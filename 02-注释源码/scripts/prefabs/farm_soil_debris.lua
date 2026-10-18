--============================================================
-- 文件：prefabs/farm_soil_debris.lua
-- 模块：预制体 / farm_soil_debris（建筑与容器）
-- 职责：实体「farm_soil_debris」的预制体定义。SpawnPrefab("farm_soil_debris") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/farm_soil_debris.zip"),
    Asset("ANIM", "anim/farm_soil.zip"),
    Asset("ANIM", "anim/smoke_puff_small.zip"),
}

local prefabs =
{
    "dirt_puff"
}

local anim_names = { "f1", "f2", "f3", "f4" }

local chance_loot =
{
	twigs = 40,
	rocks = 25,
	flint = 20,
	nitre = 10,
	goldnugget = 5,
}

for k, _ in pairs(chance_loot) do
	table.insert(prefabs, k)
end

local function onfinishcallback(inst, worker)
    local x, y, z = inst.Transform:GetWorldPosition()

    SpawnPrefab("dirt_puff").Transform:SetPosition(x, y, z)
    inst:Remove()

    if TryLuckRoll(worker, TUNING.FARM_SOIL_DEBRIS_LOOT_CHANCE, LuckFormulas.LootDropperChance) then
        inst.components.lootdropper:SpawnLootPrefab(weighted_random_choice(chance_loot))
    end
end

local function OnSpawnIn(inst)
	inst:Show()
    inst.AnimState:PlayAnimation(inst.animname.."_pre", false)
    inst.AnimState:PushAnimation(inst.animname, false)
end

local function onsave(inst, data)
    data.anim = inst.animname
end

local function onload(inst, data)
    if data and data.anim then
        inst.animname = data.anim
        inst.AnimState:PlayAnimation(inst.animname)
		inst:Show()
		if inst._spawn_task ~= nil then
			inst._spawn_task:Cancel()
			inst._spawn_task = nil
		end
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst:AddTag("farm_debris")
    inst:AddTag("farm_plant_killjoy")

    inst.AnimState:SetBank("farm_soil_debris")
    inst.AnimState:SetBuild("farm_soil_debris")
    inst.AnimState:OverrideSymbol("soil01", "farm_soil", "soil01")

	inst:Hide()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.animname = anim_names[math.random(#anim_names)]

    inst:AddComponent("inspectable")

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.DIG)
    inst.components.workable:SetWorkLeft(1)
    inst.components.workable:SetOnFinishCallback(onfinishcallback)

    inst:AddComponent("lootdropper")

	if not POPULATING then
		inst._spawn_task = inst:DoTaskInTime(0, OnSpawnIn)
	end

    inst.OnSave = onsave
    inst.OnLoad = onload

    return inst
end

return Prefab("farm_soil_debris", fn, assets, prefabs)