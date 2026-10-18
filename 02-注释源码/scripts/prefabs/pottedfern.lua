--============================================================
-- 文件：prefabs/pottedfern.lua
-- 模块：预制体 / pottedfern（建筑与容器）
-- 职责：实体「pottedfern」的预制体定义。SpawnPrefab("pottedfern") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "prefabutil"

local assets =
{
    Asset("ANIM", "anim/cave_ferns_potted.zip"),
}

local prefabs =
{
    "collapse_small",
}

local function onsave(inst, data)
    data.anim = inst.animname
end

local function onload(inst, data)
    if data ~= nil and data.anim ~= nil then
        inst.animname = data.anim
        inst.AnimState:PlayAnimation(inst.animname)
    end
    if inst.skinname then
        inst.AnimState:PlayAnimation("c")
    end
end

local function onhammered(inst)
    local fx = SpawnPrefab("collapse_small")
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    fx:SetMaterial("pot")
    inst.components.lootdropper:DropLoot()
    inst:Remove()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

	inst:SetDeploySmartRadius(0.45) --recipe min_spacing/2

    inst.AnimState:SetBank("ferns_potted")
    inst.AnimState:SetBuild("cave_ferns_potted")
    inst.AnimState:SetRayTestOnBB(true)

    inst.scrapbook_anim = "f1"

    inst:AddTag("cavedweller")
    inst:AddTag("pottedplant")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.animname = "f" .. tostring(math.random(10))
    inst.AnimState:PlayAnimation(inst.animname)

    inst:AddComponent("inspectable")

    MakeSmallBurnable(inst)
    MakeSmallPropagator(inst)
    MakeHauntableWork(inst)

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(1)
    inst.components.workable:SetOnFinishCallback(onhammered)

    inst:AddComponent("lootdropper")

    MakeHauntableWork(inst)

    --------SaveLoad
    inst.OnSave = onsave
    inst.OnLoad = onload

    return inst
end

return Prefab("pottedfern", fn, assets, prefabs),
    MakePlacer("pottedfern_placer", "ferns_potted", "cave_ferns_potted", "f1")
