#!/usr/bin/env node
/**
 * build-prefabs-umbrella.mjs —— prefabs/umbrella.lua 深度中文注释生成器（锚点注入法）
 *
 * 直接复制自 build-combat.mjs 并改写 SRC / SPEC / OUT / HEADER 四处。
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-prefabs-umbrella.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-prefabs-umbrella.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("prefabs/umbrella.lua");
const SPEC = join(__dirname, "spec-prefabs-umbrella.mjs");
const OUT = relOut("prefabs/umbrella.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/umbrella.lua",
  "-- 模块：预制体层 / 可装备物品（Equipable Item）",
  "-- 职责：雨伞与草伞。装备类预制体的最小完整样本（195 行），",
  "--       补齐前五个文件未覆盖的第六个维度：玩家背包里的东西。",
  "-- 关键符号：onequip, onunequip, onequiptomodel, onequip_grass,",
  "--           onunequip_grass, onperish, common_fn, grass, pigskin",
  "-- 变体清单（return 段仅 2 个预制体，共享同一份 assets 表）：",
  "--   umbrella         —— 第 168 行 pigskin 函数（★ 函数名与预制体名不同）",
  "--   grass_umbrella   —— 第 132 行 grass 函数（模型名 parasol，与函数名也不同）",
  "-- 架构要点：",
  "--   · 装备回调改的是「持有者」（owner）而非物品本身：换持有者的 swap 符号、",
  "--     ARM_carry/ARM_normal 动画片段、DynamicShadow 阴影尺寸",
  "--   · ★ 第 105-106 行 waterproofer 标签「偷渡」进 pristine 状态 ——",
  "--     组件只在服务端挂，但标签能过 SetPristine，与 deciduoustrees 的 __combat 同一手法",
  "--   · 两种消耗模式对照：perishable（草伞，按时间）与 fueled（猪皮伞，按使用量）",
  "--   · 「雨伞耗尽」是跨系统事件（umbrellaranout），玩家 / 三件伞类物品 / 蟹的状态图都监听它",
  "--   · 6 个组件构成一个完整可装备物品，无类无继承：判定「能做什么」只需查组件",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：prefabs.lua（Prefab 全局工厂）,",
  "--           prefabutil.lua（MakeInventoryPhysics / MakeInventoryFloatable 的上游）,",
  "--           standardcomponents.lua（MakeSmallBurnable / MakeSmallPropagator /",
  "--           MakeHauntableLaunch）,",
  "--           components/equippable.lua（dapperness 在第 37、197-204 行）,",
  "--           components/inventoryitem.lua, components/waterproofer.lua",
  "--           （第 5 行 V2C 注释与第 7、15 行的标签管理）,",
  "--           components/perishable.lua, components/fueled.lua, components/fuel.lua,",
  "--           components/floater.lua（SetBankSwapOnFloat 第 89 行、",
  "--           swap_data 字段回落第 134、198-199 行）,",
  "--           components/insulator.lua, components/tradable.lua,",
  "--           prefabs/player_common.lua:667（umbrellaranout 监听）,",
  "--           prefabs/hats.lua:1321、prefabs/voidcloth_umbrella.lua:133（同事件发出方）,",
  "--           stategraphs/SGhermitcrab.lua:435（同事件监听方）",
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
  expandKeysInPlace(AFTER, srcLines, "AFTER");

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
