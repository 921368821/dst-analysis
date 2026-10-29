/**
 * 工具层类型声明：`tools/dstsrc-report.mjs` 供判据直接使用。
 *
 * 为什么需要这一份：`tests/tools/dstsrc-report.test.ts` 要逐条打它的归类规则，而
 * tsconfig 是 strict 且没有 `allowJs` ⇒ `.mjs` 必须配 `.d.mts`
 * （与 `wx-check` / `blockers-check` / `gap-check` 同口径）。
 */

export type FailureShape =
  | "missing-module"
  | "missing-global-table"
  | "missing-global-value"
  | "missing-global-strict"
  | "script-local-nil"
  | "other";

export const SHAPES: readonly FailureShape[];

/** 加载顺序预设（`alpha` / `strict-first` / `boot-first`）。 */
export const ORDER_PRESETS: Readonly<Record<string, readonly string[]>>;

/** 按预设排加载顺序，返回新数组（不改入参）；未知预设抛错。 */
export function orderScripts(files: readonly string[], preset?: string): string[];

/** 取最内层那句并剥掉 `文件:行号:` 前缀。 */
export function innerMessage(message: string): string;

/** 判一条失败属于哪个形状；`name` 是"缺的那个东西"的名字（`other` 为空串）。 */
export function classifyFailure(message: string): { shape: FailureShape; name: string };

export interface GroupCount {
  readonly shape: FailureShape;
  readonly count: number;
}

export interface NamedCount {
  readonly name: string;
  /** 出现方式：`表` / `值` / `strict`。**只有 `missingGlobals` 有**，其余分组为空。 */
  readonly how?: string[];
  readonly count: number;
  /** 最多 3 个出现它的脚本名（便于人去翻）。 */
  readonly scripts: string[];
}

export interface TextCount {
  readonly text: string;
  readonly count: number;
  readonly scripts: string[];
}

export interface SweepSummary {
  readonly total: number;
  readonly groups: readonly GroupCount[];
  readonly missingGlobals: readonly NamedCount[];
  readonly missingModules: readonly NamedCount[];
  readonly localNils: readonly NamedCount[];
  readonly others: readonly TextCount[];
}

export function summarizeFailures(
  failures: readonly (readonly [string, string])[],
): SweepSummary;

/** 一个口径跑完时的一次「`_G` 里有没有这个名字」探测：值是 `type()` 的结果（`"nil"` 表示没有）。 */
export type GlobalProbe = Readonly<Record<string, string>>;

/**
 * 把「每个口径都缺」的名字劈成 `never`（跑完仍是 nil ⇒ 引擎欠的）与
 * `later`（跑完出现了 ⇒ 顺序/嵌套加载）。没探测到的名字进 `later`（不主张缺口）。
 */
export function splitNeverDefined(
  names: readonly string[],
  probes: readonly GlobalProbe[],
): { never: string[]; later: string[] };
