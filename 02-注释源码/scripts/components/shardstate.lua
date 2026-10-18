--============================================================
-- 文件：components/shardstate.lua
-- 模块：组件 / shardstate
-- 职责：组件「shardstate」的实现。组件是挂在实体上的行为单元，通过 inst.components.shardstate 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ ShardState ]]
--------------------------------------------------------------------------

return Class(function(self, inst)

--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

--Public
self.inst = inst

--Private
local _world = TheWorld
local _ismastersim = _world.ismastersim

--Network
local _mastersessionid = net_string(inst.GUID, "shardstate._mastersessionid", "mastersessioniddirty")

--------------------------------------------------------------------------
--[[ Private event listeners ]]
--------------------------------------------------------------------------

local OnNewMasterSessionId = _ismastersim and function(src, session_id)
    _mastersessionid:set(session_id)
end or nil

local OnMasterSessionIdDirty = not _ismastersim and function()
    TheNet:SetClientCacheSessionIdentifier(_mastersessionid:value())
    SerializeUserSession(ThePlayer, true)
end or nil

--------------------------------------------------------------------------
--[[ Public methods ]]
--------------------------------------------------------------------------

function self:GetMasterSessionId()
    return _mastersessionid:value()
end

--------------------------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------

--Initialize network variables
_mastersessionid:set(_world.meta.session_identifier)

if _ismastersim then
    --Register master simulation events
    inst:ListenForEvent("ms_newmastersessionid", OnNewMasterSessionId, _world)
else
    --Register network variable sync events
    inst:ListenForEvent("mastersessioniddirty", OnMasterSessionIdDirty)
end

--------------------------------------------------------------------------
--[[ End ]]
--------------------------------------------------------------------------

end)
