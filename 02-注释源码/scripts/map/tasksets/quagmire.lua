--============================================================
-- 文件：map/tasksets/quagmire.lua
-- 模块：tasksets / quagmire
-- 职责：tasksets模块中的「quagmire」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


AddTaskSet("quagmire_taskset", {
    name = STRINGS.UI.CUSTOMIZATIONSCREEN.TASKSETNAMES.QUAGMIRE,
    location = "quagmire",
    tasks = {
        "Quagmire_KitchenTask",
    },
    valid_start_tasks = {
        "Quagmire_KitchenTask",
    },
	set_pieces = {
	},
})

