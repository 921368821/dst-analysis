--============================================================
-- 文件：prefabs/animal_track.lua
-- 模块：预制体 / animal_track（建筑与容器）
-- 职责：实体「animal_track」的预制体定义。SpawnPrefab("animal_track") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets = {
    Asset("ANIM", "anim/koalefant_tracks.zip"),
}

local FADE_DURATION = 15
local FADE_DT = FRAMES

local function ApplyFade(inst)
    local k = inst._fadetime / FADE_DURATION
    inst.AnimState:SetMultColour(1, 1, 1, math.max(k - (1 - inst._basealpha), 0))
end

local function fadeout(inst)
    if inst._fadetime > FADE_DT then
        inst._fadetime = inst._fadetime - FADE_DT
        ApplyFade(inst)
    else
        inst:Remove()
    end
end

local function SetBaseAlpha(inst, base)
    inst._basealpha = base
    ApplyFade(inst)
end

local scrapbook_adddeps = {
    "koalefant_summer",
    "koalefant_winter",
    "lightninggoat",
    "warg",
    "spat",
    "dirtpile",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst:AddTag("track")

    inst.AnimState:SetBank("track")
    inst.AnimState:SetBuild("koalefant_tracks")
    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)
    inst.AnimState:SetRayTestOnBB(true)
    inst.AnimState:PlayAnimation("idle")

    inst.scrapbook_specialinfo = "ANIMALTRACK"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.scrapbook_adddeps = scrapbook_adddeps

    inst:AddComponent("inspectable")

    inst._fadetime = FADE_DURATION
    inst._basealpha = 1

    inst.SetBaseAlpha = SetBaseAlpha
    inst:DoPeriodicTask(FADE_DT, fadeout, 30)

    inst.persists = false

    return inst
end

return Prefab("animal_track", fn, assets)