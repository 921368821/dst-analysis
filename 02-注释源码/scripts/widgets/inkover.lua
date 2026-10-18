--============================================================
-- 文件：widgets/inkover.lua
-- 模块：UI 控件 / inkover
-- 职责：控件「inkover」的实现：布局、渲染、输入响应与鼠标交互。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local InkOver_splat = require "widgets/inkover_splat"
local Widget = require "widgets/widget"


local InkOver =  Class(Widget, function(self, owner)
    self.owner = owner
    Widget._ctor(self, "InkOver")

    self.InkOver = self:AddChild(InkOver_splat(owner))
    self.InkOver2 = self:AddChild(InkOver_splat(owner))

    local function _Flash() self:Flash() end

    self.inst:ListenForEvent("inked", _Flash, owner)
end)

function InkOver:Flash()

    TheFrontEnd:GetSound():PlaySound("hookline/creatures/squid/ink")

    local time1 = GetTime() - self.InkOver.time
    local time2 = GetTime() - self.InkOver2.time
    if time1 > 2 then
        time1 = nil
    end
    if time2 > 2 then
        time2 = nil
    end

    if time1 and time2 then
        if time1 < time2 then
            self.InkOver2:Flash("ink2")
        else
            self.InkOver:Flash("ink")
        end
    else
        if time1 then
            self.InkOver2:Flash("ink2")
        elseif time2 then
            self.InkOver:Flash("ink")
        else
            if math.random() < 0.5 then
                self.InkOver:Flash("ink")
            else
                self.InkOver2:Flash("ink2")
            end
        end
    end
end

return InkOver
