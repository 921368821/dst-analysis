--============================================================
-- 文件：components/upgrader.lua
-- 模块：组件 / upgrader
-- 职责：组件「upgrader」的实现。组件是挂在实体上的行为单元，通过 inst.components.upgrader 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function onupgradetype(self, newtype, oldtype)
	if oldtype then
		self.inst:RemoveTag(oldtype.."_upgrader")
	end
	if newtype then
		self.inst:AddTag(newtype.."_upgrader")
	end
end

local Upgrader = Class(function(self,inst)
	self.inst = inst

	self.upgradetype = UPGRADETYPES.DEFAULT
	self.upgradevalue = 1
end,
nil,
{
	upgradetype = onupgradetype,
})

function Upgrader:CanUpgrade(target, doer)
	if self.upgradetype ~= target.components.upgradeable.upgradetype then
		return false
	end
	if not doer:HasTag(self.upgradetype.."_upgradeuser") then
		return false
	end
	return true
end

return Upgrader