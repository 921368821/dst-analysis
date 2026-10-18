--============================================================
-- 文件：prefabs/marionette_fx.lua
-- 模块：预制体 / marionette_fx（建筑与容器）
-- 职责：实体「marionette_fx」的预制体定义。SpawnPrefab("marionette_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/marionette_fx.zip"),
}

local DEFAULT_ALPHA = 0.8

local function fade_step(value, inst)
    inst.AnimState:SetMultColour(1, 1, 1, value)
end

local function do_appear_fadeout(inst)
    inst.components.fader:Fade(DEFAULT_ALPHA, 0, 15*FRAMES, fade_step, inst.Remove)
end

local function SetAppearFadeTime(inst, time)
    if inst._fadeout_task ~= nil then
        inst._fadeout_task:Cancel()
    end

    inst._fadeout_task = inst:DoTaskInTime(time or FRAMES, do_appear_fadeout)
end

local function marionette_appear_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.AnimState:SetBank("marionette_fx")
    inst.AnimState:SetBuild("marionette_fx")
    inst.AnimState:PlayAnimation("appear")
    inst.SoundEmitter:PlaySound("stageplay_set/marionette/appear")
    inst.AnimState:PushAnimation("loop", true)
    inst.AnimState:SetMultColour(1, 1, 1, DEFAULT_ALPHA)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.SoundEmitter:PlaySound("stageplay_set/marionette/appear")

    inst.persists = false

    inst:AddComponent("fader")

    inst._fadeout_task = inst:DoTaskInTime(FRAMES, do_appear_fadeout)
    inst.SetTime = SetAppearFadeTime

    return inst
end

--------------------------------------------------------------------------------

local function do_disappear_exit(inst)
    inst.AnimState:PlayAnimation("dissappear")
    inst:ListenForEvent("animover", inst.Remove)

    inst.SoundEmitter:PlaySound("stageplay_set/marionette/disappear")
end

local function SetDisappearExitTime(inst, time)
    if inst._exit_task ~= nil then
        inst._exit_task:Cancel()
    end

    inst._exit_task = inst:DoTaskInTime(time or FRAMES, do_disappear_exit)
end

local function marionette_disappear_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.AnimState:SetBank("marionette_fx")
    inst.AnimState:SetBuild("marionette_fx")
    inst.AnimState:PlayAnimation("loop", true)
    inst.AnimState:SetMultColour(1, 1, 1, 0)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    inst:AddComponent("fader")
    inst.components.fader:Fade(0, DEFAULT_ALPHA, 15*FRAMES, fade_step)

    inst._exit_task = inst:DoTaskInTime(FRAMES, do_disappear_exit)
    inst.SetTime = SetDisappearExitTime

    return inst
end

return Prefab("marionette_appear_fx", marionette_appear_fn, assets),
    Prefab("marionette_disappear_fx", marionette_disappear_fn, assets)