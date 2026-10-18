--============================================================
-- 文件：firelevel.lua
-- 模块： / firelevel
-- 职责：模块中的「firelevel」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


FireLevel = Class( function(self, name, desc, minFuel, maxFuel, burnRate, intensity, colour, heat, spreadrate)
    self.name = name
    self.desc = desc

    -- Visibility changes - when do we go to a smaller or larger flame
    self.minFuel = minFuel
    self.maxFuel = maxFuel

    -- How quickly do we burn through this fuel: update in burnRate seconds
    self.burnRate = burnRate

    -- How bright is the flame light
    self.intensity = intensity
    -- What colour is the flame light
    self.colour = colour

    -- Distance to spread
    self.heat = heat
    -- Seconds before spreading again
    self.spreadrate = spreadrate
end)

