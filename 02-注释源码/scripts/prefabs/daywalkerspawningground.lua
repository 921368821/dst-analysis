--============================================================
-- 文件：prefabs/daywalkerspawningground.lua
-- 模块：预制体 / daywalkerspawningground（敌对生物）
-- 职责：实体「daywalkerspawningground」的预制体定义。SpawnPrefab("daywalkerspawningground") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local prefabs =
{
	"daywalker",
	"daywalker_pillar",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("daywalkerspawningground")
    inst:AddTag("NOBLOCK")
    inst:AddTag("NOCLICK")

    TheWorld:PushEvent("ms_registerdaywalkerspawningground", inst)

    return inst
end

return Prefab("daywalkerspawningground", fn, nil, prefabs)
