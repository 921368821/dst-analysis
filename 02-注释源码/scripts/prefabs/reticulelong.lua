--============================================================
-- 文件：prefabs/reticulelong.lua
-- 模块：预制体 / reticulelong（建筑与容器）
-- 职责：实体「reticulelong」的预制体定义。SpawnPrefab("reticulelong") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/reticulelong.zip"),
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
    local c = Lerp(1, 0, k)
	inst.AnimState:SetScale(inst.chargescale * SCALE * Lerp(s0[1], s1[1], k), SCALE * Lerp(s0[2], s1[2], k))
    inst.AnimState:SetMultColour(multcolour[1], multcolour[2], multcolour[3], c * multcolour[4])

    k = math.min(FLASH_TIME, t) / FLASH_TIME
    c = math.max(0, 1 - k * k)
    inst.AnimState:SetAddColour(c * addcolour[1], c * addcolour[2], c * addcolour[3], c * addcolour[4])
end

local function SetChargeScale(inst, chargescale)
	inst.chargescale = chargescale
	inst.AnimState:SetScale(chargescale * SCALE, SCALE)
end

local function MakeReticule(name, anim, ping)
    local function fn()
        local inst = CreateEntity()

        inst:AddTag("FX")
        inst:AddTag("NOCLICK")
        --[[Non-networked entity]]
        inst.entity:SetCanSleep(false)
        inst.persists = false

        inst.entity:AddTransform()
        inst.entity:AddAnimState()

        inst.AnimState:SetBank("reticulelong")
        inst.AnimState:SetBuild("reticulelong")
        inst.AnimState:PlayAnimation(anim)
        inst.AnimState:SetOrientation(ANIM_ORIENTATION.OnGround)
        inst.AnimState:SetLayer(LAYER_WORLD_BACKGROUND)
        inst.AnimState:SetSortOrder(3)
        inst.AnimState:SetScale(SCALE, SCALE)

        if ping then
            inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")

            local duration = .4
            inst:DoPeriodicTask(0, UpdatePing, nil, { 1, 1 }, { 1.04, 1.3 }, GetTime(), duration, {}, {})
            inst:DoTaskInTime(duration, inst.Remove)

			inst.chargescale = 1
			inst.SetChargeScale = SetChargeScale
        end

        return inst
    end

    return Prefab(name, fn, assets)
end

return MakeReticule("reticulelong", "idle", false),
    MakeReticule("reticulelongping", "idle", true),
    MakeReticule("reticulelongmulti", "idle_multi", false),
    MakeReticule("reticulelongmultiping", "idle_multi", true)
