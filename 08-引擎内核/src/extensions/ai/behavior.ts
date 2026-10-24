/**
 * L4 · AI 行为树（阶段 3 的最后一条）
 *
 * 两个决定，决定了后面**所有判据能不能写**：
 *
 * ① **树是纯数据**：`AiNode` 只含 `kind/id/op/children/ticks`，行为靠 `op` 名字在注册表里查。
 *   理由：树要能存档、要能由编辑器导出、要能进世界指纹 —— **函数不能序列化**。
 *   这和物理的 `PositionAccessor`、脚本的反射表是同一个取舍：把"数据"与"行为"分开，
 *   于是"树有没有被改坏"可以被单独验证，而不必跑一遍行为。
 *
 * ② **决策吃 tick，不吃 dt**。`wait` 数的是"被 step 了几次"，不是"过了多少毫秒"。
 *   理由：dt 会让"同种子同世界"这条承诺在 AI 上失效（丢一帧就换个决定），
 *   而饥荒式玩法本来不需要亚 tick 精度。判据里专门有一条：**把 tick 值跳成 0/100/1000，
 *   `wait(3)` 仍然恰好需要 3 次 step** —— 这就是"没吃 dt"的可验证形式。
 *
 * ★ 记忆放在 agent 上，不放在树上。
 *   这是本文件最容易写错的地方：一旦把 `cursor`/`elapsed` 挂在节点对象上，
 *   两个共用同一棵树的 agent 会互相踩，而且**只有多个 agent 同时存在时才暴露**。
 *   所以判据里必有一条"同一棵树、两个 agent、互不干扰"。
 *
 * ★ `running` 是唯一带记忆的状态。
 *   `success`/`failure` 都会把记忆清掉 ⇒ 下一轮从头开始。
 *   于是"承诺"这件事有了精确定义：**只有还在 running 的动作会被续上**，
 *   已经成功/失败的分支不会被反复执行 —— 判据用"do 的调用次数"来验，
 *   而不是靠读代码相信。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";

export type Status = "success" | "failure" | "running";

export type AiNodeKind = "sequence" | "selector" | "inverter" | "wait" | "do" | "check";

/** 行为树节点。**纯数据**：可以 JSON 往返、可以进指纹。 */
export interface AiNode {
  readonly id: string;
  readonly kind: AiNodeKind;
  /** sequence / selector 的 1..N 个子节点；inverter 恰好 1 个；叶子没有。 */
  readonly children?: readonly AiNode[];
  /** `do` / `check` / `wait` 的行为名（在 `AiOps` 里查）。 */
  readonly op?: string;
  /** `wait` 专用：需要几个 tick。整数且 >= 0；0 表示"本 tick 立即成功"。 */
  readonly ticks?: number;
}

/** 黑板：**只放数字**。放对象/函数就等着"指纹里的 NaN"和"存档里的循环引用"吧。 */
export class Board {
  private readonly data = new Map<string, number>();

  get(key: string): number {
    return this.data.get(key) ?? 0;
  }

  set(key: string, value: number): void {
    this.data.set(key, value);
  }

  has(key: string): boolean {
    return this.data.has(key);
  }

  /** 快照（升序键，便于比对与写日志）。 */
  snapshot(): Record<string, number> {
    const out: Record<string, number> = {};
    for (const k of [...this.data.keys()].sort()) out[k] = this.data.get(k)!;
    return out;
  }
}

export interface AiTick {
  readonly tick: number;
  readonly board: Board;
}

export type AiOp = (ctx: AiTick, node: AiNode) => Status;

/** 行为注册表。缺 op 在**构造时**就报错，不等跑到那一支才炸。 */
export type AiOps = Readonly<Record<string, AiOp>>;

export const AI_BAD_TREE = "AI.BAD_TREE";
export const AI_UNKNOWN_OP = "AI.UNKNOWN_OP";
export const AI_DUPLICATE_ID = "AI.DUPLICATE_ID";
export const AI_TOO_DEEP = "AI.TOO_DEEP";

/** 深度上限。用途不是"防手滑"，而是**防数据里藏了环**：环形树在递归时会一直往下走。 */
const MAX_DEPTH = 64;

interface Checked {
  readonly ids: Set<string>;
}

function validateNode(node: AiNode, path: string, depth: number, ops: AiOps, seen: Checked): Result<true, EngineError> {
  if (depth > MAX_DEPTH) {
    return err({
      code: AI_TOO_DEEP,
      message: `${path} 深度超过 ${String(MAX_DEPTH)} —— 数据里可能藏了环（树不该有环）`,
      detail: { path, depth },
    });
  }
  if (typeof node.id !== "string" || node.id.length === 0) {
    return err({ code: AI_BAD_TREE, message: `${path} 缺少 id`, detail: { path } });
  }
  if (seen.ids.has(node.id)) {
    // 重复 id 的后果很隐蔽：两个节点共用一份记忆，其中一个的 running 会被另一个续上
    return err({ code: AI_DUPLICATE_ID, message: `${path} 的 id「${node.id}」重复`, detail: { id: node.id } });
  }
  seen.ids.add(node.id);

  const kids = node.children ?? [];
  switch (node.kind) {
    case "sequence":
    case "selector":
      if (kids.length === 0) {
        return err({ code: AI_BAD_TREE, message: `${path}（${node.kind}）必须有至少 1 个子节点`, detail: { path } });
      }
      break;
    case "inverter":
      if (kids.length !== 1) {
        return err({
          code: AI_BAD_TREE,
          message: `${path}（inverter）必须恰好 1 个子节点，实际 ${String(kids.length)}`,
          detail: { path },
        });
      }
      break;
    case "wait": {
      const t = node.ticks;
      if (t === undefined || !Number.isInteger(t) || t < 0) {
        return err({
          code: AI_BAD_TREE,
          message: `${path}（wait）的 ticks 必须是 >= 0 的整数，实际 ${String(t)}`,
          detail: { path },
        });
      }
      break;
    }
    case "do":
    case "check":
      if (kids.length !== 0) {
        return err({ code: AI_BAD_TREE, message: `${path}（${node.kind}）是叶子，不该有子节点`, detail: { path } });
      }
      break;
    default:
      return err({ code: AI_BAD_TREE, message: `${path} 的 kind「${String(node.kind)}」不认识`, detail: { path } });
  }

  if (node.kind === "do" || node.kind === "check") {
    const op = node.op;
    if (op === undefined || !Object.prototype.hasOwnProperty.call(ops, op)) {
      return err({
        code: AI_UNKNOWN_OP,
        message: `${path}（${node.kind}）引用了未注册的行为「${String(op)}」`,
        detail: { path, op: String(op), available: Object.keys(ops).sort() },
      });
    }
  }

  for (let i = 0; i < kids.length; i++) {
    const r = validateNode(kids[i]!, `${path}.children[${String(i)}]`, depth + 1, ops, seen);
    if (!r.ok) return r;
  }
  return ok(true);
}

export class AiAgent {
  readonly tree: AiNode;
  private readonly ops: AiOps;

  /**
   * 记忆（**每 agent 一份**）：
   *  · `cursor`：sequence/selector 停在了第几个子节点（只在 running 时存在）
   *  · `elapsed`：wait 节点已经消耗了几个 tick
   */
  private readonly cursor = new Map<string, number>();
  private readonly elapsed = new Map<string, number>();

  private constructor(tree: AiNode, ops: AiOps) {
    this.tree = tree;
    this.ops = ops;
  }

  static create(tree: AiNode, ops: AiOps): Result<AiAgent, EngineError> {
    const r = validateNode(tree, "root", 0, ops, { ids: new Set<string>() });
    if (!r.ok) return r;
    return ok(new AiAgent(tree, ops));
  }

  /** 跑一个 tick。返回根节点的状态。**不吃 dt**：只依赖被调用的次数与黑板。 */
  step(ctx: AiTick): Status {
    return this.evalNode(this.tree, ctx, 0);
  }

  /** 清掉全部记忆（换目标、被眩晕、读档后想重来一次时用）。 */
  reset(): void {
    this.cursor.clear();
    this.elapsed.clear();
  }

  /** 只读观察：当前有多少个节点记着 running 位置（判据用它证明"记忆没串"）。 */
  memorySize(): number {
    return this.cursor.size + this.elapsed.size;
  }

  private evalNode(node: AiNode, ctx: AiTick, depth: number): Status {
    // 深度不在这里再查：构造时已经查过，这里再查只会让热路径变慢。
    // 但**必须**留一个硬上限，否则数据被外部改坏后就是栈溢出而不是报错。
    if (depth > MAX_DEPTH) return "failure";

    switch (node.kind) {
      case "sequence": {
        const kids = node.children!;
        let i = this.cursor.get(node.id) ?? 0;
        for (; i < kids.length; i++) {
          const st = this.evalNode(kids[i]!, ctx, depth + 1);
          if (st === "running") {
            // 只有 running 带记忆：下一次从这里继续，前面的分支不再执行
            this.cursor.set(node.id, i);
            return "running";
          }
          if (st === "failure") {
            this.cursor.delete(node.id);
            return "failure";
          }
        }
        this.cursor.delete(node.id);
        return "success";
      }
      case "selector": {
        const kids = node.children!;
        let i = this.cursor.get(node.id) ?? 0;
        for (; i < kids.length; i++) {
          const st = this.evalNode(kids[i]!, ctx, depth + 1);
          if (st === "running") {
            this.cursor.set(node.id, i);
            return "running";
          }
          if (st === "success") {
            this.cursor.delete(node.id);
            return "success";
          }
        }
        this.cursor.delete(node.id);
        return "failure";
      }
      case "inverter": {
        const st = this.evalNode(node.children![0]!, ctx, depth + 1);
        if (st === "running") return "running";
        return st === "success" ? "failure" : "success";
      }
      case "wait": {
        const need = node.ticks!;
        // 先记"这一 tick 已消耗"，再判是否够数：于是 wait(3) 恰好需要 3 次 step，
        // wait(0) 在第一次 step 当场成功
        const done = (this.elapsed.get(node.id) ?? 0) + 1;
        if (done >= need) {
          this.elapsed.delete(node.id);
          return "success";
        }
        this.elapsed.set(node.id, done);
        return "running";
      }
      case "do":
      case "check": {
        const fn = this.ops[node.op!];
        // 构造时已校验 ⇒ 走到这里还缺，只可能是运行时换了注册表（不允许，但别崩成 undefined()）
        if (fn === undefined) return "failure";
        return fn(ctx, node);
      }
      default:
        return "failure";
    }
  }
}

/** 语法糖：把常见结构写短一点，避免判据里嵌套七层花括号。 */
export const bt = {
  sequence: (id: string, ...children: AiNode[]): AiNode => ({ id, kind: "sequence", children }),
  selector: (id: string, ...children: AiNode[]): AiNode => ({ id, kind: "selector", children }),
  inverter: (id: string, child: AiNode): AiNode => ({ id, kind: "inverter", children: [child] }),
  wait: (id: string, ticks: number): AiNode => ({ id, kind: "wait", ticks }),
  do: (id: string, op: string): AiNode => ({ id, kind: "do", op }),
  check: (id: string, op: string): AiNode => ({ id, kind: "check", op }),
};
