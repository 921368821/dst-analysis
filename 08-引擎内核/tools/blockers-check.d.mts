/**
 * 工具层类型声明：`tools/blockers-check.mjs` 供测试直接使用。
 *
 * 为什么需要这一份：它和 `gap-check.mjs` 一样是**工具**（不是 src 里的模块），
 * 而 `tests/tools/blockers-check.test.ts` 要直接验证它的规则。tsconfig 是 strict
 * 且没有 `allowJs`，所以 `.mjs` 必须配一份 `.d.mts` 声明（同一口径）。
 *
 * ★ 声明要**够紧**：`docs-check.mjs` 是普通 node 脚本，不会替这里守约定 ——
 *   尤其是注入的 `exists` / `readText`，它们让测试可以造"哪些文件存在、内容是什么"的世界。
 */

/** 受控状态词表。顺序有意义：`✅` 是唯一需要给证据的那一类。 */
export const BLOCKER_MARKERS: readonly string[];

/** 清单文件名形如 `BLOCKERS-2026-10-27.md` ⇒ 按名字排序取最新的一份；没有则 `null`。 */
export function pickBlockersDoc(names: readonly string[]): string | null;

/** 清单里的一条数据行（首格是 `A1` / `B2` / `C11` 这种编号）。 */
export interface BlockerRow {
  /** 原文行号（1-based）。 */
  readonly no: number;
  /** 编号（首格）。 */
  readonly id: string;
  /** 切开的单元格（已 trim）。 */
  readonly cells: string[];
  /** 原文（已 trim）。 */
  readonly text: string;
  /** 是否以 `|` 结尾 —— 单元格有没有跨行。 */
  readonly singleLine: boolean;
}

export function blockerRows(docText: string): BlockerRow[];

/** 数据行数（给 `docs-check` 打印用：0 行 = 判据没在扫）。 */
export function blockerRowCount(docText: string): number;

/** 一条对不上的行。`code` 取 `ROW_MULTILINE` / `DUP_ID` / `BAD_STATUS` / `DEAD_PATH` / `NO_EVIDENCE` / `UNVERIFIED`。 */
export interface BlockerIssue {
  readonly no: number;
  readonly id: string;
  readonly code: string;
  readonly detail: string;
}

export function findBlockerIssues(p: {
  docText: string;
  exists: (rel: string) => boolean;
  readText: (rel: string) => string;
}): BlockerIssue[];
