--============================================================
-- 文件：prefabs/sewingkit.lua
-- 模块：预制体 / sewingkit（建筑与容器）
-- 职责：实体「sewingkit」的预制体定义。SpawnPrefab("sewingkit") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/sewing_kit.zip"),
}

local function onsewn(inst, target, doer)
    doer:PushEvent("repair")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("sewing_kit")
    inst.AnimState:SetBuild("sewing_kit")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "small", 0.05, 0.8)

    inst.scrapbook_specialinfo = "SEWINGKIT"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.SEWINGKIT_USES)
    inst.components.finiteuses:SetUses(TUNING.SEWINGKIT_USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)



    inst:AddComponent("sewing")
    inst.components.sewing.repair_value = TUNING.SEWINGKIT_REPAIR_VALUE
    inst.components.sewing.onsewn = onsewn
    ---------------------

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("sewing_kit", fn, assets)