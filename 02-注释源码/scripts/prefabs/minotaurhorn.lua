--============================================================
-- 文件：prefabs/minotaurhorn.lua
-- 模块：预制体 / minotaurhorn（建筑与容器）
-- 职责：实体「minotaurhorn」的预制体定义。SpawnPrefab("minotaurhorn") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/horn_rhino.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("horn_rhino")
    inst.AnimState:SetBuild("horn_rhino")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", 0.05, 0.75)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.MEAT
    inst.components.edible.healthvalue = TUNING.HEALING_HUGE
    inst.components.edible.hungervalue = TUNING.CALORIES_HUGE
    inst.components.edible.sanityvalue = -TUNING.SANITY_MED

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("minotaurhorn", fn, assets)
