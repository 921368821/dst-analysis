/**
 * L4 · 归属查询（`net/identity.ts` 的 `ownedBy`）
 *
 * ★ 为什么单独给这一个查询开一组判据：
 *   `ownedBy` 的文档写着「按 id 升序，确定性」，而**五个调用点**都用 `ownedBy(...)[0]`
 *   当"我的那个角色"。升序这件事删掉之后，单实体场景全部照旧通过 ——
 *   于是这条契约等于只长在注释里。判据要钉的是「契约本身」，
 *   不是某一次调用碰巧只有一个结果。
 *
 * ★ 夹具必须**逆序** spawn：先造 id 大的、再造 id 小的。
 *   顺造的话，插入序与升序恰好一致，排序有没有实现都看不出来。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { NetIdentity, ownedBy, registerNetIdentity } from "../../src/extensions/net/identity.ts";

function world(): Scene {
  const reg = new ComponentRegistry();
  registerNetIdentity(reg);
  return new Scene("main", reg);
}

function spawnOwned(scene: Scene, owner: number, id: number): number {
  const n = scene.spawnImmediate("player", scene.rootId, id);
  scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  scene.flush();
  return n.id;
}

test("★ ownedBy 按 id **升序**返回（逆序 spawn 也一样）", () => {
  const scene = world();
  // 逆序：503 → 502 → 501。插入序是 [503, 502, 501]，正确答案是 [501, 502, 503]。
  spawnOwned(scene, 7, 503);
  spawnOwned(scene, 7, 502);
  spawnOwned(scene, 7, 501);

  assert.deepEqual(
    ownedBy(scene, 7),
    [501, 502, 503],
    "顺序错了 ⇒ `ownedBy(...)[0]` 拿到的就不是「最小的那个」，而这一幕只在多实体时出现",
  );
});

test("ownedBy 只返回这个玩家的实体，别人的一个都不混进来", () => {
  const scene = world();
  spawnOwned(scene, 7, 601);
  spawnOwned(scene, 8, 602);
  spawnOwned(scene, 7, 603);

  assert.deepEqual(ownedBy(scene, 7), [601, 603]);
  assert.deepEqual(ownedBy(scene, 8), [602]);
});

test("一个实体都没有 ⇒ 空数组（不是 null、不是 [-1]）", () => {
  const scene = world();
  spawnOwned(scene, 7, 701);
  assert.deepEqual(ownedBy(scene, 9), [], "没有实体的玩家要拿到空数组 —— 调用方靠 `.length === 0` 判断");
});

test("实体被销毁之后不再出现（客户端整场换世界时这条是常态）", () => {
  const scene = world();
  const a = spawnOwned(scene, 7, 801);
  const b = spawnOwned(scene, 7, 802);
  assert.deepEqual(ownedBy(scene, 7), [801, 802]);

  scene.destroy(a);
  scene.flush();
  assert.deepEqual(ownedBy(scene, 7), [802], `销毁 ${String(a)} 之后还留在结果里；剩下的是 ${String(b)}`);
});
