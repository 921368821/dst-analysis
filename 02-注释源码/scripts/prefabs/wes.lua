--============================================================
-- 文件：prefabs/wes.lua
-- 模块：预制体 / wes（建筑与容器）
-- 职责：实体「wes」的预制体定义。SpawnPrefab("wes") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MakePlayerCharacter = require("prefabs/player_common")

local assets =
{
    Asset("SCRIPT", "scripts/prefabs/player_common.lua"),
    Asset("ANIM", "anim/player_mount_wes.zip"),
    Asset("ANIM", "anim/player_mount_wes_2.zip"),
    Asset("ANIM", "anim/player_mime.zip"),
    Asset("ANIM", "anim/player_mime2.zip"),
	Asset("ANIM", "anim/player_sit_mime.zip"),
    Asset("ANIM", "anim/player_idles_wes.zip"),
}

local start_inv = {}
for k, v in pairs(TUNING.GAMEMODE_STARTING_ITEMS) do
    start_inv[string.lower(k)] = v.WES
end

local prefabs = FlattenTree(start_inv, true)

local function common_postinit(inst)
    inst:AddTag("mime")
    inst:AddTag("balloonomancer")

    inst.AnimState:AddOverrideBuild("player_idles_wes")

    if TheNet:GetServerGameMode() == "quagmire" then
        inst:AddTag("quagmire_cheapskate")
    end
end

local MODIFIER_SOURCE = "wes_misfortune"
local function master_postinit(inst)
	inst.customidlestate = "wes_funnyidle"

    inst.starting_inventory = start_inv[TheNet:GetServerGameMode()] or start_inv.default

	if inst.components.houndedtarget == nil then
		inst:AddComponent("houndedtarget")
	end
	inst.components.houndedtarget.target_weight_mult:SetModifier(inst, TUNING.WES_HOUND_TARGET_MULT, MODIFIER_SOURCE)
	inst.components.houndedtarget.hound_thief_sources:SetModifier(inst, true, MODIFIER_SOURCE)

    -- TODO #FIXME_CNY2026_LUCK, 
    -- hook this up? if luck mechanic doesn't change wes too much.
    -- ADDENDUM: Probably wait for skill tree. Too many changes!
    -- inst.components.luckuser:SetLuckSource(TUNING.WES_LUCK, "wes_misfortune")

    inst.components.health:SetMaxHealth(TUNING.WES_HEALTH)
    inst.components.hunger:SetMax(TUNING.WES_HUNGER)
    inst.components.sanity:SetMax(TUNING.WES_SANITY)

    inst.components.foodaffinity:AddPrefabAffinity("freshfruitcrepes", TUNING.AFFINITY_15_CALORIES_SUPERHUGE)

	-- clothing is less effective
	inst.components.temperature.inherentinsulation = -TUNING.INSULATION_TINY
	inst.components.temperature.inherentsummerinsulation = -TUNING.INSULATION_TINY

	inst.components.grogginess.decayrate = TUNING.WES_GROGGINESS_DECAY_RATE

    inst.components.playerlightningtarget:SetHitChance(TUNING.WES_LIGHTNING_TARGET_CHANCE)

	inst.components.workmultiplier:AddMultiplier(ACTIONS.CHOP,   TUNING.WES_WORKEFFECTIVENESS_MODIFIER, inst)
	inst.components.workmultiplier:AddMultiplier(ACTIONS.MINE,   TUNING.WES_WORKEFFECTIVENESS_MODIFIER, inst)
	inst.components.workmultiplier:AddMultiplier(ACTIONS.HAMMER, TUNING.WES_WORKEFFECTIVENESS_MODIFIER, inst)

	if inst.components.efficientuser == nil then
		inst:AddComponent("efficientuser")
	end
	inst.components.efficientuser:AddMultiplier(ACTIONS.CHOP,   TUNING.WES_WORKEFFECTIVENESS_MODIFIER, inst)
	inst.components.efficientuser:AddMultiplier(ACTIONS.MINE,   TUNING.WES_WORKEFFECTIVENESS_MODIFIER, inst)
	inst.components.efficientuser:AddMultiplier(ACTIONS.HAMMER, TUNING.WES_WORKEFFECTIVENESS_MODIFIER, inst)
	inst.components.efficientuser:AddMultiplier(ACTIONS.ATTACK, TUNING.WES_DAMAGE_MULT, inst)

    if TheNet:GetServerGameMode() == "lavaarena" then
        event_server_data("lavaarena", "prefabs/wes").master_postinit(inst)
    else
        inst.components.combat.damagemultiplier = TUNING.WES_DAMAGE_MULT
    end
end

return MakePlayerCharacter("wes", prefabs, assets, common_postinit, master_postinit, prefabs)
