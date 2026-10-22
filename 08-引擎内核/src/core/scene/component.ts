/**
 * L2 · 组件
 *
 * 组件是"能力"，节点是"位置"。这是 Unity / Cocos / 饥荒三者一致的世界模型
 * （饥荒叫 EntityScript + components），也是本项目**唯一**的世界模型。
 *
 * ★★ 一个明确不做的事：**不引入第二套 ECS 世界**。
 *    我们采纳 ECS 的"数据按类型集中存放"（`Scene` 里 `byType` 表），但不采纳
 *    "实体只是 id、没有对象"的那一半 —— 因为：
 *      · 脚本层（Lua/JS 双向）需要能持有"这个实体"的引用；
 *      · 编辑器的属性面板需要按名字访问字段；
 *      · 两套世界模型并存时，"这个实体在哪套里"会成为每个新功能的第一个问题。
 *    性能上真正贵的是"每帧遍历 5000 个实体调虚函数"，而那是 `byType` + 数组遍历
 *    就能解决的，不需要把整个引擎变成 ECS。
 *
 * ★ 字段声明式（`schema`）而不是手写 save/load：
 *    手写必然漏字段，而漏字段的症状是"存了但读回来是默认值" —— 静默。
 *    上一代引擎的"读档丢背包"就是这么来的（存档里根本没写 owner）。
 *    这里 `save/load` 由基类按 schema 生成，**字段表是唯一来源**。
 */

import type { Node } from "./node.ts";

/** 字段类型：决定序列化形式与编辑器控件。新增类型要同时改 serialize 与编辑器。 */
export const FieldType = {
  Int: "i32",
  Float: "f32",
  Double: "f64",
  Bool: "bool",
  String: "string",
  Vec2: "vec2",
  Color: "color",
  /** 资产引用：存 AssetId（GUID），不存路径 —— 路径会变，GUID 不会。 */
  Asset: "asset",
  /** 场景内节点引用：存节点 id。 */
  NodeRef: "noderef",
  /** 字符串数组（标签、配方列表）。 */
  StringArray: "string[]",
} as const;
export type FieldTypeValue = (typeof FieldType)[keyof typeof FieldType];

export interface ComponentSchema {
  /** 全局唯一。约定 `域.名`，例如 `core.transform`、`game.health`。 */
  readonly type: string;
  /** 字段名 → 类型。**顺序即序列化顺序**（保证字节确定）。 */
  readonly fields: Readonly<Record<string, FieldTypeValue>>;
  /** 默认值（新节点挂载时）。缺省用类型零值。 */
  readonly defaults?: Readonly<Record<string, unknown>>;
}

export function zeroValue(t: FieldTypeValue): unknown {
  switch (t) {
    case FieldType.Int:
    case FieldType.Float:
    case FieldType.Double:
      return 0;
    case FieldType.Bool:
      return false;
    case FieldType.String:
      return "";
    case FieldType.Vec2:
      return { x: 0, y: 0 };
    case FieldType.Color:
      return { r: 1, g: 1, b: 1, a: 1 };
    case FieldType.Asset:
    case FieldType.NodeRef:
      return "";
    case FieldType.StringArray:
      return [];
    default:
      return null;
  }
}

/**
 * 组件基类。
 *
 * 生命周期（顺序固定，由 `Scene.step` 保证）：
 *   onAttach  → 挂到节点时一次
 *   onEnable  → 每次 enabled 由 false→true（含首次 attach 后的首帧）
 *   onUpdate  → 每个固定步一次（**只在 enabled 且节点 active 时**）
 *   onDisable → enabled true→false 或节点失活
 *   onDetach  → 从节点摘除时一次
 *
 * ★ `onUpdate` 的 `dt` 是**固定步长**，不是真实帧间隔。
 *   需要真实时间的地方（动画、UI 过渡）应该用 `tick` 或插值 alpha，
 *   而不是读墙钟 —— 否则暂停时动画还在走。
 */
export abstract class Component {
  /** 所属节点。`null` 只在 attach 之前/ detach 之后。 */
  node: Node | null = null;
  enabled = true;
  /** 场景内部用：记录 enabled 状态，避免重复触发 onEnable。 */
  private lastActive = false;

  abstract readonly schema: ComponentSchema;

  /** 便捷：组件类型（来自 schema，避免两处写）。 */
  get type(): string {
    return this.schema.type;
  }

  onAttach(): void {}
  onDetach(): void {}
  onEnable(): void {}
  onDisable(): void {}
  onUpdate(_tick: number, _dt: number): void {}

  /** 通用保存：按 schema 逐字段取。**顺序由 schema 决定**（字节确定）。 */
  save(): Record<string, unknown> {
    const out: Record<string, unknown> = { type: this.schema.type };
    for (const k of Object.keys(this.schema.fields)) {
      const v = (this as unknown as Record<string, unknown>)[k];
      out[k] = v === undefined ? zeroValue(this.schema.fields[k]!) : v;
    }
    return out;
  }

  /**
   * 通用读取。**缺字段用默认值而不是跳过**，但要报告（见返回值）。
   * 返回缺失的字段名：调用方（AssetDatabase / 存档）据此判断"是不是旧版本"。
   */
  load(data: Readonly<Record<string, unknown>>): { missing: string[] } {
    const missing: string[] = [];
    const self = this as unknown as Record<string, unknown>;
    for (const [k, t] of Object.entries(this.schema.fields)) {
      if (data[k] === undefined) missing.push(k);
      self[k] = data[k] === undefined ? zeroValue(t) : data[k];
    }
    return { missing };
  }

  /** 场景内部：由 Scene 调用，管理 onEnable/onDisable 的边沿。 */
  _setActive(active: boolean): void {
    if (active === this.lastActive) return;
    this.lastActive = active;
    if (active) this.onEnable();
    else this.onDisable();
  }

  get isActive(): boolean {
    return this.lastActive;
  }
}

/** 组件类型注册表：`type → 工厂`。新增组件 = 一次 register，不改 Scene。 */
export class ComponentRegistry {
  private readonly factories = new Map<string, () => Component>();
  private readonly schemas = new Map<string, ComponentSchema>();

  register(schema: ComponentSchema, factory: () => Component): void {
    if (this.factories.has(schema.type)) {
      throw new Error(`组件类型 ${schema.type} 已注册（同类型不允许重复注册）`);
    }
    this.factories.set(schema.type, factory);
    this.schemas.set(schema.type, schema);
  }

  create(type: string): Component | undefined {
    return this.factories.get(type)?.();
  }

  schemaOf(type: string): ComponentSchema | undefined {
    return this.schemas.get(type);
  }

  has(type: string): boolean {
    return this.factories.has(type);
  }

  types(): readonly string[] {
    return Array.from(this.factories.keys()).sort();
  }
}
