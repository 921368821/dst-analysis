--============================================================
-- 文件：prefabs/bearger_fx.lua
-- 模块：预制体 / bearger_fx（建筑与容器）
-- 职责：实体「bearger_fx」的预制体定义。SpawnPrefab("bearger_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/bearger_mutated_actions_fx.zip"),
}

local function Reverse(inst)
	inst.AnimState:PlayAnimation("atk2")
end

local function MakeFX(name, saturation, lightoverride)
	local function fn()
		local inst = CreateEntity()

		inst.entity:AddTransform()
		inst.entity:AddAnimState()
		inst.entity:AddNetwork()

		inst:AddTag("FX")
		inst:AddTag("NOCLICK")

		inst.Transform:SetEightFaced()

		inst.AnimState:SetBank("bearger_mutated_actions_fx")
		inst.AnimState:SetBuild("bearger_mutated_actions_fx")
		inst.AnimState:PlayAnimation("atk1")
		inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
		inst.AnimState:SetLayer(LAYER_BACKGROUND)
		inst.AnimState:SetSortOrder(3)
		inst.AnimState:SetSaturation(saturation)
		inst.AnimState:SetLightOverride(lightoverride)

		inst.entity:SetPristine()

		if not TheWorld.ismastersim then
			return inst
		end

		inst.Reverse = Reverse

		inst.persists = false
		inst:ListenForEvent("animover", inst.Remove)

		return inst
	end

	return Prefab(name, fn, assets)
end

return MakeFX("bearger_swipe_fx", 0, 0),
	MakeFX("mutatedbearger_swipe_fx", 1, 0.1)
