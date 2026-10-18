--============================================================
-- 文件：prefabs/spider_web_spit_creep.lua
-- 模块：预制体 / spider_web_spit_creep（敌对生物）
-- 职责：实体「spider_web_spit_creep」的预制体定义。SpawnPrefab("spider_web_spit_creep") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function fn()
	local inst = CreateEntity()

	inst.entity:AddTransform()
	inst.entity:AddGroundCreepEntity()
    inst.entity:AddNetwork()

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

	inst.GroundCreepEntity:SetRadius(3)

	inst:DoTaskInTime(5, inst.Remove)
	inst.persists = false

	return inst
end

return Prefab("spider_web_spit_creep", fn)