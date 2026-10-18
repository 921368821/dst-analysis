--============================================================
-- 文件：prefabs/armor_slurper.lua
-- 模块：预制体 / armor_slurper（建筑与容器）
-- 职责：实体「armor_slurper」的预制体定义。SpawnPrefab("armor_slurper") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/armor_slurper.zip"),
}

local function onequip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_body", "armor_slurper", "swap_body")
    if owner.components.hunger ~= nil then
        owner.components.hunger.burnratemodifiers:SetModifier(inst, TUNING.ARMORSLURPER_SLOW_HUNGER)
    end

    inst.components.fueled:StartConsuming()
end

local function onunequip(inst, owner)
    owner.AnimState:ClearOverrideSymbol("swap_body")
    if owner.components.hunger ~= nil then
        owner.components.hunger.burnratemodifiers:RemoveModifier(inst)
    end

    inst.components.fueled:StopConsuming()
end

local function onequiptomodel(inst, owner, from_ground)
    if owner.components.hunger ~= nil then
        owner.components.hunger.burnratemodifiers:RemoveModifier(inst)
    end

    inst.components.fueled:StopConsuming()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("armor_slurper")
    inst.AnimState:SetBuild("armor_slurper")
    inst.AnimState:PlayAnimation("anim")

    inst:AddTag("fur")
    inst:AddTag("ruins")

	--shadowlevel (from shadowlevel component) added to pristine state for optimization
	inst:AddTag("shadowlevel")

    inst.foleysound = "dontstarve/movement/foley/fur"

    MakeInventoryFloatable(inst, "small", 0.2, 0.80)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY
    inst.components.equippable.dapperness = TUNING.DAPPERNESS_SMALL
    inst.components.equippable.is_magic_dapperness = true

    inst:AddComponent("fueled")
    inst.components.fueled.fueltype = FUELTYPE.USAGE
    inst.components.fueled:InitializeFuelLevel(TUNING.HUNGERBELT_PERISHTIME)
    inst.components.fueled:SetDepletedFn(inst.Remove)

    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)
    inst.components.equippable:SetOnEquipToModel(onequiptomodel)

	inst:AddComponent("shadowlevel")
	inst.components.shadowlevel:SetDefaultLevel(TUNING.ARMORSLURPER_SHADOW_LEVEL)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("armorslurper", fn, assets)
