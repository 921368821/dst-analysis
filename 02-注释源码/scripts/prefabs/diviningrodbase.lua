--============================================================
-- 文件：prefabs/diviningrodbase.lua
-- 模块：预制体 / diviningrodbase（建筑与容器）
-- 职责：实体「diviningrodbase」的预制体定义。SpawnPrefab("diviningrodbase") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/diviningrod.zip"),
}

local function OnUnlock(inst)
    inst.components.lock.isstuck = true
    inst.AnimState:PlayAnimation("idle_full")
    inst.SoundEmitter:KillSound("pulse")
    inst.SoundEmitter:PlaySound("dontstarve/common/teleportato/teleportato_add_divining")
    local teleportato = TheSim:FindFirstEntityWithTag("teleportato")
    if teleportato then
        teleportato:PushEvent("powerup")
    end
end

local function OnLock(inst)
    inst.AnimState:PlayAnimation("idle_empty")
    inst.SoundEmitter:KillSound("pulse")
end

local function OnReady(inst)
    if inst.components.lock:IsLocked() then
        inst.AnimState:PlayAnimation("activate_loop", true)
        inst.SoundEmitter:PlaySound("dontstarve/common/teleportato/teleportato_pulse", "pulse")
        inst.components.lock.isstuck = false
    else
        OnUnlock(inst)
    end
end

local function describe(inst)
    if not inst.components.lock:IsStuck() then
        return "READY"
    elseif not inst.components.lock:IsLocked() then
        return "UNLOCKED"
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("diviningrod")
    inst.AnimState:SetBuild("diviningrod")
    inst.AnimState:PlayAnimation("idle_empty")

    inst:AddTag("rodbase")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = describe

    inst:AddComponent("lock")
    inst.components.lock.locktype = LOCKTYPE.MAXWELL
    inst.components.lock.isstuck = true
    inst.components.lock:SetOnUnlockedFn(OnUnlock)
    inst.components.lock:SetOnLockedFn(OnLock)
    inst:ListenForEvent("ready", OnReady)

    return inst
end

return Prefab("diviningrodbase", fn, assets)