--============================================================
-- 文件：prefabs/livinglog.lua
-- 模块：预制体 / livinglog（建筑与容器）
-- 职责：实体「livinglog」的预制体定义。SpawnPrefab("livinglog") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/livinglog.zip"),
}

local SOUND_TORMENTED_SCREAM = "dontstarve/creatures/leif/livinglog_burn"

local function FuelTaken(inst, taker)
    if taker ~= nil and taker.SoundEmitter ~= nil then
        taker.SoundEmitter:PlaySound(SOUND_TORMENTED_SCREAM)
    end
end

local function allanimalscanscream(inst)
    inst.SoundEmitter:PlaySound(SOUND_TORMENTED_SCREAM)
end

local function onignite(inst)
    allanimalscanscream(inst)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.pickupsound = "wood"

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("livinglog")
    inst.AnimState:SetBuild("livinglog")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", 0.1, 0.7)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.WOOD
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = 0

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL
    inst.components.fuel:SetOnTakenFn(FuelTaken)

    MakeSmallBurnable(inst, TUNING.MED_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndIgnite(inst)

    ---------------------

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst:AddComponent("stackable")

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.WOOD
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_LOGS_HEALTH * 3
    inst.components.repairer.boatrepairsound = "turnoftides/common/together/boat/repair_with_wood"

    inst:ListenForEvent("onignite", onignite)
    inst.eatensound = SOUND_TORMENTED_SCREAM
    inst.incineratesound = SOUND_TORMENTED_SCREAM -- NOTES(JBK): Pleasant orchestra.

    return inst
end

return Prefab("livinglog", fn, assets)
