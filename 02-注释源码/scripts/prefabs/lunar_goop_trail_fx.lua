--============================================================
-- 文件：prefabs/lunar_goop_trail_fx.lua
-- 模块：预制体 / lunar_goop_trail_fx（建筑与容器）
-- 职责：实体「lunar_goop_trail_fx」的预制体定义。SpawnPrefab("lunar_goop_trail_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/lunar_goop_trail.zip"),
}

local function OnStartFade(inst)
	inst.task = nil
	inst.AnimState:PlayAnimation(inst.trailname.."_pst")
	inst.AnimState:SetDeltaTimeMultiplier(.5)
end

local function OnAnimOver(inst)
	if inst.AnimState:IsCurrentAnimation(inst.trailname.."_pre") then
		inst.AnimState:PlayAnimation(inst.trailname)
		--assert(inst.task == nil)
		inst.task = inst:DoTaskInTime(inst.duration, OnStartFade)
	elseif inst.AnimState:IsCurrentAnimation(inst.trailname.."_pst") then
		if inst.onfinished ~= nil then
			inst:onfinished()
		else
			inst:Remove()
		end
	end
end

local function SetVariation(inst, rand, scale, duration)
	inst.Transform:SetScale(scale, scale, scale)
	inst.trailname = "trail"..tostring(rand)
	inst.duration = duration
	inst.AnimState:PlayAnimation(inst.trailname.."_pre")
	if inst.task ~= nil then
		inst.task:Cancel()
		inst.task = nil
	end
end

local function Dissipate(inst)
	if inst.task ~= nil then
		inst.task:Cancel()
		OnStartFade(inst)
	else
		inst.duration = 0
	end
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst:AddTag("FX")
	inst:AddTag("NOCLICK")

	inst.AnimState:SetBank("lunar_goop_trail")
	inst.AnimState:SetBuild("lunar_goop_trail")
	inst.AnimState:PlayAnimation("trail1_pre")
	inst.AnimState:SetMultColour(1, 1, 1, 0.4)
	inst.AnimState:SetLightOverride(0.1)
	inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
	inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
	inst.AnimState:SetSortOrder(3)

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst.trailname = "trail1"
	inst.duration = 1
	inst:ListenForEvent("animover", OnAnimOver)
	inst.SetVariation = SetVariation
	inst.Dissipate = Dissipate
	inst.persists = false

	--inst.onfinished = nil

	return inst
end

return Prefab("lunar_goop_trail_fx", fn, assets)
