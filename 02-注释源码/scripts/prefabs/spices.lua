--============================================================
-- 文件：prefabs/spices.lua
-- 模块：预制体 / spices（建筑与容器）
-- 职责：实体「spices」的预制体定义。SpawnPrefab("spices") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/spices.zip"),
}

local function MakeSpice(name)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("spices")
        inst.AnimState:SetBuild("spices")
        inst.AnimState:PlayAnimation("idle")
        inst.AnimState:OverrideSymbol("swap_spice", "spices", name)
        inst.scrapbook_overridedata={"swap_spice", "spices", name}

        inst:AddTag("spice")

        MakeInventoryFloatable(inst, "med", nil, (name == "spice_garlic" and 0.85) or 0.7)

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("stackable")
        inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

        inst:AddComponent("inspectable")
        inst:AddComponent("inventoryitem")

        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab(name, fn, assets)
end

return MakeSpice("spice_garlic"),
       MakeSpice("spice_sugar"),
       MakeSpice("spice_chili"),
       MakeSpice("spice_salt")
