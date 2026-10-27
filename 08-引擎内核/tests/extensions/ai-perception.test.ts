/**
 * L4 · AI 感知与目标选择
 *
 * 这两块合在一个文件里，因为它们的分工只有一条界线：
 * **感知负责"有什么"（含排序），目标选择负责"盯哪个"（含迟滞）**。
 * 分开写判据会看不见"排序→选择"这条接缝，而缝合处正是最容易错的地方
 * （选择函数自己再排一遍序，于是"感知的排序契约"永远没被验）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, FieldType } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { Perception, AI_BAD_SENSE, AI_NO_SELF } from "../../src/extensions/ai/perception.ts";
import { angleOf } from "../../src/extensions/motion/facing.ts";
import { TargetTracker, AI_BAD_TARGET } from "../../src/extensions/ai/targeting.ts";

class Marker extends Component {
  kind = "";
  readonly schema = { type: "test.marker", fields: { kind: FieldType.String } };
}

class Other extends Component {
  readonly schema = { type: "test.other", fields: {} };
}

const MARKER = "test.marker";
const OTHER = "test.other";

function makeScene(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  reg.register({ type: MARKER, fields: { kind: FieldType.String } }, () => new Marker());
  reg.register({ type: OTHER, fields: {} }, () => new Other());
  return { scene: new Scene("ai", reg), reg };
}

/** 在 (x,z) 放一个带 MARKER 的节点，返回节点 id。`extra` 表示再挂一个 OTHER。 */
function put(scene: Scene, name: string, x: number, z: number, extra = false): number {
  const n = scene.spawnImmediate(name);
  n.setLocalPosition(x, z);
  scene.attach(n.id, () => new Marker());
  if (extra) scene.attach(n.id, () => new Other());
  scene.flush();
  return n.id;
}

test("[感知] 只报 watch 里的类型，且一个节点带多种类型时取**顺序里第一个**", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  const both = put(scene, "both", 1, 0, true);
  const plain = put(scene, "plain", 0, 1);

  // watch 顺序 [OTHER, MARKER] ⇒ both 报成 OTHER
  const p = new Perception({ range: 10, watch: [OTHER, MARKER] });
  const r = p.sense(scene, self.id, 1);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const kinds = r.value.map((s) => `${String(s.nodeId)}:${s.type}`);
  assert.deepEqual(kinds, [`${String(both)}:${OTHER}`, `${String(plain)}:${MARKER}`]);

  // 换顺序 ⇒ both 报成 MARKER（顺序即优先级，不是"谁先注册"）
  const p2 = new Perception({ range: 10, watch: [MARKER, OTHER] });
  const r2 = p2.sense(scene, self.id, 1);
  assert.equal(r2.ok, true);
  if (!r2.ok) return;
  assert.equal(r2.value.find((s) => s.nodeId === both)?.type, MARKER);
});

test("[感知] 输出按 (距离², 节点 id) 升序 —— 同距离必须可判", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  // ★ **创建顺序必须与期望顺序不同**，否则这条判据在"感知不排序"时也会绿
  //   （遍历序恰好等于排好的顺序 —— 第一版就是这样，M190 没抓住）。
  //   先放最远的，再放两个恰好等距的（3-4-5 三角形，id 只能是后放的大）。
  const far = put(scene, "far", 8, 0);
  const b = put(scene, "b", 4, 3);
  const a = put(scene, "a", 3, 4);

  const p = new Perception({ range: 10, watch: [MARKER] });
  const r = p.sense(scene, self.id, 1);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(
    r.value.map((s) => s.nodeId),
    [b, a, far],
    "顺序不是 (距离², id) 升序 —— 决策会随遍历序变（这条在「不排序」时必须红）",
  );
  // dist2 是平方，不是距离：3-4-5 的平方是 25
  assert.equal(r.value[0]!.dist2, 25);
});

test("[感知] 半径边界：恰好等于 range 算看见，超出一点不算", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  const edge = put(scene, "edge", 5, 0);
  const out = put(scene, "out", 5.0001, 0);

  const p = new Perception({ range: 5, watch: [MARKER] });
  const r = p.sense(scene, self.id, 1);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const ids = r.value.map((s) => s.nodeId);
  assert.ok(ids.includes(edge), "正好在半径上的应该被看见");
  assert.ok(!ids.includes(out), "超出半径一点点的被看见了 —— 边界写错了");
});

test("[感知] 视野：正前方看见、正后方看不见、半角外（60° vs 半角 45°）看不见", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  const front = put(scene, "front", 5, 0);
  const back = put(scene, "back", -5, 0);
  // 半角 45°：30° 在视野内、60° 在视野外
  const inView = put(scene, "in", 5 * Math.cos(Math.PI / 6), 5 * Math.sin(Math.PI / 6));
  const off = put(scene, "off", 5 * Math.cos(Math.PI / 3), 5 * Math.sin(Math.PI / 3));

  const p = new Perception({ range: 10, watch: [MARKER], halfAngleDeg: 45 });
  const r = p.sense(scene, self.id, 1, 0); // 朝 +x
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const ids = r.value.map((s) => s.nodeId);
  assert.ok(ids.includes(front));
  assert.ok(ids.includes(inView), "30° 在半角 45° 内，应该看见");
  assert.ok(!ids.includes(back), "正后方被看见了 —— 视野没起作用");
  assert.ok(!ids.includes(off), "60° 超出半角 45°，不该看见");
});

test("★★ 视野锥跟着「屏幕上方 = +y」走：朝上时看不见下方的人", () => {
  // ★ 这条钉的是**第二处角度实现**（批113 修掉）：`sense()` 原来是自己写一遍
  //   `Math.atan2(dz, dx)`，而朝向来自 `angleOf()` —— 两处只有在符号约定也相同时
  //   才一致。把它们错开（或把其中一处改回数学习惯）就会出现
  //   「怪物朝着屏幕下方却看见上方的人」，而**两边各自的判据都还是绿的**。
  //   上面那条「视野」用 facing=0（+x）验，两个符号约定在 0° 上恰好重合 ⇒ 抓不到。
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  const up = put(scene, "up", 0, 3);
  const down = put(scene, "down", 0, -3);
  const east = put(scene, "east", 3, 0);

  const p = new Perception({ range: 10, watch: [MARKER], halfAngleDeg: 45 });
  const facingUp = angleOf(0, 1);
  assert.notEqual(facingUp, null);
  const r = p.sense(scene, self.id, 1, facingUp!);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const ids = r.value.map((s) => s.nodeId);
  assert.ok(ids.includes(up), "朝着屏幕上方，上方的人必须看得见");
  assert.ok(!ids.includes(down), "朝着屏幕上方却看见了下方的人 —— 两处角度的符号约定不一致");
  assert.ok(!ids.includes(east), "正侧方 90° 超出半角 45°");
});

test("[感知] 配了半角却没给朝向：报错，**不**默默当全向", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  scene.flush();
  const p = new Perception({ range: 10, watch: [MARKER], halfAngleDeg: 45 });
  const r = p.sense(scene, self.id, 1);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, AI_BAD_SENSE);
});

test("[感知] 感知者不在场景里：AI.NO_SELF", () => {
  const { scene } = makeScene();
  const p = new Perception({ range: 10, watch: [MARKER] });
  const r = p.sense(scene, 999, 1);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, AI_NO_SELF);
});

test("[感知] 记忆：跟丢后还记着位置，超过 memoryTicks 才忘", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  const prey = put(scene, "prey", 3, 0);

  const p = new Perception({ range: 10, watch: [MARKER], memoryTicks: 5 });
  assert.equal(p.sense(scene, self.id, 1).ok, true);

  // 猎物被搬远（出视野）
  scene.find(prey)!.setLocalPosition(50, 0);
  scene.flush();

  const fresh = p.sense(scene, self.id, 2);
  assert.equal(fresh.ok, true);
  if (!fresh.ok) return;
  const st = fresh.value.find((s) => s.nodeId === prey);
  assert.ok(st !== undefined, "刚跟丢就忘了 —— 记忆没生效");
  assert.equal(st!.stale, true, "跟丢了却标成可见");
  assert.equal(st!.x, 50, "记忆里应该是**当前**坐标（节点还活着）");
  assert.deepEqual([...p.visibleIds()], [], "这一轮什么都没真看见");

  // tick 8 时距最后一次看见已经 7 个 tick，超过 5 ⇒ 忘掉
  const later = p.sense(scene, self.id, 8);
  assert.equal(later.ok, true);
  if (!later.ok) return;
  assert.equal(later.value.find((s) => s.nodeId === prey), undefined, "超过 memoryTicks 还没忘");
  assert.equal(p.memorySize(), 0);
});

test("[感知] memoryTicks=0：立刻忘，且记忆不会无限增长", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  put(scene, "a", 1, 0);
  const p = new Perception({ range: 10, watch: [MARKER] });
  for (let t = 0; t < 50; t++) assert.equal(p.sense(scene, self.id, t).ok, true);
  assert.equal(p.memorySize(), 0, "不做记忆的感知器却在攒记忆 —— 那是内存泄漏");
});

test("[感知] 目标被销毁后，记忆里的位置仍然可用（坐标取记忆）", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  const prey = put(scene, "prey", 4, 0);
  const p = new Perception({ range: 10, watch: [MARKER], memoryTicks: 3 });
  assert.equal(p.sense(scene, self.id, 1).ok, true);

  scene.destroy(prey);
  scene.flush();
  const r = p.sense(scene, self.id, 2);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const st = r.value.find((s) => s.nodeId === prey);
  assert.ok(st !== undefined, "目标没了，记忆也应该还在 grace 内");
  assert.equal(st!.x, 4, "节点销毁后应该用记忆里的坐标");
  assert.equal(st!.stale, true);
});

test("[感知] 确定性：两个独立感知器看同一个场景，结果逐项相同", () => {
  const { scene } = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  for (let i = 0; i < 20; i++) put(scene, `m${String(i)}`, (i % 5) - 2, Math.floor(i / 5) - 1);

  const a = new Perception({ range: 20, watch: [MARKER] });
  const b = new Perception({ range: 20, watch: [MARKER] });
  const ra = a.sense(scene, self.id, 7);
  const rb = b.sense(scene, self.id, 7);
  assert.equal(ra.ok && rb.ok, true);
  if (!ra.ok || !rb.ok) return;
  assert.deepEqual(ra.value, rb.value);
});

// ---------------------------------------------------------------- 目标选择

/** 造一条感知结果（不经过场景：目标选择只依赖这份数据）。 */
function s(nodeId: number, dist2: number, type = MARKER, stale = false) {
  return { nodeId, type, x: dist2, z: 0, dist2, seenTick: 1, stale };
}

test("[目标] nearest 取最近；平手按 id 升序", () => {
  const t = new TargetTracker();
  const r = t.update([s(9, 40), s(3, 10), s(5, 10)], 1);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.value.nodeId, 3, "同距离应取 id 小的");
  assert.equal(r.value.kept, false);
});

test("[目标] 迟滞：新目标只近 10% 不换，近 30% 才换", () => {
  const t = new TargetTracker({ stickiness: 0.2 });
  // 先把 A 立成目标
  assert.equal(t.update([s(1, 100), s(2, 121)], 1).ok, true);
  assert.equal(t.current(), 1);

  // B 近 9%：不换
  const near = t.update([s(1, 100), s(2, 91)], 2);
  assert.equal(near.ok, true);
  if (!near.ok) return;
  assert.equal(near.value.nodeId, 1, "只近 9% 就换目标 —— 迟滞没起作用");
  assert.equal(near.value.kept, true);

  // B 近 30%：换
  const far = t.update([s(1, 100), s(2, 70)], 3);
  assert.equal(far.ok, true);
  if (!far.ok) return;
  assert.equal(far.value.nodeId, 2);
  assert.equal(far.value.kept, false);
});

test("[目标] stickiness=0：每轮都取最优（会换，这是可测的极端）", () => {
  const t = new TargetTracker({ stickiness: 0 });
  assert.equal(t.update([s(1, 100), s(2, 101)], 1).ok, true);
  assert.equal(t.current(), 1);
  assert.equal(t.update([s(1, 100), s(2, 99)], 2).ok, true);
  assert.equal(t.current(), 2);
});

test("[目标] farthest 选最远，且迟滞方向是「更远」而不是「更近」", () => {
  const t = new TargetTracker({ policy: "farthest", stickiness: 0.2 });
  assert.equal(t.update([s(1, 100), s(2, 400)], 1).ok, true);
  assert.equal(t.current(), 2);
  // 有个更远的只多 10%：不换
  assert.equal(t.update([s(2, 400), s(3, 440)], 2).ok, true);
  assert.equal(t.current(), 2, "远 10% 就换 —— farthest 的迟滞方向写反了");
  // 远 30%：换
  assert.equal(t.update([s(2, 400), s(3, 520)], 3).ok, true);
  assert.equal(t.current(), 3);
});

test("[目标] preferred：按类型优先级选，同类型才比距离；列表外的类型不选", () => {
  const t = new TargetTracker({ policy: "preferred", preferred: [OTHER, MARKER] });
  const r = t.update([s(1, 4, MARKER), s(2, 900, OTHER), s(3, 1, "test.unknown")], 1);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.value.nodeId, 2, "类型优先级没起作用（OTHER 应优先，哪怕更远）");
  // 列表外的类型即使最近也不会被选中
  assert.notEqual(r.value.nodeId, 3);
});

test("[目标] preferred 没给列表：报 AI.BAD_TARGET，不偷偷退化成 nearest", () => {
  const t = new TargetTracker({ policy: "preferred" });
  const r = t.update([s(1, 4)], 1);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, AI_BAD_TARGET);
});

test("[目标] 跟丢后 graceTicks 内保留，超过就重选（不永远记着，也不当场失忆）", () => {
  const t = new TargetTracker({ graceTicks: 3 });
  assert.equal(t.update([s(1, 10), s(2, 50)], 1).ok, true);
  assert.equal(t.current(), 1);

  // 第 3 tick 只剩 2 —— 在 grace 内，仍是 1（stale）
  const g = t.update([s(2, 50)], 3);
  assert.equal(g.ok, true);
  if (!g.ok) return;
  assert.equal(g.value.nodeId, 1);
  assert.equal(g.value.stale, true, "grace 内的目标应标成 stale");

  // 第 5 tick：距最后看见（tick 1）已 4 > 3 ⇒ 换成 2
  const out = t.update([s(2, 50)], 5);
  assert.equal(out.ok, true);
  if (!out.ok) return;
  assert.equal(out.value.nodeId, 2, "超过 grace 还在记着旧目标");
});

test("[目标] 不抖动：两个目标轮流略微更近，20 tick 内只换一次", () => {
  // 场景：A 一直略近，但每 tick 有 ±5% 的抖动（现实中来自移动）
  const t = new TargetTracker({ stickiness: 0.2 });
  let switches = 0;
  let prev: number | null = null;
  for (let tick = 0; tick < 20; tick++) {
    const a = 100 + (tick % 2 === 0 ? 0 : 10); // A 在 100~110 之间跳
    const b = 100 + (tick % 2 === 0 ? 9 : -9); // B 在 91~109 之间跳（始终在 A±10%）
    const r = t.update([s(1, a), s(2, b)], tick);
    assert.equal(r.ok, true);
    if (!r.ok) continue;
    if (prev !== null && r.value.nodeId !== prev) switches++;
    prev = r.value.nodeId;
  }
  assert.ok(switches <= 1, `20 tick 内换了 ${String(switches)} 次目标 —— 这就是抖动`);
});
