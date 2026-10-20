#!/usr/bin/env node
/**
 * build-stategraph.mjs —— stategraph.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-locomotor.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-stategraph-*.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-stategraph.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("stategraph.lua");
const SPEC = join(__dirname, "spec-stategraph.mjs");
const OUT = relOut("stategraph.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：stategraph.lua",
  "-- 模块：核心框架 / 表现层状态机（StateGraph Runtime）",
  "-- 职责：定义 DST 的**表现层** AI 框架。角色的每一个动作（待机、行走、",
  "--       攻击、受惊、死亡、僵直…）都是它的一个状态。承担四类职责：",
  "--       ① 状态图的定义与组装（State / StateGraph / 三个 Handler 值对象），",
  "--          以及四个模组注入点；",
  "--       ② 全局调度（StateGraphWrangler / SGManager）：把任意多个状态图",
  "--          实例按「唤醒 / 定时睡 / 冬眠」三态组织，保证帧率无关的时间推进",
  "--          与零 CPU 的空闲态；",
  "--       ③ 单实例的状态转移（StateGraphInstance）：GoToState 十二步、",
  "--          标签体系、timeout、timeline 执行、事件缓冲与两级派发；",
  "--       ④ 动作路由（ActionHandler）与客户端预测支持（FastForward /",
  "--          ServerStateMatches）。",
  "--       ——它只回答「我现在看起来该做什么动作」，不回答「我要去哪、",
  "--       要不要打它」。后者是决策层的职责，由 brain.lua + 行为树负责。",
  "-- 关键符号：StateGraphWrangler, SGManager, ActionHandler, EventHandler,",
  "--           TimeEvent, FrameEvent, SoundTimeEvent, SoundFrameEvent,",
  "--           State, StateGraph, StateGraphInstance,",
  "--           GoToState, PushEvent, HandleEvent, HandleEvents,",
  "--           ClearBufferedEvents, SetTimeout, StartAction, PreviewAction,",
  "--           AddStateTag, RemoveStateTag, HasStateTag, HasAnyStateTag,",
  "--           HasState, InNewState, GetTimeInState, PlayRandomAnim,",
  "--           UpdateState, Update, Start, Stop,",
  "--           ServerStateMatches, FastForward",
  "--           ——全局表：SGManager, SGTagsToEntTags",
  "-- ★★ 三层记忆（必须先记住，错误集中在这）：",
  "--     statemem —— 「本状态的工作区」，**每次 GoToState 都被清空**（550 行）。",
  "--               对应 bug-patterns.md 的 H2 条目。",
  "--     mem      —— 跨状态持久数据，只随实体销毁而清（343 行）。",
  "--     实例字段  —— tags / timeout / timelineindex / timeinstate，",
  "--               换状态时按需重置。",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：class.lua（六个类的共同基座）,",
  "--           brain.lua（同构孪生的调度层，决策层）,",
  "--           entityscript.lua:1148 SetStateGraph（装配与初始进状态）,",
  "--           entityscript.lua:1307 PushEvent_Internal（事件路由入口）,",
  "--           entityscript.lua:1600 PerformPreviewBufferedAction,",
  "--           update.lua:288 主循环驱动（另有 214 行的静态 tick 事件路径）,",
  "--           behaviourtree.lua:533 PriorityNode（决策层的思考周期散布）,",
  "--           stategraphs/commonstates.lua（CommonStates / CommonHandlers 复用库）,",
  "--           stategraphs/SGbat.lua（一个完整的最小实例）,",
  "--           actions.lua:3305（statemem 标志的另一种用法对照）,",
  "--           sched//scheduler.lua（DoTaskInTime 的同源设计）,",
  "--           bug-patterns.md H1 / H2 / H3 / F3（对应条目）",
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
  expandKeysInPlace(BEFORE, srcLines, "BEFORE");   // 锚点键 → 行号键（M8）
  expandKeysInPlace(AFTER, srcLines, "AFTER");

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
