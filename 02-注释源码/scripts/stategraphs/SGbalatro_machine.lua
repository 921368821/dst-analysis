--============================================================
-- 文件：stategraphs/SGbalatro_machine.lua
-- 模块：状态图 / SGbalatro_machine
-- 职责：状态图「SGbalatro_machine」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local events=
{

}

local states =
{
    -------------------------------
    State{
        name = "idle",
        onenter = function(inst)
            inst.AnimState:PlayAnimation("idle")
            inst.sg:SetTimeout(math.random(3,6))
        end,

        ontimeout = function(inst)
        
            if inst.rewarding then
                inst.sg:GoToState("idle")
                return
            end

            local player = inst:GetNearestPlayer(true)                    
            if player and player:GetDistanceSqToInst(inst) < 8*8 and not inst.components.timer:TimerExists("beckon") then
                inst.components.timer:StartTimer("beckon",20)
                inst.sg:GoToState("talk")
                inst.components.talker:Chatter("JIMBO_BECKON", math.random(1, #STRINGS.BALATRO.JIMBO_BECKON))
            else
                inst.sg:GoToState("idle")
            end

        end,

    },

----------------------------------------

    State{
        name = "talk",
        onenter = function(inst, data)
            inst.AnimState:PlayAnimation("talk"..math.random(1,3))
            inst.SoundEmitter:PlaySound("balatro/balatro_cabinet/jimbo_talk_3D_SFX")
        end,

        events =
        {
            EventHandler("animover",
                function(inst)
                    inst.sg:GoToState("idle")
                end),
        },
    },
 
     
}

return StateGraph("balatro_machine", states, events, "idle")
