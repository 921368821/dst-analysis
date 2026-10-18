--============================================================
-- 文件：prefabs/antliontrinket.lua
-- 模块：预制体 / antliontrinket（建筑与容器）
-- 职责：实体「antliontrinket」的预制体定义。SpawnPrefab("antliontrinket") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/antliontrinket.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("antliontrinket")
    inst.AnimState:SetBuild("antliontrinket")
    inst.AnimState:PlayAnimation("1")
    inst.scrapbook_anim = "1"

    inst:AddTag("molebait")

	MakeInventoryFloatable(inst, "med", nil, 0.65)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("tradable")
    inst.components.tradable.goldvalue = TUNING.GOLD_VALUES.ANTLION
    inst.components.tradable.rocktribute = 9

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("antliontrinket", fn, assets)
