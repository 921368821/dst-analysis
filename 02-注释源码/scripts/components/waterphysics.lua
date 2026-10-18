--============================================================
-- 文件：components/waterphysics.lua
-- 模块：组件 / waterphysics
-- 职责：组件「waterphysics」的实现。组件是挂在实体上的行为单元，通过 inst.components.waterphysics 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local WaterPhysics = Class(function(self, inst)
    self.inst = inst

    self.restitution = 1
end)

return WaterPhysics
