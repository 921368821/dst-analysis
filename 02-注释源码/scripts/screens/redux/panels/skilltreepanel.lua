--============================================================
-- 文件：screens/redux/panels/skilltreepanel.lua
-- 模块：panels / skilltreepanel
-- 职责：panels模块中的「skilltreepanel」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local Widget = require "widgets/widget"
local SkillTreeWidget = require "widgets/redux/skilltreewidget"

local SkillTreePanel = Class(Widget, function(self, parent_screen)
    Widget._ctor(self, "SkillTreePanel")

    self.root = self:AddChild(Widget("ROOT"))

    self.root:SetPosition(0, -15)

	--TheCookbook:ClearFilters()

	self.book = self.root:AddChild(SkillTreeWidget(self))

    self.focus_forward = self.book
end)

return SkillTreePanel
