/**
 * L4 · 物品与背包（采集的**下游**）
 *
 * ★ 为什么这一层不能塞进 worldgen：采集（`harvestAt`）只回答"这东西没了"，
 *   "玩家得到了什么"是**经济/背包**的事。把物品写进世界生成，会让"世界"与"玩家档案"
 *   绑死 —— 而世界应该能被多个玩家共用、能被存档回滚、能脱离玩家单独生成。
 *
 * ★★ 两条必须说清的建模决定：
 *
 *   ① **一个堆叠 = 一个节点 + 一个 `game.item` 组件**。
 *      组件在一张节点上每种类型只能挂一个（`node.get(type)`），所以"若干堆叠"要么
 *      塞进一个字符串字段（存档里不可读、不可编辑），要么就是**子节点**。
 *      选子节点：每种堆叠是一等公民，能单独销毁（`take` 到 0 就删掉节点 ——
 *      这正是"名额释放"在背包里的对应物），也能被编辑器直接看见。
 *
 *   ② **两层上限**：`maxStacks`（几格）× `maxStack`（每格几个）。
 *      只有前者时，"1 格装 9999"是合法的 —— 面板一行写不下，且格子数形同虚设。
 *      到顶自动开新格、没格才报 `INVENTORY.FULL`（饥荒语义）。
 *
 * ★ 与采集的闭环是**显式**的：`harvestInto()` 一次做三件事 —— 摘节点、还名额、进背包。
 *   少做最后一件的症状是"树砍了、东西没进包"，而画面上树确实倒了，看不出来。
 */

import { Component, FieldType, type ComponentRegistry, type ComponentSchema } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 一堆物品的组件类型。 */
export const ITEM_TYPE = "game.item";
/** 背包（挂在拥有者节点上）的组件类型。 */
export const INVENTORY_TYPE = "game.inventory";

/** 拥有者节点上没有 `game.inventory` 组件。 */
export const INVENTORY_NO_OWNER = "INVENTORY.NO_OWNER";
/** 堆叠数已到上限（且没有可合并的同种堆叠，或溢出装不进新堆）。 */
export const INVENTORY_FULL = "INVENTORY.FULL";
/** 数量必须是正整数。 */
export const INVENTORY_BAD_COUNT = "INVENTORY.BAD_COUNT";
/** 存量不足。 */
export const INVENTORY_NOT_ENOUGH = "INVENTORY.NOT_ENOUGH";
/** 格子下标越界（拖拽落点算错、或那边的堆叠刚好被消耗掉了）。 */
export const INVENTORY_BAD_INDEX = "INVENTORY.BAD_INDEX";

export class ItemStack extends Component {
  /** 物品种类（与 `SiteKind` 同名，但不强绑：背包不认识"世界"）。 */
  kind = "";
  count = 0;

  readonly schema: ComponentSchema = {
    type: ITEM_TYPE,
    fields: { kind: FieldType.String, count: FieldType.Int },
  };
}

export class Inventory extends Component {
  /** 最多几堆（不是"最多几个"）。到上限再加"新种类"就报 `INVENTORY.FULL`。 */
  maxStacks = 8;
  /**
   * 单堆上限（饥荒默认 40）。**不是**"最多几个"：到顶会自动开新堆（有名额时），
   * 没有名额才报 `INVENTORY.FULL`。
   *
   * ★ 为什么需要它：`maxStacks` 管的是**格子数**，单堆无上限时"1 堆 × 9999"与
   *   "250 堆 × 40"都合法 —— 前者让背包面板一行写不下，后者让 `maxStacks` 形同虚设。
   *   两者都管，才是"几格、每格多少"的完整形状。
   */
  maxStack = 40;

  readonly schema: ComponentSchema = {
    type: INVENTORY_TYPE,
    fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int },
  };
}

export function registerInventoryComponents(registry: ComponentRegistry): void {
  if (!registry.has(ITEM_TYPE)) registry.register(ITEM_SCHEMA, () => new ItemStack());
  if (!registry.has(INVENTORY_TYPE)) registry.register(INVENTORY_SCHEMA, () => new Inventory());
}

const ITEM_SCHEMA: ComponentSchema = { type: ITEM_TYPE, fields: { kind: FieldType.String, count: FieldType.Int } };
const INVENTORY_SCHEMA: ComponentSchema = {
  type: INVENTORY_TYPE,
  fields: { maxStacks: FieldType.Int, maxStack: FieldType.Int },
};

/** 给节点挂上背包（已有就复用，幂等）。 */
export function makeInventory(scene: Scene, ownerId: number, maxStacks = 8, maxStack = 40): Result<Inventory, EngineError> {
  const owner = scene.find(ownerId);
  if (owner === undefined) return err(engineError(INVENTORY_NO_OWNER, `节点 ${String(ownerId)} 不在场景里`));
  const existing = owner.get<Inventory>(INVENTORY_TYPE);
  if (existing !== undefined) return ok(existing);
  const made = scene.attach(ownerId, () => {
    const inv = new Inventory();
    inv.maxStacks = maxStacks;
    inv.maxStack = maxStack;
    return inv;
  });
  if (!made.ok) return made;
  // ★ `attach` 是**结构性修改**（走命令队列），在 flush 之前 `get()` 读不到 ——
  //   少了这一句，`makeInventory` 会永远返回 NO_OWNER，而"背包明明挂上了"。
  scene.flush();
  const inv = owner.get<Inventory>(INVENTORY_TYPE);
  if (inv === undefined) return err(engineError(INVENTORY_NO_OWNER, "背包组件挂上之后又读不到"));
  return ok(inv);
}

/** 这个拥有者名下的所有堆叠（按节点 id 升序 —— 顺序稳定，判据与存档都好对）。 */
export function stacksOf(scene: Scene, ownerId: number): ItemStack[] {
  const owner = scene.find(ownerId);
  if (owner === undefined) return [];
  const out: ItemStack[] = [];
  owner.walk((n) => {
    if (n.id === ownerId) return;
    const it = n.get<ItemStack>(ITEM_TYPE);
    if (it !== undefined) out.push(it);
  });
  out.sort((a, b) => (a.node?.id ?? 0) - (b.node?.id ?? 0));
  return out;
}

/**
 * 交换两格的**内容**（拖拽换位）。
 *
 * ★ 换的是 `kind` / `count` 两个字段，**不是节点 id**。
 *   显示顺序由 `stacksOf` 的节点 id 升序决定，所以"换格子"有两条实现路径：
 *   换内容、或者换节点的 id/挂载顺序。选前者，因为：
 *   ① 换 id 要销毁重建节点，`game.item` 之外挂在同一节点上的东西会一起没；
 *   ② "这一格被选中"是宿主的 `bagSel` 下标，节点一换，选中态会跳到别的东西上；
 *   ③ 玩家的心智是「这两格的东西换一下」，不是「这两个节点换身份证」。
 *   代价是存档里堆叠的顺序与创建顺序不再一致 —— 那本来就没人保证过
 *   （`stacksOf` 只承诺「按 id 升序」，不承诺「按拾取顺序」）。
 *
 * ★ 越界**报错**，不静默返回。
 *   拖拽的落点是像素算出来的，落空（拖到面板外、拖到两行之间的缝里）是常态；
 *   静默的话症状是"拖了没反应"，而它可以由十几种原因造成 ——
 *   报错至少把"落点不在任何格子上"这一类当场排掉。
 *
 * ★ `a === b` 是合法 no-op（按下去没动就松手）：不报错、不交换、不改任何字段。
 *   判据要能区分它和"真的换了"（换了两格内容相同的堆叠，字段值也没变）。
 */
export function swapStacks(
  scene: Scene,
  ownerId: number,
  a: number,
  b: number,
): Result<void, EngineError> {
  const stacks = stacksOf(scene, ownerId);
  const n = stacks.length;
  const bad = (i: number): boolean => !Number.isInteger(i) || i < 0 || i >= n;
  if (bad(a) || bad(b)) {
    return err(
      engineError(INVENTORY_BAD_INDEX, `格子下标越界：${String(a)} / ${String(b)}（当前 ${String(n)} 格）`, {
        a,
        b,
        count: n,
      }),
    );
  }
  if (a === b) return ok(undefined);
  const x = stacks[a]!;
  const y = stacks[b]!;
  const kind = x.kind;
  const count = x.count;
  x.kind = y.kind;
  x.count = y.count;
  y.kind = kind;
  y.count = count;
  return ok(undefined);
}

export function countItem(scene: Scene, ownerId: number, kind: string): number {
  let n = 0;
  for (const s of stacksOf(scene, ownerId)) if (s.kind === kind) n += s.count;
  return n;
}

function isPositiveInt(v: number): boolean {
  return Number.isInteger(v) && v > 0;
}

/**
 * 单堆上限的**防御性读取**。
 * ★ 存档里可能带着这一版的坏值（0 / 负数 / 小数）：此时宁可保守地当成 1
 *   （立刻会因为疯狂开新堆而暴露），也不能假装正常 —— 后者是静默的错误形状。
 */
function stackCapOf(inv: Inventory): number {
  const v = inv.maxStack;
  if (!Number.isInteger(v) || v < 1) return 1;
  return v;
}

/** 装满 `total` 个需要几个新堆（每堆 `cap` 个）。 */
function stacksNeeded(total: number, cap: number): number {
  return Math.max(1, Math.ceil(total / cap));
}

/**
 * 加物品。**先合并，再按需开新堆** —— 否则砍 100 次树会得到 100 个"1 个木头"的堆叠，
 * 于是 `maxStacks` 会在第 9 次就报满，而玩家明明只捡了一种东西。
 *
 * ★★ 原子性：**要么全装下，要么一点不动**。半途开两个堆叠再失败，会把"这次加了几个"
 *   变成猜谜；`harvestInto` 的"先进包后摘"也依赖这条 —— 包装一半就摘资源，
 *   玩家平白少几个。所以开堆的名额在**任何结构性修改之前**一次算清。
 */
export function addItem(scene: Scene, ownerId: number, kind: string, n: number): Result<number, EngineError> {
  if (!isPositiveInt(n)) {
    return err(engineError(INVENTORY_BAD_COUNT, `数量必须是正整数，收到 ${String(n)}`));
  }
  const owner = scene.find(ownerId);
  if (owner === undefined) return err(engineError(INVENTORY_NO_OWNER, `节点 ${String(ownerId)} 不在场景里`));
  const inv = owner.get<Inventory>(INVENTORY_TYPE);
  if (inv === undefined) return err(engineError(INVENTORY_NO_OWNER, `节点 ${String(ownerId)} 没有背包组件`));

  const cap = stackCapOf(inv);
  const stacks = stacksOf(scene, ownerId);
  const free = Math.max(0, inv.maxStacks - stacks.length);
  const same = stacks.filter((s) => s.kind === kind);

  // 需要几个**新**堆：同种堆自己不占新名额，只算溢出；没有同种堆时整份都要新堆
  const total = n + same.reduce((a, s) => a + s.count, 0);
  const needNew = Math.max(0, stacksNeeded(total, cap) - same.length);
  if (needNew > free) {
    return err(
      engineError(
        INVENTORY_FULL,
        `背包已满（${String(inv.maxStacks)} 堆 × ${String(cap)}），${kind} 溢出 ${String(needNew - free)} 堆放不下`,
      ),
    );
  }

  // ---- 从这里开始一定成功：先合并（**所有**同种堆按序填满），再开新堆 ----
  let left = n;
  for (const s of same) {
    if (left === 0) break;
    const put = Math.min(cap - s.count, left);
    s.count += put;
    left -= put;
  }
  while (left > 0) {
    const put = Math.min(cap, left);
    const spawned = scene.spawn(`item/${kind}`, ownerId);
    if (!spawned.ok) return spawned;
    // ★ `spawn` 只是**入队**：节点在 `flush()` 之前不在场景索引里，此时 `attach` 会失败，
    //   而失败信息看起来像"组件挂不上"，实际是"节点还不存在"。
    scene.flush();
    const nodeId = spawned.value.id;
    const made = scene.attach(nodeId, () => {
      const s = new ItemStack();
      s.kind = kind;
      s.count = put;
      return s;
    });
    if (!made.ok) {
      scene.destroy(nodeId);
      scene.flush();
      return made;
    }
    left -= put;
  }
  scene.flush();
  return ok(countItem(scene, ownerId, kind));
}

/**
 * 取物品。取到 0 的堆叠**销毁节点**（与采集的"名额释放"同一个道理：
 * 不清掉空壳，`maxStacks` 会被一堆 count=0 的残骸占满）。
 */
export function takeItem(scene: Scene, ownerId: number, kind: string, n: number): Result<number, EngineError> {
  if (!isPositiveInt(n)) {
    return err(engineError(INVENTORY_BAD_COUNT, `数量必须是正整数，收到 ${String(n)}`));
  }
  const has = countItem(scene, ownerId, kind);
  if (has < n) {
    return err(engineError(INVENTORY_NOT_ENOUGH, `只有 ${String(has)} 个 ${kind}，要取 ${String(n)} 个`));
  }
  let left = n;
  for (const s of stacksOf(scene, ownerId)) {
    if (left === 0) break;
    if (s.kind !== kind) continue;
    const take = Math.min(s.count, left);
    s.count -= take;
    left -= take;
    if (s.count === 0) {
      const id = s.node?.id;
      if (id !== undefined) scene.destroy(id);
    }
  }
  scene.flush();
  return ok(n);
}
