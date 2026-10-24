/**
 * L4 · Sprite 组件
 *
 * ★ 组件里**不存 GPU 句柄**，只存"用哪个图集的哪一帧"（字符串）。
 *
 *   为什么这条很重要：组件要被序列化（存档）、要在编辑器里编辑、
 *   要能跨会话复用。而 `TextureHandle` 是**进程内的**数字，
 *   存进存档就是"换个会话就指向别的纹理"——这是最坏的一类 bug
 *   （不报错、画面错乱、且只在重启后出现）。
 *
 *   所以：组件存 `atlasId`（稳定 AssetId）+ `frame`（图集内名字），
 *   由渲染模块把它们解析成纹理句柄，并缓存映射。这也是 Unity 的
 *   `SpriteRenderer.sprite`（引用资产，不是引用 GPU 资源）的同一思路。
 *
 * ★ 深度：用节点的世界 z（2.5D 里"离镜头多远"），**不是**组件字段。
 *   这样"移动实体"自动改变遮挡关系 —— 遮挡是位置的性质，不是可编辑的属性。
 *   同 z 时用 `order` 再排（树与树之间的手调）。
 *
 * ★★ 分层（`layer`）在 z **之前**：0 = 背景（地面），1 = 实体。
 *
 *   为什么需要它：T288 给地形抽了独立瓦片页之后，地形与实体按 z 全局混排，
 *   而地形的 z 是矩形左上角的格子坐标、实体的 z 是格子中心 —— 两者必然交错，
 *   于是"一块地形盖住站在它上面的角色"（z 大的地形后画），draw call 也从 1 涨到 29。
 *
 *   分层不是"为了少几次 draw"的优化，而是把两类东西分开：
 *     · 地面之间**不重叠**，层内谁先谁后看不见；
 *     · 实体永远盖住地面，这是 2.5D 的正确语义（饥荒里人物从不会被草地盖住）。
 *   z 仍然在**层内**完整保留 —— 跨层的纹理切换不做优化（先画完所有 A 再画 B
 *   会让 B 里 z 小的盖住 A 里 z 大的），跨**层**才允许，因为层的优先级高于 z。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";

/** 组件类型名。集中一处：渲染模块、可视化桥、判据都用它，避免三处各写一遍字符串。 */
export const SPRITE_TYPE = "render.sprite";

export class Sprite extends Component {
  /** 图集资产 id（空 = 用默认图集）。 */
  atlasId = "";
  /** 图集内帧名。 */
  frame = "";
  /** 世界尺寸（宽/高）。 */
  width = 1;
  height = 1;
  /** 顶点色（与纹理相乘）。 */
  r = 1;
  g = 1;
  b = 1;
  a = 1;
  /** 同 z 时的次序（小的先画）。 */
  order = 0;
  /**
   * 绘制层：0 = 背景（地面），1 = 实体（默认）。层在 z **之前**比较。
   *
   * ★ 默认 1 而不是 0：旧内容/旧存档没有这个字段，它们该保持"实体"行为。
   *   缺字段拿到 0 会让所有旧精灵掉到地形背后 —— 一帧都不显示，且没有任何报错。
   *
   * ★ 用整数而不是枚举：层数由宿主定（背景/实体/UI/ overlay…），引擎不替宿主
   *   决定有哪些层，只保证"小的先画"。
   */
  layer = 1;
  /** 关闭后不参与渲染（但仍更新逻辑）。 */
  visible = true;
  /** 锚点：0 = 底边，0.5 = 中心。饥荒风格通常用 0（脚踩地面）。 */
  pivotY = 0.5;
  /**
   * 水平锚点：0 = 左边界，0.5 = 中心。
   *
   * ★ 为什么需要它（这是"地形一直画不出来"的根因）：
   *   地形节点是**矩形**，位置是矩形左上角的格子坐标。只有 `pivotY` 时，
   *   精灵永远以节点位置为水平中心 —— 一块 8×5 的地形要么整体右移半块，
   *   要么就得把节点位置改成矩形中心（那会破坏「地形节点位置 = 格子坐标」，
   *   连带破坏反查与存档往返）。加一个对称的 `pivotX` 是唯一不动代价的解法。
   *
   * ★ 默认 0.5 = 与"只有 pivotY"时的行为完全一致：旧内容/旧代码的显示不变。
   *   也正因为如此，旧存档里没有这个字段时**必须**拿到 0.5（不是 0）——
   *   见 scene-io 的 `missingFields`：缺字段会走类里的默认值，不会被写成 0。
   */
  pivotX = 0.5;
  /**
   * 沿精灵宽度重复贴图多少次（T288）。
   *
   * ★ 为什么它是"次数"而不是"UV 缩放量"：调用方想的是"这一块 8 格宽的地形，
   *   每格铺一张 64×64 的噪点"—— 8 次，一个整数。乘出来的 UV 是 8×帧宽，
   *   那是实现细节。写成"缩放量"会让每个宿主都得自己算 `宽 / 贴图像素宽`，
   *   而那正是 T288 想消灭的"每处各算一遍"。
   *
   * ★ 只能用在 `wrap: repeat` 的**瓦片页**上（见 `buildTilePages`）。
   *   在 clamp 页上平铺，GPU 会把边缘像素抻出去 —— 画面是一条脏边，
   *   而精灵的所有数字都对。渲染模块对这种组合**告警**（不静默跳过）。
   *
   * ★ 默认 1 = 与旧行为逐字节一致：旧存档没有这个字段时也必须拿到 1
   *   （`scene-io` 的缺字段走类默认值，不会被写成 0 —— 0 会让精灵整块消失）。
   */
  tileX = 1;
  /** 沿精灵高度重复贴图多少次。语义同 `tileX`。 */
  tileY = 1;

  readonly schema: ComponentSchema = {
    type: SPRITE_TYPE,
    fields: {
      atlasId: FieldType.String,
      frame: FieldType.String,
      width: FieldType.Float,
      height: FieldType.Float,
      r: FieldType.Float,
      g: FieldType.Float,
      b: FieldType.Float,
      a: FieldType.Float,
      order: FieldType.Int,
      layer: FieldType.Int,
      visible: FieldType.Bool,
      pivotY: FieldType.Float,
      pivotX: FieldType.Float,
      tileX: FieldType.Float,
      tileY: FieldType.Float,
    },
  };
}

/** 便捷构造：`makeSprite("tree", 2, 3)`。 */
export function makeSprite(frame: string, width = 1, height = 1): Sprite {
  const s = new Sprite();
  s.frame = frame;
  s.width = width;
  s.height = height;
  return s;
}
