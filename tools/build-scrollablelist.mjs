#!/usr/bin/env node
/**
 * build-scrollablelist.mjs —— scrollablelist.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-scrollablelist.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-scrollablelist.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/widgets/scrollablelist.lua";
const SPEC = join(__dirname, "spec-scrollablelist.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/widgets/scrollablelist.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：widgets/scrollablelist.lua",
  "-- 模块：界面 / 可滚动列表控件（列表虚拟化 + 焦点链）",
  "-- 职责：DST 唯一的列表虚拟化实现，被 20+ 个界面复用（服务器列表、mod 列表、",
  "--       选项列表、morgue 死亡信息、聊天队列、封禁名单、筛选下拉等）。",
  "--       提供两种互斥模式：A 自带子控件；B 静态控件池 + updatefn 重新绑定",
  "--       （后者才是真正的虚拟化，serverlistingscreen 用 13 个行控件显示",
  "--       任意数量服务器）。另负责滚动条、拖拽滚动、焦点链的建立与同步。",
  "-- 关键符号：Scroll, RefreshView, RecalculateStepSize, SetList, AddItem,",
  "--           RemoveItem, Clear, SetFocus, DoFocusHookups, OnFocusMove,",
  "--           LayOutStaticWidgets, DoDragScroll, GetNearestStep,",
  "--           GetHierarchicalScale, focus_children, focused_index, view_offset",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：widgets/widget.lua（焦点链 focus_flow / SetFocusFromChild /",
  "--           parent_scroll_list 冒泡）, widgets/button.lua（按住重复节流、",
  "--           o_pos 按下位移）、widgets/imagebutton.lua（_RefreshImageState、",
  "--           OnLoseFocus 视觉恢复）、widgets/image.lua（全局 Image）、",
  "--           frontend.lua（LockFocus / lastx,lasty 屏幕坐标 / focus_locked）、",
  "--           screens/serverlistingscreen.lua（模式 B 的完整用例：",
  "--           listings_per_view = 13 + UpdateServerListWidget）",
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
