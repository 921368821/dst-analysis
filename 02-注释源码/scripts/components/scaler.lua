--============================================================
-- 文件：components/scaler.lua
-- 模块：组件 / scaler
-- 职责：组件「scaler」的实现。组件是挂在实体上的行为单元，通过 inst.components.scaler 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--- Tracks the herd that the object belongs to, and creates one if missing
local Scaler = Class(function(self, inst)
    self.inst = inst
    self.scale = 1
end)

function Scaler:ApplyScale()
    self.inst.Transform:SetScale(self.scale,self.scale,self.scale)

    if self.OnApplyScale then
        self.OnApplyScale(self.inst, self.scale)
    end
end

function Scaler:OnSave()
    return
    {
        scale = self.scale
    }
end

function Scaler:OnLoad(data)
    if data and data.scale then
        self:SetScale(data.scale)
    end
end

function Scaler:SetScale(scale)
    self.scale = scale
    self:ApplyScale()
end

return Scaler