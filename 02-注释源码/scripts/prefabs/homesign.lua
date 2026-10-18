--============================================================
-- 文件：prefabs/homesign.lua
-- 模块：预制体 / homesign（建筑与容器）
-- 职责：实体「homesign」的预制体定义。SpawnPrefab("homesign") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "prefabutil"

local assets =
{
    Asset("ANIM", "anim/sign_home.zip"),
    Asset("ANIM", "anim/ui_board_5x3.zip"),
    Asset("MINIMAP_IMAGE", "sign"),
}

local prefabs =
{
    "collapse_small",
}

local function onhammered(inst, worker)
    if inst.components.burnable ~= nil and inst.components.burnable:IsBurning() then
        inst.components.burnable:Extinguish()
    end
    inst.components.lootdropper:DropLoot()
    local fx = SpawnPrefab("collapse_small")
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    fx:SetMaterial("wood")
    inst:Remove()
end

local function onhit(inst, worker)
    if not inst:HasTag("burnt") then
        inst.AnimState:PlayAnimation("hit")
        inst.AnimState:PushAnimation("idle", false)
    end
end

local function onsave(inst, data)
    if inst:HasTag("burnt") or (inst.components.burnable ~= nil and inst.components.burnable:IsBurning()) then
        data.burnt = true
    end
end

local function onload(inst, data)
    if data ~= nil and data.burnt then
        inst.components.burnable.onburnt(inst)
    end
end

local function onbuilt(inst)
    inst.SoundEmitter:PlaySound("dontstarve/common/sign_craft")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

	inst:SetDeploySmartRadius(0.75) --recipe min_spacing/2
    MakeObstaclePhysics(inst, .2)

    inst.MiniMapEntity:SetIcon("sign.png")

    inst.AnimState:SetBank("sign_home")
    inst.AnimState:SetBuild("sign_home")
    inst.AnimState:PlayAnimation("idle")

    MakeSnowCoveredPristine(inst)

    inst:AddTag("structure")
    inst:AddTag("sign")

    --Sneak these into pristine state for optimization
    inst:AddTag("_writeable")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    --Remove these tags so that they can be added properly when replicating components below
    inst:RemoveTag("_writeable")

    inst:AddComponent("inspectable")
    inst:AddComponent("writeable")
    inst:AddComponent("lootdropper")

    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(4)
    inst.components.workable:SetOnFinishCallback(onhammered)
    inst.components.workable:SetOnWorkCallback(onhit)
    MakeSnowCovered(inst)

    MakeSmallBurnable(inst, nil, nil, true)
    MakeSmallPropagator(inst)
    inst.OnSave = onsave
    inst.OnLoad = onload

    MakeHauntableWork(inst)
    inst:ListenForEvent("onbuilt", onbuilt)

    return inst
end

return Prefab("homesign", fn, assets, prefabs),
    MakePlacer("homesign_placer", "sign_home", "sign_home", "idle")
