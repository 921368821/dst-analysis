--============================================================
-- 文件：scenarios/chest_explosion.lua
-- 模块：剧本 / chest_explosion
-- 职责：冒险剧本「chest_explosion」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")
local loot =
{
    {
        item = "firestaff",
        --initfn = function(inst) inst.components.finiteuses:SetUses(TUNING.ICESTAFF_USES*math.random()) end,
        count = 1
    },
    {
        item = "ash",
        count = 10
    },
    {
        item = "gunpowder",
        count = 4
    },
    {
        item = "log",
        count = 4
    },
}

local drop_loot =
{
    "gunpowder",
    "gunpowder",
    "gunpowder",
    "gunpowder",
    "gunpowder",
    "gunpowder",
    "houndfire",
    "houndfire"
}

local function triggertrap(inst)
    inst:AddComponent("lootdropper")
    inst.components.lootdropper:SetLoot(drop_loot)
    inst.components.lootdropper:DropLoot()
    --give the chest a loot dropper.
    --make the chest drop gunpowder and the fire object from fire hounds.
end

local function OnCreate(inst, scenariorunner)
    chestfunctions.AddChestItems(inst, loot)
end

local function OnLoad(inst, scenariorunner)
    chestfunctions.InitializeChestTrap(inst, scenariorunner, triggertrap)
end

local function OnDestroy(inst)
    chestfunctions.OnDestroy(inst)
end

return
{
    OnCreate = OnCreate,
    OnLoad = OnLoad,
    OnDestroy = OnDestroy
}
