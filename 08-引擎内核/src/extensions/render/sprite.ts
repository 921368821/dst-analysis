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
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";

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
  /** 关闭后不参与渲染（但仍更新逻辑）。 */
  visible = true;
  /** 锚点：0 = 底边，0.5 = 中心。饥荒风格通常用 0（脚踩地面）。 */
  pivotY = 0.5;

  readonly schema: ComponentSchema = {
    type: "render.sprite",
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
      visible: FieldType.Bool,
      pivotY: FieldType.Float,
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
