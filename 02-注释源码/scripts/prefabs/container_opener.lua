--============================================================
-- 文件：prefabs/container_opener.lua
-- 模块：预制体 / container_opener（建筑与容器）
-- 职责：实体「container_opener」的预制体定义。SpawnPrefab("container_opener") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnRemoveEntity(inst)
    if inst._parent ~= nil then
        inst._parent.container_opener = nil
    end
end

local function OnEntityReplicated(inst)
    inst._parent = inst.entity:GetParent()
    if inst._parent == nil then
    elseif inst._parent.replica.container ~= nil then
        inst._parent.replica.container:AttachOpener(inst)
    elseif inst._parent.components.container_proxy ~= nil then
        inst._parent.components.container_proxy:AttachOpener(inst)
    else
        inst._parent.container_opener = inst
        inst.OnRemoveEntity = OnRemoveEntity
    end
end

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

return Prefab("container_opener", fn)