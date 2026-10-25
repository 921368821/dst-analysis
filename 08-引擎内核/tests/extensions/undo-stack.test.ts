/**
 * L4 · 编辑器：撤销栈（纯模型，不认识 Scene）
 *
 * ★ 这一层的判据钉的是**历史本身**的六条不变量，而不是「按下撤销场景变回去了」：
 *   后者在 `editor-undo.test.ts` 里用真 Scene 验。分开写的理由是
 *   ——「栈的行为错了」和「某条操作反向执行错了」是两种完全不同的 bug，
 *     混在一起时一次失败要读半天才知道该改哪一层。
 *
 * ★ 反向操作在这里全部是**假的**（只往一个数组里记一行），
 *   于是「调了几次、什么顺序」可以被逐字比对 —— 真 Scene 反而说不了这么细。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { engineError, err, ok, type EngineError, type Result } from "../../src/foundation/result.ts";
import {
  BatchOp,
  UNDO_BUSY,
  UNDO_OP_FAILED,
  UndoStack,
  createUndoStack,
  type EditorOp,
} from "../../src/extensions/editor/undo-stack.ts";

/** 记一行日志的假操作。 `hooks` 让判据能在反向执行**中途**搞事情（重入、失败）。 */
function fakeOp(
  log: string[],
  name: string,
  hooks: {
    failRevert?: boolean;
    failApply?: boolean;
    onRevert?: () => void;
    onApply?: () => void;
  } = {},
): EditorOp {
  return {
    label: name,
    apply: (): Result<void, EngineError> => {
      log.push(`apply:${name}`);
      hooks.onApply?.();
      if (hooks.failApply === true) return err(engineError(UNDO_OP_FAILED, `${name} 前向失败`));
      return ok(undefined);
    },
    revert: (): Result<void, EngineError> => {
      log.push(`revert:${name}`);
      hooks.onRevert?.();
      if (hooks.failRevert === true) return err(engineError(UNDO_OP_FAILED, `${name} 反向失败`));
      return ok(undefined);
    },
  };
}

test("[撤销栈] 空栈：撤销与重做都返回 empty，且按钮该是灰的", () => {
  const s = createUndoStack();
  assert.equal(s.canUndo, false);
  assert.equal(s.canRedo, false);
  assert.deepEqual(s.undo(), { kind: "empty" }, "空栈撤销不是失败 —— UI 上两者含义完全不同");
  assert.deepEqual(s.redo(), { kind: "empty" });
  assert.equal(s.nextUndoLabel, null);
  assert.equal(s.nextRedoLabel, null);
});

test("[撤销栈] 撤销调用 revert、重做调用 apply，且各自搬到对面", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.push(fakeOp(log, "a"));
  assert.equal(s.depth, 1);
  assert.equal(s.nextUndoLabel, "a");

  const u = s.undo();
  assert.equal(u.kind, "done");
  assert.deepEqual(log, ["revert:a"], "撤销只该走反向，不该顺手再 apply 一次");
  assert.equal(s.depth, 0);
  assert.equal(s.canRedo, true);
  assert.equal(s.nextRedoLabel, "a");

  log.length = 0;
  const r = s.redo();
  assert.equal(r.kind, "done");
  assert.deepEqual(log, ["apply:a"]);
  assert.equal(s.depth, 1);
  assert.equal(s.canRedo, false);
});

test("[撤销栈] ★ 压新操作必须清空重做侧（否则重做会跳到另一个分支）", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.push(fakeOp(log, "a"));
  s.push(fakeOp(log, "b"));
  s.undo();
  assert.equal(s.canRedo, true, "前置条件：此时确实有一条可重做");

  s.push(fakeOp(log, "c"));
  assert.equal(s.canRedo, false, "做了 c 之后，被撤销的 b 再也到不了了 —— 留着会重做到错的状态");
  assert.equal(s.canRedo === false && s.nextRedoLabel === null, true);
  assert.deepEqual(
    s.history().undo,
    ["c", "a"],
    "历史应该是 c 在上、a 在下；b 既不在撤销侧也不在重做侧",
  );
});

test("[撤销栈] ★ 反向失败时栈不动（弹出去但状态没退 = 这条历史被吃掉）", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.push(fakeOp(log, "bad", { failRevert: true }));
  const out = s.undo();
  assert.equal(out.kind, "failed");
  assert.equal(out.kind === "failed" ? out.error.code : "", UNDO_OP_FAILED, "错误码要原样透传");
  assert.equal(s.depth, 1, "失败之后这条历史必须还在，否则改动永久留在场景里而历史里没有它");
  assert.equal(s.canRedo, false, "失败不该把条目搬到重做侧");
  assert.equal(s.nextUndoLabel, "bad", "下一次撤销还得是它");
});

test("[撤销栈] ★ 重做失败时重做侧不动", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.push(fakeOp(log, "bad", { failApply: true }));
  s.undo();
  assert.equal(s.canRedo, true, "前置条件：撤销成功了，重做侧有一条");
  const out = s.redo();
  assert.equal(out.kind, "failed");
  assert.equal(s.canRedo, true, "重做失败之后它还该在重做侧");
  assert.equal(s.depth, 0, "也不能因为一次失败就跑到撤销侧去");
});

test("[撤销栈] ★ 反向操作里不许再进一次（重入会被挡住）", () => {
  const log: string[] = [];
  const s = createUndoStack();
  let inner: ReturnType<UndoStack["undo"]> | null = null;
  let innerPush: string | null = null;
  s.push(
    fakeOp(log, "a", {
      onRevert: () => {
        inner = s.undo();
        const p = s.push(fakeOp(log, "sneaky"));
        innerPush = p.ok ? null : p.error.code;
      },
    }),
  );
  s.push(fakeOp(log, "b"));
  const out = s.undo(); // 撤销 b
  assert.equal(out.kind, "done");
  assert.equal(inner, null, "撤销 b 的过程中没有递归调用，这一位该还是 null");

  // 现在撤销 a：它的 revert 里会试着递归撤销 + 偷偷压栈
  log.length = 0;
  const out2 = s.undo();
  assert.equal(out2.kind, "done", "外层那次撤销本身要成功 —— 挡的是里层");
  assert.equal(inner !== null && (inner as { kind: string }).kind, "failed", "里层撤销必须被拒");
  assert.equal(innerPush, UNDO_BUSY, "里层压栈也必须被拒（否则历史会在遍历中途被改）");
  assert.deepEqual(
    log,
    ["revert:a"],
    "被拒的里层操作不该真的执行 —— 日志里只该有外层那一次",
  );
});

test("[撤销栈] 上限丢最老的，并把丢弃条数说出来", () => {
  const log: string[] = [];
  const s = createUndoStack({ limit: 2 });
  s.push(fakeOp(log, "a"));
  s.push(fakeOp(log, "b"));
  s.push(fakeOp(log, "c"));
  assert.equal(s.depth, 2);
  assert.equal(s.droppedTotal, 1, "丢掉的是最老的 a —— UI 才能解释「更早的历史没了」");
  assert.deepEqual(s.history().undo, ["c", "b"]);
  assert.equal(s.history().dropped, 1);
});

test("[撤销栈] limit 给 0 / 负数 / NaN 时夹到 1，而不是变成「永远存不下」", () => {
  for (const limit of [0, -5, Number.NaN]) {
    const s = createUndoStack({ limit });
    s.push(fakeOp([], "a"));
    assert.equal(s.depth, 1, `limit=${String(limit)} 时该夹到 1`);
  }
});

test("[撤销栈] clear() 连丢弃计数一起清（切场景之后不该还显示「已丢弃 3 条」）", () => {
  const s = createUndoStack({ limit: 1 });
  s.push(fakeOp([], "a"));
  s.push(fakeOp([], "b"));
  assert.equal(s.droppedTotal, 1, "前置条件：先真的丢过东西");
  s.clear();
  assert.equal(s.depth, 0);
  assert.equal(s.canRedo, false);
  assert.equal(s.droppedTotal, 0);
});

test("[撤销栈] ★ 旁路操作不进历史，且抛错之后不会把栈永久静音", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.runWithoutRecording(() => {
    s.push(fakeOp(log, "hidden"));
  });
  assert.equal(s.canUndo, false, "读档 / 回灌这类操作不该变成一条可撤销的历史");

  assert.throws(() => {
    s.runWithoutRecording(() => {
      throw new Error("模拟读档失败");
    });
  });
  s.push(fakeOp(log, "visible"));
  assert.equal(s.depth, 1, "抛错之后录制必须恢复 —— 否则之后所有编辑都不进历史，而按钮一直是灰的");
});

test("[撤销栈] 批量：一组操作合成一个原子条目，撤销一次全退", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.beginBatch("删除选中 3 个");
  s.push(fakeOp(log, "n1"));
  s.push(fakeOp(log, "n2"));
  s.push(fakeOp(log, "n3"));
  assert.equal(s.depth, 0, "批量期间不该往历史里塞半成品");
  assert.equal(s.inBatch, true);
  const c = s.commitBatch();
  assert.equal(c.ok && c.value.pushed, true);
  assert.equal(c.ok && c.value.count, 3);
  assert.equal(s.depth, 1, "三条历史合成了一个原子条目");
  assert.equal(s.nextUndoLabel, "删除选中 3 个");

  log.length = 0;
  s.undo();
  assert.deepEqual(log, ["revert:n3", "revert:n2", "revert:n1"], "撤销批量必须倒序");
});

test("[撤销栈] 批量重做按施加顺序（正序）", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.beginBatch("建树");
  s.push(fakeOp(log, "父"));
  s.push(fakeOp(log, "子"));
  s.commitBatch();
  s.undo();
  log.length = 0;
  s.redo();
  assert.deepEqual(log, ["apply:父", "apply:子"], "重做要按依赖序：父先于子");
});

test("[撤销栈] ★ 空批量不产生历史（按了没反应的一行最容易被当成 bug）", () => {
  const s = createUndoStack();
  s.beginBatch("删除选中 0 个");
  const c = s.commitBatch();
  assert.equal(c.ok && c.value.pushed, false);
  assert.equal(s.depth, 0);
  assert.equal(s.inBatch, false);
});

test("[撤销栈] ★ rollbackBatch 把已经做掉的倒序退回去，且历史里不留痕", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.push(fakeOp(log, "早先的正常操作"));
  s.beginBatch("删除选中 2 个");
  s.push(fakeOp(log, "x"));
  s.push(fakeOp(log, "y"));
  log.length = 0;
  const out = s.rollbackBatch();
  assert.equal(out.kind, "done");
  assert.deepEqual(log, ["revert:y", "revert:x"], "回滚也必须是倒序");
  assert.equal(s.depth, 1, "批量里的两条不该留下 —— 否则撤销栈里有一次「撤销」是什么都不做的");
  assert.equal(s.nextUndoLabel, "早先的正常操作");
  assert.equal(s.inBatch, false);
});

test("[撤销栈] ★ 回滚里有一条失败时停在它那里，并把错误报出来", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.beginBatch("批量");
  s.push(fakeOp(log, "ok1"));
  s.push(fakeOp(log, "bad", { failRevert: true }));
  log.length = 0;
  const out = s.rollbackBatch();
  assert.equal(out.kind, "failed");
  assert.deepEqual(log, ["revert:bad"], "失败那条之后的不该再执行（ok1 在它后面，轮不到）");
  assert.equal(s.inBatch, false, "回滚结束之后批量要关掉，否则后面所有 push 都进了一个没人 commit 的批量");
});

test("[撤销栈] 批量不许嵌套、不许在没有批量时 commit", () => {
  const s = createUndoStack();
  assert.equal(s.commitBatch().ok, false, "没有批量时 commit 要报错，不能静默成功");
  s.beginBatch("a");
  const nested = s.beginBatch("b");
  assert.equal(nested.ok, false);
  assert.equal(nested.ok ? "" : nested.error.code, UNDO_BUSY);
  s.commitBatch();
});

test("[撤销栈] 批量期间压栈遇到重入一样被拒（busy 优先于批量）", () => {
  const log: string[] = [];
  const s = createUndoStack();
  let code: string | null = null;
  s.push(
    fakeOp(log, "a", {
      onRevert: () => {
        // 反向执行中间开一个批量 —— 不该被允许，否则批量会跨过一次撤销
        const b = s.beginBatch("偷偷批量");
        code = b.ok ? null : b.error.code;
      },
    }),
  );
  s.undo();
  assert.equal(code, UNDO_BUSY);
});

test("[撤销栈] history() 的顺序是给人看的：撤销侧最近在前、重做侧下一次在前", () => {
  const log: string[] = [];
  const s = createUndoStack();
  s.push(fakeOp(log, "a"));
  s.push(fakeOp(log, "b"));
  s.push(fakeOp(log, "c"));
  s.undo();
  s.undo();
  assert.deepEqual(s.history().undo, ["a"], "撤销侧只剩 a");
  assert.deepEqual(s.history().redo, ["b", "c"], "下一次重做是 b，所以 b 在前");
  assert.equal(s.nextRedoLabel, "b");
});

test("[撤销栈] BatchOp 自己也是 EditorOp：空批量不炸、单条也对", () => {
  const log: string[] = [];
  const empty = new BatchOp("空", []);
  assert.equal(empty.apply().ok, true);
  assert.equal(empty.revert().ok, true);
  const one = new BatchOp("一", [fakeOp(log, "x")]);
  one.revert();
  assert.deepEqual(log, ["revert:x"]);
  assert.equal(one.label, "一");
});
