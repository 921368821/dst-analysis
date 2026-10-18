--============================================================
-- 文件：map/settings.lua
-- 模块：地图生成 / settings
-- 职责：世界生成相关：「settings」。参与地形、生物群系、资源分布与任务布置的生成流程。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

SettingsPreset = Class(function(self, data)
	assert( data.id ~= nil, "SettingsPreset must specify an id." )
	self:SetID(data.id)
	self:SetBaseID(data.baseid)
	self:SetNameAndDesc(data.name, data.desc)
    assert(data.location ~= nil, "SettingsPreset must specify a location")
    self.location = data.location

    self.hideinfrontend = data.hideinfrontend
	self.overrides = data.overrides or {}
    self.hideminimap = data.hideminimap or false

    self.version = data.version or 2
	self.version = math.max(self.version, 2) --minimum version is 2 because serverlistingscreen.

	self.playstyle = data.playstyle
end)

function SettingsPreset:SetID(id)
	assert(id ~= nil, "level must specify an id." )
	self.id = id
	self.settings_id = id
end

function SettingsPreset:SetBaseID(id)
	self.baseid = id
	self.settings_baseid = id
end

function SettingsPreset:SetNameAndDesc(name, desc)
	self.name = name or ""
	self.desc = desc or ""
	self.settings_name = self.name
	self.settings_desc = self.desc
end