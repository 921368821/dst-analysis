/**
 * L2 · 序列化测试
 *
 * "确定性"在这里必须能**逐字节断言** —— 否则"存档可复现"只是一句愿望。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Schema, stableHash } from "../../src/core/serialization/schema.ts";

test("编码顺序由 schema 决定，与对象插入顺序无关", () => {
  const a = new Schema({ version: 1, fields: ["name", "hp"] });
  const b = new Schema({ version: 1, fields: ["name", "hp"] });
  const x = a.encode({ hp: 3, name: "abc" }).text;
  const y = b.encode({ name: "abc", hp: 3 }).text;
  assert.equal(x, y, "同一 schema 下，两个键顺序不同的对象必须编码成同一串");
  assert.equal(x, '{"__v":1,"name":"abc","hp":3}');
});

test("浮点按 decimals 量化（0.1+0.2 不许泄漏成 0.30000000000000004）", () => {
  const s = new Schema({ version: 1, fields: ["v"] });
  const text = s.encode({ v: 0.1 + 0.2 }).text;
  assert.equal(text, '{"__v":1,"v":0.3}');
});

test("未定义字段不输出（与'存在但为 null'区分得开）", () => {
  const s = new Schema({ version: 1, fields: ["a", "b"] });
  assert.equal(s.encode({ a: 1 }).text, '{"__v":1,"a":1}');
  assert.equal(s.encode({ a: 1, b: null }).text, '{"__v":1,"a":1,"b":null}');
});

test("schema 里没有的键被丢弃并报告（不静默保留脏数据）", () => {
  const s = new Schema({ version: 1, fields: ["a"] });
  const r = s.encode({ a: 1, typo: 2 });
  assert.deepEqual(r.dropped, ["typo"]);
  assert.equal(r.text, '{"__v":1,"a":1}');
});

test("NaN / Infinity 写成字符串标记（JSON 里没有它们的表示，不能变 null）", () => {
  const s = new Schema({ version: 1, fields: ["v"] });
  const text = s.encode({ v: Number.NaN }).text;
  assert.match(text, /"__num__:NaN"/, "NaN 必须能与其他值区分：" + text);
});

test("迁移链：v1 → v2 自动补默认值", () => {
  const s = new Schema({
    version: 2,
    fields: ["name", "hp"],
    migrations: [
      {
        from: 1,
        migrate: (d) => ({ ...d, hp: 100 }), // v1 没有 hp，补默认
      },
    ],
  });
  const r = s.decode('{"__v":1,"name":"old"}');
  assert.ok(r.ok);
  if (r.ok) {
    assert.equal(r.value["hp"], 100);
    assert.equal(r.value["__v"], 2);
  }
});

test("迁移链必须连续：跳号在**构造时**就抛（而不是读旧档时才发现）", () => {
  assert.throws(
    () =>
      new Schema({
        version: 3,
        fields: ["a"],
        migrations: [{ from: 2, migrate: (d) => d }], // 缺 v1→v2
      }),
    /连续覆盖/,
  );
});

test("版本过新：明确拒绝并说明（旧引擎不能读新档）", () => {
  const s = new Schema({ version: 1, fields: ["a"] });
  const r = s.decode('{"__v":9,"a":1}');
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "SER.VERSION_TOO_NEW");
});

test("坏 JSON 给出可读错误，不抛", () => {
  const s = new Schema({ version: 1, fields: ["a"] });
  const r = s.decode("{oops");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "SER.BAD_JSON");
});

test("往返：encode → decode → encode 得到同一串（这是'存档可复现'的最小形式）", () => {
  const s = new Schema({ version: 1, fields: ["name", "x", "z", "hp"] });
  const obj = { name: "树", x: 1.23456, z: -2.5, hp: 15 };
  const t1 = s.encode(obj).text;
  const back = s.decode(t1);
  assert.ok(back.ok);
  if (!back.ok) return;
  const t2 = s.encode(back.value).text;
  assert.equal(t1, t2, `二次编码必须逐字节相同：\n  1: ${t1}\n  2: ${t2}`);
});

test("stableHash 对同内容稳定、对单字节差异敏感", () => {
  const a = stableHash("hello");
  const b = stableHash("hello");
  const c = stableHash("hellp");
  assert.equal(a, b);
  assert.notEqual(a, c);
});
