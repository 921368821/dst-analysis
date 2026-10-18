--============================================================
-- 文件：stategraphs/SGwormhole_limited.lua
-- 模块：状态图 / SGwormhole_limited
-- 职责：状态图「SGwormhole_limited」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function SetGroundLayering(inst)
	inst.AnimState:SetLayer(LAYER_BACKGROUND)
	inst.AnimState:SetSortOrder(3)
end

local function SetBBLayering(inst)
	inst.AnimState:SetLayer(LAYER_WORLD)
	inst.AnimState:SetSortOrder(0)
end

local states=
{
	State{
		name = "idle",
		tags = {"idle"},
		onenter = function(inst)
			SetBBLayering(inst)
			inst.AnimState:PlayAnimation("idle_loop", true)

			inst.sg:SetTimeout(math.random()*6 + 2)
		end,

		ontimeout = function(inst)
			inst.sg:GoToState("idlecough")
		end,

	},

	State{

		name = "idlecough",
		tags = {"idle"},

		onenter = function(inst)
			SetBBLayering(inst)
			inst.AnimState:PlayAnimation("cough")
		end,

		timeline=
		{
			TimeEvent(6*FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/common/teleportworm/sick_cough")	end),
			TimeEvent(18*FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/common/teleportworm/sick_cough") end),
		},

		events=
		{
			EventHandler("animover", function(inst) inst.sg:GoToState("idle") end),
		},

	},

	State{
		name = "open",
		tags = {"idle", "open"},
		onenter = function(inst)
			SetGroundLayering(inst)
			inst.AnimState:PlayAnimation("open_loop", true)
			-- since we can jump right to the open state, retrigger this sound.
			inst.SoundEmitter:PlaySound("dontstarve/common/teleportworm/idle", "wormhole_open")
		end,

		onexit = function(inst)
			inst.SoundEmitter:KillSound("wormhole_open")
		end,
	},

	State{
		name = "opening",
		tags = {"busy", "open"},
		onenter = function(inst)
			SetBBLayering(inst)
			inst.AnimState:PlayAnimation("open_pre")
			inst.SoundEmitter:PlaySound("dontstarve/common/teleportworm/open")
		end,

		timeline =
		{
			FrameEvent(10, SetGroundLayering),
		},

		events=
		{
			EventHandler("animover", function(inst)
				inst.sg:GoToState("open")
			end),
		},
	},

	State{
		name = "closing",
		tags = {"busy"},
		onenter = function(inst)
			SetGroundLayering(inst)
			inst.AnimState:PlayAnimation("open_pst")
			inst.SoundEmitter:PlaySound("dontstarve/common/teleportworm/close")
		end,

		timeline =
		{
			FrameEvent(4, SetBBLayering),
		},

		events=
		{
			EventHandler("animover", function(inst)
				inst.sg:GoToState("idle")
			end),
		},
	},


	State{
		name = "death",
		tags = {"busy"},

		onenter = function(inst)
			SetGroundLayering(inst)
			inst.AnimState:PlayAnimation("death")
			inst.SoundEmitter:PlaySound("dontstarve/common/teleportworm/sick_die")
			--play death sound
		end,

		timeline=
		{
			FrameEvent(5, SetBBLayering),
			TimeEvent(39*FRAMES, function(inst) inst.SoundEmitter:PlaySound("dontstarve/common/teleportworm/sick_splat")	end),
		},

		events =
		{
			EventHandler("animover", function(inst)
				--remove worm from world
				inst:Remove()
			 end),
		},
	},
}

return StateGraph("wormhole", states, {}, "idle")
