--============================================================
-- 文件：prefabs/tentaclespike.lua
-- 模块：预制体 / tentaclespike（建筑与容器）
-- 职责：实体「tentaclespike」的预制体定义。SpawnPrefab("tentaclespike") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/tentacle_spike.zip"),
    Asset("ANIM", "anim/swap_spike.zip"),
}

local function onequip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_object", "swap_spike", "swap_spike")
    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
end

local function onunequip(inst, owner)
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("spike")
    inst.AnimState:SetBuild("tentacle_spike")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("sharp")

    --weapon (from weapon component) added to pristine state for optimization
    inst:AddTag("weapon")

    MakeInventoryPhysics(inst)

    local swap_data = {sym_build = "swap_spike", bank = "spike"}
    MakeInventoryFloatable(inst, "med", 0.05, {0.9, 0.5, 0.9}, true, -17, swap_data)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("weapon")
    inst.components.weapon:SetDamage(TUNING.SPIKE_DAMAGE)

    -------

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.SPIKE_USES)
    inst.components.finiteuses:SetUses(TUNING.SPIKE_USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("equippable")
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("tentaclespike", fn, assets)
