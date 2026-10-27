/**
 * L4 · 按朝向切帧（**把 `motion.facing` 接到 `render.sprite` 上的那根线**）
 *
 * 批107 只交付了「朝向数据」，`dir-frames.ts` 只交付了「帧名契约」——
 * 两件东西各自都能验，但**没有任何一行代码把它们连起来**。
 * 这一层就是那根线：每 tick 把 `facing.dir8` 翻译成帧名写进 `Sprite.frame`。
 *
 * ★ 为什么是「每 tick 同步」而不是「转向时通知」：
 *   `Facing` 是纯数据，它不知道谁在监听；加回调就要在 `Facing` 上挂订阅表，
 *   而那会让「改朝向」这一个动作有两个副作用入口（直接改字段 vs 走 setter）。
 *   轮询的代价是「每 tick 每实体一次整数比较」—— 图集解析结果已经缓存，
 *   真正执行的只有 `resolved[dir]` 与 `sprite.frame` 两个值的比较。
 *
 * ★ 为什么帧名**只解析一次**（组件上缓存 `resolved`）：
 *   `has` 查的是图集帧表，每帧 × 每实体 × 8 向去查是纯浪费；更要紧的是
 *   「图集在运行期不变」这个前提必须**说出来**。它今天就成立（图集在 boot 时烘好、
 *   之后只读）。哪天要做热更新，改的入口是 `DirSprite.invalidate()`，
 *   而不是散在同步函数里的缓存判断。
 *
 * ★ 缺帧时**不改** `sprite.frame`，也不「保留上一帧」当成回落：
 *   回落顺序只有 `resolveDirFrame` 一处（方向帧 → 单帧 → null）。
 *   如果这里自己写「没有就往回退到上一帧」，北向走的怪会显示成南向 ——
 *   而 `resolveDirFrame` 的判据还是绿的（它从没被问过这个问题）。
 *   `null`（连单帧都没有）时保持原值并计入 `missing`：这种实体本来就画不出来，
 *   在这里改成一个别的名字只会把「资产缺失」伪装成「方向错了」。
 *
 * ★ 4 向与 8 向都支持，但 `dirs` 是**组件字段**而不是引擎全局开关：
 *   同一个世界里可以有 4 向的猎犬与 8 向的兔子（美术进度不同），
 *   全局开关会逼着所有人等高线最慢的那套图。
 *
 * ★★ 批112 起多了一条路：**方向选的是「动画片段」而不只是「帧名」**。
 *   原因很实际 —— 导入的八向素材每个方向有 4 帧待机动画，而单帧模式
 *   只能表现其中一帧（"每方向一张静态图"，走起来像纸片）。
 *   两种模式的分工写死在 `syncDirFrames` 里：
 *     · 帧模式（`clipIds` 为空）：这里写 `Sprite.frame`，`SpriteAnimator` 不参与；
 *     · clip 模式：这里**只**改 `SpriteAnimator.clipId`，`Sprite.frame` 交给
 *       `anim-module` 每帧采样写入。
 *   ★ 为什么必须二选一而不是"都写"：`sprite.frame` 有两个写入者时，
 *     谁最后跑谁赢 —— 而"谁最后跑"取决于模块装配顺序，是一个**静默**的
 *     胜负关系。症状是"动画播了两帧就被方向同步打回第一帧"，或者反过来
 *     "转向了但画面不变"，两种都像是素材/朝向出问题。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { Node } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { FACING_TYPE, Facing } from "../motion/facing.ts";
import { resolveDirFrame, type DirCount } from "./dir-frames.ts";
import { SPRITE_ANIMATOR_TYPE, SpriteAnimator } from "./sprite-animator.ts";
import { SPRITE_TYPE, Sprite } from "./sprite.ts";

/** 组件类型名。集中一处：装配、判据、编辑器都用它。 */
export const DIR_SPRITE_TYPE = "render.dirSprite";

/** 同步结果。判据靠它区分「没有需要同步的实体」与「同步了但一帧没变」。 */
export interface DirSpriteSyncStats {
  /** 这一 tick 真正改写了 `Sprite.frame` 的实体数（**只统计帧模式**）。 */
  changed: number;
  /** 带朝向与精灵、但图集里连单帧都没有的实体数（资产缺失，不是方向问题）。 */
  missing: number;
  /** 参与同步的实体数（`changed` 与 `missing` 都是它的子集）。 */
  visited: number;
  /** 本 tick 由 clip 驱动（`sprite.frame` 归动画模块写）的实体数。 */
  animated: number;
  /**
   * 本 tick **换了方向对应 clip** 的实体数。
   *
   * ★ 单独计数，而不是并进 `changed`：两者含义不同 —— `changed` 是"画面上
   *   这一格真的变了"，`clipChanged` 是"换了播放内容"（换 clip 的瞬间画面
   *   可能正好还是同一帧）。合成一个数，判据就分不清"转向了"与"换帧了"。
   */
  clipChanged: number;
  /** 带 `clipIds` 但该向的 clip 为空（回落单帧）的实体数。 */
  clipMissing: number;
}

export class DirSprite extends Component {
  /**
   * 帧名前缀（`rabbit` ⇒ `rabbit_e` / `rabbit_ne`…）。空 = 本组件不生效。
   *
   * ★ 前缀与 `mobs` 模板里的 `frame` 是**同一个字符串**，装配时直接抄过来。
   *   两处各配一次的症状是「生物在走但永远一个姿势」，而画面上完全看不出
   *   是配置写错还是图没画 —— 见 `spawn-mob.ts` 的装配注释。
   */
  prefix = "";

  /** 方向数（4 或 8）。图集里只画了 4 向就填 4，别拿 8 向去凑邻向。 */
  dirs: DirCount = 8;

  /**
   * 方向 → 动画 clip id。**空数组 = 单帧模式**（老行为）。
   *
   * ★ 长度必须是 `dirs`；某一项为空串表示"该向没有 clip"，此时回落单帧。
   *   长度不足按空数组处理（整体回落单帧），**不**按 `undefined` 逐项回退：
   *   "配了一半"与"没配"在画面上是同一件事（都在放静态图），
   *   而逐项回退会让"只配了东向"这种半成品看起来正常。
   *
   * ★ 为什么不进 `schema`：`ComponentSchema` 的字段类型只有标量
   *   （String/Int/Float/Bool），塞不进字符串数组。这意味着 `clipIds`
   *   **不随存档走** —— 它由宿主在装配时给出，和 `Sprite.atlasId` 一样属于
   *   "这是哪套资产"的问题，而不是"这个实体的状态"。如果哪天要热更新素材，
   *   改的入口是装配处，不是存档迁移。
   */
  clipIds: string[] = [];

  /** 解析缓存：下标 = 扇区号；`null` = 该向没有专属帧，回落到 `prefix` 单帧。 */
  private resolved: (string | null)[] = [];

  /** 缓存对应的 key（`prefix/dirs`）。前缀或方向数一变就重算。 */
  private resolvedFor = "";

  readonly schema: ComponentSchema = {
    type: DIR_SPRITE_TYPE,
    fields: {
      prefix: FieldType.String,
      dirs: FieldType.Int,
    },
    defaults: { prefix: "", dirs: 8 },
  };

  /**
   * 解析 8（或 4）个方向的帧名，前缀没变时直接返回缓存。
   *
   * `has` 用函数而不是 `Set`：调用方手里可能是 Map、也可能是惰性集合
   * （`dir-frames.ts` 的注释里已说明同一条理由）。
   */
  resolve(has: (frame: string) => boolean): (string | null)[] {
    const key = `${this.prefix}/${this.dirs}`;
    if (this.resolvedFor === key && this.resolved.length > 0) return this.resolved;
    const n = this.dirs;
    const out: (string | null)[] = [];
    for (let i = 0; i < n; i++) out.push(resolveDirFrame(has, this.prefix, i, n));
    this.resolved = out;
    this.resolvedFor = key;
    return out;
  }

  /** 图集变了（热更新）时调用。**故意不自动**：自动重算等于把「图集只读」这个前提藏起来。 */
  invalidate(): void {
    this.resolved = [];
    this.resolvedFor = "";
  }
}

/**
 * 注册组件工厂。与其它扩展一致：`attach` 找不到注册表条目会硬失败。
 */
export function registerDirSpriteComponent(registry: {
  has(type: string): boolean;
  register(schema: ComponentSchema, factory: () => Component): void;
}): void {
  if (!registry.has(DIR_SPRITE_TYPE)) {
    registry.register(new DirSprite().schema, () => new DirSprite());
  }
}

/**
 * 读档之后，把**宿主给的 clip 表**补回去。
 *
 * ★★ 为什么需要这个函数（批112 真踩过，是页面级断言抓出来的）：
 *   `clipIds` 不在 `schema` 里（字符串数组塞不进字段表），而 `loadScene` 是
 *   「按 schema 重建组件」——于是读一次档，玩家的 clip 表就变成空的。
 *   表现不是报错，而是：朝向照旧跟着走，`syncDirFrames` 退回单帧模式，
 *   去图集里找 `hero`（这套素材根本没有单帧名）⇒ `missing` 计数涨、
 *   `sprite.frame` 从此一秒都不再变 —— 「读档后玩家变成一个静止贴图」。
 *
 * ★ 这类字段（`atlasId` / `clipIds` / 物理登记）的共同点：它们描述的是
 *   **这是哪套资产、挂在哪**，属于装配，不是实体状态。存档只能记状态；
 *   装配必须由宿主在读档后重新施加一遍。
 *
 * @returns 真的补上了（节点在、且挂着 `DirSprite`）才为 `true`。
 */
export function restoreDirClipIds(scene: Scene, nodeId: number, clipIds: readonly string[]): boolean {
  const ds = scene.find(nodeId)?.get<DirSprite>(DIR_SPRITE_TYPE);
  if (ds === undefined) return false;
  ds.clipIds = clipIds.slice();
  return true;
}

/**
 * 把这一 tick 的朝向同步到精灵帧上。宿主在 `onStep` 里调一次即可。
 *
 * 遍历用 `walk`（含隐藏子树）而不是 `walkVisible`：隐藏的实体恢复显示时
 * 不应该先闪一帧旧方向 —— 帧名是纯数据，写它没有副作用。
 */
export function syncDirFrames(scene: Scene, has: (frame: string) => boolean): DirSpriteSyncStats {
  const stats: DirSpriteSyncStats = {
    changed: 0,
    missing: 0,
    visited: 0,
    animated: 0,
    clipChanged: 0,
    clipMissing: 0,
  };
  scene.root.walk((node: Node) => {
    const ds = node.get<DirSprite>(DIR_SPRITE_TYPE);
    if (ds === undefined || ds.prefix === "") return;
    const face = node.get<Facing>(FACING_TYPE);
    if (face === undefined) return;
    const sp = node.get<Sprite>(SPRITE_TYPE);
    if (sp === undefined) return;
    stats.visited++;
    const dir = ds.dirs === 4 ? face.dir4 : face.dir8;

    // ---- ① clip 模式：方向选的是"播哪段"，`Sprite.frame` 归动画模块
    if (ds.clipIds.length >= ds.dirs) {
      const clipId = ds.clipIds[dir] ?? "";
      const anim = clipId === "" ? undefined : node.get<SpriteAnimator>(SPRITE_ANIMATOR_TYPE);
      if (anim !== undefined) {
        stats.animated++;
        if (anim.clipId !== clipId) {
          anim.clipId = clipId;
          // ★★ 只在**真的换了 clip** 时归零，不是每 tick 归零。
          //   每 tick 归零的写法在画面上是"角色一直在动"（其它东西也在动），
          //   但这段动画永远停在第一帧 —— 极难怀疑到这一行。
          anim.timeMs = 0;
          stats.clipChanged++;
        }
        // ★ 这里**必须**返回：clip 模式下再写 `sprite.frame` 就是第二个写入者，
        //   会和 anim-module 的采样抢同一个字段（见文件头 ★★）。
        return;
      }
      // clip 配了但没生效（该向为空 / 节点没挂动画器）：如实计数，然后按单帧画。
      stats.clipMissing++;
    }

    // ---- ② 单帧模式（老行为）
    const list = ds.resolve(has);
    // ★ 这里**不再**写「没有方向帧就回落到单帧」——那个回落是 `resolveDirFrame` 的事，
    //   `resolve()` 返回的每一项本身就已经回落过了。原来这里还写了一层
    //   `?? (has(prefix) ? prefix : null)`，而它**永远不可达**：
    //   `list[dir] === null` 等价于「方向帧与单帧都没有」，此时 `has(prefix)` 必然为假。
    //   验不到的防御比没有更糟 —— 它会让人以为这里防住了。（这条是变异 M578 逼出来的。）
    //   `?? null` 只用于把 `noUncheckedIndexedAccess` 的 `undefined` 归一，不是回落。
    const target = list[dir] ?? null;
    if (target === null) {
      // 连单帧都没有：资产缺失。保持原值并计数，别在这里编一个名字（见文件头）。
      stats.missing++;
      return;
    }
    if (sp.frame !== target) {
      sp.frame = target;
      stats.changed++;
    }
  });
  return stats;
}
