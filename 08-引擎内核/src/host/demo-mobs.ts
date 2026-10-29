/**
 * L4 · 演示世界的生物配表（**宿主决定**，批126）
 *
 * 为什么单独一个文件：这张表是"这一局的世界长什么样"的**产品决定**，
 * 而演示页里那 5000 行接线（`browser-entry.ts`）不是。更要紧的是：
 * **生态判据必须读同一份数字**。
 *
 * ★★ 以前这张表写在 `browser-entry.ts` 里，于是"3 只猎狗 4 秒吃光 10 只兔子"这件事
 *   只能在浏览器里肉眼看见 —— 判据要复现它，就得把数字**抄**一份到测试里。
 *   抄出来的第二份必然漂移：调了猎狗冷却、测试还在用旧的，于是"生态正常"永远是绿的。
 *   现在测试 `import` 这张表，配表一改判据就跟着改 —— 它验的是**这个世界**，
 *   不是"某个和它长得很像的世界"。
 */

import type { Factions } from "../extensions/combat/faction.ts";
import { createFactions } from "../extensions/combat/faction.ts";
import type { NavGrid } from "../extensions/nav/nav-grid.ts";
import type { MobSpot } from "../extensions/mobs/mob-world.ts";

/**
 * 两种活物。
 *
 * ★ 名字要与图集里的帧名一致（见 `DEMO_FRAMES`）—— 两边写错一个字的症状是
 *   「生物在走但看不见」，而渲染模块只会 warn。
 * ★ 兔子 `damage: 0`：不挂攻击组件 ⇒ 只跑不打（见 `spawn-mob.ts` 文件头 ③）。
 */
export const DEMO_MOB_TEMPLATES = [
  {
    kind: "rabbit",
    frame: "rabbit",
    width: 0.9,
    height: 0.9,
    radius: 0.28,
    maxHp: 4,
    damage: 0,
    range: 1.4,
    cooldownTicks: 20,
    speed: 1.1,
    team: "prey",
    loot: [{ kind: "meat", count: 2 }],
  },
  {
    kind: "hound",
    frame: "hound",
    width: 1.1,
    height: 1.1,
    radius: 0.34,
    maxHp: 8,
    damage: 2,
    range: 1.7,
    cooldownTicks: 15,
    speed: 2.3,
    team: "hunter",
    loot: [{ kind: "hide", count: 1 }],
  },
] as const;

/** 出生数量：3 只猎狗、10 只兔子。 */
export const DEMO_HOUNDS = 3;
export const DEMO_RABBITS = 10;

/**
 * 关系表是**宿主**的配置（引擎不认识"猎人"）：玩家与猎狗同队，兔子是猎物。
 * 于是猎狗会追兔子、玩家能打兔子，而玩家与猎狗之间是友军（互不攻击）。
 */
export function createDemoFactions(): Factions {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
}

/**
 * 挑出生点：**等距抽样** + 避开采摘点。
 *
 * ★ 不用随机：同一个种子要跑出同一批位置（回放与截图比对都依赖这条）。
 * ★ 避开玩家出生点 2 格内：出生就贴脸会让"第一次看见怪物"变成"被怪物淹没"。
 */
export function pickDemoMobSpots(grid: NavGrid, hounds: number, rabbits: number, avoidCell: number): MobSpot[] {
  const walk: number[] = [];
  const ax = grid.cellX(avoidCell);
  const az = grid.cellZ(avoidCell);
  for (let i = 0; i < grid.total; i++) {
    if (!grid.isWalkableIndex(i)) continue;
    const cx = grid.cellX(i);
    const cz = grid.cellZ(i);
    if (Math.abs(cx - ax) <= 2 && Math.abs(cz - az) <= 2) continue;
    walk.push(i);
  }
  const total = hounds + rabbits;
  const out: MobSpot[] = [];
  if (walk.length === 0) return out;
  const stride = Math.max(1, Math.floor(walk.length / total));
  for (let k = 0; k < total; k++) {
    const cell = walk[Math.min(walk.length - 1, k * stride)];
    if (cell === undefined) continue;
    out.push({ template: k < hounds ? 1 : 0, cell });
  }
  return out;
}

/**
 * 猎物再生（批126）。
 *
 * ★★ 为什么需要它：捕食者不会吃饱、猎物不会再生 ⇒ **任何**有限数量都会被吃光。
 *   实测（`tests/host/demo-ecology.test.ts`）：3 只猎狗 3.5 秒吃光 10 只兔子，
 *   之后地图上只剩猎狗可打。调伤害/冷却只能把归零推迟（算术见 `docs/PROGRESS.md` 批126），
 *   所以这是**一条规则**，不是一次调参。
 * ★ 数字的取向：
 *   · `everyTicks: 90`（3 秒一只）—— 再密就成了"割草机背景下不断冒兔子"；
 *   · `max: 10` —— 与出生数量一致：被打光之后大约 30 秒回满，而不是"越打越多"；
 *   · `minCells: 6` —— 贴脸重生 = 凭空出现（玩家一转身就撞上）；
 *   · `maxCells: 14` —— 太远等于没重生；
 *   · `blockCells: 2` —— 生成在活物 1 格外 = 生成即被杀（`respawned` 照涨、地图照空）。
 */
export const DEMO_PREY_RESPAWN = {
  everyTicks: 90,
  kind: "rabbit",
  template: "rabbit",
  max: 10,
  minCells: 6,
  maxCells: 14,
  blockCells: 2,
} as const;
