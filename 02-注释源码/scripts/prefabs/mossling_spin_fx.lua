--============================================================
-- 文件：prefabs/mossling_spin_fx.lua
-- 模块：预制体 / mossling_spin_fx（建筑与容器）
-- 职责：实体「mossling_spin_fx」的预制体定义。SpawnPrefab("mossling_spin_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/mossling_spin_fx.zip")
}

local function PlaySound(inst)
    inst.SoundEmitter:PlaySound("dontstarve_DLC001/creatures/mossling/spin_electric")
    if inst.soundcount < 2 then
        inst.soundcount = inst.soundcount + 1
    else
        inst.task:Cancel()
        inst.task = nil
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.AnimState:SetBank("mossling_spin_fx")
    inst.AnimState:SetBuild("mossling_spin_fx")
    inst.AnimState:PlayAnimation("spin_loop")
    inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.soundcount = 0
    inst.task = inst:DoPeriodicTask(24 * FRAMES, PlaySound, 0)

    inst.persists = false
    inst:ListenForEvent("animover", inst.Remove)

    return inst
end

return Prefab("mossling_spin_fx", fn, assets)
