--============================================================
-- 文件：prefabs/wonkey.lua
-- 模块：预制体 / wonkey（建筑与容器）
-- 职责：实体「wonkey」的预制体定义。SpawnPrefab("wonkey") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MakePlayerCharacter = require("prefabs/player_common")

local assets =
{
    Asset("SCRIPT", "scripts/prefabs/player_common.lua"),
    Asset("ANIM", "anim/player_idles_wonkey.zip"),
    Asset("SOUND", "sound/webber.fsb"),
}

local prefabs =
{
    "monkey_cursed_pre_fx",
    "monkey_cursed_pst_fx",
    "monkey_deform_pre_fx",
    "monkey_deform_pst_fx",
}

local start_inv = {}
for k, v in pairs(TUNING.GAMEMODE_STARTING_ITEMS) do
    start_inv[string.lower(k)] = v.WONKEY
end

prefabs = FlattenTree({ prefabs, start_inv }, true)

local function common_postinit(inst)
    inst:AddTag("wonkey")
    inst:AddTag("monkey")
end

local function master_postinit(inst)
    inst.starting_inventory = start_inv[TheNet:GetServerGameMode()] or start_inv.default

    inst.components.foodaffinity:AddPrefabAffinity("cave_banana", TUNING.AFFINITY_15_CALORIES_SMALL)

    inst.customidleanim = "idle_wonkey"
    inst.talker_path_override = "monkeyisland/characters/"

    inst.components.locomotor.runspeed = TUNING.WILSON_RUN_SPEED + TUNING.WONKEY_WALK_SPEED_PENALTY

    inst.components.health:SetMaxHealth(TUNING.WONKEY_HEALTH)
    inst.components.hunger:SetMax(TUNING.WONKEY_HUNGER)
    inst.components.sanity:SetMax(TUNING.WONKEY_SANITY)
end

return MakePlayerCharacter("wonkey", prefabs, assets, common_postinit, master_postinit)
