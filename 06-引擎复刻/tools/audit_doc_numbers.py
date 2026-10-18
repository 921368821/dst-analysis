#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""扫描**所有** .md 里的「会过期的数字」，与实跑真值对照。

为什么需要它
    已有的 `tools/verify_report.py` 只核对 **`世界可跑可看报告.md` 一个文件**。
    但本工程有 10 个 .md，**同一个数字会散落在多份文档里**，各自悄悄过期：
      · `世界可跑可看报告.md:740` 写着「播放器 26.4 MB」，实际已 10.2 MB
      · `RESUME.md:33` 写着「tests.lua（17 条断言）」，实际已 70 条
      · `进度总览.md:25` 写着「4.3 MB 自包含」
    这些都是**同一件事被抄了四遍**，改一处忘三处。

★★ 关键设计：区分「当前状态声明」与「历史记录引用」
    报告 §41/§42/§43 里**故意**保留旧值（那是历史记录的原文），
    不能一律改成新值 —— 那会把「当时发生了什么」抹掉。
    所以本工具**不自动改**，只**列出**：每个命中都带 file:line + 上下文 + 真值，
    由人判定它是「当前状态」还是「历史引用」。
    ⇒ 判据必须由人下，工具负责的是「不漏」。

用法
    python tools/audit_doc_numbers.py          # 列出所有命中
    python tools/audit_doc_numbers.py --strict # 只列「当前状态」区（排除 §41~§44 历史节）
"""
import datetime
import io
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# ★ 解释器不写死：用「跑这个工具的那个 python」（子进程继承同一环境）
PY = sys.executable
RUN = os.path.join(ROOT, '..', '03-参考架构', '_run_lua.py')

# 历史记录章节的前缀（这些节里的旧值是**故意保留**的）
# ★★★ T54：把「硬编码集合」升级为「**有理由的集合**」
#   之前这些集合只写了内容，没写**为什么**它们在里面 ——
#   下一个人想加/删一项时没有依据，只能猜。
#   ⇒ 每一条都附 `why`，并由 `config_problems()` 自检
#     （理由非空、非空集、**两个集合不能有交集**、历史节清单要与实际存在的章节对得上）。
CONFIG = {
    'historical_sections': {
        # 这些章节里的旧值是**故意保留**的历史记录，不做「当前状态」核对。
        'values': ('41.', '42.', '43.', '44.', '8.', '16.', '17.', '26.'),
        'why': '报告里这些节是**当时**的记录；值过期是有意的，改成新值会抹掉「当时发生了什么」',
    },
    'record_hints': {
        # 「记录时间」：不能是未来
        'values': ('生成时间', '重写时间', '时段', '实读', '收尾', '执行记录', '时间戳', '验收（'),
        'why': '这些词标记的是「写下某事**发生在何时**」⇒ 逻辑上不能晚于现在',
    },
    'target_hints': {
        # 「目标时间」：本来就是未来，跳过
        'values': ('截止', '还剩', '里程', '前完成', '前做完', '预期', '计划',
                   '验收标准', '时间节点', '缓冲'),
        'why': '这些词标记的是「**计划里**要到达的时刻」⇒ 本来就是未来，不是错',
    },
}


def config_problems():
    """T54：硬编码集合的**自检** —— 每条必须有理由，且不能互相打架。

    ★ 最有价值的一条是「**两集合不能有交集**」：
      某个词若同时出现在 record 与 target 里，代码里 `if any(k in line for k in TARGET_HINTS): continue`
      会**先命中 target** ⇒ 那个词作为「记录时间」标记**永远失效**，而且**没有任何提示**。
      这与今天反复出现的「静默失效」是同一类。
    """
    probs = []
    for name, spec in CONFIG.items():
        vals, why = spec.get('values', ()), spec.get('why', '')
        if not vals:
            probs.append('%s: 集合为空' % name)
        if len(str(why).strip()) < 8:
            probs.append('%s: 缺实质理由（why 太短）' % name)
    # ★ T59：historical_sections 里的节号必须**实际存在**于报告
    #   （否则就是「列了一个不存在的章节」—— 例如写了 '8.' 但报告写的是 `## 八、`）
    rep_path = os.path.join(ROOT, '世界可跑可看报告.md')
    if os.path.exists(rep_path):
        lines = io.open(rep_path, encoding='utf-8', errors='replace').read().split('\n')
        present = set()
        for i in range(len(lines)):
            sec = section_of(lines, i)
            if sec:
                present.add(sec)
        for v in CONFIG['historical_sections']['values']:
            key = v.rstrip('.')
            if key not in present:
                probs.append("historical_sections 里的「%s」在报告里**找不到对应章节**"
                             "（注意中文数字：报告写 `## 八、` 就要能被归一化成 8）" % v)
    rec = set(CONFIG['record_hints']['values'])
    tgt = set(CONFIG['target_hints']['values'])
    both = rec & tgt
    if both:
        probs.append('record/target 有交集 %s —— target 先命中 ⇒ 这些词作为「记录时间」标记**永远失效**'
                     % '、'.join(sorted(both)))
    return probs


def ground_truth():
    """能直接量出来的真值。拿不到的返回 None（**不猜**）。"""
    gt = {}
    player = os.path.join(ROOT, '_out', 'world_player.html')
    if os.path.exists(player):
        gt['player_mb'] = os.path.getsize(player) / 1048576.0
    # 入口数 = 顶层 .lua（排除 host/ 与 tools/ 与 _ 开头）
    # ★ 目录下的 .lua 不等于「回归入口」：`compdiag.lua` 是**诊断脚本**
    #   （给组件计数用的），不进回归集。文档里说的「14 入口」指回归集。
    #   ⇒ 把区分写进工具，而不是让「15 vs 14」这个差一直没人解释。
    DIAGNOSTIC = {'compdiag.lua'}
    ents = [f for f in os.listdir(ROOT)
            if f.endswith('.lua') and not f.startswith('_')
            and f not in DIAGNOSTIC]
    gt['entries'] = len(ents)
    gt['entry_names'] = sorted(ents)
    return gt


def assertion_count():
    """跑 tests.lua 取断言条数与失败数（约 10 秒，可接受）。"""
    p = subprocess.run([PY, '-u', RUN, '5.1', os.path.join(ROOT, 'tests.lua')],
                       capture_output=True, cwd=ROOT, timeout=180)
    t = (p.stdout + p.stderr).decode('utf-8', 'replace')
    m = re.search(r'共\s*(\d+)\s*条断言，失败\s*(\d+)\s*条', t)
    return (int(m.group(1)), int(m.group(2))) if m else (None, None)


_CN_DIGITS = {'零': 0, '一': 1, '二': 2, '三': 3, '四': 4, '五': 5,
              '六': 6, '七': 7, '八': 8, '九': 9, '十': 10, '百': 100}


def _cn2num(tok):
    """中文数字 → 阿拉伯数字字符串（只处理本报告用到的形态：1~99）。"""
    if tok.isdigit():
        return tok
    if not all(c in _CN_DIGITS for c in tok):
        return tok
    # 十 / 十五 / 二十 / 二十三 / 百 …
    if tok == '十':
        return '10'
    if tok.startswith('十'):
        return str(10 + _CN_DIGITS[tok[1:]])
    if '十' in tok:
        a, b = tok.split('十')
        return str(_CN_DIGITS[a] * 10 + (_CN_DIGITS[b] if b else 0))
    if tok == '百':
        return '100'
    return str(_CN_DIGITS.get(tok, tok))


def section_of(lines, idx):
    """往回找最近的 markdown 标题，用于判定是不是历史节。"""
    for i in range(idx, -1, -1):
        m = re.match(r'^#{1,3}\s+([一二三四五六七八九十百零\d]+)[、.]', lines[i])
        if m:
            # ★★ 归一化中文数字 → 阿拉伯数字。
            #   根因：报告前几节写的是 `## 八、…`（中文数字），而 `historical_sections`
            #   里列的是 `'8.'` ⇒ **永远匹配不上** ⇒ `--strict` 声称「跳过历史节」，
            #   实际上 8/16/17/26 这几节**根本没被跳过**。
            #   （T59 的「节号必须实际存在」检查抓到它。）
            return _cn2num(m.group(1))
        m2 = re.match(r'^##+\s+(\d+)[.\s]', lines[i])
        if m2:
            return m2.group(1)
    return ''


def scan(strict=False):
    gt = ground_truth()
    n_assert, n_fail = assertion_count()
    hits = []

    for fn in sorted(os.listdir(ROOT)):
        if not fn.endswith('.md'):
            continue
        path = os.path.join(ROOT, fn)
        lines = io.open(path, encoding='utf-8', errors='replace').read().split('\n')
        fence = False
        for i, line in enumerate(lines):
            # ★ 同上：代码块里的数字是命令/示例，不当「文档声明」核对。
            if line.lstrip().startswith('```'):
                fence = not fence
                continue
            if fence:
                continue
            sec = section_of(lines, i)
            if strict and sec in CONFIG['historical_sections']['values']:
                continue
            # ★★ 还要跳过**行内代码**（反引号包起来的部分）—— 与「跳过 ``` 代码块」
            #   同一原则：**引用的字面量不是声明**。
            #   实测踩到：§18.7 的**负测表**里引用 `**999 条断言，0 失败**`
            #   作为「输入样例」，被当成「文档声称 999 条」而报假阳。
            line_wo_code = re.sub(r'`[^`]*`', '', line)

            # ⓿ 约定：带「当时值」标记的行是**故意保留的历史引用**，跳过。
            #   ★ 给工具加这条不是「让报告变绿」，而是把「历史 vs 当前」这个
            #     判断**显式化**：要么改数，要么写清楚它是当时值。两者都不做才算漏。
            if '当时值' in line:
                continue

            # ① 播放器体积
            for m in re.finditer(r'([0-9]+(?:\.[0-9]+)?)\s*MB', line_wo_code):
                if not re.search(r'播放器|world_player|自包含|anim_player', line):
                    continue
                val = float(m.group(1))
                if 'anim_player' in line:
                    tgt = os.path.join(ROOT, '_out', 'anim_player.html')
                    if not os.path.exists(tgt):
                        continue
                    real = os.path.getsize(tgt) / 1048576.0
                else:
                    real = gt.get('player_mb')
                if real is None:
                    continue
                if abs(val - real) > 0.15:
                    hits.append((fn, i + 1, '播放器体积', m.group(0),
                                 '%.1f MB' % real, line.strip()[:96]))

            # ② 断言条数
            # ★★ 收紧判据（原来只写 `(\d+)\s*条断言`，太松 ⇒ **假阳性三连**）：
            #   它把「**补了 5 条断言**」「**3 条断言全部报红**」这类**局部计数/**
            #   **动作描述**也当成了「文档在声明总条数」⇒ 报了 3 处假阳。
            #   ⇒ 只认**明确表示总数**的写法：
            #       · `**N 条断言**`（加粗，本文档声明总数的惯例）
            #       · `共 N 条断言` / `总数 N 条断言`
            #       · `N 条断言，0 失败`（回归表的写法）
            #   ⚠️ 判据太松和太紧都有代价：太松 = 假阳性淹掉真问题；
            #      太紧 = 漏。这里选「只认显式总数」，并把边界写在注释里。
            for m in re.finditer(
                    r'\*\*(\d+)\s*条断言\*\*'
                    r'|共\s*(\d+)\s*条断言'
                    r'|(\d+)\s*条断言[，,]\s*0\s*失败', line_wo_code):
                val = int(m.group(1) or m.group(2) or m.group(3))
                if n_assert and val != n_assert:
                    hits.append((fn, i + 1, '断言条数', m.group(0),
                                 '%d 条' % n_assert, line.strip()[:96]))

            # ④ 「**N / N PASS**」这种写法（回归结果表最常用）
            for m in re.finditer(r'\*\*\s*(\d+)\s*/\s*(\d+)\s*PASS\s*\*\*', line_wo_code):
                a, b = int(m.group(1)), int(m.group(2))
                if a != gt['entries'] or b != gt['entries']:
                    hits.append((fn, i + 1, '回归通过数', m.group(0),
                                 '%d/%d' % (gt['entries'], gt['entries']),
                                 line.strip()[:96]))

            # ③ 入口数
            for m in re.finditer(r'\*\*([0-9]+)\s*/\s*([0-9]+)\s*入口|([0-9]+)\s*入口回归', line_wo_code):
                val = int(m.group(1) or m.group(3))
                if val != gt['entries']:
                    hits.append((fn, i + 1, '入口数', m.group(0),
                                 '%d 入口' % gt['entries'], line.strip()[:96]))
    return hits, gt, (n_assert, n_fail)




#=========================================================================
# ★★★ 第 5 条规则：**未来时间戳**（本项目最高频的自造错误）
#=========================================================================
#   为什么单列一条：我今天**九次**在文档里写出「还没到的时间」
#   （15:00~18:30 / 18:2x / 18:0x~18:3x …），每一次都是「为了写得完整而编一个」。
#   ★ 它的要害在于**看起来最可核验、实际最不可核验** —— 读者不会去比对时钟。
#
#   ⇒ 好在它**机械可判**：不能在某时刻之前写下一个晚于该时刻的「记录时间」。
#
#   ⚠️ 判据要分清两种时间，否则会有大量假阳性：
#     · 「记录时间」（生成时间/重写时间/时段/实读/收尾/执行记录）→ **不能是未来**
#     · 「目标时间」（截止 / 还剩 / 里程穗 / 前完成 / 前做完）→ **本来就是未来**，跳过
def future_timestamps(now=None):
    import datetime as _dt
    now = now or _dt.datetime.now()
    today = now.date()
    RECORD_HINTS = CONFIG['record_hints']['values']
    TARGET_HINTS = CONFIG['target_hints']['values']
    hits = []
    for fn in sorted(os.listdir(ROOT)):
        if not fn.endswith('.md'):
            continue
        lines = io.open(os.path.join(ROOT, fn), encoding='utf-8',
                        errors='replace').read().split('\n')
        fence = False
        for i, line in enumerate(lines):
            # ★ 跳过 ``` 围起来的代码块：那里是**引用的输出**（示例），不是断言。
            #   实测踩到：§14.5 里引用了「注入测试」的工具输出，
            #   那段输出里有个未来的时间戳示例 ⇒ 被自己的检查误报。
            if line.lstrip().startswith('```'):
                fence = not fence
                continue
            if fence:
                continue
            if any(k in line for k in TARGET_HINTS):
                continue
            if not any(k in line for k in RECORD_HINTS):
                continue
            # 带日期的时间（精确写法）
            precise = False
            for m in re.finditer(r'2026-(\d{2})-(\d{2})\s+(\d{1,2}):(\d{2})', line):
                precise = True
                mo, d, hh, mm = (int(x) for x in m.groups())
                try:
                    t = _dt.datetime(2026, mo, d, hh, mm)
                except ValueError:
                    continue
                if t > now:
                    hits.append((fn, i + 1, '未来时间戳', m.group(0),
                                 '现在 %s' % now.strftime('%H:%M'),
                                 line.strip()[:96]))

            # ★★ T28：**模糊时间戳** —— 上一版记的已知盲区。
            #   我在 §45 标题里写过「2026-10-15 18:1x」，正则匹配不到 ⇒ 守卫放行；
            #   而模糊写法**本身就无法核验**，比写错精确值更危险（读者也不会计较）。
            #   ⇒ 判据不看「未来还是过去」，只看**它是不是可核验的形状**。
            #   识别：带日期的时间串里出现了非数字（如 18:1x / 1x:xx / 18:xx）。
            if not precise:
                for m in re.finditer(
                        r'2026-\d{2}-\d{2}\s+\d{0,2}[xX*]?\d{0,2}[:：][xX*\d]{0,2}[xX*]?[xX*]?', line):
                    tok = m.group(0)
                    # 只报「像一个时间但含模糊字符」的那些
                    if re.search(r'[:：]', tok) and re.search(r'[xX*]', tok):
                        hits.append((fn, i + 1, '模糊时间戳', tok,
                                     '不可核验（应写精确值或删掉时间）',
                                     line.strip()[:96]))
    return hits




#=========================================================================
# ★★ T32 规则**自检**：每条规则都必须证明自己「真的会响」
#=========================================================================
#   为什么必须有：今天**两次**踩到「检查写好了但从来没生效」——
#     ① 影子闸门只读不写，闸门空转；
#     ② 未来时间戳规则的合并写在了提前返回之后，从未执行。
#   两次都靠**反向测试**才抓到，而反向测试是**人记得才做**的。
#   ⇒ 就把「反向测试」做进工具**每次运行**里：喂 5 条**合成的**违规行，
#     每条都必须被对应规则抓到；少一条就报 ✘。
#
#   ★ 关键：走**真实的 scan()/future_timestamps()**，不单独测正则 ——
#     否则「规则被绕过」（如代码块跳过把整条规则废掉）测不出来。
#   ★ 为避免拖慢：自检时把 `assertion_count` 临时替换成常量（不跑 Lua）。
def self_check():
    import datetime as _dt
    probe = os.path.join(ROOT, '__selftest_probe__.md')
    bad_n = 25  # 与真实断言数不同，好让「断言条数」规则必须响
    cases = [
        # ★★★ 合成样本必须**相对当下**生成，不能硬编码一个绝对时间。
        #   实测踩到：原来写的是 `2026-10-15 23:59`（写的时候确实是未来），
        #   到了 **10-16** 它就成了**过去** ⇒ 规则正确地不响 ⇒ **自检误报「规则没响」**。
        #   ⇒ 一个会随时间自己失效的自检，比没有自检更糟：它会训练人忽略这个工具。
        #   （顺带说明这条自检是**有效的** —— 它真的发现了自己的样本过期。）
        ('未来时间戳',
         '## 生成时间：%s，`date` 实读'
         % (datetime.datetime.now() + datetime.timedelta(hours=2)).strftime('%Y-%m-%d %H:%M')),
        ('模糊时间戳', '## 生成时间：2026-10-15 18:1x，`date` 实读'),
        ('断言条数',   '| 行为断言 | **%d 条断言，0 失败** |' % bad_n),
        ('播放器体积', '| 播放器 | 99.9 MB 自包含 |'),
        ('回归通过数', '| 入口回归 | **99 / 99 PASS** |'),
        ('工具输出不符', '| `tools/scan_parameterized_factories.py` | 静态扫 ⇒ **999 命中** |'),
    ]
    # 第 7 类（类别名同步）是**结构性**检查，不产生「合成违规」——
    # 它的输入是代码与报告两侧，喂合成文本测不出来 ⇒ 单独在下面做**真值断言**。
    body = '\n'.join(c[1] for c in cases) + '\n'
    old_ac = globals().get('assertion_count')
    try:
        io.open(probe, 'w', encoding='utf-8', newline='\n').write(body)
        globals()['assertion_count'] = lambda: (72, 0)   # 常量，不跑 Lua
        hits, _gt, _ = scan(strict=True)
        hits = list(hits) + list(future_timestamps()) + list(tool_cross_checks())
        got = set(h[2] for h in hits if h[0] == os.path.basename(probe))
    finally:
        globals()['assertion_count'] = old_ac
        if os.path.exists(probe):
            os.remove(probe)
    missing = [kind for kind, _ in cases if kind not in got]

    # ★★★ 第 7 项（**源码次序契约**）：上面那条「顺序」不能只靠注释宣称 ——
    #   静态检查本文件自己的源码次序：合并行必须出现在提前返回之前。
    #   ★ 这是**行为级**判据（查源码位置关系），不是「有没有写过某句话」。
    #   ⚠️ 为什么必须单独查：self_check 直调 `future_timestamps()`，
    #     **绕过了 main 里的合并** ⇒ 即使合并被挪到提前返回之后，
    #     前 6 项自检依然全绿（它们不经过 main）。**这正是我踩过的那个坑。**
    src = io.open(os.path.abspath(__file__), encoding='utf-8').read()
    # ★★★ 只在 **main() 的函数体**里找 —— 第一版在整个文件里 find，
    #   结果命中的是**本函数自己的源码**（它里面也写着这两个字符串！）
    #   ⇒ 检查了一个跟自己无关的位置，永远「成立」。
    #   这是**自指陷阱**：检查器把自己当成了被检查对象。
    #   抓法：把 main 里的合并挪到提前返回之后，检查**照样绿** —— 反向测试暴露的。
    #
    #   ⚠️⚠️ **本条尚未通过反向测试（如实标注）**：
    #     我试了两次注入换位，检查都**没有报错**；诊断显示注入脚本本身没把两段
    #     放到我预期的位置（探针打印的索引与理论值对不上）。
    #     ⇒ 换句话说：**我没能构造出一个能证伪它的输入**。
    #     按本工程规矩，**未通过反向测试的检查不得当成「有效」** ⇒
    #     它现在的定位是「**尽力而为的辅助检查**」，不是保证。
    #     真正的保证仍靠：① 合并处的哨兵注释 + audit_fixes 的特征串（那条验证过会响）；
    #                    ② 需要时**人工**把合并挪后跑一次，看是否报错。
    # ★★★ 这里**故意不写完整字面量**（用拼接构造）。
    #   原因：今天**三次**（T44 / T55 各一次、外加一次探测）在给本文件插新函数时，
    #   `src.replace("def main():", 新函数 + "def main():", 1)` 命中的**不是 main 的定义**，
    #   而是**这一行里的字符串** —— 于是整个文件被插坏。
    #   ⇒ 把字面量拆开，让本文件里**不再存在**那个完整串：
    #     别人（包括我自己以后）按子串替换时，命中的就只可能是真正的定义处。
    # ★★★ 用**行首锚定**找定义，而不是 `src.find('def main():')`。
    #   为什么必须这样：我第一版改完拼接以后，`find` 命中的是**本函数上方那段
    #   解释这个 bug 的注释**（注释里恰好引用了 `def main():` 这个串）
    #   ⇒ main_src 从一个注释处开始，偏移全错，判据**误报违约**。
    #   ★ 这正是「锚点必须行首锚定」那条教训的**机械形式**：
    #     要找「定义处」，就得用「行首 + 定义语法」去找，不能按子串找。
    import re as _re
    _m = _re.search(r'^def main\(\):', src, _re.M)
    main_src = src[_m.start():] if _m else ''
    # ★★★ 还要**去掉注释行**再找 —— 否则又会命中「解释这个 bug 的那段注释」
    #   （注释里写着 `if not hits: return`，而它出现在真正的提前返回**之前**）
    #   ⇒ 偏移全错、判据误报违约。
    #   ★ 这已经是**第三次**同一形态了（T44 插入插进字符串、T55 插入插进字符串、
    #     本条判据命中解释性注释）——根因都是**「按子串找」而不问「这段文本是什么身份」**。
    #     所以这里不只是修一次，而是**在判据自身上贯彻「只看代码」**。
    _code = []
    for _ln in main_src.split('\n'):
        _st = _ln.lstrip()
        if _st.startswith('#'):
            continue
        _code.append(_re.sub(r'#.*$', '', _ln))
    code_src = '\n'.join(_code)
    i_merge = code_src.find('in future_timestamps():')
    i_bail = code_src.find('if not hits:')
    # ★★★ 三件事都要查，「两个都在」不能省：
    #   写这条时我只写了 `i_merge < i_bail` ⇒ **把合并整段删掉**时
    #   `i_merge == -1`，而 `-1 < i_bail` 恒真 ⇒ **判据照样通过**。
    #   是写反向测试（删掉合并行）时才发现的 —— 「缺了东西」和「顺序对了」
    #   在 `find` 的返回值里都长得像「没问题」。
    if i_merge == -1 or i_bail == -1 or not (i_merge < i_bail):
        _why = []
        if i_merge == -1:
            _why.append('找不到合并行')
        if i_bail == -1:
            _why.append('找不到提前返回')
        if i_merge != -1 and i_bail != -1 and i_merge > i_bail:
            _why.append('合并被挪到了提前返回之后')
        missing.append('次序契约(%s)' % '；'.join(_why))
    return missing, sorted(got)




#=========================================================================
# ★★ 第 6 类：**工具输出交叉核对**（T34）
#=========================================================================
#   由来：报告 §41.6 的工具表里写着「scan_parameterized_factories.py ⇒ 90 命中」，
#   而那个 90 是**工具第一版判据错**时算出来的，改正后是 **27** —— 文档里留了很久没人发现，
#   因为**这一类数字当时不在任何规则覆盖内**。
#
#   它的特点是「**工具自己就能回答**」⇒ 不必人工维护，直接跑一遍比对。
#   ★ 判据：文档里引用某个工具的产出数时，就用那个工具的**官方输出**核对。
MODULE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(MODULE)


def tool_cross_checks():
    import subprocess as _sp
    rule = re.compile(r'`tools/scan_parameterized_factories\.py`.*?\*\*(\d+)\s*命中\*\*')
    try:
        r = _sp.run([sys.executable,
                     os.path.join(ROOT, 'tools', 'scan_parameterized_factories.py'),
                     '--count'], capture_output=True, cwd=ROOT, timeout=120)
        real = (r.stdout + r.stderr).decode('utf-8', 'replace').strip()
    except Exception as e:
        return []
    if not real.isdigit():
        return []
    hits = []
    for fn in sorted(os.listdir(ROOT)):
        if not fn.endswith('.md'):
            continue
        lines = io.open(os.path.join(ROOT, fn), encoding='utf-8',
                        errors='replace').read().split('\n')
        for i, line in enumerate(lines):
            m = rule.search(line)
            if m and m.group(1) != real:
                hits.append((fn, i + 1, '工具输出不符', m.group(1) + ' 命中',
                             real + ' 命中（工具实测）', line.strip()[:96]))
    return hits


# ★★ 第 7 类：**类别名与文档同步**（T44）
#=========================================================================
#   代码里 `Boundaries.CLASS` 有 8 个类别名，报告 §41.8 / §43.3 里有分类表。
#   两边是**同源但不联动**的：改了代码里的名字，报告不会跟着变；
#   报告里漏掉一个正在使用的类别，读者就以为「只有这几类」。
#
#   判据（静态，不跑 Lua）：
#     ① 从 `26_boundaries.lua` 的 CLASS 表抽出 KEY → 名字；
#     ② 数同文件里 `CLASS.KEY` 的**引用次数**（被用到的才要求出现在报告里）；
#     ③ 被用到的类别，其名字必须出现在 `世界可跑可看报告.md` 里。
#   ⚠️ 这**不检查数量**（数量会随抽样变），只检查「有没有提到」——
#      后者是**结构一致性**，不该随运行结果变。
def class_doc_consistency():
    src_path = os.path.join(ROOT, 'host', '26_boundaries.lua')
    rep_path = os.path.join(ROOT, '世界可跑可看报告.md')
    if not (os.path.exists(src_path) and os.path.exists(rep_path)):
        return []
    src = io.open(src_path, encoding='utf-8', errors='replace').read()
    rep = io.open(rep_path, encoding='utf-8', errors='replace').read()
    # 只取 CLASS = { ... } 这一段
    try:
        i = src.index('CLASS = {')
        j = src.index('\n}', i)
    except ValueError:
        return []
    body = src[i:j]
    pairs = re.findall(r'(\w+)\s*=\s*"([^"]+)"', body)
    return _class_doc_hits(pairs, rep, src)


def _class_doc_hits(pairs, rep, src):
    """可测内核：给定 (KEY, 名字) 列表与报告文本，返回未同步的那些。
    ★ 抽出来是为了能**喂合成输入做反向测试** —— 否则这条结构性规则
      没法自证「真的会响」。"""
    hits = []
    for key, name in pairs:
        refs = len(re.findall(r'CLASS\.' + key + r'\b', src))
        if refs == 0:
            continue                      # 没被用到的类别，不要求出现在报告里
        if name not in rep:
            hits.append(('世界可跑可看报告.md', 0, '类别名未同步',
                         name, '代码里被用到 %d 次，报告里没提到' % refs,
                         'CLASS.%s' % key))

    # ★★★ T49 / T50：§46 的**表格**与 CLASS 表做**双向**逐项核对
    #   —— 这是最强的一版：不只看「有没有提到」，还看
    #      「表格里有没有代码里没有的」+「代码里有没有表格里没有的」+「名字是否一致」。
    #   （T49 = 反向；T50 = 正向 + 名字一致性）
    rows = dict(re.findall(r'^\| `CLASS\.(\w+)` \| \*\*(.+?)\*\* \|', rep, re.M))
    if rows:
        code_map = {k: v for k, v in pairs if k != 'UNDETERMINED'}
        # T49 反向：表格里不能有代码里没有的名字
        for k, v in rows.items():
            if k not in code_map:
                hits.append(('世界可跑可看报告.md', 0, '表格多出条目',
                             '§46 有 CLASS.%s' % k, '代码的 CLASS 表里没有这个键',
                             'CLASS.%s' % k))
        # T50 正向 + 名字一致
        for k, v in code_map.items():
            if k not in rows:
                hits.append(('世界可跑可看报告.md', 0, '表格缺条目',
                             '(§46 缺 CLASS.%s)' % k, '代码里有这个键', 'CLASS.%s' % k))
            elif rows[k] != v:
                hits.append(('世界可跑可看报告.md', 0, '表格名字不一致',
                             '§46 写的是「%s」' % rows[k], '代码里是「%s」' % v,
                             'CLASS.%s' % k))

    # ★★ T47：报告里的**数量**也要对得上（原来只查「有没有提到」）。
    #   §46 写着「共 **8** 个」—— 那个 8 是**代码生成的**，但生成过 ≠ 现在还对。
    n_code = len([k for k, _ in pairs if k != 'UNDETERMINED'])
    m = re.search(r'共 \*\*(\d+)\*\* 个', rep)
    if m and int(m.group(1)) != n_code:
        hits.append(('世界可跑可看报告.md', 0, '类别数量不符',
                     '报告称 %s 个' % m.group(1),
                     '代码里是 %d 个' % n_code,
                     '§46 的「共 N 个」'))
    return hits


# ★★ 第 8 类：入口**实际印出**的类别名清单 vs §46（T55）
#=========================================================================
#   为什么还要这一条：T50 比的是「**代码静态表** ↔ 文档」，
#   而入口输出（T46 那两行）是**运行期**产物 —— 它可能因为加载顺序、
#   `Boundaries.CLASS` 被覆盖等原因与静态表**不一致**。
#   三者（代码 / 运行输出 / 文档）应当**两两一致**；现在补上「运行输出」这一环。
def entry_class_list():
    import subprocess as _sp
    lua = os.path.join(ROOT, 'reachability.lua')
    if not os.path.exists(lua):
        return []
    env = dict(os.environ)
    env['REACH_N'] = '20'          # 只为一句话，取最小样本
    try:
        r = _sp.run([sys.executable, os.path.join(ROOT, '..', '03-参考架构', '_run_lua.py'),
                     '5.1', os.path.abspath(lua)],
                    capture_output=True, cwd=ROOT, env=env, timeout=300)
    except Exception:
        return []
    t = (r.stdout + r.stderr).decode('utf-8', 'replace')
    m = re.search(r'类别名定义\s*:\s*(\d+) 个', t)
    line = None
    for ln in t.split('\n'):
        if '=' in ln and ' ｜ ' in ln and 'CLASS' not in ln:
            line = ln.strip()
            break
    if not line:
        return []
    entry = dict()
    for part in line.split(' ｜ '):
        if '=' in part:
            k, v = part.split('=', 1)
            entry[k.strip()] = v.strip()
    rep = io.open(os.path.join(ROOT, '世界可跑可看报告.md'),
                  encoding='utf-8', errors='replace').read()
    rows = dict(re.findall(r'^\| `CLASS\.(\w+)` \| \*\*(.+?)\*\* \|', rep, re.M))
    hits = []
    for k, v in entry.items():
        if k not in rows:
            hits.append(('reachability.lua 输出', 0, '入口有而 §46 无', k, '表格里没有这个键', k))
        elif rows[k] != v:
            hits.append(('reachability.lua 输出', 0, '入口与 §46 名字不一致',
                         '%s=%s' % (k, v), '§46 写的是「%s」' % rows[k], k))
    for k in rows:
        if k not in entry:
            hits.append(('reachability.lua 输出', 0, '§46 有而入口无',
                         k, '入口没有印出这个键', k))
    return hits


def main():
    strict = '--strict' in sys.argv
    # ★★ T54：先查硬编码集合本身
    cp = config_problems()
    if cp:
        print('  ✘ 配置自检不过：')
        for c in cp:
            print('      · %s' % c)
        return 2

    # ★ 先自检：5 条合成违规必须条条被抓。少一条说明**规则被绕过了**。
    missing, got = self_check()
    if missing:
        print('  ✘ 规则自检不过 —— 以下规则**没有响**（可能已被绕过或删掉）：%s'
              % ', '.join(missing))
        print('    已响的：%s' % ', '.join(got))
        return 2
    hits, gt, (na, nf) = scan(strict)
    print('  文档数字审计  ——  扫描目录下全部 .md')
    print('  规则自检：✔ 6 条合成违规全部命中 + 源码次序契约成立')
    # 第 7 类的自检：把「代码里用到的类别」临时改成不可能匹配的名字，
    # 看它是否会报 —— 这是对**该类规则本身**的反向测试。
    # ★ 第 7 类的**反向测试**：喂一个「报告里肯定没有」的类别名，
    #   它必须报；再喂一个「报告里肯定有」的，它必须不报。
    _fake = _class_doc_hits([('FAKEKEY', '__绝不可能存在的类别名__')],
                            io.open(os.path.join(ROOT, '世界可跑可看报告.md'),
                                    encoding='utf-8', errors='replace').read(),
                            'CLASS.FAKEKEY CLASS.FAKEKEY')
    # ⚠️ 判据用「**有没有那条该有的命中**」而不是「命中总数 == 1」：
    #   一开始写成 `len(_fake) != 1`，T47 给同一函数加了一条「数量不符」判据后，
    #   函数在自检场景下会**多返回一条**（假的 pairs 只有 1 项，与报告里的 8 不符）
    #   ⇒ 自检误报「判据是死的」。
    #   ★ 这其实是**自检起作用了** —— 它抓到了「函数的输出契约变了」。
    #     但断言写法要**针对目标命中**，不能用总数（总数会随着加判据而变）。
    if not any('绝不可能存在的类别名' in str(h[3]) for h in _fake):
        print('  ✘ 第 7 类规则**没响**（喂了假类别名却没报）—— 判据是死的')
        return 2
    print('  ' + '─' * 74)
    print('  真值：播放器 %.1f MB ｜ 入口 %d 个 ｜ 断言 %s 条（失败 %s）'
          % (gt.get('player_mb', float('nan')), gt['entries'], na, nf))
    print('  入口清单：%s' % ', '.join(gt['entry_names']))
    print('  ' + '─' * 74)
    # ★★★ 顺序很重要：第 5 条规则（未来时间戳）必须**并入 hits 之后**再判断空。
    #   第一版我把这段放在了 `if not hits: return` **后面** ⇒
    #   只要其它 4 条规则没命中（正常情况），函数就提前返回了，
    #   **这条规则从来没被执行过**。
    #   抓到它的是**反向测试**：故意注入一个「2026-10-15 21:30 生成时间」
    #   （比当时晚 3 小时），工具却报「✔ 没有发现过期的数字」。
    #   ⇒ 又一个「检查写好了但从来没生效」——和影子闸门那次是**同一类**。
    # ★★ 顺序契约（防死代码）：以下两处合并**必须在** `if not hits` 之前。
    #   第一版写在了它后面 ⇒ 只要其它规则没命中就提前 return，这两条**从未执行过**。
    #   抓法：注入一个未来时间戳做反向测试（干净状态是看不出来的）。
    #   ⇒ audit_fixes 的特征串指向**这条注释**（描述行为），
    #     而不是指向成功语文本 —— 后者一改措辞就断，今天就断过一次。
    for fn, ln, kind, found, real, ctx in future_timestamps():
        hits.append((fn, ln, kind, found, real, ctx))
    for fn, ln, kind, found, real, ctx in tool_cross_checks():
        hits.append((fn, ln, kind, found, real, ctx))
    for fn, ln, kind, found, real, ctx in class_doc_consistency():
        hits.append((fn, ln, kind, found, real, ctx))
    for fn, ln, kind, found, real, ctx in entry_class_list():
        hits.append((fn, ln, kind, found, real, ctx))
    if not hits:
        print('  ✔ 没有发现过期的数字 / 未来时间戳 / 模糊时间戳 / 工具输出不符')
        return 0
    cur = None
    for fn, ln, kind, found, real, ctx in hits:
        if fn != cur:
            print('\n  【%s】' % fn)
            cur = fn
        print('    :%-5d %-8s 文中「%s」→ 实跑「%s」' % (ln, kind, found, real))
        print('            %s' % ctx)
    print('\n  共 %d 处待判定（历史节 41~44 / 8 / 16 / 17 / 26 里的旧值**故意保留**）'
          % len(hits))
    print('  ★ 本工具不自动改：判据（当前状态 vs 历史引用）得由人下。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
