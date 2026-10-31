/**
 * 工具层类型声明：`tools/determinism-scan.mjs` 供判据直接使用。
 *
 * 为什么需要这一份：`tests/tools/determinism-scan.test.ts` 要**直接调** `scan`
 * 往合成语料上打一发（不是 spawn 一个子进程 —— 那只能看到退出码，看不到
 * 「为什么红」）。tsconfig 是 strict 且没有 `allowJs`，所以 `.mjs` 必须配
 * 一份 `.d.mts`（与 `blockers-check` / `gap-check` 同一口径）。
 *
 * ★ 声明要**够紧**：规则表与白名单在这里是**参数**而不是模块内部状态，
 *   测试才能造「规则失效」「陈旧白名单」这些仓库里不会自然出现的世界。
 */

/** 一条扫描规则。 */
export interface DeterminismRule {
  readonly id: string;
  /** 必须是**带 `g` 标志**的正则（`scan` 会自己重置 `lastIndex`）。 */
  readonly pattern: RegExp;
  /** 今天仓库里应命中的处数（含白名单命中的）。与实测不符时进 `stale`。 */
  readonly expect: number;
  readonly why: string;
  readonly fix: string;
}

/** 白名单条目：精确到「文件 × 规则」。 */
export interface DeterminismAllow {
  readonly file: string;
  readonly rule: string;
  readonly why: string;
}

/** 一处违规。 */
export interface DeterminismViolation {
  readonly path: string;
  /** 1-based 行号。 */
  readonly line: number;
  readonly rule: string;
  /** 那一行的原文（已 trim）。 */
  readonly text: string;
  readonly why: string;
  readonly fix: string;
}

/** 规则命中数与登记的 `expect` 不符。 */
export interface StaleRule {
  readonly id: string;
  readonly expect: number;
  readonly actual: number;
}

/**
 * 扫一遍。**纯函数**：不读盘、不看仓库现状 —— 语料由调用方给。
 *
 * ★ 整行注释（行首是 `//` / `*` / 块注释标记）里的提及**不计**：闸门守的是
 *   「会被执行的运算」，而文件头写「为什么不能用某函数」是正确的文档。
 *   代码行末尾的注释**不豁免**（行首是代码就照样判）。
 */
export function scan(
  files: readonly { path: string; text: string }[],
  rules?: readonly DeterminismRule[],
  allow?: readonly DeterminismAllow[],
): {
  violations: DeterminismViolation[];
  stale: StaleRule[];
  unusedAllow: DeterminismAllow[];
  hitsByRule: Map<string, number>;
  lines: number;
  files: number;
};

/** 递归收集目录下的 `.ts`（相对仓库根的 POSIX 路径）。 */
export function collect(dir: string, out?: string[]): string[];

/**
 * 入口：返回退出码（0 干净 / 1 有违规 / 2 扫描器自身失效）。
 *
 * 直接运行时不返回 —— 入口守卫里 `process.exit(main())`。判据里 import 它
 * 不会触发执行，因为顶层有 `isEntry` 判断。
 */
export function main(argv?: readonly string[]): number;
