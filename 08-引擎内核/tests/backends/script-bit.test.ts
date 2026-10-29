/**
 * `bit`（LuaJIT 的 32 位位运算库，批137 / 阻塞项 C27 的最后一项）
 *
 * ★ 为什么值得单独一个文件：这不是"顺手补个库"。5.4 的 `& | ~ << >>` 是 **64 位**、
 *   `>>` 是**逻辑**移位，而 `bit.*` 一律 32 位、返回**有符号** 32 位。两者混起来
 *   得到的是"能跑、数值全错"—— 内容层不会报错，只会算错。所以判据必须钉住
 *   **符号**（`band(-1, 0xFF)`）、**逻辑 vs 算术右移**（`rshift(-1,1)` 与
 *   `arshift(-8,1)`）、**位移量掩码**（`lshift(1,32)`）这三处最容易"看起来对"的地方。
 *
 * ★ 正确性的对照物是 **Lua 5.4 自己的原生位运算**：`band(a,b)` 必须等于
 *   `tobit(a & b)`。只拿自己跟自己对（"算两遍得到同一个数"）不算验证。
 *
 * ★ 为什么这些判据能在 CI 里跑：`bit` 是引擎装的，不依赖 `dstsrc` 语料
 *   （那 55 处 `bit.band` 在未入库的素材里，挂在它上面等于永远跳过）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { LuaScriptRuntime } from "../../src/backends/script-lua/runtime.ts";

async function withLua(body: (rt: LuaScriptRuntime) => Promise<void>): Promise<void> {
  const rt = new LuaScriptRuntime();
  try {
    const ready = await rt.ready();
    assert.ok(ready.ok, `ready() 必须成功：${ready.ok ? "" : ready.error.message}`);
    await body(rt);
  } finally {
    rt.dispose();
  }
}

/** 在 Lua 侧算一组表达式，用逗号拼回来（比逐条跨界取值的断言更好读）。 */

test("★ `bit` 装上了，13 个函数都在（自检也查它，静默装失败的报错点会离根因很远）", async () => {
  await withLua(async (rt) => {
    const names = [
      "band", "bor", "bxor", "bnot", "lshift", "rshift", "arshift",
      "rol", "ror", "bswap", "tobit", "tohex",
    ];
    const m = await rt.loadModule(
      "probe",
      [
        "local out = { type(bit) }",
        ...names.map((n) => `out[#out + 1] = type(bit.${n})`),
        "function __engine_probe_value() return table.concat(out, ',') end",
      ].join("\n"),
    );
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const r = await rt.call("__engine_probe_value");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    assert.equal(String(r.value), ["table", ...names.map(() => "function")].join(","));
  });
});

test("★ 基本运算：band / bor / bxor / bnot / 多参数（内容层就是这样用的）", async () => {
  await withLua(async (rt) => {
    const m = await rt.loadModule(
      "ops",
      [
        "out = {}",
        "out[#out+1] = bit.band(0xFF, 0x0F)",
        "out[#out+1] = bit.bor(1, 2, 4)",
        "out[#out+1] = bit.bxor(0xFF, 0x0F)",
        "out[#out+1] = bit.bnot(0)",
        "out[#out+1] = bit.band(0xF0F0, 0x0FF0)",
        "function dump() return table.concat(out, ',') end",
      ].join("\n"),
    );
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const r = await rt.call("dump");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    assert.equal(String(r.value), "15,7,240,-1,240");
  });
});

test("★★ 符号：32 位**补码**，不是 64 位无符号（混着用是「能跑但算错」）", async () => {
  await withLua(async (rt) => {
    const m = await rt.loadModule(
      "sgn",
      [
        "out = {}",
        "out[#out+1] = bit.tobit(0xFFFFFFFF)",   // -1，不是 4294967295
        "out[#out+1] = bit.band(-1, 0xFF)",      // 高位全 1 ⇒ 仍是 255
        "out[#out+1] = bit.bor(-2147483648, 1)", // 符号位参与运算
        "out[#out+1] = bit.bnot(0)",             // -1
        "out[#out+1] = bit.tobit(2147483648)",   // 溢出到负数
        "function dump() return table.concat(out, ',') end",
      ].join("\n"),
    );
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const r = await rt.call("dump");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    assert.equal(String(r.value), "-1,255,-2147483647,-1,-2147483648");
  });
});

test("★★ 逻辑右移 vs 算术右移：`rshift(-1,1)` = 2147483647，`arshift(-8,1)` = -4", async () => {
  await withLua(async (rt) => {
    const m = await rt.loadModule(
      "shift",
      [
        "out = {}",
        "out[#out+1] = bit.rshift(-1, 1)",   // 逻辑：高位补 0
        "out[#out+1] = bit.arshift(-8, 1)",  // 算术：高位补 1 ⇒ -4
        "out[#out+1] = bit.arshift(-1, 1)",  // -1 永远是 -1
        "out[#out+1] = bit.lshift(1, 31)",   // 落到符号位
        "out[#out+1] = bit.lshift(1, 32)",   // 位移量按 &31 掩码 ⇒ 等于不移
        "out[#out+1] = bit.rshift(1, 32)",   // 同上
        "function dump() return table.concat(out, ',') end",
      ].join("\n"),
    );
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const r = await rt.call("dump");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    assert.equal(String(r.value), "2147483647,-4,-1,-2147483648,1,1");
  });
});

test("★★ 与 Lua 5.4 原生位运算交叉验证（自己跟自己对不算验证）", async () => {
  await withLua(async (rt) => {
    const m = await rt.loadModule(
      "cross",
      [
        "local cases = {",
        "  {0, 0}, {1, 1}, {0xFF, 0x0F}, {-1, 255}, {123456789, 987654321},",
        "  {-2147483648, 1}, {2147483647, -1},",
        "}",
        // 对照物：5.4 原生运算 + 同一套 tobit 规范。如果 ours 与 native 分叉，
        // 说明其中一边的符号/位宽处理错了 —— 而两边都是我们自己写的，所以这只能
        // 证明「两条路径一致」；真正的外部对照在下面那条断言里（具体数值）。
        "local bad = {}",
        "for i = 1, #cases do",
        "  local a, b = cases[i][1], cases[i][2]",
        "  if bit.band(a, b) ~= bit.tobit(a & b) then bad[#bad+1] = 'band ' .. i end",
        "  if bit.bor(a, b) ~= bit.tobit(a | b) then bad[#bad+1] = 'bor ' .. i end",
        "  if bit.bxor(a, b) ~= bit.tobit(a ~ b) then bad[#bad+1] = 'bxor ' .. i end",
        "  if bit.rshift(a, 3) ~= bit.tobit((a & 0xFFFFFFFF) >> 3) then bad[#bad+1] = 'rshift ' .. i end",
        "end",
        "function dump() if #bad == 0 then return 'ok' end return table.concat(bad, ',') end",
      ].join("\n"),
    );
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const r = await rt.call("dump");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    assert.equal(String(r.value), "ok");
  });
});

test("★ tohex：默认 8 位小写；`|n|` 取**低**位；`n<0` 大写", async () => {
  await withLua(async (rt) => {
    const m = await rt.loadModule(
      "hex",
      [
        "out = {}",
        "out[#out+1] = bit.tohex(0x12345678)",
        "out[#out+1] = bit.tohex(0x12345678, 4)",
        "out[#out+1] = bit.tohex(-1, 4)",
        "out[#out+1] = bit.tohex(0xABCDEF, -6)",
        "function dump() return table.concat(out, ',') end",
      ].join("\n"),
    );
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const r = await rt.call("dump");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    assert.equal(String(r.value), "12345678,5678,ffff,ABCDEF");
  });
});

test("★ 内容层的真实形状：用 bit 拼位掩码（`code + (bit.band(flag, 1) * 2^k)`）", async () => {
  await withLua(async (rt) => {
    const m = await rt.loadModule(
      "mask",
      [
        // 与 playercontroller 同形状：逐位检出 + 左移累加
        "local flags = { true, false, true, true, false, false, true, false }",
        "local code = 0",
        "for i = 1, #flags do",
        "  local bitval = flags[i] and bit.lshift(1, i - 1) or 0",
        "  code = bit.bor(code, bitval)",
        "end",
        "out = { code }",
        "local back = {}",
        "for i = 1, #flags do",
        "  back[i] = (bit.band(code, bit.lshift(1, i - 1)) ~= 0) and '1' or '0'",
        "end",
        "function dump() return tostring(out[1]) .. '|' .. table.concat(back) end",
      ].join("\n"),
    );
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const r = await rt.call("dump");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    // 位 0/2/3/6 置位 ⇒ 1+4+8+64 = 77；再逐位解回来必须一模一样
    assert.equal(String(r.value), "77|10110010");
  });
});

test("★★ 隔离模式下也能看见 `bit`（垫片装在 `_G`，每个模块 env 靠 __index 链过去）", async () => {
  // 这条不是多余的：`sharedModuleEnv` 与「每模块独立 env」是两种模块观（批133），
  // `bit` 装错层的话，真实 DST 内容层在默认模式下会"别的都对、只有用到 bit 的文件炸"。
  await withLua(async (rt) => {
    const m = await rt.loadModule("iso", "return bit.band(0xF0, 0x3C)");
    assert.ok(m.ok, m.ok ? "" : m.error.message);
    const probe = await rt.loadModule(
      "iso2",
      "function dump() return type(bit) .. ',' .. tostring(bit.bor(1, 2)) end",
    );
    assert.ok(probe.ok, probe.ok ? "" : probe.error.message);
    const r = await rt.call("dump");
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    assert.equal(String(r.value), "table,3");
  });
});
