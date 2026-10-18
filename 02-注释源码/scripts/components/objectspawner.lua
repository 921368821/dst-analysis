--============================================================
-- 文件：components/objectspawner.lua
-- 模块：组件 / objectspawner
-- 职责：组件「objectspawner」的实现。组件是挂在实体上的行为单元，通过 inst.components.objectspawner 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ObjectSpawner = Class(function(self, inst)
    self.inst = inst
    self.objects = {}
    self.onnewobjectfn = nil
end)

function ObjectSpawner:OnSave()
    local objects = {}
    local references = {}
    for i, v in ipairs(self.objects) do
        table.insert(objects, v.GUID)
        table.insert(references, v.GUID)
    end
    if #objects > 0 then
        return { objects = objects }, references
    end
end

function ObjectSpawner:LoadPostPass(newents, data)
    if data.objects ~= nil then
        for i, v in ipairs(data.objects) do
            local child = newents[v]
            if child ~= nil then
                self:TakeOwnership(child.entity)
            end
        end
    end
end

function ObjectSpawner:TakeOwnership(obj)
    table.insert(self.objects, obj)
    if self.onnewobjectfn ~= nil then
        self.onnewobjectfn(self.inst, obj)
    end
end

function ObjectSpawner:SpawnObject(obj, linked_skinname, skin_id)
    obj = SpawnPrefab(obj, linked_skinname, skin_id)
    self:TakeOwnership(obj)
    return obj
end

return ObjectSpawner
