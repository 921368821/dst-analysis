#!/usr/bin/env node
/**
 * build-weather.mjs —— weather.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-weather.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-weather.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/weather.lua");
const SPEC = join(__dirname, "spec-weather.mjs");
const OUT = relOut("components/weather.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/weather.lua",
  "-- 模块：组件系统 / 天气（Weather），挂在世界实体上",
  "-- 职责：降水生命周期（湿度累积/耗尽 → 晴雨雨雪切换）、温度驱动的雨雪转换、",
  "--       月石雨（rift）、积雪与融雪、地面材质叠加、屏幕光照、地面湿度、",
  "--       四层雨声（环境/树上/伞/雨穹屏障）、闪电落点仲裁、以及每次 OnUpdate",
  "--       末尾向世界广播 weathertick 供他方消费。",
  "--",
  "-- 【★ 最该学的三件事】",
  "--  1) 双端自治 + 周期性对齐的同步模型（第 356 行 SetWithPeriodicSync）：",
  "--     连续量按时间分桶，桶内客户端 set_local 自治，跨桶服务端校准；",
  "--     兼顾平滑、极低带宽、且不永久漂移。",
  "--  2) 权限边界清晰：客户端只能演化连续量，绝不 set 离散状态；",
  "--     「开始/停止降水、切雨雪、发闪电」一律只在服务端，",
  "--     外部只能通过 ms_* 前缀事件请求（第 789-826 行）。",
  "--  3) 计算与副作用分离：Calculate* 系列（400-489 行）全是只读纯函数，",
  "--     因此 GetDebugString 可安全复用而不改变状态。",
  "--",
  "-- 【重要纠偏】season 组件才是季节节拍的产生者，本文件【没有】任何",
  "--       季节计时器；它是 seasontick 的订阅方（第 783 行）。",
  "--       另：本文件不与 sanity.lua 直接联动（sanity.lua 不读 weather 任何量）；",
  "--       真实消费者是 ambientlighting.lua(274)、ambientsound.lua(267)、",
  "--       colourcube.lua(458)、dsp.lua(191)、beargerspawner.lua(440)。",
  "-- 关键符号：SetWithPeriodicSync, CalculatePrecipitationRate, CalculatePOP,",
  "--           CalculateLight, CalculateWetnessRate, PushWeather, OnSeasonTick,",
  "--           OnSendLightningStrike, SetStrikePositionAndPrefab, OnSimUnpaused,",
  "--           SetGroundOverlay, StartPrecipitation, StopPrecipitation,",
  "--           StartLunarHail, StopLunarHail, ForceResync, OnUpdate, OnSave, OnLoad",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/season.lua（seasontick 产生者，季节节拍源头）,",
  "--           components/caveweather.lua（洞穴版独立天气，同监听 temperaturetick）,",
  "--           components/environmentdelta.lua（temperaturetick 产生者，温度真值）,",
  "--           components/sanity.lua（不直接依赖本组件，环境温度另走他路）,",
  "--           components/ambientlighting.lua / ambientsound.lua（weathertick 消费者）,",
  "--           components/moonstorms.lua + riftspawner.lua（月石雨触发源）,",
  "--           components/sandstorms.lua（沙暴抑制花粉，第 1070 行）,",
  "--           prefabs rain/snow/pollen/lunarhail（客户端表现层 fx）",
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
