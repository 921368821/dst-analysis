--============================================================
-- 文件：components/worlddeciduoustreeupdater.lua
-- 模块：组件 / worlddeciduoustreeupdater
-- 职责：组件「worlddeciduoustreeupdater」的实现。组件是挂在实体上的行为单元，通过 inst.components.worlddeciduoustreeupdater 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


-- This file is deprecated but left here in case it is referenced by mods

local WorldDeciduousTreeUpdater = Class(function(self, inst)
    self.inst = inst
    self.update = function() end
end)

return WorldDeciduousTreeUpdater