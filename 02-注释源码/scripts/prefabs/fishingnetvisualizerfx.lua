--============================================================
-- 文件：prefabs/fishingnetvisualizerfx.lua
-- 模块：预制体 / fishingnetvisualizerfx（建筑与容器）
-- 职责：实体「fishingnetvisualizerfx」的预制体定义。SpawnPrefab("fishingnetvisualizerfx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/boat_net_fx.zip"),
}

local prefabs =
{
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.persists = false

    inst:AddTag("NOBLOCK")
    inst:AddTag("FX")

    inst.AnimState:SetBank("boat_net_fx")
    inst.AnimState:SetBuild("boat_net_fx")
    inst.AnimState:PlayAnimation("hit", false)
    inst.AnimState:SetSortOrder(5)

    inst:ListenForEvent("animover", function() inst:Remove() end)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    return inst
end

return Prefab("fishingnetvisualizerfx", fn, assets, prefabs)
