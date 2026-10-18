--============================================================
-- 文件：brains/wx78_shadowdrone_harvesterbrain.lua
-- 模块：AI 大脑 / wx78_shadowdrone_harvesterbrain
-- 职责：大脑「wx78_shadowdrone_harvesterbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BrainCommon = require("brains/braincommon")
local WX78_ShadowDrone_BrainCommon = require("brains/wx78_shadowdrone_braincommon")

local WX78_ShadowDrone_HarvesterBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local HARVEST_RADIUS = TUNING.SKILLS.WX78.SHADOWDRONE_HARVESTER_FINDITEM_RADIUS

function WX78_ShadowDrone_HarvesterBrain:OnStart()
    local pickupparams = {
        range = HARVEST_RADIUS,
        furthestfirst = true,
        allowpickables = true,
        itemoverridefn = function(inst, leader)
            local socket_shadow_harvester = leader and leader.components.socket_shadow_harvester or nil
            if not socket_shadow_harvester then
                return nil
            end

            return socket_shadow_harvester:GetItemForHarvester(self.inst)
        end,
    }
    local root = PriorityNode({
        WhileNode(
            function()
                return not self.inst.sg:HasStateTag("despawn")
            end,
            "<busy state guard>",
            PriorityNode({
                BrainCommon.NodeAssistLeaderPickUps(self, pickupparams),
                WX78_ShadowDrone_BrainCommon.FollowFormationNode(self.inst),
                WX78_ShadowDrone_BrainCommon.WanderNode(self.inst),
            }, .25)
        )
    }, .25)

    self.bt = BT(self.inst, root)
end

return WX78_ShadowDrone_HarvesterBrain
