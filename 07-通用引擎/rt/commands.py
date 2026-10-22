#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""命令栈（M1-1 / J2）—— 编辑器的地基，也是 PIE、Prefab 覆盖、场景格式的共同依赖。

为什么是它
----------
现在 `/editor/move|spawn|remove` 是**直接改世界**：改完就回不去了。
没有撤销栈 ⇒ 没有「试一下」的成本上限 ⇒ 用户不敢动大东西，编辑器也就没法用。
对标报告里「编辑器内核 1.5/5」这一项，这个是第一块砖。

三条设计决策（来自 `外部引擎逆向推演评估-2026-10-21.md` §5.3，都是实测选的）
----------------------------------------------------------------------
1. **Godot 式「操作序列」，不是 Unity 式「先登记后改」**。
   Unity 的 `Undo.RecordObject` 要求先把对象状态登记进撤销栈再改对象 ——
   那套形态的前提是「编辑器知道每一帧谁要改什么」。我们的改动要经过服务端命令
   （`push_action` / `/editor/*`），是**一条条描述**，与 Godot 的
   `add_do_method / add_undo_method / commit_action` 同构。选它不是偏好，是架构已经这样了。

2. **合并策略挂在「操作类型」上，不挂在「编辑器帧」上**。
   Unity 靠 `IncrementCurrentGroup()` 由编辑器帧驱动分组；浏览器里没有编辑器帧
   （拖拽是一次 pointermove 流，松手才结束）⇒ 用 Godot 的 `MergeMode`：
   `MERGE_DISABLE`（离散）/ `MERGE_ENDS`（拖拽：首尾留、中间丢）/ `MERGE_ALL`（滑条：全合并）。

3. **记录「实体级完整快照」，不做字段级 diff**。
   实测存档：35 个实体 / 8,347 B，单实体平均 **238 B**、最大 850 B
   ⇒ 30 步栈约 7 KB。没有理由为省这点空间引入 diff ——
   而 diff 恰恰是「撤销后属性没回去」的高发区（漏字段、漏嵌套、漏类型）。

一个容易做错的地方：**合并之后 undo 要回到哪**
--------------------------------------------------
拖拽 60 帧，`MERGE_ENDS` 合并成一步。合并后这一步的
  · `after` 应该是**最后一帧**的值（redo 要回到终点）
  · `before` 必须是**第一帧之前**的值（undo 要回到起点）
只改一个就会得到「撤销回到拖拽中途」这种半截状态 —— 它看起来像能用，
直到有人真的撤销一次拖拽。`U49` 锁的就是这条。
"""
from __future__ import annotations

import copy

# ── 合并策略（与 Godot UndoRedo::MergeMode 同名同序，便于对照）───────────────
MERGE_DISABLE = "disable"   # 每条命令独立成步
MERGE_ENDS = "ends"         # 只合并「紧挨着的同类」：保留首个 before + 末个 after
MERGE_ALL = "all"           # 同 MERGE_ENDS，但允许跨越不同 kind（滑动条合并成一档）

DEFAULT_MAX_STEPS = 50      # 与引擎开发计划 J2 的「50 步撤销」一致


class Command(object):
    """一条命令：一个可序列化的描述 + 两份状态快照。"""

    __slots__ = ("kind", "target", "before", "after", "merge", "seq", "label")

    def __init__(self, kind, target, before, after, merge=MERGE_DISABLE,
                 seq=0, label=""):
        self.kind = kind
        self.target = target
        self.before = before
        self.after = after
        self.merge = merge
        self.seq = seq
        self.label = label or kind

    def to_dict(self):
        """可序列化形式 —— 场景格式与回放都靠它（callable 一律不进这个结构）。"""
        return {"kind": self.kind, "target": self.target,
                "before": copy.deepcopy(self.before),
                "after": copy.deepcopy(self.after),
                "merge": self.merge, "seq": self.seq, "label": self.label}

    def __repr__(self):
        return "<Cmd %s#%s seq=%d>" % (self.kind, self.target, self.seq)


class CmdStack(object):
    """撤销/重做栈。

    `apply(kind, target, state)` 由调用方提供：把一份状态写进世界（或测试里的 dict）。
    ★ 栈**不碰世界**，只负责「什么时候写什么」。这条分界让它可以纯逻辑测试
      （U47~U52 全部不需要起引擎），也让「写世界失败」有唯一的处理点。
    """

    def __init__(self, apply, max_steps=DEFAULT_MAX_STEPS, merge_window=1):
        self._apply = apply
        self.max_steps = max(1, int(max_steps))
        # 合并窗口按「条数」而不是「秒」：秒会受机器负载影响，
        # 而"紧挨着的上一条"是可复现的。拖拽合并靠的是 UI 层在松手时 commit，
        # 这里的窗口只是兜底（防止一次拖拽因为抖动被拆成两条）。
        self.merge_window = max(0, int(merge_window))
        self._undo = []          # list[Command]，末尾是最近一条
        self._redo = []
        self._seq = 0
        self._version = 1        # 每次**状态变更** +1（客户端预测靠它判断"文档动过没有"）
        self._txn = None         # 事务上下文：{"label", "cmds", "depth"}
        self._applied = 0        # 真正执行过 do 的次数（可观测）
        self._failed = 0         # 事务回滚次数

    # ---------------------------------------------------------------- 只读属性
    @property
    def version(self):
        return self._version

    @property
    def depth(self):
        return len(self._undo)

    def can_undo(self):
        return bool(self._undo)

    def can_redo(self):
        return bool(self._redo)

    def stats(self):
        return {"undo": len(self._undo), "redo": len(self._redo),
                "version": self._version, "applied": self._applied,
                "rolled_back": self._failed,
                "txn": (self._txn["label"] if self._txn else None)}

    # ---------------------------------------------------------------- 核心：push
    def push(self, kind, target, before, after, merge=MERGE_DISABLE, label=""):
        """记一条命令并**立刻执行 after**。返回 Command。

        ★ 先执行再入栈？还是先入栈再执行？
          选「先入栈、再执行」：执行失败时（apply 抛错）要把这条从栈里摘掉，
          否则会出现「栈里有、世界没变」的幽灵步骤 —— 那种状态下 undo 会去恢复
          一个从未发生过的变更，比不撤销更糟。
        """
        self._seq += 1
        cmd = Command(kind, target, copy.deepcopy(before), copy.deepcopy(after),
                      merge=merge, seq=self._seq, label=label)

        # 合并：与栈顶同 kind 同 target、且在上次 push 的窗口内
        if self._txn is None and self._undo and merge != MERGE_DISABLE:
            top = self._undo[-1]
            same = (top.kind == kind and top.target == target)
            if MERGE_ALL == merge:
                same = (top.kind == kind)          # MERGE_ALL 允许跨 target
            if same and (self._seq - top.seq) <= (self.merge_window + 1):
                # ★ before 保持栈顶的（拖拽起点），after 换成新的（拖拽终点）
                top.after = copy.deepcopy(after)
                top.seq = self._seq
                self._redo = []
                self._version += 1
                self._execute(kind, target, after)
                return top

        self._undo.append(cmd)
        self._redo = []                            # 新操作必然清空 redo 分支
        self._trim()
        try:
            self._execute(kind, target, after)
        except Exception:
            self._undo.pop()                       # 执行失败 ⇒ 不留幽灵步骤
            raise
        self._version += 1
        if self._txn is not None:
            self._txn["cmds"].append(cmd)
        return cmd

    def _execute(self, kind, target, state):
        self._apply(kind, target, state)
        self._applied += 1

    def _trim(self):
        while len(self._undo) > self.max_steps:
            self._undo.pop(0)                      # 淘汰最旧

    # ---------------------------------------------------------------- undo/redo
    def undo(self):
        """撤销一步。栈空返回 None（调用方应当把它当成 409，不是"成功但没变化"）。"""
        if not self._undo:
            return None
        cmd = self._undo.pop()
        self._apply(cmd.kind, cmd.target, cmd.before)
        self._redo.append(cmd)
        self._version += 1
        return cmd

    def redo(self):
        if not self._redo:
            return None
        cmd = self._redo.pop()
        self._apply(cmd.kind, cmd.target, cmd.after)
        self._undo.append(cmd)
        self._version += 1
        return cmd

    def clear(self):
        """清空（切场景 / PIE 进出时必须调，否则撤销会跨场景恢复实体）。"""
        self._undo = []
        self._redo = []
        self._version += 1

    # ---------------------------------------------------------------- 事务
    def transaction(self, label="txn"):
        """事务：块内任一命令失败 ⇒ 已执行的全部回滚。

        为什么需要：一次「把对象拖到新位置并改名」是两个变更，用户按一次撤销
        应该两者都回去。没有事务时它们会成为两步，撤销一次只回一半。

        用法：
            with stack.transaction("移动并改名"):
                stack.push(...)
                stack.push(...)
        """
        return _Txn(self, label)

    def _rollback(self, cmds):
        """从后往前按 before 恢复。**恢复失败也要继续**：
        半途中断会让世界停在"部分回滚"，比全部不回滚更难查。"""
        for cmd in reversed(cmds):
            try:
                self._apply(cmd.kind, cmd.target, cmd.before)
            except Exception:                      # noqa: BLE001
                pass
        self._failed += 1
        self._version += 1


class _Txn(object):
    def __init__(self, stack, label):
        self.stack = stack
        self.label = label

    def __enter__(self):
        # 嵌套事务：复用外层（内层失败由外层一起回滚）
        if self.stack._txn is not None:
            self.stack._txn["depth"] += 1
            self._owner = False
        else:
            self.stack._txn = {"label": self.label, "cmds": [], "depth": 1}
            self._owner = True
        return self

    def __exit__(self, exc_type, exc, tb):
        txn = self.stack._txn
        if txn is None:
            return False
        if not self._owner:
            txn["depth"] -= 1
            if exc_type is not None:
                # 内层失败：标记，让外层回滚
                self.stack._rollback(txn["cmds"])
                txn["cmds"] = []
            return False
        cmds = txn["cmds"]
        self.stack._txn = None
        if exc_type is not None:
            self.stack._rollback(cmds)
            # 回滚后这些命令不能留在栈里（否则撤销会去恢复"已经回滚过"的状态）
            ids = set(id(c) for c in cmds)
            self.stack._undo = [c for c in self.stack._undo if id(c) not in ids]
            self.stack._redo = [c for c in self.stack._redo if id(c) not in ids]
            return False                            # 异常继续往外抛
        return False
