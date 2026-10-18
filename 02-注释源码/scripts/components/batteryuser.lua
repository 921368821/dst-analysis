--============================================================
-- 文件：components/batteryuser.lua
-- 模块：组件 / batteryuser
-- 职责：组件「batteryuser」的实现。组件是挂在实体上的行为单元，通过 inst.components.batteryuser 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BatteryUser = Class(function(self, inst)
    self.inst = inst
	self.chargemultfn = nil
	self.onbatteryused = nil
	self.allowpartialcharge = false

    --Recommended to explicitly add tag to prefab pristine state
    self.inst:AddTag("batteryuser")

    --self.onbatteryused = nil
end)

function BatteryUser:OnRemoveFromEntity()
    self.inst:RemoveTag("batteryuser")
end

function BatteryUser:SetChargeMultFn(fn)
	self.chargemultfn = fn
end

function BatteryUser:SetOnBatteryUsedFn(fn)
	self.onbatteryused = fn
end

function BatteryUser:SetAllowPartialCharge(allow)
	self.allowpartialcharge = allow
end

---------------------------------------------------------------------------------

function BatteryUser:ChargeFrom(charge_target)
	local mult = self.chargemultfn and self.chargemultfn(self.inst, charge_target)
	if mult and self.allowpartialcharge then
		mult = charge_target.components.battery:ResolvePartialChargeMult(self.inst, mult)
	end
	local result, reason = charge_target.components.battery:CanBeUsed(self.inst, mult)

    if result and self.onbatteryused ~= nil then
		result, reason = self.onbatteryused(self.inst, charge_target, mult)
    end

    -- If we successfully used the battery, evoke the battery's result (i.e. to tick down a fueled component)
    if result then
		charge_target.components.battery:OnUsed(self.inst, mult)
    end

    return result, reason
end

return BatteryUser
