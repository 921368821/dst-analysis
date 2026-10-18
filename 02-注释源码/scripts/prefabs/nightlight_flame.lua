--============================================================
-- 文件：prefabs/nightlight_flame.lua
-- 模块：预制体 / nightlight_flame（建筑与容器）
-- 职责：实体「nightlight_flame」的预制体定义。SpawnPrefab("nightlight_flame") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    --Asset("ANIM", "anim/fire_large_character.zip"),
    Asset("ANIM", "anim/campfire_fire.zip"),
    Asset("SOUND", "sound/common.fsb"),
}

local prefabs =
{
    "firefx_light",
}

local firelevels =
{
    {anim="level1", sound="dontstarve/common/nightlight", radius=2, intensity=.8, falloff=.33, colour = {253/255,179/255,179/255}, soundintensity=.1},
    {anim="level2", sound="dontstarve/common/nightlight", radius=3, intensity=.8, falloff=.33, colour = {253/255,179/255,179/255}, soundintensity=.3},
    {anim="level3", sound="dontstarve/common/nightlight", radius=4, intensity=.8, falloff=.33, colour = {253/255,179/255,179/255}, soundintensity=.6},
    {anim="level4", sound="dontstarve/common/nightlight", radius=5, intensity=.8, falloff=.33, colour = {253/255,179/255,179/255}, soundintensity=1},
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("campfire_fire")
    inst.AnimState:SetBuild("campfire_fire")
    inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")
    inst.AnimState:SetMultColour(0, 0, 0, .6)
    inst.AnimState:SetRayTestOnBB(true)
    inst.AnimState:SetFinalOffset(3)

    inst:AddTag("FX")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("firefx")
    inst.components.firefx.levels = firelevels

    return inst
end

return Prefab("nightlight_flame", fn, assets, prefabs)
