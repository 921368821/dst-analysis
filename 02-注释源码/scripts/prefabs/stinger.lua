--============================================================
-- 文件：prefabs/stinger.lua
-- 模块：预制体 / stinger（建筑与容器）
-- 职责：实体「stinger」的预制体定义。SpawnPrefab("stinger") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/stinger.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("stinger")
    inst.AnimState:SetBuild("stinger")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "small", 0.1, 0.7)

    --selfstacker (from selfstacker component) added to pristine state for optimization
    inst:AddTag("selfstacker")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    local selfstacker = inst:AddComponent("selfstacker")
    selfstacker:SetIgnoreMovingFast(true)

	MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
	MakeSmallPropagator(inst)

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("stinger", fn, assets)