--============================================================
-- 文件：prefabs/cave_network.lua
-- 模块：预制体 / cave_network（建筑与容器）
-- 职责：实体「cave_network」的预制体定义。SpawnPrefab("cave_network") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MakeWorldNetwork = require("prefabs/world_network")

local assets =
{
    Asset("SCRIPT", "scripts/prefabs/world_network.lua"),
}

local function custom_postinit(inst)
    inst:AddComponent("caveweather")
    inst:AddComponent("quaker")
    inst:AddComponent("nightmareclock")
    inst:AddComponent("vault_floor_helper")
    inst:AddComponent("fumarolelocaltemperature")

    inst.components.worldtemperature:SetTemperatureMod(TUNING.CAVES_TEMP_MULT, TUNING.CAVES_TEMP_LOCUS)
end

return MakeWorldNetwork("cave_network", nil, assets, custom_postinit)
