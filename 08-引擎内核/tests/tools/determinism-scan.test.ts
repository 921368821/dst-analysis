/**
 * 确定性闸门的判据
 *
 * 为什么这条闸门必须有单测：它今天的输出是「0 处违规」，而**一个恒不输出的
 * 扫描器**与**一个真的干净仓库**，报告一个字都不差。所以每条规则、每条守卫
 * 都要用**合成语料**正向打一发 —— 删掉被测逻辑，必须有一条红。
 *
 * ★ 为什么还要用**真实文件**打一次：合成语料能证明"这段逻辑对"，但不能证明
 *   "它接上了真仓库"。所以 ④ 把 `src/extensions/motion/intent.ts` 的真内容读进来、
 *   在内存里把一处 `planeLen` 换成 `Math.hypot`，再喂给同一个 `scan` ——
 *   不写盘（并行跑判据时改 src 会让别的文件读到坏代码），但走的是真路径与真行号。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { collect, scan } from "../../tools/determinism-scan.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** 与工具里同一份规则/白名单形状（这里只要 id 与 pattern 正确即可）。 */
const RULE = [
  {
    id: "hypot",
    pattern: /Math\.hypot\s*\(/g,
    expect: 1,
    why: "",
    fix: "",
  },
];

const file = (path: string, text: string) => ({ path, text });

test("[闸门] 违规未登记 → 报出文件、行号与规则名", () => {
  const r = scan([file("src/a.ts", "const a = 1;\nconst d = Math.hypot(dx, dz);\n")], RULE, []);
  assert.equal(r.violations.length, 1);
  const v = r.violations[0];
  assert.ok(v !== undefined);
  assert.equal(v.line, 2);
  assert.equal(v.path, "src/a.ts");
  assert.equal(v.rule, "hypot");
});

test("[闸门] 在白名单里 → 无违规；换一个文件 → 照样红（键精确到文件）", () => {
  const allow = [{ file: "src/a.ts", rule: "hypot", why: "测试" }];
  const same = scan([file("src/a.ts", "Math.hypot(1, 2);\n")], RULE, allow);
  assert.equal(same.violations.length, 0);
  assert.equal(same.unusedAllow.length, 0);

  const other = scan([file("src/b.ts", "Math.hypot(1, 2);\n")], RULE, allow);
  assert.equal(other.violations.length, 1, "白名单只对登记的那个文件生效");
  assert.equal(other.unusedAllow.length, 1, "同时那条白名单变成了陈旧条目");
});

test("[闸门] 陈旧白名单必须报出来（文件改名 / 那段代码被删 ⇒ 它在替未来的违规打掩护）", () => {
  const r = scan([file("src/a.ts", "const d = planeLen(dx, dz);\n")], RULE, [
    { file: "src/a.ts", rule: "hypot", why: "测试" },
  ]);
  assert.equal(r.unusedAllow.length, 1);
});

test("[闸门] 规则失效（正则写错 ⇒ 永远 0 命中）时不会假装干净", () => {
  const broken = [{ ...RULE[0]!, pattern: /Math\.hypott\s*\(/g }];
  const r = scan([file("src/a.ts", "Math.hypot(1, 2);\n")], broken, []);
  assert.equal(r.violations.length, 0);
  assert.equal(r.stale.length, 1, "命中数与登记值不符要报出来");
  assert.equal(r.stale[0]?.actual, 0);
});

test("[闸门] 整行注释里的提及不算违规，但代码行上的调用不豁免", () => {
  const comment = scan([file("src/a.ts", "// Math.hypot(a, b)\n")], RULE, []);
  assert.equal(comment.violations.length, 0);
  assert.equal(comment.hitsByRule.get("hypot"), 0);

  const code = scan([file("src/a.ts", "const d = Math.hypot(a, b); // 旧写法\n")], RULE, []);
  assert.equal(code.violations.length, 1, "行首是代码就照样判 —— 否则注释成了后门");
});

test("[闸门] ★ 真仓库：collect 收到足够多的文件，且包含 planeLen 的定义处", () => {
  const files = collect(join(ROOT, "src"));
  assert.ok(files.length >= 200, `只收到 ${String(files.length)} 个文件 —— collect 可能没接上`);
  assert.ok(
    files.includes("src/foundation/math/scalar.ts"),
    "连 planeLen 的定义文件都没收到，路径一定错了",
  );
  assert.ok(
    files.every((f) => f.endsWith(".ts")),
    "收到了非 .ts 的东西（扩展名过滤失效）",
  );
});

test("[闸门] ★ 用真实文件内容注入一处违规 → 报出真实路径与行号", () => {
  const rel = "src/extensions/motion/intent.ts";
  const text = readFileSync(join(ROOT, rel), "utf8");
  assert.ok(text.includes("planeLen(dx, dz)"), "真实文件里没有 planeLen —— 替换那批活被回滚了？");

  const broken = text.replace("const len = planeLen(dx, dz);", "const len = Math.hypot(dx, dz);");
  assert.notEqual(broken, text, "注入没生效");

  const r = scan([file(rel, broken)], RULE, []);
  assert.equal(r.violations.length, 1);
  const line = r.violations[0]?.line ?? -1;
  // 报出来的那一行，在**原始文件**里确实是要修的那一行
  assert.ok(
    (text.split("\n")[line - 1] ?? "").includes("planeLen(dx, dz)"),
    `行号 ${String(line)} 指错了地方`,
  );
});

test("[闸门] ★ 真仓库当前是干净的（直接运行工具的退出码为 0）", () => {
  const r = spawnSync(process.execPath, [join(ROOT, "tools", "determinism-scan.mjs")], {
    cwd: ROOT,
    encoding: "utf8",
  });
  assert.equal(r.status, 0, `闸门红了：\n${r.stdout ?? ""}${r.stderr ?? ""}`);
  assert.match(r.stdout ?? "", /✓ 确定性闸门：\d+ 个文件/);
});

test("[闸门] 自检模式全过（四种守卫都在合成语料上正向打过）", () => {
  const r = spawnSync(process.execPath, [join(ROOT, "tools", "determinism-scan.mjs"), "--selftest"], {
    cwd: ROOT,
    encoding: "utf8",
  });
  assert.equal(r.status, 0, r.stderr ?? "");
  assert.match(r.stdout ?? "", /自检：8\/8 通过/);
});
