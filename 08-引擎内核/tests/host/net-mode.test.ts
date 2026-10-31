/**
 * L6 · 联机模式的决策（`host/net-mode.ts`）
 *
 * 为什么这一层值得单独测：它是「URL 参数 → 游戏行为」这条链上**唯一有判断**的地方。
 * 参数写错（`?net=cleint`）时页面照常能玩（退回单机），两端的日志都说"一切正常"；
 * 「本机玩家是谁」错成"第一个找到的"时，拥有多个角色的人会控制错那个，
 * 而单机下永远只有一个角色 ⇒ 真机上测不出来。两种症状都不指向原因。
 *
 * ★ 批164 起，这一层**不再回答"我是几号座位"**：座位由握手分配（`net/join.ts` 的
 *   `Room`），宿主只能等。于是本文件里两条判据变成了「这个字段必须**不存在**」
 *   （`assumedSeat` / `playerOf`）—— 它们钉的是那条被拆掉的捷径的形状。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { NetIdentity, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import {
  DEFAULT_ROOM,
  localDriveOf,
  parseNetMode,
  pickLocalEntity,
  planNetWiring,
} from "../../src/host/net-mode.ts";

function world(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  registerNetIdentity(reg);
  return { scene: new Scene("main", reg), reg };
}

function spawnOwned(w: { scene: Scene }, owner: number, id: number): number {
  const n = w.scene.spawnImmediate("player", w.scene.rootId, id);
  w.scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  w.scene.flush();
  return n.id;
}

test("[联机模式] 不带参数 / 空值 / 显式 off 都落到单机，且理由是「未指定」", () => {
  for (const p of [null, undefined, "", "  ", "off", "OFF", "0"]) {
    const m = parseNetMode(p);
    assert.equal(m.role, "off", `参数 ${String(p)} 该落到 off`);
    assert.equal(m.self, null);
    assert.equal(m.room, "", "单机没有通道，不该给出房间名");
    assert.equal(m.why, "未指定（单机）");
  }
});

test("[联机模式] host / client 各自的端点号；**没有座位号这个东西**了（座位由握手分配）", () => {
  const h = parseNetMode("host");
  assert.equal(h.role, "host");
  assert.equal(h.self, 0);
  assert.equal(h.room, DEFAULT_ROOM, "没给房间名时用缺省");

  const c = parseNetMode("client");
  assert.equal(c.role, "client");
  assert.equal(c.self, 1);
  // ★ 批164：`assumedSeat` 删掉了。用「对象上没有这个键」钉住 ——
  //   留着这个字段的代价是「宿主可以自称座位」，而那正是这一批拆掉的捷径。
  assert.equal(Object.hasOwn(c, "assumedSeat"), false, "NetMode 里不该再有座位号：它只能由握手给");
  assert.equal(Object.hasOwn(h, "assumedSeat"), false);
});

test("[联机模式] ★ 大小写与空格被吃掉（?NET=HOST 也算 host）", () => {
  assert.equal(parseNetMode(" HOST ").role, "host");
  assert.equal(parseNetMode("Client").role, "client");
});

test("[联机模式] ★ 不认识的值退回单机，但**理由里必须写着它**（静默回退的症状是「我明明加了参数」）", () => {
  const m = parseNetMode("cleint");
  assert.equal(m.role, "off");
  assert.match(m.why, /cleint/, "理由里要出现那个拼错的值");
  assert.match(m.why, /退回单机/);
});

test("[联机模式] 房间名：合法就用，不合法退回缺省并在理由里说明", () => {
  assert.equal(parseNetMode("host", "room-1").room, "room-1");
  // 空串 = 没指定（与 `?tree=` 同一条归一规则），不是"换成一个空房间"
  assert.equal(parseNetMode("host", "").room, DEFAULT_ROOM);
  const bad = parseNetMode("host", "有 空格 和 中文");
  assert.equal(bad.room, DEFAULT_ROOM);
  assert.match(bad.why, /不合法/);
});

test("[联机模式] ★ `?seat=` 那条路整个不存在了（宿主不许申报座位号）", () => {
  // ★ 这条判据守的是**接口形状**，不是某个分支：`parseNetMode` 的第三个参数被删掉之后，
  //   多传进来的东西必须完全不起作用（JS 里多传的参数本来就会被忽略）。
  //   如果哪天有人把它加回去，这两个断言会同时红。
  // ★ 为了能"按老签名调用一次"，这里显式放宽成 `unknown[]` —— 平时的调用点
  //   靠 tsc 就挡住了第三个参数，这条判据管的是**运行期**（`?seat=0` 曾经真的
  //   让两个窗口坐进同一个座位）。
  const loose = parseNetMode as unknown as (...args: unknown[]) => ReturnType<typeof parseNetMode>;
  const m = loose("client", null, "0");
  assert.equal(m.self, 1, "端点号仍是 1");
  assert.equal(Object.hasOwn(m, "assumedSeat"), false, "第三个参数不该变出一个座位号");
});

test("[联机模式] 谁驱动本地玩家：单机给控制器模块，联机给会话", () => {
  assert.equal(localDriveOf("off"), "controller");
  assert.equal(localDriveOf("host"), "session");
  assert.equal(localDriveOf("client"), "session");
});

test("[联机模式] ★ 本机玩家取 id **最小**的那个，不是「第一个找到的」", () => {
  const w = world();
  // ★ 先 spawn id 大的、再 spawn id 小的：组件表里 302 在前。
  //   如果实现是"取第一个找到的"，它拿到的是 302，而正确答案是 301。
  // ★ 这条判据的**承重墙是 `ownedBy` 的升序契约**（`net-identity.test.ts` 钉住它）：
  //   第一版在这里写 `id < best` 的扫描是第二份实现，删掉它这条判据照样绿 ——
  //   所以扫描已经删了，最小值只剩一处。
  spawnOwned(w, 1, 302);
  spawnOwned(w, 1, 301);
  spawnOwned(w, 0, 300);

  assert.equal(pickLocalEntity(w.scene, 1), 301, "同一个玩家有两个实体时，取 id 最小的");
  assert.equal(pickLocalEntity(w.scene, 0), 300);
});

test("[联机模式] 没有座位 / 座位下没有实体 ⇒ null（不是 -1、不是第一个碰到的）", () => {
  const w = world();
  spawnOwned(w, 0, 300);
  assert.equal(pickLocalEntity(w.scene, null), null, "没有座位时不该猜");
  assert.equal(pickLocalEntity(w.scene, 5), null);
});

test("[联机模式] 实体被销毁之后不再返回它（快照整场替换时这条是常态）", () => {
  const w = world();
  const id = spawnOwned(w, 1, 401);
  assert.equal(pickLocalEntity(w.scene, 1), 401);
  w.scene.destroy(id);
  w.scene.flush();
  assert.equal(pickLocalEntity(w.scene, 1), null);
});

// ---------------------------------------------------------------- 装配决策

test("[装配决策] 单机：控制器自己驱动（联机代码一行都不经过）", () => {
  const w = planNetWiring(parseNetMode(null));
  assert.equal(w.driveController, true, "单机必须由控制器模块改位置 —— 这条路今天就在跑");
  assert.equal(w.mode.role, "off");
});

test("[装配决策] 联机：控制器**只 poll 不落位**（位置归会话，否则每拍走两步）", () => {
  for (const role of ["host", "client"] as const) {
    const w = planNetWiring(parseNetMode(role));
    assert.equal(w.driveController, false, `${role}：位置该由会话管，控制器再改一次就是每拍走两步`);
    assert.equal(w.mode.role, role);
  }
});

test("[装配决策] ★ 这一层不再产出座位映射：它是运行期才知道的东西", () => {
  // ★ 批163 的 `playerOf: () => seat` 是"任何端点都算同一个座位"那条捷径的实现。
  //   它的形状错得很具体：**URL 解析那一刻算出来的常量**，而座位表是运行期才有的。
  //   这条判据钉住"这一层不产出它"，于是捷径不可能从返回值的形状里悄悄回来。
  const w = planNetWiring(parseNetMode("client"));
  assert.equal(Object.hasOwn(w, "playerOf"), false);
  assert.equal(Object.hasOwn(w, "seat"), false);
});
