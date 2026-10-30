/**
 * L2 · 任意 tick 的快照：导出 → 还原 → 再导出，逐字节相等
 *
 * ★ 为什么单独一份判据，而不是并进现有的存档往返测试：
 *   现有那几份（跨宿主、无头存档）验的是「**一个静止的场景**存了再读回来不变」，
 *   那证明的是编码正确。联机要的是另一件事：**在运动中间、在 AI 正走着的时刻**随时导出，
 *   而且导出的东西足以让另一台机器接着跑。两件事的失败方式不同 ——
 *   前者错了会「读档报错」，后者错了会「读档成功但世界停在半路」。
 *
 * ★★ 这份判据真正钉住的是一处刻意的取舍（见 `ai/move.ts` 里 `Mover` 的注释）：
 *   寻路状态（`path` / `cursor` / `goalCell` / `arrived`）**不进 schema、不进存档**。
 *   理由在存档语义下是对的：路径是从当前局面推出来的，读档时局面已变，存进去反而会沿一条
 *   过期的路走。但在**回滚**语义下这条理由不成立 —— 回滚到 tick N 时局面与 N 完全一致，
 *   路径不是过期的，是必须一致的。
 *   所以下面第 2 条判据守的是**存档模式的默认行为**，不是「寻路状态永远不该被快照」。
 *   批151 按当初写下的办法做了：加了 `{ mode: "rollback" }` 参数，默认模式的行为一个字没变，
 *   而「回滚快照要带上运行期状态」这件事由文件下半部分的 5 条判据守。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { Node } from "../../src/core/scene/node.ts";
import {
  SCENE_FORMAT_VERSION,
  loadScene,
  saveScene,
  sceneFromJson,
  sceneToJson,
} from "../../src/core/scene/scene-io.ts";
import { MOVER_TYPE, Mover } from "../../src/extensions/ai/move.ts";

function makeRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  // ★ 用**真实** Mover 的 schema（不是自建同形类）：判据要能打到 `ai/move.ts` 里那份，
  //   否则把它改成「把 cursor 也存进档」，这条判据照样绿 —— 那是假绿。
  reg.register(new Mover().schema, () => new Mover());
  return reg;
}

function makeScene(reg: ComponentRegistry = makeRegistry()): {
  scene: Scene;
  hero: Node;
  reg: ComponentRegistry;
} {
  const scene = new Scene("任意 tick 快照", reg);
  const hero = scene.spawnImmediate("主角");
  scene.attach(hero.id, () => new Mover());
  scene.flush();
  return { scene, hero, reg };
}

test("[任意 tick] ★ 每一步的快照都不同，且都还原得回来（快照反映当期，不是缓存）", () => {
  const { scene, hero, reg } = makeScene();

  const seen: string[] = [];
  for (let i = 0; i < 6; i++) {
    const json = sceneToJson(saveScene(scene));
    seen.push(json);

    const parsed = sceneFromJson(json);
    assert.equal(parsed.ok, true, `第 ${String(i)} 次导出的 JSON 自己解析不回来`);
    if (!parsed.ok) return;
    const back = new Scene("还原", reg);
    const loaded = loadScene(back, parsed.value, reg);
    assert.equal(loaded.ok, true);
    if (!loaded.ok) return;

    const same = back.find(hero.id);
    assert.ok(same !== undefined, `第 ${String(i)} 次导出后节点丢了`);
    const p = hero.localPosition;
    const q = same.localPosition;
    assert.ok(
      Math.abs(p.x - q.x) < 1e-9 && Math.abs(p.y - q.y) < 1e-9,
      `第 ${String(i)} 次：导出时的位置必须能原样还原（${String(p.x)},${String(p.y)} → ${String(q.x)},${String(q.y)}）`,
    );
    hero.setLocalPosition(p.x + 0.25, p.y + 0.5);
  }

  const distinct = new Set(seen);
  assert.equal(distinct.size, seen.length, "六次导出必须两两不同 —— 有重复说明快照没跟着状态走");
});

test("[任意 tick] ★ 寻路状态不进存档（存档语义：路径由局面推出，存了反而沿过期的路走）", () => {
  const { scene, hero } = makeScene();
  const m = hero.get<Mover>(MOVER_TYPE);
  assert.ok(m !== undefined, "组件没挂上，后面的断言就没意义");
  m.path = [1, 2, 3];
  m.cursor = 1;
  m.goalCell = 3;
  m.arrived = false;

  const snap = saveScene(scene);
  const rec = snap.nodes.find((n) => n.id === hero.id);
  assert.ok(rec !== undefined);
  const mover = rec.components.find((c) => c.type === MOVER_TYPE);
  assert.ok(mover !== undefined, "Mover 组件本身要进存档（速度是可持久配置）");

  const keys = Object.keys(mover.data).sort();
  assert.deepEqual(
    keys,
    ["speed"],
    `存档里只该有 speed，实际 ${keys.join(",")} —— 寻路状态进档会让读档后沿一条过期的路走`,
  );
});

test("[任意 tick] 快照顶层只有「世界」的东西：没有时间、没有会话、没有种子", () => {
  const { scene } = makeScene();
  const snap = saveScene(scene);
  assert.deepEqual(
    Object.keys(snap).sort(),
    ["format", "name", "nodes"],
    "快照多了会话相关字段 ⇒ 两台机器导出的同一局面不再逐字节可比",
  );
  assert.equal(snap.format, SCENE_FORMAT_VERSION);
});

test("[任意 tick] 同一局面导两次逐字节相等（导出不改状态）", () => {
  const { scene } = makeScene();
  const a = sceneToJson(saveScene(scene));
  const b = sceneToJson(saveScene(scene));
  assert.equal(a, b, "导出必须是纯的：导一次就改了状态的话，回滚永远对不上");
});

// ==================== 批151：回滚模式 ====================
//
// ★ 为什么回滚要与存档分开：这两种语义对**同一批字段**的要求相反。
//   存档（新会话）时局面可能已经变了 ⇒ 路径是过期的，存进去会让读档后沿老路走；
//   回滚到 tick N 时局面与 N 完全一致 ⇒ 路径不是过期的，是必须一致的，重算会分叉。
//   所以不是「该不该存」，而是「存进哪种档」，由 `saveScene(scene, {mode})` 决定。
//
// ★ 五条判据分别守：模式真的切换了行为 / 还原逐字段相等 / 导出仍是纯的 /
//   存档这一侧没被污染 / **声明不许漏**（新增运行期字段忘了写进 rollback 清单）。

/** 给一只怪设满运行期状态：路径走到一半、退避中、卡住计数非零。 */
function dirtyMover(m: Mover): void {
  m.path = [3, 4, 5, 6];
  m.cursor = 2;
  m.goalCell = 6;
  m.arrived = false;
  m.failCell = 9;
  m.retryTick = 17;
  m.stuckTicks = 4;
}

test("[回滚] 模式真的切换了行为：存档只有 speed，回滚带上全部运行期状态", () => {
  const { scene, hero } = makeScene();
  const m = hero.get<Mover>(MOVER_TYPE);
  assert.ok(m !== undefined);
  dirtyMover(m);

  const saved = saveScene(scene);
  const rolled = saveScene(scene, { mode: "rollback" });
  const keysOf = (snap: ReturnType<typeof saveScene>): string[] => {
    const rec = snap.nodes.find((n) => n.id === hero.id);
    const mover = rec?.components.find((c) => c.type === MOVER_TYPE);
    assert.ok(mover !== undefined);
    return Object.keys(mover.data).sort();
  };

  assert.deepEqual(
    keysOf(saved),
    ["speed"],
    "存档模式一个字段都不许多 —— 这是批148 那条判据的同一句话，加模式不能把它改掉",
  );
  assert.deepEqual(
    keysOf(rolled),
    ["arrived", "cursor", "failCell", "goalCell", "path", "retryTick", "speed", "stuckTicks"],
    "回滚模式必须带上全部运行期状态（漏一个，回滚后那只怪的行为就会和原来分叉）",
  );
  assert.notEqual(
    sceneToJson(rolled),
    sceneToJson(saved),
    "两种模式导出的字节相同 ⇒ 模式参数根本没传到组件（接线断了，判据全绿）",
  );
});

test("[回滚] 回滚快照还原后七个字段逐个相等（含路径内容，不只是长度）", () => {
  const { scene, hero, reg } = makeScene();
  const m = hero.get<Mover>(MOVER_TYPE);
  assert.ok(m !== undefined);
  dirtyMover(m);

  const json = sceneToJson(saveScene(scene, { mode: "rollback" }));
  const parsed = sceneFromJson(json);
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;

  const back = new Scene("回滚还原", reg);
  assert.equal(loadScene(back, parsed.value, reg).ok, true);
  const same = back.find(hero.id);
  assert.ok(same !== undefined);
  const got = same.get<Mover>(MOVER_TYPE);
  assert.ok(got !== undefined);

  assert.deepEqual(got.path, [3, 4, 5, 6], "路径内容必须一致 —— 只对长度会漏掉「路径换了但一样长」");
  assert.equal(got.cursor, 2);
  assert.equal(got.goalCell, 6);
  assert.equal(got.arrived, false);
  assert.equal(got.failCell, 9, "退避的目标格丢了 ⇒ 回滚后它会立刻重算一次路");
  assert.equal(got.retryTick, 17, "退避截止 tick 丢了 ⇒ 回滚后每 tick 都在重算");
  assert.equal(got.stuckTicks, 4, "卡住计数丢了 ⇒ 回滚后要再卡 4 次才会走「丢路径重算」那条出口");
  assert.equal(got.speed, m.speed, "speed 是普通字段，两种模式都该带上");
});

test("[回滚] 回滚快照连导两次逐字节相等（加了模式，导出仍然是纯的）", () => {
  const { scene, hero } = makeScene();
  const m = hero.get<Mover>(MOVER_TYPE);
  assert.ok(m !== undefined);
  dirtyMover(m);

  const a = sceneToJson(saveScene(scene, { mode: "rollback" }));
  const b = sceneToJson(saveScene(scene, { mode: "rollback" }));
  assert.equal(a, b, "导一次就改了状态的话，回滚永远对不上（这条与模式无关，但必须重新证一次）");
});

test("[回滚] 存档这一侧没被污染：普通存档读回来路径是空的", () => {
  const { scene, hero, reg } = makeScene();
  const m = hero.get<Mover>(MOVER_TYPE);
  assert.ok(m !== undefined);
  dirtyMover(m);

  const parsed = sceneFromJson(sceneToJson(saveScene(scene)));
  assert.equal(parsed.ok, true);
  if (!parsed.ok) return;
  const back = new Scene("读档", reg);
  assert.equal(loadScene(back, parsed.value, reg).ok, true);
  const got = back.find(hero.id)?.get<Mover>(MOVER_TYPE);
  assert.ok(got !== undefined);

  assert.deepEqual(got.path, [], "存档里没有路径 ⇒ 读回来必须是「没有路径」，不能是上一份残留");
  assert.equal(got.goalCell, -1);
  assert.equal(got.cursor, 0);
  assert.equal(got.stuckTicks, 0);
});

test("[回滚] 声明不许漏：Mover 上所有非 schema 字段都在 rollback 清单里", () => {
  // ★ 这条不是「验实现」，是**清单对账**：将来给 Mover 加一个运行期字段、忘了写进
  //   `rollback`，回滚快照就会静默少一块状态 —— 而那种快照照样能读回来，只是世界
  //   从半路开始走另一条路。差集非空就红，逼一次显式决定（进 / 不进）。
  const m = new Mover();
  const base = new Set(["node", "enabled", "schema", "lastActive"]);
  const declared = new Set(Object.keys(m.schema.fields));
  const runtime = Object.keys(m).filter((k) => !base.has(k) && !declared.has(k));
  const inRollback = new Set(m.schema.rollback ?? []);

  const missing = runtime.filter((k) => !inRollback.has(k));
  assert.deepEqual(missing, [], `这些运行期字段没进 rollback 清单：${missing.join(",")}`);
  const extra = [...inRollback].filter((k) => !runtime.includes(k));
  assert.deepEqual(extra, [], `rollback 清单里有不存在的字段（改名或删字段后忘了同步）：${extra.join(",")}`);
});
