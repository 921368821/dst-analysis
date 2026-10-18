--============================================================
-- 文件：prefabs/mooneye.lua
-- 模块：预制体 / mooneye（建筑与容器）
-- 职责：实体「mooneye」的预制体定义。SpawnPrefab("mooneye") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/mooneyes.zip"),
}

local prefabs =
{
    "globalmapicon",
}

local function Sparkle(inst, colour)
    if not inst.AnimState:IsCurrentAnimation(colour.."gem_sparkle") then
        inst.AnimState:PlayAnimation(colour.."gem_sparkle")
        inst.AnimState:PushAnimation(colour.."gem_idle", false)
    end
    inst:DoTaskInTime(4 + math.random(), Sparkle, colour)
end

local function topocket(inst)
    if inst.icon ~= nil then
        inst.icon:Remove()
        inst.icon = nil
    end
end

local function toground(inst)
    if inst.icon == nil then
        inst.icon = SpawnPrefab("globalmapicon")
        inst.icon:TrackEntity(inst)
    end
end

local function init(inst)
    if not inst.components.inventoryitem:IsHeld() then
        toground(inst)
    end
end

local function buildeye(colour)
    local function fn()
        local inst = CreateEntity()

        inst.entity:AddTransform()
        inst.entity:AddAnimState()
        inst.entity:AddSoundEmitter()
        inst.entity:AddMiniMapEntity()
        inst.entity:AddNetwork()

        inst.MiniMapEntity:SetIcon(colour.."mooneye.png")
        inst.MiniMapEntity:SetCanUseCache(false)
        inst.MiniMapEntity:SetDrawOverFogOfWar(true)

        MakeInventoryPhysics(inst)

        inst.AnimState:SetBank("mooneyes")
        inst.AnimState:SetBuild("mooneyes")
        inst.AnimState:PlayAnimation(colour.."gem_idle")
        inst.scrapbook_anim = colour.."gem_idle"
        inst.AnimState:SetBloomEffectHandle("shaders/anim.ksh")

        MakeInventoryFloatable(inst, "small", 0.05, {0.8, 0.75, 0.8})

        inst:AddTag("donotautopick")

        inst.scrapbook_specialinfo = "MOONEYE"
        
        inst.entity:SetPristine()

        if not TheWorld.ismastersim then
            return inst
        end

        inst:AddComponent("tradable")

        inst:AddComponent("inspectable")

        inst:AddComponent("inventoryitem")

        MakeHauntableLaunch(inst)

        inst.icon = nil
        inst:ListenForEvent("onputininventory", topocket)
        inst:ListenForEvent("ondropped", toground)
        inst:DoTaskInTime(0, init)
        inst:DoTaskInTime(0, Sparkle, colour)

        return inst
    end

    return Prefab(colour.."mooneye", fn, assets, prefabs)
end

return buildeye("purple"),
    buildeye("blue"),
    buildeye("red"),
    buildeye("orange"),
    buildeye("yellow"),
    buildeye("green")
