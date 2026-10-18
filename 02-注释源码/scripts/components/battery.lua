--============================================================
-- 文件：components/battery.lua
-- 模块：组件 / battery
-- 职责：组件「battery」的实现。组件是挂在实体上的行为单元，通过 inst.components.battery 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Battery = Class(function(self, inst)
    self.inst = inst

    --V2C: Recommended to explicitly add tag to prefab pristine state
    self.inst:AddTag("battery")

    --self.canbeused = nil
    --self.onused = nil
	--self.resolvepartialchargemult = nil
end)

function Battery:OnRemoveFromEntity()
    self.inst:RemoveTag("battery")
end

function Battery:SetCanBeUsedFn(fn)
	self.canbeused = fn
end

function Battery:SetOnUsedFn(fn)
	self.onused = fn
end

function Battery:SetResolvePartialChargeMultFn(fn)
	self.resolvepartialchargemult = fn
end

---------------------------------------------------------------------------------

--can return a lower mult if battery supports partial charge when not enough power left
function Battery:ResolvePartialChargeMult(user, mult)
	return self.resolvepartialchargemult and self.resolvepartialchargemult(self.inst, user, mult) or mult
end

function Battery:CanBeUsed(user, mult)
    if self.canbeused ~= nil then
		return self.canbeused(self.inst, user, mult) --returns success, reason
    else
        return true
    end
end

function Battery:OnUsed(user, mult)
    if self.onused ~= nil then
		self.onused(self.inst, user, mult)
    end
end

return Battery
