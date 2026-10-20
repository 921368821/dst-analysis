#!/usr/bin/env node
/**
 * build-components.mjs —— sanity.lua / hunger.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-entityscript.mjs 同源同法：
 *   · 可执行代码行 100% 来自源文件，逐字节原样复制，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-sanity-p*.mjs / spec-hunger.mjs 中，
 *     以「源文件行号」为锚点注入（before / after 两种位置）。
 *   · 任何插入内容都以 `--` 开头，故 Lua 语义绝对不受影响。
 *   · 强制在输出文件前 10 行内写入保护标记，防止被批量工具覆盖。
 *
 * 用法：node build-components.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT = pristineRoot();
const OUT_ROOT = ANN_SCRIPTS;

const PROTECTION_MARK = "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖";

/** 校验一行插入内容确实是合法注释（开发期自检，防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

const TARGETS = [
  {
    name: "components/sanity.lua",
    spec: join(__dirname, "spec-sanity.mjs"),
    header: [
      "--============================================================",
      PROTECTION_MARK,
      "-- 文件：components/sanity.lua",
      "-- 模块：组件 / 生存状态 / 理智值（Sanity）",
      "-- 职责：定义 Sanity 组件 —— 全游戏最复杂的数值系统之一。负责把「光照、",
      "--       潮湿、装扮（dapperness）、周目光环（aura）、幽灵玩家、物品修饰、",
      "--       角色特性」等十余种来源折算成一个每秒速率 rate，逐帧积分进current，",
      "--       再据此驱动 sane/insane/lunacy 状态迁移、网络同步与 UI 事件。",
      "--       ★ 它同时是「容器式」组件：既管玩家（inst.replica.sanity），",
      "--         也管怪物（pigman / ghost 等带 sanity 组件的 prefab）。",
      "-- 关键符号：Sanity, Sanity:Recalc, Sanity:OnUpdate, Sanity:DoDelta,",
      "--           Sanity:RecalcGhostDrain, Sanity:GetPercent,",
      "--           Sanity:GetPercentWithPenalty, Sanity:GetMaxWithPenalty,",
      "--           Sanity:SetPercent, Sanity:SetInducedInsanity,",
      "--           Sanity:SetInducedLunacy, Sanity:RecalculatePenalty,",
      "--           Sanity:EnableLunacy, Sanity:UpdateMode_Internal,",
      "--           Sanity:AddSanityAuraImmunity, Sanity:TransferComponent,",
      "--           _replica_setcurrent, _replica_setissane,",
      "--           LIGHT_SANITY_DRAINS, SCRATCHPAD_AURANAMES",
      "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
      "-- 交叉引用：components/sanity_replica.lua（客户端镜像）, constants.lua",
      "--           （SANITY_MODE_* / RATE_SCALE）, tuning.lua（全部数值常量）,",
      "--           components/sanityaura.lua（光环数据源）, components/moisture.lua,",
      "--           util/sourcemodifierlist.lua（修饰器列表）, gamemodes.lua:274",
      "--           （GetGhostSanityDrain）, scheduler.lua（周期/长更新调度）",
      "--============================================================",
      "",
    ].join("\n"),
  },
  {
    name: "components/hunger.lua",
    spec: join(__dirname, "spec-hunger.mjs"),
    header: [
      "--============================================================",
      PROTECTION_MARK,
      "-- 文件：components/hunger.lua",
      "-- 模块：组件 / 生存状态 / 饥饿度（Hunger）",
      "-- 职责：定义 Hunger 组件 —— 玩家与宠物的饱食度系统。职责极简：按 1 秒周期",
      "--       匀速扣减 current；current 触底后转为「持续扣血」；饥饿值本身不负责",
      "--       回复（回复由外部调用 SetPercent / SetCurrent 完成，例如进食）。",
      "--       ★ 与 sanity 的最大差别：hunger 是「离散节拍」的，sanity 是「连续每帧」的。",
      "-- 关键符号：Hunger, Hunger:DoDec, Hunger:DoDelta, Hunger:SetCurrent,",
      "--           Hunger:SetPercent, Hunger:GetPercent, Hunger:IsStarving,",
      "--           Hunger:Pause, Hunger:Resume, Hunger:SetRate, Hunger:SetKillRate,",
      "--           Hunger:SetOverrideStarveFn, Hunger:OnTaskTick, OnTaskTick,",
      "--           onmax, oncurrent, UPDATE_PERIOD",
      "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
      "-- 交叉引用：components/health.lua:613（DoDelta，cause==\"hunger\"）、",
      "--           components/hunger_replica.lua（客户端镜像）、entityscript.lua:1512",
      "--           （DoPeriodicTask，time 单位为秒）、scheduler.lua:295",
      "--           （ExecutePeriodic）、util/sourcemodifierlist.lua、",
      "--           prefabs/pet_hunger_classified.lua（宠物镜像）",
      "--============================================================",
      "",
    ].join("\n"),
  },
];

async function buildOne(t) {
  const specUrl = pathToFileURL(t.spec).href;
  const { BEFORE = {}, AFTER = {} } = await import(specUrl);

  const src = join(SRC_ROOT, t.name);
  const srcLines = readFileSync(src, "utf8").split("\n");
  expandKeysInPlace(BEFORE, srcLines, "BEFORE");   // 锚点键 → 行号键（M8）
  expandKeysInPlace(AFTER, srcLines, "AFTER");

  const out = [t.header.replace(/\n$/, "")];
  const used = new Set();
  let injected = 0;

  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `${t.name} BEFORE[${lineno}]`);
        out.push(c);
        injected++;
      }
      used.add(`B:${lineno}`);
    }

    out.push(srcLines[i]); // ← 代码行永远原样取自源文件

    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `${t.name} AFTER[${lineno}]`);
        out.push(c);
        injected++;
      }
      used.add(`A:${lineno}`);
    }
  }

  // 报告规格里是否有「行号不存在」的锚点
  const missing = [];
  for (const key of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) {
    throw new Error(`${t.name}: 规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = out.join("\n");
  const outPath = join(OUT_ROOT, t.name);
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, text, "utf8");

  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  const cross = (text.match(/参见 /g) || []).length;
  const markLine = out.findIndex((l) => l.includes("【深度注释版】")) + 1;

  console.log(`✔ 已生成: ${outPath}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷      : ${warn}`);
  console.log(`  交叉引用 参见  : ${cross}`);
  console.log(`  保护标记行号   : 第 ${markLine} 行 ${markLine <= 10 ? "(✓ 在前10行内)" : "(✘ 越界!)"}`);
  console.log("");
}

async function main() {
  for (const t of TARGETS) await buildOne(t);
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});