--============================================================
-- 文件：widgets/redux/shadowedtext.lua
-- 模块：redux / shadowedtext
-- 职责：redux模块中的「shadowedtext」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "constants"

local Text = require("widgets/text")
local Widget = require("widgets/widget")

local ShadowedText = Class(Widget, function(self, font, size, text, colour)
    Widget._ctor(self, "ShadowedText")

    -- Shadow must come first to be behind!
    local shadow_colour = {.1,.1,.1,1}
    self.shadow = self:AddChild(Text(font, size, text, shadow_colour))
    self.shadow:SetPosition(2,-2,0)

    self.text = self:AddChild(Text(font, size, text, colour))
    self.text:SetPosition(0,0,0)
end)

function ShadowedText:SetColour(r, g, b, a)
    self.text:SetColour(r, g, b, a)
    self.shadow:SetColour(.1,.1,.1, a)
end

-- Copy existing unimplemented Text interface
for name,func in pairs(Text) do
    if type(func) == 'function' and ShadowedText[name] == nil then
        ShadowedText[name] = function(self, ...)
            func(self.text, ...)
            func(self.shadow, ...)
        end
    end
end

return ShadowedText
