--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：recipe.lua（243 行）
-- 模块：合成系统 / 配方数据结构（Recipe Schema）
-- 职责：定义 Ingredient（一份材料）与 Recipe（一条配方）两个类，
--   并维护全局配方表 AllRecipes。它是**纯数据层**，不执行合成。
--
-- ★★ 全文件最重要的认知一：本文件**不判定材料够不够**。
--   grep 核实：`CanCraft` / `IsCookingPermitted` 在本文件**不存在**
--   （全库 grep 只在 widgets/widgetutil.lua:30 命中一个同名的
--   局部函数 CanCraftIngredient，那是 UI 侧的灰显判定）。
--   真正的三段式流程分散在三个文件：
--     ① 配方定义   —— 本文件（Recipe 类）+ recipes.lua / preparedfoods.lua
--     ② 取料       —— components/builder.lua:500 GetIngredients
--                    → components/inventory.lua:1697 GetCraftingIngredient
--     ③ 扣料       —— components/builder.lua:546 RemoveIngredients
--   ⇒ 读本文件时不要指望找到「匹配算法」，它在上游的 builder 里。
--
-- ★★ 全文件最重要的认知二：Recipe 是**全局唯一表**，不是原型注册表。
--   179 行 `AllRecipes[name] = self` 直接写入全局表，name 冲突即覆盖。
--   对比 actions.lua：Action 有 ACTIONS_BY_ACTION_CODE 的编号层，
--   而 Recipe 只有 name 一个键——所以模组改配方名 = 改存档兼容。
--
-- ★★ 全文件最重要的认知三：`ingredients` 在构造时被拆成**三张表**。
--   89-96 行按 Ingredient.type 把材料分到：
--     · self.ingredients          —— 普通物品材料（草、木头、石头…）
--     · self.character_ingredients —— 角色代价（扣血、扣理智）
--     · self.tech_ingredients     —— 科技材料（目前只有雕刻材料）
--   ★ 为什么拆？因为三者的扣除路径完全不同：
--     普通材料 → inventory:RemoveItem（实体销毁）；
--     角色代价 → health:DoDelta / sanity:DoDelta（改数值，不掉实体）。
--   判定谓词见 44 行的 IsCharacterIngredient 与 55 行的 IsTechIngredient，
--   它们都是**惰性建表**（第一次调用时才建，反射常量表并取 value 反查）。
--
-- 关键符号：Ingredient（类）, Recipe（类）, Recipe2, DeconstructRecipe,
--   AllRecipes, AllBuilderTaggedRecipes, IsCharacterIngredient,
--   IsTechIngredient, GetValidRecipe, IsRecipeValid, RemoveAllRecipes,
--   mod_protect_Recipe
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 components/builder.lua:500 GetIngredients（取料入口）
--   ★★ 参见 components/builder.lua:546 RemoveIngredients（扣料执行）
--   ★★ 参见 components/inventory.lua:1690 crafting_priority_fn（取料排序）
--   ★★ 参见 components/inventory.lua:1697 GetCraftingIngredient（选哪几个）
--   参见 techtree.lua:76 Create —— level 字段被补齐成 40 轴全 0 的表
--   参见 constants.lua:2123 CHARACTER_INGREDIENT（角色代价类型枚举）
--   参见 constants.lua:2134 CHARACTER_INGREDIENT_SEG = 5（代价粒度）
--   参见 constants.lua:2136 TECH_INGREDIENT（科技材料枚举）
--   参见 constants.lua:3012 SKINUNLOCKS（unlocks_from_skin 的枚举）
--   参见 constants.lua:2224 BUILDMODE（建造落点模式）
--   参见 simutil.lua:930 DeclareLimitedCraftingRecipe（限量配方登记）
--   参见 gamemodes.lua:302 IsRecipeValidInGameMode（模式过滤）
--   参见 modutil.lua:613 AddRecipePostInit（模组配方后置钩子）
--   参见 preparedfoods.lua:352 wetgoop 兜底烹饪条目（priority = -10）
--   参见 spicedfoods.lua:32 香料版本的 wetgoop（test 改为检查香料）
--   参见 widgets/widgetutil.lua:30 CanCraftIngredient（UI 侧灰显判定）
--   参见 widgets/crafttabs.lua:260 CHARACTER_INGREDIENT_SEG 的 UI 用法
--============================================================
--
--【阅读导航】
--  §零   Ingredient 材料类（5-37）      —— 一份材料的五个字段
--  §一   全局表与惰性谓词（39-63）      —— 反射常量表的缓存技巧
--  §二 ★ Recipe 构造（65-193）          —— 60 个字段的来源与去向
--  §三   配方查询（195-227）            —— GetValidRecipe 的四重过滤
--  §四   两个子类（229-243）            —— Recipe2 与 DeconstructRecipe
--
--【★★ 全文件最重要的八条】
--  1. ★★ 本文件**不判定材料够不够**。grep 核实：CanCraft / IsCookingPermitted
--     在本文件不存在。取料在 components/builder.lua:500 GetIngredients，
--     扣料在 components/builder.lua:546 RemoveIngredients。
--     ★ 唯一同名的 CanCraftIngredient 在 widgets/widgetutil.lua:30，
--       那是 UI 灰显判定，与服务端是否允许合成**可以不一致**。
--  2. ★★ ingredients 在构造时按类型被拆成**三张表**（89-96 行）：
--     普通材料 / 角色代价 / 科技材料。三者的扣除路径完全不同，
--     所以必须在 Recipe 构造时就分好，否则 builder 每次都要重新分类。
--  3. ★ level 字段不是数字，是 TechTree.Create(level) 生成的**稀疏对照表**。
--     比较发生在 components/builder.lua 的 KnowsRecipe 里，按 40 个轴逐项比。
--     ★ 所以 recipe.lua 完全不知道玩家有几级科技——那是 builder 的事。
--  4. ★ num 是一个**全局自增序号**（39 行 / 178 行），赋给 sortkey 与 rpc_id。
--     sortkey 决定合成菜单里的**默认排序**；rpc_id 是给模组用的轻量哈希。
--     ⇒ RemoveAllRecipes() 必须把 num 归零，否则新旧配方的 sortkey 会断层。
--  5. ★ tab 参数已被废弃（99 行），但 is_deconstruction_recipe 靠它反推（174 行）。
--     Recipe2 显式传 nil 然后改写该字段，正是为了绕开这个历史包袱。
--  6. ★★ nounlock 的三来源合并在 131 行：unlocks_from_skin > nounlock > false。
--     force_hint（156 行）则允许「虽然 nounlock 但仍显示锁着的样子」，
--     用于「差 1 级科技」的场景——它是显示开关，不影响能否解锁。
--  7. ★ limitedamount 走的是「构造期登记到全局表」的旁路（162-166 行），
--     外面套 TheSim 判断是为了 updateprefabs 阶段不炸——那时全局表还不存在。
--  8. ★ 184-192 行的两个 ModManager PostInit 钩子是**唯一**的模组扩展点。
--     因为 Recipe 构造是全局唯一表，构造完就冻结，模组无法事后插桩，
--     只能在构造过程中挂钩。
--
--【⚠ 疑似缺陷清单（本文件 4 条，均只记录不修改）】
--  L1 ★★ recipe.lua:16  assert 硬编码了 `x == 5` 而没有用
--                    CHARACTER_INGREDIENT_SEG 常量拼接比较。原注释自己写了
--                    "if you changed CHARACTER_INGREDIENT_SEG, then update this assert"，
--                    即这是一个**已知且未修**的耦合。改动 constants.lua:2134
--                    会让所有角色代价配方的断言在 mod 加载期一起崩。
--  L2 ★   recipe.lua:174  self.is_deconstruction_recipe = tab == nil
--                    ⇒ 「没传 tab 的 Recipe 就是分解配方」。但 Recipe2（229 行）
--                    也传 nil，随后在 236 行改写为 false。
--                    ★ 危险：任何直接 `Recipe(...)` 而不传 tab 的新代码，
--                      都会被静默标记成 is_deconstruction_recipe=true，
--                      从而在 GetValidRecipe（216 行）里被永久过滤掉。
--                    推理依据：recipes.lua 里的官方配方绝大多数经由 Recipe2，
--                    但 recipes.lua:390 那种 `Recipe2(...)` 之外的写法确实存在。
--  L3 ★   recipe.lua:203-207  SetModRPCID 的哈希碰撞检测是 O(n) 全表扫描，
--                    且只 print 不中断。两个模组配方名 smallhash 相同会静默合并。
--                    实际风险极低（32 位哈希），但「只警告不拒绝」是弱契约。
--  L4 ★   recipe.lua:115  self.level = TechTree.Create(level)
--                    TechTree.Create 会为全部 40 个科技轴补 0（techtree.lua:72），
--                    因此**永远不为 nil**。这意味着「这个配方没有科技要求」
--                    与「这个配方要求 0 级科技」在数据结构上无法区分。
--                    ⇒ 模组想检测「完全无科技限制」必须改用 sortkey 或自加字段。
--
--【★ 关于「湿泥巴」式兜底配方 —— 用户重点询问项】
--  配方原文不在本文件，在 preparedfoods.lua:352：
--      wetgoop = {
--          test = function(cooker, names, tags) return true end,  ← 恒真
--          priority = -10,                                       ← 最低
--          health=0, hunger=0, sanity=0, perishtime=TUNING.PERISH_FAST,
--          cooktime = .25, wet_prefix = STRINGS.WET_PREFIX.WETGOOP,
--          floater = {"small", nil, nil},
--      }
--  ★★ 机制拆解（三层，缺一不可）：
--   ① test 恒真 —— 保证**任何**食材组合都能匹配到它，不会出现「无法烹饪」；
--   ② priority = -10 —— 保证它排在所有真配方之后（真实配方是 10/20/…/100），
--      所以只有当没有任何真配方命中时，兜底才生效；
--   ③ 三项数值全 0 + PERISH_FAST —— 兜底产物**没有任何收益**且极易腐坏，
--      玩家自然不会主动去用它。
--  ★★ 为什么需要它？DS 的烹饪锅是**内容驱动**的：锅里扔什么都能煮，
--    但配方表只覆盖了设计者想到的组合。兜底配方把「未覆盖」从
--    「崩溃/卡住」变成「产出 worthless 的泥巴」——这是内容型游戏的经典手法。
--  ★★ 风险与代价（三点）：
--   · **它会吞掉 mod 配方的机会**：若某 mod 提供了更高 priority 的烹饪条目，
--     兜底不会干扰（priority 更高）；但若 mod 条目 priority 写错成 -5 或更低，
--     就会被 wetgoop 抢先匹配，且不会有任何报错——
--     ★ 这就是「priority 是隐式契约」的典型例子，框架不校验。
--   · **它让「烹饪失败」不可观测**：玩家把配方材料扔错顺序，得到的仍是 wetgoop，
--     而 UI 上没有任何「你放错了」的提示。
--   · **它对存档/统计是污染**：wetgoop 会进 scrapbook（scrapbookdata.lua:336
--     明确列在 cookpot 的 deps 里），图鉴会被大量无关条目淹没。
--  ★ 相关：spicedfoods.lua:32 对 wetgoop 做了特判——香料版的 test 改为
--    `return names[spicename]`（只检查香料在不在），priority 保持 -10，
--    cooktime 压到 .12。⇒ 香料版本**不是兜底**，它是一个正常的低优先级配方，
--    这个分叉恰恰说明「priority 语义依赖于同表内其他条目的取值」，
--    是一处易碎的设计。
--
--【ingredients 的声明格式 —— 用户重点询问项】
--  ★ 先纠正一个常见误解：**ingredient 的 amount 没有 exact / atleast /
--    infinite 三种模式**。grep 全库确认 recipe.lua 里只有 Ingredient 的
--    构造函数（5 行），amount 是一个普通数字，没有模式标记。
--    实际语义如下（这是本文件真正定义的三类材料）：
--    · 普通材料（self.ingredients）
--        amount = 需要几个实体。精确匹配，不多不少。
--        例：Ingredient("rocks", 1) 就是 1 块石头。
--        ★ 特殊约定：builder.lua:507 有 `if v.amount > 0` 的过滤，
--          所以 **amount = 0 的材料被完全忽略**，等价于「infinite」。
--          这是唯一的「infinite」表达方式，而且是隐式的。
--    · 角色代价（self.character_ingredients）
--        type ∈ {decrease_health, decrease_sanity, half_health, half_sanity, decrease_oldage}
--        amount = 数值。8-16 行强制 HEALTH/SANITY 类必须是 0 或 5 的倍数
--        （用字符串切片实现，见该处注释：math.floor 有精度误差）。
--        ★ 注意原注释：这**只适用于 health/sanity 花费**，
--          不适用于 half_health / half_sanity（后者是回血上限，不是花费）。
--        ★ 反面：amount 可以是负数吗？没拦。但 builder.lua:568-580 是
--          `health:DoDelta(-v.amount, ...)`，负数会变成回血——
--          ⚠ 疑似可利用点：传 Ingredient("decrease_health", -5) 会回血。
--    · 科技材料（self.tech_ingredients）
--        目前只有 SCULPTING = "sculpting_material"（constants.lua:2140）。
--        这类材料的扣除**不在 builder.lua:546** 里，而在别处（雕刻台流程）。
--  ★ 也就是说「数量是否可消耗」这个维度上，本文件只提供了 amount 一个标量，
--    真正把它变成实体集合的是 inventory.lua:1697 GetCraftingIngredient。
--
--【科技等级判定 —— 用户重点询问项】
--  115 行 `self.level = TechTree.Create(level)` 只是**存**，不**比**。
--  ★ 比较发生在 components/builder.lua 的 KnowsRecipe 家族里，逻辑是：
--    逐轴比较 recipe.level[axis] 与 builder 的该轴等级（可能含 *_bonus 临时加成）。
--    techtree.lua:4-39 列出了全部 40 个轴名（AVAILABLE_TECH），
--    techtree.lua:57-63 的 BONUS_TECH 只允许其中 5 个（SCIENCE/MAGIC/
--    SEAFARING/ANCIENT/MASHTURFCRAFTING）加加成。
--  ★★ 因此「多轴科技」的实际含义是：**一条配方可以同时要求 8 个轴**，
--    例如「需要 SCIENCE 3 且 SEAFARING 2 且 SHADOW 1」。
--    缺任何一轴都不可解锁。这是 AND 关系，不是 OR，也不是加权总分。
--  ★ 补充：CHARLO/MOON_ALTAR 等已废弃轴仍留在列表里，
--    Create 会给它们补 0——所以老配方不会因为轴被删而崩，这是刻意的兼容。
--
--【★ 移植/二次开发最需要注意的五处】
--  · 89-96 行的三表拆分是硬编码的：新增材料类型必须同时改这里、
--    IsCharacterIngredient、IsTechIngredient 三处，漏一处材料就静默丢失；
--  · 174 行的 is_deconstruction_recipe 推断（tab == nil）极脆弱，见 L2；
--  · 16 行的 assert 硬编码 5，见 L1；
--  · 182 行 AllBuilderTaggedRecipes 只在 allowautopick 为 nil 时才登记，
--    原注释解释「donotautopick 的物品要显式设置 allowautopick」——
--    这意味着**不设就默认会被机器人捡走**，是相当危险的默认值；
--  · 67 行的参数列表已经 16 个了，原注释明写
--    "do not add more params here, add them to placer_or_more_data"——
--    新参数只能走 more_data（74-80 行做兼容：传 table 就整个当 more_data）。
-- 【§零】Ingredient —— 「一份材料」的最小单位。
-- ★ 全类只有 5 个字段（18-22 行），没有「是否可消耗」这类标记字段：
--   type / amount / atlas / image / deconstruct。
--   ⇒ 材料的一切复杂度都被推给了调用方与下游的 inventory。
-- 交叉引用：components/inventory.lua:1697 GetCraftingIngredient 把 Ingredient
--   翻译成「具体哪几个实体实体」的映射表。
require "class"
-- ★ require "util" —— 本文件唯一的工具依赖，提供 resolvefilepath 等路径函数。
require "util"
-- ★★ 唯一的局部 require：TechTree。它只被用于 115 行的一处调用，
--   即「把 level 数字/表规范化成 40 轴对照表」。
--   ★ 局部化是为了不污染全局 —— class.lua 的 Class 是全局的，
--     techtree 返回的是普通 table，不需要全局可见。
local TechTree = require("techtree")

-- ↑ 空行。
-- ★★ Ingredient 的构造签名故意做成位置参数，因为配方表里是
--   密集书写的：Ingredient("rocks", 1)。任何加在中间的参数都会让
--   全部 1106 条配方（见 05-数据/配方与物品表.md）需要改写。
Ingredient = Class(function(self, ingredienttype, amount, atlas, deconstruct, imageoverride)
-- ↑ 原英文注释（保留）：角色材料的 5 倍数检查只适用于
--   health/sanity 的**花费**，不适用于 max health / max sanity。
-- ★ 中文展开：
--   「decrease_health / decrease_sanity」= 从角色身上扣数值，
--   这两者的数值直接决定玩家血条掉多少，必须对齐 5 的刻度，
--   否则 UI 上会出现「最大生命 137 但血量只能停在 132」的割裂感；
--   「half_health / half_sanity」= 永久削减**上限**，是一次性惩罚，
--   不走 DoDelta 路径（走 DeltaPenalty，见 builder.lua:575），
--   所以不受此约束。
    --Character ingredient multiples of 5 check only applies to
-- ↑ 原英文注释第二行：not max health or max sanity（续）。
    --health and sanity cost, not max health or max sanity
-- ↑ 原注释两行结束。
-- 【角色代价的粒度约束】8-16 行是一个**精度妥协**的实现。
-- ★ 为什么只查 HEALTH/SANITY 而不查 MAX_HEALTH/MAX_SANITY？
--   原注释给了答案（6-7 行）：断言只适用于「花费」，不适用于「上限」，
--   因为扣上限需要另外一套 DeltaPenalty 机制（builder.lua:575），
--   其数值与扣除路径都与 DoDelta 不同，不便共用断言。
-- ★ 为什么用字符串切片而不用 math.floor？原注释说是 math.floor 的精度
--   误差「inconsistent」。这是把浮点数问题下沉到字符串层的写法，
--   好处是完全避开浮点，坏处是 amount 必须是能字符串化的数字。
    if ingredienttype == CHARACTER_INGREDIENT.HEALTH or
-- ↑ 条件的第二行：SANITY 与 HEALTH 用同样的处理（字符代价同理）。
        ingredienttype == CHARACTER_INGREDIENT.SANITY then
-- ↑ 条件块结束（if 只有一行体）。
-- ⚠ 疑似缺陷 L1：本行与 16 行的 assert 硬编码了 5，
--   没有引用 constants.lua:2134 的 CHARACTER_INGREDIENT_SEG 常量。
--   推理依据：原注释自己写了 "if you changed CHARACTER_INGREDIENT_SEG,
--   then update this assert"——即这是一个**已知未修**的耦合。
--   后果：改动该常量会让所有角色代价配方的构造在 mod 加载期一起失败。
        --V2C: string solution due to inconsistent precision errors with math.floor
-- ↑ 原英文注释（保留）：改用字符串方案，因为 math.floor 有不一致的精度误差。
-- ★ 展开：`--local x = math.floor(amount)` 是被废弃的正确写法，
--   之所以不能用，是因为 amount 可能是 7.499999999（浮点表示误差），
--   floor 后得到 7 而不是 0/5，断言就会误杀合法配方。
        --local x = math.floor(amount)
-- ↑ 被注释掉的旧实现。
-- ★ `local x = tostring(amount)` —— 把数字转成字符串，后续全用字符串运算。
        local x = tostring(amount)
-- ↑ 新实现的起点。
-- ★★ `x:find("^%-?%d+")` —— 正则匹配开头的可选负号 + 整数部分。
--   这是**截断小数**的字符串实现：对 "7.5" 匹配出 "7"，对 "-7.5" 匹配出 "-7"。
--   ⇒ 等价于朝零取整（trunc），而不是 floor（向负无穷取整）。
--   ★ 这个差异是有意义的：amount = -7.5 时，trunc 得 -7，floor 得 -8。
--     作者选择 trunc，说明他把 amount 当作「绝对数量」看待。
        x = x:sub(x:find("^%-?%d+"))
-- ↑ 匹配整数部分。
-- ★ `x:sub(x:len())` —— 取匹配长度之后的部分，等价于「截掉小数点」。
        x = tonumber(x:sub(x:len()))
-- ↑ 截断小数点后的部分。
-- ↑ 原英文注释（保留）：改了 CHARACTER_INGREDIENT_SEG 就必须同步改这个 assert。
-- ★★ 这条注释是本文件最大的维护债声明，详见 HEADER_EXTRA 的 L1。
        --NOTE: if you changed CHARACTER_INGREDIENT_SEG, then update this assert
-- ↑ 断言前的提醒注释。
-- ⚠ 疑似缺陷 L1（续）：断言信息里用了 tostring(CHARACTER_INGREDIENT_SEG)，
--   但比较用的字面量是 5。两者可能不一致——错误信息会误导排查者。
        assert(x == 0 or x == 5, "Character ingredients must be multiples of "..tostring(CHARACTER_INGREDIENT_SEG))
-- ↑ 这里用字面量 5 而非 CHARACTER_INGREDIENT_SEG，见 L1。
-- ↑ 断言块结束。只有 HEALTH / SANITY 两类会走进这个分支。
    end
-- ↑ 角色代价粒度约束结束。
-- ★ deconstruct 字段：这是**唯一**带「消耗语义」的标记，但它的含义是
--   「这个材料被拆解时是否要扣掉」，而不是配方意义上的 exact/atleast。
--   grep 核实 deconstruct 的消费点在 builder 的拆解流程，
--   recipe.lua 自身只负责存。
    self.type = ingredienttype
-- ★ self.amount —— 见 HEADER_EXTRA「ingredients 的声明格式」：它就是需要的个数，没有更多语义。
    self.amount = amount
-- ↑ self.type 之后。
-- ★★ atlas：图集路径。20 行的写法 `atlas and resolvefilepath(atlas) or nil`
--   是 Lua 三目惯用法 —— 当 atlas 为 nil 时短路成 nil（而不是调 resolvefilepath(nil)）。
-- ★ 惰性求值的另一半在 25-29 行的 GetAtlas：没传 atlas 就按 image 名反查。
    self.atlas = atlas and resolvefilepath(atlas) or nil
-- ★ image：贴图覆盖项。nil 时 GetImage（32 行）会退化成 type..".tex"。
    self.image = imageoverride
-- ★ deconstruct：见 §零 处的说明 —— 它是「拆解相关」标记，
--   语义是「作为分解配方产物时是否照常扣除」，不是配方的可消耗性。
    self.deconstruct = deconstruct
-- ↑ deconstruct 字段之后。
-- ↑ Ingredient 类构造结束。注意它没有返回 self（Class 框架自动处理）。
end)
-- ↑ Class 的第三参数（attr_init）为 nil —— Ingredient 的字段**不走 setter 同步**。

-- ★ GetAtlas 是惰性求值 + 记忆化：第一次调用时按 image 名反查图集并写入
--   self.atlas，此后直接返回。配方表有上千条，全惰性可以省掉上千次字符串运算。
function Ingredient:GetAtlas()
-- ★★ `if self.atlas == nil` —— 惰性分支。配方表有上千条，
--   全量预解析图集会拖慢加载；按需解析 + 记忆化是标准做法。
    if self.atlas == nil then
-- ↑ GetAtlas 的惰性判定。
-- ★★ 27 行是本文件**唯一**调用 GetInventoryItemAtlas 的地方。
--   该函数按贴图名在全局图集表里反查路径 —— 是 recipes/inventory 共用的工具。
--   ⇒ 隐含依赖：材料贴图必须在某个 inventoryimages 图集里注册过。
       self.atlas = resolvefilepath(GetInventoryItemAtlas(self:GetImage()))
-- ↑ atlas 惰性求值的实现行。
-- ★ 记忆化写回：下次直接返回缓存。
    end
-- ↑ 记忆化写回之后。
-- ↑ GetAtlas 返回值。
    return self.atlas
-- ↑ 返回 self.atlas。
-- ↑ GetAtlas 结束。
end
-- ↑ GetAtlas 函数结束。
-- ↑ 空行，转入 GetImage。

-- ★ GetImage 同样的惰性模式（33-35 行）。
--   约定：`type..".tex"` —— 即材料名直接对应贴图名，
--   所以「decrease_health.tex」这类贴图必须存在于图集中。
function Ingredient:GetImage()
-- ★ GetImage 同样惰性。33 行判空、34 行拼出 `type..".tex"`。
--   ★ 与 27 行的顺序耦合：必须先算出 image 才能反查 atlas，
--     所以 GetAtlas 内部才要调 GetImage 而不是直接用 type。
    if self.image == nil then
-- ↑ GetImage 的惰性判定。
-- ★ `self.type..".tex"` —— 约定式命名：decrease_health → decrease_health.tex。
        self.image = self.type..".tex"
-- ↑ 默认贴图名。
-- ★ 记忆化写回。
    end
-- ↑ 记忆化写回之后。
-- ↑ GetImage 返回值。
    return self.image
-- ↑ 返回 self.image。
-- ↑ GetImage 结束。
end
-- ↑ GetImage 函数结束。
-- ↑ 空行分隔，进入全局表定义区。

-- 【§一】全局状态与两个惰性谓词。
-- ★ num 是**全局自增序号**，构造时（178 行）赋给 sortkey 与 rpc_id。
--   它衡量的是「这条配方在本进程里是第几个被构造的」，
--   与配方内容、注册顺序的语义无关——纯粹是合成菜单排序用的稳定键。
-- ★★ 因此 AllRecipes 是 `pairs` 遍历的（203 行 SetModRPCID 就这么干），
--   顺序不可靠；凡是需要顺序的地方都必须显式用 sortkey。
local num = 0
-- ★★ AllRecipes 是**全局唯一表**，不是原型注册表。
--   179 行直接 AllRecipes[name] = self —— 同名配方**静默覆盖**，无警告。
--   对比 actions.lua：Action 有 ACTION_IDS 编号层与冲突处理，
--   而 Recipe 只有 name 一个键。⇒ 模组改配方名 = 改存档兼容（见 L2 区）。
-- ★ 为什么不做冲突检测？因为 1106 条配方在 mod 加载期批量构造，
--   任何 assert 都会让互相覆盖的 mod 无法共存。Klei 选择了容忍。
AllRecipes = {}
-- ★ AllBuilderTaggedRecipes：value 是 builder_tag 或 builder_skill，
--   表本身用于「机器人（WX78 / 蜜蜂 / 机器人）按标签找配方」的批量查询。
--   登记条件见 180-182 行：必须设了 builder_tag 或 builder_skill，
--   且 more_data.allowautopick 为 nil。
AllBuilderTaggedRecipes = {}
-- ★ AllBuilderTaggedRecipes 的用途见 40-41 处的说明。

-- ↑ AllBuilderTaggedRecipes 定义之后。
-- ★ 惰性建表的经典写法：is_character_ingredient 首调为 nil，
--   于是真建表，之后复用。反射的是 constants.lua:2123 CHARACTER_INGREDIENT。
-- ↑ is_character_ingredient 是 file-local 的（43 行 local），不污染全局。
local is_character_ingredient = nil
-- ★★ IsCharacterIngredient 的反射方向值得注意：
--   `for k, v in pairs(CHARACTER_INGREDIENT)`，k 被丢弃、**v 被当真值**。
--   ⇒ 这张表的键（HEALTH/MAX_HEALTH/…）只是 UI 用的短名，
--     真正的判据是值（decrease_health/half_health/…）。
--   ★ 这与 2138 行 TECH_INGREDIENT 的注释 "Value is used as key for NAME" 呼应。
function IsCharacterIngredient(ingredienttype)
-- ★ `if is_character_ingredient == nil` —— 惰性建表的触发条件。
    if is_character_ingredient == nil then
-- ↑ 惰性触发判定。
-- ★ 建表：从 nil 变成 {}。此后 45 行恒为 false 分支。
        is_character_ingredient = {}
-- ★★ `for k, v in pairs(CHARACTER_INGREDIENT)` —— 反射全局常量表。
--   k（HEALTH/MAX_HEALTH/…）被丢弃，**v** 被存为真值。
--   这是「以常量的值为判据」的反射写法。
        for k, v in pairs(CHARACTER_INGREDIENT) do
-- ↑ 反射常量表的循环起点。
-- ★ `is_character_ingredient[v] = true` —— 建一张「值集合」表，实现 O(1) 判定。
            is_character_ingredient[v] = true
-- ↑ 值集合写入。
-- ↑ 建表循环结束。
        end
-- ↑ 反射循环结束。
-- ↑ 惰性分支结束。
    end
-- ↑ 惰性分支结束。
-- ★ 51 行的 `ingredienttype ~= nil and ...` 是**防御性判据**：
--   Ingredient.type 未设时（构造漏参）返回 false 而不是崩。
--   注意 ingredienttype 若是非字符串（如数字），下标访问只会返回 nil，
--   不报错——Lua 的宽松性在这里被当成了特性使用。
    return ingredienttype ~= nil and is_character_ingredient[ingredienttype] == true
-- ↑ IsCharacterIngredient 结束。
end
-- ↑ IsCharacterIngredient 返回。
-- ↑ 空行分隔。

-- ★ is_tech_ingredient 同样是 file-local 惰性缓存，与 43 行同构。
local is_tech_ingredient = nil
-- ★ IsTechIngredient 与 IsCharacterIngredient 是**完全同构**的两份代码。
--   各自维护一张惰性缓存表。
--   ⚠ 若将来新增第三类材料类型，必须复制第三份；
--     框架不提供「材料类型注册表」这种可扩展点。
function IsTechIngredient(ingredienttype)
-- ★ 与 45 行同构的惰性触发。
    if is_tech_ingredient == nil then
-- ↑ 惰性触发判定（TECH 版）。
-- ★ 与 46 行同构的建表。
        is_tech_ingredient = {}
-- ★★ `for k, v in pairs(TECH_INGREDIENT)` —— 与 47 行同构。
--   constants.lua:2140 目前只有 SCULPTING = "sculpting_material"，
--   即只有「雕刻材料」一种。⇒ 这套机制是为扩展准备的，目前近乎空转。
        for k, v in pairs(TECH_INGREDIENT) do
-- ↑ 反射 TECH_INGREDIENT。
-- ★ 与 48 行同构。
            is_tech_ingredient[v] = true
-- ↑ 值集合写入。
-- ↑ 建表循环结束。
        end
-- ↑ 反射循环结束。
-- ↑ 惰性分支结束。
    end
-- ↑ 惰性分支结束。
-- ↑ IsTechIngredient 结束。
    return ingredienttype ~= nil and is_tech_ingredient[ingredienttype] == true
-- ↑ IsTechIngredient 返回。
-- ↑ 空行分隔，进入 Recipe 类。
end
-- ↑ 空行。

-- 【§二】Recipe 类的构造。它是本文件 80% 的代码量。
-- ★★ mod_protect_Recipe 是一个**全局开关**，用于给从 mod 里
--   直接 new Recipe() 的旧写法打弃用警告。
--   推测设置位置在 modutil 的初始化里；grep 显示本文件之外无处赋值，
--   默认 false ⇒ 这段警告目前只在外部显式打开时才生效。
mod_protect_Recipe = false
-- ★ Recipe 的 attr_init 是 nil —— 意味着 Recipe 的字段**不走属性 setter**，
--   即配方字段的修改不会自动同步到客户端。
-- ★★ 这与 Equippable（equippable.lua:48）形成鲜明对比：
--     装备属性必须同步，所以 equippable 有 4 个 setter；
--     配方数据全在服务端，客户端靠 classified 拿另一份副本，故无 setter。

-- ★★★ 16 个位置参数，是全游戏最长的构造签名之一。
--   原注释直言："do not add more params here, add them to placer_or_more_data"。
-- ★ 为什么这么写？历史上每次加参数都要改全部配方调用点，
--   所以后来统一改成「第 5 个参数传 table 就整个当配置袋」。
-- ★★ 但注意 74-80 行的兼容分支**有陷阱**：
--   如果某个旧调用点第 5 个位置恰好传了一个 table（当 placer 用），
--   会被误判成 more_data。placer 是字符串（prefab 名）所以不会撞，
--   但这是一个隐式契约，扩展时必须小心。
Recipe = Class(function(self, name, ingredients, tab, level, placer_or_more_data, min_spacing, nounlock, numtogive, builder_tag, atlas, image, testfn, product, build_mode, build_distance) -- do not add more params here, add them to "placer_or_more_data"
-- ★★ mod_protect_Recipe 守卫。原注释的措辞是
--   "Calling Recipe from a mod is now deprecated. Please call AddRecipe
--   from your modmain.lua file." ——即官方要求模组走 modutil 的 AddRecipe。
-- ★ 推测设置位置在 modutil 的 env 初始化中；本文件之外无处赋值，
--   故默认为 false ⇒ 该警告默认不触发。
    if mod_protect_Recipe then
-- ↑ mod_protect_Recipe 守卫判定。
-- ★ 弃用警告的实际输出文本，仅 print 不中断构造。
        print("Warning: Calling Recipe from a mod is now deprecated. Please call AddRecipe from your modmain.lua file.")
-- ↑ 弃用警告输出。
-- ↑ 守卫块结束。
    end
-- ↑ 守卫块结束。
-- ↑ 空行。

-- ★ 74-80 行是「位置参数 vs 配置袋」的双态分流。
--   传 table ⇒ more_data = 该表，placer = table.placer（可能 nil）；
--   传其他 ⇒ more_data = 空表，placer = 该值。
-- ★ Recipe2（229 行）总是走 table 分支，所以 placer 恒为 nil——
--   Recipe2 造出来的配方**不能带 placer**，这是它与 Recipe 的实质区别之一。
	local placer = nil
-- ★ more_data 局部变量，74-80 行会赋值。
	local more_data = nil
-- ★★ 74 行的 `type(...) == "table"` 是**唯一**的分流判据。
--   这就是「位置参数 vs 配置袋」双态的实现。
-- ★ 陷阱：若某个旧代码把第 5 参数传了个 table 想当别的用途，
--   会被整个吞进 more_data，placer 变成 nil。
	if type(placer_or_more_data) == "table" then
-- ↑ 双态分流判定。
-- ★ table 分支：placer 从 more_data 里取。
		placer = placer_or_more_data.placer
-- ★ table 分支：more_data 就是传入的表本身（**不拷贝**）。
		more_data = placer_or_more_data
-- ↑ else 分支起点：第 5 参数不是 table。
	else
-- ↑ else 分支。
-- ★ 非 table 分支：placer 直接取该值（通常是 prefab 名字符串）。
		placer = placer_or_more_data
-- ★ 非 table 分支：more_data 是**空表** —— 所以后续 more_data.X 全为 nil。
        more_data = {}
-- ↑ 分流结束。
	end
-- ↑ 双态分流结束。
-- ↑ 空行，进入字段赋值区。

-- ★★★ self.name —— AllRecipes 的键。改它等于改存档兼容。
    self.name          = name
-- ↑ self.name 赋值之后。

-- ★★ 三张材料表的初始化。89-96 行会把传入的 ingredients 全部重新分类。
--   ⚠ 注意：`for k,v in pairs(ingredients)` —— 材料的**顺序丢失**。
--   ⇒ 下游（builder 的扣料、UI 的材料展示顺序）不能依赖 ingredients
--     数组的原始顺序。UI 若要显示材料，通常按 ingredient.type 排序。
    self.ingredients   = {}
-- ★ character_ingredients 表在本行初始化，内容由 89-96 行填充。
--   下游 builder.lua:567-580 单独遍历它做「扣血/扣理智」。
    self.character_ingredients = {}
-- ★ tech_ingredients 同理，消费方在雕刻台流程而非 builder。
    self.tech_ingredients = {}
-- ↑ tech_ingredients 表初始化之后。
-- ★★ self.filter = more_data.filter —— 合成菜单的过滤器标记。
--   与 modutil.lua:674 AddRecipeFilter 配套：过滤器本身是外部定义的表，
--   配方通过 filter 字段挂到某个分类下。
	self.filter = more_data.filter
-- ↑ 空行，进入材料三分类循环。

-- ↑ 空行。
-- ★★ 材料三分类的实现：一个三目链。
--   判定顺序：IsCharacterIngredient → IsTechIngredient → 普通。
--   ★ 顺序即优先级：若某个 type 同时出现在两个枚举里，
--     会被归到 character 而非 tech。目前两表无交集，但这是隐式依赖。
    for k,v in pairs(ingredients) do
-- ★★ table.insert 的第一个参数是**三目链的结果**：
--   `(IsCharacterIngredient(v.type) and self.character_ingredients) or
--   (IsTechIngredient(v.type) and self.tech_ingredients) or self.ingredients`
--   ★ 判据是 v.type（字符串），所以「材料类型」本质是一个**字符串命名空间**。
--   这解释了为什么加新类型不需要改 Ingredient 类 —— 改枚举就行。
        table.insert(
-- ↑ 三目链起点。
-- ↑ 三目链第 1 段：角色代价判定。
            (IsCharacterIngredient(v.type) and self.character_ingredients) or
-- ↑ 三目链第 2 段：科技材料判定。
            (IsTechIngredient(v.type) and self.tech_ingredients) or
-- ↑ 三目链第 3 段（兜底）：普通材料。
            self.ingredients,
-- ↑ 三目链兜底（普通材料）。
-- ↑ table.insert 的待插入对象 v（Ingredient 实例本身）。
            v
-- ↑ table.insert 结束。
        )
-- ↑ table.insert 结束。
    end
-- ★↑ 循环结束后：self.ingredients / character_ingredients / tech_ingredients
--   三张表**共享**同一批 Ingredient 对象（不是拷贝）。
--   ⇒ 修改一个 Ingredient 实例会同时影响三处的引用。
--   builder.lua 的扣料逻辑遍历的正是其中一张。
-- ↑ 材料分类循环结束。

-- ★ product：产物 prefab 名。默认与 name 相同，但两者**可以不同**——
--   典型用途是「一个配方产出多个 prefab」或「产物名与配方名不同以避免覆盖」。
--   ★ 这是 AllRecipes[name] 键空间与 prefab 空间解耦的地方。
    self.product       = product or name
-- ★★ self.tab = tab  —— DEPRECATED（行内原注释）。
--   字段仍然保留，但它的**唯一实际用途**是 174 行反推
--   is_deconstruction_recipe。⇒ 这是一个「已废弃但不可删」的字段，
--   因为删掉会连带改变 174 行的行为（见 L2）。
    self.tab           = tab					-- DEPRECATED
-- ↑ 空行。

-- ↑ 空行。
-- ★ nameoverride / description：纯 UI 覆盖项（合成菜单里的名字与描述）。
--   ★ 与 21 行的 self.image = imageoverride 是同一层级的「显示覆盖」，
--     说明 Ingredient 也有自己的 override 通道（用于「材料显示为别的东西」）。
    self.nameoverride  = more_data.nameoverride -- Override the name string in the crafting menu.
-- ★ description：合成菜单里的描述文本覆盖。
	self.description   = more_data.description -- override the description string in the crafting menu
-- ↑ description 赋值之后。
-- ↑ 空行。

-- ★★ layeredimagefn —— UI 用「多层图片」合成图标。
--   与 105 行的 imagefn（单层图 + 函数）并列：
--   复杂图标走 layeredimagefn，简单图标走 imagefn。
	self.layeredimagefn = more_data.layeredimagefn
-- ↑ layeredimagefn 赋值之后。
-- ★ imagefn 与 image 的互斥设计（105-106 行）：
--   传函数 ⇒ imagefn 存函数、image 退化成 product..".tex"（占位）；
--   传字符串 ⇒ imagefn 为 nil、image 为该字符串。
--   ★ 这样 consumer 只需判断 `if recipe.imagefn then ... else ... end`。
	self.imagefn = type(image) == "function" and image or nil
-- ★★ 105-106 行的互斥赋值（原文见 105 处的注释）。
--   `self.imagefn == nil and image or (self.product..".tex")` ——
--   若 imagefn 存在则 image 退化为 product..".tex" 占位；否则 image 为传入值。
--   ★ 注意此时 image 可能是 nil（若 image 传的是函数），
--     真正的兜底在 GetImage（32 行）里。
	self.image = self.imagefn == nil and image or (self.product..".tex")
-- ↑ image/imagefn 互斥赋值结束。
-- ★★ atlas 的惰性机制在这里被**提前禁用**了：
--   107 行的 `self.atlas = (atlas and resolvefilepath(atlas))` 没有 fallback，
--   而 196 行的 GetAtlas 里才补上 `or resolvefilepath(GetInventoryItemAtlas(...))`。
--   ⇒ 构造期 atlas 恒为 nil 或显式值，绝不会是「自动推导值」。
--   110-111 行的原注释保留了被废弃的 lockedatlas/lockedimage 方案，
--   说明「配方未解锁时的灰显图」曾是一个独立字段，现已放弃。
    self.atlas         = (atlas and resolvefilepath(atlas))-- or resolvefilepath(GetInventoryItemAtlas(self.image))
-- ★ fxover：合成时的特效覆盖项（特效贴图/动画）。
	self.fxover        = more_data.fxover
-- ↑ fxover 赋值之后。
-- ↑ 空行。

-- ↑ 被注释掉的 lockedatlas —— 保留在源码里的**历史方案**：
--   「配方未解锁时显示的灰显图集」。它被废弃了，
--   推测改为由 UI 层统一处理（recipe.is_deconstruction_recipe /
--   builder.lua:464 KnowsRecipe 的结果决定灰显）。
--   ★ 保留被注释的代码是 Klei 的惯例：记录「为什么不这么做」。
    --self.lockedatlas   = (lockedatlas and resolvefilepath(lockedatlas)) or (atlas == nil and resolvefilepath("images/inventoryimages_inverse.xml")) or nil
-- ↑ 被注释的 lockedatlas。
-- ↑ 被注释掉的 lockedimage（同上）。
    --self.lockedimage   = lockedimage or (self.product ..".tex")
-- ↑ 被注释的 lockedimage。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ sortkey 与 rpc_id 都取自 num。
--   sortkey = num         —— 合成菜单里的稳定排序键（按构造顺序）；
--   rpc_id   = num         —— modutil 会在 AddRecipe 时改写成哈希（见 114 行注释）。
--   ★ 两个字段初值相同是巧合：一个是排序键、一个是网络 ID，
--     生命周期不同，只有在配方不是由 AddRecipe 注册时才相等。
    self.sortkey       = num
-- ★★ 114 行原注释："mods will set the rpc_id in SetModRPCID when called by
--   AddRecipe()" —— 即 rpc_id 初值是 num，但走 modutil.AddRecipe 的配方
--   会在 200 行的 SetModRPCID 里被换成 smallhash(name)。
--   ⇒ 两种注册路径产生**不同的 rpc_id 空间**：官方配方用序号，模组配方用哈希。
    self.rpc_id        = num --mods will set the rpc_id in SetModRPCID when called by AddRecipe()
-- ↑ rpc_id 初值赋值 + mod 说明。
-- ★★★ level 的存储形式 —— 本文件最容易被误解的一行。
--   `self.level` **不是数字**，而是 TechTree.Create(level) 的产物：
--   一张以 40 个科技轴名为键、值为所需等级（缺省 0）的稀疏对照表。
--   techtree.lua:70-74 的 Create 会遍历 AVAILABLE_TECH 逐项补 0。
--   ⇒ 推论：self.level 永远不为 nil，详见 HEADER_EXTRA 的 L4。
--   ★ 真正的「多轴科技比较」不在本文件，在 components/builder.lua 的
--     KnowsRecipe 家族；recipe.lua 对玩家的科技等级一无所知。
    self.level         = TechTree.Create(level)
-- ★★ self.placer —— 放置器 prefab 名。
--   Recipe2 构造的配方这个字段恒为 nil（见 233 行的极简路径），
--   ⇒ **只有 Recipe（老写法）才支持 placer**。
    self.placer        = placer
-- ↑ self.placer 赋值之后。
-- ★ min_spacing 默认 3.2：建造类配方放置器之间的最小间距，
--   单位是世界单位（约等于 1 网格）。用于「一次只能放一个」的摆件。
    self.min_spacing   = min_spacing or 3.2
-- ↑ 空行。

-- ↑ 空行。
-- ↑ 空行。
    
-- ★★ testfn：placer 的**自定义可放置性测试**，覆盖默认的 IsDeployPointClear。
--   ★ 121 行的 overridecandeployrecipeatpointfn 是它的加强版：
--     同样是覆盖 CanDeployRecipeAtPoint 的默认处理，
--     但可以完全接管而不只是测试。两者并存说明历史上加过两轮。
    self.testfn        = testfn					-- custom placer test function if default test isn't enough
-- ★★ 121 行已在 120 处详述：overridecandeployrecipeatpointfn 接管
--   CanDeployRecipeAtPoint 的默认 IsDeployPointClear 处理。
--   ★ 与 testfn 的区别：testfn 只是「测试」，这个是「整体覆盖」。
    self.overridecandeployrecipeatpointfn = more_data.overridecandeployrecipeatpointfn -- For overriding CanDeployRecipeAtPoint's default IsDeployPointClear handling.
-- ↑ overridecandeployrecipeatpointfn 赋值之后。
-- ★★ canbuild：返回**失败原因字符串**或 false —— 与 Action.fn 的约定一致
--   （参见 actions.lua 的 `return false, "XXX"` 模式）。
--   ⇒ 合成失败原因字符串同样是 UI 契约的一部分。
	self.canbuild      = more_data.canbuild		-- custom test function to see if we should be allowed to craft this recipe, return a build action fail message if false
-- ↑ 空行。

-- ↑ 空行。
-- ★ unlocks_from_skin 是**布尔 → 枚举**的转换（124-130 行）。
--   注意分支条件是 `level == TECH.LOST`：**只有「失落的」配方**
--   才能从皮肤解锁为 ALWAYS。
--   ★ 这解释了 TECH.LOST 的语义：它不是「科技等级为 0」，
--     而是「标记为可通过皮肤/合成台获得的特殊配方」。
    if more_data.unlocks_from_skin then -- Boolean flag to enum value based on recipe context.
-- ★★ `if level == TECH.LOST` —— 只有「失落的」配方能从皮肤
--   获得 ALWAYS 级解锁（SKINUNLOCKS.ALWAYS = 1，constants.lua:3013）。
--   ★ 这说明 TECH.LOST 是一个**语义标签**而非数值等级：
--     它标记「这条配方不由科技树解锁，而是靠皮肤/合成台获得」。
        if level == TECH.LOST then
-- ↑ unlocks_from_skin 的 LOST 分支判定。
-- ★ 赋值 SKINUNLOCKS.ALWAYS（=1）。
            self.unlocks_from_skin = SKINUNLOCKS.ALWAYS
-- ↑ else 分支起点：非 LOST 配方只能通过合成台解锁。
        else
-- ★ 赋值 SKINUNLOCKS.CRAFTINGSTATION（=2）。
            self.unlocks_from_skin = SKINUNLOCKS.CRAFTINGSTATION
-- ↑ CRAFTINGSTATION 赋值之后。
-- ↑ 枚举转换块结束。
        end
-- ↑ else 分支结束。
-- ↑ unlocks_from_skin 判定块结束。
    end
-- ↑ unlocks_from_skin 块结束。
-- ★★ nounlock 的三来源合并：unlocks_from_skin > nounlock > false。
--   131 行是**唯一一个把三者合成**的地方，下游只需读 nounlock。
--   ★ 注意 unlock_from_skin 的值不是 bool 而是 SKINUNLOCKS 枚举（1/2），
--     但 nounlock 这里只把它当 true 用（`or` 短路），
--     所以枚举信息保留在 unlock_from_skin 字段里供 builder.lua:283 细判。
    self.nounlock      = self.unlocks_from_skin or nounlock or false
-- ↑ 131 行的续（空行）。

-- ↑ nounlock 三来源合并之后。
-- ★ numtogive：产物数量。134 行允许完全接管（override_numtogive_fn）。
--   ★ 配合 167 行的 getlimitedrecipecount 看：
--     后者是「客户端与服务端都知道限量」的配方在外部合成台用的查询钩子，
--     原注释明确警告只在「两端都知道限量」时用。
    self.numtogive     = numtogive or 1
-- ★★ override_numtogive_fn：完全接管产物数量。
--   与 133 行的 numtogive 是「默认值 vs 计算值」的关系。
--   ★ 注意它挂在 more_data 上（不是位置参数），符合 67 行的约定。
	self.override_numtogive_fn = more_data.override_numtogive_fn
-- ↑ override_numtogive_fn 赋值之后。
-- ↑ 空行。

-- ↑ 空行。
-- ★★★ builder_tag / builder_skill：机器人的建造配方绑定。
--   ★★ 危险默认值见 HEADER_EXTRA 第 4 条与 180 行：
--     不设 allowautopick = 会被登记进 AllBuilderTaggedRecipes，
--     即「会被 WX78 / 蜜蜂等自动捡走并使用」。
--   mod 作者必须显式写 allowautopick = false 才能阻止。
    self.builder_tag   = builder_tag or nil
-- ★ builder_skill：与 builder_tag 并列的第二种机器人建造绑定，
--   面向「按技能而非按标签」工作的机器人（新版 WX78 技能树）。
    self.builder_skill = more_data.builder_skill or nil
-- ↑ builder_skill 赋值之后。
-- ★ no_builder_tag：反向开关 —— 明确禁止某类机器人建造此配方。
	self.no_builder_tag		= more_data.no_builder_tag
-- ↑ no_builder_tag 赋值之后。
-- ★ no_builder_skill：同上，对技能维度。
	self.no_builder_skill	= more_data.no_builder_skill
-- ↑ no_builder_skill 赋值之后。
-- ★ forward_ingredients：技能树替换基础配方时，告知 crafting
--   「应该转发到哪个替代配方」。这是技能树（沃尔特/Wanda/Wortox）
--   覆盖原有配方链的机制入口。
	self.forward_ingredients = more_data.forward_ingredients --skill trees may swap out some basic ingredient recipes; this will let crafting know which alternate recipes to forward to
-- ★ sg_state / buildingstate：建造时状态图进入的状态名。
--   原注释「buildingstate is the old variable name」说明这是改名兼容。
--   ★ 与 actions.lua 的状态图契约呼应：动作执行期走 sg_deconstructing 等。
	self.sg_state      = more_data.sg_state or more_data.buildingstate or nil -- overrides the SG state to use when crafting the item (buildingstate is the old variable name)
-- ↑ 空行，紧接 build_mode 之前。

-- ↑ 空行。
-- ★★ build_mode 默认 LAND（constants.lua:2224 BUILDMODE：NONE/LAND/WATER）。
--   WATER 是水_BUILD 配方（如救生筏）必需的落点模式。
--   build_distance 默认 1 —— 放置点相对玩家的距离约束。
    self.build_mode    = build_mode or BUILDMODE.LAND
-- ★ build_distance 默认 1：放置点与玩家的距离约束。
--   与 actions.lua 里的 distance 是不同层的概念（一个是配方属性，
--   一个是动作属性），但最终都会影响「走过去放」。
    self.build_distance= build_distance or 1
-- ↑ build_distance 赋值之后。
-- ↑ 空行。

-- ↑ 空行。
-- ★ no_deconstruction / decon_ignores_finiteuses：拆解相关的两个开关。
--   后者的原注释字段名暗示「拆解时忽略有限耐久」，
--   典型用于「耐久已耗尽但仍可拆解回收部分材料」的物品。
    self.no_deconstruction = more_data.no_deconstruction -- function or bool
-- ★ decon_ignores_finiteuses 的说明见 146 处。
    self.decon_ignores_finiteuses = more_data.decon_ignores_finiteuses -- function or bool
-- ↑ decon_ignores_finiteuses 赋值之后。
-- ★★ require_special_event：把配方限定在某个特殊事件期间可用。
--   GetValidRecipe（216 行）会用 IsSpecialEventActive 过滤它。
--   ⇒ 典型用途：万圣节限定食物、春节限定装饰。
    self.require_special_event = more_data.require_special_event
-- ↑ require_special_event 赋值之后。
-- ★ always_allow_buffered_placer：**绕过 KnowsRecipe 检查**的逃生舱。
--   原注释：useful for placing buildings out of crafting stations。
--   ⚠ 风险：任何模组配方设了这个字段，玩家就能在未解锁时通过
--     buffered placer 放置它——等于给配方开后门。这是设计取舍，不是 bug。
	self.always_allow_buffered_placer = more_data.always_allow_buffered_placer or nil -- skip KnowsRecipe check if buffered; useful for placing buildings out of crafting stations
-- ↑ 空行。

-- ↑ 空行。
-- ★ dropitem：产物直接掉在地上而非进背包（与 numtogive 配合）。
--   ★ 154 行的 recipedisplaynamefn 与 155 行的 hint_msg 是两个 UI 钩子，
--     156 行的 force_hint 见 HEADER_EXTRA 第 6 条。
	self.dropitem      = more_data.dropitem
-- ★★ dropitem：产物直接落地而非进背包。
--   ★ 与 158 行的 manufactured 是不同维度：
--     dropitem 说「产物去哪」，manufactured 说「谁来造产物」。

-- ↑ dropitem 赋值之后。
-- ★ actionstr：合成动作在 UI 上的动词（覆盖默认的「制作」）。
--   例：分解类配方会显示「拆解」。
	self.actionstr     = more_data.actionstr
-- ↑ actionstr 赋值之后。
-- ★ recipedisplaynamefn：完全接管显示名的函数。
--   与 101 行的 nameoverride（静态字符串）并列。
    self.recipedisplaynamefn = more_data.recipedisplaynamefn
-- ↑ recipedisplaynamefn 赋值之后。
-- ★ hint_msg：合成菜单里的提示文字（如「需要科技站」）。
	self.hint_msg      = more_data.hint_msg
-- ↑ hint_msg 赋值之后。
-- ★★★ force_hint：「即使 nounlock 也显示成锁着的样子」。
--   ★★ 典型场景：配方 nounlock（不需要解锁）但因**科技等级差 1**
--     而暂时做不了；此时 UI 需要提示「差一级科技」，
--     若不设force_hint 就会被显示成「随时可做」，玩家困惑。
--   ⇒ 这是**显示开关**，不影响能否合成。
	self.force_hint    = more_data.force_hint -- show locked recipe (i.e. missing +1 tech level) even if we are "nounlock"
-- ↑ force_hint 赋值 + 说明。
-- ↑ 空行。

-- ↑ 空行。
-- ★★★ manufactured：若为 true，**物品不由 builder 组件创建**，
--   而由合成台自己处理（原型机工厂 / 彩虹核心等）。
--   ⇒ 这是 builder 的「产物生成」环节的第一个分支点，
--     也解释了 141 行为什么要有 sg_state 这种底层字段。
	self.manufactured = more_data.manufactured -- if true, then it is up to the crafting station to handle creating the item, not the builder component
-- ★ station_tag：把配方限定到带某个 tag 的原型机工厂上，
--   只在 CRAFTING_FILTERS.CRAFTING_STATION 分类下出现。
    self.station_tag  = more_data.station_tag -- If set to a tag this will only show up in CRAFTING_FILTERS.CRAFTING_STATION when the prototyper machine has this tag.
-- ★ 160 行原注释解释 station_tag 的语义：
--   "If set to a tag this will only show up in CRAFTING_FILTERS.
--   CRAFTING_STATION when the prototyper machine has this tag." ——
--   即「配方挂在某类原型机工厂下」，配合 158 行的 manufactured 使用。

-- ↑ station_tag 赋值 + 说明。
-- ★★★ limitedamount：限量合成（战役模式 / 熔炉等）。
--   162-166 行：构造期就调用 DeclareLimitedCraftingRecipe 登记到全局表
--   （simutil.lua:930），这样存档加载器才知道这条配方有限量。
--   ★★ TheSim 守卫的用意：updateprefabs 阶段（构造 prefab 但不建世界）
--     时 TheSim 不存在，此时执行 simutil 的登记会崩。
--     ⇒ 这是「同一份代码在两种初始化模式下都跑」的典型防御。
    self.limitedamount = more_data.limitedamount
-- ★ 162 行 `if self.limitedamount then` —— 限量配方的登记入口。
    if self.limitedamount then
-- ↑ limitedamount 判定。
-- ★★ `if TheSim then` —— 见 §二 的详细说明：
--   updateprefabs 阶段 TheSim 不存在，此时调用 simutil 的全局登记会崩。
--   原注释直接写了 "updateprefabs guard"。
        if TheSim then -- updateprefabs guard
-- ↑ TheSim 守卫。
-- ★ DeclareLimitedCraftingRecipe(self.name)（simutil.lua:930）—— 登记到全局限量表。
            DeclareLimitedCraftingRecipe(self.name)
-- ↑ DeclareLimitedCraftingRecipe 调用。
-- ↑ TheSim 守卫块结束。
        end
-- ↑ TheSim 守卫块结束。
-- ↑ limitedamount 判定块结束。
    end
-- ↑ limitedamount 块结束。
-- ★ getlimitedrecipecount 与 limitedamount 的差别：
--   前者把限量判定交给配方自己（并在 170 行登记进
--   EXTERNALLY_HANDLED_LIMITED_RECIPES 通知外部合成台），
--   ★ 原注释明确警告：**只在客户端与服务端都知道限量时才用**。
--     否则会出现「客户端显示可做、服务端拒绝」的不一致。
    self.getlimitedrecipecount = more_data.getlimitedrecipecount -- NOTES(JBK): Only use this for recipes the client and server both know the limit to outside of crafting stations.
-- ↑ getlimitedrecipecount 判定块起点。
    if self.getlimitedrecipecount then
-- ↑ getlimitedrecipecount 赋值。
-- ★ 与 163 行的 TheSim 守卫同构，同一个生命周期考虑。
        if TheSim then -- updateprefabs guard
-- ↑ TheSim 守卫（getlimitedrecipecount 版）。
-- ★★ `table.insert(EXTERNALLY_HANDLED_LIMITED_RECIPES, self.name)` ——
--   通知「外部合成台」这些配方的限量由配方自己处理，不由 builder 管。
--   ★ 这是给「原型机工厂 / 彩虹核心」等自建合成系统的登记表。
            table.insert(EXTERNALLY_HANDLED_LIMITED_RECIPES, self.name)
-- ↑ EXTERNALLY_HANDLED_LIMITED_RECIPES 登记。
-- ↑ TheSim 守卫块结束。
        end
-- ↑ TheSim 守卫块结束。
-- ↑ getlimitedrecipecount 判定块结束。
    end
-- ↑ getlimitedrecipecount 块结束。
-- ↑ 空行。

-- ↑ 空行。
-- ⚠ 疑似缺陷 L2：`tab == nil` 即判定为「分解配方」。
--   推理依据：Recipe2（229 行）传入 tab=nil，随后 236 行显式改写为 false，
--   说明官方自己也必须「写错再修正」。
--   ⇒ 后果：任何直接调用 Recipe(...) 且不传 tab 的新代码，
--     会被静默标记 is_deconstruction_recipe=true，
--     进而在 GetValidRecipe（216 行）被永久过滤 —— 配方「不存在」且无报错。
--   这是本文件最隐蔽的坑。
	self.is_deconstruction_recipe = tab == nil
-- ↑ 空行。

-- ↑ 空行。
-- ★★ source_recipename：「这个配方的基础配方名是什么」。
--   原注释举例 Winona 的扫描器 —— 需要知道某物品的**原始**配方名
--   才能反查材料。⇒ 这是「配方派生链」的溯源字段：
--   当技能树用 forward_ingredients 生成派生配方时，
--   source_recipename 记录源头，升级物品时按源头查材料。
    self.source_recipename = more_data.source_recipename -- NOTES(JBK): What the basis recipename is used to create this object useful for things like Winona scanner.
-- ↑ source_recipename 赋值 + 说明。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ 构造的最后三步：分配 sortkey → 登记全局表 → 跑模组钩子。
--   注意 num 在 178 行自增，所以 self.sortkey 拿到的是**自增前**的值；
--   第 1 条配方 sortkey = 0。
    num                = num + 1
    AllRecipes[name]   = self
-- ★↑ AllRecipes[name] = self —— 同名覆盖，无警告（见 §一）。
-- ★★ AllBuilderTaggedRecipes 的登记条件（含默认危险值，见 HEADER_EXTRA）。
--   原注释 "donotautopick filtered items should set allowautopick in the recipe
--   if they are to be picked up by things for the player" 的措辞很别扭，
--   实意是：**要阻止机器人捡走，就必须显式设置 allowautopick**。
    if (self.builder_tag ~= nil or self.builder_skill ~= nil) and more_data.allowautopick == nil then -- NOTES(JBK): "donotautopick" filtered items should set allowautopick in the recipe if they are to be picked up by things for the player.
-- ★★ `AllBuilderTaggedRecipes[name] = self.builder_tag or self.builder_skill` ——
--   value 存的是 tag/skill 字符串本身（不是 self），因为下游机器人
--   只需要「这个配方归我管」这一位信息，不需要完整配方对象。
--   ★ 表结构因此是 `{ [配方名] = tag字符串 }`，value 类型是 string。
        AllBuilderTaggedRecipes[name] = self.builder_tag or self.builder_skill
-- ↑ AllBuilderTaggedRecipes 登记。
-- ↑ 登记条件块结束。
    end
-- ↑ 登记条件块结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ 模组后置钩子：构造完成后按注册顺序跑两批回调。
--   RecipePostInit  —— 按配方名注册（modutil.lua:613），只对特定配方生效；
--   RecipePostInitAny —— 对**每一个**配方生效（modutil.lua:602）。
--   ★★ 这是本文件唯一的扩展点。因为 AllRecipes 是全局唯一表且构造即冻结，
--     模组无法事后插桩，必须在这两个钩子里改写 self 的字段。
--   ★ ModManager 判空（184 行）说明非 mod 环境（工具/单测）也走这段。
    if ModManager then
-- ★★ `ModManager:GetPostInitFns("RecipePostInit")` —— 按名注册的钩子。
--   modutil.lua:613 的 env.AddRecipePostInit 提供注册入口，
--   k 是配方名。只有当前 self.name 命中注册名时才回调。
        for k,recipepostinit in pairs(ModManager:GetPostInitFns("RecipePostInit")) do
-- ↑ 取 RecipePostInit 钩子列表。
-- ★ `recipepostinit(self)` —— 把**完整构造好的 self** 交给模组改写。
            recipepostinit(self)
-- ↑ 调用 RecipePostInit 钩子。
-- ↑ RecipePostInit 循环结束。
        end
-- ↑ RecipePostInit 循环结束。

-- ★★ `GetPostInitFns("RecipePostInitAny")` —— 无条件对每条配方回调。
--   ★ 它排在 RecipePostInit **之后**（184-191 的顺序），
--     所以 Any 钩子能看到 PostInit 钩子改写的结果。
--   ⇒ mod 作者若希望最终决定权，应注册 Any。
        for k,recipepostinitany in pairs(ModManager:GetPostInitFns("RecipePostInitAny")) do
-- ↑ 取 RecipePostInitAny 钩子列表。
-- ★ `recipepostinitany(self)` —— 同样是交出 self 供改写。
            recipepostinitany(self)
-- ↑ 调用 RecipePostInitAny 钩子。
-- ↑ RecipePostInitAny 循环结束。
        end
-- ↑ RecipePostInitAny 循环结束。
-- ↑ ModManager 守卫块结束。
    end
-- ↑ ModManager 块结束。
-- ↑ Recipe 类构造结束。
end)
-- ↑ Recipe 构造结束。
-- ↑ 空行分隔，进入查询函数区。

-- ↑ 空行。
-- 【§三】查询与校验。整个文件对外只暴露 4 个函数。
function Recipe:GetAtlas()
-- ★★ GetAtlas 的 fallback 只在这里出现（对照 107 行构造期的无 fallback）。
--   `self.atlas = self.atlas or resolvefilepath(...)` 同样是惰性记忆化：
--   每条配方只做一次图集反查。
	self.atlas = self.atlas or resolvefilepath(GetInventoryItemAtlas(self.image))
-- ★ GetAtlas 的 `or resolvefilepath(...)` fallback —— 与 107 行对照（那里没有）。
	return self.atlas
-- ↑ atlas fallback 记忆化。
-- ↑ GetAtlas 返回值。
end
-- ↑ GetAtlas 返回。
-- ↑ GetAtlas 结束。

-- ↑ GetAtlas 结束。
-- ★★ SetModRPCID：把 rpc_id 从自增序号换成**配方名的小哈希**。
--   为什么？序号只在单进程内有效；模组配方需要跨进程（服务端算、客户端查）
--   一致的稳定 ID，smallhash(name) 才能保证两端一致。
function Recipe:SetModRPCID()
-- ★★ `local rpc_id = smallhash(self.name)` —— 小哈希（32 位左右）。
--   目的：让 rpc_id **跨进程稳定**。序号 num 在不同进程里不同，
--   但同一配方名在任何机器上哈希一致。
    local rpc_id = smallhash(self.name)
-- ↑ smallhash 计算。
-- ★★ 碰撞检测循环。遍历全表找同哈希的另一条配方。
--   ⚠ 见 L3：O(n²) 成本 + 只警告不拒绝。

-- ↑ 碰撞检测循环起点。
-- ⚠ 疑似缺陷 L3：哈希碰撞检测是**全表 O(n) 扫描**，
--   且 205 行只 print 不中断。1000+ 配方时每注册一条都扫一遍，
--   是 O(n²) 的注册开销。实际注册发生在 mod 加载期，可接受；
--   但「检测到碰撞却不拒绝」是弱契约——两个模组配方名哈希相同会静默合并。
    for _,v in pairs(AllRecipes) do
-- ★ `v.rpc_id == rpc_id` —— 注意此时 self.rpc_id 还是旧值，尚未被覆盖。
        if v.rpc_id == rpc_id then
-- ↑ 哈希相等判定。
-- ★ 205 行的 print 是**唯一**的冲突反馈，措辞带 "ERROR:" 但不中断。
            print("ERROR:hash collision between recipe names ", self.name, " and ", v.name )
-- ↑ 碰撞警告输出。
        end
-- ↑ 碰撞检测循环结束。
    end
-- ↑ 碰撞检测循环结束。
-- ★ `self.rpc_id = rpc_id` —— 真正赋值在这里（循环之后）。
    self.rpc_id = rpc_id
-- ↑ rpc_id 正式赋值。
-- ↑ SetModRPCID 结束。
end
-- ↑ SetModRPCID 结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★★★ GetValidRecipe 是全局最重要的过滤器，四重过滤逐层收窄：
--   ① TheNet == nil              —— 无网络上下文（如主菜单）→ 一律无效；
--   ② IsRecipeValidInGameMode    —— 游戏模式过滤（gamemodes.lua:302）；
--   ③ not is_deconstruction_recipe —— 见 L2；
--   ④ require_special_event 未激活 —— 季节活动限定配方。
-- ★★ 注意返回 `rec or nil`：Lua 里 `false or nil` = nil，
--   所以这里返回的是「配方对象或 nil」，**从不返回 false**。
--   调用方只需 `if recipe ~= nil`。
function GetValidRecipe(recname)
-- ★★ 212 行是四重过滤的第①重：`TheNet == nil or not IsRecipeValidInGameMode(...)`。
--   ⇒ 主机菜单 / 主菜单 / 单机启动早期，GetValidRecipe 一律返回 nil。
--   原因是配方可见性依赖**当前服务器的游戏模式**。
    if TheNet == nil or not IsRecipeValidInGameMode(TheNet:GetServerGameMode(), recname) then
-- ↑ 模式过滤判定。
-- ★ 无效则裸 return（等价 return nil）。
        return
-- ↑ 无效时的裸 return。
-- ↑ 模式过滤块结束。
    end
-- ★ `local rec = AllRecipes[recname]` —— 查表。
    local rec = AllRecipes[recname]
-- ↑ 查表。
    return rec ~= nil and not rec.is_deconstruction_recipe and (rec.require_special_event == nil or IsSpecialEventActive(rec.require_special_event)) and rec or nil
-- ★↑ 返回 `rec or nil`：从不为 false。调用方用 `~= nil` 判定。
-- ★★ 216 行的四重过滤（第②③④重）已在 211 处逐条列出。
--   此处补充：`rec or nil` 里的 rec 是 215 行的查表结果，
--   所以 216 行是「查表 + 过滤 + 返回」的合并表达式。
--   ★ 注意 Lua 的 and/or 短路：`A and B and C and D and rec or nil`，
--     若 A 为 false 则结果落到 `or nil`；若 A~C 都真则返回 rec。
--     由于 rec 是对象（永远为真），这个写法是安全的。
end
-- ↑ 四重过滤返回。
-- ↑ GetValidRecipe 结束。

-- ↑ GetValidRecipe 结束。
-- ★ IsRecipeValid 是 GetValidRecipe 的布尔包装，供 UI 批量查询。
function IsRecipeValid(recname)
-- ★ IsRecipeValid 只是一行包装，返回布尔。
    return GetValidRecipe(recname) ~= nil
-- ↑ 布尔包装返回。
-- ↑ IsRecipeValid 结束。
end
-- ↑ IsRecipeValid 结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ RemoveAllRecipes 把三样东西一起重置（AllRecipes / AllBuilderTaggedRecipes / num）。
--   ★ num 必须归零，否则新加载的配方 sortkey 会从一个很大的值开始，
--     导致「重载后合成菜单排序全变」。这正是 HEADER_EXTRA 第 4 条的推论。
--   使用场景：重载模组时先清空再重建。
function RemoveAllRecipes()
-- ★★ `AllRecipes = {}` —— **整个替换**而非清空。
--   因为 AllRecipes 是全局变量，其它模块持有的是引用，
--   替换会让所有旧引用失效（这正是重载时想要的效果）。
    AllRecipes = {}
-- ↑ AllRecipes 整体替换。
-- ★ 同步重置 AllBuilderTaggedRecipes —— 必须与 224 行成对。
    AllBuilderTaggedRecipes = {}
-- ↑ AllBuilderTaggedRecipes 重置。
-- ★ num = 0 —— 见 HEADER_EXTRA 第 4 条：必须归零，否则 sortkey 断层。
    num = 0
-- ↑ num 归零。
-- ↑ RemoveAllRecipes 结束。
end
-- ↑ RemoveAllRecipes 结束。
-- ↑ 空行。

-- ↑ 空行。
-- 【§四】Recipe2 —— 「现代写法」的子类，是 recipes.lua 的主力。
-- ★★ 与 Recipe 的实质差异只有两点：
--   ① 第 4 参数位置传的是 **tech**（Recipe 那里叫 level，语义相同）；
--   ② 强制 is_deconstruction_recipe = false（236 行）。
--   ★ tab 恒为 nil（Recipe2 不传），因此必须显式修正——见 L2。
Recipe2 = Class(Recipe, function(self, name, ingredients, tech, config) -- add new optional params to config
-- ★★ `Recipe2 = Class(Recipe, function(self, name, ingredients, tech, config)` ——
--   第 4 参数叫 tech（Recipe 叫 level），语义相同：都是科技要求。
--   命名差异是历史遗留，读者容易误以为是两种东西。
	if config ~= nil then
-- ↑ Recipe2 构造签名。
-- ★★ 参数转发是一次「位置 → 配置袋」的完整重排：
--   Recipe2 收到的 config 被拆散，config 整体又被当作 more_data（第 5 参数）。
--   ⚠ 因此 Recipe2 支持的**全部**字段 = config 表的字段 ∪ Recipe 的位置参数，
--     但两者的名字可能不同（如 min_spacing 两边同名，靠转发对齐）。
--   ★ 233 行是 config 为 nil 的极简路径：只传 5 个参数，
--     于是 placer/numtogive/atlas/image/testfn/... 全部走默认值。
		Recipe._ctor(self, name, ingredients, nil, tech, config, config.min_spacing, config.nounlock, config.numtogive, config.builder_tag, config.atlas, config.image, config.testfn, config.product, config.build_mode, config.build_distance)
-- ★★ 233 行的极简路径：config 为 nil 时只传 5 个参数。
--   ⇒ 此时 Recipe 构造里的 tab=nil、placer=nil、min_spacing 默认 3.2、
--     nounlock=nil、numtogive=1、builder_tag=nil、atlas=nil、image=nil、
--     testfn=nil、product=nil、build_mode=nil、build_distance=nil。
--   ★ 关键：product=nil ⇒ 98 行 `product or name` 兜底为 name。
	else
-- ↑ config 判定。
		Recipe._ctor(self, name, ingredients, nil, tech)
-- ↑ 极简构造路径。
-- ↑ config 判定分支结束。
	end
-- ↑ 分支结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ `self.is_deconstruction_recipe = false` —— 见 L2。
--   ★ 这行存在的**唯一原因**就是 Recipe2 不传 tab，
--     导致 174 行的 `tab == nil` 把它误判成拆解配方。
--   ⇒ 一个纯粹的「修正上一行刚犯的错」，两行代码互为因果。
	self.is_deconstruction_recipe = false
-- ↑ is_deconstruction_recipe 修正。
end)
-- ★↑ Recipe2 构造结束。236 行的修正让 is_deconstruction_recipe 回到 false。
-- ↑ Recipe2 类结束。

-- ↑ Recipe2 结束。
-- ★ DeconstructRecipe：拆解配方 = 「产物是材料」的反向配方。
--   ★ 与 Recipe2 的对照最能说明架构：两者都传 tab=nil，
--     但 DeconstructRecipe 在 241 行又显式设为 true（Recipe2 设为 false）。
--   ⇒ 再次印证 L2：这个字段的值完全由子类**事后赋值**决定，
--     构造期的推断（tab==nil）只是个初值。
-- ★★ 拆解配方的三要素：
--   return_ingredients —— 「产出的材料」，对应正常配方的 ingredients；
--   TECH.NONE          —— 永远不锁（不需要科技就能拆）；
--   nounlock = true     —— 不占用合成栏位。
DeconstructRecipe = Class(Recipe, function(self, name, return_ingredients, config)
-- ★★ `Recipe._ctor(self, name, return_ingredients, nil, TECH.NONE, config)` ——
--   注意参数位：level 位置传的是 **TECH.NONE**，tab 位置传 **nil**。
--   TECH.NONE 保证「拆解永远不需要科技」，nil 让 174 行判为 true。
--   ★★ 对比 233 行 Recipe2 的极简路径：Recipe2 传 tech，DeconstructRecipe
--     传 TECH.NONE —— 这是两者的核心语义分界。
	Recipe._ctor(self, name, return_ingredients, nil, TECH.NONE, config)
-- ↑ DeconstructRecipe 构造调用。
-- ★ 241 行是**冗余**的：240 行已让 tab=nil → 174 行已判为 true。
--   与 236 行同理，是「防御性重复赋值」。★ 说明作者不信任 174 行的推断。
	self.is_deconstruction_recipe = true
-- ↑ 冗余的 true 赋值。
-- ★ nounlock = true 是拆解配方的语义核心：拆解永远可用，
--   所以永远显示在合成菜单的「可做」列表里。
	self.nounlock = true
-- ↑ nounlock = true。
-- ↑ DeconstructRecipe 类结束。
end)
-- ↑ DeconstructRecipe 结束。
-- ↑ 文件末行（换行符产生的空串）。

-- ↑ 文件末尾空串（split 产生的）。