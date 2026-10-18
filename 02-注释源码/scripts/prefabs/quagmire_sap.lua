--============================================================
-- 文件：prefabs/quagmire_sap.lua
-- 模块：预制体 / quagmire_sap（建筑与容器）
-- 职责：实体「quagmire_sap」的预制体定义。SpawnPrefab("quagmire_sap") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_sap.zip"),
}

local prefabs =
{
    "quagmire_burnt_ingredients",
    "quagmire_syrup",
}

local function MakeSap(name, fresh)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddNetwork()

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBuild("quagmire_sap")
        inst.AnimState:SetBank("quagmire_sap")
        inst.AnimState:PlayAnimation(fresh and "idle" or "idle_spoiled")

        if fresh then
            inst:AddTag("quagmire_stewable")
        end

        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        event_server_data("quagmire", "prefabs/quagmire_sap").master_postinit(inst, fresh)

        return inst
    end

    return Prefab(name, fn, assets, fresh and prefabs or nil)
end

return MakeSap("quagmire_sap", true),
    MakeSap("quagmire_sap_spoiled", false)
