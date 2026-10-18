--============================================================
-- 文件：components/shedder.lua
-- 模块：组件 / shedder
-- 职责：组件「shedder」的实现。组件是挂在实体上的行为单元，通过 inst.components.shedder 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Shedder = Class(function(self, inst)
    self.inst = inst
    self.shedItemPrefab = nil
    self.shedHeight = 6.5 -- this height is for Bearger
    self.shedTask = nil
end)

local function DoSingleShed(inst, self)
    self:DoSingleShed()
end

function Shedder:StartShedding(interval)
    if self.shedTask ~= nil then
        self.shedTask:Cancel()
    end
    self.shedTask = self.inst:DoPeriodicTask(interval or 60, DoSingleShed, nil, self)
end

function Shedder:StopShedding()
    if self.shedTask ~= nil then
        self.shedTask:Cancel()
        self.shedTask = nil
    end
end

function Shedder:DoSingleShed()
    local item = self.shedItemPrefab ~= nil and SpawnPrefab(self.shedItemPrefab) or nil
    if item ~= nil then
        local x, y, z = self.inst.Transform:GetWorldPosition()
        item.Transform:SetPosition(x + math.random() - .5, self.shedHeight, z + math.random() - .5)
    end
    return item
end

function Shedder:DoMultiShed(max, random)
    local num = random and math.random(max) or max
    local speed = 4
    for i = 1, num do
        local item = self:DoSingleShed()
        if item ~= nil and item.Physics ~= nil and item.Physics:IsActive() then
            local angle = math.random() * TWOPI
            item.Physics:SetVel(math.cos(angle) * speed, 0, math.sin(angle) * speed)
        end
    end
end

Shedder.OnRemoveFromEntity = Shedder.StopShedding

return Shedder
