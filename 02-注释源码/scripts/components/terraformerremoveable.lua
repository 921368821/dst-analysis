--============================================================
-- 文件：components/terraformerremoveable.lua
-- 模块：组件 / terraformerremoveable
-- 职责：组件「terraformerremoveable」的实现。组件是挂在实体上的行为单元，通过 inst.components.terraformerremoveable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local TerraformerRemoveable = Class(function(self, inst)
    self.inst = inst

    -- Recommended to explicitly add tag to prefab pristine state
    self.inst:AddTag("terraformerremoveable")
end)

function TerraformerRemoveable:OnRemoveFromEntity()
    self.inst:RemoveTag("terraformerremoveable")
end

function TerraformerRemoveable:SetOnRemovedFn(fn)
    self.onremovedfn = fn
end

function TerraformerRemoveable:TryToRemove(doer)
    if self.onremovedfn then
        self.onremovedfn(self.inst, doer)
    end

    return true
end

return TerraformerRemoveable
