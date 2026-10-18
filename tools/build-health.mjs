#!/usr/bin/env node
/**
 * build-health.mjs —— health.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-entityscript.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-health-*.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-health.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/health.lua";
const SPEC = join(__dirname, "spec-health.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/components/health.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/health.lua",
  "-- 模块：组件系统 / 生命值（Health）",
  "-- 职责：全游戏唯一的血量容器与扣血汇聚点。承担伤害结算（DoDelta）、",
  "--       吸收/减伤/承伤上限、温度与饥饿的非致死保护、火焰伤害计时与",
  "--       每秒上限、月光灼烧标记、回复源管理、生命惩罚（penalty）、",
  "--       死亡事件与尸体化、存档序列化、联机副本同步等职责。",
  "--       全游戏 120+ 处调用方最终都收敛到 DoDelta 一条路径上，",
  "--       所以它的参数语义就是整个游戏「生存压力」的总契约。",
  "-- 关键符号：Health, DoDelta, SetVal, SetPercent, GetPercent, IsDead,",
  "--           GetMaxWithPenalty, SetPenalty, DeltaPenalty, Kill, ForceKill,",
  "--           DoFireDamage, StartRegen, AddRegenSource, RemoveRegenSource,",
  "--           SetAbsorptionAmount, RegisterLunarBurnSource, CanFadeOut,",
  "--           TransferComponent, OnSave, OnLoad",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：util/sourcemodifierlist.lua（修饰器容器）,",
  "--           components/health_replica.lua（客户端镜像）,",
  "--           components/combat.lua（战斗扣血主入口）,",
  "--           components/hunger.lua / components/temperature.lua（环境扣血）,",
  "--           components/revivablecorpse.lua（复活）,",
  "--           componentutil.lua（CanEntityBecomeCorpse）,",
  "--           simutil.lua（ErodeAway）, class.lua（属性 setter 机制）",
  "--============================================================",
  "",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const { HEADER_EXTRA, BEFORE, AFTER } = await import(specUrl);

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split("\n");

  const out = [HEADER.replace(/\n$/, "")];
  if (HEADER_EXTRA && HEADER_EXTRA.length) {
    for (const h of HEADER_EXTRA) {
      assertComment(h, "HEADER_EXTRA");
      out.push(h);
    }
  }

  let injected = 0;

  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `BEFORE[${lineno}]`);
        out.push(c);
        injected++;
      }
    }

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
  for (const key of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
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
  const cross = (text.match(/参见 /g) || []).length;
  const commented = new Set([
    ...Object.keys(BEFORE).map(Number),
    ...Object.keys(AFTER).map(Number),
  ]);
  let cov = 0;
  for (const k of commented) if (k >= 1 && k <= srcLines.length) cov++;

  console.log(`✔ 已生成: ${OUT}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`);
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷⚠      : ${warn}`);
  console.log(`  交叉引用参见    : ${cross}`);
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
