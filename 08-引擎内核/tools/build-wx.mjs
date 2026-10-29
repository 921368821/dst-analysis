/**
 * 小游戏产物构建（esbuild · IIFE 单文件）
 *
 * 用法：
 *   node tools/build-wx.mjs [--out <dir>] [--minify]
 *
 * 产物 `<dir>/game.js` 就是包里的入口脚本。**不 minify 是默认**：
 * ① `tools/pack.ts --strict-api` 报的是**行号**，压缩之后那行号对不上源码，
 *    人照着跳过去只会看到一坨；
 * ② 压缩会改字符串拼接方式，而"这个产物里到底有没有 document."正是这条闸门要回答的。
 *    要证伪它，两边的输入得是同一种东西。
 *
 * ★ `format: "iife"` 而不是 `"esm"`：小游戏的启动脚本是**普通脚本**（`game.js`
 *   由运行时直接执行），没有模块加载器。ESM 产物在真机上会报 `Unexpected token 'export'`，
 *   而模拟器里不一定复现 —— 这类"只有真机才炸"的差异正是能提前消掉就消掉的那种。
 *
 * ★ `platform: "neutral"`：引擎内核里不该有 node 内置模块依赖。设成 `node` 会让
 *   esbuild 悄悄把 `node:path` 之类留成外部引用，产物在真机上才炸；设成 `neutral`
 *   则**构建期**就报"没解析"，问题立刻暴露。
 */

import { mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { build } from "esbuild";

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return fallback;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith("--") ? fallback : v;
}

const outDir = resolve(arg("out", "web/wx"));
const outfile = join(outDir, "game.js");
const minify = process.argv.includes("--minify");

if (!existsSync(dirname(outfile))) mkdirSync(dirname(outfile), { recursive: true });

const r = await build({
  entryPoints: ["src/wx-boot.ts"],
  bundle: true,
  format: "iife",
  globalName: "EngineWx",
  target: "es2020",
  platform: "neutral",
  outfile,
  minify,
  sourcemap: false,
  logLevel: "warning",
  // 产物里要留着可读的注释性字符串（见文件头第 ② 条），所以不设 legalComments
  legalComments: "inline",
});

if (r.errors.length > 0) {
  console.error(`✗ 构建失败：${String(r.errors.length)} 个错误`);
  process.exit(1);
}
console.log(`✓ 已写出 ${outfile}`);
