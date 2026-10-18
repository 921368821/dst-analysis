--============================================================
-- 文件：prefabs/raindrop.lua
-- 模块：预制体 / raindrop（建筑与容器）
-- 职责：实体「raindrop」的预制体定义。SpawnPrefab("raindrop") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/raindrop.zip"),
}

local function OnAnimOver(inst)
	if inst.pool ~= nil and inst.pool.valid then
		inst:RemoveFromScene()
		table.insert(inst.pool.ents, inst)
	else
		inst:Remove()
	end
end

local function RestartFx(inst)
	inst.AnimState:PlayAnimation("anim")
end

local function fn()
	local inst = CreateEntity()

    inst:AddTag("FX")
    --[[Non-networked entity]]
    inst.entity:SetCanSleep(false)
    inst.persists = false

	inst.entity:AddTransform()
    inst.entity:AddAnimState()

    inst.AnimState:SetBuild("raindrop")
    inst.AnimState:SetBank("raindrop")
	inst.AnimState:PlayAnimation("anim")

	inst:ListenForEvent("animover", OnAnimOver)

	inst.RestartFx = RestartFx

    return inst
end

return Prefab("raindrop", fn, assets)