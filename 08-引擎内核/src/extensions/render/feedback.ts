/**
 * L4 · 受击反馈：「打中了」这件事要看得见
 *
 * 批68 之前，战斗是**纯数字**的：血从 100 掉到 92，日志里有一行，画面上什么都没发生。
 * 这个文件把"打中了"变成两个**能被判据读到的**视觉状态：
 *
 *   · **闪色**（`flash`）—— 被打的精灵乘上一层红，N tick 后还原；
 *   · **挤压**（`punch`）—— 挥击的精灵横向拉宽、纵向压扁，N tick 后还原。
 *
 * ★★ 五个刻意的决定：
 *
 * ① **记原色，而不是"到期设回白色"**。
 *    到期把 `r/g/b` 写回 1,1,1 是最省事的写法 —— 而它会**洗白**任何不是白色的精灵
 *    （尸体变灰、幽灵半透明、群系着色的地形）。更糟的是它**看不出来**：
 *    演示页里所有东西本来就接近白色，所以"还原"和"洗白"在同一张截图上一样。
 *    判据必须用**非白色基色**的精灵，否则这两种实现分不出来（见 `feedback.test.ts` ①）。
 *
 * ② **基色只在"从静止开始闪"的那一次抓**。
 *    如果每次 `flash` 都抓一次，第二次抓到的是**闪色**：闪完还原成闪色，再闪再抓，
 *    颜色会一路漂到红。症状是"被打过几次的怪一直泛红"，而所有断言都是绿的
 *    （因为每次"闪了"和"还原了"都成立）。判据必须验"连挨三下后颜色**精确**回原值"。
 *
 * ③ **重复触发取"最长的剩余"而不是累加**。
 *    累加会让连击时闪烁越来越久（20 下之后闪 20 倍时长），
 *    而"闪多久结束"变成取决于历史的东西 —— 回放/存档都对不上。
 *
 * ④ **状态挂在被闪的节点自己身上，不新建节点**。
 *    给每次受击造一个"闪光实体"会让节点数随战斗次数增长，
 *    而节点数被拾取、存档、统计、AI 索敌全部依赖。
 *
 * ⑤ **还原是幂等的**（`restoreTint` 在没闪的时候什么都不做）。
 *    模块每 tick 到点还原一次，宿主也可能手动 `clear()` 一次 ——
 *    非幂等的还原会在"玩家自己在闪完之后把精灵改成别的颜色"时把它改回去。
 *
 * ★ 单位是 **tick**，不是毫秒：与 `cooldownTicks` / `decayEveryTicks` 同口径。
 *   按毫秒的话，掉帧时闪烁时长不变但可见帧数变少，"闪几下"取决于帧率。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { Services } from "../../core/tokens.ts";
import { SPRITE_TYPE, type Sprite } from "./sprite.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 受击反馈组件类型。 */
export const FEEDBACK_TYPE = "render.feedback";

/** 节点不存在。 */
export const FX_NO_NODE = "FX.NO_NODE";
/** 节点身上没有 `render.sprite`（闪一个看不见的东西没有意义）。 */
export const FX_NO_SPRITE = "FX.NO_SPRITE";
/** tick 数不是正整数（见文件头 ⑤ 的兄弟话题：0 等于"取消"，语义模糊，一律拒绝）。 */
export const FX_BAD_TICKS = "FX.BAD_TICKS";
/** 模块没拿到场景。 */
export const FX_BAD_MODULE = "FX.BAD_MODULE";

/** 闪色：乘上去之后任何底色都会偏红，且仍保留明暗（是**乘**不是覆盖）。 */
export const FLASH_R = 1;
export const FLASH_G = 0.35;
export const FLASH_B = 0.4;

/** 挤压倍率：横向拉宽、纵向压扁（"被打了一下"的手感，纯视觉）。 */
export const PUNCH_W = 1.3;
export const PUNCH_H = 0.72;

export class Feedback extends Component {
  /** 还剩几 tick 闪（0 = 没在闪，见文件头 ②③）。 */
  flashTicks = 0;
  /** 这一段闪的总时长（诊断用，不参与判定）。 */
  flashTotal = 0;
  /** 受击**之前**的颜色（见文件头 ①②）。 */
  baseR = 1;
  baseG = 1;
  baseB = 1;
  baseA = 1;

  /** 还剩几 tick 挤压。 */
  punchTicks = 0;
  punchTotal = 0;
  /** 挤压**之前**的尺寸。 */
  baseW = 1;
  baseH = 1;

  readonly schema: ComponentSchema = {
    type: FEEDBACK_TYPE,
    fields: {
      flashTicks: FieldType.Int,
      flashTotal: FieldType.Int,
      baseR: FieldType.Float,
      baseG: FieldType.Float,
      baseB: FieldType.Float,
      baseA: FieldType.Float,
      punchTicks: FieldType.Int,
      punchTotal: FieldType.Int,
      baseW: FieldType.Float,
      baseH: FieldType.Float,
    },
  };
}

export function registerFeedbackComponent(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(FEEDBACK_TYPE)) registry.register(new Feedback().schema, () => new Feedback());
}

/** 取（必要时挂上）反馈组件。`attach` 走命令队列，所以要 `flush()`。 */
function ensure(scene: Scene, nodeId: number): Feedback | EngineError {
  const node = scene.find(nodeId);
  if (node === undefined || node === null) {
    return engineError(FX_NO_NODE, `节点 ${String(nodeId)} 不在场景里`);
  }
  const existing = node.get<Feedback>(FEEDBACK_TYPE);
  if (existing !== undefined) return existing;
  const made = scene.attach(nodeId, () => new Feedback());
  if (!made.ok) return made.error;
  scene.flush();
  const got = node.get<Feedback>(FEEDBACK_TYPE);
  if (got === undefined) {
    return engineError(FEEDBACK_TYPE + ".ATTACH_LOST", `反馈组件挂上之后又读不到（节点 ${String(nodeId)}）`);
  }
  return got;
}

function spriteOf(scene: Scene, nodeId: number): Sprite | EngineError {
  const node = scene.find(nodeId);
  if (node === undefined || node === null) {
    return engineError(FX_NO_NODE, `节点 ${String(nodeId)} 不在场景里`);
  }
  const sp = node.get<Sprite>(SPRITE_TYPE);
  if (sp === undefined) {
    return engineError(FX_NO_SPRITE, `节点 ${String(nodeId)} 没有 ${SPRITE_TYPE}（闪一个看不见的东西没有意义）`);
  }
  return sp;
}

function positiveTicks(ticks: number): EngineError | null {
  if (!Number.isInteger(ticks) || ticks <= 0) {
    return engineError(
      FX_BAD_TICKS,
      `时长必须是正整数 tick，收到 ${String(ticks)}（0 想表达"取消"的话请用 clear()）`,
    );
  }
  return null;
}

export interface FlashReport {
  readonly nodeId: number;
  /** 这一次请求的时长。 */
  readonly ticks: number;
  /** 请求之后还剩几 tick（可能大于 `ticks`，因为取了最大值，见文件头 ③）。 */
  readonly remaining: number;
  /** `true` = 本来就在闪，这一次只是把剩余时间**延长**了。 */
  readonly extended: boolean;
}

/**
 * 让 `nodeId` 闪 `ticks` tick。
 *
 * 校验顺序：时长 → 节点 → 精灵。前者任何一步失败都**一点状态都不动**。
 */
export function flash(scene: Scene, nodeId: number, ticks: number): Result<FlashReport, EngineError> {
  const bad = positiveTicks(ticks);
  if (bad !== null) return err(bad);
  const sp = spriteOf(scene, nodeId);
  if ("code" in sp) return err(sp as EngineError);
  const sprite = sp as Sprite;
  const fb = ensure(scene, nodeId);
  if ("code" in fb) return err(fb as EngineError);
  const feed = fb as Feedback;

  const extended = feed.flashTicks > 0;
  // 见文件头 ②：只在"从静止开始"时抓基色
  if (!extended) {
    feed.baseR = sprite.r;
    feed.baseG = sprite.g;
    feed.baseB = sprite.b;
    feed.baseA = sprite.a;
    feed.flashTotal = ticks;
  } else if (ticks > feed.flashTotal) {
    feed.flashTotal = ticks;
  }
  // 见文件头 ③：取最大值，不累加
  feed.flashTicks = Math.max(feed.flashTicks, ticks);
  sprite.r = FLASH_R;
  sprite.g = FLASH_G;
  sprite.b = FLASH_B;
  return ok({ nodeId, ticks, remaining: feed.flashTicks, extended });
}

export interface PunchReport {
  readonly nodeId: number;
  readonly ticks: number;
  readonly remaining: number;
  readonly extended: boolean;
}

/** 让 `nodeId` 挤压 `ticks` tick（挥击时给攻击者用）。校验顺序同 `flash`。 */
export function punch(scene: Scene, nodeId: number, ticks: number): Result<PunchReport, EngineError> {
  const bad = positiveTicks(ticks);
  if (bad !== null) return err(bad);
  const sp = spriteOf(scene, nodeId);
  if ("code" in sp) return err(sp as EngineError);
  const sprite = sp as Sprite;
  const fb = ensure(scene, nodeId);
  if ("code" in fb) return err(fb as EngineError);
  const feed = fb as Feedback;

  const extended = feed.punchTicks > 0;
  if (!extended) {
    feed.baseW = sprite.width;
    feed.baseH = sprite.height;
    feed.punchTotal = ticks;
  } else if (ticks > feed.punchTotal) {
    feed.punchTotal = ticks;
  }
  feed.punchTicks = Math.max(feed.punchTicks, ticks);
  sprite.width = feed.baseW * PUNCH_W;
  sprite.height = feed.baseH * PUNCH_H;
  return ok({ nodeId, ticks, remaining: feed.punchTicks, extended });
}

/**
 * 立刻把颜色还原（幂等，见文件头 ⑤）。返回 `true` = 这一次真的写回了颜色。
 *
 * ★★ 这里有一条比"幂等"更硬的规则：**只有"它还是闪色"的时候才写回**。
 *   第一版写成"没在闪就把基色写回去"，于是宿主在闪完之后自己把精灵改暗
 *   （尸体变灰、进入夜晚、隐身）时，`restoreTint` 会把它改回原色 ——
 *   而它的名字读起来正是"还原"，没人会想到它会**制造**颜色变化。
 *   这条规则同时覆盖"闪红的同时被击杀变灰"：到期不覆盖，记 `overridden`。
 */
export function restoreTint(scene: Scene, nodeId: number): boolean {
  const node = scene.find(nodeId);
  if (node === undefined || node === null) return false;
  const feed = node.get<Feedback>(FEEDBACK_TYPE);
  if (feed === undefined || feed.flashTicks > 0) return false;
  const sprite = node.get<Sprite>(SPRITE_TYPE);
  if (sprite === undefined) return false;
  if (sprite.r !== FLASH_R || sprite.g !== FLASH_G || sprite.b !== FLASH_B) return false;
  sprite.r = feed.baseR;
  sprite.g = feed.baseG;
  sprite.b = feed.baseB;
  sprite.a = feed.baseA;
  return true;
}

/**
 * 立刻把尺寸还原（幂等）。返回 `true` = 这一次真的写回了尺寸。
 * 规则同 `restoreTint`：只有"还是挤压后的尺寸"时才写回。
 */
export function restoreSize(scene: Scene, nodeId: number): boolean {
  const node = scene.find(nodeId);
  if (node === undefined || node === null) return false;
  const feed = node.get<Feedback>(FEEDBACK_TYPE);
  if (feed === undefined || feed.punchTicks > 0) return false;
  const sprite = node.get<Sprite>(SPRITE_TYPE);
  if (sprite === undefined) return false;
  if (sprite.width !== feed.baseW * PUNCH_W || sprite.height !== feed.baseH * PUNCH_H) return false;
  sprite.width = feed.baseW;
  sprite.height = feed.baseH;
  return true;
}

/** 两个通道都立刻结束（读档后、或"马上要拍照/截图"时用）。 */
export function clearFeedback(scene: Scene, nodeId: number): { tint: boolean; size: boolean } {
  const node = scene.find(nodeId);
  if (node === undefined || node === null) return { tint: false, size: false };
  const feed = node.get<Feedback>(FEEDBACK_TYPE);
  if (feed === undefined) return { tint: false, size: false };
  feed.flashTicks = 0;
  feed.punchTicks = 0;
  return { tint: restoreTint(scene, nodeId), size: restoreSize(scene, nodeId) };
}

export interface FeedbackStats {
  /** 正在闪的节点数。 */
  readonly flashing: number;
  /** 正在挤压的节点数。 */
  readonly punching: number;
  /** 累计还原次数（颜色 + 尺寸）。 */
  readonly restored: number;
  /** 累计：组件在、精灵没了，还原做不到（**要人看**）。 */
  readonly orphaned: number;
  /**
   * 累计：到期时"闪色已经被别人改掉了"（闪红的同时被击杀变灰、进入夜晚…），
   * 于是**不覆盖**。这不是错误，但它解释了"为什么那一下看起来没闪完"。
   */
  readonly overridden: number;
}

export interface FeedbackHandle extends IModule {
  update(tick: number): void;
  readonly stats: FeedbackStats;
}

/**
 * 每 tick 推进闪烁/挤压的倒计时，到点还原。
 *
 * ★ 必须在**渲染之前**推进：渲染读的是 `Sprite` 的当前值，
 *   在渲染之后还原会让"最后一帧闪色"多显示一帧（看起来像闪得比配置久）。
 */
export function createFeedbackModule(options: { id?: string } = {}): FeedbackHandle {
  let scene: Scene | null = null;
  let flashing = 0;
  let punching = 0;
  let restored = 0;
  let orphaned = 0;
  let overridden = 0;

  const handle: FeedbackHandle = {
    id: options.id ?? "render.feedback",
    deps: [],
    get stats(): FeedbackStats {
      return { flashing, punching, restored, orphaned, overridden };
    },
    init(ctx: ModuleContext): Result<void, EngineError> {
      const got = ctx.services.get(Services.Scene);
      if (got === undefined) {
        return err(engineError(FX_BAD_MODULE, "反馈模块需要一个 Scene（先注册 Services.Scene）"));
      }
      scene = got;
      return ok(undefined);
    },
    stop(): void {
      // 不清统计：这个模块被 stop 之后再 start 时，"已经还原过几次"仍然是事实
    },
    describe(): string {
      return `反馈：闪 ${String(flashing)} / 挤 ${String(punching)} / 还原 ${String(restored)}`;
    },
    update(): void {
      const s = scene;
      if (s === null) return;
      flashing = 0;
      punching = 0;
      // 按 id 升序：还原顺序确定（同一 tick 里多个到点时，日志/回放一致）
      const list = [...s.componentsOf<Feedback>(FEEDBACK_TYPE)].sort(
        (a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1),
      );
      for (const fb of list) {
        const node = fb.node;
        if (node === null) continue;
        if (fb.flashTicks > 0) {
          fb.flashTicks--;
          if (fb.flashTicks === 0) {
            if (node.get<Sprite>(SPRITE_TYPE) === undefined) orphaned++;
            else if (restoreTint(s, node.id)) restored++;
            else overridden++;
          } else {
            flashing++;
          }
        }
        if (fb.punchTicks > 0) {
          fb.punchTicks--;
          if (fb.punchTicks === 0) {
            if (node.get<Sprite>(SPRITE_TYPE) === undefined) orphaned++;
            else if (restoreSize(s, node.id)) restored++;
            else overridden++;
          } else {
            punching++;
          }
        }
      }
    },
  };
  return handle;
}
