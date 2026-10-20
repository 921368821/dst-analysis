#!/usr/bin/env node
/**
 * build-brains-mermguard.mjs —— mermguardbrain.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-combat.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-brains-mermguard.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("brains/mermguardbrain.lua");
const SPEC = join(__dirname, "spec-brains-mermguard.mjs");
const OUT = relOut("brains/mermguardbrain.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：brains/mermguardbrain.lua",
  "-- 模块：AI 大脑 / 美人鱼守卫（美人鱼王召唤的战斗单位）",
  "-- 职责：装配美人鱼守卫 AI。★★★ 本文件与 mermbrain.lua 是近似孪生，",
  "--       约 60% 的函数逐字重复（含注释），因此本注释【不重复解释重复部分】，",
  "--       只在两文件有差异处重点展开 —— 差异才是信息量所在。",
  "--       守卫 vs 生产者的五处根本差异：",
  "--         1) 资源：盔甲（armor, HEAD 槽）而非工具（tool, HANDS 槽）",
  "--         2) 无家：没有 GoHome / ShouldGoHome / IsHomeOnFire 三件套",
  "--         3) 战斗为主：独有的 WaitingForHelp（请求支援）节点",
  "--         4) 国王死亡即回收：独有的 OnGuardDeath 反向回调 + 化水消失",
  "--         5) 帮工仅 CHOP/MINE，无 TILL/DIG（守卫不种地）",
  "-- 关键符号：WaitingForHelp（请求支援）, TargetFollowTargetDistFn（输出位站位）,",
  "--           OnGuardDeath（国王死亡回收）, NeedsArmor, GetClosestArmory,",
  "--           PickupArmor, GetHealerFn, EatFoodAction, TargetFollowDistFn",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：brains/mermbrain.lua（★ 孪生文件，建议对照阅读）,",
  "--           brain.lua（三段式调度）, brains/braincommon.lua（帮工与恐慌底座）,",
  "--           behaviours/{wander,runaway,doaction,follow,standstill}.lua,",
  "--           simutil.lua:555（SpringCombatMod —— 季节性战斗修正器）,",
  "--           components/{follower,trader,eater,inventory,combat}.lua",
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