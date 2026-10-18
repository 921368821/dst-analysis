#!/usr/bin/env node
/**
 * build-useableitem.mjs —— useableitem.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-useableitem.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-useableitem.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/useableitem.lua";
const SPEC = join(__dirname, "spec-useableitem.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/components/useableitem.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/useableitem.lua",
  "-- 模块：组件系统 / 物品使用（UseableItem，无目标端）",
  "-- 职责：「按使用键」类物品的最小协议 —— 资格判定（CanInteract，依赖",
  "--       equippable 副本的已装备状态）、使用中状态（inuse 字段 + inuse 标签）、",
  "--       开始使用（StartUsingItem，回调可返回 false 否决）与停止使用",
  "--       （StopUsingItem）。",
  "-- 【协议四要素】① CanInteract ② StartUsingItem ③ inuse 状态（字段+标签）",
  "--       ④ StopUsingItem。物品交互统一抽象的最小充分集合。",
  "-- 【与 useabletargeteditem.lua 的关系】两个【平行】的独立实现，非继承：",
  "--       本文件无目标（手电筒、药水）；对方有目标（挤奶、喂食）。",
  "--       调度方分别是 actions.lua:3299-3309 与 actions.lua:3338-3350。",
  "-- 关键符号：UseableItem, CanInteract, StartUsingItem, StopUsingItem,",
  "--           SetOnUseFn, SetOnStopUseFn, inuse, onusefn, onstopusefn,",
  "--           stopuseevents",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/useabletargeteditem.lua（有目标端，建议对照阅读）,",
  "--           components/toggleableitem.lua（同类协议的另一个平行实现）,",
  "--           components/equippable.lua 与 inventoryitem_replica（IsEquipped 判定源）,",
  "--           actions.lua（USEITEM / STOPUSINGITEM 动作层调度）,",
  "--           componentutil.lua（makeuseable 之类的批量挂载辅助）",
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
