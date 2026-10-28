/**
 * L4 · 渲染 · 动画状态机（事件 → 状态，确定性转移）
 *
 * `animation.ts` 回答「这段动画播到第几帧」，`sprite-animator.ts` 回答「这个实体
 * 播到第几毫秒」。这一层回答**第三个问题：现在该播哪一段**。
 *
 * ★★ 为什么必须与「播到哪」分开（不是拆得过细）：
 *   合成一层会让「换状态」和「seek」互相污染 —— 换状态要重置时钟、seek 不能重置，
 *   而两者都会改「当前 clip」。一旦它们写在同一个函数里，「切到走路」就会
 *   在没有任何人说「从头播」的情况下把时间清零；反过来，「播完停在末帧」
 *   与「切到待机」也会变成同一条路径，于是"只播一次就停下"的死亡动画会自己切走。
 *   分成「决策（该播哪段）」与「推进（这段播到哪）」之后，两条路径各自可判。
 *
 * ★ 状态名与 clip id **分开**（`states[state] = clipId`），不让状态直接等于 clip：
 *   待机与走路可能共用同一段素材（速度不同、或只是同一个 4 帧循环），
 *   而「状态」还要承载别的语义（朝向、是否可被打断）。把两者合并会逼出
 *   `walk_fast` / `walk_slow` 这种把参数写进名字的命名，最后必然出现
 *   `walk_fast_left`。这里只规定映射，速度与朝向留给组件字段。
 *
 * ★ 转移表用**数组**而不是 `Record<from, Record<event, to>>`：
 *   对象字面量里同一个 (from, event) 写两遍会**静默覆盖**（后者赢），
 *   而"同一状态同一事件有两条转移"是数据错误，不是编辑意图 —— 必须报错。
 *   数组是唯一能看见重复的形状，所以构造期能把它检出来（`ANIM_STATE.DUPLICATE`）。
 *
 * ★ 本文件不做 blend tree / 混合树：
 *   混合需要「多个状态同时活跃 + 权重插值」，那是另一套数据模型（权重、同步组、
 *   过渡时长），与「确定性转移」不是同一种东西。先只做能判定的那一半 ——
 *   与批117 多轨混合同一条纪律：没有消费者之前定 API 只会得到一套猜出来的东西。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

export const ANIM_STATE_ERR = {
  /** 一个状态都没有：状态机无从谈起（不是"默认状态"能糊过去的情形）。 */
  EMPTY: "ANIM_STATE.EMPTY",
  /** 初始状态不在状态表里。 */
  BAD_INITIAL: "ANIM_STATE.BAD_INITIAL",
  /** 转移的 from / to 不在状态表里（转移永远走不到，或走到一个没有 clip 的状态）。 */
  BAD_TARGET: "ANIM_STATE.BAD_TARGET",
  /** 同一个 (from, event) 出现两条 —— 数组里写得出来，对象字面量会静默覆盖。 */
  DUPLICATE: "ANIM_STATE.DUPLICATE",
  /** 事件名为空串：会让"没有事件"与"某个事件"混同。 */
  BAD_EVENT: "ANIM_STATE.BAD_EVENT",
} as const;

/** 一条转移：在 `from` 状态收到 `event` 就进入 `to`。 */
export interface StateTransition {
  readonly from: string;
  readonly event: string;
  readonly to: string;
}

export interface AnimStateMachineInput {
  /** 稳定 id（存档/诊断引用它）。 */
  readonly id: string;
  /** 状态名 → 该状态播放的 clip id（`AnimationClip.id`，不是对象引用）。 */
  readonly states: Readonly<Record<string, string>>;
  /** 初始状态（进入状态机时所在的状态，必须在 `states` 里）。 */
  readonly initial: string;
  /** 转移表。允许为空（单状态机：只有 idle，任何事件都不改变它）。 */
  readonly transitions?: readonly StateTransition[];
}

/** 不可变的状态机（纯数据，可被任意多实体共享）。 */
export interface AnimStateMachine {
  readonly id: string;
  readonly states: Readonly<Record<string, string>>;
  readonly initial: string;
  readonly transitions: readonly StateTransition[];
}

/**
 * 一次转移的结果。
 *
 * ★ 三个布尔量各自回答一件事，**不能合并**：
 *   · `consumed` —— 这个事件在当前状态下有声明（宿主据此判断"事件被吃掉了没有"，
 *     没吃掉的话可能要冒泡给上层，或者记一条「这个状态没接这个事件」的诊断）；
 *   · `changed` —— 状态名变了（宿主据此决定**要不要换 clip**）；
 *   · `restart` —— 发生了转移，动画该**从头播**。
 *   合并 `changed` 与 `restart` 会让"自转移"（`walk → walk`，跑步键连按要重播起跑）
 *   要么被当成"没变、不用管"，要么被当成"状态变了、换 clip" —— 两种都不对。
 */
export interface StateStep {
  readonly state: string;
  readonly clip: string;
  readonly consumed: boolean;
  readonly changed: boolean;
  readonly restart: boolean;
}

/**
 * 校验并构造状态机。
 *
 * 校验顺序有意义：先 EMPTY 再 BAD_INITIAL —— 空表时 initial 必然"不在表里"，
 * 先报后者会让"你忘了写 states"变成"你的 initial 写错了"，把人支到错的地方。
 */
export function makeStateMachine(input: AnimStateMachineInput): Result<AnimStateMachine, EngineError> {
  const names = Object.keys(input.states);
  if (names.length === 0) {
    return err(engineError(ANIM_STATE_ERR.EMPTY, "状态机没有任何状态", { id: input.id }));
  }
  if (!Object.hasOwn(input.states, input.initial)) {
    return err(
      engineError(
        ANIM_STATE_ERR.BAD_INITIAL,
        `初始状态 ${JSON.stringify(input.initial)} 不在状态表里（有：${names.join(", ")}）`,
        { id: input.id, initial: input.initial },
      ),
    );
  }

  const transitions = input.transitions ?? [];
  const seen = new Set<string>();
  for (const t of transitions) {
    if (t.event.length === 0) {
      return err(
        engineError(ANIM_STATE_ERR.BAD_EVENT, `转移 ${t.from} → ${t.to} 的事件名是空串`, {
          id: input.id,
          from: t.from,
        }),
      );
    }
    if (!Object.hasOwn(input.states, t.from)) {
      return err(
        engineError(ANIM_STATE_ERR.BAD_TARGET, `转移的起点 ${JSON.stringify(t.from)} 不是已声明状态`, {
          id: input.id,
          from: t.from,
        }),
      );
    }
    if (!Object.hasOwn(input.states, t.to)) {
      return err(
        engineError(ANIM_STATE_ERR.BAD_TARGET, `转移的目标 ${JSON.stringify(t.to)} 不是已声明状态`, {
          id: input.id,
          to: t.to,
        }),
      );
    }
    // ★ 用 NUL 分隔而不是 `:` 或 `-`：状态名与事件名都可能含分隔符，
    //   拼串撞车会让两条不同的转移被当成同一条（漏报重复）。
    const key = `${t.from}\u0000${t.event}`;
    if (seen.has(key)) {
      return err(
        engineError(
          ANIM_STATE_ERR.DUPLICATE,
          `同一状态 ${JSON.stringify(t.from)} 上的事件 ${JSON.stringify(t.event)} 有两条转移`,
          { id: input.id, from: t.from, event: t.event },
        ),
      );
    }
    seen.add(key);
  }

  // 冻结：状态机与 clip 一样会被多个实体共享，运行时一次改写就会同时改掉所有实体。
  const states: Record<string, string> = Object.freeze({ ...input.states });
  return ok(
    Object.freeze({
      id: input.id,
      states,
      initial: input.initial,
      transitions: Object.freeze(transitions.map((t) => Object.freeze({ from: t.from, event: t.event, to: t.to }))),
    }),
  );
}

/** 这个状态是否存在（存档里的状态名可能来自旧版本，调用方要先问一句）。 */
export function hasState(machine: AnimStateMachine, state: string): boolean {
  return Object.hasOwn(machine.states, state);
}

/**
 * 状态对应的 clip id。
 *
 * ★ 未知状态**抛**而不是返回空串：空串会让 `SpriteAnimator.clipId = ""`
 *   变成"找不到 clip"，然后症状是"这个怪不动了"—— 根因（状态名写错/存档过期）
 *   被下游那条 warning 盖掉。与 `sampleClip` 对非有限时间抛是同一条口径：
 *   不变量被破坏就当场说清。
 */
export function stateClip(machine: AnimStateMachine, state: string): string {
  if (!Object.hasOwn(machine.states, state)) {
    throw new TypeError(`状态 ${JSON.stringify(state)} 不在状态机 ${JSON.stringify(machine.id)} 里`);
  }
  return machine.states[state]!;
}

/** 进入状态机的第一步（拿到初始状态与该播的 clip）。 */
export function initialState(machine: AnimStateMachine): StateStep {
  return {
    state: machine.initial,
    clip: stateClip(machine, machine.initial),
    consumed: false,
    changed: true,
    restart: true,
  };
}

/**
 * 投一个事件：返回新状态与该播的 clip。
 *
 * ★ **未声明的事件不改变状态**，`consumed = false`。这是这一层最要紧的一条：
 *   把"没接这个事件"处理成"回到 initial"是最省事的写法，也是最有破坏性的 ——
 *   跑步时收到一个未绑定的 `ui.pause`，"切回待机"看起来无害，实际把玩家的
 *   移动动画打断在一次按键上，而且没有任何地方会报错。
 *
 * ★ 查找是线性的：转移表通常 < 20 条，且只在**事件到达时**调用一次（不在每帧热路径）。
 *   为它建 Map 只会引入一份需要与数组同步的第二真相。
 */
export function stepState(machine: AnimStateMachine, current: string, event: string): StateStep {
  // 先确认当前状态有效：未知状态下的"查找不到转移"与"这个状态没接这个事件"
  // 是两种完全不同的错，混在一起就再也分不开了。
  const currentClip = stateClip(machine, current);
  for (const t of machine.transitions) {
    if (t.from !== current || t.event !== event) continue;
    return {
      state: t.to,
      clip: stateClip(machine, t.to),
      consumed: true,
      changed: t.to !== current,
      restart: true,
    };
  }
  return { state: current, clip: currentClip, consumed: false, changed: false, restart: false };
}
