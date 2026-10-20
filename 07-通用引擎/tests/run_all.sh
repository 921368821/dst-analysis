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

# ★★★ 运行锁（2026-10-20 实测事故）：两轮**并发**跑过一次，后果是**两轮都不可采信**：
#   · 后起的一轮 `: > "$LOG"` 把前一轮已经写好的日志**清空**（上面这行本身没有锁保护）；
#   · 两轮又各自 `tee -a` 追写，于是「⑤ 的组标题」下面跟着「② 的 A1 启动」；
#   · 端口互撞（8791 两轮都要）⇒ 服务器互相顶掉，跑完留 3 个端口还在 LISTENING。
#   ⇒ 并发不是「更快」，是**把现场毁掉**。锁用 `mkdir`（**原子**）实现 —— 文件+PID 的写法
#     在「两轮同时启动」时会两边都以为自己拿到了锁。锁里记 PID + 起始时间，人为可读、可手删。
LOCKD="$ROOT/tests/_run_all.lock.d"
BEAT="$LOCKD/beat"
# ★★ P50㉓：`600` 原来是**拍的**。这条阈值的含义是「beat 静默多久才算真残留」，
#   而 beat 只在**每组开头**（hr()）写一次 ⇒ 它的下限由「**最长的一组要跑多久**」决定，
#   不是由「一轮总共多久」决定。600 秒 = 10 分钟，我当时没有任何一组耗时数据（日志里一组都没记过），
#   属于「看起来合理」。若某一组真跑到 10 分钟以上，父 shell 一死，beat 会在那一组**中途**变陈旧，
#   下一轮就会判「残留」⇒ 清锁 ⇒ 清空日志 ⇒ 与孤儿抢端口 —— 正是这把锁要防的事。
#   ⇒ 阈值改成**由数据推**：上一轮把「最长一组耗时」写进 tests/_run_all.groupmax，
#     本轮取 2× 该值（留一倍余量）向上取整到分钟，且不低于 600。
#     没有那个文件（首次运行 / 刚清理过）就退回 600，并**在启动时说明用的是哪个来源**。
GROUPMAX_F="$ROOT/tests/_run_all.groupmax"
BEAT_STALE_MAX=600
BEAT_STALE_SRC="默认值（还没有 tests/_run_all.groupmax ⇒ 首次运行）"
if [ -f "$GROUPMAX_F" ]; then
    #   ★ 文件**在**但内容不可用，和「文件不存在」是两回事 —— 原来两种情况都打「不存在」，
    #     于是一个被写坏的数据文件会看起来像「首次运行」，永远不会被怀疑。
    BEAT_STALE_SRC="默认值（tests/_run_all.groupmax 存在但值不可用：$(head -c 20 "$GROUPMAX_F" 2>/dev/null | tr -d "
"))"
fi
if [ -f "$GROUPMAX_F" ]; then
    REC_MAX=$(tr -dc "0-9" < "$GROUPMAX_F" 2>/dev/null)
    if [ -n "$REC_MAX" ] && [ "$REC_MAX" -gt 0 ] 2>/dev/null; then
        # 2 倍余量，再向上取整到整分钟
        NEED=$(( (REC_MAX * 2 + 59) / 60 * 60 ))
        if [ "$NEED" -gt "$BEAT_STALE_MAX" ]; then BEAT_STALE_MAX=$NEED; fi
        BEAT_STALE_SRC="上一轮实测最长一组 ${REC_MAX} s × 2 向上取整" 
    fi
fi
# ★ 仅供**反向验证**用：把阈值压到 0 才能让「最长一组 ≥ 阈值」这一支在秒级内变红。
#   生产路径不要设它 —— 见 tests/run_all.sh 的判据与 开发计划.md §9bc.5。
if [ -n "${RT_BEAT_STALE_MAX:-}" ]; then
    BEAT_STALE_MAX=$RT_BEAT_STALE_MAX
    BEAT_STALE_SRC="环境变量 RT_BEAT_STALE_MAX（反向验证用）"
fi
# ★★ P50㉑：锁的存活判据原来只看**父 shell**（`kill -0 $OLD_PID`）—— 这个洞能被孤儿子进程骗过去。
#   实测证据（当天 16:32 的看护日志，不是假想）：
#     「锁 PID=1249 已不存在，而 tests/_run_all.log 至 16:32 仍在增长」
#   —— 主 shell 走了，但 `tee` / `python rt/server.py` / 各组子进程还活着：还在写日志、还占着端口。
#   下一次 `run_all.sh` 会判「残留」⇒ 清锁 ⇒ `: > tests/_run_all.log` ⇒ 与孤儿抢 8791，
#   正是当初加锁要防的那件事。
#   ⇒ 加一个 `beat` 文件：每组开头（`hr()`）写一次时间戳。判定改成三段：
#     ① PID 活着                     ⇒ 拒绝（并说明起始时间）
#     ② PID 不在但 beat 10 min 内动过 ⇒ **拒绝**（子进程多半还活着，别毁现场）
#     ③ PID 不在且 beat 陈旧/缺失     ⇒ 才算残留，清掉继续
if ! mkdir "$LOCKD" 2>/dev/null; then
    OLD_PID=$(sed -n 1p "$LOCKD/pid" 2>/dev/null)
    OLD_TS=$(sed -n 2p "$LOCKD/pid" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        printf '✘ 已有一轮全量在跑（PID %s，起始 %s）—— 没有并发跑\n' "$OLD_PID" "$OLD_TS"
        printf '  并发跑会：清空 tests/_run_all.log / 互撞端口 8765·8791·8793·8799 / 留下服务器\n'
        printf '  确认那一轮已结束：rm -rf %s\n' "$LOCKD"
        exit 3
    fi
    BEAT_AGE=999999
#   ★★ P50㉒：**先看 `done`**。上一批的 beat 判据有个反噬：正常结束的运行若收尾没删干净
#      （实测就发生了：`trap` 里的 `rm -rf` 被环境的批量删除拦截），锁会留在原地，
#      而「PID 已退出 + beat 仍新鲜」恰好落进「子进程可能还活着」那一支 ⇒ 10 分钟内再起一轮
#      会被 rc=3 挡住 —— **一次正常结束的运行，被自己的锁判成了「还在跑」。**
#      `done` 是收尾时写的结束标记：它在 ⇒ 这一轮**已经正常结束**，不必再猜 beat。
#      （它与「父 shell 走了、子进程还在」并不冲突：那种情况根本没机会写 done。）
    DONE_SAW=0
    if [ -f "$LOCKD/done" ]; then
        DONE_SAW=1
        # ★ 把 epoch 转成人能读的时间；转不了就原样打（不猜）
        DONE_TS=$(date -d "@$(cat "$LOCKD/done" 2>/dev/null)" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                 || cat "$LOCKD/done" 2>/dev/null || echo "?")
        printf '  （锁里有 done 标记：那一轮已于 %s 正常结束，PID %s 已不在）\n' "$DONE_TS" "${OLD_PID:-?}"
    elif [ -f "$BEAT" ]; then
        BEAT_MTIME=$(stat -c %Y "$BEAT" 2>/dev/null || echo 0)
        BEAT_AGE=$(( $(date +%s) - BEAT_MTIME ))
    fi
    if [ "$BEAT_AGE" -lt "$BEAT_STALE_MAX" ]; then
        printf '✘ 锁里的 PID %s 已不在，但 beat 文件 %s 秒前还在动（阈值 %s s）—— 那一轮的**子进程多半还活着**\n' "${OLD_PID:-?}" "$BEAT_AGE"
        printf '  这不是残留锁，而是「父 shell 走了、子进程还在」：清锁会清空 tests/_run_all.log 并与孤儿抢端口。\n'
        printf '  阈值来源：%s\n' "$BEAT_STALE_SRC"
        printf '  先确认现场：netstat -ano | grep -E ":(8765|879[0-9]) .*LISTENING"\n'
        printf '  确认真没人了再手删：rm -rf %s\n' "$LOCKD"
        exit 3
    fi
    # ★★ 两种残留要分开说：从 done 分支下来时 BEAT_AGE 根本没读（还是 999999），
    #   沿用下面那句会打印「beat 已静默 999999 秒」—— 一句**和数据不符**的话。
    #   文案与判据必须指同一件事，否则下一个看日志的人会被它带偏。
    if [ "$DONE_SAW" = "1" ]; then
        printf '  （清掉已正常结束的锁：那一轮写了 done，没有子进程在外面跑）\n'
    else
        printf '  （清掉残留锁：PID %s 已不在，beat 已静默 %s 秒）\n' "${OLD_PID:-?}" "$BEAT_AGE"
    fi

    rm -rf "$LOCKD" 2>/dev/null
    mkdir "$LOCKD" 2>/dev/null || { echo "✘ 抢不到锁 $LOCKD"; exit 3; }
fi
printf '%s\n%s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOCKD/pid"
date +%s > "$BEAT" 2>/dev/null || true      # ★ 第一拍：拿到锁就算活着
printf '   （锁的 beat 阈值：%s s，来源：%s）\n' "$BEAT_STALE_MAX" "$BEAT_STALE_SRC" >> "$LOG"
# ★ P50㉒：**先写 done、再删目录**。顺序不能反：删成功就什么都不需要，删失败（被拦/权限）时 done 必须已经在。
trap 'date +%s > "$LOCKD/done" 2>/dev/null; rm -rf "$LOCKD"' EXIT INT TERM
T0=$(date +%s)
printf '══ run_all 开始 %s · PID %s · 参数 %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "${1:-（全量）}" >> "$LOG"

# 跑一条命令：输出同时进 stdout 与日志，**返回命令自己的退出码**（不是 tee 的）
run_step() {
    # ★★ `--dry-run`（2026-10-20 加）：**只数组、不跑**。
    #   为什么需要：组数核对是「运行时」判据，而验它一次要 11 分钟（--fast）——
    #   等于「这条判据自己没法被便宜地验证」，于是我把声明值写错（17 vs 真实的 18）
    #   也只能在跑完之后才知道。dry-run 把这条路压到秒级：改完 run_all 先 dry 一遍。
    #   ★ P50㉓ 更正：这行原来写「压到 3 秒」，而 ③ 组**没走 run_step**、dry 时照跑 14 个
    #     lua 入口（实测 54 s）。现在 ③ 也走 DRY 分支，dry-run 实测 10 s（原来 64 s）。
    #     剩下的 10 s 里，第一组那 4 s 是 preflight（解析环境 / 查运行时版本），不属任何判据。
    #   ★ 它的结论**不作数**（所有组都算通过），所以末尾会大声说明。
    # ★ 用 `${DRY:-0}`：`set -u` 下未定义会直接退出，而 run_step 第一次被调用
    #   （preflight 那一行）比参数解析还早 ⇒ 第一版在这里报 DRY: unbound variable。
    if [ "${DRY:-0}" = "1" ]; then
        printf '  (dry-run) %s\n' "$*"
        return 0
    fi
    # ★★ P50㉔：**一边等、一边打心跳**。原来只在每组开头（hr()）打一次，
    #   于是「父 shell 死了、这一组的子进程还在跑」的一整段里 beat 是停的 ——
    #   阈值只能靠「2 × 最长单组」去兜（§9bc），而那是余量不是证明。
    #   现在子进程活着就每 15 s 打一拍，残活期也有心跳。
    #   ★ 两个已知坑，都已隔离实验过（见 backlog P23）：
    #     ① 不能改成 `| tee` + 后台：那样拿不到 PIPESTATUS。改用**进程替换**（> >(tee)），
    #        rc 由 `wait $pid` 给回来 —— 实测 0/3/7 都正确；
    #     ② 当年 `exec > >(tee)` 因为时序吞过 stdout。这里实测 3×20000 行，
    #        wait 返回时日志已写满（尾行不丢）。
    "$@" > >(tee -a "$LOG") 2>&1 &
    local _pid=$! _rc=0
    while kill -0 "$_pid" 2>/dev/null; do
        date +%s > "$BEAT" 2>/dev/null || true
        # ★ 15 s 切成 15 个 1 s 段，每段前先看一眼进程还在不在。
        #   原来直接 `sleep 15`：一个 0.1 s 就结束的步骤也要睡满 15 s（实测 15585 ms）。
        #   run_step 是**每步**调用的 ⇒ 一轮几十步，白扔几百秒，还会把 groupmax 写虚高。
        local _w=0
        while [ "$_w" -lt 15 ]; do
            kill -0 "$_pid" 2>/dev/null || break
            sleep 1
            _w=$(( _w + 1 ))
        done
    done
    wait "$_pid"; _rc=$?
    local rc=$_rc
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
# ★★ 源码洁净闸门（2026-10-20 实测事故）：
#   ②f 的变异测试是「**把源码改坏** → 看判据红不红 → 还原」；还原写在 `finally` 里，
#   而 `finally` 只在进程还活着时执行。任何硬中断（超时 / Ctrl-C / taskkill /F /
#   整轮被审计脚本掐掉）都会让源码**停在篡改态**。实测现场：`rt/rt_boot.lua` 的
#   `in_light_at` 停在 `if true then return true`、`player_state` 的 hunger 读成 max ——
#   之后每一组都在这份**假源码**上跑，夜间光照 / 饥饿判据**全绿**，日志看着漂亮。
#   ⇒ 两道：① 先跑 `falsify_server.py --heal`（有标记就按原文写回并大声说明）；
#          ② 再看 git：`rt/` 与 `06-引擎复刻` 有没有未提交改动，有就要人明确放行。
"$PY" -u "$ROOT/tests/falsify_server.py" --heal >/dev/null 2>&1 || \
    printf '  ⚠ 自动还原没成功（可能是旧格式标记），下面按 git 状态判\n'
DIRTY=$(git -C "$ROOT/.." status --porcelain -- "07-通用引擎/rt" "06-引擎复刻" 2>/dev/null)
if [ -n "$DIRTY" ]; then
    if [ "${RT_ALLOW_DIRTY_SRC:-0}" != "1" ]; then
        printf '✘ 源码不干净（变异测试可能停在篡改态，或你正在改产品代码）：\n'
        printf '%s\n' "$DIRTY" | sed 's/^/    /'
        printf '  若确认是残留篡改：git -C "%s" checkout -- "07-通用引擎/rt" "06-引擎复刻"\n' "$ROOT/.."
        printf '  若这些改动是你自己的：RT_ALLOW_DIRTY_SRC=1 bash tests/run_all.sh\n'
        exit 4
    fi
    printf '  ⚠ RT_ALLOW_DIRTY_SRC=1：带着未提交的源码改动继续（这次结论只对你本地有意义）\n'
fi
# ★ 收尾卫生的基线：**跑之前**就已经在听的端口不算本次的账（人工起的开发服不背锅）
"$PY" -u "$ROOT/tools/check_leftovers.py" --snapshot "$ROOT/tests/_leftovers.json" >/dev/null 2>&1 || true
FAST=0
DRY=0
case "${1:-}" in
    --fast) FAST=1 ;;
    --dry-run) DRY=1 ;;      # 只数组不跑（见 run_step 的注释）
    --fast-dry) FAST=1; DRY=1 ;;
esac
if [ "$DRY" = "1" ]; then
    printf '\033[1m★ --dry-run：只走组标题、不执行任何判据（结论不作数）\033[0m\n'
fi

FAIL=0
# ★★ 组数**运行时**自校验（2026-10-20）。为什么需要第二套口径：
#   文档里的「20 组」一直由 `verify_plan.py:count_groups()` 从**源码文本**数标签得到，
#   它管得住「文档数字写错」，管不住「某组被 `if false` 包住 / 被整段删掉」——
#   标签还在文本里，静态数照样 20，而那一组一次都没跑。
#   现在由 hr() **在真的打印标题时** +1 ⇒ 这个数只有「真跑过」才会涨。
#   ★ 两处声明是**故意**的：加组的人必须同时改这里和文档，两边对不上就红。
#     （本工程栽过的坑几乎都是「一处声明、零处校验」；这里要的是两个真相源对撞。）
DECLARED_GROUPS=20          # 全量
# --fast 的 18 是**量出来的**（2026-10-20 实测，见 tests/_run_all.log 的「组数核对」行）：
#   全量 20 减掉 ②c / ③ / ⑤ 三组（fast 跳过），再加上 fast 分支自己的
#   「②c / ③ / ⑤ 已跳过」那一行提示（它也走 hr，算 1 次）⇒ 20 - 3 + 1 = 18。
#   ★ 第一版我按「17」写，跑完才发现是 18 —— 靠人算这种差额一定会错，
#     所以才加了 `--dry-run`（秒级，见下）把「数错」的发现成本从 11 分钟降到 3 秒。
DECLARED_GROUPS_FAST=18     # --fast
GROUP_N=0
GROUP_LIST=""
# ★★ P50㉓：**每组实测耗时**。原来一轮跑完只有一个总数（"实测 1214 s"），
#   于是「哪一组占了大头」「比上轮慢 8 s 是谁慢了」全靠猜 —— 我在 §9bb 里把时长上涨
#   归因给「同机还有别的项目的 CPU 密集任务」，那句话当时**没有任何数据支撑**。
#   现在每组收尾打一行 `⏱ … 用时 N s`，并且记下最长的一组（锁的阈值要用它，见文件头）。
GROUP_MAX=0
GROUP_MAX_NAME=""
GROUP_T0=$T0
GROUP_LAST=""
_tally() {
    # 结算**上一组**：从它开头到现在。第一组之前 GROUP_LAST 为空，跳过。
    [ -z "$GROUP_LAST" ] && return 0
    local now dur
    now=$(date +%s)
    dur=$(( now - GROUP_T0 ))
    printf '\033[2m⏱ %s 用时 %d s\033[0m\n' "$GROUP_LAST" "$dur"
    printf '⏱ %s 用时 %d s\n' "$GROUP_LAST" "$dur" >> "$LOG" 2>/dev/null || true
    if [ "$dur" -gt "$GROUP_MAX" ]; then
        GROUP_MAX=$dur
        GROUP_MAX_NAME=$GROUP_LAST
    fi
    GROUP_T0=$now
}
hr() {
    _tally
    GROUP_N=$((GROUP_N + 1))
    GROUP_LIST="$GROUP_LIST|$1"
    GROUP_LAST=$1
    printf '\n\033[1m══ %s\033[0m\n' "$1"
    printf '\n══ %s\n' "$1" >> "$LOG" 2>/dev/null || true
    # ★ P50㉑：每组开头打一次心跳 —— 锁那边靠它区分「残留」与「父 shell 走了、子进程还活着」。
    date +%s > "$BEAT" 2>/dev/null || true
}

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
    # ★★ P50㉓：这里的 14 次调用**原来不走 run_step**，于是 `--dry-run` 拦不住它 ——
    #   实测 dry-run 仍然跑了 54 s（③ 组 14 个入口），而末尾那句总结写的是「一个判据都没跑」。
    #   一句话与行为不符，比慢更坏：它会让人以为 dry-run 是免费的，于是不再真跑。
    #   ⇒ 整段包进 DRY 分支，与 run_step 的语义对齐。
    if [ "$DRY" = "1" ]; then
        printf '  (dry-run) 宿主回归 14 入口：run batch player play full render seasons equip burn perish tests mech reachability world\n'
    else
    for f in run batch player play full render seasons equip burn perish tests mech reachability world; do
        OUT=$("$PY" "$RUNNER" 5.1 "$ENGINE/$f.lua" 2>&1)
        printf '\n--- %s ---\n%s\n' "$f.lua" "$OUT" >> "$LOG"
        if echo "$OUT" | grep -qE "^  5\.1 +PASS"; then
            printf "    ✔ %s\n" "$f.lua"
        else
            printf "    ✘ %s\n" "$f.lua"; FAIL=1
        fi
    done
    fi

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

# ★ P50⑦：**收尾卫生**。上面 ③ 那组里有 `cd "$ENGINE"`，所以这一组必须放在回到 ROOT 之后。
#   判据：本次用过的端口（8765 / 8790~8799）跑完必须都关掉；残留 ⇒ 判红并清理。
#   为什么值得单列一组：残留服务器的输出**会继续追加进 tests/_run_all.log**（它握着 tee 的
#   写端），日志「现场还在」这句话就被打脸了；而且下一轮会撞端口，红在不相干的地方。
hr "⑥ 收尾：进程与日志卫生（本次用过的端口必须已关闭）"
# ★ 先验**判据自己**（P50⑯）：`--selftest` 会临时起两个监听、验三段
#   （有残留必报 / 杀得掉 / 基线里的不背锅也不误杀），6 秒。
#   为什么放进每轮：这条判据此前**从没被反向验证过** —— 它只在「本来就没残留」
#   的情况下跑过，那时它输出 ✔，与「它根本不工作」长得一模一样。
if run_step "$PY" -u "$ROOT/tools/check_leftovers.py" --selftest; then :; else FAIL=1; fi
if run_step "$PY" -u "$ROOT/tools/check_leftovers.py" --verify "$ROOT/tests/_leftovers.json"; then :; else FAIL=1; fi
# ★ P50⑰：顺手收走 boot 留下的 `%TEMP%\rt_filelist_<pid>`。
#   实测 2026-10-20：一天下来堆了 **1251 个 / 45 MB** —— `Sim.boot()` 每次都建，
#   而它以前从不删（atexit 只覆盖正常退出，`taskkill /F` 留下的只能靠这里）。
#   只删「pid 已不存在」的：pid 还在就可能是别的进程正在读，一个都不碰。
if run_step "$PY" -u "$ROOT/tools/check_leftovers.py" --clean-temp; then :; else FAIL=1; fi

_tally
ELAPSED=$(( $(date +%s) - T0 ))
printf '\n'
# ★★ P50㉓：**这一轮自己检查自己用的阈值**。
#   判据（危险的那一侧）：最长的一组 ≥ 阈值 ⇒ 单组跑得比阈值还久 ⇒ 父 shell 一死，
#   beat 会在那一组**中途**变陈旧 ⇒ 下一轮把「还在跑」判成「残留」⇒ 清锁、清日志、抢端口。
#   所以这条一旦越界必须**判红**（不是警告）—— 它是一条安全边界，不是性能指标。
#   注意 dry-run 不写 groupmax：那时每组 0 s，落盘会把上一轮的真实数据覆盖成 0。
if [ "$GROUP_MAX" -gt 0 ]; then
    printf '  最长一组：%s（%d s）；锁的 beat 阈值 %s s，来源：%s\n' \
        "$GROUP_MAX_NAME" "$GROUP_MAX" "$BEAT_STALE_MAX" "$BEAT_STALE_SRC" | tee -a "$LOG"
    if [ "$GROUP_MAX" -ge "$BEAT_STALE_MAX" ]; then
        printf '\n\033[1m✘ 锁的 beat 阈值 %s s 不大于最长一组 %d s（%s）\033[0m\n' \
            "$BEAT_STALE_MAX" "$GROUP_MAX" "$GROUP_MAX_NAME"
        printf '  这一组跑到一半，beat 就会被判成陈旧 ⇒ 下一轮会把「还在跑」当成「残留锁」清掉。\n'
        printf '  ⇒ 阈值必须 > 最长一组（2 倍是设计余量，不是红线；见 开发计划.md §9bc）。\n'
        printf '✘ 锁的 beat 阈值 %s s 不大于最长一组 %d s（%s）\n' \
            "$BEAT_STALE_MAX" "$GROUP_MAX" "$GROUP_MAX_NAME" >> "$LOG"
        FAIL=1
    elif [ $(( GROUP_MAX * 2 )) -gt "$BEAT_STALE_MAX" ]; then
        # ★ P50㉓ 量出来的事实：最长一组 542 s，而阈值 600 s —— 只比 1 倍多 58 s（10.7%）。
        #   「单组比阈值久」这条红线还没踩到，所以不判红；但设计余量（2 倍）并不满足。
        #   直说，并且把「下一轮自动推到多少」算出来 —— 否则这个缺口什么时候闭合没人知道。
        NEED2=$(( (GROUP_MAX * 2 + 59) / 60 * 60 ))
        printf '  ⚠ 余量不足 2×：最长一组 %d s，2× = %d s > 阈值 %s s（还差 %d s）\n' \
            "$GROUP_MAX" $(( GROUP_MAX * 2 )) "$BEAT_STALE_MAX" $(( GROUP_MAX * 2 - BEAT_STALE_MAX )) | tee -a "$LOG"
        printf '    按本轮数据，下一轮读 tests/_run_all.groupmax 后阈值会推到 %d s。\n' "$NEED2" | tee -a "$LOG"
    fi
    if [ "$DRY" != "1" ]; then
        printf '%d\n' "$GROUP_MAX" > "$GROUPMAX_F" 2>/dev/null || true
    fi
fi
# ★ 组数核对（见顶部 DECLARED_GROUPS 的注释）。**只在真跑完时**才有意义，
#   所以放在 ⑥ 之后；判定进 FAIL ⇒ 会体现在总判定里，不会被「个别组全绿」掩盖。
if [ "$FAST" = "1" ]; then WANT_G=$DECLARED_GROUPS_FAST; else WANT_G=$DECLARED_GROUPS; fi
if [ "$GROUP_N" = "$WANT_G" ]; then
    printf '  组数核对：本次执行 %d 组 / 声明 %d 组 ✔\n' "$GROUP_N" "$WANT_G" | tee -a "$LOG"
else
    printf '\n\033[1m✘ 组数核对：本次执行 %d 组，但脚本声明 %d 组\033[0m\n' "$GROUP_N" "$WANT_G"
    printf '\n✘ 组数核对：执行 %d / 声明 %d（有组被删或被条件包住 ⇒ 根本没跑）\n' \
        "$GROUP_N" "$WANT_G" >> "$LOG"
    printf '  本次的组：%s\n' "${GROUP_LIST#|}" | tee -a "$LOG"
    FAIL=1
fi
printf '  本次的组：%s\n' "${GROUP_LIST#|}" | tee -a "$LOG"
if [ "$FAIL" = "0" ]; then
    VERDICT="✔ 全部通过"
else
    VERDICT="✘ 有失败项"
fi
# ★ 总判定**必须也进日志**：原来只用 echo 打到屏幕，于是打开日志看不到结论；
#   两轮混写时更是分不清哪行才是最后一句。现在它是日志的最后一行。
printf '── 总判定：%s（实测 %d s）──\n' "$VERDICT" "$ELAPSED" | tee -a "$LOG"
if [ "$DRY" = "1" ]; then
    printf '\033[1m★ 注意：本次是 --dry-run，一个判据都没跑 ⇒ 上面的「%s」只表示组数对得上，\033[0m\n' "$VERDICT"
    printf '\033[1m  （只有 run_step 与宿主回归那一段会空转；组标题 / 组数核对 / 锁判定仍是真的）\033[0m\n'
    printf '\033[1m  不代表代码是好的。真正的结论要跑 bash tests/run_all.sh。\033[0m\n'
fi
# ★ 无论红绿都报日志路径：下次出现「某组没输出汇总行」这种偶发时，
#   现场在文件里，不必靠重跑猜（重跑往往复现不出来）。
echo "   完整日志：$LOG"
exit $FAIL
