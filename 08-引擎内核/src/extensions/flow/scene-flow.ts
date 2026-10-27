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
 * ★★ 批93 补上的第七步：**离开的场景不重置**。
 *   在此之前，每次跳转都从 `source(to)` 重新解析作者文档 —— 于是"砍倒的树、杀掉的怪、
 *   丢在地上的东西"在离开后全部复原，而画面上完全看不出发生过什么（世界本来就是新的）。
 *   现在的规则是：**去过的地方记在 `visited` 里，再进去装的是那一份，不是文档**。
 *   文档只在"第一次去"时读一次，之后它只是"这个场景第一次长什么样"的记忆。
 *
 *   ★ 入册的是"我离开时的世界"，但**玩家要归位到入口**（`stampEntry`）：
 *     入口是"这一局的这一扇门通向哪里"的答案，由第一次进入时玩家站的坐标决定。
 *     不归位的话，回访会落在"上次离开时站的地方"—— 于是从 A 的门进来却出现在
 *     B 的角落里，而且离得越远越像作弊（试玩里走一次门就能绕过整张地图）。
 *
 *   ★ 这个改写把"试玩是沙盒"变成"试玩是**一次会话**"：world 会保留，但停播仍按
 *     `play-session.ts` 的会话快照整体回滚 —— 沙盒边界没变，变的只是**会话内**的连续性。
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
  sceneToJson,
  type SceneSnapshot,
} from "../../core/scene/scene-io.ts";
import { FIXED_UNITS } from "../worldgen/worldgen.ts";
import { PLAYER_TYPE } from "../worldgen/spawn.ts";
import { applyCarry, clearInventory, readCarry } from "./carry.ts";
import { decodeGameSave, encodeGameSave } from "./game-save.ts";

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
/** 存档里某一份场景文档解析不了（坏 JSON / 缺字段）。**世界未改动**。 */
export const FLOW_SAVE_BAD_SCENE = "FLOW.SAVE_BAD_SCENE";
/** 存档的当前场景里没有玩家 ⇒ 读进去没人可操控。**世界未改动**。 */
export const FLOW_SAVE_NO_SPAWN = "FLOW.SAVE_NO_SPAWN";
/** 读档装载失败。此时**已经尝试回滚**。 */
export const FLOW_SAVE_LOAD_FAILED = "FLOW.SAVE_LOAD_FAILED";

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
  /**
   * 装的是**手里那份快照**（这个场景本局去过了），不是作者文档。
   *
   * ★ 单独报出来不是为了好看：它是"离开不重置"唯一能从外面看见的证据。
   *   只看画面的话，"从文档重建"与"从快照重建"在第一次跳进去时完全一样。
   */
  readonly reused: boolean;
  readonly dropped: readonly string[];
  readonly clamped: readonly string[];
  /**
   * 落地坐标（定点）。宿主拿它去 `PortalWatcher.reseed()` ——
   * 落点正好在另一扇门里时，那不算"跨进来"（见 `portal.ts` 文件头 ②）。
   */
  readonly landing: { readonly x: number; readonly z: number } | null;
}

/** 读档的结果。 */
export interface RestoreReport {
  /** 存档说当前在哪一份（读档之后世界就是这一份）。 */
  readonly current: string;
  /** 存档里一共几份场景（含当前）。 */
  readonly scenes: number;
  readonly made: number;
  /** 装载时被跳过的组件/节点（未知类型等）。**不静默**。 */
  readonly skipped: readonly string[];
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

/** 玩家节点的**局部**坐标（`null` = 场景里没有玩家）。 */
function playerLocal(scene: Scene): PortalPoint | null {
  const id = findPlayerId(scene);
  if (id === null) return null;
  const n = scene.find(id);
  if (n === undefined) return null;
  return { x: n.localPosition.x, y: n.localPosition.y };
}

interface PortalPoint {
  readonly x: number;
  readonly y: number;
}

/**
 * 把快照里那个玩家挪回入口。
 *
 * ★ 为什么要挪：见文件头"第七步"。存的是"离开时的世界"，但**入口位置**不属于
 *   世界状态，它属于"这一关卡的门通向哪里"。两者的归属不同，所以一个存原样、
 *   一个必须覆盖。
 *
 * ★ 为什么改**快照**而不是改场景：改场景是在世界还活着的时候动玩家的坐标，
 *   画面会抖一下、而且"我离开时站的地方"被永久改掉了（下次入册就不是那个位置）。
 *   快照是纯数据，改写它没有任何副作用。
 *
 * ★ 只归位 **id 最小的那个玩家**（与 `findPlayerId` 同一口径）：一局里有多个玩家节点时，
 *   我们自己操控的是那一个；其余的是别人（或 NPC），它们在自己的场景里是什么位置就还是什么位置。
 */
function stampEntry(snap: SceneSnapshot, entry: PortalPoint | null): SceneSnapshot {
  if (entry === null) return snap;
  let target = -1;
  for (const n of snap.nodes) {
    if (!n.components.some((c) => c.type === PLAYER_TYPE)) continue;
    if (target === -1 || n.id < target) target = n.id;
  }
  if (target === -1) return snap;
  return {
    ...snap,
    nodes: snap.nodes.map((n) => (n.id === target ? { ...n, x: entry.x, y: entry.y } : n)),
  };
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
  /**
   * 本局去过的场景 → **离开时的世界**。
   *
   * `current` 永远不在这张表里（它就在 `scene` 里）。跳走时把自己这一份入册，
   * 进来时把自己那一份取走 —— 于是"在册"与"在世界里"恰好互补，
   * 不存在"同一份世界有两个副本，谁才是真的"这种问题。
   */
  private readonly visited = new Map<string, SceneSnapshot>();
  /**
   * 当前场景的入口（局部坐标）。**每次成功进入时重取** ——
   * 取的是玩家在这一刻站的地方，也就是"这一关卡的门通向哪里"。
   */
  private entry: PortalPoint | null;

  constructor(deps: FlowDeps, startScene: string) {
    this.deps = deps;
    this.current = startScene;
    // 构造时世界已经在 `startScene` 上（编辑器里就是文档本身），所以入口＝玩家现在的位置
    this.entry = playerLocal(deps.scene);
  }

  /** 现在装的是哪一份场景。 */
  get sceneName(): string {
    return this.current;
  }

  /** 本局去过几个场景（含当前这一份）。诊断/自检读它，不直接摸私有状态。 */
  get visitedCount(): number {
    return this.visited.size + 1;
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
        reused: false,
        dropped: [],
        clamped: [],
        landing: null,
      });
    }

    // ② 目标快照：**本局去过的就用手里的那一份**，没去过的才读文档
    const memo = this.visited.get(to);
    let snap: SceneSnapshot;
    if (memo !== undefined) {
      snap = memo;
    } else {
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
      snap = parsed.value;
    }

    // ③ 落点存在性（快照那条路也要查：读档读进来的档可能是别的引擎版本写的）
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
    // 离开的这一场的入口：**装载前**取，之后 `this.entry` 就换成新的那一份了
    const leavingEntry = this.entry;

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
    if (carry !== null && memo !== undefined) {
      // ★ 见 `carry.ts` 的 `clearInventory`：回访时目标身上那份背包是"上一次的我"，
      //   已经装进 `carry` 里了 —— 不清掉就是同一件东西算两遍（12 根变 24 根）。
      //   首次进入（`memo === undefined`）不清：那可能是作者给这一关配的初始装备。
      //
      // ★★ 必须在 `applyCarry` **之前**：反过来的话，刚装进去的那些会被一起删掉，
      //    症状是"回访之后背包空了"—— 而且 `applied` 里明明写着装过。
      clearInventory(scene, dstPlayer);
    }
    const applied = carry === null ? null : applyCarry(scene, dstPlayer, carry);
    const w = scene.worldPositionOf(dstPlayer);
    // ⑦ 记账（**只在装载成功之后**：装失败时要回滚到一个干净的世界，
    //    提前入册会留下"这一场已经被我改过"的假记忆）
    this.visited.set(from, stampEntry(before, leavingEntry));
    // 刚从册子里取出来的那一份现在就在世界里了 —— 留着就是同一份世界的两个副本
    this.visited.delete(to);
    this.current = to;
    this.entry = playerLocal(scene);
    return ok({
      kind: "jumped",
      from,
      to,
      made: loaded.value.made,
      skipped: loaded.value.skipped,
      carried: applied !== null && applied.applied.length > 0,
      reused: memo !== undefined,
      dropped: applied === null ? [] : applied.dropped,
      clamped: applied === null ? [] : applied.clamped,
      landing:
        w === undefined ? null : { x: Math.round(w.x * FIXED_UNITS), z: Math.round(w.y * FIXED_UNITS) },
    });
  }

  /**
   * 把这一局编成存档文本（当前场景 + 本局去过的每一份）。
   *
   * ★ 当前场景这一份是**现拍的**（`saveScene`），不是入册时那一份 ——
   *   人在这一关里走到的位置、砍掉的树，只有现在这一刻的快照才带着。
   */
  saveGame(): string {
    const docs = new Map<string, string>();
    for (const [name, snap] of this.visited) docs.set(name, sceneToJson(snap));
    docs.set(this.current, sceneToJson(saveScene(this.deps.scene)));
    return encodeGameSave(this.current, docs);
  }

  /**
   * 读一份存档：世界换成存档里的当前场景，去过的地方一并恢复。
   *
   * 顺序与 `jump` 同一套纪律——**所有判定都在装载之前**：
   *   ① 结构（`decodeGameSave`）→ ② 每份文档都能解析 → ③ 当前场景有玩家 → ④ 装载。
   * 前三条失败时世界一个字节都没动；只有 ④ 失败要回滚。
   *
   * ★ 不需要 `applyCarry`：存档里的玩家节点**自带**血/饱食/背包（它们本来就是节点上的
   *   组件）。跨场景搬运才需要 `carry`，读档是整体换世界，多搬一遍反而会把存档里的
   *   状态覆盖成"读档前那个人的"。
   */
  loadGame(text: string): Result<RestoreReport, EngineError> {
    const decoded = decodeGameSave(text);
    if (!decoded.ok) return err(decoded.error);
    const save = decoded.value;

    // ② 每一份都先解析（含当前场景）。这一步用掉的是字符串，世界还没动。
    const snaps = new Map<string, SceneSnapshot>();
    for (const s of save.scenes) {
      const p = sceneFromJson(s.doc);
      if (!p.ok) {
        return err(
          engineError(
            FLOW_SAVE_BAD_SCENE,
            `存档里场景「${s.name}」的文档读不了：${p.error.message}`,
            { cause: p.error.code },
          ),
        );
      }
      snaps.set(s.name, p.value);
    }

    // ③ 当前场景得有玩家（`decodeGameSave` 只保证这个名字在列表里，不保证内容）
    const cur = snaps.get(save.current);
    if (cur === undefined) {
      // ② 刚把每一份都放进 `snaps`，走不到这里；用 throw 顶住而不是再写一个出口
      throw new Error(`存档当前场景「${save.current}」不在解析结果里 —— 与结构校验矛盾`);
    }
    if (!snapshotHasPlayer(cur)) {
      return err(
        engineError(
          FLOW_SAVE_NO_SPAWN,
          `存档的当前场景「${save.current}」里没有玩家节点 —— 读进去没人可操控`,
        ),
      );
    }

    // ④ 装载（失败要回滚，从这里开始世界已经不可信）
    const before = saveScene(this.deps.scene);
    const loaded = loadScene(this.deps.scene, cur, this.deps.registry);
    if (!loaded.ok) {
      const back = loadScene(this.deps.scene, before, this.deps.registry);
      const tail = back.ok ? "已回滚到读档前的场景" : `回滚也失败了：${back.error.message} —— 工作区不可信`;
      return err(
        engineError(FLOW_SAVE_LOAD_FAILED, `装载存档的当前场景失败：${loaded.error.message}；${tail}`, {
          cause: loaded.error.code,
        }),
      );
    }

    // ⑤ 一次性替换记账（成功之后才动，失败时账本还是原来那一份）
    this.visited.clear();
    for (const [name, snap] of snaps) {
      if (name !== save.current) this.visited.set(name, snap);
    }
    this.current = save.current;
    this.entry = playerLocal(this.deps.scene);
    return ok({
      current: save.current,
      scenes: snaps.size,
      made: loaded.value.made,
      skipped: loaded.value.skipped,
    });
  }
}
