--============================================================
-- 文件：util/emoji.lua
-- 模块：工具函数 / emoji
-- 职责：工具函数模块中的「emoji」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "strings"
require "emoji_items"


local function GetAllowedEmojiNames(userid)
    local has_ownership = nil
    if TheWorld ~= nil and userid ~= nil and TheWorld.ismastersim then
        has_ownership = function(item_type) return TheInventory:CheckClientOwnership(userid, item_type) end
    elseif userid == TheNet:GetUserID() then
        has_ownership = function(item_type) return TheInventory:CheckOwnership(item_type) end
    else
        return {}
    end

    local emoji_translator = {}
    local allowed_emoji = {}
    for item_type,emoji in pairs(EMOJI_ITEMS) do
        if has_ownership(item_type) then
            emoji_translator[emoji.input_name] = emoji.data.utf8_str
            table.insert(allowed_emoji, emoji.input_name)
        end
    end
    return allowed_emoji, emoji_translator
end

local function GetWordPredictionDictionary()
    local words, emoji_translator = GetAllowedEmojiNames(TheNet:GetUserID())
	local data = {
		words = words,
		delim = ":",
		postfix = ":",
	}
	data.GetDisplayString = function(word) return emoji_translator[word] .. " " .. data.delim .. word .. data.postfix end
    return data
end

return {
    GetWordPredictionDictionary = GetWordPredictionDictionary,
}
