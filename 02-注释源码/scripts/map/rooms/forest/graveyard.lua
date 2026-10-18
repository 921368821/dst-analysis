--============================================================
-- 文件：map/rooms/forest/graveyard.lua
-- 模块：forest / graveyard
-- 职责：forest模块中的「graveyard」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("Graveyard", {
					colour={r=.010,g=.010,b=.10,a=.50},
					value = WORLD_TILES.FOREST,
					tags = {"Town", "Mist"},
					contents =  {
					                countprefabs= {
					                    evergreen = 3,
                                        goldnugget = function() return math.random(5) end,
					                    gravestone = function () return 4 + math.random(4) end,
					                    mound = function () return 4 + math.random(4) end
					                }
					            }
					})
