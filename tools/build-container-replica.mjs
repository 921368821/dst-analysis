#!/usr/bin/env node
/**
 * build-container-replica.mjs —— container_replica.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-container-replica.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-container-replica.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/container_replica.lua");
const SPEC = join(__dirname, "spec-container-replica.mjs");
const OUT = relOut("components/container_replica.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/container_replica.lua",
  "-- 模块：组件系统 / 容器客户端镜像（Container Replica）",
  "-- 职责：容器（箱子/背包/晾衣绳等）的客户端镜像。负责容器界面的开启与关闭、",
  "--       槽位合法性判定（CanTakeItemInSlot）、物品查询（GetItemInSlot/Has）、",
  "--       槽位点击操作的 RPC 请求转发（Put*/Take*/Add*/Swap*/Move*系列）、",
  "--       观察者管理（AttachOpener / AddOpener）与只读容器标记。",
  "-- ★ 定位：这是「replica 模式」的最佳样本——同名方法与",
  "--   components/container.lua（服务端权威）高度重合，但一个改数据、一个只读副本。",
  "--   客户端只发意图请求，真正变更一律由服务端确认后广播。",
  "-- 关键符号：Container, Open, Close, CanTakeItemInSlot, GetSpecificSlotForItem,",
  "--           ShouldPrioritizeContainer, IsOpenedBy, IsBusy, AttachOpener,",
  "--           DetachOpener, AddOpener, RemoveOpener, WidgetSetup,",
  "--           RefreshLocalPlayerUI, OnRemoveEntity",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/container.lua（服务端权威实现，方法名一一对应）,",
  "--           components/inventoryitem.lua（CanGoInContainer 等物品属性）,",
  "--           components/stackable.lua（IsFull / CanStackWith 堆叠判定）,",
  "--           widgets/containerwidget.lua（容器 UI 控件）,",
  "--           widgets/inventorybar.lua（HUD 容器条）,",
  "--           networking.lua / networkclientrpc.lua（槽位操作的 RPC 通道）,",
  "--           classed.lua（classified 子实体）, replica.lua（replica 机制本体）",
  "--============================================================",
  "",
].join("\n");

function assertComment(line, where) {
  const t = line.trim();
  if (t !== "" && !t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
  if (line.includes("\uFFFD")) {
    throw new Error(`规格错误 @${where}: 含 U+FFFD 替换字符（编码损坏）-> ${line}`);
  }
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const mod = await import(specUrl);
  const AFTER = mod.default;

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split(/\r?\n/);
  if (srcLines.length && srcLines[srcLines.length - 1] === "") srcLines.pop();
  expandKeysInPlace(AFTER, srcLines, "AFTER");

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