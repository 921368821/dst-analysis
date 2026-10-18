--============================================================
-- 文件：components/sittable.lua
-- 模块：组件 / sittable
-- 职责：组件「sittable」的实现。组件是挂在实体上的行为单元，通过 inst.components.sittable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function onoccupier(self, occupier)
	if occupier ~= nil then
		self.inst:RemoveTag("cansit")
	else
		self.inst:AddTag("cansit")
	end
end

local Sittable = Class(function(self, inst)
	self.inst = inst
	--self.occupier = nil

	self._onremoveoccupier = function() self:SetOccupier(nil) end

	inst:AddTag("cansit")
	inst:PushEvent("becomesittable")
end,
nil,
{
	occupier = onoccupier,
})

local function OnIgnite(inst)
	inst.components.sittable.occupier:PushEvent("sittableonfire", inst)
end

function Sittable:SetOccupier(occupier)
	if self.occupier ~= occupier then
		if self.occupier ~= nil then
			self.inst:RemoveEventCallback("onremove", self._onremoveoccupier, self.occupier)
			self.inst:RemoveEventCallback("onignite", OnIgnite)
		end
		self.occupier = occupier
		if occupier ~= nil then
			self.inst:ListenForEvent("onremove", self._onremoveoccupier, occupier)
			if self.inst.components.burnable ~= nil then
				self.inst:ListenForEvent("onignite", OnIgnite)
			end
			self.inst:PushEvent("becomeunsittable")
		else
			self.inst:PushEvent("becomesittable")
		end
	end
end

function Sittable:IsOccupied()
	return self.occupier ~= nil
end

function Sittable:IsOccupiedBy(occupier)
	return self.occupier == occupier and occupier ~= nil
end

function Sittable:EjectOccupier()
	if self.occupier then
		self.inst:PushEvent("becomeunsittable")
	end
end

function Sittable:OnRemoveFromEntity()
	if self.occupier ~= nil then
		self.inst:RemoveEventCallback("onremove", self._onremoveoccupier, self.occupier)
		self.inst:RemoveEventCallback("onignite", OnIgnite)
	end
	self.inst:RemoveTag("cansit")
	self.inst:PushEvent("becomeunsittable")
end

return Sittable
