#!/usr/bin/env bash
#==============================================================================
# run_all.sh —— 07-通用引擎 的**统一验证入口**（P2 交付）
#==============================================================================
# 一条命令跑齐三类验证：
#   ① Node 侧：客户端 JS 语法 + 测试钩子 + 绘制帧率 + 输入路径 + 触屏
#      （①d 变异测试：把实现改坏，确认判据**真的会红**）
#   ② Python 侧：端到端（服务端 + WebSocket + 输入闭环 + 反向测试）
#      ②g/②h 两条**跨实现一致性守卫**（协议三列 / DrawCmd 逐顶点）—— 各自带一条
#      反向测试，证明判据会红；它们比的是"两处实现是否真的一致"，不是"跑不跑得通"
#   ③ 宿主回归：06-引擎复刻 的 14 个入口 + mech.lua + tests.lua 断言（确认没把宿主改坏）
#
# 用法：bash tests/run_all.sh          全部
#       bash tests/run_all.sh --fast   跳过最慢的宿主回归
#==============================================================================
set -u
# ★★ 用**绝对路径**记住自己的根目录。原来那句收尾的
#   `cd "$(dirname "$0")/.."` 是**相对**路径，而当时 cwd 已经被切到宿主目录，
#   于是 `cd tests/..` 在宿主下找不到 ⇒ 被 `|| true` 吞掉、cwd 根本没回来 ——
#   注释写着「回 07-通用引擎」，行为却是「原地不动」。
#   与「词在≠行为在」同源：**注释描述的不是机器看到的东西**。
ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
cd "$ROOT" || exit 1

# ★★ 全量日志留证（2026-10-16 加）。
#   起因：一次「连跑 3 轮」里第 3 轮的 ② / ②b 两组**没有输出汇总行**（即中途异常退出），
#     但当时外层用了 `| grep -E "✘|总判定|结果：" | head -12` ⇒ **证据被过滤掉了**，
#     只剩 6 行摘要，事后**无法判断**到底是端口占用、还是崩了、还是超时。
#     重跑 3×2 轮都复现不出来 ⇒ 只能如实登记为「未复现的偶发」。
#   ⇒ 教训：**判据可以吵，但前提是现场还在**。任何会红的东西，必须留下完整日志。
#     （与「失败要吵」是同一件事的两面：吵得响 ≠ 留得下证据。）
#   ⚠️ 第一版用 `exec > >(tee -a "$LOG") 2>&1` 做全局重定向 —— **把 stdout 一起吞了**
#      （工具侧收到的是空输出 + SIGTERM）。进程替换会另起一个子 shell，
#      外层拿不到管道里的东西。⇒ 改成**每一组显式 tee**（run_step），
#      行为与原来逐字一致、只是顺手写一份到日志。
LOG="$ROOT/tests/_run_all.log"
: > "$LOG" 2>/dev/null || true
# 跑一条命令：输出同时进 stdout 与日志，**返回命令自己的退出码**（不是 tee 的）
run_step() {
    "$@" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    return $rc
}

# ★★ 运行时与工程路径**统一由 tools/env.sh 解析**（2026-10-17）。
#   原来这里硬编码了 `C:/Users/35916/...` 与 `E:/DST-Analysis/...`：
#   工作区搬迁后 5 个入口全部失效，而它们是**同一串字面量抄了 5 份**。
#   env.sh 提供 PY / NODE / ENGINE / RUNNER / DST_SRC（都可用环境变量覆盖）。
#
# ★★ 2026-10-18（H3）：**先过环境自检，再加载环境**。
#   审查当天 `dstsrc` 联接丢了，这条全量入口的表现是「14 个入口各抛一次 Lua 栈」——
#   一条环境故障被打印成 14 份**看起来像代码坏了**的证据。
#   现在它变成：1 条判定 + 1 条修复命令 + 退出码 2，**一个入口都不跑**。
#   判定本身也写进日志（判据可以吵，但现场必须留下）。
GATE=0
if run_step bash "$ROOT/../tools/preflight.sh"; then :; else GATE=1; fi
if [ "$GATE" != "0" ]; then
    printf '\n\033[1m✘ 环境自检不过 —— 后面的组一个都没跑（这不是代码失败，是环境缺失）\033[0m\n'
    printf '\n✘ 环境自检不过 —— 后续各组未执行\n' >> "$LOG" 2>/dev/null || true
    exit 2
fi

. "$ROOT/../tools/env.sh" || exit 2
FAST=0
[ "${1:-}" = "--fast" ] && FAST=1

FAIL=0
hr() { printf '\n\033[1m══ %s\033[0m\n' "$1"; printf '\n══ %s\n' "$1" >> "$LOG" 2>/dev/null || true; }

hr "① Node 侧：客户端验证"
if run_step "$NODE" tests/test_client.js; then :; else FAIL=1; fi

hr "①b Node 侧：精灵渲染纯函数（真实图集数据）"
if run_step "$NODE" tests/test_render_atlas.js; then :; else FAIL=1; fi

hr "①c Node 侧：二进制帧协议"
if run_step "$NODE" tests/test_protocol.js; then :; else FAIL=1; fi

hr "①d Node 侧：**变异测试**（把实现改坏，看判据是否真的变红）"
if run_step "$NODE" tests/falsify_client.js; then :; else FAIL=1; fi

# ★★ ①e **批渲染路径**（C2，2026-10-18 接入）。
#   背景：C2 原文「渲染管线只有 Canvas 2D，WebGL/批渲染未做 ⇒ 大场景帧率上限」。
#   两条判据缺一不可：
#     · tests/test_render_batch.js —— 模块本身算得对：与 Canvas 路径**逐顶点等价**
#       （≤1e-6）、strict 模式**逐条保序**、draw call 收益**量出来**、假 gl 验
#       drawArrays 的偏移/顶点数、编译失败必须抛；末尾 7 条**源码变异**证明判据有牙。
#     · tests/test_client_batch.js —— **客户端真的在用它**：
#       无 WebGL 时如实回落并说明原因、有 WebGL 时每帧贴回 1 次、
#       `?render=canvas|batch` 两个开关都验、2 条源码变异。
#   ⇒ 「模块写好了」与「被用上了」是两件事，本工程在这上面栽过（检查生效过才算数）。
hr "①e Node 侧：批渲染路径（等价 / 保序 / 收益 / 客户端接入）+ 源码变异"
if run_step "$NODE" tests/test_render_batch.js; then :; else FAIL=1; fi
if run_step "$NODE" tests/test_client_batch.js; then :; else FAIL=1; fi

hr "② Python 侧：端到端（服务端 + WebSocket + 二进制帧）"
if run_step "$PY" -u tests/test_rt.py; then :; else FAIL=1; fi

hr "②b Python 侧：跨实现一致性（Python 编码 ⇄ JS 解码）"
if run_step "$PY" -u tests/test_protocol_parity.py; then :; else FAIL=1; fi

# ★★ ②d **发布演练**（2026-10-16 加）：走 `deploy/start.sh` / `deploy/stop.sh` 这条
#   **用户入口**，而不是直接 `python rt/server.py`。
#   为什么单列一组：那两个脚本有自己的逻辑（端口守卫、启动自检、按端口找 PID 停服），
#   而「服务端没问题」≠「用户那条路没问题」—— 本工程已经在
#   「检查写好了 ≠ 检查生效过」上栽过多次，脚本的判据从来不跑就等于没有。
#   它上线第一分钟就抓到一个真问题：**默认世界只有玩家，周围什么都没有**（见 E6）。
hr "②d Python 侧：**发布演练**（deploy/start.sh → 健康检查 → 端到端 → stop.sh）"
if run_step "$PY" -u tests/test_deploy.py; then :; else FAIL=1; fi

# ★★ ②e **静态检查**（2026-10-16 加）：只判「未定义名」这类**一定会崩**的。
#   为什么单列：压 §9v.5 时压出一个真 bug —— `server.py` 的 `targets` 出错分支打印的
#   `cid` 是**另一个方法的局部变量** ⇒ 错误处理路径自己抛 NameError，
#   把真正的 `TimeoutError` 盖住了。这类 bug **跑得再全也测不出来**（只在出错时才走）。
hr "②e Python 侧：静态检查（未定义名 —— 一定会崩的那类；按设计不报无害提示）"
if run_step "$PY" -u tools/lint_names.py; then :; else FAIL=1; fi

# ★★ ②g **控制指令三列一致性**（2.5，2026-10-19 接入）。
#   防的事故：协议文档写着 `{"cmd":"me"}` 而服务端早就不认，或者客户端偷偷发了
#   一条没写进文档的命令 —— 这种人眼在 1500 行 client.html / 2000 行 server.py
#   里根本看不出来。工具从三处各自独立提取，要求三者完全相等。
#   紧跟一条**反向测试**：证明它真的会红（否则"三列一致"只是跑出来的一行绿字）。
hr "②g Python 侧：控制指令三列一致性（server ∪ client = protocol.md）+ 反向测试"
if run_step "$PY" -u tools/check_protocol.py --check; then :; else FAIL=1; fi
if run_step "$PY" -u tests/test_protocol_guard_neg.py; then :; else FAIL=1; fi

# ★★ ②h **DrawCmd 一致性**（2.4，2026-10-19 接入）。
#   判「离线渲染器（06 render.lua）与实时渲染器（07 render_atlas.js）确实在消费
#   同一份绘制指令」：逐符号、逐顶点比 xy / uv / 矩阵。
#   ⚠️ 这条判据自己换过三版才站住（v1 比错对象、v2 按 6 个顶点分组永远找不到），
#      所以反向测试是**必需**的，不是可选的：四项定点篡改 + 两项空跑/缺输入。
hr "②h Node 侧：DrawCmd 一致性（离线 vs 实时，逐顶点）+ 反向测试"
if run_step "$NODE" tools/check_drawcmd.js; then :; else FAIL=1; fi
if run_step "$PY" -u tests/test_drawcmd_neg.py; then :; else FAIL=1; fi

# ★★ ②f **服务端/引擎侧的变异测试**（2026-10-16 加）：与 ①d 同理，但对象是 `rt/`。
#   为什么必须补：客户端的判据今天被这样撞过（并当场抓到我自己的锚点过期），
#   而**服务端/引擎侧的判据从来没被撞过** —— 它们全绿着，但「凭什么绿」没人证明。
#   每条篡改**连续跑 2 遍都要红**才算数（只红一次可能是抖：砍树那件事今天就抖过）。
#   ⚠️ 篡改的锚点串找不到时它**报错**（不许静默跳过）——否则「这条判据从此没人守」。
hr "②f Python 侧：**服务端/引擎变异测试**（把 rt/ 改坏，看判据是否真的变红）"
if run_step "$PY" -u tests/falsify_server.py --runs 2; then :; else FAIL=1; fi

# ★★ ②i **停帧看门狗**（C1，2026-10-18 接入）。
#   防的事故：§9v.5「某节奏让模拟循环停住」三次没复现 —— 不复现不等于不存在，
#   它意味着**下一次发生时仍然没有证据**。所以这条要交付的是**取证能力**：
#   独立线程发现循环停住 → 计数 → 抓那一刻的 Python 栈。
#   判据分部件级（A）/ 集成级（B）/ 变异（C）三层：
#     · A 证明函数本身对（会响 / 不乱响 / 不灌水 / 阈值当阈值）
#     · B 证明**运维看到的那个面**对（/healthz 的 stalls / stall_age / last_stall.trace）
#       其中 B3 是「看门狗在独立线程里」的唯一外部证据：停帧**进行中**就得记下来，
#       如果它写在 sim_loop 里，那一拍正在 sleep ⇒ 永远记不到。
#     · C 把实现改坏（摘掉看门狗 / 阈值写死）确认 A/B 的判据**真的会红** ——
#       用的是同一份判据函数，不是另写一遍「差不多」的。
hr "②i Python 侧：停帧看门狗（部件 / 集成 / 变异三层，C1）"
if run_step "$PY" -u tests/test_stall_watchdog.py; then :; else FAIL=1; fi

# ★★ ②j **模型版本与引擎指纹绑定**（C8，2026-10-18 接入）。
#   为什么补：`tools/boot_version_guard.py` 早就写好了，**它的 docstring 还写着
#   「run_all ②i 调这个」—— 但入口里根本没有它**（②i 现在是停帧看门狗）。
#   判据存在但不被调用 = 「检查写好了 ≠ 检查生效过」，与本轮 C 类的形状完全一样：
#   输出里看不出区别，于是所有人都以为它在守。
#   ⚠️ 它只有反向测试（tests/test_boot_version_neg.py）在跑，那证明的是「工具会红」，
#      不是「当前工程这个状态是对的」—— 两件事必须分开验。
hr "②j Python 侧：模型版本 ↔ 引擎指纹（改了行为却没升版本 ⇒ 红）"
if run_step "$PY" -u tools/boot_version_guard.py --check; then :; else FAIL=1; fi

if [ "$FAST" = "1" ]; then
    # ★ L6 / M4：模块级单测（2 秒级）。放在最前面 —— 改了纯函数就该几秒知道对不对，
    #   而不是等 ② 端到端那十分钟。判据见 tests/test_units.py 顶部「判据设计」。
    hr "②k 模块级单测（net / hub / config / sim 构造期纪律）"
    if run_step "$PY" -u tests/test_units.py; then :; else FAIL=1; fi
    hr "④ 计划数字核对（--fast：跳过进程内实测）"
    if run_step "$PY" -u tools/verify_plan.py --fast; then :; else FAIL=1; fi
    # ★ H6：根目录三份基线文档的过期数字（verify_plan 只扫 07 目录，扫不到它们）
    if run_step "$PY" -u "$ROOT/../tools/audit_root_docs.py"; then :; else FAIL=1; fi
    # ★ M9：注释版**自身**完整性（U+FFFD / 二进制被当文本重写）。
    #   这一条**不需要原版副本**就能判红 —— 原版丢失期间它是唯一还在工作的
    #   「只增注释」守卫（verify-annotated 此时只能报 2＝无法复验）。
    #   （这一行原来**重复出现两次**，等于同一条判据跑两遍、白等 3 秒；已合并）
    if run_step "$NODE" "$ROOT/../tools/check-annotated-integrity.mjs"; then :; else FAIL=1; fi
    # ★ L1：协议常量单源（protocol.schema.json → protocol_schema.py/.js）
    #   生成物被手改、或改了 schema 没重生成 ⇒ 这里红。
    if run_step "$NODE" "$ROOT/../tools/gen-protocol-schema.mjs" --check; then :; else FAIL=1; fi
    # ★ M8：注释流水线里**不许**再出现别人的旧绝对路径（会红归红，不是提示）
    if run_step "$NODE" "$ROOT/../tools/relocate-paths.mjs" --check; then :; else FAIL=1; fi
    # ★ P46/P48：spec 里不许有 U+FFFD（产物好、源坏，构建时看不出来）+ 派生原版必须与 spec 对得上
    if run_step "$NODE" "$ROOT/../tools/fix-spec-fffd.mjs" --check; then :; else FAIL=1; fi
    if [ -f "$ROOT/../_baseline/derived-scripts/MANIFEST.json" ]; then
        if run_step "$NODE" "$ROOT/../tools/derive-pristine.mjs" --check; then :; else FAIL=1; fi
    fi
    hr "②c 规模与并发 / ③ 宿主回归 / ⑤ 06 三件套 —— 已跳过（--fast）"
else
    hr "②k 模块级单测（net / hub / config / sim 构造期纪律）"
    if run_step "$PY" -u tests/test_units.py; then :; else FAIL=1; fi

    hr "②c Python 侧：规模与并发（P7）"
if run_step "$PY" -u tests/test_stress.py; then :; else FAIL=1; fi

# ★ 非 --fast 时跑**完整**的核对（含进程内实测）。此前这里恒用 --fast，
#   于是 `verify_plan.py` 的 `check_runtime()`（tick 耗时 / 帧大小 / 二进制省比）
#   **从来没有在统一入口里跑过** —— 工具里有一半功能没人走。
hr "④ 计划数字核对（含进程内实测 + 规则自检 + 测试编号唯一性）"
if run_step "$PY" -u tools/verify_plan.py; then :; else FAIL=1; fi
    if run_step "$PY" -u "$ROOT/../tools/audit_root_docs.py"; then :; else FAIL=1; fi
    # ★ L1：协议常量单源 / ★ M8：注释流水线旧绝对路径绝迹（与 --fast 分支同一组判据）
    if run_step "$NODE" "$ROOT/../tools/gen-protocol-schema.mjs" --check; then :; else FAIL=1; fi
    if run_step "$NODE" "$ROOT/../tools/relocate-paths.mjs" --check; then :; else FAIL=1; fi
    # ★ P46/P48：spec 无乱码 + 派生原版与 spec 一致（与 --fast 分支同一组判据）
    if run_step "$NODE" "$ROOT/../tools/fix-spec-fffd.mjs" --check; then :; else FAIL=1; fi
    if [ -f "$ROOT/../_baseline/derived-scripts/MANIFEST.json" ]; then
        if run_step "$NODE" "$ROOT/../tools/derive-pristine.mjs" --check; then :; else FAIL=1; fi
    fi

hr "③ 宿主回归：06-引擎复刻 14 入口 + tests.lua 断言"
    # ★★ 必须**先 cd 到宿主目录**：入口里的 `require("host.01_core")` 是
    #   **按 cwd 解析**的（不是按脚本位置）—— 本脚本一直在 07-通用引擎 下跑，
    #   不切目录就会 14 个入口全部「找不到 host」⇒ 全 ✘。
    #   第一版就是这样：手动跑（在 06 下）全绿，脚本里跑全红，白查一轮。
    cd "$ENGINE" || { echo "    ✘ 进不去宿主目录 $ENGINE"; FAIL=1; }
    for f in run batch player play full render seasons equip burn perish tests mech reachability world; do
        OUT=$("$PY" "$RUNNER" 5.1 "$ENGINE/$f.lua" 2>&1)
        printf '\n--- %s ---\n%s\n' "$f.lua" "$OUT" >> "$LOG"
        if echo "$OUT" | grep -qE "^  5\.1 +PASS"; then
            printf "    ✔ %s\n" "$f.lua"
        else
            printf "    ✘ %s\n" "$f.lua"; FAIL=1
        fi
    done

    # ★★ ⑤ 06 的三件套（audit_fixes + audit_doc_numbers + verify_report）。
    #   为什么放进统一入口：07 的「发布检查单」把「三连结果」写成
    #   `run_all ✔ / 宿主 14+82 ✔ / 三件套 ✔` —— 前两个本脚本跑，
    #   第三个**谁都没跑**（要靠人记得）。于是它会悄悄红掉而没人知道。
    #   放进来的那一刻它就抓到过一次真问题（`verify_report` 报「修复清单 91 条」过期）。
    cd "$ROOT" || true                 # 回 07-通用引擎（刚才切到了宿主目录）
    hr "⑤ 06 三件套：audit_fixes + audit_doc_numbers + verify_report（约 2 分钟）"
    if run_step bash "$ENGINE/tools/check_all.sh"; then :; else FAIL=1; fi
fi

cd "$ROOT" 2>/dev/null || true

printf '\n'
if [ "$FAIL" = "0" ]; then
    echo "── 总判定：✔ 全部通过 ──"
else
    echo "── 总判定：✘ 有失败项 ──"
fi
# ★ 无论红绿都报日志路径：下次出现「某组没输出汇总行」这种偶发时，
#   现场在文件里，不必靠重跑猜（重跑往往复现不出来）。
echo "   完整日志：$LOG"
exit $FAIL
