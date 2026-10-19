#!/usr/bin/env node
/**
 * build-farmplantstress.mjs —— farmplantstress.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-farmplantstress.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-farmplantstress.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/farmplantstress.lua");
const SPEC = join(__dirname, "spec-farmplantstress.mjs");
const OUT = relOut("components/farmplantstress.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/farmplantstress.lua",
  "-- 模块：组件系统 / 作物压力（FarmPlantStress）",
  "-- 职责：DST 中真正存在的「stress 源注册与结算」系统（作用对象是作物，不是玩家）。",
  "--       提供：压力源的注册（AddStressCategory，具名 + 判定函数 + 变化回调）、",
  "--       状态灌入（SetStressed）、阶段结算与累计积分（MakeCheckpoint）、",
  "--       累计分到四档压力的映射（CalcFinalStressState）、",
  "--       面向玩家的压力描述（含信息隐藏与 plantkin 特例）。",
  "-- 【★ 抽象价值】① 注册式多源压力：新增一种压力只需 AddStressCategory 一行；",
  "--       ② 保守默认值：所有源注册即 true（宁可多报，不漏判）；",
  "--       ③ 检查点积分：压力按阶段累加，未被检查的源每阶段重置为待检查；",
  "--       ④ 判定函数两用：业务层主动调用记账，本组件内部调用显示实时状态。",
  "-- 【⚠️ 注意】本组件的 testfn 不参与自动判定 —— 判定时机由 prefab 层掌控",
  "--       （见 prefabs/farm_plants.lua 的 MakeStressCheckpoint 函数）。",
  "-- 关键符号：FarmPlantStress, AddStressCategory, SetStressed, MakeCheckpoint,",
  "--           CalcFinalStressState, GetFinalStressState, GetStressDescription,",
  "--           Reset, CopyFrom, OnSave, OnLoad, GetDebugString,",
  "--           stressors, stressors_testfns, stressor_fns, stress_points,",
  "--           num_stressors, final_stress_state, checkpoint_stress_points",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：prefabs/farm_plants.lua（7 个压力源的注册点与结算时机）、",
  "--           components/farmsoildrinker.lua（水分压力与阶段重置）、",
  "--           constants.lua:2107-2112（FARM_PLANT_STRESS 四档常量）、",
  "--           components/plantresearchable（farmplantstress 标签的消费者）、",
  "--           components/inventory_replica.lua、components/useableitem.lua",
  "--           （对照：不同组件的回调返回值约定宽严不一）",
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
