--============================================================
-- 文件：stategraphs/SGcarnivalgame_shooting_button.lua
-- 模块：状态图 / SGcarnivalgame_shooting_button
-- 职责：状态图「SGcarnivalgame_shooting_button」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local events =
{
    EventHandler("carnivalgame_turnon", function(inst)
		inst.sg:GoToState("turn_on")
    end),
}

local states =
{
    State{
        name = "place",
        onenter = function(inst, target)
            inst.AnimState:PlayAnimation("place")
            inst.SoundEmitter:PlaySound("summerevent/carnival_games/memory/place")
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("idle_off") end), -- or idle_off
        },
    },

    State{
        name = "idle_off",
		tags = {"off"},
        onenter = function(inst)
            inst.AnimState:PlayAnimation("off")
			inst.components.activatable.inactive = false
        end,
    },

    State{
        name = "turn_on",
        onenter = function(inst)
            inst.AnimState:PlayAnimation("turn_on")
			inst.components.activatable.inactive = true
            inst.SoundEmitter:PlaySound("summerevent/carnival_games/memory/turn_on")
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState(inst._shouldturnoff and "turn_off" or "idle_on") end),
        },
    },

    State{
        name = "turn_off",
		tags = {"off"},
        onenter = function(inst)
            inst.AnimState:PlayAnimation("turn_off")
			inst.components.activatable.inactive = false
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("idle_off") end),
        },
    },

    State{
        name = "idle_on",
        onenter = function(inst)
			if inst._shouldturnoff then
				inst.sg:GoToState("turn_off")
			else
	           inst.AnimState:PlayAnimation("idle_on", true)
			end
        end,

        events =
        {
            EventHandler("carnivalgame_turnoff", function(inst) inst.sg:GoToState("turn_off") end),
        },
    },

    State{
        name = "shoot",
        onenter = function(inst)
			if inst._shouldturnoff then
				inst.sg:GoToState("turn_off")
			else
	           inst.AnimState:PlayAnimation("press", true)
			end
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("idle_on") end),
        },
    },


}

return StateGraph("carnivalgame_shooting_target", states, events, "idle_off")
