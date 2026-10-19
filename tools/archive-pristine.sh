#!/usr/bin/env bash
#==============================================================================
# archive-pristine.sh —— 归档「原始未注释源码」并固化复验证据（M9）
#
# 为什么需要这个脚本
#   整套 4030 文件注释的质量底线是「只增注释、可执行代码逐字节一致」，
#   而这条承诺**只能靠比对原版**来证明。当前原版副本已随旧用户目录
#   （`C:/Users/35916/.qwenworkcn/...`）一起消失，本机也没有游戏 data，
#   ⇒ `verify-annotated.mjs` 长期处于「自己比自己」的假绿状态（v2 已改为报 2）。
#
#   等到手上有原版的那一天，**别再用「记得去比一下」这种口头承诺**：
#   跑这一条命令，把①树归档 + ②代码行指纹清单 + ③复验结果一次性落地。
#   清单只有几 KB，可以入库；以后原版再不在了也能用 --manifest 复验。
#
# 用法：
#   bash tools/archive-pristine.sh <原版 scripts 根> [归档根]
#
# 例：
#   bash tools/archive-pristine.sh "D:/dst_data/scripts"
#   # ⇒ _baseline/pristine-scripts/            原版树（gitignored，本机留证）
#   # ⇒ tools/baseline/pristine-code.sha256.json  指纹清单（**入库**）
#==============================================================================
set -u
_HERE="$(cd "$(dirname "$0")" && pwd)"
. "$_HERE/env.sh" || exit 1
TOOLS="$_HERE"

SRC="${1:-}"
ARCH_ROOT="${2:-$PROJECT_ROOT/_baseline}"

if [ -z "$SRC" ]; then
    echo "用法: bash tools/archive-pristine.sh <原版 scripts 根> [归档根]" >&2
    echo "" >&2
    echo "原版 scripts 根从哪来（任选一种）：" >&2
    echo "  ① 装了游戏：<Don't Starve Together>/data/databundles/scripts.zip 解包后的目录" >&2
    echo "  ② 别人给的副本：只要目录里是 **未加注释** 的 .lua（components/ prefabs/ …）" >&2
    echo "  ③ 本工程早期用过的那份（已丢失）：C:/Users/35916/.qwenworkcn/.../scripts/scripts" >&2
    exit 2
fi

# --- 前置：目录必须存在、且必须**不是**注释版自己 ------------------------------
if [ ! -d "$SRC" ]; then
    echo "✘ 原版根不存在：$SRC" >&2
    exit 2
fi

ANNOT="$PROJECT_ROOT/02-注释源码/scripts"
_real() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
if [ "$(_real "$SRC")" = "$(_real "$ANNOT")" ]; then
    echo "✘ 传入的是注释版自己（$SRC）—— 归档它没有任何意义。" >&2
    exit 2
fi

# 抽样判据：注释版里带「中文注释行」，原版不该有那么多。
# 不做全量（4030 文件太慢），只证明「这两个目录不是同一份东西」。
sample_rel="components/health.lua"
if [ -f "$SRC/$sample_rel" ] && [ -f "$ANNOT/$sample_rel" ]; then
    n_src=$(grep -c '^\s*--' "$SRC/$sample_rel" 2>/dev/null || echo 0)
    n_ann=$(grep -c '^\s*--' "$ANNOT/$sample_rel" 2>/dev/null || echo 0)
    if [ "$n_src" -ge "$n_ann" ] && [ "$n_ann" -gt 0 ]; then
        echo "⚠️  抽样 $sample_rel：原版注释行 $n_src ≥ 注释版 $n_ann —— 像是给反了。" >&2
        echo "    继续执行，但请确认第一个参数真的是**未注释**的原版。" >&2
    else
        echo "· 抽样 $sample_rel：原版注释行 $n_src / 注释版 $n_ann（符合预期）"
    fi
fi

# --- ① 归档原版树 -------------------------------------------------------------
mkdir -p "$ARCH_ROOT"
DEST="$ARCH_ROOT/pristine-scripts"
if [ -d "$DEST" ]; then
    echo "· 归档已存在，覆盖：$DEST"
    rm -rf "$DEST"
fi
cp -r "$SRC" "$DEST"
n_files=$(find "$DEST" -name '*.lua' | wc -l | tr -d ' ')
echo "✔ 原版树已归档：$DEST（$n_files 个 .lua）"

# --- ② 生成代码行指纹清单（入库） --------------------------------------------
mkdir -p "$TOOLS/baseline"
MANIFEST="$TOOLS/baseline/pristine-code.sha256.json"
"$NODE" "$TOOLS/verify-annotated.mjs" --stamp "$DEST" --out "$MANIFEST" || exit 2

# --- ③ 立刻用清单复验注释版 ---------------------------------------------------
echo ""
echo "════ 用清单复验注释版 ════"
"$NODE" "$TOOLS/verify-annotated.mjs" --manifest "$MANIFEST" "$ANNOT"
rc=$?
case $rc in
  0) echo "✅ M9 完成：注释版 = 原版 + 注释（逐文件代码行指纹一致）" ;;
  1) echo "❌ 注释版与原版**代码不一致**（见上面逐文件明细）—— 这是真缺陷，要修注释版" ;;
  *) echo "⊘ 复验没跑成（rc=$rc），别当通过" ;;
esac
exit $rc
