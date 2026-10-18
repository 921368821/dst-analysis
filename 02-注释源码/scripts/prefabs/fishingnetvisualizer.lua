--============================================================
-- 文件：prefabs/fishingnetvisualizer.lua
-- 模块：预制体 / fishingnetvisualizer（建筑与容器）
-- 职责：实体「fishingnetvisualizer」的预制体定义。SpawnPrefab("fishingnetvisualizer") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/boat_net.zip"),
}

local prefabs =
{
    "fishingnetvisualizerfx"
}

local function fn()
    local inst = CreateEntity()

    inst:AddTag("ignorewalkableplatforms")

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()

    inst.Transform:SetFourFaced()

    inst:AddTag("NOCLICK")

    inst.AnimState:SetBank("boat_net")
    inst.AnimState:SetBuild("boat_net")
    inst.AnimState:SetSortOrder(5)

    inst:AddComponent("groundshadowhandler")
    inst.components.groundshadowhandler:SetSize(3, 2)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end


    inst:SetStateGraph("SGfishingnetvisualizer")

    inst:AddComponent("fishingnetvisualizer")

    return inst
end

return Prefab("fishingnetvisualizer", fn, assets, prefabs)
