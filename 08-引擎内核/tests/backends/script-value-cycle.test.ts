/**
 * 脚本边界值的**自引用诊断**（批130）。
 *
 * ★ 这一批的起点是一次真实测量，不是设想：
 *   把 `dstsrc/scripts/class.lua`（363 行 DST 原始脚本）喂给 `LuaScriptRuntime`，
 *   `loadModule` **成功**（5.1 垫片够用），但 `Class()` 一返回就报
 *
 *     返回值.__index.__index.…（连续 32 次）: 嵌套超过 32 层（八成是成环的表）
 *
 *   那不是"太深"，是 `c.__index = c` —— DST 每一个类都这么写，所以**任何**返回
 *   类/实例的脚本 API 都会踩。而报错文案把人指向"数据太大"，真正的原因（自引用）
 *   一个字都没说。修完之后同一句调用报的是：
 *
 *     返回值.__index: 自引用（同一个表在它自己的路径上又出现了一次）—— DST 的类都写
 *     `c.__index = c`，所以别把类/实例当返回值，只返回数据字段
 *
 * ★ 为什么判据用自造语料而不是 `class.lua`：`dstsrc/` **没有入库**
 *   （`git ls-files dstsrc` 是 0 个文件），CI 上根本没有那个目录。判据挂在一个
 *   不在仓库里的文件上，等于在 CI 上永远跳过 —— 那比没有判据更糟（看着是绿的）。
 *   所以语料写成 10 行的等价形态（`c.__index = c`），真实跑过的结论写进文档。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { LuaScriptRuntime } from "../../src/backends/script-lua/runtime.ts";
import { assertScriptValue } from "../../src/platform/script/runtime.ts";

async function withLua(body: (rt: LuaScriptRuntime) => Promise<void>): Promise<void> {
  const rt = new LuaScriptRuntime();
  try {
    const ready = await rt.ready();
    assert.ok(ready.ok, "ready() 必须成功");
    await body(rt);
  } finally {
    rt.dispose();
  }
}

/** 失败结果的 message（调用方保证失败）。 */
function messageOf(r: { ok: boolean; error?: { message: string } }): string {
  return r.ok ? "" : (r.error?.message ?? "");
}

test("[脚本值] Lua 返回 `c.__index = c` 这种自引用表 ⇒ 报「自引用」且路径点名 __index", async () => {
  await withLua(async (rt) => {
    const loaded = await rt.loadModule(
      "cls",
      `function selfRef()
         local c = {}
         c.__index = c
         return c
       end`,
    );
    assert.ok(loaded.ok, "加载语料失败");

    const r = await rt.call("selfRef");
    assert.equal(r.ok, false, "自引用的表不该被当成普通数据转换成功");
    const msg = messageOf(r);
    // 三个观测量一起读：说清了"是自引用"、点名了是哪一环、且**没有**退回深度兜底。
    assert.ok(msg.includes("自引用"), `要报自引用，实际：${msg}`);
    assert.ok(msg.includes("__index"), `路径要指到具体那一环，实际：${msg}`);
    assert.ok(!msg.includes("嵌套超过 32 层"), `不许退回深度兜底（那是症状不是原因）：${msg}`);
  });
});

test("[脚本值] 自引用**数组**也报自引用（数组分支不能漏判）", async () => {
  // ★ 这条防的是"只在对象分支加环检测"：`t[1] = t` 会先被 `looksLikeSequence`
  //   认成序列，走进数组分支 —— 判环若写在对象分支里面就永远碰不到。
  await withLua(async (rt) => {
    const loaded = await rt.loadModule(
      "arr",
      `function selfArr()
         local t = {}
         t[1] = t
         return t
       end`,
    );
    assert.ok(loaded.ok);
    const r = await rt.call("selfArr");
    assert.equal(r.ok, false);
    const msg = messageOf(r);
    assert.ok(msg.includes("自引用"), `实际：${msg}`);
  });
});

test("[脚本值] 共享引用（同一张表挂在两个键下）必须**通过** —— 环检测不能误杀 DAG", async () => {
  // ★ 这是"路径栈 vs 全局 visited"的分水岭 —— 但**只在参数侧成立**。
  //   `{a = t, b = t}` 是合法的（Lua 里到处是这种结构：组件表互相引用），
  //   用全局"见过的对象"集判会把 b 那一支拒掉 —— 而那是一条**误报**。
  //
  //   ★★ 实测记一笔（批130）：wasmoon 把 Lua 表转成 JS 时**会深拷贝**，
  //   `{a = t, b = t}` 到这里已经是两个不同的对象 ⇒ 把实现改成"全局 visited"
  //   这条判据**仍然是绿的**（试过）。所以它守的是"共享引用不许被误杀"这个**行为**，
  //   验不到"路径栈这个实现"。后者只有下面那条参数侧判据能验（JS 对象同一性确定）。
  //   判据的适用域要写清楚，否则下一个人会以为这条能兜住那条变异。
  await withLua(async (rt) => {
    const loaded = await rt.loadModule(
      "dag",
      `function shared()
         local t = { x = 1 }
         return { a = t, b = t }
       end`,
    );
    assert.ok(loaded.ok);
    const r = await rt.call("shared");
    assert.ok(r.ok, `共享引用必须通过，实际：${messageOf(r)}`);
    assert.deepEqual(r.value, { a: { x: 1 }, b: { x: 1 } });
  });
});

test("[脚本值] 真的嵌套太深 ⇒ 报深度问题，且明说「不是环」", async () => {
  // 两种失败必须能分开：一个是"作者的写法有问题"（自引用），
  // 一个是"数据本身太大"（40 层）。文案含「不是环」是把这条路标钉住。
  await withLua(async (rt) => {
    const loaded = await rt.loadModule(
      "deep",
      `function deep()
         local root = {}
         local cur = root
         for i = 1, 40 do
           cur.next = {}
           cur = cur.next
         end
         return root
       end`,
    );
    assert.ok(loaded.ok);
    const r = await rt.call("deep");
    assert.equal(r.ok, false);
    const msg = messageOf(r);
    assert.ok(msg.includes("嵌套超过 32 层"), `实际：${msg}`);
    assert.ok(msg.includes("不是环"), `要说明这不是环，实际：${msg}`);
  });
});

test("[脚本值] 参数侧（JS → Lua）同一套判定：自引用报错、共享引用通过", async () => {
  // 两侧各有一份同形状实现（`assertScriptValue` 与 `toScriptValue`）。
  // 只修一侧的症状是"返回值能过、传参炸"（或反过来），所以两边都要判据。
  const cyc: Record<string, unknown> = { name: "x" };
  cyc["self"] = cyc;
  const bad = assertScriptValue(cyc, "参数");
  assert.equal(bad.ok, false, "自引用的参数对象必须被挡住");
  const msg = messageOf(bad);
  assert.ok(msg.includes("自引用"), `实际：${msg}`);

  // ★ 同一条判据里的反向：共享引用（JS 里是**同一个对象**，比 Lua 侧更硬）
  const shared = { x: 1 };
  const good = assertScriptValue({ a: shared, b: shared }, "参数");
  assert.ok(good.ok, `共享引用必须通过，实际：${messageOf(good)}`);
  assert.deepEqual(good.value, { a: { x: 1 }, b: { x: 1 } });
});
