/**
 * L4 · 关卡流程：跳转（换一份场景，人还是那个人）
 *
 * 这一层把三样东西接起来：**目标场景的文档**、**当前的世界**、**玩家身上的状态**。
 * 顺序一旦写错，症状全都是"跳成功了，但少了点什么"，而日志里干干净净。
 *
 * ★★ 顺序是这一层唯一的实质内容，钉死成六步：
 *
 *   ① 目标是当前场景 ⇒ `noop`，一个字节都不动（与 `editor/project.ts` 同一条规则：
 *      `loadScene` 会换掉所有 `Node` 实例，而"点了一下当前这一份"不该有任何代价）。
 *   ② **先取文本、先解析**。`loadScene` 的第一件事是 `scene.clear()` ——
 *      拿一个坏文档直接 load 就是"世界没了、新世界也没装上"。所以解析必须在装载之前，
 *      失败时世界一个字节都没动（与 `editor/session.ts` 的不变量同源）。
 *   ③ **落点存在性也在装载之前判**。目标文档里没有玩家节点 ⇒ 跳过去就是一片空地，
 *      人站在虚空里、按 WASD 谁也不动（`spawnPlayer` 才有控制器）。同样从快照里
 *      静态检查，不动世界。
 *   ④ 导出携带（血/饱食/背包）—— 必须在 `loadScene` **之前**，之后源节点就没了。
 *   ⑤ `loadScene`。**这一步之后世界已经变了**，所以从这里开始任何失败都必须回滚。
 *   ⑥ 落点与回灌：目标场景的玩家节点**自己的坐标就是落点**（作者在编辑器里摆的），
 *      然后 `applyCarry` 把状态写进去。
 *
 * ★ 只有第 ⑤ 步失败需要回滚。①②③④ 都在装载之前判定，失败时世界原样 ——
 *   这不是省事，而是**回滚本身是危险动作**：`loadScene` 回滚失败的话工作区不可信，
 *   能不做就不做。所以"能让错误发生在装载之前"的检查，一律提前。
 *
 * ★ 本层不认识 DOM、不认识 GameApp：只拿 `scene / registry / source`。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { ComponentRegistry } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import {
  loadScene,
  saveScene,
  sceneFromJson,
  type SceneSnapshot,
} from "../../core/scene/scene-io.ts";
import { FIXED_UNITS } from "../worldgen/worldgen.ts";
import { PLAYER_TYPE } from "../worldgen/spawn.ts";
import { applyCarry, readCarry } from "./carry.ts";

/**
 * 场景名 → 文档文本。找不到返回 `null`（不抛）。
 *
 * ★ 用函数而不是 `Map`：宿主那边"场景从哪儿来"是三种不同的东西 ——
 *   编辑器里是工程槽位、发布后是包里的场景清单、判据里是临时构造的文本。
 *   抽成一个函数，三者都不用把自己的数据结构摊开给流程层看。
 */
export type SceneSource = (name: string) => string | null;

/** `source` 里没有这个名字的场景。 */
export const FLOW_NO_SUCH_SCENE = "FLOW.NO_SUCH_SCENE";
/** 目标文档解析失败（坏 JSON / 版本太新 / 缺字段）。**世界未改动**。 */
export const FLOW_BAD_TARGET = "FLOW.BAD_TARGET";
/** 目标文档里没有玩家节点 ⇒ 跳过去没人可操控。**世界未改动**。 */
export const FLOW_NO_SPAWN = "FLOW.NO_SPAWN";
/** 装载失败（组件工厂抛、节点建不出来…）。此时**已经尝试回滚**。 */
export const FLOW_LOAD_FAILED = "FLOW.LOAD_FAILED";

export interface FlowDeps {
  readonly scene: Scene;
  readonly registry: ComponentRegistry;
  readonly source: SceneSource;
}

export interface JumpReport {
  /** `noop` = 目标就是当前场景（世界与实例都没动）。 */
  readonly kind: "noop" | "jumped";
  readonly from: string;
  readonly to: string;
  /** 目标文档重建出的节点数（noop 时是 0）。 */
  readonly made: number;
  /** 目标场景的加载问题（未知组件等）。**不静默**。 */
  readonly skipped: readonly string[];
  /** 真的把状态带过去了（源场景有玩家且回灌成功）。 */
  readonly carried: boolean;
  readonly dropped: readonly string[];
  readonly clamped: readonly string[];
  /**
   * 落地坐标（定点）。宿主拿它去 `PortalWatcher.reseed()` ——
   * 落点正好在另一扇门里时，那不算"跨进来"（见 `portal.ts` 文件头 ②）。
   */
  readonly landing: { readonly x: number; readonly z: number } | null;
}

/** 场景里代表玩家的那个节点（多个只取 id 最小的 —— 不靠遍历顺序碰运气）。 */
export function findPlayerId(scene: Scene): number | null {
  let best: number | null = null;
  for (const c of scene.componentsOf(PLAYER_TYPE)) {
    const id = c.node?.id;
    if (id === undefined) continue;
    if (best === null || id < best) best = id;
  }
  return best;
}

/** 文档里有没有玩家节点（静态检查，不装载）。 */
function snapshotHasPlayer(snap: SceneSnapshot): boolean {
  for (const n of snap.nodes) {
    for (const c of n.components) if (c.type === PLAYER_TYPE) return true;
  }
  return false;
}

/**
 * 一个工程的"当前场景 + 跳转能力"。
 *
 * ★ `current` 是**流程层自己的记忆**，不是从场景里读的：`Scene.name` 在所有宿主里
 *   都叫 `"main"`（`GameApp` 构造时写死），它表达的是"这台世界"，不是"哪一份文档"。
 *   拿它当场景身份的话，跳转之后 `current` 永远是 `"main"`，于是"跳到 main" 会被
 *   判成 noop —— 而实际上要跳的是另一份文档。
 */
export class SceneFlow {
  private current: string;
  private readonly deps: FlowDeps;

  constructor(deps: FlowDeps, startScene: string) {
    this.deps = deps;
    this.current = startScene;
  }

  /** 现在装的是哪一份场景。 */
  get sceneName(): string {
    return this.current;
  }

  /** 当前场景里的玩家节点 id（没有就是 `null`）。 */
  playerId(): number | null {
    return findPlayerId(this.deps.scene);
  }

  /**
   * 跳到另一份场景。
   *
   * 失败语义分两类，调用方必须能分辨：
   * - `NO_SUCH_SCENE` / `BAD_TARGET` / `NO_SPAWN`：**世界没动**，`current` 没动，
   *   可以原样重试或让玩家继续玩；
   * - `LOAD_FAILED`：世界**已经变过**，回滚是否成功写在消息里。这类之后不该继续跑。
   */
  jump(to: string): Result<JumpReport, EngineError> {
    const { scene, registry, source } = this.deps;
    if (to === this.current) {
      // ① 见文件头：noop 不是优化，是"不许换实例"
      return ok({
        kind: "noop",
        from: this.current,
        to,
        made: 0,
        skipped: [],
        carried: false,
        dropped: [],
        clamped: [],
        landing: null,
      });
    }

    // ② 取文本 + 解析，都在动世界之前
    const text = source(to);
    if (text === null) {
      return err(engineError(FLOW_NO_SUCH_SCENE, `工程里没有名为「${to}」的场景`));
    }
    const parsed = sceneFromJson(text);
    if (!parsed.ok) {
      return err(
        engineError(FLOW_BAD_TARGET, `场景「${to}」的文档读不了：${parsed.error.message}`, {
          cause: parsed.error.code,
        }),
      );
    }
    const snap = parsed.value;

    // ③ 落点存在性
    if (!snapshotHasPlayer(snap)) {
      return err(
        engineError(
          FLOW_NO_SPAWN,
          `场景「${to}」里没有玩家节点（${PLAYER_TYPE}）—— 跳过去没人可操控；` +
            `先在那个场景里放一个玩家（它的位置就是入口）`,
        ),
      );
    }

    // ④ 导出携带（必须在 loadScene 之前：之后源节点就没了）
    const from = this.current;
    const srcPlayer = findPlayerId(scene);
    const carry = srcPlayer === null ? null : readCarry(scene, srcPlayer);
    const before = saveScene(scene);

    // ⑤ 装载
    const loaded = loadScene(scene, snap, registry);
    if (!loaded.ok) {
      // 世界已经被 clear 过 ⇒ 必须回滚。回滚失败要如实说"工作区不可信"。
      const back = loadScene(scene, before, registry);
      const tail = back.ok ? "已回滚到跳转前的场景" : `回滚也失败了：${back.error.message} —— 工作区不可信`;
      return err(
        engineError(FLOW_LOAD_FAILED, `装载场景「${to}」失败：${loaded.error.message}；${tail}`, {
          cause: loaded.error.code,
        }),
      );
    }

    // ⑥ 落点与回灌
    const dstPlayer = findPlayerId(scene);
    if (dstPlayer === null) {
      // ③ 已经静态查过一次，走不到这里。用 `!` 顶住而不是再写一个错误分支：
      //    同一件事有两个出口时，其中一条变异会被另一条遮住（批90 的教训）。
      throw new Error(`场景「${to}」装载后找不到玩家节点 —— 与装载前的静态检查矛盾`);
    }
    const applied = carry === null ? null : applyCarry(scene, dstPlayer, carry);
    const w = scene.worldPositionOf(dstPlayer);
    this.current = to;
    return ok({
      kind: "jumped",
      from,
      to,
      made: loaded.value.made,
      skipped: loaded.value.skipped,
      carried: applied !== null && applied.applied.length > 0,
      dropped: applied === null ? [] : applied.dropped,
      clamped: applied === null ? [] : applied.clamped,
      landing:
        w === undefined ? null : { x: Math.round(w.x * FIXED_UNITS), z: Math.round(w.y * FIXED_UNITS) },
    });
  }
}
