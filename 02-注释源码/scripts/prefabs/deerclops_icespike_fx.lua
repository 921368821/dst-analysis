--============================================================
-- 文件：prefabs/deerclops_icespike_fx.lua
-- 模块：预制体 / deerclops_icespike_fx（建筑与容器）
-- 职责：实体「deerclops_icespike_fx」的预制体定义。SpawnPrefab("deerclops_icespike_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/deerclops_icespike.zip"),
}

local function OnAnimOver(inst)
	if inst.owner ~= nil and inst.owner.icespike_pool ~= nil then
		inst:RemoveFromScene()
		table.insert(inst.owner.icespike_pool, inst)
	else
		inst:Remove()
	end
end

local function SetFXOwner(inst, owner)
	inst.owner = owner
end

local function RestartFX(inst, big, variation)
	inst:ReturnToScene()
	inst.AnimState:PlayAnimation((big and "spike_big" or "spike")..tostring(variation or math.random(4)))
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddSoundEmitter()
	inst.entity:AddNetwork()

	inst:AddTag("FX")
	inst:AddTag("NOCLICK")

	inst.Transform:SetFourFaced()

	inst.AnimState:SetBank("deerclops_icespike")
	inst.AnimState:SetBuild("deerclops_icespike")
	inst.AnimState:PlayAnimation("spike1")

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:ListenForEvent("animover", OnAnimOver)
	inst.persists = false
	inst.SetFXOwner = SetFXOwner
	inst.RestartFX = RestartFX

	return inst
end

return Prefab("deerclops_icespike_fx", fn, assets)
