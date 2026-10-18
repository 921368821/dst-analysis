--============================================================
-- 文件：prefabs/vault_switch.lua
-- 模块：预制体 / vault_switch（建筑与容器）
-- 职责：实体「vault_switch」的预制体定义。SpawnPrefab("vault_switch") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("ANIM", "anim/archive_switch.zip"),
	Asset("ANIM", "anim/archive_switch_ground_small.zip"),
}

local assets_base =
{
	Asset("ANIM", "anim/archive_switch_ground.zip"),
}

local prefabs_base =
{
	"vault_switch",
}

--------------------------------------------------------------------------

local function CreatePad()
	local inst = CreateEntity()

	--[[Non-networked entity]]
	inst.entity:SetCanSleep(TheWorld.ismastersim)
	inst.persists = false

	inst.entity:AddTransform()
	inst.entity:AddAnimState()

	inst:AddTag("decor")
	inst:AddTag("NOCLICK")

	inst.AnimState:SetBank("archive_switch_ground_small")
	inst.AnimState:SetBuild("archive_switch_ground_small")
	inst.AnimState:PlayAnimation("idle")
	inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
	inst.AnimState:SetLayer(LAYER_BACKGROUND)
	inst.AnimState:SetSortOrder(-2)

	return inst
end

local function GetStatus(inst)
	return "VALID"
end

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddNetwork()

	inst.AnimState:SetBank("archive_switch")
	inst.AnimState:SetBuild("archive_switch")
	inst.AnimState:PlayAnimation("idle_full")

	inst:SetPrefabNameOverride("archive_switch")

	if not TheNet:IsDedicated() then
		CreatePad().entity:SetParent(inst.entity)
	end

	inst.entity:SetPristine()

	if not TheWorld.ismastersim then
		return inst
	end

	inst:AddComponent("inspectable")
	inst.components.inspectable.getstatus = GetStatus

	inst:AddComponent("pickable")
	inst.components.pickable:SetUp(nil)
	inst.components.pickable:SetStuck(true)

	return inst
end

--------------------------------------------------------------------------

local function base_OnEntityWake(inst)
	if not inst.SoundEmitter:PlayingSound("loop") then
		inst.SoundEmitter:PlaySound("grotto/common/archive_switch/LP", "loop")
	end
end

local function base_OnEntitySleep(inst)
	inst.SoundEmitter:KillSound("loop")
end

local function basefn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddAnimState()
	inst.entity:AddSoundEmitter()
	inst.entity:AddNetwork()

	inst:AddTag("decor")
	inst:AddTag("NOCLICK")

	inst.AnimState:SetBank("archive_switch_ground")
	inst.AnimState:SetBuild("archive_switch_ground")
	inst.AnimState:PlayAnimation("activate_loop", true)
	inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
	inst.AnimState:SetLayer(LAYER_BACKGROUND)
	inst.AnimState:SetSortOrder(-3)

	if not TheWorld.ismastersim then
		return inst
	end

	for i = 1, 3 do
		local switch = SpawnPrefab("vault_switch")
		switch.entity:SetParent(inst.entity)
		local theta = (90 + 120 * i) * DEGREES
		local r = 2.95
		switch.Transform:SetPosition(math.cos(theta) * r, 0, -math.sin(theta) * r)
	end

	inst.OnEntityWake = base_OnEntityWake
	inst.OnEntitySleep = base_OnEntitySleep

	return inst
end

--------------------------------------------------------------------------

return Prefab("vault_switch", fn, assets),
	Prefab("vault_switch_base", basefn, assets_base, prefabs_base)
