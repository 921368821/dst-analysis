--============================================================
-- 文件：prefabs/armor_bramble.lua
-- 模块：预制体 / armor_bramble（建筑与容器）
-- 职责：实体「armor_bramble」的预制体定义。SpawnPrefab("armor_bramble") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/armor_bramble.zip"),
}

local prefabs =
{
    "bramblefx_armor",
}

local function OnCooldown(inst)
    inst._cdtask = nil
end

local function DoThorns(inst, owner)
    --V2C: tiny CD to limit chain reactions
    inst._cdtask = inst:DoTaskInTime(.3, OnCooldown)

	if inst._hitcount then
		inst._hitcount = 0
	end

    SpawnPrefab("bramblefx_armor"):SetFXOwner(owner)

    if owner.SoundEmitter ~= nil then
        owner.SoundEmitter:PlaySound("dontstarve/common/together/armor/cactus")
    end
end

local function OnBlocked(owner, data, inst)
    if inst._cdtask == nil and data ~= nil and not data.redirected then
        DoThorns(inst, owner)
    end
end

local function OnAttackOther(owner, data, inst)
	if inst._cdtask == nil and
		owner.components.skilltreeupdater and
		owner.components.skilltreeupdater:IsActivated("wormwood_armor_bramble")
	then
        inst._hitcount = inst._hitcount + 1

        if inst._hitcount >= TUNING.WORMWOOD_ARMOR_BRAMBLE_RELEASE_SPIKES_HITCOUNT then
            DoThorns(inst, owner)
        end
	else
		inst._hitcount = 0
    end
end

local function onequip(inst, owner)
    local skin_build = inst:GetSkinBuild()
    if skin_build ~= nil then
        owner:PushEvent("equipskinneditem", inst:GetSkinName())
        owner.AnimState:OverrideItemSkinSymbol("swap_body", skin_build, "swap_body", inst.GUID, "armor_bramble")
    else
		owner.AnimState:OverrideSymbol("swap_body", "armor_bramble", "swap_body")
    end

    inst:ListenForEvent("blocked", inst._onblocked, owner)
    inst:ListenForEvent("attacked", inst._onblocked, owner)
	if owner:HasTag("plantkin") then
		inst:ListenForEvent("onattackother", inst._onattackother, owner)
	end

    inst._hitcount = 0
end

local function onunequip(inst, owner)
    owner.AnimState:ClearOverrideSymbol("swap_body")

    inst:RemoveEventCallback("blocked", inst._onblocked, owner)
    inst:RemoveEventCallback("attacked", inst._onblocked, owner)
    inst:RemoveEventCallback("onattackother", inst._onattackother, owner)

    inst._hitcount = nil

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

    inst:AddTag("bramble_resistant")

    inst.AnimState:SetBank("armor_bramble")
    inst.AnimState:SetBuild("armor_bramble")
    inst.AnimState:PlayAnimation("anim")

    inst.scrapbook_specialinfo = "ARMORBRAMBLE"
    inst.scrapbook_damage = TUNING.ARMORBRAMBLE_DMG

    inst.foleysound = "dontstarve/movement/foley/cactus_armor"

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst._hitcount = nil

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.LARGE_FUEL

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)

    inst:AddComponent("armor")
    inst.components.armor:InitCondition(TUNING.ARMORBRAMBLE, TUNING.ARMORBRAMBLE_ABSORPTION)
    inst.components.armor:AddWeakness("beaver", TUNING.BEAVER_WOOD_DAMAGE)

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY

    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)

    MakeHauntableLaunch(inst)

    inst._onblocked      = function(owner, data)     OnBlocked(owner, data, inst) end
    inst._onattackother  = function(owner, data) OnAttackOther(owner, data, inst) end

    return inst
end

return Prefab("armor_bramble", fn, assets, prefabs)
