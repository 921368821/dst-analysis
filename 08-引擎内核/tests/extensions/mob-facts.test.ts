/**
 * L4 · 生物的黑板：**感知的产出是纯数据，决策只读这份数据**
 *
 * 这一批把 `MobBrain.decide` 拆成「读世界 → facts」与「facts → 决定」两半。
 * 下面九条判据守的就是这条分界线，其中最硬的两条是：
 *
 *  · **把世界拆掉，决策不变**（`chooseFromFacts` 不偷读场景）——
 *    这条不是洁癖：它一旦不成立，行为树接线、回放重算、调试面板就都得
 *    各自再抄一份「读世界」的代码，而三份读法迟早不一致。
 *  · **黑板过一遍 JSON 还能算出同一个决定**（纯数据、可存盘、可传网）。
 *
 * ★ 三条容易写成假绿的：
 *   ① 排序要放**同距离的两个候选**。距离全不同时，「按距离排」与「按插入序排」
 *      结果一样 —— 而插入序正是这个仓库反复踩的那类隐性依赖。
 *   ② leash 边界要**正好等于**与**刚超出**各一次。只用「差得远」的语料时，
 *      `>` 写成 `>=` 完全看不出来。
 *   ③ grudge 的语料里必须放一个**更近的可见敌人**，否则「记仇优先」与
 *      「看见就近的」给出同一个答案。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { Attacker, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { FactionMember, createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { createThreatTable } from "../../src/extensions/combat/threat.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import {
  chooseFromFacts,
  type MobFacts,
  type MobGrid,
} from "../../src/extensions/mobs/mob-facts.ts";
import { createMobBrain, type Decision } from "../../src/extensions/mobs/mob-brain.ts";

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
  return new Scene("facts", reg);
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

function factsOf(brain: ReturnType<typeof createMobBrain>, id: number): MobFacts {
  const f = brain.facts(id);
  assert.ok(f !== undefined, "刚 decide 过的生物必须有当拍事实");
  return f;
}

test("[黑板] ★ 把世界拆掉，决策不变（决策函数不偷读场景）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  const prey = unit(scene, "rabbit", 12.5, 10.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });

  const before = brain.decide(scene, me, 1, rectGrid());
  assert.equal(before?.targetNodeId, prey, "前置条件：它本来在追那只兔子");
  const frozen = JSON.parse(JSON.stringify(factsOf(brain, me))) as MobFacts;

  // 世界全部消失：如果决策还依赖场景，这一步之后答案一定变
  scene.destroy(prey);
  scene.destroy(me);
  scene.flush();
  assert.equal(scene.find(me), undefined, "前置条件：自己也没了");

  assert.deepEqual(chooseFromFacts(frozen), before, "决策必须只依赖黑板（否则回放/调试/行为树各要再读一遍世界）");
});

test("[黑板] 黑板过一遍 JSON 还是同一份事实、同一个决定（纯数据）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  unit(scene, "rabbit-a", 12.5, 10.5, "prey");
  unit(scene, "rabbit-b", 8.5, 10.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const d = brain.decide(scene, me, 3, rectGrid());
  const f = factsOf(brain, me);

  const round = JSON.parse(JSON.stringify(f)) as MobFacts;
  assert.deepEqual(round, f, "字段必须全是 JSON 能表达的基元/数组（放节点或组件会在这里露出来）");
  assert.deepEqual(chooseFromFacts(round), d, "同一份事实必须给同一个决定");
});

test("[黑板] 可见候选已过滤友军与超距，并按 (距离², 节点 id) 升序", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  // 先放远的：插入序与距离序**相反**，才可能在「按插入序」的实现下露出来
  const far = unit(scene, "rabbit-far", 14.5, 10.5, "prey"); // dx = 4
  const nearB = unit(scene, "rabbit-near-b", 8.5, 10.5, "prey"); // dx = -2
  const nearA = unit(scene, "rabbit-near-a", 12.5, 10.5, "prey"); // dx = 2
  const friend = unit(scene, "hound-b", 11.5, 10.5, "hunter"); // 最近，但是友军
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  brain.decide(scene, me, 1, rectGrid());
  const f = factsOf(brain, me);

  const ids = f.visible.map((c) => c.nodeId);
  assert.deepEqual(ids, [nearB, nearA, far], "同距离两个候选必须按节点 id 升序（只按距离排会让顺序取决于遍历序）");
  assert.equal(
    ids.includes(friend),
    false,
    "友军必须在感知阶段就被滤掉 —— 留给决策去筛，同一份黑板喂给玩家控制的角色时行为会不同",
  );
  assert.equal(f.visible.length, 3);
});

test("[黑板] leash 边界：正好 4.0 格保留，4.5 格排除", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 2.5, 2.5, "hunter");
  const edge = unit(scene, "rabbit-edge", 6.5, 2.5, "prey"); // dx = 4.0 ⇒ dist² = 16
  unit(scene, "rabbit-out", 7.0, 2.5, "prey"); // dx = 4.5 ⇒ dist² = 20.25
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20, leashCells: 4 });
  const d = brain.decide(scene, me, 1, rectGrid());

  assert.deepEqual(factsOf(brain, me).visible.map((c) => c.nodeId), [edge], "`>` 写成 `>=` 会把正好在边界上的那只也丢掉");
  assert.equal(d?.targetNodeId, edge);
  assert.equal(d?.cell, 2 * 60 + 6, "目标格是它在的那一格");
});

test("[黑板] reason 三分类：记仇优先于看见（哪怕看见的那个更近）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  const closeFoe = unit(scene, "rabbit-close", 11.5, 10.5, "prey"); // 1 格
  const farFoe = unit(scene, "rabbit-far", 18.5, 10.5, "prey"); // 8 格（感知半径 5 之外）
  const threat = createThreatTable({ decayTicks: 100 });
  // 远的那只打过我一次 ⇒ 记仇；近的那只只是被看见
  assert.equal(threat.add(me, farFoe, 5, 0).ok, true);

  const withGrudge = createMobBrain({ factions: FOE_TABLE(), range: 5, threat });
  const d = withGrudge.decide(scene, me, 1, rectGrid());
  assert.equal(d?.reason, "grudge");
  assert.equal(d?.targetNodeId, farFoe, "记仇必须压过「更近的那个」—— 否则「打了就跑」依然逃得掉");
  assert.notEqual(d?.targetNodeId, closeFoe);

  const sightOnly = createMobBrain({ factions: FOE_TABLE(), range: 5 });
  assert.equal(sightOnly.decide(scene, me, 1, rectGrid())?.reason, "sight");

  const peaceful = mkScene();
  const alone = unit(peaceful, "rabbit", 30.5, 30.5, "prey", { armed: false });
  assert.equal(
    createMobBrain({ factions: FOE_TABLE(), range: 5 }).decide(peaceful, alone, 1, rectGrid())?.reason,
    "wander",
  );
});

test("[黑板] 感知是纯读：decide 前后场景逐字节相等", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  unit(scene, "rabbit", 12.5, 10.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const before = sceneToJson(saveScene(scene));
  brain.decide(scene, me, 1, rectGrid());
  brain.decide(scene, me, 2, rectGrid());
  assert.equal(sceneToJson(saveScene(scene)), before, "感知顺手写了世界（朝向、缓存字段）—— 那会让「同种子同世界」悄悄失效");
});

test("[黑板] 和平生物：不感知、候选为空、事实里 aggressive=false", () => {
  const scene = mkScene();
  const me = unit(scene, "rabbit", 10.5, 10.5, "prey", { armed: false });
  unit(scene, "hound", 11.5, 10.5, "hunter");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const d = brain.decide(scene, me, 1, rectGrid());
  const f = factsOf(brain, me);

  assert.equal(f.aggressive, false);
  assert.deepEqual(f.visible, [], "和平生物不该有候选（它连感知都没做）");
  assert.equal(brain.senseCount, 0, "和平生物每一 tick 都白扫一遍全树是最贵的一种浪费");
  assert.equal(d?.reason, "wander");
});

test("[黑板] 事实是当拍的：下一拍没重新感知前查不到旧事实", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  const prey = unit(scene, "rabbit", 12.5, 10.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const grid = rectGrid();

  brain.decide(scene, me, 1, grid);
  const t1 = factsOf(brain, me);
  assert.equal(t1.tick, 1);
  assert.equal(t1.visible[0]?.dist2, 4);

  // 猎物挪远（同一 tick 再问：缓存必须原样返回，不能偷看新位置）
  const moved = scene.find(prey);
  assert.ok(moved !== undefined);
  moved.setLocalPosition(20.5, 10.5);
  scene.flush();
  assert.equal(factsOf(brain, me).visible[0]?.dist2, 4, "同一 tick 内事实必须冻结（否则 move 与 combat 会用到两份世界）");

  brain.decide(scene, me, 2, grid);
  assert.equal(factsOf(brain, me).visible[0]?.dist2 ?? -1, 100, "下一拍必须重新读世界");
});

test("[黑板] 找不到自己 / 不在地图上：决策是 null，而不是沿着上一格继续走", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", -8.5, 10.5, "hunter"); // 网格外
  unit(scene, "rabbit", 2.5, 2.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 3 });
  const d: Decision | null = brain.decide(scene, me, 1, rectGrid());
  assert.equal(d, null);
  assert.equal(factsOf(brain, me).selfCell, -1);

  // 与自己都不存在时同样为 null（不是抛异常、不是返回上一拍的决定）
  assert.equal(brain.decide(scene, 999999, 1, rectGrid()), null);
  assert.equal(brain.facts(999999)?.selfCell, -1);
});

// ==================== 手写黑板的判据（纯函数化的直接红利） ====================
//
// ★ 上面每条判据都要先把世界摆成那个局面；有两类局面**世界造不出来**：
//   ① 有仇人时感知被跳过（`sense` 里 `grudge !== null` 就不再看）⇒ 永远不会有
//      「既有仇人又有可见候选」的黑板；
//   ② `selfCell = -1` 时 `wanderTarget` 也返回 -1 ⇒ 「selfCell 坏了但 wander 格有效」
//      这种组合在真实世界不出现。
//   这两类偏偏正是**优先级的边界**。手写一份 facts 就能测 —— 这正是把决策写成
//   `facts → Decision` 纯函数的用处：判据不再受「世界能否造出这个局面」限制。

test("[黑板·手写] 既有仇人又看得见人：记仇优先（世界造不出这种黑板，手写一份）", () => {
  const f: MobFacts = {
    agentId: 2,
    tick: 1,
    selfCell: 610,
    aggressive: true,
    grudge: { nodeId: 4, cell: 618 },
    visible: [{ nodeId: 3, cell: 611, dist2: 1 }],
    wanderCell: -1,
  };
  const d = chooseFromFacts(f);
  assert.equal(d?.reason, "grudge", "记仇必须压过「更近的那个」—— 反过来「打了就跑」就失效了");
  assert.equal(d?.targetNodeId, 4);
  assert.equal(d?.cell, 618);
});

test("[黑板·手写] selfCell 坏了就是 null，哪怕漫游格是有效的", () => {
  const f: MobFacts = {
    agentId: 2,
    tick: 1,
    selfCell: -1,
    aggressive: false,
    grudge: null,
    visible: [],
    wanderCell: 7,
  };
  assert.equal(
    chooseFromFacts(f),
    null,
    "找不到自己的生物不该沿着「上一格推出来的格子」继续走 —— 那正是尸体还在走的形状",
  );
});
