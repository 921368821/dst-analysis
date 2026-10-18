--============================================================
-- 文件：components/teleportedoverride.lua
-- 模块：组件 / teleportedoverride
-- 职责：组件「teleportedoverride」的实现。组件是挂在实体上的行为单元，通过 inst.components.teleportedoverride 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================



local TeleportedOverride = Class(function(self, inst)
	self.inst = inst
end)

function TeleportedOverride:GetDestTarget()
	return self.target_fn ~= nil and self.target_fn(self.inst) or nil
end

function TeleportedOverride:SetDestTargetFn(fn)
	self.target_fn = fn
end

function TeleportedOverride:GetDestPosition()
	return self.pos_fn ~= nil and self.pos_fn(self.inst) or nil
end

function TeleportedOverride:SetDestPositionFn(fn)
	self.pos_fn = fn
end


return TeleportedOverride