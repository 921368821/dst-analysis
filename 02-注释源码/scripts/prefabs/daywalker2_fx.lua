--============================================================
-- 文件：prefabs/daywalker2_fx.lua
-- 模块：预制体 / daywalker2_fx（敌对生物）
-- 职责：实体「daywalker2_fx」的预制体定义。SpawnPrefab("daywalker2_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local swipe_assets =
{
	Asset("ANIM", "anim/daywalker_swipe_fx.zip"),
}

local function swipe_Reverse(inst)
	inst.AnimState:PlayAnimation("atk2")
end

local function swipe_fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst:AddTag("FX")
	inst:AddTag("NOCLICK")

	inst.Transform:SetFourFaced()

	inst.AnimState:SetBank("daywalker_swipe_fx")
	inst.AnimState:SetBuild("daywalker_swipe_fx")
	inst.AnimState:PlayAnimation("atk1")
	inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
	inst.AnimState:SetLayer(LAYER_BACKGROUND)
	inst.AnimState:SetSortOrder(3)

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst.Reverse = swipe_Reverse

	inst.persists = false
	inst:ListenForEvent("animover", inst.Remove)

	return inst
end

return Prefab("daywalker2_swipe_fx", swipe_fn, swipe_assets)
