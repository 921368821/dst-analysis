#!/usr/bin/env bash
#==============================================================================
# tools/env.sh —— 运行时与路径的**单一来源**（被所有 shell 入口 source）
#
# 为什么有这个文件（2026-10-17）：
#   工作区搬迁过一次（用户目录 `35916` → `admin`，工程从 `E:/DST-Analysis`
#   挪到 `E:/xnb/DST-Analysis`），于是 5 个 shell/python 入口里的
#   `C:/Users/35916/...` 全部失效 —— 而这 5 处是**同一串字面量抄了 5 份**。
#   本工程的母题之一就是「同一件事两处实现 ⇒ 改一处、另一处悄悄过期」，
#   所以这里改成**一处解析、到处 source**。
#
# 提供的变量：
#   PROJECT_ROOT   工程根（含 06-引擎复刻 / 07-通用引擎 / 03-参考架构）
#   PY             能 `import lupa` 的 python（找不到就报错，不静默降级）
#   PY_PLAIN       任意可用 python（不要求 lupa；给只跑 stdlib 的工具用）
#   NODE           node（22.x）
#   ENGINE         06-引擎复刻 目录
#   RUNNER         03-参考架构/_run_lua.py
#   DST_SRC        DST 源码 scripts 根（ASCII 联接；Lua 打不开中文路径）
#
# 用法：在脚本顶部
#   . "$(cd "$(dirname "$0")/.." && pwd)/tools/env.sh"
# 或者（07 侧，往上一级就到根）：
#   . "$ROOT/../tools/env.sh"
#==============================================================================

# 已经 source 过就跳过（幂等；重复 source 不该重复探测）
if [ "${_WB_ENV_LOADED:-}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi
_WB_ENV_LOADED=1

_WB_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$_WB_ENV_DIR/.." && pwd)"
export PROJECT_ROOT

ENGINE="$PROJECT_ROOT/06-引擎复刻"
RUNNER="$PROJECT_ROOT/03-参考架构/_run_lua.py"
export ENGINE RUNNER

# DST 源码：优先 ASCII 联接 dstsrc（Windows 上 Lua 的 io.open 走 ANSI 代码页，
# UTF-8 中文路径「无论存不存在」都会报 No such file or directory）
#
# ★★ 2026-10-18（H3）：**去掉静默回退**。
#   原来这里在 dstsrc 缺失时会退到 `02-注释源码/scripts` —— 而那是个**中文路径**，
#   上一条注释自己就写了「Lua 打不开」。于是回退**必然**表现为
#   「components/health.lua: No such file or directory」，把**环境缺失**伪装成
#   **代码/路径错误**，14 个入口各报一次。审查当天整机起不来就是这条。
#   ⇒ 现在：先过 `tools/preflight.sh`（唯一判定点），缺失就**立刻停**并给修复命令。
if ! bash "$PROJECT_ROOT/tools/preflight.sh" --quiet; then
    echo "✘ 环境自检不过 —— 已停止加载（详见上面那条 preflight 判定）" >&2
    return 1 2>/dev/null || exit 1
fi
DST_SRC="${DST_SRC:-$PROJECT_ROOT/dstsrc/scripts}"
export DST_SRC

# --- python：必须能 import lupa 的那一个 -------------------------------------
_wb_try_py() {   # $1=候选, $2=1 表示要求 lupa
    [ -n "${1:-}" ] || return 1
    [ -x "$1" ] || command -v "$1" >/dev/null 2>&1 || return 1
    if [ "${2:-0}" = "1" ]; then
        "$1" -c "import lupa" >/dev/null 2>&1 || return 1
    else
        "$1" -c "import sys" >/dev/null 2>&1 || return 1
    fi
    printf '%s' "$1"
}

if [ -z "${PY:-}" ]; then
    for c in \
        "$HOME/.workbuddy/binaries/python/envs/default/Scripts/python.exe" \
        "$HOME/.workbuddy/binaries/python/envs/default/bin/python" \
        "$(command -v python3 2>/dev/null)" \
        "$(command -v python 2>/dev/null)"
    do
        if p="$(_wb_try_py "$c" 1)"; then PY="$p"; break; fi
    done
fi
if [ -z "${PY:-}" ]; then
    echo "✘ 找不到能 import lupa 的 python。" >&2
    echo "  修法：\"<python>\" -m venv \$HOME/.workbuddy/binaries/python/envs/default && \\" >&2
    echo "        \$HOME/.workbuddy/binaries/python/envs/default/Scripts/python.exe -m pip install lupa" >&2
    return 1 2>/dev/null || exit 1
fi

if [ -z "${PY_PLAIN:-}" ]; then
    for c in "$PY" \
        "$(command -v python3 2>/dev/null)" \
        "$(command -v python 2>/dev/null)"
    do
        if p="$(_wb_try_py "$c" 0)"; then PY_PLAIN="$p"; break; fi
    done
fi
[ -n "${PY_PLAIN:-}" ] || PY_PLAIN="$PY"
export PY PY_PLAIN

# --- node --------------------------------------------------------------------
if [ -z "${NODE:-}" ]; then
    NODE="$(command -v node 2>/dev/null)"
fi
if [ -z "${NODE:-}" ]; then
    # 没在 PATH 里就扫 workbuddy 的版本目录（取最后排序的那个）
    for d in "$HOME"/.workbuddy/binaries/node/versions/*/node.exe; do
        [ -x "$d" ] && NODE="$d"
    done
fi
if [ -z "${NODE:-}" ]; then
    echo "✘ 找不到 node（客户端/协议测试需要它）" >&2
    return 1 2>/dev/null || exit 1
fi
export NODE

# 有需要的脚本可以打印一行环境指纹（排查「手动能跑、脚本不能跑」时先看这个）
if [ "${WB_ENV_VERBOSE:-}" = "1" ]; then
    echo "env: ROOT=$PROJECT_ROOT"
    echo "env: PY=$PY"
    echo "env: NODE=$NODE"
    echo "env: DST_SRC=${DST_SRC:-（未找到）}"
fi
