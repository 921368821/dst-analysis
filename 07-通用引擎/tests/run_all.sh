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

# ★★ P50㉘：**脚本真正开始的时刻**（在 ROOT / 锁 / 预检之前）。
#   为什么需要它：`T0` 是「拿到锁、准备开跑」，而收尾那句「总耗时」用的是
#   ELAPSED（T0 起算）。墙钟与 ELAPSED 之间那段（bash 启动 + ROOT 解析 +
#   锁判定 + preflight + env.sh + 变异残留还原 + git 洁净检查 + 端口基线快照）
#   **一直没人量过** —— 我只在注释里猜过「约 9 s」，而 2026-10-21 实测差 13.6 s。
#   ⇒ 猜值换成实测：收尾同时打「判据 ELAPSED / 脚本内墙钟 / 启动+锁判定」三个数。
#   ★ 还有一段**不在脚本测量范围里**的：bash 启动时的环境 shim（`BASH_ENV` 里定义
#     rm/unlink/rmdir 的那套）与 EXIT trap 的锁清理。dry-run 实测「外部墙钟 24.3 s
#     vs 脚本内 17.1 s」⇒ 约 7 s 在这两处，**两者各占多少我没有测，所以不写**。
T_ALL0=$(date +%s)

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
# ★★ P50㊸（B11）：**截断必须挪到拿到锁之后**（原位置就是这行，2026-10-21 移走）。
#   实测事故（15:48:19）：另一轮正在跑（PID 50445），我起了一轮想看新列，被锁正确地
#   拒了（rc=3）—— **但截断发生在 `mkdir` 拿锁之前** ⇒ 那一轮**已经写完的组日志被清空**。
#   后果不是「少几行」：它让那一轮的「轮末对账」判红（日志 15 行 vs 组数 21），
#   一条**正确地**报出来的红，原因是另一条本该只读的路径。
#   ⇒ 锁的全部意义就是「保住现场」；一条被拒绝的启动**不许改写任何现场文件**。
#   ⚠ 它同时说明：`rc=3` 的「拒绝」此前并不是无副作用的。
#   （渲染之后的截断位置见下面「拿到锁」那一段。）

# ★★★ 运行锁（2026-10-20 实测事故）：两轮**并发**跑过一次，后果是**两轮都不可采信**：
#   · 后起的一轮 `: > "$LOG"` 把前一轮已经写好的日志**清空**（**2026-10-21 已修**：
#     截断挪到拿到锁之后 —— 见下面的 P50㊸。当时那行确实没有锁保护，而且连
#     「被锁拒绝的启动」也会执行它，于是「拒绝」并不无副作用）；
#   · 两轮又各自 `tee -a` 追写，于是「⑤ 的组标题」下面跟着「② 的 A1 启动」；
#   · 端口互撞（8791 两轮都要）⇒ 服务器互相顶掉，跑完留 3 个端口还在 LISTENING。
#   ⇒ 并发不是「更快」，是**把现场毁掉**。锁用 `mkdir`（**原子**）实现 —— 文件+PID 的写法
#     在「两轮同时启动」时会两边都以为自己拿到了锁。锁里记 PID + 起始时间，人为可读、可手删。
LOCKD="$ROOT/tests/_run_all.lock.d"
BEAT="$LOCKD/beat"

# ★★ P50㉕：**输出层心跳**。命令层的 beat 只证明「进程还在」，不证明「它还在干活」。
#   一个卡死的组会一直活着、一直打 beat（锁那边也就一直正确地拒绝下一轮），
#   而人只能干等 —— 日志上看不出它已经多久没动了。
#   这里记一个「日志大小连续多少秒没长」，超过阈值就打一条警告。
#   ★ 只警告、不改 rc：先测量几轮，确认 ②f（555 s 的变异测试）这种长组不会误报，
#     再决定是否收紧成判红。阈值可被 RT_QUIET_WARN 覆盖（测试用）。
QUIET_WARN=${RT_QUIET_WARN:-300}
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
# ★★ P50㊸（B11）：**拿到锁之后**才截断日志。
#   放在这里的理由只有一条：在这之前的每一条退出路径（锁被占 / 子进程还活着）都是
#   「我什么都不该动」。截断写在它们上游，等于让一次**被拒绝**的启动去改别人的现场。
#   实测代价：15:48:19 那次 rc=3 把在跑那轮已写完的 15 行组日志清空了（见文件头）。
: > "$LOG" 2>/dev/null || true
printf '%s\n%s\n' "$$" "$(date '+%Y-%m-%d %H:%M:%S')" > "$LOCKD/pid"
date +%s > "$BEAT" 2>/dev/null || true      # ★ 第一拍：拿到锁就算活着
printf '   （锁的 beat 阈值：%s s，来源：%s）\n' "$BEAT_STALE_MAX" "$BEAT_STALE_SRC" >> "$LOG"
# ★ P50㉒：**先写 done、再删目录**。顺序不能反：删成功就什么都不需要，删失败（被拦/权限）时 done 必须已经在。
trap 'date +%s > "$LOCKD/done" 2>/dev/null; rm -rf "$LOCKD"' EXIT INT TERM
T0=$(date +%s)
# ★ P50㉖-b：**起点要现在就记下来**。摘要块和 rounds.tsv 里那栏叫「开始时间」，
#   而我第一版是在**打印时**才取 date —— 那时已经跑完二十几分钟，于是它写的是结束时刻。
#   「标签写 A、代码取 B」是本工程出现最多的一类错（§9bg 的 ① 组耗时同形）。
T0_STR=$(date '+%Y-%m-%d %H:%M:%S')
printf '══ run_all 开始 %s · PID %s · 参数 %s\n' \
    "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "${1:-（全量）}" >> "$LOG"

# 跑一条命令：输出同时进 stdout 与日志，**返回命令自己的退出码**（不是 tee 的）
run_step() {
    # ★★ `--dry-run`（2026-10-20 加）：**只数组、不跑**。
    #   为什么需要：组数核对是「运行时」判据，而验它一次要 11 分钟（--fast）——
    #   等于「这条判据自己没法被便宜地验证」，于是我把声明值写错（17 vs 真实的 18）
    #   也只能在跑完之后才知道。dry-run 把这条路压到秒级：改完 run_all 先 dry 一遍。
    #   ★ P50㉓ 更正：这行原来写「压到 3 秒」，而 ③ 组**没走 run_step**、dry 时照跑 14 个
    #     lua 入口（实测 54 s）。现在 ③ 也走 DRY 分支，dry-run 从 64 s 降到 **约 12 s**（实测 12~13 s，随负载漂）。
    #     ★ P50㉖ 更正口径：12 s 是**脚本内的 ELAPSED**（T0 起算），墙钟比它大。
    #     ★★ P50㉘ 再更正：㉖ 当时把差额说成「约 9 s，在 preflight / env.sh /
    #       bash 启动上」——**那是猜的**。2026-10-21 逐项实测：bash 启动 0.34 s、
    #       `. tools/env.sh` **3.50 s**、`preflight.sh` 1.00 s，合计 4.84 s，
    #       而当天 dry-run 的差额是 **13.6 s**（ELAPSED 16 / 墙钟 29.6）。
    #       差额里还有锁判定、`--heal`、`git status`、端口基线快照，且**随负载漂**。
    #       ⇒ 结论：这段不该在注释里写任何数字，应由收尾的「判据 / 脚本内墙钟」两行给出。
    #       此前这句写的是点值「10 s」，并把这 10 s 里的 4 s 归因给第一组 ——
    #       那个 4 s 其实是「GROUP_T0 用了 T0」造成的错记（见 GROUP_T0 的注释），
    #       而 10 s 本身也会随负载漂（10~12 s 都实测到过）。
    #       ⇒ 会漂的数字写成点值必然过期，要写就写**口径 + 量级**。
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
    # ★★ P50㉕-b：tee 同时写两个目标 —— 总日志给人看，cur.out 给判据看。
    #   为什么不能用总日志：`$LOG` 是全局共享的（hr() 往里写标题、别的进程也写），
    #   它的大小**不代表这一组的输出**：这一组静默而别人在写 ⇒ 漏报；
    #   这一组在写而没有别人写 ⇒ 误报。反向用例已经证实过后一种（39 s 持续输出被报警）。
    : > "$LOCKD/cur.out" 2>/dev/null || true
    "$@" > >(tee -a "$LOG" "$LOCKD/cur.out" >/dev/null) 2>&1 &
    local _pid=$! _rc=0
    #   ★ _lastsz 初始必须是空串，不能是 0：文件刚建时 wc -c 也是 0，
    #     两下相等 ⇒ 第一轮就凑满一个周期的静默 ⇒ **与有没有输出无关地报警**。
    #     正向用例当时「通过」只是因为它也走这条路，不是因为静默被识别。
    local _lastsz="" _quiet=0 _warned=0
    while kill -0 "$_pid" 2>/dev/null; do
        date +%s > "$BEAT" 2>/dev/null || true
        # ★★ P50㉕ 输出层心跳：这一轮（约 15 s）日志有没有长。
        #   读的是**这一组专属**的 cur.out 的大小（每次 run_step 开头截断），
        #   不是 $LOG —— 总日志是共享的，它长了不代表这一组在干活。
        #   也不是 mtime：mtime 会被别的进程蹭到。
        _sz=$(wc -c < "$LOCKD/cur.out" 2>/dev/null || echo 0)
        _sz=$(printf "%s" "$_sz" | tr -dc "0-9")
        if [ -n "$_lastsz" ] && [ "$_sz" = "$_lastsz" ]; then
            _quiet=$(( _quiet + 15 ))
            if [ "$_quiet" -ge "$QUIET_WARN" ] && [ "$_warned" = "0" ]; then
                _warned=1
                printf '  ⚠ 这一组已经 %d 秒没有任何输出（进程仍在，pid %s）—— 可能卡死，也可能只是长时间不打印：%s\n' \
                    "$_quiet" "$_pid" "${GROUP_LAST:-?}" | tee -a "$LOG"
            fi
        else
            _lastsz=$_sz
            _quiet=0
        fi
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
# ★★ P50㉞：preflight 单独计时。它**在** ELAPSED 里（T0 之后跑），但此前没有任何一行
#   把它量出来 ⇒ 收尾那句「差额 N s」里它是一份没有名字的时间。
T_PF0=$(date +%s)
if run_step bash "$ROOT/../tools/preflight.sh"; then :; else GATE=1; fi
T_PF=$(( $(date +%s) - T_PF0 ))
if [ "$GATE" != "0" ]; then
    printf '\n\033[1m✘ 环境自检不过 —— 后面的组一个都没跑（这不是代码失败，是环境缺失）\033[0m\n'
    printf '\n✘ 环境自检不过 —— 后续各组未执行\n' >> "$LOG" 2>/dev/null || true
    exit 2
fi

# ★★ P50㉞：`. env.sh` 实测 3.5 s（2026-10-21），比 preflight 还贵，此前同样没量。
T_ENV0=$(date +%s)
. "$ROOT/../tools/env.sh" || exit 2
T_ENV=$(( $(date +%s) - T_ENV0 ))
# ★★ 源码洁净闸门（2026-10-20 实测事故）：
#   ②f 的变异测试是「**把源码改坏** → 看判据红不红 → 还原」；还原写在 `finally` 里，
#   而 `finally` 只在进程还活着时执行。任何硬中断（超时 / Ctrl-C / taskkill /F /
#   整轮被审计脚本掐掉）都会让源码**停在篡改态**。实测现场：`rt/rt_boot.lua` 的
#   `in_light_at` 停在 `if true then return true`、`player_state` 的 hunger 读成 max ——
#   之后每一组都在这份**假源码**上跑，夜间光照 / 饥饿判据**全绿**，日志看着漂亮。
#   ⇒ 两道：① 先跑 `falsify_server.py --heal`（有标记就按原文写回并大声说明）；
#          ② 再看 git：`rt/` 与 `06-引擎复刻` 有没有未提交改动，有就要人明确放行。
# ★★ P50㉞：这一段（还原变异 + git 洁净 + 端口基线快照）也算进 ELAPSED，一并计时。
T_PREP0=$(date +%s)
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
T_PREP=$(( $(date +%s) - T_PREP0 ))
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
# ★★ P50㊷（B4）：轮次表第 9 列 = 这一轮跑的是全量还是 `--fast`。
#   由 FAST **推**出来，不接受外部填 —— 手填的字段两天后就会和实际跑的对不上。
RUN_PARAM=full
if [ "$FAST" = "1" ]; then RUN_PARAM=fast; fi

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
# ★★ P50㉞：各组耗时之和。只记「最长一组」的话，`ELAPSED - 最长一组` 说明不了任何事；
#   有了和，才能与 ELAPSED 对账（见收尾的「耗时分解」）。
GROUP_SUM=0
#
# ★★ P50㉖：这里原来写 `GROUP_T0=$T0`，而 `T0` 是**全量起始**（preflight 之前）——
#   于是**第一组**（① Node 客户端验证）的 ⏱ 里混进了 preflight / env.sh / 变异残留还原 /
#   git 洁净检查 / 端口基线快照，实测报到 6~7 s，而它自己只跑 1 s。
#   后果不只是数字难看：① 是「最长一组」的候选，`GROUP_MAX` 会被它抬高 ⇒ 写进
#   `_run_all.groupmax` ⇒ 下一轮的心跳阈值也跟着虚高（余量判定失去意义）。
#   而且我此前在 run_step 的注释里把那段 preflight **归因给了第一组**（「第一组那 4 s
#   是 preflight，不属任何判据」）—— 句子对了，位置错了：它就不该记在 ① 头上。
#   ⇒ 改成第一组开头才置位（见 hr()）。
GROUP_T0=""
GROUP_LAST=""
_tally() {
    # 结算**上一组**：从它开头到现在。第一组之前 GROUP_LAST 为空，跳过。
    [ -z "$GROUP_LAST" ] && return 0
    local now dur
    now=$(date +%s)
    dur=$(( now - GROUP_T0 ))
    printf '\033[2m⏱ %s 用时 %d s\033[0m\n' "$GROUP_LAST" "$dur"
    printf '⏱ %s 用时 %d s\n' "$GROUP_LAST" "$dur" >> "$LOG" 2>/dev/null || true
    GROUP_SUM=$(( GROUP_SUM + dur ))
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
    # ★ P50㉖：第一组从这里开始计时（GROUP_T0 为空 ⇒ 之前什么都没在跑）。
    [ -n "$GROUP_T0" ] || GROUP_T0=$(date +%s)
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
# ★★ P50㉗：**先证明「还原路径」是活的，再去改别人的源码。**
#   ②f 的每条篡改都靠 `finally` 把原文写回；被硬中断时靠 `heal_leftover()`。
#   而后者此前**零测试** —— 2026-10-20 23:10 那次中断把 `rt/rt_boot.lua` 停在
#   `if true then return true end`，整整 10 小时 3 分；它今早能还原成功是**运气**。
#   这条自测第一次当判据用就抓出真缺陷（写用 newline=""、读不用 ⇒ 带 \r 的文件
#   永远比不平 ⇒ 写对了却报失败），见 开发计划 §9bh。
#   5 条用例 / 0.2 s / 沙箱，不碰仓库文件，所以放在真变异之前不拖慢多少。
if run_step "$PY" -u tests/falsify_server.py --selftest-heal; then :; else FAIL=1; fi
# ★★ P50㉜：源码闸门自己也要证明会响（9 条合成用例，含「pid 已死 ⇒ 脏」与「heal 逐字节写回」）
if run_step "$PY" -u tests/_src_guard.py --selftest; then :; else FAIL=1; fi
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
    # ★★ P50㉚：`tests/_run_all.rounds.tsv` 直接决定**下一轮锁阈值**（§9bc），此前零守卫：
    #   手改 `_run_all.groupmax` 没人比对；表里能出现「最长 800 s 而阈值 600 s」这种自相矛盾的行。
    #   两条都要跑：先证明判据会响（--selftest），再拿真表撞一遍。
    #   ★ 表是 gitignore 的（新克隆上没有）⇒ 缺表时**明说跳过**：不许报绿（没验过）也不许报红（不是错）。
    if run_step "$PY" -u tools/check_rounds.py --selftest; then :; else FAIL=1; fi
    if [ -f "$ROOT/tests/_run_all.rounds.tsv" ]; then
        # ★ P50㉝：`--no-log` —— 这里**不能**与日志对账：④ 组跑在中途，
        #   那一刻日志还没写全，而表的最后一行是**上一轮**的记录 ⇒ 必报假红。
        #   ★ P50㊶ 不再写位次：`--fast` 里 ④ 其实是第 16 组（它前面有 15 个 hr），
        #     全量也不是 14 —— 位次会随加组漂，会漂的数字写成点值必然过期（§9be）。
        #   日志对账挪到本轮所有组跑完之后（见收尾的「轮末对账」）。
        if run_step "$PY" -u tools/check_rounds.py --no-log; then :; else FAIL=1; fi
    else
        printf '    （还没有 tests/_run_all.rounds.tsv —— 首次运行，本检查**跳过**，不是通过）\n'
    fi
    # ★★ P50㊸（B11）：守 `run_all.sh` 自己的**顺序** —— `: > "$LOG"` 必须在拿到锁之后。
    #   为什么需要一条静态判据：修完之后我只用「伪锁 + 哨兵」手验过一次，
    #   而手工验证不防**退回去**。这条读源码判顺序，零副作用（不碰任何日志/锁）。
    #   两条都要跑：先证明判据会响（--selftest），再拿真文件撞一遍。
    if run_step "$PY" -u tools/check_run_all_order.py --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u tools/check_run_all_order.py; then :; else FAIL=1; fi
    # ★ H6：根目录三份基线文档的过期数字（verify_plan 只扫 07 目录，扫不到它们）
    # ★ P50㊱：`--selftest` 此前**从来没被调用**（工具里写着用法，run_all 两处都不带它）——
    #   「规则既不空转也不误报」这句话因此没被验证过。顺带抓到自检本身也错：
    #   它把「19 组 178 项」当成当前值 ⇒ 给「只认一代过期值」的缺陷盖章。
    if run_step "$PY" -u "$ROOT/../tools/audit_root_docs.py" --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u "$ROOT/../tools/audit_root_docs.py"; then :; else FAIL=1; fi
    # ★ P50㊴：行尾一致性（无 `\r\r\n`、无 CRLF/裸 LF 混排）。
    #   ㊳ 修的是插入器，判据没有 —— 换个入口就复发。作用域排除上游快照，
    #   且排除数量会被打印出来（静默白名单比没有更糟，见 §9bq）。
    if run_step "$PY" -u "$ROOT/../tools/check_eol.py" --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u "$ROOT/../tools/check_eol.py"; then :; else FAIL=1; fi
    # ★ P50㊵：轮次账本的**留痕对账**。④ 跑在写表之前 ⇒ 「最后一行」是上一轮，
    #   于是这条等于要求：每一轮的结论必须在下一轮开跑前已写进阶段进度文档。
    #   第一次跑就红在「12:56:00 那轮文档里一个字都没有」上 —— 抓到的是真事。
    if run_step "$PY" -u "$ROOT/../tools/check_doc_rounds.py" --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u "$ROOT/../tools/check_doc_rounds.py"; then :; else FAIL=1; fi
    # ★★ 2026-10-21 19:00（开发计划 §9cg）：**判据变松了，检查它的东西也跟着变松**。
    #   上面这一串 `--selftest` 一直是「只看 rc」：用例被删掉一半、剩下的一半全过，
    #   rc 仍是 0，本组照样绿。各工具现在自带 `WANT_CASES` 自守（拦「用例被删、常量没动」），
    #   但把用例和常量**一起**改小就拦不住 ⇒ 外部锚点是 tools/case_counts.txt。
    #   三方对账（清单 / 工具自守 / 实跑输出）在这一步一次做完；提交闸门第 ⑨ 步也跑它。
    if run_step "$PY" -u "$ROOT/../tools/check_case_counts.py"; then :; else FAIL=1; fi
    # ★ M9：注释版**自身**完整性（U+FFFD / 二进制被当文本重写）。
    #   这一条**不需要原版副本**就能判红 —— 原版丢失期间它是唯一还在工作的
    #   「只增注释」守卫（verify-annotated 此时只能报 2＝无法复验）。
    #   （这一行原来**重复出现两次**，等于同一条判据跑两遍、白等 3 秒；已合并）
    # ★ P50㊱：这两个 `--selftest` 此前**从来没跑过**（用法写在工具里，run_all/pre-commit 都不带）。
    #   实测 0.27 s + 0.27 s，没理由省。`verify-annotated.mjs` 更彻底 —— 它在 run_all 里
    #   连正文调用都没有，只在一句注释里被提到。
    if run_step "$NODE" "$ROOT/../tools/check-annotated-integrity.mjs" --selftest; then :; else FAIL=1; fi
    if run_step "$NODE" "$ROOT/../tools/verify-annotated.mjs" --selftest; then :; else FAIL=1; fi
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
    # ★★ P50㉚：`tests/_run_all.rounds.tsv` 直接决定**下一轮锁阈值**（§9bc），此前零守卫：
    #   手改 `_run_all.groupmax` 没人比对；表里能出现「最长 800 s 而阈值 600 s」这种自相矛盾的行。
    #   两条都要跑：先证明判据会响（--selftest），再拿真表撞一遍。
    #   ★ 表是 gitignore 的（新克隆上没有）⇒ 缺表时**明说跳过**：不许报绿（没验过）也不许报红（不是错）。
    if run_step "$PY" -u tools/check_rounds.py --selftest; then :; else FAIL=1; fi
    if [ -f "$ROOT/tests/_run_all.rounds.tsv" ]; then
        # ★ P50㉝：`--no-log` —— 这里**不能**与日志对账：④ 组跑在中途，
        #   那一刻日志还没写全，而表的最后一行是**上一轮**的记录 ⇒ 必报假红。
        #   ★ P50㊶ 不再写位次：`--fast` 里 ④ 其实是第 16 组（它前面有 15 个 hr），
        #     全量也不是 14 —— 位次会随加组漂，会漂的数字写成点值必然过期（§9be）。
        #   日志对账挪到本轮所有组跑完之后（见收尾的「轮末对账」）。
        if run_step "$PY" -u tools/check_rounds.py --no-log; then :; else FAIL=1; fi
    else
        printf '    （还没有 tests/_run_all.rounds.tsv —— 首次运行，本检查**跳过**，不是通过）\n'
    fi
    # ★★ P50㊸（B11）：守 `run_all.sh` 自己的**顺序** —— `: > "$LOG"` 必须在拿到锁之后。
    #   为什么需要一条静态判据：修完之后我只用「伪锁 + 哨兵」手验过一次，
    #   而手工验证不防**退回去**。这条读源码判顺序，零副作用（不碰任何日志/锁）。
    #   两条都要跑：先证明判据会响（--selftest），再拿真文件撞一遍。
    if run_step "$PY" -u tools/check_run_all_order.py --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u tools/check_run_all_order.py; then :; else FAIL=1; fi
    # ★ P50㊱：`--selftest` 此前**从来没被调用**（工具里写着用法，run_all 两处都不带它）——
    #   「规则既不空转也不误报」这句话因此没被验证过。顺带抓到自检本身也错：
    #   它把「19 组 178 项」当成当前值 ⇒ 给「只认一代过期值」的缺陷盖章。
    if run_step "$PY" -u "$ROOT/../tools/audit_root_docs.py" --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u "$ROOT/../tools/audit_root_docs.py"; then :; else FAIL=1; fi
    # ★ P50㊴：行尾一致性（无 `\r\r\n`、无 CRLF/裸 LF 混排）。
    #   ㊳ 修的是插入器，判据没有 —— 换个入口就复发。作用域排除上游快照，
    #   且排除数量会被打印出来（静默白名单比没有更糟，见 §9bq）。
    if run_step "$PY" -u "$ROOT/../tools/check_eol.py" --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u "$ROOT/../tools/check_eol.py"; then :; else FAIL=1; fi
    # ★ P50㊵：轮次账本的**留痕对账**。④ 跑在写表之前 ⇒ 「最后一行」是上一轮，
    #   于是这条等于要求：每一轮的结论必须在下一轮开跑前已写进阶段进度文档。
    #   第一次跑就红在「12:56:00 那轮文档里一个字都没有」上 —— 抓到的是真事。
    if run_step "$PY" -u "$ROOT/../tools/check_doc_rounds.py" --selftest; then :; else FAIL=1; fi
    if run_step "$PY" -u "$ROOT/../tools/check_doc_rounds.py"; then :; else FAIL=1; fi
    # ★★ 2026-10-21 19:00（开发计划 §9cg）：**判据变松了，检查它的东西也跟着变松**。
    #   上面这一串 `--selftest` 一直是「只看 rc」：用例被删掉一半、剩下的一半全过，
    #   rc 仍是 0，本组照样绿。各工具现在自带 `WANT_CASES` 自守（拦「用例被删、常量没动」），
    #   但把用例和常量**一起**改小就拦不住 ⇒ 外部锚点是 tools/case_counts.txt。
    #   三方对账（清单 / 工具自守 / 实跑输出）在这一步一次做完；提交闸门第 ⑨ 步也跑它。
    if run_step "$PY" -u "$ROOT/../tools/check_case_counts.py"; then :; else FAIL=1; fi
    # ★ L1：协议常量单源 / ★ M8：注释流水线旧绝对路径绝迹（与 --fast 分支同一组判据）
    if run_step "$NODE" "$ROOT/../tools/gen-protocol-schema.mjs" --check; then :; else FAIL=1; fi
    if run_step "$NODE" "$ROOT/../tools/relocate-paths.mjs" --check; then :; else FAIL=1; fi
    # ★ P46/P48：spec 无乱码 + 派生原版与 spec 一致（与 --fast 分支同一组判据）
    if run_step "$NODE" "$ROOT/../tools/fix-spec-fffd.mjs" --check; then :; else FAIL=1; fi
    if [ -f "$ROOT/../_baseline/derived-scripts/MANIFEST.json" ]; then
        if run_step "$NODE" "$ROOT/../tools/derive-pristine.mjs" --check; then :; else FAIL=1; fi
    fi
    # ★★ P50㊱-e：这两个自检原来只接在 `--fast` 分支（那儿有 check-annotated-integrity 的
    #   正文调用），而**全量才是权威那一轮** —— 12:33 那轮日志里 `5/5` / `10/10` 零命中，
    #   就是这条的证据。0.5 s 的事，两边都跑。
    if run_step "$NODE" "$ROOT/../tools/check-annotated-integrity.mjs" --selftest; then :; else FAIL=1; fi
    if run_step "$NODE" "$ROOT/../tools/verify-annotated.mjs" --selftest; then :; else FAIL=1; fi

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
# ★★ P50㉘ 再更正：`T0 - T_ALL0` 只覆盖**启动 + 锁判定**（ROOT 解析 / 拿锁 / 三段判定）。
#   我第一版把标签写成「启动+预检」——**错的**：`preflight.sh` 在 T0 **之后**跑，它在 ELAPSED 里。
#   暴露方式：第一轮全量打出来「另含 启动+预检 1 s」，而 preflight 单独实测 1.0 s、
#   env.sh 3.5 s —— 1 s 装不下它们。**数字对不上 ≠ 数字错了，也可能只是标签错了。**
PRELUDE=$(( T0 - T_ALL0 ))
WALL=$(( ELAPSED + PRELUDE ))
# ★★ P50㉞（backlog B2）：`ELAPSED - 各组之和` 那段差额**逐项给名字**。
#   此前它只被归成一句「另有启动/预检 N s」，而 preflight / env.sh / 变异还原 /
#   git 洁净检查 / 端口快照 / 参数解析**一个都没单独量过** —— 注释里我写过「约 21 s」，
#   今早实测 31.8 s（ELAPSED 16 s）：会漂的数字写成点值必然过期。
#   恒等式：各组 + 各项准备 + **未归因** = ELAPSED。
#   「未归因」必须显式打印 —— 把它悄悄摊进「准备」里，就等于没有对账。
PREP_SUM=$(( T_PF + T_ENV + T_PREP ))
GAP=$(( ELAPSED - GROUP_SUM ))
UNATTR=$(( GAP - PREP_SUM ))
printf '  耗时分解    ELAPSED %s s = 各组 %s s（%s 组）+ 准备 %s s + 未归因 %s s\n' \
    "$ELAPSED" "$GROUP_SUM" "$GROUP_N" "$PREP_SUM" "$UNATTR" | tee -a "$LOG"
printf '  准备明细    preflight %s s ｜ env.sh %s s ｜ 还原+git 洁净+端口快照 %s s\n' \
    "$T_PF" "$T_ENV" "$T_PREP" | tee -a "$LOG"
if [ "$UNATTR" -lt 0 ]; then
    # 重复计时：某一步被算了两次，或某组的时间被并进了准备里。
    printf '\n\033[1m✘ 未归因是负数（%s s）：各项准备与各组之和加起来比 ELAPSED 还多 ⇒ 有重复计时\033[0m\n' "$UNATTR"
    printf '✘ 耗时分解：未归因 %s s < 0（重复计时）\n' "$UNATTR" >> "$LOG"
    FAIL=1
elif [ "$UNATTR" -gt 5 ]; then
    # 漏计：ELAPSED 里有时间没有名字（新加的步骤没量，或某组没走 _tally）。
    printf '  ⚠ 未归因 %s s > 5 s：ELAPSED 里有 %s 秒没有名字（新加的步骤没量 / 某组没进 _tally）\n' \
        "$UNATTR" "$UNATTR" | tee -a "$LOG"
    printf '⚠ 耗时分解：未归因 %s s > 5 s\n' "$UNATTR" >> "$LOG"
fi
printf '\n'
# ★★ P50㉓：**这一轮自己检查自己用的阈值**。
#   判据（危险的那一侧）：最长的一组 ≥ 阈值 ⇒ 单组跑得比阈值还久 ⇒ 父 shell 一死，
#   beat 会在那一组**中途**变陈旧 ⇒ 下一轮把「还在跑」判成「残留」⇒ 清锁、清日志、抢端口。
#   所以这条一旦越界必须**判红**（不是警告）—— 它是一条安全边界，不是性能指标。
#   注意 dry-run 不写 groupmax：那时每组 0 s，落盘会把上一轮的真实数据覆盖成 0。
# ★★ P50㉟：`WANT_G` 原来在**下面**（组数核对那儿，约 40 行之后）才算，
#   而写 `groupmax` 在它**之前** —— 于是「组数不符」发现得太晚：那一轮的阈值早就写下去了。
#   阈值是下一轮锁的安全边界（§9bc），它只配由**完整**的一轮推。
if [ "$FAST" = "1" ]; then WANT_G=$DECLARED_GROUPS_FAST; else WANT_G=$DECLARED_GROUPS; fi
# 写不写的**决定**在这里算好（执行仍在下面原位），这样中间的余量提示才能说真话。
GM_MAY=0
if [ "$DRY" != "1" ] && [ "$FAST" != "1" ] && [ "$GROUP_N" = "$WANT_G" ]; then
    GM_MAY=1
fi
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
        # ★ P50㉟：只在**真的写了** groupmax 时才这么承诺。
        if [ "$GM_MAY" = "1" ]; then
            printf '    按本轮数据，下一轮读 tests/_run_all.groupmax 后阈值会推到 %d s。\n' \
                "$NEED2" | tee -a "$LOG"
        else
            printf '    （本轮**不写** groupmax —— 见下面那条，下一轮阈值不会变）\n' | tee -a "$LOG"
        fi
    fi
    # ★★ P50㉖-b：`--fast` **也不许写**。
    #   ★★ P50㉞ 更正：这一段原来写「fast 跳过的正是最慢的三组（②f 605 s / ③ / ⑤），
    #      于是 GROUP_MAX 只有 ~321 s」—— **两处数字都是错的**。2026-10-21 实测：
    #      fast **跑** ②f（本轮 586 s，正是它最长），跳的是 ②c 规模与并发 / ③ 宿主
    #      14 入口 / ⑤ 06 三件套（三者合成一条 hr 提示 ⇒ 20 - 3 + 1 = 18）。
    #      所以 fast 的最长一组不是「偏小」，而是**来自另一个组集合**：本轮 fast 586 s、
    #      全量 575 s —— 谁大谁小取决于当轮负载，两个数不能互相推。
    #   结论不变，理由换成真的那条：fast 不跑 ②c / ③ / ⑤，那三组里的失败在 fast 下
    #   根本不存在；它的「最长一组」也只覆盖 18 个组。阈值必须由**全量**的最长单组推
    #   （§9bc 同一条安全边界：阈值低于最长单组 ⇒ 父 shell 一死，beat 会在那一组中途
    #   变陈旧 ⇒ 下一轮把「还在跑」当成「残留锁」清掉）。
    # ★★ P50㉟：条件是 `GM_MAY`（上面算好的），其中多了 `GROUP_N == WANT_G` 这一半。
    if [ "$GM_MAY" = "1" ]; then
        printf '%d\n' "$GROUP_MAX" > "$GROUPMAX_F" 2>/dev/null || true
    elif [ "$FAST" = "1" ]; then
        printf '  （--fast：本轮最长一组 %d s 不代表全量，**不写** tests/_run_all.groupmax）\n' \
            "$GROUP_MAX" | tee -a "$LOG"
    elif [ "$DRY" != "1" ]; then
        # 组数不符：这一轮不完整，最长一组可能不是真的最长 ⇒ 阈值不许由它推。
        printf '  ✘ 本轮只跑了 %d/%d 组 ⇒ **不写** tests/_run_all.groupmax（阈值必须由完整的一轮推）\n' \
            "$GROUP_N" "$WANT_G" | tee -a "$LOG"
    fi
fi
# ★ 组数核对（见顶部 DECLARED_GROUPS 的注释）。**只在真跑完时**才有意义，
#   所以放在 ⑥ 之后；判定进 FAIL ⇒ 会体现在总判定里，不会被「个别组全绿」掩盖。
# ★ P50㉟：`WANT_G` 已在写 groupmax 之前算好（见那儿），这里不再重算。
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
# ★★ P50㉝：**轮末对账** —— 日志里每组一行的 `⏱` ↔ 即将写进 rounds.tsv 的这一行。
#   为什么不在 ④ 组里做：④ 跑在第 14 位，那一刻日志只有 14 行，而表的最后一行是
#   **上一轮**的 20/20 ⇒ 必报「14 ≠ 20」。判据没错、位置错了，而一条每轮都误报的
#   判据，几次之后人就开始忽略它 —— 真正的错账会混在同一句话里被一起忽略。
#   能对账的时刻只有一个：本轮所有 `⏱` 都写完（⑥ 之后）、本轮的行还没写（在下面）。
#   ⇒ 拿**即将写入的那三个变量**去撞日志，而不是去读表。
if [ -f "$ROOT/tests/_run_all.log" ]; then
    if run_step "$PY" -u "$ROOT/tools/check_rounds.py" --log "$ROOT/tests/_run_all.log" \
        --wire-groups "$GROUP_N/$WANT_G" --wire-max "$GROUP_MAX" \
        --wire-name "${GROUP_MAX_NAME:-（无一）}"; then :; else FAIL=1; fi
else
    printf '    （没有 tests/_run_all.log —— 轮末对账**没有执行**，不是通过）\n'
fi
if [ "$FAIL" = "0" ]; then
    VERDICT="✔ 全部通过"
else
    VERDICT="✘ 有失败项"
fi
# ★ 总判定**必须也进日志**：原来只用 echo 打到屏幕，于是打开日志看不到结论；
#   两轮混写时更是分不清哪行才是最后一句。现在它是日志的最后一行。
printf '── 总判定：%s（判据 %d s｜脚本内墙钟 %d s = 判据 + 启动/锁 %d s｜退出清理不在内）──\n' \
    "$VERDICT" "$ELAPSED" "$WALL" "$PRELUDE" | tee -a "$LOG"
if [ "$DRY" = "1" ]; then
    printf '\033[1m★ 注意：本次是 --dry-run，一个判据都没跑 ⇒ 上面的「%s」只表示组数对得上，\033[0m\n' "$VERDICT"
    printf '\033[1m  （只有 run_step 与宿主回归那一段会空转；组标题 / 组数核对 / 锁判定仍是真的）\033[0m\n'
    printf '\033[1m  不代表代码是好的。真正的结论要跑 bash tests/run_all.sh。\033[0m\n'
fi
# ★★ P50㉖：**本轮摘要**（给人抄，不用再从几百行里捞）。
#   起因：§9be / §9bf 里的「实测 1243 s / 534 s / 1193 s」全是我从屏幕上**手抄**进文档的，
#   而手抄没有任何校验 —— 抄错一位数，文档就永久错一位数（verify_plan 只核对项数/编号，
#   不核耗时）。这里把这一轮的四个量**一次打全**，并同时落盘成 TSV（追加式，一轮一行），
#   以后文档直接引用某一行，而不是转述。
#   ★ 只打到屏幕、**不 tee 进日志**：总判定必须是日志的最后一行（上面那条约定）。
if [ "$DRY" != "1" ]; then
    ROUNDS="$ROOT/tests/_run_all.rounds.tsv"
    # ★★ P50㊲：变异 / 反向验证的轮次**不写表**。
    #   今天实测的坑：㉟ 的反向验证把 `DECLARED_GROUPS` 改成 19 跑了一轮，
    #   于是表里多了一行「20/19」，而判据（执行数 > 声明数 ⇒ 账目坏了）**必须**判它红
    #   ⇒ 从此每一轮全量都红在那一行上（12:11 那轮就是这样）。
    #   错不在判据，在于「实验产物写进了账本」。出口比白名单干净：
    #   判据不用学会忽略矛盾，变异轮的数字从一开始就不进来。
    if [ "${RT_NO_ROUNDS_ROW:-0}" = "1" ]; then
        printf '  （RT_NO_ROUNDS_ROW=1：本轮**不写** rounds.tsv —— 变异/反向验证的数字不是一轮）\n' \
            | tee -a "$LOG"
    fi
    if [ "${RT_NO_ROUNDS_ROW:-0}" != "1" ] && [ ! -f "$ROUNDS" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "开始时间" "判定" "组数" "总耗时_s" "最长一组" "最长_s" "阈值_s" "HEAD" "参数" \
            > "$ROUNDS" 2>/dev/null || true
    fi
    if [ "${RT_NO_ROUNDS_ROW:-0}" != "1" ]; then
        # ★★ P50㊷（B4）：第 9 列「参数」。
        #   为什么加：`--fast` 与全量都往 `组数` 里写自己**声明**的组数，于是「18/18」
        #   有两种来源（一轮 fast / 一轮全量少跑了两组），今天得靠 18/18 还是 20/20 去**猜**。
        #   猜错的代价不是难看：把 fast 的最长一组当成全量的安全边界，正是 §9bc 那条红线。
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$T0_STR" "$VERDICT" "$GROUP_N/$WANT_G" "$ELAPSED" \
            "${GROUP_MAX_NAME:-（无）}" "$GROUP_MAX" "$BEAT_STALE_MAX" \
            "$(git -C "$ROOT/.." rev-parse --short HEAD 2>/dev/null || echo "?")" \
            "$RUN_PARAM" >> "$ROUNDS" 2>/dev/null || true
    fi
    printf '\n\033[1m── 本轮摘要（可直接抄进文档）──\033[0m\n'
    printf '  开始      %s（结束 %s）\n' "$T0_STR" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '  判定      %s\n' "$VERDICT"
    printf '  组数      %s / %s\n' "$GROUP_N" "$WANT_G"
    printf '  参数      %s（写进轮次表第 9 列）\n' "$RUN_PARAM"
    printf '  总耗时    %s s（判据 ELAPSED）\n' "$ELAPSED"
    printf '  脚本内墙钟 %s s（= 判据 + 启动/锁判定 %s s；退出清理不在内）\n' "$WALL" "$PRELUDE"
    printf '  最长一组  %s（%s s）\n' "${GROUP_MAX_NAME:-（无）}" "$GROUP_MAX"
    printf '  已落盘    %s\n' "$ROUNDS"
fi
# ★ 无论红绿都报日志路径：下次出现「某组没输出汇总行」这种偶发时，
#   现场在文件里，不必靠重跑猜（重跑往往复现不出来）。
echo "   完整日志：$LOG"
exit $FAIL
