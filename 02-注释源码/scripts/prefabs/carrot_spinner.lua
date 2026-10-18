--============================================================
-- 文件：prefabs/carrot_spinner.lua
-- 模块：预制体 / carrot_spinner（建筑与容器）
-- 职责：实体「carrot_spinner」的预制体定义。SpawnPrefab("carrot_spinner") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/carrot_spinner.zip"),
}

------------------------------------------------------------------------------------------------------

local FADEIN_TIMERNAME  = "begin_delay"
local FADEOUT_TIMERNAME = "end_delay"

local FADEIN_DURATION  = 0.5
local FADEOUT_DURATION = 3.0

local FADEIN_ALPHA = 2/30
local FADEOUT_ALPHA = 1/30

------------------------------------------------------------------------------------------------------

local function OnTimerDone(inst, data)
    inst.fadein  = data.name == FADEIN_TIMERNAME
    inst.fadeout = data.name == FADEOUT_TIMERNAME
end

local function OnUpdate(inst)
    if inst.fadein then
        inst.alpha = inst.alpha + FADEIN_ALPHA

        if inst.alpha > 0.6 then
            inst.alpha = 0.6
            inst.fadein = nil
        end

        inst.AnimState:SetMultColour(1, 1, 1, inst.alpha)

    elseif inst.fadeout then
        inst.alpha = inst.alpha - FADEOUT_ALPHA
        inst.AnimState:SetMultColour(1, 1, 1, inst.alpha)

        if inst.alpha < 0 then
            inst:Remove()
        end
    end
end

local function AttachTo(inst, owner)
    inst.Transform:SetPosition(owner.Transform:GetWorldPosition())
    inst.Transform:SetRotation(owner.Transform:GetRotation())

    inst:ListenForEvent("onremove", function(owner) inst:FadeOut() end, owner)
end

local function FadeOut(inst)
    inst:RemoveComponent("timer")

    inst.fadeout = true
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(3)

    inst.AnimState:SetMultColour(1, 1, 1, 0)

    inst.AnimState:SetBank("carrot_spinner")
    inst.AnimState:SetBuild("carrot_spinner")
    inst.AnimState:PlayAnimation("idle_smear")

    inst:AddTag("FX")
    inst:AddTag("NOCLICK")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.alpha = 0

    inst.OnTimerDone = OnTimerDone
    inst.AttachTo = AttachTo
    inst.FadeOut = FadeOut

    inst:AddComponent("timer")
    inst.components.timer:StartTimer(FADEIN_TIMERNAME,  FADEIN_DURATION )
    inst.components.timer:StartTimer(FADEOUT_TIMERNAME, FADEOUT_DURATION)

    inst:AddComponent("updatelooper")
    inst.components.updatelooper:AddOnUpdateFn(OnUpdate)

    inst:ListenForEvent("timerdone", inst.OnTimerDone)

    inst.persists = false

    return inst
end

return Prefab("carrot_spinner", fn, assets)
