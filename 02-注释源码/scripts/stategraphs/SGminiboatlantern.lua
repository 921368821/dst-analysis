--============================================================
-- 文件：stategraphs/SGminiboatlantern.lua
-- 模块：状态图 / SGminiboatlantern
-- 职责：状态图「SGminiboatlantern」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("stategraphs/commonstates")

local actionhandlers =
{
}

local events =
{
    CommonHandlers.OnLocomote(false, true),
	--[[EventHandler("floater_startfloating", function(inst)
		inst.sg:GoToState("idle")
    end),]]
	EventHandler("floater_stopfloating", function(inst)
		inst.sg:GoToState("idle")
    end),
    EventHandler("onturnoff", function(inst)
        inst.sg:GoToState("idle")
    end),
}

local states =
{
    State{
        name = "idle",
        tags = {"idle", "canrotate"},
        onenter = function(inst)
            inst.components.locomotor:StopMoving()
            inst.AnimState:PlayAnimation(
                TheWorld.Map:IsOceanAtPoint(inst.Transform:GetWorldPosition()) and "idle"
                or "idle_ground",
                true)
        end,
    },
}

CommonStates.AddWalkStates(states)

return StateGraph("sgminiboatlantern", states, events, "idle", actionhandlers)
