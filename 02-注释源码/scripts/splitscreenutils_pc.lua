--============================================================
-- 文件：splitscreenutils_pc.lua
-- 模块： / splitscreenutils_pc
-- 职责：模块中的「splitscreenutils_pc」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================




-- Note:
-- This file is only here to reduce merge conflicts between PC and console builds, sorry! 

-- see splitscreenutils.lua for more functions

if IsConsole() then
	return
end

Instances = {
	Player1 		= 0,
	Player2 		= 1,
	Server 			= 2,
	CaveServer 		= 3,
	Overlay 		= 4,
}

function IsGameInstance( instance_id )
	return instance_id == Instances.Player1
end

function IsSplitScreen()
	return false
end

function HaveMultipleViewports()
	return false
end