--============================================================
-- 文件：prefabs/eye_charge.lua
-- 模块：预制体 / eye_charge（建筑与容器）
-- 职责：实体「eye_charge」的预制体定义。SpawnPrefab("eye_charge") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/eyeball_turret_attack.zip"),
    --Asset("SOUND", "sound/eyeballturret.fsb"),
}

local function OnHit(inst, owner, target)
    SpawnPrefab("eye_charge_hit").Transform:SetPosition(inst.Transform:GetWorldPosition())
    inst:Remove()
end

local function OnAnimOver(inst)
    inst:DoTaskInTime(0.3, inst.Remove)
end

local function OnThrown(inst)
    inst:ListenForEvent("animover", OnAnimOver)
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)
    RemovePhysicsColliders(inst)

    inst.Transform:SetFourFaced()

    inst.AnimState:SetBank("eyeball_turret_attack")
    inst.AnimState:SetBuild("eyeball_turret_attack")
    inst.AnimState:PlayAnimation("idle")

    --projectile (from projectile component) added to pristine state for optimization
    inst:AddTag("projectile")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    inst:AddComponent("projectile")
    inst.components.projectile:SetSpeed(30)
    inst.components.projectile:SetHoming(false)
    inst.components.projectile:SetHitDist(2)
    inst.components.projectile:SetOnHitFn(OnHit)
    inst.components.projectile:SetOnMissFn(inst.Remove)
    inst.components.projectile:SetOnThrownFn(OnThrown)

    return inst
end

local function PlayHitSound(proxy)
    local inst = CreateEntity()

    --[[Non-networked entity]]

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()

    inst.Transform:SetFromProxy(proxy.GUID)

    inst.SoundEmitter:PlaySound("dontstarve/creatures/eyeballturret/shotexplo")

    inst:Remove()
end

local function hit_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    --Dedicated server does not need to spawn the local fx
    if not TheNet:IsDedicated() then
        --Delay one frame in case we are about to be removed
        inst:DoTaskInTime(0, PlayHitSound)
    end

    inst:AddTag("FX")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false
    inst:DoTaskInTime(0.5, inst.Remove)

    return inst
end

return Prefab("eye_charge", fn, assets),
    Prefab("eye_charge_hit", hit_fn)