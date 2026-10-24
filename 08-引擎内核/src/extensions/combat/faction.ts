/**
 * L4 · 阵营与关系（阶段 3：**别砍自己人**）
 *
 * 批61 的 `attack()` 只有一个"能不能打到"的判据（距离 + 冷却），于是混战里
 * 猎人会照着队友的后背砍 —— 而这在统计上完全看不出来（`hits` 照涨、`kills` 照涨），
 * 只有盯着屏幕才发现"怎么自己人掉血了"。
 *
 * ★★ 四个决定：
 *
 * ① **关系表只在"组"之间，不在"节点"之间**。
 *    节点级的关系（"这只狼和那只狼是父子"）属于业务，引擎不该有；而
 *    "猎人 vs 兔子"这种组级关系是任何有战斗的游戏都要的。
 *    组名是**字符串**（`"hunter"` / `"prey"`），引擎不认识它们的含义 ——
 *    与 `pickup` 的 `amount`、背包的 `kind`、`Team` 的角色名同一个取舍。
 *
 * ② **空串 = 中立，而且"两个中立"不算同队**。
 *    不这么定的话会出现两种都很难查的故障：
 *    · 若"空串 == 空串"算同队，则**所有没编队的怪互不攻击**，世界一片祥和；
 *    · 若"没有阵营组件"算"不可攻击"，则新加的怪**打不动**，而 AI 照旧锁定它
 *      —— 症状是"锁定了但一下不打"，与配表错误长得一模一样。
 *    所以：`stanceOf("", "") === "neutral"`，且 neutral **不是**免战牌。
 *
 * ③ **关系对称，且由一次调用写两边**。
 *    `setStance("hunter","prey","foe")` 同时写 hunter→prey 与 prey→hunter。
 *    让调用方写两次是**必然**会漏一次的接口（"我明明设了敌对，怎么它不还手"），
 *    而漏掉的那一半只在"反向那一击"上暴露。
 *
 * ④ **同队关系不可配**：`setStance(a, a, ...)` 报错，不是覆盖。
 *    同队恒为 ally 是**不变量**，不是配置项。要让队友互砍请走
 *    `attack({ friendlyFire: true })`（沙盒/测试用），而不是把不变量改掉 ——
 *    后者会留下一个"这个队伍内部互相敌对"的存档，且在读档后依然生效。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 阵营组件类型。 */
export const FACTION_TYPE = "combat.faction";

/** 参数不合法（空阵营名、未知关系、自反关系）。 */
export const FACTION_BAD_INPUT = "FACTION.BAD_INPUT";

/** 立场：盟友 / 敌人 / 中立。只有 `ally` 会被 `attack()` 拦下。 */
export type Stance = "ally" | "foe" | "neutral";

export const STANCES: readonly Stance[] = ["ally", "foe", "neutral"];

export function isStance(v: string): v is Stance {
  return (STANCES as readonly string[]).includes(v);
}

export class FactionMember extends Component {
  /** 阵营名。**空串 = 中立**（在场但没编队）。 */
  team = "";

  readonly schema: ComponentSchema = {
    type: FACTION_TYPE,
    fields: { team: FieldType.String },
  };
}

export function registerFactionComponent(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(FACTION_TYPE)) registry.register(new FactionMember().schema, () => new FactionMember());
}

/**
 * 读一个节点的阵营。
 *
 * 返回 `{ team, hasComponent }` 而不是裸字符串：调用方偶尔需要区分
 * "它没装阵营组件"与"它装了但没编队"（前者是配置遗漏，后者是有意的中立）。
 * **两者在关系判定上等价**（都是 `""`），这个区分只用于诊断。
 */
export function teamOf(scene: Scene, nodeId: number): { team: string; hasComponent: boolean } {
  const node = scene.find(nodeId);
  if (node === undefined || node === null) return { team: "", hasComponent: false };
  const m = node.get<FactionMember>(FACTION_TYPE);
  if (m === undefined) return { team: "", hasComponent: false };
  return { team: m.team, hasComponent: true };
}

interface Pair {
  readonly a: string;
  readonly b: string;
}

/**
 * 关系表。
 *
 * ★ 只存**非默认**关系：默认（未声明）= `neutral`。
 *   把默认值也存一遍的代价是"表里全是 neutral"，于是 `pairs()` 的用途
 *   （人要看真实配置）就没了。
 */
export class Factions {
  /** a → (b → stance)，**恒定对称**写入，见文件头 ③。 */
  private readonly table = new Map<string, Map<string, Stance>>();

  /**
   * 设置两个阵营的关系（**双向**）。
   *
   * 报错而非覆盖的三种情况（见文件头 ②④）：
   *  · `a`/`b` 为空串 —— 中立不是一个能用关系表编址的组（否则一次调用
   *    就把"世界上所有中立单位"变成某人的敌人，而调用方以为自己只设了一对）；
   *  · `a === b` —— 同队关系是不变量；
   *  · `stance` 不在 `STANCES` 里 —— 拼错的 `"foe "` 会被当成未知关系。
   */
  setStance(a: string, b: string, stance: Stance): Result<true, EngineError> {
    if (a.length === 0 || b.length === 0) {
      return err(engineError(FACTION_BAD_INPUT, `阵营名不能为空串（空串 = 中立，中立不参与关系表）：收到「${a}」/「${b}」`));
    }
    if (a === b) {
      return err(
        engineError(FACTION_BAD_INPUT, `不能给「${a}」和它自己设关系 —— 同队恒为 ally（要队友互砍请用 attack({friendlyFire:true})）`),
      );
    }
    if (!isStance(stance)) {
      return err(engineError(FACTION_BAD_INPUT, `未知关系「${String(stance)}」（只接受 ${STANCES.join(" / ")}）`));
    }
    this.put(a, b, stance);
    this.put(b, a, stance);
    return ok(true);
  }

  private put(a: string, b: string, stance: Stance): void {
    let row = this.table.get(a);
    if (row === undefined) {
      row = new Map<string, Stance>();
      this.table.set(a, row);
    }
    row.set(b, stance);
  }

  /**
   * 判两方的立场。
   *
   * 顺序（判据按这个顺序写）：
   *  1. 同名且非空 → `ally`（不查表）；
   *  2. 表里有 → 表里的值；
   *  3. 其余（含任一方为空串、含两方都空串）→ `neutral`。
   */
  stanceOf(a: string, b: string): Stance {
    if (a.length > 0 && a === b) return "ally";
    const got = this.table.get(a)?.get(b);
    return got ?? "neutral";
  }

  /** 是不是盟友（`attack()` 默认只拦这个）。 */
  isAlly(a: string, b: string): boolean {
    return this.stanceOf(a, b) === "ally";
  }

  /** 关系的只读快照（按 `a` 再按 `b` 升序）—— 日志与判据读它不会因插入序而变。 */
  pairs(): ReadonlyArray<Pair & { stance: Stance }> {
    const out: Array<Pair & { stance: Stance }> = [];
    for (const [a, row] of this.table) {
      for (const [b, stance] of row) out.push({ a, b, stance });
    }
    out.sort((x, y) => (x.a !== y.a ? (x.a < y.a ? -1 : 1) : x.b < y.b ? -1 : x.b > y.b ? 1 : 0));
    return out;
  }
}

export function createFactions(): Factions {
  return new Factions();
}
