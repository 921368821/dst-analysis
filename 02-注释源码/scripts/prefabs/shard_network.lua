--============================================================
-- 文件：prefabs/shard_network.lua
-- 模块：预制体 / shard_network（建筑与容器）
-- 职责：实体「shard_network」的预制体定义。SpawnPrefab("shard_network") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function PostInit(inst)
    inst:LongUpdate(0)
    inst.entity:FlushLocalDirtyNetVars()

    for k, v in pairs(inst.components) do
        if v.OnPostInit ~= nil then
            v:OnPostInit()
        end
    end
end

local function OnRemoveEntity(inst)
    if TheWorld ~= nil then
        assert(TheWorld.shard == inst)
        TheWorld.shard = nil
    end
end

local function fn()
    local inst = CreateEntity()

    assert(TheWorld ~= nil and TheWorld.shard == nil and TheWorld.ismastersim)
    TheWorld.shard = inst

    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddShardNetwork()
    inst:AddTag("CLASSIFIED")
    inst.entity:SetPristine()

    inst:AddComponent("shard_clock")
    inst:AddComponent("shard_seasons")
    inst:AddComponent("shard_sinkholes")
    inst:AddComponent("shard_players")
    inst:AddComponent("shard_worldreset")
    inst:AddComponent("shard_worldvoter")
    inst:AddComponent("shard_autosaver")
    inst:AddComponent("shard_daywalkerspawner")
    inst:AddComponent("shard_mermkingwatcher")
    inst:AddComponent("shard_wagbossinfo")

    inst.OnRemoveEntity = OnRemoveEntity

    inst:DoTaskInTime(0, PostInit)

    return inst
end

return Prefab("shard_network", fn)
