--============================================================
-- 文件：brains/stagehandbrain.lua
-- 模块：AI 大脑 / stagehandbrain
-- 职责：大脑「stagehandbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/findclosest"
require "behaviours/standstill"
local BrainCommon = require("brains/braincommon")

local SEE_LIGHT_DIST = 50

local StagehandBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function SafeLightDist(inst, target)
    if target:HasTag("player") or target:HasTag("playerlight") then
        return 4
    end
    local owner = target.components.inventoryitem ~= nil and target.components.inventoryitem:GetGrandOwner() or nil
    return (owner ~= nil and owner:HasTag("player") and 4)
        or (target.Light ~= nil and target.Light:GetCalculatedRadius())
        or 4
end

function StagehandBrain:OnStart()
    local root =
        PriorityNode({
			BrainCommon.PanicTrigger(self.inst),
            WhileNode(function() return self.inst:CanStandUp() and TheWorld.state.isnight end, "IsNight",
                FindClosest(self.inst, SEE_LIGHT_DIST, SafeLightDist, { "fire" }, nil, { "campfire", "lighter" })),
            StandStill(self.inst),
        }, 1)

    self.bt = BT(self.inst, root)
end

return StagehandBrain
