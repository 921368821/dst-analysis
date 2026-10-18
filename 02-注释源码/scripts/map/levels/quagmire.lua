--============================================================
-- 文件：map/levels/quagmire.lua
-- 模块：levels / quagmire
-- 职责：levels模块中的「quagmire」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

AddLevel(LEVELTYPE.QUAGMIRE, {
    id = "QUAGMIRE",
    name = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELS.QUAGMIRE,
    desc = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELDESC.QUAGMIRE,
    location = "quagmire", -- this is actually the prefab name
    version = 4,
    overrides={
        boons = "never",
        touchstone = "never",
        traps = "never",
        poi = "never",
        protected = "never",
        disease_delay = "none",
        prefabswaps_start = "classic",
        petrification = "none",
        wildfires = "never",
    },
    background_node_range = {0,1},
})

-- older deprecated AddLevel up here --

AddWorldGenLevel(LEVELTYPE.QUAGMIRE, {
    id = "QUAGMIRE",
    name = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELS.QUAGMIRE,
    desc = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELDESC.QUAGMIRE,
    location = "quagmire", -- this is actually the prefab name
    version = 4,
    overrides={
        boons = "never",
        touchstone = "never",
        traps = "never",
        poi = "never",
        protected = "never",
        prefabswaps_start = "classic",
    },
    background_node_range = {0,1},
})
AddSettingsPreset(LEVELTYPE.QUAGMIRE, {
    id = "QUAGMIRE",
    name = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELS.QUAGMIRE,
    desc = STRINGS.UI.CUSTOMIZATIONSCREEN.PRESETLEVELDESC.QUAGMIRE,
    location = "quagmire", -- this is actually the prefab name
    version = 1,
    overrides={
        disease_delay = "none",
        petrification = "none",
        wildfires = "never",
    },
})