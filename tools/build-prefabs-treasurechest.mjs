#!/usr/bin/env node
/**
 * build-prefabs-treasurechest.mjs —— prefabs/treasurechest.lua 深度中文注释生成器（锚点注入法）
 *
 * 直接复制自 build-combat.mjs 并改写 SRC / SPEC / OUT / HEADER 四处。
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-prefabs-treasurechest.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-prefabs-treasurechest.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("prefabs/treasurechest.lua");
const SPEC = join(__dirname, "spec-prefabs-treasurechest.mjs");
const OUT = relOut("prefabs/treasurechest.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/treasurechest.lua",
  "-- 模块：预制体层 / 容器（Container）",
  "-- 职责：宝箱族。用 MakeChest 工厂派生 5 个宝箱变体 + 1 个独立特效实体，",
  "--       演示「预制体工厂 + 变体钩子（common_postinit / master_postinit）」模式，",
  "--       是预制体层实现配置化差异的标准范式。",
  "-- 关键符号：SOUNDS, onopen, onclose, onhammered, onbuilt, onsave, onload,",
  "--           ChestsWithoutIcons, MakeChest, regular_ShouldCollapse,",
  "--           regular_ConvertToCollapsed, OnUpgrade, DoUpgradeVisuals,",
  "--           pandora_master_postinit, minotuar_master_postinit,",
  "--           terrarium_master_postinit, terrariumchest_fx_fn,",
  "--           sunken_master_postinit, ancient_container_master_postinit",
  "-- 变体清单（return 段共注册 9 个平级实体）：",
  "--   treasurechest / treasurechest_placer / pandoraschest / minotaurchest /",
  "--   terrariumchest / terrariumchest_fx / sunkenchest / boat_ancient_container",
  "-- 架构要点：",
  "--   · 主干 fn() 只写共性，变体差异通过两个后置钩子注入：",
  "--     common_postinit 在 SetPristine 之前（两端都跑，可设被网络快照带走的字段）",
  "--     master_postinit 在 SetPristine 之后（仅服务端，可 AddComponent / 覆写 OnSave）",
  "--   · assets 用 JoinArrays 合并「文件级 + 变体级」两层资源清单",
  "--   · 实例上的音效走 inst.sounds 表，变体可整表替换而回调一行不改",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：prefabs.lua（Prefab 全局工厂）, prefabutil.lua（MakePlacer）,",
  "--           standardcomponents.lua（MakeSmallBurnable / MakeMediumPropagator /",
  "--           MakeSnowCoveredPristine / SetLunarHailBuildupAmountSmall）,",
  "--           components/container.lua（WidgetSetup / canbeopened / infinite stacksize）,",
  "--           components/upgradeable.lua, components/workable.lua, components/lootdropper.lua,",
  "--           components/scenariorunner.lua, components/equippable.lua,",
  "--           components/submersible.lua, fx.lua（chestupgrade_stacksize_fx）,",
  "--           messagebottletreasures.lua（sunkenchest 的依赖清单来源）",
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
