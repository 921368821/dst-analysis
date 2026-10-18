--============================================================
-- 文件：map/rooms/cave/terrain_mazes.lua
-- 模块：cave / terrain_mazes
-- 职责：cave模块中的「terrain_mazes」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddRoom("LabyrinthGuarden", {
					colour={r=0.3,g=0.2,b=0.1,a=0.3},
					value = WORLD_TILES.BRICK,
					tags = {"LabyrinthEntrance"},
					contents =  {
									countstaticlayouts =
									{
										["WalledGarden"] = 1,
									},
					        	},
					})

AddRoom("BGLabyrinth", {
					colour={r=0.3,g=0.2,b=0.1,a=0.3},
					value = WORLD_TILES.BRICK,
					tags = {"Labyrinth"},
					contents =  {
					                distributepercent = .04,
					                distributeprefabs=
					                {

					                	nightmarelight = .45,
					                    dropperweb = 1,
					                }
					            }
					})
AddRoom("BGMaze", {
					colour={r=0.3,g=0.2,b=0.1,a=0.3},
					value = WORLD_TILES.MUD,
					tags = {"Maze"},
					contents =  {
									distributepercent = 0.15,
					                distributeprefabs=
					                {
					                	lichen = .001,
					                	cave_fern = .0015,
					                	--pond_cave = .002,
					                    pillar_algae = .0001,
					                    slurper = .0002,
					                }
					            }
					})


