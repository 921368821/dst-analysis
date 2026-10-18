--============================================================
-- 文件：prefabs/damp_trail.lua
-- 模块：预制体 / damp_trail（建筑与容器）
-- 职责：实体「damp_trail」的预制体定义。SpawnPrefab("damp_trail") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/damp_trail.zip"),
}

local function OnStartFade(inst)
    inst.task = nil
    inst.AnimState:PlayAnimation(inst.trailname.."_pst")
end

local function OnAnimOver(inst)
    if inst.AnimState:IsCurrentAnimation(inst.trailname.."_pre") then
        inst.AnimState:PlayAnimation(inst.trailname)
        if inst.task ~= nil then
            inst.task:Cancel()
        end
        inst.task = inst:DoTaskInTime(inst.duration, OnStartFade)
    elseif inst.AnimState:IsCurrentAnimation(inst.trailname.."_pst") then
        inst:Remove()
    end
end

local function SetVariation(inst, rand, scale, duration)
    if inst.trailname == nil then
        inst.task:Cancel()
        inst.task = nil

        inst.Transform:SetScale(scale, scale, scale)

        inst.trailname = "trail"..tostring(rand)
        inst.duration = duration
        inst.AnimState:PlayAnimation(inst.trailname.."_pre")
        inst:ListenForEvent("animover", OnAnimOver)
    end
end

local function Refresh(inst)
    if inst.trailname ~= nil and inst.task ~= nil then
        inst.task:Cancel()
        inst.task = inst:DoTaskInTime(inst.duration, OnStartFade)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.AnimState:SetBank("damp_trail")
    inst.AnimState:SetBuild("damp_trail")
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.SetVariation = SetVariation
    inst.Refresh = Refresh

    inst.persists = false
    inst.task = inst:DoTaskInTime(0, inst.Remove)

    return inst
end

return Prefab("damp_trail", fn, assets)
