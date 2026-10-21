# -*- coding: utf-8 -*-
"""probe_combat.py —— 战斗闭环的取证探针（**不是判据**）

用途：在改引擎之前/之后，用真实世界回答四个问题：
  1. `action_for(spider)` 到底返回什么？（ATTACK 有没有接上）
  2. `Combat:DoAttack` 在这个宿主里**会不会真扣血**？（不靠猜，看血量差）
  3. 按住不放（PENDING 每 30 拍重发）能不能把目标打死？
  4. 目标死后 `action_for` 会不会变（尸体不该再是目标）。

为什么不写成 tests/test_rt.py 里的判据：
  判据要**稳定、快、有反向**；探针要**说得多、能中途停**。
  这个脚本会把每一步的拒绝原因原样打出来，方便定位是哪一层挂了。
  结论确认后，判据再单独写（见 tests/test_rt.py 的 E14）。

跑法（必须用工程解释器，系统 python 没有 lupa）：
    cd 07-通用引擎 && bash -c '. ../tools/env.sh && $PY tools/probe_combat.py'
退出码：0 = 打死了；1 = 没打死（打印停在哪一步）；2 = 环境/生成失败
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "rt"))

from sim import Sim  # noqa: E402


def ent(s, guid):
    ok, info = s.debug_entity(guid)
    if not ok:
        return {"error": str(info)}
    return {k: (str(v) if type(v).__name__ == "_LuaTable" else v) for k, v in info.items()}


def atk(s):
    st = s.stats()
    return {k: st.get(k) for k in ("atk_ok", "atk_land", "atk_dmg", "atk_cd",
                                   "last_atk_why", "act_ok", "act_refused", "last_refusal")}


def main():
    print("=" * 70)
    print("boot ...")
    s = Sim(seed=20261015, tick_hz=30, world_content=14).boot()
    snap = s.snapshot()
    player = snap.get("player") or {}
    px, pz = float(player.get("x", 0.0)), float(player.get("z", 0.0))
    print("player at (%.2f, %.2f)" % (px, pz))

    ok, info = s.debug_spawn("spider", px + 3.0, pz)
    if not ok:
        print("✘ 生成 spider 失败：", info)
        return 2
    guid = info["guid"]
    print("spider guid=%s at (%.2f, %.2f)" % (guid, info["x"], info["z"]))
    print("  debug_entity →", ent(s, guid))

    print("-" * 70)
    ok, why = s.api.act(0, guid)
    print("act(0, %s) → %s / %s" % (guid, ok, why))

    for rnd in range(1, 31):
        for _ in range(15):
            s.step()
        e = ent(s, guid)
        a = atk(s)
        # 玩家状态与距离：不打出来就分不清「打不动」和「我已经被打死了」
        ps = s.player_state(0)
        pl = s.snapshot().get("player") or {}
        d = None
        if "error" not in e and pl.get("x") is not None:
            d = ((float(e["x"]) - float(pl["x"])) ** 2 + (float(e["z"]) - float(pl["z"])) ** 2) ** 0.5
        print("r%-2d  hp=%-6s dead=%-5s d=%-5s | 玩家 hp=%-5s alive=%-5s | atk_ok=%s hit=%s miss=%s cd=%s | %s"
              % (rnd, e.get("hp"), e.get("dead"), ("%.2f" % d) if d is not None else "-",
                 ps.get("health"), ps.get("alive"),
                 a["atk_ok"], a["atk_hit"], a["atk_miss"], a["atk_cd"],
                 a["last_atk_why"] or a["last_refusal"] or ""))
        if e.get("dead") is True or (e.get("hp") is not None and float(e["hp"]) <= 0):
            print("★ 目标死亡（第 %d 轮）" % rnd)
            break
        if "error" in e:
            print("★ 目标已不在世界表里（第 %d 轮）：%s" % (rnd, e["error"]))
            break

    print("-" * 70)
    print("最终实体：", ent(s, guid))
    print("最终统计：", atk(s))
    # ★ 掉落：死亡之后世界里的东西有没有变多？
    #   这一项必须打出来 —— 「打死了」和「打死了但什么都没掉」是两种完全不同的结果，
    #   而后者在原版里意味着 lootdropper 没接上（玩法链条断在最后一格）。
    try:
        tg = s.act_targets(0, 20)
        items = []
        for t in (tg or []):
            if isinstance(t, dict):
                items.append("%s/%s" % (t.get("p"), t.get("a")))
            else:
                items.append(str(t))
        print("死亡后附近目标（%d 个）：%s" % (len(items), items))
    except Exception as e:                                       # noqa: BLE001
        print("附近目标读取失败：%s: %s" % (type(e).__name__, e))
    snap2 = s.snapshot()
    print("世界实体数：%s（击杀前 %s）" % (snap2.get("n"), snap.get("n")))
    e = ent(s, guid)
    dead = e.get("dead") is True or ("error" in e)
    print("=" * 70)
    print("结论：" + ("✔ 打死了" if dead else "✘ 没打死"))
    return 0 if dead else 1


if __name__ == "__main__":
    sys.exit(main())
