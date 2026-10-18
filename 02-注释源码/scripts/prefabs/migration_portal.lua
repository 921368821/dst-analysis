--============================================================
-- 文件：prefabs/migration_portal.lua
-- 模块：预制体 / migration_portal（建筑与容器）
-- 职责：实体「migration_portal」的预制体定义。SpawnPrefab("migration_portal") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/portal_friends.zip"),
    Asset("SOUND", "sound/common.fsb"),
	Asset("MINIMAP_IMAGE", "wormhole"),
}

local function close(inst)
    inst.AnimState:PlayAnimation("closing")
    inst.AnimState:PushAnimation("idle_closed", true)
end

local function open(inst)
    inst.AnimState:PlayAnimation("opening")
    inst.AnimState:PushAnimation("idle", true)
end

local function full(inst)
    inst.AnimState:PlayAnimation("opening", true)
end

local function activate(inst)
    inst.AnimState:PlayAnimation("activate")
    inst.AnimState:PushAnimation("opening")
    inst.AnimState:PushAnimation("idle")
end

local function GetStatus(inst)
    if inst.components.worldmigrator:IsActive() then
        return "OPEN"
    elseif inst.components.worldmigrator:IsFull() then
        return "FULL"
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst.MiniMapEntity:SetIcon("wormhole.png")

    inst.AnimState:SetBank("portal_friends")
    inst.AnimState:SetBuild("portal_friends")
    inst.AnimState:PlayAnimation("idle_closed", true)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = GetStatus

    inst:AddComponent("worldmigrator")
    inst:ListenForEvent("migration_available", open)
    inst:ListenForEvent("migration_unavailable", close)
    inst:ListenForEvent("migration_full", full)
    inst:ListenForEvent("migration_activate", activate)

    return inst
end

return Prefab("migration_portal", fn, assets)
