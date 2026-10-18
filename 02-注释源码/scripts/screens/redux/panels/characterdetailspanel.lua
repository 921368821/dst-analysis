--============================================================
-- 文件：screens/redux/panels/characterdetailspanel.lua
-- 模块：panels / characterdetailspanel
-- 职责：panels模块中的「characterdetailspanel」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "util"
require "strings"
require "constants"

local ImageButton = require "widgets/imagebutton"
local Grid = require "widgets/grid"
local Text = require "widgets/text"
local Image = require "widgets/image"
local Widget = require "widgets/widget"

local CharacterButton = require "widgets/redux/characterbutton"
local CharacterSelect = require "widgets/redux/characterselect"
local CharacterBioScreen = require "screens/redux/characterbioscreen"

local TEMPLATES = require "widgets/redux/templates"

local CharacterDetailsPanel = Class(Widget, function(self, parent_screen)
    Widget._ctor(self, "CharacterDetailsPanel")

    self.root = self:AddChild(Widget("ROOT"))

    self.root:SetPosition(0,0)

    local scale = 0.6
    local button_width = 432 * scale
    local button_height = 90 * scale

    local function OnCharacterClick(hero)
	    TheFrontEnd:FadeToScreen( parent_screen, function() return CharacterBioScreen(self.character_scroll_list.selectedportrait.currentcharacter) end, nil )
    end

    self.character_scroll_list = self.root:AddChild(CharacterSelect(self,
            CharacterButton,
            120,
            function() return "" end, -- use default gameplay descriptions
            "wilson",
            nil,
            OnCharacterClick
        ))
    self.character_scroll_list:SetPosition(280, 100)
	self.character_scroll_list.selectedportrait:SetPosition(0,-50)

    self.focus_forward = self.character_scroll_list
end)


function CharacterDetailsPanel:Refresh()
    self.character_scroll_list:RefreshInventory()
end

return CharacterDetailsPanel
