--============================================================
-- 文件：components/playerlightningtarget.lua
-- 模块：组件 / playerlightningtarget
-- 职责：组件「playerlightningtarget」的实现。组件是挂在实体上的行为单元，通过 inst.components.playerlightningtarget 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local DefaultOnStrike = function(inst)
    if inst.components.health ~= nil and not (inst.components.health:IsDead() or inst.components.health:IsInvincible()) then
        if not inst.components.inventory:IsInsulated() then
            LightningStrikeAttack(inst)
        else
            inst:PushEvent("lightningdamageavoided")
        end
    end
end

local PlayerLightningTarget = Class(function(self, inst)
    self.inst = inst
    self.hitchance = TUNING.PLAYER_LIGHTNING_TARGET_CHANCE
    self.onstrikefn = DefaultOnStrike

    self.hitchancemodifiers = SourceModifierList(self.inst)
end)

function PlayerLightningTarget:SetHitChance(chance)
    self.hitchance = chance
end

function PlayerLightningTarget:GetHitChance()
    return self.hitchance * self.hitchancemodifiers:Get()
end

function PlayerLightningTarget:SetOnStrikeFn(fn)
    self.onstrikefn = fn
end

function PlayerLightningTarget:DoStrike()
    if self.onstrikefn ~= nil then
        self.onstrikefn(self.inst)
    end
	self.inst:PushEvent("playerlightningtargeted")
end

return PlayerLightningTarget