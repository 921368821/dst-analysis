#!/usr/bin/env node
/**
 * build-entityscript.mjs —— entityscript.lua 深度中文注释生成器（锚点注入法）
 *
 * 设计目标：从根本上杜绝「手抄代码行出错」。
 *   · 可执行代码行 100% 来自源文件，逐字节原样复制，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-entityscript.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，故 Lua 语义绝对不受影响。
 *
 * 用法：node build-entityscript.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("entityscript.lua");
const SPEC = join(__dirname, "spec-entityscript.mjs");
const OUT = relOut("entityscript.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：entityscript.lua",
  "-- 模块：核心框架 / 实体运行时（Entity Runtime）",
  "-- 职责：定义 EntityScript —— 全游戏每个实体（生物 / 物品 / 玩家 / 光球）的",
  "--       Lua 侧基类。承担组件装配、事件总线、limbo 虚体管理、更新调度注册、",
  "--       存档序列化、StateGraph / Brain 挂载、子实体与平台跟随、标签查询、",
  "--       距离与朝向计算、缓冲动作路由等职责。",
  "--       它是「C++ 引擎实体 Entity」与「Lua 业务逻辑」之间的桥接层：",
  "--       self 是 Lua 侧对象，self.entity 是 C++ 侧实体，二者一一对应。",
  "-- 关键符号：EntityScript, GetSaveRecord, SetPersistData, RemoveFromScene,",
  "--           ReturnToScene, IsInLimbo, ForceOutOfLimbo, StartUpdatingComponent,",
  "--           StopUpdatingComponent, StopUpdatingComponent_Deferred,",
  "--           StartWallUpdatingComponent, AddComponent, RemoveComponent,",
  "--           AddTag, HasTag, HasTags, HasOneOfTags, ListenForEvent, PushEvent,",
  "--           RemoveEventCallback, RemoveAllEventCallbacks, WatchWorldState,",
  "--           AddChild, RemoveChild, AddPlatformFollower, SetBrain, SetStateGraph,",
  "--           PushBufferedAction, PerformBufferedAction, PreviewBufferedAction,",
  "--           DoPeriodicTask, DoTaskInTime, PushEventInTime, Remove",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：class.lua（类系统）, scheduler.lua（任务调度）,",
  "--           entityreplica.lua（副本组件）, componentactions.lua（组件动作表）,",
  "--           stategraph.lua（状态图）, brain.lua（大脑）,",
  "--           entityscriptproxy.lua（跨端代理）, update.lua（主循环驱动）",
  "--============================================================",
  "",
].join("\n");

/** 校验一行插入内容确实是合法注释（开发期自检，防止规格里混入代码） */
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
  const lines = raw.split("\n");
  // 若文件以换行结尾，split 会产生末尾空串；保留它以便原样还原文件。
  const srcLines = lines;

  const out = [HEADER.replace(/\n$/, "")];
  // 追加规格里的额外头注（如果有）
  if (HEADER_EXTRA && HEADER_EXTRA.length) {
    for (const h of HEADER_EXTRA) {
      assertComment(h, "HEADER_EXTRA");
      out.push(h);
    }
  }

  const used = new Set();
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
      used.add(`B:${lineno}`);
    }

    out.push(srcLines[i]); // ← 代码行永远原样取自源文件

    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `AFTER[${lineno}]`);
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
    throw new Error(`规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = out.join("\n");
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, text, "utf8");

  // ---- 统计 ----
  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  const cross = (text.match(/参见 /g) || []).length;
  console.log(`✔ 已生成: ${OUT}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
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