--============================================================
-- 文件：prefabs/carnival_gametoken.lua
-- 模块：预制体 / carnival_gametoken（建筑与容器）
-- 职责：实体「carnival_gametoken」的预制体定义。SpawnPrefab("carnival_gametoken") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/carnival_gametoken.zip"),
    Asset("INV_IMAGE", "carnival_gametoken_multiple"), -- for crafting menu
}

local function shine(inst)
    if not inst.AnimState:IsCurrentAnimation("sparkle") then
        inst.AnimState:PlayAnimation("sparkle")
        inst.AnimState:PushAnimation("idle", false)
    end
    inst:DoTaskInTime(4 + math.random() * 5, shine)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("carnival_gametoken")
    inst.AnimState:SetBuild("carnival_gametoken")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("molebait")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ELEMENTAL
    inst.components.edible.hungervalue = 2

    inst:AddComponent("tradable")
	--inst.components.tradable.goldvalue = TUNING.GOLD_VALUES.CARNIVAL_GAMETOKEN

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("bait")

    MakeHauntableLaunch(inst)

    shine(inst)

    return inst
end

return Prefab("carnival_gametoken", fn, assets)
