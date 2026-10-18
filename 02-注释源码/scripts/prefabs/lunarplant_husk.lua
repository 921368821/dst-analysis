--============================================================
-- 文件：prefabs/lunarplant_husk.lua
-- 模块：预制体 / lunarplant_husk（建筑与容器）
-- 职责：实体「lunarplant_husk」的预制体定义。SpawnPrefab("lunarplant_husk") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/lunarplant_husk.zip"),
}

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	MakeInventoryPhysics(inst)

	inst.AnimState:SetBank("lunarplant_husk")
	inst.AnimState:SetBuild("lunarplant_husk")
	inst.AnimState:PlayAnimation("idle")

	MakeInventoryFloatable(inst, "large", nil, 0.6)

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inspectable")
	inst:AddComponent("inventoryitem")

	inst:AddComponent("stackable")
	inst.components.stackable.maxsize = TUNING.STACK_SIZE_MEDITEM

	MakeHauntableLaunch(inst)

	return inst
end

return Prefab("lunarplant_husk", fn, assets)
