--============================================================
-- 文件：components/appraisable.lua
-- 模块：组件 / appraisable
-- 职责：组件「appraisable」的实现。组件是挂在实体上的行为单元，通过 inst.components.appraisable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Appraisable = Class(function(self, inst)
	self.inst = inst
end)

function Appraisable:CanAppraise(target)
    -- NOTE: don't chain these together in case
    -- the canappraisefn returns a failure reason.
	if self.canappraisefn then
		return self.canappraisefn(self.inst, target)
    else
        return true
    end
end

function Appraisable:Appraise(target)
	if self.appraisefn then
		self.appraisefn(self.inst,target)
	end
end

return Appraisable
