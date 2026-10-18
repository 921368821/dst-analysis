--============================================================
-- 文件：widgets/wagpunkui_overlay.lua
-- 模块：UI 控件 / wagpunkui_overlay
-- 职责：控件「wagpunkui_overlay」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local UIAnim = require "widgets/uianim"
--local Widget = require "widgets/widget"
--local Image = require "widgets/image"

local Wagpunkui_overlay =  Class(UIAnim, function(self, owner)
    self.owner = owner
    UIAnim._ctor(self, "Wagpunkui_overlay")

    self:SetClickable(false)

    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_MIDDLE)
    self:SetScaleMode(SCALEMODE_FIXEDSCREEN_NONDYNAMIC)

    self:GetAnimState():SetBank("wagpunk_over")
    self:GetAnimState():SetBuild("wagpunk_over")
    self:GetAnimState():PlayAnimation("over")
    self:GetAnimState():AnimateWhilePaused(false)

end)

return Wagpunkui_overlay
