--============================================================
-- 文件：brains/wormwood_lightflierbrain.lua
-- 模块：AI 大脑 / wormwood_lightflierbrain
-- 职责：大脑「wormwood_lightflierbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("behaviours/panic")
local BrainCommon = require("brains/braincommon")

local Wormwood_LightFlierBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function Wormwood_LightFlierBrain:OnStart()
    local root = PriorityNode({
        ParallelNode{
            ActionNode(function()
                self.inst.components.locomotor.walkspeed = TUNING.LIGHTFLIER.WALK_SPEED
                self.inst.components.locomotor.directdrive = false
            end),

            PriorityNode({
                EventNode(self.inst, "panic",
                    ParallelNode{
                        Panic(self.inst),
                        WaitNode(6),
                    }),
				BrainCommon.PanicTrigger(self.inst),
                BrainCommon.ElectricFencePanicTrigger(self.inst),

                -- Else no need to do anything from here, movement is handled on update from outside sources.
                ActionNode(function()
                    self.inst.components.locomotor.directdrive = true
                end),
            }, .25)
        }
    }, .25)

    self.bt = BT(self.inst, root)
end

return Wormwood_LightFlierBrain
