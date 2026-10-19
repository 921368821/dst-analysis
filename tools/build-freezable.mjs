#!/usr/bin/env node
/**
 * build-freezable.mjs —— freezable.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-freezable.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-freezable.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/freezable.lua");
const SPEC = join(__dirname, "spec-freezable.mjs");
const OUT = relOut("components/freezable.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/freezable.lua",
  "-- 模块：组件系统 / 冻结（Freezable）",
  "-- 职责：把「冷」的累积量 coldness 映射到三态状态机（NORMAL / FROZEN / THAWING），",
  "--       冻结期间接管大脑、攻击目标与移动；解冻可由挨够伤害自然碎冰，或外部 Thaw。",
  "--       附带 extraresist 递减机制，专治 BOSS 被反复续冻。",
  "--",
  "-- 【与 temperature.lua 的分工：两种不同性质的设计，值得对照】",
  "--   temperature.lua 管「活物体温演化」—— 连续量，每帧 OnUpdate 积分，有保暖封顶；",
  "--   freezable.lua     管「物品/怪物冻结」—— 离散状态机，定时器驱动，有抗性门槛。",
  "--   → 移植前先判断「这个冷是连续的还是离散的」再选骨架。",
  "--",
  "-- 关键符号：Freezable, AddColdness（★唯一外部入口）, Freeze, Unfreeze, Thaw,",
  "--           IsFrozen（含 THAWING）, IsThawing, StartWearingOff, WearOff,",
  "--           ResolveResistance, ResolveWearOffTime, SetExtraResist, DecayExtraResist,",
  "--           SetResistance, SetRedirectFn, GetFreezePercent, SpawnShatterFX,",
  "--           AddShatterFX, SetShatterFXLevel, UpdateTint, PushColour, PopColour,",
  "--           SetDefaultWearOffTime, GetTimeToWearOff, Reset, OnAttacked, WearOff",
  "--",
  "-- ★设计提炼（详见正文中标注 ★★★ 的行）：",
  "--   1) 状态必须真正改变行为：Freeze 同时停大脑（第 265 行）、清攻击目标（第 268 行）、",
  "--      停移动（第 272 行）—— 漏任何一项都会出「被冻住的怪物还在追你」的 bug；",
  "--   2) 三态而非两态：FROZEN → THAWING → NORMAL 是必经流程，玩家能观察到渐进恢复；",
  "--   3) 缓冲带设计：未达门槛先「看起来结冰」（第 152-154 行）、解冻后 0.3 秒禁攻",
  "--      （第 299 行）—— 在危险边缘外留反应时间，这是手感的主要来源；",
  "--   4) extraresist 递减（每 30 秒削 0.1）：同一手段边际收益递减，防 BOSS 无限续冻；",
  "--   5) 状态恢复必须走 setter（OnLoad 调 SetExtraResist 而非裸赋值，第 329-331 行），",
  "--      否则递减计时器不会启动。",
  "--",
  "-- ⚠️ 本文件已核实的缺陷（详见对应行）：",
  "--   - 第 310 行 Thaw 双重折算：外层已调 ResolveWearOffTime，第 167 行内部又调一次，",
  "--     系数被平方。仅影响开启 extraresist 的 BOSS。",
  "--   - 第 243-245 行 GetFreezePercent 未防除零：resistance 被配成 0 时返回 NaN。",
  "--   - 第 328 行 OnLoad 缺 data ~= nil 保护（依赖 entityscript.lua 的调用约定，当前不触发）。",
  "--",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/sleeper.lua（同构孪生组件，同样有 extraresist 递减）、",
  "--           components/combat.lua（SetTarget(nil) / BlankOutAttacks(0.3)）、",
  "--           components/locomotor.lua（Stop）、components/health.lua（IsDead 守卫）、",
  "--           components/colouradder.lua（可选色调叠加，回退直写 AnimState）、",
  "--           components/shatterfx.lua（SetLevel 自行钳位档位）、",
  "--           components/propagator.lua（第 206 行 AddColdness 负值 = 火源取暖）、",
  "--           components/wateryprotection.lua（第 33 行水源加冷）、",
  "--           components/moisture.lua 与 temperature.lua（另一套「冷」的机制，对照阅读）、",
  "--           entityscript.lua（第 1980-1981 行 OnLoad 的调用约定）",
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