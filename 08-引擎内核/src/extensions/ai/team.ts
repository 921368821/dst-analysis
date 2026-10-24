/**
 * L4 · AI 队伍（阶段 3：**别都追同一个**）
 *
 * 一个队伍要解决的是"资源争抢"，不是"关系"：
 * 三只猎狗看见同一只兔子，如果各自独立决策，会**同时**扑上去 —— 结果两只白跑，
 * 而远处的羊没人管。这个现象在单 agent 判据里完全看不到，只有 ≥2 个 agent 时才暴露。
 *
 * ★ 三个决定：
 *
 * ① **目标要能被"占住"（claim）**：一个目标同一时刻只属于一个 agent。
 *    这是队伍级的**意图登记**，不是锁 —— 它不改世界，只让后来者知道"有人去了"。
 *    谁先来谁占（先到先得），后来者拿不到就去看下一个候选。**不排队、不抢**：
 *    抢的制度需要时钟与优先级，而这个仓库里最怕的就是引入没判据的时序。
 *
 * ② **角色是字符串，但分配必须确定**：`planRoles` 按 agent id 升序填配额，
 *    同输入同输出。角色名由宿主定义（引擎不认识"猎人"）—— 与 `pickup` 的
 *    `amount`、背包的 `kind` 是同一个取舍：**引擎不认业务名词**。
 *
 * ③ **黑板只放数字**（复用 `Board`）。队伍共享的是"今天我们往哪走""还剩几个人"
 *    这类标量，不是对象引用 —— 后者会带来循环引用与"改了一个人看到的不一样"。
 *
 * ★ 不做什么：不做队形/编队移动、不做仇恨链传递。那两样都需要导航与战斗系统，
 *   在没有它们之前做出来只能是"看起来像，跑起来不对"。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import { Board } from "./behavior.ts";

export const TEAM_NOT_MEMBER = "TEAM.NOT_MEMBER";
export const TEAM_TARGET_TAKEN = "TEAM.TARGET_TAKEN";
export const TEAM_BAD_INPUT = "TEAM.BAD_INPUT";

export interface TeamOptions {
  readonly id?: string;
  /** 队员上限（默认 64）。超了报错，不静默丢弃。 */
  readonly maxMembers?: number;
}

/** 占位结果：`taken` 里带着"谁占了"，调用方可以直接去问它要下一个目标。 */
export interface ClaimResult {
  readonly targetId: number;
  /** 拿到的 agent id。 */
  readonly by: number;
  /** 之前就有人占着（`by` 不是本人）。 */
  readonly taken: boolean;
}

export class Team {
  readonly id: string;
  /** 队伍共享黑板的**只读投影**：外部要改必须走 `setShared`（可控、可记日志）。 */
  readonly shared = new Board();

  private readonly maxMembers: number;
  /** agentId → 角色 */
  private readonly roles = new Map<number, string>();
  /** targetId → agentId（先到先得） */
  private readonly claims = new Map<number, number>();

  constructor(options: TeamOptions = {}) {
    const max = options.maxMembers ?? 64;
    if (!Number.isInteger(max) || max <= 0) throw new RangeError(`maxMembers 必须是正整数，得到 ${String(max)}`);
    this.id = options.id ?? "team";
    this.maxMembers = max;
  }

  size(): number {
    return this.roles.size;
  }

  /** 加人。重复加入**幂等**（返回 ok false），不覆盖已登记的角色。 */
  add(agentId: number, role: string): Result<boolean, EngineError> {
    if (!Number.isInteger(agentId) || agentId < 0) {
      return err(engineError(TEAM_BAD_INPUT, `agentId 必须是 >= 0 的整数，得到 ${String(agentId)}`));
    }
    if (role.length === 0) return err(engineError(TEAM_BAD_INPUT, "角色名不能为空"));
    if (this.roles.has(agentId)) return ok(false);
    if (this.roles.size >= this.maxMembers) {
      return err(engineError(TEAM_BAD_INPUT, `队伍已满（上限 ${String(this.maxMembers)}）—— 拒绝而不是静默丢弃`));
    }
    this.roles.set(agentId, role);
    return ok(true);
  }

  /** 移除队员，并释放他占的目标。返回该 agent 之前占着的 targetId（没有则 null）。 */
  remove(agentId: number): number | null {
    this.roles.delete(agentId);
    for (const [target, owner] of [...this.claims]) {
      if (owner === agentId) {
        this.claims.delete(target);
        return target;
      }
    }
    return null;
  }

  role(agentId: number): string | undefined {
    return this.roles.get(agentId);
  }

  /** 队员 id（升序）。**升序**是契约的一部分：宿主的驱动顺序不能取决于插入顺序。 */
  members(role?: string): readonly number[] {
    const out: number[] = [];
    for (const [id, r] of this.roles) if (role === undefined || r === role) out.push(id);
    return out.sort((a, b) => a - b);
  }

  /**
   * 占一个目标。
   *
   * 语义（判据按这三条写）：
   *  · 本人已占**同一个** → `taken: false`（幂等成功）；
   *  · 别人已占 → `taken: true`，`by` 是他（**不报错**：调用方要能拿到"谁占了"去看下一个）；
   *  · 目标被占的本人**改占另一个** → 旧的自动释放（一个 agent 只占一个目标）。
   */
  claim(agentId: number, targetId: number): Result<ClaimResult, EngineError> {
    if (!this.roles.has(agentId)) {
      return err(engineError(TEAM_NOT_MEMBER, `agent ${String(agentId)} 不在队伍「${this.id}」里`));
    }
    if (!Number.isInteger(targetId) || targetId < 0) {
      return err(engineError(TEAM_BAD_INPUT, `targetId 必须是 >= 0 的整数，得到 ${String(targetId)}`));
    }
    const owner = this.claims.get(targetId);
    if (owner !== undefined && owner !== agentId) {
      return ok({ targetId, by: owner, taken: true });
    }
    // 改占：先把这个 agent 占着的旧目标放掉（否则一个 agent 会同时占着好几个）
    for (const [t, o] of [...this.claims]) if (o === agentId && t !== targetId) this.claims.delete(t);
    this.claims.set(targetId, agentId);
    return ok({ targetId, by: agentId, taken: false });
  }

  /** 释放（不传 targetId 就释放该 agent 占着的那个）。返回是否真的释放了东西。 */
  release(agentId: number, targetId?: number): boolean {
    if (targetId !== undefined) {
      if (this.claims.get(targetId) !== agentId) return false;
      this.claims.delete(targetId);
      return true;
    }
    let freed = false;
    for (const [t, o] of [...this.claims]) {
      if (o === agentId) {
        this.claims.delete(t);
        freed = true;
      }
    }
    return freed;
  }

  /** 这个目标归谁（没有则 null）。 */
  ownerOf(targetId: number): number | null {
    return this.claims.get(targetId) ?? null;
  }

  /** 当前所有占用（按 targetId 升序 —— 判据与日志读它都不会因插入序而变）。 */
  claimsSnapshot(): ReadonlyArray<{ targetId: number; by: number }> {
    return [...this.claims.entries()]
      .map(([targetId, by]) => ({ targetId, by }))
      .sort((a, b) => a.targetId - b.targetId);
  }

  /** 共享黑板写入口（整数键值；非整数直接抛 —— 团队黑板里的 NaN 会污染决策）。 */
  setShared(key: string, value: number): void {
    if (!Number.isFinite(value)) throw new RangeError(`队伍黑板的 ${key} 必须是有限数，得到 ${String(value)}`);
    this.shared.set(key, value);
  }
}

/**
 * 按配额分配角色（**纯函数**：不改任何东西，只给一张表）。
 *
 * @param ids 队员 id（顺序无所谓 —— 函数内部先升序，于是同集合必得同结果）
 * @param quota 角色 → 名额。如果某个角色的数量写 `Infinity`，表示"把剩下的都给它"。
 * @returns id 升序的角色表；配额没覆盖到的按 `fallback` 填。
 *
 * ★ 填配额的顺序**两层都写死**：先按**角色名升序**，角色内按 **agent id 升序**。
 *   不用 `quota` 的声明顺序 —— 那依赖调用方怎么写对象字面量，
 *   同一份配置改个顺序就会换人，而"换人"在存档与回放里是不可接受的差异。
 *
 * ★ 为什么"按 id 升序填配额"而不是"随机/轮流"：随机要种子（多一处状态），
 *   轮流要记上次轮到谁（又多一处状态）。升序是**无状态**的，而且可复现。
 *   代价是"总是最小的几个 id 当猎人"—— 对原型阶段完全够用，写在这里免得以后误解。
 */
export function planRoles(
  ids: readonly number[],
  quota: Readonly<Record<string, number>>,
  fallback = "idle",
): ReadonlyMap<number, string> {
  const sorted = [...ids].sort((a, b) => a - b);
  const out = new Map<number, string>();
  let i = 0;
  for (const role of Object.keys(quota).sort()) {
    const n = quota[role]!;
    if (n !== Infinity && (!Number.isInteger(n) || n < 0)) {
      throw new RangeError(`角色「${role}」的名额必须是 >= 0 的整数或 Infinity，得到 ${String(n)}`);
    }
    const limit = n === Infinity ? sorted.length : n;
    for (let k = 0; k < limit && i < sorted.length; k++, i++) out.set(sorted[i]!, role);
  }
  for (; i < sorted.length; i++) out.set(sorted[i]!, fallback);
  return out;
}
