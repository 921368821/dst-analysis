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
# ★ M4（2026-10-19）：server.py 拆成 7 个模块，锚点跟着走。
#   只改**目标文件**，锚点串与期望判据一个字符都没动 —— 这样「篡改仍然打在
#   同一行代码上」，变异测试的语义不变。
HTTPAPI = os.path.join(ROOT, "rt", "http_api.py")
LOOPS = os.path.join(ROOT, "rt", "loops.py")
SIMPY = os.path.join(ROOT, "rt", "sim.py")

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
    (HTTPAPI, "调试端点不再校验 --allow-debug（谁都能杀角色）",
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
    (LOOPS, "暂停时帧里不再报 paused（客户端会以为断线）",
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
    # ★★ M4 之后这两处落在**两个文件**里（sim.py 帧构建器 / loops.py 模拟循环），
    #   所以 path 给成列表，与 pairs 一一对应。只改一处仍然都是 no-op。
    ([SIMPY, LOOPS], "两处都不再给 paused（运行中的帧会缺这个字段）",
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


# ★ 中断保护用的标记文件（内容：这一轮改了哪些文件、原文是什么）
MARK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_falsify_inprogress.json")


def heal_leftover():
    """上一次被强行中断留下的篡改 → **自动还原**；还原不了就返回 False（要人工）。

    ★★ 为什么要有这个函数（2026-10-20 实测踩到）：
      原来的保护是「发现标记就**中止**」——安全，但把烂摊子留给人工：
      实测把整轮 `run_all` 掐掉之后，`rt/http_api.py` 就停在
      `_debug_allowed()` 直接 `return True` 的状态（**谁都杀得了角色**），
      而屏幕上只是一句「上一次没跑完，请手工还原」。这种「知道坏了但不动手」的
      保护，在人手忙的时候等于没有 —— 而脏源码继续被别的测试跑，结论全是假的。
      ⇒ 标记里**多存一份原文**，下次开跑先按原文写回去、逐字节校验、删标记，
        并**大声说明**「刚刚自动还原了什么」。旧格式标记（没有 originals）仍走
        「中止 + 打印」那条路 —— 读不到原文就不敢乱写。
    返回 True = 现在是干净源码，可以继续；False = 仍然是脏的。
    """
    if not os.path.exists(MARK):
        return True
    print("  ⚠ 发现上一次变异测试留下的标记（当时被强行中断，`finally` 没执行）。")
    try:
        info = json.load(io.open(MARK, encoding="utf-8"))
    except Exception as e:                                       # noqa: BLE001
        print("  ✘ 标记文件读不出来：%s" % e)
        info = {}
    orig = info.get("originals") or {}
    if not orig:
        print("  ✘ 标记里**没有原文**（旧格式或写入时失败），不敢自动改写源码。")
        print("     当时正在改：%s" % info.get("path"))
        print("     篡改说明：%s" % info.get("desc"))
        print("     改前片段：\n%s" % info.get("old"))
        print("     改成片段：\n%s" % info.get("new"))
        print("  ⇒ 手工还原后删掉 %s 再跑。" % MARK)
        return False
    ok = True
    for pth, body in orig.items():
        try:
            io.open(pth, "w", encoding="utf-8", newline="").write(body)
            # ★ 读回来也必须 `newline=""`：写是不翻译的，读若翻译就永远比不平。
            back = io.open(pth, encoding="utf-8", newline="").read()
            if back != body:
                ok = False
                print("  ✘ 自动还原后校验不一致：%s" % pth)
            else:
                print("     ✔ 已还原 %s（%d 字节）" % (os.path.basename(pth), len(body)))
        except OSError as e:
            ok = False
            print("  ✘ 还原失败 %s：%s" % (pth, e))
    if not ok:
        print("  ⇒ 仍有文件停在篡改态，**本轮不跑**（保持 %s 以便下次重试）。" % MARK)
        return False
    try:
        os.remove(MARK)
    except OSError:
        pass
    print("  ✔ 已自动还原到干净源码（标记已删除）。**上一次的结论作废**，本轮重跑。")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=2, help="每条篡改连续跑几遍（都要红）")
    ap.add_argument("--check-anchors", action="store_true",
                    help="★ 只静态检查「每条篡改的锚点串在目标文件里恰好出现 1 次」，"
                         "不改文件、不跑测试（重构之后先跑这个，几秒出结果）")
    ap.add_argument("--heal", action="store_true",
                    help="★ 只做一件事：把「上一次被硬中断」留在源码里的篡改按标记还原掉，"
                         "不跑任何测试。给 run_all 开头用（否则 ①~②e 全在**假源码**上跑）")
    ap.add_argument("--selftest-heal", action="store_true",
                    help="★ 只跑「还原路径」的自测（5 条用例 / 约 0.2 s）：证明 "
                         "heal_leftover() 在无标记 / 正常 / 旧格式 / 标记损坏 / 写不进去"
                         "五种输入下都按承诺行事。不改任何真实源码")
    a = ap.parse_args()

    # ★★ P50㉗：**先由自己证明「还原路径」是活的，再去改别人的源码。**
    #   这条放在 `heal_leftover()` 之前：自测用沙箱（临时目录 + 把 MARK 指过去），
    #   与真实标记无关，所以「有残留要还原」的时候也能照跑。
    #   为什么值得单独一条：`heal_leftover()` 是「变异被硬中断」之后**唯一**的补救，
    #   而它此前零测试。2026-10-20 那次中断把 `rt/rt_boot.lua` 停在
    #   `if true then return true end` 整整 10 小时；今早它确实还原成功了，
    #   但那是**一次幸运的实测**，不是一条判据 —— 它第一次被当判据用（本自测），
    #   就抓出了「写用 `newline=""`、读不用」的真缺陷（见 falsify_heal_selftest.py 头注释）。
    if a.selftest_heal:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import falsify_heal_selftest as _hs
        return _hs.main()

    # ★★ 开机第一件事：把「上一次被掐掉」留下的篡改还原掉（见 heal_leftover 的注释）。
    #   放在 `--check-anchors` 之前 —— 那个闸门本身就是「几秒内确认源码可用」，
    #   它更应该是**修好**源码的那一步，而不是在脏源码上报「锚点 0 次」。
    if not heal_leftover():
        print("    本轮**不执行任何篡改**（在脏源码上跑出来的结论没有意义）。")
        return 2
    # ★ 2026-10-20：`--heal` 只做到这里就返回 —— 让 `run_all` 能在**开跑前**调用它。
    #   原来还原只发生在 ②f 这一组，于是被中断过的源码会先被 ①~②e 当成真代码跑一遍
    #   （实测：`in_light_at` 停在 `if true then return true`，夜间光照的判据**全绿**）。
    if a.heal:
        print("  ✔ 源码已确认干净（没有待还原的篡改）")
        return 0


    # ★ M4 教训：拆文件 / 改实现会让锚点**悄悄失效**。
    #   以前只能在跑完一整轮（每条都要起服务端、跑子集测试，几十分钟）之后
    #   从「锚点串出现 0 次」里发现 —— 那个反馈太晚，而且和「测试真的红了」
    #   混在同一屏输出里。这里给一个 3 秒的静态闸门。
    if a.check_anchors:
        bad = 0
        for path, desc, old, new, only, expect in MUTATIONS + [CONTROL]:
            pairs = list(zip(old, new)) if isinstance(old, list) else [(old, new)]
            paths = path if isinstance(path, list) else [path] * len(pairs)
            if not all(os.path.exists(p_) for p_ in paths):
                print("  ✘ [%s] 目标文件不存在：%s" % (desc, paths)); bad += 1; continue
            srcs = {p_: io.open(p_, encoding="utf-8", newline="").read() for p_ in paths}
            for (o, _nw), p_ in zip(pairs, paths):
                cnt = srcs[p_].count(o)
                if cnt != 1:
                    print("  ✘ [%s] 锚点出现 %d 次（要求 1）：%s\n     %r"
                          % (desc, cnt, os.path.basename(p_), o[:70]))
                    bad += 1
        n = len(MUTATIONS) + 1
        print("锚点自检：%d 条篡改，%d 条有问题" % (n, bad))
        return 0 if bad == 0 else 1

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
    bad = 0
    for path, desc, old, new, only, expect in MUTATIONS + [CONTROL]:
        # ★ `from`/`to` 也允许是**列表**（一处多改）：有些契约有**多个冗余来源**，
        #   只改一个不改变可观测行为 ⇒ 那种篡改是 no-op，测不出判据的死活。
        pairs = list(zip(old, new)) if isinstance(old, list) else [(old, new)]
        # ★★ M4：`path` 也允许是**列表**（与 pairs 一一对应，可跨文件）。
        #   起因：拆 server.py 时那条「两处都不再给 paused」的两处锚点
        #   分别落到了 sim.py（帧构建器的默认值）与 loops.py（模拟循环的显式赋值）。
        #   如果把它拆成两条单文件篡改，每条又都退化成 no-op（正是它当初要解决的
        #   问题）—— 所以「一处多改」必须**同时支持跨文件**。
        paths = path if isinstance(path, list) else [path] * len(pairs)
        originals = {}          # 路径 -> 改前内容（还原用）
        mutateds = {}           # 路径 -> 当前内容（改后）
        for pth in paths:
            if pth not in originals:
                # ★★ 2026-10-21：读原文也必须 `newline=""`。
                #   默认的 universal-newlines 会把 CRLF 读成 LF ⇒ 存进标记里的「原文」
                #   已经不是原文了 ⇒ 还原时按它写回，整个文件的 CRLF 被**静默换成 LF**
                #   （真损坏），而下面那次「读回来比一遍」用的也是 universal 读法，
                #   于是它会说「一致」—— **一次损坏 + 一次假绿灯**。
                #   现有的 4 个变异目标恰好都是纯 LF，所以这个洞从没被踩到；
                #   一旦哪天出现 CRLF 目标（本仓库的 `tests/run_all.sh` 就是 CRLF），
                #   它会以「还原成功」的样子把文件改掉。
                originals[pth] = io.open(pth, encoding="utf-8", newline="").read()
                mutateds[pth] = originals[pth]
        anchor_bad = False
        for (o, nw), pth in zip(pairs, paths):
            cnt = mutateds[pth].count(o)
            if cnt != 1:
                bad += 1
                anchor_bad = True
                print("  ✘ [%s] 锚点串出现 %d 次（要求恰好 1 次）—— 代码被重构过，"
                      "这条篡改已失效，必须更新锚点（**不许静默跳过**）[%s]"
                      % (desc, cnt, os.path.basename(pth)))
                break
            mutateds[pth] = mutateds[pth].replace(o, nw)
        if anchor_bad:
            continue
        path = paths[0]          # 单文件路径留给下面的标记文件与打印用
        try:
            # ★ 写标记：**在改文件之前**落盘。被 kill 时它还在 ⇒ 下次开跑会拒绝执行
            #   （见 main 开头的自检）。标记里带足够的信息，让没有 git 的人也能手工还原。
            try:
                io.open(MARK, "w", encoding="utf-8", newline="").write(
                    json.dumps({"pid": os.getpid(),   # ★ 供 `_src_guard` 判「这个变异还在不在跑」
                                "path": paths, "desc": desc, "old": old, "new": new,
                                # ★ 原文一起存：被 kill 时下次能**自动还原**（见 heal_leftover）
                                "originals": originals},
                               ensure_ascii=False, indent=1))
            except OSError as e:
                print("  ⚠ 写不了标记文件（%s）—— 中断保护这次不生效" % e)
            for pth, body in mutateds.items():
                io.open(pth, "w", encoding="utf-8", newline="").write(body)
            reds = run_one(only, a.runs)
        finally:
            for pth, body in originals.items():
                io.open(pth, "w", encoding="utf-8", newline="").write(body)
                # ★ 还原必须**被验证**：写完再读回来比一次。还原不干净的话，
                #   后面所有结果都建立在脏源码上（这比红更危险，因为它看起来是绿的）。
                back = io.open(pth, encoding="utf-8", newline="").read()
                if back != body:
                    print("  ✘ [%s] **还原失败**：%s 与改前不一致（后续结论全部不可信）"
                          % (desc, pth))
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
