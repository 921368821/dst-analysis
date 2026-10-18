--============================================================
-- 文件：prefabs/saddlehorn.lua
-- 模块：预制体 / saddlehorn（建筑与容器）
-- 职责：实体「saddlehorn」的预制体定义。SpawnPrefab("saddlehorn") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/saddlehorn.zip"),
    Asset("ANIM", "anim/swap_saddlehorn.zip"),
}

local function onequip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_object", "swap_saddlehorn", "swap_saddlehorn")
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

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("saddlehorn")
    inst.AnimState:SetBuild("saddlehorn")
    inst.AnimState:PlayAnimation("idle")

    --weapon (from weapon component) added to pristine state for optimization
    inst:AddTag("weapon")

    MakeInventoryFloatable(inst, "med")

    inst.scrapbook_subcat = "tool"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("weapon")
    inst.components.weapon:SetDamage(TUNING.SADDLEHORN_DAMAGE)
    inst.components.weapon.attackwear = 3

    inst:AddComponent("unsaddler")

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.SADDLEHORN_USES)
    inst.components.finiteuses:SetUses(TUNING.SADDLEHORN_USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)
    inst.components.finiteuses:SetConsumption(ACTIONS.UNSADDLE, 1)

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("equippable")
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("saddlehorn", fn, assets)
