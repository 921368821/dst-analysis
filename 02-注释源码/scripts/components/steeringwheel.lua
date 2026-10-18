--============================================================
-- 文件：components/steeringwheel.lua
-- 模块：组件 / steeringwheel
-- 职责：组件「steeringwheel」的实现。组件是挂在实体上的行为单元，通过 inst.components.steeringwheel 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SteeringWheel = Class(function(self, inst)
    self.inst = inst

    self.inst:AddTag("steeringwheel")

	--self.onstartfn = nil
	--self.onstopfn = nil

	self.onsailorremoved = function(sailor) if sailor == self.sailor then self:StopSteering() end end
end)


function SteeringWheel:SetOnStartSteeringFn(fn)
	self.onstartfn = fn
end

function SteeringWheel:SetOnStopSteeringFn(fn)
	self.onstopfn = fn
end

function SteeringWheel:StartSteering(sailor)
	self.sailor = sailor
	self.inst:ListenForEvent("onremove", self.onsailorremoved, sailor)

	self.inst:AddTag("occupied")

	if self.onstartfn ~= nil then
		self.onstartfn(self.inst, sailor)
	end
end

function SteeringWheel:StopSteering()
	if self.sailor ~= nil then
		self.inst:ListenForEvent("onremove", self.onsailorremoved, self.sailor)
	end
	self.inst:RemoveTag("occupied")

	if self.onstopfn ~= nil then
		self.onstopfn(self.inst, self.sailor)
	end
	self.sailor = nil
end

function SteeringWheel:OnRemoveFromEntity()
	if self.sailor ~= nil then
		if self.sailor.components.steeringwheeluser ~= nil then
			self.sailor.components.steeringwheeluser:SetSteeringWheel(nil)
		else
			self:StopSteering()
		end
	end
end

function SteeringWheel:GetDebugString()
	return "Sailor: " .. tostring(self.sailor)
end

return SteeringWheel
