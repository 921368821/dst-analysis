--============================================================
-- 文件：prefabs/ancient_husks.lua
-- 模块：预制体 / ancient_husks（建筑与容器）
-- 职责：实体「ancient_husks」的预制体定义。SpawnPrefab("ancient_husks") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/ancient_husk.zip"),
}

--[[
handmaid
architect
mason
]]

local function SetId(inst, id)
	if id ~= inst.id then
		inst.id = id
		inst.AnimState:PlayAnimation("husk_"..id)
		if id ~= "handmaid" then
			inst.Physics:SetCapsule(1.3, 2)
		end
	end
	return inst
end

local function OnSave(inst, data)
	data.id = inst.id ~= "handmaid" and inst.id or nil
end

local function OnLoad(inst, data)--, ents)
	if data and data.id then
		inst:SetId(data.id)
	end
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	MakeObstaclePhysics(inst, 1)

	inst.AnimState:SetBank("ancient_husk")
	inst.AnimState:SetBuild("ancient_husk")
	inst.AnimState:PlayAnimation("husk_handmaid")

	--these tags fit mechanically, even tho they're technically statues
	inst:AddTag("structure")
	inst:AddTag("statue")

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inspectable")

	inst.id = "handmaid"

	inst.SetId = SetId
	inst.OnSave = OnSave
	inst.OnLoad = OnLoad

	return inst
end

return Prefab("ancient_husk", fn, assets)
