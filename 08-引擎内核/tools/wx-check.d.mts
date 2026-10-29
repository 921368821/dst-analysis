/**
 * 工具层类型声明：`tools/wx-check.mjs` 供测试直接使用。
 *
 * 为什么需要这一份：它是**工具**（不是 `src/` 里的模块），而
 * `tests/host/wx-bundle.test.ts` 要逐条打它的判定规则。tsconfig 是 strict 且没有
 * `allowJs`，所以 `.mjs` 必须配一份 `.d.mts` 声明（与 `png-encode` / `blockers-check` 同口径）。
 *
 * ★ 只声明**纯函数**那一半。`wx-check.mjs` 的 CLI 部分（spawn 构建与打包）不该被测试
 *   import —— 那会变成"import 一下就构建两次"。声明里没有它，import 了也编译不过。
 */

/** 产物体积下限（字节）。低于它就认为构建成了空壳。 */
export const MIN_BUNDLE_BYTES: number;

/**
 * 检查小游戏产物。
 *
 * @param source 产物的 UTF-8 文本（`game.js` 的内容）
 * @returns 问题列表；**空数组 = 通过**
 */
export function checkWxBundle(source: string): string[];
