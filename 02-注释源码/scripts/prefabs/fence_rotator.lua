--============================================================
-- 文件：prefabs/fence_rotator.lua
-- 模块：预制体 / fence_rotator（建筑与容器）
-- 职责：实体「fence_rotator」的预制体定义。SpawnPrefab("fence_rotator") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/fence_rotator.zip"),
}

local prefabs =
{
    "fence_rotator_fx",
}

local function onequip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_object", "fence_rotator", "swap_fence_rotator")

    owner.AnimState:Show("ARM_carry")
    owner.AnimState:Hide("ARM_normal")
end

local function onunequip(inst, owner)
    owner.AnimState:Hide("ARM_carry")
    owner.AnimState:Show("ARM_normal")
end

local function onfencerotated(inst)
    if inst.components.finiteuses then
        inst.components.finiteuses:Use(1)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("fence_rotator")
    inst.AnimState:SetBuild("fence_rotator")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("fence_rotator")
    inst:AddTag("nopunch")

    MakeInventoryFloatable(inst, "med", 0.05, {1.1, 0.5, 1.1}, true, -9)

    inst:AddTag("sharp")
    inst:AddTag("pointy")
    inst:AddTag("jab")

    --weapon (from weapon component) added to pristine state for optimization
    inst:AddTag("weapon")

    inst.scrapbook_specialinfo = "FENCEROTATOR"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.components.floater:SetBankSwapOnFloat(true, -9, { sym_build = "fence_rotator", sym_name = "swap_fence_rotator" })

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.FENCE_ROTATOR_USES)
    inst.components.finiteuses:SetUses(TUNING.FENCE_ROTATOR_USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)
    inst:ListenForEvent("fencerotated", onfencerotated)

    inst:AddComponent("weapon")
    inst.components.weapon:SetDamage(TUNING.FENCE_ROTATOR_DAMAGE)

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("fencerotator")

    inst:AddComponent("equippable")
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    return inst
end

return Prefab("fence_rotator", fn, assets, prefabs)