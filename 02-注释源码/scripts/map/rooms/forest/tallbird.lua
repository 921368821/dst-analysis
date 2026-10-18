--============================================================
-- 文件：map/rooms/forest/tallbird.lua
-- 模块：forest / tallbird
-- 职责：forest模块中的「tallbird」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("TallbirdNests", {
					colour={r=.55,g=.75,b=.75,a=.50},
					value = WORLD_TILES.ROCKY,
					tags = {"ExitPiece", "Chester_Eyebone","Astral_1"},
					contents =  {
					                distributepercent = .1,
					                distributeprefabs=
					                {
					                    rock1 = 2,
					                    rock2 = 2,
										rock_ice = .5,
					                    tallbirdnest=1.8,
					                    spiderden=.01,
					                    blue_mushroom = .02,
					                },
					            }
					})
