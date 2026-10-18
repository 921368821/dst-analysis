--============================================================
-- 文件：prefabs/yoth_knightwarningsound.lua
-- 模块：预制体 / yoth_knightwarningsound（建筑与容器）
-- 职责：实体「yoth_knightwarningsound」的预制体定义。SpawnPrefab("yoth_knightwarningsound") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function CreateSoundFxAt(x, z)
	local inst = CreateEntity()

	--[[Non-networked entity]]
	inst.entity:AddTransform()
	inst.entity:AddSoundEmitter()

	inst.Transform:SetPosition(x, 0, z)
	inst.SoundEmitter:PlaySound("yoth_2026/fanfare/announce")

	inst:Remove()
end

-- PLAYER_CAMERA_SEE_DISTANCE is range knights spawn at, plus ten for padding.
local RANGE = PLAYER_CAMERA_SEE_DISTANCE + 20
local RANGE_SQ = RANGE * RANGE
local function PlayWarningSound(inst)
	local player = ThePlayer
	if player ~= nil then
		local x, y, z = inst.Transform:GetWorldPosition()
		local px, py, pz = player.Transform:GetWorldPosition()
		local dx, dz = x - px, z - pz
		local dist = dx * dx + dz * dz
		if dist <= RANGE_SQ then
			dist = math.sqrt(dist)
			if dist > 15 then
				dist = 15 / dist
				x = px + dx * dist
				z = pz + dz * dist
			end
			CreateSoundFxAt(x, z)
		end
	end
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddNetwork()

	inst.entity:SetCanSleep(false)

	inst:AddTag("FX")

	--Dedicated server does not need to spawn the local fx
	if not TheNet:IsDedicated() then
		--Delay one frame so that we are positioned properly before starting the effect
		--or in case we are about to be removed
		inst:DoTaskInTime(0, PlayWarningSound)
	end

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst.persists = false
	inst:DoTaskInTime(1, inst.Remove)

	return inst
end

return Prefab("yothknightwarningsound", fn)