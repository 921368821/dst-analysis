--============================================================
-- 文件：components/watersource.lua
-- 模块：组件 / watersource
-- 职责：组件「watersource」的实现。组件是挂在实体上的行为单元，通过 inst.components.watersource 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function onavailable(self, available)
    if available then
        if not self.inst:HasTag("watersource") then
            self.inst:AddTag("watersource")
        end
    else
        if self.inst:HasTag("watersource") then
            self.inst:RemoveTag("watersource")
        end
    end
end

local WaterSource = Class(function(self, inst)
    self.inst = inst

    self.available = true
    -- self.onusefn = nil

    -- This is used for fillable objects with override onfill behavior, like
    -- the wateringcan. If nil, presume it fills the item completely.
    -- self.override_fill_uses = nil
end, nil,
{
    available = onavailable,
})

function WaterSource:OnRemoveFromEntity()
    if self.inst:HasTag("watersource") then
        self.inst:RemoveTag("watersource")
    end
end

function WaterSource:Use()
    if self.onusefn ~= nil then
        self.onusefn(self.inst)
    end
end

return WaterSource
