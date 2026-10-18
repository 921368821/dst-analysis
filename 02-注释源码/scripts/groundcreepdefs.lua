--============================================================
-- 文件：groundcreepdefs.lua
-- 模块： / groundcreepdefs
-- 职责：模块中的「groundcreepdefs」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local TileManager = require("tilemanager")

TileManager.AddGroundCreep(
    GROUND_CREEP_IDS.WEBCREEP,
    {
        name = "web",
        noise_texture = "web_noise",
    }
)