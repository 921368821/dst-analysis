--============================================================
-- 文件：screens/redux/panels/cookbookpanel.lua
-- 模块：panels / cookbookpanel
-- 职责：panels模块中的「cookbookpanel」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local Widget = require "widgets/widget"
local CookbookWidget = require "widgets/redux/cookbookwidget"

local CookbookPanel = Class(Widget, function(self, parent_screen)
    Widget._ctor(self, "CookbookPanel")

    self.root = self:AddChild(Widget("ROOT"))

    self.root:SetPosition(0, -15)

	TheCookbook:ClearFilters()

	self.book = self.root:AddChild(CookbookWidget(self))

    self.focus_forward = self.book
end)

return CookbookPanel
