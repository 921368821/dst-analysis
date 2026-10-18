--============================================================
-- 文件：brains/killerbeebrain.lua
-- 模块：AI 大脑 / killerbeebrain
-- 职责：大脑「killerbeebrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/chaseandattack"
require "behaviours/runaway"
require "behaviours/wander"
require "behaviours/doaction"
require "behaviours/findflower"
local beecommon = require "brains/beecommon"
local BrainCommon = require("brains/braincommon")

local MAX_CHASE_DIST = 25
local MAX_CHASE_TIME = 10

local RUN_AWAY_DIST = 3
local STOP_RUN_AWAY_DIST = 6

local function GetRunAwayTarget(inst)
	return inst.components.combat.target
end

local KillerBeeBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function KillerBeeBrain:OnStart()
    local root =
        PriorityNode(
        {
			BrainCommon.PanicTrigger(self.inst),
            BrainCommon.ElectricFencePanicTrigger(self.inst),
			WhileNode(function() return not self.inst.components.combat:HasTarget() or not self.inst.components.combat:InCooldown() end, "AttackMomentarily",
				ChaseAndAttack(self.inst, SpringCombatMod(MAX_CHASE_TIME), SpringCombatMod(MAX_CHASE_DIST))),
			WhileNode(function() return self.inst.components.combat:HasTarget() and self.inst.components.combat:InCooldown() end, "Dodge",
				RunAway(self.inst, { getfn = GetRunAwayTarget }, RUN_AWAY_DIST, STOP_RUN_AWAY_DIST)),
            DoAction(self.inst, function() return beecommon.GoHomeAction(self.inst) end, "go home", true ),
            Wander(self.inst, function() return self.inst.components.knownlocations:GetLocation("home") end, beecommon.MAX_WANDER_DIST)
        },1)

    self.bt = BT(self.inst, root)
end

function KillerBeeBrain:OnInitializationComplete()
    self.inst.components.knownlocations:RememberLocation("home", Point(self.inst.Transform:GetWorldPosition()))
end

return KillerBeeBrain
