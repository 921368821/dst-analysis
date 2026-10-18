--============================================================
-- 文件：components/container_transform.lua
-- 模块：组件 / container_transform
-- 职责：组件「container_transform」的实现。组件是挂在实体上的行为单元，通过 inst.components.container_transform 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ContainerTransform = Class(function(self, inst)
	self.inst = inst
	self.cantransform = nil
	self.ontransform = nil
end)

function ContainerTransform:SetCanTransform(fn)
	self.cantransform = fn or nil
end

function ContainerTransform:SetOnTransform(fn)
	self.ontransform = fn or nil
end

function ContainerTransform:IsTryingToOpenMe(inst)
	local target
    local act = inst:GetBufferedAction()
	if act then
		target = act.target
		act = act.action
	elseif inst.components.playercontroller then
		act, target = inst.components.playercontroller:GetRemoteInteraction()
	end
	return target == self.inst and act == ACTIONS.RUMMAGE
end

------------------------------------------

function ContainerTransform:CanTransform(doer)
	local success, reason = FunctionOrValue(self.cantransform, self.inst, doer)
	return success, reason
end

function ContainerTransform:TryTransformToContainer()
	return self.ontransform ~= nil and self.ontransform(self.inst)
end

return ContainerTransform