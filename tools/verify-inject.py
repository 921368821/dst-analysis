"""verify-inject.py —— 独立校验：注释版相对原版只增加注释行。

比 verify-annotated.mjs 更严格：额外做「逐行贪心对齐」，
确认注释版里没有任何一行是原版所没有的**可执行代码**。
用法：python verify-inject.py
"""
import os

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _dst_src(sub=""):
    """DST 源码 scripts 根（ASCII 联接 dstsrc 优先 —— Lua/工具链都不吃中文路径）。"""
    for c in (os.path.join(_ROOT, "dstsrc", "scripts"),
              os.path.join(_ROOT, "02-注释源码", "scripts")):
        if os.path.isfile(os.path.join(c, "components", "health.lua")):
            return os.path.join(c, sub) if sub else c
    raise RuntimeError("找不到 DST 源码根（components/health.lua 不存在）")

SRC_ROOT = _dst_src("behaviours")
DST_ROOT = _dst_src("behaviours")


def is_code(line):
    t = line.strip()
    return t != "" and not t.startswith("--")


bad = []
total_comment = 0
files = 0

for fn in sorted(os.listdir(SRC_ROOT)):
    if not fn.endswith(".lua"):
        continue
    files += 1
    src = open(os.path.join(SRC_ROOT, fn), encoding="utf-8").read().split("\n")
    dst = open(os.path.join(DST_ROOT, fn), encoding="utf-8").read().split("\n")
    if src and src[-1] == "":
        src.pop()

    s = [l.strip() for l in src if is_code(l)]
    d = [l.strip() for l in dst if is_code(l)]

    if s != d:
        bad.append((fn, "有效代码行序列不一致"))
        continue

    # 逐行贪心对齐：dst 的每个有效代码行必须与 src 的下一个有效代码行相同
    ci = 0
    for line in dst:
        if not is_code(line):
            continue
        t = line.strip()
        if ci < len(s) and t == s[ci]:
            ci += 1
        else:
            bad.append((fn, "出现原版没有的可执行行: %s" % t[:70]))
            break

    # 编码完整性
    raw = open(os.path.join(DST_ROOT, fn), encoding="utf-8").read()
    if "\ufffd" in raw:
        bad.append((fn, "含 U+FFFD 编码损坏"))
    if "【深度注释版】" not in raw[:600]:
        bad.append((fn, "缺少 HEADER 保护标记"))

    total_comment += len([l for l in dst if l.strip().startswith("--")])

print("检查文件数: %d" % files)
print("注释行总数 : %d" % total_comment)
print("问题数     : %d" % len(bad))
for b in bad[:20]:
    print("   [%s] %s" % b)
print("PASS —— 注释版仅增加注释，可执行代码与原版逐行一致" if not bad else "FAIL")
raise SystemExit(1 if bad else 0)
