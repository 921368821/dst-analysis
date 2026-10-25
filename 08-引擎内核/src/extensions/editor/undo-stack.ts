/**
 * L4 · 编辑器：撤销栈
 *
 * `ADR-0004` 说「结构性修改走命令队列」，并顺手给了两个理由：
 * 命令**可记录** ⇒ 可重放、可撤销、可确定性。这一层就是那个承诺的兑现处。
 * 但注意它**不是**把 `SceneCommand` 直接当历史条目用 —— `SceneCommand` 里装着
 * `Node` / `Component` 对象和一个 `run` 回调，那三样都不能反向执行。
 * 历史条目得是**自带反向操作**的东西（`EditorOp`），见 `undo-ops.ts`。
 *
 * 这一层只管「历史怎么记、怎么走回去」，不认识 `Scene`、不碰 DOM。
 * 于是它能在 Node 里被逐条钉住，而页面只负责把 `history()` 画成按钮。
 *
 * ★ 六条容易写错、每条对应一条判据：
 *
 * ① **`push` 必须清空重做侧**。人在撤销两步之后又做了一次新操作，
 *    原来那两条重做就再也到不了 —— 留着它们的话按重做会跳到
 *    「另一个分支」的状态，而按钮上写的是旧标题。
 *
 * ② **撤销失败不许弹栈**。弹出去了但状态没退，等于「这条历史被吃掉了」：
 *    人再按一次撤销退的是更早那步，中间那步的改动永久留在场景里。
 *
 * ③ **`apply`/`revert` 期间不许再进栈、不许再撤销**。反向操作自己调 `undo()`
 *    会让栈在遍历中途被改 —— 这正是 ADR-0004 要解决的问题，只是换了个地方。
 *
 * ④ **批量是一个原子条目**。多选删 5 个节点 ⇒ 撤销**一次**五个都回来。
 *    批量内部的反向顺序必须与施加顺序**相反**（后面那条可能依赖前面那条，
 *    比如先建父节点再建子节点）；批量中途失败要能 `rollbackBatch()`，
 *    把已经做掉的那几条退回去 —— 否则会留下「删了一半且没有历史可退」的世界。
 *
 * ⑤ **上限只限撤销侧，且丢弃要能说出来**。丢掉的是最老的历史；
 *    人按了 200 次撤销之后按钮变灰，「更早的丢了」和「一开始就没有」
 *    在 UI 上长得一样，在数据上不是一回事。
 *
 * ⑥ **旁路操作不许被记进历史**（`runWithoutRecording`）。读档、PIE 回灌这类
 *    操作会大改场景，但它们不该变成一条可撤销的「历史」——
 *    否则一次读档之后，撤销会把世界混在「半个存档 + 半个编辑」之间。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 撤销栈重入（反向操作里又调了撤销 / 又压了栈）。 */
export const UNDO_BUSY = "UNDO.BUSY";
/** 历史条目自身反向执行失败（由条目返回，栈负责原样上报）。 */
export const UNDO_OP_FAILED = "UNDO.OP_FAILED";

/**
 * 一条可撤销的编辑器操作。
 *
 * `apply` **不是**「首次执行」——首次执行由调用方自己做（它得先拿到
 * `before` 才能构造 op）。`apply` 只用于 **redo**。
 */
export interface EditorOp {
  /** 给人看的标题（「改 sprite.zIndex」）。UI 直接显示它。 */
  readonly label: string;
  /** 前向：把效果做出来（重做用）。 */
  apply(): Result<void, EngineError>;
  /** 反向：撤销。 */
  revert(): Result<void, EngineError>;
}

/** `undo()` / `redo()` 的结果。`empty` 与 `failed` 必须分开 —— UI 上长得一样，含义完全不同。 */
export type UndoOutcome =
  | { readonly kind: "empty" }
  | { readonly kind: "done"; readonly label: string }
  | { readonly kind: "failed"; readonly label: string; readonly error: EngineError };

export interface UndoStackOptions {
  /** 撤销侧最多保留多少条（默认 200）。超出丢**最老的**。 */
  readonly limit?: number;
}

export interface UndoHistory {
  /** 撤销侧标题，**最近的在前**（`[0]` 就是下一次撤销会退掉的那条）。 */
  readonly undo: readonly string[];
  /** 重做侧标题，**下一次重做能重做的那条在前**。 */
  readonly redo: readonly string[];
  /** 因为 `limit` 被丢掉的历史条数（> 0 时 UI 该说「更早的历史已丢弃」）。 */
  readonly dropped: number;
}

const DEFAULT_LIMIT = 200;

/**
 * 一组操作合成**一个**历史条目。
 *
 * ★ 反向必须**倒序**：批量里的顺序是「父先子后」这类依赖序，
 *   正序撤销会去动一个已经被前面那条删掉的节点。
 */
export class BatchOp implements EditorOp {
  readonly label: string;
  readonly ops: readonly EditorOp[];

  // ★ 不用构造函数参数属性（`constructor(readonly ...)`）：本项目直接用
  //   Node 跑 `.ts`，strip-only 模式下参数属性会直接抛
  //   `ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX`。全仓统一显式声明 + 显式赋值。
  constructor(label: string, ops: readonly EditorOp[]) {
    this.label = label;
    this.ops = ops;
  }

  apply(): Result<void, EngineError> {
    for (const o of this.ops) {
      const r = o.apply();
      if (!r.ok) return r;
    }
    return ok(undefined);
  }

  revert(): Result<void, EngineError> {
    for (let i = this.ops.length - 1; i >= 0; i--) {
      const r = this.ops[i]!.revert();
      if (!r.ok) return r;
    }
    return ok(undefined);
  }
}

export class UndoStack {
  /** 尾部 = 栈顶 = 下一次撤销的那条。 */
  private readonly done: EditorOp[] = [];
  /** 尾部 = 下一次重做的那条。 */
  private redoSide: EditorOp[] = [];
  private readonly limit: number;
  private droppedCount = 0;
  /** 反向操作进行中（防止重入）。 */
  private busy = false;
  /** `runWithoutRecording` 的嵌套层数。 */
  private muted = 0;
  /** 正在累积的批量（`null` = 不在批量里）。 */
  private batch: { label: string; ops: EditorOp[] } | null = null;

  constructor(opts: UndoStackOptions = {}) {
    const l = opts.limit ?? DEFAULT_LIMIT;
    // 0 或负数会让栈永远存不下东西，而且不报错 —— 直接夹到 1
    this.limit = Number.isFinite(l) && l >= 1 ? Math.floor(l) : 1;
  }

  get canUndo(): boolean {
    return this.done.length > 0;
  }

  get canRedo(): boolean {
    return this.redoSide.length > 0;
  }

  /** 撤销侧深度（不含重做侧）。 */
  get depth(): number {
    return this.done.length;
  }

  get droppedTotal(): number {
    return this.droppedCount;
  }

  /** 是否正在攒批量（UI 可以在批量期间把撤销按钮置灰）。 */
  get inBatch(): boolean {
    return this.batch !== null;
  }

  /** 下一次撤销会退掉哪一条（没有则 `null`）。 */
  get nextUndoLabel(): string | null {
    const t = this.done[this.done.length - 1];
    return t === undefined ? null : t.label;
  }

  get nextRedoLabel(): string | null {
    const t = this.redoSide[this.redoSide.length - 1];
    return t === undefined ? null : t.label;
  }

  /** 压一条**已经生效**的操作。批量进行中则进批量，不直接进历史。 */
  push(op: EditorOp): Result<void, EngineError> {
    if (this.busy) {
      return err(engineError(UNDO_BUSY, `正在执行「${op.label}」的反向操作，不能同时压栈`));
    }
    if (this.muted > 0) return ok(undefined);
    if (this.batch !== null) {
      this.batch.ops.push(op);
      return ok(undefined);
    }
    this.done.push(op);
    this.redoSide = [];
    // 超限丢最老的。★ 只丢撤销侧：重做侧此时刚被清空
    while (this.done.length > this.limit) {
      this.done.shift();
      this.droppedCount++;
    }
    return ok(undefined);
  }

  /** 开始一个批量。不嵌套（批量里再开批量会让「谁是原子的」变得说不清）。 */
  beginBatch(label: string): Result<void, EngineError> {
    if (this.busy) return err(engineError(UNDO_BUSY, "正在执行反向操作，不能开始批量"));
    if (this.batch !== null) {
      return err(engineError(UNDO_BUSY, `已在批量「${this.batch.label}」里，不支持嵌套`));
    }
    this.batch = { label, ops: [] };
    return ok(undefined);
  }

  /**
   * 结束批量：先把已收集的操作合成**一个**条目压进历史。
   *
   * 一条都没收集到时**不产生空历史**（返回 `pushed: false`）——
   * 「删了 0 个」不该在历史里留一行让人按了没反应的记录。
   */
  commitBatch(): Result<{ pushed: boolean; count: number }, EngineError> {
    const b = this.batch;
    if (b === null) return err(engineError(UNDO_BUSY, "当前没有进行中的批量"));
    this.batch = null;
    if (b.ops.length === 0) return ok({ pushed: false, count: 0 });
    const r = this.push(new BatchOp(b.label, b.ops));
    return r.ok ? ok({ pushed: true, count: b.ops.length }) : r;
  }

  /**
   * 丢弃批量并**反向执行已经做掉的那几条**（倒序）。
   *
   * 用在「批量中途出错」：前 3 个删掉了、第 4 个失败 ⇒ 把前 3 个退回去，
   * 世界回到批量之前，历史里不留任何痕迹。
   */
  rollbackBatch(): UndoOutcome {
    const b = this.batch;
    if (b === null) return { kind: "empty" };
    this.batch = null;
    if (b.ops.length === 0) return { kind: "empty" };
    this.busy = true;
    try {
      for (let i = b.ops.length - 1; i >= 0; i--) {
        const op = b.ops[i]!;
        const r = op.revert();
        if (!r.ok) return { kind: "failed", label: op.label, error: r.error };
      }
    } finally {
      this.busy = false;
    }
    return { kind: "done", label: `回滚「${b.label}」（${String(b.ops.length)} 条）` };
  }

  /** 撤销一步。失败时**栈不动**（见文件头 ②）。 */
  undo(): UndoOutcome {
    if (this.busy) return this.busyOutcome();
    const op = this.done[this.done.length - 1];
    if (op === undefined) return { kind: "empty" };
    const r = this.runBusy(() => op.revert());
    if (!r.ok) return { kind: "failed", label: op.label, error: r.error };
    this.done.pop();
    this.redoSide.push(op);
    return { kind: "done", label: op.label };
  }

  /** 重做一步。失败时**栈不动**。 */
  redo(): UndoOutcome {
    if (this.busy) return this.busyOutcome();
    const op = this.redoSide[this.redoSide.length - 1];
    if (op === undefined) return { kind: "empty" };
    const r = this.runBusy(() => op.apply());
    if (!r.ok) return { kind: "failed", label: op.label, error: r.error };
    this.redoSide.pop();
    this.done.push(op);
    return { kind: "done", label: op.label };
  }

  /**
   * 丢弃全部历史（切换场景 / 读档之后必须调）。
   *
   * ★ 读档后不能留着历史：条目里记着 `nodeId` 与旧值，而读档把所有节点都换了
   *   —— 撤销一条「改 zIndex」会写到别人的节点上。
   */
  clear(): void {
    this.done.length = 0;
    this.redoSide.length = 0;
    this.droppedCount = 0;
    this.batch = null;
  }

  /** 历史快照（给 UI 的历史列表 / 判据用；内部数组不外泄）。 */
  history(): UndoHistory {
    const undo = this.done.map((o) => o.label).reverse();
    // ★ 重做侧也要**反转**：内部数组的尾部才是「下一次重做」的那条，
    //   不反转的话 UI 上排在第一位的那行按下去会重做错的那一步。
    const redo = this.redoSide.map((o) => o.label).reverse();
    return { undo, redo, dropped: this.droppedCount };
  }

  /**
   * 在**不被记录**的情况下跑一段（读档、PIE 回灌、初始化装配）。
   *
   * 注意它只挡「压栈」，不挡撤销 —— 所以别在里面调 `undo()`。
   * 嵌套调用叠加层数，`finally` 里减回来，中途抛错也不会让栈永久静音。
   */
  runWithoutRecording<T>(fn: () => T): T {
    this.muted++;
    try {
      return fn();
    } finally {
      this.muted--;
    }
  }

  private runBusy(fn: () => Result<void, EngineError>): Result<void, EngineError> {
    this.busy = true;
    try {
      return fn();
    } finally {
      this.busy = false;
    }
  }

  private busyOutcome(): UndoOutcome {
    return {
      kind: "failed",
      label: "（重入）",
      error: engineError(UNDO_BUSY, "正在执行另一条历史的反向操作，不能再进入一次"),
    };
  }
}

export function createUndoStack(opts?: UndoStackOptions): UndoStack {
  return new UndoStack(opts);
}
