#!/usr/bin/env node
/**
 * build-moisture.mjs —— moisture.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-moisture.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-moisture.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/moisture.lua");
const SPEC = join(__dirname, "spec-moisture.mjs");
const OUT = relOut("components/moisture.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/moisture.lua",
  "-- 模块：组件系统 / 湿度（Moisture）",
  "-- 职责：管理实体的「湿度」（0 到 100）连续量 —— 下雨累积、晴天蒸发、",
  "--       站火边加速变干、下水瞬间全湿；并把含水率换算成体感惩罚喂给温度系统。",
  "--       与 temperature.lua 的对偶关系：温度是「目标温度求差 + 保暖封顶速率」",
  "--       的趋近型控制；湿度是「多速率直接相加」的累加型控制，故结构更简单。",
  "-- 关键符号：Moisture, OnUpdate（★核心，第 338 行）, DoDelta, SetMoistureLevel,",
  "--           GetDryingRate（★三项缓动叠加）, GetMoistureRate, ForceDry,",
  "--           IsForceDry, GetWaterproofness, _GetMoistureRateAssumingRain,",
  "--           GetEquippedMoistureRate, GetSegs, GetMoisturePercent, GetDesiccantBonus,",
  "--           GetSleepingBagDryingRate, AddRateBonus, GetRateBonus, LongUpdate,",
  "--           AnnounceMoisture, onmoisture, onwet, onmaxmoisture, onratescale",
  "-- ★设计提炼（详见正文中标注 ★★★ 的行）：",
  "--   1) 净速率 = 降水 + 装备加湿 - 蒸发 + 外部加成 - 干燥剂（第 354、359 行）；",
  "--   2) 下雨时蒸发项直接归零（第 289 行），这就是「淋雨后必须找火」规则的源头；",
  "--   3) 双向耦合：第 293 行读 temperature 的 externalheaterpower，",
  "--      而 temperature 第 306 行读本组件的 GetMoisturePercent；",
  "--   4) ForceDry 是引用计数锁定（第 74-97 行），归零时自动退订并恢复更新（第 52 行）；",
  "--   5) ratescale 的升降阈值刻意不对称（第 362-369 行），因两方向量程差 7.5 倍。",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/temperature.lua（第 293 行反向读火源强度；",
  "--           第 306 行读 GetMoisturePercent 算湿度惩罚）、",
  "--           components/moisture_replica.lua（15 行镜像，net_bool 同步 wet）、",
  "--           components/inventory.lua（第 2715 行反读 GetWaterproofInventory；",
  "--           第 404 行 IsFloaterHeld）、components/sheltered.lua（第 10 行遮蔽防水）、",
  "--           components/rainimmunity.lua（完全免疫，优先级最高）、",
  "--           components/moistureabsorberuser.lua（第 30-44 行干燥剂，注意有副作用）、",
  "--           util/sourcemodifierlist.lua（防水与速率加成容器）、",
  "--           entityscript.lua（第 770 行 GetIsWet 供温度系统判断湿身）、",
  "--           constants.lua（RATE_SCALE 七档定义，第 2404 行）、",
  "--           easing.lua（第 175 行 inExpo，本文件用于含水量收敛项）",
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