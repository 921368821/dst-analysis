--============================================================
-- 文件：prefabs/wx78_mimicspawner.lua
-- 模块：预制体 / wx78_mimicspawner（建筑与容器）
-- 职责：实体「wx78_mimicspawner」的预制体定义。SpawnPrefab("wx78_mimicspawner") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local prefabs = {
    "itemmimic_revealed",
}

local function MimicDensityFilter(inst, ent)
    return ent.components.itemmimic ~= nil
end

local function MimicSpawn(inst, ent)
    ent:SetNoLoot(true)
    if ent.components.knownlocations then
        ent.components.knownlocations:RememberLocation("leash", inst:GetPosition())
    end
    ent:PushEvent("jump")
end

local MIMIC_MUST_TAGS = {"itemmimic_revealed"}

local function OnRemoved(inst)
    local x, y, z = inst.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, TUNING.SKILLS.WX78.MIMICHEART_SPAWN_DENSITY_RANGE, MIMIC_MUST_TAGS)
    for _, ent in ipairs(ents) do
        if ent:IsValid() and ent:GetNoLoot() then
            ent.components.health:Kill()
        end
    end
end

local function fn()
	local inst = CreateEntity()

    if not TheWorld.ismastersim then
        --Not meant for client!
        inst:DoTaskInTime(0, inst.Remove)

        return inst
    end

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst.entity:Hide()
    inst:AddTag("CLASSIFIED")

    local periodicspawner = inst:AddComponent("periodicspawner")
    periodicspawner:SetPrefab("itemmimic_revealed")
    periodicspawner:SetRandomTimes(TUNING.SKILLS.WX78.MIMICHEART_SPAWN_PERIOD, TUNING.SKILLS.WX78.MIMICHEART_SPAWN_VARIANCE)
    periodicspawner:SetDensityInRange(TUNING.SKILLS.WX78.MIMICHEART_SPAWN_DENSITY_RANGE, TUNING.SKILLS.WX78.MIMICHEART_SPAWN_DENSITY_MAX)
    periodicspawner:SetDensityFilterFn(MimicDensityFilter)
    periodicspawner:SetOnSpawnFn(MimicSpawn)
    periodicspawner:Start()

    inst.persists = false

    inst.OnRemoveEntity = OnRemoved

    return inst
end

return Prefab("wx78_mimicspawner", fn, nil, prefabs)