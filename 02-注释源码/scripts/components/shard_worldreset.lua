--============================================================
-- 文件：components/shard_worldreset.lua
-- 模块：组件 / shard_worldreset
-- 职责：组件「shard_worldreset」的实现。组件是挂在实体上的行为单元，通过 inst.components.shard_worldreset 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ Shard_WorldReset ]]
--------------------------------------------------------------------------

return Class(function(self, inst)

assert(TheWorld.ismastersim, "Shard_WorldReset should not exist on client")

--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

--Public
self.inst = inst

--Private
local _world = TheWorld
local _ismastershard = _world.ismastershard

--Network
local _countdown = net_byte(inst.GUID, "shard_worldreset._countdown", "countdowndirty")

--------------------------------------------------------------------------
--[[ Private event listeners ]]
--------------------------------------------------------------------------

local OnCountdownUpdate = _ismastershard and function(src, data)
    _countdown:set(data.countdown)
end or nil

local OnCountdownDirty = not _ismastershard and function()
    _world:PushEvent("secondary_worldresetupdate", { countdown = _countdown:value() })
end or nil

--------------------------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------

if _ismastershard then
    --Register master shard events
    inst:ListenForEvent("master_worldresetupdate", OnCountdownUpdate, _world)
else
    --Register network variable sync events
    inst:ListenForEvent("countdowndirty", OnCountdownDirty)
end

--------------------------------------------------------------------------
--[[ End ]]
--------------------------------------------------------------------------

end)
