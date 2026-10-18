--============================================================
-- 文件：prefabs/lavaarena_lootbeacon.lua
-- 模块：预制体 / lavaarena_lootbeacon（建筑与容器）
-- 职责：实体「lavaarena_lootbeacon」的预制体定义。SpawnPrefab("lavaarena_lootbeacon") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/lavaarena_item_pickup_fx.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("lavaarena_item_pickup_fx")
    inst.AnimState:SetBuild("lavaarena_item_pickup_fx")
    inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
    inst.AnimState:SetFinalOffset(1)

    inst:AddTag("DECOR")
    inst:AddTag("NOCLICK")

    inst:Hide()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("lavaarena", "prefabs/lavaarena_lootbeacon").master_postinit(inst)

    return inst
end

return Prefab("lavaarena_lootbeacon", fn, assets)
