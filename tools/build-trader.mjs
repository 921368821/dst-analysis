#!/usr/bin/env node
/**
 * build-trader.mjs —— trader.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-trader.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-trader.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/trader.lua");
const SPEC = join(__dirname, "spec-trader.mjs");
const OUT = relOut("components/trader.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/trader.lua",
  "-- 模块：组件系统 / 商人（Trader）",
  "-- 职责：NPC「愿不愿意收玩家的东西」判定与执行 —— 双层闸门（物理能力",
  "--       AbleToAccept / 意愿 WantsToAccept）、赠送事务（AcceptGift 的拆堆取物、",
  "--       销毁或转交背包、prevslot 回滚防护）、mimic 拒收、启用与标签同步。",
  "-- 【★★ 核心设计：物理闸门 与 意愿闸门 的双层拆分】",
  "--   AbleToAccept  = 物理能力（死了？在睡？状态机 busy？），返回 (bool, reason)，",
  "--                  reason 会被动作层消费并显示给玩家。",
  "--   WantsToAccept = 意愿（觉得恶心吗？），返回布尔，【不】产生失败原因，",
  "--                  只触发 onrefuse 表现回调。",
  "--   把二者合并就只会得到一种含糊的失败提示 —— 这是本文件最值得学的一点。",
  "-- 【★ 回调语义不对称】SetAcceptTest 是【追加】在物理闸门之后；",
  "--   SetAbleToAcceptTest 是【替换】整个物理闸门（第 111-112 行 elseif），",
  "--   一旦设置，第 113-119 行的 DEAD/SLEEPING/BUSY 默认检查全部失效。",
  "-- 关键符号：Trader, AbleToAccept, WantsToAccept, AcceptGift, IsTryingToTradeWithMe,",
  "--           SetAcceptTest, SetAbleToAcceptTest, SetOnAccept, SetOnRefuse,",
  "--           SetAcceptStacks, IsAcceptingStacks, Enable, Disable, GetDebugString,",
  "--           enabled, acceptnontradable, deleteitemonaccept, acceptsmimics",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：actions.lua（GIVE/GIVETOPLAYER/GIVEALLTOPLAYER 四处调用点）、",
  "--           componentactions.lua（客户端动作表与 alltrader 标签消费）、",
  "--           components/stackable.lua（Get 拆堆的语义）、",
  "--           components/container.lua:1451 与 components/inventory.lua",
  "--           （prevslot/prevcontainer 的写入与回滚消费）、",
  "--           components/itemmimic.lua（拟态怪判定）、",
  "--           prefabs/beefalo.lua、bunnyman.lua、catcoon.lua、carnival_crowkid.lua",
  "--           （deleteitemonaccept=false 的典型用法）",
  "--           prefabs/player_common.lua:2802 与 prefabs/wx78_possessedbody.lua:627",
  "--           （acceptsmimics=true 的唯二开启点）",
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
