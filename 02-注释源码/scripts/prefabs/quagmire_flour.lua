--============================================================
-- 文件：prefabs/quagmire_flour.lua
-- 模块：预制体 / quagmire_flour（建筑与容器）
-- 职责：实体「quagmire_flour」的预制体定义。SpawnPrefab("quagmire_flour") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_flour.zip"),
}

local prefabs =
{
    "quagmire_burnt_ingredients",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_flour")
    inst.AnimState:SetBuild("quagmire_flour")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("quagmire_stewable")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_flour").master_postinit(inst)

    return inst
end

return Prefab("quagmire_flour", fn, assets, prefabs)
