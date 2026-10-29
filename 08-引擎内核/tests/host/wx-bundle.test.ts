/**
 * `tools/wx-check.mjs` 的判据。
 *
 * ★ 为什么这些用例必须**自己造语料**，而不是只跑一次真实产物：
 *
 *   `wx-check` 的输出恒为「✓」时才通过（问题列表为空）。而"问题列表恒为空"有两种成因：
 *   产物真的干净，或者**判定逻辑压根没在判**（正则写错、字段读错、函数被短路）。
 *   只跑真实产物分不清这两种 —— 它会一直绿，直到真机上白屏。
 *
 *   所以每条规则都要有一段**故意违规**的合成语料把它打红，另加一段正常的打绿
 *   （否则"永远返回问题"也能让上面那句成立）。真实产物由 CI 那一步跑（`node tools/wx-check.mjs`）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { checkWxBundle, MIN_BUNDLE_BYTES } from "../../tools/wx-check.mjs";

/** 一份"最小但合格"的产物：够长、IIFE、带 globalName、没有 ESM 与 node 内置。 */
function good(): string {
  // 用注释撑到体积下限之上：内容是无关的，关键是长度要过 MIN_BUNDLE_BYTES。
  const filler = "// 填充\n".repeat(Math.ceil(MIN_BUNDLE_BYTES / 9) + 10);
  return `var EngineWx = (() => {\n${filler}\n  return { ok: true };\n})();\n`;
}

test("[wx包] 合格产物零问题（判据不能恒红，否则下面每条都是摆设）", () => {
  assert.deepEqual(checkWxBundle(good()), []);
});

test("[wx包] 空壳要报：只打进入口壳时体积会掉到几十 KB", () => {
  // ★ 这条不只验"小要报"，还验"合格的那份真的够大" —— 否则 MIN_BUNDLE_BYTES
  //   被调成 0，good() 依然通过，而这条会因为"小也通过"而变绿：两条一起假绿。
  const tiny = "var EngineWx = (() => ({ ok: true }))();\n";
  assert.ok(Buffer.byteLength(good(), "utf8") >= MIN_BUNDLE_BYTES);
  const issues = checkWxBundle(tiny);
  assert.equal(issues.length, 1, issues.join(" / "));
  assert.ok(issues[0]!.includes("不像一整局游戏"), issues[0]!);
});

test("[wx包] ESM export 要报（真机报 Unexpected token 'export'）", () => {
  const src = good().replace("var EngineWx", "export const X = 1;\nvar EngineWx");
  const issues = checkWxBundle(src);
  assert.equal(issues.length, 1, issues.join(" / "));
  assert.ok(issues[0]!.includes("export"), issues[0]!);
  // ★ 反向：字符串里的 "export" 不算（否则任何提到这个词的日志文案都会红）。
  const quoted = good().replace("return { ok: true };", 'return { msg: "export 关键字在这只是文案" };');
  assert.deepEqual(checkWxBundle(quoted), []);
});

test("[wx包] `import.meta` 要报；而名为 `import` 的**方法**不许误报", () => {
  // ★ 后半句是这条判据的重点：第一版扫的是 `import(`，真实产物里当场命中 4 处
  //   `async import(sourcePath, source) {` —— 那是本仓库导入管线的接口方法，
  //   与 ESM 动态导入在字节层长得一模一样。假红会让人把闸门关掉，所以这里把
  //   "方法必须放过"写成判据，而不是留在注释里靠人记。
  const meta = good().replace("return { ok: true };", "return { u: import.meta.url };");
  const issues = checkWxBundle(meta);
  assert.equal(issues.length, 1, issues.join(" / "));
  assert.ok(issues[0]!.includes("import.meta"), issues[0]!);

  const method = good().replace(
    "return { ok: true };",
    'return { async import(p) { return p; }, via: (u) => u.importer.import("a") };',
  );
  assert.deepEqual(checkWxBundle(method), []);
});

test("[wx包] node 内置依赖要报（真机上没有这些模块）", () => {
  for (const bad of ['require("node:fs")', 'from "node:path"']) {
    const src = good().replace("return { ok: true };", `return { x: ${bad} };`);
    const issues = checkWxBundle(src);
    assert.equal(issues.length, 1, `${bad} → ${issues.join(" / ")}`);
    assert.ok(issues[0]!.includes("node 内置"), issues[0]!);
  }
  // ★ 反向：`{ node: id }` 这种对象字面量不是 node: 协议。
  const obj = good().replace("return { ok: true };", "return { node: 7 };");
  assert.deepEqual(checkWxBundle(obj), []);
});

test("[wx包] 没有 IIFE 的 globalName 要报（包装没发生，而 export 可能仍然为假）", () => {
  const src = good().replace("var EngineWx = (() => {", "(function () {");
  const issues = checkWxBundle(src);
  assert.equal(issues.length, 1, issues.join(" / "));
  assert.ok(issues[0]!.includes("EngineWx"), issues[0]!);
});
