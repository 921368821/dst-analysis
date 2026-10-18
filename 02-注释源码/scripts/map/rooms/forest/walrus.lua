--============================================================
-- 文件：map/rooms/forest/walrus.lua
-- 模块：forest / walrus
-- 职责：forest模块中的「walrus」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


--------------------------------------------------------------------------------
-- Walrus
--------------------------------------------------------------------------------
AddRoom("WalrusHut_Plains", {
					colour={r=.30,g=.20,b=.50,a=.50},
					value = WORLD_TILES.SAVANNA,
					contents =  {
					                countprefabs= {
										walrus_camp = 1
					                },
					                distributepercent = .1,
					                distributeprefabs=
					                {
										grass=0.09,
										flower=0.003,
					                },
					            }
					})
AddRoom("WalrusHut_Grassy", {
					colour={r=.30,g=.20,b=.50,a=.50},
					value = WORLD_TILES.GRASS,
					contents =  {
					                countprefabs= {
										walrus_camp = 1
					                },
					                distributepercent = .275,
					                distributeprefabs=
					                {
										flower=0.112,
										grass=0.2,
										carrot_planted=0.05,
										flint=0.05,
										sapling=0.2,
					                    twiggytree=0.08,
										evergreen=0.3,
										pond=.005,
					                },
					            }
					})
AddRoom("WalrusHut_Rocky", {
					colour={r=.30,g=.20,b=.50,a=.50},
					value = WORLD_TILES.ROCKY,
					contents =  {
					                countprefabs= {
										walrus_camp = 1
					                },
					                distributepercent = .1,
					                distributeprefabs=
					                {
										flint=0.5,
										rock1=1,
										rock2=1,
										tallbirdnest=0.3,
					                },
					            }
					})

