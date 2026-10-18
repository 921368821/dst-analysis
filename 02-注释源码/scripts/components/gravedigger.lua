--============================================================
-- 文件：components/gravedigger.lua
-- 模块：组件 / gravedigger
-- 职责：组件「gravedigger」的实现。组件是挂在实体上的行为单元，通过 inst.components.gravedigger 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local GraveDigger = Class(function(self, inst)
    self.inst = inst

    -- self.onused = nil
end)

function GraveDigger:OnUsed(user, target)
    if self.onused then
        self.onused(self.inst, user, target)
    end
end

return GraveDigger