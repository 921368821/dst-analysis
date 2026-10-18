--============================================================
-- 文件：prefabs/beeswax.lua
-- 模块：预制体 / beeswax（建筑与容器）
-- 职责：实体「beeswax」的预制体定义。SpawnPrefab("beeswax") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/beeswax.zip"),
}

local function _OnFireMelt(inst, StartFireMelt, StopFireMelt)
    inst.firemelttask = nil
    inst:RemoveEventCallback("firemelt", StartFireMelt)
    inst:RemoveEventCallback("stopfiremelt", StopFireMelt)
    if not inst.melted then
        if inst:IsAsleep() then
            inst:Remove()
        else
            inst.melted = true
            inst.persists = false
            inst.components.inventoryitem.canbepickedup = false
            inst:AddTag("NOCLICK")
            inst.AnimState:PlayAnimation("melt")
            inst:ListenForEvent("animover", inst.Remove)
            inst:ListenForEvent("entitysleep", inst.Remove)
        end
    end
end

local function StopFireMelt(inst)
    if inst.firemelttask ~= nil then
        inst.firemelttask:Cancel()
        inst.firemelttask = nil
    end
end

local function StartFireMelt(inst)
    if inst.firemelttask == nil then
        inst.firemelttask = inst:DoTaskInTime(10, _OnFireMelt, StartFireMelt, StopFireMelt)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBuild("beeswax")
    inst.AnimState:SetBank("beeswax")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("meltable")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("wax")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:ListenForEvent("firemelt", StartFireMelt)
    inst:ListenForEvent("stopfiremelt", StopFireMelt)
    inst:ListenForEvent("onputininventory", StopFireMelt)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("beeswax", fn, assets)
