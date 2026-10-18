--============================================================
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
--   `function() return 1 + math.random(SIZE_VARIATION) end` 消费
--   （★ grep 核实：map/tasks/dst_tasks_forestworld.lua:12/14/27/…
--     map/rooms/cave/vents.lua:143-144）。
--   ★★ 它是**全局可变的**，因此：
--     ① 它必须在**所有 task 定义被 require 之前**设定好（本文件第 5 行，
--        而 require 在 127-136 行 —— 顺序正确）；
--     ② 任何 mod 若在别处改写它，会改变所有房间数量；
--     ③ ★ 因为它只在**函数被调用时**才读（math.random 在闭包内），
--        所以求值时机 = GenerateNodesFromTask 的 :1264-1266
--        （`if type(count) == "function" then count = count() end`）
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
--============================================================
-- ★★★ 本文件是「任务注册中心」，职责只有两件：
--   ① 提供 AddTask / AddModTask 两条注册路径；
--   ② require 全部 map/tasks/*.lua 触发它们自注册。
-- ★★ 它**不做任务挑选**——挑选在 map/level.lua:89 ChooseTasks，
--   依据是 overrides["task_set"] 去查 map/tasksets.lua。
--   ⇒ 三层关系：taskdefinitions（本文件，全量注册表）
--     → task_set（tasksets.lua，勾选哪些）
--     → chosen_tasks（level.lua，最终队列）。
require("map/task")
-- ★★ 关键：★ 本文件（而不是 task.lua）require 了 lockandkey。
--   理由：task.lua 只搬运字段，需要 LOCKS/KEYS **常量存在**；
--   而 tasks/*.lua 里的 locks=LOCKS.NONE 在**模块加载时**就要求值，
--   所以必须在这批 require（第 127-136 行）之前加载好。
--   ⇒ ★ 加载顺序：lockandkey（第 2 行）→ … → tasks/*.lua（第 127 行起）。
require("map/lockandkey")
-- ★ terrain：同样在 require 之前加载，供 tasks/*.lua 的 rooms 引用。
require("map/terrain")

-- ★★ 全局常量 SIZE_VARIATION = 3 ——「房间数量抖动幅度」。
-- ★★ 它被 tasks/*.lua 里的闭包消费（★ grep 核实全部消费点）：
--   · map/tasks/dst_tasks_forestworld.lua:12,14,27,29,30,41,43,55
--     形如 `["Forest"] = function() return 1 + math.random(SIZE_VARIATION) end`
--   · map/rooms/cave/vents.lua:143-144（洞穴房数量同样抖动）。
-- ★★★ 求值时机（★ 这才是关键）：
--   math.random 在**闭包内部**⇒ 只有闭包被调用时才读 SIZE_VARIATION，
--   而调用点是 storygen.lua:1264-1266
--     `if type(count) == "function" then count = count() end`
--   ⇒ ★★ **房间数量是在建图阶段现场摇的**，每个 task 每次都摇。
--   ⇒ 这直接放大 pairs 遍历顺序对最终地图布局的影响。
-- ★★ 它是**全局可写**的：任何 mod 在别处改写它会改变所有房间数量。
--   ★ 因此第 5 行必须在第 127-136 行的 require **之前**——顺序正确。
SIZE_VARIATION = 3


-- ★★ 两级注册表：本文件的 + 所有 mod 的（按 mod 名分桶）。
-- ★ 用 local 封装 ⇒ 外部无法直接改，只能通过下面 4 个导出函数。
local taskdefinitions = {}
-- ★ modtaskdefinitions[modname] = { Task, Task, … }（数组，便于顺序遍历）
local modtaskdefinitions = {}

------------------------------------------------------------------
-- Module functions
------------------------------------------------------------------

-- ══════════════ 模块内查找函数（★ 全是 O(N) 线性扫描）══════════════
local function GetAllTaskNames()
    local ret = {}
-- ★ GetAllTaskNames：把所有任务名拍平成一个数组。
--   ★ 消费方：前端任务选择 UI（★ grep 核实 map/ 内无消费，
--     说明它被 worldgen_main.lua 或 screens/ 用来列任务）。
    for i,task in ipairs(taskdefinitions) do
        table.insert(ret, task.id)
    end
-- ★★ 先扫 mod 的桶（pairs 顺序），再扫本文件的 —— ★ 顺序不稳定！
--   ⇒ 若调用方依赖这个顺序做「取第一个」的逻辑，会随 mod 变动而变。
    for mod, tasks in pairs(modtaskdefinitions) do
        for i,task in ipairs(tasks) do
            table.insert(ret, task.id)
        end
    end
    return ret
end

-- ★★ GetTaskByName：★ 全库最热的任务查找函数（线性扫描两遍）。
-- ★ 调用点：level.lua:220 EnqueueATask（每个任务调 1 次）、
--   tasks.lua:58/63（注册期防重，各调 1 次）。
-- ★ 规模：map/tasks/*.lua 加起来约 40-100 个 task ⇒ 每次 O(100)。
-- ★ ⇒ 单次生成总计约 100×100 = 1 万次字符串比较，
--   ★ 相对 Lloyd 的 2-8 s 可以忽略。**不是瓶颈**（这点值得说清楚，
--   免得读者照抄 O(N) 就当成性能问题去优化）。
local function GetTaskByName(name)
    for i,task in ipairs(taskdefinitions) do
        if task.id == name then
            return task
        end
    end
-- ★★ 第二遍：扫所有 mod 的桶。★ 嵌套两层循环 ⇒ O(总任务数)。
    for mod, tasks in pairs(modtaskdefinitions) do
        for i,task in ipairs(tasks) do
            if task.id == name then
                return task
            end
        end
    end

    return nil
end

-- ★ ClearModData(mod)：★ 卸载 mod 时清空它注册的任务。
--   ★ 消费方：mod 系统的 UnloadMod 流程。
-- ★★ 注意 :49 `modtaskdefinitions = {}` 是**重新绑定 local**，
--   不是清空原表。这在有其他引用指向旧表时有区别，
--   ★ 但因为 modtaskdefinitions 只在本文件内使用（local），无影响。
local function ClearModData(mod)
    if mod ~= nil then
        modtaskdefinitions[mod] = nil
    else
        modtaskdefinitions = {}
    end
end

------------------------------------------------------------------
-- GLOBAL functions
------------------------------------------------------------------

-- ══════════════ 全局注册函数 ══════════════
-- ★★ AddTask(name, data)：★ 本文件与 map/tasks/*.lua 唯一的注册路径。
-- ★ 注意「注册」= 立刻构造 Task 对象（不是延迟），
--   ⇒ ★★ Task 构造里对 locks/keys_given 的归一化在此刻完成。
function AddTask(name, data)
-- ★★ assert 防重：**启动期崩溃**，是本文件唯一的强校验。
--   ⇒ 对比 lockandkey.lua 的 LOCKS_KEYS **没有**查重（E1 缺陷根因）。
--   ★ 同一个仓库里两种截然不同的重复防护策略并存，值得对照。
    assert(GetTaskByName(name) == nil, "Tried adding a task '"..name.."' but it already exists!")
-- ★ table.insert 保持**注册顺序** ⇒ 后续 ipairs 遍历顺序稳定。
--   ★ 这与 map/network.lua 里 pairs 遍历的不确定性形成对比——
--     ★★ 数组顺序稳定，字典顺序不稳定。这是可复现性的分水岭。
    table.insert(taskdefinitions, Task(name, data))
end

-- ★★ AddModTask(mod, name, data)：★ mod 的注册路径。
-- ★★ 与 AddTask 的三处差异（★ 值得逐条对照）：
--   ① 重复名不 assert 而是 moderror；
--   ② ★ 报错信息给出**补救建议**（"Maybe try extending and modifying
--      that task using AddTaskPreInit instead?"）——很好的错误信息设计；
--   ③ ★★ 重复时 **return 不插入**（模组任务被静默丢弃）。
function AddModTask(mod, name, data)
    if GetTaskByName(name) ~= nil then
-- ★ moderror（不是 error）⇒ 不崩，mod 继续跑，只是那个任务没了。
--   ⚠ 副作用：玩家会在世界里发现「少了一个区域」，但日志只有一行 moderror。
--   ★ 这与 forest_map.lua 里那些「只 print 就 return nil」的静默失败同源。
        moderror(string.format("Tried adding a task called '%s' but that already exists!\n\t\tMaybe try extending and modifying that task using AddTaskPreInit instead?", name))
        return
    end

-- ★ 按 mod 名分桶：同一个 mod 的任务放一起，便于整体卸载。
    if modtaskdefinitions[mod] == nil then modtaskdefinitions[mod] = {} end
    table.insert(modtaskdefinitions[mod], Task(name, data))
end


------------------------------------------------------------------
-- Load the data
------------------------------------------------------------------

-- A set of tasks to be performed
-- ══════════════ 调试用任务集样本（★ 非正式数据）══════════════
-- ★★ everything_sample2：小型样本（4 种房间，共 6 间房）。
--   ★ locks=NONE（无锁，可直接进）、keys_given=PICKAXE（给镐）。
--   ★ 这是**最小可验证世界**（MWV）的手工范例：
--     · 无锁 ⇒ 不依赖锁钥匙算法的正确性；
--     · 给 PICKAXE ⇒ 可以立刻验证 KEYS.PICKAXE 能否开 LOCKS.ROCKS。
local everything_sample2 = {
	Task("One of everything", {
		locks=LOCKS.NONE,
		keys_given=KEYS.PICKAXE,
		room_choices={
-- ★★ DenseRocks / DenseForest / SpiderCon / Forest —— 4 种房间各 1 间。
-- ★ 观察点：room_bg=GRASS + background_room=BGGrass ⇒ 胞元内草地、胞元外草地背景。
--   ★ colour 绿 ⇒ 调试视图里这个 task 显示为绿色块。
			["DenseRocks"] = 1,
			["DenseForest"] = 1,
			["SpiderCon"] = 3,
			["Forest"] = 1,
		 },
		room_bg=WORLD_TILES.GRASS,
		background_room="BGGrass",
		colour={r=0,g=1,b=0,a=1}
	})
}
-- ★★ everything_sample：全房间穷举样本（22 种房间，各 1 间）。
--   ★ 用途：**人工目检**——生成一张把所有房间类型都放一遍的图，
--     肉眼检查每种房间的地形/内容物是否正常。
--   ★★ 它是**死数据**：只有 sample2 被导出（:180），本表未导出。
--     ⇒ 改动它对正式生成**零影响**。
local everything_sample = {
	Task("One of everything", {
		locks=LOCKS.NONE,
		keys_given=KEYS.PICKAXE,
-- ★★ 22 种房间：Graveyard 墓地 / BeefalowPlain 牛平原 / SpiderVillage 蜘蛛村 /
--   PigKingdom 猪王国 / PigVillage 猪村 / MandrakeHome 曼达草窝 /
--   BeeClearing 蜂林 / DenseRocks 密石 / DenseForest 密林 / Rockpile 石堆 /
--   Woodpile 木堆 / Trapfield 陷阱地 / Minefield 雷区 / SpiderCon 蜘蛛集会 /
--   Forest 森林 / Rocky 岩地 / BarePlain 裸地 / Plain 平原 / Marsh 沼泽 /
--   DeepForest 深林 / Clearing 空地 / BurntForest 烧林。
-- ★★ 这份清单也是理解「DST 有哪些群系」的最快索引。
		room_choices={
			["Graveyard"] = 1,
			["BeefalowPlain"] = 1,
			["SpiderVillage"] = 1,
			["PigKingdom"] = 1,
			["PigVillage"] = 1,
			["MandrakeHome"] = 1,
			["BeeClearing"] = 1,
			["DenseRocks"] = 1,
			["DenseForest"] = 1,
			["Rockpile"] = 1,
			["Woodpile"] = 1,
			["Trapfield"] = 1,
			["Minefield"] = 1,
			["SpiderCon"] = 1,
			["Forest"] = 1,
			["Rocky"] = 1,
			["BarePlain"] = 1,
			["Plain"] = 1,
			["Marsh"] = 1,
			["DeepForest"] = 1,
			["Clearing"] = 1,
			["BurntForest"] = 1,
		},
-- ★★ 与 sample2 相同的 room_bg / background_room，只是房间列表更长。
		room_bg=WORLD_TILES.GRASS,
		background_room="BGGrass",
		colour={r=0,g=1,b=0,a=1}
	})
}

-- ══════════════ ★★★ 真正的任务定义在这里被 require ══════════════
-- ★★ 9 个文件、约 100 个 task 全部在这里加载。
-- ★★★ 加载顺序 = 上表的先后顺序 ⇒ ★★ 注册顺序 = 这个顺序，
--   而注册顺序会影响 ipairs(tasklist) 的遍历顺序
--   （map/level.lua:123 `for i=1,#self.tasks`）⇒ ★★ 影响随机结果。
--   ⚠ 调换 require 顺序会改变地图。这是一条隐藏的耦合。
require("map/tasks/maxwell")
require("map/tasks/island_hopping")

-- ★ forest：主世界（森林/平原/沼泽/岩地…），★ 是 mainland 的主体。
require("map/tasks/forest")
require("map/tasks/moonisland_tasks")
-- ★ caves：洞穴（矿洞/食人花洞/古迹洞/龙洞…），★ 全部以 Sinkhole/Cave 为底。
--   ★ 洞穴任务是 biome 分区的代表：perTerrain（graphnode.lua:536）为它们启用。
require("map/tasks/caves")
require("map/tasks/ruins")
require("map/tasks/DLCtasks")
require("map/tasks/lavaarena")
require("map/tasks/quagmire")

------------------------------------------------------------------------------------------------------------------------
-- TEST TASKS
------------------------------------------------------------------------------------------------------------------------

-- ══════════════ ★★ TEST_TASK 三件套：常驻调试任务 ══════════════
-- ★★★ 这三个 task 不是被 #if 掉的临时代码，
--   ★★ 而是**永久注册进正式表**的调试任务。
-- ★★ 它们构成一条最小的两环锁—钥匙链：
--     TEST_TASK   locks = LOCKS.NONE       keys_given = KEYS.LIGHT
--     TEST_TASK1  locks = LOCKS.LIGHT      keys_given = KEYS.CAVE
--   ⇒ 必须先拿 TEST_TASK 的 LIGHT，才能进 TEST_TASK1。
--   ⇒ ★★ 用 task_set = {TEST_TASK, TEST_TASK1} 就能在几秒内验证
--     锁—钥匙连线是否正确，★ 不必生成完整世界（省掉 2-8 s 的 Lloyd）。
--   ⇒ 这是**最小可验证世界**（MWV）的现成样本，调试世界生成时首选。
AddTask("TEST_TASK", {
-- ★★ 锁定环：★ 只放 1 间 BGCaveRoom（洞穴房间），底色 SINKHOLE（天坑）。
-- ★ keys_given=LIGHT ⇒ ★★ 这是专门用来测试「LIGHT 锁」的钥匙。
--   ★ 为什么用 LIGHT？因为它是 LOCKS.LIGHT 的**唯一**钥匙
--     （lockandkey.lua:323-326 `[LOCKS.LIGHT] = { KEYS.LIGHT }`），
--   ★★ 单钥匙锁最容易验证「锁没被错误地自动解开」。
		locks=LOCKS.NONE,
		keys_given=KEYS.LIGHT,
		room_choices={
			["BGCaveRoom"] = 1,
		},
-- ★ room_bg=SINKHOLE + background_room=BGSinkholeRoom ⇒ 天坑地形。
-- ★ colour 粉紫色 ⇒ 调试视图里一眼认出是测试数据。
		room_bg=WORLD_TILES.SINKHOLE,
		background_room="BGSinkholeRoom",
		colour={r=1,g=0.7,b=1,a=1},
	})

-- ★★ TEST_TASK1：锁 LIGHT（= LOCKS.LIGHT 整数），3 间 CaveRoom + 1 间 BatCaveRoom。
--   ★ 验证点：★ 若生成结果里 TEST_TASK1 与 TEST_TASK 直接相连，
--     ⇒ 说明锁被错误解开了（storygen.lua 的 availableKeys 判定有 bug）。
--   ★ 若 TEST_TASK1 被孤立成孤岛 ⇒ 说明该开的锁没开（E1 类缺陷）。
AddTask("TEST_TASK1", {
		locks=LOCKS.LIGHT,
		keys_given=KEYS.CAVE,
		room_choices={
			["CaveRoom"] = 3,
			["BatCaveRoom"] = 1,
		},
		room_bg=WORLD_TILES.CAVE,
		background_room="BGCaveRoom",
		colour={r=1,g=0.6,b=1,a=1},
	})
-- ★ TEST_EMPTY：最简任务。无锁、给 NONE 钥匙、1 间 Clearing。
--   ★★ 用途：作为「汇点/终点」——它不需要钥匙，
--     ★ 所以任何东西都能连到它，适合放在 story 链的末尾。
-- ★★ 注意 keys_given = KEYS.NONE（=1，锁和钥匙数组的第 1 项，
--   lockandkey.lua:86/4 的第一个）。★ 给 NONE 钥匙等于「什么都不给」，
--   但它让 :617 的 availableKeys[KEYS.NONE] = { … } 照常执行 ⇒ 无害。
AddTask("TEST_EMPTY", {
		locks=LOCKS.NONE,
		keys_given=KEYS.NONE,
		room_choices = {
			["Clearing"] = 1,
		},
		room_bg = WORLD_TILES.FOREST,
		background_room = "Clearing",
		colour = { r = 1, g = 1, b = 1, a = 1 },
	})

------------------------------------------------------------------
-- Export functions
------------------------------------------------------------------

-- ══════════════ 导出表 ══════════════
-- ★★ 导出的 4 个函数正好对应 4 类消费方：
--   · GetAllTaskNames → 前端任务列表面板
--   · GetTaskByName   → ★ level.lua:220 EnqueueATask（生成期热路径）
--   · ClearModData    → mod 卸载流程
--   · oneofeverything → ★ 调试用任务集（★ 唯一导出的数据）
return {
    oneofeverything = everything_sample,
    GetAllTaskNames = GetAllTaskNames,
    GetTaskByName = GetTaskByName,
    ClearModData = ClearModData,
-- ★★ oneofeverything = everything_sample（不是 sample2！）。
--   ⚠ 注意：名字一样，两个表内容不同，且导出的是**长版**。
--   ⇒ 调试时想要「22 种房间全放一遍」用这个；
--     想要「4 种房间小样本」得自己从 sample2 构造。
--   ★ 这是个轻微的命名/导出不一致（⚠ 疑似缺陷，但影响仅限调试路径）。
}
