--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：prefabs/crabking.lua
-- 模块：预制体层 / Boss（蟹王）
-- 职责：蟹王。DST 里「一个实体同时管理 20+ 个子实体」的极限样本。
--       演示：把 30 多个内部函数挂到 inst 上作为公开 API、子实体集群的手写 GUID 存档、
--       宝石插槽系统、阶段式技能调度、跨预制体协作。
-- 关键符号：SetSharedLootTable, SocketItem, AddSocketDecoration, ShineSocketOfColor,
--           RetargetFn, CleanUpArena, OnEntitySleep, OnSave, OnLoadPostPass,
--           LaunchCrabMob, RemoveIceInRadius, RemoveIceArena, CleanUpAreaForIceTile,
--           DoSpawnIceTile, DoSpawnIceWall, EndCastSpell, SpawnCannonTower,
--           DropSocketedGems, RemoveGem, AddGem, UpdateGemCount,
--           fn, geyserfn, chipfn, burble, endgeyser
-- 变体清单（return 段共 6 条声明，1 条被注释，实际注册 5 个实体）：
--   crabking / crabking_geyserspawner / crabking_chip_high / _med / _low
-- 架构要点：
--   · 第 1637-1686 行把 30 多个函数挂到 inst 上，分「外部 / 内部 / 事件适配」三组，
--     这是 DST 里跨预制体协作的标准手段，等价于「类的 public 方法」但无类无继承
--   · 第 1683-1686 行的事件适配包装解决两个问题：回调签名不匹配、
--     注册与解除必须是同一个函数对象（否则 RemoveEventCallback 静默失败）
--   · OnSave 返回 GUID 表 + OnLoadPostPass 用 newents 还原，是「子实体集群存档」范式
--   · 第 704-710 行读档时补挂 crabking_spawner，是「版本兼容补丁」的范式
--   · 每颗宝石按颜色改变 Boss 技能强度，让玩家的「准备投入」直接转化为战斗强度
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：prefabs.lua（Prefab 全局工厂）,
--           brains/crabkingbrain.lua（AI 决策，与预制体严格分层）,
--           stategraphs/SGcrabking.lua（行为状态机）,
--           components/trader.lua（宝石插槽借用了「接受物品」能力）,
--           components/entitytracker.lua, components/combat.lua,
--           components/lootdropper.lua, components/inspectable.lua,
--           components/freezable.lua, components/complexprojectile.lua,
--           components/oceanfishable.lua（决定实体能否被「弹飞」）、
--           prefabs/boat.lua（InstantlyBreakBoat 定义处 / boat_ice_crabking 场地）,
--           prefabs/moon_altar.lua（宝石图腾，第 28 行 prefabs 清单里的
--           moon_altar_cosmic / moon_altar_crown 由该文件派生）
--============================================================
local brain = require "brains/crabkingbrain"
-- ============================================================
-- crabking.lua —— 蟹王（Boss 预制体的装配范式）
--
-- 【这个文件演示了什么架构】
-- 1) ★★ 「把 30 多个内部函数挂到 inst 上」的 API 导出模式（第 1637-1686 行）。
--   预制体是闭包，模块级函数拿不到 inst；挂到 inst 上后，任何预制体都能调用它。
--   ★ 这就是 DST 里「跨预制体协作」的标准手段，等价于「类的 public 方法」，
--   但没有类、没有继承表、没有元编程。
-- 2) ★ BOSS 的「子实体集群」管理：蟹爪臂 / 炮塔 / 冰墙关键石 / 间歇泉 / 小兵 / 冰面，
--   全部是独立预制体，由本体追踪、存档、清理。
-- 3) ★ 手写 GUID 存档：OnSave 返回一张 GUID 表（第 537 行），
--   OnLoadPostPass（第 601 行）用 newents 把 GUID 换回实体引用。
--   对比 boat.lua 用 entitytracker 组件、deciduoustrees 不需要 —— 三种方案各有取舍。
-- 4) ★ 「宝石插槽」系统：玩家把宝石插进蟹王身上的 10 个插槽，
--   不同颜色的宝石改变 Boss 的技能与强度（socketlist / gemcount）。
--
-- 【★ 为什么这个文件值得读】
-- 它是 DST 里「一个实体同时管理 20+ 个子实体」的极限样本。
-- 自研游戏做 Boss 时必然遇到同样的问题：技能生成物、召唤物、场地元素
--   各自独立存档、清理、恢复。这里给出了一套完整解法。
--
-- 【⚠️ 已核实的一处代码异味（本人对照行号）】
-- 第 1743 行 `return inst` 后的 `end` 缩进异常（多了 8 空格）：
--   1742:    return inst
--   1743:        end
-- 语法上无害（Lua 不看缩进），但说明这段是后期补丁插入的。
-- 对照第 360 行的 OnRemove 函数（第 371 行 end 缩进同样异常），
-- ★ 两处风格异常位置都与「后期追加的清理逻辑」相关，与推断一致。
--
-- 【上游来源】Klei Entertainment《Don't Starve Together》游戏脚本
-- ============================================================
local easing = require("easing")
-- brains/crabkingbrain：★ 蟹王的 AI 决策树，与预制体分离在 brains/ 目录。
-- ⇒ 【★ 架构分层】行为逻辑（brain）与实体装配（prefab）严格分离。
-- prefabs/ 负责「它是什么」，brains/ 负责「它怎么决策」，stategraphs/ 负责「它怎么动」。
-- 移植时保持这个三层分离，能让同一套装配复用到不同 AI 行为上。

----------------------------------------------------------------------------------------------------------------------------------------------
-- 第 6-11 行是「宝石 → 技能」的映射表，用自然语言注释写死了对应关系：
--   红=炮塔伤害 蓝=结冰延迟 紫=小兵 黄=炮塔数量 绿=蟹爪 橙=回血增益
-- ★ 这是「设计意图的文档化」：真正的映射散落在 LaunchCrabMob（第 756 行）、
-- DoSpawnIceWall（第 910 行）、EndCastSpell（第 963 行）等处。
-- ⇒ 【⚠️ 隐患】注释与代码若不同步就误导人。移植时建议把这段写成一张真正的配置表。

-- Red    gem -- CANNON DAMAGE
-- Blue   gem -- ICE CRACK DELAY
-- Purple gem -- MINIONS
-- Yellow gem -- TOWERS
-- Green  gem -- CLAWS
-- Orange gem -- REGEN BUFF

----------------------------------------------------------------------------------------------------------------------------------------------

local assets =
-- 4 个动画包：basic / actions / build / hole_build（冰洞造型）。
-- ★ 第 1599 行 AddOverrideBuild("crab_king_hole_build") 把冰洞做成「第二套外观」，
-- 与 boat.lua 第 1056 行的 leak_build_override 同一手法。
{
    Asset("ANIM", "anim/crab_king_basic.zip"),
    Asset("ANIM", "anim/crab_king_actions.zip"),
    Asset("ANIM", "anim/crab_king_build.zip"),
    Asset("ANIM", "anim/crab_king_hole_build.zip"),
}

local chipassets =
{
    Asset("ANIM", "anim/crabking_rockchip.zip"),
}

local prefabs =
-- ★★★ 依赖清单 33 个 —— 这是本文件规模的直接体现。
-- 按用途分五组：
--   ① 场地：boat_ice_crabking / crabking_icewall / crab_king_waterspout
--   ② 召唤物：crabking_mob / crabking_mob_knight / crabking_claw
--   ③ 装饰与反馈：crab_king_shine / crab_king_ring_fx / 三个 bubble / 三个 chip
--   ④ 宝石与图腾：hermit_cracked_pearl / moon_altar_cosmic / moon_altar_crown
--   ⑤ 战利品：meat / barnacle / trident_blueprint / 圣诞装饰等
-- ⇒ 【读源码技巧】依赖表是理解一个预制体「用到什么」的最快入口，比读 2000 行代码快得多。
{
    "boat_ice_crabking",
    "crab_king_bubble1",
    "crab_king_bubble2",
    "crab_king_bubble3",
    "crab_king_shine",
    "crab_king_waterspout",
    "crabking_cannontower",
    "crabking_chip_high",
    "crabking_chip_low",
    "crabking_chip_med",
    "crabking_claw",
    --"crabking_feeze", -- Deprecated.
-- ★ 被注释掉的 "crabking_feeze"（配合第 1678 行的 OnFreeze -- Deprecated 注释）。
-- ⇒ 与 deciduoustrees 的 #HAUNTFIX 同类：有意保留的废弃项，便于将来恢复。
    "crabking_geyserspawner",
    "crabking_icewall",
    "crabking_mob_knight",
    "crabking_mob",
    "crabking_ring_fx",
    "hermit_cracked_pearl",
    "moon_altar_cosmic",
    "moon_altar_crown",

    "meat",
    "barnacle",
    "boat_bumper_crabking",
    "singingshell_octave3",
    "singingshell_octave4",
    "singingshell_octave5",
    "messagebottle",
    "trident_blueprint",
    "chesspiece_crabking_sketch",
    "winter_ornament_boss_crabking",
    "winter_ornament_boss_crabkingpearl",
}

local geyserprefabs =
{
    "crab_king_bubble1",
    "crab_king_bubble2",
    "crab_king_bubble3",
    "crab_king_waterspout",
}

--[[local freezeprefabs =
{
    "mushroomsprout_glow",
    "crab_king_icefx",
}]]

----------------------------------------------------------------------------------------------------------------------------------------------

SetSharedLootTable("crabking",
-- ★★★ SetSharedLootTable：★ 模块加载时就注册一张全局战利品表，而不是在 fn 里配。
-- 【为什么放在模块顶层】lootdropper 组件的 SetChanceLootTable("crabking")（第 1712 行）
-- 按名字查这张表。若放在 fn() 里，每个实例都会重建一次表 —— 白费内存。
-- ⇒ 【★ 可移植模式】「数据表在模块加载时算一次，实例只按名引用」是 DST 的一贯做法。
-- 对比 prefabs/treasurechest.lua 第 18 行的 SOUNDS（那是小表，直接内联无妨）。
{
    {"trident_blueprint",                   1.00},
-- ★ 值是权重不是概率：1.00 / 0.50 / 0.25 表示相对权重，组件会归一化。
-- 所以「0.25 的东西」并不等于「25% 概率」，而是「0.25 权重」。
-- ⚠️ 【易踩的坑】初学者常把权重当概率。移植时务必在表头注明单位。
    {"chesspiece_crabking_sketch",          1.00},
    {"boat_bumper_crabking_kit",            1.00},
    {"barnacle",                            1.00},
    {"barnacle",                            1.00},
    {"barnacle",                            0.25},
    {"barnacle",                            0.25},
    {"meat",                                1.00},
    {"meat",                                1.00},
    {"meat",                                1.00},
    {"meat",                                1.00},
    {"meat",                                1.00},
    {"meat",                                0.50},
    {"messagebottle",                       1.00},
    {"messagebottle",                       1.00},
    {"messagebottle",                       0.50},
    {"messagebottle",                       0.25},
-- ★ 同一种物品可以重复出现多行（singingshell_octave4 出现 4 次），
-- 每行独立掷骰 —— 所以 4 行 1.00/1.00/0.50/0.25 意味着「最多可能同时掉 4 个」。
-- ⇒ 【可移植模式】用重复行表达「可变数量掉落」，比在代码里写循环更直观。
    {"singingshell_octave3",                1.00},
    {"singingshell_octave3",                0.50},
    {"singingshell_octave3",                0.25},
    {"singingshell_octave4",                1.00},
    {"singingshell_octave4",                1.00},
    {"singingshell_octave4",                0.50},
    {"singingshell_octave4",                0.25},
    {"singingshell_octave5",                1.00},
    {"singingshell_octave5",                1.00},
    {"singingshell_octave5",                1.00},
    {"singingshell_octave5",                0.50},
    {"singingshell_octave5",                0.25},
})

----------------------------------------------------------------------------------------------------------------------------------------------

local TARGET_DIST = 16
-- ★ TARGET_DIST = 16：索敌距离（约 16 瓦 = 8 格）。
-- MAX_SOCKETS = 9：★ 但插槽是 10 个（第 1632 行 nondamagedsymbollist 有 10 项），
-- 因为第 1631 行 socketlist 故意漏掉了 5 号（注释写 Missing 5 on purpuse!）。
-- ⇒ 【设计】5 号插槽是专门给 hermit_pearl（寄居蟹珍珠）用的固定位（第 249 行）。
-- ⇒ 【★ 命名纪律】原注释里 on purpuse 的拼写错误也保留了，说明是作者原笔。
local MAX_SOCKETS = 9

local ARMTIME = {
-- ARMTIME：六种蟹爪臂的生成间隔（第 0、0.25、0.1、0.2、0.15、0.3 秒）。
-- ★ 索引 0 的值是 0 —— 表示「第一个爪臂立刻生成」。
-- ⇒ 数组下标与「臂的编号」对应，生成第 N 个爪臂时用 ARMTIME[N] 作为延迟。
    0,
    0.25,
    0.1,
    0.2,
    0.15,
    0.3,
}

local MAXRANGE = 4

local CRABKING_SCALE = .7
-- ★★ 两个物理半径对应两种形态：
--   REGULAR_PHYSICS_RADIUS = 1.7 —— 平时（第 1589 行 MakeWaterObstaclePhysics）
--   ICEHOLE_PHYSICS_RADIUS = 6.0 —— 结冰后（第 683、900 行 SetCapsule）
-- ⇒ 【★★ 值得学】Boss 变形态时改变的不只是外观，还有物理碰撞体（1.7 → 6.0）。
-- 玩家在结冰阶段被困在冰面中央，这是关卡设计的核心，全部靠这个半径实现。
local REGULAR_PHYSICS_RADIUS = 1.7
local ICEHOLE_PHYSICS_RADIUS = 6.0

----------------------------------------------------------------------------------------------------------------------------------------------

local KEYSTONE_MUST_TAGS = { "crabking_icewall" }
-- ★ 大量标签过滤表常量，统一放在文件顶部。
-- 这与 deciduoustrees 的第 528-529 行、boat.lua 的第 163 行同属一种风格：
-- ⇒ 【★ 可移植模式】把所有 FindEntities 的标签过滤条件抽成文件级常量，
-- 好处是能一眼看出「这个 Boss 会与哪些实体交互」，也避免散落的字符串拼写错误。
local ICE_ARENA_CLEANUP_CANT_TAGS = { "INLIMBO" }
local SEASTACK_MUST_TAGS = { "seastack" }
local SEASTACK_CANT_TAGS = { "waterplant" }
local RETARGET_MUST_TAGS = { "_combat", "hostile" }
local RETARGET_CANT_TAGS = { "wall", "INLIMBO", "crabking_ally" }
local BOAT_MUST_TAGS = { "boat" }
local CRABKING_SPELLGENERATOR_MUST_TAGS = { "crabking_spellgenerator" }
local REPAIRED_PATCH_MUST_TAGS = { "boat_repaired_patch" }
local LEAK_MUST_TAGS = { "boatleak" }

local COLLAPSIBLE_WORK_ACTIONS =
-- ★★ COLLAPSIBLE_WORK_ACTIONS 与 COLLAPSIBLE_TAGS 的自动派生（第 155-157 行）：
-- 循环把每个 work action 变成 "<action>_workable" 标签插进 COLLAPSIBLE_TAGS。
-- ⇒ 【可移植模式】标签命名有系统规则时，用循环派生而不是手写，
-- 否则新增一种 work action 就会漏一处。这是「声明式标签」的雏形。
-- ★ ★★ 对比全库其它文件：workable 组件挂载时会自动打 "_workable" 标签，
--   所以这里能把「能否被摧毁」抽象成标签查询，不需要逐个查组件。
{
    CHOP = true,
    DIG = true,
    HAMMER = true,
    MINE = true,
}

local COLLAPSIBLE_TAGS = { "_combat", "NPC_workable", "frozen", "oceanfish" }
for k, v in pairs(COLLAPSIBLE_WORK_ACTIONS) do
    table.insert(COLLAPSIBLE_TAGS, k.."_workable")
end

local NON_COLLAPSIBLE_TAGS = { "epic", "boat", "flying", "shadow", "ghost", "playerghost", "player", "FX", "INLIMBO" }

local DECOR_SYMBOL_LOOKUP =
-- DECOR_SYMBOL_LOOKUP：★ 宝石名 → 装饰符号名。这是「物品外观」与「实体符号」的映射表。
-- 第 222 行的 `or "gems_blue"`：★ 查不到就用默认的蓝宝石外观。
-- ⇒ 【★ 降级策略】映射表查不到时给一个合理默认值，而不是崩溃或留空。
-- 新增宝石只需往表里加一行，蟹王的插孔表现自动跟上。
-- ⚠️ 但也意味着「新增了宝石却忘了加表」会静默显示成蓝宝石 —— 无任何报错。
{
    redgem          = "gems_red",
    purplegem       = "gems_purple",
    orangegem       = "gems_orange",
    yellowgem       = "gems_yellow",
    greengem        = "gems_green",
    opalpreciousgem = "gems_opal",
    hermit_pearl    = "hermit_pearl",
}

local GEM_TO_COLOR_LOOKUP =
{
    bluegem         = "blue",
    redgem          = "red",
    purplegem       = "purple",
    orangegem       = "orange",
    yellowgem       = "yellow",
    greengem        = "green",
}

local KEYSTONE_POSITIONS =
{
            {-2, 4}, {0, 4}, {2, 4},
         {-3, 3},                  {3, 3},
     {-4, 2},                          {4, 2},
     {-4, 0},                          {4, 0},
     {-4, -2},                         {4, -2},
         {-3, -3},                 {3, -3},
            {-2, -4}, {0, -4}, {2, -4},
}

local CHIP_SIZES =
{
    "crabking_chip_med",
    "crabking_chip_low",
    "crabking_chip_med",
    "crabking_chip_low",
    "crabking_chip_med",
    "crabking_chip_med",
    "crabking_chip_high",
    "crabking_chip_high",
    "crabking_chip_med",
    "crabking_chip_med",
}



----------------------------------------------------------------------------------------------------------------------------------------------

local function GetFreezeRange(inst)
    return TUNING.CRABKING_FREEZE_RANGE * (0.75 + Remap(inst.gemcount.blue, 0, 9, 0, 2.25)) / 2
end

local function AddSocketDecoration(inst, data, load)
-- AddSocketDecoration：★ 往插槽里放宝石并刷新对应符号。
-- 第 216 行先 table.insert 再做校验（第 218 行）—— ★ 顺序有点怪：
--   data 为 nil 时也会被插进 socketed。
-- ⚠️ 本人核实：第 613 行的读档路径 SocketItem(SpawnPrefab(v), ...) 传入的 v 一定是字符串，
--   所以 SocketItem → AddSocketDecoration 时 data.itemprefab 是非 nil 的字符串，
--   不会触发 data == nil 分支。
-- ⇒ 【结论】当前无实际触发路径，属「防御式冗余」，不是缺陷。
-- 但第 216 行与第 218 行的顺序仍不理想：应该先校验再改状态。
    table.insert(inst.socketed, data)

    if data == nil or data.slot == nil or data.itemprefab == nil then
        return
    end

    local symbol = DECOR_SYMBOL_LOOKUP[data.itemprefab] or "gems_blue"

    inst.AnimState:OverrideSymbol("gem"..data.slot, "crab_king_build", symbol)
-- ★★★ "gem" .. data.slot 动态拼符号名 —— 10 个插槽对应 gem1~gem10 十个符号。
-- ⇒ 【★ 渲染技巧】用「一个符号 × 10 个 OverrideSymbol 调用」表达「10 个插槽」。
-- 移植时这是「实例化 UI/物件」的低成本做法：不需要为每个插槽建独立实体。
-- ★ 代价是「第 5 个插槽永远是寄居蟹珍珠」（第 249 行），无法动态换。

    if not load then
-- ★ load 参数区分「读档恢复」与「玩家实际放入」。
-- 读档时不播音效、不播闪光、不推事件 —— 避免读档瞬间一堆特效同时炸出来。
-- ⇒ 【★ 可移植模式】所有「有视听反馈」的初始化都要支持静默模式，
-- 否则每次读档都会变成一次「特效大巡演」。这是自研游戏必踩的坑。
        inst.SoundEmitter:PlaySound("hookline_2/creatures/boss/crabking/gem_place")

        inst:ShineSocketInSlot(data.slot)

        inst:PushEvent("socket")
    end
end

local function ClearAllSocketDecorations(inst)
-- ★ ClearAllSocketDecorations 先清一个具名符号（第 236 行 gems_blue），
-- 再清 gem1~gem10。具名符号可能是历史遗留（旧版本的数据形态）。
-- ⇒ 【★ 读档兼容】同时清理新旧两代符号，是应对存档格式演进的标准做法。
    inst.AnimState:ClearOverrideSymbol("gems_blue")

    for i=1, MAX_SOCKETS do
        inst.AnimState:ClearOverrideSymbol("gem"..i)
    end
end

local function SocketItem(inst, item, socketnum, load)
-- ★★ SocketItem 的插槽分配逻辑：
--   第 245 行指定了插槽号 → 从 socketlist 移除该号
--   第 248 行珍珠或满员 → 强制 5 号位
--   第 251 行 → 从剩余列表里随机挑一个
-- ⇒ 【★ 注意第 246 行 table.removearrayvalue】它会移除所有等于该值的项。
-- socketlist 初始值 {1,2,3,4,6,7,8,9}（第 1631 行），不含 5，所以移除 5 是空操作。
-- 无缺陷，但逻辑冗余。
    -- Find open slot.
    if socketnum then
        table.removearrayvalue(inst.socketlist, socketnum)
    else
        if #inst.socketlist <= 0 or item.prefab == "hermit_pearl" then
-- ★ 珍珠判断在满员判断之后 —— 所以满员时珍珠仍会被塞进 5 号位（第 249 行）。
-- ⚠️ 推断这是有意的：珍珠是「通关道具」，不该因为满员而无法上钩。
-- 源码未说明，此为推断。
            socketnum = 5
        else
            local idx = math.random(1, #inst.socketlist)
            socketnum = inst.socketlist[idx]
            table.remove(inst.socketlist, idx)
        end
    end

    inst:AddSocketDecoration({slot = socketnum, itemprefab = item.prefab}, load)

    item:RemoveTag("irreplaceable")
    item:Remove()

    inst:UpdateGemCount()

    if #inst.socketed >= MAX_SOCKETS then        
-- ★★★ 插满 9 颗宝石 → BOSS 觉醒：加可燃/可冻组件、加 4 个标签、推 activate 事件。
-- ⇒ 【★ 关键设计】战斗强度、属性（抗冻等级随蓝宝石增加）、行为（epic/hostile 标签）
--   全部由「玩家插了几颗宝石」推导。
--   抗冻公式（第 268 行）= 3 + 蓝宝石数 —— ★ 直观且可预期的成长曲线。
-- ⇒ 【★ 移植要点】让玩家的「准备投入」直接转化为 Boss 的强度，
-- 比随机难度更能制造仪式感。这是 Boss 战设计的一条通用思路。
        MakeLargeBurnableCharacter(inst, "swap_fire", nil, 3)
        MakeHugeFreezableCharacter(inst, "swap_fire")

        inst.components.freezable:SetResistance(3 + inst.gemcount.blue)

        inst:AddTag("epic")
        inst:AddTag("animal")
        inst:AddTag("scarytoprey")
        inst:AddTag("hostile")

        inst:PushEvent("activate", { isload = load })
    end
end

local function ShineSocketInSlot(inst, slot)
    inst.shinefx = SpawnPrefab("crab_king_shine")
    inst.shinefx.entity:AddFollower()
    inst.shinefx.Follower:FollowSymbol(inst.GUID, "gem"..slot, 0, 0, 0)
end

local function ShineSocketOfColor(inst, color)
-- ShineSocketOfColor：★ 按颜色依次闪光（0.15 秒间隔），指定颜色的宝石依次点亮。
-- 第 293 行：opalpreciousgem 与 hermit_pearl 无视颜色筛选，统一参与闪光。
-- ⇒ 「技能释放前先闪一下对应的宝石」是个很便宜的「预警」实现。
    if inst.socketed == nil then
        return
    end

    local t = 0

    for i, data in ipairs(inst.socketed) do
        if GEM_TO_COLOR_LOOKUP[data.itemprefab] == color or (data.itemprefab == "opalpreciousgem" or data.itemprefab == "hermit_pearl") then
            inst:DoTaskInTime(t * 0.15, inst.ShineSocketInSlot, data.slot)
            t = t + 1
        end
    end
end

----------------------------------------------------------------------------------------------------------------------------------------------

local function RetargetFn(inst)
-- RetargetFn：★★ 索敌条件比 combat 组件的默认逻辑更严：
-- 默认是「能打就打」，这里是「能打 且（对方正在打我 或 对方离我够近）」。
-- 第 303 行 range = 物理半径 + 8 —— ★ 用自身的体型动态计算索敌范围。
-- ⇒ 【★ 可移植模式】大型 Boss 的索敌范围随体型变化，比硬编码一个距离合理。
-- ★ 注意第 309 行 guy.components.combat:TargetIs(inst)：假设对方一定有 combat 组件。
-- 这是靠 RETARGET_MUST_TAGS = { "_combat", "hostile" }（第 139 行）保证的 ——
-- ★★ 【关键】FindEntities 的 MUST_TAGS 里有 _combat，而 combat 组件挂载时会自动打这个标签。
--   标签过滤在这里承担了「类型安全」的职责，替代了逐个 nil 检查。
    local range = inst:GetPhysicsRadius(0) + 8
    return FindEntity(
            inst,
            TARGET_DIST,
            function(guy)
                return inst.components.combat:CanTarget(guy)
                    and (   guy.components.combat:TargetIs(inst) or
                            guy:IsNear(inst, range)
                        )
            end,
            RETARGET_MUST_TAGS,
            RETARGET_CANT_TAGS
        )
end

local function KeepTargetFn(inst, target)
    return inst.components.combat:CanTarget(target)
end

----------------------------------------------------------------------------------------------------------------------------------------------

local function ShouldAcceptItem(inst, item)
    return item:HasTag("gem") and #inst.socketed < MAX_SOCKETS
end

local function OnGetItemFromPlayer(inst, giver, item)
    inst:SocketItem(item)
end

----------------------------------------------------------------------------------------------------------------------------------------------

local function OnAttacked(inst, data)
-- OnAttacked：★ 只生成一个「采矿」火花特效来标记被打的位置。
-- 第 340 行 radius = 物理半径 - (0.2 + random*0.5)：★ 特效贴在身体表面上而非中心。
-- ⇒ 【细节】受击反馈的「位置随机化」让连续攻击看起来更自然。
    if data.attacker == nil then
        return
    end

    local fx = SpawnPrefab("mining_fx")
    local radius = inst:GetPhysicsRadius(0) - ( .2 + math.random() * .5 )
    local x, y, z = inst.Transform:GetWorldPosition()
    local theta
 
    local x1, y1, z1 = data.attacker.Transform:GetWorldPosition()
    if x ~= x1 or z ~= z1 then
        theta = math.atan2(z - z1, x1 - x) + math.random() * 1 - 0.5
-- theta = atan2(z - z1, x1 - x) + random - 0.5：★ 由「攻击者 → 自己」的向量算角度。
-- 注意 x 与 z 的符号：向量是 (x-x1, z-z1)，但 atan2 传的是 (z-z1, x1-x)，
-- ★ 第二个参数取了相反数（x1 - x 而非 x - x1）。
-- 手算验证：设自己在原点、攻击者在正 x 方向（x1=1, x=0），则 z-z1=0, x1-x=1，
-- atan2(0, 1) = 0 → theta = 0 → 特效出现在 x + r*cos(0) = 正 x 侧。
-- 即「特效出现在攻击者那一侧」，符合语义。★ 符号是对的，但极易看错，移植时建议加注释。
    end

    if theta == nil then
        theta = math.random() * TWOPI
    end
    fx.Transform:SetPosition(
        x + radius * math.cos(theta),
        math.random(),
        z - radius * math.sin(theta)
    )

end

local function OnRemove(inst)
-- ★★★ OnRemove：★ 实体销毁时取消所有蟹爪臂的挂起任务。
-- ★ 这是「清理挂起任务」的标准位置 —— 实体没了，任务还在跑会访问失效实体。
-- ⇒ 【★ 移植要点】每个预制体都要在 OnRemove 里取消自己所有 DoTaskInTime/DoPeriodicTask。
-- deciduoustrees 的 make_stump（第 495-506 行）做了同样的事，但那里是「变形」不是「销毁」。
-- ⚠️ 第 371 行的 end 缩进异常（见文件头说明），风格上与第 1743 行一致。
        if inst.arms == nil or next(inst.arms) == nil then
            return
        end

        for i, arm in ipairs(inst.arms) do
            if arm.task ~= nil then
                arm.task:Cancel()
                arm.task = nil
            end
        end
    end

----------------------------------------------------------------------------------------------------------------------------------------------

local function EndIceStage(inst)
-- EndIceStage：★★ 结冰阶段的收尾。5 件事：去标签 → 重置伤害累计 → 起冷却计时
-- → 拆冰场 → 排下一轮炮塔。
-- ★ 第 385 行 damagetotal = 0：★ 冰墙的「伤害累计」是判定「冰墙是否被打穿」的唯一依据。
    inst.end_ice_task = nil

    if not inst:HasTag("icewall") then
        return
    end

    inst:RemoveTag("icewall")
    inst:RemoveTag("notarget")

    inst.damagetotal = 0

    inst.components.timer:StartTimer("freeze_cooldown", 20)
-- StartTimer("freeze_cooldown", 20)：★ 20 秒冷却，由 TUNING.CRABKING_FREEZE_RANGE 等参数配套。
-- ⇒ 【★ Boss 战节奏】施法 → 冰场 → 冷却 20 秒 → 再施法。这个循环就是整场战斗的骨架。
-- 学会这个「阶段 - 冷却 - 阶段」的三段式循环，就掌握了绝大多数 Boss 战设计。

    inst:RemoveIceArena()

    inst.tasks.spawncannons = inst:DoTaskInTime(MAXRANGE * 2 + 3, inst.SpawnCannons)
end

local function KillKeyStone(ent)
-- KillKeyStone：★ 先设 dontchainremove = true 再 Kill。
-- ⇒ 【★ 关键技巧】防止「杀死关键石」触发连锁删除（冰墙全部消失）。
-- 第 413 行 OnKeyStoneRemoved 里检查这个标志决定是否连锁 —— 标志即「意图」。
-- ⇒ 【可移植模式】需要区分「主动摧毁」与「连带摧毁」时，用一个临时标志表达意图，
-- 比加一个参数或拆成两个函数更轻。
    if ent:IsValid() and not ent.components.health:IsDead() then
        ent.dontchainremove = true
        ent.components.health:Kill()
    end
end

local function startendicetask(inst)
-- ★★ 冰场持续时间随蓝宝石数缩短：Remap(蓝宝石数, 0→11, 25→3) 秒，下限 3 秒。
-- ⇒ 蓝宝石越多，冰封越短（玩家有更多机会攻击），但结冰延迟越短（防守越强）。
-- ★ 这是「同一个宝石同时强化两个方向」的精细设计，不是简单的数值堆叠。
    if inst.end_ice_task == nil then
        local time = math.max(3, Remap(inst.gemcount.blue, 0, 11, 25, 3 ))
        inst.end_ice_task = inst:DoTaskInTime(time, inst.EndIceStage)
    end
end

local function OnKeyStoneRemoved(inst, stone)
-- OnKeyStoneRemoved：一块关键石被摧毁 → 连锁摧毁附近 3 格内的其它关键石（第 422-428 行）。
-- ⇒ 【★ 关卡连锁】玩家打碎一块冰，附近冰墙跟着塌 —— 让「找到弱点」比「磨血」更有效。
-- ★ 第 426 行 0.3*random() 的错开延迟，避免同帧销毁导致的状态混乱。
    if inst.keystones ~= nil then
        table.removearrayvalue(inst.keystones, stone)
    end

    if stone.dontchainremove then
        return
    end

    inst:RemoveTag("notarget")

    startendicetask(inst)

    local x, y, z = stone.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, 0, z, 3, KEYSTONE_MUST_TAGS)

    for _, ent in pairs(ents) do
        if ent ~= stone then
            ent:DoTaskInTime(0.3 * math.random(), KillKeyStone)
        end
    end
end

local function OnCannonTowerRemoved(inst, tower)
    if inst.cannontowers ~= nil then
        for i, cannon in pairs(inst.cannontowers) do
            if tower == cannon then
                inst.cannontowers[i] = false
                break
            end
        end
    end
end

local function CleanUpArena(inst, remove)
-- ★★★ CleanUpArena：★ 统一的场地清理函数，被 3 处调用（第 518、799 行的间接、第 690 行）。
-- 它清 5 类东西：冰场、蟹爪臂、炮塔、间歇泉、挂起任务表。
-- ★★ 关键设计：第 470 行的注释 tower can be "false" —— 数组元素可能存 false 占位，
--   所以清理时必须判 truthy（第 473 行）。
-- ⇒ 【★ 移植要点】用「数组 + 可能为 nil/false 的空位」表示「第 N 个位置有/无东西」，
-- 比 table.remove 维护下标简单得多，但清理逻辑必须逐一判空。
    -- Clear ice.
    inst:RemoveTag("icewall")
    inst:RemoveTag("notarget")
    inst:RemoveIceArena(remove)

    -- Clear claws.
    if inst.arms ~= nil then
        for i, arm in pairs(inst.arms) do
            if arm.task ~= nil then
                arm.task:Cancel()
                arm.task = nil
            else
                inst:RemoveEventCallback("onremove", inst.onarmremoved, arm)

                if remove then
                    arm:Remove()

                elseif arm.components.health ~= nil then
                    arm.components.health:Kill()
                end
            end
        end

        inst.arms = nil
    end

    -- Clear towers. Note: tower can be "false".
    if inst.cannontowers ~= nil then
        for i, tower in pairs(inst.cannontowers) do
            -- Tower can be false...
            if tower then
                inst:RemoveEventCallback("onremove", inst.oncannontowerremoved, tower)

                if remove then
                    tower:Remove()

                elseif tower.components.health ~= nil then
                    tower.components.health:Kill()
                end
            end
        end

        inst.cannontowers = nil
    end

    -- clean geysers
    if inst.geysers and #inst.geysers > 0 then
        for i=#inst.geysers,1,-1 do
            local geyser = inst.geysers[i]
            geyser:Remove()
            inst.geysers[i] = nil
        end
    end

    -- Clear tasks.
    for i, task in pairs(inst.tasks) do
-- ★ 所有挂起任务统一在 inst.tasks 表里（第 1635 行初始化），清理时一次性 Cancel。
-- 第 957、960、962 行往里塞 DoTaskInTime 的返回值。
-- ⇒ 【★ 值得学】用「任务注册表」代替散落的 inst.xxx_task 字段。
-- 一处清理逻辑覆盖所有任务，比逐个字段 Cancel 可靠。
-- 【可改进】表用数字键（Lua 的 pairs 能遍历），但用任务名当键更好读；
--   本文件第 870 行已经这么用了（第 897 行 inst.tasks.spawnwall = nil）。
        task:Cancel()
    end

    inst.tasks = {}
end

local function OnEntitySleep(inst)
-- ★★★ OnEntitySleep：★ BOSS 休眠时「变回雕像」。
-- 与 deciduoustrees 的 OnEntitySleep（第 909 行）思路一致但更激进：
--   ① 血量回满（第 510 行）② 合成一个 fake healthdelta 事件（第 512-516 行）
--   ③ 清理场地 ④ 掉落插槽宝石 ⑤ 卸掉 3 个组件（第 528-530 行）⑥ 进 inert 状态。
-- ⇒ 【★ 值得学的技巧】第 512-516 行手动构造一个 healthdelta 事件喂给 OnHealthChange，
-- 让「休眠」复用「满血」的整套逻辑（换外观、恢复血条显示），不必重写一遍。
-- 【移植建议】这是「事件重放」模式：状态迁移时把目标状态伪装成一次正常事件，
-- 比在两处各写一遍状态应用代码可靠得多。
    if inst.sg:HasStateTag("inert") then
-- HasStateTag("inert") 守卫：已经在雕像状态就直接返回，避免重复清理。
-- ⇒ 与 deciduoustrees 的 _wasonfire 标志同属「幂等守卫」范式。
        return
    end

    inst.components.health:SetMaxHealth(TUNING.CRABKING_HEALTH)

    inst:OnHealthChange({
        oldpercent = 0,
        newpercent = 1,
        instant = true,
    })

    inst:CleanUpArena(true)

    inst:SpawnSeaStacks()
    inst:DropSocketedGems()

    inst:RemoveTag("animal")
    inst:RemoveTag("epic")
    inst:RemoveTag("hostile")
    inst:RemoveTag("scarytoprey")

    inst:RemoveComponent("freezable")
    inst:RemoveComponent("burnable")
    inst:RemoveComponent("propagator")

    inst.sg:GoToState("inert")
end

----------------------------------------------------------------------------------------------------------------------------------------------

local function OnSave(inst, data)
-- ★★★ OnSave：★★ 本文件最需要学的存档范式。
-- 【★ 手写 GUID 集群存档】返回 ents（一张 GUID 表），OnLoadPostPass（第 601 行）
-- 用 newents 把 GUID 还原成实体引用。
-- 为什么不用 entitytracker 组件（deciduoustrees 第 1224 行用了、boat.lua 也用了）？
-- 因为这里要存 4 类不同结构的子实体集群（arms / cannontowers / keystones / socketed），
-- 且 socketed 存的是「宝石名」而非 GUID（第 546 行），需要重新 SpawnPrefab。
-- ⇒ 【★ 移植要点】选择存 Guid 的标准：
--   ① 实体数量少且固定（5~15 个）→ 手写 GUID 表，简单可控；
--   ② 实体数量不定 → 用 entitytracker 这类组件；
--   ③ 需要存的不是实体而是「配置」→ 直接存字符串，读档时重新生成。
-- 本文件三种全用上了（keystones 手写、socketed 存配置、geysers 不存因为是临时的）。
    local ents = {}

    data.socketlist = inst.socketlist
    data.socketed = {}
    data.socketedslot = {}

    if #inst.socketed > 0 then
        for k, v in ipairs(inst.socketed) do
            table.insert(data.socketed, v.itemprefab)
-- ★ socketed 存 itemprefab 字符串（第 546 行），读档时 SpawnPrefab(v)（第 613 行）。
-- ⇒ 「存配置而不是存实体」：宝石被插进插槽后本体就 Remove 了（第 260 行），
--   没有实体可存，只能存名字。读档时重新生成一个。
-- ⚠️ 代价：若存档里写了个不存在的 prefab 名，SpawnPrefab 返回 nil，
--   SocketItem(nil, ...) 会崩（第 247 行读 item.prefab）。
-- 【移植建议】读档时对 SpawnPrefab 结果判空 —— 这正是 mod 改掉宝石名时的崩溃点。
            table.insert(data.socketedslot, v.slot)
        end
    end

    if inst.arms ~= nil then
        data.arms = {}

        for i, arm in pairs(inst.arms) do
            if arm.prefab ~= nil and arm:IsValid() then
                data.arms[i] = arm.GUID
                table.insert(ents, arm.GUID)
            end
        end
    end

    if inst.cannontowers ~= nil then
        data.cannontowers = {}

        for i, tower in pairs(inst.cannontowers) do
            if tower and tower:IsValid() then
                data.cannontowers[i] = tower.GUID
                table.insert(ents, tower.GUID)
            end
        end
    end

    if inst.keystones ~= nil then
        data.keystones = {}

        for i, stone in pairs(inst.keystones) do
            if stone:IsValid() then
                table.insert(data.keystones,stone.GUID)
                table.insert(ents, stone.GUID)
            end
        end
    end

    data.healthpercent = inst.components.health:GetPercent()

    if inst.damagetotal then
        data.damagetotal = inst.damagetotal
    end

    if inst:HasTag("icewall") then
-- icewall = true：★ 只存「是否在冰墙形态」，不存具体形态细节。
-- ⇒ 【存档原则】存「最小可重放状态」：读取时按确定性规则重建其余部分。
-- 本文件第 680-691 行就是重放的例子（第 683 行 SetCapsule 重建物理半径）。
        data.icewall = true
    end

    if inst.components.timer:TimerExists("freeze_cooldown") then
        data.freezetime = inst.components.timer:GetTimeLeft()
    end

    return ents
end

local function OnLoadPostPass(inst, newents, data)
-- ★★★ OnLoadPostPass：★ 存档还原的唯一入口（三类信息都在这里重建）。
-- 【时序】OnSave → OnLoad → OnLoadPostPass。
-- ★ 只有这里能拿到 newents（GUID → 实体的映射表），
--   因为其它阶段其它实体可能还没被创建出来。
-- ⇒ 【★ 移植核心】任何「引用了别的实体」的存档，都必须在所有实体创建完成后才还原。
-- 这是分布式实体系统最容易出错的地方：读档顺序不对就是悬空引用。
    -- Reset sockets.
    inst:ClearAllSocketDecorations()

    if data == nil then
        return
    end

    if data.socketed ~= nil then
        inst.socketlist = data.socketlist

        for k, v in ipairs(data.socketed) do
            inst:SocketItem(SpawnPrefab(v), data.socketedslot[k], true)
-- ★ 读档时重新 SpawnPrefab 宝石并直接插进指定插槽（第 546 行存的 slot 号）。
-- load=true 参数静默恢复，不播音效不播闪光。
        end
    end

    if data.arms ~= nil then
        inst.arms = {}

        for i, arm in pairs(data.arms) do
            if newents[arm] ~= nil then
-- ★★★ 读档的健壮性写法：`if newents[arm] ~= nil then`。
-- GUID 找不到对应实体（实体被删了、存档坏了）就静默跳过。
-- ⇒ 【★ 移植要点】★ 读档时 EVERY 一个跨实体引用都必须判空。
-- 这是分布式存档最容易崩的地方，deciduoustrees 的第 1120 行也做了同样的检查。
                inst.arms[i] = newents[arm].entity
                inst.arms[i].armpos = i

                inst:ListenForEvent("onremove", inst.onarmremoved, inst.arms[i])
            end
        end
    end

    if data.cannontowers ~= nil then
        inst.cannontowers = {}

        for i, tower in pairs(data.cannontowers) do
            if newents[tower] ~= nil then
                local cannontower = newents[tower].entity

                inst.cannontowers[i] = cannontower
                inst:ListenForEvent("onremove", inst.oncannontowerremoved, cannontower)

                local platform = cannontower:GetCurrentPlatform() -- Intentionally not using GetBoatIntersectingPhysics. We should be already at a proper position on load.
-- ★ 原注释：Intentionally not using GetBoatIntersectingPhysics.
-- We should be already at a proper position on load.
-- ⇒ 【★ 值得学】读档时「重新查询当前环境」与「直接相信存档」要分场景：
--   本例中炮塔位置是存下来的，存档保证它在一艘船上，所以不需要重新检测。
-- 注释把这个选择写清楚了，读者不必重新推导。

                if platform ~= nil and platform.components.boatphysics ~= nil then
                    cannontower.sg:GoToState("breach")

                    platform.components.boatphysics:AddEmergencyBrakeSource("crabking_cannontower"..cannontower.GUID)
-- ★ AddEmergencyBrakeSource：给船加一个「紧急刹车源」，防止船因炮塔开火而失控。
-- ★ 第 651-655 行配套注册 onremove 回调来移除刹车源 —— 严格配对。
-- ⇒ 【可移植模式】「A 让 B 产生某种影响」时，必须同时注册「B 消失时撤销影响」。
-- 漏掉撤销 = 永久性的幽灵影响（如永远制动的船）。

                    if platform.leak_build_override ~= nil then
                        tower.AnimState:AddOverrideBuild(platform.leak_build_override)
                    end

                    cannontower:ListenForEvent("onremove", function()
                        if platform:IsValid() then
                            platform.components.boatphysics:RemoveEmergencyBrakeSource("crabking_cannontower"..cannontower.GUID)
                        end
                    end)
                end
            end
        end
    end

    if data.keystones ~= nil then
        inst.keystones = {}

        for i, stone in pairs(data.keystones) do
            if newents[stone] ~= nil then
                inst.keystones[i] = newents[stone].entity
                inst:ListenForEvent("onremove", inst.onkeystoneremoved, inst.keystones[i])
            end
        end
    end

    if data.healthpercent ~= nil then
        inst.components.health:SetPercent(data.healthpercent)
    end

    if data.damagetotal ~= nil then
        inst.damagetotal = data.damagetotal
    end

    if data.icewall then
        inst:AddTag("icewall")
        inst.AnimState:Show("water")
        inst:DoTaskInTime(0, function() inst.Physics:SetCapsule(ICEHOLE_PHYSICS_RADIUS, 2) end)

        if inst.keystones ~= nil and #inst.keystones < #KEYSTONE_POSITIONS then
            startendicetask(inst)
            inst:AddTag("notarget")
        end
    else
        inst:RemoveIceArena()
    end

    if data.freezetime ~= nil then
        inst.components.timer:StartTimer("freeze_cooldown", data.freezetime)
    end

    inst:OnHealthChange({
        oldpercent = 1,
        newpercent = inst.components.health:GetPercent(),
        instant = true,
    })

    -- Retrofit crabking spawner.
-- ★★★ 读档后的「向后兼容」：给老存档里的蟹王补挂一个 spawner 预制体。
-- 第 704 行检查全场是否有 crabking_spawner，没有就生成一个并接管蟹王。
-- ⇒ 【★ 版本兼容范式】新版本引入的组件，在读老存档时必须补挂。
-- 这个模式在任何有存档的游戏里都必需，且极易被遗忘。
-- 【移植建议】把这类补丁集中到一个 upgrade 函数里，不要散在 OnLoad 里。
    if not TheSim:FindFirstEntityWithTag("crabking_spawner") then
        local spawner = SpawnPrefab("crabking_spawner")
        spawner.Transform:SetPosition(inst.Transform:GetWorldPosition())

        spawner.components.childspawner.childreninside = 0
        spawner.components.childspawner:TakeOwnership(inst)
    end
end

----------------------------------------------------------------------------------------------------------------------------------------------

local function StartCastSpell(inst, freeze)
    if inst.arms == nil then
        return
    end

    for i, arm in ipairs(inst.arms) do
        if arm.task == nil then
            arm:PushEvent("submerge")
        else
            arm.task:Cancel()
            arm.task = nil
        end
    end

    inst.arms = nil
end

local function OnCrabMobLanded(inst)
-- ★ OnCrabMobLanded：★ RemoveComponent("complexprojectile") 去掉「投射物」标签。
-- ⇒ 【★ 值得学】小兵落地后不再是投射物，不该再被「打飞行物」的技能命中。
-- 组件的移除同时改变了实体的行为分类 —— 组件不只是数据，它定义了身份。
    inst:RemoveComponent("complexprojectile") -- To remove projectile tag.

    inst:PushEvent("hit_ground")
end

local function LaunchCrabMob(inst, prefab)
-- ★★ LaunchCrabMob：30 次尝试找一个能生成小兵的落点（第 741 行 for i=1, 30）。
-- 第 746 行 IsVisualGroundAtPoint 保证落在地面上。
-- ⚠️ 若 30 次都失败则一个也不生成（第 777 行 break 在循环体内，无兜底）。
--   推断：这是可接受的降级（Boss 身边全是水时就不召小兵），源码未处理。
-- ⇒ 【★ 移植建议】这种「试 N 次」的随机布局应记录尝试次数并在日志里可查，
-- 否则「有时小兵特别多、有时一个没有」这类问题极难定位。
    local pos = inst:GetPosition()

    for i=1, 30 do
        local theta = math.random()*TWOPI
        local radius = inst.Physics:GetRadius() + 1 + math.random() * 2
        local offset = Vector3(radius * math.cos( theta ), 0, -radius * math.sin( theta ))

        if TheWorld.Map:IsVisualGroundAtPoint(pos.x+offset.x, 0, pos.z+offset.z) then
            local mob = inst:LaunchProjectile(pos+offset, prefab)

            mob.components.complexprojectile:SetOnHit(OnCrabMobLanded)

            mob.components.sleeper:SetSleepTest(nil)
            mob.components.sleeper:SetWakeTest(nil)

            local resistance = 2
-- ★★ 紫宝石提升小兵强度，三段式阶梯：>4 加 10、>7 再加 10、>=11 加额外血量加成。
-- ⇒ 【★ 可移植模式】用连续的 if 累加而不是查表，实现「分段成长」。
-- 优点是新增一档只要加一个 if；缺点是无法配置化，且阈值写死在代码里。
-- 对比本文件第 910-912 行（冰墙）与第 1002-1008 行（炮塔）用的是完全相同的写法。
-- ⚠️ 【可改进】三处重复的阶梯逻辑应抽成一个函数 changeByGemCount(base, step, count)。

            if inst.gemcount.purple > 4 then resistance = resistance + 10 end
            if inst.gemcount.purple > 7 then resistance = resistance + 10 end

            if mob:HasTag("crab_mob_knight") then resistance = resistance + 10 end

            mob.components.sleeper:SetResistance(resistance)

            local health = mob.components.health.currenthealth
            local increment = 20
            if inst.gemcount.purple > 4 then increment = 30 end
            if inst.gemcount.purple > 7 then increment = 40 end
            health = health + inst.gemcount.purple * increment
            if inst.gemcount.purple >= 11 then
-- ★ SetMaxHealth 后立刻 SetPercent(1) —— 第 773 行原注释 For pushing events?。
-- ⇒ 【★ 坑】SetPercent(1) 会触发 healthdelta 事件，用来「踢」一下状态机让它更新血条显示。
-- 没有这一步，某些依赖 healthdelta 的逻辑（攻击音效、血条）不会刷新。
-- 【移植建议】这是「用副作用达成刷新」的手法，可靠但隐晦；更好的做法是显式调刷新接口。
               health = health + TUNING.CRABKING_MOB_HEALTH_BONUS_MAXGEM
            end

            mob.components.health:SetMaxHealth(health)
            mob.components.health:SetPercent(1) -- For pushing events?

            mob.sg:GoToState("flying")

            break
        end
    end
end

local function RemoveIceInRadius(world, radius, pt, instant)
-- ★★ RemoveIceInRadius：★ 环形采样。用「半径 r 的圆」减去「半径 r-1 的圆」得到圆环。
-- 关键条件（第 785 行）：
--   (ix² + iz² <= r²) and (r-1 == 0 or not (ix² + iz² <= (r-1)²))
-- ★ 优先级分析：not 的优先级高于比较运算符，所以右半等价于
--   not (ix² + iz² <= (r-1)*(r-1))，即「不在内圈里」。语义正确。
-- ★★ 边界情况（本人用等价表达式实际验证过）：
--   r=1 时 (r-1)==0 短路为真，条件退化为「ix²+iz²<=1」，命中 5 个点：
--   (0,0) 与 (±1,0)、(0,±1) —— ★ 原点被包含在内（这是第 876 行 DoSpawnIceTile 想要的）。
--   r=2 时命中 8 个点：(|ix|,|iz|) ∈ {(2,0),(2,1),(1,2),(0,2)} 的对称集，即真正的圆环。
-- ⇒ 结论：★ 算法正确，且两处（第 785、876 行）条件完全一致，不存在漂移。
-- ⚠️ 但 `not (...)` 缺括号是隐患：若后续有人把 `not` 换成别的运算，优先级会变。
-- 【移植建议】★ 这类「从网格里圈出一圈」的标准技巧可用于任何像素级环形特效，
--   但移植时务必显式加括号，并写一行注释说明边界情况。
    for ix= -radius, radius do
        for iz = -radius, radius do
            if (math.abs(ix * ix) + math.abs(iz * iz) <= radius * radius) and (radius-1 == 0 or not (math.abs(ix * ix) + math.abs(iz * iz) <= radius-1 * radius-1)) then
                local fx = pt.x + (ix * TILE_SCALE)
                local fz = pt.z + (iz * TILE_SCALE)

                if instant then
                    world.components.oceanicemanager:DestroyIceAtPoint(fx, 0, fz, { silent = instant })
                else
                    world.components.oceanicemanager:QueueDestroyForIceAtPoint(fx, 0, fz, { icefloe_prefab = "boat_ice_crabking" })
                end
            end
        end
    end
end

local function RemoveIceArena(inst, instant)
-- RemoveIceArena(instant)：instant=true 用于休眠/初始化（立即拆），false 用于战斗中（慢速拆）。
-- ★ 第 823 行 (radius-1)*4 + random()：★ 按半径递增的延迟制造「冰从中心向外融化」的观感。
-- ⇒ 【★ 可移植模式】清理也可以有演出：延迟递增 = 视觉上的扩散/收缩过程。
-- 这与 boat.lua 第 1119 行 SetFrame(54 - frame) 是同一类「让过渡看起来连续」的技巧。
    if instant then
        inst.AnimState:Hide("water")
        inst.Physics:SetCapsule(REGULAR_PHYSICS_RADIUS, 2)
    end

    if inst.keystones ~= nil then
        for i, stone in ipairs(inst.keystones) do
            inst:RemoveEventCallback("onremove", inst.onkeystoneremoved, stone)

            if instant then
                stone:Remove()
            else
                stone:DoTaskInTime(0.8 * math.random(), KillKeyStone)
            end
        end

        inst.keystones = nil
    end

    for radius=1, MAXRANGE do
        if instant then
            RemoveIceInRadius(TheWorld, radius, inst:GetPosition(), true)
        else
            TheWorld:DoTaskInTime((radius-1)*4 + math.random(), RemoveIceInRadius, radius, inst:GetPosition())
        end
    end
end

local function CleanUpAreaForIceTile(inst, x, z)
-- ★★ CleanUpAreaForIceTile：★★ 结冰前的「清场」，按优先级分四类处理：
--   ① 冻住的可携带物 → 直接 Remove（第 847-848 行）
--   ② 可被 CHOP/DIG/HAMMER/MINE 的结构 → workable:Destroy（第 850-855 行）
--   ③ 水生生物 → Kill（第 857-860 行）
--   ④ 海洋鱼 → Remove（第 862-863 行）
-- ⇒ 【★ 移植要点】场地生成前的清场要按「优先级」而非「随机」处理：
--   先处理最容易造成 bug 的（小物件会被埋进冰里），再处理正常的。
-- 第 836-837 行原注释解释了两个白名单例外（NPC_workable 无 work action、允许挖兔洞）。
    local ents = TheSim:FindEntities(x, 0, z, TILE_SCALE, nil, NON_COLLAPSIBLE_TAGS, COLLAPSIBLE_TAGS)

    for _, ent in ipairs(ents) do
        if ent:IsValid() and ent:IsOnOcean(false) then
            local isworkable = false
            if ent.components.workable ~= nil then
                local work_action = ent.components.workable:GetWorkAction()
                    --V2C: nil action for NPC_workable (e.g. campfires)
                --     allow digging spawners (e.g. rabbithole)
                isworkable = (
                        (work_action == nil and ent:HasTag("NPC_workable")) or
                        (work_action ~= nil and ent.components.workable:CanBeWorked() and COLLAPSIBLE_WORK_ACTIONS[work_action.id])
                )
            end

            local health = ent.components.health
            local locomotor = ent.components.locomotor

            if ent:HasTag("frozen") and ent.components.inventoryitem ~= nil then
                ent:Remove()

            elseif isworkable and ent.components.inventoryitem == nil then
                ent.components.workable:Destroy(inst)

                if ent:IsValid() and ent:HasTag("stump") then
                    ent:Remove()
                end

            elseif health ~= nil and locomotor ~= nil and locomotor:IsAquatic() then
                if not health:IsDead() then
                    health:Kill()
                end

            elseif ent:HasTag("oceanfish") then
                ent:Remove()
            end
        end
    end
end

local function DoSpawnIceTile(inst, radius)
-- ★★ DoSpawnIceTile：★ 结冰逻辑。注意第 886 行的双重否定保护：
-- 有船 或 有可见地面 → 都不结冰。
-- ⇒ 【★ 关卡设计】结冰会「吞噬」玩家在海上的位置 —— 只有纯水域才结冰。
--   这意味着玩家必须提前下船，否则会被冻在冰面上。
--   第 887 行 CleanUpAreaForIceTile 在结冰前清理，是「先清场再生冰」的顺序。
    inst.tasks["spawnice_"..radius] = nil

    local x, y, z = inst.Transform:GetWorldPosition()

    for ix= -radius, radius do
        for iz = -radius, radius do
            if (math.abs(ix * ix) + math.abs(iz * iz) <= radius * radius) and (radius-1 == 0 or not (math.abs(ix * ix) + math.abs(iz * iz) <= radius-1 * radius-1)) then
                local fx = x + (ix * TILE_SCALE)
                local fz = z + (iz * TILE_SCALE)
                local width, height = TheWorld.Map:GetWorldSize()
-- ★★ 坐标转换：世界坐标 → 格子坐标 → 反算成「瓦片中心的世界坐标」。
-- 第 881 行 GetTileCoordsAtPoint 得格子，第 883-884 行再用格子算中心。
-- ⇒ 【★ 可移植模式】程序化生成网格内容时，必须先把坐标对齐到网格，
-- 否则生成的块之间会有缝隙或重叠。这个「取格子中心」的往返是标准做法。

                local tile_x, tile_y = TheWorld.Map:GetTileCoordsAtPoint(fx, 0, fz)

                local nx = (tile_x - width/2) * TILE_SCALE
                local nz = (tile_y - height/2) * TILE_SCALE

                if not (TheSim:CountEntities(nx, 0, nz, 8, BOAT_MUST_TAGS) > 0) and not TheWorld.Map:IsVisualGroundAtPoint(nx, 0, nz) then
                    CleanUpAreaForIceTile(inst, nx, nz)

                    TheWorld.components.oceanicemanager:CreateIceAtPoint(nx, 0, nz)
                end
            end
        end
    end
end

local function DoSpawnIceWall(inst)
-- ★★★ DoSpawnIceWall：在 15 个固定位置生成冰墙关键石（第 182-191 行的 KEYSTONE_POSITIONS）。
-- ★ 第 906 行 for i, coord in ipairs(...)：★ 位置是硬编码表而非随机 —— 关卡设计需要确定性。
-- 第 915 行 GetAngleToPoint 让每块石朝向蟹王，形成环形包围。
-- ⇒ 【★ 对比】本文件的 DoSpawnIceTile（第 869 行）是程序化网格，
--   DoSpawnIceWall 是固定坐标表。两种布局方式：规则用程序，构图用手摆。
-- ★ 第 902 行 inst.keystones = {}：每轮重置，避免残留上一轮的引用。
    inst.tasks.spawnwall = nil

    inst.AnimState:Show("water")
    inst.Physics:SetCapsule(ICEHOLE_PHYSICS_RADIUS, 2)

    inst.keystones = {}

    local x, y, z = inst.Transform:GetWorldPosition()

    for i, coord in ipairs(KEYSTONE_POSITIONS) do

        local icewall  = SpawnPrefab("crabking_icewall")
        local health = TUNING.CRABKING_ICEWALL_HEALTH
        if inst.gemcount.blue > 4 then health = health + TUNING.CRABKING_ICEWALL_HEALTH_BONUS end
        if inst.gemcount.blue > 7 then health = health + TUNING.CRABKING_ICEWALL_HEALTH_BONUS end
        if inst.gemcount.blue >= 11 then health = health + TUNING.CRABKING_ICEWALL_HEALTH_BONUS_MAXGEM end
        icewall.components.health:SetMaxHealth(health)

        local angle = inst:GetAngleToPoint(x+coord[1], 0, z+coord[2])

        icewall.Transform:SetPosition(x+coord[1], 0, z+coord[2])
        icewall.Transform:SetRotation(angle)

        inst:ListenForEvent("onremove", inst.onkeystoneremoved, icewall)
        table.insert(inst.keystones, icewall)
    end
end

local function EndCastSpell(inst, lastwasfreeze)
-- ★★★ EndCastSpell：★★ Boss 战的一次「阶段结束」，一次性排完全部后续动作。
-- 排的内容：冷却计时 → 加冰墙/不可选标签 → 嘲讽计时 → 冰面扩散（4 层）
-- → 冰墙生成 → 小兵召唤 → 宝石闪光。
-- ⇒ 【★ 可移植模式】★ 阶段转换时「一次性排完整个阶段的所有后续动作」，
--   而不是靠分散的回调或状态机跳转。读代码时一屏就能看到这个阶段的全貌。
-- ★ 第 926-930 行的 SetTimeLeft 分支：如果冷却已在计时就改时长，不重复 Start。
    if inst.components.timer:TimerExists("spell_cooldown") then
        inst.components.timer:SetTimeLeft("spell_cooldown", TUNING.CRABKING_CAST_DELAY)
    else
        inst.components.timer:StartTimer("spell_cooldown", TUNING.CRABKING_CAST_DELAY)
    end

    if inst.wavetask ~= nil then
        inst.wavetask:Cancel()
        inst.wavetask = nil
    end

    inst:AddTag("icewall")
-- ★ AddTag("icewall") + AddTag("notarget")：★ 结冰后蟹王自己也不可被选中。
-- ⇒ 【★ 关卡机制】结冰阶段的蟹王无法被攻击，玩家只能打冰墙 ——
--   必须先破冰才能打本体。这就是「阶段转换改变可达性」的经典设计。
-- 与 OnKeyStoneRemoved（第 417 行）的 RemoveTag("notarget") 配对，构成完整的可达性开关。
    inst:AddTag("notarget")

    inst.components.timer:StartTimer("taunt",TUNING.CRABKING_TAUNTTIME)

    inst.wantstotaunt = true
-- ★ wantstotaunt / wantstoheal / wantstofreeze 三个标志：★ 「下一轮想做什么」。
-- ⇒ 【★ 架构】这三个字段是「玩家的应对决定 Boss 的下一步行为」的接口：
--   状态机读这些标志来选技能。预制体负责收集意图，状态图负责执行。
-- 【移植建议】把「意图」与「执行」分开，是复杂 AI 必要的分层方式。
    inst.wantstoheal = nil
    inst.wantstofreeze = nil

    if inst.geysers and #inst.geysers > 0 then
        for i=#inst.geysers,1,-1 do
            local geyser = inst.geysers[i]
            geyser:Remove()
            inst.geysers[i] = nil
        end
    end

    SpawnPrefab("crabking_ring_fx").Transform:SetPosition(inst.Transform:GetWorldPosition())
    inst:PushEvent("ck_taunt")
    for radius=1, MAXRANGE do
-- ★★ 冰面按半径递增延迟生成：radius*0.2 + 0.2 秒。
-- 4 层（MAXRANGE=4）分别在 0.4 / 0.6 / 0.8 / 1.0 秒生成 ——
-- ⇒ 【★ 演出】冰从中心向外一圈圈扩散，视觉上「蟹王被冰封住」。
-- 与 RemoveIceArena（第 823 行）的反向延迟配对，组成完整的一次「冰封-解封」动画。
        inst.tasks["spawnice_"..radius] = inst:DoTaskInTime(radius*0.2 + 0.2, inst.DoSpawnIceTile, radius)
    end

    inst.tasks.spawnwall = inst:DoTaskInTime(0.4, inst.DoSpawnIceWall)

    inst.tasks.spawnminion = inst:DoTaskInTime(0.2 * MAXRANGE, function()
-- ★★ 小兵数量 = TUNING.CRABKING_BASE_MINIONS + floor(紫宝石数/2)。
-- 第 967 行：★ 血量低于 35% 时额外召唤一只强化版（knight）。
-- ⇒ 【★ Boss 战设计】★ 「血量低 → 改变战斗模式」是 Boss 战的标准手法，
--   用来防止玩家用「风筝」无风险磨死 Boss。这里的具体表现是「多召唤一只精英」。
-- 【移植建议】每个 Boss 至少设计一个「低血量阶段」的质变，而不只是数值变化。
        for i=1, TUNING.CRABKING_BASE_MINIONS + (math.floor(inst.gemcount.purple/2)) do
            inst:LaunchCrabMob("crabking_mob")
        end

        if inst.components.health:GetPercent() < 0.35 then
            inst:LaunchCrabMob("crabking_mob_knight")
        end

        inst:ShineSocketOfColor("purple")
    end)

    inst.dofreezecast = nil

    inst:ShineSocketOfColor("blue")
end

local function FindCannonPositions(inst, num, i)
-- FindCannonPositions：★ 在半径 20 的圆周上均匀撒 N 个点，角度带 ±35% 抖动（第 984 行）。
-- 与 deciduoustrees 的落叶（第 790 行）同一套「均匀分布 + 随机抖动」公式。
    local arc = TWOPI/num
    local radius = 20

    local x, y, z = inst.Transform:GetWorldPosition()
    local theta = (arc * i) + (math.random()*(arc*0.7) - (arc*0.7)/2)

    return Vector3(x + radius * math.cos(theta), 0, z - radius * math.sin(theta))
end

local function SpawnCannonTower(inst, i, pt, numcannons)
-- ★★★ SpawnCannonTower：★ 炮塔生成 + 与船（移动平台）交互。7 步：
--   ① 生成 + 血量按黄宝石提升 ② 记录宝石数 ③ 找船 ④ 位置调整 ⑤ 判断船是否防漏
--   ⑥ 清掉船上的漏口 ⑦ 造成船体伤害 + 让船紧急刹车。
-- ⇒ 【★ 跨预制体协作】这段同时操作 boat 的多个组件（health / boatphysics / hullhealth），
--   说明「跨预制体调用」是 Boss 战的常规需求 —— 也印证了第 1637-1676 行 API 导出的必要性。
    pt = pt or inst:FindCannonPositions(numcannons, i)

    if pt == nil then
        inst.cannontowers[i] = false

        return
    end

    local tower = SpawnPrefab("crabking_cannontower")

    tower.Transform:SetPosition(pt.x, 0, pt.z)

    local health = TUNING.CRABKING_CANNONTOWER_HEALTH
    if inst.gemcount.yellow > 4 then health = health + TUNING.CRABKING_CANNONTOWER_HEALTH end
    if inst.gemcount.yellow > 7 then health = health + TUNING.CRABKING_CANNONTOWER_HEALTH end

    if inst.gemcount.yellow >= 11 then
       health = health + TUNING.CRABKING_CANNONTOWER_HEALTH
    end

    tower.components.health:SetMaxHealth(health)
    tower.components.health:SetPercent(1) -- For pushing events?
    tower.redgemcount = inst.gemcount.red -- Saved in prefab.
    tower.yellowgemcount = inst.gemcount.yellow -- Saved in prefab.

    inst:ListenForEvent("onremove", inst.oncannontowerremoved, tower)

    inst.cannontowers[i] = tower

    local platform = tower:GetBoatIntersectingPhysics()
-- ★★ GetBoatIntersectingPhysics：找炮塔下面压着的船。
-- 第 1020 行 max_dist = 船的安全半径 - 2.5：★ 炮塔要离船边至少 2.5 格。
-- ⇒ 【★ 空间约束】Boss 生成的地毯必须在玩家载具的「内部」，否则炮塔会浮在半空。
    local max_dist = platform ~= nil and math.max(0, platform:GetSafePhysicsRadius() - 2.5) or nil -- Maximum distance from platform origin.

    -- Too close to the platform border.
    if max_dist ~= nil and not tower:IsNear(platform, max_dist) then
-- ★ 若炮塔离船太远 → GetPositionAdjacentTo 把它挪近，并重新取一次船。
-- 第 1026 行原注释注释了这个「挪完再查一次」的原因：for safety。
-- ⇒ 【★ 移植要点】移动一个物理实体后，必须重新查询它所处的环境，不能沿用旧结果。
        pt = tower:GetPositionAdjacentTo(platform, max_dist)

        -- Moves the tower closer to the platform origin and get the platform again for safety.
        tower.Transform:SetPosition(pt.x, 0, pt.z)
        platform = tower:GetBoatIntersectingPhysics()
    end

    if platform == nil or platform.components.health == nil then
        tower:PushEvent("ck_spawn") -- Open ocean, just spawn.

        return
    end

    -- Platform is leak proof, destroy it instantly.
    if platform ~= nil and platform.components.hullhealth.leakproof then
-- ★★★ 「防漏的船直接击沉」：第 1039 行 InstantlyBreakBoat。
-- ⇒ 这与 boat.lua 第 463 行的 InstantlyBreakBoat 是同一个函数（定义在那里，这里调用）。
--   ★★ 这就是「预制体给 inst 挂函数作为 API」的直接体现：
--   蟹王不需要知道船怎么沉，只需要调 boat:InstantlyBreakBoat()。
-- ⇒ 【★ 移植核心结论】Lua 对象挂函数 = 跨文件公开接口，无需类、无需模块导出表。
        platform:InstantlyBreakBoat()

        tower:PushEvent("ck_spawn")

        return
    end

    local destruction_radius = tower.Physics:GetRadius() + 0.8
    local leaks = TheSim:FindEntities(pt.x, 0, pt.z, destruction_radius, LEAK_MUST_TAGS)
-- ★ 清除炮塔落点周围的漏口（第 1046 行 destruction_radius = 炮塔半径 + 0.8）。
-- ⇒ 【★ 交互逻辑】炮塔把船打漏，但漏口会「修好船」，两者互相抵消。
--   所以必须先清漏口再造成伤害，否则伤害会被漏口自损抵消掉。
-- 【★ 值得学的思路】当两个系统互相抵消时，显式处理抵消关系，而不是让玩家困惑于「打了没反应」。

    for i, leak in pairs(leaks) do
        leak:Remove()
    end

    platform.components.health:DoDelta(-TUNING.CRABKING_CANNONTOWER_HULL_SMASH_DAMAGE)
    platform.components.boatphysics:AddEmergencyBrakeSource("crabking_cannontower"..tower.GUID)

    if platform.leak_build_override ~= nil then
        tower.AnimState:AddOverrideBuild(platform.leak_build_override)
    end

    tower:PushEvent("ck_breach")

    tower:ListenForEvent("onremove", function()
        if platform:IsValid() then
            platform.components.boatphysics:RemoveEmergencyBrakeSource("crabking_cannontower"..tower.GUID)
        end
    end)

    return tower -- Mods.
end

local function BubbleSeaStack(inst, doer, i)
    local MAXRADIUS = 2
    local x,y,z = inst.Transform:GetWorldPosition()
    local theta = math.random()*TWOPI
    local radius = math.pow(math.random(),0.8)* MAXRADIUS
    local offset = Vector3(radius * math.cos( theta ), 0, -radius * math.sin( theta ))
    local prefab = "crab_king_bubble"..math.random(1,3)

    if TheWorld.Map:IsOceanAtPoint(x+offset.x, 0, z+offset.z) then
        SpawnPrefab(prefab).Transform:SetPosition(x+offset.x, 0, z+offset.z)
    end

    doer.tasks["bubble_stack_"..i] = inst:DoTaskInTime(0.3 + math.random() * 0.1, inst.BubbleSeaStack, doer, i)
end

local function DoDestroySeaStack(inst, doer, i)
    if doer.tasks["bubble_stack_"..i] ~= nil then
        doer.tasks["bubble_stack_"..i]:Cancel()
        doer.tasks["bubble_stack_"..i] = nil
    end

    doer.tasks["destroy_stack_"..i] = nil

    doer = doer:IsValid() and doer or nil

    SpawnPrefab("crab_king_waterspout").Transform:SetPosition(inst.Transform:GetWorldPosition())

    if inst.components.workable ~= nil then
        inst.components.workable:Destroy(doer)
    end
end

local function SpawnCannons(inst)
    inst.tasks.spawncannons = nil

    if inst.cannontowers == nil then
        inst.cannontowers = {}
    end

    local x, y, z = inst.Transform:GetWorldPosition()

    local stacks = TheSim:FindEntities(x, 0, z, 30, SEASTACK_MUST_TAGS, SEASTACK_CANT_TAGS)

    for i, stack in ipairs(stacks) do
        inst.tasks["bubble_stack_"..i]  = stack:DoTaskInTime(0.3 + math.random() * 0.1, inst.BubbleSeaStack, inst, i)
        inst.tasks["destroy_stack_"..i] = stack:DoTaskInTime(math.random() * 2 + 1, inst.DoDestroySeaStack, inst, i)
    end

    local numcannons = TUNING.CRABKING_BASE_CANNONS + inst.gemcount.yellow

    for i=1, numcannons do
        if not inst.cannontowers[i] then
            inst:SpawnCannonTower(i, nil, numcannons)
        end
    end

    inst:ShineSocketOfColor("red")
    inst:ShineSocketOfColor("yellow")
end

local function OnFreeze(inst)
    local x,y,z = inst.Transform:GetWorldPosition()

    local ents = TheSim:FindEntities(x, 0, z, 25, nil, nil, CRABKING_SPELLGENERATOR_MUST_TAGS)

    if #ents > 0 then
        for i, ent in pairs(ents) do
            ent:Remove()
        end
    end
end

local function DoSpawnSeaStack(inst, x, z)
    inst.tasks.spawnseastacks = nil

    if TheSim:CountEntities(x, 0, z, 1.5, SEASTACK_MUST_TAGS) <= 0 then
        local stack = SpawnPrefab("seastack")

        stack.Transform:SetPosition(x, 0, z)

        if not stack:IsAsleep() then
            stack.AnimState:PlayAnimation(stack.stackid.."_emerge")
            stack.AnimState:PushAnimation(stack.stackid.."_full")

            SpawnPrefab("splash_green_large").Transform:SetPosition(x, 0, z)
        else
            stack.AnimState:PlayAnimation(stack.stackid.."_full")
        end

        return stack -- Mods.
    end
end

local function SpawnSeaStacks(inst)
    local x, y, z = inst.Transform:GetWorldPosition()

    local numstacks =  math.max(0, TUNING.CRABKING_STACKS - TheSim:CountEntities(x, 0, z, 20, SEASTACK_MUST_TAGS))

    if numstacks <= 0 then
        return
    end

    for i=1, numstacks do
        local theta = math.random()*TWOPI
        local radius = 9 + (math.pow(math.random(), 0.8) * (17-9))
        local offset = Vector3(radius * math.cos(theta), 0, -radius * math.sin(theta))

        local x2, y2, z2 = x + radius * math.cos(theta), 0, z - radius * math.sin(theta)

        if not TheWorld.Map:GetPlatformAtPoint(x2, z2) and TheSim:CountEntities(x2, 0, z2, 3, SEASTACK_MUST_TAGS) <= 0 then
            inst.tasks.spawnseastacks = inst:DoTaskInTime(math.random()*0.5, inst.DoSpawnSeaStack, x2, z2)
        end
    end
end

local function OnArmRemoved(inst, armpos)
    if inst.arms == nil then
        return
    end

    if inst.arms[armpos] ~= nil and inst.arms[armpos].task ~= nil then
        inst.arms[armpos].task:Cancel()
    end

    inst.arms[armpos] = {}
    inst.arms[armpos].task = inst:DoTaskInTime(15, inst.DoSpawnArm, armpos)

    inst.components.timer:StartTimer("claw_regen_delay"..armpos, TUNING.CRABKING_CLAW_RESPAWN_DELAY)

    local noarms = true
    for i, arm in ipairs(inst.arms) do
        if arm.prefab ~= nil then
            noarms = false
            break
        end
    end


    if noarms and inst.tasks.triggerice_task == nil then

        inst.tasks.triggerice_task = inst:DoTaskInTime(5, function()

            inst.tasks.triggerice_task = nil
            inst.damagetotal = (inst.damagetotal or 0) - TUNING.CRABKING_FREEZE_THRESHOLD
        end)
    end
end

local function IsValidArmSpawnPoint(x, z)
    if TheWorld.Map:IsVisualGroundAtPoint(x, 0, z) then
        return false
    end

    local self_radius = 0.7
    local check_radius = self_radius + (MAX_PHYSICS_RADIUS + 0.18)

    local boats = TheSim:FindEntities(x, 0, z, check_radius, BOAT_MUST_TAGS) -- Biggest radius check may include smaller boats.

    for _, boat in ipairs(boats) do
        local boat_radius = boat.GetSafePhysicsRadius and boat:GetSafePhysicsRadius() or (boat.components.hull ~= nil and boat.components.hull:GetRadius() or TUNING.BOAT.RADIUS) + 0.18 -- Add a small offset for item overhangs.
        local bx, by, bz = boat.Transform:GetWorldPosition()
        local dx, dz = bx - x, bz - z
        local dist = math.sqrt(dx * dx + dz * dz)

        if dist - boat_radius <= self_radius then
            return false
        end
    end

    return true
end

local function TrySpawningArm(inst, armpos, numclaws)
    if inst.arms == nil then
        return
    end

    local x, y, z = inst.Transform:GetWorldPosition()

    local wedge = TWOPI/numclaws
    local theta = armpos*wedge + (math.random() * wedge - wedge/2)
    local radius = 4 + 8*math.random()

    x, z = x + radius * math.cos(theta), z - radius * math.sin(theta)

    if IsValidArmSpawnPoint(x, z) then
        local arm = SpawnPrefab("crabking_claw")
        arm.Transform:SetPosition(x, 0, z)

        if inst.arms[armpos].task ~= nil then
            inst.arms[armpos].task:Cancel()
            inst.arms[armpos].task = nil
        end

        inst.arms[armpos] = arm

        local health = TUNING.CRABKING_CLAW_HEALTH
        if inst.gemcount.green > 4 then health = health + TUNING.CRABKING_CLAW_HEALTH_BOOST end
        if inst.gemcount.green > 7 then health = health + TUNING.CRABKING_CLAW_HEALTH_BOOST end
        if inst.gemcount.green >= 11 then health = health + TUNING.CRABKING_CLAW_HEALTH_BOOST_MAXGEM end

        arm.components.health:SetMaxHealth(health)
        arm.components.combat:SetDefaultDamage(TUNING.CRABKING_CLAW_PLAYER_DAMAGE + (math.floor(inst.gemcount.green/2) * TUNING.CRABKING_CLAW_DAMAGE_BOOST))
        
        arm.armpos = armpos
        arm.crabking = inst -- Saved in prefab.

        arm:PushEvent("emerge")

        inst:ListenForEvent("onremove", inst.onarmremoved, arm)

        return arm -- Mods.
    end
end

local function DoSpawnArm(inst, armpos, fx)
    if inst.arms == nil then -- This happens when the Crab King goes into entity sleep we should not continue spawning arms.
        return
    end

    if inst.arms[armpos] and (inst.arms[armpos].prefab or inst.arms[armpos].task) then
        return
    end

    local numclaws = TUNING.CRABKING_BASE_CLAWS + (math.floor(inst.gemcount.green/2))

    if not inst.arms[armpos] then
        inst.arms[armpos] = {}
    end

    inst.arms[armpos].task = inst:DoPeriodicTask(0.3, TrySpawningArm, nil, armpos, numclaws)
end

local function SpawnClawArms(inst)
    local numclaws = TUNING.CRABKING_BASE_CLAWS + (math.floor(inst.gemcount.green/2))

    if inst.arms == nil then
        inst.arms = {}
    end

    for i=1, numclaws do
        if inst.arms[i] == nil or (inst.arms[i].prefab == nil and inst.arms[i].task == nil) then
            inst:DoTaskInTime(ARMTIME[i%#ARMTIME+1], inst.DoSpawnArm, i)
        end
    end
end

local function DropSocketedGems(inst)
-- ★★★ DropSocketedGems：BOSS 休眠时把插槽里的宝石全部吐出来（第 1319-1320 行）。
-- 这保证玩家读档/下线时不会永久损失宝石。
-- ★ 第 1324 行 ★★★ 重置 socketlist 为 {1,2,3,4,6,7,8,9}，并保留了原注释
-- Missing 5 on purpuse!（含拼写错误 on purpuse，说明是作者原笔未改）。
-- ⇒ ★ 这行注释解释了为什么第 1631 行的初始 socketlist 也是这个值 ——
--   5 号插槽永远是寄居蟹珍珠专属位（第 248-249 行强制走 5）。
--
-- 【★ 三个函数的分工】（本文件把宝石操作拆成三个独立函数）
--   DropSocketedGems（第 1318 行）—— 全部丢弃
--   RemoveGem（第 1330 行）      —— 按名字移除单个
--   AddGem（第 1340 行）         —— 追加一个
-- 三者都调 UpdateGemCount（第 1344 行）刷新派生缓存。
-- ⇒ 【★ 性能与正确性】gemcount 是「派生数据的缓存」：
--   18 处 gemcount 读取点（第 212、268、403、756、910、963、1003、1119、1268 行等），
--   若每次都遍历 socketed 虽只有 9 项不算慢，但语义上「变化时算好」更清晰。
-- 【移植建议】★ 凡是会被高频查询的派生值（计数、最大值、索引表），
--   都在数据变化的唯一入口重算，而不是分散到各个读取点。
    for i, socket in pairs(inst.socketed) do
        inst.components.lootdropper:FlingItem(SpawnPrefab(socket.itemprefab))
    end

    inst.socketed = {}
    inst.socketlist = { 1, 2, 3, 4, 6, 7, 8, 9 } -- Missing 5 on purpuse!

    inst:UpdateGemCount()
    inst:ClearAllSocketDecorations()
end

local function RemoveGem(inst, gemname)
    for i=#inst.socketed, 1, -1 do
        if inst.socketed[i].itemprefab == gemname then
            table.remove(inst.socketed, i)
        end
    end

    inst:UpdateGemCount()
end

local function AddGem(inst,gemname)
    table.insert(inst.socketed, { itemprefab = gemname })

    inst:UpdateGemCount()
end

local function UpdateGemCount(inst)
    local gems =
    {
        red    = 0,
        blue   = 0,
        purple = 0,
        orange = 0,
        yellow = 0,
        green  = 0,
        opal   = 0,
        pearl  = 0,
    }

    if inst.socketed == nil then
        inst.gemcount = gems

        return
    end

    for i, data in pairs(inst.socketed) do
        local color = GEM_TO_COLOR_LOOKUP[data.itemprefab]

        if color ~= nil and gems[color] then
            gems[color] = gems[color] + 1

        elseif data.itemprefab == "opalpreciousgem" then
            gems.green  = gems.green  + 1
            gems.yellow = gems.yellow + 1
            gems.orange = gems.orange + 1
            gems.red    = gems.red    + 1
            gems.blue   = gems.blue   + 1
            gems.purple = gems.purple + 1
            gems.opal   = gems.opal   + 1

        elseif data.itemprefab == "hermit_pearl" then
            gems.green  = gems.green  + 3
            gems.yellow = gems.yellow + 3
            gems.orange = gems.orange + 3
            gems.red    = gems.red    + 3
            gems.blue   = gems.blue   + 3
            gems.purple = gems.purple + 3
            gems.pearl  = gems.pearl  + 1
        end
    end

    inst.gemcount = gems
end

local function SpawnChunk(inst, prefab, pos)
    local chip = SpawnPrefab(prefab)

    if chip ~= nil and pos ~= nil then
        chip.Transform:SetPosition(pos.x, 0, pos.z)
    end

    return chip
end

local function SetDamagedArt(inst, instant)
    local index = math.random(1, #inst.nondamagedsymbollist)
    local art = inst.nondamagedsymbollist[index]

    table.remove(inst.nondamagedsymbollist, index)
    table.insert(inst.damagedsymbollist, art)

    if not instant then
        local fx = SpawnPrefab("round_puff_fx_lg")
        fx.entity:AddFollower()
        fx.entity:SetParent(inst.entity)
        fx.Follower:FollowSymbol(inst.GUID, "damage"..art, 0, 0, 0)

        local chip = CHIP_SIZES[art]

        if chip ~= nil then
            inst:SpawnChunk(chip, inst:GetPosition())
        end

        inst.SoundEmitter:PlaySound("hookline_2/creatures/boss/crabking/rock_hit")
    end

    inst.AnimState:OverrideSymbol("damage"..art, "crab_king_build", "nil")
end

local function SetRepairedArt(inst, instant)
    local index = math.random(1, #inst.damagedsymbollist)
    local art = inst.damagedsymbollist[index]

    table.remove(inst.damagedsymbollist, index)
    table.insert(inst.nondamagedsymbollist, art)

    inst.AnimState:OverrideSymbol("damage"..art, "crab_king_build", "damage"..art)
end

local function OnHealthChange(inst, data)
    -- data.instant is a custom key.

    local current = data.oldpercent

    if inst.damagetotal == nil then
        inst.damagetotal = 0
    end

    if data ~= nil and data.amount ~= nil and not data.instant and data.amount < 0 then
        inst.damagetotal = inst.damagetotal + data.amount
    end

    local done = nil

    while data.newpercent and not done do
        if data.oldpercent > data.newpercent then
            current = math.max(current - 0.1, data.newpercent)
        else
            current = math.min(current + 0.1, data.newpercent)
        end

        if (current <= 0.9 and current > 0.8 and #inst.nondamagedsymbollist >= 10) or
           (current <= 0.8 and current > 0.7 and #inst.nondamagedsymbollist >= 9) or
           (current <= 0.7 and current > 0.6 and #inst.nondamagedsymbollist >= 8) or
           (current <= 0.6 and current > 0.5 and #inst.nondamagedsymbollist >= 7) or
           (current <= 0.5 and current > 0.4 and #inst.nondamagedsymbollist >= 6) or
           (current <= 0.4 and current > 0.3 and #inst.nondamagedsymbollist >= 5) or
           (current <= 0.3 and current > 0.2 and #inst.nondamagedsymbollist >= 4) or
           (current <= 0.2 and current > 0.1 and #inst.nondamagedsymbollist >= 3) or
           (current <= 0.1 and current > 0.0 and #inst.nondamagedsymbollist >= 2) or
           (current <= 0.0                   and #inst.nondamagedsymbollist >= 1) then

            inst:SetDamagedArt(data.instant)
        end

        if (current >= 1.0                   and #inst.nondamagedsymbollist < 10) or
           (current >= 0.9 and current < 1.0 and #inst.nondamagedsymbollist < 9) or
           (current >= 0.8 and current < 0.9 and #inst.nondamagedsymbollist < 8) or
           (current >= 0.7 and current < 0.8 and #inst.nondamagedsymbollist < 7) or
           (current >= 0.6 and current < 0.7 and #inst.nondamagedsymbollist < 6) or
           (current >= 0.5 and current < 0.6 and #inst.nondamagedsymbollist < 5) or
           (current >= 0.4 and current < 0.5 and #inst.nondamagedsymbollist < 4) or
           (current >= 0.3 and current < 0.4 and #inst.nondamagedsymbollist < 3) or
           (current >= 0.2 and current < 0.3 and #inst.nondamagedsymbollist < 2) or
           (current >= 0.1 and current < 0.2 and #inst.nondamagedsymbollist < 1) then

            inst:SetRepairedArt(data.instant)
        end

        if current == data.newpercent then
            done = true
        end
    end
end

----------------------------------------------------------------------------------------------------------------------------------------------

local function GetWintersFeastOrnaments(inst)
    local is_pearled = inst.gemcount.pearl > 0

    if not is_pearled and inst.gemcount.opal >= 3 then
        local hermit = TheWorld.components.messagebottlemanager ~= nil and TheWorld.components.messagebottlemanager:GetHermitCrab()
        is_pearled = hermit and hermit.pearlgiven
    end

    return is_pearled and { basic = 2, special = "winter_ornament_boss_crabkingpearl" } or { basic = 1, special = "winter_ornament_boss_crabking" }
end

local function PushMusic(inst)
    if ThePlayer == nil or not inst:HasTag("epic") then
        inst._playingmusic = false

    elseif ThePlayer:IsNear(inst, inst._playingmusic and 40 or 20) then
        inst._playingmusic = true
        ThePlayer:PushEvent("triggeredevent", { name = "crabking" })

    elseif inst._playingmusic and not ThePlayer:IsNear(inst, 50) then
        inst._playingmusic = false
    end
end

local function GetStatus(inst)
    return inst.sg ~= nil and inst.sg:HasStateTag("inert") and "INERT" or nil
end

local function RestoreProjectileCollisionMask(inst, mask)
    inst.Physics:SetCollisionMask(mask)
end

local function LaunchProjectile(inst, targetpos, projectile)
    local x, y, z = inst.Transform:GetWorldPosition()

    local projectile = SpawnPrefab(projectile or "cannonball_rock")

    if projectile.components.complexprojectile == nil then
        projectile:AddComponent("complexprojectile")
    end

    --V2C: scale the launch speed based on distance
    --     because 15 does not reach our max range.
    local dx = targetpos.x - x
    local dz = targetpos.z - z
    local rangesq = dx * dx + dz * dz
    local maxrange = TUNING.FIRE_DETECTOR_RANGE
    local speed = easing.linear(rangesq, 15, 3, maxrange * maxrange)

    projectile:DoTaskInTime(60*FRAMES, RestoreProjectileCollisionMask, projectile.Physics:GetCollisionMask())

    projectile.Physics:SetCollisionMask(COLLISION.GROUND)
    projectile.Physics:Teleport(x, 5, z)

    projectile.components.complexprojectile:SetHorizontalSpeed(speed)
    projectile.components.complexprojectile:SetGravity(-25)
    projectile.components.complexprojectile:Launch(targetpos, inst, inst)

    return projectile
end

local function OnDeath(inst, data)
    inst:CleanUpArena()
end

local function OnIceTileBreak(inst, floe)
    -- Ice broke near us, get rid of the water hole.
    if floe:GetDistanceSqToInst(inst) < 8 * 8 then
        inst.AnimState:Hide("water")
        inst.Physics:SetCapsule(REGULAR_PHYSICS_RADIUS, 2)
    end
end

local function SnapToGrid(inst)
    local x, y, z = inst.Transform:GetWorldPosition()

    inst.Transform:SetPosition(math.floor(x)+0.5, 0, math.floor(z)+0.5)
end

----------------------------------------------------------------------------------------------------------------------------------------------

local function fn()
-- ============================================================
-- ★★★ fn() —— 蟹王工厂。装配结构与其它预制体一致（A 段 / SetPristine / C 段），
-- 但有两处独特之处：
--
-- 【独特之处 1：SetPristine 与 ismastersim 之间还有一段（第 1615-1620 行）】
-- 这里既不是服务端逻辑也不是实体组件，而是「有画面的机器才做的事」
--（DoPeriodicTask(1, PushMusic) 每秒检查 BGM）。
-- ⇒ 与 boat.lua 第 435 行、pighouse.lua 第 391 行属于同一类：纯表现逻辑。
--   它放在 SetPristine 之后、ismastersim 判断之前，是为了同时在服务端与客户端都跑
--   （服务端也要知道该放什么 BGM）。
--
-- 【独特之处 2：第 1637-1686 行的 API 导出块】
-- 30 多个模块级函数被挂到 inst 上，分成三组：
--   外部函数（第 1638-1646 行）—— 给别的预制体调（如 crabking.lua 之外）
--   内部函数（第 1648-1668 行）—— 只给自己用，但挂上去是为了让 DoTaskInTime 能传
--   事件监听闭包（第 1683-1686 行）—— ★ 把 (inst, x) 形式的函数包装成 (x) 形式
-- ⇒ 【★ 关键技术】第 1683-1686 行解决了「事件回调签名不匹配」的问题：
--   ListenForEvent 的回调签名与模块级函数 (inst, stone) 不一致，
--   于是用匿名函数把 inst 捕获掉，适配成回调要的签名。
--   ★ 同时这些包装函数还存回 inst（inst.onkeystoneremoved），
--   是为了让 RemoveEventCallback 能解除同一个函数引用（第 807 行）。
-- 【★ 移植要点】「回调注册与解除必须是同一个函数对象」，
--   所以事件监听总是先存到实例字段再注册。这条规则在自研引擎里同样适用。
-- ============================================================
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst:SetPhysicsRadiusOverride(3.4)
-- ★ SetPhysicsRadiusOverride(3.4) 与物理半径 1.7（第 130 行）不同：
-- 前者是「对外查询用的半径」（如 FindEntities、寻路），后者是「实际碰撞体」。
-- ⇒ 【★ 移植要点】这两者可以不同且经常需要不同：AI 索敌范围通常比碰撞体大。

    MakeWaterObstaclePhysics(inst, REGULAR_PHYSICS_RADIUS, 2, 0.1)
-- MakeWaterObstaclePhysics(inst, 半径, 高 2, 摩擦 0.1)：★ 水上障碍物物理。
-- 与 boat.lua 第 386 行的裸 AddPhysics 不同，这里用标准封装。
-- ★ 第 3 个参数 2 是高度，第 4 个 0.1 是摩擦 —— 蟹王贴地但不滑动。

    inst.MiniMapEntity:SetIcon("crabking.png")

    inst.Transform:SetScale(CRABKING_SCALE, CRABKING_SCALE, CRABKING_SCALE)

    inst.AnimState:SetBank("king_crab")
    inst.AnimState:SetBuild("crab_king_build")
    inst.AnimState:PlayAnimation("inert", true)

    inst.AnimState:AddOverrideBuild("crab_king_hole_build")
-- ★★ AddOverrideBuild + Hide("water")：蟹王平时藏在水里。
-- ⇒ 【★ 视觉分层】bank="king_crab" 是蟹王的壳，override build 是它坐的冰洞。
--   冰封阶段（第 899 行 Show("water")）才把水洞显示出来。
-- ⇒ 这是 pighouse 的 window/snow、deciduoustrees 的 4 个 override 符号之外的
--   第五种用法：override 一个「环境道具」而非「身体部件」。
    inst.AnimState:Hide("water")

    --  Added so the crab king will not get attached to a moving boat when it is past entity-sleep range.
-- ★ 原注释解释了 ignorewalkableplatforms：
-- Added so the crab king will not get attached to a moving boat when it is past entity-sleep range。
-- ⇒ 【★ 值得学】这个 tag 是为了修一个具体 bug 而加的，且注释写清了「什么时候加的、为什么」。
--   移植时这类 tag 要当成「历史 bug 的补丁」来读，而不是理所当然的设计。
    inst:AddTag("ignorewalkableplatforms")

    inst:AddTag("birdblocker")
    inst:AddTag("crabking")
    inst:AddTag("gemsocket")
    inst:AddTag("largecreature")
    inst:AddTag("crabking_ally")
    inst:AddTag("lunar_aligned")
-- ★ whip_crack_imune —— ★★ 拼写确实是 imune（少一个 m）。
-- 本人已核实：全库 grep 仅此一处（prefabs/crabking.lua:1611），不是笔误扩散，
--   说明这是唯一的「免疫鞭子」标记，且拼写错误从未被发现。
-- ⇒ 【⚠️ 命名陷阱】DST 的 tag 拼写不统一，拼错不会报错、只是功能静默失效。
--   移植时务必给 tag 建常量表 + 拼写检查。
    inst:AddTag("whip_crack_imune")

    inst.entity:SetPristine()

    if not TheNet:IsDedicated() then
-- ★★ 纯表现逻辑的判断条件是 not TheNet:IsDedicated()（有画面），不是 ismastersim。
-- 对比 boat.lua 第 435 行完全相同的写法。
-- ⇒ 【★ 两种判断的分工，务必分清】
--   not IsDedicated()  —— 本机有没有画面（要不要生成纯装饰/纯音频）
--   not ismastersim    —— 本端是不是服务端（要不要生成逻辑组件）
--   监听服务器：两个都是真（既有画面也是服务端）；专服：只有 ismastersim 为真。
        inst.PushMusic = PushMusic

        inst._playingmusic = false
        inst:DoPeriodicTask(1, inst.PushMusic, 0)
-- DoPeriodicTask(1, PushMusic, 0)：★ 每秒检查一次要不要切 BGM。
-- 第 1618 行 _playingmusic 做幂等守卫，防止每秒重播。
-- ⇒ 【★ 可移植模式】「检查条件 → 满足则改变状态」必须做幂等守卫，
--   否则周期任务会反复触发同一次状态变更。
    end

    if not TheWorld.ismastersim then
        return inst
    end

    inst.scrapbook_removedeps = { "moon_altar_cosmic" }

    inst.scrapbook_maxhealth = TUNING.CRABKING_HEALTH
    inst.scrapbook_damage = 0

    inst.socketlist = { 1, 2, 3, 4, 6, 7, 8, 9 } -- Missing 5 on purpuse!
-- ★★★ socketlist = { 1,2,3,4,6,7,8,9 }：★ 故意漏掉 5 号（原注释 Missing 5 on purpuse!）。
-- ⇒ 【设计】5 号是寄居蟹珍珠的专属槽（第 248-249 行强制走这里）。
-- ⇒ 【★ 移植启示】用「列表里少一项」来表达「这个位置被特殊逻辑独占」，
--   比额外维护一个 special_slot 字段更省事，但可读性差 —— 靠注释补救。
    inst.nondamagedsymbollist = { 1,2,3,4,5,6,7,8,9,10 }
-- ★★ nondamagedsymbollist 有 10 项而 damagedsymbollist 是空表 ——
-- ★ 它们是「受损时切换哪套外观」的符号清单（第 1404 行 SetDamagedArt）。
-- ⇒ 【★ 表现设计】满血一套符号、血量低另一套。蟹王的「破损」是纯符号替换实现的。
-- 【移植建议】把「外观随状态切换」抽象成一张表 + 一个函数，任何 Boss 都能用。
    inst.damagedsymbollist = {}
    inst.socketed = {}
    inst.tasks = {}

    -- Internal and external functions.
-- ★★ 三组 API 导出的分界注释（Internal and external functions）。
-- ⇒ 【★ 值得学的组织方式】把「对外接口」与「对内实现」在装配时显式分区，
--   等于在 Lua 里手写了一份「public / private」。
--   ★ 虽然 Lua 没有访问控制，但这种命名与分组约定本身就是一种文档。
-- 【移植建议】自研引擎若不用类，可以用这种分区约定来组织 API，
--   或者干脆生成一份 stub 文件给 IDE 做提示。
    inst.AddGem = AddGem
    inst.RemoveGem = RemoveGem
    inst.DropSocketedGems = DropSocketedGems
    inst.EndCastSpell = EndCastSpell
    inst.ShineSocketOfColor = ShineSocketOfColor
    inst.SpawnCannons = SpawnCannons
    inst.SpawnChunk = SpawnChunk
    inst.SpawnClawArms = SpawnClawArms
    inst.StartCastSpell = StartCastSpell

    -- Internal functions.
    inst.SocketItem = SocketItem
    inst.AddSocketDecoration = AddSocketDecoration
    inst.ClearAllSocketDecorations = ClearAllSocketDecorations
    inst.SetDamagedArt = SetDamagedArt
    inst.SetRepairedArt = SetRepairedArt
    inst.ShineSocketInSlot = ShineSocketInSlot
    inst.UpdateGemCount = UpdateGemCount

    inst.BubbleSeaStack = BubbleSeaStack
    inst.DoDestroySeaStack = DoDestroySeaStack
    inst.DoSpawnSeaStack = DoSpawnSeaStack
    inst.SpawnSeaStacks = SpawnSeaStacks

    inst.DoSpawnIceTile = DoSpawnIceTile
    inst.DoSpawnIceWall = DoSpawnIceWall
    inst.EndIceStage = EndIceStage
    inst.RemoveIceArena = RemoveIceArena
    inst.CleanUpArena = CleanUpArena
    inst.GetFreezeRange = GetFreezeRange -- Deprecated.
    inst.SnapToGrid = SnapToGrid

    inst.DoSpawnArm = DoSpawnArm
    inst.LaunchCrabMob = LaunchCrabMob
    inst.LaunchProjectile = LaunchProjectile

    inst.FindCannonPositions = FindCannonPositions
    inst.SpawnCannonTower = SpawnCannonTower

    -- Event Listeners.
    inst.OnFreeze = OnFreeze -- Deprecated.
    inst.OnAttacked = OnAttacked
    inst.OnDeath = OnDeath
    inst.OnHealthChange = OnHealthChange

    inst.onkeystoneremoved    = function(stone)       OnKeyStoneRemoved(inst, stone)    end
-- ★★★ 事件回调的「适配包装」：inst.onkeystoneremoved = function(stone) OnKeyStoneRemoved(inst, stone) end
-- 两个作用：① 适配签名 ② ★ 存到 inst 上以便 RemoveEventCallback 解除同一个引用。
-- ⇒ 【★ 移植核心】「注册与解除必须是同一个对象」，否则解除会静默失败，
--   造成事件回调累积。deciduoustrees 第 471 行的 MakeHauntableWork 有同样问题。
    inst.oncannontowerremoved = function(tower)       OnCannonTowerRemoved(inst, tower) end
    inst.onarmremoved         = function(arm)         OnArmRemoved(inst, arm.armpos)    end
    inst.onicetilebreak       = function(world, floe) OnIceTileBreak(inst, floe)        end

    inst:AddComponent("entitytracker")
-- ★★★ 4 个组件：entitytracker / explosiveresist / inventory / knownlocations
--   entitytracker    —— 追踪蟹爪臂等子实体
--   explosiveresist  —— 免疫爆炸（矿洞里的爆破）
--   inventory        —— ★ 有背包！Boss 可以被塞东西（虽然实际上少用）
--   knownlocations   —— 让玩家能在地图上看到它（虽然它是 Boss）
-- ⇒ 【★ 观察】连 Boss 都挂了 inventory 与 knownlocations，
--   说明这些组件是「通用能力包」，任何实体都能加。组件化架构的体现。
    inst:AddComponent("explosiveresist")
    inst:AddComponent("inventory")
    inst:AddComponent("knownlocations")
    inst:AddComponent("timer")

    inst:SetStateGraph("SGcrabking")
-- ★ SetStateGraph + SetBrain：★★ 预制体的「行为大脑」在此接入。
-- 第 1695 行 SetBrain(brain)（第 1 行 require 进来的 crabkingbrain）。
-- ⇒ 【★ 三层架构的汇合点】预制体在这里同时挂上：
--   状态机（怎么动）、brain（怎么决策）、组件（提供能力）。
--   三者互相独立，可以分别替换 —— 换一个 brain 就能让同一个蟹王 AI 不同。
    inst:SetBrain(brain)

    inst:AddComponent("health")
    inst.components.health:SetMaxHealth(TUNING.CRABKING_HEALTH)
    inst.components.health.destroytime = 5
-- ★ destroytime = 5：死亡后 5 秒实体才被移除（留出死亡动画时间）。
-- ★ nofadeout（下一行）：不淡出消失，因为死亡走状态机（第 1558 行的 OnDeath）。
-- ⇒ 【可移植模式】「死亡表现」与「实体移除」解耦：组件只管计时，动画由状态机管。

    inst:AddComponent("combat")
-- ★★★ combat 组件的 7 项配置 —— Boss 战斗参数的完整清单，可作模板：
--   SetDefaultDamage            基础伤害
--   playerdamagepercent         ★ 对玩家的伤害比例（Boss 不能一击秒玩家）
--   SetRange                    攻击距离
--   SetAreaDamage               范围伤害的范围与缩放
--   hiteffectsymbol             ★ 受击特效贴在哪（body = 本体）
--   SetAttackPeriod             攻击间隔
--   SetRetargetFunction(1, ...) ★ 覆盖默认索敌逻辑（见第 302 行）
--   SetKeepTargetFunction       什么时候放弃当前目标
-- ⇒ 【★ 移植要点】playerdamagepercent 这一项是 DST 的平衡性关键：
--   同一个伤害值对玩家与怪物用不同倍率，避免 Boss 一击秒了低血玩家。
    inst.components.combat:SetDefaultDamage(TUNING.CRABKING_DAMAGE)
    inst.components.combat.playerdamagepercent = TUNING.CRABKING_DAMAGE_PLAYER_PERCENT
    inst.components.combat:SetRange(TUNING.CRABKING_ATTACK_RANGE)
    inst.components.combat:SetAreaDamage(TUNING.CRABKING_AOE_RANGE, TUNING.CRABKING_AOE_SCALE)
    inst.components.combat.hiteffectsymbol = "body"
    inst.components.combat:SetAttackPeriod(TUNING.CRABKING_ATTACK_PERIOD)
    inst.components.combat:SetRetargetFunction(1, RetargetFn)
    inst.components.combat:SetKeepTargetFunction(KeepTargetFn)

    inst:AddComponent("lootdropper")
    inst.components.lootdropper:SetChanceLootTable("crabking")
    inst.components.lootdropper.GetWintersFeastOrnaments = GetWintersFeastOrnaments

    inst:AddComponent("inspectable")
    inst.components.inspectable.getstatus = GetStatus
    inst.components.inspectable:RecordViews()
-- ★ RecordViews()：记录曾被哪些玩家看见（影响图鉴/成就）。

    inst:AddComponent("trader")
-- ★ trader 组件：★ Boss 也能接受玩家「交易」（往插槽里塞宝石）。
-- 第 1722 行 deleteitemonaccept = false：★ 宝石塞进去后不消失（进了插槽）。
-- ⇒ 【★ 组合的价值】「接受物品」这个能力被 trader 组件提供，
--   Boss 复用它就得到了「插槽」玩法，无需自己写「玩家走近→提示→点击→接收」的流程。
--   这就是组件化的直接收益：第 1719-1722 行四行代码，就实现了整个宝石插槽玩法。
    inst.components.trader:SetAcceptTest(ShouldAcceptItem)
    inst.components.trader.onaccept = OnGetItemFromPlayer
    inst.components.trader.deleteitemonaccept = false

    inst:ListenForEvent("attacked", inst.OnAttacked)
-- ★ 5 个事件监听：attacked / death / healthdelta / freeze / icefloebreak。
-- 第 1728 行的 ListenForEvent 第 3 参数传 TheWorld —— 监听世界级事件
-- （冰块破裂），而非只监听自己的事件。
-- ⇒ 【★ 可移植模式】实体可以监听世界的全局事件，这样就不需要每块冰都回调 Boss。
-- 【移植建议】广播式（世界推事件）优于拉取式（每块冰去问 Boss），后者在实体多时会 O(n²)。
    inst:ListenForEvent("death", inst.OnDeath)
    inst:ListenForEvent("healthdelta", inst.OnHealthChange)
    inst:ListenForEvent("freeze", inst.OnFreeze)
    inst:ListenForEvent("icefloebreak", inst.onicetilebreak, TheWorld)

    inst:UpdateGemCount()

    inst:ClearAllSocketDecorations()

    inst.OnSave = OnSave
    inst.OnLoadPostPass = OnLoadPostPass

    inst.OnEntitySleep = OnEntitySleep
    inst.OnRemoveEntity = OnRemove

    inst.snaptogridtask = inst:DoTaskInTime(0, inst.SnapToGrid)

    return inst
        end
-- ★ return inst 的缩进异常（见文件头说明），语法无害但是后期补丁的痕迹。
-- ⇒ 【读源码收获】★ 缩进异常是「这段代码是后来加的」的最直观信号。
--   本文件两处缩进异常（第 371、1743 行）都对应清理逻辑，与推断一致。

----------------------------------------------------------------------------------------------------------------------------------------------

local function dogeyserburbletask(inst)
-- dogeyserburbletask：★ 「泡吐」音效的间隔随喷发进程缩短。
-- 第 1753 行 Remap(年龄, 0, 总时长, 0.2, 0.01)：越接近喷发，间隔越短（0.2 → 0.01 秒）。
-- ⇒ 【★ 演出节奏】用「音效间隔越来越密」来预告事件即将发生 —— 无需 UI 提示。
-- 【移植建议】这是「听觉预警」的经典实现，比弹提示框自然得多。
    if inst.burbletask then
        inst.burbletask:Cancel()
        inst.burbletask = nil
    end
    local totalcasttime = TUNING.CRABKING_WAVE_ATTACK_TIMEOUT_TIME
    local time = Remap(inst.components.age:GetAge(),0,totalcasttime,0.2,0.01)
    inst.burbletask = inst:DoTaskInTime(time,function() inst.burble(inst) end) -- 0.01+ math.random()*0.1
end

local function burble(inst)
-- burble：★ 在半径 6 内随机生成气泡特效；陆地上则震船（第 1769-1772 行）。
-- 第 1761 行 radius = pow(random, 0.8) * 6：★ 指数 < 1 使分布偏向外圈。
-- ⇒ 【★ 与均匀圆盘采样的对比】第 790 行（deciduoustrees）用 sqrt(random)（偏内圈），
--   这里用 pow(random, 0.8)（偏外圈）。同一个公式族，指数决定分布偏向。
-- 【移植建议】把「极坐标下的面积均匀采样」收进工具库，别各处重写。
    local MAXRADIUS = 6
    local x,y,z = inst.Transform:GetWorldPosition()
    local theta = math.random()*TWOPI
    local radius = math.pow(math.random(),0.8)* MAXRADIUS
    local offset = Vector3(radius * math.cos( theta ), 0, -radius * math.sin( theta ))
    local prefab = "crab_king_bubble"..math.random(1,3)

    if TheWorld.Map:IsOceanAtPoint(x+offset.x, 0, z+offset.z) then
        local fx = SpawnPrefab(prefab)
        fx.Transform:SetPosition(x+offset.x,y+offset.y,z+offset.z)
    else
        local boat = TheWorld.Map:GetPlatformAtPoint(x+offset.x, z+offset.z)
-- ★★ 第 1769-1772 行：★ 「气泡碰到的是船而不是海」时震船。
-- 这是「一个特效，两种反应」的分支：海面 → 冒泡；船 → 震屏。
-- ⇒ 【★ 可移植模式】环境反馈按「命中了什么」分派，比统一反应更有生命力。
        if boat then
            ShakeAllCameras(CAMERASHAKE.VERTICAL, 0.1, 0.01, 0.3, boat, boat:GetPhysicsRadius(4))
        end
    end

    dogeyserburbletask(inst)
end


local function endgeyser(inst)
    inst:DoTaskInTime(2.4,function()
-- endgeyser：★★ 喷发阶段。5 组动作：取消泡吐音 → 循环生成水柱 → 循环结束再等 2.4 秒。
-- ★ 第 1857 行 `inst:DoTaskInTime(2, endgeyser)` —— 函数自递归，形成持续喷发。
-- ⇒ 【★ 模式】周期行为的两种写法：DoPeriodicTask（等间隔）与自递归 DoTaskInTime（不等）。
--   本文件第 1857 行用自递归，因为第 1783 行要动态取消（Cancel 掉即可停止）。
        if inst.burbletask then
            inst.burbletask:Cancel()
            inst.burbletask = nil
        end
    end)

    for i=1,TUNING.CRABKING_DEADLY_GEYSERS do
        inst:DoTaskInTime(math.random()*0.4,function()
            local MAXRADIUS = 4.5
            local x,y,z = inst.Transform:GetWorldPosition()
            local theta = math.random()*TWOPI
            local radius = math.pow(math.random(),0.8)* MAXRADIUS
            local offset = Vector3(radius * math.cos( theta ), 0, -radius * math.sin( theta ))
            local prefab = "crab_king_waterspout"
            if TheWorld.Map:IsOceanAtPoint(x+offset.x, 0, z+offset.z) then
                local fx = SpawnPrefab(prefab)
                fx.Transform:SetPosition(x+offset.x,y+offset.y,z+offset.z)

                local INITIAL_LAUNCH_HEIGHT = 0.1
                local SPEED = 8
                local CANT_HAVE_TAGS = {"INLIMBO", "outofreach", "DECOR"}
                local function launch_away(inst, position)
                    local ix, iy, iz = inst.Transform:GetWorldPosition()
                    inst.Physics:Teleport(ix, iy + INITIAL_LAUNCH_HEIGHT, iz)

                    local px, py, pz = position:Get()
                    local angle = (180 - inst:GetAngleToPoint(px, py, pz)) * DEGREES
                    local sina, cosa = math.sin(angle), math.cos(angle)
                    inst.Physics:SetVel(SPEED * cosa, 4 + SPEED, SPEED * sina)
                end
                local affected_entities = TheSim:FindEntities(x+offset.x,y+offset.y,z+offset.z, 2, nil, CANT_HAVE_TAGS)
-- ★★★ 喷发最狠的一招：把玩家（及任何 oceanfishable 实体）像炮弹一样打飞。
-- 第 1813 行 v.components.oceanfishable ~= nil：★ 只影响「能被钓的实体」——
--   也就是玩家、钓鱼人、其它可钓物。这是 DST 组件化带来的通用判定。
-- ⇒ 【★ 可移植模式】★ 「某能力是否作用于某个实体」由组件决定，而不是硬编码类型判断。
--   玩家会中招是因为玩家也有 oceanfishable 组件；新增可钓物自动也会被弹飞。
-- 第 1822-1825 行对 complexprojectile 的重力与速度做了强化（负重力 = 抛物线）。
                for _, v in ipairs(affected_entities) do
                    if v.components.oceanfishable ~= nil then
                        -- Launch fishable things because why not.

                        local projectile = v.components.oceanfishable:MakeProjectile()
                        if projectile.components.weighable ~= nil then
                            projectile.components.weighable.prefab_override_owner = inst.fisher_prefab
                        end
                        local position = Vector3(x+offset.x,y+offset.y,z+offset.z)
                        if projectile.components.complexprojectile then
                            projectile.components.complexprojectile:SetHorizontalSpeed(16)
                            projectile.components.complexprojectile:SetGravity(-30)
                            projectile.components.complexprojectile:SetLaunchOffset(Vector3(0, 0.5, 0))
                            projectile.components.complexprojectile:SetTargetOffset(Vector3(0, 0.5, 0))

                            local v_position = v:GetPosition()
                            local launch_position = v_position + (v_position - position):Normalize() * SPEED
                            projectile.components.complexprojectile:Launch(launch_position, projectile)
                        else
                            launch_away(projectile, position)
                        end
                    end
                end


            else
                local boat = TheWorld.Map:GetPlatformAtPoint(x+offset.x, z+offset.z)
                if boat then
                    local pt = Vector3(x+offset.x,0,z+offset.z)
                    boat.components.health:DoDelta(-TUNING.CRABKING_GEYSER_BOATDAMAGE)

                    -- look for patches
                    local nearpatch = TheSim:FindEntities(pt.x, 0, pt.z, 2, REPAIRED_PATCH_MUST_TAGS)
-- ★★★ 喷发还会「顺便撕掉玩家的补丁」：找到修补片就 Remove 掉（第 1847 行）。
-- ⇒ 【★ 关卡交互】玩家修船的成果会被 Boss 战术性摧毁 —— 迫使玩家必须在
--   「修船防漏」与「进攻」之间做取舍。这是逼迫玩家做决策的设计手法。
                    for i,patch in pairs(nearpatch)do
                        pt = Vector3(patch.Transform:GetWorldPosition())
                        patch:Remove()
                        break
                    end

                    boat:PushEvent("spawnnewboatleak", {pt = pt, leak_size = "small_leak", playsoundfx = true})
                end
            end
        end)
    end

    inst:DoTaskInTime(2, endgeyser)
end

local function geyserfn()
-- ★★ geyserfn：间歇泉实体，一个「纯功能子实体」。
-- 它只有 Transform + SoundEmitter + Network + age 四个组件 —— 没有任何玩法组件。
-- ★ 所有行为靠第 1880-1882 行挂到 inst 上的三个函数驱动：
--   inst.burble / inst.dogeyserburbletask（从外部调用）+ age 组件（记录年龄）。
-- ⇒ 【★ 架构】★ 这是「把逻辑外部化」的极简样本：实体本身几乎什么都不做，
--   只是一个「能被找到并调用」的位置标记 + 一个循环音效。
-- 【移植建议】需要「可被随时调用的位置标记」时，
--   轻量实体 + 挂函数，比往主实体上加状态字段更干净。
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("NOCLICK")
    inst:AddTag("fx")
    inst:AddTag("crabking_spellgenerator")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("age")

    inst.persists = false
-- persists = false：间歇泉是临时的，不入存档。同 pighouse 窗户的做法。

    inst.burble = burble
    inst.dogeyserburbletask = dogeyserburbletask

    inst.SoundEmitter:PlaySound("hookline_2/creatures/boss/crabking/bubble_LP","burble")
-- ★★ PlaySound(路径, "burble") 带通道名 → 之后可以用 KillSound("burble") 精确掐掉。
-- 对比不带通道名的调用（第 1727 行等）：那些只能整体停。
-- ⇒ 【★ 可移植模式】★ 需要单独控制某个音效时，必须给循环音效一个通道名。
--   否则「停止这个音」会误伤同一实体上其它音效。
    inst.SoundEmitter:SetParameter("burble", "intensity", 0)
    inst.burblestarttime = GetTime()
    inst.burbleintensity = inst:DoPeriodicTask(1,function()
            local totalcasttime = TUNING.CRABKING_WAVE_ATTACK_TIMEOUT_TIME
            local intensity = math.min(1,( GetTime() - inst.burblestarttime ) / totalcasttime)
-- intensity = min(1, 已过时间 / 总时长)：★ 音效强度随喷发进程线性上升。
-- ⇒ 【★ 演出】音量也是可脚本化的反馈通道，比纯视觉提示更微妙有效。

            inst.SoundEmitter:SetParameter("burble", "intensity", intensity)
      end)
    inst:ListenForEvent("onremove", function()
        if inst.burbletask then
            inst.burbletask:Cancel()
            inst.burbletask = nil
        end
        if inst.burbleintensity then
            inst.burbleintensity:Cancel()
            inst.burbleintensity = nil
        end
        inst.SoundEmitter:KillSound("burble")
    end)

    inst:DoTaskInTime(TUNING.CRABKING_WAVE_ATTACK_TIMEOUT_TIME,function()
        endgeyser(inst)
    end)

    dogeyserburbletask(inst)

    return inst
end



-- FREEZE FX

local function onfreeze(inst, target)
    if not target:IsValid() then
        --target killed or removed in combat damage phase
        return
    end

    if target.components.burnable ~= nil then
        if target.components.burnable:IsBurning() then
            target.components.burnable:Extinguish()
        elseif target.components.burnable:IsSmoldering() then
            target.components.burnable:SmotherSmolder()
        end
    end

    if target.components.combat ~= nil and inst.crab and inst.crab:IsValid() then
        target.components.combat:SuggestTarget(inst.crab)
    end

    if target.sg ~= nil and not target.sg:HasStateTag("frozen") and inst.crab and inst.crab:IsValid() then
        target:PushEvent("attacked", { attacker = inst.crab, damage = 0, weapon = inst })
    end

    if target.components.freezable ~= nil and target:IsValid() then -- NOTES(JBK): We need to check if ent is still valid for freezable:AddColdness after being attacked.
        target.components.freezable:AddColdness(10,10 + Remap((inst.crab and inst.crab:IsValid() and inst.crab.gemcount.blue or 0),0,9,0,10) )
-- ★★ chipfn 的位置说明：chipfn 实际定义在第 2076 行，是本文件的第二处「带参工厂」。
-- 末尾第 2141-2143 行用 chipfn("high"/"mid"/"low") 派生了 3 个芯片预制体，
-- 且三者共用同一张 chipassets（第 23 行）。
-- ⇒ 对比第 1578 行的 crabking fn：同一种「工厂 + 变体」模式，规模小得多。
--   ★ 【可移植模式】工厂函数可以任意小 —— 本质就是「参数化的 Prefab 声明」。
--   若三个芯片只有尺寸差异，连 chipfn 都可以省掉，直接写三个 fn。
        target.components.freezable:SpawnShatterFX()
    end
end

local function dofreezefz(inst)
    if inst.freezetask then
        inst.freezetask:Cancel()
        inst.freezetask = nil
    end
    local time = 0.1
    inst.freezetask = inst:DoTaskInTime(time,function() inst.freezefx(inst) end)
end

local function freezefx(inst)
    local function spawnfx()
        local MAXRADIUS = inst.crab and inst.crab:IsValid() and inst.crab:GetFreezeRange() or (TUNING.CRABKING_FREEZE_RANGE * 0.75)
        local x,y,z = inst.Transform:GetWorldPosition()
        local theta = math.random()*TWOPI
        local radius = 4+ math.pow(math.random(),0.8)* MAXRADIUS
        local offset = Vector3(radius * math.cos( theta ), 0, -radius * math.sin( theta ))

        local prefab = "crab_king_icefx"
        local fx = SpawnPrefab(prefab)
        fx.Transform:SetPosition(x+offset.x,y+offset.y,z+offset.z)
    end

    local MAXFX = Remap(( inst.crab and inst.crab:IsValid() and inst.crab.gemcount.blue or 0),0, 9,5,15)


    local fx = Remap(inst.components.age:GetAge(),0,TUNING.CRABKING_CAST_TIME_FREEZE - (math.min((inst.crab and inst.crab:IsValid() and math.floor(inst.crab.gemcount.yellow/2) or 0),4)),1,MAXFX)

    for i=1,fx do
        if math.random()<0.2 then
            spawnfx()
        end
    end

    dofreezefz(inst)
end

local FREEZE_CANT_TAGS = { "crabking_ally", "shadow", "ghost", "playerghost", "FX", "NOCLICK", "DECOR", "INLIMBO" }

local function dofreeze(inst)
    local interval = 0.2
    local pos = Vector3(inst.Transform:GetWorldPosition())
    local range = inst.crab and inst.crab:IsValid() and inst.crab:GetFreezeRange() or (TUNING.CRABKING_FREEZE_RANGE * 0.75)
    local ents = TheSim:FindEntities(pos.x, pos.y, pos.z, range, nil, FREEZE_CANT_TAGS)
    for i,v in pairs(ents)do
        -- NOTE: this code is not used anymore, but if it were reused, please use GetEntityTemperature and SetEntityTemperature to account for items
        if v.components.temperature then
            local rate = (TUNING.CRABKING_BASE_FREEZE_AMOUNT + ((inst.crab and inst.crab:IsValid() and inst.crab.gemcount.blue or 0) * TUNING.CRABKING_FREEZE_INCRAMENT)) /( (TUNING.CRABKING_CAST_TIME_FREEZE - (inst.crab and inst.crab:IsValid() and math.floor(inst.crab.gemcount.yellow/2) or 0) ) /interval)
            if v.components.moisture then
                rate = rate * Remap(v.components.moisture:GetMoisture(),0,v.components.moisture.maxmoisture,1,3)
            end

            local mintemp = v.components.temperature.mintemp
            local curtemp = v.components.temperature:GetCurrent()
            if mintemp < curtemp then
                v.components.temperature:DoDelta(math.max(-rate, mintemp - curtemp))
            end
        end
    end

    local time = 0.2
    inst.lowertemptask = inst:DoTaskInTime(time,function() inst.dofreeze(inst) end)
end

local function endfreeze(inst)
    if inst.freezetask then
        inst.freezetask:Cancel()
        inst.freezetask = nil
    end

    if inst.lowertemptask then
        inst.lowertemptask:Cancel()
        inst.lowertemptask = nil
    end

    local pos = Vector3(inst.Transform:GetWorldPosition())
    local range = inst.crab and inst.crab:IsValid() and inst.crab:GetFreezeRange() or (TUNING.CRABKING_FREEZE_RANGE * 0.75)
    local ents = TheSim:FindEntities(pos.x, pos.y, pos.z, range, nil, FREEZE_CANT_TAGS)
    for i,v in pairs(ents)do
        onfreeze(inst, v)
    end
    SpawnPrefab("crabking_ring_fx").Transform:SetPosition(pos.x,pos.y,pos.z)
    inst:DoTaskInTime(1, inst.Remove)
end

local function freezefn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("NOCLICK")
    inst:AddTag("fx")
    inst:AddTag("crabking_spellgenerator")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("age")

    inst.persists = false

    inst.freezefx = freezefx
    inst.dofreeze = dofreeze
    inst:DoTaskInTime(0,function()
        dofreezefz(inst)
        dofreeze(inst)
    end)

    inst.SoundEmitter:PlaySound("hookline_2/creatures/boss/crabking/ice_attack")

    inst:ListenForEvent("onremove", function()
        if inst.burbletask then
            inst.burbletask:Cancel()
            inst.burbletask = nil
        end
    end)

    inst:ListenForEvent("endspell", function()
        endfreeze(inst)
    end)

    inst:DoTaskInTime(TUNING.CRABKING_CAST_TIME+2,function()
        endfreeze(inst)
    end)

    return inst
end

local function chipfn(type)
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    local phys = inst.entity:AddPhysics()
    phys:SetMass(1)
    phys:SetFriction(0)
    phys:SetDamping(5)
    phys:SetCollisionGroup(COLLISION.FLYERS)
	phys:SetCollisionMask(TheWorld.has_ocean and COLLISION.GROUND or COLLISION.WORLD)
    phys:SetCapsule(0.5, 1)

    local s  = 0.7
    inst.Transform:SetScale(s, s, s)

    inst.AnimState:SetBank("rockchip")
    inst.AnimState:SetBuild("crabking_rockchip")
    inst.AnimState:PlayAnimation("rockchip_"..type)

    inst:AddTag("NOCLICK")
    inst:AddTag("fx")

    local down = TheCamera:GetDownVec()
    local offset = (math.random()*30 + 50)
    if math.random() > 0.5 then
        offset = -offset
    end
    local angle = (math.atan2(-down.z, down.x) / DEGREES ) + offset
    inst.Transform:SetRotation(angle)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:ListenForEvent("animover", function()
        if inst.AnimState:IsCurrentAnimation("hit_water") or inst.AnimState:IsCurrentAnimation("hit_land") then
            inst:Remove()
        end
        if not inst.landed then
            inst.Physics:Stop()
            inst.landed = true
            local pos = Vector3(inst.Transform:GetWorldPosition())
            if not TheWorld.Map:IsVisualGroundAtPoint(pos.x,pos.y,pos.z) and not TheWorld.Map:GetPlatformAtPoint(pos.x,pos.z) then
                inst.AnimState:PlayAnimation("hit_water")
            else
                inst.AnimState:PlayAnimation("hit_land")
            end
        end
    end)

    inst.Physics:SetMotorVel(math.random(8,12), 0, 0)

    inst.persists = false

    return inst
end

return Prefab("crabking", fn, assets, prefabs),
-- ★★★ return：★ 6 条 Prefab 声明，其中 1 条被注释掉（第 2140 行），实际注册 5 个实体：
--   crabking               —— 本体（第 1578 行 fn）
--   crabking_geyserspawner —— 间歇泉（第 1860 行 geyserfn），★ 第 3 参数 assets 显式传 nil
--   crabking_feeze         —— ★ 被注释掉的废弃项（配合第 72-76 行的长注释块）
--   crabking_chip_high     —— 芯片，第 2076 行 chipfn 的三次调用之一
--   crabking_chip_med / crabking_chip_low
--
-- ⇒ 与其它预制体文件一致：★ return 是「注册表」，不是「一堆独立定义」。
-- ★ 第 2141-2143 行的芯片用 `function() return chipfn("high") end` 包装，
--   原因是 Prefab 需要「无参函数」而 chipfn 需要参数 —— 用闭包适配。
-- ⇒ 【可移植模式】「带参工厂 → 无参 Prefab」的标准适配手法，
--   deciduoustrees.lua 的 tree() 辅助函数（第 1449 行）是同一思路的简化版。
--
-- 【★ 资源清单共享】三个芯片共用同一张 chipassets（第 23 行），
--   说明它们只是尺寸不同、贴图相同 —— 差异全在参数 type 里。
       Prefab("crabking_geyserspawner", geyserfn, nil, geyserprefabs),
       --Prefab("crabking_feeze", freezefn, nil, freezeprefabs),
       Prefab("crabking_chip_high", function() return chipfn("high") end, chipassets),
       Prefab("crabking_chip_med",  function() return chipfn("mid") end, chipassets),
       Prefab("crabking_chip_low",  function() return chipfn("low") end,  chipassets)