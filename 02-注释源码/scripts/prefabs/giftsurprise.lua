--============================================================
-- 文件：prefabs/giftsurprise.lua
-- 模块：预制体 / giftsurprise（建筑与容器）
-- 职责：实体「giftsurprise」的预制体定义。SpawnPrefab("giftsurprise") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--Usage:
--	To make a large sized gift that spawns a hound:
--		SpawnPrefab("gift").components.unwrappable:WrapItems({
--			SpawnPrefab("giftsurprise"):SetCreatureSurprise("hound"),
--			SpawnPrefab("giftsurprise"),
--			SpawnPrefab("giftsurprise"),
--			SpawnPrefab("giftsurprise"), --filler so we get large gift size
--		})

local function OnWrapped(inst, data)
	if data and data.bundle and data.bundle.MakeJiggle then
		data.bundle:MakeJiggle()
	end
end

local function OnUnwrapped(inst, data)
	local doer = data and data.doer
	local creature = ReplacePrefab(inst, inst.creature)
	if creature then
		if creature.sg and creature.sg:HasState("surprise_spawn") then
			creature.sg:GoToState("surprise_spawn")
		end
		if doer and creature.components.combat then
			creature.components.combat:SuggestTarget(doer)
		end
	end
end

local function SetCreatureSurprise(inst, prefab)
	inst.creature = prefab
	inst.components.inventoryitem:SetOnDroppedFn(nil)
	inst:ListenForEvent("wrappeditem", OnWrapped)
	inst:ListenForEvent("unwrappeditem", OnUnwrapped)
	return inst
end

local function OnSave(inst, data)
	data.creature = inst.creature
end

local function OnLoad(inst, data)--, ents)
	if data and data.creature then
		inst:SetCreatureSurprise(data.creature)
	end
end

local function OnLoadPostPass(inst)--, ents, data)
	if inst.creature and not inst.components.inventoryitem:IsHeld() then
		OnUnwrapped(inst)
	end
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddNetwork()

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inventoryitem")
	inst.components.inventoryitem.canbepickedup = false
	inst.components.inventoryitem:SetOnDroppedFn(inst.Remove)

	inst.SetCreatureSurprise = SetCreatureSurprise
	inst.OnSave = OnSave
	inst.OnLoad = OnLoad
	inst.OnLoadPostPass = OnLoadPostPass

	return inst
end

return Prefab("giftsurprise", fn)
