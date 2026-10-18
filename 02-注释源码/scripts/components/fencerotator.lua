--============================================================
-- 文件：components/fencerotator.lua
-- 模块：组件 / fencerotator
-- 职责：组件「fencerotator」的实现。组件是挂在实体上的行为单元，通过 inst.components.fencerotator 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local FenceRotator = Class(function(self, inst)
    self.inst = inst
end)

function FenceRotator:Rotate(target, delta)
    if target == nil then
        return
    end

    local angle = target.Transform:GetRotation()
    if target.SetOrientation ~= nil then
        target.SetOrientation(target, angle + (delta or TUNING.FENCE_DEFAULT_ROTATION))
    else
        target.Transform:SetRotation(angle + (delta or TUNING.FENCE_DEFAULT_ROTATION))
    end

    self.inst:PushEvent("fencerotated")

    SpawnPrefab("fence_rotator_fx").Transform:SetPosition(target.Transform:GetWorldPosition())
end

return FenceRotator