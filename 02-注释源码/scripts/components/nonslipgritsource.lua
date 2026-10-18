--============================================================
-- 文件：components/nonslipgritsource.lua
-- 模块：组件 / nonslipgritsource
-- 职责：组件「nonslipgritsource」的实现。组件是挂在实体上的行为单元，通过 inst.components.nonslipgritsource 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local NonSlipGritSource = Class(function(self, inst)
    self.inst = inst

    --self.ondeltafn = nil

    MakeComponentAnInventoryItemSource(self)
end)

function NonSlipGritSource:OnRemoveFromEntity()
    RemoveComponentInventoryItemSource(self)
end

function NonSlipGritSource:OnItemSourceRemoved(owner)
    local nonslipgrituser = owner.components.nonslipgrituser
    if nonslipgrituser then
        nonslipgrituser:RemoveSource(self.inst)
    end
end

function NonSlipGritSource:OnItemSourceNewOwner(owner)
    if owner.components.slipperyfeet then
        local nonslipgrituser = owner.components.nonslipgrituser or owner:AddComponent("nonslipgrituser")
        nonslipgrituser:AddSource(self.inst)
    end
end

function NonSlipGritSource:SetOnDeltaFn(fn)
    self.ondeltafn = fn
end

function NonSlipGritSource:DoDelta(dt)
    if self.ondeltafn then
        self.ondeltafn(self.inst, dt)
    end
end

return NonSlipGritSource
