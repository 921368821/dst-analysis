--============================================================
-- 文件：components/oceanthrowable.lua
-- 模块：组件 / oceanthrowable
-- 职责：组件「oceanthrowable」的实现。组件是挂在实体上的行为单元，通过 inst.components.oceanthrowable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local OceanThrowable = Class(function(self, inst)
    self.inst = inst

    --self.onaddprojectilefn = nil
end)

function OceanThrowable:SetOnAddProjectileFn(fn)
    self.onaddprojectilefn = fn
end

function OceanThrowable:AddProjectile()
    if self.inst.components.complexprojectile == nil then
        self.inst:AddComponent("complexprojectile")
    end

    if self.onaddprojectilefn ~= nil then
        self.onaddprojectilefn(self.inst)
    end
end

return OceanThrowable
