--============================================================
-- 文件：prefabs/reticulearc.lua
-- 模块：预制体 / reticulearc（建筑与容器）
-- 职责：实体「reticulearc」的预制体定义。SpawnPrefab("reticulearc") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/reticulearc.zip"),
}

local PAD_DURATION = .1
local SCALE = 1.5
local FLASH_TIME = .3

local function UpdatePing(inst, s0, s1, t0, duration, multcolour, addcolour)
    if next(multcolour) == nil then
        multcolour[1], multcolour[2], multcolour[3], multcolour[4] = inst.AnimState:GetMultColour()
    end
    if next(addcolour) == nil then
        addcolour[1], addcolour[2], addcolour[3], addcolour[4] = inst.AnimState:GetAddColour()
    end
    local t = GetTime() - t0
    local k = 1 - math.max(0, t - PAD_DURATION) / duration
    k = 1 - k * k
    local s = Lerp(s0, s1, k)
    local c = Lerp(1, 0, k)
    inst.Transform:SetScale(s, s, s)
    inst.AnimState:SetMultColour(multcolour[1], multcolour[2], multcolour[3], c * multcolour[4])

    k = math.min(FLASH_TIME, t) / FLASH_TIME
    c = math.max(0, 1 - k * k)
    inst.AnimState:SetAddColour(c * addcolour[1], c * addcolour[2], c * addcolour[3], c * addcolour[4])
end

local function MakeReticule(name, ping)
    local function fn()
        local inst = CreateEntity()

        inst:AddTag("FX")
        inst:AddTag("NOCLICK")
        --[[Non-networked entity]]
        inst.entity:SetCanSleep(false)
        inst.persists = false

        inst.entity:AddTransform()
        inst.entity:AddAnimState()

        inst.AnimState:SetBank("reticulearc")
        inst.AnimState:SetBuild("reticulearc")
        inst.AnimState:PlayAnimation("idle")
        inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
        inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
        inst.AnimState:SetSortOrder(3)
        inst.AnimState:SetScale(SCALE, SCALE)

        if ping then
            inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")

            local duration = .5
            inst:DoPeriodicTask(0, UpdatePing, nil, 1, 1.075, GetTime(), duration, {}, {})
            inst:DoTaskInTime(duration, inst.Remove)
        end

        return inst
    end

    return Prefab(name, fn, assets)
end

return MakeReticule("reticulearc", false),
    MakeReticule("reticulearcping", true)
