#!/usr/bin/env node
/**
 * build-serverlistingscreen.mjs —— serverlistingscreen.lua 深度中文注释生成器（锚点注入法）
 *
 * 与 build-combat.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-serverlistingscreen.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-serverlistingscreen.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("screens/serverlistingscreen.lua");
const SPEC = join(__dirname, "spec-serverlistingscreen.mjs");
const OUT = relOut("screens/serverlistingscreen.lua");

const HEADER = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：screens/serverlistingscreen.lua",
  "-- 模块：界面 / 服务器浏览器（本批最大文件，2320 行）",
  "-- 职责：拉取服务器列表 → 过滤 → 排序 → 池化渲染 → 详情展示 → 加入。",
  "--       是 widgets/scrollablelist.lua **模式 B（静态控件池）** 的标杆用户：",
  "--       只创建 13 个行控件（listings_per_view），靠 updatefn 把它们",
  "--       重新绑定到不同服务器数据，从而显示任意数量的服务器。",
  "--",
  "-- 数据流（网络 → 像素）：",
  "--   TheNet（引擎侧，异步，GetServerListingReadDirty 脏标志）",
  "--     → self.servers",
  "--     → DoFiltering（过滤 + 字段显式拷贝 + 附加 actualindex 稳定标识）",
  "--     → DoSorting（原地 table.sort，多级优先级 + 打破平局）",
  "--     → ScrollableList:SetList",
  "--     → RefreshView → updatefn = UpdateServerListWidget → 13 行重绑定",
  "--",
  "-- 关键符号：CompareTable（递归深比较，性能基石）, RefreshView（中心调度）, ",
  "--           DoFiltering / IsValidWithFilters（过滤，分「不可加入」与「被过滤」）, ",
  "--           DoSorting / SetSort / CycleColumnSort, ",
  "--           UpdateServerListWidget（虚拟化绑定函数）, ",
  "--           MakeServerListWidgets（池构建）, ",
  "--           GuaranteeSelectedServerHighlighted（高亮全量重算）, ",
  "--           ProcessPlayerData（★ RunInSandboxSafe 沙箱执行不可信上报数据）, ",
  "--           ServerSelected / UpdateServerData（选中即异步拉详情）, ",
  "--           ClearServerList（虚拟化的配套：清内容而不销毁控件）, ",
  "--           CurrentCenterFocus / CurrentRightFocus / CurrentLeftFocus",
  "--           （动态焦点图）, OnControl（输入独占与路由）, GetHelpText",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：widgets/scrollablelist.lua（模式 B 的被调用方）, ",
  "--           widgets/listcursor.lua（每行的焦点指示器，接入焦点冒泡）, ",
  "--           widgets/spinner.lua / numericspinner.lua / textedit.lua（筛选器控件）, ",
  "--           widgets/scrollablelist.lua 的 LayOutStaticWidgets(skipFixUp)（",
  "--           本文件声明自己处理焦点，故跳过框架注入）、",
  "--           thenet.lua（服务器搜索/列表/详情下载的引擎接口）、",
  "--           sandbox.lua（RunInSandboxSafe，不可信数据的唯一安全出口）、",
  "--           profile.lua（playerintention 等本地设置）、",
  "--           constants.lua（INTENTIONS / BETA_INFO / APP_VERSION）",
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
  expandKeysInPlace(AFTER, srcLines, "AFTER");
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
