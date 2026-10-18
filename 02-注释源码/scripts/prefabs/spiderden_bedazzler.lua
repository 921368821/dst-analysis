--============================================================
-- 文件：prefabs/spiderden_bedazzler.lua
-- 模块：预制体 / spiderden_bedazzler（敌对生物）
-- 职责：实体「spiderden_bedazzler」的预制体定义。SpawnPrefab("spiderden_bedazzler") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/spiderden_bedazzler.zip")
}

local prefabs = 
{
    "bedazzle_buff",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("spiderden_bedazzler")
    inst.AnimState:SetBuild("spiderden_bedazzler")
    inst.AnimState:PlayAnimation("idle", true)
    MakeInventoryPhysics(inst)

    MakeInventoryFloatable(inst, "small", 0.15, 0.9)

    inst.scrapbook_specialinfo = "DENBEDAZZLER"

	inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")
    inst:AddComponent("inspectable")
    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetOnFinished(function() inst:Remove() end)
    
    inst:AddComponent("bedazzler")
    inst.components.bedazzler:SetUseAmount(TUNING.BEDAZZLER_USE_AMOUNT)

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)

    MakeSmallPropagator(inst)
    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("spiderden_bedazzler", fn, assets, prefabs)