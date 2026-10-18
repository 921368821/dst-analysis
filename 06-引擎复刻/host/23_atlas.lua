--[[
==============================================================================
 23_atlas.lua —— TheSim:AtlasContains（真实图集索引查询）
==============================================================================
为什么需要它
   `TheSim:AtlasContains(atlas, imagename)` 是 DST 的 C++ 接口，宿主从未提供。
   缺它的后果**不是**「少画一张图」，而是**预制体工厂直接崩**：

       preparedfoods.lua:57   inst.inv_image_bg.atlas = GetInventoryItemAtlas(...)
         → simutil.lua:693    GetInventoryItemAtlas
         → simutil.lua:675    TheSim:AtlasContains(...)
         ✘ attempt to call method 'AtlasContains' (a nil value)

   实测：`reachability.lua` 抽样 300 个预制体，12 个 `*_spice_*`
   （preparedfoods 家族）全部 spawn 失败，**报错位置全部指向 simutil.lua:675**。

★★ 为什么不能「一律返回 false」糊过去
   那样 `GetInventoryItemAtlas_Internal` 会返回 nil，
   `inst.inv_image_bg.atlas` 变成 nil —— **不崩了，但值是错的**：
   DST 真实行为是 true（这些贴图确实在图集里）。
   这正好是本工程一直在防的「静默空实现」：不报错、不进缺口清单、
   上下游都正常，只是行为全是默认值。
   ⇒ 本工程的诚实原则要求**真的去查**。

真实数据在哪（这是本模块存在的前提）
   data/images/*.xml             只落了 345 个散件，**没有** inventoryimages*.xml
   data/databundles/images.zip   ✔ 里面有 images/inventoryimages1..4.xml 等
   data/minimap/*.xml            ✔ 散件直接可读

   所以索引由 tools/export_atlas_index.py 从 zip 里导出到 atlas_index/，
   本模块只做**按需读取 + 查询**。

口径
   · 只导出 DST 脚本**确实会问**的 16 个图集（simutil.lua 678-845 的调用点全集）
   · 严格精确匹配（元素名带 `.tex`，与调用方传进来的一致）
   · 不做**静默**的模糊匹配 —— 但要统计「查询名不带 .tex 且未命中」，
     这样万一将来出现口径不一致，数字会自己冒出来，而不是悄悄返回 false
   · 查不到的图集 → 返回 false **并**记入缺口清单（不静默）

诚实边界（必须写清）
   · 索引来自**同版本**游戏数据（本项目使用的 DST 安装目录）
   · 若换成别的游戏版本，`anim/` 与图集内容都会变 ⇒ 需重跑导出工具
   · `atlas_index/` 缺失时本模块**不崩**：所有查询返回 false，
     并记一次 `AtlasContains-无索引` 缺口（数字会显式出现在缺口清单里）
==============================================================================
]]

local Core = require("host.01_core")
local Sim  = require("host.02_sim")

local TheSim = Sim.TheSim
local DIR = "atlas_index"

-- atlas 路径 -> { [元素名] = true } | false（索引文件不存在）
local cache = {}
-- atlas 路径 -> 元素数（供调试/报告引用，不混进索引表当键）
local counts = {}
-- 已记过缺口的图集，避免每次查询都刷一条
local noted = {}

local stats = {
    queries       = 0,   -- 调用次数
    hit           = 0,   -- 命中
    miss          = 0,   -- 未命中
    unknown_atlas = 0,   -- 索引里没有的图集（记缺口）
    noext_miss    = 0,   -- ★ 查询名不带 .tex 且未命中（口径可疑信号）
}

local function flat(atlas)
    return (atlas:gsub("/", "__"))
end

--- 取（并缓存）某个图集的元素名集合；索引不存在返回 false
local function index_for(atlas)
    local c = cache[atlas]
    if c ~= nil then return c end

    local path = DIR .. "/" .. flat(atlas) .. ".idx"
    local f = io.open(path, "r")
    if not f then
        cache[atlas] = false
        stats.unknown_atlas = stats.unknown_atlas + 1
        if not noted[atlas] then
            noted[atlas] = true
            Core.NoteGap("atlas:" .. atlas, "AtlasContains-无索引")
        end
        return false
    end

    local t, n = {}, 0
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line ~= "" then
            t[line] = true
            n = n + 1
        end
    end
    f:close()

    cache[atlas] = t
    counts[atlas] = n
    return t
end

--- TheSim:AtlasContains(atlas, imagename) -> boolean
--  真实语义：图集文件里有没有名为 imagename 的这个元素。
function TheSim:AtlasContains(atlas, imagename)
    stats.queries = stats.queries + 1

    -- 真实引擎对非字符串会抛；宿主改成「记缺口 + false」，
    -- 理由与 Core.SpawnPrefab 的类型防御一致：不要为一句拼错的名字
    -- 让上层整条链崩掉，但**绝不静默**。
    if type(atlas) ~= "string" or type(imagename) ~= "string" then
        stats.miss = stats.miss + 1
        Core.NoteGap(string.format("AtlasContains(%s, %s)", type(atlas), type(imagename)),
                     "atlas-type-error")
        return false
    end

    local idx = index_for(atlas)
    if idx == false then
        stats.miss = stats.miss + 1
        return false
    end

    if idx[imagename] then
        stats.hit = stats.hit + 1
        return true
    end

    stats.miss = stats.miss + 1
    -- ★ 口径可疑信号：DST 调用方传的是 xxx.tex，如果查询名没有 .tex
    --   却也没命中，很可能是「我们自己导错了后缀」而不是「图真的不在」。
    --   计数出来，让这个可能性**可见**。
    if not imagename:match("%.tex$") then
        stats.noext_miss = stats.noext_miss + 1
    end
    return false
end

--- 供测试/入口读取的统计（不改变语义）
function TheSim:AtlasContainsStats()
    local out = {}
    for k, v in pairs(stats) do out[k] = v end
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    out.atlases_cached = n
    out.atlases_total = (function()
        local c = 0
        for _, v in pairs(counts) do c = c + v end
        return c
    end)()
    return out
end

--- 索引是否整体可用（缺文件时为 false，让上层能如实报「退化」）
function TheSim:AtlasIndexAvailable()
    return index_for("images/inventoryimages1.xml") ~= false
end

Sim.Atlas = {
    Stats = stats,
    Counts = counts,
}

return Sim.Atlas
