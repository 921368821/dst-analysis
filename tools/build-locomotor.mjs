#!/usr/bin/env node
/**
 * build-locomotor.mjs —— health.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-entityscript.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-health-*.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-locomotor.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("components/locomotor.lua");
const SPEC = join(__dirname, "spec-locomotor.mjs");
const OUT = relOut("components/locomotor.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/locomotor.lua",
  "-- 模块：组件系统 / 移动（Locomotor）",
  "-- 职责：全游戏每个可移动实体的移动控制器。承担目的地抽象（Dest）、",
  "--       移动指令下达（GoToEntity / GoToPoint / WalkInDirection）、",
  "--       速度倍率合成（装备/鞍/地面/临时修正）、寻路结果跟随、",
  "--       路径跟随的转向决策、平台跳跃（hopping）扫描与预约、",
  "--       斜向测距转向（strafing）、移动计时器、客户端预测，",
  "--       以及与寻路器（TheWorld.Pathfinder，C++ 侧）的协作等职责。",
  "--       它只负责「怎么走过去」，不负责「该往哪走」——",
  "--       寻路求解与决策由 brain / stategraph / pathfinder 负责。",
  "-- 关键符号：LocoMotor, Dest, WalkForward, RunForward, WalkInDirection,",
  "--           GoToEntity, GoToPoint, PushAction, PreviewAction, Stop,",
  "--           OnUpdate, FindPath, GetRunSpeed, GetWalkSpeed, GetSpeedMultiplier,",
  "--           ScanForPlatform, StartHopping, SetExternalSpeedMultiplier,",
  "--           UpdateGroundSpeedMultiplier, SetAllowPlatformHopping,",
  "--           OverrideMoveTimer, PopOverrideTimeMoving, FinishHopping",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：util/sourcemodifierlist.lua（预测倍率容器）,",
  "--           components/walkableplatform.lua（可站平台与容量）,",
  "--           components/walkableplatformmanager.lua（平台注册表）,",
  "--           components/drownable.lua（落水判定）,",
  "--           components/amphibiouscreature.lua（两栖过渡）、",
  "--           components/embarker.lua（玩家登船）、",
  "--           components/health.lua（死亡中断移动）、",
  "--           components/playercontroller.lua（客户端预测与远端输入）、",
  "--           class.lua（属性 setter 机制）、physics.lua（碰撞回调）",
  "--           TheWorld.Pathfinder 是 C++ 侧寻路器，无 Lua 源码",
  "--============================================================",
  "",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const { HEADER_EXTRA, BEFORE, AFTER } = await import(specUrl);

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split("\n");
  expandKeysInPlace(BEFORE, srcLines, "BEFORE");   // 锚点键 → 行号键（M8）
  expandKeysInPlace(AFTER, srcLines, "AFTER");

  const out = [HEADER.replace(/\n$/, "")];
  if (HEADER_EXTRA && HEADER_EXTRA.length) {
    for (const h of HEADER_EXTRA) {
      assertComment(h, "HEADER_EXTRA");
      out.push(h);
    }
  }

  let injected = 0;

  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `BEFORE[${lineno}]`);
        out.push(c);
        injected++;
      }
    }

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
  for (const key of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
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
  const cross = (text.match(/参见 /g) || []).length;
  const commented = new Set([
    ...Object.keys(BEFORE).map(Number),
    ...Object.keys(AFTER).map(Number),
  ]);
  let cov = 0;
  for (const k of commented) if (k >= 1 && k <= srcLines.length) cov++;

  console.log(`✔ 已生成: ${OUT}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`);
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷⚠      : ${warn}`);
  console.log(`  交叉引用参见    : ${cross}`);
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
