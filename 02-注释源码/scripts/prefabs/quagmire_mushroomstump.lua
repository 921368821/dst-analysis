--============================================================
-- 文件：prefabs/quagmire_mushroomstump.lua
-- 模块：预制体 / quagmire_mushroomstump（建筑与容器）
-- 职责：实体「quagmire_mushroomstump」的预制体定义。SpawnPrefab("quagmire_mushroomstump") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_mushroomstump.zip"),
}

local prefabs =
{
    "quagmire_mushrooms",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst.Transform:SetScale(0.7, 0.7, 0.7)

    MakeSmallObstaclePhysics(inst, .2)
    inst:SetPhysicsRadiusOverride(1.0)

    inst.MiniMapEntity:SetIcon("quagmire_mushroomstump.png")

    inst.AnimState:SetBank("quagmire_mushroomstump")
    inst.AnimState:SetBuild("quagmire_mushroomstump")
    inst.AnimState:PlayAnimation("idle", true)

    -- for stats tracking
    inst:AddTag("quagmire_wildplant")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_mushroomstump").master_postinit(inst)

    return inst
end

return Prefab("quagmire_mushroomstump", fn, assets, prefabs)
