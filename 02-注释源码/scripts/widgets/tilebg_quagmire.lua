--============================================================
-- 文件：widgets/tilebg_quagmire.lua
-- 模块：UI 控件 / tilebg_quagmire
-- 职责：控件「tilebg_quagmire」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Widget = require "widgets/widget"
local Image = require "widgets/image"

local QuagmireTileBG = Class(Widget, function(self, atlas, tileim, sepim)
    Widget._ctor(self, "TileBG")

    self.atlas = atlas
    self.sepim = sepim

    self.seps = nil
end)

function QuagmireTileBG:SetNumTiles(numtiles)
    self:KillAllChildren()

    self.seps = {}
    if self.sepim and numtiles > 1 then
        for k = 1, numtiles-1 do
            self.seps[k] = self:AddChild(Image(self.atlas, self.sepim))
        end
    end
end

return QuagmireTileBG
