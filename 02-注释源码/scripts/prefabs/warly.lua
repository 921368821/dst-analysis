--============================================================
-- 文件：prefabs/warly.lua
-- 模块：预制体 / warly（建筑与容器）
-- 职责：实体「warly」的预制体定义。SpawnPrefab("warly") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MakePlayerCharacter = require("prefabs/player_common")

local assets =
{
    Asset("SCRIPT", "scripts/prefabs/player_common.lua"),
    Asset("SOUND", "sound/warly.fsb"),
    Asset("ANIM", "anim/player_idles_warly.zip"),
}

local start_inv = {}
for k, v in pairs(TUNING.GAMEMODE_STARTING_ITEMS) do
    start_inv[string.lower(k)] = v.WARLY
end

local prefabs = FlattenTree(start_inv, true)

local function common_postinit(inst)
    inst:AddTag("masterchef")
    inst:AddTag("professionalchef")
    inst:AddTag("expertchef")

    inst.AnimState:AddOverrideBuild("player_idles_warly")
end

local function master_postinit(inst)
    inst.starting_inventory = start_inv[TheNet:GetServerGameMode()] or start_inv.default

    inst.customidleanim = "idle_warly"

    inst.components.health:SetMaxHealth(TUNING.WARLY_HEALTH)
    inst.components.sanity:SetMax(TUNING.WARLY_SANITY)
    inst.components.hunger:SetMax(TUNING.WARLY_HUNGER)
    inst.components.hunger:SetRate(TUNING.WILSON_HUNGER_RATE * TUNING.WARLY_HUNGER_RATE_MODIFIER)

    if inst.components.eater ~= nil then
        inst.components.eater:SetPrefersEatingTag("preparedfood")
        inst.components.eater:SetPrefersEatingTag("pre-preparedfood")
    end

    inst:AddComponent("foodmemory")
    inst.components.foodmemory:SetDuration(TUNING.WARLY_SAME_OLD_COOLDOWN)
    inst.components.foodmemory:SetMultipliers(TUNING.WARLY_SAME_OLD_MULTIPLIERS)
end

return MakePlayerCharacter("warly", prefabs, assets, common_postinit, master_postinit)
