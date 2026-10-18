--============================================================
-- 文件：components/tradable.lua
-- 模块：组件 / tradable
-- 职责：组件「tradable」的实现。组件是挂在实体上的行为单元，通过 inst.components.tradable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Tradable = Class(function(self, inst)
    self.inst = inst
    self.goldvalue = 0

    --self.tradefor = nil -- this is an array
    --self.rocktribute = nil
end)

return Tradable