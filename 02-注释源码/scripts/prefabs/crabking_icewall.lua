--============================================================
-- 文件：prefabs/crabking_icewall.lua
-- 模块：预制体 / crabking_icewall（建筑与容器）
-- 职责：实体「crabking_icewall」的预制体定义。SpawnPrefab("crabking_icewall") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/sharkboi_icespike.zip"),
    Asset("ANIM", "anim/sharkboi_iceplow_fx.zip"),
}

local prefabs = {}

------------------------------------------------------------------------------------------------------------------------

local RADIUS = 0.8
local NUM_VARIATIONS = 3

------------------------------------------------------------------------------------------------------------------------

local function SetVariation(inst, variation)
    if inst.AnimState:IsCurrentAnimation("spike"..tostring(inst.variation).."_pre") then
        local t = inst.AnimState:GetCurrentAnimationTime()
        inst.AnimState:PlayAnimation("spike"..tostring(variation).."_pre")
        inst.AnimState:SetTime(t)
        inst.AnimState:PushAnimation("spike"..tostring(variation), false)

    elseif inst.components.health:GetPercent() <= 0.5 then
        inst.AnimState:PlayAnimation("spike"..tostring(variation).."_low")

    else
        inst.AnimState:PlayAnimation("spike"..tostring(variation))
    end

    inst.variation = variation
end

local function OnHealthDelta(inst, oldpercent, newpercent)
    if newpercent <= 0 then
        inst.SoundEmitter:PlaySound("dontstarve_DLC001/common/iceboulder_smash")

        inst.persists = false
        inst.Physics:SetActive(false)
        inst:AddTag("FX")
        inst:AddTag("NOCLICK")
        inst.AnimState:SetBuild("sharkboi_iceplow_fx")

        local variation = math.random(2)

        inst.AnimState:SetBankAndPlayAnimation("sharkboi_iceplow_fx", "iceplow"..tostring(variation).."_pre")
        inst.AnimState:PushAnimation("iceplow"..tostring(variation).."_pst", false)

        if math.random() < 0.5 then
            inst.AnimState:SetScale(-1, 1)
        end

        inst:ListenForEvent("animqueueover", inst.Remove)

        return
    end

    inst.SoundEmitter:PlaySound("meta3/sharkboi/ice_spike_break")

    local animname = "spike"..tostring(inst.variation).."_low"

    if newpercent <= 0.5 and not inst.AnimState:IsCurrentAnimation(animname) then
        inst.AnimState:PlayAnimation(animname)
    end
end

------------------------------------------------------------------------------------------------------------------------

local function OnSave(inst, data)
    data.variation = inst.variation ~= 1 and inst.variation or nil
end

local function OnLoad(inst, data)
    inst:SetVariation(data and data.variation or 1)
end

------------------------------------------------------------------------------------------------------------------------

local function IceWallFn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddPhysics()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.Transform:SetSixFaced()

    inst.AnimState:SetBank("sharkboi_icespike")
    inst.AnimState:SetBuild("sharkboi_icespike")
    inst.AnimState:PlayAnimation("spike1_pre")

    MakeObstaclePhysics(inst, RADIUS, 2)

    inst:AddTag("crabking_icewall")
    inst:AddTag("crabking_ally")
    inst:AddTag("frozen")
    inst:AddTag("hostile")
    inst:AddTag("soulless")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.variation = 1
    inst.AnimState:PushAnimation("spike1", false)

    inst.SetVariation = SetVariation

    inst:AddComponent("inspectable")
    inst:AddComponent("savedrotation")

    inst:AddComponent("combat")
    inst.components.combat.noimpactsound = true

    inst:AddComponent("health")
    inst.components.health.nofadeout = true
    inst.components.health.save_maxhealth = true
    inst.components.health.canheal = false
    inst.components.health.ondelta = OnHealthDelta
    inst.components.health:SetMaxHealth(TUNING.CRABKING_ICEWALL_HEALTH)

    if not POPULATING then
        inst:SetVariation(math.random(NUM_VARIATIONS))
    end

    inst.OnSave = OnSave
    inst.OnLoad = OnLoad

    MakeHauntable(inst)

    return inst
end

return Prefab("crabking_icewall", IceWallFn, assets, prefabs)