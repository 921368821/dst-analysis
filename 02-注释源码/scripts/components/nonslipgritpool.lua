--============================================================
-- 文件：components/nonslipgritpool.lua
-- 模块：组件 / nonslipgritpool
-- 职责：组件「nonslipgritpool」的实现。组件是挂在实体上的行为单元，通过 inst.components.nonslipgritpool 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local NonSlipGritPool = Class(function(self, inst)
    self.inst = inst

    --self.isgritatfn = nil

    -- NOTES(JBK): Recommended to explicitly add tag to prefab pristine state
    self.inst:AddTag("nonslipgritpool")
end)

function NonSlipGritPool:OnRemoveFromEntity()
    self.inst:RemoveTag("nonslipgritpool")
end

function NonSlipGritPool:SetIsGritAtPoint(fn)
    self.isgritatfn = fn
end

function NonSlipGritPool:IsGritAtPosition(x, y, z)
    if self.isgritatfn ~= nil then
        return self.isgritatfn(self.inst, x, y, z)
    end

    if self.inst.Physics ~= nil then
        local r = self.inst.Physics:GetRadius()
        local ex, ey, ez = self.inst.Transform:GetWorldPosition()
        local dx, dz = ex - x, ez - z
        return dx * dx + dz * dz < r * r
    end

    return false
end

return NonSlipGritPool
