--============================================================
-- 文件：prefabs/reflectivevest.lua
-- 模块：预制体 / reflectivevest（建筑与容器）
-- 职责：实体「reflectivevest」的预制体定义。SpawnPrefab("reflectivevest") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/torso_reflective.zip"),
}

local function onequip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_body", skin_build, "swap_body", inst.GUID, "torso_reflective")
    else
		owner.AnimState:OverrideSymbol("swap_body", "torso_reflective", "swap_body")
    end

    inst.components.fueled:StartConsuming()
end

local function onunequip(inst, owner)
    owner.AnimState:ClearOverrideSymbol("swap_body")
    inst.components.fueled:StopConsuming()
    
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("unequipskinneditem", inst:GetSkinName())
    end
end

local function onequiptomodel(inst)
    inst.components.fueled:StopConsuming()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("reflective_vest")
    inst.AnimState:SetBuild("torso_reflective")
    inst.AnimState:PlayAnimation("anim")

    MakeInventoryPhysics(inst)

    --inst.foleysound = "dontstarve/movement/foley/trunksuit"

    --waterproofer (from waterproofer component) added to pristine state for optimization
    inst:AddTag("waterproofer")

    MakeInventoryFloatable(inst, "small", nil, 0.8)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY
    inst.components.equippable.dapperness = TUNING.DAPPERNESS_SMALL
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)
    inst.components.equippable:SetOnEquipToModel(onequiptomodel)

    inst:AddComponent("fueled")
    inst.components.fueled.fueltype = FUELTYPE.USAGE
    inst.components.fueled:InitializeFuelLevel(TUNING.REFLECTIVEVEST_PERISHTIME)
    inst.components.fueled:SetDepletedFn(inst.Remove)

    inst:AddComponent("insulator")
    inst.components.insulator:SetInsulation(TUNING.INSULATION_MED)
    inst.components.insulator:SetSummer()

    inst:AddComponent("waterproofer")
    inst.components.waterproofer:SetEffectiveness(TUNING.WATERPROOFNESS_SMALL)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("reflectivevest", fn, assets)