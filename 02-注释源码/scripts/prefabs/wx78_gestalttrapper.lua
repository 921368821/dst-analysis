--============================================================
-- 文件：prefabs/wx78_gestalttrapper.lua
-- 模块：预制体 / wx78_gestalttrapper（建筑与容器）
-- 职责：实体「wx78_gestalttrapper」的预制体定义。SpawnPrefab("wx78_gestalttrapper") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wx78_gestalttrapper.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("wx78_gestalttrapper")
    inst.AnimState:SetBuild("wx78_gestalttrapper")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "metal"

    MakeInventoryFloatable(inst, "small", 0.07, 1.2)
    MakeItemSocketable_Client(inst, SOCKETNAMES.GESTALTTRAPPER)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    MakeItemSocketable_Server(inst)
    inst.components.socketable:SetSocketQuality(SOCKETQUALITY.LOW)

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("wx78_gestalttrapper", fn, assets)