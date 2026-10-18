--[[
==============================================================================
 batch.lua —— 泛化验证：批量实例化多个原版预制体

 目的：证明宿主不是为 pighouse 硬编码的，而是通用契约。
 方法：加载 N 个原版 prefab 文件，逐个 SpawnPrefab，统计成功率与缺口。

 这是「契约覆盖率」的直接度量 —— 比任何论证都有说服力。
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core = require("host.01_core")
local Loader = require("host.04_loader")
local Sim = require("host.02_sim")
local Bootstrap = require("host.05_bootstrap")

--=========================================================================
-- 启动（含真实 tuning.lua，5163 个数值键）
--=========================================================================
print("════ 引擎启动 ════")
Bootstrap.Setup()
local nt = 0
for _ in pairs(_G.TUNING) do nt = nt + 1 end
print(string.format("  class=%s  TUNING 键数=%d",
    type(_G.Class) == "function" and "真实版" or "降级", nt))

--=========================================================================
-- 候选预制体（覆盖不同类型，检验通用性）
--=========================================================================
-- ★ 候选表用「文件名 → 注册名」的映射：
--   DST 里 prefab 的**文件名**与**注册名**（Prefab() 的第一个参数）常不一致：
--     meatrack2.lua   → 注册名 "meatrack"
--     rocks.lua       → 注册名 "rock1"
--     evergreens.lua  → 注册名 "evergreen"
--     lightningrod.lua→ 注册名 "lightning_rod"
--   早前按「文件名当注册名」写，结果 LoadPrefabFile 找不到文件、
--   SpawnPrefab 又查不到注册名，两边都空 —— 缺口清单里全是 "prefab:xxx"。
local CANDIDATES = {
    { file = "pighouse",        name = "pighouse" },
    { file = "treasurechest",   name = "treasurechest" },
    { file = "cookpot",         name = "cookpot" },
    { file = "icebox",          name = "icebox" },
    { file = "meatrack2",       name = "meatrack" },
    { file = "birdcage",        name = "birdcage" },
    { file = "lightningrod",    name = "lightning_rod" },
    { file = "firepit",         name = "firepit" },
    { file = "coldfirepit",     name = "coldfirepit" },
    { file = "tent",            name = "tent" },
    { file = "siestahut",       name = "siestahut" },
    { file = "resurrectionstatue", name = "resurrectionstatue" },
    { file = "gravestone",      name = "gravestone" },
    { file = "mushroom_farm",   name = "mushroom_farm" },
    { file = "beebox",          name = "beebox" },
    { file = "beehive",         name = "beehive" },
    { file = "rabbithouse",     name = "rabbithouse" },
    { file = "houndmound",      name = "houndmound" },
    { file = "walrus_camp",     name = "walrus_camp" },
    { file = "evergreens",      name = "evergreen" },
    { file = "sapling",         name = "sapling" },
    { file = "grass",           name = "grass" },
    { file = "flint",           name = "flint" },
    { file = "log",             name = "log" },
    { file = "rocks",           name = "rock1" },
    { file = "goldnugget",      name = "goldnugget" },
    { file = "cutgrass",        name = "cutgrass" },
    { file = "twigs",           name = "twigs" },
    { file = "axe",             name = "axe" },
    { file = "pickaxe",         name = "pickaxe" },
    { file = "shovel",          name = "shovel" },
    { file = "hammer",          name = "hammer" },
    { file = "pitchfork",       name = "pitchfork" },
    { file = "backpack",        name = "backpack" },
    { file = "piggyback",       name = "piggyback" },
    { file = "amulet",          name = "amulet" },
    { file = "floatinglantern", name = "floatinglantern" },
    { file = "torch",           name = "torch" },
}

print("════ 泛化验证：批量实例化原版预制体 ════")
print(string.format("候选 %d 个", #CANDIDATES))
print("")

local loaded_files = {}
local results = {}

for _, c in ipairs(CANDIDATES) do
    -- ★ 用 Bootstrap.LoadPrefabFile（按**文件名**加载，会递归加载依赖）
    local path = Core.SourceDir .. "/prefabs/" .. c.file .. ".lua"
    local f = io.open(path, "r")
    if not f then
        results[#results + 1] = { name = c.name, status = "no-file" }
    else
        f:close()
        local ok, err = Bootstrap.LoadPrefabFile(c.file)
        if not ok then
            results[#results + 1] = { name = c.name, status = "no-file",
                                      reason = tostring(err) }
        else
            results[#results + 1] = { name = c.name, status = "loaded" }
        end
    end
end

-- 统计注册到的预制体
local registered = {}
for k in pairs(Core.Prefabs) do registered[#registered + 1] = k end
table.sort(registered)
print(string.format("加载后注册表中共 %d 个预制体", #registered))
print("")

-- 逐个实例化
local ok, fail, nofile = 0, 0, 0
local faildetail = {}

for _, r in ipairs(results) do
    if r.status == "no-file" then
        nofile = nofile + 1
    else
        -- ★ 逐个隔离：一个预制体失败不能中断整批
        local spawned, inst = pcall(Core.SpawnPrefab, r.name)
        if spawned and inst then
            ok = ok + 1
            r.inst = inst
        else
            fail = fail + 1
            table.insert(faildetail,
                r.name .. " -> " .. (type(inst) == "string" and inst or "nil"))
        end
    end
end

print("════ 实例化结果 ════")
print(string.format("  ✔ 成功   : %d", ok))
print(string.format("  ✘ 失败   : %d", fail))
print(string.format("  – 文件缺失: %d", nofile))
print("")

if #faildetail > 0 then
    print("失败详情（前 15 个）:")
    for i = 1, math.min(15, #faildetail) do
        print("  " .. faildetail[i])
    end
    print("")
end

--=========================================================================
-- 对成功实例化的实体跑 tick，看能否稳定运行
--=========================================================================
print("════ 对全部成功实体跑 300 tick ════")
local alive = 0
for _, r in ipairs(results) do
    -- ★ 必须 pcall：单点 SpawnPrefab(r.name) 失败会中断整个循环，
    --   导致后面「跑 300 tick」段静默不执行（实测踩过）
    local ok2, inst = pcall(Core.SpawnPrefab, r.name)
    if ok2 and inst then alive = alive + 1 end
end
print(string.format("  重新实例化成功: %d 个", alive))

local t0 = os.clock()
local okrun, err = pcall(function() Sim.Run(300) end)
local dt = (os.clock() - t0) * 1000
if okrun then
    print(string.format("  ✔ 300 tick 完成，用时 %.1f ms", dt))
else
    print(string.format("  ✘ tick 中断: %s", tostring(err)))
end

print("════ 契约缺口汇总 ════")
Core.DumpGaps()
