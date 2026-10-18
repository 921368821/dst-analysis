#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""safe_edit.py —— **改文件前先验锚点**的小工具（T57 / T60）

为什么需要它
============
今天**四次**把文件插坏，根因**完全相同**：

    s.replace("def main():", 新函数 + "def main():", 1)   ← 只认「第一次出现」
    s.replace("def main():", 新函数)                      ← 更糟：**替换了全部**

命中的**不是**定义，而是**别处字符串/注释里引用的同一个串**
（例如 self_check 里那行 `src.find('def main():')`，或本文档自身的说明文字）。
`str.replace` **不问这段文本是什么身份**。

它做什么
========
给定「文件 + 锚点」，报告锚点在各处的**身份**（代码 / 字符串 / 注释 / 行首），并判定：

  · 行首/代码里唯一      → ✅ 可以安全替换
  · 代码里出现多次        → ❌ 拒绝，并**给出可用的替代锚点**
  · 只在字符串/注释里      → ❌ 拒绝（很可能改错地方）
  · 代码里有、注释里也有   → ✅ 但**只按代码身份那一处**替换（不用 replace(...,1)）

用法
====
    python tools/safe_edit.py --file host/xx.lua --anchor "def main():"          # 只体检
    python tools/safe_edit.py --file host/xx.lua --anchor "..." --replace "..."  # 体检通过才改
    python tools/safe_edit.py --file f --anchor a1 --anchor a2                   # 批量体检
    python tools/safe_edit.py --file f --anchor ... --count 2                    # 要求恰好 2 处

退出码
======
    0 = 体检通过（并已替换，如果给了 --replace）
    2 = 体检不过（**不改动文件**）
"""
import argparse
import io
import os
import sys


def classify(text, anchor, is_md=False):
    """返回 [(行号, 身份, 该行摘要)]；身份 ∈ {line_start, code, string, comment}"""
    out = []
    start = 0
    while True:
        i = text.find(anchor, start)
        if i == -1:
            break
        start = i + 1
        ls = text.rfind('\n', 0, i) + 1
        le = text.find('\n', i)
        line = text[ls:le if le != -1 else len(text)]
        pre = line[:i - ls]
        stripped = line.lstrip()
        ln = text[:i].count('\n') + 1
        # ★★ `.md` 里的 `#` 是**标题（结构）**，不是注释 ——
        #   实测踩到：给 README/RESUME 加段时，`## 开工前先跑一遍…` 被判成
        #   「只出现在注释里」而**误拒**。文件类型不同，同一个符号的含义就不同。
        if (stripped.startswith('--') or '--' in pre
                or (not is_md and stripped.startswith('#'))):
            kind = 'comment'
        elif (pre.count('"') % 2 == 1) or (pre.count("'") % 2 == 1):
            kind = 'string'
        elif pre.strip() == '':
            kind = 'line_start'
        else:
            kind = 'code'
        out.append((ln, kind, line.strip()[:88]))
    return out


def suggest_anchors(text, code_occ, is_md=False):
    """T60：拒绝时**给出可用的替代锚点** —— 把「不行」变成「这样才行」。

    做法：从各代码出现处提取「**整行**」作为候选，逐个验证它在**代码身份**下是否唯一。
    为什么用整行：整行天然含「语句上下文」（如 `for k in pairs(x):`），
    比原来的短串更有区分度 —— 这正是「锚点要够长」的具体化。
    """
    lines = text.split('\n')
    cands = []
    if code_occ:
        # ★★ 窗口**逐级加大**：整行不够唯一时，试「本行+下一行」「+2 行」……
        #   实测踩到：5 处歧义全是**同一行文本**（`for name, rel, marker in CHECKS:`）
        #   ⇒ 只用整行做候选，5 个候选全都还是歧义的 ⇒ 报「无法自动给出」。
        #   而带上下一行就区分开了（后面跟的语句不同）。
        for win in (1, 2, 3):
            for ln, _kind, _ctx in code_occ:
                if 1 <= ln <= len(lines):
                    blk = '\n'.join(l.rstrip() for l in lines[ln - 1:ln - 1 + win]).strip()
                    if len(blk) > 3:
                        cands.append(blk)
    seen, uniq = set(), []
    for c in cands:
        if c in seen:
            continue
        seen.add(c)
        cl = [o for o in classify(text, c, is_md) if o[1] in ('code', 'line_start')]
        if len(cl) == 1:
            uniq.append(c)
    # ★ 优先给**短**的候选（1 行的排在前面）—— 越短越好改
    uniq.sort(key=lambda x: (x.count('\n'), len(x)))
    print('  ' + '─' * 62)
    if uniq:
        print('  💡 可用的替代锚点（**代码身份下唯一**，按整行取的）：')
        for c in uniq[:5]:
            print('      --anchor %r' % c)
    else:
        print('  💡 无法自动给出替代锚点。建议：')
        print('      · 把锚点取**更长**（连上一句/上一行一起），或')
        print('      · 先确认要改的到底是哪一处，再用**那一行的表达式**做锚点')


def check_one(text, anchor, want_count, verbose=True, is_md=False):
    """单锚点体检（供批量模式复用）；返回 (rc, code_like_hits)。"""
    occ = classify(text, anchor, is_md)
    if verbose:
        print('  锚点: %r' % anchor)
        print('  ' + '─' * 62)
    if not occ:
        if verbose:
            print('  ✘ 锚点一次都没出现 —— 先确认写对了')
        return 2, []
    if verbose:
        for ln, kind, ctx in occ:
            print('    行 %-5d [%-10s] %s' % (ln, kind, ctx))
    code_like = [o for o in occ if o[1] in ('code', 'line_start')]
    others = [o for o in occ if o[1] in ('string', 'comment')]
    if not code_like:
        if verbose:
            print('  ❌ 拒绝：锚点**只**出现在字符串/注释里')
            suggest_anchors(text, None, is_md)
        return 2, code_like
    if want_count is not None:
        if len(code_like) != want_count:
            if verbose:
                print('  ❌ 拒绝：代码身份出现 %d 次，要求 %d 次'
                      % (len(code_like), want_count))
                suggest_anchors(text, code_like, is_md)
            return 2, code_like
    elif len(code_like) > 1:
        if verbose:
            print('  ❌ 拒绝：锚点在**代码里出现 %d 次** —— 别赌「第一次」' % len(code_like))
            suggest_anchors(text, code_like, is_md)
        return 2, code_like
    if verbose:
        if others:
            print('  ✅ 可以替换，但注意：别处还以 %s 身份出现 %d 次'
                  % ('/'.join(sorted({o[1] for o in others})), len(others)))
        else:
            print('  ✅ 安全：代码里唯一，且无字符串/注释同名')
    return 0, code_like


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--file', required=True)
    ap.add_argument('--anchor', required=True, action='append',
                    help='可重复给多个锚点（批量模式）')
    ap.add_argument('--replace', default=None)
    ap.add_argument('--count', type=int, default=None,
                    help='要求代码身份的出现次数（默认：必须唯一）')
    a = ap.parse_args()

    path = a.file
    if not os.path.exists(path):
        print('  ✘ 文件不存在: %s' % path)
        return 2
    text = io.open(path, encoding='utf-8', errors='replace').read()
    # ★ 文件类型决定 `#` 的含义：`.md` 里是标题，代码文件里是注释
    is_md = path.lower().endswith(('.md', '.markdown'))

    # ★★ 批量模式：任一个不过 ⇒ 整体不过（且**不改动文件**）。
    if len(a.anchor) > 1:
        rc_all = 0
        for i, anch in enumerate(a.anchor, 1):
            print('\n【%d/%d】' % (i, len(a.anchor)))
            rc, _ = check_one(text, anch, a.count, is_md=is_md)
            if rc != 0:
                rc_all = rc
        print('\n  —— 批量体检结束：%s ——'
              % ('✔ 全部通过' if rc_all == 0 else '✘ 有不过的'))
        return rc_all

    anchor = a.anchor[0]
    rc, code_like = check_one(text, anchor, a.count, is_md=is_md)
    if rc != 0:
        return rc
    if a.replace is None:
        return 0

    # 只替换「代码身份」的那一处（按精确偏移，不用 replace(...,1)）
    lines = text.split('\n')
    target = None
    for ln, _kind, _ctx in code_like:
        ls = sum(len(l) + 1 for l in lines[:ln - 1])
        j = text.find(anchor, ls)
        if j != -1 and j < ls + len(lines[ln - 1]) + 1:
            target = j
            break
    if target is None:
        print('  ✘ 内部错误：定位代码身份那一处失败')
        return 2
    new_text = text[:target] + a.replace + text[target + len(anchor):]
    io.open(path, 'w', encoding='utf-8', newline='\n').write(new_text)
    print('  ✔ 已按**代码身份**那一处替换（未用 replace(...,1)）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
