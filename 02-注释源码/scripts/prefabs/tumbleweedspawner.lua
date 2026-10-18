--============================================================
-- 文件：prefabs/tumbleweedspawner.lua
-- 模块：预制体 / tumbleweedspawner（建筑与容器）
-- 职责：实体「tumbleweedspawner」的预制体定义。SpawnPrefab("tumbleweedspawner") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local prefabs =
{
    "tumbleweed",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("CLASSIFIED")

    inst:AddComponent("childspawner")
    inst.components.childspawner.childname = "tumbleweed"
    inst.components.childspawner:SetMaxChildren(math.random(TUNING.MIN_TUMBLEWEEDS_PER_SPAWNER,TUNING.MAX_TUMBLEWEEDS_PER_SPAWNER))
    inst.components.childspawner:SetSpawnPeriod(math.random(TUNING.MIN_TUMBLEWEED_SPAWN_PERIOD, TUNING.MAX_TUMBLEWEED_SPAWN_PERIOD))
    inst.components.childspawner:SetRegenPeriod(TUNING.TUMBLEWEED_REGEN_PERIOD)
    inst.components.childspawner.spawnoffscreen = true
    inst.components.childspawner.save_max_children = true
    inst:DoTaskInTime(0, function(inst)
        inst.components.childspawner:ReleaseAllChildren()
        inst.components.childspawner:StartSpawning()
    end)

    return inst
end

return Prefab("tumbleweedspawner", fn, nil, prefabs)
