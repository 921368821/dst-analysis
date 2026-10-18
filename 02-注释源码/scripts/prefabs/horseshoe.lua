--============================================================
-- 文件：prefabs/horseshoe.lua
-- 模块：预制体 / horseshoe（建筑与容器）
-- 职责：实体「horseshoe」的预制体定义。SpawnPrefab("horseshoe") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/horseshoe.zip"),
}

local function DoShine(inst)
	inst.shinetask = nil
    if not inst.AnimState:IsCurrentAnimation("sparkle") then
        inst.AnimState:PlayAnimation("sparkle")
        inst.AnimState:PushAnimation("idle", false)
    end
	if not inst:IsAsleep() then
		inst.shinetask = inst:DoTaskInTime(4 + math.random() * 5, DoShine)
	end
end

local function OnEntityWake(inst)
	if inst.shinetask == nil then
		inst.shinetask = inst:DoTaskInTime(4 + math.random() * 5, DoShine)
	end
end

local function GetLuckFn(inst, owner)
    local mult = IsSpecialEventActive(SPECIAL_EVENTS.YOTH) and TUNING.HORSESHOE_EVENT_LUCK_MULTIPLIER or 1
    return (
        (owner and EntityHasSetBonus(owner, EQUIPMENTSETNAMES.YOTH_KNIGHT)) and TUNING.HORSESHOE_SETBONUS_LUCK
        or TUNING.HORSESHOE_LUCK
    ) * mult
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("horseshoe")
    inst.AnimState:SetBuild("horseshoe")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "metal"

	inst:AddTag("luckyitem")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM

    inst:AddComponent("luckitem")
    inst.components.luckitem:SetLuck(GetLuckFn)

    MakeHauntableLaunch(inst)

    DoShine(inst)
	inst.OnEntityWake = OnEntityWake

    return inst
end

return Prefab("horseshoe", fn, assets)