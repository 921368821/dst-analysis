--============================================================
-- 文件：components/replayproxy.lua
-- 模块：组件 / replayproxy
-- 职责：组件「replayproxy」的实现。组件是挂在实体上的行为单元，通过 inst.components.replayproxy 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ReplayProxy = Class(function(self, inst)
	self.inst = inst
	self.real_entity_guid = nil
	self.real_entity_prefab_name = ""
end)

function ReplayProxy:SetRealEntityGUID(guid)
	self.real_entity_guid = guid
end

function ReplayProxy:GetRealEntityGUID()
	return self.real_entity_guid
end

function ReplayProxy:SetRealEntityPrefabName(name)
	self.real_entity_prefab_name = name
end

function ReplayProxy:GetRealEntityPrefabName()
	return string.format("%d - %s", self.real_entity_guid, self.real_entity_prefab_name)
end

return ReplayProxy
