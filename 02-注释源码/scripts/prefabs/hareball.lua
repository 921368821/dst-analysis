--============================================================
-- 文件：prefabs/hareball.lua
-- 模块：预制体 / hareball（建筑与容器）
-- 职责：实体「hareball」的预制体定义。SpawnPrefab("hareball") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/hareball.zip"),
}

local function on_hareball_landed(inst)
    inst.SoundEmitter:PlaySound("yotr_2023/common/goop_place")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("hareball")
    inst.AnimState:SetBuild("hareball")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("cattoy")
    inst:AddTag("renewable")

    MakeInventoryFloatable(inst, "med", 0.05, 0.68)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

    local edible = inst:AddComponent("edible")
    edible.foodtype = FOODTYPE.GOODIES
    edible.healthvalue = 0
    edible.hungervalue = 0

    inst:AddComponent("inspectable")
    inst:AddComponent("tradable")

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.PERISH_FAST)
    inst.components.perishable:StartPerishing()
    inst.components.perishable.onperishreplacement = "spoiled_food"

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    inst:ListenForEvent("on_landed", on_hareball_landed)

    return inst
end

return Prefab("hareball", fn, assets)
