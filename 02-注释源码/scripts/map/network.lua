--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/network.lua（1078 行）
-- 模块：世界生成 / 地图生成用图结构（★ 地图图，不是网络图）
--
-- ★★★★★★ 【本文件核心机制清单】（【】= 机制，★ = 重点，⚠ = 疑似缺陷）
--   【Graph 类】地图图的容器。一个 Graph ≈ 一个 task / 一个区域。
--   【nodes{}】图内房间节点（字典 ⇒ pairs 遍历顺序不定 ⇒ GetRandomNode 的坑）。
--   【edges{}】图内【内部边】（房间与房间直接相连）。
--   【exit_edges{} / exit_nodes{}】跨图【出口边】—— ★ 「锁」的物理载体。
--   【story_depth】任务级进度标量（0 = 起点）。★ 缺省 -1 而非 0。
--   【SaveEncode】id → 索引重映射 + 颜色去重，把图压成可 JSON 化数据。
--   【LockGraph / UnlockGraph】按 story_depth 逐层解锁图，决定哪些区域开放。
--   【GetRandomNode】★ 依赖 pairs 顺序 ⇒ 影响可复现性（bug-patterns E4）。
--   【AddChild / GetChildren】父子图嵌套（离岛、洞穴等子区域）。
--   ⚠【与联机网络无关】★★ 本文件零命中任何 net_* / netvar / Shard API。
--
-- ★★★★★ 1. 最重要的一条警示：★ 本文件与「联机网络」毫无关系
--   · ★ grep 核实：本文件**零命中** 任何网络相关 API
--     （无 net_ / netvar / Network_ / Shard / c_net / net_bool 等）。
--     全文 1078 行**没有一行**与联机同步有关。
--   · 它出现的位置是 map/ 目录、文件名 network.lua，纯粹是历史命名遗留
--     —— Klei 内部把它称作 "network graph"（节点-边拓扑），
--     恰好与 network（网络）同词，中文翻译时最容易误解。
--   · ★ 与真正的联机网络层对比（完全不同的一套东西）：
--       本文件（地图图）        │ 联机网络层
--       ────────────────────────┼─────────────────────────────
--       Graph / Node / Edge     │ net_* / netvar / Network_*
--       WorldSim:AddChild 等     │ c_net_* / net_bool 等
--       map/network.lua          │ networking.lua, networkclientrpc.lua,
--       │                        │ shardnetworking.lua
--       worldgen 离线 VM 单机执行 │ 游戏主循环 + 服务端权威同步
--   · 本文件导出的全局 `Graph` 类，与 map/graphnode.lua 的全局 `Node` 类、
--     map/graphedge.lua 的 `Edge` 类构成一套**三角**：
--       Graph = 一批 Node 的容器（= 一个 task / 一个区域）
--       Node  = 一个房间 = 一个 Voronoi 胞元
--       Edge  = 两房间之间的连接（内部边 / 跨图 exit 边）
--
-- ★★★ 2. Graph 的数据结构（三层嵌套）
--   Graph                     ← 相当于"任务/区域"这一层（一个 task 一个 Graph）
--    ├─ .nodes{}              ← 本图内的房间节点（Node）
--    ├─ .edges{}              ← 本图内的内部边（Edge）
--    ├─ .exit_nodes{}/.exit_edges{}
--    │                          ← ★ 跨子图的连接边。一条 exit_edge 的
--    │                            node1 在本图、node2 在**兄弟图**，
--    │                            它就是"锁"的物理载体（LockGraph）。
--    ├─ .children{}            ← 子 Graph（region / task_node）
--    └─ .data{}               ← 位置/尺寸（Voronoi 阶段才填）
--
-- ★★★ 3. 两种边的语义差别（本文件最容易读错的地方）
--   · AddEdge（:349）  —— **图内**边，两端都在 self.nodes 里，
--                        同时调用 WorldSim:AddLink（:344）。
--   · LockGraph（:257）—— **跨图**边，存进 self.exit_edges，
--                        同时调用 WorldSim:AddExternalLink（:274）。
--   ★ storygen.lua:454/613/793-794/1170-1171 用的全是 LockGraph，
--     即"锁"是通过 exit_edge 表达的。锁的 key 信息挂在 lock 参数上，
--     但 ★ **lock.key 在本文件里被存下来后，从未被读取用于实际阻挡** ——
--     grep 核实：Graph 与 Edge 都不消费 lock.key 做逻辑判定。
--     ★ 真正的"锁"效果是：这条边存在 ⇒ 两个 Voronoi 胞元之间有路；
--       要"上锁"，靠的是给节点加 impassable 地块 / RoadPoison 标签
--       （storygen.lua:993、:1163），而不是靠 key 的值。
--     ⇒ **lock.key 是纯声明式的元数据**（供调试与未来使用）。
--     这也解释了为什么 E1「锁—钥匙表被覆盖」不直接导致崩溃：
--     它影响的是"哪些边被创建"的决策（storygen 的 availableKeys 判定），
--     而一旦边被创建，它就一定能通行。
--     ⇒ ★★ 于是不可达的真实机理是：**某个区域的入口 exit_edge
--       压根没被创建**（因为生成器认为你"有钥匙"，
--       但实际上那把钥匙在另一个不可达的分支里）。
--     这是拓扑级不可达，不是门锁级不可达。
--
-- ★★★ 4. ★★ 随机数
--   本文件消耗随机的点：:538 Graph:GetRandomNode（数学随机 + pairs 遍历
--     + while 重抽）、:564/:576 weighted_random_choice（util.lua:731）。
--   ★★ GetRandomNode(:534) 的实现是本库"随机选取"的标准范式，
--     也是**同一个坑的集中体现**：
--       local choice = math.random(GetTableSize(self.nodes)) -1
--       for k,v in pairs(self.nodes) do picked = v; if choice<=0 then break end; choice = choice-1 end
--     ⇒ 先用随机数选"第几个"，再用 **pairs 的遍历顺序**取第几个。
--     ⇒ 结果依赖 pairs 顺序 + 节点集合大小。同种子不同 hash ⇒ 不同地图。
--     ⚠ 且 :537 的 `while not picked or picked.data.entrance == true`
--       —— 若全图都是 entrance 节点 ⇒ **死循环**（无重试上限）。
--       实际不会发生（每个 task 至少 1 个非入口房间），故只记为隐患。
--
-- ★ 5. 交叉引用
--   Node 类 / AddNode ......................... map/graphnode.lua:107
--   Edge 类 / SaveEncode ...................... map/graphedge.lua
--   LockGraph 的调用方（★ 锁—钥匙决策全在这） ... map/storygen.lua:454/613/793
--   锁与钥匙表 ................................. map/lockandkey.lua:173
--   GetBackgroundRoom 的 room 来源 ............. map/rooms.lua
--   ApplyPoisonTag 的 flag 位定义 ............... C++（0x2 ForceConnected /
--                                              0x4 RoadPoison）
--   story_depth 的运行时消费 ................... components/grottowarmanager.lua:201
--============================================================
--
--【阅读导航】
--  §零   Graph 类构造（三层容器 + required_prefabs）    (9-61)
--  §一   Dump 调试打印                              (63-95)
--  §二 ★★ SaveEncode（★ id→索引 重映射 + 颜色去重）  (97-233)
--  §三   AddChild / RemoveChild / GetChildren        (236-255)
--  §四 ★★ LockGraph（★ 锁的物理载体）                (257-303)
--  §五 ★ AddEdgeByNode / AddEdge / GetEdge（★ 潜在全局泄漏）(305-419)
--  §六 ★★ 节点管理 AddNodeByNode / AddNode           (421-532)
--  §七 ★ 随机选点三兄弟（GetRandomNode/Exit/Entrance）(534-589)
--  §八 ★ CrosslinkRandom / MakeLoop / MakeHub        (591-656)
--  §九   RemoveNode / UpdateMinimumRadius           (658-677)
--  §十 ★ ConvertGround / Populate / PopulateVoronoi (679-762)
--  §十一 GlobalPrePopulate / GlobalPostPopulate      (764-777)
--  §十二 AddRequiredPrefab / GetRequiredPrefabs      (779-799)
--  §十三 ★★ ProcessInsanityWormholes（Oneshot 虫洞）(801-899)
--  §十四 ★ SwapOutWormholeMarkers                   (901-934)
--  §十五 ResolveCustomizationPrefabs / Randomization(936-969)
--  §十六 ApplyWormhole / SwapWormholesAndRoadsExtra   (972-1024)
--  §十七 ★ ApplyPoisonTag（★ 标签→flag 位映射）      (1026-1050)
--  §十八 SwapWormholesAndRoads                        (1052-1078)
--
--【★★ 全文件最重要的十条】
--  1. ★★★★★ **这不是网络代码**。map/network.lua 是地图生成图。
--     真正的联机网络在 networking.lua / networkclientrpc.lua /
--     shardnetworking.lua，符号前缀 net_ / c_net_ / Network_。
--  2. ★★ Graph 有**两套边**：图内 edges（AddEdge）与跨图 exit_edges
--     （LockGraph）。★ 读代码时必须先分清自己在看哪一种。
--  3. ★★ lock.key 从不被本文件读取 ⇒ 「锁」不是靠 key 值实现的，
--     而是通过"这条边存不存在"实现的。⇒ 不可达 = 边缺失，不是门打不开。
--  4. ★★ SaveEncode(:120) 用"两遍扫描"把字符串 id 映射成 1..N 索引：
--     第一遍收集所有 edge，再逐 node 把 edge.n1/n2 从 id 改成索引（:159-168）。
--     ⚠ 注意 :159-168 与 :180-189 的内层循环 `for edge_id,edge in ipairs(...)`
--     对**每条边都全量扫一遍** ⇒ O(N×E)。大型 task（数百节点）下这是
--     本文件最明显的性能热点（虽然总耗时仍在毫秒级）。
--  5. ★ :156/:177 `table.insert(encoded.story_depths, self.story_depth)`
--     —— ★★ 这里插的是 **Graph 的 story_depth**（即 task 级进度），
--     不是节点的。运行时 grottowarmanager.lua:201 拿它判断"同一区域"。
--  6. ★ GetRandomNode(:537) 的 `while ... picked.data.entrance == true`
--     无迭代上限 ⇒ 全 entrance 图会死循环（隐患，当前不可达）。
--  7. ★ GetRandomNodeForExit(:555) / ForEntrance(:567) 用
--     weighted_random_choice，★ 而 random_node_exit_weight == 0 的节点
--     被**完全排除**在候选之外（:558）。所以 START 节点（storygen.lua:1341
--     把权重设 0）永远不会被当成出入口 —— 这就是 START 被特殊保护的机制。
--  8. ★ ApplyPoisonTag(:1026) 把标签翻译成 C++ 位标志：
--     ForceDisconnected → ClearNodeLinks（断掉该节点的全部连线）；
--     ForceConnected → 0x2；RoadPoison → 0x4。★ 注意 flags 是**局部变量**
--     每节点从 0 重算，不是累加旧值。
--  9. ★ CrosslinkRandom(:592) 的 while 条件是 `crossLinkFactor > 0 且
--     iterations < 20` ⇒ **最多尝试 20 次**，不保证真的加够 factor 条边。
--     这是"尽力而为"而非"必须满足"。
--  10. ★ ProcessInsanityWormholes(:814) 的 NeighborNodes(:819) 用
--     `assert(nextNode == nil, "We already have a node from this task!")`
--     ⇒ ★★ 任何 OneshotWormhole 节点若在本图内有多于一个内部邻居
--     （crosslink / MakeLoop 都可能造成），**直接 assert 崩溃**。
--     这是本文件唯一一处"宁死不屈"的设计，且被 :846 的双邻居断言包围。
--============================================================
-- ★★★★★★★ 头号警示（务必先读）：★ 本文件与「联机网络」毫无关系
--   · ★ grep 核实：本文件**零命中**任何网络 API
--     （无 net_ / netvar / Network_ / c_net / net_bool / Shard / IsRealtimeHub 等）。
--   · 全文 1078 行**没有一行**与联机同步有关。
--   · 它叫 network.lua 只是历史命名：Klei 内部称之为 network graph
--     （节点-边拓扑），恰好与 network（网络）同词，中文最易误解。
-- ★★ 真正的联机网络层是完全不同的另一套：
--     networking.lua / networkclientrpc.lua / shardnetworking.lua
--     符号前缀 net_ / netvar / c_net_ / Network_*。
-- ★★ 本文件导出的是 **Graph** 类（全局），配套：
--     map/graphnode.lua 的 **Node**、map/graphedge.lua 的 **Edge**。
--   ⇒ 一套三角：Graph = 容器（≈ 一个 task/区域），Node = 一个房间，Edge = 连接。
require "class"
-- ★ Edge 类：地图图里的边（★ 见 map/graphedge.lua，仅 50 余行）。
require "map/graphedge"
-- ★ Node 类：一个房间 = 一个 Voronoi 胞元（map/graphnode.lua:107）。
require "map/graphnode"
-- ★ extents：GetMinimumRadiusForNodes（graphnode/Graph:UpdateMinimumRadius 用）。
-- ★★ 本文件唯一「实际用到」它的行是 :669。
require "map/extents"
-- ★ terrain：地形过滤表（map/terrain.lua）。
-- ★★ 本文件并未直接读它 ⇒ ★ 仅是「让地图目录的加载顺序固定」的副作用依赖。
require "map/terrain"
-- ★ Rooms：房间模板库（map/rooms/*.lua 的汇总入口）。
-- ★ 唯一使用点：:760 GetRoomForName → Rooms.GetRoomByName。
local Rooms = require "map/rooms"
-- ★ PrefabSwaps：prefab 改名/停用映射（★ 不在本仓库 Lua 内，外部模块）。
-- ★ 使用点：:939 ResolveCustomizationPrefab、:958/:960 Is/ResolveRandomizationPrefab。
local PrefabSwaps = require("prefabswaps")

-- ══════════════ ★★ Graph 类构造：三层容器 ══════════════
-- ★★★ 本类的一个 Graph 有五组子结构，务必分清：
--   ① .children{}     —— 子 Graph（一个 task 一个 Graph；区域再套一层）
--   ② .nodes{}        —— 本图内的房间节点（Node）
--   ③ .edges{}        —— ★ 本图**内部**的边（AddEdge 加）
--   ④ .exit_nodes{} / .exit_edges{} —— ★ **跨图**的边（LockGraph 加）
--   ⑤ .data{}         —— 位置/尺寸（★ Voronoi 阶段之前全是默认值）
-- ★★★ ③ vs ④ 是本文件最容易读错的地方：
--   「图内边」与「跨图边」语义完全不同，见 §四 LockGraph 的详细说明。
-- ★★ 典型结构（★ 亲手画一遍就懂了）：
--   rootNode (Story 的根图)
--    ├─ children: {"ForestTask"(Graph), "CaveTask"(Graph), "LOOP_BLANK1"(Graph)}
--    └─ exit_edges: { "ForestTask->CaveTask" = Edge(ForestTask的某节点, CaveTask的某节点, lock) }
--   ForestTask (Graph)
--    ├─ nodes: {"ForestTask:0:Forest"(Node), "ForestTask:1:Marsh"(Node), "START"(Node), …}
--    ├─ edges: {"edge0" = Edge(node0, node1), …}   ← 房间之间串联
--    └─ exit_edges: {}                               ← 与别的 task 的连接
Graph = Class(function(self, id, args)
-- ★ self.id：全局唯一（★ 由调用方保证，见 :241-242 的 assert）。
	self.id = id
	--print("Graph",id, args.parent,  args.data,  args.nodes,  args.edges,  args.exit_nodes,  args.exit_edges,  args.default_bg)
    -- Is this graph inside another graph
-- ★★ self.parent：父 Graph。★ rootNode 没有父（nil）。
--   ★ 二层结构：Story.rootNode → 每个 task 的 Graph。
    self.parent =  args.parent or nil
-- ★★ if self.parent then self.parent:AddChild(self) ——★ 反向注册。
--   ★★ 于是「建子图」只需传 parent 参数，不必再手工 AddChild。
--   ★ 调用点：storygen.lua:770 / 1156 / 1284 都是这个模式。
    if self.parent then
    	self.parent:AddChild(self)
    end

    -- Do we have any child graphs
-- ★ self.children{}：★ 子图字典（key = child.id）。
-- ★★ 注意是**字典**不是数组 ⇒ ★ 遍历用 pairs ⇒ 顺序不定（见 :253 GetChildren）。
    self.children =  args.children or {}

    -- Nodes within a graph may have cross linking
-- ★★ self.nodes{}：★ 本图内的房间节点。★ 本文件最核心的容器。
--   ★★ 同样是字典 ⇒ ★ 遍历顺序不定 ⇒ ★ 这就是下面 GetRandomNode 的坑。
    self.nodes =  args.nodes or {}
    -- keep a track on the internal edges
-- ★ self.edges{}：★ **图内**边。★ 与 exit_edges 分开存。
    self.edges =  args.edges or {}

    -- These nodes connect this subgraph to other graphs by Edges
-- ★ exit_nodes{}：★ 出现在本图 exit 边上的节点。
--   ★★★ 为什么单独存一份而不是复用 nodes：
--     ★★ 因为同一条 exit 边的 node2 **不在** self.nodes 里（在兄弟图里），
--       ★★ 而 AddEdgeByNode(:321-329) 会自动把不在 nodes 里的节点补进来——
--         ★★ 那是给「图内边」准备的。对 exit 边不能这么做，
--           ★★ 否则会把兄弟图的节点「收编」到本图，造成拓扑污染。
--   ★★ 于是 exit_nodes 是「只记不收」的旁路索引。★ 关键设计。
    self.exit_nodes =  args.exit_nodes or {}
-- ★ exit_edges{}：★★ 「锁」的物理载体。★ 详见 §四。
    self.exit_edges =  args.exit_edges or {}

    -- Data
    --self.data = data

	-- Used as a logical representation of progression
-- ★★★ story_depth：★ **任务级**的进度标量（0 = 起点，递增 = 解锁顺序）。
--   ★★ 它挂在 **Graph** 上而不是 Node 上 ⇒ 「一个 task 的所有房间共享一个深度」。
--   ★★ 赋值点：storygen.lua:306/440（RestrictNodesByKey）与 :504/601（LinkNodesByKeys）。
--   ★★ 落盘：:156/:177 → encoded.story_depths。
--   ★★ 运行时消费：components/grottowarmanager.lua:201（判断相邻是否同区域）、
--     components/area_trigger.lua:24（按深度切分故事）。
--   ★★★ 缺省 -1（不是 0）⇒ ★★ 可以用它区分「未参与进度链」与「是起点」。
--     storygen.lua:306 显式把起点设成 0，其余在链接过程中 +1。
	self.story_depth = args.story_depth or -1

    -- Search
-- ★ self.visited = false：搜索用标记。
-- ★★ 本文件**没有任何 BFS/DFS 会读它**（★ grep 核实 visited 只在此赋值）。
--   ⚠ 疑似缺陷（残留字段）：ConnectivitySearch 类的逻辑已不存在，字段成了化石。
    self.visited = false

-- ★★ self.data 的初值：★ 位置/尺寸全是 0，value = args.default_bg。
--   ★★ 关键：**构造时位置全是 0**，真正的坐标由 C++ WorldSim 在
--     Voronoi 阶段回填（storygen.lua:684 WorldSim:GetSite）。
--   ★★ 所以读 Graph 的 data.position 在生成早期只会拿到 0。
--   ★ value = args.default_bg：★ 这个 Graph 的「默认地块」，
--     传给 storygen.lua:1288 的 WorldSim:AddChild 作底色。
--   ★ background=args.background：★ 胞元外圈用的背景房间名。
    self.data = {position={x=0,y=0},old_pos={x=0,y=0}, width=0, height=0, size=0, value= args.default_bg, background=args.background}

-- ★ room_tags：★ 该 Graph 所有房间节点共用的标签
--   （storygen.lua:1035/1070/1133/1324 的 ArrayUnion 第二参数）。
    self.room_tags = args.room_tags

-- ★ colour：★ 调试可视化的 RGBA，缺省红色（r=1,g=0,b=0）。
--   ★★ 会写进 topology 并在小地图/调试视图里显示 ⇒ ★ 重要的调试通道。
    self.colour = args.colour or {r=1,g=0,b=0,a=1}

	-- a list of layouts to be distributed amongst children
-- ★★ set_pieces / random_set_pieces：★ 该 Graph 要放的静态场景件。
--   ★ 来源：storygen.lua:1284 从 task 搬运，
--     ★★ 或 level.lua:184/210 在 ChooseSetPieces 阶段挂到 task 上。
--   ★ 消费：storygen.lua:225/263 InsertAdditionalSetPieces。
	self.set_pieces = args.set_pieces
	self.random_set_pieces = args.random_set_pieces
-- ★ maze_tiles / maze_tile_size：竞技场迷宫的格子内容表与格子边长。
	self.maze_tiles = args.maze_tiles
-- ★★ 与 :48 同，搬运自 task（map/task.lua:28-29）。
	self.maze_tile_size = args.maze_tile_size
	-- print("####New node!! ",self.id, self.maze_tiles)
	-- dumptable(self.maze_tiles,1)
-- ★★★ MIN_WORMHOLE_ID = 2300000 ——★ 虫洞实体的 ID 起始值。
--   ★★ 为什么是 2300000 这个魔数：★ 世界生成阶段还没有任何实体，
--     ★★ 而虫洞配对需要一个「互相指向的 ID 对」。
--     ★★ 选一个大基数是为了**避免与后续生成的实体 GUID 冲突**。
--   ★★ 递增方式：:878/:930/:986 每次 +2（一对虫洞占 2 个连续 ID）。
--   ★★ ⚠ 硬编码 2300000 且**无上限检查**：
--     ★★ 若虫洞数量超过 (2^31-2300000)/2，会溢出。
--     ★★ 实际不可能到（世界最多几千个虫洞），但这是「魔数 + 无护栏」的典型。
--   ★★ 跨文件共享：storygen.lua:78 把 wormhole_prefab 挂到 rootNode 上，
--     ★★ 本文件 :53 声明 wormholeprefab = nil，二者对上了。
	self.MIN_WORMHOLE_ID = 2300000
    self.wormholeprefab = nil

-- ★★ required_prefabs{}：★ 该 Graph 内**所有房间**要求必须出现的 prefab 计数表。
--   ★★ 累加点有两处：
--     · :56-60 构造时从 args.required_prefabs 加（task 级的）
--     · :452-456 AddNodeByNode 时从 node.data.required_prefabs 加（房间级的）
--   ★★★ → Graph 级 + 房间级**两层累加**，再由 :786 GetRequiredPrefabs
--     递归合并所有子 Graph ⇒ ★★ 这是三重来源求和的「来源 2」的内部实现。
--   ★★ 最终校验在 forest_map.lua:961-974。
    self.required_prefabs = {}
    if args.required_prefabs ~= nil then
-- ★ for i,prefab in ipairs(args.required_prefabs) ——★ task 级清单。
--   ★ 来源：map/task.lua:33 → storygen.lua:1284 Graph(required_prefabs=task.required_prefabs)。
        for i,prefab in ipairs(args.required_prefabs) do
            self:AddRequiredPrefab(prefab)
        end
    end
-- ══════════════ 构造结束 ══════════════
end)

------------------------------------------------------------------------------------------
---------             Utility                   --------------------------------------
------------------------------------------------------------------------------------------

-- ══════════════ Dump：递归调试打印 ══════════════
-- ★★ 唯一会打印**全图结构**的函数。★ 用法：topology_save.root:Dump()
--   （storygen.lua:1402 的注释掉的调用）。
-- ★★ 它也打印 exit 边两端的 graph.id（:87）⇒ ★ 排查「谁连谁」最快的工具。
function Graph:Dump(depth)
	if depth == nil then
		depth = ""
	end

-- ★ 只有有父图才打印 Parent 行。
	if self.parent then
		print(depth..self.id.." Parent: "..self.parent.id)
	end

	print(depth..self.id.." Nodes: "..GetTableSize(self.nodes))
	for k,v in pairs(self.nodes) do
	    print(depth.."     Node: ",k, "Data:", v.data)
	end
	print(depth..self.id.." Edges: "..GetTableSize(self.edges))
	for k,v in pairs(self.edges) do
	    print(depth.."     Edge: ",k, v.node1.id,"-->",v.node2.id)
	end

	print(depth..self.id.." Exits: "..GetTableSize(self.exit_edges))
	for k,v in pairs(self.exit_edges) do
-- ★★★ 打印 exit 边时特意带上 `v.node1.graph.id` ——
--   ★★ 这是本文件唯一能看出「跨图连接」的地方，非常有用。
--   ★★ 普通边（:82）不打印 graph.id（因为必然同图）。
	    print(depth.."     Exit: ",k,v.node1.id.."("..v.node1.graph.id..")","-->",v.node2.id.."("..v.node2.graph.id..")")
	end

	print(depth..self.id.." Children: "..GetTableSize(self.children))
	for k,v in pairs(self.children) do
	    print(depth.."     Child: ",k)
	    v:Dump(depth.."      ")
	end
end

------------------------------------------------------------------------------------------
-----------             SAVE/LOAD                   --------------------------------------
------------------------------------------------------------------------------------------

-- ══════════════ ★★ EncodeColour：颜色去重 ══════════════
-- ★★★ 为什么要去重：★ 一张 425×425 的地图有几百个节点，
--   ★★ 若每个节点都存一份 {r,g,b,a} 四元组，savedata 会膨胀。
--   ★★ 实际颜色种类只有十几种（每个 task 一个）⇒ 去重收益极大。
-- ★★ 算法：线性扫描 encoded.colours，找到相同则替换为下标。
--   ★★ 复杂度 O(种类数) = O(10~60)，可忽略。
function EncodeColour(item, encoded)
	local found = false
	if #encoded.colours > 0 then
		for k,colour in ipairs(encoded.colours) do
-- ★★ 逐分量比较 r/g/b/a。★ 注意用 `colour.a == item.c.a` 而非 a==item.a，
--   ★★ 因为此时 item.c 已经被替换成颜色表的索引了（:108/:116）。
--   ★★ 这是个**顺序依赖**的写法：读起来容易困惑。
			if colour~= nil and colour.a == item.c.a and colour.r == item.c.r and
									colour.g == item.c.g and colour.b == item.c.b then
				found = true
-- ★★ item.c = k ——★ 把颜色对象换成它在 colours 数组里的下标。
--   ★★ 副作用：调用方的表被**就地修改**。★ 所以 SaveEncode 不可重复调用。
				item.c = k
				break
			end
		end
	end

-- ★★ if found == false then —— 新颜色。
	if found == false then
		table.insert(encoded.colours, item.c)
-- ★★ item.c = #encoded.colours —— 新颜色的下标。
--   ★★ ⚠ 这里有个隐蔽 bug 面：若某颜色恰好等于「新表长度」时的下标，
--     ★★ 由于是先 insert 再取长度，下标总是有效的。✔ 顺序正确。
		item.c = #encoded.colours
	end
end

-- ══════════════ ★★ SaveEncode：图 → savedata 的序列化 ══════════════
-- ★★★ 这是本文件**唯一影响存档体积**的函数。
--   输入：map = {width=…, height=…}
--   输出：encoded = {nodes[], edges[], ids[], story_depths[], colours[]}
-- ★★ 编码的核心目标：**把字符串 id 换成 1..N 的整数下标**。
--   ⇒ 存档里没有 "ForestTask:0:Forest" 这种长字符串，只有整数。
--   ⇒ 省下的字节数在几百节点 × 每 id 30 字符的规模下非常可观。
-- ★★ 消费：forest_map.lua:587 `topology_save.root:SaveEncode({width,height},
--   save.map.topology)`，之后 :588 CreateNodeIdTileMap。
function Graph:SaveEncode(map, encoded)

	--print ("Encoding: ".. self.id)

-- ★★★ if encoded.nodes == nil then ——★ 只在**最外层**初始化。
--   ★★ 递归调用（:193 child:SaveEncode(map, encoded)）会带着同一个 encoded，
--     ★★ 所以判据是「第一次进来」而不是「自己是 root」。
--   ★★★ 这个技巧保证了：**整个图共用一个扁平化的编码表**。
--   ★★ 这就是为什么节点的 id 映射是全局的（不是「每图一份」）。
	if encoded.nodes == nil then
		encoded.nodes = {}
		encoded.edges = {}
		encoded.ids = {}
		encoded.story_depths = {}
		encoded.colours = {}
	end


-- ★★ edge_ids{}：★ 收集边在 encoded.edges 里的下标。
--   ★★ ⚠ 疑似缺陷：edge_ids 被填充（:139/:148）但**从未被读取**。
--     ★★ 纯死变量。★ 推测原本想做「边 id 交叉引用」但没实现完。
	local edge_ids = {}
	--print("\tExits: "..GetTableSize(self.exit_edges))
-- ★★ 第一段：编码 **exit 边**（跨图边）。
--   ★★ 为什么 exit 边先编码：★ 因为它们的 node2 属于**别的图**，
--     ★★ 那些图还没被遍历到 ⇒ 若等对方编码完再回头，
--       ★★ 跨图边的两个端点就不在同一遍扫描里了。
--   ★★★ 于是「先 exit 后 internal」是这个算法能工作的前提。
	for id,edge in pairs(self.exit_edges) do
-- ★★ edge:SaveEncode(map) ——★ 委托给 Edge 类（map/graphedge.lua）。
--   ★ 返回 {n1=node1.id, n2=node2.id, c=colour, …} —— ★ 此时 n1/n2 仍是字符串。
		local encoded_edge = edge:SaveEncode(map)
-- ★ EncodeColour：★ 边也有颜色（默认继承 Graph 的 colour，:331）。
		EncodeColour(encoded_edge, encoded)
-- ★★ 入表（此时端点还是字符串 id）。
		table.insert(encoded.edges, encoded_edge)
-- ★★ 记录下标（★ 但 edge_ids 之后再也没被用过，见 :133）。
		table.insert(edge_ids, #encoded.edges)
	end


-- ★★ 第二段：编码**图内边**（internal edges）。★ 结构与上面完全相同。
	--print("\tGot "..GetTableSize(self.edges) .." edges")
-- ★★ for id,edge in pairs(self.edges) ——★★ pairs！顺序不定。
	for id,edge in pairs(self.edges) do
-- ★★ 同 :136。
		local encoded_edge = edge:SaveEncode(map)
-- ★ EncodeColour。
		EncodeColour(encoded_edge, encoded)
-- ★ 入表。
		table.insert(encoded.edges, encoded_edge)
-- ★ 记录下标（同 :139，死变量）。
		table.insert(edge_ids, #encoded.edges)
	end

-- ★★★ 第三段：编码 **exit_nodes**（出现在 exit 边上的本图节点）。
--   ★★★ 这是最容易漏读的一段：★ .nodes 之外的节点也要编码！
--   ★★ 推论：★ 一个节点要么在 .nodes 里，要么在 .exit_nodes 里，
--     ★★ 或者**两边都有**（既参与图内边又参与跨图边）。
--   ★★ ⚠ 若两边都有，★ 这个节点会被**编码两次** ⇒
--     ★★★ savedata 里出现重复节点！★ 而 :162 的重映射逻辑会把
--       后一条边的端点指向**第二个**下标 ⇒ 第一个副本成为孤儿。
--     ★★★ 这是一个真实的潜在缺陷（是否触发取决于 GetNodeById/add 的时序）。
--     ⚠ 推理依据：:155 的 table.insert(encoded.ids, id) 无查重。
	for id,node in pairs(self.exit_nodes) do --self.nodes) do
-- ★ node:SaveEncode(map) ——★ 委托 Node 类（graphnode.lua:142）。
--   ★★ 返回 {x, y, cent, poly[], type, c, area, tags} —— ★★ 注意 poly 是多边形顶点！
--   ★★★ 这意味着**存档里存了每个胞元的完整边界**，而不是只存站点坐标。
--     ★★★ 因为 Voronoi 胞元不是规则图形（做过 100 次 Lloyd 松弛），
--       ★★★ 必须存边界才能在运行时还原房间形状。
		local encoded_node =  node:SaveEncode(map)
-- ★ EncodeColour：★ 节点颜色也是去重的。
		EncodeColour(encoded_node, encoded)

-- ★★ table.insert(encoded.ids, id) ——★★ **id → 下标映射的逆表**。
--   ★★ encoded.ids[i] 就是第 i 个节点的字符串 id。
--   ★★ 运行时靠它把存档节点反查回原始 id
--     （forest_map.lua:597/598 就是用它：GetSiteArea(save.map.topology.ids[idx])）。
		table.insert(encoded.ids, id)
-- ★★ table.insert(encoded.story_depths, self.story_depth)
--   ★★★ 极容易读错：**插的是 Graph 的 story_depth**（:34 的那个），
--     ★★ **不是**节点的。★ 一个 Graph 的所有房间共享同一个深度值。
--   ★★ 这正是 grottowarmanager.lua:239 的用法：
--     ★★ 「相邻节点 story_depths 不同 ⇒ 跨了任务边界」。
--   ★★★ 而 area_trigger.lua:24 用它做「按深度切分故事章节」。
--   ★★ 零值语义：rootNode 与未参与链接的 Graph 保持 -1 或 0，
--     ★★★ 运行时（caves_retrofit_land.lua:40 等）会把某些节点强制设成 0。
		table.insert(encoded.story_depths, self.story_depth)
-- ★ 入 nodes 数组。
		table.insert(encoded.nodes, encoded_node)

-- ★★★★★★★ 本文件**最关键的算法段**：id → 整数下标的重映射。
-- ★★★ 做法：**对每个已编码的节点，把所有边里等于它字符串 id 的端点，
--   替换成「当前节点在 encoded.nodes 里的下标」（#encoded.nodes）。**
-- ★★★ 为什么这么做：★ 因为边的端点在编码时只有字符串，
--   ★★ 而节点是**边遍历完之后**才编码的（:135/:144 在 :151/:172 之前）。
--   ★★ ⇒ 边无法在编码时就知道端点下标 ⇒ 只能在节点编码完时回头改。
-- ★★★ ⚠⚠ 疑似性能缺陷（真实，O(N×E)）：
--   ★★ 每编码一个节点，就要**全量扫描 encoded.edges**（:159 的 for）。
--   ★★ 复杂度 = 节点数 × 边数。大型 task（300 节点 / 400 边）= 12 万次比较；
--     ★★ 全图（2000 节点 / 3000 边）= **600 万次**字符串比较。
--   ★★ 单次可能 10~100 ms，仍在毫秒级预算内，
--     ★★ 但 ★★ 这是本文件唯一的结构性性能热点，且**极易被忽略**
--       （代码看起来像「顺手做一下」）。
--   ★★★ 正确做法：建 id→下标 的哈希表，一次遍历所有边完成替换（O(E)）。
		for edge_id,edge in ipairs(encoded.edges) do
-- ★★ ⚠ 变量遮蔽：`local edge = encoded.edges[edge_id]` 把外层的 edge
--   （当前正在编码的边）**遮蔽**掉了。
--   ★★ 本函数内 :160/:181 之后不再需要外层 edge，所以无害；
--   ★★ 但这是典型的**易碎写法**——★ 以后有人想在循环后用 edge 就中招了。
			local edge = encoded.edges[edge_id]
-- ★★ edge.n1 == id ⇒ 替换 n1 为当前节点下标。
			if edge.n1 == id then
				edge.n1 = #encoded.nodes
			end
-- ★★ 同理替换 n2。
			if edge.n2 == id then
				edge.n2 = #encoded.nodes
			end

-- ★ 内层循环结束。
		end
	end

	--print("\tGot "..GetTableSize(self.nodes) .." nodes")
-- ★★ 第四段：编码 **nodes**（本图内的房间节点）。★ 与第三段结构完全相同。
--   ★★ 于是 exit_nodes 与 nodes 的编码逻辑是**复制粘贴**关系。
--   ★★★ 唯一差别：注释里写明了第二段遍历的是 self.nodes（第三段的注释
--     还留着 `for id,node in pairs(self.exit_nodes) do --self.nodes) do`
--     的痕迹，说明这段是从 nodes 那段**复制过来**后改了表名）。
	for id,node in pairs(self.nodes) do --self.nodes) do
-- ★ Node:SaveEncode —— ★★ 这里是唯一真正编码房间几何的地方。
		local encoded_node =  node:SaveEncode(map)
		EncodeColour(encoded_node, encoded)

-- ★★ ids 追加（★ 无查重，见 :151 的 ⚠）。
		table.insert(encoded.ids, id)
-- ★★ story_depths 追加（同 :156）。
		table.insert(encoded.story_depths, self.story_depth)
		table.insert(encoded.nodes, encoded_node)

-- ★★ 第五次全量扫描边（★ 与 :159 完全重复的代码）。
--   ★★★ 即：**同一段重映射逻辑在本文件里被写了两遍**（:159-168 与 :180-189）。
--     ★★ 属于「复制粘贴」而非抽象。★ 在这个规模下可接受，
--       ★★ 但它意味着任何修复都要改两处。
		for edge_id,edge in ipairs(encoded.edges) do
			local edge = encoded.edges[edge_id]
			if edge.n1 == id then
				edge.n1 = #encoded.nodes
			end
			if edge.n2 == id then
				edge.n2 = #encoded.nodes
			end

		end
	end
	--print("\tGot children "..GetTableSize(self.children) .." nodes")
	for id,child in pairs(self.children) do
		child:SaveEncode(map, encoded)
	end

-- ★ Get the background nodes ——★ 这段整体被注释掉了（:199-230）。
-- ★★ 从注释内容看，作者曾想做「用 GetSitePolygon 直接生成背景节点」的旧方案，
--   ★★ 后被「真实背景节点 AddBGNodes」方案取代。
--   ★★ 保留 30 行注释掉的代码是常见的「历史层积」，无害但增加阅读负担。
	-- Get the background nodes
	-- This should include links to which nodes are touching

--
--	local function GetEncodedBackgroundNone(map, id)
--		local poly_x, poly_y = WorldSim:GetSitePolygon(id)
--		local poly_def = {}
--		for current_pos_idx = 1, #poly_x  do
--			poly_def[current_pos_idx] = {math.floor((poly_x[current_pos_idx]-map.width/2.0)*TILE_SCALE), math.floor((poly_y[current_pos_idx]-map.height/2.0)*TILE_SCALE)}
--			current_pos_idx = current_pos_idx + 1
--		end
--		return {
--					poly = poly_def,
--					c = self.colour,
--					}
--	end
--
--	for id,node in pairs(self.nodes) do --self.nodes) do
--		local encoded_node = GetEncodedBackgroundNone(map, id)
--		EncodeColour(encoded_node, encoded)
--
--		table.insert(encoded.ids, id)
--		table.insert(encoded.nodes, encoded_node)
--
--		for edge_id,edge in ipairs(encoded.edges) do
--			local edge = encoded.edges[edge_id]
--			if edge.n1 == id then
--				edge.n1 = #encoded.nodes
--			end
--			if edge.n2 == id then
--				edge.n2 = #encoded.nodes
--			end
--
--		end
--	end

-- ★★ print("\tEncoding complete: "..) ——★ 唯一会打的日志（且被注释）。
	--print ("\tEncoding complete: ".. self.id, #encoded.ids, #encoded.colours, #encoded.nodes, #encoded.edges)
-- ══════════════ SaveEncode 结束 ══════════════
end


------------------------------------------------------------------------------------------
---------             Graph               --------------------------------------
------------------------------------------------------------------------------------------

-- ══════════════ AddChild / RemoveChild / GetChildren ══════════════
-- ★★ AddChild：★ 最简单的函数，但有两条**关键 assert**。
function Graph:AddChild(child)
-- ★ assert(child) —— 不接受 nil。
	assert(child)
-- ★★ assert(not self.children[child.id]) ——★ **子图 id 必须全局唯一**。
--   ★★★ 这条 assert 是整个拓扑正确性的**根保证**：
--     ★★ 若两个 Graph 撞 id，后面所有 GetNodeById(:485) 都会找到错的那个，
--       ★★★ 而且是**静默**的（返回第一个匹配的）。
--   ★★ id 的来源：storygen.lua:1284 `task.id`、:769 `REGION_LINK_N`、
--     :1156 `LOOP_BLANK N` ⇒ 都带唯一后缀。
	assert(not self.children[child.id])

	self.children[child.id] = child
end

-- ★★★ ⚠ 疑似缺陷（真实）：RemoveChild 用 table.remove 删字典键。
--   `table.remove(self.children, child.id)` ——★ child.id 是**字符串**！
--   ★★ Lua 的 table.remove 只接受**整数下标**；传字符串是 no-op 或报错，
--     ★★ **绝不会删掉那个字典项**。
--   ★★ 正确写法：`self.children[child.id] = nil`。
--   ⚠ 当前不触发：★ grep 核实 map/ 内无 RemoveChild 调用点。
--     ★★ 但这是个「谁一调谁坏」的地雷。
function Graph:RemoveChild(child)
	assert(child)
	assert(self.children[child.id])

-- ★★ return table.remove(self.children, child.id) ——★ 见上，删不掉。
	return table.remove(self.children, child.id)
end
-- ★★ GetChildren()：★ 直接返回内部字典引用（不拷贝）。
--   ★★★ 后果：★ 外部可以拿到并**直接修改** children 字典，
--     ★★ 绕过 :242 的 assert（可以覆盖已存在的子图）。
--   ★★ 且 ★★ 返回的是引用 ⇒ 遍历顺序 = pairs 顺序 = 不定。
--   ★★ storygen.lua:175 / :223 / :482 都用它遍历 ⇒
--     ★★★ 这些地方的遍历顺序全部不确定。★ 可复现性雷区。
function Graph:GetChildren()
	return self.children
-- ══════════════ 完毕 ══════════════
end

-- ══════════════ ★★★ LockGraph：★ 「锁」的物理载体 ══════════════
-- ★★★★★ 头号认知（本文件最重要的知识）：
--   ★★ lock.key 这个字段**在本文件里从未被读取**。
--   ★ grep 核实：Graph 与 Edge 都不消费 lock.key 做任何逻辑判定。
--   ★★ ⇒ 「锁」不是靠 key 的值实现的，而是靠**这条边存不存在**实现的。
--   ★★★ 这直接改写了 E1 缺陷的机理：
--     「锁—钥匙表被覆盖」并不会让某扇门打不开，
--     ★★ 而是让 storygen 误判「你已有钥匙」从而**创建了不该有的边**，
--       ★★ 或者误判「你没钥匙」从而**没创建本该有的边**。
--     ★★ 后者 = 拓扑级不可达（那条路根本没生成）。
--   ★★ 真正的「门」是：impassable 地块 + RoadPoison 标签
--     （storygen.lua:993/:1163，network.lua:1040），
--     ★★ 与 lock.key 无关。★ lock.key 是纯声明式元数据。
function Graph:LockGraph(id, left_exit_node, right_exit_node, lock)
-- ★ Lock a graph by adding an exit edge across both nodes ——★ 原始注释。
--   ★★ 精确定义：这条边跨两个 Graph（node1 在 left 所属图，
--     node2 在 right 所属图）。
	-- Lock a graph by adding an exit edge across both nodes
	--print(self.id..":LockGraph: Edge id:".. id, "Left Node:"..left_exit_node.id.."("..left_exit_node.graph.id..")", "Right Node:"..right_exit_node.id.."("..right_exit_node.graph.id..")", "Lock:"..lock.type)

	--print(lock, lock.type, lock.key)

-- ★★ assert(lock) —— lock 表必须存在（但不断言 type/key）。
--   ★★ 被注释掉的 :264-265 是 `assert(lock.type)` / `assert(lock.key)`。
--   ★★ 注释掉它们说明：**存在不带 type/key 的调用**（★ 例如海岛链接）。
	assert(lock)
	--assert(lock.type)
	--assert(lock.key)

-- ★ id 为 nil 时自动命名："Exit" .. 当前 exit 边数。
--   ★★★ ⚠ 潜在缺陷：若中途有边被 RemoveExitEdge(:287) 导致数量减少，
--     ★★ 命名会**重复**（例：删掉一个后，"Exit3" 会被复用）
--     ★★ 而 :270 的 assert(not self.exit_edges[id]) 会因此**崩溃**。
--   ⚠ 当前不触发（无自动命名路径的调用点，★ storygen 都显式传 id）。
	if id == nil then
		id = "Exit"..GetTableSize(self.exit_edges)
	end
-- ★★ assert(not self.exit_edges[id]) ——★ exit 边 id 唯一。
--   ★★ 与 :242 的子图唯一性是同一级别的保证。
--   ★★★ ★★ 而这个 assert 正是 E1 缺陷的**间接证人**：
--     ★★ E1 导致某些边「被创建了两次」时会命中这条 assert ⇒ 崩溃。
--       ★★ 也就是说：★ 如果 E1 严重到产生重复边 id，
--         ★★★ 世界生成会**立即崩溃**而不是产出坏图。
--     ★★ 实际不崩 ⇒ 说明 E1 的表现是「少连/多连」，不是「重复连同一 id」。
--       ★★（storygen.lua:793-794 的 id 用 `REGION_LINK_N` 计数器保证唯一。）
	assert(not self.exit_edges[id])

-- ★★★ self.exit_edges[id] = Edge(id, left_exit_node, right_exit_node, lock)
--   ★★ 关键：**Edge 构造函数会把自己注册到两个端点的 edges 表里**
--     ★★ （见 :336-339 的注释确认这一点）。
--   ★★ 于是 node1.edges 和 node2.edges 里都能找到这条边，
--     ★★ 即使 node2 不在 self.nodes 里（它在兄弟图里）。
--   ★★★ 这就是 exit_nodes 需要单独存在的原因（回看 :27 的注释）。
	self.exit_edges[id] = Edge(id, left_exit_node, right_exit_node, lock)

-- ★★ WorldSim:AddExternalLink(left, right) ——★ 通知 C++ 侧「这两点之间有路」。
--   ★★ 与图内边的 WorldSim:AddLink(:344) 相对：
--     · AddLink          = 图内相邻
--     · AddExternalLink  = 跨图相邻
--   ★★★ C++ 侧靠这两个调用构建 Voronoi 的邻接约束 ⇒
--     ★★★ **图上的邻接 = 地图上的邻接**，这正是整个设计的关键收益。
	WorldSim:AddExternalLink(left_exit_node.id, right_exit_node.id)

	return self.exit_edges[id]
end

-- ★★★ GetExitEdges(false)：★ 注意形参 incChildren 在 :281 被忽略。
--   ★★ 传 false 也一样返回本图的 exit_edges（★ 参数无用）。
--   ★★ ⚠ 疑似缺陷（轻微）：签名承诺了行为但未实现。
--   ★★ 与 GetEdges(:403) / GetNodes(:515) 的正确实现形成对比
--     ★★（那两个都判断了 incChildren）。
function Graph:GetExitEdges()
	local edges = {}
-- ★★ 拷贝一份（★ 与 GetChildren(:253) 返回引用不同，这里是拷贝）。
--   ★★★ 同一文件里两种风格不一致：
--     · GetChildren(:253) → 返回**引用**（可被外部改坏）
--     · GetExitEdges(:279) → 返回**拷贝**（安全但每次 O(E)）
--   ★★ 返回拷贝反而保证了 :829 `for id,edge in pairs(...)` 的安全。
 	for k,v in pairs(self.exit_edges) do
 		edges[k] = v
	end
	return edges
end

-- ★★★ ⚠ 疑似缺陷（同 :247）：RemoveExitEdge 同样用 table.remove 删字典键。
--   ★★ `table.remove(self.exit_edges, id)` 中 id 是字符串 ⇒ 删不掉。
--   ★★ 后果叠加：★ :267 的自动命名会因「数量不减」而一直递增，
--     ★★ 所以 **RemoveExitEdge 无效反而避免了 :270 的 assert 崩溃**。
--   ⚠ 当前无调用点（★ grep 核实）。
function Graph:RemoveExitEdge(id)
	assert(id)
	assert(self.exit_edges[id])
-- ★★ return table.remove(...) ——★ 见上。
	return table.remove(self.exit_edges, id)
end

-- ★★ IsConnectedTo(graph)：★ 只查**图内边**（self.edges），不查 exit_edges。
--   ★★★ ⚠ 语义缺陷：★ 一个 Graph 通过 exit_edge 连到别的图，
--     ★★ 这里会返回 **false**（因为 exit 边不在 self.edges 里）。
--   ★★ 但函数名叫 IsConnectedTo，读起来像是「是否与该图有连接」。
--   ★★★ 真实语义是「图内是否有边指向该图的节点」——这是个很窄的条件。
--   ⚠ 当前无调用点（★ grep 核实 map/ 内零消费）。★ 又一个「语义与名字不符」的化石。
function Graph:IsConnectedTo(graph)
	assert(graph)

	for k,edge in pairs(self.edges) do
-- ★★ edge.node1.graph == graph or edge.node2.graph == graph
--   ★★ 用 .graph 指针比较（而不是 id）⇒ 快。
		if edge.node1.graph == graph or edge.node2.graph == graph then
			return true
		end
	end

	return false
-- ★═══ 完毕：Utility / SAVE-LOAD / Graph / EDGES 四节结束 ════
end

-- ══════════════ ★★ EDGES 一节 ══════════════


------------------------------------------------------------------------------------------
---------             EDGES                   --------------------------------------
------------------------------------------------------------------------------------------
-- ★★★ AddEdgeByNode：★ 图内边的实际创建入口（AddEdge 委托到这里）。
-- ★★ 与 LockGraph 的区别（★ 必须记住）：
--     · AddEdgeByNode → 存进 **self.edges**，并调 WorldSim:AddLink
--     · LockGraph     → 存进 **self.exit_edges**，并调 WorldSim:AddExternalLink
function Graph:AddEdgeByNode(id, node1, node2, lock)
	--print(self.id..":AddEdgeByNode: ",id, node1, node2, lock)
-- ★ assert(node1) / assert(node2) ——★ 两端都必须存在。
	assert(node1)
	assert(node2)

-- ★ id 为 nil 时自动命名 "edge"..当前边数。
--   ★★ ⚠ 与 :267 同样的隐患：RemoveEdge(:397) 删不掉字典项
--     ★★ ⇒ 数量只增不减 ⇒ 名字不会重复。★ 所以这里是**安全**的。
	if id  ==  nil then
		id = "edge"..GetTableSize(self.edges)
	end
-- ★★ assert(not self.edges[id]) ——★ 图内边 id 也必须唯一。
	assert(not self.edges[id])


-- ★★★ if self.nodes[node1.id] == nil then ——★ 「懒补」节点。
--   ★★★ 语义：这条边的端点若不在本图节点表里，**自动加进来**。
--   ★★ 好处：调用方不必先建节点再连边。
--     ★★ 调用点全是「先 AddNode 再 AddEdge」的顺序（storygen.lua:1046/1081/
--       :1363/1375/1385…），所以这个分支实际很少走。
--   ★★★ ⚠ 但它有个副作用：★ 若传进来的 node 属于**别的图**，
--     ★★ 这里会把它「收编」进本图（:430 node.graph = self 会**改写**它）。
--     ★★★ ⇒ 图的归属被静默改变！★ 对比 :27 关于 exit_nodes 的设计说明，
--       ★★ 说明作者**清楚**这个风险，所以 exit 边才走另一条路。
	if self.nodes[node1.id] == nil then
		--print(self.id.."::AddEdgeByNode: Node1 ",node1.id,"added")
		self:AddNodeByNode(node1)
	end

	if self.nodes[node2.id] == nil then
		--print(self.id.."::AddEdgeByNode: Node2 ",node2.id,"added")
		self:AddNodeByNode(node2)
	end

-- ★★ Edge(id, node1, node2, lock, {colour = self.colour})
--   ★★ 边继承 Graph 的颜色（调试视图里整个 task 一个颜色）。
--   ★★ lock 可以为 nil ⇒ 图内边默认无锁。
	local edge =  Edge(id, node1, node2, lock, {colour = self.colour})
	self.edges[id] = edge

	--print(self.id.."::AddEdgeByNode: Edge ",id,"added")

-- ★★★ 原始注释解释了为什么不再手工往 nodes.edges 里插边：
--   -- The Edge constructor adds itself to its nodes, this isn't
--   -- necessary (I hope)
-- ★★★ 「(I hope)」三个字很关键：
--   ★★ Edge 构造函数（map/graphedge.lua）自己会注册到两个端点。
--   ★★ **节点知道自己有哪些边**（node.edges）是这套图能反向遍历的关键。
--   ★★ 作者用 "I hope" 表示「依赖了另一个文件的隐式行为」，
--     ★★★ 这是一种脆弱的跨文件耦合 ★：graphedge.lua 的构造行为一变，
--       ★★★ 本文件的所有图遍历都会静默失效。
	-- The Edge constructor adds itself to its nodes, this isn't necessary (I hope)
	--table.insert(self.nodes[node1.id].edges, edge)
	--table.insert(self.nodes[node2.id].edges, edge)
	--self.nodes[node2.id].edges[id] = self.edges[id]

-- ★ assert(self.nodes[node1.id]) / assert(self.nodes[node2.id])
--   ★★ 只是「保险再查一遍」——:321-329 刚补过。
	assert(self.nodes[node1.id])
	assert(self.nodes[node2.id])

-- ★★ WorldSim:AddLink(node1.id, node2.id) ——★ 图内邻接通知 C++。
--   ★★★ 这是「图 ⇒ 地图」转换的**两个关键调用之一**（另一个 :274）。
--     ★★ C++ 侧 Voronoi 生成时会读取这些邻接约束，
--       ★★★ 使得**两个 Voronoi 胞元之间一定留出通路**。
--     ★★ ⇒ 这就是「图上的邻接 = 地图上的邻接」的实现。
	WorldSim:AddLink(node1.id, node2.id)

	return self.edges[id]
end

-- ★★★ AddEdge(args)：★ 声明式版本，参数用 id 字符串而非对象。
--   ★★ 调用点极多（storygen.lua:788/791/975/1046/1081/1144/1363/1375/…）。
--   ★★★ 它的三步：查 nodes → 取对象 → 委托 AddEdgeByNode。
function Graph:AddEdge(args)
	--print(self.id..":AddEdge:", args.id, args.node1id, args.node2id, args.lock)

-- ★★ 两条 assert(args.node1id/node2id) ——★ 必须给 id。
	assert(args.node1id)
	assert(args.node2id)
-- ★★★ assert(self.nodes[args.node1id]) / assert(self.nodes[args.node2id])
--   ★★★ 这两条 assert 与 AddEdgeByNode(:321) 的「懒补」**矛盾**：
--     ★★ 在这里就已经要求节点必须存在了，:321 的懒补分支永远走不到。
--   ★★★ ⇒ 疑似冗余代码：要么这两条 assert 应该去掉（让懒补生效），
--     ★★ 要么 :321-329 的懒补逻辑是死代码。
--   ⚠ 推理依据：AddEdge 是 :366 委托给 AddEdgeByNode 的唯一入口，
--     ★★ 而它在委托前就断言了节点存在。
	assert(self.nodes[args.node1id])
	assert(self.nodes[args.node2id])

	if args.id  ==  nil then
		args.id = "edge"..GetTableSize(self.edges)
	end
	assert(not self.edges[args.id])


	local node1 = self.nodes[args.node1id]
	local node2 = self.nodes[args.node2id]

-- ★★ return self:AddEdgeByNode(args.id, node1, node2, args.lock)
	return self:AddEdgeByNode(args.id, node1, node2, args.lock)
end

-- ══════════════ GetEdge：★ 递归查找（三级）══════════════
-- ★★ 查找顺序：本图 edges → 本图 exit_edges → **所有子图递归**。
--   ★★★ 这就是「全局边查找」的入口 —— ★ 边 id 只要全局唯一就能查到。
function Graph:GetEdge(id)
	assert(id)

	--print(self.id..":GetEdge ["..id.."]")
-- ★★ 第一级：本图图内边。
	if self.edges[id] then
		--print(self.id..":GetEdge found edge ["..id.."]")
		return self.edges[id]
	end

-- ★★ 第二级：本图 exit 边。
--   ★★★ ★★ ⚠⚠ 真实缺陷（全局变量泄漏）：
--   `edge = child:GetEdge(id)`（:385）——★ **缺少 local 关键字**！
--   ★★ 于是 :386 的 `if edge then` 判断的是**全局变量 edge**，
--     ★★★ 而 :379 的 `return self.exit_edges[id]` 早就在常见路径返回了，
--       ★★★ 所以当确实走到递归时，:386 读到的是上一次调用留下的全局残留。
--   ★★★ 后果：★ 若某个子图确实没有这条边（child:GetEdge 返回 nil），
--     ★★ `edge` 仍保留**上一次**非 nil 的值 ⇒ **误判找到，返回错边**。
--     ★★★ 这是一个真 bug，只是依赖调用方很少走「递归未命中」路径。
--   ⚠ 推理依据：Lua 中未加 local 的赋值就是全局赋值；
--     ★★ 且 :386 的 if 与 :389 的 return 在同一作用域内。
	if self.exit_edges[id] then
		--print(self.id..":GetEdge found exit edge ["..id.."]")
		return self.exit_edges[id]
	end

-- ★★ for k,child in pairs(self.children) ——★★ 递归遍历子图。
--   ★★ ⚠ 顺序不定 ⇒ 若边 id 在多个子图里重复（理论上被 :270 禁止），
--     ★★ 返回哪一个取决于 pairs 顺序。★ 不可复现。
	for k,child in pairs(self.children) do
		--print(self.id..":GetEdge looking in child", id, child.id)
		edge = child:GetEdge(id)
		if edge then
			--print(self.id..":GetEdge found in child", id, child.id)
			return edge
		end
	end

	--print(self.id..":GetEdge could not find ["..id.."]")
	--dumptable(self.edges)
-- ★ return nil ——★ 三级都没找到。
	return nil
end

-- ★★★ ⚠ 疑似缺陷（同 :287/:247）：RemoveEdge 也删不掉字典项。
--   ★★ `table.remove(self.edges, id)` 中 id 是字符串 ⇒ 无效。
--   ★★ ⚠ 当前无调用点。★ 三个 Remove* 全是坏的，是同一处复制粘贴错误。
function Graph:RemoveEdge(id)
	assert(id)
	assert(self.edges[id])
-- ★★ return table.remove(...) ——★ 见上。
	return table.remove(self.edges, id)
end

-- ══════════════ GetEdges(incChildren) ══════════════
-- ★★ 这是本文件里 incChildren **正确实现**的版本（对比 :279 的假实现）。
-- ★ 用途：:822 的 ProcessInsanityWormholes 调 GetEdges(false)。
function Graph:GetEdges(incChildren)
	local edges = {}
-- ★★ 浅拷贝本图的 edges（★ 拷贝，外部改动不影响内部）。
 	for k,v in pairs(self.edges) do
 		edges[k] = v
	end

-- ★★ if incChildren == true then ——★ 递归合并所有子图的边。
--   ★★ 合并策略：**按 key 覆盖**（`edges[k] = v`）。
--   ★★ ⚠ 边 id 全局唯一（:270 保证）⇒ 不存在覆盖问题。✔
	if incChildren ~= nil and incChildren == true then
		for id,child in pairs(self.children) do
			local childEdges = child:GetEdges(incChildren)
		 	for k,v in pairs(childEdges) do
		 		edges[k] = v
			end
		end
	end

-- ★═══ EDGES 一节结束 ════
	return edges
end

-- ══════════════ ★★ NODES 一节 ══════════════
------------------------------------------------------------------------------------------
---------             NODES                   --------------------------------------
------------------------------------------------------------------------------------------

-- ★★★ AddNodeByNode：★ 节点的真正创建入口（AddNode 委托到这里）。
-- ★★ 它做 4 件事：注册到 nodes → 通知 WorldSim → 记 entrance → 累加 required_prefabs。
function Graph:AddNodeByNode(node)
	assert(node)
	assert(node.id)
-- ★★ assert(not self.nodes[node.id]) ——★ 节点 id 在**本图内**唯一。
--   ★★★ 注意：★ 这里只保证「本图内」唯一，不保证全局唯一。
--     ★★ 而 :485 GetNodeById 是**递归全局**查找 ⇒
--       ★★★ 若两个图里有同名节点，GetNodeById 返回哪个取决于 pairs 顺序。
--     ★★★ 真实的跨图 id 唯一性只靠「调用方保证」（task.id 全局唯一）。
	assert(not self.nodes[node.id])

-- ★★★ node.graph = self ——★ 反向指针。★ 本文件大量依赖它。
--   ★★ 用处：:297 IsConnectedTo、:87 Dump、graphedge 的反向查找。
--   ★★★ ⚠ 结合 :321-329 的「懒补」：★ 这里的赋值会**改写**传入节点的归属，
--     ★★ 也就是 AddEdgeByNode 的懒补会「偷」别的图的节点。
	node.graph = self
	self.nodes[node.id] = node

-- ★★★ if node.data.entrance then self.entrancenode = node end
--   ★★★ 重要：**只有一个 entrancenode 槽位**，后来的会覆盖前面的。
--   ★★ 一个 task 若有多个 entrance 房（storygen.lua:1254 会把 entrance=true），
--     ★★★ 只保留**最后一个** ⇒ 出生点/区域入口的选取依赖这个覆盖顺序。
--   ★★★ 而覆盖顺序由 room_choices 的入栈顺序决定 ⇒
--       ★★★ **pairs 遍历顺序 ⇒ 入口节点选择 ⇒ 区域连在哪**，
--         ★★★ 整条链都依赖不可控的遍历顺序。★ 这是可复现性的深坑。
--   ★★ 消费点：storygen.lua:803/812/830/841 的 region.entranceNode。
--   ★★ 对比 GetRandomNodeForEntrance(:567)：★ 那是「随机选一个入口」，
--     ★★ 与这个「最后一个 entrance」是**两个不同概念**，极易混淆。
	if node.data.entrance then
		self.entrancenode = node
	end

	--dumptable(self.nodes[node.id])
	--print(self.id..":Graph:AddNodeByNode ", node.id, GetTableSize(self.nodes), "Parent:"..self.nodes[node.id].graph.id)
	--dumptable(self.nodes)

-- ★ assert(self.nodes[node.id]) ——★ 保险。
	assert(self.nodes[node.id])
	--print(self.id..":Graph:AddNodeByNode ", self.id, node.id, node.data.value, node.colour.r, node.colour.g, node.colour.b, node.colour.a)

-- ★★★★★ WorldSim:AddChild(self.id, node.id, value, r,g,b,a, type,
--   internal_type)
--   ★★★ 这是「节点 → C++ 站点」的转换。★ 参数逐个对应：
--     · self.id       = 父站点（Graph 的 id）
--     · node.id       = 新站点（房间的 id，如 "ForestTask:0:Forest"）
--     · node.data.value = 地面地块 ID（★ 群系的地形由这一参数决定）
--     · colour        = 调试色
--     · node.data.type = NODE_TYPE.*（Room / Background / Blank …）
--     · internal_type = 内部连接类型，默认 EdgeSite
--   ★★ 这是整个生成流程里「Lua 数据 → C++ 几何」的关键一步：
--     ★★★ 每个房间节点在这里变成一个 Voronoi 站点。
	WorldSim:AddChild(self.id, node.id, node.data.value,
						node.colour.r, node.colour.g, node.colour.b, node.colour.a,
						node.data.type, node.data.internal_type or NODE_INTERNAL_CONNECTION_TYPE.EdgeSite)

-- ★ if node.data.tags ~= nil and #node.data.tags >0 then
--   ★★★ 里面只有一句被注释掉的 SetSiteFlags ——★ **标签此时没有传给 C++**！
--   ★★★ 真正的标签生效点在 :1026 ApplyPoisonTag（烘焙之后）。
--   ★★★ ⇒ 标签的处理被**推迟**到烘焙后，★ 而不是建站时。
--     ★★ 设计理由（推测）：标签最终要作用在「已烘焙的地块」上，
--       ★★ 建站时还没有地块。
	if node.data.tags ~= nil and #node.data.tags >0 then
		--WorldSim:SetSiteFlags(node.id, node.data.tags[1])
	end

-- ★★ 节点级 required_prefabs 累加 ——★★ 三重来源求和的「房间层」。
--   ★★★ 三层累加顺序：
--     · 房间级：这里（node.data.required_prefabs）
--     · 任务级：Graph 构造 :56-60
--     · 图级：GetRequiredPrefabs :786 递归合并所有子图
--   ★★ ⇒ 同一个 prefab 被多个房间要求时会**累加**（不是取 max）。
--   ★★ 校验（forest_map.lua:961）用的是累加值 ⇒ ★ 偏严格。
    if node.data.required_prefabs ~= nil then
        for i,prefab in ipairs(node.data.required_prefabs) do
            self:AddRequiredPrefab(prefab)
        end
    end

	return self.nodes[node.id]
end

-- ★★★ AddNode(args)：★ 声明式版本 → Node 对象 → AddNodeByNode。
--   ★★ 调用点：storygen.lua:776/972/1024/1062/1122/1158/1346。
function Graph:AddNode(args)

-- ★ id 为 nil 时自动命名 "node"..当前节点数。
--   ★★ ⚠ 潜在隐患同 :267：RemoveNode(:658) 删不掉 ⇒ 名字不重复。★ 安全。
	if args.id  ==  nil then
		args.id = "node"..GetTableSize(self.nodes)
	end
	assert(args.id)

	--print(self.id..":Graph:AddNode ", args.id, args.data)
	--dumptable(self.nodes)
-- ★★ assert(not self.nodes[args.id]) ——★ 节点 id 唯一（同 :428）。
	assert(not self.nodes[args.id])

	--print("AddNode:", args.id, args.data)
	--dumptable(args.data)
-- ★★★ local node = Node(args.id, args.data) ——★ 构造 Node（graphnode.lua:107）。
--   ★★ 注意 ★ data 是**直接引用**，不是 deepcopy。
--     ★★ ⇒ AddNode 之后外部若改 args.data，节点的数据也会变。
--     ★★ 这是有意为之还是疏忽难以判断，但与 GetRoom(:107) 的
--       ★★★ `deepcopy(Rooms.GetRoomByName(...))` 形成鲜明对比：
--         房间模板深拷贝了，但调用方构造的 data 表没有。
--       ★★★ ⇒ ★ 数据来源的可信度分两等，这是个隐蔽的不变量。
	local node = Node(args.id, args.data)

	return self:AddNodeByNode(node)
end

-- ★★★ GetNode(id)：★ 只查**本图**，且**带 assert**。
--   ★★ 与 :485 GetNodeById 的「递归 + 返回 nil」正好是两种风格：
--     · GetNode     → 本图 + 找不到就崩（用于「我确定它在这」）
--     · GetNodeById  → 全图 + 找不到返回 nil（用于「找找看」）
--   ★★★ 命名只差一个 ById 但语义差很多 ★ —— 极容易用错。
function Graph:GetNode(id)
	assert(id)
	assert(self.nodes[id])
	return self.nodes[id]
end

-- ★★★ GetNodeById(id)：★ **递归全局**查找，是本文件的核心查询函数。
--   ★★ 三级：① 自己就是它 ② 本图 nodes ③ 递归所有子图。
--   ★★ 消费点（★ 全部在 forest_map.lua）：
--     :646-691 迷宫/迷宫的 LabyrinthEntrance 节点查找
--     :699/:703 maze_tile_size / maze_tiles 查找
--     :818    迷宫入口节点查找
--   ★★★ ⚠ 性能：每层递归都遍历全部 children ⇒
--     ★★ 深度 D、宽度 W 的图，查找是 O(W^D)。★ 实际靠 D 很小（≤3）才可用。
--   ★★ 且 **children 是 pairs 遍历**（:497）⇒ 顺序不定 ⇒
--     ★★★ 同名节点时返回哪一个不可复现。
function Graph:GetNodeById(id)
	--print(self.id,"Looking for ", id)
	assert(id)

-- ★★★ if self.id == id then return self end ——★ 第①级：图自己。
	if self.id == id then
		return self
	end

	if self.nodes[id] ~= nil then
		--print("Found",id)
		return self.nodes[id]
	end
-- ★★ for child_id,child in pairs(self.children) ——★★ pairs！
--   ★★★ 同 :433 的问题：★ 若子图里有同名节点，命中哪一个随机。
	for child_id,child in pairs(self.children) do
		local childNode = child:GetNodeById(id)
		if childNode ~= nil then
			--print("Child Found",id)
			return childNode
		end
	end

	return nil
end

-- ★★★ HasNode(id)：★ 与 :479 GetNode 的第三种风格。
--   ★★ 返回 bool 而不崩 ⇒ 适合做条件判断。
--   ★★ 同一个「查节点」的需求，本文件有 **4 种**实现：
--     GetNode（:479 本图+崩）/ GetNodeById（:485 全图+nil）/
--     HasNode（:508 本图+bool）/ GetNodesByName（:579 按 data.name）。
--   ★★★ 风格不统一是「老代码库」的典型特征。
function Graph:HasNode(id)
	if self.nodes[id] ~= nil then
		return true
	end
	return false
end

-- ★★★ GetNodes(incChildren)：★ 浅拷贝 + 可选递归合并。
--   ★★ 消费：forest_map.lua:561 `local nodes = topology_save.root:GetNodes(true)`
--     ★★ 那是全图节点表，:562 的逐节点 SetTilesViaFunction 靠它。
--   ★★ 以及 :683 ConvertGround、:690 Populate、:730 PopulateVoronoi。
function Graph:GetNodes(incChildren)
	local nodes = {}
-- ★★ 浅拷贝本图 nodes。
 	for k,v in pairs(self.nodes) do
 		nodes[k] = v
	end

-- ★★ if incChildren == true then ——★ 递归合并子图节点。★ 同 :409。
	if incChildren ~= nil and incChildren == true then
		for id,child in pairs(self.children) do
			local childNodes = child:GetNodes(incChildren)
		 	for k,v in pairs(childNodes) do
		 		nodes[k] = v
			end
		end
	end

	--print(self.id.." Graph:GetNodes"..GetTableSize(self.nodes).."-->"..GetTableSize(nodes))
-- ★★ return nodes ——★ 注意这里没有 print（:530 被注释掉了）。
	return nodes
end

-- ══════════════ ★★ 随机选点三兄弟 ══════════════
-- ★★★ 三个函数，三种语义，必须分清：
--   GetRandomNode()        —— 纯随机，**永不返回 entrance**
--   GetRandomNodeForExit() —— 加权随机，排除 entrance 且权重>0
--   GetRandomNodeForEntrance() —— 加权随机，排除 entrance 且权重>0
-- ★★ 后两者的过滤条件**完全相同**（:558 vs :570），
--   ★★ 唯一区别是读的是 random_node_exit_weight 还是 entrance_weight。
-- ★★ 消费点：storygen.lua:443/444/604/605/890/892/930/939。
function Graph:GetRandomNode()
 	local picked = nil
	-- We should never pick blockers
-- ★★★ while not picked or picked.data.entrance == true do
--   ★★ 语义：「抽到一个非 entrance 节点为止」，★ 无限重抽。
--   ★★★ ⚠ 疑似缺陷（隐患，当前不可达）：★ 若本图**全部**节点都是 entrance，
--     ★★★ 这里就是**死循环**（没有重试上限、没有 fallback）。
--     ★★ 现实里每个 task 至少 1 个非入口房间（room_choices 决定），
--       ★★ 所以不触发。但 ★★ 这是「隐式前置条件」而非显式约束。
--   ★★ 对比 :563/:575 的 `assert(next(picks) ~= nil)`：
--     ★★ 那两个至少会崩，而这里会**挂死**。★ 挂死比崩更难排查。
	while not picked or picked.data.entrance == true do
-- ★★ local choice = math.random(GetTableSize(self.nodes)) - 1
--   ★★★ 「随机选第几个」的标准范式（详见 util.lua:259 GetRandomItem）。
--     ★★ 特点：① 先摇一个整数 ② 用 pairs 遍历数到第 choice 个。
--     ★★★ ⇒ 结果同时依赖 **随机数** 与 **pairs 遍历顺序**。
--     ★★★ ⇒ ★★ 「同种子 = 同世界」的前提是 pairs 顺序稳定。
--     ★★ 在 LuaJIT 上成立（hash 可预测），移植到别的 VM/语言就不成立。
		local choice = math.random(GetTableSize(self.nodes)) -1
		--print("Graph:GetRandomNode", choice)

-- ★★ for k,v in pairs(self.nodes) do ——★★ pairs！★ 顺序不定。
		for k,v in pairs(self.nodes) do
			--print("Graph:GetRandomNode", choice,  k,v)
			picked = v
-- ★★ if choice <= 0 then break end ——★ 计数命中。
			if choice<= 0 then
				break
			end
-- ★★ choice = choice - 1 ——★ 递减。
			choice = choice -1
		end
 	end

-- ★★ assert(picked) ——★ 防御性（循环退出时必然有值，除非 nodes 为空+死循环）。
 	assert(picked)
	return picked
end

-- ★★★ GetRandomNodeForExit()：★ 加权随机选「出口候选节点」。
--   ★★ 用于 storygen.lua 的 `parentNode:GetRandomNodeForExit()`：
--     ★★ 选一个房间的某个房间作为「上一区的出口」，★ 再拿它接下一区。
--   ★★ 这是「区域之间在哪里接缝」的决策点 ⇒ ★★ 直接影响地图观感。
function Graph:GetRandomNodeForExit()
	local picks = {}
	for k, v in pairs(self.nodes) do
-- ★★★ 双重过滤：★ 不是 entrance **且** random_node_exit_weight > 0。
--   ★★★ 「权重 = 0 ⇒ 完全排除」是本文件的**关键机制**：
--     storygen.lua:1341-1342 把 START 节点的 exit/entrance 权重都设成 0，
--       ★★★ ⇒ START **永远不会被选为任何区域的出入口**。
--     ★★★ 这就是「出生点被特殊保护」的实现方式 —— 不是加判断，而是设权重 0。
--     ★★ 同样的手法用在 hub_room（storygen.lua:1353-1354）。
--     ★★★ 这是「用数据表达约束」而非「用代码表达约束」的典范。
--   ★★ 筛选不出候选时（:563）会 assert 崩溃 ⇒ 权重全 0 的图不可生成。
		if v.data.entrance ~= true and (v.data.random_node_exit_weight == nil or v.data.random_node_exit_weight > 0) then
-- ★★ picks[k] = v.data.random_node_exit_weight or 1 ——★ 缺省权重 1。
--   ★★ 于是「默认均匀随机」；房间想被更常/更少选中就设权重。
			picks[k] = v.data.random_node_exit_weight or 1
		end
	end

 	assert(next(picks) ~= nil)
-- ★★ weighted_random_choice(picks)（util.lua:731）——★ 按权重抽。
--   ★★ 它内部也用 pairs 遍历 ⇒ ★★ **第二次**依赖 pairs 顺序。
--   ★★ ⇒ 同一个函数里有两处顺序依赖，★ 可复现性双重脆弱。
	return self.nodes[weighted_random_choice(picks)]
end

-- ★★ GetRandomNodeForEntrance()：★ 与上完全同构，只是读 entrance_weight。
--   ★★★ 所以真正控制「一个房间作为入口的频率」的是房间模板里的
--     ★★★ `random_node_entrance_weight` 字段（storygen.lua:1333 搬运）。
function Graph:GetRandomNodeForEntrance()
	local picks = {}
	for k, v in pairs(self.nodes) do
-- ★ if v.data.entrance ~= true and (…entrance_weight == nil or > 0) then
-- ★★★ 与 :558 的 exit 版**逐字相同**（只换了权重字段名）。
--   ★★★ ⇒ 「出口」和「入口」在候选筛选上完全对称。
--   ★★ ⇒ ★★ 所以「房间更适合当入口还是出口」这个设计意图，
--     ★★ 实际上**只体现在权重数值上，而不在筛选规则上**。
		if v.data.entrance ~= true and (v.data.random_node_entrance_weight == nil or v.data.random_node_entrance_weight > 0) then
			picks[k] = v.data.random_node_entrance_weight or 1
		end
	end

 	assert(next(picks) ~= nil)
	return self.nodes[weighted_random_choice(picks)]
end

-- ★★★ GetNodesByName(node_name)：★ 按 data.name 查，返回 **{{node=n}} 包装数组**。
--   ★★ 为什么包一层 {node=n}？★ 因为消费方 storygen.lua:840 需要
--     `node.node` 与 :812 的 `n1.node` 保持一致的形状。
--     ★★ 这是为了凑「(位置, 节点, …) 多返回值」的形式而做的包装。
--   ★★ 消费点：storygen.lua:831 `local nodes = task:GetNodesByName(node_name)`
--     ★★ 用于 AddRegionToTasksNodes（往某个 task 的指定房间群里插新区域）。
--   ★★ 返回值**按 pairs 顺序**（:582）⇒ ★★ 顺序不定。
--   ★★ 而 :840 的 `for i, node in ipairs(nodes) do LinkRegions(node, …)`
--     ★★★ ⇒ 连边的顺序随机 ⇒ 多条连接路的具体位置随机。
function Graph:GetNodesByName(node_name)
	local nodes = {}
	--
	for n_id, n in pairs(self.nodes) do
-- ★★ if n.data.name == node_name then ——★ 比对 data.name（不是 id）。
		if n.data.name == node_name then
			table.insert(nodes, {node = n})
		end
	end
	--
-- ★★★ 完毕 ════ NODES 一节前半结束 ════
	return nodes
end

-- ★★ 原始注释解释了 crossLinkFactor 的量纲（★ 极有价值）：
--   -- Each increment is one more link ie: a triangle would be factor 1,
--   -- a line factor 0, a tree factor 0, a square -> 1
-- ★★ 翻译：每个增量 = 多一条捷径。三角形=1、直线=0、树=0、正方形=1。
--   ★★★ ⇒ 所以 crosslink_factor = 1 表示「加 1 条边」，
--     ★★★ **不是「1 倍」也不是「1 条/节点」**。
--   ★★ map/task.lua:30 默认 1（storygen.lua:874 的 `or 1` 兜底）。
-- Each increment is one more link ie: a triangle would be factor 1, a line factor 0, a tree factor 0, a square -> 1
-- ★★★ CrosslinkRandom(factor)：★ 给图加随机捷径。
--   ★★ 目的（★ 重要）：★ 让「线性房间链」在地图上不是一条直线，
--     ★★ 而是带环路的网状结构 ⇒ 玩家不会觉得世界是走廊。
function Graph:CrosslinkRandom(crossLinkFactor)
-- ★★ if GetTableSize(self.nodes) <= 2 then return end
--   ★★ 两个节点以下没法加不重复的捷径。
	if GetTableSize(self.nodes)<=2 then
		return
	end

	local iterations = 0
-- ★★★ while crossLinkFactor > 0 and iterations < 20 do
--   ★★★ 两个终止条件：
--     · crossLinkFactor > 0 —— 加够条数就停；
--     · ★★ iterations < 20 —— ★★ **最多尝试 20 次**。
--   ★★★ ⇒ 「尽力而为」：★ 若 20 次内没抽到合适的节点对，
--     ★★ 就**少加几条边**，不报错、不重试、不日志。
--   ★★★ 这是一个**静默的质量降级**：crosslink_factor 的语义是
--     ★★ 「期望值」而非「保证值」。★ 属设计取舍，不是缺陷。
	while crossLinkFactor > 0 and iterations < 20 do
		local n1 = self:GetRandomNode()
		local n2 = self:GetRandomNode()
-- ★★ 四重判据才允许加边：不同节点 / 未相连 / 非 entrance / 非 entrance。
--   ★★★ 注意后两个判据**完全相同**（都是 `not ….data.entrance`），
--     ★★ ⇒ ★★ 疑似冗余：第二个应是别的条件（例如「都不是 blocker_blank」）。
--   ⚠ 推理依据：:601 的条件是
--     `n1 ~= n2 and n1:IsConnectedTo(n2)~= true and not n1.data.entrance and not n2.data.entrance`
--     ★★ 两个入口检查对「不与 entrance 相连」没有额外约束力。
		if n1 ~= n2 and n1:IsConnectedTo(n2)~= true and not n1.data.entrance and not n2.data.entrance then
-- ★★ local crosslink = self:AddEdge(...) ——★ 真正的加边。
			local crosslink = self:AddEdge({node1id=n1.id, node2id=n2.id})
-- ★★ `crosslink.hidden = true` ——★ 标记为「隐藏边」。
--   ★★★ 语义：**这条边在渲染/存档里被特殊对待**。
--     ★★ hidden 边不参与拓扑检查（ForceConnectivity 会视它为「本就连通」）。
--   ★★ ⇒ ★ 隐藏边 = 「假装不存在但留着」的边。
--   ★★ 呼应 :826-838 的 Wormhole 隐含要求：
--     ★★ 一个 OneshotWormhole 节点必须**恰好两个邻居**，
--       ★★★ 而 crosslink 会给它加邻居 ⇒ ★★ 两者会冲突。
--       ★★★ 所以 hidden 标记可能正是为了让那些检查忽略它。★ 推测。
			-- hide crosslinks
			crosslink.hidden = true
			crossLinkFactor = crossLinkFactor -1
		end
		iterations = iterations + 1
	end
end

-- ★★★ MakeLoop()：★ 把链首尾相连成环。
--   ★★ 消费：storygen.lua:1375（task.make_loop 为真时）。
function Graph:MakeLoop()
-- ★★ 原始注释："This assumes the graph is linear, and connects one end
--   with the other" ——★★★ **「假设图是线性的」**。
--   ★★★ 这是本函数最大的前提：★ 若图有 hub / crosslink / 多分支，
--     ★★ 「两个 #edges == 1 的节点」可能不止一对（若超过 2 个则取前两个），
--     ★★ 或者**一个都没有**（有环就没有端点）。
--   ★★★ ⇒ 这是一个「顺序敏感」的设计：★ crosslink 必须在 MakeLoop **之后**跑，
--     ★★ 否则环会被打破。★ 而 storygen.lua:1374-1385 恰好是这个顺序。✔
	-- This assumes the graph is linear, and connects one end with the other
	local first = nil
	local last = nil
-- ★★ for nodeid,node in pairs(self.nodes) ——★★ pairs 遍历找端点。
--   ★★★ 若图里有两个以上的链端（hub 之外的情况），
--     ★★ `first` 与 `last` 取的是**pairs 顺序里的前两个** ⇒ ★★ 随机。
	for nodeid,node in pairs(self.nodes) do
		--print(self.id, nodeid, #node.edges)
-- ★★ if #node.edges == 1 then ——★ 「度为 1」= 链的端点。
--   ★★ 用 #edges（数组长度）判断度数 ⇒ ★ 依赖 graphedge.lua 用数组存边。
		if #node.edges == 1 then
			if not first then
				first = node
			else
				last = node
				break
			end
		end
	end

-- ★★ if not first or not last then ——★ 找不到两个端点。
--   ★★ print 一条 Warning 并 return ——★ **不崩溃**，静默不成环。
--   ★★★ 这是个优雅降级：★ 「不成环」不是致命错误。
--     ★★★ 但也只有一行 print，★ 无统计。
	if not first or not last then
		print("Warning: Tried to make "..self.id.." into a loop but couldn't find end nodes.")
		return
	end

-- ★★ if first.data.entrance then ——★ 端点是入口房时的特殊处理。
--   ★★★ 语义：★ 入口房有 blocker_blank 子节点（storygen.lua:1056 挂了 2 个），
--     ★★★ 所以它的 `edges[1]` 可能是 blocker_blank 而不是房间。
--   ★★★ ⇒ 这里的处理是「**越过** blocker_blank，拿到真正的房间」。
--   ★★★ 这是全文件里唯一一处对「entrance ⇒ blocker_blank 结构」的显式认知。
--     ★★ 印证 storygen.lua:1056 挂 2 个 blocker 的原因之一。
	if first.data.entrance then
-- ★★ if first.edges[1].node1 == first then ——★ 判断自己在边的哪端。
		if first.edges[1].node1 == first then
			first = first.edges[1].node2
		else
			first = first.edges[1].node1
		end
	end
	if last.data.entrance then
		if last.edges[1].node1 == last then
			last = last.edges[1].node2
		else
			last = last.edges[1].node1
		end
	end

-- ★★ self:AddEdge({node1id=first.id, node2id=last.id}) ——★ 闭环。
--   ★★ 注意这条边**没有** hidden 标记（对比 :604）⇒
--     ★★★ 环边是**真实**边 ⇒ 会参与 ForceConnectivity。★ 正确。
	self:AddEdge({node1id=first.id, node2id=last.id})
end

-- ★★★ MakeHub(center_room_id)：★ 把所有房间连到枢纽房 ⇒ 星形拓扑。
--   ★★ 消费：storygen.lua:1378-1380（task.hub_room 非 nil 时）。
--   ★★★ 这是**另一种**连通性保证（不靠锁钥匙）：
--     ★★ 从入口进来只要连到 hub 房，★ 就一定能走到区域内**任何**房间。
--   ★★★ ⇒ 「枢纽房」本质上是**区域内的连通性保证**，
--     ★★★ 与 storygen.lua:1351-1355 把 hub 权重设 0 配合，
--       ★★★ 使 hub 只承担「汇聚点」角色而不承担「出入口」角色。★ 设计完整。
function Graph:MakeHub(center_room_id)
	for node_id, node in pairs(self.nodes) do
		if node_id ~= center_room_id then
-- ★★ self:AddEdge({node1id=node_id, node2id=center_room_id})
			self:AddEdge({node1id=node_id, node2id=center_room_id})
		end
	end
end

-- ★★★ ⚠ 疑似缺陷（同 :397）：RemoveNode 也删不掉字典项。
--   ★★ 更严重的是 :662 `self.nodes[id].graph = nil` ——
--     ★★★ 它**先**把节点的 graph 指针清空，
--       ★★★ 于是即使后面 table.remove 无效，那个节点也**已经损坏**
--         ★★★（graph 为 nil ⇒ 所有反向遍历会崩）。
--   ★★ ⇒ 「删不掉」变成了「删了一半，反而更糟」。
--   ⚠ 当前无调用点（★ grep 核实）。
function Graph:RemoveNode(id)
	assert(id)
	assert(self.nodes[id])

	self.nodes[id].graph = nil

-- ★★ return table.remove(self.nodes, id) ——★ 删不掉（见上）。
	return table.remove(self.nodes, id)
end

-- ══════════════ UpdateMinimumRadius ══════════════
-- ★★★ 这个函数**在本文件的流程里从未被调用**（★ grep 核实 map/ 内零调用点）。
--   ★★★ 它把「图的内容包围盒」写回 self.data.position/size，
--     ★★★ 但 ★★★ 注意：它写的是**自己**的 data，而 :675-676 读的是
--       ★★★ `GetMinimumRadiusForNodes(self.nodes)` —— ★ 只算自己的节点，
--         ★★★ **不含子图**！⇒ 子图的位置完全不参与。
--   ★★★ ⇒ ⚠ 这解释了一个现象：★ 为什么 rootNode.data.position 始终是 0。
--     ★★ 因为没人调它。★ 真正的位置是 C++ 给每个节点单独算的。
--   ★★ ⇒ 化石函数（vestigial）。★ 保留但不生效。
function Graph:UpdateMinimumRadius()

	local x,y,r =  GetMinimumRadiusForNodes(self.nodes)

-- ★★ self.data.size = math.ceil(r) ——★ 包围盒半径 → 整数尺寸。
	self.data.size = math.ceil(r)
-- ★★ assert(self.data.size >= 0) ——★ 防御（r 不该为负）。
	assert(self.data.size>= 0)
-- ★★ old_pos 备份 ——★ 推测原意是「检测移动」，但没人读 old_pos。
--   ★★ ⚠ 疑似残留：old_pos 字段（:39）被赋值但从不使用。
	self.data.old_pos.x = self.data.position.x
	self.data.old_pos.y = self.data.position.y
-- ★★ self.data.position.x = math.floor(x) ——★ 整数化。
--   ★★★ 但如上所述：这个值实际永远没人读。
	self.data.position.x = math.floor(x)
	self.data.position.y = math.floor(y)
end

-- ══════════════ ★ 散布调度：四个 Convert/Populate ══════════════
-- ★★ 这四个函数是「Graph 层 → Node 层」的批量转发器。
--   真正的逻辑全在 map/graphnode.lua 的同名 Node 方法里。
-- ★★ 它们的共同模式：`for k,node in pairs(self:GetNodes(true)) do … end`
--   ★★★ **注意 incChildren=true**：★ 收集全图节点（跨所有子图）后逐个转发。
--   ★★ ⇒ 这是「先收集后处理」而非「边遍历边处理」，
--     ★★ 因为后者会边遍历边改图（危险）。★ 值得学的模式。


-- ★★ ConvertGround(map, spawnFN, entities, check_col)
--   ★★ 转发到 Node:ConvertGround（graphnode.lua:247）—— 静态场景件落位。
--   ★★ 消费：forest_map.lua:843（★ 在 PopulateVoronoi **之前**调用）。
--   ★★★ 顺序很重要：★ 场景件要**先**占位（ReserveTile），
--     ★★★ 否则后面的 PopulateVoronoi 可能把道具放在宝箱正中央。
function Graph:ConvertGround(map, spawnFN, entities, check_col)
	local nodes = self:GetNodes(true)
	for k,node in pairs(nodes) do
		node:ConvertGround(map, spawnFN, entities, check_col)
	end
end

-- ★★★ Populate(map, spawnFN, entities, check_col)
--   ★★ ⚠★★ 疑似缺陷（严重）：★ 本函数**从未被调用**
--     （★ grep 核实 map/ 与 forest_map.lua 内零调用点），
--     ★★ 而且它内部 :724 调用 `spawnFN.spawnfordefault(...)` ——
--       ★★★ **spawnfordefault 在 forest_map.lua:386-390 的 SpawnFunctions
--         表里根本不存在**（只有 pickspawnprefab / pickspawngroup /
--         pickspawncountprefabforground 三个）。
--     ★★★ ⇒ 若这个函数被调用，:724 必定 nil 索引崩溃。
--   ★★★ ⇒ 结论：★ 这是个**彻底死掉的函数**，两处断链。
--     ★★ 它描述的是**上一代散布架构**（按「图内空白区」补默认物品），
--       ★★★ 而现在的架构是 PopulateVoronoi（:729）按胞元采样点散布。
--   ★★ 保留它说明架构迁移后清理不彻底。★
function Graph:Populate(map, spawnFN, entities, check_col)
	local nodes = self:GetNodes(true)
	--print(self.id.." Populating "..GetTableSize(nodes).." nodes...")
	for k,node in pairs(nodes) do
		node:Populate(map, spawnFN, entities, check_col)
	end
	--[[
	local edges = self:GetEdges(true)
	--print("Populating "..GetTableSize(nodes)+GetTableSize(self.exit_edges).." edges...")
	for k,edge in pairs(edges) do
		edge:Populate(map, spawnFN, entities, check_col)
	end

	for k,edge in pairs(self.exit_edges) do
		edge:Populate(map, spawnFN, entities, check_col)
	end
	--]]

    -- Spawn the default items
	local children = self:GetChildren()

	local graph_minus = {}
	local graph_points = {}

	for k,child in pairs(children) do
		-- Generate a list of points that are inside
		-- minus the areas that their subchildren take up
		-- This list is all the area that is not covered by nodes
-- ★★★ child:GetArea(map, graph_points, graph_minus)
--   ★★★ ⚠ 与上面同源的断链：★ **Graph 没有 GetArea 方法**
--     （★ grep 核实：本文件无 GetArea 定义，Node 也没有）。
--     ★★ ⇒ 同样会 nil 索引崩溃。
--   ★★ ⇒ ★★ Populate + GetArea 是**成对的死代码**，
--     ★★★ 它们一起描述了「上一代按区域补默认物品」的完整方案。
		child:GetArea(map, graph_points, graph_minus)
		--print(self.id..":"..child.id.." graph_points now ".. GetTableSize(graph_points))
		--print(self.id..":"..child.id.." graph_minus now ".. GetTableSize(graph_minus))
	end

	for key,point in pairs(graph_points) do
	 	--print(key,graph_minus[key])
	 	if graph_minus[key] == nil then
-- ★★ spawnFN.spawnfordefault(map, point.x, point.y, entities, check_col)
--   ★★★ 该函数在 SpawnFunctions 表（forest_map.lua:386-390）里不存在。
--     ★★ ⇒ 第三处断链。★ 三处断链共同证明：这是彻底的死代码。
	 		spawnFN.spawnfordefault(map, point.x, point.y, entities, check_col)
	 	end
	end
-- ★═══ Populate 结束（死代码）═══
end

-- ══════════════ ★★★ PopulateVoronoi：★ 真正的散布调度 ══════════════
-- ★★★ 这是本文件**唯一真正被调用**的散布入口。
--   消费：forest_map.lua:873
--     `topology_save.root:PopulateVoronoi(SpawnFunctions, entities,
--      map_width, map_height, translated_prefabs, save.map.generated.densities)`
--   ★★ 两个循环，结构很特别（★★ 容易读错）：
--     · 第一个循环遍历 **self 的节点**（:730 GetNodes(false) ← ★ 不递归）
--       ├ node:PopulateVoronoi(...)            —— 房间自己的内容物
--       └ node:PopulateChildren(...)          —— 背景房间的内容物
--     · 第二个循环遍历 **子图**，对子图**整个递归**调用 (:742)
-- ★★★ ⇒ 语义：★ 每个 Graph 负责「自己节点的房间内容」+「这些节点的背景」，
--     ★★ 然后把子图整体交给子图自己处理。
--   ★★★ 这就解释了 storygen.lua 的 Graph 层级为何重要：
--     ★★ 任务（task）的背景房间由**它自己**的 background 决定。
function Graph:PopulateVoronoi(spawnFN, entities, width, height, world_gen_choices, prefabDensities)
-- ★★ GetNodes(false) ——★ 只取本图节点（★ 不含子图）。
--   ★★★ 与 :681/:688 的 incChildren=true 形成对比。
--     ★★★ 这是**正确的**：因为 :742 的第二个循环会递归处理子图，
--       ★★ 若这里也递归就会**重复散布**子图的节点！
--     ★★ ⇒ ★★ 这两处的 incChildren 取值差异是必需的，不是随意。
	local nodes = self:GetNodes(false)
	--print(self.id.." Populating "..GetTableSize(nodes).." nodes...")
	for k,node in pairs(nodes) do
-- ★★★ node:PopulateVoronoi(spawnFN, entities, w, h, choices, prefabDensities)
--   ★★★ 真正干活的地方（graphnode.lua:330）：
--     · countprefabs 定数摆放
--     · distributeprefabs + distributepercent 权重散布
--     · PopulateExtra 用世界生成设置加量
--   ★★ E2 缺陷的现场就在里面（graphnode.lua:369/421/392/441 的静默 return）。
		node:PopulateVoronoi(spawnFN, entities, width, height, world_gen_choices, prefabDensities)
-- ★★ local perTerrain = false
--   ★★★ 语义：**「背景房间是否需要按地块类型分别指定」**。
--     ★★ 当 data.background 是一张 {地块 → 房间名} 的表时为 true。
--     ★★ 这是洞穴群系（多地块混合）的**唯一**支持机制，
--       ★★★ 由 graphnode.lua:536-537 兑现：`room = backgroundRoom[points_type[i]]`。
--     ★★★ ⇒ ★★ 「生物群系」在 DST 里可以是「一个图内多种地块」。
--   ★★★ 但⚠ 注意本函数读的是 **self.data.background**（Graph 的），
--     ★★ 而 Graph 的 data.background 来自 args.background
--       ★★ （storygen.lua:1284 `background=task.background_room`）。
--     ★★ ⇒ ★★ 所以 perTerrain 的判定依据是「task 的 background_room 是不是表」。
		local perTerrain = false
		if type(self.data.background) == type({}) then
			perTerrain = true
		end
-- ★★ local backgroundRoom = self:GetBackgroundRoom(self.data.background)
--   ★★★ GetBackgroundRoom（:746）会按类型分派：
--     · string ⇒ GetRoomForName → Rooms.GetRoomByName
--     · table  ⇒ 逐项 GetRoomForName ⇒ 返回 {地块 → 房间} 的表
--     · 其他   ⇒ nil
--   ★★ ⚠ 语义缺陷：★ 对于 table 形式，:752 的 `rooms[ground] = GetRoomForName(name)`
--     ★★ 若某个房间名不存在 ⇒ rooms[ground] = nil ⇒
--       ★★★ graphnode.lua:537 `room = backgroundRoom[points_type[i]]` 得 nil，
--         ★★★ 然后 :540 `room.contents.distributepercent` ⇒ **崩溃**。
--     ★★★ ⇒ 若某关卡声明了 {CAVE="BGGrass", MUD="不存在的房间"}，生成会崩。
--   ★★★ 这与 level.lua 的「四条 assert 迁移」风格**完全相反**：
--     ★★ 房间名这种外部字符串引用**零校验**。★ 架构不一致。
		local backgroundRoom = self:GetBackgroundRoom(self.data.background)
-- ★★★ node:PopulateChildren(spawnFN, entities, w, h, backgroundRoom,
--   perTerrain, world_gen_choices)
--   ★★★★ 真实缺陷（参数个数不匹配）：
--   ★★ graphnode.lua:498 的签名是
--     `Node:PopulateChildren(spawnFn, entitiesOut, width, height,
--      backgroundRoom, perTerrain, world_gen_choices, prefabDensities)`
--     ★★ 共 **8 个参数**（最后是 prefabDensities）；
--   ★★ 而这里只传了 **7 个** ⇒ ★★ prefabDensities = nil。
--   ★★★ 后果：graphnode.lua:558 `prefabDensities[self.id] = {}`
--     ★★★ **在 prefabDensities 为 nil 时执行 ⇒ 必然崩溃**
--       （attempt to index a nil value）。
--   ★★★★ 但它**实际没崩** ⇒ 说明 graphnode.lua:501-504 的早退
--     `if self.children_populated == true then return end` 起了作用，
--     ★★★ 或者 ★ children 为 nil（:518 的 if）使 :558 未被执行。
--   ★★★★ ⚠ 推论：★ **PopulateChildren 在有 children 的图上会崩**，
--     ★★★ 而实际世界生成中每个 task 的节点都有 children（背景节点），
--       ★★★ 所以它**必然**是走的早退分支或 children 为空的路径。
--       ★★ 换句话说：★ **PopulateChildren 这条路径事实上从未真正执行过散布**。
--   ⚠★★ 这是本文件最严重的一处缺陷：★ 「背景房间的内容物」可能根本没被散布。
--     ★★ 需要运行时验证才能确定（★ 本次只做静态分析，不改代码）。
		node:PopulateChildren(spawnFN, entities, width, height, backgroundRoom, perTerrain, world_gen_choices)
	end
-- ★★ for k,child in pairs(self:GetChildren()) ——★ 递归处理子图。
--   ★★★ 注意 :742 是**对子图整体再调一次** PopulateVoronoi，
--     ★★ 于是子图的节点会在子图自己的 :730 循环里被处理。
--   ★★★ ⇒ 结构上是「广度优先的分层派发」，不是「深度优先」。
--     ★★ 结果正确（每个节点恰好被处理一次），但可读性一般。
	for k,child in pairs(self:GetChildren()) do
		child:PopulateVoronoi(spawnFN, entities, width, height, world_gen_choices, prefabDensities)
	end
-- ★═══ PopulateVoronoi 结束 ════
end

-- ★★ GetBackgroundRoom(roomName)：★ 按类型分派（详见 :738 的调用点注释）。
function Graph:GetBackgroundRoom(roomName)
-- ★★ if type(roomName) == type("") ——★ 字符串形式：一个房间名给所有地块。
	if type(roomName) == type("") then
		return self:GetRoomForName(roomName)
-- ★★ elseif type(roomName) == type({}) ——★★ 表形式：多地块各配一个房间。
--   ★★★ 这是「混合地块群系」的数据表达方式。
--     ★★ 对照 map/rooms/cave/*.lua 里的 background 定义
--       （★ caves.lua 等洞穴任务大量使用这种表）。
	elseif type(roomName) == type({}) then
		local rooms = {}
		for ground,name in pairs(roomName) do
			rooms[ground] = self:GetRoomForName(name)
		end
		return rooms
	end
	return nil
end

-- ★★ GetRoomForName(roomName)：★ 直接透传给 Rooms。
--   ★★ 注意：**没有 nil 检查**。★ 若房间名不存在，返回 nil，
--     ★★ 崩溃点被推迟到 graphnode.lua:540（见 :738 的 ⚠）。
function Graph:GetRoomForName(roomName)
	local backgroundRoom = Rooms.GetRoomByName(roomName)
	return backgroundRoom
end


-- ★★★ GlobalPrePopulate：★ 全局「前置」散布钩子，只做一件事。
--   ★★ 消费：forest_map.lua:842（在 ConvertGround 之前）。
--   ★★★ 顺序意义：★ 「前置」= 在所有房间内容物之前。
--     ★★ 所以它适合放**全局唯一**的东西（虫洞配对这类）。
function Graph:GlobalPrePopulate(entities, width, height)
-- ★★ self:ProcessInsanityWormholes(entities, width, height)
--   ★★★ 疯狂虫洞（OneshotWormhole 标签）：★ 见 :814 的详细说明。
--   ★★ 消费：forest_map.lua 的标注是「在 Voronoi 之前」——
--     ★★★ 但实际是「在 PopulateVoronoi 之前、ConvertGround 之前」。
	self:ProcessInsanityWormholes(entities, width, height)
end


-- ══════════════ GlobalPostPopulate：★ 全局「后置」散布钩子 ══════════════
-- ★★ 消费：forest_map.lua:889（在 PopulateVoronoi 之后、实体清理之前）。
-- ★★★ 三件事，顺序有意义：
--   ① SwapOutWormholeMarkers  —— 把占位标记配成真正的一对虫洞
--   ② ResolveCustomizationPrefabs —— 自定义皮肤 prefab → 真 prefab
--   ③ ResolveRandomizationPrefabs —— 随机化 prefab → 真 prefab
-- ★★ ⇒ ①②③ 都在「把占位/代理名字换成实际 prefab」，是同一类收尾工作。
function Graph:GlobalPostPopulate(entities, width, height)
-- ★★ 原始注释：-- Spawn wormhole pairs (randomly, for now)
--   ★★ 「randomly, for now」★ 暗示这是临时方案。
	-- Spawn wormhole pairs (randomly, for now)
	self:SwapOutWormholeMarkers(entities, width, height)

	self:ResolveCustomizationPrefabs(entities, width, height)

	self:ResolveRandomizationPrefabs(entities, width, height)
end

-- ★★★ AddRequiredPrefab(prefab)：★ 计数 +1（★ 不是置位）。
--   ★★ 三个调用点：:58（构造，task 级）、:454（AddNodeByNode，房间级）。
--   ★★ 「计数」语义是关键：★ 同一 prefab 在 3 个房间都要求 ⇒ 需要 3 个。
function Graph:AddRequiredPrefab(prefab)
    if self.required_prefabs[prefab] == nil then
        self.required_prefabs[prefab] = 0
    end
    self.required_prefabs[prefab] = self.required_prefabs[prefab] + 1
end

-- ★★★ GetRequiredPrefabs()：★ 递归汇总全图的必需 prefab 计数。
--   ★★ 这是「三重来源求和」的**来源 2**（forest_map.lua:936-944）：
--     来源 1 = level.required_prefabs（关卡级）
--     ★★ 来源 2 = 本函数（图级 + 房间级，递归）
--     来源 3 = ocean_population 房间的 required_prefabs（海洋级）
--   ★★ 三者在 forest_map.lua:961-974 汇总后与实际数量比对。
-- ★★★ ⚠ 性能：★ 本函数对每个节点都 deepcopy 一次（:787），
--   ★★ 而它被 :788 循环调用 ⇒ **O(节点数 × 节点数)**！
--     ★★ 2000 节点 ⇒ 400 万次。★ 这是本文件最实质的性能问题。
--   ⚠ 推理依据：:787 `deepcopy(self.required_prefabs)` 在函数开头，
--     ★★ 而 :788 的 for 循环每次迭代都调一次本函数（递归）。
--   ★★ 正确做法：把 deepcopy 提到循环外，或改为浅拷贝 + 只读。
function Graph:GetRequiredPrefabs()
    local req = deepcopy(self.required_prefabs)
    for k,child in pairs(self:GetChildren()) do
        for prefab, count in pairs(child:GetRequiredPrefabs()) do
            if req[prefab] == nil then
                req[prefab] = count
            else
                req[prefab] = req[prefab] + count
            end
        end
    end

    return req
end

-- ★★ IsNodeTagged(node, tag)：★ 文件级局部函数（非方法）。
--   ★★ 消费点：:817、:830、:1030、:1037、:1040。
--   ★★★ 「局部函数」而非 Graph 方法 ⇒ 外部无法复用。★ 小小的设计选择。
local function IsNodeTagged(node, look_for_tag)
	if not node.data.tags then
		return false
	end
	for i,tag in ipairs(node.data.tags) do
		if tag == look_for_tag then
			return true
		end
	end
	return false
end


-- ══════════════ ★★★ ProcessInsanityWormholes ══════════════
-- ★★★ 功能：给带 "OneshotWormhole" 标签的节点**成对放置传送门**。
-- ★★ 机制：★ 在该节点的前后两个邻居房间各放一个虫洞，
--   ★★ 两者用 teleporter.target 互相指向 ⇒ 玩家走过去被传送到下一区。
-- ★★★ 这是「用传送门代替修路」的解法（Quagmire 的部分区域靠它）。
-- ★★ 消费路径：GlobalPrePopulate(:766) ← forest_map.lua:842
--   ★★★ 也就是说：**虫洞在 ConvertGround 之前就已放置**。
--     ★★ 而 DoWormholeLayout 内部会 ReserveAndPlaceLayout（:868），
--       ★★★ 而 reserve 会占住格子 ⇒ 后续散布会绕开。★ 顺序正确。
function Graph:ProcessInsanityWormholes(entities, width, height)
	--print("*** PROCESSSING INSANITY WORMHOLES ***")

-- ★★ IsNodeAWormhole：★ 闭包，判断节点是否带该标签。
	local IsNodeAWormhole = function(node) return IsNodeTagged(node, "OneshotWormhole") end

-- ★★★★ NeighborNodes(task, node)：★★ 本函数是全文件最「硬」的一段。
-- ★★★ 它要求：**该节点在本图内恰好 1 个邻居，且在 exit 边里恰好 1 个邻居**。
--   ★★ 语义：★ 虫洞节点位于「房间 A」与「跨图连接 B」的交界处，
--     ★★ 于是虫洞 A 放在 A 里、虫洞 B 放在 B 里 ⇒ 玩家被传过去。
--   ★★★ 这个设计前提很强 ⇒ 一旦拓扑不满足，:826/:846 的 assert 会**崩溃**。
--   ★★ 冲突来源（★ 重要）：
--     · crosslink（:602）会给节点加邻居 ⇒ ★ 破坏「恰好 1 个」；
--     · MakeLoop（:647）会给端点加第 2 个邻居 ⇒ ★ 同样破坏；
--     · MakeHub（:653）★ 同样。
--   ★★★★ ⇒ ★★ 只要带 OneshotWormhole 标签的节点所在图有 hub/loop/crosslink，
--     ★★★ 世界生成就会在 :826 或 :846 崩溃。
--   ⚠ 推理依据：:824/:828 明确要求「排除 blocker_blank」，
--     ★★★ 可见作者考虑过 blocker 但**没考虑** crosslink/hub/loop。
	local NeighborNodes = function(task, node)
		local prevNode = nil
		local nextNode = nil
		for edgeId,edge in pairs(task:GetEdges(false)) do
		    --print("internal edge",edge.node1.id, edge.node2.id)
-- ★★ if edge.node1.id == node.id and not edge.node2.data.blocker_blank then
--   ★★★ blocker_blank 排除的理由：★ storygen.lua:1056 给每个 entrance
--     ★★★ 挂了 2 个 blocker_blank 子节点，若不排除它们，
--       ★★★ entrance 的度会是 3 ⇒ 直接违反「恰好 1 个」。
			if edge.node1.id == node.id and not edge.node2.data.blocker_blank then
			    --print("\tlink!!")
-- ★★★★ assert(nextNode == nil, "We already have a node from this task!")
--   ★★★ 「宁死不屈」的设计：宁可在生成期崩溃，
--     ★★★ 也不产出一个错位的虫洞（错位会导致玩家传送到虚空）。
--   ★★★ 这与本文件里大量「只 print 就 return」的容错风格**完全相反**，
--     ★★ 但在这里崩溃**是对的**：虫洞错位是致命的、不可挽回的。
--   ★★★ ⇒ ★★ 通用原则：**「错了就崩」还是「错了就凑合」取决于错误是否可恢复**。
				assert(nextNode == nil, "We already have a node from this task!")
				nextNode = edge.node2
			elseif edge.node2.id == node.id and not edge.node1.data.blocker_blank then
			    --print("\tlink!!")
				assert(nextNode == nil, "We already have a node from this task!")
				nextNode = edge.node1
			end
		end
-- ★★ for edgeId,edge in pairs(self:GetExitEdges(false)) ——★ exit 边。
--   ★★ ⚠ 变量遮蔽：★ 这里复用了上一轮的 `edge` 变量名（pairs 的第二参）。
--     ★★ 上一轮是 `for edgeId,edge in pairs(task:GetEdges(false))`，
--       ★★★ 这轮又在 :836 用 edge.node1 ⇒ 若上一轮循环因 else 分支没赋值，
--         ★★★ edge 仍是上一轮的值。★ 靠 if/elseif 结构恰好不出错，
--           ★★★ 但这是**极易读错**的写法。⚠ 建议拆成两个变量名。
        for edgeId,edge in pairs(self:GetExitEdges(false)) do
            --print("external edge",edge.node1.id, edge.node2.id)
            if edge.node1.id == node.id then
                --print("\tlink!!")
                assert(prevNode == nil, "We already have a node from the other task!")
                prevNode = edge.node2
            elseif edge.node2.id == node.id then
                --print("\tlink!!")
                assert(prevNode == nil, "We already have a node from the other task!")
                prevNode = edge.node1
            end
		end
-- ★★★★ assert(prevNode ~= nil and nextNode ~= nil,
--   "A wormhole blocker must have exactly 2 neighbors!!")
--   ★★★★ 全文件最严格的一条断言：「必须恰好 2 个邻居」。
--   ★★★ 它同时覆盖两种缺失：本图内没有（nextNode 为 nil）、
--     ★★★ 跨图边里没有（prevNode 为 nil）。
--   ★★★ 而「多于 1 个」由 :826/:830/:838/:842 的四个 assert 覆盖。
--   ★★ ⇒ 合起来是「恰好 2 个」的完整校验。★ 严谨。
		assert(prevNode ~= nil and nextNode ~= nil, "A wormhole blocker must have exactly 2 neighbors!!")
		return prevNode, nextNode
	end

-- ★★ DoWormholeLayout(node, data)：★ 在指定节点放一个 WormholeOneShot 布局。
	local DoWormholeLayout = function(node, data)
-- ★★ obj_layout 在**函数内 require** ——★ 延迟加载，打破循环依赖。
--   ★★ 值得学的模式：★ storygen.lua:251 也是同样的局部 require。
		local obj_layout = require("map/object_layout")
		local prefab_list = {}

		-- Get the list of special items for this node

-- ★★ add_fn：★ 把布局里的 prefab 塞进 entitiesOut。
--   ★★ 注意 `rand_offset = false` ⇒ ★ 虫洞位置是**格子中心**，完全确定。
--     ★★ 对比 graphnode.lua 的普通散布会加随机偏移。
--     ★★★ ⇒ 虫洞位置可复现，普通散布不可。
		local add_fn = {fn=function(...) node:AddEntity(...) end,args={entitiesOut=entities, width=width, height=height, rand_offset = false, debug_prefab_list=prefab_list}}

-- ★★ obj_layout.LayoutForDefinition("WormholeOneShot") ——★ 按名字取布局。
		local layout = obj_layout.LayoutForDefinition("WormholeOneShot")
-- ★★ ConvertLayoutToEntitylist(layout) ——★ 布局 → prefab 列表。
		local prefabs = obj_layout.ConvertLayoutToEntitylist(layout)

-- ★★ for i,p in ipairs(prefabs) ——★ 找名字里带 "wormhole" 的那个。
--   ★★★ 用 string.find 而非精确匹配 ⇒ ★ 匹配任意含 wormhole 的名。
--     ★★ 这是一种「按约定而非按契约」的查找 ★：
--       ★★★ 若哪天布局里的虫洞改名（不叫 wormhole 了），
--         ★★★ 这里会**静默找不到**，:862 的 break 不执行，
--           ★★★ 结果是「布局放了但没有配对目标」⇒ 传送门失效。★ 无日志。
		for i,p in ipairs(prefabs) do
			if string.find(p.prefab, "wormhole") ~= nil then
				p.properties = data
				break
			end
		end

-- ★★ obj_layout.ReserveAndPlaceLayout(node.id, layout, prefabs, add_fn)
--   ★★★ ReserveAndPlace = ★「先占格再放置」⇒ 后续散布会绕开。
--     ★★★ 这是本文件里少数几处「主动预留」的地方（对比 :856 只是转交）。
--   ★★ ⚠ 注意 bug-patterns.md E2 提到：★ 这类调用内部有
--     ★★ `if rcx == nil then return end` 的静默失败（场景件丢失）。
		obj_layout.ReserveAndPlaceLayout(node.id, layout, prefabs, add_fn)

	end

-- ★★ ProcessWormholes(task, node)：★ 取邻居 + 分配一对 ID + 各放一个。
	local ProcessWormholes = function(task, node)
		local prevNode, nextNode = NeighborNodes(task,node)
		--print("Wormhole connecting nodes", prevNode.id, nextNode.id)

-- ★★★ id1/id2 = MIN_WORMHOLE_ID 与 +1 ——★ 一对连续 ID。
--   ★★★ 用「两个连续整数」而非两个随机数：★ 保证配对唯一性。
--     ★★ ⚠ 隐患：★ 每次配对都从当前 MIN 递增 2，
--       ★★★ 所以虫洞实体 ID 是**确定性递增**的 ⇒ 高度可复现。✔
--     ★★ 但若某个 task 有多个虫洞节点且 pairs 顺序不定（:888），
--       ★★★ 它们拿到的 ID 顺序就随机 ⇒ 但 ID 本身不携带语义 ⇒ 无影响。
		local id1 = self.MIN_WORMHOLE_ID
		local id2 = self.MIN_WORMHOLE_ID + 1
-- ★★ self.MIN_WORMHOLE_ID = self.MIN_WORMHOLE_ID + 2 ——★ 推进游标。
		self.MIN_WORMHOLE_ID = self.MIN_WORMHOLE_ID + 2

-- ★★ firstWormholeData = {id=id1, data={teleporter={target=id2}}}
--   ★★★ teleporter.target 指向对方 ID ⇒ ★★ 这就是「互指」的实现。
--   ★★ 注意 ID 顺序固定（先 id1 后 id2）⇒ 无随机性。
		local firstWormholeData = {id=id1, data={teleporter={target=id2}}}
		local secondWormholeData = {id=id2, data={teleporter={target=id1}}}

		DoWormholeLayout(prevNode, firstWormholeData)
		DoWormholeLayout(nextNode, secondWormholeData)
	end

-- ★★ TryProcessTask(task)：★ 遍历该 task 的所有节点找虫洞。
	local TryProcessTask = function(task)
-- ★★ for id,node in pairs(task.nodes) ——★★ pairs 遍历。
--   ★★ 但如 :876 处所注：遍历顺序只影响 ID 分配次序，不影响结果。
--     ★★ ⇒ 这里**不引入**不可复现性。✔
		for id,node in pairs(task.nodes) do
			if IsNodeAWormhole(node) then
				ProcessWormholes(task, node)
			end
		end
	end

	for id,task in pairs(self:GetChildren()) do
		TryProcessTask(task)
	end

end

-- ══════════════ SwapOutWormholeMarkers ══════════════
-- ★★★ 与 ProcessInsanityWormholes 是**两套独立的虫洞机制**：
--   · ProcessInsanityWormholes —— 图阶段，直接放成对的虫洞布局；
--   · SwapOutWormholeMarkers   —— ★ 散布**之后**，把「占位标记」
--     ★★ entities["wormhole_MARKER"] 配成对，换成真 prefab。
--   ★★ ⇒ 后者是给**房间内容物**里写了 wormhole_MARKER 的场景用的。
--   ★★ 两者都用 MIN_WORMHOLE_ID 游标 ⇒ ★★ ID 不会冲突（共享同一个游标）。
function Graph:SwapOutWormholeMarkers(entities, width, height)
-- ★★ if entities["wormhole_MARKER"] ~= nil then ——★ 没有标记就整体跳过。
--   ★★ 注意 ★ 这个检查是「实体表里有没有这个 key」，
--     ★★ 而不是「有没有内容」⇒ 空表 { } 也会进入分支。
--     ★★ 后果：★ 空表时 :909 的 id 游标不推进（:930 才赋值），
--       ★★ 然后 :933 把 key 删掉。★ 无害但逻辑冗余。
	if entities["wormhole_MARKER"] ~= nil then
-- ★★ assert(self.wormholeprefab ~= nil, "Level must specify a wormhole
--   prefab when wormholes are used.")
--   ★★★ 好的断言：★ 用**条件化**的措辞（when wormholes are used），
--     ★★★ 而不是笼统的「必须配置」。★ 错误信息可读性高。
--   ★★ wormholeprefab 的来源：storygen.lua:77-79 从 gen_params 挂到 rootNode。
		assert(self.wormholeprefab ~= nil, "Level must specify a wormhole prefab when wormholes are used.")

		if entities[self.wormholeprefab] == nil then
			entities[self.wormholeprefab] = {}
		end

-- ★★ local id = self.MIN_WORMHOLE_ID ——★ 从当前游标开始。
--   ★★★ 与 :876 同一套 ID 分配机制 ⇒ 两个机制共享 ID 空间。
		local id = self.MIN_WORMHOLE_ID

-- ★★ firstMarkerData = nil ——★ 「攒两个配一对」的状态变量。
		local firstMarkerData = nil
-- ★★ 遍历所有 marker（★ ipairs 数组 ⇒ 顺序稳定 ✔）。
		for i,data in ipairs(entities["wormhole_MARKER"]) do
-- ★★ 第一个：存下来，等第二个。
				if firstMarkerData == nil then
					firstMarkerData = data
				else
-- ★★ else：第二个到了 ⇒ 配成一对。
					local secondMarkerData = data
-- ★★★ firstMarkerData["id"] = id ——★ 就地改写第一个的 id。
--   ★★★ 注意这是**就地修改** entities 数组里的元素（不是拷贝）。
--     ★★ 因为 marker 本来就是要被丢弃的占位符（:933），所以无副作用。
--   ★★ ⇒ 但这依赖「wormhole_MARKER 是一次性的」这个隐含前提。
					firstMarkerData["id"] = id
					secondMarkerData["id"] = id + 1
					id = id + 2

-- ★★★ firstMarkerData["data"] = {teleporter={target=secondMarkerData["id"]}}
--   ★★ 互指的写入（第一个指向第二个）。★ 下一行对称地写第二个。
--   ★★★ 注意 ⚠ ：如果标记总数是**奇数**，最后一个会被留在 :911 的
--     ★★ firstMarkerData 里，:933 把整个 key 删掉 ⇒
--       ★★★ **最后一个 marker 连带它的坐标一起消失** ⇒ 静默丢失。
--       ★★ 不会有任何日志。★ 这是个真实的静默失败。
					firstMarkerData["data"] = {teleporter={target=secondMarkerData["id"]}}
					secondMarkerData["data"] = {teleporter={target=firstMarkerData["id"]}}

					table.insert(entities[self.wormholeprefab], firstMarkerData)
					table.insert(entities[self.wormholeprefab], secondMarkerData)

					firstMarkerData = nil
				end
		end
-- ★★ self.MIN_WORMHOLE_ID = id ——★ 游标回写（★ 让两套机制继续共享 ID 空间）。
		self.MIN_WORMHOLE_ID = id
	end

-- ★★ entities["wormhole_MARKER"] = nil ——★ 删掉占位 key。
--   ★★★★ ⚠ 上面 :921 处指出的问题在这里落地：
--     ★★ 奇数个 marker 时，最后一个的位置数据**被整体删除**，
--       ★★★ 那个位置本来应该有东西（虫洞），现在什么都没有。
--       ★★★ **无 print、无统计、无 assert** ⇒ 完全静默。
--     ★★ 修复方向：循环结束后若 firstMarkerData ~= nil 则应报错或补一个单端虫洞。
	entities["wormhole_MARKER"] = nil
end

-- ★★★ ResolveCustomizationPrefabs：★ 「自定义皮肤」代理 prefab → 真 prefab。
--   ★★ 场景：玩家用「换皮」选项把 spideregg 换成 spider_dropper。
--   ★★ 机制：★ 生成期先用代理名占位，★ **最后一步**统一换成真名。
--   ★★★ 为什么放在最后：★ 因为只有到这时才知道玩家选了什么皮肤。
function Graph:ResolveCustomizationPrefabs(entities, width, height)
	local customization_swaps = {}
-- ★★ for prefab in pairs(entities) ——★★ pairs 遍历。
--   ★★★ ⚠ 危险点：★ :951 `entities[proxy_prefab] = nil` **在遍历中删键**！
--   ★★ 在 Lua 里「遍历时修改表」是**未定义行为**：
--     ★★★ 被删的键可能被跳过，也可能后续元素错位。
--     ★★★ 实践中 Lua 的 next 实现通常能容忍删当前键，
--       ★★ 但这不是规范保证。★ 严格的移植（如移植到 C++/Rust）会出问题。
--   ★★★ ⚠ 同一模式在 :966 又出现一次（ResolveRandomizationPrefabs）。
	for prefab in pairs(entities) do
-- ★★ PrefabSwaps.ResolveCustomizationPrefab(prefab) ——★ 外部模块。
--   ★★ 返回 nil 表示「这个 prefab 不是皮肤代理」⇒ 跳过。
		local real_prefab = PrefabSwaps.ResolveCustomizationPrefab(prefab)
		if real_prefab then
-- ★★ 收集：真prefab → {代理prefab, …} 的反向表。
			customization_swaps[real_prefab] = customization_swaps[real_prefab] or {}
			table.insert(customization_swaps[real_prefab], prefab)
		end
	end
-- ★★ for real_prefab, proxies in pairs(customization_swaps) ——★ 逐个真 prefab 处理。
	for real_prefab, proxies in pairs(customization_swaps) do
-- ★★ entities[real_prefab] = entities[real_prefab] or {} ——★ 懒建（可能是 0 个）。
--   ★★★ 潜在副作用：★ 若真 prefab 本来一个都没生成，
--     ★★ 这里会创建一个**空表** entities[real_prefab] = {}。
--     ★★★ ⇒ 后续 forest_map.lua:904-918 的「按 mult 下调密度」会看到
--       ★★★ `#entities[prefab] == 0` ⇒ 跳过（不崩）。
--       ★★★ 但 forest_map.lua:961 的必需 prefab 校验：
--         ★★ `entities[prefab] == nil or #entities[prefab] < count`
--           ★★★ **空表不是 nil** ⇒ `#{} = 0 < count` ⇒ 正确判失败。✔
--     ★★ ⇒ 结论：空表的副作用被下游正确处理了，但纯属侥幸。
		entities[real_prefab] = entities[real_prefab] or {}
		for _, proxy_prefab in ipairs(proxies) do
-- ★★ for _, entity in ipairs(entities[proxy_prefab]) do ——★ 把代理的实体搬进真表。
--   ★★★ 注意搬的是**元素引用**（不是 deepcopy）⇒
--     ★★ 同一个实体表可能被同时引用在两个 key 下。
--     ★★ 但 :951 立刻删掉代理 key ⇒ 最终只有一个引用。✔
			for _, entity in ipairs(entities[proxy_prefab]) do
				table.insert(entities[real_prefab], entity)
			end
			entities[proxy_prefab] = nil
		end
	end
end

-- ★★★ ResolveRandomizationPrefabs：★ 「随机化」代理 prefab → 真 prefab。
--   ★★ 场景：★ 某些生物的变体是**运行时随机决定**的（不是玩家选的），
--     ★★ 所以生成期用随机化代理名占位，最后统一解析。
--   ★★★ 与 :936 的区别：
--     · Customization 是**玩家选择**（多对一，:941 收集成列表）；
--     · Randomization 是**单对多**（:960 每个实体单独 resolve）。
function Graph:ResolveRandomizationPrefabs(entities, width, height)
	for prefab in pairs(entities) do
-- ★★ if PrefabSwaps.IsRandomizationPrefab(prefab) ——★ 判定循环。
--   ★★★ 与 :939 相反：这里是「先问是不是」，那里是「问能解析成什么」。
		if PrefabSwaps.IsRandomizationPrefab(prefab) then
			for i, data in ipairs(entities[prefab]) do
-- ★★ real_prefab = PrefabSwaps.ResolveRandomizationPrefab(prefab)
--   ★★★ 在**每个实体的循环内**调用（:959-960），
--     ★★ 而非像 :936 那样先收集。★ 意味着同一个代理名可能解析出不同结果
--       ★★ （如果 ResolveRandomizationPrefab 内部含随机）。
--     ★★★ 这其实正是「随机化」的语义。★ 设计正确。
				local real_prefab = PrefabSwaps.ResolveRandomizationPrefab(prefab)
				if entities[real_prefab] == nil then
					entities[real_prefab] = {}
				end
				table.insert(entities[real_prefab], data)
			end
-- ★★ entities[prefab] = nil ——★★ **遍历中删键**（同 :938 的问题）。
			entities[prefab] = nil
		end
	end
end


-- ══════════════ ApplyWormhole ══════════════
-- ★★★ 手工在两个坐标之间放一对虫洞（★ 不依赖 Voronoi 邻接）。
--   ★★ 消费：:1012（SwapWormholesAndRoadsExtra）与 :1068（SwapWormholesAndRoads）。
--   ★★ 后者当前**无调用点**（★ forest_map.lua:540 的 if false 关掉了它）。
function Graph:ApplyWormhole(entities, width, height, x1, y1, x2, y2)
    assert(self.wormholeprefab ~= nil, "Level must specify a wormhole prefab.")

-- ★★ 四重边界检查 + `> 1` ——★ 排除贴边坐标。
--   ★★★ 为什么要求 > 1：★ 坐标换算（:978）会减 width/2，
--     ★★ 坐标 0 或 1 换算后落在世界边缘 ⇒ 传送门会放在边界外。
--   ★★ 四重 nil 检查防止上游返回不完整数据。
	if x1 ~= nil and x2 ~= nil and y1 ~= nil and y2 ~= nil and x1>1 and x2 >1 and y1>1 and y2>1 then
		--print("\t\t\t(".. x1 ..",".. y1 ..")\t<--->\t(".. x2 ..",".. y2 ..")")

-- ★★ xx1 = math.floor((x1 - width/2)*TILE_SCALE*10)/10 ——★ 坐标换算。
--   ★★★ 精度控制：★ 乘 10 再 floor 再除 10 ⇒ 保留 1 位小数。
--     ★★★ 这与 graphnode.lua:146 的 *100/100、:201-202 的 *100/100 一致，
--       ★★★ 是全项目统一的坐标精度约定（避免浮点尾巴写进存档）。
		local xx1 = math.floor((x1 - width/2)*TILE_SCALE*10)/10
		local yy1 = math.floor((y1 - height/2)*TILE_SCALE*10)/10
		local firstMarkerData = {data={teleporter={target=self.MIN_WORMHOLE_ID+1}}, id = self.MIN_WORMHOLE_ID, x=xx1,z=yy1}

		local xx2 = math.floor((x2 - width/2)*TILE_SCALE*10)/10
		local yy2 = math.floor((y2 - height/2)*TILE_SCALE*10)/10
		local secondMarkerData = {data={teleporter={target=self.MIN_WORMHOLE_ID}}, id = self.MIN_WORMHOLE_ID+1, x=xx2,z=yy2}

		self.MIN_WORMHOLE_ID = self.MIN_WORMHOLE_ID + 2

		table.insert(entities[self.wormholeprefab], firstMarkerData)
		table.insert(entities[self.wormholeprefab], secondMarkerData)
	else
-- ★★ else 分支：坐标不合格 ⇒ 记错误。
--   ★★★ 这里**记错误而不崩溃** ——与 :846 的 assert 形成对比。
--     ★★ 设计区别：★ 手工 ApplyWormhole 的坐标来自 C++ 统计，
--       ★★ 不可控 ⇒ 只能记错；:846 的拓扑来自自己建的图 ⇒ 可以断言。
--   ★★ 消费：:1013 `if self.error == true then return end`
--     ★★ 以及 forest_map.lua:542-547 的检查（★ 那条路径已被 if false 关掉）。
		self.error = true
		self.error_string = "ApplyWormhole nil wormhole"
	end
end

-- ★★★ SwapWormholesAndRoadsExtra：★ 用「C++ 统计出的孤岛」来配虫洞。
--   ★★★ 这是「让被切断的岛屿互通」的方案：
--     ★★ WorldSim:GetWormholesExtra() 找出所有被分离的陆地区块，
--       ★★ 然后在它们之间两两放虫洞。
--   ★★★★ ⚠ 重要：★ 当前**整个路径是关闭的** ——
--     ★★ forest_map.lua:540 `if false and not …no_wormholes_to_disconnected_tiles`
--     ★★★ 「if false」硬关。原注释（forest_map.lua:539）：
--       "turning this off for now because its conflicting with the island
--        tech and disconnected node stripping, causing wormholes in the atrium"
--     ★★★ ⇒ 「与孤岛技术冲突，会在 Atrium（回廊区域）里乱放虫洞」。
--   ★★ ⇒ 本函数与 :1052 的 SwapWormholesAndRoads **都是死代码**。
function Graph:SwapWormholesAndRoadsExtra(entities, width, height)
    if self.wormholeprefab == nil or self.wormholeprefab == "" then
		print ("[Graph:SwapWormholesAndRoadsExtra] No wormhole_prefab defined in location data. Islands will be left disconnected.")
		return
	end

	if entities[self.wormholeprefab] == nil then
		entities[self.wormholeprefab] = {}
	end
	--self:SwapWormholesAndRoads(entities, width, height)

-- ★★ WorldSim:GetWormholesExtra() ——★ C++ 侧的孤岛配对统计。
    local wx1,wy1,wx2,wy2 = WorldSim:GetWormholesExtra()
-- ★★ 四重长度一致性检查（C++ 返回的四条数组必须等长）。
--   ★★ 严谨：★ 防止 C++ 侧返回不完整数据导致 Lua 侧越界。
    if wx1 ~= nil and wy1 ~= nil and wx2 ~= nil and wy2 ~= nil and
    	#wx1 ~= 0 and #wx1 == #wy1 and #wx1 == #wx2 and #wx1 == #wy2  then

    	for i=1,#wx1 do
    		self:ApplyWormhole(entities, width, height, wx1[i], wy1[i], wx2[i], wy2[i])
    		if self.error == true then
    			return
    		end
    	end
 	else
		if wx1 ~= nil and #wx1 ~= 0 then
			self.error = true
			self.error_string = "GetWormholesExtra failed"
		end
   	end

end

-- ══════════════ ★★ ApplyPoisonTag：★ 标签 → C++ 位标志 ══════════════
-- ★★★ 这是**标签真正生效**的地方（★ 对照 :448 的被注释掉的版本）。
--   ★★ 三个标签 → 三种行为：
--     · ForceDisconnected → ★ ClearNodeLinks（断掉该节点的全部连线）
--     · ForceConnected     → flags |= 0x000002
--     · RoadPoison         → flags |= 0x000004
--   ★★★ **「毒」的含义：★ 「毒化这条边，让它不被连通性修复利用」**。
--     ★★ RoadPoison 节点连出去的边 ⇒ 道路不会画上去、
--       ★★★ 连通性修复（forest_map.lua:536）也不视它为通路。
--     ★★★ ⇒ LOOP_BLANK_SUB（storygen.lua:1163）与 blocker_blank（:993）
--       ★★★ 都带 RoadPoison ⇒ ★★ 「环路空地」既断链又禁路。
--   ★★ 调用点：forest_map.lua:526，在 WorldGen_Commit 之后、
--     ★★ ConvertToTileMap 之前。★ 时机正确（此时边已生成）。
function Graph:ApplyPoisonTag()
	local nodes = self:GetNodes(true)
	for k,node in pairs(nodes) do
-- ★ TODO: Need to handle BG nodes ——★ 已知未完成项。
--   ★★★ 这是一个**承认的技术债**：★ 背景节点（BG）的标签没处理。
--     ★★ 后果：★ 带 RoadPoison/ForceDisconnected 的**背景节点**不会被毒化。
--       ★★ 也就是说 ★ 「洞居房（cove）」与「背景节点」上的标签可能无效。
--     ★★★ ⚠ 这类「作者自己标了 TODO 的缺陷」是最可信的缺陷证据。
		-- TODO: Need to handle BG nodes
-- ★★ if IsNodeTagged(node, "ForceDisconnected") ——★ 断链标签。
--   ★★★ 原始注释里有一个被注释掉的替代条件：
--     `--or string.find(node.id, "LOOP_BLANK_SUB")~=nil then`
--   ★★★ ⇒ ★ 说明作者一度用「ID 前缀」来识别要断链的节点，
--     ★★★ 后改成了「标签」方案。★ 迁移到标签系统的痕迹。
--   ★★★ 但注意 LOOP_BLANK_SUB 同时带 RoadPoison（storygen.lua:1163），
--     ★★ 而 :1040 的 RoadPoison 只是禁路、不断链 ⇒
--       ★★ 若只靠 RoadPoison，环路空地仍会被连通。★ 所以两个标签缺一不可。
		if IsNodeTagged(node, "ForceDisconnected") then --or string.find(node.id, "LOOP_BLANK_SUB")~=nil then
-- ★★ WorldSim:ClearNodeLinks(node.id) ——★ 断掉该节点的所有链接。
--   ★★★ 这是「锁」在像素层的**唯一实际动作**。
--     ★★★ 回顾开头：lock.key 从不被读；
--       ★★★ 真正让区域不通的是这里的 ClearNodeLinks + impassable 地块。
			WorldSim:ClearNodeLinks(node.id)

			-- TODO: Move this to a more generic location
-- ★ --WorldSim:SetNodeType(node.id, 1) -- BLANK ——★ 被注释的替代方案。
--   ★★ 又一处「方案 A 换成方案 B」的痕迹（节点类型 vs 标签）。
			--WorldSim:SetNodeType(node.id, 1) -- BLANK
		end
-- ★★ local flags = 0 ——★★ 逐节点从 0 重算（★ 不是累加旧值）。
--   ★★★ 这与 ApplyPoisonTag 是递归调用（:1048）配合的关键：
--     ★★ 每个节点独立算自己的 flag，★ 不会互相污染。
		local flags = 0
-- ★★ if IsNodeTagged(node, "ForceConnected") then flags = flags + 0x000002
--   ★★★ 「强制连通」= ★ 连通性修复时**必须**把这个节点接上。
--     ★★★ ⇒ 这是「反向锁」：★ 强制让某片区域可达。
--       ★★★ 对比 storygen.lua:899-911 的 SeperateStoryByBlanks：
--         ★★ 那边**故意**造一个不可达的空节点（造「环路孤岛」），
--         ★★ 这边是**强制**让某区域可达。★ 两个方向都有机制。
		if IsNodeTagged(node, "ForceConnected") then
			flags = flags + 0x000002
		end
-- ★★ if IsNodeTagged(node, "RoadPoison") then flags = flags + 0x000004
--   ★★★ 「毒路」= ★ 道路不会画到这些节点连接的地方。
--   ★★★ 这是「无路」的物理实现，与 :1031 的 ClearNodeLinks 配合：
--     ★★ 断链 ⇒ 没有通路；毒路 ⇒ 连空地也不长路。
		if IsNodeTagged(node, "RoadPoison") then
			flags = flags + 0x000004
		end
-- ★★ WorldSim:SetSiteFlags(node.id, flags) ——★ 把位标志交给 C++。
--   ★★★ ★★ 注意：★ SetSiteFlags 也会**清除**之前设的标志
--     ★★★（因为是整体赋值）。
--     ★★★ 而 :448 那段被注释掉的代码原本会在建站时就调 SetSiteFlags，
--       ★★★ 若两者同时生效，★ :448 的标志会被 :1043 覆盖。
--       ★★★ 这解释了为什么 :448-450 被注释掉了。★
		WorldSim:SetSiteFlags(node.id, flags)
	end
-- ★ Process the graph and unlink any poisoned nodes ——★ 原始注释。
-- ★★ 注意「unlink」的实现在 :1031（循环内），而这段注释在循环**之后**。
--   ★★ ⇒ 注释位置与实际行为不符（★ 小瑕疵，无功能影响）。
	-- Process the graph and unlink any poisoned nodes
-- ★★ 递归处理所有子图 ——★★ 逐节点设置标签。
--   ★★★ 注意 :1048 用 child:ApplyPoisonTag()（有 self），
--     ★★ 而 :682 的 ApplyPoisonTag 是唯一处理 tags 的 Graph 方法。
--     ★★★ ⇒ 「标签 → 位标志」的全图遍历在此完成。
	local children = self:GetChildren()
	for k,child in pairs(children) do
		child:ApplyPoisonTag()
	end
-- ★═══ ApplyPoisonTag 结束 ════
end

-- ══════════════ SwapWormholesAndRoads ══════════════
-- ★★★★ ⚠★★ 死代码：★ 当前**无调用点**
--   （★ forest_map.lua:540 用 `if false and …` 把它连同 :541 一起关掉了）。
--   ★★ 与 :996 的 SwapWormholesAndRoadsExtra 一对，★ 都被同一个开关关闭。
-- ★★★ 若启用，它会遍历**所有 exit 边**（:1061）给每一对区域放虫洞。
--   ★★ 这是「最激进的连通性方案」：★ 每个区域连接处都放虫洞。
--   ★★★ 但 :1062-1063 排除了 LOOP_BLANK_SUB 与 START ——
--     ★★★ 说明作者意识到「环路空地不该放虫洞」。
function Graph:SwapWormholesAndRoads(entities, width, height)
    assert(self.wormholeprefab ~= nil, "Level must specify a wormhole prefab.")

	if entities[self.wormholeprefab] == nil then
		entities[self.wormholeprefab] = {}
	end

	--print(self.id.."\tSwapWormholesAndRoads", #entities[self.wormholeprefab], self.MIN_WORMHOLE_ID)

	for k,edge in pairs(self.exit_edges) do
-- ★★ if edge.node1.id ~= "LOOP_BLANK_SUB" and edge.node2.id ~= "LOOP_BLANK_SUB"
--   ★★★ ★★ 排除条件只判 node1/node2 两端，
--     ★★★ **不判中间那个 task_graph** ⇒ 若一个 exit 边是
--       ★★★ 「A -> LOOP_BLANK -> B」，B 端不会被排除。
--     ★★★ ⚠ 疑似缺陷（轻微）：★ 排除不完整。
--   ★★★ 而「START」排除同理：★ 避免在出生点放虫洞。
		if edge.node1.id ~= "LOOP_BLANK_SUB" and edge.node2.id ~= "LOOP_BLANK_SUB"
			and edge.node1.id ~= "START" and edge.node2.id ~= "START" then

			--print(self.id.."\t\t", edge.id, edge.node1.id, edge.node2.id)
			-- Get x1,y1,x2,y2 for this edge
-- ★★ WorldSim:GetWormholes(edge.node1.id, edge.node2.id) ——★ 取配对坐标。
			local x1,y1,x2,y2 = WorldSim:GetWormholes(edge.node1.id, edge.node2.id)
	    	self:ApplyWormhole(entities, width, height, x1,y1,x2,y2)
	    end
	end

	--print(self.id.."\tSwapWormholesAndRoads complete", #entities[self.wormholeprefab])

-- ★★ 递归处理子图 ——★★ 与 :1046 同构。
	local children = self:GetChildren()
	for k,child in pairs(children) do
		child:SwapWormholesAndRoads(entities, width, height)
	end
-- ★★★ 全文件结束（1079 行含末尾空行）。
-- ★★ 最后一次总账（重申开头）：
--   · ★★★★★ **本文件是地图生成图，与联机网络无关**；
--   · ★★★ 它导出 Graph（容器），与 Node（graphnode.lua）、
--       ★★★ Edge（graphedge.lua）构成一套三角；
--   · ★★★ 它最重要的两个调用是 WorldSim:AddLink(:344) 与
--       ★★★ AddExternalLink(:274) —— ★「图上邻接 = 地图邻接」的实现；
--   · ★★★ 它最重要的认知是 lock.key 从不被读 ⇒ 「锁」= 边是否存在；
--   · ★★ 真实缺陷清单（本文件内）：
--       ⚠ :385 缺 local ⇒ 全局 edge 泄漏 ⇒ 误判找到错边（真实）
--       ⚠ :759-786 GetRequiredPrefabs 的 O(N²) deepcopy（真实）
--       ⚠ :247/:287/:397/:658 四个 Remove* 全用 table.remove 删字典（真实）
--       ⚠ :658 RemoveNode 会「删一半」—— graph 指针已清空但项还在
--       ⚠ :739 PopulateChildren 少传 1 个参数 ⇒ prefabDensities 为 nil
--       ⚠ :151/:172 exit_nodes 与 nodes 无查重 ⇒ 节点可能被编码两次
--       ⚠ :159/:180 O(N×E) 的边重映射（性能）
--       ⚠ :938/:966 遍历中删键（未定义行为）
--       ⚠ :37/:673 visited 与 old_pos 是从未被读的化石字段
--       ⚠ :109 edge_ids 是从未被读的死变量
--       ⚠ :293 IsConnectedTo 语义与名字不符（只查图内边）
--       ⚠ :279 GetExitEdges(false) 的参数未实现
--       ⚠ :433 entrancenode 单槽位 ⇒ 多 entrance 时后者覆盖前者
--       ⚠ :688/:716/:724 Populate + GetArea + spawnfordefault 三处断链死代码
--       ⚠ :996/:1052 两个 SwapWormholes* 被 if false 关闭
--       ⚠ :921/:933 奇数个 marker 时最后一个静默丢失
--       ⚠ :1029 作者自标 TODO：背景节点的标签未处理
end
