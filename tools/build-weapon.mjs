#!/usr/bin/env node
/**
 * build-weapon.mjs —— weapon.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-weapon.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-weapon.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/weapon.lua";
const SPEC = join(__dirname, "spec-weapon.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/components/weapon.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/weapon.lua",
  "-- 模块：组件系统 / 武器（Weapon）",
  "-- 职责：攻击的执行环节 —— 伤害聚合（GetDamage，支持数字与函数两种 damage）、",
  "--       攻击收尾与耐久损耗（OnAttack + finiteuses）、投射物生成与发射",
  "--       （LaunchProjectile，含 projectile_offset 出手偏移）、",
  "--       电击系武器的潮湿加成参数（SetElectric）、可消耗品的 SourceModifierList。",
  "-- 关键符号：Weapon, GetDamage, OnAttack, LaunchProjectile, SetDamage,",
  "--           SetRange, SetProjectile, SetProjectileOffset, SetElectric,",
  "--           SetOverrideStimuliFn, CanRangedAttack, EnableToughFight,",
  "--           attackwearmultipliers, overridestimulifn, projectiledelay",
  "-- 与 combat.lua 的分工：combat 负责「谁打得着谁」（目标选择、距离与",
  "--       扇形弧命中判定、攻击执行调度）；本文件负责「这一击算多少伤害、",
  "--       掉多少耐久、要不要发射投射物」。真正的扣血在 health.lua。",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/combat.lua（调用 OnAttack / 读 stimuli 与倍率）,",
  "--           components/health.lua（DoDelta 扣血落点）,",
  "--           components/finiteuses.lua（耐久扣减对象）,",
  "--           components/spdamageutil.lua（元素伤害通道）,",
  "--           components/projectile.lua（Throw/IsBounced）,",
  "--           components/moisture.lua（潮湿加成的另一端）,",
  "--           util/sourcemodifierlist.lua（attackwearmultipliers 容器）,",
  "--           components/inventoryitem_replica.lua（客户端 range 同步）",
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
