--============================================================
-- 文件：prefabs/wintersfeastfuel.lua
-- 模块：预制体 / wintersfeastfuel（建筑与容器）
-- 职责：实体「wintersfeastfuel」的预制体定义。SpawnPrefab("wintersfeastfuel") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wintersfeastfuel.zip"),
}

local function OnEaten(inst, eater)
    if eater.components.talker ~= nil then
        eater.components.talker:Say( GetString(eater, "EAT_FOOD", "WINTERSFEASTFUEL") )
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("wintersfeastfuel")
    inst.AnimState:SetBuild("wintersfeastfuel")
    inst.AnimState:PlayAnimation("idle_loop", true)

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.GENERIC
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = 0
    inst.components.edible:SetOnEatenFn(OnEaten)

    MakeHauntableLaunch(inst)

    inst:AddComponent("inventoryitem")

    return inst
end

return Prefab("wintersfeastfuel", fn, assets)