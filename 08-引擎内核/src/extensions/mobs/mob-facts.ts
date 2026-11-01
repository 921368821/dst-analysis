/**
 * L4 · 生物的黑板（**这一 tick 的世界事实**，纯数据）
 *
 * 感知层与决策层的分界线就画在这个文件的类型上：`MobFacts` 是感知的**全部产出**，
 * `chooseFromFacts` 是决策的**全部输入**。决策函数签名里没有 `Scene`，
 * 所以「决策偷读世界」这件事在类型上就做不到 —— 不是靠约定、也不是靠自查。
 *
 * ★★ 四个决定：
 *
 * ① **黑板是纯数据，不是「活的引用」**：只放数字与字符串，不放节点、不放组件、
 *    不放闭包。于是它可以 `JSON.stringify` 进日志、进快照、进回放、进调试面板，
 *    也可以由判据**手写**一份来测边界（不必搭一个场景才能测「正好 4 格」）。
 *
 * ② **`visible` 在感知阶段就过滤完**（友军 / 超 leash / 不在地图上），
 *    不留给决策去筛。理由：过滤条件属于「我这只生物看得见什么、够得着什么」，
 *    那是感知的语义；留在决策里会让「同一份黑板喂给玩家控制的角色」时行为不同。
 *
 * ③ **`wanderCell` 在事实里预先算好**，虽然它是 `(seed, id, epoch)` 的纯函数。
 *    因为决策必须是纯的 —— 让它自己算就等于把 `grid` 塞进决策的输入，
 *    而 `grid` 是可变结构（`blockCells` 会改），那就不是纯数据了。
 *
 * ④ **`reason` 是给人和机器各看一半的**：人看 HUD（「它在追你，因为记你的仇」），
 *    机器看判据（三条分支各一条断言）。只有 `kind` 时，「看见才追」与「记仇才追」
 *    在终态上完全一样 —— 而这两件事的修法完全不同。
 *
 * ⑤ **新增的两组事实（批166）一律可选，缺省 = 老世界的行为逐字节不变**。
 *    「我饿了」「附近有可拾的东西 / 包里有能吃的东西」这两组只有挂了背包/饱食的
 *    生物才有值；没挂的生物读到 `undefined`，于是 `chooseFromFacts` 走的还是
 *    「记仇 > 看见 > 漫游」—— 猎狗仍然没有背包，`mob-world.ts` ② 那条语义不受影响。
 *    ★ 必填字段会逼着每一处手写夹具都补一遍，而**漏补的那一处不报错**，
 *      只是那组事实永远为假（`lastVerdict` 在批158 已经踩过一次）。
 */

/** 为什么这么决定（给 HUD 与判据各看一半，见文件头 ④）。 */
export type DecisionReason = "grudge" | "sight" | "wander" | "forage" | "eat";

/**
 * 决定的种类。`hunt` = 追/打；`wander` = 漫游；`forage` = 去捡地上的东西；
 * `eat` = 原地吃掉背包里的一个（批166）。
 *
 * ★ `forage` 与 `eat` 是**动作**，不是移动：`cell` 对 `eat` 是"自己站的格"
 *   （于是 `move` 模块拿到的是一个到得了的目标，不会带它走开）。
 */
export type DecisionKind = "hunt" | "wander" | "forage" | "eat";

/**
 * 上一拍动作的结果（批158）。
 *
 * `"none"` = 上一拍没做过动作，**或者**两个 tick 之间断过（读档、回滚、跳拍）——
 * 后一种是刻意的：陈旧结果比没有结果更坏，它会让树对着一个早就变了的局面做决定。
 */
export type LastVerdict = "none" | "ok" | "retry" | "fatal";

export interface Decision {
  /** 见 `DecisionKind`。 */
  readonly kind: DecisionKind;
  /** 要打 / 要追 / 要捡的节点；`wander` 与 `eat` 时是 `-1`。 */
  readonly targetNodeId: number;
  /** 移动目标格（`move` 模块直接用这个）。`eat` 时 = 自己站的格。 */
  readonly cell: number;
  /** 这一条决定来自哪条分支（记仇 / 看见 / 漫游 / 捡 / 吃）。 */
  readonly reason: DecisionReason;
  /**
   * `eat` 要吃哪一种（`foodKind` 原样带过来）。
   *
   * ★ 为什么它必须在决定里而不是留给执行者去猜：包里可能同时有草和熟肉，
   *   「吃哪个」是决策，不是执行细节。让执行者自己挑的话，同一份事实会喂出
   *   两种行为，而"它刚才为什么吃了熟肉"在日志里查不到。
   */
  readonly item?: string;
}

/** 网格的最小接口（世界里的 `NavGrid` 与判据里的假网格都满足它）。 */
export interface MobGrid {
  cellAt(x: number, z: number): number;
  cellX(index: number): number;
  cellZ(index: number): number;
  isWalkable(cx: number, cz: number): boolean;
}

/** 一个「看得见、够得着、不是友军」的候选。 */
export interface MobCandidate {
  readonly nodeId: number;
  /** 它所在的格下标（已确认 >= 0）。 */
  readonly cell: number;
  /** 距离**平方**（不开方：跨平台 `sqrt` 允许 1 ulp 差异，会改变「谁更近」）。 */
  readonly dist2: number;
}

/** 记仇的目标（来自仇恨表，已过滤死 / 友军 / 超距）。 */
export interface MobGrudge {
  readonly nodeId: number;
  readonly cell: number;
}

/**
 * 一只生物这一 tick 的世界事实。
 *
 * 字段全是 `readonly` 的基元或基元数组 —— 这是「可以安全地当作快照」的定义。
 */
export interface MobFacts {
  readonly agentId: number;
  readonly tick: number;
  /** 自己站第几格；`-1` = 找不到自己 / 不在地图上（此时决策必然是 `null`）。 */
  readonly selfCell: number;
  /** 有没有攻击组件（见 `mob-brain.ts` ①：没有 = 和平生物，只漫游）。 */
  readonly aggressive: boolean;
  /** 记仇的目标；`null` = 没人打过我 / 都忘了 / 够不着。 */
  readonly grudge: MobGrudge | null;
  /** 看得见的候选，已按 `(dist2, nodeId)` 升序。 */
  readonly visible: readonly MobCandidate[];
  /** 这一 epoch 的漫游目标格；`-1` = 没有可走的（孤岛 / 站在界外）。 */
  readonly wanderCell: number;
  /**
   * 上一拍那个动作的判定（见 `LastVerdict`）。
   *
   * ★ 可选：`MobFacts` 有手写夹具（判据直接造一份来测边界），必填字段会让每一处
   *   都补一遍 —— 而漏补的那一处不报错，只是读不到值。所以缺省是 `"none"`，
   *   由 `writeFacts` 兜底；同时有一条判据断言 `sense()` 产出的**一定带**这个字段。
   */
  readonly lastVerdict?: LastVerdict;
  /** 上一拍那个动作打的是谁；`-1` = 无。 */
  readonly lastTarget?: number;
  /**
   * 饿不饿（见文件头 ⑤）。`undefined` = 这只生物没有饱食组件（老世界）。
   *
   * ★ 阈值在**感知层**求值，不放进树：树是纯数据、op 不带参数，
   *   把「低于百分之几算饿」编进树里就再也改不动了。
   */
  readonly hungry?: boolean;
  /** 当前饱食百分比（0..100 的整数，面板显示用；`undefined` = 没有饱食组件）。 */
  readonly hungerPct?: number;
  /** 包里最该吃的那一种（`undefined` = 没吃的 / 不饿 / 没有背包）。 */
  readonly foodKind?: string;
  /** 最近一个够得着、走得过去的可拾格；`-1` / `undefined` = 没有。 */
  readonly forageCell?: number;
  /** 那一格上的资源节点 id（日志与"捡到了什么"用；`-1` = 没有）。 */
  readonly forageNode?: number;
}

/** 漫游参数（纯函数需要的全部外部量）。 */
export interface MobWander {
  readonly seed: number;
  readonly radiusCells: number;
  /** 多少 tick 换一次目标。 */
  readonly every: number;
}

/** 32 位混合：同 `(seed,id,epoch)` 必得同值，且相邻 epoch 不呈线性（否则生物会走直线）。 */
export function mix32(a: number, b: number, c: number): number {
  let h = (a ^ 0x9e3779b9) >>> 0;
  h = (Math.imul(h ^ (b + 0x85ebca6b), 0xcc9e2d51) >>> 0) ^ (h >>> 13);
  h = (Math.imul(h ^ (c + 0xc2b2ae35), 0x1b873593) >>> 0) ^ (h >>> 15);
  return h >>> 0;
}

/**
 * 漫游目标格（`(seed, id, epoch)` 的纯函数，见 `mob-brain.ts` ②）。
 *
 * 取**第一个可走**的候选而不是「最近的 / 最远的」：后者会让同 epoch 的所有生物
 * 挤向同一片空地（候选序是同一个函数），画面上像一队人。
 */
export function wanderTarget(grid: MobGrid, selfCell: number, agentId: number, tick: number, w: MobWander): number {
  if (selfCell < 0) return -1;
  const cx = grid.cellX(selfCell);
  const cz = grid.cellZ(selfCell);
  const r = w.radiusCells;
  const epoch = Math.floor(tick / w.every);
  let h = mix32(w.seed, agentId, epoch);
  // 6 次尝试：半径 4 的方框里 81 格总有可走的，除非它站在孤岛上
  for (let k = 0; k < 6; k++) {
    h = (Math.imul(h, 1664525) + 1013904223) >>> 0;
    const span = 2 * r + 1;
    const dx = (h % span) - r;
    const dz = (Math.floor(h / span) % span) - r;
    if (dx === 0 && dz === 0) continue;
    if (grid.isWalkable(cx + dx, cz + dz)) {
      // 格心坐标 → 下标（避开再引入一个 `indexOf` 依赖）
      return grid.cellAt(cx + dx + 0.5, cz + dz + 0.5);
    }
  }
  return -1;
}

/**
 * 决策（**唯一的输入是黑板**）。
 *
 * 优先级：记仇 > 看见 > 漫游。顺序不是风格问题：
 *  - 记仇在**看不见**时也必须生效（打了就跑的人仍然被追）；
 *  - 反过来（先看再记仇）的话，记仇只在「恰好还看得见」时有效，等于没有记忆。
 *
 * `selfCell < 0` 直接 `null`：找不到自己的生物不该沿着上一格继续走
 * （那正是「尸体还在走」这类 bug 的形状）。
 */
export function chooseFromFacts(f: MobFacts): Decision | null {
  if (f.selfCell < 0) return null;
  // ---- ① 吃（批166）：饿了 + 包里有能吃的 ⇒ 原地吃。**排在追人之前**：
  //      饿着会掉血（`survival-module`），那是会致死的一档状态，比"再追一格"更急。
  //      而它只在两个条件同时成立时才触发，所以不会把追击反复打断成"边打边啃"。
  if (f.hungry === true) {
    const food = f.foodKind;
    if (food !== undefined && food !== "") {
      return { kind: "eat", targetNodeId: -1, cell: f.selfCell, reason: "eat", item: food };
    }
  }
  if (f.aggressive) {
    if (f.grudge !== null) {
      return { kind: "hunt", targetNodeId: f.grudge.nodeId, cell: f.grudge.cell, reason: "grudge" };
    }
    const first = f.visible[0];
    if (first !== undefined) {
      return { kind: "hunt", targetNodeId: first.nodeId, cell: first.cell, reason: "sight" };
    }
  }
  // ---- ② 捡（批166）：没事干才去捡。排在追击之后 —— 拾荒者不打架，
  //      而会打架的生物"放着眼前的敌人不管去捡草"是明显的坏手感。
  const forage = f.forageCell ?? -1;
  if (forage >= 0) {
    return { kind: "forage", targetNodeId: f.forageNode ?? -1, cell: forage, reason: "forage" };
  }
  if (f.wanderCell < 0) return null;
  return { kind: "wander", targetNodeId: -1, cell: f.wanderCell, reason: "wander" };
}
