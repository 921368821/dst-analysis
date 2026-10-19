#!/usr/bin/env node
/**
 * build-controls.mjs —— controls.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-controls.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-controls.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("widgets/controls.lua");
const SPEC = join(__dirname, "spec-controls.mjs");
const OUT = relOut("widgets/controls.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：scripts/widgets/controls.lua",
  "-- 模块：UI 层 / HUD 根节点（Controls 类）",
  "-- 职责：作为整个客户端界面的最上层容器，创建并布局全部 HUD 子控件",
  "--       （状态栏、背包、制作菜单、toast、地图按钮、轮盘、提示气泡），",
  "--       管理地图与制作/背包界面的开关状态机，并驱动每帧的提示文字排版。",
  "-- 关键符号：Controls, MakeScalingNodes, SetHUDSize, OnUpdate,",
  "--           HighlightActionItem, ManageToast,",
  "--           ShowMap, FocusMapOnWorldPosition, HideMap, ToggleMap,",
  "--           ShowCrafting, HideCrafting, DoShowCrafting_Internal,",
  "--           DoHideCrafting_Internal,",
  "--           ShowCraftingAndInventory, HideCraftingAndInventory,",
  "--           BuildEmoteWheel, BuildCommandWheel,",
  "--           GetTooltipPos, OverrideTooltipPos",
  "-- ★ 三条贯穿全文件的设计原则（详见文末方法清单后的总结）：",
  "--   · 幂等守卫 —— Show*/Hide* 开头先查状态位，已达目标态直接 return",
  "--   · 无状态重算 —— OnUpdate 每帧从零重建 UI 呈现，不存中间态",
  "--   · 防御性降级 —— 跨模块访问点一律判空，宁可少显示不可崩",
  "-- ★ 移植价值最高的三处：",
  "--   1) MakeScalingNodes 第 496-552 行 —— 「外层管分辨率 / 内层管玩家缩放」",
  "--      的两层节点方案，DST 没有布局引擎，全靠锚点 + 两层缩放适配分辨率",
  "--   2) 第 1020-1093 行 —— 用两个正交布尔量（craftingshown 与",
  "--      craftingandinventoryshown）+ _Internal 收敛的幂等状态机",
  "--   3) 第 1095-1124 行 —— BuildEmoteWheel 是「UI 配置与构建分离」的样本：",
  "--      纯数据变换，不接触任何 UI 对象，构造期即可安全调用",
  "-- ⚠️ 已核实并定位的真实缺陷：第 1113 行把 focus_radius 误写成 radius，",
  "--    导致嵌套轮盘外圈判定环半径随项数放大大偏（该行注释内有量化推导）。",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：screens/playerhud.lua（指令轮盘差量重建、界面栈管理）,",
  "--           screens/mapscreen.lua（地图屏 zoom/平移生命周期）,",
  "--           widgets/mapwidget.lua（OnShow 中 minimap:ResetOffset）, widgets/wheel.lua（轮盘控件）,",
  "--           widgets/redux/craftingmenu_hud.lua（制作菜单）,",
  "--           widgets/inventorybar.lua（背包栏）, widgets/hoverer.lua（tooltip 定位）,",
  "--           emotes.lua（EMOTE_TYPE 分类）, util.lua（FunctionOrValue）,",
  "--           constants.lua（MAX_HUD_SCALE=1.25, ANCHOR_*, SCALEMODE_*）",
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