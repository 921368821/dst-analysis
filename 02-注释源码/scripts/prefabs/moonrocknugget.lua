--============================================================
-- 文件：prefabs/moonrocknugget.lua
-- 模块：预制体 / moonrocknugget（建筑与容器）
-- 职责：实体「moonrocknugget」的预制体定义。SpawnPrefab("moonrocknugget") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/moonrock_nugget.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetRayTestOnBB(true)
    inst.AnimState:SetBank("moonrocknugget")
    inst.AnimState:SetBuild("moonrock_nugget")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "rock"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ELEMENTAL
    inst.components.edible.hungervalue = 1
    inst:AddComponent("tradable")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.MOONROCK
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_MOONROCK_NUGGET_HEALTH
    inst.components.repairer.workrepairvalue = TUNING.REPAIR_MOONROCK_NUGGET_WORK

	inst:AddComponent("snowmandecor")

    MakeHauntableLaunchAndSmash(inst)

    return inst
end

return Prefab("moonrocknugget", fn, assets)