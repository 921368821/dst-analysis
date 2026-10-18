#!/usr/bin/env node
/**
 * build-combat-replica.mjs —— combat_replica.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-combat-replica.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-combat-replica.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/components/combat_replica.lua";
const SPEC = join(__dirname, "spec-combat-replica.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/components/combat_replica.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：components/combat_replica.lua",
  "-- 模块：组件系统 / 战斗客户端镜像（Combat Replica）",
  "-- 职责：为客户端提供战斗的只读视图，使 UI、动画与状态机能本地预测",
  "--       「能否攻击」「目标是谁」「是否在冷却」，而不必复制战斗逻辑到客户端。",
  "--       与 combat.lua 的分工：combat.lua 是唯一权威，本文件只做展示与预测。",
  "--",
  "-- ★★★ 本文件的核心范式：三分支回退（server / client / none）",
  "--   几乎每个查询函数都是：",
  "--     if self.inst.components.combat ~= nil then  服务端：转发给真组件",
  "--     elseif self.classified ~= nil then           客户端：用镜像数据本地估算",
  "--     else                                        都不是：保守返回空",
  "--   → 组件的「接口」不区分端，只有「实现」区分。这是 DST 镜像模式最值得学处。",
  "--",
  "-- 与 container_replica.lua 的手法差异：",
  "--   container_replica 管背包（高频增删改）→ 需细粒度脏标记与增量同步；",
  "--   combat_replica     管攻击意图（低频整体态）→ 只需 4 个 net 变量（第 4-7 行）。",
  "--   → 镜像的数据量由「状态复杂度」决定，不由「原组件大小」决定。",
  "--",
  "-- 关键符号：Combat（与 combat.lua 同名，靠挂载位置区分）, SetTarget, GetTarget,",
  "--           SetLastTarget, IsRecentTarget, SetIsPanic, SetAttackRange,",
  "--           GetAttackRangeWithWeapon, GetWeaponAttackRange, GetWeapon,",
  "--           SetMinAttackPeriod, MinAttackPeriod, SetCanAttack, StartAttack,",
  "--           CancelAttack, InCooldown, CanAttack, LocomotorCanAttack,",
  "--           CanExtinguishTarget, CanLightTarget, CanHitTarget（已弃用）,",
  "--           IsValidTarget, CanTarget, CanBeAlly, IsAlly,",
  "--           TargetHasFriendlyLeader（已弃用）, CanBeAttacked,",
  "--           AttachClassified, DetachClassified, PushColour",
  "--",
  "-- ★设计提炼（详见正文中标注 ★★★ 的行）：",
  "--   1) 客户端预测的误差补偿（第 178 行减 .5）：客户端有位置预测，与服务端有偏差；",
  "--      不补偿就会出现「刀明明碰到却砍空」。代价是有效距离真的短了 0.5 码。",
  "--   2) 预测只记账不执行（第 136-141 行）：StartAttack 在客户端只记时间戳，",
  "--      用于本地算冷却；真正攻击仍由服务端 stategraph 驱动。",
  "--   3) 弃用的两种正当方式：CanHitTarget 是「整体弃用 + dev 分支 assert 拦截」（第 263-266 行），",
  "--      CanLightTarget 是「保留函数但简化实现」（第 253-261 行）。",
  "--      区别在于「客户端是否仍会调用」。选错会造成大量无谓报错。",
  "--   4) 镜像组件不需要 OnSave/OnLoad：数据来自 net 变量与 classified，断线自动重建。",
  "--",
  "-- ⚠️ 本文件已核实的问题（详见对应行）：",
  "--   - 第 459 行 `A and B or C` 无括号，当前逻辑正确但极易被后人「修正」成错误版本；",
  "--   - 第 178/196/280/308 行的命中范围基准不一致（带武器 vs 不带武器 vs 无 -.5 补偿）；",
  "--   - 第 19-31 行 OnRemoveFromEntity 与 OnRemoveEntity 两个卸载钩子**均被注释禁用**",
  "--     （SOP 坑 #4 典型：看着有实现，实际没跑）；",
  "--   - 第 11 行的 temp_iframes_keep_aggro 在本文件被读 3 次但从未赋值，完全依赖外部注入。",
  "--",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：components/combat.lua（第 348 行服务端 IsRecentTarget，用 GUID 比较更健壮；",
  "--           第 263 行同款 dev 分支弃用断言）, components/inventory_replica.lua,",
  "--           components/follower_replica.lua（GetLeader 盟友判定）、",
  "--           components/rider_replica.lua（IsRiding 骑乘过滤）、",
  "--           components/sanity_replica.lua（IsCrazy / IsSane 影子与幽灵可见性）、",
  "--           components/inventoryitem_replica.lua（第 375 行 AttackRange）、",
  "--           components/builder_replica.lua / constructionsite_replica.lua",
  "--           （第 11-13 行同款 classified 晚到补挂模板）、",
  "--           entityscript.lua（第 1980-1981 行 OnLoad 约定；第 208-214 行 replica_mt 校验）、",
  "--           constants.lua（第 4 行 BRANCH 常量，dev/staging/production 三档）",
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