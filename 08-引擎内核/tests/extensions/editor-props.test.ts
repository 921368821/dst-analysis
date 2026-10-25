/**
 * L4 · 编辑器：属性面板模型
 *
 * ★ 这一层的判据全部围绕「**无损**」两个字：
 *   `Int` 字段收到 `"3.5"` 必须报错，而不是悄悄写成 3；
 *   校验失败必须一个字节都不写（面板是「一边打一边刷」的，顺序反了会留下半改状态）。
 *   这两条各自一条变异 —— 它们都能让"看起来能用"的编辑器写出脏数据。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { hashText } from "../../src/foundation/hash.ts";
import {
  EDIT_BAD_FIELD,
  EDIT_BAD_VALUE,
  coerce,
  controlOf,
  fieldsOf,
  setField,
  valuesEqual,
} from "../../src/extensions/editor/property-model.ts";

/** ★ 字段声明顺序**故意不是字母序**：alpha 在 zeta 后面。 */
class Widget extends Component {
  zeta = "hi";
  alpha = 7;
  flag = false;
  pos = { x: 1, y: 2 };
  tint = { r: 1, g: 1, b: 1, a: 1 };
  ref = "";
  asset = "";
  tags: string[] = ["a"];

  readonly schema: ComponentSchema = {
    type: "test.widget",
    fields: {
      zeta: FieldType.String,
      alpha: FieldType.Int,
      flag: FieldType.Bool,
      pos: FieldType.Vec2,
      tint: FieldType.Color,
      ref: FieldType.NodeRef,
      asset: FieldType.Asset,
      tags: FieldType.StringArray,
    },
  };
}

function makeScene(): { scene: Scene; id: number; comp: Widget } {
  const reg = new ComponentRegistry();
  reg.register(new Widget().schema, () => new Widget());
  const scene = new Scene("editor", reg);
  const n = scene.spawnImmediate("w", scene.root.id, 2);
  const r = scene.attach(n.id, () => new Widget());
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  scene.flush();
  const comp = scene.find(n.id)?.components.find((c) => c.type === "test.widget");
  assert.ok(comp instanceof Widget, "组件必须真的挂上去了");
  return { scene, id: n.id, comp };
}

function codeOf(r: { ok: boolean }): string {
  assert.equal(r.ok, false, "这一步本应失败");
  return (r as unknown as { error: { code: string } }).error.code;
}

test("[编辑器·属性] 字段顺序 = schema 声明顺序（不是字母序）", () => {
  const { comp } = makeScene();
  assert.deepEqual(
    fieldsOf(comp).map((f) => f.key),
    ["zeta", "alpha", "flag", "pos", "tint", "ref", "asset", "tags"],
    "顺序即序列化顺序：面板按字母序出，会让人以为面板与存档是两回事",
  );
});

test("[编辑器·属性] 每种字段类型对应确定的控件", () => {
  assert.equal(controlOf(FieldType.Int), "number");
  assert.equal(controlOf(FieldType.Float), "number");
  assert.equal(controlOf(FieldType.Double), "number");
  assert.equal(controlOf(FieldType.Bool), "checkbox");
  assert.equal(controlOf(FieldType.String), "text");
  assert.equal(controlOf(FieldType.Vec2), "vec2");
  assert.equal(controlOf(FieldType.Color), "color");
  assert.equal(controlOf(FieldType.Asset), "asset");
  assert.equal(controlOf(FieldType.NodeRef), "noderef");
  assert.equal(controlOf(FieldType.StringArray), "tags");
});

test("[编辑器·属性] Int 只收整数：3.5 报错，不静默取整", () => {
  assert.equal(coerce(FieldType.Int, 3).ok, true);
  assert.equal(coerce(FieldType.Int, "3").ok, true, "输入框给的是字符串");
  assert.equal(coerce(FieldType.Int, " 42 ").ok, true, "两端空白要容忍");
  assert.equal(codeOf(coerce(FieldType.Int, "3.5")), EDIT_BAD_VALUE, "3.5 不能变成 3");
  assert.equal(codeOf(coerce(FieldType.Int, 3.5)), EDIT_BAD_VALUE);
  assert.equal(codeOf(coerce(FieldType.Int, "")), EDIT_BAD_VALUE);
  assert.equal(codeOf(coerce(FieldType.Int, "abc")), EDIT_BAD_VALUE);
  assert.equal(codeOf(coerce(FieldType.Int, Number.NaN)), EDIT_BAD_VALUE);
  assert.equal(codeOf(coerce(FieldType.Int, Number.POSITIVE_INFINITY)), EDIT_BAD_VALUE);
});

test("[编辑器·属性] Float 收小数、拒非有限值", () => {
  assert.equal(coerce(FieldType.Float, "3.5").ok, true);
  assert.equal(codeOf(coerce(FieldType.Float, Number.NaN)), EDIT_BAD_VALUE);
  assert.equal(codeOf(coerce(FieldType.Float, "NaN")), EDIT_BAD_VALUE);
});

test("[编辑器·属性] Bool 只认 true/false（字符串形式也认）", () => {
  assert.equal(coerce(FieldType.Bool, true).ok, true);
  assert.equal(coerce(FieldType.Bool, "false").ok, true);
  assert.equal(coerce(FieldType.Bool, " true ").ok, true);
  assert.equal(codeOf(coerce(FieldType.Bool, "1")), EDIT_BAD_VALUE, "「1」是不是真值要报错，不能猜");
  assert.equal(codeOf(coerce(FieldType.Bool, 1)), EDIT_BAD_VALUE);
});

test("[编辑器·属性] Vec2 认「x, z」与 {x, y}，段数不对就报错", () => {
  const a = coerce(FieldType.Vec2, "1, 2");
  assert.equal(a.ok, true);
  assert.deepEqual(a.ok ? a.value : null, { x: 1, y: 2 });
  const b = coerce(FieldType.Vec2, { x: 3, y: 4 });
  assert.deepEqual(b.ok ? b.value : null, { x: 3, y: 4 });
  assert.equal(codeOf(coerce(FieldType.Vec2, "1")), EDIT_BAD_VALUE);
  assert.equal(codeOf(coerce(FieldType.Vec2, "1,2,3")), EDIT_BAD_VALUE, "多一段不能静默丢掉");
  assert.equal(codeOf(coerce(FieldType.Vec2, "1,abc")), EDIT_BAD_VALUE);
});

test("[编辑器·属性] Color 解析 #rgb / #rrggbb / #rrggbbaa 到 0..1", () => {
  const short = coerce(FieldType.Color, "#f00");
  assert.equal(short.ok, true);
  assert.deepEqual(short.ok ? short.value : null, { r: 1, g: 0, b: 0, a: 1 });

  const full = coerce(FieldType.Color, "#00ff00");
  assert.deepEqual(full.ok ? full.value : null, { r: 0, g: 1, b: 0, a: 1 });

  const alpha = coerce(FieldType.Color, "#0000ff80");
  assert.equal(alpha.ok, true);
  const v = (alpha as { value: { a: number } }).value;
  assert.ok(Math.abs(v.a - 128 / 255) < 1e-12, `alpha 必须是 128/255，实际 ${String(v.a)}`);

  assert.equal(codeOf(coerce(FieldType.Color, "red")), EDIT_BAD_VALUE, "颜色名不收（要么全支持，要么全不收）");
  assert.equal(codeOf(coerce(FieldType.Color, "#ff00")), EDIT_BAD_VALUE, "#ff00 既不是 3 位也不是 6/8 位");
});

test("[编辑器·属性] Asset 只收字符串，NodeRef 也收整数 id", () => {
  assert.equal(codeOf(coerce(FieldType.Asset, 5)), EDIT_BAD_VALUE, "资产 id 是 GUID，把节点 id 塞进去是纯粹的错");
  const r = coerce(FieldType.NodeRef, 5);
  assert.equal(r.ok, true);
  assert.equal(r.ok ? r.value : null, "5", "编辑器从树上点来的就是数字，按下标转字符串");
  assert.equal(codeOf(coerce(FieldType.NodeRef, 5.5)), EDIT_BAD_VALUE);
});

test("[编辑器·属性] StringArray 收数组或逗号分隔串，去空段", () => {
  const fromText = coerce(FieldType.StringArray, "a, b ,,c");
  assert.deepEqual(fromText.ok ? fromText.value : null, ["a", "b", "c"], "逗号分隔的串要去掉空段");
  const fromArr = coerce(FieldType.StringArray, ["x", ""]);
  assert.deepEqual(fromArr.ok ? fromArr.value : null, ["x", ""], "数组形式原样保留（空串是数据）");
  assert.equal(codeOf(coerce(FieldType.StringArray, ["x", 1])), EDIT_BAD_VALUE);
});

test("[编辑器·属性] setField 成功：返回 before/after 且真的写进组件", () => {
  const { scene, id, comp } = makeScene();
  const r = setField(scene, id, "test.widget", "alpha", "12");
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.before, 7);
  assert.equal(r.value.after, 12);
  assert.equal(comp.alpha, 12);
});

test("[编辑器·属性] ★ 校验失败一个字节都不写", () => {
  const { scene, id, comp } = makeScene();
  const before = hashText(JSON.stringify(fieldsOf(comp)));

  const r = setField(scene, id, "test.widget", "alpha", "3.5");
  assert.equal(codeOf(r), EDIT_BAD_VALUE);
  assert.equal(comp.alpha, 7, `非法输入写进去了：alpha 变成 ${String(comp.alpha)}`);
  assert.equal(hashText(JSON.stringify(fieldsOf(comp))), before, "失败路径不能留下半改状态");
});

test("[编辑器·属性] 三种「不存在」都报 BAD_FIELD 且消息指名道姓", () => {
  const { scene, id } = makeScene();
  const noNode = setField(scene, 999, "test.widget", "alpha", 1);
  assert.equal(codeOf(noNode), EDIT_BAD_FIELD);
  assert.match((noNode as unknown as { error: { message: string } }).error.message, /999/);

  const noComp = setField(scene, id, "test.nope", "alpha", 1);
  assert.equal(codeOf(noComp), EDIT_BAD_FIELD);
  assert.match((noComp as unknown as { error: { message: string } }).error.message, /test\.nope/);

  const noField = setField(scene, id, "test.widget", "nope", 1);
  assert.equal(codeOf(noField), EDIT_BAD_FIELD);
  assert.match((noField as unknown as { error: { message: string } }).error.message, /nope/);
});

test("[编辑器·属性] 错误消息带上原始输入（否则『报了错但不知道哪个值』）", () => {
  const r = coerce(FieldType.Int, "abc");
  assert.equal(r.ok, false);
  const msg = (r as unknown as { error: { message: string } }).error.message;
  assert.match(msg, /abc/, "消息里要能看见输入的那个值");
  assert.match(msg, /i32/, "也要能看见字段声明的类型");
});

test("[编辑器·属性] 实例上缺字段时用类型零值（schema 与实例不同步也不崩）", () => {
  const reg = new ComponentRegistry();
  class Sparse extends Component {
    readonly schema: ComponentSchema = { type: "test.sparse", fields: { a: FieldType.Int, b: FieldType.String } };
  }
  reg.register(new Sparse().schema, () => new Sparse());
  const scene = new Scene("editor", reg);
  const n = scene.spawnImmediate("s", scene.root.id, 2);
  const a = scene.attach(n.id, () => new Sparse());
  assert.equal(a.ok, true, a.ok ? "" : a.error.code);
  scene.flush();
  const c = scene.find(n.id)?.components.find((x) => x.type === "test.sparse");
  assert.ok(c !== undefined, "组件要先真的挂上去，否则这条判据测的是空指针");
  const fields = fieldsOf(c);
  assert.deepEqual(fields.map((f) => f.value), [0, ""], "缺字段给 zeroValue，不是 undefined");
});

// ---------------------------------------------------------------- 值真的变了吗

test("[编辑器·属性] ★ 值没变时 changed=false（撤销栈不该被空改动填满）", () => {
  const { scene, id } = makeScene();
  const same = setField(scene, id, "test.widget", "alpha", 7); // 出生值就是 7
  assert.equal(same.ok, true, same.ok ? "" : same.error.code);
  assert.equal(same.ok ? same.value.changed : true, false, "写了个一样的值，历史里不该多一条");
  assert.equal(same.ok ? same.value.before : 0, 7, "before 仍然要给出来（调用方可能还要用）");
});

test("[编辑器·属性] ★ Vec2 传一个同值的新对象也算「没变」（对象身份不等于值）", () => {
  const { scene, id } = makeScene();
  // coerce 每次都会造一个新对象，所以 `before !== after` 在这里恒成立 ——
  // 撤销栈要是照着 `!==` 判断，每敲一次回车都会多一条历史
  const r = setField(scene, id, "test.widget", "pos", { x: 1, y: 2 });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.equal(r.ok ? r.value.changed : true, false, "出生值就是 {x:1,y:2}，写回去不该算改动");
  assert.notEqual(r.ok ? r.value.before : null, r.ok ? r.value.after : undefined, "两个对象不是同一个引用");

  const r2 = setField(scene, id, "test.widget", "pos", "1, 3");
  assert.equal(r2.ok ? r2.value.changed : false, true, "y 变了就是变了");
});

test("[编辑器·属性] valuesEqual 按值比较，不受键序影响", () => {
  assert.equal(valuesEqual({ x: 1, y: 2 }, { y: 2, x: 1 }), true, "键序不同不等于值不同");
  assert.equal(valuesEqual({ x: 1, y: 2 }, { x: 1, y: 3 }), false);
  assert.equal(valuesEqual(["a", "b"], ["a", "b"]), true);
  assert.equal(valuesEqual(["a", "b"], ["b", "a"]), false, "数组顺序是信息，不是噪声");
  assert.equal(valuesEqual(1, 1), true);
  assert.equal(valuesEqual(1, "1"), false, "不跨类型相等 —— 否则 Int 字段收到字符串会被判成没改");
  assert.equal(valuesEqual(null, undefined), false);
  assert.equal(valuesEqual({ x: 1 }, { x: 1, y: 2 }), false, "键数量不同就是不同");
});
