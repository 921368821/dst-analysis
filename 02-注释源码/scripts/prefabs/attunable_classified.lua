--============================================================
-- 文件：prefabs/attunable_classified.lua
-- 模块：预制体 / attunable_classified（建筑与容器）
-- 职责：实体「attunable_classified」的预制体定义。SpawnPrefab("attunable_classified") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnRemoveEntity(inst)
    if inst._parent ~= nil and inst._parent.components.attuner ~= nil then
        inst._parent.components.attuner:UnregisterAttunedSource(inst)
    end
end

local function RegisterAttunableToPlayer(inst)
    inst._parent = inst.entity:GetParent()
    if inst._parent == nil then
        print("Unable to initialize classified data for attunable")
    elseif inst._parent.components.attuner ~= nil then
        inst._parent.components.attuner:RegisterAttunedSource(inst)
        inst.OnRemoveEntity = OnRemoveEntity
    end
end

local function AttachToPlayer(inst, player, source)
    inst.Network:SetClassifiedTarget(player)
    inst.entity:SetParent(player.entity)
    inst.source_guid:set(source.GUID)
    RegisterAttunableToPlayer(inst)
end

local function IsAttunableType(inst, tag)
    return inst:HasTag(tag)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddNetwork()
    inst.entity:Hide()
    inst:AddTag("CLASSIFIED")

    inst.source_guid = net_uint(inst.GUID, "attunable.source_guid")

    inst.entity:SetPristine()

    inst._parent = nil

    inst.IsAttunableType = IsAttunableType

    if not TheWorld.ismastersim then
        --Delay registration until after initial values are deserialized
        inst:DoTaskInTime(0, RegisterAttunableToPlayer)
        return inst
    end

    inst.persists = false

    inst.AttachToPlayer = AttachToPlayer

    return inst
end

return Prefab("attunable_classified", fn)
