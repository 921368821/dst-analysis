--============================================================
-- 文件：prefabs/sweatervest.lua
-- 模块：预制体 / sweatervest（建筑与容器）
-- 职责：实体「sweatervest」的预制体定义。SpawnPrefab("sweatervest") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/armor_sweatervest.zip"),
}

local function onequip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_body", "armor_sweatervest", "swap_body")
    inst.components.fueled:StartConsuming()
end

local function onunequip(inst, owner)
    owner.AnimState:ClearOverrideSymbol("swap_body")
    inst.components.fueled:StopConsuming()
end

local function onequiptomodel(inst)
    inst.components.fueled:StopConsuming()
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    MakeInventoryFloatable(inst, "small", 0.1, 0.8)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.AnimState:SetBank("armor_sweatervest")
    inst.AnimState:SetBuild("armor_sweatervest")
    inst.AnimState:PlayAnimation("anim")

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst:AddComponent("tradable")

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY
    inst.components.equippable.dapperness = TUNING.DAPPERNESS_MED

    inst.components.equippable:SetOnEquip( onequip )
    inst.components.equippable:SetOnUnequip( onunequip )
    inst.components.equippable:SetOnEquipToModel( onequiptomodel )

    inst:AddComponent("fueled")
    inst.components.fueled.fueltype = FUELTYPE.USAGE
    inst.components.fueled:InitializeFuelLevel(TUNING.SWEATERVEST_PERISHTIME)
    inst.components.fueled:SetDepletedFn(inst.Remove)

	inst:AddComponent("insulator")
    inst.components.insulator:SetInsulation( TUNING.INSULATION_SMALL )

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("sweatervest", fn, assets)