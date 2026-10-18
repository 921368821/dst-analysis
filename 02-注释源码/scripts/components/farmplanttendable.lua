--============================================================
-- 文件：components/farmplanttendable.lua
-- 模块：组件 / farmplanttendable
-- 职责：组件「farmplanttendable」的实现。组件是挂在实体上的行为单元，通过 inst.components.farmplanttendable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local function ontendable(self)
	if self.tendable then
        self.inst:AddTag("tendable_farmplant")
	else
        self.inst:RemoveTag("tendable_farmplant")
    end
end


local FarmPlantTendable = Class(function(self, inst)
    self.inst = inst

	--self.ontendtofn = nil
	self.tendable = true
end,
nil,
{
    tendable = ontendable,
})

function FarmPlantTendable:SetTendable(tendable)
	self.tendable = tendable
end

function FarmPlantTendable:TendTo(doer)
	if self.tendable and self.ontendtofn ~= nil and self.ontendtofn(self.inst, doer) then
		self.tendable = false
		return true
	end
end

function FarmPlantTendable:OnSave()
	return { tendable = self.tendable }
end

function FarmPlantTendable:OnLoad(data)
	if data ~= nil then
		self.tendable = data.tendable
	end
end

return FarmPlantTendable
