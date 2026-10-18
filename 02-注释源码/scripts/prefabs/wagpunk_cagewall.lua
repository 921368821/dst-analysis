--============================================================
-- 文件：prefabs/wagpunk_cagewall.lua
-- 模块：预制体 / wagpunk_cagewall（建筑与容器）
-- 职责：实体「wagpunk_cagewall」的预制体定义。SpawnPrefab("wagpunk_cagewall") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets = {
    Asset("ANIM", "anim/wagpunk_cagewall.zip"),
}

-- idle_off to activate to idle_on to deactivated to idle_off

local function PlayLoopingSFX(inst)
    inst.SoundEmitter:PlaySound("rifts5/wagpunk_fence/fence_LP", "fence_LP")
end
local function StopLoopingSFX(inst)
    if inst.loopingsfxtask ~= nil then
        inst.loopingsfxtask:Cancel()
        inst.loopingsfxtask = nil
    end
    inst.SoundEmitter:KillSound("fence_LP")
end

local function ExtendWall(inst)
    if inst.extended then
        return
    end
    inst.extended = true
    inst:RemoveTag("NOCLICK")

    if inst:IsAsleep() then
        inst.AnimState:PlayAnimation("idle_on")
        if inst.sfxlooper then
            inst:PlayLoopingSFX()
        end
    else
        inst.AnimState:PlayAnimation("activate")
        inst.AnimState:PushAnimation("idle_on", true)
        inst.SoundEmitter:PlaySound("rifts5/wagpunk_fence/lever_activate")
        if inst.sfxlooper then
            if inst.loopingsfxtask ~= nil then
                inst.loopingsfxtask:Cancel()
                inst.loopingsfxtask = nil
            end
            inst.loopingsfxtask = inst:DoTaskInTime(30 * FRAMES, inst.PlayLoopingSFX) -- TODO(JBK): Quick job for sounds should be done with an event listener and entity sleep state watch.
        end
    end
end

local function RetractWall(inst)
    if not inst.extended then
        return
    end
    inst.extended = false
    inst:AddTag("NOCLICK")

    if inst.sfxlooper then
        inst:StopLoopingSFX()
    end
    if inst:IsAsleep() then
        inst.AnimState:PlayAnimation("idle_off")
    else
        inst.AnimState:PlayAnimation("deactivated")
        inst.AnimState:PushAnimation("idle_off", true)
        inst.SoundEmitter:PlaySound("rifts5/wagpunk_fence/lever_deactivate")
    end
end

local function ExtendWallWithJitter(inst, jitter)
    inst:DoTaskInTime(math.random() * jitter, inst.ExtendWall)
end

local function RetractWallWithJitter(inst, jitter)
    inst:DoTaskInTime(math.random() * jitter, inst.RetractWall)
end

local function OnSave(inst, data)
    data.sfxlooper = inst.sfxlooper
end

local function OnLoad(inst, data)
    inst.sfxlooper = data and data.sfxlooper or nil
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.Transform:SetEightFaced()

    inst.AnimState:SetBank("wagpunk_fence")
    inst.AnimState:SetBuild("wagpunk_cagewall")
    inst.AnimState:PlayAnimation("idle_off")
    
    inst:AddTag("NOCLICK")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")

    inst.extended = false
    inst.ExtendWall = ExtendWall
    inst.RetractWall = RetractWall
    inst.ExtendWallWithJitter = ExtendWallWithJitter
    inst.RetractWallWithJitter = RetractWallWithJitter
    inst.PlayLoopingSFX = PlayLoopingSFX
    inst.StopLoopingSFX = StopLoopingSFX
    inst.OnSave = OnSave
    inst.OnLoad = OnLoad

    return inst
end

return Prefab("wagpunk_cagewall", fn, assets)