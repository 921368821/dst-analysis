#!/usr/bin/env node
/**
 * build-entityreplica.mjs —— entityreplica.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-entityreplica.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-entityreplica.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/entityreplica.lua";
const SPEC = join(__dirname, "spec-entityreplica.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/entityreplica.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：entityreplica.lua",
  "-- 模块：网络同步层 / replica（副本组件）分发链路",
  "-- 职责：回答「服务端如何决定谁能看到什么」。以实体标签（tag）而非网络消息",
  "--       驱动 replica 分发：维护 19 个可同步组件的白名单，用 _name / __name",
  "--       两段式标签协议表达「需要同步 / 显式不要同步」，",
  "--       并在客户端实体标签反序列化完毕后据此创建副本组件。",
  "-- ★★ 与 netvars.lua 构成本层仅有的两个「有实义」的 Lua 文件；",
  "--       其余网络逻辑都建立在 C++ 侧的 TheNet 之上。",
  "-- 关键符号：REPLICATABLE_COMPONENTS, Replicas,",
  "--           EntityScript:ValidateReplicaComponent,",
  "--           EntityScript:ReplicateComponent,",
  "--           EntityScript:UnreplicateComponent,",
  "--           EntityScript:PrereplicateComponent,",
  "--           EntityScript:ReplicateEntity,",
  "--           EntityScript:TryAttachClassifiedToReplicaComponent,",
  "--           AddReplicableComponent",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：entityscript.lua:208-213（replica_mt 惰性代理元表）、",
  "--           entityscript.lua:631（AddComponent 自动申请同步）、",
  "--           netvars.lua（类型契约与 wire format 规则）、",
  "--           class.lua:176（Class 构造器调用约定）、",
  "--           prefabs/player_classified.lua（classified 机制最大实例）",
  "-- 【移植要点】两段式标签协议用「__ 否定项」表达删除，是增量属性同步里",
  "--           「墓碑（tombstone）」思路的轻量实现，避免整表重发。",
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