#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""falsify_server.heal_leftover() 的自测 —— 还原路径本身从没被反向验证过。

═══ 为什么要这个文件（2026-10-21 实测） ═══

`heal_leftover()` 是「变异测试被硬中断后，把源码按原文写回」的那条路。
2026-10-20 23:10 整轮被掐断，`rt/rt_boot.lua` 就停在

    if true then return true end          -- 原文：if not isnight then return true end

并且**原样留了 10 小时**（到今早 09:13 才被我手工发现）。
它今早确实正确地还原了（78683 字节、`git diff` 变空）—— 但那是**一次幸运的实测**，
不是一条判据：没有人证明过「还原失败时它会说失败」「没有原文时它不乱写」
「写回时字节不变」。

⚠️ 这里有个真实的隐患：原文是 **CRLF + 中文**的 Windows 文件，
而还原用的是 `io.open(pth, "w", encoding="utf-8", newline="")`。
`newline=""` 是**唯一**能保证不翻译行尾的写法：去掉它，
`"\r\n"` 在 Windows 上会被翻成 `"\r\r\n"` —— 文件仍然「像对的」，
`git diff` 却会显示整文件重写，而 Lua 侧只是多一个空行，谁都看不出来。
本文件的 C2 就逐**字节**断言这件事。

═══ 与其它判据的分工 ═══

- `run_all.sh` 的源码洁净闸门：判**当前**源码脏不脏（运行时状态）
- `falsify_server.py --heal`：**修**它（生产路径）
- 本文件：判「修」这个动作在**五种输入**下是否都按承诺行事（判据本身可信吗）

用法：`python tests/falsify_heal_selftest.py`（约 0.2 s，不起服务端、不碰仓库文件）
"""
import io
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import falsify_server as fs                                    # noqa: E402

NL = "\r\n"           # 真实的 rt/*.lua 是 CRLF
CN = "—— 中文与全角标点，用来顺带盯住编码\n".replace("\n", NL)

CASES = []


def case(fn):
    CASES.append(fn)
    return fn


class Sandbox(object):
    """临时目录 + 把 fs.MARK 指过去 + 截住 stdout（还原过程要「大声说明」）。"""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="heal_selftest_")
        self.out = []
        self._old_mark = fs.MARK

    def __enter__(self):
        fs.MARK = os.path.join(self.dir, "_falsify_inprogress.json")
        self._stdout = sys.stdout
        sys.stdout = self
        return self

    def write(self, s):
        self.out.append(s if isinstance(s, str) else str(s))

    def flush(self):
        pass

    def text(self):
        return "".join(self.out)

    def path(self, name):
        return os.path.join(self.dir, name)

    def __exit__(self, *exc):
        sys.stdout = self._stdout
        fs.MARK = self._old_mark
        shutil.rmtree(self.dir, ignore_errors=True)
        return False


def _write(path, body):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(body)


def _read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def _mark(originals=None, **kw):
    d = {"path": ["<t>"], "desc": "自测用", "old": "旧片段", "new": "新片段"}
    if originals is not None:
        d["originals"] = originals
    d.update(kw)
    return d


# ── C1：没有标记 ⇒ 什么都不做，且返回 True ────────────────────────────
@case
def c1_no_mark():
    """没有标记时不能凭空「还原」—— 那会把正常源码写坏。"""
    with Sandbox() as sb:
        ok = fs.heal_leftover()
        assert ok is True, "没有标记却返回 %r（应为 True）" % (ok,)
        assert not os.path.exists(fs.MARK), "没有标记却仍然创建/保留了标记文件"
        assert "发现" not in sb.text(), "没有标记却打了「发现上一次…」：%r" % sb.text()
        assert "还原" not in sb.text(), "没有标记却打了「还原」：%r" % sb.text()


# ── C2：正常还原 ⇒ 逐字节、删标记、大声说明 ────────────────────────
@case
def c2_restores_bytes():
    """CRLF + 中文的原文必须**逐字节**写回（`newline=""` 一旦丢了就会变成 \\r\\r\\n）。"""
    body_a = "function M.f()" + NL + "    " + CN + "end" + NL
    body_b = "return {'" + CN + "'}" + NL
    with Sandbox() as sb:
        a, b = sb.path("a.lua"), sb.path("b.lua")
        _write(a, "function M.f()" + NL + "    if true then return true end" + NL)
        _write(b, "TAMPERED" + NL)
        _write(fs.MARK, json.dumps(_mark({a: body_a, b: body_b}), ensure_ascii=False))

        ok = fs.heal_leftover()

        assert ok is True, "正常的标记却返回 %r" % (ok,)
        assert _read_bytes(a) == body_a.encode("utf-8"), \
            "a.lua 还原后字节不一致：%r" % (_read_bytes(a)[:80],)
        assert _read_bytes(b) == body_b.encode("utf-8"), \
            "b.lua 还原后字节不一致：%r" % (_read_bytes(b)[:80],)
        assert b"\r\r\n" not in _read_bytes(a), "行尾被翻译成了 \\r\\r\\n（newline=\"\" 丢了）"
        assert not os.path.exists(fs.MARK), "还原成功后标记必须删除（否则每轮都重放）"
        t = sb.text()
        assert "已还原" in t, "还原成功却没说：%r" % t
        assert "作废" in t, "没说明「上一次的结论作废」：%r" % t


# ── C3：旧格式标记（没有 originals）⇒ 不写源码、保留标记 ──────────
@case
def c3_old_format_refuses():
    """读不到原文就不许乱写 —— 宁可停下来喊人。"""
    with Sandbox() as sb:
        a = sb.path("a.lua")
        tampered = "if true then return true end" + NL
        _write(a, tampered)
        _write(fs.MARK, json.dumps(_mark(None), ensure_ascii=False))

        ok = fs.heal_leftover()

        assert ok is False, "旧格式标记却返回 %r（应为 False）" % (ok,)
        assert _read_bytes(a) == tampered.encode("utf-8"), "没有原文却改动了源码"
        assert os.path.exists(fs.MARK), "还原不了却删了标记（下次就没线索了）"
        t = sb.text()
        assert "没有原文" in t, "没说清为什么不动手：%r" % t
        assert "手工还原" in t, "没给人工处理的指引：%r" % t


# ── C4：标记本身损坏 ⇒ 不崩、不写源码、保留标记 ──────────────────
@case
def c4_broken_json():
    """JSON 坏了要变成「一条红」，不能变成一个 traceback。"""
    with Sandbox() as sb:
        a = sb.path("a.lua")
        tampered = "TAMPERED" + NL
        _write(a, tampered)
        _write(fs.MARK, "{ this is not json")

        ok = fs.heal_leftover()

        assert ok is False, "标记损坏却返回 %r（应为 False）" % (ok,)
        assert _read_bytes(a) == tampered.encode("utf-8"), "标记损坏却改动了源码"
        assert os.path.exists(fs.MARK), "标记损坏却把它删了"
        assert "读不出来" in sb.text(), "没说清标记读不出来：%r" % sb.text()


# ── C5：目标写不进去 ⇒ 报失败、保留标记 ──────────────────────────
@case
def c5_unwritable_target():
    """还原失败必须**说失败**。说成功而实际没写回，比不还原更坏。"""
    with Sandbox() as sb:
        a = sb.path("a.lua")
        _write(a, "TAMPERED" + NL)
        ghost = os.path.join(sb.dir, "no_such_dir", "ghost.lua")
        _write(fs.MARK, json.dumps(_mark({a: "OK" + NL, ghost: "OK" + NL}),
                                   ensure_ascii=False))

        ok = fs.heal_leftover()

        assert ok is False, "有一个文件写不进去却返回 %r（应为 False）" % (ok,)
        assert os.path.exists(fs.MARK), "还原失败却删了标记"
        assert "还原失败" in sb.text(), "没说哪个文件还原失败：%r" % sb.text()
        assert "本轮不跑" in sb.text(), "没说明「本轮不跑」：%r" % sb.text()


WANT_CASES = 5                   # 自检用例条数：加/删必须同步改这里（开发计划 §9cd / §9cg）


def main():
    bad = 0
    for fn in CASES:
        name = fn.__name__
        try:
            fn()
        except AssertionError as e:
            bad += 1
            print("  ✘ %s：%s" % (name, e))
        except Exception as e:                                # noqa: BLE001
            bad += 1
            print("  ✘ %s：抛了未预期的 %s: %s" % (name, type(e).__name__, e))
        else:
            print("  ✔ %s" % name)
    # ★ 自检也要守住「用例还在不在」：删几条用例、剩下全过，rc 仍是 0，
    #   而这条自检就在静默变松（开发计划 §9cd / §9cg）。
    if len(CASES) != WANT_CASES:
        bad += 1
        print("  ✘ 自检用例 %d 条，期望 %d 条 —— 加/删用例时必须同步 WANT_CASES，"
              "否则这条自检会静默变松" % (len(CASES), WANT_CASES))
    print("heal_leftover 自测：%d 条用例，%d 条不通过（用例 %d 条）"
          % (len(CASES), bad, len(CASES)))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
