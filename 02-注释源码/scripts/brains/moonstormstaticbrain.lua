--============================================================
-- 文件：brains/moonstormstaticbrain.lua
-- 模块：AI 大脑 / moonstormstaticbrain
-- 职责：大脑「moonstormstaticbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/wander"

local MAX_WANDER_DIST = 8

local WanderTimes = {
    minwalktime = 3,
    randwalktime = 1,
    minwaittime = 0.5,
    randwaittime = 1,
}

local MoonstormStaticBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function CheckPointFn(pt)
    local x, y, z = pt:Get()
    if not TheWorld.Map:IsLandTileAtPoint(x, y, z) then
        return false
    end

    local moonstorms = TheWorld.net and TheWorld.net.components.moonstorms or nil
    if not moonstorms then
        return true
    end

    return moonstorms:IsXZInMoonstorm(x, z)
end

function MoonstormStaticBrain:OnStart()
    local root = PriorityNode({
        Wander(self.inst, function() return self.inst:GetPosition() end, MAX_WANDER_DIST, WanderTimes, nil, nil, CheckPointFn),
    }, 1)

    self.bt = BT(self.inst, root)
end

return MoonstormStaticBrain
