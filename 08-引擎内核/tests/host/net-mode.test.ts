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
  normalizeWsUrl,
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
  // ★ 这条判据守的是**接口形状**，不是某个分支。
  //
  // ★★ 批169 改过一次：原来它靠"多传第三个参数看它起不起作用"来守 ——
  //   而现在第三个参数是 `wire`（合法的），那个语料再也验不了原意。
  //   改成守形状：`NetMode` 上没有任何"我申报自己是几号"的字段，端点号只由 role 决定。
  //   这比"多传参数无效"更贴近要防的东西 —— `?seat=0` 曾经真的让两个窗口坐进同一个座位，
  //   而它的实现就是"把 URL 里的一个数字直接当端点号"。
  const m = parseNetMode("client");
  assert.equal(m.self, 1, "端点号仍是 1");
  for (const forbidden of ["assumedSeat", "seat", "playerOf"]) {
    assert.equal(Object.hasOwn(m, forbidden), false, `NetMode 上不该有 \`${forbidden}\`：那是一条"我自称我是谁"的路`);
  }
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

// ---------------------------------------------------------------- 批169：链路选择

test("[链路] ★ 缺省是 `bc`：不写 `wire` 时批163~166 的行为一模一样", () => {
  // ★ 这条是「加了新功能不许改老行为」的守卫。缺省换成 `ws` 的话，
  //   两个标签页那套（今天唯一真的能玩的方式）会当场失效 —— 而它的失败方式是
  //   "两个页面都在等一个网关"，页面上只显示"没连上"。
  for (const role of ["host", "client"] as const) {
    const m = parseNetMode(role);
    assert.equal(m.wire, "bc");
    assert.equal(m.url, null);
    // `bc` 下端点号仍是 URL 给的（同机标签页数得清）
    assert.equal(m.self, role === "host" ? 0 : 1);
  }
});

test("★★ `wire=ws` 时 **self 必须是 null**（号由网关给，这里猜一个就是把自报座位号放回来）", () => {
  // ★ 猜错的后果不是"看起来不对"，而是 `Joiner.reply()` 里 `msg.to !== selfPeer`
  //   把每一份合法回复都丢掉：客户端连上了、网关日志说转发了、主机日志说分配了座位，
  //   而客户端上什么也没有。
  for (const role of ["host", "client"] as const) {
    const m = parseNetMode(role, null, "ws", "ws://127.0.0.1:8787");
    assert.equal(m.wire, "ws");
    assert.equal(m.self, null, `${role}：ws 下本端不可能知道自己几号`);
    assert.equal(m.url, "ws://127.0.0.1:8787/");
    assert.equal(m.role, role, "选了链路不该改变角色");
  }
});

test("★★ `wire=ws` 但 url 缺失/非法 ⇒ **退回单机**，而不是退回 bc", () => {
  // ★ 退回 bc 会让"跨机器打不开"变成"同机能玩"，于是参数写错这件事再也看不出来。
  const noUrl = parseNetMode("host", null, "ws", null);
  assert.equal(noUrl.role, "off");
  assert.match(noUrl.why, /没有 url/);

  const httpUrl = parseNetMode("host", null, "ws", "http://127.0.0.1:8787");
  assert.equal(httpUrl.role, "off");
  assert.ok(httpUrl.why.includes("ws:// 或 wss://"), `理由里要说清该填什么，收到：${httpUrl.why}`);

  const junk = parseNetMode("client", null, "ws", "不是地址");
  assert.equal(junk.role, "off");
});

test("★ 不认识的 wire 值退回单机（与 `?net=cleint` 同一条规矩：失败要有理由）", () => {
  const m = parseNetMode("host", null, "websocket", "ws://x/");
  assert.equal(m.role, "off");
  assert.match(m.why, /不认识的 wire「websocket」/);
});

test("★ `normalizeWsUrl`：只认 ws/wss，且归一成带结尾斜杠的形态", () => {
  assert.equal(normalizeWsUrl("ws://a:1"), "ws://a:1/");
  assert.equal(normalizeWsUrl("wss://a/b?x=1"), "wss://a/b?x=1");
  assert.equal(normalizeWsUrl("  ws://a:1  "), "ws://a:1/", "前后空格要吃掉（URL 参数常带）");
  assert.equal(normalizeWsUrl("http://a/"), null);
  // ★ 注意 `ws:/a` **不是**"缺主机名"：WHATWG 会把特殊协议规范化成 `ws://a/`。
  //   真正没有主机的是 `ws://` —— 它直接抛。
  assert.equal(normalizeWsUrl("ws://"), null, "没有主机名的不算");
  assert.equal(normalizeWsUrl(""), null);
  assert.equal(normalizeWsUrl(null), null);
  // ★ IPv6 字面量：自己写正则的那一天就是"局域网能用、IPv6 不能用"的那一天
  assert.equal(normalizeWsUrl("ws://[::1]:8787"), "ws://[::1]:8787/");
});
