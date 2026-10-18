#!/usr/bin/env node
/**
 * build-behaviourtree.mjs —— behaviourtree.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-locomotor.mjs / build-entityscript.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-behaviourtree-p1..p5.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-behaviourtree.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/behaviourtree.lua";
const SPEC = join(__dirname, "spec-behaviourtree.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/behaviourtree.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：behaviourtree.lua",
  "-- 模块：决策层 / 行为树运行时（Behaviour Tree Runtime）",
  "-- 职责：定义「行为树」这一整套节点类型与调度协议。承担节点基类",
  "--       BehaviourNode 的生命周期（Visit / SaveStatus / Step / Reset / Stop）、",
  "--       四种状态量（READY/SUCCESS/FAILED/RUNNING）的流转规则、",
  "--       组合节点（Sequence / Selector / Priority / Parallel / Loop / Random）、",
  "--       叶节点（Condition / ConditionWait / MultiCondition / Action / Wait /",
  "--       Latch / Event）、装饰器（Not / FailIfRunning / FailIfSuccess）、",
  "--       三个语法糖构造器（WhileNode / IfNode / IfThenDoWhileNode），",
  "--       以及整棵树的休眠时间推导（GetSleepTime / GetTreeSleepTime）与",
  "--       文本导出（GetTreeString / GetString / DBString）等调试能力。",
  "--       它只回答「此刻该做什么」，不回答「我现在播哪个动画」——",
  "--       后者由 stategraph.lua（表现层状态机）负责。",
  "-- 关键符号：BT, BehaviourNode, DecoratorNode, ConditionNode,",
  "--           MultiConditionNode, ConditionWaitNode, ActionNode, WaitNode,",
  "--           SequenceNode, SelectorNode, NotDecorator,",
  "--           FailIfRunningDecorator, FailIfSuccessDecorator, LoopNode,",
  "--           RandomNode, PriorityNode, ParallelNode, ParallelNodeAny,",
  "--           EventNode, WhileNode, IfNode, IfThenDoWhileNode, LatchNode",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：brain.lua:159 Brain（思考周期与 BT 的对接、ForceUpdate 唤醒）,",
  "--           brain.lua:106 BrainManager:Update（批量驱动 + 休眠调度）,",
  "--           entityscript.lua:1103 SetBrain（树的创建者）,",
  "--           entityscript.lua:1714-1720 Remove（实体销毁时的事件总线清理）,",
  "--           class.lua:83 Class / :15 _is_a（is_a 判定链）,",
  "--           behaviours/（29 个可复用行为片段）,",
  "--           brains/*.lua（各生物的具体树，例如 brains/rabbitbrain.lua:52）,",
  "--           stategraph.lua（表现层，与本文件并存而非从属）",
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