#!/usr/bin/env bash
#==============================================================================
# pre-commit.sh —— 提交前闸门（L4）
#
# 为什么要有（H1 的教训）
#   H1 那一轮的核心发现是「**人会忘**」：判据写在文档里、工具装好了，
#   但只要「跑不跑」依赖人的记性，它迟早会不跑 —— 而**判据不跑 ≠ 判据通过**。
#   所以把「几秒级、能抓住真错误」的那几条钉在 commit 上。
#
# ★ 只放**快**的（目标 < 60 s）
#   把 10 分钟的端到端放进 pre-commit 的结果，一定是有人加 `--no-verify`。
#   慢的留在 `tests/run_all.sh`（发布/合并前跑），快的放这里。
#
# 闸门（按顺序，任一红就阻断提交）
#   ① pyflakes：未定义名 / 语法错误（重构最容易撞的就是这一类）
#   ② test_units.py：模块级单测（2 s，纯函数 + 构造期纪律）
#   ③ check-annotated-integrity：注释版编码完整性（U+FFFD / 二进制被当文本）
#   ④ verify_plan.py --fast：文档里的数字与代码对得上
#   ⑤ 改动过的 .js 跑 `node --check`（只查语法，不跑测试）
#   ⑥ 注释流水线工具自检（M8：路径解析 / 锚点解析 / 迁移器 / 重定位）
#      这四条都是**毫秒级**，但每条自带反向判据（坏输入必须报错）。
#      没有它们，四个新工具会像历史上的 verify-syntax.py 一样「装着但从不跑」。
#   ⑦ 变异残留（rt/ 里有没有「被测试改坏但没还原」的代码）
#   ⑧ 终期报告里「从账本抄来的数」是否还对
#   ⑨ 判据自检的**用例条数**：清单 / 工具自守 / 实跑 三方对账
#   ⑩ 客户端冒烟：`tests/test_client.js`（32 项）—— 拦「页面根本跑不起来」这一类
#
# ★★★ 为什么有第 ⑩ 步（2026-10-21 P63 实测，代价是 31 条判据红了整晚）：
#   上面 ①~⑨ 全是**静态/一致性**检查，没有一条真的把 client.html 跑起来。
#   P62 给客户端加编辑器时用了 `document.querySelectorAll`，而测试用的 DOM 桩里没有这个方法
#   ⇒ ① 组（32 项）**当场红 31 项**；但本闸门照样全绿，提交照样通过。
#   于是「闸门 9 步全绿」这句话是真的，**同时**「判据全红」也是真的 —— 两句话不矛盾，
#   因为它们覆盖的是**不同的集合**。这正是本项目反复抓的那类假绿：判据的作用域
#   小于结论的作用域。
#   修法不是"记得跑 run_all"，而是**把最容易碎的那一组挪进闸门**：
#   ① 组 32 项只跑 2~3 秒，且在无服务端、无浏览器的环境下可跑 —— 没有理由不拦。
#   仍然守不住的：②~⑤ 组（要起服务/跑 20 分钟）不在闸门里，仍需 pre-push 或 CI 兜底。
#      （只信 rc 的闸门，在用例被删一半时仍然绿）
#
# 绕过：`SKIP_PRECOMMIT=1 git commit ...`（**要明说**；默认不允许）
#   绕过一次就要在提交信息里写清为什么 —— 不然下一个人只看到「闸门没拦」。
#==============================================================================
set -u
# ★ 必须开 pipefail：下面多条闸门是 `cmd | tail`，没有它只能看到 tail 的退出码
#   ⇒ 闸门会「永远通过」。这正是 L4 要防的那类假绿。
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

if [ "${SKIP_PRECOMMIT:-0}" = "1" ]; then
    echo "⚠ SKIP_PRECOMMIT=1 —— 跳过提交前闸门。请在提交信息里写明原因。" >&2
    exit 0
fi

. tools/env.sh >/dev/null 2>&1 || { echo "✘ tools/env.sh 加载失败" >&2; exit 1; }

FAIL=0
step() { printf '\n▸ %s\n' "$1"; }

step "① pyflakes：07 引擎与测试"
if ! "$PY" -m pyflakes 07-通用引擎/rt/*.py 07-通用引擎/tests/test_units.py \
        07-通用引擎/tests/falsify_server.py 2>&1 | sed 's/^/   /'; then
    FAIL=1
fi

step "② 模块级单测（net / hub / config / sim 构造期）"
( cd 07-通用引擎 && "$PY" -u tests/test_units.py ) | tail -4 || FAIL=1

step "③ 注释版完整性（U+FFFD / 二进制被当文本）"
"$NODE" tools/check-annotated-integrity.mjs | tail -6 || FAIL=1

step "④ 计划数字核对（--fast）"
( cd 07-通用引擎 && "$PY" -u tools/verify_plan.py --fast ) | tail -4 || FAIL=1

step "⑤ 改动过的 .js 语法检查"
js=$(git diff --cached --name-only --diff-filter=ACM | grep -E '\.js$' || true)
if [ -z "$js" ]; then
    echo "   （本次提交没有 .js）"
else
    for f in $js; do
        if "$NODE" --check "$f" >/dev/null 2>&1; then
            echo "   ✔ $f"
        else
            echo "   ✘ $f 语法错误"; "$NODE" --check "$f" 2>&1 | head -3 | sed 's/^/     /'; FAIL=1
        fi
    done
fi

step "⑥ 注释流水线工具自检（M8：路径 / 锚点 / 迁移 / 重定位）"
for t in "tools/lib/paths.mjs --selftest" "tools/lib/spec-anchor.mjs --selftest" \
         "tools/spec-keys.mjs --selftest" "tools/relocate-paths.mjs --selftest" \
         "tools/gen-protocol-schema.mjs --selftest"; do
    if out=$("$NODE" $t 2>&1); then
        echo "   ✔ $t —— $(echo "$out" | tail -1 | sed 's/^ *//')"
    else
        echo "   ✘ $t"; echo "$out" | tail -12 | sed 's/^/     /'; FAIL=1
    fi
done
# ★ L1：协议常量单源 —— 生成物必须与 schema 一致（改 schema 忘重生成 ⇒ 红）
if out=$("$NODE" tools/gen-protocol-schema.mjs --check 2>&1); then
    echo "   ✔ gen-protocol-schema --check：$(echo "$out" | tail -1 | sed 's/^ *//')"
else
    echo "   ✘ 协议常量与 schema 不一致"; echo "$out" | sed 's/^/     /'; FAIL=1
fi
# ★ 旧绝对路径必须绝迹：这条**会红**——只要有人再抄一次 `C:/Users/35916/...`。
if out=$("$NODE" tools/relocate-paths.mjs --check 2>&1); then
    echo "   ✔ 旧绝对路径：$(echo "$out" | tail -1)"
else
    echo "   ✘ 仍有写死的旧绝对路径"; echo "$out" | head -6 | sed 's/^/     /'; FAIL=1
fi
# ★ P46/P48：spec 里不许有 U+FFFD —— 产物是好的、源却是坏的，构建时看不出来，
#   等真原版到位重建一次就会把坏字写进注释版。这条**会红**。
if out=$("$NODE" tools/fix-spec-fffd.mjs --check 2>&1); then
    echo "   ✔ spec 乱码：$(echo "$out" | tail -1)"
else
    echo "   ✘ spec 里有 U+FFFD"; echo "$out" | head -6 | sed 's/^/     /'; FAIL=1
fi
# ★ P46：派生原版树必须与当前 spec 对得上（spec 改了忘重跑 derive ⇒ 红）。
#   派生树在 .gitignore 里（可再生）；没生成过就只提示、不算失败。
if [ -f "_baseline/derived-scripts/MANIFEST.json" ]; then
    if out=$("$NODE" tools/derive-pristine.mjs --check 2>&1); then
        echo "   ✔ 派生原版：$(echo "$out" | tail -1)"
    else
        echo "   ✘ 派生原版与 spec 不一致"; echo "$out" | tail -6 | sed 's/^/     /'; FAIL=1
    fi
else
    echo "   ⊘ 派生原版未生成（node tools/derive-pristine.mjs --write 后生效）"
fi
# ★★★ 2026-10-20（P50）：**生成器模板回归**。
#   `tools/gen-builds.mjs` 会覆盖 29 个 build 脚本。它的老模板把路径写成绝对路径、
#   而且**没有** `expandKeysInPlace` —— 重跑一次就把 P47/P48 手工接的锚点展开全抹掉，
#   而 `node build-xxx.mjs` 照样打印「✔ 已生成」，只是注释少了一片。**没有任何报错。**
#   本轮真踩了一次（32 个脚本被改回），所以把「模板里必须有那两样」变成判据：
#   这不是风格检查，是「一跑就静默降级」的那类命令的保险丝。
gen_ok=1
if ! grep -q 'expandKeysInPlace(AFTER' tools/gen-builds.mjs; then
    echo "   ✘ gen-builds 模板丢了 expandKeysInPlace —— 重跑它会让锚点键静默失效"; gen_ok=0
fi
if ! grep -q 'const SRC = relSrc(' tools/gen-builds.mjs; then
    echo "   ✘ gen-builds 模板写的是绝对路径（应为 relSrc/relOut）"; gen_ok=0
fi
if [ "$gen_ok" = 1 ]; then
    echo "   ✔ 生成器模板：保留锚点展开 + 路径走 relSrc/relOut"
else
    FAIL=1
fi

step "⑦ 变异残留：rt/ 里有没有「改坏了但没还原」的代码"
# ★★★ 2026-10-21（P50）：**变异残留**。
#   ②f 的服务端/引擎变异测试会把 `rt/` 下的代码**临时改坏**（今天实测：把
#   `rt_boot.lua` 里 `hu.current` 改成 `hu.max`），跑完再由还原函数改回来。
#   它靠「跑完」这个动作还原 —— 一旦异常退出（超时 / 被 kill / 断言崩），
#   代码就留在被改坏的状态，`git status` 会显示 `M 07-通用引擎/rt/rt_boot.lua`。
#   ㉜ 那次实测：变异在源码里躺了 **10 小时 3 分**，期间没人发现。
#   若那 10 小时里有人提交了 rt/ 的改动，就会把**故意改坏的代码**提交进去 ——
#   而所有判据都会以「绿的」收尾，因为它们测的正是被改坏的那一版。
#   ⇒ 有变异标记就拒绝提交。正常开发不会产生这两个文件，所以**不会假红**。
#   ⚠ 这条守不住「标记被删了、代码却没还原」的残余情况（那需要记录注入前的 hash），
#     如实写在这儿，不当成守住了。
MARK_SEEN=0
for m in 07-通用引擎/tests/_falsify_inprogress.json \
         07-通用引擎/tests/_mutant_inprogress.json; do
    if [ -f "$m" ]; then
        echo "   ✘ 存在变异标记：$m"
        echo "      ⇒ 有一轮变异测试正在进行，或异常退出后没还原。"
        echo "      ⇒ 此刻 rt/ 里可能是**被故意改坏**的代码；等它跑完再提交。"
        MARK_SEEN=1
        FAIL=1
    fi
done
if [ "$MARK_SEEN" = 0 ]; then
    echo "   ✔ 没有变异标记（rt/ 不存在「被测试改坏但没还原」的中间状态）"
fi

step "⑧ 终期报告里「从账本抄来的数」是否还对"
# ★★★ 2026-10-21（P50㊺）：报告定稿的那一刻，它写的数就开始过期了。
#   B7 报告 16:59 定稿，17:01 就抓出两处：账本「14 轮」实际 15 轮（差的那行
#   16:35:25 那一轮在写报告时还在跑）；阈值来源「561 s×2」账本里根本没有这个数。
#   这不是谁抄错了，是**把易变的数写成点值**这个动作本身会过期。
#   ⇒ 由 tools/check_report_ledger.py 判：报告里的 N 轮 / 阈值来源 必须等于账本末两行；
#     并且先校验**账本自己**是否自洽（末行阈值 == 由倒二行推出的值），不自洽就不判报告。
#   为什么放在提交闸门而不是 ④ 组：报告是**人的产物**，随提交一起进仓库，
#   在它入库的那一刻拦住，比等下一轮全量跑完更早。
#   报告不存在时 `check_report_ledger.py` 打印跳过并 rc=0，不会把「还没写报告」判成失败。
if ! "$PY" -X utf8 -u tools/check_report_ledger.py 2>&1 | sed 's/^/   /'; then
    echo '      ⇒ 按账本自动改正（改完看 diff 再提交）：'"$PY"' -X utf8 tools/check_report_ledger.py --apply'
    FAIL=1
fi

step "⑨ 判据自检的用例条数（清单 / 工具自守 / 实跑 三方对账）"
# ★★★ 2026-10-21（P50㊾ / §9cd）：今天发现的第三类假绿 —— **判据变松了，检查它的东西也跟着变松**。
#   各工具的 `--selftest` 在本闸门与 `tests/run_all.sh` 里此前都**只看退出码**：
#   用例被删掉一半、剩下的一半全过，rc 仍是 0，闸门照样绿。
#   今天给 5 个工具各加了 `WANT_CASES` 自守，但那只拦得住「用例被删、常量没动」；
#   把用例和常量**一起**改小，工具自己照样绿 ⇒ 外部锚点只能是
#   `tools/case_counts.txt`（进仓库、进 diff、要人看过的清单）。
#
#   为什么不在每个工具里各写一遍期望：同一件事写两处必然漂 ——
#   这正是今天 `final_check.sh` 里 `want` 算了却没被比对的教训。
#   一处清单，两处消费（本闸门 + 收尾核验），各自的期望都从清单来。
#
#   守不住的：清单和用例被人一起改小（那只能靠 review diff）。如实写在这儿。
if ! "$PY" -X utf8 -u tools/check_case_counts.py 2>&1 | sed 's/^/   /'; then
    echo "      ⇒ 清单是唯一真源：tools/case_counts.txt（改用例就顺手改它，并看一眼 diff）"
    FAIL=1
fi

step "⑩ 客户端冒烟（① 组 32 项：页面能不能真的跑起来）"
# ★ 只跑 ① 组，不跑全量：它 2~3 秒、无服务端无浏览器，却覆盖了「DOM 方法不存在 / 初始化抛错 /
#   渲染路径空转」这一整类「页面打开就是白屏」的故障。P62 就是栽在这里（31/32 红而闸门全绿）。
if ! ( cd 07-通用引擎 && "$NODE" tests/test_client.js ) 2>&1 | tail -3 | sed 's/^/   /'; then
    echo "      ⇒ 客户端脚本在桩环境里跑不起来。先单独跑：cd 07-通用引擎 && node tests/test_client.js"
    FAIL=1
fi

echo ""
if [ $FAIL = 0 ]; then
    echo "✅ 提交前闸门通过"
    exit 0
fi
echo "❌ 提交前闸门未通过 —— 修完再提交（或 SKIP_PRECOMMIT=1 并说明理由）"
exit 1
