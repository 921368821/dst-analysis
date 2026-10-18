--============================================================
-- 文件：components/lavaarenamusic.lua
-- 模块：组件 / lavaarenamusic
-- 职责：组件「lavaarenamusic」的实现。组件是挂在实体上的行为单元，通过 inst.components.lavaarenamusic 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ LavaArenaMusic class definition ]]
--------------------------------------------------------------------------

return Class(function(self, inst)

--------------------------------------------------------------------------
--[[ Constants ]]
--------------------------------------------------------------------------

local MUSIC =
{
    "dontstarve/music/lava_arena/fight_1",
}

--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

--Public
self.inst = inst

--Private
local _world = TheWorld
local _soundemitter = nil
local _activatedplayer = nil --cached for activation/deactivation only, NOT for logic use
local _levelplaying = nil

--Network
local _netvars =
{
    level = net_tinybyte(inst.GUID, "lavaarenamusic._netvars.level", "leveldirty"),
}

--------------------------------------------------------------------------
--[[ Private event handlers ]]
--------------------------------------------------------------------------

local function OnLevelDirty(inst)
    if _netvars.level:value() ~= _levelplaying then
        _soundemitter:KillSound("bgm")
        local sound = MUSIC[_netvars.level:value()]
        if sound ~= nil then
            _soundemitter:PlaySound(sound, "bgm")
        end
    end
end

local function OnPlayerDeactivated(src, player)
    if player == _activatedplayer then
        _activatedplayer = nil
        _soundemitter:KillSound("bgm")
        _soundemitter = nil
        _levelplaying = nil
        inst:RemoveEventCallback("leveldirty", OnLevelDirty)
    end
end

local function OnPlayerActivated(src, player)
    if _activatedplayer ~= player then
        if _activatedplayer ~= nil then
            OnPlayerDeactivated(src, _activatedplayer)
        end
        _activatedplayer = player
        _soundemitter = TheFocalPoint.SoundEmitter
        inst:ListenForEvent("leveldirty", OnLevelDirty)
        OnLevelDirty(inst)
    end
end

--------------------------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------

--Register events
inst:ListenForEvent("playeractivated", OnPlayerActivated, _world)
inst:ListenForEvent("playerdeactivated", OnPlayerDeactivated, _world)

if _world.ismastersim then
    event_server_data("lavaarena", "components/lavaarenamusic").master_postinit(self, inst, _netvars)
end

--------------------------------------------------------------------------
--[[ End ]]
--------------------------------------------------------------------------

end)
