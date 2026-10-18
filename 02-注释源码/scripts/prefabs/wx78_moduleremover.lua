--============================================================
-- 文件：prefabs/wx78_moduleremover.lua
-- 模块：预制体 / wx78_moduleremover（建筑与容器）
-- 职责：实体「wx78_moduleremover」的预制体定义。SpawnPrefab("wx78_moduleremover") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wx78_moduleremover.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("wx78_moduleremover")
    inst.AnimState:SetBuild("wx78_moduleremover")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryPhysics(inst)
    MakeInventoryFloatable(inst, "med", nil, 0.65)

    inst.scrapbook_specialinfo = "WX78MODULEREMOVER"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")
    inst:AddComponent("upgrademoduleremover")

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("wx78_moduleremover", fn, assets)
