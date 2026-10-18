--============================================================
-- 文件：components/yotd_raceprizemanager.lua
-- 模块：组件 / yotd_raceprizemanager
-- 职责：组件「yotd_raceprizemanager」的实现。组件是挂在实体上的行为单元，通过 inst.components.yotd_raceprizemanager 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ raceprizemanager class definition ]]
--------------------------------------------------------------------------

return Class(function(self, inst)

assert(TheWorld.ismastersim, "yotd_raceprizemanager should not exist on client")

--------------------------------------------------------------------------
--[[ Constants ]]
--------------------------------------------------------------------------

--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

--Public
self.inst = inst

--Private
local _prize = 1
local _checkpoints = {}

--------------------------------------------------------------------------
--[[ Private member functions ]]
--------------------------------------------------------------------------


--------------------------------------------------------------------------
--[[ Private event handlers ]]
--------------------------------------------------------------------------
local function updateprize(inst, cycles)
    if IsSpecialEventActive(SPECIAL_EVENTS.YOTD) then
        if _prize < 1 then
            _prize = 1
            TheWorld:PushEvent("yotd_ratraceprizechange")
        end
    end
end


---------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------
inst:DoTaskInTime(0,function()
    if not IsSpecialEventActive(SPECIAL_EVENTS.YOTD) then
        _prize = 0
        TheWorld:PushEvent("yotd_ratraceprizechange")
    end
end)

--Register events

inst:WatchWorldState("cycles", updateprize)

--------------------------------------------------------------------------
--[[ Post initialization ]]
--------------------------------------------------------------------------

--------------------------------------------------------------------------
--[[ Public member functions ]]
--------------------------------------------------------------------------

function self:HasPrizeAvailable()
	return _prize > 0 
end

function self:PrizeGiven()
    _prize = _prize - 1
    TheWorld:PushEvent("yotd_ratraceprizechange")
end


function self:RegisterCheckpoint(checkpoint)
    if not _checkpoints[checkpoint] then
        _checkpoints[checkpoint] = true
    end
end

function self:UnregisterCheckpoint(checkpoint)
    if _checkpoints[checkpoint] then
        _checkpoints[checkpoint] = nil
    end
end

function self:GetCheckpoints()
    return shallowcopy(_checkpoints)
end

--------------------------------------------------------------------------
--[[ Save/Load ]]
--------------------------------------------------------------------------

function self:OnSave()
    local data = {}
    data.prize = _prize
    return data
end

function self:LoadPostPass(ents, data)
    if data then
		if data.prize ~= nil then
	        _prize = data.prize		
		end
    end

    TheWorld:PushEvent("yotd_ratraceprizechange")
end

--------------------------------------------------------------------------
--[[ Debug ]]
--------------------------------------------------------------------------

function self:GetDebugString()
    return string.format("prize:%d", _prize)
end


--------------------------------------------------------------------------
--[[ End ]]
--------------------------------------------------------------------------

end)

