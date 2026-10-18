--============================================================
-- 文件：components/deathloothandler.lua
-- 模块：组件 / deathloothandler
-- 职责：组件「deathloothandler」的实现。组件是挂在实体上的行为单元，通过 inst.components.deathloothandler 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

-- Just handle a value, doesn't actually drop the loot here.
-- OK this might become false ^ :)

local DeathLootHandler = Class(function(self, inst)
    self.inst = inst

    self.level = 0
    self.loot = {}
end)

function DeathLootHandler:StoreLoot(prefabs)
    for i, pref in ipairs(prefabs) do
        table.insert(self.loot, pref)
    end
end

function DeathLootHandler:GetLoot()
    return self.loot
end

function DeathLootHandler:SetLevel(num)
    self.level = num
end

function DeathLootHandler:GetLevel()
    return self.level
end

function DeathLootHandler:OnSave()
    return self.level > 0 and { level = self.level, loot = self.loot, add_component_if_missing = true } or nil
end

function DeathLootHandler:OnLoad(data)
    if data ~= nil then
        self.level = data.level or 0
        self.loot = data.loot or {}
    end
end

return DeathLootHandler