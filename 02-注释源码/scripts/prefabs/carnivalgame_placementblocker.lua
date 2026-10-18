--============================================================
-- 文件：prefabs/carnivalgame_placementblocker.lua
-- 模块：预制体 / carnivalgame_placementblocker（建筑与容器）
-- 职责：实体「carnivalgame_placementblocker」的预制体定义。SpawnPrefab("carnivalgame_placementblocker") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function fn()
	local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

	inst:AddTag("NOCLICK")
	inst:AddTag("DECOR")
	inst:AddTag("carnivalgame_part")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	inst.persists = false

	return inst
end

local function fn_golfgame()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    inst:AddTag("NOCLICK")
    --inst:AddTag("DECOR") NOTES(JBK): Intentionally not a decor so they block other things that do not filter out carnivalgame_part.
	inst:AddTag("carnivalgame_part")
    inst:AddTag("birdblocker")

    inst:AddTag("childdeployblocker") -- Permit this to be parented and also block.

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    return inst
end


return Prefab("carnivalgame_placementblocker", fn),
    Prefab("carnivalgame_placementblocker_golfgame", fn_golfgame)
