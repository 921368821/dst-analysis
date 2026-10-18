// spec-constants-p2.mjs —— H~L 类：世界事件、理智模式、世界生成技术、★季节★
// 覆盖源文件行号区间：781 - 1650

export const BEFORE = {
  781: [
    "--【★ 类别 H · 世界事件与音乐】790-1228 行",
    "--  ★★ 本区的核心是「事件 ID 字符串」，它们决定加载哪个事件脚本。",
    "--  ★★ 这些字符串会写进存档（世界记录了「本局发生过什么事件」）——",
    "--    改名会导致旧存档的事件状态丢失。",
  ],

  837: [
    "--★★★ 【SPECIAL_EVENTS —— 特殊世界事件】837-853 行",
    "--  这是一张「事件名 → 数值 ID」的映射表。",
    "--  ★★ 为什么用字符串键 + 数字值？",
    "--    · 字符串是可读的事件名（axe_fight、lunar_curse 等）",
    "--    · 数字值是内部索引，便于数组化处理与排序",
    "--  ★★ 后面第 889-895 行会据此拼出 prefab 名：",
    "--      SPECIAL_EVENT_GLOBAL_PREFABS = { WORLD_SPECIAL_EVENT..\"_event_global\" }",
    "--    ⇒ 事件名 \"axe_fight\" 自动派生出 prefab \"axe_fight_event_global\"。",
    "--      ★ 这是「命名约定驱动资源加载」的典型手法：新增事件只要起对名字，",
    "--        资源就能被自动找到，无需改加载代码。",
    "--★★⚠ 魔数风险：事件名同时是「存档中的键」与「prefab 名的前缀」，",
    "--    两处强耦合。改名会同时破坏存档兼容与资源加载。",
  ],

  854: [
    "--  WORLD_SPECIAL_EVENT = SPECIAL_EVENTS.CARNIVAL（第 854 行）：",
    "--    ★★ 当前生效的特殊事件 = 嘉年华。注意这是**指向某个成员的引用**，",
    "--      而不是写裸字符串。",
    "--  ★★ 这种「默认事件」的写法便于模组覆盖：",
    "--      改这一个赋值即可切换整个活动周期。",
    "--  WORLD_EXTRA_EVENTS = {}（第 855 行）：额外事件列表（空表 = 扩展点）。",
  ],

  857: [
    "--★ 【FESTIVAL_EVENTS 节庆事件】857-862 行。",
    "--  ★ 节庆事件与特殊事件是**两套独立机制**：",
    "--    SPECIAL_EVENTS  → 影响世界生成/玩法（如嘉年华）",
    "--    FESTIVAL_EVENTS → 影响节庆装饰与掉落（如新年、冬季盛宴）",
    "--  WORLD_FESTIVAL_EVENT = FESTIVAL_EVENTS.NONE（第 863 行）。",
  ],

  864: [
    "--★★★ 【PREVIOUS_FESTIVAL_EVENTS —— 「历届节庆顺序」记录】864-871 行",
    "--  PREVIOUS_FESTIVAL_EVENTS = { LAVAARENA, QUAGMIRE } --deprecated, use PREVIOUS_FESTIVAL_EVENTS_ORDER",
    "--    ★★ 行尾英文原注释明确标注 'deprecated'，并指明替代者。",
    "--  PREVIOUS_FESTIVAL_EVENTS_ORDER（第 865-870 行）：",
    "--      { id = LAVAARENA, season = 2 },",
    "--      { id = QUAGMIRE,   season = 1 },",
    "--      { id = LAVAARENA,  season = 1 },",
    "--",
    "--  ★★★ 逐条解读这个「表的历史」——它记录的不是玩家数据，而是",
    "--    ★★ **节庆活动按年份推进的排期表**：",
    "--      第 1 条：第 2 个节庆周期是熔岩竞技场（season=2 那一季）",
    "--      第 2 条：第 1 个节庆周期是沼泽（season=1 那一季）",
    "--      第 3 条：更早的第 1 周期又是熔岩竞技场",
    "--    ⇒ 可见节庆在两个内容间**交替轮换**，且season 字段记录它落在哪一季。",
    "--  ★★ 这解释了为什么需要这张表：世界要知道「第几个节庆周期」，",
    "--    才能决定当前该加载哪个节庆 prefab。",
    "--  ★★⚠ 魔数风险：这张排期表与存档中的「已过节庆数」配合使用，",
    "--    调整顺序会导致老存档的节庆进度错位。",
    "--  ★★ 命名识别法：PREVIOUS_ 前缀 = 需要持久化的历史快照；",
    "--    _ORDER 后缀 = 带顺序语义（与无序集合 PREVIOUS_FESTIVAL_EVENTS 区分）。",
  ],

  872: [
    "--★ IS_YEAR_OF_THE_SPECIAL_EVENTS（第 872-888 行）：",
    "--  ★「是否为特定年份」的特殊处理表。用于节庆主题逐年轮换。",
  ],

  889: [
    "--★★ 【★ 事件 prefab 名派生规则】889-895 行 —— 命名约定驱动的加载",
    "--  SPECIAL_EVENT_GLOBAL_PREFABS = { WORLD_SPECIAL_EVENT..\"_event_global\" }",
    "--  SPECIAL_EVENT_BACKEND_PREFABS = { ..\"_event_backend\" }",
    "--  SPECIAL_EVENT_FRONTEND_PREFABS = { ..\"_event_frontend\" }",
    "--  FESTIVAL_EVENT_* 三行同理，后缀是 \"_fest_*\"。",
    "--  ★★ 规律总结：<事件名> + _event_global / _event_backend / _event_frontend",
    "--    ⇒ 每个事件需配套三个 prefab（全局状态 / 后端逻辑 / 前端表现）。",
    "--  ★ 这解释了为什么 SPECIAL_EVENTS 每个事件都要准备三套资源。",
  ],

  903: [
    "--【SPECIAL_EVENT_MUSIC 事件音乐】903-1212 行（★本区最大表）",
    "--  ★★ 约 300 行全是「事件 → 曲名」映射，每行一个曲名。",
    "--  ★ 这是纯数据区，逐行无信息量，跳读即可。",
    "--  ★★ 唯一注意点：曲名是字符串 ID，对应 musics/ 目录下的音频文件。",
    "--    与事件名同理，改名会导致音乐加载失败。",
  ],

  1051: [
    "--  FE_MUSIC = (第 1051 行)：前端菜单音乐（一个长表达式）。",
    "--    ★ 前端音乐与事件音乐是分开的 —— 前端不该播放活动曲。",
  ],

  1213: [
    "--★ 【PICKUPSOUNDS 拾取音效】1213-1228 行：物品 → 拾取音。",
  ],

  1229: [
    "--【★ 类别 I · 万圣节计数与 ★理智模式★】1229-1236 行",
    "--★★ 【SANITY_MODE —— 理智状态枚举】1235 行",
    "--  SANITY_MODE_INSANITY = 0（发疯）",
    "--  SANITY_MODE_LUNACY  = 1（月狂）",
    "--  ★★★ 这两个是 DST 最核心的机制开关，必须理解：★★★",
    "--    正常态（sanity 65~170）：玩家正常，理智缓慢变化",
    "--    变疯（sanity < 30）：SANITY_MODE_INSANITY",
    "--      ⇒ 只能操作影子（幻象），无法直接攻击/使用多数物品",
    "--    月狂（sanity > 200）：SANITY_MODE_LUNACY",
    "--      ⇒ 持续掉理智，但能力增强、且不会被打死",
    "--  ★★ 判定阈值见 tuning.lua 的 SANITY_BECOME_* 系列（0.15~0.85 比例）。",
    "--    ⚠ 魔数风险：这两个值与存档中的玩家状态对应，",
    "--      交换 0/1 会让所有玩家的理智模式判定反转。",
    "--★ 参见 components/sanity.lua（本项目已深度注释）。",
  ],

  1230: [
    "--  NUM_HALLOWEENCANDY = 14 / NUM_HALLOWEEN_ORNAMENTS = 6",
    "--  NUM_HALLOWEEN_PUMPKINCARVERS = 3 / NUM_WINTERFOOD = 9",
    "--  ★★ 这类 NUM_* 数量常量是「节日道具的收集上限」。",
    "--  ★★⚠ 魔数风险：数量会写进存档（玩家收集了几个）。",
    "--    若把 14 改成 10，老玩家已收集的 12 个会「超出上限」，",
    "--    导致 UI 显示异常或道具被吞。",
    "--  ★ 与 tuning.lua:1603 NUM_TRINKETS = 46 属同一类约定。",
  ],

  1237: [
    "--【★ 类别 J · ★世界生成技术图（TECH）★】1237-1341 行",
    "--  ★★ TECH 表是「科技树」的定义源：决定研究点如何解锁配方。",
    "--  ★★ 这是整个游戏的进度骨架 —— 所有可研究项的依赖关系都在这里。",
    "--★ 消费方：components/techtree.lua、playercontroller.lua（研究点）。",
  ],

  1342: [
    "--★ 【NODE_TYPE / NODE_INTERNAL_CONNECTION_TYPE】1342-1364 行：",
    "--  ★ 技术图的节点类型（建筑/材料/工具…）与内部连接方式。",
    "--★ MAZE_TYPE / MAZE_CELL_EXITS（1374-1434 行）：迷宫类型与出口方向。",
    "--  ★ 迷宫用于洞穴与特殊世界生成，出口方向决定刷怪与掉落布局。",
  ],

  1435: [
    "--【★ LAYOUT / LAYOUT_POSITION / LAYOUT_ROTATION】1435-1458 行：",
    "--  ★ 世界布局（手写布局关卡）的方位与旋转枚举。",
    "--  PLACE_MASK（1459 行）：放置遮罩，限制哪些格子能放建筑。",
    "--★ 关联 tuning.lua:3858 附近的 DEPLOYSPACING 枚举（本文件另有 DEPLOYMODE）。",
  ],

  1479: [
    "--★ 【LUABIT / COLLISION】1479-1504 行：",
    "--  LUABIT（1479 行）：Lua 侧的位标记（bitmask）。",
    "--    ★ 与 YOTB_COSTUMES 同属「位掩码」用法：多个标志可组合在一个整数里。",
    "--    ★★ 这类常量的正确用法是位与 (bit and)，不是相等比较 ——",
    "--      详见文件头对 YOTB_COSTUMES 的说明。",
    "--  COLLISION（1488 行）：碰撞层定义。",
    "--  MAX_PHYSICS_RADIUS = 4 --boats are currently the largest.（第 1504 行）：",
    "--    ★★ 这是全文件**唯一一处会变的设计上限**：",
    "--      值 4 = 1 个 TILE（因为 TILE_SCALE=4），即物理体积上限为 1 格。",
    "--      英文注释 'boats are currently the largest' 「船是当前最大的」，",
    "--      暗示若将来有更大的载具，这个上限需要提高。",
    "--      ⚠ 这是「魔数与现实耦合」的典型：数值不能随便改，",
    "--        它隐含假设「没有比船更大的东西」。",
  ],

  1506: [
    "--【★ BLENDMODE 混合模式 / ANIM_ORIENTATION 动画朝向】1506-1524 行",
    "--  BLENDMODE：贴图叠加方式（正常/相加/相乘…），纯表现层。",
    "--  ANIM_ORIENTATION：动画帧朝向处理。",
    "--  ★ ANIM_ORIENTATION.Default = ANIM_ORIENTATION.BillBoard（第 1523 行）：",
    "--    显式设置默认值为「公告板模式」（永远朝向镜头）。",
    "--    ★ 这是给美术/策划的默认兜底，避免每个动画都单独指定。",
  ],

  1525: [
    "--【★ 类别 K · 配方分类（RECIPETABS）】1525-1587 行",
    "--  RECIPETABS（第 1525 行）：合成配方的分类标签（工具/战斗/食物…）。",
    "--  CUSTOM_RECIPETABS（1563 行）：模组自定义分类的扩展点。",
    "--  QUAGMIRE_RECIPETABS（1578 行）：沼泽世界**独有**的配方分类。",
    "--    ★★ 说明不同世界类型会启用不同的配方分类表。",
    "--  ★ 配方本身不在本文件，而在 prefabs/recipes/ 与 cooking.lua。",
  ],

1588: [
    "--【★ VERBOSITY / RENDERPASS】1588-1602 行",
    "--  VERBOSITY（1588 行）：日志详细级别（开发期用）。",
    "--    ★ 只影响 print 输出的冗长度，与玩法无关。",
    "--  RENDERPASS（1596 行）：渲染通道定义（决定绘制顺序）。",
    "--    ★ 与第 56 行的 LAYER_* 配合：LAYER 定批次，RENDERPASS 定批内顺序。",
  ],

1603: [
    "--★★ 【NUM_TRINKETS 与万圣节区间】1603-1605 行",
    "--  NUM_TRINKETS = 46 / HALLOWEDNIGHTS_TINKET_START = 32 / _END = 46",
    "--    ★★★ 「分段编号」的清晰范例：",
    "--      小饰品编号空间为 0~46，其中 32~46 段专属于万圣节。",
    "--    ★★ 设计要点：节日内容占据编号区间的尾部，",
    "--      这样每年新增节日只需往后扩，不必打乱既有编号 ——",
    "--      这正是本文件反复强调的「编号只增不复用」原则。",
    "--    ★★⚠ 魔数风险：编号会写入存档（玩家拥有哪号小饰品）。",
    "--      与第 1229 行的 NUM_HALLOWEENCANDY 等数量常量同理，",
    "--      调小上限会吞掉玩家已收集的道具。",
  ],

  1607: [
    "--★★★ 【★ 类别 L · ★★★ 季节定义 —— 本任务重点区域 ★★★】1607-1615 行",
    "--  SEASONS =",
    "--  {",
    "--      AUTUMN = \"autumn\",",
    "--      WINTER = \"winter\",",
    "--      SPRING = \"spring\",",
    "--      SUMMER = \"summer\",",
    "--      CAVES = \"caves\",",
    "--  }",
    "--",
    "--  ★★★ 首先必须澄清（避免常见误解）：★★",
    "--  ★★ 本文件只定义了季节的**名字**，完全没有「四季天数」。",
    "--    推理依据：四季天数（AUTUMN_LENGTH=20 等）位于 tuning.lua:2218-2221，",
    "--      属于可调数值而非常量。",
    "--  ★★ 五项的排列顺序有讲究：",
    "--    AUTUMN(秋) → WINTER(冬) → SPRING(春) → SUMMER(夏)",
    "--    ★ 这是游戏的**默认季节推进顺序**，即第 1 季秋天。",
    "--    ⚠ 若调换顺序会让新世界从别的季节开始 ——",
    "--      这会影响温度、植被、刷怪表，不是纯显示变化。",
    "--  ★★ 第 5 项 CAVES = \"caves\" 并非四季之一：",
    "--    它表示「洞穴世界的季节命名」，与地表的四季循环平行存在。",
    "--    ⇒ 5 个名字对应「4 个地表季节 + 1 套洞穴季节」。",
    "--",
    "--  ★★★ ★★ 本文件最需要警惕的一点（务必读完）：★★",
    "--  ★★ 这些季节名字（\"autumn\" 等）是**写入存档的字符串 ID**。",
    "--    components/worldstate.lua:239-243 会把它们连同天数写进存档：",
    "--        self.data.autumnlength = TUNING.AUTUMN_LENGTH",
    "--    ⇒ 若把 \"autumn\" 改成 \"fall\"：",
    "--      · 所有老存档的季节判断会失效（找不到 \"fall\" 这个 season）",
    "--      · 季节进度可能重置或卡住。",
    "--    ⇒ **季节名与天数都可以改，但季节名改了必然破坏老存档。**",
    "--      天数改了只影响新世界的难度，老存档自带天数，不受影响。",
    "--★ 消费方：components/worldstate.lua（季节推进）、",
    "--  map/forest_map.lua（地图生成）、components/seasons.lua（季节效果）。",
    "--★ ★★ 相关数值见 tuning.lua 的季节段：",
    "--    2218-2221 AUTUMN/WINTER/SPRING/SUMMER_LENGTH = 20/15/20/15",
    "--    2226-2235 SEASON_LENGTH_* 预设（FRIENDLY/HARSH 世界难度）",
  ],

  1616: [
    "--★ LEVELCATEGORY（第 1616 行）：世界设置的分类标签。",
    "--  RENDER_QUALITY（1623 行）LOW=0 / DEFAULT=1 / HIGH=2：",
    "--    ★★ 三档画质。注意 LOW=0 —— 0 通常是「无/关闭」的值，",
    "--      这里 LOW 恰好为 0，所以判断画质时要注意别写成 if not quality。",
    "--  ANIM_SORT_ORDER（1630 行）：动画排序层。",
    "--  ★★ 与 tuning.lua 的 LAYER_* 渲染图层分工不同：",
    "--    LAYER_*（第 56 行）= 渲染批次层级",
    "--    ANIM_SORT_ORDER = 批次内的排序顺序",
  ],

  1648: [
    "--★ ROAD_PARAMETERS（1648 行）：路面移动参数（移速加成、脚步声等）。",
    "--  ★ 消费方见 worldstate.lua 或 locomotor 的地面检测。",
  ],
};

export const AFTER = {};