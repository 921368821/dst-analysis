--============================================================
-- 文件：prefabs/rose_petals_fx.lua
-- 模块：预制体 / rose_petals_fx（建筑与容器）
-- 职责：实体「rose_petals_fx」的预制体定义。SpawnPrefab("rose_petals_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/rose_petals_fx.zip"),
}

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddSoundEmitter() --some places might need an entity to play sfx on
	inst.entity:AddNetwork()

	inst:AddTag("FX")

	inst.AnimState:SetBank("rose_petals_fx")
	inst.AnimState:SetBuild("rose_petals_fx")
	inst.AnimState:PlayAnimation("fall")
	inst.AnimState:SetFinalOffset(-1)

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:ListenForEvent("animover", ErodeAway)

	inst.persists = false

	return inst
end

return Prefab("rose_petals_fx", fn, assets)
