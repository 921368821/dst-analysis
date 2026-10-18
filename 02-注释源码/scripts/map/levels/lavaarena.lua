--============================================================
-- 文件：map/levels/lavaarena.lua
-- 模块：levels / lavaarena
-- 职责：levels模块中的「lavaarena」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

AddLevel(LEVELTYPE.LAVAARENA, {
        id = "LAVAARENA",
        name = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELS.LAVAARENA,
        desc = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELDESC.LAVAARENA,
        location = "lavaarena", -- this is actually the prefab name
        version = 4,
        overrides={
			boons = "never",
			touchstone = "never",
            traps = "never",
            poi = "never",
            protected = "never",
        },
        background_node_range = {0,1},
    })

-- older deprecated AddLevel up here --

AddWorldGenLevel(LEVELTYPE.LAVAARENA, {
    id = "LAVAARENA",
    name = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELS.LAVAARENA,
    desc = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELDESC.LAVAARENA,
    location = "lavaarena", -- this is actually the prefab name
    version = 4,
    overrides={
        boons = "never",
        touchstone = "never",
        traps = "never",
        poi = "never",
        protected = "never",
    },
    background_node_range = {0,1},
})
AddSettingsPreset(LEVELTYPE.LAVAARENA, {
    id = "LAVAARENA",
    name = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELS.LAVAARENA,
    desc = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELDESC.LAVAARENA,
    location = "lavaarena", -- this is actually the prefab name
    version = 1,
    overrides={},
})