--============================================================
-- 文件：map/rooms/forest/terrain_impassable.lua
-- 模块：forest / terrain_impassable
-- 职责：forest模块中的「terrain_impassable」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("BGImpassable", {
					colour={r=.6,g=.35,b=.8,a=.50},
					value = WORLD_TILES.IMPASSABLE,
                    type = NODE_TYPE.Blank,
					contents =  { }
					})
AddRoom("BGImpassableRock", {
					colour={r=.8,g=.8,b=.8,a=.90},
					value = WORLD_TILES.ABYSS_NOISE,
                    type = NODE_TYPE.Blank,
					contents =  { }
					})
AddRoom("Nothing", {
					colour={r=.45,g=.45,b=.35,a=.50},
					value = WORLD_TILES.IMPASSABLE,
                    type = NODE_TYPE.Blank,
					contents =  {
					            }
					})
