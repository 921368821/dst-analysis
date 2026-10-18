--============================================================
-- 文件：components/repellent.lua
-- 模块：组件 / repellent
-- 职责：组件「repellent」的实现。组件是挂在实体上的行为单元，通过 inst.components.repellent 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Repellent = Class(function(self, inst)
    self.inst = inst

	self.onlyfollowers = false
    self.repel_tags = {}
    self.ignore_tags = { "FX", "NOCLICK", "DECOR", "INLIMBO" }
end)

local function AddTagToTable(tag_table, tag)
	for i,v in ipairs(tag_table) do
		if v == tag then
			return
		end
	end

	table.insert(tag_table, tag)
end

local function RemoveTagFromTable(tag_table, tag)
	local index = -1

	for i,v in ipairs(tag_table) do
		if v == tag then
			index = i
			break
		end
	end

	if index ~= -1 then
		table.remove(tag_table, index)
	end
end

function Repellent:ValidateTargetTags(target)
	for _, tag in ipairs(self.repel_tags) do
		if not target:HasTag(tag) then
			return false
		end
	end

	-- for _, tag in ipairs(self.ignore_tags) do
	-- 	if target:HasTag(tag) then
	-- 		return false
	-- 	end
	-- end

	return true
end

function Repellent:AddRepelTag(tag)
	AddTagToTable(self.repel_tags, tag)
end

function Repellent:RemoveRepelTag(tag)
	RemoveTagFromTable(self.repel_tags, tag)
end

function Repellent:AddIgnoreTag(tag)
	AddTagToTable(self.ignore_tags, tag)
end

function Repellent:RemoveIgnoreTag(tag)
	RemoveTagFromTable(self.ignore_tags, tag)
end

function Repellent:SetRadius(radius)
	self.radius = radius
end

function Repellent:SetUseAmount(amount)
	self.use_amount = amount
end

function Repellent:SetOnRepelFollowerFn(fn)
	self.onrepelfollowerfn = fn
end

function Repellent:SetOnlyRepelsFollowers(enabled)
	self.onlyfollowers = enabled
end

function Repellent:Repel(doer)
    for follower, v in pairs(doer.components.leader.followers) do
        if self:ValidateTargetTags(follower) then
            follower.components.follower:StopFollowing()
			if self.onrepelfollowerfn ~= nil then
				self.onrepelfollowerfn(self.inst, follower)
			end
        end
    end

	if not self.onlyfollowers then
		local x, y, z = self.inst.Transform:GetWorldPosition()
		local ents = TheSim:FindEntities(x, y, z, self.radius or 1, self.repel_tags, self.ignore_tags)

		for k,v in pairs(ents) do
			if v.components.combat and v.components.combat:HasTarget() then
				v.components.combat:DropTarget()
			end
		end
	end

    if self.inst.components.finiteuses then
    	self.inst.components.finiteuses:Use(self.use_amount or 1)
    end
end

return Repellent