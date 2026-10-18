# -*- coding: utf-8 -*-
"""scan_constant_semantics.py —— 3.5 的机械产物：「恒值语义」到底影响谁

为什么要有它
    审计报告里写过一句「`IsInLight` 恒 false ⇒ `avoidlight` / `findlight` 两个
    behaviour **永不触发**」。这句话**一半是错的**（本轮实测发现的）：
      · `findlight` 根本不看 `IsInLight`，它按 tag 找光源实体 —— 它会触发；
      · `avoidlight` **会跑**，只是其中「等待中被照到立即切相位」那条永不成立，
        并且方向排序退化成「附近无光」分支（因为 `GetLightAngle()` 恒 nil）。
    ⇒ 「永不触发」这种断言必须**逐条对着代码与实测值写**，不能一句话扫一片。

它做什么
    ① 跑 `tools/probe_constant_semantics.lua`（真实 lupa 虚拟机），拿到**实测值**；
    ② 扫 `dstsrc/scripts` 统计每个接口的「文件数 / 调用数」；
    ③ 把结论生成成 `恒值语义影响面.md` 里的机器块（BEGIN/END 之间）。

用法
    python tools/scan_constant_semantics.py            # 只打印
    python tools/scan_constant_semantics.py --write    # 重写文档里的机器块
    python tools/scan_constant_semantics.py --check    # 与文档比对，不一致退出 1

★ 为什么要「生成 + 比对」而不是手写表：手写的表会随时间腐烂（本工程已有先例：
  报告 §47 的基线数字过期了整整两轮才被 `verify_report.py` 抓到）。
"""
import io
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _paths import ENGINE, RUN, SRC           # noqa: E402

PY = sys.executable
DOC = os.path.join(ENGINE, "恒值语义影响面.md")
PROBE = os.path.join(ENGINE, "tools", "probe_constant_semantics.lua")
BEGIN = "<!-- CONSTANT-SEMANTICS:BEGIN 本块由 tools/scan_constant_semantics.py 生成，勿手改 -->"
END = "<!-- CONSTANT-SEMANTICS:END -->"

# ---------------------------------------------------------------------------
# 每一行 = 一个接口：key（探针键） + 统计用的正则 + 人对后果的判断
#
# ★★ 2026-10-18（C1~C9 修复轮）加了一列 `expect`：
#   `why` / `verdict` 是**人写的叙述**，而"实测值"是机器量的。叙述一旦过期，
#   只靠 `--check` 的"新鲜度"是抓不住的 —— 它只比"文档里的表 vs 现在跑出来的表"，
#   两张表都由同一份叙述生成，**一起过期就恒绿**（这正是 C9 那个母题）。
#   ⇒ 给每个叙述配一个"我认为实测应该是什么"，实测不符就**报错**。
#     这样"结论"与"数据"就不再能各自漂移。
# ---------------------------------------------------------------------------
ROWS = [
    dict(key="ent.IsInLight", value="ent.IsInLight",
         label="`EntityScript:IsInLight()`",
         pattern=r"IsInLight",
         files_only_in="behaviours/",
         verdict="**已修（C3）**",
         expect="true",
         who="`behaviours/avoidlight.lua:153`",
         why="改为委托 `LightWatcher`，亮度取自 `TheWorld.state.phase`（白天 1 / 黄昏 0.5 / 夜 0），"
             "阈值 0.2 ⇒ 白天与黄昏 `true`、夜里 `false`。"
             "`avoidlight` 里「等待中被照到就立即切相位」这条**从永不成立变成真的会成立**"),
    dict(key="lightwatcher.IsInLight", value="lightwatcher.IsInLight",
         label="`LightWatcher:IsInLight()`",
         pattern=r"LightWatcher:IsInLight",
         files_only_in=None,
         verdict="**已修（C3，两处同源）**",
         expect="true",
         who="",
         why="与上面那条现在**读同一个亮度源**（`ambient_light_level()`），"
             "「一个恒 false、一个恒 true」的语义冲突消失；"
             "`IsInDark` 作为互补方法一并补上（两者恒为互斥）"),
    dict(key="lightwatcher.GetLightAngle", value="lightwatcher.GetLightAngle",
         label="`LightWatcher:GetLightAngle()`",
         pattern=r"GetLightAngle",
         files_only_in=None,
         verdict="**部分失效（未在本轮范围）**",
         expect="nil",
         who="`behaviours/avoidlight.lua:81/230`",
         why="仍返回 nil ⇒ `if light then` 恒假 ⇒ 方向排序走「附近无光」分支，"
             "**躲的方向不是背光**（随机走）。这条**不在 C1~C9 里**，如实留着 —— "
             "补它需要一张真实光照场（按光源位置的合成），不是补一个返回值就完事"),
    dict(key="lightwatcher.GetLightValue", value="lightwatcher.GetLightValue",
         label="`LightWatcher:GetLightValue()`",
         pattern=r"GetLightValue",
         files_only_in=None,
         verdict="**已修（C3）**",
         expect="1",
         who="",
         why="原来宿主**根本没有**这个方法（落到泛化桩返回 nil），而 "
             "`components/sanity.lua:1282` 会拿它比大小 ⇒ `nil > number` **直接抛错**。"
             "现在返回与 `IsInLight` 同源的亮度，崩风险消除"),
    dict(key="lightwatcher.GetTimeInDark", value="lightwatcher.GetTimeInDark",
         label="`LightWatcher:GetTimeInLight / GetTimeInDark`",
         pattern=r"GetTimeIn(Dark|Light)",
         files_only_in=None,
         verdict="**已修（需时间推进才非 0）**",
         expect="0",
         who="",
         why="改成按「上一次结算时刻」惰性累加（`settle()`），随相位翻转重置。"
             "★ 探针是在**刚起来那一刻**读的 ⇒ 值是 0，但这不是「恒 0」："
             "白天持续 120 s 后 `GetTimeInLight` 会真的长到 120。"
             "判据见 `mech.lua` 第 13 段（含「时间不推进就必须是 0」的反向断言）"),
    dict(key="physics.IsOnPlatform", value="physics.IsOnPlatform",
         label="`Physics:IsOnPlatform()`",
         pattern=r"IsOnPlatform",
         files_only_in=None,
         verdict="**已修（C4）**",
         expect="false",
         who="`components/walkableplatformplayer.lua:207/247/286`",
         why="原来恒返回 **nil**（三值逻辑里的「不知道」，`if ... then` 恒假）。"
             "现在返回 **bool**，并与 `SetIsOnPlatform` 成对（Query/Setter 必须成对才可测）。"
             "★ 真正被解锁的是 `actions.lua:445 CheckIsOnPlatform` —— 它写的是 "
             "`doer:GetCurrentPlatform() ~= nil`，而那个方法原来恒 nil ⇒ "
             "**BOARDPLATFORM（上船）永不可达**；`GetCurrentPlatform/SetCurrentPlatform` 已补成对"),
    dict(key="ent.IsInDark", value="ent.IsInDark",
         label="`EntityScript:IsInDark()`",
         pattern=r"IsInDark",
         files_only_in=None,
         verdict="**已修（C3，host 侧新增）**",
         expect="false",
         who="",
         why="宿主原来没有这个方法（调用即崩），`scripts/` 里也没人调。"
             "本轮补成 `not IsInLight()`（同一亮度源、严格互补），"
             "并加了 `mech.lua` 判据：两者不许同时为真"),
    dict(key="world.state.humidity", value="world.state.humidity",
         label="`TheWorld.state.humidity`",
         pattern=r"\.state\.humidity",
         files_only_in=None,
         verdict="**不适用**",
         expect="nil",
         who="",
         why="世界的湿度字段不存在，但湿度能力在组件上（`components/moisture`、"
             "`inventoryitem:GetMoisture`，共 78 处调用），实测正常 —— 这条是**诚实纠正**："
             "审计里把它算成缺口是错的"),
    dict(key="map.IsOceanAtPoint.far", value="map.IsOceanAtPoint.far",
         label="`Map:IsOceanAtPoint(x,y,z)`",
         pattern=r"IsOceanAtPoint",
         files_only_in=None,
         verdict="**可用（边界已可判，C5）**",
         expect=None,
         who="",
         why="实测：岛内 false、外海 true —— 可用。**越界**仍返回 false（与陆地同值），"
             "但 C5 之后不再只能靠这一个接口猜：越界瓦片现在映射成 `GROUND.INVALID`（65535），"
             "`Map:IsOutOfBoundsAtPoint/IsInvalidTileAtPoint` 能明确区分「陆地」与「界外」"),
    dict(key="map.IsOceanTileAtPoint.farther", value="map.IsOceanTileAtPoint.farther",
         label="`Map:IsOceanTileAtPoint(x,y,z)`",
         pattern=r"IsOceanTileAtPoint",
         files_only_in=None,
         verdict="**可用（边界已可判，C5）**",
         expect=None,
         who="",
         why="与上一条同形态。C5 之前越界会被误读成「陆地」；现在 `IsInvalidTile` 把界外"
             "（INVALID）与不可通行（IMPASSABLE=1）分开，"
             "`mech.lua` 第 11 段用「界外**不是一种地形**」这条断言锁住它"),
]


def run_probe():
    """跑真实 Lua 探针，返回 {key: value}"""
    out = subprocess.run([PY, "-u", RUN, "5.1", PROBE],
                         cwd=ENGINE, capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    vals = {}
    for ln in (out.stdout or "").splitlines():
        if "=" in ln and not ln.startswith((" ", "\t")):
            k, v = ln.split("=", 1)
            vals[k.strip()] = v.strip()
    if not vals:
        raise RuntimeError("探针没有输出任何 KEY=VALUE：\n%s\n%s"
                           % ((out.stdout or "")[:800], (out.stderr or "")[-800:]))
    return vals


def count_usages(pattern, files_only_in=None):
    """在 dstsrc/scripts 里统计 (文件数, 调用数)。"""
    files, hits = set(), 0
    rx = re.compile(pattern)
    root = SRC if files_only_in is None else os.path.join(SRC, files_only_in.replace("/", os.sep))
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".lua"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                text = io.open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            n = len(rx.findall(text))
            if n:
                files.add(p)
                hits += n
    return len(files), hits


def render(vals):
    lines = [BEGIN, "",
             "| 接口 | 宿主实测 | 依赖面 | 后果 | 结论 |",
             "|---|---|---|---|---|"]
    for r in ROWS:
        v = vals.get(r["value"], "<探针缺失>")
        # 海洋类：单点实测值会误导（越界点返回 false 与陆地同值），改成三点并列
        base = r["value"].rsplit(".", 1)[0]
        if base + ".land" in vals:
            v = "岛内 %s / 外海 %s / 越界 %s" % (
                vals.get(base + ".land"), vals.get(base + ".far"), vals.get(base + ".farther"))
        nf, nh = count_usages(r["pattern"], r["files_only_in"])
        deps = "%d 个文件 / %d 处" % (nf, nh)
        if r["files_only_in"]:
            deps += "（只算 `%s`）" % r["files_only_in"]
        if r["who"]:
            deps += "，" + r["who"]
        lines.append("| %s | `%s` | %s | %s | %s |"
                     % (r["label"], v, deps, r["why"], r["verdict"]))
    lines.append("")
    lines.append("> 实测值由 `tools/probe_constant_semantics.lua` 在 lupa 里跑出来；"
                 "依赖面由本脚本扫 `dstsrc/scripts` 统计。两者都不手填。")
    lines.append("")
    lines.append(END)
    return "\n".join(lines)


def check_expect(vals):
    """★ 核心：让**叙述**与**实测**互相校验。

    每一行的 `why` / `verdict` 是人写的；`expect` 是"我认为实测应该是什么"。
    两者不符就报错 —— 因为只靠 `--check` 的"新鲜度"抓不住这种漂移：
    文档里的表和现在跑出来的表**由同一份叙述生成**，一起过期就恒绿（C9 的母题）。
    返回 (ok, 问题清单)。
    """
    bad = []
    for r in ROWS:
        exp = r.get("expect", None)
        if exp is None:
            continue                    # 海洋类：三点并列，单值比不了（见 render()）
        got = vals.get(r["value"], "<探针缺失>")
        if got != exp:
            bad.append("%s：叙述假设实测为 `%s`，实际 `%s` —— 结论已过期，请改 ROWS 里的 why/verdict"
                       % (r["label"], exp, got))
    return (not bad), bad


def main(argv):
    vals = run_probe()
    ok_exp, bad = check_expect(vals)
    if not ok_exp:
        print("✘ 恒值语义表的**叙述**与实测不一致（%d 处）" % len(bad))
        for b in bad:
            print("   · " + b)
        return 1
    block = render(vals)
    mode = argv[1] if len(argv) > 1 else ""
    if mode == "--write":
        if not os.path.isfile(DOC):
            raise SystemExit("文档不存在：%s" % DOC)
        text = io.open(DOC, encoding="utf-8").read()
        if BEGIN not in text or END not in text:
            raise SystemExit("文档里没有机器块标记（BEGIN/END）")
        i = text.index(BEGIN)
        j = text.index(END) + len(END)
        new = text[:i] + block + text[j:]
        io.open(DOC, "w", encoding="utf-8", newline="").write(new)
        print("✔ 已重写 %s 的机器块" % os.path.basename(DOC))
        return 0
    if mode == "--check":
        if not os.path.isfile(DOC):
            print("✘ 文档不存在：%s" % DOC)
            return 1
        text = io.open(DOC, encoding="utf-8").read()
        if BEGIN not in text or END not in text:
            print("✘ 文档里没有机器块标记")
            return 1
        cur = text[text.index(BEGIN):text.index(END) + len(END)]
        if cur.strip() != block.strip():
            print("✘ 恒值语义表已过期（实测/统计与文档不一致）")
            for a, b in zip(cur.splitlines(), block.splitlines()):
                if a != b:
                    print("  文档: %s" % a)
                    print("  实际: %s" % b)
                    break
            print("  处置：python tools/scan_constant_semantics.py --write")
            return 1
        print("✔ 恒值语义表与实测/统计一致（%d 行）" % len(ROWS))
        return 0

    print(block)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
