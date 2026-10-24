/**
 * L4 · 仇恨表：**谁打过我，我记多久**
 *
 * 批69 之前，生物追人只靠"看见"（感知半径）。于是有一条很别扭的规则：
 * **打它一下、退到视野外，它就当作什么都没发生**。玩家于是学会了"打了就跑"，
 * 而这不是玩法设计，是"没有记忆"的副作用。
 *
 * 这个文件只回答一件事：**某只生物此刻最恨谁、恨到什么程度、什么时候忘**。
 *
 * ★★ 五个刻意的决定：
 *
 * ① **同一攻击者只留一条，累加**（不是每一下一条）。
 *    每下一条的话，100 下之后表里有 100 条同一个人的记录：`maxPerTarget` 一满
 *    就把**别人**挤掉，而"别人"才是后打的那个。累加也符合直觉：打三下比打一下更招恨。
 *
 * ② **过期按 tick 差算**（`tick - since >= decayTicks`），不是"每 tick 减一点"。
 *    递减会让"多久忘记"取决于调用频率：一个 tick 调两次就忘得快一倍，
 *    而浮点递减还会留下 `0.0000001` 这种永远不归零的尾巴。
 *
 * ③ **读取时顺手剔除过期的**（`best` / `amountOf` 都会）。
 *    只在写入时清理的话，"打一下就再没人打过我"的那些生物会永远留着那条记录，
 *    内存随战斗次数单向增长，而症状是"很久以前被谁打过还在追"。
 *
 * ④ **提供 `forget(attackerId)`，并在击杀时调用**。
 *    攻击者死了不忘记的话，`best` 会返回一个不在场景里的 id ——
 *    AI 会朝一个不存在的目标走一辈子，日志里只有一行"目标不存在"。
 *
 * ⑤ **表不进场景（不是组件）**。它是**运行期状态**：读档之后"谁恨谁"从头算，
 *    这和 `Health.invulnUntil` 同一类。放进组件就要把"一堆 (id, 数值) 对"
 *    塞进只支持标量字段的 schema 里 —— 那会变成一整个字符串编码器。
 */

/** 参数不合法。 */
export const THREAT_BAD_OPTIONS = "THREAT.BAD_OPTIONS";
/** 累加的仇恨值不是正数（0 与负数会让"记恨"这件事静默失效）。 */
export const THREAT_BAD_AMOUNT = "THREAT.BAD_AMOUNT";

export interface ThreatOptions {
  /** 多久没再挨打就忘掉（tick，正整数）。 */
  readonly decayTicks: number;
  /** 每个目标最多记几条（默认 8）。超了先丢**最不恨**的那条。 */
  readonly maxPerTarget?: number;
}

export interface ThreatEntry {
  readonly attackerId: number;
  readonly amount: number;
  /** 最后一次挨这个人打的 tick。 */
  readonly since: number;
}

export interface ThreatStats {
  /** 有仇恨的目标数（生物数）。 */
  readonly targets: number;
  /** 一共记了多少条（目标 × 攻击者）。 */
  readonly entries: number;
  /** 累计因为过期被剔除的条数（诊断"忘记"有没有真的发生）。 */
  readonly expired: number;
  /** 累计因为超过上限被挤掉的条数（正常应为 0；不为 0 说明上限太小）。 */
  readonly evicted: number;
}

interface Row {
  amount: number;
  since: number;
}

export class ThreatTable {
  private readonly decayTicks: number;
  private readonly maxPerTarget: number;
  /** `目标 → (攻击者 → 记录)`。用嵌套 Map 而不是"扁平 key 字符串"：键是数字，不该被拼成字符串。 */
  private readonly table = new Map<number, Map<number, Row>>();
  private expired = 0;
  private evicted = 0;

  constructor(options: ThreatOptions) {
    const d = options.decayTicks;
    if (!Number.isInteger(d) || d <= 0) {
      throw new RangeError(`${THREAT_BAD_OPTIONS}: decayTicks 必须是正整数，得到 ${String(d)}`);
    }
    const m = options.maxPerTarget ?? 8;
    if (!Number.isInteger(m) || m <= 0) {
      throw new RangeError(`${THREAT_BAD_OPTIONS}: maxPerTarget 必须是正整数，得到 ${String(m)}`);
    }
    this.decayTicks = d;
    this.maxPerTarget = m;
  }

  get decay(): number {
    return this.decayTicks;
  }

  /**
   * 记一笔：`attackerId` 在 `tick` 这一刻对 `targetId` 造成了 `amount` 点伤害。
   *
   * 校验顺序：数量 → 自己打自己。**都失败在"一点状态都不动"之前**。
   */
  add(targetId: number, attackerId: number, amount: number, tick: number): { ok: true } | { ok: false; code: string } {
    if (!Number.isFinite(amount) || amount <= 0) {
      return { ok: false, code: THREAT_BAD_AMOUNT };
    }
    if (targetId === attackerId) {
      // 自己打自己：记下来会让它"恨自己"，然后朝自己走
      return { ok: false, code: THREAT_BAD_AMOUNT };
    }
    let row = this.table.get(targetId);
    if (row === undefined) {
      row = new Map();
      this.table.set(targetId, row);
    }
    const prev = row.get(attackerId);
    if (prev === undefined) {
      if (row.size >= this.maxPerTarget) this.evictWeakest(row);
    }
    row.set(attackerId, { amount: (prev?.amount ?? 0) + amount, since: tick });
    return { ok: true };
  }

  /**
   * 最恨谁（`null` = 谁也不恨）。顺手剔除过期的（见文件头 ③）。
   *
   * `alive` 是**可选的过滤器**：传进来时，被它否掉的人不算 ——
   * 但**不会**因此删除记录（"暂时打不到"与"已经不恨了"是两件事）。
   */
  best(targetId: number, tick: number, alive?: (attackerId: number) => boolean): number | null {
    const row = this.table.get(targetId);
    if (row === undefined) return null;
    this.sweep(targetId, row, tick);
    let bestId: number | null = null;
    let bestAmount = -1;
    for (const [attackerId, r] of row) {
      if (alive !== undefined && !alive(attackerId)) continue;
      // ★ 平手时按 id 升序取：不引入"谁先写进 Map 谁优先"这种隐式规则
      //   （Map 的插入顺序看起来确定，但它是"历史"而不是"规则"）
      if (r.amount > bestAmount || (r.amount === bestAmount && bestId !== null && attackerId < bestId)) {
        bestAmount = r.amount;
        bestId = attackerId;
      }
    }
    return bestId;
  }

  /** 某人对某目标的仇恨值（过期即 0）。 */
  amountOf(targetId: number, attackerId: number, tick: number): number {
    const row = this.table.get(targetId);
    if (row === undefined) return 0;
    this.sweep(targetId, row, tick);
    return row.get(attackerId)?.amount ?? 0;
  }

  /** 这个目标记了几条（自检/判据用）。 */
  sizeOf(targetId: number, tick: number): number {
    const row = this.table.get(targetId);
    if (row === undefined) return 0;
    this.sweep(targetId, row, tick);
    return row.size;
  }

  /** 忘掉某个攻击者（他死了 / 离开世界了）。返回真的删掉了几条。 */
  forget(attackerId: number): number {
    let n = 0;
    for (const [targetId, row] of [...this.table]) {
      if (row.delete(attackerId)) n++;
      if (row.size === 0) this.table.delete(targetId);
    }
    return n;
  }

  /** 只忘掉"某人对某目标"这一条。 */
  forgetOne(targetId: number, attackerId: number): boolean {
    const row = this.table.get(targetId);
    if (row === undefined) return false;
    const had = row.delete(attackerId);
    if (row.size === 0) this.table.delete(targetId);
    return had;
  }

  stats(): ThreatStats {
    let entries = 0;
    for (const row of this.table.values()) entries += row.size;
    return { targets: this.table.size, entries, expired: this.expired, evicted: this.evicted };
  }

  /** 剔除过期项；顺手把空的目标删掉（否则 `targets` 会只涨不跌）。 */
  private sweep(targetId: number, row: Map<number, Row>, tick: number): void {
    for (const [attackerId, r] of [...row]) {
      if (tick - r.since >= this.decayTicks) {
        row.delete(attackerId);
        this.expired++;
      }
    }
    if (row.size === 0) this.table.delete(targetId);
  }

  /** 丢掉最不恨的那一条（平手丢 id 最大的：让结果只取决于数值与 id）。 */
  private evictWeakest(row: Map<number, Row>): void {
    let weakId: number | null = null;
    let weakAmount = Number.POSITIVE_INFINITY;
    for (const [attackerId, r] of row) {
      if (r.amount < weakAmount || (r.amount === weakAmount && weakId !== null && attackerId > weakId)) {
        weakAmount = r.amount;
        weakId = attackerId;
      }
    }
    if (weakId !== null) {
      row.delete(weakId);
      this.evicted++;
    }
  }
}

export function createThreatTable(options: ThreatOptions): ThreatTable {
  return new ThreatTable(options);
}
