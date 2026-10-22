/**
 * L4 · 脚本组件（`game.script`）
 *
 * 一个 `ScriptComponent` 把"节点"接到"脚本模块里的一个函数"：
 *   node + game.script{ module, entry } → 每 tick 调 `module` 里的 `entry`
 *
 * ★ 为什么组件只存**名字**，不存函数引用：
 *   函数引用在热重载后会指向旧闭包 —— 脚本改了但行为没变，是最难发现的
 *   "热重载其实没生效"。名字每帧在运行时的全局表里查，加载即生效。
 *
 * ★ 为什么 `entry` 默认 `onUpdate`：
 *   与饥荒的组件生命周期命名一致（`OnUpdate` 是每帧入口）。默认值让
 *   "只想挂个每帧脚本"的场景少写一个字段；字段顺序（module → entry）
 *   就是序列化顺序，改顺序会让已有存档的字节变化。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";

/** 组件类型常量：模块与场景注册表共用同一个字符串，避免两处手写。 */
export const SCRIPT_COMPONENT_TYPE = "game.script";

export class ScriptComponent extends Component {
  /** 逻辑模块名（`ai.brain`），由 `ScriptModule` 通过 `runtime.loadModule` 加载时登记。 */
  module = "";
  /** 入口函数名。空字符串在模块里会被当作默认 `onUpdate` 处理。 */
  entry = "onUpdate";

  readonly schema: ComponentSchema = {
    type: SCRIPT_COMPONENT_TYPE,
    fields: {
      module: FieldType.String,
      entry: FieldType.String,
    },
    defaults: {
      module: "",
      entry: "onUpdate",
    },
  };
}
