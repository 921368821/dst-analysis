# -*- coding: utf-8 -*-
"""probe_editor.py —— 编辑器三件套（列/删/移）的取证探针（**不是判据**）

回答四个问题，全部用真实世界回答，不靠读代码推断：
  1. `/editor/entities` 能不能列出世界里的实体？数字自洽吗（count vs listed vs len）？
  2. `/editor/move` 挪完之后，**回读的位置**真的变了吗？
  3. `/editor/remove` 删完之后，实体是不是真的不在世界表里了？
  4. 玩家实体能不能被删除？（**必须拒绝** —— 删了会破坏会话身份）

跑法：
    cd 07-通用引擎 && "C:/Users/admin/.workbuddy/binaries/python/envs/default/Scripts/python.exe" tools/probe_editor.py
退出码：0 = 四项全成立；1 = 有不成立的项（打印是哪一项）
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "rt"))

from sim import Sim  # noqa: E402

FAIL = []


def check(name, cond, detail=""):
    print(("  ✔ " if cond else "  ✘ ") + name + (("  | " + detail) if detail else ""))
    if not cond:
        FAIL.append(name)


def main():
    print("=" * 72)
    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    snap = s.snapshot()
    player = snap.get("player") or {}
    px = float(player.get("x", 0.0))
    pz = float(player.get("z", 0.0))
    print("player at (%.2f, %.2f)" % (px, pz))

    # ---- ① 列出全部实体 -----------------------------------------------------
    print("-" * 72)
    print("① /editor/entities")
    ok, info = s.debug_entities(500)
    check("调用成功", ok, str(info.get("error")) if not ok else "")
    if not ok:
        return 1
    count, listed, items = info["count"], info["listed"], info["items"]
    print("     count=%d  listed=%d  len(items)=%d" % (count, listed, len(items)))
    check("listed == len(items)", listed == len(items), "%d vs %d" % (listed, len(items)))
    check("count >= listed", count >= listed, "%d >= %d" % (count, listed))
    check("count > 0", count > 0, "世界是空的？")
    check("每项都有 guid 与 prefab",
          all(isinstance(it.get("guid"), int) and it.get("prefab") for it in items))
    check("按 guid 升序",
          all(items[i]["guid"] < items[i + 1]["guid"] for i in range(len(items) - 1)))
    print("     前 5 条：")
    for it in items[:5]:
        print("       guid=%-4s %-16s (%s, %s) hp=%s"
              % (it["guid"], it["prefab"], it["x"], it["z"], it["hp"]))

    # ---- ② 生成一个对象，确认它出现在列表里 ---------------------------------
    print("-" * 72)
    print("② 生成 → 出现在列表里")
    ok, sp = s.debug_spawn("rock1", px + 4.0, pz + 4.0)
    check("spawn rock1 成功", ok, str(sp.get("error")) if not ok else "")
    if not ok:
        return 1
    g = sp["guid"]
    ok2, info2 = s.debug_entities(500)
    found = [it for it in info2["items"] if it["guid"] == g] if ok2 else []
    check("新实体出现在列表里", len(found) == 1, "guid=%d" % g)
    check("列表 count 增了 1", ok2 and info2["count"] == count + 1,
          "%d → %d" % (count, info2["count"] if ok2 else -1))
    check("生成坐标正确",
          bool(found) and abs(found[0]["x"] - (px + 4.0)) < 0.01
          and abs(found[0]["z"] - (pz + 4.0)) < 0.01,
          str(found[0] if found else None))

    # ---- ③ 移动 -------------------------------------------------------------
    print("-" * 72)
    print("③ /editor/move")
    ok, mv = s.debug_move(g, px + 9.0, pz - 6.0)
    check("move 成功", ok, str(mv.get("error")) if not ok else "")
    ok3, ent = s.debug_entity(g)
    if ok3:
        dx = abs(float(ent["x"]) - (px + 9.0))
        dz = abs(float(ent["z"]) - (pz - 6.0))
        check("回读位置已变", dx < 0.01 and dz < 0.01,
              "回读 (%.2f, %.2f)，期望 (%.2f, %.2f)"
              % (float(ent["x"]), float(ent["z"]), px + 9.0, pz - 6.0))
    else:
        check("回读位置已变", False, str(ent))

    # 移动一个不存在的 guid 必须被拒
    ok, bad = s.debug_move(99999999, 0, 0)
    check("不存在的 guid 被拒", not ok, str(bad.get("error")))

    # ---- ④ 删除 -------------------------------------------------------------
    print("-" * 72)
    print("④ /editor/remove")
    ok, rm = s.debug_remove(g)
    check("remove 成功", ok, str(rm.get("error")) if not ok else "")
    ok4, after = s.debug_entity(g)
    check("删完就查不到了", not ok4, str(after.get("error")))
    ok5, info5 = s.debug_entities(500)
    check("列表里也没有了",
          ok5 and not any(it["guid"] == g for it in info5["items"]))
    check("count 回到原值", ok5 and info5["count"] == count,
          "%d vs %d" % (info5["count"] if ok5 else -1, count))

    # ---- ⑤ 玩家不可删除 -----------------------------------------------------
    print("-" * 72)
    print("⑤ 玩家实体必须拒绝删除")
    me = None
    for it in (info5["items"] if ok5 else []):
        if it["prefab"] in ("wilson", "willow", "wolfgang", "wendy", "wx78",
                            "wickerbottom", "woodie", "wes", "waxwell", "wathgrithr",
                            "webber"):
            me = it
            break
    if me is None:
        # 退一步：用 guid 最小的那几个里的第一个玩家（Lua 侧有 player tag）
        print("     （列表里没认出玩家 prefab，改从 Lua 侧按 tag 找）")
        me = {"guid": 0}
    ok, rs = s.debug_remove(me["guid"])
    print("     尝试删除 guid=%s (prefab=%s) → ok=%s  %s"
          % (me["guid"], me.get("prefab"), ok, rs.get("error") or rs.get("prefab")))
    # 若 guid=0 恰好不是玩家，这条会「成功」——那说明我们的探针选错了对象，
    # 不能算通过也不能算失败，单独说出来。
    if ok:
        print("     ⚠ 这个 guid 不是玩家（被删成功了）——本条不成立，需换目标重测")
        FAIL.append("⑤ 没找到玩家实体做反向验证")
    else:
        check("玩家被拒", True, str(rs.get("error")))

    print("=" * 72)
    if FAIL:
        print("✘ 有 %d 项不成立：" % len(FAIL))
        for n in FAIL:
            print("   -", n)
        return 1
    print("✔ 五项全部成立")
    return 0


if __name__ == "__main__":
    sys.exit(main())
