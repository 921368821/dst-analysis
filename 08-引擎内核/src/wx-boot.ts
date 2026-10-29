/**
 * 小游戏启动脚本（esbuild 的入口，产物就是包里的 `game.js`）
 *
 * 单独一个文件而不是在 `wx-entry.ts` 里 `void main()`：那是**库**文件，
 * 判据要 import 它来调 `startWxGame` —— 模块顶层自动启动会让"import 一下"
 * 变成"又开了一局"，而那种症状（判据里多出一堆节点、计时器乱跳）很难归因。
 *
 * ★ 这里的 `.catch` 只兜**一种**情况：`WX.NO_GLOBAL`（连 `wx` 都没有，于是连弹窗
 *   都没有）。`main` 内部已经把"装不起来"接住并弹窗了 —— 所以这里不能再报一次，
 *   否则同一次失败会有两条来源不同、措辞不同的记录。
 *   写成 `.catch` 而不是 `void`：真机上的未处理拒绝是没有观众的，
 *   而"启动脚本自己抛了、屏幕上什么都没有"正是这一批要消掉的那种状态。
 */

import { main } from "./wx-entry.ts";

void main().catch((e: unknown) => {
  console.error(e instanceof Error ? e.message : String(e));
});
