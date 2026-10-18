--============================================================
-- 文件：prefabs/lightninggoatherd.lua
-- 模块：预制体 / lightninggoatherd（建筑与容器）
-- 职责：实体「lightninggoatherd」的预制体定义。SpawnPrefab("lightninggoatherd") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local prefabs =
{
    "lightninggoat",
}

local function CanSpawn(inst)
    return inst.components.herd ~= nil and not inst.components.herd:IsFull()
end

local function OnSpawned(inst, newent)
    if inst.components.herd ~= nil then
        inst.components.herd:AddMember(newent)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("herd")
    --V2C: Don't use CLASSIFIED because herds use FindEntities on "herd" tag
    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")

    inst:AddComponent("herd")
    inst.components.herd:SetMemberTag("lightninggoat")
	inst.components.herd:SetMaxSize(TUNING.LIGHTNINGGOATHERD_MAX_SIZE)
    inst.components.herd:SetGatherRange(40)
    inst.components.herd:SetUpdateRange(20)
    inst.components.herd:SetOnEmptyFn(inst.Remove)
    inst.components.herd.nomerging = true

    inst:AddComponent("periodicspawner")
    inst.components.periodicspawner:SetRandomTimes(TUNING.LIGHTNING_GOAT_MATING_SEASON_BABYDELAY, TUNING.LIGHTNING_GOAT_MATING_SEASON_BABYDELAY_VARIANCE)
    inst.components.periodicspawner:SetPrefab("lightninggoat")
    inst.components.periodicspawner:SetOnSpawnFn(OnSpawned)
    inst.components.periodicspawner:SetSpawnTestFn(CanSpawn)
    inst.components.periodicspawner:SetOnlySpawnOffscreen(true)
    inst.components.periodicspawner:Start()

    return inst
end

return Prefab("lightninggoatherd", fn, nil, prefabs)
