--============================================================
-- 文件：components/bathbomb.lua
-- 模块：组件 / bathbomb
-- 职责：组件「bathbomb」的实现。组件是挂在实体上的行为单元，通过 inst.components.bathbomb 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BathBomb = Class(function(self, inst)
    self.inst = inst

    self.inst:AddTag("bathbomb")
end)

function BathBomb:OnRemoveFromEntity()
    self.inst:RemoveTag("bathbomb")
end

return BathBomb
