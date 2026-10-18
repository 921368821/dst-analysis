--============================================================
-- 文件：components/forcecompostable.lua
-- 模块：组件 / forcecompostable
-- 职责：组件「forcecompostable」的实现。组件是挂在实体上的行为单元，通过 inst.components.forcecompostable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ForceCompostable = Class(function(self, inst)
    self.inst = inst
    self.green = false
    self.brown = false
end)

return ForceCompostable