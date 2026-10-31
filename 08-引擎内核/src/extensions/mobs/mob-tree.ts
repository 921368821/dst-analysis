/**
 * L4 · 生物的决策树 —— 把「记仇 > 看见 > 漫游」写成**一棵数据树**
 *
 * 上一批（批153）把决策抽成 `chooseFromFacts(facts)`：签名里没有 `Scene`，于是
 * 「决策偷读世界」在类型上做不到。但那还是一段 `if`。这一段换成树，回答的是
 * 另一个问题：**「给角色配 AI」到底是改代码，还是填数据。**
 *
 * ★★ 四个决定：
 *
 * ① **黑板（`Board`）只放数字，`MobFacts` → 板的映射只做一次**（`writeFacts`）。
 *    树上的 op 看不到 `MobFacts` —— 它只读板。理由是 `Board` 本来就能存档、
 *    能进日志、能并进世界指纹（见 `ai/behavior.ts`），而 `MobFacts` 有数组与
 *    嵌套对象；树一旦能直接摸 `facts.visible[3]`，「树是纯数据」就名存实亡了。
 *
 * ② **每个键每拍都写一次**（缺的写 `-1` / `0`），不写「只在有值时写」。
 *    复用同一块板（一个 `MobBrain` 服务世界里全部生物）时，条件写法的残留值
 *    会让 B 生物继承 A 生物的仇人 —— 症状是「一群怪围着同一具尸体」。
 *    板每拍先 `clear()` 再全量写，于是「板上的键集合」是常量而不是历史。
 *
 * ③ **树必须是瞬时的（不许留 `running`）**。`AiAgent` 的记忆是**跨拍**的，
 *    而这里一只生物一拍只走一次树、且事实每拍重建 ⇒ 一旦某天有人往树里塞
 *    `wait`/`running`，决定就带上了**不在快照里的历史**：单机看不出来，回滚
 *    到 tick N 之后行为分叉。所以 `memorySize()` 暴露出来，判据钉住它恒为 0。
 *
 * ④ **树与规范（`chooseFromFacts`）互为对照，不是两份实现**。
 *    `chooseFromFacts` 是**语义规范**，树是它的编译产物；判据逐条对账两者
 *    （`mob-tree.test.ts` 第 1 条）。这条不是重复：没有对照，就分不清
 *    「树被改坏」与「规范被改坏」，而两者都只表现为「怪的行为有点怪」。
 *
 * ★ 为什么不把 op 做成通用原语（`num.gt` / `copy`）：
 *    那样树会长到二十个节点、且「记仇优先」这种语义消失在键名里。
 *    op 名是**玩法词汇**（`mob.hasGrudge`），树才读得懂 —— 这是行为树相对
 *    通用脚本的价值所在。
 */

import { AiAgent, Board, bt, type AiNode, type AiOps, type AiTick, type Status } from "../ai/behavior.ts";
import type { Decision, DecisionReason, MobFacts } from "./mob-facts.ts";

/** 树或 op 不合法（构造期抛，不等到某一拍才炸）。 */
export const MOB_BAD_TREE = "MOB.BAD_TREE";

/**
 * 黑板键。**唯一的字符串来源**：写错名字在这里是 TS 错误，
 * 而不是「静默读到 0 于是永远走不到那条分支」。
 */
export const K = {
  selfCell: "self.cell",
  aggressive: "self.aggressive",
  grudgeHas: "grudge.has",
  grudgeNode: "grudge.node",
  grudgeCell: "grudge.cell",
  visibleCount: "visible.count",
  visibleNode: "visible.0.node",
  visibleCell: "visible.0.cell",
  wanderCell: "wander.cell",
  lastVerdict: "last.verdict",
  lastTarget: "last.target",
  outKind: "out.kind",
  outTarget: "out.target",
  outCell: "out.cell",
  outReason: "out.reason",
} as const;

/**
 * 上一拍结果的三态码。**与 `LastVerdict` 一一对应**（`none` 是 0）。
 *
 * ★ 编码成数字而不是字符串：黑板只存数字（见 `mob-facts.ts` ①）。
 *   顺带让 `atLeast(ctx, K.lastVerdict, 2)` 能表达「没做成」（retry 或 fatal）。
 */
export const LAST = { none: 0, ok: 1, retry: 2, fatal: 3 } as const;

/** 输出槽的 kind 码（`0` = 这一拍没有决定）。 */
export const OUT_NONE = 0;
export const OUT_HUNT = 1;
export const OUT_WANDER = 2;

/** 输出槽的 reason 码（与 `DecisionReason` 一一对应，见 `WHY_NAME`）。 */
export const WHY = { grudge: 1, sight: 2, wander: 3 } as const;

/** 码 → 名字。顺序即码减一。 */
const WHY_NAME: readonly DecisionReason[] = ["grudge", "sight", "wander"];

/**
 * 把一份事实写进黑板（**先清空**，见文件头 ②）。
 *
 * 缺的写 `-1` / `0` 而不是跳过：板是复用的，跳过就会读到上一位的值。
 */
export function writeFacts(board: Board, f: MobFacts): Board {
  board.clear();
  board.set(K.selfCell, f.selfCell);
  board.set(K.aggressive, f.aggressive ? 1 : 0);
  board.set(K.grudgeHas, f.grudge === null ? 0 : 1);
  board.set(K.grudgeNode, f.grudge?.nodeId ?? -1);
  board.set(K.grudgeCell, f.grudge?.cell ?? -1);
  board.set(K.visibleCount, f.visible.length);
  const first = f.visible[0];
  board.set(K.visibleNode, first?.nodeId ?? -1);
  board.set(K.visibleCell, first?.cell ?? -1);
  board.set(K.wanderCell, f.wanderCell);
  board.set(K.lastVerdict, LAST[f.lastVerdict ?? "none"]);
  board.set(K.lastTarget, f.lastTarget ?? -1);
  // 输出槽也每拍归零：一棵不含漫游分支的自定义树跑完之后，不能让上一拍的
  // 「漫游」留在板上被当成本拍的决定
  board.set(K.outKind, OUT_NONE);
  board.set(K.outTarget, -1);
  board.set(K.outCell, -1);
  board.set(K.outReason, 0);
  return board;
}

/** 板上读决定（`null` = 这一拍什么都不用做）。 */
export function boardToDecision(board: Board): Decision | null {
  const kind = board.get(K.outKind);
  if (kind === OUT_HUNT) {
    return {
      kind: "hunt",
      targetNodeId: board.get(K.outTarget),
      cell: board.get(K.outCell),
      reason: WHY_NAME[board.get(K.outReason) - 1] ?? "sight",
    };
  }
  if (kind === OUT_WANDER) {
    return { kind: "wander", targetNodeId: -1, cell: board.get(K.outCell), reason: "wander" };
  }
  return null;
}

/** `board.get(key) >= min` 的短写法（四个 check 共用，见判据「读到的键必须先写」）。 */
function atLeast(ctx: AiTick, key: string, min: number): Status {
  return ctx.board.get(key) >= min ? "success" : "failure";
}

/**
 * 往输出槽写一条决定。
 *
 * `cell < 0` 一律 `failure`：目标格坏了还下令，等于让 `move` 模块沿 `-1` 走
 * （那条路上「没有目标」与「目标在第 -1 格」不可分）。
 */
function emit(ctx: AiTick, kind: number, nodeKey: string | null, cellKey: string, why: number): Status {
  const cell = ctx.board.get(cellKey);
  if (cell < 0) return "failure";
  ctx.board.set(K.outKind, kind);
  ctx.board.set(K.outTarget, nodeKey === null ? -1 : ctx.board.get(nodeKey));
  ctx.board.set(K.outCell, cell);
  ctx.board.set(K.outReason, why);
  return "success";
}

/**
 * 生物的行为 op。**名字是玩法词汇**（见文件头「为什么不把 op 做成通用原语」）。
 *
 * check 只读板；do 只写输出槽。于是「读」与「写」各自有一个固定集合，
 * 判据可以拿一块记账的板把两个集合对出来。
 */
export const MOB_OPS: AiOps = {
  "mob.canDecide": (ctx) => atLeast(ctx, K.selfCell, 0),
  "mob.isAggressive": (ctx) => atLeast(ctx, K.aggressive, 1),
  "mob.hasGrudge": (ctx) => atLeast(ctx, K.grudgeHas, 1),
  "mob.seesFoe": (ctx) => atLeast(ctx, K.visibleCount, 1),
  "mob.hasWander": (ctx) => atLeast(ctx, K.wanderCell, 0),
  "mob.huntGrudge": (ctx) => emit(ctx, OUT_HUNT, K.grudgeNode, K.grudgeCell, WHY.grudge),
  "mob.huntNearest": (ctx) => emit(ctx, OUT_HUNT, K.visibleNode, K.visibleCell, WHY.sight),
  "mob.wander": (ctx) => emit(ctx, OUT_WANDER, null, K.wanderCell, WHY.wander),
  // 上一拍那个动作**没做成**（retry 或 fatal）。默认树不挂它 —— 挂上去就等于
  // "打不到就换目标"，那是玩法决定，不该由这一批替策划做（见 mob-brain ⑦）。
  "mob.lastFailed": (ctx) => atLeast(ctx, K.lastVerdict, LAST.retry),
};

/**
 * 默认树：**记仇 > 看见 > 漫游**。
 *
 * ```
 * sequence 根
 *   check   能找到自己（selfCell >= 0）—— 否则整棵树失败 ⇒ 没有决定
 *   selector 主体
 *     sequence 敌对          ← 只有「有攻击组件」的生物才追（文件头见 mob-brain ①）
 *       check 凶不凶
 *       selector 挑目标
 *         sequence 记仇 → check 有仇人 → do 追仇人
 *         sequence 看见 → check 看得见 → do 追最近的
 *     sequence 漫游
 *       check 有漫游格（-1 = 孤岛 / 界外）
 *       do 漫游
 * ```
 *
 * `sequence` 当「与」、`selector` 当「或」、`check` 当条件、`do` 当动作 ——
 * 四个 kind 全用到，没有为这棵树新增任何原语。
 */
export const MOB_TREE: AiNode = bt.sequence(
  "mob.root",
  bt.check("mob.sane", "mob.canDecide"),
  bt.selector(
    "mob.body",
    bt.sequence(
      "mob.hostile",
      bt.check("mob.angry", "mob.isAggressive"),
      bt.selector(
        "mob.pick",
        bt.sequence("mob.grudge", bt.check("mob.c1", "mob.hasGrudge"), bt.do("mob.d1", "mob.huntGrudge")),
        bt.sequence("mob.sight", bt.check("mob.c2", "mob.seesFoe"), bt.do("mob.d2", "mob.huntNearest")),
      ),
    ),
    bt.sequence("mob.roam", bt.check("mob.c3", "mob.hasWander"), bt.do("mob.d3", "mob.wander")),
  ),
);

export interface MobTreeOptions {
  /** 换一棵树（这就是「给角色配 AI」的入口）。缺省 `MOB_TREE`。 */
  readonly tree?: AiNode;
  /** 自有 op 表（写了新 op 的树要一起给）。缺省 `MOB_OPS`。 */
  readonly ops?: AiOps;
}

export interface MobTree {
  readonly tree: AiNode;
  /** 事实 → 决定。**纯的**：同 facts 同结果，且不留跨拍记忆（见文件头 ③）。 */
  decide(facts: MobFacts): Decision | null;
  /** 树上还记着几处 `running`。正常恒为 0；非 0 说明树不再是瞬时的。 */
  memorySize(): number;
  /** 黑板快照（升序键）。面板要显示「它这一拍照什么做的决定」，判据用它看板有没有残留。 */
  boardSnapshot(): Record<string, number>;
}

/**
 * 建一棵可执行的生物树。
 *
 * 坏树（未知 op、重复 id、`wait` 缺 ticks、数据里藏环）**在这里就抛**：
 * 那是配置错误，不该等到第 500 拍某只怪走到那条分支才炸。
 */
export function createMobTree(options: MobTreeOptions = {}): MobTree {
  const tree = options.tree ?? MOB_TREE;
  const created = AiAgent.create(tree, options.ops ?? MOB_OPS);
  if (!created.ok) {
    throw new RangeError(`${MOB_BAD_TREE}: ${created.error.code} —— ${created.error.message}`);
  }
  const agent = created.value;
  const board = new Board();
  return {
    tree,
    decide(facts: MobFacts): Decision | null {
      writeFacts(board, facts);
      agent.step({ tick: facts.tick, board });
      return boardToDecision(board);
    },
    memorySize: (): number => agent.memorySize(),
    boardSnapshot: (): Record<string, number> => board.snapshot(),
  };
}
