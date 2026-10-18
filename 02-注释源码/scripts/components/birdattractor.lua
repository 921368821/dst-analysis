--============================================================
-- 文件：components/birdattractor.lua
-- 模块：组件 / birdattractor
-- 职责：组件「birdattractor」的实现。组件是挂在实体上的行为单元，通过 inst.components.birdattractor 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require "util/sourcemodifierlist"

local BirdAttractor = Class(function(self, inst)
    self.inst = inst

    -- This modifier is using multple keys, always call CalculateModifierFromKey() with "maxbirds", "mindelay" or "maxdelay"
    self.spawnmodifier = SourceModifierList(inst, 0, SourceModifierList.additive)
end)

function BirdAttractor:GetDebugString()
    local str = string.format("maxbirds:%d, mindelay:%d, maxdelay:%d", self.spawnmodifier:CalculateModifierFromKey("maxbirds"), self.spawnmodifier:CalculateModifierFromKey("mindelay"), self.spawnmodifier:CalculateModifierFromKey("maxdelay"))
    return str
end

return BirdAttractor
