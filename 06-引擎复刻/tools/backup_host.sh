#!/bin/sh
# ============================================================================
# backup_host.sh —— 改 host/*.lua 之前先跑一次
# ============================================================================
# 为什么要它：2026-10-15 我用一次错误的字符串切片把 `01_core.lua` 从 ~980 行
# 截断到 233 行，丢了当天四项改动。是靠 `/tmp` 里昨天遗留的 `.bak2` 救回来的
# —— **运气，不是流程**。
#
# `/tmp` 里的备份会随环境清理消失，且不带时间戳、看不出新旧。
# 所以改成：**改之前显式快照到项目内 .hostbak/**，带时间戳，可回滚。
#
# 用法:
#     sh tools/backup_host.sh            # 快照（覆盖同名旧快照）
#     sh tools/backup_host.sh --list     # 列出可用快照
#     sh tools/backup_host.sh --restore host/01_core.lua   # 回滚某个文件
# ============================================================================
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BAK="$ROOT/.hostbak"
STAMP=$(date +%Y%m%d-%H%M%S)
mkdir -p "$BAK"

case "$1" in
--list)
    echo "快照目录: $BAK"
    ls -la "$BAK" | tail -n +2 | awk '{printf "  %-24s %s %s %s\n", $NF, $6, $7, $8}'
    exit 0
    ;;
--restore)
    f="$2"
    [ -f "$BAK/$(basename "$f")" ] || { echo "没有 $f 的快照" >&2; exit 1; }
    cp "$BAK/$(basename "$f")" "$ROOT/$f"
    echo "已从快照恢复 $f"
    exit 0
    ;;
esac

for f in "$ROOT"/host/*.lua; do
    b=$(basename "$f")
    # 只在有变化时留带时间戳的旧版，避免快照目录无限膨胀
    if [ -f "$BAK/$b" ] && ! cmp -s "$f" "$BAK/$b"; then
        cp "$BAK/$b" "$BAK/$b.$STAMP"
    fi
    cp "$f" "$BAK/$b"
done
echo "已快照 $(ls "$ROOT"/host/*.lua | wc -l) 个 host 文件到 $BAK（时间戳 $STAMP）"
