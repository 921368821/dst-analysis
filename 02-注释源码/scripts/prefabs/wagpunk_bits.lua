--============================================================
-- 文件：prefabs/wagpunk_bits.lua
-- 模块：预制体 / wagpunk_bits（建筑与容器）
-- 职责：实体「wagpunk_bits」的预制体定义。SpawnPrefab("wagpunk_bits") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wagpunk_bits.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("wagpunk_bits")
    inst.AnimState:SetBuild("wagpunk_bits")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "metal"

    inst:AddTag("molebait")

    MakeInventoryFloatable(inst, "med", nil, 0.7)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("bait")
    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    --inst:AddComponent("edible")
    --inst.components.edible.foodtype = FOODTYPE.GEARS
    --inst.components.edible.healthvalue = TUNING.HEALING_HUGE
    --inst.components.edible.hungervalue = TUNING.CALORIES_HUGE
    --inst.components.edible.sanityvalue = TUNING.SANITY_HUGE

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.GEARS
    inst.components.repairer.workrepairvalue = TUNING.REPAIR_GEARS_WORK
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_SCRAP_HEALTH

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("wagpunk_bits", fn, assets)