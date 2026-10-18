--============================================================
-- 文件：stategraphs/SGcattoy_mouse.lua
-- 模块：状态图 / SGcattoy_mouse
-- 职责：状态图「SGcattoy_mouse」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local events =
{
    CommonHandlers.OnLocomote(true, false),
}

local states = {}

CommonStates.AddSimpleState(states, "idle", "idle", {"idle"})

CommonStates.AddRunStates(states, nil,
{
    startrun = "run_pre2",
}, nil, nil,
{
    startonenter = function(inst)
        inst.SoundEmitter:PlaySound("summerevent/carnival_games/herding_station/chicks/LP", "active_loop")
    end,
    endonenter = function(inst)
        inst.SoundEmitter:KillSound("active_loop")
    end,
})

return StateGraph("cattoy_mouse", states, events, "idle")
