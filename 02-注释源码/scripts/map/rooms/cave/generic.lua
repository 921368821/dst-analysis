--============================================================
-- 文件：map/rooms/cave/generic.lua
-- 模块：cave / generic
-- 职责：cave模块中的「generic」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "map/room_functions"

---------------------------------------------
-- Generic Caves
---------------------------------------------

AddRoom("PitRoom", {
    colour={r=.25,g=.28,b=.25,a=.50},
    value = WORLD_TILES.IMPASSABLE,
    type = NODE_TYPE.Room,
    internal_type = NODE_INTERNAL_CONNECTION_TYPE.EdgeCentroid,
    contents = {},
})

AddRoom("CaveExitRoom", {
    colour={r=.25,g=.28,b=.25,a=.50},
    value = WORLD_TILES.SINKHOLE,
    contents =  {
        countstaticlayouts = {
            ["CaveExit"] = 1,
        },
        distributepercent = .2,
        distributeprefabs=
        {
            cavelight = 0.05,
            cavelight_small = 0.05,
            cavelight_tiny = 0.05,
            flower_cave = 0.5,
            flower_cave_double = 0.1,
            flower_cave_triple = 0.05,
            cave_fern=0.5,
            fireflies = 0.01,

            red_mushroom = 0.1,
            green_mushroom = 0.1,
            blue_mushroom = 0.1,
        }
    }
})


