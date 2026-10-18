--============================================================
-- 文件：fonthelper.lua
-- 模块： / fonthelper
-- 职责：模块中的「fonthelper」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

function AddFontAssets( asset_table, font_table )
	for i, fontdata in ipairs( font_table ) do
		table.insert( asset_table, Asset( "FONT", fontdata.filename ) )
	end
end
