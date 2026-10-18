--============================================================
-- 文件：components/cookable.lua
-- 模块：组件 / cookable
-- 职责：组件「cookable」的实现。组件是挂在实体上的行为单元，通过 inst.components.cookable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Cookable = Class(function(self, inst)
    self.inst = inst
    self.product = nil
    self.oncooked = nil

    --V2C: Recommended to explicitly add tag to prefab pristine state
    inst:AddTag("cookable")
end)

function Cookable:OnRemoveFromEntity()
    self.inst:RemoveTag("cookable")
end

function Cookable:SetOnCookedFn(fn)
    self.oncooked = fn
end

function Cookable:Cook(cooker, chef)
    if self.oncooked ~= nil then
        self.oncooked(self.inst, cooker, chef)
    end
    if self.product ~= nil then
        local prod = SpawnPrefab(
            type(self.product) ~= "function" and
            self.product or
            self.product(self.inst, cooker, chef)
        )
        if prod ~= nil then
            if self.inst.components.perishable ~= nil and
                prod.components.perishable ~= nil and
                not self.inst:HasTag("smallcreature") then
                local new_percent = 1 - (1 - self.inst.components.perishable:GetPercent()) * .5
                prod.components.perishable:SetPercent(new_percent)
            end
            return prod
        end
    end
end

return Cookable
