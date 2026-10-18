--============================================================
-- 文件：map/tasks/DLCtasks.lua
-- 模块：tasks / DLCtasks
-- 职责：tasks模块中的「DLCtasks」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "map/tasks/dst_tasks_forestworld" 

AddTask("Oasis", {
		locks={LOCKS.ADVANCED_COMBAT,LOCKS.TIER4, LOCKS.MONSTERS_DEFEATED},
		keys_given={KEYS.ROCKS, KEYS.TIER5},
		room_choices={
			["Badlands"] = 3,
			["PondyGrass"] = 1,
			["BuzzardyBadlands"] = 2,
		},
		room_bg=WORLD_TILES.DIRT,
		background_room="BGBadlands",
		colour={r=.05,g=.5,b=.05,a=1},
	})

