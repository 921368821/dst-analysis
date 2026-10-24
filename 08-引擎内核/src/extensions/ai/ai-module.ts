/**
 * L4 · AI 模块（`ai.behavior`）—— 把行为树真的挂到 tick 上
 *
 * `behavior.ts` 只给了"树怎么算"。本文件回答一个不同的问题：
 * **谁来每 tick 驱动它们，以及驱动失败时怎么办。**
 *
 * ★ 为什么单独一个文件而不是塞进 behavior.ts：
 *   行为树是纯逻辑（可以在 Node 里跑一万次，不碰宿主）；
 *   模块是有生命周期的东西（init/stop/dispose、日志、错误隔离）。
 *   混在一起会让"树算得对不对"和"模块接线对不对"两种失败互相掩盖。
 *
 * ★ `update(tick, dt)` 显式接受 `dt` 但**不使用**。
 *   仓库约定宿主的步进签名是 `(tick, dt)`（与 `anim-module` / `script-module` 一致），
 *   所以签名照抄；但决策只用 tick 与内部计数器。
 *   **用它就会破坏"同种子同世界"** —— 丢一帧就换个决定。这条写在签名上、
 *   写在注释里、再用判据钉住（把 dt 从 0.001 改到 100，状态序列必须一模一样）。
 *
 * ★ 驱动顺序按 **spawn 递增的 id 升序**，不依赖 Map 的迭代顺序。
 *   Map 目前保插入序，但那是实现细节；一旦有人把 agents 换成别的容器，
 *   "第 7 个 tick 谁先动"就变了，而回放只认字节。
 *
 * ★ 一个 agent 的 op 抛异常 ⇒ **隔离并计数**，不让整个 tick 崩，也不静默：
 *   该 agent 当轮记 failure、`errors++`、`reset()` 后下一 tick 从根重来。
 *   为什么要 reset：异常可能抛在树的中途，`cursor`/`elapsed` 停在一个
 *   "看起来一致、实际不可信"的位置；接着续跑等于把坏状态带进后续决策。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Logger } from "../../foundation/log/logger.ts";
import { AiAgent, Board, type AiNode, type AiOps } from "./behavior.ts";

export const AI_TOO_MANY_AGENTS = "AI.TOO_MANY_AGENTS";
export const AI_NO_SUCH_AGENT = "AI.NO_SUCH_AGENT";

export interface AiAgentSpec {
  readonly tree: AiNode;
  readonly ops: AiOps;
  /** 各自的黑板。省略则新建一个空的（**不会**与别人共享）。 */
  readonly board?: Board;
}

export interface AiModuleOptions {
  readonly id?: string;
  /** 同时存在的 agent 上限（默认 512）。超了报错，不静默丢弃。 */
  readonly maxAgents?: number;
}

export interface AiModuleStats {
  readonly agents: number;
  /** 累计成功的 step 次数（不含抛异常的那些）。 */
  readonly steps: number;
  /** op 抛异常的累计次数。非 0 说明某个行为一直在炸，要去看它的日志。 */
  readonly errors: number;
  readonly lastTick: number;
}

export interface AiModuleHandle extends IModule {
  /** 注册一个 agent，返回它的 id（从 1 递增）。树或 op 有错就返回错误，不占号。 */
  spawn(spec: AiAgentSpec): Result<number, EngineError>;
  /** 移除。返回是否真的存在（不存在返回 false，不抛）。 */
  despawn(agentId: number): boolean;
  /** 宿主在 `scheduler.onStep` 里的入口。`dt` 不参与决策。 */
  update(tick: number, dt: number): void;
  board(agentId: number): Board | undefined;
  agentCount(): number;
  stats(): AiModuleStats;
}

interface Entry {
  readonly id: number;
  readonly agent: AiAgent;
  readonly board: Board;
}

export function createAiModule(options: AiModuleOptions = {}): AiModuleHandle {
  const maxAgents = options.maxAgents ?? 512;
  /** 按 id 升序维护：驱动顺序就是它，不依赖 Map 迭代顺序。 */
  const entries: Entry[] = [];
  let nextId = 1;
  let steps = 0;
  let errors = 0;
  let lastTick = -1;
  let root: Logger | undefined;

  function indexOf(agentId: number): number {
    // 线性查找：agent 规模是几百，且只有 spawn/despawn 会走这里；
    // 换成 Map<id, index> 反而要维护"删元素后下标全变"的一致性
    for (let i = 0; i < entries.length; i++) {
      if (entries[i]!.id === agentId) return i;
    }
    return -1;
  }

  const mod: AiModuleHandle = {
    id: options.id ?? "ai.behavior",

    init(ctx: ModuleContext): void {
      root = ctx.log;
    },

    describe(): string {
      return `ai: ${String(entries.length)} agent(s), ${String(steps)} step(s), ${String(errors)} error(s)`;
    },

    dispose(): void {
      entries.length = 0;
      steps = 0;
      errors = 0;
      lastTick = -1;
    },

    spawn(spec: AiAgentSpec): Result<number, EngineError> {
      if (entries.length >= maxAgents) {
        return err({
          code: AI_TOO_MANY_AGENTS,
          message: `agent 数量已达上限 ${String(maxAgents)} —— 拒绝继续注册（不静默丢弃）`,
        });
      }
      const created = AiAgent.create(spec.tree, spec.ops);
      if (!created.ok) return created;
      const id = nextId++;
      entries.push({ id, agent: created.value, board: spec.board ?? new Board() });
      // 保持 id 升序：id 只增不减，追加即有序
      return ok(id);
    },

    despawn(agentId: number): boolean {
      const i = indexOf(agentId);
      if (i < 0) return false;
      entries.splice(i, 1);
      return true;
    },

    update(tick: number, _dt: number): void {
      lastTick = tick;
      // ★ `_dt` 刻意不用：用它就破坏确定性（见文件头）
      for (const e of entries) {
        try {
          e.agent.step({ tick, board: e.board });
          steps++;
        } catch (cause) {
          errors++;
          // 异常可能抛在树的中途：记忆停在一个不可信的位置，续跑会把坏状态带下去
          e.agent.reset();
          const msg = cause instanceof Error ? cause.message : String(cause);
          root?.channel("ai").warn(`agent ${String(e.id)} 的行为抛异常，已隔离并重置：${msg}`);
        }
      }
    },

    board(agentId: number): Board | undefined {
      const i = indexOf(agentId);
      return i < 0 ? undefined : entries[i]!.board;
    },

    agentCount(): number {
      return entries.length;
    },

    stats(): AiModuleStats {
      return { agents: entries.length, steps, errors, lastTick };
    },
  };

  return mod;
}
