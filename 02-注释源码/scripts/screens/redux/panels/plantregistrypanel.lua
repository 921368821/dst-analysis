--============================================================
-- 文件：screens/redux/panels/plantregistrypanel.lua
-- 模块：panels / plantregistrypanel
-- 职责：panels模块中的「plantregistrypanel」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local Widget = require "widgets/widget"
local PlantRegistryWidget = require "widgets/redux/plantregistrywidget"

local PlantRegistryPanel = Class(Widget, function(self, parent_screen)
    Widget._ctor(self, "PlantRegistryPanel")

    self.root = self:AddChild(Widget("ROOT"))

    self.root:SetPosition(0, -15)

	ThePlantRegistry:ClearFilters()

	self.plantregistry = self.root:AddChild(PlantRegistryWidget(self))

    self.focus_forward = self.plantregistry
end)

return PlantRegistryPanel
