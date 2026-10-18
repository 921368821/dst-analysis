--============================================================
-- 文件：prefabs/slurtle_shellpieces.lua
-- 模块：预制体 / slurtle_shellpieces（建筑与容器）
-- 职责：实体「slurtle_shellpieces」的预制体定义。SpawnPrefab("slurtle_shellpieces") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/slurtle_shellpieces.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("slurtle_shellpieces")
    inst.AnimState:SetBuild("slurtle_shellpieces")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", nil, 0.75)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.SHELL
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_SHELL_HEALTH

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("slurtle_shellpieces", fn, assets)