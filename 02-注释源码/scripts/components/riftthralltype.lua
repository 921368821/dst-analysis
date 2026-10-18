--============================================================
-- 文件：components/riftthralltype.lua
-- 模块：组件 / riftthralltype
-- 职责：组件「riftthralltype」的实现。组件是挂在实体上的行为单元，通过 inst.components.riftthralltype 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local RiftThrallType = Class(function(self, inst)
    self.inst = inst

    --self.thrall_type = nil
end)

function RiftThrallType:SetThrallType(new_type)
    self.thrall_type = new_type
end

function RiftThrallType:GetThrallType()
    return self.thrall_type
end

function RiftThrallType:IsThrallType(check_type)
    return self.thrall_type == check_type
end

function RiftThrallType:OnSave()
    return self.thrall_type and
    {
        thrall_type = self.thrall_type
    }
    or nil
end

function RiftThrallType:OnLoad(data)
    if data and data.thrall_type then
        self.thrall_type = data.thrall_type
    end
end

function RiftThrallType:GetDebugString()
    return self.thrall_type or "NONE"
end

return RiftThrallType