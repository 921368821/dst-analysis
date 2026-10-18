--============================================================
-- 文件：prefabs/yotr_token.lua
-- 模块：预制体 / yotr_token（建筑与容器）
-- 职责：实体「yotr_token」的预制体定义。SpawnPrefab("yotr_token") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/yotr_token.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("yotr_token")
    inst.AnimState:SetBuild("yotr_token")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("cattoy")
    inst:AddTag("renewable")
    inst:AddTag("yotr_token")    

    MakeInventoryFloatable(inst, "med", 0.05, 0.68)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")
    inst:AddComponent("tradable")

    return inst
end

return Prefab("yotr_token", fn, assets)
