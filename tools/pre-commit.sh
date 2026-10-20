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

echo ""
if [ $FAIL = 0 ]; then
    echo "✅ 提交前闸门通过"
    exit 0
fi
echo "❌ 提交前闸门未通过 —— 修完再提交（或 SKIP_PRECOMMIT=1 并说明理由）"
exit 1
