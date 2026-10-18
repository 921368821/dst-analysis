--============================================================
-- 文件：components/portablestructure.lua
-- 模块：组件 / portablestructure
-- 职责：组件「portablestructure」的实现。组件是挂在实体上的行为单元，通过 inst.components.portablestructure 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local PortableStructure = Class(function(self, inst)
    self.inst = inst
    self.ondismantlefn = nil
end)

function PortableStructure:SetOnDismantleFn(fn)
    self.ondismantlefn = fn
end

function PortableStructure:Dismantle(doer)
    if self.ondismantlefn ~= nil then
        self.ondismantlefn(self.inst, doer)
    end
end

return PortableStructure
