--============================================================
-- 文件：brains/klausbrain.lua
-- 模块：AI 大脑 / klausbrain
-- 职责：大脑「klausbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/chaseandattack"
require "behaviours/wander"

local RESET_COMBAT_DELAY = 10

local KlausBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function GetHomePos(inst)
    return inst.components.knownlocations:GetLocation("spawnpoint")
end

local function ShouldEnrage(inst)
    return not inst.enraged
        and inst.components.commander:GetNumSoldiers() < 2
end

local function ShouldChomp(inst)
    return inst:IsUnchained()
        and inst.components.combat:HasTarget()
        and not inst.components.timer:TimerExists("chomp_cd")
end

function KlausBrain:OnStart()
    local root = PriorityNode(
    {
        WhileNode(function() return ShouldEnrage(self.inst) end, "Enrage",
            ActionNode(function() self.inst:PushEvent("enrage") end)),
        WhileNode(function() return ShouldChomp(self.inst) end, "Chomp",
            ActionNode(function() self.inst:PushEvent("chomp") end)),
        ChaseAndAttack(self.inst),
        ParallelNode{
            SequenceNode{
                WaitNode(RESET_COMBAT_DELAY),
                ActionNode(function() self.inst:SetEngaged(false) end),
            },
            Wander(self.inst, GetHomePos, 5),
        },
    }, .5)

    self.bt = BT(self.inst, root)
end

function KlausBrain:OnInitializationComplete()
    local pos = self.inst:GetPosition()
    pos.y = 0
    self.inst.components.knownlocations:RememberLocation("spawnpoint", pos, true)
end

return KlausBrain
