--============================================================
-- 文件：components/klaussacklock.lua
-- 模块：组件 / klaussacklock
-- 职责：组件「klaussacklock」的实现。组件是挂在实体上的行为单元，通过 inst.components.klaussacklock 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local KlausSackLock = Class(function(self, inst)
    self.inst = inst

    self.onusekeyfn = nil

    --V2C: Recommended to explicitly add tag to prefab pristine state
    inst:AddTag("klaussacklock")
end)

function KlausSackLock:OnRemoveFromEntity()
    self.inst:RemoveTag("klaussacklock")
end

function KlausSackLock:SetOnUseKey(onusekeyfn)
    self.onusekeyfn = onusekeyfn
end

function KlausSackLock:UseKey(key, doer)
    if key == nil or not key:IsValid() or self.onusekeyfn == nil then
        return false
    end

    local success, fail_msg, consumed = self.onusekeyfn(self.inst, key, doer)
    if consumed then
        if key.components.stackable ~= nil then
            key.components.stackable:Get():Remove()
        else
            key:Remove()
        end
    end

    if success then
        return true
    end
    return false, fail_msg
end

return KlausSackLock
