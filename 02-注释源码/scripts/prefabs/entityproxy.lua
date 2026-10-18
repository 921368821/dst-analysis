--============================================================
-- 文件：prefabs/entityproxy.lua
-- 模块：预制体 / entityproxy（建筑与容器）
-- 职责：实体「entityproxy」的预制体定义。SpawnPrefab("entityproxy") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function fn()
	local inst = CreateEntity()

    inst.entity:SetCanSleep(false)

	inst.entity:AddTransform()
	inst.entity:AddAnimState()

	inst:AddComponent("replayproxy")

    inst.persists = false
    inst:AddTag("entityproxy")

    return inst
end

return Prefab("entityproxy", fn)
