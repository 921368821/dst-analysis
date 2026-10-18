--============================================================
-- 文件：prefabs/itemmimic_data.lua
-- 模块：预制体 / itemmimic_data（建筑与容器）
-- 职责：实体「itemmimic_data」的预制体定义。SpawnPrefab("itemmimic_data") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


return {
    MUST_TAGS = {"_equippable", "_inventoryitem"},
    CANT_TAGS = {"_container", "_health", "_stackable", "heavy", "smallcreature", "INLIMBO"},
}