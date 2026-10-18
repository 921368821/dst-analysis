--============================================================
-- 文件：prefabs/inv_marble.lua
-- 模块：预制体 / inv_marble（建筑与容器）
-- 职责：实体「inv_marble」的预制体定义。SpawnPrefab("inv_marble") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/marble.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("marble")
    inst.AnimState:SetBuild("marble")
    inst.AnimState:PlayAnimation("anim")

    inst.pickupsound = "rock"

    inst:AddTag("molebait")
    inst:AddTag("quakedebris")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

	inst:AddComponent("snowmandecor")

    MakeHauntableLaunchAndSmash(inst)

    inst:AddComponent("bait")

    return inst
end

return Prefab("marble", fn, assets)
