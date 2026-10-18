--============================================================
-- 文件：stategraphs/SGgingerdeadpig.lua
-- 模块：状态图 / SGgingerdeadpig
-- 职责：状态图「SGgingerdeadpig」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("stategraphs/commonstates")

local actionhandlers =
{
}

local events=
{
    CommonHandlers.OnStep(),
    CommonHandlers.OnLocomote(true, true),
    EventHandler("death", function(inst) inst.sg:GoToState("death") end),
}

local states =
{
    State{
        name = "idle",
        tags = { "idle" },

        onenter = function(inst)
            inst.Physics:Stop()

            inst.AnimState:PlayAnimation("crawl_loop", true)
        end,

        events =
        {
            EventHandler("animover", function(inst)
                inst.sg:GoToState("idle")
            end),
        },
    },


    State{
        name = "death",
        tags = { "busy" },

        onenter = function(inst)
            inst.AnimState:PlayAnimation("crawl_death")
            inst.components.locomotor:StopMoving()
            RemovePhysicsColliders(inst)
        end,

        timeline=
        {
            TimeEvent(2* FRAMES, function(inst) inst.SoundEmitter:PlaySound("wintersfeast2019/creatures/gingerbreadpig/death1") end),
            TimeEvent(43* FRAMES, function(inst) inst.SoundEmitter:PlaySound("wintersfeast2019/creatures/gingerbreadpig/death2") end),
            TimeEvent(47* FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/frog/splat",nil,.5) end),
        },

        events =
        {
            EventHandler("animover", function(inst) inst:DoTaskInTime(1, ErodeAway) end),
        },
    },

    State{
        name = "walk_start",
        tags = { "moving", "canrotate" },

        onenter = function(inst)
            inst.components.locomotor:WalkForward(true)
            inst.AnimState:PlayAnimation("crawl_loop")
        end,

        timeline=
        {
            TimeEvent(6 * FRAMES, function(inst) inst.SoundEmitter:PlaySound("wintersfeast2019/creatures/gingerbreadpig/step",nil,.25) end),
            TimeEvent(13* FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/movement/foley/bushhat") end),
            TimeEvent(24* FRAMES, function(inst) inst.SoundEmitter:PlaySound("wintersfeast2019/creatures/gingerbreadpig/step",nil,.25) end),
            TimeEvent(31* FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/movement/foley/bushhat") end),
        },

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("walk") end),
        },
    },

    State{
        name = "walk",
        tags = { "moving", "canrotate" },

        onenter = function(inst)
            inst.AnimState:PlayAnimation("crawl_loop", true)
            inst.sg:SetTimeout(inst.AnimState:GetCurrentAnimationLength())
        end,

        timeline=
        {
            TimeEvent(6 * FRAMES, function(inst) inst.SoundEmitter:PlaySound("wintersfeast2019/creatures/gingerbreadpig/step",nil,.25) end),
            TimeEvent(13* FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/movement/foley/bushhat") end),
            TimeEvent(24* FRAMES, function(inst) inst.SoundEmitter:PlaySound("wintersfeast2019/creatures/gingerbreadpig/step",nil,.25) end),
            TimeEvent(31* FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/movement/foley/bushhat") end),
        },

        ontimeout = function(inst) inst.sg:GoToState("death") end,
    },

    State{
        name = "walk_stop",
        tags = { "canrotate" },

        onenter = function(inst)
            inst.components.locomotor:StopMoving()
            inst.AnimState:PlayAnimation("crawl_death")
        end,

        events =
        {
            EventHandler("animqueueover", function(inst) inst.sg:GoToState("walk_start") end),
        },
    }
}

return StateGraph("gingerdeadpig", states, events, "idle", actionhandlers)