--============================================================
-- 文件：prefabs/mosquitomusk.lua
-- 模块：预制体 / mosquitomusk（建筑与容器）
-- 职责：实体「mosquitomusk」的预制体定义。SpawnPrefab("mosquitomusk") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/mosquitomusk.zip"),
}


local function onrepaired(inst)
   --inst.components.perishable:SetPercent(1)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst:AddTag("mosquitomusk")
    inst:AddTag("show_spoilage")

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("mosquitomusk")
    inst.AnimState:SetBuild("mosquitomusk")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "small", 0.08, 0.8)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("repairable")
    inst.components.repairable.repairmaterial = MATERIALS.VITAE
    --inst.components.repairable.onrepaired = onrepaired
    inst.components.repairable.noannounce = true

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("perishable")
    inst.components.perishable.onperishreplacement = "spoiled_food"
    inst.components.perishable:SetPerishTime(TUNING.PERISH_FASTISH)
    inst.components.perishable:StartPerishing()

    MakeSmallBurnable(inst, TUNING.TINY_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("mosquitomusk", fn, assets)