--[[
==============================================================================
 28_assets.lua —— 资产加载器（TheSim 的 LoadAtlas / LoadPrefabs / LoadAnim 一族）
==============================================================================
为什么需要它（审计结论）
  审计前，`TheSim:LoadAtlas / LoadAssets / LoadPrefabs / LoadAnim` 在**全仓 0 命中**：
  原版脚本调它们时不是「什么都不发生」，而是 **attempt to call method (a nil value)**。
  其中 `TheSim:LoadPrefabs` 在原版里有 **34 处**调用、`UnloadPrefabs` **22 处**、
  `AddTextureToStreamingGroup` **137 处**（`skins_defs_data.lua` 整份就是这串调用）。

  没有这一层，「引擎」就只是「能跑预制体工厂」，不是「能加载资产」。

★★ 本模块的硬约束：**不做假实现**
  工程里已经有过一次教训（`23_atlas.lua` 的头注释）：`AtlasContains` 一律返回 false
  也能让上下游「不崩」，但值是错的，而且不进缺口清单 —— 那是**静默空实现**。
  所以这里每一条都要求「有真实数据落地」：

    LoadAtlas       → 真去读 atlas 索引（或真去解析 atlas XML 的 <Element u v w h>）
    LoadPrefabs     → 真去解析 prefab 文件（复用 Bootstrap 的加载器，带依赖递归）
    LoadAnim        → 真去读 anim_data/<build>.lua（里面有真实 UV 与矩阵）
    AddTextureTo…   → 真登记，并能按组号反查

  拿不到就**返回 false + 原因**，并计入 `Assets.Stats` 的失败计数 —— 不抛、不静默。

★ 为什么数据源是 `atlas_index/` 与 `anim_data/` 而不是 `data/`
  本机没装 DST（`data/` 不存在），但工程里已有两份**同版本**的导出物：
    · `atlas_index/*.idx`  由 tools/export_atlas_index.py 从 images.zip 导出（元素名）
    · `anim_data/*.lua`    由 tools/export_anim.py 从 anim/*.zip 导出（UV/矩阵/帧数）
  它们与游戏数据同源，是能机械核对的**真实**数据，不是编的默认值。

★ 路径与编码
  `atlas_index` / `anim_data` 都在 `06-引擎复刻/` 下，而**该目录名不含非 ASCII**，
  所以相对路径（cwd = 06-引擎复刻）在 Windows 上可以直接 io.open。
  仍保留「从 SourceDir 推算绝对路径」的兜底，但**相对优先**（与 23_atlas 一致）。
==============================================================================
]]

local Core  = require("host.01_core")
local Sim   = require("host.02_sim")
local Paths = require("host.00_paths")

local TheSim = Sim.TheSim
local Assets = {}
Sim.Assets = Assets

--=========================================================================
-- 0) 目录定位（相对优先，绝对兜底；两条都试过才算失败）
--=========================================================================
local function probe(dir, file)
    local f = io.open(dir .. "/" .. file, "r")
    if f then f:close() return true end
    return false
end

--- 找资产目录：先试相对（cwd=06-引擎复刻），再试从源码根推算的绝对路径。
--  ★ 不抛错：目录缺失时资产接口应当**如实返回 false**（并计入统计），
--    而不是让整个入口起不来 —— 但也不许静默（见 GetDirs 的返回值）。
local function find_dir(name, probe_file)
    local tried = {}
    local cands = { name }
    local ok, src = pcall(Paths.SourceDir)
    if ok and type(src) == "string" then
        -- <root>/dstsrc/scripts -> <root>/dstsrc -> <root>
        local root = Paths.dirname(Paths.dirname(src))
        cands[#cands + 1] = root .. "/06-引擎复刻/" .. name
        cands[#cands + 1] = root .. "/" .. name
    end
    for _, d in ipairs(cands) do
        tried[#tried + 1] = d
        if probe(d, probe_file) then
            return d, tried
        end
    end
    return nil, tried
end

local ATLAS_DIR, ATLAS_TRIED = find_dir("atlas_index", "_manifest.txt")
local ANIM_DIR,  ANIM_TRIED  = find_dir("anim_data",   "bee_build.lua")

--=========================================================================
-- 1) 状态与统计
--=========================================================================
local atlases   = {}     -- atlas 路径 -> { path, elements, rects, count, source, texture }
local anims     = {}     -- build 名   -> { name, symbols=n, anims=n, atlases=n, path }
local prefabs   = {}     -- 已加载的 prefab 名 -> true
local groups    = {}     -- 组号 -> 数组（保持登记顺序）
local group_idx = {}     -- 组号 -> { 路径 -> 下标 }（去重，137 处调用里重复很多）

local stats = {
    atlas_ok      = 0,
    atlas_fail    = 0,
    anim_ok       = 0,
    anim_fail     = 0,
    prefab_ok     = 0,
    prefab_fail   = 0,
    prefab_unload = 0,
    tex_registered = 0,
    tex_duplicate  = 0,
}

local last_error = nil      -- 最近一次失败原因（供调试与判据读取，不参与判定）

local function fail(what, why)
    last_error = string.format("%s: %s", what, tostring(why))
    return false, last_error
end

--- 与 `fail` 同义，但首值是 **nil** —— 给「返回下标」这类函数用。
--  ★ 为什么分开：`AddTextureToStreamingGroup` 的成功值是数字下标，
--    失败若返回 false，调用方 `if i ~= nil` 会把它当成「拿到了下标 0」吗？
--    不会，但 `if i then` 会。统一成 nil 才与「没有下标」这个语义一致。
--    （这条是被判据逼出来的：第一版返回 false，判据写 `bad ~= nil` 立刻红。）
local function fail_nil(what, why)
    fail(what, why)
    return nil, last_error
end

--=========================================================================
-- 2) 图集（atlas）
--=========================================================================
local function flat(atlas)
    return (atlas:gsub("/", "__"))
end

--- 解析真实 atlas XML（`<Element name u v w h/>`）。
--  本机 data/ 不存在，但这条分支必须有：它是 **LoadAtlas 的真实语义**，
--  只做索引名的话，「加载」与「查表」就没有区别了（那才是假实现）。
--  ⇒ 判据用一份**现造的** 2 元素 XML 覆盖它（tests.lua 里）。
local function parse_atlas_xml(text)
    local out = { elements = {}, rects = {}, count = 0 }
    -- 逐个 <Element .../> 取出，再逐属性取 —— 不假设属性顺序
    for tag in text:gmatch("<%s*Element%s+[^>]-/?>") do
        local name = tag:match('name%s*=%s*"([^"]*)"')
        if name ~= nil then
            local u = tonumber(tag:match('u%s*=%s*"([^"]*)"') or "")
            local v = tonumber(tag:match('v%s*=%s*"([^"]*)"') or "")
            local w = tonumber(tag:match('w%s*=%s*"([^"]*)"') or "")
            local h = tonumber(tag:match('h%s*=%s*"([^"]*)"') or "")
            if not out.elements[name] then
                out.elements[name] = true
                out.rects[name] = { u = u or 0, v = v or 0, w = w or 0, h = h or 0 }
                out.count = out.count + 1
            end
        end
    end
    out.texture = text:match('<%s*Texture%s+filename%s*=%s*"([^"]*)"')
    return out
end

--- 读 `.idx`（一行一个元素名，`#` 开头是注释）
local function parse_atlas_idx(text)
    local out = { elements = {}, rects = {}, count = 0 }
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            if not out.elements[line] then
                out.elements[line] = true
                out.rects[line] = nil       -- 索引里没有矩形，**如实为 nil**，不编 0,0,0,0
                out.count = out.count + 1
            end
        end
    end
    return out
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- TheSim:LoadAtlas(path) -> atlas表 | false, 原因
--  path 两种形态：
--    ① 已存在的 atlas XML 文件路径（相对 cwd）→ 真解析 <Element>
--    ② 逻辑图集名（如 "images/inventoryimages1.xml"）→ 查 atlas_index/<flat>.idx
function TheSim:LoadAtlas(path)
    if type(path) ~= "string" then
        stats.atlas_fail = stats.atlas_fail + 1
        return fail("LoadAtlas", "路径不是字符串（" .. type(path) .. "）")
    end

    local old = atlases[path]
    if old ~= nil then return old end       -- 幂等：重复加载返回同一份

    -- ① XML 文件
    if path:sub(-4):lower() == ".xml" then
        local text = read_all(path)
        if text ~= nil and text:find("<%s*Element") ~= nil then
            local a = parse_atlas_xml(text)
            a.path = path
            a.source = "xml"
            atlases[path] = a
            stats.atlas_ok = stats.atlas_ok + 1
            return a
        end
    end

    -- ② 逻辑名 → 索引
    if ATLAS_DIR == nil then
        stats.atlas_fail = stats.atlas_fail + 1
        return fail("LoadAtlas", "atlas_index 目录不存在（试过："
            .. table.concat(ATLAS_TRIED, " ; ") .. "）")
    end
    local idx_path = ATLAS_DIR .. "/" .. flat(path) .. ".idx"
    local text = read_all(idx_path)
    if text == nil then
        stats.atlas_fail = stats.atlas_fail + 1
        return fail("LoadAtlas", "既不是可解析的 XML，也没有索引文件 " .. idx_path)
    end

    local a = parse_atlas_idx(text)
    a.path = path
    a.source = "index"
    if a.count == 0 then
        stats.atlas_fail = stats.atlas_fail + 1
        return fail("LoadAtlas", "索引文件是空的（" .. idx_path .. "）")
    end
    atlases[path] = a
    stats.atlas_ok = stats.atlas_ok + 1
    return a
end

function TheSim:GetAtlas(path)
    return atlases[path]
end

function TheSim:HasAtlas(path)
    return atlases[path] ~= nil
end

--- TheSim:ReleaseAtlas(path) -> true|false
--  真实语义：把图集从内存里放掉。没加载过就没得放（返回 false，不静默成功）。
function TheSim:ReleaseAtlas(path)
    if atlases[path] == nil then return false end
    atlases[path] = nil
    return true
end

--=========================================================================
-- 3) 预制体（LoadPrefabs / UnloadPrefabs）
--=========================================================================
--- TheSim:LoadPrefabs(names) -> 成功数, 失败表
--  ★ 真去解析 prefab 文件（复用 `Core._prefab_loader`，它带依赖递归），
--    而不是「记一笔说加载了」。加载失败的**名字**要能拿出来，供判据与缺口清单用。
function TheSim:LoadPrefabs(names)
    local okn, failed = 0, {}
    if type(names) ~= "table" then
        stats.prefab_fail = stats.prefab_fail + 1
        return 0, { "<参数不是表:" .. type(names) .. ">" }
    end
    local loader = rawget(Core, "_prefab_loader")
    if type(loader) ~= "function" then
        stats.prefab_fail = stats.prefab_fail + 1
        return 0, { "<没有 prefab 加载器（Bootstrap.Setup 未完成？）>" }
    end
    for _, name in ipairs(names) do
        if type(name) ~= "string" then
            failed[#failed + 1] = tostring(name)
        elseif prefabs[name] then
            okn = okn + 1                     -- 已加载：幂等，不重复解析
        else
            local ok = loader(name)
            if ok and Core.Prefabs[name] ~= nil then
                prefabs[name] = true
                okn = okn + 1
                stats.prefab_ok = stats.prefab_ok + 1
            else
                failed[#failed + 1] = name
                stats.prefab_fail = stats.prefab_fail + 1
            end
        end
    end
    return okn, failed
end

--- TheSim:UnloadPrefabs(names) -> 卸载数
--  ★ 与真实引擎一致：把**定义**从内存里放掉；之后再 SpawnPrefab 会重新按需加载
--    （这是 Core.SpawnPrefab 已有的行为，本函数不改变它）。
function TheSim:UnloadPrefabs(names)
    if type(names) ~= "table" then return 0 end
    local n = 0
    for _, name in ipairs(names) do
        if type(name) == "string" and prefabs[name] then
            prefabs[name] = nil
            Core.Prefabs[name] = nil
            stats.prefab_unload = stats.prefab_unload + 1
            n = n + 1
        end
    end
    return n
end

function TheSim:IsPrefabLoaded(name)
    return prefabs[name] == true
end

function TheSim:GetLoadedPrefabs()
    local out = {}
    for k in pairs(prefabs) do out[#out + 1] = k end
    table.sort(out)
    return out
end

--=========================================================================
-- 4) 动画（LoadAnim）
--=========================================================================
--- TheSim:LoadAnim(build) -> 元信息表 | false, 原因
--  数据源 anim_data/<build>.lua（由 tools/export_anim.py 生成，含真实 UV/矩阵）。
function TheSim:LoadAnim(build)
    if type(build) ~= "string" then
        stats.anim_fail = stats.anim_fail + 1
        return fail("LoadAnim", "名字不是字符串（" .. type(build) .. "）")
    end
    local old = anims[build]
    if old ~= nil then return old end

    if ANIM_DIR == nil then
        stats.anim_fail = stats.anim_fail + 1
        return fail("LoadAnim", "anim_data 目录不存在（试过："
            .. table.concat(ANIM_TRIED, " ; ") .. "）")
    end

    local path = ANIM_DIR .. "/" .. build .. ".lua"
    local chunk, err = loadfile(path)
    if chunk == nil then
        stats.anim_fail = stats.anim_fail + 1
        return fail("LoadAnim", "打不开或编译失败 " .. path .. " : " .. tostring(err))
    end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then
        stats.anim_fail = stats.anim_fail + 1
        return fail("LoadAnim", "文件没有返回表（" .. path .. "）：" .. tostring(data))
    end

    local nsym, nanim, nframe = 0, 0, 0
    for _, s in pairs(data.symbols or {}) do
        nsym = nsym + 1
        -- 每个 symbol 的帧数也数出来：这是「UV 真的在读」的证据
        for _ in pairs(s.frames or {}) do nframe = nframe + 1 end
    end
    for _ in pairs(data.anims or {}) do nanim = nanim + 1 end

    local meta = {
        name = build,
        build = data.buildName or build,
        symbols = nsym,
        anims = nanim,
        frames = nframe,
        path = path,
        data = data,          -- 原始表（渲染要用 UV/矩阵，不能只留计数）
    }
    anims[build] = meta
    stats.anim_ok = stats.anim_ok + 1
    return meta
end

function TheSim:GetAnim(build)
    return anims[build]
end

function TheSim:HasAnim(build)
    return anims[build] ~= nil
end

--=========================================================================
-- 5) 纹理流式分组（AddTextureToStreamingGroup）
--=========================================================================
--- TheSim:AddTextureToStreamingGroup(group, path) -> 下标 | nil, 原因
--  原版 137 处调用（skins_defs_data.lua 全是这个）。真实语义是「把贴图登记到
--  某个流式加载组，返回它在组内的下标」。重复登记返回**已有下标**（不是新加一条）。
function TheSim:AddTextureToStreamingGroup(group, path)
    if type(group) ~= "number" then
        return fail_nil("AddTextureToStreamingGroup", "组号不是数字（" .. type(group) .. "）")
    end
    if type(path) ~= "string" or path == "" then
        return fail_nil("AddTextureToStreamingGroup", "路径不是非空字符串（" .. type(path) .. "）")
    end
    groups[group] = groups[group] or {}
    group_idx[group] = group_idx[group] or {}
    local i = group_idx[group][path]
    if i ~= nil then
        stats.tex_duplicate = stats.tex_duplicate + 1
        return i
    end
    local list = groups[group]
    list[#list + 1] = path
    group_idx[group][path] = #list
    stats.tex_registered = stats.tex_registered + 1
    return #list
end

function TheSim:GetStreamingGroup(group)
    local out = {}
    for i, p in ipairs(groups[group] or {}) do out[i] = p end
    return out
end

function TheSim:StreamingGroupCount(group)
    return #(groups[group] or {})
end

--=========================================================================
-- 6) 统计与诊断
--=========================================================================
function TheSim:AssetsStats()
    local na, nn, np, ng = 0, 0, 0, 0
    for _ in pairs(atlases) do na = na + 1 end
    for _ in pairs(anims) do nn = nn + 1 end
    for _ in pairs(prefabs) do np = np + 1 end
    for _ in pairs(groups) do ng = ng + 1 end
    local out = {}
    for k, v in pairs(stats) do out[k] = v end
    out.atlases_loaded = na
    out.anims_loaded = nn
    out.prefabs_loaded = np
    out.streaming_groups = ng
    out.last_error = last_error
    out.atlas_dir = ATLAS_DIR and ATLAS_DIR or "<缺>"
    out.anim_dir = ANIM_DIR and ANIM_DIR or "<缺>"
    return out
end

Assets.Stats = stats
Assets.Dirs = { atlas = ATLAS_DIR, anim = ANIM_DIR }

--=========================================================================
-- 7) 把「已加载的图集」接到 AtlasContains 前面
--=========================================================================
--  语义：**加载过的图集优先**（它是我们真解析出来的），否则退回 23_atlas 的索引查询。
--  这条接线是 LoadAtlas 有真实副作用的证据：LoadAtlas 之后再 AtlasContains 必须命中，
--  即使那个图集**根本不在 atlas_index 里**（判据用的正是这一点）。
local prev_atlas_contains = TheSim.AtlasContains
if type(prev_atlas_contains) == "function" then
    function TheSim:AtlasContains(atlas, imagename)
        local a = atlases[atlas]
        if a ~= nil then
            return a.elements[imagename] == true
        end
        return prev_atlas_contains(self, atlas, imagename)
    end
end

return Assets
