#!/usr/bin/env node
/**
 * build-prefabs-pighouse.mjs —— prefabs/pighouse.lua 深度中文注释生成器（锚点注入法）
 *
 * 直接复制自 build-combat.mjs 并改写 SRC / SPEC / OUT / HEADER 四处。
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-prefabs-pighouse.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-prefabs-pighouse.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("prefabs/pighouse.lua");
const SPEC = join(__dirname, "spec-prefabs-pighouse.mjs");
const OUT = relOut("prefabs/pighouse.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/pighouse.lua",
  "-- 模块：预制体层 / 结构体（Structure）",
  "-- 职责：猪屋。演示一个「结构体」预制体的完整装配：",
  "--       6 个实体组件 + 1 套物理 + 2 个纯客户端子实体 + 1 个 placer，",
  "--       全部靠 AddComponent 拼装，不含任何类继承。",
  "--       是 DST「组合优于继承」在预制体层最纯粹的样本。",
  "-- 关键符号：OnUpdateWindow, LightsOn, LightsOff, onfar, onnear, getstatus,",
  "--           onoccupied, onvacate, onhammered, onstartdaylighttask,",
  "--           spawncheckday, oninit, MakeWindow, MakeWindowSnow,",
  "--           OnPreLoad, fn",
  "-- 架构要点：",
  "--   · fn() 的执行被 SetPristine 切成三段（A 段两端跑 / B 段快照 / C 段仅服务端）",
  "--   · MakeWindow / MakeWindowSnow 是纯客户端子实体：不 AddNetwork、persists=false",
  "--   · assets 是资源清单（动画包 / 音效包），prefabs 表是依赖清单（影响预加载与打包裁剪）",
  "--   · return 一次返回两个 Prefab：pighouse 本体 + MakePlacer 派生的放置预览幽灵",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：prefabs.lua（Prefab 全局工厂的实现）, prefabutil.lua（MakePlacer）,",
  "--           standardcomponents.lua（MakeObstaclePhysics / MakeSnowCoveredPristine /",
  "--           MakeMediumBurnable / MakeLargePropagator / SetLunarHailBuildupAmountLarge /",
  "--           MakeHauntableWork）,",
  "--           components/spawner.lua, components/workable.lua, components/lootdropper.lua,",
  "--           components/playerprox.lua, components/inspectable.lua, components/burnable.lua",
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
  // 防三条会破坏 Lua 语法的序列（详见 SOP 坑 6/7）
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
