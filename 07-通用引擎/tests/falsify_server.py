# -*- coding: utf-8 -*-
"""falsify_server.py —— **服务端/引擎侧的变异测试**（对应客户端的 `falsify_client.js`）。

★★ 为什么要有（与客户端那份同源）：
  「检查写好了」≠「检查生效过」。客户端那份变异测试今天已经证明过一次价值
  （它当场指出我自己的锚点过期），而**服务端 / 引擎侧的判据从来没有被这样撞过** ——
  它们全都「绿着」，但**凭什么绿**没人证明过。

做法：把 `rt/`（引擎与服务端）逐条打上一个**语义篡改**，然后只跑「它该被抓住的那条判据」
（`RT_ONLY=<编号>`，见 `test_rt.py` 的 `check()`），要求它**变红**。
文件在 `finally` 里一定被还原（哪怕中途崩掉）。

★★ 关键纪律（与客户端那份一致）：
  · 篡改的**锚点串**在源码里找不到（有人重构过）⇒ **报错，不许静默跳过** ——
    静默跳过就等于「这条判据从此没人守」，而那是最坏的情形（绿着，但其实什么都没验）。
  · 每条篡改都要**连续跑 N 遍都红**才算数：只红一次可能是抖（本工程今天吃过这个亏：
    砍树那件事在不同运行之间结果并不完全一样）。
  · 配一条**对照篡改**（只改注释）⇒ 不许有任何判据变红。

用法：python tests/falsify_server.py [--runs 2]
退出码：0 = 每条篡改都被它该被抓住的判据抓住了
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PY = sys.executable

BOOT = os.path.join(ROOT, "rt", "rt_boot.lua")
SRV = os.path.join(ROOT, "rt", "server.py")

# ---------------------------------------------------------------- 篡改清单
# (文件, 说明, from, to, RT_ONLY 过滤词, 期望变红的判据名子串)
MUTATIONS = [
    (BOOT, "默认世界内容关掉（14 → 0）",
     "local WORLD_CONTENT = tonumber(os.getenv(\"RT_WORLD_CONTENT\") or \"\") or 14",
     "local WORLD_CONTENT = 0",
     "E6", "E6"),

    (BOOT, "自动复活延迟改到 10 分钟（等于不复活）",
     "local RESPAWN_DELAY = 90        -- 拍：死后多久自动复活（3 s）",
     "local RESPAWN_DELAY = 18000     -- 拍：死后多久自动复活（3 s）",
     "E5", "E5"),

    (BOOT, "光照代理整个不生效（改成永不调用）",
     "    sync_grue_light()\n\n    -- ★ 死了就计时，到点自动复活",
     "    -- sync_grue_light()\n\n    -- ★ 死了就计时，到点自动复活",
     "E4", "E4"),

    (BOOT, "把「到达距离」的补丁去掉（PICKUP 就永远「没到达」）",
     "    if ba.distance == nil and ba.arrivedist == nil then\n        ba.arrivedist = ACT_HIT\n        act_arrive_n = act_arrive_n + 1\n    end",
     "    if false then\n        ba.arrivedist = ACT_HIT\n        act_arrive_n = act_arrive_n + 1\n    end",
     "E3", "E3"),

    (BOOT, "把「到范围后定时重发」去掉（连砍就不成立）",
     "                        pend.next_t = steps_done + ACT_REPEAT\n                    end",
     "                        pend.next_t = steps_done + 99999\n                    end",
     "E2", "E2"),

    (BOOT, "营火附近不算在光里（夜里必死那条回来）",
     "function M.in_light_at(x, z, isnight)\n    if not isnight then return true end",
     "function M.in_light_at(x, z, isnight)\n    if true then return true end",
     "E7", "E7"),

    # ★ P41 起锚点改到 `_debug_allowed` 的**函数体**上。
    #   原来锚的是 `if not getattr(self, "allow_debug", False):` —— 这句话在
    #   `/debug/kill` 与 `/debug/*` 里各有一份，加了调试三件套之后锚点出现 2 次，
    #   脚本如实报红（「锚点串出现 2 次」）。当时两种修法：
    #     ① 把锚点写长一点，指定改哪一处 —— 治标，重复本身还在；
    #     ② 把开关收敛成一个方法，锚它 —— 治本。
    #   选了 ②：现在「调试端点能不能开」全工程只有一处判定。
    (SRV, "调试端点不再校验 --allow-debug（谁都能杀角色）",
     "        return bool(getattr(self, \"allow_debug\", False))",
     "        return True",
     "E8", "E8"),

    (BOOT, "快照不再过滤「不可绘制」的实体（内部实体会混进画面）",
     "        if x ~= nil and inst.prefab ~= nil and as0 ~= nil and as0._build ~= nil then",
     "        if x ~= nil then",
     "B23", "B23"),
    # ★★ 更正：我**曾经**把「帧里不报 paused 没人守」记成缺口 —— **记错了**。
    #   查 B16 的实现才看到它里面就有 `if not last.get("paused")`。
    #   ⇒ 那就把当时跳过的那条篡改补上：**让 B16 自己来证明它在守**。
    #   （教训：登记「缺口」之前，先去**读一遍**那条判据的实现，别凭印象写。）
    (SRV, "暂停时帧里不再报 paused（客户端会以为断线）",
     "                snap[\"paused\"] = True          # ★ 帧里如实报「世界停住了」",
     "                pass  # 故意不报 paused",
     "B16", "B16"),
    # ★★ 这条篡改我**改过一次**，过程值得记：
    #   第一版做的是「删掉模拟循环里那句 `snap["paused"] = False`」——
    #   结果**没被抓住**。查下去才明白：**帧构建器那边本来就有个默认值**
    #     `out = {..., "paused": False}`（注释写着「好让『帧里一定有这个字段』
    #      这件事在任何调用路径上都成立」）⇒ 删掉模拟循环那句**不改变可观测行为**
    #   ⇒ 这是一条**无效篡改**（no-op），不是「判据没守住」。
    #   ⇒ 改成动**那个默认值**：字段就会从「运行中的帧」里消失。
    #   ★ 教训：变异测试报「没被抓住」时，第一件事是**检查这条篡改本身是不是 no-op**。
    # ★★ 这条篡改**改过两次**，过程是这一轮最有价值的一段：
    #   ① 第一版：「删掉模拟循环里那句 `snap["paused"] = False`」⇒ **没被抓住**；
    #   ② 第二版：「删掉帧构建器里的默认值 `"paused": False`」⇒ **还是没被抓住**。
    #   查下去才明白：**这个契约有两个冗余来源**（帧构建器的默认值 + 模拟循环的显式赋值），
    #   **删掉任何一个都不改变可观测行为** ⇒ 两条都是**无效篡改**（no-op），
    #   而不是「判据没守住」。
    #   ⇒ ③ 两边一起改（为此给这个脚本加了「一处多改」的能力），这才真的改变了可观测行为。
    #   ★★ 教训：变异测试报「没被抓住」时，**第一件事是检查这条篡改本身是不是 no-op** ——
    #      否则你会去改一条本来就没问题的判据（今天差点就这么干）。
    (SRV, "两处都不再给 paused（运行中的帧会缺这个字段）",
     ['               "paused": False}', '            snap["paused"] = False'],
     ['               }', '            pass  # 故意也不补'],
     "B16", "B16"),

    # ---- P39（2026-10-18）：自身状态 ----------------
    # ★ 这两条都是「**看起来有数字，但那个数字不是真的**」那一类，
    #   正是 E10 存在的理由：它不只看「有没有字段」，还看
    #   ① 饥饿**真的在掉**（③）、② 不存在的槽位**不许**回一串 0（④）。
    (BOOT, "饥饿恒报最大值（看着有数字，其实是个死值）",
     "        hunger    = hu and hu.current or nil,",
     "        hunger    = hu and hu.max or nil,",
     "E10", "E10"),

    (BOOT, "不存在的槽位也报 ok=true（用户只会看到一串 nil/0）",
     '        return { ok = false, slot = slot, why = "槽位 " .. tostring(slot) .. " 没有玩家" }',
     '        return { ok = true, slot = slot }',
     "E10", "E10"),
]

# 对照：只改注释，不许有任何判据变红
CONTROL = (BOOT, "（对照）只改注释，不该有任何判据变红",
           "--=============================================================================\n-- 死亡与复活（2026-10-16 加）",
           "--=============================================================================\n-- 死亡与复活（2026-10-16 加）[注释改过了]",
           "E5", None)


def run_one(only, runs):
    """跑 N 遍 `RT_ONLY=<only>`，返回 (红项集合, 每遍的红项列表)。"""
    reds_all = []
    for _ in range(runs):
        env = dict(os.environ)
        env["RT_ONLY"] = only
        try:
            p = subprocess.run([PY, "-u", os.path.join(HERE, "test_rt.py")],
                               cwd=ROOT, capture_output=True, text=True, env=env, timeout=300)
            out = (p.stdout or "") + (p.stderr or "")
        except subprocess.TimeoutExpired:
            out = "<超时>"
        red = set()
        for line in out.split("\n"):
            m = re.match(r"\s*✘\s+(\S+\s*[^\s]*)", line)
            if m:
                red.add(line.strip()[:60])
        reds_all.append(red)
    return reds_all


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=2, help="每条篡改连续跑几遍（都要红）")
    a = ap.parse_args()

    print("═" * 74)
    print("  服务端/引擎判据的**变异测试**（把实现改坏，看判据是否真的变红）")
    print("  每条连续跑 %d 遍（都要红才算数：只红一次可能是抖）" % a.runs)
    print("═" * 74)

    # ★★★ 开机自检：**源码是不是还停在上一次被中断的篡改态**（2026-10-18 加）
    #   起因：本脚本的还原写在 `finally` 里 —— 但 `finally` 只在**进程还活着**时执行。
    #   实测发生过的情形：外层把整套测试 `kill` 掉（超时 / Ctrl-C / 关终端），
    #   进程在「已写入篡改」与「跑判据」之间被杀 ⇒ **源码留在篡改态**，
    #   而屏幕上只有一句「锚点串出现 0 次」，**看起来像锚点过期**，排查方向被带偏。
    #   更糟的是：源码带着篡改继续被别的测试跑，会给出**假的实现行为**。
    #   ⇒ 用「写一个标记文件 + 记录目标路径」的办法：开跑前发现标记还在，
    #     就说明上一轮没走完，**直接中止**（退出码 2），并把「当时改的是哪个文件、
    #     哪段串」打出来，好在没有 git 的情况下手工还原。
    #   ⚠️ 第一版做的是「扫所有篡改的目标串在不在源码里」——**假警报**：
    #     `if x ~= nil then` 这种短串本来就合法地存在于别处。
    #     判据必须是「上次真的写到一半」这个**事件**，而不是「源码里有没有某个串」。
    MARK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_falsify_inprogress.json")
    if os.path.exists(MARK):
        print("  ✘ 上一次变异测试**没有跑完**（被强行中断，`finally` 没执行）。")
        try:
            info = json.load(io.open(MARK, encoding="utf-8"))
            print("     当时正在改：%s" % info.get("path"))
            print("     篡改说明：%s" % info.get("desc"))
            print("     改前片段（用于对照还原）：\n%s" % info.get("old"))
            print("     改成片段：\n%s" % info.get("new"))
        except Exception as e:                                   # noqa: BLE001
            print("     （标记文件读不出来：%s）" % e)
        print("  ⇒ 手工还原被改的文件后，删掉 %s 再跑。" % MARK)
        print("    本轮**不执行任何篡改**（在脏源码上跑出来的结论没有意义）。")
        return 2

    bad = 0
    for path, desc, old, new, only, expect in MUTATIONS + [CONTROL]:
        original = io.open(path, encoding="utf-8").read()
        # ★ `from`/`to` 也允许是**列表**（一处多改）：有些契约有**多个冗余来源**，
        #   只改一个不改变可观测行为 ⇒ 那种篡改是 no-op，测不出判据的死活。
        pairs = list(zip(old, new)) if isinstance(old, list) else [(old, new)]
        mutated = original
        anchor_bad = False
        for o, nw in pairs:
            cnt = mutated.count(o)
            if cnt != 1:
                bad += 1
                anchor_bad = True
                print("  ✘ [%s] 锚点串出现 %d 次（要求恰好 1 次）—— 代码被重构过，"
                      "这条篡改已失效，必须更新锚点（**不许静默跳过**）" % (desc, cnt))
                break
            mutated = mutated.replace(o, nw)
        if anchor_bad:
            continue
        try:
            # ★ 写标记：**在改文件之前**落盘。被 kill 时它还在 ⇒ 下次开跑会拒绝执行
            #   （见 main 开头的自检）。标记里带足够的信息，让没有 git 的人也能手工还原。
            try:
                io.open(MARK, "w", encoding="utf-8", newline="").write(
                    json.dumps({"path": path, "desc": desc, "old": old, "new": new},
                               ensure_ascii=False, indent=1))
            except OSError as e:
                print("  ⚠ 写不了标记文件（%s）—— 中断保护这次不生效" % e)
            io.open(path, "w", encoding="utf-8", newline="").write(mutated)
            reds = run_one(only, a.runs)
        finally:
            io.open(path, "w", encoding="utf-8", newline="").write(original)
            # ★ 还原必须**被验证**：写完再读回来比一次。还原不干净的话，
            #   后面所有结果都建立在脏源码上（这比红更危险，因为它看起来是绿的）。
            back = io.open(path, encoding="utf-8").read()
            if back != original:
                print("  ✘ [%s] **还原失败**：%s 与改前不一致（后续结论全部不可信）"
                      % (desc, path))
                bad += 1
            try:
                os.remove(MARK)
            except OSError:
                pass
        if expect is None:
            # 对照：每一遍都不该有红项
            if any(r for r in reds):
                bad += 1
                print("  ✘ [%s] 本该零红，却红了：%s" % (desc, " | ".join(sorted(set().union(*reds)))))
            else:
                print("  ✔ [%s] 红 0 条（正确地不受影响，%d 遍）" % (desc, a.runs))
            continue
        hit_all = all(any(expect in r for r in red) for red in reds)
        if hit_all:
            print("  ✔ [%s] 被抓住 → %s（%d 遍都红）" % (desc, expect, a.runs))
        else:
            bad += 1
            print("  ✘ [%s] **没被抓住**：%d 遍里有几遍没红。红项：%s" % (
                desc, sum(1 for r in reds if not any(expect in x for x in r)),
                " | ".join(sorted(set().union(*reds))) or "（无）"))
    print("\n  结果：" + ("✔ 每条篡改都被对应的判据抓住" if bad == 0 else "✘ %d 处失效" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
