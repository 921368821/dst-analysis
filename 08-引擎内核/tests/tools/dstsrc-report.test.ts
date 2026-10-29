/**
 * `dstsrc` 失败归类（批135）：把"还有 54 条"拆成"缺的到底是什么"。
 *
 * ★ 为什么这是判据而不是一段打印：`dstsrc` **未入库**，CI 里没有语料 ⇒
 *   只跑真实数据的检查在 CI 里永远是"跳过"，而跳过与通过长得一模一样。
 *   所以归类逻辑抽成纯函数，用**合成语料**逐条打；另有一条**用真实运行时产出**
 *   的报错喂进去，防"合成语料与真实格式悄悄漂移"。
 *
 * ★ 最要紧的一条不是"能分组"，是 `script-local-nil` 必须单独一类：
 *   把 `(local 'v')` 也算进"缺全局"，会得出"引擎该提供 `v`"这种荒唐结论
 *   （`v` 是某个函数返回值）。分类错一次，后面所有决定都建在错的前提上。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ORDER_PRESETS,
  classifyFailure,
  innerMessage,
  orderScripts,
  splitNeverDefined,
  summarizeFailures,
} from "../../tools/dstsrc-report.mjs";
import { LuaScriptRuntime } from "../../src/backends/script-lua/runtime.ts";
import { resolverFromSources } from "../../src/backends/script-lua/module-resolver.ts";

test("★ innerMessage：取最内层那句，剥掉「文件:行号:」", () => {
  assert.equal(
    innerMessage("模块 a 加载失败：a:12: attempt to index a nil value (global 'TheItems')"),
    "attempt to index a nil value (global 'TheItems')",
  );
  assert.equal(
    innerMessage(
      "模块 actions 加载失败：actions:242: module 'debugtools' 加载失败（源：debugtools.lua）：debugtools:210: attempt to call a nil value (global 'global')",
    ),
    "attempt to call a nil value (global 'global')",
    "三层嵌套也要剥到最里面",
  );
  assert.equal(innerMessage(""), "");
});

test("★★ 缺全局：当表用 / 当值用 分开（决定要不要提供它，这两类处理不同）", () => {
  assert.deepEqual(classifyFailure("x:1: attempt to index a nil value (global 'TheItems')"), {
    shape: "missing-global-table",
    name: "TheItems",
  });
  assert.deepEqual(classifyFailure("x:1: attempt to call a nil value (global 'IsConsole')"), {
    shape: "missing-global-value",
    name: "IsConsole",
  });
  assert.deepEqual(classifyFailure("x:1: attempt to concatenate a nil value (global 'POT_GENERATION')"), {
    shape: "missing-global-value",
    name: "POT_GENERATION",
  });
});

test("★★ `(local 'v')` 不算缺全局 —— 那是脚本自己的逻辑问题（分类错一次，后面全错）", () => {
  const got = classifyFailure("x:284: attempt to index a nil value (local 's')");
  assert.deepEqual(got, { shape: "script-local-nil", name: "s" });
  const sum = summarizeFailures([["createstringspo.lua", "x:284: attempt to index a nil value (local 's')"]]);
  assert.equal(sum.missingGlobals.length, 0, "局部变量不许进缺全局清单");
  assert.equal(sum.localNils.length, 1);
});

test("★★ strict.lua 的 `variable 'X' is not declared` 算缺全局（同一件事的另一种说法）", () => {
  const got = classifyFailure("util:1574: variable 'IsConsole' is not declared");
  assert.deepEqual(got, { shape: "missing-global-strict", name: "IsConsole" });
  const sum = summarizeFailures([["util.lua", "util:1574: variable 'IsConsole' is not declared"]]);
  assert.equal(sum.missingGlobals.length, 1);
  assert.deepEqual(sum.missingGlobals[0]?.how, ["strict"]);
});

test("★ 找不到模块单独一类（那不是「缺全局」，是文件就不在语料里）", () => {
  const got = classifyFailure(
    "module 'dbui_no_package/debug_skins_data' not found（没有 dbui_no_package/debug_skins_data.lua 也没有 dbui_no_package/debug_skins_data/init.lua）",
  );
  assert.deepEqual(got, { shape: "missing-module", name: "dbui_no_package/debug_skins_data" });
  const sum = summarizeFailures([["simutil.lua", "x:1: module 'a/b' not found"]]);
  assert.equal(sum.missingModules.length, 1);
  assert.equal(sum.missingGlobals.length, 0);
});

test("★ 其余归 other 并留原文（不许静默丢掉认不出的失败）", () => {
  const sum = summarizeFailures([["noisetilefunctions.lua", "x:124: table index is nil"]]);
  assert.equal(sum.groups.length, 1);
  assert.deepEqual(sum.groups[0], { shape: "other", count: 1 });
  assert.equal(sum.others[0]?.text, "table index is nil", "原文要留着，否则这种失败永远不会被处理");
});

test("★ 汇总：按次数降序 + 同次数按名字（输出必须稳定，否则没人看 diff）", () => {
  // ★ 语料必须让「按次数」与「按名字」给出**不同**的答案，否则这条判据分辨力为零：
  //   value 3 条、table 2 条 ⇒ 按次数是 value 在前，按名字是 table 在前（t < v）。
  //   第一版语料是 2 : 2（打平），于是「不按次数排」的变异（M848）照样绿 —— 假绿。
  const sum = summarizeFailures([
    ["a.lua", "a:1: attempt to index a nil value (global 'TheItems')"],
    ["b.lua", "b:1: attempt to index a nil value (global 'TheItems')"],
    ["c.lua", "c:1: attempt to call a nil value (global 'Zed')"],
    ["d.lua", "d:1: attempt to call a nil value (global 'Zed')"],
    ["e.lua", "e:1: attempt to call a nil value (global 'Alpha')"],
  ]);
  assert.equal(sum.total, 5);
  assert.deepEqual(
    sum.groups.map((g) => [g.shape, g.count]),
    [["missing-global-value", 3], ["missing-global-table", 2]],
    "按次数降序：value 3 条必须排在 table 2 条前面（按名字排会得到相反的顺序）",
  );
  assert.deepEqual(sum.missingGlobals.map((g) => [g.name, g.count]), [
    ["TheItems", 2],
    ["Zed", 2],
    ["Alpha", 1],
  ], "次数降序；同次数按名字升序（TheItems < Zed）");
});

test("★ 同一个全局既能当表又能当函数：`how` 两个都记（别只记第一次）", () => {
  const sum = summarizeFailures([
    ["a.lua", "a:1: attempt to index a nil value (global 'X')"],
    ["b.lua", "b:1: attempt to call a nil value (global 'X')"],
  ]);
  assert.equal(sum.missingGlobals.length, 1);
  assert.deepEqual([...(sum.missingGlobals[0]?.how ?? [])].sort(), ["值", "表"]);
  assert.equal(sum.missingGlobals[0]?.count, 2);
});

test("★ 空输入 ⇒ total 0（调用方要能分辨「没失败」；不许假装扫过）", () => {
  const sum = summarizeFailures([]);
  assert.equal(sum.total, 0);
  assert.deepEqual(sum.groups, []);
  assert.deepEqual(sum.missingGlobals, []);
});

// ── 加载顺序（批136）：顺序是**测量口径**的一部分 ─────────────────────────────
//
// 为什么"顺序"要单独判：`IsConsole` / `global` / `Vector3` 是 `main.lua` /
// `strict.lua` / `vector3.lua` **自己定义的**。纯字母序把 `debugkeys.lua` 排在
// `main.lua` 前面 ⇒ 它们"看起来"是引擎缺口，"缺什么"就被数错了。
// 这不是"跑法不同"，这是**结论不同**。

test("★ orderScripts alpha：排成字母序，但**不许原地改入参**", () => {
  // alpha 是**基线口径**（批133/134 的 117→164 都是它量的）。它一旦变成非空，
  // 新数字就再也无法与旧数字比较 —— 所以这条钉住"alpha 就是纯字母序"。
  assert.deepEqual(ORDER_PRESETS["alpha"], []);
  const input = ["b.lua", "a.lua"];
  const out = orderScripts(input, "alpha");
  assert.deepEqual(out, ["a.lua", "b.lua"]);
  // 调用方可能还要拿原顺序做别的事（例如按文件顺序打印明细）
  assert.deepEqual(input, ["b.lua", "a.lua"], "入参被原地排序 = 偷偷改了调用方的数据");
});

test("★★ orderScripts boot-first：引导文件按**声明顺序**排前面，不是字母序", () => {
  const input = [
    "vector3.lua", "debugkeys.lua", "strict.lua", "util.lua",
    "main.lua", "class.lua", "constants.lua", "aa.lua",
  ];
  assert.deepEqual(
    orderScripts(input, "boot-first"),
    [
      // 声明顺序（main 先于 strict 先于 class…）。按字母序排会变成
      // class / constants / main / strict / util / vector3 —— 必须能分辨出这两者。
      "main.lua", "strict.lua", "class.lua", "util.lua", "vector3.lua", "constants.lua",
      "aa.lua", "debugkeys.lua",
    ],
  );
});

test("★ orderScripts：语料里没有的引导文件**不许凭空出现**（缺 main.lua 就少一个元素）", () => {
  const out = orderScripts(["z.lua", "a.lua", "strict.lua"], "boot-first");
  assert.deepEqual(out, ["strict.lua", "a.lua", "z.lua"], "只提前语料里真有的那些");
  assert.equal(out.length, 3, "长度必须等于入参，否则后面按名字读文件会读空");
});

test("★ orderScripts strict-first：只提 strict.lua，其余仍按字母序（与 alpha 可比）", () => {
  assert.deepEqual(orderScripts(["b.lua", "strict.lua", "a.lua"], "strict-first"), [
    "strict.lua", "a.lua", "b.lua",
  ]);
});

test("★★ 未知预设必须**抛错**：静默回退到 alpha 会让「以为在跑严格口径」永远发现不了", () => {
  assert.throws(() => orderScripts(["a.lua"], "no-such"), /未知的加载顺序预设：no-such/);
  // 顺带钉住可选值：报错里要把可选预设列出来，否则看到错也不知道该填什么
  assert.throws(() => orderScripts(["a.lua"], "no-such"), /alpha \/ strict-first \/ boot-first/);
});

// ── 跨口径求交（批136）：把「缺」劈成「引擎欠的」与「还没轮到」 ─────────────────
//
// 为什么光看报错不够：`WORLD_TILES` 在三档里都被报缺，但它其实由 `constants.lua:1201`
// 定义 —— 原因是 `constants.lua` 在自己跑到 1201 行之前就 `require` 了 `custompresets`。
// 只看报错，"引擎欠的"与"还没轮到"长得一模一样。判据是**跑完再问一次 `_G`**。

test("★★ 跑完仍是 nil ⇒ never（三档都 nil 才算，一档出现就划到 later）", () => {
  const got = splitNeverDefined(
    ["TheNet", "WORLD_TILES"],
    [
      { TheNet: "nil", WORLD_TILES: "nil" },
      { TheNet: "nil", WORLD_TILES: "table" }, // 只要有一档跑完出现了，就不是缺口
      { TheNet: "nil", WORLD_TILES: "table" },
    ],
  );
  assert.deepEqual(got.never, ["TheNet"]);
  assert.deepEqual(got.later, ["WORLD_TILES"]);
});

test("★★ 没探测到的名字进 later —— 「没证据」不许报成「引擎欠的」", () => {
  // 把"没证据"说成"引擎欠的"，会让人去做一堆没人需要的假对象。
  assert.deepEqual(splitNeverDefined(["X"], [{}]), { never: [], later: ["X"] });
  assert.deepEqual(splitNeverDefined(["X"], []), { never: [], later: ["X"] }, "一份探测都没有时不主张缺口");
});

test("★ 三档全 nil 才算 never：少一档不行（两档 nil + 一档缺失也不许当 never）", () => {
  assert.deepEqual(splitNeverDefined(["A"], [{ A: "nil" }, { A: "nil" }]), {
    never: ["A"],
    later: [],
  });
  assert.deepEqual(splitNeverDefined(["A"], [{ A: "nil" }, {}]), { never: [], later: ["A"] });
});

test("★ 空输入 ⇒ 两半都空；返回新数组，不改入参", () => {
  const names = ["A"];
  const probes = [{ A: "nil" }];
  assert.deepEqual(splitNeverDefined([], probes), { never: [], later: [] });
  const got = splitNeverDefined(names, probes);
  assert.deepEqual(names, ["A"], "入参不许被改");
  assert.notEqual(got.never, names, "不许把入参数组直接当结果交出去");
});

test("★★ 用**真实运行时**产出的报错喂进去：合成语料与真实格式不许漂移", async () => {
  const rt = new LuaScriptRuntime({ resolveModule: resolverFromSources(new Map()) });
  try {
    const ready = await rt.ready();
    assert.ok(ready.ok, ready.ok ? "" : ready.error.message);

    // ① 缺模块：真的走 require → 宿主解析器 → 找不到
    const miss = await rt.loadModule("m1", 'require("nosuch/thing")');
    assert.equal(miss.ok, false);
    const sumMiss = summarizeFailures([["m1.lua", miss.ok ? "" : miss.error.message]]);
    assert.deepEqual(sumMiss.groups, [{ shape: "missing-module", count: 1 }]);
    assert.equal(sumMiss.missingModules[0]?.name, "nosuch/thing");

    // ② 缺全局：模块体里把一个不存在的全局当表用
    const glob = await rt.loadModule("m2", "return TheItems.prefab");
    assert.equal(glob.ok, false);
    const sumGlob = summarizeFailures([["m2.lua", glob.ok ? "" : glob.error.message]]);
    assert.deepEqual(sumGlob.groups, [{ shape: "missing-global-table", count: 1 }]);
    assert.equal(sumGlob.missingGlobals[0]?.name, "TheItems");
  } finally {
    rt.dispose();
  }
});
