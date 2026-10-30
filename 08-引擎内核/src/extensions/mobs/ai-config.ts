/**
 * L4 · 「这只生物用哪棵树」（组件 `mobs.ai`）
 *
 * 批154 之后树是一棵数据树，但那棵树是**整根大脑一份**：世界里所有生物共用同一个决定。
 * 这个组件把「用哪棵」变成**每只生物一个值**，并且落在实体上 ——
 * 于是它跟着存档走、在属性面板里能改、编辑器点哪只改哪只。
 *
 * ★★ 三个决定：
 *
 * ① **字段存 `AssetId`（`FieldType.Asset`），不内联树**。
 *    内联的话每只生物存一份树：改一处只影响一只（"调所有猎狗"要逐只改），
 *    而且存档会随生物数量膨胀。理由与 `tree-asset.ts` 文件头 ① 同源。
 *
 * ② **`""` = 没配 = 用内置树**，而不是"没有 AI"。
 *    "这只不思考"是另一件事（`Component.enabled = false` / 节点不 active），
 *    两者合成一个值的话，属性面板上「树 = 空」到底是"没配"还是"关掉了"分不出来。
 *
 * ③ **`treeIdOf` 只读一次、不缓存**：一个 `Map` 缓存省不下什么
 *    （一次 `get` + 一次字段读），却会在「编辑器刚改了字段、AI 还在用旧值」时
 *    变成一个只有实机才看得见的 bug。
 */

import { Component, FieldType, type ComponentSchema, type ComponentRegistry } from "../../core/scene/component.ts";
import type { AssetId } from "../../core/asset/asset.ts";
import type { Scene } from "../../core/scene/scene.ts";

export const AI_CONFIG_TYPE = "mobs.ai";

export class AIConfig extends Component {
  /**
   * 决策树的资产 id。`""` = 用内置树（见文件头 ②）。
   *
   * ★ 字段名 `tree` 而不是 `treeId`：属性面板上显示的就是这个名字，
   *   而「Asset 类型的 tree」在编辑器里已经是资产选择器 —— 名字里再带一个 Id
   *   会让配置的人以为要手填一串 GUID。
   */
  tree: AssetId = "";

  readonly schema: ComponentSchema = {
    type: AI_CONFIG_TYPE,
    fields: { tree: FieldType.Asset },
    defaults: { tree: "" },
  };
}

export function registerAiConfig(reg: ComponentRegistry): void {
  reg.register(new AIConfig().schema, () => new AIConfig());
}

/**
 * 这只生物要的树的 id（`""` = 没配）。
 *
 * 节点不存在 / 没挂组件 / 组件值不是字符串，一律返回 `""`（= 内置树）。
 * ★ 不在这里区分「没组件」与「组件里是空串」：两者对玩法的含义完全相同（都用内置树），
 *   而能区分的那个信息（有没有挂组件）在 `explain` 里另有字段，不需要挤进这个返回值。
 */
export function treeIdOf(scene: Scene, nodeId: number): AssetId {
  const node = scene.find(nodeId);
  if (node === undefined) return "";
  const c = node.get<AIConfig>(AI_CONFIG_TYPE);
  if (c === undefined) return "";
  return typeof c.tree === "string" ? c.tree : "";
}
