--============================================================
-- 文件：widgets/statusdisplays_quagmire.lua
-- 模块：UI 控件 / statusdisplays_quagmire
-- 职责：控件「statusdisplays_quagmire」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Widget = require "widgets/widget"
local Badge = require "widgets/badge"
local HealthBadge = require "widgets/healthbadge"
local UIAnim = require "widgets/uianim"


local StatusDisplays = Class(Widget, function(self, owner)
    Widget._ctor(self, "Status")
    self.owner = owner

    self.modetask = nil
    self.isghostmode = false
    self.craft_hide = false
    self.visiblemode = false --force the initial UpdateMode call to be dirty
end)

function StatusDisplays:SetGhostMode(ghostmode)
end

function StatusDisplays:ToggleCrafting(hide)
end

function StatusDisplays:ShowStatusNumbers()
end

function StatusDisplays:HideStatusNumbers()
end

function StatusDisplays:GetResurrectButton()
    return nil
end

return StatusDisplays
