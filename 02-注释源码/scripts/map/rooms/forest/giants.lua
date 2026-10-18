--============================================================
-- 文件：map/rooms/forest/giants.lua
-- 模块：forest / giants
-- 职责：forest模块中的「giants」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require ("map/room_functions")

AddRoom("MooseGooseBreedingGrounds", {
	colour={r=0.2,g=0.0,b=0.2,a=0.3},
	value = WORLD_TILES.GRASS,
	tags = {"ForceConnected", "RoadPoison"},
	contents =
	{
        countprefabs=
        {
			moose_nesting_ground = 4,
        },
        distributepercent = 0.275,
        distributeprefabs =
        {
        	berrybush = 0.5,
        	berrybush_juicy = 0.25,
        	carrot_planted = 0.5,
			flower = 0.333,
			grass = 0.8,
			flint = 0.1,
			sapling = 0.8,
			twiggytree = .32,
            evergreen = 1,
			pond = 0.01,
        },
    }
})

-- AddRoom("MooseGooseNestGrass", {
-- 	colour={r=0.2,g=0.0,b=0.2,a=0.3},
-- 	value = WORLD_TILES.GRASS,
-- 	tags = {"ForceConnected", "RoadPoison"},
-- 	contents =
-- 	{
--         countprefabs=
--         {
-- 			moose_nesting_ground = 1,
--         },
--         distributepercent = 0.275,
--         distributeprefabs =
--         {
--         	berrybush = 0.5,
--         	carrot_planted = 0.5,
-- 			flower = 0.333,
-- 			grass = 0.8,
-- 			flint = 0.1,
-- 			sapling = 0.8,
-- 			evergreen = 1,
-- 			pond = 0.01,
--         },
--     }
-- })

-- AddRoom("MooseGooseNestForest", {
-- 	colour={r=0.2,g=0.0,b=0.2,a=0.3},
-- 	value = WORLD_TILES.FOREST,
-- 	tags = {"ForceConnected", "RoadPoison"},
-- 	contents =
-- 	{
--         countprefabs=
--         {
-- 			moose_nesting_ground = 1,
--         },
--         distributepercent = 0.275,
--         distributeprefabs =
--         {
--         	berrybush = 0.5,
--         	carrot_planted = 0.5,
-- 			flower = 0.333,
-- 			grass = 0.8,
-- 			flint = 0.1,
-- 			sapling = 0.8,
-- 			evergreen = 1,
-- 			pond = 0.01,
--         },
--     }
-- })