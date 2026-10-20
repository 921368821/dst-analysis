#!/usr/bin/env node
/**
 * build-worldnetwork.mjs —— prefabs/world_network.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-worldnetwork.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-worldnetwork.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("prefabs/world_network.lua");
const SPEC = join(__dirname, "spec-worldnetwork.mjs");
const OUT = relOut("prefabs/world_network.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/world_network.lua",
  "-- 模块：网络同步层 / 世界网络实体的装配（TheWorld.net）",
  "-- 职责：装配全服共享的网络权威实体 TheWorld.net。演示三件事：",
  "--       1) 一个实体如何成为全服共享的网络根；",
  "--       2) ★AddShardClient 与 AddNetwork 两个正交维度如何组合成分片拓扑；",
  "--       3) ★SetPristine 如何划分「构造期」与「服务端专属期」的分界线。",
  "-- 本文件返回一个「工厂函数」而非实体，供各存档复用同一套装配逻辑。",
  "-- 关键符号：MakeWorldNetwork, PostInit, FlushLocalDirtyNetVars,",
  "--           OnRemoveEntity, DoPostInit, AddShardClient, AddNetwork,",
  "--           SetPristine, DoStaticTaskInTime",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：netvars.lua:44-47（脏值规则，本文件第 3 行是其官方 flush 出口）、",
  "--           netvars.lua:65-67（平滑计时器由客户端 set_local 预测的范式）、",
  "--           entityscript.lua（SetPristine 标志的同一机制）、",
  "--           components/clock.lua（本文件第 57 行装配的时钟，预测+纠偏范本）、",
  "--           components/worldvoter.lua / components/shard_worldvoter.lua（按分片分层）、",
  "--           prefabs/world.lua（调用本工厂的具体存档）",
  "-- 【★移植要点】① 两段式标签之外的第二个核心：所有 AddComponent 必须在",
  "--   SetPristine 之前完成，否则含 netvar 的组件只在服务端存在，",
  "--   两端 wire format 长度不一致会导致反序列化整体错位。",
  "--   ② ismastersim 与 TheNet:IsDedicated 是正交的两个维度，不可互相替代。",
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