--============================================================
-- 文件：prefabs/dirtpile.lua
-- 模块：预制体 / dirtpile（建筑与容器）
-- 职责：实体「dirtpile」的预制体定义。SpawnPrefab("dirtpile") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets = {
    Asset("ANIM", "anim/koalefant_tracks.zip"),
    Asset("ANIM", "anim/smoke_puff_small.zip"),
}

local prefabs = {
    "small_puff"
}

local function GetVerb()
    return "INVESTIGATE"
end

local function OnInvestigated(inst, doer)
    local px, py, pz = inst.Transform:GetWorldPosition()

    local hunter = TheWorld.components.hunter
    if hunter ~= nil then
        hunter:OnDirtInvestigated(Vector3(px, py, pz), doer)
    end

    SpawnPrefab("small_puff").Transform:SetPosition(px, py, pz)
    inst:Remove()
end

local function OnHaunted(inst, haunter)
    --if haunter.isplayer then
        inst:OnInvestigated(haunter)
   -- end
    return true
end

local function create()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst:AddTag("dirtpile")

    inst.AnimState:SetBank("track")
    inst.AnimState:SetBuild("koalefant_tracks")
    inst.AnimState:SetRayTestOnBB(true)
    inst.AnimState:PlayAnimation("idle_pile")

    inst.GetActivateVerb = GetVerb

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.OnInvestigated = OnInvestigated

    inst:AddComponent("inspectable")

    local activatable = inst:AddComponent("activatable")
    activatable.OnActivate = inst.OnInvestigated
    activatable.inactive = true

    local hauntable = inst:AddComponent("hauntable")
    hauntable:SetHauntValue(TUNING.HAUNT_SMALL)
    hauntable:SetOnHauntFn(OnHaunted)

    inst.persists = false
    return inst
end

return Prefab("dirtpile", create, assets, prefabs)