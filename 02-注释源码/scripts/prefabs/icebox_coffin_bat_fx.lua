--============================================================
-- 文件：prefabs/icebox_coffin_bat_fx.lua
-- 模块：预制体 / icebox_coffin_bat_fx（建筑与容器）
-- 职责：实体「icebox_coffin_bat_fx」的预制体定义。SpawnPrefab("icebox_coffin_bat_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local easing = require("easing")

local assets =
{
    Asset("ANIM", "anim/bat_tree_fx.zip"),
    Asset("DYNAMIC_ANIM", "anim/dynamic/icebox_coffin.zip"),
}

local function DoFlutterSound(inst, intensity)
    inst.SoundEmitter:PlaySound("dontstarve/creatures/bat/flap", nil, easing.outQuad(intensity, 0, 1, 1))
    if intensity > .12 then
        inst:DoTaskInTime(math.random(5, 6) * FRAMES, DoFlutterSound, intensity - .12)
    end
end

local function PlayBatFX(proxy)
    if proxy.variation:value() > 0 then
        local inst = CreateEntity()

        --[[Non-networked entity]]
        inst.entity:SetCanSleep(false)
        inst.persists = false

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()

        inst.Transform:SetFromProxy(proxy.GUID)

        inst.AnimState:SetBank("icebox_coffin")
        inst.AnimState:SetBuild("bat_tree_fx")
        inst.AnimState:PlayAnimation("bat"..tostring(proxy.variation:value()))
        inst.AnimState:SetFinalOffset(1)

        DoFlutterSound(inst, 1)

        inst:AddTag("FX")
        inst:AddTag("NOCLICK")

        inst:ListenForEvent("animover", inst.Remove)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.variation = net_tinybyte(inst.GUID, "icebox_coffin_bat_fx.variation")

    --Dedicated server does not need to spawn the local fx
    if not TheNet:IsDedicated() then
        inst:DoTaskInTime(0, PlayBatFX)
    end

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.variation:set(math.random(3))
    inst:DoTaskInTime(1, inst.Remove)
    inst.persists = false

    return inst
end

return Prefab("icebox_coffin_bat_fx", fn, assets)
