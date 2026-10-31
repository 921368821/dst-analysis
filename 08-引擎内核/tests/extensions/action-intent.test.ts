/**
 * L3 · 动作意图：一个请求、一条路、三种判定
 *
 * ★ 这条文件要防的不是"函数写错"，而是三个更隐蔽的失效：
 *   ① **未知码被默认成 retry** —— 一个配置写错的怪会每拍重试、世界毫无变化，
 *      画面上只表现为"有点卡"。所以"未知 ⇒ fatal"必须单独有一条判据，
 *      而且要看**拼错的码**（不是随便一个字符串）。
 *   ② **形状错走到了世界里** —— 断言不是"报了个错"，而是"目标血一点没变、
 *      攻击者的 lastHitTick 一点没变"（与 `combat-attack.test.ts` ① 同一条理由）。
 *   ③ **origin 参与了判定** —— 它只该进日志。若哪天有人写 `if (origin === "player")`，
 *      同一份世界会出现两套结果；这一条用"两个来源跑同一套断言"来咬住。
 *
 * ★ 位移意图的判据在 `intent.test.ts`（批147），两份不重叠：那边钉"一步位移怎么算"，
 *   这边钉"一次动作成不成、下一步该不该换"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { HEALTH_TYPE, Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import {
  Attacker,
  COMBAT_COOLDOWN,
  COMBAT_OUT_OF_RANGE,
  COMBAT_SELF,
  registerAttackerComponent,
} from "../../src/extensions/combat/attack.ts";
import { COMBAT_NO_TARGET, COMBAT_TARGET_DEAD } from "../../src/extensions/combat/health.ts";
import { addItem, countItem, makeInventory, registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { ResourceMarker, registerResourceComponent } from "../../src/extensions/worldgen/task-module.ts";
import { FOOD_FULL, normalizeFoodTable } from "../../src/extensions/survival/food.ts";
import { makeHunger, registerHungerComponent } from "../../src/extensions/survival/hunger.ts";
import { FactionMember, createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { createCombatModule } from "../../src/extensions/combat/combat-module.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { Services } from "../../src/core/tokens.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import {
  INTENT_BAD_SHAPE,
  INTENT_OK,
  actionProblem,
  intentText,
  outcomeText,
  verdictOf,
  type ActionIntent,
} from "../../src/extensions/actions/intent.ts";
import {
  INTENT_NO_ACTOR,
  INTENT_NO_FOOD_TABLE,
  INTENT_NO_RADIUS,
  executeIntent,
  type IntentWorld,
} from "../../src/extensions/actions/executor.ts";

// ---------------------------------------------------------------- 夹具

interface World {
  readonly scene: Scene;
  readonly heroId: number;
  readonly foeId: number;
  readonly atk: Attacker;
  readonly foeHp: Health;
  readonly w: IntentWorld;
}

const TABLE = normalizeFoodTable({ meat: { nutrition: 25, health: 5 }, berry: { nutrition: 10 } });
if (!TABLE.ok) throw new Error("夹具前提：食物表合法");
const FOOD = TABLE.value;

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerInventoryComponents(reg);
  registerHungerComponent(reg);
  registerResourceComponent(reg);
  registerFactionComponent(reg);
  return new Scene("intent", reg);
}

/** 英雄站在 (2.5,2.5)，敌人站在 (3.5,2.5) —— 距离 1，射程 2 内。 */
function mkWorld(cfg: { foeHp?: number; range?: number; hungry?: number } = {}): World {
  const scene = mkScene();
  const an = scene.spawnAt("hero", 2.5, 2.5);
  const tn = scene.spawnAt("rabbit", 3.5, 2.5);
  assert.equal(an.ok && tn.ok, true);
  if (!an.ok || !tn.ok) throw new Error("unreachable");
  // ★ 必须先 flush 再 attach：`spawnAt` 只把节点排进队列，attach 一个还没落地的 id
  //   会**静默丢掉**（`makeInventory` / `makeHunger` 都是"找不到节点就什么都不做"）
  //   —— 症状是"吃不了东西"，而错在夹具。这一条踩过一次。
  scene.flush();

  const heroId = an.value.id;
  const foeId = tn.value.id;
  const atk = new Attacker();
  atk.damage = 2;
  atk.range = cfg.range ?? 2;
  atk.cooldownTicks = 10;
  scene.attach(heroId, () => atk);
  // 两个助手都返回 `Result<组件, EngineError>` —— 不看 `.ok` 的话，夹具坏掉时的症状
  // 是"吃不了东西"，而错在夹具（这一步踩过一次）
  assert.equal(makeInventory(scene, heroId).ok, true, "夹具前提：英雄有背包");
  assert.equal(makeHunger(scene, heroId, 100, cfg.hungry ?? 40).ok, true, "夹具前提：英雄有饱食度");

  const foeHp = new Health();
  foeHp.hp = cfg.foeHp ?? 10;
  foeHp.maxHp = 10;
  scene.attach(foeId, () => foeHp);
  scene.flush();

  return { scene, heroId, foeId, atk, foeHp, w: { scene, food: FOOD } };
}

function atk(actor: number, target: number, tick = 1, origin: ActionIntent["origin"] = "ai"): ActionIntent {
  return { kind: "attack", actor, target, tick, origin };
}

/** 全 ASCII（面板/日志共用；与 `mob-inspector.ts` 同一条理由）。 */
function isAscii(s: string): boolean {
  for (const ch of s) if (ch.charCodeAt(0) > 0x7e) return false;
  return true;
}

// ---------------------------------------------------------------- 分类表（纯函数）

test("[动作意图] verdictOf：OK 是 ok，四个「下一拍可能成」的码是 retry", () => {
  assert.equal(verdictOf(INTENT_OK), "ok");
  for (const code of [COMBAT_OUT_OF_RANGE, COMBAT_COOLDOWN, FOOD_FULL, "INVENTORY.FULL"]) {
    assert.equal(verdictOf(code), "retry", `${code} 应该在 retry 一侧（下一拍可能做得成）`);
  }
});

test("[动作意图] ★ 未知码是 fatal 不是 retry（默认值选安全的一侧）", () => {
  // 拼错的码、空串、大小写不对 —— 三种都会出现在真实代码里（改了码名忘改一处）
  for (const code of ["COMBAT.OUT-OF-RANGE", "", "combat.out_of_range", "FOOD.FULLL", "SOMETHING.NEW"]) {
    assert.equal(verdictOf(code), "fatal", `${JSON.stringify(code)} 不该被当成可重试`);
  }
});

test("[动作意图] actionProblem：三种合法意图都不报问题", () => {
  assert.equal(actionProblem(atk(1, 2)), null);
  assert.equal(actionProblem({ kind: "pickup", actor: 1, tick: 0, origin: "player" }), null, "半径可省略（执行器有默认值）");
  assert.equal(actionProblem({ kind: "pickup", actor: 1, tick: 0, origin: "player", radius: 2.5 }), null);
  assert.equal(actionProblem({ kind: "use", actor: 1, tick: 0, origin: "script", item: "meat" }), null);
});

test("[动作意图] actionProblem：畸形请求在**进世界之前**被拦下，且点名到字段", () => {
  const bad: Array<[string, unknown]> = [
    ["actor", { kind: "attack", actor: -1, target: 2, tick: 0, origin: "ai" }],
    ["actor", { kind: "attack", actor: 1.5, target: 2, tick: 0, origin: "ai" }],
    ["tick", { kind: "attack", actor: 1, target: 2, tick: -3, origin: "ai" }],
    ["target", { kind: "attack", actor: 1, tick: 0, origin: "ai" }],
    ["target", { kind: "attack", actor: 1, target: 2.5, tick: 0, origin: "ai" }],
    ["radius", { kind: "pickup", actor: 1, tick: 0, origin: "ai", radius: -1 }],
    ["radius", { kind: "pickup", actor: 1, tick: 0, origin: "ai", radius: Number.NaN }],
    ["item", { kind: "use", actor: 1, tick: 0, origin: "ai", item: "   " }],
  ];
  for (const [field, it] of bad) {
    const e = actionProblem(it as ActionIntent);
    assert.notEqual(e, null, `${JSON.stringify(it)} 应被判为畸形`);
    assert.equal(e?.code, INTENT_BAD_SHAPE);
    // ★ 消息里必须点到字段：只说"意图不合法"的话，宿主只能把整条丢掉
    assert.equal(e?.message.includes(field), true, `${JSON.stringify(it)} 的消息没点名字段 ${field}：${e?.message ?? ""}`);
  }
});

// ---------------------------------------------------------------- 形状错不碰世界

test("[动作意图] ★ 畸形意图不碰世界：血量与冷却都不动", () => {
  const { heroId, foeHp, atk: a, w } = mkWorld();
  const before = { hp: foeHp.hp, last: a.lastHitTick };
  // target 缺失 = 形状错（不是"打不到"）
  const o = executeIntent(w, { kind: "attack", actor: heroId, tick: 5, origin: "player" });
  assert.equal(o.ok, false);
  assert.equal(o.code, INTENT_BAD_SHAPE);
  assert.equal(o.verdict, "fatal");
  assert.equal(foeHp.hp, before.hp, "形状错却扣了血");
  assert.equal(a.lastHitTick, before.last, "形状错却消费了冷却");
});

// ---------------------------------------------------------------- attack

test("[动作意图] attack 命中：ok / verdict ok / applied = 扣掉的血 / 带回原始报告", () => {
  const { heroId, foeId, foeHp, w } = mkWorld();
  const o = executeIntent(w, atk(heroId, foeId, 7));
  assert.equal(o.ok, true);
  assert.equal(o.verdict, "ok");
  assert.equal(o.code, INTENT_OK);
  assert.equal(o.applied, 2);
  assert.equal(foeHp.hp, 8);
  // 原始报告要带得回来：表现层要 before/after/overkill，裁剪版会把它变成 0
  assert.equal(o.hit?.report.before, 10);
  assert.equal(o.hit?.report.after, 8);
  assert.equal(o.hit?.report.overkill, 0);
  assert.equal(o.hit?.targetId, foeId);
});

test("[动作意图] attack 超距：verdict retry（走近就能打），applied 0", () => {
  const { heroId, foeId, foeHp, w } = mkWorld({ range: 0.5 });
  const o = executeIntent(w, atk(heroId, foeId));
  assert.equal(o.ok, false);
  assert.equal(o.code, COMBAT_OUT_OF_RANGE);
  assert.equal(o.verdict, "retry");
  assert.equal(o.applied, 0);
  assert.equal(foeHp.hp, 10);
});

test("[动作意图] attack 冷却没好：verdict retry，且**不消费**第二次冷却", () => {
  const { heroId, foeId, atk: a, foeHp, w } = mkWorld();
  assert.equal(executeIntent(w, atk(heroId, foeId, 10)).ok, true);
  const lastAfterFirst = a.lastHitTick;
  const second = executeIntent(w, atk(heroId, foeId, 11));
  assert.equal(second.code, COMBAT_COOLDOWN);
  assert.equal(second.verdict, "retry");
  assert.equal(a.lastHitTick, lastAfterFirst, "冷却被拒的一次不该改写 lastHitTick");
  assert.equal(foeHp.hp, 8, "第二次不该扣血");
});

test("[动作意图] attack 目标已死 / 不存在 / 打自己：三种都是 fatal（换目标，不是等）", () => {
  const { heroId, foeId, w } = mkWorld({ foeHp: 2 });
  assert.equal(executeIntent(w, atk(heroId, foeId, 20)).ok, true);
  const dead = executeIntent(w, atk(heroId, foeId, 40));
  assert.equal(dead.code, COMBAT_TARGET_DEAD);
  assert.equal(dead.verdict, "fatal");

  const ghost = executeIntent(w, atk(heroId, 99999));
  assert.equal(ghost.code, COMBAT_NO_TARGET);
  assert.equal(ghost.verdict, "fatal");

  const self = executeIntent(w, atk(heroId, heroId));
  assert.equal(self.code, COMBAT_SELF);
  assert.equal(self.verdict, "fatal");
});

// ---------------------------------------------------------------- pickup

test("[动作意图] pickup 空地：ok 但 verdict fatal（请求没错，这条路走不通）", () => {
  const { heroId, w } = mkWorld();
  const o = executeIntent(w, { kind: "pickup", actor: heroId, tick: 1, origin: "player", radius: 3 });
  assert.equal(o.ok, true, "站在空地上按一下不是错误");
  assert.equal(o.verdict, "fatal", "但对决策层来说这条路走不通 —— 换个地方");
  assert.equal(o.applied, 0);
  assert.equal(o.picked?.inRange, 0);
});

test("[动作意图] pickup 有资源：进背包、applied = 拾到的堆数、verdict ok", () => {
  const { scene, heroId, w } = mkWorld();
  const n = scene.spawnAt("tree", 3.0, 3.0);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const m = new ResourceMarker();
  m.cell = 0;
  m.kind = "tree";
  m.count = 2;
  scene.attach(n.value.id, () => m);
  scene.flush();

  const o = executeIntent(w, { kind: "pickup", actor: heroId, tick: 1, origin: "player", radius: 3 });
  assert.equal(o.ok, true);
  assert.equal(o.verdict, "ok");
  assert.equal(o.applied, 1, "一格被拾走 = 1 次");
  assert.equal(o.picked?.inRange, 1);
  assert.equal(o.picked?.failed, null);
  const got = o.picked?.picked[0];
  assert.notEqual(got, undefined, "报告里要有一条拾取记录");
  assert.equal(got?.total, 2, "背包里这一种的总数（资源 count=2 ⇒ 一次全拿走）");
  assert.equal(countItem(scene, heroId, got?.kind ?? ""), 2, "拾到的东西要真的进背包");
});

test("[动作意图] pickup 发起者不在场景里：NO_ACTOR，fatal（不是静默 0 个）", () => {
  const { scene } = mkWorld();
  const o = executeIntent({ scene }, { kind: "pickup", actor: 99999, tick: 1, origin: "ai", radius: 2 });
  assert.equal(o.ok, false);
  assert.equal(o.code, INTENT_NO_ACTOR);
  assert.equal(o.verdict, "fatal");
});

test("[动作意图] pickup 缺默认半径：NO_RADIUS 而不是默默按 0 米扫", () => {
  const { scene, heroId } = mkWorld();
  const o = executeIntent({ scene }, { kind: "pickup", actor: heroId, tick: 1, origin: "ai" });
  assert.equal(o.ok, false);
  assert.equal(o.code, INTENT_NO_RADIUS);
  assert.equal(o.verdict, "fatal");
});

// ---------------------------------------------------------------- use

test("[动作意图] use 吃一个：applied = 营养值、饱食真的涨了、带回原始报告", () => {
  const { scene, heroId, w } = mkWorld({ hungry: 40 });
  addItem(scene, heroId, "meat", 1);
  const o = executeIntent(w, { kind: "use", actor: heroId, tick: 1, origin: "ai", item: "meat" });
  assert.equal(o.ok, true);
  assert.equal(o.verdict, "ok");
  assert.equal(o.applied, 25);
  assert.deepEqual([o.ate?.hungerBefore, o.ate?.hungerAfter], [40, 65]);
  assert.equal(countItem(scene, heroId, "meat"), 0);
});

test("[动作意图] use 吃饱了：retry（待会儿饿了就能吃），物品一个不少", () => {
  const { scene, heroId, w } = mkWorld({ hungry: 100 });
  addItem(scene, heroId, "meat", 1);
  const o = executeIntent(w, { kind: "use", actor: heroId, tick: 1, origin: "ai", item: "meat" });
  assert.equal(o.ok, false);
  assert.equal(o.code, FOOD_FULL);
  assert.equal(o.verdict, "retry");
  assert.equal(countItem(scene, heroId, "meat"), 1, "吃不下去却把东西吃没了");
});

test("[动作意图] use 但执行器没有食物表：fatal（不是静默成功）", () => {
  const { scene, heroId } = mkWorld();
  addItem(scene, heroId, "meat", 1);
  const o = executeIntent({ scene }, { kind: "use", actor: heroId, tick: 1, origin: "ai", item: "meat" });
  assert.equal(o.ok, false);
  assert.equal(o.code, INTENT_NO_FOOD_TABLE);
  assert.equal(o.verdict, "fatal");
  assert.equal(countItem(scene, heroId, "meat"), 1, "没有表却把东西吃了");
});

// ---------------------------------------------------------------- 来源不参与判定

test("[动作意图] ★ origin 只进日志、不进判定：player 与 ai 跑同一套断言", () => {
  const a = mkWorld();
  const b = mkWorld();
  const oa = executeIntent(a.w, atk(a.heroId, a.foeId, 3, "player"));
  const ob = executeIntent(b.w, atk(b.heroId, b.foeId, 3, "ai"));
  assert.deepEqual(
    [oa.ok, oa.verdict, oa.code, oa.applied],
    [ob.ok, ob.verdict, ob.code, ob.applied],
    "两个来源在同一份世界上必须得到同一个结果",
  );
  // 但日志要能分辨是谁干的
  assert.notEqual(intentText(oa.intent), intentText(ob.intent));
  assert.equal(intentText(oa.intent), `player#${String(a.heroId)} attack->${String(a.foeId)} @3`);
});

test("[动作意图] 文案全 ASCII，且成功/失败读得出来", () => {
  const { heroId, foeId, w } = mkWorld({ range: 0.5 });
  const o = executeIntent(w, atk(heroId, foeId, 4));
  const texts = [
    intentText(o.intent),
    outcomeText(o),
    intentText({ kind: "pickup", actor: 1, tick: 0, origin: "replay", radius: 2 }),
  ];
  for (const s of texts) {
    assert.equal(isAscii(s), true, `文案里有非 ASCII：${s}`);
    assert.equal(s.length > 0, true);
  }
  assert.equal(outcomeText(o).includes(COMBAT_OUT_OF_RANGE), true, "失败文案要带码");
  assert.equal(outcomeText(o).includes("retry"), true, "失败文案要带判定");
});

// ---------------------------------------------------------------- 共用（两条真实路径）

function makeCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  } as unknown as ModuleContext;
}

test("[动作意图] ★ 友伤拦截在**执行器**里：玩家与 AI 共用那一份规则", () => {
  const { scene, heroId, foeId, w } = mkWorld();
  // 两只同队 ⇒ `attack()` 的友伤拦截必须生效（执行器透传了 factions）
  const a = new FactionMember();
  a.team = "hunter";
  const b = new FactionMember();
  b.team = "hunter";
  scene.attach(heroId, () => a);
  scene.attach(foeId, () => b);
  scene.flush();

  const o = executeIntent({ ...w, factions: createFactions() }, atk(heroId, foeId));
  assert.equal(o.ok, false);
  assert.equal(o.code, "COMBAT.FRIENDLY_FIRE");
  assert.equal(o.verdict, "fatal", "友军挡着 ⇒ 换目标，不是「等一等就能打」");
  assert.equal(scene.find(foeId)?.get<Health>(HEALTH_TYPE)?.hp, 10, "友伤被拦下却掉了血");
});

test("[动作意图] ★ AI 侧真的走执行器：combat-module 每次尝试都回报（含失败）", () => {
  // 够不着：必须报出来（`onHit` 只在命中时回调，用它会永远收不到"没做成"）
  const far = mkWorld({ range: 0.5 });
  const seenA: Array<{ ok: boolean; code: string; verdict: string }> = [];
  const modA = createCombatModule({
    decide: () => far.foeId,
    onAttempt: (i) => seenA.push({ ok: i.ok, code: i.code, verdict: i.verdict }),
  });
  assert.equal((modA.init(makeCtx(far.scene)) as { ok: boolean } | undefined)?.ok, true);
  modA.update(1, 1 / 30);
  assert.equal(seenA.length, 1, "够不着也要报一次");
  assert.deepEqual([seenA[0]?.ok, seenA[0]?.code, seenA[0]?.verdict], [false, COMBAT_OUT_OF_RANGE, "retry"]);
  assert.equal(modA.stats.outOfRange, 1, "统计口径不能因为改走执行器就变");

  // 够得着：报 ok，并且 stats.hits 照涨
  const near = mkWorld({ range: 2 });
  const seenB: Array<{ ok: boolean; code: string; verdict: string }> = [];
  const modB = createCombatModule({
    decide: () => near.foeId,
    onAttempt: (i) => seenB.push({ ok: i.ok, code: i.code, verdict: i.verdict }),
  });
  assert.equal((modB.init(makeCtx(near.scene)) as { ok: boolean } | undefined)?.ok, true);
  modB.update(1, 1 / 30);
  assert.deepEqual([seenB[0]?.ok, seenB[0]?.code, seenB[0]?.verdict], [true, INTENT_OK, "ok"]);
  assert.equal(modB.stats.hits, 1);
  assert.equal(near.foeHp.hp, 8, "AI 那一刀要真的扣血");
});
