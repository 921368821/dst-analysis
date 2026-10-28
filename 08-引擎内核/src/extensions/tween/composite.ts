/**
 * L4 · 多轨合成：同一 (目标, 属性) 上的多条轨道 → 一个值（C9 的最后一个缺口）
 *
 * 批76 接线时只有一条轨道写一个属性，于是"同一属性被两条轨道写"这件事
 * 在 `advancePlayer` 里被处理成**一条确定的顺序**（后写者胜），并留下了一句
 * "这不是混合解析器"。现在第二个写者出现了（"受伤压暗"要乘不透明度、
 * "弹一下"要在基础缩放上叠偏移），后写者胜就不再是"确定的顺序"，而是
 * **静默丢掉一条正确的轨道** —— 两条轨道各自的采样都对，合成结果是错的。
 *
 * ★★ 调研了什么（业界三种做法）
 *   ① CSS `animation-composition`（含 Web Animations 的 `composite`）：
 *      三个值 `replace | add | accumulate`。
 *        · `replace`（缺省）= 效果值**覆盖**底层值；
 *        · `add` = 底层值**后面接**效果值 —— 对列表型值（`transform`/`filter`）
 *          是拼接（`blur(5px)` + `blur(10px)` ⇒ 两串），对标量是相加；
 *        · `accumulate` = 累积 —— 对标量也是相加，只有列表型值才与 `add` 分开
 *          （`blur(15px)`）。
 *      多个动画写同一属性时，按 `animation-name` 里的**声明顺序**依次合成，
 *      后一条作用在前一条**已合成的结果**上；底层值来自动画之下的级联。
 *   ② Unity Animator 的动画层：`Blending = Override | Additive`。
 *      Additive 层要求"相对参考姿势的增量"，同一属性的多条曲线**相加**。
 *   ③ 图形合成（`multiply` 混合模式、变换矩阵相乘）：相对量天然是**乘**。
 *
 * ★★ 借了什么、改了什么
 *   · 算子挂在**轨道**上（CSS 是 per-animation，Unity 是 per-layer）——
 *     两处都说明"合成语义属于参与者，不属于属性"。我们也挂在轨道上，
 *     于是"两条轨道 + 第三个观察者"这种情形不需要引入"层/组"这个中间概念：
 *     **轨道顺序就是层序**。
 *   · 合成顺序 = 声明顺序（`player.tracks` 全在前、`player.keyTracks` 全在后，
 *     各自按添加顺序），后一条基于前一条的已合成结果 —— 与 CSS 同构。
 *   · **每一帧从头 fold，不跨帧累积**：`add` 若被实现成"在上一帧的值上加"
 *     就成了积分器，一个静止的 `add` 轨道会以每秒 60 次的速度把不透明度推到天上。
 *     这条有判据钉着（同一时刻连推两次 `dt=0`，值必须一模一样）。
 *   · **不提供 `accumulate`**：本项目所有可补间属性都是标量，标量域里
 *     `add` 与 `accumulate` 恒等（差别只存在于列表型值）。多一个名字不会多一种
 *     能力，只会让人以为两者有区别，然后在需要"两个都写对"的地方挑错一个。
 *   · **多提供 `multiply`**（CSS 没有）：`opacity` 与 `scale` 是**相对量** ——
 *     两个系统各自"减半"时正确的合成是 0.5×0.5，而加法给出 0（再叠一条就是 0，
 *     屏幕上直接黑掉）。这与图形合成里 `multiply` 混合模式、
 *     变换矩阵相乘是同一条直觉。
 *
 * ★★ 第一条的算子为什么"不起作用"
 *   没有第二条可参考时，`add` 的基底取加法恒等元 0（`0 + v = v`），
 *   `multiply` 取 1（`1 * v = v`），`replace` 直接就是 v —— 三者结果相同。
 *   这不是巧合而是**必须**：本层的轨道是"绝对值的来源"，不存在 CSS 那样
 *   动画之下的底层值。让"第一条写 add"去乘 0 会把整条属性锁死在 0，
 *   而症状是"这条轨道加了没反应" —— 与"算子拼错"完全无法区分。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

export const COMPOSITE_ERR = {
  /** 算子名不认识（拼错 `"multipy"` 会静默变成覆盖，见 `resolveComposite`）。 */
  BAD_OP: "TWEEN.BAD_COMPOSITE",
} as const;

/** 合成算子（字符串常量表，与 `UI_TWEEN_PROP` 同一形态：可读、可校验、可日志）。 */
export const COMPOSITE_OP = {
  /** 覆盖（缺省）：后一条直接取代前一条的合成结果。 */
  Replace: "replace",
  /** 相加：前一条的合成结果 + 本条的值。适合"偏移"类属性（offsetX/offsetY）。 */
  Add: "add",
  /** 相乘：前一条的合成结果 × 本条的值。适合"相对量"（opacity/scale）。 */
  Multiply: "multiply",
} as const;

export type CompositeOp = (typeof COMPOSITE_OP)[keyof typeof COMPOSITE_OP];

const KNOWN_OPS: ReadonlySet<string> = new Set(Object.values(COMPOSITE_OP));

/** 算子名是否合法（配置期自检用：配置文件里的算子名拼错不该静默变成覆盖）。 */
export function isCompositeOp(op: string): op is CompositeOp {
  return KNOWN_OPS.has(op);
}

/**
 * 校验一个来自配置的算子，缺省 `replace`。
 *
 * ★ 为什么在构造期报错而不是"不认识就当 replace"：拼成 `"multipy"` 的那条轨道
 *   会静默覆盖掉前一条 —— 症状是"两条轨道里有一条没生效"，而它看起来与
 *   "算子语义理解错"一模一样，只能靠翻配置文件里那个字母找。
 */
export function resolveComposite(op: string | undefined, id: string): Result<CompositeOp, EngineError> {
  if (op === undefined) return ok(COMPOSITE_OP.Replace);
  if (!isCompositeOp(op)) {
    return err(
      engineError(COMPOSITE_ERR.BAD_OP, `轨道 ${id} 的合成算子不认识：${op}（可用：replace / add / multiply）`, {
        id,
        op,
      }),
    );
  }
  return ok(op);
}

/** 一条待合成的条目（`advancePlayer` 采出、尚未分组的原始值）。 */
export interface CompositeEntry {
  /** 轨道 id（合成后保留**最后一条**写这个属性的那条，见 `composeEntries`）。 */
  readonly id: string;
  readonly targetId: string;
  readonly prop: string;
  readonly op: CompositeOp;
  readonly value: number;
  /** 这条轨道自己是否已经播完。 */
  readonly done: boolean;
}

/** 合成结果：每个 (targetId, prop) **一条**。 */
export interface ComposedEntry {
  /** 最后一条写这个属性的轨道 id（"这个值是谁给的"要能查）。 */
  readonly id: string;
  readonly targetId: string;
  readonly prop: string;
  /** 合成值。 */
  readonly value: number;
  /** 参与合成的所有轨道都播完了（任一未完成 ⇒ false）。 */
  readonly done: boolean;
}

/**
 * 把一条算子的效果作用到已合成的基底上。
 *
 * ★ 抽成独立函数只为一件事：让"乘写成加"这种错**只有一处**可能发生，
 *   并且那处能被判据直接钉住（它没有 I/O、没有状态，纯得像算术）。
 */
export function composeValue(op: CompositeOp, base: number, value: number): number {
  if (op === COMPOSITE_OP.Add) return base + value;
  if (op === COMPOSITE_OP.Multiply) return base * value;
  // replace：基底被丢掉。
  return value;
}

/**
 * 按输入顺序 fold：同一 (targetId, prop) 的多条合成一条。
 *
 * 三条规则（每一条都有判据）：
 *   ① 分组键是 **(targetId, prop) 二元组**，不是 prop：两个面板各自的 `opacity`
 *      互不相干，用 prop 当键会让"打开背包时 HUD 也变成半透明"。
 *   ② 输出顺序 = 该组**首次出现**的位置（`Map` 的插入序），值 = 最后一次 fold 的结果；
 *      合成顺序本身则严格按输入顺序（后一条基于前一条的已合成结果）。
 *   ③ 第一条的算子不影响结果（恒等元），见文件头 ★★。
 *
 * ★ 为什么要返回新数组而不是就地改：`entries` 由调用方持有，就地改会让
 *   "推进"这一步带上看不见的副作用，而这条链上已经有两个消费者（UI 写入、
 *   判据/诊断），谁都可能先读到。
 */
export function composeEntries(entries: readonly CompositeEntry[]): ComposedEntry[] {
  const out: ComposedEntry[] = [];
  // targetId → prop → out 里的下标。两级 Map 而不是 `targetId + "\0" + prop`：
  // 拼接键要求"id 里不会有分隔符"这个没人保证过的前提。
  const at = new Map<string, Map<string, number>>();
  for (const e of entries) {
    let byProp = at.get(e.targetId);
    if (byProp === undefined) {
      byProp = new Map<string, number>();
      at.set(e.targetId, byProp);
    }
    const idx = byProp.get(e.prop);
    if (idx === undefined) {
      byProp.set(e.prop, out.length);
      out.push({ id: e.id, targetId: e.targetId, prop: e.prop, value: e.value, done: e.done });
      continue;
    }
    const prev = out[idx] as ComposedEntry;
    out[idx] = {
      // ★ id 取**后一条**：`id` 回答的是"这个最终值是谁给的"，
      //   而覆盖/叠加之后，屏幕上看到的是最后那条参与者的功劳（也是出问题时要找的那条）。
      id: e.id,
      targetId: e.targetId,
      prop: e.prop,
      value: composeValue(e.op, prev.value, e.value),
      // ★ 全部完成才算完成：`add` 链里前一条还在动，这个属性的值就还在变。
      done: prev.done && e.done,
    };
  }
  return out;
}
