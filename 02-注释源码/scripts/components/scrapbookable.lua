--============================================================
-- 文件：components/scrapbookable.lua
-- 模块：组件 / scrapbookable
-- 职责：组件「scrapbookable」的实现。组件是挂在实体上的行为单元，通过 inst.components.scrapbookable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Scrapbookable = Class(function(self, inst)
    self.inst = inst
end)

function Scrapbookable:SetOnTeachFn(fn)
    self.onteach = fn
end

function Scrapbookable:Teach(doer)
    if self.onteach ~= nil then
        self.onteach(self.inst, doer)
    end

    return true
end

return Scrapbookable