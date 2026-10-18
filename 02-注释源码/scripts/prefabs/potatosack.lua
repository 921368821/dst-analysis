--============================================================
-- 文件：prefabs/potatosack.lua
-- 模块：预制体 / potatosack（建筑与容器）
-- 职责：实体「potatosack」的预制体定义。SpawnPrefab("potatosack") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets = 
{
    Asset("INV_IMAGE", "potato_sack_empty"),
    Asset("INV_IMAGE", "potato_sack_full"),
    Asset("ANIM", "anim/potato_sack.zip"),
}
local prefabs = {}
local PHYSICS_RADIUS = 0.45

local function onequip(inst, owner)
    owner.AnimState:OverrideSymbol("swap_body", "potato_sack", "swap_body")
end

local function onunequip(inst, owner)
    owner.AnimState:ClearOverrideSymbol("swap_body")
end

local function onhammered(inst, worker)
    if inst.components.burnable ~= nil and inst.components.burnable:IsBurning() then
        inst.components.burnable:Extinguish()
    end

    inst.components.lootdropper:DropLoot()

    local fx = SpawnPrefab("collapse_small")
    fx.Transform:SetPosition(inst.Transform:GetWorldPosition())
    fx:SetMaterial("rock")
    inst:Remove()
end

local function onhit(inst, worker)
    inst.AnimState:PlayAnimation("hit")
    inst.AnimState:PushAnimation("idle_full")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeHeavyObstaclePhysics(inst, PHYSICS_RADIUS)
    inst:SetPhysicsRadiusOverride(PHYSICS_RADIUS)

    inst:AddTag("heavy")
    inst.gymweight = 1

    inst.AnimState:SetBank("potato_sack_empty")
    inst.AnimState:SetBuild("potato_sack")
    inst.AnimState:PlayAnimation("idle_full")
    inst.scrapbook_anim = "idle_full"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("heavyobstaclephysics")
    inst.components.heavyobstaclephysics:SetRadius(PHYSICS_RADIUS)

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem.cangoincontainer = false
    inst.components.inventoryitem:SetSinks(true)
    inst.components.inventoryitem:ChangeImageName("potato_sack_full")

    inst:AddComponent("symbolswapdata")
    inst.components.symbolswapdata:SetData("potato_sack", "swap_body")

    inst:AddComponent("hauntable")
    inst.components.hauntable:SetHauntValue(TUNING.HAUNT_TINY)

    inst:AddComponent("equippable")
    inst.components.equippable.equipslot = EQUIPSLOTS.BODY
    inst.components.equippable:SetOnEquip(onequip)
    inst.components.equippable:SetOnUnequip(onunequip)
    inst.components.equippable.walkspeedmult = TUNING.HEAVY_SPEED_MULT

    inst:AddComponent("submersible")

    inst:AddComponent("lootdropper")
    inst:AddComponent("workable")
    inst.components.workable:SetWorkAction(ACTIONS.HAMMER)
    inst.components.workable:SetWorkLeft(2)
    inst.components.workable:SetOnFinishCallback(onhammered)
    inst.components.workable:SetOnWorkCallback(onhit)

    MakeMediumBurnable(inst)
    MakeMediumPropagator(inst)

    return inst
end

return Prefab("potatosack", fn, assets, prefabs)