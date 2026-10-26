/**
 * L4 · 关卡流程：传送门（走进一扇门 → 换一份场景）
 *
 * 这一层回答一个问题：**"玩家站在哪儿"什么时候算"走进了另一个场景"**。
 * 在这之前，工程里可以有很多份场景（批90），但游戏跑起来永远只玩到当前那一份 ——
 * 多场景的价值停在编辑器里。传送门就是那个把两边接起来的零件。
 *
 * ★★ 四条容易做错、做错了**在画面上完全看不出来**的规则：
 *
 * ① **只在"跨进来"的那一次触发，站着不动不许重复触发**。
 *    最直觉的实现是"距离 < 半径就跳" —— 于是玩家在门里站着的那几帧会每帧都跳：
 *    第一次跳到目标场景，目标场景又把玩家放在一扇门里，于是第二次再跳……
 *    症状是"进门黑屏抖动一下回到原地"，而日志里只有一串成功的跳转。
 *    所以这一层是一个**边沿状态机**：记住"上一刻离他最近的是哪一扇门"，只有这个名字变化才产生事件。
 *
 * ② **落地时已经在门里 ⇒ 不算跨进来**（`reseed`）。
 *    与 ① 是同一件事的另一半：跳转把玩家放到目标场景的落点上，而那个落点**很可能
 *    就是目标场景里通往源场景的那扇门**（这是关卡设计里最常见的样子：两扇门互相对接）。
 *    不 reseed 的话，A→B 一落地就立刻 B→A，来回弹到线程爆掉。
 *
 * ③ **重叠时触发"最近的那一扇"**，平手按名字升序。用遍历顺序决定的话，
 *    门的先后取决于场景里的挂载顺序 —— 同一次点击在两次运行里跳向不同场景。
 *
 * ④ **半径与坐标都是定点整数**（1 格 = `FIXED_UNITS` = 256）。理由与出生点、资源投放
 *    同一个：`dx² + dz² ≤ r²` 全整数比较，不含浮点舍入，判据里能写等号。
 *
 * ★ 不做的：门没有"开/关"状态、没有方向性（走进走出都触发）、没有渐隐过场。
 *   这三件都要先有"过场"这个概念 —— 那是表现层的事，不是流程层的事。
 */

import {
  Component,
  FieldType,
  type ComponentRegistry,
  type ComponentSchema,
} from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { FIXED_UNITS } from "../worldgen/worldgen.ts";

/** 传送门组件类型。 */
export const PORTAL_TYPE = "flow.portal";

/**
 * 缺省触发半径：**1.5 格**（定点 384）。
 *
 * 为什么不是"玩家半径那么大"（0.28 格）：门是给人走的，不是给人"精确踩点"的；
 * 太小的门在等距视角下几乎点不中自己的落脚格。
 */
export const PORTAL_DEFAULT_RADIUS = (FIXED_UNITS * 3) / 2;

/** `to` 没写（空串）—— 这扇门通向哪里，作者没说。 */
export const FLOW_PORTAL_NO_TARGET = "FLOW.PORTAL_NO_TARGET";
/** 半径不是正整数。 */
export const FLOW_PORTAL_BAD_RADIUS = "FLOW.PORTAL.BAD_RADIUS";
/** 两扇门同名 ⇒ "上一刻在哪扇门里"这件事就没有确定含义了。 */
export const FLOW_PORTAL_DUPLICATE = "FLOW.PORTAL_DUPLICATE";

export const PORTAL_SCHEMA: ComponentSchema = {
  type: PORTAL_TYPE,
  fields: {
    /** 目标场景名（工程里的槽位名）。空串 = 作者还没填，见 `FLOW_PORTAL_NO_TARGET`。 */
    to: FieldType.String,
    /** 触发半径（定点单位，> 0）。见文件头 ④。 */
    radius: FieldType.Int,
  },
  defaults: { to: "", radius: PORTAL_DEFAULT_RADIUS },
};

export class Portal extends Component {
  to = "";
  radius = PORTAL_DEFAULT_RADIUS;

  readonly schema: ComponentSchema = PORTAL_SCHEMA;
}

export function registerPortalComponent(registry: ComponentRegistry): void {
  if (!registry.has(PORTAL_TYPE)) registry.register(PORTAL_SCHEMA, () => new Portal());
}

/** 从场景里读出来的一扇门（纯数据，`PortalWatcher` 只吃它）。 */
export interface PortalSpec {
  /** 门在场景里的节点名。既做人话，也做"上一刻在哪扇门里"的身份。 */
  readonly name: string;
  /** 目标场景名。 */
  readonly to: string;
  /** 触发半径（定点）。 */
  readonly radius: number;
  /** 门心的世界坐标（定点）。 */
  readonly x: number;
  readonly z: number;
}

export interface PortalHit {
  readonly portal: PortalSpec;
  /** 玩家到门心的距离平方（定点整数）。"最近的门"靠它排序，也是诊断里唯一的数值。 */
  readonly distance2: number;
}

/**
 * 把场景里的 `flow.portal` 组件收集成规格表。
 *
 * 三条校验各自对应一种"作者写错了但引擎会照跑"：
 * - 空 `to` ⇒ 跳转时才报错的话，人得先走到门前才知道；
 * - 半径 ≤ 0 ⇒ 那扇门永远不会触发（`dx²+dz² ≤ 0` 只有正中一点成立），
 *   而画面上门还在、图标还在；
 * - 重名 ⇒ 边沿状态机记的是名字，"从 A 门走到另一个 A 门"会被判成没动过。
 *
 * 返回顺序按名字升序：不排序的话，`componentsOf` 的顺序就是挂载顺序，
 * 而"重叠时取最近的那一扇"在距离相同时要靠这个顺序兜底。
 */
export function collectPortals(scene: Scene): Result<readonly PortalSpec[], EngineError> {
  const specs: PortalSpec[] = [];
  for (const p of scene.componentsOf<Portal>(PORTAL_TYPE)) {
    // `componentsOf` 只返回已挂载的组件 ⇒ `node` 一定有值。
    // 这里用 `!` 而不是写一条"没有节点就跳过"的分支：那条分支永远进不去，
    // 而它会成为一条变异被"抓住"的假绿（批90 的教训：同一个错误码两个出口会遮变异）。
    const node = p.node!;
    if (p.to === "") {
      return err(
        engineError(FLOW_PORTAL_NO_TARGET, `节点「${node.name}」上的传送门没写目标场景（to 是空串）`),
      );
    }
    if (!Number.isInteger(p.radius) || p.radius <= 0) {
      return err(
        engineError(
          FLOW_PORTAL_BAD_RADIUS,
          `节点「${node.name}」的传送门半径是 ${String(p.radius)} —— 必须是正整数（定点单位，256 = 1 格）`,
        ),
      );
    }
    // ★ 世界坐标：门的触发范围跟着父节点走。父带缩放时 `worldPositionOf` 给的还是
    //   世界坐标（它按世界变换算），所以缩放过的大门触发范围也应当是"世界里的半径" ——
    //   按世界半径算，不做缩放换算（门的半径是关卡设计参数，不是子节点的局部量）。
    const w = scene.worldPositionOf(node.id);
    if (w === undefined) {
      return err(
        engineError(FLOW_PORTAL_NO_TARGET, `节点「${node.name}」不在场景里（取不到世界坐标）`),
      );
    }
    specs.push({
      name: node.name,
      to: p.to,
      radius: p.radius,
      x: Math.round(w.x * FIXED_UNITS),
      z: Math.round(w.y * FIXED_UNITS),
    });
  }
  specs.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (let i = 1; i < specs.length; i++) {
    if (specs[i]!.name === specs[i - 1]!.name) {
      return err(
        engineError(
          FLOW_PORTAL_DUPLICATE,
          `有两扇传送门都叫「${specs[i]!.name}」—— 名字用来记"上一刻在哪扇门里"，必须唯一`,
        ),
      );
    }
  }
  return ok(specs);
}

/** 覆盖某一点的所有门，按 (距离², 名字) 升序 —— 第 0 个就是"最近的那一扇"。 */
export function hitTestPortals(
  x: number,
  z: number,
  portals: readonly PortalSpec[],
): readonly PortalHit[] {
  const hits: PortalHit[] = [];
  for (const p of portals) {
    const dx = x - p.x;
    const dz = z - p.z;
    const d2 = dx * dx + dz * dz;
    if (d2 <= p.radius * p.radius) hits.push({ portal: p, distance2: d2 });
  }
  hits.sort((a, b) => {
    if (a.distance2 !== b.distance2) return a.distance2 - b.distance2;
    return a.portal.name < b.portal.name ? -1 : a.portal.name > b.portal.name ? 1 : 0;
  });
  return hits;
}

/**
 * "我现在在哪扇门里"的身份：**离我最近的那一扇**，没有门覆盖时是 `null`。
 *
 * ★ 为什么不是"覆盖我的门的集合"：那样在两扇**重叠**的门之间走动永远不会触发 ——
 *   从 a 走到 b 时集合一直是 `{a,b}`（没变），于是想去 b 的人怎么走都进不去，
 *   而画面上他明明站在 b 的门柱中间。玩家对"我在哪扇门里"的直觉是**最近那一扇**，
 *   不是覆盖集合；身份跟着这个直觉走，重叠门的语义才有定义。
 *   （重叠本身仍是关卡设计要避免的，但引擎不该因此给出一个走不通的语义。）
 */
function keyOf(hits: readonly PortalHit[]): string | null {
  return hits.length === 0 ? null : hits[0]!.portal.name;
}

/**
 * 边沿状态机：吃位置，只在"最近的那扇门换了、且新的一扇存在"时给出一扇门。
 *
 * ★★ 它是**有状态**的，而且这个状态不属于场景、不属于组件 —— 它属于"这一次行走"。
 *   所以它不实现成 `Component.onUpdate`：组件在 `loadScene` 时会被重建，
 *   而重建那一刻的"我以前在门里吗"恰好是**不该保留**的信息（见 `reseed`）。
 */
export class PortalWatcher {
  private key: string | null = null;

  /** 当前所在的门名（诊断/自检读它，不直接摸私有状态）。 */
  get insideKey(): string | null {
    return this.key;
  }

  /**
   * 重设"我现在站在哪儿" —— **跳转落地后必须调**（文件头 ②）。
   *
   * 语义：把"现在这扇门"记成"本来就该在这"，于是下一次 `enter` 不会因为
   * "刚刚莫名从外面进来了"而触发。
   */
  reseed(x: number, z: number, portals: readonly PortalSpec[]): void {
    this.key = keyOf(hitTestPortals(x, z, portals));
  }

  /**
   * 喂一个位置。返回"这一次真的跨进了一扇门"，否则 `null`。
   *
   * 三种情形**不是**跨越：集合没变（站着不动 / 在门里挪）；集合变成空（走出门）；
   * 从没门的地方走到没门的地方。
   */
  enter(x: number, z: number, portals: readonly PortalSpec[]): PortalHit | null {
    const hits = hitTestPortals(x, z, portals);
    const key = keyOf(hits);
    if (key === this.key) return null;
    this.key = key;
    if (hits.length === 0) return null;
    return hits[0]!;
  }

  /** 世界被换掉了（读档 / 停播回滚）：忘掉"我以前在哪儿"。 */
  reset(): void {
    this.key = null;
  }
}
