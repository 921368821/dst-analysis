--============================================================
-- 文件：prefabs/thunder_far.lua
-- 模块：预制体 / thunder_far（建筑与容器）
-- 职责：实体「thunder_far」的预制体定义。SpawnPrefab("thunder_far") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function PlayThunderSound()
    local inst = CreateEntity()

    --[[Non-networked entity]]

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:SetParent(TheFocalPoint.entity)

    inst.SoundEmitter:PlaySound("dontstarve/rain/thunder_far")

    inst:Remove()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddNetwork()

    inst:AddTag("FX")

    --Dedicated server does not need to spawn the local fx
    if not TheNet:IsDedicated() then
        --Delay one frame in case we are about to be removed
        inst:DoTaskInTime(0, PlayThunderSound)
    end

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.entity:SetCanSleep(false)
    inst.persists = false
    inst:DoTaskInTime(2, inst.Remove)

    return inst
end

return Prefab("thunder_far", fn)
