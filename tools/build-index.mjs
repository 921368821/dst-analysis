#!/usr/bin/env node
/**
 * build-index.mjs —— 生成注释源码总索引
 * 扫描注释版目录，按模块统计文件数与行数，输出 Markdown 索引。
 */
import { readdirSync, statSync, readFileSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const ROOT = process.argv[2] ?? ANN_SCRIPTS;
// 索引 md 放在 `02-注释源码/` 下（scripts 的上一级）
const OUT = process.argv[3] ?? join(ANN_SCRIPTS, "..", "注释源码总索引.md");

const MODULE_CN = {
  "": "根目录核心框架",
  prefabs: "预制体（实体工厂）",
  components: "组件系统",
  map: "地图与世界生成",
  stategraphs: "状态图（AI 行为机）",
  brains: "AI 大脑",
  widgets: "UI 控件",
  screens: "界面",
  behaviours: "行为树",
  scenarios: "冒险剧本",
  util: "工具函数",
  tools: "开发工具",
  languages: "本地化",
  cameras: "摄像机",
};

function walk(dir, acc = []) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) walk(p, acc);
    else if (n.endsWith(".lua")) acc.push(p);
  }
  return acc;
}

const files = walk(ROOT);
const byModule = new Map();
let totalLines = 0;
let totalCommentLines = 0;

for (const f of files) {
  const rel = relative(ROOT, f);
  const parts = rel.split(/[\\/]/);
  const mod = parts.length > 1 ? parts[0] : "";
  const raw = readFileSync(f, "utf8");
  const lines = raw.split(/\r?\n/).length;
  const commentLines = raw.split(/\r?\n/).filter((l) => l.trim().startsWith("--")).length;
  totalLines += lines;
  totalCommentLines += commentLines;

  if (!byModule.has(mod)) byModule.set(mod, { files: 0, lines: 0, comment: 0 });
  const m = byModule.get(mod);
  m.files++;
  m.lines += lines;
  m.comment += commentLines;
}

const rows = [...byModule.entries()]
  .sort((a, b) => b[1].files - a[1].files)
  .map(([mod, s]) => {
    const name = MODULE_CN[mod] ?? mod;
    const pct = ((s.comment / s.lines) * 100).toFixed(1);
    return `| \`${mod || "(根)"}\` | ${name} | ${s.files} | ${s.lines.toLocaleString()} | ${s.comment.toLocaleString()} | ${pct}% |`;
  });

const md = `# 《饥荒联机版》中文注释源码 · 总索引

> 全部 Lua 源码均已添加中文注释。本索引用于快速定位文件。
> 注释规范见 \`../00-注释规范与术语表.md\`。

## 总览

| 指标 | 数值 |
|---|---|
| 文件总数 | **${files.length.toLocaleString()}** |
| 代码总行数 | ${totalLines.toLocaleString()} |
| 注释行数 | ${totalCommentLines.toLocaleString()} |

## 按模块分布

| 目录 | 中文模块 | 文件数 | 总行数 | 注释行 | 注释占比 |
|---|---|---:|---:|---:|---:|
${rows.join("\n")}

## 阅读顺序建议

若目标是**仿写一个类饥荒的生存游戏**，建议按此顺序阅读：

1. **\`class.lua\`** —— 理解 OOP 基础设施（已深度注释，可作范本）
2. **\`entityscript.lua\`** —— 实体生命周期与事件总线
3. **\`scheduler.lua\`** —— tick 调度与协程
4. **\`prefabs/(任意简单实体).lua\`** —— 看懂预制体怎么组装
5. **\`components/sanity.lua\` / \`hunger.lua\` / \`health.lua\`** —— 三大生存属性
6. **\`player.lua\` + \`playercontroller.lua\`** —— 角色与控制
7. **\`components/locomotor.lua\`** —— 移动与物理
8. **\`actions.lua\`** —— 玩家动作体系
9. **\`inventory*.lua\` + \`recipe.lua\`** —— 物品与合成
10. **\`map/\`** —— 世界生成
11. **\`stategraphs/ + brains/\`** —— AI
12. **\`lighting.lua\` + \`time.lua\`** —— 光照与昼夜

## 核心文件深度注释状态

以下文件已手工逐行深度注释，可直接作为理解全系统的参考范本：

| 文件 | 说明 |
|---|---|
| \`scripts/class.lua\` | 面向对象基础设施，逐行注释 |
| \`scripts/entityscript.lua\` | 实体生命周期 |
| \`scripts/scheduler.lua\` |任务调度 |
| \`scripts/main.lua\` | 主循环 |

其余文件均含中文文件头（模块归属 + 职责 + 关键机制），按需深入时再逐函数阅读。
`;

writeFileSync(OUT, md, "utf8");
console.log(md.split("\n").slice(0, 8).join("\n"));
console.log(`\n索引已写入: ${OUT}`);