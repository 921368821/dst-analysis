--============================================================
-- 文件：prefabs/pocket_scale.lua
-- 模块：预制体 / pocket_scale（建筑与容器）
-- 职责：实体「pocket_scale」的预制体定义。SpawnPrefab("pocket_scale") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pocket_scale.zip"),
}

local function doweight(inst, target, doer)
	if inst.components.finiteuses then
		inst.components.finiteuses:Use(1)
	end
	return true
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("pocket_scale")
    inst.AnimState:SetBuild("pocket_scale")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "small", 0.0, 0.8)

    --trophyscale_fish (from itemweigher component) added to pristine state for optimization
	inst:AddTag("trophyscale_fish")
    inst:AddTag("donotautopick")

    inst.scrapbook_specialinfo = "POCKETSCALE"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("finiteuses")
    inst.components.finiteuses:SetMaxUses(TUNING.POCKETSCALE_USES)
    inst.components.finiteuses:SetUses(TUNING.POCKETSCALE_USES)
    inst.components.finiteuses:SetOnFinished(inst.Remove)

	inst:AddComponent("itemweigher")
	inst.components.itemweigher.type = TROPHYSCALE_TYPES.FISH
	inst.components.itemweigher:SetOnDoWeighInFn(doweight)

    inst:AddComponent("inventoryitem")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.TINY_FUEL

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("pocket_scale", fn, assets)
