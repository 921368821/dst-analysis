--============================================================
-- 文件：components/strongman.lua
-- 模块：组件 / strongman
-- 职责：组件「strongman」的实现。组件是挂在实体上的行为单元，通过 inst.components.strongman 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Strongman = Class(function(self, inst)
    self.inst = inst
end)


function Strongman:DoWorkout(gym)
    self.gym = gym
    self.inst.components.mightiness:Pause()
    self.inst:AddTag("ingym")
end

function Strongman:StopWorkout()
    self.inst:RemoveTag("ingym")
    self.inst.components.mightiness:Resume()
    self.gym = nil
end

return Strongman