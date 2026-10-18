--============================================================
-- 文件：prefabs/armor_ruins.lua
-- 模块：预制体 / armor_ruins（建筑与容器）
-- 职责：实体「armor_ruins」的预制体定义。SpawnPrefab("armor_ruins") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("prefabs/amulet")

local assets =
{
    Asset("ANIM", "anim/armor_ruins.zip"),
}

local function OnBlocked(owner)
    owner.SoundEmitter:PlaySound("dontstarve/wilson/hit_armour")
end

local function onequip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_body", skin_build, "swap_body", inst.GUID, "armor_ruins")
    else
		owner.AnimState:OverrideSymbol("swap_body", "armor_ruins", "swap_body")
    end

    inst:ListenForEvent("blocked", OnBlocked, owner)
end

local function onunequip(inst, owner)
    owner.AnimState:ClearOverrideSymbol("swap_body")
    inst:RemoveEventCallback("blocked", OnBlocked, owner)

    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("unequipskinneditem", inst:GetSkinName())
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("armor_ruins")
    inst.AnimState:SetBuild("armor_ruins")
    inst.AnimState:PlayAnimation("anim")

    inst:AddTag("ruins")
    inst:AddTag("metal")
	inst:AddTag("hardarmor")

	--shadowlevel (from shadowlevel component) added to pristine state for optimization
	inst:AddTag("shadowlevel")

    inst.foleysound = "dontstarve/movement/foley/metalarmour"

    local swap_data = {bank = "armor_ruins", anim = "anim"}
    MakeInventoryFloatable(inst, "small", 0.2, 0.80, nil, nil, swap_data)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("armor")
    inst.components.armor:InitCondition(TUNING.ARMORRUINS, TUNING.ARMORRUINS_ABSORPTION)

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY
    inst.components.equippable.dapperness = TUNING.DAPPERNESS_MED
    inst.components.equippable.is_magic_dapperness = true

    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

	inst:AddComponent("shadowlevel")
	inst.components.shadowlevel:SetDefaultLevel(TUNING.ARMORRUINS_SHADOW_LEVEL)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("armorruins", fn, assets)
