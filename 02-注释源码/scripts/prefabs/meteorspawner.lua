--============================================================
-- 文件：prefabs/meteorspawner.lua
-- 模块：预制体 / meteorspawner（建筑与容器）
-- 职责：实体「meteorspawner」的预制体定义。SpawnPrefab("meteorspawner") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("CLASSIFIED")

    inst:AddComponent("meteorshower")

    return inst
end

return Prefab("meteorspawner", fn)