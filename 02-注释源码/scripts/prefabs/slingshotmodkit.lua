--============================================================
-- 文件：prefabs/slingshotmodkit.lua
-- 模块：预制体 / slingshotmodkit（建筑与容器）
-- 职责：实体「slingshotmodkit」的预制体定义。SpawnPrefab("slingshotmodkit") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/slingshot_mod_kit.zip"),
}

local function ResetInUse(inst)
	inst.components.useabletargeteditem:StopUsingItem()
end

local function OnUsed(inst, target, user)
	local success, reason = inst.components.slingshotmodder:StartModding(target, user)
	if success then
		--We don't need to lock this item as "inuse"
		inst:DoStaticTaskInTime(0, ResetInUse)
	end
	return success, reason
end

local function UseableTargetedItem_ValidTarget(inst, target, doer)
	--component exists on clients
	return target.components.slingshotmods and target.components.slingshotmods:CanBeOpenedBy(doer)
end

local FLOATABLE_SCALE = { 1.1, 0.6, 1.1 }

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst.AnimState:SetBank("slingshot_mod_kit")
	inst.AnimState:SetBuild("slingshot_mod_kit")
	inst.AnimState:PlayAnimation("idle")

	inst:AddTag("slingshotmodkit")

	--useabletargeteditem_mounted (from useabletargeteditem component) added to pristine state for optimization
	inst:AddTag("useabletargeteditem_mounted")

	MakeInventoryPhysics(inst)
	MakeInventoryFloatable(inst, "med", .05, FLOATABLE_SCALE)

	inst.UseableTargetedItem_ValidTarget = UseableTargetedItem_ValidTarget

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inspectable")
	inst:AddComponent("inventoryitem")

	inst:AddComponent("useabletargeteditem")
	inst.components.useabletargeteditem:SetOnUseFn(OnUsed)
	inst.components.useabletargeteditem:SetUseableMounted(true)

	inst:AddComponent("slingshotmodder")

	MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
	MakeSmallPropagator(inst)
	MakeHauntableLaunch(inst)

	return inst
end

return Prefab("slingshotmodkit", fn, assets)
