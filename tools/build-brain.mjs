#!/usr/bin/env node
/**
 * build-brain.mjs —— brain.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-stategraph.mjs / build-locomotor.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-brain.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-brain.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("brain.lua");
const SPEC = join(__dirname, "spec-brain.mjs");
const OUT = relOut("brain.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：brain.lua",
  "-- 模块：核心框架 / 决策层调度（Brain Manager Runtime）",
  "-- 职责：定义全游戏所有生物大脑的「全局调度局」与「大脑基类」。承担：",
  "--       ① BrainWrangler / BrainManager：把任意多个大脑实例按",
  "--          「唤醒 / 定时睡 / 冬眠」三态组织，含**双缓冲迭代**",
  "--          （_safe_updaters）以保证遍历安全；",
  "--       ② 大脑的注册、注销、休眠、定时睡；",
  "--       ③ Brain 基类：生命周期（启动/停止/暂停/恢复）、",
  "--          同步事件派发、思考周期查询、模组注入点；",
  "--       ④ 与状态图的边界分工（本文件**不**负责动作表现）。",
  "--       ——它回答「我要去哪、要不要攻击」，然后驱动 stategraph.lua",
  "--       去回答「我现在看起来该做什么动作」。",
  "-- 关键符号：BrainWrangler, BrainManager, _safe_updaters,",
  "--           SendToList, Wake, Hibernate, Sleep, AddInstance,",
  "--           RemoveInstance, Update,",
  "--           Brain, ForceUpdate, AddEventHandler, GetSleepTime,",
  "--           Start, _Start_Internal, OnUpdate, DoUpdate,",
  "--           Stop, _Stop_Internal, PushEvent, Pause, Resume,",
  "--           Brain:OnStart, Brain:OnStop, Brain:OnInitializationComplete",
  "-- ★★ 与 stategraph.lua 的关系（★ 详见文件头 §零）：",
  "--     两者是**同构孪生**——BrainWrangler 与 StateGraphWrangler 的",
  "--     字段名完全一致（instances/updaters/tickwaiters/hibernaters），",
  "--     但**没有做统一抽象**，实现已各自演化出实质差异：",
  "--       ① 大脑多一张 _safe_updaters（双缓冲数组），状态图用换表法；",
  "--       ② 状态图多一张 haveEvents（事件缓冲），大脑事件是同步的；",
  "--       ③ 状态图的 Sleep 无条件 +1 tick，大脑改用 > GetTick() 判断；",
  "--       ④ 大脑的 SendToList 多一层 old_list ~= list 早退守卫。",
  "-- ★★ 三种「不更新」状态的区别（★ 本文件最易混淆处）：",
  "--     stopped —— 被彻底停用（死亡/冻结/睡着），不在调度表里",
  "--     paused  —— 被玩家暂停（打开背包），不在调度表里但可 Resume",
  "--     IsAsleep—— 由引擎判定（离屏/地洞/存档切换），",
  "--                大脑仍在 updaters 里，但被 Update 的过滤条件跳过",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：stategraph.lua:3 StateGraphWrangler（同构孪生），",
  "--           stategraph.lua:118-119 换表法（另一种快照方案），",
  "--           stategraph.lua:100 tickwaiters 清理的疑似缺陷（本文件 93-95 是正确版），",
  "--           behaviourtree.lua:533 PriorityNode（思考周期 period 与散布）,",
  "--           behaviourtree.lua:541 GetSleepTime（三态返回值的来源）,",
  "--           entityscript.lua:1078 RestartBrain / 1091 StopBrain（reason 计数）,",
  "--           entityscript.lua:1103 SetBrain / 1121 _DisableBrain_Internal /",
  "--           entityscript.lua:1135 _EnableBrain_Internal（装配与休眠联动）,",
  "--           entityscript.lua:1465 IsAsleep（not entity:IsAwake()）,",
  "--           update.lua:292 主循环驱动（紧随 SGManager:Update 之后）,",
  "--           modutil.lua:630 modpostinitfns 的注册处,",
  "--           components/freezable.lua:265、components/pinnable.lua:113、",
  "--           components/sleeper.lua:289、components/centipedebody.lua:69",
  "--           （StopBrain 的四个真实 reason 调用方）,",
  "--           brains/*.lua（各生物的 Brain 子类与行为树）,",
  "--           scheduler.lua（另一种调度实现：协程式，见文件头对照）,",
  "--           bug-patterns.md H3（事件时序）/ F2 / F4（休眠与思考周期）",
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
