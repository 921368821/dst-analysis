--============================================================
-- 文件：map/rooms/forest/beefalo.lua
-- 模块：forest / beefalo
-- 职责：forest模块中的「beefalo」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("BeefalowPlain", {
					colour={r=.45,g=.5,b=.85,a=.50},
					value = WORLD_TILES.SAVANNA,
					contents =  {
					                distributepercent = .05,
					                distributeprefabs= {
					                    grass = .01,
					                    beefalo = 0.02,
					                }
					            }
					})
