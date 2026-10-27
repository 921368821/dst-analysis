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
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { Node } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { FACING_TYPE, Facing } from "../motion/facing.ts";
import { resolveDirFrame, type DirCount } from "./dir-frames.ts";
import { SPRITE_TYPE, Sprite } from "./sprite.ts";

/** 组件类型名。集中一处：装配、判据、编辑器都用它。 */
export const DIR_SPRITE_TYPE = "render.dirSprite";

/** 同步结果。判据靠它区分「没有需要同步的实体」与「同步了但一帧没变」。 */
export interface DirSpriteSyncStats {
  /** 这一 tick 真正改写了 `Sprite.frame` 的实体数。 */
  changed: number;
  /** 带朝向与精灵、但图集里连单帧都没有的实体数（资产缺失，不是方向问题）。 */
  missing: number;
  /** 参与同步的实体数（`changed` 与 `missing` 都是它的子集）。 */
  visited: number;
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
 * 把这一 tick 的朝向同步到精灵帧上。宿主在 `onStep` 里调一次即可。
 *
 * 遍历用 `walk`（含隐藏子树）而不是 `walkVisible`：隐藏的实体恢复显示时
 * 不应该先闪一帧旧方向 —— 帧名是纯数据，写它没有副作用。
 */
export function syncDirFrames(scene: Scene, has: (frame: string) => boolean): DirSpriteSyncStats {
  const stats: DirSpriteSyncStats = { changed: 0, missing: 0, visited: 0 };
  scene.root.walk((node: Node) => {
    const ds = node.get<DirSprite>(DIR_SPRITE_TYPE);
    if (ds === undefined || ds.prefix === "") return;
    const face = node.get<Facing>(FACING_TYPE);
    if (face === undefined) return;
    const sp = node.get<Sprite>(SPRITE_TYPE);
    if (sp === undefined) return;
    stats.visited++;
    const list = ds.resolve(has);
    const dir = ds.dirs === 4 ? face.dir4 : face.dir8;
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
