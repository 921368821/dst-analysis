#!/usr/bin/env node
/**
 * build-itemtile.mjs —— itemtile.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-templates.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-itemtile.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-itemtile.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("widgets/itemtile.lua");
const SPEC = join(__dirname, "spec-itemtile.mjs");
const OUT = relOut("widgets/itemtile.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：widgets/itemtile.lua",
  "-- 模块：UI 系统 / 物品格控件（ItemTile）",
  "-- 职责：渲染背包/容器中「一个物品」的最小可复用单元。自身不含玩法规则，",
  "--       只把服务端数据与本地预览状态映射为视觉表现：主贴图（支持分层图标）、",
  "--       堆叠数量文字、耐久百分比、腐败进度条、潮湿标记、蓄力/回复环、温度条、",
  "--       损坏底衬，以及暗影燃料雾、酸嘶嘶、长笛光环、吸水、好运等一次性特效。",
  "--       ★ 核心难点是「客户端本地预览 + 服务端同步」的双轨：ispreviewing /",
  "--         isolddata 标记使预测与权威回包共存而不产生双重动画。",
  "--       ★ 本文件的子节点一律 AddChild 到 self.image 之下，",
  "--         渲染层级完全由 AddChild 顺序决定（无 zIndex）。",
  "-- 关键符号：ItemTile, SetImageFromItem（静态导出 sSetImageFromItem）,",
  "--           DoInspected, Refresh, SetBaseScale, OnControl, UpdateTooltip,",
  "--           GetDescriptionString, SetOnQuantityChangedFn, SetQuantity,",
  "--           SetPercent, SetPerishPercent, SetChargePercent, SetChargeTime,",
  "--           StartDrag, ShowSpoilage, HideSpoilage, HasSpoilage,",
  "--           StartUpdatingCharge, StopUpdatingCharge, StartUpdatingShadowFuel,",
  "--           StopUpdatingShadowFuel, OnUpdate, CheckShadowFXFuel, ToggleShadowFX,",
  "--           SetIsEquip, HandleAcidSizzlingFX, HandleBuffFX,",
  "--           UpdateTemperaturePercent, SetTemperaturePercent",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：class.lua（Class 继承）、widgets/widget.lua（基类与焦点）、",
  "--           widgets/image.lua、widgets/text.lua、widgets/uianim.lua",
  "--           （AnimState 的 OverrideSymbol / SetPercent / SetTime / animover）、",
  "--           widgets/invslot.lua（父级槽位，承接点击与拖拽交互）、",
  "--           widgets/inventorybar.lua（设置 isactivetile，消费 sSetImageFromItem）、",
  "--           widgets/recipetile.lua（SetImageFromItem 需与之保持同步，见第 15 行）、",
  "--           components/inventoryitem.lua（温度组件 AttachReplica）、",
  "--           components/stackable.lua、prefabs/wobycommon.lua、",
  "--           constants.lua（FOODTYPE、HUD_ATLAS）、util/sourcemodifierlist.lua",
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