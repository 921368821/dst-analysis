#!/usr/bin/env node
/**
 * build-statusdisplays.mjs —— statusdisplays.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-templates.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-statusdisplays.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-statusdisplays.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("widgets/statusdisplays.lua");
const SPEC = join(__dirname, "spec-statusdisplays.mjs");
const OUT = relOut("widgets/statusdisplays.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：widgets/statusdisplays.lua",
  "-- 模块：UI 系统 / 玩家状态条总装配器（StatusDisplays）",
  "-- 职责：装配并编排十余个状态徽章（理智/生命/饥饿/狼形态/潮湿度/船/宠物血量/",
  "--       宠物饥饿/复仇幽灵/激励/壮力/护盾），把服务端下发的 delta 事件映射为",
  "--       数值更新与红绿脉冲音效反馈；管理玩家形态与灵魂形态之间的",
  "--       事件订阅/解绑、复活按钮（塑像/墓碑）的延迟合并判定与碎裂动画、",
  "--       分屏镜像列布局、以及各类可选徽章的条件添加与空守卫。",
  "--       ★ 本文件是「装配器」而非绘制控件：真正的绘制在各 badge.lua 中。",
  "-- 关键符号：StatusDisplays, OnSetPlayerMode, OnSetGhostMode,",
  "--           OnFinishSeamlessPlayerSwap, UpdateRezButton_Enable,",
  "--           UpdateRezButton_Disable, SetGhostMode, AddWereness, RemoveWereness,",
  "--           SetWereMode, AddInspiration, AddMightiness, AddPetHunger,",
  "--           SetupWobyPetHunger, SetHealthPercent, HealthDelta, ForceHealthPulse,",
  "--           SetHungerPercent, HungerDelta, SetSanityPercent, SanityDelta,",
  "--           SetWerenessPercent, SetInspiration, SetMightiness, MightinessDelta,",
  "--           SetMoisturePercent, SetWxShieldPercent, EnableResurrect,",
  "--           RefreshPetHealth, RefreshHealthBuff, RefreshAvengingGhost,",
  "--           RefreshPetSkin, ShowStatusNumbers, HideStatusNumbers",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：class.lua（Class 继承）, widgets/widget.lua（UpdateWhilePaused 语义）、",
  "--           widgets/sanitybadge.lua、widgets/healthbadge.lua、widgets/hungerbadge.lua、",
  "--           widgets/werebadge.lua、widgets/moisturemeter.lua、widgets/boatmeter.lua、",
  "--           widgets/pethealthbadge.lua、widgets/pethungerbadge.lua、",
  "--           widgets/avengingghostbadge.lua、widgets/inspirationbadge.lua、",
  "--           widgets/mightybadge.lua、widgets/resurrectbutton.lua、",
  "--           widgets/uianim.lua（animover 自动隐藏）、prefabs/wobycommon.lua（FLAGBITS）、",
  "--           widgets/inventorybar.lua（另两处 delta/解绑范式的对照实现）",
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
  // 防长注释截断：注释正文里若出现长注释定界符，会提前闭合源码里
  // 已存在的 --[[ ]] 块，导致后续代码行被当成注释/语法错误。
  // 只允许整行恰为 '--[[' 或 '--]]' 这两个定界行本身。
  if (t !== "--[[" && t !== "--]]" && (t.includes("--[[") || t.includes("]]"))) {
    throw new Error(
      `规格错误 @${where}: 注释正文含长注释定界符，会截断源码块注释 -> ${line}`
    );
  }
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const mod = await import(specUrl);
  const AFTER = mod.default; // { 行号: [注释行...] }

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split(/\r?\n/);
  expandKeysInPlace(AFTER, srcLines, "AFTER");
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