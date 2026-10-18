--============================================================
-- 文件：prefabs/saltrock.lua
-- 模块：预制体 / saltrock（建筑与容器）
-- 职责：实体「saltrock」的预制体定义。SpawnPrefab("saltrock") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/salt.zip"),
}

local CACHED_SALT_LICK_IMPROVED_RECIPE_COST = nil

local function CacheSaltLickImprovedRecipeCost(default)
    local saltlickrecipe = AllRecipes.saltlick_improved

    if saltlickrecipe == nil or saltlickrecipe.ingredients == nil then
        return default
    end

    local neededsalt = 0

    for _, ingredient in ipairs(saltlickrecipe.ingredients) do
        if ingredient.type == "saltrock" then
            neededsalt = neededsalt + ingredient.amount
        end
    end

    return neededsalt > 0 and neededsalt or default
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetRayTestOnBB(true)
    inst.AnimState:SetBank("salt")
    inst.AnimState:SetBuild("salt")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "rock"

    inst:AddTag("molebait")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    if CACHED_SALT_LICK_IMPROVED_RECIPE_COST == nil then
        CACHED_SALT_LICK_IMPROVED_RECIPE_COST = CacheSaltLickImprovedRecipeCost(6)
    end

    inst:AddComponent("bait")
    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")
    inst:AddComponent("tradable")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ELEMENTAL
    inst.components.edible.hungervalue = 1

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("preservative")
    inst.components.preservative.percent_increase = TUNING.SALTROCK_PRESERVE_PERCENT_ADD

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.SALT
    inst.components.repairer.finiteusesrepairvalue = TUNING.SALTLICK_IMPROVED_MAX_LICKS / CACHED_SALT_LICK_IMPROVED_RECIPE_COST

    MakeHauntableLaunchAndSmash(inst)

    return inst
end

return Prefab("saltrock", fn, assets)
