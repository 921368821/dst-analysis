--============================================================
-- 文件：components/sewing.lua
-- 模块：组件 / sewing
-- 职责：组件「sewing」的实现。组件是挂在实体上的行为单元，通过 inst.components.sewing 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Sewing = Class(function(self, inst)
    self.inst = inst
    self.repair_value = 1
end)

function Sewing:DoSewing(target, doer)

    if target:HasTag("needssewing") then

		target.components.fueled:DoDelta(self.repair_value)

		if self.inst.components.finiteuses then
			self.inst.components.finiteuses:Use(1)
		elseif self.inst.components.stackable then
			self.inst.components.stackable:Get(1):Remove()
		end

		if self.onsewn then
			self.onsewn(self.inst, target, doer)
		end

		AwardPlayerAchievement("sewing_kit", doer)

		return true
	end

end

return Sewing