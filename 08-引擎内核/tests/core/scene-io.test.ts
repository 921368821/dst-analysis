/**
 * L2 · 场景存档与跳时间测试
 *
 * 存档的核心承诺是"存 → 读 → 再存，逐字节相同"。
 * 跳时间的核心承诺是"**报告**跳过了什么"（而不是让世界看起来没变）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import {
  saveScene,
  loadScene,
  sceneToJson,
  sceneFromJson,
  SCENE_FORMAT_VERSION,
  SCENE_SCHEMA,
} from "../../src/core/scene/scene-io.ts";

class Ttl extends Component {
  ttl = 10;
  readonly schema: ComponentSchema = { type: "test.ttl", fields: { ttl: FieldType.Float } };
  onFastForward(elapsed: number): void {
    this.ttl = Math.max(0, this.ttl - elapsed);
  }
}

class Brain extends Component {
  mood = "idle";
  readonly schema: ComponentSchema = { type: "test.brain", fields: { mood: FieldType.String } };
  // 故意**不**实现 onFastForward：跳时间时它"什么都没发生"，必须被报告
}

function makeScene(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  reg.register({ type: "test.ttl", fields: { ttl: FieldType.Float } }, () => new Ttl());
  reg.register({ type: "test.brain", fields: { mood: FieldType.String } }, () => new Brain());
  return { scene: new Scene("demo", reg), reg };
}

function build(): { scene: Scene; reg: ComponentRegistry; ids: number[] } {
  const { scene, reg } = makeScene();
  const a = scene.spawnImmediate("a");
  a.setLocalPosition(1, 2);
  const b = scene.spawnImmediate("b", a.id);
  b.setLocalPosition(0.5, 0.5);
  b.setLocalScale(2, 3);
  b.setLocalRotation(0.25);
  b.zIndex = 4;
  b.active = true;
  b.layer = 2;
  scene.attach(a.id, () => new Ttl());
  scene.attach(b.id, () => new Brain());
  scene.attach(b.id, () => new Ttl());
  scene.flush();
  return { scene, reg, ids: [a.id, b.id] };
}

test("存 → 读 → 再存（完整版）：逐字节相同", () => {
  const { scene, reg } = build();
  const json1 = sceneToJson(saveScene(scene));

  const parsed = sceneFromJson(json1);
  assert.ok(parsed.ok, "刚生成的 JSON 必须能解析回来");
  if (!parsed.ok) return;

  const { scene: fresh } = makeScene();
  const loaded = loadScene(fresh, parsed.value, reg);
  assert.ok(loaded.ok);
  if (!loaded.ok) return;
  assert.deepEqual(loaded.value.skipped, [], "不该有跳过项");

  const json2 = sceneToJson(saveScene(fresh));
  assert.equal(json1, json2, `二次编码必须逐字节相同：\n  1: ${json1}\n  2: ${json2}`);
});

test("父子关系与变换成分都被恢复", () => {
  const { scene, reg } = build();
  const parsed = sceneFromJson(sceneToJson(saveScene(scene)));
  assert.ok(parsed.ok);
  if (!parsed.ok) return;
  const { scene: fresh } = makeScene();
  const loaded = loadScene(fresh, parsed.value, reg);
  assert.ok(loaded.ok);

  const [idA, idB] = parsed.value.nodes.map((n) => n.id);
  const a = fresh.find(idA!)!;
  const b = fresh.find(idB!)!;
  assert.equal(b.parent?.id, a.id, "父子关系应恢复");
  assert.deepEqual([b.localPosition.x, b.localPosition.y], [0.5, 0.5]);
  assert.deepEqual([b.localScale.x, b.localScale.y], [2, 3]);
  assert.equal(b.localRotation, 0.25);
  assert.equal(b.zIndex, 4);
  assert.equal(b.layer, 2);
  // 世界变换要重算（不重算的话读档后位置是旧缓存）
  assert.deepEqual([b.worldPosition.x, b.worldPosition.y], [1.5, 2.5]);
});

test("组件按 type 升序输出（与插入顺序无关）", () => {
  const { scene } = build();
  const snap = saveScene(scene);
  for (const n of snap.nodes) {
    const types = n.components.map((c) => c.type);
    const sorted = [...types].sort();
    assert.deepEqual(types, sorted, `节点 #${n.id} 的组件未按 type 排序：${types.join(",")}`);
  }
});

test("未知组件类型：**报告**而不是静默丢弃", () => {
  const { scene } = build();
  const snap = sceneFromJson(sceneToJson(saveScene(scene)));
  assert.ok(snap.ok);
  if (!snap.ok) return;
  // 用一个没有注册 brain 的注册表去读
  const reg2 = new ComponentRegistry();
  reg2.register({ type: "test.ttl", fields: { ttl: FieldType.Float } }, () => new Ttl());
  const { scene: fresh } = makeScene();
  const r = loadScene(fresh, snap.value, reg2);
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.ok(
    r.value.skipped.some((s) => s.includes("test.brain")),
    `未知组件必须被报告：${JSON.stringify(r.value.skipped)}`,
  );
  // 已注册的仍然挂上
  assert.ok(fresh.componentsOf("test.ttl").length > 0);
});

test("缺字段：报告 missingFields（旧版本存档会缺字段）", () => {
  const { scene, reg } = build();
  const snap = sceneFromJson(sceneToJson(saveScene(scene)));
  assert.ok(snap.ok);
  if (!snap.ok) return;
  // 手工删掉一个字段，模拟旧档
  const nodes = snap.value.nodes.map((n) => ({
    ...n,
    components: n.components.map((c) => (c.type === "test.ttl" ? { type: c.type, data: {} } : c)),
  }));
  const { scene: fresh } = makeScene();
  const r = loadScene(fresh, { ...snap.value, nodes }, reg);
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.ok(
    r.value.missingFields.some((m) => m.includes("ttl")),
    `缺字段必须被报告：${JSON.stringify(r.value.missingFields)}`,
  );
});

test("格式过新：明确拒绝（不许'尽力读'）", () => {
  const { scene, reg } = build();
  const snap = saveScene(scene);
  const { scene: fresh } = makeScene();
  const r = loadScene(fresh, { ...snap, format: SCENE_FORMAT_VERSION + 5 }, reg);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "SCENE.FORMAT_TOO_NEW");
});

test("坏 JSON：可读错误，不抛", () => {
  const r = sceneFromJson("{nope");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "SCENE.BAD_JSON");
});

test("loadScene 会先清空（'打开一个关卡'的语义，不是'叠加'）", () => {
  const { scene, reg } = build();
  const json = sceneToJson(saveScene(scene));
  const parsed = sceneFromJson(json);
  assert.ok(parsed.ok);
  if (!parsed.ok) return;
  // 同一个 scene 上再读一次：不该变成双份
  const before = saveScene(scene).nodes.length;
  loadScene(scene, parsed.value, reg);
  const after = saveScene(scene).nodes.length;
  assert.equal(after, before, `读档后节点数应不变（${before} → ${after}）`);
});

test("fastForward：实现接口的组件被结算，没实现的被**报告**", () => {
  const { scene } = build();
  const ttl = scene.componentsOf<Ttl>("test.ttl")[0]!;
  assert.equal(ttl.ttl, 10);

  const report = scene.fastForward(4);
  assert.equal(report.elapsed, 4);
  assert.equal(ttl.ttl, 6, "TTL 应该扣掉 4 秒");
  assert.ok(report.handled >= 1, "至少有一个被结算");
  assert.equal(report.skipped, 1, "Brain 没有实现 onFastForward，应计入 skipped");
  assert.equal(report.skippedByType.get("test.brain"), 1);
  assert.equal(scene.totalFastForwarded, 4);
});

test("fastForward：跳很久也不会把值跳成负数", () => {
  const { scene } = build();
  const ttl = scene.componentsOf<Ttl>("test.ttl")[0]!;
  scene.fastForward(999);
  assert.equal(ttl.ttl, 0, "应被夹到 0，不是 -989");
});

test("fastForward 不接受负 elapsed", () => {
  const { scene } = build();
  assert.throws(() => scene.fastForward(-1), /负/);
});

test("存档里不含 GPU 句柄之类的进程内 id（只存字符串/数字状态）", () => {
  const { scene } = build();
  const json = sceneToJson(saveScene(scene));
  assert.ok(!json.includes("Handle"), "不该出现句柄");
  assert.ok(!/"(texture|pipeline|vbo|ibo)"/.test(json), "不该出现 GPU 资源字段");
});

// ------------------------------------------------------------------ 存档头（版本闸门）
//
// ★ 以前 `sceneFromJson` 只 `JSON.parse` + 查 `format`/`nodes` 存在，**从不看版本上下限**。
//   后果分两种，都很安静：
//   ① `format: 0` 的旧档 → 当成当前版本读进来（组件按今天的字段解释旧数据）；
//   ② `format: 99`（新引擎写的）→ 也读进来，直到 `loadScene` 才炸 ——
//      而调用方完全可能只解析不加载（编辑器列表、存档预览）。
//   现在版本闸门在**解析这一步**就生效，且错误码说的是场景域的话。

test("存档头：比当前版本旧（format:0）→ FORMAT_BAD，不再静默当当前版本", () => {
  const r = sceneFromJson('{"format":0,"name":"old","nodes":[]}');
  assert.equal(r.ok, false, "format:0 必须被拒绝");
  if (!r.ok) assert.equal(r.error.code, "SCENE.FORMAT_BAD");
});

test("存档头：非整数版本（format:1.5）→ FORMAT_BAD（以前两个比较都不成立，原样返回）", () => {
  const r = sceneFromJson('{"format":1.5,"name":"x","nodes":[]}');
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "SCENE.FORMAT_BAD");
});

test("存档头：版本过新（format:99）→ 解析就报 FORMAT_TOO_NEW，不等 loadScene", () => {
  const r = sceneFromJson('{"format":99,"name":"future","nodes":[]}');
  assert.equal(r.ok, false, "新引擎写的档，旧引擎读解析阶段就该拒绝");
  if (!r.ok) assert.equal(r.error.code, "SCENE.FORMAT_TOO_NEW");
});

test("存档头：缺 format → BAD_JSON（'没写版本'不等于'版本是 1'）", () => {
  const r = sceneFromJson('{"name":"x","nodes":[]}');
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "SCENE.BAD_JSON");
});

test("存档头：版本闸门用的键必须就是 format（不是 __v）", () => {
  // 这条是"接线检查"：`SCENE_SCHEMA` 一旦丢掉 versionKey，上面四条会全部变绿 ——
  // 因为 Schema 会按 `__v` 读、读不到就当 v1，于是任何 format 值都被放行。
  assert.equal(SCENE_SCHEMA.versionKey, "format");
  assert.equal(SCENE_SCHEMA.version, SCENE_FORMAT_VERSION);
  // 而且 fields 里不能再有 format：否则 encode 会写出两个 "format" 键
  assert.equal(SCENE_SCHEMA.fields.includes("format"), false);
});

test("存档头：我们自己的档读回来版本恒等于当前版本", () => {
  const { scene } = build();
  const r = sceneFromJson(sceneToJson(saveScene(scene)));
  assert.ok(r.ok);
  if (!r.ok) return;
  assert.equal(r.value.format, SCENE_FORMAT_VERSION);
});
