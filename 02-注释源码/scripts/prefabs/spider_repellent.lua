--============================================================
-- 文件：prefabs/spider_repellent.lua
-- 模块：预制体 / spider_repellent（敌对生物）
-- 职责：实体「spider_repellent」的预制体定义。SpawnPrefab("spider_repellent") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/spider_repellent.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("spider_repellent")
    inst.AnimState:SetBuild("spider_repellent")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryPhysics(inst)

    MakeInventoryFloatable(inst, "small", 0.15, 0.9)

    inst.scrapbook_specialinfo = "SPIDERREPELLENT"

	inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")
    inst:AddComponent("inspectable")
    
    inst:AddComponent("repellent")
    inst.components.repellent:AddRepelTag("spider")
    inst.components.repellent:AddIgnoreTag("spiderqueen")
    inst.components.repellent:SetRadius(TUNING.SPIDER_REPELLENT_RADIUS)
    inst.components.repellent:SetUseAmount(10)

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetOnFinished(function() inst:Remove() end)

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)

    MakeSmallPropagator(inst)
    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("spider_repellent", fn, assets)