--============================================================
-- 文件：prefabs/driedplants_defs.lua
-- 模块：预制体 / driedplants_defs（建筑与容器）
-- 职责：实体「driedplants_defs」的预制体定义。SpawnPrefab("driedplants_defs") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local DRIED_DEFS =
{
    {
        name = "petals",
        sanityvalue = TUNING.SANITY_SUPERTINY,
        --
        build = "flower_petals",
    },
    {
        name = "petals_evil",
        sanityvalue = -TUNING.SANITY_TINY,
        --
        bank = "flower_petals_evil",
        build = "flower_petals_evil",
    },
    {
        name = "foliage",
    },
    {
        name = "succulent_picked",
        healthvalue = TUNING.HEALING_MEDSMALL,
    },
    {
        name = "firenettles",
        healthvalue = -TUNING.HEALING_SMALL,
        sanityvalue = -TUNING.SANITY_TINY,
        oneaten = function(inst, eater)
        	if not eater:HasTag("plantkin") then
                eater:AddDebuff("firenettle_toxin", "firenettle_toxin")
        	end
        end,
    },
    {
        name = "tillweed",
		healthvalue = TUNING.HEALING_MEDSMALL,
    },
    {
        name = "moon_tree_blossom",
        sanityvalue = TUNING.SANITY_SMALL,
        --
        bank = "moon_tree_petal",
        build = "moon_tree_petal",
    },
    {
        name = "forgetmelots",
        sanityvalue = TUNING.SANITY_TINY,
    },
}

--[[ Omar: For searching
petals_dried
petals_evil_dried
foliage_dried
succulent_picked_dried
firenettles_dried
tillweed_dried
moon_tree_blossom_dried
forgetmelots_dried
]]
return {
    plants = DRIED_DEFS
}