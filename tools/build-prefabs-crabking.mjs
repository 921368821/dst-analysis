#!/usr/bin/env node
/**
 * build-prefabs-crabking.mjs —— prefabs/crabking.lua 深度中文注释生成器（锚点注入法）
 *
 * 直接复制自 build-combat.mjs 并改写 SRC / SPEC / OUT / HEADER 四处。
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-prefabs-crabking.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-prefabs-crabking.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/prefabs/crabking.lua";
const SPEC = join(__dirname, "spec-prefabs-crabking.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/prefabs/crabking.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/crabking.lua",
  "-- 模块：预制体层 / Boss（蟹王）",
  "-- 职责：蟹王。DST 里「一个实体同时管理 20+ 个子实体」的极限样本。",
  "--       演示：把 30 多个内部函数挂到 inst 上作为公开 API、子实体集群的手写 GUID 存档、",
  "--       宝石插槽系统、阶段式技能调度、跨预制体协作。",
  "-- 关键符号：SetSharedLootTable, SocketItem, AddSocketDecoration, ShineSocketOfColor,",
  "--           RetargetFn, CleanUpArena, OnEntitySleep, OnSave, OnLoadPostPass,",
  "--           LaunchCrabMob, RemoveIceInRadius, RemoveIceArena, CleanUpAreaForIceTile,",
  "--           DoSpawnIceTile, DoSpawnIceWall, EndCastSpell, SpawnCannonTower,",
  "--           DropSocketedGems, RemoveGem, AddGem, UpdateGemCount,",
  "--           fn, geyserfn, chipfn, burble, endgeyser",
  "-- 变体清单（return 段共 6 条声明，1 条被注释，实际注册 5 个实体）：",
  "--   crabking / crabking_geyserspawner / crabking_chip_high / _med / _low",
  "-- 架构要点：",
  "--   · 第 1637-1686 行把 30 多个函数挂到 inst 上，分「外部 / 内部 / 事件适配」三组，",
  "--     这是 DST 里跨预制体协作的标准手段，等价于「类的 public 方法」但无类无继承",
  "--   · 第 1683-1686 行的事件适配包装解决两个问题：回调签名不匹配、",
  "--     注册与解除必须是同一个函数对象（否则 RemoveEventCallback 静默失败）",
  "--   · OnSave 返回 GUID 表 + OnLoadPostPass 用 newents 还原，是「子实体集群存档」范式",
  "--   · 第 704-710 行读档时补挂 crabking_spawner，是「版本兼容补丁」的范式",
  "--   · 每颗宝石按颜色改变 Boss 技能强度，让玩家的「准备投入」直接转化为战斗强度",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：prefabs.lua（Prefab 全局工厂）,",
  "--           brains/crabkingbrain.lua（AI 决策，与预制体严格分层）,",
  "--           stategraphs/SGcrabking.lua（行为状态机）,",
  "--           components/trader.lua（宝石插槽借用了「接受物品」能力）,",
  "--           components/entitytracker.lua, components/combat.lua,",
  "--           components/lootdropper.lua, components/inspectable.lua,",
  "--           components/freezable.lua, components/complexprojectile.lua,",
  "--           components/oceanfishable.lua（决定实体能否被「弹飞」）、",
  "--           prefabs/boat.lua（InstantlyBreakBoat 定义处 / boat_ice_crabking 场地）,",
  "--           prefabs/moon_altar.lua（宝石图腾，第 28 行 prefabs 清单里的",
  "--           moon_altar_cosmic / moon_altar_crown 由该文件派生）",
  "--============================================================",
  "",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (t !== "" && !t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
  if (line.includes("\uFFFD")) {
    throw new Error(`规格错误 @${where}: 含 U+FFFD 替换字符（编码损坏）-> ${line}`);
  }
  if (line.includes("--[[")) throw new Error(`规格错误 @${where}: 含块注释起始序列`);
  if (line.includes("]]")) throw new Error(`规格错误 @${where}: 含块注释结束序列`);
  if (line.includes("\\r")) throw new Error(`规格错误 @${where}: 含反斜杠 r 转义`);
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const mod = await import(specUrl);
  const AFTER = mod.default; // { 行号: [注释行...] }

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split(/\r?\n/);
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
