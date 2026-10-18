--============================================================
-- 文件：prefabs/cookiecuttershell.lua
-- 模块：预制体 / cookiecuttershell（建筑与容器）
-- 职责：实体「cookiecuttershell」的预制体定义。SpawnPrefab("cookiecuttershell") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cookiecuttershell.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("cookiecutter_shell")
    inst.AnimState:SetBuild("cookiecuttershell")
    inst.AnimState:PlayAnimation("idle")

	MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("tradable")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_MEDITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    MakeHauntableLaunchAndSmash(inst)

    return inst
end

return Prefab("cookiecuttershell", fn, assets)
