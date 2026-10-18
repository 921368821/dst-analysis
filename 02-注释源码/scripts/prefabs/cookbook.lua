--============================================================
-- 文件：prefabs/cookbook.lua
-- 模块：预制体 / cookbook（建筑与容器）
-- 职责：实体「cookbook」的预制体定义。SpawnPrefab("cookbook") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cookbook.zip"),
}

local function OnReadBook(inst, doer)
	doer:ShowPopUp(POPUPS.COOKBOOK, true)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("cookbook")
    inst.AnimState:SetBuild("cookbook")
    inst.AnimState:PlayAnimation("idle")

	inst.Transform:SetScale(1.2, 1.2, 1.2)

    MakeInventoryFloatable(inst, "med", nil, 0.75)

	-- for simplebook component
	inst:AddTag("simplebook")
    inst:AddTag("bookcabinet_item")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    -----------------------------------

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

	inst:AddComponent("simplebook")
	inst.components.simplebook.onreadfn = OnReadBook

    MakeSmallBurnable(inst, TUNING.MED_BURNTIME)
    MakeSmallPropagator(inst)

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("cookbook", fn, assets, prefabs)

