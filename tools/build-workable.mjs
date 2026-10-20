#!/usr/bin/env node
/**
 * build-workable.mjs —— workable.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-workable.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-workable.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/workable.lua");
const SPEC = join(__dirname, "spec-workable.mjs");
const OUT = relOut("components/workable.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/workable.lua",
  "-- 模块：组件系统 / 可施工（Workable）",
  "-- 职责：斧/镐/锄对实体的挖掘与修理进度账本 —— 余量扣减（WorkedBy_Internal）、",
  "--       浮点 epsilon 收尾、完成编排（掉落/销毁事件）、工具崩开判定（ShouldRecoil）、",
  "--       按 save 是否持久化 workleft/maxwork，并把可施工标签同步给 repairable。",
  "-- 【架构要点】本组件【不含进度条、不含计时器、不含协程】。",
  "--       长动作由 actions.lua 的 DoToolWork + stategraph 的 dolongaction 驱动，",
  "--       每结算一次调一次 WorkedBy_Internal。",
  "--       因此「打断」退化为「不再被调用」，无需任何中断/保存代码 ——",
  "--       因为进度本身就被建模为剩余量 workleft 这一个持久化字段。",
  "-- 关键符号：Workable, WorkedBy, WorkedBy_Internal, ShouldRecoil,",
  "--           SetWorkLeft, SetMaxWork, CanBeWorked, Destroy, SetWorkable,",
  "--           SetOnWorkCallback, SetOnFinishCallback, SetWorkMultiplierFn,",
  "--           SetShouldRecoilFn, SetRequiresToughWork, SetOnLoadFn",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：actions.lua（DoToolWork/ValidToolWork —— 真正的进度驱动方）,",
  "--           components/repairable.lua（可修理性同步与 workrepairable 标签）,",
  "--           components/tool.lua（CanDoToughWork 工具硬度豁免）,",
  "--           components/stackable.lua, components/burnable.lua（完成后的掉落）,",
  "--           components/finiteuses.lua（工具自身耐久）,",
  "--           physics.lua（DestroyEntity 倒塌时强制摧毁）,",
  "--           prefabs/lunarrift_crystals.lua、prefabs/daywalker_pillar.lua",
  "--           （两个自定义 ShouldRecoil 实例）",
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
