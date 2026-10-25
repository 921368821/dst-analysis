/**
 * 架构守护测试
 *
 * ★ 这个文件的地位：它是"架构"与"文档里的架构"之间的唯一区别。
 *   没有它，"分层"只是一段注释 —— 而注释不会阻止任何人 `import` 一个不该 import 的东西。
 *   上一代引擎的架构腐化就是这样发生的：每一处越界都有"这次特殊"的理由，
 *   半年后没有人能说出"谁依赖谁"。
 *
 * 五条规则：
 *  1. 层依赖方向（L0..L5，只能向下）
 *  2. L1 不许出现平台类型（WebGL/HTMLCanvas/document/…）
 *  3. L2/L3 不许出现环境随机与墙钟（Math.random / Date.now / performance.now）
 *  4. 只有组合根可以 import 具体后端
 *  5. 没有未分类的顶层目录（新增目录必须登记层级）
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { checkLayerRules, scan, type Layer } from "./scan.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "..", "..", "src");
const files = scan(SRC);

test("架构：src 能被扫描到（前置）", () => {
  assert.ok(files.length >= 15, `只扫到 ${files.length} 个文件 —— 路径或扫描逻辑坏了`);
});

test("规则 1 · 层依赖只能向下（L0 ← L1 ← L2 ← L3，后端只依赖 L0/L1）", () => {
  const bad = checkLayerRules(files);
  const msg = bad
    .map((v) => `  ${v.file}  [${v.fromLayer}] → [${v.toLayer}]  ${v.spec}`)
    .join("\n");
  assert.equal(bad.length, 0, `发现 ${bad.length} 处越层依赖：\n${msg}`);
});

test("规则 2 · L1 平台层不许出现平台专有类型（抽象必须可移植）", () => {
  const forbidden = [
    "WebGL2RenderingContext",
    "WebGLRenderingContext",
    "HTMLCanvasElement",
    "CanvasRenderingContext2D",
    "AudioContext",
    "document.",
    "window.",
  ];
  const hits: string[] = [];
  for (const f of files) {
    if (f.layer !== "L1-platform") continue;
    for (const bad of forbidden) {
      if (f.code.includes(bad)) hits.push(`${f.rel}: ${bad}`);
    }
  }
  assert.equal(
    hits.length,
    0,
    `L1 出现了平台专有类型（应改为 unknown/接口，由后端收窄）：\n  ${hits.join("\n  ")}`,
  );
});

test("规则 3 · L2/L3 不许直接取环境随机与墙钟", () => {
  const forbidden = ["Math.random(", "Date.now(", "performance.now("];
  const hits: string[] = [];
  for (const f of files) {
    if (f.layer !== "L2-core" && f.layer !== "L3-runtime") continue;
    for (const bad of forbidden) {
      const at = f.code.indexOf(bad);
      if (at >= 0) {
        const line = f.code.slice(0, at).split("\n").length;
        hits.push(`${f.rel}:${line}: ${bad}`);
      }
    }
  }
  assert.equal(
    hits.length,
    0,
    `内核层出现了环境随机/墙钟（应使用注入的 IRandom / IClock）：\n  ${hits.join("\n  ")}`,
  );
});

test("规则 4 · 只有组合根（GameApp）可以 import 具体后端", () => {
  const hits: string[] = [];
  for (const f of files) {
    if (!f.imports.some((s) => s.includes("backends/"))) continue;
    const isRootAggregator = f.layer === "root";
    const isCompositionRoot = f.rel === "runtime/GameApp.ts";
    if (!isRootAggregator && !isCompositionRoot) {
      hits.push(`${f.rel} → ${f.imports.filter((s) => s.includes("backends/")).join(", ")}`);
    }
  }
  assert.equal(
    hits.length,
    0,
    `以下文件绕过了组合根直接引用后端（会让"换后端"变成改多处）：\n  ${hits.join("\n  ")}`,
  );
});

test("规则 5 · 每个顶层目录都必须登记层级（新增目录不许'默认放行'）", () => {
  // ★ 这个白名单必须**手写**，不能从 ALLOWED 的 key 反推 ——
  //   层名是 `L5-backend`（单数），目录是 `backends`（复数），反推会永远对不上。
  //   第一次跑这条规则时就是这么红的：它把 backends 判成"未分类"。
  const KNOWN_DIRS = new Set([
    "foundation",
    "platform",
    "core",
    "runtime",
    "script",
    "extensions",
    "backends",
    "host",
  ]);
  const tops = new Set<string>();
  for (const f of files) {
    const first = f.rel.split("/")[0]!;
    if (f.rel.includes("/")) tops.add(first);
  }
  const unknown = [...tops].filter((t) => !KNOWN_DIRS.has(t));
  assert.equal(
    unknown.length,
    0,
    `未分类的顶层目录：${unknown.join(", ")} —— 在 tests/arch/scan.ts 的 LAYER_BY_DIR 与本白名单里登记它属于哪层`,
  );
});

test("规则 6 · 层级映射本身符合预期（错误会让规则 1 形同虚设）", () => {
  const byLayer = new Map<Layer, number>();
  for (const f of files) byLayer.set(f.layer, (byLayer.get(f.layer) ?? 0) + 1);
  for (const must of ["L0-foundation", "L1-platform", "L2-core", "L3-runtime", "L5-backend"] as const) {
    assert.ok((byLayer.get(must) ?? 0) > 0, `层 ${must} 里一个文件都没有 —— 要么目录改名了，要么规则失效`);
  }
});
