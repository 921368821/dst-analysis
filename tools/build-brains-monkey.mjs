#!/usr/bin/env node
/**
 * build-brains-monkey.mjs —— monkeybrain.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-combat.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-brains-monkey.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/brains/monkeybrain.lua";
const SPEC = join(__dirname, "spec-brains-monkey.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/brains/monkeybrain.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：brains/monkeybrain.lua",
  "-- 模块：AI 大脑 / 猴子（捣蛋型随从）",
  "-- 职责：装配猴子 AI。★ 与其他随从不同，猴子的核心行为是【骚扰主人】：",
  "--       抢主人 5 秒内刚采集到的东西、抢在主人前面捡起主人正要捡的物品、",
  "--       偷主人附近的箱子。配套亮点：",
  "--       · 五级候选阶梯的觅食逻辑（背包→帽子→地上食物→作物→随便捡）",
  "--       · 「随机闸门」（第 85 行 75% 概率放弃觅食）让行为显得自然",
  "--       · 「好奇心」与「翻箱子冷却」两处 DoTaskInTime 限频机制",
  "--       · 资源驱动的战斗闭环（有弹药→远程打玩家 / 没弹药→捡便便）",
  "--       · deepcopy 处理表别名（第 28 行），避免 NO_LOOTING_TAGS 被污染",
  "--       · distsq 两距离平方对比判断「我比主人更近」（第 214 行）",
  "-- 关键符号：MonkeyBrain, AnnoyLeader（骚扰主人三段策略）, EatFoodAction,",
  "--           GetPoop, ShouldRunFn, OnLootingCooldown, SetCurious,",
  "--           NO_LOOTING_TAGS / NO_PICKUP_TAGS, TIME_BETWEEN_EATING",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：brain.lua（三段式调度）, brains/braincommon.lua（共享底座）,",
  "--           behaviours/{wander,runaway,doaction,chaseandattack,leash,",
  "--           follow,faceentity}.lua,",
  "--           util.lua:553-572（★ distsq 的双签名：4 数字=2D / 2 向量=3D）,",
  "--           components/{combat,eater,inventory,homeseeker,follower,",
  "--           knownlocations}.lua",
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