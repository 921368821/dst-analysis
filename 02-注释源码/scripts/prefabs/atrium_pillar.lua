--============================================================
-- 文件：prefabs/atrium_pillar.lua
-- 模块：预制体 / atrium_pillar（建筑与容器）
-- 职责：实体「atrium_pillar」的预制体定义。SpawnPrefab("atrium_pillar") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pillar_atrium.zip"),
}

local function OnPoweredFn(inst, ispowered)
    inst.AnimState:PlayAnimation(ispowered and "idle_active" or "idle", ispowered)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeObstaclePhysics(inst, 2.5)
    inst.Physics:SetCylinder(2.35, 6)

    inst.AnimState:SetBank("pillar_atrium")
    inst.AnimState:SetBuild("pillar_atrium")
    inst.AnimState:PlayAnimation("idle", true)

    inst:AddTag("groundhole")
    inst:AddTag("pillar_atrium")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:ListenForEvent("atriumpowered", function(_, ispowered) OnPoweredFn(inst, ispowered) end, TheWorld)

    return inst
end

return Prefab("pillar_atrium", fn, assets)
