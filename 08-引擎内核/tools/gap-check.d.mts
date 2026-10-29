/**
 * 工具层类型声明：`tools/gap-check.mjs` 供测试直接使用。
 *
 * 为什么需要这一份：`gap-check.mjs` 是**工具**（不是 src 里的模块），
 * 而 `tests/tools/gap-check.test.ts` 要直接验证它的规则（判据在 `docs-check` 里叫
 * "缺口清单对账"）。tsconfig 是 strict 且没有 `allowJs`，所以 `.mjs` 必须配一份
 * `.d.mts` 声明（与 `browser-kit.d.mts` / `png-encode.d.mts` 同一口径）。
 *
 * ★ 声明要**够紧**：`docs-check.mjs` 是普通 node 脚本，不会替这里守约定，
 *   所以参数全部显式（尤其是注入的 `exists`，它让测试可以造"文件存在与否"的世界）。
 */

/** §六 的标题。改标题会让判据立刻报问题，而不是静默扫 0 行。 */
export const GAP_HEADING: string;

/** 一行缺口（带原文行号）。 */
export interface GapLine {
  readonly no: number;
  readonly text: string;
}

/** 取 §六 的正文行；**标题不见了返回 `null`**（不是空数组 —— 两者含义完全不同）。 */
export function gapSectionLines(docText: string): GapLine[] | null;

/** 一条过期缺口：首格没标已消除，却点名了已在 CI 里跑的工具。 */
export interface StaleGapRow {
  /** 原文行号（1-based）。 */
  readonly no: number;
  /** 首格原文（缺口名）。 */
  readonly head: string;
  /** 命中的工具路径（去重、保持出现顺序）。 */
  readonly hits: string[];
}

export function findStaleGapRows(p: {
  docText: string;
  exists: (rel: string) => boolean;
  ciText: string;
}): StaleGapRow[];

/** §六 里的缺口行数（给 `docs-check` 打印用：0 行 = 判据没在扫）。 */
export function gapRowCount(docText: string): number;

/**
 * 一条「仍缺」的毛病（批113）。
 *
 * `uncited` = 没挂阻断编号（没人被迫回来核对）；`stale` = 挂的那条已经 ✅（句子过期）。
 */
export interface UnresolvedClaim {
  /** 原文行号（1-based）。 */
  readonly no: number;
  readonly kind: "uncited" | "stale";
  /** 仅 `stale` 有：清单里已经是 ✅ 的编号。 */
  readonly ids?: string[];
}

/**
 * 一条「做完了却没关单」的缺口行（批131）。
 *
 * 与 `UnresolvedClaim` 分开两种类型而不是共用一个 `kind`：这两条规则的**输出**
 * 完全不同（一条是「还差什么没写清」，一条是「已经做完了还在数」），
 * 混成一个联合类型的话，`docs-check` 的 `problems` 分支只能靠 `kind` 猜着走。
 */
export interface ForgottenClosure {
  /** 原文行号（1-based）。 */
  readonly no: number;
  /** 首格原文（缺口名）。 */
  readonly head: string;
  readonly kind: "forgot-close";
}

/**
 * 扫「首格没划掉、行里却自称做完」的缺口行。
 *
 * **标题不见了返回 `null`**（同一口径：不静默扫 0 行）。
 */
export function findForgottenClosures(docText: string): ForgottenClosure[] | null;

/**
 * 扫出「没被划掉、却既没挂编号 / 挂的编号已 ✅」的「仍缺」。
 *
 * **标题不见了返回 `null`**（与 `gapSectionLines` 同一口径：不静默扫 0 行）。
 */
export function findUnresolvedClaims(docText: string, blockerText: string): UnresolvedClaim[] | null;

