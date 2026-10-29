/**
 * L4 · 生物碰撞：**会动的东西也能挡路**（C18 动态障碍，批124）
 *
 * ★ 这条文件要守的不是"物理算得对"（那是 `physics-*.test.ts` 的事），而是
 *   **接缝**：生物真的有体、体是动态的、被推开之后还能接着走、死后体跟着没。
 *   这四件事里任何一件漏掉，画面外的数字都照样自洽 ——
 *   只有在这种"模块拼起来"的层次上才看得见。
 *
 * ★★ 三条最容易写成假绿的：
 *   ① 只断言"生物位置变了"：**没有体也会变**（AI 自己在走）。所以每条判据都要
 *      **同时**读两个量：该被推的推了 ∧ 不该动的一动没动（树 / 别人）。
 *   ② 只断言 `has(id) === true`："体在"与"体会跟着节点走"是两件事。
 *   ③ 只断言"死后 `has` 是 false"：删掉整段 `prune` 里的撤体逻辑当然也 false ——
 *      如果那条判据跑在**根本不加体**的夹具上。所以每条都先证"加过"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { registerCorpseComponent } from "../../src/extensions/combat/corpse.ts";
import { SpatialHashWorld, makeSceneAccessor } from "../../src/extensions/physics/physics.ts";
import { createMobWorldModule, type MobWorldHandle } from "../../src/extensions/mobs/mob-world.ts";

const RABBIT = {
  kind: "rabbit",
  frame: "rabbit",
  width: 0.8,
  height: 0.8,
  radius: 0.3,
  maxHp: 2,
  damage: 0,
  range: 1.4,
  cooldownTicks: 20,
  speed: 0.6,
  team: "prey",
  loot: [],
};

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  registerInventoryComponents(reg);
  registerCorpseComponent(reg);
  registerLootComponent(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return new Scene("mob-collision", reg);
}

function makeCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: {
      channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }),
    } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  } as unknown as ModuleContext;
}

/** 物理世界：位置访问器指向**场景节点**（与宿主同一个接法）。 */
function mkPhysics(scene: Scene): SpatialHashWorld {
  return new SpatialHashWorld(
    makeSceneAccessor((id) => {
      const n = scene.find(id);
      if (n === undefined) return undefined;
      return {
        id: n.id,
        worldPosition: () => n.worldPosition,
        setLocalPosition: (x: number, y: number) => n.setLocalPosition(x, y),
      };
    }),
  );
}

function realWorld(seed: number, n: number): { grid: NavGrid; cells: number[] } {
  const g = generateWorld({ seed, width: 22, height: 16, maxSitesPerCell: 0 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  const gr = NavGrid.fromPlan(g.value);
  assert.equal(gr.ok, true);
  if (!gr.ok) throw new Error("unreachable");
  const grid = gr.value;
  const cells: number[] = [];
  for (let i = 0; i < grid.total && cells.length < n; i++) if (grid.isWalkableIndex(i)) cells.push(i);
  assert.ok(cells.length >= n, `世界里要有至少 ${String(n)} 个可走格`);
  return { grid, cells };
}

function mkFactions() {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
}

/** 一棵"树"：场景节点 + 静态体（半径 0.55，与演示一致）。 */
function mkTree(scene: Scene, physics: SpatialHashWorld, x: number, z: number): number {
  const r = scene.spawnAt("tree", x, z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  scene.flush();
  physics.add({ nodeId: r.value.id, radius: 0.55, isStatic: true });
  return r.value.id;
}

function mobModule(scene: Scene, grid: NavGrid, cells: readonly number[], physics?: SpatialHashWorld): MobWorldHandle {
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT],
    spots: cells.map((cell) => ({ template: 0, cell })),
    range: 12,
    seed: 5,
    wanderEvery: 6,
    ...(physics === undefined ? {} : { physics }),
  });
  const r = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
  // ★ 物理体是**第一次 `update` 补齐**的（`syncBodies`，见 `mob-world.ts`）：
  //   init 期间组合根还读不到场景，`physics.add` 会因为"没有位置"直接抛。
  //   不推进这一拍的话，下面每条判据都在验"体还没加上"那一刻 —— 全绿成假象。
  if (physics !== undefined) mod.update(0, 1 / 30);
  return mod;
}

function posOf(scene: Scene, id: number): { x: number; z: number } {
  const n = scene.find(id);
  assert.notEqual(n, undefined, `节点 ${String(id)} 不在了`);
  if (n === undefined) throw new Error("unreachable");
  return { x: n.worldPosition.x, z: n.worldPosition.y };
}

test("[生物·碰撞] 给了物理世界 ⇒ 每只都有体；不给 ⇒ 一只都没有（老行为原样）", () => {
  const withP = mkScene();
  const w1 = realWorld(4242, 3);
  const p = mkPhysics(withP);
  const m1 = mobModule(withP, w1.grid, w1.cells, p);
  assert.equal(m1.stats.bodies, 3, "三只生物就该有三个体");
  assert.equal(m1.stats.mobs, 3);
  for (const id of m1.nodeIds) assert.equal(p.has(id), true, `${String(id)} 应该有体`);

  // ★ 对照：不传 physics —— 老行为，一只体都没有（这条是"默认值没悄悄接管"的证据）
  const noP = mkScene();
  const w2 = realWorld(4242, 3);
  const m2 = mobModule(noP, w2.grid, w2.cells);
  assert.equal(m2.stats.bodies, 0);
  assert.equal(m2.stats.bodiesRemoved, 0);
});

test("★★ 树压在生物身上：解算把**生物**顶出去，而树一动没动", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(9001, 2);
  const physics = mkPhysics(scene);
  const mod = mobModule(scene, grid, [cells[0]!], physics);
  const id = mod.nodeIds[0]!;
  const start = posOf(scene, id);

  const treeId = mkTree(scene, physics, start.x, start.z);
  physics.resolve();

  const after = posOf(scene, id);
  const d = Math.hypot(after.x - start.x, after.z - start.z);
  // 接触距离 = 0.55（树）+ 0.3（兔子）= 0.85；解算留 skin=0.001，取 0.02 的余量
  assert.ok(d >= 0.85 - 0.02, `生物该被顶到接触面外，实际只挪了 ${d.toFixed(3)}`);
  // ★ 第二个观测量：静态体不该被推走（推走的话"树会漂"——比穿模更难发现）
  const tp = posOf(scene, treeId);
  assert.equal(tp.x, start.x, "树被推动了（静态体不该动）");
  assert.equal(tp.z, start.z, "树被推动了（静态体不该动）");
});

test("★★ 同一份夹具不传 physics ⇒ 树穿了它也不动（证明上一条的差异来自物理体）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(9001, 1);
  const physics = mkPhysics(scene);
  const mod = mobModule(scene, grid, [cells[0]!]);
  const id = mod.nodeIds[0]!;
  const start = posOf(scene, id);
  mkTree(scene, physics, start.x, start.z);
  physics.resolve();
  const after = posOf(scene, id);
  assert.equal(after.x, start.x, "没有体就不该被推 —— 这条红了说明上一条验的不是体");
  assert.equal(after.z, start.z);
});

test("★★★ 生物死后物理体必须撤掉（不撤 = 原地一堵看不见的墙）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(777, 2);
  const physics = mkPhysics(scene);
  const mod = mobModule(scene, grid, cells, physics);
  const [a, b] = mod.nodeIds;
  assert.notEqual(a, undefined);
  assert.notEqual(b, undefined);
  if (a === undefined || b === undefined) throw new Error("unreachable");
  assert.equal(physics.has(a), true, "前提：活着的时候有体");

  scene.destroy(a);
  scene.flush();
  // ★ 前提要单独证：**销毁节点本身不会动物理体**（这是"必须有 prune 撤体"的理由）。
  //   没有这一句的话，把撤体逻辑删掉、恰好在别处有 remove，判据也会绿。
  assert.equal(physics.has(a), true, "前提：节点没了，体还挂着");

  mod.update(0, 1 / 30);
  assert.equal(physics.has(a), false, "prune 必须把死者的体撤掉");
  assert.equal(physics.has(b), true, "别人的体不许被误删");
  assert.equal(mod.stats.bodiesRemoved, 1);
  assert.equal(mod.stats.bodies, 1, "活着的还有一只");
  // 那块地现在应该真的空了（查询半径 0.01 只可能命中"就在那一点"的体）
  const at = posOf(scene, b);
  assert.equal(physics.query(at.x, at.z, 0.01).includes(a), false);
});

test("★★ 外部清表（读档）之后 `resyncBodies` **当场**补齐 —— 不等下一拍（批125：33ms 空窗）", () => {
  // ★ 这条钉的是"宿主的读档路径"能不能同步补齐：`applyLoad` 里 `physics.clear()`
  //   与下一拍之间那 33ms（30Hz 一拍）里，生物是**没有体**的 —— 它们互相穿过、
  //   也穿过玩家，而 `mobs` 数、战利品数、尸体数全都自洽。只有"清表之后立刻读
  //   `bodies`"这一个采样点能分辨它。
  // ★ 为什么不能靠 `update` 那一条判据兜：`syncBodies` 已经每拍跑了，所以
  //   "过一拍再看"永远绿 —— 那正是批124 的写法（自检里等 250ms）。
  const scene = mkScene();
  const { grid, cells } = realWorld(5150, 3);
  const physics = mkPhysics(scene);
  const mod = mobModule(scene, grid, cells, physics);
  assert.equal(mod.stats.mobs, 3, "夹具前提：三只生物");
  assert.equal(mod.stats.bodies, 3, "夹具前提：三只都已经有体（不然下面清表量到的 0 不算数）");

  // ---- ① 模拟宿主读档那一刻：`physics.clear()` 之后只重建摆件与玩家
  physics.clear();
  assert.equal(mod.stats.bodies, 0, "清表之后体确实没了 —— 这是下面那步的分辨力来源");
  assert.equal(mod.stats.mobs, 3, "生物本身还在（清表只清物理表，不动场景）");

  // ---- ② 宿主在同一处调用它（`applyLoad` 里那一行）
  const addedBefore = mod.stats.bodiesAdded;
  const added = mod.resyncBodies();
  assert.equal(added, 3, "三只都该被补上");
  assert.equal(mod.stats.bodies, mod.stats.mobs, "补完必须一具不缺");
  // ★ 第二个观测量：补齐要**被计数器看见**，否则"补了 3 个"与"这里没跑过"在日志上一样
  assert.equal(mod.stats.bodiesAdded - addedBefore, 3);

  // ---- ③ 幂等：再调一次不许重复加（宿主每个安全点都能调，重复加会把表撑大）
  assert.equal(mod.resyncBodies(), 0, "已经有体的一只都不该再补");
  assert.equal(mod.stats.bodies, mod.stats.mobs);
  const bodiesAfter = physics.stats().bodies;
  assert.ok(bodiesAfter >= 3, `物理世界里该有三具体，实际 ${String(bodiesAfter)}`);
});

test("★★ 清表前先 prune：已经销毁的节点不会被 `add`（否则读档会对不存在的节点抛）", () => {
  // ★ `resyncBodies` 里那一句 `prune()` 的理由就在这里：`ids` 是"出生名单"，
  //   读档前打死的那只已经从场景里没了，而它的 id 还在名单上。
  //   不 prune 的话 `phys.add` 读不到坐标会**抛**（`body N 没有位置`）——
  //   抛在 `applyLoad` 里 = 读档直接炸，而不是"少一具体"。
  const scene = mkScene();
  const { grid, cells } = realWorld(6262, 3);
  const physics = mkPhysics(scene);
  const mod = mobModule(scene, grid, cells, physics);
  const [a] = mod.nodeIds;
  if (a === undefined) throw new Error("unreachable");
  scene.destroy(a);
  scene.flush();

  physics.clear();
  let added = -1;
  assert.doesNotThrow(() => {
    added = mod.resyncBodies();
  }, "对已销毁的节点补体会抛 —— 说明 prune 没跑");
  assert.equal(added, 2, "只剩两只要补");
  assert.equal(mod.stats.mobs, 2, "名单也要跟着清（否则 stats 会多报一只）");
  assert.equal(mod.stats.bodies, 2);
});

test("★★ 两只生物被摆在同一格 ⇒ 一进解算就被分开（动态-动态这一对也有人处理）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(3131, 2);
  const physics = mkPhysics(scene);
  // 同一个格子两只（`spots` 允许重复）—— 比"靠随机走到一起"更确定
  const mod = mobModule(scene, grid, [cells[0]!, cells[0]!], physics);
  const [a, b] = mod.nodeIds;
  if (a === undefined || b === undefined) throw new Error("unreachable");
  // ★ 前提要**自己造**：第一次 update 已经让两只各走了一点。把它们叠回同一处
  //   （位置改了但空间哈希里的格还是旧的 —— `resolve` 会自己重分格，见 physics.ts）。
  const na = scene.find(a);
  const nb = scene.find(b);
  if (na === undefined || nb === undefined) throw new Error("unreachable");
  const p0 = { x: na.worldPosition.x, z: na.worldPosition.y };
  nb.setLocalPosition(p0.x, p0.z);
  assert.ok(Math.hypot(na.worldPosition.x - nb.worldPosition.x, na.worldPosition.y - nb.worldPosition.y) < 1e-9);

  const pushesBefore = physics.stats().pushes;
  physics.resolve();
  const pa = posOf(scene, a);
  const pb = posOf(scene, b);
  const d = Math.hypot(pa.x - pb.x, pa.z - pb.z);
  assert.ok(d >= 0.6 - 0.02, `两只该被分开到 0.6，实际 ${d.toFixed(3)}`);
  // ★ 第二个观测量：**这一对真的被处理过**。
  //   只读距离的话，"两只各被自己推开"和"这一对被跳过"都可能达标；
  //   `pushes` 是解算内部计数器，它不涨就说明 `otherId < id` 那行把这一对漏了。
  assert.ok(physics.stats().pushes > pushesBefore, "动态-动态这一对没进解算（pushes 没涨）");
});

test("★★★ 物理表被外部清空（读档那条路）之后：下一拍体就回来，不是静默开始穿模", () => {
  // ★ 这条是**实际踩到过**的：`applyLoad` 里 `physics.clear()` 之后只重建了
  //   摆件与玩家，生物一只都没补。症状是全套计数照旧、只有画面变（生物又开始穿树）。
  //   修法不是"在又一个出口补一遍"，而是把这个不变量交给**拥有它的模块**（`syncBodies`）。
  const scene = mkScene();
  const { grid, cells } = realWorld(1234, 2);
  const physics = mkPhysics(scene);
  const mod = mobModule(scene, grid, cells, physics);
  assert.equal(mod.stats.bodies, 2, "前提：正常时两只有体");

  const before = mod.stats.bodiesAdded;
  physics.clear();
  assert.equal(physics.stats().bodies, 0, "前提：清表之后确实一只都不剩");

  mod.update(1, 1 / 30);
  assert.equal(mod.stats.bodies, 2, "读档之后体没补回来（生物会静默穿模）");
  assert.equal(mod.stats.bodiesAdded, before + 2, "补体的次数要能看见 —— 它才是读档发生过的证据");
});

test("★★ 二十只挤在一小片地上：谁都不会被永久卡死，也不会长期叠着", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(2026, 24);
  const physics = mkPhysics(scene);
  const mod = mobModule(scene, grid, cells.slice(0, 20), physics);
  assert.equal(mod.stats.mobs, 20);

  const moved = new Map<number, number>();
  let prev = new Map(mod.nodeIds.map((id) => [id, posOf(scene, id)]));

  for (let t = 0; t < 400; t++) {
    mod.update(t, 1 / 30);
    // 解算在移动**之后**跑：于是"这一拍它挤进去了"下一拍就被分开 ——
    // 与宿主里 `world-step-module` 的顺序一致（scene.step → resolve → onStep 里的 update）
    physics.resolve();
    const next = new Map<number, { x: number; z: number }>();
    for (const id of mod.nodeIds) {
      const p = posOf(scene, id);
      const q = prev.get(id);
      if (q !== undefined && Math.hypot(p.x - q.x, p.z - q.z) > 1e-3) moved.set(id, (moved.get(id) ?? 0) + 1);
      next.set(id, p);
    }
    prev = next;
  }

  // ① 没有一只被永久卡住（"二十只挤在门口没人验过"这条，就是这一句）
  const frozen = mod.nodeIds.filter((id) => (moved.get(id) ?? 0) === 0);
  assert.equal(frozen.length, 0, `有 ${String(frozen.length)} 只 400 拍一次都没动过：${frozen.join(",")}`);
  // ② 也不许长期叠着（叠着 = 解算没生效，而"动过"这一条照样绿）
  let worst = 0;
  for (let i = 0; i < mod.nodeIds.length; i++) {
    for (let j = i + 1; j < mod.nodeIds.length; j++) {
      const a = posOf(scene, mod.nodeIds[i]!);
      const b = posOf(scene, mod.nodeIds[j]!);
      worst = Math.max(worst, 0.6 - Math.hypot(a.x - b.x, a.z - b.z));
    }
  }
  assert.ok(worst <= 0.05, `最后仍有 ${worst.toFixed(3)} 的重叠`);
});
