--============================================================
-- 文件：prefabs/vault_chandelier.lua
-- 模块：预制体 / vault_chandelier（建筑与容器）
-- 职责：实体「vault_chandelier」的预制体定义。SpawnPrefab("vault_chandelier") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--This file contains vault_chandelier_broken.
--vault_chandelier is defined in archive_chandelier.lua

local assets =
{
	Asset("ANIM", "anim/chandelier_vault.zip"),
}

--------------------------------------------------------------------------

local function brokenfn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	MakeObstaclePhysics(inst, 0.75)

	inst.AnimState:SetBank("chandelier_vault")
	inst.AnimState:SetBuild("chandelier_vault")
	inst.AnimState:PlayAnimation("fallen")

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inspectable")

	return inst
end

--------------------------------------------------------------------------

local function decor_SetVariation(inst, variation)
	if inst.variation ~= variation then
		inst.variation = variation
		inst.AnimState:PlayAnimation("chain_idle_"..tostring(variation), true)
	end
	return inst
end

local function decor_OnSave(inst, data)
	data.variation = inst.variation ~= 1 and inst.variation or nil
end

local function decor_OnLoad(inst, data)--, ents)
	if data and data.variation then
		inst:SetVariation(data.variation)
	end
end

local function decorfn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst.AnimState:SetBank("chandelier_vault")
	inst.AnimState:SetBuild("chandelier_vault")
	inst.AnimState:PlayAnimation("chain_idle_1", true)

	inst:AddTag("NOCLICK")
	inst:AddTag("decor")

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst.AnimState:SetFrame(math.random(inst.AnimState:GetCurrentAnimationNumFrames()) - 1)

	inst.variation = 1
	inst.SetVariation = decor_SetVariation
	inst.OnSave = decor_OnSave
	inst.OnLoad = decor_OnLoad

	return inst
end

--------------------------------------------------------------------------

--vault_chandelier is defined in archive_chandelier.lua
return Prefab("vault_chandelier_broken", brokenfn, assets),
	Prefab("vault_chandelier_decor", decorfn, assets)
