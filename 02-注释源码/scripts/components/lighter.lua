--============================================================
-- 文件：components/lighter.lua
-- 模块：组件 / lighter
-- 职责：组件「lighter」的实现。组件是挂在实体上的行为单元，通过 inst.components.lighter 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Lighter = Class(function(self, inst)
    self.inst = inst

    --V2C: Recommended to explicitly add tag to prefab pristine state
    inst:AddTag("lighter")

    self.onlight = nil
end)

function Lighter:OnRemoveFromEntity()
    self.inst:RemoveTag("lighter")
end

function Lighter:SetOnLightFn(fn)
    self.onlight = fn
end

function Lighter:Light(target, doer)
    if target.components.burnable ~= nil and not ((target:HasTag("fueldepleted") and not target:HasTag("burnableignorefuel")) or target:HasTag("INLIMBO")) then
        target.components.burnable:Ignite(nil, self.inst, doer)
        if self.onlight ~= nil then
            self.onlight(self.inst, target)
        end
    end
    target:PushEvent("onlighterlight")
end

return Lighter
