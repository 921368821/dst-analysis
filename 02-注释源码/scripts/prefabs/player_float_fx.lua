--============================================================
-- 文件：prefabs/player_float_fx.lua
-- 模块：预制体 / player_float_fx（建筑与容器）
-- 职责：实体「player_float_fx」的预制体定义。SpawnPrefab("player_float_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--[[ For searching
	Asset("ANIM", "anim/player_boat_sink.zip"),
	Asset("ANIM", "anim/player_float.zip"),
	Asset("ANIM", "anim/player_hotspring.zip"),
]]

local function MakeFx(name, build, bankfile, anim, facings)
	local assets =
	{
		Asset("ANIM", "anim/"..build..".zip"),
	}
	if bankfile and bankfile ~= build then
		table.insert(assets, Asset("ANIM", "anim/"..bankfile..".zip"))
	end

	local function fn()
		local inst = CreateEntity()

		inst.entity:AddTransform()
		inst.entity:AddAnimState()
		inst.entity:AddNetwork()

		inst.AnimState:SetBank("wilson")
		inst.AnimState:SetBuild(build)
		inst.AnimState:PlayAnimation(anim)
		inst.AnimState:SetFinalOffset(-1)

		if facings == 6 then
			inst.Transform:SetSixFaced()
		else
			inst.Transform:SetFourFaced()
		end

		inst:AddTag("FX")
		inst:AddTag("NOCLICK")

		inst.entity:SetPristine()

		if not TheWorld.ismastersim then
			return inst
		end

		inst.persists = false
		inst:ListenForEvent("animover", inst.Remove)

		return inst
	end

	return Prefab(name, fn, assets)
end

return	MakeFx("player_float_hop_water_fx", "player_boat_sink", "player_float", "float_water_pst", 6),
		MakeFx("player_hotspring_water_fx", "player_hotspring", nil, "hotspring_water_pst", 4)
