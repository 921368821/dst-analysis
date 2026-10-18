--============================================================
-- 文件：components/summoningitem.lua
-- 模块：组件 / summoningitem
-- 职责：组件「summoningitem」的实现。组件是挂在实体上的行为单元，通过 inst.components.summoningitem 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local SummoningItem = Class(function(self, inst)
    self.inst = inst
end)

return SummoningItem
