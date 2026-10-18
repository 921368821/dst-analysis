--============================================================
-- 文件：components/flotationdevice.lua
-- 模块：组件 / flotationdevice
-- 职责：组件「flotationdevice」的实现。组件是挂在实体上的行为单元，通过 inst.components.flotationdevice 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local FlotationDevice = Class(function(self, inst)
    self.inst = inst

	self.enabled = true
	--self.onpreventdrowningdamagefn  = nil
end)

function FlotationDevice:IsEnabled()
    return self.enabled
end

function FlotationDevice:OnPreventDrowningDamage()
	if self.onpreventdrowningdamagefn ~= nil then
		self.onpreventdrowningdamagefn(self.inst)
	end
end

return FlotationDevice
