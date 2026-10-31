/**
 * L4 · 结果回报：执行层把「这一拍做成了没有」送回决策层
 *
 * 批158 之前，树的输入只有**世界**（看得见谁、有仇吗、往哪走）。
 * 它知道自己想打谁，但不知道**上一次打没打成** —— 于是"打不到就换目标"
 * 这类玩法在树里根本写不出来，只能写死在代码的 `if` 里。
 *
 * 这一批开了一条单向通道：
 *
 * ```
 * combat-module（每次尝试） → MobBrain.noteOutcome → 下一拍的 MobFacts → 黑板 → 树
 * ```
 *
 * ★ 五条地基：
 *  · **结果真的能改行为**：手写一棵树，`mob.lastFailed` 成立时不追。只断言
 *    "facts 里有个字段"是不够的 —— 那证明的是"存进去了"，不是"用得上"。
 *  · **retry 也算没做成**：射程不够这一拍不成，下一拍照样追（那是追的过程），
 *    但树要知道"还没到"。只判 `fatal` 的实现在"够不着"的语料上完全正常。
 *  · **只认紧邻的上一拍**：读档 / 回滚之后 tick 会跳，陈旧结果比没有结果更坏。
 *  · **默认树不受影响**：这条通道开的是能力，不是玩法 —— 默认树不挂它，
 *    所以所有既有判据的决定必须一模一样。
 *  · **`sense()` 一定带这两个字段**：可选字段的代价是"忘填也不报错"，
 *    用一条判据把那一步补回来。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { Board, bt } from "../../src/extensions/ai/behavior.ts";
import { Attacker, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { FactionMember, createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { createMobBrain } from "../../src/extensions/mobs/mob-brain.ts";
import type { MobFacts, MobGrid } from "../../src/extensions/mobs/mob-facts.ts";
import { K, LAST, MOB_OPS, createMobTree, writeFacts } from "../../src/extensions/mobs/mob-tree.ts";
import { TreeLibrary } from "../../src/extensions/mobs/tree-library.ts";
import { AIConfig, registerAiConfig } from "../../src/extensions/mobs/ai-config.ts";

const TREE_ID = "test:lastFailed";

/**
 * 一棵**会看结果**的树：上一拍没做成，这一拍就不追。
 *
 * ```
 * sequence 根
 *   check     能找到自己
 *   inverter  上一拍没失败（`mob.lastFailed` 取反）
 *   selector  追最近的
 * ```
 * 结果：上一拍 `ok` / 没做过 ⇒ 追；上一拍 `retry` / `fatal` ⇒ 整棵失败（这一拍不动）。
 */
function outcomeAware() {
  return bt.sequence(
    "o.root",
    bt.check("o.can", "mob.canDecide"),
    bt.inverter("o.fine", bt.check("o.lf", "mob.lastFailed")),
    bt.selector("o.sel", bt.sequence("o.hunt", bt.check("o.sees", "mob.seesFoe"), bt.do("o.do", "mob.huntNearest"))),
  );
}

function rectGrid(w = 60, h = 60): MobGrid {
  return {
    cellAt: (x, z) => {
      const cx = Math.floor(x);
      const cz = Math.floor(z);
      if (cx < 0 || cx >= w || cz < 0 || cz >= h) return -1;
      return cz * w + cx;
    },
    cellX: (i) => i % w,
    cellZ: (i) => (i - (i % w)) / w,
    isWalkable: (cx, cz) => cx > 0 && cx < w - 1 && cz > 0 && cz < h - 1,
  };
}

function registry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  registerLootComponent(reg);
  registerAiConfig(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

function factions() {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
}

function unit(scene: Scene, name: string, x: number, z: number, team: string, tree?: string): number {
  const n = scene.spawnAt(name, x, z);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const id = n.value.id;
  const h = new Health();
  h.hp = 5;
  h.maxHp = 5;
  scene.attach(id, () => h);
  const f = new FactionMember();
  f.team = team;
  scene.attach(id, () => f);
  if (team === "hunter") {
    const a = new Attacker();
    a.damage = 1;
    a.range = 1.6;
    a.cooldownTicks = 10;
    scene.attach(id, () => a);
  }
  if (tree !== undefined) {
    const c = new AIConfig();
    c.tree = tree;
    scene.attach(id, () => c);
  }
  scene.flush();
  return id;
}

interface Built {
  readonly scene: Scene;
  readonly brain: ReturnType<typeof createMobBrain>;
  readonly hound: number;
  readonly prey: number;
  readonly grid: MobGrid;
}

/** 一只猎狗 + 一只兔子，猎狗挂 `outcomeAware`。 */
function build(): Built {
  const scene = new Scene("outcome", registry());
  const lib = new TreeLibrary();
  const put = lib.put(TREE_ID, outcomeAware());
  assert.equal(put.ok, true, put.ok ? "" : `${put.error.code}: ${put.error.message}`);

  const prey = unit(scene, "prey", 11.5, 10.5, "prey");
  const hound = unit(scene, "hound", 10.5, 11.5, "hunter", TREE_ID);
  const brain = createMobBrain({ factions: factions(), range: 10, seed: 1, library: lib });
  return { scene, brain, hound, prey, grid: rectGrid() };
}

// ---------------------------------------------------------------- 纯函数层

test("[结果] ★ mob.lastFailed：retry 也算没做成（不只是 fatal）", () => {
  const board = new Board();
  const base: MobFacts = { agentId: 1, tick: 1, selfCell: 0, aggressive: true, grudge: null, visible: [], wanderCell: -1 };
  const op = MOB_OPS["mob.lastFailed"];
  assert.notEqual(op, undefined, "op 表里必须有它（否则手写树装不上）");

  for (const [verdict, expect] of [
    ["none", "failure"],
    ["ok", "failure"],
    ["retry", "success"],
    ["fatal", "success"],
  ] as const) {
    writeFacts(board, { ...base, lastVerdict: verdict });
    // `AiOp = (ctx: AiTick, node: AiNode) => Status`：第二个参数是"当前节点"，
    // check 类 op 用不到它，但签名要求给（`as never` 绕过去只会让 tsc 报错，不报错的是运行时）
    const got = op?.({ board, tick: 1 }, { id: "t", kind: "check", op: "mob.lastFailed" });
    assert.equal(got, expect, `lastVerdict=${verdict} 时 mob.lastFailed 应为 ${expect}`);
  }
});

test("[结果] writeFacts 把结果按 LAST 码写进板（`none` 也有值，不是缺键）", () => {
  const board = new Board();
  const f: MobFacts = {
    agentId: 7,
    tick: 3,
    selfCell: 1,
    aggressive: true,
    grudge: null,
    visible: [],
    wanderCell: -1,
    lastVerdict: "fatal",
    lastTarget: 42,
  };
  writeFacts(board, f);
  assert.equal(board.get(K.lastVerdict), LAST.fatal);
  assert.equal(board.get(K.lastTarget), 42);
  // 缺省（手写夹具没填）要落到 none，而不是读到上一只生物留下的值
  writeFacts(board, { ...f, lastVerdict: undefined, lastTarget: undefined });
  assert.equal(board.get(K.lastVerdict), LAST.none);
  assert.equal(board.get(K.lastTarget), -1);
});

// ---------------------------------------------------------------- 真的能改行为

test("[结果] ★ 上一拍 fatal ⇒ 这棵树不追（结果真的回到了决策层）", () => {
  // ★ 两组夹具必须各用**自己的 brain**：同一个 brain 在同一 tick 会复用事实缓存，
  //   第二组拿到的还是第一组那份「没有结果」的 facts —— 判据就成了"验了第一次"。
  const a = build();
  const clean = a.brain.decide(a.scene, a.hound, 1, a.grid);
  assert.equal(clean?.kind, "hunt", "夹具前提：没有结果时这棵树会追");
  assert.equal(clean?.targetNodeId, a.prey);

  const b = build();
  b.brain.noteOutcome(b.hound, "fatal", b.prey, 0); // 上一拍 = tick 0
  assert.equal(b.brain.decide(b.scene, b.hound, 1, b.grid), null, "上一拍没做成，这一拍还在追 ⇒ 结果没进到决策里");
});

test("[结果] ★ 上一拍 retry（够不着）也让它这拍不动 —— 只判 fatal 的实现会漏", () => {
  const { scene, brain, hound, prey, grid } = build();
  brain.noteOutcome(hound, "retry", prey, 0);
  assert.equal(brain.decide(scene, hound, 1, grid), null);
});

test("[结果] 上一拍 ok ⇒ 照常追（结果是能力，不是刹车）", () => {
  const { scene, brain, hound, prey, grid } = build();
  brain.noteOutcome(hound, "ok", prey, 0);
  const d = brain.decide(scene, hound, 1, grid);
  assert.equal(d?.kind, "hunt");
  assert.equal(d?.targetNodeId, prey);
});

// ---------------------------------------------------------------- 紧邻规则

test("[结果] ★ 只认紧邻的上一拍：中间隔了一拍就作废（读档 / 回滚之后不带陈旧结果）", () => {
  const { scene, brain, hound, prey, grid } = build();
  brain.noteOutcome(hound, "fatal", prey, 10);
  // 紧邻：11 拍读得到
  brain.decide(scene, hound, 11, grid);
  assert.equal(brain.facts(hound)?.lastVerdict, "fatal");
  // 跳拍：12 拍（隔了 2 拍）读不到
  brain.decide(scene, hound, 12, grid);
  assert.equal(brain.facts(hound)?.lastVerdict, "none", "陈旧结果必须作废 —— 否则树对着早就变了的局面做决定");
  assert.equal(brain.facts(hound)?.lastTarget, -1);
});

test("[结果] 早于当前拍的结果（未来 / 同拍重放）不算「上一拍」", () => {
  const { scene, brain, hound, prey, grid } = build();
  // 同拍：结果发生在 tick 5，当前也是 tick 5 —— 不是"上一拍"
  brain.noteOutcome(hound, "fatal", prey, 5);
  brain.decide(scene, hound, 5, grid);
  assert.equal(brain.facts(hound)?.lastVerdict, "none");
});

// ---------------------------------------------------------------- 契约与不回归

test("[结果] ★ sense() 产出的 facts 一定带这两个字段（可选字段的代价由这条补回来）", () => {
  const { brain, hound, grid, scene } = build();
  brain.decide(scene, hound, 1, grid);
  const f = brain.facts(hound);
  assert.notEqual(f, undefined);
  assert.notEqual(f?.lastVerdict, undefined, "`sense` 忘了填 lastVerdict（可选字段不报错，只能靠判据）");
  assert.notEqual(f?.lastTarget, undefined);
});

test("[结果] ★ 默认树不挂 mob.lastFailed：结果不会偷偷改掉既有玩法", () => {
  const scene = new Scene("outcome-default", registry());
  const prey = unit(scene, "prey", 11.5, 10.5, "prey");
  const hound = unit(scene, "hound", 10.5, 11.5, "hunter");
  const brain = createMobBrain({ factions: factions(), range: 10, seed: 1 });
  const grid = rectGrid();

  const clean = brain.decide(scene, hound, 1, grid);
  brain.noteOutcome(hound, "fatal", prey, 1);
  const after = brain.decide(scene, hound, 2, grid);

  assert.equal(brain.facts(hound)?.lastVerdict, "fatal", "夹具前提：结果确实进了事实");
  assert.equal(clean?.kind, "hunt");
  assert.equal(after?.kind, "hunt", "默认树没有读 lastFailed —— 行为必须与批158 之前一样");
  assert.equal(after?.targetNodeId, prey);
});

test("[结果] 手写树能通过装载路径；op 名拼错则**构造期**就抛（不是某一拍才炸）", () => {
  assert.equal(createMobTree({ tree: outcomeAware() }).tree.id, "o.root");
  const typo = bt.sequence("t.root", bt.check("t.c", "mob.lastFaild"));
  assert.throws(
    () => createMobTree({ tree: typo }),
    "拼错的 op 必须当场拒 —— 拖到某一拍才炸的话，那只怪会在第 N 拍突然不动，而没人知道为什么",
  );
});
