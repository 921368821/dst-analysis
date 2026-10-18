--============================================================
-- 文件：prefabs/forest_network.lua
-- 模块：预制体 / forest_network（建筑与容器）
-- 职责：实体「forest_network」的预制体定义。SpawnPrefab("forest_network") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MakeWorldNetwork = require("prefabs/world_network")

local assets =
{
    Asset("SCRIPT", "scripts/prefabs/world_network.lua"),
}

local prefabs =
{
    "thunder_close",
    "thunder_far",
    "thunder",
    "lightning",
}

local function custom_postinit(inst)
    inst:AddComponent("weather")
    inst:AddComponent("moonstorms")
    inst:AddComponent("sharkboimanagerhelper")
    inst:AddComponent("wagpunk_floor_helper")
    inst:AddComponent("lunarhailbirdsoundmanager")
end

return MakeWorldNetwork("forest_network", prefabs, assets, custom_postinit)