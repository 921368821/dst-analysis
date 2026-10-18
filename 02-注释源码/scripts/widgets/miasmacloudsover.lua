--============================================================
-- 文件：widgets/miasmacloudsover.lua
-- 模块：UI 控件 / miasmacloudsover
-- 职责：控件「miasmacloudsover」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local UIAnim = require("widgets/uianim")

local MiasmaCloudsOver = Class(UIAnim, function(self, owner)
	self.owner = owner
	UIAnim._ctor(self)

	self:SetClickable(false)

	self:SetHAnchor(ANCHOR_MIDDLE)
	self:SetVAnchor(ANCHOR_MIDDLE)
	self:SetScaleMode(SCALEMODE_FIXEDSCREEN_NONDYNAMIC)

	self:GetAnimState():SetBank("miasma_over")
	self:GetAnimState():SetBuild("miasma_over")
	self:GetAnimState():PlayAnimation("dust_loop", true)
	self:GetAnimState():AnimateWhilePaused(false)
end)

return MiasmaCloudsOver
