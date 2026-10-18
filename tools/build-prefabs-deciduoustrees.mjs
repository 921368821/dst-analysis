#!/usr/bin/env node
/**
 * build-prefabs-deciduoustrees.mjs —— prefabs/deciduoustrees.lua 深度中文注释生成器（锚点注入法）
 *
 * 直接复制自 build-combat.mjs 并改写 SRC / SPEC / OUT / HEADER 四处。
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-prefabs-deciduoustrees.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-prefabs-deciduoustrees.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/prefabs/deciduoustrees.lua";
const SPEC = join(__dirname, "spec-prefabs-deciduoustrees.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/prefabs/deciduoustrees.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/deciduoustrees.lua",
  "-- 模块：预制体层 / 植被（Tree）",
  "-- 职责：落叶树。演示「运行时形态可变的预制体」：",
  "--       长势（短/中/高）× 季节叶色（常绿/彩色/光秃/毒）× 怪物化 × 砍伐 × 烧毁，",
  "--       两条正交状态轴 + 组件动态装卸 + 休眠时卸载能力。",
  "-- 关键符号：builds（颜色系表）, makeanims, GetBuild, SpawnLeafFX, PushSway, Sway,",
  "--           UpdateIdleLeafFx, GrowLeavesFn, OnChangeLeaves, SetShort/SetNormal/SetTall,",
  "--           growth_stages, chop_tree, make_stump, chop_down_tree,",
  "--           StartMonster/StopMonster/DoStartMonster/DoStopMonster,",
  "--           OnEntitySleep/OnEntityWake, OnTimerDone, onsave/onload,",
  "--           OnSeasonChanged, ChangeToSeason, OnCyclesChanged, makefn, tree",
  "-- 变体清单（return 派生 6 个）：",
  "--   deciduoustree / _normal / _tall / _short / _burnt / _stump",
  "-- 架构要点：",
  "--   · 颜色系（6 种）不是 6 个预制体，而是 inst.build 字段的取值（第 1310 行 SetPrefabName",
  "--     统一为 deciduoustree）—— 预制体名 = 身份，外观 = 状态",
  "--   · 渲染三层递进：改 bank（形态级）/ 改 build（贴图级）/ OverrideSymbol（季节级）",
  "--   · target_leaf_state 与 leaf_state 分离，让异步过渡（11 秒动画）可中断与重定向",
  "--   · make_stump 是「同一实体原地变形态」的范本：换组件等级、换物理、换交互方式",
  "--   · OnEntitySleep 卸载 burnable/propagator/inspectable，OnEntityWake 严格镜像重建",
  "--   · 存档只存状态描述与相对时间，不存 GetTime 绝对值",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：prefabs.lua（Prefab 全局工厂）, prefabutil.lua,",
  "--           standardcomponents.lua（MakeObstaclePhysics / MakeSnowCoveredPristine /",
  "--           MakeLargeBurnable / MakeMediumPropagator / MakeWaxablePlant /",
  "--           RemovePhysicsColliders / SetLunarHailBuildupAmount*）,",
  "--           components/growable.lua, components/plantregrowth.lua, components/timer.lua,",
  "--           components/lootdropper.lua, components/workable.lua, components/cattoy.lua,",
  "--           components/burnable.lua, components/combat.lua,",
  "--           components/deciduoustreeupdater.lua,",
  "--           stategraphs/SGdeciduoustree.lua, tuning.lua:2892（怪物概率阈值表）",
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
