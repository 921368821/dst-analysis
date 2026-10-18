--[[
==============================================================================
 20_map.lua —— 真实地图层（瓦片网格 + 真实 TileGroupManager + Pathfinder）

 背景
   此前宿主的地图查询全是「宽松兜底」：
     `IsAboveGroundAtPoint` 永远 true、`GetTile` 永远 0、`Pathfinder:IsClear` 永远 true。
   于是**所有地形相关的逻辑分支从未被检验**，生物也永远「走在虚空上」——
   走到哪儿都算合法，走多远都不会被挡。

 做法：只补 C++ 那一侧，判定逻辑全部复用真实 DST 文件
   · `tilegroups.lua`（147 行）是**纯 Lua** 的：
     `IsLandTile / IsOceanTile / IsImpassableTile / IsInvalidTile / IsNoiseTile`
     全部由常量区间（LEGACY_WORLD_TILES_* / WORLD_TILES_*）推导，零引擎依赖。
     → 直接加载它，地形判定就是原版的，一个字节都不用改写。
   · `components/map.lua`（900+ 行）是纯 Lua 猴补丁：
     `IsAboveGroundAtPoint = TileGroupManager:IsLandTile(self:GetTileAtPoint(...))`，
     `IsPassableAtPoint` 再在其上叠平台/船的逻辑。
     → 只要宿主提供 `Map:GetTileAtPoint` / `Map:GetTile`，这些判定立刻变成**真的**。
   · 宿主唯一要自己写的是：瓦片数组、世界坐标 ↔ 瓦片坐标换算、Pathfinder。

 瓦片编号
   用 `GROUND` 的旧编号（GRASS=6 / FOREST=7 / OCEAN_COASTAL=201 …）。
   这与宿主的 WORLD_TILES 惰表一致（它 `__index` 先查 GROUND），
   所以 `WORLD_TILES.FOREST == GROUND.FOREST`，交叉比较不会错位。

 世界生成
   程序化 value-noise，**不是**原版 map/forest_map 的剧情生成器
   （那是独立一大块，见 06-引擎复刻/计划.md 的「世界生成深挖」方向）。
   这里只要一张「有真实瓦片编号、真实可通行语义、真实边界」的地形，
   让地形相关分支第一次被真正走一遍。
==============================================================================
]]

local Core = require("host.01_core")
local Loader = require("host.04_loader")

local M = {}

local SRC = Core.SourceDir

--=========================================================================
-- 1) TileGroupManager —— 真实 tilegroups.lua 的宿主载体
--=========================================================================
-- tilegroups.lua:1 是 `local TileGroupManager__index = getmetatable(TileGroupManager).__index`
-- 然后 `function TileGroupManager__index:IsLandTile(tile)`。
-- 所以宿主必须给出「一个表 + 元表 __index 指向一张方法表」的形状。
local TileGroups = {}
local TGM = {}
local TGMindex = {}

--- 新建一个瓦片组。组的成员 = 可选父组 + 自己登记的区间/单点。
function TGMindex:AddTileGroup(parent)
    local g = { parent = parent, ranges = {}, valid = {}, invalid = {} }
    return g
end
function TGMindex:SetValidTileRange(group, first, last)
    group.ranges[#group.ranges + 1] = { first, last }
end
function TGMindex:AddValidTile(group, tile)
    group.valid[tile] = true
end
function TGMindex:AddInvalidTile(group, tile)
    group.invalid[tile] = true
end

-- 下面这些 setter 在真实引擎里是「把某个组登记为默认组」。
-- 宿主把它们记下来供诊断（真实判定走 tilegroups.lua 的区间函数，不依赖这些）。
function TGMindex:SetIsLandTileGroup(g) M._defaults.land = g end
function TGMindex:SetIsOceanTileGroup(g) M._defaults.ocean = g end
function TGMindex:SetIsTransparentOceanTileGroup(g) M._defaults.transparent_ocean = g end
function TGMindex:SetIsImpassableTileGroup(g) M._defaults.impassable = g end
function TGMindex:SetIsInvalidTileGroup(g) M._defaults.invalid = g end
function TGMindex:SetIsNoiseTileGroup(g) M._defaults.noise = g end
function TGMindex:SetInvalidTile(t) M._special.invalid = t end
function TGMindex:SetDefaultImpassableTile(t) M._special.impassable = t end
function TGMindex:SetFakeGroundTile(t) M._special.fakeground = t end
function TGMindex:SetInvisibleTile(t) M._special.invisible = t end
function TGMindex:SetNoGroundOverlays(...) end
function TGMindex:SetIsTemporaryTileGroup(g) M._defaults.temporary = g end

M._defaults = {}
M._special = {}

--=========================================================================
-- 2) Map 数据层 —— 真实引擎里这是 C++ 对象
--=========================================================================
M.TILE = 4              -- 1 瓦片 = 4 世界单位（DST 惯例，见 prefabs/vaultroom_defs.lua:3）

local Map = {}
Map.TILE = M.TILE

M.WIDTH = 128
M.HEIGHT = 128

local tiles = {}        -- 扁平数组，索引 = cy * WIDTH + cx + 1
local default_tile = 6  -- GROUND.GRASS，Install 时再按真实常量修正

--- 世界坐标 → 瓦片坐标
-- ★ 约定：瓦片 cx 覆盖世界 x ∈ [ (cx-OX)*4 , (cx-OX+1)*4 )
--   取 OX = W/2，所以世界原点落在图中央，负坐标也是合法的陆地。
function Map:GetTileCoordsAtPoint(x, y, z)
    local cx = math.floor((x or 0) / self.TILE) + self.OX
    local cy = math.floor((z or 0) / self.TILE) + self.OY
    return cx, cy
end

--- Map:GetEntitiesOnTileAtPoint(x, y, z) -> 数组（这一格上的实体）
--
--  ★★ 为什么补它（P41 农业链路实测）：`prefabs/farm_plants.lua:192` 的
--     `OvercrowdingStressTest` 调它来数「同一格里有几株作物」，缺了就直接崩：
--         farm_plants.lua:193: attempt to call method 'GetEntitiesOnTileAtPoint' (a nil value)
--     ⇒ 作物的 `Growable:DoGrowth()` 每次推进都在压力测试里抛错 ⇒ **作物永远长不熟**。
--     这不是「少一个查询接口」，是「农业链路整条断在这里」。
--
--  真实引擎有空间索引；宿主没有，就**遍历存活实体按瓦片坐标比对**。
--  实体规模是几十到几百，线性扫一遍完全够用（与 `TheSim:FindEntities` 同一个取舍）。
--  ★ 返回的是**真实结果**，不是空表 —— 空表会让「同格作物数」恒为 0，
--    越拥挤越不长的那条逻辑就永远不触发（静默失真）。
function Map:GetEntitiesOnTileAtPoint(x, y, z)
    local out = {}
    local cx, cy = self:GetTileCoordsAtPoint(x, y or 0, z)
    if cx == nil or cy == nil then return out end
    for _, inst in pairs(Core.Spawned) do
        if inst:IsValid() and inst.Transform ~= nil
           and inst.Transform.GetWorldPosition ~= nil then
            local ix, iy, iz = inst.Transform:GetWorldPosition()
            if ix ~= nil then
                local ax, ay = self:GetTileCoordsAtPoint(ix, iy or 0, iz)
                if ax == cx and ay == cy then
                    out[#out + 1] = inst
                end
            end
        end
    end
    return out
end

function Map:GetTile(cx, cy)
    cx, cy = math.floor(cx or 0), math.floor(cy or 0)
    if cx < 0 or cy < 0 or cx >= self.WIDTH or cy >= self.HEIGHT then        -- 图外 = 不可通行（真实引擎里也是 invalid/impassable）
        return self.OUT_OF_BOUNDS or 65535
    end
    local v = tiles[cy * self.WIDTH + cx + 1]
    return v or default_tile
end

--- Map:IsOutOfBoundsAtPoint(x, y, z) -> boolean
---
--- ★ C5 配套：把「界外」做成**可问的一个问题**，调用方不必再靠
---   `IsOceanAtPoint == false` 去反推（那一步正是把界外当陆地的根源）。
---   原版 C++ 没有这个接口，但原版也**不需要**：它的地图边界外是真空，
---   Lua 层拿不到坐标就结束了。宿主是有限网格，必须显式给出这个语义。
function Map:IsOutOfBoundsAtPoint(x, y, z)
    local cx, cy = self:GetTileCoordsAtPoint(x, y, z)
    if cx == nil or cy == nil then return true end
    return cx < 0 or cy < 0 or cx >= self.WIDTH or cy >= self.HEIGHT
end

function Map:SetTile(cx, cy, tile)
    cx, cy = math.floor(cx or 0), math.floor(cy or 0)
    if cx < 0 or cy < 0 or cx >= self.WIDTH or cy >= self.HEIGHT then return end
    tiles[cy * self.WIDTH + cx + 1] = tile
end

function Map:GetTileAtPoint(x, y, z)
    local cx, cy = self:GetTileCoordsAtPoint(x, y, z)
    return self:GetTile(cx, cy)
end

function Map:GetSize() return self.WIDTH, self.HEIGHT end
function Map:GetTileSize() return self.TILE end

--- 瓦片中心的**世界坐标**
function Map:GetTileCenterPoint(cx, cy)
    return (cx - self.OX) * self.TILE + self.TILE / 2, 0,
           (cy - self.OY) * self.TILE + self.TILE / 2
end
--- 瓦片左上角的世界坐标（渲染用）
function Map:GetTileCornerPoint(cx, cy)
    return (cx - self.OX) * self.TILE, (cy - self.OY) * self.TILE
end

-- ★ IsVisualGroundAtPoint 在真实引擎里是 C++ 的，components/map.lua 会用它
--   判断「悬岩上方的可视地面」。宿主没有悬岩概念，等价于「是不是陆地」。
function Map:IsVisualGroundAtPoint(x, y, z)
    if self.IsAboveGroundAtPoint then
        return self:IsAboveGroundAtPoint(x, y, z)
    end
    return false
end

-- 这几个真实引擎里由 C++ 提供；宿主没有平台/船系统，按「没有」返回。
function Map:GetPlatformAtPoint() return nil end
function Map:GetNearestPlatformInDirection() return nil end
function Map:GetEntitiesAtPoint() return {} end
function Map:GetGroundEntity() return nil end
function Map:VisualizeGrid() end
function Map:SetUndergroundVisibility() end
function Map:SetOverhang() end

-- ★ 世界拓扑（TheWorld.topology）在真实引擎里由 C++ 生成：
--   把地图切成「地块节点（node）」并记录连通关系，地图查询里
--   FindNodeAtPoint / GetTopologyIDAtPoint / NodeAtPointHasTag 都靠它。
--   宿主没有拓扑生成器，正确的投影是「没有节点」——
--   返回 0，配合 `World.topology = { nodes = {}, ids = {} }`（见 02_sim），
--   `nodes[0]` 就是 nil，调用方自然走「没有节点」分支。
--   （不返回 0 的话，components/map.lua:1010 会 `attempt to call method
--     'GetNodeIdAtPoint' (a nil value)`，每 tick 一次。）
function Map:GetNodeIdAtPoint(x, y, z) return 0 end
function Map:GetTopologyIDAtPoint(x, y, z) return nil, 0 end
function Map:FindNodeAtPoint(x, y, z) return nil, 0 end
function Map:NodeAtPointHasTag(x, y, z, tag) return false end
function Map:GetNodeCenter(node_index) return nil end
function Map:GetRandomPointsForSite(...) return {}, {} end
function Map:GetRandomPointForSite(...) return nil end

--=========================================================================
-- 3) Pathfinder
--=========================================================================
-- 真实引擎里是 C++ A*。宿主实现在此层面只需要两件事：
--   · `IsClear` —— 两点之间的直线视线是否全程可通行（寻路/行为树大量使用）
--   · 墙体登记 —— 实体物理启停时的 AddWall/RemoveWall（宿主不参与碰撞，记为空操作）
local Pathfinder = {}

-- ★ 下面这几个函数被 `IsClear` 与 A* **共用** —— 判据必须只有一份，
--   否则会出现「A* 绕开了墙、而 IsClear 说没墙」这种自相矛盾。
--   （这条就是实测出来的：造墙后 IsClear 仍返回 true。）
--
-- ★★ 声明顺序有讲究：Lua 的 `local function f` 只在**声明之后**的作用域可见。
--    `point_ok` 要调 `tile_ok`，所以 `tile_ok` 必须写在它前面 ——
--    否则 `point_ok` 里的 `tile_ok` 会被编译成**全局查找**，运行时是 nil。

local walls = {}            -- 瓦片索引 -> true（AddWall 登记的动态障碍）
local function tidx(cx, cy) return cy * M.WIDTH + cx end

--- 某个瓦片能不能走。
--  ★ 判定一律复用**真实** `Map:IsPassableAtPoint`（它由
--    `components/map.lua` 的猴补丁提供，`20_map.lua:461` 挂上），
--    宿主不自己发明「什么算能走」。
local function tile_ok(cx, cy, allowocean)
    if cx < 0 or cy < 0 or cx >= M.WIDTH or cy >= M.HEIGHT then return false end
    if walls[tidx(cx, cy)] then return false end
    local x, y, z = Map:GetTileCenterPoint(cx, cy)
    y = y or 0
    local pass = false
    if type(Map.IsPassableAtPoint) == "function" then
        pass = Map.IsPassableAtPoint(Map, x, y, z) and true or false
    elseif type(Map.IsAboveGroundAtPoint) == "function" then
        pass = Map.IsAboveGroundAtPoint(Map, x, y, z) and true or false
    else
        pass = true                       -- 真图尚未安装：退回旧行为
    end
    if pass then return true end
    if allowocean and type(Map.IsOceanTileAtPoint) == "function" then
        return Map.IsOceanTileAtPoint(Map, x, y, z) and true or false
    end
    return false
end

--- 某个**世界坐标点**能不能站人（含 AddWall 登记的动态障碍）
local function point_ok(x, z, allowocean)
    if Map == nil or Map.GetTileCoordsAtPoint == nil then return true end
    local cx, cy = Map:GetTileCoordsAtPoint(x, 0, z)
    if cx < 0 or cy < 0 or cx >= M.WIDTH or cy >= M.HEIGHT then return false end
    return tile_ok(cx, cy, allowocean)
end

--- 两点之间的直线全程可通行？（采样步长 1 世界单位，瓦片 4 单位不会漏格）
local function seg_clear(x0, z0, x1, z1, allowocean)
    local dx, dz = (x1 or 0) - (x0 or 0), (z1 or 0) - (z0 or 0)
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist <= 0.5 then return point_ok(x1, z1, allowocean) end
    local steps = math.ceil(dist)
    for i = 0, steps do
        local t = i / steps
        if not point_ok((x0 or 0) + dx * t, (z0 or 0) + dz * t, allowocean) then
            return false
        end
    end
    return true
end

function Pathfinder:IsClear(x0, y0, z0, x1, y1, z1, caps)
    local map = M.Map
    if map == nil or map.IsPassableAtPoint == nil then return true end
    return seg_clear(x0, z0, x1, z1,
        type(caps) == "table" and caps.allowocean == true or false)
end

function Pathfinder:CanWalkOnPoint(x, y, z)
    local map = M.Map
    if map == nil or map.IsPassableAtPoint == nil then return true end
    return map:IsPassableAtPoint(x, y, z) and true or false
end
Pathfinder.IsPassableAtPoint = Pathfinder.CanWalkOnPoint

function Pathfinder:IsWaterAtPoint(x, y, z)
    local map = M.Map
    if map == nil or map.IsOceanTileAtPoint == nil then return false end
    return map:IsOceanTileAtPoint(x, y, z) and true or false
end

function Pathfinder:GetWalkableOffset() return nil end
function Pathfinder:HasStaticHoppablePlatform() return false end
function Pathfinder:AddStaticHoppablePlatform() end
function Pathfinder:RemoveStaticHoppablePlatform() end

--=========================================================================
-- 3.5) A* —— 真实现（原先四个函数全是空桩）
--
-- ★★ 为什么必须自己写：真实引擎里 A* 在 C++ 侧（`locomotor.lua:2964` 原话
--    「求解本身在 C++ 侧」），Lua 侧只**消费**结果。宿主没有 C++ 侧，
--    所以这四个空桩等于把原版一整套「绕障」能力直接关掉：
--      · `SubmitSearch` 恒 nil ⇒ `locomotor.lua:3680` 只打一句
--        `Print(VERBOSITY.DEBUG, "SUBMIT PATH FAILED")`
--      ⇒ `self.path.steps` 永远是 nil ⇒ 生物**只走直线**，撞墙就卡住。
--
-- ★★ 接口严格对齐原版消费方（`components/locomotor.lua`）：
--      · `SubmitSearch(x0,y0,z0,x1,y1,z1,pathcaps)` → **句柄**（非 nil = 提交成功）
--      · `GetSearchStatus(handle)` → `0`=计算中 / `1`=找到 / `2`=无路
--        （常量取 locomotor.lua:97-99：`STATUS_CALCULATING=0`、
--         `STATUS_FOUNDPATH=1`，`STATUS_NOPATH` 原版注释掉了但值是 2）
--      · `GetSearchResult(handle)` → `{steps = {{x=,y=,z=}, ...}}`，
--        **steps[1] 是起点、steps[#steps] 是终点**（locomotor.lua:2989 的
--        「`if #foundpath.steps > 2 then 采纳 else 丢弃走直线`」正是依赖这一点）
--      · `KillSearch(handle)` → 释放句柄（locomotor.lua:3022 在取到结果后必调）
--
-- ★ 原版是**异步**搜索（提交后每帧轮询 status）。宿主是**同步**求解：
--   提交时就算完，status 直接给 1 或 2。这对消费方完全等价——
--   它只是「一次立刻完成的搜索」，不会让 `WaitingForPathSearch()` 出错。
--
-- ★ 诚实登记：下面是宿主**仍做不到**的，不是忘记做
--   · `pathcaps.ignorewalls` —— 宿主没有「墙的碰撞体」概念，
--     只有 `AddWall(x,y,z)` 点登记（见下），所以 ignorewalls 无副作用。
--   · `pathcaps.ignorecreep` —— 宿主没有 creep 地皮，`AddCreepBlocker` 保持空操作。
--   · 平台 / 船 / 海洋寻路 —— 宿主没有平台与船系统。
--=========================================================================
local STATUS_CALCULATING = 0     -- 与 locomotor.lua:97 一致
local STATUS_FOUNDPATH   = 1     -- 与 locomotor.lua:98 一致
local STATUS_NOPATH      = 2     -- 原版注释掉的常量，值为 2

-- （`walls` / `tidx` / `tile_ok` 已在上面「共用判据」处声明，这里不重复声明 ——
--   重复声明会**遮蔽**前面的定义，让 IsClear 与 A* 各自持有一份墙表。）
local searches   = {}            -- handle -> {status=, steps=, expand=}
local next_h     = 0
local PATH_STATS = { submitted = 0, found = 0, nopath = 0,
                     expanded = 0, last_expand = 0, killed = 0 }
local MAX_EXPAND = 4000          -- 单次搜索展开上限（防病态输入拖垮一拍）

-- 二叉小顶堆（按 f 排序）
local function hpush(h, n)
    h[#h + 1] = n
    local i = #h
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].f <= h[i].f then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end
local function hpop(h)
    if #h == 0 then return nil end
    local top = h[1]
    local last = table.remove(h)
    if #h > 0 then
        h[1] = last
        local i, n = 1, #h
        while true do
            local l, r, m = i * 2, i * 2 + 1, i
            if l <= n and h[l].f < h[m].f then m = l end
            if r <= n and h[r].f < h[m].f then m = r end
            if m == i then break end
            h[i], h[m] = h[m], h[i]
            i = m
        end
    end
    return top
end

local DIRS = {
    { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 1 }, { 0, -1, 1 },
    { 1, 1, 1.41421356 }, { 1, -1, 1.41421356 },
    { -1, 1, 1.41421356 }, { -1, -1, 1.41421356 },
}

--- 目标点若落在不可通行格上，就近吸附（半径 r 内找最近可通行格）。
--  ★ 原版 C++ 寻路器也有这一步（否则「目标在墙里」会永远无路）。
local function snap(cx, cy, r, allowocean)
    if tile_ok(cx, cy, allowocean) then return cx, cy end
    for rad = 1, r or 3 do
        for dx = -rad, rad do
            for dy = -rad, rad do
                if math.abs(dx) == rad or math.abs(dy) == rad then
                    if tile_ok(cx + dx, cy + dy, allowocean) then
                        return cx + dx, cy + dy
                    end
                end
            end
        end
    end
    return nil, nil
end

--- 拉直（string pulling）：从当前点起，能一路直线看到的最远点作为下一个拐点。
--
--  ★ 为什么不是「去掉共线点」：A* 的拐点是**瓦片中心**（4 单位格的中心），
--    而起点/终点是**真实世界坐标**——两者几乎不可能严格共线。
--    实测：从 (0,-16) 到 (0,16)，瓦片中心在 x=2，纯共线判定会得到 4 个拐点，
--    路径呈锯齿状 ⇒ locomotor 采纳它（`steps > 2`）⇒ 角色走 S 形。
--    而原版在开阔地上是**丢弃路径走直线**（locomotor.lua:2989）。
--  ★ 拉直之后：能直连就只剩 {起点, 终点} **2 个 step** ⇒ 触发丢弃分支
--    ⇒ 行为与原版一致。
local function string_pull(pts, allowocean)
    if #pts <= 2 then return pts end
    local out = { pts[1] }
    local i = 1
    local guard = 0
    while i < #pts and guard < 1000 do
        guard = guard + 1
        local j = #pts
        while j > i + 1 and not seg_clear(pts[i].x, pts[i].z, pts[j].x, pts[j].z, allowocean) do
            j = j - 1
        end
        out[#out + 1] = pts[j]
        i = j
    end
    return out
end
local simplify = string_pull      -- 兼容旧名（内部只有一处调用）

local function astar(sx, sy, sz, gx, gy, gz, allowocean)
    local s_cx, s_cy = Map:GetTileCoordsAtPoint(sx, sy or 0, sz)
    -- ★ 不能写成 snap(Map:GetTileCoordsAtPoint(...), 3, allowocean)：
    --   Lua 里「不在参数列表末位」的函数调用只取**第一个**返回值，
    --   那样会变成 snap(cx, 3, allowocean) —— 参数整体错位一格。
    local rgx, rgy = Map:GetTileCoordsAtPoint(gx, gy or 0, gz)
    local g_cx, g_cy = snap(rgx, rgy, 3, allowocean)
    if g_cx == nil then return nil, 0 end
    s_cx = math.min(math.max(s_cx, 0), M.WIDTH - 1)
    s_cy = math.min(math.max(s_cy, 0), M.HEIGHT - 1)
    if not tile_ok(s_cx, s_cy, allowocean) then
        local nx, ny = snap(s_cx, s_cy, 2, allowocean)
        if nx == nil then return nil, 0 end
        s_cx, s_cy = nx, ny
    end

    local start_i, goal_i = tidx(s_cx, s_cy), tidx(g_cx, g_cy)
    local gscore, came, closed = {}, {}, {}
    local hx, hz = math.abs(g_cx - s_cx), math.abs(g_cy - s_cy)
    local open = {}
    gscore[start_i] = 0
    hpush(open, { i = start_i, cx = s_cx, cy = s_cy,
                  f = (hx > hz) and (hx - hz + 1.41421356 * hz) or (hz - hx + 1.41421356 * hx) })
    local expand = 0

    while #open > 0 and expand < MAX_EXPAND do
        local cur = hpop(open)
        if closed[cur.i] == nil then
            closed[cur.i] = true
            expand = expand + 1
            if cur.i == goal_i then
                -- 回溯
                local tiles, ti = {}, cur.i
                while ti ~= nil do
                    tiles[#tiles + 1] = ti
                    ti = came[ti]
                end
                local pts = {}
                for k = #tiles, 1, -1 do
                    local cx = tiles[k] % M.WIDTH
                    local cy = math.floor(tiles[k] / M.WIDTH)
                    local x, y, z = Map:GetTileCenterPoint(cx, cy)
                    pts[#pts + 1] = { x = x, y = y or 0, z = z }
                end
                pts[1]        = { x = sx, y = sy or 0, z = sz }
                pts[#pts]     = { x = gx, y = gy or 0, z = gz }
                return string_pull(pts, allowocean), expand
            end
            for _, d in ipairs(DIRS) do
                local nx, ny = cur.cx + d[1], cur.cy + d[2]
                if tile_ok(nx, ny, allowocean) then
                    -- 斜向不允许切角：两侧正交格都必须可走
                    if d[1] ~= 0 and d[2] ~= 0 then
                        if not (tile_ok(cur.cx + d[1], cur.cy, allowocean)
                            and tile_ok(cur.cx, cur.cy + d[2], allowocean)) then
                            nx, ny = nil, nil
                        end
                    end
                    if nx ~= nil then
                        local ni = tidx(nx, ny)
                        if closed[ni] == nil then
                            local ng = (gscore[cur.i] or 0) + d[3]
                            if gscore[ni] == nil or ng < gscore[ni] then
                                gscore[ni] = ng
                                came[ni] = cur.i
                                local ax = math.abs(g_cx - nx)
                                local ay = math.abs(g_cy - ny)
                                local hh = (ax > ay) and (ax - ay + 1.41421356 * ay)
                                                     or (ay - ax + 1.41421356 * ax)
                                hpush(open, { i = ni, cx = nx, cy = ny, f = ng + hh })
                            end
                        end
                    end
                end
            end
        end
    end
    return nil, expand
end

function Pathfinder:AddWall(x, _y, z)
    local cx, cy = Map:GetTileCoordsAtPoint(x, 0, z)
    walls[tidx(cx, cy)] = true
end
function Pathfinder:RemoveWall(x, _y, z)
    local cx, cy = Map:GetTileCoordsAtPoint(x, 0, z)
    walls[tidx(cx, cy)] = nil
end
function Pathfinder:AddCreepBlocker() end      -- 宿主没有 creep 地皮（诚实保留空操作）
function Pathfinder:RemoveCreepBlocker() end

function Pathfinder:SubmitSearch(x0, y0, z0, x1, y1, z1, pathcaps)
    -- ★ 句柄必须是**非 nil**：locomotor.lua:3683 用它判断提交成功。
    next_h = next_h + 1
    PATH_STATS.submitted = PATH_STATS.submitted + 1
    local allowocean = type(pathcaps) == "table" and pathcaps.allowocean == true or false
    local ok, steps, expand = pcall(astar, x0, y0, z0, x1, y1, z1, allowocean)
    if not ok or steps == nil then
        PATH_STATS.nopath = PATH_STATS.nopath + 1
        PATH_STATS.last_expand = type(expand) == "number" and expand or 0
        searches[next_h] = { status = STATUS_NOPATH, steps = nil,
                             why = (not ok) and tostring(steps) or "无可达路径" }
        return next_h
    end
    PATH_STATS.found = PATH_STATS.found + 1
    PATH_STATS.expanded = PATH_STATS.expanded + expand
    PATH_STATS.last_expand = expand
    searches[next_h] = { status = STATUS_FOUNDPATH, steps = steps }
    return next_h
end

function Pathfinder:GetSearchStatus(handle)
    local s = searches[handle]
    if s == nil then return nil end      -- 句柄失效：locomotor 会打印 LOST PATH SEARCH
    return s.status
end

function Pathfinder:GetSearchResult(handle)
    local s = searches[handle]
    if s == nil or s.steps == nil then return nil end
    return { steps = s.steps }
end

function Pathfinder:KillSearch(handle)
    if searches[handle] ~= nil then
        searches[handle] = nil
        PATH_STATS.killed = PATH_STATS.killed + 1
    end
end

function Pathfinder:GetPathTileIndexFromPoint(x, _y, z)
    local cx, cy = Map:GetTileCoordsAtPoint(x, 0, z)
    if cx < 0 or cy < 0 or cx >= M.WIDTH or cy >= M.HEIGHT then return 0 end
    return tidx(cx, cy)
end

--- 诊断：寻路到底在不在干活（数字要能被机械核对，不能只靠「看着能动」）
function M.path_stats() return PATH_STATS end
function M.path_reset_stats()
    PATH_STATS.submitted, PATH_STATS.found = 0, 0
    PATH_STATS.nopath, PATH_STATS.expanded = 0, 0
    PATH_STATS.killed, PATH_STATS.last_expand = 0, 0
end
function M.path_search_status() return STATUS_CALCULATING, STATUS_FOUNDPATH, STATUS_NOPATH end
function M.path_pending() local n = 0 for _ in pairs(searches) do n = n + 1 end return n end
function Pathfinder:GetDebugString()
    return string.format("[host A*] 提交%d 找到%d 无路%d 待回收%d 上次展开%d",
        PATH_STATS.submitted, PATH_STATS.found, PATH_STATS.nopath,
        M.path_pending(), PATH_STATS.last_expand)
end

M.Map = Map
M.Pathfinder = Pathfinder
M.TileGroupManager = TGM

--=========================================================================
-- 4) 程序化世界生成（value noise；确定性，不用 math.random）
--=========================================================================
local function hash01(x, y, seed)
    -- 三个大素数混合后取模；乘数 < 2^17 保证 (n * 48271) 不超 2^53，无精度损失
    local n = (x * 374761393 + y * 668265263 + seed * 1274126177) % 2147483647
    n = (n * 48271) % 2147483647
    return n / 2147483647
end

local function smooth(t) return t * t * (3 - 2 * t) end

local function valueNoise(x, y, scale, seed)
    local fx, fy = x / scale, y / scale
    local x0, y0 = math.floor(fx), math.floor(fy)
    local tx, ty = smooth(fx - x0), smooth(fy - y0)
    local v00 = hash01(x0, y0, seed)
    local v10 = hash01(x0 + 1, y0, seed)
    local v01 = hash01(x0, y0 + 1, seed)
    local v11 = hash01(x0 + 1, y0 + 1, seed)
    local a = v00 + (v10 - v00) * tx
    local b = v01 + (v11 - v01) * tx
    return a + (b - a) * ty
end

--- 多倍频叠加，返回 0..1
local function fbm(x, y, scale, seed, octaves)
    local sum, amp, norm, s = 0, 1, 0, scale
    for i = 1, (octaves or 3) do
        sum = sum + amp * valueNoise(x, y, s, seed + i * 17)
        norm = norm + amp
        amp = amp * 0.5
        s = s * 0.5
    end
    return sum / norm
end

--- 生成一张地形图
-- @param opts.force  强制全部瓦片（调试用）
-- @param opts.seed   噪声种子
function M.Generate(opts)
    opts = opts or {}
    local G = _G.GROUND or {}
    local W, H = M.WIDTH, M.HEIGHT
    local seed = opts.seed or 20261013
    local rng = opts.rng

    local T = {
        grass = G.GRASS or 6,
        forest = G.FOREST or 7,
        savanna = G.SAVANNA or 5,
        marsh = G.MARSH or 8,
        rocky = G.ROCKY or 3,
        dirt = G.DIRT or 4,
        imp = G.IMPASSABLE or 1,
        ocean_swell = G.OCEAN_SWELL or 203,
        ocean_coastal = G.OCEAN_COASTAL or 201,
    }

    tiles = {}
    local half = W / 2
    for cy = 0, H - 1 do
        for cx = 0, W - 1 do
            local t
            if opts.force then
                t = opts.force
            else
                -- 圆盘边界：越靠外越「水」，保证生物被自然困在图内
                local dx, dy = cx - half, cy - half
                local r = math.sqrt(dx * dx + dy * dy) / half
                local e = fbm(cx, cy, 17, seed, 3)          -- 地势
                local m = fbm(cx, cy, 11, seed + 991, 3)    -- 湿度
                local d = fbm(cx, cy, 6, seed + 3571, 2)    -- 细节

                if r > 0.95 then
                    t = T.ocean_swell
                elseif r > 0.88 then
                    t = T.ocean_coastal
                elseif r > 0.83 then
                    t = T.savanna                            -- 海岸草甸
                elseif e < 0.24 then
                    t = T.imp                                -- 深渊/裂隙（不可通行）
                elseif e > 0.80 then
                    t = T.rocky
                elseif m > 0.68 then
                    t = T.marsh
                elseif m > 0.52 then
                    t = T.forest
                elseif d > 0.62 then
                    t = T.savanna
                else
                    t = T.grass
                end
            end
            tiles[cy * W + cx + 1] = t
        end
    end

    -- 出生点保证是陆地：把中心 5×5 抹平为草地
    local c0x, c0y = math.floor(half) - 2, math.floor(half) - 2
    for cy = c0y, c0y + 4 do
        for cx = c0x, c0x + 4 do
            Map:SetTile(cx, cy, T.grass)
        end
    end
    M.LastSeed = seed
    return M
end

--- 统计各地形瓦片数量（诊断/报告用）
function M.TileStats()
    local G = _G.GROUND or {}
    local names = {}
    local counts = {}
    for name, id in pairs(G) do names[id] = name end
    for _, v in pairs(tiles) do counts[v] = (counts[v] or 0) + 1 end
    local out = {}
    for id, n in pairs(counts) do
        out[#out + 1] = { id = id, name = names[id] or ("#" .. tostring(id)), count = n }
    end
    table.sort(out, function(a, b) return a.count > b.count end)
    return out
end

--- 导出一张「什么地形」的字符图（终端里能直接看）
function M.ASCIIMap(maxw, maxh)
    local G = _G.GROUND or {}
    local ch = {
        [G.GRASS or 6] = ".", [G.FOREST or 7] = "T", [G.SAVANNA or 5] = ",",
        [G.MARSH or 8] = "~", [G.ROCKY or 3] = "^", [G.IMPASSABLE or 1] = "#",
        [G.OCEAN_COASTAL or 201] = "o", [G.OCEAN_SWELL or 203] = "O",
    }
    local W, H = M.WIDTH, M.HEIGHT
    local step = math.max(1, math.ceil(math.max(W, H) / (maxw or 64)))
    local rows = {}
    for cy = 0, H - 1, step do
        if not maxh or #rows < maxh then
            local line = {}
            for cx = 0, W - 1, step do
                line[#line + 1] = ch[Map:GetTile(cx, cy)] or "?"
            end
            rows[#rows + 1] = table.concat(line)
        end
    end
    return table.concat(rows, "\n")
end

--- 供外部（导出器）读取原始瓦片
function M.GetTiles() return tiles, M.WIDTH, M.HEIGHT end
function M.GetMap() return Map end

--- 找一个可通行的随机点（用给定 rng，默认 math.random）
function M.RandomWalkablePoint(radius, rng)
    rng = rng or math.random
    local can_pass = type(Map.IsPassableAtPoint) == "function"
    local can_ground = type(Map.IsAboveGroundAtPoint) == "function"
    for _ = 1, 200 do
        local x = (rng() * 2 - 1) * radius
        local z = (rng() * 2 - 1) * radius
        if can_pass and Map.IsPassableAtPoint(Map, x, 0, z) then
            return x, z
        elseif can_ground and Map.IsAboveGroundAtPoint(Map, x, 0, z) then
            return x, z
        end
    end
    return 0, 0
end

--=========================================================================
-- 5) 安装
--=========================================================================
M.Installed = false

function M.Install(opts)
    if M.Installed then return M end
    local G = _G

    -- ---- 5.1 常量前置（tilegroups.lua 依赖 GROUND_ISTEMPTILE 等）----
    G.TileGroups = G.TileGroups or {}
    local okConst = rawget(G, "LEGACY_WORLD_TILES_LAND_START") ~= nil
    if not okConst then
        Core.NoteGap("constants:not-loaded-before-map", "map-install")
    end
    if type(rawget(G, "GROUND")) ~= "table" then
        Core.NoteGap("GROUND:missing", "map-install")
    else
        default_tile = G.GROUND.GRASS or 6
    end

    -- ---- 5.2 TileGroupManager（先装宿主载体，再让真实文件覆盖判定）----
    setmetatable(TGM, { __index = TGMindex })
    G.TileGroupManager = TGM
    local okTG, errTG = Loader.LoadFile(SRC .. "/tilegroups.lua")
    if not okTG then
        Core.NoteGap("tilegroups.lua: " .. tostring(errTG):sub(1, 90), "map-install")
    end
    M.TileGroupManagerReady =
        type(TGMindex.IsLandTile) == "function" and TGMindex.IsLandTile ~= nil

    -- ---- 5.3 Map 数据对象 ----
    Map.WIDTH, Map.HEIGHT = M.WIDTH, M.HEIGHT
    Map.OX, Map.OY = math.floor(M.WIDTH / 2), math.floor(M.HEIGHT / 2)
    -- ★★★ C5（2026-10-18 P44）：越界瓦片必须映射成 **INVALID**，不是 IMPASSABLE。
    --
    --   旧写法 `OUT_OF_BOUNDS = GROUND.IMPASSABLE` 造成一个**语义塌陷**：
    --   越界点在 TileGroupManager 眼里是「有效但不可通行」——
    --       IsValidTileAtPoint(65535→旧:1) = true   ← 界外被当成"有效地块"
    --       IsLandTileAtPoint            = false
    --       IsOceanAtPoint               = false   ← 与陆地同值
    --   于是任何「不是海洋 ⇒ 是陆地」的写法都会把界外算成陆地；
    --   反过来任何「有效 ⇒ 能放东西」的写法会在界外放东西。
    --
    --   真 constants.lua:1065 里 GROUND.INVALID = 65535，且
    --   tilegroups.lua:50 的 IsInvalidTile 明确把 INVALID 与 impassable 分开判：
    --       IsInvalidTile = IsImpassableTile(tile) or tile == WORLD_TILES.INVALID
    --   ⇒ 越界用 INVALID 之后：
    --       IsValidTileAtPoint = false   ← 可区分「界外」与「陆地」
    --       IsLandTileAtPoint  = false
    --       IsOceanAtPoint     = false
    --       IsPassableAtPoint  = false   ← IsAboveGroundAtPoint 只认 land/ocean
    --   四个值**同时**正确，调用方才有可能分开处理。
    --
    --   ⚠️ 不能直接写 `G.GROUND.INVALID` 就完事：05_bootstrap 给 GROUND 装了
    --      「缺键就发号」的 __index（见 05_bootstrap.lua:577-591）。若真
    --      constants.lua 没加载成，读 INVALID 会**新发一个 id** ——
    --      那是个"看起来是 tile 的假号"，比越界本身更坏。
    --      ⇒ 显式校验：必须是数字、且不等于 IMPASSABLE、且不是发号器给的 0。
    do
        local imp = G.GROUND and G.GROUND.IMPASSABLE
        local inv = G.GROUND and G.GROUND.INVALID
        if type(inv) ~= "number" or inv == imp or inv == 0 then
            inv = (G.WORLD_TILES and type(G.WORLD_TILES.INVALID) == "number"
                   and G.WORLD_TILES.INVALID) or 65535
        end
        Map.OUT_OF_BOUNDS = inv
    end
    -- ★ 这里在**函数体内**，所以必须同时写 `_G` ——
    --   `05_bootstrap.lua:26` 的一次性拷贝（`for k,v in pairs(G) do _G[k]=v end`）
    --   在世界生成**之前**就跑完了 ⇒ 之后写 `G.Map` 不会更新 `_G.Map`。
    --   而 `components/map.lua:3` 就是 `local _SetTile = Map.SetTile`，
    --   即游戏代码在**加载时读全局 Map** ⇒ 只写 G.Map 的话它是 nil。
    --   本项目已在同一个坑上栽过三次（PrefabExists / SetFocalPoint / 这里），
    --   判据统一为：**凡是运行时才赋值的全局，一律写 _G**。
    G.Map = Map
    _G.Map = Map
    M.Map = Map

    local world = require("host.02_sim").World
    world.Map = Map
    world.Pathfinder = Pathfinder

    -- ---- 5.35 ★★ 广播 `worldmapsetsize`（真实引擎在设定地图尺寸时发）----
    --
    --   P41 实测缺口：`components/farming_manager.lua:149` 靠这个事件才去建
    --   `_nutrientgrid` / `_moisturegrid`（`InitializeDataGrids`）。宿主从不发它 ⇒
    --   `_nutrientgrid` 永远是 nil ⇒ 之后任何 `SetTile` 都会在
    --       farming_manager.lua:155 attempt to index upvalue '_nutrientgrid' (a nil value)
    --   直接崩掉**世界生成**（不是作物的错，是地形铺瓦片时就崩）。
    --
    --   时序也必须对：**地图尺寸先定、瓦片后铺** —— 真实引擎就是这个顺序，
    --   所以这里在 Generate 之前发，而不是生成完之后补。
    --   没有 PushEvent 的极简探针下静默跳过（此时也没有监听者，发了也没意义）。
    if world ~= nil and type(world.PushEvent) == "function" then
        local okEv, errEv = pcall(function() world:PushEvent("worldmapsetsize") end)
        if not okEv then
            Core.NoteGap("worldmapsetsize 广播失败: " .. tostring(errEv):sub(1, 90),
                         "map-install")
        end
    end

    -- ---- 5.4 让真实 components/map.lua 的猴补丁挂到宿主 Map 上 ----
    --   ★ 必须在 `_G.Map = Map` 之后：该文件第 3 行是 `local _SetTile = Map.SetTile`，
    --     它是**在加载时**抓取全局 Map 的。
    local okT, errT = Loader.LoadFile(SRC .. "/map/terrain.lua")
    if not okT then
        Core.NoteGap("map/terrain.lua: " .. tostring(errT):sub(1, 90), "map-install")
    end
    local okM, errM = Loader.LoadFile(SRC .. "/components/map.lua")
    if not okM then
        Core.NoteGap("components/map.lua: " .. tostring(errM):sub(1, 90), "map-install")
    end
    M.RealMapLuaAttached = type(Map.IsAboveGroundAtPoint) == "function"

    -- ---- 5.5 默认一张全草地图：保证不改变既有入口的行为 ----
    --   （旧入口此前拿到的就是「处处可通行」，换成真图由入口脚本显式调用 M.Generate）
    tiles = {}
    M.Generate({ force = default_tile })

    -- ---- 5.6 map.lua 里的几个全局函数在别处被直接调用 ----
    for _, fn in ipairs({
        "IsAboveGroundAtPoint", "IsWalkableAtPoint", "GetPlatformAtPoint",
        "GetTileCoordsAtPoint", "GetTile", "GetEntitiesAtPoint",
        "VisualizeGrid", "GetGroundEntity", "IsPassableAtPoint",
        "IsPointNearHole", "IsOceanAtPoint",
    }) do
        if G[fn] == nil and type(Map[fn]) == "function" then
            G[fn] = function(...) return Map[fn](Map, ...) end
        end
    end

    M.Installed = true
    return M
end

return M
