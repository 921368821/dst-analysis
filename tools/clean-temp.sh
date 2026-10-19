#!/usr/bin/env bash
#==============================================================================
# clean-temp.sh —— 清理「一次性产物」（L3）
#
# 为什么默认 dry-run
#   这些文件**不在版本库里**（被 .gitignore 排除）⇒ 删掉就真的没了，`git checkout`
#   救不回来。所以默认只**列清单 + 算体积**，要真删必须显式 `--yes`。
#
# ★ 安全判据（比"我记得它没用"可靠）
#   只删**同时满足**三条的路径：
#     ① 在下面的白名单里（逐个列出，不用通配扫全盘）
#     ② `git check-ignore` 判定它确实被忽略（⇒ 不属于版本控制内容）
#     ③ 不是运行期必需目录（`_out/json`、`_out/drawcmd.json` 必须保留 ——
#        它们是图集元数据与绘制指令基准，被 /atlas 与 ②h 判据直接读）
#   任何一条不满足 ⇒ 跳过并说明原因，**绝不"大概没关系"地删**。
#
# 用法
#   bash tools/clean-temp.sh              # 只看：列文件数 / 体积 / 将保留项
#   bash tools/clean-temp.sh --yes        # 真删（分批、每批后复核）
#==============================================================================
set -u
_HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$_HERE/.." && pwd)"
cd "$ROOT" || exit 1

DO=0
[ "${1:-}" = "--yes" ] && DO=1

# --- 白名单：**一次性**产物目录（逐条列出，不做全盘 glob） --------------------
TARGETS=(
    "06-引擎复刻/_animtest"
    "06-引擎复刻/_animtest2"
    "06-引擎复刻/out"
    "07-通用引擎/_out"
    "07-通用引擎/tests/_out"
)
# --- 保留清单：混在上述目录里但**必须留**的东西 ------------------------------
KEEP=(
    "06-引擎复刻/_out/json"
    "06-引擎复刻/_out/drawcmd.json"
)

human() {  # 字节 -> 人读
    local b=$1
    if   [ "$b" -ge 1073741824 ]; then echo "$((b/1073741824))G"
    elif [ "$b" -ge 1048576 ];    then echo "$((b/1048576))M"
    elif [ "$b" -ge 1024 ];       then echo "$((b/1024))K"
    else echo "${b}B"; fi
}

echo "工程根: $ROOT"
echo "模式  : $([ $DO = 1 ] && echo '真删（--yes）' || echo '只读预览（加 --yes 才真删）')"
echo ""

total_files=0
total_bytes=0

for t in "${TARGETS[@]}"; do
    if [ ! -e "$t" ]; then
        printf "  · %-28s 不存在，跳过\n" "$t"
        continue
    fi
    # ② git 必须认为它被忽略（否则说明有内容进了版本库，删了会丢历史）
    if ! git check-ignore -q "$t"; then
        printf "  ✘ %-28s **未被 .gitignore 忽略** ⇒ 可能含版本库内容，跳过\n" "$t"
        continue
    fi
    n=$(find "$t" -type f 2>/dev/null | wc -l | tr -d ' ')
    b=$(du -sb "$t" 2>/dev/null | cut -f1)
    printf "  %s %-28s %6s 个文件 / %s\n" "$([ $DO = 1 ] && echo '删' || echo '·')" "$t" "$n" "$(human "$b")"
    total_files=$((total_files + n))
    total_bytes=$((total_bytes + b))
    if [ $DO = 1 ]; then
        # ★ 分批删 + 每批后复核：一次性 rm -rf 出错时无法定位到哪一步
        find "$t" -mindepth 1 -maxdepth 1 -print0 2>/dev/null \
            | xargs -0 -r rm -rf --
        left=$(find "$t" -type f 2>/dev/null | wc -l | tr -d ' ')
        if [ "$left" != "0" ]; then
            echo "    ⚠ 仍有 $left 个文件（可能被占用）—— 已停止，请手工确认"
            exit 1
        fi
    fi
done

# --- 06/_out：整目录里只删「非保留」项 ---------------------------------------
OUT="06-引擎复刻/_out"
if [ -d "$OUT" ]; then
    n=$(find "$OUT" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    b=$(find "$OUT" -maxdepth 1 -type f -exec du -cb {} + 2>/dev/null | tail -1 | cut -f1)
    printf "  %s %-28s %6s 个文件 / %s（目录内散落的一次性件）\n" \
        "$([ $DO = 1 ] && echo '删' || echo '·')" "06-引擎复刻/_out/*（保留 json/ 与 drawcmd.json）" "$n" "$(human "${b:-0}")"
    total_files=$((total_files + n))
    total_bytes=$((total_bytes + ${b:-0}))
    if [ $DO = 1 ]; then
        find "$OUT" -maxdepth 1 -type f -print0 | xargs -0 -r rm -f --
        # ★ 删完必须复核：保留项一个都不能少
        for k in "${KEEP[@]}"; do
            if [ ! -e "$k" ]; then
                echo "    ✘ **保留项被误删**：$k —— 立即从备份/构建脚本恢复"
                exit 1
            fi
        done
        echo "    ✔ 保留项完好：${KEEP[*]}"
    fi
fi

echo ""
printf "合计：%s 个文件 / %s\n" "$total_files" "$(human "$total_bytes")"
if [ $DO = 1 ]; then
    echo "✔ 已清理。保留项："
else
    echo "（预览结束。确认无误后：bash tools/clean-temp.sh --yes）"
    echo "保留项："
fi
for k in "${KEEP[@]}"; do echo "    · $k"; done
