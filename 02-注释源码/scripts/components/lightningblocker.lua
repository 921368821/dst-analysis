--============================================================
-- 文件：components/lightningblocker.lua
-- 模块：组件 / lightningblocker
-- 职责：组件「lightningblocker」的实现。组件是挂在实体上的行为单元，通过 inst.components.lightningblocker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local EPSILON = 0.001 -- The smallest acceptable range value, basically.
local function onblock_rsq(self, newrsq)
    if newrsq ~= nil and newrsq > EPSILON then
        self.inst:AddTag("lightningblocker")
    else
        self.inst:RemoveTag("lightningblocker")
    end
end

local LightningBlocker = Class(function(self, inst)
    self.inst = inst

    self.block_rsq = 0
    --self.on_strike = nil
end,
nil,
{
    block_rsq = onblock_rsq
})

function LightningBlocker:OnRemoveFromEntity()
    self.inst:RemoveTag("lightningblocker")
end

function LightningBlocker:SetBlockRange(newrange)
    self.block_rsq = (newrange ~= nil and newrange * newrange) or nil
end

function LightningBlocker:SetOnLightningStrike(fn)
    self.on_strike = fn
end

function LightningBlocker:DoLightningStrike(pos)
    if self.on_strike ~= nil then
        self.on_strike(self.inst, pos)
    end
end

return LightningBlocker