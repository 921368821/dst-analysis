--============================================================
-- 文件：widgets/wagpunkui_distmeter.lua
-- 模块：UI 控件 / wagpunkui_distmeter
-- 职责：控件「wagpunkui_distmeter」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local UIAnim = require "widgets/uianim"
--local Widget = require "widgets/widget"
--local Image = require "widgets/image"

local Wagpunkui_distancemeter =  Class(UIAnim, function(self, owner)
    self.owner = owner
    UIAnim._ctor(self, "Wagpunkui_distmeter")

    self:SetClickable(false)

    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_MIDDLE)
    self:SetScaleMode(SCALEMODE_FIXEDPROPORTIONAL)

    self:GetAnimState():SetBank("wagstaff_armor_target")
    self:GetAnimState():SetBuild("wagstaff_armor_target")
    self:GetAnimState():PlayAnimation("distance_meter")
    self:GetAnimState():AnimateWhilePaused(false)

end)

return Wagpunkui_distancemeter
