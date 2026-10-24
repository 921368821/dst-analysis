/**
 * L4 · AI 队伍（占目标 / 分角色）
 *
 * 这里的每条判据都对应"多个 agent 同时存在"才会出现的现象：
 * 争抢、改主意、离队不释放 —— 单 agent 判据一条都看不见。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { TEAM_BAD_INPUT, TEAM_NOT_MEMBER, Team, planRoles } from "../../src/extensions/ai/team.ts";

test("[队伍] 占位先到先得：后来者拿到 taken=true，并且知道是谁占了", () => {
  const t = new Team();
  assert.equal(t.add(1, "hunter").ok, true);
  assert.equal(t.add(2, "hunter").ok, true);

  const a = t.claim(1, 42);
  assert.equal(a.ok, true);
  if (!a.ok) return;
  assert.deepEqual(a.value, { targetId: 42, by: 1, taken: false });

  const b = t.claim(2, 42);
  assert.equal(b.ok, true);
  if (!b.ok) return;
  assert.equal(b.value.taken, true);
  assert.equal(b.value.by, 1, "后来者必须能问出「谁占了」。拿不到这个信息就只能干等");

  // 占位没有改变世界状态：只是登记
  assert.equal(t.ownerOf(42), 1);
  assert.deepEqual(t.claimsSnapshot(), [{ targetId: 42, by: 1 }]);
});

test("[队伍] 一个 agent 只占一个目标：改占会自动释放旧的", () => {
  const t = new Team();
  t.add(1, "hunter");
  assert.equal(t.claim(1, 10).ok, true);
  assert.equal(t.claim(1, 11).ok, true);
  assert.equal(t.ownerOf(10), null, "改占之后旧目标还挂在他名下 —— 别人永远拿不到");
  assert.equal(t.ownerOf(11), 1);
  assert.equal(t.claimsSnapshot().length, 1);
});

test("[队伍] 重复占同一个目标是幂等成功（不重复登记）", () => {
  const t = new Team();
  t.add(1, "hunter");
  const first = t.claim(1, 7);
  const again = t.claim(1, 7);
  assert.equal(first.ok && again.ok, true);
  if (!first.ok || !again.ok) return;
  assert.equal(again.value.taken, false);
  assert.equal(t.claimsSnapshot().length, 1);
});

test("[队伍] 离队会释放他占的目标（不释放就是永久泄漏）", () => {
  const t = new Team();
  t.add(1, "hunter");
  t.add(2, "hunter");
  t.claim(1, 100);
  const freed = t.remove(1);
  assert.equal(freed, 100, "remove 应该把释放的目标交回来（调用方要能立刻让给别人）");
  assert.equal(t.ownerOf(100), null);
  assert.equal(t.size(), 1);
  // 2 现在能占到
  const r = t.claim(2, 100);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.value.taken, false);
});

test("[队伍] 非队员占位：TEAM.NOT_MEMBER（不静默失败）", () => {
  const t = new Team();
  const r = t.claim(9, 1);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, TEAM_NOT_MEMBER);
});

test("[队伍] 人数上限：满了报错，不静默丢弃", () => {
  const t = new Team({ maxMembers: 2 });
  assert.equal(t.add(1, "a").ok, true);
  assert.equal(t.add(2, "a").ok, true);
  const over = t.add(3, "a");
  assert.equal(over.ok, false);
  if (over.ok) return;
  assert.equal(over.error.code, TEAM_BAD_INPUT);
  assert.equal(t.size(), 2);
});

test("[队伍] 成员列表按 id 升序（驱动顺序不能取决于插入顺序）", () => {
  const t = new Team();
  for (const id of [7, 3, 11, 5]) assert.equal(t.add(id, "hunter").ok, true);
  assert.deepEqual([...t.members()], [3, 5, 7, 11]);
  t.add(20, "gatherer");
  assert.deepEqual([...t.members("gatherer")], [20]);
});

test("[队伍] 占位快照按 targetId 升序（日志与判据读它都不会因插入序而变）", () => {
  const t = new Team();
  for (const id of [1, 2, 3]) t.add(id, "h");
  t.claim(1, 30);
  t.claim(2, 10);
  t.claim(3, 20);
  assert.deepEqual(
    t.claimsSnapshot().map((c) => c.targetId),
    [10, 20, 30],
  );
});

test("[队伍] 共享黑板拒绝非有限数（NaN 会污染决策）", () => {
  const t = new Team();
  t.setShared("retreat", 1);
  assert.equal(t.shared.get("retreat"), 1);
  assert.throws(() => t.setShared("retreat", Number.NaN), RangeError);
  assert.throws(() => t.setShared("retreat", Infinity), RangeError);
});

test("[队伍] planRoles：乱序输入得到相同分配（无状态、可复现）", () => {
  const quota = { gatherer: 2, hunter: 1 };
  const a = planRoles([5, 3, 9, 1], quota);
  const b = planRoles([1, 9, 3, 5], quota);
  assert.deepEqual([...a.entries()].sort(), [...b.entries()].sort());
  // 填配额的顺序有两层，都是**写死的**：角色名升序（gatherer < hunter），角色内按 agent id 升序。
  // 于是 gatherer 先吃掉 1、3；hunter 拿 5；9 落 fallback。
  // ★ 这条断言的作用不是"证明这个分配合理"，而是**钉住它是确定的**：
  //   哪天有人把 Object.keys 的遍历序当成"声明的顺序"，这里会立刻红。
  assert.equal(a.get(1), "gatherer");
  assert.equal(a.get(3), "gatherer");
  assert.equal(a.get(5), "hunter");
  assert.equal(a.get(9), "idle");
});

test("[队伍] planRoles：Infinity 名额吃掉剩下的，坏名额抛错", () => {
  const all = planRoles([2, 1], { hunter: Infinity });
  assert.equal(all.get(1), "hunter");
  assert.equal(all.get(2), "hunter");
  assert.throws(() => planRoles([1], { hunter: -1 }), RangeError);
  assert.throws(() => planRoles([1], { hunter: 1.5 }), RangeError);
});
