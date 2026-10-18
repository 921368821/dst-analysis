--============================================================
-- 文件：prefabs/boneshard.lua
-- 模块：预制体 / boneshard（建筑与容器）
-- 职责：实体「boneshard」的预制体定义。SpawnPrefab("boneshard") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/bone_shards.zip")
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("bone_shards")
    inst.AnimState:SetBuild("bone_shards")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "rock"

    MakeInventoryFloatable(inst, "small", 0.15, 0.8)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")

	inst:AddComponent("snowmandecor")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("boneshard", fn, assets)
