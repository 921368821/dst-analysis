--============================================================
-- 文件：prefabs/yotb_pattern_fragments.lua
-- 模块：预制体 / yotb_pattern_fragments（建筑与容器）
-- 职责：实体「yotb_pattern_fragments」的预制体定义。SpawnPrefab("yotb_pattern_fragments") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/yotb_pattern_fragment_1.zip"),
    Asset("ANIM", "anim/yotb_pattern_fragment_2.zip"),
    Asset("ANIM", "anim/yotb_pattern_fragment_3.zip"),
}

local function make(name,bank)

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank(bank)
        inst.AnimState:SetBuild(name)
        inst.AnimState:PlayAnimation("idle")

        inst:AddTag("cattoy")
        inst:AddTag("yotb_pattern_fragment")

        MakeInventoryFloatable(inst, "med", 0.05, 0.68)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("inventoryitem")

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        inst:AddComponent("inspectable")
        inst:AddComponent("tradable")

        inst:AddComponent("fuel")
        inst.components.fuel.fuelvalue = TUNING.SMALL_FUEL

        MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
        MakeSmallPropagator(inst)

        MakeHauntableLaunchAndIgnite(inst)

        return inst
    end

    return Prefab(name, fn, assets, prefabs)
end

return  make("yotb_pattern_fragment_1","pattern_fragment_1"),
        make("yotb_pattern_fragment_2","pattern_fragment_2"),
        make("yotb_pattern_fragment_3","pattern_fragment_3")
