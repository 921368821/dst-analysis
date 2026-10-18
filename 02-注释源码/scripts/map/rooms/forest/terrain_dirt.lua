--============================================================
-- 文件：map/rooms/forest/terrain_dirt.lua
-- 模块：forest / terrain_dirt
-- 职责：forest模块中的「terrain_dirt」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("BGDirt", {
					colour={r=1.0,g=.8,b=.66,a=.50},
					value = WORLD_TILES.DIRT,
					tags = {"ExitPiece", "Chester_Eyebone","Astral_2"},
					contents =  {
					                distributepercent = .1,
					                distributeprefabs=
					                {
										rock1=1,
										rock2=1,
										rock_ice=.2,
					                },
					            }
					})
