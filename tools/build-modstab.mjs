#!/usr/bin/env node
/**
 * build-modstab.mjs —— modstab.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-modstab.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-modstab.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("widgets/modstab.lua");
const SPEC = join(__dirname, "spec-modstab.mjs");
const OUT = relOut("widgets/modstab.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：widgets/modstab.lua",
  "-- 模块：界面 / 模组列表标签页（servercreationscreen 的一个页签）",
  "-- 职责：列出所有已安装模组（分客户端/服务端两栏），支持勾选启用、",
  "--       配置、更新（创意工坊）、批量清理、批量更新；右侧详情面板",
  "--       展示名称/作者/描述/兼容性/状态。",
  "--       本控件是 **Widget 而非 Screen**，没有屏幕栈参与，",
  "--       而通过 self.servercreationscreen 反向通知宿主界面刷新。",
  "-- 关键符号：UpdateForWorkshop（数据→UI 的唯一刷新入口，375 行）,",
  "--           StartWorkshopUpdate（周期轮询）, ShowModDetails（详情填充）,",
  "--           EnableCurrent / OnConfirmEnable（模组启停，含可撤销快照）, ",
  "--           LoadModInfoPrefabs / UnloadModInfoPrefabs / ReloadModInfoPrefabs",
  "--           （运行时为模组图标临时注册预制体，含引用计数顺序陷阱）, ",
  "--           DoFocusHookups（23 行焦点导航图，含动态目标函数）,",
  "--           SetModsList（页签切换）, CreateDetailPanel, GetBestModStatus,",
  "--           SetSaveSlot（切换存档槽 = 换整套模组配置）, CleanAllButton",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：widgets/scrollablelist.lua（列表容器，本文件用其模式 A）, ",
  "--           widgets/templates.lua（ModListItem / ModDLListItem 行模板）、",
  "--           widgets/widget.lua（SetFocusChangeDir 支持 FunctionOrValue,",
  "--           这是 tomiddlecol 动态焦点目标的基础）、",
  "--           widgets/imagebutton.lua（SetTextures 多态贴图切换）、",
  "--           screens/servercreationscreen.lua（宿主界面，接收反向通知）、",
  "--           screens/modconfigurationscreen.lua（PushScreen 打开的子屏）、",
  "--           knownmodindex.lua（模组元数据与启用状态）、",
  "--           modmanager.lua（模组加载/卸载）、",
  "--           schaduler / staticScheduler（周期轮询，不随暂停冻结）",
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
  // ★ 防块注释定界符出现在注释正文里（会提前闭合源文件已开启的长注释块）
  if (/\-\-\[\[/.test(line)) {
    throw new Error(`规格错误 @${where}: 含块注释开定界符 -> ${line}`);
  }
  if (/\]\]/.test(line)) {
    throw new Error(`规格错误 @${where}: 含块注释闭定界符 -> ${line}`);
  }
  // ★ 防反斜杠转义：工具链可能把某些转义当真回车，把一行劈成两行
  if (line.includes("\\")) {
    throw new Error(`规格错误 @${where}: 含反斜杠 -> ${line}`);
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
