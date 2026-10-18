--============================================================
-- 文件：prefabs/woby_treat.lua
-- 模块：预制体 / woby_treat（建筑与容器）
-- 职责：实体「woby_treat」的预制体定义。SpawnPrefab("woby_treat") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/woby_treat.zip"),
}

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	MakeInventoryPhysics(inst)

	inst.AnimState:SetBank("woby_treat")
	inst.AnimState:SetBuild("woby_treat")
	inst.AnimState:PlayAnimation("idle")

	inst:AddTag("meat")
	inst:AddTag("quickeat")
	inst:AddTag("monstermeat")
	inst:AddTag("quickfeed")
	inst:AddTag("pet_treat")

	MakeInventoryFloatable(inst, "small", 0.19, { 0.7, 0.9, 1 })

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inspectable")
	inst:AddComponent("inventoryitem")

	inst:AddComponent("stackable")
	inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

	inst:AddComponent("edible")
	inst.components.edible.ismeat = true
	inst.components.edible.foodtype = FOODTYPE.MEAT
	inst.components.edible.secondaryfoodtype = FOODTYPE.MONSTER
	inst.components.edible.healthvalue = -TUNING.HEALING_TINY
	inst.components.edible.hungervalue = TUNING.CALORIES_TINY
	inst.components.edible.sanityvalue = -TUNING.SANITY_TINY

	inst:AddComponent("tradable")
	inst.components.tradable.goldvalue = 0

	MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
	MakeSmallPropagator(inst)
	MakeHauntableLaunchAndIgnite(inst)

	return inst
end

return Prefab("woby_treat", fn, assets)
