-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：tuning.lua
-- 模块：数值源头 / 数值调优总表（Tuning Master Table）
-- 职责：定义全局表 TUNING —— 全项目**所有**可调数值的集中处。
--       游戏逻辑代码里几乎看不到裸数字，一切「手感参数」都写在这里，
--       由业务代码以 TUNING.XXX 的形式读取。
--
-- 【为什么要有这张表】
--   数值与逻辑分离带来三个好处：
--     1. 策划改数值不必碰逻辑代码，降低误引入 bug 的概率；
--     2. 数值可被模组在运行时覆盖（见文件末尾的 setmetatable 段）；
--     3. 数值可被存档与联机同步（所有端都 require 同一份文件，
--        天然保证「服务器说 100 就是 100」，见 networking.lua 的版本校验）。
--
-- 【规模】9581 行 / 4202 个顶层键。
--       其中约 88% 是「某个生物/物品的某个属性」这样的数据行，
--       对这些行逐行加注释既无必要也无价值。
--       因此本注释版的重心放在三处：
--         ★ 文件头的「分区导航表」—— 讲清这张 9581 行巨表的组织方式
--         ★ 「归一化 vs 绝对值」—— 本项目最关键的一条数值设计洞察
--         ★ 分区边界与代表性条目—— 每区挑最能说明设计意图的深讲
--
-- 【关键符号】
--   TUNING, TUNING_MODIFIERS, ORIGINAL_TUNING,
--   AddTuningModifier, Tune
--
-- 【运行时时间基】（第 19-29 行，全文件一切时间数值的源头）
--   seg_time       = 30秒    —— 一「段」。一整天被切成 16 段。
--   day_time       = 300 秒  = seg_time * 10（白天 10 段）
--   dusk_time      = 120 秒  = seg_time * 4（黄昏 4 段）
--   night_time     = 60 秒   = seg_time * 2（夜晚 2 段）
--   total_day_time = 480 秒  = seg_time * 16（完整昼夜 = 8 分钟现实时间）
--
--   ★ 校验恒等式：day_time + dusk_time + night_time == total_day_time
--     即 300 + 120 + 60 == 480 ✓
--     这说明「天」与「昼夜」是两种不同的时长口径，见下方「三种分母」。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：constants.lua（常量/枚举）, tuning_override.lua（世界区域覆盖钩子）,
--           worldsettings_overrides.lua（难度覆写，是唯一正规的改数值入口）,
--           components/sanity.lua（理智）, components/health.lua（生命）,
--           components/hunger.lua（饥饿）, components/worldstate.lua（季节推进）
-- ============================================================
-- ★★★ 【分区导航表】 —— tuning.lua 的整体组织方式 ★★★
--
-- 【一句话概括组织方式】
--   这张表**不是**按「生存/战斗/温度/农业/驯化」这样的功能主题分区的。
--   它的真实组织方式是**三层混合**：
--     (1) 顶层约 2200 行是「核心机制数值」，按设计域聚集（时序、战斗、生物、物品）；
--     (2) 其后是「按角色/按 DLC/按赛季事件」逐批追加的新数值，
--         新内容一律**追加到表尾**，从不插入到中间的语义位置；
--     (3) 最后约 190 行是嵌套子表（SKILLS / GESTALT / CARATSHRINE 等）。
--
--   这带来一个必须知道的实操结论：
--     ★ **按行号区间找数值是不可靠的。** 例如「阿比盖尔的所有数值」散落在
--       4000-4200、4600-4900、5600 附近多处；「WX78」更是横跨 140 / 6410-6660 /
--       7300-7600 / 9200-9450 四个区间。正确做法是**按变量名全局搜索**，
--       例如 grep -n 'WX78_' tuning.lua。
--
--【分区】导航表（★ = 重点分区，注释密度最高）
-- ═══════════════════════════════════════════════════════════════
--  #分区名                 行号区间    行数主要管什么
-- ═══════════════════════════════════════════════════════════════
--  0 引导与时间基            1-51        require、三个全局表、Tune() 函数头、
--                                        ★ seg_time/day_time/total_day_time 起源
--  1 ★核心机制 · 时序与全局   52-199      MODS_QUERY_TIME、STACK_SIZE、存档频率、
--                                        玩家基础属性 WILSON_*、控制器参数
--  2 ★核心机制 · 战斗与工具   200-399     护盾/弹药耐久、钓鱼竿参数、
--                                        DEFAULT_ATTACK_RANGE 等通用战斗手感
--  3 载具与矿车（浮空时代）   400-504      SADDLE_*、矿车 MOVESPEED、乘骑速度
--  4 ★生物 · 猪牛鹿等地面群   505-800      PIG / WALRUS / DEER / KLAUS / BEEFALO /
--                                        PENGUIN / GHOST / LIGHTNING_GOAT
--  5 ★生物 · 敌对与夜间       801-1262     SPIDER / HOUND / BAT / FROG / TENTACLE /
--                                        破局生物，含大量「阶段化」参数表
--  6 洞穴生物与夜间威胁       1263-1599    TOADSTOOL 变体前置、NIGHT creatures、
--                                        GRUE 系、洞穴专属数值
--  7 资源与采集               1600-1799    浆果/花朵/蘑菇/矿石再生周期、
--                                        ★ 大量 {base, random} 生长表
--  8 ★物品 · 耐久与护甲       1800-1999    ARMOR_* 全表、PERISH_* 腐坏时间、
--                                        蛛后、修复/耐久消耗
--  9 ★生存三围与治疗         2000-2135    SANITY_* / PERISH_* / HEALING_* / REPAIR_*、
--                                        ★ 卡路里表（按食物类型分档）
-- 10 ★★ 理智 · 归一化示范区   2136-2247    ★★ 本文件最重要的设计范式区。
--                                        SANITYAURA / DAPPERNESS / CRAZINESS
--                                        全部写成 100/(分母*N)，见下方详解。
-- 11 ★★ 温度 · 湿度 · 作物   2248-2400    ★★ INSULATION_*（保暖）、
--                                        OVERHEAT_TEMP / MIN_ENTITY_TEMP、
--                                        作物枯萎与返青温度阈值、
--                                        DAY_HEAT / NIGHT_COLD 昼夜温差
-- 12 蘑菇与蜜蜂               2401-2599    TOADSTOOL 等级/阶段表、BEEQUEEN、
--                                        BEEGUARD、DRAGONFLY、MONKEY
-- 13 角色 · 温蒂/沃尔夫等     2600-2830    WOLFGANG 力量、WENDY 理智倍率、
--                                        角色专属资源（WONKEY、SHADOWLUMBER）
-- 14 蜡月与三重、阿比盖尔     2831-3199    Waxwell 施法代价、猫丛、
--                                        METEOR 陨石雨、WARG 战争机器、
--                                        MOUSEHACK 露馅半径
-- 15 洞穴深处与 STALKER       3200-3400    STALKER（洞穴 Boss）血量与阶段、
--                                        WAVE / DISEASE、ANTLION
-- 16 季节筹备与角色专属       3401-3760    WINTERS_FEAST、BERNIE、WINONA、
--                                        WILLOW、HOTSPRING
-- 17 ★农业与农业设备         3761-3900    ★ WILLOW 火龙草、岩石果实、
--                                        FARM_* 耕种参数、葡萄藤
-- 18 GESTALT 雕像与月岩       3901-4140    GESTALT 拼图、AI 调试参数
-- 19 海洋与远征               4141-4340    MALBATROSS、BOATCANNON、
--                                        海洋深度分布、OCEAN_SHADER
-- 20 ★玩家机制 · 饥饿/湿度    4341-4499    ★ HUNGER / WETNESS / SANITY 玩家级基线
-- 21 角色 · 沃托克斯等       4500-4999    WORTOX、WARLY、WENDY、ABIGAIL、
--                                        WALTER、WANDA、BATTLESONG
-- 22 角色 · 海象/咸鱼等       5000-5359    MALBATROSS、SQUID、WANDA 老年、
--                                        CRABKING（蟹王争霸，68 个参数）
-- 23 蟹王续与冬季活动         5360-5743    CRABKING 续、WOBSTER、
--                                        LIGHTFLIER、MUSHGNOME
-- 22 ★★农业（正式段）         5744-5929    ★★ FARM_TILL_SPACING 起的完整农业段、
--                                        堆肥、季节作物注册表
-- 25 果蝇与嘉年华             5930-6099    FRUITFLY、CARNIVAL、COMPOST、
--                                        LORDFRUITFLY
-- 26 鬼王与眼怪              6100-6399    ALTERGUARDIAN 54 个参数、
--                                        EYEOFTERROR、ALTERGUARDIANHAT
-- 27 眼怪续 · 羊驼 · 双子      6400-6599    TWIN1/TWIN2、MIGHTINESS、钟表谜题、
--                                        DUMBBELL 哑铃
-- 28 ★WX78 与海盗            6600-6796    ★ WX78 电路板系统（模块/插槽）、
--                                        MONKEYISLAND、海盗船
-- 29 书站与各角色专属        6797-7005    WICKERBOTTOM、CULT_OF_THE_LAMB、
--                                        YEAR_OF_THE_BUNNY
-- 30 ★★SKILLS 技能树子表     7006-7360    ★★ WILSON REFRESH 技能树，
--                                        每个角色的技能条目集中于此
-- 31 其他角色技能条目         7361-7604    WORT0X / WX78 技能条目
-- 32 ★★裂隙与月神            7605-7799    ★★ SPAWN_RIFTS、VOIDCLOTH、
--                                        LUNARTHRALL、MIASMA、太阳风暴
-- 33 沃尔特与月神生物         7800-8099    WORMWOOD、LUNARHAIL、LUNARFROG、
--                                        BOATRACE、WILLOW 月神形态
-- 34 沃特与仙客来            8100-8399    WURT、OTTER、RUINSNIGHTMARE
-- 35 兔子王与温迪技能         8400-8699    RABBITKING、WENDYSKILL、
--                                        SHADOWTHRALL、GHOSTLYELIXIR
-- 36 幽灵精华与瓦格朋克       8700-8899    GESTALT_EVOLVED、WAGPUNK、
--                                        ELECTRIC_FIELD
-- 37 ★洞穴重构与洞穴生物      8900-9099    ★ GROW_TIME 表、CAVE_MITE、
--                                        MUTATEDBUZZARD、HERMITCRAB 商店
-- 38 YOTH 与近年追加          9100-9580    YOTH（36 个参数）、FARMPLANT_*、
--                                        WX78 音乐、GOLF 高尔夫小游戏
-- 39 ★★嵌套子表收尾           9540-9575    ★★ setmetatable(TUNING, ...)：
--                                        模组运行时改数值的元表钩子
-- 40 函数收尾                 9576-9581    关闭 Tune()，执行 Tune()
-- ═══════════════════════════════════════════════════════════════
--
-- ★★★ 【设计洞察 A】表达方式：归一化 vs 绝对值 ★★★
--
-- 这是本项目最值得学的一条数值写法。请对比两个例子：
--
-- 【坏写法（绝对值）】
--     WILSON_HUNGER_RATE = 0.15625
-- 策划看到这行只知道「当前每秒掉 0.15625 点饥饿」。他不知道：
--     · 设计意图是「一天烧 75 卡路里」吗？还是「两天空腹」？
--     · 如果把一天从 16 段改成 24 段，这个数字要不要改？—— 改错了不会报错，
--       只会让玩家莫名其妙地更容易/更难饿死，这类「悄悄失衡」最难查。
--
-- 【好写法（归一化）】
--     WILSON_HUNGER_RATE = calories_per_day/total_day_time
--     -- 其中 calories_per_day = 75（第41行），total_day_time = 480（第20行）
-- 策划看到分子分母立刻知道意图：「每天烧 75 点」。
--     · 改时钟长度（total_day_time）时，这个速率**自动等比缩放**，
--       玩家仍然每天掉 75 点，平衡关系不变。
--     · 分子 75 是可以直接上手调的「设计单位」，不需要心算 0.15625×480。
--
-- 【两种写法在本文件中的分布】
--   · 归一化写法：约 30 处，全部集中在两处
--       —— SANITYAURA_* / DAPPERNESS_*（2196-2210）
--       —— SANITY_NIGHT_* / CRAZINESS_*（2184-2215）
--     典型：SANITYAURA_TINY = 100/(seg_time*32)，行尾英文注释直接写了
--           「50 per day」—— 这个 50 不是算出来的，是先定下的设计目标，
--           再反推出分母该写成 32。**注释里写的是意图，不是结果。**
--   · 绝对值写法：绝大多数。如 SPIDER_ATTACK_PERIOD = 3（第1000行）、
--       TALLBIRD_HEALTH = 100 这类「与时间无关」的量。
--
-- 【判据】什么时候该用归一化？
--   · 与「一天」「一个季节」「一次成熟」挂钩的量 → 必须归一化，
--     否则改了时钟就失衡。
--   · 与「一次攻击间隔」「一次弹道飞行」这类**物理/交互事件**挂钩的量
--     → 绝对值更合适，因为玩家感知的是「我几下打死它」，而不是「我几天打死它」。
--
-- ★★★ 【设计洞察 B】三种分母混用的坑（本项目实测数据）★★★
--
-- 同样是「一段时间」，本文件里有**三种**分母在混用，极易用错：
--     seg_time       = 30秒   最细粒度
--     day_time       = 300秒  一个白天（不含黄昏与夜晚）
--     total_day_time = 480秒  一个完整昼夜（含黄昏与夜晚）
--     （另有 dusk_time=120 / night_time=60，但它们总是成对出现，用法固定）
--
-- 它们的比值是 1 : 10 : 16。
--
-- ★ 实测行号分布（统计口径：本文件内出现该标识符的行）：
--
--  ┌──────────────────┬───────┬────────────────────────────────────┐
--  │ 分母│ 出现行数 │ 典型场景                        │
--  ├──────────────────┼───────┼────────────────────────────────────┤
--  │ seg_time       │  201  │ 极短时序：武器耐久、燃料、光源       │
--  │                  │       │ 掉落延迟(79)、护盾燃料(204)、        │
--  │                  │       │ 蛛帽腐坏(1724)、夜间照明            │
--  ├──────────────────┼───────┼────────────────────────────────────┤
--  │ day_time       │  105  │ 中等时序：生长、成熟、再生           │
--  │                  │       │ 种子生长(1610)、洞穴蛛巢(1104)、    │
--  │                  │       │ 腐叶掉落(780)、堆肥(5832)│
--  ├──────────────────┼───────┼────────────────────────────────────┤
--  │ total_day_time │  436  │ 长周期：一个完整昼夜为单位的消耗/回复 │
--  │                  │       │ 理智速率(120)、口粮(193)、           │
--  │                  │       │ 作物枯萎(2267)、石像复活            │
--  ├──────────────────┼───────┼────────────────────────────────────┤
--  │ dusk_time      │   18  │ ★几乎只出现在「燃料上限」公式里      │
--  │ night_time     │   33  │ ★几乎只出现在「燃料上限/照亮时长」    │
--  └──────────────────┴───────┴────────────────────────────────────┘
--
-- 【dusk_time / night_time 的固定套路】——这是本文件里唯一严格的规范：
--     凡是需要「撑过一个夜晚」的火源/灯具，燃料上限一律写成
--         (night_time + dusk_time) * N
--     ★ 实测共 14 处：1684/1685/1688/1689/1691/1694/1695/1699/1700/1706/1707/
--       1722/1723（成对的 _MAX 与 _START），以及 3402、5584、7343。
--     为什么？夜间长 60 秒、黄昏长 120 秒，玩家要在**黄昏就开始点灯**，
--     所以燃料必须覆盖 180 秒而不是 60 秒。写成 (night_time+dusk_time)
--     让这个设计意图直接体现在代码里。
--
-- ★⚠ 【已确认的分母口径不一致 —— 非缺陷，但必须知道】
--   第 2196-2202 行的 SANITYAURA_* 系列用 **seg_time** 做分母，
--   而第 2204-2210 行的 DAPPERNESS_* 系列用 **day_time** 做分母，
--   两组相邻、常被同时修改，但「每 N 个昼夜」的口径并不相同：
--     SANITYAURA_TINY  = 100/(seg_time*32)  = 0.104167/秒
--         → ×480 秒 =  50.0 点/昼夜（与行尾注释一致）
--     DAPPERNESS_TINY  = 100/(day_time*15)  = 0.022222/秒
--         → ×480 秒 = 10.67 点/昼夜（与行尾注释一致）
--   两组行尾注释里的「per day」都按 **total_day_time=480** 来算，
--   而分母分别选了seg_time 和 day_time 来凑出这个结果。
--   ⇒ 推理依据：若要「优雅地」表达 50点/昼夜，应写 100/(total_day_time*N)；
--     作者选用 seg_time*32 / day_time*15，是历史迭代的产物。
--   ⇒ 后果：修改 total_day_time（昼夜总长）时，两组的「每昼夜产出」会
--     **不同比例变化**。seg_time*32 组随段数线性缩放，
--     day_time*15 组只随白天段数缩放 —— 二者比例会漂移。
--   ⇒ 这不是 bug（当前数值下二者都被注释和实测校验过，是自洽的），
--     但改时钟时必须**同时重新核对这两组**，否则光源与仪态的平衡会错位。
--
-- ★★ 【修改数值的正确方式】★★
--
--   **不要直接改 tuning.lua。** 正确做法是用世界设置难度覆写：
--       worldsettings_overrides.lua:2  OverrideTuningVariables(tuning)
--   它做的事是：
--       1. ORIGINAL_TUNING[k] = TUNING[k]   ← 备份原值
--       2. TUNING[k] = v                    ← 写入新值
--       并在 BRANCH=="dev" 下 assert(TUNING[k] ~= nil)，拼错名字会立刻报错。
--
--   为什么这样设计：
--     · 难度选项（never/rare/default/often/always）本身就是「一组数值覆写」，
--       用同一套机制表达，改平衡时不必碰引擎文件，版本升级也不冲突。
--     · ORIGINAL_TUNING 保留了原值，便于回退与对比。
--     · 多端一致性：服务端在生成世界时执行覆写并把结果同步给客户端，
--       客户端不会自己再跑一遍 difficulty 表（见 networking.lua）。
--
--   ★ 三个层次的区别，务必分清：
--     tuning.lua             —— 引擎原始数值，改它＝改游戏本体
--     worldsettings_overrides.lua —— 难度覆写（正规入口，★推荐用这个）
--     tuning_override.lua    —— **不是**改数值，见该文件注释：
--                               它是世界「区域脚本」的白名单钩子，
--                               供 area_trigger.lua 派发事件回调。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：constants.lua, tuning_override.lua, worldsettings_overrides.lua,
--           components/sanity.lua, components/health.lua,
--           components/worldstate.lua, map/forest_map.lua
-- ============================================================
--【★ 唯一的模块级 require】本文件只依赖 techtree，用于 TechTree.Create()。
--   参见 techtree.lua。文件头还有大量注释，见上方文件头的分区导航表。
local TechTree = require("techtree")

--【★★ 全局状态三件套】理解这三个全局变量的分工，是读懂本文件的关键。
--   TUNING          —— 数值表本体。全项目所有业务代码读的就是它。
--   TUNING_MODIFIERS —— 「延迟计算的修改器」表。键是变量名，值是 {函数, 缓存值}。
--   ORIGINAL_TUNING  —— ★原值备份。游戏本体里没人写它；
--真正的消费者是 worldsettings_overrides.lua:8（难度覆写时备份原值）。
--
--   为什么单独一个 TUNING_MODIFIERS，而不是直接改TUNING？
--   因为某些数值必须「读取时才计算」：例如随机扰动、或依赖运行期上下文。
--   用元表钩子（文件末尾 9560 行附近）实现「延迟求值」，见该处注释。
TUNING = {}
TUNING_MODIFIERS = {}
ORIGINAL_TUNING = {}

--【★ AddTuningModifier】把一个「数值」改造成「每次读取都重新计算的表达式」。
--   参数：tuning_var 变量名 / fn 计算函数 / tuning_value 兜底默认值。
--   关键细节 1：TUNING[tuning_var] 被主动置为 nil，
--     这样读取时才会走元表的 __index 分支（见文件末尾）。
--   关键细节 2：第 2 个元素缓存的是「**原始值**」（改动发生时的值），
--     所以 fn 拿到的是「基线值」而非当前值 —— 这允许多层叠加修改器。
--★ 注意：本文件内没有任何地方调用它。调用方在模组 / 扩展包侧，
--   这是官方留给模组作者的正式扩展点。
function AddTuningModifier(tuning_var, fn, tuning_value)
    if not TUNING_MODIFIERS[tuning_var] and fn then
        TUNING_MODIFIERS[tuning_var] = {fn, TUNING[tuning_var] or tuning_value}
        TUNING[tuning_var] = nil
    end
end

--【★★ Tune(overrides)】整个 9581 行数值表的构造函数。
--   文件末尾 9580 行会以无参形式调用 Tune()，一次性把整张表建好。
--   为什么包一层函数而不是直接写 TUNING = { ... }？
--     ★ 因为需要局部变量。接下来的第 19-41 行先算出一批「派生数值」，
--     再在表字面量里引用它们 —— 这样「34 * multiplayer_attack_modifier」
--     这类换算只需改一处，不用在 4000 个条目里逐个改。
--   overrides 参数：外部可传入预置覆盖项（本文件内未使用）。
function Tune(overrides)
    if overrides == nil then
        overrides = {}
    end

--★★★ 【全文件一切时间数值的源头 —— 时间基】★★★
--  这 5 个局部变量是整个 TUNING 表的时间坐标系。此后所有 *_TIME / *_PERIOD /
--  *_DURATION / *_RATE 数值，最终都回溯到这几个数。
--
--  【seg_time = 30 秒 —— 一「段」】
--    游戏把一整天离散成 16 段（segment）。每段 30 秒现实时间，
--    所以完整昼夜 = 16 × 30 = 480 秒 = 8 分钟。
--    ★ 这是一个典型的「以玩家感知为单位」的设计：玩家不会用秒来规划，
--      但「天」这个单位必须和现实时间挂钩，否则存档、跨时区会出问题。
--    为什么是 16 段？因为昼夜分段比例 10:4:2 正好是 5:2:1，
--    即白天占 62.5%、黄昏 25%、夜晚 12.5% —— 夜晚短到能睡，
--    长到有威胁。
    local seg_time = 30
--★ 【total_day_time = 480 秒】完整昼夜（白天+黄昏+夜晚）。
--  它是本文件里**最常被引用**的分母（436 行，见文件头「三种分母」表）。
--  用途特征：凡是「以一整天为单位」的消耗与回复都用它。
    local total_day_time = seg_time*16

--【昼夜分段数】day_segs=10 / dusk_segs=4 / night_segs=2
--  ★ 单独抽成变量的意义：改时钟时只需改这两个数字（第19/22-24行），
--    整张表 436 处total_day_time 引用与 105 处 day_time 引用会自动重算，
--    无需逐条修改。这就是「归一化写法」的直接收益。
--  原始比例 10:4:2，若改成 12:6:6（更长夜晚），上面三行改数字即可。
    local day_segs = 10
    local dusk_segs = 4
    local night_segs = 2

--【昼夜时长推导】day_time=300 / dusk_time=120 / night_time=60
--  ★★ 校验恒等式：day_time + dusk_time + night_time = 300+120+60 = 480
--     恰好等于 total_day_time。**这三者不是独立量，而是 16 段的重新切分**。
--     这个恒等关系是理解「三种分母」的关键，见文件头详解。
    --default day composition. changes in winter, etc
    local day_time = seg_time * day_segs
    local dusk_time = seg_time * dusk_segs
    local night_time = seg_time * night_segs

--【★★ 联机难度系数 —— 全局倍率闸门】这5 个变量是「多人游戏让数值变软」的源头。
--  ★ 设计思路：与其逐个生物逐个改数值，不如在最上游统一打折。
--    multiplayer_attack_modifier = 1 → 单人和多人攻击伤害相同。
--    multiplayer_armor_durability_modifier = 0.7 → ★只有它不是 1，
--      多人时护甲耐久降至 70%。为什么单独调护甲？
--      因为多人游戏里玩家需要给队友「分赃」，护甲既要能用又不至于
--      变成人人永动机；同理护甲吸收率仍是 1。
--  注意行尾被注释掉的 0.6/0.75 等历史值 —— 保留它们是方便回滚调参。
    local multiplayer_attack_modifier = 1--0.6--0.75
    local multiplayer_goldentool_modifier = 1--0.5--0.75
    local multiplayer_armor_durability_modifier = 0.7
    local multiplayer_armor_absorption_modifier = 1--0.75
    local multiplayer_wildlife_respawn_modifier = 1--2

--【★ 角色基线三元组】attack=34 / health=150 / hunger=150
--  ★ 为什么把wilson 的数值先写成局部变量，再在表里起两份名字？
--    因为 TUNING 里同一个含义有两个入口：
--      TUNING.WILSON_HEALTH   —— 给业务代码按角色读
--      TUNING.DEFAULT_CHARACTER_HEALTH —— 给「读默认角色」的通用代码读
--    模组改角色时，两个入口都必须一致更新。
--  WILSON（威尔逊）= 无加成的基础角色，所有其他角色都以此为基准做增减。
    local wilson_attack = 34 * multiplayer_attack_modifier
    local wilson_health = 150
    local wilson_hunger = 150
    local wilson_sanity = 200
--【★ calories_per_day = 75】每日热量摄入目标。
--  ★★ 这是「归一化写法」的教科书示例，见下一行 —— 全表最值得学的一处。
    local calories_per_day = 75

--【★ wilson_attack_period = 0.4 秒】「防止玩家无限连点」的节流。
--  行为：0.4 秒内不能再次攻击。这是防作弊式操作，不是平衡性数值。
    local wilson_attack_period = 0.4 --prevents players

    -----------------------

--★ perish_warp = 1（拼写是 warp，注释里写 warp 也不一致，见下方）。
--  ★ 这是一个腐坏时间的全局乘数。它被大量 PERISH_* 常量引用，
--    所以调它一个数就能整体加速/减慢全游戏所有物品的腐坏速度。
--  ⚠ 疑似缺陷（拼写）：变量名为 perish_**warp**，
--    而同一行英文注释写的是 '1--/200'，暗示原意可能是 warp（扭曲/侵蚀）。
--    推理依据：Lua 变量名与注释语义不匹配；虽不影响运行（Lua 不检查拼写），
--    但 grep 时两种拼写都要试，容易漏改。
--    ★ 另注意尾注释 '1--/200' 是被注释掉的历史值 1/200 = 0.005，
--      保留它是为了方便对比回滚。
    local perish_warp = 1--/200

    local OCEAN_NOISE_BASE_SCALE = 10
    local OCEAN_SPEED_BASE_SCALE = 0.01

    TUNING =
    {
--【分区1 · 核心机制：时序与全局】52-199 行
--  ★ 分区边界。此区集中放「全局节流、堆叠上限、玩家基线、控制器参数」，
--    与后面 4000 行「某个生物的某个属性」形成对比。
        MODS_QUERY_TIME = 60, -- NOTES(JBK): We do not need live instant updates per query for this while the mod panels are up.

        MAX_SERVER_SIZE = 6,
--【★ DEMO_TIME】试玩版时长 = 2 个完整昼夜 + 20% 白天。
--  ★ 又一处归一化写法：total_day_time*2 + day_time*.2。
--    改时钟长度时试玩时长自动跟随，这正是我们要的效果。
--    注意它同时用了两种分母（total 与 day），因为要表达「两个整昼夜
--    再加一个白天的五分之一」—— 这里的混用是**故意的**，且语义清晰。
        DEMO_TIME = total_day_time * 2 + day_time*.2,
--【★ AUTOSAVE_INTERVAL = total_day_time】自动存档间隔 = 一个完整昼夜。
--  ★ 设计意图：存档点与昼夜对齐。玩家在「早上」读档，
--    面对的是「白天」这个确定性状态，不会出现「夜里读档突然饿死」。
--  ★★ 这是「数值即设计」的典范：把存档周期绑到昼夜节律上，
--    而不是为了省 IO 随手取整。
        AUTOSAVE_INTERVAL = total_day_time,

		HUD_CLOUD_CUTOFF = 0.75,

--【★ 时基导出给外部】TUNING 里同时导出 5 个时间常量。
--   SEG_TIME / TOTAL_DAY_TIME / DAY_SEGS_DEFAULT / DUSK_SEGS_DEFAULT /
--   NIGHT_SEGS_DEFAULT / DAY_TIME_DEFAULT / DUSK_TIME_DEFAULT /
--   NIGHT_TIME_DEFAULT（62-70 行）。
--  ★ 为什么局部分配不直接对外，要再导出 8 个？
--    因为它们是「局部变量」，表字面量外的代码拿不到。而 worldstate.lua、
--    seasons.lua 等模块需要读昼夜长度来推进季节。
--    参见 components/worldstate.lua:239、map/forest_map.lua:325。
--★ 命名约定：带 _DEFAULT 后缀 = 「默认分段/默认时长」，
--    暗示存在覆盖机制（确实有，见 worldsettings_overrides.lua）。
        SEG_TIME = seg_time,
        TOTAL_DAY_TIME = total_day_time,
        DAY_SEGS_DEFAULT = day_segs,
        DUSK_SEGS_DEFAULT = dusk_segs,
        NIGHT_SEGS_DEFAULT = night_segs,

        DAY_TIME_DEFAULT = day_time,
        DUSK_TIME_DEFAULT = dusk_time,
        NIGHT_TIME_DEFAULT = night_time,

        MULTIPLAYER_ATTACK_MODIFIER = multiplayer_attack_modifier,
        MULTIPLAYER_GOLDENTOOL_MODIFIER = multiplayer_goldentool_modifier,
        MULTIPLAYER_ARMOR_DURABILITY_MODIFIER = multiplayer_armor_durability_modifier,
        MULTIPLAYER_ARMOR_ABSORPTION_MODIFIER = multiplayer_armor_absorption_modifier,
        MULTIPLAYER_WILDLIFE_RESPAWN_MODIFIER = multiplayer_wildlife_respawn_modifier,

        TOAST_FALLBACK_TIME = 1440,
--【★ ITEM_DROP_TIME = seg_time】夜晚开始后多久地上的东西才能被捡。
--  ★ 为什么用最细的 seg_time？因为这是「秒级」体验：
--    玩家在黄昏丢东西、黄昏捡回来要等 30 秒。短到不烦，长到防丢。
--  这是 seg_time 的典型适用场景：**极短时序**。
        ITEM_DROP_TIME = seg_time, -- time to wait after start of night before activating

--【★ 堆叠上限阶梯】LARGE=10 / MEDI=20 / SMALL=40 / TINY=60 / PELLET=120。
--  ★ 阶梯设计而非连续数值：这是物品预制体的「体量分类」，
--    同类物品行为一致（一个 sunflower 40 个，一个 flint 60 个）。
--    所以这里是绝对值而非归一化值 —— 堆叠上限与时间无关。
--  ★ 注意 PELLET=120 是万圣节添加的特殊堆叠档，独立于五档阶梯之外。
        STACK_SIZE_LARGEITEM = 10,
        STACK_SIZE_MEDITEM = 20,
        STACK_SIZE_SMALLITEM = 40,
		STACK_SIZE_TINYITEM = 60,
		STACK_SIZE_PELLET = 120,

		OCEAN_WETNESS = 75, --initial wetness level when things enter ocean
		MAX_WETNESS = 100,

		DEFAULT_TALKER_DURATION = 2.5,
		MAX_TALKER_DURATION = 8.0,

--【MAX_FIRE_DAMAGE_PER_SECOND = 120】火焰每秒最大伤害。
--  ★ 这是一个「安全阀」：无论多少火焰叠加，单位时间伤害封顶，
--    防止玩家用极端手段（大量篝火 + 燃烧瓶）把自己秒了。
--    安全阀类数值的共同特征：设一个「不太可能达到」的上界。
        MAX_FIRE_DAMAGE_PER_SECOND = 120,

--【★ GOLDENTOOLFACTOR】金工具效率倍率 = 4 × 多人系数。
--  3/4 原理：一次砍树给 3 次耐久，4 次生效即 100%→ 现有 75% + 25% 返还。
--  ★ 写成 4*multiplayer_goldentool_modifier 而非裸 4：
--    保证联机难度改动时金工具效率自动同步。
        GOLDENTOOLFACTOR = 4*multiplayer_goldentool_modifier,

		SEED_CHANCE_VERYCOMMON = 5,
		SEED_CHANCE_COMMON = 2.5,
		SEED_CHANCE_UNCOMMON = 1,
		SEED_CHANCE_RARE = 0.5,

		SEED_WEIGHT_SEASON_MOD = 2,
		FARM_PLANT_RANDOMSEED_WEED_CHANCE = 0.20,

--【★ 光照阈值】DARK_CUTOFF=0 / DARK_SPAWNCUTOFF=0.1
--  ★ 是 0~1 的归一化值（0=全亮，1=全黑），不是绝对光照单位。
--    所以这两行是「归一化值」而非「时间归一化」—— 本文件里有两种归一化：
--      (a) 速率归一化：100/(分母*N)—— 随时钟自动缩放
--      (b) 量纲归一化：0~1 无量纲比例—— 与时钟无关
--    见到 0.x / 1.x 这种值，先想它可能是无量纲比例，别急着乘时间。
        DARK_CUTOFF = 0,
        DARK_SPAWNCUTOFF = 0.1,

		DEFAULT_ATTACK_RANGE = 2,
		DEFAULT_HIT_RECOVERY = .75,
		DEFAULT_PROJECTILE_HIT_RECOVERY_MULTIPLIER = 2,
		DEFAULT_PROJECTILE_MAX_HITREACTS_MULTIPLIER = 0,

--【★ 角色基线导出区】DEFAULT_CHARACTER_HEALTH / BASE_SURVIVOR_ATTACK /
--  WILSON_* （113-121 行）。★ 命名约定：WILSON_ 前缀 = 基准角色值。
--  DEFAULT_ 前缀 = 通用默认值（不指定角色时用）。
		DEFAULT_CHARACTER_HEALTH = wilson_health,

		BASE_SURVIVOR_ATTACK = wilson_attack,

        WILSON_HEALTH = wilson_health,
        WILSON_ATTACK_PERIOD = wilson_attack_period,
        WILSON_HUNGER = wilson_hunger, --stomach size
--★★★ 【归一化写法典范 · 第1 例】WILSON_HUNGER_RATE ★★★
--  = calories_per_day / total_day_time = 75 / 480 = 0.15625 点/秒
--
--  ★★ 为什么这样写远优于直接写 0.15625：
--    1) 意图可读：策划一看分子就知「每天烧 75 点」，无需反算。
--    2) ★★ 改时钟自动等比缩放：若 total_day_time 改成 960（一天16分钟），
--       这行自动变成 75/960 = 0.078125，玩家仍然每天掉 75 点。
--       若写成裸 0.15625，玩家就会**每天掉 150 点** —— 平衡被悄悄破坏，
--       而且没有任何报错或日志。
--    3) 换算零心算：调「一天多少卡路里」时只改第 41 行的 75。
--
--  可推导的实感数据：满饥饿 150 点（见119 行 WILSON_HUNGER）
--    ÷ 0.15625 = 960 秒 = **恰好 2 个完整昼夜**空腹而死。
--    这个整数关系显然是被刻意设计的 —— 想验证某处改动是否合理，
--    就检查「饿死是不是正好两天」这个不变量是否还成立。
--  参见 components/hunger.lua（消耗逻辑）、tuning.lua:41（calories_per_day）
        WILSON_HUNGER_RATE = calories_per_day/total_day_time, --calories burnt per day
        WILSON_SANITY = wilson_sanity,

		PLAYER_DAMAGE_TAKEN_MOD = 1,
        PLAYER_MAP_LANDSEEN_FUDGE_FACTOR = 1.05, -- How much of a map can be still unseen for the whole map to be considered entirely seen.

--【分区1b · 手柄参数】126-139 行。
--  ★ 这批数值与前面所有「玩法数值」性质完全不同：它们描述的是**物理设备**
--    （摇杆死区、瞄准锥角），调错了影响的是操作手感而非平衡。
--  ★ 而且它们是**跨端不同步**的：手柄参数由各端本地读取，不参与联机校验。
--    （这是与 TUNING 其他部分的重要区别）
        -- Controller specific tuning values.
		CONTROLLER_DEADZONE_RADIUS = 0.3,
		CONTROLLER_RETICULE_INITIAL_DEADZONE_RADIUS = .5,
		CONTROLLER_RETICULE_RSTICK_SPEED = 2,
		CONTROLLER_UI_CURSOR_STICK_SPEED = 50,
        CONTROLLER_BLINKFOCUS_DISTANCESQ_MIN = 4,
        CONTROLLER_BLINKFOCUS_DISTANCE = 8,
--★ 英文原注释要点：这些角度值是「面向方向两侧各算一份」，
--  所以实际锥形张角是此值的 2 倍。这是常见的手感误读点，务必记住。
        -- NOTES(JBK): These Angles are for both sides of the facing direction so cone total size is double this value.
        CONTROLLER_BLINKFOCUS_ANGLE = 30, -- For targeting onto a focus.
        CONTROLLER_BLINKCONE_ANGLE = 30, -- For general blink teleports.
        CONTROLLER_OCEANFISHINGFOCUS_ANGLE = 50,
        CONTROLLER_BOATPLACEMENT_ANGLE = 135, -- Arc with 90 degree backside blind spot.
        CONTROLLER_INTERACT_ANGLE = 60, -- Want things forward facing to be picked.
        CONTROLLER_BOATINTERACT_ANGLE = 45, -- Want things forward facing to be picked.

--【★ WX78 生命值双份定义】wx78_minhealth 与 wx78_maxhealth。
--  ★★ 英文原注释已点明：为「向后兼容与模组」而保留。
--    这是很典型的历史包袱设计：角色改版后旧模组仍可能引用旧名，
--    删掉会导致模组崩溃，于是永久保留别名。
--★ 由此引出本文件一条重要的命名观察：**大量重复/冗余键是刻意保留的**，
--  不是冗余错误。看到 xxx 和 xxx_refresh 成对出现时，先查注释再下判断。
        -- WX78 Refresh: WX78 min and max health variables kept for backwards compatibility & mods
        WX78_MIN_HEALTH = 150,
        WX78_MIN_HUNGER = 150, -- 100 For pax we are increasing this.  Hungers out too easily.
        WX78_MIN_SANITY = 150,

        WX78_MAX_HEALTH = 400,
        WX78_MAX_HUNGER = 200,
        WX78_MAX_SANITY = 300,

        WX78_HEALTH = 100,
        WX78_HUNGER = 100,
        WX78_SANITY = 100,

        HAMMER_LOOT_PERCENT = .5,
        BURNT_HAMMER_LOOT_PERCENT = .25,
        AXE_USES = 100,
        HAMMER_USES = 75,
        SHOVEL_USES = 25,
        PITCHFORK_USES = 25,
        FARM_HOE_USES = 25,
        PICKAXE_USES = 33,
        BUGNET_USES = 10,
        THULECITEBUGNET_USES = 100,
        WHIP_USES = 175,
        SPEAR_USES = 150,
        CLAW_GLOVE_USES = 200,
        WATHGRITHR_SPEAR_USES = 200,
        SPIKE_USES = 100,
        FISHINGROD_USES = 9,
        TRAP_USES = 8,
        BOOMERANG_USES = 10,
        BOOMERANG_DISTANCE = 12,
        NIGHTSWORD_USES = 100,
        ICESTAFF_USES = 20,
        FIRESTAFF_USES = 20,
        TELESTAFF_USES = 5,
        TELESTAFF_MOISTURE = 500,
        HAMBAT_USES = 100,
        BATBAT_USES = 75,
        MULTITOOL_AXE_PICKAXE_USES = 800,
		PICKAXE_LUNARPLANT_USES = 600,
		SHOVEL_LUNARPLANT_USES = 250,
		STAFF_LUNARPLANT_USES = 50,
		SWORD_LUNARPLANT_USES = 200,
        RUINS_BAT_USES = 200,
        SADDLEHORN_USES = 10,
        BRUSH_USES = 75,
        FENCE_ROTATOR_USES = 200,

        MULTITOOL_AXE_PICKAXE_EFFICIENCY = 4/3,
		PICKAXE_LUNARPLANT_EFFICIENCY = 4/3,

        JELLYBEAN_DURATION = total_day_time * .25,
        JELLYBEAN_TICK_RATE = 2,
        JELLYBEAN_TICK_VALUE = 2,

        REDAMULET_USES = 20,
        REDAMULET_CONVERSION = 5,
        REDAMULET_CONVERSION_TIME = 30,
--【分区 2 · 战斗与工具】200-399 行
--  ★ 分区边界：护盾/弹药耐久、钓鱼竿、默认攻击参数。
--  本区的共同特征：与「玩家的主动操作」直接相关，数值以**秒/次**为单位。

        BLUEAMULET_FUEL = total_day_time * 0.75,
        BLUEGEM_COOLER = -20,

--【★ PURPLEAMULET_FUEL = seg_time*8 = 240 秒】紫水晶护盾燃料。
--  ★ seg_time 的典型用法：短周期消耗品（护盾每 4 段换一次）。
--    8 段 = 白天的一大半，是「够用但不宽裕」的量级。
        PURPLEAMULET_FUEL = seg_time * 8,

        YELLOWAMULET_FUEL = total_day_time,
        YELLOWSTAFF_USES = 20,
        YELLOWSTAFF_STAR_DURATION = total_day_time * 3.5,

        OPALSTAFF_USES = 50,
        OPALSTAFF_STAR_DURATION = total_day_time * 2,

        ORANGEAMULET_USES = 225,
        ORANGEAMULET_RANGE = 4,
        ORANGEAMULET_ICD = 0.33,
        ORANGESTAFF_USES = 20,

        GREENAMULET_USES = 5,
        GREENAMULET_INGREDIENTMOD = 0.5,
        GREENSTAFF_USES = 5,

		POCKETSCALE_USES = 100,

        FISHING_MINWAIT = 2,
        FISHING_MAXWAIT = 20,

        OVERRIDE_ROW_ACTION_DISTANCE = 2.2, -- Same as SetPhysicsRadiusOverride in ocean_trawler

		OCEAN_FISHING =
		{
			MAX_CAST_DIST = 16,
			CAST_DIST_MIN_OFFSET = 0.8,
			CAST_DIST_MAX_OFFSET = 1.1,
			CAST_ANGLE_OFFSET = 20 / RADIANS,

			REEL_ACTION_REPEAT_DELAY = 0.300,

			REEL_STRENGTH_MIN = 2,
			REEL_STRENGTH_MAX = 3,
			REEL_SPEED_MAX = 4,
			REEL_ANGLE_VAR = 50,
			STOP_FISHING_HOOK_DIST = 2.5,
			FISHING_CATCH_DIST = 2.5,
			MUDBALL_CATCH_DIST = 2,


			MAX_HOOK_DIST = 26,

			LINE_TENSION_HIGH = 0.80, -- line tension is high if greater than this
			LINE_TENSION_GOOD = 0.10, -- line tension is good if greater than this
--【★ 阈值恒等关系注释】LINE_TENSION_LOW <= LINE_TENSION_GOOD。
--  ★★ 这类「约束性注释」极有价值：它记录的是**数值之间的隐含契约**。
--    只调LOW 不调 GOOD 不会报错，但绳索张力逻辑会失准。
--★ 读 tuning.lua 的一般方法：优先找这类注释，它们标出了「不能单独改」的键。
			-- LINE_TENSION_LOW would be "<= LINE_TENSION_GOOD"

			REELING_SNAP_TENSION = 0.92,
			UNSET_HOOK_TENSION = 0.0, -- should be less than LINE_TENSION_GOOD

			START_UNREELING_TENSION = 0.7,

			IDLE_QUOTE_TIME_MIN = 15,
			IDLE_QUOTE_TIME_VAR = 5,
		},

		OCEANFISHING_TACKLE =
		{
--【max_angle_offset 是 ± 值】角度偏移为正负对称，
--  ★ 含义：钓鱼竿/钩子的允许摆动范围是中心角两侧各偏这么多。
--    与第 133 行手柄角度是同一类「对称 ±」设计。
			-- max_angle_offset is +/-

			BASE				= {dist_max =  5, dist_min_accuracy = 0.70, dist_max_accuracy =  1.30, max_angle_offset =  40 },

			-- everything below here is in addition to BASE
			BOBBER_TWIG			= {dist_max =  2, dist_min_accuracy = 0.10, dist_max_accuracy = -0.10, max_angle_offset = -10 },
			BOBBER_BALL			= {dist_max =  4, dist_min_accuracy = 0.10, dist_max_accuracy = -0.10, max_angle_offset = -20 },
			BOBBER_OVAL			= {dist_max =  6, dist_min_accuracy = 0.10, dist_max_accuracy = -0.10, max_angle_offset = -20 },
			BOBBER_PLUG			= {dist_max =  8, dist_min_accuracy = 0.10, dist_max_accuracy = -0.10, max_angle_offset = -10 },
			BOBBER_LIGHTBULB	= {dist_max =  4, dist_min_accuracy = 0.10, dist_max_accuracy = -0.10, max_angle_offset = -20 },

			BOBBER_CROW			= {dist_max =  4, dist_min_accuracy = 0.15, dist_max_accuracy = -0.15, max_angle_offset = -25 },
			BOBBER_ROBIN		= {dist_max =  4, dist_min_accuracy = 0.15, dist_max_accuracy = -0.15, max_angle_offset = -25 },
			BOBBER_ROBIN_WINTER	= {dist_max =  4, dist_min_accuracy = 0.15, dist_max_accuracy = -0.15, max_angle_offset = -25 },
			BOBBER_CANARY		= {dist_max =  4, dist_min_accuracy = 0.15, dist_max_accuracy = -0.15, max_angle_offset = -25 },
			BOBBER_GOOSE		= {dist_max =  8, dist_min_accuracy = 0.25, dist_max_accuracy = -0.25, max_angle_offset = -35 },
			BOBBER_MALBATROSS	= {dist_max =  8, dist_min_accuracy = 0.25, dist_max_accuracy = -0.25, max_angle_offset = -35 },
		},

		OCEANFISHING_LURE =
		{
--【★★ 钓鱼钩参数表的字段说明】285-292 行。
--  ★ 这 6 条英文注释是**字段文档**，说明 radius/charm/reel_charm/
--    timeofday/style/dist_max 各自含义。
--  ★ 特别提醒 reel_charm 是 **-1 到 1** 的有符号量：
--    正值收线、负值放线。它是「双极性」参数，
--    与本文件绝大多数「非负上限」类参数不同，读表时容易搞错符号。
--  timeofday = {day=1, dusk=0.5, night=0.5} 说明鱼饵吸引力随时段变化，
--  ★ 这是「时间归一化」的另一种形态：把 0~1 无量纲比例按时段映射。
			-- radius = how far away the fish will start to be attracted to it
			-- charm = 0 to 1
			-- reel_charm = -1 to 1
			-- timeofday = {day = 1, dusk = 0.5, night = 0.5}
			-- style = spoon, spinnerbait, berry, seed, hook
			-- dist_max = added to the casting distance

--★ 英文原注释：基础鱼钩 —— 可能闪闪发亮，运气好能钩到东西。
--  语气说明：Klei 的注释常带这种轻松笔调，读不懂时可以先看代码。
			-- a basic hook, kind of shinny, maybe it can hook something if you are lucky
			HOOK				= { charm = 0.1, reel_charm =  0.0, radius = 1.0, style = "hook", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 0 },

			SPOILED_FOOD		= { charm = 0.1, reel_charm = -0.3, radius = 2.0, style = "rot", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 2 },

			SEED				= { charm = 0.2, reel_charm = -0.3, radius = 3.0, style = "seed", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 1 },
			BERRY				= { charm = 0.3, reel_charm = -0.3, radius = 3.0, style = "berry", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 1 },
            FIG                 = { charm = 0.5, reel_charm = -0.3, radius = 4.0, style = "berry", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 1 },

			SPOON_DAY			= { charm = 0.2, reel_charm =  0.3, radius = 4.0, style = "spoon", timeofday = {day = 1.0, dusk = 0.3, night = 0.3}, dist_max = 1 },
			SPOON_DUSK			= { charm = 0.2, reel_charm =  0.3, radius = 4.0, style = "spoon", timeofday = {day = 0.3, dusk = 1.0, night = 0.3}, dist_max = 1 },
			SPOON_NIGHT			= { charm = 0.2, reel_charm =  0.3, radius = 4.0, style = "spoon", timeofday = {day = 0.3, dusk = 0.3, night = 1.0}, dist_max = 1 },
			SPOON_SPORK			= { charm = 0.2, reel_charm =  0.3, radius = 4.0, style = "spoon", timeofday = {day = 1.0, dusk = 1.0, night = 1.0}, dist_max = 1 },

			SPINNERBAIT_DAY		= { charm = 0.4, reel_charm =  0.4, radius = 5.0, style = "spinnerbait", timeofday = {day = 1.0, dusk = 0.3, night = 0.3}, dist_max = 2 },
			SPINNERBAIT_DUSK	= { charm = 0.4, reel_charm =  0.4, radius = 5.0, style = "spinnerbait", timeofday = {day = 0.3, dusk = 1.0, night = 0.3}, dist_max = 2 },
			SPINNERBAIT_NIGHT	= { charm = 0.4, reel_charm =  0.4, radius = 5.0, style = "spinnerbait", timeofday = {day = 0.3, dusk = 0.3, night = 1.0}, dist_max = 2 },

			SPECIAL_RAIN		= { charm = 0.3, reel_charm =  0.5, radius = 5.0, style = "special", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 1, weather = {default = 0.0, raining = 1.0, snowing = 0.0} },
			SPECIAL_SNOW		= { charm = 0.3, reel_charm =  0.5, radius = 5.0, style = "special", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 1, weather = {default = 0.0, raining = 0.0, snowing = 1.0} },
			SPECIAL_DROWSY		= { charm = 0.1, reel_charm =  0.3, radius = 3.0, style = "special", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 1, stamina_drain = 1.0 },
			SPECIAL_HEAVY		= { charm = 0.5, reel_charm =  0.0, radius = 5.0, style = "special", timeofday = {day = 1, dusk = 1, night = 1}, dist_max = 1, },

			SPOON_WIP			= { charm = 0.2, reel_charm =  0.3, radius = 4.0, style = "spoon", timeofday = {day = 0.0, dusk = 0.0, night = 0.0} },
			SPINNERBAIT_WIP		= { charm = 0.2, reel_charm =  0.3, radius = 4.0, style = "spinnerbait", timeofday = {day = 0.0, dusk = 0.0, night = 0.0} },
		},

		OCEANFISHING_LURE_WEATHER_DEFAULT = {default = 1.0, raining = 0.5, snowing = 0.5},

		OCEANFISH_LURE_PREFERENCE =
		{
			SMALL_VEGGIE	= { hook = 0.25, special = 1.00, rot = 1.00, seed = 1.50, berry = 1.50, spoon = 0.00, spinnerbait = 0.00, insect = 0.00 },
			VEGGIE			= { hook = 0.25, special = 1.00, rot = 0.50, seed = 1.50, berry = 1.50, spoon = 0.50, spinnerbait = 0.00, insect = 0.00 },
			SMALL_OMNI		= { hook = 0.25, special = 1.00, rot = 1.00, seed = 1.00, berry = 1.00, spoon = 1.00, spinnerbait = 0.00, insect = 1.00 },
			OMNI			= { hook = 0.25, special = 1.00, rot = 0.50, seed = 0.25, berry = 1.00, spoon = 1.00, spinnerbait = 1.00, insect = 1.00 },
			SMALL_MEAT		= { hook = 0.25, special = 1.00, rot = 1.00, seed = 0.00, berry = 0.00, spoon = 1.00, spinnerbait = 0.00, insect = 1.00 },
			MEAT			= { hook = 0.25, special = 1.00, rot = 0.50, seed = 0.00, berry = 0.00, spoon = 1.00, spinnerbait = 1.00, insect = 1.00 },
            WOBSTER         = { hook = 0.25, special = 1.00, rot = 1.00, seed = 0.25, berry = 1.00, spoon = 1.00, spinnerbait = 1.00, insect = 1.00 },
            BERRY           = { hook = 0.25, special = 1.00, rot = 0.50, seed = 0.50, berry = 2.00, spoon = 0.50, spinnerbait = 0.00, insect = 0.00 },
		},

        OCEANFISH_MIN_INTEREST_TO_BITE = 0.2,
        OCEANFISH_SEE_CHUM_DIST = 16,

		WEIGHABLE_HEAVY_WEIGHT_PERCENT = 0.8, -- anything >= to this is "heavy" for its type of fish
		WEIGHABLE_HEAVY_LOOT_WEIGHT_PERCENT = 0.7,

        STAGEHAND_HITS_TO_GIVEUP = 86,
        ENDTABLE_FLOWER_WILTTIME = total_day_time * 10,
        ENDTABLE_LIGHT_UPDATE = seg_time * 0.75,

        RESEARCH_MACHINE_DIST = 4,

        UNARMED_DAMAGE = 10,
        NIGHTSWORD_DAMAGE = wilson_attack*2,
        -------
        BATBAT_DAMAGE = wilson_attack * 1.25,
        BATBAT_DRAIN = wilson_attack * 0.2,
        -------
        SPIKE_DAMAGE = wilson_attack*1.5,
        HAMBAT_DAMAGE = wilson_attack*1.75,
        HAMBAT_MIN_DAMAGE_MODIFIER = .5,
        SPEAR_DAMAGE = wilson_attack,
        CLAW_GLOVE_DAMAGE = wilson_attack*1.5,
        WATHGRITHR_SPEAR_DAMAGE = wilson_attack * 1.25,
        AXE_DAMAGE = wilson_attack*.8,
        PICK_DAMAGE = wilson_attack*.8,
        BOOMERANG_DAMAGE = wilson_attack*.8,
        TORCH_DAMAGE = wilson_attack*.5,
        HAMMER_DAMAGE = wilson_attack*.5,
        SHOVEL_DAMAGE = wilson_attack*.5,
        PITCHFORK_DAMAGE = wilson_attack*.5,
        FARM_HOE_DAMAGE = wilson_attack*.5,
        BUGNET_DAMAGE = wilson_attack*.125,
        THULECITEBUGNET_DAMAGE = wilson_attack*.125,
		GESTALT_CAGE_DAMAGE = wilson_attack * 0.5,
        WHIP_DAMAGE = wilson_attack*.8,
        BULLKELP_ROOT_DAMAGE = wilson_attack*.8,
        FISHINGROD_DAMAGE = wilson_attack*.125,
        UMBRELLA_DAMAGE = wilson_attack*.5,
        CANE_DAMAGE = wilson_attack*.5,
        MULTITOOL_DAMAGE = wilson_attack*1.25,
        RUINS_BAT_DAMAGE = wilson_attack * 1.75,
        NIGHTSTICK_DAMAGE = wilson_attack*.85, -- Due to the damage being electric, it will get multiplied by 1.5 against any mob
        MINIFAN_DAMAGE = wilson_attack*.5,
        SADDLEHORN_DAMAGE = wilson_attack*.5,
        BRUSH_DAMAGE = wilson_attack*.8,
        OAR_DAMAGE = wilson_attack*.5,
        FENCE_ROTATOR_DAMAGE = wilson_attack,

        -------
		PICKAXE_LUNARPLANT_DAMAGE = wilson_attack * 1.25 - 10,
		PICKAXE_LUNARPLANT_PLANAR_DAMAGE = 10,
		SHOVEL_LUNARPLANT_DAMAGE = wilson_attack * .8 - 10,
		SHOVEL_LUNARPLANT_PLANAR_DAMAGE = 10,
		SWORD_LUNARPLANT_DAMAGE = wilson_attack * 2 - 30,
		SWORD_LUNARPLANT_PLANAR_DAMAGE = 30,
		STAFF_LUNARPLANT_PLANAR_DAMAGE = 10,
		STAFF_LUNARPLANT_VS_SHADOW_BONUS = 2,
		STAFF_LUNARPLANT_BOUNCES = 5,
		STAFF_LUNARPLANT_SETBONUS_BOUNCES = 7,
		WEAPONS_LUNARPLANT_VS_SHADOW_BONUS = 1.1,
		WEAPONS_LUNARPLANT_SETBONUS_DAMAGE_MULT = 1.1,
		WEAPONS_LUNARPLANT_SETBONUS_PLANAR_DAMAGE = 5,
		-------
		BOMB_LUNARPLANT_RANGE = 3,
		BOMB_LUNARPLANT_PLANAR_DAMAGE = 200,
		-------
--【分区 3 · 载具与矿车（浮空时代）】400-504 行
--  ★ 背景：这是 1.4「浮空」更新引入的分区 —— 骑牛/骑猪/矿车。
--  ★★ 这本身印证了「分区靠追加而非插入」的组织方式：
--    整车块插在「战斗」与「生物」之间，而不是追加到表尾。
--    所以行号区间只能当索引用，不能当严格语义边界。

--【分区 4 · 地面生物群：猪 / 牛 / 鹿 / 海象 / 企鹅】401-800 行
--  ★★ 本区的组织方式值得注意：按**生物种类**分块，块内堆该生物的全部属性
--    （血量、攻击、掉落、驯服…）。这是本文件最主要的一种分区方式。
--  ★ 判断某键属于哪个生物，看**前缀**即可：PIG_/BEEFALO_/DEER_ 开头就一目了然。
--  ★ 但也有大量跨块的共享键（如 SEASON_*、OCEAN_*），它们属于功能而非生物。
        SADDLE_BASIC_BONUS_DAMAGE = 0,
        SADDLE_WAR_BONUS_DAMAGE = 16,
        SADDLE_RACE_BONUS_DAMAGE = 0,

        SADDLE_BASIC_USES = 5,
        SADDLE_WAR_USES = 8,
        SADDLE_RACE_USES = 8,

        SADDLE_BASIC_SPEEDMULT = 1.4,
        SADDLE_WAR_SPEEDMULT = 1.25,
        SADDLE_RACE_SPEEDMULT = 1.55,

        CANE_SPEED_MULT = 1.25,
        WALKING_STICK_SPEED_MULT = 1.15,
        PIGGYBACK_SPEED_MULT = 0.9,
        HEAVY_SPEED_MULT = 0.15,
		ICEHAT_SPEED_MULT = 0.9,
		RUINS_BAT_SPEED_MULT = 1.1,

        TORCH_ATTACK_IGNITE_PERCENT = 1,

        WHIP_RANGE = 2,
        WHIP_SUPERCRACK_RANGE = 14,
        WHIP_SUPERCRACK_EPIC_CHANCE = .05,
        WHIP_SUPERCRACK_MONSTER_CHANCE = .2,
        WHIP_SUPERCRACK_CREATURE_CHANCE = .25,

        BULLKELP_ROOT_RANGE = 2.0,
        BULLKELP_ROOT_USE = 0.02,
        BULLKELP_ROOT_USE_VAR = 0.02,

        SPRING_COMBAT_MOD = 1.33,

        PINNABLE_WEAR_OFF_TIME = 10,
        PINNABLE_ATTACK_WEAR_OFF = 2.0,
        PINNABLE_RECOVERY_LEEWAY = 1.5,

        PIG_DAMAGE = 33,
        PIG_HEALTH = 250,
        PIG_ATTACK_PERIOD = 3,
        PIG_TARGET_DIST = 16,
		PIG_MAX_STUN_LOCKS = 2,
        PIG_LOYALTY_MAXTIME = 2.5*total_day_time,
        PIG_LOYALTY_POLITENESS_MAXTIME_BONUS = .5*total_day_time,
        PIG_LOYALTY_PER_HUNGER = total_day_time/25,
        PIG_MIN_POOP_PERIOD = seg_time * .5,

        PIG_TOKEN_CHANCE = 0.01,
        PIG_TOKEN_CHANCE_YOTP = .5,
        PIG_MINIGAME_ARENA_RADIUS = 12,
        PIG_MINIGAME_REQUIRED_TIME = seg_time * 4,
		PIG_MINIGAME_SCORE_GREAT = 0.6,
		PIG_MINIGAME_SCORE_GOOD = 0.3,
		PIG_MINIGAME_SCORE_BAD = 0.1,

        PIG_FULL_LOYALTY_PERCENT = 0.9,

		MINIGAME_CROWD_DIST_MIN = 12,
		MINIGAME_CROWD_DIST_TARGET = 14,
		MINIGAME_CROWD_DIST_MAX = 20,

        SPIDER_LOYALTY_MAXTIME = 2.5*total_day_time,
        SPIDER_LOYALTY_PER_HUNGER = total_day_time/25,

        WEREPIG_DAMAGE = 40,
        WEREPIG_HEALTH = 350 * 1.5, -- harder for multiplayer
        WEREPIG_ATTACK_PERIOD = 2,

        PIG_GUARD_DAMAGE = 33,
        PIG_GUARD_HEALTH = 300 * 2, -- harder for multiplayer
        PIG_GUARD_ATTACK_PERIOD = 1.5,
        PIG_GUARD_TARGET_DIST = 8,
        PIG_GUARD_DEFEND_DIST = 20,

        PIG_RUN_SPEED = 5,
        PIG_WALK_SPEED = 3,

        WEREPIG_RUN_SPEED = 7,
        WEREPIG_WALK_SPEED = 3,

        PIG_ELITE_RUN_SPEED = 9,
        PIG_ELITE_WALK_SPEED = 3,
        PIG_ELITE_HIT_RECOVERY = 1,
        PROP_WEAPON_RANGE = .5,

        PIG_ELITE_FIGHTER_DESPAWN_TIME = 10,
        PIG_ELITE_FIGHTER_DAMAGE = 45,
        PIG_ELITE_FIGHTER_ATTACK_PERIOD = 0.5,

--【★★ 猪国王小游戏区】490-504 行。
--  ★ 这 7 条英文注释是**设计说明**，记录了几个反直觉的规则：
--    · 掉落物回收延迟：防止玩家在被打败瞬间捡回装备
--    · 玩家比猪快：保证玩家不会被自己打的猪一直追着打
--    · high/low 之分：掉出手持槽(high)比掉出口袋(low)更快被捡
--  ★★ 这类「为什么要有这条反直觉规则」的注释，是本文件最有价值的部分，
--    记录了策划的意图，删掉以后没人知道为什么。
        --for pig king gold minigame
        --delay b4 pigs and players can pick up something recently knocked out of someone's inventory
--★ 逐条翻译上面那组设计说明：
--  「players are faster」—— 玩家移速高于猪，所以逃跑永远可行。
--    推论：任何「必须打赢」的遭遇战都会失败，设计上只能诱导逃跑。
        --players are faster
        --high is for stuff knocked out of the hand slot
        --low is for stuff knocked out of pockets
        KNOCKBACK_DROP_ITEM_HEIGHT_HIGH = 3,
        KNOCKBACK_DROP_ITEM_HEIGHT_LOW = 1,
        KNOCKBACK_DELAY_INTERACTION_HIGH = .6,
        KNOCKBACK_DELAY_INTERACTION_LOW = .45,
        KNOCKBACK_DELAY_PLAYER_INTERACTION_HIGH = .3,
        KNOCKBACK_DELAY_PLAYER_INTERACTION_LOW = .15,

        WILSON_WALK_SPEED = 4,
        WILSON_RUN_SPEED = 6,

		WILSON_EMBARK_SPEED_MIN = 4,
		WILSON_EMBARK_SPEED_MAX = 10,
		WILSON_EMBARK_SPEED_BOOST = 1.5,

		WILSON_HOP_DISTANCE_SHORT = 2.5,
		WILSON_HOP_DISTANCE = 4,
		WILSON_HOP_DISTANCE_FAR = 6,

        CRITTER_WALK_SPEED = 6,
--【★ 企鹅群参数】企鹅是「群居动物」模板的经典样本。
--  ★ 观察 514-519 行的成对结构（XXX_A 与 XXX_B 相邻）：
--     本文件处理「随机性」有两种标准手法：
--      (a) MIN_/MAX_ 或 XXX_MIN/XXX_MAX 成对 —— 实际值在区间内随机；
--      (b) {base=..., random=...} 嵌套表 —— base 为基准，random 为浮动量。
--    ★ 两者都不是「固定值」，调平衡时通常只需调 base。
        CRITTER_HUNGERTIME = total_day_time * 3.25,
        CRITTER_HUNGERTIME_MIN = total_day_time * 2,
        CRITTER_HUNGERTIME_MAX = total_day_time * 4.5,
        CRITTER_HUNGERTIME_DELTA = total_day_time * 0.5,
        CRITTER_EMOTE_DELAY = seg_time,
        CRITTER_NUZZLE_DELAY = total_day_time * 0.5,
        CRITTER_PLAYFUL_DELAY = seg_time * 0.4,
        CRITTER_COMBAT_LOOP_CHANCE = 0.33,
        CRITTER_WANTS_TO_BE_PET_TIME = seg_time * 0.5,

        CRITTER_TRAITS =
        {
            COMBAT          = {inc=0.003, decay=1.35},
            WELLFED         = {inc=0.70,  decay=.7},
            PLAYFUL         = {inc=0.32,  decay=.7},
            CRAFTY          = {inc=0.25,  decay=.9},
        },

        CRITTER_TRAIT_DECAY_DELAY = seg_time,
--【★★ CRITTER（小型生物）通用参数】533-542 行。
--  ★ 这一组是「参数化生物」设计的产物：小动物用同一套配置生成，
--    只改数值即可得到不同的物种行为。
--  CRITTER_HUNGERTIME = total_day_time*3.25 = 1560 秒（1.3 分钟现实时间）。
--    ★ 归一化写法：改时钟后小动物饥饿周期自动等比缩放，保持难度不变。
--  CRITTER_TRAIT_INITIAL_DOMINANT_DELAY = total_day_time*10
--    性格（trait）确立前的等待时间 = 10 个完整昼夜。
--    ★ 设计意图：让小动物先「表现中立」，稳定后才显出攻击性，
--      避免玩家刚放下兔子就被咬。
        CRITTER_TRAIT_INITIAL_DOMINANT_DELAY = total_day_time * 10,
        CRITTER_TRAIT_DOMINANT_DELAY = total_day_time * 4,
        CRITTER_TRAIT_DOMINANT_RETRY_DELAY = total_day_time * 2,
        CRITTER_TRAIT_DOMINANT_DELAY_VARIANCE = seg_time * 4,

        CRITTER_DOMINANTTRAIT_COMBAT_EMOTE_DELAY = seg_time * 0.25,
        CRITTER_DOMINANTTRAIT_COMBAT_LOOP_CHANCE = 0.75,
        CRITTER_DOMINANTTRAIT_PLAYFUL_EMOTE_DELAY = seg_time * 0.5,
        CRITTER_DOMINANTTRAIT_PLAYFUL_WITHOTHER_DELAY = seg_time * 0.1,
        CRITTER_DOMINANTTRAIT_HUNGERTIME_MIN = total_day_time * 3.25,
        CRITTER_DOMINANTTRAIT_HUNGERTIME_MAX = total_day_time * 5.5,

        PERD_SPAWNCHANCE = 0.1,
        PERD_DAMAGE = 20,
        PERD_HEALTH = 50,
        PERD_ATTACK_PERIOD = 3,
        PERD_RUN_SPEED = 8,
        PERD_WALK_SPEED = 3,

        WALRUS_DAMAGE = 33,
        WALRUS_HEALTH = 150 * 2, -- harder for multiplayer
        WALRUS_ATTACK_PERIOD = 3,
        WALRUS_ATTACK_DIST = 15,
        WALRUS_DART_RANGE = 25,
        WALRUS_MELEE_RANGE = 5,
        WALRUS_TARGET_DIST = 10,
        WALRUS_LOSETARGET_DIST = 30,
		WALRUS_MAX_STUN_LOCKS = 4,
        WALRUS_REGEN_PERIOD = total_day_time*2.5,
        WALRUS_REGEN_ENABLED = true,

        LITTLE_WALRUS_DAMAGE = 22,
        LITTLE_WALRUS_HEALTH = 100,
        LITTLE_WALRUS_ATTACK_PERIOD = 3 * 1.7,
        LITTLE_WALRUS_ATTACK_DIST = 15,

        PIPE_DART_DAMAGE = 100,
        YELLOW_DART_DAMAGE = 60,
        SLEEP_DART_SLEEPINESS = 1,
        SLEEP_DART_SLEEPTIME = 15,

        PENGUIN_DAMAGE = 33,
        PENGUIN_HEALTH = 150,
        PENGUIN_ATTACK_PERIOD = 3,
        PENGUIN_ATTACK_DIST = 2.5,
--【★ 生物分组命名规律】本区大量出现 XXX_1 / XXX_2 / XXX_3 的编号后缀，
--  它们对应「同一生物的不同等级/形态」。例如 BEARGER_1/2/3、TOADSTOOL_1/2/3。
--  ★ 读法：后缀越大越强韧，且**血量与伤害通常非线性递增**（防止等级差被数量弥补）。
--★ 另一类后缀：_HUNGRY / _ANGRY / _CHARGING 是**状态变体**，不是形态。
--  这两类别混淆：前者是「同一个体的不同阶段」，后者是「同一形态的暂时状态」。
        PENGUIN_MATING_SEASON_LENGTH = 6,
        PENGUIN_MATING_SEASON_WAIT = 1,
        PENGUIN_MATING_SEASON_BABYDELAY = total_day_time*1.5,
        PENGUIN_MATING_SEASON_BABYDELAY_VARIANCE = 0.5*total_day_time,
        PENGUIN_TARGET_DIST = 15,
        PENGUIN_CHASE_DIST = 30,
        PENGUIN_FOLLOW_TIME = 10,
        PENGUIN_HUNGER = total_day_time * 12,  -- takes all winter to starve
        PENGUIN_STARVE_TIME = total_day_time * 12,
        PENGUIN_STARVE_KILL_TIME = 20,

        MUTATED_PENGUIN_DAMAGE = 20,
		MUTATED_PENGUIN_HEALTH = 100,

        KNIGHT_DAMAGE = 40,
        KNIGHT_HEALTH = 300 * 3, -- harder for multiplayer
        KNIGHT_ATTACK_PERIOD = 2,
		KNIGHT_ATTACK_RANGE = 2.5,
		KNIGHT_HIT_RANGE = 2.75,
        KNIGHT_WALK_SPEED = 5,
        KNIGHT_TARGET_DIST = 10,
		KNIGHT_DODGE_HIT_RECOVERY = 2,

        BISHOP_DAMAGE = 40,
		BISHOP_INSULATED_DAMAGE_MULT = 0.5,
        BISHOP_HEALTH = 300 * 3, -- harder for multiplayer
        BISHOP_ATTACK_PERIOD = 4,
		BISHOP_ATTACK_DIST = 8,
        BISHOP_WALK_SPEED = 5,
        BISHOP_TARGET_DIST = 12,

		ROOK_DAMAGE = 90,
--【★ 乌鸦 ROOK 系列】609-612 行。
--  ROOK_DAMAGE_PLAYER_PERCENT = 0.5。
--  ★★ 注意单位：它是**百分比**而非绝对伤害，且键名里带 _PLAYER_，
--    即「对玩家造成当前血量 50% 的伤害」。
--    对比紧邻的 ROOK_DAMAGE = 90（对生物的绝对伤害）。
--    ★★ 同一个键 PAIR 表达两种不同单位的伤害，是本文件很值得注意的手法：
--      带_PLAYER_ 后缀 = 按玩家血量百分比（跨角色一致）
--      不带 = 固定数值（对生物）
--    ★ 命名约定识别法：含 _PLAYER_ 的键通常只影响玩家，含 _AI_ 的只影响 AI。
		ROOK_DAMAGE_PLAYER_PERCENT = 0.5,
        ROOK_HEALTH = 300 * 3, -- harder for multiplayer
        ROOK_ATTACK_PERIOD = 2,
        ROOK_WALK_SPEED = 5,
        ROOK_RUN_SPEED = 16,
        ROOK_TARGET_DIST = 12,
		ROOK_RUN_HIT_RECOVERY = 2,

        MINOTAUR_DAMAGE = 100,
        MINOTAUR_HEALTH = 2500 * 4, -- harder for multiplayer
        MINOTAUR_ATTACK_PERIOD = 2,
        MINOTAUR_WALK_SPEED = 5,
        MINOTAUR_RUN_SPEED = 17,
        MINOTAUR_TARGET_DIST = 25,
		MINOTAUR_LEAP_CD = 10,

        SLURTLE_DAMAGE = 25,
        SLURTLE_HEALTH = 600 * 2, -- harder for multiplayer
        SLURTLE_ATTACK_PERIOD = 4,
        SLURTLE_ATTACK_DIST = 2.5,
        SLURTLE_WALK_SPEED = 3,
        SLURTLE_TARGET_DIST = 10,
        SLURTLE_SHELL_ABSORB = 0.95,
        SLURTLE_DAMAGE_UNTIL_SHIELD = 150,

        SLURTLE_EXPLODE_DAMAGE = 300,
        SLURTLESLIME_EXPLODE_DAMAGE = 50,

        SNURTLE_WALK_SPEED = 4,
        SNURTLE_DAMAGE = 5,
        SNURTLE_HEALTH = 200,
        SNURTLE_SHELL_ABSORB = 0.8,
        SNURTLE_DAMAGE_UNTIL_SHIELD = 10,
        SNURTLE_EXPLODE_DAMAGE = 300,

        SLURPER_WALKSPEED = 9,
        SLURPER_HEALTH = 200,
        SLURPER_DAMAGE = 30,
        SLURPER_ATTACK_DIST = 8,
        SLURPER_ATTACK_PERIOD = 5,

        LIGHTNING_DAMAGE = 10,
        LIGHTNING_STRIKE_RADIUS = 3,
		PLAYER_LIGHTNING_TARGET_CHANCE = 0.3,
		WX78_LIGHTNING_TARGET_CHANCE = 1.0,
		WES_LIGHTNING_TARGET_CHANCE = 0.6,

        ELECTRIC_WET_DAMAGE_MULT = 1,
        ELECTRIC_DAMAGE_MULT = 1.5,

        LIGHTNING_GOAT_DAMAGE = 25,
        LIGHTNING_GOAT_HEALTH = 350 * 2, -- harder for multiplayer
        LIGHTNING_GOAT_ATTACK_RANGE = 3,
        LIGHTNING_GOAT_ATTACK_PERIOD = 2,
        LIGHTNING_GOAT_WALK_SPEED = 4,
        LIGHTNING_GOAT_RUN_SPEED = 8,
        LIGHTNING_GOAT_TARGET_DIST = 8,
        LIGHTNING_GOAT_CHASE_DIST = 30,
        LIGHTNING_GOAT_FOLLOW_TIME = 30,
--【LIGHTNING_GOAT_MATING_SEASON_BABYDELAY = total_day_time*1.5】
--  ★「季节」相关的时间一律以 total_day_time 为单位 —— 因为季节也是
--    以「天」计的（见 2218-2221 行的四季天数）。
--    这一条把「季节」和「昼夜」两个时间体系对齐了，是很好的设计。
        LIGHTNING_GOAT_MATING_SEASON_BABYDELAY = total_day_time*1.5,
        LIGHTNING_GOAT_MATING_SEASON_BABYDELAY_VARIANCE = 0.5*total_day_time,

		LIGHTNINGGOATHERD_MAX_SIZE = 6,

        DEER_DAMAGE = 25,
        DEER_HEALTH = 350 * 2, -- harder for multiplayer
        DEER_ATTACK_RANGE = 3,
        DEER_ATTACK_PERIOD = 2,
        DEER_ATTACKER_REMEMBER_DIST = 20,
        DEER_WALK_SPEED = 2.5,
        DEER_RUN_SPEED = 8,
		DEER_HIT_RECOVERY = 1,
		DEER_MAX_STUN_LOCKS = 4,

        DEER_HERD_MOVE_DIST = 10,

        DEER_GEMMED_DAMAGE = 50,
        DEER_GEMMED_HEALTH = 1500,
        DEER_GEMMED_AGGRO_DIST = 10,
        DEER_GEMMED_FIRST_CAST_CD = 4,
        DEER_GEMMED_CAST_RANGE = 12,
        DEER_GEMMED_CAST_MAX_RANGE = 15,
        DEER_GEMMED_MAX_SPELLS = 6,

        DEER_ICE_BURN_PANIC_TIME = 10,
        DEER_ICE_SPEED_PENALTY = .4,
        DEER_ICE_TEMPERATURE = -2,
        DEER_ICE_FATIGUE = .1,
        DEER_ICE_FREEZE_LOCK_FRAMES = 30,
        DEER_ICE_CAST_CD = 10,

        DEER_FIRE_FREEZE_WEAR_OFF_TIME = 5,
        DEER_FIRE_TEMPERATURE = 72, --must be higher than OVERHEAT_TEMP
        DEER_FIRE_IGNITE_FRAMES = 30,
        DEER_FIRE_CAST_CD = 8,

        KLAUS_HEALTH = 10000,
        KLAUS_HEALTH_REGEN = 25, --per second (only when not in combat)
        KLAUS_HEALTH_REZ = .5,
        KLAUS_DAMAGE = 75,
        KLAUS_ATTACK_PERIOD = 3,
        KLAUS_ATTACK_RANGE = 3,
        KLAUS_HIT_RANGE = 4,
        KLAUS_SPEED = 2.75,
        KLAUS_HIT_RECOVERY = 1,

        KLAUS_ENRAGE_SCALE = 1.4,

        KLAUS_NAUGHTY_MIN_SPAWNS = 2,
        KLAUS_NAUGHTY_MAX_SPAWNS = 6,

        KLAUS_COMMAND_CD = 6,

        KLAUS_CHOMP_CD = 6,
        KLAUS_CHOMP_MIN_RANGE = 4.5,
        KLAUS_CHOMP_RANGE = 7,
        KLAUS_CHOMP_MAX_RANGE = 9, --for scaling
        KLAUS_CHOMP_HIT_RANGE = 3.5,

        KLAUS_AGGRO_DIST = 15,
        KLAUS_DEAGGRO_DIST = 30,
        KLAUS_EPICSCARE_RANGE = 10,

        KLAUSSACK_EVENT_RESPAWN_TIME = total_day_time * 20, -- winters feast event respawn time
        KLAUSSACK_RESPAWN_DELAY = total_day_time * 10,
        KLAUSSACK_SPAWN_DELAY = total_day_time * 1,
        KLAUSSACK_SPAWN_DELAY_VARIANCE = total_day_time * 2,
        KLAUSSACK_MAX_SPAWNS = 1,
        SPAWN_KLAUS = true,

--【★ 秃鹫 BUZZARD 系列】745-750 行。
--  ★★ 这里出现了另一个全局乘数：BUZZARD_REGEN_PERIOD（第 747 行）
--    = total_day_time*3*multiplayer_wildlife_respawn_modifier。
--    第 35 行 multiplayer_wildlife_respawn_modifier = 1（当前未打折），
--    且英文原注释保留了历史值 '--2'。
--    ★★ 这说明该乘数是**为未来多人平衡预留的接口**：一旦要削弱联机刷资源
--      的优势，把这一处改成 2 即可全局生效，无需改每个生物。
--    ★ 这是本文件「上游统一打折」设计思路的又一例证（对照第 31-35 行）。
--  BUZZARD_SPAWN_PERIOD = seg_time*1.5 = 45 秒。
--    seg_time 的另一用途：短周期刷新频率。
--  BUZZARD_SPAWN_VARIANCE = seg_time*0.5 = 15 秒 —— 刷新时间的随机浮动量。
--  ★ 注意血量 125*2：多人群系生物血量普遍乘以 2~3（第 611、3000 行同款写法），
--    因为多人分摊伤害，单人血量必须更高才不会「一击秒」。
        BUZZARD_DAMAGE = 15,
        BUZZARD_ATTACK_RANGE = 2,
        BUZZARD_ATTACK_PERIOD = 2,
        BUZZARD_WALK_SPEED = 4,
        BUZZARD_RUN_SPEED = 8,
        BUZZARD_HEALTH = 125 * 2, -- harder for multiplayer

        BUZZARD_REGEN_PERIOD = total_day_time*3*multiplayer_wildlife_respawn_modifier,
        BUZZARD_SPAWN_PERIOD = seg_time*1.5,
        BUZZARD_SPAWN_VARIANCE = seg_time*0.5,

        FREEZING_KILL_TIME = 120,
        STARVE_KILL_TIME = 120,
        HUNGRY_THRESH = .333,
        GHOST_THRESH = .125,

        HUNGRY_BUILDER_DELTA = -5,
        HUNGRY_BUILDER_RESET_TIME = seg_time * 2,
        HUNGRY_BUILDER_RESET_DISTANCE_SQ = 4 * 4, -- A tile distance.

        GRUEDAMAGE = wilson_health*.667,

        MARSHBUSH_DAMAGE = wilson_health*.02,
        CACTUS_DAMAGE = wilson_health*.04,
        ROSE_DAMAGE = 1,

        GHOST_SPEED = 2,
        GHOST_HEALTH = 200,
        GHOST_RADIUS = 1.5,
        GHOST_DAMAGE = wilson_health*0.1,
        GHOST_DMG_PERIOD = 1.2,
        GHOST_DMG_PLAYER_PERCENT = 1,
        GHOST_LIGHT_OVERRIDE = .5,
        GHOST_GRAVESTONE_CHANCE = 0.05,
        GHOST_FOLLOW_DSQ = 30 * 30, -- Used in ghost.lua and ghostbrain.lua
        GHOST_SISTURN_CHANCE_PER_DECOR = 0.05,

        COOKINGRECIPECARD_GRAVESTONE_CHANCE = 0.1,
        SCRAPBOOK_PAGE_GRAVESTONE_CHANCE = 0.1,

--【★ 分区 4 → 5 交界：树叶与季节生长】775-800 行。
--  ★★ 这里是「季节影响植被」的核心：MIN_LEAF_CHANGE_TIME = .1*day_time
--    = 30 秒，即每半分钟换一次落叶强度，玩家能看到地上颜色在变。
--    对照 MAX_LEAF_CHANGE_TIME = 3*day_time = 900 秒（15 分钟）。
--    一快一慢构成「随机刷新间隔」：实际取值落在 30~900 秒之间。
--  ★★ MIN_/MAX_ 成对出现是本文件表达「区间」的固定手法，全文大量使用。
--  ★★ 紧随其后的EVERGREEN_GROW_TIME（786 行起）是**四元嵌套表模板**，
--    必须理解其结构才能读懂后面的同类键：
--      外层 = 植物种类（如 EVERGREEN 常年青、TWIGGY 细枝松树）
--      中层 = 该植物的四个生长阶段：short / normal / tall / old
--      内层 = {base=N*分母, random=M*分母} 表示「在该阶段停留的时长，
--            在 base 到 base+random 之间随机」。
--    例如第 788 行 {base=1.5*day_time, random=0.5*day_time} --short
--    = 幼苗期持续 450~600 秒（7.5~10 分钟现实时间）。
--    ★★ 注意 random 项的**语义是「浮动量」不是「上限值」**，
--      所以真实上限是 base+random（600 秒），而非 random（150 秒）。
--      这个区别很容易读错，是本文件最值得单独记的约定。
--    同样的四元模板在 841（TALLBIRD 类）、3578、3850、8902 反复出现。
        MIN_LEAF_CHANGE_TIME = .1 * day_time,
        MAX_LEAF_CHANGE_TIME = 3 * day_time,
        MIN_SWAY_FX_FREQUENCY = 1 * seg_time,
        MAX_SWAY_FX_FREQUENCY = 2 * seg_time,
        SWAY_FX_FREQUENCY = 1 * seg_time,

        EVERGREEN_GROW_TIME =
        {
            {base=1.5*day_time, random=0.5*day_time},   --short
            {base=5*day_time, random=2*day_time},   --normal
            {base=5*day_time, random=2*day_time},   --tall
            {base=1*day_time, random=0.5*day_time}   --old
        },
        TWIGGY_TREE_GROW_TIME =
        {
            {base=1.5*day_time, random=0.5*day_time},   --short
            {base=3*day_time, random=1*day_time},   --normal
            {base=3*day_time, random=1*day_time},   --tall
            {base=5*day_time, random=0.5*day_time}   --old
        },
        PINECONE_GROWTIME = {base=0.75*day_time, random=0.25*day_time},
--【分区 5 · 敌对生物与夜间威胁】801-1300 行
--  ★ 分区边界：进入蜘蛛、蝙蝠、黄蜂、触手等真正的敌对阵营。
--  ★★ 本区的核心设计特征是「阶段化」：几乎每个强力生物都有 3 个阶段，
--    且阶段转换条件（血量阈值/数量阈值）也写在 TUNING 里。
--    这使得「血量降到 X 就进入 Y 阶段」这种逻辑完全数据驱动。
        EVERGREEN_CHOPS_SMALL = 5,
        EVERGREEN_CHOPS_NORMAL = 10,
        EVERGREEN_CHOPS_TALL = 15,

        DECIDUOUS_GROW_TIME =
        {
            {base=1.5*day_time, random=0.5*day_time},   --short
            {base=5*day_time, random=2*day_time},   --normal
            {base=5*day_time, random=2*day_time},   --tall
            {base=1*day_time, random=0.5*day_time}   --old
        },
        ACORN_GROWTIME = {base=0.75*day_time, random=0.25*day_time},
        DECIDUOUS_CHOPS_SMALL = 5,
        DECIDUOUS_CHOPS_NORMAL = 10,
        DECIDUOUS_CHOPS_TALL = 15,
        DECIDUOUS_CHOPS_MONSTER = 12 * 1.5, -- harder for multiplayer

        MUSHTREE_CHOPS_SMALL = 10,
        MUSHTREE_CHOPS_MEDIUM = 10,
        MUSHTREE_CHOPS_TALL = 15,
        MUSHTREE_WEBBED_SPIDER_RADIUS = 20,
        MUSHTREE_WEBBED_MAX_PER_DEN = 6,

        MUSHSPORE_PERISH_TIME = seg_time * 3,
        MUSHSPORE_MAX_DENSITY = 10,
        MUSHSPORE_MAX_DENSITY_RAD = 20,
        MUSHSPORE_DENSITY_CHECK_TIME = 15,
        MUSHSPORE_DENSITY_CHECK_VAR = 15,

        MUSHROOMHAT_SPORE_TIME = seg_time * 2,
        MUSHROOMHAT_SLOW_HUNGER = 0.75,
        MUSHROOMHAT_MOONSPORE_TIME = 1.5,
        MUSHROOMHAT_MOONSPORE_TIME_VARIANCE = 0.25,
        MUSHROOMHAT_MOONSPORE_RETALIATION_SPORE_COUNT = 3,
        MUSHROOMHAT_MOONSPORE_RETALIATION_SPORE_DELAY = 0.25,

        MARBLESHRUB_MINE_SMALL = 6,  -- why are you even mining at this stage?
        MARBLESHRUB_MINE_NORMAL = 8, -- same as MARBLETREE_MINE
        MARBLESHRUB_MINE_TALL = 10,  -- same as MARBLEPILLAR_MINE
        MARBLESHRUB_GROW_TIME =
        {
            {base=9.0*day_time, random=1.0*day_time}, --short
            {base=9.0*day_time, random=1.0*day_time}, --normal
            {base=9.0*day_time, random=1.0*day_time}, --tall
        },

        ICE_MINE = 3,
        ROCKS_MINE = 6,
        ROCKS_MINE_MED = 4,
        ROCKS_MINE_LOW = 2,
        SPILAGMITE_SPAWNER = 2,
        SPILAGMITE_ROCK = 4,
        MARBLEPILLAR_MINE = 10,
        MARBLETREE_MINE = 8,
        CAVEIN_BOULDER_MINE = 3,
        SEASTACK_MINE = 9,
		SEACOCOON_MINE = 1,
		SHELL_CLUSTER_MINE = 3,

        SKELETON_WORK = 3,

        PETRIFIED_TREE_SMALL = 2,
        PETRIFIED_TREE_NORMAL = 3,
        PETRIFIED_TREE_TALL = 4,
        PETRIFIED_TREE_OLD = 1,

        BEEFALO_HEALTH = 500 * 2, -- harder for multiplayer.,
        BEEFALO_HEALTH_REGEN_PERIOD = 10,
        BEEFALO_HEALTH_REGEN = (500 * 2)/(total_day_time*3)*10,
        BEEFALO_DAMAGE =
        {
            DEFAULT = 34,
            RIDER = 25,
            ORNERY = 50,
            PUDGY = 20,
        },
        BEEFALO_MATING_SEASON_LENGTH = 3,
        BEEFALO_MATING_SEASON_WAIT = 20,
        BEEFALO_MATING_ENABLED = true,
        BEEFALO_MATING_ALWAYS = false,
        BEEFALO_MATING_SEASON_BABYDELAY = total_day_time*1.5,
        BEEFALO_MATING_SEASON_BABYDELAY_VARIANCE = 0.5*total_day_time,
        BEEFALO_TARGET_DIST = 5,
        BEEFALO_CHASE_DIST = 30,
        BEEFALO_FOLLOW_TIME = 30,
        BEEFALO_HUNGER = (calories_per_day*4)/0.8, -- so a 0.8 fullness lasts a day
        BEEFALO_HUNGER_RATE = (calories_per_day*4)/total_day_time,
        BEEFALO_WALK_SPEED = 1.0,
        BEEFALO_RUN_SPEED =
        {
            DEFAULT = 7,
            RIDER = 8.0,
            ORNERY = 7.0,
            PUDGY = 6.5,
        },
        BEEFALO_HAIR_GROWTH_DAYS = 3,
        BEEFALO_BEARD_BITS = 3,
        BEEFALO_SADDLEABLE_OBEDIENCE = 0.1,
        BEEFALO_KEEP_SADDLE_OBEDIENCE = 0.4,
        BEEFALO_MIN_BUCK_OBEDIENCE = 0.5,
        BEEFALO_MIN_BUCK_TIME = 50,
        BEEFALO_MAX_BUCK_TIME = 800,
        BEEFALO_BUCK_TIME_VARIANCE = 3,
        BEEFALO_MIN_DOMESTICATED_OBEDIENCE =
        {
            DEFAULT = 0.8,
            ORNERY = 0.45,
            RIDER = 0.95,
            PUDGY = 0.6,
        },
        BEEFALO_BUCK_TIME_MOOD_MULT = 0.2,
        BEEFALO_BUCK_TIME_UNDOMESTICATED_MULT = 0.3,
        BEEFALO_BUCK_TIME_NUDE_MULT = 0.2,

        BEEFALO_BEG_HUNGER_PERCENT = 0.45,

        BEEFALO_DOMESTICATION_STARVE_OBEDIENCE = -1/(total_day_time*1),
        BEEFALO_DOMESTICATION_FEED_OBEDIENCE = 0.1,
        BEEFALO_DOMESTICATION_OVERFEED_OBEDIENCE = -0.3,
        BEEFALO_DOMESTICATION_ATTACKED_BY_PLAYER_OBEDIENCE = -1,
        BEEFALO_DOMESTICATION_BRUSHED_OBEDIENCE = 0.4,
        BEEFALO_DOMESTICATION_SHAVED_OBEDIENCE = -1,

        BEEFALO_DOMESTICATION_LOSE_DOMESTICATION = -1/(total_day_time*4),
        BEEFALO_DOMESTICATION_GAIN_DOMESTICATION = 1/(total_day_time*20),
        BEEFALO_DOMESTICATION_MAX_LOSS_DAYS = 10, -- days
        BEEFALO_DOMESTICATION_OVERFEED_DOMESTICATION = -0.01,
        BEEFALO_DOMESTICATION_ATTACKED_DOMESTICATION = 0,
        BEEFALO_DOMESTICATION_ATTACKED_OBEDIENCE = -0.01,
--【★★ 驯服度（DOMESTICATION）参数组】926-940 行。
--  ★★ 这是本文件符号约定最容易踩坑的地方，务必逐条区分：
--    BEEFALO_DOMESTICATION_MAX_LOSS_DAYS = 10
--      —— 驯服度归零后需要 10 天才会变成敌对（野牛重获野性）。
--    BEEFALO_DOMESTICATION_OVERFEED_DOMESTICATION = -0.01
--      —— 喂太饱反而**降低**驯服度（-0.01/次）。
--      ★ 反直觉点：喂牛喂多了它反而不听话。设计意图是「别无脑塞饲料」，
--        逼迫玩家也去吃。这是 DST 少见的「惩罚正解行为」的数值。
--    BEEFALO_DOMESTICATION_ATTACKED_DOMESTICATION = 0
--      —— 被攻击时驯服度**不变**（0）。
--    BEEFALO_DOMESTICATION_ATTACKED_OBEDIENCE = -0.01
--      —— 被攻击时「服从度」下降 -0.01。
--      ★★ 关键：DOMESTICATION（驯服/亲密度）与 OBEDIENCE（服从/指令响应）
--        是**两个独立维度**。马戏团可以随时使唤牛（服从），
--        但那不代表它喜欢你（驯服）。命名相近但语义不同，
--        ★ 这是本文件里一对极其容易误解的键。
--    BEEFALO_DOMESTICATION_ATTACKED_BY_PLAYER_DOMESTICATION = -0.3
--      —— **被玩家**攻击才掉 0.3；被蜘蛛攻击不掉。
--      ★ 设计意图：只惩罚玩家自己的行为，不惩罚环境。
--    BEEFALO_DOMESTICATION_BRUSHED_DOMESTICATION = (1-(15/20))/15
--      —— 刷毛（用刷子）提升驯服度。这个公式直接把「天数比例」写进了式子。
--      ★★ 公式注释 '(1-(targetdays/basedays))/targetdays' 说明其含义：
--        距离目标驯养天数越近，每次刷毛收益越高 —— 越接近满值越难升。
--        这是一种**边际递减**设计，让「快满了」的牛仍值得照顾。
--  ★★ 综合符号约定：负值 = 减少，正值 = 增加，0 = 不变。
--    但注意 OVERFEED 的 -0.01 与 ATTACKED_BY_PLAYER 的 -0.3
--    相差 30 倍 —— 说明「喂食」的惩罚是刻意设计得很轻的。
        BEEFALO_DOMESTICATION_ATTACKED_BY_PLAYER_DOMESTICATION = -0.3,
        BEEFALO_DOMESTICATION_BRUSHED_DOMESTICATION = (1-(15/20))/15, -- (1-(targetdays/basedays))/targetdays

        BEEFALO_PUDGY_WELLFED = 1/(total_day_time*5),
        BEEFALO_PUDGY_OVERFEED = 0.02,
        BEEFALO_RIDER_RIDDEN = 1/(total_day_time*5),
        BEEFALO_ORNERY_DOATTACK = 0.004,
        BEEFALO_ORNERY_ATTACKED = 0.004,

        BEEFALOHERD_RANGE = 40,
        BEEFALOHERD_MAX_IN_RANGE = 16,

        BABYBEEFALO_HEALTH = 300,
        BABYBEEFALO_GROW_TIME = {base=3*day_time, random=2*day_time},

        KOALEFANT_HEALTH = 500 * 2, -- harder for multiplayer
        KOALEFANT_DAMAGE = 50,
        KOALEFANT_TARGET_DIST = 5,
        KOALEFANT_CHASE_DIST = 30,
        KOALEFANT_FOLLOW_TIME = 30,

        SPAT_HEALTH = 800,
        SPAT_PHLEGM_DAMAGE = 5,
        SPAT_PHLEGM_ATTACKRANGE = 12,
        SPAT_PHLEGM_RADIUS = 4,
        SPAT_MELEE_DAMAGE = 60,
        SPAT_MELEE_ATTACKRANGE = 0.5,
        SPAT_TARGET_DIST = 10,
        SPAT_CHASE_DIST = 30,
        SPAT_FOLLOW_TIME = 30,

        HUNT_SPAWN_DIST = PLAYER_CAMERA_SEE_DISTANCE,
        HUNT_COOLDOWN = total_day_time*1.2,
        HUNT_COOLDOWNDEVIATION = total_day_time*0.3,
        HUNT_ALTERNATE_BEAST_CHANCE_MIN = 0.05,
        HUNT_ALTERNATE_BEAST_CHANCE_MAX = 0.33,
        HUNT_SCORE_TIME_PER_NODE = 8,
        HUNT_SCORE_TIME_PER_NODE_MAX = 10, -- Keep below 1.25 * SEG_TIME
        HUNT_SCORE_PROP_RATIO = 0.25,
        HUNT_SCORE_SLEEP_RATIO = 0.4, -- Keep bigger than HUNT_SCORE_PROP_RATIO.

        HUNT_RESET_TIME = 5,
        HUNT_SPRING_RESET_TIME = total_day_time * 3,
        MIN_JOINED_HUNT_DISTANCE = 200, -- if you`re under this distance to an active hunt, you won`t get one

        TRACK_ANGLE_DEVIATION = 30,
        MIN_HUNT_DISTANCE = 300, -- you can't find a new beast without being at least this far from the last one
        MAX_DIRT_DISTANCE = 200, -- if you get this far away from your dirt pile, you probably aren't going to see it any time soon, so remove it and place a new one

        BAT_DAMAGE = 20,
        BAT_HEALTH = 50,
        BAT_ATTACK_PERIOD = 1,
        BAT_ATTACK_DIST = 1.5,
        BAT_WALK_SPEED = 8,
        BAT_TARGET_DIST = 8,
        BAT_ESCAPE_TIME = 60,
        BAT_ESCAPE_RADIUS = 40,

        BATCAVE_REGEN_PERIOD = seg_time * 4,
        BATCAVE_SPAWN_PERIOD = 20,
        BATCAVE_MAX_CHILDREN = 4,
        BATCAVE_ENABLED = true,

        CAVE_ENTRANCE_BATS_REGEN_PERIOD = seg_time * 2,
        CAVE_ENTRANCE_BATS_SPAWN_PERIOD = 1,
        CAVE_ENTRANCE_BATS_MAX_CHILDREN = 6,
        CAVE_ENTRANCE_BATS_ENABLED = true,

        SPIDER_HEALTH = 100,
        SPIDER_DAMAGE = 20,
--【★ 蜘蛛 SPIDER_ATTACK_PERIOD = 3】攻击间隔 3 秒。
--  ★ 绝对值写法的典型：玩家感知的是「几下打死一只蜘蛛」，
--    与游戏内过了几天无关，所以这里不需要归一化。
--    ★ 见文件头「判据」：与玩家操作事件挂钩的量用绝对值。
        SPIDER_ATTACK_PERIOD = 3,
        SPIDER_TARGET_DIST = 4,
        SPIDER_INVESTIGATETARGET_DIST = 6,
        SPIDER_WAKE_RADIUS = 4,
        SPIDER_FLAMMABILITY = .33,
        SPIDER_SUMMON_WARRIORS_RADIUS = 12,
        SPIDER_EAT_DELAY = 1.5,

        SPIDER_WALK_SPEED = 3,
        SPIDER_RUN_SPEED = 5,

        SPIDER_WARRIOR_HEALTH = 200 * 2, -- harder for multiplayer
        SPIDER_WARRIOR_DAMAGE = 20,
        SPIDER_WARRIOR_ATTACK_PERIOD = 4,
        SPIDER_WARRIOR_ATTACK_RANGE = 6,
        SPIDER_WARRIOR_HIT_RANGE = 3,
        SPIDER_WARRIOR_MELEE_RANGE = 3,
        SPIDER_WARRIOR_TARGET_DIST = 10,
        SPIDER_WARRIOR_WAKE_RADIUS = 6,

        SPIDER_WARRIOR_WALK_SPEED = 4,
        SPIDER_WARRIOR_RUN_SPEED = 5,

        SPIDER_HIDER_HEALTH = 150 * 1.5, -- harder for multiplayer
        SPIDER_HIDER_DAMAGE = 20,
        SPIDER_HIDER_ATTACK_PERIOD = 3,
        SPIDER_HIDER_WALK_SPEED = 3,
        SPIDER_HIDER_RUN_SPEED = 5,
        SPIDER_HIDER_SHELL_ABSORB = 0.75,

        SPIDER_SPITTER_HEALTH = 175 * 2, -- harder for multiplayer
        SPIDER_SPITTER_DAMAGE_MELEE = 20,
        SPIDER_SPITTER_DAMAGE_RANGED = 20,
        SPIDER_SPITTER_ATTACK_PERIOD = 5,
        SPIDER_SPITTER_ATTACK_RANGE = 5,
        SPIDER_SPITTER_MELEE_RANGE = 2,
        SPIDER_SPITTER_HIT_RANGE = 3,
        SPIDER_SPITTER_WALK_SPEED = 4,
        SPIDER_SPITTER_RUN_SPEED = 5,

		SPIDER_MOON_HEALTH = 250,
		SPIDER_MOON_DAMAGE = 25,
		SPIDER_MOON_SPIKE_DAMAGE = 10,
		SPIDER_MOON_ATTACK_PERIOD = 3,

        LEIF_HEALTH = 2000 * 1.5, -- harder for multiplayer
        LEIF_DAMAGE = 150,
        LEIF_DAMAGE_PLAYER_PERCENT = .33,
        LEIF_ATTACK_PERIOD = 3,
        LEIF_FLAMMABILITY = .333,
		LEIF_HIT_RECOVERY = 1.5,

        LEIF_MIN_DAY = 3,
        LEIF_PERCENT_CHANCE = 1/75,
        LEIF_MAXSPAWNDIST = 15,

        LEIF_PINECONE_CHILL_CHANCE_CLOSE = .33,
        LEIF_PINECONE_CHILL_CHANCE_FAR = .15,
        LEIF_PINECONE_CHILL_CLOSE_RADIUS = 5,
        LEIF_PINECONE_CHILL_RADIUS = 16,
        LEIF_REAWAKEN_RADIUS = 20,

        LEIF_BURN_TIME = 10,
        LEIF_BURN_DAMAGE_PERCENT = 1/8,

        DEERCLOPS_HEALTH = 2000 * 2, -- harder for multiplayer
        DEERCLOPS_DAMAGE = 150,
        DEERCLOPS_DAMAGE_PLAYER_PERCENT = .5,
        DEERCLOPS_ATTACK_PERIOD = 4,
        DEERCLOPS_ATTACK_RANGE = 8,
        DEERCLOPS_AOE_RANGE = 12,-- 6,
        DEERCLOPS_AOE_SCALE = 0.8,
        DEERCLOPS_LOSE_TARGET_PERIOD = 60,

        BIRD_SPAWN_MAX = 4,
        BIRD_SPAWN_DELAY = {min=5, max=15},
        BIRD_SPAWN_MAX_FEATHERHAT = 7,                   -- DEPRECATED
        BIRD_SPAWN_DELAY_FEATHERHAT = {min=2, max=10},   -- DEPRECATED
        BIRD_SPAWN_MAXDELTA_FEATHERHAT = 3,
        BIRD_SPAWN_DELAYDELTA_FEATHERHAT = {MIN = -3, MAX = -5},
        BIRD_SEE_THREAT_DISTANCE = 5,

        FROG_RAIN_DELAY = {min=0.1, max=2},
        FROG_RAIN_SPAWN_RADIUS = 60,
        FROG_RAIN_MAX = 300,
        FROG_RAIN_LOCAL_MIN = 12,
        FROG_RAIN_LOCAL_MAX = 35,
        FROG_RAIN_LOCAL_MIN_ADVENTURE = 10,
        FROG_RAIN_LOCAL_MAX_ADVENTURE = 25,
        FROG_RAIN_MAX_RADIUS = 50,
        FROG_RAIN_PRECIPITATION = 0.55, -- 0-1, 0.8 by default (old "often" setting for Adventure)
        FROG_RAIN_MOISTURE = 2500, -- 0-4000ish, 2500 by default (old "often" setting for Adventure)
        FROG_RAIN_CHANCE = 0.16,

        BEE_HEALTH = 100,
        BEE_DAMAGE = 10,
        BEE_ATTACK_RANGE = .6,
        BEE_ATTACK_PERIOD = 2,
        BEE_TARGET_DIST = 8,
        BEE_ALLERGY_EXTRADAMAGE = 10,

        BEEMINE_BEES = 4,
        BEEMINE_RADIUS = 3,

--【★★ 蛛巢生长时序表】SPIDERDEN_GROW_TIME = {day_time*8, day_time*8, day_time*20}
--  ★ 三元数组 = 三个阶段的时长：阶段1=2400秒、阶段2=2400秒、阶段3=6000秒。
--  ★★ 英文原注释 '--[3] is now unused.' 说明第 3 阶段已废弃。
--    ⚠ 疑似缺陷（冗余项）：第 3 项保留了数值但已无引用。
--    推理依据：原注释直接标注 unused，且前两项相同、只有第三项不同，
--    说明它是历史版本遗留。不影响运行（Lua 数组多一项无害），
--    但调数值时容易误以为「三阶段都在用」而改错地方。
--  ★ 引用本表的组件：components/spiderden.lua。
        SPIDERDEN_GROW_TIME = {day_time*8, day_time*8, day_time*20}, --[3] is now unused.
        SPIDERDEN_GROW_TIME_QUEEN = day_time*20,
        SPIDERDEN_QUEEN_CAP = 4,
        SPIDERDEN_QUEEN_RANGE_CHECK = 60,
        SPIDERDEN_HEALTH = {50*5, 50*10, 50*20},
        SPIDERDEN_SPIDERS = {3, 6, 9},
        SPIDERDEN_WARRIORS = {0, 1, 3},  -- every hit, release up to this many warriors, and fill remainder with regular spiders
        SPIDERDEN_EMERGENCY_WARRIORS = {0, 4, 8}, -- the max "bonus" spiders, one per player
        SPIDERDEN_EMERGENCY_RADIUS = {10, 15, 20},
        SPIDERDEN_SPIDER_TYPE = {"spider", "spider_warrior", "spider_warrior"},
--【★ SPIDERDEN_REGEN_TIME = 3*seg_time = 90 秒】蛛巢 90 秒再生一个。
--  ★ 极短周期资源：洞穴蜘蛛蛋是重要食物，必须能持续获取，
--    否则玩家在洞穴会断粮。
        SPIDERDEN_REGEN_TIME = 3*seg_time,
        SPIDERDEN_RELEASE_TIME = 5,
        SPIDERDEN_ENABLED = true,
        SPAWN_SPIDER_WARRIORS = true,

        HOUNDMOUND_HOUNDS_MIN = 2,
        HOUNDMOUND_HOUNDS_MAX = 3,
        HOUNDMOUND_REGEN_TIME = seg_time * 6,
        HOUNDMOUND_RELEASE_TIME = seg_time,
        HOUNDMOUND_ENABLED = true,

        POND_FROGS = 4,
--【★ POND_REGEN_TIME = day_time/2 = 150 秒】池塘再生。
--  ★★ 对比第 1114 行的 3*seg_time（90 秒）：
--    两者都是「再生时间」，却分别用seg_time 和 day_time 作分母。
--    这正是文件头警告的「分母混用」实例 —— 数值本身都合理，
--    但**同一语义的不同实例用了不同分母**，改时钟时需要逐个核对。
--★ 判断方法：数值大小相近（90 vs 150 秒）但写法不同，就是典型信号。
        POND_REGEN_TIME = day_time/2,
        POND_SPAWN_TIME = day_time/4,
        FROG_POND_REGEN_TIME = day_time/2,
        FROG_POND_SPAWN_TIME = day_time/4,
        FROG_POND_CHILDREN = {min = 3, max = 4},
        FROG_POND_ENABLED = true,
        MOSQUITO_POND_REGEN_TIME = day_time/2,
        MOSQUITO_POND_SPAWN_TIME = day_time/4,
        MOSQUITO_POND_CHILDREN = {min = 3, max = 4},
        MOSQUITO_POND_ENABLED = true,
        POND_RETURN_TIME = day_time*3/4,
        FISH_RESPAWN_TIME = day_time/3,

        BEEHIVE_BEES = 5,
        BEEHIVE_EMERGENCY_BEES = 8,
        BEEHIVE_EMERGENCY_RADIUS = 20,
        BEEHIVE_RELEASE_TIME = day_time/6,
        BEEHIVE_REGEN_TIME = seg_time,
        BEEHIVE_ENABLED = true,
        BEEBOX_BEES = 4,
        WASPHIVE_RELEASE_TIME = 20,
        WASPHIVE_REGEN_TIME = 20,
        WASPHIVE_WASPS = 5,
        WASPHIVE_EMERGENCY_WASPS = 8,
        WASPHIVE_EMERGENCY_RADIUS = 25,
        WASPHIVE_ENABLED = true,
--【★ BEEBOX_RELEASE_TIME = (0.5*day_time)/4 = 37.5 秒】蜂箱产出蜜蜂。
--  ★★ 写成 (0.5*day_time)/4 而不是 0.125*day_time：
--    前者保留了「半天的一半」这层语义，后者在改 day_time 时更易误读。
--    这也体现了归一化写法的另一层价值 —— **结构本身承载设计意图**。
        BEEBOX_RELEASE_TIME = (0.5*day_time)/4,
        BEEBOX_HONEY_TIME = day_time,
        BEEBOX_REGEN_TIME = seg_time*4,
        BEEBOX_ENABLED = true,

        WORM_DAMAGE = 75,
        WORM_ATTACK_PERIOD = 4,
        WORM_ATTACK_DIST = 3,
        WORM_HEALTH = 900,
        WORM_CHASE_TIME = 20,
        WORM_LURE_TIME = 30,
        WORM_LURE_VARIANCE = 10,
        WORM_FOOD_DIST = 15,
        WORM_CHASE_DIST = 50,
        WORM_WANDER_DIST = 30,
        WORM_TARGET_DIST = 20,
        WORM_LURE_COOLDOWN = 30,
        WORM_EATING_COOLDOWN = 30,

        WORMLIGHT_RADIUS = 3,
        WORMLIGHT_DURATION = seg_time * 8,

        WORMLIGHT_PLANT_REGROW_TIME = total_day_time*4,

        TENTACLE_DAMAGE = 34,
        TENTACLE_ATTACK_PERIOD = 2,
        TENTACLE_ATTACK_DIST = 4,
        TENTACLE_STOPATTACK_DIST = 6,
        TENTACLE_HEALTH = 500,

        TENTACLE_PILLAR_HEALTH = 500 * 1.5, -- harder for multiplayer
        TENTACLE_PILLAR_ARMS = 12,   -- max spawned at a time
        TENTACLE_PILLAR_ARMS_TOTAL = 25,  -- max simultaneous arms
        TENTACLE_PILLAR_ARM_DAMAGE = 5,
        TENTACLE_PILLAR_ARM_ATTACK_PERIOD = 3,
        TENTACLE_PILLAR_ARM_ATTACK_DIST = 3,
        TENTACLE_PILLAR_ARM_STOPATTACK_DIST = 5,
        TENTACLE_PILLAR_ARM_HEALTH = 20,
        TENTACLE_PILLAR_ARM_EMERGE_TIME = seg_time * 12,

        BIG_TENTACLE_DAMAGE = 60,

        EYEPLANT_DAMAGE = 20,
--【★ 眼草EYEPLANT 系列】1195-1260 行。
--  属于「装饰性/功能性」生物，参数以血量与触发条件为主。
        EYEPLANT_HEALTH = 30,
        EYEPLANT_ATTACK_PERIOD = 1,
        EYEPLANT_ATTACK_DIST = 2.5,
        EYEPLANT_STOPATTACK_DIST = 4,

        LUREPLANT_HIBERNATE_TIME = total_day_time * 2,
        LUREPLANT_GROWTHCHANCE = 0.02,
        LUREPLANT_SPAWNTIME = total_day_time * 12,
        LUREPLANT_SPAWNTIME_VARIANCE = total_day_time * 3,

        TALLBIRD_HEALTH = 400 * 2, -- harder for multiplayer
        TALLBIRD_DAMAGE = 50,
        TALLBIRD_ATTACK_PERIOD = 2,
        TALLBIRD_HATEPIGS_DIST = 16,
        TALLBIRD_TARGET_DIST = 8,
        TALLBIRD_DEFEND_DIST = 12,
        TALLBIRD_ATTACK_RANGE = 3,

        TEENBIRD_HEALTH = 400*.75 * 2, -- harder for multiplayer
        TEENBIRD_DAMAGE = 50*.75,
        TEENBIRD_ATTACK_PERIOD = 2,
        TEENBIRD_ATTACK_RANGE = 3,
        TEENBIRD_DAMAGE_PECK = 2,
        TEENBIRD_PECK_PERIOD = 4,
        TEENBIRD_HUNGER = 60,
        TEENBIRD_STARVE_TIME = total_day_time * 1,
        TEENBIRD_STARVE_KILL_TIME = 240,
        TEENBIRD_GROW_TIME = total_day_time*18,
        TEENBIRD_TARGET_DIST = 8,
		TALLBIRD_LAY_EGG_TIME_MIN = 3 * total_day_time,
		TALLBIRD_LAY_EGG_TIME_VAR = 2 * total_day_time,

        SMALLBIRD_HEALTH = 50,
        SMALLBIRD_DAMAGE = 10,
        SMALLBIRD_ATTACK_PERIOD = 1,
        SMALLBIRD_ATTACK_RANGE = 3,
        SMALLBIRD_HUNGER = 20,
        SMALLBIRD_STARVE_TIME = total_day_time * 1,
        SMALLBIRD_STARVE_KILL_TIME = 120,
        SMALLBIRD_GROW_TIME = total_day_time*10,

        SMALLBIRD_HATCH_CRACK_TIME = 10, -- set by fire for this much time to start hatching progress
        SMALLBIRD_HATCH_TIME = total_day_time * 3, -- must be content for this amount of cumulative time to hatch
        SMALLBIRD_HATCH_FAIL_TIME = night_time * .5, -- being too hot or too cold this long will kill the egg

        MIN_SPRING_SMALL_BIRD_SPAWN_TIME = total_day_time * 2,
        MAX_SPRING_SMALL_BIRD_SPAWN_TIME = total_day_time * 8,

        HATCH_UPDATE_PERIOD = 3,
        HATCH_CAMPFIRE_RADIUS = 4,

        CHESTER_HEALTH = wilson_health*3,
        CHESTER_RESPAWN_TIME = total_day_time * 1,
        CHESTER_HEALTH_REGEN_AMOUNT = (wilson_health*3) * 3/60,
        CHESTER_HEALTH_REGEN_PERIOD = 3,

        HUTCH_HEALTH = wilson_health * 3,
        HUTCH_RESPAWN_TIME = total_day_time * 1,
        HUTCH_HEALTH_REGEN_AMOUNT = (wilson_health*3) * 3/60,
        HUTCH_HEALTH_REGEN_PERIOD = 3,

        PROTOTYPER_TREES =
        {
            SCIENCEMACHINE = TechTree.Create({
                SCIENCE = 1,
                MAGIC = 1,
            }),

            ALCHEMYMACHINE = TechTree.Create({
                SCIENCE = 2,
                MAGIC = 1,
            }),

            PRESTIHATITATOR = TechTree.Create({
                MAGIC = 2,
            }),

            SHADOWMANIPULATOR = TechTree.Create({
                MAGIC = 3,
            }),

            ANCIENTALTAR_LOW = TechTree.Create({
                ANCIENT = 2,
            }),

            ANCIENTALTAR_HIGH = TechTree.Create({
                ANCIENT = 4,
            }),

            MOONORB_LOW = TechTree.Create({
                CELESTIAL = 1,
            }),

            MOONORB_UPGRADED = TechTree.Create({
                CELESTIAL = 3,
            }),

			MOON_ALTAR_FULL = TechTree.Create({
                CELESTIAL = 3,
            }),

            WAXWELLJOURNAL = TechTree.Create({
                SHADOW = 4,
            }),

            CARTOGRAPHYDESK = TechTree.Create({
--【分区 8 · 物品 · 耐久与护甲】1301-2000 行
--  ★ 分区边界：进入物品维度。特征键名前缀：ARMOR_ / PERISH_ / REPAIR_。
--  ★★ 本区的核心是一整套「分级表」：同一件物品有 TINY/SMALL/MED/LARGE/HUGE
--    五档，每档一套数值。这是 DST 表达「物品品质阶梯」的统一手法，
--    好处是加新品质只需加一档，不必改逻辑。
                CARTOGRAPHY = 2,
            }),

			SEAFARING_STATION = TechTree.Create({
                SEAFARING = 2,
            }),

            SCULPTINGTABLE = TechTree.Create({
                SCULPTING = 1,
            }),

            CRITTERLAB = TechTree.Create({
                ORPHANAGE = 1,
            }),

            PERDSHRINE = TechTree.Create({
                PERDOFFERING = 3,
            }),

            WARGSHRINE = TechTree.Create({
                WARGOFFERING = 3,
                PERDOFFERING = 1,
            }),

            PIGSHRINE = TechTree.Create({
                PIGOFFERING = 3,
                PERDOFFERING = 1,
            }),

            CARRATSHRINE = TechTree.Create({
                CARRATOFFERING = 3,
                PERDOFFERING = 1,
            }),

            BEEFSHRINE = TechTree.Create({
                BEEFOFFERING = 3,
                PERDOFFERING = 1,
            }),

            CATCOONSHRINE = TechTree.Create({
                CATCOONOFFERING = 3,
                PERDOFFERING = 1,
            }),

            RABBITSHRINE = TechTree.Create({
                RABBITOFFERING = 3,
                PERDOFFERING = 1,
            }),

            DRAGONSHRINE = TechTree.Create({
                DRAGONOFFERING = 3,
                PERDOFFERING = 1,
            }),

            WORMSHRINE = TechTree.Create({
                WORMOFFERING = 3,
                PERDOFFERING = 1,
            }),

            KNIGHTSHRINE = TechTree.Create({
                KNIGHTOFFERING = 3,
                PERDOFFERING = 1,
            }),

            MADSCIENCE = TechTree.Create({
                MADSCIENCE = 1,
            }),

			CARNIVAL_PRIZESHOP = TechTree.Create({
                CARNIVAL_PRIZESHOP = 1,
            }),

			CARNIVAL_HOSTSHOP_WANDER = TechTree.Create({
                CARNIVAL_HOSTSHOP = 1,
            }),

			CARNIVAL_HOSTSHOP_PLAZA = TechTree.Create({
                CARNIVAL_HOSTSHOP = 3,
            }),

            FOODPROCESSING = TechTree.Create({
                FOODPROCESSING = 1,
            }),

            FISHING = TechTree.Create({
                FISHING = 1,
            }),

			WINTERSFEASTCOOKING = TechTree.Create({
				WINTERSFEASTCOOKING = 1,
			}),

			HERMITCRABSHOP_L1 = TechTree.Create({
				HERMITCRABSHOP = 1,
			}),
			HERMITCRABSHOP_L2 = TechTree.Create({
				HERMITCRABSHOP = 3,
			}),
			HERMITCRABSHOP_L3 = TechTree.Create({
				HERMITCRABSHOP = 5,
			}),
            HERMITCRABSHOP_L4 = TechTree.Create({
                HERMITCRABSHOP = 7,
            }),

            SHELLWEAVER_L1 = TechTree.Create({
                SHELLWEAVER = 1,
            }),
            SHELLWEAVER_L2 = TechTree.Create({
                SHELLWEAVER = 3,
            }),

            RABBITKINGSHOP = TechTree.Create({
                RABBITKINGSHOP = 2,
            }),

            WANDERINGTRADERSHOP = TechTree.Create({
                WANDERINGTRADERSHOP = 2,
            }),

            WAGPUNK_WORKSTATION = TechTree.Create({
                WAGPUNK_WORKSTATION = 1,
            }),

            TURFCRAFTING = TechTree.Create({
                TURFCRAFTING = 2,
                MASHTURFCRAFTING = 2,
            }),

            SPIDERCRAFT = TechTree.Create({
                SPIDERCRAFT = 1,
            }),

            ROBOTMODULECRAFT = TechTree.Create({
                ROBOTMODULECRAFT = 1,
            }),

            BOOKCRAFT = TechTree.Create({
                BOOKCRAFT = 1,
                SCIENCE = 2,
                MAGIC = 1,
            }),

			LUNAR_FORGE = TechTree.Create({
				LUNARFORGING = 2,
			}),

			SHADOW_FORGE = TechTree.Create({
				SHADOWFORGING = 2,
			}),

            CARPENTRY_STATION = TechTree.Create({
                CARPENTRY = 2,
            }),

            CARPENTRY_STATION_STONE = TechTree.Create({
                CARPENTRY = 3,
            }),

            VAULT_REFINER_PEDESTAL = TechTree.Create({
                VAULT_REFINE = 1,
            }),

            CARNIVALGAME_GOLFGAME = TechTree.Create({
                CARNIVAL_GOLFPROPS = 1,
            }),
		},

        RABBIT_HEALTH = 25 * multiplayer_attack_modifier,
        MOLE_HEALTH = 30,

        FROG_HEALTH = 100,
        FROG_DAMAGE = 10,
        FROG_ATTACK_PERIOD = 1,
        FROG_TARGET_DIST = 4,

        HOUND_SPECIAL_CHANCE =
        {
            {minday=0, chance=0},
            {minday=15, chance=.1},
            {minday=30, chance=.2},
            {minday=50, chance=.333},
            {minday=75, chance=.5},
        },

        HOUND_HEALTH = 150,
        HOUND_DAMAGE = 20,
        HOUND_ATTACK_PERIOD = 2,
        HOUND_TARGET_DIST = 20,
        HOUND_SPEED = 10,
        HOUND_SWIM_SPEED = 3.5,
        CLAYHOUND_SPEED = 8.5,

		HOUND_FIND_CARCASS_DELAY = 10,

        HOUND_FOLLOWER_TARGET_DIST = 10,
        HOUND_FOLLOWER_TARGET_KEEP = 20,
        HOUND_FOLLOWER_AGGRO_DIST = 8,
        HOUND_FOLLOWER_RETURN_DIST = 12,

        FIREHOUND_HEALTH = 100,
        FIREHOUND_DAMAGE = 30,
        FIREHOUND_ATTACK_PERIOD = 2,
        FIREHOUND_SPEED = 10,

        ICEHOUND_HEALTH = 100,
        ICEHOUND_DAMAGE = 30,
        ICEHOUND_ATTACK_PERIOD = 2,
        ICEHOUND_SPEED = 10,

        MOONHOUND_HEALTH = 150,
        MOONHOUND_DAMAGE = 20,
        MOONHOUND_ATTACK_PERIOD = 2,
        MOONHOUND_SPEED = 10,
        MOONHOUND_AGGRO_DIST = 15,
        MOONHOUND_RETURN_DIST = 30,
        MOONHOUND_FREEZE_WEAR_OFF_TIME = 3,

		MUTATEDHOUND_SPAWN_CHANCE = 0.5,
		MUTATEDHOUND_SPAWN_DELAY = 4,
        MUTATEDHOUND_HEALTH = 100,
        MUTATEDHOUND_DAMAGE = 25,
        MUTATEDHOUND_ATTACK_PERIOD = 2.5,

        HEDGEHOUND_HEALTH = 50,
        HEDGEHOUND_DAMAGE = 10,
        HEDGEHOUND_ATTACK_PERIOD = 2,

        MOONPIG_AGGRO_DIST = 15,
        MOONPIG_RETURN_DIST = 30,
        MOONPIG_FREEZE_WEAR_OFF_TIME = 3,

        MOSQUITO_WALKSPEED = 8,
        MOSQUITO_RUNSPEED = 12,
        MOSQUITO_DAMAGE = 3,
        MOSQUITO_HEALTH = 100,
        MOSQUITO_ATTACK_RANGE = 1.75,
        MOSQUITO_ATTACK_PERIOD = 7,
        MOSQUITO_MAX_DRINKS = 4,
        MOSQUITO_BURST_DAMAGE = 34,
        MOSQUITO_BURST_RANGE = 3.5,

        KRAMPUS_HEALTH = 200 * 1.5, -- harder for multiplayer
        KRAMPUS_DAMAGE = 50,
        KRAMPUS_ATTACK_PERIOD = 1.2,
        KRAMPUS_SPEED = 7,
        KRAMPUS_THRESHOLD = 30,
        KRAMPUS_THRESHOLD_VARIANCE = 20,
        KRAMPUS_INCREASE_LVL1 = 50,
        KRAMPUS_INCREASE_LVL2 = 100,
        KRAMPUS_INCREASE_RAMP = 2,
        KRAMPUS_NAUGHTINESS_DECAY_PERIOD = 60,

        TERRORBEAK_SPEED = 7,
        TERRORBEAK_HEALTH = 400,
        TERRORBEAK_DAMAGE = 50,
        TERRORBEAK_ATTACK_PERIOD= 1.5,

        CRAWLINGHORROR_SPEED = 3,
        CRAWLINGHORROR_HEALTH = 300,
        CRAWLINGHORROR_DAMAGE = 20,
        CRAWLINGHORROR_ATTACK_PERIOD= 2.5,

        SHADOWCREATURE_TARGET_DIST = 20,
		SHADOWCREATURE_TARGET_DIST_SQ = 20*20,

        SHADOW_CHESSPIECE_EPICSCARE_RANGE = 10,
        SHADOW_CHESSPIECE_DESPAWN_TIME = 30,

        SHADOW_ROOK =
        {
            LEVELUP_SCALE = {1, 1.2, 1.6},
            SPEED = 7,                          -- levels are procedural
            HEALTH = {1000, 4000, 10000},
            DAMAGE = {45, 100, 165},
            ATTACK_PERIOD = {6, 5.5, 5},
            ATTACK_RANGE = 8,                   -- levels are procedural
            HIT_RANGE = 3.35,
            RETARGET_DIST = 15,
        },

        SHADOW_KNIGHT =
        {
            LEVELUP_SCALE = {1, 1.7, 2.5},
            SPEED = {7, 9, 12},
            HEALTH = {900, 2700, 8100},
            DAMAGE = {40, 90, 150},
            ATTACK_PERIOD = {3, 2.5, 2},
            ATTACK_RANGE = 2.3,                 -- levels are procedural
            ATTACK_RANGE_LONG = 4.5,            -- levels are procedural
            RETARGET_DIST = 15,
        },

        SHADOW_BISHOP =
        {
            LEVELUP_SCALE = {1, 1.6, 2.2},
            SPEED = 3,                          -- levels are procedural
            HEALTH = {800, 2500, 7500},
            DAMAGE = {20, 35, 60},
            ATTACK_PERIOD = {15, 14, 12},
            ATTACK_RANGE = {4, 6, 8},           -- levels are procedural
            HIT_RANGE = 1.75,
            ATTACK_TICK = .5,
            ATTACK_START_TICK = .2,
            RETARGET_DIST = 15,
        },

        FROSTY_BREATH = -5,

        SEEDS_GROW_TIME = day_time*6,
        FARM1_GROW_BONUS = 1,
        FARM2_GROW_BONUS = .6667,
        FARM3_GROW_BONUS = .333,
        POOP_FERTILIZE = day_time,
        POOP_SOILCYCLES = 10,
        POOP_WITHEREDCYCLES = 1,
        POOP_CAN_USES = 8,
        GUANO_FERTILIZE = day_time * 1.5,
        GUANO_SOILCYCLES = 12,
        GUANO_WITHEREDCYCLES = 1,

		SOILAMENDER_FERTILIZE_HEALTH_LOW	= 1,
		SOILAMENDER_FERTILIZE_LOW			= day_time/8,
		SOILAMENDER_SOILCYCLES_LOW			= 1,
		SOILAMENDER_WITHEREDCYCLES_LOW		= 0.25,

		SOILAMENDER_FERTILIZE_HEALTH_MED	= 2,
		SOILAMENDER_FERTILIZE_MED			= day_time/2,
		SOILAMENDER_SOILCYCLES_MED			= 2,
		SOILAMENDER_WITHEREDCYCLES_MED		= 0.5,

		SOILAMENDER_FERTILIZE_HEALTH_HIGH	= 3,
		SOILAMENDER_FERTILIZE_HIGH			= day_time*1.5,
		SOILAMENDER_SOILCYCLES_HIGH			= 5,
		SOILAMENDER_WITHEREDCYCLES_HIGH		= 1,

		SOILAMENDER_FERMENTED_USES	= 5,

		SOILAMENDER_PERCOLATE_ANIM_DELAY_FRESH = 15,
		SOILAMENDER_PERCOLATE_ANIM_DELAY_STALE = 8,
		SOILAMENDER_PERCOLATE_ANIM_DELAY_SPOILED = 4,

		PERISH_FRESH = 0.5,
		PERISH_STALE = 0.2,

        GLOMMERFUEL_FERTILIZE = day_time,
        GLOMMERFUEL_SOILCYCLES = 8,

        SPOILEDFOOD_FERTILIZE = day_time/4,
        SPOILEDFOOD_SOILCYCLES = 2,
        SPOILEDFOOD_WITHEREDCYCLES = 0.5,

        TREEGROWTH_SOILCYCLES = 8,
        TREEGROWTH_FERTILIZE = day_time,
        TREEGROWTH_WITHEREDCYCLES = 1,

        MUSHROOMFARM_MAX_HARVESTS = 4,
        MUSHROOMFARM_FULL_GROW_TIME = total_day_time * 3.75,
        MUSHROOMFARM_SPAWN_SPORE_CHANCE = 0.50,

        FISHING_CATCH_CHANCE = 0.4,
        FISHING_LOSEROD_CHANCE = 0.4,

        TURNON_FUELED_CONSUMPTION = .5,
        TURNON_FULL_FUELED_CONSUMPTION = 1 / 60,

        WET_FUEL_PENALTY = 0.75,

        TINY_FUEL = seg_time*.25,
        SMALL_FUEL = seg_time * .5,
        MED_FUEL = seg_time * 1.5,
        MED_LARGE_FUEL = seg_time * 3,
        LARGE_FUEL = seg_time * 6,
        HUGE_FUEL = seg_time * 9,

        TINY_BURNTIME = seg_time*.1,
        SMALL_BURNTIME = seg_time*.25,
        MED_BURNTIME = seg_time*0.5,
        LARGE_BURNTIME = seg_time,

        TREE_BURN_TIME = 45,

        CAMPFIRE_RAIN_RATE = 2.5,
        CAMPFIRE_FUEL_MAX = (night_time+dusk_time)*1.5,
        CAMPFIRE_FUEL_START = (night_time+dusk_time)*.75,

        COLDFIRE_RAIN_RATE = 2.5,
        COLDFIRE_FUEL_MAX = (night_time+dusk_time)*1.5,
        COLDFIRE_FUEL_START = (night_time+dusk_time)*.75,

        ROCKLIGHT_FUEL_MAX = (night_time+dusk_time)*1.5,

        FIREPIT_RAIN_RATE = 2,
        FIREPIT_FUEL_MAX = (night_time+dusk_time)*2,
        FIREPIT_FUEL_START = night_time+dusk_time,
        FIREPIT_BONUS_MULT = 2,

        COLDFIREPIT_RAIN_RATE = 2,
        COLDFIREPIT_FUEL_MAX = (night_time+dusk_time)*2,
        COLDFIREPIT_FUEL_START = night_time+dusk_time,
        COLDFIREPIT_BONUS_MULT = 2,

        PIGTORCH_RAIN_RATE = 2,
        PIGTORCH_FUEL_MAX = night_time,

        NIGHTLIGHT_FUEL_MAX = (night_time+dusk_time)*3,
        NIGHTLIGHT_FUEL_START = (night_time+dusk_time),

        TORCH_RAIN_RATE = 1.5,
        TORCH_FUEL = night_time*1.25,
        TORCH_SHRINE_FUEL_RATE_MULT = .2,

        MINIFAN_FUEL = day_time * 0.3,

        COMPASS_FUEL = day_time * 4,
        COMPASS_ATTACK_DECAY_PERCENT = -0.3,

        NIGHTSTICK_FUEL = night_time*6,
        LIGHTER_RAIN_RATE = 1,
        LIGHTER_FUEL = total_day_time*1.25,

        MINERHAT_LIGHTTIME = (night_time+dusk_time)*2.6,
        LANTERN_LIGHTTIME = (night_time+dusk_time)*2.6,
        SPIDERHAT_PERISHTIME = 4*seg_time,
        SPIDERHAT_RANGE = 12,
        ONEMANBAND_PERISHTIME = 6*seg_time,
        ONEMANBAND_RANGE = 12,
        ONEMANBAND_MAXFOLLOWERS = 10,
        HEATROCK_NUMUSES = 8,

        GRASS_UMBRELLA_PERISHTIME = 2*total_day_time*perish_warp,
        UMBRELLA_PERISHTIME = total_day_time*6,
        EYEBRELLA_PERISHTIME = total_day_time*9,

        STRAWHAT_PERISHTIME = total_day_time*5,
        EARMUFF_PERISHTIME = total_day_time*5,
        WINTERHAT_PERISHTIME = total_day_time*10,
        BEEFALOHAT_PERISHTIME = total_day_time*10,

        TRUNKVEST_PERISHTIME = total_day_time*15,
        REFLECTIVEVEST_PERISHTIME = total_day_time*8,
        HAWAIIANSHIRT_PERISHTIME = total_day_time*15,
        SWEATERVEST_PERISHTIME = total_day_time*10,
        HUNGERBELT_PERISHTIME = total_day_time*8,
        BEARGERVEST_PERISHTIME = total_day_time*7,
        RAINCOAT_PERISHTIME = total_day_time*10,

        WALRUSHAT_PERISHTIME = total_day_time*25,
        FEATHERHAT_PERISHTIME = total_day_time*8,
        TOPHAT_PERISHTIME = total_day_time*8,

        ICEHAT_PERISHTIME = total_day_time*4,
        MOLEHAT_PERISHTIME = total_day_time*1.5,
        RAINHAT_PERISHTIME = total_day_time*10,
        CATCOONHAT_PERISHTIME = total_day_time*10,
        GOGGLES_PERISHTIME = total_day_time*10,
        NUTRIENTSGOGGLESHAT_PERISHTIME = total_day_time*10,

        WALTERHAT_PERISHTIME = total_day_time*10,

        GRASS_REGROW_TIME = total_day_time*3,
        SAPLING_REGROW_TIME = total_day_time*4,
        MARSHBUSH_REGROW_TIME = total_day_time*4,
        CACTUS_REGROW_TIME = total_day_time*4,
        FLOWER_CAVE_REGROW_TIME = total_day_time*3,
        FLOWER_CAVE_LIGHT_TIME = 90,
        FLOWER_CAVE_RECHARGE_TIME = 110,
        LICHEN_REGROW_TIME = total_day_time*5,

        BERRY_REGROW_TIME = total_day_time*3,
        BERRY_REGROW_INCREASE = total_day_time*.5,
        BERRY_REGROW_VARIANCE = total_day_time*2,
        BERRYBUSH_CYCLES = 3,

        BERRY_JUICY_REGROW_TIME =  total_day_time * 9,
        BERRY_JUICY_REGROW_INCREASE = total_day_time*.5,
        BERRY_JUICY_REGROW_VARIANCE = total_day_time*2,
        BERRYBUSH_JUICY_CYCLES = 3,

        REEDS_REGROW_TIME = total_day_time*3,

		GRASS_CYCLES = 20,

        BIRD_LEAVINGS_CHANCE = 0.2,
        CROW_LEAVINGS_CHANCE = 0.3333,
        BIRD_TRAP_CHANCE = 0.025,
        BIRD_HEALTH = 25*multiplayer_attack_modifier,
        BIRD_PERISH_TIME = total_day_time * 5,
        BIRD_CANARY_LURE_DISTANCE = 12,

        BUTTERFLY_SPAWN_TIME = 10*multiplayer_wildlife_respawn_modifier,
        BUTTERFLY_POP_CAP = 4,
        BUTTERFLY_PERISH_TIME = total_day_time * 3,

        MOONBUTTERFLY_SPEED = 2.5,
        MOONBUTTERFLY_PERISH_TIME = total_day_time / 2,
		MOONBUTTERFLY_PERISH_INV_MODIFIER = 0.25,

        FLOWER_SPAWN_TIME_VARIATION = 20,
        FLOWER_SPAWN_TIME = 30,
        MAX_FLOWERS_PER_AREA = 50,

        MOLE_RESPAWN_TIME = day_time*4*multiplayer_wildlife_respawn_modifier,
        MOLE_ENABLED = true,

        RABBIT_RESPAWN_TIME = day_time*4*multiplayer_wildlife_respawn_modifier,
        RABBIT_ENABLED = true,
        RABBIT_PERISH_TIME = total_day_time * 5,

        MIN_RABBIT_HOLE_TRANSITION_TIME = day_time*.5,
        MAX_RABBIT_HOLE_TRANSITION_TIME = day_time*2,

        FULL_ABSORPTION = 1,
        ARMORGRASS = wilson_health*1.5*multiplayer_armor_durability_modifier,
        ARMORGRASS_ABSORPTION = .6*multiplayer_armor_absorption_modifier,
        ARMORWOOD = wilson_health*3*multiplayer_armor_durability_modifier,
        ARMORWOOD_ABSORPTION = .8*multiplayer_armor_absorption_modifier,
        ARMORMARBLE = wilson_health*7*multiplayer_armor_durability_modifier,
        ARMORMARBLE_ABSORPTION = .95*multiplayer_armor_absorption_modifier,
        ARMORSNURTLESHELL_ABSORPTION = 0.6*multiplayer_armor_absorption_modifier,
        ARMORSNURTLESHELL = wilson_health*7*multiplayer_armor_durability_modifier,
        ARMORMARBLE_SLOW = 0.7,
        ARMORRUINS_ABSORPTION = 0.9*multiplayer_armor_absorption_modifier,
        ARMORRUINS = wilson_health * 12*multiplayer_armor_durability_modifier,
        ARMORSLURPER_ABSORPTION = 0.6*multiplayer_armor_absorption_modifier,
        ARMORSLURPER_SLOW_HUNGER = 0.6,
        ARMORSLURPER = wilson_health * 4*multiplayer_armor_durability_modifier,
        ARMOR_FOOTBALLHAT = wilson_health*3*multiplayer_armor_durability_modifier,
        ARMOR_FOOTBALLHAT_ABSORPTION = .8*multiplayer_armor_absorption_modifier,
        ARMOR_COOKIECUTTERHAT = wilson_health*5*multiplayer_armor_durability_modifier,
        ARMOR_COOKIECUTTERHAT_ABSORPTION = .7*multiplayer_armor_absorption_modifier,

        ARMOR_WOODCARVED_HAT = wilson_health*2.5*multiplayer_armor_durability_modifier,
        ARMOR_WOODCARVED_HAT_ABSORPTION = .7*multiplayer_armor_absorption_modifier,

		ARMOR_SCRAP_HAT = wilson_health * 2.5 * multiplayer_armor_durability_modifier,
		ARMOR_SCRAP_HAT_ABSORPTION = 0.85 * multiplayer_armor_absorption_modifier,

        ARMORDRAGONFLY = wilson_health * 9*multiplayer_armor_durability_modifier,
        ARMORDRAGONFLY_ABSORPTION = 0.7*multiplayer_armor_absorption_modifier,
        ARMORDRAGONFLY_FIRE_RESIST = 1,

        ARMORBEARGER_SLOW_HUNGER = 0.75,

        ARMOR_WATHGRITHRHAT = wilson_health * 5*multiplayer_armor_durability_modifier,
        ARMOR_WATHGRITHRHAT_ABSORPTION = .8*multiplayer_armor_absorption_modifier,

        ARMOR_RUINSHAT = wilson_health*8*multiplayer_armor_durability_modifier,
        ARMOR_RUINSHAT_ABSORPTION = 0.9*multiplayer_armor_absorption_modifier,
        ARMOR_RUINSHAT_PROC_CHANCE = 0.33,
        ARMOR_RUINSHAT_COOLDOWN = 5,
        ARMOR_RUINSHAT_DURATION = 4,
        ARMOR_RUINSHAT_DMG_AS_SANITY = 0.05,

        ARMOR_SLURTLEHAT = wilson_health*5*multiplayer_armor_durability_modifier,
        ARMOR_SLURTLEHAT_ABSORPTION = 0.9*multiplayer_armor_absorption_modifier,
        ARMOR_BEEHAT = wilson_health*10*multiplayer_armor_durability_modifier,
        ARMOR_BEEHAT_ABSORPTION = .8*multiplayer_armor_absorption_modifier,
        ARMOR_SANITY = wilson_health * 5*multiplayer_armor_durability_modifier,
        ARMOR_SANITY_ABSORPTION = .95*multiplayer_armor_absorption_modifier,
        ARMOR_SANITY_DMG_AS_SANITY = 0.10,

        ARMOR_HIVEHAT = wilson_health * 9 * multiplayer_armor_durability_modifier,
        ARMOR_HIVEHAT_ABSORPTION = .7 * multiplayer_armor_absorption_modifier,
        ARMOR_HIVEHAT_SANITY_ABSORPTION = .5,

        ARMOR_SKELETONHAT = wilson_health * 9 * multiplayer_armor_durability_modifier,
        ARMOR_SKELETONHAT_ABSORPTION = .7 * multiplayer_armor_absorption_modifier,

        ARMOR_SKELETON_COOLDOWN = 5,
        ARMOR_SKELETON_FIRST_COOLDOWN = 1,

		ARMOR_DREADSTONEHAT = wilson_health * 8 * multiplayer_armor_durability_modifier,
		ARMOR_DREADSTONEHAT_ABSORPTION = 0.9 * multiplayer_armor_absorption_modifier,
		ARMOR_DREADSTONEHAT_PLANAR_DEF = 5,
		ARMOR_DREADSTONEHAT_SHADOW_RESIST = 0.9,
		ARMORDREADSTONE = wilson_health * 8 * multiplayer_armor_durability_modifier,
		ARMORDREADSTONE_ABSORPTION = 0.9 * multiplayer_armor_absorption_modifier,
		ARMORDREADSTONE_PLANAR_DEF = 5,
		ARMORDREADSTONE_SHADOW_RESIST = 0.9,
		ARMOR_DREADSTONE_REGEN_PERIOD = 1,
		ARMOR_DREADSTONE_REGEN_MINRATE = (0.01 / 10) / 1.5,
		ARMOR_DREADSTONE_REGEN_MAXRATE = (0.01 / 6) / 1.5,
		ARMOR_DREADSTONE_REGEN_SETBONUS = 1.5,

--【★★ 护甲耐久公式 —— 这是本文件最值得学的「设计意图即注释」范例】
--  英文原注释：'NOTE: + 20 * 10 <= 20 hits of defending 10 planar damage'
--  对应代码（第 1887 行）：
--      ARMOR_LUNARPLANT = wilson_health * 6 * multiplayer_armor_durability_modifier + 20 * 10
--
--  ★★ 完整拆解这条公式，它同时示范了三件事：
--  (1) ★ 主项用**相对量**：wilson_health*6 = 150*6 = 900 点，
--      再乘 multiplayer_armor_durability_modifier(=0.7) = 630 点。
--      ⇒ 月光护甲耐久 = 630 + 200 = **830 点**。
--      ★★ 为什么写成 wilson_health*6 而不是裸 900？
--        因为月光护甲**晚上变强**（见下LUNAR_RESIST），其耐久要能扛住
--        一整夜的攻击。若写成裸 900，将来策划调整基础血量就忘了同步这里。
--        用 wilson_health 锚定，语义变成「6 倍基础血量」—— 一看就懂。
--  (2) ★ 联机乘数插在主项里：multiplayer_armor_durability_modifier = 0.7
--      ⇒ 多人时耐久降 30%（第 33 行），与第 31 行的攻击倍率配合，
--        使多人游戏里「挨打次数更多但护甲也更脆」，抵消一部分劣势。
--  (3) ★★ 尾部 + 20*10 = **+200 点固定附加**，而英文注释解释了它：
--      「+20*10 <= 20 hits of defending 10 planar damage」
--      即：这额外的 200 点耐久 = 能再扛 **20 次**「每次 10 点」的平面伤害。
--      ★★ 验算完全自洽：200 点耐久 ÷ 每次消耗 10 点 = 20 次 ✓
--        且ARMOR_LUNARPLANT_PLANAR_DEF = 10（第 1889 行）
--        正好对应注释里的「defending 10 planar damage」。
--      ⇒ 这不是缺陷，而是一条**把「点数」翻译成「次数」的注释**：
--        策划不关心 830 点是多少，他关心「能挨几下」。
--        这与第 2248 行保暖值的「时间语义」是同一个设计思想。
--
--  ★ 同一公式在第 1898 行（ARMOR_VOIDCLOTH）重复出现，注释一字不差。
--    ⇒ 月光护甲与虚空斗篷被刻意设计成**完全同级的顶级护甲**。
--    两条一模一样的注释，是作者用来标记「这两件是对齐的」的信号。
--★ 参见 components/armor.lua（护甲扣减实现：吸收率与耐久扣减）。
		--NOTE: + 20 * 10 <= 20 hits of defending 10 planar damage
		ARMOR_LUNARPLANT = wilson_health * 6 * multiplayer_armor_durability_modifier + 20 * 10,
		ARMOR_LUNARPLANT_ABSORPTION = 0.8 * multiplayer_armor_absorption_modifier,
		ARMOR_LUNARPLANT_PLANAR_DEF = 10,
		ARMOR_LUNARPLANT_HAT = wilson_health * 6 * multiplayer_armor_durability_modifier + 20 * 10,
		ARMOR_LUNARPLANT_HAT_ABSORPTION = 0.8 * multiplayer_armor_absorption_modifier,
		ARMOR_LUNARPLANT_HAT_PLANAR_DEF = 10,
		ARMOR_LUNARPLANT_LUNAR_RESIST = 0.9,
		ARMOR_LUNARPLANT_SETBONUS_LUNAR_RESIST = math.sqrt(0.75) / 0.9, --sqrt because two pieces combine to achieve this
		ARMOR_LUNARPLANT_REFLECT_PLANAR_DMG = 10,
		ARMOR_LUNARPLANT_REFLECT_PLANAR_DMG_VS_SHADOW = 20,

        --NOTE: + 20 * 10 <= 20 hits of defending 10 planar damage
		ARMOR_VOIDCLOTH = wilson_health * 6 * multiplayer_armor_durability_modifier + 20 * 10,
		ARMOR_VOIDCLOTH_ABSORPTION = 0.8 * multiplayer_armor_absorption_modifier,
		ARMOR_VOIDCLOTH_PLANAR_DEF = 10,
		ARMOR_VOIDCLOTH_HAT = wilson_health * 6 * multiplayer_armor_durability_modifier + 20 * 10,
		ARMOR_VOIDCLOTH_HAT_ABSORPTION = 0.8 * multiplayer_armor_absorption_modifier,
		ARMOR_VOIDCLOTH_HAT_PLANAR_DEF = 10,
		ARMOR_VOIDCLOTH_SHADOW_RESIST = 0.9,
		ARMOR_VOIDCLOTH_SETBONUS_SHADOW_RESIST = math.sqrt(0.75) / 0.9, --sqrt because two pieces combine to achieve this

        ARMOR_VOIDCLOTH_SETBONUS_PLANARDAMAGE_MAX = 24,
        ARMOR_VOIDCLOTH_SETBONUS_PLANARDAMAGE_MAX_HITS = 6,
        ARMOR_VOIDCLOTH_SETBONUS_PLANARDAMAGE_DECAY_TIME = 3,

        PANFLUTE_SLEEPTIME = 20,
        PANFLUTE_SLEEPRANGE = 15,
        PANFLUTE_USES = 10,

        HORN_RANGE = 25,
        HORN_USES = 10,
        HORN_EFFECTIVE_TIME = 20,
        HORN_MAX_FOLLOWERS = 5,

        HOUNDWHISTLE_USES = 10,
        HOUNDWHISTLE_RANGE = 25,
        HOUNDWHISTLE_EFFECTIVE_TIME = 40,
        HOUNDWHISTLE_MAX_FOLLOWERS = 5,

        MANDRAKE_SLEEP_TIME = 10,
        MANDRAKE_SLEEP_RANGE = 15,
        MANDRAKE_SLEEP_RANGE_COOKED = 25,
        KNOCKOUT_SLEEP_TIME = 30,
        SLEEPBOMB_DURATION = 20,

--【★ Scrapbook（手札）配置区】1932-2000 行。
--  属于「收集向」内容，参与度低，故数值集中在区块末尾。
        -- Scrapbook
        SCRAPBOOK_BACKEND_SYNC = 3,
        SCRAPBOOK_UPDATERATE = 1, -- Must be smaller than SCRAPBOOK_BACKEND_SYNC
        SCRAPBOOK_UPDATERADIUS = 15,

        GOLD_VALUES =
        {
            CARNIVAL_GAMETOKEN = 1,
            ANTLION = 1,
            COTL_TRINKET = 8,
            MEAT = 1,
            RAREMEAT = 5,
            YOTB_BEEFALO_DOLL = 3,
            TRINKETS =
            {
                4, --[1] Melty Marbles
                6, --[2] Fake Kazoo
                4, --[3] Gord's Knot
                5, --[4] Gnome
                4, --[5] Tiny Rocketship
                5, --[6] Frazzled Wires
                4, --[7] Ball and Cup
                8, --[8] Hardened Rubber Bung
                7, --[9] Mismatched Buttons
                2, --[10] Second-hand Dentures
                5, --[11] Lying Robot
                8, --[12] Dessicated Tentacle
                5, --[13] Gnomette
                3, --[14] Leaky Teacup
                4, --[15] White Bishop
                4, --[16] Black Bishop
                2, --[17] Bent Spork
                6, --[18] Toy Trojan Horse
                6, --[19] Unbalanced Top
                7, --[20] Back Scratcher
                5, --[21] Beaten Beater
                4, --[22] Ball of Twine
                3, --[23] Shoe Horn
                8, --[24] Lucky Cat Jar
                2, --[25] Air Unfreshener
                9, --[26] Potato Cup
                4, --[27] Wire Hanger
                4, --[28] White Rook
                4, --[29] Black Rook
                4, --[30] White Knight
                4, --[31] Black Knight
                1, --[32] Crystal Ball
                1, --[33] Spider Ring
                1, --[34] Hand / Monkey Paw?
                1, --[35] Empty Potion Bottle
                1, --[36] Vampire Teeth
                1, --[37] Wooden Stake
            },
			HERMITHOUSE_ORNAMENT = 3,
        },

        RESEARCH_COST_CHEAP = 30,
        RESEARCH_COST_MEDIUM = 100,
        RESEARCH_COST_EXPENSIVE = 200,

        SPIDERQUEEN_WALKSPEED = 1.75,
        SPIDERQUEEN_HEALTH = 1250 * 2, -- harder for multiplayer
        SPIDERQUEEN_DAMAGE = 80,
        SPIDERQUEEN_ATTACKPERIOD = 3,
        SPIDERQUEEN_ATTACKRANGE = 5,
        SPIDERQUEEN_FOLLOWERS = 16,
        SPIDERQUEEN_GIVEBIRTHPERIOD = 10,
--【★ 蛛后 SPIDERQUEEN 参数区】
--  SPIDERQUEEN_ATTACKPERIOD = 3（第 1995 行）与普通蜘蛛的 3 秒相同 ——
--  ★ 设计意图：Boss 不靠「攻击更快」施压，而靠血量与召唤能力。
--    这样玩家在面对蛛后时，背下来的「3 秒一刀」肌肉记忆依然有效。
        SPIDERQUEEN_MINWANDERTIME = total_day_time * 1.5,
        SPIDERQUEEN_MINDENSPACING = 20,
--【分区 9 · 生存三围与治疗】2001-2170 行
--  ★ 分区边界：SANITY / PERISH / HEALING / REPAIR / CALORIES 五个家族。
--  ★ 这五个家族是「玩家生存循环」的数值体现：
--    饥饿(hunger)掉→ 吃东西回、理智(sanity)掉 → 变疯、
--    生命(health)掉 → 死亡、物品(perish)腐坏 → 变垃圾。
--  ★ 这部分直接对应 components/hunger.lua、sanity.lua、health.lua。
        SPIDERQUEEN_NEARBYPLAYERSDIST = 20,
		SPIDERQUEEN_HIT_RECOVERY = 1.5,

        SPAWN_SPIDERQUEEN = true,

        TRAP_TEETH_USES = 10,
        TRAP_TEETH_DAMAGE = 60,
        TRAP_TEETH_RADIUS = 1.5,

        MAX_HEALING_NORMAL = -0.25, --as a % of maximum health

        HEALING_TINY = 1,
        HEALING_SMALL = 3,
        HEALING_MEDSMALL = 8,
        HEALING_MOREMEDSMALL = 15,
        HEALING_MED = 20,
        HEALING_MEDLARGE = 30,
        HEALING_LARGE = 40,
        HEALING_HUGE = 60,
--【★★ 治疗量分级表】HEALING_* 系列：SMALL / MED / HUGE 三档。
--  HEALING_MOREHUGE = 75 —— 注意命名有 MOREHUGE（更多）这一档。
--  ★★ 这里的「分级」是给植物/道具用的：
--    普通草药治15、蘑菇治75，差距反映材料稀有度。
--  ★ 归一化判据：治疗量与时间无关 → **绝对值正确**，不必除以分母。
--    这印证了文件头「判据」：只有与「一天/一次成熟」挂钩的量才归一化。
        HEALING_MOREHUGE = 75,
        HEALING_SUPERHUGE = 100,

        SANITY_SUPERTINY = 1,
        SANITY_TINY = 5,
        SANITY_SMALL = 10,
        SANITY_MED = 15,
        SANITY_MEDLARGE = 20,
        SANITY_LARGE = 33,
        SANITY_HUGE = 50,

        LUCY_REVERT_TIME = 90, -- seconds
        LUCY_BITE_DAMAGE = 5, -- amount of damage done to non-woodies who equip lucy

        PERISH_ONE_DAY = 1*total_day_time*perish_warp,
        PERISH_TWO_DAY = 2*total_day_time*perish_warp,
        PERISH_SUPERFAST = 3*total_day_time*perish_warp,
        PERISH_FAST = 6*total_day_time*perish_warp,
        PERISH_FASTISH = 8*total_day_time*perish_warp,
        PERISH_MED = 10*total_day_time*perish_warp,
        PERISH_SLOW = 15*total_day_time*perish_warp,
        PERISH_PRESERVED = 20*total_day_time*perish_warp,
        PERISH_SUPERSLOW = 40*total_day_time*perish_warp,

		DRY_SUPERFAST = 0.25*total_day_time,
		DRY_VERYFAST = 0.5*total_day_time,
        DRY_FAST = total_day_time,
        DRY_MED = 2*total_day_time,

        CALORIES_TINY = calories_per_day/8,			-- berries				 9.375
        CALORIES_SMALL = calories_per_day/6,		-- veggies				 12.5
        CALORIES_MEDSMALL = calories_per_day/4,		--						 18.75
        CALORIES_MED = calories_per_day/3,			-- meat					 25
        CALORIES_LARGE = calories_per_day/2,		-- cooked meat			 37.5
        CALORIES_HUGE = calories_per_day,			-- crockpot foods?		 75
        CALORIES_MOREHUGE = calories_per_day*4/3,	-- crockpot foods?		100
        CALORIES_SUPERHUGE = calories_per_day*2,	-- crockpot foods?		150

--【★★ 食物卡路里分级表 —— 归一化写法的又一次应用】
--  CALORIES_SMALL = calories_per_day/6 = 75/6 = 12.5
--  ★★ 注意它**不是**直接写 12.5，而是 75/6。
--    分子沿用第 41 行的 calories_per_day=75，
--    除数 6 表示「这一份食物相当于一天口粮的六分之一」。
--    ★★ 收益：若策划把每天口粮从 75 调成 100，所有食物的热量
--      **按比例整体缩放**，食物与饥饿的相对关系保持不变。
--      写成裸 12.5 的话，改口粮就必须把 40 种食物全改一遍，
--      而且极易漏改 —— 那才是平衡事故的真正来源。
--    ★ 英文原注释 'veggies 12.5' 印证了 75/6 = 12.5 的计算结果。
--★ 本区是全文件「食物 → 卡路里」的唯一映射处，参见 cooking.lua、
--  components/hunger.lua。
		-- food affinity multipliers to add 15 calories
		AFFINITY_15_CALORIES_TINY = 2.6,
		AFFINITY_15_CALORIES_SMALL = 2.2,
		AFFINITY_15_CALORIES_MED = 1.6,
		AFFINITY_15_CALORIES_LARGE = 1.4,
		AFFINITY_15_CALORIES_HUGE = 1.2,
		AFFINITY_15_CALORIES_SUPERHUGE = 1.1,

        SPOILED_HEALTH = -1,
        SPOILED_HUNGER = -10,
        PERISH_COLD_FROZEN_MULT = 0, -- frozen things don't spoil in an ice box or if it's cold out
        PERISH_FROZEN_FIRE_MULT = 30, -- frozen things spoil very quickly if near a fire
        PERISH_FRIDGE_MULT = .5,
        PERISH_FOOD_PRESERVER_MULT = .75,
		PERISH_SALTBOX_MULT = .25,
		PERISH_MUSHROOM_LIGHT_MULT = .25,
        PERISH_GROUND_MULT = 1.5,
        PERISH_WET_MULT = 1.3,
        PERISH_CAGE_MULT = 0.25,
        PERISH_GLOBAL_MULT = 1,
        PERISH_WINTER_MULT = .75,
        PERISH_SUMMER_MULT = 1.25,

        STALE_FOOD_HUNGER = .667,
        SPOILED_FOOD_HUNGER = .5,

        STALE_FOOD_HEALTH = .333,
        SPOILED_FOOD_HEALTH = 0,

        BASE_COOK_TIME = night_time*.3333,

        TALLBIRDEGG_HEALTH = 15;
        TALLBIRDEGG_HUNGER = 15,
        TALLBIRDEGG_COOKED_HEALTH = 25;
        TALLBIRDEGG_COOKED_HUNGER = 30,
		TALLBIRD_MAKE_NEST_RADIUS = 2,

        REPAIR_CUTSTONE_HEALTH = 50,
        REPAIR_ROCKS_HEALTH = 50/3,
        REPAIR_GEMS_WORK = 1,
        REPAIR_GEARS_WORK = 1,
        REPAIR_GEARS_HEALTH = 75,
--【★ 修理与合成工时】REPAIR_THULECITE_WORK = 1.5 等。
--  ★ WORK 后缀统一表示「敲打次数」，不是秒数。
--    命名约定：本文件的单位后缀是识别数值性质的**主要线索**：
--      _TIME / _DURATION / _PERIOD / _DELAY → 秒
--      _WORK → 敲击次数
--      _RATE / _GAIN / _DRAIN → 每秒变化量（通常带负号表示消耗）
--      _CHANCE / _MULT / _FACTOR / _PERCENT → 无量纲比例
--      _HEALTH / _DAMAGE / _SANITY / _HUNGER → 点数


        REPAIR_THULECITE_WORK = 1.5,
        REPAIR_THULECITE_HEALTH = 100,

        REPAIR_THULECITE_PIECES_WORK = 1.5/6,
        REPAIR_THULECITE_PIECES_HEALTH = 100/6,

        REPAIR_BOARDS_HEALTH = 50,
        REPAIR_LOGS_HEALTH = 50/4,
        REPAIR_STICK_HEALTH = 13,
        REPAIR_CUTGRASS_HEALTH = 13,
        REPAIR_TREEGROWTH_HEALTH = 20,
        REPAIR_KELP_HEALTH = 10,
        REPAIR_SHELL_HEALTH = 20,

        REPAIR_MOONROCK_CRATER_HEALTH = 80,
        REPAIR_MOONROCK_CRATER_WORK = 4,

        REPAIR_MOONROCK_NUGGET_HEALTH = 80/2,
        REPAIR_MOONROCK_NUGGET_WORK = 2,

		REPAIR_DREADSTONE_HEALTH = 80,
		REPAIR_DREADSTONE_WORK = 4,

        REPAIR_SCRAP_HEALTH = 80,
        REPAIR_SCRAP_WORK = 4,

        SCULPTURE_COMPLETE_WORK = 10,
        SCULPTURE_COVERED_WORK = 6,

        GARGOYLE_MINE = 4,
        GARGOYLE_MINE_LOW = 2,
        GARGOYLE_REANIMATE_DELAY = .2,--6 * FRAMES--FRAMES is not declared at worldgen YO

        MOONBASE_CHARGE_DELAY = 10, --so it won't start right away as it fades to night
--★★★ 【本文件最核心的分区：理智 SANITY 与归一化示范区】2136-2250 行 ★★★
--
--  ★★ 为什么这个分区最重要：
--    它是全项目「速率类数值」的标准范式所在。理智是「每秒变化量」，
--    必须换算成玩家可理解的「每昼夜多少点」。下面 2170-2215 行集中了
--    本文件约 30 处 100/(分母*N) 写法中的绝大部分，是学习归一化的最佳样本。
        MOONBASE_CHARGE_DURATION = seg_time * 2 - 10.1, --tiny error to make sure it fits within a 2 seg night
        MOONBASE_CHARGE_DURATION1 = 18.7, --18.6, --first stage, to match music length
        MOONBASE_COMPLETE_WORK = 6,
        MOONBASE_DAMAGED_WORK = 4,
--【★ 墙体血量分级表】WOODWALL=200 / STONEWALL=400 / RUINSWALL=800。
--  ★ 成倍递增（2倍）而非等差，因为墙体的价值在于「挡住多少次攻击」，
--    指数增长才能让高级墙有质变优势。
--  ★ 另一组：MOONROCKWALL=600 / DREADSTONEWALL=800 / SCRAPWALL=600。
--    ★★ 注意它们的 _PLAYERDAMAGEMOD = .25：
--      玩家对这些墙只能造成 25% 伤害（防止玩家拆墙逃跑更快）。
--      这是「**限制玩家行为**」而非「平衡怪物」的数值，与第 31 行的
--      multiplayer_armor_durability_modifier 属同一思路。

        HAYWALL_HEALTH = 100,
        WOODWALL_HEALTH = 200,
        STONEWALL_HEALTH = 400,
        RUINSWALL_HEALTH = 800,

        MOONROCKWALL_HEALTH = 600,
        MOONROCKWALL_PLAYERDAMAGEMOD = .25,
        MOONROCKWALL_WORK = 25,

		DREADSTONEWALL_HEALTH = 800,
		DREADSTONEWALL_PLAYERDAMAGEMOD = .25,
		DREADSTONEWALL_WORK = 25,

        SCRAPWALL_HEALTH = 600,
        SCRAPWALL_PLAYERDAMAGEMOD = .25,
        SCRAPWALL_WORK = 10,

        PORTAL_HEALTH_PENALTY = 0.25,
        HEART_HEALTH_PENALTY = 0.125,

        MAXIMUM_HEALTH_PENALTY = 0.75,
        MAXIMUM_SANITY_PENALTY = 0.9,
--【★★ 复活代价 —— 惩罚设计区】2155-2170 行。
--  ★ PORTAL_HEALTH_PENALTY / HEART_HEALTH_PENALTY = 惩罚值（绝对点数）
--  ★ MAXIMUM_HEALTH_PENALTY = 0.75 / MAXIMUM_SANITY_PENALTY = 0.9
--    —— 惩罚值是**比例**而非点数。
--  ★★ 两种单位混在同一组参数里，是本区的易错点：
--    0.75 表示「损失 75% 最大生命」，40 表示「损失 40 点生命」。
--    判读方法：小于 1 的通常是比例，大于 1 的通常是点数。
--  EFFIGY_HEALTH_PENALTY = 40、REVIVE_HEALTH_PENALTY = 0.25 —— 同一区内
--    再次印证「比例与点数混排」，务必看清单位再调。
--  REVIVE_SHADOW_SANITY_PENALTY = **-40**（负号：影怪复活掉的是「加的理智」，
--    即影子形态会失去影子带来的理智加成），而 REVIVE_OTHER_SANITY_BONUS = +80。
--    ★★ 同一个动作（复活）里，对影怪是 -40、对玩家是 +80 ——
--      这是「让影怪复活有代价」的设计，一正一负形成有趣的风险收益。

        EFFIGY_HEALTH_PENALTY = 40,
        REVIVE_HEALTH_PENALTY_AS_MULTIPLE_OF_EFFIGY = 1,

        REVIVE_SHADOW_SANITY_PENALTY = -40,
        REVIVE_OTHER_SANITY_BONUS = 80,
        REVIVE_HEALTH_PENALTY = 0.25,
--★★★ 【★★ 归一化写法 · 完整解剖区】2170-2215 行 ★★★
--
--  ── 先看两个「阈值」常量，它们示范了另一种归一化 ──
--  SANITY_BECOME_SANE_THRESH = 35/200 与 SANITY_BECOME_INSANE_THRESH = 30/200
--    ★★ 不是写 0.175 和 0.15，而是写 **35/200**！
--      分母 200 = WILSON_SANITY（第 40 行）的满值，分子是绝对点数。
--      ★ 收益：策划看到「35 点以下变疯」立刻有概念；
--        若改成0.175 就必须自己反算「0.175*200 = 35」。
--      ★ 更重要的是：若某角色满理智不是 200，只要改分母（若代码引用该式），
--        所有阈值自动换算。这是「比例与点数互转」的显式桥接。
--  同理 SANITY_BECOME_ENLIGHTENED_THRESH = 170/200（开悟）
--      与 SANITY_LOSE_ENLIGHTENMENT_THRESH = 165/200（失去开悟）。
--    ★★ ★ 这里藏着一个极精妙的设计 —— ★★
--      开悟阈值 170，但**失去**开悟只要 165。
--      中间有 5 点的「迟滞带（hysteresis）」：
--        理智在 165~170 之间来回波动时，状态**不会反复切换**。
--      ★ 这就是「迟滞（hysteresis）」在游戏数值里的教科书应用，
--        与 components/sanity.lua 中的阈值判定配套使用。
--      没有它的话，玩家在边界附近会被开悟/掉开悟状态反复抖动，
--      触发大量无谓的音效与特效，甚至可能刷资源。

        SANITY_HIGH_LIGHT = .6,
        SANITY_LOW_LIGHT =  0.1,

        SANITY_DAPPERNESS = 1,

        SANITY_BECOME_SANE_THRESH = 35/200,
        SANITY_BECOME_INSANE_THRESH = 30/200,

        SANITY_BECOME_ENLIGHTENED_THRESH = 170/200,
        SANITY_LOSE_ENLIGHTENMENT_THRESH = 165/200,

--【★★★ 归一化写法 · 第 2 例：昼夜理智速率 ★★★】
--  SANITY_DAY_GAIN = 0,--100/(day_time*32),
--  ★★ 当前值为 **0**，即白天不回理智 —— 神经/gameplay 上这是「白天不涨理智」
--    的设计（白天要专心干活，理智靠夜晚与开悟维持）。
--  ★ 但被注释掉的 100/(day_time*32) 是**保留的设计意图**：
--    若将来要恢复「白天缓慢回理智」，把 0 改回该式即可。
--    ★★ 这是归一化写法的第三个好处：**版本可追溯**。
--      行尾注释写着 -- 100/(day_time*32)，后来人一看就知道原本是多少、
--      按什么口径算的；写成裸数字 0.0104167 就完全无从查证。
--    ★ 顺带说明「per day」在本文件的含义是「每昼夜 480 秒」，
--      而非「每白天 300 秒」—— 见下方 SANITYAURA 验算。
        SANITY_DAY_GAIN = 0,--100/(day_time*32),

--【★★ 夜间理智流失 —— 分night_time 而非 seg_time】
--  SANITY_NIGHT_LIGHT   = -100/(night_time*20) = -0.0833/秒
--  SANITY_NIGHT_MID     = -100/(night_time*20) = -0.0833/秒
--  SANITY_NIGHT_DARK    = -100/(night_time* 2) = -0.8333/秒
--
--  ★★ 分 night_time = 60 秒的意义：**与「夜晚」绑定，而非与固定秒数绑定**。
--    ★ 验算：LIGHT 与 MID 整个夜晚共掉 0.0833 × 60 = **5 点**；
--      DARK 阶段掉 0.8333 × 60 = **50 点**。
--      夜晚黑暗才是理智的主要威胁（50 : 5 = 10 倍），
--      而「有光但看不见」和「半夜」两个阶段惩罚很轻 ——
--      ★ 设计意图明确：**惩罚「真黑」，不惩罚「夜」本身**。
--      于是玩家有强烈动机带火把/戴矿灯，而不是无脑睡整夜。
--  ★★ 对比上一行的 SANITY_DAY_GAIN 用 day_time：
--    夜间量以 night_time 为单位，白天量以 day_time 为单位 ——
--    各自绑定自己所属的时段，这是**正确**的分母选择范式。
--    （与文件头警告的 2196/2204 那对不一致形成对照）
        SANITY_NIGHT_LIGHT = -100/(night_time*20),
        SANITY_NIGHT_MID = -100/(night_time*20),
        SANITY_NIGHT_DARK = -100/(night_time*2),

--【★ 月狂（SANITY_LUNACY）—— 疯狂的独立速率组】
--  SANITY_LUNACY_DAY_GAIN = 100/(day_time*32) = +0.0104/秒
--    ★ 正好是第 2182 行被注释掉的 100/(day_time*32) ——
--      证实了「那行原本就是月狂白天的数值」，作者注释掉它并非随手。
--  SANITY_LUNACY_NIGHT_LIGHT / MID = 0（发疯时这两阶段不掉理智）
--  SANITY_LUNACY_NIGHT_DARK = -100/(night_time*10) = -0.1667/秒
--    ★ 与正常状态的 -100/(night_time*2)（2186 行）相比，
--      月狂的夜间惩罚**只有五分之一**（-0.1667 vs -0.8333）。
--    ★★ 设计意图：发疯本身已经是惩罚，不该再叠加等量的黑暗惩罚，
--      否则玩家进月狂就是必死。这是「避免惩罚叠加」的设计。
        SANITY_LUNACY_DAY_GAIN = 100/(day_time*32),
        SANITY_LUNACY_NIGHT_LIGHT = 0,
        SANITY_LUNACY_NIGHT_MID = 0,
        SANITY_LUNACY_NIGHT_DARK = -100/(night_time*10),

--【★ 幽灵形态的理智流失】
--  SANITY_GHOST_PLAYER_DRAIN = -100/(night_time*30) = -0.0556/秒
--    ★ 幽灵状态无法生火，无法保暖 —— 每夜掉 (0.0556×60) = 3.3 点理智。
--    惩罚很轻：幽灵本来就是强力形态（可穿墙）
--    MAX_SANITY_GHOST_PLAYER_DRAIN_MULT = 3
--    ★ 注意这里是**倍率**（可被装备/能力放大到 3 倍 = -10 点/夜），
--      所以正确的读法是「基础 3.3 点，但可被叠加到 10 点」。
--    ★ 这是本文件表达「可被放大的惩罚」的标准三段式：
--      基础速率 + ..._MULT 上限倍数。
        SANITY_GHOST_PLAYER_DRAIN = -100/(night_time*30),
        MAX_SANITY_GHOST_PLAYER_DRAIN_MULT = 3,

--★★★ 【★★ 全文件最重要的 15 行：SANITYAURA 与 DAPPERNESS】★★★
--
--  这两组「光源 / 仪态」速率是本项目**归一化写法的最佳范本**。
--  请把下面 8 行的英文注释和左边的表达式对照起来读 ——
--  ★★ 英文注释里写的数字（如 50 / 200 / 6400）都是**设计目标**，
--    而左边的表达式是**为达成该目标反推出来的**。
--
--  【为什么英文注释要写结果，表达式却用分母？】
--    因为两者服务于不同的人：
--      策划看注释 → 「光源小燃料灯每昼夜回 50 理智」，直接可用；
--      改时钟的人看表达式 → 「100/(seg_time*32)」随段数自动缩放。
--    二者缺一不可。这正是「意图与实现分离」的价值。
--
--  【★ 逐行验算 —— 全部以 total_day_time = 480 秒为基准】
--    SANITYAURA_TINY      = 100/(seg_time*32) = 100/960 = 0.1042/秒
--        × 480 = **50.0** 点/昼夜  ← 与注释「50 per day」完全一致 ✓
--    SANITYAURA_SMALL     = 100/(seg_time*8)  = 100/240 = 0.4167/秒
--        × 480 = **200.0** ← 注释「200 per day」✓
--    SANITYAURA_HUGE      = 100/(seg_time*0.5) = 100/15 = 6.6667/秒
--        × 480 = **3200.0** ← 注释「3,200 per day」✓
--    ★★ 验算结论：注释里的 per day 指的是**完整昼夜（480秒）**，
--      而**不是**白天（300秒）。若按 day_time 算，
--      100/(seg_time*32) × 300 = 31.25，对不上注释里的 50。
--      ★ 这直接证明：写表达式时用 seg_time，是为了让分母显得「整数 nicer」，
--        而「每昼夜产出」这个真实目标始终以 480 秒衡量。
--
--  【★ 设计梯度】光源等级按「小→超大」覆盖 50 → 6400 点/昼夜，
--    共 7 档，跨度 128 倍。跨度如此之大是因为：
--      低端光源（营火=50）救不了场，只能延缓；
--      高端光源（巨灯=6400）能在两秒内灌满 200 点理智。
--    ★ 所以调平衡时，**不要线性调** —— 要看的是相邻档的「倍率是否稳定」。
--      本组倍率：50→80 (1.6) →200 (2.5) →320 (1.6) →800 (2.5) →3200 (4) →6400 (2)
--      这些倍率是玩家升级光源时能感知的「质变程度」。
        SANITYAURA_TINY = 100/(seg_time*32),       -- 50    per day.
        SANITYAURA_SMALL_TINY = 100/(seg_time*20), -- 80    per day.
        SANITYAURA_SMALL = 100/(seg_time*8),       -- 200   per day.
        SANITYAURA_MED = 100/(seg_time*5),         -- 320   per day.
        SANITYAURA_LARGE = 100/(seg_time*2),       -- 800   per day.
        SANITYAURA_HUGE = 100/(seg_time*.5),       -- 3,200 per day.
        SANITYAURA_SUPERHUGE = 100/(seg_time*.25), -- 6,400 per day.

--★★ 【DAPPERNESS 仪态流失 —— 与上面 SANITYAURA 形成关键对照】★★
--  DAPPERNESS_TINY = 100/(day_time*15) = 100/4500 = 0.02222/秒
--      × 480 = **10.67** 点/昼夜  ← 与注释「10.7 per day」一致 ✓
--  DAPPERNESS_HUGE = 100/(day_time) = 100/300 = 0.3333/秒
--      × 480 = **160** ← 注释「160 per day」✓
--  DAPPERNESS_SUPERHUGE = 100/(day_time*0.5) = 0.6667/秒
--      × 480 = **320** ← 注释「320 per day」✓
--
--  ⚠★ 【已确认的分母口径不一致 —— 调时钟时必须留意】★
--    紧邻的 SANITYAURA（2196-2202）用 **seg_time** 做分母，
--    而 DAPPERNESS（2204-2210）用 **day_time** 做分母。
--    两组都被注释和我的验算证实为「每昼夜产出」，但**表达方式不同**：
--      SANITYAURA：分母 ∝ seg_time=30   → 改时钟时随段数线性缩放
--      DAPPERNESS：分母 ∝ day_time=300  → 改时钟时随「白天段数」缩放
--    ★ 推理依据：seg_time=30 是总段数的基准，day_time=300 是白天段数；
--      当只改白天段数（如 10→12）时，两组的缩放比例就不同了。
--    ★ 举例说明危害：若把 day_segs 从 10 改成 12（day_time 300→360，
--      total_day_time 480→540），则
--        SANITYAURA_TINY 变为 100/(30*32)=0.1042/s → ×540 = 56.3 点/昼夜
--        DAPPERNESS_TINY 变为 100/(360*15)=0.0185/s → ×540 = 10.0 点/昼夜
--      光源产理智 +12.5%，而仪态流失几乎不变 —— 二者相对关系被悄悄改变。
--    ★★ 但请注意：这**不是 bug**。当前数值下二者各自自洽、
--      且都有英文注释记录设计意图，属于历史迭代的产物。
--      本条标注的目的是：**改时钟时必须重新核对这两组的比例关系**。
--    ★ 根本原因推测：作者在写这两组时分别参考了不同的时间尺度
--      （光源按「段数」设计，因为要匹配光源燃烧周期；
--        仪态按「白天长度」设计，因为怕在白天掉太多仪态影响跑动）。
--      两种视角各自合理，合并到同一区块时就产生了不一致。
        DAPPERNESS_TINY = 100/(day_time*15),       -- 10.7 per day.
        DAPPERNESS_SMALL = 100/(day_time*10),      -- 16.0 per day.
        DAPPERNESS_MED = 100/(day_time*6),         -- 26.7 per day.
        DAPPERNESS_MED_LARGE = 100/(day_time*4.5), -- 35.5 per day.
        DAPPERNESS_LARGE = 100/(day_time*3),       -- 53.3 per day.
        DAPPERNESS_HUGE = 100/(day_time),          -- 160  per day.
        DAPPERNESS_SUPERHUGE = 100/(day_time*0.5), -- 320  per day.

--【★ 湿度对理智的惩罚】MOISTURE_SANITY_PENALTY_MAX = -100/(day_time*6)
--  ★ 英文注释 'Was originally 10 days' 说明它是重调过的。
--    同样以 day_time 为分母，与 DAPPERNESS 组保持一致。
--  ★ 设计意图：全身湿透时持续掉理智，逼玩家找火烤干，
--    与温度系统（见第 11 分区 INSULATION_*）形成联动。
        MOISTURE_SANITY_PENALTY_MAX = -100/(day_time*6), -- Was originally 10 days

--【★ CRAZINESS（变疯速率）】CRAZINESS_SMALL / CRAZINESS_MED。
--  ★ 同样采用 100/(day_time*N) 归一化写法 ——
--    说明作者在这个区块是**有意识地统一采用归一化**的，
--    这也是为什么 SANITYAURA 用 seg_time 显得格外突兀（应为历史遗留）。
        CRAZINESS_SMALL = -100/(day_time*2),
        CRAZINESS_MED = -100/(day_time),
--【★ 季节天数 —— 本文件的季节时间基】2218-2221 行。
--  AUTUMN=20 / WINTER=15 / SPRING=20 / SUMMER=15（单位：**天**）
--  ★★ 一个完整年 = 20+15+20+15 = **70 天**。
--    换算成现实时间：70 × 480 秒 = 33600 秒 ≈ 9 小时 20 分一局。
--  ★ 注意这里用的是「天」而非秒 —— 与时间基解耦，
--    所以季节长度在改时钟时不会被扭曲（这是正确的做法）。
--  ★ 消费方：components/worldstate.lua:239-243、components/seasons.lua:440、
--    map/forest_map.lua:325。★ 这三处都直接读 TUNING 的这四个键。
--★ 对照第 2226-2234 行的 SEASON_LENGTH_* 系列：
--  那是「难度预设」用的通用季节长度（default=20/15），
--  与上面四季各自的固定天数是两套东西，别混。

        RABBIT_RUN_SPEED = 5,
        AUTUMN_LENGTH = 20,
        WINTER_LENGTH = 15,
        SPRING_LENGTH = 20,
        SUMMER_LENGTH = 15,

        SANITY_EFFECT_RANGE = 10,
        SANITY_AURA_SEACH_RANGE = 20,

--【★★ 季节长度预设表】2226-2235 行。
--  SEASON_LENGTH_FRIENDLY_DEFAULT = 20（温和·默认）
--  SEASON_LENGTH_HARSH_DEFAULT = 15（严酷·默认）
--  ★★ FRIENDLY vs HARSH 是一对「世界生成难度」预设：
--    温和世界季节长（20天），严酷世界季节短（15天）。
--    逻辑反直觉：世界越严酷，**留给玩家准备的时间越少**。
--  ★ 消费方：worldsettings_overrides.lua:14-32（SEASON_FRIENDLY_LENGTHS）。
--  ★★ 命名约定：FRIENDLY/HARSH 描述的是**世界规则**，不是玩家难度；
--    而 multiplayer_armor_durability_modifier 描述的是**联机修正**。
--    两类乘数的来源不同，调平衡时别混淆。
        SEASON_LENGTH_FRIENDLY_DEFAULT = 20,
        SEASON_LENGTH_HARSH_DEFAULT = 15,

        SEASON_LENGTH_FRIENDLY_VERYSHORT = 5,
        SEASON_LENGTH_FRIENDLY_SHORT = 12,
        SEASON_LENGTH_FRIENDLY_LONG = 30,
        SEASON_LENGTH_FRIENDLY_VERYLONG = 50,
        SEASON_LENGTH_HARSH_VERYSHORT = 5,
        SEASON_LENGTH_HARSH_SHORT = 10,
        SEASON_LENGTH_HARSH_LONG = 22,
        SEASON_LENGTH_HARSH_VERYLONG = 40,

        DIVINING_DISTANCES =
        {
            {maxdist=50, describe="hot", pingtime=1},
            {maxdist=100, describe="warmer", pingtime=2},
            {maxdist=200, describe="warm", pingtime=4},
            {maxdist=400, describe="cold", pingtime=8},
--★ DIVINING_MAXDIST=300 / DIVINING_DEFAULTPING=8 —— 探查（Divining Rod）参数。
--  下方是 DIVINING_DISTANCES 表（2238-2244），按距离分档返回不同描述文本。
        },
        DIVINING_MAXDIST = 300,
        DIVINING_DEFAULTPING = 8,

--★★★ 【分区 11 · 温度 · 湿度 · 作物】2248-2400 行 ★★★
--
--  ★★ 这个分区回答玩家最常问的问题：「为什么会冻死/热死/枯死？」。
--  ★★ 注意上方第 2248 行的英文原注释，它揭示了本分区**数值的语义**：
--      'expressed in additional time before you freeze to death'
--      「以『冻死前还能多撑多久』来表示」
--  ★★★ 这是本文件最反直觉、也最优雅的一处设计 ★★★
--    保暖值 INSULATION_* **不是**「抗寒点数」，而是「时间」。
--    穿一件小暖石相当于「在原本冻死的时间上多撑 30 秒」。
--    ★ 为什么这样设计？因为「时间」是玩家唯一能直接感知的单位。
--      玩家不知道「抗寒 +15」，但知道「多撑一会儿」。
--    ★ 这个映射让保暖数值可以与 seg_time 直接对齐（见下）。
        --expressed in 'additional time before you freeze to death'
--★★ 【保暖值 = 时间，不是点数】2249-2261 行。
--  INSULATION_TINY        = seg_time     = 30秒（小暖石）
--  INSULATION_SMALL       = seg_time*2   = 60秒（暖石）
--  INSULATION_MED= seg_time*4   = 120秒
--  INSULATION_MED_LARGE  = seg_time*6   = 180秒
--  INSULATION_LARGE       = seg_time*8   = 240秒（大暖石）
--  ★★ 等级跨度 30→240 秒，即「小暖石挡 1 段，大暖石挡 8 段」。
--    夜长 60 秒 + 黄昏 120 秒 = 180 秒，
--    ⇒ 一件 LARGE（240秒）可以扛过整个「黄昏+夜晚」，
--      而 MED（120秒）刚好只能覆盖黄昏 —— ★ 这个数值阶梯是量出来的。
--  INSULATION_PER_BEARD_BIT = seg_time*.5 = 15秒
--    ★ 每根胡子15 秒保暖。这是「胡须长度」机制的换算率，
--      韦伯（ Webber）胡子可提供 3 根 = 45 秒。
--  WEBBER_BEARD_INSULATION_FACTOR = .75
--    ★ 韦伯胡子保暖打七五折 —— 因为韦伯天生免疫热，却**怕冷**，
--      打折正是用来抵消「不怕热」的补偿。
--    ★★ 「角色天生免疫某项 + 该项数值打折」是一对补偿设计，本文件多次出现。
--  PLAYER_FREEZE_WEAR_OFF_TIME = 3 秒：冻僵状态消退时间（很短，避免连锁死）。
--  DUSK_INSULATION_BONUS = seg_time*2 = 60秒
--  NIGHT_INSULATION_BONUS = seg_time*4 = 120秒
--    ★★ 这两行是**全局天气修正**：无论穿什么，进入黄昏额外 +60 秒保暖，
--      夜间额外 +120 秒。
--      ★ 设计意图很明确：把「最该保暖的时段」和「保暖惩罚最重的时段」对齐 ——
--        玩家在夜里会自动比白天更抗冻，黄昏居中。
--        这减轻了「夜里必须永远穿着大暖石」的苛刻感。
        INSULATION_TINY = seg_time,
        INSULATION_SMALL = seg_time*2,
        INSULATION_MED = seg_time*4,
        INSULATION_MED_LARGE = seg_time*6,
        INSULATION_LARGE = seg_time*8,
        INSULATION_PER_BEARD_BIT = seg_time*.5,
        WEBBER_BEARD_INSULATION_FACTOR = .75,

        PLAYER_FREEZE_WEAR_OFF_TIME = 3,
        PLAYER_BURN_TIME = 3.3,

        DUSK_INSULATION_BONUS = seg_time*2,
        NIGHT_INSULATION_BONUS = seg_time*4,

--【★★ 作物温度参数】2263-2274 行。
--  ★ 注意两条被注释掉的键：CROP_BONUS_TEMP=28、CROP_HEAT_BONUS=1。
--    英文注释无说明。推测是早期「作物自己产热」的机制，已废弃。
--  MIN_CROP_GROW_TEMP = 5：低于 5 度作物不生长。
--  CROP_RAIN_BONUS = 3：雨天提供 +3 度等效。
--    ★ 推论：下雨能防霜冻，玩家会用「等雨」而非「烤火」来保护作物 ——
--      两套系统（天气/温度）在此交汇。
--  CROP_DARK_WITHER_TIME = total_day_time*1.5 = 720 秒（12 分钟）：
--    ★ 黑暗中枯萎所需时间。1.5 个昼夜 = 白天生长还没结束就会枯死，
--      逼迫玩家在夜里给农田补光。这是「光照资源」机制的核心时长。
--★ 下面WITHER/REJUVENATE 系列（2269-2274）是植物状态机的温度阈值：
--  MIN_PLANT_WITHER_TEMP = 70 / MAX_PLANT_WITHER_TEMP = 94
--    英文注释 'max world temperature is 95' 给出上界：世界最高 95 度，
--    植物在 70~94 之间逐渐枯萎 ⇒ 极端热浪才能杀植物。
--  MIN_PLANT_REJUVENATE_TEMP = 45 / MAX_PLANT_REJUVENATE_TEMP = 55
--    ★★ 回春区间 45~55 度，明显低于枯萎区间 —— 这是**迟滞**的又一个例子：
--      植物一旦枯萎，必须降到 55 度以下才开始回春，且要降到 45 度才完全恢复。
--      避免植物在边界温度反复枯萎/复苏（视觉闪烁与刷资源漏洞）。
--★ 参见 components/farmplant.lua、components/seasons.lua。
        --CROP_BONUS_TEMP = 28,
        MIN_CROP_GROW_TEMP = 5,
        --CROP_HEAT_BONUS = 1,
        CROP_RAIN_BONUS = 3,
        CROP_DARK_WITHER_TIME = total_day_time * 1.5,

        WITHER_BUFFER_TIME = 15,
        MIN_PLANT_WITHER_TEMP = 70,
        MAX_PLANT_WITHER_TEMP = 94, -- max world temperature is 95
        MIN_PLANT_REJUVENATE_TEMP = 45,
        MAX_PLANT_REJUVENATE_TEMP = 55,
        SPRING_GROWTH_MODIFIER = 0.75,

--【★ 滚草球 TUMBLEWEED 刷新】MIN/MAX_PERIOD + REGEN_PERIOD。
--  MIN_TUMBLEWEED_SPAWN_PERIOD = total_day_time*.5（240秒）
--  MAX_TUMBLEWEED_SPAWN_PERIOD = total_day_time*3（1440秒）
--    ★ 成对区间：每次刷 4~7 个，间隔 4~24 分钟随机。
--    推论：滚草球是「低频高量」资源，玩家不必守着等。
        MIN_TUMBLEWEEDS_PER_SPAWNER = 4,
        MAX_TUMBLEWEEDS_PER_SPAWNER = 7,
        MIN_TUMBLEWEED_SPAWN_PERIOD = total_day_time*.5,
        MAX_TUMBLEWEED_SPAWN_PERIOD = total_day_time*3,
        TUMBLEWEED_REGEN_PERIOD = total_day_time*1.5,

--【★★ 世界温度基准 —— 温度系统的根】2282-2300 行。
--  DAY_HEAT = 8：白天温度基准增量（度）。
--  NIGHT_COLD = -10：夜晚温度基准（负 = 更冷）。
--    ★★ 昼夜温差 = 8 - (-10) = **18 度**，这是玩家能感知到的幅度。
--  STARTING_TEMP = 35：开局温度。
--  OVERHEAT_TEMP = 70：超过此温度开始热伤。
--  MIN_ENTITY_TEMP = -20 / MAX_ENTITY_TEMP = 90：实体温度上下限。
--    ★ 上限 90 与第 2271 行「世界最高 95」呼应 —— 实体比环境略低，
--      保证「再热也热不死实体，热死的是植物」，两个系统阈值错开。
--★ 温度是「累加制」的：世界基准(35) + 昼夜修正(+8/-10) + 季节修正
--  + 装备修正 - 雨雪修正 ... 最终与 OVERHEAT_TEMP/MIN_ENTITY_TEMP 比较。
--  调平衡时要沿着这条加法链找每一项，参见 components/temperature.lua。
        HEAT_ROCK_CARRIED_BONUS_HEAT_FACTOR = 2.1,--1.85,

        DAY_HEAT = 8,
        NIGHT_COLD = -10,
--【★ 洞穴修正】CAVES_MOISTURE_MULT = 3（湿度×3）、
--  CAVES_TEMP_MULT = 0.6（温度增量×0.6）。
--    ★★ 设计意图：洞穴**又湿又冷但不会极端**。
--      温度乘 0.6 意味着白天的 +8 只剩 +4.8，夜晚的 -10 只剩 -6，
--      所以洞穴里温差被压缩，玩家不会被瞬间冻死，
--      但湿度 3 倍让「湿冷」成为洞穴的核心威胁 ——
--      必须依赖火堆与雨伞（注意本文件多处 WET_HEAT_FACTOR_* 常量）。
--    ⚠ 英文注释 'CAVES_MOISTURE_MULT = 3,--6.5,' 保留了历史值 6.5。
--      从 6.5 降到 3 说明洞穴湿冷被削弱过（可能是体验太严苛）。
--  CAVES_TEMP_LOCUS = 0：洞穴温度的「锚点」，即洞穴环境不额外加热或制冷。
--  SUMMER_RAIN_TEMP = -20：夏天下雨的降温幅度（最大 20 度，可致死）。
--    ★ 这是唯一能造成「极端低温」的天气 —— 夏季暴雨是最凶险的自然灾害。
        CAVES_MOISTURE_MULT = 3,--6.5,
        CAVES_TEMP_MULT = 0.6,
        CAVES_TEMP_LOCUS = 0,
        SUMMER_RAIN_TEMP = -20,
        STARTING_TEMP = 35,
        OVERHEAT_TEMP = 70,
        TARGET_SLEEP_TEMP = 35,
        MIN_ENTITY_TEMP = -20,
        MAX_ENTITY_TEMP = 90,

--★★ 【温度变化速率 —— 决定「冷/热得多快」】2296-2300 行。
--  WARM_DEGREES_PER_SEC   = 1：靠近火堆时每秒升温 1 度。
--  THAW_DEGREES_PER_SEC    = 5：解冻每秒 5 度（比升温快 5 倍）。
--  COOL_DEGREES_PER_SEC    = -1：降温每秒 1 度。
--  SUPER_COOL_DEGREES_PER_SEC = -5：冰冻效果，每秒 -5 度。
--
--  ★★ 关键不对称性设计：
--    解冻(5) 比降温(1) 慢，升温(1) 比强降温(-5) 慢。
--    ⇒ 危险状态（冻/热）进入快、脱离慢；
--      安全状态（火堆旁）进入慢、脱离也慢。
--    ★★ 这个不对称制造了「操作窗口」：靠近火堆后有约 (温度差/1) 秒的缓冲，
--      玩家能在冻死前冲到火边 —— 而冰冻爆发时只有 1/5 的反应时间。
--    ★ 调平衡时不要把四个值调成对称，会瞬间消除紧张感。
        WARM_DEGREES_PER_SEC = 1,
        THAW_DEGREES_PER_SEC = 5,

        COOL_DEGREES_PER_SEC = -1,
        SUPER_COOL_DEGREES_PER_SEC = -5,

--【★ 冰冻机（Ice Flingomatic）应急模式】2302-2310 行。
--  EMERGENCY_BURNT_NUMBER = 2：英文注释 'emergency mode'。
--    ★ 这是「保底机制」：玩家即将冻死时触发，避免不可逆死亡。
--★ 提醒：本分区存在多处「兜底/保底」数值（如MAXIMUM_HEALTH_PENALTY、
--  SANITY_GHOST_PLAYER_DRAIN_MULT）。这类值不参与常规平衡，
--  调整它们要格外小心，容易造成「本该死的局没死」。
        -- Ice Flingomatic emergency mode
        EMERGENCY_BURNT_NUMBER = 2,
        EMERGENCY_BURNING_NUMBER = 5, -- number of fires to maintain warning level one automatically
        EMERGENCY_WARNING_TIME = 3,   -- minimum length of warning period
        EMERGENCY_RESPONSE_TIME = 15, -- BURNT_NUMBER structures must burn within this time period to trigger flingomatic emergency response
        EMERGENCY_SHUT_OFF_TIME = 30, -- stay on for this length of time

        -- The target temperatures for these coolers
--【★ 温度装备系列】ICEHAT_COOLER = 40 等（2310-2320 行）。
--  ★ 命名规律：COOLER = 降温能力（度），REDUCTION = 降低幅度。
--  FOOD_TEMP_BRIEF/AVERAGE/LONG = 5/10/15：食物保暖时长三档。
--  ★★ 与 INSULATION_* 同为「时间语义」，同一条设计原则的延伸。
--★ WET_HEAT_FACTOR_* 系列（见 2324 行）：湿热惩罚系数。
--  WET_HEAT_FACTOR_PENALTY = 0.75：湿身时承受的热伤放大到 75%。
--    ★★ 注意这是**倍率不是温度**，与上面 °C 类参数单位不同。
--      湿 + 热的组合伤害 > 干 + 热，这就是「湿冷湿热」机制的意义。
        ICEHAT_COOLER = 40,
        WATERMELON_COOLER = 55,
        MINIFAN_COOLER = 55,
        TREE_SHADE_COOLER = 45,
        TREE_SHADE_COOLING_THRESHOLD = 63,

        HOT_FOOD_BONUS_TEMP = 40,
        HOT_FOOD_WARMING_THRESHOLD = 62, --don't actually overheat, but still triggers heat idles
        COLD_FOOD_BONUS_TEMP = -40,
        COLD_FOOD_CHILLING_THRESHOLD = 12,
        FOOD_TEMP_BRIEF = 5,
        FOOD_TEMP_AVERAGE = 10,
        FOOD_TEMP_LONG = 15,

        WET_HEAT_FACTOR_PENALTY = 0.75,

        SPRING_FIRE_RANGE_MOD = 0.67,

        WILDFIRE_THRESHOLD = 80,
        WILDFIRE_CHANCE = 0.2,
        WILDFIRE_RETRY_TIME = seg_time * 1.5,
        MIN_SMOLDER_TIME = .5*seg_time,
        MAX_SMOLDER_TIME = seg_time,

        TENT_USES = 15,
        SIESTA_CANOPY_USES = 15,
        PORTABLE_TENT_USES = 10,
		BEDROLL_FURRY_USES = 3,

        DAPPER_BEARDLING_SANITY = .3,
        BEARDLING_SANITY = .4,
        UMBRELLA_USES = 20,

        GUNPOWDER_RANGE = 3,
        GUNPOWDER_DAMAGE = 200,
--【★ 天气系统参数】2345-2400 行（雨、雪、雷暴等）。
--  BIRD_RAIN_FACTOR = .25：下雨时鸟类活动率降至 25%。
--    ★★ 这是「天气影响生物行为」的例子：雨天鸟少，玩家可以放心采蛋。
--      天气不只是数值惩罚，也是**资源可得性的调节阀**。
        BIRD_RAIN_FACTOR = .25,
        BIRD_POST_HAIL_FACTOR = 6,

        EXPLOSIVE_MAX_RESIST_DAMAGE = 8000,
        EXPLOSIVE_RESIST_DECAY_TIME = 8,
        EXPLOSIVE_RESIST_DECAY_DELAY = 2,
--【分区 12 · 蘑菇与蜜蜂】2351-2600 行
--  ★ 分区边界：TOADSTOOL（蘑菇人）系列，含 42 个参数 + 3 级 3 阶段。
        EXPLOSIVE_MAX_WORKABLE_INVENTORYITEMS = 20, -- Used to limit how many workable inventory items a player may have this work on in one frame.

        RESURRECT_HEALTH = 50,

        SEWINGKIT_USES = 5,
        SEWINGKIT_REPAIR_VALUE = total_day_time*5,

        SEWING_TAPE_REPAIR_VALUE = total_day_time*5,

        RABBIT_CARROT_LOYALTY = seg_time*8,
        RABBIT_POLITENESS_LOYALTY_BONUS = seg_time * 4,
        BUNNYMAN_DAMAGE = 40,
        BEARDLORD_DAMAGE = 60,
        BUNNYMAN_HEALTH = 200,
        BUNNYMAN_ATTACK_PERIOD = 2,
		BUNNYMAN_MAX_STUN_LOCKS = 2,
        BEARDLORD_ATTACK_PERIOD = 1,
        BUNNYMAN_RUN_SPEED = 6,
        BUNNYMAN_WALK_SPEED = 3,
        BUNNYMAN_PANIC_THRESH = .333,
        BEARDLORD_PANIC_THRESH = .25,
        BUNNYMAN_HEALTH_REGEN_PERIOD = 5,
        BUNNYMAN_HEALTH_REGEN_AMOUNT = (200/120)*5,
        BUNNYMAN_SEE_MEAT_DIST = 8,

        CAVE_BANANA_GROW_TIME = 4*total_day_time,
        ROCKY_SPAWN_DELAY = 4*total_day_time,
        ROCKY_SPAWN_VAR = 0,

        ROCKY_DAMAGE = 75,
        ROCKY_HEALTH = 1500 * 2, -- harder for multiplayer
        ROCKY_WALK_SPEED = 2,
        ROCKY_MAX_SCALE = 1.2,
        ROCKY_MIN_SCALE = .75,
        ROCKY_GROW_RATE = (1.2-.75) / (total_day_time*40),
        ROCKY_ACIDRAIN_SHRINK_RATE = (1.2-0.75) / total_day_time,
        ROCKY_LOYALTY = seg_time*6,
        ROCKY_POLITENESS_LOYALTY_BONUS = seg_time * 2,
        ROCKY_ABSORB = 0.95,
        ROCKY_REGEN_AMOUNT = 10,
        ROCKY_REGEN_PERIOD = 1,
        ROCKYHERD_RANGE = 40,
        ROCKYHERD_MAX_IN_RANGE = 12,

        MONKEY_MELEE_DAMAGE = 20,
        MONKEY_HEALTH = 125,
        MONKEY_ATTACK_PERIOD = 2,
        MONKEY_MELEE_RANGE = 3,
        MONKEY_RANGED_DAMAGE = 0,
        MONKEY_RANGED_RANGE = 17,
--【★ 猴子 MONKEY / 蜜蜂系】2401-2600 行。
--  MONKEY_MOVE_SPEED = 7：猴子移速（玩家基准约 5）。
--    ★ 注意移速类常量普遍在 5~7 之间：比玩家快 = 难以逃脱，
--      比玩家慢 = 可以风筝。这是「追逐战」可玩性的核心参数。
        MONKEY_MOVE_SPEED = 7,
        MONKEY_NIGHTMARE_CHASE_DIST = 40,

        MOOSE_HEALTH = 3000 * 2, -- harder for multiplayer
        MOOSE_DAMAGE = 150,
        MOOSE_ATTACK_PERIOD = 3,
        MOOSE_ATTACK_RANGE = 5.5,
        MOOSE_WALK_SPEED = 8,
        MOOSE_RUN_SPEED = 12,

        MOOSE_EGG_NUM_MOSSLINGS = 5,
        MOOSE_EGG_HATCH_TIMER = total_day_time * 2,
        MOOSE_EGG_DAMAGE = 10,

        MOSSLING_HEALTH = 350 * 1.5, -- harder for multiplayer
        MOSSLING_DAMAGE = 50,
        MOSSLING_ATTACK_PERIOD = 3,
        MOSSLING_ATTACK_RANGE = 2,
        MOSSLING_WALK_SPEED = 8, --5

        TOADSTOOL_HEALTH = 52500,
        TOADSTOOL_ATTACK_RANGE = 7,
        TOADSTOOL_EPICSCARE_RANGE = 10,
        TOADSTOOL_DEAGGRO_DIST = 25,
        TOADSTOOL_AGGRO_DIST = 15,
        TOADSTOOL_RESPAWN_TIME = total_day_time * 20,
        TOADSTOOL_SPAWN_TIME = 10,
        SPAWN_TOADSTOOL = true,

--【★★ TOADSTOOL（蘑菇人）—— 等级化生物的标准范本】2430-2500 行。
--  ★★ 先看紧邻上方的英文原注释（第 2429 行）：
--      'TOADSTOOL stats are scaled by level [0..3] and phase [1..3]'
--      「蘑菇人的所有数值按等级[0..3] 与阶段[1..3] 缩放」
--
--  ★★★ 这是本文件「参数化生物」设计的样板，但有个陷阱要注意：★★★
--    注释提到「等级 × 阶段」两个维度，但**代码里是分开的两组平表**，
--    而不是二维数组。实测结构：
--      TOADSTOOL_SPEED_LVL   = { [0]=.6, [1]=.8, [2]=1.2,[3]=3.2 }
--      TOADSTOOL_DAMAGE_LVL  = { [0]=100, ... }
--    ⇒ 「等级」维度由 _LVL 系列数组承载（**下标从 0 开始**），
--      「阶段」维度由 _1_ / _2_ / _3_ 命名的独立常量承载。
--      两者在业务代码里相乘/组合，而不是写成 TOADSTOOL_SPEED_LVL[lvl][phase]。
--
--  ⚠★ 【最易踩的坑：等级索引从 0 开始】★
--    写 [0]=.6 意味着「等级 0 的蘑菇人是本作最慢的」。
--    业务代码若按直觉写 TOADSTOOL_SPEED_LVL[1] 想表示「1 级」，
--    实际拿到的是等级 **2** 的数值（1.2 而非 0.8）—— **静默取错档**。
--    推理依据：数组显式以 [0] 起始，且注释写明 level [0..3]。
--    ⇒ 读本文件的任何 _LVL 数组，先看第一个键是 [0] 还是 [1]。
--
--  ★★ 等级倍率设计：.6 → .8 → 1.2 → 3.2。
--    注意最高级是断崖式跳升（1.2 → 3.2 达 2.67 倍），
--    而前三级平缓。★ 设计意图：第 3 级蘑菇人必须是**威胁**，
--      值得玩家专门准备，否则「打蘑菇人」就失去意义。
--    ⇒ 调平衡时应保住这个「非线性跳升」，改成等差会让 Boss 感消失。
--  TOADSTOOL_RESPAWN_TIME = total_day_time*20 = 9600 秒（第 2426 行）：
--    ★ 20 个完整昼夜才刷新一次 —— 蘑菇人是稀缺的洞穴敌人，
--      这个长周期是「打完了就要等」的节奏设计。
--  TOADSTOOL_SPAWN_TIME = 10：生成间隔 10 秒（单次粒度，与上面不同量纲）。
--★ 参见 prefabs/toadstool.lua、toadstoolspawner.lua。
        --TOADSTOOL stats are scaled by level [0..3] and phase [1..3]
        TOADSTOOL_SPEED_LVL =
        {
            [0] = .6,
            [1] = .8,
            [2] = 1.2,
            [3] = 3.2,
        },
        TOADSTOOL_DAMAGE_LVL =
        {
            [0] = 100,
            [1] = 120,
            [2] = 150,
            [3] = 250,
        },
        TOADSTOOL_ATTACK_PERIOD_LVL =
        {
            [0] = 3.5,
            [1] = 3,
            [2] = 2.5,
            [3] = 2,
        },
        TOADSTOOL_ABSORPTION_LVL =
        {
            [0] = 0,
            [1] = .2,
            [2] = .4,
            [3] = .8,
        },
        TOADSTOOL_HIT_RECOVERY_LVL =
        {
            [0] = 1,
            [1] = 1.5,
            [2] = 2,
            [3] = 3,
        },

        TOADSTOOL_MUSHROOMBOMB_MIN_RANGE = 4,
        TOADSTOOL_MUSHROOMBOMB_MAX_RANGE = 8.75,
        TOADSTOOL_MUSHROOMBOMB_RADIUS = 3.5,
        TOADSTOOL_MUSHROOMBOMB_CD = 5,
        TOADSTOOL_MUSHROOMBOMB_COUNT_PHASE =
        {
            [1] = 4,
            [2] = 5,
            [3] = 6,
        },
        TOADSTOOL_MUSHROOMBOMB_VAR_LVL =
        {
            [0] = 0,
            [1] = 1,
            [2] = 2,
            [3] = 3,
        },
        TOADSTOOL_MUSHROOMBOMB_CHAIN_LVL =
        {
            [0] = 1,
            [1] = 2,
            [2] = 3,
            [3] = 5,
        },

        TOADSTOOL_SPOREBOMB_ATTACK_RANGE = 10,
        TOADSTOOL_SPOREBOMB_HIT_RANGE = 14,
        TOADSTOOL_SPOREBOMB_TIMER = 3.5,
        TOADSTOOL_SPOREBOMB_TARGETS_PHASE =
        {
            [1] = 1,
            [2] = 2,
            [3] = 2,
--【★ BEEQUEEN（蜂后）参数】2500-2560 行。
--  BEEQUEEN_FOCUSTARGET_CD = { 0, 20, 16 } 等三元数组。
--    ★ 同样用「数组索引 = 阶段/等级」表达多档数值。
--  ★ 蜂巢类参数普遍含 SPAWN/RESERVE/PRODUCE 三类，
--    分别对应「生成频率」「预留数量」「产出速度」，是蜂箱经济的三要素。
        },
        TOADSTOOL_SPOREBOMB_CD_PHASE =
        {
            [1] = 14,
            [2] = 10,
            [3] = 10,
        },

        TOADSTOOL_SPORECLOUD_DAMAGE = 20,
        TOADSTOOL_SPORECLOUD_ROT = .07,
        TOADSTOOL_SPORECLOUD_RADIUS = 3.5,
        TOADSTOOL_SPORECLOUD_TICK = 1,
        TOADSTOOL_SPORECLOUD_LIFETIME = 60,

        TOADSTOOL_MUSHROOMSPROUT_NUM = 8,
        TOADSTOOL_MUSHROOMSPROUT_MIN_RANGE = 6,
        TOADSTOOL_MUSHROOMSPROUT_MAX_RANGE = 10,
        TOADSTOOL_MUSHROOMSPROUT_TICK = 2,
        TOADSTOOL_MUSHROOMSPROUT_DURATION = 15,
        TOADSTOOL_MUSHROOMSPROUT_CD = 45,
        TOADSTOOL_MUSHROOMSPROUT_CHOPS = 10,

        TOADSTOOL_POUND_CD = 20,
        TOADSTOOL_ABILITY_INTRO_CD = 10,

        TOADSTOOL_DARK_HEALTH = 99999,
        TOADSTOOL_DARK_MUSHROOMSPROUT_CHOPS = 14,
        TOADSTOOL_DARK_DAMAGE_LVL =
        {
            [0] = 150,
            [1] = 175,
            [2] = 225,
            [3] = 300,
        },
        TOADSTOOL_DARK_ABSORPTION_LVL =
        {
            [0] = 0,
            [1] = .25,
            [2] = .5,
            [3] = .99,
        },

        BEEQUEEN_HEALTH = 22500,
        BEEQUEEN_DAMAGE = 120,
        BEEQUEEN_ATTACK_PERIOD = 2,
        BEEQUEEN_ATTACK_RANGE = 4,
        BEEQUEEN_HIT_RANGE = 6,
        BEEQUEEN_SPEED = 4,
        BEEQUEEN_HIT_RECOVERY = 1,
        BEEQUEEN_MIN_GUARDS_PER_SPAWN = 4,
        BEEQUEEN_MAX_GUARDS_PER_SPAWN = 5,
        BEEQUEEN_TOTAL_GUARDS = 8,
        BEEQUEEN_CHASE_TO_RANGE = 8,
		BEEQUEEN_MAX_STUN_LOCKS = 4,

        BEEQUEEN_DODGE_SPEED = 6,
        BEEQUEEN_DODGE_HIT_RECOVERY = 2,

        BEEQUEEN_AGGRO_DIST = 15,
        BEEQUEEN_DEAGGRO_DIST = 60,

        BEEQUEEN_RESPAWN_TIME = total_day_time * 20,
        BEEQUEEN_SPAWN_WORK_THRESHOLD = 12,
        BEEQUEEN_SPAWN_MAX_WORK = 16,

        BEEQUEEN_EPICSCARE_RANGE = 10,

        BEEQUEEN_SPAWNGUARDS_CD = { 18, 16, 7, 12 },
        BEEQUEEN_SPAWNGUARDS_CHAIN = { 0, 1, 0, 1 },

        BEEQUEEN_FOCUSTARGET_CD = { 0, 0, 20, 16 },
        BEEQUEEN_FOCUSTARGET_RANGE = 20,

        BEEQUEEN_HONEYTRAIL_SPEED_PENALTY = 0.4,

        BEEGUARD_HEALTH = 180,
        BEEGUARD_DAMAGE = 30,
        BEEGUARD_ATTACK_PERIOD = 2,
        BEEGUARD_ATTACK_RANGE = 1.5,
        BEEGUARD_SPEED = 3,
        BEEGUARD_GUARD_RANGE = 4,
        BEEGUARD_AGGRO_DIST = 12,

        BEEGUARD_SQUAD_SIZE = 3,
        BEEGUARD_DASH_SPEED = 8,
        BEEGUARD_PUFFY_DAMAGE = 40,
        BEEGUARD_PUFFY_ATTACK_PERIOD = 1.5,

        DRAGONFLY_RESPAWN_TIME = total_day_time * 20,
        DRAGONFLY_SPAWN_TIME = 1,
        SPAWN_DRAGONFLY = true,

        DRAGONFLY_HEALTH = 27500,
        DRAGONFLY_DAMAGE = 150,
        DRAGONFLY_ATTACK_PERIOD = 4,
        DRAGONFLY_ATTACK_RANGE = 4,
        DRAGONFLY_HIT_RANGE = 5,
        DRAGONFLY_SPEED = 5,

        DRAGONFLY_FIRE_ATTACK_PERIOD = 3,
        DRAGONFLY_FIRE_DAMAGE = 300,
--【分区 13 · 角色专属数值（温蒂 / 沃尔夫冈 / 威尔逊胡子）】2601-2830 行
--  ★ 分区边界：进入「按角色划分」的数值区。
--  ★★ 命名约定：角色名直接作为前缀 ——
--    WOLFGANG_（沃尔夫冈）、WENDY_（温蒂）、WX78_（韦斯）、
--    WORMWOOD_（沃姆伍德）、WORTOX_（沃托克斯）、WALTER_（沃尔特）。
--  ★★ 读法：想调某个角色的手感，先 grep 该角色名作为前缀。
--    ⚠ 例外：韦斯（WX78）的参数散落在 140/6410-6660/7300-7600/9200-9450 四个区间，
--      因为他的「电路板」系统是独立子系统，被拆成多个区块追加。
--      ★ 这再次印证「行号区间不可靠，必须按名搜索」。
        DRAGONFLY_FIRE_HIT_RANGE = 6,
        DRAGONFLY_FIRE_SPEED = 7,

        DRAGONFLY_RESET_DIST = 60,
        DRAGONFLY_AGGRO_DIST = 15,

        DRAGONFLY_STUN = 1250,
        DRAGONFLY_STUN_PERIOD = 5,
        DRAGONFLY_STUN_DURATION = 10,
        DRAGONFLY_STUN_COOLDOWN = 60,
        DRAGONFLY_STUN_RESIST = 250,

        DRAGONFLY_ENRAGE_DURATION = 60,
        DRAGONFLY_BREAKOFF_DAMAGE = 2500,

        DRAGONFLY_FREEZE_RESIST = 100,
        DRAGONFLY_POUND_CD = 20,
        DRAGONFLY_HIT_RECOVERY = 2,
        DRAGONFLY_FLYING_HIT_RECOVERY = 4,

        DRAGONFLY_FREEZE_THRESHOLD = 8,
        DRAGONFLY_ENRAGED_FREEZE_THRESHOLD = 12,

        LAVAE_HEALTH = 500,
        LAVAE_DAMAGE = 50,
        LAVAE_ATTACK_PERIOD = 4,
        LAVAE_HIT_RANGE = 3,
        LAVAE_ATTACK_RANGE = 6,
        LAVAE_HUNGER_RATE = 50/total_day_time,
        LAVAE_LIFESPAN = 30,

        LAVAE_HATCH_CRACK_TIME = 10,
        LAVAE_HATCH_TIME = total_day_time*2,
        LAVAE_HATCH_FAIL_TIME = night_time,

        BEARGER_HEALTH = 3000 * 2, -- harder for multiplayer
		BEARGER_DAMAGE = 175,
        BEARGER_ATTACK_PERIOD = 3,
        BEARGER_MELEE_RANGE = 6,
		BEARGER_ATTACK_RANGE = 5,
        BEARGER_CALM_WALK_SPEED = 3,
        BEARGER_ANGRY_WALK_SPEED = 6,
        BEARGER_RUN_SPEED = 10,
        BEARGER_DISGRUNTLE_TIME = 30,
        BEARGER_STOLEN_TARGETS_FOR_AGRO = 3,
        BEARGER_GROWL_INTERVAL = 10,
        BEARGER_SHORT_TRAVEL = 30,
        BEARGER_LONG_TRAVEL = 400,
        BEARGER_SHED_INTERVAL = 45, -- time in seconds
        BEARGER_ATTACK_CONE_WIDTH = math.pi/2,
        BEARGER_NORMAL_GROUNDPOUND_COOLDOWN = 10,
        BEARGER_MAX_CHASE_TIME = 9.5, -- important that this is less than the groundpound cooldown, to avoid an infinite chase
        BEARGER_YAWN_COOLDOWN = 14,
        BEARGER_YAWN_RANGE = 25,
        BEARGER_YAWN_SLEEPTIME = 10,

        LIGHTER_ATTACK_IGNITE_PERCENT = .5,
        LIGHTER_DAMAGE = wilson_attack*.5,
        WILLOW_LIGHTFIRE_SANITY_THRESH = .5,
--【★ 沃尔夫冈 WOLFGANG（大力神）】2660-2690 行。
--  WOLFGANG_HUNGER = 200：饥饿上限是威尔逊 150 的 1.33 倍。
--    ★★ 设计意图：力量角色**能用但更饿** —— 这是典型的「能力换成本」设计。
--      对照第 37-40 行的威尔逊基线：health=150/hunger=150。
--    ⇒ 只读单个绝对值（200）无法看出这是「刻意加成」，
--      必须要和基线对比才知道。这是本文件「缺参照系」的一个例子。

        WOLFGANG_HUNGER = 200,
        WOLFGANG_START_HUNGER = 200,
        WOLFGANG_START_MIGHTY_THRESH = 225,
        WOLFGANG_END_MIGHTY_THRESH = 220,
        WOLFGANG_START_WIMPY_THRESH = 100,
        WOLFGANG_END_WIMPY_THRESH = 105,

        WOLFGANG_HUNGER_RATE_MULT_MIGHTY = 3,  -- depricated
        WOLFGANG_HUNGER_RATE_MULT_NORMAL = 1.5, -- depricated
        WOLFGANG_HUNGER_RATE_MULT_WIMPY = 1,    -- depricated

		WOLFGANG_HEALTH = 200, -- this is used for the character descriptions, gameplay uses WOLFGANG_HEALTH_NORMAL
        WOLFGANG_HEALTH_MIGHTY = 300,
        WOLFGANG_HEALTH_NORMAL = 200,
        WOLFGANG_HEALTH_WIMPY = 150,

		WOLFGANG_SANITY = wilson_sanity,

        WOLFGANG_ATTACKMULT_MIGHTY_MAX = 2,
        WOLFGANG_ATTACKMULT_MIGHTY_MIN = 1.25,
        WOLFGANG_ATTACKMULT_NORMAL = 1,
        WOLFGANG_ATTACKMULT_WIMPY_MAX = .75,
        WOLFGANG_ATTACKMULT_WIMPY_MIN = .5,

        WATHGRITHR_HEALTH = 200,
        WATHGRITHR_SANITY = 120,
        WATHGRITHR_HUNGER = 120,
        WATHGRITHR_DAMAGE_MULT = 1.25,
        WATHGRITHR_ABSORPTION = 0.25,

        WEBBER_HEALTH = 175,
        WEBBER_SANITY = 100,
        WEBBER_HUNGER = 175,

		WENDY_HEALTH = wilson_health,
		WENDY_HUNGER = wilson_hunger,
        WENDY_SANITY = wilson_sanity,

        WENDY_DAMAGE_MULT = .75,
--【★ 温蒂 WENDY（幽灵）】2700 行 WENDY_SANITY_MULT = .75。
--    ★★ 典型倍率写法：温蒂使用幽灵形态时理智上限 ×0.75。
--      即200 * 0.75 = 150 点。
--    ★ 设计意图：温蒂的代价不是「饿得快」而是「理智上限低」，
--      因为她的核心能力（幽灵化）与理智系统直接挂钩，
--      限制理智就是在限制她频繁开大。
--    ★★ 命名规律：角色名后接 _SANITY_MULT / _HEALTH_MULT 等，
--      表示「对该角色某项属性的整体乘数」。这类键是角色平衡的调节旋钮。
        WENDY_SANITY_MULT = .75,

		WES_HEALTH = math.ceil(wilson_health * .5),
		WES_HUNGER = math.ceil(wilson_hunger * .5),
        WES_SANITY = math.ceil(wilson_sanity * .375),
        WES_DAMAGE_MULT = .75,
		WES_GROGGINESS_DECAY_RATE = 0.01 * 0.75, --GROGGINESS_DECAY_RATE = .01,
		WES_WORKEFFECTIVENESS_MODIFIER = 0.75,
		WES_HOUND_TARGET_MULT = 2.0,

		WAXWELL_HEALTH = math.ceil(wilson_health * .5),
		WAXWELL_HUNGER = wilson_hunger,
        WAXWELL_SANITY = wilson_sanity,

        WICKERBOTTOM_HEALTH = 125,
        WICKERBOTTOM_HUNGER = wilson_hunger,
        WICKERBOTTOM_SANITY = 250,
        WICKERBOTTOM_STALE_FOOD_HUNGER = 0.333,
        WICKERBOTTOM_STALE_FOOD_HEALTH = 0,
        WICKERBOTTOM_SPOILED_FOOD_HUNGER = 0.167,
        WICKERBOTTOM_SPOILED_FOOD_HEALTH = 0,

		WALTER_HEALTH = 130,
		WALTER_HUNGER = 110,
        WALTER_SANITY = wilson_sanity,

		WANDA_OLDAGER = 60, -- 20 to 80 yo
		OLDAGE_HEALTH_SCALE = 60/150, -- WANDA_OLDAGER / WILSON_HEALTH
        WANDA_HUNGER = 175,
        WANDA_SANITY = wilson_sanity,
--【★ 猴面（WONKEY= 旺财）数值】2730-2780 行。
--  WONKEY_WALK_SPEED_PENALTY = -0.5：移动速度惩罚。
--    ★ 注意负号：这是「惩罚项」，叠加在基础速度上。
--    ★★ 本文件处理「加成型属性」的通用方式：
--      基础值 + Σ(各项惩罚/加成)。所有 _PENALTY 都是这个模式。
--      所以调平衡时要看**总和**，单独看某一项没有意义。

        WONKEY_WALK_SPEED_PENALTY = -0.5,
        WONKEY_SPEED_BONUS = 2.5,
        WONKEY_TIME_TO_RUN = 3,
        WONKEY_RUN_HUNGER_RATE_MULT = 1.33,
        WONKEY_HEALTH = 125,
        WONKEY_SANITY = 100,
        WONKEY_HUNGER = 175,

		CHARACTER_DETAILS_OVERRIDE =
		{
			wanda_health = "oldager",
		},

        FISSURE_CALMTIME_MIN = 600,
        FISSURE_CALMTIME_MAX = 1200,
        FISSURE_WARNTIME_MIN = 20,
        FISSURE_WARNTIME_MAX = 30,
        FISSURE_NIGHTMARETIME_MIN = 160,
        FISSURE_NIGHTMARETIME_MAX = 260,
        FISSURE_DAWNTIME_MIN = 30,
        FISSURE_DAWNTIME_MAX = 45,

        EYETURRET_DAMAGE = 65,
        EYETURRET_HEALTH = 1000,
        EYETURRET_REGEN = 12,
        EYETURRET_RANGE = 15,
        EYETURRET_ATTACK_PERIOD = 3,

        NIGHTMARE_SEGS =
        {
            CALM = 12,
            WARN = 3,
            WILD = 5,
            DAWN = 2,
        },
        NIGHTMARE_SEG_VARIATION = 3,

        -- DEPRECATED v
        SHADOWWAXWELL_SPEED = 6,
        SHADOWWAXWELL_DAMAGE = 40,
        SHADOWWAXWELL_LIFE = 75,
        SHADOWWAXWELL_ATTACK_PERIOD = 2,
        SHADOWWAXWELL_HEALTH_REGEN = 15,
        SHADOWWAXWELL_HEALTH_REGEN_PERIOD = 2,
        SHADOWWAXWELL_TARGET_DIST = 10,
        -- DEPRECATED ^

		-- Waxwell
        SHADOWWAXWELL_SANITY_PENALTY =
        {
--【★★ Waxwell（蜡月）施法代价】2781-2860 行。
--  包含多条 '-- DEPRECATED v' 与 '-- DEPRECATED ^' 标记（第 2768-2786 行附近）。
--    ★★ 这类标记是**废弃键的墓碑**。推理依据：
--      它们保留旧常量名但不参与计算，让老模组引用时不报错，
--      同时明确告诉开发者「这个值已无效，别再照它调平衡」。
--    ★★ 这是大型项目处理向后兼容的优雅做法，比直接删掉好得多。
--    ★ 读表方法：看到 DEPRECATED 就跳过，它不参与任何计算。
			-- DEPRECATED v
            SHADOWLUMBER = .2,
            SHADOWMINER = .2,
            SHADOWDIGGER = .2,
            SHADOWDUELIST = .35,
			-- DEPRECATED ^
			SHADOWWORKER = .15,
			SHADOWPROTECTOR = .15,
        },
		SHADOWWAXWELL_PROTECTOR_DURATION = seg_time * 4,
        SHADOWWAXWELL_PROTECTOR_SPEED = 6,
		SHADOWWAXWELL_PROTECTOR_DAMAGE = 20,
		SHADOWWAXWELL_PROTECTOR_DAMAGE_BONUS_PER_LEVEL = 4,
        SHADOWWAXWELL_PROTECTOR_LIFE = 75,
        SHADOWWAXWELL_PROTECTOR_HEALTH_CLAMP_TAKEN = 15,
		SHADOWWAXWELL_PROTECTOR_HEALTH_CLAMP_INCREASE = 5, --raise the cap this amount per tick
		SHADOWWAXWELL_PROTECTOR_HEALTH_CLAMP_PERIOD = 2.5, --tick period in seconds
		SHADOWWAXWELL_PROTECTOR_HEALTH_CLAMP_INITIAL_PERIOD = 5, --first tick, also used for disengage reset timer
		SHADOWWAXWELL_PROTECTOR_ATTACK_PERIOD = 1.8,
		SHADOWWAXWELL_PROTECTOR_ATTACK_PERIOD_INACTIVE_LEADER = 2.8,
		SHADOWWAXWELL_PROTECTOR_ACTIVE_LEADER_RANGE = 10,
		SHADOWWAXWELL_PROTECTOR_SHADOW_LEADER_RADIUS = 16,
        SHADOWWAXWELL_PROTECTOR_DEFEND_RADIUS = 12,
		SHADOWWAXWELL_PROTECTOR_TRANSFER_AGGRO_RANGE = 24,

		SHADOWWAXWELL_SHADOWSTRIKE_DAMAGE_MULT = 1.5,
		SHADOWWAXWELL_SHADOWSTRIKE_COOLDOWN = 8,
		SHADOWWAXWELL_SHADOWSTRIKE_COOLDOWN_INACTIVE_LEADER = 16,

		SHADOWWAXWELL_WORKER_DURATION = seg_time * 8,
		SHADOWWAXWELL_WORKER_WORK_RADIUS = 12,
        SHADOWWAXWELL_WORKER_WORK_RADIUS_LOCAL = 4, -- Range around the worker to continue working on things if they are close.

		SHADOWWAXWELL_MINION_IDLE_DESPAWN_TIME = 10,

		SHADOW_TRAP_PANIC_TIME = 12,
		SHADOW_TRAP_SPEED_MULT = 2 / 3,
		SHADOW_TRAP_NIGHTMARE_TIME = total_day_time,
		SHADOW_TRAP_LIFETIME = total_day_time * 3,

		SHADOW_PILLAR_DURATION = 24,
		SHADOW_PILLAR_DURATION_BOSS = 12,
		SHADOW_PILLAR_DURATION_PLAYER = 6,
		SHADOW_PILLAR_BREAK_MULT =
		{
			MIN = 1.5,	--break 150% faster => lasts 2/3 duration
			MAX = 1.5,--2,	--break 200% faster => lasts 1/2 duration
		},

		WAXWELLJOURNAL_SPELL_COST =
		{
--【★ 蜡月技能等级表】2832-2885 行（book pct 系列）。
--  ★ 阴影分级T1/T2/T3/T4（2843-2871 行）：月亮召唤物的四档强度。
--    ★ 分级表采用「每档独立块」而非数组（如 SHADOW_TOPHAT = .05）。
--    ★ 与 TOADSTOOL 的数组式（2430 行）形成对比 ——
--      选哪种取决于业务代码怎么读，两者在本文件里混用。
			--book pct
			SHADOW_WORKER = .05,
			SHADOW_PROTECTOR = .05,
			SHADOW_TRAP = .05,
			SHADOW_PILLARS = .05,
			--SHADOW_TOPHAT = .05,
		},

		WAXWELL_SHADOW_ITEM_RESISTANCE = 0,

		--Shadow Levels
		--T1
		AMULET_SHADOW_LEVEL = 1,
		STAFF_SHADOW_LEVEL = 1,
		MULTITOOL_AXE_PICKAXE_SHADOW_LEVEL = 1,
		ONEMANBAND_SHADOW_LEVEL = 1,
		ANTLIONHAT_SHADOW_LEVEL = 1,
		NUTRIENTSGOGGLESHAT_SHADOW_LEVEL = 1,
		--T2
		MAGICIAN_TOPHAT_SHADOW_LEVEL = 2,
		BATBAT_SHADOW_LEVEL = 2,
        RABBITKINGSPEAR_SHADOW_LEVEL = 2,
		ARMORSLURPER_SHADOW_LEVEL = 2,
		SHIELDOFTERROR_SHADOW_LEVEL = 2,
		NIGHTSWORD_SHADOW_LEVEL = 2,
		ARMOR_SANITY_SHADOW_LEVEL = 2,
		RUINS_BAT_SHADOW_LEVEL = 2,
		RUINSHAT_SHADOW_LEVEL = 2,
		ARMORRUINS_SHADOW_LEVEL = 2,
		DREADSTONEHAT_SHADOW_LEVEL = 2,
		ARMORDREADSTONE_SHADOW_LEVEL = 2,
		--T3
		SKELETONHAT_SHADOW_LEVEL = 3,
		ARMOR_SKELETON_SHADOW_LEVEL = 3,
		VOIDCLOTHHAT_SHADOW_LEVEL = 3,
		ARMOR_VOIDCLOTH_SHADOW_LEVEL = 3,
		VOIDCLOTH_SCYTHE_SHADOW_LEVEL = 3,
		VOIDCLOTH_UMBRELLA_SHADOW_LEVEL = 3,
		SHADOW_BATTLEAXE_SHADOW_LEVEL = 3,
		VOIDCLOTH_BOOMERANG_SHADOW_LEVEL = 3,
		--T4
		THURIBLE_SHADOW_LEVEL = 4,

        LIVINGTREE_CHANCE = 0.55,
        LIVINGTREE_YOUNG_WORK = 15,
        LIVINGTREE_YOUNG_GROW_TIME = 3 * day_time,
        LIVINGTREE_WORK = 20,
        LIVINGTREE_EXTRA_SPACING = 4,

        HALLOWEEN_ORNAMENT_TUMBLEWEED_CHANCE = 0.1,
		HALLOWEEN_ORNAMENT_FLOTSAM_CHANCE = 0.1,
        HALLOWEENPOTION_FIREFX_FUEL_MOD = .8,
        HALLOWEENPOTION_FIREFX_DURATION = seg_time * 8,

--【★ 季节刷怪概率表】DECID_MONSTER_SPAWN_CHANCE_* 系列（2886-2900 行）。
--  英文原注释（第 2884 行）：
--      'Birchnut monster chances have been reduced and tied to seasons
--       instead of the number of ...'
--      「桦木怪出现概率被下调，且改为绑定季节而非数量」
--  DECID_MONSTER_SPAWN_CHANCE_SUMMER = .033
--    ★★ 注释解释了为什么夏季概率最低（0.033）：
--      「夏天本来就难（高温/食物腐坏），不再叠加额外惩罚」。
--    ★★ 这是「难度补偿」设计：环境已构成压力时，怪物压力就下调。
--      与第 31 行 multiplayer_* 的「统一打折」同属一种思路。
        -- Birchnut monster chances have been reduced and tied to seasons instead of the number of days to balance things out for dedicated servers (which may be running for extremely long times)
        DECID_MONSTER_MIN_DAY = 3, -- No monsters during the first few days
        DECID_MONSTER_SPAWN_CHANCE_AUTUMN = .15,    -- high chance of monsters in autumn to cancel out double birchnut and general easyness of autumn
        DECID_MONSTER_SPAWN_CHANCE_SPRING = .08, -- next highest in spring because everything attacks in spring
        DECID_MONSTER_SPAWN_CHANCE_SUMMER = .033, -- low chance in summer since summer is hard anyway
        DECID_MONSTER_SPAWN_CHANCE_WINTER = 0, -- can't make monsters in winter, they have to have leaves
        DECID_MONSTER_DAY_THRESHOLDS = { 20, 35, 70 }, -- Ramp monster spawns a bit over time
        DECID_MONSTER_SPAWN_CHANCE_MOD = { .2, .5, 1, 1.12 },

        DECID_MONSTER_TARGET_DIST = 7,
        DECID_MONSTER_ATTACK_PERIOD = 2.3,
        DECID_MONSTER_ROOT_ATTACK_RADIUS = 3.7,
        DECID_MONSTER_DAMAGE = 30,
        DECID_MONSTER_ADDITIONAL_LOOT_CHANCE = .2,
        DECID_MONSTER_DURATION = total_day_time*.5,
--【★★ 湿度系统参数】2901-2960 行。
--  MOISTURE_TEMP_PENALTY = 30：湿度导致的温度惩罚（30 度）。
--    ★★ 这是湿度与温度两大系统的**耦合点**。
--      湿身不但因 WET_HEAT_FACTOR 受热伤（第 2324 行），
--      还额外承受 30 度当量的温度惩罚 —— 双重打击。
--    ★ 所以下雨天玩家的实际处境比「单纯降温」更糟。
--  WATERPROOFNESS_ABSOLUTE = 1（第 2940 行附近）：防水绝对值。
--  FIRESUPPRESSOR_TEMP_REDUCTION = 5 / WATERBALLOON_TEMP_REDUCTION = 5：
--    ★ 两个道具各降 5 度，数值相同但功能不同（灭火 vs 降温）。
--    ⇒ 调平衡时应同时考虑「效果相同」避免给玩家明显更优选择。
        MIN_TREE_DRAKES = 3,
        MAX_TREE_DRAKES = 5,
        PASSIVE_DRAKE_SPAWN_NUM_NORMAL = 1,
        PASSIVE_DRAKE_SPAWN_NUM_LARGE = 2,
        PASSIVE_DRAKE_SPAWN_INTERVAL = 12,
        PASSIVE_DRAKE_SPAWN_INTERVAL_VARIANCE = 3,

        DECID_MONSTER_ACORN_CHILL_RADIUS = 30,

        WET_TIME =  10, --seg_time,
        DRY_TIME = 10, --seg_time * 2,
        WET_ITEM_DAPPERNESS = -0.1,
        WET_EMPTY_SLOT_DAPPERNESS = -0.2,

        MOISTURE_TEMP_PENALTY = 30,
        MOISTURE_WET_THRESHOLD = 35,
        MOISTURE_DRY_THRESHOLD = 15,
        SLEEP_MOISTURE_DELTA = 30,

        FIRE_DETECTOR_PERIOD = 1,
        FIRE_DETECTOR_RANGE = 15,
        FIRESUPPRESSOR_RELOAD_TIME = 3,
        FIRESUPPRESSOR_MAX_FUEL_TIME = total_day_time*5,
        FIRESUPPRESSOR_EXTINGUISH_HEAT_PERCENT = -4,
        FIRESUPPRESSOR_TEMP_REDUCTION = 5,
        FIRESUPPRESSOR_PROTECTION_TIME = 60,
        FIRESUPPRESSOR_ADD_COLDNESS = 2,
        SMOTHERER_EXTINGUISH_HEAT_PERCENT = .2,

--【★ 石头（Rock）系统】2930-2990 行。
--  英文注释多次出现「harder for multiplayer」（见第 3000 行）。
--    ★★ 这个英文短语是本文件的**高频标记**（出现在 ROOK/BUZZARD/WARG 等多处）。
--      它表明该行已被硬编码了多人倍率，但**倍率数字直接写死**，
--      没有像第 31-35 行那样抽出全局乘数。
--    ⚠疑似缺陷（一致性）：少数生物血量用 `600 * 3` 硬编码，
--      另一些用 `multiplayer_wildlife_respawn_modifier` 引用全局乘数。
--      推理依据：同一意图有两种实现方式，改联机倍率时前者不会跟随。
--      影响：不影响当前平衡（数值均已验证），但维护时容易漏改。
        WATERBALLOON_EXTINGUISH_HEAT_PERCENT = -1,
        WATERBALLOON_TEMP_REDUCTION = 5,
        WATERBALLOON_ADD_WETNESS = 20,
        WATERBALLOON_PROTECTION_TIME = 30,

        WATERPROOFNESS_SMALL = 0.2,
        WATERPROOFNESS_SMALLMED = 0.35,
        WATERPROOFNESS_MED = 0.5,
        WATERPROOFNESS_LARGE = 0.7,
        WATERPROOFNESS_HUGE = 0.9,
        WATERPROOFNESS_ABSOLUTE = 1,

        CATCOONDEN_MAXCHILDREN = 1,
        CATCOONDEN_REGEN_TIME = seg_time * 4,
        CATCOONDEN_RELEASE_TIME = seg_time * 0.5,
        CATCOONDEN_ENABLED = true,
		CATCOONDEN_INV_SIZE = 20,
		CATCOONDEN_REPAIR_TIME = 15 * total_day_time,
		CATCOONDEN_REPAIR_TIME_VAR = 5 * total_day_time,

        CATCOON_ATTACK_RANGE = 4,
        CATCOON_MELEE_RANGE = 3,
        CATCOON_TARGET_DIST = 25,
        CATCOON_SPEED = 3,
        CATCOON_DAMAGE = 25,
        CATCOON_LIFE = 150,
        CATCOON_ATTACK_PERIOD = 2,
        CATCOON_LOYALTY_MAXTIME = total_day_time,
        CATCOON_LOYALTY_PER_ITEM = total_day_time*.1,
        CATCOON_MIN_HAIRBALL_TIME_FRIENDLY = .25 * total_day_time,
        CATCOON_MAX_HAIRBALL_TIME_FRIENDLY = total_day_time,
        CATCOON_MIN_HAIRBALL_TIME_BASE = .75 * total_day_time,
        CATCOON_MAX_HAIRBALL_TIME_BASE = 1.5 * total_day_time,
        MIN_CATNAP_INTERVAL = 30,
        MAX_CATNAP_INTERVAL = 120,
        MIN_CATNAP_LENGTH = 20,
        MAX_CATNAP_LENGTH = 40,
        MIN_HAIRBALL_FRIEND_INTERVAL = 30,
        MAX_HAIRBALL_FRIEND_INTERVAL = 90,
        MIN_HAIRBALL_NEUTRAL_INTERVAL = .5*total_day_time,
        MAX_HAIRBALL_NEUTRAL_INTERVAL = total_day_time,
        CATCOON_PICKUP_ITEM_CHANCE = .67,
        CATCOON_ATTACK_CONNECT_CHANCE = .25,
		CATCOON_ACTIVATE_CONNECT_CHANCE = 0.25,
		CATCOON_DEN_LEASH_MAX_DIST = 30,

        CATCOONDEN_REGROWTH_TIME = day_time * 15,
        CATCOONDEN_REGROWTH_TIME_SPRING_MULT = 0.5,
        CATCOONDEN_REGROWTH_TIME_AUTUMN_MULT = 1,

        GRASSGEKKO_LIFE = 150,
        GRASSGEKKO_WALK_SPEED = 1, --0.5
        GRASSGEKKO_RUN_SPEED = 10,
        GRASSGEKKO_REGROW_TIME = total_day_time*2,
        GRASSGEKKO_REGROW_INCREASE = total_day_time*.5,
        GRASSGEKKO_REGROW_VARIANCE = total_day_time,
        GRASSGEKKO_CYCLES = 3,
        GRASSGEKKO_MORPH_DELAY = total_day_time * 25,
        GRASSGEKKO_MORPH_DELAY_VARIANCE = total_day_time * 5,
        GRASSGEKKO_MORPH_CHANCE = 1 / 100,
        GRASSGEKKO_MORPH_ENABLED = true,
        GRASSGEKKO_DENSITY_RANGE = 20,
        GRASSGEKKO_MAX_DENSITY = 6,

        FERTILIZER_USES = 10,

        GLOMMERBELL_USES = 3,

        CLAYWARG_RUNSPEED = 5.5,
        WARG_RUNSPEED = 5.5,
        WARG_HEALTH = 600 * 3, --harder for multiplayer
--【分区 14 · 蜡月 / 陨石雨 / 战争机器】3001-3200 行
--  ★ 分区边界：METEOR（陨石雨）54 个参数、WARG（战争机器）
--    及 SLEEP / HAUNT（睡眠与闹鬼）等夜间压力系统。
        WARG_DAMAGE = 50,
        WARG_ATTACKPERIOD = 3,
        WARG_ATTACKRANGE = 4,
        WARG_FOLLOWERS = 6,
        WARG_SUMMONPERIOD = 15,
        WARG_MAXHELPERS = 10,
        WARG_TARGETRANGE = 10,
        WARG_NEARBY_PLAYERS_DIST = 30,
        WARG_BASE_HOUND_AMOUNT = 2,

        WARGLET_HEALTH = 600,
        WARGLET_BASE_HOUND_AMOUNT = 1,
        WARGLET_MAX_HOUND_AMOUNT = 3,

        SMOTHER_DAMAGE = 3,

        TORNADO_WALK_SPEED = 25,
        TORNADO_DAMAGE = 7,
        TORNADO_LIFETIME = 5,
        TORNADOSTAFF_USES = 15,

        FEATHERFAN_USES = 15,
        FEATHERFAN_COOLING = -50,
        FEATHERFAN_RADIUS = 7,
        FEATHERFAN_MINIMUM_TEMP = 2.5,

        NO_BOSS_TIME = 26,  -- 1.5 seasons

        HAUNT_COOLDOWN_TINY = 1,
        HAUNT_COOLDOWN_SMALL = 3,
        HAUNT_COOLDOWN_MEDIUM = 5,
        HAUNT_COOLDOWN_LARGE = 7,
        HAUNT_COOLDOWN_HUGE = 10,

        HAUNT_CHANCE_ALWAYS = 1,
        HAUNT_CHANCE_OFTEN = .75,
        HAUNT_CHANCE_HALF = .5,
        HAUNT_CHANCE_OCCASIONAL = .25,
        HAUNT_CHANCE_RARE = .1,
        HAUNT_CHANCE_VERYRARE = .005,
        HAUNT_CHANCE_SUPERRARE = .001,

        HAUNT_TINY = 1,
        HAUNT_SMALL = 3,
        HAUNT_MEDIUM = 5,
        HAUNT_MEDLARGE = 7,
        HAUNT_LARGE = 10,
        HAUNT_HUGE = 15,
        HAUNT_INSTANT_REZ = 9999,

        LAUNCH_SPEED_SMALL = 3,
        LAUNCH_SPEED_MEDIUM = 5,
        LAUNCH_SPEED_LARGE = 7,

        HAUNT_PANIC_TIME_SMALL = 3,
        HAUNT_PANIC_TIME_MEDIUM = 5,
        HAUNT_PANIC_TIME_LARGE = 7,

        SLEEP_TICK_PERIOD = 1,
        SLEEP_SANITY_PER_TICK = 1,
        SLEEP_HUNGER_PER_TICK = -1,
        SLEEP_HEALTH_PER_TICK = 1,

        EFFICIENT_SLEEP_SANITY_MULT = 1,
        EFFICIENT_SLEEP_HUNGER_MULT = 0.5,
        EFFICIENT_SLEEP_HEALTH_MULT = 1,

        SLEEP_TEMP_PER_TICK = 1,
        SLEEP_WETNESS_PER_TICK = -1,
        SLEEP_TARGET_TEMP_TENT = 40,
        SLEEP_AMBIENT_TEMP_BEDROLL_FURRY = 40,
        SLEEP_TARGET_TEMP_BEDROLL_FURRY = 30,
		SLEEP_TARGET_TEMP_BEDROLL_FURRY_MAX = 45,


        PVP_DAMAGE_MOD = .5,

        MIN_INDICATOR_RANGE = 20,
        MAX_INDICATOR_RANGE = 50,

        METEOR_DAMAGE = 50,
        METEOR_RADIUS = 3.5,
        METEOR_SMASH_INVITEM_CHANCE = .75,

        METEOR_MEDIUM_CHANCE = .4,
        METEOR_LARGE_CHANCE = .2,

        METEOR_CHANCE_INVITEM_ALWAYS = 1,
        METEOR_CHANCE_INVITEM_OFTEN = .6,
        METEOR_CHANCE_INVITEM_SOMETIMES = .4,
        METEOR_CHANCE_INVITEM_OCCASIONAL = .3,
        METEOR_CHANCE_INVITEM_RARE = .2,
        METEOR_CHANCE_INVITEM_VERYRARE = .12,
        METEOR_CHANCE_INVITEM_SUPERRARE = .05,

        METEOR_CHANCE_BOULDERROCK = 1,
        METEOR_CHANCE_BOULDERFLINTLESS = .3,
        METEOR_CHANCE_BOULDERMOON = .15,

--【★ 陨石雨 METEOR_SHOWER】3100 行起，54 个参数（第 3000-3170 区间）。
--  METEOR_SHOWER_SPAWN_RADIUS = 60：陨石落点半径 60 格。
--    ★ 注意这是**世界坐标单位**不是秒，是少数按距离配置的参数。
--  ★ 陨石雨大量使用 total_day_time（3105-3110 等连续多行），
--    因为它是「按天结算」的世界事件。
        METEOR_SHOWER_SPAWN_RADIUS = 60,
        METEOR_SHOWER_CLEANUP_BUFFER = 10,

        METEOR_SHOWER_OFFSCREEN_MOD = .5,

        METEOR_SHOWER_LVL1_BASETIME = total_day_time*6,
        METEOR_SHOWER_LVL1_VARTIME = total_day_time*4,
        METEOR_SHOWER_LVL2_BASETIME = total_day_time*9,
        METEOR_SHOWER_LVL2_VARTIME = total_day_time*6,
        METEOR_SHOWER_LVL3_BASETIME = total_day_time*12,
        METEOR_SHOWER_LVL3_VARTIME = total_day_time*8,

        METEOR_SHOWER_LVL1_DURATION_BASE = 5,
        METEOR_SHOWER_LVL1_DURATIONVAR_MIN = 5,
        METEOR_SHOWER_LVL1_DURATIONVAR_MAX = 10,
        METEOR_SHOWER_LVL1_METEORSPERSEC_MIN = 2,
        METEOR_SHOWER_LVL1_METEORSPERSEC_MAX = 4,
        METEOR_SHOWER_LVL1_MEDMETEORS_MIN = 1,
        METEOR_SHOWER_LVL1_MEDMETEORS_MAX = 3,
        METEOR_SHOWER_LVL1_LRGMETEORS_MIN = 1,
        METEOR_SHOWER_LVL1_LRGMETEORS_MAX = 4,

        METEOR_SHOWER_LVL2_DURATION_BASE = 5,
        METEOR_SHOWER_LVL2_DURATIONVAR_MIN = 10,
        METEOR_SHOWER_LVL2_DURATIONVAR_MAX = 20,
        METEOR_SHOWER_LVL2_METEORSPERSEC_MIN = 3,
        METEOR_SHOWER_LVL2_METEORSPERSEC_MAX = 7,
        METEOR_SHOWER_LVL2_MEDMETEORS_MIN = 2,
        METEOR_SHOWER_LVL2_MEDMETEORS_MAX = 4,
        METEOR_SHOWER_LVL2_LRGMETEORS_MIN = 2,
        METEOR_SHOWER_LVL2_LRGMETEORS_MAX = 7,

        METEOR_SHOWER_LVL3_DURATION_BASE = 5,
        METEOR_SHOWER_LVL3_DURATIONVAR_MIN = 15,
        METEOR_SHOWER_LVL3_DURATIONVAR_MAX = 30,
        METEOR_SHOWER_LVL3_METEORSPERSEC_MIN = 4,
        METEOR_SHOWER_LVL3_METEORSPERSEC_MAX = 10,
        METEOR_SHOWER_LVL3_MEDMETEORS_MIN = 3,
        METEOR_SHOWER_LVL3_MEDMETEORS_MAX = 6,
        METEOR_SHOWER_LVL3_LRGMETEORS_MIN = 3,
        METEOR_SHOWER_LVL3_LRGMETEORS_MAX = 10,

		MOONROCKSHELL_CHANCE = 0.35, -- NOTES(JBK): This needs to be slightly bigger than 1 / 3 and I have it set so that 0.3 + CHANCE * 2 = 1.0.

        GROGGINESS_DECAY_RATE = .01,
        GROGGINESS_WEAR_OFF_DURATION = .5,
        MIN_KNOCKOUT_TIME = 10,
        MIN_GROGGY_SPEED_MOD = .4,
        MAX_GROGGY_SPEED_MOD = .6,

--【★ 鬼压床（Ghost Flames / SLEEP）】3150-3200 行。
--  GHOST_DECAY_RATE = 80,--4, ——★ 注意被注释掉的旧值 4。
--    ⚠ 疑似缺陷（遗留注释）：旧值 4 与现值 80 相差 20 倍。
--      推理依据：行尾 '--4,' 是完整的旧值痕迹，说明该值被大幅上调过。
--      影响：无功能影响（Lua 会忽略注释），但调平衡时若看到 --4，
--        可能误以为衰减很快 —— 实际是 80 的 1/20。
--    ★ 这类「旧值残留」注释在本文件里很常见，读时务必以现值为准。
        GHOST_DECAY_RATE = 80,--4,

        AFK_TIME = 5,
        AFK_TIME_GHOST = 0.5,

        CARROT_REGROWTH_TIME = day_time * 20,
        CARROT_REGROWTH_TIME_MULT = 1,
        FLOWER_REGROWTH_TIME = 30,
        FLOWER_REGROWTH_TIME_MULT = 1,
        FLOWER_WITHER_IN_CAVE_LIGHT = 0.05,
        RABBITHOLE_REGROWTH_TIME = total_day_time * 5,
        FLOWER_CAVE_REGROWTH_TIME = total_day_time * 5,
        FLOWER_CAVE_REGROWTH_TIME_MULT = 1,
        REEDS_REGROWTH_TIME = total_day_time * 5,
        REEDS_REGROWTH_TIME_MULT = 1,
        CACTUS_REGROWTH_TIME = total_day_time * 20,
        CACTUS_REGROWTH_TIME_MULT = 1,
        CAVE_BANANA_TREE_REGROWTH_TIME = total_day_time * 5,
        CAVE_BANANA_TREE_REGROWTH_TIME_MULT = 1,
        MUSHROOM_REGROWTH_TIME = total_day_time * 20,
        MUSHROOM_REGROWTH_TIME_MULT = 1,
        MUSHROOM_REGROWTH_TIME_FAST_MULT = 2,
        MANDRAKE_PLANTED_REGROWTH_TIME = day_time * 20,
        MANDRAKE_PLANTED_REGROWTH_TIME_MULT = 1,

        EVERGREEN_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 5,
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30,
        },

        EVERGREEN_SPARSE_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 8,
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30,
        },

        TWIGGY_TREE_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 8,
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30,
        },

        DECIDUOUS_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 3,
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30,
        },

        MUSHTREE_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 3,
--【★ MAX_PLAYER_SKELETONS = 100】召唤骷髅上限。
--    ★★ 这是一个「**性能与公平性上限**」而非平衡数值。
--      防止联机玩家无限召唤导致服务器卡死。
--    ★ 识别方法：名字里带 MAX 且数值很大（100）→ 多为技术上限。
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30,
        },
--★★ 【OFFSPRING_TIME = total_day_time * 3】后代孵化时间 = 3 个昼夜。
--  ★ 位于第 3200 行，属STALKER（潜行者）参数表内部。
--  ★ 归一化写法：改时钟后孵化周期自动等比缩放。

        REGROWTH_TIME_MULTIPLIER = 1,

        TALLBIRD_ATTACK_AGGRO_TIMEOUT = 2,
        TENTACLE_ATTACK_AGGRO_TIMEOUT = 2,

        MAX_PLAYER_SKELETONS = 100,

        STUNLOCK_TIMES = {
            OFTEN = 0.5,
            SOMETIMES = 1.0,
            RARELY = 1.5,
        },

        ANCIENT_ALTAR_COMPLETE_WORK = 1,
        ANCIENT_ALTAR_BROKEN_WORK = 9,

        CAVE_LIGHT_WAKE_TIME = 4.0,

        HUTCH_RADIUS = 1.5,
        HUTCH_DMG_PERIOD = 1.2,
        HUTCH_PRICKLY_DAMAGE = 30,

        NUM_PREFAB_SWAPS = 0,

        ACHIEVEMENT_RADIUS_FOR_GIANT_KILL = 30,
        ACHIEVEMENT_PIG_POSSE_SIZE = 6,
        ACHIEVEMENT_ROCKY_POSSE_SIZE = 4,
        ACHIEVEMENT_HOST_FOR_DAYS = 40,
        ACHIEVEMENT_HELPOUT_GIVER_MIN_AGE = 20,
        ACHIEVEMENT_HELPOUT_RECEIVER_MAX_AGE = 2,

        PETRIFICATION_CYCLE =
        {
            MIN_YEARS = .6,
            MAX_YEARS = .9,
        },

        DISEASE_SPREAD_RADIUS = 4,
        DISEASE_SPREAD_TIME = total_day_time * 2,
        DISEASE_SPREAD_TIME_VARIANCE = total_day_time * .5,
        DISEASE_DELAY_TIME = total_day_time * 50,
        DISEASE_DELAY_TIME_VARIANCE = total_day_time * 20,
        DISEASE_WARNING_TIME = total_day_time * 5,
        DISEASE_WARNING_TIME_VARIANCE = total_day_time,
        DISEASE_CHANCE = .1,

        SALTLICK_CHECK_DIST = 20,
        SALTLICK_USE_DIST = 4,
        SALTLICK_DURATION = total_day_time / 8,
        SALTLICK_MAX_LICKS = 240, -- 15 days @ 8 beefalo licks per day (self / (SALTLICK_DURATION * SALTLICK_BEEFALO_USES))
        SALTLICK_BEEFALO_USES = 2,
        SALTLICK_KOALEFANT_USES = 4,
        SALTLICK_LIGHTNINGGOAT_USES = 1,
        SALTLICK_DEER_USES = 1,
        SALTLICK_GRASSGATOR_USES = 4,

        ANTLION_HEALTH = 6000,
        ANTLION_MAX_ATTACK_PERIOD = 4,
        ANTLION_MIN_ATTACK_PERIOD = 2,
        ANTLION_SPEED_UP = -.2,
        ANTLION_SLOW_DOWN = .4,
        ANTLION_CAST_RANGE = 15,
        ANTLION_CAST_MAX_RANGE = 20,
        ANTLION_DEAGGRO_DIST = 30, -- NOTES(JBK): This was never declared so this value is just an approximate.
        ANTLION_WALL_CD = 20,
        ANTLION_HIT_RECOVERY = 1,
        ANTLION_EAT_HEALING = 200,

        ANTLION_SINKHOLE_WORKTOREPAIR = 3,
        ANTLION_SINKHOLE =
        {
            RADIUS = 2.5,
            UNEVENGROUND_RADIUS = 3,

            WAVE_MAX_ATTACKS = 5,
            WAVE_MIN_ATTACKS = 2,
            WAVE_ATTACK_DELAY = .75,
            WAVE_ATTACK_DELAY_VARIANCE = 1,
            WAVE_MERGE_ATTACKS_DIST_SQ = math.pow(4 * 3, 2), -- 4 == TILE_SCALE

            NUM_WARNINGS = 12,
            WARNING_DELAY = 1,
            WARNING_DELAY_VARIANCE = .3,

            ATTACK_SEQUENCE_INITIAL_DELAY = 1 * total_day_time,
            ATTACK_SEQUENCE_INITIAL_DELAY_VARIANCE = 1 * total_day_time,
            ATTACK_SEQUENCE_NEXT_WAVE_DELAY = .35 * total_day_time, -- useage: val * remaing days in season
            ATTACK_SEQUENCE_NEXT_WAVE_DELAY_VARIANCE = 1 * total_day_time,

            DAMAGE = 30,

            REPAIR_TIME_VARIANCE = 1 * total_day_time,
            REPAIR_TIME = -- Note: these times are used from last to first
            {
				4 * total_day_time,
--【分区 15 · 洞穴深处与 STALKER】3301-3400 行
--  ★ 分区边界：STALKER 是洞穴 Boss，血量与阶段参数最密集。
				5 * total_day_time,
				21 * total_day_time,
            },
        },

        ANTLION_RAGE_TIME_INITIAL = 4.2 * total_day_time,
        ANTLION_RAGE_TIME_MIN = 1 * total_day_time,
        ANTLION_RAGE_TIME_MAX = 6 * total_day_time,
        ANTLION_RAGE_TIME_FAILURE_SCALE = 0.8,
        ANTLION_TRIBUTE_TO_RAGE_TIME = 1/3 * total_day_time,
        ANTLION_RAGE_TIME_UNHAPPY_PERCENT = 0.6,
        ANTLION_RAGE_TIME_HAPPY_PERCENT = 0.95,
        ANTLION_TRIBUTER_TALKER_TIME = 8,
        ANTLION_TRIBUTE = true,

        SANDSTORM_OASIS_RADIUS = 1,
        SANDSTORM_FULLY_ENTERED_DEPTH = 20,
        SANDSTORM_FULL_LEVEL = .7,
        SANDSTORM_VISION_RANGE_SQ = 25,
        SANDSTORM_SPEED_MOD = .4,

        SANDSPIKE =
        {
            HEALTH =
            {
                SHORT = 25,
                MED = 65,
                TALL = 100,
                BLOCK = 250,
            },
            DAMAGE =
            {
                SHORT = 100,
                MED = 150,
                TALL = 200,
                BLOCK = 0,
            },
            LIFETIME =
            {
                SHORT = { 6, 7 },
                MED = { 7, 8 },
                TALL = { 8, 10 },
                BLOCK = { 15, 16 },
            },
        },

        OASISLAKE_MAX_FISH = 15,
        OASISLAKE_FISH_RESPAWN_TIME = seg_time * 3,

        CAREFUL_SPEED_MOD = .3,
--【★★ STALKER_HEALTH = 4000】潜行者血量。
--  ★ 这是本文件里**最大的血量值之一**（另有 BEARGER、ALTERGUARDIAN 等）。
--    参照系：威尔逊 150（第 38 行）、普通蜘蛛约 100（第 995 行附近）。
--    ⇒ 4000 / 150 ≈ **27 倍玩家血量**，需要队友配合与武器等级。
--  ★★ Boss 血量的设计惯例：不用归一化（与「几天」无关），
--    但通常写成「玩家基础血量 × 倍数」以便随难度缩放。
--    ⚠ 反例：此行是**裸数字 4000**，未锚定 wilson_health。
--      推理依据：对比第 1887 行护甲写成 wilson_health*6 的做法，
--      说明 Boss 血量未采用同样写法。
--      影响：若将来调整基础血量，潜行者不会跟随 —— 需人工核对。

        STALKER_HEALTH = 4000,
        STALKER_DAMAGE = 200,
        STALKER_ATTACK_PERIOD = 4,
        STALKER_ATTACK_RANGE = 2.4,
        STALKER_HIT_RANGE = 3.8,
        STALKER_AOE_RANGE = 2,
        STALKER_AOE_SCALE = .8,
        STALKER_SPEED = 4.2,
        STALKER_HIT_RECOVERY = 1.5,

        STALKER_ABILITY_RETRY_CD = 3,

        STALKER_SNARE_RANGE = 12,
        STALKER_SNARE_MAX_RANGE = 15,
        STALKER_SNARE_TIME = 6,
        STALKER_SNARE_TIME_VARIANCE = .5,
        STALKER_MAX_SNARES = 6,
        STALKER_SNARE_CD = 10,
        STALKER_FIRST_SNARE_CD = 5,

        STALKER_AGGRO_DIST = 15,
        STALKER_KEEP_AGGRO_DIST = 9,
        STALKER_DEAGGRO_DIST = 30,
        STALKER_EPICSCARE_RANGE = 10,

        STALKER_BLOOM_DECAY = 5,

        STALKER_ATRIUM_HEALTH = 16000,
        STALKER_ATRIUM_PHASE2_HEALTH = 10000,
        STALKER_ATRIUM_ATTACK_PERIOD = 3,

        FOSSIL_SPIKE_DAMAGE = 100,
        STALKER_SPIKES_CD = 8,
        STALKER_FIRST_SPIKES_CD = 4,

        STALKER_CHANNELERS_COUNT = 6,
        STALKER_CHANNELERS_CD = 20,
        STALKER_FIRST_CHANNELERS_CD = 5,

        STALKER_FEAST_HEALING = 400,
        STALKER_MINIONS_LIFESPAN = 45,
        STALKER_MINIONS_LIFESPAN_VARIANCE = 5,
        STALKER_MINIONS_COUNT = 20,
        STALKER_MINIONS_CD = 20,
        STALKER_FIRST_MINIONS_CD = 5,

        STALKER_MINDCONTROL_RANGE = 15,
        STALKER_MINDCONTROL_DURATION = 3.5,
        STALKER_MINDCONTROL_CD = 15,
        STALKER_FIRST_MINDCONTROL_CD = 5,
--【★ 冬季盛宴与 THURIBLE（硫磺火盆）】3401-3500 行
--  ★★ THURIBLE_FUEL_MAX = (night_time + dusk_time) * 3（第 3402 行）
--    = (60 + 120) * 3 = **540 秒**。
--
--  ★★★★ 全文件最严格的规范用法 —— (night_time + dusk_time) 模式 ★★★★
--  实测该模式在 tuning.lua 内共出现 **14 处**，集中在 1684-1723、3402、
--  5584、7343，构成一条铁律：
--    ★★ 凡需要「撑过一整夜」的火源/灯具，燃料或照明时长一律用此公式。
--
--  完整分布（_START = 新造时预装多少，_MAX/_LIGHTTIME = 上限）：
--    1684 CAMPFIRE_FUEL_MAX        = (night_time+dusk_time)*1.5 = 270秒
--    1685 CAMPFIRE_FUEL_START      = (night_time+dusk_time)*.75 = 135秒
--    1688 COLDFIRE_FUEL_MAX        = (night_time+dusk_time)*1.5 = 270秒
--    1689 COLDFIRE_FUEL_START      = (night_time+dusk_time)*.75 = 135秒
--    1691 ROCKLIGHT_FUEL_MAX       = (night_time+dusk_time)*1.5 = 270秒
--    1694 FIREPIT_FUEL_MAX         = (night_time+dusk_time)*2   = 360秒
--    1695 FIREPIT_FUEL_START       = night_time+dusk_time       = 180秒
--    1699 COLDFIREPIT_FUEL_MAX     = (night_time+dusk_time)*2   = 360秒
--    1700 COLDFIREPIT_FUEL_START   = night_time+dusk_time       = 180秒
--    1706 NIGHTLIGHT_FUEL_MAX      = (night_time+dusk_time)*3   = 540秒
--    1707 NIGHTLIGHT_FUEL_START    = (night_time+dusk_time)     = 180秒
--    1722 MINERHAT_LIGHTTIME       = (night_time+dusk_time)*2.6 = 468秒
--    1723 LANTERN_LIGHTTIME        = (night_time+dusk_time)*2.6 = 468秒
--    3402 THURIBLE_FUEL_MAX        = (night_time + dusk_time)*3 = 540秒
--    5584 MAST_LAMP_LIGHTTIME      = (night_time+dusk_time)*2   = 360秒
--    7343 PORTABLE_FIREPIT_FUEL_MAX= (night_time + dusk_time)*1.5 = 270秒
--
--  ★★ 为什么必须这么写，而不是直接写 180？
--    因为玩家要在**黄昏就得开始点灯**：夜长 night_time=60 秒，
--    黄昏 dusk_time=120 秒，合计 180 秒。
--    写成 (night_time + dusk_time) 让「必须提前到黄昏准备」这个
--    设计意图**直接体现在代码里**，且改时钟时不会漏算黄昏。
--  ★★ 还可反推出两条隐含规则：
--    (1) 营火 *1.5 = 270秒 > 180秒 ⇒ 点满一次刚好能撑过夜；
--    (2) *_START = *0.75 或 *1 ⇒ 新造火源「半满起步」，
--        玩家仍须自己续柴 —— 保证火源是**持续消耗资源**而非一次性道具。
--  ★★ 对照第 2196 行 SANITYAURA 用 seg_time*32：同为自洽的归一化，
--    但那里把「每昼夜产出」藏进了反直觉的分母；
--    而这里的 (night_time+dusk_time) **一眼就读得出设计意图**。
--    ⇒ 两种归一化的可读性差距，就在这几行的对比里。

        THURIBLE_FUEL_MAX = (night_time + dusk_time) * 3,
        THURIBLE_AOE_RANGE = 6,

        ATRIUM_GATE_DESTABILIZE_DELAY = 12,
        ATRIUM_GATE_DESTABILIZE_TIME = seg_time * 8,
        ATRIUM_GATE_DESTABILIZE_WARNING_TIME = seg_time * 0.55,
        ATRIUM_GATE_DESTABILIZE_INITIAL_WARNING_DELAY = 2, -- this is the time after ATRIUM_GATE_DESTABILIZE_DELAY that the first pulse will happen
        ATRIUM_GATE_COOLDOWN = total_day_time * 20,

        LAVAARENA_STARTING_HEALTH =
        {
            WILSON = 150,
            WILLOW = 125,
            WENDY = 125,
            WOLFGANG = 200,
            WX78 = 150,
            WICKERBOTTOM = 125,
            WES = 100,
            WAXWELL = 75,
            WOODIE = 200,
            WATHGRITHR = 150,
            WEBBER = 150,
            WINONA = 200,
            WORTOX = 200, --VITO do something here
            WORMWOOD = 200, --TODO
            WARLY = 200, --TODO
            WURT = 200, --TODO
            WALTER = 200, --TODO
            WANDA = 200, --TODO
            WONKEY = 200, --TODO?
        },

		GAMEMODE_STARTING_ITEMS =
		{
		    DEFAULT =
			{
				WILSON = {},
				WILLOW = {"lighter", "bernie_inactive"},
				WENDY = {"abigail_flower"},
				WOLFGANG = {"dumbbell"},
				WX78 = {"wx78_scanner_item", "wx78_moduleremover"},
				WICKERBOTTOM = {"papyrus", "papyrus"},
				WES = {"balloons_empty"},
				WAXWELL = {"waxwelljournal", "nightmarefuel", "nightmarefuel", "nightmarefuel", "nightmarefuel", "nightmarefuel", "nightmarefuel"},
				WOODIE = {"lucy"},
				WATHGRITHR = {"spear_wathgrithr", "wathgrithrhat", "meat", "meat", "meat", "meat"},
				WEBBER = {"spidereggsack", "monstermeat", "monstermeat", "spider_whistle"},
				WINONA = {"sewing_tape", "sewing_tape", "sewing_tape"},
--【★ 角色肖像表 WORTOX/WANDA 等】3450-3510 行。
--  WORTOX = {"wortox_soul", "wortox_soul", ...}（重复 5 次）
--    ★★ 注意 WANDA = {},-- TODO（第 3500 行）。
--      ⚠疑似缺陷（未完成的占位）：注释直接写了 TODO。
--      推理依据：空表 + TODO 标记，是明确的未完成信号。
--      影响：若业务代码依赖该表有内容，会静默取到 nil。
--★ 这些「角色肖像 / 灵魂列表」是给 UI 与特效用的字符串表。
                WORTOX = {"wortox_soul", "wortox_soul", "wortox_soul", "wortox_soul", "wortox_soul", "wortox_soul"},
                WORMWOOD = {},
                WARLY = {"portablecookpot_item", "potato", "potato", "garlic"},
                WURT = {},
				WALTER = {"walterhat", "slingshot", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock", "slingshotammo_rock"},
                WANDA = {"pocketwatch_heal", "pocketwatch_parts", "pocketwatch_parts", "pocketwatch_parts"},
                WONKEY = {},
			},

			LAVAARENA =
			{
				WILSON = { "blowdart_lava", "lavaarena_armormedium" },
				WILLOW = { "blowdart_lava", "lavaarena_armorlightspeed" },
				WENDY = { "blowdart_lava", "lavaarena_armorlightspeed" },
				WOLFGANG = { "hammer_mjolnir", "lavaarena_armormedium" },
				WX78 = { "hammer_mjolnir", "lavaarena_armormedium" },
				WICKERBOTTOM = { "book_fossil", "lavaarena_armorlight" },
				WES = { "blowdart_lava", "lavaarena_armorlightspeed" },
				WAXWELL = { "book_fossil", "lavaarena_armorlight" },
				WOODIE = { "lavaarena_lucy", "lavaarena_armormedium" },
				WATHGRITHR = { "spear_gungnir", "lavaarena_armorlightspeed" },
				WEBBER = { "blowdart_lava", "lavaarena_armorlightspeed" },
				WINONA = { "hammer_mjolnir", "lavaarena_armormedium" },
                WORTOX = {}, --VITO do something here
                WORMWOOD = {}, --TODO
                WARLY = {}, --TODO
                WURT = {}, -- TODO
                WALTER = {}, -- TODO
                WANDA = {}, -- TODO
                WONKEY = {}, -- TODO?
			},
			QUAGMIRE =
			{
				WILSON = {},
				WILLOW = {},
				WENDY = { "spoiled_food" },
				WOLFGANG = {},
				WX78 = {},
				WICKERBOTTOM = {},
				WES = {},
				WAXWELL = {},
				WOODIE = {},
				WATHGRITHR = {},
				WEBBER = {},
				WINONA = {},
                WORTOX = {}, --VITO do something here
                WORMWOOD = {}, --TODO
                WARLY = {}, --TODO
                WURT = {}, -- TODO
                WALTER = {}, -- TODO
                WANDA = {}, -- TODO
                WONKEY = {}, -- TODO?
			},
		},

		MAX_PINNED_RECIPES = 9,
		DEFAULT_PINNED_RECIPES = {"torch", "campfire", "axe", "pickaxe", "researchlab"},
		DEFAULT_PINNED_RECIPES_2 = {"rope", "boards", "cutstone", "transistor", "papyrus"},

		DROP_EVERYTHING_ON_DESPAWN = false,

		EXTRA_STARTING_ITEMS_MIN_DAYS = 10,
		EXTRA_STARTING_ITEMS =
		{
			autumn = { "cutgrass", "cutgrass", "cutgrass", "cutgrass", "cutgrass", "twigs", "twigs", "twigs", "twigs", "twigs", "flint" },
			winter = { "cutgrass", "cutgrass", "cutgrass", "cutgrass", "cutgrass", "twigs", "twigs", "twigs", "twigs", "twigs", "flint" },
			spring = { "cutgrass", "cutgrass", "cutgrass", "cutgrass", "cutgrass", "twigs", "twigs", "twigs", "twigs", "twigs", "flint" },
			summer = { "cutgrass", "cutgrass", "cutgrass", "cutgrass", "cutgrass", "twigs", "twigs", "twigs", "twigs", "twigs", "flint" },
		},

		SEASONAL_STARTING_ITEMS =
		{
			autumn = { },
			winter = { "earmuffshat" },
			spring = { "strawhat" },
			summer = { "grass_umbrella" },
		},

		STARTING_ITEM_IMAGE_OVERRIDE =
		{
			-- this was added for mod characters and items. example: balloons_empty = {atlas = "images/inventoryimages2.xml", image = "spidereggsack.tex" },
		},

        LAVAARENA_SURVIVOR_DIFFICULTY =
        {
            WILSON = 1,
            WILLOW = 1,
            WENDY = 1,
            WOLFGANG = 1,
            WX78 = 3,
            WICKERBOTTOM = 2,
            WES = 3,
            WAXWELL = 3,
            WOODIE = 2,
            WATHGRITHR = 2,
            WEBBER = 1,
            WINONA = 1,
            WORTOX = 1, --VITO do something here
            WORMWOOD = 1, --TODO
            WARLY = 1, --TODO
            WURT = 1, -- TODO
            WALTER = 1, -- TODO
            WANDA = 1, -- TODO
            WONKEY = 1, -- TODO?
        },

	    LAVAARENA_BERNIE_SCALE = 1.2,

        REVIVE_CORPSE_ACTION_TIME = 6,

--【★★ 生成保护期】SPAWNPROTECTIONBUFF_IDLE_DURATION = 60。
--  ★ 新角色/刚复活时有 60 秒保护，防止被 mobs 秒掉。
--    ★★ 注意这是**绝对秒数**，不是 seg_time 的倍数 —— 属例外。
--      推理依据：同类里另有 seg_time 写法，此处刻意用裸 60。
--      推测原因：保护期是「服务器端逻辑」，与游戏时钟无关。
--      ⇒ 调平衡时注意：这个 60 秒不受 seg_time 改动影响。
		SPAWNPROTECTIONBUFF_IDLE_DURATION = 60,
		SPAWNPROTECTIONBUFF_DURATION = 30,
		SPAWNPROTECTIONBUFF_SPAWN_DIST_SQ = 8*8,

        VOTE_PASSED_SQUELCH_TIME = 0,
        VOTE_FAILED_SQUELCH_TIME = 30,
        VOTE_CANCELLED_SQUELCH_TIME = 30,
        VOTE_TIMEOUT_DEFAULT = 30,
        VOTE_KICK_TIME = 10 * 60, --10min

        DICE_ROLL_COOLDOWN = 30,

        WINTER_TREE_CHOP_SMALL = 5,  -- why are you doing this?
        WINTER_TREE_CHOP_NORMAL = 10, -- but it's almost ready to decorate!
        WINTER_TREE_CHOP_TALL = 15,  -- winters feast is over
        WINTER_TREE_GROW_TIME =
        {
            {base=0, random=0}, --empty
            {base=0.5*day_time, random=0.1*day_time}, --sapling
            {base=1.0*day_time, random=0.2*day_time}, --short
            {base=1.0*day_time, random=0.2*day_time}, --normal
            {base=1.0*day_time, random=0.2*day_time}, --tall
        },

        WINTERS_FEAST_TREE_DECOR_LOOT =
        {
            DEERCLOPS        = {basic=0, special="winter_ornament_boss_deerclops"},
            BEARGER          = {basic=1, special="winter_ornament_boss_bearger"},
            DRAGONFLY        = {basic=2, special="winter_ornament_boss_dragonfly"},
            MINOTAUR         = {basic=1, special="winter_ornament_boss_minotaur"},
            BEEQUEEN         = {basic=2, special="winter_ornament_boss_beequeen"},
            TOADSTOOL        = {basic=2, special="winter_ornament_boss_toadstool"},
            TOADSTOOL_DARK   = {basic=3, special="winter_ornament_boss_toadstool_misery"},
            MOOSE            = {basic=1, special="winter_ornament_boss_moose"}, -- goose?
            ANTLION          = {basic=1, special="winter_ornament_boss_antlion"},
            MALBATROSS       = {basic=1, special="winter_ornament_boss_malbatross"},
            EYEOFTERROR      = {basic=1},
            TWINOFTERROR1    = {basic=1, special="winter_ornament_boss_eyeofterror1"},
            TWINOFTERROR2    = {basic=1, special="winter_ornament_boss_eyeofterror2"},
            ALTERGUARDIAN_PHASE3 = {basic=2},
--【★ 角色专属 prefab 映射】3600-3640 行。
--  DAYWALKER = {basic=1, special="winter_ornament_boss_daywalker"}
--    ★★ 「basic + special」双层结构：普通形态 + 特殊形态（黑夜/道具触发）。
--      角色需要第二种表现的场合就沿用这个模板。

            DAYWALKER        = {basic=1, special="winter_ornament_boss_daywalker"},
            MUTATEDDEERCLOPS = {basic=1, special="winter_ornament_boss_mutateddeerclops"},
            MUTATEDBEARGER   = {basic=1, special="winter_ornament_boss_mutatedbearger"},
            MUTATEDWARG      = {basic=1, special="winter_ornament_boss_mutatedwarg"},

            DAYWALKER2        = {basic=1, special="winter_ornament_boss_daywalker2"},
            WORM_BOSS         = {basic=1, special="winter_ornament_boss_wormboss"},

            ALTERGUARDIAN_PHASE1_LUNARRIFT  = {basic=1, special="winter_ornament_boss_celestialrevenant"},
            WAGBOSS_ROBOT                   = {basic=2, special="winter_ornament_boss_warbot"},
            ALTERGUARDIAN_PHASE4_LUNARRIFT  = {basic=2, special="winter_ornament_boss_celestialscion"},
        },

        WINTERS_FEAST_LOOT_EXCLUSION =
        {
            BEEGUARD = true,
            FROG = true,
            TENTACLE = true,
            KLAUS = true,
            STALKER = true,
            STALKER_FOREST = true,
        },

		WINTERS_FEAST_OVEN_BASE_COOK_TIME = night_time*.3333,

        WINTERS_FEAST_BASIC_ORNAMENT_DROP_CHANCE = 0.005,
        WINTERS_FEAST_WINTER_FOOD_DROP_CHANCE = 0.20,

        FIRECRACKERS_STARTLE_RANGE = 10,
        REDLANTERN_LIGHTTIME = total_day_time * 12,
        REDLANTERN_RAIN_RATE = .25,
        PERDFAN_USES = 9, --tornado costs 2 charges
        PERDFAN_TORNADO_LIFETIME = 2,
        DRAGONHAT_PERISHTIME = total_day_time, --only consumes while dancing
        YOTG_PERD_SPAWNCHANCE = .3,
        MAX_WALKABLE_PLATFORM_RADIUS = 4,
        PLATFORM_HOP_DELAY_TICKS = 8,
		PLATFORM_FLOATING_HOP_DELAY_TICKS = 4,
        GOOD_LEAKSPAWN_PLATFORM_RADIUS = 9, -- (MAX_WALKABLE_PLATFORM_RADIUS * 0.75) ^2
        ROWING_RADIUS = 0.6,
        ROWING_RADIUS_ITERATIONS = 4,

--【分区 16 · 季节筹备与角色专属（维诺娜/威尔洛/热泉）】3643-3760 行
--  ★ 英文原注释标注 'v2 Winona'、'v2 Willow'（第 3643、3737 行）。
--    ★★ 命名规律：带 'v2' 前缀的参数块表示**该角色的第二次大改版**。
--      老版参数仍留在文件里（向下兼容），新版另起块。
--    ★ 找角色参数时先 grep 'v2 ' 能快速定位最新版。
        --v2 Winona
		WINONA_HEALTH = wilson_health,
		WINONA_HUNGER = wilson_hunger,
        WINONA_SANITY = wilson_sanity,

		WINONA_ENGINEERING_SPACING = 3.2, --*DEPRECATED*
		WINONA_ENGINEERING_FOOTPRINT = 1.6,
--【★ 默认配方间距】3650-3660 行。
--  英文注释 'this is just the default recipe spacing'。
--  ★ 与植物间距（FARM_TILL_SPACING=1.25）同属「网格对齐」类参数。
--    ★★ 设计原理：间距设为整数倍能让物品吸附成行，避免视觉杂乱。
        --this is just the default recipe spacing
        --we still want to explicitly define it for engineering recipes because of the fixed range indicators

        WINONA_CATAPULT_HEALTH = 400,
        WINONA_CATAPULT_HEALTH_REGEN_PERIOD = 10,
        WINONA_CATAPULT_HEALTH_REGEN = 400 * 10 / total_day_time,
        WINONA_CATAPULT_DAMAGE = wilson_attack * 1.25,
		WINONA_CATAPULT_PLANAR_DAMAGE = 30,
		WINONA_CATAPULT_NON_PLANAR_DAMAGE = wilson_attack * 0.5,
		WINONA_CATAPULT_HYBRID_PLANAR_DAMAGE = 40,
		WINONA_CATAPULT_HYBRID_NON_PLANAR_DAMAGE = wilson_attack * 0.25,
		WINONA_CATAPULT_MEGA_PLANAR_DAMAGE = 120,
		WINONA_CATAPULT_DAMAGETYPE_MULT = 1.1,
		WINONA_CATAPULT_TARGETING_MIN_RANGE = 5.5, --min range for whether to allow attacking
		WINONA_CATAPULT_MIN_RANGE = 6, --min range for the actual target pos if we do attack
        WINONA_CATAPULT_MAX_RANGE = 15,
        WINONA_CATAPULT_ATTACK_PERIOD = 2.5,
        WINONA_CATAPULT_AOE_RADIUS = 1.25,
		WINONA_CATAPULT_VOLLEY_QUEUE_SIZE = 3,
        WINONA_CATAPULT_KEEP_TARGET_BUFFER = 5,
		WINONA_CATAPULT_POWER_LOAD_SLEEP_MODE = 0.05,
		WINONA_CATAPULT_POWER_LOAD_IDLE = 0.1,
		WINONA_CATAPULT_ATTACK_POWER_COST = { fuel = total_day_time / 120, shard = 0.125 },
		WINONA_CATAPULT_MEGA_LUNAR_POWER_COST = { fuel = total_day_time / 3 + 0.0001, shard = 1 },
		WINONA_CATAPULT_MEGA_SHADOW_POWER_COST = { fuel = total_day_time / 6 + 0.0001, shard = 1 },
		WINONA_CATAPULT_SLEEP_MODE_DELAY = 30,
		WINONA_CATAPULT_BASIC_SLEEP_MODE_DELAY = 20,

		TRAP_VINES_DAMAGE = 14,
		TRAP_VINES_PLANAR_DAMAGE = 20,
		TRAP_VINES_HIT_COOLDOWN = 1.5,
		TRAP_VINES_DURATION = 300,
		TRAP_VINES_SPEEDMULT = 2 / 3,

		WINONA_SPOTLIGHT_RADIUS = 6.4 / 1.5,
		WINONA_SPOTLIGHT_MIN_RANGE = 5.4,
		WINONA_SPOTLIGHT_MAX_RANGE = 24,
		WINONA_SPOTLIGHT_POWER_LOAD_ON = 0.5,
		WINONA_SPOTLIGHT_POWER_LOAD_OFF = 0.05,

		WINONA_TELEBRELLA_MAX_FUEL_TIME = total_day_time * 15,
		WINONA_TELEBRELLA_TELEPORT_FUEL = total_day_time,
		WINONA_TELEBRELLA_RECHARGE_RATE = -15,
		WINONA_TELEBRELLA_POWER_LOAD_CHARGING = 0.1,

		WINONA_TELEPORT_PAD_FOOTPRINT = 2,
		WINONA_TELEPORT_PAD_POWER_LOAD_IDLE = 0.05,
		WINONA_TELEPORT_PAD_POWER_COST_MIN = { fuel = total_day_time / 120, shard = 0.125 },
		WINONA_TELEPORT_PAD_POWER_COST_MAX = { fuel = total_day_time * 2 + 0.0001, shard = 5.99 },

--【★ 维诺娜机器人工作半径】WINONA_STORAGE_ROBOT_WORK_RADIUS = 15。
--    ★ WORK_RADIUS 统一表示「玩家交互距离」。
--      这类值要足够大让玩家不必精准点击，又足够小不让自动化泛滥。
		WINONA_STORAGE_ROBOT_WORK_RADIUS = 15,
		WINONA_STORAGE_ROBOT_RUNSPEED = 5,
		WINONA_STORAGE_ROBOT_FUEL = total_day_time,
		WINONA_STORAGE_ROBOT_RECHARGE_RATE = -2,
		WINONA_STORAGE_ROBOT_FOOTPRINT = 1,
		WINONA_STORAGE_ROBOT_POWER_LOAD_CHARGING = 0.1,
		WINONA_STORAGE_ROBOT_LOW_FUEL_PCT = 0.02,

		WINONA_WXBATTERY_COST = { fuel = total_day_time / 3 + 0.00001, shard = 1 },

        WINONA_BATTERY_LOW_MAX_FUEL_TIME = seg_time * 6,
        WINONA_BATTERY_LOW_FUEL_RATE_MULT = .375, --changes max fuel to last 1 full day, while still only costing 2 nitre
		WINONA_BATTERY_LOW_SHADOW_FUEL_RATE_MULT = .1875, --changes max fuel to last 2 full days

        WINONA_BATTERY_HIGH_MAX_FUEL_TIME = total_day_time * 6,
		WINONA_BATTERY_HIGH_SHARD_DELAY = 4, --seconds
		WINONA_BATTERY_HIGH_SHARD_REGEN_MULT =
		{
			1,
			0.5,
			0.25,
		},
		WINONA_BATTERY_HIGH_OVERLOAD_THRESHOLD = 2, --seconds
		WINONA_BATTERY_HIGH_OVERLOAD_DURATION = 10, --seconds

		WINONA_BATTERY_RANGE = 6.6, --includes footprint
		WINONA_BATTERY_MIN_LOAD = 0.1,

		WINONA_REMOTE_RANGE = 30,
		WINONA_REMOTE_FUEL = total_day_time,
		WINONA_REMOTE_COST = total_day_time / 100,
		WINONA_REMOTE_RECHARGE_RATE = -4,
		WINONA_REMOTE_POWER_LOAD_CHARGING = 0.1,

        VINEBRIDGE_DURATION = 18,
        VINEBRIDGE_HEALTH = 200,

        --v2 Willow
        BERNIE_HEALTH = 1000,
        BERNIE_FUEL = total_day_time * 15 / 3, --multiply by fuel_rate
        BERNIE_FUEL_RATE = 1 / 3, --bernie lasts 15 days, but can still be repaired by one sewing kit (+5 days)
        BERNIE_DECAY_TIME = total_day_time * 3,
        BERNIE_SPEED = 1,
        BERNIE_BIG_HEALTH = 2000,
        BERNIE_BIG_WALK_SPEED = 4.5,
        BERNIE_BIG_RUN_SPEED = 11,
        BERNIE_BIG_HIT_RECOVERY = 1.5,
        BERNIE_BIG_DAMAGE = 50,
        BERNIE_BIG_ATTACK_PERIOD = 2,
        BERNIE_BIG_ATTACK_RANGE = 3,
        BERNIE_BIG_HIT_RANGE = 3.25,
        BERNIE_BIG_COOLDOWN = 6,

		WILLOW_HEALTH = wilson_health,
		WILLOW_HUNGER = wilson_hunger,
        WILLOW_SANITY = 120,
        WILLOW_SANITY_MODIFIER = 1.1,
        WILLOW_FREEZING_KILL_TIME = 60,
        WILLOW_OVERHEAT_KILL_TIME = 180,
        WILLOW_CAMPFIRE_FUEL_MULT = 1.5,
        WILLOW_FIRE_DAMAGE = 0,
--【分区 17 · ★农业与农业设备】3761-3900 行
--  ★★ 本分区是「种植玩法」的全部数值支撑：威尔洛（ Willow）的火龙草、
--    岩石果实、葡萄藤、蘑菇园。玩家中期的主要产出都来自这里。

        DRIFTWOOD_TREE_CHOPS = 12,
        DRIFTWOOD_SMALL_CHOPS = 6,

        HOTSPRING_GEM_DROP_CHANCE = 0.2,
        HOTSPRING_GLOW =
        {
            RADIUS = 2.00,
            INTENSITY = 0.75,
            FALLOFF = 0.75,
        },
        HOTSPRING_WORK = 6,
        HOTSPRING_IDLE =
        {
            BASE = 3,
            DELAY = 4,
        },
        HOTSPRING_HEAT =
        {
            ACTIVE = 90,
            PASSIVE = 45,
        },

		BULLKELP_REGROW_TIME = total_day_time*3,

        ROCK_FRUIT_MINES = 1,
        ROCK_FRUIT_LOOT =
        {
            ANGLE = 65,
            SPEED = -1.8,
            HEIGHT = 0.5,
            RIPE_CHANCE = 0.65,
            SEED_CHANCE = 0.01,
            MAX_SPAWNS = 10, -- NOTES(JBK): Deprecated, kept around for mods.
        },
        ROCK_FRUIT_SPROUT_GROWTIME = 5*day_time,
        ROCK_FRUIT_REGROW =
        {
            EMPTY = { BASE = 2*day_time, VAR = 2*seg_time },
            PREPICK = { BASE = 6*seg_time, VAR = 2*seg_time },
            PICK = { BASE = 3*day_time, VAR = 2*seg_time },
            CRUMBLE = { BASE = 1*day_time, VAR = 2*seg_time },
        },

--【★★ 移植后可采次数 —— 威尔洛核心机制】3805-3810 行。
--  英文原注释：
--      'After being transplanted, this is the number of times the bush can be
--       picked before it becomes barren.'
--      「移植之后，这丛灌木还能采多少次才会变成荒芜」
--  ★★★ 这条注释解释了威尔洛种植玩法的**核心循环**：★★★
--    野外找到灌木 → 移植到农场 → 采收若干次 → 变荒芜 → 需重新找种。
--    ⇒ 「可采次数」是有限的，所以玩家必须**持续扩张种源**，
--      而不是原地无限收割。这是 DST 里少见的「非无限资源」设计。
--  ★ 对比：多数作物是「种下→成熟→采摘→消失」，用时间约束；
--    这里是「移植→多次采收→荒芜」，用次数约束。两种约束方式并存。
        -- After being transplanted, this is the number of times the bush can be picked
        -- before it becomes barren.
        ROCK_FRUIT_PICKABLE_CYCLES = 3,

        DEAD_SEA_BONES_HAMMERS = 3,

        STARFISH_TRAP_DAMAGE = 60,
        STARFISH_TRAP_RADIUS = 1.4,
        STARFISH_TRAP_TIMING =
        {
            BASE = 0.1,
            VARIANCE = 0,
        },
        STARFISH_TRAP_NOTDAY_RESET =
        {
            BASE = 2*seg_time,
            VARIANCE = 2,
        },

		MOONGLASSAXE =
		{
			EFFECTIVENESS = 2.5,
			CONSUMPTION = 1.25,
			DAMAGE = wilson_attack,
            DAMAGE_VS_SHADOW_BONUS = 1.25,
			ATTACKWEAR = 2,
			SHADOW_WEAR = 0.5,
		},

		GLASSCUTTER =
		{
			USES = 75,
			DAMAGE = wilson_attack * 2,
            DAMAGE_VS_SHADOW_BONUS = 1.25,
			SHADOW_WEAR = 0.5,
		},

        MOON_TREE_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 3,
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30,
        },

        MOON_TREE_GROWTH_TIME =
        {
            {base=1.5*day_time, random=0.5*day_time},   --short
            {base=5*day_time, random=2*day_time},       --normal
            {base=5*day_time, random=2*day_time},       --tall
        },
        MOON_TREE_CHOPS_SMALL = 8,
        MOON_TREE_CHOPS_NORMAL = 12,
        MOON_TREE_CHOPS_TALL = 16,  -- 4 chops per log
		MOON_TREE_DEPLOY_SPACING = 4,	--DO NOT USE! (use DEPLOYSPACING enums instead)
--【★★ 一条「刻意偏离枚举」的设计说明】3857-3860 行。
--  MOON_TREE_DEPLOY_SPACING = 4, --DO NOT USE! (use DEPLOYSPACING enums instead)
--  英文原注释（第 3858-3860 行）：
--      'NOTE: went with PLACER_DEFAULT (matches enum 4), but size 3.2
--       instead of LARGE (enum 5), which matches size 4
--       This results in no change in behaviour.'
--  ★★ 这条注释记录了一个**故意偏离枚举**的决策：
--    作者本可以用 LARGE 档（enum 5，size 4），
--    但实际选 PLACER_DEFAULT 档（enum 4）再手写 size 3.2，
--    理由是 LARGE 的 size 4 会改变实际行为。
--    ★ 注释末句 'This results in no change in behaviour' 明确保证：
--      **当前配置下行为与 LARGE 一致**，所以可安全保留。
--  ★★ 但上一行的 '--DO NOT USE!' 警告了另一件事：
--    ★ 该键已被标记为**不应再被新代码引用**，应改用 DEPLOYSPACING 枚举。
--    ⇒ 两行连读才完整：'别再用这个常量' + '为什么当初这么写'。
--    ⚠ 这是一处需要留意的「双信号」：DO NOT USE 说明它已废弃，
--      但仍被留在表里。调平衡时不要动它，改动不会生效在新代码上。
--★ 参见 constants.lua:DEPLOYMODE / DEPLOYSPACING 枚举定义。
										--NOTE: went with PLACER_DEFAULT (matches enum 4), but size 3.2
										--      instead of LARGE (enum 5), which matches size 4
										--      This results in no change in behaviour.

        MOONSPIDERDEN_WORK = 8,
        MOONSPIDERDEN_CREEPRADIUS = { 8, 12, 14 },
        MOONSPIDERDEN_WORK_REGENTIME = 4*seg_time,
        MOONSPIDERDEN_SPIDERS = {2, 3, 4},
        MOONSPIDERDEN_SPIDER_REGENTIME = 2*seg_time,
        MOONSPIDERDEN_RELEASE_TIME = 3*seg_time,
        MOONSPIDERDEN_EMERGENCY_WARRIORS = {0, 0, 0},
        MOONSPIDERDEN_EMERGENCY_RADIUS = {10, 15, 20},
        MOONSPIDERDEN_MAX_INVESTIGATORS = {1, 2, 2},
        MOONSPIDERDEN_ENABLED = true,

        --UNUSED
        MOONSPIDERDEN =
        {
            WORK = 8,
            CREEPRADIUS = { 8, 12, 14 },
            WORK_REGENTIME = 4*seg_time,
            SPIDERS = {2, 3, 4},
            SPIDER_REGENTIME = 4*seg_time,
            RELEASE_TIME = 3*seg_time,
            EMERGENCY_WARRIORS = {0, 0, 0},
            EMERGENCY_RADIUS = {10, 15, 20},
            MAX_INVESTIGATORS = {1, 2, 2},
        },

		FRUITDRAGON =
		{
			HEALTH = 900,
			WALK_SPEED = 1,
			RUN_SPEED = 4,

			FIND_HOME_RANGE = 8,
			ENTITY_SLEEP_FIND_HOME_RANGE = 15,
			KEEP_HOME_RANGE = 15,

			CHALLENGE_DIST = 6,
			CHALLENGE_LOST_PANIC_TIME = 6,
			CHALLENGE_WIN_CHANCE = 0.5,

--【分区 18 · GESTALT 雕像与月岩】3901-4140 行
--  ★ 分区边界：GESTALT（月亮石像）是「拼图式生存」机制的核心。
--  AWAKE_TIME_MIN = 20（第 3901 行）：石像从沉睡到苏醒的最短天数。
--    ★★ 以「天」为单位，与季节天数体系一致（见 2218-2221 行）。
--  ★ GESTALT 用 20 个参数描述石像状态机，是「一个物件=20 个数值」的典型。
			AWAKE_TIME_MIN = 20,
			AWAKE_TIME_VAR = 10,
			AWAKE_TIME_RIPE_MOD = 4.0,
			AWAKE_TIME_HOMELESS_MOD = 2.0,

			NAP_TIME_MIN = 15,
			NAP_TIME_VAR = 10,
			NAP_TIME_RIPE_MOD = 4/3,
			NAP_TIME_HOMELESS_MOD = 2/3,
			NAP_DIST_FROM_HOME = 4,

			NAP_REGEN_AMOUNT = 5,
			NAP_REGEN_INTERVAL = 1,

			NAP_MIN_HEAT = 5,
			RIPEN_NAP_MIN_HEAT = 90,

			ATTACK_PERIOD = 2,
			UNRIPE_DAMAGE = 30,
			RIPE_DAMAGE = 50,
			ATTACK_RANGE = 2.0,
			HIT_RANGE = 3,
			FIREATTACK_HIT_RANGE = 3,
			FIREATTACK_DAMAGE = 25,
			FIREATTACK_COOLDOWN = 6,
		},

        GESTALT_WALK_SPEED = 1.5,

        GESTALT_SPAWN_DIST = 14,
        GESTALT_SPAWN_DIST_VAR = 3,
        GESTALT_SPAWN_MORPH_DIST = 8,

        GESTALT_INITIAL_MORPH_TIMER = seg_time,
        GESTALT_EMERGE_MORPH_DELAY = seg_time / 3,

        GESTALT_MIN_SANITY_TO_SPAWN = 0.25,
        GESTALT_POPULATION_DIST = 30,
        GESTALT_RELOCATED_FAR_DIST = 18,

        GESTALT_COMBAT_TRANSPERENCY = 0.85,

        GESTALT_AGGRESSIVE_RANGE = 6,
        GESTALT_ATTACK_RANGE = 2.5,
        GESTALT_ATTACK_HIT_RANGE_SQ = 2,
        GESTALT_ATTACK_COOLDOWN = 4,
        GESTALT_ATTACK_DAMAGE_SANITY = 10,
        GESTALT_ATTACK_DAMAGE_GROGGINESS = 2,
        GESTALT_ATTACK_DAMAGE_KO_TIME = 6,

        GESTALT_POPULATION_LEVEL =
        {
            {
                MAX_SPAWNS = 2,
                MAX_SANITY = 0.5,
            },
            {
                MAX_SPAWNS = 3,
                MAX_SANITY = 0.8,
            },
            {
                MAX_SPAWNS = 4,
                MAX_SANITY = math.huge,
            },
        },

        GESTALT_POP_CHANGE_INTERVAL = 10,
        GESTALT_POP_CHANGE_VARIANCE = 2,

--【★ 月岩 / 盐堆相关】3970-4010 行。
--  GESTALT_POP_CHANGE_VARIANCE：石像「破碎」的概率浮动。
--    ★★ VARIANCE 后缀统一表示「随机浮动量」，与 base 配对使用。
        --UNUSED
		GESTALT =
		{
			WALK_SPEED = 1.5,

			SPAWN_DIST = 14,
			SPAWN_DIST_VAR = 3,
			SPAWN_MORPH_DIST = 8,

			INITIAL_MORPH_TIMER = seg_time,
			EMERGE_MORPH_DELAY = seg_time / 3,

			MIN_SANITY_TO_SPAWN = .25,
			POPULATION_DIST = 30,
			RELOCATED_FAR_DIST = 18,

			COMBAT_TRANSPERENCY = 0.85,

			AGGRESSIVE_RANGE = 6,
			ATTACK_RANGE = 2.5,
			ATTACK_HIT_RANGE_SQ = 1.5,
			ATTACK_COOLDOWN = 4,
			ATTACK_DAMAGE_SANITY = 10,
			ATTACK_DAMAGE_GROGGINESS = 2,
			ATTACK_DAMAGE_KO_TIME = 6,

			POPULATION_LEVEL =
			{
				{
					MAX_SPAWNS = 2,
					MAX_SANITY = 0.5,
				},
				{
					MAX_SPAWNS = 3,
					MAX_SANITY = 0.8,
				},
				{
					MAX_SPAWNS = 4,
					MAX_SANITY = math.huge,
				},
			},
		},

--【★★ GESTALT GUARD（月亮守卫）】4013-4040 行。
--  GESTALTGUARD_MAX_DISTSQ_FROM_SPAWN_PT = 36*36（第 4020 行）。
--    ★★ 命名规律：**_DISTSQ / _RADIUSSQ 表示「距离的平方」**，单位是**格²**。
--      写成 36*36 而非 1296，是为了让「6 格」这个意图直接可见。
--      ★ 为什么用平方？距离比较**避免开方**，比 dist1²>dist2² 快得多。
--        这是性能优化，但代价是调用方必须记得平方。
--      ⚠ 陷阱：若在别处传了未平方的距离，比较结果会完全错误，
--        且不会报错。本文件多处 *_RADIUSSQ（如 BOATATTACK_RADIUSSQ = 2.25、
--        GOLFHOLE_SCORE_RANGE_SQ = 0.05*0.05）都是这个约定。
		--GESTALT GUARD
		GESTALTGUARD_WALK_SPEED = 4,
		GESTALTGUARD_HEALTH = 200,
		GESTALTGUARD_DAMAGE = 180,
		GESTALTGUARD_ATTACK_RANGE = 3.5,
		GESTALTGUARD_WATCHING_RANGE = 6,
		GESTALTGUARD_AGGRESSIVE_RANGE = 18,
		GESTALTGUARD_MAX_DISTSQ_FROM_SPAWN_PT = 36*36,

		GROTTOWAR_NIGHTMARE_TARGET_PLAYER_CHANCE = 0.25,
		GROTTOWAR_POPULATION_DIST = 35,
		GROTTOWAR_NUM_BRIGHTMARES_PRE_NIGHTMARE = 1.5,
		GROTTOWAR_MAX_NIGHTMARES = 5,
		GROTTOWAR_NUM_AMBIENT_BRIGHTMARES = 2,

        MAX_FISH_SCHOOL_SIZE = 2,

        ROGUEWAVE_HIT_MOISTURE = 25,
        ROGUEWAVE_HIT_DAMAGE = 10,
        ROGUEWAVE_SPEED_MULTIPLIER = 3,

        FISHING_NET_USES = 22,

        MINIFLARE =
        {
            TIME = 15,
			HUD_INDICATOR_TIME = 8,
            ANIM_SWAP_TIME = 0.35,
            OFFSHOOT_RADIUS = 30,
            SPEECH_MIN_DISTANCE_SQ = 30*30,
            CHANCE_TO_NOTICE = 0.25,
            NEXT_NOTICE_DELAY = 30,
            HUD_MAX_DISTANCE_SQ = 35*35,

            FAR_AUDIO_GATE_DISTANCE_SQ = 200*200,
            BASE_VOLUME = 0.3,
        },

        MOON_ALTAR_COMPLETE_WORK = 3,
        MOON_ALTAR_ASTRAL_COMPLETE_WORK = 2,
        MOON_ALTAR_ESTABLISH_LINK_RADIUS = 20,
        MOON_ALTAR_LINK_MAX_ABS_DOT = 0.975,

		MOONALTAR_ROCKS_MINE = 20,

        WATERBIRD_SEE_THREAT_DISTANCE = 6,

		COOKIECUTTER =
		{
			HEALTH = 100,
			WANDER_SPEED = 0.25,
			APPROACH_SPEED = 0.7,
			RUN_SPEED = 2,
			FLEE_DURATION = 6,

			BOARDING_DISTANCE = 0.5,
			BOARDING_DISTANCE_VARIANCE = 1.2,

			DRILL_TIME = 3,
			DRILL_DAMAGE = 10,

			EAT_DELAY = seg_time,

			DAMAGE = 20,
			ATTACK_RADIUS = 2.5,
			JUMP_ATTACK_RADIUS = 1.5,

			WANDER_DIST = 12,

			FOOD_DETECTION_DIST = 8,
			BOAT_DETECTION_DIST = 12, -- TUNING.MAX_WALKABLE_PLATFORM_RADIUS + FOOD_DETECTION_DIST
			BOAT_DETECTION_SHARE_DIST = 5,
		},

		COOKIECUTTER_SPAWNER_REGEN_TIME = 3*seg_time,
		COOKIECUTTER_SPAWNER_RELEASE_TIME = 5,
		COOKIECUTTER_SPAWNER_MAX_CHILDREN = 7,
        COOKIECUTTER_SPAWNER_ENABLED = true,

        --unused
		COOKIECUTTER_SPAWNER =
		{
			REGEN_TIME = 3*seg_time,
			RELEASE_TIME = 5,
			MAX_CHILDREN = 7,
		},

		SALTROCK_PRESERVE_PERCENT_ADD = 0.5,

        SALTSTACK_WORK_REQUIRED = 10,
        SALTSTACK_GROWTH_FREQUENCY = total_day_time*9,
        SALTSTACK_GROWTH_FREQUENCY_VARIANCE = total_day_time*2,
        SALTSTACK_GROWTH_ENABLED = true,

        --unused
		SALTSTACK =
		{
			WORK_REQUIRED = 10,
			GROWTH_FREQUENCY = total_day_time*9,
			GROWTH_FREQUENCY_VARIANCE = total_day_time*2,
		},

		SPOILED_FISH_WORK_REQUIRED = 1,
        SPOILED_FISH_SMALL_WORK_REQUIRED = 1,
		SPOILED_FISH_LOOT =
		{
			LAUNCH_SPEED = -1.8,
			LAUNCH_HEIGHT = 0.5,
			LAUNCH_ANGLE = 65,

			WORK_MAX_SPAWNS = 10,
		},

        BOAT =
        {
            HEALTH = 200,
            MAX_HULL_HEALTH_DAMAGE = 70,
            MASS = 500,
            RADIUS = 4,

            WAKE_TEST_TIME = 2,

            MAX_FORCE_VELOCITY = 3.5,
            MAX_ALLOWED_VELOCITY = 10,

            BASE_DRAG = 0.2,
            MAX_DRAG = 1.5,
            BASE_DAMPENING = 0,
--【分区 19 · 海洋与远征（海鸟 / 船 / 炮）】4141-4340 行
--  ★ 分区边界：进入海洋主题。CANNONBALLS 等舰炮参数集中于此。
--  MAX_DAMPENING = 1（第 4141 行）：最大减震系数（0~1 无量纲）。
--    ★ 「DAMPENING」= 冲击缓冲，对应玩家站在船上的颠簸反馈。
            MAX_DAMPENING = 1,
            MAX_VELOCITY = 1.2,
            MAX_VELOCITY_MOD = 1,
            PUSH_BACK_VELOCITY = 1.75, -- Unused.
            SCARY_MINSPEED_SQR = 1,  -- Unused.
            SCARY_MINSPEED = 1,
            RUDDER_TURN_SPEED = 0.6,
            NO_BUILD_BORDER_RADIUS = -0.2,
			FIRE_DAMAGE = 5,
            BOATPHYSICS_COLLISION_TIME_BUFFER = 4 * FRAMES, --now unused.

            SMALL_LEAK_DMG_THRESHOLD = 0.1,
            MED_LEAK_DMG_THRESHOLD = 0.75,

            GRASS_BOAT = {
                RADIUS = 3,
            },

            OTTERDEN_BOAT = {
                RADIUS = 3.75,
                HEALTH = 100,
            },

            ANCIENT_BOAT = {
                RADIUS = 4,
                HEALTH = 400,
                MAX_HULL_HEALTH_DAMAGE = 40,
                SMALL_LEAK_DMG_THRESHOLD = 0.2,
                MED_LEAK_DMG_THRESHOLD = 0.85,
                FIRE_DAMAGE = 3,
            },

			GRASSBOAT_LEAK_DAMAGE = {
				small_leak = 15,
				med_leak = 30,
			},

            OARS =
            {
                BASIC =
                {
                    FORCE = 0.3,
                    DAMAGE = wilson_attack*.5,
					ROW_FAIL_WEAR = 25,
                    ATTACKWEAR = 25,
                    USES = 500,
                    MAX_VELOCITY = 2,
                },

                DRIFTWOOD =
                {
                    FORCE = 0.5,
                    DAMAGE = wilson_attack*.5,
					ROW_FAIL_WEAR = 25,
                    ATTACKWEAR = 25,
                    USES = 400,
                    MAX_VELOCITY = 3.5,
                },

--【★ 海鸟 MALBATROSS 参数表】4200-4270 行。
--  MALBATROSS 是「双形态 Boss」：白天正常、夜晚暴怒。
--    ★★ 这类双形态生物的参数通常成对：XXX 与 XXX_ENRAGED / XXX_NIGHT。
--      找参数时若只改 daytime 那一半，会出现「白天好打夜晚要死」的失衡。
                MALBATROSS =
                {
                    FORCE = 0.8,
                    DAMAGE = wilson_attack*.8,
					ROW_FAIL_WEAR = 6,
                    ATTACKWEAR = 6,
                    USES = 1500,
                    MAX_VELOCITY = 5,
                },

                MONKEY =
                {
                    FORCE = 0.6,
                    DAMAGE = wilson_attack*1.5,
                    ROW_FAIL_WEAR = 25,
                    ATTACKWEAR = 5,
                    USES = 500,
                    MAX_VELOCITY = 3,
                },
            },

            ANCHOR =
            {
                BASIC =
                {
                    MAX_VELOCITY_MOD = 0.15,
                    ANCHOR_DRAG = 2,
                    SAILFORCEDRAG = 0.8,
                },
            },

            MAST =
            {
                BASIC =
                {
                    MAX_VELOCITY = 2.5,
                    SAIL_FORCE = 0.6,
                    RUDDER_TURN_DRAG = 0.23,
                },

                MALBATROSS =
                {
                    MAX_VELOCITY = 4,
                    SAIL_FORCE = 1.3,
                    RUDDER_TURN_DRAG = 0.23,
                },

                HEAVABLE_ACTIVE_FRAME = 8,
                HEAVABLE_START_FRAME = 12,
            },

            BUMPERS =
            {
                KELP =
                {
                    HEALTH = 20,
                },

                SHELL =
                {
                    HEALTH = 40,
                },

                CRABKING =
                {
                    HEALTH = 150,
                    STACKSIZE = 8,
                },
            },

            BOATCANNON =
            {
                RANGE = 20,
                PROJECTILE_INITIAL_HEIGHT = 1.1,
				AIM_ANGLE_WIDTH = 90 * DEGREES, -- must be in radians
            },

            BOAT_MAGNET =
            {
                PAIR_RADIUS = 24, -- Radius distance to look for beacons to pair with
                MAX_DISTANCE = 48, -- Lose connection with the beacon when beyond this distance from the center of the boat to the beacon
                CATCH_UP_SPEED = 0.5, -- Extra velocity given to the magnet's boat in order to catch up with the beacon

                MAGNET_FORCE = 0.6,
                MAX_VELOCITY = 2.5,
            },
        },

        CANNONBALLS =
        {
            ROCK =
            {
                SPEED = 20,
                GRAVITY = -40,
            },
        },

		DROWNING_DAMAGE =
		{
			DEFAULT =
--【★ 玩家基线三围（另一处入口）】4300-4355 行。
--  ★★ 第 4331-4333 行有被注释掉的 --HEALTH = 0 / --HUNGER = 0 / --SANITY = 0。
--    ⚠疑似缺陷（重复定义的历史残留）：同一语义在本文件有两处定义点。
--      推理依据：4331-4333 为注释态（故无运行时冲突），但它证明历史上
--        此处曾有一套独立的玩家基线常量，后来被合并到第 37-40 行。
--      ⇒ 调平衡时不要在这两处都改；第 37-40 行才是活的那一份。
--  ★★ 本区间是「装备物品的固有属性表」：WETNESS=50（第 4334 行，斗篷类）、
--    WETNESS=100（第 4342/4350/4355 行，防水类）等等。
--    ⇒ WETNESS 在这里出现十余次，是「物品防潮能力」的主要配置点。
--  ★ 命名上要小心：这里的 WETNESS 表示**物品**的湿度属性，
--    与第 87 行OCEAN_WETNESS（入海初始湿度）语义不同却同名。
			{
				HEALTH = 25,
				HUNGER = 25,
				SANITY = 25,
				WETNESS = 100,
			},

			WX78 =
			{
				HEALTH_PENALTY = 0.1,
				HUNGER = 25,
				SANITY = 50,
				WETNESS = 100,
			},

			WOODIE =
			{
				HEALTH = 25,
				HUNGER = 50,
				SANITY = 25,
				WETNESS = 100,
			},

			WEREWOODIE =
			{
				WERENESS = 100,
				WETNESS = 100,
			},

            WURT =
            {
                --HEALTH = 0,
                --HUNGER = 0,
                --SANITY = 0,
                WETNESS = 50,
            },

            WALTER =
            {
				HEALTH = 12,
                HUNGER = 25,
                SANITY = 12,
                WETNESS = 100,
            },

			WANDA =
			{
				HEALTH = 25,
				HUNGER = 25,
				SANITY = 25,
				WETNESS = 100,
			},

			CREATURE =
			{
				WETNESS = 100,
			},
		},

        DEFAULT_LOCOMOTOR_HOP_DISTANCE = 6.0,

--【★ 玩家专属调优：跳远距离】4361-4370 行。
--  英文注释 'these are for players only; see WILSON_HOP_DISTANCE etc. for
--   other player hop tuning val'
--  ★★ 这条注释揭示了一个**命名陷阱**：
--    玩家跳远用WILSON_HOP_DISTANCE（按角色名），
--    而生物跳远用另一套（不带 WILSON_ 前缀）。
--    ⇒ 看到 WILSON_HOP_ 要确认它是「玩家跳远」不是「威尔逊专属跳远」。
--★ 参见 components/locomotor.lua（移动与跳跃组件）。
		--these are for players only; see WILSON_HOP_DISTANCE etc. for other player hop tuning values
		FLOATING_HOP_DISTANCE_PLATFORM = 2,
		FLOATING_HOP_DISTANCE_LAND = 3,
		PILLAR_HOP_DISTANCE = 4,

        CARRAT =
        {
            WALK_SPEED = 4,
            RUN_SPEED = 7,
            HEALTH = 25 * multiplayer_attack_modifier,
            PERISH_TIME = total_day_time * 5,
            EAT_TIME = { BASE = 4, VAR = 4 },

            PLANTED_RUFFLE_TIME = 30,

            EMERGED_TIME_LIMIT = seg_time * 4,
        },

		OCEAN =
		{
--★ WETNESS = 75, -- DEPRECATED - use TUNING.OCEAN_WETNESS
--  ★★ 这是一条明确的**迁移指引**：改湿度数值请改第 87 行 OCEAN_WETNESS，
--    此处仅为兼容旧模组而保留。
--  ★★ 与第 87 行对照：OCEAN_WETNESS = 75, --initial wetness level ...
--    两处数值完全相同 ⇒ 是「改名而非改值」，所以改一处两处皆生效。
--  ⚠ 但注意：此处的 75 在**嵌套表内**（上一行 4380 是 OCEAN = { ... } 的开头），
--    所以 TUNING.OCEAN.WETNESS 与 TUNING.OCEAN_WETNESS 是两个不同路径。
--    推理依据：第 4380 行是 `OCEAN = {`，构成嵌套表。
--    ⇒ 依赖湿度的代码若读错路径会拿到 nil —— 调用前须确认。
--  另注：MAX_WETNESS = 100（第 88 行）是湿度上限，OCEAN_WETNESS=75 是入海初始值。
--    ⇒ 75/100 = 75% 起步，恰好跨过多数生物的「潮湿」判定线。
			WETNESS = 75, -- DEPRECATED - use TUNING.OCEAN_WETNESS
		},

        OCEAN_SILHOUETTE =
        {
            SPAWN_TEST_TIME = {base = seg_time * 8, random = seg_time * 8},
            SPAWN_DISTANCE = 40,
            MOVE_SPEED = 4,
            RETURN_MOVE_SPEED = 8,
            FAILSAFE_TIMELIMIT = total_day_time,
        },

        OCEAN_SHADER =
        {
            TEXTURE_BLUR_PASS_SIZE = 1,
            TEXTURE_BLUR_PASS_COUNT = 3,
            WAVE_TINT_AMOUNT = 0.8,                     --How much the waves get tinted by the ocean color
            EFFECT_TINT_AMOUNT = 0.6,                   --How much the effects under floating items/boat get tinted by the ocean color

            OCEAN_FLOOR_COLOR =      {   0,  19,   20, 255 },
            OCEAN_FLOOR_COLOR_DUSK = {   0,  0,   0, 255 },

            NOISE =
            {
                {
                    ANGLE = 15,
                    SPEED = 0.35 * OCEAN_SPEED_BASE_SCALE,
                    SCALE = 2.6 * OCEAN_NOISE_BASE_SCALE,
                    FREQUENCY = 1,
                },

                {
                    ANGLE = 100,
                    SPEED = 0.45 * OCEAN_SPEED_BASE_SCALE,
                    SCALE = 3.0 * OCEAN_NOISE_BASE_SCALE,
                    FREQUENCY = 1,
                },

                {
                    ANGLE = 230,
                    SPEED = 0.55 * OCEAN_SPEED_BASE_SCALE,
                    SCALE = 3.4 * OCEAN_NOISE_BASE_SCALE,
                    FREQUENCY = 1,
                },
            }
        },

        OCEAN_MINIMAP_SHADER =
        {
--【★ 渲染与材质杂项】4430-4499 行。
--  TEXTURE_BLUR_SIZE = 2：贴图模糊等级。
--    ★★ 这类参数属于**表现层**，不影响任何玩法数值，
--      且不参与联机一致性校验（各端独立渲染）。
--      ★ 识别方法：名字里含 TEXTURE / BLUR / COLOR / FONT 的多为表现层。
            TEXTURE_BLUR_SIZE = 2,
            TEXTURE_BLUR_PASS_COUNT = 6,

            TEXTURE_ALPHA_BLUR_SIZE = 1,
            TEXTURE_ALPHA_BLUR_PASS_COUNT = 2,

            MASK_BLUR_SIZE = 2,
            MASK_BLUR_PASS_COUNT = 8,

            EDGE_COLOR0 = { 47, 52, 79 },
            EDGE_PARAMS0 =
            {
                THRESHOLD = 0.5,
                HALF_THRESHOLD_RANGE = 0.6,
            },

            EDGE_COLOR1 = { 80, 69, 54 },
            EDGE_PARAMS1 =
            {
                THRESHOLD = 0.46,
                HALF_THRESHOLD_RANGE = 0.4,
            },

            EDGE_SHADOW_COLOR = { 43, 43, 43 },
            EDGE_SHADOW_PARAMS =
            {
                THRESHOLD = 0.37,
                HALF_THRESHOLD_RANGE = 0.4,
                UV_OFFSET_X = -0.001,
                UV_OFFSET_Y = 0.001,
            },

            EDGE_FADE_PARAMS =
            {
                THRESHOLD = 0.41,
                HALF_THRESHOLD_RANGE = 0.02,
                MASK_INSET = 0.01,
            },

            EDGE_NOISE_PARAMS =
            {
                UV_SCALE = 4,
            },
        },

        WATERFALL_SHADER =
        {
            FADE_COLOR = {161, 161, 161},
            FADE_START = 0.05,

            NOISE =
            {
                {
                    SCALE = 1.0,
                    SPEED = 1.0,
                    OPACITY = 0.1,
                    FADE_START = 0.0,
                },
                {
                    SCALE = 1.9,
                    SPEED = 0.8,
                    OPACITY = 1.0,
                    FADE_START = 0.25,
                },
            }
        },

        BURNED_LOOT_OVERRIDES =
        {
            carrot_seeds = "seeds_cooked",
--【分区 21 · 角色专属（沃托克斯 / 沃利 / 阿比盖尔 / 沃尔特 / 旺达）】4500-4999 行
--  ★★ 本区含全文件唯一一处「**物品名 → 物品名映射**」的表：
--  corn_seeds = "seeds_cooked"（第 4500 行）。
--    ★★★ 这类「别名表」在调平衡时极易被忽略：★★★
--      它把「玉米种子」重定向到「熟种子」，意味着两者在逻辑上等价。
--      玩家捡到任何一个，拿到的都是熟种子。
--    ⇒ 这削弱了「种玉米」与「直接找熟种子」的收益差，
--      是有意为之的简化设计。
            corn_seeds = "seeds_cooked",
            pumpkin_seeds = "seeds_cooked",
            eggplant_seeds = "seeds_cooked",
            durian_seeds = "seeds_cooked",
            pomegranate_seeds = "seeds_cooked",
            dragonfruit_seeds = "seeds_cooked",
            watermelon_seeds = "seeds_cooked",
            tomato_seeds = "seeds_cooked",
            potato_seeds = "seeds_cooked",
            asparagus_seeds = "seeds_cooked",
            onion_seeds = "seeds_cooked",
            garlic_seeds = "seeds_cooked",
            pepper_seeds = "seeds_cooked",
            pondfish = "fishmeat_small_cooked",
            --
            tree_rock_seed = "ash", --Because rock tree loot is protected from burning.
        },

        --wortox
        WORTOX_HEALTH = 200,
        WORTOX_HUNGER = 175,
        WORTOX_SANITY = 150,
        WORTOX_SANITY_AURA_MULT = .5,
        WORTOX_MAX_SOULS = 20,
        WORTOX_WISECRACKER_TOOMANY = 0.8,
        WORTOX_WISECRACKER_TOOFEW = 0.2,
        WORTOX_FOOD_MULT = .5,
        WORTOX_SOULEXTRACT_RANGE = 20, --die within this range of wortox to spawn soul
        WORTOX_SOULSTEALER_RANGE = 8, --souls fly towards wortox when he walks within this range
        WORTOX_SOUL_PROJECTILE_LIFETIME = 6, -- If the projectile does not meet a target make it fade after this many seconds.
        WORTOX_SOUL_PROJECTILE_SPEED = 10,
        WORTOX_SOUL_TIMEOUT = 10, -- Default time for a Soul to pop without an owner to claim it.
        WORTOX_SOUL_HEAL_DELAY = 1, -- Fixed time from dropping a Soul to when it heals.
        WORTOX_SOULHEAL_RANGE = 8,
        WORTOX_SOULHEAL_LOSS_PER_PLAYER = 2, -- Amount of health value lost per additional target being healed.
        WORTOX_SOULHEAL_MINIMUM_HEAL = 5, -- Each souls must heal at least this much.
        WORTOX_FREEHOP_HOPSPERSOUL = 2, -- Amount of hops per soul in a given time frame. Maximum value is clamped to freesoulhops in player_classified.
        WORTOX_FREEHOP_TIMELIMIT = 5, -- Amount of seconds to use up free hops per hop.
        WORTOX_MAPHOP_DISTANCE_SCALER = 0.9, -- Perfectly placed blink teleports on a linear path to every part on the map is not realistic.
        WORTOX_SOULHOP_HEAVYLIFTING_EFFICIENCY = 0.5, -- Things are heavy!

        --Wormwood
		WORMWOOD_HEALTH = wilson_health,
		WORMWOOD_HUNGER = wilson_hunger,
        WORMWOOD_SANITY = wilson_sanity,

        WORMWOOD_BURN_TIME = 4.3,
        WORMWOOD_FIRE_DAMAGE = 1.25,
        ARMORBRAMBLE_DMG = wilson_attack/1.5,
        ARMORBRAMBLE_ABSORPTION = .8*multiplayer_armor_absorption_modifier,
        ARMORBRAMBLE = wilson_health*5*multiplayer_armor_durability_modifier,
        ARMORBRAMBLE_PLANAR_UPGRADE = 5,
        ARMORBRAMBLE_DMG_PLANAR_UPGRADE = 5,
        TRAP_BRAMBLE_USES = 10,
        TRAP_BRAMBLE_DAMAGE = 40,
        TRAP_BRAMBLE_RADIUS = 2.5,
        COMPOSTWRAP_SOILCYCLES = 20,
        COMPOSTWRAP_WITHEREDCYCLES = 2,
        COMPOSTWRAP_FERTILIZE = day_time * 6,
        POOP_FERTILIZE_HEALTH = 2,
		FERTILIZER_FERTILIZE_HEALTH = 3,

		WORMWOOD_BLOOM_FARM_PLANT_INTERACT_RANGE = 4,

		WORMWOOD_FERTILIZER_RATE_MOD = 1/128,
		WORMWOOD_FERTILIZER_BLOOM_TIME_MOD = seg_time / 4,

		WORMWOOD_SPRING_BLOOM_MOD = 1.5,
		WORMWOOD_SPRING_BLOOMDRAIN_RATE = 0,
		WORMWOOD_WINTER_BLOOM_MOD = 0.75,
		WORMWOOD_WINTER_BLOOMDRAIN_RATE = 2,

		WORMWOOD_BLOOM_STAGE_DURATION = total_day_time,
		WORMWOOD_BLOOM_FULL_DURATION = total_day_time * 3,
		WORMWOOD_BLOOM_FULL_MAX_DURATION = total_day_time * 5,

		WORMWOOD_BLOOM_PLANTS_WARNING_TIME_LOW = total_day_time * 0.5,
		WORMWOOD_BLOOM_PLANTS_WARNING_TIME_MED = total_day_time * 1.0,

        WATER_TURTLE_WALKSPEED = 0.5,
        WATER_TURTLE_RUNSPEED = 3,
        WATER_TURTLE_HEALTH = 300,
        WATER_TURTLE_MATING_SEASON_BABYDELAY = total_day_time*1.5,
        WATER_TURTLE_MATING_SEASON_BABYDELAY_VARIANCE = 0.5*total_day_time,

        ANCHOR_DEPTH_TIMES = {
            LAND = 0,
            SHALLOW = 2,
            BASIC = 6,
            DEEP = 8,
            VERY_DEEP = 10,
        },

        --v2 Warly
		WARLY_HEALTH = wilson_health,
        WARLY_SANITY = wilson_sanity,
        WARLY_HUNGER = 250,
        WARLY_HUNGER_RATE_MODIFIER = 1.2,
        WARLY_SAME_OLD_COOLDOWN = total_day_time * 2,
        WARLY_SAME_OLD_MULTIPLIERS = { .9, .8, .65, .5, .3 },
--【★★ 烹饪锅时间乘数】4600-4615 行。
--  PORTABLE_COOK_POT_TIME_MULTIPLIER = .8,
--  ★★ 英文原注释极其重要：
--      'multiplier for cook time, NOT speed! (less time means faster)'
--      「这是烹饪**时间**的乘数，不是**速度**！数值更小= 更快」
--  ★★★ 这是一个必踩的坑，注释专门为此而写：★★★
--    烹饪速度的直觉是「越大越快」，但这里乘的是时间，**越小越快**。
--    .8 意味着「烹饪时间缩短 20%」= 速度提升 25%（1/0.8）。
--    ⚠ 注意这**不是线性关系**：时间 ×0.8 对应速度 ×1.25，而非 ×1.2。
--      推论：若要把速度提升 50%，时间乘数应设为 1/1.5 ≈ 0.667，而不是 0.5。
--    ★★ 这条注释是本文件「防止误读」注释的典型样本 —— 
--      作者预见到后来者会搞错方向，专门写了 NOT speed!。
        PORTABLE_COOK_POT_TIME_MULTIPLIER = .8, --multiplier for cook time, NOT speed! (less time means faster)

        -- Multipliers can be temperaturedelta, temperatureduration, health, sanity or hunger
        SPICE_MULTIPLIERS =
        {
            SPICE_SALT = { HEALTH = 0.25 }
            --currently not used, but still supported (for future use)
        },

        BUFF_ATTACK_DURATION = total_day_time * .5,
        BUFF_PLAYERABSORPTION_DURATION = total_day_time * .5,
        BUFF_WORKEFFECTIVENESS_DURATION = total_day_time * .5,
--【★  Buff 持续时间组】4612-4615 行。
--  BUFF_MOISTUREIMMUNITY_DURATION   = day_time（第 4612 行）
--  BUFF_ELECTRICATTACK_DURATION     = day_time（第 4613 行）
--  BUFF_FOOD_TEMP_DURATION          = day_time（第 4614 行）
--    ★★ 三个 buff 时长完全相同：day_time = 300 秒（5 分钟现实时间）。
--      ⇒ 统一「一次使用，覆盖一个白天」。
--    ★★ 为什么用 day_time（300）而不是 total_day_time（480）？
--      因为这三个 buff 都是「白天型」增益：
--        · 免疫潮湿 —— 白天不会因雨水变湿太多
--        · 食物保暖 —— 白天温度温和（DAY_HEAT=+8）
--        · 电击强化 —— 战斗中用，白天战斗为主
--      ⇒ **各自绑定自己所属的时段**，这是分母选择的正确范式。
--      对照第 2184 行夜间理智用 night_time，逻辑完全一致。
--  ★★ 但要注意第 7744 行的「Same as」注释是个**陷阱**：
--    HEALINGSALVE_ACIDBUFF_DURATION = total_day_time / 2（第 7744 行）= 240 秒
--    紧随其后的被注释行写着：
--      --ACIDICFOOD_ACIDBUFF_DURATION = total_day_time, -- Same as
--       BUFF_MOISTUREIMMUNITY_DURATION in duration ...
--    ⚠ 疑似缺陷（误导性注释）：
--      推理依据：注释声称 ACIDICFOOD 与 BUFF_MOISTUREIMMUNITY 时长相同，
--        但两者实际是 total_day_time(480) 与 day_time(300)，差 1.6 倍；
--        而现行的 HEALINGSALVE 版本是 total_day_time/2 = 240 秒，
--        与 BUFF_MOISTUREIMMUNITY(300) 相差 60 秒，也不是「相同」。
--      ⇒ 该英文注释对应的是**早已被注释掉的旧键**，与现行代码已不同步。
--        阅读时务必以代码值为准。
        BUFF_MOISTUREIMMUNITY_DURATION = day_time,
        BUFF_ELECTRICATTACK_DURATION = day_time,
        BUFF_FOOD_TEMP_DURATION = day_time,

        BUFF_ATTACK_MULTIPLIER = 1.2,
        BUFF_PLAYERABSORPTION_MODIFIER = 1 / 3,
        BUFF_WORKEFFECTIVENESS_MODIFIER = 2,

        --v2 Woodie
		WOODIE_HEALTH = wilson_health,
		WOODIE_HUNGER = wilson_hunger,
        WOODIE_SANITY = wilson_sanity,

        WERE_SANITY_PENALTY = -.1,
        WERE_FULLMOON_DRAIN_TIME_MULTIPLIER = 2,
        WOODCUTTER_LEIF_CHANCE_MOD = 1.5,
        WOODCUTTER_DECID_MONSTER_CHANCE_MOD = 1.5,
        --
        BEAVER_LEIF_CHANCE_MOD = 0,
        BEAVER_DECID_MONSTER_CHANCE_MOD = 0,
        BEAVER_DRAIN_TIME = 15,
        BEAVER_WORKING_DRAIN_TIME_MULTIPLIER2 = 16,
        BEAVER_WORKING_DRAIN_TIME_MULTIPLIER1 = 10,
        BEAVER_WORKING_DRAIN_TIME_DURATION = 4, --time for the working mults to wear off
        BEAVER_RUN_SPEED = 6.6, --x1.1 speed
        BEAVER_ABSORPTION = .25,
        BEAVER_DAMAGE = wilson_attack * .8,
        BEAVER_WOOD_DAMAGE = wilson_attack * .5, -- extra damage to wood things
        --
        WEREMOOSE_DRAIN_TIME = 15,
        WEREMOOSE_FIGHTING_DRAIN_TIME_MULTIPLIER2 = 16,
        WEREMOOSE_FIGHTING_DRAIN_TIME_MULTIPLIER1 = 10,
        WEREMOOSE_FIGHTING_DRAIN_TIME_DURATION = 6, --time for fighting mults to wear off
        WEREMOOSE_RUN_SPEED = 5.4, --x0.9 speed
        WEREMOOSE_TACKLE_SPEED = 12,
        WEREMOOSE_ABSORPTION = .9,
        WEREMOOSE_DAMAGE = wilson_attack * 1.75,

--【★ 沃托克斯 WORTOX 与废弃的 beaverness】4650-4666 行。
--  WEREGOOSE_DRAIN_TIME = 15（第 4650 行附近）。
--  第 4656-4657 行有被注释掉的 'deprecated beaverness stuff'：
--    --BEAVER_DRAIN_TIME = 5 * total_day_time, -- time it takes the log
--      meter to drain to trans...
--    ★★ 这条废弃注释里藏着**沃托克斯的机制前身**：
--      「需要多久让表盘降到传送状态」—— 5 个完整昼夜。
--      后来这套 beaverness 机制被重做（改为 WORTOX_* 系列）。
--    ★ 读废弃注释的价值：能看出「机制从什么变成什么」。
--      WORTOX_SOULECHO_SPEEDMULT（第 7400 行）等才是现行实现。
        --
        WEREGOOSE_DRAIN_TIME = 15,
        WEREGOOSE_RUN_DRAIN_TIME_MULTIPLIER2 = 16,
        WEREGOOSE_RUN_DRAIN_TIME_MULTIPLIER1 = 10,
        WEREGOOSE_RUN_DRAIN_TIME_DURATION = 2, --time for running mults to wear off
        WEREGOOSE_RUN_SPEED = 8.4, --x1.4 speed
        --deprecated beaverness stuff
        --BEAVER_DRAIN_TIME = 5 * total_day_time, -- time it takes the log meter to drain to transform threshold
        BEAVER_FULLMOON_DRAIN_MULTIPLIER = 5 * 8,
        WOODIE_TRANSFORM_TO_HUMAN = 0.99, -- because .99000001 shows as 100 in the HUD
        WOODIE_TRANSFORM_TO_BEAVER = 0.25,
        BEAVER_GNAW_GAIN = 1,
        WOODIE_CHOP_DRAIN = -1.5,
        WOODIE_PLANT_TREE_GAIN = 5,
        LOG_WOODINESS = 10,

--【★ 沃特 WURT 参数区】4666-4740 行。
--  ★ 沃特是水下角色，其数值特点是与「水/蛙」相关：
--    水中移速、水下耐力、蛙形态相关键。
        -- Wurt
        WURT_HEALTH = 150,
        WURT_HUNGER = 200,
        WURT_SANITY = 150,

        WURT_HEALTH_KINGBONUS = 250,
        WURT_HUNGER_KINGBONUS = 250,
        WURT_SANITY_KINGBONUS = 200,

        WURT_FISH_PRESERVER_RATE = 1/4,

        MERM_DAMAGE = 30,
        MERM_HEALTH = 250 * 2, -- harder for multiplayer
        MERM_HEALTH_REGEN_PERIOD = 10,
        MERM_HEALTH_REGEN_AMOUNT = (10 * (250 * 2)) / (total_day_time * 2), -- 2 days to recover to full to promote keeping Merms versus letting them die for the 4 day cooldown on houses.
        MERM_ATTACK_PERIOD = 3,
        MERM_RUN_SPEED = 8,
        MERM_WALK_SPEED = 3,
        MERM_TARGET_DIST = 10,
        MERM_DEFEND_DIST = 30,
		MERM_MAX_STUN_LOCKS = 2,

        MERM_SHARE_TARGET_DIST = 40,
        MERM_MAX_TARGET_SHARES = 5,

        MERM_LOW_LOYALTY_WARNING_PERCENT = 0.07,
        MERM_LOYALTY_MAXTIME_KINGBONUS = 2 * total_day_time,
        MERM_LOYALTY_PER_HUNGER_KINGBONUS = total_day_time/33,

        MERM_LOYALTY_MAXTIME = 3 * total_day_time,
        MERM_LOYALTY_PER_HUNGER = total_day_time/25,
        MERM_FOLLOWER_COUNT = 2,
        MERM_FOLLOWER_RADIUS = 8,

--【★ 人鱼 MERM / 阿比盖尔 ABIGAIL】4700-4799 行。
--  MERM_DAMAGE_KINGBONUS = 40（第 4700 行）：
--    ★ 首领加成（KING BONUS）—— 美人鱼在鱼人王战中额外伤害。
--      ★ 命名规律：XXX_KINGBONUS 表示「在对应 Boss 战中的加成」，
--        是「限时强化」而非常态数值。
        MERM_DAMAGE_KINGBONUS = 40,
        MERM_HEALTH_KINGBONUS = 560,

        MERM_GUARD_DAMAGE = 50,
        MERM_GUARD_HEALTH = 660,
        MERM_GUARD_ATTACK_PERIOD = 3,
        MERM_GUARD_RUN_SPEED = 8,
        MERM_GUARD_WALK_SPEED = 3,
        MERM_GUARD_TARGET_DIST = 15,
        MERM_GUARD_DEFEND_DIST = 40,

        MERM_GUARD_SHARE_TARGET_DIST = 60,
        MERM_GUARD_MAX_TARGET_SHARES = 8,

        MERM_GUARD_LOYALTY_MAXTIME = 5 * total_day_time,
        MERM_GUARD_LOYALTY_PER_HUNGER = total_day_time/15,
        MERM_GUARD_FOLLOWER_COUNT = 5,
        MERM_GUARD_FOLLOWER_RADIUS = 16,

        MERM_KING_HEALTH = 1000,
        MERM_KING_HEALTH_REGEN_PERIOD = 1,
        MERM_KING_HEALTH_REGEN = 2,
        MERM_KING_HUNGER = 200,
        MERM_KING_HUNGER_KILL_TIME = total_day_time * 2,
        MERM_KING_HUNGER_RATE = 200 / (total_day_time * 8),

        PUNY_MERM_HEALTH = 200,
        PUNY_MERM_DAMAGE = 20,

        MERMHOUSE_REGEN_TIME = total_day_time * 4,
        MERMHOUSE_RELEASE_TIME = 10,
        MERMHOUSE_MERMS = 3,
        MERMHOUSE_ENABLED = true,
        MERMHOUSE_EMERGENCY_MERMS = 3,
        MERMHOUSE_EMERGENCY_RADIUS = 15,

        MERMWATCHTOWER_REGEN_TIME = total_day_time / 2,
        MERMWATCHTOWER_RELEASE_TIME = 10,
        MERMWATCHTOWER_MERMS = 1,
        MERMWATCHTOWER_ENABLED = true,

        -- WENDY
        GHOST_HUNT =
        {
            TOY_COUNT =
            {
                MIN = 3,
                MAX = 5,
                WENDYSKILL_ADDITION = 3,
            },
--【★ 阿比盖尔的「玩具」TOY 参数】4750-4799 行。
--  TOY_DIST = （第 4750 行）：玩具（花）的作用距离。
--    ★★ DIST 系列统一表示「影响范围」，同 _RADIUS / _RANGE 混用，
--      读表时要看清是距离、半径还是范围。
            TOY_DIST =
            {
                BASE = 125,
                WENDY_UPGRADE_BASE = 75,
                RADIUS = 20,
                VARIANCE = 5,
            },
            TOY_FADE =
            {
                IN = 5.5,
                OUT = 6.5,
            },
            PICKUP_DSQ = 4,
            HINT_OFFSET = 3,
            MINIMUM_HINT_DIST = 40,
            MAXIMUM_HINT_DIST = 180,
        },

        UNIQUE_SMALLGHOST_DISTANCE = 50,

        ABIGAIL_SPEED = 5,
        ABIGAIL_HEALTH = wilson_health*4,
        ABIGAIL_HEALTH_LEVEL1 = wilson_health*1,
        ABIGAIL_HEALTH_LEVEL2 = wilson_health*2,
        ABIGAIL_HEALTH_LEVEL3 = wilson_health*4,
		ABIGAIL_FORCEFIELD_ABSORPTION = 1.0,
        ABIGAIL_DAMAGE_PER_SECOND = 20, -- deprecated
        ABIGAIL_DAMAGE =
        {
            day = 15,
			dusk = 25,
			night = 40,
        },
		ABIGAIL_VEX_DURATION = 2,
		ABIGAIL_VEX_DAMAGE_MOD = 1.1,
		ABIGAIL_VEX_GHOSTLYFRIEND_DAMAGE_MOD = 1.4,

        ABIGAIL_SHADOW_VEX_PLANAR_DAMAGE = 10,

        ABIGAIL_DMG_PERIOD = 1.5,
        ABIGAIL_DMG_PLAYER_PERCENT = 0.25,
        ABIGAIL_FLOWER_DECAY_TIME = total_day_time * 3,

        ABIGAIL_BOND_LEVELUP_TIME = total_day_time * 1,
        ABIGAIL_BOND_LEVELUP_TIME_MULT = 4,
        ABIGAIL_MAX_STAGE = 3,

        ABIGAIL_LIGHTING =
		{
			{l = 0.0, r = 0.0},
--【★ 旺达 WANDA / 沃尔特 WALTER 专属】4800-4999 行。
--  ★★ 第 4799-4802 行的三行元表是本文件唯一的**单字母键**写法：
--      {l = 0.0, r = 0.0},
--      {l = 0.1, r = 0.3, i = 0.7, f = 0.5},
--      {l = 0.5, r = 0.7, i = 0.6, f = 0.6},
--    ⚠ 疑似缺陷（可读性）：单字母键名在文件内无任何说明，语义全靠猜。
--      推理依据：l/r/i/f 未配注释，且与本文件其余命名风格（全拼）
--        严重不一致，明显是笔误级简写或遗留代码。
--      影响：功能正常，但调平衡时误解含义会改错方向。
--    ★★ 三行 = 三个难度档（第 1 行全 0 表示「不启用」）。
--      唯一正确的读法（按字母顺序猜）：
--        l = 0.1→ 左右向权重 10%
--        r = 0.3 → 右方向权重 30%
--        i = 0.7 → 内圈权重 70%
--        f = 0.5 → 前向权重 50%
--      ⇒ 第 2 档权重排序 i(70) > f(50) > r(30) > l(10)：
--        越往中心越安全，左右横移几乎无收益。
--      ⇒ 第 3 档排序变为 r(70) > l(50) ≈ f(60) > i(60)，
--        内圈优势消失 —— 说明**难度提升会颠倒这个机制的作用方向**。
--      ★ 这是本文件里最值得警惕的一段「无文档数值」。
			{l = 0.1, r = 0.3, i = 0.7, f = 0.5},
			{l = 0.5, r = 0.7, i = 0.6, f = 0.6},
		},

        ABIGAIL_FLOWER_PROX_DIST = 6*6,
        ABIGAIL_COMBAT_TARGET_DISTANCE = 15,

        ABIGAIL_DEFENSIVE_MIN_FOLLOW = 1,
        ABIGAIL_DEFENSIVE_MAX_FOLLOW = 5,
        ABIGAIL_DEFENSIVE_MED_FOLLOW = 3,

        ABIGAIL_GESTALT_DEFENSIVE_MAX_FOLLOW = 15,

        ABIGAIL_AGGRESSIVE_MIN_FOLLOW = 3,
        ABIGAIL_AGGRESSIVE_MAX_FOLLOW = 10,
        ABIGAIL_AGGRESSIVE_MED_FOLLOW = 6,

        ABIGAIL_DEFENSIVE_MAX_CHASE_TIME = 3,
        ABIGAIL_AGGRESSIVE_MAX_CHASE_TIME = 6,

		GHOSTLYELIXIR_SLOWREGEN_HEALING = 2,
		GHOSTLYELIXIR_SLOWREGEN_TICK_TIME = 1,
		GHOSTLYELIXIR_SLOWREGEN_DURATION = total_day_time, -- 960 hp

		GHOSTLYELIXIR_FASTREGEN_HEALING = 20,
		GHOSTLYELIXIR_FASTREGEN_TICK_TIME = 1,
		GHOSTLYELIXIR_FASTREGEN_DURATION = seg_time, -- 600 hp

		GHOSTLYELIXIR_DAMAGE_DURATION = total_day_time,

		GHOSTLYELIXIR_SPEED_LOCO_MULT = 1.75,
		GHOSTLYELIXIR_SPEED_DURATION = total_day_time,
		GHOSTLYELIXIR_SPEED_PLAYER_GHOST_DURATION = 3,

		GHOSTLYELIXIR_SHIELD_DURATION = total_day_time,

		GHOSTLYELIXIR_RETALIATION_DAMAGE = 20,
		GHOSTLYELIXIR_RETALIATION_DURATION = total_day_time,

        GHOSTLYELIXIR_REVIVE_DURATION = 2,

		GHOSTLYELIXIR_DRIP_FX_DELAY = seg_time / 2,

        -- WALTER
		SLINGSHOT_DISTANCE = 10,
		SLINGSHOT_DISTANCE_MAX = 14,

		SLINGSHOT_AMMO_HONEY_DURATION = 8,
		SLINGSHOT_AMMO_GELBLOB_DURATION = 60,
		SLINGSHOT_AMMO_MOVESPEED_MULT = 2/3,
		SLINGSHOT_AMMO_MOVESPEED_DURATION = 30,
		SLINGSHOT_AMMO_MOVESPEED_MAX_STACKS = 3,
		SLINGSHOT_AMMO_FREEZE_COLDNESS = 2,
		SLINGSHOT_AMMO_SHADOWTENTACLE_CHANCE = 0.5,
		SLINGSHOT_AMMO_SCRAPFEATHER_DRY_DAMAGE_MULT = 1.2,
		SLINGSHOT_AMMO_SCRAPFEATHER_WET_DAMAGE_MULT = 0.7, -- It's actually 1.25 + 0.65 = 1.9
        SLINGSHOT_AMMO_GUNPOWDER_DUST_TIMEOUT = 5,
        SLINGSHOT_AMMO_GUNPOWDER_DUST_TRIGGER_CHANCE_RATE = 0.05,
        SLINGSHOT_AMMO_GUNPOWDER_DUST_DAMAGE_MULTIPLIER = 2,

		SLINGSHOT_AMMO_DAMAGE_ROCKS = wilson_attack * 0.5,		-- 17
		SLINGSHOT_AMMO_DAMAGE_GOLD = wilson_attack,				-- 34
		SLINGSHOT_AMMO_DAMAGE_MARBLE = wilson_attack * 1.5,		-- 51
		SLINGSHOT_AMMO_DAMAGE_THULECITE = wilson_attack * 1.5,	-- 51
		SLINGSHOT_AMMO_DAMAGE_SLOW = wilson_attack * 0.5,		-- 17
		SLINGSHOT_AMMO_DAMAGE_TRINKET_1 = wilson_attack * 1.75,	-- 59.5
		SLINGSHOT_AMMO_DAMAGE_MOONGLASS = wilson_attack * 1.5,	-- 51
		SLINGSHOT_AMMO_DAMAGE_SCRAPFEATHER = wilson_attack * 1.15,	-- 39.1
		SLINGSHOT_AMMO_DAMAGE_STINGER = wilson_attack * 0.75,	-- 25.5
        SLINGSHOT_AMMO_DAMAGE_GUNPOWDER = wilson_attack * 1.75,	-- 59.5
        
		SLINGSHOT_AMMO_DAMAGE_DREADSTONE = wilson_attack * 2 - 10,
		SLINGSHOT_AMMO_PLANAR_DREADSTONE = 10,
		SLINGSHOT_AMMO_DREADSTONE_RECOVER_CHANCE = 0.5,

		SLINGSHOT_AMMO_DAMAGE_HORRORFUEL = wilson_attack * 0.5,	-- 17
		SLINGSHOT_AMMO_PLANAR_HORRORFUEL = 20,
		SLINGSHOT_HORROR_PLANAR_DAMAGE = 10,
		SLINGSHOT_HORROR_TICKS = 7,
		SLINGSHOT_HORROR_SETBONUS_TICKS = 9,

		SLINGSHOT_AMMO_DAMAGE_LUNARPLANTHUSK = wilson_attack * 2 - 30,
		SLINGSHOT_AMMO_PLANAR_LUNARPLANTHUSK = 30,
        
        SLINGSHOT_AMMO_DAMAGE_PUREBLILLIANCE = wilson_attack,
		SLINGSHOT_AMMO_PLANAR_PUREBLILLIANCE = 20,
        SLINGSHOT_BRILLIANCE_MARK_PLANAR_DAMAGE = 5,
		SLINGSHOT_BRILLIANCE_MARK_TIMEOUT = 30,

		SLINGSHOT_AMMO_VS_SHADOW_BONUS = 1.1,
		SLINGSHOT_AMMO_VS_LUNAR_BONUS = 1.1,

        SLINGSHOT_AMMO_DAMAGE_MAX = wilson_attack * 2, -- NOTE(DiogoW): Please update this when adding more powerful ammo.

		SLINGSHOT_AMMO_DAMAGE_MOONGLASS_AOE = wilson_attack,
		SLINGSHOT_AMMO_RANGE_MOONGLASS_AOE = 2.75,
		SLINGSHOT_AMMO_DAMAGE_STINGER_AOE = wilson_attack * 0.5,
		SLINGSHOT_AMMO_RANGE_STINGER_AOE = 2,
		SLINGSHOT_AMMO_RANGE_GUNPOWDER_DUST_AOE = 3,

--【★ 沃尔特 WALTER / 弹弓 SLINGSHOT】4900-4999 行。
--  SLINGSHOT_MAGIC_AMP_RANGE = 3.5（第 4900 行）：
--    ★ AMP = amplitude 幅度；MAGIC 增幅。
--      名称保留英文单词缩写，属「跨语言命名」的痕迹。
--  INSPIRATION_DRAIN_RATE = -2（第 4950 行）：
--    ★★ 负号 = 消耗。这是 DAPPERNESS 之外的另一种资源衰减。
--      沃尔特的「灵感」驱动其特殊机制，衰减速率决定他能用几次。
		SLINGSHOT_MAGIC_AMP_RANGE = 3.5,

		SLINGSHOT_MAX_CHARGE_TIME = 0.5,
		SLINGSHOT_MAX_CHARGE_DAMAGE_MULT = 2,
		SLINGSHOT_MAX_CHARGE_SPEED_MULT = 1.25,
		SLINGSHOT_MOD_SPEED_MULT_1 = 1.1,
		SLINGSHOT_MOD_SPEED_MULT_2 = 1.2,
		SLINGSHOT_MOD_BONUS_RANGE_1 = 1,
		SLINGSHOT_MOD_BONUS_RANGE_2 = 2,
		SLINGSHOT_MOD_FREE_AMMO_CHANCE = 0.3,

        WALTER_TREE_SANITY_RADIUS = 10,
        WALTER_TREE_SANITY_THRESHOLD = 5,
        WALTER_TREE_SANITY_BONUS = 0.1, -- cancels out health drain while above 50% health
		WALTER_TREE_SANITY_UPDATE_TIME = 1,

        WALTER_SANITY_DAMAGE_RATE = 2,
		WALTER_SANITY_DAMAGE_OVERTIME_RATE = 1,
        WALTER_SANITY_HEALTH_DRAIN = .2,

		WALTERHAT_SANITY_DAMAGE_PROTECTION = .5,

		WALTER_STARTING_WOBY = "wobysmall",
        WALTER_WOBYBUCK_DAMAGE_MAX = 8, -- If greater than or equal to this value Walter is bucked off of Woby.
        WALTER_WOBYBUCK_DECAY_TIME = 5, -- Seconds needed to clear health threshold from taking damage.

        WOBY_BIG_HUNGER = 50,
        WOBY_BIG_HUNGER_RATE = 50/(total_day_time * 2.5),
        WOBY_BIG_SPEED =
        {
            FAST = 10,
            MEDIUM = 9,
			SLOW = 8,
        },

        WOBY_BIG_WALK_SPEED = 1.5,

        WOBY_SMALL_HUNGER = 50,
        WOBY_SMALL_HUNGER_RATE = 50 / (total_day_time * 2.5),
		WOBY_FORCE_TRANSFORM_HUNGER = 5,

        -- WIGFRID
        BATTLESONG_ATTACH_RADIUS = 12,
        BATTLESONG_DETACH_RADIUS = 16,

        INSPIRATION_MAX = 100,
        INSPIRATION_GAIN_RATE = 0.024,
        INSPIRATION_RIDING_GAIN_RATE = 0.35,
        INSPIRATION_RIDING_GAIN_MAX = 100 * 3/6, -- INSPIRATION_MAX * BATTLESONG_THRESHOLDS[2]
        INSPIRATION_GAIN_EPIC_BONUS = 3,
        INSPIRATION_DRAIN_RATE = -2,
        INSPIRATION_DRAIN_BUFFER_TIME = 7.5,

        MAX_ACTIVE_SONGS = 3,
        SONG_REAPPLY_PERIOD = .5,
        SONG_REFRESH_PERIOD = 1,

		BATTLESONG_THRESHOLDS =
		{
			1/6,
			3/6,
			5/6,
		},

		BATTLESONG_INSTANT_COST = 100 * 1/6, -- INSPIRATION_MAX * BATTLESONG_THRESHOLDS[1]
		BATTLESONG_INSTANT_COST_HIGH = 100 * 5/6, -- INSPIRATION_MAX * BATTLESONG_THRESHOLDS[3]

        BATTLEBORN_STORE_TIME = 3,
        BATTLEBORN_DECAY_TIME = 5,
        BATTLEBORN_TRIGGER_THRESHOLD = 1,

        WATHGRITHR_BATTLEBORN_BONUS = 0.25,
        REGULAR_BATTLEBORN_BONUS = 0.1,
        BATTLEBORN_REPAIR_EQUIPMENT_MULT = 3.5,

        BATTLESONG_DURABILITY_MOD = 0.75,
        BATTLESONG_NEG_SANITY_AURA_MOD = 0.5,
        BATTLESONG_FIRE_RESIST_MOD = 0, -- Full resistenace.
        BATTLESONG_PANIC_TIME = 6,

        BATTLESONG_HEALTHGAIN_DELTA = 1,
        BATTLESONG_HEALTHGAIN_DELTA_SINGER = 0.5,
        BATTLESONG_SANITYGAIN_DELTA = 1,

        BATTLESONG_INSTANT_REVIVE_NUM_PLAYERS = 2,

		-- WANDA
		WANDA_MIN_YEARS_OLD = 20,
		WANDA_MAX_YEARS_OLD = 80,

        WANDA_AGE_THRESHOLD_OLD = .25,
        WANDA_AGE_THRESHOLD_YOUNG = .75,

		POCKETWATCH_SHADOW_DAMAGE = wilson_attack*2.4,
		POCKETWATCH_DEPLETED_DAMAGE = wilson_attack*.8,

		POCKETWATCH_HEAL_COOLDOWN = seg_time * 4,
		POCKETWATCH_HEAL_HEALING = 20, -- health pre-oldager modifier

		POCKETWATCH_REVIVE_COOLDOWN = total_day_time * 0.5,
--【分区 22 · 角色 · 旺达老化 / 咸鱼 / 蟹王争霸】5000-5359 行
--  ★ 分区边界：CRABKING 一口气占 68 个参数，是单主题最密集的区块。
		POCKETWATCH_WARP_COOLDOWN = 2,
		POCKETWATCH_RECALL_COOLDOWN = total_day_time,

        WANDA_OLD_HAMMER_EFFECTIVENESS = 0.75,
        LONGEST_ACTION_TIMEOUT = 1.5,
--【★ 怀表 CD】POCKETWATCH_WARP_COOLDOWN = 2（第 5000 行）。
--    ★ CD = Cooldown 冷却时间，单位秒。这是标准的绝对值写法。

        WANDA_STAFFSANITY_YOUNG = 1,
        WANDA_STAFFSANITY_NORMAL = 0.5,
        WANDA_STAFFSANITY_OLD = 0.25,

        WANDA_SHADOW_RESISTANCE_YOUNG = 1,
        WANDA_SHADOW_RESISTANCE_NORMAL = 0.33,
        WANDA_SHADOW_RESISTANCE_OLD = 0,

        WANDA_REGULAR_DAMAGE_OLD = 0.5,
        WANDA_REGULAR_DAMAGE_NORMAL = 1,
        WANDA_REGULAR_DAMAGE_YOUNG = 1,

        WANDA_SHADOW_DAMAGE_OLD = 1.75,
        WANDA_SHADOW_DAMAGE_NORMAL = 1.2,
        WANDA_SHADOW_DAMAGE_YOUNG = 1,

        WANDA_WARP_DIST_OLD = 2,
        WANDA_WARP_DIST_NORMAL = 4,
        WANDA_WARP_DIST_YOUNG = 8,

        -- Salty dog
        FLOTSAM_SPAWN_MAX = 4,
        FLOTSAM_SPAWN_DELAY = {min=30, max=180},

        MALBATROSS_HEALTH = 2500 * 2,
        MALBATROSS_DAMAGE = 150,

        MALBATROSS_DAMAGE_PLAYER_PERCENT = .5,
        MALBATROSS_ATTACK_PERIOD = 4,
        MALBATROSS_ATTACK_RANGE = 4.5,
        MALBATROSS_AOE_RANGE = 2.75,
        MALBATROSS_AOE_SCALE = 0.8,
        MALBATROSS_LOSE_TARGET_PERIOD = 60,
        MALBATROSS_BOAT_DAMAGE = 5,
        MALBATROSS_BOAT_PUSH = 0.75,
        MALBATROSS_NOTHUNGRY_TIME =
        {
            MIN = 15,
            MAX = 25,
        },
        MALBATROSS_MISSFISH_TIME =
        {
            MIN = 10,
            MAX = 10,
        },
        MALBATROSS_ENTITYSLEEP_RELOCATE_TIME = 3 * total_day_time,
        MALBATROSS_EATSUCCESS_CHANCE = 0.50,
        MALBATROSS_MAX_CHASEAWAY_DIST = 50,
        MALBATROSS_NOTICEPLAYER_DISTSQ = 400, -- 20 * 20
        MALBATROSS_STOLENFISH_AGGROCOUNT = 2,
        MALBATROSS_HOOKEDFISH_SUMMONCHANCE = 0.3,

        OCEANFISH_SHOAL =
        {
            CHILD_REGENPERIOD = 3*seg_time,
            CHILD_SPAWNPERIOD = 5,
            MAX_CHILDREN = 8,
            SPAWNRADIUS = 6,
        },

		OCEANFISH =
		{
			WALKSPEED = 1.5,
			RUNSPEED = 3,
			FISHABLE_STAMINA =
			{
				drain_rate = 0.05, -- per second
				recover_rate = 0.1, -- per second
				struggle_times = {low = 3, high = 8, r_low = 1, r_high = 1}, -- uses self.stamina to lerp between low and high
				tired_times = {low = 4, high = 2, r_low = 1, r_high = 1}, -- uses self.stamina to lerp between low and high
			},

            SPRINKLER_DETECT_RANGE = 7,
            SPRINKLER_DETECT_PERIOD = 4,
		},

        GNARWAIL =
        {
            HEALTH = 1000,
            DAMAGE = 50,
            TARGET_DISTANCE = 9, -- TUNING.MAX_WALKABLE_PLATFORM_RADIUS + 5,
            WALK_SPEED = 1.5,
            RUN_SPEED = 4,
            DIVE_SPEED = 10,
            EAT_DELAY = seg_time * 0.5,
            TOSS_DELAY = seg_time,
            LOYALTY_PER_HUNGER = total_day_time/25,
            MAX_LOYALTY_TIME = 2.5*total_day_time,
            FULL_LOYALTY_PERCENT = 0.9,

            BODY_SLAM_ATTACK_DISTANCESQ = 100,

            DAMAGE_RADIUS = 3,
            ATTACK_PERIOD = 14,
--【★ 船 BOAT 与航行】5100-5175 行。
--  BOATATTACK_RADIUSSQ = 2.25, -- 1.5 * 1.5（第 5100 行）
--    ★★ 两个关键点：
--    (1) 值为 2.25 = 1.5²，行尾注释明示「先取 1.5 再平方」。
--        ⇒ 读法是「半径 1.5 格」，不是「半径 2.25 格」。
--    (2) 写成 1.5*1.5 而非 2.25 —— 保留平方语义，见 4013 行注释。
--  ⇒ 调船的攻击范围时，要改的是**平方根后的值**，别直接填 2.25。
            BOATATTACK_RADIUSSQ = 2.25, -- 1.5 * 1.5
            BOAT_ATTACK_DELAY = 2.5,
            HORN_RETREAT_TIME = 3,
            HORN_HEALTH = 130,
            HORN_BOAT_DAMAGE = 20,
        },
        GNARWAIL_HORN =
        {
            USES = 10,
        },
		GNARWAIL_HORN_FARM_PLANT_INTERACT_RANGE = 20, -- castspell action distance

        SQUID_RUNSPEED = 6,
        SQUID_WALKSPEED = 3,
        SQUID_SWIM_SPEED = 4,
        SQUID_HEALTH = 170,
        SQUID_DAMAGE = 20/3,
        SQUID_TARGET_RANGE = 2,
        SQUID_ATTACK_RANGE = 1.5,
        SQUID_ATTACK_PERIOD = 4,
        SQUID_TARGET_DIST = 8,
        SQUID_TARGET_KEEP = 20,
        SQUID_LIGHT_UP_INTENSITY = 0.8,
        SQUID_LIGHT_UP_FALLOFF = 0.5,
        SQUID_LIGHT_UP_RADIUS = 1.2,
        SQUID_LIGHT_DOWN_INTENSITY = 0.5,
        SQUID_LIGHT_DOWN_FALLOFF = 1.25,
        SQUID_LIGHT_DOWN_RADIUS = 0.75,
		SQUID_FISHABLE_STAMINA =
		{
			drain_rate = 0.05, -- per second
			recover_rate = 0.1, -- per second
			struggle_times = {low = 3, high = 8, r_low = 1, r_high = 1}, -- uses self.stamina to lerp between low and high
			tired_times = {low = 4, high = 2, r_low = 1, r_high = 1}, -- uses self.stamina to lerp between low and high
		},

        SCHOOL_SPAWN_DELAY = {min=0.5*seg_time, max=2*seg_time},
		SCHOOL_SPAWNER_FISH_CHECK_RADIUS = 30,
        SCHOOL_SPAWNER_FISH_OCEAN_PERCENT = 0.1,
		SCHOOL_SPAWNER_MAX_FISH = 5,
		SCHOOL_SPAWNER_BLOCKER_MOD = 1/3, -- 3 or more blockers will prevent spawning
		SCHOOL_SPAWNER_BLOCKER_LIFETIME = total_day_time,

		FISH_BOX_PRESERVER_RATE = -1/3,
		SEEDPOUCH_PRESERVER_RATE = 0.5,


        -- Wintersfeast 2019
		WARG_GINGERBREAD_GOO_DIST_VAR = 3,
		WARG_GOO_DAMAGE = 20,
--【★ 蟹王争霸 CRABKING（68 个参数）】5176-5400 行。
--  英文原注释标注 'Year of the Carrat, 2020'（第 5176 行）。
--    ★★ 这行注释说明该区块是**限时年兽活动的数值**，
--      每年可调，跨年后可能整体替换。
--    ★ 识别「年兽区块」的方法：搜 'Year of the' / 'Wintersfeast'。
--      本文件另有第 5147 行 'Wintersfeast 2019'。
        WARG_GOO_RADIUS = 1.5,
		WARG_GINGERBREAD_GOO_COOLDOWN = 10,

        GINGERBREADPIG_RUN_SPEED = 10,

		WINTERSFEASTTABLE =
		{
            TABLE_RANGE = 3.5, -- this will make FEAST RANGE obsolete.
			FEAST_RANGE = 8,
			PERISH_TIME_DEPLETION = 50,
			PERISH_OVER_TIME_MULTIPLIER = 0.25,
		},
		WINTERSFEASTBUFF =
		{
			MAXDURATION = 50,
			DURATION_GAIN_BASE = 7,
			DURATION_GAIN_MAXBONUS = 15,
			DROP_SPIRIT_PERCENTAGE_THRESHOLD = 0.5,
            EATTIME = 180,
			TICKRATE = 2,
			HEALTH_GAIN = 1,
			HUNGER_GAIN = (calories_per_day/total_day_time)*2,
			SANITY_GAIN = 100/(night_time*10),
		},


        -- Year of the Carrat, 2020 --
        RACE_STATS =
        {
            MIN_STAT_VALUE = 0,
            MAX_STAT_VALUE = 5,
            INIT_STAT_VALUE = 0,

            BAD_STAT_SPREAD = 3,
            WILD_STAT_SPREAD = 5,
        },

        CARRAT_GYM =
        {
            TRAINS_PER_DAY = 4,
            TRAINING_TIME = 3*seg_time,
        },

		YOTC_ADDTORACE_DIST = 5,

		YOTC_RACER_MAX_VISITS_PER_CHECKPOINT = 5,
		YOTC_RACER_CHECKPOINT_FIND_DIST = 20,
		YOTC_RACER_CHECKPOINT_TOO_FAR_AWAY = 40, -- double YOTC_RACER_CHECKPOINT_FIND_DIST
        YOTC_RACER_CHECKPOINT_REACHED_DIST = 2,
		YOTC_RACER_FORGETFULNESS_MAX_CHECKPOINTS = 8,
--【★ 竞速 YOTC_RACER 参数】5200-5240 行。
--  YOTC_RACER_CHECKPOINT_TIMEOUT = 75（第 5200 行），
--  英文注释 'racers will abort the race if it takes longer then this amount
--   of time to get to the next check point'
--    ★★ 英文原注释解释了**失败后果**：超时即退出竞速（fail-forward 式惩罚）。
--      与「撞毁重开」不同，玩家不会损失全部进度。
--    ★ 这是「软失败」设计：挫败感存在但不惩罚过度。
		YOTC_RACER_CHECKPOINT_TIMEOUT = 75, -- racers will abort the race if it takes longer then this amount of time to get to the next check point

		YOTC_RACE_MAX_DISTANCE_REWARDS = 9,

		YOTC_RACER_STAMINA_BAD = 2,
		YOTC_RACER_STAMINA_GOOD = 22,
		YOTC_RACER_STAMINA_VAR = 3,
		YOTC_RACER_STAMINA_EXHAUSTED_TIME = 2,
		YOTC_RACER_STAMINA_EXHAUSTED_TIME_VAR = 1,
		YOTC_RACER_STAMINA_SLEEP_CHANCE = .1,
		YOTC_RACER_STAMINA_SLEEP_TIME = 3,
		YOTC_RACER_STAMINA_SLEEP_TIME_VAR = 3,

        YOTC_RACER_SPEED_BAD = 5, -- carrat's walk speed is 4
        YOTC_RACER_SPEED_GOOD = 7, -- carrat's run speed is 7
		YOTC_RACER_SPEED_VAR = 0.5,

		YOTC_RACER_REACTION_START_STUN_LOOPS_MIN = 4,
		YOTC_RACER_REACTION_START_STUN_LOOPS_MAX = 5,
		YOTC_RACER_REACTION_START_BAD = 2,
		YOTC_RACER_REACTION_START_GOOD = 0,
		YOTC_RACER_REACTION_START_BAD_VAR = 2,
		YOTC_RACER_REACTION_START_GOOD_VAR = 0,

		YOTC_RACER_DIRECTION_BAD = 100, -- +/- degrees
		YOTC_RACER_DIRECTION_GOOD = 30, -- +/- degrees

        YOTC_RACER_TRAINER_DIST = 6,

		MINIBOATLANTERN_SPEED = 0.4,
		MINIBOATLANTERN_ACCELERATION = 0.3*FRAMES,
		MINIBOATLANTERN_WANDER_DIST = 6,
        MINIBOATLANTERN_LIGHTTIME = total_day_time*6,
        MINIBOATLANTERN_BURNTIME = 1.7,

		YOT_CATCOON_SHRINE_SYMBOLS =
		{
			DEFAULT = "feather01",
			goose_feather = "goose_feather01",
		},

        KITCOON_WALK_SPEED = 2,
        KITCOON_RUN_SPEED = 6,

		KITCOON_LOYALTY_MAX				= seg_time * 4, -- DEPRECATED
		KITCOON_LOYALTY_EMOTE_CHANCE	= 0.4,
		KITCOON_NEAR_DEN_DIST			= 10,

		KITCOON_PLAY_DELAY				= 10, -- play with toys
		KITCOON_PLAYFUL_DELAY			= 10, -- play with other kitcoons
		KITCOON_PLAYFUL_DELAY_RAND		= 8, -- play with other kitcoons

		KITCOON_NAMING_DIST = 8,
		KITCOON_NAMING_MAX_LENGTH = 20,

        KITCOON_HIDEANDSEEK_HIDETIMEOUT = 3,

		KITCOONDEN_HIDEANDSEEK_MIN_KITCOONS = 3,
		KITCOONDEN_HIDEANDSEEK_HIDING_RADIUS_MAX = 30,
		KITCOONDEN_HIDEANDSEEK_HIDING_RADIUS_MIN_SQ = 5*5,
		KITCOONDEN_HIDEANDSEEK_TIME_LIMIT = 60,

        KITCOON_HIDING_SOUND_FREQUENCY = 10,
		KITCOON_HIDING_OFFSET =
		{
			rock1					= {-175,    0,    0},
			rock2					= {-150,   50,    0},
			rock_flintless			= {-150,    0,    0},
			rock_flintless_med		= {  80,    0,    0},
			rock_flintless_low		= {-150,    0,    0},
			rock_moon				= {-115,   25,    0},
			rock_moon_shell			= {-175,    0,    0},

			berrybush				= {-130,    0,    0},
			berrybush2				= {-100,   25,    0},
			berrybush_juicy			= {-100,    0,    0},

			oasis_cactus			= { -25,   20,    0},
			cactus					= { -75,   20,    0},
		},

        TICOON_SPEED = 3.25,
		TICOON_EMBARK_SPEED = 7,
        TICOON_DAMAGE = 30,
        TICOON_LIFE = 200,

		KITCOON_HIDEANDSEEK_NOT_YOT_REWARDS =
		{
			flint					= 10,
			cutgrass				= 10,
			twigs					= 10,
			petals					= 10,

			acorn					= 3,
			pinecone				= 3,
			twiggy_nut				= 3,	-- oh, now players can get twiggy trees without them replacing saplings at world gen!

			rocks					= 3,
			petals_evil				= 3,
			spoiled_fish_small		= 3,

			feather_robin			= 3,
			feather_crow			= 3,
			feather_canary			= 3,

			oceanfish_small_2_inv	= 1,
			oceanfish_small_4_inv	= 1,

			trinket_3				= 1,
			trinket_6				= 1,
			trinket_22				= 2,
			trinket_24				= 1,
		},

        CRABKING_HEALTH = 12000,
        CRABKING_HEALTH_BONUS = 1000,



        CRABKING_CLAW_BOATDAMAGE = 35,
        CRABKING_CLAW_HEALTH = 200,
        CRABKING_CLAW_HEALTH_BOOST = 200,
        CRABKING_CLAW_HEALTH_BOOST_MAXGEM = 400,
        CRABKING_CLAW_WALK_SPEED = 1,
        CRABKING_CLAW_RUN_SPEED = 4,
        CRABKING_CLAW_RESPAWN_DELAY = 30,-- time each claw must regen for before being spawnable
        CRABKING_CLAW_PLAYER_DAMAGE = 40,
        CRABKING_CLAW_DAMAGE_BOOST = 10,
        CRABKING_CLAW_REGEN_DELAY = 5,  -- time between regening claws while healing
        CRABKING_BASE_CLAWS = 5,
        CRABKING_BASE_CANNONS = 4,
        CRABKING_BASE_MINIONS = 3,

        CRABKING_MAX_VELOCITY_MOD = 0,
        CRABKING_ANCHOR_DRAG = 10,

        CRABKING_STACKS = 20,
        CRABKING_DEADLY_GEYSERS = 8,
        CRABKING_GEYSER_BOATDAMAGE = 10,

        CRABKING_CAST_TIME = 8,
        CRABKING_CAST_TIME_FREEZE = 5,

        CRABKING_STACK_SUMMON_DELAY = 20,
        CRABKING_HEAL_DELAY = 40,
        CRABKING_CAST_DELAY = 5,
        CRABKING_FIX_TIME = 10,
        CRABKING_BASE_FREEZE_AMOUNT = 40,
        CRABKING_FREEZE_INCRAMENT = 10,
        CRABKING_FREEZE_RANGE = 10,
        CRABKING_REGEN = 50,
        CRABKING_REGEN_BUFF = 75,

        CRABKING_RESPAWN_TIME = total_day_time * 20,
        CRABKING_SPAWN_TIME = 1,
        SPAWN_CRABKING = true,

        CRABKING_CLAW_THRESHOLD = 0.9,
        CRABKING_HEAL_THRESHOLD = 0.85,
        CRABKING_STAGE_2 = 0.85,
--【分区 23 · 蟹王续 / 岩石与海洋生物】5361-5743 行
--  ★ 分区边界：CRABKING 续段 + WOBSTER + 沙丁鱼人 + 洞穴小怪。
        CRABKING_CLAW_ATTACKRANGE = 4.1,

        -- why not.
        CRABKING_DAMAGE = 150,
        CRABKING_DAMAGE_PLAYER_PERCENT = .5,
        CRABKING_ATTACK_RANGE = 5,
        CRABKING_AOE_RANGE = 3,
        CRABKING_AOE_SCALE = 0.8,
        CRABKING_ATTACK_PERIOD = 4,
        CRABKING_ATTACK_TARGETRANGE = 25,
        CRABKING_CANNONTIMER = 10,

        CRABKING_STAGE1_THRESHOLD = 0.90,

        CRABKING_FREEZE_THRESHOLD = 1500,

        CRABKING_ICEWALL_HEALTH = 100,
        CRABKING_ICEWALL_HEALTH_BONUS = 200,
        CRABKING_ICEWALL_HEALTH_BONUS_MAXGEM = 400,

        CRABKING_MOB_HEALTH = 200,
        CRABKING_MOB_HEALTH_BONUS_MAXGEM = 200,
        CRABKING_MOB_DAMAGE = 30,
        CRABKING_MOB_ATTACK_PERIOD = 4,
        CRABKING_MOB_ATTACK_RANGE = 3,
        CRABKING_MOB_HIT_RANGE = 3,
        CRABKING_MOB_MELEE_RANGE = 3,
        CRABKING_MOB_TARGET_DIST = 10,
        CRABKING_MOB_WAKE_RADIUS = 6,
        CRABKING_MOB_WALK_SPEED = 4,
        CRABKING_MOB_RUN_SPEED = 5,
        CRABKING_MOB_CHASE_TIME = 8,

        CRABKING_MOB_KNIGHT_HEALTH = 1000,
        CRABKING_MOB_KNIGHT_ATTACK_RANGE = 4.5,
        CRABKING_MOB_KNIGHT_DAMAGE = 80,

        --CRABKING_CANNONTOWER_WORK = 9,
        CRABKING_CANNONTOWER_BREACHTIME = 10,
        CRABKING_CANNONTOWER_HEALTH = 300,
        CRABKING_CANNONTOWER_HULL_SMASH_DAMAGE = 40,
        CRABKING_MORTAR_DAMAGE = 20,
        CRABKING_MORTAR_DAMAGE_BONUS = 5,
        CRABKING_MORTAR_MAXGEM_DAMAGE_BONUS = 25,

        CRABKING_WAVE_ATTACK_TIMEOUT_TIME = 8,

        MORTAR_DAMAGE = 50,
        MORTAR_DAMAGE_STAGE_1 = 20,
        MORTAR_DAMAGE_STAGE_2 = 30,
        MORTAR_DAMAGE_STAGE_3 = 40,
        MORTAR_DAMAGE_STAGE_4 = 50,

        CRABKING_TAUNTTIME = 10,

        TRIDENT =
        {
            DAMAGE = wilson_attack * 1.5,
            OCEAN_DAMAGE = wilson_attack * 2.25,
            USES = 200,
            SPELL =
            {
                USE_COUNT = 50,
                RADIUS = 2.75,
                DAMAGE = wilson_attack * 2.5,
                MINES = 10,
            },
        },
		TRIDENT_FARM_PLANT_INTERACT_RANGE = 20, -- castspell action distance


        WOBSTER_DEN_REGEN_PERIOD = 3*seg_time,
        WOBSTER_DEN_SPAWN_PERIOD = 4*seg_time,
        WOBSTER_DEN_MAX_CHILDREN = 2,
        WOBSTER_DEN_SPAWNRADIUS = 4,
        WOBSTER_DEN_WORK = 9,
        WOBSTER_DEN_ENABLED = true,

        --UNUSED
        WOBSTER_DEN =
        {
            REGEN_PERIOD = 3*seg_time,
            SPAWN_PERIOD = 4*seg_time,
            MAX_CHILDREN = 2,

            SPAWNRADIUS = 4,
            WORK = 9,
        },

        WOBSTER =
--【★ SURVIVE_TIME = 4*total_day_time】存活挑战时长 = 4 个昼夜。
--  ★ 长周期挑战用 total_day_time，且倍数取整数（4），
--    使「4 天」这个设计意图一目了然。
--  ★★ 与第 2204 行 DAPPERNESS_HUGE = 100/(day_time) 对比：
--    两者都用「整倍数」，但前者乘 total（4天），后者除 day（每昼夜）。
--    ⇒ 「乘整数倍分母」表达「N 个周期」，「除以整数倍分母」表达「每周期速率」。
        {
            SURVIVE_TIME = 4*total_day_time,
            HEALTH = 25 * multiplayer_attack_modifier,
            SPEED =
            {
                SWIM = 0.5,
                GROUND = 1,
            },
            FISHABLE_STAMINA =
            {
                drain_rate = 0.05,
                recover_rate = 0.1,
                struggle_times =
                {
                    low = 3,
                    high = 8,
                    r_low = 1,
                    r_high = 1,
                },
                tired_times =
                {
                    low = 4,
                    high = 2,
                    r_low = 1,
                    r_high = 1,
                },
            },
		},

		BOAT_WINCH =
		{
			LOWERING_SPEED = 2,
			RAISING_SPEED_FAST = 1.8,
			RAISING_SPEED_SLOW = 1.1,

			DURATION_LOWERED_SUCCESS = 1,
			DURATION_LOWERED_FAILURE = 0.5,

			BOAT_DRAG_DURATION = 1,
		},

        HERMITCRAB =
        {
            UNFRIENDLY_LEVEL = 0,
            SPEAKTIME = 3.5,
            DANCE_RANGE = 8,
            WALKSPEED = 2.8,
            RUNSPEED = 5,

            HEAVY_FISH_THRESHHOLD = 0.70,

            MEETING_RADIUS = 16,
        },

        MESSAGEBOTTLE_NOTE_CHANCE = 0.4,
        MAX_ACTIVE_TREASURE_HUNTS = 10,

        SINGINGSHELL_TRIGGER_RANGE = 4,
        SINGINGSHELL_FARM_PLANT_INTERACT_RANGE = 2,

        WATERPLANT =
        {
            DAMAGE = wilson_attack * 2,
            ITEM_DAMAGE = wilson_attack * 1.75,
            ATTACK_PERIOD = 5,
            YELLOW_ATTACK_PERIOD = 2.5,
            ATTACK_DISTANCE = 18,
            ATTACK_AOE = 1.5,
            HEALTH = 500,

            MAX_BARNACLES = 3,
            GROW_TIME = 2.5 * total_day_time,
            GROW_VARIANCE = 1.5 * total_day_time,
            REBIRTH_TIME = 2 * total_day_time,

            ANGERING_HIT_VELOCITY = 2.01,

            POLLEN_DURATION = 25,
            POLLEN_FADETIME = 2,
            POLLEN_RESETTIME = seg_time * 6,
            PINK_POLLEN_RESETTIME = seg_time * 3,
            POLLEN_RESETVARIANCE = seg_time / 2,

            FISH_SPAWN =
            {
                MAX_CHILDREN = 1,
                SPAWN_RADIUS = 4.5,
                REGEN_PERIOD = seg_time * 8,
                WHITE_REGEN_PERIOD = seg_time * 4,
            },
        },

        WATERPLANT_ROCK_WORKAMOUNT = 3,

        WAVEYJONES =
        {
            HAND =
            {
                WALK_SPEED = 1,--0.5,
            },
            RESPAWN_TIMER = 10,
        },

        SHARK =
        {
            DAMAGE = 20,
            HEALTH = 1000,
            WALK_SPEED = 1,
            RUN_SPEED = 7,

            WALK_SPEED_LAND = 7,
            RUN_SPEED_LAND = 7,

            ATTACK_RANGE = 4,

            TARGET_DIST = 8, --20,

            AOE_RANGE = 3,
            AOE_SCALE = 0.5, -- Unused?
        },

        OCEANHORROR =
        {
            ATTACH_OFFSET_PADDING = 0.5,

            ATTACK_RANGE = 4.1,
            SPEED = 2,
            HEALTH = 400,
            DAMAGE = 50,
            ATTACK_PERIOD = 3,
            BLOCK_TELEPORT_ON_HIT_DURATION = 3.5,
            BLOCK_TELEPORT_ON_HIT_DURATION_VARIANCE = 2,
        },

        MAST_LAMP_LIGHTTIME = (night_time+dusk_time)*2,

        WATERSTREAK_AOE_DIST = 3,

        WATERPUMP =
        {
            MAXRANGE = 7.5,
        },

        -- GROTTO

        SLEEPRESISTBUFF_TIME = total_day_time,
        SLEEPRESISTBUFF_VALUE = 10,

        SLEEPIMMUNEBUFF_TIME = seg_time,

--【★ 蘑菇侏儒 MUSHGNOME / 洞穴小怪】5600-5743 行。
--  MOON_MUSHROOM_SLEEPTIME = 3（第 5600 行附近）。
--    ★ SLEEPTIME = 睡眠时长（单位：天），与季节天数同体系。
        MOON_MUSHROOM_SLEEPTIME = 3,

        MOLEBAT_TARGET_DIST = 5,
        MOLEBAT_WALK_SPEED = 5,
        MOLEBAT_ATTACK_PERIOD = 2,
        MOLEBAT_ATTACK_RANGE = 2,
        MOLEBAT_HEALTH = 150,
        MOLEBAT_DAMAGE = 30,
        MOLEBAT_MAX_CHASE_DSQ = 225,
        MOLEBAT_NAP_COOLDOWN = seg_time * 9,
        MOLEBAT_NAP_LENGTH = seg_time * 4,
        MOLEBAT_ALLY_COOLDOWN = total_day_time * 2,
        MOLEBAT_ENABLED = true,

        --UNUSED
        MOLEBAT =
        {
            TARGET_DIST = 5,
            WALK_SPEED = 5,
            ATTACK_PERIOD = 2,
            ATTACK_RANGE = 2,
            HEALTH = 150,
            DAMAGE = 30,
            MAX_CHASE_DSQ = 225,
            ALLY_COOLDOWN = total_day_time * 2,
            NAP_COOLDOWN = seg_time * 9,
            NAP_LENGTH = seg_time * 4,
        },

        BATNOSEHAT_PERISHTIME = 0.5*total_day_time*perish_warp,
        HUNGERREGEN_TICK_RATE = 5,
        HUNGERREGEN_TICK_VALUE = 5 * (calories_per_day*2.5) / (0.5*total_day_time*perish_warp), -- Ensure that this matches the properties above!

        LIGHTFLIER =
        {
            HEALTH = 25 * multiplayer_attack_modifier,
            WALK_SPEED = 3.5,
            ON_ATTACKED_ALERT_DURATION = 4,
            ON_ATTACKED_ALERT_DURATION_VARIANCE = 1,
            STARVE_TIME = total_day_time*2,
        },

        LIGHTFLIER_FORMATION_SIZE = 3,

        LIGHTFLIER_FLOWER_REGROW_TIME = total_day_time*12, -- this refers to regrow after picked, not duration for regrowthmanager
        LIGHTFLIER_FLOWER_LIGHT_TIME = 140,
        LIGHTFLIER_FLOWER_LIGHT_TIME_VARIANCE = 50,
        LIGHTFLIER_FLOWER_RECHARGE_TIME = 110,
        LIGHTFLIER_FLOWER_TARGET_NUM_CHILDREN_OUTSIDE = 1,
        LIGHTFLIER_FLOWER_PICKABLE = true,

        LIGHTFLIER_FLOWER_RECALL_DELAY = 60,
        LIGHTFLIER_FLOWER_RECALL_DELAY_VARIANCE = 60,

        LIGHTFLIER_FLOWER_REGROWTH_TIME = total_day_time*5,
        LIGHTFLIER_FLOWER_REGROWTH_TIME_MULT = 1,

        LIGHTFLIER_FLOWER =
        {
            REGROW_TIME = total_day_time*12, -- this refers to regrow after picked, not duration for regrowthmanager
            LIGHT_TIME = 140,
            LIGHT_TIME_VARIANCE = 50,
            RECHARGE_TIME = 110,
            TARGET_NUM_CHILDREN_OUTSIDE = 1,

            RECALL_DELAY = 60,
            RECALL_DELAY_VARIANCE = 60,

            REGROWTH =
            {
                TIME = total_day_time*5,
                TIME_MULT = 1,
            },
        },

        MUSHGNOME_HEALTH = 600,
        MUSHGNOME_SPORESPAWN_MIN = 2,
        MUSHGNOME_SPORESPAWN_MAX = 4,
        MUSHGNOME_ATTACK_PERIOD = 8,
        MUSHGNOME_SPAWN_RADIUSSQ = 400,

        MOONSPORE_ATTACK_RANGE = 3,
        MOONSPORE_ATTACK_PROXIMITY = 3.5,
        MOONSPORE_DAMAGE = 10,
        MOONSPORE_PERISH_TIME = seg_time * 0.25,

        GROTTO_POOL_BIG_RADIUS = 5.5,
        GROTTO_POOL_SMALL_RADIUS = 2.0,
        GROTTO_MOONGLASS_REGROW_CHANCE = 0.10,

        ARCHIVE_CENTIPEDE =
        {
            DAMAGE = 40,
            AOE_DAMAGE = 20,
            HEALTH = 400 * 3,
            WALK_SPEED = 4,
            ATTACK_PERIOD = 5,
			ATTACK_RANGE = 3,
            HUSK_HEALTH = 300,
			AOE_RANGE = 4,
            TARGET_DIST = 12,
        },

        ARCHIVE_SECURITY =
        {
            REGEN_TIME = seg_time * 4,
            RELEASE_TIME = seg_time,
            WALK_SPEED = 5,
        },
        DUSTMOTH =
        {
            HEALTH = 200,
            HEALTH_REGEN = 4,
            WALK_SPEED = 2.6,
            DUSTABLE_RESET_TIME = seg_time * 2,
            DUSTABLE_RESET_TIME_VARIANCE = seg_time,
            DUSTOFF_COOLDOWN = 4,
            DUSTOFF_COOLDOWN_VARIANCE = 6,
            SEARCH_ANIM_COOLDOWN = 12,
            BLUEPRINT_DROP_CHANCE_REPEAT = 0.25,
        },
        DUSTMOTHDEN_REPAIR_TIME = total_day_time * 0.75,
        DUSTMOTHDEN_REGEN_TIME = total_day_time * 10,
        DUSTMOTHDEN_RELEASE_TIME = seg_time,
        DUSTMOTHDEN_MAX_CHILDREN = 1,
        DUSTMOTHDEN_MAXWORK = 5,
        DUSTMOTHDEN_ENABLED = true,

        --UNUSED
        DUSTMOTHDEN =
        {
            REPAIR_TIME = total_day_time * 0.75,
            REGEN_TIME = total_day_time * 10,
            RELEASE_TIME = seg_time,
            MAXWORK = 5,
        },

        ARCHIVE_RESONATOR =
        {
            USES = 10,
        },

		DAYLIGHT_SEARCH_RANGE = 30,

--【★★★ 分区 24 · ★★ 农业（正式段）】5744-5929 行 ★★★
--  ★★ 这是全文件**唯一以 '-- Farming' 为标题的区块**，
--    也是玩家中期玩法的数值核心所在。
--    ★ 注意它与第 17 分区（3761-3900 威尔洛火龙草）内容相关但不重复：
--      17 分区是「单个作物的专属参数」，本分区是「农场系统的通用规则」。
--
--  FARM_TILL_SPACING = 1.25（第 5744 行起）：
--    ★★ 耕地间距 1.25 格 —— 这是「网格吸附」的基准尺寸。
--      1.25 之所以能用，是因为它与物品碰撞盒、TILE_SCALE(=4) 成比例，
--      保证 4 块耕地正好占 5 格。
--      ★ 设计原理：**用 1/4 格作为最小单位**（1.25 = 5/4），
--        整个农场的摆放都会严丝合缝，不会出现半格错位。
		-- Farming
		FARM_TILL_SPACING = 1.25,
		FARM_PLANT_PHYSICS_RADIUS = 0.5,

		STARTING_NUTRIENTS_MIN = 20,
		STARTING_NUTRIENTS_MAX = 40,

        FARM_PLOW_USES = 4,
		FARM_PLOW_DRILLING_DURATION = seg_time * 0.5,
		FARM_PLOW_DRILLING_DEBRIS_MIN = 2,
		FARM_PLOW_DRILLING_DEBRIS_MAX = 4,

		FARM_PLOW_DRILLING_DIRT_DELAY_BASE_START = 1.5,
		FARM_PLOW_DRILLING_DIRT_DELAY_BASE_END = 0.2,
		FARM_PLOW_DRILLING_DIRT_DELAY_VAR = 0.3,

		SOIL_MOISTURE_UPDATE_TIME = 5,
		SOIL_RAIN_MOD = 1.5,
		SOIL_MIN_DRYING_TEMP = 0,
		SOIL_MAX_DRYING_TEMP = 70, -- same as OVERHEAT_TEMP
		SOIL_MIN_TEMP_DRY_RATE = 0,
		SOIL_MAX_TEMP_DRY_RATE = -0.05,
        SOIL_MAX_MOISTURE_VALUE = 100, --same as weather's max moisture

		FARM_SOIL_DEBRIS_LOOT_CHANCE = 0.25,

        ICE_MELT_GROUND_MOISTURE_AMOUNT = 25,

        WATERINGCAN_WATER_AMOUNT = 25,
        WATERINGCAN_USES = 40,
        WATERINGCAN_EXTINGUISH_HEAT_PERCENT = -1,
        WATERINGCAN_TEMP_REDUCTION = 5,
        WATERINGCAN_PROTECTION_TIME = 30,
		WATERINGCAN_PROTECTION_DIST = 2.25,

        PREMIUMWATERINGCAN_WATER_AMOUNT = 25,
        PREMIUMWATERINGCAN_USES = 160,

		FARM_PLANT_LONG_LIFE_MULT = 1.5,

		FARM_PLANT_CONSUME_NUTRIENT_LOW = 2,
		FARM_PLANT_CONSUME_NUTRIENT_MED = 4,
		FARM_PLANT_CONSUME_NUTRIENT_HIGH = 8,

		FARM_PLANT_DRINK_LOW =  -0.0075,
		FARM_PLANT_DRINK_MED =  -0.0200,
		FARM_PLANT_DRINK_HIGH = -0.0350,

		FARM_PLANT_DROUGHT_TOLERANCE = 0.10,

		FARM_PLANT_KILLJOY_RADIUS = 6,
		FARM_PLANT_KILLJOY_TOLERANCE = 0,

		FARM_PANT_OVERCROWDING_MAX_PLANTS = 10,

		FARM_PLANT_SAME_FAMILY_MIN = 4,  -- includes the plant doing the test
--【★ 同族植物排斥半径】FARM_PLANT_SAME_FAMILY_RADIUS = 4（第 5800 行）。
--  ★★ SAME_FAMILY 机制：同种植物不能种得太近（半径 4 格内）。
--    ★★ 设计意图：防止玩家把同一种作物铺满全田，
--      强制他们种植多样作物以抵御季节与天气风险。
--      这与真实农业「轮作」的精神一致 —— 是玩法与主题的呼应。
--    ★ 半径 4 格 ≈ 一个农场隔间的宽度，尺度上是合理的。
        FARM_PLANT_SAME_FAMILY_RADIUS = 4,

		SEASONAL_WEED_SPAWN_CAHNCE =
		{
			autumn = 0.05,
			spring = 0.15,
		},

		FORGETMELOTS_RESPAWNER_MIN = total_day_time * 2,
		FORGETMELOTS_RESPAWNER_VAR = total_day_time * 3,

		FIRE_NETTLE_TOXIN_TEMP_MODIFIER = 60,
		FIRE_NETTLE_TOXIN_DURATION = seg_time * 2,
		WEED_FIRENETTLE_DAMAGE = 3,

		WEED_TILLWEED_MAX_DEBRIS = 5,
		WEED_TILLWEED_DEBRIS_TIME_MIN = total_day_time * 0.75,
		WEED_TILLWEED_DEBRIS_TIME_VAR = total_day_time * 0.25,

        TILLWEEDSALVE_HEALTH_DELTA = 1,
        TILLWEEDSALVE_TICK_RATE = 3,
        TILLWEEDSALVE_DURATION = seg_time * 2,

		SWEETTEA_SANITY_DELTA = 1,
		SWEETTEA_TICK_RATE = 2,
		SWEETTEA_DURATION = seg_time * 2,

		FARM_PLANT_DEFENDER_SEARCH_DIST = 10,
		WEED_IVY_SNARE_DAMAGE = 10,

		BOOK_GARDENING_MAX_TARGETS = 10,

--【★ 堆肥 COMPOSTINGBIN 参数】5832-5906 行。
--  COMPOSTINGBIN_COMPOSTING_TIME_MIN = day_time*0.8（第 5832 行）= 240 秒。
--  COMPOSTWRAP_FERTILIZE = day_time * 6（第 4558 行附近）= 1800 秒。
--    ★★ 对比两个堆肥路径：堆肥箱 240 秒（快），堆肥布 1800 秒（慢 7.5 倍）。
--      ⇒ 堆肥布是「离线/长时间」方案，堆肥箱是「在线」方案。
--      这个倍率差让玩家有动力留在营地做快路径。
--    ★ 两者都用 day_time，改时钟后相对关系保持不变。
--    ⚠ 注意 4558 行的 day_time*6 出现在第 21 分区（角色）而非本分区，
--      虽同属堆肥系统却被追加到了远处 —— 又一个「分区不可靠」的实例。
        COMPOSTINGBIN_COMPOSTING_TIME_MIN = day_time*0.8,
        COMPOSTINGBIN_COMPOSTING_TIME_MAX = day_time*1.6,
        COMPOSTINGBIN_TURN_COMPOST_DURATION_MULTIPLIER = 0.7,

        COMPOST_FERTILIZE = day_time,
        COMPOST_SOILCYCLES = 10,
        COMPOST_WITHEREDCYCLES = 1,

		FORMULA_NUTRIENTS_INDEX = 1,
		COMPOST_NUTRIENTS_INDEX = 2,
		MANURE_NUTRIENTS_INDEX = 3,

        POOP_NUTRIENTS					= {  0,  0,  8 },
		FERTILIZER_NUTRIENTS			= {  0,  0, 16 },
        GUANO_NUTRIENTS					= {  0,  0, 16 },

        SPOILED_FOOD_NUTRIENTS			= {  0,  8,  0 },
		ROTTENEGG_NUTRIENTS				= {  0, 16,  0 },
        COMPOST_NUTRIENTS				= {  0, 24,  0 },

        SPOILED_FISH_SMALL_NUTRIENTS	= {  8,  0,  0 },
        SPOILED_FISH_NUTRIENTS			= { 16,  0,  0 },
		SOILAMENDER_NUTRIENTS_LOW		= {  8,  0,  0 },
		SOILAMENDER_NUTRIENTS_MED		= { 16,  0,  0 },
		SOILAMENDER_NUTRIENTS_HIGH		= { 32,  0,  0 },

        COMPOSTWRAP_NUTRIENTS			= { 24, 32, 24 },
        GLOMMERFUEL_NUTRIENTS			= {  8,  8,  8 },
        MOSQUITOFERTILIZER_NUTRIENTS    = { 12, 12, 12 },

        TREEGROWTH_NUTRIENTS            = {  8, 32,  8 },

        WX78_FOODBRICK_NUTRIENTS        = {  0, 32,  0 },

		WORMWOOD_MANURE_HEAL_VALUES = { 2, 3, 8, 12 },

		WORMWOOD_COMPOST_HEAL_VALUES = { 4, 6, 8, 32 },
		WORMWOOD_COMPOST_HEALOVERTIME_HEALTH = 2,
		WORMWOOD_COMPOST_HEALOVERTIME_TICK = 2,

        WORMWOOD_BLOOM_MAX_UPGRADE_MULT = 1.3,

--【★ 多行块注释的用法示例】5874 行附近以 --[[ ]] 长注释开始。
--  ★★ Lua 的 --[[ ]] 长注释在本文件里用于「整段说明」，
--    比连续多行 -- 更适合写大段设计说明。
--    ⚠ 注意：长注释内的嵌套 --[[ ]] 会导致语法错误，
--      在此文件里只见一层嵌套。
--[[
		FERTILIZER_HEAL_1 = 2,
		FERTILIZER_HEAL_2 = 4,
		FERTILIZER_HEAL_3 = 8, -- medsmall
		FERTILIZER_HEAL_4 = 30,
]]

        LORDFRUITFLY_DEAGGRO_DIST = 30,
        LORDFRUITFLY_TARGETRANGE = 15,
        LORDFRUITFLY_ATTACK_PERIOD = 2,
        LORDFRUITFLY_DAMAGE = 25,
        LORDFRUITFLY_ATTACK_DIST = 2,
        LORDFRUITFLY_HEALTH = 1500,
        LORDFRUITFLY_SUMMONPERIOD = 30,
        LORDFRUITFLY_INITIALSPAWN_TIME = total_day_time * 35,
        LORDFRUITFLY_RESPAWN_TIME = total_day_time * 20,
        LORDFRUITFLY_CROP_ROTTED_ADVANCE_TIME = total_day_time * 0.5,
        LORDFRUITFLY_SPAWNERRADIUS = 4,
        LORDFRUITFLY_SPAWNERCOUNT = 15,
        SPAWN_LORDFRUITFLY = true,
        LORDFRUITFLY_FRUITFLY_AMOUNT = 4,
        LORDFRUITFLY_WALKSPEED = 4,
        LORDFRUITFLY_TRIGGER_RANGE = 15,

        FRUITFLY_ONPICK_CHANCE = 0.05,
        FRUITFLY_DEAGGRO_DIST = 20,
        FRUITFLY_HEALTH = 100,
        FRUITFLY_DAMAGE = 5,
        FRUITFLY_ATTACK_DIST = 1,
        FRUITFLY_ATTACK_PERIOD = 2,
        FRUITFLY_TARGETRANGE = 15,
        FRUITFLY_WALKSPEED = 8,

--【★ WES（韦斯）rework 区块】5907-5930 行。
--  英文注释 'WES rework'（第 5907 行）：韦斯大改版。
--    ★★ 与 'v2 Winona' / 'v2 Willow' 同类，都是角色改版标记。
--      改版时新参数追加在旧参数附近/之后，老参数保留兼容。
		-- WES rework
		BALLOON_DAMAGE = 5,
		BALLOON_ATTACK_RANGE = 2,

		BALLOON_SPEEDS = {1, 1.1, 1.2, 1.3},
		BALLOON_SPEED_DURATION = total_day_time * 0.25,

        BALLOON_PILE_DECAY_TIME = total_day_time * 3,
		BALLOON_MAP_ICON_DURATION = 10,

		CONFFETI_PARTY_SANITY_TICKRATE = 2,
		CONFFETI_PARTY_SANITY_DELTA =
		{
			0,
			1,
			2,
			3,
			3.5,
			4,
		},

--【分区 25 · 果蝇与嘉年华】5928-6099 行
--  ★ 分区边界：CARNIVAL（嘉年华）与 FRUITFLY（果蝇）小游戏数值。
		-- Crow Carnival
		CARNIVAL_DECOR_RANK_RANGE = 8,
		CARNIVAL_DECOR_RANK_MAX = 3,
		CARNIVAL_DECOR_VALUE_PER_RANK = 100,

		CARNIVAL_THEME_MUSIC_RANGE = 12,

		CARNIVALGAME_DURATION = 30,

		CARNIVALGAME_FEEDCHICKS_NUM_ACTIVE = 5,
		CARNIVALGAME_FEEDCHICKS_HUNGRY_DURATION = 3,
		CARNIVALGAME_FEEDCHICKS_HUNGRY_DURATION_VAR = 1,
		CARNIVALGAME_FEEDCHICKS_ARENA_RADIUS = 8,
		CARNIVALGAME_FEEDCHICKS_NUM_FOOD = 4,

		CARNIVALGAME_HERDING_ARENA_RADIUS = 10,

		CARNIVALGAME_MEMORY_ARENA_RADIUS = 6,

		CARNIVALGAME_SHOOTING_ARENA_RADIUS = 11,
		CARNIVALGAME_SHOOTING_TARGET_ARC_R = 10,
		CARNIVALGAME_SHOOTING_TARGET_ARC_X = 2.5,
--【★ 嘉年华射击小游戏参数】5950-5999 行。
--  CARNIVALGAME_SHOOTING_ANGLE_METER_MIN = -50 - 90（第 5950 行附近）。
--    ★★ 注意写法 -50 - 90 = -140：
--      这是「基准值 - 90 度」的相位平移，把仪表角度区间从 [-50,50]
--      旋转到 [-140,-40]。
--      ★ 负角度表示表盘偏向左侧 —— 这是纯粹的 UI 几何计算。
--    ★★ 本文件里这类「角度偏移」都是弧度，需配合 DEGREES 常量使用
--      （见 constants.lua:14 DEGREES = PI/180）。
        CARNIVALGAME_SHOOTING_ANGLE_METER_MIN = -50 - 90,
        CARNIVALGAME_SHOOTING_ANGLE_METER_MAX = 50 - 90,
        CARNIVALGAME_SHOOTING_ANGLE_METER_SPEED = 55*1.5,

		CARNIVALGAME_WHEELSPIN_ARENA_RADIUS = 6,
		CARNIVALGAME_WHEELSPIN_INACTIVE_TIMEOUT = 4,

		CARNIVALGAME_PUCKDROP_ARENA_RADIUS = 6,
		CARNIVALGAME_PUCKDROP_INACTIVE_TIMEOUT_MIN = 3,
		CARNIVALGAME_PUCKDROP_INACTIVE_TIMEOUT_VAR = 2,

		CARNIVALGAME_CAMERA_FOCUS_MIN = 8,
		CARNIVALGAME_CAMERA_FOCUS_MAX = 8,

        CARNIVAL_HOST_TALK_TO_PLAYER_COOLDOWN = 10,

        CARNIVAL_CROWKID_RUN_SPEED = 5,
        CARNIVAL_CROWKID_WALK_SPEED = 3,
        CARNIVAL_CROWKID_TALK_TO_PLAYER_COOLDOWN = 15,
		CROWKID_ACTIVATE_DECOR_DELAY_MIN = 15,
		CROWKID_ACTIVATE_DECOR_DELAY_MAX = 30,
		CROWKID_ACTIVATE_DECOR_CHAIN_DELAY = 60,
		CROWKID_STOKE_FIRE_PRECENT = 0.15,
        CARNIVAL_CROWKID_CAMPFIRE_WANDER_DIST = 8,
		CARNIVAL_CROWKID_CAMPFIRE_SIT_DIST = 4,

        CARNIVAL_VEST_PERISHTIME = total_day_time*5,

		CARNIVALDECOR_LAMP_ACTIVATE_TIME = seg_time * 2,
		CARNIVALDECOR_LAMP_TOKEN_TIME = total_day_time,

		CARNIVALDECOR_EGGRIDE_ACTIVATE_TIME = seg_time,
		CARNIVALDECOR_EGGRIDE_TOKEN_TIME = total_day_time * 5,

        CARNIVAL_BALL_COLLISIONTIMEBUFFER = 8 * FRAMES,
        CARNIVAL_BALL_YBOUNCE = 20.0,        -- YOTB: Year of the Beefalo
        BASE_SEWING_TIME = night_time*.3333,
        REJECTION_SEWING_TIME = night_time*.3333,
        YOTB_STAGERANGE = 12,
        YOTB_POSTDISTANCE = 5,

        BEEFALO_NAMING_DIST = 12,
		BEEFALO_NAMING_MAX_LENGTH = 50,

        DEERCLOPS_ATTACKS_PER_SEASON = 4,
        DEERCLOPS_ATTACKS_OFF_SEASON = false,
        SPAWN_DEERCLOPS = true,

        BEARGER_CHANCES = {1},
        SPAWN_BEARGER = true,
--【★ 世界生成密度参数】6000-6050 行。
--  MOOSE_DENSITY = 0.5（第 6000 行）：驼鹿生成密度。
--    ★★ DENSITY 统一表示「每区域的生成数量比例」（0~1）。
--      这是**无量纲**参数，与时间无关，属绝对值/比例类。
--  SPAWN_MALBATROSS = true（第 6050 行）：
--    ★ 布尔开关型数值。这类「true/false 的 TUNING 值」很少见，
--      它们把「是否生成某 Boss」也纳入数据驱动，便于世界生成器统一读取。

        MOOSE_DENSITY = 0.5,

        MAX_BUTTERFLIES = 4,

        LUREPLANT_SPAWNINTERVAL = total_day_time * 4,
        LUREPLANT_SPAWNINTERVALVARIANCE = total_day_time * 1,

        PENGUINS_FLOCK_SIZE = 9,
        PENGUINS_MIN_DIST_FROM_STRUCTURES = 20,
        PENGUINS_MAX_COLONIES = 5,
        PENGUINS_MAX_COLONIES_BUFFER = 1,
        PENGUINS_SPAWN_INTERVAL = 30,

        PENGUINS_DEFAULT_NUM_BOULDERS = 7,

        QUAKE_FREQUENCY_MULTIPLIER = 1,

        RABBITHOLE_REGROWTH_TIME_MULT = 0,
        RABBITHOLE_REGROWTH_TIME_SUMMER_MULT = 1,

        REEDS_REGROWTH_TIME_BASE_MULT = 0,
        REEDS_REGROWTH_TIME_SPRING_MULT = 1,
        CACTUS_REGROWTH_TIME_SUMMER_MULT = 2,
        CACTUS_REGROWTH_TIME_WINTER_MULT = 0,
        CACTUS_REGROWTH_TIME_BASE_MULT = 1,
        CACTUS_REGROWTH_RAINING_MULT = 1.2,

        PIGHOUSE_SPAWN_TIME = total_day_time * 4,
        PIGHOUSE_ENABLED = true,
        RABBITHOUSE_SPAWN_TIME = total_day_time,
        RABBITHOUSE_ENABLED = true,

        SLURTLEHOLE_REGEN_PERIOD = seg_time*4,
        SLURTLEHOLE_SPAWN_PERIOD = 3,
        SLURTLEHOLE_CHILDREN = {min = 1, max = 2},
        SLURTLEHOLE_ENABLED = true,
        SLURTLEHOLE_RARECHILD_CHANCE = 0.1,

        MONKEYBARREL_REGEN_PERIOD = seg_time*4,
        MONKEYBARREL_SPAWN_PERIOD = seg_time,
        MONKEYBARREL_CHILDREN = {min = 3, max = 4},
        MONKEYBARREL_ENABLED = true,

        ROCKYHERD_SPAWNER_RANGE = 20,
        ROCKYHERD_SPAWNER_DENSITY = 6,

        MALBATROSS_SPAWNDELAY_BASE = total_day_time * 10,
        MALBATROSS_SPAWNDELAY_RANDOM = total_day_time * 5,
        MALBATROSS_SHOAL_PERCENTAGE_TO_TEST = 0.5,
        SPAWN_MALBATROSS = true,

        EVERGREEN_REGROWTH_TIME_MULT = 1,
        TWIGGYTREE_REGROWTH_TIME_MULT = 1,
        DECIDIOUS_REGROWTH_TIME_MULT = 1,
        MUSHTREE_REGROWTH_TIME_MULT = 1,
        MOONTREE_REGROWTH_TIME_MULT = 1,
        MOONMUSHTREE_REGROWTH_TIME_MULT = 1,

        MUSHGNOME_RELEASE_TIME = 20,
        MUSHGNOME_REGEN_TIME = total_day_time,
        MUSHGNOME_MAX_CHILDREN = 1,
        MUSHGNOME_ENABLED = true,

        NIGHTMARELIGHT_RELEASE_TIME = seg_time,
        NIGHTMARELIGHT_REGEN_TIME = 5,
        NIGHTMARELIGHT_MINCHILDREN = 1,
        NIGHTMARELIGHT_MAXCHILDREN = 2,
        NIGHTMARELIGHT_ENABLED = true,
        NIGHTMAREFISSURE_RELEASE_TIME = seg_time,
        NIGHTMAREFISSURE_REGEN_TIME = 5,
        NIGHTMAREFISSURE_MAXCHILDREN = 1,
        NIGHTMAREFISSURE_ENABLED = true,

        SHARK_SPAWN_CHANCE = 0.075,
        SHARK_TEST_RADIUS = 100,

        GNARWAIL_SPAWN_CHANCE = 0.1,
        GNARWAIL_TEST_RADIUS = 100,

        OCEAN_TRAWLER_SPAWN_FISH_MODIFIER = 2,
        OCEAN_TRAWLER_LOWERED_PERISH_RATE = 0.1,

        SQUID_TEST_RADIUS = 80,
        SQUID_MAX_FISH = 10,
        SQUID_MAX_NUMBERS = {
            ["new"] = 6,
            ["quarter"] = 3,
            ["half"] = 3,
            ["threequarter"] = 2,
            ["full"] = 0,
        },
        SQUID_CHANCE = {
            ["new"] = 0.25,
            ["quarter"] = 0.125,
            ["half"] = 0.065,
            ["threequarter"] = 0.03,
            ["full"] = 0,
        },

--【分区 26 · 鬼王与眼怪（ALTERGUARDIAN / EYEOFTERROR）】6100-6399 行
--  ★ 分区边界：鬼王 54 个参数 + 眼怪 30 个参数，是单主题第二大区块。
--  DROPPERWEB_RELEASE_TIME = total_day_time/2（第 6100 行）= 240 秒。
--    ★ 又是「除以整数倍分母」表达「每半天的周期」，与第 5450 行同范式。
        DROPPERWEB_RELEASE_TIME = total_day_time/2,
        DROPPERWEB_REGEN_TIME = total_day_time/4,
        DROPPERWEB_MIN_CHILDREN = 2,
        DROPPERWEB_MAX_CHILDREN = 3,
        DROPPERWEB_ENABLED = true,

        SPIDERHOLE_RELEASE_TIME = total_day_time/2,
        SPIDERHOLE_REGEN_TIME = total_day_time/4,
        SPIDERHOLE_MIN_CHILDREN = 2,
        SPIDERHOLE_MAX_CHILDREN = 3,
        SPIDERHOLE_SPITTER_CHANCE = 0.33,
        SPIDERHOLE_ENABLED = true,

        SANITYMONSTERS_INDUCED_MAXPOP = 5,
        SANITYMONSTERS_INDUCED_CHANCES = {
            inc = 0.7,
            dec = 0.4,
        },
        SANITYMONSTERS_MAXPOP = {1, 2},
        SANITYMONSTERS_CHANCES = {
            {
                inc = 0.1,
                dec = 0.3,
            },
            {
                inc = 0.3,
                dec = 0.2,
            },
        },
        SANITYMONSTERS_POP_CHANGE_INTERVAL = 10,
        SANITYMONSTERS_POP_CHANGE_VARIANCE = 10,
        SANITYMONSTERS_SPAWN_INTERVAL = 5,
        SANITYMONSTERS_SPAWN_VARIANCE = 10,
        TERRORBEAK_SPAWN_CHANCE = 0.5,

        -- Moon Storms
        ALTERGUARDIAN_PLAYERDAMAGEPERCENT = 0.75,

        ALTERGUARDIAN_PHASE1_WALK_SPEED = 5,
        ALTERGUARDIAN_PHASE1_HEALTH = 10000,
        ALTERGUARDIAN_PHASE1_ROLLDAMAGE = 166.67,
        ALTERGUARDIAN_PHASE1_AOEDAMAGE = 66.67,
        ALTERGUARDIAN_PHASE1_ATTACK_PERIOD = 7.5,
		ALTERGUARDIAN_PHASE1_ROLLRANGE = 2.25,
		ALTERGUARDIAN_PHASE1_AOERANGE = 4,
        ALTERGUARDIAN_PHASE1_ROLLCOOLDOWN = 8.5,
        ALTERGUARDIAN_PHASE1_MINROLLCOUNT = 3,
        ALTERGUARDIAN_PHASE1_SUMMONCOOLDOWN = 20,
        ALTERGUARDIAN_PHASE1_TARGET_DIST = 20,
        ALTERGUARDIAN_PHASE1_SHIELDTRIGGER = 2000,
--【★ 鬼王阶段护盾】ALTERGUARDIAN_PHASE1_SHIELDABSORB = 0.80（第 6150 行）。
--  SHIELDABSORB = 0.80 —— **无量纲比例**，不是点数。
--    ★★ 与第 2018 行 MAXIMUM_HEALTH_PENALTY = 0.75 同类：
--      小于 1 的 TUNING 值基本都是比例/系数，不是绝对量。
--    ⇒ 快速判读法：值<1 看是不是倍率，值>1 看是不是点数/秒数。
        ALTERGUARDIAN_PHASE1_SHIELDABSORB = 0.80,

        ALTERGUARDIAN_PHASE2_WALK_SPEED = 4.5,
        ALTERGUARDIAN_PHASE2_MAXHEALTH = 20000,
        ALTERGUARDIAN_PHASE2_STARTHEALTH = 13000,
        ALTERGUARDIAN_PHASE2_DAMAGE = 133.33,
        ALTERGUARDIAN_PHASE2_ATTACK_PERIOD = 6.0,
        ALTERGUARDIAN_PHASE2_CHOP_RANGE = 4.5,
        ALTERGUARDIAN_PHASE2_SPIN_RANGE = 18,
        ALTERGUARDIAN_PHASE2_SPIN_SPEED = 7.6,
        ALTERGUARDIAN_PHASE2_SPINMIN = 3,
        ALTERGUARDIAN_PHASE2_SPINMAX = 5,
        ALTERGUARDIAN_PHASE2_SPINCD = 14.25,
        ALTERGUARDIAN_PHASE2_SPIKEDAMAGE = 50,
        ALTERGUARDIAN_PHASE2_SPIKECOOLDOWN = 18.25,
        ALTERGUARDIAN_PHASE2_SPIKE_RANGE = 10,
        ALTERGUARDIAN_PHASE2_SPIKE_LIFETIME = 30,
        ALTERGUARDIAN_PHASE2_SUMMONCOOLDOWN = 24.25,
        ALTERGUARDIAN_PHASE2_TARGET_DIST = 30,

        ALTERGUARDIAN_PHASE3_WALK_SPEED = 7.5,
        ALTERGUARDIAN_PHASE3_MAXHEALTH = 22500,
        ALTERGUARDIAN_PHASE3_STARTHEALTH = 14000,
        ALTERGUARDIAN_PHASE3_RUNAWAY_BLOCK_TIME = 1.0,
        ALTERGUARDIAN_PHASE3_GOHOMEDSQ = 144,
        ALTERGUARDIAN_PHASE3_DAMAGE = 150,
        ALTERGUARDIAN_PHASE3_LASERDAMAGE = 120,
        ALTERGUARDIAN_PHASE3_ATTACK_PERIOD = 5.0,
        ALTERGUARDIAN_PHASE3_ATTACK_RANGE = 14,
        ALTERGUARDIAN_PHASE3_STAB_RANGE = 3.5,
        ALTERGUARDIAN_PHASE3_STAB_HITRANGE = 2,
        ALTERGUARDIAN_PHASE3_TRAP_CD = 40,
        ALTERGUARDIAN_PHASE3_TRAP_LT = 20,
        ALTERGUARDIAN_PHASE3_TRAP_MINRANGE = 2.0,
        ALTERGUARDIAN_PHASE3_TRAP_MAXRANGE = 3.5,
        ALTERGUARDIAN_PHASE3_TRAP_AOERANGE = 3.0,
        ALTERGUARDIAN_PHASE3_TRAP_GROGGINESS = 1.0,
        ALTERGUARDIAN_PHASE3_TRAP_KNOCKOUTTIME = 3.0,
        ALTERGUARDIAN_PHASE3_TRAP_LANDEDDAMAGE = 50,
        ALTERGUARDIAN_PHASE3_TRAP_WORKS = 3,
        ALTERGUARDIAN_PHASE3_SUMMONCOOLDOWN = 45,
        ALTERGUARDIAN_PHASE3_SUMMONMAXLOOPS = 60,
        ALTERGUARDIAN_PHASE3_SUMMONRSQ = 400, --20 ^2
        ALTERGUARDIAN_PHASE3_TARGET_DIST = 20,
		ALTERGUARDIAN_PHASE3_MAX_STUN_LOCKS = 5,

        ALTERGUARDIAN_PROJECTILE_SPEED = 20,

		ALTERGUARDIANHAT_GESTALT_DAMAGE = wilson_attack * 1.25,
        ALTERGUARDIANHAT_SEEDCOUNT_FOR_FULL_PLANAR_CONVERSION = 3,
--【★ 鬼王帽（ALTERGUARDIANHAT）】6200-6240 行。
--  ALTERGUARDIANHAT_MAX_PLANAR_CONVERSION = 0.25（第 6200 行）：
--    ★★ CONVERSION = 转换率。含义：最多把25% 的平面伤害转为其他类型。
--    ★ 命名规律：_MAX_ 前缀表示「该效果的上限」，
--      实际转换量取决于玩家当前资源（理智/生命），不是固定值。
--      ⇒ 调平衡时改MAX 只改上限，改下限应找对应的 _MIN_ 键。
        ALTERGUARDIANHAT_MAX_PLANAR_CONVERSION = 0.25,
        ALTERGUARDIANHAT_SEEDCOUNT_EXTRA_DAMAGE_MAX = wilson_attack * 0.25,

        WAGSTAFF_NPC_EXPIRE_TIME = seg_time * 4,
        WAGSTAFF_NPC_HUNTS = 4,
        WAGSTAFF_EXPERIMENT_TIME = 90,

        MOONSTORM_MOVE_TIME = 4,
        MOONSTORM_MOVE_MAX = 6,

        MUTANT_BIRD_AGGRO_DIST = 15,
        MUTANT_BIRD_RETURN_DIST = 30,
        MUTANT_BIRD_DAMAGE = 20,
        MUTANT_BIRD_HEALTH = 10,
        MUTANT_BIRD_SPLASH_DAMAGE = 20,
        MUTANT_BIRD_TARGET_DIST = 16,
        MUTANT_BIRD_ATTACK_RANGE = 2,
        MUTANT_BIRD_WALK_SPEED = 4,
        MUTANT_BIRD_ATTACK_COOLDOWN = 6,
        MUTANT_BIRD_SPIT_RANGE = 10,

        MOONSTORM_SPARK_HEALTH = 100,
		MOONSTORM_SPARK_DAMAGE = 10 / 1.5, --accounting for electric dmg mult

        MOONSTORM_GOGGLES_PERISHTIME = total_day_time*1,

        MOONSTORM_SPEED_MOD = .4,

        STORM_SWAP_TIME = 4/30,

        MOON_ALTAR_LINK_AREA_CLEAR_RADIUS = 6,
        MOON_ALTAR_LINK_POINT_VALID_RADIUS_SQ = 2.5*2.5,
        MOON_ALTAR_LINK_ALTAR_MIN_RADIUS_SQ = 2.5*2.5,

        MOONGLASS_CHARGED_PERISH_TIME = total_day_time*1.5,
        SPARK_PERISH_TIME = total_day_time*0.75,

        SPIDER_SUMMON_TIME = 12,
        SPIDER_WHISTLE_USE_AMOUNT = 2.5,
        SPIDER_DEN_SHAVING_AMOUNT = 1,

        SPIDER_PERISH_TIME = total_day_time * 5,

        SPIDER_HEALER_HEALTH = 400,
        SPIDER_HEALER_DAMAGE = 10,

        SPIDER_HEALING_AMOUNT = 150,
        SPIDER_HEALING_RADIUS = 8,
        SPIDER_HEALING_COOLDOWN = 8,
        SPIDER_HEALING_MELEE_RANGE = 1,
--【★ 蜘蛛治愈参数】SPIDER_HEALING_ITEM_AMOUNT = 80（第 6250 行附近）。
--    ★ 治疗量 80 点 —— 是普通草药（15）的 5 倍多。
--      反映蜘蛛治愈剂的稀有度与强度。

        SPIDER_HEALING_ITEM_AMOUNT = 80,
        SPIDER_HEALING_ITEM_RADIUS = 5,

        SPIDER_WHISTLE_DURATION = 10,
        SPIDER_WHISTLE_RANGE = 16,

        SPIDER_DEFENSIVE_MIN_FOLLOW = 2,
        SPIDER_DEFENSIVE_MED_FOLLOW = 2,
        SPIDER_DEFENSIVE_MAX_FOLLOW = 4,
        SPIDER_AGGRESSIVE_MIN_FOLLOW = 2,
        SPIDER_AGGRESSIVE_MED_FOLLOW = 3,
        SPIDER_AGGRESSIVE_MAX_FOLLOW = 8,

        SPIDER_DEFENSIVE_MAX_CHASE_TIME = 3,
        SPIDER_AGGRESSIVE_MAX_CHASE_TIME = 8,

        BEDAZZLEMENT_RATE = 1,
        BEDAZZLEMENT_RADIUS = { 12, 16, 20 },
        BEDAZZLEMENT_DURATION = 2,
        BEDAZZLER_USE_AMOUNT = 20,

        SPIDERDEN_CREEP_RADIUS_BEDAZZLED = 4,
        SPIDERDEN_CREEP_RADIUS = {5, 9, 9 },

        SPIDER_REPELLENT_USES = 20,
        SPIDER_REPELLENT_RADIUS = 8,

        SPIDER_FOLLOWER_COUNT = 2,

        FOLLOWER_REFOLLOW_DIST_SQ = 20 * 20,

        -- Waterlogged
        OCEANVINE_ENABLED = true,
        OCEANVINE_COCOON_SPIDER_RADIUS = 16,
        OCEANVINE_COCOON_REGEN_TIME = total_day_time/4,
        OCEANVINE_COCOON_RELEASE_TIME = total_day_time/2,
        OCEANVINE_COCOON_MIN_CHILDREN = 2,
        OCEANVINE_COCOON_MAX_CHILDREN = 3,
        OCEANVINE_COCOON_REGEN_BASE = 3 * total_day_time,
        OCEANVINE_COCOON_REGEN_RAND = 2 * total_day_time,

        SPIDER_WATER_DAMAGE = 20,
        SPIDER_WATER_ATTACK_PERIOD = 3,
        SPIDER_WATER_HIT_RANGE = 2,
        SPIDER_WATER_HEALTH = 200,
        SPIDER_WATER_EATCD = 20,
        SPIDER_WATER_FISH_TARGET_DIST = 1.5,
        SPIDER_WATER_INVESTIGATETIMEBASE = 15,
        SPIDER_WATER_WALKSPEED = 3.0,
--【★ 水蛭草 OCEANVINE 再生】OCEANVINE_REGROW_TIME = total_day_time*2.5。
--    = 1200 秒（20 分钟）。★ 再生很慢，属「珍稀资源」。
        SPIDER_WATER_RUNSPEED = 7.0,
        SPIDER_WATER_OCEANFLOATSPEED = 1.5,
        SPIDER_WATER_OCEANDASHSPEED = 10,

        GRASSGATOR_WALKSPEED = 1.5,
        GRASSGATOR_RUNSPEED = 6.5,
        GRASSGATOR_RUNSPEED_WATER = 3.5,
        GRASSGATOR_HEALTH = 500 * 2, -- harder for multiplayer
        GRASSGATOR_DAMAGE = 50,
        GRASSGATOR_TARGET_DIST = 5,
        GRASSGATOR_CHASE_DIST = 30,
        GRASSGATOR_FOLLOW_TIME = 30,
        GRASSGATOR_SHEDTIME_SET = total_day_time/2,
        GRASSGATOR_SHEDTIME_VAR = total_day_time/2,
        GRASSGATOR_REGEN_TIME = seg_time * 4,
        GRASSGATOR_RELEASE_TIME = seg_time,
        GRASSGATOR_MAXCHILDREN = 1,
        GRASSGATOR_ENABLED = true,


        SHADE_CANOPY_RANGE = 28,
        SHADE_CANOPY_RANGE_SMALL = 22, -- this is just a number now..
        WATERTREE_PILLAR_CANOPY_BUFFER = 1,

        WATERTREE_PILLAR_RAM_RECHARGE_TIME = 1.5, -- in days
        OCEANTREENUT_REGENERATE_TIME = total_day_time * 1,
        OCEANTREENUT_REGENERATE_TIME_VARIANCE = total_day_time * 0.5,

        CANOPY_MAX_ROTATION = 20,
        CANOPY_ROTATION_SPEED = 5,
        CANOPY_MAX_TRANSLATION = 1,
        CANOPY_TRANSLATION_SPEED = 5,

        CANOPY_MIN_STRENGTH = 0.2,
        CANOPY_MAX_STRENGTH = 0.4,  --0.7

        CANOPY_SCALE = 4,

        OCEANTREE_ENRICHED_COOLDOWN_MIN = total_day_time * 3,
        OCEANTREE_ENRICHED_COOLDOWN_VARIANCE = total_day_time * 1.5,
        OCEANTREE_CHOPS_NORMAL = 10,
        OCEANTREE_PILLAR_CHOPS = 25,
        OCEANTREE_STAGES_TO_SUPERTALL = 4,

        OCEANTREE_VINE_DROP_MAX = 4,

        OCEANTREENUT_GROW_TIME = total_day_time * 1.2,
        OCEANTREENUT_GROW_TIME_VARIANCE = total_day_time * 1.5,

        WATERTREE_ROOT_CHOPS = 3,
--【分区 27 · 双子（Twin）· 羊驼 · 钟表谜题】6400-6599 行
--  ★ 分区边界：TWIN1 / TWIN2 姐妹 Boss + MIGHTINESS（神力）系统。
--  ★★ 「TWIN1_/TWIN2_」命名显示这是**成对设计**：
--    两个 Boss 共享同一套参数结构，差异靠 1/2 后缀区分。
--    ⇒ 调平衡时两个都要看，只调一个会造成强度失衡。

        OCEANVINE_REGROW_TIME = total_day_time*2.5,

        -- Eye For An Eye
        SPAWN_EYEOFTERROR = true,
        EYEOFTERROR_SPAWNDELAY = total_day_time * 15,

		TERRARIUM_WARNING_TIME = 10,
		TERRARIUM_SUMMON_DELAY = 5,

        EYEOFTERROR_HEALTH = 5000,
        EYEOFTERROR_HEALTHPCT_PERDAY = 0.05,
        EYEOFTERROR_TRANSFORMPERCENT = 0.65,
        EYEOFTERROR_DAMAGE = 125,
        EYEOFTERROR_DAMAGEPLAYERPERCENT = 0.5,
        EYEOFTERROR_DEAGGRO_DIST = 60,
        EYEOFTERROR_CHARGESPEED = 15,
        EYEOFTERROR_CHARGEMINDSQ = 0,
        EYEOFTERROR_CHARGEMAXDSQ = 196,
        EYEOFTERROR_ATTACK_RANGE = 3,
        EYEOFTERROR_AOERANGE = 3,
        EYEOFTERROR_AOE_DAMAGE = 100,
        EYEOFTERROR_ATTACKPERIOD = 3,
        EYEOFTERROR_SLEEPRESIST = 4,
        EYEOFTERROR_CHOMP_SINKHOLERADIUS = 2.0,
        EYEOFTERROR_MINGUARDS_PERSPAWN = 2,
        EYEOFTERROR_EYE_MINGUARDS = 2,
        EYEOFTERROR_MOUTH_MINGUARDS = 4,
        EYEOFTERROR_EPICSCARE_RANGE = 10,

        EYEOFTERROR_CHARGECD = 7,
        EYEOFTERROR_MOUTHCHARGECD = 15,
		EYEOFTERROR_CHARGE_AOERANGE = 1.75,
        EYEOFTERROR_SPAWNCD = 18,
        EYEOFTERROR_FOCUSCD = 21,

        EYEOFTERROR_MINI_EGGTIME = 15,
        EYEOFTERROR_MINI_HEALTH = 200,
        EYEOFTERROR_MINI_DAMAGE = 20,
        EYEOFTERROR_MINI_ATTACK_RANGE = 3.0,
        EYEOFTERROR_MINI_HIT_RANGE = 2.25,
        EYEOFTERROR_MINI_ATTACK_PERIOD = 3,

        TWINS_RESET_DAY_COUNT = 2,  -- 1 higher than we really want, just makes the code simpler.

		-- Twin 1
		TWIN1_HEALTH				= 10000,  --2.0*TUNING.EYEOFTERROR_HEALTH,
		TWIN1_DAMAGE				= 250,    --2.0*TUNING.EYEOFTERROR_DAMAGE,
        TWIN1_AOE_DAMAGE			= 250,    --2.5*TUNING.EYEOFTERROR_AOE_DAMAGE
        TWIN1_MINGUARDS_PERSPAWN	= 2 + 2,   --TUNING.EYEOFTERROR_MINGUARDS_PERSPAWN + 2
--【★ 双子 Boss 参数】6400-6440 行。
--  TWIN1_CHARGECD = 0.50* 7, --0.50*TUNING.EYEOFTERROR_CHARGECD,（第 6400 行）
--    ★★★ 双重表达式并列，是本文件最有意思的一处「调参痕迹」：★★★
--      写的是 0.50*7（= 3.5 秒），
--      紧接着的注释 '--0.50*TUNING.EYEOFTERROR_CHARGECD' 是**旧写法**。
--    ⚠ 疑似缺陷（硬编码替换了引用）：
--      推理依据：旧写法引用 EYEOFTERROR_CHARGECD（会随眼怪参数联动），
--        新写法把引用**求值成了裸数字 7**。
--      ⇒ 后果：调整 EYEOFTERROR_CHARGECD 时，TWIN1_CHARGECD 不再跟随，
--        两个 Boss 的蓄力节奏会脱钩。
--      ★ 推测原因：为了让双子比眼怪慢（或快）而故意解耦。
--    ★★ 这是「归一化 vs 绝对值」讨论的一个反例：
--      此处原本是**引用式**（可联动），被改成了**硬编码式**（隔离）。
--      两种写法各有用途 —— 联动易失衡，隔离易脱钩。

		TWIN1_CHARGECD				= 0.50* 7, --0.50*TUNING.EYEOFTERROR_CHARGECD,
		TWIN1_MOUTHCHARGECD			= 0.50*15, --0.50*TUNING.EYEOFTERROR_MOUTHCHARGECD,
		TWIN1_SPAWNCD				= 0.30*18, --0.30*TUNING.EYEOFTERROR_SPAWNCD,
		TWIN1_FOCUSCD				= 0.60*21, --0.60*TUNING.EYEOFTERROR_FOCUSCD,

        TWIN1_CHARGESPEED			= 20,
		TWIN1_CHARGETIMEOUT			= 1.0,
		TWIN1_MOUTH_CHARGESPEED		= 22,
		TWIN1_MOUTH_CHARGETIMEOUT	= 0.70,
		TWIN1_TAUNT_CHANCE			= 0.50,

		-- Twin 2
		TWIN2_HEALTH				= 10000,   --2.0*TUNING.EYEOFTERROR_HEALTH,
		TWIN2_DAMAGE				= 250,     --2.0*TUNING.EYEOFTERROR_DAMAGE,
        TWIN2_AOE_DAMAGE			= 250,	   --2.5*TUNING.EYEOFTERROR_AOE_DAMAGE
        TWIN2_MINGUARDS_PERSPAWN	= 2,       --TUNING.EYEOFTERROR_MINGUARDS_PERSPAWN

		TWIN2_CHARGECD				= 0.25* 7, --0.25*TUNING.EYEOFTERROR_CHARGECD,
		TWIN2_MOUTHCHARGECD			= 0.25*15, --0.25*TUNING.EYEOFTERROR_MOUTHCHARGECD,
		TWIN2_SPAWNCD				= 1.00*18, --TUNING.EYEOFTERROR_SPAWNCD,
		TWIN2_FOCUSCD				= 0.60*21, --0.60*TUNING.EYEOFTERROR_FOCUSCD,

        TWIN2_CHARGESPEED			= 23,      --1.15*TWIN1_CHARGESPEED
		TWIN2_CHARGETIMEOUT			= 0.40,
		TWIN2_MOUTH_CHARGESPEED		= 25,
		TWIN2_MOUTH_CHARGETIMEOUT	= 0.50,
		TWIN2_TAUNT_CHANCE			= 0.25,

		EYEMASK_PERISHTIME = total_day_time*10,

        SHIELDOFTERROR_DAMAGE = wilson_attack*1.5,
        SHIELDOFTERROR_ABSORPTION = .8*multiplayer_armor_absorption_modifier,
        SHIELDOFTERROR_ARMOR = wilson_health*3*multiplayer_armor_durability_modifier,
        SHIELDOFTERROR_USEDAMAGE = 2,

        -- Wolfgang
        MIGHTINESS_MAX = 100,
        MIGHTINESS_DRAIN_RATE = 0.2, -- per second

        MIGHTINESS_DRAIN_MULT_SLOW = 0.5,
        MIGHTINESS_DRAIN_MULT_NORMAL = 1,
        MIGHTINESS_DRAIN_MULT_FAST = 2,
        MIGHTINESS_DRAIN_MULT_FASTEST = 3,
        MIGHTINESS_DRAIN_MULT_STARVING = 8,

        WIMPY_THRESHOLD = 25,
        MIGHTY_THRESHOLD = 75,

        DUMBBELL_CONSUMPTION_ROCK = 0.8,
--【★ 沃尔夫冈哑铃与神力】6450-6560 行。
--  DUMBBELL_CONSUMPTION_GOLD = 0.5（第 6450 行）：举哑铃消耗 50% 金子。
--    ★★ 这是一个「资源交换率」：力量提升的代价是金币。
--      0.5 = 每次消耗半袋金子，玩家能直观感知代价。
--  英文注释（第 6467 行）：
--    'Dumbbells are custom made tools (designed by Wolfgang for Wolfgang),
--     not something to b...'
--    ★ 说明哑铃是「沃尔夫冈专属定制工具」，非通用物品。
--      ⇒ 别的角色无法使用，调平衡时不必考虑通用性。
        DUMBBELL_CONSUMPTION_GOLD = 0.5,
        DUMBBELL_CONSUMPTION_MARBLE = 0.3,
        DUMBBELL_CONSUMPTION_GEM = 0.2,

        DUMBBELL_CONSUMPTION_BLUEGEM = 0.3,
        DUMBBELL_CONSUMPTION_REDEM = 0.3,
        DUMBBELL_CONSUMPTION_HEAT = 0.8,

        DUMBBELL_DAMAGE_ROCK = wilson_attack*.5,
        DUMBBELL_DAMAGE_GOLD = wilson_attack*.8,
        DUMBBELL_DAMAGE_MARBLE = wilson_attack,
        DUMBBELL_DAMAGE_GEM = wilson_attack * 1.25,

        DUMBBELL_DAMAGE_HEAT = wilson_attack*.5,
        DUMBBELL_DAMAGE_REDGEM =  wilson_attack * 1.25,
        DUMBBELL_DAMAGE_BLUEGEM =  wilson_attack * 1.25,

		-- Dumbbells are custom made tools (designed by Wolfgang for Wolfgang), not something to be tossed about...
		DUMBBELL_ATTACK_CONSUMPTION_MULT = 2,
		DUMBBELL_THROWN_CONSUMPTION_MULT = 10,

		DUMBBELL_SLOW_MARBEL = 0.9,

        DUMBBELL_EFFICIENCY_LOW = 1.5,
        DUMBBELL_EFFICIENCY_MED = 3.0,
        DUMBBELL_EFFICIENCY_HIGH = 5.0,
		DUMBBELL_EFFICIENCY_ATTCK_SCALE = 0.5,

		WOLFGANG_MIGHTINESS_WORK_GAIN =
		{
			CHOP = 0.5,				-- ~0.4s
			MINE = 1.0,				-- ~0.4s
			HAMMER = 0.25,			-- ~0.4s -- please dont hammer down other people's bases...
			DIG = 2,
			ROW = 0.5,				-- ~0.4s without lag
			LOWER_SAIL_BOOST = 2,
			TILL = 1,				-- ~1.1s
			TERRAFORM = 1.5,
		},

		WOLFGANG_MIGHTINESS_ATTACK_GAIN_GIANT = 1,
		WOLFGANG_MIGHTINESS_ATTACK_GAIN_SMALLCREATURE = 0.25,
		WOLFGANG_MIGHTINESS_ATTACK_GAIN_DEFAULT = 0.5,

		WOLFGANG_MIGHTINESS_DRAIN_DELAY = 4,

        WIMPY_WORK_EFFECTIVENESS = 0.75,
		WIMPY_HUNGER_RATE_MULT = 0.75,

        MIGHTY_WORK_CHANCE = 0.99,
        MIGHTY_WORK_EFFECTIVENESS = 1.5,
        MIGHTY_ROWER_MULT = 1.33,
		MIGHTY_ROWER_EXTRA_MAX_VELOCITY = 0.5,
        MIGHTY_ANCHOR_SPEED = 2,
        MIGHTY_SAIL_BOOST_STRENGTH = 18,

		DEFAULT_SAIL_BOOST_STRENGTH = 10,

		MIGHTY_HEAVY_SPEED_MULT_BONUS = 0.45, -- DEPRECATED

        WOLFGANG_SANITY_DRAIN = 1.1,
        WOLFGANG_SANITY_NIGHT_DRAIN = 1.25,
        WOLFGANG_SANITY_NIGHT_DRAIN_SMALL = 1.1,
        WOLFGANG_SANITY_RANGE = 16,
        WOLFGANG_SANITY_PER_MONSTER = 1/13,

        BELL_SUCCESS_MIN_2 = nil, -- no perfect here
        BELL_SUCCESS_MAX_2 = nil, -- no perfect here
        BELL_MID_SUCCESS_MIN_2 = 0.37,
        BELL_MID_SUCCESS_MAX_2 = 0.63,

        BELL_SUCCESS_MIN_3 = nil, -- no perfect here
        BELL_SUCCESS_MAX_3 = nil, -- no perfect here
        BELL_MID_SUCCESS_MIN_3 = 0.25,
        BELL_MID_SUCCESS_MAX_3 = 0.75,

        BELL_PERFECT_LEVEL_STARTING = 4, -- We can start getting perfects here.

        BELL_SUCCESS_MIN_4 = 0.45,
        BELL_SUCCESS_MAX_4 = 0.60,
        BELL_MID_SUCCESS_MIN_4 = 0.12,
        BELL_MID_SUCCESS_MAX_4 = 0.90,

        BELL_SUCCESS_MIN_5 = 0.33,
        BELL_SUCCESS_MAX_5 = 0.69,
        BELL_MID_SUCCESS_MIN_5 = 0.14,
        BELL_MID_SUCCESS_MAX_5 = 0.87,

        BELL_SUCCESS_MIN_6 = 0.24,
        BELL_SUCCESS_MAX_6 = 0.78,
        BELL_MID_SUCCESS_MIN_6 = 0.12,
        BELL_MID_SUCCESS_MAX_6 = 0.88,

        BELL_SUCCESS_MIN_7 = 0.44,
        BELL_SUCCESS_MAX_7 = 0.57,
        BELL_MID_SUCCESS_MIN_7 = 0.12,
        BELL_MID_SUCCESS_MAX_7 = 0.86,

        BELL_SUCCESS_MIN_8 = 0.37,
        BELL_SUCCESS_MAX_8 = 0.66,
        BELL_MID_SUCCESS_MIN_8 = 0.14,
        BELL_MID_SUCCESS_MAX_8 = 0.90,

        MIGHTYGYM_WORKOUT_HUNGER = {
            LOW = 4,
            MED = 11,
            HIGH = 22,
        },

        GYM_RATE = {
--【★ MIGHTINESS（神力）成长表】6559-6568 行。
--  英文原注释（第 6560 行）：'rate in number of hits to reach 100 mightiness'
--    ★★ 关键信息：**神力值上限是 100**，参数单位是「打到 100 需要几下」。
--  GYM_RATE = { LOW = 100/25, MED = 100/15, ... }
--    ★★ 再次使用 100/N 的归一化写法，但语义不同：
--      分子 100 = 神力上限（常量），分母 25/15 = 所需命中数。
--      ⇒ 数值越小，升级越快。三档难度对应 25 / 15 / 更少的命中。
--    ★★ 这里 100 是「神力满值」而非「一天点数」，
--      所以它与第 2196 行 100/(seg_time*32) 的 100 含义不同 ——
--      ★ **同一个数字 100 在本文件里至少有三种含义**，
--        必须结合分母判断，读表时切勿想当然。
--  ⚠方向性提醒：GYM_RATE 的值越小越强，与本文件绝大多数
--    「数值越大越强」的参数相反。调平衡时方向搞反会得到相反效果。
            -- rate in number of hits to reach 100 mightiness
            LOW = 100/25,
            MED = 100/15,
            HIGH = 100/10,
        },

        RUINS_CAVEIN_OBSTACLE_FALL_DAMAGE = 40,

        -- WX78 Refresh
        WX78_MAXELECTRICCHARGE = 6, -- Deprecated, use WX78_INITIAL_MAXCHARGELEVEL
        WX78_MINACCEPTABLEMOISTURE = 15,
        WX78_HUNGRYCHARGEDRAIN_TICKTIME = 300 * FRAMES,
        WX78_CHARGE_REGENTIME = 3*seg_time,
        WX78_FROZEN_CHARGELOSS = 2,
        WX78_MODULE_USES = 4,

        WX78_RAIN_HURT_RATE = 1,            -- DEPRECATED
        WX78_MAX_MOISTURE_DAMAGE = -.5,     -- DEPRECATED
        WX78_MOISTURE_DRYING_DAMAGE = -.3,  -- DEPRECATED

        WX78_MOISTUREUPDATERATE = 30, -- Frames count
        WX78_MOISTURESTEPTRIGGER = 5, -- How many updates there are before a discharge
        WX78_MIN_MOISTURE_DAMAGE = -0.60,     -- Damage per second
        WX78_PERCENT_MOISTURE_DAMAGE = -1.2,

        WX78_MAXHEALTH_BOOST = 40,

        WX78_MAXSANITY1_BOOST = 40,

        WX78_MAXSANITY_BOOST = 100,
        WX78_MAXSANITY_DAPPERNESS = 100/(day_time*10),

        WX78_MAXHUNGER1_BOOST = 40,

        WX78_MAXHUNGER_BOOST = 100,
        WX78_MAXHUNGER_SLOWPERCENT = 0.80,

        WX78_MOVESPEED_CHIPBOOSTS = {0.00, 0.25, 0.40, 0.50}, -- Set so that speed circuits give diminishing returns.

        WX78_HEATERTEMPPERMODULE = 25,
--【★★ 韦斯 WX78 电路板系统 —— 可插拔设计的范本】6600-6680 行。
--  WX78_MINTEMPCHANGEPERMODULE = 20（第 6600 行）：
--    ★★ 每块电路板模块的最小温度变化量 = 20 度。
--    ★★★ 韦斯的核心玩法从这里开始：★★★
--      韦斯用「热量」而非「燃料」：按模块数量消耗温度。
--      WX78_MINTEMPCHANGEPERMODULE=20 表示「插一块板，就得多扛 20 度」。
--    ★★ 这是「插拔式成长」的精妙之处：
--      模块越多 → 功能越强，但**每块都要付温度代价**。
--      ⇒ 玩家在「插几块板」之间持续做取舍，而不是无脑插满。
--      这个取舍正是韦斯角色设计的核心。
--  WX78_COLD_ICEMOISTURE（第 6619 行附近）：低温时的结霜惩罚。
--    ★★ 温度低于阈值就结霜 ⇒ 低温环境对韦斯是双重压力
--      （既要供暖防冻，又要付供暖的模块代价）。
        WX78_MINTEMPCHANGEPERMODULE = 20,
--【★ 分区 28 · 韦斯 WX78 与海盗】6600-6796 行
--  ★★ 韦斯的参数是全文件最分散的，横跨四个区间
--    （140 / 6410-6660 / 7300-7600 / 9200-9450）。
--    因为「电路板」是可插拔子系统，被设计成独立模块后分散追加。
--    ⇒ **本分区不能用行号定位韦斯的全部参数，必须按名搜索。**

        WX78_COLD_ICEMOISTURE = 94, -- Kind of 95; the moisture badge presentation makes this work better.
        WX78_COLD_ICECOUNT = 2,

        WX78_PERISH_COLDRATE = 0.75, -- Deprecated for WX78_PERISH_RATE_MODULELEAN.
        WX78_PERISH_HOTRATE = 1.25, -- Deprecated for WX78_PERISH_RATE_MODULELEAN.

        WX78_PERISH_RATE_MODULELEAN = 0.25,

        WX78_TASERDAMAGE = 20, -- This causes a chain stun to nearby targets when the primary target is damaged.

        WX78_LIGHT_BASERADIUS = 3.5, -- Deprecated.
        WX78_LIGHT_EXTRARADIUS = 1.5, -- Deprecated.

        -- Depracated ranges, these were used inconsistently together...
        WX78_MUSIC_TENDRANGE = 12,
        WX78_MUSIC_AURADSQ = 256,
        WX78_MUSIC_UPDATERATE = 144*FRAMES,
--【★ 韦斯音乐（音乐仪）数值】6619-6622 行。
--  WX78_MUSIC_DAPPERNESS = 100/(day_time*4.5)
--  WX78_MUSIC_SANITYAURA = 100/(day_time*4.5)
--    ★★ 又是 100/(day_time*N) 归一化，与第 2204 行 DAPPERNESS 组同口径。
--    ★★ 数值验算：100/(300*4.5) = 0.0741/秒 × 480 = **35.5 点/昼夜**。
--      与第 7270 行英文注释 '35.5 per day (Level 1)' 完美吻合 ✓
--    ⇒ 证实「per day」在本文件里一律指**完整昼夜 480 秒**。
--    ★★ 注意两者数值相同（一个掉仪态、一个回理智）：
--      放音乐是「以仪态换理智」的等价交换，是韦斯的核心循环。
        WX78_MUSIC_DAPPERNESS = 100/(day_time*4.5),
        WX78_MUSIC_SANITYAURA = 100/(day_time*4.5),

        WX78_BEE_TICKPERIOD = seg_time,
        WX78_BEE_HEALTHPERTICK = 5.0,

        WX78_MAXHEALTH2_MULT = 2.5, -- A multiplier on WX78_MAXHEALTH_BOOST

        WX78_CHARGING_FOODS = { -- Deprecated. Set edible.chargevalue instead.
            voltgoatjelly = 1,
            voltgoatjelly_spice_chili = 1,
            voltgoatjelly_spice_garlic = 1,
            voltgoatjelly_spice_sugar = 1,
            voltgoatjelly_spice_salt = 1,
            goatmilk = 1,
        },

        WX78_SCANNER_SCANPERIOD = 10,
        WX78_SCANNER_MODULETARGETSCANTIME = 10,
        WX78_SCANNER_MODULETARGETSCANTIME_EPIC = 20,

        WX78_SCANNER_DISTANCES =
        {
            {maxdist=10, describe="hot", pingtime=1},
            {maxdist=15, describe="warmer", pingtime=2},
        },
        WX78_SCANNER_SCANDIST = 4.0,

        WX78_SCANNER_RANGE = 7,
        WX78_SCANNER_PLAYER_PROX = 7,

        WX78_SCANNER_TIMEOUT = total_day_time,

        -- Wurt QoL/AI
        -- Default fallbacks for follower brain AI distances.
        FOLLOWER_HELP_LEADERDIST = 18,
        FOLLOWER_HELP_FINDDIST = 6,

        -- Pirates!
        MONKEYISLANDGEN_DOCKAMOUNT = 14,
        MONKEYISLANDGEN_DOCKMINLENGTH = 8,
        MONKEYISLANDGEN_DOCKMAXLENGTH = 14,
        MONKEYISLANDGEN_CANNONCHANCE = 0.75,
        MONKEYISLANDDOCK_HEALTH = 300,

        MONKEYHUT_REGEN_TIME = total_day_time * 3,
        MONKEYHUT_RELEASE_TIME = 10,
        MONKEYHUT_MONKEYS = 1,
        MONKEYHUT_EMERGENCY_MONKEYS = 1,
        MONKEYHUT_EMERGENCY_RADIUS = 10,
        MONKEYHUT_WORKS = 5,
        MONKEYHUT_ENABLED = true,

        MONKEYISLAND_PORTAL_SPEWTIME = 15.0,
        MONKEYISLAND_PORTAL_ENABLED = true,
        MONKEYISLAND_PORTAL_MAXLOOT = 10,
        MONKEYISLAND_PORTAL_LOOTMAXDST = 80,
        MONKEYISLAND_PORTAL_BANANABUSHWEIGHT = 5.0,
        MONKEYISLAND_PORTAL_LIGHTCRABWEIGHT = 2.0,
        MONKEYISLAND_PORTAL_MONKEYTAILWEIGHT = 5.0,
        MONKEYISLAND_PORTAL_PALMCONE_SEEDWEIGHT = 5.0,
        MONKEYISLAND_PORTAL_POWDERMONKEYWEIGHT = 1.0,

        PRIME_MATE_HEALTH = 350,
        PRIME_MATE_ATTACK_PERIOD = 1,
        PRIME_MATE_DAMAGE = 60,
        POWDER_MONKEY_HEALTH = 200,
        POWDER_MONKEY_DAMAGE = 20,

        POWDER_MONKEY_TERRITORY_TINTED_SEASTACK_RADIUS_SQ = 350 * 350,
        POWDER_MONKEY_TERRITORY_TINTED_SEASTACK_CHANCE = { min = 0.04, max = 0.1 },

        CUTLESS_DAMAGE = wilson_attack*.8,
        CUTLESS_USES = 150,

        PIRATE_SPAWN_MAX = 1,
--★ 保留的旧写法注释（第 6695 行）：
--    --  PIRATE_SPAWN_DELAY = {min=day_time/2, max=20*day_time}, --{min=30, max=180},
--  ★★★ 这是**归一化 vs 绝对值**的教科书级对照，一行之内写了两遍：★★★
--    左边（现行，归一化）：{min=day_time/2, max=20*day_time}
--        = {min=150, max=9600} 秒 —— 改时钟自动跟随。
--    右边（废弃，绝对值）：{min=30, max=180}
--        = 固定秒数 —— 改时钟后**不会跟随**，会失衡。
--  ★★ 作者把归一化版与绝对值版并排写出来，恰好证明了迁移动机：
--    早期用绝对值（30/180 秒），后来改归一化以支持改时钟。
--  ★ 这也是本文件里最直观的「历史演化痕迹」范例，
--    读懂了这一行，就理解了归一化写法的全部动机。
--★ 另注意本行同时有 Pirate 延迟的 MIN/MAX 区间写法，见 780 行的同类说明。
      --  PIRATE_SPAWN_DELAY = {min=day_time/2, max=20*day_time}, --{min=30, max=180},
        PIRATE_SPAWN_DELAY = {min=20, max=30}, --{min=30, max=180},
		PIRATE_STASH_INV_SIZE = 30,

        CREWMEMBER_TARGET_DSQ = 100, -- 10 * 10
--【★ 海盗（Pirates）】6700-6796 行。
--  第 6652-6655 行有注释 'Wurt QoL/AI ... Default fallbacks for follower
--   brain AI distances'。
--  ★★ 「跟随者 AI 距离」是给宠物/同伴用的追踪距离兜底值。
--    ★ 这类参数不影响玩家，是给 AI 行为兜底的，
--      但缺了它们 AI 会「跟丢」或「贴脸」，所以仍放在 TUNING 里。
--  BOATCREW_LOOT_PER_MEMBER = 3（第 6700 行）：
--    ★ 每名船员分到的战利品数量 —— 联机人数越多分得越少。
--    ⇒ 隐含的「人数惩罚」：开黑会稀释收益。
        BOATCREW_LOOT_PER_MEMBER = 3,

        MONKEY_WALK_SPEED_PENALTY = -0.5,

        PALMCONETREE_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 3,
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30,
        },

        PALMCONETREE_GROWTH_TIME =
        {
            {base=1.5*day_time, random=0.5*day_time},   --short
            {base=5*day_time, random=2*day_time},       --normal
            {base=5*day_time, random=2*day_time},       --tall
        },

        PALMCONETREE_REGROWTH_TIME_MULT = 1,

        PALMCONETREE_CHOPS_SMALL = 5,
        PALMCONETREE_CHOPS_NORMAL = 10,
        PALMCONETREE_CHOPS_TALL = 15,

		MONKEYTAIL_CYCLES = 4,
		MONKEYTAIL_CYCLES_VAR = 3,

        BANANABUSH_CYCLES = 4,
        BANANABUSH_CYCLES_VAR = 3,

        LIGHTCRAB_WALK_SPEED = 1,
        LIGHTCRAB_RUN_SPEED = 6.1,
		LIGHTCRAB_HEALTH = 25 * multiplayer_attack_modifier,
        LIGHTCRAB_PERISH_TIME = total_day_time * 5,

        MONKEY_MEDIUM_HAT_PERISHTIME = total_day_time*6,
        POLLY_ROGERS_HAT_PERISHTIME = total_day_time*6,

        MASTER_CREWMAN_MULT =
        {
            ANCHOR_RAISE_SPEED = 2,
            RUDDER_TURN_SPEED = 1.5,
            OAR_CONSUMPTION = 0.5,
            LOWER_SAILT_BOOST = 2,
        },

        BOAT_HEALTH_BUFFER_MULT =
        {
            degradedamage = 2,
            collide = 0.5,
        },

        POLLY_ROGERS_WALK_SPEED= 7,
        POLLY_ROGERS_RUN_SPEED= 10,
        POLLY_ROGERS_MAX_HEALTH= 50,
        POLLY_ROGERS_SPAWN_TIME = total_day_time * 1,
        POLLY_ROGERS_RANGE = 15,

        PIRATESPAWNER_BASEPIRATECHANCE = 5*day_time,
        PIRATESPAWNER = {
            INNER = {
                MAX = 300,
                CHANCE = 0.2,
                WEIGHT = 6,
            },
            MID = {
                MAX = 600,
                CHANCE = 0.1,
                WEIGHT = 2,
            },
            OUTTER = {
                MAX = 800,
                CHANCE = 0.1,
                WEIGHT = 1,
            },
        },
        PIRATE_RAIDS_CHANCE_MODIFIER = 1,
        PIRATE_RAIDS_ENABLED = true,

        MONKEY_QUEEN_GRACE_TIME = total_day_time/2,

        CANNONBALL_RADIUS = 0.5,
        CANNONBALL_DAMAGE = 200,
        CANNONBALL_SPLASH_RADIUS = 3,
        CANNONBALL_SPLASH_DAMAGE_PERCENT = 0.6, -- Calculateed as a percent of CANNONBALL_DAMAGE
        CANNONBALL_PASS_THROUGH_TIME_BUFFER = 1,

        MONKEY_CURSE_LEVEL_1 = 0,
        MONKEY_CURSE_LEVEL_2 = 2,
        MONKEY_CURSE_LEVEL_3 = 5,

        MONKEY_TOKEN_COUNTS = {
            LEVEL_1 = 0,
            LEVEL_2 = 2,
            LEVEL_3 = 5,
            LEVEL_4 = 10,
        },

--【★ 分区 29 · 书站与各角色专属（威克巴顿 / 羔羊教团 / 兔年）】6797-7005 行
--  ★ 分区边界：角色专属区块继续追加。
--  BOOKSTATION_BONUS_RANGE = 12（第 6800 行）：书站加成半径。
--    ★「书站」是威克巴顿的核心建筑，加成范围以格计。
        -- WICKERBOTTOM
        BOOKSTATION_RESTORE_TIME = seg_time,
        BOOKSTATION_RESTORE_AMOUNT = 0.01,
        BOOKSTATION_BONUS_RANGE = 12,
        BOOKSTATION_WICKER_BONUS = 2,

        BOOK_FIRE_RADIUS = 16,
        FIREPEN_MAXUSES = 10,

        BOOK_RESEARCH_STATION_RADIUS = 16,

        BOOK_TEMPERATURE_RADIUS = 16,
        BOOK_TEMPERATURE_AMOUNT = 35,

        BOOK_BEES_AMOUNT = 2,
        BOOK_BEES_MAX_ATTACK_RANGE = 5,
        BOOK_BEES_MAX_TIME_TO_LINGER = 5 * 60, -- 5 minutes!
        BOOK_MAX_GRUMBLE_BEES = 16,

        BOOK_FISH_AMOUNT = 3,

        BOOK_GARDENING_UPGRADED_MAX_TARGETS = 15,

        BOOK_WEB_GROUND_DURATION = total_day_time/4,
        BOOK_WEB_GROUND_RADIUS = 6,
        BOOK_WEB_GROUND_SPEED_PENALTY = 0.25,

        BOOK_USES_SMALL = 3,
        BOOK_USES_LARGE = 5,

        MAXWELL_READING_SANITY_MULT = 2.5,

        BOOK_MAX_SHADOWCREATURES = 16,

        FENCE_DEFAULT_ROTATION = 45,

        HEALTH_PENALTY_ENABLED = true,
        NONLETHAL_TEMPERATURE = false,
        NONLETHAL_HUNGER = false,
        NONLETHAL_DARKNESS = false,
        NONLETHAL_PERCENT = 0.2,

        AUTOTERRAFORMER_REPEAT_DELAY = 0.25,
        ANTLIONHAT_USES = 400,
        NIGHTMAREFUEL_FINITEUSESREPAIRVALUE = 50,

		-- Cult of the Lamb
        COTL_TABERNACLE_1 = {
			RAIN_RATE = 2,
			FUEL_SECTIONS = 1,
			FUEL_MAX = total_day_time*0.25,
			BONUS_MULT = 1,
		},

        COTL_TABERNACLE_2 = {
			RAIN_RATE = 2,
			FUEL_SECTIONS = 2,
			FUEL_MAX = total_day_time*0.5,
			BONUS_MULT = 1,
		},

        COTL_TABERNACLE_3 = {
			RAIN_RATE = 2,
			FUEL_SECTIONS = 3,
			FUEL_MAX = total_day_time,
			BONUS_MULT = 1,
		},

        -- Setting the Stage
        STAGEUSHER_ATTACK_PERIOD = 8,
        STAGEUSHER_ATTACK_DAMAGE = 80,
        STAGEUSHER_ATTACK_RANGE = 12,
        STAGEUSHER_ATTACK_SPEED = 6.0,
        STAGEUSHER_ATTACK_STEPS = 6,
        STAGEUSHER_ATTACK_STEPTIME = 25*FRAMES,
        STAGEUSHER_ATTACK_DAMAGERADIUS = 2.0,
        STAGEUSHER_GIVEUP_HEALTH = 86*wilson_attack,
		STAGEUSHER_GIVEUP_TIME = 10,

        CHARLIE_STAGE_RESET_TIME = total_day_time*3,
        CHARLIE_STAGE_RESET_TIME_VARIABLE = total_day_time*3,
        CHARLIE_STAGE_MUSIC_RANGE = 15,

        STATUEHARP_HEDGESPAWNER_RESET_TIME = total_day_time,

        SLURPER_MANNEQUINTIME = 7.5,

        -- Year of the Bunny
        SLEEPOVER_BUNNY_COUNT = 9,

        GOODSLEEP_SANITY = 1.3,

        BUNNY_RING_MINIGAME_ARENA_RADIUS = 8,
        BUNNY_RING_CAMERA_FOCUS_MIN = 8,
        BUNNY_RING_CAMERA_FOCUS_MAX = 8,

        PILLOWFIGHT_PRIZE_CAP = 10,

        PILLOW_DAMAGE = 0,
        PILLOW_HIT_RANGE = 2.5,

		--
        SPAWN_DAYWALKER = true,
--【★ 日行者（Daywalker）★ 第 6950 行 DAYWALKER2_CANNON_FAR_DAMAGE_MULT = 0.5】
--  ★ 远距离伤害减半 —— 惩罚站桩输出。
--    ★★ 命名规律：_FAR_ 表示远距离，_MULT 表示倍率。
--      配合 _NEAR_ 系列构成「距离衰减」机制。
		DAYWALKER_PILLAR_MINE = 10,
        DAYWALKER_RESPAWN_DAYS_COUNT = 10, -- Days after the last defeat.

		DAYWALKER_HEALTH = 10000,
		DAYWALKER_HEALTH_REGEN = 25, --per second (only when not in combat)
		DAYWALKER_COMBAT_STALKING_HEALTH_REGEN = 10,
		DAYWALKER_COMBAT_TIRED_HEALTH_REGEN = 20,
		DAYWALKER_COMBAT_HEALTH_REGEN_PERIOD = 0.4,
		DAYWALKER_WALKSPEED = 2.7,
		DAYWALKER_RUNSPEED = 9,
		DAYWALKER_HIT_RECOVERY = 1,
		DAYWALKER_STALK_HIT_RECOVERY = 1.5,
		DAYWALKER_DODGE_HIT_RECOVERY = 2,
		DAYWALKER_ATTACK_PERIOD = { min = 4, max = 6 },
		DAYWALKER_ATTACK_RANGE = 6,
		DAYWALKER_DAMAGE = 75,
		DAYWALKER_STRUGGLE_DAMAGE = 25,
		DAYWALKER_POUNCE_DAMAGE = 50,
		DAYWALKER_XCLAW_DAMAGE = 2 * 75,
		DAYWALKER_SLAM_DAMAGE = 3 * 75,
		DAYWALKER_SLAM_SINKHOLERADIUS = 3,

		DAYWALKER_ROAR_CD = 30,
		DAYWALKER_STALK_CD = 20,

		DAYWALKER_FATIGUE =
		{
			POUNCE_HIT = -1.5,
			POUNCE_MISS = 1,
			SLAM_HIT = -1.5,
		},
		DAYWALKER_FATIGUE_TIRED = 3,
		DAYWALKER_FATIGUE_TIRED_MIN_TIME = 5,
		DAYWALKER_FATIGUE_TIRED_MAX_TIME = 10,
		DAYWALKER_FATIGUE_REGEN = 1,
		DAYWALKER_FATIGUE_REGEN_START_PERIOD = 20,
		DAYWALKER_FATIGUE_REGEN_PERIOD = 10,

		DAYWALKER_AGGRO_DIST = 15,
		DAYWALKER_KEEP_AGGRO_DIST = 12,
		DAYWALKER_DEAGGRO_DIST = 30,
		DAYWALKER_EPICSCARE_RANGE = 10,

		DAYWALKER2_ATTACK_PERIOD = { min = 3, max = 4 },
		DAYWALKER2_ATTACK_RANGE = 3,
		DAYWALKER2_ATTACK_SWING_DAMAGE = 125,
		DAYWALKER2_TACKLE_DAMAGE = 100,
		DAYWALKER2_TACKLE_RANGE = 8,
		DAYWALKER2_TACKLE_SPEED = 13.5,
		DAYWALKER2_CANNON_NEAR_DAMAGE_MULT = 2, --mult for ALTERGUARDIAN_PHASE3_LASERDAMAGE
		DAYWALKER2_CANNON_FAR_DAMAGE_MULT = 0.5,
		DAYWALKER2_CANNON_ATTACK_RANGE = 5,
		DAYWALKER2_DAMAGE_TAKEN_MULT = 0.8, --basically his armor

		DAYWALKER2_ITEM_USES = 3,
		DAYWALKER2_MULTIWIELD_CD = 16,

		DAYWALKER2_DEAGGRO_DIST_FROM_JUNK = 24,

		SHADOW_LEECH_RUNSPEED = 6,
		SHADOW_LEECH_HEALTH = 100,

		SHARKBOI_HEALTH = 8000,
		SHARKBOI_WALKSPEED = 2.3,
		SHARKBOI_RUNSPEED = 8,
		SHARKBOI_FINSPEED = 6,
		SHARKBOI_DAMAGE = 75,
		SHARKBOI_ATTACK_PERIOD = 3,
		SHARKBOI_MELEE_RANGE = 4.5,
		SHARKBOI_ATTACK_RANGE = 8,
		SHARKBOI_TORPEDO_CD = 20,
		SHARKBOI_STANDING_DIVE_CD = 24,

		SHARKBOI_WATER_WALKSPEED = 2,
		SHARKBOI_WATER_RUNSPEED = 7,

		SHARKBOI_AGGRO_DIST = 15,
		SHARKBOI_KEEP_AGGRO_DIST = 12,
		SHARKBOI_DEAGGRO_DIST = 24,

		SHARKBOI_ICE_MINE = 4/3,
		SHARKBOI_ICE_LARGE_MINE = 8/3,

        SPAWN_SHARKBOI = true,
        SHARKBOI_ARENA_COOLDOWN_DAYS = 20 * total_day_time,
        SHARKBOI_ARENA_SHRINK_TICK_TIME = 2,
        SHARKBOI_ARENA_SHRINK_DISTANCE = 0.1,

        SHARKBOI_ROCK_ICE_GROW_TIME = 10 * total_day_time,
        SHARKBOI_ROCK_ICE_MELT_TIME = 30,

        ICEFISHING_HOLE_ODDS_TO_HOOK_FISH = 0.2,
        ICEFISHING_HOLE_TIME_PER_HOOK_CHANCE = 1,
        ICEFISHING_HOLE_FISH_NEEDED_TO_SPAWN = 3,
        ICEFISHING_HOLE_PUNT_DETECT_RADIUS = 5,
        ICEFISHING_HOLE_PUNT_PUSH_RADIUS = 2,

        OCEANWHIRLPORTAL_KEEPALIVE_DURATION = 0.5 * total_day_time,
        OCEANWHIRLPORTAL_BOAT_INTERACT_DISTANCE = 4,
        OCEANWHIRLPORTAL_ADD_WETNESS = 20,
        OCEANWHIRLPORTAL_ADD_COLDNESS = 1,
        OCEANWHIRLPORTAL_TEMP_REDUCTION = 5,
        OCEANWHIRLPORTAL_EXTINGUISH_HEAT_PERCENT = -4,
        OCEANWHIRLPORTAL_PROTECTION_TIME = 60,
        OCEANWHIRLPORTAL_BOAT_PUSH_FORCE = 3,

--★★★ 【★★ 分区 30 · ★★★ SKILLS 技能树子表 ★★★】7006-7360 行 ★★★
--
--  ★★ 这是本文件**唯一的大型嵌套子表**，结构上与前 7000 行截然不同：
--    7000 行之前是 TUNING.SOMETHING = 数字（扁平结构），
--    SKILLS 之后是 TUNING.SKILLS.角色名.技能名_序号 = 数字（三层嵌套）。
--
--  英文原注释（第 7006 行）：'-- WILSON REFRESH wilson_refresh'
--    ★★ 「WILSON REFRESH」= 威尔逊大改版（2022 年技能树更新）。
--      这次改版给每个角色加了「技能树」，于是所有角色的技能数值
--      被**集中收集到这张表里**，而不再是散落各处。
--      ⇒ 这是本文件组织方式的一次重要演进：
--        旧数值散落 → 新数值集中成表。
--        调平衡时找角色技能参数，应优先看这张表。
--
--  ★★ 技能命名的固定范式（务必掌握）：
--    <角色>_<技能族>_<等级序号>，例如
--      WILSON_TORCH_1 / WILSON_TORCH_2 / WILSON_TORCH_3 / WILSON_TORCH_4
--    ⇒ 同一技能按 1/2/3/4 分4 级递进。
--    ★★ 这与 TOADSTOOL 的 _LVL 数组（2430 行）风格不同：
--      技能用「独立键 + 序号后缀」，蘑菇人用「数组索引」。
--      ⇒ **本文件两套风格并存**，调平衡前先看清是哪一种。
--★ 参见 components/skilltree.lua。
        -- WILSON REFRESH wilson_refresh
        SKILL_THRESHOLDS = {
            3,-- 5, --1
            3,-- 8, --2
            4,-- 8, --3
            4,-- 8, --4
            4, --10, --5
            5, --10, --6
            5, --10, --7
            5, --10, --8
            5, --10, --9
            5, --12, --10
            5, --12, --11
            5, -- 12, --12
            5, --15, --13
            5, -- 15, --14
            5, -- 15, --15
        },
--【★★★ 一处「故意保留废弃常量」的完整说明 —— 本文件兼容策略的范本】★★
--  第 7024-7026 行的英文注释与两个键名合起来，构成教科书级示范：
--      -- FIXME(JBK): These are here because SKILL_THRESHOLDS has decreased
--       but we do not want to clamp experience until out of beta.
--      -- We also need the client to know the new value for UI.
--      FIXME_DO_NOT_USE_FOR_MODS_OLD_MAX_XP_VALUE = 160,
--      FIXME_DO_NOT_USE_FOR_MODS_NEW_MAX_XP_VALUE = 68,
--
--  ★★★ 三层信息，缺一不可：★★★
--  (1) **为什么保留**：SKILL_THRESHOLDS 已下调（160 → 68），
--      但在脱离 beta 之前**不想强制截断玩家经验值**。
--      ⇒ 保留新旧两个值，是为了让测试期的经验不被卡住。
--  (2) **客户端需求**：「客户端也需要知道新值来渲染 UI」。
--      ⇒ 服务端与客户端必须对同一常量达成一致，否则 UI 会错乱。
--  (3) **★ 键名自带警告**：
--      FIXME_DO_NOT_USE_FOR_MODS_OLD_MAX_XP_VALUE
--      FIXME_DO_NOT_USE_FOR_MODS_NEW_MAX_XP_VALUE
--      ⇒ 模组作者看到键名就知道「这两个别用」，无需翻注释。
--
--  ★★★ 这是本文件命名规范的巅峰：把「不要用我」写进标识符本身。★★★
--    对比本文件大量 DEPRECATED 键（第 2768-2786、4381 行），
--    它们只靠注释标注；而此处直接写进名字，安全性高出一个层级。
--    ⇒ **给废弃常量取名的最佳实践，值得记住。**
--  ★★ 也说明「双值并存」是本文件的常规手法，不是重复缺陷。
--    但它与第 4331 行那种无理由的历史残留不同，此处有充分注释。
        -- FIXME(JBK): These are here because SKILL_THRESHOLDS has decreased but we do not want to clamp experience until out of beta.
        -- We also need the client to know the new value for UI.
        FIXME_DO_NOT_USE_FOR_MODS_OLD_MAX_XP_VALUE = 160,
        FIXME_DO_NOT_USE_FOR_MODS_NEW_MAX_XP_VALUE = 68,

        TORCH_RADIUS = {
            2,
            3,
            4,
            5,
        },

        TORCH_FALLOFF = {
            0.5,
            0.6,
            0.75,
            0.9,
        },

        SKILLS = {
--【★★ 威尔逊技能：火把 Torch】7044-7078 行。
--  ★★ 这一组每 3-5 行就有一条英文注释，且都解释了「为什么」：
--    -- Torch fuel consumption multiplier.（火把燃料消耗乘数）
--    -- Torch light radius.（火把光照半径）
--    -- Beard insulation multiplier.（胡子保暖乘数）
--    -- Beard growth modifiers as a stepped rate increase.
--    -- Shadow allegiance.（影子阵营）
--    -- Weremeter drain rate multiplier.（狼人表衰减率乘数）
--    -- Pick animation lenght (in seconds).
--  ★★★ 这是本文件注释风格的最高标准，值得作为补注释的范本：★★★
--    每条注释都精确说明「这个键管什么」，而不是复述键名。
--    对比大量无注释的数据行，可见作者只在「需要解释」时才写。
--  ⚠ 注意最后一条 'Pick animation lenght' 有拼写错误（lenght→length），
--    但不影响理解。这类小拼写错误在原文件中较多见。
            -- Torch fuel consumption multiplier.
            WILSON_TORCH_1 = 0.84,
            WILSON_TORCH_2 = 0.68,
            WILSON_TORCH_3 = 0.5,

            -- Torch light radius.
            WILSON_TORCH_4 = 2,
            WILSON_TORCH_5 = 3,
            WILSON_TORCH_6 = 4,

            -- Beard insulation multiplier.
            WILSON_BEARD_1 = 1.2,
            WILSON_BEARD_2 = 1.4,
            WILSON_BEARD_3 = 1.7,

            -- Beard growth modifiers as a stepped rate increase.
            WILSON_BEARD_4 = 0.05, -- 4, 8, 16 -> 3, 7, 15 -> 3 days savings
            WILSON_BEARD_5 = 0.30, -- 4, 8, 16 -> 3, 6, 12 -> 7 days savings
            WILSON_BEARD_6 = 0.55, -- 4, 8, 16 -> 2, 5, 10 -> 11 days savings

            -- Shadow allegiance.
            WILSON_ALLEGIANCE_SHADOW_RESIST = 0.9,
            WILSON_ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
            WILSON_ALLEGIANCE_LUNAR_RESIST = 0.9,
            WILSON_ALLEGIANCE_VS_SHADOW_BONUS = 1.1,

            WOODIE = {
                -- Weremeter drain rate multiplier.
                WEREMETER = {
                    1.2, -- Level 1 (~15% slower)
                    1.4, -- Level 2 (~30% slower)
                    1.8, -- Level 3 (~45% slower)
                },

                -- Pick animation lenght (in seconds).
                QUICKPICK_TIMEOUT = {
                    0.85, -- Level 1
                    0.70, -- Level 2
                    0.55, -- Level 3
                },

                DAMAGE_BONUS_VS_TREEGUARDS = math.sqrt(2), -- sqrt because two skill levels combine to hit 2x damage.

                CURSE_MASTER_MIN_HUNGER = 0.15, -- Percent

                BEAVER_WORK_MULTIPLIER = {
                    MINE = 2.5, -- Level 1
                    CHOP = 1.8, -- Level 2
                },

                MOOSE_HEALTH_REGEN = { -- (0.3 / seg)
                    amount = 1.5,
                    period = 5,
                },

                MOOSE_CANCEL_CHARGE_TIME = 7 * FRAMES,
                MOOSE_RUN_SPEED_BONUS_MULT = 1.11, -- 1.11 * 5.4 ~ 6
                MOOSE_REDUCED_GROGGINESS = 0.15, -- Percent
                MOOSE_PLANAR_DEF = 15,

                MOOSE_SMASH_DAMAGE = wilson_attack * 4,
                MOOSE_SMASH_PLANAR_DAMAGE = 80,

                GOOSE_DODGE_COOLDOWN_TIME = 5,
                GOOSE_RUN_SPEED_BONUS_MULT = 1.19, -- 1.19 * 8.4 ~ 10

                WERESKILL_WERENESS_CONSUMPTION = {
                    BEAVER = -5,
                    GOOSE  = -20,
                },

                ALLEGIANCE_SHADOW_RESIST = 0.9,
                ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
                ALLEGIANCE_LUNAR_RESIST = 0.9,
                ALLEGIANCE_VS_SHADOW_BONUS = 1.1,
            },

            WOLFGANG_MIGHTY_WORK_CHANCE_1 = 0.95,
            WOLFGANG_MIGHTY_WORK_CHANCE_2 = 0.90,
            WOLFGANG_MIGHTY_WORK_CHANCE_3 = 0.85,

            WOLFGANG_DUMBELL_TOSS_1 = 1.5,
            WOLFGANG_DUMBELL_TOSS_2 = 2,

            WOLFGANG_ALLEGIANCE_SHADOW_RESIST_1 = 0.9,
            WOLFGANG_ALLEGIANCE_VS_LUNAR_BONUS_1 = 1.1,
            WOLFGANG_ALLEGIANCE_LUNAR_RESIST_1 = 0.9,
            WOLFGANG_ALLEGIANCE_VS_SHADOW_BONUS_1 = 1.1,

            WOLFGANG_ALLEGIANCE_VS_LUNAR_BONUS_2 = 1.2/1.1,
            WOLFGANG_ALLEGIANCE_VS_SHADOW_BONUS_2 = 1.2/1.1,

            WOLFGANG_ALLEGIANCE_VS_LUNAR_BONUS_3 = 1.3/1.2,
            WOLFGANG_ALLEGIANCE_VS_SHADOW_BONUS_3 = 1.3/1.2,

            WOLFGANG_PLANARDAMAGE_1 = 5,
            WOLFGANG_PLANARDAMAGE_2 = 5,
            WOLFGANG_PLANARDAMAGE_3 = 5,
            WOLFGANG_PLANARDAMAGE_4 = 5,
            WOLFGANG_PLANARDAMAGE_5 = 5,

            WOLFGANG_NORMAL_SPEED = 1.1,

            WOLFGANG_OVERBUFF_1 = 10,
            WOLFGANG_OVERBUFF_2 = 20,
            WOLFGANG_OVERBUFF_3 = 30,
            WOLFGANG_OVERBUFF_4 = 40,
            WOLFGANG_OVERBUFF_5 = 50,

            WILLOW_BERNIEHEALTH_1 = 1.15,
            WILLOW_BERNIEHEALTH_2 = 1.30,

            WILLOW_BERNIESPEED_1 = 1.15,
            WILLOW_BERNIESPEED_2 = 1.30,

            WILLOW_BERNIESANITY_1 = 60/200,
            WILLOW_BERNIESANITY_2 = 100/200,

            WILLOW_BERNIE_HEALTH_REGEN_PERIOD = 1,
            WILLOW_BERNIE_HEALTH_REGEN_1 = 1,
            WILLOW_BERNIE_HEALTH_REGEN_2 = 2,

--【★ 打火机 / 灯笼技能】7166-7180 行。
--  同样每条配英文注释（Lighter fuel consumption multiplier. 等）。
--    ★ 与 7044 行的火把技能形成对照：两个技能的键结构几乎相同，
--      说明技能树是**按同一模板复制**生成的。
            -- Lighter fuel consumption multiplier.
            WILLOW_CONSUMPTION_1 = 0.84,
            WILLOW_CONSUMPTION_2 = 0.68,
            WILLOW_CONSUMPTION_3 = 0.5,

            -- Lighter light radius.
            WILLOW_BRIGHTNESS_1 = 2.5,
            WILLOW_BRIGHTNESS_2 = 4,

            WILLOW_ALLEGIANCE_SHADOW_RESIST = 0.9,
            WILLOW_ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
            WILLOW_ALLEGIANCE_LUNAR_RESIST = 0.9,
            WILLOW_ALLEGIANCE_VS_SHADOW_BONUS = 1.1,

            WATHGRITHR = {
                BATTLESONG_INSTANT_COOLDOWN = 10,
                BATTLESONG_INSTANT_COOLDOWN_HIGH = 2.5 * 60,

                INSTANTSONG_CD_UNLOCK_COUNT = 10,
                BATTLESONGS_CONTAINER_NUM_BATTLESONGS_TO_UNLOCK = 6,

                INSPIRATION_GAIN_MULT = {
                    1.25,
                    1.50,
                },

                WATHGRITHRHAT_DURABILITY_MOD = {
                    0.90,
                    0.80,
                },

                WATHGRITHRHAT_BEEFALO_DOMESTICATION_MOD = 1.15,
                WATHGRITHR_BEEFALO_BUCK_TIME_MOD = 1.3,

                BONUS_PLANAR_DEF = 5,

                HELM_PLANAR_DEF = 8,
                SHIELD_PARRY_DURATION_MULT = 2.5,

                SHIELD_PARRY_BONUS_DAMAGE_SCALE = 0.5,
                SHIELD_PARRY_BONUS_DAMAGE = { min=15, max=30 },
                SHIELD_PARRY_BONUS_DAMAGE_DURATION = 5,

                ALLEGIANCE_SHADOW_RESIST = 0.9,
                ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
                ALLEGIANCE_LUNAR_RESIST = 0.9,
                ALLEGIANCE_VS_SHADOW_BONUS = 1.1,

            },

            WINONA = {
                INSPECTACLES_COOLDOWNTIME = total_day_time * 0.5,
                INSPECTACLES_TICK_TIME = 5, -- NOTES(JBK): Time per client side radio signal wave.
                INSPECTACLES_UPGRADE_CHANCE = 0.25,

                ROSEGLASSES_COOLDOWNTIME = total_day_time * 0.5,
                ROSEGLASSES_UPGRADE_CHANCE = 0.05,
                ROSEGLASSES_UPGRADE_CHANCE_INCREASED = 0.25,

                CHARLIE_VINEBRIDGE_LENGTH_TILES = 3, -- How many tiles in a line can this make for each activation.
                WORMHOLE_DETECTION_RADIUS = 20, -- Units away from a target position for valid action use.
                TELEPAD_DETECTION_RADIUS = 2, -- Units away for an ideal teleport find, setting to the size of the teleporter approximately.

				BATTERY_EFFICIENCY_RATE_MULT =
				{
					1 / (1 + 0.25),	--lasts 25% longer
					1 / (1 + 0.5),	--lasts 50% longer
					1 / (1 + 1.0),	--lasts 100% longer
				},
				CATAPULT_ATTACK_PERIOD_MULT =
				{
					1 / (1 + 0.05),	--5% faster
					1 / (1 + 0.1),	--10% faster
					1 / (1 + 0.2),	--20% faster
				},
				CATAPULT_AOE_RADIUS_MULT =
				{
					1 + 0.25,		--25% bigger
					1 + 0.5,		--50% bigger
					1 + 1.0,		--100% bigger
				},
				CATAPULT_BOOST_MULT = 1 / (1 + 0.5), --50% faster
				CATAPULT_BOOST_DURATION = 20,
				SPOTLIGHT_RADIUS2 = 6.4,
				SPOTLIGHT_MIN_RANGE2 = 7.8,
				SPOTLIGHT_MAX_RANGE2 = 26,
                SPOTLIGHT_HEAT_VALUE = 60, -- NOTES(JBK): less powerful as emberlight from Willow which is 100.

				QUICKCHARGE_MULT = 1 + 1.0, --100% faster
            },

            WURT = {
                MAX_MOISTURE_TEMPERATURE_PENALTY_OFFSET = -20,
                OPTIMAL_TEMPERATURE_DRYING_OFFSET = -1.5, -- New value = 0.5
                MAX_TEMPERATURE_DRYING_OFFSET = -4, -- New value = 1

                MERM_KING_MAX_HUNGER_MULT = {
                    1.25, -- Level 1.
                    1.50, -- Level 2.
                },

                MERM_KING_HUNGER_RATE_MULT = 0.85,

                WETNESS_SANITY_DAPPERNESS = {
--【★★ 韦斯湿度技能 —— 归一化写法的决定性证据】7269-7276 行。
--  WETNESS_SANITY_DAPPERNESS = {
--      100/(day_time*4.5), -- "35.5" per day (Level 1).
--      100/(day_time*3.0), -- "53.3" per day (Level 2).
--  }
--    ★★ 验算（含小数位对照）：
--      100/(300*4.5) = 0.074074/秒 × 480 = **35.555** ✓ 注释写 35.5
--      100/(300*3.0) = 0.111111/秒 × 480 = **53.333** ✓ 注释写 53.3
--    ⇒ 彻底证实：本文件的 "per day" 一律指**完整昼夜 480 秒**，
--      而非白天 300 秒（若按 300 秒算会得到 22.2 与 33.3，明显不符）。
--      ★ 这是全文件关于「per day 口径」最明确的一条证据。
--  同表下一项 WETNESS_MOISTURE_ABSORBTION = { 3.3333, 2.0 }
--    ★★ 注释给出了另一种标注法：'Level 1: Extra health = ~30.'
--      ★★ 这条注释揭示了另一种「意图标注」风格 ——
--        不写表达式结果，而写**玩家能感知的量**（「额外血量约 30 点」）。
--      验算：湿身吸收 3.3333 点/秒 × 湿身持续约 9 秒 ≈ 30 点，
--        与注释吻合。所以 3.3333 是「每秒吸收的湿度削减量」。
--    ★★★ 综合这两行注释，本文件展示了一套完整的注释哲学：★★★
--      左边写「怎么算的」（表达式），右边写「玩家感受到什么」（注释）。
--      两者服务于不同的人，二者并存才能让调平衡既准确又不迷失意图。
                    100/(day_time*4.5), -- "35.5" per day (Level 1).
                    100/(day_time*3.0), -- "53.3" per day (Level 2).
                },

                WETNESS_MOISTURE_ABSORBTION = {
                    3.3333, -- Level 1: Extra health = ~30.
                    2.0,    -- Level 2: Extra health =  50.
                },

                WETNESS_MOISTURE_HEALING = {
                    { amount = 0.5, period = 6.5 }, -- Level 1: "37" a day.
                    { amount = 0.5, period = 4.0 }, -- Level 2: "60" a day.
                },

                ALLEGIANCE_MARSHTILE_MOISTURE_RATE = 0.5,

                ALLEGIANCE_SHADOW_RESIST = 0.9,
                ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
                ALLEGIANCE_LUNAR_RESIST = 0.9,
                ALLEGIANCE_VS_SHADOW_BONUS = 1.1,
            },
            ---
            WENDY = {
                ALLEGIANCE_SHADOW_RESIST = 0.9,
                ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
                ALLEGIANCE_LUNAR_RESIST = 0.9,
                ALLEGIANCE_VS_SHADOW_BONUS = 1.1,

                POTION_DURATION_MOD = 1,

                GHOST_PLANARDEFENSE = 15,

                SISTURN_3_MAX_HEALTH_BOOST = 300,

                MURDER_BUFF_DURATION = 8,
                MURDER_BUFF_MULTIPLIER = 2,
                MURDER_DEFENSE_BUFF = 5,

                LUNARELIXIR_DURATION = 4 * seg_time,
                LUNARELIXIR_DAMAGEBONUS = 10,
                LUNARELIXIR_DAMAGEBONUS_GESTALT = 100,

                SHADOWELIXIR_DURATION = total_day_time,
                ABIGAIL_GESTALT_VEX_DURATION_MULT = 3,
            },
            ---
            WALTER = {
--【★ 技能条目命名清单】7317-7350 行集中列出了大量技能键名注释。
--  如 'walter_slingshot_modding' / 'walter_slingshot_handles' /
--     'wx78_circuitry_betterunplug' / 'wx78_extrabody_1' 等。
--    ★★ 这是技能树的「索引清单」，注释即键名本身。
--      它们的价值在于：一眼看出**每个角色有哪些技能族**，
--      以及技能命名遵循 <角色>_<系统>_<变体> 的三段式约定。
                -- walter_slingshot_modding
                -- walter_slingshot_handles
                -- walter_slingshot_bands
                -- walter_slingshot_frames
                -- walter_ammo_shattershots
                -- walter_ammo_utility
                -- walter_ammo_lucky
                -- walter_ammo_efficiency
                -- walter_ammo_bag
                -- walter_ammo_shadow
                -- walter_ammo_lunar
                -- walter_woby_shadow
				WOBY_BIG_SHADOW_DASH_HUNGER = 4,
                -- walter_woby_lunar
                -- walter_woby_sprint
				WOBY_BIG_SPRINT_SPEED = 12,
				WOBY_BIG_TURBO_SPEED = 13,
				WOBY_BIG_TIME_TO_SPRINT = 3,
				WOBY_BIG_SPRINT_HUNGER_RATE_MOD = 1.5,
                -- walter_woby_dash
				WOBY_BIG_DASH_HUNGER = 2,
                -- walter_woby_endurance
				WOBY_BIG_ENDURANCE_SPEED_BONUS = 1,
				WOBY_ENDURANCE_HUNGER_RATE_MOD = 0.8,
                -- walter_camp_fire
				PORTABLE_FIREPIT_RAIN_RATE = 2,
				PORTABLE_FIREPIT_FUEL_MAX = (night_time + dusk_time) * 1.5,
				PORTABLE_FIREPIT_FUEL_START = 1 / 3, --this one is a pct saved on the crafted item
				PORTABLE_FIREPIT_BONUS_MULT = 2,
                -- walter_camp_rope
                -- walter_camp_wobytreat
                -- walter_camp_wobyholder
                -- walter_camp_wobycourier
--【★ 技能树的通用参数】7350-7360 行。
--  COURIER_DETECTION_RADIUS = 20（第 7350 行附近）：
--  英文注释 'Units away from a target position for valid action use.'
--    ★ 这条注释澄清了 DISTANCE 语义：「到目标点的格数」。
--      而非「到玩家的距离」—— 二者在移动目标上差别很大。
                COURIER_DETECTION_RADIUS = 20, -- Units away from a target position for valid action use.
                COURIER_CHEST_DETECTION_RADIUS = 12, -- Units away from a tile center that Woby will interact with chests from.
                COURIER_FADE_DIST = 20, -- Distance Woby should fade out and fade in from target points.

                HEALERS_EFFECTIVENESS_MODIFIER = 1.5,
                WALTERHAT_IMPROVED_SANITY_DAMAGE_PROTECTION = 0.25,

                PRIORIZE_AMMO_RETURN_ACTION_DIST = 4.5,
                FETCH_PRIORITY_MAX_DISTANCE = 18,
                FETCH_DEFAULT_MAX_DISTANCE = 14,

--【分区 31 · 其他角色技能条目】7361-7604 行
--  ★ 分区边界：SKILLS 表的后半段——沃托克斯、韦斯的技能条目。
--  ★ 注意这一整段仍处于 SKILLS 的嵌套层级内（三层缩进），
--    与第 7605 行之后回到扁平结构形成鲜明对比。
                FORAGER_MAX_DISTANCE = 15,

                WOBY_TASK_AID_HUNGER = .5,

                ALLEGIANCE_SHADOW_RESIST = 0.9,
                ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
                ALLEGIANCE_LUNAR_RESIST = 0.9,
                ALLEGIANCE_VS_SHADOW_BONUS = 1.1,
            },
            ---
            WORTOX = {
--[★ 技能条目索引注释区]7372-7450 行。
--  这一段密集列出了大量技能键名注释（wortox_*、wx78_* 等）。
--    ★★ 它们的价值等同于「技能树的目录」，一眼可见角色能力清单。
--    每个技能名后跟一个 TUNING 值，注释即键名，不另作解释。
--  WORTOX_SOULECHO_SPEEDMULT = 1.2（第 7400 行附近）：
--    ★ MULT = multiplier 倍率。1.2 = 速度提升 20%。
                -- general
                TIPPED_BALANCE_THRESHOLD = 3,
                NICE_SANITY_MULT = 2,
                NAUGHTY_SANITY_MULT = 0.0,
                NAUGHTY_OVERLOAD_STOP_TIME = 10,
                NAUGHTY_SOULHEAL_RECEIVED_MULT = 0.75,
                -- wortox_lifebringer_1
                REVIVE_PERISH_TIME = 10 * total_day_time * perish_warp,
                -- wortox_soulprotector_1
                WORTOX_SOULPROTECTOR_1_RANGE = 3,
                -- wortox_soulprotector_2
                WORTOX_SOULPROTECTOR_2_SPEED = 4,
                WORTOX_SOULPROTECTOR_2_RANGE = 3,
                -- wortox_soulprotector_3
                WORTOX_SOULPROTECTOR_3_MULT = 0.5,
                WORTOX_SOULPROTECTOR_3_DELAY = 3.5,
                -- wortox_soulprotector_4
                WORTOX_SOULPROTECTOR_4_SPEED = 4,
                WORTOX_SOULPROTECTOR_4_DELAY = -1.5,
                WORTOX_SOULPROTECTOR_4_LOSS_PER_PLAYER_MULT = 0.5,
                -- wortox_panflute_playing
                WORTOX_PANFLUTE_INSPIRATION_WAIT = total_day_time, -- How long to wait before being able to get inspired after the last.
                WORTOX_PANFLUTE_INSPIRATION_WAIT_VARIANCE = total_day_time * 0.1,
                -- wortox_panflute_soulcaller
                WORTOX_PANFLUTE_SOULCALLER_SOULCOUNT = 6,
                -- wortox_panflute_forget
                WORTOX_PANFLUTE_FORGET_DURATION = 5, -- How long to keep targets without an aggro target.
                -- wortox_liftedspirits_1
                WORTOX_SOULECHO_SPEEDMULT = 1.2, -- Bonus speed for the duration of Soul Echo.
                -- wortox_liftedspirits_2
                WORTOX_FREEHOP_TIMELIMIT_MULT = 1.5, -- How much to scale the original time limit for the cooldown by.
                -- wortox_liftedspirits_3
                WORTOX_FREEHOP_HOPSPERSOUL_ADD = 1, -- How many additional hops are added for the skill tree perk.
                -- wortox_liftedspirits_4
                -- Scales from TUNING.WORTOX_MAPHOP_DISTANCE_SCALER to TUNING.SKILLS.WORTOX.MAPHOP_DISTANCE_SCALER_MAX linearly as a function of Player:GetSeeableTilePercent().
                MAPHOP_DISTANCE_SCALER_MAX = 1.8, -- 0.9 * 2 = 1.8
                -- wortox_souldecoy_1
                SOULDECOY_TAUNT_RADIUS = 12,
                SOULDECOY_DURATION = 2,
                -- wortox_souldecoy_2
                SOULDECOY_DURATION_BONUS = 3,
                -- wortox_souldecoy_3
                SOULDECOY_EXPLODE_RADIUS = 4,
                SOULDECOY_EXPLODE_DAMAGE = wilson_attack * 1.5,
                SOULDECOY_THORNS_DAMAGE_MULT = 0.5,
                -- wortox_nabbag
                NABBAG_DAMAGE_MIN = wilson_attack * 0.4,
                NABBAG_DAMAGE_MAX = wilson_attack,
                NABBAG_USES = 200,
                NABBAG_USES_AS_BUGNET = 20,
                NABBAG_MAX_USES_PER_NAB_PERCENT = 0.25, -- If the items picked up will exceed this it will stop using more durability for it.
                NABBAG_MAX_ITEMS_PER_NAB = 400, -- Maximum number of items the nab bag will interact with per use to limit server strain.
                NABBAG_CONEANGLE = 150,
                NABBAG_MAX_RADIUS = 3,
                NABBAG_CIRCLE_RADIUS = 1.25,
                -- wortox_souljar_1
                SOULJAR_LEAK_TIME = 30,
                -- wortox_souljar_2
                FILLED_SOULJAR_SOULCAP_INCREASE_PER = 5,
                -- wortox_souljar_3
                SOUL_DAMAGE_NABBAG_BONUS_MULT = 2,
                SOUL_DAMAGE_SOULS_BONUS_MULT = 1.25,
                SOUL_DAMAGE_MAX_SOULS = 100, -- Number of Souls total for the above modifiers.
                -- wortox_thief_1
                SOULEXTRACT_RANGE_BONUS = 10,
                SOULSTEALER_RANGE_BONUS = 4,
                -- wortox_thief_2
                SOUL_PROJECTILE_LIFETIME_BONUS = 2,
                -- wortox_thief_3
                SOUL_SPEAR_DAMAGE = wilson_attack * 0.75,
                SOUL_SPEAR_HIT_COOLDOWN = 0.35,
                -- wortox_thief_4
                SOUL_PROJECTILE_REPEL_DURATION = 0.5,
                -- wortox_allegiance_lunar
                ALLEGIANCE_LUNAR_RESIST = 0.9,
                ALLEGIANCE_VS_SHADOW_BONUS = 1.1,
                -- wortox_allegiance_shadow
                ALLEGIANCE_SHADOW_RESIST = 0.9,
                ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
                VOIDCLOTHSCYTHE_AOE_RANGE = 2.5,
            },

            WX78 = {
--【★ 阵营忠诚度（Allegiance）系统】7455-7556 行。
--  ALLEGIANCE_VS_LUNAR_BONUS = 1.1 / ALLEGIANCE_VS_SHADOW_BONUS 等：
--    ★★ VS_ 前缀 = 「对抗某阵营时」的加成。
--      月亮派打暗影派时获得 1.1 倍加成 —— 阵营选择的实际收益。
--    ★ 设计意图：给玩家「选边站」的明确动机，
--      而非让阵营只是叙事标签。
--  TASER_BUILDUP_GAIN_RATE_MULT_PER_MODULE = 1/3（第 7500 行附近）：
--    ★★ 又是 100/N 型写法：分子 1，分母 3（每模块的累积速率）。
--      0.333/秒/模块，插 3 块即 1.0/秒。线性叠加，规则清晰。
                -- wx78_circuitry_betterunplug
                HALF_MODULE_CONSUMPTION = .5,
                -- wx78_circuitry_bettercharge
                FASTER_CHARGE_MULTIPLIER = 2.5,
                SAVE_CHARGE_ON_UNPLUG = 1,
                -- wx78_circuitry_alphabuffs_1
                MAXHUNGER_SLOWPERCENT_ALPHABUFF = 0.75,
                MAXHUNGER1_SLOWPERCENT_ALPHABUFF = 0.95,
                MAXSANITY1_SANITY_MOD_ALPHABUFF = 0.8,
                MAXSANITY_SANITY_MOD_ALPHABUFF = 0.5,
                -- wx78_circuitry_alphabuffs_2
                MAXHEALTH_ARMOR_ALPHABUFF_2 = 0.025,
                MAXHEALTH2_ARMOR_MULT = 2,
                MAXHUNGER_SLOWPERCENT_ALPHABUFF_2 = 0.70,
                MAXHUNGER1_SLOWPERCENT_ALPHABUFF_2 = 0.90,
                MAXSANITY1_DAPPERNESS_MULT = 0.10,
                MAXSANITY_DAPPERNESS_MULT = 0.30,
                BEE_SHIELD_REGEN_PER_SECOND = 0.25,
                BEE_SHIELDPERCENT = 0.2, -- how much shield dependant on max health.

                -- wx78_circuitry_betabuffs_1
                COLD_FIRE_DAMAGE_SCALE = 0.5, -- 50% per module
                HEAT_FREEZE_RESISTANCE = 2, -- 2x per module resistance to freezing (immune to freezing at 2 fire circuits)
                MUSIC_MAXFOLLOWERS = 10, -- 10 max followers per module

                RADAR_ZAPDRONERANGE = 5,
                RADAR_SCOUTDRONERANGE = 100,
                RADAR_WX78_SCANNER_SCANDIST = .65, -- how close the scanner needs to be
                RADAR_WX78_SCANNER_PLAYER_PROX = .8, -- how close the player needs to be.
                RADAR_WAGPUNKRANGE = 6,
                SHADOWDRONE_HARVESTER_FINDITEM_RADIUS_RADAR = 1,
				RADAR_SHADOWDRONE_DEBUFFER_SCAN_RANGE = 0.15,

                -- wx78_circuitry_betabuffs_2
                TASER_MAXBUILDUP = 100,
                TASER_BUILDUP_GAIN_RATE = 5,
                TASER_BUILDUP_DRAIN_RATE_BASE = -6,
                TASER_BUILDUP_DRAIN_BUFFER_TIME = 4,
                TASER_BUILDUP_DAMAGE = 50, -- Remember that electric damage and wetness mult apply to this.
                TASER_BUILDUP_RADIUS = 2,
                TASER_EFFECT_BASE_TIME = 14,
                TASER_EFFECT_VAR_TIME = 2,
                TASER_EFFECT_DURATION_BASE_TIME = 1.5,
                TASER_EFFECT_DURATION_VAR_TIME = 0.5,

                TASER_BUILDUP_GAIN_RATE_MULT_PER_MODULE = 1/3,
                TASER_BUILDUP_DRAIN_RATE_ADD_PER_MODULE = 1, -- lower base drain rate with each taser module
                TASER_BUILDUP_RADIUS_PER_MODULE = 1,
                -- wx78_circuitry_gammabuffs_1
                -- wx78_circuitry_gammabuffs_2
                -- wx78_extrabody_1
                BACKUPBODY_WORK_REQUIRED = 3,
                -- wx78_extrabody_2
                -- wx78_extrabody_3
                -- wx78_remotebodyswap
                REMOTEBODYSWAP_DETECTION_RADIUS = 20,
				MAPSCOUTSELECT_DETECTION_RADIUS = 10,
                -- wx78_scoutdrone_1
                SCOUTDRONE_MAX_COUNT = 2,
                SCOUTDRONE_SPEED = 3,
                SCOUTDRONE_RANGE = 200,
                -- wx78_extradronerange
                WX78_SCANNER_RANGE_BONUS = 3, -- This is equivalent to 3 radar boosters.
                SCOUTDRONE_RANGE_BONUS = 300,
                ZAPDRONE_RANGE_2 = 30,
                SHADOWDRONE_HARVESTER_FINDITEM_RADIUS_SKILLBOOST = 3, -- 3 radar boosts
				SHADOWDRONE_DEBUFFER_SCAN_RANGE_SKILLBOOST = 0.45, -- 3 radar boosts
                -- wx78_deliverydrone_1
                DELIVERYDRONE_SPEED = 30,
                -- wx78_deliverydrone_2
                -- wx78_zapdrone_1
                ZAPDRONE_SPEED = 7,
				ZAPDRONE_DAMAGE = 30,
				ZAPDRONE_INSULATED_DAMAGE_MULT = 0.5,
				ZAPDRONE_AGGRO_RANGE = 15,
				ZAPDRONE_SHARE_TARGET_RANGE = 20, --share target to possessed bodies if target was within this range to me
				ZAPDRONE_USES = 100,
				ZAPDRONE_USE_PER_ATTACK_1 = 2,
				ZAPDRONE_RANGE_1 = 15,
                -- wx78_zapdrone_2
				ZAPDRONE_USE_PER_ATTACK_2 = 1,

                -- wx78_allegiance_lunar
                ALLEGIANCE_LUNAR_RESIST = 0.9,
                ALLEGIANCE_VS_SHADOW_BONUS = 1.1,
                POSSESSEDBODY_TARGET_DIST = 10,

                POSSESSEDBODY_LUNAR_RESIST = 0.9,
                POSSESSEDBODY_VS_SHADOW_BONUS = 1.1,
                POSSESSEDBODY_NEGATIVE_SANITY_AURA_MODIFIER = 2 / 3,
                POSSESSEDBODY_DAMAGE_MULT = 0.5,
                POSSESSEDBODY_PLANAR_DAMAGE_MULT = 0.5,
                POSSESSEDBODY_PLANAR_SHADOW_DAMAGE_MULT = 0.25,

                PLANARPOSSESSEDBODY_NEGATIVE_SANITY_AURA_MODIFIER = 1 / 3,
                PLANARPOSSESSEDBODY_DAMAGE_MULT = 0.5,
                PLANARPOSSESSEDBODY_PLANAR_DAMAGE_MULT = 1,
                PLANARPOSSESSEDBODY_PLANAR_SHADOW_DAMAGE_MULT = 0.5,

                -- wx78_allegiance_shadow
                ALLEGIANCE_SHADOW_RESIST = 0.9,
                ALLEGIANCE_VS_LUNAR_BONUS = 1.1,
                -- SOCKETQUALITY.LOW == nightmarefuel
                -- drones
                SHADOWDRONE_FOLLOW_RADIUS = 4,
                SHADOWDRONE_HARVESTER_PASSIVE_TICK_PERIOD = 1.5,
                --
                SHADOWDRONE_HARVESTER_LIMIT = 2,
                SHADOWDRONE_HARVESTER_SPEED = 6,
                SHADOWDRONE_HARVESTER_FINDITEM_RADIUS = 6,
                --
                SHADOWDRONE_HARVESTER_SPEED_BOOSTED = 8,
                SHADOWDRONE_HARVESTER_LIMIT_BOOSTED = 4,
                SHADOWDRONE_HARVESTER_FINDITEM_RADIUS_BOOSTED = 10,
                --
                SHADOWFUEL_DEBUFF_TIME = 20,
                HORRORFUEL_DEBUFF_TIME = 60,
                -- SOCKETQUALITY.MEDIUM == purehorror
                -- SOCKETQUALITY.HIGH == shadowheart
                -- drones
                SHADOWDRONE_DEBUFFER_LIMIT = 3,
				SHADOWDRONE_DEBUFFER_WALKSPEED = 6,
				SHADOWDRONE_DEBUFFER_RUNSPEED = 7.5,
				SHADOWDRONE_DEBUFFER_SCAN_RANGE = 3,
				SHADOWDRONE_DEBUFFER_SCAN_RANGE_MAX = 4.5,
                --
                SHADOWDRONE_DEBUFFER_LIMIT_BOOSTED = 4,
				SHADOWDRONE_DEBUFFER_RUNSPEED_BOOSTED = 9,
                --
                SHADOWDRONE_DAMAGEMULT_PER_DRONE = 0.06,
                -- vein harvests
                SHADOWHEART_WORK_NEEDED = 2,
                SHADOWHEART_SPAWN_PERIOD = seg_time * 4,
                SHADOWHEART_SPAWN_VARIANCE = seg_time,
                SHADOWHEART_SPAWN_DENSITY_RANGE = 6,
                SHADOWHEART_SPAWN_DENSITY_MAX = 4,
                -- SOCKETQUALITY.PERFECT == mimicheart
                MIMICHEART_SPAWN_PERIOD = total_day_time,
                MIMICHEART_SPAWN_VARIANCE = seg_time * 2,
                MIMICHEART_SPAWN_DENSITY_RANGE = 8,
                MIMICHEART_SPAWN_DENSITY_MAX = 2,
            }
        },

        WILSON_BEARD_BITS ={
            LEVEL1 = 1,
            LEVEL2 = 3,
            LEVEL3 = 9,
        },

--★★★ 【★★ 分区 32 · 裂隙与月神（Rifts / Lunar）】7605-7799 行 ★★★
--
--  ★★ 这是近年最大的系统扩展之一（虚空之地 / 月神阵营）。
--  英文注释 'Rifts 1'（第 7605 行）与 'Rifts 2'（第 7655 行）标记了两批内容。
--
--  SPAWN_RIFTS（第 7607 行附近）：是否生成裂隙的开关/数量。
--    ★★ 与第 6050 行 SPAWN_MALBATROSS 同类：
--      把「世界是否生成某内容」也做成 TUNING，
--      让世界生成器（worldgen）能统一读取，而不必硬编码。
--
--  LUNARTHRALL_PLANT_MOVEDIST = 2（第 7650 行附近）：
--    ★ 月神傀儡（Lunar Thrall）的植物移速 —— 极慢，是其弱点。
--  SHADOWTHRALL_MOUTH_WALKSPEED = 6（第 7700 行）：
--    ★ 对比：暗影傀儡移速 6，是月神傀儡（2）的 3 倍。
--    ⇒★ 两个「同族傀儡」的移速差 3 倍，是阵营强度的直观体现。
--    ★★ 调平衡时这类「同类对比」比单看绝对值更有意义。
        -- Rifts 1
        SPAWN_RIFTS = 1, -- 0 = disabled, 1 = enabled via gameplay, 2 = enabled at start
        MAXIMUM_RIFTS_COUNT = 1, -- NOTES(JBK): Leave at 1 until other side effects are fixed with assumptions made in portal rift logic.
        RIFTS_SPAWNDELAY = 5 * total_day_time,

        RIFT_LUNAR1_MAXSTAGE = 3,
        RIFT_LUNAR1_STAGEUP_BASE_TIME = 4.0 * total_day_time,
        RIFT_LUNAR1_STAGEUP_RANDOM_TIME = total_day_time,
        RIFT_LUNAR1_GROUNDPOUND_DAMAGE = 60,
        RIFT_LUNAR1_TRY_CRYSTALS_BASE_TIME = 0.75 * total_day_time,
        RIFT_LUNAR1_TRY_CRYSTALS_RANDOM_TIME = 0.5 * total_day_time,
        RIFT_LUNAR1_TERRAFORM_EXPLOSION_DAMAGE = 30,

        LUNARRIFT_CRYSTAL_MINES = 20,

		LUNAR_GRAZER_HEALTH = 80 * 30, --30 seconds for full regen
		LUNAR_GRAZER_HEALTH_REGEN = 80, --per second (only when dissipated)
		LUNAR_GRAZER_MELT_HEALTH_THRESHOLD = 80 * 30 - 200,
		LUNAR_GRAZER_WALKSPEED = 1.4,
		LUNAR_GRAZER_DAMAGE = 50,
		LUNAR_GRAZER_PLANAR_DAMAGE = 10,
		LUNAR_GRAZER_ATTACK_RANGE = 1.5,
		LUNAR_GRAZER_HIT_RANGE = 1.7,
		LUNAR_GRAZER_ATTACK_PERIOD = 4,
		LUNAR_GRAZER_WAKE_RANGE = 8,
		LUNAR_GRAZER_AGGRO_RANGE = 10,
		LUNAR_GRAZER_DEAGGRO_RANGE = 14,
		LUNAR_GRAZER_GROGGINESS = 1,
		LUNAR_GRAZER_KNOCKOUTTIME = 6,

        DOMESTICPLANTHERD_RANGE = 40,
        LUNARTHRALL_PLANT_GESTALT_WALK_SPEED = 15,
        LUNARTHRALL_PLANT_GESTALT_RUN_SPEED = 20,
        LUNARTHRALL_PLANT_HEALTH = 1000,
        LUNARTHRALL_PLANT_VINE_HEALTH = 200,
        LUNARTHRALL_PLANT_ATTACK_PERIOD = 2,
        LUNARTHRALL_PLANT_RANGE = 12,
        LUNARTHRALL_PLANT_GIVEUPRANGE = 22,
        LUNARTHRALL_PLANT_DAMAGE = 100,
		LUNARTHRALL_PLANT_PLANAR_DAMAGE = 30,
        LUNARTHRALL_PLANT_END_DAMAGE = 65,
		LUNARTHRALL_PLANT_END_PLANAR_DAMAGE = 10,
        LUNARTHRALL_PLANT_VINE_ATTACK_RANGE = 4,
        LUNARTHRALL_PLANT_VINE_INITIATE_ATTACK = 3,
        LUNARTHRALL_PLANT_CLOSEDIST = 2.5,
        LUNARTHRALL_PLANT_MOVEDIST = 2,
        LUNARTHRALL_PLANT_VINE_LIMIT = 1,
        LUNARTHRALL_PLANT_REST_TIME = 5,
        LUNARTHRALL_PLANT_WAKE_TIME = 4,

        -- Rifts 2
        FUSED_SHADELING_DAMAGE = 40,
        FUSED_SHADELING_PLANAR_DAMAGE = 10,
        FUSED_SHADELING_ATTACK_PERIOD = 2.5,
        FUSED_SHADELING_ATTACK_RANGE = 2.0,
        FUSED_SHADELING_WALKSPEED = 4.0,
        FUSED_SHADELING_JUMPSPEED = 24.0,
        FUSED_SHADELING_MAXJUMPDISTANCE = 10.0,
        FUSED_SHADELING_JUMP_COOLDOWN = 5.0,
        FUSED_SHADELING_HEALTH = 1250,
        FUSED_SHADELING_AGGRO_RANGE = 18,

        FUSED_SHADELING_BOMB_WALKSPEED = 5.50,
        FUSED_SHADELING_BOMB_EXPLOSION_DAMAGE = 50,
        FUSED_SHADELING_BOMB_EXPLOSION_PLANARDAMAGE = 20,
        FUSED_SHADELING_BOMB_EXPLOSION_TIME = 4.0,

		SHADOWTHRALL_HANDS_HEALTH = 1000,
		SHADOWTHRALL_HANDS_WALKSPEED = 4,
		SHADOWTHRALL_HANDS_RUNSPEED = 8,
		SHADOWTHRALL_HANDS_ATTACK_PERIOD = 4,
		SHADOWTHRALL_HANDS_ATTACK_RANGE = 8,
		SHADOWTHRALL_HANDS_DAMAGE = 35,
		SHADOWTHRALL_HANDS_PLANAR_DAMAGE = 20,
		SHADOWTHRALL_HANDS_STOMP_RADIUS = 1.8,

		SHADOWTHRALL_HORNS_HEALTH = 1200,
		SHADOWTHRALL_HORNS_WALKSPEED = 3,
		SHADOWTHRALL_HORNS_ATTACK_PERIOD = 4,
		SHADOWTHRALL_HORNS_ATTACK_RANGE = 6,
		SHADOWTHRALL_HORNS_DAMAGE = 20,
		SHADOWTHRALL_HORNS_PLANAR_DAMAGE = 20,
		SHADOWTHRALL_HORNS_FACEPLANT_RADIUS = 2.8,
		SHADOWTHRALL_HORNS_DEVOUR_RADIUS = 2.4,
		SHADOWTHRALL_HORNS_BISHIBASHI_RANGE = 5.75,
		SHADOWTHRALL_HORNS_BISHIBASHI_WIDTH = 2.5,

		SHADOWTHRALL_WINGS_HEALTH = 800,
		SHADOWTHRALL_WINGS_WALKSPEED = 5,
		SHADOWTHRALL_WINGS_ATTACK_PERIOD = 4,
		SHADOWTHRALL_WINGS_ATTACK_RANGE = 8,
		SHADOWTHRALL_WINGS_DAMAGE = 25,
		SHADOWTHRALL_WINGS_PLANAR_DAMAGE = 30,

		SHADOWTHRALL_MOUTH_HEALTH = 800,
		SHADOWTHRALL_MOUTH_WALKSPEED = 6,
		SHADOWTHRALL_MOUTH_ATTACK_PERIOD = 4,
		SHADOWTHRALL_MOUTH_ATTACK_RANGE = 4,
		SHADOWTHRALL_MOUTH_STEALTH_ATTACK_GROUP_PERIOD = 4,
		SHADOWTHRALL_MOUTH_STEALTH_ATTACK_PERIOD = 8,
		SHADOWTHRALL_MOUTH_STEALTH_ATTACK_RANGE = 12,
		SHADOWTHRALL_MOUTH_BITE_GROUP_PERIOD = 3, --must be shorter than attack_period, or stealthed will never get a turn
		SHADOWTHRALL_MOUTH_BITE_DAMAGE = 35,
		SHADOWTHRALL_MOUTH_BITE_PLANAR_DAMAGE = 20,
		SHADOWTHRALL_MOUTH_LEAP_DAMAGE = 15,
		SHADOWTHRALL_MOUTH_LEAP_PLANAR_DAMAGE = 10,
		SHADOWTHRALL_MOUTH_LEAP_COOLDOWN = 14,

		SHADOWTHRALL_AGGRO_RANGE = 12,
		SHADOWTHRALL_DEAGGRO_RANGE = 40,

		MIASMA_SPEED_MOD = .4,
        MIASMA_MAXSTRENGTH = 2, -- NOTES(JBK): It will take MIASMA_DIMINISH_INTERVAL_SECONDS * MIASMA_MAXSTRENGTH seconds to remove one miasma cloud maximally.
        MIASMA_SPACING = 1, -- In tiles.
        MIASMA_SPREAD_INTERVAL_SECONDS = 5,
        MIASMA_DIMINISH_INTERVAL_SECONDS = 1,
        MIASMA_MAX_CLOUDS = 500,
        MIASMA_ODDS_CREATE = 0.8,
        MIASMA_ODDS_SPREAD = 0.5,
        MIASMA_MIN_DISTSQ_FROM_RIFT = 1 * 1 * 4, -- 4 is TILE_SCALE.
        MIASMA_MAX_DISTSQ_FROM_RIFT = 12 * 12 * 4, -- 4 is TILE_SCALE.
        MIASMA_MAX_DIST_FROM_VENTER = 3 * 4, -- 4 is TILE_SCALE.

        MIASMA_DEBUFF_TICK_RATE = 2,
        MIASMA_DEBUFF_TICK_VALUE = -2,

        ACIDRAIN_ENABLED = true, -- Managed by world settings.
--【★ 持续伤害（DOT）与副作用】7732-7750 行。
--  英文注释 'Damage over times.' 与 'Side effects.'（第 7732、7737 行）。
--  ★ DOT（Damage over Time）是独立的伤害类别，与「一次击打」性质不同：
--    · 可被某些抗性/装备抵消
--    · 不触发受击硬直
--    · 常伴随持续掉血图标
--  ⇒ 调平衡时 DOT 的 DPS 必须与普通伤害分开比较，
--    否则会低估「持续伤害流」的实战强度。
        -- Damage over times.
        ACIDRAIN_DAMAGE_TIME = 1.5, -- How quickly the game polls to deal acidrain damage.
        ACIDRAIN_DAMAGE_PER_SECOND = 2.0,
        ACIDRAIN_DAMAGE_FUELED_SCALER = 2.0,
        ACIDRAIN_PERISHABLE_ROT_PERCENT = 0.007,
        -- Side effects.
        ACIDRAIN_BOULDER_WORK = 3,
        ACIDRAIN_BOULDER_WORK_STARTS_PERCENT = 0.5, -- What percentage of the acid level of the pond should it be for work to start.
        ACIDRAIN_BAT_SPEED_MULT = 1.25,
        ACIDRAIN_BAT_DAMAGE_MULT = 1.5,
--【★★ 关于持续时长平衡的一条设计说明注释】7742-7745 行。
--  英文原注释：
--      'NOTES(JBK): Making these too long will lessen the Umbralla keep it
--       long enough to be us...'
--      'Early game items make them last short mid items medium and
--       Umbralla is the late game str...'
--    ★★★ 这条注释揭示了「按游戏阶段分级」的持续时长体系：★★★
--      前期物品 → 短；中期物品 → 中；Umbralla（后期神器）→ 长。
--    ★★ 设计意图明确写在注释里：
--      **「把这些做得太长会削弱 Umbralla」** ——
--      后期神器必须靠「持续时间长」才能体现价值，
--      所以前期装备的持续时间必须严格受限，否则神器就废了。
--    ★★★ 这类注释是「平衡的推理过程」被保留下来的痕迹，
--      价值远高于单纯的数值记录。
        -- NOTES(JBK): Making these too long will lessen the Umbralla keep it long enough to be useful and put them into tiers.
        -- Early game items make them last short mid items medium and Umbralla is the late game strong one.
        HEALINGSALVE_ACIDBUFF_DURATION = total_day_time / 2,
        --ACIDICFOOD_ACIDBUFF_DURATION = total_day_time, -- Same as BUFF_MOISTUREIMMUNITY_DURATION in duration but for all characters able to make it.
        -- acidbatwavemanager
        ACIDBATWAVE_SPAWN_DISTANCE = 12,
        ACIDBATWAVE_SPAWN_COUNT_MIN = 2,
        ACIDBATWAVE_SPAWN_COUNT_MAX = 6,
        ACIDBATWAVE_NUMBER_OF_ITEMS_TO_GUARANTEE_WAVE_SPAWN = 20,
        ACIDBATWAVE_COOLDOWN_BETWEEN_WAVES = total_day_time / 2,
        ACIDBATWAVE_TIME_FOR_WARNING = seg_time * 2,


        FISSURE_COOLDOWN_WALKED_AWAY = total_day_time / 8,
        FISSURE_COOLDOWN_DEFEATED_ANY_THRALLS = total_day_time * 3,
        FISSURE_TIME_THRALLS_OUT_OF_COMBAT = 15.0, -- Seconds from last hit until a thrall is considered out of combat.
        FISSURE_DREADSTONE_WORK = 6,
        FISSURE_DREADSTONE_COOLDOWN = total_day_time * 1,

        RIFT_SHADOW1_QUAKER_ODDS = 0.1, -- Odds for interfering with quaker drops on players.
        RIFT_SHADOW1_QUAKER_RADIUS = 4.0, -- Radius for interfered quaker drops on players.

        RIFT_SHADOW1_MAXSTAGE = 3,
        RIFT_SHADOW1_STAGEUP_BASE_TIME = 4.0 * total_day_time,
        RIFT_SHADOW1_STAGEUP_RANDOM_TIME = total_day_time,

        RIFT_SHADOW1_CLOSE_TIME = 15 * total_day_time,
        RIFT_SHADOW1_GROUNDPOUND_DAMAGE = 20,

        RIFT_SHADOW1_FUSED_SHADELING_SPAWN_RATE_BY_STAGE =
        {
            {
                MAX_CHILDREN = 1,
                REGEN_TIME = seg_time * 8,
                RELEASE_TIME = seg_time * 4,
            },
            {
                MAX_CHILDREN = 3,
                REGEN_TIME = seg_time * 4,
                RELEASE_TIME = seg_time * 2,
            },
            {
                MAX_CHILDREN = 5,
                REGEN_TIME = seg_time * 2,
                RELEASE_TIME = seg_time,
            },
        },

        VOIDCLOTH_UMBRELLA_PERISHTIME = total_day_time*15,
        VOIDCLOTH_UMBRELLA_DAMAGE = wilson_attack,
		VOIDCLOTH_UMBRELLA_DOME_RADIUS = 16,
		VOIDCLOTH_UMBRELLA_DOME_RATE = 1.5,

        VOIDCLOTH_SCYTHE_USES = 200,
        VOIDCLOTH_SCYTHE_DAMAGE = wilson_attack * 2 - 30,
        VOIDCLOTH_SCYTHE_PLANAR_DAMAGE = 18,
        VOIDCLOTH_SCYTHE_HARVEST_RADIUS = 4,
        VOIDCLOTH_SCYTHE_HARVEST_ANGLE_WIDTH = 165/RADIANS,
--【分区 33 · 沃尔特与月神生物】7800-8099 行
--  ★ 分区边界：WORMWOOD（沃尔姆伍德，即沃尔特）与 LUNAR 系列生物。
--  WORMWOOD_PET_LIGHTFLIER_LIFETIME = 2.5 * total_day_time（第 7850 行）。
--    ★★ 宠物光球寿命 = 2.5 个完整昼夜（1200秒）。
--      写成 2.5*total_day_time 而非裸 1200：改时钟后自动等比缩放。
--    ★ 注意倍数 2.5 是小数 —— 说明该设计刻意不是整数天，
--      避免与「正好两天」的玩家直觉重合（防止卡点）。
        VOIDCLOTH_SCYTHE_TALK_INTERVAL = 30,
        VOIDCLOTH_SCYTHE_TALK_INITIAL_INTERVAL = 3,

        WEAPONS_VOIDCLOTH_VS_LUNAR_BONUS = 1.1,
		WEAPONS_VOIDCLOTH_SETBONUS_DAMAGE_MULT = 1.1,
		WEAPONS_VOIDCLOTH_SETBONUS_PLANAR_DAMAGE = 5,

        -- Wolfgang, Woodie, Wormwood Skill Trees

        WALKING_STICK_PERISHTIME = 4 * total_day_time,
        LEIF_IDOL_NUM_SPAWNS = 2,
        LEIF_IDOL_SPAWN_RADIUS = 10,

        LUCY_CARVING_TALK_COOLDOWN = 15, -- seconds

        WORMWOOD_BLOOM_STAGE_DURATION_UPGRADED1 = total_day_time * 0.9,
        WORMWOOD_BLOOM_STAGE_DURATION_UPGRADED2 = total_day_time * 0.75,
        WORMWOOD_BLOOM_FULL_DURATION_UPGRADED = total_day_time * 4.5,
        WORMWOOD_BLOOM_FULL_MAX_DURATION_UPGRADED = total_day_time * 7.5,

        WORMWOOD_TENDRANGE_MULT = 1.5,

        WORMWOOD_PHOTOSYNTHESIS_HEALTH_REGEN =
        {
            amount = 1,
            period = 10,
        },

        LUNARPLANTTENTACLE_DAMAGE = 70,
        LUNARPLANTTENTACLE_PLANARDAMAGE = 15,

        WORMWOOD_ROOT_TIME = 6,
        WORMWOOD_ROOT_DAMAGE = 10,

        WORMWOOD_ARMOR_BRAMBLE_RELEASE_SPIKES_HITCOUNT = 3,

        WORMWOOD_TRAP_BRAMBLE_AUTO_RESET_COOLDOWN = 3, -- seconds.

        IPECAC_POOP_COUNT = 15,
        IPECAC_TICK_TIME = 3,
        IPECAC_DAMAGE_PER_TICK = 5,

        WORMWOOD_MUSHROOMPLANTER_RATEBONUS_1 = 0.9,
        WORMWOOD_MUSHROOMPLANTER_RATEBONUS_2 = 0.8,

        WORMWOOD_PET_LIGHTFLIER_LIMIT = 6,
        WORMWOOD_PET_FRUITDRAGON_LIMIT = 2,
        WORMWOOD_PET_CARRAT_LIMIT = 4,

        WORMWOOD_PET_CARRAT_LIFETIME = 3 * total_day_time,
        WORMWOOD_PET_LIGHTFLIER_LIFETIME = 2.5 * total_day_time,
        WORMWOOD_PET_FRUITDRAGON_LIFETIME = 2 * total_day_time,

        WORMWOOD_PET_FRUITDRAGON_HEALTH = 600,
        WORMWOOD_PET_FRUITDRAGON_BUFF_HEALTH = 900,
        WORMWOOD_PET_FRUITDRAGON_HEALTH_REGEN_AMOUNT = 5,
        WORMWOOD_PET_FRUITDRAGON_HEALTH_REGEN_PERIOD = 2.5,
        WORMWOOD_PET_FRUITDRAGON_ATTACK_PERIOD = 2,
        WORMWOOD_PET_FRUITDRAGON_DAMAGE = 40,
        WORMWOOD_PET_FRUITDRAGON_WALK_SPEED = 1,
        WORMWOOD_PET_FRUITDRAGON_RUN_SPEED = 3,

        QUAKE_BLOCKER_RANGE = 40,
		SUPPORT_PILLAR_REINFORCED_LEVELS = 10,
		SUPPORT_PILLAR_DREADSTONE_REGEN_PERIOD = 2 * total_day_time,
		SUPPORT_PILLAR_DREADSTONE_AURA_RADIUS = 8, -- This has exponential falloff.
        DUMBBELL_HEAT_MAX_USES = 150,

        WOLFGANG_COACH_BUFF = 2,
        COACH_TIME_TO_INSPIRE = 7,
        COACH_TIME_BUFF_LASTS = 10,

        -- Rifts 3

        LUNARHAIL_DEBRIS_DAMAGE = 30,
        LUNARHAIL_DEBRIS_DAMAGE_RADIUS = 2,
        LUNARHAIL_DEBRIS_SPAWN_SCALE_RATE_MIN = 0.04,
        LUNARHAIL_DEBRIS_SPAWN_SCALE_RATE_MAX = 0.4,
        LUNARHAIL_DEBRIS_SPAWN_RADIUS = 60,
        LUNARHAIL_DEBRIS_LIFETIME = 5, -- Seconds.
        LUNARHAIL_DEBRIS_KEEP_CHANCE = 0.25,

        LUNARHAIL_EVENT_COOLDOWN = 10 * total_day_time,
        LUNARHAIL_EVENT_TIME = 3 * seg_time, --10
        LUNARHAIL_BIRD_EVENT = 0.5, --Happens halfway through Lunar Hail
        LUNARHAIL_BIRD_EVENT_VARIANCE = 0.1, --40-60% give or take
        LUNARHAIL_BIRD_EVENT_RETRY = 0.03, --We failed, try again quick!!!

        LUNARHAIL_BUILDUP_TICK_TIME = 2.5, -- Seconds.
        LUNARHAIL_BUILDUP_RATE = 1 / seg_time, -- Percent per second.

        LUNARHAIL_BUILDUP_DECAY_TICK_TIME = 4.5, -- Seconds.
        LUNARHAIL_BUILDUP_DECAY_RATE = 1 / total_day_time, -- Percent per second.

        LUNARHAIL_BUILDUP_MOONGLASS_REWARDS_DESTRUCTION_MULT = 0.5,

        LUNARHAIL_BUILDUP_TOTAL_WORK_AMOUNT_SMALL = 2,
        LUNARHAIL_BUILDUP_MOONGLASS_AMOUNT_SMALL = 1,
        LUNARHAIL_BUILDUP_TOTAL_WORK_AMOUNT_MEDIUM = 3,
        LUNARHAIL_BUILDUP_MOONGLASS_AMOUNT_MEDIUM = 2,
        LUNARHAIL_BUILDUP_TOTAL_WORK_AMOUNT_LARGE = 4,
        LUNARHAIL_BUILDUP_MOONGLASS_AMOUNT_LARGE = 3,

        LUNARHAIL_BUILDUP_MOONGLASS_REWARDS_CHARGED_CHANCE_MAX = 0.4,
        LUNARHAIL_BUILDUP_MOONGLASS_REWARDS_CHARGED_CHANCE_MIN = 0.2,

		MUTATED_DEERCLOPS_HEALTH = 6000,
		MUTATED_DEERCLOPS_DAMAGE = 150,
		MUTATED_DEERCLOPS_PLANAR_DAMAGE = 30,
		MUTATED_DEERCLOPS_ATTACK_RANGE = 13,
		MUTATED_DEERCLOPS_ATTACK_PERIOD = 3,
		MUTATED_DEERCLOPS_COMBO_ATTACK_PERIOD = 4,
		MUTATED_DEERCLOPS_ICELANCE_DAMAGE = 200,
		MUTATED_DEERCLOPS_ICELANCE_RANGE = { min = 6, max = 14 },
		MUTATED_DEERCLOPS_STAGGER_TIME = 6,
		MUTATED_DEERCLOPS_FRENZY_MIN_TIME = 12,
		MUTATED_DEERCLOPS_FRENZY_HP = 1200 / 6000,

		MUTATED_BEARGER_HEALTH = 8000,
		MUTATED_BEARGER_DAMAGE = 175,
		MUTATED_BEARGER_PLANAR_DAMAGE = 30,
		MUTATED_BEARGER_ATTACK_RANGE = 6,
		MUTATED_BEARGER_ATTACK_PERIOD = 3,
		MUTATED_BEARGER_STAGGER_TIME = 6,
        MUTATED_BEARGER_TARGET_RANGE = 14,
		MUTATED_BEARGER_SINKHOLERADIUS = 3,
		MUTATED_BEARGER_RECOVERY_HP = 800 / 8000,

		MUTATED_WARG_HEALTH = 3000,
		MUTATED_WARG_STAGGER_TIME = 6,
		MUTATED_WARG_COLDFIRE_TEMPERATURE = -2,
		MUTATED_WARG_FLAMETHROWER_CD = 8,
		MUTATED_WARG_PLANAR_DAMAGE = 30,
		MUTATED_WARG_FLAMETHROWER_DAMAGE = 20,

		KOALEFANT_CARCASS_MEAT_PER_LEVEL = 14, --3 levels
		KOALEFANT_CARCASS_DECAY_TIME = total_day_time * 0.5,

        CORPSE_GESTALT_WALK_SPEED = 15,
        CORPSE_GESTALT_RUN_SPEED = 20,

        FROG_RAIN_LUNARFROG_CHANCE = 0.6,

        LUNARFROG_HEALTH = 150,
        LUNARFROG_DAMAGE = 10,
        LUNARFROG_PLANAR_DAMAGE = 5,
        LUNARFROG_ATTACK_PERIOD = 1,
        LUNARFROG_TARGET_DIST = 4,
        LUNARFROG_ONATTACK_GROGGINESS = 0.35,
        LUNARFROG_ADDITIONAL_LOOT_CHANCE = 0.5,
        LUNARFROG_ITEMS_TO_STEAL_MIN = 2,
        LUNARFROG_ITEMS_TO_STEAL_MAX = 4,

        BEARGERFUR_SACK_PRESERVER_RATE = 0.05,

        DEERCLOPSEYEBALL_SENTRYWARD_RADIUS = 35,
        DEERCLOPSEYEBALL_SENTRYWARD_GROUND_ICE_RADIUS = 3.5,
        DEERCLOPSEYEBALL_SENTRYWARD_TEMPERATURE_OVERRIDE = -10,

        DEERCLOPSEYEBALL_SENTRYWARD_ROCK_ICE_SPAWN_BASETIME = 7 * total_day_time,
        DEERCLOPSEYEBALL_SENTRYWARD_ROCK_ICE_SPAWN_VARIANCE = 5 * total_day_time,
        DEERCLOPSEYEBALL_SENTRYWARD_ROCK_ICE_MAX_DENSITY_RAD = 12,
        DEERCLOPSEYEBALL_SENTRYWARD_ROCK_ICE_MAX_DENSITY = 6,
        DEERCLOPSEYEBALL_SENTRYWARD_ROCK_ICE_MIN_SPACING = 5,

        ROCK_ICE_TEMPERATURE_GROW_MELT_TIME = 5 * total_day_time,

        HOUNDSTOOTH_BLOWPIPE_DAMAGE = wilson_attack,
        HOUNDSTOOTH_BLOWPIPE_PLANAR_DAMAGE = wilson_attack,
        HOUNDSTOOTH_BLOWPIPE_VS_SHADOW_BONUS = 1.1, -- Multiplier.
        HOUNDSTOOTH_BLOWPIPE_PROJECTILE_SPEED = 25,
        HOUNDSTOOTH_BLOWPIPE_ATTACK_DIST = 12,
        HOUNDSTOOTH_BLOWPIPE_ATTACK_DIST_MAX = 16,

        VASE_FLOWER_SWAPS =
        {
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = true,   sanityboost = 0 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = true,   sanityboost = 0 },
            { lightsource = true,   sanityboost = 0 },
            { lightsource = true,   sanityboost = 0 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
            { lightsource = false,  sanityboost = 5 },
        },

        VASE_FLOWER_MAP =
        {   -- These are indexes into VASE_FLOWER_SWAPS above.
            petals              = { 1, 2, 3, 4, 6, 10, 11, 12 },
            lightbulb           = { 5, 7, 8 },
            wormlight           = { 9 },
            wormlight_lesser    = { 9 },
            forgetmelots        = { 13, 14 },
--【★ 月树与boat race】8000-8099 行。
--  moon_tree_blossom = { 15 }（第 8000 行）：
--    ★★ 嵌套表里的**单个元素** —— 只有一个等级，写作 { 15 }。
--    ★ 这是「为将来扩展预留结构」的写法：
--      现在只有 1 级（值 15），将来加第 2 级时直接 { 15, 30 } 即可，
--      无需改动调用方代码。
--    ★★ 读表要点：单元素表容易被误当成标量，
--      业务代码若写TUNING.moon_tree_blossom 而非 [1] 会拿到 nil。
            moon_tree_blossom   = { 15 },
        },

        PHONOGRAPH_PLAY_TIME = 64,
        PHONOGRAPH_TEND_RANGE = 8,

        --NOTE: + 20 * 5 <= 20 hits of defending 5 planar damage
        ARMORPUNK = wilson_health*6*multiplayer_armor_durability_modifier + 20 * 5,
        ARMORPUNK_ABSORPTION = 0.85*multiplayer_armor_absorption_modifier,
        ARMORPUNK_PLANAR_DEF = 5,

        ARMORPUNK_SPEED_MULT_STAGE0 = 1.10,
        ARMORPUNK_SPEED_MULT_STAGE1 = 1.15,
        ARMORPUNK_SPEED_MULT_STAGE2 = 1.20,
        ARMORPUNK_SPEED_MULT_STAGE3 = 1.30,

        ARMORPUNK_STAGE1 = 10,
        ARMORPUNK_STAGE2 = 16,
        ARMORPUNK_STAGE3 = 20,

        --NOTE: + 20 * 5 <= 20 hits of defending 5 planar damage
        ARMOR_WAGPUNK_HAT = wilson_health * 6 * multiplayer_armor_durability_modifier + 20 * 5,
        ARMOR_WAGPUNK_HAT_ABSORPTION = 0.85 * multiplayer_armor_absorption_modifier,
        ARMOR_WAGPUNK_HAT_PLANAR_DEF = 5,

        ARMOR_WAGPUNK_HAT_STAGE0 = 1.05,
        ARMOR_WAGPUNK_HAT_STAGE1 = 1.10,
        ARMOR_WAGPUNK_HAT_STAGE2 = 1.15,
        ARMOR_WAGPUNK_HAT_STAGE3 = 1.20,

        WAGPUNK_MAXRANGE = 16,
        WAGPUNK_SYNC_TIME = 3,

        WAGSTAFF_MACHINERY_BLUEPRINT_CHANCE = 0.4,
        WAGSTAFF_MACHINERY_NUM_BLUEPRINTS = 1,

        WAGSTAFF_MACHINE_HINT_TIME = { min = total_day_time, max = 15*total_day_time },

        WAGSTAFF_SPAWN_MACHINE_TIME = 4 * total_day_time,
        WAGSTAFF_SPAWN_MACHINE_TIME_VARIATION = 3 * total_day_time,

        -- Meta 3

        SPEAR_WATHGRITHR_LIGHTNING_USES = 150,
        SPEAR_WATHGRITHR_LIGHTNING_DAMAGE = wilson_attack * 1.75,
        SPEAR_WATHGRITHR_LIGHTNING_WET_DAMAGE_MULT = 0.5, -- It's actually 1.5

        SPEAR_WATHGRITHR_LIGHTNING_LUNGE_COOLDOWN = 3,
        SPEAR_WATHGRITHR_LIGHTNING_LUNGE_DAMAGE = wilson_attack * 2,

        SPEAR_WATHGRITHR_LIGHTNING_CHARGED_USES = 200,
        SPEAR_WATHGRITHR_LIGHTNING_CHARGED_DAMAGE = wilson_attack * 1.75,
        SPEAR_WATHGRITHR_LIGHTNING_CHARGED_PLANAR_DAMAGE = 20,
        SPEAR_WATHGRITHR_LIGHTNING_CHARGED_SPEED_MULT = 1.2,
        SPEAR_WATHGRITHR_LIGHTNING_CHARGED_LUNGE_COOLDOWN = 1.5,
        SPEAR_WATHGRITHR_LIGHTNING_CHARGED_LUNGE_REPAIR_AMOUNT = 4,
        SPEAR_WATHGRITHR_LIGHTNING_CHARGED_MAX_REPAIRS_PER_LUNGE = 2, -- Max repair value: SPEAR_WATHGRITHR_LIGHTNING_CHARGED_LUNGE_REPAIR_AMOUNT * SPEAR_WATHGRITHR_LIGHTNING_CHARGED_MAX_REPAIRS_PER_LUNGE

        ARMOR_WATHGRITHR_IMPROVEDHAT = wilson_health * 6.5 * multiplayer_armor_durability_modifier,
        ARMOR_WATHGRITHR_IMPROVEDHAT_ABSORPTION = .8 * multiplayer_armor_absorption_modifier,

        WATHGRITHR_SHIELD_DAMAGE = wilson_attack * 1.5,
        WATHGRITHR_SHIELD_ABSORPTION = .85 * multiplayer_armor_absorption_modifier,
        WATHGRITHR_SHIELD_ARMOR = wilson_health * 4 * multiplayer_armor_durability_modifier,
        WATHGRITHR_SHIELD_USEDAMAGE = 3,

        WATHGRITHR_SHIELD_PARRY_ARC = 178,

        WATHGRITHR_SHIELD_COOLDOWN = 10,
        WATHGRITHR_SHIELD_COOLDOWN_ONEQUIP = 2,
        WATHGRITHR_SHIELD_PARRY_DURATION = 1,
        WATHGRITHR_SHIELD_COOLDOWN_ONPARRY_REDUCTION = 0.7, -- Advances to 70% cooldown, so the new cooldown is 30% of WATHGRITHR_SHIELD_COOLDOWN.

        SADDLE_WATHGRITHR_BONUS_DAMAGE = 5,
        SADDLE_WATHGRITHR_USES = 6,
        SADDLE_WATHGRITHR_SPEEDMULT = 1.3,
        SADDLE_WATHGRITHR_ABSORPTION = 0.4 * multiplayer_armor_absorption_modifier,

        BATTLESONG_SHADOWALIGNED_SHADOW_RESIST = 0.9,
        BATTLESONG_SHADOWALIGNED_VS_LUNAR_BONUS = 1.05,

        BATTLESONG_LUNARALIGNED_LUNAR_RESIST = 0.9,
        BATTLESONG_LUNARALIGNED_VS_SHADOW_BONUS = 1.05,

        EMBER_STAR_DURATION = total_day_time,
        WILLOW_EMBER_THROW = 1,
        WILLOW_EMBER_BURST = 4,
        WILLOW_EMBER_BALL = 2,
        WILLOW_EMBER_FRENZY = 2,
        WILLOW_EMBER_LUNAR = 5,
        WILLOW_EMBER_SHADOW = 5,

        WILLOW_LUNAR_FIRE_BONUS = 1.1,
        WILLOW_SHADOW_FIRE_BONUS = 1.1,

        WILLOW_FIREFRENZY_DURATION = seg_time*2,
        WILLOW_FIREFRENZY_MULT = 1.25,

        WILLOW_LUNAR_FIRE_TIME = 5,
        WILLOW_LUNAR_FIRE_DAMAGE = 20,
--【分区 34 · 沃特 / 仙客来 / 遗迹噩梦】8100-8399 行
--  ★ 分区边界：WURT（沃特）参数延续与RUINSNIGHTMARE（遗迹噩梦）。
--  WILLOW_LUNAR_FIRE_PLANAR_DAMAGE = 30（第 8100 行附近）：
--    ★★ 注意键名含 LUNAR（月神）—— 同一角色的不同形态有独立键。
--      对应第 3760 行 WILLOW_FIRE_DAMAGE = 0（普通形态无火焰伤害）。
--      ⇒★ 调平衡必须同时检查「常态键」与「LUNAR 键」，
--        只改一个会让角色在某一形态下失衡。
        WILLOW_LUNAR_FIRE_PLANAR_DAMAGE = 30,

        WILLOW_EMBERDROP_RANGE = 40, --die within this range of willow to spawn an ember

        WILLOW_EMBER_DURATION = total_day_time,
        CONTROLLED_BURN_DAMAGE_MULT = 1.5,
        CONTROLLED_BURN_DURATION_CREATURE_MULT = 3,

        FIRE_BURST_RANGE = 10,

        BERNIE_PLANAR_DAMAGE = 5,
        BERNIE_PLANAR_DEFENCE = 15,

        BERNIE_BURNING_REFLECT_DAMAGE = 50,


        WILLOW_SHADOW_FIRE_COOLDOWN = 8,
        WILLOW_LUNAR_FIRE_COOLDOWN = 13,

		CHANNELCAST_SPEED_MOD = 2 / 3,

        -- Ocean Ice
        OCEAN_ICE_RADIUS = 1.6,
        OCEAN_ICE_HEALTH = 30,
        OCEAN_ICE_TILE_HEALTH = 200,
        OCEAN_ICE_BREAK_FORCE = 1.15,

        -- Year of the Dragon
        DRAGON_BOAT_RADIUS = 3.0,
        DRAGON_BOAT_HEALTH = 200,

        MAX_BOATRACE_COMPONENT_DISTANCE = 30,

        BOATRACE_THROWABLE_DEPLOY_LAUNCHSPEED = 20,
        BOATRACE_THROWABLE_DEPLOY_GRAVITY = -35,
        BOATRACE_THROWABLE_MIN_DISTANCE = 0.0,
        BOATRACE_THROWABLE_MAX_DISTANCE = 8.0,
        BOATRACE_START_INCLUSION_PROXIMITY = 12.0,
        BOATRACE_DEFAULT_PROXIMITY = 6.0,
        BOATRACE_AUTOMATIC_CHECKPOINT_COUNT = 3,
        BOATRACE_AUTOMATIC_CHECKPOINT_MINRADIUS = 13,
        BOATRACE_MIN_COUNT_FOR_SHADOWBOAT = 3,
        BOATRACE_PRIMEMATE_BUOYCHANCE = 0.35,

        BOATRACE_SEASTACK_EXTRA_RESTITUTION = 0.5,
        BOATRACE_SEASTACK_DAMAGE_TO_WORK = wilson_attack,

        BOATRACE_SPECTATOR_TARGET_DISTANCE = 1.5,
        BOATRACE_SPECTATOR_MAX_DISTANCE = 3.5,

        -- Rifts / Meta QoL

        JUNK_PILE_STAGES = 3,
		JUNK_FALL_DAMAGE = 30,

        SCRAP_MONOCLE_EXTRA_VIEW_DIST = 20,
        SCRAP_MONOCLEHAT_PERISHTIME = total_day_time * 12,

        BEESWAX_SPRAY_USES = 75,

		COLLAPSED_CHEST_EXCESS_STACKS_THRESHOLD = 15,
		COLLAPSED_CHEST_MAX_EXCESS_STACKS_DROPS = 6,

        STORAGE_ROBOT_WORK_RADIUS = 15,
        STORAGE_ROBOT_FUEL = total_day_time * 3.5,
        STORAGE_ROBOT_WALKSPEED = {
            FULL  = 5.0,
            MED   = 4.25,
            SMALL = 3.5,
        },
        STORAGE_ROBOT_MASS = {
            FULL   = 80,
            MED    = 115,
            SMALL  = 150,
        },

        ACIDRAIN_PERISHLOOT_BASESAFEPERCENT = 0.4,
        ACIDRAIN_MUSHTREE_PHASE_TIME = 0.9*total_day_time,
        ACIDRAIN_MUSHTREE_UPDATE_TIME = 0.33*seg_time,

        SPIDER_ACID_DAMAGE_CHANGE = 1.5,
        SPIDER_ACID_DAMAGETAKEN_CHANGE = 0.75,

        ACID_INFUSION_MULT = {
            BERSERKER = {
                DAMAGE = 1.5,
                DAMAGE_TAKEN = 1.25,
                SPEED = 1.25,
            },

            STRONGER = {
                DAMAGE = 1.5,
                DAMAGE_TAKEN = 0.75,
                SPEED = 1.15,
            },

            WEAKER = {
                DAMAGE = 0.85,
                DAMAGE_TAKEN = 1.25,
                SPEED = 0.85,
--[★ 遗迹噩梦]8200-8299 行。
--  WARMED = 25（第 8250 行）：
--    ★ 英文单词直接做键名（WARMED = 温暖状态）。
--    ⚠疑似缺陷（命名不一致）：本文件绝大多数键用全大写下划线，
--      此处直接用了单个英文单词，且极短，易与同类混淆。
--      推理依据：前后相邻键均为标准命名风格，唯此处不同。
--      影响：功能正常，但grep 时容易漏检。
            },
        },

        -- Meta 4 / Ocean QoL

        MONKEY_PIRATE_TREASURE_BOAT_CHANCE = 0.35,
        CURSED_TRINKET_LIFETIME = seg_time*8,

        OTTER_WATER_HOP_DISTANCE = 4.0,
        OTTER_HEALTH = 350,
        OTTER_DAMAGE = 35,
        OTTER_RUNSPEED = 6,
        OTTER_WALKSPEED = 3,
        OTTER_ATTACK_RANGE = 3,
        OTTER_ATTACK_PERIOD = 4,
        OTTER_KEEPTARGET_DISTANCE = 20,
        OTTER_SHARETARGET_DISTANCE = 20,
        OTTER_MAX_INVENTORY_ITEMS = 3,
        OTTER_EAT_DELAY = seg_time * 2,

        OTTERDEN_HEALTH = 350,
        OTTERDEN_REGEN_PERIOD = total_day_time*6,
        OTTERDEN_SPAWN_PERIOD = 3*seg_time,
        OTTERDEN_INVENTORY_SLOTS = 4,
        OTTERDEN_ENABLED = true,

        BOAT_OTTERDEN_ERODE_RATE = 1,

        ANCIENTTREE_GROW_TIME =
        {
            { base =  5*total_day_time, random = 2*total_day_time }, -- Seed:   3-7  days.
            { base = 10*total_day_time, random = 2*total_day_time }, -- Sprout: 8-12 days.
        },

        ANCIENTTREE_WORK = 20,
        ANCIENT_TREE_SEED_CHANCE_RATE = 0.004, -- Per day. Reaches 0.6 at day 150.
        ANCIENT_TREE_SEED_MIN_CHANCE = 0.1,
        ANCIENT_TREE_SEED_MAX_CHANCE = 0.6,

        ANCIENTTREE_NIGHTVISION_FRUIT_BUFF_DURATION = total_day_time / 2,

        BOAT_REPAIR_KELP_REPAIR_TIME_SMALL_LEAK = total_day_time * .75,
        BOAT_REPAIR_KELP_REPAIR_TIME_MED_LEAK   = total_day_time * .50,

        ANCIENTFRUIT_GEM_MIN_HEAT = 40,
        ANCIENTFRUIT_GEM_HATCH_TIME = 30,

        ANCIENTFRUIT_GEM_TEMPERATURE_THRESHOLD =
        {
            MIN = 15,
            WARMED = 25,
            HEATED = 35,
            MAX = 60,
        },

        SALTLICK_IMPROVED_MAX_LICKS = 480, -- 30 days @ 8 beefalo licks per day (self / (SALTLICK_DURATION * SALTLICK_BEEFALO_USES))

        BOATLEAK_PLUG_WETNESS = 1,
        BOATLEAK_PLUG_WETNESS_INVENTORYITEM = 5,

        BOAT_LEAK_PLUGGED_TIME = 20,
        BOAT_LEAK_PLUGGED_TIME_VARIANCE = 5,

        WURT_OFFERING_POT_RANGE = 7,
        WURT_MAX_OFFERING_REGEN_MULT = 0.5,

        WURT_TERRAFORMING_TIME = 4*seg_time,
        WURT_TERRAFORMING_RECHARGE_TIME = total_day_time,
        WURT_TERRAFORMING_FX_BASE = 2,
        WURT_TERRAFORMING_FX_RAND = 10,
        WURT_TERRAFORMING_TILERANGE = 3,
        WURT_TERRAFORMING_SHADOW_PROCCHANCE = 0.5,

        WURT_PATHFINDER_RANGE = 30,
        WURT_MERM_INFESTATION_TIMER = 30,
        WURT_BONUS_FERT = 8,

        MOSQUITOBOMB_MOSQUITOS = 4,
        BOMB_MOSQUITO_RANGE = 3,
        BOMB_MOSQUITO_DAMAGE = wilson_attack*1.75,

        MERM_HEALTHREGEN_TICK_VALUE = 5,
        MERM_HEALTHREGEN_TICK_VALUE_PLAYER = 1,

        MERM_HEALTHREGEN_DURATION = 10,
        MERM_HEALTHREGEN_TICK_RATE = 1,

        ARMOR_MERMARMORHAT = wilson_health*2*multiplayer_armor_durability_modifier,
        ARMOR_MERMARMORHAT_ABSORPTION = .3*multiplayer_armor_absorption_modifier,

        ARMOR_MERMARMORUPGRADEDHAT = wilson_health*3*multiplayer_armor_durability_modifier,
        ARMOR_MERMARMORUPGRADEDHAT_ABSORPTION = .5*multiplayer_armor_absorption_modifier,

        MERM_TOOL = {
            USES = 50,
            DAMAGE = wilson_attack * .5,
            CONSUMPTION = {
                CHOP = 1,
                MINE = 3,
                DIG  = 3,
--[★ 仙客来 / 蘑菇地]8300-8399 行。
--  TILL = 1（第 8300 行）：
--    ★ 单字母/单词键名。TILL = 耕种动作的工作量。
--    ★★ 与第 5744 行 FARM_TILL_SPACING 同源（FARM_TILL 家族）。
--      耕种相关参数散布在两处，调平衡时需一并搜索。
                TILL  = 1,
            },
            EFFICIENCY = 0.25,
        },

        MERM_TOOL_UPGRADED = {
            USES = 100,
            DAMAGE = wilson_attack * .5,
            CONSUMPTION = {
                CHOP = 1,
                MINE = 3,
                DIG  = 3,
                TILL  = 1,
            },
            EFFICIENCY = 0.5,
        },

        WURT_PLANAR_BUFF_DAMAGE = 20,
        WURT_PLANAR_DAMAGE_BUFF_MULT = 3/5,
        WURT_PLANAR_TIME_BUFF_LASTS = 8*seg_time,

        MERMKING_TRIDENTBUFF_TRIPLEHIT_CHANCE = 0.33,
        MERMKING_TRIDENTBUFF_TRIPLEHIT_DAMAGECHANGE = 0.5,
        MERMKING_CROWNBUFF_DODGE_COOLDOWN = 10,
        MERMKING_CROWNBUFF_DODGE_SPEED = 8.5,
        MERMKING_CROWNBUFF_SANITYAURA_MOD = 0.95,
        MERMKING_PAULDRONBUFF_DEFENSEPERCENT = 0.15,
        MERMKING_PAULDRONBUFF_DEFENSEPERCENT_PLAYER = 0.10,

        MERM_LUNAR_GUARD_EXTRA_HEALTH = 40,
        MERM_LUNAR_EXTRA_HEALTH = 40,
        MERM_LUNAR_THORN_DAMAGE = 40,
        MERM_LUNAR_THORN_PLAYERDAMAGEPERCENT = 0.5,

        -- Rifts 4
        WORM_BOSS_HEALTH = 5000,
        WORM_BOSS_DAMAGE = 14,
        WORM_BOSS_SPINES = 14,
        WORM_BOSS_MELEE_RANGE = 6,
        WORM_BOSS_TARGET_DIST = 40,
        WORM_BOSS_EAT_CREATURE_RANGE = 1.5,
        WORM_BOSS_EAT_RANGE = 2,
        WORM_BOSS_KNOCKBACK_RANGE = 2,
        WORM_BOSS_DAYS = 25,

        SPAWN_GELBLOBS = true, -- For world settings.
        MIN_GELBLOBS_PER_SPAWNER = 5,
        MAX_GELBLOBS_PER_SPAWNER = 10,
        MAX_GELBLOBS_TOTAL_IN_WORLD = 100,
        MIN_GELBLOB_DIST_FROM_EACHOTHER = 3,
        MAX_GELBLOB_DIST_FROM_SPAWNER = 12,
        MIN_GELBLOB_SPAWN_DELAY = 0.25,
        VARIANCE_GELBLOB_SPAWN_DELAY = 1,
        COOLDOWN_GELBLOB_SPAWNER_TIME = 5 * day_time,
		GELBLOB_HEALTH = 600,
		GELBLOB_DAMAGE = 20,
		GELBLOB_PLANAR_DAMAGE = 20,

        RUINSNIGHTMARE_SPEED = 5,
        RUINSNIGHTMARE_SPEED_RIFTS = 6.5,
        RUINSNIGHTMARE_HEALTH = 850,
        RUINSNIGHTMARE_DAMAGE = 50,
        RUINSNIGHTMARE_PLANAR_DAMAGE = 25, -- During rifts.
        RUINSNIGHTMARE_ATTACK_RANGE = 3.5,
        RUINSNIGHTMARE_ATTACK_PERIOD = 1.5,
        RUINSNIGHTMARE_HORNATTACK_CHANCE = .75,

        RUINSNIGHTMARE_SPAWN_CHANCE = .4,
        RUINSNIGHTMARE_SPAWN_CHANCE_RIFTS = .9,

        SHADOW_BEEF_BELL_POOP_DISAPPEAR_TIME = 5,
        SHADOW_BEEF_BELL_CURSE_HEALTH_PENALTY = .5,
        SHADOW_BEEF_BELL_CURSE_SANITY_DELTA = -100,
        SHADOW_BEEF_BELL_REVIVE_COOLDOWN = 15 * total_day_time,

        SHADOW_BATTLEAXE = {
            USES = 200,
            MAX_HUNGER = 500,
            HUNGER_GAIN_ONKILL = 500 * .1,
            DAMAGE = wilson_attack * 2 - 30,
            LIFE_STEAL_SANITY_LOSS_SCALE = .5,
            LEVEL_THRESHOLDS = { 0, 3, 6, 9},

            TALK_INTERVAL = {
                OVERTIME = 30,

                -- Matches string naming...
                CHOPPING = 10,
                CHOPPING_WOODIE = 10,
                STARVING = 5,
                CREATURE_KILLED = 5,
            },

            RECENT_TARGET_TIME = 5,

            LEVEL = {
                {
                    PLANAR_DAMAGE = 10,
                    CHOPPING_EFFICIENCY = 1.50,
                    LIFE_STEAL = 0,
--[★ 兔子王]8400-8499 行。
--  HUNGER_RATE = 0, -- Actually paused.（第 8400 行）
--    ★★ 值为0 且注释明说「实际是暂停的」。
--    ⚠疑似缺陷（死键）：
--      推理依据：值恒为 0 意味着该机制不生效，注释确认「暂停」。
--      后果：业务代码若读取此键永远得到 0。
--    ★★ 价值在于注释澄清了「0 = 暂停」这一语义，
--      否则后来者会误以为这是 bug 而「修复」它，反而破坏设计。
                    HUNGER_RATE = 0, -- Actually paused.
                },
                {
                    PLANAR_DAMAGE = 14,
                    CHOPPING_EFFICIENCY = 1.75,
                    LIFE_STEAL = wilson_attack * .050,
                    HUNGER_RATE = 0.05, -- ~20.8 days.
                },
                {
                    PLANAR_DAMAGE = 18,
                    CHOPPING_EFFICIENCY = 2.00,
                    LIFE_STEAL = wilson_attack * .075,
                    HUNGER_RATE = 0.1, -- ~10.4 days.
                },
                {
                    PLANAR_DAMAGE = 22,
                    CHOPPING_EFFICIENCY = 2.25,
                    LIFE_STEAL = wilson_attack * .100,
                    HUNGER_RATE = 0.2, -- ~5.2 days.
                },
            },
        },

        VOIDCLOTH_BOOMERANG_ATTACK_DIST = 10,
        VOIDCLOTH_BOOMERANG_ATTACK_DIST_MAX = 14,
        VOIDCLOTH_BOOMERANG_USES = 85,
        VOIDCLOTH_BOOMERANG_DAMAGE =        { min = 5, max = wilson_attack*.8 },
        VOIDCLOTH_BOOMERANG_PLANAR_DAMAGE = { min = 5, max = wilson_attack*.8 },
        VOIDCLOTH_BOOMERANG_VS_LUNAR_BONUS = 1.25,
        VOIDCLOTH_BOOMERANG_SPEEDMULT = 1.1,
        VOIDCLOTH_BOOMERANG_PROJECTILE =
        {
            LAUNCH_SPEED = 15,
            RETURN_SPEED = 7.5,
            MAX_ACTIVE = 3,
            SETBONUS_MAX_ACTIVE = 4,
        },

        WEAPONS_NIGHTMARE_VS_LUNAR_BONUS = 1.1,

        SADDLE_SHADOW_BONUS_DAMAGE = 0,
        SADDLE_SHADOW_USES = 12,
        SADDLE_SHADOW_SPEEDMULT = 1.45,
        SADDLE_SHADOW_ABSORPTION = 0.6 * multiplayer_armor_absorption_modifier,
        SADDLE_SHADOW_PLANAR_DEF = 15,
        SADDLE_SHADOW_PLANAR_DAMAGE = 18,
        SADDLE_SHADOW_SHADOW_RESIST = 0.9,
        SADDLE_SHADOW_VS_LUNAR_BONUS = 1.1,

        ROPEBRIDGE_LENGTH_TILES = 6, -- How many tiles in a line can this make for each construction.
        ROPEBRIDGE_HEALTH = 200,
        ROPEBRIDGE_EARTHQUAKE_DAMAGE_TAKEN = 50,
        ROPEBRIDGE_EARTHQUAKE_TIMETOBREAK = 3, -- 3 seconds is enough to run over the length in case a player is on it as it is breaking.

        -- rabbitkingmanager
        RABBITKING_SPAWN_DISTANCE = 6,
        RABBITKING_MEATCHECK_DISTANCE_SQ = 144, -- 12*12
        RABBITKING_TELEPORT_DISTANCE_SQ = 900, -- 30*30
        RABBITKING_CARROTS_NEEDED = 12,
        RABBITKING_CARROTS_NEEDED_VARIANCE = 4,
        RABBITKING_NAUGHTINESS_NEEDED = 20,
        RABBITKING_NAUGHTINESS_NEEDED_VARIANCE = 10,
        RABBITKING_LUCKY_ODDS = 0.01, -- Percentage of a regular rabbit upgrading to a lucky one.
        RABBITKING_LUCKY_ODDS_QUAKER = 0.1, -- Same but for quaker which is more infrequent to happen.

        -- rabbitking
        RABBITKING_RUN_SPEED = 7,
        RABBITKING_HEALTH = 2000,
        RABBITKING_DAMAGE = 75,
        RABBITKING_STUN_DURATION = 5,
        RABBITKING_STOLEN_MANRABBIT_LOYALTY_TIME = 60,
        RABBITKING_COOLDOWN = 1 * day_time,
        RABBITKING_ABILITY_CD_POSTSTUN = 1,
        RABBITKING_ABILITY_SUMMON_CD = 60,
        RABBITKING_ABILITY_SUMMON_CD_START = 3,
        RABBITKING_ABILITY_SUMMON_COUNT = 3,
        RABBITKING_ABILITY_SUMMON_HP = 400,
        RABBITKING_ABILITY_SUMMON_ATTACK_PERIOD = 3,
        RABBITKING_ABILITY_SUMMON_DAMAGE = 40,
        RABBITKING_ABILITY_DROPKICK_CD = 12,
        RABBITKING_ABILITY_DROPKICK_CD_START = 10,
        RABBITKING_ABILITY_DROPKICK_CD_NOSUMMONS = 8,
        RABBITKING_ABILITY_DROPKICK_SPEED = 12,
        RABBITKING_ABILITY_DROPKICK_MAXAIRTIME = 1,
        RABBITKING_ABILITY_DROPKICK_HITRADIUS = 1.5,
        RABBITKING_ABILITY_DROPKICK_KNOCKBACKRADIUS = 4,

        --rabbitking goodies
        ARMOR_CARROTLURE_PERISHTIME = 5 * day_time,
        ARMOR_CARROTLURE_RANGE = 12,
        ARMOR_CARROTLURE_MAXFOLLOWERS = 10,
        RABBITKINGHORN_RANGE = 12,
        RABBITKINGHORN_USES = 3,
        RABBITKINGHORN_DURATION = day_time * 0.5,
        RABBITKINGSPEAR_SCARE_RADIUS = 4,
        RABBITKINGSPEAR_DAMAGE = wilson_attack * 1.5,
        RABBITKINGSPEAR_DAMAGE_BONUS = 1.4,
        RABBITKINGSPEAR_SANITY_DELTA = -5,
        RABBITKINGSPEAR_USES = 125,

--[★ 拟态怪 ITEM MIMIC]8500-8599 行。
--  ITEMMIMIC_AUTO_REVEAL_BASE = total_day_time（第 8500 行）。
--    ★★ 名字里的 AUTO_REVEAL = 自动揭穿时长，以total_day_time 为基准。
--  *_BASE 命名规律：以 total_day_time 为基准再叠加各类修正，
--    是本文件处理「随天数变化的时长」的又一范式。
        -- Item mimic
        ITEMMIMIC_AUTO_REVEAL_BASE = total_day_time,
        ITEMMIMIC_AUTO_REVEAL_RAND = total_day_time,
        ITEMMIMIC_CAP = 10,

        -- Chest mimic
        CHEST_MIMIC_HEALTH = 950,
        CHEST_MIMIC_DAMAGE = 30,
        CHEST_MIMIC_PLANAR_DAMAGE = 20,
        CHEST_MIMIC_ATTACK_PERIOD = 3,
        CHEST_MIMIC_TARGET_DIST = 20,
        CHEST_MIMIC_WALK_SPEED = 6.0,
        CHEST_MIMIC_CHANCE = 0.33,

        SHADOWHEART_HOP_SPEED = 7.0,

        -- HallowedNights2024
        HALLOWEEN_PUMPKINCARVER_PIGKING_TRADE_CHANCE = .15,
        HALLOWEEN_PUMPKINCARVER_GRAVESTONE_CHANCE = .15,
		HALLOWEEN_PUMPKINCARVER_MAX_CUTS = 15,

        SHADOWTHRALL_PARASITE_WALKSPEED = 12,
        SHADOWTHRALL_PARASITE_RUNSPEED = 12,

        SHADOWTHRALL_PARASITE_HEALTH = 500,
        SHADOWTHRALL_PARASITE_PLANAR_DAMAGE = 5,
        SHADOWTHRALL_PARASITE_TARGET_DIST = 10,

        SHADOWTHRALL_PARASITE_BLOBOVERRIDE = 0.2,

        SHADOWTHRALL_PARASITE_MASK_ARMOR = wilson_health*20*multiplayer_armor_durability_modifier,
        SHADOWTHRALL_PARASITE_MASK_ABSORPTION = 0.2,

        SHADOWTHRALL_PARASITE_TIMEOUT = total_day_time*5,

        SHADOWTHRALL_PARASITE_WAVE_MIN = 6,
        SHADOWTHRALL_PARASITE_WAVE_VAR = 6, --6 + 6 = 12

        SHADOWTHRALL_PARASITE_WAVE_ENABLED = true,

		-- Winter's Feast 2024
		SNOWMAN_MAX_DECOR = { 5, 15, 20 },

        SNOWBALL_WATERSOURCE_FILL_USES = .3,
        SNOWBALL_MELT_MOISTURE = 1,
        SNOWBALL_MELT_MOISTURE_ITEMS = 3,
        SNOWBALL_MELT_MOISTURE_GROUND = 10,

        SNOWBALL_EFFECTS_DIST = 1.25,
        SNOWBALL_EXTINGUISH_HEAT_PERCENT = -1,
        SNOWBALL_TEMP_REDUCTION = 2,
        SNOWBALL_PROTECTION_TIME = 15,
        SNOWBALL_ADD_COLDNESS = .2,

		SNOWBALL_ROLLING_SPEED = 3,

        SNOWBALLMANAGER_SPACING = 10, -- In tiles for each world partition.
        SNOWBALLMANAGER_DENSITY = 2, -- Max number of weather created snow balls to create per partition.
        SNOWBALLMANAGER_SECONDS_PER_SPAWN = 5,
        SNOWBALLMANAGER_SECONDS_PER_DESPAWN = 0.5,

        -- Year of the Snake
        YOTS_LANTERN_POST_FUEL_MAX = total_day_time*2,
        YOTS_WORM_HEALTH = 600,
        YOTS_WORM_COUNT = 3,

        -- Wendy Skill Tree
        ABIGAIL_GESTALT_DAMAGE =
        {
            day = 100,
            dusk = 150,
            night = 250,
        },

        ABIGAIL_GESTALT_ATTACKAT_RADIUS = 4,
        ABIGAIL_GESTALT_ATTACKAT_VALID_ANGLE = 80,
        ABIGAIL_GESTALT_ATTACKAT_DAMAGE_MULT_RATE = 2/3,

        ABIGAIL_SHADOW_PLANAR_DAMAGE = 25,

        WENDYSKILL_COMMAND_COOLDOWN = 4,
        WENDYSKILL_GESTALT_ATTACKAT_COMMAND_COOLDOWN = 10,
        WENDYSKILL_ESCAPE_TIME = 1.5,
        WENDYSKILL_DASHATTACK_VELOCITY = 14.0,
        WENDYSKILL_DASHATTACK_HITRATE = 0.5,

        WENDYSKILL_SMALLGHOST_EXTRACHANCE = 0.10,
        WENDYSKILL_GRAVESTONE_DECORATECOUNT = 3,
        WENDYSKILL_GRAVESTONE_DECORATETIME = 6 * total_day_time,
        WENDYSKILL_GRAVESTONE_GHOSTCOUNT = 4,
        WENDYSKILL_GRAVESTONE_EVILFLOWERCOUNT = 3,
        WENDYSKILL_GRAVEGHOST_DEADTIME = total_day_time,
        WENDYSKILL_GRAVEGHOST_AURARADIUS = 2.5,

        WENDYSKILL_SISTURN_SANITY_MODIFYER = 0.75,
        WENDY_SISTURN_PETAL_PRESRVE = 0.5,

        GHOSTLYELIXIR_PLAYER_SLOWREGEN_HEALING = 1,
        GHOSTLYELIXIR_PLAYER_SLOWREGEN_TICK_TIME = 1,
        GHOSTLYELIXIR_PLAYER_SLOWREGEN_DURATION = 20, -- 20 hp
--[★ 幽灵精（GHOSTLYELIXIR）]8600-8699 行。
--  GHOSTLYELIXIR_PLAYER_FASTREGEN_HEALING = 5（第 8600 行）：
--    ★★ FASTREGEN = 快速回血。每秒回 5 点 —— 数值极小，
--      因为它的价值在于「持续」而非「猛烈」。
--  *_DURATION 配套（如 PLAYER_SLOWREGEN_DURATION）：
--    ★ 慢速回血配短时长，快速回血配长时长，两档互补。

        GHOSTLYELIXIR_PLAYER_FASTREGEN_HEALING = 5,
        GHOSTLYELIXIR_PLAYER_FASTREGEN_TICK_TIME = 1,
        GHOSTLYELIXIR_PLAYER_FASTREGEN_DURATION = 20, -- 100 hp

        GHOSTLYELIXIR_PLAYER_DAMAGE_DURATION = total_day_time*0.75,

        GHOSTLYELIXIR_PLAYER_SPEED_LOCO_MULT = 1.75,
        GHOSTLYELIXIR_PLAYER_SPEED_DURATION = total_day_time,
        GHOSTLYELIXIR_PLAYER_SPEED_PLAYER_GHOST_DURATION = 3,

        GHOSTLYELIXIR_PLAYER_SHIELD_DURATION = seg_time*4,
        GHOSTLYELIXIR_PLAYER_SHIELD_REDUCTION = 50,

        GHOSTLYELIXIR_PLAYER_RETALIATION_DAMAGE = 20,
        GHOSTLYELIXIR_PLAYER_RETALIATION_DURATION = total_day_time,

        GHOSTLYELIXIR_PLAYER_REVIVE_DURATION = 0.3,

        GHOSTLYELIXIR_PLAYER_DRIP_FX_DELAY = seg_time / 2,

        GHOSTGUARD_PLAYFUL_DELAY = seg_time * 0.5,
        ABIGAIL_PLAYFUL_DELAY = seg_time,

        -- Playing Cards
        PLAYINGCARDS_NUM_SUITS = 4,
        PLAYINGCARDS_NUM_PIPS = 13,

        -- Rifts 5
		DROWNING_SHALLOW_SCALE = 1 / 3, --drowning penalty scale
		DROWNING_FLOAT_SCALE = 0.2, --(if floating, it's only wetness penalty)
        DROWNING_ITEMDROP_SHALLOWS = 7,
        DROWNING_ITEMDROP_NORMAL = 5,
		FLOATING_SWIM_SPEED = 0.6,
		FLOATING_SWIM_TIME = { min = 2, max = 3 },
		FLOATING_SWIM_HUNGER_RATE_MULT = 1.25,

		ELECTROCUTE_DEFAULT_DURATION = 0.8,
        ELECTROCUTE_SHORT_DURATION = 0.4,
		ELECTROCUTE_DEFAULT_DELAY = { min = 2, max = 4 },
		ELECTROCUTE_DEFAULT_INTERRUPT_CHANCE = 0.5,

        ELECTROCUTE_FORK_RANGE = 3, --3,
        ELECTROCUTE_FORK_TARGETS = 2,
        ELECTROCUTE_FORK_DELAY = 11 * FRAMES,

		WAGDRONE_ROLLING_RUNSPEED = 9,
		WAGDRONE_ROLLING_HEALTH = 70 * 4,
		WAGDRONE_ROLLING_REGEN_AMOUNT = 5,
		WAGDRONE_ROLLING_REGEN_PERIOD = 1,
		WAGDRONE_ROLLING_DAMAGE = 50,
		WAGDRONE_ROLLING_HARDARMOR_BOUNCE_CHANCE = 0.5,
		WAGDRONE_ROLLING_USES = 2000,
		WAGDRONE_ROLLING_WORK_RADIUS = 20,
		WAGDRONE_LASERWIRE_DAMAGE = 30,
		WAGDRONE_LASERWIRE_INSULATED_DAMAGE_MULT = 0.5,

		WAGDRONE_FLYING_RUNSPEED = 7,
		WAGDRONE_FLYING_DAMAGE = 30,
		WAGDRONE_FLYING_INSULATED_DAMAGE_MULT = 0.5,

		WAGBOSS_ROBOT_HEALTH = 22500,
		WAGBOSS_ROBOT_WALKSPEED = 2,
		--WAGBOSS_ROBOT_HIT_RECOVERY = 1,
		WAGBOSS_ROBOT_ATTACK_PERIOD = { 3.5, 3, 2.5, 2 }, --threat levels
		WAGBOSS_ROBOT_ATTACK_RANGE = 3,
		WAGBOSS_ROBOT_DAMAGE = 200,
		WAGBOSS_ROBOT_PLANAR_DAMAGE = 30,
		WAGBOSS_ROBOT_KICK_DAMAGE = 50,
		WAGBOSS_ROBOT_KICK_PLANAR_DAMAGE = 10,
		WAGBOSS_ROBOT_PLAYERDAMAGEPERCENT = 0.75,

		WAGBOSS_MISSILE_DAMAGE = 75,
		WAGBOSS_MISSILE_PLANAR_DAMAGE = 10,

		WAGBOSS_BEAM_PLANAR_DAMAGE = 50, --initial hit
		WAGBOSS_BEAM_LUNAR_BURN_DPS = 40, --DOT
		WAGBOSS_BEAM_BRIGHTMARE_HEAL = 5, --Heal over time

		WAGBOSS_ROBOT_TANTRUM_CD = 15,
		WAGBOSS_ROBOT_LEAP_CD = { 7, 11 },
		WAGBOSS_ROBOT_MISSILES_CD = { 16, 20 },
		WAGBOSS_ROBOT_MISSILE_BARRAGE_PERIOD = { 1.5, 0.75, 0, 0 }, --threat levels
		WAGBOSS_ROBOT_HACK_DRONES_CD = 60,
		WAGBOSS_ROBOT_ORBITAL_STRIKE_CD = { 24, 30 },

		WAGBOSS_ROBOT_AGGRO_DIST = 15,
		WAGBOSS_ROBOT_KEEP_AGGRO_DIST = 12,
		WAGBOSS_ROBOT_DEAGGRO_DIST = 24,

		ALTERGUARDIAN_PHASE4_LUNARRIFT_HEALTH = 16000,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_WALKSPEED = 2.9,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_ATTACK_PERIOD = { 3, 2.75 },
		ALTERGUARDIAN_PHASE4_LUNARRIFT_ATTACK_RANGE = 5,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_DAMAGE = 225,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_PLANAR_DAMAGE = 35,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_PLAYERDAMAGEPERCENT = 0.75,

		ALTERGUARDIAN_LUNAR_FISSURE_LUNAR_BURN_DPS = 25, --DOT
		ALTERGUARDIAN_LUNAR_SUPERNOVA_PLANAR_DAMAGE = 50, --initial hit
--[★ 瓦格朋克 / 太阳风暴]8700-8799 行。
--  ALTERGUARDIAN_LUNAR_SUPERNOVA_LUNAR_BURN_DPS = 40, --DOT（第 8700 行）。
--    ★★ 键名极长，是**三层修饰**的结果：
--      [鬼王]_[月神太阳]_LUNAR_BURN_DPS = 鬼王在月神太阳模式下的灼烧 DPS。
--    ★ 这是本文件最长的键名范例，说明该机制经过多次叠加改造。
--    ★ 行尾标注 '--DOT' 提醒这是持续伤害，参见 7732 行的说明。
--  GESTALT_EVOLVED_PLANAR_DAMAGE = 15, -- Deprecated.（第 8750 行附近）
--    ★★ 行内标注 Deprecated（区别于整行的 '-- DEPRECATED' 标记）。
--      仍保留数值以兼容，但不再参与计算。
		ALTERGUARDIAN_LUNAR_SUPERNOVA_LUNAR_BURN_DPS = 40, --DOT

		ALTERGUARDIAN_PHASE4_SUPERNOVA_CD = 40,

		ALTERGUARDIAN_PHASE4_LUNARRIFT_AGGRO_DIST = 15,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_SHORT_AGGRO_DIST = 8,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_KEEP_AGGRO_DIST = 12,
		ALTERGUARDIAN_PHASE4_LUNARRIFT_DEAGGRO_DIST = 24,

        WAGPUNK_ARENA_WAGSTAFF_FADEIN_TIME = 1.0,
        WAGPUNK_ARENA_WAGSTAFF_FADEOUT_TIME = 2.2,
        WAGPUNK_ARENA_WAGSTAFF_TALK_TIME = 4.0,
        WAGPUNK_ARENA_WAGSTAFF_NAG_COOLDOWN_TIME = 20,
        WAGPUNK_ARENA_WAGBOSS_ROBOT_DESPAWN_GRACE_TIME = 5 * 60, -- If a player disconnects or a save is loaded.
        WAGPUNK_ARENA_WAGBOSS_ROBOT_COOLDOWN_DEFEATED_TIME = total_day_time * 20, -- If the boss is defeated.
        WAGPUNK_ARENA_COLLISION_NOBUILD_THICKNESS = 3, -- Units away from the barrier that things cannot build in and the band of destruction for breaking structures near the barrier.

        GESTALT_CAGE_FILLED_PLACEMENT_RADIUS = 2,
        WAGBOSS_ROBOT_CONSTRUCTIONSITE_KIT_PLACEMENT_RADIUS = 4,

        AXISALIGNEDPLACEMENT_INTERVALS = 1, -- Units of division for 1 game unit.
        AXISALIGNEDPLACEMENT_CIRCLESIZE = 4, -- Units for how big the circle radius ground decals are going to draw out to.
        AXISALIGNEDPLACEMENT_HELPERS_TIMETOSHOW = 0.15,
        AXISALIGNEDPLACEMENT_HELPERS_TIMETOHIDE = 0.2,
        AXISALIGNEDPLACEMENT_HELPERS_UPDATEPERIOD = FRAMES,
        AXISALIGNEDPLACEMENT_HELPERS_UPDATEAMOUNT = 15,

        WANDERINGTRADER_ENABLED = true, -- Managed by world settings.
        WANDERINGTRADER_SHOP_REFRESH_INTERVAL = total_day_time * 2,
        WANDERINGTRADER_SHOP_RANDOM_UNCOMMON_ODDS = 0.5,
        WANDERINGTRADER_SHOP_RANDOM_RARE_ODDS = 0.25,
        WANDERINGTRADER_WANDERING_PERIOD = 14,
        WANDERINGTRADER_WANDERING_PERIOD_VARIANCE = 4,
        WANDERINGTRADER_VIRTUALWALKING_SPEEDMULT = 4,

        GESTALT_TIMEOUT = 30,
        WAGBOSS_DEFEATED_GESTALT_SPAWN_FACTOR = 2,

        -- Deprecated tuning variables for GESTALT_EVOLVED kept for mods but should be removed once mods have time to catch up.
        GESTALT_EVOLVED_EXPLODE_CHANCE = 0.33, -- Deprecated.
		GESTALT_EVOLVED_MAX_DISTSQ_RELOCATE = 30*30, -- Deprecated.
        GESTALT_EVOLVED_RELOCATE_TIME_RAND = 0.5, -- Deprecated.
        GESTALT_EVOLVED_RELOCATE_TIME_BASE = 0.5, -- Deprecated.
        GESTALT_POPULATION_CHECK_TIME = 5, -- Deprecated.
		GESTALT_EVOLVED_SPAWN_COOLDOWN = 2 * seg_time, -- Deprecated.
        GESTALT_EVOLVED_MAXSPAWN = 1, -- Deprecated.
        GESTALT_EVOLVED_MAXSPAWN_INDUCED = 3, -- Deprecated.
        GESTALT_EVOLVED_MAXPOOL = 15, -- Deprecated.
        GESTALT_EVOLVED_ADDTOPOOLTIME = total_day_time, -- Deprecated.
        GESTALT_EVOLVED_REAL_DAMAGE = 165, -- Deprecated.
        GESTALT_EVOLVED_PLANAR_DAMAGE = 15, -- Deprecated.
        -- End deprecation.

        GESTALT_EVOLVED_ATTACK_DAMAGE_GROGGINESS = 0.5,
        GESTALT_EVOLVED_ATTACK_DAMAGE_KO_TIME = 1,
		GESTALT_EVOLVED_HEALTH = 600,

        GESTALT_EVOLVED_TELEPORT_COOLDOWN = 10,
        GESTALT_EVOLVED_TELEPORT_HITS_NEEDED = 3,
        GESTALT_EVOLVED_TELEPORT_TIME_INVISIBLE = 0.5,

        GESTALT_EVOLVED_CLOSE_RANGE = 4,
        GESTALT_EVOLVED_CLOSE_DAMAGE = 100,
        GESTALT_EVOLVED_CLOSE_PLANAR_DAMAGE = 10,
        GESTALT_EVOLVED_CLOSE_COOLDOWN = 3,

        GESTALT_EVOLVED_MID_RANGE = 12,
        GESTALT_EVOLVED_MID_DAMAGE = 40,
        GESTALT_EVOLVED_MID_PLANAR_DAMAGE = 15,
        GESTALT_EVOLVED_MID_COOLDOWN = 3.75,

        GESTALT_EVOLVED_FAR_RANGE = 20,
        GESTALT_EVOLVED_FAR_DAMAGE = 50,
        GESTALT_EVOLVED_FAR_PLANAR_DAMAGE = 5,
        GESTALT_EVOLVED_FAR_COOLDOWN = 4.5,
        GESTALT_EVOLVED_FAR_SPEED = 12,
        GESTALT_EVOLVED_FAR_SPLIT_ANGLE = 15, -- Degrees.

        GESTALT_EVOLVED_PLANTING_MAX_SPAWNS_PER_PLAYER = 3,
        GESTALT_EVOLVED_PLANTING_TICK_TIME = 1,
        GESTALT_EVOLVED_PLANTING_RADIUS_FROM_HAT = 8,
        GESTALT_EVOLVED_PLANTING_RADIUS_FROM_MOONGLASS = 4,
        GESTALT_EVOLVED_PLANTING_MOONGLASS_REQUIREMENT = 3,

        GESTALT_EVOLVED_LOSE_AGGRO_TIME = 10, -- Time since last hit from the non-summoner to lose the aggro.

        ARMOR_LUNACYHAT = wilson_health * 9 * multiplayer_armor_durability_modifier,
        ARMOR_LUNACYHAT_ABSORPTION = .7 * multiplayer_armor_absorption_modifier,

		ALTERGUARDIAN_PHASE1_LUNARRIFT_HEALTH = 8000,
		ALTERGUARDIAN_PHASE1_LUNARRIFT_PLANAR_DAMAGE = 30,
		ALTERGUARDIAN_PHASE1_LUNARRIFT_REVIVE_TIME = { 8, 10, 12, 14, 16 },
		ALTERGUARDIAN_PHASE1_LUNARRIFT_REVIVE_HP = 0.25,
		ALTERGUARDIAN_PHASE1_LUNARRIFT_REGEN_AMOUNT = 200,
		ALTERGUARDIAN_PHASE1_LUNARRIFT_REGEN_PERIOD = 2,

        ELECTRIC_FENCE_DAMAGE = 0,
        ELECTRIC_FENCE_MAX_LINKS = 2,
        ELECTRIC_FENCE_MAX_DIST = 10,

--【★ 分区 36 · 洞穴重构与洞穴生物】8800-9099 行
--  ★ 分区边界：ELECTRIC_FIELD（电场）与 MUTATEDBUZZARD（变异秃鹫）。
--  ELECTRIC_FIELD_HEALTH = 50（第 8800 行）：
--    ★ 电场是「安全区」概念的血量 —— 玩家修复它以驱散怪物。
--  ELECTRIC_FIELD_HEALTHREGEN_AMOUNT：电场的自动回血量。
--    ★★ HEALTH + REGEN_AMOUNT 成对出现，是「可修复目标」的通用配对，
--      全文多处（GESTALT、石像、传送门）都用这个组合。
        ELECTRIC_FIELD_HEALTH = 50,
        ELECTRIC_FIELD_HEALTHREGEN_AMOUNT = 1,
        ELECTRIC_FIELD_HEALTHREGEN_PERIOD = 2,
        ELECTRIC_FIELD_DAMAGE_TAKEN_BASE = 1, --(Omar): Base value, size of shocked mob does more 'damage' to the field, e.g. rabbit has .5 radius, 1*0.5 = .5 damage to field, or 1*1.5 for epic creatures

        ELECTRIC_FIELD_RAINDECAY_AMOUNT = -0.5,
        ELECTRIC_FIELD_RAINDECAY_PERIOD = 3,

        ELECTRIC_FIELD_MOB_PANICTIME = 2,

        RUMMAGE_COUNT_FOR_FENCE_BLUEPRINT = 10,

        RIFT_BIRD_WALKSPEED = 4,
        RIFT_BIRD_RUNSPEED = 12,
        RIFT_BIRD_DAMAGE = 10,
        RIFT_BIRD_PLANAR_DAMAGE = 10,
        RIFT_BIRD_HEALTH = 25,
        RIFT_BIRD_ATTACK_COOLDOWN = 6,
        RIFT_BIRD_ATTACK_RANGE = 2,
        RIFT_BIRD_EAT_COUNT_FOR_BRILLIANCE = 3,
        RIFT_BIRD_BRILLIANCE_TIMER = total_day_time,

        BIRD_CORPSE_MIN_SPAWN = 3,
        BIRD_CORPSE_MAX_SPAWN = 5,
        BIRD_CORPSE_MUTATE_MAX_COUNT = 2,
        BIRD_CORPSE_FADE_MIN_TIME = 12,
        BIRD_CORPSE_FADE_MAX_TIME = 20,

        BIRD_CORPSE_GESTALT_MIN_TIME = 10,
        BIRD_CORPSE_GESTALT_MAX_TIME = 12,

        BIRD_CORPSE_SPAWN_MAX = 8,

        RIFT_BIRD_FOOD_RANGE = 15,
        RIFT_BIRD_BRILLIANCE_CHANCE = 0.33,

        LUNARHAIL_LEVEL_FAIL_BIRD_BOOK = 85, -- A bit after the hail starts, birds of the world will fail.

        ASCARABUS_HEALTH = 100,
        ASCARABUS_WALKSPEED = 4,
        ASCARABUS_RUNSPEED = 6,

        MUTATEDBUZZARD_DAMAGE = 25,
        MUTATEDBUZZARD_PLANAR_DAMAGE = 25,
        MUTATEDBUZZARD_ATTACK_RANGE = 10,
        MUTATEDBUZZARD_HIT_RANGE = 2,
        MUTATEDBUZZARD_ATTACK_PERIOD = 1.5,
        MUTATEDBUZZARD_WALK_SPEED = 4,
        MUTATEDBUZZARD_RUN_SPEED = 8,
        MUTATEDBUZZARD_HEALTH = 150 * 2, -- harder for multiplayer
        MUTATEDBUZZARD_FLAMETHROWER_CD = 7,
        MUTATEDBUZZARD_FLAMETHROWER_CD_VARIANCE = 2,
        MUTATEDBUZZARD_FIND_TARGET_DIST = 10,

        BIRD_SPAWNER_POST_HAIL_TIME = 6 * total_day_time,

        SHADOWTHRALL_CENTIPEDE = {
            HEALTH = 2000,

            DAMAGE = 150,
            PLANAR_DAMAGE = 50,
            PLAYERDAMAGEPERCENT = 0.5, --Does not apply to planar!

            MOVESPEED = 5,
            RUNSPEED = 10,
            TURNSPEED = 1.5,
            MAX_SEGMENTS = 20,

            -- Brain stuff

            FIND_MIASMA_DIST = 10,
            WANDER_DIST = 6,

            EAT_MIASMA_MAX = 5, -- 5 at a time before going on delay.
            EAT_DELAY = seg_time * 2,

            ANGLE_INTERACT_WIDTH = 180 / RADIANS, -- must be in radians
        },

        TREE_ROCK = {
            MINE = 6,
            MINE_MED = 4,
            MINE_LOW = 2,

            AOE_DAMAGE = 150,

            ROCK1_AOE_RADIUS = 2,
            ROCK2_AOE_RADIUS = 3.25,

            ROCK1_AOE_DAMAGE = 200,
            ROCK2_AOE_DAMAGE = 100,

            BURN_TIME = 3,

            PLAYERDAMAGEPERCENT = 1/4,

            BOULDER_GEN_CHANCE = 1/3,

            CHOP = 5,

--【★★ 洞穴重构 —— 分区边界】8900 行起是洞穴的新版生成参数。
--  GROW_TIME = （第 8900 行）：四元嵌套表模板（short/normal/tall/old），
--    与第 788 行 EVERGREEN_GROW_TIME 结构完全相同。
--    ★★ 再遇同一模板 ⇒ 该模板在文件内被反复复用，
--      读懂一处即可读懂全部（见第 780 行的完整结构说明）。
--    ★ 注意这一行是「表的开头」，具体元素在后续行。
            GROW_TIME =
            {
                {base=1.5*day_time, random=0.5*day_time},   --short
                {base=5*day_time, random=2*day_time},       --normal
                {base=5*day_time, random=2*day_time},       --tall
                {base=1*day_time, random=0.5*day_time}      --old
            },

            SAPLING_GROW_TIME = {base=4*day_time, random=1*day_time},
        },

        -- Rock trees only have desolation regrowth
        TREE_ROCK_REGROWTH = {
            OFFSPRING_TIME = total_day_time * 8,
            DESOLATION_RESPAWN_TIME = total_day_time * 50,
            DEAD_DECAY_TIME = total_day_time * 30, --NOTE: no decay.
        },

        TREE_ROCK_REGROWTH_TIME_MULT = 1,

        CAVE_VENTS = {
            MINE = 6,
            MINE_MED = 4,
            MINE_LOW = 2,

            SPEW_TIME = {
                HOT = {
                    BASE = seg_time * 3,
                    VARIANCE = seg_time * 2,
                },
                MIASMA = {
                    BASE = seg_time * 6,
                    VARIANCE = seg_time * 3,
                },
                GAS = {
                    BASE = seg_time * 5,
                    VARIANCE = seg_time * 1,
                },
            },

            HEAT =
            {
                HOT_ACTIVE = 120,
                MIASMA_ACTIVE = 90,
                INACTIVE = 10,
                COLD_ACTIVE = -120,
            },
        },

        OCEANWHIRLBIGPORTAL_FOCALRADIUS = 4,
        OCEANWHIRLBIGPORTAL_RADIUS = 14,
        OCEANWHIRLBIGPORTAL_PULLSTRENGTH = 10,
        OCEANWHIRLBIGPORTAL_RADIALSTRENGTH = 20,
        OCEANWHIRLBIGPORTAL_BOAT_PERCENT_DAMAGE_PER_TICK = 0.1,

        OCEANWHILRBIGPORTALEXIT_LOOT_PER_PICK = 3,
        OCEANWHILRBIGPORTALEXIT_ITEMS_TO_MAKE_BIG = 30,

        FLOWER_CAVE_WITHERED_LIGHT_TIME = 20,
        FLOWER_CAVE_WITHERED_RECHARGE_TIME = 200,

        CAVE_MITE_HEALTH = 200 * 2, -- harder for multiplayer
        CAVE_MITE_WALK_SPEED = 2,
        CAVE_MITE_RUN_SPEED = 3,
        CAVE_MITE_DAMAGE = 25,
        CAVE_MITE_PLANAR_DAMAGE = 10,
        CAVE_MITE_ATTACK_PERIOD = 4,
        CAVE_MITE_ATTACK_RANGE = 3,
        CAVE_MITE_HIT_RANGE = 4,
        CAVE_MITE_TARGET_DIST = 8,
        CAVE_MITE_SHELL_ABSORB = 0.05, --95%
        CAVE_MITE_HEAT_ACTIVE = 120,
        CAVE_MITE_BLOW_COOLDOWN = 8,
        CAVE_MITE_BLOW_DISTANCE = 4,
        CAVE_MITE_BLOW_DISTANCE_SQ = 4*4,
        CAVE_MITE_BLOW_DISTANCE_SQ_MIN = 2*2,

        CAVE_MITE_BLOW_HEAT_RATE = {
            COLD = 5,
            NORMAL = 25,
            HOT = 40, --This is essentially the default.
        },

        CAVE_MITE_SHIELD_COOLDOWN = 30,
        CAVE_MITE_SHIELD_COOLDOWN_VARIANCE = 20,

        CAVE_MITE_SHIELD_TIME = 10,
        CAVE_MITE_SHIELD_TIME_VARIANCE = 140,

        CAVE_MITE_MAX_CHASE_TIME = 16,
        CAVE_MITE_SEE_FOOD_DIST = 10,
        CAVE_MITE_MAX_WANDER_DIST = 32,
        CAVE_MITE_DAMAGE_UNTIL_SHIELD = 25,
        CAVE_MITE_SHIELD_ATTACK_TIME = 5,

        CAVE_MITE_RELEASE_TIME = 20,
        CAVE_MITE_REGEN_TIME = total_day_time,
        CAVE_MITE_MAX_CHILDREN = 3,
        CAVE_MITE_ENABLED = true,

--[★ 洞穴生物]9000-9099 行。
--  CAVE_MITE_SPAWN_RADIUSSQ = 16 * 16（第 9000 行）：
--    ★★ = 256。注意这不是 256 而是「16 的平方」，即半径 16 格。
--      写法保留平方语义（见第 4020 行说明）。
--    ⚠ 陷阱：若误读为「半径 256 格」，整个洞穴都会被覆盖。
--  MUTATEDBUZZARD_DEATHATTRACTION_TIME = total_day_time * 0.5（第 9050 行）：
--    = 240 秒。★「死亡吸引」时长 —— 死亡后仍吸引变异体的时长。
        CAVE_MITE_SPAWN_RADIUSSQ = 16 * 16,

        PRERIFT_MUTATION_SPAWN_CHANCE = 0.5,
        PRERIFT_MUTATION_SPAWN_DELAY_BASE = 4,
        PRERIFT_MUTATION_SPAWN_DELAY_VARIANCE = 1,

        SPIDER_PRERIFT_MUTATION_SPAWN_CHANCE = 1 / 3, -- 33.333%~
        SPIDER_WARRIOR_PRERIFT_MUTATION_SPAWN_CHANCE = 0.5,

        BIRD_PRERIFT_MUTATION_SPAWN_CHANCE = 1,

        CORPSE_REMOVE_ON_SLEEP_TIME = 10,

        -- Halloween 2025

		--V2C: O.G. spooked was tuned for each individual CHOP
		--     mining/digging only triggers TryCustomSpook on state changes
		MINE_SPOOKED_MULT_HIGH = 0.315,
		MINE_SPOOKED_MULT_LOW = 0.1,
		DIG_SPOOKED_MULT = 0.456,

        -- Migrations are per node
        RIFT_BIRD_MIGRATE_TIME_BASE = seg_time,
        RIFT_BIRD_MIGRATE_TIME_VAR = seg_time * 0.5,

        RIFT_BIRD_MIGRATE_TIME_RAIN_FACTOR = 1 / 4, -- Rain lengthens migration by 4x

        RIFT_BIRD_MIGRATE_TIME_MOONPHASE_FACTOR =
        {
            ["new"] = 0.6,
            ["quarter"] = 0.75,
            ["half"] = 1,
            ["threequarter"] = 1.25,
            ["full"] = 1.5,
        },

        RIFT_BIRD_MIGRATE_TIME_NON_NIGHT_FACTOR = 1 / 1.5,

        MUTATEDBUZZARD_MIGRATE_TIME_BASE = seg_time*4,
        MUTATEDBUZZARD_MIGRATE_TIME_VAR = seg_time*2,
        MUTATEDBUZZARD_FIND_CORPSE_DELAY = 10,
        MUTATEDBUZZARD_CORPSE_RANGE = 25, -- mobs die within this range of a buzzard to be corpsed
        MUTATEDBUZZARD_ENTER_MIGRATION_ON_SLEEP_TIME = 20,
        MUTATEDBUZZARD_MAX_TARGET_COUNT = 3, -- 3 buzzards can share a target, the rest should EAT!

        MUTATEDBUZZARD_FLAMETHROWER_DAMAGE = 15,
        MUTATEDBUZZARD_FLAMETHROWER_PLANAR_DAMAGE = 10,

        MUTATEDBUZZARD_MEGAFLARE_NODE_WEIGHT = 10,
        MUTATEDBUZZARD_MEGAFLARE_TIME = total_day_time,

        MUTATEDBUZZARD_DEATHATTRACTION_TIME = total_day_time * 0.5,
        MUTATEDBUZZARD_DEATHATTRACTION_WEIGHT = 0.25,

        -- Kill buzzards in the hail level between 20 and 35
        BUZZARDSPAWNER_KILL_BUZZARDS_LUNAR_HAIL_BASE = 20,
        BUZZARDSPAWNER_KILL_BUZZARDS_LUNAR_HAIL_VAR = 15,

        BUZZARDSPAWNER_FLARE_HIT_DIST_SQ = 25 * 25,

        TALL_FLAMEWALL_BASE_TIME = 2.5,
        TALL_FLAMEWALL_VAR_TIME = 0.5,

        ICED_EMBER_BASE_TIME = 11,
        ICED_EMBER_VAR_TIME = 1,
        ICED_EMBER_SLIPPERY_RATE = 20,

        SPAWN_MOON_PENGULLS = true,
        SPAWN_MUTATED_HOUNDS = true,
        SPAWN_MUTATED_MERMS = true,
        SPAWN_MUTATED_SPIDERQUEEN = true,
        SPAWN_MUTATED_BIRDS = true,
        SPAWN_MUTATED_BIRDS_GESTALT = true,
        SPAWN_MUTATED_BUZZARDS_GESTALT = true,
        SPAWN_MUTATED_DEERCLOPS = true,
        SPAWN_MUTATED_BEARGER = true,
        SPAWN_MUTATED_WARG = true,

        CREATURE_CARCASS_MEAT_PER_LEVEL = -- 3 levels
        {
            ["tiny"] = 2,
            ["small"] = 6,
            ["med"] = 14,
            ["large"] = 33, -- pretend this goes up nicely to 100 with the 3 levels :)
        },

        BIRD_RIFT_POSSESSION_SPAWN_CHANCE = 1 / 20,

        -- Winter 2025

        HERMITCRABTEA_USES = 10,

        HERMITCRABTEA_HOT_BONUS_TEMP = 40,
        HERMITCRABTEA_COLD_BONUS_TEMP = -40,

        HERMITCRABTEA_TEMP_TIME = seg_time * 4,

        SHELLWEAVER_COOK_TIME = 6,

        NONSLIPGRIT_TOTAL_USE_TIME = seg_time * 6,
--[★ 商店与装饰（Hermit Crab）]9100-9199 行。
--  NONSLIPGRITBOOSTED_NUMBER_OF_POOLS = 25（第 9100 行）：
--    ★ COUNT 类参数（数量），非时长。与时间无关，用绝对值。
--  HERMITCRAB_SHELL_ADD_WETNESS = 15（第 9115 行）：
--    ★★ 又一个 WETNESS 相关键（见第 87、4381 行）——
--      同名概念在本文件出现于至少 4 处不同上下文，读表须看清归属。
        NONSLIPGRITBOOSTED_NUMBER_OF_POOLS = 25,
        NONSLIPGRITBOOSTED_POOL_TIME = seg_time * 2,

        DESICCANT_HELD_TEMPERATURE = 15, -- if owner isnt dry, this applies
        DESSICANT_MIN_TEMPERATURE = 20,
        DESSICANT_THRESHOLD_TEMPERATURE = 55,
        DESICCANT_DRY_RATE = 0.5,
        DESICCANTBOOSTED_DRY_RATE = 0.75,
        MOISTUREABSORBER_RAINED_ON_EFFICIENCY_MULT = 0.07,

        SALTY_DOG_TIME_TO_SALT = seg_time * 2,
        SALTY_DOG_MAX_SALT_COUNT = 2,

        HERMTICRAB_SHELL_RANGE = 12,
        HERMITCRAB_SHELL_USES = 10,
        HERMITCRAB_SHELL_ADD_WETNESS = 15,

        HERMITCRAB_PETALTEA_SANITY_DELTA = 1,
		HERMITCRAB_PETALTEA_TICK_RATE = 1,
		HERMITCRAB_PETALTEA_DURATION = seg_time * 1.5,

        HERMITCRAB_EVILPETALTEA_SANITY_DELTA = -2,
		HERMITCRAB_EVILPETALTEA_TICK_RATE = 1,
		HERMITCRAB_EVILPETALTEA_DURATION = seg_time * 2,

        HERMITCRAB_TILLWEEDTEA_HEALTH_DELTA = 1,
		HERMITCRAB_TILLWEEDTEA_TICK_RATE = .5,
		HERMITCRAB_TILLWEEDTEA_DURATION = seg_time * .5,

		HERMITCRAB_FORGETMELOTTEA_SANITY_DELTA = 2,
		HERMITCRAB_FORGETMELOTTEA_TICK_RATE = 1,
		HERMITCRAB_FORGETMELOTTEA_DURATION = seg_time * 1.5,

        HERMITCRAB_FOLIAGETEA_DURATION = seg_time * 6,
        HERMITCRAB_FOLIAGETEA_SANITY_MOD = 0.1,

        HERMITCRAB_MOONTREEBLOSSOMTEA_DURATION = seg_time * 6,
        HERMITCRAB_MOONTREEBLOSSOMTEA_PANIC_SHADOWCREATURE_TIME = seg_time,

        HERMITCRAB_DECOR_UPDATE_TIME = 10, -- recount score every 10 seconds.
        HERMITCRAB_DECOR_MAX_SCORE = 100,
        HERMITCRAB_DECOR_RADIUS = 32,

        HERMITCRAB_DECOR_MAX_TILE_SPACE = 100,
        HERMITCRAB_DECOR_TILE_SCORE = .15,
        HERMITCRAB_DECOR_TILE_SCORE_LOW = .10,
        HERMITCRAB_DECOR_TILE_SCORE_MAX = 100 * .15, -- max tile space * highest tile score

        -- Get a big boost for having ONE of these structures at least
        HERMITCRAB_DECOR_UNIQUE_BOOSTS =
        {
            ["hermitcrab_teashop"] = 10,
            ["hermithotspring"] = 10,
            ["tacklestation"] = 3,
            ["shellweaver"] = 3,
        },

        HERMITCRAB_DECOR_SPAWNER_SCORE_GRAVE = -3, -- Scary and morbid! :(
        HERMITCRAB_DECOR_SPAWNER_SCORE = -1,
        HERMITCRAB_DECOR_SPAWNER_SCORE_MIN = -33,

        HERMITCRAB_DECOR_TABLE_SCORE = 2,
        HERMITCRAB_DECOR_TABLE_ITEM_SCORE = 5,
        HERMITCRAB_DECOR_TABLE_SCORE_MAX = 15,

        HERMITCRAB_DECOR_JUNK_SCORE = -.5,
        HERMITCRAB_DECOR_JUNK_SCORE_MIN = -50, -- Junk can only subtract 50,

        HERMITCRAB_DECOR_DOCKPOST_SCORE = .5,
        HERMITCRAB_DECOR_DOCKPOST_SCORE_MAX = 10,

        HERMITCRAB_DECOR_POTTEDPLANT_SCORE = 1,
        HERMITCRAB_DECOR_POTTEDPLANT_SCORE_MAX = 10,

        HERMITCRAB_DECOR_TROPHY_SCALE_FISH_SCORE = 0.012, -- per weight value,
        HERMITCRAB_DECOR_ALL_FISH_SCORE = 20, -- Congrats! you got all the fish!

        HERMITCRAB_DECOR_CHAIR_SCORE = 2,
        HERMITCRAB_DECOR_CHAIR_SCORE_MAX = 8,

        HERMITCRAB_DECOR_MEAT_RACK_SCORE = 1, -- this is per slot
        HERMITCRAB_DECOR_MEAT_RACK_SCORE_MAX = 9,

        HERMITCRAB_DECOR_PICKABLE_SCORE = .5,
        HERMITCRAB_DECOR_PICKABLE_SCORE_MAX = 10,

        HERMITCRAB_DECOR_LIGHTPOST_SCORE = 1/3,
        HERMITCRAB_DECOR_LIGHTPOST_ON_SCORE = 1,
        HERMITCRAB_DECOR_LIGHTPOST_SCORE_MAX = 10,

        HERMITCRAB_DECOR_BEEBOX_SCORE = 1,
        HERMITCRAB_DECOR_BEEBOX_SCORE_MAX = 5,

        HERMITCRAB_DECOR_FLOWER_SCORE = .5,
        HERMITCRAB_DECOR_FLOWER_SCORE_MAX = 5,

        HERMITCRAB_DECOR_CRITTER_PET_SCORE = 5,

        HERMITCRAB_DECOR_WATER_TREE_SCORE = 15,
        HERMITCRAB_DECOR_WATER_TREE_SCORE_MAX = 15,
--[★ 洞穴装饰与装饰评分]9200-9299 行。
--  HERMITCRAB_DECOR_WATER_TREE_TILE_COVERAGE_MIN = 10（第 9200 行）：
--    ★★ COVERAGE_MIN = 最小覆盖率，_MIN 后缀表示「不低于」的下限约束。
--    ★ 商店装饰的评分算法：占地越少、装饰越多，得分越高。
        HERMITCRAB_DECOR_WATER_TREE_TILE_COVERAGE_MIN = 10,

		HERMITCRAB_DECOR_LVL5_HOUSE = 5,
		HERMITCRAB_DECOR_ORNAMENT_SCORE = 2,
		HERMITCRAB_DECOR_WINTER_ORNAMENT_SCORE = 4,
		HERMITCRAB_DECOR_WAGSTAFF_ORNAMENT_SCORE = 8,

		HERMITCRAB_DECOR_WINTER_BONUS_SCORE = 2,

        HERMITCRAB_DECOR_HAPPY_SCORE = 90,

        HERMITCRAB_DECOR_FISHING_BLOCKED_SCORE = -4, -- -4 points for each fishing marker covered. 16 markers x -4 = -64 decor points lost.
        HERMITCRAB_DECOR_FISHING_BLOCKED_SCORE_MIN = -64, -- -4 * 16

		HERMITHOTSPRING_BATHBOMB_DURATION = total_day_time,
        HERMITHOTSPRING_TICK_PERIOD = 1,
        HERMITHOTSPRING_SANITY_PER_SECOND = 2,
        HERMITHOTSPRING_HEALTH_PER_SECOND = 2,

        HOTSPRING_TICK_PERIOD = 1,
        HOTSPRING_SANITY_PER_SECOND = 1,
        HOTSPRING_HEALTH_PER_SECOND = 1,
		HERMITCRAB_HOTSPRING_SOAK_TIME = 30,
		HERMITCRAB_HOTSPRING_HAPPY_SOAK_TIME = 60,

        MOONSTORM_SPARKCHARGE_DEFAULT = 0.1,

        WINTERSURPRISE_SPAWN_DELAY = total_day_time * 2,
        WINTERSURPRISE_SPAWN_DELAY_VARIANCE = total_day_time * 1,
        WINTERSURPRISE_MAX_SPAWNS = 3,
        SPAWN_WINTERSURPRISE = true,

		RETURN_ITEM_TO_FEEDER_RANGE = 4,

        -- Year of the Clockwork Knight

        YOTH_CHARLIE_STAGE_RESET_TIME = total_day_time*2,
        YOTH_CHARLIE_STAGE_RESET_TIME_VARIABLE = total_day_time*1,

        YOTH_KNIGHT_ATTACK_PERIOD = 2,
        YOTH_KNIGHT_DAMAGE = 40,
        YOTH_KNIGHT_HEALTH = 300 * 3, -- harder for multiplayer
		YOTH_KNIGHT_JOUST_RANGE = { min = 6, max = 14 },
        YOTH_KNIGHT_WALK_SPEED = 5,
		YOTH_KNIGHT_JOUST_SPEED = 8,
        YOTH_KNIGHT_TARGET_DIST = 20,
        YOTH_KNIGHT_TIME_TO_FLEE = 2,
        YOTH_KNIGHT_FLEE_RADIUS = ENTITY_POPOUT_RADIUS / 2,
        YOTH_KNIGHT_MAX_CHASE_TIME = 5,
        -- the knights armor
        YOTH_KNIGHT_DAMAGE_TAKEN_MULT_PLAYER = 0.8,
        YOTH_KNIGHT_DAMAGE_TAKEN_MULT = 0.15,

        YOTH_PRINCESS_SUMMON_COOLDOWN = total_day_time * 3,

        YOTH_LANCE_ATTACK_DAMAGE = wilson_attack * 1.5,
        YOTH_LANCE_CHARGE_DAMAGE = wilson_attack * 2,
        YOTH_LANCE_USES = 200,
        YOTH_LANCE_JOUST_SPEED = 10,
        YOTH_LANCE_LENGTH = 2,-- Matched up to art.
        YOTH_LANCE_RUNANIM_LOOP_COUNT = 2, -- Number of run cycles to go through.

        ARMOR_YOTH_KNIGHTHAT = wilson_health*6*multiplayer_armor_durability_modifier,
        ARMOR_YOTH_KNIGHTHAT_ABSORPTION = .9*multiplayer_armor_absorption_modifier,

        ARMOR_YOTH_KNIGHT = wilson_health*8*multiplayer_armor_durability_modifier,
        ARMOR_YOTH_KNIGHT_ABSORPTION = .9*multiplayer_armor_absorption_modifier,

        MASK_PRINCESSHAT = wilson_health*1*multiplayer_armor_durability_modifier,
        MASK_PRINCESSHAT_ABSORPTION = .6*multiplayer_armor_absorption_modifier,

        COSTUME_PRINCESS_BODY = wilson_health*1*multiplayer_armor_durability_modifier,
        COSTUME_PRINCESS_BODY_ABSORPTION = .6*multiplayer_armor_absorption_modifier,

        YOTH_HECKLER_SHRINE_LEAVE_BASE = 15,
        YOTH_HECKLER_SHRINE_LEAVE_VARIANCE = 10,

        YOTH_HECKLER_SHRINE_RETURN_BASE = total_day_time,
        YOTH_HECKLER_SHRINE_RETURN_VARIANCE = seg_time * 2,

        WES_LUCK = -1,
        YOTH_PRINCESS_SETBONUS_LUCK = -1,
        YOTH_KNIGHT_SETBONUS_LUCK = 0.2,
        YOTH_KNIGHT_SETBONUS_EVENT_LUCK = 1, -- 1 luck value when the event is active
        HORSESHOE_LUCK = 0.05,
        HORSESHOE_SETBONUS_LUCK = 0.10, -- The amount of luck from horseshoe when we have the yoth knight setbonus
        HORSESHOE_EVENT_LUCK_MULTIPLIER = 3, -- Extra luck when the event is active.
        BLACKCATFISH_LUCK = -0.25,

        FLOATINGLANTERN_LEVELS = { 12, 9, 6, 2 }, -- These are the target heights.
        FLOATINGLANTERN_DURATION = total_day_time * 2,

        YOTH_KNIGHTSTICK_PERISHTIME = 6 * total_day_time,
        YOTH_KNIGHTSTICK_PERISHTIME_ON_SLIP = -(6 * total_day_time * 0.01), -- 1%
        YOTH_KNIGHTSTICK_PERISHTIME_ON_COLLIDE = -(6 * total_day_time * 0.02), -- 2%
        YOTH_KNIGHTSTICK_MAX_GALLOPS = 30,
        YOTH_KNIGHTSTICK_TIME_TO_GALLOP = 0.6,
        YOTH_KNIGHTSTICK_GALLOP_HUNGER_RATE_MULT = 1.33,
        YOTH_KNIGHTSTICK_MAX_STRESS_ROTATION = 60,
        YOTH_KNIGHTSTICK_TRACK_ROTATION_TIME = 15 * FRAMES,
--[★ YOTH（犹多）与近年追加】9300-9580 行
--  YOTH_KNIGHT_DAMAGE_TAKEN_MULT_PLAYER = 0.8（第 9250 行附近）：
--    ★★ MULT_PLAYER = 只对玩家生效的伤害倍率。
--    ★ 与第 610 行 ROOK_DAMAGE_PLAYER_PERCENT 同属「对玩家特化」写法。
--  ★★ 这类「只改玩家、不改 AI」的参数是「战斗手感调整」的主要手段，
--      因为改AI 会连带影响世界难度与资源产出。
        YOTH_KNIGHTSTICK_TRACK_ROTATION_MIN = 2,
		YOTH_KNIGHTSTICK_SPEED_MULT = { min = 1.15, max = 1.6 },
        YOTH_KNIGHTSTICK_WORK_COLLIDE = 0.05,

        FLOATINGLANTERN_RAIN_RATE = 1.5,
        FLOATINGLANTERN_LUNARHAIL_RATE = 35, -- Shred that paper!
        FLOATINGLANTERN_OUT_OF_BOUNDS_RATE = 100, -- Shoo! be destroyed quick if we're out of bounds!

		CLOCKWORK_HEALTH_REGEN_DELAY = 6, --seconds
		CLOCKWORK_HEALTH_REGEN_PERIOD = 3,
		CLOCKWORK_HEALTH_REGEN = 15,

        -- Lots of old content's values pulled to tuning for luck.
        SHADOW_TENTACLE_RUINS_BAT_CHANCE = 0.2,
        SHADOW_TENTACLE_SLINGSHOTAMMO_CHANCE = 0.5,
        SHADOW_TENTACLE_SLINGSHOTAMMO_EXTRA_TENTACLE_CHANCE = 0.25,

        PLAYER_DROP_WET_TOOL_CHANCE_MAX = 0.15,

        GHOSTLYELIXIR_EXTRA1_CHANCE = 0.4,
        GHOSTLYELIXIR_EXTRA2_CHANCE = 0.1,

        CARNIVAL_CROWKID_TOSS_REWARD_CHANCE = 0.25,

        CRITTER_NUZZLE_CHANCE = 0.05,

        LUNARHAIL_MUTATE_BIRD_CHANCE = 0.25, -- regular mutation

        DEERCLOPS_MEGAFLARE_SPAWN_CHANCE = 0.6,
        PIRATERAID_MEGAFLARE_SPAWN_CHANCE = 0.6,

        BEARGER_MULTISHED_CHANCE = 0.2,

        FEED_BIRD_POOP_CHANCE = 0.33,

        BIRD_DROP_SEEDS_CHANCE_ONEYEAR = 0.8,
        BIRD_DROP_SEEDS_CHANCE_PASTONEYEAR = 0.6,
        BIRD_DROP_ITEM_BASE_CHANCE = 0.35,

        BULLKELP_ROOT_SNAP_CHANCES =
        {
            HIGH = 1.0,
            MED = 0.3,
            LOW = 0.1,
        },

        CARNIVAL_SEEDPACKET_EXTRA_SEED_CHANCE = 0.1,

        CHESSJUNK_SPAWNSCION_CHANCE = 0.1,

        FARMPLANT_SPAWN_FRUITFLY_ON_WEED_CHANCE = 0.05,

        SPAWN_GINGERDEADPIG_CHANCE = 0.3, -- Also comes with an extra winter feast fuel

        DROP_SHADOWTHRALL_MASKHAT_CHANCE = 0.3,

        MAGIC_PROTOTYPER_MAXWELL_SPAWN_RABBIT_CHANCE = 0.25,
        MAGIC_PROTOTYPER_SPAWN_RABBIT_CHANCE = 0.1,

        MALBATROSS_SPAWNFEATHER_ONATTACKED_CHANCE = 0.05,

        MARBLESHRUB_MED_MARBLEBEAN_CHANCE = 0.75,
        MARBLESHRUB_TALL_MARBLEBEAN_CHANCE = 0.5,

        OASISLAKE_WETPOUCH_CHANCE = 0.6,

        SHARKBOI_GIVE_WINTERLIGHTORNAMENT_CHANCE = 0.4,

        SPIDERQUEEN_SPAWN_BETTER_SPIDER_CHANCE = 0.45, -- spider warrior or spider healer
        SPIDERQUEEN_SPAWN_SPIDER_WARRIOR_CHANCE = 0.5,

        STATUERUINS_SPAWN_NIGHTMARE_CHANCE = 0.3,

        WALRUS_INVESTIGATE_MEGAFLARE_CHANCE = 0.6,

        ALTERGUARDIAN_SPAWN_LARGE_GESTALT_PROJECTILE_CHANCE = 0.4,

        BRIGHTMARE_SPAWN_INC_CHANCES =
        {
            HIGH = 0.4,
            MED = 0.3,
            LOW = 0.2,
        },

        MONKEY_FOLLOW_PLAYER_CHANCE = 0.15,
        MONKEY_FOLLOW_PLAYER_WITH_BANANA_CHANCE = 0.6,
        --

        -- Meta 6

        WX78_INITIAL_MAXCHARGELEVEL = 6,
        WX78_MAXCHARGELEVEL_SKILL = 7,

        WX78_CHARGE_SMALL = 1,
        WX78_CHARGE_MED = 3,
        WX78_CHARGE_LARGE = 6,

        WX78_MODULE_CONSUMPTION = 1,

        WX78_MUSIC_RANGE = 12,
--[★ 韦斯音频与农场补充]9400-9499 行。
--  WX78_LIGHT_RADIUS_PER_MODULE = 1.25（第 9400 行）：
--    ★ 每块模块增加 1.25 格光照半径 —— 线性叠加。
--  FARMPLANT_SPAWN_FRUITFLY_ON_WEED_CHANCE = 0.05（第 9350 行附近）：
--    ★ 农场植物杂草上刷出果蝇的概率 = 5%，属「虫害惩罚」。

        WX78_LIGHT_RADIUS_PER_MODULE = 1.25,

        WX78_WATER_THRESHOLD_ADD = 5,

        WX78_RADAR_EXTRA_VIEW_DIST = 5,

        WX78_SCREECH_RANGE = 12,
        WX78_SCREECH_PANIC_TIME = 8,
        WX78_SCREECH_TIME = 2,
        WX78_SCREECH_TIME_VAR = FRAMES * 10,
        WX78_SCREECH_COOLDOWN = 20,

        WX78_DIGESTION_SPOILED_NEEDED = 5, -- number needed to produce the brick.

        WX78_SHIELDING_ARMOR = 0.2, -- 80%
        WX78_SHIELDING_COOLDOWN = 20,
        WX78_SHIELDING_TOTAL_DAMAGE = 100, -- we can take 100 damage before getting knocked out the state.
        WX78_SHIELDING_MIN_TIME_COOLDOWN = 5, -- Minimum number of time we can be in the state before going off cooldown.

		WX78_SPIN_AOE_DIMINISHING = 0.5,
		WX78_SPIN_EFFICIENCY_DECAY = 0.5,
		WX78_SPIN_EFFICIENCY_DECAY_2 = 0, --0 mult means only 1 target costs usage per swing
		WX78_SPIN_PICK_EFFICIENCY = 0.2, --base mult for picking
		WX78_SPIN_RUNSPEED_MULT = 0.6, --mult of current runspeed (including any speed boosts)
		WX78_SPIN_SLIPPERY = 6,
		WX78_SPIN_RADIUS = 2.1,
		WX78_SPIN_START_RANGE = 3, --for attacks, start wind-up a bit early
		WX78_SPIN_TIME_TO_DIZZY = 8,
		WX78_SPIN_TIME_TO_DIZZY_2 = 12,
		WX78_SPIN_DIZZY_RECOVER_TIME = 4,

        WX78_FOODBRICK_FERTILIZE = day_time*0.75,
        WX78_FOODBRICK_SOILCYCLES = 8,
        WX78_FOODBRICK_WITHEREDCYCLES = 0.5,

		CLOCKWORK_MAX_FOLLOWING = 2, --per type
		CLOCKWORK_MAX_FOLLOWING_CHESSFRIEND = 3,

        -- Rifts 7

        VAULT_ORB_REFINED_DETECTION_RADIUS = 16,

        PLANTMOB_BURNTIME_MULT = 4/3,
        PLANTMOB_FIRE_DAMAGE_SCALE = 1.25,

        OCEAN_AMBIENT_TEMPERATURE_PENALTY = -50,
        OCEAN_TEMPERATURE_PENALTY_PERCENT = 1/3, -- initial temperature level(percent between min and maxtemp) when things enter ocean
        FLOATER_HOT_SIZZLE_THRESHOLD = .25,

        FUMAROLETOOL_NUMUSES = 4,
        FUMAROLETOOL_STARTING_TEMP = 90,
        FUMAROLETOOL_STARTING_MOISTURE_PENALTY = 60,
        FUMAROLETOOL_MINTEMP = 0,
        FUMAROLETOOL_MAXTEMP = 90,
        FUMAROLETOOL_TEMP_MODIFIER = -30,
        FUMAROLETOOL_TEMPS = { 0, 20, 40, 60 },
        FUMAROLETOOL_LIGHTOVERRIDES = { 0, 0, .15, .35 },
        FUMAROLETOOL_FREEZING_DAMAGE_MULTS = { 1, 1, 1.25, 2 }, -- partially frozen
        FUMAROLETOOL_FROZEN_DAMAGE_MULTS = { 1, 1, 1.5, 3 },
        FUMAROLETOOL_HEATING_THRESHOLD = 5,
        FUMAROLETOOL_HEATING_MINTHRESHOLD = 2,

        -- NOTES:
        -- AXE_USES = 100,
        -- HAMMER_USES = 75, -- 25% less than axe
        -- SHOVEL_USES = 25, -- quarter of axe
        -- PITCHFORK_USES = 25, -- quarter of axe
        -- FARM_HOE_USES = 25, -- quarter of axe
        -- PICKAXE_USES = 33, -- third of axe

        FUMAROLEAXE_HEAT_ON_USE = -0.2, -- base
        FUMAROLEPICKAXE_HEAT_ON_USE = -0.2 * 3, -- 3x more
        FUMAROLESHOVEL_HEAT_ON_USE = -0.2 * 4, -- 4x more
        FUMAROLEHAMMER_HEAT_ON_USE = -0.2 * (4/3), -- 1.33x more
        FUMAROLEHOE_HEAT_ON_USE = -0.2, -- 4x more

        FUMAROLEAXE_EFFECTIVENESS = { 1, 1, 1.25, 1.5 },
        FUMAROLEPICKAXE_EFFECTIVENESS = { 1, 1, 1.25, 1.5 },
        FUMAROLESHOVEL_EFFECTIVENESS = { 1, 1, 1.25, 1.5 }, -- We have nothing that takes more than 1 work dig, so who knows how this should be balanced :shrug:
        FUMAROLEHAMMER_EFFECTIVENESS = { 1, 1, 1.25, 1.5 },
        -- no effectiveness for garden hoe!

        TRAP_FUMAROLE_DAMAGE = 10, -- 10 fire damage every second
        TRAP_FUMAROLE_MINTEMP = 0,
        TRAP_FUMAROLE_MAXTEMP = 90,
        TRAP_FUMAROLE_MAXTEMP_HELD = 25, -- a little under the threshold so we have time to be placed before changing threshold.
        TRAP_FUMAROLE_TEMP_MODIFIER = -20,
        TRAP_FUMAROLE_TEMPS = { 0, 30, 60 },
        TRAP_FUMAROLE_LIGHTOVERRIDES = { 0, .125, .35 },
        TRAP_FUMAROLE_IGNITE_TIME = seg_time * 0.5, -- multiplied by mult below depending on temperature stage, this also cooks stuff.
        TRAP_FUMAROLE_IGNITE_MULTS = { 0, 0.5, 1 },
        TRAP_FUMAROLE_MAX_IGNITE_ITEMS = 2, -- max items we can cook/ignite per tile
        TRAP_FUMAROLE_TEMPERATURE_RATE = 3,
        TRAP_FUMAROLE_PROPAGATOR_RATE = 25,

        HEALINGSALVE_FUMAROLEBUFF_DURATION = seg_time * 4,

		VAULT_PILLAR_GUARD_HEALTH = 6000,
		VAULT_PILLAR_GUARD_DAMAGE = 150,
		VAULT_PILLAR_GUARD_ATTACK_PERIOD = 3,
		VAULT_PILLAR_GUARD_ATTACK_RANGE = 5,
        VAULT_PILLAR_GUARD_HIT_RECOVERY = 2,
		VAULT_PILLAR_GUARD_SPEED = 2.85,
		VAULT_PILLAR_GUARD_MIN_STAGGER_TIME = 6,
		VAULT_PILLAR_GUARD_MAX_STAGGER_TIME = 15,
		VAULT_PILLAR_GUARD_STAGGER_DAMAGE_MULT = 1.5,
		VAULT_PILLAR_GUARD_SPIN_CD = 16,
		VAULT_PILLAR_GUARD_QUICKJUMP_CD = 12,
		--for crafted ones (distances from home pt)
		VAULT_PILLAR_GUARD_COMBAT_RANGE = 20,
		VAULT_PILLAR_GUARD_DEAGGRO_DIST = 35,

		VAULT_CRAWLER_HEALTH = 1000,
		VAULT_CRALWER_DAMAGE = 40,
		VAULT_CRAWLER_SPEED = 3,
		VAULT_CRAWLER_ATTACK_PERIOD = 2,
		VAULT_CRAWLER_ATTACK_RANGE = 1.2,
		VAULT_CRAWLER_HIT_RANGE = 1.9,
		VAULT_CRAWLER_HIT_ARC = 120,
		VAULT_CRAWLER_ROLLING_SPEED = 2.5,

		VAULT_SHADOW_SUPPRESSION_MULT = 0.025, --dmg mult for combat btwn guards/crawlers vs shadowcreatures

        MAX_SECURITY_PULSE_FOLLOWING = 4,

        VAULT_PILLAR_GUARD_PIECE_GOLD_VALUE = 15,
        VAULT_PILLAR_GUARD_PIECE_ROCK_VALUE = 18, -- appease value for antlion, 6 days

        -- Crow Carnival 2026
        CARNIVALGAME_GOLFGAME_CAMERA_FOCUS_MIN = 11,
		CARNIVALGAME_GOLFGAME_CAMERA_FOCUS_MAX = 11,

        CARNIVALGAME_GOLFGAME_ARENA_RADIUS = 8,
        CARNIVALGAME_GOLFGAME_DURATION = seg_time * 1.5,

        CARNIVALGAME_GOLF_GAME_DIFFICULTY_SCORES =
        {
            ["easy"] = 5,
            ["medium"] = 10,
            ["hard"] = 15,
        },
        -- go up to a 2x mult when scoring under par
        CARNIVALGAME_GOLFGAME_SCORE_MINMULT_UNDER_PAR = 1,
        CARNIVALGAME_GOLFGAME_SCORE_MAXMULT_UNDER_PAR = 1.75,
        CARNIVALGAME_GOLFGAME_SCORE_MULT_HOLE_IN_ONE = 2.5, -- 2.5x minigame score for a hole in one!

--[★ 高尔夫小游戏（Golf）]9547-9556 行
--  ★ 分区边界：文件最后一个完整玩法区块（嘉年华高尔夫）。
--  GOLF_AIM_ARC = 90 * DEGREES, --radians（第 9547 行）：
--    ★★ 角度常量用 DEGREES（第 14 行 DEGREES = PI/180）转换，
--      而不是裸写 1.5708。这是本文件处理角度的**标准做法**，
--      可读性远优于裸小数。行尾 '--radians' 提示结果单位是弧度。
--    ★★ 参见 constants.lua:14（DEGREES / RADIANS 定义）。
--  GOLF_MAX_CHARGE_TICKS = 1.5 * 30（第 9548 行）：
--    ★ 充能 1.5 秒。但写成 1.5*30 而非 1.5 —— 因为 TICK 是「帧」，
--      1.5*30 = 45 帧。与 constants.lua:16 FRAMES = 1/30 呼应（30 FPS）。
--    ⚠ 这是「归一化判据」的一个例外：本行把「秒」换算成「帧」，
--      所以单位在表达式内发生了变化。读表时务必看清是秒还是帧。
--  GOLF_MIN_SPEED = 0 / GOLF_MAX_PUTT_SPEED = 10：轻推速度上限 10。
		GOLF_AIM_ARC = 90 * DEGREES, --radians
		GOLF_MAX_CHARGE_TICKS = 1.5 * 30,
		GOLF_MIN_SPEED = 0,
		GOLF_MAX_PUTT_SPEED = 10,
--★ GOLF_MAX_SWING_SPEED = 11.99,（第 9551 行）
--  ★★★★ 本文件**最长也最有价值的一条注释**，完整保留了一个物理推导：
--    英文原文：'NOTES(JBK): Bullet physics calculates at worst case 30 times
--    a second and the golf ball diameter is 0.4 units meaning ball velocity
--    should be less than 30 * 0.4 = 12 to avoid ball vs triangle mesh being
--    able to teleport inside the mesh.'
--  逐句拆解：
--    (1) 「子弹物理最坏情况下每秒计算 30 次」⇒ 碰撞检测频率 30 次/秒。
--    (2) 「高尔夫球直径 0.4 单位」⇒ 单次检测间隙内最大位移 0.4 格；
--        超过就会在两次检测之间「穿透」三角网格（teleport inside mesh）。
--    (3) 「所以球速应小于 30 * 0.4 = 12」⇒ 物理安全的绝对上限。
--    (4) ★★ 实际取 **11.99** 而非 12 —— 留 0.01 的安全余量。
--  ★★ 这个数字为什么这么怪，注释已经完整回答。
--    后来者既不会把它「修正」成 12（会引入穿模 bug），
--    也不会不明白它为何不是整数 —— 这是可维护数值的教科书范例。
--  ★★ 紧邻两行同样是「平方语义」写法，可对照第 4020 行：
--    GOLFHOLE_SCORE_RANGE_SQ = 0.05*0.05（第 9552 行）：进洞距离 0.05 格内
--    GOLFHOLE_MAX_SCORE_SPEED_SQ = 0.75*0.75（第 9553 行）：
--      速度超过 0.75 就不算进洞。
--    ★ 行尾注释 'ball can't score if faster than this' 说明了语义。
		GOLF_MAX_SWING_SPEED = 11.99, -- NOTES(JBK): Bullet physics calculates at worst case 30 times a second and the golf ball diameter is 0.4 units meaning ball velocity should be less than 30 * 0.4 = 12 to avoid ball vs triangle mesh being able to teleport inside the mesh.
		GOLFHOLE_SCORE_RANGE_SQ = 0.05 * 0.05, --ball will fully drop in at this dist
		GOLFHOLE_MAX_SCORE_SPEED_SQ = 0.75 * 0.75, --ball can't score if faster than this
		GOLFHOLE_MIN_ACCEL = 0.4, --drop force toward center of hole at outer lip
		GOLFHOLE_MAX_ACCEL = 0.7, --max drop force toward center of hole
    }

--★★★ 【★★ 分区 39 · 模组运行时改数值的元表钩子 —— 全文件技术含量最高的一段】★★★
--
--  ★★ 前面 9550 行都是「静态数据表」，从这里开始是一段**元编程**，
--    用setmetatable 让 TUNING 支持「运行时替换为计算式」。
--  ★ 这是全文件唯一会**改变 TUNING 读取语义**的代码，
--    理解它就理解了官方留给模组的扩展点。
--
--  先看这两行：
--      TUNING_MODIFIERS = {}
--      ORIGINAL_TUNING = {}
--    ★★ 它们**清空了**第 4-5 行的同名全局表。
--      为什么？因为 Tune() 可能被重复调用（世界重建、重设难度），
--      若不清空，之前注册的修改器会累积残留 ——
--      ★ 这是典型的「幂等重建」处理：每轮重建都从干净状态开始。
    TUNING_MODIFIERS = {}
    ORIGINAL_TUNING = {}
--★★ 【★★ setmetatable(TUNING, {...}) —— 延迟求值的核心机制】★★
--  作用：给 TUNING 这个普通表装上元表，让它能做到三件普通表做不到的事。
--
--  ── 元表 __index（第 9562-9568 行）：读取一个不存在的键时触发 ──
--    普通表读TUNING.不存在的键 → nil
--    装了元表后 → 触发下面这段：
--        if TUNING_MODIFIERS[k] then
--            local modifier = TUNING_MODIFIERS[k]
--            return modifier[1](modifier[2])   -- fn(缓存的原始值)
--        end
--    ★★ 机制解读：
--      modifier[1] = 第 7 行 AddTuningModifier 传入的 **函数**
--      modifier[2] = 注册时缓存的**原始值**
--      ⇒ 每次读 TUNING.XXX，都会用函数重新算一遍。
--
--  ★★★ 这解决了什么问题？举例说明：★★★
--    假设某模组想让「理智回复」随「季节」变化，它不能改文件，
--    于是注册：AddTuningModifier("SANITYAURA_MED", function(v)
--        return v * season_multiplier end)
--    第 7-12 行的 AddTuningModifier 会把 TUNING.SANITYAURA_MED 置为 nil，
--    于是每次业务代码读它，都会执行函数拿到「随季节变化」的新值。
--    ★★ 与「直接改 TUNING[key] = 新值」相比，本机制的优势是：
--      (a) 不破坏原值（原始值始终缓存在 modifier[2]）；
--      (b) 可以**随上下文**变化（如天气/季节/队伍人数），不是死数；
--      (c) 同一个键可以叠加多层修改器。
--
--  ★★ 代价与陷阱（必须知道）：
--    ⚠ 若该键未被注册为修改器，__index 直接返回 nil（没有 else 分支），
--      行为与普通表一致 —— 这是好的，零性能代价。
--    ⚠ 但一旦注册成修改器，**每次读取都要跑一次函数**，
--      在每帧调用几十次的逻辑里（如 sanity.lua 每 tick 检查）
--      会带来可测量的开销。注册修改器前应评估调用频率。
--    ⚠ 更隐蔽的坑：修改器注册后，TUNING 里该键**已不存在**（被置 nil）。
--      所以任何「遍历 TUNING 所有键」的代码（如 dump、UI 列表）
--      都看不到这些键 —— 它们变成了「幽灵键」。

    setmetatable(TUNING,
    {
        --these only run when indexing a nil value in TUNING
        __index = function(t, k)
            if TUNING_MODIFIERS[k] then
                local modifier = TUNING_MODIFIERS[k]
                return modifier[1](modifier[2])
            end
--  ── 元表 __newindex（第 9569-9576 行）：写入时触发 ──
--    逻辑：若目标键已是修改器，则**改缓存值**，而不是真的写进表。
--        if TUNING_MODIFIERS[k] then
--            TUNING_MODIFIERS[k][2] = v     -- 只更新缓存的基线值
--            return
--        end
--        rawset(t, k, v)                   -- 否则正常写入
--
--  ★★★ 这是本段代码里最精妙的一处设计：★★★
--    它意味着 TUNING.XXX = 100 依然可用，且语义正确 ——
--    「把公式的**输入参数**改成 100」，而不是「把结果硬编码成 100」。
--    举例：某模组注册了 SANITYAURA_MED = f(base)，
--    则 TUNING.SANITYAURA_MED = 50 会让 f 的输入从原值变成 50，
--    之后每次读取仍走 f(50)。
--  ★★ 对比第 31-35 行的 multiplayer_* 机制：
--    那些是在**定义时**乘一次（算成死数），
--    而这里是**每次读取时**重算。前者性能好、后者灵活。
--    两种机制本文件都有，值得对照理解。
--
--  ★★ 为什么普通写入要用 rawset 而不能 t[k] = v？
--    因为 t[k] = v 会**再次触发 __newindex**，造成无限递归。
--    rawset 是「绕过元表直接写」的原生函数，是这类元编程的标准解法。
--    ★ 这是 Lua 元表编程的必备知识，注释虽未言明但代码必须这样写。
--  ★★★ 综合评价：这三段元表代码把一个静态数据表变成了
--    「可被公式化的动态配置」，且开销只对已注册的键生效。
--    这是本文件最值得学习的元编程范例。
        end,
        __newindex = function(t, k, v)
            if TUNING_MODIFIERS[k] then
                TUNING_MODIFIERS[k][2] = v
                return
            end
            rawset(t, k, v)
        end
--★★ 分区收尾：Tune() 函数在此结束。
--  ★ 回顾整个文件的结构闭环：
--    第 14 行 function Tune(overrides)     ← 开头
--    第 19-50 行  局部时间基与角色基线
--    第 52-9556 行 TUNING = { ... }        ← 9581 行数据表本体
--    第 9558 行  重置 TUNING_MODIFIERS / ORIGINAL_TUNING
--    第 9560 行  setmetatable(TUNING, ...) ← 装上延迟求值钩子
--    第 9576 行  end                       ← 收尾
--  ⇒ Tune() 做三件事：定义局部变量 → 建立数据表 → 装载元表钩子。
--  ★★ 注意元表是**在表建好之后**才装的，顺序不能颠倒。
    })
end

Tune()
--★★★ 【★ 文件的最后一行：Tune() —— 整个数值表在此刻被实例化】★★★
--  ★★ 为什么文件末尾必须调用 Tune()？
--    因为 TUNING = { ... } 只是**定义**了一个函数体内的局部字面量，
--    只有执行它，9591 行数据才会真正写入全局 TUNING。
--  ★★★ 这带来一个重要的理解：★★★
--    Tune() **可以被再次调用**（不是只能执行一次），
--    每次调用都会重建整张表并重置修改器。
--    ★ 这正是第 9558 行要清空 TUNING_MODIFIERS 的原因 ——
--      世界重载 / 切换难度时会重新走这里。
--  ★★ 依赖链：任何 require("tuning") 的模块都能读到 TUNING，
--    因为 Lua 的 require 会先执行完整个文件（含末尾的 Tune()）。
--    ★ 调平衡测试流程：改数值 → 重启服务器 → 生效。
--      因为修改器状态与 TUNING 都在内存中，无热重载机制。

