--============================================================
-- 文件：components/grabbable.lua
-- 模块：组件 / grabbable
-- 职责：组件「grabbable」的实现。组件是挂在实体上的行为单元，通过 inst.components.grabbable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

-- NOTES(JBK): This component is deprecated.
-- Use inventoryitem.grabbableoverridetag instead.


local Grabbable = Class(function(self, inst)
    self.inst = inst

    --V2C: Recommended to explicitly add tag to prefab pristine state
    self.inst:AddTag("grabbable")

    --self.cangrabfn = nil
end)

function Grabbable:OnRemoveFromEntity()
    self.inst:RemoveTag("grabbable")
end

function Grabbable:SetCanGrabFn(fn)
    self.cangrabfn = fn
end

function Grabbable:CanGrab(doer)
    if self.cangrabfn ~= nil then
        return self.cangrabfn(self.inst, doer)
    end

    return false
end

return Grabbable
