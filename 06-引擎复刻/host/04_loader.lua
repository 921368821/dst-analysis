--[[
==============================================================================
 04_loader.lua —— require 钩子：把 DST 内部 require 解析到真实源码

 DST 的 Lua 层用 `require("components/health")` 这种相对路径。
 真实引擎有自定义的 package.path / loader。
 宿主要复刻的就是这个解析规则：
     require("xxx")        -> <scripts>/xxx.lua
     require("prefabs/yyy")-> <scripts>/prefabs/yyy.lua

 关键设计：
   · 原版文件**只读**，绝不修改
   · 加载失败时不静默跳过，而是记入 GAPS 并返回空表，
     让上层继续跑（否则一个缺失文件会阻断整个验证）
==============================================================================
]]

local Core = require("host.01_core")

local Loader = {}

-- ★ SRC 一律取 Core.SourceDir（由 host/00_paths.lua 解析），不再各写一份字面量
local SRC = Core.SourceDir

Loader.Loaded = {}       -- 模块名 -> 已加载的模块（模拟 package.loaded）
Loader.LoadOrder = {}    -- 加载顺序，便于调试
Loader.Failures = {}     -- 加载失败的模块

--- 解析 require 名到真实文件路径
function Loader.Resolve(name)
    local clean = name:gsub("%.", "/")
    return SRC .. "/" .. clean .. ".lua"
end

--- 加载一个真实 DST Lua 文件
-- ★★★ 「失败不永久缓存」—— 与 `Core.LoadRealComponent` 同一修法。
--
--   原来「文件不存在 / 编译失败 / 运行时抛错」都把 `Loaded[name]` 写成 `{}`，
--   而这一行是**永久的** ⇒ 只要某个模块在**环境还没就绪时**被 require 过一次
--   （例如更早的某个 prefab 触发的加载），它就永远返回空表，
--   后续真正需要它的调用点全部拿到 `{}`。
--
--   实测症状：`armor_lunarplant.lua:236`
--       require("prefabs/skilltree_defs").CUSTOM_FUNCTIONS.wortox.SetupLunarResists(inst)
--   报 `attempt to index field 'CUSTOM_FUNCTIONS' (a nil value)`
--   —— 而**单独** require 同一个模块完全正常。差别只在**加载时机**。
--
--   改成：失败时仍返回 `{}`（让调用方本语句不崩），但把名字记进
--   `Loader.Retry[name]`，**下一次 require 同一名字时重试**。
--   成功则清掉记录。这样既不会死循环（每次调用最多试一次），
--   也不会把「一次早期失败」放大成「永久缺口」。
Loader.Retry = Loader.Retry or {}

function Loader.Load(name)
    -- 只有**成功**的缓存才直接返回；失败过的每次重试
    if Loader.Loaded[name] ~= nil and Loader.Retry[name] == nil then
        return Loader.Loaded[name]
    end

    local path = Loader.Resolve(name)
    local f = io.open(path, "r")
    if not f then
        Loader.Failures[name] = { path = path, reason = "文件不存在" }
        Core.NoteGap("require:" .. name, "file-missing")
        Loader.Loaded[name] = {}     -- 返回空表，让上层继续
        Loader.Retry[name] = true    -- ★ 但下次仍重试（文件可能后补）
        return Loader.Loaded[name]
    end
    f:close()

    local chunk, err = loadfile(path)
    if not chunk then
        Loader.Failures[name] = { path = path, reason = tostring(err) }
        Core.NoteGap("require:" .. name, "compile-error")
        Loader.Loaded[name] = {}
        Loader.Retry[name] = true    -- ★ 下次重试
        return Loader.Loaded[name]
    end

    -- 真实引擎的模块返回一个值；但 DST 很多文件是「定义全局函数」型
    -- （如 standardcomponents.lua 定义一堆 MakeXxx），返回 nil。
    local ok, result = pcall(chunk, "@" .. path)
    if not ok then
        Loader.Failures[name] = { path = path, reason = tostring(result) }
        -- ★ 缺口记录里带上**原因摘要**。
        --   此前只记 `require:<名字>`，看缺口清单时完全不知道「为什么失败」；
        --   补上原因后一眼能看出是「文件不存在」「依赖缺失」还是「运行时报错」。
        local why = tostring(result):gsub("^.-:%d+: ", "")
        if #why > 70 then why = why:sub(1, 70) .. "…" end
        Core.NoteGap("require:" .. name .. "  (" .. why .. ")", "runtime-error")
        Loader.Loaded[name] = {}
        Loader.Retry[name] = true    -- ★ 下次重试（环境可能已就绪）
        return Loader.Loaded[name]
    end

    Loader.Loaded[name] = result == nil and true or result
    Loader.Retry[name] = nil          -- ★ 成功 ⇒ 撤销重试标记
    table.insert(Loader.LoadOrder, name)
    -- ★★ 与 LoadFile 同一时机：确保 MakeWorld / MakeWorldNetwork 已被包一层。
    --   ⚠️ 这条**必须在 Load 里也接**：`prefabs/world.lua` 是 forest.lua 通过
    --      `require("prefabs/world")` 载入的 —— 走的是本函数（Loader.Load），
    --      **不是** LoadFile。只在 LoadFile 里装会漏掉 world.lua，
    --      于是 forest/cave/lavaarena 调 MakeWorld 时钩子还没装上（实测漏判）。
    Loader.WrapWorldMakers()
    Loader.EnsureActionsFallback()
    return Loader.Loaded[name]
end

--- 包装成一个可赋给 package.loaders 的加载器
function Loader.Searcher(name)
    if Loader.Loaded[name] ~= nil then
        return function() return Loader.Loaded[name] end
    end
    return nil
end

--=========================================================================
-- ★ 全局表守卫：防御「模块重新赋值全局表、冲掉元表」
--
-- 踩过的坑（DST 里反复出现同一类问题）：
--   · tuning.lua:3     `TUNING = {}`        → 重建 5163 个数值键的表
--   · constants.lua    `WORLD_TILES = {...}` → 重建常量表
--   · 某个 map 模块在**懒加载时**又重建 WORLD_TILES
-- 每次元表被冲掉，「惰性兜底」就失效，表现为 `table index is nil` 等
-- 莫名的后续错误（实测：Setup 后 RIFT_MOON=65619，加载 wilson 后变 nil）。
--
-- 解法：登记「需要守卫的全局表」，每次执行任何 DST 文件后自动重新挂元表。
-- 这比逐个找出是哪个模块干的要稳 —— 那个链条可能随时变化。
local Guarded = {}
Loader._GuardMeta = {}
Loader.Guarded = Guarded

--- 登记一张需要守卫的全局表
function Loader.GuardGlobalTable(name, key)
    Guarded[key or name] = name
end

--- 重新给所有受守卫的全局表挂上元表
function Loader.RearmGuards()
    for key, globalName in pairs(Guarded) do
        local t = _G[globalName]
        if type(t) == "table" and getmetatable(t) == nil then
            local mk = Loader._GuardMeta[key]
            -- ★ 必须把表传进去：mk 就是 ensure(t)，它要给「这张表」挂元表
            if mk then mk(t) end
        end
    end
end

--- 清除守卫登记
function Loader.ClearGuards()
    Guarded = {}
    Loader._GuardMeta = {}
end

--- 直接实现：把某张全局表改成惰性补键，并在 Loader 里登记
--- @param globalName 全局变量名，如 "WORLD_TILES"
--- @param startId    新键的起始 id
function Loader.MakeLazyGlobal(globalName, startId)
    local nextid = startId or 100
    local function ensure(t)
        if getmetatable(t) ~= nil then return t end
        setmetatable(t, {
            __index = function(tt, k)
                if type(k) ~= "string" or k:match("^_") then return nil end
                local id = nextid
                nextid = nextid + 1
                rawset(tt, k, id)
                return id
            end,
        })
        return t
    end
    local t = _G[globalName]
    if type(t) ~= "table" then t = {}; _G[globalName] = t end
    ensure(t)
    Guarded[globalName] = globalName
    Loader._GuardMeta[globalName] = ensure
    return t
end

--=========================================================================
-- ★★ 世界根预制体的**自动登记**（不用反射、不用名字清单）
--
--   要解决的问题：`prefabs/world.lua:418` 的闸门
--       if TheWorld ~= nil then print("You cannot spawn multiple worlds!") return nil end
--   是 **Lua 层**的 —— spawn 世界根预制体**只打印一句就返回 nil，不抛错**
--   ⇒ 没法用「错误文本」判据（错误是 nil）。
--
--   ★ 为什么不用 `debug.getinfo(2,"n").name` 认调用者：
--     实测**在本运行时里恒为 nil**（连 `_G.Prefab(...)` 这种最普通的全局调用
--     也拿不到名字）。与 `debug.getinfo(fn,"u").nparams` 恒 nil 是同一类问题
--     —— 这个 Lua 实现的 debug 信息不全。⇒ 反射这条路不走。
--
--   ★ 为什么不用名字清单 {world, net, forest, cave, lavaarena, quagmire}：
--     本轮已经**三次**被「手工列清单」坑到（sg 方法表 / prefabskin 全局表 /
--     渲染管理器）。而且 DST 以后新增世界类型就漏。
--
--   ⇒ 用**调用嵌套**：把 `MakeWorld` / `MakeWorldNetwork` 包一层，
--     在它们执行期间置一个标记；`Core.Prefab` 看标记决定是否登记。
--     这两个函数是所有世界根的**唯一构造入口**（world.lua:401 /
--     world_network.lua:38），且它们内部调 `Prefab` 是**同一栈帧**内的，
--     所以嵌套法没有漏判的余地。
--
--   ★ 什么时候装钩子：**每次执行完任何文件后**（与 RearmGuards 同一时机）。
--     因为 world.lua 是随 forest.lua 的 `require` 被加载的，而 forest.lua
--     会在**同一次 LoadFile 调用内**紧接着调 MakeWorld ——
--     只在入口处装一次会来不及（实测漏掉 forest/cave/lavaarena）。
--=========================================================================
Loader.WrappedMakers = Loader.WrappedMakers or {}

function Loader.WrapWorldMakers()
    for _, gname in ipairs({ "MakeWorld", "MakeWorldNetwork" }) do
        local cur = rawget(_G, gname)
        local mine = Loader.WrappedMakers[gname]
        -- ★★ 判据是「当前这个是不是**我装的包装器**」，而不是
        --   「我以前装过没有」。第一版写成后者（`== nil` 才装），
        --   实测**完全失效**：
        --     · `LoadPrefabFile("world")` 走的是 `Loader.LoadFile`，
        --       它**不写** `Loader.Loaded` ⇒ 后续 forest.lua 的
        --       `require("prefabs/world")` 会**再执行一遍** world.lua，
        --       于是 `MakeWorld` 全局被**重新定义成原始版本**；
        --     · 而「我以前装过」为真 ⇒ 不再包装 ⇒ forest/cave/lavaarena
        --       调到的都是**未包装的**原函数 ⇒ 一个都没登记上。
        --   ⇒ 必须每次比对当前值与我的包装器是否为同一个。
        if type(cur) == "function" and cur ~= mine then
            local wrapper
            wrapper = function(...)
                local prev = Core._InWorldMaker
                Core._InWorldMaker = gname
                local n = select("#", ...)
                local r = { cur(...) }
                Core._InWorldMaker = prev
                -- 用返回的名字兜底登记（宿主 Core.Prefab 返回 name 字符串）
                if type(r[1]) == "string" then
                    Core.WorldRootPrefabs[r[1]] = gname
                end
                return unpack(r, 1, n > 0 and n or #r)
            end
            Loader.WrappedMakers[gname] = wrapper
            rawset(_G, gname, wrapper)
        end
    end
end

--- 确保 ACTIONS 上挂着「未知动作名也造得出来」的惰性兜底。
--
--   ★ 为什么需要**反复**确保，而不是装一次就完事：
--     真实 `actions.lua` 里是 `ACTIONS = { ... }`（**整个表重新赋值**）。
--     只要有人在别处 `require("actions")` 而 `Loader.Loaded["actions"]` 还是空，
--     actions.lua 就会**再执行一遍** ⇒ 全局 ACTIONS 被换成一个**没有元表的新表**
--     ⇒ 兜底静默消失。
--     `finiteuses.lua:30 self.consumption[ACTIONS.XXX]` 一旦拿到 nil
--     就是 `table index is nil` 直接崩，而且崩在离原因很远的地方。
--
--   ★ 这与 `Loader.RearmGuards`（防「模块重建全局表、冲掉元表」）是**同一类问题**，
--     所以挂在同一时机（每次执行完任何文件后）。
--   ⚠️ 实测这条是 tests.lua 的反向判据抓出来的：
--      「未知动作名要造得出来」断言直接报 nil —— 否则我根本不会发现兜底丢了。
function Loader.EnsureActionsFallback()
    local A = rawget(_G, "ACTIONS")
    if type(A) ~= "table" then return end

    -- ★★ 判据是「兜底**现在是否真的生效**」，而不是「我以前装过没有」。
    --   这与 WrapWorldMakers 那次是**同一个教训**：
    --     第一版这里写的是 `if getmetatable(A) ~= nil then return end`
    --     —— 以为「有元表」就等于「有我的兜底」。实测报 nil：
    --     `_G.ACTIONS` 上确实挂着一张元表，但**不是我的**（另有来源），
    --     而它不认识未知键 ⇒ 兜底形同不存在。
    --   ⇒ 改成**自验证**：真的去读一个不存在的键，看能不能拿到可用对象。
    local PROBE = "FALLBACK_PROBE_KEY"
    if type(rawget(A, PROBE)) == "table" then return end   -- 上次探测留下痕迹 ⇒ 已生效

    local mt = getmetatable(A)
    if mt == nil then mt = {}; setmetatable(A, mt) end
    local prev = rawget(mt, "__index")
    rawset(mt, "__index", function(t, k)
        if type(k) ~= "string" then return nil end
        local a = { id = k, str = k, code = k }
        function a:GetActionType() return self.id end
        rawset(t, k, a)          -- 合成后落表（与宿主原惰性表同语义）
        return a
    end)
    -- 探测一次：走 __index、把合成对象 rawset 进表；
    -- 下一次调用就能靠 rawget 短路（不再重装元表）。
    local probe = A[PROBE]
    if type(probe) ~= "table" and type(prev) == "function" then
        prev(A, PROBE)           -- 万一 prev 是别的兜底，也让它走一遍
    end
end

--- 把 require 失败的原因逐条打印出来（缺口清单只给摘要，这里给全文）
function Loader.DumpFailures(limit)
    local keys = {}
    for k in pairs(Loader.Failures or {}) do keys[#keys + 1] = k end
    if #keys == 0 then
        print("  （无 require 失败）")
        return
    end
    table.sort(keys)
    print(string.format("  require 失败 %d 个:", #keys))
    for i, k in ipairs(keys) do
        if limit and i > limit then
            print(string.format("    … 另有 %d 个", #keys - limit))
            break
        end
        local f = Loader.Failures[k]
        print(string.format("    %-34s %s", k, tostring(f.reason):sub(1, 130)))
    end
end

--- 直接执行一个真实文件，返回其返回值（用于 prefab 文件）
function Loader.LoadFile(path)
    local chunk, err = loadfile(path)
    if not chunk then return false, "loadfile: " .. tostring(err) end
    -- ★ 用 xpcall + debug.traceback 而不是 pcall：
    --   pcall 只拿到错误**值**，如果被 `error(nil)` 或裸 `error()` 抛出，
    --   错误值就是 nil —— 表现为「失败但说不出原因」（实测 turfs.lua 就是这样，
    --   缺口清单里只有个 `nil`，完全无法定位）。
    --   traceback 一定包含出错位置，不会再出现空错误的黑洞。
    local ok, result = xpcall(chunk, debug.traceback, "@" .. path)
    -- ★ 执行任何 DST 文件后都要重新挂守卫 —— 可能有模块重建了全局表
    Loader.RearmGuards()
    -- ★ 同一时机：确保 MakeWorld / MakeWorldNetwork 已被包一层
    --   （见 Loader.WrapWorldMakers 的说明：world.lua 随 require 加载，
    --     而调用方在同一次 LoadFile 内就调 MakeWorld ⇒ 必须在每次执行后装）
    Loader.WrapWorldMakers()
    Loader.EnsureActionsFallback()
    -- ★ 契约：返回 (成功?, chunk的返回值 或 错误信息)
    --   ⚠️ 之前是「返回 chunk 的返回值」当成功标志 —— 但很多 DST 文件
    --      **本来就不返回值**（只做全局副作用），于是被判成失败。
    --      实测 turfs.lua 就是这样：它成功执行、注册了 0 个预制体，
    --      却因为返回 nil 被 full.lua 当成「加载失败」，缺口清单里只有个 `nil`。
    --      改成 bool-first 后，调用方第一次返回值就一定是布尔。
    if not ok then return false, result end
    return true, result
end

--=========================================================================
-- ★ 在模块加载时就装好 require 钩子
--   这样后续任何文件（包括真实 scheduler.lua 的 require("class")）
--   都能被解析到 DST 源码，不受调用顺序影响。
--=========================================================================
local _native_require = require
Loader.NativeRequire = _native_require

_G.require = function(name)
    -- 宿主自己的模块走原生 require
    if type(name) == "string" and name:match("^host%.") then
        return _native_require(name)
    end
    return Loader.Load(name)
end

--=========================================================================
-- ★ 契约发现模式：给 _G 装元表，未知全局自动返回 0 并记录
--
-- 用途：加载 tuning.lua（9581 行）这类大文件时，它可能引用几十个
-- 宿主尚未定义的全局常量。逐个补太低效且容易漏。
-- 自动发现能一次性跑完并输出**完整缺失清单**，比盲目猜测高效得多。
--=========================================================================
function Loader.DiscoverGlobals(fn)
    local discovered = {}
    local real_require_backup = _G.require

    local mt = {
        __index = function(t, k)
            if type(k) ~= "string" or k:match("^_") then return nil end
            if rawget(t, k) ~= nil then return rawget(t, k) end
            if k == "require" then return real_require_backup end
            discovered[k] = (discovered[k] or 0) + 1
            return 0
        end,
    }

    local saved = getmetatable(_G)

    setmetatable(_G, mt)
    local ok, err = pcall(fn)
    -- ★ 必须恢复**原来的**元表而不是直接置 nil ——
    --   万能兜底全局（07_universal）也挂在 _G 上，直接清会把它擦掉。
    --   实测踩过：开启兜底后仍报 "attempt to call global X (a nil value)"。
    setmetatable(_G, saved)
    return ok, err, discovered
end

return Loader
