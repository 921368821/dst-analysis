--============================================================
-- 文件：prefabs/wintersfeastcookedfoods.lua
-- 模块：预制体 / wintersfeastcookedfoods（建筑与容器）
-- 职责：实体「wintersfeastcookedfoods」的预制体定义。SpawnPrefab("wintersfeastcookedfoods") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "tuning"
local fooddef = require("wintersfeastcookedfoods")

local function MakeFood(name)
    local assets =
    {
		Asset("ANIM", "anim/food_winters_feast_2019.zip"),
        Asset("INV_IMAGE", name),
    }

    local prefabs =
    {
        --"spoiled_food",
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("food_winters_feast_2019")
        inst.AnimState:SetBuild("food_winters_feast_2019")
        inst.AnimState:PlayAnimation("idle")
		inst.AnimState:OverrideSymbol("swap_food", "food_winters_feast_2019", name)
        inst.scrapbook_overridedata = {"swap_food", "food_winters_feast_2019", name}
        inst.scrapbook_specialinfo = "WINTERSFEASTCOOKEDFOODS"

		local data = fooddef.foods[name]

        local float = data.floater
        if float ~= nil then
            MakeInventoryFloatable(inst, float[1], float[2], float[3])
        else
            MakeInventoryFloatable(inst)
        end

		inst:AddTag("wintersfeastcookedfood")

		inst.wet_prefix = data.wet_prefix

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

		local uses = data.uses or TUNING.WINTERSFEASTBUFF.EATTIME
		inst:AddComponent("finiteuses")
		inst.components.finiteuses:SetMaxUses(uses)
		inst.components.finiteuses:SetUses(uses)
		--inst.components.finiteuses:SetOnFinished(inst.Remove) -- removed by the winters feast table

        inst:AddComponent("inspectable")

        inst:AddComponent("inventoryitem")

        MakeSmallBurnable(inst)
        MakeSmallPropagator(inst)
		MakeHauntableLaunchAndPerish(inst)

        inst:AddComponent("bait")

        inst:AddComponent("tradable")

        return inst
    end

    return Prefab(name, fn, assets, prefabs)
end

local prefs = {}
for foodname,fooddata in pairs(fooddef.foods) do
    table.insert(prefs, MakeFood(foodname))
end

return unpack(prefs)
