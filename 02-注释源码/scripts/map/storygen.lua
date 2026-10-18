--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/storygen.lua（1407 行）
-- 模块：世界生成 / 剧情图编排层（Story Graph Orchestrator）
-- 职责：把「任务（Task）+ 房间（Room）」两份纯数据，编排成一张
--       树/图状的**剧情拓扑图**（story graph）。它只产出拓扑与
--       节点上的房间数据，**不碰任何地块像素、不撒任何实体**。
--       像素层面的事全部委托给 C++ 的 WorldSim（见 forest_map.lua）。
--
-- ★★★ 0. 首要澄清：本文件**不是**世界生成的入口
--   真正的入口是 map/forest_map.lua:381 的 Generate()。
--   本文件是被它 require 进来、调用 story:GenerationPipeline() 的**子流程**。
--   边界：本文件产出 Graph 树 → forest_map.lua:497 才 WorldGen_InitializeNodePoints()
--   → :499 VoronoiPass(100) 把图节点变成 Voronoi 站点 → :522 WorldGen_Commit() 烘焙像素。
--
-- ★★★ 1. ★★ 生成总流程图（真实顺序 —— 已逐行核实，纠正常见误解）
--
--   入口（forest_map.lua）
--     │
--     ├─ level.overrides → story_gen_params 翻译   forest_map.lua:402-460
--     ├─ BuildStory(tasks, story_gen_params, level)          :1394
--     │    │
--     │    └─ Story:GenerationPipeline()                    :86   ★ 本文件的总流程
--     │         │
--     │         ├─【阶段 S1】GenerateNodesFromTasks()        :87→849
--     │         │    └─ GenerateNodesForRegion(region_tasksets["mainland"],
--     │         │                            gen_params.layout_mode)  :864
--     │         │         │
--     │         │         ├─【S1-a】逐 task 生成节点        :871-877
--     │         │         │    └─ GenerateNodesFromTask()   :1232
--     │         │         │         ├─ 房间栈 room_choices:Stack:Create()
--     │         │         │         ├─ 弹栈 → task_node:AddNode() 建房间节点
--     │         │         │         ├─ 线性串联 AddEdge（prevNode 链）
--     │         │         │         ├─ make_loop → MakeLoop()      :1375
--     │         │         │         ├─ hub_room  → MakeHub()       :1379
--     │         │         │         └─ CrosslinkRandom()           :1385
--     │         │         │
--     │         │         ├─【S1-b】_FindStartingTask()     :854  挑无锁起点
--     │         │         ├─【S1-c】锁—钥匙连线            :886-890
--     │         │         │    ├─ layout_mode=="RestrictNodesByKey"
--     │         │         │    │    → RestrictNodesByKey()      :299  （批量分支法）
--     │         │         │    └─ 其他（默认 LinkNodesByKeys）
--     │         │         │         → LinkNodesByKeys()        :493  （逐个贪心法）
--     │         │         │         ★★ 二者是两套独立实现，语义近似但不等价，
--     │         │         │            layout_mode 由 forest_map.lua:431 透传。
--     │         │         │
--     │         │         └─【S1-d】闭环 SeperateStoryByBlanks :899-911
--     │         │              （loop_percent，默认 50% 概率）
--     │         │
--     │         ├─【S1-e】_AddPlayerStartNode(g)           :851→916
--     │         │    └─ 在随机一个 task 里插一个 id=="START" 的绿色节点
--     │         │       ★ 这是玩家出生点，place 时被强拉到地图中心
--     │         │         （见 placement.lua）
--     │         │
--     │         ├─【阶段 S2】AddBGNodes(min,max)           :91→980
--     │         │    给每个 task 的每个非入口节点挂 0~max 个「背景节点」
--     │         │    背景房间模板来自 task.data.background（默认 BGGrass 之类）
--     │         │    ★ 给每个入口节点挂 2 个 blocker_blank（封口用）
--     │         │
--     │         ├─【阶段 S3】AddCoveNodes()                :92→1090
--     │         │    给边数少的节点加 1 个「穴居小房间」（默认 35% 概率）
--     │         │    ★ 它的作用是「打散正则感」——地图不会一格一格均匀
--     │         │
--     │         ├─【阶段 S4】InsertAdditionalSetPieces()   :93→222
--     │         │    把 level/task 里声明的 set_pieces、random_set_pieces
--     │         │    随机塞进该 task 的某个合格节点（写成
--     │         │    terrain_contents.countstaticlayouts[name]=1）
--     │         │
--     │         ├─【阶段 S5】ProcessExtraTags()            :94→187 【已废弃】
--     │         │    → PlaceTeleportatoParts()（传送门零件，deprecated）
--     │         │
--     │         └─【阶段 S6】ProcessOceanContent()         :95→192
--     │              把 level.ocean_population 的房间模板灌进 ocean_population
--     │              （给森林_map.lua:886 PopulateOcean 用）
--     │
--     │    ⚠ **本文件到此结束。它不做 Voronoi、不撒实体、不烘焙地块。**
--     │
--     ├─ WorldGen_InitializeNodePoints()          forest_map.lua:497
--     ├─ ★ WorldGen_VoronoiPass(100)              forest_map.lua:499  ← Lloyd 松弛 100 次
--     ├─ AddRegionsToMainland(on_region_added_fn)  forest_map.lua:506
--     │    每个非大陆区域（如月岛）生成后 → on_region_added_fn()：
--     │      WorldGen_AddNewPositions() + ★ WorldGen_VoronoiPass(50)   ← 再松弛 50 次
--     ├─ WorldGen_Commit()  烘焙                  forest_map.lua:522
--     ├─ ApplyPoisonTag / ConvertToTileMap / SeparateIslands  :526-529
--     ├─ ★ ForceConnectivity(join_islands, ...)   forest_map.lua:536 ← 连通性保证在这
--     ├─ DrawRoads                             forest_map.lua:557
--     ├─ node:SetTilesViaFunction 逐节点自定义地块 :563
--     ├─ GlobalPrePopulate / ConvertGround / PopulateVoronoi :842-873
--     └─ 校验 → GetEncodedMap → return save      forest_map.lua:961-1056
--
-- ★★ 2. 纠正任务描述里给出的顺序（重要，避免照抄错误结论）
--   任务描述给的是：PlaceSpecialPoint → Voronoi/Triangulation → PlaceItems
--                    → PlaceTasks → PlaceCharacters → PostProcess
--   ★ grep 核实：这 5 个函数名在本仓库**全部零命中**（PlaceSpecialPoint /
--     PlaceItems / PlaceTasks / PlaceCharacters / PostProcess 均不存在）。
--     PostProcess 只在 components/colourcube.lua 里作为 C++ PostProcessor 的
--     属性名出现，与世界生成无关。
--   真实关系是：**Task（任务）不是"放置"出来的，而是"最先"被解析成图的**；
--   Voronoi 在图的**后面**；而"放置物品/角色"发生在图的**更后面**（forest_map）。
--   ⇒ 正确心智模型：**先有图，图才有点，点才成地块，地块才长东西。**
--
-- ★★★ 3. 随机数与可复现性（本文件是全库最"吃"随机数的地方之一）
--   · 本文件**从不调用** math.randomseed。★ grep 核实：本文件零命中 randomseed。
--     种子由 C++ 主程序在拉起这个离线 VM 之前设定好。
--   · 本文件消耗的随机源全部是全局 math.random（Lua 标准库），共 14 处，
--     最要命的是下面 4 类：
--       ① math.random(n) 选索引 —— 用于 GetRandomNodeFromTasks(:638)、
--          GetRandomNode（network.lua:538）、_FindStartingTask(:861）、
--          ProcessOceanContent(:209)、PlaceTeleportatoParts 的间接调用。
--       ② math.random() 单次浮点 —— 用于概率判定：island_percent(:450/:610)、
--          loop_percent(:901)、cove_room_chance(:1116)。
--       ③ shuffledKeys(task.nodes) —— 底层是 shuffleArray（util.lua:864），
--          它做 **原地 Fisher-Yates**，连续调用 N 次就吃掉 N×随机数。
--          出现在 :143 PlaceTeleportatoParts、:240/:265 InsertAdditionalSetPieces、
--          :753 FindMainlandNodesForNewRegion（shuffleArray(bucket_counts)）。
--       ④ GetRandomItem（util.lua:259）—— :1241 选 entrance_room。
--   · ★★ **Lua 的 pairs() 遍历顺序不确定，这是自研世界生成第一大雷。**
--     本文件大量使用 pairs() 遍历字典，再把遍历中第 k 个元素当作"随机结果"：
--       - :57  self.tasks 遍历（建索引，无随机性，但影响后续 pairs 顺序）
--       - :175 rootNode:GetChildren() 遍历求 maxdepth —— **顺序不同 ⇒ maxdepth 相同
--              （求的是 max，与顺序无关）**，这里安全。
--       - :316 FindAttachNodes 遍历 target_tasks —— unlockingNodes 的**插入顺序**
--              由 pairs 决定，而 :395 的 default 分支正是靠遍历顺序做轮转分配，
--              ⇒ **同一颗种子下，pairs 顺序变了地图就变了**。
--       - :366/:477 candidateTasks 遍历 —— 同上。
--       - :641 GetRandomNodeFromTasks 里手写 "special order" 遍历注释，
--         明确说明作者知道这里依赖 pairs 顺序。
--     ⇒ 结论：**"同种子必得同世界"只在 Lua 的 hash 遍历顺序稳定时成立**。
--       Lua 5.1 的字符串 hash 带随机种子（每进程不同），但 DST 用的是
--       LuaJIT（5.1 语义 + 可预测 hash），所以实际能复现；移植到别的
--       VM/语言时必须先把所有 pairs 遍历换成有序遍历，否则不可复现。
--   · ★ 第 187 行 processextra 的 print 被 --print(...) 注释掉（:9/:12），
--     于是全文件第 11 行 print_lockandkey 是**空函数**。这意味着：
--     ★★ **联锁算法的调试输出通道被永久关闭了**（除非改代码取消注释，
--     本文件严禁改动）。这就是为什么 :165 会出现"was causeing crash"的
--     历史注释和被注释掉的 assert —— 出问题也看不到日志。
--
-- ★ 4. 交叉引用（关键符号）
--   LockGraph / AddEdge / AddNode ......... map/network.lua:257 / 349 / 461
--   GraphNode 的权重随机选口 ............... map/network.lua:555 / 567
--   LOCKS / KEYS / LOCKS_KEYS .............. map/lockandkey.lua:77 / 165 / 173
--   Task 基类与字段 ......................... map/task.lua:1
--   任务清单注册 ........................... map/tasks.lua:57 / 62
--   关卡级参数挑选 .......................... map/level.lua:89 ChooseTasks
--   场景件房间模板 .......................... map/rooms.lua（Rooms.GetRoomByName）
--   标签展开（maptags） ..................... map/maptags.lua
--   房间栈实现 ............................. map/stack.lua
--   ★ 后处理与像素烘焙 ...................... map/forest_map.lua:381 Generate
--   ★ 真正的重试循环（maxtries = 5） ........ worldgen_main.lua:419
--============================================================
--
--【阅读导航】
--  §零   依赖 / 空掉的调试打印 / 顶部设计备忘      (1-47)
--  §一 ★ Story 类构造与 GenerationPipeline 总流程  (49-96)
--  §二   Mod 房间与 GetRoom（deepcopy 边界）        (98-116)
--  §三 ★★ PlaceTeleportatoParts（★ 已废弃 + 疑似缺陷）(118-190)
--  §四   海洋内容 ProcessOceanContent              (192-220)
--  §五   InsertAdditionalSetPieces（场景件落位）    (222-297)
--  §六 ★★ RestrictNodesByKey（锁—钥匙·批量分支法）  (299-491)
--  §七 ★★ LinkNodesByKeys（锁—钥匙·逐个贪心法）    (493-632)
--  §八   GetRandomNodeFromTasks / AddStartingSetPiece (634-662)
--  §九 ★ FindMainlandNodesForNewRegion（3×3 九宫格）(664-762)
--  §十 ★ LinkRegions / AddRegionsToMainland / AddRegionToTasksNodes (765-847)
--  §十一 ★ GenerateNodesFromTasks / _FindStartingTask /
--         GenerateNodesForRegion（闭环逻辑）        (849-914)
--  §十二 _AddPlayerStartNode（★ START 出生点）      (916-978)
--  §十三 AddBGNodes（背景节点 + blocker 封口）      (980-1088)
--  §十四 AddCoveNodes（★ return 误伤整批的疑似缺陷）(1090-1153)
--  §十五 SeperateStoryByBlanks（闭环 / 孤岛）       (1155-1172)
--  §十六 GetExtrasForRoom / RunTaskSubstitution    (1174-1229)
--  §十七 ★★ GenerateNodesFromTask（单任务的节点生成）(1232-1389)
--  §十八 BuildStory 与 return                     (1390-1408)
--
--【★★ 全文件最重要的十条】
--  1. ★★ 本文件只画图，不画地。产出是一棵 Graph 树；像素由 C++ WorldSim
--     在 forest_map.lua:497 之后接手。参见 :86-96 与 forest_map.lua:499。
--  2. ★★ 两种锁—钥匙连线算法并存：RestrictNodesByKey(:299) 与
--     LinkNodesByKeys(:493)，由 layout_mode 字符串切换（forest_map.lua:431）。
--     二者不共享代码，且 **RestrictNodesByKey 有致命差异：
--     它在 :331-339 只判"每个 lock 是否被任一 key 解开"，
--     但收集 unlockingNodes 时（:349-351）把所有解锁节点都塞进去，
--     而 LinkNodesByKeys(:533-547) 会把 keyNodes 展开成节点表。语义近似但细节不同。**
--  3. ★★ 两算法的"逃生阀"完全一样：**当没有任何任务可解锁时，强行随机接一个**
--     （:473-475 与 :596-599）。这保证了"永远能连完"，代价是
--     **锁—钥匙约束在这一步被打破，可能产出"钥匙拿不到"的不合理地图**。
--     ★ 这正是 bug-patterns.md E1「锁—钥匙同名覆盖致不可达」的
--     在原版里的**兜底**：不可达不会崩溃，但会以"不合理地形"的形式漏出去。
--  4. ★★ pairs() 遍历顺序参与决策（:316 / :366 / :641），
--     所以"同种子 = 同世界"依赖 LuaJIT 的 hash 顺序。移植必炸点。
--  5. ★ AddBGNodes 给入口节点挂 **2 个 blocker_blank**（:1056），
--     配合 ForceDisconnected 标签（:993）给"门"封口 —— 这就是锁的物理形态。
--  6. ★ AddCoveNodes(:1108) 里的 `return` 写在 for 循环体内，
--     ⚠ 疑似缺陷：一旦某个 task 的 cove_room_chance==0 或 max_edges==0，
--     **整个 AddCoveNodes 直接退出**，后面所有 task 的穴居房间都不生成。
--     正确写法应是 `goto continue` / 提取成 continue 标志。见 :1108-1110。
--  7. ★ PlaceTeleportatoParts(:180) 的 `maxdepth/#parts`：
--     当 parts 为空表时 #parts==0 ⇒ **除零**。maxdepth 初值 -1，
--     -1/0 = -inf（Lua 5.1 里 -1/0 不报错，返回 -inf），不会崩，
--     但 :163 的 math.ceil(partnum * -inf) 恒不等于任何 story_depth，
--     结果是"什么都不放" —— 静默失效。⚠ 疑似缺陷（不崩但语义错）。
--  8. ★★ story_depth 是**图上的"解锁顺序"标量**，在 RestrictNodesByKey:440
--     / LinkNodesByKeys:601 单调递增赋值，并被 SaveEncode 写进
--     topology.story_depths（network.lua:156/177）。运行时由
--     components/grottowarmanager.lua:201 与 area_trigger.lua:24 消费。
--     ★ 它是**任务级**（不是节点级）的进度指标，0 = 起点。
--  9. ★ 闭环 SeperateStoryByBlanks(:1155) 造的是一张"空节点 + 两条边"，
--     标签 RoadPoison + ForceDisconnected ⇒ 既阻止道路又切断连接。
--     它同时被 island_percent(:452/:611) 与 loop_percent(:903/:908) 复用，
--     两种完全不同的语义共用一个函数。
--  10. ★ GetRoom(:107) 每次都 deepcopy 整个房间模板，且在
--      GenerateNodesFromTask 的 while 循环里逐房间调用（:1244/:1268）
--      ⇒ **房间数量 × 模板大小** 的深拷贝是本文件的主要内存开销之一。
--      参见 forest_map.lua 的「约 1000 次深拷贝」耗时预算。
--============================================================
-- ============================================================
-- 【对照表】RestrictNodesByKey（:299）与 LinkNodesByKeys（:493）的三处实质差异
-- ============================================================
--
--   维度        RestrictNodesByKey（批量法）      LinkNodesByKeys（贪心法，默认）
--   ---------   ------------------------------   ----------------------------------
--   候选集      unlockingTasks 存【任务对象】     unlockingNodes 存【节点对象】
--   （:350 / :540）
--               ⇒ 候选集是「还没生成的地块」      ⇒ 候选集是「已存在的挂载点」
--
--   深度粒度    批量表 depthData[key]，:440      逐节点 node.story_depth，:601
--   （:440 / :601）
--               ⇒ 任务级深度，可正常落盘           ⚠ Node 级深度，恒为 nil（E1-B）
--
--   钥匙维护    :457 被整段注释，改为 :326       :617-623 增量追加
--   （:326/:457 vs :617）
--               每轮从 usedTasks 全量重算          每轮只追加新钥匙
--               ⇒ O(N²) 但不漏                    ⇒ O(1) 但依赖必经路径
--
-- 【选哪一套】由 forest_map.lua:431 的 layout_mode 透传决定。
--   默认走 LinkNodesByKeys；只有明确指定时才会走 RestrictNodesByKey。
--   ⇒ 因此 :566 的 E1-B 缺陷命中的是【实际生产路径】。
--
-- 【两套共有的安全网】
--   Restrict：:473-475 随机接一条边
--   LinkNodesByKeys：:596-599 随机接一个节点
--   ⇒ 两套算法都保证「图最终连通」，这也是 E1/E1-B 类缺陷长期未被发现的原因：
--     它们不会导致崩溃或坏图，只会导致「地图布局不合理」。
-- ★★★ 本文件是「世界生成的剧情图编排层」。★ 但请先记住第一件事：
--   ★★ 它**不是**世界生成的入口，★ 入口是 map/forest_map.lua:381 Generate()。
--   ★★ 本文件是被它 require 后调用 story:GenerationPipeline() 的**子流程**。
-- ★★ 边界：★ 本文件产出 Graph 树 ⇒ forest_map.lua:497 才 InitializeNodePoints()
--   ⇒ :499 VoronoiPass(100) 把图节点变成 Voronoi 站点 ⇒ :522 烘焙像素。
--   ⇒ ★★ **本文件全程不碰任何地块像素、不撒任何实体。**
require("map/network")
-- ★ map/lockandkey：★ 锁—钥匙表（LOCKS / KEYS / LOCKS_KEYS）。
--   ★★ 本文件是它**唯一重要的消费者**（:319/:324/:524/:617 四处）。
require("map/lockandkey")
-- ★ map/stack：★ 极简栈（★ 全文仅 push/pop/getn 三个函数）。
--   ★★ 唯一使用点：:1235 room_choices = Stack:Create()。
--   ★★★ 关键：★ pop() 是**后进先出** ⇒ 房间生成顺序 = 入栈顺序的**逆序**。
--     ★★ 这意味着 :1262 的 `for room, count in pairs(task.room_choices)`
--       ★★★ 的 pairs 顺序虽然不定，★ 但最终房间顺序也随之不定。
--       ★★★ ⇒ ★★ 又一个 pairs 依赖点（★ 影响地图的视觉布局）。
require("map/stack")
-- ★ map/terrain：地形过滤表。★ 本文件只在 :1038 等处**挂引用**。
require("map/terrain")
-- ★ MapTags：★ 标签展开器（★ maptags.lua）。
--   ★★ 唯一使用点：:83 self.map_tags = MapTags()，:1179 消费。
--   ★★★ 「标签」机制是本文件的隐藏亮点：★ 房间模板可以打标签，
--     ★★★ 标签会被**展开**成实体/静态布局/额外标签/全局标签。
--       ★★★ 这让「这个房间区域是迷宫」「这个区域连通到外部」
--         ★★★ 这类**跨越房间的声明**可以用数据表达。
--     ★★ 四种类型（storygen.lua:1180-1204）：
--       ★★★ STATIC    → 静态布局（extra.static_layouts）
--       ★★★ ITEM       → 额外实体（extra.prefabs）
--       ★★★ TAG       → 追加到本节点的标签
--       ★★★ GLOBALTAG → 记进 self.GlobalTags（★ 跨节点，★ 关键）
local MapTags = require("map/maptags")
-- ★ Rooms：房间模板库（map/rooms/*.lua 的汇总）。
--   ★★ 使用点：:108 GetRoom → deepcopy(Rooms.GetRoomByName(...))。
local Rooms = require("map/rooms")

-- ══════════════ ★★ 空掉的调试通道（本文件最重要的「坑」）══════════════
-- ★★★ 这两个 print 函数是**空函数体**（原代码里 print 被注释掉了）：
--   print_lockandkey_ex(...)  -- print(...)   ← :9
--   print_lockandkey(...)     -- print(...)   ← :12
-- ★★★ ⇒ ★★ **锁—钥匙算法的全部调试输出被永久关闭。**
--   ★★★ 后果：★ 想排查「为什么某个区域不可达」，本文件**给不出任何日志**。
--   ★★★★ 这直接解释了 :165 那行历史注释的存在：
--     -- Not sure why we need this, was causeing crash
--     ★★ 「不知道为什么要这个，它会导致崩溃」——
--       ★★★★ 一个崩溃被注释掉了，而**没人在乎原因**。
--       ★★★ 因为就算想查也查不了（没日志）。★ 这是最坏的一种状态。
--   ★★ ⚠ 要恢复：需取消注释（本项目严禁改动原版代码）。
--   ★★★ 但即使恢复也有用：见 map/lockandkey.lua:531 的说明——
--     ★★ 打印覆盖后的表**看不出重复键**，★ 必须构造期检测。
function print_lockandkey_ex(...)
	--print(...)
end
function print_lockandkey(...)
	--print(...)
end

-- ══════════════ ★★★ 设计备忘（原作者的思路文档）══════════════
-- ★★★ 这段注释是全文件最有价值的文档，★ 它揭示了作者的心智模型：
--   ★★ 「目标：杀光所有蜘蛛 → 1. 先过山口（锁：巨石；钥匙：造镐）
--   ★★  2. 给猪村收集足够的肉（锁：猪的好感；钥匙：肉）」
-- ★★★ 由此倒推出世界生成的设计方法（原文 :36）：
--   -- So working backwards: (create a random number of empty nodes between each)
--   ★★ 「**倒着推**：每两个关键区域之间随机插 N 个空节点**」。
-- ★★ 这就是整个 DST 世界生成的**设计本质**：
--   ★★★ · 不是「随机撒房间」，★ 而是「按一条叙事链的骨架，
--     ★★★ 在骨架之间填充随机节点」。
--   ★★★ 而这个骨架由 tasks.lua 的 room_choices 声明，
--     ★★★ 由 lockandkey.lua 的锁—钥匙关系表达，
--     ★★★ **由本文件的 LinkNodesByKeys 把骨架串起来**。
-- ★★★ 记住这句话，整套系统就通了：
--   ★★★ 「图 = 骨架 + 骨架之间的随机填充物」。
--[[

Example story for DS

Goals:
	Kill ALL the Spiders (The pig village is in trouble, can you defend it and remove the threat?)

	1. To get to the pig village you must first pass through a mountain pass
		LOCK: 	Bolder blocks your path
		KEY:		You must build a pickaxe

	2. You must gather enough meat for the pigs so that they have time to help you with the spiders
		LOCK: 	Pig friendship (Pig village)
		KEY:		Meat

Requirements:
	1. 	LOCK: 	Narrow area that can be blocked with boulders
		KEY:		Rocks on the ground, Twigs/grass, time to dig through the boulders
	2.	LOCK: 	Pig village with pigs and fireplace
		KEY:		Sources of meat and ways to get it; Carrots & Rabbits, wandering spiders

-- ★★★ 这条推导的四步，就是 story_depth 的语义来源：
--   Area 0（起点，蜘蛛巢）→ Area 1（猪村）
--   ★★★ 而 tasks.lua:142 的 TEST_TASK → TEST_TASK1 正是这条链的代码化。
So working backwards: (create a random number of empty nodes between each)

Area 0
	1. Create evil spider dens
	2. Create pig village far enough away from spider dens, but close enough to annoy them
	3. Create Meat source close enough to pig village (this includes wood/etc to stay safe at night) it probably wants to stay away from spiders
	4. Lock all this behind LOCK 1
Area 1
	1. Add rock source
	2. Add twigs/grass source
	3. Add Starting position
--]]

-- ══════════════ ★★★ Story 类构造 ══════════════
-- ★★★ 本类只有 4 个成员：tasks / region_tasksets / rootNode / map_tags。
--   ★★ 加上从 gen_params/level 抄来的配置字段。
Story = Class(function(self, id, tasks, terrain, gen_params, level)
-- ★ id：★ 固定是 "GAME"（forest_map.lua:1398 传的）。★ 不区分世界类型。
	self.id = id
-- ★★ loop_blanks = 1：★ 「环路空地」的计数器起点。
--   ★★ 使用点：:1156/:1157/:1159/:1169。每建一个闭环空地 +1。
--   ★★★ 注意初值是 1 而不是 0 ⇒ 第一个叫 LOOP_BLANK1。
	self.loop_blanks = 1
-- ★★ gen_params：★ forest_map.lua:395-460 组装的参数表。
--   ★★★ 消费者（★ 本文件读它的 6 处）：
--     ★★ :394 branching（分支策略）
--     ★★ :394/:407/:427/:430/:433/:577 分支策略的分派
--     ★★ :449/:610 island_percent（孤岛概率）
--     ★★ :654 start_setpeice（起始场景件）
--     ★★ :864 layout_mode（★ 连线算法选择器）
--     ★★ :900 loop_percent（闭环概率）
	self.gen_params = gen_params
-- ★★ impassible_value：★ 「不可通行地块」的 ID，缺省 WORLD_TILES.IMPASSABLE。
--   ★★ 使用点：:995（blocker_blank 的 value）、:1165（LOOP_BLANK_SUB 的 value）。
--   ★★★ 这就是「锁」的**物理实现**：★ 用不可通行地块当门。
--     ★★ gen_params 里可以覆盖 ⇒ ★★ 不同关卡可以用不同的「门」材质。
	self.impassible_value = gen_params.impassible_value or WORLD_TILES.IMPASSABLE
-- ★ level：★ map/level.lua 的 Level 对象（forest_map.lua:1398 传入）。
--   ★★ 消费者：:89/:91 background_node_range、:173 ordered_story_setpieces、
--     ★★ :193 ocean_population、:207 ocean_population_setpieces、
--     ★★ :234 background（maptag 展开用）、:988 blocker_blank_room_name。
	self.level = level

-- ★★ self.tasks{}：★ 按 id 索引的任务表。
--   ★★★ 这是**唯一**的任务索引，★ 本文件所有 tasks[..].locks 都查它。
	self.tasks = {}
-- ★★ for k,task in pairs(tasks) do ——★★ pairs 遍历入参。
--   ★★★ 后果：★ 若 tasks 里有两个同名 id（不可能，tasks.lua:58 有 assert），
--     ★★ 后者会覆盖前者。★ 实际安全。
--   ★★★ 但「遍历顺序」决定了字典内部布局 ⇒ 影响后续 pairs 的顺序。
--     ★★★ ⇒ ★★ 这是**不可复现性的源头之一**：
--       ★★ 不同的插入顺序 ⇒ 不同的 hash 布局 ⇒ 不同的 pairs 顺序
--         ★★ ⇒ 不同的随机结果。★ 移植时必须改成有序遍历。
	for k,task in pairs(tasks) do
		self.tasks[task.id] = task
	end

-- ★★ region_link_tasks = 1：★ 区域连接任务的计数器。
--   ★★ 使用点：:769 生成 REGION_LINK_N 的 N，:796 +1。
--   ★★★ 这个计数器的存在保证了 :793-794 的 exit 边 id 唯一，
--     ★★★ 而唯一性是 network.lua:270 的 assert 要求的。★ 设计正确。
	self.region_link_tasks = 1
-- ★★ self.region_tasksets{}：★ 按 region_id 分组的任务。
--   ★★★★ 这是「多区域」机制的核心数据：
--     ★★★ · 绝大多数任务没有 region_id ⇒ 全部进 "mainland"（:64）
--     ★★★ · 少数任务（★ caves.lua / moonisland_tasks.lua / ruins.lua）
--     ★★★★ 指定了 region_id ⇒ 形成独立区域（ruins_island、vault_island…）
--     ★★★★ 区域之间靠 :765 LinkRegions 用「连接任务」连起来。
--   ★★★ ⇒ ★★ 「月岛」「废墟岛」的实现本质就是「一个 region + 两条连接」。
--   ★★ 消费点：:850 mainland、:800 AddRegionsToMainland 的迭代、
--     ★★ :512 storygen.region_tasksets["ruins_island"]（forest_map:512）。
	self.region_tasksets = {}
-- ★★ for task_id, task in pairs(self.tasks) do ——★★ pairs 遍历。
	for task_id, task in pairs(self.tasks) do
-- ★★★★ `local region_id = task.region_id or "mainland"`
--   ★★★★ ★★ **全文件最关键的一行默认值**。
--     ★★★ · 大部分 task 没写 region_id ⇒ 归入 mainland
--     ★★★★ · mainland 是**唯一**在 :850 被生成为「主体」的区
--     ★★★ · 其余区在 :800 AddRegionsToMainland 里**另外生成**，
--     ★★★★ 并各自用两条 LinkRegions 连到大陆（:812-813）。
--     ★★★★ ⇒ ★★ 这就是「洞穴不是主世界的一部分，而是插在主世界里的岛」的机制。
--   ★★★ 若某个 task 写了拼错的 region_id ⇒ 它会成为一个**孤立区域**，
--     ★★★ 而 :801 的条件（非 mainland/ruins_island/vault_island）仍然放行它，
--     ★★★★ ⇒ 它会被生成并连上大陆（不会丢）。★ 容错性不错。
		local region_id = task.region_id or "mainland"
		if self.region_tasksets[region_id] == nil then
			self.region_tasksets[region_id] = {}
		end
		self.region_tasksets[region_id][task_id] = task
	end


-- ★★ self.GlobalTags{}：★★ **跨节点**的标签收集器。
--   ★★★★ 这是「区域级声明」的唯一载体：
--     ★★★ · :1196-1203 的 GLOBALTAG 分支往这里塞 {tag → {task → {node_ids}}}
--     ★★★ 所以 GlobalTags 的结构是 **tag → task_id → node_id 数组**。
--     ★★★★ ★★ 三层索引！★ 为什么要 task 这一层？
--       ★★★ 因为「迷宫」这类声明需要区分「哪个 task 的哪些节点是迷宫」。
--       ★★★ forest_map.lua:647 就是 `for task, labyrinth_nodes in
--         ★★★ pairs(GlobalTags["Labyrinth"]) do`。
--     ★★★ 消费点（★ forest_map.lua，grep 核实 4 处）：
--       ★★★ :646/:696 读 Labyrinth / Maze
--       ★★★ :673/:704/:752/:817 读 LabyrinthEntrance / MazeEntrance
--       ★★★ ⇒ ★★ 两种 GlobalTag 成对出现：X 与 XEntrance。
--         ★★★ 这就是「迷宫有一批节点 + 一批入口节点」的数据结构。
	self.GlobalTags = {}
	self.TERRAIN = {}
	self.terrain = terrain

-- ★★★★ self.rootNode = Graph(id.."_root", {}) ——★ 根图。
--   ★★★★ 整个剧情图的**唯一根**。所有 task 图都是它的 children。
--     ★★★ 它的 id 是 "GAME_root"（forest_map:1398 传 id="GAME"）。
--     ★★★★ 注意 rootNode 自身**没有任何节点**，它纯粹是容器。
--       ★★★ ⇒ 真正的房间节点都在子图里。★ 这就是 :730 GetNodes(false)
--         ★★★ 在 PopulateVoronoi 里返回空集的原因。
	self.rootNode = Graph(id.."_root", {})
-- ★★ if gen_params.wormhole_prefab ~= nil then ——★ 虫洞 prefab。
--   ★★ 它被挂到 rootNode 上，★ 而 network.lua:53 声明 wormholeprefab = nil，
--     ★★★ 二者对上了 ⇒ ★★ 虫洞 prefab 的传递链：
--       forest_map.lua:451 读 level.overrides.wormhole_prefab
--         → story_gen_params.wormhole_prefab
--           → :78 self.rootNode.wormholeprefab
--             → network.lua:903/:973/:997/:1053 的 assert
--   ★★★ 一个字段串了 4 个文件。★ 脆弱但清晰。
    if gen_params.wormhole_prefab ~= nil then
        self.rootNode.wormholeprefab = gen_params.wormhole_prefab
    end

-- ★ startNode = nil ——★ 玩家出生节点，★ :851 赋值。
--   ★★ 它会被单独返回（:1405）★ 给 placement.lua 强制把出生点放地图中心。
	self.startNode = nil

-- ★ map_tags = MapTags() ——★ 标签展开器实例（★ 见 :5 的说明）。
	self.map_tags = MapTags()
end)

-- ══════════════ ★★★ GenerationPipeline：★ 本文件的总流程 ══════════════
-- ★★★★ ★★ 只有 7 行，但它是整个剧情图的**唯一驱动点**。
--   ★★★★ 真实执行顺序（★ 已逐行核实，这是唯一的真相）：
--   ┌── 阶段 S1：任务 → 节点（含出生点）─────────────────────────┐
--   │ :87  self:GenerateNodesFromTasks()                        │
--   │      └─ GenerateNodesForRegion(mainland, layout_mode)    │
--   │         ├─ 逐 task 生成房间节点（:871-877）              │
--   │         ├─ _FindStartingTask 挑无锁起点（:879）           │
--   │         ├─ ★ 锁—钥匙连线（:886-890）                     │
--   │         └─ 可能闭环（:899-911）                          │
--   │      └─ _AddPlayerStartNode（:851）★ 插 START 节点       │
--   ├── 阶段 S2：背景节点 ──────────────────────────────────────┤
--   │ :91  self:AddBGNodes(min_bg, max_bg)                     │
--   │      · background_node_range 缺省 {0,2}（:89-90）        │
--   │      · ★ 给每个 entrance 挂 2 个 blocker_blank（:1056）  │
--   ├── 阶段 S3：穴居小房间 ────────────────────────────────────┤
--   │ :92  self:AddCoveNodes()                                 │
--   │      · ★ 缺省 35% 概率（:1106）                          │
--   ├── 阶段 S4：额外场景件 ────────────────────────────────────┤
--   │ :93  self:InsertAdditionalSetPieces()                    │
--   ├── 阶段 S5：★ 已废弃的标签处理 ───────────────────────────┤
--   │ :94  self:ProcessExtraTags()  -- deprecated but leaving  │
--   │      in for modders                                       │
--   └── 阶段 S6：海洋内容 ──────────────────────────────────────┘
--      :95  self:ProcessOceanContent()
--
-- ★★★★ ★★ 关键澄清（纠正任务描述里的误解）：
--   ★★ 任务描述给的顺序是「PlaceSpecialPoint → Voronoi/Triangulation
--   ★★ → PlaceItems → PlaceTasks → PlaceCharacters → PostProcess」。
--   ★★★★ ★★ grep 核实：这 5 个函数名在**整个仓库零命中**。
--     ★★★ · PlaceSpecialPoint / PlaceItems / PlaceTasks /
--       ★★★   PlaceCharacters ——★ 不存在
--     ★★★ · PostProcess ——★ 只在 components/colourcube.lua 作为
--       ★★★   C++ PostProcessor 的属性名出现，★ 与世界生成无关。
--   ★★★★ ⇒ 真实关系是：
--     ★★★ · ★★ Task 不是「放置」出来的，★ 而是**最先被解析成图**的；
--     ★★★ · ★★ Voronoi 在图的**后面**（forest_map.lua:499）；
--     ★★★ · ★★ 「放置物品/角色」在图的**更后面**（forest_map:842-889）。
--     ★★★★ ⇒ 正确心智模型：★「**先有图，图才有点，点才成地块，地块才长东西**」。
--     ★★ 这个顺序不能颠倒：★ 图是因，地块是果。
function Story:GenerationPipeline()
-- ★★ S1：★ 整个剧情图的诞生。★ 详见 :849 GenerateNodesFromTasks。
	self:GenerateNodesFromTasks()

-- ★★ local min_bg = self.level.background_node_range and [1] or 0
--   ★★★ 缺省下限 0。★ 所以「不加背景节点」也是允许的。
	local min_bg = self.level.background_node_range and self.level.background_node_range[1] or 0
-- ★★ local max_bg = … and [2] or 2 ——★ 缺省上限 **2**。
--   ★★★★ ★★ 每个 task 的每个非入口节点会加 0~2 个背景节点。
--     ★★★★ 「背景节点」是**胞元外圈**用的房间（背景房间的 Voronoi 站点）。
--       ★★★ 它们填在 Voronoi 图的「空隙」里 ⇒ ★★ 让地图不是整齐的方格网。
--       ★★★ 这是「Lloyd 松弛之外」的打散正则感的手段。
--     ★★★★ 若关卡声明了 background_node_range = {3, 6}，
--       ★★★ 则每个节点加 3~6 个背景节点 ⇒ 地图更「碎」但更贵（站点更多 ⇒
--         ★★★★ ★★ Voronoi 更慢 ⇒ ★★ Lloyd 的 O(P×S) 里 S 变大）。
--       ★★★ ★★ ⇒ ★★ background_node_range 直接影响生成耗时！★ 重要。
	local max_bg = self.level.background_node_range and self.level.background_node_range[2] or 2
	self:AddBGNodes(min_bg, max_bg)
-- ★★ S3：AddCoveNodes() ——★ 给边数少的节点加「穴居小房间」。
--   ★★ 目的纯粹是**视觉打散**：★ 没有它，Voronoi 胞元大小差异会更明显。
	self:AddCoveNodes()
-- ★★ S4：★ 把任务声明的 set_pieces 塞进该任务的某个合格房间。
	self:InsertAdditionalSetPieces()
-- ★★ S5：★ ProcessExtraTags ——★ 原注释「deprecated but leaving in for modders」。
--   ★★ ★★★ 诚实的注释：★ 知道废弃了，★ 但为了不破坏 mod 留着。
--     ★★★★ 对比 map/level.lua:16-22 用 assert 硬崩的迁移风格，
--       ★★★ 这里选择了**软保留**。★ 因为被废弃的是 mod 会调的函数。
--     ★★★★ ⇒ ★★ 两个文件对「废弃」有两种策略，★ 各有道理。
	self:ProcessExtraTags() -- deprecated but leaving in for modders
-- ★★ S6：★ 把 level.ocean_population 的房间模板灌进 self.ocean_population。
--   ★★ 消费点：forest_map.lua:886 PopulateOcean(…, storygen.ocean_population, …)。
	self:ProcessOceanContent()
end

-- ══════════════ ★ ModRoom：mod 的房间改写钩子 ══════════════
-- ★★ 这是本文件提供的**唯一 mod 扩展点**（RoomPreInit）。
--   ★★ 它在 GetRoom(:114) 里被调用 ⇒ ★★ **每个房间实例化时都会跑一遍**。
--   ★★★ 注意 hooks 是按 roomname 取的（:99），★ 所以 mod 可以：
--     ★★★ · 只针对某个房间（"Forest"）注册钩子
--     ★★★★ 也可以用 ModManager 的通配（★ 取决于框架实现）。
function Story:ModRoom(roomname, room)
-- ★★ ModManager:GetPostInitFns("RoomPreInit", roomname)
--   ★★ PostInit 语义：★ 「post-init」= 构造完、初始化前。
--     ★★★ 同一体系还有 TaskPreInit / TaskSetPreInit / LevelPreInit
--       ★★★ 共 6 个钩子（★ 详见 map/level.lua 的 §一）。
	local modfns = ModManager:GetPostInitFns("RoomPreInit", roomname)
	for i,modfn in ipairs(modfns) do
-- ★★ print 出正在改哪个房间 ⇒ mod 生效可见。★ 好实践。
		print("Applying mod to room '"..roomname.."'")
		modfn(room)
	end

end

-- ══════════════ ★★ GetRoom：★ 房间模板实例化（★ 唯一的 deepcopy 点）══════
-- ★★★★ ★★ `deepcopy(Rooms.GetRoomByName(roomname))` ——★ 全文件唯一的深拷贝。
--   ★★★★ 它在 GenerateNodesFromTask 的 while 循环里被逐房间调用
--     ★★★★ （:1244 入口房 + :1268 每个 room_choices 条目）。
--   ★★★★ ⇒ ★★★ **深拷贝次数 = 房间总数**（约 100~500 次）。
--     ★★★★ 房间模板里有 contents（含几十个 prefab 的权重表）
--       ★★★★ ⇒ ★★ 每次拷贝几百个表项 ⇒ 总拷贝量几万。
--     ★★★★ 但相对 Lloyd 的 2-8 s，这仍是 < 50 ms 预算内的一小部分。
--     ★★★★ ⇒ ★★ **不是瓶颈**，★ 但它是「为什么消耗内存」的主因之一。
--   ★★★★ ★★ **为什么要 deepcopy？**
--     ★★★ · 每个房间实例的数据会被**就地修改**：
--       ★★★ · :1310 `next_room.task = task.id`（写 task）
--       ★★★ · :1305/:1307 `next_room.id = …`（写 id）
--       ★★★ · :1254 `new_room.entrance = true`（写 entrance）
--       ★★★ · :1312 RunTaskSubstitution 会**改 contents.distributeprefabs**
--       ★★★ ★★ 最后这条最关键：★ :1220 `items[k] = nil`、
--         ★★★ ★★ :1223 `items[k] = items[k] * (1.0 - v.percent)`
--           ★★★ ★★★ ⇒ ★★★ **会破坏共享的模板表**！
--         ★★★★ ⇒ ★★★★ 如果不 deepcopy，★ 第一个房间的替换会影响所有房间。
--       ★★★★ ⇒ ★★ deepcopy 是**正确且必要**的。★ 不是过度设计。
--   ★★★ 另一处 deepcopy 在 map/level.lua:223（task 层）。
function Story:GetRoom(roomname)
	local newroom = deepcopy(Rooms.GetRoomByName(roomname))
-- ★★ if newroom == nil then return nil end ——★ 房间不存在。
--   ★★ 这里**返回 nil 而不是崩溃** ⇒ ★★ 下游的 assert（:1245/:1270）
--     ★★ 才崩。而 :999-1000（AddBGNodes）用 assert，:1099-1100（AddCoveNodes）也用。
--   ★★★★ ★★ 三种错误处理风格并存：
--     ★★★ · GetRoom 返回 nil（最温和）
--     ★★★★ · AddBGNodes / AddCoveNodes 的 assert（崩溃并给清晰信息）
--     ★★★★ · storygen.lua:865 的 assert（Must specify a layout mode）
--     ★★★★ ⇒ ★★ 总体上「有清晰报错」，★ 这点比纯静默失败好得多。
    if newroom == nil then
        return nil
    end
-- ★ newroom.name = roomname ——★ 显式写回名字。
--   ★★ 为什么？★ 因为 deepcopy 出来的表可能没有 name 字段，
--     ★★ 而 :1320 `name = next_room.name` 与 :583 GetNodesByName 都要它。
    newroom.name = roomname
-- ★★ newroom.type = newroom.type or NODE_TYPE.Default
--   ★★ **给类型兜底**。★ 房间模板没写 type 就当普通房。
--     ★★★ 后续 :1027/:1125 会据此转换：
--       ★★★ · Room → BackgroundRoom（背景房间）
--       ★★★ · Default → Background
--       ★★★ ⇒ ★★ 「没写 type」的普通房在背景节点里会变 Background。
--     ★★★ 这就是「同一套房间模板在不同用途下类型不同」的机制。
    newroom.type = newroom.type or NODE_TYPE.Default
	self:ModRoom(roomname, newroom)
	return newroom
end

-- ══════════════ ★★ PlaceTeleportatoParts（★ 已废弃）══════════════
-- ★★★★ ★★ 本函数是「传送门零件按剧情顺序布置」的遗留实现。
--   ★★ 它被 :94 ProcessExtraTags 调用 ⇒ ★★ **仍在执行**，
--     ★★★ 只是绝大多数关卡的 level.ordered_story_setpieces 为空
--       ★★★ （★ 因为 map/level.lua:27 标了 Deprecated）。
--   ★★★★ ⇒ ★★ 实际效果：**什么都不放**，★ 但每层遍历全跑一遍。
--     ★★★ 无害的浪费。★ 但若某 mod 设置了 ordered_story_setpieces，
--       ★★★★ 它就会真的执行——★ 而 :180 有除零隐患（见该行）。
function Story:PlaceTeleportatoParts()
-- ★★★ "-- This is deprecated" ★★ 作者自己标注的废弃。
	-- This is deprecated
-- ★★ RemoveExitTag：★ 局部函数，从节点上摘掉 "ExitPiece" 标签。
--   ★★ 为什么要摘？★ 因为传送门零件要放进一个**正常的**房间，
--     ★★ 而不能是「入口房」。★ 所以放完之后就把「入口」标记去掉。
	local RemoveExitTag = function(node)
-- ★★ local newtags = {} ——★ 重建标签数组（不能用 table.remove 边遍历边删）。
		local newtags = {}
-- ★★ for i,tag in ipairs(node.data.tags) do ——★ ipairs（数组，顺序稳定）。
		for i,tag in ipairs(node.data.tags) do
-- ★★ if tag ~= "ExitPiece" then ——★ 过滤。
			if tag ~= "ExitPiece" then
				table.insert(newtags, tag)
			end
		end
-- ★★ node.data.tags = newtags ——★ 就地替换标签数组。
		node.data.tags = newtags
	end

-- ★★ IsNodeAnExit：★ 局部函数，判断节点是否带 ExitPiece 标签。
	local IsNodeAnExit = function(node)
		if not node.data.tags then
			return false
		end
		for i,tag in ipairs(node.data.tags) do
			if tag == "ExitPiece" then
				return true
			end
		end
		return false
	end

-- ★★ AddPartToTask(part, task)：★★ 「找一个出口房，把零件塞进去」。
--   ★★ 它**修改**了 task.nodes[name].data.terrain_contents_extra.static_layouts
--     ★★ ⇒ ★★ 副作用是就地修改图节点。★ 无 deepcopy 保护。
--     ★★★ 但这是**有意的**：★ 我们就是要把它加进最终要烘焙的数据里。
	local AddPartToTask = function(part, task)
-- ★★★ local nodeNames = shuffledKeys(task.nodes) ——★ 随机打乱候选节点。
--   ★★★★ ★★ 这是本函数**唯一**的随机消耗点：
--     ★★★ · shuffledKeys（util.lua:873）→ shuffleArray（:864）
--     ★★★★ · shuffleArray 是原地 Fisher-Yates，消耗 N-1 次 math.random
--     ★★★★ ⇒ ★★ 每放一个传送门零件就消耗 N-1 次随机数。
--       ★★ 而且 N 是「该 task 的房间数」，可能几十。
--       ★★★ ⇒ ★★ 放置顺序**直接影响后续所有随机结果**。
--     ★★★★ ★★ 这是本文件最需要注意的随机消耗点之一。
--       ★★★ 因为 ordered_story_setpieces 通常为空，★ 所以实际上不消耗。
--         ★★ ⇒ ★★ 「废弃代码」反而**保护了随机流的稳定性**。★ 讽刺但真实。
		local nodeNames = shuffledKeys(task.nodes)
		for i,name in ipairs(nodeNames) do
-- ★★ if IsNodeAnExit(task.nodes[name]) then ——★ 找到带 ExitPiece 的房间。
			if IsNodeAnExit(task.nodes[name]) then
-- ★★ local extra = task.nodes[name].data.terrain_contents_extra
--   ★★★★ ⚠ 疑似缺陷（轻度 nil 风险）：★ 若 terrain_contents_extra 为 nil，
--     ★★ :147 的 `if not extra then extra = {} end` 会兜住。★ 安全。
				local extra = task.nodes[name].data.terrain_contents_extra
				if not extra then
					extra = {}
				end
-- ★★ if not extra.static_layouts then extra.static_layouts = {} end
--   ★★ 懒初始化（★ 与 :151 同款）。
				if not extra.static_layouts then
					extra.static_layouts = {}
				end
-- ★★ table.insert(extra.static_layouts, part) ——★ 加入场景件清单。
--   ★★ ★★★ 「传送门零件」本质上就是一个**静态布局**（prefab 的排布模板）。
--     ★★★★ ★★ ⇒ ★★ 传送门零件与其他场景件（如废墟）在数据层面**没有区别**，
--       ★★★★ ★★ 区别只在**放置位置与时机**。★ 统一抽象的好处。
				table.insert(extra.static_layouts, part)
-- ★★ RemoveExitTag(task.nodes[name]) ——★ 放完就摘掉入口标记。
				RemoveExitTag(task.nodes[name])
-- ★★ return true ——★ 成功。★ 调用方用它决定是否继续。
				return true
			end
		end
-- ★★ return false ——★ 失败（没有出口房）。
		return false
	end

-- ★★ InsertPartnumIntoATask(partnum, partSpread, part, tasks)：
--   ★★ 「把第 N 个零件放进 story_depth ≈ N × partSpread 的任务」。
--   ★★★★ ★★ 这是**唯一**用到 story_depth 做决策的地方。
--     ★★★ 语义：★ 按剧情推进的**深度**均匀分布零件。
--       ★★★ 深度 0 是起点 ⇒ 零件不会落在起点上。★
--     ★★★★ ⚠ 但 story_depth 是**任务级**的（network.lua:34），
--       ★★★★ 而这里遍历 tasks（= rootNode 的 children = 任务图）★ 对上了。
	local InsertPartnumIntoATask = function(partnum, partSpread, part, tasks)
		for id,task in pairs(tasks) do
-- ★★ if task.story_depth == math.ceil(partnum*partSpread) then ——★ 匹配深度。
--   ★★★★ ★★ ⚠ 这里有个**精度隐患**：
--     ★★★ · story_depth 是整数（:440/:601 的自增计数器）
--     ★★★★ · math.ceil(partnum * partSpread) 可能重复（多个 partnum 落到同一深度）
--       ★★★ 或**永远匹配不到**（若 partSpread 是小数）。
--     ★★★★ ⇒ ★★ 部分零件放不下（return false，★ 静默）。
--       ★★★ ★★ 没人检查返回值（★ :164 的返回值被 :167 直接 return）。
--       ★★★★ ⇒ ★★ 「有零件没放上去」是完全静默的。★ E2 类缺陷。
			if task.story_depth == math.ceil(partnum*partSpread) then
-- ★★ local success = AddPartToTask(part, task)
--   ★★★ 注意 ★★ success 赋值后**只用于 :167 的 return**，
--     ★★★ ★★ 真正用来检测失败的是下一行那个**被注释掉的 assert**。
--       ★★★★ ⇒ ★★ 「失败」不会中断任何流程，★ 只是这个任务被跳过。
				local success = AddPartToTask(part, task)
-- ★★★★ ★★★ 「-- Not sure why we need this, was causeing crash」
--   ★★★★ ★★★ 这一行是**整个文件最沉痛的一行注释**。
--     ★★★★ 翻译：「不知道为什么需要这个，它会导致崩溃」。
--       ★★★★ 下一行的 assert 被注释掉了，★ 但**没人知道它为什么崩**。
--       ★★★★ 而 :8-13 的 print 通道又是空的 ⇒ ★★ **无从排查**。
--         ★★★★ ★★ 于是这个 assert 就这么被注释掉，★ 留到现在。
--       ★★★★ ★★ 这是一个「技术债 + 无日志」叠加的经典案例。
--     ★★★★ ⚠ 而修好它其实不难：★ assert 的条件里 `task.id == "TEST_TASK"`
--       ★★★ 或 `task.id == "MaxHome"` 是**白名单**（这两个任务没有出口房），
--         ★★★ ⇒ ★★ 说明作者知道「有的任务确实没有 ExitPiece 房间」，
--           ★★★★ ★★ 正确的修法应是「白名单化」而不是「整个 assert 注释掉」。
--     ★★★ ★★ ⇒ ★★ 这是一个**可以确定修好**的历史遗留，值得还原。
				-- Not sure why we need this, was causeing crash
-- ★★★★★★ --assert( success or task.id == "TEST_TASK" or task.id == "MaxHome",
-- ★★★★ ★★ 「Could not add an exit part to task "..task.id)
--   ★★★ ★★ 白名单：TEST_TASK 与 MaxHome。
--     ★★★★ 这两个任务**结构上没有出口房**（★ 没有 room_choices 或全是 entrance），
--       ★★★ 所以 assert 会误报。★ 白名单是对的。
--     ★★★★ ⇒ ★★ 结论：★ 这个 assert 的**本意是对的**，
--       ★★★★ ★★ 只是需要一个更好的白名单机制（比如「task 无出口房就跳过」）。
--       ★★ 现在的处理（整体注释）代价太大：★ 连真正的问题也一起掩盖了。
				--assert( success or task.id == "TEST_TASK"or task.id == "MaxHome", "Could not add an exit part to task "..task.id)
-- ★★ return success ——★★ 无论成功失败都返回，★ 不重试别的任务。
--   ★★★ ⚠ 于是「匹配到深度但放不下」的任务会被放弃，
--     ★★★ 而 **for id,task in pairs(tasks) 里的后续任务不再尝试**（:168 return）。
--       ★★★ ⇒ ★★ 顺序依赖：★ 哪个任务先被遍历到，决定了哪个能拿到零件。
--         ★★★★ ★★ **pairs 顺序不定 ⇒ 结果不可复现**。★ 又一个雷点。
				return success
			end
		end
		return false
	end

-- ★★ local parts = self.level.ordered_story_setpieces or {}
--   ★★★ ★★ 绝大多数关卡这一项是 nil ⇒ ★★ parts = {} ⇒ 整个函数空转。
--     ★★★★ 对照 map/level.lua:27：「ordered_story_setpieces = data.ordered
--       ★★★★ _story_setpieces -- Deprecated」。★ 确认：默认无人填。
	local parts = self.level.ordered_story_setpieces or {}
-- ★★ local maxdepth = -1 ——★★ 初值 -1 而不是 0。
--   ★★★★ ★★ 与 network.lua:34 的 `story_depth or -1` 一致。
--     ★★★ 语义：★ -1 = 「未参与深度链」。★ 区分于 0（起点）。
--       ★★★★ 这是本文件里 story_depth 的**唯一语义规范**。
	local maxdepth = -1
-- ★★ for id, task_node in pairs(self.rootNode:GetChildren()) do
--   ★★★ ★★ 求 maxdepth 用 pairs 遍历，★ 但 **max 与顺序无关**。
--     ★★★★ ⇒ ★★ 这里**安全**。★（对比 :143/:316 那些依赖顺序的地方。）
--     ★★★★ 这是本文件里唯一「用了 pairs 但安全」的地方。
--       ★★★ ⇒ ★★ 判断标准：**只有「取第 k 个」才依赖顺序，
--         ★★★★ 「求聚合量（max/min/sum）永远安全」。★ 好判据。
	for id, task_node in pairs(self.rootNode:GetChildren()) do
		if task_node.story_depth > maxdepth then
			maxdepth = task_node.story_depth
		end
	end
-- ★★★★ ★★★ 【缺陷】`local partSpread = maxdepth/#parts`
--   ★★★★ ★★★ 当 parts 为**空表**时 #parts == 0 ⇒ ★★ 除零！
--     ★★★★ 推演：
--       ★★★ · maxdepth 初值 -1；若 rootNode 有 children 则 > 0
--       ★★★ -1 / 0 与 3 / 0 在 Lua 5.1 中**都不报错**，
--         ★★★★ 分别得到 -inf 与 inf（IEEE 浮点除零的既定行为）。
--       ★★★★ ⇒ **不会崩**，★ 但 partSpread = ±inf。
--       ★★★★ 后续 :163 的 `math.ceil(partnum * inf)`：
--         ★★★★ ★★ · inf ⇒ math.ceil(inf) 在 Lua 5.1 里返回 inf（不报错）
--         ★★★★ ★★ · 任何 story_depth（整数）**永远不等于 inf**
--         ★★★★ ⇒ ★★ ⇒ ★★ **什么都不匹配 ⇒ 什么都不放**。
--     ★★★★ ⇒ ★★ **静默失效**：★ 不崩溃、不报错、什么都不做。
--     ★★★★ ⚠ 伪缺陷之「正确说法」：★ 这不是崩溃 bug，
--       ★★★★ 而是「除以零得到 inf，恰好导致循环体永不进入」的**无害失效**。
--       ★★★★ 但它**掩盖了意图**：★ 若将来 parts 非空而 maxdepth 为 0，
--         ★★★ partSpread = 0 ⇒ :163 匹配 story_depth==0（起点）⇒
--           ★★★★ ★★ 所有零件都堆到**起点任务**上！★ 这是真实风险。
--     ★★ ⚠ 记录：★ 修复方向是 `if #parts == 0 then return end`。
	local partSpread = maxdepth/#parts

-- ★★ for partnum = 1, #parts do ——★ 空表时不执行。★ 所以上面那行除零是唯一影响。
	for partnum = 1,#parts do
		InsertPartnumIntoATask(partnum, partSpread, parts[partnum], self.rootNode:GetChildren())
	end
end

-- ══════════════ ProcessExtraTags（★ 已废弃，保留给 mod）══════════════
-- ★★ 只有一行：调 PlaceTeleportatoParts。
--   ★★ 原注释「-- This is deprecated」★ 再次确认。
function Story:ProcessExtraTags()
	-- This is deprecated
	self:PlaceTeleportatoParts()
end

-- ══════════════ ProcessOceanContent：★ 海洋区域的内容物准备 ══════════════
-- ★★ 它不生成任何节点，★ 只是把房间模板收集到一个表里，
--   ★★ 交给 forest_map.lua:886 的 PopulateOcean 去撒。
function Story:ProcessOceanContent()
-- ★★ if self.level.ocean_population then ——★ 关卡没配海洋 ⇒ 整段跳过。
--   ★★ 森林地图（无海洋）走不到这里。
	if self.level.ocean_population then
		print("[Ocean] Processing ocean fake room content.")

-- ★★ if self.ocean_population == nil then self.ocean_population = {} end
--   ★★★★ ⚠ 疑似缺陷（轻度隐患）：★ :200-205 是**无条件 for 循环**，
--     ★★ 若 level.ocean_population 存在但**所有房间名都无效**，
--       ★★★ 则 ocean_population 保持为空表 {}。
--       ★★★★ 而 :209 的 `math.random(#self.ocean_population)`
--         ★★★★ ★★ 在空表上执行 = **math.random(0) ⇒ 报错**！
--         ★★★★ Lua 的 math.random(0) 会抛「interval is empty」。
--       ★★★★ ⇒ ★★ 只要 ocean_population_setpieces 非空且所有房间都无效，
--         ★★★★ ★★ **世界生成崩溃**。⚠ 疑似缺陷（真实，触发条件苛刻）。
--     ★★★ 修复方向：`if #self.ocean_population == 0 then return end`。
		if self.ocean_population == nil then
			self.ocean_population = {}
		end

-- ★★ for _, room in pairs(self.level.ocean_population) do ——★ pairs 遍历。
--   ★★ 消费顺序不定 ⇒ :209 的随机选取顺序不定。★ 依赖 pairs 顺序。
		for _, room in pairs(self.level.ocean_population) do
-- ★★ local data = self:GetRoom(room) ——★ 同样 deepcopy 一份。
			local data = self:GetRoom(room)
-- ★★ if data then ——★ 房间不存在就跳过（★ 静默）。
			if data then
-- ★★ table.insert(self.ocean_population, {data = data})
--   ★★★ 注意包装成 {data=data}：★ 与 Graph:GetNodesByName 同样的包装风格。
--     ★★★★ 为什么包装？★ 因为 PopulateOcean 的参数签名可能要求多返回值位。
--       ★★★ 这种「为了凑位置而包装」的手法在本仓库出现多次（:584/:831）。
--         ★★★ 是一种**接口适配技巧**，不算优雅但有效。
				table.insert(self.ocean_population, {data = data})
			end
		end

-- ★★ if self.level.ocean_population_setpieces then ——★ 海洋场景件计数表。
--   ★★★ ★★ 与 :263 的 random_set_pieces 对应，★ 但这里的语义不同：
--     ★★★ · ★ 它是 {预制体名 → 数量}（:213-216 的自增）
--     ★★★ · ★ 那是 {场景件名 → 1}（:293 的赋值）
--     ★★★★ ⇒ ★★ 两者**不是同一套机制**，★ 容易混淆。
--       ★★★ 海洋的这套更接近「资源数量表」，★ 会走 ocean_gen.lua 的加权散布。
		if self.level.ocean_population_setpieces then
			for k,v in ipairs(self.level.ocean_population_setpieces) do
-- ★★ content = self.ocean_population[math.random(#self.ocean_population)]
--   ★★★ ⚠ 见 :196 的 ⚠：★ **空表 ⇒ math.random(0) 崩溃**。
--   ★★★★ 每次循环**独立**摇一次 ⇒ 多个场景件可能落在同一个房间。
--     ★★★ 对比 map/level.lua:212 的 `idx[choices[i]] = nil`（防重复），
--       ★★★★ ★★ 这里**没有去重** ⇒ 允许重复。★ 语义不同，无对错。
--     ★★★★ ⇒ ★★ 每个 setpiece 在「所有海洋房间」里随机选一个房间。
--       ★★★ ⇒ ★★ 结果是「总共 N 个 setpiece 分散在 M 个房间里，
--         ★★★ ★★ 可能有两个挤在同一房间」。
				local content = self.ocean_population[math.random(#self.ocean_population)]
-- ★★ if content.data.contents.countstaticlayouts == nil then … end
--   ★★★ countstaticlayouts 是 graphnode.lua:260 消费的字段。
--     ★★★★ ⇒ ★★ 这里的自增会**直接变成**海洋房间里要放的数量。
--       ★★★★ ★★ 所以：★ 同一个海洋房间被抽中两次 ⇒ 放 2 个该场景件。
				if content.data.contents.countstaticlayouts == nil then
					content.data.contents.countstaticlayouts = {}
				end
				if content.data.contents.countstaticlayouts[v] == nil then
					content.data.contents.countstaticlayouts[v] = 0
				end
-- ★★ content.data.contents.countstaticlayouts[v] = … + 1 ——★ 计数 +1。
--   ★★★ ★★ 对比 storygen.lua:260（`= 1`，赋值）与 :293（`= 1`，赋值）：
--     ★★★★ ★★ 这里是**唯一的自增**！★ 语义确实是「数量」。
--       ★★★ 其余两处是「放不放」，★ 所以用赋值 1。★ 各有道理。
--       ★★★★ ⇒ ★★ 同一个字段（countstaticlayouts）在三处有**三种语义**：
--         ★★★ · :216 累加（海洋场景件）
--         ★★★ · :260 赋值 1（任务级 set_pieces）
--         ★★★★ · :293 赋值 1（随机场景件）
--         ★★★★ ⇒ ★★★ 混合使用是**隐患**：若同一房间既被 :216 又被
--           ★★★★ :293 处理，★ :293 的 `= 1` 会**覆盖** :216 的累加结果。★
				content.data.contents.countstaticlayouts[v] = content.data.contents.countstaticlayouts[v] + 1
			end
		end
	end
end

function Story:InsertAdditionalSetPieces(task_nodes)
	local tasks = task_nodes or self.rootNode:GetChildren()
	for id, task in pairs(tasks) do
		if task.set_pieces ~= nil and #task.set_pieces >0 then
			for i,setpiece_data  in ipairs(task.set_pieces) do

				local is_entrance = function(room)
					-- return true if the room is an entrance
					return room.data.entrance ~= nil and room.data.entrance == true
				end
				local is_background_ok = function(room)
					-- return true if the piece is not backround restricted, or if it is but we are on a background
					return setpiece_data.restrict_to ~= "background" or room.data.type == "background"
				end
				local isnt_blank = function(room)
					return room.data.type ~= "blank" and not TileGroupManager:IsImpassableTile(room.data.value)
				end

				local choicekeys = shuffledKeys(task.nodes)
				local choice = nil
				for i, choicekey in ipairs(choicekeys) do
					if not is_entrance(task.nodes[choicekey]) and is_background_ok(task.nodes[choicekey]) and isnt_blank(task.nodes[choicekey]) then
						choice = choicekey
						break
					end
				end

				if choice == nil then
					print("Warning! Couldn't find a spot in "..task.id.." for "..setpiece_data.name)
					break
				end

				--print("Setpiece Placing "..setpiece_data.name.." in "..task.id..":"..task.nodes[choice].id)

				if task.nodes[choice].data.terrain_contents.countstaticlayouts == nil then
					task.nodes[choice].data.terrain_contents.countstaticlayouts = {}
				end
				--print ("Set peice", name, choice, room_choices._et[choice].contents, room_choices._et[choice].contents.countstaticlayouts[name])
				task.nodes[choice].data.terrain_contents.countstaticlayouts[setpiece_data.name] = 1
			end
		end
		if task.random_set_pieces ~= nil and #task.random_set_pieces > 0 then
			for k,setpiece_name in ipairs(task.random_set_pieces) do
				local choicekeys = shuffledKeys(task.nodes)
				local choice = nil
				for i, choicekey in ipairs(choicekeys) do
					local is_entrance = function(room)
						-- return true if the room is an entrance
						return room.data.entrance ~= nil and room.data.entrance == true
					end
					local isnt_blank = function(room)
						return room.data.type ~= NODE_TYPE.Blank
					end

					if not is_entrance(task.nodes[choicekey]) and isnt_blank(task.nodes[choicekey]) then
						choice = choicekey
						break
					end
				end

				if choice == nil then
					print("Warning! Couldn't find a spot in "..task.id.." for "..setpiece_name)
					break
				end

				--print("Random Placing "..setpiece_name.." in "..task.id..":"..task.nodes[choice].id)

				if task.nodes[choice].data.terrain_contents.countstaticlayouts == nil then
					task.nodes[choice].data.terrain_contents.countstaticlayouts = {}
				end
				-- print ("Set peice", name, choice, room_choices._et[choice].contents, room_choices._et[choice].contents.countstaticlayouts[name])
				task.nodes[choice].data.terrain_contents.countstaticlayouts[setpiece_name] = 1
			end
		end
	end
end

-- ══════════════ ★★★★ RestrictNodesByKey（锁—钥匙·批量分支法）════════
-- ★★★★ layout_mode == "RestrictNodesByKey" 时走这个（:886-887）。
--   ★★ 它与 LinkNodesByKeys(:493) 是**两套独立实现**，不共享代码。
--   ★★ 三处实质差异：候选集含义(:334)、深度粒度(:440)、钥匙维护(:457)。
-- ★★★ **不可达性的兜底就在 :473-475** ——★ 全文件最重要的一处。
function Story:RestrictNodesByKey(startParentNode, unusedTasks)
-- ★ print("[Story Gen] RestrictNodesByKey") ——★ 阶段日志（有输出）。
    print("[Story Gen] RestrictNodesByKey")

-- ★★ lastNode = startParentNode ——★ 「上一个接上的节点」。
--   ★★★★ 默认 branching 模式下它**不参与决策**（只在 :434 的 "never" 分支用）。
	local lastNode = startParentNode

-- ★★ usedTasks{}：★ 已经接进图的任务（存 Graph 对象，非 id）。
--   ★★★★ 对比 LinkNodesByKeys(:502)：那边同名变量**只写不读**（死变量）。
	local usedTasks = {}
-- ★★ 起点登记（key = Graph 的 id，因为 :367 按 taskid 查）。
	usedTasks[startParentNode.id] = startParentNode
-- ★★ startParentNode.story_depth = 0 ——★ 起点深度为 0。
--   ★★★★ 与 network.lua:34 的 -1 默认值配合：★ 0 = 「是起点」。
	startParentNode.story_depth = 0
-- ★★ local story_depth = 1 ——★★ 从 1 开始（0 已被起点占用）。
	local story_depth = 1
-- ★ currentNode = nil ——★ 暂存「正在接入的节点」。
	local currentNode = nil

-- ★★★★ local last_parent = 1 -- this is a desperate attempt to
--   distribute the nodes better
--   ★★★★ ★★★ **作者自己承认这是「绝望的尝试」**。全文件最诚实的注释。
--     ★★★★2 它说的是 :394-405 的默认分支：用 last_parent 在
--       ★★★★2 pairs(parents) 的遍历顺序里**轮转**，
--       ★★★★2 ★2 让父节点选择均匀分布（避免全挂在同一个父节点下）。
--       ★★★★2 ★2 代价：完全依赖 pairs 顺序 ⇒ **不可复现**。
--     ★★★★2 ★2 正解应是「按 id 排序后轮转」——既均匀又可复现。
    local last_parent = 1 -- this is a desperate attempt to distribute the nodes better

-- ★★★★ FindAttachNodes(taskid, node, target_tasks)：「找出可挂的目标」。
--   ★★★★ 返回 {target_taskid → target_node}，只含**可解锁**的。
--     ★★★★2 语义：「这个 task 的所有锁都已被现有钥匙打开」。
--       ★★★★2 ★★ ⇒ 这是「锁—钥匙」在**建图期**的唯一执行点。
--     ★★★★4 ★★ ⇒★2 E1 缺陷在这里生效：
--       ★★★★2 LOCKS_KEYS[LOCKS.TREES] 被覆盖成 {AXE, PIGS}
--         ★★★★2 ★2 （lockandkey.lua:254 覆盖了 :219 的 {AXE, FIRE}）
--       ★★★★2 ★2 ⇒ 「持有 FIRE 的任务」被判为「不能开 TREES 锁」
--       ★★★★2 ★2 ⇒ **它的边不会被创建** ⇒ 那条路不存在
--       ★★★★2 ★2 ⇒ 若无别的路，:473-475 的逃生阀强行随机连一条
--         ★★★★2 ★2 ★2 ⇒ 地图不合逻辑但能玩。
--       ★★★★2 ★2 ⇒★2 ★2 「不可达」被掩盖成「不合理」。★★
--     ★★★★2 ★2 ★★ 换句话说：
--       ★★★★2 ★2 锁—钥匙表的错误**不会**导致崩溃，
--       ★★★★2 ★2 只会导致「不该有的边没有 / 该有的边多了」。
--     ★★★★2 ★2 ★★ ⇒ 这就是 E1 缺陷能存活多年的机制性原因。
    local function FindAttachNodes(taskid, node, target_tasks)

-- ★★ unlockingNodes{}：★ 返回值累加器。
        local unlockingNodes = {}

-- ★★ for target_taskid, target_node in pairs(target_tasks) do ——★★ pairs！
--   ★★★★2 关键：★ 返回字典的**插入顺序 = pairs 遍历顺序**。
--     ★★★★2 而 :395/:397 的默认分支正是按遍历顺序轮转父节点
--       ★★★★2 ★2 ⇒ 「谁当父亲」由 pairs 顺序决定 ⇒ 不可复现。
--       ★★★★2 ★2 对比 :175 求 maxdepth 也用 pairs 但**安全**（与顺序无关）。
--         ★★★★2 ★2 判据：★ 只有「取第 k 个」才依赖顺序。
        for target_taskid, target_node in pairs(target_tasks) do

-- ★★ local locks = {} ——★ 「本 task 的锁」的局部表。
            local locks = {}
-- ★★ for i,v in ipairs(self.tasks[taskid].locks) do ——★ ipairs（数组，稳定）。
--   ★★★2 locks 是**数组**（task.lua:8-10 归一化过）⇒ ★★ ipairs 安全。
--     ★★★★2 这就是 task.lua 那两行归一化（标量→表）的价值兑现处。
            for i,v in ipairs(self.tasks[taskid].locks) do
-- ★★ local lock = {keys=LOCKS_KEYS[v], unlocked = false}
--   ★★★★2 ⚠ 隐患：★ 若 LOCKS_KEYS[v] 为 nil（锁未定义），
--     ★★★★2 则 lock.keys = nil ⇒ :333 `ipairs(lockData.keys)` ⇒ **崩溃**。
--       ★★★★2 ★2 这就是 lockandkey.lua:173 那段 ⚠ 说的后果。
--         ★★★★2 ★2 ★2 移植时应在 require 期校验 LOCKS_KEYS 覆盖率。
                local lock = {keys=LOCKS_KEYS[v], unlocked = false}
-- ★★ locks[v] = lock ——★★ 用**整数 ID** v 作键（不是名字）。
                locks[v] = lock
            end

-- ★★ local availableKeys = {} --What are we allowed to connect to this task?
--   ★★★★2 注释里的问句很关键：★ 输入其实是「我们允许连到哪些地方」
--     ★★★★2 ★2 ——即**钥匙检查**而非节点检查。
--       ★★★★2 ★2 ⇒ 函数名 FindAttachNodes 有点名不副实。
            local availableKeys = {} --What are we allowed to connect to this task?

-- ★★ for i, v in ipairs(self.tasks[target_taskid].keys_given) do
--   ★★★★2 【★ 与 LinkNodesByKeys 的重大差异 ★★】
--     ★★★★2 本函数每次调用都**重新收集** availableKeys，
--       ★★★★2 ★2 而且**只收集 target_tasks（= usedTasks）里已有的节点**。
--     ★★★★2 ★2 ⇒ availableKeys 内容**取决于调用时机**：
--       ★★★★2 ★2 只包含**已经接进图的**任务给的钥匙。
--         ★★★★2 ★2 ★2 这是**正确的时序语义**：
--           ★★★★2 ★2 ★2 只有已能到达的区域释放的钥匙才能开下一道门。
--     ★★★★2 ★2 对比 LinkByKeys（:508 外维护、每轮只增）。
--       ★★★★2 ★2 ★2 ⇒ 语义等价，实现方式不同（重算 vs 增量）。
            for i, v in ipairs(self.tasks[target_taskid].keys_given) do --Get the keys that the last area we generated gives
                availableKeys[v] = {}
-- ★★ table.insert(availableKeys[v], target_node) ——★ 记录持钥匙的节点。
                table.insert(availableKeys[v], target_node)
            end

-- ★★★ for lock, lockData in pairs(locks) do ——★★ pairs 遍历锁。
--   ★★★★2 顺序不定 ⇒ 不影响判定（只看布尔聚合）。★ 安全。
            for lock, lockData in pairs(locks) do 						--For each lock:
-- ★★★ for key, keyNodes in pairs(availableKeys) do ——★ 检查每把钥匙。
                for key, keyNodes in pairs(availableKeys) do 			--Do we have a key...
-- ★★★ for reqKeyIdx, reqKey in ipairs(lockData.keys) do ——★★ 遍历锁的钥匙集。
--   ★★★★2 ⚠ 崩溃点（见 :320）：★ lockData.keys 为 nil 时崩。
--     ★★★★2 ★2 两套算法**同一处**风险。
                    for reqKeyIdx, reqKey in ipairs(lockData.keys) do 	--...for this lock?
-- ★★ if reqKey == key then ——★★ 「这把钥匙能开这把锁吗？」
--   ★★★★4 【★ 与 LinkNodesByKeys 的差异二 ★★】
--     ★★★★2 本函数：**只把 lockData.unlocked 置为 true**。
--       ★★★★2 ★2 它**没有**把 keyNodes 展开成节点表塞进 unlockingNodes！
--     ★★★★2 ★2 ⇒ unlockingNodes 里只有「全部锁已解开」的任务，
--       ★★★★2 ★2 **不包含任何「钥匙节点」信息**。
--         ★★★★2 ★2 ★2 后果：:483 挑父节点时只能从候选任务里挑，
--           ★★★★2 ★2 ★2 无法「挑那个真正持有钥匙的节点」。
--           ★★★★2 ★2 ★2 拓扑上仍连通（边照样建），
--             ★★★★2 ★2 ★2 但「谁提供钥匙」这层语义**丢失了**。
--         ★★★★2 ★2 ★2 对比 LinkByKeys(:539-540)：那里有
--           ★★★★2 ★2 ★2 `for i,node in ipairs(keyNodes) do unlockingNodes[node.id]=node end`
--           ★★★★2 ★2 ★2 ⇒ ★2 两算法的候选集含义**真的不同**：
--             ★★★★2 ★2 · Restrict：候选 = **可解锁的任务本身**
--             ★★★★2 ★2 · LinkByKeys：候选 = **持有钥匙的节点**
--           ★★★★2 ★2 ★2 ⇒ 这就是两种布局形态不同的根因。
--             ★★★★2 ★2 ★2 也解释了 :310「desperate attempt」的由来：
--               ★★★★2 ★2 ★2 候选集不含「钥匙所在」信息，分布就难均匀。
                        if reqKey == key then 							--If yes, get the nodes
-- ★★ lockData.unlocked = true ——★★ 开锁（OR 语义）。
--   ★★★★2 印证 lockandkey.lua:171「Locks are unlocked if ANY key is provided」。
--     ★★★★2 ★★ 全仓库**唯一**实现该规则的代码之一（另一处 :542）。
                            lockData.unlocked = true 					--Unlock the lock.
                        end
                    end
                end
            end

-- ★★ local unlocked = true ——★★ AND 语义起点：默认全开。
--   ★★★★2 印证 lockandkey.lua:172「ALL locks must be opened」。
            local unlocked = true
            for lock, lockData in pairs(locks) do
                if lockData.unlocked == false then
                    unlocked = false
                    break
                end
            end

-- ★★ if unlocked then unlockingNodes[target_taskid] = target_node
--   ★★★★3 「AND 语义」的落地点：★ 全部锁都开 ⇒ 收录。
--     ★★★★2 任何一个锁没开 ⇒ 不收录（:342-347 的 break 跳出）。
--       ★★★★2 ★2 ⇒ 语义等价于「检查全部」（break 只是优化）。
            if unlocked then
                unlockingNodes[target_taskid] = target_node
-- ★★★ } else end ——★★ 空 else 分支！
--   ★★★★2 没有任何说明。★ 这是一个「写了一半的分支」。
--     ★★★★2 推测原本想写「否则记录原因以便调试」，但从未实现。
--       ★★★★2 ★2 又一处「调试意图未落地」的痕迹，
--         ★★★★2 ★2 与 :9/:12 空 print、:166 注释 assert 同一类。
            else
            end
        end

        return unlockingNodes
    end

-- ★★ while GetTableSize(unusedTasks) > 0 do ——★ 主循环直到所有任务都接上。
--   ★★★★2 终止性：★ 每轮至少接入一个（:466），或在 :473-475 强制接入。
--     ★★★★2 ⚠ 但若 GetRandomNodeFromTasks 返回 nil（:475），
--       ★★★★2 :379 的 `currentNode.id` 会**崩溃**。
--         ★★★★2 ★2 依赖「unusedTasks 非空」这一隐含前提。
    while GetTableSize(unusedTasks) > 0 do
-- ★★ local effectiveLastNode = lastNode ——★★ 「实际挂到哪个节点」。
--   ★★★★2 会被 :394-436 的五种 branching 策略改写。
--     ★★★★2 ★2 branching 参数**直接决定地图形态**。
--       ★★★★2 ★2 五种策略语义：
--         ★★★★2 · nil/"default" → :395 轮转分配（均衡）
--         ★★★★2 · "random"       → :407 随机选（避开上次）
--         ★★★★2 · "most"         → :428 **深度最低**（最靠近起点）
--         ★★★★2 · "least"        → :431 **深度最高**（最远离起点）
--         ★★★★2 ★2 · "never"        → :434 永远挂 lastNode（纯链）
--       ★★★★2 ★2 ⇒ ★2 「most」与「least」其实是「早」与「晚」
--         ★★★★2 ★2 —— 生成**几乎直线推进** vs **深度优先探索**。
--         ★★★★2 ★2 ⇒ 这是玩家可选的「世界形状」旋钮。★
        local effectiveLastNode = lastNode
-- ★ print_lockandkey_ex("\n\n_______Attempting new connection_______")
--   ★★★★3 这是**空函数**（:9-10）⇒ ★ 这条调试信息**永不出现**。
--     ★★★★2 见文件头的「空掉的调试通道」说明。
        print_lockandkey_ex("\n\n_______Attempting new connection_______")

-- ★★ local candidateTasks = {} ——★ 本轮的可选任务集。
        local candidateTasks = {}

        print_lockandkey_ex("Gathering new batch:")

-- ★★ for taskid, node in pairs(unusedTasks) do ——★★ pairs 遍历。
--   ★★★★2 ⇒ 遍历顺序决定 candidateTasks 的**插入顺序**。
--     ★★★★2 而 :477 又是 pairs 遍历 candidateTasks ⇒ **双重顺序依赖**。
--       ★★★★2 ★2 ⇒ 「哪些任务这一轮被接入」不可复现。
        for taskid, node in pairs(unusedTasks) do
-- ★★ local unlockingNodes = FindAttachNodes(taskid, node, usedTasks)
            local unlockingNodes = FindAttachNodes(taskid, node, usedTasks)

-- ★★ if GetTableSize(unlockingNodes) > 0 then ——★ 有候选才算。
            if GetTableSize(unlockingNodes) > 0 then
                print_lockandkey_ex(taskid, GetTableSize(unlockingNodes))
                candidateTasks[taskid] = unlockingNodes
            end
        end

-- ★★ local function AppendNode(in_node, parents) ——★ 「把一个节点接进图」。
--   ★★★★2 ★★ 这是本函数**唯一的写操作入口**，全部副作用在这里。
--     ★★★★2 ★2 它做 5 件事：
--       ★★★★2 · ① 选父节点（:381-436，五种 branching 策略）
--       ★★★★2 · ② 分配 story_depth（:440-441）
--       ★★★★2 · ③ 挑父节点出口与自己入口（:443-444）
--       ★★★★2 · ④ 建边（LockGraph / SeperateStoryByBlanks，:449-455）
--       ★★★★2 · ⑤ 移出 unusedTasks、加入 usedTasks、更新 lastNode
--     ★★★★2 ★2 ⇒ 原子性：★ 全部做完才算成功，无中间状态。
        local function AppendNode(in_node, parents)

            print_lockandkey_ex("#############Success! Making connection.#############")
            print_lockandkey_ex(string.format("Trying to connect %s", in_node.id))
-- ★★ currentNode = in_node ——★ 暂存。
            currentNode = in_node

-- ★★ local lowest = {i=999, node=nil} ——★★ i=999 是「无穷小」哨兵。
--   ★★★★2 ⚠ 硬编码 999：★ 若 story_depth 超过 999，
--     ★★★★2 "most" 策略（:428）会选错节点（999 比真实值大）。
--       ★★★★2 ★2 实践中 task 数量 < 999 ⇒ 不触发。
--         ★★★★2 ★2 「硬编码哨兵」是脆弱写法（应用 math.huge）。
--       ★★★★2 ★2 对比 :715 的 `dist = math.huge`（用对了）——
--         ★★★★2 ★2 同一文件两种写法，★ 不一致。
            local lowest = {i = 999, node = nil}
-- ★★ local highest = {i=-1, node=nil} ——★ 「无穷大」哨兵。
            local highest = {i = -1, node = nil}
-- ★★ for id, node in pairs(parents) do ——★★ pairs 遍历候选父节点。
--   ★★★★2 ★2 ⚠★ 这里 pairs 顺序**确实有影响**：
--     ★★★★2 · :384 `>= highest.i` ⇒ **相等时取后者**
--       ★★★★2 · :388 `< lowest.i` ⇒ **相等时不更新**
--     ★★★★2 · ⇒ highest 是 pairs 最后一个，lowest 是**第一个**。
--     ★★★★2 ★2 ⇒ 「most」/「least」的结果**依赖 pairs 顺序**！
--       ★★★★2 ★2 ★2 branching 是玩家可选的 ⇒ 不同玩家世界形态不同
--         ★★★★2 ★2 ★2 （即便同种子）。★ 很实质的不可复现性。
            for id, node in pairs(parents) do
                if node.story_depth >= highest.i then
                    highest.i = node.story_depth
                    highest.node = node
                end
                if node.story_depth < lowest.i then
                    lowest.i = node.story_depth
                    lowest.node = node
                end
            end

-- ★★★★ if branching == nil or branching == "default" then
--   ★★★★2 「轮转分配」策略 ——★ :310 注释里的「desperate attempt」。
--     ★★★★2 算法：last_parent = ((last_parent-1) % size) + 1
--       ★★★★2 ★2 ⇒ 在 1..size 循环，每个父节点被轮流选中一次。
--         ★★★★2 ★2 ⇒ 轮转的是「pairs 顺序里的位置」而非确定节点。
            if self.gen_params.branching == nil or self.gen_params.branching == "default" then
-- ★★ last_parent = ((last_parent-1) % GetTableSize(parents)) + 1 ——★ 循环索引。
--   ★★★★2 ⚠ 若 GetTableSize(parents) 为 0 ⇒ 除零！
--     ★★★★2 ★2 推理：:369 只收录有 unlockingNodes 的 ⇒ 非空。
--       ★★★★2 ★2 但 :475 传的是 usedTasks ⇒ 它至少含起点 ⇒ 非空。✔ 安全。
                last_parent = ((last_parent-1) % GetTableSize(parents)) + 1
-- ★★ local parent_i = 1 ——★ 遍历计数器。
                local parent_i = 1
-- ★★ for k,v in pairs(parents) do ——★★ pairs（顺序即「第几个」的依据）。
--   ★★★★2 ⚠ 疑似缺陷（变量语义混乱）：
--     ★★★★2 · :401 的 `last_parent = last_parent + 1` **多加了 1**，
--       ★★★★2   而 :395 刚把它规范到 1..size ⇒ 下次又归一。逻辑闭合。
--     ★★★★2 ★2 parent_i 与 last_parent 两个计数器交织，谁在数谁说不清。
--       ★★★★2 ★2 ⇒ 对应 :310 的「desperate attempt」自嘲。
                for k,v in pairs(parents) do
                    if parent_i < last_parent then
                        parent_i = parent_i + 1
                    else
                        last_parent = last_parent + 1
-- ★★ effectiveLastNode = v ——★★ 选中它。
                        effectiveLastNode = v
                        break
                    end
                end
-- ★★ print_lockandkey_ex("\tAttaching "..) ——★ 空函数，无输出。
                 print_lockandkey_ex("\tAttaching "..currentNode.id.." to next key", effectiveLastNode.id)
-- ★★★★ elseif branching == "random" then ——★ 随机选，但**避开上次**。
--   ★★★★2 算法：摇随机数，若等于 last_parent 就**重摇**。
--     ★★★★2 ⚠ 疑似缺陷（潜在活锁）：
--       ★★★★2 `while (choice == last_parent) do … end`
--         ★★★★2 ★2 当 **num_parents == 1** 时 choice 恒等于 last_parent
--           ★★★★2 ★2 ⇒ **死循环**！
--         ★★★★2 ★2 但 :409-411 提前判了 num_parents==1 ⇒ 兜住。✔
--           ★★★★2 ★2 ★2 ⇒ 结论：**有防御但很脆弱**——
--             ★★★★2 ★2 ★2 若有人删掉 :409 特判，这里立刻变死循环。
--     ★★★★2 ★2 每次重摇消耗 1 次随机数 ⇒ 消耗量是**变量**。
            elseif self.gen_params.branching == "random" then
				local num_parents = GetTableSize(parents)
-- ★★★ if num_parents == 1 then ——★★ 唯一候选 ⇒ 直接用（★ 死循环防护）。
				if num_parents == 1 then
					local dummy
-- ★★★ dummy, effectiveLastNode = next(parents) ——★ 用 next 取唯一元素。
					dummy, effectiveLastNode = next(parents)
				else
-- ★★ local choice = last_parent ——★ 初始化为上次值以触发重摇。
					local choice = last_parent
-- ★★★ while (choice == last_parent) do choice = math.random(num_parents) end
--   ★★★★2 这就是上面 ⚠ 说的死循环点（★ :409 兜住了）。
					while (choice == last_parent) do
-- ★★ choice = math.random(num_parents) ——★★ 摇 1..num_parents。
						choice = math.random(num_parents)
					end
-- ★★ last_parent = choice ——★★ 记住，供下次「避开」。
					last_parent = choice
-- ★★ for _, v in pairs(parents) do ——★★ pairs 找第 choice 个。
--   ★★★★2 ⇒ 「random」的随机性被 pairs 稀释：
--     ★★★★2 摇出的 index 落在 pairs 顺序上，而 pairs 顺序本身随机 ⇒ 双重随机。
					for _, v in pairs(parents) do
						effectiveLastNode = v
						choice = choice - 1
						if choice <= 0 then
							break
						end
					end
				end
-- ★ print_lockandkey_ex(...) ——★ 空函数（★ 与 :579 的 print_lockandkey 不同）。
                print_lockandkey_ex("\tAttaching "..currentNode.id.." to random key" .. effectiveLastNode.id)
-- ★★ elseif branching == "most" then ——★ 挂到 story_depth 最**小**的候选。
--   ★★★★2 效果：总是挂到**离起点最近**的位置 ⇒ 地图是「广度优先」。
--     ★★★★2 对比 :430 "least" ⇒ 「深度优先」。
            elseif self.gen_params.branching == "most" then
                effectiveLastNode = lowest.node
                print_lockandkey_ex("\tAttaching "..currentNode.id.." to lowest key" .. effectiveLastNode.id)
-- ★★ elseif branching == "least" then ——★ 挂到 story_depth 最**大**的候选。
--   ★★★★2 效果：一直往最远最新的区域延伸 ⇒ 地图是「深度优先」。
            elseif self.gen_params.branching == "least" then
                effectiveLastNode = highest.node
                print_lockandkey_ex("\tAttaching "..currentNode.id.." to highest key" .. effectiveLastNode.id)
-- ★★ elseif branching == "never" then ——★ 永远挂 lastNode ⇒ **纯线性链**。
--   ★★★★2 效果：地图就是一条直线，每个区域依次接在末尾。
--     ★★★★2 ★2 ⇒ ★★ 与 loop 闭环（:899-911）配合：
--       ★★★★2 ★2 得到「一条直线绕一圈回到起点」= **环形世界**。★
--       ★★★★2 ★2 ⇒ branching=never + loop=always 是环形世界的配方。
            elseif self.gen_params.branching == "never" then
                effectiveLastNode = lastNode
                print_lockandkey_ex("\tAttaching "..currentNode.id.." to end of chain" .. effectiveLastNode.id)
-- ★★ ⚠ 没有 else 分支！★ 若 branching 是别的值（如 "foo"），
--   ★★★★2 五个分支全不命中 ⇒ effectiveLastNode 保持 :359 的初值
--     ★★★★2 （= lastNode）⇒ 退化成 branching == "never" 的行为。
--       ★★★★2 ★2 ⇒ ★2 **静默降级，无任何日志**。★
--         ★★★★2 ★2 ⚠ 疑似缺陷：应加 else + print 警告。
--           ★★★★2 ★2 对比 :589（LinkNodesByKeys）同样缺失 ⇒ 复制粘贴产物。
            end

-- ★ print_lockandkey_ex(...) ——★ 空函数。
            print_lockandkey_ex(string.format("Connected it to %s", effectiveLastNode.id))

-- ★★ currentNode.story_depth = story_depth ——★★ ★★ 深度分配。
--   ★★★★4 ★★ 这是 story_depth 的**唯一赋值点**（本函数内）。
--     ★★★★2 ★2 语义：**接入的先后顺序**，而非图上的最短距离。
--       ★★★★2 ★★★ 因为 :358 是「一轮接多个」的批量算法，
--         ★★★★2 ★2 一个 depth 可能对应**多个任务**！
--       ★★★★2 ★2 ⇒ ★2 而 :163 的 `task.story_depth == ceil(...)`
--         ★★★★2 ★2 假设深度唯一 ⇒ ★2 RestrictNodesByKey 下
--           ★★★★2 ★2 **传送门零件会多个挤在同一深度上**。
--       ★★★★2 ★2 ⇒★2 ★2 这是 RestrictNodesByKey 的第三个隐患。
--     ★★★★2 ★2 而 :601（LinkNodesByKeys）**逐个**接 ⇒ 深度唯一。
--       ★★★★2 ★2 ⇒ ★★ 两算法的 story_depth 语义不同！
--         ★★★★2 ★2 ★★ **同一存档里 depth 含义取决于 layout_mode**！
--           ★★★★2 ★2 ★2 ⇒ 运行时消费（grottowarmanager:239 判「是否同区域」）
--             ★★★★2 ★2 ★2 会有**不一致的行为**。★ 值得记录。
            currentNode.story_depth = story_depth
-- ★★ story_depth = story_depth + 1 ——★★ 单调递增（逐个递增）。
            story_depth = story_depth + 1

-- ★★ lastNodeExit = effectiveLastNode:GetRandomNodeForExit()
--   ★★★★3 「接缝点」的选择 ——★ 这是地图观感的核心。
--     ★★★★2 · 从父任务候选节点里**加权随机**挑一个当出口
--       ★★★★2   （network.lua:555，排除 entrance）
--     ★★★★2 · 权重来自 room 模板的 random_node_exit_weight。
--       ★★★★2 ★2 ⇒ ★2 「哪些房间适合当出口」是**数据决定的**。
--     ★★★★2 消耗 1 次随机数（weighted_random_choice 内）。
            local lastNodeExit = effectiveLastNode:GetRandomNodeForExit()
-- ★★★★ currentNodeEntrance = currentNode.entrancenode or
--   currentNode:GetRandomNodeForEntrance()
--   ★★★★4 「优先用任务自己的入口房」。
--     ★★★★2 · :433 的网络层记录 self.entrancenode（**只留最后一个**）
--     ★★★★2 · 有 entrance 房（storygen.lua:1254 打的标记）就用它；
--       ★★★★2   否则随机挑一个当入口。
--     ★★★★2 ★2 ⇒ ★2 **有 entrance 房的任务，图上会多一个特殊节点**，
--       ★★★★2 它是 blocker 类型（storygen.lua:1318），
--         ★★★★2 且挂 2 个 blocker_blank 子节点（:1056）⇒ ★「封口」。
--     ★★★★2 ★2 ⇒ ★2 **entrance 房是「门」**，房间连接都经过它。
--       ★★★★2 ★2 ★★ 这正是「锁」的视觉形态：★ 一间封死的入口房。
--     ★★★★2 ⚠ :433 只保留**最后一个** entrance ⇒ 多个 entrance 时
--       ★★★★2 只有最后一个被用作接入点，其余白建。★
            local currentNodeEntrance = currentNode.entrancenode or currentNode:GetRandomNodeForEntrance()

-- ★★ assert(lastNodeExit) ——★★ 「父任务必须有可用出口」。
--   ★★★★2 失败原因：所有房间 exit 权重为 0，或全是 entrance。
--     ★★★★2 ⇒ 崩在这里说明该 task 的 room_choices 全是 entrance 房。
--       ★★★★2 ★2 ⇒ 数据错误，★ 崩溃是**恰当**的。★ 好断言。
            assert(lastNodeExit)
-- ★★ assert(currentNodeEntrance) ——★★ 同理，「新区必须有可用入口」。
            assert(currentNodeEntrance)

-- ★★★★ if self.gen_params.island_percent ~= nil
--   ★★★★3 「要不要造一个孤岛」的判定。
--     ★★★★2 三个条件（都要满足）：
--       ★★★★2 ① 玩家设置了 islands（forest_map.lua:415-418 映射成百分比）
--       ★★★★2 ② 随机数 ≤ island_percent
--       ★★★★2 ③ `currentNodeEntrance.data.entrance == false`
--         ★★★★2 ★2 ⇒ 已有入口房的任务不会被切成孤岛（合理：孤岛不该有门）。
--     ★★★★2 island_percent 映射（forest_map.lua:416）：
--       ★★★★2 always=1/never=0/default=0.2/sometimes=0.1/often=0.8
--       ★★★★2 ★2 ⇒ 「default」= 20% 的边被切成孤岛（比例很高）。
--     ★★★★2 ★2 ⇒ ★2 孤岛 + ForceConnectivity（forest_map:536）
--       ★★★★2 最终所有孤岛都会被连上（无路则造陆桥）。
--         ★★★★2 ★2 ★2 ⇒ 「孤岛」在最终地图上不可见，
--           ★★★★2 ★2 只是在图上多了一个节点而已。★
            if self.gen_params.island_percent ~= nil
-- ★★ and currentNodeEntrance.data.entrance == false then ——★ 排除有门任务。
                and self.gen_params.island_percent >= math.random()
                and currentNodeEntrance.data.entrance == false then
-- ★★ self:SeperateStoryByBlanks(lastNodeExit, currentNodeEntrance)
--   ★★★★2 切岛 ⇒ 造一个不可达的空节点，两端都连到它。
--     ★★★★2 ★2 但★ 它**不是真的不可达**：
--       ★★★★2 · network.lua:1030 的 ApplyPoisonTag 会因
--         ★★★★2   "ForceDisconnected" 标签调用 ClearNodeLinks
--       ★★★★2 · forest_map.lua:536 的 ForceConnectivity 会**造陆桥**
--         ★★★★2 ★2 ⇒ 所以「孤岛」最终会被修复。
                self:SeperateStoryByBlanks(lastNodeExit, currentNodeEntrance)
            else
-- ★★★★★★ self.rootNode:LockGraph(effectiveLastNode.id..'->'..currentNode.id,
--   lastNodeExit, currentNodeEntrance,
--   {type="none", key=self.tasks[currentNode.id].locks, node=nil})
--   ★★★★4 ★★★ **全文件最重要的一行** ——★ 「锁」在此诞生。
--     ★★★★2 逐部分：
--       ★★★★2 · id = "A->B" 是 exit 边 id（★ network.lua:270 要求唯一）
--         ★★★★2 ★2 ★★ A/B 都是 **Graph 的 id**（不是节点 id）⇒
--           ★★★★2 ★2 ★★ 边 id 是**任务级**的 ⇒ ★★ 一个 task 对之间
--             ★★★★2 ★2 ★★ **只有一条** exit 边 ⇒ 该对所有房间连接
--               ★★★★2 ★2 ★★ 都汇聚到这一条边（:443/:444 选的那对房间）。
--       ★★★★2 · key = tasks[..].locks：★★ 锁信息
--         ★★★★3 ★★ lock.key 在**网络层从未被读取**（network.lua 全核实）。
--           ★★★★3 ★2 ⇒ ★2 它是纯声明式元数据。
--             ★★★★3 ★2 ⇒★2 「锁」的物理形态**不是 key**：
--               ★★★★3 ★2 · ① 这条边存在 ⇒ 可通行
--               ★★★★3 ★2 · ② entrance 房的 blocker_blank ⇒ 视觉上的门
--               ★★★★3 ★3 · ③ ★★ 「有钥匙才建边」⇒ 无钥匙时**路不存在**
--             ★★★★3 ★2 ⇒★2 ★2 **不可达 = 边缺失，不是门打不开**。
--       ★★★★2 · type = "none"：★★ 恒为 "none"（也是纯元数据，
--         ★★★★2 ★2 network.lua:264 的 assert 被注释掉了）。
                self.rootNode:LockGraph(effectiveLastNode.id..'->'..currentNode.id, lastNodeExit, currentNodeEntrance, {type="none", key=self.tasks[currentNode.id].locks, node=nil})
            end

-- ★★★★ -- for i,v in ipairs(currentNode.keys_given) do … end
--   ★★★★4 【★ 与 LinkNodesByKeys 的差异三 ★★】
--     ★★★★2 ★★ 这段「把新区给的钥匙加进 availableKeys」被**整段注释掉**！
--       ★★★★2 对比 :616-623 的 LinkNodesByKeys 是**活代码**。
--       ★★★★2 ★2 ⇒ 两算法的钥匙传递方式不同：
--         ★★★★2 · Restrict：★ 不维护，调用时**从 usedTasks 重算**（:326）。
--         ★★★★2 · LinkByKeys：★ 增量维护（:617-623）。★ 更快。
--     ★★★★2 ★2 ★★ 三处差异汇总（移植时的对照表）：
--       ★★★★2 · 候选集含义不同（任务 vs 钥匙节点，见 :334）
--       ★★★★2 · 深度分配粒度不同（批量 vs 逐个，见 :440）
--       ★★★★2 · 钥匙维护方式不同（重算 vs 增量，见本行）
--       ★★★★2 ★2 ⇒ ★2 移植时若只实现一套，★ 世界形态会变。
            -- print_lockandkey_ex("\t\tAdding keys to keyring:")
            -- for i,v in ipairs(self.tasks[currentNode.id].keys_given) do
            -- 	if availableKeys[v] == nil then
            -- 		availableKeys[v] = {}
            -- 	end
            -- 	table.insert(availableKeys[v], currentNode)
            -- 	print_lockandkey_ex("\t\t",KEYS_ARRAY[v])
            -- end

-- ★★ unusedTasks[currentNode.id] = nil ——★★ 移出待接队列。
            unusedTasks[currentNode.id] = nil
-- ★★ usedTasks[currentNode.id] = currentNode ——★★ 加入已接集合。
            usedTasks[currentNode.id] = currentNode
-- ★★ lastNode = currentNode ——★★ 供「never」策略与返回值用。
            lastNode = currentNode
-- ★★ currentNode = nil ——★ 复位。
            currentNode = nil

        end

-- ★★★★★★ if next(candidateTasks) == nil then ——★★ 「本轮无可选任务」。
--   ★★★★★4 ★★★★ 全文件最重要的「逃生阀」。
--     ★★★★★2 触发条件：★ 没有任何任务的所有锁都被解开。
--       ★★★★★2 ★2 典型原因（★ E1 缺陷在此显形）：
--         ★★★★★2 · 某任务的锁要求一把「没人给的钥匙」（★ 死锁）
--         ★★★★★2 · LOCKS_KEYS 覆盖不全导致 :333 判定异常
--         ★★★★★2 · 钥匙链根本不通（★ 数据配错）
--       ★★★★★2 ★2 ★★ 原注释的口吻（★ 空函数，从不打印）：
--         print_lockandkey_ex("We aint found nothin'!! Making a random connection :( -- ")
--         ★★★★★2 ★2 ★2 ★2 (T_T)★ 作者知道这是妥协。
--     ★★★★★4 ★★★ **强行随机接一个任务**。
--       ★★★★★2 ★2 ⇒ ★2 「锁」被**完全绕过**。
--         ★★★★★2 ★2 ★2 ⇒ ★★ 生成出来的地图**可能不合逻辑**：
--           ★★★★★2 ★2 ★2 ★2 某区域被放在它「应该被锁住」的位置上。
--           ★★★★★2 ★2 ★2 ★2 玩家会看到「这个门怎么没锁」。
--       ★★★★★4 ★2 ★2 ⇒★2 ★2 E1「不可达」被掩盖成「不合理」。
--         ★★★★★2 ★2 ★2 ★★ 这就是缺陷长期存活的原因。
--       ★★★★★2 ★2 ★2 ★2 ★2 而且**这条 print 也是空函数**（:11）⇒
--         ★★★★★2 ★2 ★2 ★2 玩家和开发者都看不到它发生过。
--           ★★★★★2 ★2 ★2 ★2 ⇒ ★2 一条**零可见性的妥协路径**。
--     ★★★★★2 ★2 移植时的正确做法：不要静默兜底，而应可配置 + 留日志：
--       ★★★★★2 · fallback = "random"（原版行为）
--       ★★★★★2 · fallback = "fail"   （严格模式，暴露数据错误）
        if next(candidateTasks) == nil then
            print_lockandkey_ex("We aint found nothin'!! Making a random connection :( -- ")
-- ★★ AppendNode(self:GetRandomNodeFromTasks(unusedTasks), usedTasks)
--   ★★★★2 ★★ 强制接入：★ 随机挑一个未接任务，挂到 usedTasks 里。
--     ★★★★2 · GetRandomNodeFromTasks(:634) 从 unusedTasks **随机**挑一个
--       ★★★★2 ★2 （★ 消耗 1 次 math.random，且它内部用 pairs ⇒ 不可复现）。
--     ★★★★2 · 第二参数传 usedTasks ⇒ 父节点从**已接任务**里选。
--       ★★★★2 ★2 ⇒ ★2 图仍然连通。✔
--     ★★★★2 · ⇒ ★★ 「不可达」被消除，★ 但「合理性」被牺牲。
            AppendNode( self:GetRandomNodeFromTasks(unusedTasks), usedTasks )
        else
-- ★★ for taskid, unlockingNodes in pairs(candidateTasks) do ——★★ pairs！
--   ★★★★2 批量接入：★ 本轮**所有**候选任务都被接入。
--     ★★★★2 ★2 ⇒ 一个 depth 对应多个任务（见 :440 的 ⚠）。
--     ★★★★2 ★2 pairs 遍历 ⇒ ★2 接入顺序不可复现 ⇒ 直接影响 depth 分配。
            for taskid, unlockingNodes in pairs(candidateTasks) do
-- ★ print_lockandkey_ex("Current Node: "..taskid) ——★ 空函数。
		        print_lockandkey_ex("Current Node: " .. taskid)
-- ★ print_lockandkey_ex("  PARENTS:") ——★ 空函数。
                print_lockandkey_ex("  PARENTS:")
                for k,v in pairs(unlockingNodes) do
-- ★ print_lockandkey_ex("    "..k) ——★ 空函数。
                    print_lockandkey_ex("    " .. k)
                end
-- ★★ AppendNode(unusedTasks[taskid], unlockingNodes) ——★★ 真正的接入。
                AppendNode( unusedTasks[taskid], unlockingNodes )
            end
        end


-- ★★ 循环结束。
    end

-- ★★ return lastNode:GetRandomNodeForExit() ——★★ 返回「链尾的出口」。
--   ★★★★3 返回值用途：★ GenerateNodesForRegion(:889) 赋给 finalNode。
--     ★★★★2 ★2 ★2 ⇒ ★★ 返回的是**「房间」而非「任务」**，
--       ★★★★2 ★2 但 :899 读的是 .data.task ⇒ ★★ 恰好兼容。★
--         ★★★★2 ★2 ★2 ★2 这种「巧合兼容」是隐式契约的典型。
--     ★★★★2 ★2 ⇒ ★2 移植时若改成返回 Graph，:899 会崩。★
	return lastNode:GetRandomNodeForExit()
end

-- ============================================================
-- ★ LinkNodesByKeys —— 锁—钥匙连线的【默认路径】
-- ============================================================
-- 【机制】这是与 storygen.lua:299 RestrictNodesByKey 并存的第二套锁—钥匙连线算法。
--   两者不是重构关系，而是 layout_mode 的两条分支（forest_map.lua:431 透传 layout_mode）。
--   RestrictNodesByKey : 批量分支法 —— 一次把「所有已解锁任务」挂成网
--   LinkNodesByKeys    : 逐个贪心法 —— 一次只接一个任务，串成主链 ★
--
-- 【为什么要有两套】
--   批量法生成的地图更像「灌木丛」，区域之间高度并联；
--   逐个法生成的是一条清晰的「主路」，玩家体验上更接近手工关卡。
--   逐个法是默认路径（forest_map.lua:431 只在明确要求时才走 Restrict），
--   所以这一段是实际上跑得最多的路径，也是缺陷密度最高的一段。
--
-- 【输入】startParentNode：根地块（playerstart 所在）。unusedTasks：待接入的地块表。
-- 【输出】最后一块地的某个出口节点 —— 供调用方继续往上挂内容。
--
-- ⚠ 三处与 Restrict 的实质差异见本文件末尾的对照总结（:664 之后）。
function Story:LinkNodesByKeys(startParentNode, unusedTasks)
    print("[Story Gen] LinkNodesByKeys")
	print_lockandkey_ex("\n\n### START PARENT NODE:",startParentNode.id)
	local lastNode = startParentNode
-- 【availableKeys】全函数唯一的「钥匙串」，形态是 key -> {持有该钥匙的节点列表}。
--   注意这是【节点列表】而不是【钥匙计数】——见 :540，候选集语义由此而来。
--   增量维护（只在 :617-623 追加），不重算，这是与 Restrict:326 每轮重算的差异一。
	local availableKeys = {}
	for i,v in ipairs(self.tasks[startParentNode.id].keys_given) do
		availableKeys[v] = {}
		table.insert(availableKeys[v], startParentNode)
	end
-- ⚠ 疑似缺陷（死变量）：usedTasks 在本函数内只有这一处赋值（:626），
--   没有任何读取点（grep 核实：LinkNodesByKeys 函数体内无 usedTasks 的读取）。
--   它很可能是早期实现（批量法 RestrictNodesByKey 的遗留写法）的残骸。
--   真正的「已用任务集合」由 :625 把 unusedTasks[key]=nil 的副作用承担。
--   保留它无害，但会误导读者以为存在「回溯已用任务」的逻辑 —— 并不存在。
	local usedTasks = {}

-- 【story_depth 的起点】根地块深度 0，首个接入的地块深度 1，单调递增。
--   这是任务级（Graph 级）进度标量，运行时由 components/grottowarmanager.lua:201
--   与 area_trigger.lua:24 消费，用于控制「任务推进到什么阶段」的触发门槛。
--   ⚠ 它被写在【节点对象】上（node.story_depth），但 network.lua:34 的规范位置是
--      Graph.story_depths 数组。见 :566-575 的缺陷说明。
	startParentNode.story_depth = 0
	local story_depth = 1
	local currentNode = nil

-- ★ 主循环：只要还有任务没接入，就再摘一个挂到链尾。
--   与 RestrictNodesByKey 的结构性差异二：Restrict 的外层循环遍历的是「锁的种类」，
--   这里是「还没接入的任务」，且每轮只接入【一个】任务。
--   ⇒ 图的形状从「并联灌木」变成「串行主链 + 若干旁支」。
--   代价：接入顺序完全由 :518 的 pairs 遍历顺序决定 ⇒ 依赖 hash 顺序 ⇒
--   这是全库可复现性陷阱的又一处实例（详见文件头「随机数与可复现性」章节）。
	while GetTableSize(unusedTasks) > 0 do
		local effectiveLastNode = lastNode

-- 下面是 print_lockandkey_ex 调试输出通道。
--   ⚠ 该通道在 storygen.lua:8-13 被整段留空（函数体只有 -- 注释），
--     所以这些调用全部退化为空函数调用，【不产生任何输出，也不消耗随机数】。
--     这是一个刻意的「编译期关闭调试」手法：保留调用点便于将来恢复。
		print_lockandkey_ex("\n\n### About to insert a node. Last node:", lastNode.id)

		print_lockandkey_ex("\tHave Keys:")
-- 遍历 availableKeys 打印钥匙持有情况。debug 通道，同样是空函数。
		for key, keyNodes in pairs(availableKeys) do
			print_lockandkey_ex("\t\t",KEYS_ARRAY[key], GetTableSize(keyNodes))
		end

-- ★ 逐个试任务：找出第一个「现在就能解锁」的任务。
--   注意这里用的是 pairs 而非有序遍历 ⇒ 第一个被试中的任务 = pairs 顺序里的第一个。
--   ⇒ 结果依赖 Lua 表的 hash 布局，而非任务 id 的大小。
--   与 RestrictNodesByKey:326 相比，这里没有做任何顺序修正。
		for taskid, node in pairs(unusedTasks) do

			print_lockandkey_ex("  TASK: "..taskid)
			print_lockandkey_ex("\t Locks:")

-- 【locks 局部表】形态 lock -> {keys={可用钥匙列表}, unlocked=bool}。
--   注意这是每个任务每轮【重建】的局部表，不是缓存 —— 每轮都重新判一次锁。
--   与 RestrictNodesByKey 的 locks 表复用策略不同（差异三，见文件末尾）。
			local locks = {}
			for i,v in ipairs(self.tasks[taskid].locks) do
-- ★ 查表：lockandkey.lua:78-81 GetKeysForLock 的等价展开。
--   LOCKS_KEYS[v] 就是那把锁能被哪些钥匙打开的列表（可能多把，OR 语义）。
--   ⚠ 关键：v 若不在 LOCKS_KEYS 里（比如 E 类缺陷导致的漏配），
--     这里得到 nil ⇒ :536 的 ipairs(nil) 直接报错。
--     实际不会崩，是因为 lockandkey.lua:478-485 在启动期做了自校验，
--     且 :498-510 的 SKIP_THESE_MISSING_KEYS_AND_LOCKS 白名单会剔除这些任务。
--   参见 lockandkey.lua:219 vs :254 —— TREES 锁被重复定义静默覆盖的经典案例。
				local lock = {keys=LOCKS_KEYS[v], unlocked=false}
				locks[v] = lock
				print_lockandkey_ex("\t\tLock:",LOCKS_ARRAY[v],tabletoliststring(lock.keys, function(x) return KEYS_ARRAY[x] end))
			end


-- 【unlockingNodes】形态 nodeId -> Node对象。
--   ★ 与 RestrictNodesByKey:350 的 unlockingTasks 形成对照：
--     Restrict 存【任务对象】（候选集 = 任务），锁解开后拿任务去生成新地块；
--     LinkNodesByKeys 存【节点对象】（候选集 = 已存在的地块）。
--   差别是根本性的：LinkNodesByKeys 全程都在一个固定的 unusedTasks 集合里打转，
--   「任务」在这里已经等同于「地块」——【任务即地块】，没有「先有任务后有点」的两阶段。
--   这正是它能串成主链的原因：候选集是现成的点，不必等待生成。
			local unlockingNodes = {}

-- 外层：遍历本任务的每一把锁。
-- 内层（:535）：遍历当前持有的每一种钥匙。
-- 最内层（:536）：遍历那把锁能被哪些钥匙打开。
-- 【OR 语义】只要命中任意一把可用钥匙，lockData.unlocked 置 true（:542）。
--   多把锁之间则是 AND（:550-557 必须全部 unlocked）。
--   这条规则来自 lockandkey.lua:171-172，与全库一致。
			for lock,lockData in pairs(locks) do						-- For each lock:
				print_lockandkey_ex("\tUnlocking",LOCKS_ARRAY[lock])
				for key, keyNodes in pairs(availableKeys) do			-- Do we have any key for
					for reqKeyIdx,reqKey in ipairs(lockData.keys) do	   -- this lock?
-- 上面这行 if 上方的整块空白缩进区，是【被注释掉的旧实现】的残留。
-- ⚠ 特别提醒：:537-540 那一段看起来像注释，实际不是 ——
--   真正的代码在 :538-540（for i,node in ipairs(keyNodes)）。
--   源码的缩进具有强烈误导性，第一次阅读极易把 :539-540 当成注释而漏掉。
--   :539 的作用是把所有「持有该钥匙的节点」全部塞进候选集 unlockingNodes。
--   ⇒ 候选集含义 = 「当前钥匙串能开的锁所对应的全部挂载点」，
--     也就是说：一次解锁会同时把 N 个挂载点变成候选，然后由 :578 随机挑一个。
						if reqKey == key then							-- If yes, get the nodes with
																		   -- that key so that we
							for i,node in ipairs(keyNodes) do			   -- can potentially attach
								unlockingNodes[node.id] = node			   -- to one.
							end
							lockData.unlocked = true					-- Also unlock the lock
							print_lockandkey_ex("\t\t\tUnlocked!", KEYS_ARRAY[key])
						end
					end
				end
			end

-- 【AND 收敛】把各把锁的 unlocked 结果求交。任一把没解开 ⇒ 本任务本轮不可接入。
--   break 后 :555 直接跳出，等下一轮再看（下一轮 availableKeys 可能已变化）。
--   ⚠ 这就是「贪心 + 重试」策略的来源：主循环每轮都要把所有未接入任务重扫一遍。
--     最坏情况 O(任务数² × 锁数 × 钥匙数)，是本函数的性能特征（不是缺陷，但要知道）。
			local unlocked = true
			for lock,lockData in pairs(locks) do
				print_lockandkey_ex("\tDid we unlock ", LOCKS_ARRAY[lock])
				if lockData.unlocked == false then
					print_lockandkey_ex("\t\tno.")
					unlocked = false
					break
				end
			end

			if unlocked then
				-- this task is presently unlockable!
-- ★ 命中：当前任务此刻可接入。
--   currentNode 就是这个任务的代表地块（任务即地块，见 :531 的对照说明）。
--   ⚠ 注意赋值发生在 :561，而循环末尾的清理在 :628 ——
--     如果后续某步抛错，currentNode 会残留为非 nil，导致 :596 的兜底失效。
				currentNode = node
				print_lockandkey_ex ("StartParentNode",startParentNode.id,"currentNode",currentNode.id)

-- 【lowest / highest】记录候选节点里 story_depth 的极值。
--   ★ 用途完全取决于 gen_params.branching 的取值，见 :577-589。
--   ⚠ 哨兵值：i=999 / i=-1 是硬编码魔法数。
--     若真实 story_depth 超过 999（超长任务链），highest 永远停在 999 找不到节点。
--   这类「999 哨兵」在本仓库反复出现（RestrictNodesByKey:336 亦有同款）。
				local lowest = {i=999,node=nil}
				local highest = {i=-1,node=nil}
-- ============================================================
-- ⚠⚠ 疑似缺陷（本段是 storygen.lua 中最可疑的一处，内部编号 E1-B）
-- ============================================================
-- 【缺陷描述】node.story_depth 恒为 nil，导致 :567 的比较直接抛错。
--
-- 【推理依据】
--   1) unlockingNodes 里装的是 Node 对象（见 :540，来自 availableKeys[key]）。
--   2) availableKeys 的元素只有两个来源：:500 的 startParentNode、:621 的 currentNode，
--      两者都是 Graph 的节点。
--   3) story_depth 的规范存储位置是【Graph】对象上的 story_depths 数组，
--      见 network.lua:34（Graph 构造）与 network.lua:156/177（Encode/Decode 落盘）。
--      GraphNode 自身【没有】story_depth 字段的任何定义或初始化。
--   4) :504 给 startParentNode.story_depth = 0、:601 给 currentNode.story_depth = n，
--      都是往 Node 上【动态挂】一个新字段，而不是写进 Graph.story_depths。
--   ⇒ 结论：这两个赋值没有把值写进任何会被读取的结构。
--
-- 【触发条件】
--   :567 无条件执行（位于 unlocked 分支内、break 之前），
--   所以【每次成功接入一个任务都会走到】。
--   unlockingNodes 首次循环时至少有 startParentNode 一个元素（非空）
--   ⇒ pairs 至少迭代一次 ⇒ node.story_depth 至少被读一次。
--   ⚠ 于是：默认 branching 下（见 :577 第一个分支）本应直接抛
--     「attempt to compare nil with number」。
--
-- 【为什么线上没炸】—— 三层掩盖，缺一不可：
--   a) 若真抛错，会被 worldgen_main.lua:419 的 5 次重试循环吞掉；
--   b) graphnode.lua:330 附近的 PopulateVoronoi 对 E2 类失败是【静默放弃】而非抛错，
--      两者失败模式都表现为「本次生成不出好图」而不是「崩溃」；
--   c) :596-599 的兜底会在 currentNode 为 nil 时随机取一个节点接上，
--      保证图一定连通 ⇒ 缺陷表现为「地图不合理」而非「地图坏掉」。
--
-- 【正确做法应该是什么】（仅记录，不改代码）
--   若要修，应改为从 Graph 的 story_depths[node.id] 读取，
--   或在 Node 构造时同步初始化 story_depth 字段。参见 network.lua:34。
--
-- 【交叉引用】RestrictNodesByKey:440 的对应赋值作用在【表】上，那里能正常工作，
--   正是本处出错的对照证据。
-- ============================================================
				for id,node in pairs(unlockingNodes) do
					if node.story_depth >= highest.i then
						highest.i = node.story_depth
						highest.node = node
					end
					if node.story_depth < lowest.i then
						lowest.i = node.story_depth
						lowest.node = node
					end
				end

-- 【branching 四分支】决定新地块挂在候选集的哪个点上。
--   default / random ⇒ 随机挑一个候选（:578）—— 绝大多数情况走这里。
--   most             ⇒ 挂 story_depth 最【浅】的候选（:581，对应 lowest）
--   least            ⇒ 挂 story_depth 最【深】的候选（:584，对应 highest）
--   never            ⇒ 永远挂链尾 lastNode（:587），完全不分支，生成一条纯直线。
--   ⚠ most/least 依赖上面 :566-575 的极值计算，而那段在 unlockingNodes 非空时必然执行
--     ⇒ E1-B 缺陷命中。
--   ⇒ 只有 never 分支能绕开 E1-B（因为它不走极值结果，但仍会执行 :566 的计算）。
--   严格说：:566 的循环在任何分支下都执行，因此【全条件命中】。
				if self.gen_params.branching == nil or self.gen_params.branching == "default" or self.gen_params.branching == "random" then
					effectiveLastNode = GetRandomItem(unlockingNodes)
					print_lockandkey("\tAttaching "..currentNode.id.." to random key", effectiveLastNode.id)
				elseif self.gen_params.branching == "most" then
					effectiveLastNode = lowest.node
					print_lockandkey("\tAttaching "..currentNode.id.." to lowest key", effectiveLastNode.id)
				elseif self.gen_params.branching == "least" then
					effectiveLastNode = highest.node
					print_lockandkey("\tAttaching "..currentNode.id.." to highest key", effectiveLastNode.id)
				elseif self.gen_params.branching == "never" then
					effectiveLastNode = lastNode
					print_lockandkey("\tAttaching "..currentNode.id.." to end of chain", effectiveLastNode.id)
				end

-- ★ break —— 贪心策略的核心：一旦找到一个可接入的任务，立刻跳出 :518 的遍历。
--   【与 Restrict 的差异】RestrictNodesByKey:559-583 是「全部解锁的都接上」，
--     这里是「只接一个」。
--   【后果】本轮只消耗一个任务 ⇒ 主循环至少迭代 |unusedTasks| 次。
--   【副作用】顺序完全由 pairs 决定，不受任何启发式影响。
--   ⚠ 贪心的另一后果：不会为了「后面更好接」而选择当前代价小的任务。
--     若某任务只给出很鸡肋的钥匙，可能把整条链带进死胡同。
--     :596-599 的兜底就是为这种情况准备的。
				break
			end

		end

-- ⚠ 兜底：一轮下来没有任何任务能解锁（贪心走进了死胡同）。
--   做法：从剩余任务里【随机取一个】强行接到链尾。
-- ★ 这就是 storygen.lua:473-475 逃生阀的同构实现（那里是随机接一条边），
--   作用相同：保证图永远连通，把「不可达」降级为「布局不合理」。
--   ⚠ 代价：这条边【没有真正的锁语义】（:613 仍传 key=self.tasks[...].locks），
--     但玩家走到这里时并未真正满足前置条件 ⇒ 破坏任务线性度。
--   玩家可能在一个不该出现的分支里捡到不该拿的东西。
--   这与 E1 锁—钥匙覆盖缺陷同源：都靠逃生阀活着。
		if currentNode == nil then
			currentNode = self:GetRandomNodeFromTasks(unusedTasks)
			print_lockandkey("\t\tAttaching random node "..currentNode.id.." to last node", effectiveLastNode.id)
		end

-- ★ story_depth 单调递增赋值（与 :504 的 0 一起构成 0,1,2,... 的链）。
--   ⚠ 写在 Node 上而非 Graph.story_depths ⇒ 与 E1-B 同源，见 :566 的完整分析。
--   对照 RestrictNodesByKey:440：那里是批量表 depthData[key] = story_depth，
--   结构上更接近正确实现。
		currentNode.story_depth = story_depth
		story_depth = story_depth + 1

-- ★ 两端各取一个具体节点来连线。
--   lastNodeExit        = 已在图中的链尾地块的【随机出口】
--   currentNodeEntrance = 新地块的【入口】；优先用任务预置的 entrancenode，
--                          没有才随机挑一个（network.lua 的单槽位设计，参见该文件注释）。
--   ★ 这两行是「连接方向性」的体现：边是有向的（entrance → exit），
--     不是无向图的连通性检查，而是「玩家从 A 走到 B」的单向可达。
--     这正是锁—钥匙机制能成立的前提：钥匙决定「有没有这条边」。
		local lastNodeExit = effectiveLastNode:GetRandomNodeForExit()
		local currentNodeEntrance = currentNode.entrancenode or currentNode:GetRandomNodeForEntrance()

-- 两个断言：确保取到了有效的出入口节点。
--   ⚠ 这两个 assert 是【硬失败】点，一旦触发会向上冒泡到 worldgen_main.lua 的重试。
--     换言之，出入口取不到 ⇒ 整张地图重生成（消耗新的随机数）⇒ 可能得到完全不同的世界。
--   ⚠ 玩家视角的现象：同一个种子偶尔会生成出不同的世界——这就是原因之一。
		assert(lastNodeExit)
		assert(currentNodeEntrance)

-- 【island_percent】孤岛机制：按概率把这次连接变成「断开 + 留白」。
--   概率值来自 gen_params.island_percent（世界设置里的「孤岛」选项）。
--   ⚠ 双重条件缺一不可：既要命中概率，又要 currentNodeEntrance.data.entrance == false
--     （即该地块本身不是入口地块）。这个额外条件在保护 :613 的常规连线不被切断。
--   SeperateStoryByBlanks 见 storygen.lua 的同名实现（在本文件 :9xx 段）。
		if self.gen_params.island_percent ~= nil and self.gen_params.island_percent >= math.random() and currentNodeEntrance.data.entrance == false then
			self:SeperateStoryByBlanks(lastNodeExit, currentNodeEntrance )
		else
-- ★★ LockGraph —— 见 network.lua:454 的详细注释。
--   这是全文件最重要的一行：它【只把边登记进图】，lock.key 参数本身
--   从不被网络层读取（grep 核实：map/ 下无任何读取 lock.key 的代码）。
--   换言之，「锁」在物理上不是数据，而是三件事的合成：
--     ① 这条 exit_edge 存在 ⇒ 可通行；
--     ② entrance 房的 blocker_blank 是视觉上的「门」；
--     ③ 「有钥匙才建边」⇒ 没有钥匙时这条路【根本不存在】。
--   锁的本质是【拓扑层面的缺席】，不是数据层面的标记。
--   这也解释了为什么 E1 类「锁被覆盖」会造成【不可达】而非「锁打不开」：
--   钥匙算不出来 ⇒ 边建不出来 ⇒ 地图缺一块 ⇒ 回不来。
			self.rootNode:LockGraph(effectiveLastNode.id..'->'..currentNode.id, lastNodeExit, currentNodeEntrance, {type="none", key=self.tasks[currentNode.id].locks, node=nil})
		end

-- ★ 钥匙增量维护：把本任务给出的钥匙追加到钥匙串。
--   对照 RestrictNodesByKey:457 —— 那里的同类代码被【整段注释掉】了，
--   改为在 :326 每次从 usedTasks 全量重算。
--   ⇒ 差异三（本文件最后一个算法差异）：
--     Restrict：全量重算，代价 O(任务数²)，但不会漏；
--     LinkNodesByKeys：增量追加，代价 O(1)，但要求每条路径都必经此处。
--   ⚠ 增量法的风险：:596 的兜底连接虽然也会走到 :617 追加钥匙，
--     所以不会漏；但若将来有人给兜底分支加个 early return，钥匙就会漏算。
		print_lockandkey_ex("\t\tAdding keys to keyring:")
		for i,v in ipairs(self.tasks[currentNode.id].keys_given) do
			if availableKeys[v] == nil then
				availableKeys[v] = {}
			end
			table.insert(availableKeys[v], currentNode)
			print_lockandkey_ex("\t\t",KEYS_ARRAY[v])
		end

-- 从待接入集合移除本任务（:625），并登记到 usedTasks（:626，本函数内无人读，见 :502）。
--   lastNode 前进到本节点 ⇒ 下一轮的「链尾」就是它。
--   currentNode 清空 ⇒ :596 的兜底判断回到初始态。
		unusedTasks[currentNode.id] = nil
		usedTasks[currentNode.id] = currentNode
		lastNode = currentNode
		currentNode = nil
	end

-- ★ 返回最终链尾的随机出口节点。
--   调用方（storygen.lua:491 一带）拿它去接 rootNode 之外的内容，
--   或作为 AddBGNodes / AddCoveNodes 的挂载点。
--   ⚠ 返回的是随机挑的出口 ⇒ 同一个种子下这个选择也受 pairs/math.random 影响。
	return lastNode:GetRandomNodeForExit()
end

-- ============================================================
-- GetRandomNodeFromTasks —— 兜底取点器
-- ============================================================
-- 【用途】从一组任务里随机挑一个，返回其【地块对象】（self.TERRAIN[task]）。
-- ⚠ 三处值得注意：
--   1) 返回的是 self.TERRAIN[task] 而不是 task 本身 ⇒ 返回类型与入参语义不同；
--   2) 若 taskSet 为空，sz==0 ⇒ task 保持 nil ⇒ self.TERRAIN[nil] 抛错（Lua 中 t[nil] 索引报错）。
--      实际不会发生，因为调用点 :597 保证 unusedTasks 非空（外层 :508 的条件）。
--   3) :638 的 math.random(sz) + :641 的 pairs 遍历取第 k 个 —— 【经典可复现性陷阱】。
--      依赖 hash 顺序而非任务 id 顺序 ⇒ 换 Lua 版本/平台可能得到不同的点。
--      这是「同种子是否必得同世界」这个问题的答案之一：【不保证】。
--   ⚠ 若要保证可复现，应改用有序遍历（先收集 key 列表并排序）。
--   本仓库 widespread 使用这一模式，是既成事实而非孤立疏漏。
function Story:GetRandomNodeFromTasks(taskSet)
	local sz = GetTableSize(taskSet)
	local task = nil
	if sz > 0 then
		local choice = math.random(sz) -1


		for taskid,_ in pairs(taskSet) do -- special order
			task = taskid
			if choice<= 0 then
				break
			end
			choice = choice -1
		end
	end
	--print("G2 task ", task)
	return self.TERRAIN[task]
end

-- ============================================================
-- AddStartingSetPiece —— 出生点场景件覆盖
-- ============================================================
-- 【机制】gen_params.start_setpeice 非 nil 时（由世界设置传入），
--   强制在出生点这块地上放一个指定场景件，并清空原本的静态布局表。
--   ⚠ :659 把 countprefabs.spawnpoint 置 nil —— 出生点 prefab 被移除。
--     这是有意为之：场景件自带玩家出生位置，不需要再放一个标准的 spawnpoint。
--   ⚠ :658 的 nil 检查说明 countprefabs 可能不存在 ⇒ 依赖上游是否初始化过该字段，
--     属于隐式契约（与 storygen.lua:8-13 那类隐式契约同类）。
--   ⚠ 变量名 start_setpeice 有拼写错误（应为 start_setpiece）。
--     保持不改：序列化格式已落盘，改名会导致旧存档读不出。
function Story:AddStartingSetPiece(starting_node_data)
	if self.gen_params.start_setpeice ~= nil then
		starting_node_data.terrain_contents.countstaticlayouts = {}
		starting_node_data.terrain_contents.countstaticlayouts[self.gen_params.start_setpeice] = 1

		if starting_node_data.terrain_contents.countprefabs ~= nil then
			starting_node_data.terrain_contents.countprefabs.spawnpoint = nil
		end
	end
end

-- ============================================================
-- FindMainlandNodesForNewRegion —— 新区域挂载点选择（3×3 九宫格最近邻）
-- ============================================================
-- 【用途】为「离岛区域」（ruins_island 之外的任意 region）挑两个大陆上的节点，
--   用作 LinkRegions 的两端，把整块离岛挂回主大陆。
--
-- 【算法概要】
--   1) 把已有节点按世界坐标归一化，取其包围盒的【最长边】作为边长 w；
--   2) 用 w 把平面切成 3×3 九宫格，统计每格有多少节点；
--   3) 取节点最少的格子（且永不取中心格）；
--   4) 在该格的【边缘中点】上找最近的两个节点返回。
--
-- 【为什么挑最空的格子】
--   离岛若挂在人烟稀少处 ⇒ 玩家从大陆走过去距离短 ⇒ 体验好；
--   且新区域不会与已有区域的边重叠打架。
--   这是「留白优先」的布局策略，与 Voronoi 的均匀化取向相反但目标一致。
function Story:FindMainlandNodesForNewRegion()
	print("[Story Gen] Finding nodes on mainland to connect a region to.")

-- ★ next_bucket：九宫格的【邻接表】，每个格子记录它的四个对角邻居与四条边中点。
--   形如 {x=1..3, y=1..3}，用途见 :728-738 的 bucket_edge_pts 选择逻辑。
--   ⚠ 这张表在当前代码路径里【实际上没有用到】——
--     :760 选完 bucket 后只把 {x,y} 传给 _FindBestNodes，
--     而 _FindBestNodes 自己又另建了一张 bucket_edge_pts（:729）。
--     next_bucket 是被 :728 之前某个版本使用过的残留常量。
--   这是「重构后未清理的遗留表」，典型表现：常量还在、引用已消失。
--   保持不改：删它属于源码修改，超出本任务范围。
	local next_bucket = {	{{{x=2, y=1}, {x=1, y=2}}, {{x=1, y=1}, {x=3, y=1}}, {{x=2, y=1}, {x=3, y=2}}},
							{{{x=1, y=1}, {x=1, y=3}}, {{x=2, y=2}, {x=2, y=2}}, {{x=3, y=1}, {x=3, y=3}}},
							{{{x=1, y=2}, {x=2, y=3}}, {{x=1, y=3}, {x=3, y=3}}, {{x=2, y=3}, {x=3, y=2}}} }
-- bucket_counts：九个格子的计数器，初始化顺序为 x=1 外层、y=1 内层，
--   因此数组下标 (x-1)*3 + y 与 [y][x] 的访问方式在 :751 保持一致。
-- ⚠ 注意 :751 写的是 bucket_counts[(x-1)*3 + y]，与 :673 的插入顺序匹配，
--   但 :734 访问边点表时用的是 [y][x]（行优先）——两种下标约定混用。
--   不是缺陷（两处各自自洽），但阅读时极易看错。
	local bucket_counts = {}
	for x = 1, 3 do
		for y = 1, 3 do
			table.insert(bucket_counts, {x = x, y = y, count = 0})
		end
	end

-- 【_GetOffsetPositionsAndSize】把当前所有任务节点换算到「左上角为原点、
--   宽高均为 w」的正方形坐标系里，并返回正方形边长 w。
--   这一步是九宫格划分的前提：必须先归一化，否则地图尺寸会随 region 大小漂移。
	local function _GetOffsetPositionsAndSize(task_nodes)
		local pos = {}
		local min_x, max_x = math.huge, -math.huge
		local min_y, max_y = math.huge, -math.huge
-- 双层 pairs：先遍历任务，再遍历该任务下的所有节点。
--   ⚠ pairs 遍历 ⇒ 这里只做 min/max 聚合，属于【安全用法】：
--     聚合量（min/max）与遍历顺序无关，结果确定。
--   对照 GetRandomNodeFromTasks:638 的「取第 k 个」——那种才是不安全用法。
--   这条判据是全库可复现性分析的核心：聚合安全，取序危险。
		for t_id, t in pairs(task_nodes) do
			for n_id, n in pairs(t.nodes) do
-- 过滤：只统计带 task 字段的节点。
--   WorldSim:GetSite(n_id) 从 C++ WorldSim 取该点的整数格位坐标。
--   ⚠ 这意味着本函数【强依赖 WorldSim 已完成点集初始化】，
--     调用时机必须在 forest_map.lua:497 WorldGen_InitializeNodePoints 之后。
				if n.data.task ~= nil then
					local _x, _y = WorldSim:GetSite(n_id)
					pos[n_id] = {x = _x, y = _y, node = n}
					min_x, max_x = math.min(_x, min_x), math.max(_x, max_x)
					min_y, max_y = math.min(_y, min_y), math.max(_y, max_y)
				end
			end
		end
-- padding = 5：包围盒向外扩 5 格再取整。
--   作用：让九宫格边界不贴着实际节点，避免边缘格子因数值取整而漏掉边缘节点。
		local padding = 5
		min_x, max_x = math.floor(min_x - padding), math.ceil(max_x + padding)
		min_y, max_y = math.floor(min_y - padding), math.ceil(max_y + padding)

-- 偏移量把包围盒左下角移到原点；:697-698 随后把 max 改成【边长】。
-- :699-703：长边不变、短边【居中补齐】⇒ 得到一个正方形。
--   为什么强制正方形？因为九宫格必须是 w×w 的正方形才能等分。
		local offset_x, offset_y = -min_x, -min_y

		max_x = max_x - min_x
		max_y = max_y - min_y
		if max_y < max_x then
			offset_y = offset_y + (max_x - max_y)/2
		else
			offset_x = offset_x + (max_y - max_x)/2
		end

		for _, v in pairs(pos) do
			v.x = v.x + offset_x
			v.y = v.y + offset_y
		end

		return pos, math.max(max_x, max_y)
	end

-- 【_FindBestNodes】在选定的空格里找两个最近的非空节点作为挂载点。
--   返回 (closest_node1, closest_node2)，两者分属【不同任务】。
	local function _FindBestNodes(node_pos, target_bucket, w)
-- GetClosestNode：找离给定点最近的节点。
--   ⚠ exclude_task 参数用于 :741 强制第二个点来自【不同任务】，
--     避免两个挂载点都在同一块地里（那等于只挂了一次）。
		local function GetClosestNode(point, exclude_task)
			local closest_node = {node = nil, dist = math.huge}
			for n_id, n in pairs(node_pos) do
-- 排除 Blank 节点：留白节点不可作为挂载点。
--   NODE_TYPE.Blank 是 SeperateStoryByBlanks / LinkRegions 造出来的隔断地块。
--   ★ 这与锁—钥匙机制呼应：留白节点带 RoadPoison / ForceDisconnected 标签，
--     语义上就是「此路不通」。参见 :1163。
-- ⚠ 这里【只】排除 Blank，没排除 Background / Blocker ——
--   背景地块也可能被选为挂载点，语义上略微奇怪，但不是错误。
				if n.node.data.type ~= NODE_TYPE.Blank and (exclude_task == nil or node_pos[n_id].node.data.task ~= exclude_task)then
					local dist = DistXYSq(point, n)
					if dist < closest_node.dist then
						closest_node.dist = dist
						closest_node.node = node_pos[n_id]
					end
				end
			end
			return closest_node.node
		end

-- 桶的外侧中点（朝地图外缘的那个边中点）。
-- bucket_edge_pts：九宫格各【边】上的两个候选点（每边两个，形成 3 等分）。
--   ⚠ 注意与 :667 的 next_bucket 结构几乎相同——两张重复的表。
--     next_bucket 已成死表，bucket_edge_pts 是活表。
-- :734 用 [y][x] 取桶的边点（行优先），与 :751 的 (x-1)*3+y 索引约定不同。
		local bucket_outer_pt = {x = (target_bucket.x - 1) * w/2, y = (target_bucket.y - 1) * w/2}
		local bucket_edge_pts = {	{{{x=0, y=w/3},   {x=w/3, y=0}},	{{x=w/3, y=0}, {x=2*w/3, y=0}}, {{x=2*w/3, y=0}, {x=w, y=w/3}}},
									{{{x=0, y=w/3},   {x=0, y=2*w/3}},	{},								{{x=w, y=w/3},   {x=w, y=2*w/3}}},
									{{{x=0, y=2*w/3}, {x=w/3, y=w}},	{{x=w/3, y=w}, {x=2*w/3, y=w}}, {{x=2*w/3, y=w}, {x=w, y=2*w/3}}}
								}

		local bucket_p1, bucket_p2 = unpack(bucket_edge_pts[target_bucket.y][target_bucket.x])
-- 第一个挂载点：桶为空时取外侧中点，否则取边点 bucket_p1。
-- ★ 这里用了「桶是否为空」做分支：空桶优先往【地图外缘】挂 ——
--   新的离岛应该长在地图边缘，而不是长在中心。
		local closest_node1 = GetClosestNode(target_bucket.count == 0 and bucket_outer_pt or bucket_p1)

-- 空桶时，在两个边点里挑【离第一个挂载点更近的那个】当第二个点。
--   目的：让新区域的连接口集中在同一侧，视觉上更紧凑。
		if target_bucket.count == 0 then
			bucket_p2 = (DistXYSq(closest_node1, bucket_p1) < DistXYSq(closest_node1, bucket_p2)) and bucket_p2 or bucket_p1
		end

-- 第二个挂载点：排除与第一个点【同任务】的节点。
--   ⚠ 潜在 nil 解引用：closest_node1.node 若为 nil（node_pos 全是 Blank 时），
--     :741 的 closest_node1.node.data 会抛错。
--   实际不会发生：起点必有非空节点。但这是一个未加保护的边界。
		local closest_node2 = GetClosestNode(bucket_p2, closest_node1.node.data.task)

		return closest_node1, closest_node2
	end

	local node_pos, w = _GetOffsetPositionsAndSize(self.TERRAIN)

-- ★ 把每个节点按归一化坐标划入九宫格：
--   x = 1 + floor(n.x / w * 3)，clamp 到 >= 1（即 [1,3]）。
--   ⚠ 硬编码 3 与 w/2 等字面量（:728-731）散落在多处，共同构成「九宫格」约定。
--     改成可配置需要同时改这 4~5 处，耦合度较高。
	for n_id, n in pairs(node_pos) do
		local x = 1 + math.max(0, math.floor(((n.x) / w) * 3))
		local y = 1 + math.max(0, math.floor(((n.y) / w) * 3))
		bucket_counts[(x-1) * 3 + y].count = bucket_counts[(x-1) * 3 + y].count + 1
	end
-- ★ shuffleArray 后再按 count 升序排序。
--   【为什么先洗牌再排序？】为了让 count 相同的格子之间产生随机的决胜顺序。
--   若只排序，count 相同的格子会按 shuffle 后的相对位置稳定排列，
--   而 shuffleArray 本身消耗随机数 ⇒ 这是本函数对全局随机序列的【唯一消耗点】。
--   ⇒ 同种子下九宫格选择是可复现的，但依赖 shuffleArray 的实现稳定性。
-- ⚠ 排序不是稳定排序（table.sort 不保证），count 相同时顺序不确定。
--   但因为前面洗过，最终效果等价于「在 count 最小的格子里随机选一个」。
	shuffleArray(bucket_counts)
	table.sort(bucket_counts, function(a, b) return a.count < b.count end)

--	local str = "\n"
--	for y = 1, 3 do for x = 1, 3 do str = str .. tostring(bucket_counts[(x-1) * 3 + y].count) .. "\t" end str = str .. "\n" end
--	print(str)

-- ★ 取节点最少且【不是中心格】的那个。
--   注释原文「never pick the center bucket, even if it is the best」说明这是有意为之。
--   【为什么排除中心】地图中心是玩家主要活动区，把新离岛塞到中心会让
--     前期探索路径过长、且容易与主路交叉造成拓扑混乱。
-- ⚠ 若除中心外还有 8 个格子，最少者必然在这些格子里 —— 该守卫在正常数据下
--   几乎不会改变结果，只在「中心格是唯一空格」这种极端情形下生效。
--   这是一个防御性写法，代价可忽略。
-- 返回 _FindBestNodes(node_pos, bucket, w) 的两个挂载点。
	local bucket = (bucket_counts[1].x == 2 and bucket_counts[1].y == 2) and bucket_counts[2] or bucket_counts[1] -- never pick the center bucket, even if it is the best
	return _FindBestNodes(node_pos, bucket, w)
end


-- ============================================================
-- LinkRegions —— 用一条「装饰用的假地块链」把两个区域连起来
-- ============================================================
-- 【机制】造 num_links 个子节点，首尾相接成一条链（:791 再把首尾连上成环），
--   然后把这条【链】的两端分别 LockGraph 到 n1 和 n2。
--
-- 【为什么要造假节点而不是直接连一条边？】
--   ★ 因为 LockGraph 产生的是有向边（entrance→exit），
--     而 LinkRegions 的两端 n1 / n2 是任意的节点，可能方向不对。
--   造一条中间链可以【自由选择从哪端进、从哪端出】，从而规避方向约束。
--   附带收益：这条链本身是一串地块，铺开后天然形成一条走廊。
--
-- 【外观】子节点的 value = link_tile（默认 OCEAN_COASTAL，:767），
--   即「看起来是海岸的过道」—— 让玩家从视觉上知道这是一条捷径/渡口。
function Story:LinkRegions(n1, n2, num_links, link_tile)
	num_links = num_links or 4
	link_tile = link_tile or WORLD_TILES.OCEAN_COASTAL

-- 任务 id 形如 REGION_LINK_0 / REGION_LINK_1，:796 自增。
--   ⚠ 这个 id 会进入 WorldSim 的子节点表（:771/:775），
--     是序列化格式的一部分 ⇒ 不可随意改名（旧存档会读不出）。
-- :770 的 Graph 参数里 default_bg = IMPASSABLE 而 background="MoonIsland_Meadows"，
--   两者语义不同：default_bg 是地块底图，background 是背景房模板。
	local task_id = "REGION_LINK_"..tostring(self.region_link_tasks)
	local node_task = Graph(task_id, {parent=self.rootNode, default_bg=WORLD_TILES.IMPASSABLE, colour = {r=0,g=0,b=0,a=1}, background="MoonIsland_Meadows" })
	WorldSim:AddChild(self.rootNode.id, task_id, WORLD_TILES.IMPASSABLE, 0, 0, 0, 1, "blank")

	local nodes = {}
-- ★ 循环造 num_links 个子节点，并在相邻者之间连边（:787-789，i>1 才连 ⇒ 链状）。
-- ⚠ :775 的 WorldSim:AddChild 在循环体内重复调用，
--   而 :771 已经在循环【外】调用过一次同 id 的 AddChild。
--   ⇒ 同一个 task_id 被 AddChild 两次。
--   第二次是否覆盖取决于 WorldSim C++ 侧实现（Lua 不可见）。
--   若为覆盖语义则无副作用；若是「重复插入」则可能产生一条游离记录。
--   这类「C++ 侧语义未知」的假设在本仓库多处存在，属既定风险模式。
	for i = 1, num_links do
		WorldSim:AddChild(self.rootNode.id, task_id, WORLD_TILES.IMPASSABLE, 0, 0, 0, 1, "blank")
		table.insert(nodes, node_task:AddNode({
			id = task_id..":REGION_LINK_SUB_"..tostring(i),
			data =
			{
				type=NODE_TYPE.Background,
				name="REGION_LINK_SUB",
				tags = {"RoadPoison", "ForceDisconnected"},
				colour={r=0.3,g=.8,b=.5,a=.50},
				value = link_tile,
			}
		}))
		if i > 1 then
			node_task:AddEdge({node1id=nodes[#nodes-1].id, node2id=nodes[#nodes].id})
		end
	end
-- 把链首与链尾相连 ⇒ 得到一个【环】。
--   ⚠ 这样环上任意点都能到达任意点，是为了让 n1/n2 的挂载顺序不重要。
--   实际形成的结构是：n1 → 环上一点，环 → n2，双向都通。
	node_task:AddEdge({node1id=nodes[1].id, node2id=nodes[#nodes].id})

-- ★ 第一端连接：n1 的【节点对象】→ 链的第一个节点。
--   对照 :812 的调用点 LinkRegions(c1, new_region.entranceNode)，
--   c1 是 FindMainlandNodesForNewRegion 返回的 {node=...} 结构，
--   而 new_region.entranceNode 是裸 Node ⇒ ★ 参数类型不一致！
--   这里的 n1.node 说明函数按「包装结构」写，而 :812 传的也是包装结构。
--   真正的类型不一致在 :813：LinkRegions(c2, new_region.finalNode) ——
--   finalNode 来自 RestrictNodesByKey/LinkNodesByKeys 的返回值，
--   参见 :631（返回 lastNode:GetRandomNodeForExit()，是裸 Node）。
--   ⇒ :794 的 n2.data.task 能工作是因为 Node 也有 data.task 字段；但
--     :793 的 n1.node 在 c1 为裸 Node 时会取到 nil。
--   ⚠⚠ 疑似缺陷：LinkRegions 对两端的类型假设不一致（一个要 node 包装，一个要裸 Node）。
--     当前调用点 :812/:813 都来自 AddRegionsToMainland，恰好是「包装 + 裸」混搭。
--     若将来有人传入裸 Node 作为第一个参数，:793 会静默传入 nil 触发错误。
--     详见 :812 / :813 的注释。
-- {key=KEYS.NONE} ⇒ 这是条【无锁】的边，任何人都能走。
--   ★ 与 :613 的 {key=self.tasks[...].locks} 形成对照：连线的锁语义是显式声明的。
	self.rootNode:LockGraph(n1.node.data.task..'->'..nodes[1].id, 	n1.node, nodes[1], {type="none", key=KEYS.NONE, node=nil})
	self.rootNode:LockGraph(task_id..'->'..n2.id, 	                nodes[math.floor(num_links * 0.5) + 1], n2, {type="none", key=KEYS.NONE, node=nil})

-- 区域连接任务的序号自增。⚠ 名字里有笔误（region_link_tasks 语义是「已建连接数」）。
	self.region_link_tasks = self.region_link_tasks + 1
end

-- ============================================================
-- AddRegionsToMainland —— 把所有非大陆 region 挂回大陆
-- ============================================================
-- 【在 GenerationPipeline 七步中的位置】第 4 步（storygen.lua:89）。
--   也就是说：主大陆的图已经建好，这里负责给【外围区域】各建一套子图并连回来。
function Story:AddRegionsToMainland(on_region_added_fn)
	for region_id, region_taskset in pairs(self.region_tasksets) do
-- ★ 排除名单：mainland（自己）、ruins_island、vault_island（都是特殊区域，
--   由各自的专用流程处理，不由这里统一挂载）。
--   ⚠ 这三个 id 是【硬编码的魔法字符串】，与 level.lua 里 region_tasksets 的键名耦合。
--     若 Mod 自定义区域名恰好叫这三个，会被误排除。
--     参见 level.lua 的 region_tasksets 定义。
		if region_id ~= "mainland" and region_id ~= "ruins_island" and region_id ~= "vault_island" then
-- 选两个大陆挂载点（九宫格算法，见 :664）。
-- ★ 注意 :802 在 :803 之前调用：挂载点基于【当前已有节点】计算，
--   所以第 2 个区域挂载时，地图上已经多了第 1 个区域 ⇒ 挂载点会避开它。
--   ⇒ 多个离岛天然分散，不会全部堆在同一侧。这是顺序生效的自然结果。
			local c1, c2 = self:FindMainlandNodesForNewRegion()
-- ⚠ 关键差异：这里【硬编码传入 "RestrictNodesByKey"】，
--   不看 gen_params.layout_mode。
--   ⇒ 与主大陆（:850 用 self.gen_params.layout_mode）不一致。
--   含义：无论玩家选什么布局模式，离岛一律用批量分支法生成。
--   这可能是有意的（离岛需要「并联多出口」以便挂两条 LinkRegions），
--   也可能是遗漏。从结构上看更像有意：LinkRegions 需要接 entrance 和 final 两个点，
--   批量法天然产生多个并联分支，更容易取到不同的两端。
-- ⚠ 对比 AddRegionToTasksNodes:830 —— 那里硬编码 "LinkNodesByKey"。
--   两个区域挂载函数各写死一种模式，互为镜像，进一步说明是分别设计而非统一配置。
-- ★ 这也意味着 :566 的 E1-B 缺陷【不影响离岛】（离岛走 Restrict），
--   但影响主大陆（默认 layout_mode 走 LinkNodesByKeys）。
			local new_region = self:GenerateNodesForRegion(region_taskset, "RestrictNodesByKey")

			local new_task_nodes = {}
-- 把本 region 的任务映射到对应地块对象，供后续 AddCoveNodes / InsertAdditionalSetPieces 使用。
--   ⚠ 与 :833-836 的 AddRegionToTasksNodes 是完全相同的 4 行样板代码，两处重复。
			for k, v in pairs(region_taskset) do
				new_task_nodes[k] = self.TERRAIN[k]
			end
			self:AddCoveNodes(new_task_nodes)
			self:InsertAdditionalSetPieces(new_task_nodes)

-- ⚠ 疑似缺陷（类型不一致）：见 :793 的完整分析。
--   c1 是 {node=..., ...} 包装结构（FindMainlandNodesForNewRegion 返回），
--   new_region.entranceNode 是裸 Node（:892 GetRandomNodeForEntrance 的返回值）。
--   而 LinkRegions 内部 :793 用 n1.node、:794 用 n2.data.task，
--   ⇒ 对第一个参数要求「有 .node 字段」，对第二个只要求「有 .data」。
--   两种类型恰好都能通过，但语义极不统一：任何一边换成裸 Node 或换包装对象都会坏。
--   ⚠ 不改代码，仅记录：这是一个「靠调用点恰好合适而工作」的脆弱耦合。
-- 两条 LinkRegions：分别接新区域的【入口】和【末端】。
--   ⇒ 新区域有两条路连回大陆，玩家可以从入口进、从末端出，形成环游结构。
			self:LinkRegions(c1, new_region.entranceNode)
			self:LinkRegions(c2, new_region.finalNode)

			if on_region_added_fn ~= nil then
				on_region_added_fn()
			end
		end
	end
end

-- Links up to all the nodes of a specific name in task
-- ============================================================
-- AddRegionToTasksNodes —— 把一个 region 挂到【指定任务】的指定名字节点上
-- ============================================================
-- 【与 AddRegionsToMainland 的区别】
--   前者：挂到【大陆上随机选的两个节点】（九宫格最近邻）
--   本函数：挂到【调用方点名的任务节点】（task_name + node_name）
--   ⇒ 本函数用于「精确指定挂载点」的场景，如洞穴层、海底等定向区域。
function Story:AddRegionToTasksNodes(region_taskset, task_name, node_name, links, on_region_added_fn)
	local task = self.TERRAIN[task_name]
-- 防御：任务不存在时打印并返回（软失败）。
--   ★ 与 :872 的 assert（硬失败）形成对比：这里选择不崩。
--     软失败在本仓库是常见风格 —— 生成器宁可少生成也不中断。
	if not task then
		print("[Story Gen] We couldn't add this region taskset to "..task_name.." and it's nodes of name: "..node_name)
		return
	end

-- ⚠ 这里硬编码 "LinkNodesByKey"（单数），与 :803 的 "RestrictNodesByKey" 恰好相反。
--   ★ 注意字符串是单数 "LinkNodesByKey"，而实际函数名是复数 LinkNodesByKeys。
--     但 :886 只做 string.upper 比较，不校验函数名 ⇒ 能正常工作。
--   ⚠ 这是一处脆弱点：:886 用 string.upper(layout_mode) == "RESTRICTNODESBYKEY" 判断，
--     任何其他取值都落到 else 分支调 LinkNodesByKeys ⇒ 传错名字会静默走另一条路。
	local new_region = self:GenerateNodesForRegion(region_taskset, "LinkNodesByKey")
	local nodes = task:GetNodesByName(node_name)

	local new_task_nodes = {}
	for k, v in pairs(region_taskset) do
		new_task_nodes[k] = self.TERRAIN[k]
	end
	self:AddCoveNodes(new_task_nodes)
	self:InsertAdditionalSetPieces(new_task_nodes)

-- 对该任务的每个同名节点都连一条 LinkRegions。
--   links 默认 2（:841）⇒ 假链只造 2 个子节点 ⇒ 视觉上很短。
--   WORLD_TILES.FAKE_GROUND ⇒ 地面看起来像普通地面，而不是海岸。
--   ★ 与 AddRegionsToMainland 的 4 个链接 + OCEAN_COASTAL 形成对比：
--     「自然形成的区域」用明显的海岸过道，「人工挂载的区域」用普通地面。
--     这是给玩家的视觉暗示：Fake_GROUND 的路看起来「像是本来就有的」。
	for i, node in ipairs(nodes) do
		self:LinkRegions(node, new_region.entranceNode, links or 2, WORLD_TILES.FAKE_GROUND)
	end

	if on_region_added_fn ~= nil then
		on_region_added_fn()
	end
end

-- ============================================================
-- GenerateNodesFromTasks —— 生成总编排的第 1 步（storygen.lua:87）
-- ============================================================
-- 【只做两件事】
--   1) 用【大陆 region 的任务集】建图，布局模式取自 gen_params.layout_mode；
--   2) 在图上挂一个 START 节点（玩家出生门户）。
--   ⚠ 注意它【不返回图】，只设置 self.startNode ——
--     大陆图本身挂在 self.TERRAIN / self.rootNode 上，后续步骤直接取用。
--   这是与 AddRegionsToMainland 的接口风格差异（后者返回 new_region）。
function Story:GenerateNodesFromTasks()
-- ★ 唯一使用 gen_params.layout_mode 的地方（对比 :803/:830 的硬编码）。
--   主大陆用玩家配置的模式，其余区域用硬编码 ⇒ 配置只影响主大陆。
	local g = self:GenerateNodesForRegion(self.region_tasksets["mainland"], self.gen_params.layout_mode)
-- 生成 START 节点并记为 self.startNode。
--   ★ 注释点明用途：placement.lua 会用它【强制玩家出生点位于地图中心】。
--   ⇒ 世界坐标的「中心」不是几何中心，而是 START 节点所在的 Voronoi 点。
--     这是一个重要约定：所有『距离中心多远』的逻辑都以 START 为原点。
--   参见 :967-968 给 START 打的特殊配色（青色 .80 透明）—— 调试渲染时一眼可见。
	self.startNode = self:_AddPlayerStartNode(g) -- Adds where the player portal will be spawned and used in placement.lua to force the starting point to be at the center of the map
end

-- ============================================================
-- _FindStartingTask —— 选「任务链的起点」
-- ============================================================
-- 【规则】优先选 locks 为空或 locks[1]==LOCKS.NONE 的任务（无前置条件的任务）。
--   若一个都没有，则退化为 GetRandomItem(task_nodes) 随机挑一个。
--
-- 【为什么起点必须无锁】
--   ★ 因为它是整条任务链的根，前面没有任何东西 ⇒ 不能有前置条件。
--   若强行选一个有锁的任务作为起点，那个锁永远无法满足 ⇒ 任务链断裂。
--   ⇒ 这就是 :508 主循环能收敛的根本保证。
-- ⚠ 但 :861 的兜底（随机挑）会打破这个不变量。
--   触发条件：taskset 里【所有】任务都有锁。
--   此时后续 RestrictNodesByKey / LinkNodesByKeys 从这个有锁任务开始，
--   若 availableKeys 里没有对应钥匙 ⇒ 第一轮就走进 :596/:473 的逃生阀。
--   ⇒ 不是崩溃，而是「任务顺序被打乱」。玩家仍能通关，但体验错乱。
function Story:_FindStartingTask(task_nodes)
	local startTasks = {}
	for task_id, nodes in pairs(task_nodes) do
		if #self.tasks[task_id].locks == 0 or self.tasks[task_id].locks[1] == LOCKS.NONE then
			table.insert(startTasks, nodes)
		end
	end
-- ⚠ 三处风险：
--   1) startTasks 用 pairs 收集 ⇒ 顺序不定；math.random(#startTasks) 取下标 ⇒
--      起点选择在多个无锁任务之间是随机的。
--   2) 返回的可能是 startTasks 的元素（Node 对象），也可能是 task_nodes 的元素；
--      两者语义相同（都是 Node）⇒ 返回类型一致，这里是好的设计。
--   3) GetRandomItem 是无序取首个（见 network.lua 的同名封装），
--      依赖 pairs 顺序 ⇒ 又一处可复现性陷阱。
--   ⚠ 更稳的写法应是收集 task_id 列表后排序 —— 但本仓库普遍未这样做。
	return #startTasks > 0 and startTasks[math.random(#startTasks)] or GetRandomItem(task_nodes)
end

-- ============================================================
-- GenerateNodesForRegion —— 【任务集 → 子图】的核心工厂
-- ============================================================
-- 【被谁调用】:850（大陆）、:803（离岛）、:830（定向区域）—— 全部区域共用此函数。
-- 【职责】
--   1) :871-877 为每个任务生成子图（GenerateNodesFromTask），登记进 self.TERRAIN；
--   2) :879 挑起点任务；
--   3) :886-890 按 layout_mode 选两套锁算法之一，把所有子图连成一个图；
--   4) :899-911 按概率把首尾连成环（loop）；
--   5) 返回 {startingTask, entranceNode, finalNode} 三元组。
-- 【心智模型】「先有图，图才有点，点才成地块，地块才长东西」
--   本函数是第 2 步（建子图）与第 3 步（连子图）的交界。
function Story:GenerateNodesForRegion(taskset, layout_mode)
-- ★ layout_mode 必填断言。
--   ⇒ 这条断言把「布局模式」确立为区域生成的【必填契约】，
--     所有调用点都必须显式指定（因而才出现 :803/:830 的硬编码）。
    assert(layout_mode ~= nil, "Must specify a layout mode for your level.")

-- ⚠ 静默返回 nil（不是 {}），调用点 :812 直接访问 new_region.entranceNode 会崩。
--   实际不会触发：三个调用点传的都是非 nil 的 region_taskset。
--   但这是一个未标注的隐式前置条件。
    if taskset == nil then return end

	-- Generate all the TERRAIN
	local task_nodes = {}
-- ★ 为 taskset 里每个任务生成一个子图。
--   ⚠ :872 的 assert「Cannot add the same task twice」是【全局唯一性约束】：
--     因为 self.TERRAIN 是跨区域共享的，同一个任务 id 只能生成一次。
--     这也意味着 AddRegionsToMainland 里若两个 region 共享任务，会直接崩。
--   现实中 region_tasksets 是互斥的，所以不触发。
	for k, task in pairs(taskset) do
		assert(self.TERRAIN[task.id] == nil, "Cannot add the same task twice!")

-- crossLinkFactor 缺省为 1（来自 task.lua 的 crosslink_factor）。
--   ⇒ 传给 GenerateNodesFromTask → :1385 CrosslinkRandom，控制【任务内部的额外连边数】。
--   值越大，任务内部的房间之间横向连接越多 ⇒ 地图越「网状」而非「线性」。
		local task_node = self:GenerateNodesFromTask(task, task.crosslink_factor or 1, nil)
		self.TERRAIN[task.id] = task_node
		task_nodes[task.id] = task_node
	end

-- 挑起点，并把起点从待连接集合里摘掉（:880）。
--   ★ 为什么要摘掉：起点已经是根，不需要再被「接入」，否则会形成自环。
	local startingTask = self:_FindStartingTask(task_nodes)
	task_nodes[startingTask.id] = nil

	print("[Story Gen] Generate nodes. Starting at: '" .. startingTask.id .. "'")
	--dumptable(task_nodes, 1, 1)

	local finalNode = nil
-- ⚠ layout_mode 的分派：只有大小写不敏感地等于 "RestrictNodesByKey" 才走批量法，
--   其余【一切】取值都走 LinkNodesByKeys。
--   ⇒ 传 "LinkNodesByKey"（单数）、传 "foo"、传 nil（被 :865 拦下）都走同一条路。
--   这是一种「默认兜底」写法：只有明确要求才切换。
--   ★ 实用含义：mod 或世界设置若想用批量法，必须拼对大小写与单复数。
    if string.upper(layout_mode) == string.upper("RestrictNodesByKey") then
        finalNode = self:RestrictNodesByKey(startingTask, task_nodes)
    else
		finalNode = self:LinkNodesByKeys(startingTask, task_nodes)
    end

-- ★ entranceNode = 起点任务的随机入口节点。
--   这是整个区域的「对外接口」，:812 的 LinkRegions 就接在这里。
--   ⚠ 起点任务若有多个 entrance 节点（AddStartingSetPiece 处理过），
--     GetRandomNodeForEntrance 是加权随机 ⇒ 结果依赖 network.lua 的权重实现。
	local entranceNode = startingTask:GetRandomNodeForEntrance()


	-- TODO: SeperateStoryByBlanks has bad names in the lock edge ID, might have bad rooms too!
	--       This might be one of the sources of bad debug rendering!!!!

	-- form the map into a loop!
-- ============================================================
-- 【成环】把入口与末端用留白节点连起来，形成一条回环
-- ============================================================
-- 【机制】SeperateStoryByBlanks 会造一个 LOOP_BLANK 子图（:1155），
--   用【不可通行地块】把两端连起来。
--   ★ 为什么用不可通行地块「连接」？因为它的作用不是通行，而是
--     「告诉 Voronoi：这两个点之间要留一条空隙」。
--   留白被烘焙进地块后，地图上就出现一条自然形成的海峡/山口 ——
--   玩家的实际通路会在后续 DrawRoads / 地形铺装阶段被【另外生成】。
--   参见 forest_map.lua 的 DrawRoads（:557）。
-- ⚠ :895-896 的 TODO 自承：这条路径的 lock edge ID 命名有问题，
--   可能导致调试渲染异常。这是源码作者自己留下的缺陷记录。
-- ⚠ :899 的守卫 entranceNode.data.task ~= finalNode.data.task 防止自环，
--   但在 taskset 只有 1 个任务时两者必然相同 ⇒ 不会成环（正确）。
-- 概率：世界设置给了 loop_percent 就用它，否则默认 0.5（一半的地图有环）。
--   ⚠ :906 的 0.5 是硬编码默认值，不同关卡配置下手感差异很大。
--   SeperateStoryByBlanks 会自增 self.loop_blanks（:1169），命名 LOOP_BLANKn。
-- 返回三元组：起点任务 / 入口节点 / 末端节点。
	if entranceNode.data.task ~= finalNode.data.task then
		if self.gen_params.loop_percent ~= nil then
			if math.random() < self.gen_params.loop_percent then
				--print("Adding map loop")
				self:SeperateStoryByBlanks(entranceNode, finalNode )
			end
		else
			if math.random() < 0.5 then
				--print("Adding map loop")
				self:SeperateStoryByBlanks(entranceNode, finalNode )
			end
		end
	end

	return {startingTask = startingTask, entranceNode = entranceNode, finalNode = finalNode}
end

-- ============================================================
-- _AddPlayerStartNode —— 挂 START 节点
-- ============================================================
-- 【START 是什么】玩家出生门户所在的地块。
--   它被挂在【某个任务】下面（:972 randomStartTask:AddNode），
--   并用一条无向直连边连到该任务的某个入口节点（:975）。
--   ⇒ START 本身不参与锁—钥匙连线，它只是「地图的坐标原点标记」。
function Story:_AddPlayerStartNode(mainland)
	local randomStartTaskName = nil
-- 若关卡配置了 valid_start_tasks，从中随机挑一个任务名。
--   ⚠ :919 是「math.random 取下标」用法 ⇒ 依赖数组的真实顺序（这里是数组，安全）。
--   valid_start_tasks 是数组 ⇒ 与 GetRandomItem（表）不同，这里没有 pairs 顺序问题。
	if self.level.valid_start_tasks ~= nil then
		randomStartTaskName = self.level.valid_start_tasks[math.random(#self.level.valid_start_tasks)]
	end

	local randomStartTask = nil
	local randomStartNode = nil
	if randomStartTaskName ~= nil then
		print("Finding valid start task...")
-- ⚠ 遍历 rootNode 的【所有子孙任务】找同名者（:927 比对 id）。
--   效率：这是线性查找，在任务数多时是 O(N)。任务数通常 < 200，可接受。
--   若找不到（:936），静默降级到 mainland.startingTask ⇒ 出生点可能不符合关卡设计。
--   ★ 这个「找不到就降级」的策略贯穿全文件：不崩，但会静默改变结果。
		for id,task in pairs(self.rootNode:GetChildren()) do
			if id == randomStartTaskName then
				print("   ...picked ", task.id)
				randomStartTask = task
				randomStartNode = task:GetRandomNodeForEntrance()
				break
			end
		end
	end

	if randomStartNode == nil then
		print("No valid start node, using first task.")
		randomStartTask = mainland.startingTask
		randomStartNode = mainland.startingTask:GetRandomNodeForEntrance()
	end

-- ★ start_node_data：START 节点的数据模板。
--   两种来源：
--   A) :944 gen_params.start_node 指定了房间模板 → 用关卡里预定义的房间；
--   B) :948 兜底 → 现编一个草地房（草、树枝、燧石、浆果丛、树苗）。
--   B 的物品清单是「最小可玩出生点」：有燧石（开局工具）、浆果丛（食物）。
	local start_node_data = {id="START"}

	if self.gen_params.start_node ~= nil then
		print("Has start node", self.gen_params.start_node)
		start_node_data.data = self:GetRoom(self.gen_params.start_node)
-- ⚠ 疑似缺陷：terrain_contents = start_node_data.data.contents
--   把【内容物】赋给了【地形内容】字段。
--   参照 task.lua 对两者的区分：terrain_contents 是地块级的（草、石头），
--   contents 是房间级的（prefab、static_layout）。
--   这里把房间内容直接塞进地块内容，若模板同时有 terrain_contents，
--   会被【整表覆盖】而非合并 ⇒ 模板里地块级的配置丢失。
--   ⚠ 影响面：仅在【世界设置显式指定了 start_node 房间】时触发；
--     默认路径（:948 兜底）不走这里。
--     这解释了为什么这个覆盖行为可能长期未被发现：默认配置走不到。
		start_node_data.data.terrain_contents = start_node_data.data.contents
	else
		print("No start node! Createing a default room.")
		start_node_data.data =
		{
			value = WORLD_TILES.GRASS,
			terrain_contents={
				countprefabs = {
					spawnpoint=1,
					sapling=1,
					twiggytree=1,
					flint=1,
					berrybush=1,
					berrybush_juicy = 0.5,
-- ⚠ 求值时机陷阱：grass 是【函数】，写成 function() return 2 + math.random(2) end。
--   它不会在此刻求值，而是被塞进 countprefabs 传给 C++ / graphnode。
--   ⇒ 真正求值发生在 PopulateWorld_AddEntity 阶段（graphnode.lua 的实体生成循环）。
--   ★ 好的一面：把随机消耗推迟到烘焙期，且每张地图只求值一次。
--   ⚠ 风险面：随机数的消耗时机被推迟 ⇒ 任何在 Story 阶段之后才做的
--     math.random 调用都会受影响 ⇒ 改 Story 代码会连带改变地图布局。
--   这是「可复现性」最容易被破坏的地方，值得单独记住。
					grass=function () return 2 + math.random(2) end
				}
			}
		}
	end

-- ★ START 的统一标记：name="START"，青色半透明。
--   这两个字段让调试渲染能一眼认出「地图原点」，
--   玩家看到的世界里不会有它（这是仅用于调试视图的 data）。
--   ⚠ 注意 next_room_data.colour 在 :1340 也会被设成同样的值 ——
--     两处硬编码了相同的颜色，没有共用常量。
-- :970 AddStartingSetPiece：若配置了 start_setpeice，覆盖该房间的静态布局
--   并移除 spawnpoint prefab（见 :653 的注释）。
-- :972 ★ 挂在【随机挑的任务】下，不是挂在起点任务下。
--   ⇒ START 节点的 parent task 可能是任意任务，
--     但它只与 randomStartNode 相连，结构上仍是孤立的。
-- :975 唯一的边：START → 该任务的某个入口节点。
--   ★ 这条边是 AddEdge（无锁语义），不是 LockGraph。
--     ⇒ 出生门户始终可达，不受任何钥匙影响。这是刻意的正确设计。
	start_node_data.data.name = "START"
	start_node_data.data.colour = {r=0,g=1,b=1,a=.80}

	self:AddStartingSetPiece(start_node_data.data)

	local startNode = randomStartTask:AddNode(start_node_data)

	--print("Story:_AddPlayerStartNode adding start node link", self.startNode.id.." -> "..randomStartNode.id)
	randomStartTask:AddEdge({node1id=startNode.id, node2id=randomStartNode.id})

	return startNode
end

-- ============================================================
-- AddBGNodes —— 给每个非入口节点挂背景地块（BG）
-- ============================================================
-- 【目的】让 Voronoi 多出候选点 ⇒ 地图边界更平滑、不留大片空白。
-- 【在流程中的位置】GenerationPipeline 第 2 步（storygen.lua:88）。
--   必须在 Voronoi 之前执行 —— BG 节点就是 Voronoi 的额外点。
-- ★ 这是本文件里少见的【纯增点】操作：不连线、不加锁，只为了影响几何。
-- min_count/max_count 每个节点挂多少个背景地块（:1010 每次现摇）。
function Story:AddBGNodes(min_count, max_count, task_nodes)
	print("Adding Background Nodes")
	task_nodes = task_nodes or self.rootNode:GetChildren(false)
	local bg_idx = 0

-- ⚠ 外层 pairs 遍历任务 ⇒ BG 的分配顺序依赖 hash 顺序。
--   与 GetRandomNodeFromTasks:638 的「取第 k 个」不同，
--   这里只在【每个任务内部】用 math.random(1, count) ⇒ 危险度较低
--   （局部随机，任务遍历顺序只影响任务间分配）。
--   仍然是可复现性的一处依赖，但影响面局限在「BG 落在哪个任务」。
-- :986 取任务的 background 房间模板（每个任务可指定不同的背景主题）。
-- ⚠ :987 的 assert 是硬失败：模板缺失 ⇒ 整张地图重生成。
--   实际风险低（room 名字由 level/tasks 配对提供）。
-- ★ :988 blocker_blank 模板：给【入口节点】用的「门」。
--   默认是 type=Blank + value=self.impassible_value + RoadPoison/ForceDisconnected 标签。
--   ⚠ :997 ArrayUnion(blocker_blank_template.tags, task.data.room_tags) ——
--     在【每次循环内】都把 task 的标签并进【共享的】blocker_blank_template.tags。
--     而该模板在 :988 之后不再重建 ⇒ 多个任务循环时，
--     后一个任务的 room_tags 会累积到同一个模板上 ⇒ ★ 标签越积越多。
--   影响：Blocker 地块会带上所有已遍历任务的标签。
--   实践后果：RoadPoison 扩散判定会覆盖更广范围（通常是想要的），
--     但 ForceDisconnected 若被误加会造成非预期断开。
--   ⚠⚠ 这是一个真实的共享状态污染缺陷（对比 graphnode.lua 的 scratchpad 双重隔离手法，
--     那里专门为同类问题做了隔离，说明这是本仓库的已知教训）。
-- :1001-1003 兜底：模板没有 contents 时给个空表。
--   ⚠ 这也是对【共享模板】的修改 —— 与 :997 同类问题。
--   若多个任务共用同一个 background 房间模板，:1004 的替换会互相干扰。
-- :1004 RunTaskSubstitution：按任务的 substitutes 表替换 prefab（见 :1211）。
--   ⚠ 同样是对共享模板的原地修改，见 :1001 的同类风险。
	for taskid, task in pairs(task_nodes) do
		local background_template = self:GetRoom(task.data.background)
		assert(background_template, "Couldn't find room with name "..(task.data.background or "<nil>").." from "..task.id)
		local blocker_blank_template = self:GetRoom(self.level.blocker_blank_room_name)
		if blocker_blank_template == nil then
			blocker_blank_template = {
				type=NODE_TYPE.Blank,
                name="blocker_blank",
				tags = {"RoadPoison", "ForceDisconnected"},
				colour={r=0.3,g=.8,b=.5,a=.50},
				value = self.impassible_value
			}
            ArrayUnion(blocker_blank_template.tags, task.data.room_tags)
		end


        if background_template.contents == nil then
            background_template.contents = {}
        end
        self:RunTaskSubstitution(task, background_template.contents.distributeprefabs)

-- 遍历该任务下的所有【非子节点】节点（:1006 false 参数）。
--   ★ 传 false 是为了排除已添加的 BG 节点自身，否则会无限增殖。
-- :1008 入口节点跳过背景 —— 入口不能被背景埋掉。
		for nodeid,node in pairs(task:GetNodes(false)) do

			if not node.data.entrance then

				local count = math.random(min_count,max_count)
				local prevNode = nil
-- ★ 内层：为这一个节点挂 count 个背景地块。
--   每次都 deepcopy 模板（:1014）⇒ 互不干扰，这是正确的隔离做法。
--   ⚠ 对比 :997/:1004 的共享模板污染 —— 这里是干净的。
--     同一文件里两种做法并存，说明前者是疏忽而非有意。
-- :1015 id 形如 <taskid>:BG_<n>:<roomname>，全局唯一（bg_idx 跨节点持续递增）。
--   ★ id 的结构被下游解析：graphnode.lua 用 ':' 分割取地块信息
--     （详见 graphnode.lua 的 SaveEncode / PopulateVoronoi 注释）。
--     ⇒ id 格式是【隐式协议】，改动会导致反序列化失败。
-- :1019-1020 注释说明 GetExtrasForRoom 必须在内层循环里调用，
--   否则 teleportato 之类的一次性标签会被误应用到多个节点上。
--   ★ 这是一个「标签必须一对一消费」的设计约束，注释写得很清楚。
-- :1027-1029 类型提升：Room→BackgroundRoom，Default→Background，其余原样。
--   【为什么】房间类节点需要完整铺装，背景类只需要地表。
--   ⚠ 这是硬编码的两级提升规则，不支持更深层的类型转换。
-- :1035 tags = ArrayUnion(extra_tags, task.room_tags) —— 标签三来源合并。
--   ★ 标签是 DST 地图系统的【核心控制流】：
--     RoadPoison      → 道路不铺到这里
--     ForceDisconnected → Voronoi 连通性修复时不处理
--     teleportato     → 生成传送门
--   参见 network.lua:390 附近的标签→flag 位映射（ApplyPoisonTag）。
-- :1036-1037 contents 与 extra_contents 分开存：
--   前者是房间自带内容，后者是 tag 注入的额外内容。
--   ⚠ 保持两个字段而非合并，是为了 graphnode 侧能区分来源。
-- ⚠ :1047-1050：把相邻 BG 串成链的代码被【注释掉】，注释自承「会造成 crushng」。
--   ⚠ prevNode 变量仍在 :1011/:1053 被维护 —— 纯死变量。
--   这是一个「已知会崩所以关掉」的正确决策，不是缺陷。
-- :1056 ★ 入口节点走另一条分支：固定挂【2 个】 blocker_blank（不可通行的门）。
--   ★★ 这就是「锁的物理形态」：
--     玩家走到入口房时，面前有一块不可通行的地块（视觉上的门/山壁），
--     旁边挂着 blocker_blank 子节点。
--     当 LinkNodesByKeys 判定钥匙够了，就 LockGraph 到真正的下一块地 ——
--     此时阻挡物依然存在，但旁边开出一条路。
--   ⇒ 锁不是「门开了就没了」，而是「门旁边多了一条路」。
--   这个设计让锁的状态【完全由拓扑表达】，无需任何运行时标记。
--   ⚠ :1056 的 for i=1,2 是硬编码 2，与上面的 count 随机无关。
--     两个 blocker_blank 的作用是「双叶门」，视觉上更宽。
--   ⚠ :1074 blocker_blank = true —— 这个标记让 graphnode 侧把它画成门而非地面。
--     参见 graphnode.lua 的 PopulateWorld_AddEntity 对该标记的处理。
				for i=1,count do

					local new_room = deepcopy(background_template)
					new_room.id = task.id..":BG_"..bg_idx..":"..new_room.name
					new_room.task = task.id


					-- this has to be inside the inner loop so that things like teleportato tags
					-- only get processed for a single node.
					local extra_contents, extra_tags = self:GetExtrasForRoom(new_room)


					local newNode = task:AddNode({
										id=new_room.id,
										data={
												type=(new_room.type == NODE_TYPE.Room and NODE_TYPE.BackgroundRoom)
                                                    or (new_room.type == NODE_TYPE.Default and NODE_TYPE.Background)
                                                    or new_room.type,
                                                task = new_room.task,
                                                name="background",
												colour = new_room.colour,
												value = new_room.value,
												internal_type = new_room.internal_type,
												tags = ArrayUnion(extra_tags, task.room_tags),
												terrain_contents = new_room.contents,
												terrain_contents_extra = extra_contents,
												terrain_filter = self.terrain.filter,
												entrance = new_room.entrance,
												required_prefabs = new_room.required_prefabs,

												SafeFromDisconnect = new_room.SafeFromDisconnect,
											  }
										})

					task:AddEdge({node1id=newNode.id, node2id=nodeid})
					-- This will probably cause crushng so it is commented out for now
					-- if prevNode then
					-- 	task:AddEdge({node1id=newNode.id, node2id=prevNode.id})
					-- end

					bg_idx = bg_idx + 1
					prevNode = newNode
				end
			else -- this is an entrance node
				for i=1,2 do
					local new_room = deepcopy(blocker_blank_template)
					new_room.task = task.id

					local extra_contents, extra_tags = self:GetExtrasForRoom(new_room)

					local blank_subnode = task:AddNode({
											id=nodeid..":BLOCKER_BLANK_"..tostring(i),
											data={
													type= new_room.type or NODE_TYPE.Blank,
                                                    task = new_room.task,
													colour = new_room.colour,
													value = new_room.value,
													internal_type = new_room.internal_type,
													tags = ArrayUnion(extra_tags, task.room_tags),
													terrain_contents = new_room.contents,
													terrain_contents_extra = extra_contents,
													terrain_filter = self.terrain.filter,
													blocker_blank = true,
													required_prefabs = new_room.required_prefabs,

													SafeFromDisconnect = new_room.SafeFromDisconnect,
												  }
										})

					task:AddEdge({node1id=nodeid, node2id=blank_subnode.id})
				end
			end

		end

	end
end

-- ============================================================
-- AddCoveNodes —— 挂「小口袋地块」（cove）
-- ============================================================
-- 【与 AddBGNodes 的区别】
--   AddBGNodes：挂在【入口以外的所有节点】上，纯几何增点，没有条件过滤。
--   AddCoveNodes：只挂在【边数少】的非入口、非背景、非 START 的节点上，且带概率。
--   ⇒ cove 是「凹进去的小房间」，是拓扑上的口袋，不是背景装饰。
--   在流程中排在最后（GenerationPipeline 第 3 步，storygen.lua:90），
--   因为它依赖最终的边数（要在连线完成后才知道哪些节点还空着）。
-- ★★ 与 AddBGNodes 的关系：BGNodes 先跑，它会改变节点的边数
--   ⇒ cove 的 cove_room_max_edges 判定读到的边数【已经包含 BG 边】。
--   这两个参数是耦合的：BG 数量会挤占 cove 的名额。
function Story:AddCoveNodes(task_nodes)
	print("[Story Gen] Adding Cove Nodes")
	task_nodes = task_nodes or self.rootNode:GetChildren(false)
	local bg_idx = 0

	for taskid, task_node in pairs(task_nodes) do
		local task_def = self.tasks[taskid]
-- ⚠ 跳过「自动生成的任务」：LOOP_BLANK_n / REGION_LINK_n 等没有任务定义。
--   它们的 id 在 self.TERRAIN 里存在但 self.tasks 里没有。
--   ★ 硬编码的判断方式（task_def == nil）而非「是否属于某一类」，
--     简洁但脆弱：任何新增的自动任务都会被自动排除（这是想要的行为）。
		if task_def ~= nil then -- generated tasks like LOOP_BLANK_X and REGION_LINK_X do not need coves added to them
-- cove 房名默认 "Blank"，任务可覆盖。
--   ★ 注意默认是 Blank：没有专门配置 cove 房的任务，长出的就是留白地块。
--     留白地块在烘焙后就是一小块空地/岩壁 —— 视觉上像地图上的「小坑」。
-- :1100 assert：模板缺失即硬失败。
			local cove_room_name = task_def.cove_room_name or "Blank"
			local cove_room_template = self:GetRoom(cove_room_name)
			assert(cove_room_template, "Couldn't find blank room with name "..(cove_room_name).." from "..taskid)

			if cove_room_template.contents == nil then
				cove_room_template.contents = {}
			end

-- cove 出现概率缺省 0.35，任务可覆盖。
-- cove 挂载数上限缺省 1（cove_room_max_edges 是【判定阈值】不是数量）。
-- ⚠⚠ 疑似缺陷（整批中止）：下面 :1108-1110 的 return 位于【任务遍历循环内部】。
--   语义应是「跳过这个任务」，但写成了 return ⇒ 【整个函数提前返回】，
--   后续所有任务都不会被处理。
--
-- 【推理依据】
--   本函数结构是 for taskid, task_node in pairs(task_nodes) do ... end，
--   :1108 的 return 直接退出函数，而循环内的 return 等价于 break。
--   ⇒ 若任意一个任务配了 cove_room_chance==0 或 cove_room_max_edges==0，
--     该任务【之后】的所有任务（pairs 顺序不确定）都会丢失 cove。
--
-- 【为什么线上没暴露】
--   pairs 顺序不确定 ⇒ 「哪些任务被跳过」每次生成都可能不同，
--   表现为「某些任务的地图少了小口袋」，非常难被察觉。
--   且这不会导致不可达或崩溃，只是装饰缺失。
--
-- 【正确做法】应为 break（跳过当前任务）而非 return。
--   ⚠ 但注意：cove_room_chance==0 的任务在 tasks.lua 中确实存在（用于明确不要 cove），
--     所以这个分支不是死代码 —— 它【一定会被走到】，只是走错出口。
--   ⇒ 判定：这是【真实缺陷】而非防御性冗余。
--   影响面：任何含 cove 禁用配置的任务集，其 cove 分配都被截断。
			local cove_room_chance = task_def.cove_room_chance ~= nil and task_def.cove_room_chance or 0.35
			local cove_room_max_edges = task_def.cove_room_max_edges ~= nil and task_def.cove_room_max_edges or 1
			if cove_room_chance == 0 or cove_room_max_edges == 0 then
				return
			end

-- ⚠ 与 AddBGNodes:1004 同样的共享模板污染：RunTaskSubstitution 原地修改
--   cove_room_template.contents.distributeprefabs。
--   cove 房模板的 distributeprefabs 若非空，替换会累积。
			self:RunTaskSubstitution(task_node, cove_room_template.contents.distributeprefabs)

-- ★ 五重筛选条件，缺一不可：
--   (1) not node.data.entrance          → 入口不挂 cove（入口已有 blocker_blank 门）
--   (2) node.data.type ~= Blank         → 留白节点不挂（留白本身就是空隙）
--   (3) node.data.type ~= BackgroundRoom → 背景地块不挂（BGNodes 已经处理过）
--   (4) node.id ~= "START"             → 出生点不挂
--   (5) GetTableSize(node.edges) <= cove_room_max_edges → 只挂在【边少】的节点上
--   + math.random() < cove_room_chance   → 概率
--
-- ★【条件 5 是核心】edges 少的节点 = 地图的「末端」或「角落」。
--   在这里挂 cove ⇒ 玩家走进死路时发现一个额外的小房间。
--   这正是「cove（凹室）」这个名字的由来 —— 拓扑上的死角点缀。
--   边数判定用 GetTableSize(node.edges) ⇒ 包含 BG 边和 cove 边，
--   而 cove 边在 :1144 立刻加入 ⇒ 一个节点最多只能有 1 个 cove（缺省上限）。
-- ⚠ 这个自反馈（加了边就超过阈值）使 max_edges=1 时严格只挂一个。
-- :1119 id 形如 <taskid>:COVE_<n>:<roomname>，bg_idx 在每个任务内重置（:1150）。
			for nodeid, node in pairs(task_node:GetNodes(false)) do
				if not node.data.entrance and node.data.type ~= NODE_TYPE.Blank and node.data.type ~= NODE_TYPE.BackgroundRoom and node.id ~= "START"
					and (node.edges ~= nil and GetTableSize(node.edges) <= cove_room_max_edges) and math.random() < cove_room_chance then

					local new_room = deepcopy(cove_room_template)
					new_room.id = taskid..":COVE_"..bg_idx..":"..new_room.name
					new_room.task = taskid
					local extra_contents, extra_tags = self:GetExtrasForRoom(new_room)
					local newNode = task_node:AddNode({
										id=new_room.id,
										data={
												type=(new_room.type == NODE_TYPE.Room and NODE_TYPE.BackgroundRoom)
													or (new_room.type == NODE_TYPE.Default and NODE_TYPE.Background)
													or new_room.type,
												task = new_room.task,
												name="background",
												colour = new_room.colour,
												value = new_room.value,
												internal_type = new_room.internal_type,
												tags = ArrayUnion(extra_tags, task_node.room_tags),
												terrain_contents = new_room.contents,
												terrain_contents_extra = extra_contents,
												terrain_filter = self.terrain.filter,
												entrance = new_room.entrance,
												required_prefabs = new_room.required_prefabs,

												SafeFromDisconnect = new_room.SafeFromDisconnect,
												}
										})

					task_node:AddEdge({node1id=newNode.id, node2id=nodeid})

					bg_idx = bg_idx + 1
				end
			end

			bg_idx = 0
		end
	end
end

-- ============================================================
-- SeperateStoryByBlanks —— 用【不可通行地块】把两个节点「连」起来
-- ============================================================
-- ★★ 这是全文件最反直觉也最关键的机制，务必理解清楚：
--
-- 【它不制造通路，它制造留白】
--   做法：造一个 LOOP_BLANK 子图，含一个 NODE_TYPE.Blank 的子节点，
--        再把 startnode 和 endnode 各自 LockGraph 到这个 blank 节点。
--   后果：Voronoi 烘焙时，这两点之间会被【烘焙成不可通行的地块】（默认 BGImpassable）。
--   ⇒ 地图上出现一条天然的山脊/海峡/岩壁。
--
-- 【那玩家怎么过去？】
--   答：不需要「过去」。这条留白的目的是打断直连路径，迫使玩家绕行，
--   或者作为「这条边不通」的物理表达。
--   它的真正用途有三个：
--     ① 成环（:903/:908）—— 让入口和末端之间「有路但不是直路」；
--     ② 孤岛（:611）—— 按 island_percent 断开某些连接；
--     ③ 视觉隔断 —— 把大片地图切成有层次的几块。
--
-- 【与锁—钥匙的关系】
--   两条边都用 key=KEYS.NONE ⇒ 无锁，任何时候都「连着」。
--   锁的效果不来自这条边，而来自 blank 地块本身不可通行。
--   ⇒ 这里的「断开」是【物理断开】，不是【条件断开】。
--   这是与 LinkNodesByKeys:613 那种「有钥匙才建边」的相反机制。
-- ⚠ :1159 的节点 id 是 "LOOP_BLANK_SUB " + 序号 —— ★ 注意 SUB 后面【有空格】。
--   与 :1156/:1157 的图 id "LOOP_BLANKn" 命名不一致。
--   ⚠ 影响：graphnode.lua 解析 id 时若按 ':' 分割，这里没有冒号，会解析出异常段。
--     属于命名不一致的潜在雷点。
-- :1163 tags = RoadPoison + ForceDisconnected ⇒
--   ① 不铺路；② Voronoi 连通性修复时跳过。两者共同保证它永远是空地。
-- :1169 loop_blanks 自增 ⇒ 多个 loop 会得到 LOOP_BLANK0/1/2...。
-- ★ :1170/:1171 两次 LockGraph 的 key 都是 KEYS.NONE，node 参数都是 nil。
--   参照 :613 的 {type="none", key=self.tasks[...].locks, node=nil}，
--   这里连 locks 都没传 ⇒ 纯粹是「无条件加一条边到 blank 节点」。
function Story:SeperateStoryByBlanks(startnode, endnode )
	local blank_node = Graph("LOOP_BLANK"..tostring(self.loop_blanks), {parent=self.rootNode, default_bg=WORLD_TILES.IMPASSABLE, colour = {r=0,g=0,b=0,a=1}, background="BGImpassable" })
	WorldSim:AddChild(self.rootNode.id, "LOOP_BLANK"..tostring(self.loop_blanks), WORLD_TILES.IMPASSABLE, 0, 0, 0, 1, "blank")
	local blank_subnode = blank_node:AddNode({
											id="LOOP_BLANK_SUB "..tostring(self.loop_blanks),
											data={
													type=NODE_TYPE.Blank,
                                                    name="LOOP_BLANK_SUB",
													tags = {"RoadPoison", "ForceDisconnected"},
													colour={r=0.3,g=.8,b=.5,a=.50},
													value = self.impassible_value
												  }
										})

	self.loop_blanks = self.loop_blanks + 1
	self.rootNode:LockGraph(startnode.data.task..'->'..blank_subnode.id, 	startnode, 	blank_subnode, {type="none", key=KEYS.NONE, node=nil})
	self.rootNode:LockGraph(endnode.data.task..'->'..blank_subnode.id, 	endnode, 	blank_subnode, {type="none", key=KEYS.NONE, node=nil})
end

-- ============================================================
-- GetExtrasForRoom —— 【tag → 内容物】的翻译器
-- ============================================================
-- 【机制】遍历房间的 tags，逐个调用 self.map_tags.Tag[tag](self.map_tags.TagData, self.level)，
--   该函数返回一个 (type, extra) 二元组，按 type 分流到四个去处：
--     STATIC   → extra_contents.static_layouts（静态场景件，追加）
--     ITEM     → extra_contents.prefabs（prefab，追加）
--     TAG      → extra_tags（标签，传递给调用方合并到节点 tags）
--     GLOBALTAG→ self.GlobalTags[extra][task] （全局标签台账）
--
-- 【为什么要有 GLOBALTAG 这种「旁路」】
--   ★ 前三种都是「给这一个房间加东西」，而 GLOBALTAG 是「记录一个全局事实」，
--     例如「这个任务里有传送门」「这个区域被诅咒」。
--     它写进 self.GlobalTags 而不写进房间 ⇒ 运行时（grottowarmanager 等）
--     按 tag 查询全局索引，而不是逐房间扫描。
--   这是一张两级索引：GLOBALTAG → task → roomId 列表。
--   BuildStory:1405 把它作为返回值之一传给上层。
-- ⚠ :1179 直接以函数形式调用 map_tags.Tag[tag] —— 若 tag 未在 Tag 表中定义，
--   这里会抛「attempt to call a nil value」。
--   ⇒ 【隐式契约】：所有 room/task 上出现的 tag 必须在 maptags.lua 里注册。
--   ⚠ 无保护、无默认值。tag 拼错 ⇒ 整张地图生成失败（进 worldgen_main 重试）。
-- ⚠ :1179 用 [tag] 而非 [tag.."_fn"] 之类的间接形式 ⇒ 零性能优化，
--   每个房间每个 tag 一次哈希查找。房间数 × tag 数 = 数千次，可接受。
-- ⚠ :1180-1194 使用三个独立的 if 而非 if/elseif ——
--   若某个 tag 函数同时返回多个语义（实际不会），会全部写入。
--   写法上是防御性的，语义上无副作用。
function Story:GetExtrasForRoom(next_room)
	local extra_contents = {}
	local extra_tags = {}
	if next_room.tags ~= nil then
		for i,tag in ipairs(next_room.tags) do
			local type, extra = self.map_tags.Tag[tag](self.map_tags.TagData, self.level)
			if type == "STATIC" then
				if extra_contents.static_layouts == nil then
					extra_contents.static_layouts = {}
				end
				table.insert(extra_contents.static_layouts, extra)
			end
			if type == "ITEM" then
				if extra_contents.prefabs == nil then
					extra_contents.prefabs = {}
				end
				table.insert(extra_contents.prefabs, extra)
			end
			if type == "TAG" then
				table.insert(extra_tags, extra)
			end
			if type == "GLOBALTAG" then
				if self.GlobalTags[extra] == nil then
					self.GlobalTags[extra] = {}
				end
				if self.GlobalTags[extra][next_room.task] == nil then
					self.GlobalTags[extra][next_room.task] = {}
				end
				--print("Adding GLOBALTAG", extra, next_room.task, next_room.id)
				table.insert(self.GlobalTags[extra][next_room.task], next_room.id)
			end
		end
	end

	return extra_contents, extra_tags
end

-- ============================================================
-- RunTaskSubstitution —— prefab 替换（substitutes）
-- ============================================================
-- 【用途】让任务把自己的 prefab「换掉」，用于主题化与难度调整。
--   例：某任务的 substitutes = { rocks = {name="boulder", percent=0.5} }
--   ⇒ 一半变巨石，一半保留原样（:1222-1223 的守恒拆分）。
-- 【percent 语义】
--   nil 或 1 ⇒ 全量替换（:1218-1220，直接搬走并清空原键）
--   0<p<1    ⇒ 按比例拆分：新名 p*old，原名 (1-p)*old
-- ⚠ p=0 时会写 items[name]=0 —— 下游按 0 处理（视为不要），但表里仍有键。
--   ⚠ 是否有符号（count=0 vs 无此键）在 graphnode.lua 侧可能有区别，
--     参见 graphnode.lua 的 AddEntity 计数逻辑。
-- ⚠ :1216 pairs 遍历 substitutes ⇒ 若替换链存在（A→B, B→C），
--   结果依赖遍历顺序（可能变成 A→C 而非 A→B→C）。
--   实践上 substitutes 通常只有一层 ⇒ 不触发。属潜在风险。
-- ★ :1213 提前 return items（不做替换）—— 两个 nil 检查都是「没有就原样返回」。
function Story:RunTaskSubstitution(task, items )
	if task.substitutes == nil or items == nil then
		return items
	end

	for k,v in pairs(task.substitutes) do
		if items[k] ~= nil then
			if v.percent == 1 or v.percent == nil then
				items[v.name] = items[k]
				items[k] = nil
			else
				items[v.name] = items[k] * v.percent
				items[k] = items[k] * (1.0-v.percent)
			end
		end
	end

	return items
end

-- Generate a subgraph containing all the items for this story
-- ============================================================
-- GenerateNodesFromTask —— 【单任务 → 子图】的真正实现
-- ============================================================
-- 【与 GenerateNodesForRegion 的分工】
--   前者（:864）：处理【任务集】的连通与布局；
--   本函数（:1232）：处理【单个任务内部】的房间排布、连边、闭环、加枢纽。
-- ★ 这是整份生成逻辑中最「有手感」的部分：
--   房间怎么排、要不要成环、枢纽在哪，全在这里决定。
--
-- 【三步】
--   1) :1235-1282 组装房间栈（Stack:Create，支持 LIFO 弹出）；
--   2) :1284 建 Graph 与 WorldSim 子节点；
--   3) :1297-1372 弹栈建节点、串成链（prevNode）；
--   4) :1374-1386 后处理：成环 / 枢纽 / 横向连边。
-- 【为什么用 Stack 而不是数组】
--   Stack 的 pop 是 LIFO ⇒ 最后 push 的房间最先出场。
--   :1261 的 pairs 遍历 room_choices 决定了 push 顺序，
--   ⇒ LIFO 使「最后遍历到的房间」出现在地图入口处。
--   ⚠ 这是个隐式的顺序耦合，且依赖 pairs 遍历顺序。
function Story:GenerateNodesFromTask(task, crossLinkFactor, starting_node_name)
	--print("Story:GenerateNodesFromTask", task.id)
	-- Create stack of rooms
	local room_choices = Stack:Create()

-- ★ 入口房：按 entrance_room_chance 概率决定是否给这个任务一个入口。
--   多数任务没有 entrance_room ⇒ 这段跳过 ⇒ 该任务没有专门的入口地块。
-- ⚠ :1238-1239 的判定是 `chance == nil or chance > r`：
--   chance 为 nil 时【必然通过】（100% 给入口）。
--   ⇒ 默认值语义是「默认有」，而不是「默认无」。
-- ★ :1241 的破坏性赋值：task.entrance_room = GetRandomItem(...)
--   【⚠ 重大副作用】直接把【任务定义】里的表替换成一个字符串！
--   ⇒ 第一次生成时随机挑一个房间名，任务定义被永久改写。
--   ⇒ 若同一个 Story 对象内该任务被生成两次，第二次只会用第一次选中的房间。
--     若 story/level 对象被复用（跨世界重开、multiplayer 换图），
--     则会【锁死】同一个入口房。
--   这是本文件最隐蔽的一处缺陷 —— 它修改的是「配置」而非「实例」。
--   正确做法应是写入局部变量而非回写 task。
-- :1244-1245 取房间模板并断言存在。
-- :1251-1253 contents.fn：房间内容生成钩子（可以是 pre 表，也可以是函数）。
--   ⚠ :1252 直接调用 new_room.contents.fn(new_room) —— 会【原地修改】房间模板！
--     而 self:GetRoom 的返回值是共享表（见 :1174 的同类问题）。
--     同一个房间模板被多个任务使用时，fn 的副作用会累积。
-- ★ :1254 new_room.entrance = true —— 同样是对共享模板的写入。
--   ⇒ 任何用到该房间模板的节点都会变成 entrance！
--   ⚠ 这是一条高风险的模板污染路径，值得在阅读时重点关注。
--   与 :1004（AddBGNodes）、:1112（AddCoveNodes）是同一类问题。
--   本仓库正确的隔离手法见 graphnode.lua 的 scratchpad（那里显式做了双层拷贝）。
-- :1255 push 进栈 ⇒ 将来会作为该任务的第一个节点（:1298 pop 时先出栈）。
	if task.entrance_room then
		local r = math.random()
		if task.entrance_room_chance == nil or task.entrance_room_chance > r then
			if type(task.entrance_room) == "table" then
				task.entrance_room = GetRandomItem(task.entrance_room)
			end
			--print("\tAdding entrance: ",task.entrance_room,"rolled:",r,"needed:",task.entrance_room_chance)
			local new_room = self:GetRoom(task.entrance_room)
			assert(new_room, "Couldn't find entrance room with name "..task.entrance_room)

			if new_room.contents == nil then
				new_room.contents = {}
			end

			if new_room.contents.fn then
				new_room.contents.fn(new_room)
			end
			new_room.entrance = true
			room_choices:push(new_room)
		--else
		--	print("\tHad entrance but didn't use it. rolled:",r,"needed:",task.entrance_room_chance)
		end
	end

-- ★ room_choices：任务内各房间的【数量表】，{ RoomName = count }。
--   count 可以是数字，也可以是【函数】（:1264-1266 现求值）。
-- ⚠ :1264 的求值时机在这里（Story 阶段），而 :1238 的 entrance 概率也是。
--   ⇒ 所有这些随机数都在 Story 阶段消耗，会直接影响后续 layout 的结果。
--   ⚠ :1262 pairs 遍历 ⇒ push 顺序 = pairs 顺序 ⇒ 结合 LIFO 影响地图布局。
--   ⚠ 这里也是「取第 k 个」的形态吗？不是：只是顺序 push，不取随机下标。
--     但它仍让「哪个房间先出场」依赖 hash 顺序 ⇒ 可复现性风险（轻度）。
-- ⚠ :1267 for id=1,count 里 count 若为 0 或负数则不执行，安全。
-- ⚠ :1268/:1276-1278 与 :1244-1252 完全相同的模板取用与 fn 调用 ——
--     同样的共享模板污染问题。
-- ★ :1284 Graph(...) 的参数是一长串镜像字段：
--   default_bg = task.room_bg              ← 地块底图
--   background = task.background_room       ← 背景房模板
--   set_pieces / random_set_pieces           ← 场景件（必出 / 概率）
--   maze_tiles / maze_tile_size              ← 迷宫地形（见 :645 的 Maze 流程）
--   room_tags / required_prefabs            ← 全局标签与必需 prefab
--   ⚠ 这些都是 task.lua 上的【镜像字段】，由 level.lua 的 SetID/SetBaseID 等填充。
--     参见 level.lua 注释中「镜像字段」一节。
-- ★ :1285 task_node.substitutes = task.substitutes ——
--   把 substitutes 【挂在 Graph 上】而非每次传参，
--   于是 :1312 的 RunTaskSubstitution(task, ...) 能拿到。
-- :1288 ★ WorldSim:AddChild：在 C++ WorldSim 里为该任务分配一组点。
--   这些点就是后续 Voronoi 的种子。
--   ⚠ 这是 Lua 与 C++ 的接缝：WorldSim 的点集一旦建立，Lua 侧只能查询不能改变。
--     Voronoi/Lloyd 也在 C++ 侧完成（forest_map.lua:499 调 WorldSim:WorldGen_VoronoiPass）。
--   ⇒ ★ 所有「加点」操作（AddBGNodes / AddCoveNodes）必须在此之前完成，
--     否则新点不会参与 Voronoi。这是流程顺序不可颠倒的根本原因。
	if task.room_choices then
		for room, count in pairs(task.room_choices) do
			--print("Story:GenerateNodesFromTask adding "..count.." of "..room, Rooms.GetRoomByName(room).contents.fn)
            if type(count) == "function" then
                count = count()
            end
			for id = 1, count do
				local new_room = self:GetRoom(room)

				assert(new_room, "Couldn't find room with name "..room)
				if new_room.contents == nil then
					new_room.contents = {}
				end

				-- Do any special processing for this room
				if new_room.contents.fn then
					new_room.contents.fn(new_room)
				end
				room_choices:push(new_room)
			end
		end
	end

	local task_node = Graph(task.id, {parent=self.rootNode, default_bg=task.room_bg, colour = task.colour, background=task.background_room, set_pieces=task.set_pieces, random_set_pieces=task.random_set_pieces, maze_tiles=task.maze_tiles, maze_tile_size=task.maze_tile_size, room_tags=task.room_tags, required_prefabs=task.required_prefabs})
	task_node.substitutes = task.substitutes
	--print ("Adding Voronoi Child", self.rootNode.id, task.id, task.backround_room, task.room_bg, task.colour.r, task.colour.g, task.colour.b, task.colour.a )

	WorldSim:AddChild(self.rootNode.id, task.id, task.room_bg, task.colour.r, task.colour.g, task.colour.b, task.colour.a)

	local newNode = nil
	local prevNode = nil
	-- TODO: we could shuffleArray here on rom_choices_.et to make it more random
	local roomID = 0
	local hub_node = nil
	local starting_node_picked = false
	--print("Story:GenerateNodesFromTask adding "..room_choices:getn().." rooms")
-- ★ 主循环：只要栈非空就弹一个房间做成节点。
--   LIFO ⇒ 栈顶（最后 push 的）先出。
-- ⚠ :1292 的 TODO 自承「这里可以 shuffleArray 让 room_choices 更随机」——
--   作者知道当前实现依赖 pairs 顺序，但没有随机化。
--   ⇒ 这是可复现性的已知薄弱点。
-- :1300 ★ starting_node_name 匹配：指定名字的房间会成为该任务的 START 节点。
--   starting_node_picked 保证只挑一次（同名房间多次出现也不会都当起点）。
-- :1305 next_room.id = "START" —— ⚠ 危险：START 是全局约定名，
--   若同一任务里有多个同名房间，只有第一个被选中，其余保持 task:idx:name 格式。
-- :1312 RunTaskSubstitution(task, ...) ——
--   ⚠ 传的是 task（任务定义）不是 task_node，用的是 task.substitutes。
-- :1315 GetExtrasForRoom —— 见 :1174。GLOBALTAG 会写进 self.GlobalTags。
-- :1318 type = entrance ? Blocker : 原类型 ——
--   ★ 入口房间被强制标记为 NODE_TYPE.Blocker。
--   Blocker 是「不可通行但要绘制」的类型 ⇒ 视觉上就是那扇门。
--   这是锁的物理形态的第二处实现（第一处是 AddBGNodes 的 blocker_blank）。
--   ⚠ 注意 :1330 又单独存了 entrance = next_room.entrance，
--     于是 type=Blocker 与 entrance=true 是两个独立标记，可能不一致。
-- :1332-1333 进出权重：影响 GetRandomNodeForExit / ForEntrance 的随机选择。
--   设为 0 则该节点永不被随机选中 ⇒ START 节点（:1341-1342）用它来保护自己。
-- ★ :1346-1349 AddNode：把房间变成节点。data 是上面组装的 next_room_data。
-- ★ :1351-1355 hub_room：任务可指定一个「枢纽房间」。
--   枢纽的进出权重清零 ⇒ 不会被随机连边碰到，只能由 MakeHub 显式连接。
-- :1357-1350 ★ 关键分支：有 hub_room 且不 make_loop 时【不自动串链】。
--   ⇒ 链的构建推迟到 :1379 MakeHub，由它统一把所有房间接到枢纽上。
--   效果：枢纽任务生成的是【星形】而非【链形】⇒ 玩家从枢纽可向任意房间探索。
-- ⚠ :1358 的条件写作 task.hub_room == nil or task.make_loop ——
--   当两者都成立（有 hub 且要成环）时，走普通串链逻辑，且跳过枢纽节点本身（:1359）。
--   ⇒ 枢纽被排除在链外，但随后 :1374 MakeLoop 会把链闭成环，:1379 MakeHub 再接枢纽。
--   三者叠加的拓扑是「环 + 一个挂在环上的枢纽」，是本文件最复杂的形态。
	while room_choices:getn() > 0 do
		local next_room = room_choices:pop()

		local is_starting_room = starting_node_name == next_room.name and not starting_node_picked

		if is_starting_room then
			print("Found starting task " .. task.id .. ", picked existing room " .. next_room.name)
			starting_node_picked = true
			next_room.id = "START"
		else
			next_room.id = task.id..":"..roomID..":"..next_room.name	-- TODO: add room names for special rooms
		end

		next_room.task = task.id

		self:RunTaskSubstitution(task, next_room.contents.distributeprefabs)

		-- TODO: Move this to
		local extra_contents, extra_tags = self:GetExtrasForRoom(next_room)

		local next_room_data = {
								type = next_room.entrance and NODE_TYPE.Blocker or next_room.type,
                                task = next_room.task,
                                name = next_room.name,
								colour = next_room.colour,
								value = next_room.value,
								internal_type = next_room.internal_type,
								tags = ArrayUnion(extra_tags, task.room_tags),
								custom_tiles = next_room.custom_tiles,
								custom_objects = next_room.custom_objects,
								terrain_contents = next_room.contents,
								terrain_contents_extra = extra_contents,
								terrain_filter = self.terrain.filter,
								entrance = next_room.entrance,
								required_prefabs = next_room.required_prefabs,
								random_node_exit_weight = next_room.random_node_exit_weight,
								random_node_entrance_weight = next_room.random_node_entrance_weight,

								SafeFromDisconnect = next_room.SafeFromDisconnect,
							  }

		if is_starting_room then
			next_room_data.name = "START"
			next_room_data.colour = {r=0,g=1,b=1,a=.80}
			next_room_data.random_node_exit_weight = 0
			next_room_data.random_node_entrance_weight = 0
			self:AddStartingSetPiece(next_room_data)
		end

		newNode = task_node:AddNode({
										id=next_room.id,
										data=next_room_data,
									})

		if task.hub_room ~= nil and hub_node == nil and next_room.name == task.hub_room then
			hub_node = newNode
			hub_node.data.random_node_exit_weight = 0
			hub_node.data.random_node_entrance_weight = 0
		end

		-- Dont add edges if there is a hub room, this will hapen later in MakeHub, if we want to make a loop, then just dont add the hub to it.
		if task.hub_room == nil or task.make_loop then
			if newNode ~= hub_node then
				if prevNode then
					--dumptable(prevNode)
					--print("Story:GenerateNodesFromTask Adding edge "..newNode.id.." -> "..prevNode.id)
					local edge = task_node:AddEdge({node1id=newNode.id, node2id=prevNode.id})
				end

				--dumptable(newNode)
				-- This will make long line of nodes
				prevNode = newNode
			end
		end
		roomID = roomID + 1
	end

-- ★ make_loop：MakeLoop 把链首尾相连（见 network.lua 的实现注释）。
--   ⇒ 任务内部成一个环，玩家可以绕一圈回到起点。
	if task.make_loop then
		task_node:MakeLoop()
	end

-- MakeHub：把所有节点连到枢纽节点上，形成星形 + 可能的环。
--   详见 network.lua 的 MakeHub 注释（含它对节点数量的假设）。
	if hub_node ~= nil then
		task_node:MakeHub(hub_node.id)
	end

-- CrosslinkRandom(crossLinkFactor)：随机加横向边。
--   详见 network.lua 的注释（含 20 次上限与隐藏边的说明）。
--   ⚠ crossLinkFactor 恒非 nil（:874 用 `or 1` 兜底），所以这段【总会被调用】。
--   即使值为 1，也会尝试加边 —— 语义上「1」不是「不加」。
--   真正的不加需要显式传 false/nil，但 :874 的 `or 1` 堵死了这条路。
--   ⚠ 这是一个「默认值吞掉禁用意图」的经典陷阱。
	if crossLinkFactor then
		--print("Story:GenerateNodesFromTask crosslinking")
		-- do some extra linking.
		task_node:CrosslinkRandom(crossLinkFactor)
	end
	--print("Story:GenerateNodesFromTask done", task_node.id)
	return task_node
end
------------------------------------------------------------------------------------------
---------             TESTING                   --------------------------------------
------------------------------------------------------------------------------------------

-- ============================================================
-- BuildStory —— ★ 模块的唯一对外入口
-- ============================================================
-- 【调用方】forest_map.lua:495（GenerationPipeline 的第 1 步）
--
-- 【返回三元组】
--   root      = story.rootNode        整张图的根 Graph（含所有任务子图）
--   startNode = story.startNode       START 节点（玩家门户位置）
--   GlobalTags= story.GlobalTags     全局标签台账（GLOBALTAG 的产物）
--   story                                完整的 Story 实例（供上层调 AddBGNodes 等）
--
-- 【为什么两个返回值】
--   三元组给「只读消费者」，story 实例给「需要继续加工的调用方」
--   （AddRegionsToMainland / AddBGNodes / AddCoveNodes 都在其上调用）。
-- :1396 计时起点：GetTimeReal() 是【真实时间】而非游戏时间 ⇒ 不受暂停/加速影响。
--   ⚠ 计时结果【没有被使用】（没有对应的 GetTimeReal 差值输出），
--     是一个被放弃的性能埋点。
--   ⇒ 性能分析需靠外部工具（见 bug-patterns.md E3 的阶段耗时预算表）。
-- ★★ :1399 story:GenerationPipeline() 是整个世界生成的 Lua 侧总入口。
--   七步完整流程见 storygen.lua:86-95 的注释。
--   之后 Lua 侧的图构建就结束了，剩下交给 C++ WorldSim 的 Voronoi 与铺装。
function BuildStory(tasks, story_gen_params, level)
    --print("Building TEST STORY", tasks)
    local start_time = GetTimeReal()

    local story = Story("GAME", tasks, terrain, story_gen_params, level)
    story:GenerationPipeline()

    --print("\n------------------------------------------------")
    --story.rootNode:Dump()
    --print("\n------------------------------------------------")

    return {root=story.rootNode, startNode=story.startNode, GlobalTags = story.GlobalTags}, story
end

-- ★ 模块出口：一个函数（Story）被导出。
--   ⚠ 注意 :1394 的 BuildStory 是【全局函数】（无 local），
--     会污染 _G 命名空间。在 DST 的 Lua 环境里这是可接受的惯例。
--   ⚠ 同时 :1405 的 story.TERRAIN 等内部状态仍可被外部改写 ——
--     没有访问控制，全靠调用方自觉。
return Story