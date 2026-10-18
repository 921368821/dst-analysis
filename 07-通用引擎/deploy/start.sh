#!/usr/bin/env bash
#==============================================================================
# start.sh —— 启动实时引擎服务端（带**端口守卫**与日志）
#==============================================================================
# 用法：bash deploy/start.sh [端口] [hz]
#   bash deploy/start.sh            # 默认 8765 / 30 Hz
#   bash deploy/start.sh 9000 60
#   RT_RECORD=1 bash deploy/start.sh 8765 30   # 顺便录像 → deploy/logs/rec-8765.json
#
# ★ 录像为什么值得挂在启动脚本上：M7 的验收是「回放同一份输入日志 ⇒ 逐帧一致」，
#   而**只有真的在录**才有录像可用。开关在这里，判据在
#   `tests/test_rt.py` 的 B18~B21（含「进程被硬杀后录像仍在」）。
#
# ★ 为什么用脚本而不是直接跑 server.py：
#   ① **端口守卫**（server.py 内置）：端口被占则拒绝启动 —— Windows 的
#      SO_REUSEADDR 允许重复绑定，两条监听并存会让连接随机落到一个（静默脑裂）；
#   ② 日志落到 deploy/logs/ 并按日期分文件，出问题有据可查；
#   ③ 启动后**自动做一次健康检查**，不合格立刻报出来（不是「起完就算」）。
set -u
cd "$(dirname "$0")/.." || exit 1

PORT="${1:-8765}"
HZ="${2:-30}"
# ★ 路径与解释器**不再写在脚本里**：统一由工程根的 tools/env.sh 解析
#   （原来这里硬编码了用户目录，工作区一搬迁就整条链失效）。
. "$(cd "$(dirname "$0")/../.." && pwd)/tools/env.sh" || exit 2
LOGDIR="deploy/logs"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/server-$(date +%Y%m%d).log"

echo "── 启动前检查 ──────────────────────────────"
# 端口占用（与 server.py 内置守卫同一判据，这里先查一次，给出更早的提示）
# ★★ 用 Python 的 connect_ex 查，**不用 netstat** ——
#   实测：start.sh 里 `netstat ... | grep -q` 恒不匹配（这条管道在脚本环境里
#   取不到输出，而 `2>/dev/null` 把「命令找不到」这类错误也一起吞了），
#   于是明明有服务端在听，脚本却报「端口空闲」⇒ 起了**第二个服务端**，
#   两条监听并存（Windows SO_REUSEADDR 允许双绑）⇒ 静默脑裂。
#   ⇒ 判据必须**与 server.py 的 port_in_use() 完全一致**，且不依赖 PATH。
if ! "$PY" -c "
import socket, sys
s = socket.socket(); s.settimeout(1.0)
sys.exit(0 if s.connect_ex(('127.0.0.1', $PORT)) == 0 else 1)
" 2>/dev/null; then
    echo "  ✔ 端口 $PORT 空闲"
else
    echo "✘ 端口 $PORT 已被占用（有进程在监听）"
    echo "  → 先停掉旧进程：bash deploy/stop.sh $PORT"
    echo "  ⚠️ 不要直接再起一个：Windows 允许两个进程绑同一端口，"
    echo "     两条监听并存会让连接**随机**落到其中一个（静默脑裂）。"
    exit 2
fi

echo "── 启动 ────────────────────────────────────"
echo "  日志: $LOG"
# ★ 参数用**数组**拼，不用 `${VAR:+--record "$VAR"}` 那种写法：
#   后者在引号处理上不可靠（内层引号不会按你想的方式保留），出问题是**静默的参数错位**。
ARGS=(--port "$PORT" --hz "$HZ" --save-file "deploy/logs/world-$PORT.json")
RECORD=""
case "${RT_RECORD:-0}" in
    ""|0|no|off|false) : ;;
    *)  RECORD="$LOGDIR/rec-$PORT.json"
        ARGS+=(--record "$RECORD")
        echo "  ✔ 录像开启：$RECORD（每 5 s 落盘一次；硬杀也最多丢 5 s）" ;;
esac
nohup "$PY" -u rt/server.py "${ARGS[@]}" >> "$LOG" 2>&1 &
PID=$!
echo "  PID: $PID（已写入 deploy/logs/server.pid）"
echo "$PID" > "$LOGDIR/server.pid"

echo "── 健康检查（最多等 30 s）─────────────────"
for i in $(seq 1 30); do
    sleep 1
    if "$PY" -c "
import urllib.request, json, sys
try:
    h = json.loads(urllib.request.urlopen('http://127.0.0.1:$PORT/healthz', timeout=2).read().decode())
    sys.exit(0 if h.get('ok') and h['stats']['tick'] >= 0 else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
        echo "  ✔ /healthz 通过（第 ${i} 秒）"
        # 再等 2 s 确认 tick 真的在走（不是「起来但卡住」）
        T1=$("$PY" -c "
import urllib.request, json
print(json.loads(urllib.request.urlopen('http://127.0.0.1:$PORT/healthz', timeout=2).read().decode())['stats']['tick'])")
        sleep 2
        T2=$("$PY" -c "
import urllib.request, json
print(json.loads(urllib.request.urlopen('http://127.0.0.1:$PORT/healthz', timeout=2).read().decode())['stats']['tick'])")
        if [ "$T2" -gt "$T1" ]; then
            echo "  ✔ 世界在走（tick $T1 → $T2）"
            # ★★ 开了录像就**必须确认「真的在录」**：否则 `--record` 被忽略
            #   （比如参数没传进去）也不会有人知道，直到你真要回放的时候。
            #   这与「失败要吵」是同一条纪律：**开关打开了 ≠ 功能在跑**。
            if [ -n "$RECORD" ]; then
                R1=$("$PY" -c "
import urllib.request, json
print(json.loads(urllib.request.urlopen('http://127.0.0.1:$PORT/healthz', timeout=2).read().decode())['stats'].get('rec_ticks', -1))")
                sleep 2
                R2=$("$PY" -c "
import urllib.request, json
print(json.loads(urllib.request.urlopen('http://127.0.0.1:$PORT/healthz', timeout=2).read().decode())['stats'].get('rec_ticks', -1))")
                if [ "$R2" -gt "$R1" ] 2>/dev/null; then
                    echo "  ✔ 录像在录（rec_ticks $R1 → $R2）"
                else
                    echo "  ✘ 开了录像但 rec_ticks 没增长（$R1 → $R2）—— 录像没在工作，查日志：$LOG"
                    exit 5
                fi
            fi
            echo ""
            echo "  浏览器打开： http://127.0.0.1:$PORT/"
            echo "  状态页：     http://127.0.0.1:$PORT/status"
            if [ -n "$RECORD" ]; then
                echo "  回放核对：   $PY rt/server.py --replay $RECORD --seed 20261015"
            fi
            exit 0
        else
            echo "  ✘ tick 没增长（$T1 → $T2）—— 起来了但**没在跑**，查日志：$LOG"
            exit 3
        fi
    fi
done
echo "  ✘ 30 s 内 /healthz 没通过 —— 查日志：$LOG"
exit 4
