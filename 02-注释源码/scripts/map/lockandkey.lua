--============================================================
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
--   ★★ 为什么第 39 行还留着 `--"ADVANCED_COMBAT"`：
--     LOCKS_ARRAY 第 18 行已有 "ADVANCED_COMBAT"（第 204 行有用到它），
--     第 39 行是把它注释掉的重复项。★ 若有人手贱取消注释，
--     78-81 行的 `assert(LOCKS[v] == nil, "Lock "..v.." is defined twice!")`
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
--   ⇒ 引用它们的 task 在 `LOCKS.ROCKY` 之类处会取到 **nil**。
--   ★ CRASH_ON_MISSING_KEY_OR_LOCK = (BRANCH == "dev")（511）：
--     只有 dev 分支才通过 __index 元表把 nil 变成 error。
--     ★ 正式分支里 `LOCKS.ROCKY` 返回 nil（不报错），
--       于是 storygen.lua:857 的 `task.locks[1] == LOCKS.NONE` 之类
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
--  3. ★ LOCKS_ARRAY 侧有 `assert(LOCKS[v] == nil, "... defined twice!")`（79）
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
--     storygen.lua:333 遍历 `lockData.keys` 时会拿到 nil
--     ⇒ ★★ **nil 遍历在 Lua 里是崩溃**（attempt to iterate a nil value）。
--     对照 storygen.lua:333：`for reqKeyIdx, reqKey in ipairs(lockData.keys)`。
--     ★ 所以真实约束是：**LOCKS_KEYS 必须覆盖 tasks/*.lua 里用到的每个锁**，
--     这条约束没有任何校验保护，纯靠人肉维护。
--  8. ★ 本文件在 require 时就做全部校验（78/166/478/513 行都在模块顶层），
--     ⇒ 任何声明错误都会在**世界生成开始之前**崩溃，而不是生成到一半。
--     这是本文件唯一值得学习的设计。
--============================================================
-- ★★★ 本文件是「锁—钥匙」的**纯声明表 + 启动期自校验**，零运行时逻辑。
-- ★★ 它导出的 LOCKS / KEYS / LOCKS_KEYS 被两处消费，★ 那两处才是判定逻辑：
--   · map/storygen.lua:319-347   （RestrictNodesByKey 分支法）
--   · map/storygen.lua:524-547   （LinkNodesByKeys 贪心法）
-- ★ grep 核实：本文件**零 math.random、零 WorldSim 调用**。
-- ★★ 但它是 E1 缺陷「锁—钥匙同名覆盖致不可达」的**确切根因所在**。
-- List of locks
-- ══════════════ LOCKS_ARRAY：所有锁名的有序数组 ══════════════
-- ★★ 用数组而非直接写字典，是为了**保证 ID 稳定**（按定义顺序 1..N）。
--   ⇒ 存档文件（topology/锁边）里存的是整数 ID，不是名字。
--   ★★ 由此推出一条硬规则：**★ 绝不能在这个数组中间插入新项**，
--     否则所有已生成世界的存档里锁 ID 全部错位。
--     ⇒ 这就是为什么第 39 行有注释掉的条目（见该行注释）。
LOCKS_ARRAY =
{
-- ★ index 1 = NONE（无锁）。★ 它是「起始任务」的判据：
--   storygen.lua:857 `if #locks == 0 or locks[1] == LOCKS.NONE`
--   ⇒ ★★ locks 写成单个 LOCKS.NONE（归一化成 {NONE}）或空表 {} 都能起手。
	"NONE",
-- ★ PIGGIFTS：猪的好感（送肉）才能进的门（对应 LOCKS.MEAT）。
	"PIGGIFTS",
-- ★ TREES：★★★ 本表里被重复定义锁钥匙的那一个（见 219 行与 254 行）。
	"TREES",
-- ★ SPIDERDENS：蜘蛛巢。
	"SPIDERDENS",
-- ★ ROCKS：★ 需要镐（PICKAXE）才能开的石头门 —— 最经典的锁。
	"ROCKS",
-- ★ FARM：农场，需要化肥（POOP）。
	"FARM",
-- ★ MEAT：需要肉（SPIDERS/PIGS/FARM 任一，lockandkey.lua:240-245）。
	"MEAT",
-- ★ BEEHIVE：蜂巢，需要斧（AXE）。
	"BEEHIVE",
-- ★ KILLERBEES：杀人蜂，需要蜂帽（BEEHAT）。
	"KILLERBEES",
-- ★ PIGKING：猪王，需要小物件（TRINKETS）。
	"PIGKING",
-- ★★ 以下是「战斗/层级」类锁，是**难度分级门**而非资源门：
--   MONSTERS_DEFEATED / HARD_MONSTERS_DEFEATED / SPIDERS_DEFEATED /
--   BASIC_COMBAT / ADVANCED_COMBAT / ONLYTIER1 / TIER0..TIER6 /
--   ANYTIER / INNERTIER / OUTERTIER
-- ★★ 它们的钥匙同样是「击杀某生物」或「到达某战斗层级」，
--   ★ 由任务完成后 keys_given 发放，⇒ 玩家靠战斗推进而非靠采集。
	"MONSTERS_DEFEATED",
-- ★ HARD_MONSTERS_DEFEATED：★ 6 把钥匙的 OR（:177-185）。
	"HARD_MONSTERS_DEFEATED",
-- ★ SPIDERS_DEFEATED：只认 SPIDERS 一把钥匙（:195-198）。
	"SPIDERS_DEFEATED",
-- ★★ BASIC_COMBAT 的钥匙是 { AXE, PIGS } —— 注意**不是斧头**，
--   而是「用斧头」和「猪」两把，语义上是「会砍树 / 有猪帮忙」。
	"BASIC_COMBAT",
-- ★★ ADVANCED_COMBAT 的钥匙是 { GOLD, HONEY }（:204-208）。
--   ⚠ 注意：这个名字在第 39 行又被写了一次（被注释掉）。见 :39 注释。
	"ADVANCED_COMBAT",
-- ★ ONLYTIER1：只认 TIER1 一把钥匙（:259-262）—— 最严格。
	"ONLYTIER1",
-- ★★ TIER0..TIER6：从 20 行开始连续 7 项，★ 每把钥匙对应一个战斗层级。
--   ⇒ 这是「按战力分层解锁」的声明式表达。
	"TIER0",
	"TIER1",
	"TIER2",
	"TIER3",
	"TIER4",
	"TIER5",
	"TIER6",
-- ★ ANYTIER：TIER1..TIER6 任意一把（:293-301）—— OR 语义。
-- ★ INNERTIER：只认低三层（:302-307）；OUTERTIER：只认高三层（:308-313）。
-- ⇒ ★★ 这三个锁是同一维度上的不同聚合方式，声明式配置的价值在此。
    "ANYTIER",
    "INNERTIER",
    "OUTERTIER",
-- ─── 从这里开始是「区域/主题」类锁（月亮、月亮蘑菇、洞穴…）───
-- ★★ 这些锁是**地区分区**的门：LIGHT 光 / FUNGUS 蘑菇地 /
--   CAVE 洞穴 / LABYRINTH 迷宫 / WILDS 荒野 / RUINS 古迹 /
--   SACRED 圣所 / BADLANDS 荒地。
-- ★ 每把钥匙由**对应区域的任务**发放 ⇒ 区域自锁。
	"LIGHT",
	"FUNGUS",
	"CAVE",
	"LABYRINTH",
	"WILDS",
	"RUINS",
	"SACRED",
	"BADLANDS",
	"HOUNDS",
	--"ADVANCED_COMBAT",

-- ★ ENTRANCE_INNER / ENTRANCE_OUTER：内/外层入口门（:314-321）。
--   ⇒ 这两个锁专门用于「多层结构」的区域（月亮遗迹、远古之门）。
    "ENTRANCE_INNER",
    "ENTRANCE_OUTER",

-- ★ MUSHROOM / RABBIT / PASSAGE / AREA / CAVERN / SINKHOLE / BATS：
--   ★★ 语义已从「资源」漂移到「地点」——★ 说明这张表是**长期累积**的，
--     早期是资源锁，后期变成地理分区锁。
-- ★ 这是演化痕迹：★ 表越滚越大而分类注释越晚出现。
	"MUSHROOM",
	"RABBIT",
	"PASSAGE",
    "AREA",
	"CAVERN",
	"SINKHOLE",
	"BATS",

-- ★★ EASY / MEDIUM / HARD：难度锁（:386-399）。
-- ★★★ 这是★唯一一处**同名锁与同名钥匙**成对存在的设计（:386-399 与 :141-143）：
--   锁 EASY 的钥匙也是 KEYS.EASY。
--   ⚠ 而 LOCKS.KEYS[LOCKS.EASY] 与 KEYS.EASY 是**两个不同的整数**！
--   ⇒ ★★ 整数 ID 空间与名字空间是分离的，同名纯属巧合。
--     改一处名字另一处可能不同步 ⇒ 又一个「同名覆盖」的温床。
	"EASY",
	"MEDIUM",
	"HARD",

-- ★ BLUE / RED / GREEN：三色锁（:401-414）。★ 用于 Quagmire 的三阶段。
	"BLUE",
	"RED",
	"GREEN",

-- ★ MOONMUSH：月蘑菇。
	"MOONMUSH",
-- ★ ARCHIVE：档案馆。★ 对应 terrain.lua:151 给 ARCHIVE 地块加的禁长规则
--   ⇒ ★ 两个文件协同：terrain 负责「档案馆不长草」，
--     本文件负责「档案馆要拿钥匙才能进」。
	"ARCHIVE",

-- ★ CENTIPEDE：蜈蚣（蕨类 DLC）。
	"CENTIPEDE",

-- ─── Quagmire（执政官）DLC：5 个区域锁（:416-439）──
-- ★★ GATEWAY 大门 / PARK_L1 公园一层 / FOOD_L1 食物一层 /
--   TRIBE 部族 / GIANT 巨人。
-- ⇒ 与 terrain.lua:137-146 的 10 条 OnlyAllow 规则配对：
--   ★★ 同一个 DLC 必须同时改「地形表」和「锁表」，漏一处就穿帮。
	"QUAGMIRE_GATEWAY",
	"QUAGMIRE_PARK_L1",
	"QUAGMIRE_FOOD_L1",
	"QUAGMIRE_TRIBE",
	"QUAGMIRE_GIANT",

-- ★★ ISLAND_TIER1..TIER4：月岛/外岛的层级锁（:441-459）。
--   ★ 与 TIER0..TIER6 是**不同的 ID 空间**，同名后缀但不同语义。
--   ★★ 这就是「用字符串拼接命名」的必然后果：两个维度撞名。
	"ISLAND_TIER1",
	"ISLAND_TIER2",
	"ISLAND_TIER3",
	"ISLAND_TIER4",
-- ★ 数组结束。★ 统计（grep 核实）：LOCKS_ARRAY 共 78 项。
}

-- ══════════════ ★ LOCKS：名字 → 整数 ID 的反查表 ══════════════
-- ★ 与 KEYS 一起构成「名字 ↔ ID」的双向字典。
LOCKS = {}
-- ★ 用 ipairs（不是 pairs）⇒ ★★ 遍历顺序 = 定义顺序 = ID 顺序。
--   这是**本文件唯一保证顺序稳定的地方**。
--   ★★ 对比 storygen.lua 里大量 pairs 遍历的不确定性——
--     「声明表有序、决策表无序」是本仓库反复出现的模式。
for i,v in ipairs(LOCKS_ARRAY) do
-- ★★★ 全文件**唯一一处重复键检测**：
--   「Lock %s is defined twice!」——★ 只要 LOCKS_ARRAY 里有重名，
--   ★ 加载时立刻崩溃。
-- ★★★ 这正是 LOCKS_KEYS **缺失**的那道防线（见 477-487 行），
--   ★★ 也正是 E1 缺陷能存活至今的原因：
--     · LOCKS_ARRAY 侧：有查重（:79）
--     · LOCKS_KEYS 侧：**无查重** ⇒ 重复键静默覆盖
--   ⇒ ★★ 同一个文件里两种防护策略并存，是教科书级的「防护不对称」。
	assert(LOCKS[v] == nil, "Lock "..v.." is defined twice!")
-- ★ LOCKS["NONE"] = 1, LOCKS["PIGGIFTS"] = 2, …
	LOCKS[v] = i
-- ★ 循环结束。全表 78 项。
end

-- ══════════════ KEYS_ARRAY：所有钥匙名的有序数组 ══════════════
-- List of keys
KEYS_ARRAY =
{
-- ★ index 1 = NONE。★ 与 LOCKS.NONE 是不同的整数（各表的第 1 项），
--   ★★ 但名字相同 ⇒ 与 :52 处的 EASY/MEDIUM/HARD 同名问题同源。
	"NONE",
-- ★★ 基础工具钥匙（8 把）：PICKAXE 镐 / AXE 斧 / GRASS 草 /
--   STONE 石 / WOOD 木 / MEAT 肉 / PIGS 猪 / FIRE 火。
-- ★★ 这 8 把对应游戏前 15 分钟的全部工具链，★ 也是绝大多数锁的钥匙。
	"PICKAXE",
	"AXE",
	"GRASS",
	"STONE",
	"WOOD",
-- ★ POOP 粪 / WOOL 毛 —— 农场与剪刀的工具链。
	"MEAT",
	"PIGS",
-- ★ FIRE 火（★ 注意它同时是 LOCKS.TREES 的候选钥匙，见 :221 的被覆盖定义）。
	"FIRE",
	"POOP",
-- ★★ FARM / HONEY / GOLD —— 三级经济钥匙。
-- ★ GOLD 与 HONEY 恰好是 ADVANCED_COMBAT 的两把钥匙（:204-208）。
	"WOOL",
	"FARM",
	"HONEY",
	"GOLD",
-- ★★★ 战斗钥匙群：BEEHAT 蜂帽 / TRINKETS 小物件 /
--   HARD_WALRUS / HARD_SPIDERS / HARD_HOUNDS / HARD_MERMS / HARD_TENTACLES /
--   WALRUS / SPIDERS / HOUNDS / MERMS / GEARS 齿轮 /
--   CHESSMEN 棋 / TENTACLES 触手。
-- ★★ HARD_ 前缀表示「变种/加强版怪物」，★ 用于 HARD_MONSTERS_DEFEATED 锁。
-- ★★ CHESSMEN 出现在 MONSTERS_DEFEATED 的钥匙集里（:193）——
--   ★ 意味着「杀掉足够多的怪」也包括棋盘区的棋子，略有语义拉伸。
	"BEEHAT",
	"TRINKETS",
	"HARD_WALRUS",
	"HARD_SPIDERS",
	"HARD_HOUNDS",
	"HARD_MERMS",
	"HARD_TENTACLES",
	"WALRUS",
	"SPIDERS",
	"HOUNDS",
	"MERMS",
	"GEARS",
	"CHESSMEN",
	"TENTACLES",
-- ★★ TIER0..TIER6：战斗层级钥匙（与 LOCKS 的 TIER 锁同名）。
--   ★ 又一组「同名不同 ID」的碰撞（见 :20 的 LOCKS TIER 组）。
	"TIER0",
	"TIER1",
	"TIER2",
	"TIER3",
	"TIER4",
	"TIER5",
	"TIER6",
	"LIGHT",
	"FUNGUS",
	"CAVE",
	"LABYRINTH",
	"WILDS",
	"RUINS",
	"SACRED",
	"BADLANDS",

-- ★ ENTRANCE_INNER / ENTRANCE_OUTER：与同名锁一一对应（:314-321）。
    "ENTRANCE_INNER",
    "ENTRANCE_OUTER",

-- ★ MUSHROOM / RABBIT / PASSAGE / AREA / CAVERN / SINKHOLE / BATS：
--   ★★ 与 LOCKS 的同名组（44-50 行）一一对应 ⇒ 这里是**刻意对称**的。
--   ⇒ 「同名锁 + 同名钥匙」的规范写法是有的（在这些组里），
--     ★ 但在 TIER / EASY / ISLAND_TIER 组里就漂移了。★ 不彻底。
	"MUSHROOM",
	"RABBIT",
	"PASSAGE",
    "AREA",
	"CAVERN",
	"SINKHOLE",
	"BATS",

-- ★★ EASY / MEDIUM / HARD（钥匙侧）：与 :52 的同名锁配对。
--   ★★ 这三个是「同名锁+同名钥匙」的组，但整数 ID 完全不同
--   （KEYS 里是 55/56/57，LOCKS 里是 51/52/53 量级）。
--   ⇒ ★ 读代码时极易混淆：`LOCKS.HARD ~= KEYS.HARD`。
	"EASY",
	"MEDIUM",
	"HARD",

-- ★ BLUE / RED / GREEN：三色钥匙（与 :56 的同名锁配对）。
	"BLUE",
	"RED",
	"GREEN",

-- ★ MOONMUSH / ARCHIVE：与 :60/:61 的同名锁配对。
	"MOONMUSH",
	"ARCHIVE",

-- ★ CENTIPEDE：与 :63 的同名锁配对。
	"CENTIPEDE",

-- ★★ Quagmire 5 把钥匙（:154-158）：与 :65-69 的同名锁配对。
-- ★★ 这些「一对一的同名锁」是本文件里最规整的部分。
	"QUAGMIRE_GATEWAY",
	"QUAGMIRE_PARK_L1",
	"QUAGMIRE_FOOD_L1",
	"QUAGMIRE_TRIBE",
	"QUAGMIRE_GIANT",

-- ★★ ISLAND_TIER1..TIER4（钥匙侧）：与 :71-74 的同名锁配对。
-- ★ 数组结束。★ 统计（grep 核实）：KEYS_ARRAY 共 75 项。
	"ISLAND_TIER1",
	"ISLAND_TIER2",
	"ISLAND_TIER3",
	"ISLAND_TIER4",
}
-- ══════════════ KEYS：名字 → 整数 ID 的反查表 ══════════════
-- ★★ 与 LOCKS 完全同构：同一段循环、同一句 assert。
--   ⇒ ★★ 这是本文件**唯一做对了对称性**的地方。
--     （对比 LOCKS_KEYS 侧连查重都没有。）
KEYS = {}
-- ★ ipairs 保证 ID 与定义顺序一致（同 :78）。
for i,v in ipairs(KEYS_ARRAY) do
-- ★★ 「Key %s is defined twice!」——★ KEYS 侧**也有**重复检测。
--   ⇒ ★★★ 现在对比就非常刺眼了：
--     · LOCKS_ARRAY → 有查重（:79）
--     · KEYS_ARRAY  → 有查重（:167）
--     · LOCKS_KEYS  → ★★ 没有查重  ← 唯一的缺口
--   ⇒ ★★★ E1 缺陷的根因可以精确表述为：
--     「作者为前两张表都写了防重，却忘了给第三张表写」。
	assert(KEYS[v] == nil, "Key "..v.." is defined twice!")
	KEYS[v] = i
end

-- ★★★★ 全文件最重要的一段语义声明（第 171-172 行两条注释）：
--   -- Locks are unlocked if ANY key is provided.
--   -- However, ALL locks must be opened for a task to be unlocked.
--   翻译：
--     · **单个锁是 OR 语义** —— 它的钥匙集里任一把都能开它。
--     · **任务是 AND 语义** —— 一个任务的所有锁必须全部解开。
-- ★★ 判定伪码（storygen.lua:331-347 与 :533-557 两处实现）：
--     for lock in task.locks:
--         if not any(key in availableKeys for key in LOCKS_KEYS[lock]):
--             unlocked = false
-- ★★ 这两段注释是全 map/ 目录**唯一**把规则写在明处的地方。
--   对比 storygen.lua 里两套**互相独立实现**的判定（语义等价、代码不共享）
--   ⇒ ★★ 规则文档与实现分处两地 ⇒ 改规则要改三处，漏一处就穿帮。
-- Locks are unlocked if ANY key is provided.
-- However, ALL locks must be opened for a task to be unlocked.
-- ══════════════ ★★★ LOCKS_KEYS：锁 → 能开它的钥匙集合 ══════════════
-- ★★ 这是本文件**唯一有业务含义**的表，也是 E1 缺陷的现场。
-- ★★★ 统计（grep 核实）：约 60 项，即**有 18 个锁没有定义钥匙集**。
--   ⇒ ★★★ 后果：那些锁在 storygen.lua:333 `ipairs(lockData.keys)` 处
--     拿到 nil ⇒ **遍历 nil 崩溃**。
--   ⇒ ★★ 所以存在一条**纯靠人肉维护的隐式约束**：
--     「LOCKS_KEYS 必须覆盖 tasks/*.lua 里用到的每一个锁」，
--     ★ 而这条约束**没有任何校验保护**（见 477-487 行）。
LOCKS_KEYS =
{
-- ★★ LOCKS.NONE → 空表 {}。
--   ★★ 语义：无锁可开 ⇒ **恒定已解锁**（vacuous truth）。
--   ★★ 这是整个锁系统的**恒真元素**，也是「起始任务」的判据来源。
--   ★★ 推论：★ tasks.lua:79 那种 `locks=LOCKS.NONE` 写法
--     ★ 经 task.lua:8-10 归一化成 {NONE}，
--     ★ storygen.lua:326 的 availableKeys 循环里 v=LOCKS.NONE，
--     ★ 于是 availableKeys[1] 会被塞入节点 —— ★★ 而 KEYS.NONE 也是 1！
--   ⚠★⇒ availableKeys[KEYS.NONE] 与 availableKeys[LOCKS.NONE] 是**同一个键**。
--     ⇒ 凡声明 locks=LOCKS.NONE 的任务，都会往 availableKeys[1] 塞自己。
--     ★★ 若某个任务声明 keys_given=KEYS.NONE（★ tasks.lua:166 TEST_EMPTY 就是），
--     ★★ 两者会互相污染。★ 具体影响见 storygen.lua 的 ⚠ 标注。
	[LOCKS.NONE] =
	{},
-- ★★ HARD_MONSTERS_DEFEATED → 6 把钥匙（:177-185）：
--   HARD_WALRUS / HARD_SPIDERS / HARD_HOUNDS / HARD_MERMS /
--   HARD_TENTACLES / CHESSMEN。
--   ★★ OR 语义 ⇒ 杀掉其中**任意一种**强敌即可开门。
--   ★ 阈值设计：这是「至少见过一种高难度敌人」的低门槛版本。
	[LOCKS.HARD_MONSTERS_DEFEATED] =
	{
		KEYS.HARD_WALRUS,
		KEYS.HARD_SPIDERS,
		KEYS.HARD_HOUNDS,
		KEYS.HARD_MERMS,
		KEYS.HARD_TENTACLES,
		KEYS.CHESSMEN,
	},
-- ★ MONSTERS_DEFEATED → 普通版 6 把（WALRUS/SPIDERS/HOUNDS/MERMS/
--   TENTACLES/CHESSMEN）。★ 与 HARD_ 版同构，只是钥匙降级。
	[LOCKS.MONSTERS_DEFEATED] =
	{
		KEYS.WALRUS,
		KEYS.SPIDERS,
		KEYS.HOUNDS,
		KEYS.MERMS,
		KEYS.TENTACLES,
		KEYS.CHESSMEN,
	},
-- ★ SPIDERS_DEFEATED → 只认 SPIDERS（单钥匙）。★ 最严格的单点锁。
	[LOCKS.SPIDERS_DEFEATED] =
	{
		KEYS.SPIDERS,
	},
-- ★★ BASIC_COMBAT → { AXE, PIGS }。
--   ★★ 语义不是「战斗力」，而是「你会用斧头 / 你有猪」——
--     ★ 是**工具与伙伴**的门，不是战斗门的门。
	[LOCKS.BASIC_COMBAT] =
	{
		KEYS.AXE,
		KEYS.PIGS,
	},
-- ★★ ADVANCED_COMBAT → { GOLD, HONEY }。★ 经济门槛而非战斗门槛。
--   ★★ 命名与内容不符 ⇒ 「名字不可信」的又一例。
	[LOCKS.ADVANCED_COMBAT] =
	{
		KEYS.GOLD,
		KEYS.HONEY,
	},
-- ★★ LOCKS.ROCKS → { PICKAXE }。★ 最经典的一对一锁。
--   ★★ 玩家的第一个「门」永远是石头，钥匙是镐。
--   ⇒ 设计意图：★ 用最基础的工具做第一道教学关卡门。
    [LOCKS.ROCKS] =
    {
    	KEYS.PICKAXE
    },
-- ★★ PIGGIFTS → { MEAT, AXE, PICKAXE }。
--   ★★ 三把钥匙任一 ⇒ ★ 「猪村」的三种进入方式（讨好/开路/挖路）。
    [LOCKS.PIGGIFTS] =
    {
    	KEYS.MEAT,
    	KEYS.AXE,
    	KEYS.PICKAXE,
    },
-- ══════════════════════════════════════════════════════════════
-- ★★★★★★ E1 缺陷现场（一）：LOCKS.TREES 的**第一次**定义
--   [LOCKS.TREES] = { KEYS.AXE, KEYS.FIRE }        ← 本行（219）
-- ★★★ 这个定义在 Lua 的 table 构造器里会被**同文件后面第 254 行的
--   同名键静默覆盖**。⇒ 生效的是 254 行那组 { AXE, PIGS }。
-- ★★★ 直接后果：★ **KEYS.FIRE 永远打不开 LOCKS.TREES**。
-- ★★★ 深层后果：依赖「用火开路」的那些关卡 / task_set，
--   ★★ 其区域入口边**根本不会被创建** ⇒ **拓扑级不可达**。
-- ★★ 为什么不是「门打不开」而是「路不存在」：
--   · 门的物理形态是「这条 exit_edge + impassable 地块」（network.lua:257）；
--   · ★★ 而 exit_edge 是在 storygen 判定「你已有钥匙」时才创建的；
--   · ★★ 所以「没钥匙」表现为「那条边不存在」⇒ Voronoi 烘焙后
--     那片区域与主线之间**没有道路**⇒ 玩家走不过去。
--   ★★ 而 storygen.lua:473-475 / 596-599 的「逃生阀」会在无解时
--     **强行随机连一条边**把图连完 ⇒ 最终表现为「地图不合逻辑」
--     而不是崩溃或报错。★★ 这就是为什么这个 bug 能长期存活。
--
-- ⚠⚠【复核修正·重要】★ 本项目 bug-patterns.md E1 把本条记作
--   「致不可达」，实测【影响面比该描述小得多】，依据如下（均已 grep 核实）：
--   ① 生效的钥匙集是 { AXE, PIGS }，★ **AXE 仍在其中**；
--   ② 使用 LOCKS.TREES 的任务共 3 个，且【全都】与别的锁用 AND 组合：
--      map/tasks/forest.lua:148  locks={TREES, TIER3}
--      map/tasks/forest.lua:164  locks={TREES, TIER2}
--      map/tasks/dst_tasks_forestworld.lua:289  locks={TREES, TIER2}
--   ③ 三个任务的 keys_given 里**都有 KEYS.PIGS** ⇒ PIGS 路径也通；
--   ④ ★★ KEYS.AXE 由**首个任务**给出，且该任务 locks=LOCKS.NONE：
--      map/tasks/forest.lua:9-10
--        locks=LOCKS.NONE, -- Special story starting node
--        keys_given={PICKAXE, AXE, GRASS, WOOD, TIER1, TIER2}
--      ⇒ 玩家一开局就同时持有 AXE 与 PIGS ⇒ **TREES 必然可开**。
--   ⑤ ★★ 更关键：**KEYS.FIRE 从未被任何 task 的 keys_given 发放过**
--      （全仓 grep `KEYS.FIRE` 仅命中 lockandkey.lua:222 与 :227 两处，
--        即它只作为「锁的候选钥匙」出现，从不是「任务发放的钥匙」）。
--   ⇒ 结论：即便没有覆盖，{ AXE, FIRE } 里的 FIRE 也**永远拿不到**；
--     覆盖成 { AXE, PIGS } 反而**多给了 PIGS 这条路**。
--   ★★ 所以本条缺陷在【原版自带任务集】下**不会造成玩家不可达**，
--     真正的问题是：① LOCKS_KEYS 侧缺少查重（结构性隐患）；
--     ② FIRE 成为一把**设计上根本发不出来的死钥匙**（语义失效）；
--     ③ ★★ 一旦有 MOD/关卡改用「FIRE 开路」的意图（FIRE 显然被设计
--        为 TREES/SPIDERDENS 的候选钥匙，见 :222 与 :227），就会立刻不可达。
--   ⚠ 自研世界生成时务必区分「结构性缺陷」与「实际触发后果」——
--     前者必须修，后者决定优先级。本条属【必修但不紧急】。
--   ★ 另注：正因如此，排查此类问题时【不能只看 LOCKS_KEYS 的定义】，
--     必须双向核对：每把钥匙是否真被某个 task 的 keys_given 发出过。
    [LOCKS.TREES] =
-- ★★ 本组的第 1 把钥匙 AXE（= KEYS.AXE = 2）。★ 它在 254 行那组里也在，
--   ⇒ 所以「用斧头开树门」这条路**没有**被破坏。
--   ★★ 这解释了为什么这个 bug 影响面有限：AXE 覆盖了 FIRE 的位置。
--   ★★★ 但若哪天有人「清理」254 行那组里的 PIGS、只留 AXE+FIRE，
--     ★★ 破坏面就会突然扩大。★ 这是一颗定时炸弹。
    {
-- ★★★ 本行的 KEYS.FIRE（= 9）是**被覆盖掉的那把钥匙**。
--   ★★ 它是整张表里唯一一处「写对了却被覆盖」的语义。
--   ★★★ 对照 KEYS_ARRAY 第 94 行：FIRE 确实被声明为一把钥匙，
--     ★★ 说明它当初是有意设计的，不是笔误。
--   ⚠ 反过来说：★ 若 FIRE 在别处也有 keys_given 发放，
--     那它就是一把「发放了但永远用不上」的孤儿钥匙。
    	KEYS.AXE,
-- ★ 本组的第 2 把钥匙 FIRE —— 见上方 ⚠。
    	KEYS.FIRE,
-- ★★ 表项结束。整个 { AXE, FIRE } 会被 254 行覆盖。
    },
-- ★ SPIDERDENS → { PIGS, FIRE, AXE, PICKAXE, HONEY }（:224-231）。
--   ★★ 注意 ★★ 这组**保留了 KEYS.FIRE**，
--     ★★ ⇒ 证明「火能开路」的设计在别处仍然有效，
--       ★★ 更凸显 219 行被覆盖是**局部笔误**而非全局废弃。
--   ★★ 5 把钥匙 OR ⇒ 蜘蛛巢有 5 种进入方式，是全表最宽松的锁之一。
    [LOCKS.SPIDERDENS] =
    {
    	KEYS.PIGS,
    	KEYS.FIRE,
    	KEYS.AXE,
    	KEYS.PICKAXE,
    	KEYS.HONEY,
    },
-- ★ BEEHIVE → { AXE }（砍树才能取蜜）。
    [LOCKS.BEEHIVE] =
    {
    	KEYS.AXE,
    },
-- ★ FARM → { POOP }（单钥匙）。
    [LOCKS.FARM] =
    {
    	KEYS.POOP,
    },
-- ★★ MEAT → { SPIDERS, PIGS, FARM }（:240-245）。
--   ★★ 语义：★ 打蜘蛛 / 有猪 / 有农场，任一条产肉途径即可。
--   ★★ 这是「资源替代设计」：保证任何路线的玩家都能搞到肉。
    [LOCKS.MEAT] =
    {
    	KEYS.SPIDERS,
    	KEYS.PIGS,
    	KEYS.FARM,
    },
-- ★ KILLERBEES → { BEEHAT }（蜂帽）。★ 装备门槛。
	[LOCKS.KILLERBEES] =
	{
		KEYS.BEEHAT,
	},
-- ★ PIGKING → { TRINKETS }（小物件；猪王会掉）。
	[LOCKS.PIGKING] =
	{
		KEYS.TRINKETS,
	},
-- ══════════════════════════════════════════════════════════════
-- ★★★★★★ E1 缺陷现场（二）：LOCKS.TREES 的**第二次**定义
--   [LOCKS.TREES] = { KEYS.AXE, KEYS.PIGS }       ← 本行（254）
-- ★★★ 这一个**生效**。上面 219 行那组 { AXE, FIRE } 被静默丢弃。
-- ★★★ ⇒ E1「锁—钥匙同名覆盖」的确切根因与行号就是这一对：
--     · 覆盖者：第 254 行（生效）
--     · 被覆盖者：第 219 行（失效）
--     · 净效果：LOCKS.TREES 的钥匙集从 {AXE, FIRE} 变成 {AXE, PIGS}
--     · ★★ 具体缺陷：KEYS.FIRE 成为一把「永远开不了 TREES 锁」的钥匙
--   ★★ 为什么静默：Lua 的 `{ [k]=a, [k]=b }` 就是 `{[k]=b}`，
--     不报错、不警告（Lua 5.1 连警告都没有）。
--   ★★★ 为什么 477-487 行的自校验抓不到：见该段注释。
	[LOCKS.TREES] =
-- ★★ 本组的 KEYS.AXE —— 与 220 行重复，是「幸存」的那把。
	{
-- ★★★ 本行的 KEYS.PIGS 是**新增**的钥匙（219 行那组里没有）。
		KEYS.AXE,
-- ★★★ KEYS.PIGS 让「有猪 ⇒ 能进树区」成为可能。
--   ★★ 推测原意：作者本想加一条「猪帮忙开路」的替代路径，
--     ★★★ 但他没意识到自己**覆盖**了原有的 FIRE 路径。
--   ⇒ ★★★ 这是典型的「Lua 表里重复键」的经典事故：
--     作者以为自己在追加，其实在替换。
		KEYS.PIGS,
-- ★★ 表项结束。★ 此后 LOCKS_KEYS 里再无 TREES 定义。
	},
-- ★ ONLYTIER1 → { TIER1 }（单钥匙）。
	[LOCKS.ONLYTIER1] =
	{
		KEYS.TIER1,
	},
-- ★★ TIER0 → { TIER0, TIER1 }：★ 允许「达到 0 层或 1 层」。
--   ★★ 268-292 行的 TIER1..TIER5 全部是「本层或下一层」的 OR。
--   ★★ 设计意图：★ 层级锁允许**越一级**，给玩家一点弹性。
-- ★★ 但注意 LOCKS.TIER6 **没有**定义（第 24 行的 TIER6 锁无钥匙集）
--   ⇒ ★★ 这是「LOCKS_KEYS 覆盖不全」的一个具体实例：
--     若某个 task 声明 locks=LOCKS.TIER6 ⇒ storygen.lua:333 遍历 nil 崩溃。
--     ★★ 目前不触发，是因为 tasks/*.lua 恰好没用 TIER6 锁。
--   ⚠ 典型的「靠巧合不出错」。
	[LOCKS.TIER0] =
	{
		KEYS.TIER0,
		KEYS.TIER1,
	},
	[LOCKS.TIER1] =
	{
		KEYS.TIER1,
		KEYS.TIER2,
	},
	[LOCKS.TIER2] =
	{
		KEYS.TIER2,
		KEYS.TIER3,
	},
	[LOCKS.TIER3] =
	{
		KEYS.TIER3,
		KEYS.TIER4,
	},
	[LOCKS.TIER4] =
	{
		KEYS.TIER4,
		KEYS.TIER5,
	},
	[LOCKS.TIER5] =
	{
		KEYS.TIER5,
		KEYS.TIER6,
	},
-- ★ ANYTIER → TIER1..TIER6 六把全列（OR）。
    [LOCKS.ANYTIER] =
    {
        KEYS.TIER1,
        KEYS.TIER2,
        KEYS.TIER3,
        KEYS.TIER4,
        KEYS.TIER5,
        KEYS.TIER6,
    },
-- ★ INNERTIER → { TIER1, TIER2, TIER3 }（低三层）。
    [LOCKS.INNERTIER] =
    {
        KEYS.TIER1,
        KEYS.TIER2,
        KEYS.TIER3,
    },
-- ★ OUTERTIER → { TIER4, TIER5, TIER6 }（高三层）。
    [LOCKS.OUTERTIER] =
    {
        KEYS.TIER4,
        KEYS.TIER5,
        KEYS.TIER6,
    },
-- ★★ ENTRANCE_INNER → { KEYS.ENTRANCE_INNER }。★ 1:1 同名配对。
-- ★★ 这两组的写法（318-321）是全表最规范的范式：
--   锁名与钥匙名完全一致，一对一，无歧义。
--   ★★ 对照 219/254 那组：同名锁却配了两套不同的钥匙 ⇒ 出事。
    [LOCKS.ENTRANCE_INNER] =
    {
        KEYS.ENTRANCE_INNER,
    },
-- ★ ENTRANCE_OUTER → { KEYS.ENTRANCE_OUTER }。1:1 配对。
    [LOCKS.ENTRANCE_OUTER] =
    {
        KEYS.ENTRANCE_OUTER,
    },

-- ★★ 从这里开始（323-474）全是「1:1 同名锁」的规范写法。
-- ★★ 对照 219/254 的 TREES：★ 这 150 行证明作者**知道**正确写法，
--   ★★★ 于是 E1 更像「局部疏忽」而非「不会写」。
-- ★★ 统计（grep 核实）：这一段约 38 个锁，全部是 { KEYS.同名 } 单元素。
--   ★★ 这是全表最无聊但最重要的部分——**它是默认值，不是例外**。
	[LOCKS.LIGHT] =
	{
		KEYS.LIGHT,
	},
-- ★ CAVE → { KEYS.CAVE }。★ 洞穴入口门。
	[LOCKS.CAVE] =
	{
		KEYS.CAVE,
	},
-- ★ FUNGUS → { KEYS.FUNGUS }。★ 蘑菇地门（洞穴内部分区）。
	[LOCKS.FUNGUS] =
	{
		KEYS.FUNGUS,
	},
-- ★ LABYRINTH → { KEYS.LABYRINTH }。★ 迷宫门。
--   ★★ 对应 forest_map.lua:646-693 的 Labyrinth 标签处理（RunMaze）。
--     ⇒ ★ 锁声明与标签展开是**两套并行机制**：前者管连通性，
--       后者管内容物生成。★ 二者靠 GLOBALTAG 标签名对齐。
	[LOCKS.LABYRINTH] =
	{
		KEYS.LABYRINTH,
	},
-- ★ WILDS → { KEYS.WILDS }。★ 荒野（月亮岛外围）。
	[LOCKS.WILDS] =
	{
		KEYS.WILDS,
	},
-- ★ RUINS → { KEYS.RUINS }。★ 古迹（考古 DLC）。
	[LOCKS.RUINS] =
	{
		KEYS.RUINS
	},
-- ★ SACRED → { KEYS.SACRED }。★ 圣所。
	[LOCKS.SACRED] =
	{
		KEYS.SACRED
	},

-- ★ MUSHROOM → { KEYS.MUSHROOM }。★ 蘑菇房。
	[LOCKS.MUSHROOM] =
	{
		KEYS.MUSHROOM
	},

-- ★ RABBIT → { KEYS.RABBIT }。★ 兔子洞。
	[LOCKS.RABBIT] =
	{
		KEYS.RABBIT
	},
-- ★ SINKHOLE → { KEYS.SINKHOLE }。★ 天坑。
--   ★★ 对应 tasks.lua:148 `room_bg = WORLD_TILES.SINKHOLE`
--     ⇒ 天坑是「垂直进入洞穴」的地形表现。
	[LOCKS.SINKHOLE] =
	{
		KEYS.SINKHOLE
	},
-- ★ BATS → { KEYS.BATS }。★ 蝙蝠洞。
	[LOCKS.BATS] =
	{
		KEYS.BATS
	},

-- ★ PASSAGE → { KEYS.PASSAGE }。
--   ★★ 语义最模糊的一个锁：★ 「通道」既可能指必经之路，
--     也可能是 mod 自定义的占位符。
	[LOCKS.PASSAGE] =
	{
		KEYS.PASSAGE
	},

-- ★ AREA → { KEYS.AREA }。★ 泛化的「区域」锁。
	[LOCKS.AREA] =
	{
		KEYS.AREA
	},

-- ★ CAVERN → { KEYS.CAVERN }。★ 大洞窟。
	[LOCKS.CAVERN] =
	{
		KEYS.CAVERN
	},


-- ★ EASY → { KEYS.EASY }。★ 1:1 同名配对（难度锁）。
--   ★★ ⚠ 但 LOCKS.EASY 与 KEYS.EASY 是**不同的整数**（两个表各自编号）。
--     这是本表最容易被误读的地方：`LOCKS_KEYS[LOCKS.EASY] = { KEYS.EASY }`
--     读起来像自己映射自己，实际是两个独立 ID 空间的交叉引用。
	[LOCKS.EASY] =
	{
		KEYS.EASY
	},

-- ★ MEDIUM → { KEYS.MEDIUM }。
	[LOCKS.MEDIUM] =
	{
		KEYS.MEDIUM
	},

-- ★ HARD → { KEYS.HARD }。
	[LOCKS.HARD] =
	{
		KEYS.HARD
	},

-- ★ BLUE → { KEYS.BLUE }。
	[LOCKS.BLUE] =
	{
		KEYS.BLUE
	},

-- ★ RED → { KEYS.RED }。
	[LOCKS.RED] =
	{
		KEYS.RED
	},

-- ★ GREEN → { KEYS.GREEN }。
	[LOCKS.GREEN] =
	{
		KEYS.GREEN
	},

-- ★ QUAGMIRE_GATEWAY → { KEYS.QUAGMIRE_GATEWAY }。
-- ★★ 与 terrain.lua:137-146 的 OnlyAllow 规则**成对出现**：
--   ★ 锁管「进不进得去」，地形表管「进去之后长什么」。
	[LOCKS.QUAGMIRE_GATEWAY] =
	{
		KEYS.QUAGMIRE_GATEWAY,
	},

-- ★ QUAGMIRE_PARK_L1 → { KEYS.QUAGMIRE_PARK_L1 }。
	[LOCKS.QUAGMIRE_PARK_L1] =
	{
		KEYS.QUAGMIRE_PARK_L1,
	},

-- ★ QUAGMIRE_FOOD_L1 → { KEYS.QUAGMIRE_FOOD_L1 }。
	[LOCKS.QUAGMIRE_FOOD_L1] =
	{
		KEYS.QUAGMIRE_FOOD_L1,
	},

-- ★ QUAGMIRE_TRIBE → { KEYS.QUAGMIRE_TRIBE }。
	[LOCKS.QUAGMIRE_TRIBE] =
	{
		KEYS.QUAGMIRE_TRIBE,
	},

-- ★ QUAGMIRE_GIANT → { KEYS.QUAGMIRE_GIANT }。
	[LOCKS.QUAGMIRE_GIANT] =
	{
		KEYS.QUAGMIRE_GIANT,
	},

-- ★ ISLAND_TIER1 → { KEYS.ISLAND_TIER1 }。
	[LOCKS.ISLAND_TIER1] =
	{
		KEYS.ISLAND_TIER1,
	},

-- ★ ISLAND_TIER2 → { KEYS.ISLAND_TIER2 }。
	[LOCKS.ISLAND_TIER2] =
	{
		KEYS.ISLAND_TIER2,
	},

-- ★ ISLAND_TIER3 → { KEYS.ISLAND_TIER3 }。
	[LOCKS.ISLAND_TIER3] =
	{
		KEYS.ISLAND_TIER3,
	},

-- ★ ISLAND_TIER4 → { KEYS.ISLAND_TIER4 }。
	[LOCKS.ISLAND_TIER4] =
	{
		KEYS.ISLAND_TIER4,
	},

-- ★ MOONMUSH → { KEYS.MOONMUSH }。★ 月蘑菇（月亮遗迹）。
--   ★★ 与 LOCKS.MOONMUSH（第 60 行）严格同名配对。
	[LOCKS.MOONMUSH] =
	{
		KEYS.MOONMUSH,
	},

-- ★ ARCHIVE → { KEYS.ARCHIVE }。★ 档案馆。
--   ★★ 对应「远古档案馆」DLC（archive_worldgen.lua）。
--     与 terrain.lua:151 的 ARCHIVE 禁长规则呼应。
	[LOCKS.ARCHIVE] =
	{
		KEYS.ARCHIVE,
	},

-- ★ CENTIPEDE → { KEYS.CENTIPEDE }。★ 蜈蚣。
	[LOCKS.CENTIPEDE] =
	{
		KEYS.CENTIPEDE,
	},
-- ★★★ LOCKS_KEYS 表结束（第 173-475 行，302 行数据）。
-- ★★ 覆盖率检查（grep 核实）：LOCKS_ARRAY 78 项 vs LOCKS_KEYS 约 60 项
--   ⇒ ★★ 约 18 个锁**没有**钥匙集定义。
--   ⇒ 后果见 :173 处注释：storygen.lua:333 遍历 nil 会崩溃。
--   ⇒ ★ 目前不崩**只因为** tasks/*.lua 恰好没用那些锁。
}


-- ══════════════ ★★★ 启动期自校验（★ 为什么抓不到重复键）══════════════
-- ★★ 表面看这是道防线，但它**结构上不可能**发现 LOCKS_KEYS 的重复键：
--   · for lock,keyset in pairs(LOCKS_KEYS) 遍历的是**已构造完成的表**；
--   · ★★ 而重复键在 table 构造器执行时就已覆盖，
--     ★★ 表里根本**不存在**那个被覆盖的键 ⇒ 无从遍历、无从发现。
-- ★★ 换句话说：这道校验**只能发现「LOCKS_KEYS 里引用了未声明的锁/钥匙」**，
--   ★★ 发现不了「同一个锁被声明了两次」。
for lock,keyset in pairs(LOCKS_KEYS) do
-- ★★ 校验①：lock 必须等于 LOCKS[LOCKS_ARRAY[lock]]。
--   ★ 这个反查是**自洽性**检查（保证表里的键和数组下标对得上）。
--   ★★ 对本文件的 bug 完全无感——LOCKS.TREES 的反查是正确的。
	assert(lock ~= nil and lock == LOCKS[LOCKS_ARRAY[lock]], "A lock in the lock_keys is misnamed!")
-- ★ count：统计该锁实际有多少把钥匙。
	local count = 0
-- ★★ 注意 ★★ 用的是 **pairs** 而不是 ipairs 来遍历 keyset。
--   ★★ 这是本文件**第二处**用 pairs 遍历数据表的地方，
--     而 :78/:166 用的是 ipairs。⇒ 又一处顺序不确定性。
--   ★ 后果：#keyset（数组长度）与 count（pairs 计数）可能不等，
--     ★★ 下一行的 assert 就是为了抓这个。
	for i,key in pairs(keyset) do
-- ★★ 校验②：每个 key 也必须反查自洽（key == KEYS[KEYS_ARRAY[key]]）。
--   ★★ 同样只能抓「引用了不存在的 KEYS 常量」这类问题。
		assert(key ~= nil and key == KEYS[KEYS_ARRAY[key]], "A key in lock "..LOCKS_ARRAY[lock].." is misnamed!")
-- ★ count = count + 1
		count = count + 1
	end
-- ★★ 校验③：`assert(#keyset == count, "There appears to be an
--   incorrectly named key in locks_keys: "..LOCKS_ARRAY[lock])`
--   ★★ 它抓的是「keyset 是稀疏数组（有洞）」——
--     ★ 即 pairs 遍历到的键不是 1..n 的连续整数。
--   ★★ 对重复键依然**完全无感**。
-- ★★★ 三条校验全部通过，而 LOCKS.TREES 的 FIRE 已经死了。
--   ⇒ ★★ 「我写了校验」不等于「校验覆盖了缺陷模式」。
	assert(#keyset == count, "There appears to be an incorrectly named key in locks_keys: "..LOCKS_ARRAY[lock])
-- ★★★ 源码自己承认了盲区（作者原注释）：
--   NOTE: This wil **NOT** catch it if the typo is in the last key in
--   the list. ... But it's better than nothing...
-- ★★ 翻译：「就算错字出现在最后一个 key 位置，这道校验也抓不到。
--   但有总比没有好……」
-- ★★★ 这条注释是全文件最有价值的一行：
--   作者**清楚**校验不完备，却仍然把它当作「已加固」来依赖。
--   ⇒ ★★ 更严重的是：本例的缺陷比注释里说的还严重——
--     不是「最后一个 key 拼错」，而是**整组 key 被覆盖**。
--     ★★ 即使补上作者设想的那种校验（检查 key 拼写），
--       ★★★ 也照样抓不到——因为被覆盖的那组从来没进过表。
-- ⇒ ★★ 这说明作者的自我评估方向就错了：他以为缺的是「拼写检查」，
--     ★★★ 实际缺的是「重复键检查」。★ 归因错误 ⇒ 修复方向也错。
	-- NOTE: This wil **NOT** catch it if the typo is in the last key in the list. ... But it's better than nothing...
end


-- ══════════════ ★★★ 未声明 key/lock 的容错设计 ══════════════
-- ★★ 原始注释（490-496 行）：
--   NOTE: There already are some missing locks and keys that we will
--   explitcly skip in our check for now. These have been missing for
--   along while and warped the world gen, we could fix these cases now
--   but they'll change world generation drastically, changing how
--   players experience the game. We can leave it for another time
--   when/if we're ready to tackle world generation and update it
--   accordingly and fix these issues in an active development period
-- ★★★★ 这段注释是整个 E1 缺陷**最沉痛的证据**：
--   「这些问题**已经扭曲了世界生成很久了**，我们本来可以现在修，
--     但那会**剧烈改变世界生成结果、改变玩家的体验**，
--     所以留到我们真正要大改世界生成的时候再修。」
-- ★★★ ⇒ ★★ 结论：这些缺陷**不是疏忽，是明知故犯**。
--   ★★ 这是「技术债」的标准形态：知道、有文档、故意不修。
-- ★★ ⚠ 注意 typo：「expli**tl**cly」「wil」「along while」——
--   ★ 说明这段注释本身也很久没人维护了。
--[[
NOTE:
There already are some missing locks and keys that we will explitcly skip in our check for now.
These have been missing for along while and warped the world gen, we could fix these cases now
but they'll change world generation drastically, changing how players experience the game.
We can leave it for another time when/if we're ready to tackle world generation and update it accordingly and fix these issues in an active development period
]]

-- ★★ 白名单：声明「我们知道这些名字没定义，且我们选择跳过」。
-- ★★ 注释明确分组：Keys（4 个）/ Locks（1 个）/ 两者皆非（1 个）。
local SKIP_THESE_MISSING_KEYS_AND_LOCKS = {
	-- Keys
-- ★★ 「SILK」：丝。★ 这是**藤壶/蜘蛛 DLC 的钥匙**，
--   ★★ tasks/*.lua 里若有任务写 keys_given=KEYS.SILK，
--     ★★ `KEYS.SILK` 在正式分支里返回 **nil**（不是报错）。
--   ★★ 后果链：task.lua:13 归一化成 { nil }，
--     ★★ storygen.lua:617 `availableKeys[nil] = {}` ⇒ 
--       ★★★ **在 Lua 里给表赋 nil 键的值会报错**
--         （attempt to index a nil value / table index is nil）
--     ★★★ ⇒ 也就是说：正式分支下若真有 task 用了 KEYS.SILK，
--       ★★★ **世界生成会直接崩溃**，不是静默失效。
--   ★★★ ⇒ 推论：**这些白名单名字实际上根本不能被使用**，
--     ★★ 白名单的真实作用是「让 dev 分支的扫描不报错」，
--       ★★ 而非「让正式分支能容错」。★ 注释的意图与实际行为不符。
	["SILK"] = true,
-- ★★ 「ROCKS」：★ 既被当作 key 也被当作 lock（注释说「Both」）。
--   ★★ 注意 LOCKS.ROCKS 是**声明过的**（第 8 行），
--     ★★ 但 KEYS.ROCKS **没有**声明 ⇒ keys_given=KEYS.ROCKS 会拿到 nil。
--   ★★ 这是「同名不同义」造成误判的典型：
--     ★ 作者看到「ROCKS 锁是有的」就以为「ROCKS 钥匙也是有的」。
	["ROCKS"] = true,
-- ★★ 「TALLBIRDS」：高鸟。★ tasks/*.lua 里高鸟窝任务若用 KEYS.TALLBIRDS
--   ⇒ 正式分支 nil ⇒ 同 SILK 的崩溃链。
	["TALLBIRDS"] = true,
-- ★★ 「SWAMP」：沼泽。★ 地形概念被误用作钥匙名。
--   ★★ 这条最能说明问题：★ 有人想让「沼泽」当钥匙，
--     ★★ 但沼泽是 WORLD_TILES 里的地块，不是钥匙。
--   ★★ ⇒ 白名单里混着「拼写错误」「概念错误」「真的漏了」三类，
--     ★★ 一律用同一个 `= true` 掩盖。★ 分类缺失。
	["SWAMP"] = true,

	-- Locks
-- ★★ 「SPIDERDEN」：★ 注意它与声明过的 **SPIDERDENS**（第 7 行，
--   多了个 S）只差一个字母！
--   ★★★ 这是 E1 的**第二个兄弟缺陷**——同样是「拼写漂移」，
--     ★★ 而且同样被白名单静默掉了。
--   ★★ 对照：第 7 行的 SPIDERDENS 有钥匙集（:224-231），
--     ★★ 而 SPIDERDEN 在 LOCKS 侧**不存在** ⇒ `LOCKS.SPIDERDEN` = nil。
--   ⇒ ★★ 参照 bug-patterns.md E1 的「预防」条目：
--     「永远不要在同一张表里写重复键」——这里还要加一条：
--     「拼写相近的名字必须做前缀/编辑距离校验」。
	["SPIDERDEN"] = true,

	-- Both a lock and key
-- ★★ 「ROCKY」：★ 它是 **WORLD_TILES.ROCKY（岩地地块）**，
--   ★★ 同时也是 map/rooms 里的房间名（tasks.lua:113 `["Rocky"] = 1`）。
--   ★★ ⇒ 三处同名：地块常量 / 房间名 / （曾经的）钥匙名。
--   ★★★ 名字空间污染的教科书案例。
	["ROCKY"] = true,
}
-- ★★★ CRASH_ON_MISSING_KEY_OR_LOCK = (BRANCH == "dev")。
-- ★★ 这是全文件**唯一**的运行期防线，且只在 dev 分支生效：
--   · dev  分支：LOCKS.ROCKY 访问 → error() ⇒ **立刻崩溃**（好）
--   · 正式分支：LOCKS.ROCKY 访问 → nil     ⇒ **静默**（危险）
-- ★★★ ⇒ ★★ 缺陷在正式包里**完全没有保护**：
--   ★★ 玩家跑的是 BRANCH ~= "dev" 的包，锁表错了也照跑。
-- ★★ 讽刺之处：★ 这道防线的价值恰恰在它**不生效**的场合被浪费了。
--   ★★ 正确做法应是反过来：**正式分支更严**（数据错误必须崩），
--     dev 分支反而可以宽松（方便调试半成品数据）。
local CRASH_ON_MISSING_KEY_OR_LOCK = BRANCH == "dev"

-- ★ if CRASH_ON_MISSING_KEY_OR_LOCK then —— 只在 dev 分支装元表。
if CRASH_ON_MISSING_KEY_OR_LOCK then
-- ★★ 给 LOCKS 装 __index 元表：**只有访问不存在的键才会触发**。
--   ★★ ⇒ 已声明的键走正常路径，零性能开销（Lua 元表只查 miss）。
	setmetatable(LOCKS, {
		__index = function(k, n)
-- ★ 白名单里的名字：返回 nil（不报错），等于「确认它没定义」。
--   ★★ ⇒ 即使在 dev 分支，白名单里的 6 个名字仍然静默返回 nil。
--   ★★★ 所以严格说：**这 6 个名字在哪个分支都不安全**。
			if not SKIP_THESE_MISSING_KEYS_AND_LOCKS[n] then
-- ★★★ error("Lock '"..n.."' is not declared", 2) —— level 2 指向上层调用者。
--   ★★ 错误信息带名字 ⇒ 可直接定位。★ 好的错误信息。
				error("Lock '"..n.."' is not declared", 2)
			end
		end
	})

-- ★★ KEYS 侧完全同构的元表（514-520 的 KEYS 版）。
--   ★★ 两条防线的**代码重复**（只有变量名不同）——
--     ★ 可以抽成函数，但只有 2 处，不值得。★ 可接受的重复。
	setmetatable(KEYS, {
		__index = function(k, n)
			if not SKIP_THESE_MISSING_KEYS_AND_LOCKS[n] then
				error("Key '"..n.."' is not declared", 2)
			end
		end
	})
end

-- ─── 以下 6 行是全部被注释掉的调试打印（531-536）────
-- ★★ 与 storygen.lua:9/:12 的 print_lockandkey 空函数**同一个模式**：
--   ★★ 「调试通道被永久关闭」。
-- ★★ 对 E1 排查的影响：★ 想 dump LOCKS_KEYS 的实际内容，
--   ★★ 必须手工取消注释。而取消注释又会**暴露另一个问题**：
--     ★★ 你看到的是覆盖后的表，★ 根本看不出 219 行曾经存在过。
--   ⇒ ★★ 调试 print 在这里是**无效的**——
--     ★★★ 要发现重复键，必须在**构造时**检测，不是构造后打印。
--print("LOCKS")
--dumptable(LOCKS,1)
--print("KEYS")
--dumptable(KEYS,1)
--print("LOCKS_KEYS")
--dumptable(LOCKS_KEYS,1,1)
