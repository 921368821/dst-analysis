--============================================================
-- 文件：prefabs/wortox_soul_heal_fx.lua
-- 模块：预制体 / wortox_soul_heal_fx（建筑与容器）
-- 职责：实体「wortox_soul_heal_fx」的预制体定义。SpawnPrefab("wortox_soul_heal_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wortox_soul_heal_fx.zip"),
}

local TINT = { r = 154 / 255, g = 23 / 255, b = 19 / 255 }

local function OnUpdateTargetTint(inst)--, dt)
    if inst._tinttarget:IsValid() then
		local curframe = inst.AnimState:GetCurrentAnimationFrame()
        if curframe < 10 then
            local k = curframe / 10 * .5
            if inst._tinttarget.components.colouradder ~= nil then
                inst._tinttarget.components.colouradder:PushColour(inst, TINT.r * k, TINT.g * k, TINT.b * k, 0)
            end
        elseif curframe < 40 then
            local k = (curframe - 10) / 30
            k = (1 - k * k) * .5
            if inst._tinttarget.components.colouradder ~= nil then
                inst._tinttarget.components.colouradder:PushColour(inst, TINT.r * k, TINT.g * k, TINT.b * k, 0)
            end
        else
            inst.components.updatelooper:RemoveOnUpdateFn(OnUpdateTargetTint)
            if inst._tinttarget.components.colouradder ~= nil then
                inst._tinttarget.components.colouradder:PopColour(inst)
            end
        end
    else
        inst.components.updatelooper:RemoveOnUpdateFn(OnUpdateTargetTint)
    end
end

local function Setup(inst, target)
    if inst.components.updatelooper == nil then
        inst:AddComponent("updatelooper")
        inst.components.updatelooper:AddOnUpdateFn(OnUpdateTargetTint)
        inst._tinttarget = target
    end
    if target.SoundEmitter ~= nil then
        target.SoundEmitter:PlaySound("dontstarve/characters/wortox/soul/heal")
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("wortox_soul_heal_fx")
    inst.AnimState:SetBuild("wortox_soul_heal_fx")
    inst.AnimState:PlayAnimation("heal")
    inst.AnimState:SetFinalOffset(3)
    inst.AnimState:SetScale(1.5, 1.5)
    inst.AnimState:SetDeltaTimeMultiplier(2)

    inst:AddTag("FX")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    if math.random() < .5 then
        inst.AnimState:SetScale(-1.5, 1.5)
    end

    inst:ListenForEvent("animover", inst.Remove)
    inst.persists = false
    inst.Setup = Setup

    return inst
end

return Prefab("wortox_soul_heal_fx", fn, assets)
