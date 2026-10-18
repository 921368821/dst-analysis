--============================================================
-- 文件：prefabs/carnival_golfclub.lua
-- 模块：预制体 / carnival_golfclub（建筑与容器）
-- 职责：实体「carnival_golfclub」的预制体定义。SpawnPrefab("carnival_golfclub") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/carnivalgame_golfclub.zip"),
}

local prefabs =
{
	"cannon_aoe_range_fx",
	"golfclub_reticulecharging",
	"golfclub_reticule_fx",
	"reticulelongping",
}

local function OnEquip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_object", skin_build, "swap_golfclub", inst.GUID, "carnivalgame_golfclub")
    else
        owner.AnimState:OverrideSymbol("swap_object", "carnivalgame_golfclub", "swap_golfclub")
    end
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
end

local function OnUnequip(inst, owner)
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("unequipskinneditem", inst:GetSkinName())
    end

	inst.components.golfclub:StopAiming()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("carnivalgame_golfclub")
    inst.AnimState:SetBuild("carnivalgame_golfclub")
    inst.AnimState:PlayAnimation("idle")

    --weapon (from weapon component) added to pristine state for optimization
    inst:AddTag("weapon")

    MakeInventoryFloatable(inst)

	inst:AddComponent("golfclub_reticule")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("equippable")
    inst.components.equippable:SetOnEquip(OnEquip)
    inst.components.equippable:SetOnUnequip(OnUnequip)

    inst:AddComponent("weapon")
    inst.components.weapon:SetDamage(TUNING.CANE_DAMAGE)

    inst:AddComponent("golfclub")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("carnivalgame_golfclub", fn, assets, prefabs)