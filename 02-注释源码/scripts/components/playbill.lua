--============================================================
-- 文件：components/playbill.lua
-- 模块：组件 / playbill
-- 职责：组件「playbill」的实现。组件是挂在实体上的行为单元，通过 inst.components.playbill 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local Playbill = Class(function(self, inst)
    self.scripts = {}
    self.costumes = {}
    self.starting_act = nil
    self.current_act = nil
	self.book_build = nil
end)

function Playbill:SetCurrentAct(act)
	self.current_act = act
end

function Playbill:OnSave()
	local data = {
		current_act = self.current_act
	}
	return data
end

function Playbill:OnLoad(data)
	if data and data.current_act then
		self.current_act = data.current_act
	end
end

return Playbill
