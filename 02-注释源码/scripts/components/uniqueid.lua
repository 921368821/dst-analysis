--============================================================
-- 文件：components/uniqueid.lua
-- 模块：组件 / uniqueid
-- 职责：组件「uniqueid」的实现。组件是挂在实体上的行为单元，通过 inst.components.uniqueid 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local function TryGetNewId(inst)
    local self = inst.components.uniqueid
    if self.id == nil then
        self.id = TheWorld.components.uniqueprefabids:GetNextID(inst.prefab)
        return
    end
    -- else we must have loaded with an ID!
end

local UniqueID = Class(function(self, inst)
    self.inst = inst

    self.id = nil

    self.task = self.inst:DoTaskInTime(0, TryGetNewId)
end)

function UniqueID:OnSave()
    return {
        id = self.id,
    }
end

function UniqueID:OnLoad(data)
    self.id = data.id -- even if it's nil!
    if self.id ~= nil then
        self.task:Cancel()
    end
end

function UniqueID:GetDebugString()
    return tostring(self.id)
end

return UniqueID
