--============================================================
-- 文件：stategraphs/SGmoonspore.lua
-- 模块：状态图 / SGmoonspore
-- 职责：状态图「SGmoonspore」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("stategraphs/commonstates")

local events=
{
    EventHandler("pop", function(inst) -- for instantaneous pops
        inst.sg:GoToState("pop")
    end),
    EventHandler("preparedpop", function(inst) -- for a delayed pop
        inst.sg:GoToState("pre_pop")
    end),
}

local function return_to_idle(inst)
    inst.sg:GoToState("idle")
end

local states=
{
    State{
        name = "pre_pop",
        tags = {"busy"},

        onenter = function(inst)
            inst.AnimState:PlayAnimation("rumble", true)

            inst.sg:SetTimeout(26 * FRAMES)
        end,

        ontimeout = function(inst)
            inst.sg:GoToState("pop")
        end,
    },

    State{
        name = "pop",
        tags = {"busy"},

        onenter = function(inst)
            inst.AnimState:PlayAnimation("explode")
        end,

        timeline =
        {
            TimeEvent(4*FRAMES, function(inst)
                inst.Light:Enable(false)
                inst.DynamicShadow:Enable(false)

                inst:PushEvent("popped")
            end),
        },

        events =
        {
            EventHandler("animover", function(inst)
                inst:Remove()
            end),
        },
    },

    State{
        name = "idle",
        tags = {"idle", "canrotate"},

        onenter = function(inst)
            if not inst.AnimState:IsCurrentAnimation("idle_flight_loop") then
                inst.AnimState:PlayAnimation("idle_flight_loop", true)
            end
            inst.sg:SetTimeout( inst.AnimState:GetCurrentAnimationLength() )
        end,

        ontimeout = return_to_idle,
    },

    State{
        name = "takeoff",
        tags = {"busy"},

        onenter = function(inst)
            inst.AnimState:PlayAnimation("cough_out")
        end,

        timeline =
        {
            TimeEvent(14*FRAMES, function(inst)
                inst.Light:Enable(true)
                inst.DynamicShadow:Enable(true)
                inst.SoundEmitter:PlaySound("dontstarve/cave/mushtree_tall_spore_land")
            end),
        },

        events =
        {
            EventHandler("animover", return_to_idle),
        },
    },
}

return StateGraph("moonspore", states, events, "takeoff")
