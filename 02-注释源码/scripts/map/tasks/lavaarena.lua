--============================================================
-- 文件：map/tasks/lavaarena.lua
-- 模块：tasks / lavaarena
-- 职责：tasks模块中的「lavaarena」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddTask("LavaArenaTask", {
    locks = {},
    keys_given = {},
    room_choices = {
        ["Blank"] = 1,
    },
    background_room = "Blank",
    room_bg = WORLD_TILES.IMPASSABLE,
    colour = {r=1,g=0,b=1,a=1},
})
