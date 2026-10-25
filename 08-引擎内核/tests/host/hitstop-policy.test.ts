/**
 * L6 · 演示世界顿帧策略的判据
 *
 * 这组判据钉住一句话：**只有玩家的命中值得冻世界**。
 *
 * ★ 为什么值得单测（批74 的教训）：策略第一版把分支顺序写反了
 *   （`dead ? 12 : attacker===hero ? 3 : 0`），于是"任何死亡都冻 12 步" ——
 *   猎狗咬死兔子也冻。症状不在 Node 里（Node 用例的策略是自己传的），
 *   只在浏览器里：世界被野怪冻得一顿一顿，两条顿帧判据时红时绿，
 *   最后以 CI 上"M292 还原不干净"的形式爆出来。玩法判断抽成纯函数
 *   就是为了让这类错误在毫秒级被发现，而不是在 20 分钟的 CI 里。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { demoHitstopPolicy, HITSTOP_HIT_TICKS, HITSTOP_KILL_TICKS } from "../../src/host/hitstop-policy.ts";
import type { HitInfo } from "../../src/extensions/combat/combat-module.ts";

/** 造一条命中记录（只填策略会读的字段）。 */
function hit(attackerId: number, dead: boolean): HitInfo {
  return {
    attackerId,
    targetId: attackerId + 100,
    before: dead ? 1 : 5,
    after: dead ? 0 : 3,
    applied: dead ? 1 : 2,
    overkill: dead ? 1 : 0,
    dead,
    tick: 10,
  };
}

const HERO = 1;

test("玩家击杀 ⇒ 冻满 12 步", () => {
  assert.equal(demoHitstopPolicy(hit(HERO, true), HERO), HITSTOP_KILL_TICKS);
});

test("玩家普通命中 ⇒ 冻 3 步", () => {
  assert.equal(demoHitstopPolicy(hit(HERO, false), HERO), HITSTOP_HIT_TICKS);
});

test("怪打怪（没打死）⇒ 不冻", () => {
  assert.equal(demoHitstopPolicy(hit(7, false), HERO), 0);
});

test("★★ 怪打死怪 ⇒ 也不冻（批74：第一版这里错了，写成见 death 就冻）", () => {
  // ★★ 这就是 CI 上时红时绿的那一条：猎狗（id 7）咬死兔子，
  //   而演示世界里有 3 只猎狗常年追杀 10 只兔子 ⇒ 世界被冻得一顿一顿。
  //   分支顺序写反时（`dead ? 12 : ...`）这里会返回 12。
  assert.equal(demoHitstopPolicy(hit(7, true), HERO), 0);
});

test("怪打玩家（没打死）⇒ 不冻", () => {
  // 玩家是被打方：attackerId 是怪，不是 hero。
  assert.equal(demoHitstopPolicy(hit(7, false), HERO), 0);
});

test("怪打死玩家 ⇒ 同样不冻（死亡这一侧不该触发顿帧）", () => {
  // 玩家被打死也走"攻击者不是 hero"这一支 —— 顿帧是"我打中了"的反馈，
  // 不是"世界死了人"的反馈。后者该由死亡表现（闪色/掉落）负责。
  assert.equal(demoHitstopPolicy(hit(7, true), HERO), 0);
});

test("英雄 id 未定（-1）时任何命中都不冻", () => {
  // 世界没建好时的中间态：不冻比"冻一下"安全（后者会在启动时莫名卡一拍）。
  assert.equal(demoHitstopPolicy(hit(3, true), -1), 0);
  assert.equal(demoHitstopPolicy(hit(3, false), -1), 0);
});
