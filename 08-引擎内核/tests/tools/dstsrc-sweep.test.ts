/**
 * 测量仪器本身（批138）：`tools/dstsrc-run.ts` —— 「按某种口径把一份 Lua 语料全量加载一遍」。
 *
 * ★ 为什么要给仪器写判据：批136/137 的结论（「哪 18 个名字是顺序造成的假缺口」
 *   「`bit` 一给就 164 → 165」）全部由这段逻辑产出，而它原来只跑在 `dstsrc` 上 ——
 *   那份素材**未入库**，CI 里永远只有"跳过"，而跳过与通过长得一模一样。
 *   仪器坏了（顺序没应用、探针装错、解析器忘传），报告依旧全绿，清单悄悄变样。
 *
 * ★ 语料是**合成的**，但每一条都对应真实语料里的一种形状：
 *   · `zz_late_def.lua` 在 `a_uses_late.lua` **之后**才定义它要用的全局
 *     —— 真语料里是 `constants.lua` 跑到 1201 行才 `WORLD_TILES = {`，
 *     而它在 1200 行前就 `require` 了 `custompresets`（嵌套加载）；
 *   · `main.lua` 先定义 `IsConsole` 再死在 `TheSim` 上
 *     —— 真语料里 `main.lua` 在 16 行定义、95 行死；
 *   · `strict.lua` 给 `_G` 挂 `__index` —— 真语料里 `strict.lua` 就这么干。
 *   这几条合起来能复现批136 的核心发现：**换顺序，"缺什么"的清单会变**。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { runSweepPass } from "../../tools/dstsrc-run.ts";
import { splitNeverDefined } from "../../tools/dstsrc-report.mjs";

/** 造一份迷你语料。文件名故意让**字母序**把"用的"排在"定义的"前面。 */
async function corpus(): Promise<MemoryFileSystem> {
  const fs = new MemoryFileSystem();
  const files: Record<string, string> = {
    // 用 LateGlobal 的人排在前面（'a' < 'z'）
    "a_uses_late.lua": "return LateGlobal.inner",
    "z_late_def.lua": "LateGlobal = { inner = 1 }",
    // 引导文件：先定义辅助函数，再撞上引擎没提供的世界对象（真语料 main.lua 的形状）
    "main.lua": [
      "function IsConsole() return false end",
      "TheSim:ShouldInitTest()",
    ].join("\n"),
    // 排在 main.lua 前面（'c' < 'm'）—— 字母序下它是"缺全局 IsConsole"
    "c_debugkeys.lua": "if IsConsole() then CHEAT = 1 end",
    // strict.lua：给 _G 挂 __index（读未声明全局 = 报错）
    // ★ 必须照抄真 strict.lua 的那两个 `what ~= "main"` 例外：
    //   chunk **顶层**的赋值是允许的（`what == "main"`），只有函数体里的才算违规。
    //   第一版假件省了这两个例外，结果探针自己都装不上 ——
    //   而这不是"引擎的 bug"，是**夹具比现实更严**造出来的假红。
    "strict.lua": [
      "local mt = getmetatable(_G)",
      "if mt == nil then mt = {} setmetatable(_G, mt) end",
      "mt.__declared = {}",
      "local function top()",
      '  local w = debug.getinfo(3, "S").what',
      '  return w == "main" or w == "C"',
      "end",
      "mt.__newindex = function(t, n, v)",
      '  if not mt.__declared[n] and not top() then error("assign to undeclared variable \'" .. n .. "\'", 2) end',
      "  mt.__declared[n] = true",
      "  rawset(t, n, v)",
      "end",
      "mt.__index = function(t, n)",
      '  if not mt.__declared[n] and debug.getinfo(2, "S").what ~= "C" then error("variable \'" .. n .. "\' is not declared", 2) end',
      "  return rawget(t, n)",
      "end",
      "function global(...) for _, v in ipairs{...} do mt.__declared[v] = true end end",
    ].join("\n"),
    // 谁都没给过它 —— 这一条在三档里都该是 nil
    "zz_items.lua": "return TheItems.prefab",
    // require 的第三站。★ 被 require 的模块**故意不在顶层列表里**（放在子目录）：
    //   第一版把它也列进 `files`，于是它先被宿主 `loadModule` 加载进 `package.loaded`，
    //   `require` 直接命中缓存 —— **没有解析器也能通过**，这条判据就白写了。
    //   真实语料里失败的那 101 条正是这个形状：被 require 的还在后面没轮到。
    "zz_needs_class.lua": 'local c = require("lib/classutil")\nreturn c.name',
    "lib/classutil.lua": 'return { name = "classutil" }',
  };
  for (const [name, text] of Object.entries(files)) {
    const w = await fs.writeText(name, text);
    assert.ok(w.ok, `写不进 ${name}：${w.ok ? "" : w.error.message}`);
  }
  return fs;
}

const FILES = [
  "a_uses_late.lua",
  "c_debugkeys.lua",
  "main.lua",
  "strict.lua",
  // ★ 这一条曾经漏掉：少了"定义方"，`LateGlobal` 就永远是 nil，
  //   于是「跑完出现了」这条判据会**以正确的理由**不成立 —— 而判据本身看不出差别。
  "z_late_def.lua",
  "zz_items.lua",
  "zz_needs_class.lua",
];

function failedNames(fail: ReadonlyArray<readonly [string, string]>): string[] {
  return fail.map(([name]) => name).sort();
}

test("★ 解析器开关真的接线：`require` 在无解析器时失败、有解析器时通过", async () => {
  const fs = await corpus();
  const off = await runSweepPass({ fs, files: FILES, resolve: false });
  assert.ok(off.ok, off.ok ? "" : off.error.message);
  assert.ok(failedNames(off.value.fail).includes("zz_needs_class.lua"), "没有解析器时 require 必须失败");

  const on = await runSweepPass({ fs, files: FILES, resolve: true });
  assert.ok(on.ok, on.ok ? "" : on.error.message);
  assert.equal(
    failedNames(on.value.fail).includes("zz_needs_class.lua"),
    false,
    "装上解析器后 classutil 应能找到",
  );
});

test("★★ 顺序真的被应用：boot-first 把 main.lua 提到最前 ⇒ 缺 IsConsole 那条不再出现", async () => {
  const fs = await corpus();
  // alpha：'c_debugkeys' 排在 'main' 前面 ⇒ IsConsole 还不存在
  const alpha = await runSweepPass({ fs, files: FILES, order: "alpha" });
  assert.ok(alpha.ok, alpha.ok ? "" : alpha.error.message);
  assert.ok(
    failedNames(alpha.value.fail).includes("c_debugkeys.lua"),
    "字母序下 c_debugkeys 必须失败（这就是批136 说的假缺口）",
  );
  // boot-first：main.lua 先跑，它先定义 IsConsole 再死 ⇒ 后面的文件能看见它
  const boot = await runSweepPass({ fs, files: FILES, order: "boot-first" });
  assert.ok(boot.ok, boot.ok ? "" : boot.error.message);
  assert.equal(boot.value.order[0], "main.lua", "boot-first 必须把 main.lua 排在第一个");
  assert.equal(
    failedNames(boot.value.fail).includes("c_debugkeys.lua"),
    false,
    "main.lua 先跑之后 IsConsole 已定义，这条必须变通过 —— 否则顺序只是算出来打印了一下",
  );
});

test("★★ 探针用 `rawget`：strict 档下 `_G[name]` 会自己炸，探针必须还能给出答案", async () => {
  const fs = await corpus();
  const strict = await runSweepPass({ fs, files: FILES, order: "strict-first" });
  assert.ok(strict.ok, strict.ok ? "" : strict.error.message);
  // strict 生效的证据：读未声明全局变成 missing-global-strict 形状
  const joined = strict.value.fail.map(([, m]) => m).join("\n");
  assert.match(joined, /is not declared/, "strict 档应当出现「变量未声明」这类报错");
  // 探针要能回答（`_G[name]` 在 strict 下会 error ⇒ 值会变成「?（调用失败…）」）
  for (const [name, verdict] of strict.value.probed) {
    assert.equal(
      verdict.startsWith("?"),
      false,
      `探针对 ${name} 失败了（${verdict}）—— 说明它走的不是 rawget`,
    );
  }
  assert.ok(strict.value.probed.size > 0, "strict 档应当至少有东西可探");
});

test("★★ 探的是**跑完之后**的 `_G`：晚定义的全局必须报成「后来才有」，不是「引擎欠的」", async () => {
  const fs = await corpus();
  const alpha = await runSweepPass({ fs, files: FILES, order: "alpha" });
  assert.ok(alpha.ok, alpha.ok ? "" : alpha.error.message);
  assert.ok(
    failedNames(alpha.value.fail).includes("a_uses_late.lua"),
    "a_uses_late 在 LateGlobal 定义之前跑，必须失败",
  );
  assert.equal(
    alpha.value.probed.get("LateGlobal"),
    "table",
    "跑完之后 LateGlobal 是存在的 ⇒ 只能报「顺序问题」，不能报「引擎欠的」",
  );
});

test("★★ 端到端：三档求交 + 探针 ⇒ `TheItems` 是缺口、`LateGlobal` 不是", async () => {
  const fs = await corpus();
  const orders = ["alpha", "strict-first", "boot-first"];
  const runs = [];
  for (const order of orders) {
    const r = await runSweepPass({ fs, files: FILES, order });
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    runs.push(r.value);
  }
  // 三档都缺的名字（按名字求交，与 dstsrc-report 的 always 同口径）
  const missingPerOrder = runs.map((r) => new Set(r.probed.keys()));
  const always = [...(missingPerOrder[0] ?? new Set<string>())].filter((n) =>
    missingPerOrder.every((s) => s.has(n)),
  );
  assert.ok(always.includes("TheItems"), "TheItems 三档都缺");
  assert.ok(always.includes("LateGlobal"), "LateGlobal 三档都缺（这就是它需要探针的原因）");

  const split = splitNeverDefined(
    always,
    runs.map((r) => Object.fromEntries(r.probed)),
  );
  assert.ok(split.never.includes("TheItems"), "谁都没给过 TheItems ⇒ never");
  assert.ok(
    split.later.includes("LateGlobal"),
    "LateGlobal 后来被定义了 ⇒ later（做成 API 面就是白做）",
  );
});

test("★ 未知预设返回 Err，不是崩溃（一个笔误不该让整轮变成异常栈）", async () => {
  const fs = await corpus();
  const r = await runSweepPass({ fs, files: FILES, order: "nope" });
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /未知的加载顺序预设/);
});

test("★ 入参 `files` 的顺序不影响结果（顺序只由预设决定，调用方不用先排一遍）", async () => {
  const fs = await corpus();
  const forward = await runSweepPass({ fs, files: FILES, order: "alpha" });
  const backward = await runSweepPass({ fs, files: [...FILES].reverse(), order: "alpha" });
  assert.ok(forward.ok && backward.ok);
  if (forward.ok && backward.ok) {
    assert.deepEqual(forward.value.order, backward.value.order);
    assert.equal(forward.value.ok, backward.value.ok);
  }
});

test("★ `order` 就是实际加载顺序（判据靠它确认预设生效，而不是靠「看起来像」）", async () => {
  const fs = await corpus();
  const r = await runSweepPass({ fs, files: FILES, order: "boot-first" });
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  // boot-first 的声明顺序：main / strict / class / util / vector3 / constants，语料里只有前两个
  assert.deepEqual(r.value.order.slice(0, 2), ["main.lua", "strict.lua"]);
  assert.equal(r.value.order.length, FILES.length, "结果不许凭空多出或漏掉文件");
});
