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
 * 三种活物。
 *
 * ★ 名字要与图集里的帧名一致（见 `DEMO_FRAMES`）—— 两边写错一个字的症状是
 *   「生物在走但看不见」，而渲染模块只会 warn。
 * ★ 兔子 `damage: 0`：不挂攻击组件 ⇒ 只跑不打（见 `spawn-mob.ts` 文件头 ③）。
 *
 * ★★ 拾荒者（批167）是**唯一带 `carry` / `hunger` 的一只**，而这不是随手选的：
 *   `mob-world.ts` ② 的语义是「猎狗打死兔子 ⇒ 猎狗没有背包 ⇒ `LOOT.NO_OWNER` ⇒
 *   计入 `lootNoRecipient`，且与 `lootLost`（包满了）分开」。**给猎狗挂背包会把它
 *   悄悄改掉**（肉进猎狗的包、`lootNoRecipient` 归零，而所有计数都自洽）。
 *   所以能力挂在新来的这一只上，老的两种一个字段都不动。
 *   判据 `[生态] ★ 猎狗仍然没有背包` 钉住"老语义没被默认值接管"。
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
  {
    // ★ 只捡不吃亏：`carry` 让它能拾取、`hunger` 让它会饿（饿了就吃包里的）。
    //   `damage: 0` ⇒ 不挂攻击组件 ⇒ 它不会参与打架（生态数字不受影响）。
    //   队伍独立：不设任何 stance ⇒ 与猎狗、玩家都是友好，谁都打不了它、
    //   它也打不了谁。★ 与 prey 同队会让猎狗顺手把它吃掉，那不是"拾荒"该有的样子。
    kind: "scavenger",
    frame: "scavenger",
    width: 1.0,
    height: 1.0,
    radius: 0.3,
    maxHp: 5,
    damage: 0,
    range: 1.4,
    cooldownTicks: 20,
    speed: 1.0,
    team: "scavenger",
    loot: [],
    // 3 格 × 每格 5 个：够它边捡边吃，但装不下半张地图的浆果。
    carry: { stacks: 3, stack: 5 },
    // 100 = 满饱食；低于 50% 才找吃的（见 `MobBrainOptions.hungryBelowPercent`）
    hunger: 100,
  },
] as const;

/** 出生数量：3 只猎狗、10 只兔子、2 只拾荒者。 */
export const DEMO_HOUNDS = 3;
export const DEMO_RABBITS = 10;
/**
 * 拾荒者数量（批167）。
 *
 * ★ 为什么只有 2 只：它们会**真的把地上的浆果捡走并吃掉**（那是玩家的采集资源）。
 *   数量一多，"走进林子发现浆果没了"就变成主要体验 —— 而这一只存在的目的是
 *   让「AI 会捡东西」这件事看得见，不是来抢资源的。
 */
export const DEMO_SCAVENGERS = 2;

/**
 * 随包发的决策树文件（**相对 `web/assets/`**，批156）。
 *
 * ★★ 为什么是一张显式的清单，而不是"扫一遍目录"：
 *   浏览器的资产源是静态资源服务器（`HttpFileSystem` 的 `canList === false`），
 *   **没有列目录这个操作**。而小游戏包里也没有 —— 目录信息在构建期就丢了。
 *   所以"这一局有哪几棵树"必须是数据，不能靠运行时枚举。
 *   ★ 与 `DEMO_FRAMES` 同一条理由的另一面：清单在这里，判据才能逐条核对
 *     「清单里的文件真的存在、真的能解析、推出来的 id 真的是组件里写的那个」——
 *     而这三件事任何一件坏了，症状都只是"怪的脾气没变"。
 */
export const DEMO_TREE_FILES = ["ai/hound.tree.json", "ai/hound_grudge.tree.json"] as const;

/**
 * 猎狗默认用哪棵：`ai/hound.tree.json` 去掉后缀。
 *
 * ★ 就是 `treeAssetIdFromPath` 的输出。判据断言两者相等（`demo-trees.test.ts`），
 *   于是"改文件名却忘了改这里"会红在测试里，而不是变成一次静默的 `miss`。
 */
export const DEMO_HOUND_TREE = "ai/hound";

/**
 * 关系表是**宿主**的配置（引擎不认识"猎人"）：玩家与猎狗同队，兔子是猎物。
 * 于是猎狗会追兔子、玩家能打兔子，而玩家与猎狗之间是友军（互不攻击）。
 *
 * ★★ 拾荒者必须**显式**设成 `ally`（批167）。第一版只给它一个独立的队名就收工，
 *   结果 `kills` 从 10 变成 12 —— 猎狗把它也吃了。原因是 `faction.ts` ① 那条：
 *   `stanceOf` 对没配过的两支返回 `neutral`，而 **neutral 不是免战牌**
 *   （只有 `ally` 会被 `attack()` 拦下）。所以"中立旁观者"这个意图
 *   在关系表里没有对应值，必须写成 ally。
 */
export function createDemoFactions(): Factions {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  f.setStance("hunter", "scavenger", "ally");
  f.setStance("prey", "scavenger", "ally");
  return f;
}

/**
 * 这一局出生多少只、各是哪一类（**模板下标**，见 `DEMO_MOB_TEMPLATES`）。
 *
 * ★ 用**下标**而不是 `kind`：`MobSpot.template` 就是下标，转一道 kind 只会
 *   多一个"名字写错 ⇒ 全部退回第 0 种"的失效方式，而且症状是"世界里全是兔子"
 *   —— 看起来像配表保守，不像 bug。
 */
export interface DemoSpotPlan {
  readonly hounds: number;
  readonly rabbits: number;
  readonly scavengers: number;
}

/**
 * 挑出生点：**等距抽样** + 避开采摘点。
 *
 * ★ 不用随机：同一个种子要跑出同一批位置（回放与截图比对都依赖这条）。
 * ★ 避开玩家出生点 2 格内：出生就贴脸会让"第一次看见怪物"变成"被怪物淹没"。
 * ★★ **两类生物用两套抽样，这不是洁癖**。第一版把拾荒者算进同一个 `total`，
 *   于是 `stride = walk / 15` 而不是 `/ 13` —— 猎狗与兔子的**每一个出生点都挪了位置**。
 *   后果不是"画面变了"，是**捕食链的节奏变了**：实测归零时间从 360 拍退到 790 拍，
 *   而开了再生之后还会出现「某一拍地图上一只兔子都没有」（批126 的两条判据当场红）。
 *   拾荒者是旁观者，它不该改变"三只猎狗多久吃光十只兔子"。
 *   所以：捕食链那两类仍按旧基准（`hounds + rabbits`）等距取样，**逐项与旧的相同**；
 *   拾荒者另取一批**没被占用的**格。
 */
export function pickDemoMobSpots(grid: NavGrid, plan: DemoSpotPlan, avoidCell: number): MobSpot[] {
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
  const out: MobSpot[] = [];
  if (walk.length === 0) return out;

  // ---- ① 捕食者与被捕食者：基准只数这两类（见 ★★）
  const base = plan.hounds + plan.rabbits;
  if (base > 0) {
    const stride = Math.max(1, Math.floor(walk.length / base));
    for (let k = 0; k < base; k++) {
      const cell = walk[Math.min(walk.length - 1, k * stride)];
      if (cell === undefined) continue;
      out.push({ template: k < plan.hounds ? 1 : 0, cell });
    }
  }

  // ---- ② 拾荒者：在**剩下的**格子里等距取（不与上面撞格：同格出生会被物理推开，
  //      而"被推开"与"自己走过去"在截图里分不开）
  if (plan.scavengers > 0) {
    const taken = new Set<number>(out.map((s) => s.cell));
    const free = walk.filter((c) => !taken.has(c));
    const n = Math.min(plan.scavengers, free.length);
    for (let j = 0; j < n; j++) {
      const cell = free[Math.floor(((j + 0.5) * free.length) / n)];
      if (cell === undefined) continue;
      out.push({ template: 2, cell });
    }
  }
  return out;
}

/**
 * 旁观者：既不参加战斗、也不会被战斗波及的种类（批167）。
 *
 * ★ 它存在是为了回答**一个问题**：「重生落点要不要避开它」。答案是不要 ——
 *   拾荒者与猎物是 `ally`，兔子生成在它旁边既不会被吃掉、也不会互相打；
 *   把它算进阻挡只会让候选集变小，而候选一变，`pickPreyCell` 的
 *   `mix32 % cand.length` 就选到**别的格**，整条重生时间线从此分叉
 *   （实测：分叉之后满地图的空拍从 0 变成 123 拍）。
 *
 * ★ 为什么是函数而不是在每个收集点写 `kind === "scavenger"`：收集点有两处
 *   （宿主 `pickPreySpawnCell` 与生态判据的 `pickCell`），写两遍的那一份必然漂移。
 */
export function isDemoBystander(kind: string | null): boolean {
  // `MobWorldHandle.templateOf` 对"已经不在了的节点"返回 `null` —— 那不是旁观者，
  // 而是"查不到"。两者绝不能合并：把 `null` 当旁观者会把**所有**死掉的怪
  // 从阻挡集里漏掉，而症状是"兔子重生在猎狗脸上"。
  return kind === "scavenger";
}

/**
 * 猎物再生（批126）。
 *
 * ★★ 为什么需要它：捕食者不会吃饱、猎物不会再生 ⇒ **任何**有限数量都会被吃光。
 *   实测（`tests/host/demo-ecology.test.ts`）：3 只猎狗 3.5 秒吃光 10 只兔子，
 *   之后地图上只剩猎狗可打。调伤害/冷却只能把归零推迟（算术见 `docs/PROGRESS.md` 批126），
 *   所以这是**一条规则**，不是一次调参。
 * ★ 数字的取向：
 *   · `everyTicks: 75`（2.5 秒一只）—— 再密就成了"割草机背景下不断冒兔子"；
 *   · `max: 10` —— 与出生数量一致：被打光之后大约 30 秒回满，而不是"越打越多"；
 *   · `minCells: 6` —— 贴脸重生 = 凭空出现（玩家一转身就撞上）；
 *   · `maxCells: 14` —— 太远等于没重生；
 *   · `blockCells: 2` —— 生成在活物 1 格外 = 生成即被杀（`respawned` 照涨、地图照空）。
 */
export const DEMO_PREY_RESPAWN = {
  // ★ 批167 从 90 改成 75。不是"为了过判据凑数"，而是那个世界本来就在临界：
  //   老世界里"地图上最少的兔子数"恰好是 **1**，多一只不参加战斗的旁观者就掉到 0
  //   （实测：1800 拍里 123 拍空着）。3 秒 → 2.5 秒让"补 >= 吃"有一点余量，
  //   观感上仍是"打光之后慢慢回满"，不是割草机。
  everyTicks: 75,
  kind: "rabbit",
  template: "rabbit",
  max: 10,
  minCells: 6,
  maxCells: 14,
  blockCells: 2,
} as const;
