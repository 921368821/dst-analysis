/**
 * L4 · 客户端预测（只预测「移动」这一窄口）
 *
 * ★★ 要解决的是哪一个具体现象
 *
 *   不预测时，客户端本地角色的位置**只在快照到达时变**。默认 30Hz、每 5 拍广播，
 *   角色每秒动 6.7 次、每次跳一大段。更糟的是延迟：玩家按下方向键，要等「上行 RTT
 *   + 主机排队 + 下行快照」才看到自己动 —— 那是 100ms 以上，格斗 / 平台类的手感
 *   直接没了。预测把这一段变成「当拍就动」。
 *
 * ★★ 为什么只预测移动，不预测打斗 / 拾取 / AI
 *
 *   预测成立的前提是一句话：**同一 tick、同一输入 ⇒ 同一结果**。这句话在这个仓库里
 *   今天只有一处能证明 —— `motion/intent.ts` 的 `dirStep`：
 *
 *     · 输入是 `(intent, speed, dt)` 三个数，没有隐藏状态；
 *     · 只用 `+ - * /` 与 `hypot`，都是 IEEE-754 双精度里逐位可复现的（`hypot` 的
 *       可复现边界见 `docs/ONLINE-READINESS-PLAN.md` §17）；
 *     · 玩家与网络意图走的是**同一个函数**（批147 立的规矩），所以"客户端算一份、
 *       主机算另一份"这件事在结构上就不存在。
 *
 *   打斗 / 拾取不满足：它们要读背包、读 AI 决策、读随机数流，而 AI 的每拍决策依赖
 *   Map 迭代序与上几拍的缓存。预测它们等于**猜**，猜错的代价不是"抖一下"，而是
 *   客户端显示"我把怪打死了"、主机显示"没有"。
 *
 * ★★ 重放的边界由**主机说**，不由客户端猜
 *
 *   客户端在两次快照之间攒了 N 步预测。快照落地后要回答一个问题：「这 N 步里，
 *   哪些主机已经算过了？」算过了还重放 ⇒ 多走；没算过就不放 ⇒ 少走。两种都是
 *   位置漂移，而漂移的观感是"人物在滑"，日志里什么都看不出来。
 *
 *   猜测的写法有两种，都不能用：
 *     · 「快照是第 T 拍，我按本地 tick 数，tick ≤ T 的就算算过了」—— 要求两端
 *       共用同一个 tick 时钟。客户端中途加入时从 0 开始数，主机已经在第 1000 拍；
 *     · 「按往返时延估」—— 估错一次就永久偏，而且没法自证。
 *
 *   所以主机在每份快照里带一张**收据**（`AckEntry`）：每个实体「处理到哪一条意图
 *   （发送方的 `seq`）」。`seq` 是发送方自己的，与时钟无关。收据里"处理"包含三种
 *   结局 —— 执行了、被拒了、队列满被丢了。三种都必须算进去：漏掉任何一种，那一条
 *   意图就会永远留在客户端的待重放表里，一拍一步地重复应用。
 *
 * ★★ 客户端**不自己维护"我预测到了哪个位置"**，位置就在场景里
 *
 *   两次快照之间，场景里那个节点的坐标**就是**预测值（`predict` 每拍往上加）。
 *   快照落地后 `reconcile` 从主机给的位置重新加一遍剩下的步 —— 覆盖，不是累加。
 *   「累加」是个很自然的错：它让重放成为"在预测值上再走一遍"，无积压时看不出
 *   （两种算出来的数一样），一有积压就变成双倍位移。
 *
 * ★ 量化地板：快照是 `mode: "rollback"` 导出的，浮点被量化到 1e-9（见 `delta.ts`
 *   文件头 ①）。所以即使两端算得一模一样，重放出来的坐标与"主机若在本机算"也会
 *   差 ≤ 1e-9。这不是 bug，是快照的精度；`maxError` 把它记下来，判据钉的是这个量级。
 *
 * ★ 不做"平滑回正"。差异超过阈值时位置就是**跳**回去 —— 好看的做法是插值，但插值
 *   期间客户端显示的位置既不是主机的也不是自己的，而且插值本身要占一个状态机。
 *   第一批先把"世界状态正确"钉死；表现层的平滑（或者干脆把差异交给渲染层做视觉偏移）
 *   属于下一个决定，不该混在这里。
 */

import type { NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { CONTROLLER_TYPE, PlayerController } from "../input/player-controller.ts";
import { dirStep, type MoveIntent } from "../motion/intent.ts";
import type { AckEntry } from "./transport.ts";

/**
 * 一条还没被主机收据确认的本地步。
 *
 * ★ 存**意图 + dt**，不存"已经算好的位移"：重放时要用**当时那拍的速度**再算一遍，
 *   与主机 `move()` 走同一条路。存位移的话，第一步与重放的第二步会各自用一次自己的
 *   `speed`，一旦速度在这期间被改过（加速道具、受伤减速），两边就对不上 ——
 *   而"速度被改过"恰恰是最需要两边一致的时刻。
 */
interface PendingStep {
  readonly seq: number;
  readonly intent: MoveIntent;
  readonly dt: number;
}

/** 预测的诊断计数（面板与判据读这一份）。 */
export interface PredictStats {
  /** 本地先走了一步的总次数（= 真正被预测的输入条数）。 */
  readonly applied: number;
  /** 快照落地后重放的步数总和（这是"预测确实在起作用"的证据）。 */
  readonly replayed: number;
  /** 待重放表超上限被丢的最老步数。 */
  readonly dropped: number;
  /** 实体在快照里不见了（被销毁）而整条丢弃的次数。 */
  readonly resets: number;
  /** 当前还挂着的步数。 */
  readonly pending: number;
  /**
   * 重放前后的最大坐标偏差（世界单位）。
   *
   * ★ 没有积压、没有丢包时它应该停在**量化地板**（≈1e-9），而不是 0 ——
   *   快照把坐标量化到 1e-9 之后，从主机的位置往回加，加出来的数与本地一路加的
   *   差一点点。判据拿它当"预测没有算错"的上界：真的算错时这个数会是 1e-2 以上。
   */
  readonly maxError: number;
}

export interface PredictorOptions {
  /**
   * 每个实体最多挂多少步未确认。缺省 32（30Hz 下约 1 秒）。
   *
   * ★ 上限不是内存考虑，是**收敛**考虑：收据断了（主机不发 / 版本不匹配 / bug）时，
   *   无上限会让角色一直往前漂，玩家看到的是「人自己走」。有上限时领先量被卡在
   *   `上限 + 1` 步（那 +1 是本拍刚产生、还没被任何一份快照重放过的那一步），
   *   与跑了多少拍无关 —— 有界是可解释的，无声地越走越远不可解释。
   */
  readonly maxPerEntity?: number;
}

export interface Predictor {
  /**
   * 本地输入：先落地一步，再把它记进待重放表。返回 `false` = 没预测（不记）。
   *
   * ★ 顺序不可反。先记后落地时，若落地那步因为实体被销毁而失败，表里会留下一条
   *   "重放时会凭空加一步"的记录；而先落地后记，失败就是失败，表里干净。
   */
  predict(scene: Scene, entity: NodeId, seq: number, intent: MoveIntent, dt: number): boolean;
  /**
   * 一份快照装载**之后**：按收据剪掉已确认的步，再从主机的坐标把剩下的重放上去。
   *
   * ★ 只能在 `loadScene` **之后**调。之前在的话，重放结果会被随后的装载覆盖 ——
   *   现象是"预测只生效了一瞬间"，而且所有终态判据都还是绿的（下一次重放又对了）。
   *   返回重放的步数。
   */
  reconcile(scene: Scene, acks: readonly AckEntry[]): number;
  stats(): PredictStats;
}

class PredictorImpl implements Predictor {
  private readonly maxPerEntity: number;
  /** 待重放表。`Map` 的插入序就是发送序，重放也按这个序。 */
  private readonly pending = new Map<NodeId, PendingStep[]>();
  /**
   * 上一拍**玩家看到**的坐标。
   *
   * ★ 必须自己记一份：`reconcile` 跑在 `loadScene` 之后，那时节点里的预测值已经被
   *   主机坐标覆盖了。"这次重放把玩家挪了多少"（= 可见的抖动）只能与装载**之前**
   *   的那个数比，而那个数此刻只存在于这里。
   */
  private readonly shown = new Map<NodeId, { readonly x: number; readonly y: number }>();

  private applied = 0;
  private replayed = 0;
  private dropped = 0;
  private resets = 0;
  private maxError = 0;

  constructor(opts: PredictorOptions) {
    const max = opts.maxPerEntity ?? 32;
    if (!Number.isInteger(max) || max < 1) {
      throw new RangeError(`maxPerEntity 必须是 ≥1 的整数，收到 ${String(max)}`);
    }
    this.maxPerEntity = max;
  }

  predict(scene: Scene, entity: NodeId, seq: number, intent: MoveIntent, dt: number): boolean {
    const node = scene.find(entity);
    // 没有速度来源 = 主机那边也会以 `no-controller` 拒掉，预测它只会白跳一下。
    const c = node?.get<PlayerController>(CONTROLLER_TYPE);
    if (node === undefined || c === undefined) return false;
    const r = dirStep(intent, c.speed, dt);
    // 空输入不记：记了之后重放表里会多一条恒零的步，`pending` 永远回不到 0，
    // 判据「没有积压时表为空」就再也不会成立。
    if (r.dx === 0 && r.dz === 0) return false;
    node.setLocalPosition(node.localPosition.x + r.dx, node.localPosition.y + r.dz);
    this.shown.set(entity, { x: node.localPosition.x, y: node.localPosition.y });
    this.applied++;

    let q = this.pending.get(entity);
    if (q === undefined) {
      q = [];
      this.pending.set(entity, q);
    }
    q.push({ seq, intent, dt });
    while (q.length > this.maxPerEntity) {
      q.shift();
      this.dropped++;
    }
    return true;
  }

  reconcile(scene: Scene, acks: readonly AckEntry[]): number {
    const acked = new Map<NodeId, number>();
    for (const a of acks) acked.set(a.entity, a.seq);
    // ★ 这里不做"取最大"的合并：快照本身是**按 seq 递增**应用的（`session.noteSeq`
    //   把乱序 / 重放的旧快照挡在 `commit` 之前），所以这一份的收据只可能比上一份新。
    //   加一层 max 是防御性的死代码 —— 而它会让"收据真的可以让客户端少剪一步"这件事
    //   变得不可观察（判据写不出来）。

    if (this.pending.size === 0) return 0;

    let replayed = 0;
    // ★ 先剪再放：剪的时候别删 key。否则"这一实体刚好被确认完、但下面还要重放"
    //   会走成两条路径，而两条路径里只要有一条忘了把节点位置写回去，就是永久偏移。
    for (const [entity, q] of this.pending) {
      const limit = acked.get(entity);
      if (limit !== undefined) {
        while (q.length > 0) {
          const head = q[0];
          if (head === undefined || head.seq > limit) break;
          q.shift();
        }
      }

      const node = scene.find(entity);
      if (node === undefined) {
        // 实体被销毁：这批步永远不会有人确认了，整条丢掉。
        this.resets++;
        this.pending.delete(entity);
        this.shown.delete(entity);
        continue;
      }
      if (q.length === 0) {
        // 全被确认：主机的坐标就是最终答案，不需要重放。
        this.pending.delete(entity);
        this.shown.delete(entity);
        continue;
      }
      const c = node.get<PlayerController>(CONTROLLER_TYPE);
      if (c === undefined) {
        this.pending.delete(entity);
        this.shown.delete(entity);
        continue;
      }

      // ★ 基准是**刚装载进来的主机坐标**，不是上一拍的预测值（见文件头）。
      const before = node.localPosition;
      let x = before.x;
      let y = before.y;
      for (const step of q) {
        const r = dirStep(step.intent, c.speed, step.dt);
        x += r.dx;
        y += r.dz;
      }
      // 抖动 = 这次重放把玩家**从上一拍看到的坐标**挪了多远。没有积压、没有丢包时
      // 它停在量化地板（≈1e-9）；主机丢过一条意图时它是一步的量（speed × dt ≈ 0.15）。
      const seen = this.shown.get(entity);
      if (seen !== undefined) {
        const err = Math.hypot(x - seen.x, y - seen.y);
        if (err > this.maxError) this.maxError = err;
      }
      node.setLocalPosition(x, y);
      this.shown.set(entity, { x, y });
      replayed += q.length;
    }
    this.replayed += replayed;
    return replayed;
  }

  stats(): PredictStats {
    let pending = 0;
    for (const q of this.pending.values()) pending += q.length;
    return {
      applied: this.applied,
      replayed: this.replayed,
      dropped: this.dropped,
      resets: this.resets,
      pending,
      maxError: this.maxError,
    };
  }
}

export function createPredictor(opts: PredictorOptions = {}): Predictor {
  return new PredictorImpl(opts);
}
