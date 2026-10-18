--============================================================
-- 文件：prefabs/lavaarena_eventstages.lua
-- 模块：预制体 / lavaarena_eventstages（建筑与容器）
-- 职责：实体「lavaarena_eventstages」的预制体定义。SpawnPrefab("lavaarena_eventstages") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ret = {}
for i, v in pairs({
    "attack",
    "delay",
    "dialog",
    "allplayersspawned",
    "wait",
    "endofround",
    "endofmatch",
    "resetgame",
    "goto",
    "blank",
    "startround",
}) do
    table.insert(ret, Prefab("lavaarenastage_"..v, function()
        return event_server_data("lavaarena", "prefabs/lavaarena_eventstages")[v.."fn"]()
    end))
end
return unpack(ret)
