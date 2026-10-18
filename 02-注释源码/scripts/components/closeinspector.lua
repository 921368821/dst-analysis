--============================================================
-- 文件：components/closeinspector.lua
-- 模块：组件 / closeinspector
-- 职责：组件「closeinspector」的实现。组件是挂在实体上的行为单元，通过 inst.components.closeinspector 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local CloseInspector = Class(function(self, inst)
	self.inst = inst
	--self.inspecttargetfn = nil
	--self.inspectpointfn = nil

	--V2C: Recommended to explicitly add tag to prefab pristine state
	inst:AddTag("closeinspector")
end)

function CloseInspector:OnRemoveFromEntity()
	self.inst:RemoveTag("closeinspector")
end

function CloseInspector:SetInspectTargetFn(fn)
	--fn should return action resulsts: success, reason
	self.inspecttargetfn = fn
end

function CloseInspector:SetInspectPointFn(fn)
	--fn should return action resulsts: success, reason
	self.inspectpointfn = fn
end

function CloseInspector:CloseInspectTarget(doer, target)
	if self.inspecttargetfn then
		return self.inspecttargetfn(self.inst, doer, target)
	end
end

function CloseInspector:CloseInspectPoint(doer, pt)
	if self.inspectpointfn then
		return self.inspectpointfn(self.inst, doer, pt)
	end
end

return CloseInspector
