--============================================================
-- 文件：components/inkable.lua
-- 模块：组件 / inkable
-- 职责：组件「inkable」的实现。组件是挂在实体上的行为单元，通过 inst.components.inkable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Inkable = Class(function(self, inst)
    self.inst = inst
    self.inked = nil
    self.inktime = 0
end)

function Inkable:Ink()
	self.inktime = 2

	self.inked = true
	self.inst.player_classified.inked:push()
    --self.inst.SoundEmitter:PlaySound("hookline/creatures/squid/ink")
    self.inst:StartUpdatingComponent(self)
    self.inst:AddDebuff("squid_ink_player_fx", "squid_ink_player_fx")
end

function Inkable:OnUpdate(dt)
	self.inktime = self.inktime - dt
	if self.inktime <= 0 then
		--remove fx
		self.inked = nil
		self.inst:PushEvent("deinked")
		self.inst:RemoveDebuff("squid_ink_player_fx")
		self.inst:StopUpdatingComponent(self)
	end
end

function Inkable:TransferComponent(newinst)
    local newcomponent = newinst.components.inkable
    if self.inked then
    	newcomponent:Ink()
    	newcomponent.inktime = self.inktime
    end
end

return Inkable
