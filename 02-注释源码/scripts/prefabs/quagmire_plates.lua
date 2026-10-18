--============================================================
-- 文件：prefabs/quagmire_plates.lua
-- 模块：预制体 / quagmire_plates（建筑与容器）
-- 职责：实体「quagmire_plates」的预制体定义。SpawnPrefab("quagmire_plates") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function MakePlate(basedish, dishtype, assets)
    local assets =
    {
        Asset("ANIM", "anim/quagmire_generic_"..basedish..".zip"),
        Asset("ATLAS", "images/quagmire_food_common_inv_images.xml"),
        Asset("IMAGE", "images/quagmire_food_common_inv_images.tex"),
    }

    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("quagmire_generic_"..basedish)
        inst.AnimState:SetBuild("quagmire_generic_"..basedish)
        inst.AnimState:OverrideSymbol("generic_"..basedish, "quagmire_generic_"..basedish, dishtype.."_"..basedish)
        inst.AnimState:PlayAnimation("idle")

        inst:AddTag("quagmire_replater")

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        event_server_data("quagmire", "prefabs/quagmire_plates").master_postinit(inst, basedish, dishtype)

        return inst
    end

    return Prefab("quagmire_"..basedish.."_"..dishtype, fn, assets)
end

return MakePlate("plate", "silver"),
    MakePlate("bowl", "silver")
