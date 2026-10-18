--============================================================
-- 文件：stategraphs/SGfissure.lua
-- 模块：状态图 / SGfissure
-- 职责：状态图「SGfissure」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("stategraphs/commonstates")

local events=
{
    EventHandler("attacked", function(inst) end),
    EventHandler("death", function(inst) end),
}

local states=
{
    State{
        name = "idle_off",
        tags = {"idle"},
        onenter = function(inst)

        end,
        onexit = function(inst)

        end,
    },
        State{
        name = "idle_turnoff",
        tags = {"idle"},
        onenter = function(inst)
            inst.sg:SetTimeout(4)
            inst.turnoff(inst)
        end,
        ontimeout = function(inst)
            inst.sg:GoToState("idle_off")
        end,
    },

    State{
        name = "idle_on",
        tags = {"idle"},
        onenter = function(inst)

        end,
        onexit = function(inst)

        end,
    },
        State{
        name = "idle_turnon",
        tags = {"idle"},
        onenter = function(inst)
            inst.sg:SetTimeout(4)
            inst.turnon(inst)
        end,
        ontimeout = function(inst)
            inst.sg:GoToState("idle_on")
        end,
    },
}

return StateGraph("fissure", states, events, "idle")

