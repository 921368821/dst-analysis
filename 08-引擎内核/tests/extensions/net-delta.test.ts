/**
 * L4 · 增量快照的口径与合成（批160）
 *
 * ★ 这份判据要回答的是「哪些字段算变化量、合回去还是不是同一个世界」，
 *   而不是「diff 函数的实现对不对」。所以核心是三条：
 *
 *   ① **合成 == 全量**：`applyDelta(prev, diff(prev, next))` 序列化之后与 `next`
 *      **逐字节**相同。这一条松了，客户端的副本会在某个字段上悄悄停在旧值 ——
 *      而「位置都对、只有朝向不对」这种偏差，任何终态判据都抓不到。
 *   ② **没变就不发**：量化噪声（`0.30000000000000004`）不算变化，否则增量每拍都非空，
 *      带宽优化归零，而日志上只是「优化没效果」。
 *   ③ **变了就发全**：十个顶层字段逐个试一遍。漏一个的症状是「客户端那个字段永远
 *      不更新」，而其余九个都对 —— 这类漏项在用手写的两份字段表时是必然发生的，
 *      所以字段表只允许有一份（`NODE_FIELDS`），这里逐个钉住。
 *
 * ★ 语料全部自己造（不借 `net-session` 的场景）：那边一改动，这边的分辨力就跟着变。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { sceneToJson, type SceneSnapshot } from "../../src/core/scene/scene-io.ts";
import { MOVER_TYPE, Mover, registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { NET_IDENTITY_TYPE, NetIdentity, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import {
  DELTA_FORMAT_VERSION,
  NODE_FIELDS,
  applyDelta,
  deltaFromJson,
  deltaIsEmpty,
  deltaToJson,
  diffSnapshot,
  snapshotOfScene,
} from "../../src/extensions/net/delta.ts";

// ---------------------------------------------------------------- 语料

interface World {
  readonly scene: Scene;
}

function world(name = "main"): World {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  registerNetIdentity(reg);
  registerMoverComponent(reg);
  return { scene: new Scene(name, reg) };
}

function spawnPlayer(scene: Scene, owner: number, id: number): number {
  const n = scene.spawnImmediate("player", scene.rootId, id);
  scene.attach(n.id, () => new PlayerController());
  scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  scene.flush();
  return n.id;
}

function spawnMob(scene: Scene, id: number): number {
  const n = scene.spawnImmediate("mob", scene.rootId, id);
  scene.attach(n.id, () => new Mover());
  scene.flush();
  return n.id;
}

function snapOf(scene: Scene): SceneSnapshot {
  return snapshotOfScene(scene);
}

function jsonOf(snap: SceneSnapshot): string {
  return sceneToJson(snap);
}

// ---------------------------------------------------------------- 1 · 口径：什么算变化

test("[增量] 量化噪声不算变化（1e-9 之下相同 ⇒ 空增量）", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const node = w.scene.find(p);
  assert.ok(node !== undefined);

  const before = snapOf(w.scene);
  // ★ 真实的形状：定点累加出来的尾巴（`0.1 + 0.2` 那种）。序列化时被抹平，
  //   所以它对「客户端的副本」没有任何影响 —— 判成变化就是白花带宽。
  const x = node.localPosition.x;
  node.setLocalPosition(x + 1e-12, node.localPosition.y);
  const after = snapOf(w.scene);

  const d = diffSnapshot(before, after);
  assert.equal(deltaIsEmpty(d), true, "1e-12 的变化量在 1e-9 的量化下是同一个数");
  assert.equal(d.patched.length, 0);
});

test("[增量] 组件里的浮点尾巴也不算变化（量化在组件数据上同样生效）", () => {
  const w = world();
  const mob = spawnMob(w.scene, 200);
  const mover = w.scene.find(mob)?.get<Mover>(MOVER_TYPE);
  assert.ok(mover !== undefined);
  const before = snapOf(w.scene);
  // ★ 组件字段是 `save()` 直接吐出来的原始 double。这里的量化漏了的话，
  //   任何「每拍被乘除一次」的组件字段（速度、冷却、耐久）都会让增量永远非空。
  mover.speed = 2.2 + 1e-12;
  const d = diffSnapshot(before, snapOf(w.scene));
  assert.equal(deltaIsEmpty(d), true);
});

test("[增量] 真的变了就发，而且只发变了的那几个字段", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const before = snapOf(w.scene);
  w.scene.find(p)?.setLocalPosition(1.5, -2.25);
  const after = snapOf(w.scene);

  const d = diffSnapshot(before, after);
  assert.equal(d.added.length, 0);
  assert.equal(d.removed.length, 0);
  assert.equal(d.patched.length, 1);
  const patch = d.patched[0];
  assert.ok(patch !== undefined);
  assert.equal(patch.id, p);
  assert.deepEqual(Object.keys(patch.fields).sort(), ["x", "y"], "只挪了位置，就只该发 x / y");
  assert.equal(patch.components, undefined, "位置变了不等于组件变了");
  assert.equal((patch.fields.x as number) > 0, true);
});

test("[增量] ★ 十个顶层字段逐个改一遍，每一个都要能自己出现", () => {
  // ★ 这条钉的是**字段表只有一份**：谁把某个字段从 `NODE_FIELDS` 里去掉，
  //   那个字段从此再也不会出现在增量里 —— 客户端那一个字段永远停在旧值，
  //   而其余九个都对，任何「位置一致」的判据都看不见。
  const cases: readonly (readonly [string, (w: World, id: number) => void])[] = [
    ["name", (w, id) => {
      const n = w.scene.find(id);
      assert.ok(n !== undefined);
      n.name = "renamed";
    }],
    ["parent", (w, id) => {
      const n = w.scene.find(id);
      const host = w.scene.spawnImmediate("holder", w.scene.rootId, 900);
      w.scene.flush();
      host.addChild(n!);
    }],
    ["x", (w, id) => w.scene.find(id)?.setLocalPosition(3, 0)],
    ["y", (w, id) => w.scene.find(id)?.setLocalPosition(0, 3)],
    ["rot", (w, id) => w.scene.find(id)?.setLocalRotation(0.5)],
    ["sx", (w, id) => w.scene.find(id)?.setLocalScale(2, 1)],
    ["sy", (w, id) => w.scene.find(id)?.setLocalScale(1, 2)],
    ["zIndex", (w, id) => {
      const n = w.scene.find(id);
      assert.ok(n !== undefined);
      n.zIndex = 7;
    }],
    ["active", (w, id) => {
      const n = w.scene.find(id);
      assert.ok(n !== undefined);
      n.active = false;
    }],
    ["layer", (w, id) => {
      const n = w.scene.find(id);
      assert.ok(n !== undefined);
      n.layer = 9;
    }],
  ];
  assert.equal(cases.length, NODE_FIELDS.length, "字段表加了字段就要在这里补一条语料");

  for (const [field, mutate] of cases) {
    const w = world();
    const p = spawnPlayer(w.scene, 0, 100);
    const before = snapOf(w.scene);
    mutate(w, p);
    const d = diffSnapshot(before, snapOf(w.scene));
    const patch = d.patched.find((x) => x.id === p);
    assert.ok(patch !== undefined, `改 ${field} 之后没有产生补丁`);
    assert.ok(
      Object.prototype.hasOwnProperty.call(patch.fields, field),
      `改 ${field} 之后补丁里没有这个字段（字段表漏了它？）`,
    );
    assert.equal(d.removed.length, 0, `改 ${field} 不该产生删除`);
  }
});

// ---------------------------------------------------------------- 2 · 组件

test("[增量] 组件变了整块重发，而且只发变的那一个", () => {
  const w = world();
  spawnPlayer(w.scene, 0, 100);
  const m = spawnMob(w.scene, 200);
  const mob = w.scene.find(m);
  assert.ok(mob !== undefined);
  const mover = mob.get<Mover>(MOVER_TYPE);
  assert.ok(mover !== undefined);

  const before = snapOf(w.scene);
  mover.speed = 9.5;
  const d = diffSnapshot(before, snapOf(w.scene));

  assert.equal(d.patched.length, 1, "只有那只怪变了");
  const patch = d.patched[0];
  assert.ok(patch !== undefined);
  assert.equal(patch.id, m);
  assert.deepEqual(Object.keys(patch.fields), [], "速度是组件的字段，不是节点的字段");
  assert.equal(patch.components?.length, 1, "变了的那一个组件整块重发");
  assert.equal(patch.components?.[0]?.type, MOVER_TYPE);
  assert.equal((patch.components?.[0]?.data as { speed: number }).speed, 9.5);
});

test("[增量] 删组件走 dropComponents（不是「没出现在 components 里」）", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const before = snapOf(w.scene);
  w.scene.detach(p, NET_IDENTITY_TYPE);
  w.scene.flush();
  const d = diffSnapshot(before, snapOf(w.scene));

  const patch = d.patched.find((x) => x.id === p);
  assert.ok(patch !== undefined);
  assert.deepEqual(patch.dropComponents, [NET_IDENTITY_TYPE]);
  assert.equal(patch.components, undefined, "删除不是「重发一个空组件」");
});

// ---------------------------------------------------------------- 3 · 增删节点

test("[增量] 删掉的节点进 removed（升序），并且不许只靠「没出现」推断", () => {
  const w = world();
  const a = spawnPlayer(w.scene, 0, 100);
  const b = spawnPlayer(w.scene, 1, 101);
  const before = snapOf(w.scene);
  w.scene.destroy(b);
  w.scene.destroy(a);
  w.scene.flush();
  const d = diffSnapshot(before, snapOf(w.scene));

  assert.deepEqual(d.removed, [a, b], "删除必须显式列，且升序");
  assert.equal(d.patched.length, 0);
});

test("[增量] 新增的节点进 added（完整记录，不是补丁）", () => {
  const w = world();
  spawnPlayer(w.scene, 0, 100);
  const before = snapOf(w.scene);
  const late = spawnPlayer(w.scene, 1, 101);
  const d = diffSnapshot(before, snapOf(w.scene));

  assert.equal(d.added.length, 1);
  const rec = d.added[0];
  assert.ok(rec !== undefined);
  assert.equal(rec.id, late);
  assert.equal(rec.components.length, 2, "新增节点要带全部组件");
});

// ---------------------------------------------------------------- 4 · 状态差不是事件流

test("[增量] 空增量：什么都没变（含「加了又删」「改了又改回」）", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const before = snapOf(w.scene);

  // 加了又删：状态上等于没发生
  const tmp = spawnPlayer(w.scene, 1, 101);
  w.scene.destroy(tmp);
  w.scene.flush();
  // 改了又改回
  const node = w.scene.find(p);
  assert.ok(node !== undefined);
  node.setLocalPosition(5, 5);
  node.setLocalPosition(0, 0);

  const d = diffSnapshot(before, snapOf(w.scene));
  assert.equal(deltaIsEmpty(d), true, "增量描述状态差，不描述事件流");
  assert.equal(deltaToJson(d).length < 60, true, `空增量该很短，实际 ${String(deltaToJson(d).length)}`);
});

// ---------------------------------------------------------------- 5 · 合成

test("[增量] ★ 合成之后与全量逐字节相同（增删改混在一起）", () => {
  const w = world();
  const a = spawnPlayer(w.scene, 0, 100);
  const b = spawnPlayer(w.scene, 1, 101);
  const mob = spawnMob(w.scene, 200);
  const before = snapOf(w.scene);

  // 一锅端：移动、改名、删组件、加节点、删节点、改组件
  w.scene.find(a)?.setLocalPosition(3.25, -7.5);
  const nb = w.scene.find(b);
  assert.ok(nb !== undefined);
  nb.name = "second";
  nb.zIndex = 3;
  w.scene.find(mob)?.get<Mover>(MOVER_TYPE);
  const mover = w.scene.find(mob)?.get<Mover>(MOVER_TYPE);
  assert.ok(mover !== undefined);
  mover.speed = 7;
  const late = spawnMob(w.scene, 201);
  w.scene.find(late)?.setLocalPosition(1, 1);
  w.scene.destroy(mob);
  w.scene.flush();

  const after = snapOf(w.scene);
  const d = diffSnapshot(before, after);
  assert.ok(d.patched.length > 0 && d.added.length > 0 && d.removed.length > 0, "三种变化都要出现");

  const rep = applyDelta(before, d);
  assert.equal(rep.orphans, 0);
  assert.equal(jsonOf(rep.snap), jsonOf(after), "合成结果必须与全量逐字节相同");
});

test("[增量] ★ 合成结果按 id / type 升序（乱序基线也要归位）", () => {
  const w = world();
  spawnPlayer(w.scene, 0, 100);
  spawnMob(w.scene, 50);
  spawnPlayer(w.scene, 1, 7);

  const canonical = snapOf(w.scene);
  // ★ 基线故意倒序：一份合法的快照（`sceneFromJson` 不排序）完全可能长这样。
  //   `loadScene` 会自己按 id 排，但 `sceneToJson` **不会** —— 它按数组顺序写。
  //   于是少一次排序就会让「同一个世界写出两种字节」。
  const reversed: SceneSnapshot = { ...canonical, nodes: [...canonical.nodes].reverse() };
  const empty = diffSnapshot(canonical, canonical);
  const rep = applyDelta(reversed, empty);

  assert.equal(jsonOf(rep.snap), jsonOf(canonical), "合成之后必须回到升序，否则逐字节比对会红在顺序上");
  assert.deepEqual(
    rep.snap.nodes.map((n) => n.id),
    [...rep.snap.nodes.map((n) => n.id)].sort((x, y) => x - y),
  );
});

test("[增量] 合成是纯的：不改基线，也不改增量", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const before = snapOf(w.scene);
  w.scene.find(p)?.setLocalPosition(4, 4);
  const d = diffSnapshot(before, snapOf(w.scene));

  const beforeJson = jsonOf(before);
  const dJson = deltaToJson(d);
  applyDelta(before, d);
  assert.equal(jsonOf(before), beforeJson, "基线被改了 —— 下一次增量就会合到错的东西上");
  assert.equal(deltaToJson(d), dJson);
});

test("[增量] 对不上基线的三种形状都报 orphans（不许「尽量合」）", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const base = snapOf(w.scene);

  // ① 补丁指向基线里没有的节点
  const ghost = applyDelta(base, {
    format: DELTA_FORMAT_VERSION,
    added: [],
    patched: [{ id: 999, fields: { x: 1 } }],
    removed: [],
  });
  assert.equal(ghost.orphans, 1);

  // ② 删一个基线里没有的节点
  const stale = applyDelta(base, { format: DELTA_FORMAT_VERSION, added: [], patched: [], removed: [999] });
  assert.equal(stale.orphans, 1);

  // ③ 重复新增（基线里已经有了）
  const dup = applyDelta(base, { format: DELTA_FORMAT_VERSION, added: [base.nodes[0]!], patched: [], removed: [] });
  assert.equal(dup.orphans, 1);
  assert.equal(dup.snap.nodes.length, base.nodes.length, "重复新增只能覆盖，不能变成两个");

  // ④ 正常的补丁不许误报
  const ok = applyDelta(base, {
    format: DELTA_FORMAT_VERSION,
    added: [],
    patched: [{ id: p, fields: { x: 2 } }],
    removed: [],
  });
  assert.equal(ok.orphans, 0);
});

test("[增量] 删组件与改组件同时发生时，合成结果与全量一致", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const mob = spawnMob(w.scene, 200);
  const base = snapOf(w.scene);

  const mover = w.scene.find(mob)?.get<Mover>(MOVER_TYPE);
  assert.ok(mover !== undefined);
  mover.speed = 5;
  void p;
  w.scene.detach(p, NET_IDENTITY_TYPE);
  w.scene.flush();

  const next = snapOf(w.scene);
  const rep = applyDelta(base, diffSnapshot(base, next));
  assert.equal(rep.orphans, 0);
  assert.equal(jsonOf(rep.snap), jsonOf(next));
});

// ---------------------------------------------------------------- 6 · 编解码

test("[增量] 编码 → 解码 → 合成，结果与直接合成一致（增删改组件都在里面）", () => {
  const w = world();
  const p = spawnPlayer(w.scene, 0, 100);
  const mob = spawnMob(w.scene, 200);
  const doomed = spawnPlayer(w.scene, 1, 101);
  const base = snapOf(w.scene);

  // ★ 只测「挪一格」会让编码器漏字段（`removed`、`dropComponents`）完全隐形：
  //   合成的结果是靠 `applyDelta` 算的，而它读的是解码出来的对象。
  w.scene.find(p)?.setLocalPosition(2.5, 3.5);
  const mover = w.scene.find(mob)?.get<Mover>(MOVER_TYPE);
  assert.ok(mover !== undefined);
  mover.speed = 3.25;
  w.scene.detach(p, NET_IDENTITY_TYPE);
  w.scene.destroy(doomed);
  const late = spawnMob(w.scene, 201);
  w.scene.find(late)?.setLocalPosition(1, 1);
  w.scene.flush();

  const next = snapOf(w.scene);
  const d = diffSnapshot(base, next);
  assert.ok(d.added.length > 0 && d.removed.length > 0 && d.patched.length > 0);

  const back = deltaFromJson(deltaToJson(d));
  assert.equal(back.ok, true);
  if (!back.ok) return;
  const rep = applyDelta(base, back.value);
  assert.equal(rep.orphans, 0);
  assert.equal(jsonOf(rep.snap), jsonOf(next), "过一遍编码之后必须还是同一个世界");
});

test("[增量] 坏增量一律读不回来，而且错误分得清（坏 / 更新 / 不知道）", () => {
  const tooNew = deltaFromJson('{"format":99,"added":[],"patched":[],"removed":[]}');
  assert.equal(tooNew.ok, false);
  if (!tooNew.ok) assert.equal(tooNew.error.code, "NET.DELTA_TOO_NEW");

  const cases: readonly (readonly [string, string])[] = [
    ["不是 JSON", "{"],
    ["缺 format", '{"added":[],"patched":[],"removed":[]}'],
    ["缺 removed", '{"format":1,"added":[],"patched":[]}'],
    ["format 是字符串", '{"format":"1","added":[],"patched":[],"removed":[]}'],
    ["format 是 0（旧版本不认）", '{"format":0,"added":[],"patched":[],"removed":[]}'],
    ["added 里不是节点", '{"format":1,"added":[{"id":1}],"patched":[],"removed":[]}'],
    [
      "added 的坐标是字符串",
      '{"format":1,"added":[{"id":1,"name":"a","parent":null,"x":"1","y":0,"rot":0,"sx":1,"sy":1,"zIndex":0,"active":true,"layer":0,"components":[]}],"patched":[],"removed":[]}',
    ],
    [
      "added 的组件没有 data",
      '{"format":1,"added":[{"id":1,"name":"a","parent":null,"x":1,"y":0,"rot":0,"sx":1,"sy":1,"zIndex":0,"active":true,"layer":0,"components":[{"type":"t"}]}],"patched":[],"removed":[]}',
    ],
    ["patched 没有 fields", '{"format":1,"added":[],"patched":[{"id":1}],"removed":[]}'],
    ["patched 有未知字段", '{"format":1,"added":[],"patched":[{"id":1,"fields":{"speed":2}}],"removed":[]}'],
    ["removed 里有小数", '{"format":1,"added":[],"patched":[],"removed":[1.5]}'],
    ["dropComponents 不是数组", '{"format":1,"added":[],"patched":[{"id":1,"fields":{},"dropComponents":"x"}],"removed":[]}'],
  ];
  for (const [label, text] of cases) {
    const r = deltaFromJson(text);
    assert.equal(r.ok, false, `这条该被拒：${label}`);
    if (!r.ok) assert.equal(r.error.code, "NET.DELTA_BAD", label);
  }
});

// ---------------------------------------------------------------- 7 · 体量

test("[增量] 100 个静态节点 + 1 个在动：增量不到全量的 5%", () => {
  const w = world();
  for (let i = 0; i < 100; i++) spawnMob(w.scene, 300 + i);
  const hero = spawnPlayer(w.scene, 0, 100);
  const base = snapOf(w.scene);
  const full = jsonOf(base).length;

  w.scene.find(hero)?.setLocalPosition(1, 0);
  const next = snapOf(w.scene);
  const delta = deltaToJson(diffSnapshot(base, next)).length;

  assert.equal(full > 20000, true, `全量该有 20k 字符以上，实际 ${String(full)}`);
  assert.equal(delta < full * 0.05, true, `增量 ${String(delta)} / 全量 ${String(full)} 超过了 5%`);
});
