#!/usr/bin/env node
/**
 * build-modindex.mjs —— modindex.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-modindex.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-modindex.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/modindex.lua";
const SPEC = join(__dirname, "spec-modindex.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/modindex.lua";

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：modindex.lua",
  "-- 模块：模组系统 / 中枢（发现、索引、筛选、加载模组）",
  "-- 职责：模组系统的中枢单例（KnownModIndex）。负责四阶段：",
  "--       1. 发现 —— TheSim:GetModDirectoryNames() 列出磁盘上的模组目录",
  "--       2. 索引 —— 在受限沙箱内读取并校验各模组的 modinfo.lua",
  "--       3. 筛选 —— GetModsToLoad 按启用来源 + 依赖 + standalone 规则决定装哪些",
  "--       4. 加载 —— 实际 require 各模组 modmain.lua 的工作由 mods.lua 承担",
  "-- ★★ 注意「索引」不等于「加载」：读 modinfo 不等于加载模组代码，",
  "--       这样模组列表界面无需加载任何模组代码即可快速展示。",
  "-- 关键符号：ModIndex（local 类 + 单例）, GetModsToLoad, UpdateModInfo,",
  "--           InitializeModInfo, LoadModOverides, ApplyEnabledOverrides,",
  "--           ApplyConfigOptionOverrides, BeginStartupSequence / EndStartupSequence,",
  "--           GetModDependencies, CacheSaveData / RestoreCachedSaveData,",
  "--           UpdateModSettings, ResolveModname, KnownAPIVersion, Save",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：mods.lua（实际加载模组代码的另一半）、",
  "--           modutil.lua（模组 API 表面与配置读取优先级）、",
  "--           netvars.lua:29-32（★模组使用 netvar 时两端必须装同一 MOD，",
  "--           直接决定同步层能否正常工作 —— 模组系统与网络层的强耦合点）、",
  "--           techtree.lua / strict.lua（沙箱需用 rawget 绕过 _G 检查）、",
  "--           shardindex.lua（集群槽位存档路径）",
  "-- 【★移植要点】① 「半途标记 + 启动自愈」的崩溃恢复机制（本文件第 97-123 行）；",
  "--   ② package.preload 劫持以静默接管旧依赖系统（第 7-37 行）；",
  "--   ③ 递归遍历依赖图必须自带 visited 集合防环（第 1150 行）；",
  "--   ④ 白名单沙箱只暴露「意图声明」函数，不授予能力（第 1108 行）。",
  "-- 【⚠️ 已知隐患】ApplyEnabledOverrides 与 ShardSaveIndex:SetSlotEnabledServerMods",
  "--   的数据格式强耦合且无自动校验，改一处忘另一处会静默失效。",
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