--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/forest_map.lua（1072 行）
-- 模块：世界生成 / 与 C++ WorldSim 的对接层（WorldSim Bridge）
-- 职责：★ 本文件才是世界生成的真正入口。
--       把「关卡预设 overrides」翻译成引擎参数 → 调 storygen 建剧情图
--       → 驱动 C++ WorldSim 做 Voronoi/Lloyd/烘焙/连通性修复
--       → 逐节点散落地块与实体 → 5 道校验 → 编码成 savedata blob。
--
-- ★★★ 0. 本文件 = 唯一"看得见耗时"的层
--   全文件散布着 print（"[Story Gen]"、"Baking map..."、"Encoding..."…），
--   这些是玩家在生成界面看到的进度文案来源，也是性能排查的第一手依据。
--   生成耗时预算（对齐 debug 资料 §1.6）：
--     ├ 参数翻译 + 任务解析 + 建图   < 50 ms   （:392-495）
--     ├ ★ Voronoi + Lloyd ×100        2–8 s    （:499）—— 唯一的大头
--     ├ 逐区域 AddNewPositions + ×50  0.3–1 s/区域（:503）
--     ├ WorldGen_Commit 烘焙          0.5–2 s  （:522）O(W×H)
--     ├ ForceConnectivity 连通性修复   0.3–1 s  （:536）
--     ├ DrawRoads                     0.2–0.5 s（:557）
--     ├ PopulateVoronoi 散布          1–3 s    （:873）
--     ├ 海洋生成（仅 has_ocean）      1–4 s    （:874-888）
--     ├ 校验                         < 100 ms  （:596/:599/:857/:961）
--     └ GetEncodedMap 序列化         0.3–1 s   （:978）
--   ⚠ 上述除 Lloyd 外**没有一行计时器**。想量化就必须自己加
--     GetTimeReal() 埋点（BuildStory :1396 已经示范了正确写法）。
--   ★★ 最坏情况：单次 10 s × worldgen_main.lua:419 的 maxtries = 5
--      = 50 s 才给玩家一句"An error occured during world and we give up!"。
--
-- ★★★ 1. ★★ 六阶段流程图（真实执行顺序，逐行核实）
--
--   ┌── S0 参数翻译 ────────────────────────────────────────────────┐
--   │ :382-384  WorldSim:SetPointsBarrenOrReservedTile(ROAD)       │
--   │           WorldSim:SetResolveNoiseFunction(GetTileForNoise)   │
--   │           WorldSim:SetValidateGroundTileFunction(Validate)    │
--   │ :392      assert(level.overrides ~= nil)                     │
--   │ :402-460  start_location / islands / branching / loop /       │
--   │           layout_mode / has_ocean / wormhole_prefab …         │
--   │ :455-460  ApplySpecialEvent + SPECIAL_EVENTS 逐个             │
--   │ :462-491  world_size → 地图边长（350~450）→ SetWorldSize     │
--   └───────────────────────────────────────────────────────────────┘
--                              ↓
--   ┌── S1 建剧情图（委托 storygen）────────────────────────────────┐
--   │ :494-495  require("map/storygen"); BuildStory(...)           │
--   │           ★ 内部：GeneratePipeline → 任务节点 → 锁钥匙连线   │
--   └───────────────────────────────────────────────────────────────┘
--                              ↓
--   ┌── S2 空间化（★ 唯一的大头，全在 C++）────────────────────────┐
--   │ :497  WorldSim:WorldGen_InitializeNodePoints()               │
--   │ :499  ★ WorldSim:WorldGen_VoronoiPass(100)   ← Lloyd 松弛    │
--   │ :501-506 on_region_added_fn = AddNewPositions + VoronoiPass(50)│
--   │         storygen:AddRegionsToMainland(on_region_added_fn)     │
--   └───────────────────────────────────────────────────────────────┘
--                              ↓
--   ┌── S3 烘焙 + 连通性 ───────────────────────────────────────────┐
--   │ :522  WorldGen_Commit()            失败 → return nil（重试） │
--   │ :526  topology_save.root:ApplyPoisonTag()                    │
--   │ :527  WorldSim:ConvertToTileMap(min_size)                    │
--   │ :529  WorldSim:SeparateIslands()                             │
--   │ :536  ★ WorldSim:ForceConnectivity(join_islands, false, ROCKY)│
--   │        ★ 注释明说"This also generates land tiles"            │
--   │          —— 这是"保证玩家能从出生点走到所有必需区域"的最终保证 │
--   │ :550-557 DrawRoads（roads ~= "never" 且非洞穴）              │
--   └───────────────────────────────────────────────────────────────┘
--                              ↓
--   ┌── S4 特殊标签后处理（Labyrinth / Maze）──────────────────────┐
--   │ :561-575 逐 node:SetTilesViaFunction + MakeSafeFromDisconnect│
--   │ :587-588  SaveEncode + CreateNodeIdTileMap                    │
--   │ :645-693  Tag: Labyrinth → WorldSim:RunMaze + pandoraschest  │
--   │ :695-838  Tag: Maze      → GetPointsForMetaMaze + obj_layout │
--   └───────────────────────────────────────────────────────────────┘
--                              ↓
--   ┌── S5 散布 ───────────────────────────────────────────────────┐
--   │ :842  GlobalPrePopulate（疯狂虫洞 oneshot）                   │
--   │ :843  ConvertGround（静态场景件 countstaticlayouts）          │
--   │ :844  ReplaceSingleNonLandTiles                               │
--   │ :853-868 DetectDisconnect（断连检测，>5% 则判失败）           │
--   │ :873  ★ PopulateVoronoi（countprefabs + distributeprefabs）   │
--   │ :874-888 has_ocean：Ocean_PlaceSetPieces / PopulateOcean /   │
--   │         MonkeyIsland_GenerateDocks                           │
--   │ :889  GlobalPostPopulate（wormhole 配对 + prefab 改名解析）   │
--   │ :891-902 移除压在不可通行格上的实体                            │
--   │ :904-919 按 translated_prefabs 下调密度（mult<1 时）         │
--   │ :921-924 BunchSpawner（草丛簇）+ AncientArchivePass          │
--   └───────────────────────────────────────────────────────────────┘
--                              ↓
--   ┌── S6 五道校验 + 编码 ────────────────────────────────────────┐
--   │ :596-606 校验①每个 site 面积 ≥ 8 格（LOOP_BLANK_SUB 豁免）    │
--   │ :857      校验②断连格 ≤ 5%                                   │
--   │ :961-974 校验③required_prefabs 三重来源求和                   │
--   │ :1007     校验④至少存在一个出生点                             │
--   │ （校验⑤ = :522 WorldGen_Commit 自身的返回值）                 │
--   │ :978-1056 GetEncodedMap / 季节 / 道路点序列 → return save     │
--   └───────────────────────────────────────────────────────────────┘
--
-- ★★ 2. ★★ 随机数与可复现性
--   · 本文件同样**从不调用** math.randomseed（★ grep 核实零命中）。
--     种子在 C++ 侧设定。
--   · 本文件消耗随机的点：:407-411 start_setpeice/start_node 各一次、
--     :649 迷宫尺寸、:722/:727/:732 迷宫房间选择、:990 起始季节。
--     ★ 数量不多但**位置敏感** —— :407/:408 连着两次 math.random(#table)，
--     一旦 start_loc 表的长度变了，其后所有随机会整体错位。
--   · ★★ **本文件是"静默失败点"最密集的地方**，而这些点都只 print：
--       :522 WorldGen_Commit 失败 → return nil（会重试，OK）
--       :599 area < 8       → return nil（会重试，OK）
--       :857 断连 > 5%      → return nil（会重试，OK）
--       :968 缺 required prefab → return nil（会重试，OK）
--       :1011 无出生点       → return nil（会重试，OK）
--       ★ 上面 5 处返回 nil 让 worldgen_main.lua:419 的 maxtries=5 生效。
--       ★ 但 SKIP_GEN_CHECKS（:3）为 false 时才 return nil；
--       改成 true 就变成"带病出图"（仅用于调试）。
--       ⚠ E2 缺陷（bug-patterns.md）：这些 print 不进统计表，
--         开发者复现不了"玩家说缺东西"的投诉。
--
-- ★ 3. 生物群系（biome）在 DST 不是一个数据结构
--   ★ grep 核实：`biome` 这个词在 map/ 下只出现在 3 处，且都是别的意思
--     （waterlog_worldgen.lua:11 的 BIOME_SPAWN_NUM 常量、
--      caves_retrofit_land.lua:200 的 print 文案、
--      graphnode.lua:536 的注释 "For use in biomes with mixed tile types"）。
--     **DST 没有 Biome 类、没有 biome 表、没有 biomeid。**
--   ⇒ 真实的"群系"是这样表达的（三层）：
--     ① **图节点层**：一个 Node 就是一个群系。它的 data.value 是
--        该 Voronoi 胞元压下去的地面地块 ID（WORLD_TILES.GRASS 等）。
--        多个同类房间合成一个 task ⇒ 一个 task 就是一个"大群系"。
--     ② **房间层**：map/rooms/*.lua 里每个房间模板的 contents
--        （distributeprefabs / countprefabs / distributepercent）
--        决定这个群系里长什么、密度多少。★ 这才是"群系内容"的真正来源。
--     ③ **地块过滤层**：map/terrain.lua 的 TERRAIN_FILTER
--        （prefab → 禁止出现的地块列表）。它在 pickspawnprefab(:16)、
--        pickspawncountprefabforground(:62) 里做否决，
--        ★ 所以"生物群系约束"实际上是**地块约束**。
--     ④ **边界柔化**：*_NOISE 过渡地块（DIRT_NOISE=123 / CAVE_NOISE=126 …）+
--        :364 GetTileForNoiseTile 查 noisetilefunctions 决定交界处取哪一侧。
--        ★ DST 不用后处理柔化边界，靠过渡地块。
--     ⑤ **perTerrain**（graphnode.lua:536）：data.background 是一个
--        {地块→房间名} 表时，背景内容按点所在的地块类型选房间 —— 这是洞穴
--        多地块混合群系的唯一支持机制，由 network.lua:735 判定。
--
-- ★ 4. 交叉引用
--   BuildStory / GenerationPipeline ........... map/storygen.lua:1394 / 86
--   VoronoiPass 的 Lloyd 实现 ................ C++（不在 Lua 库内）
--   spawnFN 三函数 ........................... :16 / :54 / :62（本文件）
--   terrain.filter ........................... map/terrain.lua:14
--   object_layout.Place / ReserveAndPlaceLayout  map/object_layout.lua
--   BunchSpawnerInit / Run .................... map/bunch_spawner.lua
--   AncientArchivePass ........................ map/archive_worldgen.lua
--   MonkeyIsland_GenerateDocks ............... map/monkeyisland_worldgen.lua
--   Ocean_SetWorldForOceanGen / PopulateOcean map/ocean_gen.lua
--   ★ 重试循环 maxtries = 5 .................. worldgen_main.lua:419
--   所需 prefab 改名映射 ...................... prefabswaps.lua
--============================================================
--
--【阅读导航】
--  §零   依赖 / 死代码 trees / 三个 spawn 选择器      (1-84)
--  §一 ★ 密度倍数表 MULTIPLY / CLUMP / CLUMPSIZE      (86-166)
--  §二 ★ TRANSLATE_TO_PREFABS（★ 最大的世界生成设置表）(168-265)
--  §三   TranslateWorldGenChoices（三类改写：翻译/覆盖/兼有）(267-360)
--  §四   季节表 seasonfn / SEASONS                    (320-348)
--  §五 ★ 噪声地块与地面校验                            (362-379)
--  §六 ★★ Generate：S0 参数翻译（S0 全部）             (381-491)
--  §七 ★★ Generate：S1-S3 建图→空间化→烘焙→连通性     (493-558)
--  §八   S4 逐节点自定义地块 + 编码 + 面积校验         (560-606)
--  §九 ★★ S4 特殊标签：Labyrinth（迷宫）与 Maze（竞技场）(608-838)
--  §十 ★★ S5 散布与断连检测                            (840-889)
--  §十一 后处理：清理不可通行上的实体 / 密度下调        (891-924)
--  §十二 ★★ S6 校验三重来源求和                        (926-974)
--  §十三 编码 / 季节 / 出生点校验 / 道路序列化         (976-1057)
--  §十四 模块导出表                                    (1059-1072)
--
--【★★ 全文件最重要的十条】
--  1. ★★ Generate(:381) 是世界生成的真正入口；storygen.lua 只是它的子流程。
--  2. ★★ 五道校验全部以 `return nil` 表达失败，由 worldgen_main.lua:419
--     的 maxtries=5 重试。⚠ 每一次重试都会 collectgarbage + WorldSim:ResetAll()
--     并**重新消耗随机数** ⇒ 5 次尝试得到的 5 张图彼此不同。
--  3. ★★ VoronoiPass(100)（:499）是全流程唯一的数量级开销。
--     ★ grep 核实：Lua 库里**没有一行 Lloyd 实现**（`grep -rn Lloyd` 零命中），
--     松弛完全在 C++ WorldSim 内。移植时必须自己实现，
--     复杂度 O(P×S)，用网格空间哈希可降到近 O(P+S)。
--  4. ★ WorldGen_VoronoiPass 的**参数是迭代次数**，不是采样数（:499 传 100）。
--     加区域时降到 50（:503）—— 因为老点已经收敛，只微调新点。
--  5. ★★ ForceConnectivity(:536) 是连通性的**最终保证**，注释明说
--     "This also generates land tiles"。★ 但注释里的 `prefab == "cave"`
--     被注释掉了 ⇒ 洞穴地图也走同一套连通性修复。
--  6. ★ :846-852 的长注释解释了本文件最容易误解的一段：
--     **ForceDisconnected 标签并不真的让东西悬空**，
--     它靠 FAKE_GROUND（假地面）在生成期先连上，之后再清理。
--     ⇒ 想做"真正的浮空岛"，必须用 SafeFromDisconnect 标记排除格子。
--  7. ★ 面积校验阈值是 **8 格**（:599），极宽松。详见注释里的自嘲：
--     "TODO: Double check that each of the rooms has enough space"。
--  8. ★ 校验③（:926-959）是三重来源求和：
--       level.required_prefabs + root:GetRequiredPrefabs()（递归合并
--       图级/节点级）+ ocean_population 房间的 required_prefabs。
--       ★ 三者都要减去 translated_prefabs==0 的项（玩家主动禁用的）。
--  9. ★ §二 TRANSLATE_TO_PREFABS 是"世界生成设置 UI"到"真实 prefab"的
--     翻译字典，200 多行。它的存在意味着 UI 上的一个选项经常对应
--     **多个 prefab**，且同名概念在月岛/海洋下要写 moon_/ocean_ 两套。
--  10.★ ⚠ :572 `print(self.id.." Cant process points")` —— Generate 是
--     local function，**没有 self 参数** ⇒ 一旦 #points_x==0 走到这里
--     必然 runtime error（attempt to index a nil value）。
--     推理依据：同函数内 :562 用的是 `for k,node in pairs(nodes)` 里的 node，
--     而 :572 写的是 self.id。⚠ 疑似缺陷（低概率触发，但一旦触发即崩）。
--============================================================
-- ★★★★★ 本文件是【整个世界生成流程的 Lua 侧总入口】。
--
-- 【★ 纠正一个常见误解】
--   任务描述中提到的 PlaceSpecialPoint → Voronoi/Triangulation → PlaceItems
--   → PlaceTasks → PlaceCharacters → PostProcess 这条链，
--   在本仓库中【零命中】（grep 核实 map/ 与整个 scripts/ 目录均无这些函数名）。
--   真实入口是本文件的 :381 Generate()，真实顺序见 :381 处的大段注释。
--
-- 【本文件负责什么】
--   只做「翻译」与「编排」，真正的几何计算在 C++ WorldSim 里：
--     · Lua：决定【有哪些地块、地块之间怎么连、每块地放什么】
--     · C++ ：决定【这些地块在平面上怎么排、怎么切、怎么铺路面】
--   ★ 所以本文件里 90% 的行是参数搬运与校验，看不到任何 Voronoi 算法实现。
--
-- 【★ Lloyd 松弛在哪里】—— 不在 Lua 里。
--   grep -rn Lloyd 在整个 scripts/ 目录零结果。
--   松弛由 WorldSim:WorldGen_VoronoiPass(n) 在 C++ 侧完成，
--   本文件只在 :499（迭代 100 次）与 :503（迭代 50 次）两次调用它。
--   ⇒ 性能预算分析必须围绕这两行展开，参见下面 :499 的注释。
--
-- 【★ 关于 map/network.lua 的提醒】
--   同目录下的 network.lua 是【地图生成图】（Graph/GraphNode/GraphEdge），
--   与联机网络同步毫无关系。文件名是历史误称，参见该文件头的警示。
local startlocations = require"map/startlocations"

local SKIP_GEN_CHECKS = false

-- 三种常绿树（短/中/高）的候选表。
-- ⚠ 实际上从未被用到：下面的 tree() 已经被硬编码为只返回 "evergreen"，
--   trees[...] 的随机选择被注释掉了（:7）。
--   ⇒ 这是一个「故意关掉随机」的历史残留表。
--   保持不改：若恢复随机，同一个种子会得到完全不同的地图。
local trees = {"evergreen_short", "evergreen_normal", "evergreen_tall"}
local function tree()
    return "evergreen"--trees[math.random(#trees)]
end

require "map/terrain"
require "map/ocean_gen"
require "map/bunch_spawner"
require "map/archive_worldgen"
require "map/monkeyisland_worldgen"

-- ============================================================
-- 三个「spawn 选择器」—— 传给 C++ WorldSim 的 Lua 回调
-- ============================================================
-- 【机制】WorldSim 在烘焙地图时需要决定「某个格子上生成什么」，
--   但生成规则在 Lua 侧。于是 Lua 把这三个函数注册给 C++（:386-390），
--   C++ 在遍历地块时反调用它们。
-- ★ 这是 Lua↔C++ 的关键接缝：Lua 提供策略，C++ 提供数据。
--   也因此这三函数的签名必须与 C++ 侧严格对齐，改动会静默失效。
local function pickspawnprefab(items_in, ground_type)
--	if ground_type == WORLD_TILES.ROAD then
--		return
--	end
-- ★ pickspawnprefab(items_in, ground_type)：按权重随机挑一个 prefab。
--   items_in 是 {prefab名 = 权重} 的表（来自房间的 contents.countprefabs）。
--   ground_type 是当前地块类型（草地/道路/沙地…），用于过滤禁生 prefab。
-- ⚠ :17-19 有一段被注释掉的「道路不生成任何东西」的旧逻辑。
--   现在的做法是在下面用 terrain.filter 过滤，而不是整体跳过。
	local items = {}
	if ground_type ~= nil then
		-- Filter the items
	    for item,v in pairs(items_in) do
	    	items[item] = items_in[item]
-- ★★ 过滤核心：terrain.filter[item] —— 这就是【生物群系约束】的真正实现。
--   terrain.filter 来自 map/terrain.lua 的 TERRAIN_FILTER 表。
--   它的语义是【黑名单】：列出的地块类型是「这个 prefab 不能长的地方」。
--   详见 terrain.lua 的详细注释（TERRAIN_FILTER 段落）。
--
-- 【★ 群系系统澄清 —— 任务要求重点讲解】
--   DST 【没有 Biome 类】。grep 核实：`biome` 一词在 map/ 下仅 3 处命中且都不是类定义。
--   真实的「群系」由三层共同表达：
--     ① 地块类型（Node.data.value，如 GRASS/SAND/ROCKY）—— 决定地表长什么样
--     ② 房间内容物（room.contents.countprefabs）—— 决定地表上长什么
--     ③ TERRAIN_FILTER 黑名单 —— 决定 ② 中哪些项在 ① 上被禁止
--   ⇒ 「群系」= ①×② 的交叉结果，而 ③ 是过滤器。
--   ★ 这三层是【正交】的：同一个 prefab（如 berrybush）可以在草地上长、在沙地上被禁。
--     这就是为什么 DST 的世界看起来「群系感」比 Minecraft 弱：
--     因为群系不是一个被整体切换的模式，而是逐 prefab 的独立判定。
	        if terrain.filter[item]~= nil then
--	        	if ground_type == WORLD_TILES.ROAD then
--	        		print ("Filter", item, terrain.filter.Print(terrain.filter[item]), GROUND_NAMES[ground_type])
--	        	end

	            for idx,gt in ipairs(terrain.filter[item]) do
        			if gt == ground_type then
        				items[item] = nil
        				--print ("Filtered", item, GROUND_NAMES[ground_type], " (".. terrain.filter.Print(terrain.filter[item])..")")
        			end
   				end
	        end
	    end
	end
-- ★ 加权随机：先求总和 total，再取 [0, total) 的随机数，线性扫描扣减。
--   这是标准的「按权重抽样」写法，避免了先展开成数组再取下标的开销。
--
-- ⚠⚠ 可复现性缺陷（重要）：:45 的 pairs 遍历依赖 hash 顺序。
--   对同一个 {a=1, b=1, c=1} 的表，线性扣减的顺序决定哪个键先被选中。
--   ⚠ 这里【恰好是安全的】—— 因为键值本身来自上游的表（同样是 pairs 构造），
--     整条链的顺序都由同一套 hash 规则决定，同种子下仍然自洽。
--   ★ 但判据要记住：「只有取第 k 个才致命，求聚合量则安全」。
--     这里是「取累积阈值的第一个」，介于两者之间 ——
--     若权重差异很大（一个 0.9 一个 0.1），实际近似按权重，与顺序无关；
--     若权重全相等（1,1,1），则退化为「取 pairs 第一个」⇒ 顺序相关。
--   实践中房间内容的权重多为小数（如 0.3、0.5），故近似安全。
-- ⚠ :43-51 若 total == 0，函数【隐式返回 nil】（没有 else 分支）。
--   调用方必须能处理 nil ⇒ C++ 侧会理解为「这块地什么都不长」。
--   这是一个有意设计的默认值，不是缺陷。
    local total = 0
    for k,v in pairs(items) do
        total = total + v
    end
    if total > 0 then
        local rnd = math.random()*total
        for k,v in pairs(items) do
            rnd = rnd - v
            if rnd <= 0 then
                return k
            end
        end
    end
end

-- ★ pickspawngroup(groups)：独立概率抽样。
--   groups 是 {名字 = {percent=概率}} 的表。
--   ⚠ 关键语义：【返回第一个命中概率的】，而不是「按权重抽样」。
--   ⚠⚠ 强顺序依赖：pairs 顺序决定了先试哪个。
--     若 A 有 50% 概率、B 有 10% 概率：
--       pairs 先遇 A ⇒ 50% 得 A、50% 得 B（若 A 未中）
--       pairs 先遇 B ⇒ 90% 得 A、10% 得 B
--   ⇒ 同一个 percent 表在不同 Lua 版本/平台上产出比例不同。
--   这是本文件里最危险的可复现性陷阱之一。
--   ⚠ 正确做法应为逐个独立掷骰（每个都掷），而非「第一个命中就返回」。
--   保持不改：改它会改变所有种子的地图。
local function pickspawngroup(groups)
    for k,v in pairs(groups) do
        if math.random() < v.percent then
            return v
        end
    end
end

-- ★ pickspawncountprefabforground(prefabs, ground_type)：纯等概率取一个。
--   与 pickspawnprefab 的区别：【不考虑权重，只做禁生过滤 + 等概率】。
--   用于「一组同类 prefab 里随便挑一个」（如几种岩石里挑一个）。
-- ⚠⚠ 最危险的一处可复现性陷阱：:81 的 items[math.random(#items)]。
--   items 是数组（table.insert 构造，顺序确定）⇒ 取下标【本身是安全的】。
--   但 items 的【元素顺序】由 :64 的 pairs 遍历 prefabs 决定 ⇒ 依然顺序相关。
--   ⇒ 链条：pairs(prefabs) 决定 items 顺序 → 顺序决定「随机下标」落到谁身上。
--   净效果：同种子下可复现（整条链统一），跨版本不保证。
-- ⚠ :83 显式返回 nil（与 pickspawnprefab 的隐式返回不同）—— 风格不统一但无害。
local function pickspawncountprefabforground(prefabs, ground_type)
	local items = {}
	for item, _ in pairs(prefabs) do
		if terrain.filter[item] == nil then
			table.insert(items, item)
		else
			local add = true
	        for idx,gt in ipairs(terrain.filter[item]) do
        		if gt == ground_type then
					add = false
					break
				end
			end
			if add then
				table.insert(items, item)
			end
		end
	end
	if #items > 0 then
		return items[math.random(#items)]
	end
	return nil
end

-- ============================================================
-- 【密度倍率表】MULTIPLY —— 世界生成选项的数值化
-- ============================================================
-- 【语义】把玩家在设置界面选的「never/rare/default/.../insane」翻译成浮点倍率。
--   这个倍率最终乘到房间内容物的 prefab 数量上。
--
-- 【★ 为什么分陆地与海洋两套】
--   同一档位在海里和在陆地的观感差异很大：
--     rare   陆地 0.5 / 海洋 0.65 —— 海洋资源少一点会显得空
--     insane 陆地 6   / 海洋 4   —— 陆地太多会糊屏
--   ⇒ 海洋的曲线更平缓。这是一条【手感调优曲线】，不是数学推导。
-- ⚠ 全部硬编码，无 TUNING 外挂项 ⇒ Mod 无法调整这些手感参数。
local MULTIPLY = {
	["never"] = 0,
	["rare"] = 0.5,
	["uncommon"] = 0.75,
	["default"] = 1,
	["often"] = 1.5,
	["mostly"] = 2.2,
	["always"] = 3,
	["insane"] = 6,

	["ocean_never"] = 0,
	["ocean_rare"] = 0.65,
	["ocean_uncommon"] = 0.85,
	["ocean_default"] = 1,
	["ocean_often"] = 1.3,
	["ocean_mostly"] = 1.65,
	["ocean_always"] = 2,
	["ocean_insane"] = 4,
}

-- 【CLUMP】成簇生成的数量档位。
--   典型用法：浆果丛不是散着长，而是「一次长 8 丛，每丛 1~2 个」。
-- ⚠ ocean_often 是 15，比陆地的 often=8 大近一倍。
--   ⇒ 海洋资源本身就是成片分布的（藻类带、鱼群），符合视觉预期。
local CLUMP = {
	["often"] = 8,
	["mostly"] = 15,
	["always"] = 30,
	["insane"] = 60,

	["ocean_often"] = 15,
	["ocean_mostly"] = 25,
	["ocean_always"] = 40,
	["ocean_insane"] = 60,
}

-- 【CLUMPSIZE】每簇的个数范围 {min, max}。
--   ⚠ 档位越高簇越大：insane 是 {5,6}，意味着单次生成会连续摇 5~6 次随机数。
--   ★ 这是「随机数消耗量随难度增长」的一个例子，会影响后续所有随机结果。
--     对本文件而言：换难度档 ⇒ 后续地图细节整体变化（不是 bug，是耦合）。
local CLUMPSIZE = {
	["often"] = {1, 2},
	["mostly"] = {2, 3},
	["always"] = {3, 4},
	["insane"] = {5, 6},

	["ocean_often"] = {1, 2},
	["ocean_mostly"] = {2, 3},
	["ocean_always"] = {3, 4},
	["ocean_insane"] = {5, 6},
}

-- ============================================================
-- ★【Spawner 密度修正】—— 本文件最巧妙的设计之一
-- ============================================================
-- 【问题】spawner 类 prefab（草垛、天鹅spawner 等）自身会【生成一堆东西】。
--   若按普通倍率给 density=3（insane），一个 spawner 就会变成资源洪水。
-- 【解法】把它们单独映射：先除以 SPAWNER_MUL(=1.2) 再夹到 <= 1。
--   效果：spawner 的上限被强制压到 1，「always」也只给 0.83。
--   ⇒ 【资源点可以很少，但它产出的资源总量不变】——这正是设计意图。
-- ★ 这个「稀疏但高产」的设计是 DST 资源分布的核心手感。
local SPAWNER_MUL = 1.2
local OCEAN_SPAWNER_MUL = 1.2
-- prefab_spawner_multiply：mult>1 时除以 1.2 并夹到 <=1；mult<1 时乘 1.2 并夹到 >=1。
-- ⚠ 注意 mult<1 的分支是【放大】（mult*1.2）——
--   即「rare」档位的 spawner 密度反而比原值高。
--   ★ 意图：spawner 太少了玩家就看不到资源，所以下限被抬高。
--   ⚠ 参数 density 在函数体内【完全未被使用】（两个函数都是）。
--     推测是早期版本按 density 缩放的遗留签名。保持不改。
local function prefab_spawner_multiply(density, mult)
	if mult > 1 then
		return math.max(mult / SPAWNER_MUL, 1)
	elseif mult < 1 then
		return math.min(mult * SPAWNER_MUL, 1)
	end
	return mult
end
-- prefab_spawner_ocean_multiply：与 :132 逻辑相同，只是用 OCEAN_SPAWNER_MUL。
-- ⚠ 但 OCEAN_SPAWNER_MUL 也是 1.2（:131），与 SPAWNER_MUL 完全相同。
--   ⇒ 两个函数目前行为【完全等价】，差异只是为将来调参预留的接口。
--   疑似缺陷：OCEAN_SPAWNER_MUL 被定义为常量却与普通常量同值，
--     属于「预留参数位」而非「有意区分」。
local function prefab_spawner_ocean_multiply(density, mult)
	if mult > 1 then
		return math.max(mult / OCEAN_SPAWNER_MUL, 1)
	elseif mult < 1 then
		return math.min(mult * OCEAN_SPAWNER_MUL, 1)
	end
	return mult
end

--spawners get a lower density, since spawners spawn multiple things.
-- ============================================================
-- MULTIPLY_PREFABS：哪些 prefab 走 spawner 修正逻辑
-- ============================================================
-- ★ 表的值不是数字而是【函数】—— 这是本文件最巧妙的一处设计。
--   常规 prefab 的值是 MULTIPLY[tweak]（数字），
--   spawner 的值是 prefab_spawner_multiply（函数）。
--   ⇒ 调用方 :280-281 用 `if MULTIPLY_PREFABS[prefab] then ... (v, mult) end`
--     统一处理两种类型，无需分支判断。
--   ⚠ 代价：语义被藏在一个表里，看表本身无法知道某个 prefab 是否被修正。
local MULTIPLY_PREFABS = {
	["tumbleweedspawner"] = 		prefab_spawner_multiply,
	["buzzardspawner"] = 			prefab_spawner_multiply,
    ["slurper_spawner"] =           prefab_spawner_multiply,
    ["worm_spawner"] =             	prefab_spawner_multiply,
	["monkeybarrel_spawner"] =      prefab_spawner_multiply,

-- wobster_den_spawner_shore：虽然是海洋 prefab，但生成条件要求像陆地一样处理。
--   ★ 注释自承这一点，说明这是【内容驱动的特例】而非分类错误。
-- oceanfish_shoalspawner：用陆地倍率。
--   注释说「作为陆地设置倍率感觉更合适」⇒ 纯手感调优，无数学依据。
-- seastack/waterplant/boat_otterden：走海洋 spawner 修正。
-- ⚠ 表里只有 11 项，而 TRANSLATE_TO_PREFABS 有 100+ 项。
--   ⇒ 【绝大多数 prefab 不做 spawner 修正】。
--   ⚠ 这个表明显不完整（例如 mermhouse 会刷海妖、catcoonden 会刷猫）。
--   可能是有意的（避免过度削弱），也可能是遗漏。记录为观察项。
	--while it is an ocean setting, its spawning requirements mean it needs to get treated like a land setting.
	["wobster_den_spawner_shore"] =	prefab_spawner_multiply,
	--feels more impactful as a land setting multiplier.
	["oceanfish_shoalspawner"] =	prefab_spawner_multiply,

	["seastack_spawner_rough"] =	prefab_spawner_ocean_multiply,
	["seastack_spawner_swell"] =	prefab_spawner_ocean_multiply,
	["waterplant_spawner_rough"] =	prefab_spawner_ocean_multiply,
	["boat_otterden"] = 			prefab_spawner_ocean_multiply,
}

-- ============================================================
-- ★★ TRANSLATE_TO_PREFABS：【世界设置项 → prefab 名】的翻译总表
-- ============================================================
-- 【★ 这就是「群系/世界设置」在数据层的真正形态】
--   玩家在设置界面看到的每一个条目（蜘蛛、帐篷、浆果丛…）都有一个抽象名，
--   这个表把抽象名映射到具体的游戏 prefab 名（可多个）。
--   例：["pigs"] = {"pighouse"} —— 猪屋在代码里叫 pighouse
--   例：["berries"] 类的 ["berrybush"] = 3 个变体 ⇒ 随机取一种
--
-- 【★ 三段式前缀约定】—— 这张表的组织方式值得单独理解：
--   无前缀      ：通用条目，两栖（水陆都能长）
--   moon_ 前缀   ：月岛（Moon Island）专用，见 :224-235
--   ocean_ 前缀  ：海洋专用，见 :237-243
--   ⇒ 【生物群系在这个层面就是「带前缀的子表」】。
--   加一个新群系 = 加一批带新前缀的行，不需要任何代码改动。
--   这是一个非常高效的扩展设计，Mod 也靠它注入新群系。
--
-- 【规模】约 100 项，覆盖陆地/洞穴/海洋/月岛/特殊活动五大类。
-- ⚠ 这张表同时被导出（:1061），供 Mod 与其他模块使用 —— 它是公开契约。
--   改动会破坏 Mod 兼容性。
-- ⚠ 「1 个抽象名 → N 个 prefab」的展开由 :288 的循环完成，
--   所有变体共用【同一个倍率】⇒ 无法单独调节某个变体的密度。
local TRANSLATE_TO_PREFABS = {
	["spiders"] = 			{"spiderden"},
	["cave_spiders"] = 		{"dropperweb", "spiderhole"},
	["tentacles"] = 		{"tentacle"},
	["tallbirds"] = 		{"tallbirdnest"},
	["pigs"] = 				{"pighouse"},
	["rabbits"] = 			{"rabbithole"},
	["moles"] =				{"molehill"},
	["beefalo"] = 			{"beefalo"},
	["ponds"] = 			{"pond", "pond_mos"},
	["cave_ponds"] = 		{"pond", "pond_cave"},
	["bees"] = 				{"beehive", "bee"},
	["grass"] = 			{"grass","grassgekko"},
	["rock"] = 				{"rocks", "rock1", "rock2", "rock_flintless","rock_petrified_tree"},
	["sapling"] = 			{"sapling","twiggytree","ground_twigs"},
	["reeds"] = 			{"reeds"},
	["trees"] = 			{"evergreen", "evergreen_sparse", "deciduoustree", "marsh_tree"},
	["evergreen"] = 		{"evergreen"},
	["carrot"] = 			{"carrot_planted"},
	["berrybush"] = 		{"berrybush", "berrybush2", "berrybush_juicy"},
	["maxwelllight"] = 		{"maxwelllight"},
	["maxwelllight_area"] = {"maxwelllight_area"},
	["fireflies"] = 		{"fireflies"},
	["cave_entrance"] = 	{"cave_entrance"},
	["tumbleweed"] = 		{"tumbleweedspawner"},
	["cactus"] = 			{"cactus", "oasis_cactus"},
	["lightninggoat"] = 	{"lightninggoat"},
	["catcoon"] = 			{"catcoonden"},
	["merm"] = 				{"mermhouse"},
	["buzzard"] = 			{"buzzardspawner"},
	["mushroom"] =			{"red_mushroom", "green_mushroom", "blue_mushroom"},
	["marshbush"] = 		{"marsh_bush"},
	["flint"] = 			{"flint"},
	["mandrake"] = 			{"mandrake"},
	["angrybees"] = 		{"wasphive", "killerbee"},
	["houndmound"] = 		{"houndmound"},
-- chess → 三个棋子。注释明说目的：「降低棋子的数量」。
--   ★ 这是一个很典型的【用翻译表实现数量控制】的手法：
--     不改倍率（那会影响整个抽象项），而是把一个条目拆成三个独立 prefab，
--     每个都拿同一份 density ⇒ 总量不变但种类多了。
--   ⚠ 但注释说的「降低数量」与代码效果【不一致】：
--     TRANSLATE_TO_CLUMP 的注释（:259）说「提高棋子数量」。
--     两处注释互相矛盾，说明这块逻辑经历过反复修改。记录为观察项。
	["chess"] = 			{"knight", "bishop", "rook"}, --here for lowering the quantities of chess pieces.
	["walrus"] = 			{"walrus_camp"},
    ["mushtree"] =          {"mushtree_tall", "mushtree_medium", "mushtree_small", "mushtree_moon"},
    ["bats"] =              {"batcave"},
    ["fissure"] =           {"fissure", "fissure_lower"},
    ["fern"] =              {"cave_fern"},
    ["flower_cave"] =       {"flower_cave", "flower_cave_double", "flower_cave_triple"},
    ["slurper"] =           {"slurper", "slurper_spawner"},
    ["cavelight"] =         {"cavelight", "cavelight_small", "cavelight_tiny"},
    ["bunnymen"] =          {"rabbithouse"},
    ["wormlights"] =        {"wormlight_plant"},
    ["worms"] =             {"worm_spawner"},
    ["slurtles"] =          {"slurtlehole"},
    ["rocky"] =             {"rocky"},
    ["lichen"] =            {"lichen"},
    ["banana"] =            {"cave_banana_tree"},
    ["monkey"] =            {"monkeybarrel_spawner"},
	["mooncarrot"] =        {"mooncarrot_planted"},
    ["palmconetree"] =      {"palmconetree"},

	--lunar island stuff, all prefixed with "moon_"
	["moon_tree"] =			{"moon_tree"},
	["moon_sapling"] =		{"sapling_moon"},
	["moon_berrybush"] =	{"rock_avocado_bush"},
	["moon_rock"] = 		{"moonglass_rock", "rock_moon", "moonglass", "lunar_island_rocks", "lunar_island_rock1", "lunar_island_rock2"},
	["moon_spiders"] =		{"moonspiderden"},
	["moon_carrot"] =		{"carrat_planted"},
	["moon_fruitdragon"] =	{"fruitdragon"},
	["moon_hotspring"] =	{"hotspring"},
	["moon_fissure"] =		{"moon_fissure"},
	["moon_starfish"] =		{"trap_starfish"},
	["moon_bullkelp"] =		{"bullkelp_beachedroot"},

	--Ocean stuff all prefixed with "ocean_"
	["ocean_seastack"] =	{"seastack", "seastack_spawner_rough", "seastack_spawner_swell"},
	["ocean_shoal"] =		{"oceanfish_shoalspawner"},
	["ocean_waterplant"] =	{"waterplant_spawner_rough", "waterplant"},
	["ocean_wobsterden"] =	{"wobster_den_spawner_shore"},
	["ocean_bullkelp"] =	{"bullkelp_plant"},
	["ocean_otterdens"] =   {"boat_otterden"},

-- 三个「特例」条目：terrariumchest / stageplays / junkyard / balatro。
--   注释统一模式：「允许它作为必需的 world gen prefab，但仍可通过设置禁用」。
-- ★ 解决的是一个真实矛盾：任务系统要求某些 prefab 必须出现（如竞技场道具），
--   但玩家可能想在生成时关掉它们。
--   ⇒ 解法：翻译进表里（进入必需 prefab 的计算范围），
--     同时由 runtime_overrides 记住玩家的选择（使 :965 的 never 判断生效）。
--   这个「双写」机制见 :277 的 TRANSLATE_AND_OVERRIDE 判定。
    -- Allow for the Terrarium to be a required world gen prefab, but still disable-able via World Gen settings
    ["terrariumchest"] =    {"terrariumchest"},

    -- Allow for the stageplays to be required world gen prefabs, but still disable-able via World Gen settings
	["stageplays"] =		{"charlie_stage_post", "statueharp_hedgespawner"},
	-- Allow for the junk piles to be required world gen prefabs, but still disable-able via World Gen settings
	["junkyard"] =		    {"junk_pile", "junk_pile_big"},
	-- Allow for the balatro machine to be required world gen prefabs, but still disable-able via World Gen settings
	["balatro"] =		    {"balatro_machine"},

	["tree_rock"] =			{ "tree_rock", "tree_rock1", "tree_rock2" },
}

-- TRANSLATE_TO_CLUMP：走「成簇」而非「均布」的条目。
--   目前只有 chess 一项。
-- ⚠ :303 写入的 translated_prefabs[prefab] 是【表】，而其他项是【数字】。
--   ⇒ translated_prefabs 是异构表（number | {clumpcount, clumpsize}）。
--   ⚠ 下游必须做类型判断：:907 的 `if type(mult) == "number"` 正是为此。
--     ⚠ 但 :873 的 PopulateVoronoi 与 graphnode.lua 的密度处理是否也做了判断？
--       参见 graphnode.lua 中 amt.clumpcount 的注释（那里记录了共享状态污染问题）。
-- ⇒ 这是一个「类型不一致但靠调用方自觉」的隐患。
local TRANSLATE_TO_CLUMP = {
	["chess"] = 			{"worldgen_chesspieces"}, --here for increasing the quantities of chess pieces
}

-- ============================================================
-- TRANSLATE_AND_OVERRIDE：翻译 + 运行时覆盖（双写）
-- ============================================================
-- 【机制】这类条目需要同时做两件事：
--   ① 翻译进 prefab 生成流程（translated_prefabs）
--   ② 记进运行时覆盖表（runtime_overrides），让游戏本体也接受这个设置
--   典型：flowers（花）、rock_ice（冰岩）。
--   ⭐ 为什么需要 ②？因为 flowers 这个 prefab 在【运行时也会被游戏自己生成】（孢子等），
--     只做 ① 的话，玩家设置「never」只能控制地图生成，控制不了孢子。
--   ⇒ 双写是为了让设置对【地图生成】与【运行时生成】同时生效。
local TRANSLATE_AND_OVERRIDE = { --These are entities that should be translated to prefabs for world gen but also have a postinit override to do
	["flowers"] =			{"flower", "flower_evil"},
	["rock_ice"] = 			{"rock_ice"},
}

-- ============================================================
-- ★ TranslateWorldGenChoices —— 把玩家设置翻译成两份产物
-- ============================================================
-- 【返回】(translated_prefabs, runtime_overrides)
--   translated_prefabs : 给地图生成用（prefab → 密度倍率 或 成簇参数）
--   runtime_overrides  : 给游戏运行时用（抽象项名 → 玩家选择）
--
-- 【★ 这就是「世界设置」影响地图的两条通路】
--   通路 A（生成期）：translated_prefabs → PopulateVoronoi 的 prefabDensities
--   通路 B（运行期）：runtime_overrides → 各游戏系统的 spawn 判定
--   ⇒ 同一个设置在两个阶段各生效一次，实现「生成时少放、运行时也少刷」。
local function TranslateWorldGenChoices(gen_params)
    if gen_params == nil or GetTableSize(gen_params) == 0 then
        return nil, nil
    end

    local translated_prefabs = {}
    local runtime_overrides = {}

-- ★ 三分支分派：一个抽象项有三种处理方式。
--   1) 在 TRANSLATE_AND_OVERRIDE 里 ⇒ 翻译 + 运行时覆盖（:277）
--   2) 在 TRANSLATE_TO_PREFABS 里 ⇒ 只翻译（:287）
--   3) 都不在 ⇒ 【只做运行时覆盖】（:295）
--
-- ⚠ 陷阱：:353 的 UpdatePercentage 会【无条件】索引 TRANSLATE_TO_PREFABS[tweak]，
--   若走到分支 3 就会索引 nil ⇒ ipairs(nil) 报错。
--   UpdatePercentage 当前【没有任何调用点】（grep 核实：本文件内无调用）。
--   ⇒ 这是一个死函数，但它是「未来的雷」：一旦被启用就会崩。
    for tweak, v in pairs(gen_params) do
-- ★ 跳过 "default"：默认档位不需要任何处理。
--   ⚠ 这意味着「default」在翻译阶段是完全透明的 ——
--     但倍率表里 default=1（即不改变），所以跳过与乘 1 等价。
--   ⇒ 优化正确。
        if v ~= "default" then
            if TRANSLATE_AND_OVERRIDE[tweak] ~= nil then --Override and Translate
				for i,prefab in ipairs(TRANSLATE_AND_OVERRIDE[tweak]) do --Translate
					local mult = MULTIPLY[v]
					if MULTIPLY_PREFABS[prefab] then
						mult = MULTIPLY_PREFABS[prefab](v, mult)
					end
                    translated_prefabs[prefab] = mult
                end

                runtime_overrides[tweak] = v --Override
            elseif TRANSLATE_TO_PREFABS[tweak] ~= nil then --Translate only
                for i,prefab in ipairs(TRANSLATE_TO_PREFABS[tweak]) do
					local mult = MULTIPLY[v]
					if MULTIPLY_PREFABS[prefab] then
						mult = MULTIPLY_PREFABS[prefab](v, mult)
					end
                    translated_prefabs[prefab] = mult
                end
            else --Override only
                runtime_overrides[tweak] = v
            end

-- 成簇处理【独立于三分支】：不管走哪条分支都会检查。
-- ⚠ 嵌套层级：它在 `if v ~= "default"` 内部、三分支【之外】。
--   ⇒ 只有 chess 会走到（因为只有它在 TRANSLATE_TO_CLUMP 里）。
-- ★ 注意 :303 写的是 translated_prefabs[prefab] = {...}（整体覆盖）。
--   若同一个 prefab 已被前面的分支写入数字倍率，会被【覆盖成表】。
--   ⚠ 实际不会冲突（chess 走的是 :287 分支，写入的是 knight/bishop/rook，
--     而 :303 写的是 worldgen_chesspieces，是不同的 prefab 名）。
			if TRANSLATE_TO_CLUMP[tweak] then
                for i,prefab in ipairs(TRANSLATE_TO_CLUMP[tweak]) do
					local clump = CLUMP[v]
					if clump then
						translated_prefabs[prefab] = {clumpcount = clump, clumpsize = CLUMPSIZE[v]}
					end
                end
			end
        end
    end

-- ★ 空表 ⇒ nil 的归一化。
--   目的：下游 `if translated_prefabs ~= nil then` 就能省掉长度判断。
--   ⚠ 代价：调用方无法区分「没有设置项」与「设置项全被跳过」。
--   在 :928/:937 的必需要求校验里，这个区分是有意义的（见那些行的注释）。
    if GetTableSize(translated_prefabs) == 0 then
        translated_prefabs = nil
    end

    if GetTableSize(runtime_overrides) == 0 then
        runtime_overrides = nil
    end

    return translated_prefabs, runtime_overrides
end
-- ============================================================
-- seasonfn —— 季节工厂（柯里化）
-- ============================================================
-- 【柯里化技巧】seasonfn(friendly, winter) 返回一个函数，
--   该函数再接收 season 名字，返回完整的季节状态表。
--   ⇒ SEASONS 表里每个值都只需要标注两个布尔量，非常易读。
-- ★ 这是 Lua 里做「带参数的模板」最简洁的写法（没有其他语言的闭包糖）。
local function seasonfn(friendly, winter)
	return function(season)
		local totaldaysinseason
		local remainingdaysinseason
-- friendly 分支用 SEASON_LENGTH_FRIENDLY_DEFAULT。
-- ⚠⚠ 疑似缺陷（硬编码系数 2）：totaldaysinseason = ..._FRIENDLY_DEFAULT * 2
--   而 remainingdaysinseason = ..._FRIENDLY_DEFAULT（不乘 2）。
--   ⇒ 若 TUNING.SEASON_LENGTH_FRIENDLY_DEFAULT 的本意是「一个季节的天数」，
--     那这里把它当作「半个季节」用，乘 2 得到全年。
--   ★ 这个 *2 是一个【隐含约定】：TUNING 里那个常量实际含义是「半季长度」。
--   ⚠ 风险：若 Mod 改了那个 TUNING 值，或 DST 某天改成真实季节长度，
--     这里会静默变成「全年 = 2 个真实季节」。
--   没有任何注释说明这一点 —— 记录为高优先级观察项。
--   非 friendly 分支（harsh）没有 *2，说明 harsh 走的是另一套约定。
		if friendly then
			totaldaysinseason = TUNING.SEASON_LENGTH_FRIENDLY_DEFAULT*2
			remainingdaysinseason = TUNING.SEASON_LENGTH_FRIENDLY_DEFAULT
		else
			totaldaysinseason = TUNING.SEASON_LENGTH_HARSH_DEFAULT
			remainingdaysinseason = TUNING.SEASON_LENGTH_HARSH_DEFAULT
		end
		local seasons = {
			season = season,
			totaldaysinseason = totaldaysinseason,
			elapseddaysinseason = 0,
			remainingdaysinseason = remainingdaysinseason,
		}
-- ★ 返回 {seasons=..., weather=...}。
--   winter 为真时附带 weather = {snowlevel=1} ⇒ 一开始就下雪。
--   ⚠ 这是【烘焙进存档】的初始天气，不是运行时逻辑（见 :995-1005）。
--   ⇒ 天气的后续演化由 seasonsmanager 组件负责，生成器只给初值。
		return {seasons = seasons, weather = winter and {snowlevel = 1} or nil}
	end
end

-- ★ 四个季节的初始状态表。
--   autumn/spring 用 friendly 长度且不下雪；
--   winter  同长度但 snowlevel=1；
--   summer  用 harsh 长度（更长更严苛）。
--   ⚠ 注意 summer 没有 winter 参数 ⇒ 从函数签名看第三个参数缺省为 nil/false，
--     语法上合法（Lua 允许少传参数）。
local SEASONS = {
	["autumn"] = seasonfn(true),
	["winter"] = seasonfn(true, true),
	["spring"] = seasonfn(true),
	["summer"] = seasonfn(false),
}

local DEFAULT_SEASON = "autumn"

-- ============================================================
-- ⚠ UpdatePercentage —— 【死函数】（grep 核实：全文件零调用点）
-- ============================================================
-- 【意图】按世界设置倍率，把已算好的 prefab 密度再乘一遍。
--   看起来是 TranslateWorldGenChoices 的早期版本（后来被 :267 重写并取代）。
-- ⚠⚠ 若被启用会立即崩溃：
--   :353 的 TRANSLATE_TO_PREFABS[selected] 对不存在的 selected 会是 nil，
--   :354 直接对 nil 取值 ⇒ "attempt to index a nil value"。
--   ⇒ 在 :295 的「只做运行时覆盖」分支里，任何非 prefab 的设置项都会触发。
--   记录为高优先级死代码观察项。不改代码。
local function UpdatePercentage(distributeprefabs, gen_params)
	for selected, v in pairs(gen_params) do
		if v ~= "default" then
			for i, prefab in ipairs(TRANSLATE_TO_PREFABS[selected]) do
				if distributeprefabs[prefab] ~= nil then
					distributeprefabs[prefab] = distributeprefabs[prefab] * MULTIPLY[v]
				end
			end
		end
	end
end

-- ★ 噪声地块函数表（来自独立模块 noisetilefunctions）。
-- 【机制】噪声地块是一种「贴图化」的连续地块（如沼泽、灰烬地）。
--   WorldSim 烘焙时会逐格求值，用噪声函数决定该格的实际地块类型。
-- ⚠ 它被注册进 C++（:383），所以噪声逻辑在烘焙期才真正生效。
local NoiseTileFunctions = require("noisetilefunctions")

-- ★ GetTileForNoiseTile：C++ 反调用的 Lua 侧实现。
--   未在噪声表里的地块类型 ⇒ 走 default 兜底。
--   ⚠ 注意参数名叫 tile（噪声函数名）但被当作表键用 —— 命名与用途略有错位。
local function GetTileForNoiseTile(tile, noise)
	if NoiseTileFunctions[tile] then
		return NoiseTileFunctions[tile](noise)
	end
	return NoiseTileFunctions.default(noise)
end

-- ★ ValidateGroundTile：烘焙后的地块合法性校验与纠正。
--   噪声地块 ⇒ 强制变成 DIRT（噪声地块是逻辑概念，不是可存储的地块）。
--   非陆地（IsLandTile 为假，如水/不可通行）⇒ 强制变成 ROCKY。
--   合法 ⇒ 原样返回。
-- ★ 这是一个【防御性纠正器】：烘焙后总有些格子的类型不合法，
--   这个函数在写入 tilemap 前把它们统一修正。
-- ⚠ 强制 ROCKY 意味着「原来是什么」的信息丢失了。
--   这在 ForceConnectivity（:536）之后使用 ⇒ 本函数负责把连通性修复产生的
--   临时地块固化成正式地块。
local function ValidateGroundTile(tile)
	if TileGroupManager:IsNoiseTile(tile) then
		return WORLD_TILES.DIRT
	end
	if not TileGroupManager:IsLandTile(tile) then
		return WORLD_TILES.ROCKY
	end
	return tile
end

-- ============================================================
-- ★★★★★ Generate —— 【世界生成总流程】
-- ============================================================
-- 【签名】Generate(prefab, map_width, map_height, tasks, level, level_type)
--   prefab       : 地图风格标识（"forest" / "cave"），决定走哪条分支
--   map_width/height : 【入参被完全覆盖】（见 :489-490），传进来只为接口统一
--   tasks        : 任务集合（由 tasks.lua 的 region_tasksets 提供）
--   level        : 关卡定义（level.lua），提供 overrides / required_prefabs 等
--   level_type   : 任务关/自由关等
--
-- ============================================================
-- 【★★ 真实阶段流程图（已核实，纠正任务描述给出的顺序）】
--
--   S0  参数翻译        :382-491  把玩家设置翻译成 story_gen_params + 地图尺寸
--       ├ :382-384 注册三个 Lua 回调进 C++ WorldSim
--       ├ :392      断言 level.overrides 存在
--       ├ :402-453  逐项翻译世界设置（出生点/孤岛/分支/成环/布局模式…）
--       ├ :455-460  应用特殊事件
--       └ :462-491  地图尺寸（含 PS4 分支）→ WorldSim:SetWorldSize
--
--   S1  BuildStory      :493-517  → storygen.lua:1394（Lua 侧建图）
--       └ 七步 GenerationPipeline（storygen.lua:86-95）：
--          GenerateNodesFromTasks → AddBGNodes → AddCoveNodes
--          → InsertAdditionalSetPieces → ProcessExtraTags(废弃) → ProcessOceanContent
--          再 AddRegionsToMainland 挂离岛
--
--   ★★ S2  Voronoi + Lloyd 松弛   :497-506
--       :497 WorldGen_InitializeNodePoints  初始化点集
--       :499 WorldGen_VoronoiPass(100)      ★★ 第一次 Lloyd，100 次迭代
--       :506 AddRegionsToMainland 期间每加一个区域：
--              :502 WorldGen_AddNewPositions  追加新区域的点
--              :503 WorldGen_VoronoiPass(50)    ★ 第二次 Lloyd，50 次迭代（每区域一次）
--
--   S3  烘焙（Commit）  :520-589
--       :522 WorldGen_Commit     ★ 不可撤销的烘焙点，失败即 return nil
--       :526 ApplyPoisonTag      把 RoadPoison 标签落成实际标记
--       :527 ConvertToTileMap    转成 tilemap
--       :529 SeparateIslands     分离岛屿
--       :536 ForceConnectivity   ★ 连通性修复（保证玩家能走到所有必需区域）
--       :557 DrawRoads           铺路
--       :561-575 SetTilesViaFunction + SafeFromDisconnect 标记
--       :587-588 SaveEncode + CreateNodeIdTileMap
--
--   S4  特殊标签后处理    :645-838  Labyrinth（迷宫树）与 Maze（元迷宫）
--   S5  散布             :840-974  Voronoi 铺装 + 海洋 + 实体清理 + 校验
--   S6  编码与落盘        :976-1056 地图编码 / 季节 / 出生点校验 / 道路序列化
--
-- 【★ 与任务描述中给出的顺序对照】
--   任务描述：PlaceSpecialPoint → Voronoi → PlaceItems → PlaceTasks
--            → PlaceCharacters → PostProcess
--   实际情况：这些函数名在仓库中【零命中】。真实名称与顺序见上表。
--   ⇒ 特别地：「PlaceTasks / PlaceCharacters」不是一个独立阶段 ——
--     任务系统（storygen.lua）在【S1】就已经把图结构定好了，
--     「放任务」= 在已有地块上摆 prefab（S5 的 PopulateVoronoi）。
--
-- 【★ return nil 的五处】（全部触发 worldgen_main.lua:421 的重试循环）
--   :523  Commit 失败      :546  Wormhole 出错
--   :602  某地块面积 < 8   :860  断开地块超过 5%
--   :860（同上）           :970  缺少必需 prefab
--   :1013 没有出生点
--   ⇒ 每次 return nil 都会重新消耗随机数并完全重建地图 ⇒ 最坏 5× 耗时。
--   ⚠ 重试循环细节（worldgen_main.lua:419-435）：
--     maxtries = 5（:419）、while savedata == nil（:421）、
--     try = try + 1（:431）、collectgarbage（:434）、WorldSim:ResetAll（:435）。
--     ★ ResetAll 重置 WorldSim 但【不重置 math.random】⇒
--       第 N 次尝试拿到的是同一种子序列的第 N 段 ⇒ 5 次是不同的世界，
--       既非重试同条件、也非穷举 ⇒ 可能 5 次全败。
--
-- 【★ return nil 与 SKIP_GEN_CHECKS 的关系】
--   所有校验失败点都用 `if SKIP_GEN_CHECKS == false then return nil end` 包裹。
--   ⇒ 把 :3 的 SKIP_GEN_CHECKS 改成 true 即可让生成器【永不失败】，
--     代价是可能产出「面积过小」「缺必需 prefab」「没有出生点」的坏地图。
--   ★ 这是调试世界生成时的标准手法：设 true 看生成器到底想放什么。
--     注意这是 local 变量，需改源码。
local function Generate(prefab, map_width, map_height, tasks, level, level_type)
-- ============================================================
-- 【S0-a】把三个 Lua 回调注册进 C++ WorldSim
-- ============================================================
-- ★ 这是 Lua 与 C++ 的【反向调用机制】：Lua 把函数交给引擎，
--   引擎在生成过程的特定时刻回调它们。
--   典型用途是【规则注入】—— 引擎问「这块噪声该变成什么地块？」
--   （:383）而规则逻辑留在 Lua 侧，改规则不必重编引擎。
	WorldSim:SetPointsBarrenOrReservedTile(WORLD_TILES.ROAD)
	WorldSim:SetResolveNoiseFunction(GetTileForNoiseTile)
	WorldSim:SetValidateGroundTileFunction(ValidateGroundTile)

    local SpawnFunctions = {
        pickspawnprefab = pickspawnprefab,
        pickspawngroup = pickspawngroup,
		pickspawncountprefabforground = pickspawncountprefabforground,
    }

    assert(level.overrides ~= nil, "Level must have overrides specified.")
-- 【deepcopy(level.overrides)】★ 注意是【深拷贝】。
--   为什么必须深拷贝：overrides 之后会被本函数一路【写入】（:403/:417/:427…），
--   若不拷贝就会污染 level.overrides 本身。
--   ⇒ 副作用（可接受且必要）：current_gen_params 从「只读预设」变成了「工作副本」，
--     :981 存进存档的 overrides 是这个被改写过的副本。
--   ⚠ 性能：deepcopy 是全量深拷贝，425 世界下约 1000 次节点级拷贝
--     ⇒ 这是「任务解析 + 图构建 < 50ms」预算里不可忽略的一小项。
    local current_gen_params = deepcopy(level.overrides)

-- 【story_gen_params】★ 与 current_gen_params 是【两张不同的表】，别混：
--   current_gen_params ← level.overrides 的深拷贝，玩家设置（字符串枚举）
--   story_gen_params    ← 翻译给 storygen 的参数（数字/布尔/表）
--   ★ 例：islands="often"（字符串）→ story_gen_params.island_percent=0.8（数字）。
--   这层间接是必需的：storygen 不该知道玩家界面的字符串长什么样。
    local story_gen_params = {}

-- 【默认不可通行地块】WORLD_TILES.IMPASSABLE。
--   ★ 这是「锁」的物理材质：storygen 用 blocker_blank 造门（storygen.lua:995/:1165），
--     烘焙后这些格就是玩家穿不过去的墙。
--   ⇒ 锁—钥匙体系在本层的物理落点，见 map/lockandkey.lua 与 storygen.lua 的 blocker_blank。
    local default_impassible_tile = WORLD_TILES.IMPASSABLE

    story_gen_params.impassible_value = default_impassible_tile
    story_gen_params.level_type = level_type

-- 【start_location 兜底】为 nil 时补 "default"。
--   ⚠ 注意 :405 又判了一次 `~= nil` —— 同一条件判两次，属冗余。
--     第 2 次判断恒为真（:403 刚补过），无害但多余。
    if current_gen_params.start_location == nil then
        current_gen_params.start_location = "default"
    end
    if current_gen_params.start_location ~= nil then
        local start_loc = startlocations.GetStartLocation( current_gen_params.start_location )
-- ============================================================
-- 【★ 随机数消耗点 #1 & #2】出生场景件与起始节点
-- ============================================================
-- 【模式】startlocations 里允许一个位置对应【多个候选】，此处随机挑一个：
--   type(...) == "table" → math.random(#t) 索引；否则直接用单值
-- ★ 这是「同种子同世界」链条上的第一环：
--   math.random 的调用【顺序】一旦有变化，后面所有结果全变。
--   ⚠ 自研世界生成最易踩的雷：
--     任何「在两处条件分支里各调一次 math.random」的写法都会破坏可复现性，
--     因为分支条件可能因前置改动而改变。
--   ⇒ 正确姿势：把随机点【集中到单一时序的列表】再统一消费，
--     而不是让它们散落在流程各处。
--   参见文件头「随机数与可复现性」小节与 bug-patterns.md E4。
        story_gen_params.start_setpeice = type(start_loc.start_setpeice) == "table" and start_loc.start_setpeice[math.random(#start_loc.start_setpeice)] or start_loc.start_setpeice
-- 【随机数消耗点 #2】起始节点（与 :407 的 start_setpeice 相邻）。
--   ★ 二者必须【成对理解】：先挑场景件、再挑节点，顺序颠倒会得到不同的世界。
--   ⚠ :409-412 是向后兼容的兜底（existing_start_node 已不再支持）。
        story_gen_params.start_node = type(start_loc.start_node) == "table" and start_loc.start_node[math.random(#start_loc.start_node)] or start_loc.start_node
		if story_gen_params.start_node == nil then
			-- existing_start_node is no longer supported
-- 【向后兼容兜底】existing_start_node —— 源码注释：
--   "existing_start_node is no longer supported"（该字段已废弃）。
--   ★ 保留它是为了不让老 MOD 的 startlocations 定义直接崩溃。
--   ⚠ 但它同样是 math.random 消耗点 ⇒ 若被走到会再次改变随机序列。
--     这类「废弃但仍可达」的分支是可复现性的隐藏破坏者。
			story_gen_params.start_node = type(start_loc.existing_start_node) == "table" and start_loc.existing_start_node[math.random(#start_loc.existing_start_node)] or start_loc.existing_start_node
		end
    end

-- 【islands → island_percent】把玩家选项映射成概率：
--   always=1  never=0  default=0.2  sometimes=0.1  often=0.8
--   ★ 顺序有讲究：default(0.2) 比 sometimes(0.1) 高，
--     反映「默认比偶尔更常出现孤岛」的设计倾向。
--   ⚠ 未知选项会得到 nil（表取不存在的键）⇒ story_gen_params.island_percent=nil
--     ⇒ 下游 :449/:610 的 `if ... island_percent` 判定为 false ⇒ 静默退回默认行为。
--     这是【静默失败】模式：不报错，但玩家的设置被忽略。
--   参见 storygen.lua:449/:610 的消费点。
    if  current_gen_params.islands ~= nil then
        local percent = {always=1, never=0,default=0.2, sometimes=0.1, often=0.8}
        story_gen_params.island_percent = percent[current_gen_params.islands]
    end

-- 【branching】分支策略，原样透传（字符串）。
--   ★ 与 islands 不同，这里不做字符串→数字的翻译，
--     因为 branching 的语义由 storygen 内部再分派（storygen.lua:394/:407/:427/:430/:433/:577）。
    if  current_gen_params.branching ~= nil then
        story_gen_params.branching = current_gen_params.branching
    end

-- 【loop → loop_percent + loop_target】★ 一项设置翻成两个参数：
--   never   → percent=0,    target="any"
--   default → percent=nil,  target=nil   ← 交给 storygen 自决定
--   always  → percent=1.0,  target="end"
--   ★ 设计要点：default 刻意【不填】而留 nil，让 storygen 的默认策略生效。
--     这样调整 storygen 的默认成环概率时，不必同步改这里。
--   消费点：storygen.lua:900 的 loop_percent（闭环概率）。
--   ⚠ 同 :415，未知选项 ⇒ percent=nil ⇒ 等价于 default，静默忽略玩家设置。
    if  current_gen_params.loop ~= nil then
        local loop_percent = { never=0, default=nil, always=1.0 }
        local loop_target = { never="any", default=nil, always="end"}
        story_gen_params.loop_percent = loop_percent[current_gen_params.loop]
        story_gen_params.loop_target = loop_target[current_gen_params.loop]
    end

-- 【★ layout_mode】★★ 最关键的一项透传，直接【切换锁—钥匙算法】：
--   "RestrictNodesByKey" → storygen 走 RestrictNodesByKey（批量分支法，:299）
--   其他（含 nil）        → storygen 走 LinkNodesByKeys（逐个贪心法，:493）
--   ★ 这是本文件对「地图连通性」最直接的开关：两套实现语义近似但【不等价】，
--     选哪套会改变哪些区域被锁住、钥匙放在哪。
--   ★★ 与 bug-patterns.md E1「锁—钥匙致不可达」直接相关：
--     切换 layout_mode 会换掉整条连通性算法 ⇒ 若某关卡只在其中一套下可达，
--     切到另一套就可能产生不可达地图。
--   详见 map/lockandkey.lua 与 storygen.lua:299/:493。
    if current_gen_params.layout_mode ~= nil then
        story_gen_params.layout_mode = current_gen_params.layout_mode
    end

-- 【keep_disconnected_tiles】★ 直接控制 E5 缺陷的暴露与否：
--   nil/false → :853 会跑 DetectDisconnect，把悬空 FAKE_GROUND 清掉（正确但可能误删）
--   true      → 【完全跳过检测】⇒ 保留 FAKE_GROUND ⇒ 玩家可能走进虚空
--   ★ 详见 :846-852 的原始 NOTE 与 :857 的容差说明。
--   ⚠ 这是玩家可见的难度/风险开关，但没有任何 UI 警示。
    if current_gen_params.keep_disconnected_tiles ~= nil then
        story_gen_params.keep_disconnected_tiles = current_gen_params.keep_disconnected_tiles
    end

-- 【no_joining_islands】是否把孤岛强制连上主陆。
--   ★ 与 :533 的 join_islands、:536 ForceConnectivity、:978 GetEncodedMap 三处联动，
--     必须是同一个值，否则存档里的地图与实际编码的地图会不一致。
--   ⚠ 该值在 :533 才被算出（`not current_gen_params.no_joining_islands`），
--     而 :439 只是把它存进 overrides ⇒ 中间若被改会不一致。
    if current_gen_params.no_joining_islands ~= nil then
        story_gen_params.no_joining_islands = current_gen_params.no_joining_islands
    end

-- 【has_ocean】★ 只透传给 story_gen_params，不改 overrides。
--   ⇒ :874 的海洋分支读的是 story_gen_params.has_ocean，
--     而 :585 存进 save.map 的是 current_gen_params.has_ocean。
--   ⚠ 两处同名字段来自【不同的表】，若将来翻译逻辑改变会不一致。
--     当前值相同（:443 原样拷贝）所以无害，属【脆弱的一致性】。
    if current_gen_params.has_ocean ~= nil then
        story_gen_params.has_ocean = current_gen_params.has_ocean
    end

-- 【no_wormholes_to_disconnected_tiles】虫洞是否允许通向断开的地块。
--   ⚠ 但 :540 的使用处被 `if false and ...` 整段关闭了 ⇒ 该设置当前【完全无效】。
--     见 :539 的原始注释：与孤岛技术冲突，会在 Atrium 里造成虫洞。
    if current_gen_params.no_wormholes_to_disconnected_tiles ~= nil then
        story_gen_params.no_wormholes_to_disconnected_tiles = current_gen_params.no_wormholes_to_disconnected_tiles
    end

-- 【wormhole_prefab】虫洞用的 prefab 名。
--   ⚠ 同 :447，消费侧（:541）已被 `if false` 关闭 ⇒ 该参数当前也是无效的。
--   ★ 两处失效设置并排出现，说明这是一次【未完成的回退】而非有意废弃。
    if current_gen_params.wormhole_prefab ~= nil then
        story_gen_params.wormhole_prefab = current_gen_params.wormhole_prefab
    end

-- 【ApplySpecialEvent】应用单个特殊事件（万圣节/冬天等）。
--   ★ 与 :456-460 的循环并列：前者处理「单个具名事件」，
--     循环处理「所有枚举出来的事件」⇒ 两套机制共存。
--   ⚠ 顺序敏感：多个事件同时开启时，:456 的 pairs 遍历顺序【不确定】
--     （Lua 的 pairs 顺序依赖哈希布局）⇒ 同种子可能得到不同的事件组合。
--     ★ 这是 E4「pairs 遍历顺序」在本文件的具体落点之一。
	ApplySpecialEvent(current_gen_params.specialevent)
-- 【遍历所有特殊事件】逐个检查 overrides 里是否为 "enabled"。
--   ⚠⚠ 疑似缺陷（可确证·真 bug·影响可复现性）：
--     `for k, event_name in pairs(SPECIAL_EVENTS)` 使用了【无序遍历】。
--     若玩家同时开启 ≥2 个事件，ApplyExtraEvent 的【调用顺序】不确定。
--     【推理依据】Lua 5.1 的 pairs 遍历哈希表顺序取决于表内容与内部布局，
--       不保证稳定；而不同事件大概率修改不同的全局状态 ⇒ 最终生效结果
--       取决于遍历顺序 ⇒ 同一世界在【同种子、同代码】下仍可能不同。
--     ⇒ 这是 E4 三大破坏者之一（pairs 顺序依赖）的确凿实例。
--     ⚠ 修复方向（仅说明，不改代码）：改用 SPECIAL_EVENTS 的【数组】形态，
--       或对键先 table.sort 再遍历。
--   ★ 对照：:45的 SEASONS 表就是数组式的 ⇒ 说明作者知道正确写法，
--     只是 SPECIAL_EVENTS 用了字典。
	for k, event_name in pairs(SPECIAL_EVENTS) do
		if current_gen_params[event_name] == "enabled" then
			ApplyExtraEvent(event_name)
		end
	end

-- 【默认地图边长 350】非「default」尺寸时的兜底。
--   ★ 与 :476 的 `default = 425` 注释 "default == large, at the moment" 呼应：
--     尺寸档位是纯数据表，增删改不影响逻辑。
    local min_size = 350
-- 【world_size → 边长】★ 玩家界面的尺寸档位映射到具体边长。
    if current_gen_params.world_size ~= nil then
        local sizes
-- 【PS4 分支】主机平台只有 3 档且没有 tiny/small/huge。
--   ★ 平台差异被编码进【数据表】而非逻辑分支，是很干净的做法。
--   ⚠ 但这也意味着 PS4 与 PC 的世界尺寸选项【不对等】，
--     同种子在两平台上生成的地图【大小不同】⇒ 跨平台不可复现。
--   ⇒ 又一个 E4 的边界条件。
        if PLATFORM == "PS4" then
            sizes = {
                ["default"] = 350,
                ["medium"] = 400,
                ["large"] = 425,
            }
        else
            sizes = {
-- 【tiny=1 的荒诞取值】★ 极易误读，特意标注：
--   tiny 的边长是【1 格】，不是 100/150 之类的任何实际尺寸。
--   【为什么】tiny 的玩法含义是「测试地图」—— 只要够放下最基本的结构即可，
--     用于快速验证任务链连通性，不追求可玩性。
--   ⚠ 后果：tiny 世界几乎必然触发 :599 的 area < 8 校验而 return nil，
--     5 次重试后放弃 ⇒ 【tiny 选项在实践中可能根本生成不出来】。
--   ★ 这一点在原版没有任何 UI 提示，属【静默的功能性缺陷】。
                ["tiny"] = 1,
                ["small"] = 50,
                ["medium"] = 400,
-- 【default == 425 == large】源码自带注释承认两者当前等价。
--   ⚠ 一旦哪天只改其中一个，玩家会看到「默认尺寸」与「大地图」行为分叉，
--     而 UI 上看不出区别。属【数据耦合】风险。
                ["default"] = 425, -- default == large, at the moment...
                ["large"] = 425,
                ["huge"] = 450,
            }
        end

-- 【无效尺寸的处理】只打印 ERROR，然后【继续用 min_size 默认值】。
--   ⚠ 注意这里【不 return nil】⇒ 无效尺寸不会导致生成失败，
--     而是静默退化成 350（或 default 预设的 min_size）。
--   ⇒ 属于「宽容但不可感知」的失败：玩家选了超大图却得到中等图，游戏不报错。
--   ★ 对比 :599/:857/:964 的校验失败都会 return nil ⇒
--     这里的不一致（只警告不失败）值得注意。
        if sizes[current_gen_params.world_size] then
            min_size = sizes[current_gen_params.world_size]
            print("New size:", min_size, current_gen_params.world_size)
        else
            print("ERROR: Worldgen preset had an invalid size: "..current_gen_params.world_size)
        end
	end
-- ============================================================
-- 【★ 入参被完全覆盖】map_width / map_height 的生命周期终点
-- ============================================================
-- ★★ 重要：函数签名收了 map_width/map_height（worldgen_main.lua:422 传的是 1024），
--   但这两行【直接覆盖】成 min_size（350~450）。
--   ⇒ 传入的 1024 从未被使用。这是【接口与实现脱节】的典型：
--     签名沿用了「由调用方决定尺寸」的历史设计，
--     实现却改为「由关卡预设决定尺寸」，但没改签名。
--   ⚠ 不影响正确性（覆盖彻底），但会误导阅读者：
--     看签名会以为地图大小是调用方的决定。
--   ⇒ 自研生成器应直接从参数取尺寸，或删掉这两个入参。
--   ★ 之后 :531 会从 WorldSim 重新读回真实尺寸（可能已被 ForceConnectivity 改变）。
    map_width = min_size
    map_height = min_size
    WorldSim:SetWorldSize(map_width, map_height)

-- 【阶段推进日志】"Creating story..." —— 玩家在生成界面看到的进度文案。
--   ★ 全文件 27 处 print 构成了唯一的耗时观察点（没有任何计时器）。
--   ⚠ 性能排查建议：这些 print 前后加 os.clock()/GetTimeReal() 埋点。
--     参见 bug-patterns.md E3 的阶段耗时预算表。
    print("Creating story...")
    require("map/storygen")
-- ============================================================
-- 【★ S1 边界】建剧情图 —— 与 storygen 的交接点
-- ============================================================
-- 【返回值两个】
--   topology_save —— 序列化后的拓扑（:587 会被压成纯数据）
--   storygen       —— Story 对象【还活着】，后面 :506/:886 还要用它的方法/字段
-- ★ 两个生命周期不同的返回值：拓扑在 :587 后变「死数据」，
--   storygen 对象则一直活到 :889。
--   ⚠ 混用二者是本文件最容易出错的点（如 :936 用拓扑，:886 用 storygen）。
--   详见 map/storygen.lua:1394 BuildStory 与 :86 GenerationPipeline。
    local topology_save, storygen = BuildStory(tasks, story_gen_params, level)

	WorldSim:WorldGen_InitializeNodePoints();

	WorldSim:WorldGen_VoronoiPass(100)

	local function on_region_added_fn()
		WorldSim:WorldGen_AddNewPositions()
		WorldSim:WorldGen_VoronoiPass(50)
	end

	storygen:AddRegionsToMainland(on_region_added_fn)

-- 【ISLAND_EXPERIMENT_IDEA】★ 显式关闭的实验特性（硬编码 false）。
--   ⚠ 与 :447/:451/:540 一样，这是【未完成的回退】。
--     关闭它 ⇒ 洞穴世界的「遗迹离岛」不会生成。
--   ★ 三处 `if false` 并存，说明曾经有一次孤岛重构（ISLAND_EXPERIMENT_IDEA）
--     被部分回退，残留了这几处开关。建议在自研版本中统一清理。
	local ISLAND_EXPERIMENT_IDEA = false
	if prefab == "cave" then
        if ISLAND_EXPERIMENT_IDEA then
            print("Creating the ripped off ruins island from centipede cave...")
            storygen:AddRegionToTasksNodes(storygen.region_tasksets["ruins_island"], "CentipedeCaveTask", "VentsRoom_exit", 2, on_region_added_fn)
            print("... ruins island created")
        end
	end

    print("... story created")


    print("Baking map...", min_size)

	if not WorldSim:WorldGen_Commit() then
        return nil
    end

    topology_save.root:ApplyPoisonTag()
    WorldSim:ConvertToTileMap(min_size)

	WorldSim:SeparateIslands()
    print("Map Baked!")
	map_width, map_height = WorldSim:GetWorldSize()

-- 【join_islands】★ 贯穿后半程的同一个布尔：
--   :536 ForceConnectivity(join_islands, ...)  修复连通性时是否合并孤岛
--   :557 DrawRoads(join_islands, ...)           铺路时是否跨越孤岛
--   :978 GetEncodedMap(join_islands)            编码时是否包含孤岛
--   :1022 GetRoad(0, join_islands)              取路时是否跨越孤岛
--   ⚠ 四处必须一致，否则会出现「地图上有路但寻路找不到」类难查 bug。
--   ★ 这是「同一语义参数在多处传递」的典型，适合抽成一个上下文对象。
	local join_islands = not current_gen_params.no_joining_islands

	-- Note: This also generates land tiles
-- ★★ 【连通性修复的核心】ForceConnectivity
--   【签名解读】ForceConnectivity(join_islands, false, WORLD_TILES.ROCKY)
--     第 1 参 join_islands —— 是否把孤岛并入主陆
--     第 2 参 false        —— 原注释 :535 写 "Note: This also generates land tiles"，
--                          第二参语义（推测为「是否在修复处生成新地块」）本处传 false
--     第 3 参 WORLD_TILES.ROCKY —— 修复失败时填什么地块
--   【★ 这就是「保证玩家能从出生点走到所有必需区域」的执行点】
--     图上的连通性（图论意义）由 storygen 的 AddEdge 保证；
--     空间上的连通性（几何意义）由本行保证。
--     ★★ 二者【不等价】：图上相邻的两个胞元在平面上可能相距很远
--       （中间夹着别的胞元），或迷宫在边缘被切断（见 :672/:816）。
--   【副作用】本行【会改变地块】⇒ 它在 :527 ConvertToTileMap【之后】、
--     :531 GetWorldSize【之前】执行，所以 :531 读回的是修复后的尺寸。
--   ⚠ 它也可能【制造】新地块（见 :526 ApplyPoisonTag 的配套语义），
--     这正是 :1059 导出表里没有它的原因——它是不可复用的纯生成期操作。
--   关联缺陷：见 bug-patterns.md E5 与本文件 :846-852 的自白。
    WorldSim:ForceConnectivity(join_islands, false, WORLD_TILES.ROCKY)--prefab == "cave" )

    local entities = {}
-- 【原始注释逐字保留】
--   "turning this off for now because its conflicting with the island tech
--    and disconnected node stripping, causing wormholes in the atrium"
-- ★ 信息量很大：作者明确知道与【孤岛技术 + 断开节点剔除】冲突，
--   症状是「Atrium（大厅）里出现虫洞」，但选择整段关闭而非修复。
--   ⇒ 这解释了为什么 :447/:451 两个参数至今无效。
--   ⚠ 「wormholes in the atrium」正是 :846-852 那段 Sigh 注释提到的同一个区域 ——
--     两处自白指向同一个结构性问题：【Atrium 这类『悬空但可达』的区域】
--       是整套孤岛/断连机制的长期痛点。
	-- turning this off for now because its conflicting with the island tech and disconnected node stripping, causing wormholes in the atrium
	if false and not current_gen_params.no_wormholes_to_disconnected_tiles then
		topology_save.root:SwapWormholesAndRoadsExtra(entities, map_width, map_height)
		if topology_save.root.error == true then
			print ("ERROR: Node ", topology_save.root.error_string)
			if SKIP_GEN_CHECKS == false then
	    		return nil
			end
		end
	end

-- 【铺路条件】roads 设置非 never 【且】不是洞穴世界。
--   ★ 洞穴世界不铺路 ⇒ 洞穴靠迷宫化地形本身引导玩家。
	if (current_gen_params.roads == nil or current_gen_params.roads ~= "never") and prefab ~= "cave" then
-- 【SetRoadParameters】★ 道路的六项形态参数全在这里定死。
--   ★ 道路宽度有【最小/最大/最小边缘/最大边缘】四档 + 抖动，
--     说明道路是【有宽度渐变的有机形状】而非直线，
--     这是 DST 视觉风格的重要一环。
--   ★ 这六项是硬编码的（ROAD_PARAMETERS 常量），玩家不可调 ——
--     与资源密度可调形成对比，说明【道路被视为美术而非玩法】。
--   ⚠ 洞穴分支不执行本行 ⇒ 洞穴的 DrawRoads 也不会被调用（见 :550）。
	    WorldSim:SetRoadParameters(
			ROAD_PARAMETERS.NUM_SUBDIVISIONS_PER_SEGMENT,
			ROAD_PARAMETERS.MIN_WIDTH, ROAD_PARAMETERS.MAX_WIDTH,
			ROAD_PARAMETERS.MIN_EDGE_WIDTH, ROAD_PARAMETERS.MAX_EDGE_WIDTH,
			ROAD_PARAMETERS.WIDTH_JITTER_SCALE )
-- ============================================================
-- 【S3 尾】逐节点铺装 + 「不许被切掉」标记
-- ============================================================
-- ★ 为什么放在 DrawRoads 之后：DrawRoads 只保证「路」连通；
--   本段保证的是「节点自己的地块」被正确铺设，并给关键节点打保护标记。

		WorldSim:DrawRoads(join_islands, WORLD_TILES.DIRT)
	end

	-- Run Node specific functions here
-- 【逐节点处理】GetNodes(true) 的 true = 含子节点（递归展开整棵树）。
-- ★ 这是【Lua 侧最后一次按节点遍历】的机会——之后全是 WorldSim 的批量操作。
--   拓扑被压成 save.map.topology 之后（:587）就再也拿不回节点对象了。
	local nodes = topology_save.root:GetNodes(true)
	for k,node in pairs(nodes) do
-- 【SetTilesViaFunction】把该节点的房间布局/静态布局写进 tilemap。
--   真正的绘制在 network.lua 的 node:SetTilesViaFunction 里（按 node.data 里的
--   room_name / layout_name 查 map/rooms/ 与 map/static_layouts/ 的定义）。
--   参见 network.lua 的节点侧实现与 room_functions.lua。
		node:SetTilesViaFunction(entities, map_width, map_height)

-- 【SafeFromDisconnect】★ 「保护这些格不被 DetectDisconnect 清理掉」。
--   背景见 :846-852 的原始 NOTE：
--     「ForceDisconnected 标签并不能真的让虚空里的东西与主陆断开，
--      它反而依赖一块 FAKE_GROUND 临时地块把它连上，事后才清理。」
--   ★ 推论：没有这面保护旗，某些房间（例如 Atrium）会在 :855
--     DetectDisconnect 时被误删 —— 所以必须在这里逐格登记。
--   参见 map/forest_map.lua:855 DetectDisconnect 与 bug-patterns.md E5。
		if node.data.SafeFromDisconnect then
-- 【GetPointsForSite】取出该节点 Voronoi 胞元覆盖的所有格子坐标。
--   与 Voronoi/Lloyd 的站点集是同一套点（:497 WorldGen_InitializeNodePoints 建，
--   :499 VoronoiPass(100) 松弛过）⇒ 这里拿到的是「松弛后」的最终胞元。
			local points_x, points_y, points_type = WorldSim:GetPointsForSite(node.id)
-- ⚠ 疑似缺陷（低危·可确证）：#points_x ~= 0 的写法是对的（取长度），
--   但下一行的错误分支有真 bug，见 :572。
			if #points_x ~= 0 then
				for i = 1, #points_x do
					WorldSim:MakeSafeFromDisconnect(points_x[i], points_y[i])
				end
			else
-- ⚠⚠ 疑似缺陷【可确证·真 bug·本批次最高价值发现】
--   内容：`print(self.id.." Cant process points")`
--
--   【推理依据】
--     1) :381 的签名是 local function Generate(prefab, map_width, map_height,
--        tasks, level, level_type) —— 【没有 self 参数】。
--     2) grep 全文件，`local self` / `self =` / `_G.self` 均为【零命中】。
--     3) Generate 是普通函数（不是方法），调用方 worldgen_main.lua:422 以
--        forest_map.Generate(...) 形式调用，【不会隐式传入 self】。
--     4) Lua 规则：未声明的全局变量求值为 nil ⇒ self.id 立刻抛
--        "attempt to index a nil value (global 'self')"。
--
--   【为什么至今没炸】
--     这是错误【日志】分支，只在「该节点一个格子都没分到」时才进。
--     正常生成中这几乎不会发生 ⇒ 缺陷被「不可达的错误处理」掩盖了。
--     ★ 但一旦触发，整个世界生成直接崩溃（而不是优雅降级），
--       而它本来的意图只是打一行日志。这是典型的「日志比业务更致命」。
--
--   【正确写法应为】（仅说明，本项目严禁改动原版代码）
--     print(prefab.." Cant process points")   -- 或直接删掉 self.id
--
--   ★ 顺带印证：全文件另外 26 处 print 都没有这种问题，
--     说明 :572 是从别的「类方法」上下文复制粘贴过来的残留。
				print(self.id.." Cant process points")
			end
		end
	end

-- ============================================================
-- 【S6 前段】编码：把内存中的拓扑与地块压成 save 结构
-- ============================================================
-- ★ 此时 WorldSim 里已是最终像素；本段只做「打包」，不再改地图内容。
--   ⚠ 因此 :579 之后到 :1056 之间任何 return nil，都是「白跑一遍烘焙」。
    print("Encoding...")

    local save = {}
    save.ents = {}
-- 【save.map 的五个字段】
--   tiles/topology 后面由 WorldSim 填；prefab/has_ocean 在此落定。
--   ★ has_ocean 取自【关卡 overrides】而非 :443 的翻译结果，
--     两者同名不同源 —— 注意 :443 只把值拷进 story_gen_params，不改 overrides。
    save.map = {
        tiles = "",
		topology = {},
        prefab = prefab,
		has_ocean = current_gen_params.has_ocean,
    }
-- 【SaveEncode】把图拓扑序列化成可 JSON 化的纯表（节点/边/标签）。
--   ★ 这一步之后拓扑就【不可逆地变成了数据】——后续 :596 起的校验
--     只能读数据，不能再回头改图。这是「先生成后校验」架构的必然代价。
--   参见 network.lua 的 SaveEncode 与 GetEncodedTopology。
    topology_save.root:SaveEncode({width=map_width, height=map_height}, save.map.topology)
-- 【CreateNodeIdTileMap】生成「节点 ID 栅格图」：每格记录自己属于哪个节点。
--   ★ 运行时（存档加载后）靠它做碰撞/寻路/实体归属判定，
--     体积等于整张地图的宽×高 个字符串 ⇒ 编码耗时 0.3-1 s 的主因之一。
	WorldSim:CreateNodeIdTileMap(save.map.topology.ids)
    print("Encoding... DONE")

    -- TODO: Double check that each of the rooms has enough space (minimimum # tiles generated) - maybe countprefabs + %
    -- For each item in the topology list
    -- Get number of tiles for that node
    -- if any are less than minumum - restart the generation

-- ============================================================
-- 【校验 #1】地块面积下限：area < 8 ⇒ 放弃本次生成
-- ============================================================
-- 【为什么要卡面积】
--   Voronoi 胞元可能退化成极小的碎块（尤其是孤岛区域与深凹处）。
--   面积过小的地块放不下任何房间 ⇒ 玩家走过去发现是空地，属于【坏地图】。
--   阈值 8 是经验值：一个最小可活动房间的量级。
    for idx,val in ipairs(save.map.topology.nodes) do
-- ★ 豁免：LOOP_BLANK_SUB 类型的节点不参与面积校验。
--   原因见 storygen.lua 的 make_loop / LOOP_BLANK_SUB ——
--   「环路空地」本来就是【故意留的空地】，面积小是设计意图，不是缺陷。
--   参见 storygen.lua:1165（LOOP_BLANK_SUB 的 value 定义）。
		if string.find(save.map.topology.ids[idx], "LOOP_BLANK_SUB") == nil  then
 	    	local area = WorldSim:GetSiteArea(save.map.topology.ids[idx])
	    	if area < 8 then
	    		print ("ERROR: Site "..save.map.topology.ids[idx].." area < 8: "..area)
-- 【SKIP_GEN_CHECKS 闸门】
--   ★ 调试世界生成的标准手法：把 :3 的 SKIP_GEN_CHECKS 改成 true，
--     所有校验点全部放行，可以直接看到「生成器本来想放什么」。
--     注意它是 local 变量，必须改源码（不能用 console command）。
--   ⇒ 代价：可能产出「面积过小」「缺必需 prefab」「没有出生点」的坏地图。
--   ⚠ 但 :1013 有个例外分支仍会兜底写入 {x=0,y=0,z=0} 的出生点。
	    		if SKIP_GEN_CHECKS == false then
	    			return nil
	    		end
	   		end
	   	end
	end

-- 【TranslateWorldGenChoices】把玩家在世界生成界面上的「资源频率」设置
--   翻译成两张表：
--     translated_prefabs : prefab名 → 数量乘数（供散布时缩放）
--     runtime_overrides  : 运行时覆写（如季节/天气设置）
--   ★ 注意此时是【烘焙之后】才翻译 —— 乘数只能用于 :904-919 的事后裁剪，
--     无法影响已经铺好的地形。这是架构上的顺序约束，不是 bug。
--   详见 :267 的 TranslateWorldGenChoices 定义与 MULTIPLY(:86) 档位表。
    local translated_prefabs, runtime_overrides = TranslateWorldGenChoices(current_gen_params)

    print("Checking Tags")
-- 【obj_layout】房间家具布局模块：知道「某个房间该摆哪些家具」。
--   本文件后面所有 Place(...) 调用都通过 add_fn 回调把 prefab 塞进 entities。
--   参见 map/object_layout.lua。
	local obj_layout = require("map/object_layout")

-- ============================================================
-- 【add_fn】★ 贯穿 S4/S5 的「实体投放回调」
-- ============================================================
-- 【为什么需要回调而不是直接插表】
--   调用方（obj_layout.Place / Ocean_PlaceSetPieces）是 C++ 或别的模块，
--   它们不认识 entities 这个 Lua 表 ⇒ 用「Lua 函数交给它们回调」的
--   方式反转依赖。这是 Lua↔C++ 混合工程里的标准手法。
-- 【签名（前 6 个参数由 C++ 传入，后 4 个来自 :642 的 args）】
--   prefab/points_x/points_y/current_pos_idx : 投放目标
--   entitiesOut/width/height/prefab_list/prefab_data/rand_offset
	local add_fn = {fn=function(prefab, points_x, points_y, current_pos_idx, entitiesOut, width, height, prefab_list, prefab_data, rand_offset)
-- 【先占格再放实体】★ 顺序很重要，不能反。
--   ReserveTile 把该格标记为「已被预定」，后续散布阶段不会在它上面再放资源。
--   ⇒ 房间家具与野外资源不会重叠。
--   ⚠ 副作用：占掉的格子也不会被 :844 ReplaceSingleNonLandTiles 之类修正，
--     所以 ReserveTile 必须落在合法地形上（由 ValidateGroundTile :371 兜底）。
				WorldSim:ReserveTile(points_x[current_pos_idx], points_y[current_pos_idx])

-- 【坐标系转换：格 → 世界单位】
--   x = (格X - 宽度/2) * TILE_SCALE
--   ★ 减去一半宽度是因为 WorldSim 的格坐标【以左上角为原点且不居中】，
--     而游戏世界坐标【以地图中心为原点】。少了这半个 width 就会整体偏移。
--   ★ TILE_SCALE 是「格 → 世界单位」的比例常数（tiledefs.lua 定义）。
--   ⚠ 这套换算在本文件里重复出现十余次（:616/:659/:893/:1030…），
--     且 :659 用了 +1.5 而 :616 用 0 基 —— 见 :659 的原始注释，
--     那里明确写了「RunMaze points are in a strange position」，
--     说明【连原作者都没完全搞清 maze 点的偏移】，属已知遗留问题。
				local x = (points_x[current_pos_idx] - width/2.0)*TILE_SCALE
				local y = (points_y[current_pos_idx] - height/2.0)*TILE_SCALE
-- ★ 精度处理：截断到小数点后 2 位。
--   为什么不用四舍五入而用 math.floor：
--   截断保证「两个相邻格算出的坐标严格单调递增且不相等」；
--   四舍五入可能让相邻两格得到相同坐标，导致实体重叠。
--   ★ 代价是整体坐标系统性偏「向原点收缩」最多 0.01 世界单位，
--     这个误差远小于 1 格（TILE_SCALE 通常为 1），可忽略。
				x = math.floor(x*100)/100.0
				y = math.floor(y*100)/100.0
				if entitiesOut[prefab] == nil then
					entitiesOut[prefab] = {}
				end
-- 【save_data 的形状】{x, z} —— 注意存的是 z 不是 y。
--   ★ 原因：DST 的世界坐标是 (x, y, z) 三轴，z 是「南北/平面」轴，
--     y 是「高度/垂直」轴。2D 地图存 (x, z)，y 留给实体的实际海拔。
--     这与 3D 引擎的直觉相反，是自研引擎最常见的踩坑点。
				local save_data = {x=x, z=y}
				if prefab_data then

					if prefab_data.data then
						if type(prefab_data.data) == "function" then
							save_data["data"] = prefab_data.data()
						else
							save_data["data"] = prefab_data.data
						end
					end
					if prefab_data.id then
						save_data["id"] = prefab_data.id
					end
					if prefab_data.scenario then
						save_data["scenario"] = prefab_data.scenario
					end
				end
				table.insert(entitiesOut[prefab], save_data)
			end,
			args={entitiesOut=entities, width=map_width, height=map_height, rand_offset = false, debug_prefab_list=nil}
		}

-- ============================================================
-- 【S4】特殊标签后处理 · Labyrinth（迷宫树）
-- ============================================================
-- ★ GlobalTags 是「按标签聚合的节点集合」，由 storygen 阶段打上。
--   本段【不生成新的图结构】，只在已烘焙的地块上刻迷宫、摆宝藏。
    print("Tag: Labyrinth")
-- 【双重守卫】先判非 nil，再判 GetTableSize > 0。
--   GetTableSize 来自 util.lua，对非表参数安全返回 0。
--   ⇒ GlobalTags["Labyrinth"] 为 nil 时短路，不会进入循环。
   	if topology_save.GlobalTags["Labyrinth"] ~= nil and GetTableSize(topology_save.GlobalTags["Labyrinth"]) >0 then
   		for task, labyrinth_nodes in pairs(topology_save.GlobalTags["Labyrinth"]) do

-- 【迷宫随机种子】val = floor(random()*10 - 2.5) ⇒ 整数区间 [-3, 6]，共 10 种。
--   ★ 这个 val 直接决定迷宫的生长形态 ⇒ 它是【世界的又一个随机维度】。
--   ⚠ 副作用：因为区间含负数，而 MAZE_TYPE 是固定值，
--     实际只有 10 种迷宫布局可选 ⇒ 大规模换图时迷宫重复率不低。
--   ⇒ 对「同种子必须完全复现」的影响见文件头的随机数小节。
	   		local val = math.floor(math.random()*10.0-2.5)
	   		local mazetype = MAZE_TYPE.MAZE_GROWINGTREE_4WAY

-- 【RunMaze】在 labyrinth_nodes 指定的区域内生成迷宫。
--   参数：迷宫类型 / 种子val / 【墙的地块】IMPASSABLE / 【路的地块】BRICK。
--   ★ IMPASSABLE 作墙 ⇒ 这是「锁」的物理实现之一（另一种是 storygen 的 blocker_blank）。
--   返回三张平行表 xs / ys / types：
--     types[i] == 0     ⇒ 死胡同/角落 ⇒ 这类点放宝箱（:656）
--     types[i] ~= 0     ⇒ 通道格，值的绝对值编码方向（1/2/4/8 = 上右下左）
--   ⚠ types 用【位编码】而非索引，:717 的 1/2/4/8 判断即基于此。
	   		local xs, ys, types = WorldSim:RunMaze(mazetype, val, WORLD_TILES.IMPASSABLE, WORLD_TILES.BRICK, labyrinth_nodes)
	   		-- TODO: place items of interest in these locations
			if xs ~= nil and #xs >0 then
				for idx = 1,#xs do
			   		if types[idx] == 0 then
			   			--Spawning chests within the labyrinth.
						local prefab = "pandoraschest"
-- ⚠ 疑似缺陷（已由原作者承认）：坐标用了 +1.5 而非 +0.5。
--   原始注释："gjans: note the +1.5 instead of +0.5... RunMaze points are
--   in a strange position." —— 作者明确指出 RunMaze 返回的点位置【异常】，
--   于是手工加了半个格的偏移去凑。
--   ⇒ 这是【已知的、靠魔法数字掩盖的坐标 bug】。正确做法应是修 C++ 侧
--     RunMaze 的返回值约定，而不是在 Lua 端打补丁。
--   ★ :661 的 ReserveTile 被注释掉并附同样说明：
--     something wrong with the points returned by RunMaze."
--   ⇒ 后果：迷宫里的宝箱【没有占格】，可能被后续散布的资源覆盖。
						local x = (xs[idx]+1.5 - map_width/2.0)*TILE_SCALE --gjans: note the +1.5 instead of +0.5... RunMaze points are in a strange position.
						local y = (ys[idx]+1.5 - map_height/2.0)*TILE_SCALE
						--WorldSim:ReserveTile(xs[idx], ys[idx]) --gjans: This reseves the wrong tile, something wrong with the points returned by RunMaze.
						--print(task.." Labyrinth Point of Interest:",xs[idx], ys[idx], x, y)

						if entities[prefab] == nil then
							entities[prefab] = {}
						end
						local save_data = {x=x, z=y, scenario = "chest_labyrinth"}
						table.insert(entities[prefab], save_data)
					end
				end
			end
-- ============================================================
-- 【迷宫接回主陆】原注释："The maze can cut itself off from land at the
--   edge, so draw a little road to bring it together."
-- ============================================================
-- ★ 迷宫是在既有胞元里刻出来的，【可能整体悬空】——
--   这是 Voronoi 空间的固有现象（图上有边，空间上不相邻）。
--   手工补 BRICK 通道 ⇒ 保证迷宫可达。
--   ★ 这是【图连通性 ≠ 空间连通性】的典型修补点，全文件共出现 3 次
--     （:673 迷宫入口 / :683 迷宫出口 / :817 元迷宫入口）。
            -- The maze can cut itself off from land at the edge, so draw a little road to bring it together.
            for i,node in ipairs(topology_save.GlobalTags["LabyrinthEntrance"][task]) do
                local entrance_node = topology_save.root:GetNodeById(node)
                for id, edge in pairs(entrance_node.edges) do
                    if edge.node1.data.type ~= NODE_TYPE.Blank and edge.node2.data.type ~= NODE_TYPE.Blank then
                        WorldSim:DrawCellLine( edge.node1.id, edge.node2.id, NODE_INTERNAL_CONNECTION_TYPE.EdgeSite, WORLD_TILES.BRICK)
                    end
                end
            end

            -- And same story on all it's exits and non-maze internal nodes
            for i,node in ipairs(labyrinth_nodes) do
                local real_node = nodes[node]
                for id, edge in pairs(real_node.edges) do
                    if edge.node1.data.type ~= NODE_TYPE.Blank and edge.node2.data.type ~= NODE_TYPE.Blank
                        and table.contains(topology_save.GlobalTags["Labyrinth"][task], edge.node1.id) ~= table.contains(topology_save.GlobalTags["Labyrinth"][task], edge.node2.id) then
                        WorldSim:DrawCellLine( edge.node1.id, edge.node2.id, NODE_INTERNAL_CONNECTION_TYPE.EdgeSite, WORLD_TILES.BRICK)
                    end
                end
            end
        end
    end

-- ============================================================
-- 【S4 续】Maze（元迷宫 / meta-maze）—— 与 Labyrinth 的区别
-- ============================================================
-- ★ Labyrinth = 「在一片区域里长一棵迷宫树」（RunMaze 在 C++ 里生成）。
--   Maze      = 「按 meta-maze 的格子编码摆 prefab」（这里只是查询 + 布置）。
--   ⇒ Maze 的形状由 C++ 的 GetPointsForMetaMaze 决定，Lua 侧只负责填内容。
    print("Tag: Maze")
   	if topology_save.GlobalTags["Maze"] ~= nil and GetTableSize(topology_save.GlobalTags["Maze"]) >0 then

   		for task, nodes in pairs(topology_save.GlobalTags["Maze"]) do
-- 【maze_tile_size】默认 8：元迷宫每个逻辑格对应 8×8 个世界格。
--   ★ 这个默认值决定了【元迷宫的物理大小】。若 level 未指定就用 8。
			local maze_tile_size = topology_save.root:GetNodeById(task).maze_tile_size or 8
-- 【GetPointsForMetaMaze】返回迷宫格中心点 + 每格的方向编码（同 :652 的 types）。
	 		local xs, ys, types = WorldSim:GetPointsForMetaMaze(maze_tile_size, nodes)

			if xs ~= nil and #xs >0 then
				local choices = topology_save.root:GetNodeById(task).maze_tiles
-- 【以「入口质心」为参考原点】后续所有『离入口远近』的判断都基于它。
--   c_x/c_y 是入口地块的质心 ⇒ 迷宫中心 = 离入口最远的那个格子。
--   ★ 设计意图：让迷宫从入口「由内向外」展开，起点在核心、终点在外圈。
				local c_x, c_y = WorldSim:GetSiteCentroid(topology_save.GlobalTags["MazeEntrance"][task][1])
				local centroid = Vector3(c_x, c_y, 0)

-- 【距离排序】对每个迷宫格算到入口质心的平方距离并升序排。
--   ★ 用 LengthSq()（平方距离）而非 :Length()：省掉 sqrt，
--     在数百个格子的规模上是无意义的微优化，但不影响排序结果。
--   ⚠ table.sort 不稳定：距离相同的格子相对次序取决于初始顺序，
--     而初始顺序来自 C++ 返回的 xs/ys ⇒ 理论上可影响 :722/:727 的随机取值。
				local distances = {}
				for idx = 1,#xs do
					table.insert(distances, {idx=idx, dist=(centroid - Vector3(xs[idx], ys[idx], 0)):LengthSq()})
				end
				table.sort(distances, function(a,b) return a.dist < b.dist end)

-- 【三分支之一：Archive（档案室）布局】
--   有 choices.archive ⇒ 走「随机选 2 个不同出口当起点/终点 + 留一个密室」的完整流程。
--   三个分支由 :713 / :782 / :805 判别，依据是 level 的 maze_tiles 配置。
				if choices.archive ~= nil then
					local ends = {}
					for _,d in ipairs(distances) do
						local maze_room = math.abs(types[d.idx])
						if maze_room == 1 or maze_room == 2 or maze_room == 4 or maze_room == 8 then
							table.insert(ends, d.idx)
						end
					end

-- ★ 此处 math.random(1,#ends) 选起点与 :727 选终点。
--   ⚠ 疑似缺陷（低危）：:723 取走一个后 :724 用 table.remove(ends, choice)
--     从【中间】删除 ⇒ 剩下数组的顺序被打乱，但 ends 的元素本身仍是索引值，
--     所以后续 table.insert 收集新元素仍正确。语义正确，只是顺序被扰动。
--   ⇒ 真正的隐患是 :733 的 while 重抽：若 #xs <= 2 会【死循环】（见 :731 守卫，
--     故实际安全）。守卫存在，此处无缺陷，仅记录依赖关系。
					local choice = math.random(1,#ends)
					local endidx = ends[choice]
					table.remove(ends,choice)
					obj_layout.Place({xs[endidx], ys[endidx]}, MAZE_CELL_EXITS_INV[math.abs(types[endidx])], add_fn, choices.special.finish)

					choice = math.random(1,#ends)
					local startidx = ends[choice]
					obj_layout.Place({xs[startidx], ys[startidx]}, MAZE_CELL_EXITS_INV[math.abs(types[startidx])], add_fn, choices.special.start)

                    if #xs > 2 then
                        local reservedindex = math.random(1,#xs)
                        while reservedindex == endidx or reservedindex == startidx do
                            reservedindex = math.random(1,#xs)
                        end
    
                        for idx = 1,#xs do
                            if idx ~= reservedindex and idx ~= endidx and idx ~= startidx then
                                if types[idx] > 0 then
                                    obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[types[idx] ], add_fn, choices.rooms)
                                else
                                    obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[-types[idx] ], add_fn, choices.bosses)
                                end
                            end
                        end
-- 【密室 keyroom】在第三个（随机且不同于起点/终点的）格子里放钥匙房。
--   ★ 这是「锁—钥匙」在世界侧的物理落点：
--     图侧由 map/lockandkey.lua 定义（见该文件 :219/:254 的 TREES 缺陷），
--     空间侧由这里的 keyroom 提供钥匙实体。两侧任一失配 ⇒ 玩家不可达。
--   ★★ 这正是 bug-patterns.md E1「锁—钥匙同名覆盖致不可达」的完整链路。
                        if choices.archive.keyroom then
                            obj_layout.Place({xs[reservedindex], ys[reservedindex]}, "SINGLE_NORTH", add_fn, choices.archive.keyroom)
                        end
    
-- 【从迷宫核心画三条对角线】DrawGroundLine(..., DIRT, true, true)。
--   后两个 true 应为「起点终点都写/不写半格」之类的布尔开关（C++ 侧约定）。
--   ★ 画的是 DIRT（土路）而不是 BRICK ⇒ 迷宫中心被刻意做成一个『空地广场』。
--   玩法上：这里是玩家会合点，也是档案室封印的位置（:758 起）。
                        local closest_index = distances[1].idx
                        local x, y = xs[closest_index], ys[closest_index]
                        local s_x, s_y = WorldSim:GetSite(topology_save.GlobalTags["MazeEntrance"][task][1])
    
                        WorldSim:DrawGroundLine( x, y, s_x, s_y, WORLD_TILES.DIRT, true, true)
                        WorldSim:DrawGroundLine( x+2, y+2, x-2, y-2, WORLD_TILES.DIRT, true, true)
                        WorldSim:DrawGroundLine( x-2, y+2, x+2, y-2, WORLD_TILES.DIRT, true, true)
    
-- 【ARCHIVE SEALS】在迷宫核心与入口连线的中点堆碎石，封住档案室。
--   rubble1 / rubble2 各插一个 ⇒ 两层碎石，需要玩家二次清理。
--   ★ 这就是 meta-maze 的「锁」：纯实体实现，不依赖 lockandkey 的图约束。
--   ⚠ 坐标 incx/incz 除以 2（:761-762）取中点，而 :777 又 `incx/2`（源码注释 -- /10
--     表明这里曾把除数从 10 改成 2）⇒ 两处除数不同但都想要中点，
--     :777 的写法使最终落点偏靠近迷宫中心。属遗留魔法数字，不影响可达性。
                         -- ARCHIVE SEALS
                        local x_diff = s_x - x
                        local y_diff = s_y - y
                        local incx = (x_diff/2) *TILE_SCALE
                        local incz = (y_diff/2) *TILE_SCALE
    
                        local newx = x
                        local newz = y
    
                        newx = (newx - map_width/2.0)*TILE_SCALE --gjans: note the +1.5 instead of +0.5... RunMaze points are in a strange position.
                        newz = (newz - map_height/2.0)*TILE_SCALE
    
                        if not entities["rubble1"] then
                            entities["rubble1"] = {}
                        end
                        if not entities["rubble2"] then
                            entities["rubble2"] = {}
                        end
    
                        newx = newx + incx/2 -- /10
                        newz = newz + incz/2 -- /10
                        table.insert(entities["rubble1"],{ x = newx, z = newz })
                        table.insert(entities["rubble2"],{ x = newx, z = newz })
                    end
				elseif choices.special ~= nil then
					local ends = {}
					for _,d in ipairs(distances) do
						local maze_room = math.abs(types[d.idx])
						if maze_room == 1 or maze_room == 2 or maze_room == 4 or maze_room == 8 then
							table.insert(ends, d.idx)
						end
					end

					for idx = 1,#xs do
						if idx == ends[1] or idx == ends[#ends] then
							-- skip
						elseif types[idx] > 0 then
							obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[types[idx] ], add_fn, choices.rooms)
						else
							obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[-types[idx] ], add_fn, choices.bosses)
						end
					end

					local idx = ends[1]
					obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[math.abs(types[idx])], add_fn, choices.special.start)
					idx = ends[#ends]
					obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[math.abs(types[idx])], add_fn, choices.special.finish)
				else
					types[distances[1].idx] = MAZE_CELL_EXITS.FOUR_WAY
					for idx = 1,#xs do
						if types[idx] > 0 then
							obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[types[idx] ], add_fn, choices.rooms)
						else
							obj_layout.Place({xs[idx], ys[idx]}, MAZE_CELL_EXITS_INV[-types[idx] ], add_fn, choices.bosses)
						end
					end
				end

                -- The maze can cut itself off from land at the edge, so draw a little road to attempt to bring it together.
                for i,node in ipairs(topology_save.GlobalTags["MazeEntrance"][task]) do
                    local entrance_node = topology_save.root:GetNodeById(node)
                    for id, edge in pairs(entrance_node.edges) do
                        if edge.node1.data.type ~= NODE_TYPE.Blank and edge.node2.data.type ~= NODE_TYPE.Blank then
                            WorldSim:DrawCellLine( edge.node1.id, edge.node2.id, NODE_INTERNAL_CONNECTION_TYPE.EdgeSite, choices.bridge_ground or WORLD_TILES.BRICK, nil, true)

                            -- If the maze is force disconnected then double make sure that the maze is connected with the fake ground
                            local othernode = edge.node1 == entrance_node and edge.node2 or edge.node1
                            if table.contains(othernode.data.tags, "ForceDisconnected") then
								for id, edge in pairs(othernode.edges) do
									if edge.node1.data.type ~= NODE_TYPE.Blank and edge.node2.data.type ~= NODE_TYPE.Blank then
										WorldSim:DrawCellLine( edge.node1.id, edge.node2.id, NODE_INTERNAL_CONNECTION_TYPE.EdgeSite, WORLD_TILES.FAKE_GROUND, nil, true)
									end
								end
                            end
                        end
                    end
                end

			end
		end
    end

-- ============================================================
-- 【S5】散布（Populate）：★ 耗时 1-3 s 的第二大块
-- ============================================================
    print("Populating voronoi...")

-- 【GlobalPrePopulate】给【所有】节点一个统一的「生成前」钩子。
--   ★ 与 :889 的 GlobalPostPopulate 成对，构成全图级的前后处理夹。
--   节点级还有 SaveEncode/SetTilesViaFunction/PopulateVoronoi 等，
--   详见 network.lua 的 root 节点实现。
	topology_save.root:GlobalPrePopulate(entities, map_width, map_height)
-- 【ConvertGround】★★ 把 Voronoi 胞元翻译成【实际地表】的关键一步。
--   SpawnFunctions 三个回调（:386-390）就是本文件的「AI」：
--     pickspawnprefab                  —— 按权重抽一个 prefab
--     pickspawngroup                   —— 按 percent 抽一个组
--     pickspawncountprefabforground    —— 按地块类型抽一个候选
--   ★ 它们全在【Lua 侧】，通过 C++ 回调被调用 ⇒ 这就是 Lua 参与散布的方式。
--   密度表 save.map.generated.densities 由本行第三个返回值填充。
    topology_save.root:ConvertGround(SpawnFunctions, entities, map_width, map_height)
	WorldSim:ReplaceSingleNonLandTiles()

-- ============================================================
-- 【★ 原始 NOTE（E5 缺陷的权威出处，逐字保留）】
-- ============================================================
--   Sigh, so the "ForceDisconnected" tag does not actually keep something
--   in the void disconnected from the mainland (e.g. Atrium)
--   It instead relies on this FAKE_GROUND tile to connect it to the main
--   land during world generation, that is then cleaned up afterwards....
--
--   Now you can set SafeFromDisconnect on room or static layouts to
--   exclude their tiles from being disconnected!
-- ============================================================
-- ★★ 【逐句解读】这是全文件最有价值的一段自白：
--   1) "Sigh" —— 作者自己叹了口气，说明这是【明知有缺陷的权宜之计】。
--   2) 机制：虚空区域（如 Atrium）靠 FAKE_GROUND 临时地块【临时连上主陆】，
--      生成结束后才把 FAKE_GROUND 清理掉 ⇒ 制造出「悬空但可达」的幻象。
--   3) ★★ 缺陷：若后续的清理（:855 DetectDisconnect）漏掉某块，
--      玩家就能走进【设计上应该是虚空】的地方并掉下去 —— 即 E5。
--   4) 补丁：SafeFromDisconnect 标记（:565 在此处登记）可豁免清理。
--   ⇒ 见 bug-patterns.md E5「临时连通地块没被清理 → 玩家走进虚空」。
	--[[
	NOTE:
	Sigh, so the "ForceDisconnected" tag does not actually keep something in the void disconnected from the mainland (e.g. Atrium)
	It instead relies on this FAKE_GROUND tile to connect it to the main land during world generation, that is then cleaned up afterwards....

	Now you can set SafeFromDisconnect on room or static layouts to exclude their tiles from being disconnected!
	]]
-- 【断开检测的总闸】keep_disconnected_tiles 为真时【完全不检测】。
--   该开关由关卡 overrides 透传（:435-437）。
--   ⚠ 打开它就等于放弃 E5 的兜底 —— 可能产出有「设计外虚空」的地图。
	if not story_gen_params.keep_disconnected_tiles then
        print("DetectDisconnect")
-- 【DetectDisconnect】★ 洪水填充：从主陆出发标记所有可达格，
--   未被标记的格即为「悬空」⇒ 把它们的 FAKE_GROUND 替换掉。
--   这就是 :849 注释里说的 "cleaned up afterwards" 的实体动作。
--   ⚠ O(W×H) 全图扫描 ⇒ 425² ≈ 18 万格，是 0.3-1 s 预算的主要来源。
--   ⚠ 根因未解：清理靠【事后检测】而非【生成时不连通】，
--     任何一次 DetachConnectivity 的疏漏都会变成玩家的虚空陷阱。
--     ⇒ 结构性缺陷，非参数调优可解。
	    local replace_count = WorldSim:DetectDisconnect()
		--allow at most 5% of tiles to be disconnected
-- 【容差 5%】map_width * map_height * 0.05。
--   ★ 为什么要容差而不是 0：孤岛/洞穴的连通性本来就有天然断点，
--     强行要求 100% 连通会导致几乎每次生成都失败 ⇒ 重试 5 次后放弃。
--   ⚠ 但 5% 的绝对值随地图尺寸变化：tiny(1) 的世界容差仅 0 格（极严），
--     huge(450) 的世界容差高达 10125 格（极松）⇒
--     ★ 严格程度与地图大小【反相关】，小地图反而更容易因断连而失败。
--     这是一个隐性的规模相关缺陷，值得在自研生成器里改成绝对值或比例+下限。
		if replace_count > math.floor(map_width * map_height * 0.05) then
			print("PANIC: Too many disconnected tiles...",replace_count)
			if SKIP_GEN_CHECKS == false then
				return nil
			end
		else
			print("disconnected tiles...",replace_count)
		end
	else
		print("Not checking for disconnected tiles.")
	end
-- 【ClearSafeFromDisconnect】★ 检测结束，立刻清掉保护旗。
--   ★ 必须清：否则下一轮散布会把上一轮的豁免名单也带上，越积越多。
--   ⇒ 这是「标记—使用—清除」的三段式生命周期，:565 埋、:853 用、:868 清。
    WorldSim:ClearSafeFromDisconnect()

    save.map.generated = {}
    save.map.generated.densities = {}

-- 【PopulateVoronoi】★★ 撒资源的主循环，1-3 s 预算的主体。
--   参数依次：三个 spawn 回调 / entities 出口 / 地图尺寸 /
--              乘数表 translated_prefabs / 密度输出 densities。
--   ★ 逐胞元遍历，每个胞元按其 biome 与 density 抽 prefab 落地。
--   ★ 生物群系（biome）在这里生效：地形(terrain.lua)决定『这里是什么地』，
--     资源表(:168 TRANSLATE_TO_PREFABS)决定『这种地上长什么』。
--   ⚠ 若某个胞元【一个格子都没有】（退化胞元），其资源无处落地，
--     而 :572 那行坏掉的日志正是在报告这种情况 —— 两处 bug 互为因果。
    topology_save.root:PopulateVoronoi(SpawnFunctions, entities, map_width, map_height, translated_prefabs, save.map.generated.densities)
-- 【海洋分支】仅当 story_gen_params.has_ocean 为真时执行（:443 透传）。
--   ★ 海洋是【独立于 Voronoi 的第二套空间系统】（ocean_gen.lua），
--     与陆地区域通过 Wormhole（虫洞）相连。
--   ⚠ 耗时 1-4 s，仅海洋世界额外付出。
	if story_gen_params.has_ocean then
		local ocean_gen_config = require("map/ocean_gen_config")
		Ocean_SetWorldForOceanGen(WorldSim)
		Ocean_PlaceSetPieces(level.ocean_prefill_setpieces, add_fn, obj_layout, WORLD_TILES.IMPASSABLE, ocean_gen_config.ocean_prefill_setpieces_min_land_dist, save.map.topology, map_width, map_height)
--		local required_treasure_placed = WorldGenPlaceTreasures(topology_save.root:GetChildren(), entities, map_width, map_height, 4600000, level)
--		if not required_treasure_placed then
--			print("PANIC: Missing required treasure!")
--			if SKIP_GEN_CHECKS == false then
--				return nil
--			end
--		end
-- 【Ocean_ConvertImpassibleToWater】海洋区域里不可通行的地块改判为水。
--   ★ 顺序要求：必须【先】铺 Ocean_PlaceSetPieces 再【后】改判，
--     否则连海面也会被当成陆地铺满场景件。
		Ocean_ConvertImpassibleToWater(map_width, map_height, ocean_gen_config)
-- 【PopulateOcean】海洋资源散布，与陆地 PopulateVoronoi(:873) 对称。
--   注意它拿的是 storygen.ocean_population（storygen 阶段算好的），
--   而不是像陆地那样现算 ⇒ 海洋的「放什么」在 S1 就定死了。
		PopulateOcean(SpawnFunctions, entities, map_width, map_height, storygen.ocean_population, translated_prefabs, ocean_gen_config.ocean_prefill_setpieces_min_land_dist, save.map.topology)
        MonkeyIsland_GenerateDocks(WorldSim, entities, map_width, map_height)
	end
-- 【GlobalPostPopulate】与 :842 的 Pre 成对，全图级后处理钩子。
--   ★ 这是【最后】一次能改 entities 的全图级时机；
--     之后 :891 起就是逐实物的清理与裁剪。
    topology_save.root:GlobalPostPopulate(entities, map_width, map_height)

-- ============================================================
-- 【实体清洗】删掉落在不可通行地块上的实体
-- ============================================================
-- ★ 为什么需要：散布阶段是【按密度撒】的，不知道具体格子的地形，
--   所以难免把东西撒到水里/墙里。
--   ⚠ 逆向遍历（i = #ents → 1）是必须的：table.remove 会让后面的元素前移，
--     正向遍历会漏删。【这是本文件唯一需要小心索引的地方】。
    for k,ents in pairs(entities) do
        for i=#ents, 1, -1 do
            local x = ents[i].x/TILE_SCALE + map_width/2.0
            local y = ents[i].z/TILE_SCALE + map_height/2.0

-- ⚠ 疑似缺陷（原作者已自曝）：原始注释
--   "Warning: This does not quite work as expected. It thinks the ground
--    type id is in rendering order, which it totally is not!"
--
--   【推理依据】GetVisualTileAtPosition 返回的是【渲染层】的地块 ID，
--     而 TileGroupManager:IsImpassableTile 判定的是【逻辑层】的通行性。
--     两者编号空间不同 ⇒ 拿渲染 ID 去查逻辑属性，【结果不可信】。
--   【后果】实体清理可能【误删合法实体】或【漏删非法实体】。
--   ★ 正确做法应是查逻辑层 API（如 WorldSim:GetTileAtPosition）。
--   ⚠ 这是本文件第二处「作者明确知道不对、但没有修」的地方
--     （第一处是 :659/:661 的 +1.5 与被注释掉的 ReserveTile）。
            local tiletype = WorldSim:GetVisualTileAtPosition(x,y) -- Warning: This does not quite work as expected. It thinks the ground type id is in rendering order, which it totally is not!
            if TileGroupManager:IsImpassableTile(tiletype) then
				print("Removing entity on IMPASSABLE", k, x, y, ""..ents[i].x..", 0, "..ents[i].z)
                table.remove(entities[k], i)
            end
        end
    end

-- ============================================================
-- 【乘数裁剪】按玩家设置砍掉多余的 prefab
-- ============================================================
-- ★ 与 :873 的乘数用法不同：
--   :873 把 mult 传给 C++ 影响散布密度（生成时就少放），
--   :904-919 是【事后】物理删除（已经放完了才砍）。
--   ⇒ 只有 mult < 1 会走到这里；mult >= 1 的设置在 :873 就已生效。
    if translated_prefabs ~= nil then
        -- Filter out any etities over our overrides
        for prefab,mult in pairs(translated_prefabs) do
-- 【type(mult) == "number" 的必要性】
--   ★ translated_prefabs 的值有两种形态（见 :303 与 :283）：
--     number —— 普通乘数
--     table  —— clump 形态 {clumpcount=, clumpsize=}（成簇散布）
--   ⇒ 必须先判 type，否则对 table 做 mult < 1 会抛「attempt to compare table」。
--     这个守卫是必需的，不是冗余。
            if type(mult) == "number" and mult < 1 and entities[prefab] ~= nil and #entities[prefab] > 0 then
                local new_amt = math.floor(#entities[prefab]*mult)
                if new_amt == 0 then
-- 【剪到 0 就整类删掉】entities[prefab] = nil
--   ★ 语义：玩家选了 "never" ⇒ 这个 prefab 不应出现在地图上。
--     置 nil 而非留空表 ⇒ 后面 :964 的必需 prefab 检查会正确地认为它「不存在」。
--   ⇒ 两处判定靠同一个 nil 约定耦合，改一处必须改另一处。
                    entities[prefab] = nil
                else
-- 【shuffleArray 后从头删】★ 保证「随机保留哪些」而非「保留前几个」。
--   ★ 若不洗牌直接从头删（table.remove(...,1)），留下的永远是
--     数组前端的同类实体 ⇒ 会造成【空间聚集】。
--   ⚠ 性能：table.remove(数组, 1) 是 O(n)，整体 O(n²)。
--     对数百个元素的单个 prefab 可接受；若 prefab 数量上万则需改为标记删除。
--   ⚠ shuffleArray 消耗随机数 ⇒ 又一个影响可复现性的随机源。
                    entities[prefab] = shuffleArray(entities[prefab])
                    while #entities[prefab] > new_amt do
                        table.remove(entities[prefab], 1)
                    end
                end
            end
        end
    end

-- ============================================================
-- 【成簇修正】Bunch*：把某些 prefab 聚成堆（草丛、灌木等）
-- ============================================================
-- ★ BunchSpawnerInit/Run 在【所有裁剪之后】执行，
--   所以簇的生成不受 mult 裁剪影响 ⇒ 簇的数量也不受玩家设置控制。
--   ⚠ 若某 prefab 已被 :910 置 nil，簇生成仍可能重新创建它 ——
--     两者没有统一的「禁用清单」。潜在不一致点。
--   参见 map/bunch_spawner.lua 与 bunches.lua。
  	BunchSpawnerInit(entities, map_width, map_height)
	BunchSpawnerRun(WorldSim)

-- 【AncientArchivePass】古档案相关实体的世界生成后处理。
--   单独一个模块（map/archive_worldgen.lua，:13 require）。
	AncientArchivePass(entities, map_width, map_height, WorldSim)

-- ============================================================
-- 【校验 #2】必需 prefab（required_prefabs）数量核对
-- ============================================================
-- ★ 这是【最重要的一道校验】：它保证关卡设计的核心内容真的放下了。
--   与 :596 的面积校验不同，这道校验直接对应玩家的任务可达性。
--   若失败 ⇒ return nil ⇒ 重试 ⇒ 最多 5 次后放弃生成。
    local double_check = {}
-- 【三个来源累加】同一个 prefab 被多个来源要求时，数量【相加】。
--   来源 1 :927 level.required_prefabs      —— 关卡声明的硬性要求
--   来源 2 :936 图节点的 GetRequiredPrefabs() —— 房间/节点引入的要求
--   来源 3 :945 海洋房间的 required_prefabs  —— 海洋关卡的要求
--   ★ 用 double_check 累加而非覆盖 ⇒ 要求是【可叠加】的。
    for i, prefab in ipairs(level.required_prefabs or {}) do
-- ★ 关键守卫：translated_prefabs[prefab] ~= 0 才计入。
--   mult == 0 来自 MULTIPLY["never"]（:87）⇒ 玩家明确关了这类资源。
--   ⇒ 语义：「玩家主动关掉的东西，不算缺失」。这是合理的优先级设计。
--   ⚠ 但 :965 又用 level.overrides[prefab] == "never" 单独判断失败原因，
--     两处用的是【不同的表】（translated_prefabs vs overrides）却表达同一意图。
--     若将来 translate 规则变化，两处可能给出不同判定 —— 一致性隐患。
		if not translated_prefabs or translated_prefabs[prefab] ~= 0 then
			if double_check[prefab] == nil then
				double_check[prefab] = 1
			else
				double_check[prefab] = double_check[prefab] + 1
			end
		end
    end
    for prefab, count in pairs(topology_save.root:GetRequiredPrefabs()) do
		if not translated_prefabs or translated_prefabs[prefab] ~= 0 then
			if double_check[prefab] == nil then
				double_check[prefab] = count
			else
				double_check[prefab] = double_check[prefab] + count
			end
		end
    end
    if storygen.ocean_population ~= nil then
        for _, ocean_room in pairs(storygen.ocean_population) do
            if ocean_room.data ~= nil and ocean_room.data.required_prefabs ~= nil then
                for _, prefab in ipairs(ocean_room.data.required_prefabs) do
					if not translated_prefabs or translated_prefabs[prefab] ~= 0 then
						if double_check[prefab] == nil then
							double_check[prefab] = 1
						else
							double_check[prefab] = double_check[prefab] + 1
						end
					end
                end
            end
        end
    end

-- 【逐个核对并打印】打印格式含期望值与实际值，
--   是排查「为什么生成失败」的第一手日志。
--   ★ 这也是 SKIP_GEN_CHECKS=false 时唯一能看到的失败原因。
    for prefab,count in pairs(double_check) do
		print ("Checking Required Prefab " .. prefab .. " has at least " .. count .. " instances (" .. (entities[prefab] ~= nil and #entities[prefab] or 0) .. " found).")
		
        if entities[prefab] == nil or #entities[prefab] < count then
-- ★ 失败分诊：区分「玩家关掉了」与「真的没放出来」。
--   前者只打印提示、不失败 —— 因为那是玩家的选择，不是生成器的错。
--   ⚠ 注意这里查的是 level.overrides[prefab] == "never"（字符串精确匹配），
--     而 :928 查的是 translated_prefabs[prefab] ~= 0（数值 0）。
--     两条路径的判定条件不完全等价，见 :928 的告警。
			if level.overrides[prefab] == "never" then
				print(string.format(" - missing required prefab [%s] was disabled in the world generation options!", prefab))
			else
				print(string.format("PANIC: missing required prefab [%s]! Expected %d, got %d", prefab, count, entities[prefab] == nil and 0 or #entities[prefab]))
				if SKIP_GEN_CHECKS == false then
					return nil
				end
			end
        end
    end

-- 【save.ents 定稿】此后 entities 不再变化，可以序列化了。
    save.ents = entities

-- ============================================================
-- 【S6 收尾】地图编码与序列化
-- ============================================================
-- 【GetEncodedMap 一次性产出 5 张表】★ 本文件最重的单行：
--   tiles         地块类型栅格（字符串，每格 1 字符）
--   tiledata       每格的附加数据（亮度/湿度等）
--   nav            寻路栅格
--   adj            邻接信息
--   nodeidtilemap  节点归属栅格（:588 已生成过一份，这里应是最终版）
--   ⚠ 耗时 0.3-1 s，体积与地图面积成正比（425² ≈ 18 万格）。
-- ★ join_islands 决定是否把孤岛一并编码进来。
    save.map.tiles, save.map.tiledata, save.map.nav, save.map.adj, save.map.nodeidtilemap = WorldSim:GetEncodedMap(join_islands)
	save.map.world_tile_map = GetWorldTileMap()

-- 【overrides 原样存档】deepcopy 后存进拓扑。
--   ★ 为什么必须深拷贝：current_gen_params 仍被 :986 之后的代码使用，
--     浅拷贝会让存档数据与运行时数据共享子表 ⇒ 后续任何修改都会污染存档。
--   运行时读档后即可复原玩家的世界生成设置。
    save.map.topology.overrides = deepcopy(current_gen_params)
    if save.map.topology.overrides == nil then
        save.map.topology.overrides = {}
	end

	save.map.width, save.map.height = map_width, map_height

-- ============================================================
-- 【季节初始化】决定新世界从哪个季节开始
-- ============================================================
-- ★ 三种写法：
--   "秋|冬|春"  —— 竖线分隔 ⇒ 随机挑一个（:990）
--   "default"   —— 落到 DEFAULT_SEASON（:991-992）
--   nil/其他     —— 直接按字面值查 SEASONS
--   ⚠ :989 用 string.find(start_season, "|", nil, true) 的第 4 参 true
--     表示【纯文本查找】（不当作正则）—— 这是正确写法，避免了竖线被当元字符。
--   ★ GetRandomItem 又消耗随机数 ⇒ 季节也是可复现性的一环。
	local start_season = current_gen_params.season_start or "autumn"
	if string.find(start_season, "|", nil, true) then
		start_season = GetRandomItem(string.split(start_season, "|"))
	elseif start_season == "default" then
		start_season = DEFAULT_SEASON
	end

-- 【seasonfn 闭包】SEASONS 表里存的是【函数】（:341-346）。
--   调用 SEASONS[start_season](start_season) 得到 componentdata。
--   ★ 温柔/严酷季两套长度（friendly=true → 乘 2 作为总长）。
--   winter 额外返回 weather.snowlevel = 1 ⇒ 开局就是大雪。
--   ⚠ 若 start_season 是 SEASONS 里没有的值 ⇒ 下标为 nil ⇒ 调用即崩。
--     :988-993 的三种分支都未校验「值是否在 SEASONS 中」⇒ 隐患。
	local componentdata = SEASONS[start_season](start_season)

	if save.world_network == nil then
		save.world_network = {persistdata = {}}
	elseif save.world_network.persistdata == nil then
		save.world_network.persistdata = {}
	end

-- 【写入 persistdata】存档里的持久化数据（季节/天气进度）。
--   ★ 这一段只影响「新存档的初始季节」，
--     读档后由 world_network.persistdata 接管季节推进。
	for k, v in pairs(componentdata) do
		save.world_network.persistdata[k] = v
	end

-- ============================================================
-- 【校验 #3】出生点存在性 —— ★ 最后一道、也是最致命的一道校验
-- ============================================================
-- ★ 判定「四类传送/出生 prefab 全都为空」才失败：
--   spawnpoint_multiplayer  —— 多人出生点
--   multiplayer_portal      —— 传送门
--   quagmire_portal / lavaarena_portal —— 两个特殊世界
--   ⇒ 这四类是互斥的世界类型，普通世界放前者、特殊世界放后者。
--   ★ 放到最后校验的原因：前面所有校验都在管『地图质量』，
--     只有这一条管『玩家能不能开始游戏』—— 它是唯一不可协商的。
	if (save.ents.spawnpoint_multiplayer == nil or #save.ents.spawnpoint_multiplayer == 0)
        and (save.ents.multiplayer_portal == nil or #save.ents.multiplayer_portal == 0)
        and (save.ents.quagmire_portal == nil or #save.ents.quagmire_portal == 0)
        and (save.ents.lavaarena_portal == nil or #save.ents.lavaarena_portal == 0) then
    	print("PANIC: No start location!")
-- 【失败即 return nil】⇒ 触发 worldgen_main.lua:421 的重试循环。
--   ★ 结合 :435 的 keep_disconnected_tiles 等参数，
--     「总是生成不出出生点」往往是【世界设置组合本身有问题】，
--     重试 5 次也不会变好 ⇒ 只会让玩家白等 5× 的生成时间。
--   ⚠ 这暴露了重试机制的根本缺陷：【重试不改变确定性输入】。
--     唯一变化的是 RNG 状态 ⇒ 实际是在 5 个随机世界里赌一次成功。
--   ⇒ 这是 E4 可复现性问题与 E3 性能问题的【交汇点】：
--     既可能白等 50 s，也仍可能 5 次全失败。
    	if SKIP_GEN_CHECKS == false then
    		return nil
    	else
-- 【SKIP_GEN_CHECKS=true 时的兜底】硬塞一个原点出生点。
--   ★ 这是唯一一处 return nil 的【降级分支】而非放弃分支。
--     写法上更务实：既然校验都放行了，至少让游戏能跑起来。
--   ⚠ 但 {x=0,y=0,z=0} 可能落在水里/不可通行处 ⇒ 玩家可能卡死。
--     仅在调试模式下可接受。
    		save.ents.spawnpoint={{x=0,y=0,z=0}}
    	end
    end

    save.map.roads = {}

    if current_gen_params.roads == nil or current_gen_params.roads ~= "never" then
-- ============================================================
-- 【S6 尾】道路序列化
-- ============================================================
-- ★ GetRoad 与 :557 的 DrawRoads 是同一份道路的【两阶段】：
--   :557 DrawRoads     —— 生成期把路【画进 tilemap】（影响地形外观）
--   :1022 GetRoad      —— 存档期把路的【坐标序列】取出（供寻路/小地图）
--   ⇒ 两处都要，且必须 join_islands 一致，否则存档里的路与地图上的路不匹配。
--   参见 :539 的注释：该功能与孤岛技术冲突被整段关闭（if false）。
        local num_roads, road_weight, points_x, points_y = WorldSim:GetRoad(0, join_islands)
        local current_road = 1
-- 【最短道路长度 3-5】不足则丢弃这条道路。
--   ★ 理由：太短的道路没有导航价值，只会在地图上留下难看的短线段。
--   ⚠ 消耗随机数 ⇒ 又一个影响可复现性的随机源。
--   ★ 注意 :1027 判断用的是 #points_x（格数），而 :1022 返回的可能是【采样点】数，
--     两者单位是否一致需看 C++ 实现 —— 属跨语言契约，原版未加断言。
        local min_road_length = math.random(3,5)
        --print("Building roads... Min Length:"..min_road_length, current_gen_params.roads)

        if #points_x>=min_road_length then
            save.map.roads[current_road] = {3}
            for current_pos_idx = 1, #points_x  do
-- 【道路坐标精度：截断到 1 位小数】比 add_fn(:618) 的 2 位更粗。
--   ★ 道路点数可达数百上千，用 1 位小数是为了压缩存档体积。
--   ⚠ 精度不统一（实体 2 位 / 道路 1 位）容易在对比调试时造成困惑。
--   ⚠ 截断而非四舍五入 ⇒ 道路整体向原点收缩最多 0.1 单位；
--     TILE_SCALE 通常为 1 ⇒ 远小于一格，可接受。
--   ★ 与 :618 的处理方式一致（都用 math.floor 保住单调性），思路是对的。
                local x = math.floor((points_x[current_pos_idx] - map_width/2.0)*TILE_SCALE*10)/10.0
                local y = math.floor((points_y[current_pos_idx] - map_height/2.0)*TILE_SCALE*10)/10.0

                table.insert(save.map.roads[current_road], {x, y})
            end
            current_road = current_road + 1
        end

-- 【补齐剩余道路】从 current_road 循环到 num_roads。
--   ⚠ 疑似缺陷（低危·可确证）：循环变量名 current_road 与外层的局部变量【同名】。
--     Lua 的 for 循环变量会遮蔽外层变量，循环结束后外层的 current_road
--     停留在 num_roads+1 处的外层值（本例中最后一次 GetRoad 已把编号推进）。
--     ★ 实际行为正确（循环内用局部副本、外层 current_road 未被破坏），
--       但同名遮蔽是极易引发后续维护 bug 的写法，属【代码异味】。
--   ⚠ 不影响正确性，仅记录为可读性/可维护性问题。
        for current_road = current_road, num_roads  do

            num_roads, road_weight, points_x, points_y = WorldSim:GetRoad(current_road-1, join_islands)

            if #points_x>=min_road_length then
                save.map.roads[current_road] = {road_weight}
                for current_pos_idx = 1, #points_x  do
                    local x = math.floor((points_x[current_pos_idx] - map_width/2.0)*TILE_SCALE*10)/10.0
                    local y = math.floor((points_y[current_pos_idx] - map_height/2.0)*TILE_SCALE*10)/10.0

                    table.insert(save.map.roads[current_road], {x, y})
                end
            end
        end
    end

-- 【成功出口】打印最终确认文案。
--   ★ 至此 Generate 返回 save 表，由 worldgen_main.lua:422 接收。
--   ⚠ 但注意：返回的 save 里【不含种子】——
--     种子只存在于 RNG 内部状态，存档无法据此复现地图。
--     ⇒ 这是 E4「同种子无法复现」在【存档层】的体现：
--       即使玩家记住了当时用的种子，也没有渠道把它与这张地图关联起来。
	print("Done "..prefab.." map gen!")

	return save
end

-- ============================================================
-- 【模块导出】★ 全部导出都是【配置表】，只有 Generate 是函数
-- ============================================================
-- ★ 导出的配置表供【外部世界（ocean_gen / monkeyisland / cave_gen 等）】
--   复用同一套资源倍率与翻译规则，避免每个世界各写一份。
--   消费者举例：
--     MULTIPLY / MULTIPLY_PREFABS / TRANSLATE_TO_PREFABS
--       → ocean_gen.lua、monkeyisland_worldgen.lua
--     TRANSLATE_TO_CLUMP / CLUMP / CLUMPSIZE
--       → 成簇散布的世界
--     SEASONS / DEFAULT_SEASON
--       → 季节相关的世界生成后处理
--   ⚠ 注意：pickspawnprefab / pickspawngroup /
--     pickspawncountprefabforground 这三个散布回调【没有导出】——
--     它们只在本文件 :386 组装成 SpawnFunctions 后交给 C++ 回调使用。
--     ⇒ 别的世界（洞穴/海洋）若要自定义散布，得自己另写一套。
--   ★ 这是本文件的设计边界：它是【森林世界的生成器】，
--     而非一个通用的地图生成框架。
return {
    Generate = Generate,
	TRANSLATE_TO_PREFABS = TRANSLATE_TO_PREFABS,
	MULTIPLY = MULTIPLY,
	TRANSLATE_AND_OVERRIDE = TRANSLATE_AND_OVERRIDE,
	MULTIPLY_PREFABS = MULTIPLY_PREFABS,
	TRANSLATE_TO_CLUMP = TRANSLATE_TO_CLUMP,
	CLUMP = CLUMP,
	CLUMPSIZE = CLUMPSIZE,
	SEASONS = SEASONS,
	DEFAULT_SEASON = DEFAULT_SEASON,
}


