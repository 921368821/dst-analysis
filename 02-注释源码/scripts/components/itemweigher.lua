--============================================================
-- 文件：components/itemweigher.lua
-- 模块：组件 / itemweigher
-- 职责：组件「itemweigher」的实现。组件是挂在实体上的行为单元，通过 inst.components.itemweigher 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function ontype(self, type, old_type)
	if old_type ~= nil then
		self.inst:RemoveTag("trophyscale_"..old_type)
	end
	if type ~= nil then
		self.inst:AddTag("trophyscale_"..type)
	end
end

local ItemWeigher = Class(function(self, inst)
    self.inst = inst

	self.type = nil

	--self.ondoweighinfn = nil
end,
nil,
{
	type = ontype
})

function ItemWeigher:OnRemoveFromEntity()
	type = nil -- to remove the tag
end

function ItemWeigher:SetOnDoWeighInFn(fn)
	self.ondoweighinfn = fn
end

function ItemWeigher:DoWeighIn(target, doer)
	return self.ondoweighinfn ~= nil and self.ondoweighinfn(self.inst, target, doer) or nil
end

return ItemWeigher