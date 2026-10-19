#!/usr/bin/env bash
#==============================================================================
# preflight.sh —— **环境自检**：在跑任何入口之前，先回答「这台机器能不能跑」
#
# 为什么有这个文件（2026-10-18，H3）
#   审查时整机起不来，症状是 14 个入口**各抛一次** Lua 栈（`00_paths.lua` 找不到
#   `components/health.lua`）。人要读 14 份栈才知道「是联接没了」。
#   更糟的是 `tools/env.sh` 当时会**静默回退**到 `02-注释源码/scripts`（中文路径），
#   而 Windows 上 Lua 的 `io.open` 打不开非 ASCII 路径 ⇒ 回退**必然**变成
#   「文件不存在」⇒ 环境问题被伪装成路径问题。
#   ⇒ 本工程已把「判据要放到必经路径上」写进 P42 复盘，这条是同一形态：
#     **检查写在一个没人必经的地方，等于没写。**
#
# 用法
#   bash tools/preflight.sh            # 检查；不过则打印「缺什么 + 怎么修」，退出 2
#   bash tools/preflight.sh --quiet    # 只在**失败**时说话（给 env.sh 用）
#   bash tools/preflight.sh --fix      # 尝试自愈（重建 dstsrc 目录联接）
#
# 退出码
#   0 = 可以跑 ；2 = 环境缺失（**不是代码错**，所以与「测试失败=1」区分开）
#
# 检查项（顺序即「先修哪个」的顺序）
#   ① 工程根可定位（本脚本在 <root>/tools/ 下）
#   ② DST 源码根可读：优先 `$DST_SRC`（外部覆盖），否则 `<root>/dstsrc/scripts`
#   ③ 校验文件 `components/health.lua` 可读
#   ④ `components/ prefabs/ brains/` 三个目录都在（缺一个都会让后半程失败）
#==============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)" || exit 2
ROOT="$(cd "$HERE/.." && pwd)" || exit 2
LINK="$ROOT/dstsrc"
TARGET="$ROOT/02-注释源码"

# ★ 判定结果的**落盘位置**（H3-5）
#   为什么需要：`rel/host/00_paths.lua` 里那一句 Lua 错误是**最后一道**提示，
#   但它没有 lfs，**判断不了目录是否存在**；而 `02-注释源码` 是中文路径，
#   在 Windows 上连 io.open 都打不开 ⇒ 从 Lua 侧观察不出「本体在、只差联接」
#   还是「本体也没有」。这里判得准（bash 的 -e/-d），就把结论写成两行给它引用。
#   成功也写（code=ok）——否则上一次的失败原因会一直挂在那里误导人。
STATE="$HERE/.preflight-state"

QUIET=0
FIX=0
for a in "$@"; do
    case "$a" in
        --quiet) QUIET=1 ;;
        --fix)   FIX=1 ;;
        -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "preflight: 未知参数 $a" >&2; exit 2 ;;
    esac
done

say()  { [ "$QUIET" = "1" ] || echo "$@"; }
fail() { echo "$@" >&2; }

# --- 把判定结果写给 00_paths.lua 引用 -----------------------------------------
# 行格式固定（Lua 侧按 `code=` / `why=` 取），why 里的换行压成空格
record() {  # record <code> <why>
    printf 'code=%s\nwhy=%s\n' "$1" "$(printf '%s' "${2:-}" | tr '\n' ' ')" > "$STATE" 2>/dev/null || true
}

# --- 找出「这台机器上能用的 python」（--fix 与路径转换只为 Windows 服务） ------
_py() {
    for c in "${PY_PLAIN:-}" "${PY:-}" \
             "$HOME/.workbuddy/binaries/python/envs/default/Scripts/python.exe" \
             "$HOME/.workbuddy/binaries/python/envs/default/bin/python" \
             "$(command -v python3 2>/dev/null)" \
             "$(command -v python 2>/dev/null)"
    do
        [ -n "$c" ] || continue
        [ -x "$c" ] 2>/dev/null || command -v "$c" >/dev/null 2>&1 || continue
        printf '%s' "$c"; return 0
    done
    return 1
}

# --- 修复命令的**唯一来源**：打印给人复制的那一条 -----------------------------
fix_hint() {
    fail "  修法（任选一条）："
    fail "    ① 自动：bash \"$HERE/preflight.sh\" --fix"
    fail "    ② 手动（PowerShell）：New-Item -ItemType Junction -Path \"$LINK\" -Target \"$TARGET\""
    fail "    ③ 或把 DST_SRC 指向一个**纯 ASCII 路径**的 scripts 目录（含 components/prefabs/brains）"
    fail ""
    fail "  ★ 为什么必须是 ASCII：Windows 上 Lua 5.1 的 io.open 走 ANSI 代码页，"
    fail "    UTF-8 中文路径**无论存不存在**都报「No such file or directory」。"
    fail "    所以不能直接指向 02-注释源码/scripts，只能经 dstsrc 这个 ASCII 联接。"
}

# --- 核心判定 ----------------------------------------------------------------
# 返回 0 = 可用；1 = 缺失（并把原因写进 _WHY）
_WHY=""
_CODE=""
check_src() {
    local src=""

    # ① 外部覆盖优先（发布/容器里常见：DST_SRC 直接指到游戏安装目录）
    if [ -n "${DST_SRC:-}" ]; then
        src="$DST_SRC"
        if [ ! -r "$src/components/health.lua" ]; then
            _CODE="dst_src_bad"
            _WHY="DST_SRC=$src 已设置，但 $src/components/health.lua 不可读"
            return 1
        fi
        _SRC_KIND="env DST_SRC"
        _SRC="$src"
        return 0
    fi

    # ② 工程内的 ASCII 联接
    if [ ! -e "$LINK" ]; then
        if [ -e "$TARGET/scripts/components/health.lua" ]; then
            _CODE="missing_link"
            _WHY="联接缺失：$LINK 不存在（但源码本体在 $TARGET —— 只差这一层联接）"
        else
            _CODE="no_body"
            _WHY="源码缺失：$LINK 与 $TARGET/scripts 都不存在"
        fi
        return 1
    fi

    src="$LINK/scripts"
    if [ ! -r "$src/components/health.lua" ]; then
        if [ -e "$TARGET/scripts/components/health.lua" ]; then
            _CODE="broken_link"
            _WHY="$LINK 存在，但它指不到源码（$LINK/scripts/components/health.lua 不可读）—— 联接可能已失效"
        else
            _CODE="no_body"
            _WHY="$LINK 存在，但源码本体 $TARGET/scripts 也不存在"
        fi
        return 1
    fi
    _SRC_KIND="dstsrc 联接"
    _SRC="$src"
    return 0
}

# --- --fix：重建联接（用 python 做，避免 bash→cmd 的中文路径编码坑） ----------
do_fix() {
    local py
    if ! py="$(_py)"; then
        fail "preflight --fix：找不到 python，无法自动修复。请按上面的手动命令操作。"
        return 1
    fi
    # ★ 为什么用 python 而不是 cmd/mklink：目标路径含中文（02-注释源码）。
    #   Git Bash 传给 cmd.exe 的是 UTF-8 字节，cmd 按 ANSI 代码页解释 ⇒ 乱码路径。
    #   python3 源码默认 UTF-8，且 os.symlink/junction 都不经过 shell 编码。
    "$py" - "$LINK" "$TARGET" <<'PYEOF'
import os, sys, subprocess
link, target = sys.argv[1], sys.argv[2]
probe = os.path.join(link, "scripts", "components", "health.lua")
if os.path.exists(probe):
    print("preflight --fix：%s 已可用，不动它" % link)
    sys.exit(0)
if not os.path.isdir(target):
    print("preflight --fix：目标目录不存在：%s" % target, file=sys.stderr)
    sys.exit(1)
# ★ 只清理「自己上一次留下的空壳 / 失效联接」：非空真实目录一律不动（防误删）
#   为什么不再用 os.remove 单打一：junction 在 Windows 上是**目录重解析点**，
#   os.remove 对它抛 OSError 而代码又吞了它 ⇒ 后面 mklink 报「已存在」，
#   表现得像「修不了」。实测：空壳 dstsrc 目录时 --fix 直接判「不可自愈」，
#   而它打印的修法恰好就是 --fix 自己 —— 自相矛盾。
def drop_link_only(p):
    try:
        os.remove(p)              # 符号联接：只删这一层
        return
    except OSError:
        pass
    try:
        os.rmdir(p)               # junction / 空目录：只删这层，不碰目标内容
    except OSError as e:
        raise RuntimeError("拒绝覆盖：%s 既不是可删的联接也不是空目录（%s）" % (p, e))

if os.path.isdir(link) or os.path.islink(link) or os.path.exists(link):
    try:
        drop_link_only(link)
    except RuntimeError as e:
        print("preflight --fix：%s" % e, file=sys.stderr)
        sys.exit(1)

# ★★ 为什么用 junction 而不是 os.symlink（本轮实测踩到）：
#   `os.symlink(..., target_is_directory=True)` 在这台机器上**返回成功**，
#   但建出来的是个**普通空目录**（PowerShell 里 LinkType 为空、Target 为空、
#   子项 0 个）—— 也就是「报告成功但什么也没连上」。
#   junction 不需要任何权限，且不需要经过 shell 编码（subprocess 直接调 cmd）。
if os.name == "nt":
    # ★ text=True 会让 subprocess 按 UTF-8 解码 cmd 的 GBK 输出 ⇒
    #   UnicodeDecodeError 直接炸在读取线程里（本轮实测踩到）。⇒ 拿 bytes，自己宽松解码。
    r = subprocess.run(["cmd", "/c", "mklink", "/J",
                        os.path.normpath(link), os.path.normpath(target)],
                       capture_output=True)
    out = (r.stdout + r.stderr).decode("mbcs", "replace")
else:
    r = subprocess.run(["ln", "-s", target, link], capture_output=True)
    out = (r.stdout + r.stderr).decode("utf-8", "replace")
if r.returncode != 0:
    print("preflight --fix：建联接失败\n%s" % out, file=sys.stderr)
    sys.exit(1)
# ★ 建完必须**回读**：命令返回 0 不等于连上了（上面 os.symlink 就是反例）
if not os.path.exists(probe):
    print("preflight --fix：命令返回 0，但 %s 仍不可读 —— 联接没连上" % probe, file=sys.stderr)
    sys.exit(1)
print("preflight --fix：已建联接 %s -> %s（回读通过）" % (link, target))
PYEOF
}

# --- 主流程 ------------------------------------------------------------------
if ! check_src; then
    if [ "$FIX" = "1" ]; then
        # 能自愈的两种：① 联接整个没了 ② 联接在但失效（空壳/指错）
        # 其余（DST_SRC 指错、源码本体缺失、目录不全）如实报错，不猜着修。
        if [ -e "$TARGET/scripts/components/health.lua" ] \
           && { [ "$_CODE" = "missing_link" ] || [ "$_CODE" = "broken_link" ]; }; then
            record "$_CODE" "$_WHY"
            do_fix || {
                record "$_CODE" "自愈失败（目标不可安全覆盖）：$_WHY"
                fail "✘ 自愈失败：$_WHY"
                fail ""
                fix_hint
                exit 2
            }
            if ! check_src; then
                record "$_CODE" "$_WHY"
                fail "✘ 自愈后仍不可用：$_WHY"; fix_hint; exit 2
            fi
        else
            record "$_CODE" "$_WHY"
            fail "✘ 环境自检失败（不可自愈）：$_WHY"
            fail ""
            fix_hint
            exit 2
        fi
    else
        # ★ 一条判定，不抛 14 份栈
        record "$_CODE" "$_WHY"
        fail "✘ 环境自检失败：$_WHY"
        fail "  探测位置：$LINK/scripts/components/health.lua"
        fail ""
        fix_hint
        fail "  ⇒ 已**不再启动**任何入口（14 个入口一条都没跑）。"
        exit 2
    fi
fi

# ③④ 结构完整性（联接通了但目录残缺，同样会让后半程报错）
_missing=""
for d in components prefabs brains; do
    [ -d "$_SRC/$d" ] || _missing="$_missing $d"
done
if [ -n "$_missing" ]; then
    record "incomplete" "源码根 $_SRC 缺目录：$_missing"
    fail "✘ 环境自检失败：源码根 $_SRC 缺目录：$_missing"
    fail "  （只通了 health.lua，但 components/prefabs/brains 不全，后半程必然失败）"
    exit 2
fi

record "ok" "自检通过（$_SRC_KIND：$_SRC）"
say "✔ 环境自检通过（$_SRC_KIND：$_SRC）"
exit 0
