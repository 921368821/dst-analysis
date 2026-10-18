--============================================================
-- 文件：prefabs/writeable_classified.lua
-- 模块：预制体 / writeable_classified（建筑与容器）
-- 职责：实体「writeable_classified」的预制体定义。SpawnPrefab("writeable_classified") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--Client interface
--------------------------------------------------------------------------

local function OnRemoveEntity(inst)
    if inst._parent ~= nil then
        inst._parent.writeable_classified = nil
    end
end

local function OnEntityReplicated(inst)
    inst._parent = inst.entity:GetParent()
    if inst._parent == nil then
        print("Unable to initialize classified data for writeable")
	elseif not inst._parent:TryAttachClassifiedToReplicaComponent(inst, "writeable") then
        inst._parent.writeable_classified = inst
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

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        --Client interface
        inst.OnEntityReplicated = OnEntityReplicated

        return inst
    end

    inst.persists = false

    return inst
end

return Prefab("writeable_classified", fn)
