--============================================================
-- 文件：prefabs/wortox_soul_in_fx.lua
-- 模块：预制体 / wortox_soul_in_fx（建筑与容器）
-- 职责：实体「wortox_soul_in_fx」的预制体定义。SpawnPrefab("wortox_soul_in_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wortox_soul_ball.zip"),
}

local SCALE = .8
local TINT = { r = 154 / 255, g = 23 / 255, b = 19 / 255 }

local function PushColour(inst, addval, multval)
    if inst.components.highlight == nil then
        inst.AnimState:SetHighlightColour(TINT.r * addval, TINT.g * addval, TINT.b * addval, 0)
        inst.AnimState:OverrideMultColour(multval, multval, multval, 1)
    else
        inst.AnimState:OverrideMultColour()
    end
end

local function PopColour(inst)
    if inst.components.highlight == nil then
        inst.AnimState:SetHighlightColour()
    end
    inst.AnimState:OverrideMultColour()
end

local function OnUpdateTargetTint(inst)--, dt)
    if inst._tinttarget:IsValid() then
		local curframe = inst.AnimState:GetCurrentAnimationFrame()
        if curframe < 10 then
            local k = curframe / 10
            k = k * k
            PushColour(inst._tinttarget, (1 - k) * .7, k * .7 + .3)
        else
            inst.components.updatelooper:RemoveOnUpdateFn(OnUpdateTargetTint)
            inst.OnRemoveEntity = nil
            PopColour(inst._tinttarget)
        end
    else
        inst.components.updatelooper:RemoveOnUpdateFn(OnUpdateTargetTint)
        inst.OnRemoveEntity = nil
    end
end

local function OnRemoveEntity(inst)
    if inst._tinttarget:IsValid() then
        PopColour(inst._tinttarget)
    end
end

local function OnTargetDirty(inst)
    if inst._target:value() ~= nil and inst._tinttarget == nil then
        if inst.components.updatelooper == nil then
            inst:AddComponent("updatelooper")
        end
        inst.components.updatelooper:AddOnUpdateFn(OnUpdateTargetTint)
        inst._tinttarget = inst._target:value()
        inst.OnRemoveEntity = OnRemoveEntity
    end
end

local function Setup(inst, target)
    inst._target:set(target)
    if not TheNet:IsDedicated() then
        OnTargetDirty(inst)
    end
    if target.SoundEmitter ~= nil then
        target.SoundEmitter:PlaySound("dontstarve/characters/wortox/soul/spawn", nil, .5)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("wortox_soul_ball")
    inst.AnimState:SetBuild("wortox_soul_ball")
    inst.AnimState:PlayAnimation("idle_pst")
	inst.AnimState:SetFrame(6)
    inst.AnimState:SetScale(SCALE, SCALE)
    inst.AnimState:SetFinalOffset(3)

    inst:AddTag("FX")

    inst._target = net_entity(inst.GUID, "wortox_soul_in_fx._target", "targetdirty")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        inst:ListenForEvent("targetdirty", OnTargetDirty)

        return inst
    end

    inst:ListenForEvent("animover", inst.Remove)
    inst.persists = false
    inst.Setup = Setup

    return inst
end

return Prefab("wortox_soul_in_fx", fn, assets)
