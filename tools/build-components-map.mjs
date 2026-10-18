#!/usr/bin/env node
/**
 * build-components-map.mjs —— components/map.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-components-map.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * ⚠️ 命名说明：本工程已有 build-map.mjs，那是 map/ 目录（storygen/forest/
 *    network/graphnode/task 等）的批量构建器，与本文件无关，切勿混淆。
 *
 * 用法：node build-components-map.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/map.lua";
const SPEC = join(__dirname, "spec-components-map.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/components/map.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/map.lua",
  "-- 模块：地图服务层 / Map 类的全局扩展（⚠️ 不是组件）",
  "-- 职责：把「生成数据」翻译成「可否通行 / 可否建造」的空间查询服务。",
  "--       ① 地块谓词（IsXxxAtPoint 系列，40-187 行）；",
  "--       ② 建造合法性判定与间距计算（189-745 行，本文件算法核心）；",
  "--       ③ 空间采样：方形螺旋找水、随机点、视觉节点归属（747-1116 行）；",
  "--       ④ 竞技场出生点的增量扫描与四级降级搜索（1122-1449 行）；",
  "--       ⑤ DLC 区域（WagPunk 竞技场 / Vault 金库）转发查询（1453-1569 行）。",
  "-- 【重要纠偏】本文件【没有】世界生成落地、季节视觉刷新、洞穴地表切换、",
  "--       资源散布、OnSave/OnLoad。全文件无 Class( ) 包装、无 AddComponentPostInit、",
  "--       无任何 net_* 声明。地图生成见 map/storygen.lua，季节见 components/seasons.lua。",
  "-- 【文件形态】猴补丁扩展：require \"map/terrain\" 引入全局 Map 类后，",
  "--       用 function Map:Xxx(...) 直接挂方法（第 1 行 + 3-8 行是唯一的改写）。",
  "--       唯一被改写语义的是 Map:SetTile —— 补发全局事件 \"onterraform\"。",
  "-- 关键符号：SetTile, IsPassableAtPointWithPlatformRadiusBias, IsDeployPointClear,",
  "--           IsDeployPointClear2, IsNearOther, IsNearOther2, CanDeployAtPoint,",
  "--           CanDeployWallAtPoint, CanDeployDockAtPoint, CanDeployBridgeAtPointWithFilter,",
  "--           IsSurroundedByWater/Land/LandNoDocks, GetNearbyOceanPointFromXZ,",
  "--           GetNearestPlatformInDirection, FindVisualNodeAtPoint, IsInLunacyArea,",
  "--           GetLunacyAreaModifier, StartFindingGoodArenaPoints,",
  "--           FindBestSpawningPointForArena, IsPointInAnyVault",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：map/terrain.lua（Map 类本体 + terrain.filter 生成表）,",
  "--           tilegroups.lua（TileGroupManager，tile 分组判定）,",
  "--           components/placer.lua（放置流程，本文件提供判定）,",
  "--           components/season.lua（季节；本文件不含季节逻辑）,",
  "--           components/moonstorms.lua（经 world.net 读月爆区域）,",
  "--           world net components wagpunk_floor_helper / vault_floor_helper（DLC 区域）",
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
