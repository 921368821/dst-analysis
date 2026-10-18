--============================================================
-- 文件：prefabs/glasscutter.lua
-- 模块：预制体 / glasscutter（建筑与容器）
-- 职责：实体「glasscutter」的预制体定义。SpawnPrefab("glasscutter") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/glasscutter.zip"),
    Asset("ANIM", "anim/swap_glasscutter.zip"),
}

local function onequip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_object", skin_build, "swap_glasscutter", inst.GUID, "swap_glasscutter")
    else
        owner.AnimState:OverrideSymbol("swap_object", "swap_glasscutter", "swap_glasscutter")
    end
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")

    if inst.skin_equip_sound and owner.SoundEmitter then
        owner.SoundEmitter:PlaySound(inst.skin_equip_sound)
    end
end

local function onunequip(inst, owner)
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("unequipskinneditem", inst:GetSkinName())
    end
end

local function onattack(inst, attacker, target)
	inst.components.weapon.attackwear = target ~= nil and target:IsValid()
		and target:HasAnyTag(PURE_SHADOW_TARGET_TAGS)
		and TUNING.GLASSCUTTER.SHADOW_WEAR
		or 1
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("glasscutter")
    inst.AnimState:SetBuild("glasscutter")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("sharp")
    inst:AddTag("pointy")

    local floater_swap_data = {sym_build = "swap_glasscutter"}
    MakeInventoryFloatable(inst, "med", 0.05, {1.21, 0.4, 1.21}, true, -22, floater_swap_data)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("weapon")
    inst.components.weapon:SetDamage(TUNING.GLASSCUTTER.DAMAGE)
	inst.components.weapon:SetOnAttack(onattack)

    local damagetypebonus = inst:AddComponent("damagetypebonus")
	damagetypebonus:AddBonus("shadowsubmissive", inst, TUNING.GLASSCUTTER.DAMAGE_VS_SHADOW_BONUS)

    -------

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.GLASSCUTTER.USES)
    inst.components.finiteuses:SetUses(TUNING.GLASSCUTTER.USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("equippable")
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("glasscutter", fn, assets)