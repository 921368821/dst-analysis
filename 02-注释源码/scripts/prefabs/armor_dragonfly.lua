--============================================================
-- 文件：prefabs/armor_dragonfly.lua
-- 模块：预制体 / armor_dragonfly（建筑与容器）
-- 职责：实体「armor_dragonfly」的预制体定义。SpawnPrefab("armor_dragonfly") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/torso_dragonfly.zip"),
}

local function OnBlocked(owner, data)
    owner.SoundEmitter:PlaySound("dontstarve/wilson/hit_scalemail")
    if data.attacker ~= nil and
        not (data.attacker.components.health ~= nil and data.attacker.components.health:IsDead()) and
        (data.weapon == nil or ((data.weapon.components.weapon == nil or data.weapon.components.weapon.projectile == nil) and data.weapon.components.projectile == nil)) and
        data.attacker.components.burnable ~= nil and
        not data.redirected and
        not data.attacker:HasTag("thorny") then
        data.attacker.components.burnable:Ignite(nil,nil,owner)
    end
end

local function onequip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_body", skin_build, "swap_body", inst.GUID, "torso_dragonfly")
    else
        owner.AnimState:OverrideSymbol("swap_body", "torso_dragonfly", "swap_body")
    end

    inst:ListenForEvent("blocked", OnBlocked, owner)
    inst:ListenForEvent("attacked", OnBlocked, owner)

    if owner.components.health ~= nil then
        owner.components.health.externalfiredamagemultipliers:SetModifier(inst, 1 - TUNING.ARMORDRAGONFLY_FIRE_RESIST)
    end
end

local function onunequip(inst, owner)
    owner.AnimState:ClearOverrideSymbol("swap_body")

    inst:RemoveEventCallback("blocked", OnBlocked, owner)
    inst:RemoveEventCallback("attacked", OnBlocked, owner)

    if owner.components.health ~= nil then
        owner.components.health.externalfiredamagemultipliers:RemoveModifier(inst)
    end

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

    inst.AnimState:SetBank("torso_dragonfly")
    inst.AnimState:SetBuild("torso_dragonfly")
    inst.AnimState:PlayAnimation("anim")

    local swap_data = {bank = "torso_dragonfly", anim = "anim"}
    MakeInventoryFloatable(inst, "small", 0.2, 0.80, nil, nil, swap_data)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("armor")
    inst.components.armor:InitCondition(TUNING.ARMORDRAGONFLY, TUNING.ARMORDRAGONFLY_ABSORPTION)

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY
    inst.components.equippable.dapperness = TUNING.DAPPERNESS_MED

    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("armordragonfly", fn, assets)
