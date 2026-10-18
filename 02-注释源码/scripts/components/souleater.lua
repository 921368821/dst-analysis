--============================================================
-- 文件：components/souleater.lua
-- 模块：组件 / souleater
-- 职责：组件「souleater」的实现。组件是挂在实体上的行为单元，通过 inst.components.souleater 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SoulEater = Class(function(self, inst)
    self.inst = inst

    self.oneatsoulfn = nil

    --V2C: Recommended to explicitly add tag to prefab pristine state
    inst:AddTag("souleater")
end)

function SoulEater:SetOnEatSoulFn(fn)
    self.oneatsoulfn = fn
end

function SoulEater:EatSoul(soul)
    if soul.components.soul == nil then
        return false
    elseif soul.components.stackable ~= nil then
        soul = soul.components.stackable:Get()
    end

    self.inst:PushEvent("oneatsoul", { soul = soul })
    if self.oneatsoulfn ~= nil then
        self.oneatsoulfn(self.inst, soul)
    end

    if soul:IsValid() then --might get removed in OnEatSoul
        soul:Remove()
    end
    return true
end

return SoulEater
