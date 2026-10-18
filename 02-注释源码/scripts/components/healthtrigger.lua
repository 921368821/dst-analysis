--============================================================
-- 文件：components/healthtrigger.lua
-- 模块：组件 / healthtrigger
-- 职责：组件「healthtrigger」的实现。组件是挂在实体上的行为单元，通过 inst.components.healthtrigger 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnHealthDelta(inst, data)
    inst.components.healthtrigger:OnHealthDelta(data)
end

local HealthTrigger = Class(function(self, inst)
    self.inst = inst

    self.triggers = {}

    self.inst:ListenForEvent("healthdelta", OnHealthDelta)
end)

function HealthTrigger:OnRemoveFromEntity()
    self.inst:RemoveEventCallback("healthdelta", OnHealthDelta)
end

function HealthTrigger:AddTrigger(amount, fn)
    self.triggers[amount] = fn
end

local function descending(a, b)
    return a > b
end

function HealthTrigger:OnHealthDelta(data)
    local totrigger = {}
    for k, v in pairs(self.triggers) do
        if (data.oldpercent > k and data.newpercent <= k) or
            (data.oldpercent < k and data.newpercent >= k) then
            table.insert(totrigger, k)
        end
    end
    if #totrigger > 0 then
        table.sort(totrigger, data.oldpercent > data.newpercent and descending or nil)
        for i, v in ipairs(totrigger) do
            self.triggers[v](self.inst)
        end
    end
end

return HealthTrigger
