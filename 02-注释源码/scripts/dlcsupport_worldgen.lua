--============================================================
-- 文件：dlcsupport_worldgen.lua
-- 模块： / dlcsupport_worldgen
-- 职责：模块中的「dlcsupport_worldgen」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require 'json'

MAIN_GAME = 0
REIGN_OF_GIANTS = 1

NO_DLC_TABLE = {REIGN_OF_GIANTS=false}
ALL_DLC_TABLE = {REIGN_OF_GIANTS=true}
DLC_LIST = {REIGN_OF_GIANTS}

local __DLCEnabledTable = {}

function IsDLCEnabled(index)
    return __DLCEnabledTable[index] or false
end

function SetDLCEnabled(tbl)
	tbl = tbl or {}
	__DLCEnabledTable = tbl
end

local parameters = json.decode(GEN_PARAMETERS or {})
SetDLCEnabled(parameters.DLCEnabled)

print("DLC enabled : ",IsDLCEnabled(REIGN_OF_GIANTS))