--============================================================
-- 文件：map/tasksets/lavaarena.lua
-- 模块：tasksets / lavaarena
-- 职责：tasksets模块中的「lavaarena」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddTaskSet("lavaarena_taskset", {
    name = STRINGS.UI.CUSTOMIZATIONSCREEN.TASKSETNAMES.LAVA_ARENA,
    location = "lavaarena",
    tasks = {
        "LavaArenaTask",
    },
    valid_start_tasks = {
        "LavaArenaTask",
    },
})

