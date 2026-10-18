--============================================================
-- 文件：prefabs/weremoose_smash_fx.lua
-- 模块：预制体 / weremoose_smash_fx（建筑与容器）
-- 职责：实体「weremoose_smash_fx」的预制体定义。SpawnPrefab("weremoose_smash_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/weremoose_attacks.zip"),
}

local function AddBackFX(parent)
	local inst = CreateEntity()

	inst:AddTag("FX")
	--[[Non-networked entity]]
	--inst.entity:SetCanSleep(false)
	inst.persists = false

	inst.entity:AddTransform()
	inst.entity:AddAnimState()

	inst.Transform:SetFourFaced()

	inst.entity:SetParent(parent.entity)

	inst.AnimState:SetBank("weremoose")
	inst.AnimState:SetBuild("weremoose_build")
	inst.AnimState:PlayAnimation("moose_slam_fx_back")
	inst.AnimState:SetFrame(parent.AnimState:GetCurrentAnimationFrame())
	inst.AnimState:SetFinalOffset(-1)

	return inst
end

local function OnOwnerDirty(inst)
	if inst._owner:value() == ThePlayer then
		--Predicting! so we'll have spawned our own fx locally already
		inst:Hide()
	end
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst:AddTag("FX")

	inst.Transform:SetFourFaced()

	inst.AnimState:SetBank("weremoose")
	inst.AnimState:SetBuild("weremoose_build")
	inst.AnimState:PlayAnimation("moose_slam_fx_front")
	inst.AnimState:SetFinalOffset(3)

	inst._owner = net_entity(inst.GUID, "weremoose_smash_fx._owner", "ownerdirty")

	inst.entity:SetPristine()

	--Dedicated server does not need to spawn the local fx
	if not TheNet:IsDedicated() then
		inst:DoTaskInTime(0, AddBackFX)
	end

	if not TheWorld.ismastersim then
		if ThePlayer ~= nil and ThePlayer.sg ~= nil then
			inst:ListenForEvent("ownerdirty", OnOwnerDirty)
		end

		return inst
	end

	inst.persists = false
	inst:ListenForEvent("animover", inst.Remove)

	return inst
end

return Prefab("weremoose_smash_fx", fn, assets)
