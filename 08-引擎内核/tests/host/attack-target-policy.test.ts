/**
 * L6 · 演示世界"这一下能打谁"的判据（批123）
 *
 * 这组判据钉住一句话：**候选资格是四条独立的规矩，不是一个大 `if`**。
 * 自己 / 未激活 / 死 / 盟友，四条各自返回自己的理由码。
 *
 * ★ 为什么会抽到这个文件（如实记）：批123 给玩家击杀补了"当场撤掉死掉的节点"
 *   （尸体落地的同时 `scene.destroy`），于是演示世界里不再有"站着的尸体"——
 *   `attackNearest` 里那行 `if (isDead(h)) continue;` **再也等不到它的语料**。
 *   原来的变异 M314（删掉那一行）由浏览器自检咬住，批123 之后它变成了
 *   **等价变异**，CI 报「判据假绿」。那不是判据写窄了，是那行代码在浏览器里
 *   没了可观察的出口。要继续咬住它，只能给它一条不依赖世界的判据 —— 就是这里。
 *
 * ★★ 判据的口径：**返回值是理由码，不是一个 boolean**。这是这一批栽过的坑的
 *   另一面 —— 把四个条件与在一起时，"打不到"是所有失败的同一个现象，
 *   诊断只能靠猜（批123 的浏览器判据就被那个 `&&` 坑了一轮）。
 *   所以这里逐条断言**具体的理由**，并且额外钉住"四条理由互不相同"：
 *   哪怕实现把四个分支写成同一句 `return "no"`，那条判据也会红。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { whyNotAttackable, type AttackCandidateInfo } from "../../src/host/attack-target-policy.ts";

const HERO = 1;

/** 造一个"什么毛病都没有"的候选（能打）。各条判据只改自己关心的那一项。 */
function cand(patch: Partial<AttackCandidateInfo> = {}): AttackCandidateInfo {
  return { selfId: HERO, id: 7, active: true, dead: false, isAlly: false, ...patch };
}

test("干净候选 ⇒ 能打（返回 null）", () => {
  assert.equal(whyNotAttackable(cand()), null);
});

test("拿自己当目标 ⇒ self", () => {
  assert.equal(whyNotAttackable(cand({ id: HERO })), "self");
});

test("未激活 ⇒ inactive（画面上没有的东西不该被打到）", () => {
  assert.equal(whyNotAttackable(cand({ active: false })), "inactive");
});

test("★★ 血见底 ⇒ dead（贴着尸体打不到活人）", () => {
  // ★★ 批123 之前这条由浏览器自检咬住（M314）；批123 之后演示里不再有
  //   站着的尸体，浏览器判据咬不住它 —— 这就是这个文件存在的理由。
  //   写成 `if (false)` 或整段删掉，这条立刻红。
  assert.equal(whyNotAttackable(cand({ dead: true })), "dead");
});

test("同队 ⇒ ally（友伤默认拦截，靠关系表判而不是靠距离蒙）", () => {
  assert.equal(whyNotAttackable(cand({ isAlly: true })), "ally");
});

test("★ 判定顺序写死：死的盟友报 dead（不是 ally）", () => {
  // 顺序散着写在循环里的时候，"盟友也死了"到底报哪个理由取决于代码行先后，
  // 判据与日志会各说一套。这里把顺序钉成契约：便宜且确定的先判。
  assert.equal(whyNotAttackable(cand({ dead: true, isAlly: true })), "dead");
});

test("★ 判定顺序写死：未激活的尸体报 inactive（不是 dead）", () => {
  assert.equal(whyNotAttackable(cand({ active: false, dead: true })), "inactive");
});

test("★★ 四条理由互不相同（防「四个分支写成同一句 return」）", () => {
  // 只看"不是 null"的话，把四条合并成一个 `"no"` 也能过 —— 那等于把
  // "为什么打不到"重新变回不可诊断。所以这里比集合大小。
  const reasons = new Set([
    whyNotAttackable(cand({ id: HERO })),
    whyNotAttackable(cand({ active: false })),
    whyNotAttackable(cand({ dead: true })),
    whyNotAttackable(cand({ isAlly: true })),
  ]);
  assert.equal(reasons.size, 4, `四条理由必须各不相同，实际 ${[...reasons].join(" / ")}`);
});

test("★ selfId 变化会影响判定（不是把 HERO 写死在策略里）", () => {
  // 策略只该看传进来的 selfId：同一份数据，换一个观察者结论就该反过来。
  assert.equal(whyNotAttackable(cand({ id: 7, selfId: 7 })), "self");
  assert.equal(whyNotAttackable(cand({ id: 7, selfId: 8 })), null);
});
