--============================================================
-- 文件：prefabs/quagmire_safe.lua
-- 模块：预制体 / quagmire_safe（建筑与容器）
-- 职责：实体「quagmire_safe」的预制体定义。SpawnPrefab("quagmire_safe") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_safe.zip"),
    Asset("ANIM", "anim/quagmire_ui_chest_3x3.zip"),
}

local prefabs =
{
    "quagmire_key",
}

local function DisplayNameFn(inst)
    return inst.replica.container ~= nil
        and not inst.replica.container:CanBeOpened()
        and STRINGS.NAMES.QUAGMIRE_SAFE_LOCKED
        or nil
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("structure")

    inst.AnimState:SetBank("quagmire_safe")
    inst.AnimState:SetBuild("quagmire_safe")
    inst.AnimState:PlayAnimation("closed")

    MakeSnowCoveredPristine(inst)

    inst.displaynamefn = DisplayNameFn

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_safe").master_postinit(inst)

    return inst
end

return Prefab("quagmire_safe", fn, assets, prefabs)
