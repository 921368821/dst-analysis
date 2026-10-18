--============================================================
-- 文件：components/plantable.lua
-- 模块：组件 / plantable
-- 职责：组件「plantable」的实现。组件是挂在实体上的行为单元，通过 inst.components.plantable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Plantable = Class(function(self, inst)
    self.inst = inst
    self.growtime = 120
    self.product = nil
end)

return Plantable