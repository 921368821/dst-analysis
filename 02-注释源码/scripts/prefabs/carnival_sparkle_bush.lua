--============================================================
-- 文件：prefabs/carnival_sparkle_bush.lua
-- 模块：预制体 / carnival_sparkle_bush（建筑与容器）
-- 职责：实体「carnival_sparkle_bush」的预制体定义。SpawnPrefab("carnival_sparkle_bush") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/carnival_sparkle_bush.zip"),
}

local prefs = {}

local function PlayAnim(proxy, anim, scale, flip)
    local inst = CreateEntity()

    inst:AddTag("FX")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.Transform:SetFromProxy(proxy.GUID)

    inst.AnimState:SetBank("carnival_sparkle_bush")
    inst.AnimState:SetBuild("carnival_sparkle_bush")
    local scale = 0.75
    inst.AnimState:SetScale(scale, scale)
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetFinalOffset(1)
    
    inst:ListenForEvent("onremove", function() inst:Remove() end, proxy )

    proxy.fx_ent = inst
end

local function DisableNetwork(inst) --do we need this?
    inst.Network:SetClassifiedTarget(inst)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.entity:SetPristine()

    inst.persists = false
    
    --Dedicated server does not need to spawn the local fx
    if not TheNet:IsDedicated() then
        inst:DoTaskInTime(0, PlayAnim) --before or after pristine?
    end

    return inst
end

return Prefab("carnival_sparkle_bush", fn, assets, prefs)