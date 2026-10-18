--============================================================
-- 文件：stategraphs/SGboatmeter.lua
-- 模块：状态图 / SGboatmeter
-- 职责：状态图「SGboatmeter」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local events =
{
    EventHandler("close_meter", function(inst, data)
        if data.instant then
            inst.sg:GoToState("closed")
        else
            inst.sg:GoToState("close_pre")
        end
    end),
    EventHandler("open_meter", function(inst) inst.sg:GoToState("open_pre") end),
}

local states =
{
    State{
        name = "open",
        onenter = function(inst)
            inst.widget.backing:Show()
            inst.widget.badge:Show()
            inst.widget.icon:Show()
            inst.widget.leak_anim:Show()
        end,

        onupdate = function(inst)
            inst.widget:UpdateLeak()
        end,
    },

    State{
        name = "open_pre",
        onenter = function(inst)
            inst.widget.anim:GetAnimState():PlayAnimation("open_pre")
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("open_pst") end),
        },
    },

    State{
        name = "open_pst",
        onenter = function(inst)
            inst.widget.anim:GetAnimState():PlayAnimation("open_pst")
            inst.widget.backing:Show()
            inst.widget.badge:Show()
            inst.widget.icon:Show()
            inst.widget.leak_anim:Show()
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("open") end),
        },
    },

    State{
        name = "close_pre",
        onenter = function(inst)
            inst.widget.anim:GetAnimState():PlayAnimation("close_pre")
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("close_pst") end),
        },
    },

    State{
        name = "close_pst",
        onenter = function(inst)
            inst.widget.anim:GetAnimState():PlayAnimation("close_pst")
            inst.widget.backing:Hide()
            inst.widget.badge:Hide()
            inst.widget.icon:Hide()
            inst.widget.leak_anim:Hide()
        end,

        events =
        {
            EventHandler("animover", function(inst) inst.sg:GoToState("closed") end),
        },
    },

    State{
        name = "closed",
        onenter = function(inst)
            inst.widget.backing:Hide()
            inst.widget.badge:Hide()
            inst.widget.icon:Hide()
            inst.widget.leak_anim:Hide()
        end,
    },
}

return StateGraph("boatmeter", states, events, "closed")
