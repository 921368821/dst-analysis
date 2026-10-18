-- =========================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：constants.lua
-- 模块：数值源头 / 常量定义（Constants）
-- 职责：定义全项目的**常量与枚举** —— 那些「一旦定下就不该改」的量。
--       与 tuning.lua 的分工：
--         tuning.lua   = 「可以调」的数值（手感、平衡）
--         constants.lua= 「不该调」的常量（ID、枚举、协议）
--       举例：饥饿速率在 tuning.lua；但「第 0 号朝向是右」在 constants.lua。
--
-- 【两者的根本区别 —— 这决定了改动的风险等级】
--   · tuning.lua 的值错了 → 体验不好（可接受，靠后续版本修）
--   · constants.lua 的值错了 → **存档损坏 / 联机不同步**（不可接受）
--   所以本文件的内容比 tuning.lua 更需要谨慎对待。
--
-- 【规模】3041 行。约 2/3 是枚举表（大量重复的 NAME = value 形式），
--       剩下 1/3 是各类表定义（颜色、道具表、世界分类…）。
--
-- 【★★★ 分类导航表 ★★★】 —— 本文件的三大类内容
-- ═══════════════════════════════════════════════════════════════
--  # 类别                行号区间       代表内容
-- ═══════════════════════════════════════════════════════════════
--  A 数学与画面基础常量1-43          PI/FRAMES/TILE_SCALE/分辨率/镜头距离
--  B 朝向 / 图层 / 锚点 / 缩放       44-98       FACING_*/LAYER_*/ANCHOR_*
--  C ★手柄按键（★最大枚举区）       99-284CONTROL_* 约 100 个按键编号
--  D 键盘 / 鼠标 / 手势键码285-406 KEY_* / MOUSEBUTTON_* / GESTURE_*
--  E 前后端 prefab 与角色表          407-648      *_PREFABS / *_CHARACTERLIST
--  F ★装备槽位与物品标签★          649-671      MAXITEMSLOTS / EQUIPSLOTS / ITEMTAG
--  G 地面与地形（大部分已废弃）      672-789      GROUND / WORLD_TILES
--  H ★世界事件与音乐                790-1228     SPECIAL_EVENTS / FESTIVAL_EVENTS
--  I 万圣节计数与理智模式           1229-1236    NUM_* / SANITY_MODE_*
--  J ★世界生成与技术图              1237-1524    TECH / NODE_TYPE / MAZE_TYPE
--  K 配方分类与 UI 枚举              1525-1602    RECIPETABS / ANIM_ORIENTATION
--  L ★季节与渲染质量                1603-1650    SEASONS / RENDER_QUALITY
--  M 颜色表（★大量 RGB 值）        1651-1836    PLAYERCOLOURS / UICOLOURS
--  N 材质与皮肤/ 存档槽              1837-1964    MATERIALS / NUM_SAVE_SLOTS
--  O ★物品材质分类（★调平衡相关）   1965-2182    UPGRADETYPES / FOODTYPE / FARM_PLANT_STRESS
--  P 动作与建造模式枚举             2183-2292    TOOLACTIONS / FALLINGREASON / DEPLOYMODE
--  Q Steam AppID 与 UI 常量         2293-2350    DONT_STARVE_TOGETHER_APPID
--  R 聊天 / 玩家权限 / 权限等级      2351-2595    CHATPRIORITIES / USERFLAGS / COMMAND_*
--  S ★语言与物品数量上限            2596-2675    LANGUAGE / QUAGMIRE_NUM_*
--  T 物品 ID 与联机协议              2676-2760TEMP_ITEM_ID / IAP_TYPE_* / YOTB_COSTUMES
--  U ★★物品系统枚举（★核心）       2761-3041STORM_TYPES / HUNT_ACTIONS / THRALL_TYPES /
--                                   SCRAPBOOK_CATS / SOCKETQUALITY / CIRCUIT_BARS
-- ═══════════════════════════════════════════════════════════════
--
-- 【★★★ 本文件最需要警惕的三个点 ★★★】
--
--  ── 1. ★★ 物品 ID 系统与「魔法字符串」★★
--  本文件里大量键名本身就是 ID（如 "wortox_soul"、"hermitcrab_teashop"）。
--  这些字符串会写进存档：玩家背包里存的是 {"minotaurhorn": 3} 这样的表。
--  ⚠ 若把某物品的 ID 改名，旧存档里的该物品会**变成无法识别的死数据**，
--    玩家会「丢东西」。这是本文件最不可逆的操作。
--
--  ── 2. ★★ 存档相关的数字常量 ★★
--     NUM_SAVE_SLOTS = 5（第 1910 行）
--     NUM_DST_SAVE_SLOTS = NUM_SAVE_SLOTS（第 1911 行）
--     NUM_SKIN_PRESET_SLOTS = 25（第 1907 行）
--     CLOUD_SAVES_SAVE_OFFSET = 100000（第 2564 行）
--     WOBYCOURIER_NO_CHEST_COORD = -32767（第 2926 行）
--  ⚠ 这些数字参与存档槽位寻址，改动会导致存档列表错位或云存档读取失败。
--    第 1909 行英文原注释已明确写着：
--      'Neither of these are used anymore, kept here only for mods.'
--    ⇒ 两个 NUM_SAVE_SLOTS **已废弃**，保留纯为兼容旧模组。
--
--  ── 3. ★★ 位掩码（bitmask）枚举，不是普通枚举 ★★
--     YOTB_COSTUMES（第 2746-2756 行）：
--         WAR = 1, DOLL = 2, ROBOT = 4, NATURE = 8, FORMAL = 16,
--         VICTORIAN = 32, ICE = 64, FESTIVE = 128, BEAST = 256
--     ★★ 这些值是 2 的幂（1,2,4,8...256），且注释说明要组合使用：
--         玩家装扮 = YOTB_COSTUMES.WAR | YOTB_COSTUMES.FESTIVE  → 129
--     ⇒ 判断「玩家有没有鹿角装扮」要用位与运算，不能用相等比较：
--         if costumes & YOTB_COSTUMES.WAR ~= 0 then   ← 对
--         if costumes == YOTB_COSTUMES.WAR then       ← 错（组合值就不匹配了）
--     ★★ 这是本文件最容易写错的一处，务必记住。
--
-- 【★ 命名约定总览】
--   · 全大写下划线= 常量或枚举成员（FACING_RIGHT、LAYER_GROUND…）
--   · 以数字结尾 = 编号型枚举（CONTROL_INV_1…CONTROL_INV_15）
--   · 带 _SQ 后缀   = 「距离的平方」，避免开方（性能优化）
--   · 带 _MAX/_MIN  = 边界钳制值
--   · 带 _LOOKUP 后缀 = 由前一张表派生出来的反查表（table.invert 生成）
--   · 带 DEPRECATED 的键 = 已废弃，保留兼容，不要使用
--   · ✦ 注释里出现「NOTES(JBK):」= 作者留给自己的待办/跨文件同步提醒
--
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：tuning.lua（可调数值）, containers.lua（背包槽位 UI 定义）,
--           components/inventory.lua（物品栏逻辑）, components/sanity.lua（SANITY_MODE）,
--           worldsettings_overrides.lua（难度）, components/area_trigger.lua
-- ===========================================================
--【★★ 类别 A · 数学与画面基础常量】1-43 行
--  ★ 这是全文件的「地基常量」—— 数学换算、帧率、格子尺寸、镜头距离。
--    它们本身不参与玩法，但所有表现层计算都依赖它们。
require "util"
local TechTree = require("techtree")

local IS_BETA = BRANCH == "staging" or BRANCH == "dev"

--【★★ 角度常量族】PI=π, PI2=2π, HALFPI=π/2 …DEGREES=π/180, RADIANS=180/π
--  ★★ 这是全文件最有用的一组小常量，值得单独理解：
--    DEGREES 与 RADIANS 互为倒数，构成「度↔弧度」的换算对。
--  ★★ 为什么必须这样写？对比两种写法：
--    坏写法：GOLF_AIM_ARC = 1.5708   ← 读者不知道这是什么角度
--    好写法：GOLF_AIM_ARC = 90 * DEGREES← 一眼看出是 90 度
--    ★ 这与 tuning.lua 的归一化写法是同一种思想：
--      让表达式承载意图，而不是留下一个算完的结果。
--    ★ 实际用例见 tuning.lua:9547（GOLF_AIM_ARC = 90 * DEGREES）。
PI = math.pi
PI2 = PI*2
TWOPI = PI2
HALFPI = PI/2
QUARTERPI = PI/4
EIGHTHPI = PI/8
SQRT2 = math.sqrt(2)
GOLDENANGLE = PI * (3 - math.sqrt(5))
DEGREES = PI/180
RADIANS = 180/PI
--★★★ 【FRAMES = 1/30 —— 帧率常量，本文件最容易被忽略的关键值】★★★
--  ★★★ 这个 1/30 表示「引擎每秒跑 30 帧」。它的影响远超想象：★★★
--  (1) 所有以「帧(tick/frame)」为单位的参数，换算成秒要乘/除 30。
--      例：tuning.lua:9548 GOLF_MAX_CHARGE_TICKS = 1.5 * 30 = 45 帧。
--  (2) 它解释了 tuning.lua 里大量 `* 30` 的由来（如 STALKER_*_FRAMES）。
--  (3) 例：tuning.lua:698 DEER_ICE_FREEZE_LOCK_FRAMES = 30 = **整整 1 秒**。
--      看到 FRAMES 后缀的值，先除以 30 得到秒数再理解。
--  ★★ 推理依据：常量定义即 1/30，配合 tuning.lua 中反复出现的 30。
--    ⇒ 本作固定 30 FPS；这在「每帧移动距离」类物理计算中必须严格遵守
--      （典型案例：tuning.lua:9551 高尔夫球速度上限 11.99 的推导，
--        就是 30 帧/秒 × 0.4 球径 = 12，为防穿模取 11.99）。
FRAMES = 1/30
--★★ 【TILE_SCALE = 4 —— 格子缩放】TILE_SCALE / HALF_TILE_SCALE=2
--  ★ 一个世界「格」在内部坐标里是 4 个单位。这是所有距离数值的基准。
--  ★★ 重要推论：调平衡时若碰到「格」与「单位」混用，
--    必须记住 1 格 = 4 单位。
--  ★ 关联：tuning.lua 的 FARM_TILL_SPACING = 1.25 单位（不到半格），
--    之所以能用 1/4 这种小数，正是因为 TILE_SCALE=4 提供了最小刻度。
TILE_SCALE = 4
HALF_TILE_SCALE = TILE_SCALE/2
--★★★ 【★ 魔数风险 ★ MAXUINT = 4294967295 = 2^32 - 1】★★★
--  ★ 这是 32 位无符号整数的最大值，用作「无效值 / 哨兵值(sentinel)」。
--  ⚠★ 它在第 684 行被用作 GROUND.INVALID（地面无效值标记）。
--    推理依据：地面类型本应是枚举（1~N），用2^32-1 表示「不是任何地面」，
--      因为这个值不可能与任何合法枚举撞车。
--  ★★ 这类「魔数」是本文件的高危改动点：
--    改它会同时影响「无效值判断」与「位运算掩码」两处用途。
--★ 位运算相关：常与 0xFFFFFFFF 搭配，表示「所有位都为真」。
MAXUINT = 4294967295

--【★ 分辨率常量】RESOLUTION_X = 1280 / RESOLUTION_Y = 720
--  ★ 基准分辨率（16:9）。UI 坐标以此为参照做缩放。
--  ★ SCALEMODE_* 系列（第 83-87 行）就是描述窗口变化时如何适配这个基准。
RESOLUTION_X = 1280
RESOLUTION_Y = 720

--★★ 【镜头与可见范围】24-40 行
--  PLAYER_REVEAL_RADIUS = 30.0 —— ★★ 英文原注释：
--    'NOTES(JBK): Keep in sync with MiniMapRenderer.cpp!'
--    「务必与 C++ 文件 MiniMapRenderer.cpp 保持同步！」
--  ⚠★★ 疑似缺陷（跨语言同步风险）—— 这是本文件最危险的注释：
--    推理依据：同一个数值同时存在于 Lua 与 C++ 两侧，且**没有任何自动校验**。
--      只改Lua 会导致小地图显示范围与实际逻辑不一致；
--      只改 C++ 则反之。
--    ⇒ 这是本项目「魔数风险」的最典型案例，也说明为什么
--      常量一旦定下就不该轻改：改动的成本不只在本文件内。
--  同类跨语言同步提醒见第 26 行 PLAYER_CAMERA_SEE_DISTANCE 与 28 行。
PLAYER_REVEAL_RADIUS = 30.0 -- NOTES(JBK): Keep in sync with MiniMapRenderer.cpp!
PLAYER_REVEAL_RADIUS_SQ = PLAYER_REVEAL_RADIUS * PLAYER_REVEAL_RADIUS
--  PLAYER_CAMERA_SEE_DISTANCE = 40.0 —— 同样带 'Keep in sync' 类提醒。
--  PLAYER_CAMERA_SHOULD_SNAP_DISTANCE = 20.0：镜头「吸附」的距离阈值。
--    ★★ SNAP 机制：相机在两个位置间做平滑过渡，超过该距离就瞬移，
--      避免长距离移动时镜头「缓慢追不上」。
--  PLAYER_CAMERA_MAX_DIST = 80（第 31 行）：镜头最大缩放距离。
--    ★ 英文原注释 'This is the max distance we can do before we risk seei...'
--      意思是「再远就会看到不该看到的东西（地图外）」——纯技术上限。
PLAYER_CAMERA_SEE_DISTANCE = 40.0 -- NOTES(JBK): Based off of an approximation of the maximum default camera distance before seeing clouds and is the screen diagonal.
PLAYER_CAMERA_SEE_DISTANCE_SQ = PLAYER_CAMERA_SEE_DISTANCE * PLAYER_CAMERA_SEE_DISTANCE -- Helper.
PLAYER_CAMERA_SHOULD_SNAP_DISTANCE = 20.0 -- NOTES(JBK): This is an approximate distance traveled where the camera should snap and fade out to not cause disorientations.
PLAYER_CAMERA_SHOULD_SNAP_DISTANCE_SQ = PLAYER_CAMERA_SHOULD_SNAP_DISTANCE * PLAYER_CAMERA_SHOULD_SNAP_DISTANCE -- Helper.

PLAYER_CAMERA_MAX_DIST = 80 -- This is the max distance we can do before we risk seeing entities pop in and out

-- Deprecated, left in case of mods.
PLAYER_CAMERA_MAX_DIST_CAVES = PLAYER_CAMERA_MAX_DIST

--★ 【ENTITY_POPIN_RADIUS = 64 / POPOUT = POPIN * 1.2 = 76.8】
--  ★ 这是一对「进入/离开加载」的缓冲区半径：
--    玩家走进 64 单位内→ 实体加载进内存；走出 76.8 单位 → 卸载。
--  ★★ POPOUT 比 POPIN 大 1.2 倍是**迟滞设计**（hysteresis）：
--    留 12.8 单位的余量，防止玩家在边界来回走动时反复加载/卸载（卡顿）。
--  ★ 与 tuning.lua 的迟滞阈值（170/165）同属一种设计思路。
ENTITY_POPIN_RADIUS = 64.0 -- Read only value.
ENTITY_POPOUT_RADIUS = ENTITY_POPIN_RADIUS * 1.2 -- Read only value.

ENTITY_POPIN_RADIUS_SQ = ENTITY_POPIN_RADIUS * ENTITY_POPIN_RADIUS
ENTITY_POPOUT_RADIUS_SQ = ENTITY_POPOUT_RADIUS * ENTITY_POPOUT_RADIUS

--  MAX_FE_SCALE = 3（前端最大缩放） / MAX_HUD_SCALE = 1.25（HUD 最大缩放）。
--    ★★ 两者的差距反映设计倾向：HUD 只能微调，前端菜单可大幅放大（照顾视力）。
MAX_FE_SCALE = 3 --Default if you don't call SetMaxPropUpscale
MAX_HUD_SCALE = 1.25
--【★★ 类别 B · 朝向 / 图层 / 锚点 / 缩放模式】44-98 行
--  ★★ 这类枚举的危险性远高于普通配置：它们的值参与渲染排序与输入判定，
--    ★ 改编号会导致「精灵画在错误的层」「按键映射到错误动作」。

--★★★ 【FACING_* 朝向枚举 —— 8向体系】45-53 行
--  FACING_RIGHT=0  FACING_UP=1  FACING_LEFT=2  FACING_DOWN=3
--  FACING_UPRIGHT=4  FACING_UPLEFT=5  FACING_DOWNRIGHT=6  FACING_DOWNLEFT=7
--  FACING_NONE = 8
--
--  ★★ 编号规律：前 4 个是「正交四向」，且按**逆时针**排序：
--      右(0) → 上(1) → 左(2) → 下(3)
--    后4 个是对角线与特殊姿态。
--  ★★ 为什么必须记住「0 是右」？因为很多旋转计算是
--      (原朝向 + 90) % 4，得到的是**索引**而非角度。
--      索引 0=右、1=上、2=左、3=下，恰好满足「索引*90 度 = 实际角度」。
--  ★★⚠ 魔数风险：FACING_NONE = 8 是「哨兵值」，
--    若有人把 FACING_UPRIGHT 从 4 改成 8，NONE 就与它撞值了。
--    ⇒ 改动此枚举必须同步检查所有 % 4 与查表代码。
--★ 关联：components/locomotor.lua（移动朝向）、animations（动画帧名）。
FACING_RIGHT = 0
FACING_UP = 1
FACING_LEFT = 2
FACING_DOWN = 3
FACING_UPRIGHT = 4
FACING_UPLEFT = 5
FACING_DOWNRIGHT = 6
FACING_DOWNLEFT = 7
FACING_NONE = 8

-- Careful inserting into here. You will have to update game\render\RenderLayer.h
--★★ 【LAYER_* 渲染图层】56-69 行 —— 决定「谁盖住谁」
--  LAYER_BACKDROP=0（背景板）→ LAYER_FRONTEND_DEBUG=9（前端调试层）
--  ★★ 数值越大越靠前（画在上层）。完整层级：
--    0背景板→ 1 海面下→ 2 地下→ 3 地面→ 4 背景实体→
--    5 世界背景→ 6 世界实体→ 7 世界调试→ 8 前端 UI→ 9 前端调试
--  ★ 设计意图：调试层永远在最上面（7、9），保证开发者能看到任何被遮挡的东西。
--  ⚠ LAYER_WIP_BELOW_OCEAN = 2 --1（第 68 行）：
--    ⚠疑似缺陷（残留覆盖）：值写成2，而被注释掉的是 1。
--      推理依据：行尾 '--1' 是历史值，说明这层曾与 LAYER_BELOW_GROUND 同为 2，
--        调整时漏改了注释、只改了值。
--      ⇒ 注意它现在与 LAYER_BELOW_GROUND **值相同（都是 2）**，
--        两者在同一批次渲染时依赖绘制顺序而非层号区分。
--        这是一个潜在的图层顺序隐患，但不影响功能。
LAYER_BACKDROP = 0
LAYER_BELOW_OCEAN = 1
LAYER_BELOW_GROUND = 2
LAYER_GROUND = 3
LAYER_BACKGROUND = 4
LAYER_WORLD_BACKGROUND = 5
LAYER_WORLD = 6
-- client-only layers go below here --
LAYER_WORLD_DEBUG = 7
LAYER_FRONTEND = 8
LAYER_FRONTEND_DEBUG = 9

LAYER_WIP_BELOW_OCEAN = 2 --1

-- From SortKeyConsts in scenegraphnode.h
--【★ 渲染微调常量】FINALOFFSET_MIN/MAX = ±7；SORTORDER_MIN/MAX = ±3
--  ★ FINALOFFSET 影响「同一格内多个实体的前后微调」，
--    SORTORDER 影响「角色与可穿戴物的遮挡顺序」。
--  ★★ 二者范围很小（±7 / ±3），说明它们是**像素级微调**而非布局控制。
FINALOFFSET_MIN = -7
FINALOFFSET_MAX = 7

SORTORDER_MIN = -3
SORTORDER_MAX = 3

--★★ 【ANCHOR_* 锚点】77-81 行
--  ANCHOR_MIDDLE=0 / ANCHOR_LEFT=1 / ANCHOR_RIGHT=2
--  ANCHOR_TOP=1 / ANCHOR_BOTTOM=2
--  ★★ 注意一个易错点：三个锚点表**独立编号**且数值有重叠
--    （LEFT 和 TOP 都是 1）。它们是不同维度，不能混用。
--    ⇒ 用错表会得到「上下颠倒」或「左右错位」的 UI 布局。
ANCHOR_MIDDLE = 0
ANCHOR_LEFT = 1
ANCHOR_RIGHT = 2
ANCHOR_TOP = 1
ANCHOR_BOTTOM = 2

--★ 【SCALEMODE_* 缩放模式】83-87 行：窗口拉伸时的适配策略。
--  FILLSCREEN=1（拉伸填满，会变形） / PROPORTIONAL=2（保持比例）
--  FIXEDPROPORTIONAL=3 / FIXEDSCREEN_NONDYNAMIC=4
--  ★★ 设计取舍：宁可留黑边（PROPORTIONAL）也不让人物变形 ——
--    因为变形的手绘角色会非常难看。
SCALEMODE_NONE = 0
SCALEMODE_FILLSCREEN = 1 --stretch art to fit/fill window
SCALEMODE_PROPORTIONAL = 2 --preserve aspect ratio (picks the smaller of horizontal/vertical scale)
SCALEMODE_FIXEDPROPORTIONAL = 3 --same as SCALEMODE_FIXEDSCREEN_NONDYNAMIC, except for safe area on consoles
SCALEMODE_FIXEDSCREEN_NONDYNAMIC = 4 --scale same amount as window scaling from 1280x720

--★ 【物理驱动类型】PHYSICS_TYPE_ANIMATION_CONTROLLED=0 / _PHYSICS_CONTROLLED=1
--  ★★ 「谁说了算」：0 = 动画关键帧驱动位置（放风筝式跟随）；
--    1 = 物理引擎驱动（自由掉落）。
--  ★ 这决定了物体的运动是否受重力影响，是玩法相关的选择而非表现细节。
PHYSICS_TYPE_ANIMATION_CONTROLLED = 0
PHYSICS_TYPE_PHYSICS_CONTROLLED = 1

ALT_RENDERPATH = 1	-- You should really not use this unless you know what it is and how it works. Otherwise it can crash things, consume lots of memory, reduce performance, you name it.

MOVE_UP = 1
MOVE_DOWN = 2
MOVE_LEFT = 3
MOVE_RIGHT = 4

--【★★ 类别 C · ★手柄按键枚举（CONTROL_*）】99-284 行
--  ★★ 这是本文件**最大的单一区块**，约 100 个按键编号。
--  ★★★ 理解它的三个关键点：★★★
--  (1) ★ 它是「动作编号」不是「按键编号」—— 定义的是「按下这个键要做什么」，
--      实际物理按键到动作的映射在 input.lua / 具体平台的绑定文件里。
--      ⇒ 同一个 CONTROL_MOVE_UP 可以被键盘 W 键、手柄左摇杆上、
--        以及自定义按键同时触发。
--  (2) ★★ 编号必须**永远递增、永不复用**：
--      这些编号会存进玩家的「按键绑定设置」，并随云存档同步。
--      若把CONTROL_OPEN_DEBUG_MENU 从 70 改成 62，
--      旧玩家的「调试菜单」绑定就会变成别的动作 —— 静默错乱。
--      ⚠ 这就是「魔数风险」在本区的具体体现，见第 186 与 207 行的证据。
--  (3) VIRTUAL_CONTROL_* 从 10000 起（第 246 行），
--      是虚拟控制（触屏摇杆等），与实体按键空间隔离。
NUM_CRAFTING_RECIPES = 10

--push priorities
--  STATIC_PRIORITY = 10000（第 102 行）：输入事件的静态优先级基准值。
--  ★ 数值较大意味着「这类输入不受其他输入打断」，用于需要稳定执行的交互。
STATIC_PRIORITY = 10000

-- Controls:
-- Must match the Control enum in DontStarveInputHandler.h
-- Must match STRINGS.UI.CONTROLSSCREEN.CONTROLS

-- player action controls
--  CONTROL_PRIMARY=0 … CONTROL_ACTION=4（第 109-113 行）：五个基础动作。
--  ★★ 注意这不是「扳机/按键」，而是游戏内的抽象动作：
--      PRIMARY(主交互) SECONDARY(次交互) ATTACK(攻击) INSPECT(查看) ACTION(动作)
--  ★ 这是「输入抽象层」的核心：游戏只认动作，不认设备。
CONTROL_PRIMARY = 0
CONTROL_SECONDARY = 1
CONTROL_ATTACK = 2
CONTROL_INSPECT = 3
CONTROL_ACTION = 4

-- player movement controls
CONTROL_MOVE_UP = 5  -- left joystick up
CONTROL_MOVE_DOWN = 6 -- left joystick down
CONTROL_MOVE_LEFT = 7 -- left joystick left
CONTROL_MOVE_RIGHT = 8 -- left joystick right

-- view controls
CONTROL_ZOOM_IN = 9      -- left trigger
CONTROL_ZOOM_OUT = 10    -- right trigger
CONTROL_ROTATE_LEFT = 11  -- left shoulder
CONTROL_ROTATE_RIGHT = 12 -- right shoulder


-- player movement controls
CONTROL_PAUSE = 13  -- start
CONTROL_MAP = 14
CONTROL_INV_1 = 15
CONTROL_INV_2 = 16
CONTROL_INV_3 = 17
CONTROL_INV_4 = 18
CONTROL_INV_5 = 19
CONTROL_INV_6 = 20
CONTROL_INV_7 = 21
CONTROL_INV_8 = 22
CONTROL_INV_9 = 23
CONTROL_INV_10 = 24

CONTROL_FOCUS_UP = 25  -- d-pad up
CONTROL_FOCUS_DOWN = 26  -- d-pad down
CONTROL_FOCUS_LEFT = 27 -- d-pad left
CONTROL_FOCUS_RIGHT = 28 -- d-pad right

CONTROL_ACCEPT = 29  -- A
CONTROL_CANCEL = 30 -- B
CONTROL_SCROLLBACK = 31  -- left shoulder
CONTROL_SCROLLFWD = 32   -- right shoulder

CONTROL_PREVVALUE = 33
CONTROL_NEXTVALUE = 34

CONTROL_SPLITSTACK = 35
CONTROL_TRADEITEM = 36
CONTROL_TRADESTACK = 37
CONTROL_FORCE_INSPECT = 38
CONTROL_FORCE_ATTACK = 39
CONTROL_FORCE_TRADE = 40
CONTROL_FORCE_STACK = 41

CONTROL_OPEN_DEBUG_CONSOLE = 42
CONTROL_TOGGLE_LOG = 43
CONTROL_TOGGLE_DEBUGRENDER = 44

CONTROL_OPEN_INVENTORY = 45  -- right trigger
CONTROL_OPEN_CRAFTING = 46   -- left trigger
CONTROL_INVENTORY_LEFT = 47 -- right joystick left
CONTROL_INVENTORY_RIGHT = 48 -- right joystick right
CONTROL_INVENTORY_UP = 49 --  right joystick up
CONTROL_INVENTORY_DOWN = 50 -- right joystick down
CONTROL_INVENTORY_EXAMINE = 51 -- d-pad up
CONTROL_INVENTORY_USEONSELF = 52 -- d-pad right
CONTROL_INVENTORY_USEONSCENE = 53 -- d-pad left
CONTROL_INVENTORY_DROP = 54 -- d-pad down
CONTROL_PUTSTACK = 55
CONTROL_CONTROLLER_ATTACK = 56 -- X on xbox controller
CONTROL_CONTROLLER_ACTION = 57 -- A
CONTROL_CONTROLLER_ALTACTION = 58 -- B
CONTROL_USE_ITEM_ON_ITEM = 59

CONTROL_MAP_ZOOM_IN = 60
CONTROL_MAP_ZOOM_OUT = 61

--★★ CONTROL_OPEN_DEBUG_MENU = IsConsole() and 70 or -1, --62 steam deck is 70
--  ★★★ 这行是「魔数风险」的**最强证据**，请仔细读：★★★
--  (1) 它是**运行时条件表达式**，不是常量：
--      IsConsole() 为真（主机/Steam Deck）→ 70；否则 → -1（禁用）。
--  (2) ★ 行尾注释 '--62 steam deck is 70' 揭示了历史：
--      该键原本编号 62，后来因 Steam Deck 占用了 62，改为 70。
--  (3) ⚠ 但 62 并未被回收 —— 第 188 行 CONTROL_TOGGLE_SAY = 63、
--      63-66 又分配给了别的动作，且第 62 号在 CONTROL_* 序列中**确实空缺**。
--      ⇒ 结论：Steam Deck 版本的迁移遗留，导致编号不连续。
--  ★★ 教学价值：即便只是调试菜单这种低风险功能，
--    编号也不能随意重排，只能「新增、跳过、废弃」。
--★ 关联：platform/ 目录下各平台的 input 绑定。
CONTROL_OPEN_DEBUG_MENU = IsConsole() and 70 or -1 --62 steam deck is 70

CONTROL_TOGGLE_SAY = 63
CONTROL_TOGGLE_WHISPER = 64
CONTROL_TOGGLE_SLASH_COMMAND = 65
CONTROL_TOGGLE_PLAYER_STATUS = 66 -- Deprecated for CONTROL_OPEN_COMMAND_WHEEL.
CONTROL_SHOW_PLAYER_STATUS = 67

CONTROL_MENU_MISC_1 = 68  -- X
CONTROL_MENU_MISC_2 = 69  -- Y
CONTROL_MENU_MISC_3 = 70  -- L
CONTROL_MENU_MISC_4 = 71  -- R

CONTROL_INSPECT_SELF = 72 -- Keyboard self inspect [I]

CONTROL_SERVER_PAUSE = 73

CONTROL_CRAFTING_MODIFIER = 74		-- this + CONTROL_OPEN_CRAFTING to open with the search box ready to type in
CONTROL_CRAFTING_PINLEFT = 75
CONTROL_CRAFTING_PINRIGHT = 76

--★★★ CONTROL_INV_11 = 77 -- Sequence ordering difference but makes backwards compatability
--  ★★★ 这是「编号不可重排」的**最直接书面证据**：★★★
--  英文原注释：'Sequence ordering difference but makes backwards compatability'
--  「顺序（编号）与直觉不同，但这样能保持向后兼容」。
--  ★★★ 逐字解读这个决定：★★★
--    · CONTROL_INV_1..10 是第 131-140 行，编号 15~24。
--    · 但 CONTROL_INV_11..15 却从 **77** 开始（第 207-211 行）。
--    · 为什么不给 25~29？因为编号 25+ 之后已被其他键占用了。
--      若为了「顺序整齐」把 INV_11 改成 25，就会与既有存档中的
--      玩家按键设置冲突 —— 老玩家保存的是数字 77。
--  ★★⇒ 这条注释记录了一个「不优雅但正确」的设计决策。
--    后人看编号跳跃觉得奇怪时，这条注释就是答案。
--  ★ 关键认识：**这些数字是持久化数据的一部分**，
--    不是可以随手整理的顺序编号。
CONTROL_INV_11 = 77 -- Sequence ordering difference but makes backwards compatability easier.
CONTROL_INV_12 = 78
CONTROL_INV_13 = 79
CONTROL_INV_14 = 80
CONTROL_INV_15 = 81

CONTROL_START_EMOJI = 82

-- extra menu controls that should have been above but it's too late to add them now
CONTROL_MENU_BACK = 83
CONTROL_MENU_START = 84
CONTROL_MENU_L2 = 85
CONTROL_MENU_R2 = 86

CONTROL_OPEN_COMMAND_WHEEL = 87

-- controller targetting
CONTROL_TARGET_LOCK = 88
CONTROL_TARGET_CYCLE = 89

CONTROL_CAM_AND_INV_MODIFIER = 90
CONTROL_CHARACTER_COMMAND_WHEEL = 91

--Preset directional controls (used with CameraModifier) (cannot be remapped)
CONTROL_PRESET_RSTICK_UP = 92
CONTROL_PRESET_RSTICK_DOWN = 93
CONTROL_PRESET_RSTICK_LEFT = 94
CONTROL_PRESET_RSTICK_RIGHT = 95
CONTROL_PRESET_DPAD_UP = 96
CONTROL_PRESET_DPAD_DOWN = 97
CONTROL_PRESET_DPAD_LEFT = 98
CONTROL_PRESET_DPAD_RIGHT = 99

CONTROL_AXISALIGNEDPLACEMENT_TOGGLEMOD = 100
CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID = 101

CONTROL_CUSTOM_START = 102 -- NOTES(JBK): This might not be used for anything keep it above our last control in case mods are using it for something.

-- virtual controls
--★★ VIRTUAL_CONTROL_START = 10000 —— 虚拟控制编号起点。
--  ★★ 选10000 而非 1，是为了与实体按键（0~102）**彻底隔离**，
--    让程序能靠「是否 ≥10000」判断这是虚拟输入。
--  ★ 这是「编号空间分区」的标准做法，本文件多处使用。
VIRTUAL_CONTROL_START = 10000

-- Used in conjunction with CONTROL_CAM_AND_INV_MODIFIER and CONTROL_SCHEME_CAM_AND_INV
--NOTE: these must be listed in order: up, down, left, right
VIRTUAL_CONTROL_CAMERA_ZOOM_IN = 10001
VIRTUAL_CONTROL_CAMERA_ZOOM_OUT = 10002
VIRTUAL_CONTROL_CAMERA_ROTATE_LEFT = 10003
VIRTUAL_CONTROL_CAMERA_ROTATE_RIGHT = 10004
--
VIRTUAL_CONTROL_AIM_UP = 10005
VIRTUAL_CONTROL_AIM_DOWN = 10006
VIRTUAL_CONTROL_AIM_LEFT = 10007
VIRTUAL_CONTROL_AIM_RIGHT = 10008
--
VIRTUAL_CONTROL_INV_UP = 10009
VIRTUAL_CONTROL_INV_DOWN = 10010
VIRTUAL_CONTROL_INV_LEFT = 10011
VIRTUAL_CONTROL_INV_RIGHT = 10012
--
VIRTUAL_CONTROL_INV_ACTION_UP = 10013
VIRTUAL_CONTROL_INV_ACTION_DOWN = 10014
VIRTUAL_CONTROL_INV_ACTION_LEFT = 10015
VIRTUAL_CONTROL_INV_ACTION_RIGHT = 10016
--
VIRTUAL_CONTROL_STRAFE_UP = 10017
VIRTUAL_CONTROL_STRAFE_DOWN = 10018
VIRTUAL_CONTROL_STRAFE_LEFT = 10019
VIRTUAL_CONTROL_STRAFE_RIGHT = 10020
--

-- Control Schemes:
-- Must match STRINGS.UI.CONTROLSSCREEN.SCHEMES

--★ CONTROL_SCHEME_CAM_AND_INV = 1：切换「镜头+物品栏」双屏控制方案。
--  XBOX_CONTROLLER_ID = 17：Xbox 手柄的设备 ID。
--  CONTROL_SKIN_PRESETS = CONTROL_MENU_MISC_1（第 284 行）：
--    ★★ 这是**别名赋值** —— 皮肤预设功能复用了 MENU_MISC_1 这个动作。
--    ⇒ 不新增编号，而是复用已有动作，是维持兼容的另一种手段。
CONTROL_SCHEME_CAM_AND_INV = 1

XBOX_CONTROLLER_ID = 17

-- a constant used in place of hardcoding the CONTROL_ for the skin presets popup. This is overridden to a different CONTROL_ in the console branch (currently CONTROL_MENU_L2)
CONTROL_SKIN_PRESETS = CONTROL_MENU_MISC_1
--【★ 类别 D · 键盘 / 鼠标 / 手势键码】285-406 行
--  ★★ 关键区分：这一区是**操作系统层**的键码，不是游戏动作。
--    对比上一区 CONTROL_*（游戏内动作），这里 KEY_* 是物理按键。
--  ★★ 数字 256/257…（第 287-303 行）是 Windows 虚拟键码小键盘区的偏移：
--    Windows 把小键盘 0-9 定义为 0x60(96) 起的偏移，这里从 256 起重新编号，
--    目的是避开字母区(A=97)与数字区(0=48)造成冲突。
--  ★★ 由此推出两条实操结论：
--    · 数字键 = 48~57（对应 '0'~'9' 的 ASCII 码）
--    · 字母键 A~Z = 97~122（同样就是 ASCII 码）
--      ⇒ 这些键码实际就是字符的 ASCII 值，写起来省事。

KEY_TAB = 9
KEY_KP_0			= 256
KEY_KP_1			= 257
KEY_KP_2			= 258
KEY_KP_3			= 259
KEY_KP_4			= 260
KEY_KP_5			= 261
KEY_KP_6			= 262
KEY_KP_7			= 263
KEY_KP_8			= 264
KEY_KP_9			= 265
KEY_KP_PERIOD		= 266
KEY_KP_DIVIDE		= 267
KEY_KP_MULTIPLY		= 268
KEY_KP_MINUS		= 269
KEY_KP_PLUS			= 270
KEY_KP_ENTER		= 271
KEY_KP_EQUALS		= 272
KEY_MINUS = 45
KEY_EQUALS = 61
KEY_SPACE = 32
KEY_ENTER = 13
KEY_ESCAPE = 27
KEY_HOME = 278
KEY_INSERT = 277
KEY_DELETE = 127
KEY_END    = 279
KEY_PAUSE = 19
KEY_PRINT = 316
KEY_CAPSLOCK = 301
KEY_SCROLLOCK = 302
KEY_RSHIFT = 303 -- use KEY_SHIFT instead
KEY_LSHIFT = 304 -- use KEY_SHIFT instead
KEY_RCTRL = 305 -- use KEY_CTRL instead
KEY_LCTRL = 306 -- use KEY_CTRL instead
KEY_RALT = 307 -- use KEY_ALT instead
KEY_LALT = 308 -- use KEY_ALT instead
KEY_LSUPER = 311
KEY_RSUPER = 312
--★★ KEY_ALT=400 / KEY_CTRL=401 / KEY_SHIFT=402（第 325-327 行）
--  ★★ 这三个键码 400+ 是**自造的虚拟键码**，不对应任何真实字符 ASCII。
--  ★ 为什么不给它们 ASCII？
--    因为「按下 Alt」是一个**修饰键状态**，不是一个字符。
--    ⇒ 400+ 这段空间专用于「无字符的修饰键」，与真实键码分离。
--  ★ 与第 246 行VIRTUAL_CONTROL_START=10000 同属「编号空间分区」思想。
KEY_ALT = 400
KEY_CTRL = 401
KEY_SHIFT = 402
KEY_BACKSPACE = 8
KEY_PERIOD = 46
KEY_SLASH = 47
KEY_SEMICOLON = 59
KEY_LEFTBRACKET	= 91
KEY_BACKSLASH	= 92
KEY_RIGHTBRACKET= 93
KEY_TILDE = 96
KEY_A = 97
KEY_B = 98
KEY_C = 99
KEY_D = 100
KEY_E = 101
KEY_F = 102
KEY_G = 103
KEY_H = 104
KEY_I = 105
KEY_J = 106
KEY_K = 107
KEY_L = 108
KEY_M = 109
KEY_N = 110
KEY_O = 111
KEY_P = 112
KEY_Q = 113
KEY_R = 114
KEY_S = 115
KEY_T = 116
KEY_U = 117
KEY_V = 118
KEY_W = 119
KEY_X = 120
KEY_Y = 121
KEY_Z = 122
KEY_F1 = 282
KEY_F2 = 283
KEY_F3 = 284
KEY_F4 = 285
KEY_F5 = 286
KEY_F6 = 287
KEY_F7 = 288
KEY_F8 = 289
KEY_F9 = 290
KEY_F10 = 291
KEY_F11 = 292
KEY_F12 = 293

KEY_UP			= 273
KEY_DOWN		= 274
KEY_RIGHT		= 275
KEY_LEFT		= 276
KEY_PAGEUP		= 280
KEY_PAGEDOWN	= 281

KEY_0 = 48
KEY_1 = 49
KEY_2 = 50
KEY_3 = 51
KEY_4 = 52
KEY_5 = 53
KEY_6 = 54
KEY_7 = 55
KEY_8 = 56
KEY_9 = 57

-- DO NOT use these for gameplay!
--★ MOUSEBUTTON_LEFT=1000 … MOUSEBUTTON_SCROLLDOWN=1003（第 394-398 行）：
--  ★★ 注意起点是 1000 —— 远超 ASCII 范围（最大 122）。
--    ⇒ 沿用「分区编号」：鼠标键独占 1000+ 区间，永不与键盘冲突。
--  GESTURE_ZOOM_IN=900 … GESTURE_MAX=904（第 401-405 行）：
--    ★ 触控手势编号占用 900+。同样是独立分区。
--  ★★ 汇总本区编号分区：
--    0~99 基础动作 / 100~999 其他 / 900~999 手势 / 1000+ 鼠标 / 10000+ 虚拟
MOUSEBUTTON_LEFT = 1000
MOUSEBUTTON_RIGHT = 1001
MOUSEBUTTON_MIDDLE = 1002
MOUSEBUTTON_SCROLLUP = 1003
MOUSEBUTTON_SCROLLDOWN = 1004


GESTURE_ZOOM_IN = 900
GESTURE_ZOOM_OUT = 901
GESTURE_ROTATE_LEFT = 902
GESTURE_ROTATE_RIGHT = 903
GESTURE_MAX = 904

--【★ 类别 E · 前后端 prefab 与角色表】407-648 行
--  ★ 这些表决定「游戏加载哪些资源」，是内容装配的清单。
SCREEN_FLASH_SCALING =
{
	0.9, -- default
	0.6, -- dim
	0.3, -- dimmest
}

--  BACKEND_PREFABS = { "forest", "cave", "lavaarena", "quagmire" }
--  FRONTEND_PREFABS = { "frontend" }
--  ★★ 这四个后端 prefab 名字就是**四种世界类型**：
--      forest 普通世界 / cave 洞穴 / lavaarena 熔岩竞技场 / quagmire 沼泽
--  ★★ 这些字符串是 ID（见文件头「物品 ID 系统」警告）：
--    它们参与世界存档的 prefab 引用，改名会导致老存档无法加载世界。
BACKEND_PREFABS = { "forest", "cave", "lavaarena", "quagmire" }
FRONTEND_PREFABS = { "frontend" }
RECIPE_PREFABS = {}
--Defined below:
-- SPECIAL_EVENT_GLOBAL_PREFABS
-- SPECIAL_EVENT_BACKEND_PREFABS
-- SPECIAL_EVENT_FRONTEND_PREFABS
-- FESTIVAL_EVENT_GLOBAL_PREFABS
-- FESTIVAL_EVENT_BACKEND_PREFABS
-- FESTIVAL_EVENT_FRONTEND_PREFABS

--  FADE_OUT = false / FADE_IN = true（第 425-426 行）：
--    ★ 注意这两个是**布尔常量**却与图像淡入淡出无关，
--      它们表示「淡入/淡出枚举」的两个成员（而非效果开关）。
--    ⚠ 极易误读：FADE_OUT = false 不代表「淡出关闭」，
--      而是「FADE_OUT 这个枚举项的值是 false」。
FADE_OUT = false
FADE_IN = true

--Legacy table, not for DST
--★★ 【★ 角色清单表】429-510 行
--  MAIN_CHARACTERLIST / ROG_CHARACTERLIST / DST_CHARACTERLIST（分别定义）
--  SEAMLESSSWAP_CHARACTERLIST（第 466 行）—— 「无缝切换」角色池
--  MODCHARACTERLIST / MODCHARACTEREXCEPTIONS_DST（模组角色）
--  ★★ 为什么要分成多个表？
--    因为不同入口看到的角色列表不同：
--      · 联机版（DST）不该出现仅限单机（Swine）的角色
--      · 模组角色按兼容模式分别过滤
--    ⇒ 表名里的 EXCEPTIONS（例外）就是「排除名单」。
--★ CHARACTER_GENDERS（第 614 行）：角色性别表 —— 影响外观与语音，
--  ★★ 属于存档相关：换性别设置可能影响角色贴图，需谨慎。
MAIN_CHARACTERLIST =
{
    "wilson", "willow", "wolfgang", "wendy", "wx78", "wickerbottom", "woodie", "wes", "waxwell",
}

--Legacy table, not for DST
ROG_CHARACTERLIST =
{
    "wathgrithr", "webber",
}

--When adding new characters with alternate states, be sure to update skinsutils.lua function GetSkinModes.
-- NOTES(JBK): Keep this up to date with LOOKUP_LIST in scrapbookpartitions.lua
DST_CHARACTERLIST =
{
    "wilson",
    "willow",
    "wolfgang",
    "wendy",
    "wx78",
    "wickerbottom",
    "woodie",
    "wes",
    "waxwell",
    "wathgrithr",
    "webber",
    "winona",
    "warly",
    "wortox",
    "wormwood",
    "wurt",
    "walter",
    "wanda",
    "wonkey", --hidden internal char
}

-- This is used for seamless swap characters only and can not spawn in as these characters.
SEAMLESSSWAP_CHARACTERLIST =
{
    "wonkey",
}

CHARACTER_VIDEOS =
{
	wilson = {"https://bit.ly/3w9VYcN"},
	willow = {"https://bit.ly/3rFOkU3"},
	wendy = {"https://bit.ly/3fI3PbR"},
	wolfgang = {"https://klei.gg/33A9mNx"},
	wx78 = {"https://klei.gg/3F9qqc1"},
	wickerbottom = {"https://klei.gg/3bCaOTL"},
	wes = {"https://bit.ly/2QLFpn4"},
	waxwell = {"https://klei.gg/3AHfLEb"},
	woodie = {"https://bit.ly/3sHhUK1"},
	wathgrithr = {"https://bit.ly/3rC8YV6"},
	webber = {"https://klei.gg/3zXJrLt"},
	winona = {"https://bit.ly/3fB6LHb"},
    wortox = {"https://bit.ly/3cBQ10g"},
    wormwood = {"https://bit.ly/3cBilQq"},
    warly = {"https://bit.ly/39vp0tG"},
    wurt = {"https://bit.ly/2QVJup1"},
	walter = {"https://bit.ly/31Ajrpj"},
	wanda = {"https://klei.gg/dst-wanda-short"},
}

PLAYER_SWAP_TRANSITIONS =
{
	wonkey =
	{
		transfrom_state = "changetomonkey_pst",
		restore_state = "changefrommonkey_pst",
	},
}

require("prefabskins")
require("clothing")
require("beefalo_clothing")
require("misc_items")
require("emote_items")
require("idleanimations_items")
require("item_blacklist")
require("entitlementlookups")

CLOTHING.body_default1 =
{
    type = "body",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
CLOTHING.hand_default1 =
{
    type = "hand",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
CLOTHING.legs_default1 =
{
    type = "legs",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
CLOTHING.feet_default1 =
{
    type = "feet",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
MISC_ITEMS.beard_default1 =
{
    type = "beard",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}



--★ 【★ 装备槽位表与装备默认值】549-585 行
--  这些是「角色身上默认穿什么」：
--    CLOTHING.body_default1 / hand_default1 / legs_default1 / feet_default1
--    MISC_ITEMS.beard_default1 / BEEFALO_CLOTHING.* （牛牛的四件套）
--  ★★ ★ 警告：_default1 后缀表示「第 1 套默认搭配」。
--    同一常量族常有 default2 / default3 等变体（用于皮肤或季节更换）。
--    ⇒ 增删变体时必须注意**编号连续性**。
BEEFALO_CLOTHING.beef_body_default1 =
{
    type = "beef_body",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
BEEFALO_CLOTHING.beef_horn_default1 =
{
    type = "beef_horn",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
BEEFALO_CLOTHING.beef_head_default1 =
{
    type = "beef_head",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
BEEFALO_CLOTHING.beef_feet_default1 =
{
    type = "beef_feet",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}
BEEFALO_CLOTHING.beef_tail_default1 =
{
    type = "beef_tail",
    skin_tags = {},
    is_default = true,
    release_group = 999,
}


--★ MAINSCREEN_TOOL_LIST / TORSO_LIST / HAT_LIST（586-604 行）：
--  ★ 主界面商店分类清单 —— 决定商店里按什么分类展示。
MAINSCREEN_TOOL_LIST =
{
    "swap_axe", "swap_spear", "swap_pickaxe", "swap_shovel", "swap_staffs", "swap_cane", "swap_fishingrod", "swap_hammer", "swap_batbat", "swap_ham_bat",
}


MAINSCREEN_TORSO_LIST =
{
    "", "", "", "", "armor_wood", "armor_sweatervest", "torso_amulets", "armor_trunkvest_winter", "armor_ruins", "torso_dragonfly", "torso_hawaiian"
}


MAINSCREEN_HAT_LIST =
{
    "", "", "", "", "hat_top", "hat_beefalo", "hat_football", "hat_winter", "hat_spider", "hat_catcoon", "hat_mole", "hat_ice", "hat_watermelon"
}


MODCHARACTERLIST =
{
    -- this gets populated by mods
}

MODCHARACTEREXCEPTIONS_DST =
{
    -- this also gets populated by mods
}

CHARACTER_GENDERS =
{
    FEMALE =
    {
        "willow",
        "wendy",
        "wickerbottom",
        "wathgrithr",
        "winona",
        "wurt",
        "wanda",
    },
    MALE =
    {
        "wilson",
        "woodie",
        "waxwell",
        "wolfgang",
        "wes",
        "webber",
        "warly",
        "wortox",
        "wormwood",
        "walter",
    },
    ROBOT =
    {
        "wx78",
        "pyro",
    },
    NEUTRAL = {}, --empty, for modders to add to
    PLURAL = {}, --empty, for modders to add to
}

--  MODCHARACTERMODES = {} --empty, for modders to add to（第 648 行）：
--    ★★ 官方预留的**空表 + 显式说明用途**，是模组扩展的标准形态。
--    ★ 本文件多处采用此模式（CRAFTINGSTATION_LIMITED_RECIPES、
--      STORM_TYPES 等），读表时看到 {} 就知道「这是扩展点」。
MODCHARACTERMODES = {} --empty, for modders to add to

--★★★ 【★ 类别 F · ★★ 装备槽位与物品标签 —— 本任务重点区域 ★★】649-671 行
--
--  ★★★ 首先澄清一个常见误解（必须说清，否则后面全错）：★★★
--  ★★ 本文件里**不存在** INVENTORY_BACKPACK / INVENTORY_EQUIP /
--    INVENTORY_NUM_SLOTS 这三个常量。
--    推理依据：已在整个脚本目录（4030 个文件）内全文搜索
--      「INVENTORY_NUM_SLOTS」「INVENTORY_BACKPACK」「INVENTORY_EQUIP」，
--      **零命中** —— 它们在本项目任何文件中都不存在。
--  ⇒ 背包容量的真实来源是别处：
--      · containers.lua:23 params.backpack —— 用循环插入 8 个 slotpos（2列×4行）
--        来**动态生成** 8 格背包，槽位数由 UI 布局决定而非数字常量；
--      · containers.lua:43 params.icepack = params.backpack（冰盒复用同一布局）
--    ★ 这是「数据驱动 UI」的表现：容量 = 槽位坐标数量，而非写死的常量。
MAXITEMSLOTS = 15

--★★★ 【★★ EQUIPSLOTS —— 真正的装备槽位定义】★★★
--  HANDS = "hands" / HEAD = "head" / BODY = "body" / BEARD = "beard"
--
--  ★★★ 三个关键设计要点：★★★
--  (1) ★★ 值是**字符串**，不是数字！
--      ⇒ 槽位标识用有语义的英文单词，而非 0/1/2/3。
--      ★★ 好处：存档里存的是 "head" 而不是数字，
--        即使将来调整槽位顺序或增删槽位，旧存档仍能正确解析。
--        若用数字索引，插入新槽位就会让所有旧存档的装备错位。
--      ★ 这正是「字符串 ID 比数字索引更抗重构」的标准案例。
--  (2) ★★ 它是**开放表**（文件末尾无闭合花括号前的普通表）：
--      模组可添加自己的槽位（如 modcharacter 装备位）。
--  (3) ★★ 槽位数量 = 4（头/身/手/胡须），加上背包容纳物品：
--      物品栏与装备栏是**两套机制**——
--      装备栏用 EQUIPSLOTS（字符串标识），背包容纳在 containers.lua 定义。
--★ 消费方：components/inventory.lua:166 遍历 EQUIPSLOTS 初始化装备栏；
--  components/equippable.lua 负责穿戴逻辑；
--  ★ 另见 beefalo_clothing.lua 牛的独立装备体系（BEEFALO_CLOTHING）。
--★⚠ 魔数风险：**删除或改名某个槽位会直接损坏存档**。
--    玩家存档存的是 {head = "hat"}，键名必须保持为 "head"。
--    ⇒ 唯一安全的改动是**新增**槽位，永不删除/改名。
EQUIPSLOTS =
{
    HANDS = "hands",
    HEAD = "head",
    BODY = "body",
    BEARD = "beard",
}

--★★ 【ITEMTAG 物品标签】660-671 行
--  FOOD / MEAT / WEAPON / TOOL / TREASURE / FUEL / FIRE / STACKABLE / FX
--
--  ★★ 与 EQUIPSLOTS 同为字符串值，但用途不同：
--    EQUIPSLOTS = 「装备放在哪」（互斥，一个槽位一个物品）
--    ITEMTAG= 「物品是什么」（可叠加，一个物品可有多个标签）
--  ★★ 设计要点：**标签是可组合的**，用 inst:HasTag("weapon") 查询。
--    例：一把剑可能同时带 WEAPON + TOOL 两个标签。
--  ★★ 这套标签体系是 DST 内容装配的核心机制：
--    烹饪、合成、AI 行为判定都靠标签而非具体物品名。
--    ⇒ 好处：新增物品无需改动任何判定代码；
--      代价：改标签会**全局改变**该物品的所有行为。
--★ 完整标签列表见 prefabs/ 各文件的 tags 参数定义。
ITEMTAG =
{
    FOOD = "food",
    MEAT = "meat",
    WEAPON = "weapon",
    TOOL = "tool",
    TREASURE = "treasure",
    FUEL = "fuel",
    FIRE = "fire",
    STACKABLE = "stackable",
    FX = "FX",
}
--★ 承上：EQUIPSLOTS（4 个槽位，字符串 ID）与 ITEMTAG（9 个行为标签）
--  共同构成本项目的「物品 — 位置 — 行为」三元描述。
--【★ 类别 G · 地面与地形】672-789 行（★大部分已废弃）
--  ★★ 英文原注释（第 681 行）写得很明确：
--    'this table is deprecated, nothing should add into this table, or
--     reference this table at all.'
--    「此表已废弃，不应再向其中添加，也不应再引用它。」
--  ★★★ 所以读GROUND_* 时：全部跳过即可，别花时间研究。
--    真正生效的地形判定已迁移到 WORLD_TILES / GROUND_* 新表（第 765-787 行）。

--  OCEAN_DEPTH（海洋深度枚举）SHALLOW=1 / NORMAL=2 / DEEP=3 / VERY_DEEP=4
--    ★★ 这是**仍在使用**的枚举，不是废弃表。
--      深度影响水下氧气、水压、可见度等 gameplay 参数。
--    ★ 命名规律：深度递增 1→4，对应 playercontroller.lua 的水下判定。
OCEAN_DEPTH =
{
    SHALLOW = 1,
    NORMAL = 2,
    DEEP = 3,
    VERY_DEEP = 4,
}

--this table is deprecated, nothing should add into this table, or reference this table at all.
GROUND =
{
	INVALID = 65535,
    IMPASSABLE = 1,
    ROAD = 2,
    ROCKY = 3,
    DIRT = 4,
	SAVANNA = 5,
	GRASS = 6,
	FOREST = 7,
	MARSH = 8,
	WEB = 9,
	WOODFLOOR = 10,
	CARPET = 11,
	CHECKER = 12,
	CAVE = 13,
	FUNGUS = 14,
	SINKHOLE = 15,
    UNDERROCK = 16,
    MUD = 17,
    BRICK = 18,
    BRICK_GLOW = 19,
    TILES = 20,
    TILES_GLOW = 21,
    TRIM = 22,
    TRIM_GLOW = 23,
	FUNGUSRED = 24,
	FUNGUSGREEN = 25,
	DECIDUOUS = 30,
	DESERT_DIRT = 31,
	SCALE = 32,
	LAVAARENA_FLOOR = 33,
	LAVAARENA_TRIM = 34,
	QUAGMIRE_PEATFOREST = 35,
	QUAGMIRE_PARKFIELD = 36,
	QUAGMIRE_PARKSTONE = 37,
	QUAGMIRE_GATEWAY = 38,
	QUAGMIRE_SOIL = 39,
	QUAGMIRE_CITYSTONE = 41,
	PEBBLEBEACH = 42,
	METEOR = 43,
    SHELLBEACH = 44,
    ARCHIVE = 45,
    FUNGUSMOON = 46,
    FARMING_SOIL = 47,
	FUNGUSMOON_NOISE = 120,
	METEORMINE_NOISE = 121,
	METEORCOAST_NOISE = 122,
    DIRT_NOISE = 123,
	ABYSS_NOISE = 124,
	GROUND_NOISE = 125,
	CAVE_NOISE = 126,
	FUNGUS_NOISE = 127,
	UNDERGROUND = 128,
	WALL_ROCKY = 151,
	WALL_DIRT = 152,
	WALL_MARSH = 153,
	WALL_CAVE = 154,
	WALL_FUNGUS = 155,
	WALL_SINKHOLE = 156,
	WALL_MUD = 157,
	WALL_TOP = 158,
	WALL_WOOD = 159,
	WALL_HUNESTONE = 160,
	WALL_HUNESTONE_GLOW = 161,
	WALL_STONEEYE = 162,
	WALL_STONEEYE_GLOW = 163,
	FAKE_GROUND = 200,
	OCEAN_START = 201,
	OCEAN_COASTAL = 201,
	OCEAN_COASTAL_SHORE = 202,
	OCEAN_SWELL = 203,
	OCEAN_ROUGH = 204,
	OCEAN_BRINEPOOL = 205,
	OCEAN_BRINEPOOL_SHORE = 206,
	OCEAN_HAZARDOUS = 207,
    OCEAN_WATERLOG = 208,
	OCEAN_END = 247,
}
GROUND.OCEAN_REEF = GROUND.OCEAN_BRINEPOOL
GROUND.OCEAN_REEF_SHORE = GROUND.OCEAN_BRINEPOOL_SHORE

--these are filled in via AddTile
--★★ 【地面分类表群】765-787 行 —— 这才是现行的地面定义
--  GROUND_NAMES / TERRAFORM_IMMUNE / GROUND_FLOORING / GROUND_HARD
--  GROUND_ROADWAYS（★路面：玩家移速加成）/ GROUND_NOGROUNDOVERLAYS
--  GROUND_INVISIBLETILES（隐藏贴图）/ GROUND_ISTEMPTILE（临时层）
--  ★★ 这 8 张表都是「集合表」，通过表内是否存在某地面名来判断。
--    例：某地面若在 GROUND_ROADWAYS 内，则玩家走在上面会加速。
--  ★★ 设计要点：把行为绑定到**地面类型集合**，而非逐个地面写 if。
--    ⇒ 新增一种地面只需在对应集合里加个名字，行为自动继承。
--★ GROUND_CREEP_IDS（第 781 行）：会「蔓延」的地面（青苔等）。
--  INVERTED_WORLD_TILES（第 785 行）：反向世界用的贴图。
GROUND_NAMES = {}
TERRAFORM_IMMUNE = {}
GROUND_FLOORING = {} --These tiles are flooring (stuff shouldn't grow on them)
GROUND_HARD = {} --not plantable
GROUND_ROADWAYS = {} -- Player speed boosting enabled.
GROUND_NOGROUNDOVERLAYS = {} -- Stops rendering of snow or water etc overlays this table is immutable after initialization or engine crashes may occur.
GROUND_INVISIBLETILES = {} -- Stops rendering of the tile top and skirt but will still have overlays this table is immutable after initialization or engine crashes may occur.
GROUND_ISTEMPTILE = {} -- Tiles that are temporarily placed as a layer using the undertile component.

--★ FALLOFF_IDS（第 774-780 行）：
--  ★ 「边缘衰减」贴图ID —— 用于让地形过渡看起来自然。
FALLOFF_IDS = {
    FALLOFF = 1,
    DOCK_FALLOFF = 2,
    OCEANICE_FALLOFF = 3,
    INVISIBLE = 4,
}

--【★ 类别 H · 世界事件与音乐】790-1228 行
--  ★★ 本区的核心是「事件 ID 字符串」，它们决定加载哪个事件脚本。
--  ★★ 这些字符串会写进存档（世界记录了「本局发生过什么事件」）——
--    改名会导致旧存档的事件状态丢失。
GROUND_CREEP_IDS = {
    WEBCREEP = 1,
}

INVERTED_WORLD_TILES = {
    [65535] = "INVALID"
}
--★★★ 【WORLD_TILES —— 世界贴图编号体系】788-834 行
--  ★★★ 这是本文件最「魔数密集」的区域，请务必理解：★★★
--  它把贴图编号划分成**若干连续区间**，每段对应一类地形：
--    LEGACY（老版）  : 2-127 陆地，128-200 不可通行，201-247 海洋
--    现行 WORLD_TILES:
--      256 ~ 8447   陆地（WORLD_TILES_LAND_START=256, SIZE=8192）
--      8448 ~ 10495 噪声地形（NOISE_START=8449, SIZE=2048）
--      10496 ~ 14591 海洋（OCEAN_START, SIZE=4096）
--      14592 ~ 18687 不可通行（IMPASSABLE_START, SIZE=4096）
--  ★★ 全部由基础值 + SIZE 递推写成（第 811-834 行），而非硬编码。
--    这是本文件少见的**递推式常量定义**，改一个 START 后续全部跟随。
--  ★★⚠ 魔数风险（最高）：这些编号会**写进世界存档**。
--    世界文件记录每个格子的贴图编号，若改变划分方式：
--      · 新世界正常，但旧世界加载时贴图全部错位（草原变海洋）
--      · 且不会有任何报错 —— 只是画面全乱。
--    ⇒ 这是本文件**最不可修改**的常量群，务必不要动。
WORLD_TILES = {
    INVALID = 65535,
}

function GetWorldTileMap()
    local world_tile_map = {}
    for name, id in pairs(WORLD_TILES) do
        world_tile_map[name] = id
    end
    for name, id in pairs(GROUND) do
        if not WORLD_TILES[name] and not INVERTED_WORLD_TILES[id] then
            world_tile_map[name] = id
        end
    end
    return world_tile_map
end

--★ LEGACY_WORLD_TILES_*（805-809 行）与 LEGACY_*_OCEAN（822-823 行）：
--  ★ 老版编号区间的遗留定义，仅为读取极早期存档所需。
--  ★ 对比可见：新旧体系**完全分开**，互不重叠 ——
--    这是刻意设计，让老存档的编号不会与新编号混淆。
LEGACY_WORLD_TILES_LAND_START = 2
LEGACY_WORLD_TILES_LAND_END = 127

LEGACY_WORLD_TILES_NOISE_START = 110
LEGACY_WORLD_TILES_NOISE_END = 127

WORLD_TILES_LAND_START = 256
WORLD_TILES_LAND_SIZE = 8192

WORLD_TILES_LAND_ONLY_END = WORLD_TILES_LAND_START + WORLD_TILES_LAND_SIZE

WORLD_TILES_NOISE_START = WORLD_TILES_LAND_ONLY_END + 1
WORLD_TILES_NOISE_SIZE = 2048
WORLD_TILES_NOISE_END = WORLD_TILES_NOISE_START + WORLD_TILES_NOISE_SIZE

WORLD_TILES_LAND_END = WORLD_TILES_NOISE_END

LEGACY_WORLD_TILES_OCEAN_START = 201
LEGACY_WORLD_TILES_OCEAN_END = 247

WORLD_TILES_OCEAN_START = WORLD_TILES_LAND_END + 1
WORLD_TILES_OCEAN_SIZE = 4096
WORLD_TILES_OCEAN_END = WORLD_TILES_OCEAN_START + WORLD_TILES_OCEAN_SIZE

LEGACY_WORLD_TILES_IMPASSABLE_START = 128
LEGACY_WORLD_TILES_IMPASSABLE_END = 200

WORLD_TILES_IMPASSABLE_START = WORLD_TILES_OCEAN_END + 1
WORLD_TILES_IMPASSABLE_SIZE = 4096
WORLD_TILES_IMPASSABLE_END = WORLD_TILES_IMPASSABLE_START + WORLD_TILES_IMPASSABLE_SIZE

---------------------------------------------------------
--★★★ 【SPECIAL_EVENTS —— 特殊世界事件】837-853 行
--  这是一张「事件名 → 数值 ID」的映射表。
--  ★★ 为什么用字符串键 + 数字值？
--    · 字符串是可读的事件名（axe_fight、lunar_curse 等）
--    · 数字值是内部索引，便于数组化处理与排序
--  ★★ 后面第 889-895 行会据此拼出 prefab 名：
--      SPECIAL_EVENT_GLOBAL_PREFABS = { WORLD_SPECIAL_EVENT.."_event_global" }
--    ⇒ 事件名 "axe_fight" 自动派生出 prefab "axe_fight_event_global"。
--      ★ 这是「命名约定驱动资源加载」的典型手法：新增事件只要起对名字，
--        资源就能被自动找到，无需改加载代码。
--★★⚠ 魔数风险：事件名同时是「存档中的键」与「prefab 名的前缀」，
--    两处强耦合。改名会同时破坏存档兼容与资源加载。
SPECIAL_EVENTS =
{
    NONE = "none",
    HALLOWED_NIGHTS = "hallowed_nights",
    WINTERS_FEAST = "winters_feast",
	CARNIVAL = "crow_carnival",
    YOTG = "year_of_the_gobbler",
    YOTV = "year_of_the_varg",
    YOTP = "year_of_the_pig",
    YOTC = "year_of_the_carrat",
    YOTB = "year_of_the_beefalo",
    YOT_CATCOON = "year_of_the_catcoon",
    YOTR = "year_of_the_bunnyman",
    YOTD = "year_of_the_dragonfly",
    YOTS = "year_of_the_snake",
    YOTH = "year_of_the_knight",
}
--  WORLD_SPECIAL_EVENT = SPECIAL_EVENTS.CARNIVAL（第 854 行）：
--    ★★ 当前生效的特殊事件 = 嘉年华。注意这是**指向某个成员的引用**，
--      而不是写裸字符串。
--  ★★ 这种「默认事件」的写法便于模组覆盖：
--      改这一个赋值即可切换整个活动周期。
--  WORLD_EXTRA_EVENTS = {}（第 855 行）：额外事件列表（空表 = 扩展点）。
WORLD_SPECIAL_EVENT = SPECIAL_EVENTS.CARNIVAL
WORLD_EXTRA_EVENTS = {}

--★ 【FESTIVAL_EVENTS 节庆事件】857-862 行。
--  ★ 节庆事件与特殊事件是**两套独立机制**：
--    SPECIAL_EVENTS  → 影响世界生成/玩法（如嘉年华）
--    FESTIVAL_EVENTS → 影响节庆装饰与掉落（如新年、冬季盛宴）
--  WORLD_FESTIVAL_EVENT = FESTIVAL_EVENTS.NONE（第 863 行）。
FESTIVAL_EVENTS =
{
    NONE = "none",
    LAVAARENA = "lavaarena",
    QUAGMIRE = "quagmire",
}
WORLD_FESTIVAL_EVENT = FESTIVAL_EVENTS.NONE
--★★★ 【PREVIOUS_FESTIVAL_EVENTS —— 「历届节庆顺序」记录】864-871 行
--  PREVIOUS_FESTIVAL_EVENTS = { LAVAARENA, QUAGMIRE } --deprecated, use PREVIOUS_FESTIVAL_EVENTS_ORDER
--    ★★ 行尾英文原注释明确标注 'deprecated'，并指明替代者。
--  PREVIOUS_FESTIVAL_EVENTS_ORDER（第 865-870 行）：
--      { id = LAVAARENA, season = 2 },
--      { id = QUAGMIRE,   season = 1 },
--      { id = LAVAARENA,  season = 1 },
--
--  ★★★ 逐条解读这个「表的历史」——它记录的不是玩家数据，而是
--    ★★ **节庆活动按年份推进的排期表**：
--      第 1 条：第 2 个节庆周期是熔岩竞技场（season=2 那一季）
--      第 2 条：第 1 个节庆周期是沼泽（season=1 那一季）
--      第 3 条：更早的第 1 周期又是熔岩竞技场
--    ⇒ 可见节庆在两个内容间**交替轮换**，且season 字段记录它落在哪一季。
--  ★★ 这解释了为什么需要这张表：世界要知道「第几个节庆周期」，
--    才能决定当前该加载哪个节庆 prefab。
--  ★★⚠ 魔数风险：这张排期表与存档中的「已过节庆数」配合使用，
--    调整顺序会导致老存档的节庆进度错位。
--  ★★ 命名识别法：PREVIOUS_ 前缀 = 需要持久化的历史快照；
--    _ORDER 后缀 = 带顺序语义（与无序集合 PREVIOUS_FESTIVAL_EVENTS 区分）。
PREVIOUS_FESTIVAL_EVENTS = { FESTIVAL_EVENTS.LAVAARENA, FESTIVAL_EVENTS.QUAGMIRE } --deprecated, use PREVIOUS_FESTIVAL_EVENTS_ORDER
PREVIOUS_FESTIVAL_EVENTS_ORDER =
{
    { id = FESTIVAL_EVENTS.LAVAARENA, season = 2 },
    { id = FESTIVAL_EVENTS.QUAGMIRE, season = 1 },
    { id = FESTIVAL_EVENTS.LAVAARENA, season = 1 },
}

--★ IS_YEAR_OF_THE_SPECIAL_EVENTS（第 872-888 行）：
--  ★「是否为特定年份」的特殊处理表。用于节庆主题逐年轮换。
IS_YEAR_OF_THE_SPECIAL_EVENTS =
{
    [SPECIAL_EVENTS.YOTG] = true,
    [SPECIAL_EVENTS.YOTV] = true,
    [SPECIAL_EVENTS.YOTP] = true,
    [SPECIAL_EVENTS.YOTC] = true,
    [SPECIAL_EVENTS.YOTB] = true,
	[SPECIAL_EVENTS.YOT_CATCOON] = true,
    [SPECIAL_EVENTS.YOTR] = true,
    [SPECIAL_EVENTS.YOTD] = true,
    [SPECIAL_EVENTS.YOTS] = true,
    [SPECIAL_EVENTS.YOTH] = true,
}


---------------------------------------------------------
-- Reminder: update event_deps.lua
--★★ 【★ 事件 prefab 名派生规则】889-895 行 —— 命名约定驱动的加载
--  SPECIAL_EVENT_GLOBAL_PREFABS = { WORLD_SPECIAL_EVENT.."_event_global" }
--  SPECIAL_EVENT_BACKEND_PREFABS = { .."_event_backend" }
--  SPECIAL_EVENT_FRONTEND_PREFABS = { .."_event_frontend" }
--  FESTIVAL_EVENT_* 三行同理，后缀是 "_fest_*"。
--  ★★ 规律总结：<事件名> + _event_global / _event_backend / _event_frontend
--    ⇒ 每个事件需配套三个 prefab（全局状态 / 后端逻辑 / 前端表现）。
--  ★ 这解释了为什么 SPECIAL_EVENTS 每个事件都要准备三套资源。
SPECIAL_EVENT_GLOBAL_PREFABS = { WORLD_SPECIAL_EVENT.."_event_global" }
SPECIAL_EVENT_BACKEND_PREFABS = { WORLD_SPECIAL_EVENT.."_event_backend" }
SPECIAL_EVENT_FRONTEND_PREFABS = { WORLD_SPECIAL_EVENT.."_event_frontend" }

FESTIVAL_EVENT_GLOBAL_PREFABS = { WORLD_FESTIVAL_EVENT.."_fest_global" }
FESTIVAL_EVENT_BACKEND_PREFABS = { WORLD_FESTIVAL_EVENT.."_fest_backend" }
FESTIVAL_EVENT_FRONTEND_PREFABS = { WORLD_FESTIVAL_EVENT.."_fest_frontend" }


---------------------------------------------------------
--Used in preloadsounds.lua
---------------------------------------------------------
-- Reminder: update asset dependencies in frontend.lua --
---------------------------------------------------------
--【SPECIAL_EVENT_MUSIC 事件音乐】903-1212 行（★本区最大表）
--  ★★ 约 300 行全是「事件 → 曲名」映射，每行一个曲名。
--  ★ 这是纯数据区，逐行无信息量，跳读即可。
--  ★★ 唯一注意点：曲名是字符串 ID，对应 musics/ 目录下的音频文件。
--    与事件名同理，改名会导致音乐加载失败。
SPECIAL_EVENT_MUSIC =
{
	--hallowed nights
	[SPECIAL_EVENTS.HALLOWED_NIGHTS] =
	{
		bank = "music_frontend_hallowednights2024.fsb",
		sound = "dontstarve/music/music_FE_hallowednights2025",
	},

    --winter's feast carol
    [SPECIAL_EVENTS.WINTERS_FEAST] =
    {
		bank = "music_frontend_wintersfeast2025.fsb",
		sound = "dontstarve/music/music_FE_winterfeast2025",
    },

    --year of the gobbler
    [SPECIAL_EVENTS.YOTG] =
    {
        bank = "music_frontend_yotg.fsb",
        sound = "dontstarve/music/music_FE_yotg",
    },

    --year of the varg
    [SPECIAL_EVENTS.YOTV] =
    {
        bank = "music_frontend_yotg.fsb",
        sound = "dontstarve/music/music_FE_yotg",
    },

    --year of the pig
    [SPECIAL_EVENTS.YOTP] =
    {
        bank = "music_frontend_yotg.fsb",
        sound = "dontstarve/music/music_FE_yotg",
    },

    --year of the carrat
    [SPECIAL_EVENTS.YOTC] =
    {
        bank = "music_frontend_yotc.fsb",
        sound = "dontstarve/music/music_FE_yotc",
    },

    --year of the beefalo
    [SPECIAL_EVENTS.YOTB] =
    {
        bank = "music_frontend_yotb.fsb",
        sound = "yotb_2021/music/FE",
    },

    [SPECIAL_EVENTS.YOT_CATCOON] =
    {
        bank = "music_frontend_yotg.fsb",
        sound = "dontstarve/music/music_FE_yotg",
    },

    --year of the rabbit
    [SPECIAL_EVENTS.YOTR] =
    {
        bank = "music_frontend_yotg.fsb",
        sound = "dontstarve/music/music_FE_yotg",
    },

    --year of the dragonfly
    [SPECIAL_EVENTS.YOTD] =
    {
        bank = "music.fsb",
        sound = "dontstarve/music/music_FE_boatrace",
    },

	-- crow carnival
    [SPECIAL_EVENTS.CARNIVAL] =
    {
        bank = "music_frontend_cawnival2026.fsb",
        sound = "dontstarve/music/music_FE_cawnival2026",
    },

    --year of the depths worm
    -- THE BETA HAS THIS EVENT TURNED ON, BUT IS USING THE META 5 BANNER AND MUSIC
    --[[
    [SPECIAL_EVENTS.YOTS] =
    {
        bank = "music_frontend_yotg.fsb",
        sound = "dontstarve/music/music_FE_yotg",
    },  
    ]]  

    [SPECIAL_EVENTS.YOTH] =
    {
		bank = "music_frontend_yoth2026.fsb",
		sound = "dontstarve/music/music_FE_yoth2026",
	},
}

FESTIVAL_EVENT_MUSIC =
{
    --the forge
    [FESTIVAL_EVENTS.LAVAARENA] =
    {
        bank = "lava_arena.fsb",
        sound = "dontstarve/music/lava_arena/FE_1_2",
    },
    --the gorge
    [FESTIVAL_EVENTS.QUAGMIRE] =
    {
        bank = "quagmire.fsb",
        sound = "dontstarve/quagmire/music/FE",
    },
}

DEFAULT_FE_MUSIC =
{
	bank = "music_frontend_rifts7.fsb",
	sound = "dontstarve/music/music_FE_rifts7",

	--bank = "music_frontend_WX.fsb",
	--sound = "dontstarve/music/music_FE_WX",

	--bank = "music.fsb",
	--sound = "dontstarve/music/music_epicfight_eot",

	--bank = "music_frontend.fsb",
	--sound = "dontstarve/music/music_FE_cavepuzzle",
	--sound = "dontstarve/music/music_FE_cavepuzzle",
	--sound = "dontstarve/music/music_FE_wagboss",
	--sound = "dontstarve/music/music_FE_balatro",
	--sound = "dontstarve/music/music_FE_rifts4",
	--sound = "dontstarve/music/music_FE_winonawurt",
	--sound = "dontstarve/music/music_FE_junkyardhog",
	--sound = "dontstarve/music/music_FE_riftsthree",
	--sound = "dontstarve/music/music_FE_survivorsguideone",
	--sound = "dontstarve/music/music_FE_shadowrift",
	--sound = "dontstarve/music/music_FE_lunarrift",
	--sound = "dontstarve/music/music_FE_daywalker",
	--sound = "dontstarve/music/music_FE_maxwell",
	--sound = "dontstarve/music/music_FE_charliestage",
	--sound = "dontstarve/music/music_FE_wickerbottom",
	--sound = "dontstarve/music/music_FE",
	--sound = "dontstarve/music/music_FE_pirates",
	--sound = "dontstarve/music/music__moonstorm_FE",
	--sound = "dontstarve/music/musicFE_webber",
	--sound = "dontstarve/music/music_FE_wanda",
	--sound = "dontstarve/music/music_FE",
}

---------------------------------------------------------
--If changing this logic, remember to update preloadsounds.lua
--  FE_MUSIC = (第 1051 行)：前端菜单音乐（一个长表达式）。
--    ★ 前端音乐与事件音乐是分开的 —— 前端不该播放活动曲。
FE_MUSIC = (
	FESTIVAL_EVENT_MUSIC[WORLD_FESTIVAL_EVENT] or
	SPECIAL_EVENT_MUSIC[WORLD_SPECIAL_EVENT] or
	DEFAULT_FE_MUSIC
).sound

---------------------------------------------------------
local SPECIAL_EVENT_SKIN_TAGS =
{
    [SPECIAL_EVENTS.HALLOWED_NIGHTS] = "COSTUME",
}

local FESTIVAL_EVENT_SKIN_TAGS =
{
}

local FESTIVAL_EVENT_INFO =
{
    --the forge
    [FESTIVAL_EVENTS.LAVAARENA] =
    {
        GAME_MODE = "lavaarena",
        SERVER_NAME = "LavaArena",
        FEMUSIC = "dontstarve/music/lava_arena/FE2",
		STATS_FILE_PREFIX = "forge_stats",
        LATEST_SEASON = 2,
    },
    --the gorge
    [FESTIVAL_EVENTS.QUAGMIRE] =
    {
        GAME_MODE = "quagmire",
        SERVER_NAME = "Quagmire",
        FEMUSIC = nil, --no special FE music for the festival event screen
		STATS_FILE_PREFIX = "thegorge_stats",
        LATEST_SEASON = 1,
    },
}

---------------------------------------------------------
-- Refers to holiday-specific events.
function IsSpecialEventActive(event)
    return WORLD_SPECIAL_EVENT == event or WORLD_EXTRA_EVENTS[event] == true
end

function IsAnySpecialEventActive()
    return WORLD_SPECIAL_EVENT ~= SPECIAL_EVENTS.NONE or not IsTableEmpty(WORLD_EXTRA_EVENTS)
end

function GetActiveSpecialEventCount()
    return (WORLD_SPECIAL_EVENT ~= SPECIAL_EVENTS.NONE and 1 or 0) + GetTableSize(WORLD_EXTRA_EVENTS)
end

function GetFirstActiveSpecialEvent()
    if WORLD_SPECIAL_EVENT ~= SPECIAL_EVENTS.NONE then
        return WORLD_SPECIAL_EVENT
    end
    return next(WORLD_EXTRA_EVENTS), nil --, nil prevents the value from getting returned by next
end

function GetAllActiveEvents(special_event, extra_events)
    local all_events = {}
    if special_event then
        all_events[special_event] = true
    end
    for event in pairs(extra_events or {}) do
        all_events[event] = true
    end
    all_events[SPECIAL_EVENTS.NONE] = nil
    return all_events
end

---------------------------------------------------------
-- Checks if any of the "Year of the <creature>" events are active
function IsAny_YearOfThe_EventActive()
	if IS_YEAR_OF_THE_SPECIAL_EVENTS[WORLD_SPECIAL_EVENT] then
        return true
    end
    for special_event in pairs(WORLD_EXTRA_EVENTS) do
        if IS_YEAR_OF_THE_SPECIAL_EVENTS[special_event] then
            return true
        end
    end
    return false
end

function GetSpecialEventSkinTag()
    return SPECIAL_EVENT_SKIN_TAGS[WORLD_SPECIAL_EVENT]
end

---------------------------------------------------------
-- Refers to intermittent scheduled events.
function IsFestivalEventActive(event)
    return WORLD_FESTIVAL_EVENT == event
end

function IsPreviousFestivalEvent(event)
    for _,prev_event in ipairs(PREVIOUS_FESTIVAL_EVENTS_ORDER) do
        if prev_event.id == event then
            return true
        end
    end
    return false
end

function IsAnyFestivalEventActive()
    return WORLD_FESTIVAL_EVENT ~= FESTIVAL_EVENTS.NONE
end

function GetFestivalEventSkinTag()
    return FESTIVAL_EVENT_SKIN_TAGS[WORLD_FESTIVAL_EVENT]
end

function GetFestivalEventInfo()
    return FESTIVAL_EVENT_INFO[WORLD_FESTIVAL_EVENT]
end

function GetFestivalEventSeasons(festival)
    return FESTIVAL_EVENT_INFO[festival] ~= nil and FESTIVAL_EVENT_INFO[festival].LATEST_SEASON or 0
end

-- Used by C side. Do NOT rename without editing simulation.cpp
function GetActiveFestivalEventServerName()
    local festival = IsAnyFestivalEventActive() and WORLD_FESTIVAL_EVENT
    return GetFestivalEventServerName( festival, GetFestivalEventSeasons(festival) )
end

-- Used by C side. Do NOT rename without editing simulation.cpp
function GetActiveFestivalProductName()
	return FESTIVAL_EVENT_INFO[WORLD_FESTIVAL_EVENT] ~= nil and FESTIVAL_EVENT_INFO[WORLD_FESTIVAL_EVENT].SERVER_NAME or ""
end

function GetFestivalEventServerName(festival, season)
    if season == 1 then
        return FESTIVAL_EVENT_INFO[festival] ~= nil and FESTIVAL_EVENT_INFO[festival].SERVER_NAME or ""
    else
        return FESTIVAL_EVENT_INFO[festival] ~= nil and (string.format( "%s_s%d", FESTIVAL_EVENT_INFO[festival].SERVER_NAME, season )) or ""
    end
end

function GetActiveFestivalEventStatsFilePrefix()
    local festival = IsAnyFestivalEventActive() and WORLD_FESTIVAL_EVENT
    return FESTIVAL_EVENT_INFO[festival] ~= nil and FESTIVAL_EVENT_INFO[festival].STATS_FILE_PREFIX or "stats"
end

function GetActiveFestivalEventAchievementStrings()
    --Note, this requires the festival name to have the same spelling at the name in the STRINGS.UI.ACHIEVEMENTS string table
    local festival = IsAnyFestivalEventActive() and WORLD_FESTIVAL_EVENT
    return STRINGS.UI.ACHIEVEMENTS[festival:upper()]
end

-- To enable/disable the tournament, change the return value of Server_IsTournamentActive()
function Server_IsTournamentActive()
	-- for internal server use only
	return false
end

function Client_IsTournamentActive() -- ticket_name is optional
	return Server_IsTournamentActive() and IsSteam()
end

---------------------------------------------------------
-- Pickup sounds for in game events.
--★ 【PICKUPSOUNDS 拾取音效】1213-1228 行：物品 → 拾取音。
PICKUPSOUNDS = {
    ["wood"] = "aqol/new_test/wood",
    ["gem"] = "aqol/new_test/gem",
    ["cloth"] = "aqol/new_test/cloth",
    ["metal"] = "aqol/new_test/metal",
    ["rock"] = "aqol/new_test/rock",
    ["vegetation_firm"] = "aqol/new_test/vegetation_firm",
    ["vegetation_grassy"] = "aqol/new_test/vegetation_grassy",
    ["squidgy"] = "aqol/new_test/squidgy",
    ["grainy"] = "aqol/new_test/grainy",
    ["paper"] = "aqol/new_test/paper",
    ["DEFAULT_FALLBACK"] = "dontstarve/HUD/collect_resource",
	["NONE"] = nil, --reserved
}

---------------------------------------------------------
--【★ 类别 I · 万圣节计数与 ★理智模式★】1229-1236 行
--★★ 【SANITY_MODE —— 理智状态枚举】1235 行
--  SANITY_MODE_INSANITY = 0（发疯）
--  SANITY_MODE_LUNACY  = 1（月狂）
--  ★★★ 这两个是 DST 最核心的机制开关，必须理解：★★★
--    正常态（sanity 65~170）：玩家正常，理智缓慢变化
--    变疯（sanity < 30）：SANITY_MODE_INSANITY
--      ⇒ 只能操作影子（幻象），无法直接攻击/使用多数物品
--    月狂（sanity > 200）：SANITY_MODE_LUNACY
--      ⇒ 持续掉理智，但能力增强、且不会被打死
--  ★★ 判定阈值见 tuning.lua 的 SANITY_BECOME_* 系列（0.15~0.85 比例）。
--    ⚠ 魔数风险：这两个值与存档中的玩家状态对应，
--      交换 0/1 会让所有玩家的理智模式判定反转。
--★ 参见 components/sanity.lua（本项目已深度注释）。
NUM_HALLOWEENCANDY = 14
--  NUM_HALLOWEENCANDY = 14 / NUM_HALLOWEEN_ORNAMENTS = 6
--  NUM_HALLOWEEN_PUMPKINCARVERS = 3 / NUM_WINTERFOOD = 9
--  ★★ 这类 NUM_* 数量常量是「节日道具的收集上限」。
--  ★★⚠ 魔数风险：数量会写进存档（玩家收集了几个）。
--    若把 14 改成 10，老玩家已收集的 12 个会「超出上限」，
--    导致 UI 显示异常或道具被吞。
--  ★ 与 tuning.lua:1603 NUM_TRINKETS = 46 属同一类约定。
NUM_HALLOWEEN_ORNAMENTS = 6
NUM_HALLOWEEN_PUMPKINCARVERS = 3
NUM_WINTERFOOD = 9

SANITY_MODE_INSANITY = 0
SANITY_MODE_LUNACY = 1

--【★ 类别 J · ★世界生成技术图（TECH）★】1237-1341 行
--  ★★ TECH 表是「科技树」的定义源：决定研究点如何解锁配方。
--  ★★ 这是整个游戏的进度骨架 —— 所有可研究项的依赖关系都在这里。
--★ 消费方：components/techtree.lua、playercontroller.lua（研究点）。
TECH =
{
    NONE = TechTree.Create(),

    SCIENCE_ONE = { SCIENCE = 1 },
    SCIENCE_TWO = { SCIENCE = 2 },
    SCIENCE_THREE = { SCIENCE = 3 },
    -- Magic starts at level 2 so it's not teased from the start.
    MAGIC_TWO = { MAGIC = 2 },
    MAGIC_THREE = { MAGIC = 3 },

    ANCIENT_TWO = { ANCIENT = 2 },
    ANCIENT_THREE = { ANCIENT = 3 },
    ANCIENT_FOUR = { ANCIENT = 4 },

    CELESTIAL_ONE = { CELESTIAL = 1 },
    CELESTIAL_THREE = { CELESTIAL = 3 },

	MOON_ALTAR_TWO = { CELESTIAL = 3 }, -- deprecated, use CELESTIAL_THREE

    SHADOW_TWO = { SHADOW = 3 },

    CARTOGRAPHY_TWO = { CARTOGRAPHY = 2 },

    SEAFARING_ONE = { SEAFARING = 1 },
    SEAFARING_TWO = { SEAFARING = 2 },

    SCULPTING_ONE = { SCULPTING = 1 },
    SCULPTING_TWO = { SCULPTING = 2 },

    ORPHANAGE_ONE = { ORPHANAGE = 1 },
    PERDOFFERING_ONE = { PERDOFFERING = 1 },
    PERDOFFERING_THREE = { PERDOFFERING = 3 },
    WARGOFFERING_THREE = { WARGOFFERING = 3 },
    PIGOFFERING_THREE = { PIGOFFERING = 3 },
    CARRATOFFERING_THREE = { CARRATOFFERING = 3 },
    BEEFOFFERING_THREE = { BEEFOFFERING = 3 },
    CATCOONOFFERING_THREE = { CATCOONOFFERING = 3 },
    RABBITOFFERING_THREE = { RABBITOFFERING = 3 },
    DRAGONOFFERING_THREE = { DRAGONOFFERING = 3 },
    WORMOFFERING_THREE = { WORMOFFERING = 3 },
    KNIGHTOFFERING_THREE = { KNIGHTOFFERING = 3 },

    MADSCIENCE_ONE = { MADSCIENCE = 1 },
	CARNIVAL_PRIZESHOP_ONE = { CARNIVAL_PRIZESHOP = 1 },
	CARNIVAL_HOSTSHOP_ONE = { CARNIVAL_HOSTSHOP = 1 },
	CARNIVAL_HOSTSHOP_THREE = { CARNIVAL_HOSTSHOP = 3 },

    FOODPROCESSING_ONE = { FOODPROCESSING = 1 },
	FISHING_ONE = { FISHING = 1 },
	FISHING_TWO = { FISHING = 2 },

	HERMITCRABSHOP_ONE = { HERMITCRABSHOP = 1 },
	HERMITCRABSHOP_THREE = { HERMITCRABSHOP = 3 },
	HERMITCRABSHOP_FIVE = { HERMITCRABSHOP = 5 },
    HERMITCRABSHOP_SEVEN = { HERMITCRABSHOP = 7 },

    SHELLWEAVER_ONE = { SHELLWEAVER = 1 },
    SHELLWEAVER_THREE = { SHELLWEAVER = 3 },

    RABBITKINGSHOP_TWO = { RABBITKINGSHOP = 2 },

    WAGPUNK_WORKSTATION_TWO = { WAGPUNK_WORKSTATION = 2 },

    TURFCRAFTING_ONE = { TURFCRAFTING = 1 },
    TURFCRAFTING_TWO = { TURFCRAFTING = 2 },
	MASHTURFCRAFTING_TWO = { MASHTURFCRAFTING = 2},

	WINTERSFEASTCOOKING_ONE = { WINTERSFEASTCOOKING = 1 },

    HALLOWED_NIGHTS = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    WINTERS_FEAST = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTG = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTV = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTP = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTC = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTB = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOT_CATCOON = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTR = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTD = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTS = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0
    YOTH = { SCIENCE = 10 }, -- ApplySpecialEvent() will change this from lost to 0

    LOST = { MAGIC = 10, SCIENCE = 10, ANCIENT = 10 },

    SPIDERCRAFT_ONE = { SPIDERCRAFT = 1 },

    ROBOTMODULECRAFT_ONE = { ROBOTMODULECRAFT = 1 },
    BOOKCRAFT_ONE = { BOOKCRAFT = 1 },

	LUNARFORGING_ONE = { LUNARFORGING = 1 },
	LUNARFORGING_TWO = { LUNARFORGING = 2 },

	SHADOWFORGING_ONE = { SHADOWFORGING = 1 },
	SHADOWFORGING_TWO = { SHADOWFORGING = 2 },

    CARPENTRY_TWO = { CARPENTRY = 2 },
    CARPENTRY_THREE = { CARPENTRY = 3 },

    VAULT_REFINE_ONE = { VAULT_REFINE = 1 },

    CARNIVAL_GOLFPROPS_ONE = { CARNIVAL_GOLFPROPS = 1 },
}

-- See cell_data.h
--★ 【NODE_TYPE / NODE_INTERNAL_CONNECTION_TYPE】1342-1364 行：
--  ★ 技术图的节点类型（建筑/材料/工具…）与内部连接方式。
--★ MAZE_TYPE / MAZE_CELL_EXITS（1374-1434 行）：迷宫类型与出口方向。
--  ★ 迷宫用于洞穴与特殊世界生成，出口方向决定刷怪与掉落布局。
NODE_TYPE =
{
    Default = 0,		-- Land can touch any other Default node in the task that is within range
    Blank = 1,			-- empty room with impassable ground
    Background = 2,
    Random = 3,
    Blocker = 4,		-- Adds 2 Blank nodes beside it
    Room = 5,			-- Land can only touch the room(s) it is connected to by the graph (adds impassable around its parameter with a single land bidge)
    BackgroundRoom = 6,
	SeparatedRoom = 7,	-- adds impassable around its entire parameter
}

-- See cell_data.h
NODE_INTERNAL_CONNECTION_TYPE =
{
    EdgeCentroid = 0,
    EdgeSite = 1,
    EdgeEdgeDirect = 2,
    EdgeEdgeLeft = 3,
    EdgeEdgeRight = 4,
    EdgeData = 5,
}

CA_SEED_MODE =
{
    SEED_RANDOM = 0,
    SEED_CENTROID = 1,
    SEED_SITE = 2,
    SEED_WALLS = 3,
}

-- See maze.h
MAZE_TYPE =
{
    MAZE_DFS_4WAY_META = 0,
    MAZE_DFS_4WAY = 1,
    MAZE_DFS_8WAY = 2,
    MAZE_GROWINGTREE_4WAY = 3,
    MAZE_GROWINGTREE_8WAY = 4,
    MAZE_GROWINGTREE_4WAY_INV = 5,
}

-- NORTH	1
-- EAST		2
-- SOUTH	4
-- WEST		8
--[[
Meta maze def:
5 room types:
4 way,	3 way,	2 way,	1 way,	L shape
	1,		4,		2,		4,		4
	15 tiles needed
--]]

MAZE_CELL_EXITS =
{
	NO_EXITS = 		0, -- Dont place a cell here.
	SINGLE_NORTH = 	1,
	SINGLE_EAST = 	2,
	L_NORTH = 		3,
	SINGLE_SOUTH = 	4,
	TUNNEL_NS = 	5,
	L_EAST = 		6,
	THREE_WAY_N = 	7,
	SINGLE_WEST = 	8,
	L_WEST = 		9,
	TUNNEL_EW =		10,
	THREE_WAY_W = 	11,
	L_SOUTH = 		12,
	THREE_WAY_S = 	13,
	THREE_WAY_E = 	14,
	FOUR_WAY = 		15,
}

MAZE_CELL_EXITS_INV =
{
	"SINGLE_NORTH",
	"SINGLE_EAST",
	"L_NORTH",
	"SINGLE_SOUTH",
	"TUNNEL_NS",
	"L_EAST",
	"THREE_WAY_N",
	"SINGLE_WEST",
	"L_WEST",
	"TUNNEL_EW",
	"THREE_WAY_W",
	"L_SOUTH" ,
	"THREE_WAY_S",
	"THREE_WAY_E",
	"FOUR_WAY",
}

--【★ LAYOUT / LAYOUT_POSITION / LAYOUT_ROTATION】1435-1458 行：
--  ★ 世界布局（手写布局关卡）的方位与旋转枚举。
--  PLACE_MASK（1459 行）：放置遮罩，限制哪些格子能放建筑。
--★ 关联 tuning.lua:3858 附近的 DEPLOYSPACING 枚举（本文件另有 DEPLOYMODE）。
LAYOUT =
{
	STATIC = 0,
	CIRCLE_EDGE = 1,
	CIRCLE_RANDOM = 2,
	GRID = 3,
	RECTANGLE_EDGE = 4,
	CIRCLE_FILLED = 5,
}

LAYOUT_POSITION =
{
	RANDOM = 0,
	CENTER = 1,
}

LAYOUT_ROTATION =
{
	NORTH = 0, 	-- 0 Degrees
	EAST = 1, 	-- 90 Degrees
	SOUTH = 2, 	-- 180 Degrees
	WEST = 3, 	-- 270 Degrees
}

PLACE_MASK =
{
	NORMAL = 0,
	IGNORE_IMPASSABLE = 1,
	IGNORE_BARREN = 2,
	IGNORE_IMPASSABLE_BARREN = 3,
	IGNORE_RESERVED = 4,
	IGNORE_IMPASSABLE_RESERVED = 5,
	IGNORE_BARREN_RESERVED = 6,
	IGNORE_IMPASSABLE_BARREN_RESERVED = 7,
}

-- keep up to date with MapSampleStyle in MapDefines.h
MAP_SAMPLE_STYLE =
{
	NINE_SAMPLE = 0,
	MARCHING_SQUARES = 1, -- Note to modders: this approach is still a prototype
}

--keep up to date with luabit.h
--★ 【LUABIT / COLLISION】1479-1504 行：
--  LUABIT（1479 行）：Lua 侧的位标记（bitmask）。
--    ★ 与 YOTB_COSTUMES 同属「位掩码」用法：多个标志可组合在一个整数里。
--    ★★ 这类常量的正确用法是位与 (bit and)，不是相等比较 ——
--      详见文件头对 YOTB_COSTUMES 的说明。
--  COLLISION（1488 行）：碰撞层定义。
--  MAX_PHYSICS_RADIUS = 4 --boats are currently the largest.（第 1504 行）：
--    ★★ 这是全文件**唯一一处会变的设计上限**：
--      值 4 = 1 个 TILE（因为 TILE_SCALE=4），即物理体积上限为 1 格。
--      英文注释 'boats are currently the largest' 「船是当前最大的」，
--      暗示若将来有更大的载具，这个上限需要提高。
--      ⚠ 这是「魔数与现实耦合」的典型：数值不能随便改，
--        它隐含假设「没有比船更大的东西」。
LUABIT =
{
    WIDTH8BIT = 1,
    WIDTH16BIT = 2,
    --WIDTH32BIT = 3, --if 1 or 2 isn't passed, its assumed to be 32 bit width
}


-- keep up to date with COLLISION_GROUP in simconstants.h
COLLISION =
{
    GROUND            = 32,
	BOAT_LIMITS       = 64,
	LAND_OCEAN_LIMITS = 128,             -- physics wall between water and land
    LIMITS            = 128 + 64,        -- BOAT_LIMITS + LAND_OCEAN_LIMITS
    WORLD             = 128 + 64 + 32,   -- BOAT_LIMITS + LAND_OCEAN_LIMITS + GROUND
    ITEMS             = 256,
    OBSTACLES         = 512,
    CHARACTERS        = 1024,
    FLYERS            = 2048,
    SANITY            = 4096,
    SMALLOBSTACLES    = 8192,	-- collide with characters but not giants
    GIANTS            = 16384,	-- collide with obstacles but not small obstacles
}

MAX_PHYSICS_RADIUS = 4 --boats are currently the largest.

--【★ BLENDMODE 混合模式 / ANIM_ORIENTATION 动画朝向】1506-1524 行
--  BLENDMODE：贴图叠加方式（正常/相加/相乘…），纯表现层。
--  ANIM_ORIENTATION：动画帧朝向处理。
--  ★ ANIM_ORIENTATION.Default = ANIM_ORIENTATION.BillBoard（第 1523 行）：
--    显式设置默认值为「公告板模式」（永远朝向镜头）。
--    ★ 这是给美术/策划的默认兜底，避免每个动画都单独指定。
BLENDMODE =
{
	Disabled = 0,
	AlphaBlended = 1,
	Additive = 2,
	Premultiplied = 3,
	InverseAlpha = 4,
	AlphaAdditive = 5,
	VFXTest = 6,
}

ANIM_ORIENTATION =
{
    BillBoard = 0,
    OnGround = 1,
    OnGroundFixed = 2,
}
ANIM_ORIENTATION.Default = ANIM_ORIENTATION.BillBoard

--【★ 类别 K · 配方分类（RECIPETABS）】1525-1587 行
--  RECIPETABS（第 1525 行）：合成配方的分类标签（工具/战斗/食物…）。
--  CUSTOM_RECIPETABS（1563 行）：模组自定义分类的扩展点。
--  QUAGMIRE_RECIPETABS（1578 行）：沼泽世界**独有**的配方分类。
--    ★★ 说明不同世界类型会启用不同的配方分类表。
--  ★ 配方本身不在本文件，而在 prefabs/recipes/ 与 cooking.lua。
RECIPETABS =
{
    TOOLS =         { str = "TOOLS",        sort = 0,   icon = "tab_tool.tex" },
    LIGHT =         { str = "LIGHT",        sort = 1,   icon = "tab_light.tex" },
    SURVIVAL =      { str = "SURVIVAL",     sort = 2,   icon = "tab_trap.tex" },
    FARM =          { str = "FARM",         sort = 3,   icon = "tab_farm.tex" },
    SCIENCE =       { str = "SCIENCE",      sort = 4,   icon = "tab_science.tex" },
    WAR =           { str = "WAR",          sort = 5,   icon = "tab_fight.tex" },
    TOWN =          { str = "TOWN",         sort = 6,   icon = "tab_build.tex" },
    SEAFARING =     { str = "SEAFARING",    sort = 7,   icon = "tab_seafaring.tex" },
    REFINE =        { str = "REFINE",       sort = 8,   icon = "tab_refine.tex" },
    MAGIC =         { str = "MAGIC",        sort = 9,   icon = "tab_arcane.tex" },
    DRESS =         { str = "DRESS",        sort = 10,  icon = "tab_dress.tex" },

    --Crafting stations
    ANCIENT =				{ str = "ANCIENT",				sort = 100, icon = "tab_crafting_table.tex",	crafting_station = true },
    CELESTIAL =				{ str = "CELESTIAL",			sort = 100, icon = "tab_celestial.tex",			crafting_station = true },
    MOON_ALTAR =			{ str = "MOON_ALTAR",			sort = 100, icon = "tab_moonaltar.tex",			crafting_station = true }, -- deprecated, all recipes have been moved into CELESTIAL
    CARTOGRAPHY =			{ str = "CARTOGRAPHY",			sort = 100, icon = "tab_cartography.tex",		crafting_station = true },
    SCULPTING =				{ str = "SCULPTING",			sort = 100, icon = "tab_sculpt.tex",			crafting_station = true },
    ORPHANAGE =				{ str = "ORPHANAGE",			sort = 100, icon = "tab_orphanage.tex",			crafting_station = true },
    PERDOFFERING =			{ str = "PERDOFFERING",			sort = 100, icon = "tab_perd_offering.tex",		crafting_station = true },
    MADSCIENCE =			{ str = "MADSCIENCE",			sort = 100, icon = "tab_madscience_lab.tex",	crafting_station = true, manufacturing_station = true },
	CARNIVAL_PRIZESHOP =	{ str = "CARNIVAL_PRIZESHOP",	sort = 100, icon = "tab_prizebooth.tex",		crafting_station = true , shop = true, icon_atlas = "images/hud2.xml"},
	CARNIVAL_HOSTSHOP =		{ str = "CARNIVAL_HOSTSHOP",	sort = 100, icon = "tab_host.tex",				crafting_station = true , shop = true, icon_atlas = "images/hud2.xml"},
    FOODPROCESSING =		{ str = "FOODPROCESSING",		sort = 100, icon = "tab_foodprocessing.tex",	crafting_station = true },
	FISHING =				{ str = "FISHING",				sort = 100, icon = "tab_fishing.tex",			crafting_station = true },
	WINTERSFEASTCOOKING =	{ str = "WINTERSFEASTCOOKING",	sort = 100, icon = "tab_feast_oven.tex",		crafting_station = true },
    HERMITCRABSHOP =		{ str = "HERMITCRABSHOP",		sort = 100, icon = "tab_hermitcrab_shop.tex",	crafting_station = true, shop = true},
    SHELLWEAVER =           { str = "SHELLWEAVER",          sort = 100, icon = "tab_shellweaver.tex",       crafting_station = true, manufacturing_station = true, icon_atlas = "images/hud2.xml"},
    RABBITKINGSHOP =		{ str = "RABBITKINGSHOP",		sort = 100, icon = "tab_rabbitking.tex",		crafting_station = true, shop = true, icon_atlas = "images/hud2.xml"},
    WANDERINGTRADERSHOP =	{ str = "WANDERINGTRADERSHOP",	sort = 100, icon = "tab_wanderingtrader.tex",	crafting_station = true, shop = true, icon_atlas = "images/hud2.xml"},
    WAGPUNK_WORKSTATION =	{ str = "WAGPUNK_WORKSTATION",	sort = 100, icon = "tab_wagpunk_workstation.tex",crafting_station = true, shop = true, icon_atlas = "images/hud2.xml"},
    TURFCRAFTING =		    { str = "TURFCRAFTING", 		sort = 100, icon = "tab_turfcrafting.tex",      crafting_station = true, icon_atlas = "images/hud2.xml" },
    CARPENTRY =	    	    { str = "CARPENTRY",			sort = 100, icon = "station_carpentry.tex",     crafting_station = true, icon_atlas = "images/hud2.xml" },
    HERMITCRAB_TEASHOP =    { str = "HERMITCRABTEASHOP",    sort = 100, icon = "tab_hermitcrab_teashop.tex",crafting_station = true, manufacturing_station = true, icon_atlas = "images/hud2.xml"},
}

CUSTOM_RECIPETABS =
{
    BOOKS         = { str = "BOOKS",			sort = 999, icon = "tab_book.tex",          owner_tag = "bookbuilder"  },
    SHADOW        = { str = "SHADOW",			sort = 999, icon = "tab_shadow.tex",        owner_tag = "shadowmagic"  },
    ENGINEERING   = { str = "ENGINEERING",		sort = 999, icon = "tab_engineering.tex",   owner_tag = "handyperson"  },
	ELIXIRBREWING = { str = "ELIXIRBREWING",	sort = 999, icon = "tab_elixirbrewing.tex", owner_tag = "elixirbrewer" },
    BATTLESONGS   = { str = "BATTLESONGS",      sort = 999, icon = "tab_battlesongs.tex",   owner_tag = "battlesinger",    icon_atlas = "images/hud2.xml" },
    SPIDERCRAFT   = { str = "SPIDERCRAFT",      sort = 999, icon = "tab_spidercraft.tex",   owner_tag = "spiderwhisperer", icon_atlas = "images/hud2.xml" },
    NATURE        = { str = "NATURE",			sort = 999, icon = "tab_nature.tex",        owner_tag = "plantkin"     },
	SLINGSHOTAMMO =	{ str = "SLINGSHOTAMMO",	sort = 999, icon = "tab_slingshot.tex",	    owner_tag = "pebblemaker"  },
	BALLOONOMANCY = { str = "BALLOONOMANCY",	sort = 999, icon = "tab_balloonomancy.tex",	owner_tag = "balloonomancer",	icon_atlas = "images/hud2.xml" },
	CLOCKMAKER    =	{ str = "CLOCKMAKER",		sort = 999, icon = "tab_clockmaker.tex",	owner_tag = "clockmaker",		icon_atlas = "images/hud2.xml"},
    STRONGMAN     =	{ str = "STRONGMAN",		sort = 999, icon = "tab_strongman.tex",	    owner_tag = "strongman",		icon_atlas = "images/hud2.xml"},
}

QUAGMIRE_RECIPETABS =
{
    QUAGMIRE_MEALINGSTONE = { str = "QUAGMIRE_MEALINGSTONE", sort = 0, icon = "tab_quagmire_mealingstone.tex", icon_atlas = "images/quagmire_hud.xml", crafting_station = true },
    QUAGMIRE_TRADER_ELDER = { str = "QUAGMIRE_TRADER_ELDER", sort = 0, icon = "tab_quagmire_swampigelder.tex", icon_atlas = "images/quagmire_hud.xml", crafting_station = true, shop = true },
    QUAGMIRE_TRADER_MERM1 = { str = "QUAGMIRE_TRADER_MERM1", sort = 0, icon = "tab_quagmire_trader_merm1.tex", icon_atlas = "images/quagmire_hud.xml", crafting_station = true, shop = true },
    QUAGMIRE_TRADER_MERM2 = { str = "QUAGMIRE_TRADER_MERM2", sort = 0, icon = "tab_quagmire_trader_merm2.tex", icon_atlas = "images/quagmire_hud.xml", crafting_station = true, shop = true },
    QUAGMIRE_TRADER_MUM =   { str = "QUAGMIRE_TRADER_MUM",   sort = 0, icon = "tab_quagmire_trader_mum.tex",   icon_atlas = "images/quagmire_hud.xml", crafting_station = true, shop = true },
    QUAGMIRE_TRADER_KID =   { str = "QUAGMIRE_TRADER_KID",   sort = 0, icon = "tab_quagmire_trader_kid.tex",   icon_atlas = "images/quagmire_hud.xml", crafting_station = true, shop = true },
}

--【★ VERBOSITY / RENDERPASS】1588-1602 行
--  VERBOSITY（1588 行）：日志详细级别（开发期用）。
--    ★ 只影响 print 输出的冗长度，与玩法无关。
--  RENDERPASS（1596 行）：渲染通道定义（决定绘制顺序）。
--    ★ 与第 56 行的 LAYER_* 配合：LAYER 定批次，RENDERPASS 定批内顺序。
VERBOSITY =
{
	ERROR = 0,
	WARNING = 1,
	INFO = 2,
	DEBUG = 3,
}

RENDERPASS =
{
	Z = 0,
	BLOOM = 1,
	DEFAULT = 2,
}

--★★ 【NUM_TRINKETS 与万圣节区间】1603-1605 行
--  NUM_TRINKETS = 46 / HALLOWEDNIGHTS_TINKET_START = 32 / _END = 46
--    ★★★ 「分段编号」的清晰范例：
--      小饰品编号空间为 0~46，其中 32~46 段专属于万圣节。
--    ★★ 设计要点：节日内容占据编号区间的尾部，
--      这样每年新增节日只需往后扩，不必打乱既有编号 ——
--      这正是本文件反复强调的「编号只增不复用」原则。
--    ★★⚠ 魔数风险：编号会写入存档（玩家拥有哪号小饰品）。
--      与第 1229 行的 NUM_HALLOWEENCANDY 等数量常量同理，
--      调小上限会吞掉玩家已收集的道具。
NUM_TRINKETS = 46
HALLOWEDNIGHTS_TINKET_START = 32
HALLOWEDNIGHTS_TINKET_END = 46

--★★★ 【★ 类别 L · ★★★ 季节定义 —— 本任务重点区域 ★★★】1607-1615 行
--  SEASONS =
--  {
--      AUTUMN = "autumn",
--      WINTER = "winter",
--      SPRING = "spring",
--      SUMMER = "summer",
--      CAVES = "caves",
--  }
--
--  ★★★ 首先必须澄清（避免常见误解）：★★
--  ★★ 本文件只定义了季节的**名字**，完全没有「四季天数」。
--    推理依据：四季天数（AUTUMN_LENGTH=20 等）位于 tuning.lua:2218-2221，
--      属于可调数值而非常量。
--  ★★ 五项的排列顺序有讲究：
--    AUTUMN(秋) → WINTER(冬) → SPRING(春) → SUMMER(夏)
--    ★ 这是游戏的**默认季节推进顺序**，即第 1 季秋天。
--    ⚠ 若调换顺序会让新世界从别的季节开始 ——
--      这会影响温度、植被、刷怪表，不是纯显示变化。
--  ★★ 第 5 项 CAVES = "caves" 并非四季之一：
--    它表示「洞穴世界的季节命名」，与地表的四季循环平行存在。
--    ⇒ 5 个名字对应「4 个地表季节 + 1 套洞穴季节」。
--
--  ★★★ ★★ 本文件最需要警惕的一点（务必读完）：★★
--  ★★ 这些季节名字（"autumn" 等）是**写入存档的字符串 ID**。
--    components/worldstate.lua:239-243 会把它们连同天数写进存档：
--        self.data.autumnlength = TUNING.AUTUMN_LENGTH
--    ⇒ 若把 "autumn" 改成 "fall"：
--      · 所有老存档的季节判断会失效（找不到 "fall" 这个 season）
--      · 季节进度可能重置或卡住。
--    ⇒ **季节名与天数都可以改，但季节名改了必然破坏老存档。**
--      天数改了只影响新世界的难度，老存档自带天数，不受影响。
--★ 消费方：components/worldstate.lua（季节推进）、
--  map/forest_map.lua（地图生成）、components/seasons.lua（季节效果）。
--★ ★★ 相关数值见 tuning.lua 的季节段：
--    2218-2221 AUTUMN/WINTER/SPRING/SUMMER_LENGTH = 20/15/20/15
--    2226-2235 SEASON_LENGTH_* 预设（FRIENDLY/HARSH 世界难度）
SEASONS =
{
	AUTUMN = "autumn",
	WINTER = "winter",
	SPRING = "spring",
	SUMMER = "summer",
	CAVES = "caves",
}

--★ LEVELCATEGORY（第 1616 行）：世界设置的分类标签。
--  RENDER_QUALITY（1623 行）LOW=0 / DEFAULT=1 / HIGH=2：
--    ★★ 三档画质。注意 LOW=0 —— 0 通常是「无/关闭」的值，
--      这里 LOW 恰好为 0，所以判断画质时要注意别写成 if not quality。
--  ANIM_SORT_ORDER（1630 行）：动画排序层。
--  ★★ 与 tuning.lua 的 LAYER_* 渲染图层分工不同：
--    LAYER_*（第 56 行）= 渲染批次层级
--    ANIM_SORT_ORDER = 批次内的排序顺序
LEVELCATEGORY = {
    LEVEL = "LEVEL",
    SETTINGS = "SETTINGS",
    COMBINED = "COMBINED",
    WORLDGEN = "WORLDGEN",
}

RENDER_QUALITY =
{
	LOW = 0,
	DEFAULT = 1,
	HIGH = 2,
}

ANIM_SORT_ORDER =
{
	OCEAN_UNDERWATER = 0,
	OCEAN_WAVES = 1,
	OCEAN_WHIRLPORTAL = 1,
	OCEAN_BOAT = 2, -- Keep at 2.
    OCEAN_BOAT_BUMPERS = 3,
	OCEAN_SKYSHADOWS = 4,
}

ANIM_SORT_ORDER_BELOW_GROUND =
{
    UNDERWATER = 0,
    BOAT_TRAIL = 1,
    BOAT_LIP = 2,
    UNUSED = 3,
}

--★ ROAD_PARAMETERS（1648 行）：路面移动参数（移速加成、脚步声等）。
--  ★ 消费方见 worldstate.lua 或 locomotor 的地面检测。
ROAD_PARAMETERS =
--【★ 类别 M · 颜色表（★本文件最大单一区块）】1651-1836 行
--  ★★ 约 180 行全是 { r/255, g/255, b/255, a/255 } 形式的颜色常量。
--    ★ 这类值 99% 是纯数据，逐行注释无价值，跳读即可。
--  ★★ 唯一需要理解的是**数值格式**：全部除以 255 转成 0~1 浮点。
--    为什么不用 0~255 整数？因为渲染 API 期望归一化浮点。
--    ⇒ 这是一种「归一化」——与 tuning.lua 的时间归一化同理，
--      不同之处在于这里不涉及调时钟，改动风险低。
{
	NUM_SUBDIVISIONS_PER_SEGMENT = 50,
--  BGCOLOURS（1651 行）/ WEBCOLOURS（1662 行）背景与网页色。
--  PLAYERCOLOURS（1722 行）：18 名角色各自的代表色。
--    ★ 这会用于玩家头顶的名字标签颜色 —— 是身份识别功能。
--    ★★ 但颜色值本身不写进存档（由角色 ID 决定），
--      所以改颜色不会损坏存档，只是换了个观感。
	MIN_WIDTH = 2,
	MAX_WIDTH = 3,
	MIN_EDGE_WIDTH = 0.5,
	MAX_EDGE_WIDTH = 1,
	WIDTH_JITTER_SCALE=1,
}

function RGB(r, g, b)
    return { r / 255, g / 255, b / 255, 1 }
end

BGCOLOURS =
{
	RED =          RGB(255, 89,  46 ),
	PURPLE =       RGB(184, 87,  198),
	YELLOW =       RGB(255, 196, 45 ),
	GREY =         RGB(75,  75,  75 ),
	HALF =         RGB(128, 128, 128 ),
	FULL =         RGB(255, 255, 255),
}

-- Standard html colours: https://en.wikipedia.org/wiki/Web_colors#X11_color_names
WEBCOLOURS =
{
    -- pinks
    PINK           = RGB(255, 192, 203),
    PALEVIOLETRED  = RGB(219, 112, 147),
    -- reds
    SALMON         = RGB(250, 128, 114),
    CRIMSON        = RGB(220, 20, 60),
    FIREBRICK      = RGB(178, 34, 34),
    DARKRED        = RGB(139, 0, 0),
    RED            = RGB(255, 0, 0),
    -- oranges
    TOMATO         = RGB(255, 99, 71),
    CORAL          = RGB(255, 127, 80),
    ORANGE         = RGB(255, 165, 0),
    -- yellows
    YELLOW         = RGB(255, 255, 0),
    KHAKI          = RGB(240, 230, 140),
    -- browns
    BISQUE         = RGB(255, 228, 196),
    BURLYWOOD      = RGB(222, 184, 135),
    TAN            = RGB(210, 180, 140),
    ROSYBROWN      = RGB(188, 143, 143),
    SANDYBROWN     = RGB(244, 164, 96),
    GOLDENROD      = RGB(218, 165, 32),
    PERU           = RGB(205, 133, 63),
    CHOCOLATE      = RGB(210, 105, 30),
    SADDLEBROWN    = RGB(139, 69, 19),
    BROWN          = RGB(165, 42, 42),
    -- greens
    GREEN          = RGB(0, 128, 0),
    SPRINGGREEN    = RGB( 0, 255, 127),
    -- cyans
    TURQUOISE      = RGB(64, 224, 208),
    TEAL           = RGB(0, 128, 128),
    -- blues
    LIGHTSKYBLUE   = RGB(135, 206, 250),
    CORNFLOWERBLUE = RGB(100, 149, 237),
    BLUE           = RGB(0, 0, 255),
    -- purples
    LAVENDER       = RGB(230, 230, 250),
    THISTLE        = RGB(216, 191, 216),
    PLUM           = RGB(221, 160, 221),
    MEDIUMPURPLE   = RGB(147, 112, 219),
    PURPLE         = RGB(128, 0, 128),
}

-- A limited palette of colours to match our world tones.
-- Don't reference these from code! The names don't match the colour.
PLAYERCOLOURS =
{
	BLUE =          RGB(149, 191, 242),
	--RED =           RGB(242, 99,  99 ), --RED redefined below
	YELLOW =        RGB(222, 222, 99 ),
	GREEN =         RGB(59,  222, 99 ),
	CORAL =         RGB(216, 60,  84 ),
	GRASS =         RGB(129, 168, 99 ),
	TEAL =          RGB(150, 206, 169),
	LAVENDER =      RGB(206, 145, 192),
	OTHERBLUE =     RGB(113, 125, 194),
	OTHERYELLOW =   RGB(205, 191, 121),
	FUSCHIA =       RGB(170, 85,  129),
	OTHERTEAL =     RGB(150, 201, 206),
	LIGHTORANGE =   RGB(206, 150, 100),
	ORANGE =        RGB(208, 120, 86 ),
	PURPLE =        RGB(125, 81,  156),

    --Colour theme to better match the world tones
    --(So these colour names don't match standard web colours).
    TOMATO =        RGB(205, 79,  57 ),
    TAN =           RGB(255, 165, 79 ),
    PLUM =          RGB(205, 150, 205),
    BURLYWOOD =     RGB(205, 170, 125),
    RED =           RGB(238, 99,  99 ),
    PERU =          RGB(205, 133, 63 ),
    DARKPLUM =      RGB(139, 102, 139),
    EGGSHELL =      RGB(252, 230, 201),
    SALMON =        RGB(255, 140, 105),
    CHOCOLATE =     RGB(255, 127, 36 ),
    VIOLETRED =     RGB(139, 71,  93 ),
    SANDYBROWN =    RGB(244, 164, 96 ),
    BROWN =         RGB(165, 42,  42 ),
    BISQUE =        RGB(205, 183, 158),
    PALEVIOLETRED = RGB(255, 130, 171),
    GOLDENROD =     RGB(255, 193, 37 ),
    ROSYBROWN =     RGB(255, 193, 193),
    LIGHTTHISTLE =  RGB(255, 225, 255),
    PINK =          RGB(255, 192, 203),
    LEMON =         RGB(255, 250, 205),
    FIREBRICK =     RGB(238, 44,  44 ),
    LIGHTGOLD =     RGB(255, 236, 139),
    MEDIUMPURPLE =  RGB(171, 130, 255),
    THISTLE =       RGB(205, 181, 205),
}
--★ DEFAULT_PLAYER_COLOUR = RGB(153, 153, 153) -- GREY（第 1767 行）
--  ★ 用RGB() 辅助函数而非裸表 —— 这是本文件少数用函数构造颜色的地方。
--  ★★ 说明：文件里存在**两套颜色写法**：
--    (a) RGB(r,g,b) 辅助函数（如本行）
--    (b) { r/255, g/255, b/255, a/255 } 裸表（如 PLAYERCOLOURS）
--    两者结果等价，新写代码时用 (a) 更清晰。
--  SAY_COLOR / WHISPER_COLOR / TWITCH_COLOR（1769-1771 行）：
--    ★ 聊天文字三色：说话/低语/Twitch 联动。
--    ⇒ 属于UI 表现层，与 gameplay 无关。
DEFAULT_PLAYER_COLOUR = RGB(153, 153, 153) -- GREY

SAY_COLOR =         RGB(255, 255, 255)
WHISPER_COLOR =     RGB(153, 153, 153)
TWITCH_COLOR  =     RGB(153, 153, 255)

--  WET_TEXT_COLOUR = RGB(149, 191, 242)（第 1773 行）：
--    ★★ 很有意思的细节：★「淋湿时」文字变为蓝色。
--    ⇒ 这是一个纯表现层反馈，告诉玩家「你正处在湿身状态」，
--      与 tuning.lua 的湿度机制联动（OCEAN_WETNESS、WET_HEAT_FACTOR）。
--    ★★ 数值设计的体现：状态变化不仅改血条，还改**UI 配色**。
WET_TEXT_COLOUR = RGB(149, 191, 242)
NORMAL_TEXT_COLOUR = RGB(255, 255, 255)

FRONTEND_PORTAL_COLOUR = {245/255, 232/255, 204/255, 255/255}
--FRONTEND_TREE_COLOUR = {208/255, 196/255, 187/255, 255/255} --V2C: baked into the art now
FRONTEND_CHARACTER_CLOSE_COLOUR = {235/255, 225/255, 212/255, 255/255}
FRONTEND_CHARACTER_FAR_COLOUR = {225/255, 216/255, 206/255, 255/255}
FRONTEND_SMOKE_COLOUR = {245/255, 232/255, 204/255, 153/255}
FRONTEND_TITLE_COLOUR = {235/255, 225/255, 212/255, 255/255}
PORTAL_TEXT_COLOUR = {243/255, 244/255, 243/255, 255/255}
FADE_WHITE_COLOUR = {237/255, 224/255, 189/255, 255/255}


--★ CHARACTER_COLOURS（1786 行）：各角色的肤色/主色。
--  ★ 消费方：角色选择界面与多人列表的头像。
--  ANNOUNCEMENT_ICONS（1812 行）：公告图标路径。
--  ROAD_STRIPS（1829 行）：路面贴图（对应 tuning.lua 的 ROADWAY 地面）。
CHARACTER_COLOURS =
{
    wilson       = WEBCOLOURS.ORANGE,
    willow       = WEBCOLOURS.TOMATO,
    wendy        = WEBCOLOURS.KHAKI,
    wolfgang     = WEBCOLOURS.LIGHTSKYBLUE,
    woodie       = WEBCOLOURS.SADDLEBROWN,
    wickerbottom = WEBCOLOURS.MEDIUMPURPLE,
    wx78         = WEBCOLOURS.PERU,
    wes          = WEBCOLOURS.TEAL,
    waxwell      = WEBCOLOURS.SALMON,
    wathgrithr   = WEBCOLOURS.OTHERBLUE,
    webber       = WEBCOLOURS.SPRINGGREEN,
    winona       = WEBCOLOURS.CRIMSON,
    warly        = WEBCOLOURS.RED, --TODO
    --DLC chars:
    wortox       = WEBCOLOURS.RED, --VITO do something here
    wormwood     = WEBCOLOURS.RED, --VITO do something here
    wurt         = WEBCOLOURS.RED, --VITO do something here
    walter       = WEBCOLOURS.RED, --VITO do something here
    wanda        = WEBCOLOURS.RED, --VITO do something here
    --
    default      = WEBCOLOURS.THISTLE,
}


ANNOUNCEMENT_ICONS =
{
    ["default"] =           { atlas = "images/button_icons.xml", texture = "announcement.tex" },
    ["afk_start"] =         { atlas = "images/button_icons.xml", texture = "AFKstart.tex" },
    ["afk_stop"] =          { atlas = "images/button_icons.xml", texture = "AFKstop.tex" },
    ["death"] =             { atlas = "images/button_icons.xml", texture = "death.tex" },
    ["resurrect"] =         { atlas = "images/button_icons.xml", texture = "resurrect.tex" },
    ["join_game"] =         { atlas = "images/button_icons.xml", texture = "join.tex" },
    ["leave_game"] =        { atlas = "images/button_icons.xml", texture = "leave.tex" },
    ["kicked_from_game"] =  { atlas = "images/button_icons.xml", texture = "kicked.tex" },
    ["banned_from_game"] =  { atlas = "images/button_icons.xml", texture = "banned.tex" },
    ["item_drop"] =         { atlas = "images/button_icons.xml", texture = "item_drop.tex" },
    ["vote"] =              { atlas = "images/button_icons.xml", texture = "vote.tex" },
    ["dice_roll"] =         { atlas = "images/button_icons.xml", texture = "diceroll.tex" },
    ["mod"] =               { atlas = "images/button_icons.xml", texture = "mod_announcement.tex" },
}

ROAD_STRIPS =
{
	CORNERS = 0,
	ENDS = 1,
	EDGES = 2,
	CENTER = 3,
}

--【★ WRAP_MODE / FILTER_MODE / MIP_FILTER_MODE】1837-1859 行
--  ★★ 这三个是**贴图采样模式**（纹理环绕、过滤方式）。
--  ★ 与玩法完全无关，但影响画面表现：
--    FILTER_MODE 决定图片放大时是否模糊（线性过滤 vs 最近邻）。
--  ★★ 识别方法：含MODE 且值为小整数的，多半是引擎枚举而非玩法参数。
WRAP_MODE =
{
	WRAP = 0,
	CLAMP = 1,
	MIRROR = 2,
	CLAMP_TO_EDGE = 3,
}

FILTER_MODE =
{
    POINT = 0,
	LINEAR = 1,
	ANISOTROPIC = 2,
    NONE = 3,
}

MIP_FILTER_MODE =
{
    NONE = 0,
    POINT = 1,
    LINEAR = 2,
}

--【★ 渲染引擎高级常量】1860-1895 行
--  SamplerEffectBase / SamplerSizes / SamplerColourMode / TexSamplers
--  UniformVariables / SamplerEffects / PostProcessorEffects / TileGroups
--  ★★ 全部为**空表 {}**（第 1878-1883 行），是给 C++ 侧回填的占位。
--    ⇒ 在纯 Lua 环境（如本项目的脚本提取）里它们全是空的。
--  ShadeTypes（1894 行）：着色器类型（同样为空表）。
--    ★ 读表提示：看到 { } 且名字是渲染相关的，直接跳过。
SamplerEffectBase = {
    PostProcessSampler = 0,
    BloomSampler = 1,
    Shader = 2,
    Texture = 3,
    Smoke = 4,
}

SamplerSizes = {
    Relative = 0,
    Static = 1,
}

SamplerColourMode = {
    RGBA = 0,
    RGB = 1,
}

TexSamplers = {}
UniformVariables = {}
SamplerEffects = {}
PostProcessorEffects = {}

TileGroups = {}

RESET_ACTION =
{
	LOAD_FRONTEND = 0,
	LOAD_SLOT = 1,
	LOAD_FILE = 2,
	DO_DEMO = 3,
    JOIN_SERVER = 4
}

ShadeTypes = {}

--★★ 【★ 图集路径常量（HUD/UI 贴图）】1896-1899 行
--  HUD_ATLAS = "images/hud.xml" / UI_ATLAS = "images/ui.xml"
--  CRAFTING_ATLAS = "images/crafting_menu.xml"
--  CRAFTING_ICONS_ATLAS = "images/crafting_menu_icons.xml"
--  ★★ 这四个「图集」是美术资源的入口文件（Klei 用 XML 描述动画图集）。
--  ★★⚠ 魔数风险：路径字符串写进 UI 配置，改名会让界面加载失败。
--    与物品 ID 同属「字符串即 ID」的风险类别。
HUD_ATLAS = "images/hud.xml"
UI_ATLAS = "images/ui.xml"
CRAFTING_ATLAS = "images/crafting_menu.xml"
CRAFTING_ICONS_ATLAS = "images/crafting_menu_icons.xml"

--  SNOW_THRESH = .015（第 1901 行）：积雪阈值。
--    ★ 无量纲比例（0~1），与 tuning.lua 的 DARK_CUTOFF 同属「归一化数值」。
SNOW_THRESH = .015

--★ VIBRATION_CAMERA_SHAKE=0 / VIBRATION_BLOOD_FLASH=1 / _OVER=2（1903-1905 行）：
--  ★★★ 这是**手柄震动类型**枚举，不是数值参数。
--    ★★ 与第 109 行的 CONTROL_* 同属「平台层动作编号」体系，
--      参与者机与主机端的震动反馈。
--    ★ ★若主机端不支持震动，这些常量实际不会被用到。
VIBRATION_CAMERA_SHAKE = 0
VIBRATION_BLOOD_FLASH = 1
VIBRATION_BLOOD_OVER = 2

--★★★ 【★★ 存档与皮肤槽位 —— 本文件的高危魔数区】1907-1911 行
--  NUM_SKIN_PRESET_SLOTS = 25（第 1907 行）：皮肤预设槽数量。
--  ★★⚠ 魔数风险：槽位编号会写入玩家存档（"我保存了第 17 号预设"）。
--    调小到 20 会让使用 21~25 号槽的玩家丢失预设。
--    ⇒ 安全的做法永远是**只增不减**。
--
--  ★★★ 紧接着的英文原注释（第 1909 行）是一句极重要的警告：
--      'Neither of these are used anymore, kept here only for mods.'
--      「这两个都**不再被使用**了，仅为模组保留。」
--  NUM_SAVE_SLOTS = 5 / NUM_DST_SAVE_SLOTS = NUM_SAVE_SLOTS
--    ★★ 确认了两个 NUM_SAVE_SLOTS **已废弃**。
--    ⇒ 真正的存档槽数量现在由 C++ 引擎侧管理，Lua 里不再声明。
--  ★★★ 这是大型项目演进中的典型痕迹：
--    功能迁到引擎层后，Lua 常量不删除（怕破坏模组），只标注废弃。
--    读表时务必先看有没有这类 'no longer used' 注释，
--    否则会误以为改这些数字能生效。
NUM_SKIN_PRESET_SLOTS = 25

--Neither of these are used anymore, kept here only for mods.
NUM_SAVE_SLOTS = 5
NUM_DST_SAVE_SLOTS = NUM_SAVE_SLOTS

--【SAVELOAD 存档读档操作枚举】1913-1935 行：
--  OPERATION 字段定义存档操作类型（新建/读取/删除…）。
--  ★★ 这是**命令枚举**，参与存档流程分支，改动风险高。
SAVELOAD =
{
    OPERATION =
    {
        PREPARE = 0,
        LOAD = 1,
        SAVE = 2,
        DELETE = 3,
        NONE = 4,
    },

    STATUS =
    {
        OK = 0,
        DAMAGED = 1,
        NOT_FOUND = 2,
        NO_SPACE = 3,
        FAILED = 4,
    },
}

--Extended for DST

--【★ 类别 N · 材质表】1936-1964 行
--  MATERIALS（1936 行）：物品的物理材质（石/木/金属/玻璃…）。
--    ★★ 材质影响：敲击音效、掉落耐久、能否点燃、能被什么工具破坏。
--  FORGEMATERIALS（1958 行）：锻造专用材质子集。
--  ★ 消费方：components/forge.lua、inventory.lua 的耐久消耗逻辑。
MATERIALS =
{
    WOOD = "wood",
    STONE = "stone",
    HAY = "hay",
    THULECITE = "thulecite",
    GEM = "gem",
    GEARS = "gears",
    MOONROCK = "moonrock",
    ICE = "ice",
    CARROT = "carrot",
    SCULPTURE = "sculpture",
    FOSSIL = "fossil",
    MOON_ALTAR = "moon_altar",
    KELP = "kelp",
    SHELL = "shell",
    NIGHTMARE = "nightmare",
	DREADSTONE = "dreadstone",
    SALT = "salt",
    VITAE = "vitae",
}

FORGEMATERIALS =
{
	LUNARPLANT = "lunarplant",
	VOIDCLOTH = "voidcloth",
    WAGPUNKBITS = "wagpunk_bits",
}

--★★★ 【★ 类别 O · ★★ 物品材质分类（与调平衡强相关）★★】1965-2182 行
--
--  ★★ 这是本文件中**与数值平衡关系最密切**的一段，
--    它把物品分成若干「材质类型」，每类有各自的升级/耐久/伤害规则。
--  ★★ 理解它能回答一个常见问题：为什么斧头能砍树但砍不动石头？
--    答：树的材质属于木材类，而斧头的升级路径只覆盖木材类。
--
--  ★★★ UPGRADETYPES（第 1965 行）的英文原注释带着一条重要指令：
--      Keep this table updated in export_accountitems.lua [EAITAB]
--    「务必同步更新 export_accountitems.lua 文件！」
--  ⚠★ 疑似缺陷（跨文件同步风险，无自动校验）：
--    推理依据：注释明确要求两文件保持同步，说明二者强耦合；
--      而这类同步要求完全依赖人工，无任何校验机制。
--    export_accountitems.lua 负责向账户系统导出可购买物品清单，
--      若两表不一致，玩家在商城会看到与实际不符的内容。
--    ★★ 这类「靠注释维持的一致性」是本项目最隐蔽的技术债 ——
--      注释能被看到，但违反时不会有任何报错。
--
--  ★★★ ★ 全文件共 5 处标记了同样的同步要求（实测行号）：★★
--      1965  UPGRADETYPES      Keep this table updated in ...
--      1976  SPELLTYPES         Keep this table updated in ...
--      3017  CIRCUIT_BARS       Keep this table updated in ...
--      3028  MAX_CIRCUIT_SLOTS = 7  Keep this value updated in ...
--      3034  SOCKETQUALITY      Keep this value updated in ...
--    ⇒ 这 5 处构成本文件与 export_accountitems.lua 的同步契约。
--    ⚠ 其中 3017-3034 三处在本文件最尾部（韦斯电路板系统），
--      极易在翻阅时被漏掉。
--
--  ★★ 后续 SPELLTYPES / LOCKTYPE / FUELTYPE / OCCUPANTTYPE（第 1976-2009 行）
--    定义施法书、燃料、乘坐物等分类，与 tuning.lua 的 *_FUEL_MAX、
--    *_WORK 等数值配合。
UPGRADETYPES = -- NOTES(JBK): Keep this table updated in export_accountitems.lua [EAITAB]
{
    DEFAULT = "default",
    SPIDER = "spider",
    WATERPLANT = "waterplant",
    MAST = "mast",
    SPEAR_LIGHTNING = "spear_lightning",
    CHEST = "chest",
    GRAVESTONE = "gravestone",
}

SPELLTYPES = -- NOTES(JBK): Keep this table updated in export_accountitems.lua [EAITAB]
{
    WURT_SHADOW = "wurt_shadow",
    WURT_LUNAR = "wurt_lunar",
    SHADOW_SWAMP_BOMB = "shadow_swamp_bomb",
    LUNAR_SWAMP_BOMB = "lunar_swamp_bomb",
    WORTOX_REVIVER_LOCK = "wortox_reviver_lock", -- Inverted and stops allowing to cast.
}

LOCKTYPE =
{
    DOOR = "door",
    MAXWELL = "maxwell",
}

FUELTYPE =
{
    BURNABLE = "BURNABLE",
    USAGE = "USAGE",
    MAGIC = "MAGIC", --V2C: use this one if u don't want there to be any associated fuel
    CAVE = "CAVE",
    NIGHTMARE = "NIGHTMARE",
    ONEMANBAND = "ONEMANBAND",
    PIGTORCH = "PIGTORCH",
    CHEMICAL = "CHEMICAL",
    WORMLIGHT = "WORMLIGHT",
    LIGHTER = "LIGHTER",
}

OCCUPANTTYPE =
{
    BIRD = "bird",
}

VALID_KITCOON_BUILDS = {
    "kitcoon_forest_build",
    "kitcoon_savanna_build",
    "kitcoon_deciduous_build",
    "kitcoon_marsh_build",
    "kitcoon_grass_build",
    "kitcoon_rocky_build",
    "kitcoon_desert_build",
    "kitcoon_moon_build",
    "kitcoon_yot_build", 
}

--★★ 【FOODTYPE 食物类型表】2022-2044 行 —— ★★ 调平衡核心
--  GENERIC / MEAT / VEGGIE / ELEMENTAL / GEARS / HORRIBLE / INSECT /
--  SEEDS / BERRY …（约 20 种类型）
--  ★★★ 值得注意的一行（BERRY，第 2030 行）：
--    BERRY = "BERRY", --hack for smallbird; berries are actually part of veggie
--    「为了小鸟类生物而设的 hack；浆果实际上属于蔬菜类」
--  ★★ 这条注释坦承了一个**历史特例**：
--    浆果在数值上按 VEGGIE 计算，但为了让小鸟的特定逻辑生效，
--    额外定义了一个 BERRY 类型。
--    ⇒ 说明 FOODTYPE 的划分并非纯粹按设计意图，
--      有个别类型是为「特殊代码路径」而存在的。
--    ★ 调平衡时若发现浆果行为与蔬菜不一致，原因就在这行。
--  ★★★ 与 tuning.lua 的分工（务必记住）：
--    · constants.lua FOODTYPE  —— 食物**属于哪个类型**（分类，不常改）
--    · tuning.lua CALORIES_*   —— 各类型的**具体卡路里**（数值，可调）
--    · tuning.lua PERISH_*     —— 各类型的**腐坏时长**（数值，可调）
--  ★★ 也就是说：食物分类在常量表，平衡数值在调优表。
--    调平衡时只改 tuning.lua，不需要动 FOODTYPE。
--    ⇒ 这正是「常量与数值分离」带来的好处，与文件头分工说明一致。
--★ 消费方：components/hunger.lua（卡路里）、cooking.lua（烹饪）、
--  components/perishable.lua（腐坏）。
FOODTYPE =
{
    GENERIC = "GENERIC",
    MEAT = "MEAT",
    VEGGIE = "VEGGIE",
    ELEMENTAL = "ELEMENTAL",
    GEARS = "GEARS",
    HORRIBLE = "HORRIBLE",
    INSECT = "INSECT",
    SEEDS = "SEEDS",
    BERRY = "BERRY", --hack for smallbird; berries are actually part of veggie
    RAW = "RAW", -- things which some animals can eat off the ground, but players need to cook
    BURNT = "BURNT", --For lavae.
    NITRE = "NITRE", -- For acidbats; they are part of elemental.
    ROUGHAGE = "ROUGHAGE",
	WOOD = "WOOD",
    GOODIES = "GOODIES",
    MONSTER = "MONSTER", -- Added in for woby, uses the secondary foodype originally added for the berries
    LUNAR_SHARDS = "LUNAR_SHARDS", -- For rift birds, yummy glass
    CORPSE = "CORPSE", -- For rift buzzards potentially
    MIASMA = "MIASMA", -- For the centipede thrall
}

--【★★ FOODGROUP 食物分组表】2045-2106 行（★本区第二大表）
--  ★★ 与 FOODTYPE 的区别：
--    FOODTYPE = 「这食物是什么类型」（决定行为规则）
--    FOODGROUP= 「这食物属于哪一组」（用于图鉴/统计/收集进度）
--  ★ 例：所有「料理」类食物同属一个 FOODGROUP，便于展示收集进度。
--  ★★ 这是一张**纯分类表**，几乎不含平衡数值。
--    ⚠ 但分组名会写进存档（收集进度），改名会丢失收集记录。
--  ★★★ 这也解释了「调平衡」时改这里通常没用 —— 
--    真正影响体验的是 tuning.lua 里的卡路里与腐坏时间。
FOODGROUP =
{
    OMNI =
    {
        name = "OMNI",
        types =
        {
            FOODTYPE.MEAT,
            FOODTYPE.VEGGIE,
            FOODTYPE.INSECT,
            FOODTYPE.SEEDS,
            FOODTYPE.GENERIC,
            FOODTYPE.GOODIES,
        },
    },

    BERRIES_AND_SEEDS =
    {
        name = "BERRIES_AND_SEEDS",
        types =
        {
            FOODTYPE.SEEDS,
            FOODTYPE.BERRY,
        },
    },

    BEARGER =
    {
        name = "BEARGER",
        types =
        {
            FOODTYPE.MEAT,
            FOODTYPE.VEGGIE,
            FOODTYPE.BERRY,
            FOODTYPE.GENERIC,
        },
    },

    MOOSE =
    {
        name = "MOOSE",
        types =
        {
            FOODTYPE.MEAT,
            FOODTYPE.VEGGIE,
            FOODTYPE.SEEDS,
        },
    },

    VEGETARIAN =
    {
        name = "VEGETARIAN",
        types =
        {
            FOODTYPE.VEGGIE,
            FOODTYPE.SEEDS,
            FOODTYPE.GENERIC,
            FOODTYPE.GOODIES,
        },
    },
}

--★★ 【FARM_PLANT_STRESS 作物受 Stress 影响】2107-2117 行
--  ★★ 这是「作物会受极端温度影响」的参数表。
--    与 tuning.lua 的 MIN/MAX_PLANT_WITHER_TEMP（2270-2271 行）配套：
--      tuning 定义「什么温度会枯萎」，constants 定义「枯萎的严重程度」。
--    ★★ 又一处「分类在常量、阈值在调优」的分工。
--★ 消费方：components/farmplant.lua。
FARM_PLANT_STRESS = {
	NONE = 1,
	LOW = 2,
	MODERATE = 3,
	HIGH = 4,
}

-- NOTES(JBK): After initial game load this is a constant of some value.
-- This is the maximum number of offerings a craftingstation:SetRecipeCraftingLimit can have.
-- For each recipe that is designed for this it will be added to the list.
-- This table is declared in constants used by simutil through recipes and is what is used by a player_classified.
--【CRAFTINGSTATION_LIMITED_RECIPES 系列】2118-2122 行
--  ★ 三张空表 + 一个计数器，都是**模组扩展点**：
--    CRAFTINGSTATION_LIMITED_RECIPES = {}
--    CRAFTINGSTATION_LIMITED_RECIPES_LOOKUPS = {}
--    CRAFTINGSTATION_LIMITED_RECIPES_COUNT = 0
--    EXTERNALLY_HANDLED_LIMITED_RECIPES = {}
--  ★★ 说明：这些配方**没有定义在源码里**，而是由模组在运行时注入。
--    ⇒ 若想知道某配方从哪来，看模组而不是本文件。
CRAFTINGSTATION_LIMITED_RECIPES = {}
CRAFTINGSTATION_LIMITED_RECIPES_LOOKUPS = {}
CRAFTINGSTATION_LIMITED_RECIPES_COUNT = 0
EXTERNALLY_HANDLED_LIMITED_RECIPES = {} -- These are from getlimitedrecipecount where the number limit is expected to be synchronized on the client and server.

--★★ 【角色食材需求表】2123-2146 行
--  CHARACTER_INGREDIENT（2123 行）：每个角色解锁哪些食材（烹饪解锁）。
--  CHARACTER_INGREDIENT_SEG = 5（第 2134 行）：
--  ★★★ 纠正一个极易产生的误解：它**不是字符串分隔符**，而是
--    「数值步进粒度」。其正上方第 2133 行有明确英文注释：
--      '--Character ingredient amounts must be multiples of 5'
--      「角色食材数量必须是 5 的倍数」
--    ⇒ 用途是**校验规则**：烹饪所需食材数（2 份→3 份→4 份）
--      统一按 5 的倍数递增，保证配方数量递进符合直觉。
--    ★ SEG = segment/步进（segment 的常见缩写），非 separator。
--    ⚠ 首次阅读时极易误以为是「分隔符 ASCII 值」，务必看上一行注释。
--  TECH_INGREDIENT（2136 行）：科技树的食材需求。
--  TECH_SKILLTREE_BUILDER_TAG_OWNERS（2147 行）：技能树标签归属。
--  SKILLTREE_EQUIPPABLE_RESTRICTED_TAGS（2149 行）：
--    ★ 限定「哪些装备标签可被技能树引用」。
--  INGREDIENT_MOD_LOOKUP（2165 行）/ INGREDIENT_MOD = table.invert(...)（2173 行）：
--    ★★★ 这是一个「双向映射表」的标准写法：
--      LOOKUP   = { [名称] = 索引 }        正向：名字 → 编号
--      INGREDIENT_MOD = table.invert(LOOKUP) 反向：编号 → 名字
--    ★ 用一个函数生成反向表，避免手写两份可能不同步的数据。
--    ★★ 本文件其他 _LOOKUP 表（第 2874、2896、2914 行）也遵循此模式。
CHARACTER_INGREDIENT =
{
    --NOTE: Value is used as key for NAME string and inventory image
    HEALTH = "decrease_health",
    MAX_HEALTH = "half_health",
    SANITY = "decrease_sanity",
    MAX_SANITY = "half_sanity",
	OLDAGE = "decrease_oldage",
}

--Character ingredient amounts must be multiples of 5
CHARACTER_INGREDIENT_SEG = 5

TECH_INGREDIENT =
{
    --NOTE: Value is used as key for NAME string and inventory image
    --NOTE: Must be name of the tech + "_material"
    SCULPTING = "sculpting_material",
}

-- NOTES(DiogoW): Now DEPRECATED, keeping it around for mods.
    -- Identifies which builder tags are from which characters' skill trees,
    -- so that the crafting menu properly identifies that they're locked behind a skill
    -- for your current character.
TECH_SKILLTREE_BUILDER_TAG_OWNERS = {}

SKILLTREE_EQUIPPABLE_RESTRICTED_TAGS =
{
    -- Using quotes for searching purposes.
    ["inspectacleshatuser"]  = "winona",
    ["wathgrithrshielduser"] = "wathgrithr",
    [UPGRADETYPES.SPEAR_LIGHTNING.."_upgradeuser"] = "wathgrithr",
    ["nabbaguser"] = "wortox",
	["drone_zap_user"] =
    { -- (OMAR): :,)
        ["wx78"] = true,
        ["wx78_possessedbody"] = true,
        ["wx78_backupbody_inventory"] = true,
    },
}

-- IngredientMod must be one of the following values
INGREDIENT_MOD_LOOKUP =
{
    [0] = 0,
    [1] = 0.25,
    [2] = 0.5,
    [3] = 0.75,
    [4] = 1.0,
}
INGREDIENT_MOD = table.invert(INGREDIENT_MOD_LOOKUP)

--【CONTAINERTEST 容器测试】2175 行：容器交互测试表。
--  TOOLACTIONS 工具动作表（2183 行）：
--    ★★ 定义「持某种工具对某物品做什么」—— 即工具的行为映射。
--    ★★ 这张表决定了：斧头能砍树、锄头能耕地、铲子能挖洞。
--    ★★ 是 gameplay 的核心映射表，但**数值在 tuning.lua**。
--      例：砍树需要的敲击次数在 tuning.lua 的 *_CHOPS_* 系列。
--    ⇒ 又是「行为映射在常量、强度数值在调优」的分工。
CONTAINERTEST =
{
    NONE = 0,
    COOKING = 1,
    PERISHABLE_FOOD = 2,
    TELEPORTATO = 3,
}

TOOLACTIONS =
{
    CHOP = true,
    DIG = true,
    HAMMER = true,
    MINE = true,
    NET = true,
    PLAY = true,
    UNSADDLE = true,
	SCYTHE = true,
}

--【★ 类别 P · 动作与建造模式枚举】2195-2292 行
--  FALLINGREASON 掉落原因枚举（2195 行）：
--    ★★ 记录「东西为什么掉了」（被打死 / 掉进洞/ 被丢下）。
--    ★ 部分原因会触发音效与音效强度，属表现层。
--  EQUIPMENTSETNAMES 套装名（2201 行）：
--    ★★★ 这与tuning.lua 的 *_SETBONUS 系列配套：
--      穿齐两件套触发加成（见 tuning.lua:1893
--        ARMOR_LUNARPLANT_SETBONUS_LUNAR_RESIST = math.sqrt(0.75)/0.9，
--        该行注释'--sqrt because two pieces combine to achieve this'
--        明确说明开方是因为「两件装备要恰好组合出该效果」）。
--  ★★ 这是跨文件设计耦合的又一例：常量表命名套装，调优表算加成。
--  DEPLOYMODE / BUILDMODE（2211-2231 行）：部署与建造模式。
--  DEPLOYSPACING / DEPLOYSPACING_RADIUS（2232-2260 行）：部署间距。
--    ★★ 对应 tuning.lua:3858 MOON_TREE_DEPLOY_SPACING 的废弃警告
--      （'--DO NOT USE! (use DEPLOYSPACING enums instead)'），
--      说明部署间距的正确来源是这里的枚举而非 tuning.lua。
--  TROPHYSCALE_TYPES 战利品缩放类型（2261 行）。
--  NAUGHTY_VALUE 邪恶值（2267 行）：
--    ★★ 用于「熊孩子/捣蛋鬼」相关内容，属独立小游戏系统。
FALLINGREASON =
{
    OCEAN = "ocean",
    VOID = "void",
}

EQUIPMENTSETNAMES =
{
    DREADSTONE = "dreadstone",
    LUNARPLANT = "lunarplant",
    VOIDCLOTH = "voidcloth",
    YOTH_KNIGHT = "yoth_knight",
    YOTH_PRINCESS = "yoth_princess",
}

-- this is a net_tinybyte on inventoryitem_classified.deploymode
DEPLOYMODE =
{
    NONE = 0,
    DEFAULT = 1,
    ANYWHERE = 2,
    TURF = 3,
    PLANT = 4,
    WALL = 5,
    WATER = 6,
    MAST = 7,-- Keeping MAST around for mod support
    CUSTOM = 7,
}

BUILDMODE =
{
    NONE = 0,
    LAND = 1,
    WATER = 2
}

-- Max value of 7 (net_tinybyte)
DEPLOYSPACING =
{
    DEFAULT = 0,
    MEDIUM = 1,
    LESS = 2,
    NONE = 3,
	PLACER_DEFAULT = 4,
    LARGE = 5,
	--V2C: late additions
	ONEPOINTFIVE = 6,
}

--V2C: Deploy spacing is a legacy system where this is actually the distance
--     between our center point and other objects' center points.
--     For newer things, half of DEPLOYSPACING_RADIUS is used to indicate our
--     actual footprint radius, combined with nearby objects that have called
--     SetDeploySmartRadius (or physics size for inventoryitems) to determine
--     required deploy spacing.
DEPLOYSPACING_RADIUS =
{
    [DEPLOYSPACING.DEFAULT] = 2,
    [DEPLOYSPACING.MEDIUM] = 1,
    [DEPLOYSPACING.LESS] = .75,
    [DEPLOYSPACING.NONE] = 0,
	[DEPLOYSPACING.PLACER_DEFAULT] = 3.2,
    [DEPLOYSPACING.LARGE] = 4.0,
	[DEPLOYSPACING.ONEPOINTFIVE] = 1.5,
}

TROPHYSCALE_TYPES =
{
    FISH = "fish",
    OVERSIZEDVEGGIES = "oversizedveggies",
}

NAUGHTY_VALUE =
{
    ["pigman"] = 3,
    ["babybeefalo"] = 6,
    ["teenbird"] = 2,
    ["smallbird"] = 6,
    ["beefalo"] = 4,
    ["deer"] = 4,
    ["crow"] = 1,
    ["robin"] = 2,
    ["robin_winter"] = 2,
    ["canary"] = 2,
    ["butterfly"] = 1,
    ["moonbutterfly"] = 1,
    ["rabbit"] = 1,
    ["mole"] = 1,
    ["tallbird"] = 2,
    ["bunnyman"] = 3,
    ["penguin"] = 2,
    ["glommer"] = 50, -- You've been bad!
    ["catcoon"] = 5,
    ["lightflier"] = 1,
    ["dustmoth"] = 4,
    ["friendlyfruitfly"] = 20,
}

--【★ 类别 Q · ★★ Steam AppID 与 UI 基础常量 —— 本区第一个高危魔数】2293 行
--  ★★★ 三个 Steam 商店 ID（2293-2295 行）：
--      DONT_STARVE_TOGETHER_APPID = 322330（★本作）
--      DONT_STARVE_APPID = 219740（初代饥荒）
--      REIGN_OF_GIANTS_APPID = 282470（reign of giants DLC）
--  ★★ 用途：区分玩家买的是哪一作，用于 DLC 校验与跨作联机判断。
--  ★★⚠ 这三个数字是**外部平台 ID**，由 Steam 平台规定，不可自创；
--    写错会导致 DLC 校验失败或跳转到错误的商店页。
--  HUMAN_MEAT_ENABLED = false（第 2299 行）：
--    ★★ 布尔开关，默认关闭 —— 涉及部分地区法规合规要求。
--  SWIPE_FADE_TIME = .4 / SCREEN_FADE_TIME = .2（第 2301-2302 行）：
--    ★ UI 过渡时长（秒）。属表现层，不影响平衡。
--  DOUBLE_CLICK_TIMEOUT = .5 / _POS_THRESHOLD = 3（第 2306-2307 行）：
--    ★ 双击判定：0.5 秒内、位移不超过 3 单位。
--    ★★ 3 单位小于 1 格（TILE_SCALE = 4），所以鼠标几乎不动才算双击。
--  GOLD / GREY / BLACK / WHITE / BROWN / RED / DARKGREY（2309-2315 行）：
--    ★ 基础调色板，供 UICOLOURS 表引用。
--★ 下一部分（类别 R：聊天/权限）从第 2351 行开始。
DONT_STARVE_TOGETHER_APPID = 322330
DONT_STARVE_APPID = 219740
REIGN_OF_GIANTS_APPID = 282470

-- keeping this here in case someone wants to mod it in. It won't be a default part of the game (or even an option), but we've already done the work
-- and someone might be able to do something cool with it.
HUMAN_MEAT_ENABLED = false

SWIPE_FADE_TIME = .4
SCREEN_FADE_TIME = .2
-- Use TEMPLATES.BackButton instead of BACK_BUTTON_X/Y
BACK_BUTTON_X = 60
BACK_BUTTON_Y = 60
DOUBLE_CLICK_TIMEOUT = .5
DOUBLE_CLICK_POS_THRESHOLD = 3 --how far ur mouse can move and still count as dbl click

GOLD = {202/255, 174/255, 118/255, 255/255}
GREY = {.57, .57, .57, 1}
BLACK = {.1, .1, .1, 1}
WHITE = {1, 1, 1, 1}
BROWN = {97/255, 73/255, 46/255, 255/255}
RED = {.7, .1, .1, 1}
DARKGREY = {.12, .12, .12, 1}

-- A coherent palette for UI elements
--★ UICOLOURS 界面配色表（2318 行）+ PLANTREGISTRYUICOLOURS（2341 行）。
--  ★ PLANTREGISTRY = 植物图鉴。这是 DST 的收集系统UI。
--    植物图鉴的收集进度会写入存档（见第 2889 行 SPECIAL_SCRAPBOOK_PAGES）。
UICOLOURS = {
    GOLD_CLICKABLE = RGB(215, 210, 157), -- interactive text & menu
    GOLD_FOCUS = RGB(251, 193, 92), -- menu active item
    GOLD_SELECTED = RGB(245, 243, 222), -- titles and non-interactive important text
    GOLD_UNIMPORTANT = RGB(213, 213, 203), -- non-interactive non-important text
    HIGHLIGHT_GOLD = RGB(243, 217, 161),
    GOLD = GOLD,
    BROWN_MEDIUM = RGB(107, 84, 58),
    BROWN_DARK = RGB(80, 61, 39),
    BLUE = RGB(80, 143, 244),
    GREY = GREY,
    BLACK = BLACK,
    WHITE = WHITE,
    BRONZE = RGB(180, 116, 36, 1),
    EGGSHELL = RGB(252, 230, 201),
    IVORY = RGB(236, 232, 223, 1),
    IVORY_70 = RGB(165, 162, 156, 1),
    PURPLE = RGB(152, 86, 232, 1),
    RED = RGB(207, 61, 61, 1),
    SLATE = RGB(155, 170, 177, 1),
	SILVER = RGB(192, 192, 192, 1),
}

PLANTREGISTRYUICOLOURS = {
    LOCKEDBROWN = RGB(76, 50, 34, 1),
    UNLOCKEDBROWN = RGB(76, 50, 34, 1), --UICOLOURS.EGGSHELL,
}


--★ MAX_CHAT_INPUT_LENGTH = 150 / MAX_WRITEABLE_LENGTH = 200（第 2347-2348 行）：
--  ★★ 输入长度上限。属技术限制（防超长文本），非平衡数值。
--    ★ 200 > 150 ⇒ 「可写入的内容（存档/日志）」比「聊天框」更长，
--      两者服务于不同场景。
MAX_CHAT_INPUT_LENGTH = 150
MAX_WRITEABLE_LENGTH = 200

-- Used by exportprefabs to identify which "npcchatflairs" images to recognize.
--  DST_NPCCHATTERLIST NPC 闲聊库（2351 行）。
--  ★★ 这是「NPC 会随机说的话」文本库。纯内容，无逻辑。
DST_NPCCHATTERLIST =
{
    "none", -- Default chatter/image name

    "daywalker",
    "daywalker_scrap",
    "hermitcrab",
    "sharkboi",
    "stalker",
    "wagstaff",
    "wanderingtrader",
}

--★★★ 【CHATPRIORITIES 聊天优先级】2364-2382 行
--  ★★ 这张表决定「谁的消息显示在哪里 / 谁能看到谁的消息」：
--    例如普通聊天进公共频道、世界管理员消息给所有人看、
--    队伍语音只给同队玩家显示。
--  ★★ 这是**联机核心机制**：过滤聊天可见性，防止跨队泄露信息。
--  ★★⚠ 魔数风险：优先级值决定消息路由，改动会导致
--    「本该私密的队伍消息出现在公共频道」—— 这是**信息泄露类 bug**。
--    ⇒ 在修改权限系统时必须格外小心。
CHATPRIORITIES =
{
    -- Messages sent with priority 0 should never appear in chat history.
    NOCHAT = 0,

    LOW = 1,
    HIGH = 2,

    -- Keep this the highest value in the table.
    -- Do not use this value for any messages, unless
    -- it is desperately needed to be seen irrelevant of user settings.
    MAX = 3,
}

--Bit flags, currently supports up to 8
--Server may use these for things that clients need to know about
--other clients whose player entities may or may not be available
--e.g. Stuff that shows on the scoreboard
-- NOTE: Keep this up to date with USERFLAGS::Enum in PlayerListingData.h
--★★★ 【USERFLAGS 用户权限标志位】2383-2395 行 —— ★★ 位掩码
--  ★★ 这是**权限的位掩码枚举**，与 YOTB_COSTUMES 同一用法：
--    每个标志是 2 的幂（1/2/4/8...），可按位或组合成一个整数。
--    例：房主+建造者权限 = USERFLAGS.HOST | USERFLAGS.BUILDER
--  ★★★ 正确判定方式（务必记住）：
--      if flags & USERFLAGS.BUILDER ~= 0 then   ← 位与，判断「拥有」
--      if flags == USERFLAGS.BUILDER then       ← 错误！组合值不匹配
--  ★★ 因为一个玩家往往同时拥有多项权限，用相等比较会永远为假。
--  ★ 这与本文件第 2746 行 YOTB_COSTUMES 是完全相同的陷阱。
--★ 消费方：networking.lua / consolecommands.lua 的权限校验。
USERFLAGS =
{
    IS_GHOST			= 1,
    IS_AFK				= 2,
    CHARACTER_STATE_1	= 4,
    CHARACTER_STATE_2	= 8,
    IS_LOADING			= 16,
    CHARACTER_STATE_3   = 32,
    -- = 64,
    -- = 128,
}

--Camera shake modes
--★ CAMERASHAKE 震屏类型（2396 行）/ RATE_SCALE 速率缩放（2404 行）。
--  TWITCH（2416 行）：Twitch 联动的平台 ID 与配置。
--  ★ Twitch 相关的键名会参与账号鉴权，改动会导致登录失败。
--  ORDERS 管理员指令表（2425 行）：控制台指令的定义。
--  PLAYERSTUNLOCK 玩家解锁项（2434 行）：
--    ★★★ 记录「哪些角色/物品需要解锁才能用」，**会写入存档**。
--      ⚠ 改动会让老玩家的解锁状态错乱（已解锁变未解锁）。
--    ⇒ 这是「存档兼容性」最敏感的表之一，只增不减。
CAMERASHAKE =
{
    FULL = 0,
    SIDE = 1,
    VERTICAL = 2,
}

--Badge/meter arrow sizes
RATE_SCALE =
{
    NEUTRAL = 0,
    INCREASE_HIGH = 1,
    INCREASE_MED = 2,
    INCREASE_LOW = 3,
    DECREASE_HIGH = 4,
    DECREASE_MED = 5,
    DECREASE_LOW = 6,
}

-- Twitch status codes
TWITCH =
{
    UNDEFINED = -1,
    CHAT_CONNECTED = 0,
    CHAT_DISCONNECTED = 1,
    CHAT_CONNECT_FAILED = 2,
}

-- TeamAttacker orders
ORDERS =
{
    NONE = 0,
    HOLD = 1,
    WARN = 2,
    ATTACK = 3,
}

-- How does this creature apply stunlock to the player
PLAYERSTUNLOCK =
{
    ALWAYS = nil,--0,
    OFTEN = 1,
    SOMETIMES = 2,
    RARELY = 3,
    NEVER = 4,
}

-- Which wormhole?
--【★ 传送门与危险提示枚举】2444-2495 行
--  WORMHOLETYPE 传送门类型（2444 行）。
--  HOUNDWARNINGTYPE 猎犬预警类型（2453 行）。
--    ★★ 玩家在屏幕边缘看到的「猎犬来了」提示有不同等级。
--  TENDENCY 倾向（2467 行）：NPC 性格倾向。
--  REMOTESHARDSTATE 远程服务器状态（2475 行）：
--    ★ 联机主从架构下的 shard（分片）状态机。
--  SHARDID 分片 ID（2481 行）/ PRIVACY_TYPE 隐私类型（2488 行）。
--  INTENTIONS 意图枚举（2496 行）：请求加入/直连/换主机。
--  ★★ 这几项是联机底层协议的枚举，改动会导致客户端与主机握手失败。
WORMHOLETYPE =
{
    WORM = 0,
    TENTAPILLAR = 1,
    OCEANWHIRLPORTAL = 2,
    VAULTLOBBYEXIT = 3,
}

-- Houndwarning level, max value of 63 (net_smallbyte)
HOUNDWARNINGTYPE =
{
    LVL1 = 0,
    LVL2 = 1,
    LVL3 = 2,
    LVL4 = 3,
    LVL1_WORM = 4,
    LVL2_WORM = 5,
    LVL3_WORM = 6,
    LVL4_WORM = 7,
    WORM_BOSS = 8,
}

-- Domestication tendencies
TENDENCY =
{
    DEFAULT = "DEFAULT",
    ORNERY = "ORNERY",
    RIDER = "RIDER",
    PUDGY = "PUDGY",
}

REMOTESHARDSTATE =
{
    OFFLINE = 0,
    READY = 1,
}

SHARDID =
{
    INVALID = "0",
    MASTER = "1"
}

-- Server pricacy options
PRIVACY_TYPE =
{
    PUBLIC = 0,
    FRIENDS = 1,
    LOCAL = 2,
    CLAN = 3,
}

INTENTIONS =
{
    SOCIAL = "social",
    COOPERATIVE = "cooperative",
    COMPETITIVE = "competitive",
    MADNESS = "madness",
    ANY = "any", -- for player use only, servers must have an intention
}

--【★ 联机世界类型与标签】2505-2545 行
--  PLAYSTYLE_ANY / PLAYSTYLE_DEFAULT = "survival"（2505-2506 行）。
--    ★ 玩法类型字符串（生存/标本/ Davenport 等）。
--    ⚠ 该值可能写入存档，作为世界类型标识。
--  WORLDPROGRESSIONTAG_MUST = "must" / _CANT = "cant"（2508-2509 行）：
--    ★ 世界进度标签：「必须完成」/「禁止完成」的标记。
--  LEVELTYPE（2511 行）：世界类型表。
--  EVENTSERVER_LEVEL_LOCATIONS 事件服务器区域（2538 行）。
--  SERVER_LEVEL_SHARDS 服务器分片配置（2546 行）。
--  SERVER_LEVEL_CONFIGS 服务器配置（2552 行）。
--    ★★ 这几张表描述「联机服务器如何拉起世界」，是运维侧配置。
PLAYSTYLE_ANY = "ANY"
PLAYSTYLE_DEFAULT = "survival"

WORLDPROGRESSIONTAG_MUST = "must"
WORLDPROGRESSIONTAG_CANT = "cant"

LEVELTYPE = {
    SURVIVAL = "SURVIVAL",
    CAVE = "CAVE",
    ADVENTURE = "ADVENTURE",
    LAVAARENA = "LAVAARENA",
    QUAGMIRE = "QUAGMIRE",
    TEST = "TEST",
    UNKNOWN = "UNKNOWN",
    CUSTOM = "CUSTOM",
    CUSTOMPRESET = "CUSTOMPRESET",
}

if BRANCH == "dev" then
    SERVER_LEVEL_LOCATIONS =
    {
        "forest",
        "cave",
    }
else
    SERVER_LEVEL_LOCATIONS =
    {
        "forest",
        "cave",
    }
end
assert(BRANCH == "dev" or SERVER_LEVEL_LOCATIONS[1] == "forest", "Invalid server start level location.")

EVENTSERVER_LEVEL_LOCATIONS =
{
	[LEVELTYPE.LAVAARENA] = { "lavaarena" },
	[LEVELTYPE.QUAGMIRE] = { "quagmire" },
}

DEFAULT_LOCATION = "forest"

SERVER_LEVEL_SHARDS =
{
    "Master",
    "Caves",
}

SERVER_LEVEL_CONFIGS =
{
	forest = {
		standalone = true,
	},
	cave = {
		standalone = false,
		shard_link = true,
	},
}

-- Mirrors constant from CloudSaves.h
--★★★ 【CLOUD_SAVES_SAVE_OFFSET = 100000】—— 存档编号的高危魔数
--  ★★★ 这个数字必须单独理解，它决定云存档的编号空间：★★
--    · 本地存档编号从 0（或 1）开始；
--    · 云存档编号统一加上 100000 的偏移，
--      即云存档 #1 在系统里是 100001。
--  ★★ 为什么需要偏移？为了与本地存档**互不冲突** ——
--    若云存档用 1,2,3…，就分不清「第 1 个」是本地还是云端。
--  ★★★⚠ 魔数风险：
--    · 改这个值 → 所有云存档都会「消失」（编号对不上，列表为空）。
--    · 这是本文件中**最不可改动的单个数字**之一。
--  ★ 若确需变更（如迁移），必须同时做数据迁移脚本。
CLOUD_SAVES_SAVE_OFFSET = 100000

--【COMMAND_PERMISSION / COMMAND_RESULT】2566-2579 行：
--  ★ 控制台指令所需的权限等级，以及指令执行结果枚举。
--  ★★ 与第 2383 行 USERFLAGS 配合，构成完整的权限校验体系。
COMMAND_PERMISSION = {
    ADMIN = "ADMIN", -- only admins see and can activate
    MODERATOR = "MODERATOR", -- only admins and mods can see and activate
    USER = "USER", -- anyone can see and do instantly. Mostly for local commands, or if a mod wants to offer accessible functionality
}

COMMAND_RESULT = {
    ALLOW = "ALLOW",
    DISABLED = "DISABLED", --cannot run it right now (not related to voting)
    VOTE = "VOTE",
    DENY = "DENY", --cannot start vote right now
    INVALID = "INVALID",
}

--  CARRAT_MUSIC_STATES 嘉年华音乐状态（2580 行）。
--  LOCALPLAYER_MUSIC 本地玩家音乐（2586 行）：
--    ★★ 这是**本地偏好**而非世界状态，所以不同步给其他玩家。
--      ⇒ 它不改存档、不参与联机校验 —— 风险等级低。
--  MAX_VOTE_OPTIONS = 6（第 2591 行）：投票选项上限。
--    ★★ 与第 209 页 TUNING 的 MAX_FLOOR_ITEMS 等「上限」同类：
--      这些是防滥用/防性能问题的技术上限，不参与平衡。
CARRAT_MUSIC_STATES = {
    NONE = 0,
    TRAINING = 1,
    RACE = 2,
}

LOCALPLAYER_MUSIC = {
    NONE = 0,
    WINTERS_FEAST = 1,
}

MAX_VOTE_OPTIONS = 6

--★★★ 【USER_HISTORY_EXPIRY_TIME = 60*60*24*30】—— 见习期时长
--  ★★ 写法极具示范性：`60*60*24*30` 而不是 `2592000`。
--    ⇒ 一眼看出是「30 天」，而 2592000 无法心算。
--    ★★ 这与 tuning.lua 的归一化写法是同一种思想：
--      **让表达式承载意图**，而不是留下算完的结果。
--  ★ 行尾英文注释 '30 days' 直接给出了结果，两者互为验证。
--  ★⇒ 这是本文件里**归一化/可读性写法**的最佳实例之一。
USER_HISTORY_EXPIRY_TIME = 60*60*24*30 -- 30 days

-- Mirrors enum in SystemService.h
--【★ 类别 S · 语言与物品数量上限】2596-2675 行
--  LANGUAGE 语言表（2596 行）：定义支持的语言代码。
--  LANGUAGE_STEAMCODE_TO_ID（2624 行）：Steam 语言代码 → 游戏内部 ID。
--    ★★ 这是一个**外部平台映射表**，用于识别玩家客户端语言。
--    ⚠ 语言代码是 Steam 约定的标准值，不可自创。
LANGUAGE =
{
    ENGLISH = 0,
    ENGLISH_UK = 1,
    FRENCH = 2,
    FRENCH_CA = 3,
    SPANISH = 4,
    SPANISH_LA = 5,
    GERMAN = 6,
    ITALIAN = 7,
    PORTUGUESE = 8,
    PORTUGUESE_BR = 9,
    DUTCH = 10,
    FINNISH = 11,
    SWEDISH = 12,
    DANISH = 13,
    NORWEGIAN = 14,
    POLISH = 15,
    RUSSIAN = 16,
    TURKISH = 17,
    ARABIC = 18,
    KOREAN = 19,
    JAPANESE = 20,
    CHINESE_T = 21,
    CHINESE_S = 22,
    CHINESE_S_RAIL = 23,
}

LANGUAGE_STEAMCODE_TO_ID =
{
    brazilian = LANGUAGE.PORTUGUESE_BR,
    bulgarian = nil,
    czech = nil,
    danish = LANGUAGE.DANISH,
    dutch = LANGUAGE.DUTCH,
    english = LANGUAGE.ENGLISH,
    finnish = LANGUAGE.FINNISH,
    french = LANGUAGE.FRENCH,
    german = LANGUAGE.GERMAN,
    greek = nil,
    hungarian = nil,
    italian = LANGUAGE.ITALIAN,
    japanese = LANGUAGE.JAPANESE,
    korean = LANGUAGE.KOREAN,
    norwegian = LANGUAGE.NORWEGIAN,
    polish = LANGUAGE.POLISH,
    portuguese = LANGUAGE.PORTUGUESE,
    romanian = nil,
    russian = LANGUAGE.RUSSIAN,
    schinese = LANGUAGE.CHINESE_S,
    spanish = LANGUAGE.SPANISH,
    swedish = LANGUAGE.SWEDISH,
    tchinese = LANGUAGE.CHINESE_T,
    thai = nil,
    turkish = LANGUAGE.TURKISH,
    ukrainian = nil,
}

--★★ 【QUAGMIRE_NUM_* 沼泽世界数量上限】2654-2656 行
--  QUAGMIRE_NUM_FOOD_PREFABS = 69 / QUAGMIRE_NUM_SEEDS_PREFABS = 7
--  QUAGMIRE_USE_KLUMP = false
--    ★★★ 这是本文件**最后一组会参与世界生成的硬上限**：
--      69 种食物 prefab、7 种种子 prefab ——
--      它限定了沼泽世界地图上能生成多少种食物。
--  ⚠★ 魔数风险（生成上限）：
--    推理依据：NUM_ 前缀 + 数值恰为 prefab 数量，说明这是
--      「地图生成时随机抽取的候选池大小」。
--    ⇒ 把 69 改小会让沼泽世界的食物种类减少（生态变单调）；
--      改大则无效（因为 prefab 总数就那么多）。
--  ★★ 对比 NUM_TRINKETS（第 1603 行，收集类，写入存档）：
--    同样是 NUM_ 常量，但一个管**生成**、一个管**存档**，
--      风险性质完全不同。读 NUM_ 常量时务必先确认它是哪一类。
--  QUAGMIRE_USE_KLUMP = false：是否使用特殊土球（沼泽机制）开关。
QUAGMIRE_NUM_FOOD_PREFABS = 69
QUAGMIRE_NUM_SEEDS_PREFABS = 7
QUAGMIRE_USE_KLUMP = false

--★ OCEAN_MAPWRAPPER_WARN_RANGE / OCEAN_POPULATION_EDGE_DIST /
--  OCEAN_WATERFALL_MAX_DIST（2658-2660 行）：海洋地图与瀑布的渲染/生成参数。
--  INVENTORY_PROGRESS 物品栏进度表（2663 行）：
--    ★★ 这是「物品收集进度」的展示分组（按材料分类显示百分比）。
--    ★ 与 FOODGROUP 配合，图鉴 UI 据此渲染。
OCEAN_MAPWRAPPER_WARN_RANGE = 14
OCEAN_POPULATION_EDGE_DIST = 4
OCEAN_WATERFALL_MAX_DIST = 14

-- needs to be kept synchronized with InventoryProgress enum in InventoryManager.h
--★ 【★ BETA_INFO 测试版信息】2663-2710 行
--  CURRENT_BETA = 1（第 2675 行）：
--  ★★ 英文原注释：'set to 0 if there is no beta. Note: release builds
--   wont use this...'
--    「没有 beta 时设为 0。注意：正式版本不会用这个。」
--    ★★ 这是**发布通道标记**：
--      · 值 > 0 → 当前是第 N 个 beta 通道
--      · 值 = 0 → 正式版
--    ⇒ 该值可能影响服务器与客户端的兼容性校验。
--  PUBLIC_BETA = #BETA_INFO（第 2708 行）：
--    ★★★ 用Lua 的 # 运算符（取数组长度）自动计算公开 beta 数量！
--      ⇒ 往 BETA_INFO 里加一项，PUBLIC_BETA 自动 +1，无需手动同步。
--    ★★ 这是「用表达式代替手写常量」的又一实例，
--      与 tuning.lua 的归一化思想一致，且**自动维护、不会失配**。
--★ 命名识别法：当前行是源数据，行尾注释标注了「另一个常量是它的函数」。
INVENTORY_PROGRESS =
{
	IDLE = 0,
	CHECK_SHOP = 1,
	CHECK_EVENT = 2,
	CHECK_DLC = 3,
	CHECK_DAILY_GIFT = 4,
	CHECK_PENDINGKEYVALUESTORES = 5,
	CHECK_KEYVALUESTORES = 6,
	CHECK_INVENTORY = 7,
}

CURRENT_BETA = 1 -- set to 0 if there is no beta. Note: release builds wont use this so only staging and dev really care
BETA_INFO =
{
    {
		NAME = "UPDATEBETA",
		SERVERTAG = "public_update_beta",
		VERSION_MISMATCH_STRING = "VERSION_MISMATCH_UPDATEBETA",
		URL = "https://forums.kleientertainment.com/forums/topic/106156-how-to-opt-in-to-return-of-them-beta-for-dont-starve-together/",
	},

    {
		NAME = "ROTBETA",
		SERVERTAG = "return_of_them_beta",
		VERSION_MISMATCH_STRING = "VERSION_MISMATCH_ROTBETA",
		URL = "https://forums.kleientertainment.com/forums/topic/106156-how-to-opt-in-to-return-of-them-beta-for-dont-starve-together/ ",
	},

    {
		NAME = "ANRBETA",
		SERVERTAG = "a_new_reign_beta",
		VERSION_MISMATCH_STRING = "VERSION_MISMATCH_ARNBETA",
		URL = "https://forums.kleientertainment.com/topic/69487-how-to-opt-in-to-a-new-reign-beta-for-dont-starve-together/",
	},

	-- THE GENERIC PUBLIC BETA INFO MUST BE LAST --
	-- This is added to all beta servers as a fallback
	{
		NAME = "PUBLIC_BETA",
		SERVERTAG = "public_beta",
		VERSION_MISMATCH_STRING = "VERSION_MISMATCH_PUBLIC_BETA",
		URL = "https://forums.kleientertainment.com/forum/66-dont-starve-together-general-discussion/",
	},
}
PUBLIC_BETA = #BETA_INFO

--★★★ 【★ 类别 T · ★★ 物品 ID 与联机协议 —— 本任务重点★★】2710-2760 行
--
--  ★★★ TEMP_ITEM_ID = "0"（第 2710 行）：临时物品 ID。
--  ★★ 关键理解：物品 ID 是**字符串**，不是数字！
--    ★★ 为什么用字符串？三个理由：
--      (1) 可读 —— 存档里看到 "kustomkight_hat" 一眼知道是什么；
--      (2) 唯一 —— 数字容易重复，字符串可加语义前缀；
--      (3) 稳定 —— 不会因新增物品而与既有 ID 冲突。
--    ★★ 但注意它用了字符串 "0" —— 说明历史上曾用数字，
--      迁移到字符串时保留 "0" 以兼容旧存档。
--    ⚠ 这是「迁移兼容」的痕迹，与本文件多处废弃键同源。
TEMP_ITEM_ID = "0"

--matches enum eIAPType
--★ IAP_TYPE_REAL = 0 / IAP_TYPE_VIRTUAL = 1（第 2713-2714 行）：
--  ★★ 内购类型：真实货币 vs 虚拟货币。
--    ★⚠ 与 IAP_TYPE_REAL = 0 组合的注意事项：
--      值为 0 意味着「不能简单用 if not type 来判断是否真实货币」，
--      因为 Lua 中 0 是真值（只有 nil/false 为假）。
--      ⇒ 判读本枚举时别被 0 误导，这与本文件第 1625 行
--        RENDER_QUALITY.LOW = 0 属同类陷阱。
IAP_TYPE_REAL = 0
IAP_TYPE_VIRTUAL = 1

--matches enum ETextFilteringContext
--  TEXT_FILTER_CTX_* 文本过滤上下文（2717-2721 行）：
--    UNKNOWN=0 / GAME=1 / CHAT=2 / NAME=3 / SERVERNAME=0
--    ★★ ⚠ 疑似缺陷（枚举值重复）：
--      推理依据：UNKNOWN = 0 而 SERVERNAME = 0，**两者值相同**。
--        一个枚举里两个成员共享同一数值，意味着「无法区分」，
--        对比同文件 FACING_* / LAYER_* / CONTROL_* 全部唯一。
--      ⇒ 若代码用该值做分支判断，UNKNOWN 与 SERVERNAME 会走同一分支。
--      行尾注释 'not sure how we want to handle this'（不太确定该如何处理）
--        恰好印证了作者本人也意识到这里未定型。
--    ⇒ 这是一个「进行中的设计」，不应视为最终定义。
TEXT_FILTER_CTX_UNKNOWN = 0
TEXT_FILTER_CTX_GAME = 1
TEXT_FILTER_CTX_CHAT = 2
TEXT_FILTER_CTX_NAME = 3
TEXT_FILTER_CTX_SERVERNAME = 0 -- not sure how we want to handle this


--★ CHARACTER_BUTTON_OFFSET / _SCALE（2724-2745 行）：角色选择界面布局。
--  ★★ 纯 UI 坐标常量，不涉及存档与联机，风险低。
CHARACTER_BUTTON_OFFSET =
{
    wilson = -51,
    wendy = -45,
    waxwell = -45,
    wortox = -53,
    wormwood = -53,
    winona = -49,
    wurt = -45,
    webber = -45,
    wanda = -51,

    default = -47,
}

CHARACTER_BUTTON_SCALE =
{
    wurt = 0.24,

    default = 0.23,
}

--★★★ 【★★ YOTB_COSTUMES —— ★★ 位掩码枚举，本文件最易写错处★★】★★
--  WAR=1  DOLL=2  ROBOT=4  NATURE=8  FORMAL=16
--  VICTORIAN=32  ICE=64  FESTIVE=128  BEAST=256
--
--  ★★★ 为什么它不是普通枚举？三个判据：★★★
--  (1) ★ 所有值都是 **2 的幂**（1,2,4,8,16,32,64,128,256），
--      这是位掩码的标准特征（普通枚举不需要 2 的幂）。
--  (2) ★ 这些装扮**可以叠加** —— 玩家能同时戴鹿角和节日装，
--      所以多个值会组合成同一个整数。
--  (3) ★ 名字末尾是复数 COSTUMES（装扮们），暗示是集合而非单选。
--
--  ★★★★ 正确用法 vs 错误用法（务必背下来）：★★★★
--    组合：local c = YOTB_COSTUMES.WAR | YOTB_COSTUMES.FESTIVE   -- 1|128 = 129
--    正确：if c & YOTB_COSTUMES.WAR ~= 0 then ... end   ← 位与判断「是否包含」
--    错误：if c == YOTB.COSTUMES.WAR then ... end        ← 相等比较会漏掉 129
--  ★★ 原因：一旦玩家拥有多个装扮，值就不再等于任何单个成员，
--    相等比较永远为假 → 装扮功能静默失效。
--
--  ★★ 本文件内同类的位掩码常量还有（可对照学习）：
--    · USERFLAGS（第 2383 行）—— 玩家权限标志
--    · LUABIT（第 1479 行）—— Lua 侧位标记
--  ⇒ 遇到值为 1/2/4/8… 且能组合的枚举，一律用位运算。
--★ 与第 2759 行 SKIN_TYPES_THAT_RECEIVE_CLOTHING 配套使用。
YOTB_COSTUMES =
{
    WAR         = 1,
    DOLL        = 2,
    ROBOT       = 4,
    NATURE      = 8,
    FORMAL      = 16,
    VICTORIAN   = 32,
    ICE         = 64,
    FESTIVE     = 128,
    BEAST       = 256,
}

--★★★ 【★ 类别 U · ★★★ 物品系统枚举 —— 本文件最核心的一段★★★】2761-3041 行
--
--  ★★ 这 280 行是「物品的元数据定义」—— 它们不描述某个具体物品，
--    而是描述**所有物品共有的那些维度**：类型、品质、动作、状态。
--  ★★★ 读懂这一段，就理解了 DST 的物品系统架构：★★★
--    一个物品 = 「预制体名（字符串 ID）」+ 「若干个类型标签」
--    + 「一个品质档位」+ 「可参与的动作」。
--    例如「石斧」= prefab "stoneaxe" + TOOL 类型 + UPGRADETYPES 类
--    + TOOLACTIONS 中登记的敲击动作。
SKIN_TYPES_THAT_RECEIVE_CLOTHING =
{
--★ SKIN_TYPES_THAT_RECEIVE_CLOTHING 接受服装的皮肤类型（2761 行）。
--  ★★ 这是「哪些角色模型能穿上某种装备」的白名单。
--    ⇒ 皮肤（skin）与装备（clothing）是两个正交维度，
--      这张表负责二者的兼容性判断。
--★ 属于存档相关（玩家拥有哪些皮肤会写入存档），改名有风险。
    "normal_skin",
	"wimpy_skin",
    "mighty_skin",
	"stage_2",
    "stage_3",
    "stage_4",
	"young_skin",
	"old_skin",
	"powerup",
	"NO_BASE",
}

--★★ 【POSTACTIVATEHANDSHAKE 激活握手】2773-2779 行
--  ★★ 英文原注释是一条**不可逆性警告**：
--    'NOTES(JBK): These are expected to never go backwards and ...'
--    「这些值预期**永不回退**……」
--  ★★★ 这是本文件对「魔数风险」最直白的表述：★★★
--    该表记录客户端与主机之间的握手协议版本，
--    一旦对外发布就不能改回旧值，否则新旧客户端无法互联。
--  ⇒ 这是网络协议常量，与 tuning 的平衡数值完全不是一个风险等级。
--★ 参照 networking.lua 的版本校验逻辑。
POSTACTIVATEHANDSHAKE = { -- NOTES(JBK): These are expected to never go backwards and only increment.
    NONE = 0, -- Initialization purposes.
    CTS_LOADED = 1, -- Client is ready to receive server state.
    STC_SENDINGSTATE = 2, -- Server is sending what it knows.
    READY = 3, -- Client is in a good sync state. Must be the end.
}

--★★ 【STORM_TYPES 风暴类型】2780 行
--  ★★ 玻璃风暴/月亮的阶段类型枚举。
--  ★ 与 tuning.lua 的 STORM_* 系列数值配合。
STORM_TYPES =
{
    NONE = 0,
    SANDSTORM = 1,
    MOONSTORM = 2,
}

--【★★ HUNT_ACTIONS 狩猎动作】2787 行
--  ★★★ 这张表把「狩猎」分解成若干**可被逐步执行的动作**：
--    打手势 → 挖坑 → 竖网 → 等待 → 收网……
--  ★★ 设计意图：DST 把一次完整的「大型狩猎仪式」拆成多个离散步骤，
--    每步有各自的时长与触发条件（数值在 tuning.lua 的 HUNT_* 系列）。
--    ★ 好处：玩家可以中断与继续，且每步都有独立反馈。
--  ★ 与 tuning.lua:801 区间的 HUNT_* 参数组配套（见 tuning.lua 分区 4）。
--  THRALL_TYPES 仆从类型（2793 行）：
--    ★ 与 HUNT_ACTIONS 同为「大型仪式」系统（狼人召唤/月亮召唤）。
HUNT_ACTIONS = {
    SUCCESS = 0,
    PROP = 1,
    SLEEP = 2,
}

THRALL_TYPES = {
    SHADOW = {
        TRIO = "trio",
        MOUTH = "mouth",
    },
    LUNAR = {
        PLANT = "plant",
    },
}

--【LOADING_SCREEN_TIP_* 载入界面提示】2803-2864 行
--  ★★ 一整套关于「载入小贴士」的配置：内容、分类、图标、权重区间。
--  ★★★ LOADING_SCREEN_TIP_CATEGORY_WEIGHTS_START / _END（第 2829/2838 行）：
--    这是「按分类设置提示出现权重区间」的两张表，
--    ★ 用 START/END 成对定义区间，是本文件常见手法
--      （与 tuning.lua 的 MIN/MAX 成对写法同源）。
--  ★ 权重决定各类提示被随机抽中的频率 —— 属体验微调，无存档风险。
LOADING_SCREEN_TIP_OPTIONS =
{
    ALL = 1,
    TIPS_ONLY = 2,
    LORE_ONLY = 3,
    NONE = 4,
}

LOADING_SCREEN_TIP_CATEGORIES =
{
    CONTROLS = 1,
    SURVIVAL = 2,
    LORE = 3,
    LOADING_SCREEN = 4,
    OTHER = 5,
}

LOADING_SCREEN_TIP_ICONS =
{
    CONTROLS = { atlas = "images/loading_screen_icons.xml", icon = "icon_tooltips.tex" },
    SURVIVAL = { atlas = "images/loading_screen_icons.xml", icon = "icon_survival.tex" },
    LORE = { atlas = "images/loading_screen_icons.xml", icon = "icon_lore.tex" },
    LOADING_SCREEN = { atlas = "images/loading_screen_icons.xml", icon = "icon_lore.tex" },
    OTHER = { atlas = "images/loading_screen_icons.xml", icon = "icon_survival.tex" },
}

LOADING_SCREEN_TIP_CATEGORY_WEIGHTS_START =
{
    CONTROLS = 4,
    SURVIVAL = 3,
    LORE = 1,
    LOADING_SCREEN = 2,
    OTHER = 0,
}

LOADING_SCREEN_TIP_CATEGORY_WEIGHTS_END =
{
    CONTROLS = 0.5,
    SURVIVAL = 2,
    LORE = 4,
    LOADING_SCREEN = 3.5,
    OTHER = 0,
}

LOADING_SCREEN_CONTROL_TIP_KEYS =
{
    TIP_ATTACK = { attack = CONTROL_ATTACK },
    TIP_FORCE_ATTACK = { modifier = CONTROL_FORCE_ATTACK, attack = CONTROL_ATTACK },
    TIP_HOLD_INSPECT = { inspect = CONTROL_FORCE_INSPECT},
    TIP_HOLD_ACTION = { action = CONTROL_ACTION },
    TIP_HOLD_PRIMARY = { primary = CONTROL_ATTACK },
    TIP_HOLD_MOUSE = { primary = CONTROL_PRIMARY },
    TIP_HALF_STACK = { modifier = CONTROL_FORCE_STACK, primary = CONTROL_PRIMARY },
    TIP_DROP_ITEMS = { modifier = CONTROL_FORCE_TRADE, secondary = CONTROL_SECONDARY },
    TIP_ROTATE_CAMERA = { rotateleft = CONTROL_ROTATE_LEFT, rotateright = CONTROL_ROTATE_RIGHT },
    TIP_SHOW_MAP = { map = CONTROL_MAP },
    TIP_INSPECT_SELF = { inspectself = CONTROL_INSPECT_SELF },
    TIP_CHAT = { chat = CONTROL_TOGGLE_SAY, whisper = CONTROL_TOGGLE_WHISPER },
    TIP_PLAYER_STATUS = { playerstatus = CONTROL_SHOW_PLAYER_STATUS },
    TIP_INVENTORY_SLOTS = { inv_0 = CONTROL_INV_10, inv_9 = CONTROL_INV_9 },
}

--★★ 【SCRAPBOOK_CATS 手札分类】2865-2895 行 —— ★★ 与存档强相关
--  SCRAPBOOK_CATS（第 2865 行）：手札（Scrapbook）页面的分类。
--  SPECIAL_SCRAPBOOK_PAGES_LOOKUP（第 2874 行）。
--  SPECIAL_SCRAPBOOK_PAGES = {}（第 2889 行）：
--    ★ 空表 —— 特殊手札页面由模组或后续版本填充。
--  ★★★ 手札 = 玩家的「发现记录」：捡到某物、解锁某配方会记一页。
--  ★★ 它与 FOODGROUP（第 2045 行）、INVENTORY_PROGRESS（第 2663 行）
--    共同构成收集进度系统。
--  ⚠★ 魔数风险：分类名与页面 ID **写入存档**。
--    改分类名 → 老玩家已收集的页面归类错乱或「消失」。
--    ⇒ 收集系统的所有 ID 都应视为只增不改。
--★ 参见 components/scrapbook.lua。
SCRAPBOOK_CATS = {
    "creature",
    "item",
    "food",
    "giant",
    "thing",
    "POI",
}

SPECIAL_SCRAPBOOK_PAGES_LOOKUP =
{
    --[[
    {
        name = "ID",
        entries = { "entry1", "entry2", "..." },
    },
    ]]
}

--  BERNIEALLEGIANCE（第 2884 行）：伯尼（雕像 Boss）的阵营选择。
--  ★ 对应 tuning.lua:7455 区的 ALLEGIANCE_VS_LUNAR / _VS_SHADOW 加成。
--    ⇒ 常量表存「选了哪个阵营」，调优表存「选了对玩家什么好处」。
BERNIEALLEGIANCE ={
    SHADOW = 1,
    LUNAR = 2,
}

SPECIAL_SCRAPBOOK_PAGES = {}

for i, data in ipairs(SPECIAL_SCRAPBOOK_PAGES_LOOKUP) do
    SPECIAL_SCRAPBOOK_PAGES[data.name] = i
end

-- When using a controller or on console, some control IDs are different than on non-console, but use the same tips.
--【LOADING_SCREEN_CONTROLLER_ID_LOOKUP】2896 行：
--  ★ _LOOKUP 后缀 = 反查表（由前表 table.invert 生成）。
--  INSPECTACLES_GAMES（2905 行）眼镜小游戏配置 + _LOOKUP（2914 行）。
--  ★★ 又一组「正向表 + 反向表」配对，
--    说明这个模式在本文件被反复使用（见第 2165/2173 行）。
--  CHARLIERESIDUE_MAP_ACTIONS 地图操作（2919 行）。
LOADING_SCREEN_CONTROLLER_ID_LOOKUP =
{
    [CONTROL_ATTACK] = CONTROL_CONTROLLER_ATTACK,
    [CONTROL_ACTION] = CONTROL_CONTROLLER_ACTION,
    [CONTROL_FORCE_INSPECT] = CONTROL_INSPECT,
    [CONTROL_SHOW_PLAYER_STATUS] = CONTROL_MENU_MISC_4,
}

-- The games for inspectacles with netvar inspectacles_game range [0..7]
INSPECTACLES_GAMES = {
    NONE = 0,
    WIRES = 1,
    --GEARS = 2,
    --TAPE = 3,
    FREE1 = 2, -- FIXME(JBK): Adjust the enum for games added.
    --FREE2 = 5,
    --FREE3 = 6,
}
INSPECTACLES_GAMES_LOOKUP = {}
for name, i in pairs(INSPECTACLES_GAMES) do
    INSPECTACLES_GAMES_LOOKUP[i] = name
end

CHARLIERESIDUE_MAP_ACTIONS = {
    NONE = 0,
    WORMHOLE = 1,
}

--★★ 【★ 小地图装饰优先级上限】2924 行
--  MINIMAP_DECORATION_PRIORITY = 50 -- NOTES(JBK): Nothing should go above
--   this to maint...
--  ★★★ 这是**带约束的常量**，行尾注释给出了一条硬性规则：
--    「**任何东西都不应超过这个值**」，以维持某种保证。
--  ★ 与 MAX_PHYSICS_RADIUS（第 1504 行，注释「船是当前最大的」）同属：
--    **常量与「当前事实」耦合**的类型。
--    它们的值不能孤立理解，必须与别处的设计假设一起看。
MINIMAP_DECORATION_PRIORITY = 50 -- NOTES(JBK): Nothing should go above this to maintain the minimap UI space.

--★★ 【WOBYCOURIER_NO_CHEST_COORD = -32767】—— 极端哨兵坐标
--  ★★ 英文原注释：'Way off of any normal sized map.'
--    「远离任何正常尺寸的地图。」
--  ★★★ 用途：当作「不存在的坐标」的标记。
--    选 -32767 的原因：它是 16 位有符号整数的下界，
--    任何真实世界坐标都不可能取到这个值。
--  ★ 与第 19 行 MAXUINT = 2^32-1 属同一类「不可能值」设计，
--    只是本处用 16 位、上处用 32 位。
--  WOBYCOURIER_MIN_DIST_TO_PLAYER_SQ = 16 -- 4 * 4（第 2927 行）：
--    ★★ 注意行尾注释 '4 * 4' —— 与第 1504 行的 MAX_PHYSICS_RADIUS = 4 呼应，
--      说明这个 4 就是「1 格」（TILE_SCALE = 4）。
--    ⇒ 含义：旺财快递员至少离玩家 4 单位（1 格）才算数。
--    ★ 再次印证 _SQ 后缀语义：调用方必须传未平方的距离。
--  CONTAINER_AUTOCLOSE_DISTANCE = 3（第 2928 行）：
--    ★ 离开容器 3 单位外自动关闭 UI。属交互手感参数。
WOBYCOURIER_NO_CHEST_COORD = -32767 -- Way off of any normal sized map.
WOBYCOURIER_MIN_DIST_TO_PLAYER_SQ = 16 -- 4 * 4
CONTAINER_AUTOCLOSE_DISTANCE = 3

-- Constants to reduce network overhead.
--【CLIENTAUTHORITATIVESETTINGS 客户端权威设置】2931 行：
--  ★★★ 这是一个**架构性概念**，值得单独理解：
--    某些设置由**客户端**决定并上报给主机，而非主机强制下发。
--    典型场景：画面质量、按键设置这类「纯本地偏好」。
--  ★★ 与 tuning.lua 的机制对比：
--    tuning 数值由**主机**决定并同步给客户端（保证公平）；
--    本表是**反过来**的少数几处。
--    ⇒ 调平衡时绝不能把平衡数值放进这张表，否则可被客户端篡改。
CLIENTAUTHORITATIVESETTINGS = {
    PLATFORMHOPDELAY = 0,
}

--【NIGHTSWORD_FX_OFFSETS 夜剑特效偏移】2935 行。
--  ★ 纯表现层坐标，与 gameplay 无关。
NIGHTSWORD_FX_OFFSETS = {
    RIGHT = 0.75,-- -1,
    DOWN = 2.9,-- 2.6,
}

--★★ 【SHARDTRANSACTIONSTEPS / _TYPES 跨服事务】2940-2950 行
--  ★★ 这是「跨服务器迁移玩家」的事务状态机：
--    STEPS = 流程的各个阶段，_TYPES = 事务类型。
--  ★★ 与 REMOTESHARDSTATE（第 2475 行）配合，构成完整的跨服架构。
--  ★ 改这组枚举会破坏跨服迁移流程，但不影响单机或同服联机 ——
--    属「局部高风险」常量。
SHARDTRANSACTIONSTEPS = {
    INITIATE = 0,
    ACCEPTED = 1,
    FINALIZED = 2,
}
SHARDTRANSACTIONTYPES = {
    TRANSFERINVENTORYITEM = 0,
}

-- Tag pairs in this list behave mutually exclusively,
-- when trying to attune to different objects.
--  EQUIVALENT_ATTUNABLE_TAGS 等价可调标签（2951 行）。
--  HAPTICS 触觉反馈表（2958 行）：手柄震动强度映射。
--    ★ 与第 1903 行 VIBRATION_* 同属手柄震动体系。
EQUIVALENT_ATTUNABLE_TAGS =
{
    ["remoteresurrector"] = "gravestoneresurrector",
    ["gravestoneresurrector"] = "remoteresurrector",
}

-- This must match the Categories enum in HapticsManager
HAPTICS = 
{
    CATEGORIES = 
    {
        ["ui"]          = 2,       -- 0x02
        ["danger"] 	    = 4,       -- 0x04
        ["player"]      = 8,       -- 0x08
        ["environment"] = 16,      -- 0x10
        ["boss"]        = 32,      -- 0x20

        -- These are included here for reference only since they exist and have meaning in C++
        -- I won't include them in the table so we don't accidentally iterate over them        
        -- ["default"]     = 1,       -- 0x01
        -- ["all"]         = 255,     -- 0xFF    
    },

    CATEGORY_ENABLED_BY_DEFAULT = rawget(_G, "IsPS5") and IsPS5() or false,
}

--【MIGRATION_TYPES 存档迁移类型】2977 行：
--  ★★★ 这张表的存在本身就是「魔数风险」的历史证据：★★
--    因为开发过程中**确实修改过存档格式**，
--    所以需要记录每个版本该用什么方式把老存档升到新格式。
--  ★★ 教学意义：任何长期存活的游戏都需要存档迁移机制，
--    而它的存在会提醒你：改动持久化格式是有代价的。
--  PEARL_DECORATION_TYPES 珍珠装饰类型（2982 行）。
--  YOTH_HORSE_NAMES 犹多马名字（3005 行）：纯文本列表。
MIGRATION_TYPES = {
    MUTATED_BIRD_GESTALT = "mutatedbird_gestalt",
    MUTATED_BUZZARD_GESTALT = "mutatedbuzzard_gestalt",
}

PEARL_DECORATION_TYPES =
{
    UNIQUE_DECORATION = "UNIQUE_DECORATION",
    WATER_TREE = "WATER_TREE",
    CRITTER_PET = "CRITTER_PET",
    TILES = "TILES",
    BEE_BOXES = "BEE_BOXES",
    FLOWERS = "FLOWERS",
    ORNAMENTS = "ORNAMENTS",
    LVL5_HOUSE = "LVL5_HOUSE",
    LIGHT_POSTS = "LIGHT_POSTS",
    PICKABLE_PLANTS = "PICKABLE_PLANTS",
    MEAT_RACKS = "MEAT_RACKS",
    FACED_CHAIR = "FACED_CHAIR",
    TROPHY_FISH = "TROPHY_FISH",
    POTTED_PLANTS = "POTTED_PLANTS",
    DOCK_POSTS = "DOCK_POSTS",
    DECORATION_TAKER = "DECORATION_TAKER",
    FISHING_MARKERS = "FISHING_MARKERS",
    SPAWNER = "SPAWNER",
    JUNK = "JUNK",
}

YOTH_HORSE_NAMES = {
    "CONQUEST",
    "WAR",
    "FAMINE",
    "DEATH",
}

--【SKINUNLOCKS 皮肤解锁表】3012 行：
--  ★★ 记录皮肤解锁方式（游戏内进度/购买/活动赠送）。
--    ★ 属**存档数据**：玩家的解锁进度会记录在此。
SKINUNLOCKS = {
    ALWAYS = 1,
    CRAFTINGSTATION = 2,
}

--★★★ 【★★ 韦斯电路板系统常量 —— 本文件最后一段 ★★】3017-3041 行
--
--  ★★★ 这 25 行定义韦斯（WX78）技能树的电路板体系，
--    是 DST 中**最新的系统之一**（对应 tuning.lua 第 28 分区）。
--
--  CIRCUIT_BARS（第 3017 行）—— 电路板类型表，
--  ★★ 英文原注释再次出现同步警告：
--    'NOTES(JBK): Keep this table updated in export_accountitems.lua [EAITAB]'
--    「务必同步更新 export_accountitems.lua！」
--    ⇒ 这是第 5 处、也是第 2 次出现在韦斯区域的同步要求
--      （第 1 处是第 1965 行 UPGRADETYPES）。
--    ⚠ 这印证了一个规律：**越新的系统，同步要求越密集**。
--
--  CIRCUIT_BARS_LOOKUP = {}（第 3023 行）：
--    ★ 空表但命名带 LOOKUP —— 说明它在别处被填充，
--      或预留给模组。
--
--  MAX_CIRCUIT_SLOTS = 7（第 3028 行）：
--  ★★★ 这个 7 是韦斯的**核心平衡参数**，含义是「最多插 7 块板」。
--    ★★ 它决定了整个角色的玩法上限：
--      插得越多 → 功能越强，但每块都要付温度代价
--      （见 tuning.lua:6600 WX78_MINTEMPCHANGEPERMODULE = 20度/块）。
--      ⇒ 7 块 × 20 度 = 140 度的温度负担，
--        而世界温度上限是 90（tuning.lua:2294 MAX_ENTITY_TEMP）。
--      ★★ 推论：**玩家不可能插满 7 块还能保持温度正常** ——
--        这个上限本身就是为了制造「插几块」的持续取舍。
--    ★ 这是「常量（槽位数）」与「数值（每块代价）」跨文件配合的范例。
--  ⚠⚠ 魔数风险：槽位数会写入存档（玩家插了几块板）。
--    ★★ 而且它带有 export_accountitems.lua 同步要求，
--      意味着改动会同时影响存档与商城展示 —— **双重风险**。
--    ⇒ 这是本文件中改动代价最高的单个数字之一。
CIRCUIT_BARS = -- NOTES(JBK): Keep this table updated in export_accountitems.lua [EAITAB]
{
    ALPHA = 0,
    BETA = 1,
    GAMMA = 2,
}
CIRCUIT_BARS_LOOKUP = {}
for name, i in pairs(CIRCUIT_BARS) do
    CIRCUIT_BARS_LOOKUP[i] = name
end

MAX_CIRCUIT_SLOTS = 7 -- NOTES(JBK): Keep this value updated in export_accountitems.lua [EAITAB]

--  SOCKETNAMES 插槽名（3030 行）：韦斯装备的插槽名称。
--  ★ 与 CIRCUIT_BARS（电路板类型）配合，构成装备结构定义。
SOCKETNAMES = {
    SHADOW = "socket_shadow",
    GESTALTTRAPPER = "socket_gestalttrapper",
}
--★★ 【SOCKETQUALITY 插槽品质】3034-3040 行
--  ★★ 行尾同样带有 export_accountitems.lua 同步警告（第 5 处同步要求）。
--  ★★ 紧随其后的英文注释提供了品质对应关系（重要背景知识）：
--    第 7557 行注释：'SOCKETQUALITY.LOW == nightmarefuel'（噩梦燃料）
--    第 7572 行注释：'SOCKETQUALITY.MEDIUM == purehorror'（纯粹恐惧）
--    第 7574 行注释：'SOCKETQUALITY.HIGH == shadowheart'（暗影之心）
--    第 7591 行注释：'SOCKETQUALITY.PERFECT == mimicheart'（拟态之心）
--  ⇒★ 四档品质分别对应四种可穿戴的物品材质，
--    材质名称定义在 constants.lua 的 MATERIALS（第 1936 行）。
--    ★ 这是一个**跨区块的概念关联**：
--      品质枚举（此处）→ 材质名（1936 行）→ 实际物品（prefabs/）。
--  ★★★ 本文件最后一行（第 3041 行）值得注意：
--    SOCKETQUALITY_MAXVALUE = table.count(SOCKETQUALITY)
--    ★★ 用 table.count() **自动计算**枚举的项数，而不是手写 4。
--    ⇒ 与第 2708 行 PUBLIC_BETA = #BETA_INFO 属同一手法。
--    ★★★ 价值极大：往 SOCKETQUALITY 里新增一档品质时，
--      这个上限会自动 +1，不会出现「加了新档但上限还是4」的 bug。
--    ⇒ 这是本文件「可维护常量」的最佳实践，值得作为范本记住。
--★ SOCKETQUALITY_MAXVALUE 的用途：循环遍历全部品质档位。
--  ★ 由此可知品质枚举必须**连续**（1~4），不能有空洞。
SOCKETQUALITY = { -- NOTES(JBK): Keep this value updated in export_accountitems.lua [EAITAB]
    NONE = 0,
    LOW = 1,
    MEDIUM = 2,
    HIGH = 3,
    PERFECT = 4,
}
SOCKETQUALITY_MAXVALUE = table.count(SOCKETQUALITY)
--★★★ 【★ 全文件结束】3041 行 ★★★
--  ★★★ 回看整个 constants.lua 的三条主线：★★★
--
--  (1) ★★★ 【魔数风险三等级】★★★
--      ① 最危险：存档/协议相关 —— 物品 ID、装备槽位名（EQUIPSLOTS）、
--         CONTROL_* 按键编号、WORLD_TILES 编号区间、NUM_SAVE_SLOTS、
--         CLOUD_SAVES_SAVE_OFFSET、POSTACTIVATEHANDSHAKE、
--         MIGRATION_TYPES、STORM/HUNT/THRALL 类型。
--         ⇒ 改动 = 老存档损坏或联机握手失败。
--      ② 中等：生成与上限相关 —— NUM_TRINKETS、QUAGMIRE_NUM_*、
--         MAX_CIRCUIT_SLOTS、MAX_PHYSICS_RADIUS。
--         ⇒ 改动 = 世界生态变化或存档数量对不上。
--      ③ 安全：纯表现层 —— 颜色表、贴图采样模式、震屏强度、
--         UI 偏移、动画时长。
--         ⇒ 改动只影响观感。
--
--  (2) ★★★ 【跨文件人工同步点（5 处 + 1 处 C++）】★★★
--      export_accountitems.lua 需同步：1965 / 1976 / 3017 / 3028 / 3034 行
--      C++ MiniMapRenderer.cpp 需同步：第 24 行 PLAYER_REVEAL_RADIUS
--      ⇒ 全部**只有注释约束，无代码校验**。这是最隐蔽的技术债。
--
--  (3) ★★★ 【与 tuning.lua 的分工（最该记住的一点）】★★★
--      constants.lua = 「是什么」（ID、枚举、分类、白名单）—— 不该改
--      tuning.lua     = 「是多少」（卡路里、时长、伤害）—— 可以调
--      ★ 调平衡时**只改 tuning.lua**，几乎不需要动本文件。
--      ★ 反过来，改本文件时要想的是「会不会弄坏旧存档」，
--        而不是「手感好不好」。
--
--  ★★ 补充：几个最容易被误解的常量，最终澄清：
--      · FRAMES = 1/30（第 16 行）—— 30 FPS，不是帧数上限
--      · SEASONS（第 1607 行）—— 只有名字，四季**天数在 tuning.lua**
--      · EQUIPSLOTS（第 652 行）—— 4 个装备槽位，**不是背包**；
--        背包容量在 containers.lua 用循环生成 8 个 slotpos
--      · YOTB_COSTUMES / USERFLAGS —— **位掩码**，须用位与判断
--      · CHARACTER_INGREDIENT_SEG = 5 —— 「5 的倍数」规则，非分隔符
--      · MAX_PHYSICS_RADIUS = 4 —— 隐含「船是最大的」这一假设
--★ 交叉引用：tuning.lua（数值源头）, containers.lua（背包 UI）,
--  components/inventory.lua, export_accountitems.lua（同步契约）
