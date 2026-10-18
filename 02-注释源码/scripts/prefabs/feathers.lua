--============================================================
-- 文件：prefabs/feathers.lua
-- 模块：预制体 / feathers（建筑与容器）
-- 职责：实体「feathers」的预制体定义。SpawnPrefab("feathers") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function makefeather(name)
    local assetname = "feather_"..name
    local assets =
    {
        Asset("ANIM", "anim/"..assetname..".zip"),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank(assetname)
        inst.AnimState:SetBuild(assetname)
        inst.AnimState:PlayAnimation("idle")

        inst.pickupsound = "cloth"

        inst:AddTag("cattoy")
        inst:AddTag("birdfeather")

        MakeInventoryFloatable(inst, "small", 0.05, 0.95)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        inst:AddComponent("inspectable")

        MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
        MakeSmallPropagator(inst)

        inst:AddComponent("fuel")
        inst.components.fuel.fuelvalue = TUNING.TINY_FUEL

        MakeHauntableLaunchAndIgnite(inst)

        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem.nobounce = true

        inst:AddComponent("tradable")

		inst:AddComponent("snowmandecor")

        return inst
    end
    return Prefab( assetname, fn, assets)
end

return makefeather("crow"),
    makefeather("robin"),
    makefeather("robin_winter"),
    makefeather("canary")
