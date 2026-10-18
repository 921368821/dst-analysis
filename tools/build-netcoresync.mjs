#!/usr/bin/env node
/**
 * build-netcoresync.mjs —— netvars.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-netcoresync.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * ⚠️ 本文件源码 4-38 / 42-69 / 73-81 行本身是长注释块，
 *    故 spec 中的注释正文一律不含块注释标记（见 SOP 坑 6）。
 *
 * 用法：node build-netcoresync.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/netvars.lua";
const SPEC = join(__dirname, "spec-netcoresync.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/netvars.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：netvars.lua",
  "-- 模块：网络同步层 / 网络变量（Network Variable）类型契约",
  "-- 职责：DST 同步层的「类型契约」。声明 13 种 net_* 网络变量的位宽与值域、",
  "--       set / value / set_local 三件套的语义（含脏值检测规则）、",
  "--       一次性触发事件 net_event 的约定，以及整数宽度选择器",
  "--       GetIdealUnsignedNetVarForCount。",
  "-- ★★ 本文件不含同步实现：13 个 net_* 构造器全部是 C++ 内建函数",
  "--       （见文件首行注释指向的 luanetworkvariable.cpp），Lua 侧零实现。",
  "--       它是「Lua 与 C++ 双份真相」的一份，宽度表在 C++ 里也有一份。",
  "-- 关键符号：net_bool .. net_ushortarray（类型表，仅注释）、net_event、",
  "--           net_event:push、GetIdealUnsignedNetVarForCount",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：entityreplica.lua（replica 分发链路，本层的另一半）、",
  "--           class.lua:176（Class 构造器调用约定 c._ctor(obj, ...)）、",
  "--           components/clock.lua:161 ForceResync（set_local 的官方对冲手段）、",
  "--           prefabs/player_classified.lua:1330-1520（wire format 实战声明区）、",
  "--           components/clientpickupsoundsuppressor.lua:23（不用 net_event 的反例）",
  "-- 【★已核实缺陷】net_event 构造器只接受 (guid, event) 两个业务实参，",
  "--       第三个实参被 Lua 静默丢弃；alterguardian_phase1/2/3 传了第三个实参",
  "--       却按其生效，详见下方第 85 行注。",
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