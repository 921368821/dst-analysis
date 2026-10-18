--============================================================
-- 文件：components/symbolswapdata.lua
-- 模块：组件 / symbolswapdata
-- 职责：组件「symbolswapdata」的实现。组件是挂在实体上的行为单元，通过 inst.components.symbolswapdata 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SymbolSwapData = Class(function(self, inst)
	self.inst = inst
end)

function SymbolSwapData:SetData(build, symbol, is_skinned)
	self.build = build
	self.symbol = symbol
	self.is_skinned = is_skinned
end

function SymbolSwapData:GetDebugString()
	return string.format("build:%s, symbol:%s, is_skinned:%s", self.build or "", self.symbol or "", self.is_skinned or "")
end

return SymbolSwapData
