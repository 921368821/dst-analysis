#!/usr/bin/env node
/**
 * build-brains-buzzard.mjs —— buzzardbrain.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-combat.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-brains-buzzard.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("brains/buzzardbrain.lua");
const SPEC = join(__dirname, "spec-brains-buzzard.mjs");
const OUT = relOut("brains/buzzardbrain.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：brains/buzzardbrain.lua",
  "-- 模块：AI 大脑 / 秃鹫（争抢并占有尸体的空中单位）",
  "-- 职责：装配秃鹫 AI。★★★ 本文件最大看点：覆写 DoUpdate 实现【逐帧失效的缓存】——",
  "--       Brain:OnUpdate（顶层 brain.lua:228）每帧先调 DoUpdate 把威胁缓存标记待查，",
  "--       再跑行为树，于是树内多次查询只做一次 FindEntity。",
  "--       另含完整的「资源占有三件套」：模块级共享表 ignorethese 登记占有者、",
  "--       SIZE_TO_NUM_OWNERS 按尸体尺寸分配名额、OnStop 释放防止表无限增长。",
  "--       以及「设标志 / 执行分离」的三入口飞走机制、SuggestTarget 的群体协商、",
  "--       「战斗距离 + 尸体半径」联动的拾取站位等模式。",
  "--",
  "-- ⚠️ 阅读警告：第 45-46 行的 FINDTHREAT_MUST_TAGS / FINDTHREAT_CANT_TAGS",
  "--   变量名与实际传入 FindEntity 的位置【相反】（源码自带澄清注释）。",
  "--   第 48 行的变异体版本命名却是正确的 —— 可反证前者是笔误。",
  "-- 关键符号：BuzzardBrain, DoUpdate（逐帧缓存失效）, FindThreat（三态缓存）,",
  "--           OwnCorpse / LoseCorpseOwnership（占有与释放）, ShouldIgnoreCorpse,",
  "--           SIZE_TO_NUM_OWNERS（容量表）, DealWithThreat, GetCorpseRadius,",
  "--           Buzzard_ShouldIgnoreCorpse, OnStop（★ 释放共享表）",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：顶层 brain.lua:228-236（Brain:OnUpdate —— DoUpdate 的调用点）,",
  "--           brains/braincommon.lua（共享底座）,",
  "--           behaviours/{standandattack,wander,doaction,faceentity,leash}.lua,",
  "--           components/combat.lua（SuggestTarget / SetTarget / TargetIs）,",
  "--           components/{inventory,health,burnable}.lua,",
  "--           tuning.lua（TUNING.MUTATEDBUZZARD_FIND_CORPSE_DELAY）,",
  "--           FOODGROUP.OMNI.types（FOOD_TAGS 的来源）",
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