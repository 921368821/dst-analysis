/**
 * 小游戏启动脚本（esbuild 的入口，产物就是包里的 `game.js`）
 *
 * 单独一个文件而不是在 `wx-entry.ts` 里 `void main()`：那是**库**文件，
 * 判据要 import 它来调 `startWxGame` —— 模块顶层自动启动会让"import 一下"
 * 变成"又开了一局"，而那种症状（判据里多出一堆节点、计时器乱跳）很难归因。
 */

import { main } from "./wx-entry.ts";

void main();
