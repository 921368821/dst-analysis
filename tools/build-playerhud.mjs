#!/usr/bin/env node
/**
 * build-playerhud.mjs —— playerhud.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-playerhud.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-playerhud.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("screens/playerhud.lua");
const SPEC = join(__dirname, "spec-playerhud.mjs");
const OUT = relOut("screens/playerhud.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：screens/playerhud.lua",
  "-- 模块：界面 / 游戏内 HUD 屏幕（screen 名 \"HUD\"）",
  "-- 职责：游戏主 HUD 的「编排器」。本身是 Screen，但几乎不画东西，只做三件事：",
  "--       1) 持有五棵根控件（overlayroot/under_root/root/over_root/",
  "--          popupstats_root），其 AddChild 顺序即渲染 z 序；",
  "--       2) 编排全部弹窗与轮盘的开与关（Open*/Close* 共 20 多对）；",
  "--       3) 独占输入：HasInputFocus 与 OnControl 决定按键归 UI 还是归世界。",
  "--       真正的 HUD 内容在 widgets/controls.lua（root 的唯一子控件）。",
  "-- 关键符号：CreateOverlays, SetMainCharacter, OpenScreenUnderPause,",
  "--           HasInputFocus, SetModFocus, OnControl, OpenSpellWheel,",
  "--           OpenCommandWheel, TryStopInspectingModules, RefreshControllers,",
  "--           UpdateClouds, UpdateDrops, GetFirstOpenContainerWidget",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：frontend.lua（screenstack 压栈/出栈/插栈、焦点）, ",
  "--           widgets/screen.lua（Screen 基类，OnDestroy 即 Kill）, ",
  "--           widgets/widget.lua（焦点链 SetFocus/SetFocusFromChild）, ",
  "--           widgets/controls.lua（HUD 本体，本文件的 self.controls）, ",
  "--           widgets/inventorybar.lua（rebuild_pending 脏标记）, ",
  "--           widgets/characterstatst displays（血/理智/体温）,",
  "--           cameras/followcamera.lua（ScreenHOffset 配对栈）, ",
  "--           prefabs/player_common.lua（ActivateHUD 激活顺序）,",
  "--           popupmanager.lua（POPUPS.PLAYERINFO 等模组化弹窗）, ",
  "--           components/playercontroller.lua（ShouldPlayerHUDControlBeIgnored 输入仲裁）",
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
  if (line.includes("--[") && line.includes("[") && /\-\-\[\[/.test(line)) {
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
  expandKeysInPlace(AFTER, srcLines, "AFTER");
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
