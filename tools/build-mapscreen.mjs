#!/usr/bin/env node
/**
 * build-mapscreen.mjs —— mapscreen.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-mapscreen.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-mapscreen.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("screens/mapscreen.lua");
const SPEC = join(__dirname, "spec-mapscreen.mjs");
const OUT = relOut("screens/mapscreen.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：screens/mapscreen.lua",
  "-- 模块：界面 / 全屏地图（screen 名 \"MapScreen\"）",
  "-- 职责：打开地图即冻结模拟（SetAutopaused），每帧完成六件事：",
  "--       摇杆平移 / 缩放动画 / 取光标世界坐标 / 自动吸附 /",
  "--       问玩法层「这里能做什么」/ 刷三层装饰。",
  "--       装饰分三层：static（技能标记常驻）、lmb（左键动作预览）、",
  "--       rmb（右键动作预览）；后两层是复用池，仅动作类型变化时重建。",
  "--       与 playerhud 的分工：playerhud 决定地图能否打开，",
  "--       本文件负责打开后的每帧逻辑与输入。",
  "-- 关键符号：OnUpdate, OnControl, UpdateMapActionsDecorations,",
  "--           ProcessStaticDecorations, UpdateStaticDecorations,",
  "--           ProcessLMBDecorations, ProcessRMBDecorations,",
  "--           AutoAimToStaticDecorations, SetNewMapTarget, ValidateMapTarget,",
  "--           SetInherentMapActions, GetZoomOffset, GetCursorPosition,",
  "--           GetWorldPositionAtCursor, GetHelpText",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：frontend.lua（PushScreen/PopScreen 触发 OnBecomeActive/Inactive、",
  "--           TheFrontEnd.tracking_mouse）、widgets/screen.lua（基类生命周期）、",
  "--           widgets/mapwidget.lua（WorldPosToMapPos/MapPosToWorldPos 真正的",
  "--           坐标换算归属处）、widgets/controls.lua（ToggleMap 的调用方）、",
  "--           components/playercontroller.lua（UpdateActionsToMapActions /",
  "--           OnMapAction / 吞键 hack 的另一处写入方）、",
  "--           globalmapiconsdb（地图图标的全局注册表）、",
  "--           tuning.lua（各技能检测半径、CONTROLLER_DEADZONE_RADIUS）",
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
  // ★ 防块注释定界符出现在注释正文里（会提前闭合源文件已开启的长注释块）
  if (/\-\-\[\[/.test(line)) {
    throw new Error(`规格错误 @${where}: 含块注释开定界符 -> ${line}`);
  }
  if (/\]\]/.test(line)) {
    throw new Error(`规格错误 @${where}: 含块注释闭定界符 -> ${line}`);
  }
  // ★ 防反斜杠转义：工具链可能把某些转义当真回车，把一行劈成两行
  if (line.includes("\\")) {
    throw new Error(`规格错误 @${where}: 含反斜杠 -> ${line}`);
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
