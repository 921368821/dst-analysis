--============================================================
-- 文件：prefabs/razor.lua
-- 模块：预制体 / razor（建筑与容器）
-- 职责：实体「razor」的预制体定义。SpawnPrefab("razor") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/razor.zip"),
    Asset("ANIM", "anim/swap_razor.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("razor")
    inst.AnimState:SetBuild("swap_razor")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "small", 0.08, {0.9, 0.7, 0.9}, true, -2, {sym_build = "swap_razor"})
    inst:AddTag("donotautopick")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("shaver")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("razor", fn, assets)