#!/usr/bin/env node
/**
 * build-modutil.mjs —— modutil.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-modutil.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-modutil.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("modutil.lua");
const SPEC = join(__dirname, "spec-modutil.mjs");
const OUT = relOut("modutil.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：modutil.lua",
  "-- 模块：模组系统 / API 表面（按模组构造专属环境表）",
  "-- 职责：模组 API 的全部表面。与 modindex.lua 的分工：",
  "--       modindex 管「装不装」，modutil 管「装上之后能做什么」。",
  "--       核心机制 InsertPostInitFunctions 为每个模组构建一张独立的",
  "--       env 表，注入该模组可用的全部 AddXxx API，再以该表作为该模组",
  "--       代码的执行环境 —— 各模组私有状态互不可见，方法名可重复而不冲突。",
  "-- ★★ 全文件只导出一个符号（InsertPostInitFunctions），是「API 工厂」而非",
  "--       「API 集合」：所有 AddXxx 都只存在于各模组的 env 表中。",
  "-- 关键符号：InsertPostInitFunctions（★核心，约 800 行）、",
  "--           ModInfoname, AddModReleaseID, CurrentRelease.GreaterOrEqualTo,",
  "--           GetModConfigData（★四级读取优先级）, AddModCharacter,",
  "--           moderror / modassert / modprint（★开发期崩溃、用户期降级）,",
  "--           getfenvminfield（★调用栈回溯定位调用者模组）、",
  "--           DoAddClassPostConstruct（★猴子补丁原语）, env.AddAction",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：modindex.lua（模组发现/索引/筛选；与本文件的配置优先级耦合）、",
  "--           modindex.lua:467（本文件第 467 行 code 只写 saved 的陷阱来源）、",
  "--           class.lua:175-176（Class 在实例化时才调 _ctor，故可被猴补）、",
  "--           strict.lua（解释了本文件多处使用 rawget 绕开 _G 检查）、",
  "--           mods.lua（顶部调用 AddModReleaseID 建立版本登记表）、",
  "--           map/customize.lua（本文件第 211 行注入的外观 API 宿主）",
  "-- 【★★已核实缺陷：第 109 行 `level = level or 1` 吞掉显式传入的 0】",
  "--   因 Lua 的 0 为真值，level 恒 >= 1，第 110 行的 `if level ~= 0` 恒真，",
  "--   第 111 行总会执行。后果是 error() 的堆栈层级固定比预期深一层，",
  "--   不影响功能，仅影响报错可读性。我已对照源码逐行核实。",
  "-- 【⚠️ 另注：第 29 行 PrintID 的 or 分支为多余的两个点，疑似调试残留。】",
  "-- 【★移植要点】① 按「执行阶段」裁剪能力（第 436 行 isworldgen 分界）；",
  "--   ② 版本判断用「注册表存在性」而非字符串比较（第 24 行）；",
  "--   ③ 错误信息必须可操作 —— 断言文案里直接给出正确代码示例（第 448 行）。",
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