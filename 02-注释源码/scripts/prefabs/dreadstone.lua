--============================================================
-- 文件：prefabs/dreadstone.lua
-- 模块：预制体 / dreadstone（建筑与容器）
-- 职责：实体「dreadstone」的预制体定义。SpawnPrefab("dreadstone") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/dreadstone.zip"),
}

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	MakeInventoryPhysics(inst)

	inst.AnimState:SetBank("dreadstone")
	inst.AnimState:SetBuild("dreadstone")
	inst.AnimState:PlayAnimation("idle")

	inst.pickupsound = "rock"

	MakeInventoryFloatable(inst, "med", .145, { .77, .75, .77 })

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("tradable")

	inst:AddComponent("stackable")
	inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

	inst:AddComponent("inspectable")

	inst:AddComponent("inventoryitem")

	inst:AddComponent("repairer")
	inst.components.repairer.repairmaterial = MATERIALS.DREADSTONE
	inst.components.repairer.healthrepairvalue = TUNING.REPAIR_DREADSTONE_HEALTH
	inst.components.repairer.workrepairvalue = TUNING.REPAIR_DREADSTONE_WORK

	MakeHauntableLaunchAndSmash(inst)

	return inst
end

return Prefab("dreadstone", fn, assets)
