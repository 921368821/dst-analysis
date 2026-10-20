#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_plan.py —— 核对 `开发计划.md` 里的**可机器验证数字**（P8）

为什么需要它
    06 工程早就吃过这个亏：同一个数字被抄在 4 份 md 里，改一处其余三处集体过期。
    07 工程的 `开发计划.md` 是**边做边写**的，里面有几十个具体数字
    （测试项数、带宽、tick 耗时、字节数…）—— **每一个都会随代码变化而失效**。
    ⇒ 与其靠人记得回头改，不如让工具在**每次跑的时候**把数字重测一遍。

判据
    只查**可复现**的数字：
      · 各测试文件的 `check(...)` 条数  —— 数得出来
      · 产物字节数（图集/存档）         —— 量得出来
      · 宿主回归的入口数与断言数        —— 跑一遍就有
      · 进程内实测的几个量（tick 耗时、帧大小、二进制省比）—— 短时间内可复现
    **不查**「某次运行的瞬时值」（如当时的 tick/s 具体到个位）—— 那类只作参考。

用法
    python tools/verify_plan.py            # 全部
    python tools/verify_plan.py --fast     # 跳过要起运行时的测量
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAN = os.path.join(ROOT, "开发计划.md")
# ★ 解释器与 node 不再写死：统一由 tools/_rt_env.py 解析
#   （原来这里硬编码了用户目录，工作区一搬迁就整条链失效）
sys.path.insert(0, os.path.join(ROOT, "tools"))
from _rt_env import PY, NODE, ENGINE, RUNNER   # noqa: E402

HITS = []
# ★★ 环境缺失**不是**文档过期，必须分开记（见 `_can_import_lupa` 处的长注释）
ENV_MISSING = []


def hit(where, kind, found, real, ctx=""):
    HITS.append((where, kind, found, real, ctx))


def read(p):
    return io.open(p, encoding="utf-8", errors="replace").read()


# ---------------------------------------------------------------- 1. 测试项数
TEST_FILES = {
    "tests/test_client.js": "客户端",
    "tests/test_render_atlas.js": "精灵纯函数",
    "tests/test_protocol.js": "二进制帧协议",
    "tests/test_rt.py": "端到端",
    "tests/test_protocol_parity.py": "跨实现一致性",
    "tests/test_stress.py": "规模与并发",
    "tests/test_deploy.py": "发布演练（走 deploy/start.sh）",
    # ★ 2026-10-18（C1/C2）：本轮新加的三组 —— **必须进这张表**，否则
    #   README 的「合计 N 项」会把 44 条新断言漏掉，却仍然显示为「对得上」。
    #   这正是 C 类问题的形状：**缺登记**，而不是算错。
    "tests/test_render_batch.js": "批渲染（C2 模块侧）",
    "tests/test_client_batch.js": "批渲染（C2 客户端侧）",
    "tests/test_stall_watchdog.py": "停帧看门狗（C1）",
    # ★★ 2026-10-20（P50）：`tests/test_units.py` 从 L6 落地起就**没进过这张表** ——
    #   于是它的 12 条（现 19 条）模块级断言从来没被算进「合计 N 项」，
    #   而 README 的总数仍然显示「对得上」。这正是上面那条注释说的 C 类形状：
    #   **缺登记**，不是算错。发现路径也一样：本轮给 hub 补 7 条单测，
    #   跑 `verify_plan --fast` 总数一动不动（179 还是 179）——「加了东西数字不变」本身就是判据。
    "tests/test_units.py": "模块级单测（L6，2 秒级）",
}


# ★ 这三份**必须**自己声明条数（见 `_declared_items` 的说明）
MUST_DECLARE = {
    "tests/test_render_batch.js",
    "tests/test_client_batch.js",
    "tests/test_stall_watchdog.py",
}


def _declared_items(path):
    """读测试文件里**自己声明**的断言条数（`EXPECT_ITEMS = 21` / `const EXPECT_ITEMS = 8`）。

    ★★ 为什么需要它（2026-10-18，C2 那轮踩到的）：
      静态数 `check(` 的**调用行**，与「实跑多少条断言」**不是一回事** ——
      断言写在循环里时，1 行调用能跑出 4 条（①e 的几何/UV 等价按 4 个缩放档各跑一条：
      静态 15 行 vs 实跑 21 条）。这时若一边按静态数、一边按实跑数，
      两个数就会**各自过期**，而任何「两处一起过期 ⇒ 一致性判据恒绿」的陷阱
      本工程已经踩过好几次。
      ⇒ 口径统一为「文件里显式声明的条数」，且**声明的正确性由测试自己守**：
        三份测试都在结尾校验 `实跑条数 == EXPECT_ITEMS`，不符直接退出 1
        （反向验证过：把 21 改成 20 → 打印 ✘ 且退出码 1）。
    """
    s = read(path)
    m = re.search(r"(?:const\s+)?EXPECT_ITEMS\s*=\s*(\d+)", s)
    return int(m.group(1)) if m else None


def file_items(path):
    """某个测试文件的断言条数：**有声明用声明**，否则退回静态数 `check(` 调用行。"""
    n = _declared_items(path)
    return n if n is not None else count_checks(path)


def count_checks(path):
    """数 `check(` 的**调用**数（跳过函数定义与注释）"""
    s = read(path)
    n = 0
    for line in s.split("\n"):
        st = line.strip()
        # ★ 要同时跳过 **Python 的 `def check` 和 JS 的 `function check`** ——
        #   第一版只跳了 `def `，于是 3 个 JS 文件各自把**定义行**也算成了调用，
        #   总数虚高 3（61 vs 实测 58）。这与本工程反复出现的母题同源：
        #   **同一件事在不同语言里写法不同，而我只处理了一种。**
        if (st.startswith("#") or st.startswith("//")
                or st.startswith("def ") or st.startswith("function ")
                or st.startswith("const check") or st.startswith("let check")):
            continue
        n += len(re.findall(r'(?<![\w.])check\(', line))
    return n


def check_test_counts():
    plan = read(PLAN)
    total = 0
    for f, name in TEST_FILES.items():
        p = os.path.join(ROOT, f)
        if not os.path.isfile(p):
            hit(f, "测试文件不存在", f, "缺文件")
            continue
        n = file_items(p)
        # ★ 声明了条数的文件，**必须真的声明着**：拿掉 `EXPECT_ITEMS` 不许静默退回
        #   静态数（那会让「实跑 21 条」悄悄变成「15 行调用」，而总数照样"对得上"）。
        if f in MUST_DECLARE and _declared_items(p) is None:
            hit(f, "缺 EXPECT_ITEMS 声明", "（无）", "该文件必须显式声明断言条数")
        total += n
        # 计划里有一张表写着各项条数（形如 `| Python 端到端 | **29 / 0** |` 之类）
        # 这里只对**总数**做硬核对，避免格式一改就误报
    # ★★ 必须**跳过标了「当时值」的历史引用** —— 这是本工程的既有约定
    #   （06 工程的 audit_doc_numbers 同样这么做）：历史节里的旧数字是**故意保留**的，
    #   把它们当「过期」报出来，等于逼人删掉「当时发生了什么」。
    #   第一版没跳过 ⇒ 立刻把 §9g.3 那条**已正确标注**的历史值报成不一致（假阳性）。
    live = "\n".join(l for l in plan.split("\n") if "当时值" not in l)
    m = re.search(r'合计 \*{0,2}(\d+) 项测试', live)
    if m:
        claimed = int(m.group(1))
        if claimed != total:
            hit("开发计划.md", "测试总数", "合计 %d 项" % claimed, "实测 %d 项" % total,
                "各文件: " + " ".join("%s=%d" % (TEST_FILES[f], file_items(os.path.join(ROOT, f)))
                                     for f in TEST_FILES if os.path.isfile(os.path.join(ROOT, f))))
    else:
        hit("开发计划.md", "找不到测试总数声明", "（无）", "实测 %d 项" % total)
    return total


# ---------------------------------------------------------------- 2. 产物字节数
def check_artifacts():
    # ★★ 跳过标了「当时值」的历史行 —— **与 `check_test_counts` 用同一条约定**。
    #   第一版这里直接 `re.search(plan)` 全文找，于是把 §9e.2 那张**P5 那时的验收表**
    #   当成「当前声明」来核对：我加了 3 条动画后 JSON 从 2784 → 4678 字节，
    #   工具报红 —— 报得对（数字确实变了），但**该改的不是那张历史表**。
    #   一张验收表是「当时发生了什么」，改它等于篡改历史。
    plan = "\n".join(l for l in read(PLAN).split("\n") if "当时值" not in l)
    # 自产图集（wilson）：字节数写在本文件「当前基线」一节里
    jp = os.path.join(ROOT, "_demo_atlas", "json", "wilson.json")
    pp = os.path.join(ROOT, "_demo_atlas", "anim_data", "wilson__atlas-0.png")
    if os.path.isfile(jp) and os.path.isfile(pp):
        js, ps = os.path.getsize(jp), os.path.getsize(pp)
        m = re.search(r'PNG \*\*(\d+) 字节\*\* \+ JSON \*\*(\d+) 字节\*\*', plan)
        if m:
            if int(m.group(1)) != ps:
                hit("开发计划.md", "图集 PNG 字节", m.group(1), str(ps))
            if int(m.group(2)) != js:
                hit("开发计划.md", "图集 JSON 字节", m.group(2), str(js))
    else:
        hit("_demo_atlas", "自产图集缺失", "应有 json/ 与 anim_data/", "缺文件",
            "跑 tools/pack_atlas.py --out _demo_atlas --build wilson")


# ---------------------------------------------------------------- 3. 入口数 / 断言数
def classify_lua_failure(text):
    """Lua 跑不出结果时，分清「**环境缺 lupa**」与「**脚本真的报错**」。

    ★★ 为什么要分（2026-10-20 实测）：用 PATH 上那个没装 lupa 的 python 跑本工具，
       输出是 **2 处「文档数字过期」**（`tests.lua` / `mech.lua` 的实测值变成了
       `ModuleNotFoundError: No module named 'lupa'`）—— 而计划与 README **一个字都没错**。
       这与 H3 是同一类毛病：**一条环境故障被打印成 N 份「看起来像代码坏了」的证据**。
       （H3 现场：`dstsrc` 联接丢了，14 个入口各抛一次 Lua 栈，看起来像 14 个 bug。）

    返回 `"env"` / `"lua"`（其余一律按「脚本报错」处理，宁可吵也不静默）。
    """
    if re.search(r"No module named ['\"]?lupa", text or ""):
        return "env"
    if "ModuleNotFoundError" in (text or "") and "lupa" in (text or ""):
        return "env"
    return "lua"


def _can_import_lupa():
    """本进程用的解释器能不能 `import lupa`。

    ★ `PY` 就是 `sys.executable`（`_rt_env.py`）⇒ **用哪个 python 跑本工具，
      就用哪个 python 去跑 06 的 Lua 入口**。所以这一步必须先试，不能等跑崩了再猜。
    """
    try:
        r = subprocess.run([PY, "-c", "import lupa"], capture_output=True, timeout=60)
        out = (r.stdout + r.stderr).decode("utf-8", "replace")
        return r.returncode == 0, out.strip().splitlines()[-1] if out.strip() else ""
    except Exception as e:                                       # noqa: BLE001
        return False, "%s: %s" % (type(e).__name__, e)


def _env_hit(what, why, detail=""):
    ENV_MISSING.append((what, why, detail))


def check_host():
    # ★ 用 _rt_env 里的同一份定义（原来这里自己又拼了一遍路径 —— 两处实现的老毛病）
    engine, runner = ENGINE, RUNNER
    entries = ["run", "batch", "player", "play", "full", "render", "seasons",
               "equip", "burn", "perish", "tests", "mech", "reachability", "world"]
    missing = [e for e in entries if not os.path.isfile(os.path.join(engine, e + ".lua"))]
    if missing:
        hit("06-引擎复刻", "入口缺失", "14 个", "缺 " + ",".join(missing))
    # ★★ 下面两段**要跑 Lua**。先判环境：缺 lupa 时它们一条都跑不了，
    #   而原来的表现是报「文档数字过期」——把环境问题说成了文档问题。
    ok, why = _can_import_lupa()
    if not ok:
        _env_hit("宿主断言数 / 机制横扫（06-引擎复刻）",
                 "PY 跑不了 Lua：%s" % PY, why)
        return

    # 断言数：跑一次 tests.lua（约 1 秒）
    try:
        r = subprocess.run([PY, runner, "5.1", os.path.join(engine, "tests.lua")],
                           capture_output=True, cwd=engine, timeout=180)
        t = (r.stdout + r.stderr).decode("utf-8", "replace")
        m = re.search(r'共 (\d+) 条断言，失败 (\d+) 条', t)
        if m:
            n, bad = int(m.group(1)), int(m.group(2))
            plan = read(PLAN)
            mm = re.search(r'(\d+) 条断言 0 失败', plan)
            if mm and int(mm.group(1)) != n:
                hit("开发计划.md", "宿主断言数", mm.group(1), str(n))
            if bad:
                hit("06-引擎复刻/tests.lua", "断言有失败", "0", str(bad))
        elif classify_lua_failure(t) == "env":
            _env_hit("宿主断言数（tests.lua）", "跑起来但缺 lupa：%s" % PY, t[-200:])
        else:
            hit("06-引擎复刻/tests.lua", "跑不出断言数", "—", t[-120:])
    except Exception as e:                                       # noqa: BLE001
        hit("06-引擎复刻/tests.lua", "跑不动", "—", "%s: %s" % (type(e).__name__, e))

    return run_mech_check(engine, runner)


def run_mech_check(engine, runner):
    """跑一次 `mech.lua`，核对文档里那句「N 条机制横扫 0 失败」。

    ★★ 为什么补这一条（2026-10-18）：README 的分组表里写着「`mech.lua` **26 条
      机制横扫 0 失败**」，而**没有任何工具重算过它** —— 实跑是 **50**（本轮 C3~C6
      的判据加进去之后）。数字写错不是最坏的，最坏的是它**在输出里长得像已被核对的**：
      同一张表里 `tests.lua` 的 99 条有工具守、`mech` 的 26 条没有，读者分不出。
    """
    try:
        r = subprocess.run([PY, runner, "5.1", os.path.join(engine, "mech.lua")],
                           capture_output=True, cwd=engine, timeout=300)
        t = (r.stdout + r.stderr).decode("utf-8", "replace")
        m = re.search(r'通过 (\d+) · 宿主边界 (\d+) · 失败 (\d+)', t)
        if not m:
            if classify_lua_failure(t) == "env":
                _env_hit("机制横扫（mech.lua）", "跑起来但缺 lupa：%s" % PY, t[-200:])
            else:
                hit("06-引擎复刻/mech.lua", "跑不出机制横扫汇总", "—", t[-120:])
            return
        n, bad = int(m.group(1)), int(m.group(3))
        if bad:
            hit("06-引擎复刻/mech.lua", "机制横扫有失败", "0", str(bad))
        check_mech_claim(n)
    except Exception as e:                                       # noqa: BLE001
        hit("06-引擎复刻/mech.lua", "跑不动", "—", "%s: %s" % (type(e).__name__, e))


def check_mech_claim(n, docs=None):
    """文档里的「`mech.lua` **N 条机制横扫 0 失败**」必须与实跑条数一致。

    `docs` 只给规则自检用（{文件名: 文本}）。
    """
    items = list(docs.items()) if docs is not None else [
        (rel, read(os.path.join(ROOT, rel))) for rel in DOC_COUNTS
        if os.path.isfile(os.path.join(ROOT, rel))]
    for rel, text in items:
        for m in re.finditer(r'(\d+) 条机制横扫', text):
            if int(m.group(1)) != n:
                hit(rel, "机制横扫条数过期", "%s 条" % m.group(1), "实跑 %d 条" % n)


# ---------------------------------------------------------------- 4. 进程内实测
def check_runtime():
    sys.path.insert(0, os.path.join(ROOT, "rt"))
    from server import Sim
    import protocol_bin as PB
    for n in (0, 400):
        os.environ["RT_SPAWN"] = str(n)
        s = Sim(seed=20261015, tick_hz=30).boot()
        for _ in range(30):
            s.step()
        ms = 1e9
        for _ in range(3):
            t0 = __import__("time").perf_counter()
            for _ in range(120):
                s.step()
            ms = min(ms, (__import__("time").perf_counter() - t0) * 1000 / 120)
        snap = s.snapshot()
        enc = PB.BinEncoder()
        enc.encode(snap)
        b = len(enc.encode(s.snapshot()))
        j = len(json.dumps(snap, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
        if n == 0:
            if ms > 33.3 * 0.05:
                hit("默认世界", "tick 占预算", "<5%", "%.1f%%" % (100 * ms / 33.3))
        else:
            # 计划里声明的是「规模档 ≥20 tick/s」
            if 1000 / ms < 20:
                hit("400 生成档", "tick/s", "≥20", "%.1f" % (1000 / ms))
            # 二进制省比：计划声明 ≥70%
            save = 100 * (1 - b / j)
            if save < 70:
                hit("400 生成档", "二进制省比", "≥70%", "%.0f%%" % save)


# ------------------------------------------------- 4. 测试编号的可引用性
def collect_ids():
    """把各测试文件里 `check("<编号> ...")` 的编号收集起来。

    ★ 支持的编号形态：`A3` / `A3b` / `B19` / `T5` / `S4` / `C0` / `TC12`
      （本工程的两套命名：任务号 `Txx` 在 06 的文档里，测试分组号 `TCxx` 在 `tests.lua` 里；
       07 这边用的是 A/B/T/S/C 前缀。）
    """
    ids = {}
    for f in TEST_FILES:
        p = os.path.join(ROOT, f)
        if not os.path.isfile(p):
            continue
        for m in re.finditer(r"""(?<![\w.])check\(\s*["']([A-Z]{1,2}\d{1,3}[a-z]?)\b""", read(p)):
            ids.setdefault(m.group(1), []).append(f)
    # ★ 顺带把 **06 的测试分组号**（`tests.lua` 里的 `hr("TCxx …")`）也收进来：
    #   两个工程共用一套文档时，「引用的编号存不存在」要跨工程一起判，
    #   否则开发计划里写一句「见 `TC25`」会被误报成「不存在」。
    tl = os.path.join(ROOT, "..", "06-引擎复刻", "tests.lua")
    if os.path.isfile(tl):
        for m in re.finditer(r"""hr\(\s*["'](TC\d{1,3})\b""", read(tl)):
            ids.setdefault(m.group(1), []).append("06/tests.lua")
    return ids


def check_test_ids(plan_text=None, idmap=None):
    """★ 测试编号纪律（2026-10-16 加）——两条，都是**零假阳性**的硬判据：

       ① **编号不得重复**：本工程的文档大量写「见 `B19`」「见 `A3`」这种引用，
          一旦两个测试共用一个编号，「引用的到底是哪条」就没人能确定了。
          —— 与「数字会被机械核对、形容词不会」是同一类：**能被引用的东西必须唯一**。
       ② **文档里**反引号包起来的单编号（形如 `` `A17` ``）**必须真的存在**。
          只认「反引号 + 纯编号」这种无歧义写法，避免正文里的 `A3` 之类误报。

    ★ 两个参数只为**规则自检**（`--selftest`）留的注入点：给合成输入就能证明规则真的会响。
      —— 本工程的纪律：「检查写好了」≠「检查生效过」，死代码在干净状态下同样输出 ✔。
    """
    ids = collect_ids() if idmap is None else idmap
    dups = {k: v for k, v in ids.items() if len(v) > 1}
    for k, v in sorted(dups.items()):
        hit("tests/", "测试编号重复", k, "出现在 %s" % ", ".join(v))

    src = read(PLAN) if plan_text is None else plan_text
    # 与其它规则一致：跳过标了「当时值」的历史行（那类行里的旧编号是**故意保留**的）
    live = "\n".join(l for l in src.split("\n") if "当时值" not in l)
    cited = set(re.findall(r"`([A-Z]{1,2}\d{1,3}[a-z]?)`", live)) | \
            set(re.findall(r"`(TC\d{1,3})`", live))
    missing = sorted(c for c in cited if c not in ids)
    for c in missing:
        hit("开发计划.md", "引用了不存在的测试编号", c, "已存在的编号共 %d 个" % len(ids))
    return ids


# ------------------------------------------------- 5. 重复定义（静默死代码）
# ★ 要扫的文件：测试与工具里的 Python + 客户端的 JS。
DEF_FILES = ["tests/test_rt.py", "tests/test_stress.py", "tests/test_protocol_parity.py",
             "tools/verify_plan.py", "tools/pack_atlas.py",
             "rt/client.html", "rt/perf_lib.js", "rt/render_atlas.js", "rt/protocol_bin.js"]


def check_ids_claim(n=None, plan_text=None):
    """`§9aq.1` 表里的「测试编号 | N 个」必须与实测一致。

    ★★ 2026-10-20：这条原来**没有任何判据**。实测证据：test_units 从 25 条长到 32 条，
      编号 188 → 195，**总数（204→211）当场被抓住，编号总数却一路绿**。
      同一张表里两个数字，一个有人守、一个没有 —— 读者分不出哪个可信。
      （同一类毛病在本轮已经咬了三次：缺登记的条目不受任何判据约束。）
    """
    total = n if n is not None else len(collect_ids())
    text = plan_text if plan_text is not None else read(PLAN)
    for m in re.finditer(r"测试编号\s*\|\s*\**(\d+)\s*个\**", text):
        if int(m.group(1)) != total:
            hit("开发计划.md", "测试编号总数过期", "%s 个" % m.group(1), "%d 个" % total)


def check_duplicate_defs(sources=None):
    """★★ 同名函数定义两次 = **静默死代码**（2026-10-16 加）。

    为什么值得单独立一条：Python 里后一个定义**静静覆盖**前一个 —— 不报错、不警告，
    JS 的顶层 `function` 声明同理。实测抓到的真例：
    `tests/test_rt.py` 里 `b25_每个客户端有自己的角色` 与 `_latest_ent` **各定义了两次**
    （1212/1303 与 1184/1275），于是**前面那两份从来没跑过** ——
    包括 `b25` 前一版 docstring 里记着的那条经验（「用持续读线程取值」）。
    后果是：谁改「上面那版」并跑测试，会得出「改了没用」的结论，
    而真相是**它根本不是被执行的那一份**。

    ⇒ 与「同一件事两处实现」「改了文件 ≠ 改动在文件里」同源，只是更隐蔽（连 diff 都不显眼）。
      `sources` 参数只给规则自检用（传 {文件名: 源码}）。
    """
    import ast
    if sources is None:
        items = []
        for f in DEF_FILES:
            p = os.path.join(ROOT, f)
            if os.path.isfile(p):
                items.append((f, read(p)))
    else:
        items = list(sources.items())

    for f, src in items:
        seen = {}
        if f.endswith(".py"):
            try:
                tree = ast.parse(src, filename=f)
            except SyntaxError as e:
                hit(f, "语法错误（无法解析）", "SyntaxError", str(e)[:80])
                continue
            for node in tree.body:                  # 只看**顶层**：嵌套同名是合法的
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    seen.setdefault(node.name, []).append(node.lineno)
        else:
            # JS：只看**行首**（列 0）的 `function 名字(` —— 缩进的一律算嵌套，不参与
            for i, line in enumerate(src.split("\n"), 1):
                m = re.match(r"function\s+([A-Za-z_$][\w$]*)\s*\(", line)
                if m:
                    seen.setdefault(m.group(1), []).append(i)
        for name, lns in sorted(seen.items()):
            if len(lns) > 1:
                hit(f, "同名函数重复定义（前面那份是死代码）", name,
                    "第 %s 行" % "、".join(str(x) for x in lns))


# ------------------------------------------------- 6. README / 发布检查单里的同一批数字
# ★★ 为什么加这一条（2026-10-16）：今天**手工**同步过 `README.md` 与
#   `deploy/发布检查单.md` 里的「合计 N 项」「N 项 / M 组」**四次**，其中三次都是
#   「改了一处、漏了另一处」（有一次还把两处写成了同一个数，导致读者分不清哪份是当前值）。
#   ⇒ 这两份**面向用户/发布**的文档，数字没人核 —— 而它们恰恰是最该准的。
#   本规则把「总数」与「组数」也纳入机器核对（与 `开发计划.md` 那条同一口径）。
DOC_COUNTS = ["README.md", "deploy/发布检查单.md"]


def count_groups(run_all_text):
    """数 `run_all.sh` 里有**几组**验证。

    ★★ 为什么不能直接数 `hr "` 行（这一条今天连踩两次）：
      ① 有两组在 `if [ "$FAST" = "1" ]` 的分支里（**缩进**）⇒ 第一版用 `^hr "` 只数到 10；
      ② `--fast` 分支里还各有一条「**已跳过**」的提示，也走 `hr` ⇒ 直接数会数到 14。
      ⇒ 正确口径：取每条标签**开头的分组记号**（`①`/`②b`/`④`…）**去重**。
        `--fast` 的跳过提示与它对应的那一组同名 ⇒ 去重后正好是完整跑一遍的组数。
    """
    toks = set()
    for line in run_all_text.split("\n"):
        m = re.match(r'\s*hr\s+"([①-⑳][a-z]?)', line)
        if m:
            toks.add(m.group(1))
    return len(toks)


def _selftest_groups(run_all_text, want):
    """★ 给 `selftest` 撞用的包装：`count_groups` 是**纯函数**（返回数字），
    而自检的契约是「报了几条」，所以这里把「与期望不符」变成一条记录。
    ⇒ 自检里成对使用：**数对时应当 0 条、故意给错期望时应当 1 条**（后者证明它真的数了）。"""
    got = count_groups(run_all_text)
    if got != want:
        hit("<selftest>", "数分组不对", "期望 %d 组" % want, "实测 %d 组" % got)


# README「分组表」每一行 → 它对应哪个文件（**行里的数字必须与那个文件的实测一致**）
# ★ 为什么连**行内数字**也要核：总分对得上，不代表每行都对 ——
#   今天 README 的 ① 行写着 29、①d 行写着 10，而实测是 31 / 13（**总分那行是对的**）。
README_ROWS = {
    "① Node 客户端": "tests/test_client.js",
    "①b Node 精灵纯函数": "tests/test_render_atlas.js",
    "①c Node 二进制协议": "tests/test_protocol.js",
    "② Python 端到端": "tests/test_rt.py",
    "②b Python 跨实现": "tests/test_protocol_parity.py",
    "②d Python 发布演练": "tests/test_deploy.py",
    "②c Python 规模并发": "tests/test_stress.py",
    "①d Node 变异测试": "<mutations>",          # 特殊：数 falsify_client.js 里的条目
    # ★ 2026-10-18（C1/C2）：本轮新增的两组
    "①e Node 同一图集批渲染": "tests/test_render_batch.js",
    "②i Python 停帧看门狗": "tests/test_stall_watchdog.py",
    # ★★ 2026-10-20：这一行**此前不在表里** —— 于是它就是唯一一个「数字可以随便过期、
    #   没有任何判据会红」的行。实测证据：test_units 从 19 条长到 25 条，
    #   总分行（198→204）被工具抓住了，**行内那个 19 却一直是绿的**。
    #   这与「test_units.py 没进 TEST_FILES」是同一个病的两面：**缺登记**。
    "②k Python 模块级单测": "tests/test_units.py",
    # ★★ 2026-10-20：这一行**此前也不在表里**，而且比 ②k 更糟 ——
    #   `tests/test_client_batch.js` 的 8 条**进了「合计 204 项」，却没有任何一行显示它**：
    #   读者把表里各行的数字加起来，永远对不上总计，而每一行又都是「对的」。
    #   ⇒ 补行（README）＋ 补登记（这里）＋ 加一条**双表对齐**判据（见 crosscheck_registries）。
    "①f Node 客户端真的用上批路径": "tests/test_client_batch.js",
}


def crosscheck_registries(test_files=None, rows=None):
    """两张登记表必须**指向同一批文件**：`TEST_FILES`（算总数用）与 `README_ROWS`（显示用）。

    ★★ 为什么值得一条判据（2026-10-20）：这两张表是同一件事的两份清单，
      而「缺登记」已经在本工程咬了三次（`test_units` 没进 TEST_FILES、
      README ②k 行没进 README_ROWS、`test_client_batch` 两边都没人提）。
      每次的症状都一样：**数字全都是对的，只是有一份东西没人看见**。
      单看任一张表都发现不了 —— 只有把它们**对起来**才看得见。
    """
    tf = set((test_files if test_files is not None else TEST_FILES).keys())
    rv = {v for v in (rows if rows is not None else README_ROWS).values()
          if not v.startswith("<")}          # `<mutations>` 不是文件，是条目数
    bad = [("有测试文件、README 分组表没有对应行", f) for f in sorted(tf - rv)]
    bad += [("README 分组表有行、但它的条数没进合计", f) for f in sorted(rv - tf)]
    return bad


def _rows_live_n(label):
    """README 分组表某一行的**实时**项数（给规则自检用，避免把数字写死）。

    ★ 为什么需要它：自检用例若拿一个**字面量**当「对得上的值」，
      那么被测系统（测试套件）一长出新项，这条用例就会**假红** ——
      而假红比漏测更坏：人一旦习惯「这条偶尔红」，真的回归就看不见了。
    """
    f = README_ROWS.get(label)
    if f is None:
        raise KeyError("README_ROWS 里没有标签 %r" % label)
    if f == "<mutations>":
        src = read(os.path.join(ROOT, "tests/falsify_client.js"))
        return len(re.findall(r"^    name: ", src, re.M))
    return file_items(os.path.join(ROOT, f))


def check_readme_rows(readme=None):
    """README 分组表**每一行**的项数都要与实测一致（行内数字也会过期）。"""
    text = readme if readme is not None else read(os.path.join(ROOT, "README.md"))
    for line in text.split("\n"):
        m = re.match(r"\|\s*([①-⑳][a-z]?[^|]*?)\s*\|\s*([^|]*?)\s*\|", line)
        if not m:
            continue
        label = m.group(1).replace("*", "").strip()
        cell = m.group(2).replace("*", "").strip()
        f = README_ROWS.get(label)
        if f is None:
            continue
        if f == "<mutations>":
            src = read(os.path.join(ROOT, "tests/falsify_client.js"))
            n = len(re.findall(r"^    name: ", src, re.M))
        else:
            p = os.path.join(ROOT, f)
            if not os.path.isfile(p):
                hit("README.md", "分组表指向的文件不存在", label, f)
                continue
            n = file_items(p)
        if not cell.isdigit():
            hit("README.md", "分组表的项数不是数字", "%s → %r" % (label, cell), "实测 %d 项" % n)
        elif int(cell) != n:
            hit("README.md", "分组表的项数过期", "%s → %s" % (label, cell), "实测 %d 项" % n)


def check_rows_present(readme=None, rows=None):
    """`README_ROWS` 里登记过的每一行**都必须真的出现在 README 文本里**。

    ★★ 2026-10-20 补：`check_readme_rows` 是「从 README 出发」遍历的 ——
      于是「**整行不见了**」它看不见。实测 `tests/test_client_batch.js` 的 8 条
      进了「合计 204 项」却没有任何一行显示它，而那条判据一直报 ✔。
      ⇒ 必须再有一遍「**从登记表出发**」的遍历；否则「删掉一行」比「写错一行」更安全。
    """
    text = readme if readme is not None else read(os.path.join(ROOT, "README.md"))
    want = rows if rows is not None else README_ROWS
    labels = set()
    for line in text.split("\n"):
        m = re.match(r"\|\s*([①-⑳][a-z]?[^|]*?)\s*\|", line)
        if m:
            labels.add(m.group(1).replace("*", "").strip())
    miss = [k for k in want if k not in labels]
    for k in miss:
        hit("README.md", "分组表**缺行**（登记表里有、README 里没有）", k,
            "有测试文件却没有任何一行显示它")
    return miss


def check_registry_alignment():
    """两张登记表对不齐 ⇒ 报出来（缺登记 / 多登记各算一条）。"""
    for kind, f in crosscheck_registries():
        hit("README.md", kind, f, "两张表必须指向同一批文件")


def _selftest_crosscheck(test_files, rows, want):
    """同 `_selftest_groups`：把「条数不对」变成一条记录，成对使用才有意义。"""
    got = len(crosscheck_registries(test_files, rows))
    if got != want:
        hit("<selftest>", "双表对齐判据条数不对", "期望 %d 条" % want, "实测 %d 条" % got)


# ------------------------------------------------- 2b. 文档里的命令能不能真跑
def doc_md_files(root=None):
    """`07-通用引擎` 下所有 Markdown（跳过版本库 / 依赖 / 缓存目录）。"""
    base = root or ROOT
    out = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames
                       if d not in (".git", "node_modules", "__pycache__", ".pytest_cache")]
        for fn in filenames:
            if fn.lower().endswith(".md"):
                out.append(os.path.join(dirpath, fn))
    return sorted(out)


def scan_doc_cd_paths(texts=None, exists=None):
    """扫 Markdown **代码块里**的 `cd <盘符绝对路径>`，返回指向不存在目录的那些。

    ★★ 为什么要有这条（2026-10-20 实测）：`deploy/发布检查单.md` 的第一条命令写着
      `cd E:/xnb/DST-Analysis/07-通用引擎` —— 工作区早就搬到 `E:/game_make/25d` 了。
      照抄**必失败**。而它的位置（「发布检查单」第 1 节）+ 形式（还带注释）
      让它长得**像已经验证过的命令**，正是最容易被无条件信任的那类文字。
      「文档里的命令没跑过」和「代码没测过」是同一种病，只是更难发现 ——
      读者以为错的是自己。

    ★ 只认**代码块内**的行：正文里叙述历史路径（「以前是 E:/xnb/...」）不算。
    ★ 只认**盘符开头**的绝对路径：`cd "$(git rev-parse --show-toplevel)/..."`
      这类自解析写法不该被判。示例占位（`cd /path/to/x`）也不匹配。
    """
    if exists is None:
        exists = os.path.isdir
    if texts is None:
        items = []
        for p in doc_md_files():
            try:
                items.append((p, read(p)))
            except OSError:
                continue
    else:
        items = list(texts.items())
    bad = []
    for p, text in items:
        fence = False
        for i, line in enumerate(text.split("\n"), 1):
            s = line.strip()
            if s.startswith("```"):
                fence = not fence
                continue
            if not fence:
                continue
            m = re.match(r'cd\s+["\']?([A-Za-z]:[/\\][^\s"\'`#]*)', s)
            if m and not exists(m.group(1)):
                bad.append((p, i, m.group(1)))
    return bad


def check_doc_cd_paths(texts=None, exists=None):
    for p, n, path in scan_doc_cd_paths(texts, exists):
        hit("%s:%d" % (os.path.basename(p), n),
            "文档里的 cd 指向这台机器上**不存在**的目录", path, "os.path.isdir → False")


def check_lua_format_percent(sources=None):
    """★ Lua 里 `%` 是**取模**，不是字符串格式化 ⇒ `("… %d …") % n` 一定会抛错。

    ★★ 为什么值得一条规则：这处错误**跑得再全也可能测不到** ——
      它只在「那一支真的被执行到」时才炸。今天的实例：读档后清理多余角色那句打印，
      因为**以前从来没有「读档后出现多余角色」的场景**，潜伏至今；
      是 D4（会话身份挺过重启）第一次让那一支跑起来，才把它炸出来。
    ⇒ 形状识别：**某一行的第一个非空白字符是 `%`** ——
      那是「字符串格式化的续行写法」，而 Lua 里合法的取模不会那样断行。
      `string.format(...)` 完全不受影响。
    `sources` 只给规则自检用（{文件名: 源码}）。
    """
    if sources is None:
        items = []
        d = os.path.join(ROOT, "rt")
        if os.path.isdir(d):
            for f in sorted(os.listdir(d)):
                if f.endswith(".lua"):
                    items.append((os.path.join("rt", f), read(os.path.join(d, f))))
    else:
        items = list(sources.items())
    for rel, text in items:
        for i, line in enumerate(text.split("\n"), 1):
            if line.lstrip()[:1] == "%":
                hit(rel, "Lua 里把 `%` 当字符串格式化（它是取模）", line.strip()[:40],
                    "第 %d 行（应改成 string.format）" % i)


def check_doc_counts(total=None, docs=None, groups=None, ctxt=None):
    """README / 发布检查单里的 `合计 N 项` 与 `N 项 / M 组` 必须与实测一致。

    ★ 参数只为**规则自检**留注入点（`--selftest`）：给合成输入就能证明规则真的会响。
    """
    if total is None:
        total = sum(file_items(os.path.join(ROOT, f))
                    for f in TEST_FILES if os.path.isfile(os.path.join(ROOT, f)))
    if groups is None:
        groups = count_groups(read(os.path.join(ROOT, "tests/run_all.sh")))
    items = []
    if docs is None:
        for rel in DOC_COUNTS:
            p = os.path.join(ROOT, rel)
            if os.path.isfile(p):
                items.append((rel, read(p)))
    else:
        items = list(docs.items())

    for rel, text in items:
        # ★★ **跳过标了「当时值」的历史行** —— 与 `check_test_counts` / `check_artifacts`
        #   用同一条约定（06 的 `audit_doc_numbers` 也一样）：发布记录里那一行是
        #   「当时发生了什么」，把它报成「过期」等于逼人篡改历史。
        #   2026-10-18 真踩：`rt_boot/6` 那条记录写着「133 项 / 15 组」，
        #   本轮升到 /7 后它立刻被判为过期 —— 而它**本来就该停在 133/15**。
        text = "\n".join(l for l in text.split("\n") if "当时值" not in l)
        # `合计 123 项。`（README 的写法）
        for m in re.finditer(r"合计\s*\*{0,2}(\d+)\s*项", text):
            if int(m.group(1)) != total:
                hit(rel, "文档里的测试总数过期", "合计 %s 项" % m.group(1), "实测 %d 项" % total)
        # `（**123 项 / 12 组**，含静态检查）`（发布检查单的写法）
        for m in re.finditer(r"\*{0,2}(\d+)\s*项\s*/\s*(\d+)\s*组\*{0,2}", text):
            if int(m.group(1)) != total:
                hit(rel, "文档里的测试总数过期", "%s 项 / %s 组" % (m.group(1), m.group(2)),
                    "实测 %d 项" % total)
            if int(m.group(2)) != groups:
                hit(rel, "文档里的组数过期", "%s 组" % m.group(2),
                    "run_all.sh 里有 %d 组" % groups)
        # `（17 组 177 项 + 宿主 14 入口 + 06 三件套）`（README 顶部「30 秒上手」的写法）
        # ★★ 为什么单独加这一条（2026-10-18）：上面两条**都匹配不到这个语序**，
        #   于是 README 顶部那句「15 组 133 项」在本轮加了 ①e/②i 之后**依旧显示为绿** ——
        #   不是算错，是**规则没覆盖**。这正是本工程反复出现的形状：
        #   「没被查到的数字」和「查过且正确的数字」在输出里长得一模一样。
        for m in re.finditer(r"(\d+)\s*组\s*\*{0,2}(\d+)\s*项", text):
            if int(m.group(2)) != total:
                hit(rel, "文档里的测试总数过期", "%s 组 %s 项" % (m.group(1), m.group(2)),
                    "实测 %d 项" % total)
            if int(m.group(1)) != groups:
                hit(rel, "文档里的组数过期", "%s 组" % m.group(1),
                    "run_all.sh 里有 %d 组" % groups)


def _selftest_classify(text, want):
    """★ 同 `_selftest_groups` 的套路：`classify_lua_failure` 返回字符串，
    而自检的契约是「报了几条」⇒ 把「与期望不符」变成一条记录。
    成对使用才有意义：判对时 0 条、**故意给错期望时 1 条**（后者证明它真的判了）。"""
    got = classify_lua_failure(text)
    if got != want:
        hit("<selftest>", "Lua 失败归因不对", "期望 %s" % want, "实测 %s" % got)


def selftest():
    """★ 拿**已知答案**去撞这几条新规则：每条都必须「该响时响、不该响时不响」。

    ★★ 为什么必须做：本工程反复栽在「检查写好了 ≠ 检查生效过」上 ——
    死代码在干净状态下也输出 ✔，只有**注入合成违规**才分得清。
    （06 的 `audit_doc_numbers` 就是这么做的：6 条合成违规全部命中才算自检通过。）
    """
    # 合成一段 run_all.sh：三组，其中「②c 乙 / ③ 丙 —— 已跳过（--fast）」是**跳过提示**
    G3 = ('hr "① 甲"\n    hr "④ 全"\n    hr "②c 乙 / ③ 丙 —— 已跳过（--fast）"\n')
    print("  规则自检（合成违规）：")
    # ★ 表改成 (说明, 被撞的函数, 关键字参数, 期望报几条)——
    #   原来把函数名写死成 check_test_ids，加一条新规则就没法一起自检了。
    cases = [
        ("重复编号必须报", check_test_ids,
         dict(plan_text="", idmap={"A1": ["x.js", "y.py"]}), 1),
        ("干净输入不得报", check_test_ids,
         dict(plan_text="见 `A1`", idmap={"A1": ["x.js"]}), 0),
        ("引用不存在的编号必须报", check_test_ids,
         dict(plan_text="见 `A99`", idmap={"A1": ["x.js"]}), 1),
        ("「当时值」行里的旧编号必须跳过", check_test_ids,
         dict(plan_text="见 `A7`（当时值）", idmap={"A1": ["x.js"]}), 0),
        ("正文里的裸编号不该误报", check_test_ids,
         dict(plan_text="A3 那条测过", idmap={"A1": ["x.js"]}), 0),
        ("TC 组号也算在册（06 那边）", check_test_ids,
         dict(plan_text="见 `TC25`", idmap={"TC25": ["06/tests.lua"]}), 0),
        # ---- 重复定义（静默死代码）----
        ("Python 同名函数定义两次必须报", check_duplicate_defs,
         dict(sources={"x.py": "def f():\n    pass\n\n\ndef f():\n    return 1\n"}), 1),
        ("Python 不重复不得报", check_duplicate_defs,
         dict(sources={"x.py": "def f():\n    pass\n\n\ndef g():\n    pass\n"}), 0),
        ("JS 顶层 function 重名必须报", check_duplicate_defs,
         dict(sources={"x.js": "function f(){}\nfunction f(){}\n"}), 1),
        ("JS 嵌套同名函数**不该**误报（作用域不同）", check_duplicate_defs,
         dict(sources={"x.js": "function f(){ function g(){} }\nfunction g(){}\n"}), 0),
        # ---- README / 发布检查单的数字 ----
        ("README 的总数过期必须报", check_doc_counts,
         dict(total=123, groups=12, docs={"README.md": "**合计 122 项。**"}), 1),
        ("README 的总数对得上不得报", check_doc_counts,
         dict(total=123, groups=12, docs={"README.md": "**合计 123 项。**"}), 0),
        ("发布检查单的「N 项 / M 组」过期必须报", check_doc_counts,
         dict(total=123, groups=12, docs={"发布检查单.md": "run_all ✔（**122 项 / 11 组**）"}), 2),
        ("组数过期单报一条", check_doc_counts,
         dict(total=123, groups=12, docs={"发布检查单.md": "**123 项 / 11 组**"}), 1),
        # ★ 2026-10-18：README 顶部那种「N 组 M 项」的语序（与上面两条都不同）
        ("README 的「N 组 M 项」语序过期必须报", check_doc_counts,
         dict(total=123, groups=12, docs={"README.md": "跑全部验证（15 组 133 项 + 宿主）"}), 2),
        ("README 的「N 组 M 项」语序对得上不得报", check_doc_counts,
         dict(total=123, groups=12, docs={"README.md": "跑全部验证（12 组 123 项 + 宿主）"}), 0),
        # ★ 2026-10-18：机制横扫的条数以前只写在 README 里、没人重算过（写的是 26，实跑 50）
        ("机制横扫条数过期必须报", check_mech_claim,
         dict(n=50, docs={"README.md": "`mech.lua` **26 条机制横扫 0 失败**"}), 1),
        ("机制横扫条数对得上不得报", check_mech_claim,
         dict(n=50, docs={"README.md": "`mech.lua` **50 条机制横扫 0 失败**"}), 0),
        ("Lua 续行取模误用必须报", check_lua_format_percent,
         dict(sources={"x.lua": 'print("x %d"\n  % 3)\n'}), 1),
        ("Lua 里 string.format 不得误报", check_lua_format_percent,
         dict(sources={"x.lua": 'print(string.format("x %d", 3))\n'}), 0),
        ("发布记录里标了「当时值」的旧数字必须跳过", check_doc_counts,
         dict(total=123, groups=12,
              docs={"发布检查单.md": "| 2026-10-18 | `rt_boot/6` | run_all ✔（当时值 133 项 / 15 组） |"}), 0),
        ("README 行内数字过期必须报", check_readme_rows,
         dict(readme="| ① Node 客户端 | **3** | 说明 |\n"), 1),
        # ★★★ 2026-10-18：这条用例原来把项数**写死成 31**（当时的真实值）。
        #   这一轮加了 F32（① 组 31 → 32）之后，它立刻报
        #   「期望报 0 条，实际 1 条」——**假的失败**：规则没错，是**用例**过期了。
        #   更糟的是它的失效方式：以后每加一条测试都会红，而人一旦习惯了
        #   「这条自检偶尔会红」，真正的规则回归就再也看不见了。
        #   ⇒ 项数**从实时数据取**（和被测函数用同一张 `README_ROWS`），
        #     用例只锁**语义**（「对得上就不许报」），不锁数字。
        ("README 行内数字对得上不得报", check_readme_rows,
         dict(readme="| ① Node 客户端 | **%d** | 说明 |\n" % _rows_live_n("① Node 客户端")), 0),
        ("README 行内写成非数字必须报", check_readme_rows,
         dict(readme="| ① Node 客户端 | 三十一 | 说明 |\n"), 1),
        ("数分组：数对时不该报（含 --fast 跳过提示的三标签）", _selftest_groups,
         dict(run_all_text=G3, want=3), 0),
        ("数分组：**故意给错期望**时必须报（证明它真的数了）", _selftest_groups,
         dict(run_all_text=G3, want=4), 1),
        ("数分组：同名标签去重（两条① 只算一组）", _selftest_groups,
         dict(run_all_text='hr "① 甲"\n    hr "① 甲（--fast）"\n', want=1), 0),
        # ---- 环境缺失 vs 脚本报错（2026-10-20：缺 lupa 曾被报成「文档过期」）----
        ("缺 lupa 必须归因为**环境**（不是文档过期）", _selftest_classify,
         dict(text="Traceback (most recent call last):\n"
                   "ModuleNotFoundError: No module named 'lupa'", want="env"), 0),
        ("Lua 脚本真报错不得归因为环境", _selftest_classify,
         dict(text="lua: x.lua:12: attempt to index a nil value", want="lua"), 0),
        ("归因**故意给错期望**时必须报（证明它真的判了）", _selftest_classify,
         dict(text="ModuleNotFoundError: No module named 'lupa'", want="lua"), 1),
        # ---- 两张登记表必须指向同一批文件（缺登记咬过三次）----
        ("双表对齐：一致时不得报", _selftest_crosscheck,
         dict(test_files={"a.js": "A"}, rows={"x": "a.js"}, want=0), 0),
        ("双表对齐：**有测试文件但 README 没行**必须报", _selftest_crosscheck,
         dict(test_files={"a.js": "A", "b.js": "B"}, rows={"x": "a.js"}, want=1), 0),
        ("双表对齐：**README 有行但没进合计**必须报", _selftest_crosscheck,
         dict(test_files={"a.js": "A"}, rows={"x": "a.js", "y": "b.js"}, want=1), 0),
        ("双表对齐：`<mutations>` 不是文件，不该误报", _selftest_crosscheck,
         dict(test_files={"a.js": "A"}, rows={"x": "a.js", "y": "<mutations>"}, want=0), 0),
        # ---- 「整行不见了」也要有人看得见（check_readme_rows 从 README 出发，看不见这个）----
        ("分组表缺行：全部都在时不得报", check_rows_present,
         dict(readme="\n".join("| %s | 1 | x |" % k for k in README_ROWS),
              rows=README_ROWS), 0),
        ("分组表缺行：**掉了一行**必须报", check_rows_present,
         dict(readme="\n".join("| %s | 1 | x |" % k for k in list(README_ROWS)[1:]),
              rows=README_ROWS), 1),
        # ---- §9aq.1 表里的编号总数（这个数字此前没人守）----
        ("编号总数：对得上不得报", check_ids_claim,
         dict(n=195, plan_text="| 测试编号 | **195 个** | x |"), 0),
        ("编号总数：过期必须报", check_ids_claim,
         dict(n=195, plan_text="| 测试编号 | **188 个** | x |"), 1),
        # ---- 文档里的命令能不能真跑（`cd E:/...` 这类硬编码路径）----
        ("代码块里 cd 到不存在的盘符路径必须报", check_doc_cd_paths,
         dict(texts={"x.md": "```bash\ncd E:/nope/eng\nbash tests/run_all.sh\n```\n"},
              exists=lambda p: False), 1),
        ("代码块里 cd 到存在的目录不得报", check_doc_cd_paths,
         dict(texts={"x.md": "```bash\ncd E:/real/eng\n```\n"}, exists=lambda p: True), 0),
        ("正文（代码块外）提历史路径不该误报", check_doc_cd_paths,
         dict(texts={"x.md": "以前写的是 cd E:/xnb/DST-Analysis\n"}, exists=lambda p: False), 0),
        ("自解析写法 `cd \"$(git rev-parse …)\"` 不该误报", check_doc_cd_paths,
         dict(texts={"x.md": "```bash\ncd \"$(git rev-parse --show-toplevel)/07-通用引擎\"\n```\n"},
              exists=lambda p: False), 0),
    ]
    # ★★★ 自检会产生一堆**假的**记录，必须只清掉这些、**绝不能碰真记录**。
    #   第一版写的是 `del HITS[:]` —— 而当时自检是在 `check_test_counts()` **之后**调的，
    #   于是它把**真实**的不一致也一起抹掉了：计划写 79、实测 80，工具却报 ✔。
    #   典型的「**检查把证据销毁了**」—— 比不检查更危险，因为它给出的是虚假的绿。
    #   两道保险：① 调 selftest **之前**先备份/还原；② main 里把 selftest 放在**最前面**。
    mark0 = len(HITS)
    bad = []
    for name, fn, kw, want in cases:
        n0 = len(HITS)
        fn(**kw)
        got = len(HITS) - n0
        mark = "✔" if got == want else "✘"
        if got != want:
            bad.append(name)
        print("    %s %-34s 期望报 %d 条，实际 %d 条" % (mark, name, want, got))
    assert len(HITS) >= mark0
    del HITS[mark0:]                # 只砍掉自检自己新增的那些
    if bad:
        print("  ✘ 自检不过：%s" % "、".join(bad))
        return 1
    print("  ✔ %d 条合成用例全部符合预期（规则既不空转也不误报）" % len(cases))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fast", action="store_true", help="跳过进程内实测")
    ap.add_argument("--selftest", action="store_true", help="只跑规则自检（合成违规），不核对文档")
    a = ap.parse_args()

    print("  开发计划数字核对  ——  %s" % os.path.basename(PLAN))
    print("  " + "─" * 68)

    if a.selftest:
        rc = selftest()
        print("  " + "─" * 68)
        return rc

    # ★★ 自检必须放在**最前面**（在任何真实核对之前）：
    #   它会产生假的记录，一旦它跑在真实核对**之后**，清理动作就可能连真记录一起清掉
    #   （第一版就是这么把「计划 79 / 实测 80」的不一致抹成 ✔ 的 —— 检查把证据销毁了）。
    rc_self = selftest()
    if rc_self != 0:
        print("  ✘ 规则自检不过 —— 下面的核对结果**不可信**")
        return 1

    total = check_test_counts()
    print("  测试项数（各文件自报条数；无声明者数 `check(` 调用行）：%d 项" % total)
    ids = check_test_ids()
    print("  测试编号：%d 个（无重复、文档引用的都存在）" % len(ids))
    check_ids_claim(len(ids))
    check_duplicate_defs()
    check_doc_counts()
    check_readme_rows()
    check_rows_present()
    check_registry_alignment()
    check_doc_cd_paths()
    check_lua_format_percent()
    check_artifacts()
    check_host()
    if not a.fast:
        check_runtime()
        print("  进程内实测：已跑（tick 耗时 / 帧大小 / 二进制省比）")
    else:
        print("  进程内实测：**已跳过**（--fast）")

    print("  " + "─" * 68)
    # ★★ 环境缺失**先判**，而且单独一个退出码：它不是「文档写错了」。
    #   原来缺 lupa 时的输出是 2 处「文档数字过期，实测 ModuleNotFoundError…」——
    #   读者只会去改文档，越改越错。现在它变成 1 条判定 + 1 条修复命令 + 退出码 2。
    if ENV_MISSING:
        for what, why, detail in ENV_MISSING:
            print("  ✘ 环境缺失（**不是**文档过期）：%s —— %s" % (what, why))
            if detail:
                print("       %s" % detail[:150])
        print("\n  修复：在 07-通用引擎 下执行")
        print("        bash -c '. ../tools/env.sh && \"$PY\" -u tools/verify_plan.py'")
        print("        （env.sh 会挑**能 import lupa** 的解释器；本进程的 PY=%s）" % PY)
        print("\n  共 %d 处**未核对**（这些数字本轮没有真相，别当成「对得上」）" % len(ENV_MISSING))
        return 2
    if not HITS:
        print("  ✔ 计划里的可机器验证数字与实测一致")
        return 0
    for where, kind, found, real, ctx in HITS:
        print("  ✘ [%s] %s：计划写「%s」，实测「%s」" % (where, kind, found, real))
        if ctx:
            print("       %s" % ctx[:150])
    print("\n  共 %d 处不一致（本工具**不自动改**：改哪边得由人下）" % len(HITS))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
