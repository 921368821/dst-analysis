#!/usr/bin/env node
/**
 * build-prefabs-boat.mjs —— prefabs/boat.lua 深度中文注释生成器（锚点注入法）
 *
 * 直接复制自 build-combat.mjs 并改写 SRC / SPEC / OUT / HEADER 四处。
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-prefabs-boat.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有一种：after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-prefabs-boat.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("prefabs/boat.lua");
const SPEC = join(__dirname, "spec-prefabs-boat.mjs");
const OUT = relOut("prefabs/boat.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：prefabs/boat.lua",
  "-- 模块：预制体层 / 移动平台（Boat）",
  "-- 职责：船族。DST 里最大的一族预制体，末尾一次注册 23 个平级实体。",
  "--       演示：资源/依赖/音效三层按变体切表、pre/post 两段式装配、",
  "--       数据表驱动变体、运行时程序化生成碰撞网格、变体派生变体。",
  "-- 关键符号：create_common_pre, create_master_pst, build_boat_collision_mesh,",
  "--           boat_player_collision_template, boat_item_collision_template,",
  "--           wood_fn, grass_fn, pirate_fn, ancient_fn, otterden_fn, ice_fn,",
  "--           ice_crabking_fn, item_fn, common_item_fn_pre, common_item_fn_pst,",
  "--           ondeploy, CLIENT_CanDeployBoat, SpawnFragment, AddConstrainedPhysicsObj,",
  "--           ReticuleTargetFn, DoSpawnIceTile, DoSpawnIceWall, otterden_on_update",
  "-- 变体清单：boat / boat_pirate / boat_ancient / boat_otterden / boat_grass /",
  "--           boat_ice / boat_ice_crabking（7 种船）+ 10 个碰撞体 + 3 个建造物品 +",
  "--           3 个放置预览（MakePlacer）",
  "-- 架构要点：",
  "--   · 每种船只写一张 XXX_BOAT_DATA 同构表 + 一个五步式 fn，共性全在 pre/post 两函数",
  "--   · create_common_pre 在 SetPristine 之前（两端跑，含网络组件与 net_bool 声明）",
  "--   · create_master_pst 在 SetPristine 之后（仅服务端，AddComponent + 状态图）",
  "--   · 碰撞体用 build_boat_collision_mesh 运行时生成三角网格，一套代码服务 5 种半径",
  "--   · ice_crabking_fn 直接调用 ice_fn() 再覆盖，是「变体派生变体」的范式",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：prefabs.lua（Prefab 全局工厂）, prefabutil.lua（MakePlacer）,",
  "--           prefabskins.lua（船与走路板的皮肤命名规则，第 1971-1980 行）,",
  "--           mainfunctions.lua:73（MINIMAP_IMAGE 在专服被跳过加载）,",
  "--           components/walkableplatform.lua, components/hullhealth.lua,",
  "--           components/boatphysics.lua, components/boatring.lua,",
  "--           components/healthsyncer.lua, components/reticule.lua,",
  "--           components/entitytracker.lua, components/repairable.lua,",
  "--           components/deployable.lua, components/fuel.lua,",
  "--           components/boattrail.lua, prefabs/treasurechest.lua（boat_ancient_container）,",
  "--           prefabs/crabking.lua（调用 boat_ice_crabking 与 boat.Physics）",
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
