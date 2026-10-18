--============================================================
-- 文件：prefabs/quagmire_mealingstone.lua
-- 模块：预制体 / quagmire_mealingstone（建筑与容器）
-- 职责：实体「quagmire_mealingstone」的预制体定义。SpawnPrefab("quagmire_mealingstone") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_mealingstone.zip"),
}

local prefabs =
{
    "collapse_small",
}

local WARES =
{
    "quagmire_flour",
    "quagmire_salt",
    "quagmire_spotspice_ground",
}

for i, v in ipairs(WARES) do
    table.insert(prefabs, v)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeObstaclePhysics(inst, .4)

    inst.MiniMapEntity:SetPriority(5)
    inst.MiniMapEntity:SetIcon("quagmire_mealingstone.png")

    inst.AnimState:SetBank("quagmire_mealingstone")
    inst.AnimState:SetBuild("quagmire_mealingstone")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("structure")

    --prototyper (from prototyper component) added to pristine state for optimization
    inst:AddTag("prototyper")

    MakeSnowCoveredPristine(inst)

    inst.quagmire_shoptab = QUAGMIRE_RECIPETABS.QUAGMIRE_MEALINGSTONE

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_mealingstone").master_postinit(inst, WARES)

    return inst
end

return Prefab("quagmire_mealingstone", fn, assets, prefabs)
