--============================================================
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
--   :108-110 ★★ `for k,v in pairs(task_set_data) do self[k] = v end`
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
--   ⚠ :178 的 `local idx = math.random(#tasks)` 取到的是 tasks 数组的
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
--  2. ★★ ChooseTasks 的 :108-110 `self[k] = v` 让 task_set 表拥有
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
--============================================================
-- ★★★ 本类 = 一份「世界预设」（Level）的内存表示。
--   数据源是 map/levels/*.lua 里的字面量表（玩家在前端选的那个预设）。
-- ★★ 它做三件事：
--   ① 构造期**强制迁移**（4 个 assert 把废弃字段变成硬错误）；
--   ② ChooseTasks(:89) 从 task_set 挑任务队列；
--   ③ ChooseSetPieces(:162) 把关卡级场景件分配到各任务上。
-- ★★ 本文件**不生成任何地图**，只产出「配置」。
local tasks = require("map/tasks")
-- ★★ tasksets.GetGenTasks 是本文件的核心依赖 —— ★ 它内部会 deepcopy，
--   ⇒ 每次 ChooseTasks 都拿到一份独立副本，mod 钩子改它不会污染全局。
--   参见 map/tasksets.lua:6-13。
local tasksets = require("map/tasksets")

-- ══════════════ ★★ Level 构造：★ 强制迁移契约 ══════════════
Level = Class( function(self, data)
-- ★ assert：level 必须有 id。★ 崩溃点在构造期而不是生成期。
	assert( data.id ~= nil, "level must specify an id." )
-- ★ SetID 同时写 id 与 worldgen_id（★ 见 :229-233 的镜像字段说明）。
	self:SetID(data.id)
	self:SetBaseID(data.baseid)
	self:SetNameAndDesc(data.name, data.desc)
-- ★ override_level_string：控制前端如何显示「已覆盖默认值」的提示。
	self.override_level_string = data.override_level_string or false
-- ★★ assert(location ~= nil, "Levels must specify a location, no more default.")
--   ★★ 这条把「不写 location 就用默认森林」的旧行为**彻底废除**。
--   ★★ 与 :16/:18/:20/:22 一起构成本文件的「迁移契约」四件套。
    assert(data.location ~= nil, "Levels must specify a location, no more default.")
    self.location = data.location
    self.hideinfrontend = data.hideinfrontend
-- ★★ overrides：★ 本文件最重要的字段 —— 玩家的所有世界生成设置都在这。
--   消费者：forest_map.lua:393 `local current_gen_params = deepcopy(level.overrides)`
--   ★★ 它涵盖：world_size / branching / loop / islands / roads /
--     has_ocean / season_start / start_location / task_set /
--     以及几十个 prefab 密度项（berrybush = "often" 之类）。
--   ★★ key 的全集见 map/forest_map.lua:168-256 的 TRANSLATE_TO_PREFABS。
	self.overrides = data.overrides or {}
-- ★★ substitutes：资源替换配置 { 原资源名 = {perstory=…, pertask=…} }。
--   消费：本文件 :55 GetOverridesForTasks → map/resource_substitution.lua。
--   ★★ 注意它是**关卡级**配置，但实际挂载在**任务级**（:73）。
	self.substitutes = data.substitutes or {}
-- ★ override_triggers：★ 标了 --UNUSED 但**仍然被搬运**。
--   ⚠ 疑似缺陷（极轻微）：一个明确标注「未使用」的字段被保留在数据流里，
--     ★★ mod 作者可能误以为它有效。★ 迁移不彻底的第一处。
	self.override_triggers = data.override_triggers --UNUSED
-- ★★★★★★ 迁移契约 ①（set_pieces）：
--   assert(data.set_pieces == nil, "level 'set_pieces' should be specified
--   as an override via 'task_set' now.")
-- ★★ 手法：把「曾经支持、现已废弃」的写法变成**启动期崩溃**。
--   ★★ 设计价值（★ 全 map/ 最值得学的一处）：
--     宁可让老 mod 立刻崩，也不要让它「看起来在工作但效果不对」。
--   ⇒ ★ 因为静默忽略会浪费 mod 作者几小时去查「为什么我的场景件没出现」。
-- ★★ 替代路径：改用 overrides["task_set"] 指向一个 taskset，
--   而 taskset 里可以带 set_pieces（见 map/tasksets/*.lua）。
    assert(data.set_pieces == nil, "level 'set_pieces' should be specified as an override via 'task_set' now.")
-- ★ self.set_pieces = nil：★ 防御性冗余（assert 已保证输入为 nil）。
--   ★★ 但它明确告诉 reader「这个字段现在恒为 nil」，
--     ★★ 避免后人再去 data 里找 ⇒ **有价值的冗余**。
--   ★★★ 而正因这一行恒为 nil，
--     ★★★ ChooseSetPieces 的 :187-216 分支是**完全死代码**（见该段注释）。
	self.set_pieces = nil
-- ★★★★★★ 迁移契约 ②（numoptionaltasks）：同类，措辞一致。
--   ⇒ ★ 四条 assert 的措辞高度统一，说明是**一次性批量迁移**而非逐次演进。
    assert(data.numoptionaltasks == nil, "level 'numoptionaltasks' should be specified as an override via 'task_set' now.")
-- ★ 同上：self.numoptionaltasks = nil（防御性冗余）。
	self.numoptionaltasks = nil
-- ★★★★★★ 迁移契约 ③（optionaltasks）：可选任务列表，
--   ★ 现改由 task_set 里的 numoptionaltasks/optionaltasks 提供。
--   ★★ 注意 :129-145 仍在消费 self.numoptionaltasks / self.optionaltasks，
--     ★★ 但它们来自 :108-110 的「task_set 字段拷贝」⇒ 数据换了来源，逻辑没变。
    assert(data.optionaltasks == nil, "level 'optionaltasks' should be specified as an override via 'task_set' now.")
-- ★ 同上：self.optionaltasks = nil（防御性冗余）。
	self.optionaltasks = nil
-- ★★★★★★ 迁移契约 ④（valid_start_tasks）：出生点候选任务列表。
--   ★★ 消费仍在 storygen.lua:918-920，但数据同样来自 task_set 拷贝。
    assert(data.valid_start_tasks == nil, "level 'valid_start_tasks' should be specified as an override via 'task_set' now.")
-- ★ 同上：self.valid_start_tasks = nil（防御性冗余）。
    self.valid_start_tasks = nil
-- ★ hideminimap：★ 前端小地图隐藏标记（不影响生成）。
	self.hideminimap = data.hideminimap or false
-- ★ min/max_playlist_position：★ 标了 --UNUSED 但有默认值 0 / 999。
--   ★★ 与 :15 不同：这两个**有默认值**，说明曾经被 UI 排序用过。
--   ★★ 属残留字段，无害。
	self.min_playlist_position = data.min_playlist_position or 0  --UNUSED
	self.max_playlist_position = data.max_playlist_position or 999  --UNUSED
-- ★★ ordered_story_setpieces：★ **标了 Deprecated 但仍然搬运**。
--   ⚠ 疑似缺陷（轻微）：与 :16 的硬 assert 风格不一致。
--   ★★ 为什么它没被 assert 掉：★ 它**确实还在被用**——
--     storygen.lua:173 `local parts = self.level.ordered_story_setpieces or {}`
--     在 PlaceTeleportatoParts 里读它。
--   ★★ 而那个函数本身在 :119 标了 "-- This is deprecated"。
--   ⇒ ★★★ 「废弃」在三处同时出现却从未真正删除 = 典型的技术债形态。
--     ★★ 而且 storygen.lua:180 的 maxdepth/#parts 在它为空表时
--       ★★ 会静默失效（除零 ⇒ -inf ⇒ 什么都不放）。见该行注释。
	self.ordered_story_setpieces = data.ordered_story_setpieces -- Deprecated
-- ★★ required_prefabs：★ 关卡级必需 prefab 清单。
--   ★★★ 三重来源求和校验的**来源 1**（forest_map.lua:927-935）。
--   ★ 与任务级 required_prefabs（map/task.lua:33）**相加**而非覆盖。
	self.required_prefabs = data.required_prefabs
-- ★★ background_node_range：★ 每个 task 加多少背景节点的区间。
--   消费：storygen.lua:89-91
--     `min_bg = level.background_node_range and [1] or 0`
--     `max_bg = level.background_node_range and [2] or 2`
--   ★★ 缺省 {0, 2} ⇒ **每个 task 都会加 0~2 个背景节点**。
--   ★★ 这是「让 Voronoi 胞元之间不长成整齐方格」的主要手段。
	self.background_node_range = data.background_node_range
-- ★★ blocker_blank_room_name：★ 封口用的「空房间」模板名。
--   消费：storygen.lua:988 给入口节点挂 2 个 blocker_blank（:1056）。
--   ★★ 它是「锁」在像素层的物理形态之一：不可通行地块。
	self.blocker_blank_room_name = data.blocker_blank_room_name

-- ★ required_setpieces：★ 关卡**必须**出现的静态场景件（distinct 于随机池）。
--   消费：本文件 :168-169 deepcopy 后 :176-185 分配到各任务。
	self.required_setpieces = data.required_setpieces
-- ★ numrandom_set_pieces：★ 要塞多少个**随机**场景件，缺省 0。
--   ★★ 典型值：多数关卡 3~8。
	self.numrandom_set_pieces = data.numrandom_set_pieces or 0
-- ★ random_set_pieces：★ 随机场景件的**候选池**（场景件名数组）。
--   ⚠ 与 :32 配对使用：★ 若 numrandom_set_pieces > 0 但本项为 nil，
--     ★★ :172 `self.random_set_pieces[math.random(#self.random_set_pieces)]`
--       ⇒ `#nil` 崩溃。★ 属「配置必须成对」的隐式约束，无校验。
	self.random_set_pieces = data.random_set_pieces or nil

-- ★ playstyle：★ 玩法风格标签（宽松/标准/硬核…），影响关卡参数。
	self.playstyle = data.playstyle

-- ★ chosen_tasks = nil：★ 初始为空，ChooseTasks 填。
--   ★★ 消费者 worldgen_main.lua / forest_map.lua:495 的 BuildStory(tasks=…)。
    self.chosen_tasks = nil

-- ★ version：缺省 1。★ 用于存档兼容判定。
    self.version = data.version or 1
-- ══════════════ 构造结束 ══════════════
-- ★★ 统计：Level 实例字段共 30 余个，其中
--   · 真正影响生成：约 15 个（overrides / required_prefabs /
--     background_node_range / blocker_blank_room_name / required_setpieces /
--     numrandom_set_pieces / random_set_pieces / version / location）
--   · 仅前端用：name / desc / hideinfrontend / hideminimap / playstyle
--   · ★ 已废弃但保留：ordered_story_setpieces / override_triggers
--   · ★ 恒为 nil：set_pieces / numoptionaltasks / optionaltasks / valid_start_tasks
end)

-- ══════════════ ApplyModsToTasks：TaskPreInit 钩子 ══════════════
-- ★★ 对每个任务调 ModManager:GetPostInitFns("TaskPreInit", task.id)，
--   ★★ **按任务 id 精确匹配** ⇒ mod 只能改自己关心的任务。
-- ★★ 这是本文件与 map/storygen.lua:99 RoomPreInit、
--   :95 TaskSetPreInit、:100 TaskSetPreInitAny、:112 LevelPreInit、
--   :117 LevelPreInitAny 一起组成的**六层 mod 钩子体系**。
--   ★★ 六层的区别全在「匹配粒度」：
--     RoomPreInit        → 按房间名（最细）
--     TaskPreInit        → 按任务 id
--     TaskSetPreInit     → 按 task_set 名
--     TaskSetPreInitAny  → 全部 task_set
--     LevelPreInit       → 按关卡 id
--     LevelPreInitAny    → 全部关卡
--   ⇒ ★ 这是本仓库最完整的扩展点设计，值得单独成篇。
function Level:ApplyModsToTasks(tasklist)

	for i,task in ipairs(tasklist) do
		--print(i, "modding task "..task.id)
		local modfns = ModManager:GetPostInitFns("TaskPreInit", task.id)
		for i,modfn in ipairs(modfns) do
-- ★ print 出被改的任务名 ⇒ mod 生效有日志。★ 好实践。
			print("Applying mod to task '"..task.id.."'")
			modfn(task)
		end
	end
end

-- ══════════════ ★★ GetOverridesForTasks：资源替换 ══════════════
-- ★★★ 原始注释（:59）本身就是一处「设计意图的自述」：
--   -- WE MAKE ONE SELECTION FOR ALL TASKS or ONE PER TASK
-- ★★ 即「所有任务共享一次选择」或「每个任务各选一次」——
--   ★★★ 而代码实现的是**后者**（:66-78 的 for 循环在 tasklist 内层）。
--   ⇒ ★★ 注释与实现**不一致**：注释说「二选一」，代码是「每任务一次」。
--     ⚠ 疑似缺陷（注释误导，但代码行为自洽且可用）。
function Level:GetOverridesForTasks(tasklist)
	-- Update the task with whatever overrrides are going
-- ★ resource_substitution.GetSubstitute(name)：查这张替换表。
--   ★★ 映射表本身在别处（★ grep 核实不在 map/ 内）。
	local resources = require("map/resource_substitution")

	-- WE MAKE ONE SELECTION FOR ALL TASKS or ONE PER TASK
-- ★★ 遍历关卡级 substitutes（key = 原资源名）。
--   ★★ 用 pairs ⇒ ★ 顺序不定 ⇒ 若多个替换同时生效，
--     ★★ 最终哪个任务先被写、哪个后被写是随机的。
--   ★ 实务上不同 substitute 作用于不同 prefab，互不冲突 ⇒ 影响可忽略。
	for name, override in pairs(self.substitutes) do

-- ★★ 「名字 == 替换名」⇒ 跳过。★ 防自替换的短路。
		local substitute = resources.GetSubstitute(name)

		if name ~= substitute then
-- ★★ print 出替换信息 ⇒ 玩家/开发者在日志里能看到资源被换掉了。
--   ★★★ 这是本文件唯一一处「主动暴露资源替换」的日志。
--     ★★ 对 E2 类缺陷排查很有用：玩家说「矿变少了」，这里能看出是不是替换。
			print("Substituting [".. substitute.."] for [".. name.."]")
-- ★★★ 内层循环：**逐任务**摇随机数。
--   ★★ 一次 ChooseTasks 会消耗 **N 个 math.random()**（N = 任务数）。
--   ★★ ⇒ 这是本文件最大的随机消耗点，★ 直接影响可复现性。
			for task_idx,val in ipairs(tasklist) do
-- ★★ chance = math.random() —— perstory 的随机判定。
--   ★★ 语义：★「这个任务要不要做这次替换」，是个 Bernoulli 采样。
--   ★★ 注意是在循环体内每次重摇 ⇒ **各任务独立**。
				local chance = 	math.random()
-- ★★ if chance < override.perstory —— 命中则准备写 task.substitutes。
--   ★★ perstory ∈ [0,1]：0 = 从不替换，1 = 总是替换。
				if chance < override.perstory then
					if tasklist[task_idx].substitutes == nil then
						tasklist[task_idx].substitutes = {}
					end
					--print(task_idx, "Overriding", name, "with", substitute, "for:", self.name, chance, override.perstory )
-- ★★★ 写入点：`tasklist[task_idx].substitutes[name] = {name=substitute,
--   percent=override.pertask}`。
-- ★★★ 这是 substitutes 的**唯一产生点**。★ 注意：
--   · 挂在 **task 的 deepcopy** 上，不是 Level 上；
--   · ★★ 所以 map/task.lua:1 的 Task 构造**故意不搬运**它（见该文件注释）；
--   · 消费在 storygen.lua:1211 RunTaskSubstitution。
-- ★★ pertask 语义（极易误解）：
--   ★★ 它不是「替换概率」，而是「**替换后新资源占多大比例**」。
--   storygen.lua:1222-1223：
--     items[v.name] = items[k] * v.percent
--     items[k]     = items[k] * (1.0 - v.percent)
--   ★★ 所以 percent=1 ⇒ 整换；percent=0.5 ⇒ 一半换一半留。
--   ★★ 「pertask」这个命名让人以为是「按任务的概率」，★ 实为「按任务的比例」。
--   ⚠ 这是本文件最容易让人做出错误决策的命名。
					tasklist[task_idx].substitutes[name] = {name = substitute, percent = override.pertask}
				-- else
				-- 	print("NOT overriding ", name, "with", substitute, "for:", self.name, chance, override.perstory)

				end
			end
		end
	end

	return tasklist
end

-- ══════════════ ★★ GetTasksForLevel（极简）══════════════
-- ★ 返回 chosen_tasks。★ forest_map.lua 的 tasks 参数就来自它。
-- ★★ 名字 GetTasksForLevel 与同文件 :152 GetTasksForLevelSetPieces
--   极易混淆：★ 后者是**过滤后**的子集（排除了 level_set_piece_blocker）。
function Level:GetTasksForLevel()
    return self.chosen_tasks
end

-- ══════════════ ★★★ ChooseTasks：整个生成流程的任务入口 ══════════════
-- ★★★ 执行顺序本身就是语义（★ 改顺序会改变世界生成结果）：
--   :92   assert(必须声明 task_set)
--   :94   取 task_set 数据（deepcopy）
--   :95-104  TaskSetPreInit / TaskSetPreInitAny 钩子
--   :106  assert 数据非空（★ 含「预设是带 mod 建的」提示）
--   :108-110 ★★ 把 task_set 的字段拷贝到 self
--   :112-121 LevelPreInit / LevelPreInitAny 钩子
--   :123-125 必需任务入队
--   :127  TaskPreInit 钩子
--   :129-145 可选任务入队
--   :147  资源替换（挂 substitutes）
--   :149  落盘 chosen_tasks
-- ★★★ 最关键的是「钩子在拷贝的哪一侧」：
--   · TaskSetPreInit(:95) —— 在**拷贝之前** ⇒ 改 task_set_data 会生效；
--   · LevelPreInit(:112)   —— 在**拷贝之后** ⇒ 此时 self 已被覆盖，
--     ★★★ mod 若想「改回」level 原始字段，必须自己先备份。
--   ⚠ 疑似缺陷（顺序陷阱）：两层钩子作用在不同的对象快照上，
--     ★★ 但 API 长得一模一样（都是 modfn(task_set_data) / modfn(self)），
--     ★★ mod 作者极容易误判。★ 建议文档里明确区分。
function Level:ChooseTasks()
	--print("Getting tasks for level:", self.name)
	local tasklist = {}
-- ★★ assert：level 必须显式声明 overrides["task_set"]。
--   ★★ 没有默认值 ⇒ 漏写直接崩（好设计：宁可崩也不要随机挑一套任务）。
    assert(self.overrides["task_set"] ~= nil, "Must specify the task set for a level!")
-- ★ 取 task_set 名（字符串，如 "default" / "cave" / "quagmire"）。
    local task_set = self.overrides["task_set"]
-- ★★ tasksets.GetGenTasks(task_set) —— 内部 deepcopy（tasksets.lua:12）。
--   ★★ 所以每个 level 拿到的是独立副本，mod 改坏了不会污染全局。
--   ★★ 这一点很重要：★ ChooseTasks 可以被反复调用（换预设时）。
	local task_set_data = tasksets.GetGenTasks(task_set)
	local modfns = ModManager:GetPostInitFns("TaskSetPreInit", task_set)
	for i,modfn in ipairs(modfns) do
		print("Applying mod to task set '"..task_set.."'")
		modfn(task_set_data)
	end
	modfns = ModManager:GetPostInitFns("TaskSetPreInitAny")
	for i,modfn in ipairs(modfns) do
		print("Applying mod to current task set")
		modfn(task_set_data)
	end

-- ★★ assert(task_set_data ~= nil, …)。
--   ★★★ 错误信息写得非常好（★ 值得学）：
--     "TaskSet 'X' has no data! If preset 'Y' was created with mods
--      enabled, please enable the mods."
--   ⇒ ★★ 直接给出了**最可能的根因**（预设带 mod 存下来的），
--     ★★★ 而不是干巴巴一句「数据为空」。★ 好的错误信息 = 省下的客服工单。
    assert(task_set_data ~= nil, ("TaskSet '" .. tostring(task_set) .. "' has no data! If preset '".. tostring(self.id) .. "' was created with mods enabled, please enable the mods."))

-- ★★★★★★ 全文件最关键的 3 行：把 task_set 表的**所有字段**拷到 Level 上。
--   ★★ 这意味着 map/tasksets/*.lua 里的表**拥有与 Level 构造同等的权力**：
--     它可以覆盖 location、overrides，甚至 overwrite 任意字段。
--   ★★★ 好处：★ 极致的可扩展性 —— 一个 taskset 就能改整个关卡。
--   ★★★ 风险：★ 极致的失控点 —— ★★ taskset 写错一个键会静默改变关卡行为，
--     ★★ 且**没有任何校验**（:108-110 无 assert、无日志）。
--   ⚠ 疑似缺陷（架构级）：
--     ★★ 这是「开放数据通道 + 零校验」的典型组合。
--     ★★ 对比 :16/:18/:20/:22 的硬 assert 风格，此处完全相反。
--   ★★ 一个 taskset 甚至可以写 `{tasks=…, task_set=…}` 造成自我影响。
	for k, v in pairs(task_set_data) do
		self[k] = v
-- ★ 拷贝结束。★⚠ 无任何日志 ⇒ 覆盖发生时完全静默。
	end

-- ★ LevelPreInit(id)：★ **拷贝之后**的关卡级钩子。
--   ★★ 此时 self 已被 task_set 覆盖 ⇒ mod 若要访问 level 原始值，
--     ★★ 必须自己在钩子里先备份（构造期数据已丢）。
--   ★★ ⚠ 顺序陷阱（见 :89 处汇总说明）。
	local modfns = ModManager:GetPostInitFns("LevelPreInit", self.id)
	for i,modfn in ipairs(modfns) do
		print("Applying mod to level '"..self.id.."'")
		modfn(self)
	end
-- ★ LevelPreInitAny：★ 对**所有**关卡生效的钩子（不限 id）。
--   ★★ 在 :112 之后 ⇒ 顺序上「先具体后通用」，
--     ★★ 也就是说通用钩子能看到特定钩子的修改结果。★ 这个顺序是对的。
	modfns = ModManager:GetPostInitFns("LevelPreInitAny")
	for i,modfn in ipairs(modfns) do
		print("Applying mod to current level")
		modfn(self)
	end

-- ★★★ 必需任务入队：★ `for i=1,#self.tasks do` —— 用 **ipairs 语义**。
--   ★★ self.tasks 来自 task_set 拷贝，是**数组** ⇒ 顺序 = 声明顺序。
--   ★★ ⇒ ★★ 这里**没有 pairs 陷阱**（与 storygen.lua 的大量 pairs 对比）。
--     任务入队顺序稳定 ⇒ chosen_tasks 数组顺序稳定。
--   ★★★ 顺序稳定性很重要：level.lua:178 与 storygen.lua:861 的
--     math.random(#tasks) 都依赖它才能得到可复现的结果。
	for i=1,#self.tasks do
-- ★ EnqueueATask：查表 + deepcopy（见 :219）。
		self:EnqueueATask(tasklist, self.tasks[i])
	end

-- ★★★ TaskPreInit 钩子：★ 在**全部任务入队后**统一施加。
--   ★★ 顺序理由：★ 只有等所有任务都在 tasklist 里了，
--     ★★ mod 才能「跨任务」做协调（比如把 A 的钥匙改给 B）。
--   ★★ 这就是为什么 TaskPreInit 必须晚于 :123-125。
	self:ApplyModsToTasks(tasklist)

-- ★★ 可选任务入队：★ 先 shuffle 再取前 N 个。
--   ★★ 即「随机挑 numoptionaltasks 个可选任务塞进队列」。
--   ★★★ 这是世界多样性的一个来源：★ 同 task_set 不同种子 ⇒ 任务列表不同。
	if self.numoptionaltasks and self.numoptionaltasks > 0 and self.optionaltasks then
-- ★★ shuffleArray（util.lua:864）：原地 Fisher-Yates。
--   ★★ 它**消耗 (#optionaltasks - 1) 个随机数**，
--     ★★ 且 inplace 修改了 self.optionaltasks（= task_set 拷贝的那份）。
--   ⚠ 副作用：★ 若 ChooseTasks 被调用两次，第二次洗的是**已洗过**的数组。
--     ★★ 洗两次不改变「均匀分布」性质，但会多消耗随机数。
		local shuffletasknames = shuffleArray(self.optionaltasks)
-- ★ numtoadd = self.numoptionaltasks —— 还要加几个。
		local numtoadd = self.numoptionaltasks
		local i = 1
-- ★★★ ⚠ 疑似缺陷的现场：可选任务**支持嵌套表**（:134）。
--   语义：`optionaltasks = { {"A","B","C"}, "D", "E" }`
--   ⇒ 第一个槽位是「一组任务」，三个都要加。
--   ★★ 设计意图（推测）：让 DLC/主题包能整组出现或整组不出现。
		while numtoadd > 0 and i <= #self.optionaltasks do
-- ★★ if type(self.optionaltasks[i]) == "table" ⇒ 嵌套分支。
			if type(self.optionaltasks[i]) == "table" then
-- ★★ 内层 for 遍历嵌套表里的任务名。
--   ⚠★★★ 疑似缺陷（真实）：**numtoadd 在内层按元素数递减（:137），
--     而外层 i 只 +1（:143）**。
--   ★★ 后果：★ 若第一个槽位是含 10 个任务的表，
--     ★★★ numoptionaltasks=3 会被**一次性塞满 10 个**（直到 numtoadd 变负）。
--   ★★ 循环条件是 `numtoadd > 0`，所以它不会溢出，
--     ★★ 但「要 3 个」变成「要 10 个」⇒ 与配置意图不符。
--   ★★ 正确写法应是内层也检查 numtoadd > 0 后 break。
--   ⚠ 当前不触发，是因为 tasksets/*.lua 里没人用嵌套写法。
				for i,taskname in ipairs(self.optionaltasks[i]) do
					self:EnqueueATask(tasklist, taskname)
-- ★★ numtoadd = numtoadd - 1 —— ★★ 按内层元素个数递减（缺陷点）。
--   ★★ 对比 :142 的外层递减，两者粒度不同 ⇒ 就是问题根源。
					numtoadd = numtoadd - 1
				end
			else
-- ★★ else 分支：普通单任务名，同样递减。
				self:EnqueueATask(tasklist, self.optionaltasks[i])
				numtoadd = numtoadd - 1
			end
-- ★★ i = i + 1 —— ★★ 无论内层加了几个，外层只前进一格（缺陷点）。
			i = i + 1
		end
	end

-- ★★ 资源替换：★ 必须放在任务全部入队**之后**。
--   ★★ 因为 :73 要写 tasklist[task_idx].substitutes ⇒ tasklist 必须完整。
--   ★★ ⇒ 与 :127 的 TaskPreInit 是同一类顺序约束。
--   ⚠ 但 :127（TaskPreInit）在 :147（substitutes）**之前**，
--     ★★ ⇒ ★★ mod 在 TaskPreInit 里看不到 substitutes，
--       ★★ 也无法预判哪些资源会被替换。★ 一个真实的扩展盲点。
	self:GetOverridesForTasks(tasklist)

-- ★★ chosen_tasks 落盘。★ 这是 forest_map.lua:495 的 tasks 参数来源。
--   ★★ 数组顺序 = 必需任务（:123 声明序）+ 可选任务（:130 洗牌序）。
	self.chosen_tasks = tasklist
end

-- ══════════════ ★ GetTasksForLevelSetPieces：过滤 blocker ══════════════
-- ★★ 返回一个**新数组**，剔除 level_set_piece_blocker == true 的任务。
--   用途：只让「正常」任务去承接关卡级场景件。
-- ★★ 为什么必须过滤：★ 某些任务是「程序化拼接房」（如 CentipedeCaveTask），
--   ★★ 塞静态布局进去会破坏它们的形状/机关。
-- ★★ 对应字段：map/task.lua:35 level_set_piece_blocker。
-- ★★★ 注意与 :85 GetTasksForLevel 的区别：
--   :85 返回**全部** chosen_tasks（给 forest_map 生成用）；
--   :152 返回**过滤后**的子集（只给 ChooseSetPieces 用）。
--   ⇒ ★★ 两个名字只差一个词，极易在外部代码里用错。
function Level:GetTasksForLevelSetPieces()
	local tasks = {}
	for _, v in ipairs(self.chosen_tasks) do
-- ★★ if not v.level_set_piece_blocker then —— 唯一判据。
--   ★★ 无日志、无统计 ⇒ 有多少任务被过滤掉是不可见的。
--   ⚠ 若某关卡把所有任务都标了 blocker，则返回空数组 ⇒
--     ★★ 下游 :166 的 `if #tasks > 0` 会整体跳过场景件分配 ⇒
--     ★★★ 该关卡的**所有**关卡级场景件都消失，且**完全静默**。
--     ★★ 这正是 E2 类缺陷的形态：无日志的静默丢失。
		if not v.level_set_piece_blocker then
			table.insert(tasks, v)
		end
	end
-- ★ 返回过滤后的数组。
	return tasks
end

-- ══════════════ ★★ ChooseSetPieces：把场景件分配到任务 ══════════════
-- ★★★ 本函数分两半：
--   · :167-186  ★ 生效路径（required_setpieces + random_set_pieces）
--   · :187-216  ★★ **完全死代码**（self.set_pieces 被 :16 assert 强制为 nil）
-- ★★ 死代码的位置在 :187 的 `for name, choicedata in pairs(self.set_pieces or {})`，
--   ★★ 由于 self.set_pieces 恒为 nil，`nil or {}` ⇒ {} ⇒ 循环体永不执行。
--   ★★★ 讽刺之处：★ 那段死代码里恰好写着本函数最重要的设计不变量，
--     而生效路径**没有**这个不变量。详见 :202 处注释。
function Level:ChooseSetPieces()
-- ★★ assert：必须先调 ChooseTasks。★ 顺序契约。
    assert(self.chosen_tasks ~= nil, "Must call ChooseTasks before ChooseSetPieces")

-- ★ 取过滤后的任务数组（:152）。★★★ 这就是「场景件不能进哪些任务」的来源。
	local tasks = self:GetTasksForLevelSetPieces()
-- ★★ if #tasks > 0 then ——★ 没有可用任务就整段跳过（静默）。
--   ⚠ 见 :155 的推论：全被 blocker ⇒ 场景件全部丢失且无日志。
	if #tasks > 0 then
-- ★ set_pieces = {}：本地累加器，不写回 self。
		local set_pieces = {}
-- ★★ if self.required_setpieces ~= nil then —— 关卡级必需场景件。
--   ★★ deepcopy：★ 每个 task 拿到的是**独立副本**，
--     ★★★ 这是必需的：同一个场景件若塞进 3 个任务，
--       ★★★ 不 deepcopy 就会共享同一张表，后续改动互相污染。
		if self.required_setpieces ~= nil then
			set_pieces = deepcopy(self.required_setpieces)
-- ★★ 随机场景件循环：★ 塞 numrandom_set_pieces 个（默认 0）。
--   ★★★ 注意 :172 每个场景件都独立摇一次 math.random(#池子)，
--     ★★ **允许重复**（同一场景件可能被摇中两次）。
--   ★★ 对比 :198-215 的死代码里有 `idx[k]=nil; table.remove(choices,i)`
--     ★★★ 保证「一任务一场景件」——★ 那份唯一性在生效路径里不存在。
			for i = 1, self.numrandom_set_pieces do
				--Get random set piece to put in task
-- ★★ 从候选池随机取一个名字。⚠ 池为 nil 时 `#nil` 崩溃（见 :34 处注释）。
--   ★★★ 允许重复 ⇒ 可能两个任务拿到同一个场景件名字，
--     ★★ 而 storygen.lua:293 的 `countstaticlayouts[setpiece_name] = 1`
--       ★★★ 是**赋值不是累加** ⇒ 若同一 task 里被塞进两个同名场景件，
--         ★★ 后者覆盖前者（实际都只放 1 个，无害）。
--     ★★ 但若同一名字被塞进**不同** task ⇒ 两个任务各放 1 个（符合预期）。
				table.insert(set_pieces, self.random_set_pieces[math.random(#self.random_set_pieces)])
			end
		end

-- ★★ 逐个已确定的场景件，随机挑一个 task 塞进去。
		for _, set_piece in ipairs(set_pieces) do
			--Get random task
-- ★★ `local idx = math.random(#tasks)` ——★ 取数组下标，不是 task id。
--   ★★ 依赖 #tasks：来自 :154-158 的 table.insert 构建的**数组** ⇒ 顺序稳定。
--   ★★ ⇒ ★ 这里**没有** pairs 顺序陷阱。★（对比 storygen.lua:477 的 pairs 遍历。）
--   ★★★ 一个场景件 = 一个 math.random() ⇒ numrandom + #required 个随机数。
			local idx = math.random(#tasks)

-- ★★ if tasks[idx].random_set_pieces == nil then —— 懒初始化。
			if tasks[idx].random_set_pieces == nil then
				tasks[idx].random_set_pieces = {}
			end
-- ★★ print 出分配结果 ⇒ ★ 场景件去了哪个任务是**可见的**。
--   ★★★ 这是全文件最好的一处日志：它是「关卡级配置生效」的
--     ★★★ **唯一可观测点**。E2 类缺陷排查时先看这行。
			print(set_piece .. " added to task " .. tasks[idx].id)
-- ★★ table.insert(tasks[idx].random_set_pieces, set_piece)。
--   ★★ 注意 tasks 是 :152 的**过滤后数组**，其元素与 chosen_tasks 同对象
--     ★★ ⇒ 这里改的是 chosen_tasks 里的 task 对象。★ 引用而非拷贝。
			table.insert(tasks[idx].random_set_pieces, set_piece)
		end
	end
-- ══════════════════════════════════════════════════════════════
-- ★★★★ 【完全死代码】★ 因为 :16 的 assert 强制 data.set_pieces == nil，
--   ★★ 于是 self.set_pieces 恒为 nil（:17 又显式赋 nil），
--   ★★ `nil or {}` ⇒ {} ⇒ **这个 for 循环一次都不执行**。
-- ★★ 但讽刺的是：★ 这段死代码里写着本函数**最重要的设计不变量**：
--     :202-203 的注释「Only one layout per task」
--   ★★ 而**生效路径**（:176-185）恰恰没有这个不变量。
-- ⇒ ★★ 结论：这条不变量随迁移一起被「删掉」了，
--   ★★★ 现在的行为是「一个场景件可以塞进同一个任务的多个位置，
--     ★★★ 也可以多个场景件塞进同一个任务」。
--   ⚠ 疑似缺陷（表现层无害，但会让「场景件应该分散开」的直觉失效）。
	for name, choicedata in pairs(self.set_pieces or {}) do
        --print("Adding",name, choicedata.count)
		local found = false
		local idx = {}
-- ★ idx[task.id] = i：建 id → 下标的反查表（数组语义，顺序稳定）。
		for i, task in ipairs(self.chosen_tasks) do
			idx[task.id] = i
		end
-- ★ table.invert(idx)：反查表取反 ⇒ 变成 下标 → id。
--   ★★ 于是 availabletasks 是**「任务 id 集合」**（值是 id，键是下标）。
--   ★★ 命名有误导性：变量叫「available**tasks**」但存的是 id 字符串。
--   ★★ 而下面 :197 的 ArrayIntersection 求的是**交集**，结果仍是 id 数组。
--     ★⇒ :205 `idx[choices[idx_choice]]` 用 id 查下标 ⇒ 逻辑自洽。
        local availabletasks = table.invert(idx)

		-- Pick one of the choices and add it to that task
-- ★★ ArrayIntersection(choicedata.tasks, availabletasks)：
--   ★★ 「这个场景件允许放在哪些任务」∩ 「本次实际有的任务」。
--   ★★★ 这是本设计的关键收敛点：★ 场景件的**允许范围**由数据声明，
--     ★★★ 实际选择只在这个交集里做。⇒ 不会出现「放到不该放的任务」。
--   ★★ 但注意：★ 因为这段是死代码，★ 这个「允许范围」机制
--     ★★★ 在当前版本里**完全没有生效**。
		local choices = ArrayIntersection(choicedata.tasks, availabletasks)
-- ★ count = choicedata.count or 1：要放几个（默认 1）。
		local count = choicedata.count or 1

-- ★★ assert(choices and #choices > 0, "Trying to add set piece '"..name..
--   "' but no choices given.") ——★ 好消息：这在死代码里所以不生效。
--   ★★ 若这段是活的，那么一个「允许范围与实际任务无交集」的场景件
--     ★★ 会让整个世界生成崩溃。★ 迁移把这颗雷也一起拆掉了。
		assert(choices and #choices > 0, "Trying to add set piece '"..name.."' but no choices given.")

		-- Only one layout per task, so we stop when we run out of tasks or
-- ★★★ 「Only one layout per task, so we stop when we run out of tasks or」
--   ★★★ 这是**全文件最可惜的一行注释**：
--     ★★ 它准确描述了一个本来存在的不变量，但因为 :16 的 assert，
--       ★★★ 连同实现它的整段代码一起成了死代码。
--     ★★ ⇒ 迁移不仅改了数据源，还**顺手删掉了一个正确性约束**。
--   ⚠ 这是「大规模迁移」的典型副作用：★ 断言挡住了新写法，
--     ★★ 却没人为旧代码里的隐含约束找到新家。
		while count > 0 and #choices > 0 do
-- ★★ idx_choice = math.random(#choices) —— 死代码内的随机点。
            local idx_choice = math.random(#choices)
            local choice = idx[choices[idx_choice]]
-- ★★ if self.chosen_tasks[choice].set_pieces == nil then ——懒初始化。
--   ★★ 注意写的是 **self.chosen_tasks**（全部任务），而 :180/:184 写的是
--     ★★ tasks（过滤后子集）★★ ⇒ 两处用的对象集合不同。
--   ★★ 但因为这段是死代码，这个不一致不会造成实际问题。
            if self.chosen_tasks[choice].set_pieces == nil then
                self.chosen_tasks[choice].set_pieces = {}
            end
            --print("\tinserted in",self.chosen_tasks[choice])
-- ★★ table.insert(..., {name=name, restrict_to=choicedata.restrict_to})。
--   ★★ restrict_to 的消费在 storygen.lua:234：
--     `setpiece_data.restrict_to ~= "background" or room.data.type == "background"`
--   ★★ 即「restrict_to = "background" 的场景件只放进背景节点」。
--   ★★ ⇒ 「允许范围」有两层：① 允许放哪些任务（本段，死代码）
--     ★★ ② 允许放进哪类房间（restrict_to，生效）。
            table.insert(self.chosen_tasks[choice].set_pieces, {name=name, restrict_to=choicedata.restrict_to})

-- ★★★ idx[choices[idx_choice]] = nil + table.remove(choices, idx_choice)
--   ★★★ 这两行是「一任务一场景件」的实现：把已选任务从候选里剔除。
--   ★★★ 而这两行随 :16 的 assert 一起变成了死代码。
--     ★★ ⇒ ★★ 这就是 HEADER 里那条 ⚠ 缺陷的确切根因与行号。
            idx[choices[idx_choice]] = nil
            table.remove(choices, idx_choice)
            count = count-1
		end
	end
end

-- ══════════════ EnqueueATask ══════════════
-- ★★ 三步：查表 → 断言非空 → **deepcopy** 入队。
function Level:EnqueueATask(tasklist, taskname)
	local task = tasks.GetTaskByName(taskname)
	if task then
		--print("\tChoosing task:",task.id)
-- ★★★ table.insert(tasklist, deepcopy(task)) ——★ 全流程固定的拷贝开销。
--   ★★★ 为什么必须 deepcopy：★ 因为 :147 之后每个 task 会被挂上
--     ★★★ **各自的** substitutes 表（:73）。若共享同一对象，
--       ★★★ 所有任务的 substitutes 会互相覆盖。
--   ★★ 拷贝量级：约 40~100 个任务 × 任务表大小（含 room_choices 等），
--     ★★ 相对 Lloyd 的 2-8 s 可忽略（< 50 ms 预算内）。
--   ★★ 但 ★ 它是「为什么 Task 是 immutable 而 Level 不是」的根本原因。
		table.insert(tasklist, deepcopy(task))
	else
-- ★★ assert(task, "Could not find a task called "..taskname)
--   ★★★ 注意这里断言的是 **task 变量**而不是 taskname，
--     ★★ 所以错误信息里 taskname 已经在字符串里拼进去了。★ 写法正确。
--   ★★★ 另一个细节：★ :223 的 assert 缺失（这里只在 else 里断言）——
--     若 task 存在但 deepcopy 失败…不会发生。可忽略。
		assert(task, "Could not find a task called "..taskname)
	end
end

-- ══════════════ SetID / SetBaseID / SetNameAndDesc ══════════════
-- ★★★ 这三个函数都做同一件事：**写两份**（原字段 + worldgen_* 镜像）。
-- ★★ 镜像字段的用途（★ 重要）：
--   · 世界生成跑在**独立离线 Lua VM**（worldgen_main.lua）里；
--   · ★★ 前端在**游戏 VM** 里选好预设，把 Level 表序列化传给 worldgen VM；
--   · ★★ 两个 VM 的命名空间不同 ⇒ 用 worldgen_* 前缀区分「给 worldgen 用的副本」。
--   ⇒ ★★ 这些镜像字段**不可删**（否则序列化后 worldgen 侧读不到）。
function Level:SetID(id)
-- ★ assert(id ~= nil) —— 重复了一次构造期的 :5 检查。★ 无害的防御。
	assert(id ~= nil, "level must specify an id." )
-- ★ self.id = id —— 主字段（前端显示用）。
	self.id = id
-- ★ self.worldgen_id = id —— ★ 镜像（worldgen VM 读）。
	self.worldgen_id = id
end

-- ★ SetBaseID：baseid 是「关卡家族」标识（如 cave 系列共用 baseid）。
--   ★★ 用途：★ 前端按 baseid 分组显示，★ 存档按 baseid 做兼容。
function Level:SetBaseID(id)
	self.baseid = id
-- ★ worldgen_baseid = id —— 同 :232 的镜像模式。
	self.worldgen_baseid = id
end

-- ★ SetNameAndDesc：★ 关卡显示名与描述。
--   ★★ 注意 `name or ""` —— nil 时给空串而非 nil，
--     ★★ 简化下游的 nil 检查。★ 小而实用的默认值。
function Level:SetNameAndDesc(name, desc)
	self.name = name or ""
	self.desc = desc or ""
-- ★ worldgen_name = self.name —— 镜像。
	self.worldgen_name = self.name
-- ★ worldgen_desc = self.desc —— 镜像。
-- ★★ 全文件结束（245 行）。
-- ★★★ 本文件的三层价值总结：
--   ① **迁移契约**：4 个 assert 把废弃字段变硬错误（★ 值得学）；
--   ② **mod 钩子体系**：6 层不同粒度的扩展点（★ 值得学）；
--   ③ ★★ **反面教材**：:108-110 的开放拷贝零校验、:187-216 的死代码
--      （连带删掉了「一任务一场景件」的不变量）、:129-145 的嵌套计数缺陷。
	self.worldgen_desc = self.desc
end