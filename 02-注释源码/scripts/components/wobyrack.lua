--============================================================
-- 文件：components/wobyrack.lua
-- 模块：组件 / wobyrack
-- 职责：组件「wobyrack」的实现。组件是挂在实体上的行为单元，通过 inst.components.wobyrack 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local DryingRack = require("components/dryingrack")

local WobyRack = Class(DryingRack, function(self, inst)
	local container = SpawnPrefab("woby_rack_container").components.container
	container.inst.entity:SetParent(inst.entity)

	DryingRack._ctor(self, inst, container)
end)

function WobyRack:_dbg_print(...)
	--print("WobyRack:", ...)
end

return WobyRack
