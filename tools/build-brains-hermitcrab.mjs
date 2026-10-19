#!/usr/bin/env node
/**
 * build-brains-hermitcrab.mjs —— hermitcrabbrain.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-combat.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-brains-hermitcrab.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("brains/hermitcrabbrain.lua");
const SPEC = join(__dirname, "spec-brains-hermitcrab.mjs");
const OUT = relOut("brains/hermitcrabbrain.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：brains/hermitcrabbrain.lua",
  "-- 模块：AI 大脑 / 蟹壳怪（Hermit Crab，全 DST 最复杂的社交型 NPC）",
  "-- 职责：装配蟹壳怪 AI。★ 与其他大脑不同，它的独特之处在【社交层】：",
  "--       好感度驱动三档态度、台词按好感度二级选择、用「定时器名拼玩家 GUID」",
  "--       实现「对每个玩家分别记忆今天是否已打招呼」、茶会的选摊与级联清理、",
  "--       钓鱼时按鱼群密度择优、泡温泉/钓鱼/采收/扔瓶子等日常活动，",
  "--       以及雨天穿伞雪天穿外套这类「成对状态维护节点」。",
  "--       按 SOP 对 796 行的大文件只精读并注释核心决策函数（覆盖主干）。",
  "--",
  "-- 【★ 三级优先级结构（与 pigbrain 同款但多一层「不友好」层）】",
  "--   root（第 753 行）→ 跨人格节点（瞬移收尾/泡温泉/恐慌/躲猪/换装备/扔物/说完话）",
  "--     → day（第 681 行，含第 683 行的不友好子层）",
  "--     → night（第 743 行）",
  "--   day 与 night 的条件严格互补，且都考虑 AllNightTest（蟹壳怪可通宵营业）。",
  "--",
  "-- ⚠️ 已核实的遗留问题：第 533 行 CHATTERPARAMS_HIGH 定义后全文件未使用。",
  "-- 关键符号：HermitBrain, getfriendlevelspeech（好感度台词 ★）, GetFaceTargetFn,",
  "--           GetTraderFn, SelectTeaShop / ValidateTeaShops（茶摊集合管理）,",
  "--           DoFishingAction（按鱼群密度择优）, CanWanderAtPoint（夜光约束）,",
  "--           DoSoakin, DoHarvestMeat, GetFoodForCritter, RemoveActiveTeaShop,",
  "--           holding_umbrella / equipped_umbrella / has_umbrella（三态查询）",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：brain.lua（三段式调度）, brains/braincommon.lua（恐慌与帮工底座）,",
  "--           behaviours/{wander,follow,faceentity,chaseandattack,runaway,",
  "--           doaction,findlight,panic,chattynode,leash}.lua,",
  "--           components/{trader,inventory,friendlevels,npc_talker,locomotor,",
  "--           homeseeker,eater,petleash,knownlocations,timer}.lua,",
  "--           strings.lua（HERMITCRAB_GREETING / LEVEL10_* 等台词表）, tuning.lua",
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