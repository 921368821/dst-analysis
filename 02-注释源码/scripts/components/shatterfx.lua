--============================================================
-- 文件：components/shatterfx.lua
-- 模块：组件 / shatterfx
-- 职责：组件「shatterfx」的实现。组件是挂在实体上的行为单元，通过 inst.components.shatterfx 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ShatterFX = Class(function(self, inst)
    self.inst = inst
    self.level = nil
    self.levels = {}
end)

function ShatterFX:SetLevel(level)
    level = math.min(level, #self.levels)
    if level ~= self.level and self.levels[level] then
        if not self.level and self.levels[level].pre then
            self.inst.AnimState:PlayAnimation(self.levels[level].pre)
            self.inst.AnimState:PushAnimation(self.levels[level].anim, true)
        else
            self.inst.AnimState:PlayAnimation(self.levels[level].anim, true)
        end
        self.level = level
    end
end

return ShatterFX