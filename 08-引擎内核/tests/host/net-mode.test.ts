/**
 * L6 · 联机模式的决策（`host/net-mode.ts`）
 *
 * 为什么这一层值得单独测：它是「URL 参数 → 游戏行为」这条链上**唯一有判断**的地方。
 * 参数写错（`?net=cleint`）时页面照常能玩（退回单机），两端的日志都说"一切正常"；
 * 「本机玩家是谁」错成"第一个找到的"时，拥有多个角色的人会控制错那个，
 * 而单机下永远只有一个角色 ⇒ 真机上测不出来。两种症状都不指向原因。
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
    assert.equal(m.assumedSeat, null);
    assert.equal(m.room, "", "单机没有通道，不该给出房间名");
    assert.equal(m.why, "未指定（单机）");
  }
});

test("[联机模式] host / client 各自的端点号，缺省座位号 = 端点号", () => {
  const h = parseNetMode("host");
  assert.equal(h.role, "host");
  assert.equal(h.self, 0);
  assert.equal(h.assumedSeat, 0);
  assert.equal(h.room, DEFAULT_ROOM, "没给房间名时用缺省");

  const c = parseNetMode("client");
  assert.equal(c.role, "client");
  assert.equal(c.self, 1);
  assert.equal(c.assumedSeat, 1);
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

test("[联机模式] ★ 座位号：给了就认，不合法退回端点号并说明（`Number(\"\")` 是 0 这类陷阱）", () => {
  assert.equal(parseNetMode("client", null, "0").assumedSeat, 0);
  assert.equal(parseNetMode("client", null, "7").assumedSeat, 7);
  // 这些都不该被 `Number()` 悄悄接受
  // ★ 必须同时有「位数就不对」（"999"、"1e3"）与「位数对但越界」（"32"、"99"）两类：
  //   只放前者的话，把 `n <= 31` 上界删掉判据照样全绿 —— 因为正则已经把它们挡住了。
  for (const bad of ["", "  ", "1e3", "-1", "abc", "999", "1.5", "32", "99"]) {
    const m = parseNetMode("client", null, bad);
    assert.equal(m.assumedSeat, 1, `座位号「${bad}」该退回端点号 1`);
    if (bad.trim() !== "") assert.match(m.why, /座位号/, `座位号「${bad}」不合法时要说明`);
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

test("[装配决策] 单机：控制器自己驱动、没有座位、没有端点映射（联机代码一行都不经过）", () => {
  const w = planNetWiring(parseNetMode(null));
  assert.equal(w.driveController, true, "单机必须由控制器模块改位置 —— 这条路今天就在跑");
  assert.equal(w.seat, null);
  assert.equal(w.playerOf, null, "没有座位表就交 null，而不是一个恒等函数（后者会让 Session 以为有人管座位）");
});

test("[装配决策] 联机：控制器**只 poll 不落位**，座位与端点映射都给出来", () => {
  for (const [role, seat] of [["host", 0], ["client", 1]] as const) {
    const w = planNetWiring(parseNetMode(role));
    assert.equal(w.driveController, false, `${role}：位置该由会话管，控制器再改一次就是每拍走两步`);
    assert.equal(w.seat, seat);
    assert.ok(w.playerOf !== null);
    assert.equal(w.playerOf(0), seat, "demo 里只有一个角色：任何端点都映射到同一个座位");
    assert.equal(w.playerOf(1), seat);
  }
});

test("[装配决策] ★ `?seat=` 可以覆盖座位 —— 双窗口同控一个角色的那条路", () => {
  const w = planNetWiring(parseNetMode("client", null, "0"));
  assert.equal(w.seat, 0, "客户端声明自己是 0 号座位");
  assert.equal(w.playerOf?.(1), 0, "于是主机端收到的意图也能落到 0 号座位上");
  assert.equal(w.mode.self, 1, "但端点号仍是 1 —— 座位与端点没有合并");
});
