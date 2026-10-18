--============================================================
-- 文件：prefabs/armor_grass.lua
-- 模块：预制体 / armor_grass（建筑与容器）
-- 职责：实体「armor_grass」的预制体定义。SpawnPrefab("armor_grass") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/armor_grass.zip"),
}

local function OnBlocked(owner)
    owner.SoundEmitter:PlaySound("dontstarve/wilson/hit_armour")
end

local function onequip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_body", skin_build, "swap_body", inst.GUID, "armor_grass")
    else
		owner.AnimState:OverrideSymbol("swap_body", "armor_grass", "swap_body")
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

    inst.AnimState:SetBank("armor_grass")
    inst.AnimState:SetBuild("armor_grass")
    inst.AnimState:PlayAnimation("anim")

    inst:AddTag("grass")

    inst.foleysound = "dontstarve/movement/foley/grassarmour"

    local swap_data = {bank = "armor_grass", anim = "anim"}
    MakeInventoryFloatable(inst, "small", 0.2, 0.80, nil, nil, swap_data)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.LARGE_FUEL

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)

    inst:AddComponent("armor")
    inst.components.armor:InitCondition(TUNING.ARMORGRASS, TUNING.ARMORGRASS_ABSORPTION)
    inst.components.armor:AddWeakness("beaver", TUNING.BEAVER_WOOD_DAMAGE)

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY

    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("armorgrass", fn, assets)
