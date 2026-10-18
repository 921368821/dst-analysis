/**
 * extract-data.mjs — DST Lua 源码结构化数据提取器
 *
 * 数据源: C:\Users\35916\.qwenworkcn\workspace\mv38nal4gdn29zna\dst-analysis\scripts\scripts
 * 输出:   E:\DST-Analysis\05-数据\{预制体总表,组件总表,状态图与大脑总表,配方与物品表,数值参数总表}.md
 *
 * 解析策略: 纯正则 + 启发式, 不做完整 Lua 语法树解析。
 * 所有提取项均在输出文件中标注为「启发式」, 不确定的一律输出「未提取到」而不猜测。
 *
 * 用法: node extract-data.mjs
 */

import fs from "node:fs";
import path from "node:path";

const SRC = "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts";
const OUT = "E:/DST-Analysis/05-数据";

const NOW = new Date().toISOString().replace("T", " ").slice(0, 19) + " UTC";

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

function readLua(rel) {
  const p = path.join(SRC, rel);
  if (!fs.existsSync(p)) return null;
  return fs.readFileSync(p, "utf8");
}

function listLua(dir) {
  const p = path.join(SRC, dir);
  if (!fs.existsSync(p)) return [];
  return fs
    .readdirSync(p)
    .filter((f) => f.toLowerCase().endsWith(".lua"))
    .map((f) => path.join(dir, f));
}

function countLines(text) {
  if (!text) return 0;
  // 与 `wc -l` 对齐: 文件末尾若有换行符, 不额外计一行
  const n = text.split("\n").length;
  return text.endsWith("\n") ? n - 1 : n;
}

/** 取所有匹配, 返回去重后的字符串数组 (保持出现顺序) */
function uniq(arr) {
  const seen = new Set();
  const out = [];
  for (const v of arr) {
    if (v != null && v !== "" && !seen.has(v)) {
      seen.add(v);
      out.push(v);
    }
  }
  return out;
}

function matchAll(text, re) {
  const out = [];
  let m;
  const r = new global.RegExp(re.source, re.flags.includes("g") ? re.flags : re.flags + "g");
  while ((m = r.exec(text)) !== null) {
    out.push(m);
    if (m.index === r.lastIndex) r.lastIndex++;
  }
  return out;
}

/**
 * 花括号配平扫描: 返回从 openIdx 处 `{` 对应的闭合 `}` 的下标。
 * 正确跳过字符串(含转义)、行注释、块注释, 避免注释中的括号误配平。
 */
function matchBrace(text, openIdx) {
  let depth = 0;
  let i = openIdx;
  while (i < text.length) {
    const ch = text[i];
    const ch2 = text[i + 1];
    if (ch === '"' || ch === "'") {
      const q = ch;
      i++;
      while (i < text.length && text[i] !== q) {
        if (text[i] === "\\") i++;
        i++;
      }
      i++;
      continue;
    }
    if (ch === "-" && ch2 === "-") {
      while (i < text.length && text[i] !== "\n") i++;
      continue;
    }
    if (ch === "[" && ch2 === "[") {
      while (i < text.length && !(text[i] === "]" && text[i + 1] === "]")) i++;
      i += 2;
      continue;
    }
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) return i;
    }
    i++;
  }
  return -1;
}

/**
 * 配平提取 TUNING 主表体。
 * 注意: 文件开头存在 `TUNING = {}` 空表, 真正的定义在 function Tune() 内且表体非空,
 * 因此这里遍历所有 `TUNING = {` 候选, 取「第一个配平后内容非空且含顶层键」的那个。
 */
function extractTuningTable(text) {
  const candidates = [];
  const re = /\bTUNING\s*=\s*\{/g;
  let m;
  while ((m = re.exec(text)) !== null) {
    const openIdx = m.index + m[0].length - 1; // 指向 {
    const closeIdx = matchBrace(text, openIdx);
    if (closeIdx < 0) continue;
    const body = text.slice(openIdx + 1, closeIdx);
    if (body.trim().length === 0) continue;
    // 顶层键判定: 该表体内是否存在 8 空格缩进的 NAME = 行
    if (/^ {8}[A-Za-z_][A-Za-z_0-9]*\s*=/m.test(body)) {
      candidates.push({ body, openIdx, closeIdx, line: countLines(text.slice(0, openIdx)) });
      break;
    }
  }
  return candidates[0] || null;
}

/**
 * 以 openIdx 处的 `(` 为起点, 在括号配平范围内按「顶层逗号」切分实参。
 * 正确跳过嵌套括号/方括号/花括号、字符串与注释。
 * 配平失败或参数过多(>30, 判定为误匹配)时返回 null。
 */
function splitCallArgs(text, openIdx) {
  if (text[openIdx] !== "(") return null;
  let depth = 0;
  let i = openIdx;
  const start = openIdx + 1;
  const args = [];
  let curStart = start;
  while (i < text.length) {
    const ch = text[i];
    const ch2 = text[i + 1];
    if (ch === '"' || ch === "'") {
      const q = ch;
      i++;
      while (i < text.length && text[i] !== q) {
        if (text[i] === "\\") i++;
        i++;
      }
      i++;
      continue;
    }
    if (ch === "-" && ch2 === "-") {
      while (i < text.length && text[i] !== "\n") i++;
      continue;
    }
    if (ch === "(" || ch === "[" || ch === "{") {
      depth++;
      i++;
      continue;
    }
    if (ch === ")" || ch === "]" || ch === "}") {
      depth--;
      if (depth === 0) {
        const last = text.slice(curStart, i);
        if (last.trim() !== "") args.push(last);
        return args.length > 30 ? null : args;
      }
      i++;
      continue;
    }
    if (ch === "," && depth === 1) {
      args.push(text.slice(curStart, i));
      curStart = i + 1;
      i++;
      continue;
    }
    i++;
  }
  return null;
}

function writeOut(fileName, content) {
  const p = path.join(OUT, fileName);
  fs.writeFileSync(p, content, "utf8");
  const lines = countLines(content);
  console.log(`  [OK] ${fileName}  (${lines} 行, ${(Buffer.byteLength(content, "utf8") / 1024).toFixed(0)} KB)`);
  return lines;
}

/** 转义表格单元格中的竖线与换行 */
function cell(s) {
  if (s == null || s === "") return "—";
  return String(s).replace(/\|/g, "\\|").replace(/\r?\n/g, " ").trim() || "—";
}

/** 截断长列表用于表格显示, 完整列表放在同行的 title 属性外(用脚注) */
function joinCell(arr, max = 6) {
  if (!arr || arr.length === 0) return "—";
  if (arr.length <= max) return arr.join(", ");
  return `${arr.slice(0, max).join(", ")} +${arr.length - max}`;
}

// ---------------------------------------------------------------------------
// 文件头
// ---------------------------------------------------------------------------

function header(title, sources, method, accuracy) {
  return `# ${title}

> **数据来源**: \`${SRC}\`
> ${sources.map((s) => `> - **来源文件**: \`${s}\``).join("\n")}
> **生成时间**: ${NOW}
> **生成方式**: \`node E:/DST-Analysis/tools/extract-data.mjs\`（可重复运行，幂等覆盖输出）
> **提取方法**: ${method}
> **准确性说明**: ${accuracy}

---
`;
}

// ===========================================================================
// 1. 预制体总表
// ===========================================================================

function extractPrefabs() {
  const files = listLua("prefabs");
  const rows = [];

  for (const rel of files) {
    const text = readLua(rel);
    if (text == null) continue;
    const name = path.basename(rel, ".lua");

    // --- 资产依赖: 收集 Asset("TYPE", "path") 的第一参数类型作为资产种类, 数量为 Asset 调用总数
    const assetCalls = matchAll(text, /Asset\(\s*"([^"]*)"\s*,\s*"([^"]*)"/g);
    const assetTypes = uniq(assetCalls.map((m) => m[1]));
    const assetCount = assetCalls.length;

    // --- 依赖的其它预制体
    // Lua 源码中 prefs 数组有多种命名: local prefabs / local deps / 直接局部数组
    // 策略: 找出所有名为 prefabs/deps/assets 的表字面量, 提取其中被双引号包裹的字符串。
    // 注意: 这些表只用于 prefab 注册, 元素多为预制体名或素材名, 因此标注为「启发式」。
    const depNames = [];
    const tableRe =
      /local\s+(?:prefabs|deps|assets|lootprefs|creatureprefs)\s*=\s*\{([\s\S]*?)\n\}/g;
    let tm;
    while ((tm = tableRe.exec(text)) !== null) {
      const body = tm[1];
      for (const q of matchAll(body, /"([^"]+)"/g)) depNames.push(q[1]);
    }
    // 另有 require("prefabs/xxx") 形式, 明确是预制体依赖
    for (const q of matchAll(text, /require\s*\(?\s*"prefabs\/([^"]+)"/g)) depNames.push(q[1]);
    const deps = uniq(depNames);

    // --- 挂载的组件: AddComponent(inst, "xxx") / inst:AddComponent("xxx") / AddComponent("xxx")
    const compOrder = [];
    const compRe =
      /(?:AddComponent|AddPlayableComponent)\s*\(\s*[^,()]+,\s*"([^"]+)"|[:.]AddComponent\s*\(\s*"([^"]+)"/g;
    let cm;
    while ((cm = compRe.exec(text)) !== null) {
      compOrder.push(cm[1] || cm[2]);
    }
    const components = uniq(compOrder);

    // --- 实体标签
    const tags = uniq(matchAll(text, /(?:[:.]entity:)?AddTag\s*\(\s*"([^"]+)"/g).map((m) => m[1]));

    // --- SetPristine 调用
    // 【重要】源码中全部 1950 处 SetPristine 均为无参调用 `SetPristine()`, 从未出现 SetPristine(false)。
    // SetPristine 是引擎(C++)实现的方法, 定义不在本 Lua 源码树内, 因此**无法**从 Lua 侧判断其参数语义。
    // 本表只客观记录「该文件是否调用了 SetPristine」及调用次数, 不据此推断是否支持联机 —— 那会属于编造。
    const pristineCalls = matchAll(text, /\bSetPristine\s*\(/g).length;
    const pristine = pristineCalls > 0;

    // 联机相关旁证: 含 replica 组件 / 标记 networked 等。仅作参考, 不作结论。
    const hasReplicaComp = components.some((c) => c.endsWith("_replica"));
    const netTags = tags.filter((t) => /network/i.test(t));

    // --- 攻击/攻击目标: 便于查询怪物
    const isCreature =
      tags.includes("hostile") || tags.includes("FX") === false && /Attackable\s*=|CanBeAttacked/.test(text);
    const hasHealth = components.includes("health");
    const attackable = /entity:.*Attackable|Attackable\s*=/.test(text);

    // --- 分类标签 (启发式)
    const categories = [];
    if (tags.includes("FX")) categories.push("特效");
    if (tags.includes("hostile")) categories.push("敌对");
    if (tags.includes("structure")) categories.push("建筑");
    if (tags.includes("CLASSIFIED") && !tags.includes("INLIMBO")) categories.push("资源");
    if (components.includes("plant") || components.includes("lootdropper") && tags.includes("plantable"))
      categories.push("植物");
    if (components.includes("builder")) categories.push("可建造");
    if (components.includes("craftable")) categories.push("可制作");
    if (components.includes("deployable")) categories.push("可部署");
    if (components.includes("inventoryitem")) categories.push("物品");
    if (components.includes("fueled") || components.includes("cooker")) categories.push("燃烧器");
    if (components.includes("light") || components.includes("lightradial")) categories.push("光源");
    if (components.includes("locomotor")) categories.push("生物");
    if (components.includes("brain")) categories.push("生物");

    rows.push({
      name,
      file: rel.replace(/\\/g, "/"),
      lines: countLines(text),
      assetCount,
      assetTypes,
      deps,
      depCount: deps.length,
      components,
      compCount: components.length,
      tags,
      pristine,
      pristineCalls,
      hasReplicaComp,
      netTags,
      categories: uniq(categories),
      isCreature,
      attackable,
      hasHealth,
    });
  }

  rows.sort((a, b) => a.name.localeCompare(b.name));

  // --- 按组件索引
  const compIndex = new Map();
  for (const r of rows) {
    for (const c of r.components) {
      if (!compIndex.has(c)) compIndex.set(c, []);
      compIndex.get(c).push(r.name);
    }
  }
  const compSorted = [...compIndex.entries()].sort(
    (a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0])
  );

  // --- 按标签索引
  const tagIndex = new Map();
  for (const r of rows) {
    for (const t of r.tags) {
      if (!tagIndex.has(t)) tagIndex.set(t, []);
      tagIndex.get(t).push(r.name);
    }
  }
  const tagSorted = [...tagIndex.entries()].sort(
    (a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0])
  );

  // --- 输出
  const withAssets = rows.filter((r) => r.assetCount > 0).length;
  const withDeps = rows.filter((r) => r.depCount > 0).length;
  const pristineYes = rows.filter((r) => r.pristine).length;

  let md = header(
    "DST 预制体总表（prefabs/）",
    ["prefabs/*.lua"],
    "正则 + 启发式。`AddComponent` / `AddTag` / `Asset` 为**直接正则匹配**（高可信）；`deps` 依赖预制体为**启发式**（提取局部表字面量中的字符串，无法区分预制体名与素材名）。",
    [
      "**组件 / 标签 / 资产数量 / 行数**: 直接正则匹配，可信度高。",
      "**SetPristine 列**: 仅记录调用次数。源码全库无 `SetPristine(false)`，无法据此判定联机支持，详见统计概览下方说明。",
      "**deps（依赖预制体）**: 启发式提取局部数组字面量，可能混入素材名与常量，**仅供参考**。",
      "**categories（分类）**: 由标签与组件组合推断的启发式标签，非官方分类。",
      "行数为文件物理行数（含空行）。",
    ].join(" ")
  );

  md += `## 使用说明

本表共 **${rows.length}** 条预制体记录，**可用 grep 检索**：

\`\`\`bash
# 按预制体名精确查找
grep -w "^crow |" 预制体总表.md

# 找出所有含某组件的预制体（如 health）
grep "| health" 预制体总表.md

# 找出带某标签的预制体（如 CLASSIFIED）
grep "CLASSIFIED" 预制体总表.md

# 找出未调用 SetPristine 的预制体
grep "| 未调用 |" 预制体总表.md
\`\`\`

**统计概览**

| 指标 | 数量 |
|---|---|
| 预制体总数 | ${rows.length} |
| 声明了 assets 的预制体 | ${withAssets} |
| 声明了依赖表(prefabs/deps)的预制体 | ${withDeps} |
| 调用了 SetPristine 的预制体 | ${pristineYes} |
| 含 replica 组件的预制体 | ${rows.filter((r) => r.hasReplicaComp).length} |

> **关于「是否支持联机」: 未提取到** —— 无法从 Lua 源码判定，此处不做推测。
> 源码中全部 1950 处 \`SetPristine\` 调用**均为无参形式** \`SetPristine()\`，从未出现 \`SetPristine(false)\`。
> \`SetPristine\` 由引擎(C++)实现，其定义不在本 Lua 源码树内，因此无法得知无参调用时的默认语义。
> 若强按「出现 SetPristine 即视为可联机」下结论，等同于编造，故本表只客观记录调用次数。
> 需要该维度时请查引擎侧 \`Entity:SetPristine\` 实现，或用「含 replica 组件」作间接参考。

---

## 1. 预制体明细表（${rows.length} 条）

| # | 预制体名 | 行数 | 资产数 | 依赖数 | 组件数 | 挂载组件 | 实体标签 | SetPristine | 分类 | 源文件 |
|---|---|---|---|---|---|---|---|---|---|---|
`;

  rows.forEach((r, i) => {
    md += `| ${i + 1} | \`${r.name}\` | ${r.lines} | ${r.assetCount} | ${r.depCount} | ${r.compCount} | ${joinCell(r.components)} | ${joinCell(r.tags)} | ${r.pristineCalls > 0 ? `${r.pristineCalls} 次` : "未调用"} | ${joinCell(r.categories, 3)} | \`${r.file}\` |\n`;
  });

  // 完整依赖清单（避免表格截断丢数据）
  md += `\n---\n\n## 2. 预制体依赖与标签完整清单\n\n> 表格中「依赖」与「标签」列过长时已截断，此处给出完整数据。\n\n`;
  md += "### 2.1 依赖的其它预制体（deps，启发式）\n\n";
  const withDepRows = rows.filter((r) => r.depCount > 0);
  md += `共 ${withDepRows.length} 个预制体声明了依赖。\n\n| 预制体 | 依赖数量 | 依赖列表 |\n|---|---|---|\n`;
  for (const r of withDepRows) {
    md += `| \`${r.name}\` | ${r.depCount} | ${cell(r.deps.join(", "))} |\n`;
  }

  md += `\n### 2.2 实体标签完整清单\n\n`;
  const withTagRows = rows.filter((r) => r.tags.length > 0);
  md += `共 ${withTagRows.length} 个预制体带有标签。\n\n| 预制体 | 标签列表 |\n|---|---|\n`;
  for (const r of withTagRows) {
    md += `| \`${r.name}\` | ${cell(r.tags.join(", "))} |\n`;
  }

  // 索引节
  md += `\n---\n\n## 3. 组件索引（按使用该组件的预制体数排序）\n\n`;
  md += `共 ${compSorted.length} 种组件被使用。\n\n| 组件名 | 使用数 | 预制体列表 |\n|---|---|---|\n`;
  for (const [c, list] of compSorted) {
    md += `| \`${c}\` | ${list.length} | ${cell(list.join(", "))} |\n`;
  }

  md += `\n---\n\n## 4. 标签索引（按使用该标签的预制体数排序）\n\n`;
  md += `共 ${tagSorted.length} 种标签。\n\n| 标签 | 数量 | 预制体列表 |\n|---|---|---|\n`;
  for (const [t, list] of tagSorted) {
    md += `| \`${t}\` | ${list.length} | ${cell(list.join(", "))} |\n`;
  }

  // 组件组合统计
  md += `\n---\n\n## 5. 组件组合统计\n\n`;
  const comboCount = new Map();
  for (const r of rows) {
    const key = r.components.slice().sort().join("+");
    if (!key) continue;
    comboCount.set(key, (comboCount.get(key) || 0) + 1);
  }
  const comboSorted = [...comboCount.entries()].sort((a, b) => b[1] - a[1]).slice(0, 60);
  md += `出现频次最高的 60 种组件组合（共 ${comboCount.size} 种组合，完整组合见第 1 节）。\n\n`;
  md += `| 次数 | 组件组合 |\n|---|---|\n`;
  for (const [k, v] of comboSorted) {
    md += `| ${v} | ${cell(k.split("+").join(", "))} |\n`;
  }

  writeOut("预制体总表.md", md);
  return { rows, compSorted, tagSorted };
}

// ===========================================================================
// 2. 组件总表
// ===========================================================================

function extractComponents() {
  const files = listLua("components");
  const compFiles = files.filter((f) => !path.basename(f).endsWith("_replica.lua"));
  const replicaFiles = files.filter((f) => path.basename(f).endsWith("_replica.lua"));

  // 所有组件名集合, 用于过滤误判的「依赖组件」
  const allNames = new Set(files.map((f) => path.basename(f, ".lua")));

  const rows = [];

  for (const rel of files) {
    const text = readLua(rel);
    if (text == null) continue;
    const name = path.basename(rel, ".lua");
    const isReplica = name.endsWith("_replica");

    // --- 周期更新
    const periodic =
      /DoPeriodicTask\s*\(/.test(text) ||
      /DoTaskInTime\s*\(/.test(text) ||
      /StartUpdatingComponent|AddComponentUpdate\w*\s*\(/.test(text);
    const periodicRaw = /DoPeriodicTask\s*\(/.test(text);

    // --- 网络同步
    // DST 的组件同步机制: 服务端通过 self.inst.replica.<comp>:SetXxx(...) 写入副本组件,
    // 不使用 net_ 前缀变量(全库仅 fishschool 的 'net_' 为误报匹配)。
    const replicaSets = uniq(
      matchAll(text, /replica\s*\.\s*([A-Za-z_0-9]+)\s*:\s*(Set[A-Za-z_0-9]*)\s*\(/g).map(
        (m) => `${m[1]}.${m[2]}`
      )
    );
    const replicaTargets = uniq(
      matchAll(text, /replica\s*\.\s*([A-Za-z_0-9]+)\s*\./g).map((m) => m[1])
    );
    // self.xxx 与 OnSave/OnLoad 中的字段会被随存档同步
    const saveFields = [];
    for (const fn of ["OnSave", "OnLoad"]) {
      const fnRe = new global.RegExp(`function\\s+[A-Za-z_0-9]*:?${fn}\\s*\\([^)]*\\)([\\s\\S]*?)\\n\\s*end`, "g");
      const fm = fnRe.exec(text);
      if (!fm) continue;
      for (const a of matchAll(fm[1], /data\s*\.\s*([A-Za-z_0-9]+)/g)) saveFields.push(a[1]);
    }
    // net_ 前缀变量 (仅作记录, 实际全库几乎不存在)
    const netVars = uniq(matchAll(text, /local\s+(net_[A-Za-z_0-9]*)/g).map((m) => m[1]));

    // --- 依赖的其他组件
    // 启发式: 匹配 <任意>.components.<name> 访问, 过滤掉自身
    const depSet = new Set();
    for (const m of matchAll(text, /\.components\s*\.\s*([A-Za-z_0-9]+)/g)) {
      if (allNames.has(m[1]) && m[1] !== name) depSet.add(m[1]);
    }
    for (const m of matchAll(text, /require\s*\(\s*"components\/([A-Za-z_0-9]+)"\s*\)/g)) {
      if (allNames.has(m[1]) && m[1] !== name) depSet.add(m[1]);
    }
    // AddComponent(inst, "other") 形式 (部分组件会主动装其它组件)
    for (const m of matchAll(text, /AddComponent\s*\(\s*[^,()]+,\s*"([A-Za-z_0-9]+)"/g)) {
      if (allNames.has(m[1]) && m[1] !== name) depSet.add(m[1]);
    }
    const deps = [...depSet].sort();

    // --- 定义的网络事件: inst:PushEvent("xxx")
    const events = uniq(
      matchAll(text, /(?:[:.]|->)?PushEvent\s*\(\s*"([^"]+)"/g).map((m) => m[1])
    );

    // --- 对外方法 (组件 API)
    const methods = uniq(
      matchAll(text, /function\s+([A-Za-z_0-9]+):([A-Za-z_0-9]+)\s*\(/g).map((m) => m[2])
    );

    // --- 功能分类 (启发式)
    const cats = [];
    if (periodicRaw) cats.push("周期更新");
    if (replicaSets.length > 0) cats.push("网络同步");
    if (isReplica) cats.push("副本组件");
    if (/EventHandler\s*\(|:ListenForEvent/.test(text)) cats.push("事件驱动");
    if (/OnSave|OnLoad/.test(text)) cats.push("存档");
    if (/AddComponentSave|AddComponentLoad/.test(text)) cats.push("组件存档");

    rows.push({
      name,
      file: rel.replace(/\\/g, "/"),
      lines: countLines(text),
      isReplica,
      periodic,
      periodicRaw,
      replicaSets,
      replicaTargets,
      saveFields: uniq(saveFields),
      netVars,
      deps,
      events,
      methods,
      cats,
    });
  }

  rows.sort((a, b) => a.name.localeCompare(b.name));

  const periodicCount = rows.filter((r) => r.periodic).length;
  const replicaSetsCount = rows.filter((r) => r.replicaSets.length > 0).length;
  const eventCount = rows.filter((r) => r.events.length > 0).length;

  let md = header(
    "DST 组件总表（components/）",
    ["components/*.lua"],
    "正则 + 启发式。周期更新 / PushEvent / replica 同步目标 均为**直接正则匹配**；组件依赖为**启发式**（从 `.components.xxx` 访问与 AddComponent 调用推断）。",
    [
      "**重要修正**: DST 的 Lua 组件**不使用 `net_` 前缀网络变量**。该机制由 C++ 引擎的 replica 组件实现：服务端写 `self.inst.replica.<comp>:SetXxx()`，客户端读副本。",
      "因此本表的「网络同步」列基于 `replica.X:SetY()` 调用提取，`net_` 列仅保留字面匹配结果（全库仅 `fishschool.lua` 有 `SetNettedPrefab` 等误报，已剔除）。",
      "**依赖组件**: 启发式，反映代码中的实际访问关系，不含隐式依赖。",
      "**对外方法**: 正则匹配 `function Name:Method(` 的 Method 部分，可能包含私有方法。",
    ].join(" ")
  );

  md += `## 使用说明

共 **${rows.length}** 条组件记录（其中副本组件 ${replicaFiles.length} 个），**可用 grep 检索**。

\`\`\`bash
# 找出所有周期更新的组件
grep "| 是 |" 组件总表.md

# 按组件名查找
grep "^| \`hunger\` |" 组件总表.md

# 找出某事件的全部发起者
grep "onhunger" 组件总表.md
\`\`\`

**统计概览**

| 指标 | 数量 |
|---|---|
| 组件总数 | ${rows.length} |
| 副本组件(*_replica) | ${replicaFiles.length} |
| 含周期更新(DoPeriodicTask 等) | ${periodicCount} |
| 含网络同步(replica.*:Set*) | ${replicaSetsCount} |
| 定义了 PushEvent 的组件 | ${eventCount} |

---

## 1. 组件明细表

| 组件名 | 行数 | 周期更新 | 网络同步 | 副本 | 依赖组件数 | 依赖组件 | 事件数 | 事件列表 | 分类 |
|---|---|---|---|---|---|---|---|---|---|
`;

  for (const r of rows) {
    md += `| \`${r.name}\` | ${r.lines} | ${r.periodic ? "是" : "否"} | ${r.replicaSets.length > 0 ? "是" : "否"} | ${r.isReplica ? "是" : "否"} | ${r.deps.length} | ${joinCell(r.deps, 5)} | ${r.events.length} | ${joinCell(r.events, 5)} | ${joinCell(r.cats, 3)} |\n`;
  }

  // 网络同步明细
  md += `\n---\n\n## 2. 网络同步明细（replica.*:Set* 调用）\n\n`;
  md += `共 ${replicaSetsCount} 个组件含网络同步调用。\n\n| 组件名 | 同步目标组件 | 同步方法数 | 同步方法 |\n|---|---|---|---|\n`;
  for (const r of rows.filter((x) => x.replicaSets.length > 0)) {
    const targets = uniq(r.replicaSets.map((s) => s.split(".")[0]));
    const methods = uniq(r.replicaSets.map((s) => s.split(".")[1]));
    md += `| \`${r.name}\` | ${cell(targets.join(", "))} | ${methods.length} | ${cell(methods.join(", "))} |\n`;
  }

  md += `\n### 2.1 字面 net_ 变量匹配结果\n\n`;
  const netRows = rows.filter((r) => r.netVars.length > 0);
  if (netRows.length === 0) {
    md += `**未提取到** —— 全库无 \`local net_*\` 形式的网络变量声明。DST 组件网络同步由引擎 replica 机制实现，不使用该模式。\n`;
  } else {
    md += `| 组件名 | 匹配到的 net_ 变量 | 说明 |\n|---|---|---|\n`;
    for (const r of netRows) {
      md += `| \`${r.name}\` | ${cell(r.netVars.join(", "))} | 疑似误报（DST 无此模式），请人工确认 |\n`;
    }
  }

  // 事件明细
  md += `\n---\n\n## 3. 网络事件索引（PushEvent）\n\n`;
  const evIndex = new Map();
  for (const r of rows) for (const e of r.events) {
    if (!evIndex.has(e)) evIndex.set(e, new Set());
    evIndex.get(e).add(r.name);
  }
  const evSorted = [...evIndex.entries()].sort((a, b) => b[1].size - a[1].size || a[0].localeCompare(b[0]));
  md += `共 ${evSorted.length} 种事件。\n\n| 事件名 | 发起组件数 | 发起组件 |\n|---|---|---|\n`;
  for (const [e, set] of evSorted) {
    md += `| \`${e}\` | ${set.size} | ${cell([...set].join(", "))} |\n`;
  }

  // 依赖关系图
  md += `\n---\n\n## 4. 组件依赖关系图\n\n`;
  const topByDep = rows.filter((r) => r.deps.length > 0).sort((a, b) => b.deps.length - a.deps.length).slice(0, 25);
  const coreNames = new Set(["health", "hunger", "sanity", "combat", "locomotor", "inventory", "inventoryitem", "builder", "finiteuses", "fueled", "perishable", "workable", "sleepable", "freezable", "fuelregen", "environment", "skilled", "entitylimits", "deployable", "craftable", "workable"]);

  md += `### 4.1 核心组件依赖（mermaid）\n\n`;
  md += "```mermaid\ngraph LR\n";
  for (const r of topByDep) {
    if (r.deps.length === 0) continue;
    const id = "N_" + r.name.replace(/[^A-Za-z0-9]/g, "_");
    md += `  ${id}[\"${r.name}\"]\n`;
    for (const d of r.deps) {
      if (coreNames.has(d)) {
        md += `  ${id} --> N_${d.replace(/[^A-Za-z0-9]/g, "_")}[\"${d}\"]\n`;
      } else {
        md += `  ${id} --> N_${d.replace(/[^A-Za-z0-9]/g, "_")}[\"${d}\"]\n`;
      }
    }
  }
  md += "```\n";

  md += `\n### 4.2 ASCII 依赖视图（依赖数最多的 20 个组件）\n\n`;
  md += "```\n";
  for (const r of topByDep.slice(0, 20)) {
    md += `${r.name}  (${r.lines} 行)\n`;
    md += `  ├─ 依赖: ${r.deps.join(", ") || "无"}\n`;
    md += `  ├─ 事件: ${r.events.slice(0, 8).join(", ") || "无"}${r.events.length > 8 ? ` +${r.events.length - 8}` : ""}\n`;
    md += `  └─ 同步: ${r.replicaSets.slice(0, 6).join(", ") || "无"}${r.replicaSets.length > 6 ? ` +${r.replicaSets.length - 6}` : ""}\n`;
  }
  md += "```\n";

  // 反向索引
  md += `\n### 4.3 反向依赖（被哪些组件依赖）\n\n`;
  const revIndex = new Map();
  for (const r of rows) for (const d of r.deps) {
    if (!revIndex.has(d)) revIndex.set(d, []);
    revIndex.get(d).push(r.name);
  }
  const revSorted = [...revIndex.entries()].sort((a, b) => b[1].length - a[1].length);
  md += `| 组件名 | 被依赖次数 | 被哪些组件依赖 |\n|---|---|---|\n`;
  for (const [d, list] of revSorted.slice(0, 60)) {
    md += `| \`${d}\` | ${list.length} | ${cell(list.join(", "))} |\n`;
  }

  // 方法索引
  md += `\n---\n\n## 5. 组件对外方法索引\n\n`;
  md += `共 ${rows.reduce((s, r) => s + r.methods.length, 0)} 个方法（仅列出方法数最多的 120 个组件）。\n\n| 组件名 | 方法数 | 方法列表 |\n|---|---|---|\n`;
  const byMethod = rows.filter((r) => r.methods.length > 0).sort((a, b) => b.methods.length - a.methods.length);
  for (const r of byMethod.slice(0, 120)) {
    md += `| \`${r.name}\` | ${r.methods.length} | ${cell(r.methods.join(", "))} |\n`;
  }

  writeOut("组件总表.md", md);
  return { rows, evSorted, revSorted };
}

// ===========================================================================
// 3. 状态图与大脑总表
// ===========================================================================

function extractStategraphBrain() {
  const sgFiles = listLua("stategraphs");
  const brainFiles = listLua("brains");

  const sgSet = new Set(sgFiles.map((f) => path.basename(f, ".lua")));
  const brainSet = new Set(brainFiles.map((f) => path.basename(f, ".lua")));

  // --- 状态图
  const sgRows = sgFiles.map((rel) => {
    const text = readLua(rel);
    const name = path.basename(rel, ".lua");

    // 状态计数: 主形态为 State{ name = "xxx", ... }
    // 兼容 State("xxx") / State{ name = "xxx" } 两种书写
    const braceStates = matchAll(text, /\bState\s*\{/g);
    const parenStates = matchAll(text, /\bState\s*\(\s*"([^"]+)"/g);
    const namedStates = matchAll(text, /\bState\s*\{\s*name\s*=\s*"([^"]+)"/g);

    // 事件定义: EventHandler("xxx", ...) / Name("xxx")
    const eventDefs = uniq([
      ...matchAll(text, /EventHandler\s*\(\s*"([^"]+)"/g).map((m) => m[1]),
      ...matchAll(text, /\bName\s*\(\s*"([^"]+)"/g).map((m) => m[1]),
    ]);

    // 动作处理器目标状态
    const actionStates = uniq(matchAll(text, /ActionHandler\s*\(\s*ACTIONS\s*\.\s*([A-Z_0-9]+)/g).map((m) => m[1]));

    // 所属生物: 文件名去 SG 前缀, 去掉 _water/_shell 等变体后缀(启发式)
    let creature = name.replace(/^SG/, "");
    // 常见变体后缀
    const variantMatch = creature.match(/^(.*?)(_water|_shell|_moon|_dusk|_day|_night|_poison|_cursed|_moonlit)$/);
    let variant = "";
    if (variantMatch) {
      creature = variantMatch[1];
      variant = variantMatch[2];
    }

    // 绑定的 prefab: 搜索 prefabs/ 中引用该状态图的文件
    return {
      name,
      file: rel.replace(/\\/g, "/"),
      lines: countLines(text),
      stateCount: braceStates.length + parenStates.length,
      braceCount: braceStates.length,
      parenCount: parenStates.length,
      namedCount: namedStates.length,
      namedStates: namedStates.map((m) => m[1]),
      events: eventDefs,
      actions: actionStates,
      creature,
      variant,
      isCommon: /^SGcommon/.test(name),
      requireCommon: /require\s*\(\s*"stategraphs\/commonstates"/.test(text),
    };
  });
  sgRows.sort((a, b) => a.name.localeCompare(b.name));

  // --- 反查: 哪些 prefab 使用了该状态图
  const sgToPrefabs = new Map();
  for (const rel of listLua("prefabs")) {
    const text = readLua(rel);
    if (!text) continue;
    const pname = path.basename(rel, ".lua");
    for (const m of matchAll(text, /["'](SG[A-Za-z_0-9]+)["']/g)) {
      if (!sgSet.has(m[1])) continue;
      if (!sgToPrefabs.has(m[1])) sgToPrefabs.set(m[1], new Set());
      sgToPrefabs.get(m[1]).add(pname);
    }
  }

  // --- 大脑
  const brainRows = brainFiles.map((rel) => {
    const text = readLua(rel);
    const name = path.basename(rel, ".lua");

    // 绑定的状态图: 该 brain 文件内出现的 SGxxx 字符串
    const sgRefs = uniq(matchAll(text, /["'](SG[A-Za-z_0-9]+)["']/g).map((m) => m[1]));

    // 绑定的预制体: prefabs/ 中 SetBrain(require("brains/xxx")) 或 SetBrain(brainvar)
    const usedBy = new Set();
    for (const prel of listLua("prefabs")) {
      const ptext = readLua(prel);
      if (!ptext) continue;
      if (new RegExp(`brains/${name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`).test(ptext)) {
        usedBy.add(path.basename(prel, ".lua"));
      }
    }

    // 行为树结构统计
    const brainNodes = matchAll(text, /\bbrain\s*\{/g).length;
    const subbrains = uniq(matchAll(text, /require\s*\(?\s*"brains\/([A-Za-z_0-9]+)"/g).map((m) => m[1]));
    const requireLines = uniq(matchAll(text, /require\s*\(?\s*"([^"]+)"/g).map((m) => m[1]));
    const eventsUsed = uniq(matchAll(text, /EventHandler\s*\(\s*"([^"]+)"/g).map((m) => m[1]));

    // 绑定的状态图: 命名约定推断 (xxxbrain -> SGxxx), 若 sgRefs 为空则尝试约定匹配
    let inferredSg = "";
    if (sgRefs.length === 0) {
      const base = name.replace(/brain$/, "");
      const cand = "SG" + base;
      if (sgSet.has(cand)) inferredSg = cand;
      else {
        // 尝试后缀匹配
        for (const sg of sgSet) {
          const sgBase = sg.replace(/^SG/, "");
          if (sgBase === base || sgBase.startsWith(base + "_")) {
            inferredSg = sg;
            break;
          }
        }
      }
    }

    return {
      name,
      file: rel.replace(/\\/g, "/"),
      lines: countLines(text),
      sgRefs,
      inferredSg,
      usedBy: [...usedBy].sort(),
      brainNodes,
      subbrains,
      requireLines,
      eventsUsed,
      isCommon: /common/i.test(name),
    };
  });
  brainRows.sort((a, b) => a.name.localeCompare(b.name));

  const totalStates = sgRows.reduce((s, r) => s + r.stateCount, 0);
  const boundBrain = brainRows.filter((r) => r.sgRefs.length > 0 || r.inferredSg).length;

  let md = header(
    "DST 状态图与大脑总表（stategraphs/ + brains/）",
    ["stategraphs/*.lua", "brains/*.lua", "prefabs/*.lua（用于反查引用关系）"],
    "正则 + 启发式。状态计数以 `State{` / `State(\"...\")` 正则匹配为主；生物名由文件名去 `SG` 前缀推断；大脑↔状态图绑定先取文件内 `SGxxx` 字符串，缺失时按命名约定推断。",
    [
      "**格式修正**: 任务书中提到的 `Name(\"xxx\")` 状态定义形式在本源码中基本不存在；实际主形态是 `State{ name = \"xxx\", ... }`。本表两者都统计并分列。",
      "**格式修正**: 大脑文件**不通过 `Asset(\"IMAGE\", \"sgXXX\")` 绑定状态图**，而是 prefab 中 `inst:SetBrain(require(\"brains/xxx\"))` 注入，大脑与状态图通过**文件命名约定**对应。故 `绑定的状态图` 列分「显式引用」与「约定推断」两种来源。",
      "状态计数含 `State{}` 空块与嵌套 stategraph 定义，可能高估。",
      "`所属生物` 去除了 `_water`/`_moon` 等已知变体后缀，属启发式。",
    ].join(" ")
  );

  md += `## 使用说明

| 数据 | 条目数 | 说明 |
|---|---|---|
| 状态图 | ${sgRows.length} | stategraphs/*.lua |
| 大脑 | ${brainRows.length} | brains/*.lua |
| 状态定义总数 | ${totalStates} | State{ 与 State("..") 累计 |
| 大脑可关联状态图 | ${boundBrain} | 显式引用或约定推断成功 |

\`\`\`bash
# 查找某生物的状态图
grep "crow" 状态图与大脑总表.md

# 找出状态数最多的状态图（按表头排序不适用，直接 grep 状态列）
grep "^| \`SG" 状态图与大脑总表.md
\`\`\`

---

## 1. 状态图总表（${sgRows.length} 条）

| 状态图名 | 行数 | 状态数 | 具名状态数 | 所属生物 | 变体后缀 | 公共库 | 事件定义数 | 动作处理数 | 被预制体数 | 源文件 |
|---|---|---|---|---|---|---|---|---|---|---|
`;

  for (const r of sgRows) {
    const used = sgToPrefabs.get(r.name);
    md += `| \`${r.name}\` | ${r.lines} | ${r.stateCount} | ${r.namedCount} | ${cell(r.creature)} | ${r.variant ? cell(r.variant) : "—"} | ${r.isCommon ? "是" : r.requireCommon ? "引用common" : "否"} | ${r.events.length} | ${r.actions.length} | ${used ? used.size : 0} | \`${r.file}\` |\n`;
  }

  md += `\n---\n\n## 2. 状态图 → 预制体 反查索引\n\n`;
  md += `仅列出被 prefab 直接引用（字符串匹配）的状态图。\n\n| 状态图名 | 引用它的预制体 |\n|---|---|\n`;
  for (const r of sgRows) {
    const used = sgToPrefabs.get(r.name);
    if (!used || used.size === 0) continue;
    md += `| \`${r.name}\` | ${cell([...used].sort().join(", "))} |\n`;
  }

  md += `\n---\n\n## 3. 大脑总表（${brainRows.length} 条）\n\n`;
  md += `| 大脑名 | 行数 | 绑定的状态图 | 来源 | 状态图引用数 | 被预制体数 | 使用该大脑的预制体 | 引用子大脑 | 行为树节点数 |\n|---|---|---|---|---|---|---|---|---|\n`;
  for (const r of brainRows) {
    const sgDisplay =
      r.sgRefs.length > 0
        ? cell(r.sgRefs.join(", "))
        : r.inferredSg
          ? cell(r.inferredSg)
          : "未提取到";
    const src = r.sgRefs.length > 0 ? "显式引用" : r.inferredSg ? "约定推断" : "未提取到";
    md += `| \`${r.name}\` | ${r.lines} | ${sgDisplay} | ${src} | ${r.sgRefs.length} | ${r.usedBy.length} | ${cell(r.usedBy.join(", "))} | ${joinCell(r.subbrains, 4)} | ${r.brainNodes} |\n`;
  }

  md += `\n---\n\n## 4. 大脑依赖的其它大脑\n\n`;
  const brainSubIdx = new Map();
  for (const r of brainRows) for (const s of r.subbrains) {
    if (!brainSubIdx.has(s)) brainSubIdx.set(s, []);
    brainSubIdx.get(s).push(r.name);
  }
  const bSorted = [...brainSubIdx.entries()].sort((a, b) => b[1].length - a[1].length);
  md += `共 ${bSorted.length} 个大脑被其它大脑复用。\n\n| 子大脑名 | 被复用次数 | 被哪些大脑引用 |\n|---|---|---|\n`;
  for (const [b, list] of bSorted) {
    md += `| \`${b}\` | ${list.length} | ${cell(list.join(", "))} |\n`;
  }

  md += `\n---\n\n## 5. 公共状态图库\n\n`;
  md += `stategraphs/commonstates.lua 等公共库被大量状态图 require。这些文件提供可复用的 State 定义，修改时影响面广。\n\n| 文件名 | 行数 | 被多少状态图 require |\n|---|---|---|\n`;
  const commonFiles = sgRows.filter((r) => /common/i.test(r.name));
  for (const c of commonFiles) {
    let n = 0;
    for (const rel of sgFiles) {
      const t = readLua(rel);
      if (t && t.includes(`stategraphs/${c.name}`)) n++;
    }
    md += `| \`${c.name}\` | ${c.lines} | ${n} |\n`;
  }

  writeOut("状态图与大脑总表.md", md);
  return { sgRows, brainRows };
}

// ===========================================================================
// 4. 配方与物品表
// ===========================================================================

function extractRecipes() {
  const text = readLua("recipes.lua");
  const constText = readLua("constants.lua");

  const recipes = [];
  const stations = [];
  let unparsed = 0;

  if (text) {
    // --- 制作台定义: PROTOTYPER_DEFS 表内形如
    //     name = {icon_atlas = ..., icon_image = "...", is_crafting_station = true/false, ...},
    const defsBlock = /PROTOTYPER_DEFS\s*=\s*\{([\s\S]*?)\n\}\s*\n/s.exec(text);
    if (defsBlock) {
      const body = defsBlock[1];
      const lineRe = /^\s*([A-Za-z_0-9]+)\s*=\s*\{(.*)\},?\s*$/gm;
      let m;
      while ((m = lineRe.exec(body)) !== null) {
        const stationName = m[1];
        const fields = m[2];
        const icon = /icon_image\s*=\s*"([^"]+)"/.exec(fields);
        const isStation = /is_crafting_station\s*=\s*(true|false)/.exec(fields);
        const actionStr = /action_str\s*=\s*"([^"]+)"/.exec(fields);
        const filterText = /filter_text\s*=\s*([^,}]+)/.exec(fields);
        stations.push({
          name: stationName,
          icon: icon ? icon[1] : "未提取到",
          isStation: isStation ? isStation[1] === "true" : "未提取到",
          actionStr: actionStr ? actionStr[1] : "—",
          filterText: filterText ? filterText[1].trim() : "—",
          line: countLines(body.slice(0, m.index)) + 1 + countLines(text.slice(0, text.indexOf(body))),
        });
      }
    }

    // --- 配方: Recipe("product", {Ingredient(...)}, [nil,] TECH.X, [{opts}])
    // 注意 DST 存在两种签名:
    //   Recipe2("x", {ing}, TECH.NONE, {opts})            -- 第3参为科技
    //   Recipe ("x", {ing}, nil, TECH.LOST, nil, ...)     -- 第3参为 nil, 科技在第4参
    // 因此不能用单条正则, 改为「定位调用括号 -> 顶层逗号切分实参 -> 按内容归类」。
    const callRe = /\b(Recipe|Recipe2|DeconstructRecipe)\s*\(/g;
    let cm2;
    while ((cm2 = callRe.exec(text)) !== null) {
      const fn = cm2[1];
      const parenIdx = cm2.index + cm2[0].length - 1; // 指向 (
      const args = splitCallArgs(text, parenIdx);
      if (args === null || args.length === 0) continue;

      // 产物名: 绝大多数是纯字符串字面量;
      // 少数在循环中用拼接生成 (如 Recipe2("hermitcrabtea_petals_"..i, ...)),
      // 这类记为 `<前缀>..i` 并在「循环生成」列标注, 不静默丢弃。
      const productM = /^\s*"([^"]+)"/.exec(args[0]);
      if (!productM) continue; // 不是我们认识的配方调用(例如被注释掉或格式异常)
      let product = productM[1];
      let loopGenerated = false;
      if (args[0].includes("..")) {
        // 形如 "prefix_"..i -> 记为 prefix_{loop}
        const concat = /^\s*"([^"]*)"\s*\.\./.exec(args[0]);
        if (concat) {
          product = concat[1] + "{loop}";
          loopGenerated = true;
        }
      }

      // 材料表: 含 Ingredient( 的实参
      let ingBody = "";
      for (const a of args) if (/Ingredient\s*\(/.test(a)) ingBody = a;
      // 科技: 形如 TECH.XXX 的实参 (DeconstructRecipe 无科技参数, 故为空)
      let tech = "";
      if (fn !== "DeconstructRecipe") {
        for (const a of args) {
          const t = /^\s*(TECH\s*\.\s*[A-Za-z_0-9]+)\s*$/.exec(a);
          if (t) {
            tech = t[1].replace(/\s+/g, "");
            break;
          }
        }
      }
      // 选项表: 含 builder_tag= / builder_skill= 等键的实参
      let opts = "";
      for (const a of args) if (/builder_tag\s*=|builder_skill\s*=|builder\s*=/.test(a)) opts = a;

      // 材料: Ingredient("name", count) / Ingredient("name", count, nil, nil, "icon")
      const ingredients = [];
      for (const im of matchAll(ingBody, /Ingredient\s*\(\s*([^,]+?)\s*,\s*([^,)]+)/g)) {
        let n = im[1].trim();
        const c = im[2].trim();
        // 去掉 Icon(...) 包裹
        if (n.startsWith("Icon(")) {
          const inner = /Icon\s*\(\s*"([^"]+)"/.exec(n);
          n = inner ? inner[1] : n;
        }
        ingredients.push({ name: n, count: c });
      }
      if (ingredients.length === 0) unparsed++;

      // 选项字段
      const builderTag = /builder_tag\s*=\s*"([^"]+)"/.exec(opts);
      const builderSkill = /builder_skill\s*=\s*"([^"]+)"/.exec(opts);
      const productOpt = /product\s*=\s*"([^"]+)"/.exec(opts);
      const numToGive = /numtogive\s*=\s*([^,}]+)/.exec(opts);
      const placer = /placer\s*=\s*"([^"]+)"/.exec(opts);

      const lineNo = countLines(text.slice(0, cm2.index));

      recipes.push({
        fn,
        product,
        loopGenerated,
        ingredients,
        tech,
        builderTag: builderTag ? builderTag[1] : "",
        builderSkill: builderSkill ? builderSkill[1] : "",
        productOpt: productOpt ? productOpt[1] : "",
        numToGive: numToGive ? numToGive[1].trim() : "1",
        placer: placer ? placer[1] : "",
        line: lineNo,
      });
    }
  }

  // --- constants.lua 顶层常量
  const constants = [];
  if (constText) {
    for (const m of matchAll(constText, /^\s*([A-Z][A-Z_0-9]*)\s*=\s*(.+)$/gm)) {
      const name = m[1];
      const raw = m[2].replace(/--.*$/, "").trim().replace(/,\s*$/, "");
      if (!raw) continue;
      constants.push({
        name,
        value: raw,
        isTable: raw.startsWith("{"),
        line: countLines(constText.slice(0, m.index)),
      });
    }
  }

  const techCount = new Map();
  for (const r of recipes) techCount.set(r.tech, (techCount.get(r.tech) || 0) + 1);
  const techSorted = [...techCount.entries()].sort((a, b) => b[1] - a[1]);

  const ingCount = new Map();
  for (const r of recipes) for (const i of r.ingredients) ingCount.set(i.name, (ingCount.get(i.name) || 0) + 1);

  let md = header(
    "DST 配方与物品表（recipes.lua + constants.lua）",
    ["recipes.lua", "constants.lua"],
    "正则 + 启发式。配方用 `Recipe(\"...\",{Ingredient(...)},TECH.X,{...})` 正则匹配；常量用顶层 `NAME = value` 正则匹配。",
    [
      "**配方数量**: 正则可完整匹配 `Recipe`/`Recipe2` 调用（含多行）。材料的数量可能是 TUNING 表达式而非字面数字，此处原样保留表达式文本。",
      "**科技等级**: 原样保留 `TECH.XXX` 常量名。需查具体分级顺序见 `techtree.lua`（本表未展开）。",
      "**制作台**: 从 `PROTOTYPER_DEFS` 提取图标与动作，不含各台可制作物品的完整映射（那部分由上面的配方表 builder_tag 字段体现）。",
      `有 ${unparsed} 条配方匹配到调用但未能解析出材料（可能是空材料或非常规写法），已跳过。`,
    ].join(" ")
  );

  md += `## 统计概览

| 指标 | 数量 |
|---|---|
| 配方总数 | ${recipes.length} |
| 制作台定义数 | ${stations.length} |
| constants.lua 顶层常量数 | ${constants.length} |
| 材料种类数 | ${ingCount.size} |
| 科技等级种类数 | ${techSorted.length} |
| 材料解析失败的配方 | ${unparsed} |
| 合成配方(Recipe/Recipe2) | ${recipes.filter((r) => r.fn !== "DeconstructRecipe").length} |
| 拆解配方(DeconstructRecipe) | ${recipes.filter((r) => r.fn === "DeconstructRecipe").length} |
| 循环批量生成的配方 | ${recipes.filter((r) => r.loopGenerated).length} |
| 科技等级未提取到的配方 | ${recipes.filter((r) => !r.tech && r.fn !== "DeconstructRecipe").length} |

> ⚠循环 表示该配方在源码中由 \`for\` 循环拼接产物名批量生成（如 \`hermitcrabtea_petals_{loop}\`），
> 运行时按等级展开为多条记录。本表条数以**源码调用点**计，非运行时实例数。

\`\`\`bash
# 查找某物品的配方
grep "| \`axe\` |" 配方与物品表.md

# 查找某科技等级的全部配方
grep "TECH.SCIENCE_TWO" 配方与物品表.md
\`\`\`

---

## 1. 配方总表（${recipes.length} 条）

| # | 产物 | 类型 | 材料与数量 | 科技等级 | 制作条件 | 产出数量 | 源文件:行号 |
|---|---|---|---|---|---|---|---|
`;

  recipes.forEach((r, i) => {
    const ings = r.ingredients.map((x) => `${x.name}×${x.count}`).join(", ");
    const cond = r.builderTag ? `builder_tag=${r.builderTag}` : r.builderSkill ? `builder_skill=${r.builderSkill}` : "—";
    const name = r.loopGenerated ? `\`${r.product}\` ⚠循环` : `\`${r.product}\``;
    const typeLabel = r.fn === "DeconstructRecipe" ? "拆解" : r.fn === "Recipe2" ? "合成v2" : "合成v1";
    const techCell = r.tech ? `\`${r.tech}\`` : r.fn === "DeconstructRecipe" ? "不适用" : "未提取到";
    md += `| ${i + 1} | ${name} | ${typeLabel} | ${cell(ings)} | ${techCell} | ${cond} | ${r.numToGive} | recipes.lua:${r.line} |\n`;
  });

  // 材料索引
  md += `\n---\n\n## 2. 材料索引（被使用次数排序）\n\n`;
  const ingSorted = [...ingCount.entries()].sort((a, b) => b[1] - a[1]);
  md += `共 ${ingSorted.length} 种材料。\n\n| 材料名 | 使用次数 |\n|---|---|\n`;
  for (const [ing, c] of ingSorted) {
    md += `| \`${ing}\` | ${c} |\n`;
  }

  // 科技等级统计
  md += `\n---\n\n## 3. 科技等级统计\n\n`;
  md += `| 科技等级 | 配方数 |\n|---|---|\n`;
  for (const [t, c] of techSorted) {
    md += `| \`${t}\` | ${c} |\n`;
  }

  // 制作台
  md += `\n---\n\n## 4. 制作台定义（PROTOTYPER_DEFS）\n\n`;
  md += `| 制作台 | 图标 | 是制作站 | 动作 | 过滤分类 |\n|---|---|---|---|---|\n`;
  for (const s of stations) {
    md += `| \`${s.name}\` | ${cell(s.icon)} | ${s.isStation} | ${cell(s.actionStr)} | ${cell(s.filterText)} |\n`;
  }

  // constants
  md += `\n---\n\n## 5. 关键常量（constants.lua）\n\n`;
  md += `> constants.lua 共 ${constants.length} 条顶层常量。此处按类别节选出常用项；完整清单见下方「全部常量」。\n\n`;

  // 分类常量
  const catRules = [
    ["物品栏与栏位", /INVENTORY|EQUIPSLOT|EQUIPPED_SLOT/i],
    ["季节与天气", /SEASON|WEATHER|WORLDTEMP|TEMPERATURE/i],
    ["工具与耐久", /TOOL|DURABILITY|FRABILITY|USES/i],
    ["战斗与生命", /DAMAGE|ATTACK|HEALTH|ARMOR|FIGHT/i],
    ["饱食度与生命", /HUNGER|FOOD|CALORIE|HUNGRY/i],
    ["理智值", /SANITY|MIND|INSANITY|LUNACY/i],
    ["网络与联机", /NET_|SERVER|CLIENT|MASTER|C2S|S2C/i],
    ["时间与时序", /TIME|_TIME|DAY|NIGHT|DUSK|INTERVAL|DELAY/i],
    ["掉落与概率", /LOOT|DROP|CHANCE|RATE|PERCENT|WEIGHT/i],
    ["烹饪与燃料", /COOK|FOOD|FUEL|BURN|FIRE/i],
    ["生物与属性", /CREATURE|MOB|ANIMAL|MONSTER|HEALTH/i],
  ];

  md += `### 5.1 按类别节选\n\n`;
  for (const [cat, re] of catRules) {
    const hits = constants.filter((c) => re.test(c.name));
    if (hits.length === 0) continue;
    md += `#### ${cat}（${hits.length} 项）\n\n| 常量名 | 值 | 源文件:行号 |\n|---|---|---|\n`;
    for (const c of hits) {
      md += `| \`${c.name}\` | ${cell(c.value.slice(0, 120))} | constants.lua:${c.line} |\n`;
    }
    md += `\n`;
  }

  md += `### 5.2 全部常量（${constants.length} 条）\n\n`;
  md += `| # | 常量名 | 值 | 类型 | 源文件:行号 |\n|---|---|---|---|---|\n`;
  constants.forEach((c, i) => {
    md += `| ${i + 1} | \`${c.name}\` | ${cell(c.value.slice(0, 150))} | ${c.isTable ? "表" : "标量"} | constants.lua:${c.line} |\n`;
  });

  writeOut("配方与物品表.md", md);
  return { recipes, stations, constants };
}

// ===========================================================================
// 5. 数值参数总表
// ===========================================================================

function extractTuning() {
  const tuningText = readLua("tuning.lua");
  const constText = readLua("constants.lua");

  const rows = [];

  // --- tuning.lua: TUNING = { ... } 表内条目 (顶层键, 缩进 8 空格)
  if (tuningText) {
    const tbl = extractTuningTable(tuningText);
    if (tbl) {
      const body = tbl.body;
      const bodyStartLine = countLines(tuningText.slice(0, tbl.openIdx + 1));

      // 顶层键: 缩进恰好 8 空格的 NAME = value (嵌套子表缩进更深, 不会被匹配)
      const entryRe = /^ {8}([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*)$/gm;
      let m;
      while ((m = entryRe.exec(body)) !== null) {
        const name = m[1];
        // 去掉行尾注释(注意不要误伤字符串内的 --)
        let rawVal = m[2];
        let comment = "";
        const strEnd = rawVal.search(/"[^"]*"/g);
        const cIdx = strEnd >= 0 ? rawVal.indexOf("--", strEnd + 1) : rawVal.indexOf("--");
        if (cIdx >= 0) {
          comment = rawVal.slice(cIdx + 2).trim();
          rawVal = rawVal.slice(0, cIdx);
        }
        rawVal = rawVal.trim().replace(/,\s*$/, "");
        if (!rawVal) continue;
        const line = bodyStartLine + countLines(body.slice(0, m.index));
        const isTable = rawVal.startsWith("{");
        const isNumeric = /^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$/.test(rawVal);
        rows.push({
          scope: "TUNING",
          name,
          value: rawVal,
          unit: guessUnit(name),
          line,
          srcFile: "tuning.lua",
          isTable,
          isNumeric,
          comment,
          note: "",
        });
      }
    }

    // Tune() 函数内的顶层 local 数值变量 (影响多个 TUNING 值的派生量)
    for (const m of matchAll(tuningText, /^\s{4}local\s+([a-z_][A-Za-z_0-9]*)\s*=\s*([-0-9. *\/\w]+?)\s*(?:--(.*))?$/gm)) {
      const name = m[1];
      const rawVal = m[2].trim();
      if (!/^[-0-9.]/.test(rawVal)) continue;
      rows.push({
        scope: "local",
        name,
        value: rawVal,
        unit: guessUnit(name),
        line: countLines(tuningText.slice(0, m.index)),
        srcFile: "tuning.lua",
        isTable: false,
        isNumeric: /^[-0-9.]+$/.test(rawVal),
        comment: m[3] ? m[3].trim() : "",
        note: "派生量, 参与 TUNING 计算",
      });
    }
  }

  // --- constants.lua 顶层标量常量
  if (constText) {
    for (const m of matchAll(constText, /^([A-Z][A-Z_0-9]*)\s*=\s*([^\n]+)$/gm)) {
      const name = m[1];
      let rawVal = m[2].replace(/--.*$/, "").trim().replace(/,\s*$/, "");
      if (!rawVal || rawVal.startsWith("{")) continue;
      if (!/^[-+0-9]/.test(rawVal)) continue; // 仅数值型
      rows.push({
        scope: "CONST",
        name,
        value: rawVal,
        unit: guessUnit(name),
        line: countLines(constText.slice(0, m.index)),
        srcFile: "constants.lua",
        isTable: false,
        isNumeric: /^[-+]?[0-9]*\.?[0-9]+$/.test(rawVal),
        comment: "",
        note: "",
      });
    }
  }

  const numericCount = rows.filter((r) => r.isNumeric).length;
  const tableCount = rows.filter((r) => r.isTable).length;

  let md = header(
    "DST 数值参数总表（tuning.lua + constants.lua + 组件默认值）",
    ["tuning.lua", "constants.lua", "components/hunger.lua", "components/sanity.lua", "components/health.lua", "components/fueled.lua", "components/perishable.lua"],
    "正则 + 花括号配平。tuning.lua 的 TUNING 表通过逐字符配平花括号（跳过字符串与注释）定位表体，再按「缩进 8 空格 + NAME = value」提取顶层条目。",
    [
      "**仅提取顶层键**。TUNING 表内 93 个嵌套子表（如 `TUNING.SANITY = {...}`）的内部字段未展开，标为「表」。",
      "值为表达式（如 `wilson_health * 0.5`）时原样保留文本，其最终值需结合 local 变量求值。",
      "单位列为**按变量名推断**（如 `_PER_SECOND` → 次/秒），非源码显式声明，仅供快速定位。",
      "组件默认值（hunger/sanity/health 等）另见第 5 节，其中多数直接引用 TUNING 常量而非硬编码。",
    ].join(" ")
  );

  md += `## 统计概览

| 指标 | 数量 |
|---|---|
| 数值条目总数 | ${rows.length} |
| 纯数字字面量 | ${numericCount} |
| 表（未展开） | ${tableCount} |
| TUNING 条目 | ${rows.filter((r) => r.scope === "TUNING").length} |
| CONST 条目 | ${rows.filter((r) => r.scope === "CONST").length} |
| local 派生量 | ${rows.filter((r) => r.scope === "local").length} |

\`\`\`bash
# 查找某个数值
grep "MAX_HEALTH" 数值参数总表.md

# 找出所有每秒类参数
grep "次/秒" 数值参数总表.md
\`\`\`

---

## 1. 生存核心数值（按主题筛选）

> 从全量条目中按主题关键词节选，便于开发时快速定位。**完整清单见第 4 节**。

`;

  const themes = [
    ["生命值与伤害", /MAX_HEALTH|_HEALTH\b|DAMAGE|ATTACK|ARMOR/],
    ["饱食度与食物", /HUNGER|CALOR|FOOD|HEART|VESSEL/],
    ["理智值", /SANITY|INSANITY|LUNACY|MIND/],
    ["温度与体温", /TEMP|WARMTH|COOL|FREEZ|CHILL|HEAT/],
    ["时间与时序", /SEG_TIME|DAY_TIME|NIGHT|DUSK|TOTAL_DAY|AUTOSAVE|TICK/],
    ["掉落与概率", /DROP|CHANCE|PERCENT|SPAWN|RATE/],
    ["燃料与烹饪", /FUEL|BURN|COOK|FUELED/],
    ["腐烂与保鲜", /PERISH|FRESH/],
    ["制作台与科技", /TECH|PROTOTYP|RESEARCH|SCIENCE/],
    ["世界生成", /WORLD|WILDLIFE|SPAWN|ANIMAL/],
  ];

  for (const [title, re] of themes) {
    const hits = rows.filter((r) => re.test(r.name));
    if (hits.length === 0) continue;
    md += `### ${title}（${hits.length} 项）\n\n`;
    md += `| 名称 | 值 | 单位 | 来源文件:行号 | 作用 |\n|---|---|---|---|---|\n`;
    for (const h of hits.slice(0, 80)) {
      md += `| \`${h.name}\` | ${cell(h.value.slice(0, 60))} | ${h.unit || "—"} | ${h.srcFile}:${h.line} | ${cell((h.comment || describeName(h.name)).slice(0, 80))} |\n`;
    }
    if (hits.length > 80) md += `\n> 该主题共 ${hits.length} 项，此处仅显示前 80 项，完整内容见第 4 节。\n`;
    md += `\n`;
  }

  // 组件默认值
  md += `---\n\n## 2. 组件默认值\n\n`;
  const compFiles = ["hunger", "sanity", "health", "fueled", "perishable", "freezable", "combustible", "fuelregen", "sleepable", "electric"];
  md += `| 组件 | 默认值定义 | 源文件:行号 |\n|---|---|---|\n`;
  for (const c of compFiles) {
    const t = readLua(`components/${c}.lua`);
    if (!t) {
      md += `| \`${c}\` | 未提取到（文件不存在） | — |\n`;
      continue;
    }
    // 收集组件内 TUNING 引用与字面默认
    const tuningRefs = uniq(matchAll(t, /TUNING\.([A-Z_0-9]+)/g).map((m) => m[1]));
    const lineNo = tuningRefs.length > 0 ? 1 : 1;
    md += `| \`${c}\` | ${tuningRefs.length > 0 ? `引用 TUNING: ${joinCell(tuningRefs, 8)}` : "无 TUNING 引用（使用字面常量）"} | components/${c}.lua |\n`;
  }

  md += `\n**说明**: DST 组件普遍不硬编码数值，而是引用 \`TUNING.*\`，因此本表以 TUNING 为准。\n\n`;

  // 组件内字面默认值
  md += `### 2.1 组件内字面数值常量\n\n`;
  md += `| 组件 | 变量名 | 值 | 单位 | 源文件:行号 |\n|---|---|---|---|---|\n`;
  let litCount = 0;
  for (const c of compFiles) {
    const t = readLua(`components/${c}.lua`);
    if (!t) continue;
    for (const m of matchAll(t, /^\s*([A-Za-z_][A-Za-z_0-9]*)\s*=\s*([-+]?[0-9]*\.?[0-9]+)\s*(?:--(.*))?$/gm)) {
      const v = m[2];
      if (!/^[-+]?[0-9]*\.?[0-9]+$/.test(v)) continue;
      // 过滤明显是循环索引/计数器的变量
      if (/^(i|j|k|n|idx|index|count|num|step)$/i.test(m[1])) continue;
      litCount++;
      md += `| \`${c}\` | \`${m[1]}\` | ${v} | ${guessUnit(m[1]) || "—"} | components/${c}.lua:${countLines(t.slice(0, m.index))} |\n`;
    }
  }
  if (litCount === 0) md += `| — | 未提取到 | — | — | — |\n`;

  // local 派生量
  md += `\n---\n\n## 3. Tune() 局部派生量\n\n`;
  md += `> 这些是 tuning.lua 中参与 TUNING 计算的局部变量，理解它们才能求值含表达式的 TUNING 项。\n\n`;
  md += `| 变量名 | 值 | 单位 | 源文件:行号 | 注释 |\n|---|---|---|---|---|\n`;
  for (const r of rows.filter((x) => x.scope === "local")) {
    md += `| \`${r.name}\` | ${cell(r.value)} | ${r.unit || "—"} | tuning.lua:${r.line} | ${cell(r.comment || r.note)} |\n`;
  }

  // 全量
  md += `\n---\n\n## 4. 全量数值清单（${rows.length} 条）\n\n`;
  md += `| # | 名称 | 值 | 单位 | 来源 | 源文件:行号 | 注释/作用 |\n|---|---|---|---|---|---|---|\n`;
  rows.forEach((r, i) => {
    const scopeLabel = r.scope === "TUNING" ? "TUNING" : r.scope === "CONST" ? "CONST" : "local";
    md += `| ${i + 1} | \`${r.name}\` | ${cell(r.value.slice(0, 70))} | ${r.unit || "—"} | ${scopeLabel} | ${r.srcFile}:${r.line} | ${cell((r.comment || describeName(r.name)).slice(0, 60))} |\n`;
  });

  writeOut("数值参数总表.md", md);
  return { rows };
}

/** 按变量名推断单位 (启发式) */
function guessUnit(name) {
  const n = name.toUpperCase();
  if (/_PER_SECOND\b|PERSEC|PER_SEC/.test(n)) return "次/秒";
  if (/_PER_DAY\b|PERDAY/.test(n)) return "次/天";
  if (/_PER_MONTH|PERMONTH/.test(n)) return "次/月";
  if (/_TIME\b|_TIMES\b|_DELAY\b|_INTERVAL\b|_COOLDOWN\b/.test(n)) return "秒";
  if (/_CD\b|_TIMEOUT\b/.test(n)) return "秒";
  if (/_PERCENT\b|_PCT\b/.test(n)) return "%";
  if (/_RATE\b|_MULT\b|_MOD\b|_FACTOR\b/.test(n)) return "倍率";
  if (/_DAMAGE\b|_ATTACK\b/.test(n)) return "点";
  if (/_HEALTH\b/.test(n)) return "点";
  if (/_RADIUS\b|_DISTANCE\b|_RANGE\b/.test(n)) return "距离";
  if (/_SPEED\b|_VELOCITY\b/.test(n)) return "速度";
  if (/_HUNGER\b/.test(n)) return "饥饿值";
  if (/_SANITY\b/.test(n)) return "理智值";
  if (/_TEMP\b|TEMPERATURE/.test(n)) return "温度";
  if (/_CALORIE|CALORIES/.test(n)) return "卡路里";
  if (/_SEASON|_DAY\b|DAY_LENGTH/.test(n)) return "天";
  if (/_TILE\b/.test(n)) return "格";
  if (/_SCALE\b/.test(n)) return "缩放";
  if (/_WEIGHT\b/.test(n)) return "重量";
  if (/_FUEL\b/.test(n)) return "燃料";
  return "";
}

/** 按变量名生成简短作用说明 (启发式, 基于命名约定) */
function describeName(name) {
  const n = name.toUpperCase();
  const parts = [];
  if (/MAX_HEALTH|HEALTH_MAX/.test(n)) parts.push("生命值上限");
  else if (/ATTACK/.test(n)) parts.push("攻击力");
  else if (/DAMAGE/.test(n)) parts.push("伤害值");
  else if (/HUNGER/.test(n)) parts.push("饱食度相关");
  else if (/SANITY|INSANITY|LUNACY/.test(n)) parts.push("理智值相关");
  else if (/PERISH/.test(n)) parts.push("腐败相关");
  else if (/FUEL/.test(n)) parts.push("燃料相关");
  else if (/COOK/.test(n)) parts.push("烹饪相关");
  else if (/SPAWN/.test(n)) parts.push("生成相关");
  else if (/DROP|LOOT/.test(n)) parts.push("掉落相关");
  else if (/ARMOR/.test(n)) parts.push("护甲相关");
  else if (/TEMPERATURE|_TEMP\b|THERMOMETER/.test(n)) parts.push("温度相关");
  else if (/WALK_SPEED|MOVE_SPEED|_SPEED/.test(n)) parts.push("移动速度");
  else if (/TECH|PROTOTYP/.test(n)) parts.push("科技/制作相关");
  else if (/DAY|NIGHT|DUSK|SEG_TIME/.test(n)) parts.push("时间周期相关");
  else return "—";
  return parts.join(" / ");
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

console.log("DST 数据提取开始");
console.log(`源码根目录: ${SRC}`);
console.log(`输出目录:   ${OUT}\n`);

if (!fs.existsSync(SRC)) {
  console.error(`错误: 源码目录不存在 -> ${SRC}`);
  process.exit(1);
}
if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });

console.log("[1/5] 提取预制体...");
const p = extractPrefabs();
console.log("[2/5] 提取组件...");
const c = extractComponents();
console.log("[3/5] 提取状态图与大脑...");
const s = extractStategraphBrain();
console.log("[4/5] 提取配方与常量...");
const r = extractRecipes();
console.log("[5/5] 提取数值参数...");
const t = extractTuning();

console.log("\n完成:");
console.log(`  预制体      ${p.rows.length} 条`);
console.log(`  组件        ${c.rows.length} 条`);
console.log(`  状态图      ${s.sgRows.length} 条`);
console.log(`  大脑        ${s.brainRows.length} 条`);
console.log(`  配方        ${r.recipes.length} 条`);
console.log(`  制作台      ${r.stations.length} 条`);
console.log(`  常量        ${r.constants.length} 条`);
console.log(`  数值条目    ${t.rows.length} 条`);