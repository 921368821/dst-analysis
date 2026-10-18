--============================================================
-- 文件：prefabs/quagmire_parkspike.lua
-- 模块：预制体 / quagmire_parkspike（建筑与容器）
-- 职责：实体「quagmire_parkspike」的预制体定义。SpawnPrefab("quagmire_parkspike") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_park_fence.zip"),
}

local function InitializePathFinding(inst)
    if inst._pfpos == nil then
        inst._pfpos = inst:GetPosition()
        TheWorld.Pathfinder:AddWall(inst._pfpos:Get())
    end
end

local function OnRemoveEntity(inst)
    TheWorld.Pathfinder:RemoveWall(inst._pfpos:Get())
    inst._pfpos = nil
end

local function fn(anim)
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("quagmire_park_fence")
    inst.AnimState:SetBuild("quagmire_park_fence")
    inst.AnimState:PlayAnimation(anim)

    MakeObstaclePhysics(inst, .2)

    inst.entity:SetPristine()
    inst.OnRemoveEntity = OnRemoveEntity

    inst:SetPrefabNameOverride("quagmire_parkspike")

    inst:DoTaskInTime(0, InitializePathFinding)

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    return inst
end

local function tallfn()
    return fn("idle")
end

local function shortfn()
    return fn("idle_short")
end

return Prefab("quagmire_parkspike", tallfn, assets),
    Prefab("quagmire_parkspike_short", shortfn, assets)
