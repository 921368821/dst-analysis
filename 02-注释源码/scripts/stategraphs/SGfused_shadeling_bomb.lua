--============================================================
-- 文件：stategraphs/SGfused_shadeling_bomb.lua
-- 模块：状态图 / SGfused_shadeling_bomb
-- 职责：状态图「SGfused_shadeling_bomb」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("stategraphs/commonstates")

local events =
{
    EventHandler("locomote", function(inst)
        local is_moving = inst.sg:HasStateTag("moving")
        local is_idling = inst.sg:HasStateTag("idle")

        local should_move = inst.components.locomotor:WantsToMoveForward()

        if is_moving and not should_move then
            inst.sg:GoToState("idle")
        elseif is_idling and should_move then
            inst.sg:GoToState("walk")
        end
    end),
}

local states = {
    State {
        name = "walk",
        tags = { "moving", "canrotate" },

        onenter = function(inst)
            inst.components.locomotor:WalkForward()
            inst.AnimState:PlayAnimation("walk", true)
            inst.SoundEmitter:PlaySound("rifts2/parasitic_shadeling/dreadmite_walk", "walk")
            inst.sg:SetTimeout(inst.AnimState:GetCurrentAnimationLength())
        end,

        ontimeout = function(inst)
            inst.sg:GoToState("walk")
        end,

        onexit = function(inst)
            inst.SoundEmitter:KillSound("walk")
        end,
    },
}

CommonStates.AddSimpleState(states, "bounce", "bounce", {"busy"}, "idle_ground")
CommonStates.AddSimpleState(states, "idle_ground", "idle_ground", { "idle" }, "idle_ground")
CommonStates.AddSimpleState(states, "spawn", "spawn", {"busy"}, nil, nil,
{
    onenter = function(inst)
        inst.components.timer:StartTimer("finish_spawn", inst.AnimState:GetCurrentAnimationLength() + (1/3))
    end,
})
CommonStates.AddSimpleState(states, "idle", "idle_2", { "idle", "canrotate" })

return StateGraph("fused_shadeling_bomb", states, events, "bounce")