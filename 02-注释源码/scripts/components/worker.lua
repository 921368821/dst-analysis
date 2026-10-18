--============================================================
-- 文件：components/worker.lua
-- 模块：组件 / worker
-- 职责：组件「worker」的实现。组件是挂在实体上的行为单元，通过 inst.components.worker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Worker = Class(function(self, inst)
    self.inst = inst
    self.actions = {}
end)

function Worker:GetEffectiveness(action)
    return self.actions[action] or 0
end

function Worker:SetAction(action, effectiveness)
    self.actions[action] = effectiveness or 1
end

function Worker:CanDoAction(action)
    return self.actions[action] ~= nil
end

return Worker
