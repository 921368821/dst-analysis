--============================================================
-- 文件：brains/nightmaremonkeybrain.lua
-- 模块：AI 大脑 / nightmaremonkeybrain
-- 职责：大脑「nightmaremonkeybrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/wander"
require "behaviours/chaseandattack"
local BrainCommon = require("brains/braincommon")

local MAX_WANDER_DIST = 10

local MAX_CHASE_TIME = 60
local MAX_CHASE_DIST = 40


local NightmareMonkeyBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function EquipWeapon(inst, weapon)
    if not weapon.components.equippable:IsEquipped() then
        inst.components.inventory:Equip(weapon)
    end
end

function NightmareMonkeyBrain:OnStart()

    local root = PriorityNode(
    {
		BrainCommon.PanicTrigger(self.inst),
        BrainCommon.ElectricFencePanicTrigger(self.inst),
        SequenceNode({
            ActionNode(function() EquipWeapon(self.inst, self.inst.weaponitems.hitter) end, "Equip hitter"),
            ChaseAndAttack(self.inst, MAX_CHASE_TIME, MAX_CHASE_DIST),
        }),
        Wander(self.inst, function() return self.inst.components.knownlocations:GetLocation("home") end, MAX_WANDER_DIST),
    }, .25)
    self.bt = BT(self.inst, root)
end

return NightmareMonkeyBrain
