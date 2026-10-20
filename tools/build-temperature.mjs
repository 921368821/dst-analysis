#!/usr/bin/env node
/**
 * build-temperature.mjs —— temperature.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-temperature.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-temperature.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/temperature.lua");
const SPEC = join(__dirname, "spec-temperature.mjs");
const OUT = relOut("components/temperature.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/temperature.lua",
  "-- 模块：组件系统 / 体温（Temperature）",
  "-- 职责：把「环境温度 + 各类修正项」合成为实体当前体感温度，按「速率 x 时间」",
  "--       逐帧积分逼近目标；跨过 0 度或过热阈值时向 health.lua 输送持续伤害。",
  "--       与 health/sanity/hunger 的分工：本组件只负责「算出该变成多少度」，",
  "--       血量变动一律由 health.lua 的 DoDelta 承接（cause = cold / hot）。",
  "-- 关键符号：Temperature, OnUpdate（★核心，第 311 行）, SetTemperature（唯一写入口）,",
  "--           DoDelta, GetInsulation（★六层保暖合成）, GetMoisturePenalty,",
  "--           SetModifier, RemoveModifier, SetInsulationModifier, IsFreezing,",
  "--           IsOverheating, SetTemp（温度钉死开关）, SetTemperatureInBelly,",
  "--           TransferComponent, ClearBellyTemperature, oncurrent, onsheltered",
  "-- ★设计提炼（详见正文中标注 ★★★ 的行）：",
  "--   1) 保暖不改变目标温度，只封顶「速率」——第 367 行目标公式里没有保暖项；",
  "--   2) 保暖只挡「变坏」的方向，对「变好」方向完全无效——第 487-506 行；",
  "--   3) 跨阈值后自动加速回温/解暑（THAW = WARM x 5）——第 496、505 行；",
  "--   4) 伤害只取决于「是否越线」，与偏离幅度脱钩，故不会瞬间冻死——第 519 行；",
  "--   5) 双层值域夹取：局部（冰箱/口袋）先夹，固有 [-20, 90] 后夹——第 514 行。",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/heater.lua（热源接口 heater.lua 第 89 行）,",
  "--           components/insulator.lua（冬/夏保暖类型）,",
  "--           components/moisture.lua（第 293 行反向读 externalheaterpower）,",
  "--           components/preserver.lua（温度变化速率倍率）,",
  "--           components/beard.lua（胡须：加冬保暖、减夏保暖）,",
  "--           components/sheltered.lua（遮蔽等级）, components/health.lua",
  "--           （第 613 行 DoDelta、第 616-621 行 nonlethal_* 非致死保护）,",
  "--           util/sourcemodifierlist.lua（保暖修正器容器）,",
  "--           tuning.lua（STARTING_TEMP=35 / OVERHEAT_TEMP=70 / SEG_TIME=30）,",
  "--           prefabs/player_common.lua（第 2744 行唯一设 usespawnlight 的实体）",
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