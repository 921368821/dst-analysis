--============================================================
-- 文件：prefabs/wereitems.lua
-- 模块：预制体 / wereitems（建筑与容器）
-- 职责：实体「wereitems」的预制体定义。SpawnPrefab("wereitems") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wereitems.zip"),
}

local prefabs =
{

}

local function GetHealthFn(inst, eater)
    return eater ~= nil and eater:HasTag("cursemaster") and 0 or -TUNING.HEALING_MED
end

local function GetSanityFn(inst, eater)
    return eater ~= nil and eater:HasTag("cursemaster") and 0 or -TUNING.SANITY_MED
end

local function MakeWereItem(were_mode)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("wereitems")
        inst.AnimState:SetBuild("wereitems")
        inst.AnimState:PlayAnimation("idle_"..were_mode)
        inst.scrapbook_anim = "idle_"..were_mode

        inst:AddTag("monstermeat")
        inst:AddTag("wereitem")
        inst:AddTag("unsafefood")

        if were_mode == "goose" then
            MakeInventoryFloatable(inst, "small", .15, { 1.3, 1.1, 1.3 })
        else
            MakeInventoryFloatable(inst, "small", .2)
        end

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("edible")
        inst.components.edible.ismeat = true
        inst.components.edible.foodtype = FOODTYPE.MEAT
        inst.components.edible.hungervalue = TUNING.CALORIES_MED
        inst.components.edible:SetGetHealthFn(GetHealthFn)
        inst.components.edible:SetGetSanityFn(GetSanityFn)

        inst.scrapbook_healthvalue = -TUNING.HEALING_MED
        inst.scrapbook_sanityvalue = -TUNING.SANITY_MED

        inst:AddComponent("bait")
        inst:AddComponent("tradable")

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM

        MakeSmallBurnable(inst)
        MakeSmallPropagator(inst)
        MakeHauntableLaunchAndPerish(inst)

        inst.were_mode = were_mode

        return inst
    end

    return Prefab("wereitem_"..were_mode, fn, assets, prefabs)
end

return
    MakeWereItem("beaver"), -- "wereitem_beaver", Search strings!
    MakeWereItem("moose"), -- "wereitem_moose",
    MakeWereItem("goose") -- "wereitem_goose",
