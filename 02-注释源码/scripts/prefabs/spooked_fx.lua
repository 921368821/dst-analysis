--============================================================
-- 文件：prefabs/spooked_fx.lua
-- 模块：预制体 / spooked_fx（建筑与容器）
-- 职责：实体「spooked_fx」的预制体定义。SpawnPrefab("spooked_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--V2C: not using fx.lua for client-side fx because these anims are quite long

local function OnEntitySleep(inst)
	inst.OnEntityWake = nil
	inst.OnEntitySleep = nil
end

local function MakeFx(name, build, anim, sound)
	local assets =
	{
		Asset("ANIM", "anim/"..build..".zip"),
	}

	local function OnEntityWake(inst)
		inst.SoundEmitter:PlaySound(sound)
		inst.OnEntityWake = nil
		inst.OnEntitySleep = nil
	end

	local function fn()
		local inst = CreateEntity()

		inst.entity:AddTransform()
		inst.entity:AddAnimState()
		inst.entity:AddSoundEmitter()
		inst.entity:AddNetwork()

		inst.AnimState:SetBank(build)
		inst.AnimState:SetBuild(build)
		inst.AnimState:PlayAnimation(anim)

		inst:AddTag("FX")
		inst:AddTag("NOCLICK")

		inst.entity:SetPristine()

		if not TheWorld.ismastersim then
			return inst
		end

		inst.OnEntityWake = OnEntityWake
		inst.OnEntitySleep = OnEntitySleep

		inst:ListenForEvent("animover", inst.Remove)
		inst.persists = false

		return inst
	end

	return Prefab(name, fn, assets)
end

return MakeFx("spooked_spider_rock_fx", "spider_rock_fx", "spiders_spawn", "hallowednights2025/spooks/spiders"),
	MakeFx("spooked_worms_fx", "worms_fx", "worms_spawn", "hallowednights2025/spooks/worms")
