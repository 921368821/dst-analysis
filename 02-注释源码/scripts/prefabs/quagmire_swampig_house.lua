--============================================================
-- 文件：prefabs/quagmire_swampig_house.lua
-- 模块：预制体 / quagmire_swampig_house（建筑与容器）
-- 职责：实体「quagmire_swampig_house」的预制体定义。SpawnPrefab("quagmire_swampig_house") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pig_house.zip"), -- bank
    Asset("ANIM", "anim/quagmire_werepig_house.zip"), -- build
    Asset("ANIM", "anim/quagmire_merm_house.zip"), -- build
    Asset("SOUND", "sound/pig.fsb"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeObstaclePhysics(inst, 1)

    inst.AnimState:SetBank("pig_house")
    inst.AnimState:SetBuild("quagmire_merm_house")
    inst.AnimState:PlayAnimation("rundown")

    MakeSnowCoveredPristine(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    MakeSnowCovered(inst)
    MakeHauntableWork(inst)

    return inst
end

local function rubblefn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeObstaclePhysics(inst, 1)

    inst.AnimState:SetBank("pig_house")
    inst.AnimState:SetBuild("quagmire_werepig_house")
    inst.AnimState:PlayAnimation("rubble")

    MakeSnowCoveredPristine(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    MakeSnowCovered(inst)
    MakeHauntableWork(inst)

    return inst
end

return Prefab("quagmire_swampig_house", fn, assets),
    Prefab("quagmire_swampig_house_rubble", rubblefn, assets)
