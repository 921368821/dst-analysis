--============================================================
-- 文件：prefabs/wave_shore.lua
-- 模块：预制体 / wave_shore（建筑与容器）
-- 职责：实体「wave_shore」的预制体定义。SpawnPrefab("wave_shore") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/wave_shore.zip")
}

local small = {"idle_small", "idle_small2", "idle_small3", "idle_small4"}
local smallsize = #small

local function SetAnim(inst)
	local ex, ey, ez = inst.Transform:GetWorldPosition()
	local bearing = -(inst.Transform:GetRotation() + 90) * DEGREES

	local map = TheWorld.Map
	local xr45, yr45 = map:GetTileXYAtPoint(ex + math.cos(bearing - 0.25 * PI), ey, ez + math.sin(bearing - 0.25 * PI))
	local xr90, yr90 = map:GetTileXYAtPoint(ex + math.cos(bearing - 0.5 * PI), ey, ez + math.sin(bearing - 0.5 * PI))
	local xl45, yl45 = map:GetTileXYAtPoint(ex + math.cos(bearing + 0.25 * PI), ey, ez + math.sin(bearing + 0.25 * PI))
	local xl90, yl90 = map:GetTileXYAtPoint(ex + math.cos(bearing + 0.5 * PI), ey, ez + math.sin(bearing + 0.5 * PI))

	local left = IsLandTile(map:GetTile(xl45, yl45)) and IsOceanTile(map:GetTile(xl90, yl90))
	local right = IsLandTile(map:GetTile(xr45, yr45)) and IsOceanTile(map:GetTile(xr90, yr90))

	if left and right then
		inst.AnimState:PlayAnimation("idle_big", false)
	elseif left then
		inst.Transform:SetPosition(ex - 0.5 * TILE_SCALE * math.cos(bearing - 0.5 * PI), ey, ez - 0.5 * TILE_SCALE * math.sin(bearing - 0.5 * PI))
		inst.AnimState:PlayAnimation("idle_med", false)
	elseif right then
		inst.Transform:SetPosition(ex + 0.5 * TILE_SCALE * math.cos(bearing - 0.5 * PI), ey, ez + 0.5 * TILE_SCALE * math.sin(bearing - 0.5 * PI))
		inst.AnimState:PlayAnimation("idle_med", false)
	else
		inst.AnimState:PlayAnimation(small[math.random(1, smallsize)], false)
	end
end

local function fn(Sim)
	local inst = CreateEntity()
	local trans = inst.entity:AddTransform()
    local anim = inst.entity:AddAnimState()

    --[[Non-networked entity]]
    inst:AddTag("CLASSIFIED")

    anim:SetOceanBlendParams(TUNING.OCEAN_SHADER.WAVE_TINT_AMOUNT)
    anim:SetBuild("wave_shore")
    anim:SetBank("wave_shore")
    anim:PlayAnimation("idle_small", false)
    anim:SetOrientation(ANIM_ORIENTATION.OnGround)
    anim:SetLayer(LAYER_BACKGROUND)
    anim:SetSortOrder(ANIM_SORT_ORDER.OCEAN_WAVES)

	inst:AddTag("FX")
	inst:AddTag("NOCLICK")
	inst:AddTag("NOBLOCK")
	inst:AddTag("ignorewalkableplatforms")

	if TheNet:GetIsClient() then
		inst.entity:AddClientSleepable()
	end

	inst.OnEntitySleep = inst.Remove
	inst:ListenForEvent("animover", inst.Remove)

	inst.persists = false

	inst.SetAnim = SetAnim

    return inst
end

return Prefab("wave_shore", fn, assets)
