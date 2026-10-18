--============================================================
-- 文件：components/pocketwatch.lua
-- 模块：组件 / pocketwatch
-- 职责：组件「pocketwatch」的实现。组件是挂在实体上的行为单元，通过 inst.components.pocketwatch 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local function oninactive(self, inactive)
    self.inst:AddOrRemoveTag("pocketwatch_inactive", inactive)
end

local PocketWatch = Class(function(self, inst)
    self.inst = inst

	self.inactive = true
end,
nil,
{
    inactive = oninactive,
})

function PocketWatch:OnRemoveFromEntity()
    self.inst:RemoveTag("pocketwatch_inactive")
end


function PocketWatch:CanCast(doer, target, pos)
	return self.inactive and (self.CanCastFn == nil or self.CanCastFn(self.inst, doer, target, pos))
end

function PocketWatch:CastSpell(doer, target, pos)
    if self.DoCastSpell ~= nil and self.inactive then
        local success, reason = self.DoCastSpell(self.inst, doer, target, pos)
        return success, reason
    else
        return false
    end
end

return PocketWatch
