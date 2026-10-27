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
 * ★ 不做的：**「同一扇门单向」**。这一条看起来像缺功能，其实缺的是**数据**：
 *   引擎里的节点只有位置与缩放，没有"朝向/法线"。想判"他是不是朝着门里走"，
 *   只能拿前后两次位置去猜方向 —— 而猜错的表现是"这扇门有时能过有时不能过"，
 *   比没有方向性更坏（玩家会以为是自己站位不对）。
 *   真要的"只去不回"今天就有两种做法，都不需要引擎改：
 *     · 目标场景里**不放回程门**（关卡结构就是方向性）；
 *     · 那扇回程门设 `requires`（钥匙被消耗掉 ⇒ 回去的路自然断了）。
 *   剩下的过场（渐隐）是表现层的事，也不是流程层的。
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
/** 写了要钥匙，但数量不是正整数 ⇒ 这扇门永远打不开（或语义不明）。 */
export const FLOW_PORTAL_BAD_REQUIRES = "FLOW.PORTAL.BAD_REQUIRES";
/** 写了「要先去过的场景」，但那个名字是空白 ⇒ 永远匹配不上任何场景，门永远锁着。 */
export const FLOW_PORTAL_BAD_SCENE = "FLOW.PORTAL.BAD_SCENE";

export const PORTAL_SCHEMA: ComponentSchema = {
  type: PORTAL_TYPE,
  fields: {
    /** 目标场景名（工程里的槽位名）。空串 = 作者还没填，见 `FLOW_PORTAL_NO_TARGET`。 */
    to: FieldType.String,
    /** 触发半径（定点单位，> 0）。见文件头 ④。 */
    radius: FieldType.Int,
    /**
     * 这扇门现在通不通（`open=false` = 作者还没开通这条路）。
     *
     * ★★ 名字**不能叫 `enabled`**：基类 `Component` 已经有一个同名成员
     *   （它管「这个组件要不要跑 onUpdate / onEnable」）。字段同名会把
     *   「门关着」变成「组件停用」—— 停用的组件连生命周期都不一样了，
     *   症状是「我把门设成关着，结果整扇门都不工作了」。
     *   TypeScript 会报（要求 `override`），但报错位置在类声明上，
     *   看起来像语法问题 —— 记在这里，免得下次又想用 `enabled`。
     *
     * ★ 与 `requires` 是两件事，别合并：
     *   `open=false` = **这条路还没开通**（作者还在做，玩家走过去什么都不该发生，
     *   也不该弹一句"锁着"—— 那会让人去满地找钥匙）；
     *   `requires` = **要钥匙**（走过去要报"缺什么"，因为钥匙确实存在）。
     */
    open: FieldType.Bool,
    /** 需要的物品 kind（空串 = 不需要钥匙）。 */
    requires: FieldType.String,
    /** 需要几个（`requires` 非空时必须是正整数）。 */
    requiresCount: FieldType.Int,
    /**
     * 过门时**扣掉**钥匙。
     *
     * ★ 缺省 `false`：钥匙是"资格"还是"消耗品"，只有作者知道。
     *   同一扇门扣不扣，决定"能不能反复来回"，而这是关卡设计，不是引擎该替他定的。
     */
    consume: FieldType.Bool,
    /**
     * 「先去过这个场景」才通（空串 = 不设剧情门槛）。
     *
     * ★ 与 `requires` 是**两件事**，别合并（批103）：
     *   `requires` = 要钥匙，缺了要报「缺哪把、还差几个」—— 因为钥匙确实存在，玩家能去弄；
     *   这里 = **剧情没到**，一扇根本没该出现的门不该被提示"缺某把钥匙"，
     *   否则玩家会满世界找一把不存在的钥匙。
     *
     * ★ 门槛取自**本局进度**（`SceneFlow.visited`），不是背包：
     *   「去过第 2 关」与「身上有 3 个木头」是两种不同的进度，前者跟着存档走、后者跟着携带走。
     *   也正因为门槛是 `visited`，它天然进存档 —— 不需要给存档格式加字段。
     *
     * ★ 与目标场景同名是**允许**的：那是"你从别处到过 B，这里才给你一条回 B 的近路"。
     *   而与**当前这一场**同名则是死锁（`visited` 永远不含当前场景），
     *   在 `SceneFlow.jump` 里报 `FLOW.STORY_SELF`，不是永远锁着不说原因。
     */
    requiresScene: FieldType.String,
  },
  defaults: {
    to: "",
    radius: PORTAL_DEFAULT_RADIUS,
    open: true,
    requires: "",
    requiresCount: 1,
    consume: false,
    requiresScene: "",
  },
};

export class Portal extends Component {
  to = "";
  radius = PORTAL_DEFAULT_RADIUS;
  open = true;
  requires = "";
  requiresCount = 1;
  consume = false;
  requiresScene = "";

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
  /** 这扇门现在通不通（`false` 的门不会被 `hitTestPortals` 返回）。 */
  readonly open: boolean;
  /** 需要的物品 kind（空串 = 不需要钥匙）。 */
  readonly requires: string;
  /** 需要几个。 */
  readonly requiresCount: number;
  /** 过门时扣不扣钥匙。 */
  readonly consume: boolean;
  /** 「先去过这个场景」才通（空串 = 不设剧情门槛）。 */
  readonly requiresScene: string;
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
    // ★ 写了钥匙但数量不是正整数：这扇门要么永远打不开（0 / 负数），
    //   要么"要 1.5 个木头"（小数，`takeItem` 会按整数截断，作者看不出为什么多了半个）。
    //   与半径同一条纪律：**作者写错了就当场说**，别等玩家走到门前才发现。
    if (p.requires !== "" && (!Number.isInteger(p.requiresCount) || p.requiresCount <= 0)) {
      return err(
        engineError(
          FLOW_PORTAL_BAD_REQUIRES,
          `节点「${node.name}」的传送门要「${p.requires}」，但数量是 ${String(p.requiresCount)}` +
            ` —— 必须是正整数（这扇门现在要么永远打不开，要么语义不明）`,
        ),
      );
    }
    // ★ 空白名字的剧情门槛：`" "` 永远匹配不上任何场景名 ⇒ 这扇门永远锁着，
    //   而画面上它与一扇正常的门一模一样。与半径、钥匙同一条纪律：**作者写错了就当场说**。
    if (p.requiresScene !== "" && p.requiresScene.trim() === "") {
      return err(
        engineError(
          FLOW_PORTAL_BAD_SCENE,
          `节点「${node.name}」的传送门写了一个空白的「要先去过的场景」（${JSON.stringify(p.requiresScene)}）` +
            ` —— 它永远匹配不上任何场景名，这扇门会永远锁着`,
        ),
      );
    }
    specs.push({
      name: node.name,
      to: p.to,
      radius: p.radius,
      open: p.open,
      requires: p.requires,
      requiresCount: p.requiresCount,
      consume: p.consume,
      requiresScene: p.requiresScene,
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

/**
 * 覆盖某一点的所有门，按 (距离², 名字) 升序 —— 第 0 个就是"最近的那一扇"。
 *
 * ★ **关着的门（`open=false`）不在这里出现**，而不是在这里出现再由调用方筛：
 *   这个函数同时被 `enter`（要不要触发）和 `reseed`（落地时把哪儿记成"本来就该在这"）
 *   使用。两处各自筛一遍的话，"关着的门算不算一个身份"会有两个答案，而其中一个
 *   永远没人测 —— 那正是批90 记下的"同一件事两个出口会遮掉一条变异"。
 */
export function hitTestPortals(
  x: number,
  z: number,
  portals: readonly PortalSpec[],
): readonly PortalHit[] {
  const hits: PortalHit[] = [];
  for (const p of portals) {
    if (!p.open) continue;
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
