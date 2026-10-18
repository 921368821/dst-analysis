--============================================================
-- 文件：stategraphs/SGabysspillar_minion.lua
-- 模块：状态图 / SGabysspillar_minion
-- 职责：状态图「SGabysspillar_minion」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("stategraphs/commonstates")

local events =
{
	CommonHandlers.OnLocomote(true, false),
	CommonHandlers.OnHop(),
	EventHandler("deactivate", function(inst)
		if not inst.sg:HasStateTag("deactivating") then
			inst.sg:GoToState("deactivate")
		end
	end),
}

local states =
{
	State{
		name = "idle",
		tags = { "idle", "canrotate" },

		onenter = function(inst, pushanim)
			inst.components.locomotor:Stop()
			if pushanim then
				inst.AnimState:PushAnimation("idle_on")
			else
				inst.AnimState:PlayAnimation("idle_on", true)
			end
			inst.SoundEmitter:PlaySound("rifts6/sequitor/idle_LP", "loop")
		end,

		onexit = function(inst)
			inst.SoundEmitter:KillSound("loop")
		end,
	},

	State{
		name = "activate",
		tags = { "idle", "canrotate" },

		onenter = function(inst)
			inst.components.locomotor:Stop()
			inst.AnimState:PlayAnimation("turn_on_pst")
			inst.SoundEmitter:PlaySound("rifts6/sequitor/jump_land")
		end,

		events =
		{
			EventHandler("animover", function(inst)
				if inst.AnimState:AnimDone() then
					inst.sg:GoToState("idle")
				end
			end),
		},
	},

	State{
		name = "deactivate",
		tags = { "deactivating", "busy", "canrotate" },

		onenter = function(inst)
			inst.components.locomotor:Stop()
			inst.AnimState:PlayAnimation("turn_off_pre")
			inst.SoundEmitter:PlaySound("rifts6/sequitor/jump")
			inst:AddTag("ignorewalkableplatformdrowning")
		end,

		events =
		{
			EventHandler("animover", function(inst)
				if inst.AnimState:AnimDone() then
					inst.sg.statemem.deactivating = true
					inst.sg:GoToState("deactivate_delay")
				end
			end),
		},

		onexit = function(inst)
			if not inst.sg.statemem.deactivating then
				inst:RemoveTag("ignorewalkableplatformdrowning")
			end
		end,
	},

	State{
		name = "deactivate_delay",
		tags = { "deactivating", "busy", "canrotate" },

		onenter = function(inst)
			inst.sg:SetTimeout(0.25 + math.random() * 0.15)
		end,

		ontimeout = function(inst)
			local bigpillar, leftminion = inst:GetBigPillar()
			if bigpillar then
				--Deactivate will remove the tag as well
				--inst:RemoveTag("ignorewalkableplatformdrowning")
				inst:SetOnBigPillar(bigpillar, leftminion)
			else
				inst:Remove()
			end
		end,

		events =
		{
			EventHandler("entitysleep", function(inst)
				local bigpillar, leftminion = inst:GetBigPillar()
				if bigpillar then
					--Deactivate will remove the tag as well
					--inst:RemoveTag("ignorewalkableplatformdrowning")
					inst:SetOnBigPillar(bigpillar, leftminion)
				else
					inst:Remove()
				end
			end),
		},
	},

	State{
		name = "run_start",
		onenter = function(inst) inst.sg:GoToState("run") end,
	},

	State{
		name = "run",
		tags = { "moving", "running", "canrotate" },

		onenter = function(inst)
			inst.components.locomotor:RunForward()
			if not inst.AnimState:IsCurrentAnimation("idle_on") then
				inst.AnimState:PlayAnimation("idle_on", true)
			end
		end,
	},

	State{
		name = "run_stop",
		onenter = function(inst) inst.sg:GoToState("idle") end,
	},
}

CommonStates.AddHopStates(states, true,
{
	pre = "jump_pre",
	loop = "jump_loop",
	pst = "jump_pst",
},
{
	hop_pst =
	{
		FrameEvent(0, function(inst) inst.SoundEmitter:PlaySound("rifts6/sequitor/jump_land") end),
		FrameEvent(7, function(inst)
			inst.sg:GoToState("idle", true)
		end),
	},
}, nil, nil,
{ start_embarking_pre_frame = 1 * FRAMES })

return StateGraph("abysspillar_minion", states, events, "idle")
