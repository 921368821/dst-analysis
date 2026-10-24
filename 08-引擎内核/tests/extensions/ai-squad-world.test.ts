/**
 * L4 · AI 感知/目标/队伍 接到**真实生成的世界**上（不是手搭的假场景）
 *
 * ★ 为什么还要一条"接线"判据：三个模块各自的判据都是用手搭的小场景跑的 ——
 *   那证明的是"逻辑对"，证明不了"在真世界里的组件类型名与坐标量纲对得上"。
 *   这个项目已经踩过一次同类问题：解码器支持了 13 个 SOF，导入器却还在用旧清单
 *   把它们全拦在门外，两边判据各自全绿。
 *
 * ★ 这里刻意**不**引入新的抽象层：调用方（未来的怪物 AI）自己写"拿不到就试下一个"。
 *   引擎只提供"看见什么""盯哪个""这个目标谁占了"三件事，不替调用方规定策略。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { Logger } from "../../src/foundation/log/logger.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { SITE_TYPE, assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA } from "../../src/extensions/worldgen/tasks.ts";
import { createWorldTaskModule, registerResourceComponent } from "../../src/extensions/worldgen/task-module.ts";
import { PLAYER_TYPE, registerPlayerComponent, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { Perception, type Sensed } from "../../src/extensions/ai/perception.ts";
import { TargetTracker } from "../../src/extensions/ai/targeting.ts";
import { Team } from "../../src/extensions/ai/team.ts";

function makeCtx(): ModuleContext {
  return {
    log: new Logger(() => 0),
    events: new EventBus<Record<string, unknown>>(),
    services: new ServiceRegistry(),
    platform: {} as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

function buildWorld() {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponent(reg);
  // ★ 玩家必须"有身体"（`spawnPlayer` 会检查 render.sprite 注册过）——
  //   渲染模块启动时会注册，判据里得自己补，否则拿到的是 SPAWN.NO_SPRITE_COMPONENT
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("squad", reg);
  const g = generateWorld({ seed: 77, width: 24, height: 18, maxSitesPerCell: 1 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  assert.equal(assembleWorld(g.value, scene).ok, true);
  // 任务模块起来（判据里它只是为了让"有没有再生资源"不影响感知结果）
  const mod = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 2, biomes: ["grass"] }] },
    plan: g.value,
    scene,
  });
  const init = mod.init(makeCtx());
  assert.ok(init === undefined || !(init instanceof Promise));
  return { scene, plan: g.value, mod };
}

/** 在真实世界里挑两个投放点，把它们当作"猎狗"的落脚点（不动世界，只加节点）。 */
function placeHunters(scene: Scene, n: number): number[] {
  const sites = [...scene.componentsOf(SITE_TYPE)]
    .map((c) => c.node)
    .filter((node): node is NonNullable<typeof node> => node !== null)
    .sort((a, b) => a.id - b.id);
  assert.ok(sites.length >= n, "世界里投放点太少，判据没法进行");
  const ids: number[] = [];
  for (let i = 0; i < n; i++) {
    const node = scene.spawnImmediate(`hunter${String(i)}`);
    const p = sites[i]!.worldPosition;
    node.setLocalPosition(p.x + 0.25, p.y + 0.25);
    ids.push(node.id);
  }
  scene.flush();
  return ids;
}

test("[接线] 真实世界里感知得到投放点与玩家（类型名与坐标量纲对得上）", () => {
  const { scene, plan } = buildWorld();
  const hero = spawnPlayer(scene, plan);
  assert.equal(hero.ok, true, hero.ok ? "" : hero.error.code);
  if (!hero.ok) return;
  const [hunter] = placeHunters(scene, 1);
  assert.ok(hunter !== undefined);

  const p = new Perception({ range: 30, watch: [SITE_TYPE, PLAYER_TYPE] });
  const r = p.sense(scene, hunter!, 1);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;

  const sites = r.value.filter((s) => s.type === SITE_TYPE);
  const players = r.value.filter((s) => s.type === PLAYER_TYPE);
  assert.ok(sites.length >= 5, `只看见 ${String(sites.length)} 个投放点 —— 类型名或范围对不上`);
  assert.equal(players.length, 1, "玩家也应该被看见（watch 里第二个类型）");
  // 半径 30 在这个世界里足够覆盖全图，所以看见的投放点数应接近总数
  const total = scene.countOf(SITE_TYPE);
  assert.ok(sites.length >= total - 2, `看见 ${String(sites.length)} / 共 ${String(total)} —— 漏得太多`);
  // 距离² 与坐标一致（量纲检查：如果谁把 cell 当坐标，这里会不等）
  for (const s of r.value) {
    const node = scene.find(s.nodeId);
    if (node === undefined) continue;
    const w = node.worldPosition;
    assert.equal(s.x, w.x);
    assert.equal(s.z, w.y);
  }
});

test("[接线] 两只猎狗分头追：队伍占位后**不会**都扑同一个目标", () => {
  const { scene, plan } = buildWorld();
  const hero = spawnPlayer(scene, plan);
  assert.equal(hero.ok, true);
  if (!hero.ok) return;
  const [a, b] = placeHunters(scene, 2);
  assert.ok(a !== undefined && b !== undefined);

  const team = new Team({ id: "hounds" });
  assert.equal(team.add(a!, "hunter").ok, true);
  assert.equal(team.add(b!, "hunter").ok, true);

  const pa = new Perception({ range: 12, watch: [SITE_TYPE] });
  const pb = new Perception({ range: 12, watch: [SITE_TYPE] });
  const ta = new TargetTracker({ stickiness: 0 });
  const tb = new TargetTracker({ stickiness: 0 });

  const sa = pa.sense(scene, a!, 1);
  const sb = pb.sense(scene, b!, 1);
  assert.equal(sa.ok && sb.ok, true);
  if (!sa.ok || !sb.ok) return;

  // ★ 调用方的"拿不到就试下一个"：引擎不替它决定策略，但提供的原语要够用
  function pickFree(agentId: number, tracker: TargetTracker, cands: readonly Sensed[]): number | null {
    for (const c of cands) {
      const claim = team.claim(agentId, c.nodeId);
      if (!claim.ok) return null;
      if (claim.value.taken) continue; // 有人去了，看下一个
      const r = tracker.update([c], 1);
      if (!r.ok) return null;
      return r.value.nodeId;
    }
    return null;
  }

  const targetA = pickFree(a!, ta, sa.value);
  const targetB = pickFree(b!, tb, sb.value);
  assert.ok(targetA !== null && targetB !== null, "两只猎狗至少该各分到一个目标");
  assert.notEqual(targetA, targetB, "两个队员扑了同一个目标 —— 占位没起作用");
  assert.equal(team.ownerOf(targetA!), a);
  assert.equal(team.ownerOf(targetB!), b);
  // 占位数 = 队员数（没有多占、没有漏占）
  assert.equal(team.claimsSnapshot().length, 2);
});

test("[接线] 目标被采走（节点销毁）之后，队员能释放并把目标让给别人", () => {
  const { scene, plan, mod } = buildWorld();
  const hero = spawnPlayer(scene, plan);
  assert.equal(hero.ok, true);
  if (!hero.ok) return;
  const [a, b] = placeHunters(scene, 2);
  const team = new Team();
  team.add(a!, "hunter");
  team.add(b!, "hunter");

  const pa = new Perception({ range: 12, watch: [SITE_TYPE] });
  const sa = pa.sense(scene, a!, 1);
  assert.equal(sa.ok, true);
  if (!sa.ok) return;
  const first = sa.value[0]!;

  assert.equal(team.claim(a!, first.nodeId).ok, true);
  // 世界这一侧：目标节点被销毁（采集/被吃/下线，最终都是这一件事）
  const node = scene.find(first.nodeId);
  assert.ok(node !== undefined);
  scene.destroy(first.nodeId);
  scene.flush();
  void mod;

  // 队员这一侧：离队释放，另一个人能占到这个号（存档里 id 会复用吗？这里是"允许再占"，不是"节点复活"）
  assert.equal(team.remove(a!), first.nodeId);
  const claim = team.claim(b!, first.nodeId);
  assert.equal(claim.ok, true);
  if (!claim.ok) return;
  assert.equal(claim.value.taken, false, "旧队员走了，目标应该空出来");
});
