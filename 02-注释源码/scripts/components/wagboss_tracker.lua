--============================================================
-- 文件：components/wagboss_tracker.lua
-- 模块：组件 / wagboss_tracker
-- 职责：组件「wagboss_tracker」的实现。组件是挂在实体上的行为单元，通过 inst.components.wagboss_tracker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

return Class(function(self, inst)
self.inst = inst

local _world = TheWorld
self.wagboss_defeated = false

self.OnWagbossDefeated = function()
    self.wagboss_defeated = true
    _world:PushEvent("master_wagbossinfoupdate", {isdefeated = self.wagboss_defeated})
end

function self:IsWagbossDefeated()
    return self.wagboss_defeated
end

function self:OnSave()
    return {
        wagboss_defeated = self.wagboss_defeated,
    }
end

function self:OnLoad(data)
    if data then
        self.wagboss_defeated = data.wagboss_defeated
        _world:PushEvent("master_wagbossinfoupdate", {isdefeated = self.wagboss_defeated})
    end
end

inst:ListenForEvent("wagboss_defeated", self.OnWagbossDefeated)

end)