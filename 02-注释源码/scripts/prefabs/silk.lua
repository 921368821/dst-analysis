--============================================================
-- 文件：prefabs/silk.lua
-- 模块：预制体 / silk（建筑与容器）
-- 职责：实体「silk」的预制体定义。SpawnPrefab("silk") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/silk.zip"),
}

local function CanUpgrade(inst, target, doer)
    return doer:HasTag("spiderwhisperer")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("silk")
    inst.AnimState:SetBuild("silk")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "cloth"

    inst:AddTag("cattoy")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("tradable")

    inst:AddComponent("upgrader")
    inst.components.upgrader.canupgradefn = CanUpgrade
    inst.components.upgrader.upgradetype = UPGRADETYPES.SPIDER

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("silk", fn, assets)