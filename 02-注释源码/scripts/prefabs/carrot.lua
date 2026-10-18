--============================================================
-- 文件：prefabs/carrot.lua
-- 模块：预制体 / carrot（建筑与容器）
-- 职责：实体「carrot」的预制体定义。SpawnPrefab("carrot") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/carrot.zip"),
}

local prefabs =
{
    "carrot",
}

local function fn()
    --Carrot you eat is defined in veggies.lua
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("carrot")
    inst.AnimState:SetBuild("carrot")
    inst.AnimState:PlayAnimation("planted")
    inst.AnimState:SetRayTestOnBB(true)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.scrapbook_anim = "planted"

    inst:AddComponent("inspectable")

    inst:AddComponent("pickable")
    inst.components.pickable.picksound = "dontstarve/wilson/pickup_plants"
    inst.components.pickable:SetUp("carrot", 10)
	inst.components.pickable.remove_when_picked = true -- Triggers onremove event.

    inst.components.pickable.quickpick = true

    MakeSmallBurnable(inst)
    AddToRegrowthManager(inst)
    MakeSmallPropagator(inst)

	inst:AddComponent("halloweenmoonmutable")
	inst.components.halloweenmoonmutable:SetPrefabMutated("carrat_planted")

    inst:AddComponent("hauntable")
    inst.components.hauntable:SetHauntValue(TUNING.HAUNT_TINY)



    return inst
end

return Prefab("carrot_planted", fn, assets)
