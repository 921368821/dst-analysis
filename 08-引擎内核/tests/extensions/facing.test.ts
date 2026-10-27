/**
 * L4 · 朝向（C7）
 *
 * 朝向看起来只是「一个数」，真正会坏的地方是四处，各自对一类症状：
 *
 *   ① **零向量被当成「朝东」**：`atan2(0,0)` 在 V8 里是 0，于是停下来不动的怪物
 *      被悄悄掰向 +x。症状只在「它停住以后」出现，看着像美术选错了帧。
 *   ② **不归一化**：`-π` 与 `π` 同向却 `!==`；累加会一路漂到 1e6 弧度。
 *      画面完全正常，而判据与存档比对假红。
 *   ③ **不取最短弧**：从 350° 转到 10° 走 340°，怪物原地绕一大圈 ——
 *      **终点都是 10°**，只有「转过的量」这一个观测量能分辨。
 *   ④ **限速只写在调用点**：`turnRate` 是度、`angle` 是弧度、`dt` 是秒，
 *      换算漏一个 `DEG` 的症状是「转得特别慢」，看着像配错了数。
 *
 * ★ 数字全部手算：`turnRate = 90°/s`、`dt = 0.1s` ⇒ 每 tick 9°；
 *   转 90° 正好 10 tick，第 9 tick 之后还差 9°。抄实现算出来的数字不算判据。
 *
 * ★ 角度一律用 `π/4`、`π/8` 这类**二进制精确**的量构造：
 *   写成 `22.5 * π / 180` 会引入 1 ulp 误差，而边界扇区判据正卡在 0.5 上 ——
 *   那种判据会变成「看平台心情」，而不是看实现对不对。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, FieldType } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import {
  FACING_TYPE,
  Facing,
  angleOf,
  dirIndex,
  normRad,
  registerFacingComponent,
  shortestDelta,
} from "../../src/extensions/motion/facing.ts";
import { AI_BAD_SENSE, Perception } from "../../src/extensions/ai/perception.ts";
import { Mover, createMoveModule, registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { dirFrameName, resolveDirFrame } from "../../src/extensions/render/dir-frames.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import { registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { spawnMob } from "../../src/extensions/mobs/spawn-mob.ts";

const PI = Math.PI;
const EPS = 1e-9;

/** 弧度比较：差多少要写进失败信息里（只报「不相等」的判据，排障要靠猜）。 */
function near(actual: number, expect: number, msg: string, eps = EPS): void {
  assert.ok(Math.abs(actual - expect) <= eps, `${msg}：期望 ${String(expect)}，实际 ${String(actual)}`);
}

class Marker extends Component {
  readonly schema = { type: "test.faceMarker", fields: { k: FieldType.String } };
}
const MARK = "test.faceMarker";

function makeScene(): Scene {
  const reg = new ComponentRegistry();
  reg.register({ type: MARK, fields: { k: FieldType.String } }, () => new Marker());
  registerFacingComponent(reg);
  registerMoverComponent(reg);
  return new Scene("facing", reg);
}

function makeCtx(scene: Scene | null): ModuleContext {
  const services = new ServiceRegistry();
  if (scene !== null) services.provide(Services.Scene, scene, "test");
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

function initOk(mod: { init(ctx: ModuleContext): unknown }, ctx: ModuleContext): void {
  const r = mod.init(ctx) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
}

/** 放一个挂着 Facing 的节点，返回 (id, 组件)。 */
function withFacing(scene: Scene, name: string, x: number, z: number): { id: number; f: Facing } {
  const n = scene.spawnImmediate(name);
  n.setLocalPosition(x, z);
  const r = scene.attach(n.id, () => new Facing());
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  scene.flush();
  return { id: n.id, f: r.value as Facing };
}

/** 在 (x,z) 放一个带标记的节点（感知目标）。 */
function putMark(scene: Scene, name: string, x: number, z: number): number {
  const n = scene.spawnImmediate(name);
  n.setLocalPosition(x, z);
  scene.attach(n.id, () => new Marker());
  scene.flush();
  return n.id;
}

/** 一条横向走廊，代理（带 Mover + Facing）放在第 0 格中心。 */
function corridor(width: number): { scene: Scene; grid: NavGrid; id: number; f: Facing; mover: Mover } {
  const scene = makeScene();
  const grid = new NavGrid(width, 1, new Uint8Array(width).fill(1));
  const n = scene.spawnAt("agent", 0.5, 0.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const fr = scene.attach(n.value.id, () => new Facing());
  const mr = scene.attach(n.value.id, () => new Mover());
  assert.equal(fr.ok, true, "agent 需要 motion.facing（否则下面每一条都在验空气）");
  assert.equal(mr.ok, true);
  scene.flush();
  return { scene, grid, id: n.value.id, f: fr.value as Facing, mover: mr.value as Mover };
}

// ---------------------------------------------------------------- 纯函数层

test("[朝向] 归一化：负角、超一圈、非有限值都落到 [0,2π)", () => {
  near(normRad(-PI / 2), (3 * PI) / 2, "负角要折成正的");
  near(normRad(4 * PI), 0, "整整两圈是 0°");
  near(normRad(2 * PI - 1e-6), 2 * PI - 1e-6, "刚好小于 2π 不许被抹成 0");
  assert.equal(normRad(Number.NaN), 0, "NaN 会让整块矩形变成 NaN（实体直接消失），宁可按 0 处理");
  assert.equal(normRad(Number.POSITIVE_INFINITY), 0);
  assert.equal(Object.is(normRad(-0), 0), true, "−0 要归一成 +0，否则深层判等会把同一个方向判成两份");
});

test("[朝向] 零向量不动：站着不动的怪物不会面朝东", () => {
  const f = new Facing();
  f.setAngle(PI); // 朝西
  assert.equal(f.faceTo(0, 0), 0, "没有位移就没有方向");
  near(f.angle, PI, "零向量不该改变朝向");
  assert.equal(angleOf(0, 0), null, "零向量没有方向，不能给 0 —— 那等于「朝东」");
  assert.equal(angleOf(Number.NaN, 1), null);
});

test("[朝向] 8 向扇区：扇心、边界右闭合、0 与 2π 连续", () => {
  for (let i = 0; i < 8; i++) {
    assert.equal(dirIndex((i * PI) / 4, 8), i, `${String(i * 45)}° 应是第 ${String(i)} 扇区`);
  }
  // 边界 22.5° = π/8：闭合于右端（Math.round(0.5) = 1）⇒ 边界本身属于后一扇区
  assert.equal(dirIndex(PI / 8, 8), 1, "正好 22.5° 归 1 号（右端闭合，边界只有一个答案）");
  assert.equal(dirIndex(PI / 8 - 1e-9, 8), 0);
  assert.equal(dirIndex(2 * PI - PI / 8 - 1e-9, 8), 7, "337.5° 之前还是最后一扇");
  // ★ 这里**不用** 337.5° 本身：`TAU - PI/8` 在 f64 里比 7.5 略小，`Math.round` 会落回 7。
  //   判据要钉的是「越过边界就回到 0、索引不越界」，取一个离边界半格的点才验得干净。
  assert.equal(dirIndex(2 * PI - PI / 16, 8), 0, "越过 337.5° 就回到 0，不能在 8 处越界");
  assert.equal(dirIndex(2 * PI - 1e-12, 8), 0, "接近 2π 仍是东");
});

test("[朝向] 4 向扇区：0/90/180/270，45° 取右端（南）", () => {
  assert.equal(dirIndex(0, 4), 0);
  assert.equal(dirIndex(PI / 2, 4), 1);
  assert.equal(dirIndex(PI, 4), 2);
  assert.equal(dirIndex((3 * PI) / 2, 4), 3);
  assert.equal(dirIndex(PI / 4, 4), 1, "45° 正好在边界上 ⇒ 取右端");
  assert.equal(dirIndex(PI / 4 - 1e-9, 4), 0);
  assert.equal(dirIndex(2 * PI - 1e-12, 4), 0);
});

test("[朝向] 最短弧：350° → 10° 只走 20°，不绕 340°", () => {
  const from = (350 * PI) / 180;
  const to = (10 * PI) / 180;
  near(
    shortestDelta(from, to),
    (20 * PI) / 180,
    "不取最短会让怪物原地绕一大圈（终点一样，只有转过的量能分辨）",
  );
  const f = new Facing();
  f.setAngle(from);
  const step = f.turnTowards(to);
  near(step, (20 * PI) / 180, "实际转过的量");
  near(f.angle, to, "终点");
});

test("[朝向] 正好差 180° 统一取 +π（同一输入不许两个方向）", () => {
  near(shortestDelta(0, PI), PI, "正向");
  near(shortestDelta(PI, 0), PI, "反向也取 +π：不定死的话两台机器可能反向转，回放就不认字节");
  const f = new Facing();
  f.setAngle(0);
  f.turnTowards(PI);
  near(f.angle, PI, "0° 转 180° 落在 π");
});

// ---------------------------------------------------------------- 转向速率

test("[朝向] turnRate=0 ⇒ 瞬时对准（旧内容行为不变）", () => {
  const f = new Facing();
  assert.equal(f.turnRate, 0, "默认必须是 0：没有朝向驱动的旧内容行为不许变");
  f.setAngle(0);
  const step = f.turnTowards(PI / 2);
  near(step, PI / 2, "turnRate=0 就是不限速");
  near(f.angle, PI / 2, "一 tick 到位");
});

test("[朝向] 限速：90°/s × 0.1s = 9°/tick，90° 要 10 tick，且不过冲", () => {
  const f = new Facing();
  f.turnRate = 90;
  f.setAngle(0);
  for (let i = 0; i < 9; i++) {
    const step = f.turnTowards(PI / 2, f.maxTurn(0.1));
    near(step, (9 * PI) / 180, `第 ${String(i + 1)} tick 只能转 9°`);
  }
  near(f.angle, (81 * PI) / 180, "9 tick 之后还差 9°");
  const last = f.turnTowards(PI / 2, f.maxTurn(0.1));
  near(last, (9 * PI) / 180, "第 10 tick 转满");
  near(f.angle, PI / 2, "正好到 90°");
  const over = f.turnTowards(PI / 2, f.maxTurn(0.1));
  assert.ok(Math.abs(over) <= 1e-12, `已经在目标上不该再转，实际转了 ${String(over)}`);
  near(f.angle, PI / 2, "到了就是到了");
});

test("[朝向] maxTurn 的单位换算：度/秒 → 弧度/tick（漏 DEG 会慢 57 倍）", () => {
  const f = new Facing();
  f.turnRate = 180;
  near(f.maxTurn(0.5), PI / 2, "180°/s × 0.5s = 90°");
  near(f.maxTurn(0.1), (18 * PI) / 180, "180°/s × 0.1s = 18°");
  f.turnRate = 0;
  assert.equal(f.maxTurn(1), Number.POSITIVE_INFINITY, "0 = 不限速");
  f.turnRate = -90;
  assert.equal(f.maxTurn(1), Number.POSITIVE_INFINITY, "负值当不限速（负角速度只会让怪原地发抖）");
});

test("[朝向] 负 turnRate 不会把朝向转反", () => {
  const f = new Facing();
  f.turnRate = -90;
  f.setAngle(0);
  const step = f.turnTowards(PI / 2, f.maxTurn(0.1));
  near(step, PI / 2, "负值不参与限速，方向仍是 +");
  near(f.angle, PI / 2, "一 tick 对准");
});

test("[朝向] 存档往返：角度与限速都在；旧存档缺字段用类默认值", () => {
  const f = new Facing();
  f.setAngle(PI / 3);
  f.turnRate = 45;
  const saved = f.save();
  const g = new Facing();
  const r = g.load(saved);
  assert.deepEqual(r.missing, [], "新存档不该缺字段");
  near(g.angle, PI / 3, "角度");
  assert.equal(g.turnRate, 45, "限速");

  const h = new Facing();
  const old = h.load({ type: FACING_TYPE }); // 旧存档：一个字段都没有
  assert.deepEqual([...old.missing].sort(), ["angle", "turnRate"]);
  assert.equal(h.angle, 0);
  assert.equal(h.turnRate, 0, "缺字段必须落到「不限速」= 旧行为");
});

// ---------------------------------------------------------------- 接进感知

test("[感知] 配了视野半角却没有任何朝向 ⇒ 报错（不当全向）", () => {
  const scene = makeScene();
  const self = scene.spawnImmediate("self");
  self.setLocalPosition(0, 0);
  scene.flush();
  putMark(scene, "t", 3, 0);
  const p = new Perception({ range: 10, watch: [MARK], halfAngleDeg: 60 });
  const r = p.sense(scene, self.id, 1);
  assert.equal(r.ok, false, "没有朝向就把「前方」当全向是错的 —— 那等于给每只怪 360° 视野");
  if (r.ok) return;
  assert.equal(r.error.code, AI_BAD_SENSE);
});

test("[感知] 节点上有 Facing 时省略参数也能做扇区感知（前方看见、后方看不见）", () => {
  const scene = makeScene();
  const { id, f } = withFacing(scene, "self", 0, 0);
  f.setAngle(0); // 朝东
  const front = putMark(scene, "front", 3, 0);
  const back = putMark(scene, "back", -3, 0);
  const p = new Perception({ range: 10, watch: [MARK], halfAngleDeg: 60 });
  const r = p.sense(scene, id, 1);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const ids = r.value.map((s) => s.nodeId);
  assert.deepEqual(ids, [front], `只该看见正前方那个，实际 ${JSON.stringify(ids)}`);
  assert.equal(ids.includes(back), false, "背后的目标不该进结果");
});

test("[感知] 显式朝向参数优先于组件（组件朝东、参数朝西 ⇒ 看见西边那个）", () => {
  const scene = makeScene();
  const { id, f } = withFacing(scene, "self", 0, 0);
  f.setAngle(0); // 组件朝东
  const front = putMark(scene, "front", 3, 0);
  const back = putMark(scene, "back", -3, 0);
  const p = new Perception({ range: 10, watch: [MARK], halfAngleDeg: 60 });
  const r = p.sense(scene, id, 1, PI); // 调用方明确说「我朝西」
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const ids = r.value.map((s) => s.nodeId);
  assert.deepEqual(ids, [back], `参数优先：只该看见西边那个，实际 ${JSON.stringify(ids)}`);
  assert.equal(ids.includes(front), false);
});

// ---------------------------------------------------------------- 接进移动

test("[移动] 追人时朝向跟着位移：一直往东走 ⇒ dir8 = 0", () => {
  const c = corridor(8);
  c.f.setAngle(PI); // 故意先朝西，证明它真的被改了
  const mod = createMoveModule({ grid: c.grid, decide: () => 5 });
  initOk(mod, makeCtx(c.scene));
  for (let t = 1; t <= 10; t++) mod.update(t, 0.1);
  assert.equal(c.mover.arrived, false, "这一段还没到，别把判据建在「已经停下」上");
  assert.equal(c.f.dir8, 0, "往东走却面朝别处 —— 精灵与视野锥会同时错");
});

test("[移动] 被挡住没挪动时不转身（原地不动却慢慢转过去最假）", () => {
  const c = corridor(8);
  c.f.setAngle(PI); // 朝西
  const mod = createMoveModule({
    grid: c.grid,
    decide: () => 5,
    // 恒在起点接触（t = 0）：这一拍位移为 0
    sweep: () => ({ t: 0, nx: -1, nz: 0, nodeId: 999 }),
  });
  initOk(mod, makeCtx(c.scene));
  for (let t = 1; t <= 10; t++) mod.update(t, 0.1);
  assert.ok(mod.stats.blocked > 0, "夹具必须真的挡住它，否则这条判据在验别的东西");
  near(c.f.angle, PI, "没有位移就没有新的朝向");
  assert.equal(c.f.dir8, 4, "被挡住的怪不该朝着墙转过去");
});

test("[移动] 限速时第一 tick 不会瞬间对齐（视野锥不会瞬间变成全向）", () => {
  const c = corridor(8);
  c.f.turnRate = 90; // 9°/tick
  c.f.setAngle(PI); // 朝西，要转 180° 才朝东
  const mod = createMoveModule({ grid: c.grid, decide: () => 5 });
  initOk(mod, makeCtx(c.scene));
  mod.update(1, 0.1);
  near(c.f.angle, PI + (9 * PI) / 180, "第一 tick 只转 9°（最短弧取 +π，从 180° 往 189° 转）");
  assert.ok(Math.abs(c.f.angle) > 1, "第一 tick 就对准了 —— 限速没生效");
});

// ---------------------------------------------------------------- 渲染契约

test("[帧] dirFrameName：8 向 / 4 向字母表，越界按环取", () => {
  const eight = ["e", "se", "s", "sw", "w", "nw", "n", "ne"];
  for (let i = 0; i < 8; i++) assert.equal(dirFrameName("walk", i, 8), `walk_${eight[i]!}`);
  const four = ["e", "s", "w", "n"];
  for (let i = 0; i < 4; i++) assert.equal(dirFrameName("walk", i, 4), `walk_${four[i]!}`);
  assert.equal(dirFrameName("walk", 9, 8), "walk_se", "越界按环取，不抛错（帧名算不出来时游戏还得动）");
  assert.equal(dirFrameName("walk", -1, 8), "walk_ne");
});

test("[帧] resolveDirFrame：缺方向帧回落到单帧，一张图都没有则 null", () => {
  const frames = new Set(["walk", "walk_e", "walk_s"]);
  const has = (n: string): boolean => frames.has(n);
  assert.equal(resolveDirFrame(has, "walk", 0, 8), "walk_e");
  assert.equal(resolveDirFrame(has, "walk", 2, 8), "walk_s");
  assert.equal(resolveDirFrame(has, "walk", 4, 8), "walk", "没有 walk_w ⇒ 回落单帧（美术还没画，实体也不能消失）");
  const none = new Set<string>();
  assert.equal(resolveDirFrame((n) => none.has(n), "walk", 0, 8), null, "连回落的图都没有 ⇒ 说 null，别编一个名字");
});

// ---------------------------------------------------------------- 装配

const RABBIT = {
  kind: "rabbit",
  frame: "rabbit",
  width: 0.8,
  height: 0.8,
  radius: 0.3,
  maxHp: 4,
  damage: 0,
  range: 1.4,
  cooldownTicks: 20,
  speed: 1.8,
  team: "prey",
  loot: [{ kind: "meat", count: 2 }],
};

function mobRegistry(withFacingComp: boolean): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  if (withFacingComp) registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  if (!reg.has(SPRITE_TYPE)) reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

test("[装配] spawnMob 给生物挂上 motion.facing，handle 上那个就是节点上那个", () => {
  const scene = new Scene("mob-facing", mobRegistry(true));
  const r = spawnMob(scene, RABBIT, 0.5, 0.5);
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;
  const back = scene.find(r.value.nodeId)?.get<Facing>(FACING_TYPE);
  assert.ok(back instanceof Facing, "生物身上没有 motion.facing —— 朝向又回到「数据不存在」");
  assert.equal(r.value.facing, back, "handle 上的 facing 必须就是节点上那一个（复制品改了也不生效）");
});

test("[装配] 朝向没注册 ⇒ 装配硬失败，不留「画得出来但不会转身」的怪", () => {
  const scene = new Scene("mob-no-facing", mobRegistry(false));
  const r = spawnMob(scene, RABBIT, 0.5, 0.5);
  assert.equal(r.ok, false, "少了 motion.facing 还照样生成 = 装配静默退化");
  if (r.ok) return;
  assert.equal((r.error.detail as { type?: string }).type, FACING_TYPE, "要点名缺的是哪个组件");
  let nodes = 0;
  scene.root.walk(() => {
    nodes++;
  });
  assert.equal(nodes, 1, "失败的装配不能留下孤儿节点（树里只剩 __root__）");
});
