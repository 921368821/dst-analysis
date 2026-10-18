--============================================================
-- 文件：components/yotc_racestart.lua
-- 模块：组件 / yotc_racestart
-- 职责：组件「yotc_racestart」的实现。组件是挂在实体上的行为单元，通过 inst.components.yotc_racestart 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local YOTC_RaceStart = Class(function(self, inst)
	self.inst = inst

	self.onstartracefn = nil
	self.rats = {}

    self.inst:AddTag("yotc_racestart")
end,
nil,
{})

function YOTC_RaceStart:OnRemoveFromEntity()
    self.inst:RemoveTag("yotc_racestart")
end

function YOTC_RaceStart:StartRace()
	if self.onstartracefn ~= nil then
		self.onstartracefn(self.inst)
	end
	self.inst:AddTag("race_on")
end

function YOTC_RaceStart:EndRace()
	if self.onendracefn ~= nil then
		self.onendracefn(self.inst)
	end
	self.inst:RemoveTag("race_on")
end

function YOTC_RaceStart:CanInteract()
	if not self.inst:HasTag("race_on") then
		return true
	end
end


return YOTC_RaceStart