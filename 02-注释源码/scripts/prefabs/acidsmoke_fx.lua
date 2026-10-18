--============================================================
-- 文件：prefabs/acidsmoke_fx.lua
-- 模块：预制体 / acidsmoke_fx（建筑与容器）
-- 职责：实体「acidsmoke_fx」的预制体定义。SpawnPrefab("acidsmoke_fx") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/acidsmoke.zip"),
}

local INTERVAL_MAX = 8
local INTERVAL_MIN = 5

local function PlayAnim(inst)
    inst.AnimState:PlayAnimation(inst._anim)
end

local function OnAnimOver(inst)
    inst:DoTaskInTime(GetRandomMinMax(INTERVAL_MIN, INTERVAL_MAX), inst.PlayAnim)
end

local function SetLevel(inst, level)
    inst._anim = "idle_"..level
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst:AddTag("FX")

    inst.AnimState:SetBank("acidsmoke")
    inst.AnimState:SetBuild("acidsmoke")
    inst.AnimState:SetFinalOffset(3)
    
    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst._anim = "idle_1"

    inst.SetLevel   = SetLevel
    inst.OnAnimOver = OnAnimOver
    inst.PlayAnim   = PlayAnim

    inst.persists = false

    inst:ListenForEvent("animover", inst.OnAnimOver)
    inst:OnAnimOver()

    return inst
end

return Prefab("acidsmoke_fx", fn, assets)