--============================================================
-- 文件：prefabs/sewing_tape.lua
-- 模块：预制体 / sewing_tape（建筑与容器）
-- 职责：实体「sewing_tape」的预制体定义。SpawnPrefab("sewing_tape") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/sewing_tape.zip"),
    Asset("ANIM", "anim/boat_repair_tape_build.zip"),
}

local function onsewn(inst, target, doer)
    doer:PushEvent("repair")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("tape")
    inst.AnimState:SetBuild("sewing_tape")
    inst.AnimState:PlayAnimation("idle")

	inst:AddTag("tape")

    --boat_patch (from boatpatch component) added to pristine state for optimization
    inst:AddTag("boat_patch")

    MakeInventoryFloatable(inst, "small", nil, 0.8)

    inst.scrapbook_specialinfo = "SEWINGTAPE"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("boatpatch")
    inst.components.boatpatch.patch_type = "tape"

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("sewing")
    inst.components.sewing.repair_value = TUNING.SEWING_TAPE_REPAIR_VALUE
    inst.components.sewing.onsewn = onsewn
    ---------------------

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("sewing_tape", fn, assets)