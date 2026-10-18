--============================================================
-- 文件：map/rooms/forest/bee.lua
-- 模块：forest / bee
-- 职责：forest模块中的「bee」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("BeeClearing", {
					colour={r=.8,g=1,b=.8,a=.50},
					value = WORLD_TILES.GRASS,
					contents =  {
					                countprefabs= {
                                        fireflies= 1,
					                    flower=6,
					                    beehive=1,
					                }
					            }
					})

AddRoom("BeeQueenBee", {
					colour={r=.8,g=1,b=.8,a=.50},
					value = WORLD_TILES.GRASS,
					contents =  {
					                countprefabs= {
                                        beequeenhive=1,
										beehive=1,
										wasphive=function() return math.random(2) end,
					                },
					                distributepercent = .45,
					                distributeprefabs=
					                {
										flower=5,
										berrybush=0.5,
										berrybush_juicy=0.25,
										sapling=0.2,
					                },
					            }
					})
