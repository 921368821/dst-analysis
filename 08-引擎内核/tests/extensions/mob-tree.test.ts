/**
 * L4 · 生物的决策树：**「给角色配 AI」= 写一棵数据树**
 *
 * 这一批把 `MobBrain.decide` 的最后一句从 `chooseFromFacts(f)` 换成了
 * `MobTree.decide(f)`。下面十条判据守的是这次替换，其中三条是地基：
 *
 *  · **与规范逐条等价**：48 组事实 × `chooseFromFacts` 对账。
 *    没有这条，就分不清「树被改坏」与「规范被改坏」—— 两者都只表现为
 *    「这只怪的行为有点怪」，而那种描述没人能复现。
 *  · **换树就换行为**：给同一根大脑传另一棵树，决定跟着变。
 *    没有这条，「接线了」与「接线没生效、还在走老 if」完全不可分。
 *  · **树是瞬时的**：跑完 `memorySize() === 0`。非 0 意味着决定带上了
 *    **不在快照里的历史**，单机看不出来，回滚到 tick N 之后行为分叉。
 *    这一条配了一个**反向对照**（塞一个 `wait` 进去，`memorySize()` 必须变 1），
 *    否则「恒为 0」可能只是因为那个计数根本没人加。
 *
 * ★ 语言之外的一条：`move` / `combat` 两个模块每拍各问一次同一个决定，
 *   所以「同一 tick 问两次给两个答案」是这里最容易出的静默错 ——
 *   判据里有一条专门连问两次。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { Attacker, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { FactionMember, createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { createThreatTable } from "../../src/extensions/combat/threat.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { AiAgent, Board, bt, type AiNode, type AiOps } from "../../src/extensions/ai/behavior.ts";
import {
  chooseFromFacts,
  type MobCandidate,
  type MobFacts,
  type MobGrid,
  type MobGrudge,
} from "../../src/extensions/mobs/mob-facts.ts";
import { createMobBrain } from "../../src/extensions/mobs/mob-brain.ts";
import {
  K,
  MOB_OPS,
  MOB_TREE,
  OUT_HUNT,
  WHY,
  boardToDecision,
  createMobTree,
  writeFacts,
} from "../../src/extensions/mobs/mob-tree.ts";

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

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  return new Scene("tree", reg);
}

function unit(
  scene: Scene,
  name: string,
  x: number,
  z: number,
  team: string,
  opts: { armed?: boolean } = {},
): number {
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
  if (opts.armed !== false) {
    const a = new Attacker();
    a.damage = 1;
    a.range = 1.6;
    a.cooldownTicks = 10;
    scene.attach(id, () => a);
  }
  scene.flush();
  return id;
}

const FOE_TABLE = () => {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
};

/** 一份事实（缺省是「站在格子中间、凶、什么都没看见、无处漫游」）。 */
function factsOf(over: Partial<MobFacts> = {}): MobFacts {
  return {
    agentId: 2,
    tick: 1,
    selfCell: 610,
    aggressive: true,
    grudge: null,
    visible: [],
    wanderCell: -1,
    ...over,
  };
}

/**
 * 48 组事实：自己能不能定位 × 凶不凶 × 有没有仇人 × 看见几个 × 有没有漫游格。
 *
 * ★ 其中两组世界**造不出来**（`!aggressive` 却有仇人 / `selfCell < 0` 却有漫游格），
 *   因为感知在没有攻击组件时根本不查仇恨表、`wanderTarget` 在 `selfCell < 0` 时返回 -1。
 *   但「树与规范等价」必须覆盖它们 —— 树是被人改的，改坏之后恰恰容易在那两条边界上分叉。
 */
function* corpus(): Generator<MobFacts> {
  const selves = [610, -1];
  const aggro = [true, false];
  const grudges: (MobGrudge | null)[] = [null, { nodeId: 4, cell: 618 }];
  const visibles: MobCandidate[][] = [
    [],
    [{ nodeId: 3, cell: 611, dist2: 1 }],
    [
      { nodeId: 3, cell: 611, dist2: 1 },
      { nodeId: 5, cell: 607, dist2: 9 },
    ],
  ];
  const wanders = [7, -1];
  for (const selfCell of selves) {
    for (const aggressive of aggro) {
      for (const grudge of grudges) {
        for (const visible of visibles) {
          for (const wanderCell of wanders) {
            yield factsOf({ selfCell, aggressive, grudge, visible, wanderCell });
          }
        }
      }
    }
  }
}

function labelOf(f: MobFacts): string {
  return `self=${String(f.selfCell)} 凶=${String(f.aggressive)} 仇人=${String(f.grudge !== null)} 看见=${String(f.visible.length)} 漫游=${String(f.wanderCell)}`;
}

test("[树] ★ 与规范逐条等价：48 组事实，树给出的决定与 chooseFromFacts 完全一致", () => {
  const tree = createMobTree();
  let n = 0;
  for (const f of corpus()) {
    const want = chooseFromFacts(f);
    const got = tree.decide(f);
    assert.deepEqual(got, want, `${labelOf(f)} —— 树算的和规范不一样`);
    n++;
  }
  assert.equal(n, 48, "语料条数变了就要重新核对覆盖（这个数字是「覆盖了几种组合」的唯一证据）");
});

test("[树] ★ 换树就换行为：同一根大脑传另一棵树，决定跟着变（证明接线真的生效）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  const farFoe = unit(scene, "rabbit-far", 18.5, 10.5, "prey");
  const threat = createThreatTable({ decayTicks: 100 });
  assert.equal(threat.add(me, farFoe, 5, 0).ok, true);

  const byDefault = createMobBrain({ factions: FOE_TABLE(), range: 5, threat }).decide(
    scene,
    me,
    1,
    rectGrid(),
  );
  assert.equal(byDefault?.reason, "grudge", "前置条件：默认树应该在追那个打过它的人");
  assert.equal(byDefault?.targetNodeId, farFoe);

  // 一棵「不看事实、永远下令去第 42 格打 999 号」的树 + 它自己的 op
  const customOps: AiOps = {
    ...MOB_OPS,
    "test.alwaysCell": (ctx) => {
      ctx.board.set(K.outKind, OUT_HUNT);
      ctx.board.set(K.outTarget, 999);
      ctx.board.set(K.outCell, 42);
      ctx.board.set(K.outReason, WHY.sight);
      return "success";
    },
  };
  const customTree = bt.sequence("test.root", bt.do("test.always", "test.alwaysCell"));

  const swappedBrain = createMobBrain({
    factions: FOE_TABLE(),
    range: 5,
    threat,
    tree: customTree,
    ops: customOps,
  });
  const swapped = swappedBrain.decide(scene, me, 1, rectGrid());

  assert.deepEqual(
    swapped,
    { kind: "hunt", targetNodeId: 999, cell: 42, reason: "sight" },
    "换了树还是按老规矩办事 ⇒ 接线没生效（`decide` 里还留着 `chooseFromFacts`）",
  );
  assert.equal(swappedBrain.tree, customTree, "面板/编辑器读的是这个 getter：它要显示「这只怪在跑哪棵树」");
  assert.equal(createMobBrain({ factions: FOE_TABLE(), range: 5 }).tree, MOB_TREE, "缺省必须是 MOB_TREE");
});

test("[树] ★ 决策树是瞬时的：跑完不留 running，连问两次给同一个答案", () => {
  const tree = createMobTree();
  for (const f of corpus()) {
    const a = tree.decide(f);
    assert.equal(tree.memorySize(), 0, `${labelOf(f)} —— 树留了记忆，决定就带上了不在快照里的历史`);
    const b = tree.decide(f);
    assert.deepEqual(b, a, `${labelOf(f)} —— 同一份事实连问两次答案不同（move 与 combat 会各拿到一个）`);
  }

  // 反向对照：塞一个 wait 进去，计数必须真的动。没有这条，「恒为 0」可能只是没人加过
  const waiting = createMobTree({ tree: bt.wait("w.w", 5) });
  waiting.decide(factsOf());
  assert.equal(waiting.memorySize(), 1, "memorySize 数不出 running ⇒ 上面那些 0 一个都不能算证据");
});

test("[树] 主体是纯数据：过一遍 JSON 还是同一棵树、同一个决定", () => {
  const round = JSON.parse(JSON.stringify(MOB_TREE)) as AiNode;
  assert.deepEqual(round, MOB_TREE, "树里出现了函数/引用 ⇒ 存不了档、进不了指纹、编辑器也导不出");
  const a = createMobTree();
  const b = createMobTree({ tree: round });
  for (const f of corpus()) {
    assert.deepEqual(b.decide(f), a.decide(f), `${labelOf(f)} —— JSON 往返之后的树行为变了`);
  }
});

test("[树] 坏树在构造期就抛，不等到第 500 拍那只怪走到那条分支", () => {
  const cases: readonly { readonly name: string; readonly tree: AiNode; readonly code: string }[] = [
    { name: "未知 op", tree: bt.sequence("e1", bt.do("e1.d", "nope.notRegistered")), code: "AI.UNKNOWN_OP" },
    { name: "重复 id", tree: bt.sequence("dup", bt.check("dup", "mob.canDecide")), code: "AI.DUPLICATE_ID" },
    {
      name: "wait 缺 ticks",
      tree: { id: "w", kind: "wait" },
      code: "AI.BAD_TREE",
    },
  ];
  for (const c of cases) {
    assert.throws(
      () => createMobTree({ tree: c.tree }),
      (e: unknown) =>
        e instanceof RangeError && e.message.includes("MOB.BAD_TREE") && e.message.includes(c.code),
      `${c.name} 必须当场抛（带上 ${c.code}），而不是建出一个跑起来才炸的树`,
    );
  }
});

test("[黑板] 事实→板→JSON→决定：板上全是有限整数，决定与规范一致", () => {
  const f = factsOf({ grudge: { nodeId: 4, cell: 618 }, visible: [{ nodeId: 3, cell: 611, dist2: 4 }] });
  const board = writeFacts(new Board(), f);
  const created = AiAgent.create(MOB_TREE, MOB_OPS);
  assert.equal(created.ok, true);
  if (!created.ok) return;
  created.value.step({ tick: f.tick, board });

  const snap = board.snapshot();
  for (const [k, v] of Object.entries(snap)) {
    assert.equal(Number.isFinite(v), true, `键「${k}」不是有限数（${String(v)}）—— 板只能放数字`);
  }

  const back = new Board();
  for (const [k, v] of Object.entries(JSON.parse(JSON.stringify(snap)) as Record<string, number>)) back.set(k, v);
  const fromJson = boardToDecision(back);
  assert.deepEqual(fromJson, chooseFromFacts(f), "板过一遍 JSON 之后决定变了 ⇒ 板不是纯数据");
  assert.equal(fromJson?.reason, "grudge");
});

test("[黑板] ★ 树上读的每个键，写板的那一步都必须先写过", () => {
  // ★ 这条抓的是「op 读了一个没人写的键」：`Board.get` 对缺键返回 0，
  //   于是那条分支静默走不到（或永远走得到），而所有「结果一致」的判据照样绿。
  class SpyBoard extends Board {
    readonly reads = new Set<string>();
    override get(key: string): number {
      this.reads.add(key);
      return super.get(key);
    }
  }

  const spy = new SpyBoard();
  const created = AiAgent.create(MOB_TREE, MOB_OPS);
  assert.equal(created.ok, true);
  if (!created.ok) return;

  for (const f of corpus()) {
    writeFacts(spy, f);
    created.value.step({ tick: f.tick, board: spy });
  }

  const written = new Set<string>(Object.values(K));
  const unknown = [...spy.reads].filter((k) => !written.has(k));
  assert.deepEqual(unknown, [], `这些键被树读了，但 writeFacts 从来不写（读到的永远是 0）：${unknown.join(",")}`);

  // 反向：九个输入键必须**真的被读过**。少了谁就说明那条分支是死的（或键名写错了）
  const inputs = [
    K.selfCell,
    K.aggressive,
    K.grudgeHas,
    K.grudgeNode,
    K.grudgeCell,
    K.visibleCount,
    K.visibleNode,
    K.visibleCell,
    K.wanderCell,
  ];
  const neverRead = inputs.filter((k) => !spy.reads.has(k));
  assert.deepEqual(neverRead, [], `这些输入键写了却从来没人读 —— 对应的分支是死的：${neverRead.join(",")}`);
});

test("[黑板] 复用一块板：自定义 op 的临时键不会带进下一次决定", () => {
  // 一个 `MobBrain` 服务世界里**全部**生物，板是复用的。自定义 op 往板上写的
  // 临时键没人覆盖 ⇒ 下一位生物会读到上一位留下的东西。`writeFacts` 先 clear 才挡得住。
  // ★ op 只在**第一拍**写临时键：每拍都写的话，第二拍残留与「写」不可分，这条判据就废了
  let calls = 0;
  const ops: AiOps = {
    ...MOB_OPS,
    "test.scratch": (ctx) => {
      if (calls++ === 0) ctx.board.set("test.scratch", 7);
      return "success";
    },
  };
  const tree = createMobTree({
    tree: bt.sequence(
      "s.root",
      bt.check("s.sane", "mob.canDecide"),
      bt.do("s.d", "test.scratch"),
      bt.do("s.go", "mob.wander"),
    ),
    ops,
  });

  assert.equal(tree.decide(factsOf({ wanderCell: 9 }))?.cell, 9, "前置：这棵自定义树只会漫游");
  assert.equal(
    Object.prototype.hasOwnProperty.call(tree.boardSnapshot(), "test.scratch"),
    true,
    "前置：第一拍确实写了临时键（不写的话下面那条判据等于没测）",
  );

  assert.equal(tree.decide(factsOf({ wanderCell: 7 }))?.cell, 7);
  assert.equal(
    Object.prototype.hasOwnProperty.call(tree.boardSnapshot(), "test.scratch"),
    false,
    "writeFacts 没有清空板 ⇒ 上一位生物的临时键还在（症状：一群怪用同一条数据做决定）",
  );
});

test("[黑板] ★ 追猎的节点与格子必须来自同一条候选（内容层，不是计数层）", () => {
  const tree = createMobTree();
  const grudge = { nodeId: 4, cell: 618 };
  const near = { nodeId: 3, cell: 611, dist2: 1 };
  const far = { nodeId: 5, cell: 607, dist2: 9 };

  const byGrudge = tree.decide(factsOf({ grudge, visible: [near, far] }));
  assert.deepEqual(byGrudge, { kind: "hunt", targetNodeId: 4, cell: 618, reason: "grudge" });

  const bySight = tree.decide(factsOf({ visible: [near, far] }));
  assert.deepEqual(
    bySight,
    { kind: "hunt", targetNodeId: 3, cell: 611, reason: "sight" },
    "四个数字必须两两配对：id 取一个候选、格子取另一个的话，怪会朝 A 的格子打 B",
  );
});

test("[黑板] 真实世界里三条 reason 都到得了（没有永远走不到的分支）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  const closeFoe = unit(scene, "rabbit-close", 11.5, 10.5, "prey");
  const farFoe = unit(scene, "rabbit-far", 18.5, 10.5, "prey");
  const threat = createThreatTable({ decayTicks: 100 });
  assert.equal(threat.add(me, farFoe, 5, 0).ok, true);

  const seen = new Set<string>();
  const grudgeBrain = createMobBrain({ factions: FOE_TABLE(), range: 5, threat });
  const d1 = grudgeBrain.decide(scene, me, 1, rectGrid());
  assert.equal(d1?.reason, "grudge");
  assert.equal(d1?.targetNodeId, farFoe, "记仇压过更近的那只（「打了就跑」得追得上）");
  assert.notEqual(d1?.targetNodeId, closeFoe);
  seen.add(d1?.reason ?? "?");

  const sightBrain = createMobBrain({ factions: FOE_TABLE(), range: 5 });
  const d2 = sightBrain.decide(scene, me, 1, rectGrid());
  assert.equal(d2?.reason, "sight");
  assert.equal(d2?.targetNodeId, closeFoe);
  seen.add(d2?.reason ?? "?");

  // ★ 凶但眼前什么都没有：树必须落到漫游分支（这条是「aggressive 有值但看见为空」的唯一覆盖）
  const quiet = mkScene();
  const alone = unit(quiet, "hound", 30.5, 30.5, "hunter");
  const roamBrain = createMobBrain({ factions: FOE_TABLE(), range: 5 });
  const d3 = roamBrain.decide(quiet, alone, 1, rectGrid());
  assert.equal(d3?.reason, "wander");
  assert.ok((d3?.cell ?? -1) >= 0, "漫游必须给出一个真的格子");
  seen.add(d3?.reason ?? "?");

  assert.deepEqual([...seen].sort(), ["grudge", "sight", "wander"], "三条分支必须各有一条真实世界的入口");

  // 树的瞬时性在**每一条**入口上都成立（不只是手工语料）
  for (const b of [grudgeBrain, sightBrain, roamBrain]) assert.equal(b.treeMemory(), 0);
});
