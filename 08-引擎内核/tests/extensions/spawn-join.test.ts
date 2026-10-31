/**
 * L4 · 后来加入的玩家：**选一格**（`pickJoinCell`）+ **落在那一格上**（`spawnPlayerAt`）
 *
 * ★ 为什么与 `spawn.test.ts` 分成两个文件：那个文件管的是「开局那一位」——
 *   他要站在"最宽敞"的格子上，而且**只许有一个**（重复出生会让两个控制器抢同一个位置）。
 *   这个文件管的是「后来的人」—— 他要站在"离队友最近"的空格上，而且可以有**很多个**。
 *   两条规则的目标函数相反，写在一起会让人以为它们是同一个东西的两个参数。
 *
 * ★★ 这一批要拆掉的那条捷径，症状恰好落在这里：
 *   批163 的两个窗口同控一个角色，是因为世界里只有**一个**玩家实体，
 *   而两端都把自己当成它的主人。多造一个玩家是「每人一个角色」的前提，
 *   而"造在哪"必须确定性 —— 两个人开局叠在一格里，物理推谁、推多远取决于
 *   体的先后，两台机器算出来不同，世界从第 0 拍就分叉。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import {
  FIXED_UNITS,
  generateWorld,
  isPassable,
  pickJoinCell,
  pickSpawn,
  type WorldPlan,
} from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import {
  PLAYER_TYPE,
  PlayerSpawn,
  SPAWN_ALREADY_SPAWNED,
  SPAWN_CELL_NOT_PASSABLE,
  SPAWN_CELL_OUT_OF_RANGE,
  registerPlayerComponents,
  spawnPlayer,
  spawnPlayerAt,
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

/**
 * 独立的四连通距离（从 `from` 出发、只走可通行格）。
 *
 * ★ 判据里**必须**有一份自己的实现：如果不重算，就只能断言"选出来的那格看起来还行"
 *   —— 那不叫判据。这 15 行是故意写得笨的（不用生成计划里的任何辅助），
 *   于是它与 `pickJoinCell` 唯一的共同点是"四连通 BFS 这个定义"。
 */
function distancesFrom(plan: WorldPlan, from: number): Int32Array {
  const { width, height, kinds } = plan;
  const total = width * height;
  const dist = new Int32Array(total).fill(-1);
  if (from < 0 || from >= total || !isPassable(kinds[from]!)) return dist;
  dist[from] = 0;
  const q = [from];
  for (let head = 0; head < q.length; head++) {
    const cur = q[head]!;
    const cx = cur % width;
    const cz = (cur - cx) / width;
    for (const [ox, oz] of [
      [1, 0],
      [-1, 0],
      [0, 1],
      [0, -1],
    ] as const) {
      const nx = cx + ox;
      const nz = cz + oz;
      if (nx < 0 || nz < 0 || nx >= width || nz >= height) continue;
      const ni = nz * width + nx;
      if (dist[ni] !== -1 || !isPassable(kinds[ni]!)) continue;
      dist[ni] = dist[cur]! + 1;
      q.push(ni);
    }
  }
  return dist;
}

// ---------------------------------------------------------------- 选一格

test("[加入选位] ★ 选中的是**离起点最近**的空格（不是「随便一个空格」，也不是起点自己）", () => {
  const { plan } = makeWorld();
  const origin = pickSpawn(plan);
  assert.ok(origin.ok);
  const cell = pickJoinCell(plan, origin.value.cell);
  assert.ok(cell !== null, "这么大一张图不该找不到落脚点");
  assert.notEqual(cell, origin.value.cell, "不能与起点同格（两人叠在一格里，物理会把世界推开）");
  assert.ok(isPassable(plan.kinds[cell]!), "选出来的格子必须可通行");

  // 独立重算距离：选中的那一格必须达到**全局最小值**。
  const dist = distancesFrom(plan, origin.value.cell);
  const want = dist[cell]!;
  let min = Number.POSITIVE_INFINITY;
  for (let i = 0; i < plan.kinds.length; i++) {
    if (i === origin.value.cell) continue;
    const d = dist[i]!;
    if (d > 0 && d < min) min = d;
  }
  assert.equal(want, min, `选中的格子距离 ${String(want)}，图上的最小值是 ${String(min)}`);
});

test("[加入选位] ★ 已经在用的格子会被跳过（`taken` 不是参考意见，是硬约束）", () => {
  const { plan } = makeWorld();
  const origin = pickSpawn(plan);
  assert.ok(origin.ok);
  const first = pickJoinCell(plan, origin.value.cell);
  assert.ok(first !== null);
  const second = pickJoinCell(plan, origin.value.cell, { taken: [first] });
  assert.ok(second !== null);
  assert.notEqual(second, first, "第二个人不能站在第一个人身上");
  assert.ok(isPassable(plan.kinds[second]!));

  // 距离仍然是最小的那份（在排除了 first 之后）
  const dist = distancesFrom(plan, origin.value.cell);
  let min = Number.POSITIVE_INFINITY;
  for (let i = 0; i < plan.kinds.length; i++) {
    if (i === origin.value.cell || i === first) continue;
    const d = dist[i]!;
    if (d > 0 && d < min) min = d;
  }
  assert.equal(dist[second]!, min);
});

test("[加入选位] 平局取**格号最小**的那个（不写死的话结果取决于遍历顺序 —— 同种子换一个世界）", () => {
  // ★ 为什么这条必须单独立一个：注释里写着「平局取小下标」，但"最近"那条判据
  //   只断言**距离**等于最小值 —— 平局的几个格子距离全都一样，改坏平局规则它照样绿。
  //   规则写在注释里而没有判据 = 没有这条规则（批98 M480 的教训：顺序类 bug 只在
  //   **内容**层可分辨，计数与距离全对）。
  const { plan } = makeWorld();
  const origin = pickSpawn(plan);
  assert.ok(origin.ok);
  const cell = pickJoinCell(plan, origin.value.cell);
  assert.ok(cell !== null);

  const dist = distancesFrom(plan, origin.value.cell);
  let min = Number.POSITIVE_INFINITY;
  for (let i = 0; i < plan.kinds.length; i++) {
    if (i === origin.value.cell) continue;
    const d = dist[i]!;
    if (d > 0 && d < min) min = d;
  }
  // 独立重算：所有「距离 = 最小值」的格子里格号最小的那一个
  let firstAtMin = -1;
  let ties = 0;
  for (let i = 0; i < plan.kinds.length; i++) {
    if (i === origin.value.cell || dist[i]! !== min) continue;
    ties++;
    if (firstAtMin < 0) firstAtMin = i;
  }
  // ★ 先证这张图**真有平局**：一张只有一个最近格的图里，任何平局规则都能过 ——
  //   那这条判据就恒真了（"把被测逻辑删掉还会绿吗"）。
  assert.ok(ties >= 2, `最小距离的格子只有 ${String(ties)} 个 —— 没有平局，这条判据分辨不了平局规则`);
  assert.equal(cell, firstAtMin, "平局时没有取格号最小的那个（遍历顺序一变，两端算出的世界就不一样）");
});

test("[加入选位] ★ `taken` 的顺序不影响结果（Set 语义；按数组 `includes` 扫会随调用方顺序变）", () => {
  const { plan } = makeWorld();
  const origin = pickSpawn(plan);
  assert.ok(origin.ok);
  const a = pickJoinCell(plan, origin.value.cell, { taken: [origin.value.cell + 1, origin.value.cell + 2] });
  const b = pickJoinCell(plan, origin.value.cell, { taken: [origin.value.cell + 2, origin.value.cell + 1] });
  assert.equal(a, b, "同一组占用格换个顺序就换了答案 —— 那是「同种子不同世界」的入口");
});

test("[加入选位] ★ `free` 谓词被真的用上（树摆在格中心：只看地形会让新玩家生在树里）", () => {
  const { plan } = makeWorld();
  const origin = pickSpawn(plan);
  assert.ok(origin.ok);
  const plain = pickJoinCell(plan, origin.value.cell);
  assert.ok(plain !== null);
  // 让"最近那格"不可站：结果必须换一格，而且不能是起点
  const scoped = pickJoinCell(plan, origin.value.cell, { free: (c) => c !== plain });
  assert.ok(scoped !== null);
  assert.notEqual(scoped, plain, "`free` 说不行的格子还是被选中了");
  assert.notEqual(scoped, origin.value.cell);
});

test("[加入选位] 没地方站 ⇒ null（不能返回一个凑合的格子：那是把人放进海里）", () => {
  const { plan } = makeWorld();
  const origin = pickSpawn(plan);
  assert.ok(origin.ok);
  assert.equal(pickJoinCell(plan, origin.value.cell, { free: () => false }), null);
});

test("[加入选位] 起点非法（越界 / 在海里 / 小数）⇒ null，不抛也不猜", () => {
  const { plan } = makeWorld();
  assert.equal(pickJoinCell(plan, -1), null);
  assert.equal(pickJoinCell(plan, plan.width * plan.height), null);
  assert.equal(pickJoinCell(plan, 1.5), null);
  let sea = -1;
  for (let i = 0; i < plan.kinds.length; i++) {
    if (!isPassable(plan.kinds[i]!)) {
      sea = i;
      break;
    }
  }
  assert.ok(sea >= 0, "这张图上居然一格海都没有");
  assert.equal(pickJoinCell(plan, sea), null);
});

test("[加入选位] 确定性：同一张图、同一组占用，两次算出的格子相同", () => {
  const a = makeWorld(11, 24, 18);
  const b = makeWorld(11, 24, 18);
  const origin = pickSpawn(a.plan);
  assert.ok(origin.ok);
  const taken = [origin.value.cell + 1];
  assert.equal(
    pickJoinCell(a.plan, origin.value.cell, { taken }),
    pickJoinCell(b.plan, origin.value.cell, { taken }),
  );
});

// ---------------------------------------------------------------- 落在格上

test("★ 后来的人落在指定的格子上：坐标 = 格子中心，且三样组件齐全（不是只挂个标记）", () => {
  const { scene, plan } = makeWorld();
  const host = spawnPlayer(scene, plan);
  assert.ok(host.ok);
  const cell = pickJoinCell(plan, host.value.cell);
  assert.ok(cell !== null);

  const r = spawnPlayerAt(scene, plan, { cell, name: "player:1" });
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  const node = scene.find(r.value.nodeId);
  assert.ok(node !== undefined);
  assert.equal(node.name, "player:1", "名字要能把人分开（日志与存档 diff 靠它）");

  const cx = cell % plan.width;
  const cz = (cell - cx) / plan.width;
  assert.equal(node.localPosition.x * FIXED_UNITS, cx * FIXED_UNITS + FIXED_UNITS / 2);
  assert.equal(node.localPosition.y * FIXED_UNITS, cz * FIXED_UNITS + FIXED_UNITS / 2);

  assert.ok(node.get<Sprite>(SPRITE_TYPE) !== undefined, "后来的人没有身体");
  assert.equal(node.get<PlayerSpawn>(PLAYER_TYPE)?.cell, cell);
  assert.ok(node.get(CONTROLLER_TYPE) !== undefined, "后来的人没有控制器 —— 他按 WASD 不会动");
  assert.equal(scene.countOf(PLAYER_TYPE), 2, "世界里应该站着两个人");
});

test("★ `spawnPlayerAt` 允许第二个；`spawnPlayer` 仍然只许一个（两条契约不同，不能合并）", () => {
  const { scene, plan } = makeWorld();
  const a = spawnPlayer(scene, plan);
  assert.ok(a.ok);
  const cell = pickJoinCell(plan, a.value.cell);
  assert.ok(cell !== null);
  assert.ok(spawnPlayerAt(scene, plan, { cell }).ok, "联机玩家必须能加进来");

  // ★ 而"开局那一位"的重复出生仍然是错误 —— 这条与"能不能有第二个人"是两件事。
  const again = spawnPlayer(scene, plan);
  assert.ok(!again.ok);
  if (!again.ok) assert.equal(again.error.code, SPAWN_ALREADY_SPAWNED);
  assert.equal(scene.countOf(PLAYER_TYPE), 2, "报错的同时又建了一个玩家节点");
});

test("★ 不可通行的格子 ⇒ 报错且不建节点（站在海里的玩家看起来一切正常）", () => {
  const { scene, plan } = makeWorld();
  let sea = -1;
  for (let i = 0; i < plan.kinds.length; i++) {
    if (!isPassable(plan.kinds[i]!)) {
      sea = i;
      break;
    }
  }
  assert.ok(sea >= 0);
  const before = scene.countOf(PLAYER_TYPE);
  const r = spawnPlayerAt(scene, plan, { cell: sea });
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, SPAWN_CELL_NOT_PASSABLE);
  assert.equal(scene.countOf(PLAYER_TYPE), before, "报错之后还是留下了节点");
});

test("越界 / 非整数的格子 ⇒ 报错且不建节点", () => {
  const { scene, plan } = makeWorld();
  for (const cell of [-1, plan.width * plan.height, 1.5, Number.NaN]) {
    const r = spawnPlayerAt(scene, plan, { cell });
    assert.ok(!r.ok, `格子 ${String(cell)} 该被拒`);
    if (!r.ok) assert.equal(r.error.code, SPAWN_CELL_OUT_OF_RANGE);
  }
  assert.equal(scene.countOf(PLAYER_TYPE), 0);
});

test("★ 组件没注册时，`spawnPlayerAt` 与 `spawnPlayer` 报同一个码（只有一份实现）", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerPlayerComponents(reg);
  // 故意不注册 render.sprite
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed: 7, width: 16, height: 12 });
  assert.ok(g.ok);
  assert.ok(assembleWorld(g.value, scene).ok);
  const one = spawnPlayerAt(scene, g.value, { cell: 0 });
  const two = spawnPlayer(scene, g.value);
  assert.ok(!one.ok && !two.ok);
  if (!one.ok && !two.ok) assert.equal(one.error.code, two.error.code);
  assert.equal(scene.countOf(PLAYER_TYPE), 0);
});
