--============================================================
-- 文件：prefabs/shadowskittish.lua
-- 模块：预制体 / shadowskittish（建筑与容器）
-- 职责：实体「shadowskittish」的预制体定义。SpawnPrefab("shadowskittish") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/shadow_skittish.zip"),
}

local function Disappear(inst)
    if inst.deathtask ~= nil then
        inst.deathtask:Cancel()
        inst.deathtask = nil
        inst.AnimState:PlayAnimation("disappear")
        inst:ListenForEvent("animover", inst.Remove)
    end
end

local function fn()
    local inst = CreateEntity()

    inst:AddTag("NOCLICK")
    inst:AddTag("FX")
    inst:AddTag("NOBLOCK")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.AnimState:SetBank("shadowcreatures")
    inst.AnimState:SetBuild("shadow_skittish")
    inst.AnimState:PlayAnimation("idle_loop", true)
    inst.AnimState:SetMultColour(1, 1, 1, 0)

    inst:AddComponent("playerprox")
    inst.components.playerprox:SetDist(5, 8)
    inst.components.playerprox:SetOnPlayerNear(Disappear)

    if not TheNet:IsDedicated() then
        -- this is purely view related
        inst:AddComponent("transparentonsanity")
        inst.components.transparentonsanity:ForceUpdate()
    end

    inst.deathtask = inst:DoTaskInTime(5 + 10 * math.random(), Disappear)

    return inst
end

return Prefab("shadowskittish", fn, assets)