#!/usr/bin/env node
/**
 * build-tradescreen.mjs —— tradescreen.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-tradescreen.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-tradescreen.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("screens/tradescreen.lua");
const SPEC = join(__dirname, "spec-tradescreen.mjs");
const OUT = relOut("screens/tradescreen.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：screens/tradescreen.lua",
  "-- 模块：界面 / 皮肤商店（爪机换肤，screen 名 \"TradeScreen\"）",
  "-- 职责：玩家把皮肤放进机器 → 点交易 → 机器吞掉 → 请求物品服务器 → 吐出结果。",
  "--       全流程跨越 5 个屏幕（本体 + 5 个小鸟小游戏屏 + 若干弹窗），",
  "--       靠六个布尔标志驱动一个「动画名即状态」的异步状态机。",
  "--       核心抽象是 ItemsInUse：把「已放入格子」与「正在飞向格子」",
  "--       合并成一张真实占用表，杜绝快速连点导致的重复占用。",
  "-- 关键符号：DoInitState（六个状态标志）, Reset / FinishReset（请求-完成对）, ",
  "--           Trade / FinishTrade / GiveItem, ",
  "--           StartAddSelectedItem / AddSelectedItem（两阶段提交）, ",
  "--           RemoveSelectedItem, ItemsInUse（占用合并视图）, ",
  "--           IsTradeAllowed（交易可行性判定）, RefreshUIState（唯一渲染入口）, ",
  "--           RefreshMachineTilesState（派生状态全量重算）, ",
  "--           StartFlushTiles / FlushTilesUpdate（程序化吐物动画）, ",
  "--           ResetFrameTiles（格子网格布局）, OnUpdate（状态机 tick）, ",
  "--           Quit（最完整的清理路径）, GetHelpText（与 OnControl 严格对应）",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：screens/skinsscreen.lua（唯一调用方，传参见本文件 92 行注释）、",
  "--           widgets/itemselector.lua（物品列表，内部用 TrueScrollList）、",
  "--           widgets/skincollector.lua（老板 NPC 的四种状态）, ",
  "--           widgets/truescrolllist.lua（列表的滚动与 ResetScroll）、",
  "--           widgets/mousetracker.lua（摇杆拖拽）, ",
  "--           skinsfiltersutils / skinstradeutils（副作用型 require，注入全局函数）、",
  "--           frontend.lua（PushScreen / FadeToScreen / FadeBack 演出编排）、",
  "--           uianim 组件（补间动画；1212 行直接改其 pos_t 中止补间）、",
  "--           screens/crowgamescreen 等 5 个小游戏屏（FadeToScreen 切换）",
  "--============================================================",
  "",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (t !== "" && !t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
  // 防编码损坏：U+FFFD 说明写入时字符被截断，必须修好再生成
  if (line.includes("\uFFFD")) {
    throw new Error(`规格错误 @${where}: 含 U+FFFD 替换字符（编码损坏）-> ${line}`);
  }
  // ★ 防块注释定界符出现在注释正文里（会提前闭合源文件已开启的长注释块）
  if (/\-\-\[\[/.test(line)) {
    throw new Error(`规格错误 @${where}: 含块注释开定界符 -> ${line}`);
  }
  if (/\]\]/.test(line)) {
    throw new Error(`规格错误 @${where}: 含块注释闭定界符 -> ${line}`);
  }
  // ★ 防反斜杠转义：工具链可能把某些转义当真回车，把一行劈成两行
  if (line.includes("\\")) {
    throw new Error(`规格错误 @${where}: 含反斜杠 -> ${line}`);
  }
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const mod = await import(specUrl);
  const AFTER = mod.default; // { 行号: [注释行...] }

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split(/\r?\n/);
  // 去掉末尾空行造成的额外元素，保持行号与源文件一致
  if (srcLines.length && srcLines[srcLines.length - 1] === "") srcLines.pop();

  const out = [HEADER.replace(/\n$/, "")];

  let injected = 0;
  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    out.push(srcLines[i]); // ← 代码行永远原样取自源文件
    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `AFTER[${lineno}]`);
        out.push(c);
        injected++;
      }
    }
  }

  // 报告规格里是否有「行号不存在」的锚点
  const missing = [];
  for (const key of Object.keys(AFTER)) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) {
    throw new Error(`规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = out.join("\n");
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, text, "utf8");

  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  let cov = 0;
  for (const k of Object.keys(AFTER)) {
    const n = Number(k);
    if (n >= 1 && n <= srcLines.length) cov++;
  }

  console.log(`✔ 已生成: ${OUT}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(
    `  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`
  );
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷⚠      : ${warn}`);
  console.log(
    `  保护标记在前10行: ${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】")) ? "是" : "否"
    }`
  );
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});
