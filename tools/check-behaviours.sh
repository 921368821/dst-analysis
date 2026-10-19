#!/usr/bin/env bash
# check.sh —— behaviours 注释版的三道关卡批量检查
# 用法：bash check.sh follow chaseandattack ...
set -u
# ★ 运行时与路径统一由 tools/env.sh 解析（2026-10-17 迁移；原来全是硬编码）
_HERE="$(cd "$(dirname "$0")" && pwd)"
. "$_HERE/env.sh" || exit 1
TOOLS="$_HERE"
OUT="$DST_SRC/behaviours"
fail=0
for n in "$@"; do
  if grep -q $'\uFFFD' "$TOOLS/spec-$n.mjs" 2>/dev/null; then
    echo "[$n] ✘ spec-$n.mjs 含 U+FFFD 编码损坏，先修 spec:"; grep -n $'\uFFFD' "$TOOLS/spec-$n.mjs" | head -3; fail=1; continue
  fi
  if ! "$NODE" "$TOOLS/build-$n.mjs" > /tmp/b.log 2>&1; then
    echo "[$n] 关卡1 构建失败:"; tail -3 /tmp/b.log; fail=1; continue
  fi
  r=$(cd "$PROJECT_ROOT/03-参考架构" && "$PY" -c "
from lupa import LuaRuntime
L=LuaRuntime(unpack_returned_tuples=True)
fn=L.eval('function(src) local f,e=load(src,\"x\") if f then return \"SYNTAX_OK\" else return \"ERR: \"..tostring(e) end end')
print(fn(open(r'$OUT/$n.lua',encoding='utf-8').read()))
")
  src=$(grep -oE '源文件行数 *: [0-9]+' /tmp/b.log | grep -oE '[0-9]+$')
  out=$(grep -oE '输出文件行数 *: [0-9]+' /tmp/b.log | grep -oE '[0-9]+$')
  inj=$(grep -oE '注入注释行数 *: [0-9]+' /tmp/b.log | grep -oE '[0-9]+$')
  cov=$(grep -oE '注释锚点行数 *: [0-9]+' /tmp/b.log | grep -oE '[0-9]+$')
  if [ "$r" = "SYNTAX_OK" ]; then st="OK "; else st="LUA-FAIL"; fail=1; fi
  printf "[%-28s] src=%-4s out=%-4s +注释=%-4s 锚点=%-3s %s\n" "$n" "$src" "$out" "$inj" "$cov" "$st"
  if [ "$r" != "SYNTAX_OK" ]; then echo "    $r"; fi
done
"$NODE" "$TOOLS/verify-annotated.mjs" \
  "$DST_SRC" \
  "$PROJECT_ROOT/dstsrc/scripts"
va=$?
case $va in
  0) echo "  关卡3 verify-annotated：✔ 通过" ;;
  1) echo "  关卡3 verify-annotated：✘ 代码被改动（见上）"; fail=1 ;;
  *) # 2 = 无法复验。★ 不能当通过：原版副本已丢失，$DST_SRC 退化成注释版本身，
      #   这一关现在**没有判据**。吵出来，由 L4 的 pre-commit 决定是否阻断。
      echo "  关卡3 verify-annotated：⊘ 无法复验（缺原版副本，见 M9）—— 本关不计通过" ;;
esac
exit $fail
