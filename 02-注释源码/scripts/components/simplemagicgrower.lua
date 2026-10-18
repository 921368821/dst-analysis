--============================================================
-- 文件：components/simplemagicgrower.lua
-- 模块：组件 / simplemagicgrower
-- 职责：组件「simplemagicgrower」的实现。组件是挂在实体上的行为单元，通过 inst.components.simplemagicgrower 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SimpleMagicGrower = Class(function(self, inst)
    self.inst = inst
end)

function SimpleMagicGrower:SetLastStage(last_stage)
	self.last_stage = last_stage
end

function SimpleMagicGrower:Grow()

	if self.inst.components.growable == nil or self.last_stage == nil then
		return
	end

	if self.inst.components.growable.stage < self.last_stage then
		self.inst.components.growable:DoGrowth()
		self.inst:DoTaskInTime(math.random(), function() self:Grow() end)
	else
		self.inst.components.growable:StartGrowing()
		self.inst:RemoveTag("magicgrowth")
	end
end

function SimpleMagicGrower:StartGrowing()
	self.inst:AddTag("magicgrowth")
	self:Grow()
end

return SimpleMagicGrower