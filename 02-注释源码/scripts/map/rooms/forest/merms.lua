--============================================================
-- 文件：map/rooms/forest/merms.lua
-- 模块：forest / merms
-- 职责：forest模块中的「merms」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


--------------------------------------------------------------------------------
-- Merms
--------------------------------------------------------------------------------
AddRoom("MermTown", {
					colour={r=0.5,g=.18,b=.35,a=.50},
					value = WORLD_TILES.MARSH,
					contents =  {
									countprefabs={
										pighead=function() return math.random(6) end,
									},
									distributepercent = .1,
									distributeprefabs= {
					                    --merm = 0.1,
					                    mermhouse = 1,
					                    tentacle =  1,
					                    reeds =  2,
					                    pond_mos=0.5,
									},
					            }
					})
