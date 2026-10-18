#!/usr/bin/env node
/**
 * build-clock.mjs —— components/clock.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-clock.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-clock.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/clock.lua";
const SPEC = join(__dirname, "spec-clock.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/components/clock.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/clock.lua",
  "-- 模块：组件系统 / 世界时钟（Clock）—— 客户端预测的范本",
  "-- 职责：维护全服共享的昼夜与月相。三个时段（day/dusk/night）各占若干",
  "--       segment，全天共 16 段（NUM_SEGS）；月相按 20 元素循环序列推进。",
  "--       ★核心范式：客户端用 set_local 自行推进时间（预测，零带宽），",
  "--       服务端仅在每个 segment 边界用 set 强制覆盖（纠偏）。",
  "--       并在暂停恢复时经 ForceResync 强制对齐一次。",
  "-- 关键符号：NUM_SEGS, PHASE_NAMES, MOON_PHASE_CYCLES, _segs, _cycles,",
  "--           _phase, _moonphase, _mooniswaxing, _totaltimeinphase,",
  "--           _remainingtimeinphase, GetMoonPhase, CalcTimeOfDay,",
  "--           ForceResync, OnSetClockSegs, OnSetMoonPhase, OnSimUnpaused,",
  "--           OnClockUpdate, OnUpdate, OnStaticUpdate, LongUpdate, OnSave, OnLoad",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：netvars.lua:36（脏事件在 Lua 更新前触发）、",
  "--           netvars.lua:52-57（set_local 使服务端下次 set 必定变脏）、",
  "--           netvars.lua:65-67（平滑计时器由客户端预测的原文范式）、",
  "--           prefabs/world_network.lua:57（本组件的装配位置）、",
  "--           components/shard_clock.lua（次 shard 时钟，与本文 NUM_PHASES 对齐）、",
  "--           components/moonstormmanager.lua:197（ms_setmoonphase 的发起方）、",
  "--           components/worldstate.lua:90（iswaxingmoon 的落地）、",
  "--           components/squidspawner.lua:83（读取盈亏标记刷怪）、",
  "--           components/seasons.lua（负责调整昼夜段数，不在时钟内做）",
  "-- 【★★已核实缺陷：第 149 行盈亏分界 off-by-one】",
  "--   waxing 判据用 (#MOON_PHASE_CYCLES / 2) = 10，但真实盈象段数为 11、",
  "--   亏象 9（因新月满月各 1 段而中间相各 3 段），故游标 11（满月）被误判。",
  "--   我已按第 38-51 行的展开逻辑构造序列并逐项比对，确认仅第 11 项不符。",
  "--   详见第 148 行注。",
  "-- 【★移植要点】预测系统必须自带「强制纠偏」出口（本文件 ForceResync），",
  "--   且段数/分段这类「刻度」量必须由权威端统一决定，客户端只能本地推进。",
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