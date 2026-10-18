--============================================================
-- 文件：map/rooms/forest/starts.lua
-- 模块：forest / starts
-- 职责：forest模块中的「starts」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("BurntForestStart", {
					colour={r=.010,g=.010,b=.010,a=.50},
					value = WORLD_TILES.FOREST,
					contents =  {
									countprefabs= {
										firepit=1,
									},
									distributepercent = 0.6,
									distributeprefabs= {
										evergreen = function() return 3 + math.random(4) end,
										charcoal = 0.2,
									},
									prefabdata={
										evergreen = {burnt=true},
									}
								}
					})
AddRoom("SafeSwamp", {
					colour={r=0.2,g=0.0,b=0.2,a=0.3},
					value = WORLD_TILES.MARSH,
					contents =  {
					                distributepercent = 0.2,
									distributeprefabs = {
										marsh_tree=1,
										marsh_bush=1,
					                }
					            }
					})

