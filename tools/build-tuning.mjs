#!/usr/bin/env node
/**
 * build-tuning.mjs —— tuning.lua 深度中文注释生成器（锚点注入法）
 *
 * 设计目标：从根本上杜绝「手抄代码行出错」。
 *   · 可执行代码行 100% 来自源文件，逐字节原样复制，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-tuning-pN.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，故 Lua 语义绝对不受影响。
 *
 * tuning.lua 是纯数据表（9581 行 / 4202 个顶层键），逐行注释既无必要也无价值。
 * 因此本文件的注释策略是：
 *   ★ 重心放在「组织方式」—— 文件头的分区导航表 + 分区边界注释
 *   ★ 重心放在「表达方式」—— 归一化 vs 绝对值这一设计洞察
 *   ★ 重心放在「代表性条目」—— 每区挑最能说明设计意图的条目深讲
 *
 * 用法：node build-tuning.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/tuning.lua";
const OUT = "E:/DST-Analysis/02-注释源码/scripts/tuning.lua";

/** 12 个分段 spec，与源文件 12 个行号区间一一对应 */
const SPECS = Array.from({ length: 12 }, (_, i) =>
  join(__dirname, `spec-tuning-p${i + 1}.mjs`)
);

/** 文件头（分区导航表等）—— 单独一份，内容很长 */
const HEADER_SPEC = join(__dirname, "spec-tuning-header.mjs");

/** 校验一行插入内容确实是合法注释（开发期自检，防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function main() {
  // 文件头（分区导航表）
  const hdr = await import(pathToFileURL(HEADER_SPEC).href + `?v=${Date.now()}`);
  // HEADER 导出的是「已用换行拼接好的整段字符串」
  const HEADER = typeof hdr.HEADER === "string" ? hdr.HEADER.split("\n") : hdr.HEADER;
  if (!Array.isArray(HEADER)) throw new Error("spec-tuning-header.mjs 未导出 HEADER");

  // 合并全部 spec 的 BEFORE / AFTER（行号唯一，各 spec 负责不同区间）
  let BEFORE = {};
  let AFTER = {};
  for (const sp of SPECS) {
    const m = await import(pathToFileURL(sp).href + `?v=${Date.now()}`);
    for (const [k, v] of Object.entries(m.BEFORE || {})) {
      if (BEFORE[k]) throw new Error(`行号 ${k} 在多个 spec 中重复定义 BEFORE`);
      BEFORE[k] = v;
    }
    for (const [k, v] of Object.entries(m.AFTER || {})) {
      if (AFTER[k]) throw new Error(`行号 ${k} 在多个 spec 中重复定义 AFTER`);
      AFTER[k] = v;
    }
  }

  const srcLines = readFileSync(SRC, "utf8").split("\n");

  const out = [];
  let injected = 0;

  // 先写文件头
  for (const h of HEADER) {
    assertComment(h, "HEADER");
    out.push(h);
    injected++;
  }

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

  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, out.join("\n"), "utf8");

  const text = out.join("\n");
  const cnt = (re) => (text.match(re) || []).length;
  console.log(`✔ 已生成: ${OUT}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  机制标注【】   : ${cnt(/【/g)}`);
  console.log(`  重点标注★      : ${cnt(/★/g)}`);
  console.log(`  疑似缺陷⚠      : ${cnt(/⚠/g)}`);
  console.log(`  交叉引用参见    : ${cnt(/参见 /g)}`);
  console.log(
    `  保护标记在前10行: ${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】"))
        ? "是"
        : "否"
    }`
  );
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});