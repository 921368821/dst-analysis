#!/usr/bin/env bash
#==============================================================================
# stop.sh —— 停掉服务端（**按端口找 PID**，不靠记 PID）
#==============================================================================
# 用法：bash deploy/stop.sh [端口]
#
# ★ 为什么按端口找而不是读 server.pid：
#   实测踩过 —— 旧进程没死透、新进程照样起来（Windows SO_REUSEADDR 允许双绑），
#   于是**两条监听并存**，连接随机落到哪一个，表现为「同一个 ?bin=1 连接
#   有时收到二进制、有时收到 JSON」。看起来像功能没生效，实际是**连到了另一个世界**。
#   ⇒ 停服必须**以「这个端口上还有谁在听」为准**，而不是「我以为的那个 PID」。
set -u
PORT="${1:-8765}"
# ★ 解释器由工程根的 tools/env.sh 统一解析（原来硬编码用户目录，搬迁即失效）
. "$(cd "$(dirname "$0")/../.." && pwd)/tools/env.sh" || exit 2

PIDS=$(netstat -ano 2>/dev/null | grep ":$PORT .*LISTENING" | awk '{print $5}' | sort -u)
if [ -z "$PIDS" ]; then
    echo "  （端口 $PORT 上没有监听进程）"
    exit 0
fi

# ★★ P37：**先存档，再杀**。
#   为什么：`taskkill //F` 是**硬杀**，进程**没有机会**保存自己；而周期自动存档是 30 s
#   一次 ⇒ 直接杀会丢掉最后 30 s 的世界进度，刚连上的客户端身份也可能还没落盘
#   （于是 P36 的「会话身份挺过重启」在**真实停服路径**上时灵时不灵）。
#   `/save` 是**同步**的：入队给模拟线程，写完才回 200 —— 所以这里等它回话就够了。
#   ⚠️ 存档失败**不阻止停服**（停服是用户的意图）；但失败必须**说出来**，不静默。
echo "  ── 停服前先存档（避免硬杀丢掉最后 30 s）──"
"$PY" -c "
import urllib.request, json
try:
    d = json.loads(urllib.request.urlopen('http://127.0.0.1:$PORT/save', timeout=25).read().decode())
    if d.get('ok'):
        print('  ✔ 已存档：%s 实体 / %s 字节' % (d.get('n'), d.get('sz')))
    else:
        print('  ⚠ 存档被拒（继续停服）：%s' % d.get('error'))
except Exception as e:
    print('  ⚠ 存档请求失败（继续停服）：%s' % e)
" 2>/dev/null || echo "  ⚠ 存档请求异常（继续停服）"

for pid in $PIDS; do
    echo "  停 PID $pid（监听 $PORT）"
    taskkill //F //PID "$pid" > /dev/null 2>&1 && echo "    ✔ 已停" || echo "    ✘ 停不掉（权限？）"
done

sleep 1
LEFT=$(netstat -ano 2>/dev/null | grep ":$PORT .*LISTENING" | wc -l)
if [ "$LEFT" -gt 0 ]; then
    echo "  ✘ 还有 $LEFT 条监听没停掉："
    netstat -ano 2>/dev/null | grep ":$PORT .*LISTENING"
    exit 1
fi
echo "  ✔ 端口 $PORT 已空闲"
exit 0
