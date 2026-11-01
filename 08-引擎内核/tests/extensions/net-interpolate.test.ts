/**
 * L4 · 视觉插值的契约（批168，`net/interpolate.ts`）
 *
 * ★★ 这一层要回答的是「别人画在哪」，不是「Interpolator 写对了没有」。
 *   三个承诺，各有一组判据：
 *
 *   ① **本地玩家不插值。** 预测的全部价值是"输入与画面之间没有延迟"，插值会把
 *      这份延迟加回去。这条坏了**看不出来**：画面更顺了，而手感差一帧。
 *   ② **新一段的起点是"现在画到哪"。** 两份快照之间上一段没走完时，从上一份的
 *      权威坐标重新开始会让画面往回跳一段刚走过的路。
 *   ③ **超阈值直接跳。** 传送/重生也插值的话，人从地图这头飘到那头。
 *
 * ★ 每条判据都同时读**两个**观测量（该变的变了 ∧ 不该变的没变）。
 *   「标志位对了、效果没发生」在这里最典型：`started` 涨了而 `at()` 返回 null
 *   （或者反过来）都是同一类假绿，只读一个数分不开。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { NET_IDENTITY_TYPE, NetIdentity, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { DEFAULT_INTERP_MS, createInterpolator } from "../../src/extensions/net/interpolate.ts";

// ---------------------------------------------------------------- 夹具

function world(): Scene {
  const reg = new ComponentRegistry();
  registerNetIdentity(reg);
  return new Scene("main", reg);
}

/** 造一个挂了 `net.identity` 的实体（归 `owner`）。 */
function spawn(scene: Scene, owner: number, id: number, x = 0, y = 0): number {
  const n = scene.spawnImmediate("e", scene.rootId, id);
  scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  scene.flush();
  n.setLocalPosition(x, y);
  return n.id;
}

function moveTo(scene: Scene, id: number, x: number, y = 0): void {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 ${String(id)} 不见了`);
  n.setLocalPosition(x, y);
}

// ---------------------------------------------------------------- ① 谁被插值

test("★★ 本地玩家不插值、别人插值（两个观测量一起读）", () => {
  const scene = world();
  const me = spawn(scene, 0, 10);
  const other = spawn(scene, 1, 11);
  const it = createInterpolator();

  it.capture(scene, 0);
  // 两个实体走同样的一步 —— 唯一的区别是归属。位移相同 ⇒ 「他插了我不插」
  // 不可能是"位移大小"造成的。
  moveTo(scene, me, 0.5);
  moveTo(scene, other, 0.5);
  const began = it.rebase(scene, 0, 100);

  assert.equal(began, 1, "只该开始一段：我这一段根本不该存在（不是「时长为 0」）");
  assert.equal(it.at(me), null, "本地玩家被插值了 ⇒ 输入与画面之间多一帧延迟，预测白做");
  assert.notEqual(it.at(other), null, "别人没被插值 ⇒ 位移仍然一格一格地闪");
  assert.deepEqual(
    { active: it.stats().active, started: it.stats().started },
    { active: 1, started: 1 },
    "`active` 把「我自己」也算进去的话，它就永远回不到 0 —— 而那个数是唯一能发现轨道泄漏的量",
  );
});

test("★ 没握手（`local = null`）时全场都插值：此时也不预测，两者一致", () => {
  const scene = world();
  const a = spawn(scene, 0, 12);
  const b = spawn(scene, 1, 13);
  const it = createInterpolator();
  it.capture(scene, null);
  moveTo(scene, a, 0.5);
  moveTo(scene, b, 0.5);
  assert.equal(it.rebase(scene, null, 100), 2, "没有座位就没有「我自己」，两个都该插");
  assert.equal(it.stats().active, 2);
});

test("★★ 归属交接到我头上：上一段「别人的」插值必须立刻作废", () => {
  const scene = world();
  const n = spawn(scene, 7, 14); // 先归 7 号（别人）
  const it = createInterpolator();

  it.capture(scene, 0);
  moveTo(scene, n, 0.5);
  assert.equal(it.rebase(scene, 0, 100), 1, "别人的实体本来就该插值（前提）");
  assert.notEqual(it.at(n), null);

  // 主机把它交接给我（0 号）：下一份快照里 owner 变成我。
  const ident = scene.find(n)?.get<NetIdentity>(NET_IDENTITY_TYPE);
  assert.ok(ident !== undefined, "节点上该有归属组件");
  ident.owner = 0;
  it.capture(scene, 0);
  moveTo(scene, n, 1);
  it.rebase(scene, 0, 100);

  assert.equal(
    it.at(n),
    null,
    "交接之后还被插值 ⇒ 我的角色由「它还是别人的时候」那段过渡带着走，而本地一毫秒也不该插",
  );
  assert.equal(it.stats().active, 0, "旧轨道没被清 ⇒ `active` 泄漏");
});

// ---------------------------------------------------------------- ② 重新定基

test("★★ 新一段的起点是「现在画到哪」，不是「上一份权威在哪」", () => {
  const scene = world();
  const n = spawn(scene, 1, 30);
  const it = createInterpolator();

  it.capture(scene, 0); // 起点 (0,0)
  moveTo(scene, n, 1);
  it.rebase(scene, 0, 100); // 0 → 1，摊 100ms
  it.beginFrame(50);
  const mid = it.at(n);
  assert.ok(mid !== null);
  assert.equal(mid.x, 0.5, "走了 50/100 就该在一半（这条不成立的话下面那条也不用看了）");

  // 第二份快照到：装载前再捕获一次（此刻节点还在 1，**画面上**是 0.5）
  it.capture(scene, 0);
  moveTo(scene, n, 2);
  it.rebase(scene, 0, 100);

  const start = it.at(n);
  assert.ok(start !== null, "新一段没开始 ⇒ 第二份快照的位移是**跳**过去的");
  assert.equal(
    start.x,
    0.5,
    "起点用了「上一份权威坐标」(1.0) ⇒ 画面往回跳一段刚走过的路；" +
      "只有在卡顿（帧率低于插值时长）时才明显，而那时人只会说「有点卡」",
  );
});

// ---------------------------------------------------------------- ② 时钟与到位

test("★★ 时钟是累加的、走满就交还节点坐标；而且全程不写节点", () => {
  const scene = world();
  const n = spawn(scene, 1, 40);
  const it = createInterpolator();

  it.capture(scene, 0);
  moveTo(scene, n, 1);
  it.rebase(scene, 0, 100);

  it.beginFrame(25);
  assert.equal(it.at(n)?.x, 0.25);
  it.beginFrame(25);
  assert.equal(
    it.at(n)?.x,
    0.5,
    "每帧把时间**覆盖**成 dt 而不是累加 ⇒ 永远走不到终点，" +
      "而「走满之后 at() 归 null」那条判据照样是绿的",
  );

  const node = scene.find(n);
  assert.ok(node !== undefined);
  assert.equal(
    node.localPosition.x,
    1,
    "插值写进了节点坐标 ⇒ 预测/重放会以中间值为基准（`predict.ts` 文件头的覆盖语义被破坏）",
  );

  it.beginFrame(60); // 累计 110 > 100
  assert.equal(it.at(n), null, "走满了还返回中间值 ⇒ 画面永远差最后的几厘米");
  assert.deepEqual(
    { active: it.stats().active, settled: it.stats().settled },
    { active: 0, settled: 1 },
    "走满却没有被清走（轨道泄漏）",
  );
});

test("★ 帧长 NaN / ≤0 一律忽略：NaN 会把精灵画到 (NaN, NaN) 上（表现是「角色凭空消失」）", () => {
  const scene = world();
  const n = spawn(scene, 1, 41);
  const it = createInterpolator();
  it.capture(scene, 0);
  moveTo(scene, n, 1);
  it.rebase(scene, 0, 100);
  it.beginFrame(50);
  const before = it.at(n);
  assert.ok(before !== null);

  for (const bad of [Number.NaN, Number.POSITIVE_INFINITY, 0, -5]) {
    it.beginFrame(bad);
    const after = it.at(n);
    assert.ok(after !== null, `帧长 ${String(bad)} 让这一段提前结束了`);
    assert.ok(Number.isFinite(after.x) && Number.isFinite(after.y), `帧长 ${String(bad)} 把坐标算成了非有限值`);
    assert.deepEqual(after, before, `帧长 ${String(bad)} 推进了时钟`);
  }
});

// ---------------------------------------------------------------- ③ 阈值

test("★★ 超过阈值直接跳、没超过就插值（两半都要验）", () => {
  const near = world();
  const a = spawn(near, 1, 20);
  const itNear = createInterpolator({ snapDistance: 2 });
  itNear.capture(near, 0);
  moveTo(near, a, 0.6); // 一个广播周期的正常位移
  itNear.rebase(near, 0, 100);
  assert.notEqual(itNear.at(a), null, "正常走一步被当成传送 ⇒ 一秒跳七次，比不插值更糟");
  assert.equal(itNear.stats().snapped, 0);
  assert.ok(
    Math.abs(itNear.stats().maxDistance - 0.6) < 1e-12,
    `被插值的最大位移记错了（${String(itNear.stats().maxDistance)}）—— 这个数是调阈值时唯一的依据`,
  );

  const far = world();
  const b = spawn(far, 1, 21);
  const itFar = createInterpolator({ snapDistance: 2 });
  itFar.capture(far, 0);
  moveTo(far, b, 8); // 传送 / 重生 / 主机把位置改回来
  itFar.rebase(far, 0, 100);
  assert.equal(itFar.at(b), null, "被传送 8 格还插值 ⇒ 人从地图这头飘到那头");
  assert.deepEqual(
    { snapped: itFar.stats().snapped, active: itFar.stats().active },
    { snapped: 1, active: 0 },
    "判成传送就必须留下计数，否则「阈值一直在生效」与「一个传送都没有」分不开",
  );
});

test("★ 阈值必须是 >0 的有限数（0 会把所有移动判成传送）", () => {
  assert.throws(() => createInterpolator({ snapDistance: 0 }), RangeError);
  assert.throws(() => createInterpolator({ snapDistance: Number.NaN }), RangeError);
});

// ---------------------------------------------------------------- ④ 世界的形状

test("★★ 实体从世界里消失 ⇒ 轨道一起清（否则 `active` 永远不归零）", () => {
  const scene = world();
  const a = spawn(scene, 1, 50);
  const b = spawn(scene, 1, 51);
  const it = createInterpolator();
  it.capture(scene, 0);
  moveTo(scene, a, 0.5);
  moveTo(scene, b, 0.5);
  it.rebase(scene, 0, 100);
  assert.equal(it.stats().active, 2, "两段都该在走");

  scene.destroy(b);
  scene.flush();
  it.capture(scene, 0);
  moveTo(scene, a, 1);
  it.rebase(scene, 0, 100);

  assert.equal(it.stats().active, 1, "被销毁的实体还留着轨道 ⇒ 世界稳定后 active 也不归 0");
  assert.equal(it.at(b), null, "已销毁的节点不该还有插值坐标（id 若被复用，新节点会从旧位置飘过来）");
});

test("★ 新出现的实体没有「上一帧」⇒ 直接到位，不从原点飞来", () => {
  const scene = world();
  const a = spawn(scene, 1, 60);
  const it = createInterpolator();
  it.capture(scene, 0);
  // 装载之后才出现的（刚进视野 / 刚被造出来 / 我刚进房看到的第一批）
  //
  // ★ 位置必须落在**阈值之内**（缺省 2.0）。放远了，那条"从 (0,0) 出发"的错误写法
  //   会被阈值拦成一次传送 —— 于是外层的断言（`at()` 为 null）照样成立，判据变绿，
  //   而规则其实已经被改坏了。这是「语料选得太宽松」的典型：判别力藏在**距离**里。
  const b = spawn(scene, 1, 61, 1, 0);
  moveTo(scene, a, 0.5);
  const began = it.rebase(scene, 0, 100);

  assert.equal(began, 1, "只有 a 有上一帧");
  assert.equal(it.at(b), null, "从 (0,0) 开始插 ⇒ 所有新角色都是「从地图原点飞过来」的");
});

test("★ 时长非法时回落到缺省，**不抛**：表现参数错了的代价是「不够平滑」，不是「装不上世界」", () => {
  const scene = world();
  const n = spawn(scene, 1, 70);
  const it = createInterpolator();
  it.capture(scene, 0);
  moveTo(scene, n, 1);
  assert.equal(it.rebase(scene, 0, Number.NaN), 1, "一段都不开始 ⇒ 整段功能静默失效");
  it.beginFrame(DEFAULT_INTERP_MS / 2);
  const mid = it.at(n);
  assert.ok(mid !== null);
  assert.ok(
    Math.abs(mid.x - 0.5) < 1e-9,
    `缺省时长没生效：走了 ${String(DEFAULT_INTERP_MS / 2)}ms 却不在半路（x=${String(mid.x)}）`,
  );
});
