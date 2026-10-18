#!/usr/bin/env node
/**
 * build-revivablecorpse.mjs —— revivablecorpse.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-revivablecorpse.mjs 中，以「源文件行号」为锚点注入。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-revivablecorpse.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/revivablecorpse.lua";
const SPEC = join(__dirname, "spec-revivablecorpse.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/components/revivablecorpse.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/revivablecorpse.lua",
  "-- 模块：组件系统 / 可复活尸体（RevivableCorpse）",
  "-- 职责：DST「死亡 → 尸体 → 复活」链路的枢纽组件。提供四件事：",
  "--       ① 复活资格判定（CanBeRevivedBy，corpse 标签 + 自定义回调）；",
  "--       ② 复活速度倍率的标签化注册与撤销（SetReviveSpeedMultForTag/GetReviveSpeedMult）；",
  "--       ③ 复活后血量百分比（SetReviveHealthPercent/GetReviveHealthPercent）；",
  "--       ④ 推 respawnfromcorpse 事件，把实际复活交给 prefab 层。",
  "-- 【与幽灵机制互斥】gamemodes.lua:291 的原文注释：",
  "--   「revivablecorpse forces ghosts to be disabled」。",
  "--   玩家死亡要么变幽灵（ghost），要么留下可复活实体尸体，二者不共存。",
  "-- 【完整链路】挂载 player_common.lua:2482 → SetCorpse 打 corpse 标签 →",
  "--   客户端 playercontroller.lua:2061 决定显示 REVIVE_CORPSE →",
  "--   SGwilson.lua:8023 用 GetReviveSpeedMult 算按住时长 →",
  "--   actions.lua:4112 执行 Revive → respawnfromcorpse 事件 →",
  "--   player_common.lua:2670 → player_common_extensions.lua:443 完成复活与回血。",
  "-- 【客户端/服务端二分】ismastersim 缓存于第 6 行；写方法一律加守卫，",
  "--   只读判定（CanBeRevivedBy）故意不加，因为客户端 UI 决策需要它。",
  "-- 关键符号：RevivableCorpse, CanBeRevivedBy, SetCanBeRevivedByFn,",
  "--           SetReviveSpeedMult, SetReviveSpeedMultForTag, GetReviveSpeedMult,",
  "--           SetCorpse, Revive, SetReviveHealthPercent, GetReviveHealthPercent",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/health.lua（死亡判定与 IsDead）, components/talker.lua:273,",
  "--           components/playercontroller.lua:2001-2002、2061（客户端 UI 决策）,",
  "--           components/inventory_replica.lua:4（corpse 时隐藏背包）,",
  "--           actions.lua:4112-4120（REVIVE_CORPSE，失败静默）,",
  "--           componentactions.lua:736-737、gamemodes.lua:291（幽灵互斥）,",
  "--           stategraphs/SGwilson.lua:8023（复活时长计算）,",
  "--           prefabs/player_common.lua:2482、2670,",
  "--           prefabs/player_common_extensions.lua:131、443-448,",
  "--           prefabs/corpses_defs.lua、prefabs/corpses.lua（尸体构造）",
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
