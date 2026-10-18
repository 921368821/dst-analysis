--============================================================
-- 文件：brains/wx78_possessedbodybrain_no_package.lua
-- 模块：AI 大脑 / wx78_possessedbodybrain_no_package
-- 职责：大脑「wx78_possessedbodybrain_no_package」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/wander"
require "behaviours/faceentity"
require "behaviours/chaseandattack"
require "behaviours/doaction"
require "behaviours/leash"
require "behaviours/standstill"

local BrainCommon = require("brains/braincommon")

--------------------------------------------------------------------------------------------------------------------------------

local Wx78_PossessedBodyBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local UPDATE_RATE = 0.5
function Wx78_PossessedBodyBrain:OnStart()
    local root = PriorityNode(
    {
        StandStill(self.inst),
    }, UPDATE_RATE)

    self.bt = BT(self.inst, root)
end

function Wx78_PossessedBodyBrain:OnStop()

end

return Wx78_PossessedBodyBrain