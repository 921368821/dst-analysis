--============================================================
-- 文件：components/key.lua
-- 模块：组件 / key
-- 职责：组件「key」的实现。组件是挂在实体上的行为单元，通过 inst.components.key 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function onkeytype(self, keytype, old_keytype)
    if old_keytype ~= nil then
        self.inst:RemoveTag(old_keytype.."_key")
    end
    if keytype ~= nil then
        self.inst:AddTag(keytype.."_key")
    end
end

local Key = Class(function(self, inst)
	self.inst = inst
    self.keytype = LOCKTYPE.DOOR
	self.onused = nil
	self.onremoved = nil
end,
nil,
{
    keytype = onkeytype,
})

function Key:OnRemoveFromEntity()
    if self.keytype ~= nil then
        self.inst:RemoveTag(self.keytype.."_key")
    end
end

function Key:SetOnUsedFn(fn)
	self.onused = fn
end

function Key:SetOnRemovedFn(fn)
	self.onremoved = fn
end

function Key:OnUsed(lock, doer)
	if self.onused then
		self.onused(self.inst, lock, doer)
	end
end

function Key:OnRemoved(lock, doer)
	if self.onremoved then
		self.onremoved(self.inst, lock, doer)
	end
end

return Key