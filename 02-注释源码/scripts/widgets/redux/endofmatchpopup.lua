--============================================================
-- 文件：widgets/redux/endofmatchpopup.lua
-- 模块：redux / endofmatchpopup
-- 职责：redux模块中的「endofmatchpopup」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Widget = require "widgets/widget"
local Text = require "widgets/text"
local TEMPLATES = require "widgets/redux/templates"

local EndOfMatchPopup = Class(Widget, function(self, owner, data)
    Widget._ctor(self, "EndOfMatchPopup")

    self.owner = owner

    self.proot = self:AddChild(Widget("ROOT"))
	self.proot:SetHAnchor(ANCHOR_MIDDLE)
	self.proot:SetVAnchor(ANCHOR_MIDDLE)
	self.proot:SetScaleMode(SCALEMODE_PROPORTIONAL)


	local t = self.proot:AddChild(Text(TITLEFONT, 50, data.title))
	t:SetHAlign(ANCHOR_MIDDLE)
	t:SetPosition(0, 155)
	t:SetColour(UICOLOURS.GOLD)

	local body = self.proot:AddChild(Text(CHATFONT_OUTLINE, 20, data.body))
	body:SetHAlign(ANCHOR_MIDDLE)
	body:SetPosition(0, 120)
	body:SetColour(UICOLOURS.EGGSHELL)
end)

return EndOfMatchPopup
