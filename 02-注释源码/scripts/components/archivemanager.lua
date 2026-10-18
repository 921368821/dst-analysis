--============================================================
-- 文件：components/archivemanager.lua
-- 模块：组件 / archivemanager
-- 职责：组件「archivemanager」的实现。组件是挂在实体上的行为单元，通过 inst.components.archivemanager 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--------------------------------------------------------------------------
--[[ grottowarmanager class definition ]]
--------------------------------------------------------------------------

return Class(function(self, inst)

assert(TheWorld.ismastersim, "ArchiveManager should not exist on client")

--------------------------------------------------------------------------
--[[ Constants ]]
--------------------------------------------------------------------------



--------------------------------------------------------------------------
--[[ Member variables ]]
--------------------------------------------------------------------------

--Public
self.inst = inst

--Private
local _power_enabled = false


--------------------------------------------------------------------------
--[[ Private member functions ]]
--------------------------------------------------------------------------

--------------------------------------------------------------------------
--[[ Public member functions ]]
--------------------------------------------------------------------------

function self:SwitchPowerOn(setting)
	if _power_enabled ~= true and setting == true then
		_power_enabled = true
        WORLDSTATETAGS.SetTagEnabled("ARCHIVES_ENERGIZED", true)
		self.inst:PushEvent("arhivepoweron")
	elseif _power_enabled ~= false and setting  == false then
		_power_enabled = false
        WORLDSTATETAGS.SetTagEnabled("ARCHIVES_ENERGIZED", false)
		self.inst:PushEvent("arhivepoweroff")
	end
end

function self:GetPowerSetting()
	return _power_enabled
end

--------------------------------------------------------------------------
--[[ Private event handlers ]]
--------------------------------------------------------------------------

--------------------------------------------------------------------------
--[[ Initialization ]]
--------------------------------------------------------------------------

--Register events
--inst:ListenForEvent("ms_playerjoined", OnPlayerJoined)

--------------------------------------------------------------------------
--[[ Save/Load ]]
--------------------------------------------------------------------------

--@V2C deleted save/load, typo means it never worked here.
--     power state is loaded from archive_switch instead.

--------------------------------------------------------------------------
--[[ Debug ]]
--------------------------------------------------------------------------

function self:GetDebugString()
    return tostring(_power_enabled)
end

--------------------------------------------------------------------------
--[[ End ]]
--------------------------------------------------------------------------

end)