#!/usr/bin/env node
/**
 * build-brains-braincommon.mjs —— braincommon.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-combat.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-brains-braincommon.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/brains/braincommon.lua";
const SPEC = join(__dirname, "spec-brains-braincommon.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/brains/braincommon.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：brains/braincommon.lua",
  "-- 模块：AI 大脑 / 公共底座（brains/ 下 191 个大脑共用）",
  "-- 职责：不是某只生物的大脑，而是【行为节点工厂库】。导出造子树的函数，",
  "--       把 behaviours/ 的原子节点组装成可复用的复合子树，供所有具体大脑调用。",
  "--       内容分五段：",
  "--         1) 盐渍跟随（FindSaltlick / AnchorToSaltlick）—— 缓存+失效校验范式",
  "--         2) 恐慌系列（PanicTrigger / PanicWhenScared）—— 惊吓时间轴与状态翻转记忆器",
  "--         3) 帮工策略表（AssistLeaderDefaults）—— Starter/KeepGoing/FindNew 三钩子",
  "--         4) 捡拾与交付（NodeAssistLeaderPickUps）—— 软锁互斥 + 两阶段优先级",
  "--         5) WX78 附身机甲（PossessChassisNode）",
  "-- 关键符号：AssistLeaderDefaults, NodeAssistLeaderDoAction,",
  "--           NodeAssistLeaderPickUps, PanicWhenScared, PanicTrigger,",
  "--           ShouldTriggerPanic, ElectricFencePanicTrigger, PossessChassisNode,",
  "--           AnchorToSaltlick, FindTillPosition",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：brain.lua（三段式大脑运行时机制，本文件是其节点层实现）,",
  "--           behaviours/（29 个原子决策节点，本文件的原料）,",
  "--           behaviours/chattynode.lua, behaviours/panic.lua, behaviours/leash.lua,",
  "--           components/follower.lua, components/trader.lua, components/eater.lua",
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