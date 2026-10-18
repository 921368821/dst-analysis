--============================================================
-- 文件：prefabs/daywalker2_items.lua
-- 模块：预制体 / daywalker2_items（敌对生物）
-- 职责：实体「daywalker2_items」的预制体定义。SpawnPrefab("daywalker2_items") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/daywalker_phase3.zip"),
}

local function OnHitGround(inst, speed)
	inst.Physics:SetMotorVel(speed * 0.5, 0, 0)
end

local function OnAnimOver(inst)
	if inst.loot then
		local loot = SpawnPrefab(inst.loot)
		loot.Transform:SetPosition(inst.Transform:GetWorldPosition())
		if loot.components.armor then
			loot.components.armor:SetPercent(GetRandomMinMax(0.06, 0.2))
		end
		inst:Remove()
	else
		inst:RemoveEventCallback("animover", OnAnimOver)
		inst.Physics:SetMotorVel(0, 0, 0)
		inst.Physics:Stop()
		ErodeAway(inst)
	end
end

local function MakeItemBreakFx(name, anim, loot)
	local prefabs = loot and { loot } or nil

	local function fn()
		local inst = CreateEntity()

		inst.entity:AddTransform()
		inst.entity:AddAnimState()
		inst.entity:AddNetwork()

		MakeInventoryPhysics(inst)

		inst:AddTag("FX")
		inst:AddTag("NOCLICK")

		inst.AnimState:SetBank("daywalker")
		inst.AnimState:SetBuild("daywalker_phase3")
		inst.AnimState:PlayAnimation(anim)

		inst.entity:SetPristine()

		if not TheWorld.ismastersim then
			return inst
		end

		if loot then
			local speed = 3 + math.random()
			inst.Physics:SetMotorVel(speed, 0, 0)
			inst:DoTaskInTime(15 * FRAMES, OnHitGround, speed)
			inst.loot = loot
			inst.OnLoad = OnAnimOver
		else
			local speed = 4 + math.random()
			inst.Physics:SetMotorVel(speed, 0, 0)
			inst:DoTaskInTime(20 * FRAMES, OnHitGround, speed)
			inst.persists = false
		end
		inst:ListenForEvent("animover", OnAnimOver)

		return inst
	end

	return Prefab(name, fn, assets, prefabs)
end

return MakeItemBreakFx("daywalker2_object_break_fx", "object_break"),
	MakeItemBreakFx("daywalker2_spike_break_fx", "spike_break"),
	MakeItemBreakFx("daywalker2_spike_loot_fx", "spike_loot", "scraphat"),
	MakeItemBreakFx("daywalker2_cannon_break_fx", "cannon_break"),
	MakeItemBreakFx("daywalker2_armor1_break_fx", "armor1_break"),
	MakeItemBreakFx("daywalker2_armor2_break_fx", "armor2_break"),
	MakeItemBreakFx("daywalker2_cloth_break_fx", "cloth_break")
