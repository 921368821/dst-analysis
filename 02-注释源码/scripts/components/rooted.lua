--============================================================
-- 文件：components/rooted.lua
-- 模块：组件 / rooted
-- 职责：组件「rooted」的实现。组件是挂在实体上的行为单元，通过 inst.components.rooted 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Rooted = Class(function(self, inst)
	self.inst = inst
	self.sources = {}

	inst:AddTag("rooted")

	if inst.Physics ~= nil then
		inst.Physics:Stop()

		--Generally, don't call SetTempMass0 outside of here.
		--A prefab's own internal logic should just manage Physics:SetMass.
		--Otherwise, just add and use the "rooted" component where needed.
		inst.Physics:SetTempMass0(true)
	end
	if inst.components.locomotor ~= nil then
		inst.components.locomotor:SetExternalSpeedMultiplier(inst, "rooted", 0)
	end

	self._onremovesource = function(src)
		self.sources[src] = nil
		if next(self.sources) == nil then
			inst:RemoveComponent("rooted")
		end
	end

	inst:PushEvent("rooted")
end)

function Rooted:OnRemoveFromEntity()
	self.inst:RemoveTag("rooted")

	if self.inst.Physics ~= nil then
		--Generally, don't call SetTempMass0 outside of here.
		--A prefab's own internal logic should just manage Physics:SetMass.
		--Otherwise, just add and use the "rooted" component where needed.
		self.inst.Physics:SetTempMass0(false)
	end
	if self.inst.components.locomotor ~= nil then
		self.inst.components.locomotor:RemoveExternalSpeedMultiplier(self.inst, "rooted")
	end

	for src in pairs(self.sources) do
		if src ~= self.inst then
			self.inst:RemoveEventCallback("onremove", self._onremovesource, src)
		end
	end

	self.inst:PushEvent("unrooted")
end

function Rooted:AddSource(src)
	if not self.sources[src] then
		self.sources[src] = true
		if src ~= self.inst then
			self.inst:ListenForEvent("onremove", self._onremovesource, src)
		end
	end
end

function Rooted:RemoveSource(src)
	if self.sources[src] then
		if src ~= self.inst then
			self.inst:RemoveEventCallback("onremove", self._onremovesource, src)
		end
		self._onremovesource(src)
	end
end

return Rooted
