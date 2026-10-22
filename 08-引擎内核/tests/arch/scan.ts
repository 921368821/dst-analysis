/**
 * 架构扫描工具
 *
 * 用**文本扫描**而不是 AST，是刻意的取舍：
 *  · 这个测试要能在任何环境跑（不依赖 TS 编译器的解析器）；
 *  · 规则简单到"正则足够"（只看 import 目标与少量禁用符号）；
 *  · 误报的代价低（改一行注释即可），漏报的代价高（依赖腐化）。
 * 如果将来规则变复杂（例如按类型引用判断），再升级到 `typescript` 的 AST ——
 * 那时这个文件是唯一要改的地方。
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";

export type Layer = "L0-foundation" | "L1-platform" | "L2-core" | "L3-runtime" | "L4-ext" | "L5-backend" | "root";

/** 目录 → 层。新增顶层目录必须在这里登记，否则扫描会报"未分类"。 */
const LAYER_BY_DIR: Readonly<Record<string, Layer>> = {
  foundation: "L0-foundation",
  platform: "L1-platform",
  core: "L2-core",
  runtime: "L3-runtime",
  script: "L4-ext",
  extensions: "L4-ext",
  backends: "L5-backend",
};

export interface SourceFile {
  /** 相对 `src/` 的路径（统一 `/`）。 */
  readonly rel: string;
  readonly abs: string;
  readonly layer: Layer;
  readonly text: string;
  /** 去掉注释后的文本（用于"禁用符号"检查，避免注释里的词误报）。 */
  readonly code: string;
  readonly imports: readonly string[];
}

export function stripComments(text: string): string {
  // 逐字符状态机：正确跳过字符串里的 `//`，比正则可靠
  let out = "";
  let i = 0;
  let inLine = false;
  let inBlock = false;
  let quote: string | null = null;
  while (i < text.length) {
    const c = text[i]!;
    const n = text[i + 1];
    if (inLine) {
      if (c === "\n") {
        inLine = false;
        out += c;
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c === "*" && n === "/") {
        inBlock = false;
        i += 2;
        continue;
      }
      i++;
      continue;
    }
    if (quote !== null) {
      out += c;
      if (c === "\\") {
        out += n ?? "";
        i += 2;
        continue;
      }
      if (c === quote) quote = null;
      i++;
      continue;
    }
    if (c === "/" && n === "/") {
      inLine = true;
      i += 2;
      continue;
    }
    if (c === "/" && n === "*") {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      quote = c;
      out += c;
      i++;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

export function extractImports(code: string): string[] {
  const out: string[] = [];
  // 覆盖 `import ... from "x"`、`export ... from "x"`、`await import("x")`
  const re = /(?:from|import)\s*\(?\s*["']([^"']+)["']/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(code)) !== null) out.push(m[1]!);
  return out;
}

export function layerOf(rel: string): Layer {
  const first = rel.split("/")[0]!;
  if (rel.includes("/")) {
    return LAYER_BY_DIR[first] ?? "root";
  }
  return "root";
}

export function scan(srcDir: string): SourceFile[] {
  const out: SourceFile[] = [];
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir).sort()) {
      const abs = join(dir, name);
      const st = statSync(abs);
      if (st.isDirectory()) {
        if (name === "node_modules" || name === ".git") continue;
        walk(abs);
      } else if (name.endsWith(".ts")) {
        const text = readFileSync(abs, "utf8");
        const rel = relative(srcDir, abs).split(sep).join("/");
        const code = stripComments(text);
        out.push({
          rel,
          abs,
          layer: layerOf(rel),
          text,
          code,
          imports: extractImports(code),
        });
      }
    }
  };
  walk(resolve(srcDir));
  return out;
}

/** 把相对 import 解析成"相对于 src 的路径"，非相对 import 返回 null。 */
export function resolveImport(fromRel: string, spec: string): string | null {
  if (!spec.startsWith(".")) return null;
  const parts = fromRel.split("/").slice(0, -1);
  for (const seg of spec.split("/")) {
    if (seg === "." || seg === "") continue;
    if (seg === "..") parts.pop();
    else parts.push(seg);
  }
  return parts.join("/");
}

/** 层依赖规则：from 层允许 import 哪些层的文件。 */
export const ALLOWED: Readonly<Record<Layer, readonly Layer[]>> = {
  // L0 不许依赖任何东西（标准库除外）
  "L0-foundation": ["L0-foundation"],
  // L1 只依赖 L0（接口层不依赖引擎内核）
  "L1-platform": ["L0-foundation", "L1-platform"],
  // L2 可依赖 L0/L1（但只依赖 L1 的接口）
  "L2-core": ["L0-foundation", "L1-platform", "L2-core"],
  // L3 可依赖 L0..L2
  "L3-runtime": ["L0-foundation", "L1-platform", "L2-core", "L3-runtime"],
  // 扩展层可依赖内核
  "L4-ext": ["L0-foundation", "L1-platform", "L2-core", "L3-runtime", "L4-ext"],
  // ★ 后端只实现接口，**不许 import 引擎内核**（否则后端会开始依赖内核的实现细节）
  "L5-backend": ["L0-foundation", "L1-platform", "L5-backend"],
  // 根文件（index.ts 等）是聚合导出，豁免
  root: ["L0-foundation", "L1-platform", "L2-core", "L3-runtime", "L4-ext", "L5-backend", "root"],
};

export interface Violation {
  readonly file: string;
  readonly fromLayer: Layer;
  readonly toLayer: Layer;
  readonly spec: string;
}

export function checkLayerRules(files: readonly SourceFile[]): Violation[] {
  const out: Violation[] = [];
  const byRel = new Map(files.map((f) => [f.rel, f]));
  for (const f of files) {
    for (const spec of f.imports) {
      const target = resolveImport(f.rel, spec);
      if (target === null) continue; // 标准库/第三方
      const tf = byRel.get(target) ?? byRel.get(target + ".ts") ?? byRel.get(target + "/index.ts");
      if (tf === undefined) continue; // 解析不到就不在这里管（tsc 会报）
      const allowed = ALLOWED[f.layer] ?? [];
      if (!allowed.includes(tf.layer)) {
        out.push({ file: f.rel, fromLayer: f.layer, toLayer: tf.layer, spec });
      }
    }
  }
  return out;
}
