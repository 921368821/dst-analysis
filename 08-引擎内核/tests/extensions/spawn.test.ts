/**
 * L4 · 出生落地测试（`pickSpawn` → 场景里的玩家节点）
 *
 * `worldgen.test.ts` 验"哪一格最适合开局"（纯函数）；本文件验"玩家真的站在那一格上"。
 * 分开的理由：**选错格** 与 **落地错位** 是两种失效，而且第二种的判据必须核对坐标，
 * 不能只看"有个叫 player 的节点"。
 *
 * ★ 坐标用**定点恒等式**判：`position.x * 256 === cell * 256 + 128`。
 *   256 是 2 的幂，除法无舍入，所以这是恒等式而不是"近似相等"—— 写成
 *   `Math.abs(a-b) < 0.001` 的判据抓不住"差半格"这类错（0.5 太大反而会红，
 *   但差 1/256 的真实 bug 会被容差吃掉）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { FIXED_UNITS, generateWorld, isPassable, pickSpawn, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import {
  PLAYER_FRAME,
  PLAYER_SCHEMA,
  PLAYER_TYPE,
  SPAWN_ALREADY_SPAWNED,
  SPAWN_NO_CONTROLLER_COMPONENT,
  SPAWN_NO_SPRITE_COMPONENT,
  PlayerSpawn,
  registerPlayerComponents,
  spawnPlayer,
} from "../../src/extensions/worldgen/spawn.ts";
import { CONTROLLER_TYPE } from "../../src/extensions/input/player-controller.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";

function makeWorld(seed = 7, width = 32, height = 24): { scene: Scene; plan: WorldPlan } {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerPlayerComponents(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed, width, height, maxSitesPerCell: 1 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  const a = assembleWorld(g.value, scene);
  assert.ok(a.ok, a.ok ? "" : `装配失败：${a.error.code} ${a.error.message}`);
  return { scene, plan: g.value };
}

test("★ 玩家真的站在出生点上：坐标 = 格子中心，且 × 256 是整数（定点恒等式）", () => {
  const { scene, plan } = makeWorld();
  const r = spawnPlayer(scene, plan);
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);

  const node = scene.find(r.value.nodeId);
  assert.ok(node !== undefined, "节点不在场景索引里");
  const cx = r.value.cell % plan.width;
  const cz = (r.value.cell - cx) / plan.width;
  assert.equal(node.localPosition.x * FIXED_UNITS, cx * FIXED_UNITS + FIXED_UNITS / 2, "x 不是格子中心");
  assert.equal(node.localPosition.y * FIXED_UNITS, cz * FIXED_UNITS + FIXED_UNITS / 2, "z 不是格子中心");
  assert.ok(Number.isInteger(node.localPosition.x * FIXED_UNITS), "定点坐标不是整数 —— 存档往返会漂");
});

test("出生点就是 `pickSpawn` 选的格（不是「第一个可通行格」）", () => {
  const { scene, plan } = makeWorld();
  const want = pickSpawn(plan);
  assert.ok(want.ok);
  const r = spawnPlayer(scene, plan);
  assert.ok(r.ok);
  assert.equal(r.value.cell, want.value.cell);
  assert.equal(r.value.x, want.value.x);
  assert.equal(r.value.z, want.value.z);
});

test("出生格可通行、在主大陆上（走不到的小岛上开局等于白开）", () => {
  const { scene, plan } = makeWorld();
  const r = spawnPlayer(scene, plan);
  assert.ok(r.ok);
  assert.ok(isPassable(plan.kinds[r.value.cell]!), `出生格是 ${plan.kinds[r.value.cell]}`);
});

test("玩家节点挂了三样东西：`render.sprite`（帧 player、脚踩地面）· `world.player`（带出生格）· `game.controller`", () => {
  const { scene, plan } = makeWorld();
  const r = spawnPlayer(scene, plan);
  assert.ok(r.ok);
  const node = scene.find(r.value.nodeId)!;

  const sp = node.get<Sprite>(SPRITE_TYPE);
  assert.ok(sp !== undefined, "玩家没有身体 —— 画面上什么都看不到");
  assert.equal(sp.frame, PLAYER_FRAME);
  assert.equal(sp.pivotY, 0, "pivotY 不是 0 —— 玩家会浮在半空");
  assert.equal(sp.width, 1);
  assert.equal(sp.height, 1);

  const marker = node.get<PlayerSpawn>(PLAYER_TYPE);
  assert.ok(marker !== undefined, "没有 world.player 标记 —— 其它系统找不到玩家");
  assert.equal(marker.cell, r.value.cell, "标记里的出生格与返回的值不一致");
});

test("★ 重复出生报 SPAWN.ALREADY_SPAWNED，且不会多出一个玩家节点", () => {
  const { scene, plan } = makeWorld();
  const first = spawnPlayer(scene, plan);
  assert.ok(first.ok);
  const count = scene.countOf(PLAYER_TYPE);

  const second = spawnPlayer(scene, plan);
  assert.ok(!second.ok);
  if (second.ok) return;
  assert.equal(second.error.code, SPAWN_ALREADY_SPAWNED);
  assert.equal(scene.countOf(PLAYER_TYPE), count, "报错的同时又建了一个玩家节点");
});

test("组件没注册 ⇒ 报错且不建节点（不静默造一个「看不见的玩家」）", () => {
  // 情形一：没有 render.sprite
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerPlayerComponents(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed: 7, width: 16, height: 12 });
  assert.ok(g.ok);
  assert.ok(assembleWorld(g.value, scene).ok);
  const r1 = spawnPlayer(scene, g.value);
  assert.ok(!r1.ok);
  if (!r1.ok) assert.equal(r1.error.code, SPAWN_NO_SPRITE_COMPONENT);

  // 情形二：没有 world.player
  const reg2 = new ComponentRegistry();
  registerWorldComponents(reg2);
  reg2.register(new Sprite().schema, () => new Sprite());
  const scene2 = new Scene("world", reg2);
  assert.ok(assembleWorld(g.value, scene2).ok);
  const r2 = spawnPlayer(scene2, g.value);
  assert.ok(!r2.ok);
  if (!r2.ok) {
    assert.equal(r2.error.code, SPAWN_NO_SPRITE_COMPONENT);
    assert.match(r2.error.message, /world\.player/);
  }
  assert.equal(scene2.countOf(SPRITE_TYPE), 0, "报错之后还是留下了节点");
});

test("确定性：两张独立装配的场景里，玩家节点 id / 名字 / 出生格完全相同", () => {
  const a = makeWorld(11, 24, 18);
  const b = makeWorld(11, 24, 18);
  const ra = spawnPlayer(a.scene, a.plan);
  const rb = spawnPlayer(b.scene, b.plan);
  assert.ok(ra.ok && rb.ok);
  if (!ra.ok || !rb.ok) return;
  assert.equal(ra.value.nodeId, rb.value.nodeId, "节点 id 依赖了执行历史");
  assert.equal(a.scene.find(ra.value.nodeId)!.name, b.scene.find(rb.value.nodeId)!.name);
  assert.equal(ra.value.cell, rb.value.cell);
});

/**
 * ★★ 批88：玩家身上**必须**挂着控制器。
 *
 * 这一条打的是一个整整漏掉的接线：`createControllerModule` 两个宿主都装了、都每 tick
 * 驱动，但 `src/` 里没有任何一处 attach `game.controller` ⇒ `driven` 恒为 0 ⇒
 * 按 WASD 谁也不动。而 `player-controller.test.ts` 是绿的（它自己造了带控制器的节点）。
 * **模块单测证不到接线**，所以这条必须落在"造玩家的那个函数"上。
 */
test("★★ 玩家节点上真的挂着控制器（不是只挂了个标记）", () => {
  const { scene, plan } = makeWorld();
  const r = spawnPlayer(scene, plan);
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  if (!r.ok) return;

  assert.equal(scene.countOf(CONTROLLER_TYPE), 1, "场景里没有控制器 —— 按 WASD 玩家不会动");
  const node = scene.find(r.value.nodeId);
  assert.ok(node !== undefined);
  const types = node.components.map((c) => c.type);
  assert.ok(types.includes(CONTROLLER_TYPE), `玩家节点上没挂 ${CONTROLLER_TYPE}（现有：${types.join(",")}）`);
});

/** 情形三：控制器没注册 ⇒ 报错。造一个走不动的木桩比报错更糟（看起来能玩）。 */
test("★ 没有 game.controller 注册 ⇒ 报 SPAWN.NO_CONTROLLER_COMPONENT", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  // 只注册标记，不注册控制器 —— 这正是批88 之前"两个宿主"的真实状态
  reg.register(PLAYER_SCHEMA, () => new PlayerSpawn());
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed: 7, width: 16, height: 12 });
  assert.ok(g.ok);
  assert.ok(assembleWorld(g.value, scene).ok);
  const r = spawnPlayer(scene, g.value);
  assert.ok(!r.ok, "控制器没注册却出生成功了 —— 会得到一个站着不动的玩家");
  if (!r.ok) {
    assert.equal(r.error.code, SPAWN_NO_CONTROLLER_COMPONENT);
    assert.match(r.error.message, /站着不动/);
  }
  assert.equal(scene.countOf(PLAYER_TYPE), 0, "报错之后还是留下了玩家");
});
