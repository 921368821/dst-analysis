/**
 * 掉线与超时清扫（批169）
 *
 * ★ 这两条路径在批164 就写好了接口（`Room.drop` / `Room.sweep`），
 *   **而 `src/` 里一个调用点都没有** —— 因为当时没有任何一条链路能给出「谁断了」。
 *   网关是第一个知道的一方，所以接线落在 `host/net-assembly.ts`。
 *
 * ★ 为什么判据打的是 `sweepExpired` / `notePeerLeft` 而不是 `assembleHostNet`：
 *   后者内部 `createRoom()` + 需要一份真 `WorldPlan`（要生成世界），
 *   而这里要验的是**归属交还**这一步 —— 它与房间怎么建没有关系。
 *   参数用结构化类型（只要求有 `sweep` / `drop`），于是判据可以造一个只会
 *   "刚好在第 3 拍清掉 7 号"的假房间。
 *
 * ★★ 这一组守的是什么，值得写清：归属交还不是"顺手做一下"，
 *   它是**唯一**会把 `net.identity.owner` 改回 `AUTHORITY` 的地方。
 *   不做的后果是下一个坐进那个座位号的人一进来就"拥有"一个远处的实体，
 *   而他自己的角色还没造出来 —— 症状是「我按方向键，动的是别人」，
 *   而座位数、在线数、实体数全都正常。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Scene } from "../../src/core/scene/scene.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { AUTHORITY, NetIdentity, ownerOf, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { notePeerLeft, sweepExpired } from "../../src/host/net-assembly.ts";

function world(): Scene {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  registerNetIdentity(reg);
  return new Scene("main", reg);
}

function spawnOwned(scene: Scene, owner: number, name: string): number {
  const n = scene.spawnImmediate(name, scene.rootId);
  scene.attach(n.id, () => new PlayerController());
  scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  scene.flush();
  return n.id;
}

test("★★ 超时清掉的座位要把归属交还 AUTHORITY（不交还 ⇒「我按方向键，动的是别人」）", () => {
  const scene = world();
  const a = spawnOwned(scene, 1, "a");
  const b = spawnOwned(scene, 1, "b");
  const other = spawnOwned(scene, 2, "other");
  assert.equal(ownerOf(scene, a), 1);

  // 假房间：第 3 拍清掉 1 号。
  let swept = 0;
  const room = {
    sweep(tick: number): readonly number[] {
      swept++;
      return tick >= 3 ? [1] : [];
    },
  };
  assert.deepEqual(sweepExpired(room, scene, 2), [], "第 2 拍还没到窗口");
  assert.equal(ownerOf(scene, a), 1, "窗口内不许动归属（他可能马上重连回来）");

  assert.deepEqual(sweepExpired(room, scene, 3), [1]);
  assert.equal(swept, 2);
  // ★ 两个观测量一起读：该变的变了（1 号的两个实体交还了），不该变的没变（2 号的没碰）。
  assert.equal(ownerOf(scene, a), AUTHORITY, "1 号被清掉了，他的实体还归他 ⇒ 下一个人能用他的角色");
  assert.equal(ownerOf(scene, b), AUTHORITY);
  assert.equal(ownerOf(scene, other), 2, "别人的归属被一起交还了");
});

test("★ 只交还归属，**不销毁实体**（他不在了，但他的身体还站在原地）", () => {
  const scene = world();
  const a = spawnOwned(scene, 1, "a");
  const before = scene.find(a);
  assert.ok(before !== undefined);
  sweepExpired({ sweep: () => [1] }, scene, 10);
  const after = scene.find(a);
  assert.ok(after !== undefined, "实体被销毁了：世界会因为网线拔了而少一个人");
  assert.equal(ownerOf(scene, a), AUTHORITY);
});

test("★ 一个被清掉的座位有 0 个实体时什么也不炸（清扫是每拍跑的，绝大多数拍是空转）", () => {
  const scene = world();
  assert.deepEqual(sweepExpired({ sweep: () => [9, 10] }, scene, 50), [9, 10]);
});

test("★★ 端点断开 → `room.drop`；`drop` 返回 null 时**不告警**（那是常态）", () => {
  // ★ 这条不需要场景：`drop` 只动房间账本，归属交还是 `sweep` 的事（上一条）。
  const warns: string[] = [];
  const dropped: { peer: number; tick: number }[] = [];
  const room = {
    drop(peer: number, tick: number): number | null {
      dropped.push({ peer, tick });
      // 只有 3 号坐下了；7 号还没握手 —— 后者返回 null 是常态。
      return peer === 3 ? 5 : null;
    },
  };

  assert.equal(notePeerLeft(room, 3, 12, "socket closed", (m) => warns.push(m)), 5);
  assert.deepEqual(dropped, [{ peer: 3, tick: 12 }]);
  assert.equal(warns.length, 1, "真正掉线的人必须留一条证据");
  assert.match(warns[0] ?? "", /端点 3/);
  assert.match(warns[0] ?? "", /座位 5/);

  // 没坐下的端点：静默
  assert.equal(notePeerLeft(room, 7, 13, "socket closed", (m) => warns.push(m)), null);
  assert.equal(warns.length, 1, "「某个陌生人断了」也告警 ⇒ 真正的掉线被淹掉");
});

test("★★ 断开只标掉线、**不清座位**（清了的话重连的人会拿到新座位号，背包位置全丢）", () => {
  // ★ 这条钉的是分工：`drop` 与 `sweep` 是两件事。
  //   把 `drop` 写成"直接清掉"的实现会让 `sweep` 永远返回空 ——
  //   而所有"座位数"计数仍然对得上（清掉之后座位数确实少了）。
  const scene = world();
  const a = spawnOwned(scene, 5, "a");
  notePeerLeft({ drop: () => 5 }, 3, 1, "x", () => {});
  assert.equal(ownerOf(scene, a), 5, "断线当场就把归属交还了 ⇒ 他重连回来会发现自己的角色「不归自己」");
});

test("★ 端口号抖动（同一 tick 重复 drop）不改变结果：`notePeerLeft` 是幂等的", () => {
  // 网关的 `socket.on("close")` 与 `socket.on("error")` 可能都会触发，
  // 而真实 `Room.drop` 对"已经掉线的座位"返回 null。
  const warns: string[] = [];
  let calls = 0;
  const room = {
    drop(): number | null {
      calls++;
      return calls === 1 ? 5 : null;
    },
  };
  notePeerLeft(room, 3, 9, "x", (m) => warns.push(m));
  notePeerLeft(room, 3, 9, "x", (m) => warns.push(m));
  assert.equal(warns.length, 1);
});
