--============================================================
-- 文件：prefabs/rope.lua
-- 模块：预制体 / rope（建筑与容器）
-- 职责：实体「rope」的预制体定义。SpawnPrefab("rope") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/rope.zip"),
}

local function ResetInUse(inst)
    inst.components.useabletargeteditem:StopUsingItem()
end

local function OnUsedRope(inst, target, doer)
    if target.OnUsedRope then
        local success, reason = target:OnUsedRope(inst, doer)
        if inst:IsValid() then
            --We don't need to lock this item as "inuse"
            inst:DoStaticTaskInTime(0, ResetInUse)
        end
        if success then
            return true
        end
        return success, reason
    end
    return false
end

local function UseableTargetedItem_ValidTarget(inst, target, doer)
    return target:HasTag("canrope")
end

local function GetUseItemOnVerb(inst, target, doer)
    return "TIE_ONTO"
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("rope")
    inst.AnimState:SetBuild("rope")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "cloth"

    inst:AddTag("cattoy")

    MakeInventoryFloatable(inst, "small", 0.05)

    inst.UseableTargetedItem_ValidTarget = UseableTargetedItem_ValidTarget
    inst.GetUseItemOnVerb = GetUseItemOnVerb

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

    inst:AddComponent("inspectable")
    inst:AddComponent("stackable")

    MakeSmallBurnable(inst, TUNING.LARGE_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndIgnite(inst)

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL

    inst:AddComponent("tradable")

    local useabletargeteditem = inst:AddComponent("useabletargeteditem")
    useabletargeteditem:SetOnUseFn(OnUsedRope)

    return inst
end

return Prefab("rope", fn, assets)
