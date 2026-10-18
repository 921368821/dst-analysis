--============================================================
-- 文件：components/slingshotmodder.lua
-- 模块：组件 / slingshotmodder
-- 职责：组件「slingshotmodder」的实现。组件是挂在实体上的行为单元，通过 inst.components.slingshotmodder 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SlingshotModder = Class(function(self, inst)
	self.inst = inst
end)

function SlingshotModder:StartModding(target, user)
	if target.components.linkeditem and target.components.linkeditem:IsEquippableRestrictedToOwner() then
		local owneruserid = target.components.linkeditem:GetOwnerUserID()
		if owneruserid and (user and user.userid) ~= owneruserid then
			return false, "NOT_MINE"
		end
	end
	return target.components.slingshotmods and target.components.slingshotmods:Open(user) or false
end

function SlingshotModder:StopModding(target, user)
	return target.components.slingshotmods and target.components.slingshotmods:Close(user) or false
end

return SlingshotModder
