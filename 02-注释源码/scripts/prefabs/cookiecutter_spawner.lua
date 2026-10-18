--============================================================
-- 文件：prefabs/cookiecutter_spawner.lua
-- 模块：预制体 / cookiecutter_spawner（建筑与容器）
-- 职责：实体「cookiecutter_spawner」的预制体定义。SpawnPrefab("cookiecutter_spawner") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("worldsettingsutil")

local assets =
{
}

local prefabs =
{
	"cookiecutter",
}

local function DoReleaseAllChildren(inst)
	inst.components.childspawner:ReleaseAllChildren()
end

local function OnEntitySleep(inst)
	if inst.releasechildrentask ~= nil then
		inst.releasechildrentask:Cancel()
		inst.releasechildrentask = nil
	end
end

local function OnEntityWake(inst)
	if inst.releasechildrentask ~= nil then
		inst.releasechildrentask:Cancel()
	end
	inst.releasechildrentask = inst:DoTaskInTime(0.1, DoReleaseAllChildren)
end

local function OnPreLoad(inst, data)
    WorldSettings_ChildSpawner_PreLoad(inst, data, TUNING.COOKIECUTTER_SPAWNER_RELEASE_TIME, TUNING.COOKIECUTTER_SPAWNER_REGEN_TIME)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()

    --[[Non-networked entity]]
    inst:AddTag("CLASSIFIED")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("childspawner")
    inst.components.childspawner:SetRegenPeriod(TUNING.COOKIECUTTER_SPAWNER_REGEN_TIME)
    inst.components.childspawner:SetSpawnPeriod(TUNING.COOKIECUTTER_SPAWNER_RELEASE_TIME)
    inst.components.childspawner:SetMaxChildren(TUNING.COOKIECUTTER_SPAWNER_MAX_CHILDREN)
    WorldSettings_ChildSpawner_SpawnPeriod(inst, TUNING.COOKIECUTTER_SPAWNER_RELEASE_TIME, TUNING.COOKIECUTTER_SPAWNER_ENABLED)
    WorldSettings_ChildSpawner_RegenPeriod(inst, TUNING.COOKIECUTTER_SPAWNER_REGEN_TIME, TUNING.COOKIECUTTER_SPAWNER_ENABLED)
    if not TUNING.COOKIECUTTER_SPAWNER_ENABLED then
        inst.components.childspawner.childreninside = 0
    end
    inst.components.childspawner:StartRegen()
	inst.components.childspawner.spawnradius = {min = 2, max = TUNING.COOKIECUTTER.WANDER_DIST}
	inst.components.childspawner.childname = "cookiecutter"
	inst.components.childspawner.wateronly = true
	inst.components.childspawner:StartSpawning()

    inst.OnEntitySleep = OnEntitySleep
    inst.OnEntityWake = OnEntityWake

    inst.OnPreLoad = OnPreLoad

    return inst
end


return Prefab("cookiecutter_spawner", fn, assets, prefabs)