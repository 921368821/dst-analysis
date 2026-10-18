--============================================================
-- 文件：prefabs/messagebottletreasure_marker.lua
-- 模块：预制体 / messagebottletreasure_marker（建筑与容器）
-- 职责：实体「messagebottletreasure_marker」的预制体定义。SpawnPrefab("messagebottletreasure_marker") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
	Asset("MINIMAP_IMAGE", "messagebottletreasure_marker"),
}

-- local prefabs =
-- {
-- }

local function OnAdd(inst)
	TheWorld:PushEvent("messagebottletreasure_marker_added", inst)
end

local function OnRemove(inst)
	TheWorld:PushEvent("messagebottletreasure_marker_removed", inst)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

	inst.MiniMapEntity:SetIcon("messagebottletreasure_marker.png")
	inst.MiniMapEntity:SetPriority(6)

	inst:AddTag("NOCLICK")
	inst:AddTag("NOBLOCK")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
	end

	inst.persists = false

	inst:DoTaskInTime(0, OnAdd)

	inst:ListenForEvent("onremove", OnRemove)

    return inst
end

return Prefab("messagebottletreasure_marker", fn, assets--[[, prefabs]])