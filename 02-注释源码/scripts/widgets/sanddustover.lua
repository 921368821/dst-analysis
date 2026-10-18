--============================================================
-- 文件：widgets/sanddustover.lua
-- 模块：UI 控件 / sanddustover
-- 职责：控件「sanddustover」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local UIAnim = require "widgets/uianim"

local SandDustOver = Class(UIAnim, function(self, owner)
    self.owner = owner
    UIAnim._ctor(self)

    self:SetClickable(false)

    self:SetHAnchor(ANCHOR_MIDDLE)
    self:SetVAnchor(ANCHOR_MIDDLE)
    self:SetScaleMode(SCALEMODE_FIXEDSCREEN_NONDYNAMIC)

    self:GetAnimState():SetBank("sand_over")
    self:GetAnimState():SetBuild("sand_over")
    self:GetAnimState():PlayAnimation("dust_loop", true)
    self:GetAnimState():AnimateWhilePaused(false)
end)

return SandDustOver
