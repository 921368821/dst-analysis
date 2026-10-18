--============================================================
-- 文件：prefabs/halloweenpotion_common.lua
-- 模块：预制体 / halloweenpotion_common（建筑与容器）
-- 职责：实体「halloweenpotion_common」的预制体定义。SpawnPrefab("halloweenpotion_common") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================



local puff_fx = {"halloween_firepuff_1", "halloween_firepuff_2", "halloween_firepuff_3", }
local puff_fx_cold = {"halloween_firepuff_cold_1", "halloween_firepuff_cold_2", "halloween_firepuff_cold_3", }

local prefabs = JoinArrays(puff_fx, puff_fx_cold)
local assets =
{
	Asset("ANIM", "anim/halloween_embers.zip"),
	Asset("ANIM", "anim/halloween_embers_cold.zip"),
}

local function AttachToTarget(inst, target, build, cold_build)
    inst.entity:SetParent(target.entity)
    inst.Transform:SetPosition(0, 0, 0)

	if target.components.burnable ~= nil and target.components.burnable.fxdata[1] ~= nil then
		local fx_data = target.components.burnable.fxdata[1]
		if fx_data.follow ~= nil then
			inst.entity:AddFollower()
			inst.Follower:FollowSymbol(target.GUID, fx_data.follow, fx_data.x or 0, fx_data.y or 0, fx_data.z or 0)
		end
	end
end

local function SpawnPuffFx(inst, target)
	local fx_list = target:HasTag("blueflame") and puff_fx_cold or puff_fx
	local fx = SpawnPrefab(fx_list[math.random(#fx_list)])
	AttachToTarget(fx, target)
	return fx
end


return{
	prefabs = prefabs,
	assets = assets,
	SpawnPuffFx = SpawnPuffFx,
	AttachToTarget = AttachToTarget,
}
