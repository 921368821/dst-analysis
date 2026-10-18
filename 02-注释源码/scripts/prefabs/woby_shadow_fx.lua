--============================================================
-- 文件：prefabs/woby_shadow_fx.lua
-- 模块：预制体 / woby_shadow_fx（建筑与容器）
-- 职责：实体「woby_shadow_fx」的预制体定义。SpawnPrefab("woby_shadow_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/woby_shadow_fx.zip"),
}

local function OnWallUpdate(inst, dt)
	dt = TheNet:IsServerPaused() and 0 or dt * TheSim:GetTimeScale()
	if dt <= 0 then
		return
	end
	local owner = inst.owner and inst.owner:IsValid() and inst.owner or nil
	if owner then
		local x, y, z = inst.Transform:GetWorldPosition()
		local x1, y1, z1 = owner.Transform:GetWorldPosition()
		local dx = x1 - x
		local dz = z1 - z
		local dist = math.sqrt(dx * dx + dz * dz)
		local dist1 = dt * 3
		if dist1 >= dist then
			inst.Transform:SetPosition(x1, y, z1)
		else
			dist1 = dist1 / dist
			inst.Transform:SetPosition(x + dx * dist1, y, z + dz * dist1)
		end
	end
end

local function SetFxOwner(inst, owner)
	inst:AddComponent("updatelooper")
	inst.components.updatelooper:AddOnWallUpdateFn(OnWallUpdate)
	inst.owner = owner
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddSoundEmitter() --sfx triggered from SGwilson
	inst.entity:AddNetwork()

	inst.AnimState:SetBank("woby_shadow_fx")
	inst.AnimState:SetBuild("woby_shadow_fx")
	inst.AnimState:PlayAnimation("woby_teleport_fx_big")

	inst:AddTag("FX")
	inst:AddTag("NOCLICK")

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst.persists = false
	inst:ListenForEvent("animover", inst.Remove)

	inst.SetFxOwner = SetFxOwner

	return inst
end

local function silhouttefn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst.Transform:SetSixFaced()

	inst.AnimState:SetBank("woby_shadow_fx")
	inst.AnimState:SetBuild("woby_shadow_fx")
	inst.AnimState:PlayAnimation("tp_silhoutte")

	inst:AddTag("FX")

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst.persists = false

	return inst
end

return Prefab("woby_dash_shadow_fx", fn, assets),
	Prefab("woby_dash_silhouette_fx", silhouttefn, assets)
