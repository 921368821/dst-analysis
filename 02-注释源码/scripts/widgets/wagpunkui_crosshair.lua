--============================================================
-- 文件：widgets/wagpunkui_crosshair.lua
-- 模块：UI 控件 / wagpunkui_crosshair
-- 职责：控件「wagpunkui_crosshair」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local UIAnim = require "widgets/uianim"
--local Widget = require "widgets/widget"
--local Image = require "widgets/image"

local Wagpunkui_crosshair =  Class(UIAnim, function(self, owner)
    self.owner = owner
    UIAnim._ctor(self, "Wagpunkui_crosshair")

    self:SetClickable(false)

    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_MIDDLE)
    self:SetScaleMode(SCALEMODE_FIXEDPROPORTIONAL)

    self:GetAnimState():SetBank("wagstaff_armor_target")
    self:GetAnimState():SetBuild("wagstaff_armor_target")
    self:GetAnimState():PlayAnimation("distance_meter")
    self:GetAnimState():AnimateWhilePaused(false)

end)

return Wagpunkui_crosshair
