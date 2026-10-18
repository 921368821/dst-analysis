--============================================================
-- 文件：util/profanityfilter.lua
-- 模块：工具函数 / profanityfilter
-- 职责：工具函数模块中的「profanityfilter」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

ProfanityFilter = Class(function(self)
	self.dictionaries = {}
end)

function ProfanityFilter:AddDictionary(name, data)
	--[[
	self.dictionaries["test"] =
	{
		exact_match = {
			[smallhash("dst")] = true,
		},
		loose_match =
		{
			"test",
		},
	}
	]]
	if name ~= nil and name ~= "" and self.dictionaries[name] == nil then
		for i, v in ipairs(data.loose_match) do
			data.loose_match[i] = TheSim:DecodeKleiData(v)
		end
		self.dictionaries[name] = data
	end
end

function ProfanityFilter:RemoveDictionary(name)
    self.dictionaries[name] = nil
end

----------------------------
function ProfanityFilter:HasProfanity(input)
	if input == nil or input == "" then
		return false
	end

	local strhash = smallhash -- optimization

	input = string.lower(input)
	local input_words = string.split(input, "%s")
	local input_hashes = {}
	for _, v in ipairs(input_words) do
		table.insert(input_hashes, strhash(v))
	end

	-- exact matches
	for _, dict in pairs(self.dictionaries) do
		for i, h in ipairs(input_hashes) do
			if dict.exact_match[ h ] then
				--print("bad word '"..input.."' exact match '"..input_words[i].."'")
				return true
			end
		end
	end

	-- loose match
	local str_find = string.find -- optimization
	for _, dict in pairs(self.dictionaries) do
		for _, profanity in ipairs(dict.loose_match) do
			if str_find(input, profanity, 1, true) ~= nil then
				--print("bad word '"..input.."' loose match '"..profanity.."'")
				return true
			end
		end
	end

	--print("safe words")

	return false
end
