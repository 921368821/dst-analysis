--============================================================
-- 文件：components/sanityaura.lua
-- 模块：组件 / sanityaura
-- 职责：组件「sanityaura」的实现。组件是挂在实体上的行为单元，通过 inst.components.sanityaura 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SanityAura = Class(function(self, inst)
    self.inst = inst
    self.aura = 0
    
    --self.max_distsq = nil
    --self.aurafn = nil
    --self.fallofffn = nil

	self.inst:AddTag("sanityaura")
end)

function SanityAura:OnRemoveFromEntity()
	self.inst:RemoveTag("sanityaura")
end

function SanityAura:GetBaseAura(observer) --No falloff.
	return self.aurafn == nil and self.aura or self.aurafn(self.inst, observer)
end

function SanityAura:SetBaseAuraName(baseauraname)
    -- Auras with the same source name will count as one. It is assumed all auras with the same name have the same magnitude.
    self.baseauraname = baseauraname
end

local SANITY_EFFECT_RANGE_SQ = TUNING.SANITY_EFFECT_RANGE * TUNING.SANITY_EFFECT_RANGE
function SanityAura:GetAura(observer)
	local aura_val = 0
	local distsq = observer:GetDistanceSqToInst(self.inst)
	if distsq <= (self.max_distsq or SANITY_EFFECT_RANGE_SQ) then
	    aura_val = (self.aurafn == nil and self.aura or self.aurafn(self.inst, observer)) / (self.fallofffn ~= nil and self.fallofffn(self.inst, observer, distsq) or math.max(1, distsq))
	end
    return aura_val
end

return SanityAura
