/**
 * 工具层类型声明：`tools/browser-kit.mjs` 供测试直接使用。
 *
 * 为什么需要这一份：`browser-kit.mjs` 是**工具**（不是 src 里的模块），
 * 而 `tests/tools/browser-kit.test.ts` 要直接验证它 —— `killTree` 有没有真的
 * 杀掉整棵进程树，只有起真实进程才能证明。tsconfig 是 strict 且没有 `allowJs`，
 * 所以 `.mjs` 必须配一份 `.d.mts` 声明（与 `png-encode.d.mts` 同一口径）。
 *
 * ★ 这里只声明**测试用到的那几个**，不追求覆盖整个工具：
 *   声明写宽了会让人以为"这工具保证这些签名"，而工具随时可以改。
 */

import type { ChildProcess } from "node:child_process";

/**
 * 起浏览器进程。
 *
 * ★ POSIX 上给独立进程组（`detached`），`killTree` 的 `process.kill(-pid)`
 *   才打得到 —— 否则只杀主进程，Chrome 的 zygote / renderer 会整棵留下，
 *   一轮变异校验起二十几次浏览器后把机器拖慢（2026-10-25 批75 的真因之一）。
 */
export function spawnBrowser(browser: string, args: readonly string[]): ChildProcess;

/** 杀掉整棵进程树（Windows 走 `taskkill /T`，POSIX 走进程组）。 */
export function killTree(child: ChildProcess): void;
