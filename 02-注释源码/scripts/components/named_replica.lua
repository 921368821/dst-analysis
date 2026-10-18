--============================================================
-- 文件：components/named_replica.lua
-- 模块：组件 / named_replica
-- 职责：组件「named_replica」的实现。组件是挂在实体上的行为单元，通过 inst.components.named_replica 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnNameDirty(inst)
    local name = inst.replica.named._name:value()
    inst.name = name ~= "" and name or STRINGS.NAMES[string.upper(inst.prefab)]
end

local function OnAuthorDirty(inst)
    local author = inst.replica.named._author_netid:value()
    inst.name_author_netid = author ~= "" and author or nil
end

local Named = Class(function(self, inst)
    self.inst = inst

    self._name = net_string(inst.GUID, "named._name", "namedirty")
    self._author_netid = net_string(inst.GUID, "named._author_netid", "authordirty")

    if not TheWorld.ismastersim then
        inst:ListenForEvent("namedirty", OnNameDirty)
        inst:ListenForEvent("authordirty", OnAuthorDirty)
    end
end)

function Named:SetName(name, author)
    if TheWorld.ismastersim then
        self._name:set(name)
		self._author_netid:set(author)
    end
end

return Named