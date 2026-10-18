--============================================================
-- 文件：components/simplebook.lua
-- 模块：组件 / simplebook
-- 职责：组件「simplebook」的实现。组件是挂在实体上的行为单元，通过 inst.components.simplebook 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local SimpleBook = Class(function(self, inst)
	self.inst = inst

	self.inst:AddTag("simplebook")

	--self.onreadfn = nil
end)

function SimpleBook:OnRemoveFromEntity()
    self.inst:RemoveTag("simplebook")
end

function SimpleBook:Read(doer)
	if not CanEntitySeeTarget(doer, self.inst) then
		return false
	end

	if self.onreadfn then
		self.onreadfn(self.inst, doer)
	end
end

return SimpleBook