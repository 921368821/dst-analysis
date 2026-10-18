--============================================================
-- 文件：widgets/redux/weedspage.lua
-- 模块：redux / weedspage
-- 职责：redux模块中的「weedspage」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Image = require "widgets/image"
local ImageButton = require "widgets/imagebutton"
local Widget = require "widgets/widget"

local WEED_DEFS = {}--require("prefabs/weed_defs").WEED_DEFS

local WeedsPage = Class(Widget, function(self, parent, ismodded)
    Widget._ctor(self, "WeedsPage")

end)

return WeedsPage