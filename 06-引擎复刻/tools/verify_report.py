#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""核对报告里的关键数字与实跑是否一致。

为什么需要它
    报告 2600 多行，里面全是数字。而数字会**悄悄过期**：
    这份文档自己的第 8.5 节就记着「加 7 只生物后五项数字全部失效，
    包括被标为『可单次引用』的那一项」。

    所以「数字对不对」不能靠人记得，要靠**机器核对**。
    本脚本把报告里可机器验证的断言抽出来，逐条实跑比对，
    不一致就**列出来**而不是只报一个「失败」。

判据设计（**两套**，2026-10-16 起）
    ① `CHECKS`：每条是 (章节, 转述标签, 取值函数, 期望子串)。
       ⚠️ 第二列是**人写的转述标签**，**不参与判定**（只用于打印）。
          实测 15 条里只有 4 条能在报告里逐字找到 —— 它本来就不是引文。
          第一版文档里把它写成「报告里的原话片段」，那是**对工具能力的错误描述**：
          它会让人以为「标签在，就说明报告里写着这句话」。**现在这句话已改正。**
       取「实跑值」的方式：跑对应入口并解析输出；`expect` 是**必须出现在实跑值里**的子串
       （用包含而不是全等：取值函数常会带上说明前缀）。
    ② `BASELINE`（§47 **当前基线**）：**本工具唯一真正「读报告」的地方** ——
       解析报告 `## 47.` 一节里的 `| 项目 | 整数 |` 表格，逐行与实跑值**按数值**比对。
       改了引擎忘了改表 ⇒ 报红；表里写了不存在的项目 ⇒ 报红。

用法
    python tools/verify_report.py            # 核对全部
    python tools/verify_report.py -v         # 逐条打印
"""
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# ★ 解释器不写死：用「跑这个工具的那个 python」（子进程继承同一环境）
PY = sys.executable
RUN = os.path.join(ROOT, '..', '03-参考架构', '_run_lua.py')
REPORT = os.path.join(ROOT, '世界可跑可看报告.md')
# ★ 交付物是 world_player.html（`world_day_player.html` 是历史名字，
#   第一版核对工具指着它 ⇒ 永远报「不存在」而没人发现。
PLAYER = os.path.join(ROOT, '_out', 'world_player.html')
EDGE = r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'


# ★★ 同一个入口在一次核对里**只跑一次**（按 (入口, 环境变量) 记忆）。
#   两个理由，第二个更重要：
#     ① 快：`full.lua` 被 3 条条目引用，原来就真的跑 3 遍；§47 又引用 3 个值 ⇒ 会跑 6 遍。
#     ② ★ **一致性**：同一个量在一次核对里跑两遍，理论上可以给出两个值
#        （世界有时间/随机性、机器负载也不同）。那时工具报的「不一致」
#        到底是「报告过期」还是「两次跑得不一样」，没人分得清。
#        这与本工程反复出现的「**同一件事两处实现**」是同一类问题。
_RUN_CACHE = {}


def run_lua(entry, env=None, timeout=300):
    """跑一个入口，返回 (exit_code, 完整输出文本)。同 (entry, env) 只跑一次。"""
    key = (entry, tuple(sorted((env or {}).items())))
    if key in _RUN_CACHE:
        return _RUN_CACHE[key]
    e = dict(os.environ)
    if env:
        e.update(env)
    script = os.path.join(ROOT, entry + '.lua')
    p = subprocess.run([PY, '-u', RUN, '5.1', script],
                       capture_output=True, cwd=ROOT, env=e, timeout=timeout)
    raw = p.stdout + p.stderr
    # 用 replace 解码：输出里可能有非 UTF-8 字节（lupa 严格解码的已知问题）
    res = (p.returncode, raw.decode('utf-8', 'replace'))
    _RUN_CACHE[key] = res
    return res


def grab(text, pattern, default='?'):
    m = re.search(pattern, text)
    return m.group(1) if m else default


#=========================================================================
# 断言表：(章节, 报告里写的值, 取值函数)
#=========================================================================
def a_full_baseline():
    _, t = run_lua('full')
    return grab(t, r'注册了预制体的文件\s*:\s*(\d+)'), '1525'


def a_full_failed():
    _, t = run_lua('full')
    return grab(t, r'加载失败\s*:\s*(\d+)'), '0'


def a_full_total():
    _, t = run_lua('full')
    return grab(t, r'预制体总数\s*:\s*(\d+)'), '6081'


def a_assertions():
    _, t = run_lua('tests')
    n = grab(t, r'共 (\d+) 条断言')
    fail = grab(t, r'共 \d+ 条断言，失败 (\d+)')
    return '%s 条断言 / 失败 %s' % (n, fail), None   # 数字会变，只要求失败=0


def a_mech():
    _, t = run_lua('mech')
    n = grab(t, r'通过 (\d+) · 宿主边界')
    b = grab(t, r'通过 \d+ · 宿主边界 (\d+) ·')
    f = grab(t, r'通过 \d+ · 宿主边界 \d+ · 失败 (\d+)')
    return '%s 通过 / %s 边界 / %s 失败' % (n, b, f), None


def a_world_gaps():
    _, t = run_lua('world')
    real = re.search(r'【真缺口】无', t)
    stub = re.search(r'【桩调用】无', t)
    return ('真缺口无=%s 桩调用无=%s' % (bool(real), bool(stub))), None


def a_world_misc():
    _, t = run_lua('world')
    return '%s 生物 / %s 状态名' % (
        grab(t, r'生物 (\d+) 个'), grab(t, r'全局不同状态名 (\d+) 种')), None


def a_seasons():
    _, t = run_lua('seasons')
    return ('顺序%s 四季%s 冬冷%s' % (
        '✔' if '顺序一致：✔' in t else '✘',
        '✔' if '四季都出现过：✔' in t else '✘',
        '✔' if '冬天更冷' in t else '✘')), None


def a_renderer():
    """双后端 A/B：scale=1 必须逐字节 100%（硬判据）。"""
    if not os.path.exists(PLAYER):
        return '播放器不存在', None
    p = subprocess.run([PY, os.path.join(ROOT, 'tools', 'compare_renderers.py')],
                       capture_output=True, cwd=ROOT, timeout=600)
    t = (p.stdout + p.stderr).decode('utf-8', 'replace')
    return 'scale=1 逐字节 %s' % grab(t, r'scale=1 zoom=1 tick=2000[^\n]*?逐字节\s+([\d.]+)%'), None


def a_player_size():
    """播放器体积（MB），只做记录不做判定。"""
    if not os.path.exists(PLAYER):
        return '不存在', None
    return '%.1f MB' % (os.path.getsize(PLAYER) / 1048576.0), None


# ★★ T30：原来的 `a_reachability`（300 抽样之 295）**已删除**，理由三条：
#   ① 它的数字已被 `a_reach_exhaustive`（穷举）取代 —— 报告里不再引用抽样值；
#   ② 它依赖 `_out/_names300.txt` 这个**一次性产物**（临时名单），
#      而入口 `reachability.lua` 自带确定性种子抽样，不需要外部名单；
#   ③ **更关键**：它跑探针时 `U.Install(Core)` 打开了**万能兜底**，
#      于是「缺全局」会被兜住而不失败 ⇒ 它量到的可达率**语义上和真入口不同**
#      （真入口不开兜底）。**留着一个量不同东西的函数，比删掉更危险。**
#   ⇒ 需要抽样口径时，直接用：`REACH_N=300 … reachability.lua`
#
#   旧实现留在 git 之外的历史文档里（报告 §36 记着它的用法与当时的数）。


#=========================================================================
# 第三轮新增：把「穷举可达率 / 断言数 / 修复清单 / 边界登记表」也交给机器核对
#=========================================================================
def a_reach_exhaustive():
    """可达性**穷举**（REACH_N = 注册表总数）—— 精确值，不是抽样估计。"""
    _, t = run_lua('reachability', env={'REACH_N': '6081'}, timeout=300)
    ok_n = grab(t, r'可达\s*:\s*(\d+)')
    bad_n = grab(t, r'不可达\s*:\s*(\d+)')
    undet = grab(t, r'⚠ 未定性\s*(\d+)\s*条', '0')
    return 'REACH %s/%s 未定性 %s' % (ok_n, bad_n, undet), None


def a_assertion_count():
    """行为断言条数与失败数（报告 §41.10 / §42.6 / §43.6 引用）。"""
    _, t = run_lua('tests')
    return '断言 %s 条 失败 %s' % (
        grab(t, r'共\s*(\d+)\s*条断言'),
        grab(t, r'条断言，失败\s*(\d+)\s*条')), None


def a_audit_count():
    """修复清单条数与缺失数（防「文件恢复不完整静默丢修复」）。"""
    p = subprocess.run([PY, '-u', os.path.join(ROOT, 'tools', 'audit_fixes.py')],
                       capture_output=True, cwd=ROOT, timeout=120)
    t = (p.stdout + p.stderr).decode('utf-8', 'replace')
    return '清单 %s 条 缺失 %s 条' % (
        grab(t, r'共\s*(\d+)\s*条，缺失'),
        grab(t, r'条，缺失\s*(\d+)\s*条')), None


def a_boundary_table():
    """边界登记表的规模（§41.8 / §43.3 引用了这个数）。"""
    _, t = run_lua('reachability', env={'REACH_N': '300'}, timeout=300)
    return '登记 %s 个案 / %s 规则' % (
        grab(t, r'(\d+)\s*条个案'),
        grab(t, r'条个案 /\s*(\d+)\s*条规则')), None




def a_shadow_gate():
    """影子闸门在标准场景里实际拦下多少次重复 AddComponent（报告 §44.6）。"""
    _, t = run_lua('world')
    m = re.search(r'影子闸门（重复 AddComponent）：.*?\*\*(\d+) 次\*\*', t)
    if not m:
        return '未取到', None
    return '闸门 %s 次' % m.group(1), None


CHECKS = [
    ('第 35 节 · full 基线', '注册文件数 1525', a_full_baseline, '1525'),
    ('第 35 节 · full 基线', '加载失败 0', a_full_failed, '0'),
    ('第 35 节 · full 基线', '预制体总数 6081', a_full_total, '6081'),
    ('第 35 节 · 断言', '全部通过', a_assertions, None),
    ('第 33 节 · 机制', '无失败', a_mech, None),
    ('第 30 节 · 缺口', '真缺口与桩调用均为无', a_world_gaps, None),
    ('第 28 节 · 世界', '27 只生物', a_world_misc, None),
    ('第 16 节 · 四季', '三项全对', a_seasons, None),
    ('第 26 节 · 渲染', 'scale=1 逐字节 100%', a_renderer, '100.000'),
    ('第 35 节 · 播放器', '体积记录', a_player_size, None),
    # ★ 明确的期望值（不是 None）—— 否则「回退到 288」这类变化抓不到
    # ★★ 第三轮把口径从抽样推进到穷举：抽样数不再是结论性数字，
    #   故这里只核对**穷举**（精确值）。旧的抽样函数已删除（见上面的说明）。
    ('第 43 节 · 可达性穷举', '6038 / 6081 = 99.29%，未定性 0',
     a_reach_exhaustive, 'REACH 6038/43 未定性 0'),
    ('第 43 节 · 断言数', '99 条 0 失败', a_assertion_count, '断言 99 条 失败 0'),
    # ★ C9（2026-10-18 P44）：这里**原本**还有一条「修复清单 152 条」的 CHECKS，
    #   它是该数字的**第三份副本**（清单代码、报告 §47、本行各一份）。
    #   三份副本的代价不是「要记得改三处」，而是：**只要三处一起改，就永远不会红**。
    #   而且它的期望值与取值函数来自**同一个** a_audit_count，本质上是
    #   「拿自己跟自己比」—— 永远为真的判据，比“会过期”更坏。
    #   → 已删除。真正的交叉核对只保留一处：下面 BASELINE_LIVE 的
    #   '修复清单（' / '修复清单缺失'——它把**报告 §47 表里写的数**
    #   与实跑清单长度逐行比（两个独立来源）。
    ('第 43 节 · 边界登记表', '12 个案 / 7 规则', a_boundary_table,
     '登记 12 个案 / 7 规则'),
    # ★ §44.6 那条「闸门拦下 20 次」原先只写在散文里（而且是**我自纠过一次**的数：
    #   一次性探针给 0、入口给 20）。⇒ 交给机器守着，避免又悄悄过期。
    ('第 44.6 节 · 影子闸门', '标准场景拦下 20 次', a_shadow_gate, '闸门 20 次'),
]


#=========================================================================
# ★★ 第四轮（2026-10-16）：让这个工具**真的读报告**
#=========================================================================
# 在加这一段之前，`CHECKS` 的第二列（章节旁边的那个短语）**从来没有拿去和报告比对**，
# 它只是打印用的标签。于是它自己会漂移：有一条写着「91 条 缺失 0」，而报告里
# 早就不存在这个数了 —— 工具却一直把它当成「报告说的」在打印。
#
# ⇒ 真正「读报告」的机制放在 §47：报告里有一张**格式固定**的当前基线表，
#   本工具解析它、逐行按**数值**与实跑比对。
BASELINE_HEAD = '## 47. '


def _report_text():
    """读报告全文（**每次都重新读**：工具可能被长驻进程调用，缓存会读到旧内容）。"""
    try:
        with io.open(REPORT, encoding='utf-8', errors='replace') as f:
            return f.read()
    except OSError:
        return ''


def parse_baseline(text=None):
    """解析报告 §47 的 `| 项目 | 整数 |` 表格 → {项目: int}；找不到那一节返回 None。"""
    t = _report_text() if text is None else text
    i = t.find(BASELINE_HEAD)
    if i < 0:
        return None
    block = t[i:]
    j = block.find('\n## ', 1)
    if j > 0:
        block = block[:j]
    out = {}
    for line in block.split('\n'):
        s = line.strip()
        if not s.startswith('|'):
            continue
        cells = [c.strip() for c in s.strip('|').split('|')]
        if len(cells) != 2:
            continue
        k, v = cells
        # ★ 只收**纯整数**行 ⇒ 表头（「项目 | 当前值」）与分隔行（`|---|---|`）
        #   自然被排除。不靠「跳过第 N 行」这种一改格式就失效的写法。
        if re.fullmatch(r'\d+', v) and k and k != '项目':
            out[k] = int(v)
    return out


def _int_of(getter, pattern):
    v, _ = getter()
    m = re.search(pattern, str(v))
    return int(m.group(1)) if m else None


# §47 表格里的「项目名（前缀）」 → 怎么算当前值
# ★ 用**前缀匹配**而不是全等：表里为了可读性会带括号注明来源
#   （「注册文件数（`full.lua`）」），全等匹配一改注释就失效。
BASELINE_LIVE = [
    ('注册文件数',   lambda: _int_of(a_full_baseline, r'(\d+)')),
    ('加载失败',     lambda: _int_of(a_full_failed, r'(\d+)')),
    ('预制体总数',   lambda: _int_of(a_full_total, r'(\d+)')),
    ('行为断言',     lambda: _int_of(a_assertion_count, r'断言 (\d+) 条')),
    ('行为断言失败', lambda: _int_of(a_assertion_count, r'失败 (\d+)')),
    ('机制横扫 通过', lambda: _int_of(a_mech, r'(\d+) 通过')),
    ('机制横扫 边界', lambda: _int_of(a_mech, r'(\d+) 边界')),
    ('机制横扫 失败', lambda: _int_of(a_mech, r'(\d+) 失败')),
    ('可达（穷举',   lambda: _int_of(a_reach_exhaustive, r'REACH (\d+)/')),
    ('不可达（穷举', lambda: _int_of(a_reach_exhaustive, r'REACH \d+/(\d+)')),
    ('可达性 未定性', lambda: _int_of(a_reach_exhaustive, r'未定性 (\d+)')),
    ('修复清单（',   lambda: _int_of(a_audit_count, r'清单 (\d+) 条')),
    ('修复清单缺失', lambda: _int_of(a_audit_count, r'缺失 (\d+) 条')),
    ('边界个案',     lambda: _int_of(a_boundary_table, r'登记 (\d+) 个案')),
    # ⚠️ 这里是 `个案 / 5 规则`（斜杠后有空格）—— 第一版写成 `/(\d+) 规则` 取不到值，
    #    于是 §47 报「报告写 5，实跑 None」。**取值函数取不到值时必须报 None，
    #    而比对端把 None 当「不一致」**：否则「没取到」会被当成「没问题」（本工程的老坑）。
    ('边界规则',     lambda: _int_of(a_boundary_table, r'/\s*(\d+) 规则')),
    ('影子闸门拦截', lambda: _int_of(a_shadow_gate, r'闸门 (\d+) 次')),
]


def check_baseline(report_text=None, live=None, verbose=False):
    """★ 逐行比对报告 §47 的当前基线与实跑值。返回不一致条数。

    ★ 三种失败形态都要能报（缺一种就有盲区）：
      ① 报告里没有 §47 —— 说明「被机器读的那份表」被人删了；
      ② 表里的值 ≠ 实跑值 —— 数字过期（这是最常见的一种）；
      ③ `BASELINE_LIVE` 里登记的项目在表里**找不到** —— 说明表被改瘦了，
         工具不再覆盖它 ⇒ 必须报，不能默默少查一项。
    """
    bad = 0
    rep = parse_baseline(report_text)
    if rep is None:
        print('  ✘ 报告里找不到「%s」一节 —— 当前基线表不见了（它是唯一被机器读的部分）'
              % BASELINE_HEAD.strip())
        return 1
    if live is None:
        live = {name: fn() for name, fn in BASELINE_LIVE}
    for name, fn in BASELINE_LIVE:
        got = live.get(name)
        key = next((k for k in rep if k.startswith(name)), None)
        if key is None:
            print('  ✘ §47 里缺项目「%s*」—— 工具覆盖了它，表里却没有' % name)
            bad += 1
            continue
        if rep[key] != got:
            print('  ✘ §47「%s」：报告写 %s，实跑 %s' % (key, rep[key], got))
            bad += 1
        elif verbose:
            print('  ✔ §47「%s」= %s' % (key, got))
    return bad


def selftest_baseline():
    """★ 拿**合成违规**撞 check_baseline：该响时必须响、干净输入不许响。

    —— 本工程纪律：「检查写好了」≠「检查生效过」。死代码在干净状态下同样输出 ✔。
    """
    print('  §47 比对自检（合成用例）：')
    good_live = {name: 7 for name, _ in BASELINE_LIVE}
    rows = '\n'.join('| %s | 7 |' % name for name, _ in BASELINE_LIVE)
    clean = '%s\n\n| 项目 | 当前值 |\n|---|---|\n%s\n' % (BASELINE_HEAD, rows)
    stale = clean.replace('| 影子闸门拦截 | 7 |', '| 影子闸门拦截 | 6 |')
    thin = clean.replace('| 影子闸门拦截 | 7 |', '')
    cases = [
        ('干净输入不得报', clean, good_live, 0),
        ('数字过期必须报', stale, good_live, 1),
        ('表被改瘦必须报', thin, good_live, 1),
        ('缺 §47 必须报', '没有那一节', good_live, 1),
    ]
    bad = []
    for name, txt, lv, want in cases:
        # check_baseline 会直接 print，自检时静音掉
        import io as _io
        import contextlib
        buf = _io.StringIO()
        with contextlib.redirect_stdout(buf):
            got = check_baseline(report_text=txt, live=lv)
        mark = '✔' if got == want else '✘'
        if got != want:
            bad.append(name)
        print('    %s %-18s 期望报 %d 条，实际 %d 条' % (mark, name, want, got))
    if bad:
        print('  ✘ §47 自检不过：%s' % '、'.join(bad))
        return 1
    print('  ✔ 4 条合成用例全部符合预期')
    return 0


def main():
    verbose = '-v' in sys.argv
    print('  报告数字核对  ——  %s' % os.path.basename(REPORT))
    print('  ' + '─' * 66)
    bad = 0
    for where, claim, fn, expect in CHECKS:
        try:
            got, _ = fn()
        except Exception as e:
            got = '异常: %s' % str(e)[:80]
        if expect is not None:
            # ★ 用「子串包含」而不是全等：取值的函数常会带上说明前缀
            #   （如 'scale=1 逐字节 100.000'），全等会造成**假不一致**——
            #   第一版就因此把一条 ✔ 的检查报成 ✘。
            ok = (str(expect) in str(got))
        else:
            # ★★ 无固定期望时的判据 —— 这里踩过一次「宽容判据」的坑：
            #   第一版写成「不含失败标记就算过」，结果一条返回 `REACH ?`
            #   （探针压根没出结果）的检查**被判成通过**。
            #   那等于把「没读到」当成「没问题」——与本工程一直在防的
            #   「静默失效」是同一类错误，只不过这次在核对工具自己身上。
            #   ⇒ 判据改成：**出现 `?` 一律算失败**（表示没取到值）。
            g = str(got)
            if '?' in g:
                ok = False
            elif '失败' in g:
                ok = ('失败 0' in g) or ('失败=0' in g) or ('/ 0 失败' in g)
            else:
                ok = ('✘' not in g) or ('true' in g)
        if not ok:
            bad += 1
        if verbose or not ok:
            # ★ 措辞从「报告称」改成「标签」：这一列**不参与判定**、也**不等于报告里真写着这句**
            #   （见文件头的判据设计）。原来的措辞会让人以为报告被读过了 —— 那是假象。
            print('  %s %-22s 标签「%s」  实跑=%s' % (
                '✔' if ok else '✘', where, claim, got))

    # ★★ 先自检（合成违规），再比对真报告 —— 顺序不能反：
    #   自检若跑在真实比对**之后**，它的清理动作会搅乱真实结果
    #   （07 工程的 `verify_plan.py` 就栽过一次：自检把**真实**的不一致记录一起清了）。
    rc_self = selftest_baseline()
    if rc_self != 0:
        print('  ✘ 自检不过 —— 下面的 §47 比对结果**不可信**')
        return 1
    print('  §47 当前基线（**本工具唯一真正读报告的地方**）：')
    bad_base = check_baseline(verbose=verbose)
    if bad_base == 0:
        print('  ✔ §47 的 %d 项当前基线与实跑逐项一致' % len(BASELINE_LIVE))

    print('  ' + '─' * 66)
    total_bad = bad + bad_base
    print('  条目 %d 条，不一致 %d 条（其中 §47 基线 %d 条）' % (len(CHECKS), total_bad, bad_base))
    if total_bad == 0:
        print('  ✔ 报告里的可机器验证数字与实跑一致')
        return 0
    print('  ✘ 有 %d 条对不上 —— **不要手改历史节**（那是「当时发生了什么」），'
          '要改就改 §47 那张当前基线表' % total_bad)
    return 1


if __name__ == '__main__':
    sys.exit(main())