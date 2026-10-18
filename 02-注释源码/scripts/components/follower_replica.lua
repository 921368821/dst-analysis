--============================================================
-- 文件：components/follower_replica.lua
-- 模块：组件 / follower_replica
-- 职责：组件「follower_replica」的实现。组件是挂在实体上的行为单元，通过 inst.components.follower_replica 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Follower = Class(function(self, inst)
    self.inst = inst

    self._leader = net_entity(inst.GUID, "follower._leader")
    self._itemowner = net_entity(inst.GUID, "follower._itemowner")
end)

function Follower:SetLeader(leader)
    self._leader:set(leader)
end

function Follower:SetItemOwner(owner)
    self._itemowner:set(owner)
end

function Follower:GetLeader()
    return self._itemowner:value() or self._leader:value()
end

return Follower