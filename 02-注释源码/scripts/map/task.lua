--============================================================
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
--     一律用 `ipairs(self.tasks[...].locks)` 遍历。
--     如果 tasks/*.lua 里有人写 locks = LOCKS.NONE 而忘了归一化，
--     ipairs(数字) 会**直接崩溃**。⇒ 归一化在构造期把两种写法都变成表，
--     换来「写数据的人不必关心 arity」的自由。
--   ★ 但归一化只处理"标量→表"，**不处理 nil**：
--     ⚠ 若某个 task 完全不写 locks，第 7 行 self.locks = nil，
--       第 8 行 type(nil) ~= "table" ⇒ self.locks = { nil }
--       ⇒ ★★ **一个只含 nil 的表**。ipairs 遍历它立刻结束（看起来正常），
--         但 :319 的 `LOCKS_KEYS[v]` 中 v 为 nil 时
--         ★ `LOCKS_KEYS[nil]` 在 Lua 中是**读取** nil 键（合法，返回 nil），
--           而 :333 `ipairs(lockData.keys)` 中 keys 为 nil ⇒ ★★ **崩溃**。
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
--       ★ 而 storygen.lua:1216 `for k,v in pairs(task.substitutes)` 与
--         :1285 `task_node.substitutes = task.substitutes` 都在读它。
--         ⇒ 解释：substitutes 是由 map/level.lua:69-73 **运行时挂到
--         tasklist 里的 deepcopy 上的**（GetOverridesForTasks），
--         不走 Task 构造函数。★ 正确但极易误读。
--     · set_pieces / random_set_pieces —— 同样由 level.lua:180-210
--       在 ChooseSetPieces 阶段挂载，不走构造函数。★ 一致的设计。
--     · background_room ★ 有搬运（:23），但 graphnode 的 backgroundRoom
--       实际来自 task_node.data.background（network.lua:738）
--       ⇒ ★ 那条链是 storygen.lua:1284 的 Graph 构造参数
--         `background=task.background_room`。
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
--============================================================
-- ★★★ 本文件是 map/ 目录最短的类（36 行有效代码），职责单一：
--   把 map/tasks/*.lua 里的**纯字面量表**搬成「带类型的对象」。
--   ★ 它**没有任何生成逻辑**——「这个任务要生成哪些房间」由
--   storygen.lua:1232 GenerateNodesFromTask 解释执行。
-- ★ 关键陷阱：本文件 **不 require("map/lockandkey")**。
--   ⇒ LOCKS / KEYS 常量必须由**调用方**先加载。
--   参见 map/tasks.lua:2（那边 require 了 lockandkey）。
Task = Class(function(self, id, data)
-- -- print("Task ",id)
-- -- dumptable(data,1)
-- ★ 原作者调试这两行留下的痕迹。dumptable 是 Klei 的调试工具。
	-- print("Task ",id)
	-- dumptable(data,1)
-- ★ 任务 ID 是全局唯一键，后续被 storygen 用作 dict 键：
--   storygen.lua:58  self.tasks[task.id] = task
--   ⇒ 重复 ID 会静默覆盖。这里不 assert，因为注册期已由
--   map/tasks.lua:58 `assert(GetTaskByName(name) == nil)` 拦过一道。
	self.id = id

-- ══════════════ 【锁钥匙组】——★ 全库锁算法的数据源头 ══════════════
-- 下面 6 行是本文件存在的**首要理由**。
	-- what locks this task
-- ★ locks：这个任务**要求玩家先打开哪些锁**才能进入。
--   ★ 取值来自 LOCKS（map/lockandkey.lua:77），是一个整数。
--   ⚠ 注意语义：它是「AND」——所有列出的锁都必须解开（lockandkey.lua:172）。
--   参见 storygen.lua:341-347 的 unlocked 判定循环。
	self.locks = data.locks
-- ★★ 归一化①：如果声明时写的是单个锁（如 locks=LOCKS.NONE），
--   这里把它包成单元素表 { LOCKS.NONE }。
--   ★ 为什么必须这样：storygen.lua 四处都用 ipairs 遍历 locks
--   （:319 / :324 / :524 / :617），ipairs(数字) 在 Lua 里**直接崩溃**。
--   ⇒ 这一行是全库锁算法的**隐式契约**，不能删。
--   ⚠ 但它只处理「标量→表」，**不处理 nil**：
--     若某个 task 完全不写 locks，则 self.locks = { nil }（含 nil 的表），
--     ipairs 遍历它会**立刻结束**（看起来正常），
--     但 storygen.lua:320 `local lock = {keys=LOCKS_KEYS[v], ...}` 中
--     v 为 nil ⇒ LOCKS_KEYS[nil] 读取合法返回 nil，
--     ★★ 于是 storygen.lua:333 `for reqKeyIdx, reqKey in ipairs(lockData.keys)`
--     遍历 nil ⇒ **崩溃**（attempt to iterate a nil value）。
--     ⇒ 这就是「漏写字段 ⇒ 后期神秘崩溃」的典型陷阱。
--     （推理依据：Lua 中 t[nil] 读取合法返回 nil，t[nil] = v 赋值才报错。）
	if type(self.locks) ~= "table" then
		self.locks = { self.locks }
	end
	-- the key that this task provides
-- ★ keys_given：这个任务**通关后交给玩家**的钥匙。
--   ★ 它是锁算法的「产出端」：storygen.lua:617-623 把它塞进 availableKeys，
--   后续任务就能用它开锁。
--   ⚠ 与 locks 不同，keys_given **没有 AND/OR 语义**——全都给。
--   ★ 这构成了整个世界生成的「探索链」：
--     任务A 给 PICKAXE ⇒ 任务B 的 ROCKS 锁可开 ⇒ 任务B 给 WOOD ⇒ …
	self.keys_given = data.keys_given
-- ★★ 归一化②：同 8-10 行，keys_given 也允许写单个。
--   storygen.lua:617 `for i,v in ipairs(self.tasks[...].keys_given)` 依赖它。
	if type(self.keys_given) ~= "table" then
		self.keys_given = { self.keys_given }
	end
-- ★ region_id：这个任务属于哪个「区域」（mainland / ruins_island / …）。
--   ★ 决定它进哪个 region_tasksets（storygen.lua:63-69），
--   缺省 "mainland" ⇒ 大陆。
--   ★ 消费者 storygen.lua:801：非大陆/非 ruins_island/非 vault_island 的区域
--   会被 AddRegionsToMainland 单独生成并用 LinkRegions 连两条路。
	self.region_id = data.region_id

-- ══════════════ 【房间组成组】══════════════
-- ★ entrance_room：这个 task 强制带的「入口房」。
--   storygen.lua:1237-1259：按 entrance_room_chance 概率决定是否真的加。
	self.entrance_room = data.entrance_room
-- ★ entrance_room_chance：加不加入口房的概率（缺省 = 必加）。
--   storygen.lua:1239：`if task.entrance_room_chance == nil or task.entrance_room_chance > r`
--   ★ nil 时无条件加；给了值就是一次 math.random() 判定。
--   ⇒ 同样是**随机消耗点**，改这个值会改变整条随机流。
	self.entrance_room_chance = data.entrance_room_chance
-- ★★ room_choices：★ 本文件最核心的业务字段。
--   形如 { ["Forest"] = 3, ["Marsh"] = 1 } —— 房间名 → 要几间。
--   ★ 值可以是**函数**（storygen.lua:1264-1266 会现场调用 count()），
--   ★★ 于是「房间数量」本身可以是随机的 ——
--   这就是 tasks/*.lua 里 `function() return 1+math.random(3) end` 的机制，
--   依赖 map/tasks.lua:5 的全局 SIZE_VARIATION = 3。
--   ★ 消费：storygen.lua:1261-1282，逐个 GetRoom + 压进 Stack。
	self.room_choices = data.room_choices
-- ★ room_choices_special：★ 本文件搬运了它，但 storygen.lua 里
--   ★ grep 核实：GenerateNodesFromTask **从不读取** room_choices_special。
--   ⇒ 死字段（或由别处的 DLC 支持代码消费，★ 本 map/ 目录内零消费点）。
	self.room_choices_special = data.room_choices_special
-- ★★ room_bg 与 background_room 是**两件完全不同的事**，极易混淆：
--   · room_bg          → Voronoi 胞元**内部**压什么地面地块。
--     链：storygen.lua:1284 Graph(default_bg=task.room_bg)
--          → :1288 WorldSim:AddChild(..., task.room_bg, ...)
--     ★ 它是 C++ 烘焙时的底色。
--   · background_room → 胞元**外圈**（残留空地）用哪个房间模板。
--     链：storygen.lua:1284 Graph(background=task.background_room)
--          → network.lua:738 GetBackgroundRoom → graphnode.lua:498 PopulateChildren
--   ⚠ 混用的后果：草地胞元外面长出洞穴背景内容。
	self.room_bg = data.room_bg
	self.background_room = data.background_room
-- ★★ cove_room_name：穴居小房间的模板名（storygen.lua:1090 AddCoveNodes）。
--   ★ 它的作用是**打散正则感**——地图不会一格一格均匀排列。
--   ★ 缺省 "Blank"（storygen.lua:1098）。
	self.cove_room_name = data.cove_room_name
-- ★ cove_room_chance：加穴居房的概率，缺省 0.35（storygen.lua:1106）。
--   ⚠ 若为 0 ⇒ storygen.lua:1108 的 `return` 会**终止整个 AddCoveNodes**。
	self.cove_room_chance = data.cove_room_chance
-- ★ cove_room_max_edges：只有边数 ≤ 此值的节点才加穴居房。
--   缺省 1（storygen.lua:1107）⇒ 「只在链的末端/孤立点上开口」。
--   ★ 同 :1108 的 ⚠ 陷阱：为 0 时整个 AddCoveNodes 提前 return。
	self.cove_room_max_edges = data.cove_room_max_edges
-- ★ colour：调试可视化用的 RGBA（storygen.lua:1284 → network.lua:43）。
--   ★ 它会被 SaveEncode 写进 topology 并在小地图/调试视图里显示。
--   ★ 对玩法**零影响**——纯调试信息，但泄露了拓扑，是重要的调试通道。
	self.colour = data.colour
-- ══════════════ 【拓扑形状组】══════════════
-- ★ maze_tiles：竞技场迷宫的房间内容表（按迷宫格类型索引）。
--   消费：forest_map.lua:703 `local choices = ...maze_tiles`
--     → :713/:740/:795/:809 obj_layout.Place(..., choices.rooms/bosses/...)
--   ★ 链：task.maze_tiles → storygen.lua:1284 Graph(maze_tiles=)
--     → network.lua:48 → :738 附近可读
	self.maze_tiles = data.maze_tiles
-- ★ maze_tile_size：迷宫格子边长，缺省 8（forest_map.lua:699）。
	self.maze_tile_size = data.maze_tile_size
-- ★★ crosslink_factor：★ 「交叉连线强度」——给线性房间链额外加几条随机捷径。
--   缺省 1（storygen.lua:874 `task.crosslink_factor or 1`）。
--   ★ 消费：network.lua:592 CrosslinkRandom。
--   ★ 那里的语义：factor=1 加 1 条，factor=0.5 因是浮点会**加 0 条**，
--     ★★ 也就是说「三角形 = 1、直线 = 0、树 = 0、正方形 = 1」（原注释 :591）。
--   ★★ 而 network.lua:598 的 while 有 20 次上限 ⇒ 尽力而为，不保证达标。
	self.crosslink_factor = data.crosslink_factor
-- ★ make_loop：把本 task 的房间链首尾相连成**环**。
--   消费：storygen.lua:1374-1376 → network.lua:611 MakeLoop。
--   ★★ 注意与 hub_room 的互斥（storygen.lua:1357-1358 的注释）：
--   「有 hub_room 时不自动连边，交给 MakeHub；要成环就别把 hub 连进去」
	self.make_loop = data.make_loop
-- ══════════════ 【环境约束组】══════════════
-- ★ room_tags：★ 附加到本 task **所有房间节点**上的标签。
--   消费：storygen.lua:1035 / 1070 / 1133 / 1324 的
--     `tags = ArrayUnion(extra_tags, task.room_tags)`
--   ★ 标签的运行时语义：network.lua:1030 ForceDisconnected（断链）、
--     :1037 ForceConnected、:1040 RoadPoison（禁路）。
--   ★★ 这些标签是「锁」在像素层面的物理实现（见 HEADER 第 3 条）。
    self.room_tags = data.room_tags
-- ★ required_prefabs：本 task 必须出现的 prefab 清单（可带数量）。
--   ★★★ 三重来源求和校验的一员（forest_map.lua:936-944）。
--   ★ 链路：本字段 → Graph(required_prefabs=)（storygen.lua:1284）
--     → network.lua:55-60 递归累加
--     → network.lua:452-456 节点级再累加
--     → network.lua:786 GetRequiredPrefabs 汇总
--     → forest_map.lua:961-974 与实际数量比对，不足则 return nil 重试。
    self.required_prefabs = data.required_prefabs
-- ★ hub_room：★ 本 task 的**枢纽房名**。给了它，链式连线会跳过它，
--   最后 MakeHub 把其余所有房间都连到它（storygen.lua:1378-1380）。
--   ★★ 于是「枢纽房」= 多条支路的汇合点，保证从入口能走到任一支路。
--   ★★ 这本身就是一种连通性保证（不依赖锁钥匙）。
    self.hub_room = data.hub_room
-- ★ level_set_piece_blocker：置 true 后本 task **拿不到任何**关卡级场景件。
--   消费：level.lua:152-160 GetTasksForLevelSetPieces 把它筛掉。
--   ★ 用途：让某些「程序化拼接房」不被随机塞入静态布局破坏形状。
	self.level_set_piece_blocker = data.level_set_piece_blocker -- prevents the task from getting any of the random_set_pieces and required_setpieces defined in the level
end)
-- ★★★ 收尾自检：本类的全部 25 个字段搬运完毕。
-- ★★ 但有 3 个**被 tasks/*.lua 大量使用、却没有在这里搬运**的字段：
--   · substitutes        → ★★ map/level.lua:69-73 在运行时挂到 deepcopy 上
--     （见 map/resource_substitution.lua）。不是 bug，是设计。
--   · set_pieces         → level.lua:206-210 在 ChooseSetPieces 阶段挂载。
--   · random_set_pieces  → level.lua:180-184 同上。
-- ⇒ ★★ 读代码时若在 Task 对象上找不到这三个字段，不是 bug，是挂载时机不同。

-- ★ __tostring：唯一的「行为」，纯粹为了让日志/报错可读。
--   ★ 在 storygen.lua 的各种 print(..task.id..) 里其实没被用到，
--   ★ 但 print(task) 自动调用它（Lua 的 tostring 协议）。
function Task:__tostring()
    return "Task: "..self.id
end


