#!/usr/bin/env node
/**
 * build-inventorybar.mjs —— inventorybar.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-templates.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-inventorybar.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-inventorybar.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("widgets/inventorybar.lua");
const SPEC = join(__dirname, "spec-inventorybar.mjs");
const OUT = relOut("widgets/inventorybar.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：widgets/inventorybar.lua",
  "-- 模块：UI 系统 / 手柄背包栏主控件（类名 Inv）",
  "-- 职责：手柄与主机模式下的背包条。维护槽位网格布局（5 格一组的组间大间距）、",
  "--       装备槽、光标导航（几何最近邻 + 环绕步进）、动态操作提示条 actionstring、",
  "--       物品飞入动画、溢出背包（第二行）集成与自动暂停联动。",
  "--       ★ 注意：鼠标玩家的背包交互不在本文件，由 invslot.lua/itemtile.lua 自行处理；",
  "--         本文件是并列的第二套手柄交互实现。",
  "-- 关键符号：Inv, Rebuild, Refresh, RebuildLayout, RebuildLayout_Quagmire,",
  "--           CursorNav, CursorLeft, CursorRight, CursorUp, CursorDown,",
  "--           GetClosestWidget, OffsetCursor, GetInventoryLists, SelectSlot,",
  "--           SelectDefaultSlot, UpdateCursor, UpdateCursorText, OnControl,",
  "--           OpenControllerInventory, CloseControllerInventory,",
  "--           SetAutopausedInternal, SetHoverTileHideModifier, OnItemGet,",
  "--           OnNewActiveItem, RefreshIntegratedContainer, AddEquipSlot",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：class.lua（Class 继承）, widgets/widget.lua（基类与焦点锁）,",
  "--           widgets/invslot.lua（槽位控件）、widgets/itemtile.lua（物品图）,",
  "--           widgets/equipslot.lua（装备槽）、widgets/hudcompass.lua（罗盘）,",
  "--           containers.lua（容器 widget.slotpos / *_align_tip 数据驱动定义）,",
  "--           widgets/containerwidget.lua（容器 UI）、util/sourcemodifierlist.lua",
  "--           （多来源布尔遮罩聚合器）",
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
  // 防长注释截断：注释正文里若出现长注释定界符，会提前闭合源码里
  // 已存在的 --[[ ]] 块，导致后续代码行被当成注释/语法错误。
  // 只允许整行恰为 '--[[' 或 '--]]' 这两个定界行本身。
  if (t !== "--[[" && t !== "--]]" && (t.includes("--[[") || t.includes("]]"))) {
    throw new Error(
      `规格错误 @${where}: 注释正文含长注释定界符，会截断源码块注释 -> ${line}`
    );
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