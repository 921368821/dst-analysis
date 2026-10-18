--============================================================
-- 文件：prefabs/fishschoolspawnblocker.lua
-- 模块：预制体 / fishschoolspawnblocker（建筑与容器）
-- 职责：实体「fishschoolspawnblocker」的预制体定义。SpawnPrefab("fishschoolspawnblocker") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local function ontimerdone(inst)
	inst:Remove()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("herd")
    --V2C: Don't use CLASSIFIED because schoolspawner use FindEntities on "fishschoolspawnblocker" tag
    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")

    inst:AddTag("fishschoolspawnblocker")

	inst:AddComponent("timer")
    inst:ListenForEvent("timerdone", ontimerdone)
    inst.components.timer:StartTimer("remove", TUNING.SCHOOL_SPAWNER_BLOCKER_LIFETIME)

    return inst
end

return Prefab("fishschoolspawnblocker", fn)
