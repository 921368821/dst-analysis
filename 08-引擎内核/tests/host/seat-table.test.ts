/**
 * L6 · 座位表：`PlayerId` → 场景里的实体（`host/seat-table.ts`）
 *
 * ★ 这一层是「握手」与「世界」之间唯一的连接点，而它出错的方式**全都不报警**：
 *   · 座位坐了、实体没造 ⇒ 客户端进了房，世界里没有他（所有计数都对）；
 *   · 同一座位造了两次 ⇒ 他有个分身站在离开的地方；
 *   · 释放时删了实体 ⇒ "他走了"与"他被打死了"变成同一件事；
 *   · 重连没重写归属 ⇒ 他看得到自己的角色，按键不动（全被 `not-owner` 拒）。
 *   所以每条契约各有一条判据，且都读**世界里的东西**（归属、节点、格子），
 *   不读这一层自己的计数器（自证没有意义）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { generateWorld, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { PLAYER_TYPE, PlayerSpawn, registerPlayerComponents, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { AUTHORITY, ownerOf, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import {
  SEAT_BAD_ID,
  SEAT_NO_IDENTITY,
  SEAT_NO_ROOM,
  countPlayers,
  createSeatTable,
  type SeatTable,
} from "../../src/host/seat-table.ts";

interface World {
  readonly scene: Scene;
  readonly plan: WorldPlan;
  readonly table: SeatTable;
  /** 开局那位（0 号座位，不经过座位表）。 */
  readonly hostNode: number;
  readonly hostCell: number;
}

function makeWorld(opts: { identity?: boolean; free?: (cell: number) => boolean } = {}): World {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerPlayerComponents(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  if (opts.identity !== false) registerNetIdentity(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed: 7, width: 32, height: 24, maxSitesPerCell: 1 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  const plan = g.value;
  assert.ok(assembleWorld(plan, scene).ok);
  const hero = spawnPlayer(scene, plan);
  assert.ok(hero.ok, hero.ok ? "" : `${hero.error.code} ${hero.error.message}`);
  const table = createSeatTable({
    scene,
    plan,
    origin: hero.value.cell,
    ...(opts.free === undefined ? {} : { free: opts.free }),
  });
  return { scene, plan, table, hostNode: hero.value.nodeId, hostCell: hero.value.cell };
}

test("★ 一个座位落成一个实体：世界里多站一个人，他归这个座位，且不在主机的格子上", () => {
  const w = makeWorld();
  const id = w.table.join(1);
  assert.ok(id !== null, `没造出来：${String(w.table.stats().lastError)}`);
  assert.equal(ownerOf(w.scene, id), 1, "归属没写进场景 —— 他的输入会被 `not-owner` 拒掉");
  assert.equal(countPlayers(w.scene), 2, "世界上应该站着两个人（开局那位 + 1 号座位）");

  const mine = w.scene.find(id)?.get<PlayerSpawn>(PLAYER_TYPE);
  assert.ok(mine !== undefined);
  assert.notEqual(mine.cell, w.hostCell, "两个人站在同一格：物理会推开其中一个，而两端推的方向不一定一样");
  assert.equal(w.table.stats().seats, 1);
  assert.equal(w.table.stats().spawned, 1);
});

test("★ 同一个座位第二次 `join` 返回**同一个**实体（重连不该多出一个分身）", () => {
  const w = makeWorld();
  const first = w.table.join(1);
  assert.ok(first !== null);
  const again = w.table.join(1);
  assert.equal(again, first, "重连造了第二个实体 —— 客户端只认 id 最小的那个，另一个永远站在他离开的地方");
  assert.equal(countPlayers(w.scene), 2, "世界里多了一个人");
  assert.equal(w.table.stats().reused, 1);
  assert.equal(w.table.stats().spawned, 1);
});

test("★ 两个座位两个人：各自独立的实体、各自的归属、各自的格子", () => {
  const w = makeWorld();
  const one = w.table.join(1);
  const two = w.table.join(2);
  assert.ok(one !== null && two !== null);
  assert.notEqual(one, two);
  assert.equal(ownerOf(w.scene, one), 1);
  assert.equal(ownerOf(w.scene, two), 2);
  const a = w.scene.find(one)?.get<PlayerSpawn>(PLAYER_TYPE)?.cell;
  const b = w.scene.find(two)?.get<PlayerSpawn>(PLAYER_TYPE)?.cell;
  assert.notEqual(a, b, "两个座位站到了同一格");
  assert.equal(countPlayers(w.scene), 3);
});

test("★ 释放 = 把归属交还权威，**实体留在原地**（他走了，不是他死了）", () => {
  const w = makeWorld();
  const id = w.table.join(1);
  assert.ok(id !== null);
  assert.equal(w.table.release(1), true);
  assert.equal(ownerOf(w.scene, id), AUTHORITY, "超时后归属该回到权威手里（AI/脚本继续演他）");
  assert.ok(w.scene.find(id) !== undefined, "释放把实体删掉了 —— 那让「掉线」与「被打死」变成同一件事");
  assert.equal(countPlayers(w.scene), 2);
  assert.equal(w.table.stats().released, 1);
});

test("★ 释放之后同一个座位再进来：**同一个实体**、归属写回他的座位（重连后你还是你）", () => {
  const w = makeWorld();
  const id = w.table.join(1);
  assert.ok(id !== null);
  const cell = w.scene.find(id)?.get<PlayerSpawn>(PLAYER_TYPE)?.cell;
  w.table.release(1);
  assert.equal(ownerOf(w.scene, id), AUTHORITY);

  const back = w.table.join(1);
  assert.equal(back, id, "重连造了个新实体 —— 他的角色会在世界里瞬移");
  assert.equal(ownerOf(w.scene, id), 1, "归属没写回去：他看得到自己，但按键不动（全被 not-owner 拒）");
  assert.equal(w.scene.find(id)?.get<PlayerSpawn>(PLAYER_TYPE)?.cell, cell, "位置也不该变");
  assert.equal(countPlayers(w.scene), 2, "重连不该多一个人");
});

test("★ 没有 `net.identity` ⇒ 拒绝造人（造出来是一个谁都驱动不了的木桩）", () => {
  const w = makeWorld({ identity: false });
  const id = w.table.join(1);
  assert.equal(id, null);
  assert.equal(w.table.stats().lastError, SEAT_NO_IDENTITY);
  assert.equal(countPlayers(w.scene), 1, "报错的同时还是造了人");
});

test("座位号非法（负数 / 小数 / `AUTHORITY`）⇒ 拒绝，且不占用号", () => {
  const w = makeWorld();
  for (const bad of [-1, 1.5, Number.NaN]) {
    assert.equal(w.table.join(bad), null, `座位 ${String(bad)} 该被拒`);
    assert.equal(w.table.stats().lastError, SEAT_BAD_ID);
  }
  assert.equal(countPlayers(w.scene), 1);
  // 拒绝之后再要一个正常座位，仍然是 1 号实体（坏请求没消耗格子）
  assert.ok(w.table.join(1) !== null);
});

test("没地方站 ⇒ 拒绝并给出 SEAT_NO_ROOM（不能挤在队友身上）", () => {
  const w = makeWorld({ free: () => false });
  assert.equal(w.table.join(1), null);
  assert.equal(w.table.stats().lastError, SEAT_NO_ROOM);
  assert.equal(countPlayers(w.scene), 1);
});

test("★ 实体被别的系统销毁之后，同一个座位会重新造一个（不返回死 id）", () => {
  const w = makeWorld();
  const id = w.table.join(1);
  assert.ok(id !== null);
  w.scene.destroy(id);
  w.scene.flush();
  assert.equal(w.table.entityOf(1), id, "表里还记着旧 id（这是允许的，它只是一个映射）");
  const again = w.table.join(1);
  assert.ok(again !== null, `重新造失败：${String(w.table.stats().lastError)}`);
  assert.notEqual(again, id, "返回了一个已经不存在的节点 id —— 客户端会永远找不到自己的角色");
  assert.equal(ownerOf(w.scene, again), 1);
});
