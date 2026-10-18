--============================================================
-- 文件：components/savedscale.lua
-- 模块：组件 / savedscale
-- 职责：组件「savedscale」的实现。组件是挂在实体上的行为单元，通过 inst.components.savedscale 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SavedScale = Class(function(self, inst)
    self.inst = inst
end)

function SavedScale:OnSave()
    local sx, sy, sz = self.inst.Transform:GetScale()
    local data =
    {
        x = sx ~= 1 and sx or nil,
        y = sy ~= sx and sy or nil,
        z = sz ~= sx and sz or nil,
    }
    return next(data) ~= nil and data or nil
end

function SavedScale:OnLoad(data)
    local scale = data.x or 1
    self.inst.Transform:SetScale(scale, data.y or scale, data.z or scale)
end

return SavedScale
