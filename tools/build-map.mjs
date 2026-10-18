#!/usr/bin/env node
/**
 * build-map.mjs —— 世界生成核心 9 个文件深度中文注释生成器（锚点注入法）
 *
 * 与 build-containers.mjs 完全同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-map-*.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头（assertComment 强制）。
 *   · 规格里出现越界行号会在构建期抛错。
 *
 * 用法：node build-map.mjs [storygen|forest|network|graphnode|lockandkey|tasks|task|level|terrain|all]
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT =
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/map";
const OUT_ROOT = "E:/DST-Analysis/02-注释源码/scripts/map";

/* ══════════════════════════ storygen.lua ══════════════════════════ */

const HEADER_STORYGEN = `--============================================================
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
--  6. ★ AddCoveNodes(:1108) 里的 \`return\` 写在 for 循环体内，
--     ⚠ 疑似缺陷：一旦某个 task 的 cove_room_chance==0 或 max_edges==0，
--     **整个 AddCoveNodes 直接退出**，后面所有 task 的穴居房间都不生成。
--     正确写法应是 \`goto continue\` / 提取成 continue 标志。见 :1108-1110。
--  7. ★ PlaceTeleportatoParts(:180) 的 \`maxdepth/#parts\`：
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
--============================================================`;

/* ══════════════════════════ forest_map.lua ══════════════════════════ */

const HEADER_FOREST = `--============================================================
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
--   ★ grep 核实：\`biome\` 这个词在 map/ 下只出现在 3 处，且都是别的意思
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
--  2. ★★ 五道校验全部以 \`return nil\` 表达失败，由 worldgen_main.lua:419
--     的 maxtries=5 重试。⚠ 每一次重试都会 collectgarbage + WorldSim:ResetAll()
--     并**重新消耗随机数** ⇒ 5 次尝试得到的 5 张图彼此不同。
--  3. ★★ VoronoiPass(100)（:499）是全流程唯一的数量级开销。
--     ★ grep 核实：Lua 库里**没有一行 Lloyd 实现**（\`grep -rn Lloyd\` 零命中），
--     松弛完全在 C++ WorldSim 内。移植时必须自己实现，
--     复杂度 O(P×S)，用网格空间哈希可降到近 O(P+S)。
--  4. ★ WorldGen_VoronoiPass 的**参数是迭代次数**，不是采样数（:499 传 100）。
--     加区域时降到 50（:503）—— 因为老点已经收敛，只微调新点。
--  5. ★★ ForceConnectivity(:536) 是连通性的**最终保证**，注释明说
--     "This also generates land tiles"。★ 但注释里的 \`prefab == "cave"\`
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
--  10.★ ⚠ :572 \`print(self.id.." Cant process points")\` —— Generate 是
--     local function，**没有 self 参数** ⇒ 一旦 #points_x==0 走到这里
--     必然 runtime error（attempt to index a nil value）。
--     推理依据：同函数内 :562 用的是 \`for k,node in pairs(nodes)\` 里的 node，
--     而 :572 写的是 self.id。⚠ 疑似缺陷（低概率触发，但一旦触发即崩）。
--============================================================`;

/* ══════════════════════════ network.lua ══════════════════════════ */

const HEADER_NETWORK = `--============================================================
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
--   · 本文件导出的全局 \`Graph\` 类，与 map/graphnode.lua 的全局 \`Node\` 类、
--     map/graphedge.lua 的 \`Edge\` 类构成一套**三角**：
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
--     ⚠ 且 :537 的 \`while not picked or picked.data.entrance == true\`
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
--     ⚠ 注意 :159-168 与 :180-189 的内层循环 \`for edge_id,edge in ipairs(...)\`
--     对**每条边都全量扫一遍** ⇒ O(N×E)。大型 task（数百节点）下这是
--     本文件最明显的性能热点（虽然总耗时仍在毫秒级）。
--  5. ★ :156/:177 \`table.insert(encoded.story_depths, self.story_depth)\`
--     —— ★★ 这里插的是 **Graph 的 story_depth**（即 task 级进度），
--     不是节点的。运行时 grottowarmanager.lua:201 拿它判断"同一区域"。
--  6. ★ GetRandomNode(:537) 的 \`while ... picked.data.entrance == true\`
--     无迭代上限 ⇒ 全 entrance 图会死循环（隐患，当前不可达）。
--  7. ★ GetRandomNodeForExit(:555) / ForEntrance(:567) 用
--     weighted_random_choice，★ 而 random_node_exit_weight == 0 的节点
--     被**完全排除**在候选之外（:558）。所以 START 节点（storygen.lua:1341
--     把权重设 0）永远不会被当成出入口 —— 这就是 START 被特殊保护的机制。
--  8. ★ ApplyPoisonTag(:1026) 把标签翻译成 C++ 位标志：
--     ForceDisconnected → ClearNodeLinks（断掉该节点的全部连线）；
--     ForceConnected → 0x2；RoadPoison → 0x4。★ 注意 flags 是**局部变量**
--     每节点从 0 重算，不是累加旧值。
--  9. ★ CrosslinkRandom(:592) 的 while 条件是 \`crossLinkFactor > 0 且
--     iterations < 20\` ⇒ **最多尝试 20 次**，不保证真的加够 factor 条边。
--     这是"尽力而为"而非"必须满足"。
--  10. ★ ProcessInsanityWormholes(:814) 的 NeighborNodes(:819) 用
--     \`assert(nextNode == nil, "We already have a node from this task!")\`
--     ⇒ ★★ 任何 OneshotWormhole 节点若在本图内有多于一个内部邻居
--     （crosslink / MakeLoop 都可能造成），**直接 assert 崩溃**。
--     这是本文件唯一一处"宁死不屈"的设计，且被 :846 的双邻居断言包围。
--============================================================`;

/* ══════════════════════════ graphnode.lua ══════════════════════════ */

const HEADER_GRAPHNODE = `--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/graphnode.lua（610 行）
-- 模块：世界生成 / 图节点 = 一个房间 = 一个 Voronoi 胞元
--
-- ★★★★★★ 【本文件核心机制清单】（【】= 机制，★ = 重点，⚠ = 疑似缺陷）
--   【Node 类】房间节点的实现。★ 一个 Node ⇒ 一个 Voronoi 站点 ⇒ 一块地形。
--   【node.data】房间的"元数据袋"：房间名 / biome / 尺寸 / 锁 / 钥匙 /
--     story_depth / tags / terrain_filter 等，几乎所有生成决策都挂在这里。
--   【AddNode / AddEdge】图的写入接口（storygen 通过它建整棵树）。
--   【PopulateVoronoi】★★ 撒资源的主循环：逐胞元按 biome 与 density 落地 prefab。
--   【SetTilesViaFunction】把房间布局 / 静态布局写进 tilemap。
--   【GetRoomLocation / FindEntityInRoom...】运行时按房间反查实体（跨生成期/运行期）。
--   【deepcopy 房间定义】从 map/rooms/*.lua 模板深拷贝出一个实例。
--   【room_functions】房间的地表装饰逻辑（草、石头、洞穴形态）。
--   ⚠【terrain_filter 只是挂载】node.data.terrain_filter 在 Lua 侧从不被读，
--     真正生效的是 forest_map / ocean_gen / components/map 那 4 个直读点。
--
-- ★★★ 0. Node 是什么
--   一个 Node 对应 map/rooms/ 里的一个**房间模板实例**（deepcopy 出来的）。
--   它带着这些数据参与世界生成：
--     .data.value         → 这个胞元压什么地面地块（WORLD_TILES.*）
--     .data.terrain_contents.countprefabs        → 定数摆放（如 flint=1）
--     .data.terrain_contents.distributeprefabs   → 权重散布（如 grass=0.5）
--     .data.terrain_contents.distributepercent   → 散布概率（0~1）
--     .data.terrain_contents.countstaticlayouts  → 静态场景件数量
--     .data.terrain_contents_extra               → 标签展开出来的东西
--     .data.type / .internal_type / .tags        → 拓扑与生成约束
--     .data.entrance / blocker_blank             → 门 / 封口
--   Voronoi 阶段后，C++ 给它算出一个胞元（polygon）与一批采样点
--   （points_x/points_y/points_type），★ 散布只遍历**采样点**，
--   不遍历格子（详见 PopulateVoronoi 的注释）。
--
-- ★★ 1. ★★★ 全文件只有 4 个"真正干活"的方法
--   ① ConvertGround(:247)     静态场景件（countstaticlayouts）落位
--   ② PopulateVoronoi(:330)   ★ 主散布：定数 prefab + 权重 prefab
--   ③ PopulateChildren(:498)  背景房间（task 级 background_room）散布
--   ④ PopulateExtra(:567)     世界生成设置的"加量"（>default 的项）
--   其余 20 多个方法都是 SaveEncode / 属性存取 / 钩子转发。
--
-- ★★ 2. ★ 随机数与可复现性
--   · ★ 本文件**零 randomseed**。
--   · 消耗随机的点：:321 GetRandomItem（swappable prefabs 解析）、
--     :458 math.random() < distributepercent、:582 math.random() < 0.25
--     （成簇 clumpcount 判定）、:593 pickspawnprefab（内含一次
--     math.random()*total）、:196-198 PopulateWorld_AddEntity 的 ±1 随机偏移。
--   · ★★ :196-199 的 \`if rand_offset == nil or rand_offset == true\` 意味着
--     **★ 省略参数与传 true 行为一致**（都加随机偏移），传 false 才固定。
--     而 forest_map.lua:613 的 add_fn 与 network.lua:856 都显式传了
--     rand_offset=false ⇒ 这两条路径的实体位置是**格子中心**，完全确定。
--     但 graphnode.lua:257 的 add_fn 也是 rand_offset=false。
--     ⇒ 真正带随机偏移的是 PopulateWorld_AddEntity 被
--       PopulateExtra(:598) 调用时 —— ★ 但它也没传（第 8 个参数后就没了），
--       实际上 data.idx_left 路径调用时 rand_offset 传入的是 nil ⇒ **会加偏移**。
--     ⇒ 结论：**散落实体的位置本身就不是纯随机的格子中心**，
--       这增加了"同种子同图"的验证难度（还受 float 精度影响）。
--
-- ★ 3. 交叉引用
--   Graph:AddNode → Node 构造 ................. map/network.lua:461 / 474
--   Edge 类 .................................. map/graphedge.lua
--   房间模板来源 .............................. map/rooms/*.lua
--   权重抽取 spawnFN.pickspawnprefab ......... map/forest_map.lua:16
--   按地块过滤 pickspawncountprefabforground . map/forest_map.lua:62
--   ★ 缺陷背景 ................................ E2（静默失败，bug-patterns.md）
--   prefab 改名映射 ........................... prefabswaps.lua
--   SaveEncode 的调用方 ........................ map/network.lua:120
--============================================================
--
--【阅读导航】
--  §零   依赖 / DENSITY_PRECISION / 两个 prefab 权重工具  (1-44)
--  §一 ★ recurseTable（★ 递归参数漏传的疑似缺陷）       (46-80)
--  §二   filterPrefabsForGlobalSwaps              (82-104)
--  §三 ★ Node 类构造（custom_tiles/objects 提前转钩子）(107-140)
--  §四 ★ SaveEncode（★ 坐标居中与取整精度）            (142-166)
--  §五 ★ PopulateWorld_AddEntity（★ 坐标换算的核心）   (188-235)
--  §六 ★ AddEntity（★ 非陆地直接丢弃）                (238-245)
--  §七 ★ ConvertGround（静态场景件 + scratchpad）      (247-279)
--  §八   自定义钩子 SetPopulate/Tiles + ViaFunction   (281-314)
--  §九 ★★ PopulateVoronoi（★ 主散布，E2 缺陷现场）    (330-495)
--  §十 ★★ PopulateChildren（★ perTerrain 混合地块）   (498-565)
--  §十一 ★★ PopulateExtra（世界生成设置的加量）        (567-610)
--
--【★★ 全文件最重要的十条】
--  1. ★★ 散布的单位是 **Voronoi 采样点**，不是格子。
--     :348 GetPointsForSite 返回 points_x/y/type，#points_x 就是这个
--     胞元"能用多少个位置"。Lloyd 松弛的迭代次数（forest_map.lua:499）
--     直接决定这个数 ⇒ ★ 群系大小不均 → distributepercent 的实际密度剧烈波动。
--  2. ★★ E2 缺陷现场：:369-372 \`if #points_x < floor(pos_needed) then return end\`
--     ⇒ **整个节点的所有 prefab 一个都不放**，只 print 一行。
--     :421-424 同理（中途放弃）。:392/:441 再加两处。
--     这是"玩家说地图上没东西、开发者复现不了"的根因。
--  3. ★★ :374-405 countprefabs_uses_filters 分支会
--     **table.remove 三条并行数组**（:389-391），把已用的点从池子里删掉。
--     ⚠ 疑似缺陷：循环条件是 \`while next(generate_these) ~= nil\`，
--       但内部 \`cur_pt = cur_pt - 1\` 与 \`table.remove\` 会让
--       cur_pt 与 #points_x 不同步 —— remove 之后 cur_pt 指向的元素已经左移，
--       实际是"从尾部往前扫并原地删"，逻辑上碰巧自洽但极易读错。
--       若 pickspawncountprefabforground 返回 nil（全部被地块过滤掉），
--       :397 仍然 cur_pt-1 ⇒ 会白扫一遍但不死循环（cur_pt 到 0 break）。
--  4. ★ :460 \`if prefab == nil then table.insert(idx_left, ...)\` ——
--     ★ idx_left 是"这个点没能放东西"的集合，随后交给 PopulateExtra。
--     所以 idx_left 的语义是"空位"，不是"失败位"。
--  5. ★★ :544 \`prefab_data.data = room.contents.prefabdata and
--     backgroundRoom.contents.prefabdata[prefab] or nil\`
--     ⚠ 疑似缺陷：当 perTerrain 为真（:536）时 room 是按地块选出来的，
--     这里却用 **backgroundRoom**（整体的、可能是 {地块→房间} 的表）
--     去索引 prefabdata ⇒ table 索引 table 会拿到 nil，
--     结果 prefab_data 恒为 nil。推理依据：:531 \`local room = backgroundRoom\`
--     在 perTerrain 时被 :537 改写，但 :544 用的仍是外层 backgroundRoom。
--  6. ★ :482 \`prefabDensities[self.id] = {}\` 位于 countprefabs 分支之后，
--     且 :491 的 removed 合并写在其后。★ 注意 :558 在 PopulateChildren 里
--     **又赋一次值**，会覆盖掉 PopulateVoronoi 在同一 site 上算的密度
--     （两者用同一个 self.id 作 key）⇒ 背景房间的密度会覆盖房间密度。
--     ⚠ 疑似缺陷（密度统计只用于前端/调试，影响面小）。
--  7. ★ getFilteredSpawnWeight(:10) 的 for 循环变量名叫 weightList，
--     但 :14-15 在 table 分支里读 \`weightList.weight\` —— ★★ 这个字段
--     在本文件里从不存在（resolveswappableprefabs:316 产出的表里
--     value 是数字不是 {weight=} 表）⇒ table 分支是**死分支**。
--  8. ★ recurseTable(:46) ⚠ 疑似缺陷：:52 \`v = recurseTable(v, fn)\`
--     ★ **漏传了 removed 参数**（应为 recurseTable(v, removed, fn)），
--     且返回值只接了第一个 ⇒ 递归层级里被删掉的 prefab 不会累计进 removed。
--     后果：嵌套层的 prefab 改名/停用会丢。⚠ 推理依据：:79 返回两个值，
--     :52 只接 1 个且第二个参数位置错位（fn 传给了 removed）。
--  9. ★ :54 \`local add, delete = fn(k, fn)\` —— ★ 把 **fn 自己**当第二个
--     参数传给了回调。回调签名是 fn(testData)（见 :86 / :91），只用第一个
--     参数 ⇒ 第二参无人读 ⇒ 无害但明显是复制粘贴残留。⚠ 疑似缺陷（无害）。
--  10. ★ :189 \`if _G.WorldSim ~= nil then WorldSim:ReserveTile(...)\` ——
--     WorldSim 是 C++ 注入的全局。★ 它的存在意味着这份脚本
--     **只能跑在离线 worldgen VM 里**，无法单元测试。
--============================================================`;

/* ══════════════════════════ lockandkey.lua ══════════════════════════ */

const HEADER_LOCKANDKEY = `--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/lockandkey.lua（536 行）
-- 模块：世界生成 / 锁—钥匙声明表（Lock & Key Declarations）
--
-- ★★★ 0. 本文件是**纯数据 + 启动期校验**，零运行时逻辑
--   它导出三个全局：
--     LOCKS_ARRAY (2) / LOCKS (77)    锁名 → 整数 ID
--     KEYS_ARRAY (84) / KEYS (165)    钥匙名 → 整数 ID
--     LOCKS_KEYS  (173)               锁 ID → {能开它的钥匙 ID 集合}
--   ★ 消费者只有两处：
--     map/storygen.lua:319-339 / 524-547（★ 真正的解锁判定在这里）
--     以及 tasks/*.lua、levels/*.lua 里的 locks= / keys_given= 字段。
--   ★ grep 核实：本文件不含任何 math.random，也不调用任何 WorldSim。
--
-- ★★ 1. ★★★ 本文件的核心规则（源码 171-172 行自己写了）
--     -- Locks are unlocked if ANY key is provided.
--     -- However, ALL locks must be opened for a task to be unlocked.
--       即：**单个锁是 OR 语义**（任一钥匙可开）；
--           **任务是 AND 语义**（所有锁都开才解锁）。
--     ⇒ 判定伪码（storygen.lua:341-347）：
--         for lock in task.locks:
--             if not any(key in availableKeys for key in LOCKS_KEYS[lock]):
--                 unlocked = false
--
-- ★★★ 2. ★★★★★ E1 缺陷现场：「锁—钥匙同名覆盖致不可达」的确切根因
--   ★★ **[LOCKS.TREES] 在 LOCKS_KEYS 里被定义了两次**：
--       · 第 219-223 行： [LOCKS.TREES] = { KEYS.AXE, KEYS.FIRE }
--       · 第 254-258 行： [LOCKS.TREES] = { KEYS.AXE, KEYS.PIGS }
--     ★ Lua 的 table 构造器对重复键是**后者静默覆盖前者**，
--       所以生效的是第 254 行那组，**KEYS.FIRE 永远打不开 TREES 锁**。
--   ★★ 为什么原版自带的校验（478-487）抓不到：
--       · 校验只遍历 pairs(LOCKS_KEYS) —— ★ 而 pairs 看到的是
--         **覆盖之后的结果表**，重复的那一份根本不在表里，无从遍历。
--       · 源码 486 行自己承认了这个盲区：
--         "NOTE: This will **NOT** catch it if the typo is in the last key
--          in the list. ... But it's better than nothing..."
--       · ★ 对本例而言比"最后一个 key"更糟：整个键值对都被覆盖了，
--         而校验逻辑对此完全无感。
--   ★★ 为什么第 39 行还留着 \`--"ADVANCED_COMBAT"\`：
--     LOCKS_ARRAY 第 18 行已有 "ADVANCED_COMBAT"（第 204 行有用到它），
--     第 39 行是把它注释掉的重复项。★ 若有人手贱取消注释，
--     78-81 行的 \`assert(LOCKS[v] == nil, "Lock "..v.." is defined twice!")\`
--     会立刻报错 —— ★ 这说明 **LOCKS_ARRAY 侧有重复检测，LOCKS_KEYS 侧没有**。
--     这就是不对称的根因。
--   ★★ 实际后果【已双向 grep 复核 · 修正 bug-patterns.md E1 的表述】：
--     · 生效钥匙集 = { AXE, PIGS }，★ AXE 与 PIGS **都还在**。
--     · 用到 LOCKS.TREES 的任务只有 3 个，且 keys_given **全部含 KEYS.PIGS**：
--         map/tasks/forest.lua:148 / :164
--         map/tasks/dst_tasks_forestworld.lua:289
--     · KEYS.AXE 由【首个任务】给出，而该任务 locks=LOCKS.NONE
--       （forest.lua:9-10）⇒ 开局即持有 AXE 与 PIGS ⇒ TREES 必然可开。
--     · ★★ 更关键：KEYS.FIRE **全仓从未被任何 task 的 keys_given 发放**
--       （grep KEYS.FIRE 仅命中本文件 :222 与 :227）⇒
--       即使不覆盖，FIRE 也永远拿不到；覆盖成 PIGS 反而【多了一条路】。
--     ⇒ 结论：在【原版自带任务集】下**不会造成玩家不可达**。
--       真正的问题是 ① LOCKS_KEYS 侧缺查重（结构性隐患）；② FIRE 成为
--       一把设计上发不出来的【死钥匙】（语义失效）；③ 一旦有 MOD 关卡
--       想用「FIRE 开路」，立刻退化为拓扑级不可达（那条 exit_edge
--       根本不会被创建 ⇒ 不是"门打不开"而是"路没生成"，
--       而 storygen 的逃生阀会强行乱连一条边 ⇒ 表现为"地图不合逻辑"）。
--     ★ 教训：排查此类问题不能只看 LOCKS_KEYS 的定义，必须双向核对
--       「每把钥匙是否真被某个 task 的 keys_given 发出过」。
--       ★ 也要区分【结构性缺陷】与【实际触发后果】：前者必修，后者定优先级。
--   ★★ 修复建议（本项目严禁改原版代码，仅记录）：
--     ① 改成数组声明 + 启动期显式查重；
--     ② 补一条「每个 KEYS_ARRAY 的钥匙至少被一个 task 的 keys_given 发出」
--        的反向校验（当前完全没有）—— 这条能直接抓出 FIRE 这类死钥匙。
--
-- ★★ 3. ★ 另一处容错设计：SKIP_THESE_MISSING_KEYS_AND_LOCKS（498-510）
--   白名单承认有 6 个 key/lock 被引用但从未声明：
--     key:  SILK / ROCKS / TALLBIRDS / SWAMP
--     lock: SPIDERDEN
--     两者: ROCKY
--   ★ 这些名字在 LOCKS_ARRAY / KEYS_ARRAY 里都**没有**（grep 核实）。
--   ⇒ 引用它们的 task 在 \`LOCKS.ROCKY\` 之类处会取到 **nil**。
--   ★ CRASH_ON_MISSING_KEY_OR_LOCK = (BRANCH == "dev")（511）：
--     只有 dev 分支才通过 __index 元表把 nil 变成 error。
--     ★ 正式分支里 \`LOCKS.ROCKY\` 返回 nil（不报错），
--       于是 storygen.lua:857 的 \`task.locks[1] == LOCKS.NONE\` 之类
--       判定会走"非 nil"分支 ⇒ 起始任务筛选被污染。
--     ⇒ 这是 E1 的**第二个根因面**：未声明常量静默变 nil。
--
-- ★ 4. 交叉引用
--   解锁判定的两处实现 ................. map/storygen.lua:319-347（批量分支）
--                                          map/storygen.lua:524-557（逐个贪心）
--   起始任务筛选（用到 LOCKS.NONE） .... map/storygen.lua:857
--   LockGraph 写入 exit_edge ............ map/network.lua:257
--   实际使用 LOCKS_KEYS 的循环 ......... map/storygen.lua:333 / 536
--   ★ E1 缺陷档案 ....................... 04-skill/dst-survival-dev/
--                                          references/bug-patterns.md §E1
--============================================================
--
--【阅读导航】
--  §零   LOCKS_ARRAY（★ 78 个锁名，39 行有注释掉的重复项）(1-75)
--  §一 ★ LOCKS 构建 + 重复检测（★ 这是唯一有查重的地方） (77-81)
--  §二   KEYS_ARRAY（75 个钥匙名）                    (83-164)
--  §三 ★ KEYS 构建 + 重复检测                          (165-169)
--  §四 ★★ 语义规则注释（OR 开锁 / AND 解任务）          (171-172)
--  §五 ★★ LOCKS_KEYS 全表（★★ TREES 重复键在 219 与 254）(173-475)
--  §六 ★★ 启动期自校验（★ 为什么抓不到重复键）          (477-487)
--  §七 ★★ 未声明 key/lock 的白名单与 dev-only 崩溃      (489-529)
--  §八   被注释掉的调试打印                            (531-537)
--
--【★★ 全文件最重要的八条】
--  1. ★★★★★ **[LOCKS.TREES] 重复定义**：219 行 {AXE, FIRE} 被
--     254 行 {AXE, PIGS} 静默覆盖 ⇒ FIRE 永远开不了 TREES。
--     ⇒ 这就是 bug-patterns.md E1 的确切根因与行号。
--  2. ★★ 校验器（478-487）遍历 pairs(LOCKS_KEYS) 只能看到覆盖后的结果，
--     结构上不可能发现重复键。源码 486 行自己承认了盲区。
--  3. ★ LOCKS_ARRAY 侧有 \`assert(LOCKS[v] == nil, "... defined twice!")\`（79）
--     而 LOCKS_KEYS 侧没有 —— ★ 查重能力不对称就是缺陷的温床。
--  4. ★★ 规则一句话：锁是 OR，任务是 AND（171-172 行源码注释）。
--  5. ★ SKIP_THESE_MISSING_KEYS_AND_LOCKS（498）承认 6 个未声明名，
--     CRASH_ON_MISSING_KEY_OR_LOCK 只在 dev 分支生效（511）。
--     ⇒ 正式分支里未声明常量 = 静默 nil，会污染 storygen.lua:857 的起点筛选。
--  6. ★ 表里的注释性分组（月岛 / 海洋 / Quagmire / ISLAND_TIER）在
--     224/237/506-509 等处可以看出**同一概念要在两套 ID 空间各写一遍**，
--     这正是"同名覆盖"类缺陷的高发土壤。
--  7. ★ 全表 300 行里，LOCKS 有 78 项而 LOCKS_KEYS 只定义了约 60 项
--     —— ★ 未定义的锁（grep 可验证，如 ONLYTIER1 之外的一些）在
--     storygen.lua:333 遍历 \`lockData.keys\` 时会拿到 nil
--     ⇒ ★★ **nil 遍历在 Lua 里是崩溃**（attempt to iterate a nil value）。
--     对照 storygen.lua:333：\`for reqKeyIdx, reqKey in ipairs(lockData.keys)\`。
--     ★ 所以真实约束是：**LOCKS_KEYS 必须覆盖 tasks/*.lua 里用到的每个锁**，
--     这条约束没有任何校验保护，纯靠人肉维护。
--  8. ★ 本文件在 require 时就做全部校验（78/166/478/513 行都在模块顶层），
--     ⇒ 任何声明错误都会在**世界生成开始之前**崩溃，而不是生成到一半。
--     这是本文件唯一值得学习的设计。
--============================================================`;

/* ══════════════════════════ tasks.lua ══════════════════════════ */

const HEADER_TASKS = `--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/tasks.lua（184 行）
-- 模块：世界生成 / 任务注册中心（Task Registry）
--
-- ★★★★★★ 【本文件核心机制清单】（【】= 机制，★ = 重点，⚠ = 疑似缺陷）
--   【taskdefinitions】全局注册表。map/tasks/*.lua 用 AddTask 往里塞数据。
--   【region_tasksets】★ 按【区域】再分一层：mainland / ocean / ruins_island 等。
--     ★ storygen.lua:86 的 GenerateNodesFromTasks 只吃 region_tasksets["mainland"]。
--   【AddTask】注册入口，同时兼容 AddTaskSet（见 map/tasksets.lua）。
--   【keys_given / locks】★ 锁—钥匙体系的【数据侧】。locks 是 AND 语义，
--     单个锁是 OR 语义（任一钥匙即可）。判定实现在 map/lockandkey.lua。
--   【room_choices / background_room】房间组合，可为数字或函数（返回随机数量）。
--   【ordered_story_setpieces】★ 叙事场景件的**有序**播放列表（与图结构不同层）。
--   【ChooseTasks / ChooseSetPieces】★ 在 level.lua 里被调用，按区域抽任务。
--   ⚠【本文件只注册、不执行】★ 零运行时逻辑，纯数据 + 启动期校验。
--   ⚠【注册顺序影响剧情】★ taskdefinitions 的插入顺序决定候选顺序，
--     而 ChooseTasks 用 GetRandomItem 抽取 ⇒ 顺序变了世界就变。
--
-- ★★★ 0. 本文件 = 一张全局注册表 + 两条注册路径
--   · taskdefinitions      —— 本文件与 map/tasks/*.lua 用 AddTask 注册
--   · modtaskdefinitions{} —— mod 用 AddModTask 注册，按 mod 名分桶
--   ★ Task 基类见 map/task.lua:1（只有 36 行，纯字段搬运）。
--   ★ 真正被生成用的任务**列表**由 map/level.lua:89 ChooseTasks 从
--     task_set（tasksets.lua）里挑出来 —— ★ 本文件**不做挑选**。
--
-- ★★ 1. ★ 为什么 tasks.lua 里有三个 TEST_TASK
--   142-173 行注册了 TEST_TASK / TEST_TASK1 / TEST_EMPTY。
--   ★ 它们是**永久留在正式注册表里的调试任务**（不是被 #if 掉的）。
--   它们的锁关系构成一条最小可验证链：
--     TEST_TASK  locks=NONE        keys_given=LIGHT
--     TEST_TASK1 locks=LIGHT       keys_given=CAVE    ← 必须先拿 LIGHT
--   ⇒ 用 task_set = {...TEST_TASK, TEST_TASK1} 就能在几秒内
--     验证锁—钥匙连线是否正确，而不用生成完整世界。
--   ★ 这正是**最小可验证世界**（MWV）的手工范例。
--   ⚠ 但它们的代价是：所有 task 名的线性查找（GetTaskByName，:28）
--     都要多扫 3 项，且前端任务列表里可能出现它们。
--     （★ grep 核实：tasknames.lua 是否过滤 TEST_ 未在本文件内，
--     过滤逻辑在别处或依赖 hideinfrontend 机制。）
--
-- ★★ 2. ★★ SIZE_VARIATION（:5）—— 房间数量的随机抖动
--   全局变量 SIZE_VARIATION = 3，被 tasks/*.lua 里的
--   \`function() return 1 + math.random(SIZE_VARIATION) end\` 消费
--   （★ grep 核实：map/tasks/dst_tasks_forestworld.lua:12/14/27/…
--     map/rooms/cave/vents.lua:143-144）。
--   ★★ 它是**全局可变的**，因此：
--     ① 它必须在**所有 task 定义被 require 之前**设定好（本文件第 5 行，
--        而 require 在 127-136 行 —— 顺序正确）；
--     ② 任何 mod 若在别处改写它，会改变所有房间数量；
--     ③ ★ 因为它只在**函数被调用时**才读（math.random 在闭包内），
--        所以求值时机 = GenerateNodesFromTask 的 :1264-1266
--        （\`if type(count) == "function" then count = count() end\`）
--        ⇒ ★★ **房间数量是在建图阶段现场摇的**，且每次摇都吃随机数。
--        这直接放大了 pairs 顺序对最终地图的影响。
--
-- ★ 3. 交叉引用
--   Task 基类 ......................... map/task.lua:1
--   ★ 消费方：Level:EnqueueATask ......... map/level.lua:219-227
--   ★ 挑选：Level:ChooseTasks ........... map/level.lua:89-150
--   task_set 定义 ...................... map/tasksets.lua
--   真正的任务内容（房间组合） ......... map/tasks/*.lua（9 个文件）
--   mod 钩子 TaskPreInit ............... map/level.lua:47
--============================================================
--
--【阅读导航】
--  §零   依赖 / SIZE_VARIATION 全局（★ 求值时机敏感）    (1-9)
--  §一 ★ 三个模块内查找函数（★ O(N) 线性扫描）            (11-51)
--  §二 ★ AddTask / AddModTask（★ 两条注册路径的不对称）    (53-70)
--  §三   两个 sample 任务集（调试用模板）                  (73-125)
--  §四 ★ 9 个 tasks/*.lua 的 require 顺序                (127-136)
--  §五 ★ TEST_TASK 三件套（★ 最小可验证世界）            (138-173)
--  §六   导出表                                         (175-185)
--
--【★★ 全文件最重要的六条】
--  1. ★★ 本文件只做「注册」不做「挑选」。挑选在 map/level.lua:89
--     ChooseTasks，靠 overrides["task_set"] 查 tasksets.lua。
--  2. ★★ SIZE_VARIATION（第 5 行）是全局可变的随机抖动源，
--     在 GenerateNodesFromTask 的 :1264-1266 现场求值 ⇒ 每次建图都吃随机数。
--  3. ★ GetTaskByName(:28) 是 **O(N) 线性扫描**，且要扫两遍
--     （taskdefinitions + 每个 mod 的桶）。N 大时是热路径。
--     ★ 但它只在 ChooseTasks（一次）与 AddTask（启动期）被调用，
--     所以不是生成期瓶颈。
--  4. ★ AddTask 用 assert 拦重复（:58），★ AddModTask 用 moderror
--     且**直接 return 不插入**（:64-66）⇒ mod 的重复任务名是"静默跳过"
--     而非崩溃。这是一个不对称，但 moderror 会弹提示，可接受。
--  5. ★★ TEST_TASK / TEST_TASK1 / TEST_EMPTY 是**常驻调试任务**，
--     且 TEST_TASK→TEST_TASK1 构成一条两环的锁—钥匙链，
--     可作为最小可验证世界（MWV）的现成样本。
--  6. ★ everything_sample / everything_sample2（:78/:93）是"每样东西
--     都来一份"的全房间穷举模板，用于人工目检。★ 只有 sample2 被导出
--     （:180），sample 未导出 ⇒ 死数据。
--============================================================`;

/* ══════════════════════════ task.lua ══════════════════════════ */

const HEADER_TASK = `--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/task.lua（42 行）
-- 模块：世界生成 / 任务基类（Task Base Class）
--
-- ★★★ 0. 本文件只有 36 行有效代码，是全 map/ 目录最短的类文件。
--   它的唯一职责：**把 map/tasks/*.lua 里那些字面量表，搬成带类型的对象**。
--   绝大部分"行为"（这个任务要生成哪些房间）由 storygen.lua:1232
--   GenerateNodesFromTask 解释执行，本类只负责**声明式数据**。
--
-- ★★★ 1. ★ 本类最重要的两行：第 8-10 与 13-15 行的「标量升表」归一化
--     locks:       LOCKS.NONE（数字）→ { LOCKS.NONE }（表）
--     keys_given:  KEYS.PICKAXE（数字）→ { KEYS.PICKAXE }（表）
--   ★ 为什么重要：★ storygen.lua:319 / 324 / 524 / 617 四处
--     一律用 \`ipairs(self.tasks[...].locks)\` 遍历。
--     如果 tasks/*.lua 里有人写 locks = LOCKS.NONE 而忘了归一化，
--     ipairs(数字) 会**直接崩溃**。⇒ 归一化在构造期把两种写法都变成表，
--     换来「写数据的人不必关心 arity」的自由。
--   ★ 但归一化只处理"标量→表"，**不处理 nil**：
--     ⚠ 若某个 task 完全不写 locks，第 7 行 self.locks = nil，
--       第 8 行 type(nil) ~= "table" ⇒ self.locks = { nil }
--       ⇒ ★★ **一个只含 nil 的表**。ipairs 遍历它立刻结束（看起来正常），
--         但 :319 的 \`LOCKS_KEYS[v]\` 中 v 为 nil 时
--         ★ \`LOCKS_KEYS[nil]\` 在 Lua 中是**读取** nil 键（合法，返回 nil），
--           而 :333 \`ipairs(lockData.keys)\` 中 keys 为 nil ⇒ ★★ **崩溃**。
--       ⇒ 这是"漏写字段 ⇒ 后期神秘崩溃"的典型陷阱。
--       （★ 推理依据：Lua 里 t[nil]=v 读取合法返回 nil，t[nil]=v 赋值才报错。）
--     ⇒ 现实里所有 task 都写了 locks（tasks/*.lua），所以不触发。
--
-- ★★ 2. ★ 字段分组（★ 记住这三组，后面 storygen 逐一消费）
--   【锁钥匙组】 locks / keys_given / region_id
--   【房间组成】 entrance_room(+_chance) / room_choices /
--              room_choices_special / room_bg / background_room /
--              cove_room_name / cove_room_chance / cove_room_max_edges
--   【拓扑形状】 hub_room / make_loop / crosslink_factor
--   【环境约束】 room_tags / required_prefabs / maze_tiles / maze_tile_size
--   【配色/产物】 colour / level_set_piece_blocker
--
-- ★★ 3. ★★ 声明了但**本类没有搬运**的字段（★ 重要：漏字段 = 静默失效）
--   grep 逐字段比对 map/tasks/*.lua 的写法可以发现，本类未搬运的常见字段包括：
--     · substitutes —— ★★ tasks/*.lua 里大量使用（资源替换），
--       ★ 但 Task 类**没有 self.substitutes**！
--       ★ 而 storygen.lua:1216 \`for k,v in pairs(task.substitutes)\` 与
--         :1285 \`task_node.substitutes = task.substitutes\` 都在读它。
--         ⇒ 解��：substitutes 是由 map/level.lua:69-73 **运行时挂到
--         tasklist 里的 deepcopy 上的**（GetOverridesForTasks），
--         不走 Task 构造函数。★ 正确但极易误读。
--     · set_pieces / random_set_pieces —— 同样由 level.lua:180-210
--       在 ChooseSetPieces 阶段挂载，不走构造函数。★ 一致的设计。
--     · background_room ★ 有搬运（:23），但 graphnode 的 backgroundRoom
--       实际来自 task_node.data.background（network.lua:738）
--       ⇒ ★ 那条链是 storygen.lua:1284 的 Graph 构造参数
--         \`background=task.background_room\`。
--
-- ★ 4. 交叉引用
--   注册 ..................... map/tasks.lua:57 / 62
--   被解释执行 .............. map/storygen.lua:1232 GenerateNodesFromTask
--   ★ locks/keys_given 消费 ... map/storygen.lua:319/324/524/617（ipairs）
--   room_choices 消费 ........ map/storygen.lua:1261-1282
--   entrance_room 消费 ....... map/storygen.lua:1237-1259
--   hub_room / make_loop ..... map/storygen.lua:1351-1380
--   substitutes 挂载 ......... map/level.lua:69-73（运行时，非构造期）
--   room_tags 消费 ........... map/storygen.lua:1035 / 1070 / 1133 / 1324
--   region_id 消费 .......... map/storygen.lua:64
--============================================================
--
--【阅读导航】
--  §零   依赖（★ require 本文件不会自动拉 lockandkey）        (1)
--  §一 ★★ Task 构造（★ 36 行 = 全部字段搬运 + 两次归一化） (1-36)
--  §二   __tostring（★ 唯一的"行为"，只为日志好看）         (38-40)
--
--【★★ 全文件最重要的五条】
--  1. ★★ 第 8-10 / 13-15 行的标量→表归一化是**全库锁算法的隐式契约**：
--     storygen 的四处 ipairs 遍历都依赖它。不写 locks 会得到 {nil}
--     而在 :333 崩溃。
--  2. ★★ 本类**不搬运** substitutes / set_pieces / random_set_pieces，
--     它们由 map/level.lua 在运行时挂载。★ 读代码时若在 Task 上找不到
--     substitutes，不是 bug，是设计。
--  3. ★ region_id 决定任务进哪个 region_tasksets（storygen.lua:64），
--     缺省 "mainland" ⇒ 绝大多数 task 都在大陆。
--  4. ★ room_bg 与 background_room 是**两件事**：前者是胞元地面地块
--     （storygen.lua:1284 → WorldSim:AddChild），后者是胞元外圈
--     残留空地用的背景房间（network.lua:738 → PopulateChildren）。
--     ★ 混用会导致"胞元内是草地、胞元外是洞穴背景"。
--  5. ★ level_set_piece_blocker（:35）是个纯过滤器：置 true 后该 task
--     拿不到任何 level 级 set_piece（level.lua:155-157 把它筛掉）。
--============================================================`;

/* ══════════════════════════ level.lua ══════════════════════════ */

const HEADER_LEVEL = `--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/level.lua（244 行）
-- 模块：世界生成 / 关卡定义与任务挑选（Level & Task Selection）
--
-- ★★★★★★ 【本文件核心机制清单】（【】= 机制，★ = 重点，⚠ = 疑似缺陷）
--   【Level 类】一份「世界预设」的内存表示，数据来自 map/levels/*.lua 的字面量表。
--   【overrides】★★ 玩家在世界生成界面上的所有设置。
--     ★ forest_map.lua:393 深拷贝它作为工作副本，之后翻译成 story_gen_params。
--   【location / level_type】forest / cave 等，决定走哪条生成分支。
--   【ChooseTasks】★★ 按 region_tasksets 抽任务，塞进 self.taskdefinitions。
--   【ChooseSetPieces】抽"场景件"（setpiece）——★ 与 task 是两套并行的注册表。
--   【required_prefabs】★★ 硬性要求：必须放进地图的 prefab 及数量。
--     ★ forest_map.lua:926-974 会三重累加校验，缺一个就 return nil 重试。
--   【blocker_blank / blocker_entrance】"锁"的房间模板（门 = impassable 地块）。
--   【ocean_prefill_setpieces / ocean_population】海洋世界的专属配置。
--   【AddSetPeices】被 worldgen_main.lua:403 调用，把 boons/touchstone 等加进来。
--   ⚠【两套注册表并存】★ taskdefinitions（任务）与 set_pieces（场景件）
--     结构相近但独立演进 ⇒ 移植时容易只搬一套。
--   ⚠【assert 式硬迁移】本文件用 assert 强制新字段，与 terrain.lua 的
--     moderror 软弃用风格并存（两种手法各有一致性风险）。
--
-- ★★★ 0. 本类的身份：★ 一份「世界预设」（Level）的内存表示
--   数据来源是 map/levels/*.lua 里的一堆字面量表（玩家在前端选的那个预设）。
--   它做三件事：
--     ① 构造期强制迁移 —— ★ 用 4 个 assert 把旧字段迁移声明为硬错误
--        （:16/:18/:20/:22），逼 mod 作者改用 task_set。
--     ② ChooseTasks(:89) —— 从 task_set 取出任务列表，施加 mod 钩子，
--        处理可选任务，施加资源替换，得到 chosen_tasks。
--     ③ ChooseSetPieces(:162) —— 把关卡级的场景件分配到各任务上。
--
-- ★★ 1. ★★ 四条「硬 assert」＝迁移契约（★ 本文件最重要的设计）
--   :16  assert(data.set_pieces == nil, "level 'set_pieces' should be
--         specified as an override via 'task_set' now.")
--   :18  assert(data.numoptionaltasks == nil, ...)
--   :20  assert(data.optionaltasks == nil, ...)
--   :22  assert(data.valid_start_tasks == nil, ...)
--   ★ 这四条把**曾经支持过、现已废弃的写法变成了启动期崩溃**，
--     而不是静默忽略。这是全 map/ 目录最值得学的迁移手法：
--     **宁可让老 mod 立刻崩，也不要让它"看起来在工作但效果不对"。**
--   ★ 注意紧跟其后的 self.set_pieces = nil 等四行是**冗余的**
--     （assert 已保证输入为 nil），但保留它们明确了"该字段现在恒为 nil"，
--     使后续 reader 不会再去 data 里找。这是**防御性冗余**。
--   ★ 唯独 ordered_story_setpieces（:27）与 override_triggers（:15）
--     没有 assert —— ★ 前者只写了 "-- Deprecated" 注释，
--     后者标了 "--UNUSED" 但**仍然被搬运**。⇒ 迁移不彻底。
--
-- ★★ 2. ★★ ChooseTasks(:89) 的执行顺序（★ 顺序本身就是语义）
--   :92   assert(overrides["task_set"] ~= nil)  ← ★ 必须显式声明 task_set
--   :94   tasksets.GetGenTasks(task_set)         （内部 deepcopy）
--   :95-104 mod 钩子：TaskSetPreInit(task_set) → TaskSetPreInitAny()
--   :106  assert(task_set_data ~= nil)  ← 含"预设是带 mod 建的"提示
--   :108-110 ★★ \`for k,v in pairs(task_set_data) do self[k] = v end\`
--         —— **把 task_set 表里的所有字段直接覆盖到 Level 上**。
--         这意味着 tasksets/*.lua 里的表**拥有与 Level 构造同等的权力**，
--         可以覆盖 location / overrides 等任何字段。
--         ⇒ ★ 这是本文件最大的可扩展性也是最大的失控点。
--         ⚠ 疑似缺陷：:95-104 的 mod 钩子在 :108 的字段拷贝**之前**，
--           所以 mod 对 task_set_data 的修改会生效；但 :112-121 的
--           LevelPreInit 钩子在**之后**，此时 self 已被 task_set 覆盖，
--           mod 若想改回原始 level 字段需要自己备份。顺序陷阱。
--   :112-121 mod 钩子：LevelPreInit(id) → LevelPreInitAny()
--   :123-125 ★ 必需任务入队（#self.tasks）
--   :127   ApplyModsToTasks（TaskPreInit(task.id) 逐任务）
--   :129-145 可选任务：shuffleArray(optionaltasks) 后取 numoptionaltasks 个
--   :147   GetOverridesForTasks → 挂 substitutes
--   :149   self.chosen_tasks = tasklist
--
-- ★★ 3. ★★ ChooseSetPieces(:162) 的「一个场景件一个任务」不变量
--   :168-174 先把 required_setpieces deepcopy 出来，并追加
--            numrandom_set_pieces 个随机场景件。
--   :176-185 逐个场景件随机挑一个 task 塞进 task.random_set_pieces。
--            ★ 此时**不检查重名** ⇒ 同一个 task 可能拿到多个。
--   :187-216 另一条路：self.set_pieces（★ 被 :16 assert 强制为 nil，
--            所以 ★★ 这段是**完全的死代码**）。
--            它内部的 :202-203 注释写着
--            "Only one layout per task, so we stop when we run out of tasks"
--            —— ★ 那个"一任务一场景件"的不变量**只在这段死代码里存在**。
--   ⇒ 结论：★ 当前生效的路径（:176-185）**不保证**该不变量，
--     同一任务可能拿到 N 个场景件。storygen.lua:263-295 的
--     InsertAdditionalSetPieces 会为每个名字各找一次随机节点，
--     ★ 所以最终仍可能塞进同一节点两次不同场景件（不覆盖，累加）。
--     ⚠ 疑似缺陷（表现层无害，但会让"场景件应该分散开"的直觉失效）。
--
-- ★★ 4. ★★ GetOverridesForTasks(:55) —— 资源替换的三层语义
--   :59 注释 "WE MAKE ONE SELECTION FOR ALL TASKS or ONE PER TASK"：
--     · perstory（:68）—— **每个任务各自摇一次** math.random()，
--       决定"这个任务要不要替换"。
--     · pertask（:73）—— 替换后新资源的**占比**。
--     ⇒ 「要不要换」在任务粒度随机，「换了占多少」是固定百分比。
--     ⇒ 效果：同一个世界里，有的任务全用替代资源，有的不换。
--   ★ 消费方是 storygen.lua:1211 RunTaskSubstitution：
--     percent==1 或 nil ⇒ **整换**（items[v.name]=items[k]; items[k]=nil）
--     否则 **按比例拆分**（items[v.name]=items[k]*p; items[k]=items[k]*(1-p)）
--     ⇒ ★★ 「pertask」不是"替换概率"而是"替换占比"，
--     这个命名极易误导。
--
-- ★★ 5. ★★ 随机数消耗点（★ 影响可复现性）
--   :67   math.random()                      perstory 判定（逐任务！）
--   :130  shuffleArray(optionaltasks)        可选任务洗牌
--   :172  math.random(#random_set_pieces)    随机场景件
--   :178  math.random(#tasks)                ★ 每个场景件都摇一次
--   :204  math.random(#choices)              （死代码内）
--   ⚠ :178 的 \`local idx = math.random(#tasks)\` 取到的是 tasks 数组的
--     下标 ⇒ 但 tasks 是从 chosen_tasks 过滤出来的**数组**（:154-158
--     用 table.insert）⇒ 顺序稳定 ⇒ 这里没有 pairs 陷阱。✔
--
-- ★ 6. 交叉引用
--   ★ 任务挑选的结果流向 ....... map/forest_map.lua:495 → storygen.lua:849
--   Task 基类 .................. map/task.lua:1
--   task_set 定义 .............. map/tasksets.lua:53 AddTaskSet
--   任务名查表 ................. map/tasks.lua:28 GetTaskByName
--   ★ substitutes 的运行时挂载 . 本文件 :73（不是 Task 构造）
--   ★ substitutes 的消费 ....... map/storygen.lua:1216 RunTaskSubstitution
--   level 数据源 ............... map/levels/*.lua
--   资源替换表 ................. map/resource_substitution.lua
--   ★ choices 的清单位置 ....... map/level.lua:310 worldgen_main.lua
--============================================================
--
--【阅读导航】
--  §零   依赖与 Level 构造（★ 四条硬 assert 迁移契约）    (1-41)
--  §一   ApplyModsToTasks（TaskPreInit 钩子）             (43-53)
--  §二 ★★ GetOverridesForTasks（perstory / pertask）      (55-83)
--  §三 ★★ ChooseTasks（★ 整个生成流程的任务入口）        (85-150)
--  §四   GetTasksForLevelSetPieces（★ blocker 过滤）     (152-160)
--  §五 ★★ ChooseSetPieces（★ 一半是死代码）              (162-217)
--  §六   EnqueueATask / SetID / SetBaseID / SetNameAndDesc (219-244)
--
--【★★ 全文件最重要的八条】
--  1. ★★ 四条 assert（:16/:18/:20/:22）把废弃字段变成启动期崩溃，
--     是全 map/ 最值得学的迁移手法。但 ordered_story_setpieces(:27)
--     与 override_triggers(:15) 迁移不彻底。
--  2. ★★ ChooseTasks 的 :108-110 \`self[k] = v\` 让 task_set 表拥有
--     与 Level 构造同等的字段覆盖权 —— 可扩展性最大、失控点也最大。
--  3. ★★ mod 钩子顺序陷阱：TaskSetPreInit(:95) 在字段拷贝(:108) **之前**，
--     LevelPreInit(:112) 在**之后**。
--  4. ★★ GetOverridesForTasks 的 perstory = "要不要换"（逐任务随机），
--     pertask = "换了占多少"。★ "pertask" 这个名字极具误导性。
--  5. ★★ ChooseSetPieces 的 :187-216 是**完全死代码**（被 :16 assert 杀死），
--     "一任务一场景件"的不变量只存在于死代码里；当前生效的 :176-185
--     不保证该不变量。⚠ 疑似缺陷（表现层无害）。
--  6. ★ Level 的 worldgen_* 镜像字段（:232/:237/:244）是为序列化而存在
--     （前端与 worldgen VM 之间传参用），不可删。
--  7. ★ optionaltasks 支持嵌套表（:134-138）⇒ 「一组任务当一个槽位」，
--     ★ 但 numtoadd 在嵌套分支里按**内层元素个数**递减（:137），
--     而外层 i 只 +1（:143）⇒ ★★ 若第一个槽位是含 10 个任务的表，
--     numoptionaltasks=3 会被一次性塞满 10 个。⚠ 疑似缺陷。
--  8. ★ EnqueueATask(:223) 做 deepcopy(task) ⇒ ★★ 每个任务在
--     ChooseTasks 阶段被完整深拷贝一次。这是生成期的固定开销之一
--     （约 40~100 个任务 × 任务表大小）。
--============================================================`;

/* ══════════════════════════ terrain.lua ══════════════════════════ */

const HEADER_TERRAIN = `--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：map/terrain.lua（174 行）
-- 模块：世界生成 / 地形过滤表（Terrain Filter）
--
-- ★★★★★★ 【本文件核心机制清单】（【】= 机制，★ = 重点，⚠ = 疑似缺陷）
--   【TERRAIN_FILTER】★★ prefab → **禁止出现**的地块列表（黑名单语义）。
--     ★★ 方向最容易搞反：表里列的是"不能长"的地块。
--   【OnlyAllow】7 处白名单写法：遍历全部已注册地块取补集。
--     ★ 补集相对于"当前已注册地块"求 ⇒ 新增地块自动进黑名单。
--   【ARCHIVE / VAULT 追加】require 时给每条规则 in-place 追加 3 个地块
--     ⇒ 存档区（档案馆/保险库）里任何植物都不长。★ 靠数据表兜底。
--   【terrain.filter.Print】调试用，打印黑名单的可读形式。
--   【弃用 shim】terrain.rooms 走 __index 转 Rooms.GetRoomByName，
--     ★ 仍返回正确结果但每次访问 moderror —— 老 mod 不崩、开发者能定位。
--   ⚠【风格 A 列表地狱】134 行里绝大多数是显式黑名单枚举，
--     新增地块时**不会**自动被排除（与 OnlyAllow 相反）—— 真实维护陷阱。
--   ⚠【横跨两个时代】components/map.lua:613-614 运行时也在读这张表，
--     改动影响面远大于"一张 134 行的表"的观感。
--
-- ★★★ 0. 本文件只有两张表 + 一个兼容 shim，是 map/ 里最"纯数据"的文件
--   ① TERRAIN_FILTER（:14-147）—— **prefab → 禁止出现的地块列表**。
--      ★★ 注意语义方向：表里列的是**不能长**的地块，不是能长的。
--   ② 对老 API terrain.rooms 的弃用 shim（:164-174）。
--
-- ★★ 1. ★★★ TERRAIN_FILTER 的语义（★ 最容易搞反的一处）
--   -- These items will not spawn on a terrain tile of the types in the
--      list provided                                     （:13 原注释）
--   例：berrybush = { ROAD, WOODFLOOR, SCALE, CARPET, CHECKER, ROCKY,
--                     MARSH, DIRT, DESERT_DIRT, MONKEY_DOCK }
--   ⇒ 浆果丛**不会**长在道路、地毯、岩石地、沼泽、沙地、猴岛码头。
--     它会长在草地、森林、瓷砖地上（凡不在表里的都允许）。
--   ★ 两种书写风格并存，语义完全等价：
--     风格 A（黑名单，显式列举）：berrybush = { ROAD, ... }      ← 绝大多数
--     风格 B（白名单求补）：toadstool_cap = OnlyAllow({ ROCKY })  ← 7 处
--     OnlyAllow(:3) 遍历 GetWorldTileMap() 取补集 ⇒ ★★ 白名单是
--     **相对于"当前已注册的全部地块"** 求的，★ 未来新增地块会自动被加入黑名单。
--     ⇒ 风格 B 对新地块是安全的，风格 A 不是。⚠ 这是个真实的维护陷阱。
--
-- ★★ 2. ★★ :150-154 的全局副作用（★ 本文件最隐蔽的一处）
--     for terrain, tiles in pairs(TERRAIN_FILTER) do
--         table.insert(tiles, WORLD_TILES.ARCHIVE)
--         table.insert(tiles, WORLD_TILES.VAULT)
--         table.insert(tiles, WORLD_TILES.VAULT_CLEAN)
--     end
--   ★ 这在 require 时**一次性执行**，给**每一条**规则追加 3 个地块。
--   · 后果①：★ 这三个地块（档案馆 / 保险库）里**任何**植物都不长。
--     ★ 这是"存档区必须是纯净空地"的实现方式——**靠数据表兜底，
--     而不是靠布置逻辑**。
--   · 后果②：★ 它 **in-place 修改** TERRAIN_FILTER 的每一个 value 表。
--     若本模块被 require 两次（不同路径），会追加两次 → 无害但冗余。
--     若有 mod 在 require 之后缓存了某条规则的引用再读，会看到被追加后的值。
--   · 后果③：★ OnlyAllow 生成的补集**不会**包含这三个（因为它们是
--     require 时才插入的，而 OnlyAllow 在 :101-145 就已经跑完）。
--     ⇒ ⚠ 疑似缺陷（极轻微）：风格 B 的 7 条规则**没有**享受
--       "档案馆/保险库禁长"的加固。因为它们已经把自己排除成"除 ROCKY 外都禁"，
--       而 ARCHIVE/VAULT 本来就在补集里 ⇒ ★ 结论：其实**恰好是安全的**，
--       但这是巧合而非设计。⚠ 记录以防将来改动打破它。
--
-- ★★ 3. ★★ 为什么这张表是"生物群系约束"的真正载体
--   ★ grep 核实：terrain.filter 的消费点只有 4 处
--     · map/forest_map.lua:25-36  pickspawnprefab（权重散布时否决）
--     · map/forest_map.lua:65-79  pickspawncountprefabforground（定数散布时否决）
--     · map/ocean_gen.lua:745    海洋散布时否决
--     · ★ components/map.lua:613-614 —— ★★★ **运行时也在用**！
--       （组件 map 用它决定已生成的实体是否合法/是否要清理）
--   ⇒ 所以这张表**跨越了生成期与运行期**，改动它的影响面
--     远大于它看起来的样子（一张 134 行的表，两个时代都在读）。
--   ★★ 而 map/storygen.lua:1038 / 1073 / 1136 / 1329 只是把
--     \`terrain_filter = self.terrain.filter\` **整个引用挂到节点 data 上**
--     ⇒ ★ 节点的 data.terrain_filter 字段在 Lua 侧**从不被读取**，
--       真正生效的是上面那 4 个直接读 terrain.filter 的点。
--       挂上去只是为了让 C++ 侧或调试器能看到。
--
-- ★ 4. ★ 兼容 shim（:164-174）—— ★ 值得学的弃用手法
--   old_rooms_mt.__index = function(table, key)
--       moderror(string.format("Accessing 'terrain.rooms' directly is being
--           deprecated, please use AddRoomPreInit(\\"%s\\") instead!", key))
--       return Rooms.GetRoomByName(key)
--   end
--   ★ 手艺：
--     ① **不报错**，仍然返回正确结果 ⇒ 老 mod 不崩；
--     ② ★ **每次访问都 moderror** ⇒ 开发者看日志能立刻定位到该改哪儿；
--     ③ 错误信息里**带上出错的 key 名** ⇒ 可直接定位。
--   ⇒ 对比 level.lua:16-22 的 assert 式硬迁移，两者可并存：
--     数据结构（字段）用 assert 硬崩，API（字段访问）用 shim 软弃用。
--     ★ 因为前者是本项目自己会改的，后者是外部 mod 在用的。
--
-- ★★ 5. ★★ 随机数：本文件**零 math.random**（★ grep 核实）
--   ★ 但它间接决定随机结果：TERRAIN_FILTER 被否决掉的 prefab
--     不会进入 pickspawnprefab 的候选池 ⇒ ★ 改这张表会**直接改变**
--     所有后续随机抽取的候选集，从而改变整张地图。
--   ⇒ 这是"纯数据文件影响随机流"的典型：★ 它是 seed 敏感表之一。
--
-- ★ 6. 交叉引用
--   ★ 权重散布的过滤 ...... map/forest_map.lua:16-52 pickspawnprefab
--   ★ 定数散布的过滤 ...... map/forest_map.lua:62-84
--                         pickspawncountprefabforground
--   ★ 海洋散布的过滤 ...... map/ocean_gen.lua:745
--   ★★ 运行时也在读 ....... components/map.lua:613-614
--   节点上挂的引用（只读不用） map/storygen.lua:1038 / 1073 / 1136 / 1329
--   Print（调试用） ......... :156-162（★ 唯一被 forest_map.lua:27/33
--                           的注释掉的 print 提到过）
--   GROUND_NAMES（Print 用）  constants.lua
--   GetWorldTileMap ........  ★ C++ 注入；★ 决定了 OnlyAllow 的补集范围
--============================================================
--
--【阅读导航】
--  §零   OnlyAllow（★ 白名单求补，依赖 C++ 的 GetWorldTileMap）(1-11)
--  §一 ★★ TERRAIN_FILTER 主表（★ 134 行，★ 黑名单语义）  (13-147)
--  §二 ★★ :150-154 全局追加（★ 档案馆/保险库禁长）       (149-154)
--  §三   Print（调试辅助）                              (156-162)
--  §四 ★ 弃用 shim old_rooms（★ 值得学的手法）           (164-174)
--
--【★★ 全文件最重要的六条】
--  1. ★★★ 语义是**黑名单**：列出的地块**不能**长。搞反会导致整张地图空掉。
--  2. ★★ 两种风格并存：显式黑名单（绝大多数）vs OnlyAllow 白名单求补（7 处）。
--     ★ 白名单对未来新增地块是安全的，黑名单不是 —— 维护陷阱。
--  3. ★★ :150-154 在 require 时给每条规则追加 ARCHIVE/VAULT/VAULT_CLEAN
--     ⇒ 存档区与保险库**任何植物都不长**。这是纯数据兜底的典范。
--  4. ★★ 这张表**跨越生成期与运行时**（components/map.lua:613 也在读），
--     改动影响面远大于 134 行的视觉体量。
--  5. ★ storygen 挂到节点上的 \`terrain_filter\` 字段在 Lua 侧从不被读，
--     ★ 真正的过滤发生在 forest_map / ocean_gen 的两个 spawn 选择器里。
--  6. ★ 弃用 shim（:164-172）：不报错 + 每次 moderror + 错误信息带 key 名
--     ⇒ 让老 mod 平滑迁移且开发者一眼定位。对比 level.lua 的 assert 硬崩，
--     两者是互补而非冲突：**字段废弃用 assert，API 废弃用 shim。**
--============================================================`;

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function build(srcFile, outFile, header, specFiles) {
  const BEFORE = {};
  const AFTER = {};
  const headerExtra = [];

  for (const sf of specFiles) {
    const specUrl = pathToFileURL(sf).href;
    const mod = await import(specUrl);
    for (const raw of [mod.HEADER_EXTRA ?? []].flat(Infinity)) {
      for (const h of String(raw).split("\n")) {
        if (h.trim() === "") continue;
        headerExtra.push(h);
        assertComment(h, `HEADER_EXTRA(${sf})`);
      }
    }
    for (const [name, target] of [
      ["BEFORE", BEFORE],
      ["AFTER", AFTER],
    ]) {
      for (const [k, v] of Object.entries(mod[name] ?? {})) {
        if (target[k] !== undefined) target[k] = [...target[k], ...v];
        else target[k] = v;
      }
    }
  }

  const raw = readFileSync(join(SRC_ROOT, srcFile), "utf8");
  const srcLines = raw.split("\n");

  const out = [header.replace(/\n$/, "")];
  for (const h of headerExtra) out.push(h);

  let injected = 0;

  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `BEFORE[${lineno}]`);
        out.push(c);
        injected++;
      }
    }

    out.push(srcLines[i]); // ← 代码行永远原样取自源文件

    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `AFTER[${lineno}]`);
        out.push(c);
        injected++;
      }
    }
  }

  const missing = [];
  for (const key of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) {
    throw new Error(`规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = out.join("\n");
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, text, "utf8");

  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  const cross = (text.match(/参见 /g) || []).length;
  const commented = new Set([
    ...Object.keys(BEFORE).map(Number),
    ...Object.keys(AFTER).map(Number),
  ]);
  let cov = 0;
  for (const k of commented) if (k >= 1 && k <= srcLines.length) cov++;

  console.log(`✔ 已生成: ${outFile}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`);
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷⚠      : ${warn}`);
  console.log(`  交叉引用参见    : ${cross}`);
  console.log(
    `  保护标记在前10行: ${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】")) ? "是" : "否"
    }`
  );
}

const S = (n) => join(__dirname, n);

async function main() {
  const which = process.argv[2] || "all";
  const R = OUT_ROOT;

  if (which === "all" || which === "storygen") {
    await build("storygen.lua", join(R, "storygen.lua"), HEADER_STORYGEN, [
      S("spec-map-storygen-p1.mjs"),
      S("spec-map-storygen-p2.mjs"),
      S("spec-map-storygen-p3.mjs"),
      S("spec-map-storygen-p4.mjs"),
    ]);
  }
  if (which === "all" || which === "forest") {
    await build("forest_map.lua", join(R, "forest_map.lua"), HEADER_FOREST, [
      S("spec-map-forest-p1.mjs"),
      S("spec-map-forest-p2.mjs"),
      S("spec-map-forest-p3.mjs"),
      S("spec-map-forest-p4.mjs"),
    ]);
  }
  if (which === "all" || which === "network") {
    await build("network.lua", join(R, "network.lua"), HEADER_NETWORK, [
      S("spec-map-network-p1.mjs"),
      S("spec-map-network-p2.mjs"),
      S("spec-map-network-p3.mjs"),
    ]);
  }
  if (which === "all" || which === "graphnode") {
    await build("graphnode.lua", join(R, "graphnode.lua"), HEADER_GRAPHNODE, [
      S("spec-map-graphnode-p1.mjs"),
      S("spec-map-graphnode-p2.mjs"),
    ]);
  }
  if (which === "all" || which === "lockandkey") {
    await build("lockandkey.lua", join(R, "lockandkey.lua"), HEADER_LOCKANDKEY, [
      S("spec-map-lockandkey-p1.mjs"),
      S("spec-map-lockandkey-p2.mjs"),
    ]);
  }
  if (which === "all" || which === "tasks") {
    await build("tasks.lua", join(R, "tasks.lua"), HEADER_TASKS, [
      S("spec-map-tasks-p1.mjs"),
    ]);
  }
  if (which === "all" || which === "task") {
    await build("task.lua", join(R, "task.lua"), HEADER_TASK, [S("spec-map-task-p1.mjs")]);
  }
  if (which === "all" || which === "level") {
    await build("level.lua", join(R, "level.lua"), HEADER_LEVEL, [
      S("spec-map-level-p1.mjs"),
      S("spec-map-level-p2.mjs"),
    ]);
  }
  if (which === "all" || which === "terrain") {
    await build("terrain.lua", join(R, "terrain.lua"), HEADER_TERRAIN, [
      S("spec-map-terrain-p1.mjs"),
    ]);
  }
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});
