--============================================================
-- 文件：prefabs/carpentry_blades.lua
-- 模块：预制体 / carpentry_blades（建筑与容器）
-- 职责：实体「carpentry_blades」的预制体定义。SpawnPrefab("carpentry_blades") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SCRAPBOOK_DEPENDENCIES = { "carpentry_station" }

local BANK_NAME = "carpentry_blade_moonglass"

local function MakeBlade(material, tech_level)
    assert(TUNING.PROTOTYPER_TREES[tech_level] ~= nil, string.format("TUNING.PROTOTYPER_TREES.%s is nil", tech_level))

    local name = "carpentry_blade_"..material
    local build_override = "carpentry_station_"..material.."_build"

    local assets = {
        Asset("ANIM", "anim/"..BANK_NAME..".zip"),
        Asset("ANIM", "anim/"..build_override..".zip"),
    }

    if name ~= BANK_NAME then
        table.insert(assets, Asset("ANIM", "anim/"..name..".zip"))
    end

    local function BladeFn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank(BANK_NAME)
        inst.AnimState:SetBuild(name)
        inst.AnimState:PlayAnimation("idle")

        inst:AddTag("carpentry_blade")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst.scrapbook_adddeps = SCRAPBOOK_DEPENDENCIES

        inst.blade_tech_tree = TUNING.PROTOTYPER_TREES[tech_level]
        inst.build_override = build_override

        inst:AddComponent("inspectable")

        inst:AddComponent("inventoryitem")
        inst.components.inventoryitem:SetSinks(true)

        MakeHauntableLaunch(inst)

        return inst
    end

    return Prefab(name, BladeFn, assets)
end

return MakeBlade("moonglass", "CARPENTRY_STATION_STONE") -- For searching: "carpentry_blade_moonglass"
