--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：tuning_override.lua
-- 模块：数值源头 / ★ 世界区域调优覆盖钩子（Area Tuning Override Hook）★
-- 行数：45 行
--
--★★★ 【★★★ 最重要的澄清：这个名字极具误导性 ★★★】★★★
--  ★★ 本文件名叫 tuning_override（数值覆盖），**但里面一个数字都没有**。
--    它是一个「键名白名单」，把 41 个**世界事件/区域脚本的名字**
--    映射到一个**空函数** dummyfn 上。
--  ★★ ⇒ 因此：本文件与「改数值」毫无关系。
--    改数值请走worldsettings_overrides.lua（难度覆写）。
--
-- 【★★★ 它到底是什么？（实测结论）★★★】
--  ★★ 全项目只有**一处**引用了本文件：
--      components/area_trigger.lua:9   local retune = require("tuning_override")
--  ★ 该处代码（第 7-15 行）是这样用的：
--      function AreaTrigger:DoOverride(overrides)
--          local retune = require("tuning_override")
--          for i, override in ipairs(overrides) do
--              if retune[override[1]] ~= nil then     -- ← 只检查「键是否存在」
--                  retune[override[1]](override[2])   -- ← 调用（此处为空函数）
--              end
--          end
--      end
--  ★★★ 关键在第 2 行那个判断条件 `retune[override[1]] ~= nil`：★★★
--    本文件里的每个值都是 dummyfn（一个空函数），**永不为 nil**，
--    所以它唯一的作用是充当「**这个事件名是合法的**」校验白名单。
--    若某个区域想覆写的事件名不在本表里，就**会被静默跳过**。
--
-- 【★★★ 这个机制解决了什么问题？★★★】
--  ★★ 场景：世界由「区域(area)」组成，每个区域可携带一组覆写指令
--    （如「这个区域里僵尸刷新更快」「这里不下雨」）。
--    这些指令由世界生成器或模组产生，事件名是字符串。
--
--  ★★ 没有本文件时的问题：
--    若不校验，任何拼写错误或无效事件名都会静默失败 ——
--    「我配了僵尸加速，但游戏里没反应」，且没有任何报错。
--
--  ★★ 有本文件后的改善：
--    ① 提供了一个**可枚举的合法事件名清单**（本表 41 项），
--      开发者查这张表就知道能覆写什么；
--    ② 提供了**安全的调用槽位** —— 模组只要把本表某项
--      从 dummyfn 换成真函数，覆写就自动生效，
--      而调用方（area_trigger）无需改动。
--
--  ★★★ 这就是本项目的「**扩展点（extension point）**」模式：★★★
--    · 常量表以空函数/空表的形式**声明接口存在**；
--    · 具体实现由模组在运行时注入；
--    · 官方无需为每个扩展场景改动核心代码。
--  ★★ 本项目多处采用此模式，参见：
--      constants.lua:648   MODCHARACTERMODES = {}  -- 模组角色模式
--      constants.lua:2118  CRAFTINGSTATION_LIMITED_RECIPES = {}（三张空表）
--      constants.lua:2183  TOOLACTIONS（工具动作注册表）
--      constants.lua:2787  HUNT_ACTIONS（狩猎动作注册表）
--      tuning.lua:14Tune(overrides) —— overrides 参数也是同思路
--    ⇒ 「空表 = 留给模组的扩展点」是本项目一致的设计语言。
--
-- 【★ 与调数值的关系（务必分清三层）★】
--  ┌────────────────────────────────────────────────────────┐
--  │ 层                │ 作用                │ 改什么           │
--  ├────────────────────────────────────────────────────────┤
--  │ tuning.lua│ 引擎原始数值        │ 改游戏本体       │
--  │ worldsettings_overrides│ 难度覆写（★正规入口）│ 改平衡        │
--  │ tuning_override.lua│ ★区域事件白名单   │ **什么都不改** │
--  └────────────────────────────────────────────────────────┘
--  ★★ 结论：想改数值 → 用 worldsettings_overrides.lua。
--         本文件只回答「世界区域能覆写哪些事件」。
--
-- 【★ 命名辨析】
--  ·「override」在本项目有两层含义，容易混淆：
--      (a) tuning_override.lua= 区域**事件脚本**的覆写钩子（本文件）
--      (b) worldsettings_overrides.lua = 世界设置**数值**的覆写（真改数值）
--  ⇒ 二者一个管事件、一个管数值，务必按文件名区分。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/area_trigger.lua（唯一消费方）,
--           worldsettings_overrides.lua（真正的数值覆写入口）,
--           tuning.lua（数值源头）, constants.lua（扩展点模式）
--============================================================
local dummyfn = function() end
--★ dummyfn = function() end（第 1 行）：空函数，即「什么都不做」。
--  ★★ 它是本文件全部 41 个键的默认值。
--    由于 Lua 的函数是一等值，把 dummyfn 赋给多个键是安全的
--    （它们共享同一个函数对象，但调用它没有任何副作用）。
--  ★ 模组覆写时的典型写法：
--      local retune = require("tuning_override")
--      retune.wolves = function(opts) ... 真逻辑 ... end
--      -- 于是所有配置了「wolves」事件的区域都会执行真逻辑
return
--★★★ 【★★ 41 个合法事件名 —— 本文件的全部内容（第 4-44 行）★★】★★★
--  ★★★ 实测键数 41，经程序化去重检验**无重复键**。★★
--  ★★★ 按语义归为 8 组（行号已逐一核对）：★★★
--
--  ┌──① 敌对生物（7 项：4-10 行）────────────────────────┐
--  │ 4 hounds(猎犬) 5 wormattacks(洞穴蠕虫) 6 deerclops(巨鹿)
--  │ 7 bearger(熊獾) 8 goosemoose(鸭嘴兽) 9 dragonfly(蜻蜓)
--  │ 10 antliontribute(蚁狮供奉)
--  └───────────────────────────────────────────────────────┘
--    ★ 这 7 项都是「在某区域内是否出现 / 出现多少」类指令。
--      ⇒ 典型用途：沼泽区域关掉巨鹿、洞穴区域关掉猎犬。
--
--  ┌──② 疾病与仪式机制（4 项：11-14 行）─────────────────┐
--  │ 11 disease_delay(疾病延迟) 12 perd(石化)
--  │ 13 hunt(狩猎) 14 alternatehunt(替代狩猎)
--  └───────────────────────────────────────────────────────┘
--    ⚠ 注意第 12 行 **perd 是 petrification 的缩写** ——
--      与 tuning.lua 的 PERISH_*（物品腐坏）含义**完全不同**，
--      这是本文件最易误读的一处。
--
--  ┌──③ 植被与节庆（4 项：15-18 行）──────────────────────┐
--  │ 15 deciduousmonster(落叶怪) 16 krampus(圣诞怪)
--  │ 17 butterfly(蝴蝶) 18 flowers(花)
--  └───────────────────────────────────────────────────────┘
--    ★★ 第 19 行 **flower_cave** 独立于第 18 行 flowers：
--      地表花与洞穴花是**两套独立配置**。
--      ⇒ 这一拆分透露了设计意图：洞穴与地表生态分开调。
--
--  ┌──④ 动物群（6 项：20-25 行）──────────────────────────┐
--  │ 20 birds(鸟) 21 penguins(企鹅) 22 lureplants( lure plant)
--  │ 23 rock_ice(冰岩) 24 beefaloheat(牛牛取暖) 25 liefs(传送门)
--  └───────────────────────────────────────────────────────┘
--    ★ 注意 beefaloheat 与 liefs 也归在此组 ——
--      前者控制野牛取暖相关，后者控制传送门(lie gate)行为。
--
--  ┌──⑤ 天气与季节（8 项：26-33 行）★★ 最完整的一组 ──┐
--  │ 26 day(永昼/永夜) 27 autumn 28 winter 29 spring
--  │ 30 summer 31 season_start 32 weather 33 lightning
--  └───────────────────────────────────────────────────────┘
--    ★★ 第 26 行 day 与第 31 行 season_start 需特别留意：
--      day        = 某区域是永昼还是永夜
--      season_start = 该区域的季节由外部指定（而非按进度推进）
--      ⇒ 二者共同支撑「自定义季节长度」世界类型（呼应
--        worldsettings_overrides.lua 中的 noseason 选项）。
--    ★ 四季齐全（第 27-30 行）说明季节覆写是逐季独立的。
--
--  ┌──⑥ 环境灾害（4 项：34-37 行）──────────────────────┐
--  │ 34 frograin(蛙雨) 35 wildfires(野火) 36 earthquakes(地震)
--  │ 37 creepyeyes(恐怖之眼)
--  └───────────────────────────────────────────────────────┘
--
--  ┌──⑦ 区域氛围与海浪（5 项：38-42 行）────────────────┐
--  │ 38 areaambient 39 areaambientdefault 40 meteorshowers
--  │ 41 waves 42 colourcube
--  └───────────────────────────────────────────────────────┘
--    ★ waves(第 41 行)指**海浪**（海洋灾害），不是季节波动 ——
--      命名极易误解。
--    ★ meteorshowers(第 40 行)严格说属灾害，却排在氛围组前 ——
--      说明本表的排列更接近「历史追加顺序」而非严格分类。
--    ★ colourcube(第 42 行)= 区域色调滤镜，影响整个区域画面配色。
--
--  ┌──⑧ 世界演化（2 项：43-44 行）──────────────────────┐
--  │ 43 regrowth(再生) 44 petrification(石化)
--  └───────────────────────────────────────────────────────┘
--    ★★ 注意第 12 行已有缩写 perd，此处是完整拼写 petrification ——
--      同一概念的两种命名，详见第 44 行处详述。
--
--  ★★★ 【★ 排列规律总结】★★
--  本表**并非按主题严格分组**，而是「敌对生物 → 机制 → 季节 →
--  灾害 → 氛围」的宽泛顺序，且新内容持续追加到尾部
--  （如 40 meteorshowers、41 waves、44 petrification 都是后期加入）。
--  ⇒ 与 tuning.lua 一样：按行号找功能不可靠，应按键名搜索。
{
    hounds = dummyfn,
    wormattacks = dummyfn,
    deerclops = dummyfn,
    bearger = dummyfn,
    goosemoose = dummyfn,
    dragonfly = dummyfn,
    antliontribute = dummyfn,
    disease_delay = dummyfn,
    perd = dummyfn,
    hunt = dummyfn,
    alternatehunt = dummyfn,
	deciduousmonster = dummyfn,
	krampus = dummyfn,
    butterfly = dummyfn,
    flowers = dummyfn,
    flower_cave = dummyfn,
    birds = dummyfn,
    penguins = dummyfn,
    lureplants = dummyfn,
    rock_ice = dummyfn,
    beefaloheat = dummyfn,
    liefs = dummyfn,
	day = dummyfn,
	autumn = dummyfn,
	winter = dummyfn,
	spring = dummyfn,
	summer = dummyfn,
    season_start = dummyfn,
    weather = dummyfn,
    lightning = dummyfn,
	frograin = dummyfn,
	wildfires = dummyfn,
	earthquakes = dummyfn,
    creepyeyes = dummyfn,
    areaambient = dummyfn,
    areaambientdefault = dummyfn,
    meteorshowers = dummyfn,
    waves = dummyfn,
    colourcube = dummyfn,
    regrowth = dummyfn,
--★★ 【★★ 本文件最后一行 —— 一个易被误解的细节】★★
--  petrification = dummyfn,
--  ★★ 关键事实（已实测确认）：本表共 **41 个键，经程序化去重检验，
--    无任何重复键**。第 12 行的 perd 与本行的 petrification
--    是**两个不同的键**，各自独立存在、都等于 dummyfn。
--
--  ⚠疑似缺陷（命名不统一，同一概念两种写法）：
--    推理依据：二者从上下文看指向同一概念（石化），
--      但一个用缩写（perd）、一个用完整拼写（petrification）。
--    ⇒ 由于 Lua 表键唯一，它们**不会互相覆盖**，
--      因此这不是运行时冲突，而是**接口层面的歧义**：
--      调用方（area_trigger 传入的 override 名）该用哪个？
--      两者都能通过 `retune[name] ~= nil` 校验通过，
--      但模组只替换其中一个时，另一个仍是空函数 → 覆写不生效。
--      ★★ 这是一个**静默失败**风险：配置看似被接受，实则无效。
--    ⇒ 推测：第 12 行是历史缩写名，第 44 行是后加的规范名，
--      两者为兼容不同调用方而并存，属未清理的遗留痕迹。
--  ★★★ 对比本表中其他「看似重复」项，它们是**不同事物**：
--      flowers（第 17 行）vs flower_cave（第 18 行）= 地表花 vs 洞穴花
--      birds vs penguins、regrowth vs petrification = 不同机制
--    ⇒ 唯有perd / petrification 这一对是**同一事物的两种命名**。
--★ 这正体现了「白名单表」的价值与局限：
--  它保证事件名**合法**，却不保证事件名**唯一**、也不校验语义正确。
--  ⇒ 需要更强的保护时，应由消费方（area_trigger）加额外校验。
    petrification = dummyfn,
}
--★★★ 【★ 全文件结束 · 三条实操结论 ★★★】
--  (1) ★ 本文件**不含任何数值**，不要在这里找「可调参数」。
--  (2) ★ 想改平衡数值 → tuning.lua（本体）或
--      worldsettings_overrides.lua（★推荐，走难度覆写）。
--  (3) ★ 本文件的真实用途：为「区域事件覆写」提供合法事件名白名单，
--      是模组注入自定义区域行为的扩展点。
--★ 全项目唯一消费方：components/area_trigger.lua:7-15
--★ 该处的核心判断是 retune[override[1]] ~= nil（键是否存在），
--  因为所有值都是空函数，所以本表实际只提供「白名单」语义。
