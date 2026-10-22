# ADR-0001 · 世界模型：Node + Component，但组件按类型集中存储

- **状态**：已采纳
- **日期**：2026-10-22

## 背景

《饥荒》风格需要一个能容纳数千实体、支持"能力组合"（可腐烂 + 可堆叠 + 可被攻击）的世界模型。
业界有三条主流路线：

1. **纯 OOP 组合**（Unity GameObject + Component、Cocos Node + Component、DST 的 EntityScript + components）
2. **纯 ECS**（实体只是 id，数据全在组件数组里，逻辑在 System 里）
3. **两套并存**（Unity 的 GameObject 与 DOTS）

## 决策

采用 **Node（变换层级）+ Component（能力）**，但**组件按类型集中存放**：
`Scene` 内部维护 `byType: Map<string, Component[]>`，并对每种类型维护一条稳定的更新顺序。

因此"遍历所有可腐烂物"是一次数组遍历，不是"遍历全部节点再过滤"。

## 后果

### 正面

- 脚本层与编辑器可以持有"这个实体"的引用（`Node` 是对象），不需要额外 id → 句柄的映射。
- 属性面板按名字访问字段是自然的；ECS 里要额外维护反射元数据。
- 遍历性能接近 ECS（按类型连续数组），而"能力组合"仍然是 `node.get('x')` 这种可读写法。
- 只有**一套**世界模型 ⇒ "这个实体在哪套里"不会成为每个新功能的第一个问题。

### 负面

- 组件不保证内存连续（每个 `Component` 是独立对象）。真正的 SIMD/job 化需要额外的 SoA 布局层。
  **缓解**：`Scene.componentsOf(type)` 已提供"按类型取数组"的入口，
  将来做 SoA 是在这个入口后面换存储，不改调用方。
- 单个节点的组件查找是线性扫描（`node.get` 遍历 `components` 数组）。
  **缓解**：单节点组件数量通常 < 10，线性扫描比 Map 更快（无哈希开销）。

## 被否的方案

- **纯 ECS**：脚本层（Lua/JS 双向）需要"实体引用"，
  而在 ECS 里那只能是一个 id，任何"这个实体的组件"访问都要经过 World 查表 ——
  脚本侧写起来会变成 `world.get(id, Health).hp`，对内容作者不友好。
- **两套并存（Unity DOTS 式）**：代价是每个新功能都要回答"进哪套"，
  以及两套之间的同步（一旦有了同步，就有了两个真相）。

## 相关

- `src/core/scene/scene.ts`（`byType` / `typeOrder` / `step`）
- `src/core/scene/component.ts`（schema 声明式序列化）
- `docs/ARCHITECTURE.md` §3.3、§9.1
