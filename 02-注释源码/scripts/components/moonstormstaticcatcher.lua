--============================================================
-- 文件：components/moonstormstaticcatcher.lua
-- 模块：组件 / moonstormstaticcatcher
-- 职责：组件「moonstormstaticcatcher」的实现。组件是挂在实体上的行为单元，通过 inst.components.moonstormstaticcatcher 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MoonstormStaticCatcher = Class(function(self, inst)
	self.inst = inst
	self.target = nil
    self.oncaughtfn = nil
end)

function MoonstormStaticCatcher:OnRemoveFromEntity()
	self:OnUntarget()
end

function MoonstormStaticCatcher:SetOnCaughtFn(fn)
    self.oncaughtfn = fn
end

function MoonstormStaticCatcher:Catch(target, doer)
    local objectradius = 0.2 -- NOTES(JBK): Make this the same size for moonstorm_static. Search string [NOWAGPRF]
    if not target:IsValid() then
        return false, "MISSED"
    elseif not doer:IsNear(target, 1 + doer:GetPhysicsRadius(0) + objectradius) then
        return false, "MISSED"
    elseif not (target.components.moonstormstaticcapturable and target.components.moonstormstaticcapturable:IsEnabled()) then
        return false, "MISSED"
    end

    target.components.moonstormstaticcapturable:OnCaught(self.inst, doer)
    if self.oncaughtfn then
        self.oncaughtfn(self.inst, doer)
    end
    return true
end

function MoonstormStaticCatcher:OnTarget(target)
	if self.target ~= target then
		self:OnUntarget()
		if target:IsValid() and target.components.moonstormstaticcapturable then
			self.target = target
			target.components.moonstormstaticcapturable:OnTargeted(self.inst)
		end
	end
end

function MoonstormStaticCatcher:OnUntarget(target)
	if self.target and (target == nil or self.target == target) then
		target = self.target
		self.target = nil
		if target:IsValid() and target.components.moonstormstaticcapturable then
			target.components.moonstormstaticcapturable:OnUntargeted(self.inst)
		end
	end
end

return MoonstormStaticCatcher
