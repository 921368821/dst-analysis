--============================================================
-- 文件：prefabs/cutless.lua
-- 模块：预制体 / cutless（建筑与容器）
-- 职责：实体「cutless」的预制体定义。SpawnPrefab("cutless") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cutless.zip"),
}

local function onequip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_object", skin_build, "cutless", inst.GUID, "swap_cutless")
    else
        owner.AnimState:OverrideSymbol("swap_object", "cutless", "swap_cutless")
    end
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
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
    inst.components.thief:StealItem(target)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("cutless")
    inst.AnimState:SetBuild("cutless")
    inst.AnimState:PlayAnimation("idle")

    --weapon (from weapon component) added to pristine state for optimization
    inst:AddTag("weapon")

    local swap_data = {sym_name = "swap_cutless", sym_build = "cutless"}
    MakeInventoryFloatable(inst, "med", 0.05, {1.1, 0.5, 1.1}, true, -18, swap_data)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("thief")

    inst:AddComponent("weapon")
    inst.components.weapon:SetDamage(TUNING.CUTLESS_DAMAGE)
    inst.components.weapon:SetOnAttack(onattack)

    -------

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL
    
    --------

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.CUTLESS_USES)
    inst.components.finiteuses:SetUses(TUNING.CUTLESS_USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("equippable")
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("cutless", fn, assets)
