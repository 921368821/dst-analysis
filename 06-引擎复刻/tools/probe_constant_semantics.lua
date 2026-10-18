--[[
==============================================================================
 tools/probe_constant_semantics.lua —— 把宿主里「恒值语义」**实测**出来

为什么需要它（3.5 的验收方式是二选一：补实现，或者逐条写明哪些 behaviour
永远不触发）。要写「永远不触发」，先得知道接口**实际返回什么** ——
不能靠读代码猜，因为同一个名字在宿主里可能有两个实现（本文件就发现了一例：
`host/01_core.lua:189` 的 LightWatcher:IsInLight 返回 true，
而 `host/06_entityscript.lua:203` 的 EntityScript:IsInLight 返回 false）。

输出格式：每行 `KEY=VALUE`，供 tools/scan_constant_semantics.py 解析。
==============================================================================
]]

package.path = "./?.lua;./host/?.lua;" .. package.path

local Core      = require("host.01_core")
local Bootstrap = require("host.05_bootstrap")
local WorldMap  = require("host.20_map")
local Universal = require("host.07_universal")

Bootstrap.Setup()
WorldMap.Generate({ seed = 20261015 })
pcall(Bootstrap.LoadPrefabFile, "wilson")

Universal.Install(Core)
local inst = Core.SpawnPrefab("wilson")
Universal.Uninstall()

local function out(k, v)
    print(string.format("%s=%s", k, tostring(v)))
end

----------------------------------------------------------------------------
-- 1) 光照：实体层 vs 光照观察者层（两个实现，可能是两个答案）
----------------------------------------------------------------------------
if inst ~= nil then
    local ok, v = pcall(inst.IsInLight, inst)
    out("ent.IsInLight", ok and tostring(v) or ("ERR:" .. tostring(v)))

    local ok2, v2 = pcall(inst.IsInDark, inst)
    out("ent.IsInDark", ok2 and tostring(v2) or ("ERR:" .. tostring(v2)))

    local lw = inst.LightWatcher
    if lw ~= nil then
        local ok3, v3 = pcall(lw.IsInLight, lw)
        out("lightwatcher.IsInLight", ok3 and tostring(v3) or ("ERR:" .. tostring(v3)))
        local ok4, v4 = pcall(function() return lw:GetLight() end)
        out("lightwatcher.GetLight", ok4 and tostring(v4) or ("ERR:" .. tostring(v4)))
        -- ★ 下面三个是 behaviours/avoidlight.lua 真正会调的（GetLightAngle 两处、
        --   GetLightValue 4 处、GetTimeInDark 1 处）。宿主的 LightWatcher 用 __index
        --   **静默兜底**造桩并返回 nil —— 所以「有没有这个方法」是 type()=="function"，
        --   但「返回什么」才是关键。这里两个都记。
        for _, m in ipairs({ "GetLightAngle", "GetLightValue", "GetTimeInLight", "GetTimeInDark" }) do
            local okm, vm = pcall(function() return lw[m](lw) end)
            out("lightwatcher." .. m, okm and tostring(vm) or ("ERR:" .. tostring(vm)))
        end
    else
        out("lightwatcher.IsInLight", "NO_LIGHTWATCHER")
        out("lightwatcher.GetLight", "NO_LIGHTWATCHER")
    end
else
    out("ent.IsInLight", "NO_ENTITY")
    out("ent.IsInDark", "NO_ENTITY")
    out("lightwatcher.IsInLight", "NO_ENTITY")
    out("lightwatcher.GetLight", "NO_ENTITY")
end

----------------------------------------------------------------------------
-- 2) 海洋 / 可通行：近原点（陆地）vs 远处（外海）
----------------------------------------------------------------------------
local M = TheWorld.Map
local pts = { { "land", 40, 0, 40 }, { "far", 200, 0, 200 }, { "farther", 500, 0, 500 } }
for _, p in ipairs(pts) do
    local tag, x, y, z = p[1], p[2], p[3], p[4]
    local ok1, v1 = pcall(M.IsOceanAtPoint, M, x, y, z)
    out("map.IsOceanAtPoint." .. tag, ok1 and tostring(v1) or "MISSING")
    local ok2, v2 = pcall(M.IsOceanTileAtPoint, M, x, y, z)
    out("map.IsOceanTileAtPoint." .. tag, ok2 and tostring(v2) or "MISSING")
    local ok3, v3 = pcall(M.IsPassableAtPoint, M, x, y, z)
    out("map.IsPassableAtPoint." .. tag, ok3 and tostring(v3) or "MISSING")
end

----------------------------------------------------------------------------
-- 3) 平台 / 湿度 / 温度：平台与湿度是否恒值
----------------------------------------------------------------------------
if inst ~= nil then
    local ph = inst.Physics
    if ph ~= nil then
        local ok, v = pcall(ph.IsOnPlatform, ph)
        out("physics.IsOnPlatform", ok and tostring(v) or "MISSING")
    else
        out("physics.IsOnPlatform", "NO_PHYSICS")
    end
    local okE, vE = pcall(inst.IsOnPlatform, inst)
    out("ent.IsOnPlatform", okE and tostring(vE) or "MISSING")
end

local st = TheWorld.state
local state_keys = {
    "isday", "isdusk", "isnight", "iscaveday", "iscavenight",
    "temperature", "humidity", "moisture", "precipitation",
    "iswet", "israining", "issnowing", "issnowcovered",
    "season", "phase", "light",
}
for _, k in ipairs(state_keys) do
    local ok, v = pcall(function() return st[k] end)
    out("world.state." .. k, ok and tostring(v) or "ERR")
end

-- 世界层的湿度/温度读取入口（temperature.lua 走它们）
local okT, vT = pcall(function() return TheWorld:GetTemperature() end)
out("world.GetTemperature", okT and tostring(vT) or "MISSING")
local okH, vH = pcall(function() return TheWorld:GetMoisture() end)
out("world.GetMoisture", okH and tostring(vH) or "MISSING")
