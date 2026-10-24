/**
 * L4 · 制作（阶段 3：「材料有用途」）
 *
 * 只做一件事：**按配方把材料换成产物**，并且保证"要么换成了，要么一点没动"。
 *
 * ★★ 五个决定：
 *
 * ① **先全量检查，再一次性扣材料**。按顺序"检查一项扣一项"的实现在第二项不足时
 *    已经把第一项扣掉了 —— 玩家看到的是"材料少了，东西没做出来"。
 *    这个错误在"材料刚好够"的语料上完全正常，只有缺料时才现形。
 *
 * ② **产物放不进背包 ⇒ 回滚材料**（`CRAFT.NO_SPACE`）。这是唯一需要**真回滚**的地方：
 *    `addItem` 的成败只有试过才知道，而试之前材料已经扣了。
 *    不回滚的后果是"材料变空气" —— 比"做不出来"严重得多。
 *
 * ③ **缺料要说得清缺什么**（`missing: [{kind, need, have}]`），不是一句"材料不足"。
 *    只说"材料不足"的时候，玩家只能挨个去数背包；而缺什么、缺几个是**已知的**。
 *
 * ④ **配方 id 是主键，且必须唯一**。产物可能同名（两根配方都产 rope），
 *    "改哪一条配方"这件事只能靠 id 说清。
 *
 * ⑤ **一次 craft 只产一次，数量写死在配方里**。不做 `times` 参数：
 *    多份制作在"材料刚好够两份的一半"时会引出"做了一份半"这种没法表达的状态，
 *    而调用方要连做 N 次只需要写一个循环。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { addItem, countItem, takeItem } from "../inventory/inventory.ts";

/** 配方表本身不合法（不是数组 / 有重复 id / 材料或产物写错）。 */
export const RECIPE_BAD_TABLE = "CRAFT.BAD_TABLE";
/** 配方 id 不存在。 */
export const RECIPE_UNKNOWN = "CRAFT.UNKNOWN_RECIPE";
/** 材料不足（`detail.missing` 里带清单）。 */
export const RECIPE_MISSING = "CRAFT.MISSING";
/** 产物放不进背包（材料已回滚）。 */
export const RECIPE_NO_SPACE = "CRAFT.NO_SPACE";
/** 拥有者不存在 / 没有背包。 */
export const RECIPE_NO_OWNER = "CRAFT.NO_OWNER";

/** 一份材料的需要量。 */
export interface ItemCost {
  readonly kind: string;
  readonly count: number;
}

export interface Recipe {
  /** 主键（唯一、非空）。 */
  readonly id: string;
  /** 人看得懂的名字（HUD/toast 用；引擎不解释它）。 */
  readonly name: string;
  readonly inputs: readonly ItemCost[];
  readonly output: ItemCost;
}

/** 缺料清单里的一项。 */
export interface MissingItem extends ItemCost {
  readonly have: number;
}

/**
 * 把"配表原文"变成可信的 `Recipe[]`。
 *
 * ★ 每项非法值都**点名到具体字段**（`detail.field`）：报"配方表不合法"让人只能一行行看。
 * ★ 顺序**原样保留**（不排序）：调用方按表序找"第一条能做的"，而表序是人写的意图。
 */
export function normalizeRecipes(raw: unknown): Result<readonly Recipe[], EngineError> {
  if (!Array.isArray(raw)) {
    return err(engineError(RECIPE_BAD_TABLE, "配方表必须是数组"));
  }
  if (raw.length === 0) {
    // 空表几乎一定是"忘了填"：它能正常工作，只是世界里什么都做不出来。
    return err(engineError(RECIPE_BAD_TABLE, "配方表是空的 —— 多半是忘了填，而不是真的不想让人做东西"));
  }
  const seen = new Set<string>();
  const out: Recipe[] = [];
  for (const [i, item] of raw.entries()) {
    const at = `[${i}]`;
    if (typeof item !== "object" || item === null || Array.isArray(item)) {
      return err(engineError(RECIPE_BAD_TABLE, `配方${at} 必须是对象`, { field: at }));
    }
    const r = item as Record<string, unknown>;
    const id = r.id;
    if (typeof id !== "string" || id === "") {
      return err(engineError(RECIPE_BAD_TABLE, `配方${at}.id 必须是非空字符串`, { field: `${at}.id` }));
    }
    if (seen.has(id)) {
      // id 是主键：重复的 id 会让"改哪一条"变成猜
      return err(engineError(RECIPE_BAD_TABLE, `配方 id 重复："${id}"`, { field: `${at}.id`, id }));
    }
    seen.add(id);
    const name = r.name;
    if (typeof name !== "string" || name === "") {
      return err(engineError(RECIPE_BAD_TABLE, `配方 ${id}.name 必须是非空字符串`, { field: `${id}.name`, id }));
    }
    const rawIn = r.inputs;
    if (!Array.isArray(rawIn) || rawIn.length === 0) {
      return err(
        engineError(RECIPE_BAD_TABLE, `配方 ${id}.inputs 必须是非空数组（没有材料的配方等于白送）`, {
          field: `${id}.inputs`,
          id,
        }),
      );
    }
    const inputs: ItemCost[] = [];
    for (const [k, c] of rawIn.entries()) {
      const cost = asCost(c);
      if (typeof cost === "string") {
        return err(
          engineError(RECIPE_BAD_TABLE, `配方 ${id}.inputs[${k}] 写错了：${cost}`, {
            field: `${id}.inputs[${k}]`,
            id,
          }),
        );
      }
      inputs.push(cost);
    }
    const output = asCost(r.output);
    if (typeof output === "string") {
      return err(engineError(RECIPE_BAD_TABLE, `配方 ${id}.output 写错了：${output}`, { field: `${id}.output`, id }));
    }
    out.push({ id, name, inputs, output });
  }
  return ok(out);
}

/** 成功返回成本项；失败返回**一句为什么**（调用方补上位置信息）。 */
function asCost(v: unknown): ItemCost | string {
  if (typeof v !== "object" || v === null || Array.isArray(v)) return "必须是 {kind, count} 对象";
  const o = v as { kind?: unknown; count?: unknown };
  if (typeof o.kind !== "string" || o.kind === "") return "kind 必须是非空字符串";
  if (!Number.isInteger(o.count) || (o.count as number) <= 0) {
    return `count 必须是正整数，收到 ${String(o.count)}（0 会做出"不需要材料"的配方）`;
  }
  return { kind: o.kind, count: o.count as number };
}

/** 缺什么、缺几个。空数组 = 材料齐了。 */
export function missingFor(scene: Scene, ownerId: number, recipe: Recipe): MissingItem[] {
  const out: MissingItem[] = [];
  for (const cost of recipe.inputs) {
    const have = countItem(scene, ownerId, cost.kind);
    if (have < cost.count) out.push({ kind: cost.kind, count: cost.count, have });
  }
  return out;
}

export interface CraftReport {
  readonly recipeId: string;
  /** 实际扣掉的材料（按配方顺序）。 */
  readonly consumed: readonly ItemCost[];
  /** 产物。 */
  readonly output: ItemCost;
  /** 产物实际进了几个（正常情况下等于 `output.count`）。 */
  readonly added: number;
}

/**
 * 做一次 `recipe`。
 *
 * 顺序（见文件头 ①②）：
 *   配方已归一化 → 拥有者有背包 → **全量检查缺料** → 扣材料 → 加产物 → （加不进）回滚材料
 */
export function craft(scene: Scene, ownerId: number, recipe: Recipe): Result<CraftReport, EngineError> {
  const node = scene.find(ownerId);
  if (node === undefined || node === null) {
    return err(engineError(RECIPE_NO_OWNER, `节点 ${String(ownerId)} 不在场景里`));
  }
  // ---- ① 全量检查：缺料时**一点材料都不扣**
  const missing = missingFor(scene, ownerId, recipe);
  if (missing.length > 0) {
    const desc = missing.map((m) => `${m.kind} ${String(m.have)}/${String(m.count)}`).join("、");
    return err(
      engineError(RECIPE_MISSING, `材料不足：${desc}`, {
        recipeId: recipe.id,
        missing: missing.map((m) => ({ kind: m.kind, need: m.count, have: m.have })),
      }),
    );
  }

  // ---- 扣材料。全部检查过才走到这里，所以这里失败只可能是"别的代码同时在动背包"
  const consumed: ItemCost[] = [];
  for (const cost of recipe.inputs) {
    const r = takeItem(scene, ownerId, cost.kind, cost.count);
    if (!r.ok) {
      // 走到这里说明世界被别处改了。把已扣的**还回去**，不留半成品状态。
      for (const back of consumed) addItem(scene, ownerId, back.kind, back.count);
      return err(
        engineError(RECIPE_MISSING, `扣材料时 ${cost.kind} 不够（${r.error.message}）—— 已回滚`, {
          recipeId: recipe.id,
          rolledBack: consumed.map((c) => ({ kind: c.kind, count: c.count })),
        }),
      );
    }
    consumed.push(cost);
  }

  // ---- 加产物（见文件头 ②：放不下就回滚材料）
  const added = addItem(scene, ownerId, recipe.output.kind, recipe.output.count);
  if (!added.ok) {
    for (const back of consumed) addItem(scene, ownerId, back.kind, back.count);
    return err(
      engineError(
        RECIPE_NO_SPACE,
        `产物「${recipe.output.kind}×${String(recipe.output.count)}」放不进背包（${added.error.code}）—— 材料已退回`,
        { recipeId: recipe.id, rolledBack: consumed.map((c) => ({ kind: c.kind, count: c.count })) },
      ),
    );
  }

  return ok({
    recipeId: recipe.id,
    consumed,
    output: recipe.output,
    added: added.value,
  });
}

/** 表里第一条**现在就能做**的配方（表序即优先级）。全做不了返回 `undefined`。 */
export function firstCraftable(
  scene: Scene,
  ownerId: number,
  recipes: readonly Recipe[],
): Recipe | undefined {
  for (const r of recipes) {
    if (missingFor(scene, ownerId, r).length === 0) return r;
  }
  return undefined;
}
