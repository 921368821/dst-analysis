--============================================================
-- 文件：components/brush.lua
-- 模块：组件 / brush
-- 职责：组件「brush」的实现。组件是挂在实体上的行为单元，通过 inst.components.brush 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Brush = Class(function(self, inst)
    self.inst = inst
end)

return Brush
