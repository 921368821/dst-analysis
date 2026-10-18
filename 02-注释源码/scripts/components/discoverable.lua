--============================================================
-- 文件：components/discoverable.lua
-- 模块：组件 / discoverable
-- 职责：组件「discoverable」的实现。组件是挂在实体上的行为单元，通过 inst.components.discoverable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Discoverable = Class(function(self, inst)
    self.inst = inst
    self.discovered = false

	self.undiscoveredIcon = nil
	self.discoveredIcon = nil

	inst:ListenForEvent( "onclick",
		function( globa, data )
			if not self.discovered then
				self:Discover()
			end
		end
	)
end)

function Discoverable:Discover()
	self.discovered = true

	self.inst.MiniMapEntity:SetIcon( self.discoveredIcon )
	--self.inst.MiniMapEntity:SetRenderOnTopOfMask( false )
end

function Discoverable:Hide()
	self.discovered = false

	self.inst.MiniMapEntity:SetIcon( self.undiscoveredIcon )
	--self.inst.MiniMapEntity:SetRenderOnTopOfMask( true )
end

function Discoverable:SetIcons(undiscovered, discovered)
	self.undiscoveredIcon = undiscovered
	self.discoveredIcon = discovered

	self:Hide()
end

function Discoverable:OnSave(data)
	local data = {}

	if self.discovered then
		data.discovered = true
	end

	return data
end

function Discoverable:OnLoad(data)
	if data.discovered then
		self:Discover()
	end
end

return Discoverable

