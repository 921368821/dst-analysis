--============================================================
-- 文件：prefabs/pumpkincarver.lua
-- 模块：预制体 / pumpkincarver（建筑与容器）
-- 职责：实体「pumpkincarver」的预制体定义。SpawnPrefab("pumpkincarver") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/pumpkincarver.zip"),
}

local FLOATER_SCALE = { 1.2, 1, 1.2 }

local function MakeCarver(id)
	local function fn()
		local inst = CreateEntity()

		inst.entity:AddTransform()
		inst.entity:AddAnimState()
		inst.entity:AddNetwork()

		MakeInventoryPhysics(inst)

		inst.AnimState:SetBank("pumpkincarver")
		inst.AnimState:SetBuild("pumpkincarver")
		inst.AnimState:PlayAnimation("carver"..tostring(id))

		inst:AddTag("donotautopick")

		MakeInventoryFloatable(inst, "small", 0.15, FLOATER_SCALE)

		inst.entity:SetPristine()

		if not TheWorld.ismastersim then
			return inst
		end

		inst.scrapbook_specialinfo = "PUMPKINCARVER"

		inst:AddComponent("inventoryitem")
		inst:AddComponent("pumpkincarver")

		inst:AddComponent("inspectable")
        inst.components.inspectable:SetNameOverride("pumpkincarver")

		MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
		MakeSmallPropagator(inst)

		MakeHauntableLaunch(inst)

		return inst
	end

	return Prefab("pumpkincarver"..tostring(id), fn, assets)
end

local ret = {}

for i = 1, NUM_HALLOWEEN_PUMPKINCARVERS do
    table.insert(ret, MakeCarver(i))
end

return unpack(ret)
