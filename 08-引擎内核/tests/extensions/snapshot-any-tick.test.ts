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
 *   将来加「回滚模式快照」时，不要删这条，而是给它加一个模式参数、让默认模式的行为不变。
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
