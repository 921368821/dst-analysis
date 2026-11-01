/**
 * L4 · 视觉插值：把「别人」的位移摊平到几帧里
 *
 * ★★ 要解决的是哪一个具体现象
 *
 *   客户端的世界**只在快照到达时变**（默认每 5 拍一份）。不插值时，别人的角色
 *   每秒动 6.7 次、每次挪 0.6 格 —— 画面上是「一格一格地闪」，而所有位置判据
 *   都是绿的（每份快照的坐标都分毫不差）。预测解决不了这一半：别人的位置只有
 *   主机知道，客户端能做的只是**把已知的两点之间画匀**。
 *
 * ★★ 插值期间显示谁的位置（批168 的决定，改这里之前先读这一节）
 *
 *   `docs/ONLINE-READINESS-PLAN.md` §17.5 把这条挂着，是因为它是个**表现层决定**，
 *   不是实现细节。定下来的答案是「本地预测 + 他人插值」：
 *
 *   · **本地玩家：一毫秒也不插值。** 位置就是预测/重放算出来的那个数。理由：
 *     预测的全部价值在于「输入与画面之间没有延迟」，插值会把这份延迟成建制地
 *     加回去（至少一帧），还会把回正时的抖动抹成「人自己在滑」—— 而抖动的大小
 *     是玩家判断「主机跟没跟上我」的唯一线索。
 *   · **其他实体：从「上一帧画在哪」匀速走到「这一份的权威坐标」。** 别的玩家、
 *     AI、一切归权威的东西都算。插值期间画出来的点**既不是主机的也不是上一份
 *     的**，它是连接两点的直线上的一点 —— 这句写在这里，下一个读的人不必再推。
 *
 * ★★ 为什么不改节点坐标，只改「画在哪」
 *
 *   节点上的坐标是**预测与重放的基准**（`predict.ts` 文件头：快照落地后从主机
 *   坐标把剩下的步重放一遍，覆盖而不是累加）。往里面塞插值中间值，重放就会以
 *   中间值为基准，误差一路累积；更糟的是「重放从哪开始」会取决于渲染跑了多少帧
 *   —— 帧率在判据里可控、在玩家机器上不可控。所以插值只活在渲染这一层：
 *   节点上的数是权威，画出来的是平滑。
 *
 * ★★ 重新定基：新一段的起点是「现在画到哪」，不是「上一份权威在哪」
 *
 *   两份快照之间，若上一段插值已经走完，两者是同一个点；**没走完时**从上一份的
 *   权威坐标重新开始，画面会往回跳（跳到一段刚走过的路上）。所以 `capture` 记的是
 *   `at()` 的**当前值**，而不是 `node.worldPosition`。
 *
 *   这是整条链上唯一「错了也几乎看不出来」的地方：只有在卡顿（帧率低于插值时长）
 *   时才明显，而那时人只会说「有点卡」。
 *
 * ★★ 超过阈值就直接跳
 *
 *   0.6 格是「走了一段」，8 格是「被传送了 / 死了重生 / 主机把你的位置改回来了」。
 *   后者也插值的话，画面是「人从地图这头飘到那头」，比直接跳更糟。阈值是世界单位
 *   （1 格 = 1），缺省 2.0 —— 一个广播周期最多走 0.6~0.75 格，留了 3 倍余量；而
 *   一次真实的传送至少是好几格。
 *
 * ★ 只给客户端建（`session` 里 `role === "client"`）：主机的世界就是权威，每拍都
 *   在更新，「两份快照之间的空档」在那边根本不存在。
 *
 * ★ 坐标系：`node.worldPosition` 的 `y` 就是世界的 `z`（2.5D 里 Node 只有二维
 *   局部坐标）。这里的 `y` 与它同口径，直接喂给 `spriteToRenderItem` 的 `z` 位。
 */

import { planeLen } from "../../foundation/math/scalar.ts";
import type { NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { NET_IDENTITY_TYPE, NetIdentity, type PlayerId } from "./identity.ts";

/** 平面上的一个点。`y` = 世界的 `z`（与 `node.worldPosition` 同口径）。 */
export interface InterpPoint {
  readonly x: number;
  readonly y: number;
}

/** 没给时长时用这个（≈ 半个 30Hz 广播周期：够平滑，又不至于"慢半拍"太明显）。 */
export const DEFAULT_INTERP_MS = 120;

/** 缺省阈值（世界单位）。理由见文件头「超过阈值就直接跳」。 */
export const DEFAULT_SNAP_DISTANCE = 2.0;

export interface InterpStats {
  /** 此刻正在插值中的实体数（世界稳定后必须回 0，否则是轨道没清）。 */
  readonly active: number;
  /** 开始过多少段过渡（含被下一份快照**中途重新定基**的）。 */
  readonly started: number;
  /** 因为位移超过阈值而直接跳的次数。 */
  readonly snapped: number;
  /** 走完的过渡段数（与 `started` 的差 = 还在路上的）。 */
  readonly settled: number;
  /** 被插值过的最大位移（世界单位）。诊断「阈值是不是设错了」。 */
  readonly maxDistance: number;
}

export interface InterpOptions {
  /** 位移超过多少（世界单位）就直接跳。缺省 `DEFAULT_SNAP_DISTANCE`。 */
  readonly snapDistance?: number;
}

/** 一段过渡：`from`（上一帧画在哪）→ `to`（这一份的权威坐标）。 */
interface Track {
  readonly fromX: number;
  readonly fromY: number;
  readonly toX: number;
  readonly toY: number;
  elapsedMs: number;
  readonly durationMs: number;
}

export interface Interpolator {
  /**
   * **装载之前**：记下「玩家现在看到」的坐标（含正在插值中的中间值）。
   *
   * ★ 必须在 `loadScene` 之前调：装载是整场替换，装载之后上一帧的位置就不存在了。
   *   与 `predict.reconcile` 的顺序（必须在装载**之后**）正好相反，这两个「之前/之后」
   *   都只有唯一一个正确位置，写反了不会报错，只会静默失效。
   *
   * ★ 开头先清空：装载**失败**时不会有人来收尾（`commit` 直接返回 `false`），
   *   而下一次成功装载前一定还会有一次 `capture` —— 于是「失败的那份捕获会不会
   *   被下一次用上」这个问题，答案只能是"不会，它被覆盖了"。这也是这里不需要
   *   一个单独的 `abort()` 的全部理由（多一个没人调的方法就是多一条死路）。
   */
  capture(scene: Scene, local: PlayerId | null): void;
  /**
   * **装载之后**：为每个非本地实体重新定基。
   *
   * `durationMs` = 这一段过渡摊几毫秒（调用方按自己的广播周期给）。
   * 返回这一段真正开始的段数（新出现的实体没有"上一帧"，不插值）。
   */
  rebase(scene: Scene, local: PlayerId | null, durationMs?: number): number;
  /**
   * 每帧一次：推进插值时钟。
   *
   * ★ 非有限值与 ≤0 一律忽略：`NaN` 会让插值系数变成 `NaN`，那一刻整只精灵被画到
   *   `(NaN, NaN)` 上 —— 表现是「某些角色凭空消失」，而所有计数都是对的。
   */
  beginFrame(dtMs: number): void;
  /**
   * 这个节点这一帧该画在哪。`null` = 不插值（用节点真实坐标）。
   *
   * ★ 返回的是**新对象**（每次调用一次分配）。热路径上多一次小对象分配，与
   *   `render-module` 每帧给每个精灵建一个 `RenderItem` 是同一量级，不值得为它
   *   改成"复用暂存对象"那种会让人把返回值存下来的接口。
   */
  at(nodeId: NodeId): InterpPoint | null;
  stats(): InterpStats;
}

/**
 * 这个实体参不参与插值？——**本地玩家不参与**（本地走预测，理由见文件头）。
 *
 * ★★ 为什么抽成函数，而不是在 `capture` 与 `rebase` 里各写一遍 `if`
 *
 *   两个调用点写同一条判断的后果不是"重复"，而是**变异只打得到一处**：
 *   单独改掉任意一处，另一处仍然会把它挡住 —— 变异报告"被抓住"，
 *   而这条规则的第二处等于从来没被覆盖过（批131 的 M821、批168 的 M1108 都栽在这）。
 *   收成一个函数之后，变异靶子打在**函数体**上，两个调用点一起变。
 *
 * ★ `local === null`（还没握手）时全场都插值：那时也不预测（`sendIntent` 需要座位），
 *   两者对"我是谁"的答案一致。
 */
function interpolable(owner: PlayerId, local: PlayerId | null): boolean {
  return local === null || owner !== local;
}

class InterpolatorImpl implements Interpolator {
  private readonly snapDistance: number;
  /** 正在走的过渡，按节点 id。 */
  private readonly tracks = new Map<NodeId, Track>();
  /** `capture` 与 `rebase` 之间的暂存：装载前的坐标。 */
  private readonly held = new Map<NodeId, InterpPoint>();

  private started = 0;
  private snapped = 0;
  private settled = 0;
  private maxDistance = 0;

  constructor(opts: InterpOptions) {
    const d = opts.snapDistance ?? DEFAULT_SNAP_DISTANCE;
    if (!Number.isFinite(d) || d <= 0) {
      throw new RangeError(`snapDistance 必须是 >0 的有限数，收到 ${String(d)}`);
    }
    this.snapDistance = d;
  }

  capture(scene: Scene, local: PlayerId | null): void {
    this.held.clear();
    for (const c of scene.componentsOf<NetIdentity>(NET_IDENTITY_TYPE)) {
      const node = c.node;
      if (node === null) continue;
      // ★ 本地玩家整段跳过（不是"插值时长 0"）：本地连轨道都不该有，否则
      //   `active` 会因为"我自己"永远非 0，而那个计数是唯一能发现轨道泄漏的量。
      if (!interpolable(c.owner, local)) continue;
      // ★ 起点取"现在画到哪"，不是"节点在哪"（见文件头「重新定基」）。
      const cur = this.at(node.id);
      const p = node.worldPosition;
      this.held.set(node.id, cur ?? { x: p.x, y: p.y });
    }
  }

  rebase(scene: Scene, local: PlayerId | null, durationMs: number = DEFAULT_INTERP_MS): number {
    // ★ 非法时长回落到缺省，不抛：时长是**表现参数**，它错了的代价应该是"不够平滑"，
    //   而不是"整个客户端装不上世界"。
    const dur = Number.isFinite(durationMs) && durationMs > 0 ? durationMs : DEFAULT_INTERP_MS;
    let began = 0;
    for (const c of scene.componentsOf<NetIdentity>(NET_IDENTITY_TYPE)) {
      const node = c.node;
      if (node === null) continue;
      if (!interpolable(c.owner, local)) {
        // ★ 归属刚变到我头上（主机交接 / 重连补归属）时，上一段是「那时它还归别人」
        //   的过渡，必须立刻作废 —— 否则我的角色会被别人的插值带着走，而这条规矩是
        //   本地**一毫秒也不插**。这类交接在判据里专门有一条（改这个 `delete` 会被抓）。
        this.tracks.delete(node.id);
        continue;
      }
      const from = this.held.get(node.id);
      // 新出现的实体（刚进视野 / 刚被造出来）：没有"上一帧"，直接到位。
      // ★ 不能从 (0,0) 开始插 —— 那是"所有新角色从地图原点飞过来"。
      if (from === undefined) {
        this.tracks.delete(node.id);
        continue;
      }
      const p = node.worldPosition;
      const d = planeLen(p.x - from.x, p.y - from.y);
      if (d > this.snapDistance) {
        this.tracks.delete(node.id);
        this.snapped++;
        continue;
      }
      if (d <= 0) {
        this.tracks.delete(node.id);
        continue;
      }
      if (d > this.maxDistance) this.maxDistance = d;
      this.tracks.set(node.id, {
        fromX: from.x,
        fromY: from.y,
        toX: p.x,
        toY: p.y,
        elapsedMs: 0,
        durationMs: dur,
      });
      this.started++;
      began++;
    }
    this.held.clear();
    // ★ 世界是整场替换：快照里已经没有的节点，轨道必须一起清掉。不清的后果是
    //   `active` 永远不归零（那个计数就是为这条泄漏准备的），而且 id 若被复用，
    //   新节点会凭空从"上一条命的位置"插值过来。
    for (const id of [...this.tracks.keys()]) {
      if (scene.find(id) === undefined) this.tracks.delete(id);
    }
    return began;
  }

  beginFrame(dtMs: number): void {
    if (!Number.isFinite(dtMs) || dtMs <= 0) return;
    for (const [id, t] of this.tracks) {
      t.elapsedMs += dtMs;
      // ★ `>=` 不是 `>`：恰好走满那一帧就该落地。用 `>` 时最后那段会多留一帧，
      //   而那一帧的 k 会 >1（插值过冲，画到目标之外）。
      if (t.elapsedMs >= t.durationMs) {
        this.tracks.delete(id);
        this.settled++;
      }
    }
  }

  at(nodeId: NodeId): InterpPoint | null {
    const t = this.tracks.get(nodeId);
    if (t === undefined) return null;
    // `beginFrame` 保证 `0 < elapsedMs < durationMs`（走满就删），所以 k ∈ (0,1)。
    const k = t.elapsedMs / t.durationMs;
    return {
      x: t.fromX + (t.toX - t.fromX) * k,
      y: t.fromY + (t.toY - t.fromY) * k,
    };
  }

  stats(): InterpStats {
    return {
      active: this.tracks.size,
      started: this.started,
      snapped: this.snapped,
      settled: this.settled,
      maxDistance: this.maxDistance,
    };
  }
}

export function createInterpolator(opts: InterpOptions = {}): Interpolator {
  return new InterpolatorImpl(opts);
}
