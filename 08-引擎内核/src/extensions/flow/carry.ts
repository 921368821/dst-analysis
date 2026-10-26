/**
 * L4 · 关卡流程：跨场景携带（背着的东西跟着人走）
 *
 * 跳场景要回答的不是"换哪份世界"，而是**"换了世界之后他还是不是刚才那个人"**。
 * 没有这一层，跳过去就是"换了个人":背包空了、血满了、饱食度回 100 ——
 * 而画面完全正常（目标场景本来就有个玩家），人只会以为"过个门把我东西吃了"。
 *
 * ★★ 三条建模决定：
 *
 * ① **携带的是"值"，不是节点**。背包在世界里是子节点（`game.item`），
 *    但目标场景的玩家节点有它自己的背包容量（`maxStacks`/`maxStack` 是**目标场景
 *    作者配的**）。所以这里读出来的是纯数据（按 kind 聚合），写回去时**按目标的容量
 *    重新分堆** —— 搬节点会让源场景的容量配置跟着人跑，而那是关卡参数，不是人物属性。
 *
 * ② **装不下要如实记账，不许静默丢**。目标场景把背包配小时，超出的部分确实装不下；
 *    悄悄扔掉的话，"跳个门东西少了"会变成一条永远查不出来的怪事。
 *    所以 `applyCarry` 返回 `dropped`（丢弃了什么）与 `clamped`（被上限夹住了什么）。
 *
 * ③ **不搬运行期字段**：`combat.health.invulnUntil`（无敌截止 tick）不带走 ——
 *    它是"这一次受击的无敌窗口"，跨场景没有意义；`world.player.cell` 也不搬 ——
 *    那是目标场景里的出生格，属于场景。
 *
 * ★ 血量与饱食度都是**整数**（见 health.ts / hunger.ts 文件头）。这里不引入任何浮点：
 *   夹上限时用 `Math.min` 对整数，`value` 落下多少就是多少，不做比例换算 ——
 *   "按比例带血量"会让 12/20 变成 6/10，而玩家看到的是"我掉了 6 点血"。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { INVENTORY_TYPE, Inventory, addItem, stacksOf } from "../inventory/inventory.ts";
import { HEALTH_TYPE, Health } from "../combat/health.ts";
import { HUNGER_TYPE, Hunger } from "../survival/hunger.ts";

/** 一次携带的全部内容（纯数据，可存档、可比较、可跨越 `loadScene`）。 */
export interface CarryState {
  /** 背包里的东西，**按 kind 聚合且升序**（不保留源场景的堆划分，见文件头 ①）。 */
  readonly items: readonly { readonly kind: string; readonly count: number }[];
  /** 血量；目标玩家没有 `combat.health` 时这里是 `null`。 */
  readonly health: { readonly hp: number; readonly maxHp: number } | null;
  /** 饱食度；同上。 */
  readonly hunger: { readonly value: number; readonly max: number } | null;
}

export interface ApplyReport {
  /** 真的写回去的项（`items` / `health` / `hunger`）。 */
  readonly applied: readonly string[];
  /** 丢掉的项，每行一句人话。 */
  readonly dropped: readonly string[];
  /** 被目标上限夹住的项，每行一句人话。 */
  readonly clamped: readonly string[];
}

/** 空携带（场景里没有玩家时用它，"什么都没带"是合法状态，不是错误）。 */
export const EMPTY_CARRY: CarryState = { items: [], health: null, hunger: null };

/**
 * 从场景里的某个节点读出携带内容。
 *
 * 节点不存在 ⇒ 返回空携带而不是报错：调用方的语义是"跳场景时要带走什么"，
 * 没有玩家 = 没有要带的（第一次进游戏、或场景本来就没有玩家）。
 */
export function readCarry(scene: Scene, nodeId: number): CarryState {
  const node = scene.find(nodeId);
  if (node === undefined) return EMPTY_CARRY;

  // ★ 同名 kind 要合并：源场景可能有 3 堆 `wood`（各 40），那是"容量 8 格"的产物。
  //   原样搬 3 堆过去，目标场景容量更大时会出现"3 堆各 40 却只用了 3 格"的怪状态。
  const byKind = new Map<string, number>();
  for (const s of stacksOf(scene, nodeId)) {
    if (s.count <= 0) continue;
    byKind.set(s.kind, (byKind.get(s.kind) ?? 0) + s.count);
  }
  const items = [...byKind.entries()]
    .map(([kind, count]) => ({ kind, count }))
    .sort((a, b) => (a.kind < b.kind ? -1 : a.kind > b.kind ? 1 : 0));

  const hp = node.get<Health>(HEALTH_TYPE);
  const hg = node.get<Hunger>(HUNGER_TYPE);
  return {
    items,
    health: hp === undefined ? null : { hp: hp.hp, maxHp: hp.maxHp },
    hunger: hg === undefined ? null : { value: hg.value, max: hg.max },
  };
}

/**
 * 把携带内容写进场景里的某个节点。
 *
 * ★ 顺序是**先血后饱食再背包**：背包可能因为容量不足而部分失败，
 *   而血量/饱食度不该因为"背包没装下"就一起不写 —— 那是两件事。
 *   反过来（先背包）会让"背包满了 ⇒ 血也没带过来"这种耦合出现。
 */
export function applyCarry(scene: Scene, nodeId: number, carry: CarryState): ApplyReport {
  const applied: string[] = [];
  const dropped: string[] = [];
  const clamped: string[] = [];
  const node = scene.find(nodeId);
  if (node === undefined) {
    return {
      applied,
      dropped: [`节点 ${String(nodeId)} 不在场景里（携带内容全部丢掉）`],
      clamped,
    };
  }

  if (carry.health !== null) {
    const hp = node.get<Health>(HEALTH_TYPE);
    if (hp === undefined) {
      dropped.push(`血量（目标场景的玩家身上没有 ${HEALTH_TYPE}）`);
    } else {
      // 见文件头 ★：夹上限但不按比例换算
      const want = Math.max(0, carry.health.hp);
      if (want > hp.maxHp) {
        clamped.push(`血量 ${String(want)} → ${String(hp.maxHp)}（目标上限更低）`);
        hp.hp = hp.maxHp;
      } else {
        hp.hp = want;
      }
      applied.push("health");
    }
  }

  if (carry.hunger !== null) {
    const hg = node.get<Hunger>(HUNGER_TYPE);
    if (hg === undefined) {
      dropped.push(`饱食度（目标场景的玩家身上没有 ${HUNGER_TYPE}）`);
    } else {
      const want = Math.max(0, carry.hunger.value);
      if (want > hg.max) {
        clamped.push(`饱食度 ${String(want)} → ${String(hg.max)}（目标上限更低）`);
        hg.value = hg.max;
      } else {
        hg.value = want;
      }
      applied.push("hunger");
    }
  }

  if (carry.items.length > 0) {
    const inv = node.get<Inventory>(INVENTORY_TYPE);
    if (inv === undefined) {
      const total = carry.items.reduce((a, it) => a + it.count, 0);
      dropped.push(`背包 ${String(total)} 件（目标场景的玩家身上没有 ${INVENTORY_TYPE}）`);
    } else {
      let moved = 0;
      for (const it of carry.items) {
        moved += addUpTo(scene, nodeId, it.kind, it.count, inv.maxStack, dropped);
      }
      if (moved > 0) applied.push("items");
    }
  }

  scene.flush();
  return { applied, dropped, clamped };
}

/**
 * 尽力装：先按整份试一次（`addItem` 内部会合并同种堆并开新堆），
 * 整份装不下时退到"按单堆上限一步一步装"，装到装不下为止。
 *
 * ★ 为什么要分两步：`addItem` 是**全或无**的（它先算需要几个新堆，不够就整单拒绝），
 *   所以"整份试一次"在目标背包只小一格时会整单失败 —— 一整车木头全丢，
 *   而实际还能装下 7 堆。逐堆重试才是"装到装不下为止"。
 *
 * 返回值：真的装进去多少个。
 */
function addUpTo(
  scene: Scene,
  ownerId: number,
  kind: string,
  count: number,
  cap: number,
  dropped: string[],
): number {
  const step = Math.max(1, cap);
  let left = count;
  let moved = 0;
  while (left > 0) {
    const put = Math.min(left, step);
    const r = addItem(scene, ownerId, kind, put);
    if (!r.ok) break;
    left -= put;
    moved += put;
  }
  if (left > 0) dropped.push(`背包里的 ${kind}×${String(left)}（目标背包装不下）`);
  return moved;
}
