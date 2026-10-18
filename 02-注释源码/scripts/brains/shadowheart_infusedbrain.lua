--============================================================
-- 文件：brains/shadowheart_infusedbrain.lua
-- 模块：AI 大脑 / shadowheart_infusedbrain
-- 职责：大脑「shadowheart_infusedbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/runaway"
require "behaviours/standstill"

local AVOID_PLAYER_DIST = 4.0
local AVOID_PLAYER_STOP = 6.0

local ShadowheartInfusedBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local UPDATE_RATE = 0.25
function ShadowheartInfusedBrain:OnStart()
    local root = PriorityNode({
        RunAway(self.inst, "player", AVOID_PLAYER_DIST, AVOID_PLAYER_STOP),
        StandStill(self.inst),
    }, UPDATE_RATE)

    self.bt = BT(self.inst, root)
end

return ShadowheartInfusedBrain