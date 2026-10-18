--============================================================
-- 文件：prefabs/pocketwatch_dismantler.lua
-- 模块：预制体 / pocketwatch_dismantler（建筑与容器）
-- 职责：实体「pocketwatch_dismantler」的预制体定义。SpawnPrefab("pocketwatch_dismantler") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pocketwatch_dismantler.zip"),
}

local prefabs = 
{
	"brokentool",
	"shadow_puff_solid",
}


local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("pocketwatch_dismantler")
    inst.AnimState:SetBuild("pocketwatch_dismantler")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "small", 0.05, {1.2, 0.75, 1.2})

    inst.scrapbook_specialinfo = "POCKETWATCHDISMANTLER"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

    inst:AddComponent("pocketwatch_dismantler")
	
    inst:AddComponent("inspectable")

	MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("pocketwatch_dismantler", fn, assets, prefabs)