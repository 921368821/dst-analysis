--============================================================
-- 文件：prefabs/shadowheart.lua
-- 模块：预制体 / shadowheart（建筑与容器）
-- 职责：实体「shadowheart」的预制体定义。SpawnPrefab("shadowheart") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local WX78Common = require("prefabs/wx78_common")

local assets =
{
    Asset("ANIM", "anim/shadowheart.zip"),
}

local function beat(inst)
    inst.AnimState:PlayAnimation("idle")
    inst.SoundEmitter:PlaySound("dontstarve/sanity/shadow_heart")
    inst.beattask = inst:DoTaskInTime(.75 + math.random() * .75, beat)
end

local function ondropped(inst)
    if inst.beattask ~= nil then
        inst.beattask:Cancel()
    end
    inst.beattask = inst:DoTaskInTime(.75 + math.random() * .75, beat)
end

local function onpickup(inst)
    if inst.beattask ~= nil then
        inst.beattask:Cancel()
        inst.beattask = nil
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("shadowheart")
    inst.AnimState:SetBuild("shadowheart")
    inst.AnimState:PlayAnimation("idle")
    --inst.AnimState:SetMultColour(1, 1, 1, 0.5)

    MakeInventoryFloatable(inst, "small", 0.05, 0.8)

    inst:AddTag("shadowheart")

    MakeItemSocketable_Client(inst, SOCKETNAMES.SHADOW)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    WX78Common.MakeItemSocketable(inst)
    inst.components.socketable:SetSocketQuality(SOCKETQUALITY.HIGH)

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetOnDroppedFn(ondropped)
    inst.components.inventoryitem:SetOnPutInInventoryFn(onpickup)

    inst:AddComponent("inspectable")
    inst:AddComponent("tradable")

    MakeHauntableLaunch(inst)

    inst.beattask = nil
    ondropped(inst)

    return inst
end

return Prefab("shadowheart", fn, assets)
