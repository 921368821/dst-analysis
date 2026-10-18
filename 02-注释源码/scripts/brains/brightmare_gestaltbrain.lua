--============================================================
-- 文件：brains/brightmare_gestaltbrain.lua
-- 模块：AI 大脑 / brightmare_gestaltbrain
-- 职责：大脑「brightmare_gestaltbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/follow"
require "behaviours/wander"
require "behaviours/standstill"

local BrainCommon = require("brains/braincommon")

local BRIGHTMARE_AVOID_DIST = 2
local BRIGHTMARE_AVOID_STOP = 4

local AVOID_SHADOW_DIST = 5
local AVOID_SHADOW_STOP = 8

local L1_AVOID_PLAYER_DIST = 3
local L1_AVOID_PLAYER_STOP = 6

local L2_FACE_PLAYER_DIST = 6
local L2_FACE_PLAYER_DURATION = 5
local L2_AVOID_PLAYER_DIST = L2_FACE_PLAYER_DIST + 0.1
local L2_AVOID_PLAYER_STOP = L2_FACE_PLAYER_DIST + 2

local L3_ATTACK_CHASE_START_DIST = L2_FACE_PLAYER_DIST
local L3_ATTACK_CHASE_DIST = L3_ATTACK_CHASE_START_DIST + 3
local L3_ATTACK_CHASE_TIME = 5
local L3_AVOID_PLAYER_DIST = L3_ATTACK_CHASE_START_DIST + 0.1
local L3_AVOID_PLAYER_STOP = L3_AVOID_PLAYER_DIST + 2


local SHADOW_TAGS = {oneoftags = {"nightmarecreature", "shadowcreature", "shadow", "shadowminion", "stalker", "stalkerminion", "nightmare", "shadow_fire"}}

local GestaltBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function ShouldRelocate(inst)
    return not inst._ignorerelocating
        and not inst.sg:HasStateTag("busy")
        and (inst.tracking_target == nil or not inst:IsNearPlayer(TUNING.GESTALT_RELOCATED_FAR_DIST, true))
end

local function Relocate(inst)
	inst.sg:GoToState("relocate")
end

local function onrunaway(target, inst)
	inst.components.combat:DropTarget()
	return true
end

--------------------------------------------------------------------------

local WANDER_TIMES = { minwaittime = 0, randwaittime = 0 }

local UPDATE_RATE = 0.1
function GestaltBrain:OnStart()
	local possess_chassis_node = BrainCommon.PossessChassisNode(self, UPDATE_RATE)

    local root =
	PriorityNode({
		WhileNode(function() return not self.inst.sg:HasStateTag("jumping") end, "AttackAndWander",
			PriorityNode({
				WhileNode( function() return ShouldRelocate(self.inst) end, "relocate",
					SequenceNode{
						ActionNode(function() Relocate(self.inst) end),
						StandStill(self.inst),
					}),


				RunAway(self.inst, SHADOW_TAGS, AVOID_SHADOW_DIST, AVOID_SHADOW_STOP, onrunaway),
				WhileNode( function() return self.inst.behaviour_level == 1 end, "level1",
					PriorityNode({
						RunAway(self.inst, "player", L1_AVOID_PLAYER_DIST, L1_AVOID_PLAYER_STOP),
					}, UPDATE_RATE)),

				WhileNode( function() return self.inst.behaviour_level == 2 end, "level2",
					PriorityNode({
						possess_chassis_node,
						WhileNode( function() return self.inst.components.combat.target ~= nil end, "aggressive",
							StandAndAttack(self.inst, nil, L3_ATTACK_CHASE_TIME)),
						IfNode(function() return self.inst.components.combat:InCooldown() end, "combat_pst",
							RunAway(self.inst, "player", L2_AVOID_PLAYER_DIST, L2_AVOID_PLAYER_STOP)),
					}, UPDATE_RATE)),

				WhileNode( function() return self.inst.behaviour_level == 3 end, "level3",
					PriorityNode({
						possess_chassis_node,
						ChaseAndAttack(self.inst, L3_ATTACK_CHASE_TIME, L3_ATTACK_CHASE_DIST, nil, nil, true),
						IfNode(function() return self.inst.components.combat:InCooldown() end, "combat_pst",
							RunAway(self.inst, "player", L2_AVOID_PLAYER_DIST, L2_AVOID_PLAYER_STOP)),
					}, UPDATE_RATE)),

				RunAway(self.inst, "brightmare", BRIGHTMARE_AVOID_DIST, BRIGHTMARE_AVOID_STOP),
				Wander(self.inst, nil, nil, WANDER_TIMES),
			}, UPDATE_RATE)),
		}, UPDATE_RATE)

    self.bt = BT(self.inst, root)
end

return GestaltBrain