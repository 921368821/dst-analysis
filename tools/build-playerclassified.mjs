#!/usr/bin/env node
/**
 * build-playerclassified.mjs —— prefabs/player_classified.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-playerclassified.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-playerclassified.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/prefabs/player_classified.lua";
const SPEC = join(__dirname, "spec-playerclassified.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/prefabs/player_classified.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/player_classified.lua",
  "-- 模块：网络同步层 / 玩家同步状态宿主（classified 实体，1669 行）",
  "-- 职责：全工程 net_* 声明密度最高的单文件（123 处，第 1330-1633 行）。",
  "--       把玩家的全部共享状态（生命/饥饿/理智/温度/湿度/配方/科技树/",
  "--       相机/HUD/战斗/骑乘/移动速度/死亡原因等）集中挂在一个 classified",
  "--       网络实体上，作为「服务端权威、全服可见」的同步载体。",
  "-- ★ 与玩家实体（player.lua）的分工：classified 上的 netvar = 全服可见；",
  "--   玩家实体自身的字段 = 本地私有。这是「可见性分区」的设计。",
  "-- ★ 演示了 dirty 事件的「三段式分发」：",
  "--   玩家实体本地事件 -> 服务端压进布尔 netvar（SetDirty 强制置脏）",
  "--   -> 客户端脏事件消费 -> PushEvent 给玩家实体 -> UI/动画/音效。",
  "-- 关键符号：SetDirty（强制置脏，18 处）, OnEntityReplicated,",
  "--           RegisterNetListeners_mastersim / _local / _common,",
  "--           OnInitialDirtyStates, FinishSeamlessPlayerSwap,",
  "--           craftinglimit_net_enum, SetOldagerRate / GetOldagerRate,",
  "--           DeserializeTemperature, PushPausePredictionFrames",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：netvars.lua（类型契约、set_local 警告、数组类型注意事项）、",
  "--           netvars.lua:97 GetIdealUnsignedNetVarForCount（本文件 1535 行唯一用处）、",
  "--           entityreplica.lua:87-95 classified 机制与 TryAttachClassifiedToReplicaComponent、",
  "--           entityreplica.lua:82 OnEntityReplicated 钩子（本文件 247 行即其实现）、",
  "--           entityscript.lua（玩家实体侧的组件与事件源）、",
  "--           techtree.lua（BONUS_TECH / AVAILABLE_TECH 为有序数组，故可用 ipairs）、",
  "--           components/clock.lua:161 ForceResync（与本文件 SetDirty 同构的原语）",
  "-- 【★移植要点】① 「声明 + 立即赋初值」应视为一体，否则首帧读到 nil。",
  "--   ② 123 处 netvar 必须全部位于 SetPristine 之前，否则两端 wire format",
  "--      长度不一致会导致反序列化整体错位，且报错点与出错点相距很远。",
  "--   ③ 增量同步必须配「强制全量重算」（本文件 OnInitialDirtyStates），",
  "--      否则当初值恰好等于默认值时客户端会漏掉初始化，表现为偶发 UI 不刷新。",
  "--   ④ 一次性网络事件要「收到即消费」，不能在发送端预复位，否则高频连发丢事件。",
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