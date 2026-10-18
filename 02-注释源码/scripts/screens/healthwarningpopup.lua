--============================================================
-- 文件：screens/healthwarningpopup.lua
-- 模块：界面 / healthwarningpopup
-- 职责：界面「healthwarningpopup」。一个全屏场景的 UI，含打开/关闭流程、控件组装与动画。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Screen = require "widgets/screen"
local Button = require "widgets/button"
local ImageButton = require "widgets/imagebutton"

local HealthWarningPopup = Class(Screen, function(self)
	Screen._ctor(self, "HealthWarningPopup")

    self.bg = self:AddChild(ImageButton("images/rail.xml", "health_warning.tex"))
    self.bg.image:SetVRegPoint(ANCHOR_MIDDLE)
    self.bg.image:SetHRegPoint(ANCHOR_MIDDLE)
    self.bg.image:SetVAnchor(ANCHOR_MIDDLE)
    self.bg.image:SetHAnchor(ANCHOR_MIDDLE)
    self.bg.image:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.bg:SetOnClick(function() --[[ eat the click ]] end)

	self.inst:DoTaskInTime(7.75, function()
		TheFrontEnd:Fade(FADE_OUT, SCREEN_FADE_TIME, function()
			TheFrontEnd:PopScreen()
			TheFrontEnd:Fade(FADE_IN, SCREEN_FADE_TIME)
		end)
	end)
end)

return HealthWarningPopup