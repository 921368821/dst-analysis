--============================================================
-- 文件：prefabs/chestupgrade_stacksize.lua
-- 模块：预制体 / chestupgrade_stacksize（建筑与容器）
-- 职责：实体「chestupgrade_stacksize」的预制体定义。SpawnPrefab("chestupgrade_stacksize") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets = {
    Asset("ANIM", "anim/chestupgrade_stacksize.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("chestupgrade_stacksize")
    inst.AnimState:SetBuild("chestupgrade_stacksize")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", nil, 0.68)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("tradable")

    inst:AddComponent("inspectable")

    local inventoryitem = inst:AddComponent("inventoryitem")
    inventoryitem:SetSinks(false)

    local upgrader = inst:AddComponent("upgrader")
    upgrader.upgradetype = UPGRADETYPES.CHEST

    MakeHauntableLaunchAndSmash(inst)

    return inst
end

return Prefab("chestupgrade_stacksize", fn, assets)