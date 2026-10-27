/**
 * L4 · 单行文本输入（**编辑模型**，不含任何 DOM）
 *
 * 光标、选区、IME 组合三件事看起来是"三个小功能"，实际是**同一个不变量的三个侧面**：
 * 「屏幕上看到的字符串」与「真正提交的字符串」必须能被分开描述。
 * 所以这一层只持有一个 `value`（已提交的值）和一份**未提交的**组合串，
 * 其余全部是派生量。
 *
 * ★★ 为什么组合中**不改** `value`：
 *   另一种常见写法是"边打边写进 value，同时记一个组合区间"。它的问题是回滚 ——
 *   玩家按 Esc 取消、切走窗口、点别处、浏览器崩掉组合，这四种情况都要把 value 恢复成
 *   组合前的样子，而"恢复"依赖那份被覆盖的内容还在。分开存就没有回滚这回事：
 *   取消 = 丢掉 `composing`，`value` 从头到尾没动过。
 *
 * ★ `compositionend` 带空串**不是提交**：
 *   Esc 取消时浏览器会发 `compositionend`（`data` 为空串）。把它当提交的话，
 *   "先选中一段字、再打拼音、再按 Esc"会**把选中的字删掉** —— 而玩家觉得自己什么都没做。
 *   所以 `commitComposition("")` 一律按取消处理，判据钉死。
 *
 * ★ 下标一律是**码点下标**（`Array.from` 的长度），不是 UTF-16 码元：
 *   用码元的话，在 emoji / 生僻字上按一次退格会留下半个代理对，
 *   屏幕上显示成 `�`，而 `value.length` 看起来"少了一个"。两者都很难查。
 *
 * ★ 这一层**没有时钟、没有事件订阅**：宿主把 DOM 事件翻译成这里的四个调用
 *   （`beginComposition` / `updateComposition` / `commitComposition` / `cancelComposition`），
 *   键盘编辑翻译成 `insert` / `deleteBackward` / `moveCaret` / `setSelection`。
 *   于是"组合中不提交"可以在 Node 里用几行断言证明，不用开浏览器打拼音。
 */

/** 选区范围（码点下标，左闭右开）。`start === end` 表示没有选区。 */
export interface CaretRange {
  readonly start: number;
  readonly end: number;
}

/** 一个码点里"是不是一个整体"：目前只区分代理对，够用且不引依赖。 */
export function codePointsLength(text: string): number {
  let n = 0;
  for (const _ of text) n++;
  return n;
}

/** 码点下标切片（越界自动夹到两端）。 */
export function sliceCodePoints(text: string, start: number, end: number): string {
  return Array.from(text).slice(start, end).join("");
}

export class TextInput {
  /** 已提交的值。**组合期间不变**（见文件头）。 */
  value = "";

  /** 光标（码点下标）。 */
  caret = 0;

  /** 选区锚点。`anchor === caret` 表示没有选区；否则选区是两者的闭区间外沿。 */
  anchor = 0;

  /**
   * 正在组合的串（`null` = 没在组合）。
   *
   * ★ 空串 `""` 也是合法状态：IME 一开始会先发一个空组合（比如刚按下键、还没出候选）。
   *   用 `null` 区分"没在组合"与"在组合但还没内容"—— 两者的 `isComposing` 都为真，
   *   但只有后者的"取消"是无声的（没东西可丢）。
   */
  composing: string | null = null;

  /** 组合替换的区间（码点下标，左闭右开）。组合开始时定下，组合期间不变。 */
  composeStart = 0;
  composeEnd = 0;

  /**
   * 组合开始那一刻的 `anchor` / `caret`（**保留方向**）。
   *
   * ★ 取消时必须**原样**放回去，而不是"放回替换区间起点"：
   *   选区是有方向的（`anchor` 是拖动时不动的那端），方向决定下一次 Shift+方向键
   *   往哪边扩。用归一化区间恢复会把"向右拖选"变成"向左拖选" ——
   *   屏幕上完全一样，手感不一样，而且没人报得出这算什么 bug。
   */
  private composeAnchor = 0;
  private composeCaret = 0;

  get isComposing(): boolean {
    return this.composing !== null;
  }

  /** 选区（左闭右开）。没有选区时 `start === end === caret`。 */
  get selection(): CaretRange {
    return { start: Math.min(this.anchor, this.caret), end: Math.max(this.anchor, this.caret) };
  }

  get hasSelection(): boolean {
    return this.anchor !== this.caret;
  }

  /** 选中的文本（码点下标切片）。 */
  get selectedText(): string {
    const s = this.selection;
    return sliceCodePoints(this.value, s.start, s.end);
  }

  /**
   * **屏幕上该显示的串**：组合中 = `value` 的 [0,composeStart) + 组合串 + [composeEnd,)。
   *
   * ★ 组合区间是 `[composeStart, composeEnd)` 而不是"插入点"：
   *   开始组合时若有选区，那一段是要被**替换**掉的。只记插入点的话，
   *   "选中三个字再打拼音"会显示成"三个字 + 拼音"，提交后却只剩拼音 —— 显示与结果不一致。
   */
  get display(): string {
    if (this.composing === null) return this.value;
    return (
      sliceCodePoints(this.value, 0, this.composeStart) + this.composing + sliceCodePoints(this.value, this.composeEnd, this.value.length)
    );
  }

  /**
   * 屏幕上的光标位置（码点下标，相对 `display`）。
   * ★ 组合中光标固定在组合串**末尾**：IME 自己会画候选框，引擎不该去猜候选里的位置。
   */
  get displayCaret(): number {
    if (this.composing === null) return this.caret;
    return this.composeStart + codePointsLength(this.composing);
  }

  // ---------------------------------------------------------------- 编辑

  /**
   * 插入文本（`overwriteSelection` 语义：有选区就先删）。
   *
   * ★ 组合中调用会**先提交**再插入：真实世界里的顺序是"compositionend → keydown"，
   *   宿主若把顺序弄反，至少结果还是对的，而不是把字符插到组合串中间去。
   */
  insert(text: string): void {
    if (text === "") return;
    if (this.composing !== null) this.commitComposition();
    const s = this.selection;
    const before = sliceCodePoints(this.value, 0, s.start);
    const after = sliceCodePoints(this.value, s.end, this.value.length);
    this.value = before + text + after;
    this.caret = s.start + codePointsLength(text);
    this.anchor = this.caret;
  }

  /** 退格：有选区删选区，否则删光标前一个码点。返回是否真的改了。 */
  deleteBackward(): boolean {
    if (this.composing !== null) this.commitComposition();
    const s = this.selection;
    if (s.start !== s.end) {
      this.value = sliceCodePoints(this.value, 0, s.start) + sliceCodePoints(this.value, s.end, this.value.length);
      this.caret = s.start;
      this.anchor = s.start;
      return true;
    }
    if (s.start === 0) return false;
    this.value = sliceCodePoints(this.value, 0, s.start - 1) + sliceCodePoints(this.value, s.start, this.value.length);
    this.caret = s.start - 1;
    this.anchor = this.caret;
    return true;
  }

  /** 前向删除（Delete 键）：有选区删选区，否则删光标后一个码点。 */
  deleteForward(): boolean {
    if (this.composing !== null) this.commitComposition();
    const s = this.selection;
    if (s.start !== s.end) return this.deleteBackward();
    const n = codePointsLength(this.value);
    if (s.start >= n) return false;
    this.value = sliceCodePoints(this.value, 0, s.start) + sliceCodePoints(this.value, s.start + 1, n);
    return true;
  }

  /** 移动光标。`extend` = 按住 Shift（拖动锚点，产生选区）。 */
  moveCaret(to: number, extend = false): void {
    const n = codePointsLength(this.value);
    // 组合中移动光标 = 放弃这次组合（DOM 里点别处也会先 compositionend）
    if (this.composing !== null) this.commitComposition();
    this.caret = Math.max(0, Math.min(n, Math.trunc(to)));
    if (!extend) this.anchor = this.caret;
  }

  setSelection(anchor: number, caret: number): void {
    const n = codePointsLength(this.value);
    this.anchor = Math.max(0, Math.min(n, Math.trunc(anchor)));
    this.caret = Math.max(0, Math.min(n, Math.trunc(caret)));
  }

  selectAll(): void {
    this.anchor = 0;
    this.caret = codePointsLength(this.value);
  }

  // ---------------------------------------------------------------- IME

  /**
   * 开始组合（`compositionstart`）。
   *
   * ★ 选区**不在这里删**：删了就回不去了（取消要复原）。这里只把"要替换的区间"记下来，
   *   组合期间屏幕上按替换后的样子显示，提交时才真正动 `value`。
   */
  beginComposition(): void {
    // 已经在组合：浏览器理论上不会连发两次 start，真发了就按"重新开始"处理，
    // 区间沿用上一次的起点（不重置，否则会把上一次的替换范围忘掉）
    if (this.composing !== null) {
      this.composing = "";
      return;
    }
    const s = this.selection;
    this.composeStart = s.start;
    this.composeEnd = s.end;
    this.composeCaret = this.caret;
    this.composeAnchor = this.anchor;
    this.composing = "";
  }

  /** 组合更新（`compositionupdate`，每次候选变化都会来一次）。 */
  updateComposition(text: string): void {
    if (this.composing === null) this.beginComposition();
    this.composing = text;
  }

  /**
   * 组合结束（`compositionend`）。
   *
   * ★★ 空串 = 取消，**不删**任何东西（见文件头）。这是这一层最容易做假的一条，
   *   判据 `[输入] 组合取消（compositionend 空串）不会删掉选中的内容` 钉着它。
   * ★ 提交后光标落在插入串之后，锚点同步 —— 否则下一次 Shift+方向键会选中"提交前"的旧区间。
   */
  commitComposition(text?: string): void {
    if (this.composing === null) {
      // 没在组合却收到提交：当成普通插入（有些输入法会省掉 start）
      if (text !== undefined && text !== "") this.insert(text);
      return;
    }
    const pending = text ?? this.composing;
    const start = this.composeStart;
    const end = this.composeEnd;
    this.composing = null;
    if (pending === "") {
      // 取消：`value` 从头到尾没动过，这里把光标与锚点也还回去 ——
      // 「取消」的字面意思就是**什么都没发生**，包括选区还在原处。
      this.caret = this.composeCaret;
      this.anchor = this.composeAnchor;
      return;
    }
    this.value = sliceCodePoints(this.value, 0, start) + pending + sliceCodePoints(this.value, end, this.value.length);
    this.caret = start + codePointsLength(pending);
    this.anchor = this.caret;
  }

  /** 取消组合（宿主在 Esc / 失焦时调；等价于 `commitComposition("")`）。 */
  cancelComposition(): void {
    if (this.composing === null) return;
    this.commitComposition("");
  }

  /** 存档/序列化用：只导出**已提交**的值（组合中的半成品不该进存档）。 */
  toJSON(): string {
    return this.value;
  }

  static from(value: string): TextInput {
    const t = new TextInput();
    t.value = value;
    t.caret = codePointsLength(value);
    t.anchor = t.caret;
    return t;
  }
}

// ---------------------------------------------------------------- 几何

/**
 * 光标位置**取自排版层**（`TextLayout.lineCaretX[行号]`），这一层不自己算。
 *
 * ★★ 曾经在这里实现过一个 `caretTableOf(font, text)`：按 `xadvance + 字距 + kerning`
 *   把每个码点的笔位置重新推一遍。它**能算对**，但那是第二份实现 ——
 *   `layoutText` 的绘制循环里已经有一份，两处只要有一处漏了 kerning 或字距，
 *   光标就会整体偏一点，而"偏一点"在纯 ASCII 上几乎看不出来。
 *   判据当场发现了这件事：空格不产生四边形，拿 `quads[i].x` 当第 i 格从第一个空格起就错位；
 *   顺着查下去才发现正确的位置只有排版本体知道，于是改成由 `layoutText` 顺手记下来。
 *
 * 所以这一层只留**纯算术**：给定一条笔位置表与一个区间，算出光标与选区的矩形。
 */

/** 第 `index` 个码点左边界的 x。越界夹到两端（末尾 = 整串宽度）。 */
export function caretXOf(table: readonly number[], index: number): number {
  if (table.length === 0) return 0;
  if (index <= 0) return table[0]!;
  if (index >= table.length - 1) return table[table.length - 1]!;
  return table[index]!;
}

/** 光标与选区在**一行**上的位置。 */
export interface InputGeometry {
  /** 光标竖条的左边缘（相对排版原点，px）。 */
  readonly caretX: number;
  /** 选区高亮：`null` = 没有选区。 */
  readonly selection: { readonly x: number; readonly w: number } | null;
}

export function inputGeometryOf(table: readonly number[], range: CaretRange): InputGeometry {
  const caretX = caretXOf(table, range.end);
  if (range.start === range.end) return { caretX, selection: null };
  const x0 = caretXOf(table, range.start);
  const x1 = caretXOf(table, range.end);
  return { caretX, selection: { x: Math.min(x0, x1), w: Math.abs(x1 - x0) } };
}
