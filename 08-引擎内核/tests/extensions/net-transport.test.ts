/**
 * L4 · 环回传输的契约（批150）
 *
 * ★ 这份判据要回答的问题不是「Transport 这个类写对了没有」，而是三件事：
 *   ① 同一串输入，**过一遍网络**之后主机算出来的世界与单机逐字节一致吗？
 *   ② 晚到几拍的消息，追平之后结果还一样吗（还是变成了另一种结局）？
 *   ③ 丢了一条包，接收方能不能**发现**（而不是把后面那条当成前面那条用）？
 *
 * ★★ 为什么第 ① 条必须逐 tick 比对、而不是只比终态：
 *   终态相等有两种完全不同的原因 —— 「过程相同」与「误差互相抵消」。后者在浮点上
 *   迟早会发生（尤其有归一化和累加时），而它一旦发生，回滚重算与预测都会开始漂。
 *   逐 tick 逐字节相等才排除了"抵消"这条解释。
 *
 * ★ 一条刻意的约定：**判据自己造语料**（`keysAt` 的 24 拍脚本），不依赖 demo 的输入。
 *   demo 的输入会随玩法改动变，判据跟着变就再也不知道自己在守什么。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";
import type { InputSnapshot } from "../../src/platform/input/device.ts";
import { directionFromMap, stepOf } from "../../src/extensions/input/player-controller.ts";
import { DEFAULT_INPUT_MAP } from "../../src/extensions/input/input-map.ts";
import { dirStep, type MoveIntent } from "../../src/extensions/motion/intent.ts";
import {
  createLoopbackPair,
  type IntentMessage,
  type NetMessage,
} from "../../src/extensions/net/transport.ts";

const SPEED = 4.5;
const DT = 1 / 30;

/** 造一个「按住这些键」的输入快照（其余字段是空值，与真设备"什么都没发生"等价）。 */
function snapOf(keys: readonly string[]): InputSnapshot {
  return {
    keysDown: new Set(keys),
    keysPressed: new Set<string>(),
    keysReleased: new Set<string>(),
    pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
    wheel: { dx: 0, dy: 0 },
    text: "",
  };
}

/**
 * 24 拍的输入脚本：直走 / 斜走 / 反向 / 空拍 / 混入非移动键。
 *
 * ★ 必须包含**斜走**与**空拍**：前者是归一化唯一能暴露差异的地方，
 *   后者是"零位移不该被当成一条消息或一条位移"的地方。
 */
function keysAt(tick: number): readonly string[] {
  const dirs: readonly (readonly string[])[] = [
    ["KeyD"],
    ["KeyD", "KeyW"],
    ["KeyW"],
    ["KeyA", "KeyW"],
    ["KeyA"],
    ["KeyA", "KeyS"],
    ["KeyS"],
    [],
  ];
  const base = dirs[tick % dirs.length] ?? [];
  // 非移动键（攻击）混进来：它不该改变位移，也不该被当成移动意图发出去。
  return tick % 3 === 0 ? [...base, "Space"] : base;
}

function intentOf(tick: number): MoveIntent {
  const d = directionFromMap(DEFAULT_INPUT_MAP, snapOf(keysAt(tick)));
  return { kind: "move.dir", dx: d.dx, dz: d.dz };
}

function intentMsg(tick: number): IntentMessage {
  // ★ 过一遍 JSON：消息必须**可序列化**。若哪天给意图塞进一个函数引用或一个 Node，
  //   这里会当场变成 `{}`，后面的等价判据就再也对不上。
  return JSON.parse(
    JSON.stringify({ kind: "intent", from: 0, tick, seq: tick, entity: 1, intent: intentOf(tick) }),
  ) as IntentMessage;
}

function pos(o: { x: number; y: number }): string {
  return `${String(o.x)},${String(o.y)}`;
}

test("[传输] 同一拍发的消息同一拍就能收到，且顺序 = 发送顺序", () => {
  const [a, b] = createLoopbackPair();
  const sent: NetMessage[] = [
    { kind: "intent", from: 0, tick: 5, seq: 0, entity: 1, intent: { kind: "move.dir", dx: 1, dz: 0 } },
    { kind: "intent", from: 0, tick: 5, seq: 1, entity: 1, intent: { kind: "move.dir", dx: 0, dz: 1 } },
    { kind: "intent", from: 0, tick: 5, seq: 2, entity: 1, intent: { kind: "move.cell", cell: 7 } },
  ];
  for (const m of sent) assert.equal(a.send(m), true);

  const got = b.receive(5);
  assert.equal(got.length, 3, `同一拍发的三条应同一拍全到，实际 ${String(got.length)} 条`);
  assert.deepEqual(
    got.map((m) => m.seq),
    [0, 1, 2],
    "到达顺序必须与发送顺序一致（乱序会让「这一拍想往右」变成「上一拍想往右」）",
  );
  assert.equal(a.stats().sent, 3);
  assert.equal(b.stats().received, 3);
  assert.equal(b.stats().queued, 0);
});

test("[传输] 延迟 3 拍：tick 2 的消息在 tick 4 取不到、tick 5 才到（边界是 ≤ 不是 <）", () => {
  const [a, b] = createLoopbackPair({ delayTicks: 3 });
  assert.equal(a.send(intentMsg(2)), true);

  assert.equal(b.receive(4).length, 0, "2 + 3 = 5，第 4 拍不该收到 —— 收到说明延迟没生效");
  const got = b.receive(5);
  assert.equal(got.length, 1, "第 5 拍必须收到（`at <= tick`）—— 收不到说明边界写成了 `<`");
  assert.equal(got[0]?.tick, 2, "信封里的 tick 是**产生时刻**，不该被延迟改写");
});

test("[传输] 同一条消息只投一次（取走即出队）", () => {
  const [a, b] = createLoopbackPair();
  a.send(intentMsg(1));
  assert.equal(b.receive(1).length, 1);
  assert.equal(b.receive(1).length, 0, "同一拍取了两次却拿到两条 ⇒ 队列没出队，收件方会把同一步走两遍");
  assert.equal(b.receive(100).length, 0, "往后再取也不该再出现");
  assert.equal(b.stats().received, 1);
});

test("[传输] 丢包可复现、可发现：同种子同结果，seq 出现缺口，且后面的不顶替前面的", () => {
  const TOTAL = 300;
  const run = (seed: number): { seqs: number[]; dropped: number; sent: number } => {
    const [a, b] = createLoopbackPair({ lossRate: 0.3, seed });
    for (let i = 0; i < TOTAL; i++) a.send(intentMsg(i));
    const seqs = b.receive(TOTAL).map((m) => m.seq);
    return { seqs, dropped: a.stats().dropped, sent: a.stats().sent };
  };

  const r1 = run(7);
  const r2 = run(7);
  assert.deepEqual(r1.seqs, r2.seqs, "同种子的两次实验必须丢同一批 —— 否则判据不可复现");
  assert.equal(r1.dropped, r2.dropped, "丢弃条数也必须一样");

  assert.ok(r1.dropped > 0, "一条都没丢 ⇒ 这条判据验不到丢包路径（无分辨力）");
  assert.ok(r1.seqs.length > 0, "一条都没到 ⇒ 同样验不到「后面的不顶替前面的」");
  assert.equal(r1.sent + r1.dropped, TOTAL, "发出 + 丢弃必须等于总数（有消息凭空消失或凭空多出来）");

  for (let i = 1; i < r1.seqs.length; i++) {
    assert.ok(
      (r1.seqs[i] ?? -1) > (r1.seqs[i - 1] ?? -1),
      `到达序号必须严格递增，实际 ${String(r1.seqs[i - 1])} → ${String(r1.seqs[i])}（重排或重复）`,
    );
  }
});

test("[传输] 关闭后再发一律失败、在途的也取不到（半关不闭会静默丢世界状态）", () => {
  const [a, b] = createLoopbackPair();
  a.send(intentMsg(1));
  b.dispose();
  assert.equal(a.send(intentMsg(2)), false, "关闭后 send 必须返回 false（本端当场就该知道）");
  assert.equal(b.receive(10).length, 0, "关闭后在途的消息不该再冒出来");
  assert.equal(a.stats().dropped, 1);
  assert.equal(b.stats().queued, 0);
});

test("[传输] 非法配置当场抛，不静默降级（「我设了延迟，判据却在同一拍收到」查起来极贵）", () => {
  assert.throws(() => createLoopbackPair({ delayTicks: -1 }), RangeError);
  assert.throws(() => createLoopbackPair({ delayTicks: 1.5 }), RangeError);
  assert.throws(() => createLoopbackPair({ lossRate: 1.5 }), RangeError);
  assert.throws(() => createLoopbackPair({ lossRate: Number.NaN }), RangeError);
});

/**
 * ★★ 本批最要紧的一条：**同一份代码走环回，表现与单机一致**。
 *
 * 左侧是单机（`stepOf`：输入快照 → 位移，玩家控制器每 tick 走的就是它）；
 * 右侧是联机（客户端把输入变成**意图**、过网、主机用 `dirStep` 执行）。
 * 两条路逐 tick 位置逐字节相等，才说明「换成网络之后玩法没变」——
 * 这正是 P2 要的验收标准，也是后面「预测 / 回滚」能被验证的前提。
 */
test("[传输] ★ 同一串输入过环回（0 延迟）与单机逐 tick 逐字节一致", () => {
  const TICKS = 24;
  const reg = new ComponentRegistry();

  // ---- 单机：一步一算
  const solo = new Scene("单机", reg);
  const soloNode = solo.spawnImmediate("主角");
  solo.flush();

  // ---- 联机：客户端出意图，主机执行
  const host = new Scene("主机", reg);
  const hostNode = host.spawnImmediate("主角");
  host.flush();
  const [client, server] = createLoopbackPair();

  for (let t = 0; t < TICKS; t++) {
    // 单机
    const s = stepOf(snapOf(keysAt(t)), SPEED, DT);
    const p0 = soloNode.localPosition;
    soloNode.setLocalPosition(p0.x + s.dx, p0.y + s.dz);

    // 联机（同一条输入，走「意图 → 过网 → 执行」）
    assert.equal(client.send(intentMsg(t)), true);
    for (const m of server.receive(t)) {
      assert.equal(m.kind, "intent");
      if (m.kind !== "intent") continue;
      const r = dirStep(m.intent, SPEED, DT);
      const p1 = hostNode.localPosition;
      hostNode.setLocalPosition(p1.x + r.dx, p1.y + r.dz);
    }

    assert.equal(
      pos(hostNode.localPosition),
      pos(soloNode.localPosition),
      `第 ${String(t)} 拍：过网后的位置与单机不一致 —— 网络这一层改变了玩法`,
    );
  }

  assert.notEqual(pos(soloNode.localPosition), "0,0", "24 拍一步没走 ⇒ 上面的『一致』是同义反复");
});

test("[传输] 延迟 3 拍只是「晚到」：第 t 拍的主机位置 = 单机第 t−3 拍的位置，追平后终态相同", () => {
  const TICKS = 24;
  const DELAY = 3;
  const reg = new ComponentRegistry();

  const solo = new Scene("单机", reg);
  const soloNode = solo.spawnImmediate("主角");
  solo.flush();
  const trail: string[] = [];
  for (let t = 0; t < TICKS; t++) {
    const s = stepOf(snapOf(keysAt(t)), SPEED, DT);
    const p = soloNode.localPosition;
    soloNode.setLocalPosition(p.x + s.dx, p.y + s.dz);
    trail.push(pos(soloNode.localPosition));
  }

  const host = new Scene("主机", reg);
  const hostNode = host.spawnImmediate("主角");
  host.flush();
  const [client, server] = createLoopbackPair({ delayTicks: DELAY });
  for (let t = 0; t < TICKS; t++) client.send(intentMsg(t));

  let applied = 0;
  for (let t = 0; t < TICKS + DELAY; t++) {
    for (const m of server.receive(t)) {
      if (m.kind !== "intent") continue;
      const r = dirStep(m.intent, SPEED, DT);
      const p = hostNode.localPosition;
      hostNode.setLocalPosition(p.x + r.dx, p.y + r.dz);
      applied++;
      // 第 t 拍执行的是第 t−DELAY 拍的意图 ⇒ 追平后必须落在单机第 t−DELAY 拍的位置上
      const expect = trail[t - DELAY];
      if (expect !== undefined) {
        assert.equal(pos(hostNode.localPosition), expect, `第 ${String(t)} 拍追平失败：延迟改的不该是结果`);
      }
    }
  }

  assert.equal(applied, TICKS, `应用了 ${String(applied)} 步，期望 ${String(TICKS)} 步（延迟不该吞掉步骤）`);
  assert.equal(
    pos(hostNode.localPosition),
    trail[trail.length - 1],
    "追平后的终态必须与单机一致",
  );
});

test("[传输] 快照消息过环回之后能原样还原世界（回传方向也走同一条线）", () => {
  const reg = new ComponentRegistry();
  const host = new Scene("主机", reg);
  const n = host.spawnImmediate("甲");
  host.flush();
  n.setLocalPosition(3.5, -1.25);

  const [a, b] = createLoopbackPair({ delayTicks: 1 });
  a.send({ kind: "snapshot", from: 0, tick: 4, seq: 0, json: sceneToJson(saveScene(host)) });

  assert.equal(b.receive(4).length, 0, "延迟 1 拍，第 4 拍不该到");
  const got = b.receive(5);
  assert.equal(got.length, 1);
  const msg = got[0];
  assert.ok(msg !== undefined && msg.kind === "snapshot");
  if (msg === undefined || msg.kind !== "snapshot") return;

  const parsed = sceneFromJson(msg.json);
  assert.equal(parsed.ok, true, "过了环回的 JSON 自己解析不回来");
  if (!parsed.ok) return;
  const client = new Scene("客户端", reg);
  const loaded = loadScene(client, parsed.value, reg);
  assert.equal(loaded.ok, true);

  const same = client.find(n.id);
  assert.ok(same !== undefined, "还原后节点丢了（id 没跟着走）");
  assert.equal(pos(same.localPosition), "3.5,-1.25", "还原后的位置不对 —— 快照过网损坏了");
});

test("[传输] ★ 信封的 from 由端点在发送时盖章：自称 from: 0 冒充不了主机", () => {
  // ★ 这条不是洁癖：会话层的**全部**授权都是 `owner(entity) === msg.from`
  //   （见 `net/session.ts` 的 `admit`）。如果 `from` 采信发送方写进去的值，
  //   一个客户端只要在消息里填 `from: 0` 就能驱动主机自己的角色，而世界一致性
  //   判据照样全绿（主机确实动了，只是动的人不对）。源地址必须由栈填，不由报文自称。
  const [a, b] = createLoopbackPair();
  a.send({
    kind: "intent",
    from: 99,
    tick: 0,
    seq: 0,
    entity: 1,
    intent: { kind: "move.dir", dx: 1, dz: 0 },
  });
  const got = b.receive(0);
  assert.equal(got.length, 1);
  assert.equal(got[0]?.from, 0, "端点 0 发出来的消息，from 必须是 0 —— 而不是发送方自称的 99");
});
