#!/usr/bin/env node
/**
 * build-brains-penguin.mjs —— penguinbrain.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-combat.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-brains-penguin.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("brains/penguinbrain.lua");
const SPEC = join(__dirname, "spec-brains-penguin.mjs");
const OUT = relOut("brains/penguinbrain.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：brains/penguinbrain.lua",
  "-- 模块：AI 大脑 / 企鹅（贼鸥，唯一有完整繁殖生命周期的普通 NPC）",
  "-- 职责：装配企鹅 AI。行为链：找蛋 → 叼回巢 → 下蛋 → 护蛋 → 被偷就抢回来，",
  "--       外加群体迁徙与天敌规避。★ 本文件是【长周期 AI】的标准范本：",
  "--       大量使用 inst:DoTaskInTime 做延迟执行，并用 nextDropTime /",
  "--       nextPickupTime / layingEgg / myEgg / eggsLayed 等字段做跨帧跨存档记忆。",
  "--       另含 EventNode 事件驱动接入口、标签持久化缺失的存档兼容修复、",
  "--       「有蛋时游荡半径收缩」等值得照抄的细节。",
  "--",
  "-- ★★ 已核实的真实缺陷（详见各锚点处说明）：",
  "--   1) 第 185、297 行 #lst > 1 应为 >= 1（同文件第 141 行是正确写法），",
  "--      导致候选恰好只有 1 个时企鹅不行动；",
  "--   2) 第 280 行检查 nextPickupTime 但第 306 行设的是 nextDropTime（疑似）。",
  "-- ★★ 已撤回的误判：第 256-257 行的 and/or 优先级【不是缺陷】，",
  "--      已用 lupa(Lua 5.5) 实测五种布尔组合确认作者写法正确。",
  "-- 关键符号：PenguinBrain, CheckMyEgg, StealAction, LayEggAction,",
  "--           PickUpEggAction, EatFoodAction, GetWanderDistFn, ShouldRunAway,",
  "--           AtRookery, HerdAtRookery, PrepareForNight, FindItems, TOOCLOSE",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：brain.lua（三段式调度）, brains/braincommon.lua（恐慌底座）,",
  "--           behaviours/{wander,runaway,doaction,standstill,attackwall}.lua,",
  "--           components/{inventory,combat,knownlocations,teamattacker,",
  "--           perishable,eater,sleeper}.lua,",
  "--           tuning.lua（TUNING.TOTAL_DAY_TIME 等）",
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