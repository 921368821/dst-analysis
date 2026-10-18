--============================================================
-- 文件：prefabs/constructionsite_classified.lua
-- 模块：预制体 / constructionsite_classified（建筑与容器）
-- 职责：实体「constructionsite_classified」的预制体定义。SpawnPrefab("constructionsite_classified") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ Constants ]]
--------------------------------------------------------------------------

local MAX_SLOTS = 4

--------------------------------------------------------------------------
--Server interface
--------------------------------------------------------------------------

local function SetSlotCount(inst, slot, num)
    if inst._slotcounts[slot] ~= nil then
        inst._slotcounts[slot]:set(num)
    end
end

--------------------------------------------------------------------------
--Common interface
--------------------------------------------------------------------------

local function GetSlotCount(inst, slot)
    return inst._slotcounts[slot] ~= nil and inst._slotcounts[slot]:value() or 0
end

--------------------------------------------------------------------------
--Client interface
--------------------------------------------------------------------------

local function OnRemoveEntity(inst)
    if inst._parent ~= nil then
        inst._parent.constructionsite_classified = nil
    end
end

local function OnEntityReplicated(inst)
    inst._parent = inst.entity:GetParent()
    if inst._parent == nil then
        print("Unable to initialize classified data for constructionsite")
	elseif not inst._parent:TryAttachClassifiedToReplicaComponent(inst, "constructionsite") then
        inst._parent.constructionsite_classified = inst
        inst.OnRemoveEntity = OnRemoveEntity
    end
end

--------------------------------------------------------------------------

local function fn()
    local inst = CreateEntity()

    if TheWorld.ismastersim then
        inst.entity:AddTransform() --So we can follow parent's sleep state
    end
    inst.entity:AddNetwork()
    inst.entity:Hide()
    inst:AddTag("CLASSIFIED")

    inst._slotcounts = {}
    for i = 1, MAX_SLOTS do
        inst._slotcounts[i] = net_byte(inst.GUID, "constructionsite_classified._slotcounts["..tostring(i).."]")
    end

    inst.entity:SetPristine()

    --Common interface
    inst.GetSlotCount = GetSlotCount

    if not TheWorld.ismastersim then
        --Client interface
        inst.OnEntityReplicated = OnEntityReplicated

        return inst
    end

    --Server interface
    inst.SetSlotCount = SetSlotCount

    inst.persists = false

    return inst
end

return Prefab("constructionsite_classified", fn)
