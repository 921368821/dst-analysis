--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：prefabs/world.lua
-- 模块：世界预制体（World Prefab）/ 全局事件总线 / 实体注册表
-- 职责：定义「世界」这个预制体本身。承担世界资源与预制体清单的声明、
--       地图渲染层（render layer）与碰撞集的建立、23 个管理器组件的装配、
--       全局单例 TheWorld / TheFocalPoint 的建立与销毁、
--       以及 TheWorld 作为「全局事件总线」的那一半职责。
-- 关键符号：MakeWorld, PostInit, OnRemoveEntity, CreateTilePhysics,
--           OnPlayerSpawn, DoGameDataChanged, OnGameDataChanged,
--           SetPocketDimensionContainer, CanFlyingCrossBarriers
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：main.lua:289（Ents 全局表）、entityscript.lua（事件机制）,
--           prefabs/world_network.lua:57-59（clock / seasons 等时钟类组件）,
--           networking.lua:498 JoinServer / :849 StartDedicatedServer,
--           shardnetworking.lua（分片网络）、update.lua:42（WallUpdate 驱动）
--           TheNet / TheShard / TheSim 均为 C++ 侧对象，无 Lua 源码
--============================================================
--
--【阅读导航】
--  §零   依赖与资源清单（1-66）        —— 世界预制体为什么自带 asset 依赖
--  §一   预制体清单（68-296）           —— ★ world prefab 是「全预制体」的根
--  §二   玩家出生与游戏数据（298-333） —— 两级 DoTaskInTime 合并广播
--  §三 ★ PostInit（335-355）           —— 装配收尾 + 状态变更自动推送
--  §四   销毁与碰撞集（357-397）       —— TheWorld 单例的断言式拆解
--  §五 ★★ MakeWorld 工厂（401-616）   —— 本文件的心脏
--  §六   单例建立时序（414-437）       —— ★ TheWorld 在第 422 行被赋值
--  §七   底层组件装配（439-457）       —— 五个 C++ 侧实体组件
--  §八   地图渲染层建立（459-523）     —— 三轮循环：地面/苔藓/衰减
--  §九 ★★ 23 个管理器组件（525-610）   —— 逐个职责说明，见下方清单
--  §十   入口（615-618）               —— Prefab() 与 MakeWorld 的自我调用
--
--【本文件最重要的八条】
--  1. ★★「世界」是一个 prefab，不是引擎里的特殊对象。
--     TheWorld 的类型是 Entity，寿命受普通实体的 Remove/DoTaskInTime 管理。
--     这一个决定统一了「世界」与「实体」：世界能加组件、能监听事件、能被遍历。
--     参见第 401 行的 MakeWorld 与第 615 行的 Prefab() 封装。
--  2. ★ 全局事件总线 = TheWorld 自己。TheWorld:PushEvent / inst:ListenForEvent
--     走的是 entityscript.lua 的实体事件机制，只是**换了个实体当总线**。
--     答案在 entityscript.lua:2966 ListenForEvent 与 :3156 PushEvent_Internal：
--     事件能力是所有实体共有的，TheWorld 恰好是寿命最长、谁都可达的那个。
--     命名空间 `ms_` 前缀是给「服务端世界」事件的固定约定（如 :349 ms_* 监听）。
--  3. ★★ Ents 表是全局实体注册表，键是 GUID。定义在 main.lua:289，
--     不是本文件；本文件第 305 行是它最典型的读法（全表遍历找玩家）。
--     遍历 Ents 代价与实体总数成正比，见该行的性能注记。
--  4. ★★★ ismastersim（第 426 行）是**端判定**的唯一权威：
--     主机与专服为 true，纯客户端为 false。第 348 行与第 564 行两处用它分流。
--     第 427 行的 ismastershard 进一步区分「主分片」——多分片集群里
--     洞穴分片虽然也是 master sim，但不是 master shard。
--  5. ★ 组件装配被三层条件切开：全部端 525-562 → 非专服 553-557 → 主 sim 568-610。
--     第 564-566 行的提前 return 是整个函数的性能命门：客户端在此直接返回。
--  6. ★★ 第 417-420 行的重复世界检查会 `print` 后 return nil，
--     但此时 CreateEntity() 已经执行（第 415 行），实体已被创建却不会被清理。
--  7. 第 358-365 行的销毁顺序：先删 minimap，再断言 TheWorld 就是自己，
--     然后清空 TheWorld 与 TheFocalPoint。断言（assert）是防止误删的护栏。
--  8. ★ 第 501-502 行 StartHop 的一对互斥断言是「参数自洽性校验」的范本：
--     has_platform 与 platform 是否为 nil 必须相反。这类校验在 networkclientrpc.lua
--     里被系统化为 check*/opt* 谓词（networkclientrpc.lua:4-13）。
--
--【★ 23 个管理器组件逐个职责（源文件第 525-598 行，条件不同）】
--  —— 全端无条件（525-562），客户端也需要 ——
--   :525 worldsettings          世界设置键值袋 + 监听 ms_setworldsetting
--                              （见 components/worldsettings.lua，仅 23 行）
--   :528 worldstate             ★ 世界 Lua 状态（cycles/season 等）的所有者，
--                              :529 把 inst.state 直接别名到它的 data
--   :532 groundcreep            地表苔藓/地衣的渲染与铺设（配合 :447 AddGroundCreep）
--   :559 walkableplatformmanager 可站平台（船/矿车）的全局登记表与容量仲裁
--                              （配合 walkableplatform.lua；locomotor 的跳跃预约对象）
--   :561 waterphysics           水体物理，:562 restitution=0.75 即水面弹性
--  —— 仅非专服（553-557，客户端也要）——
--   :554 oceancolor             海水颜色渐变表现，纯客户端表现层
--   :555 nutrients_visual_manager 土壤营养的视觉表现（不含逻辑，逻辑在 farming_manager）
--   :556 hudindicatablemanager   HUD 图标的全局注册与显示仲裁
--  —— 仅主模拟（568-610，客户端在 :565 已 return）——
--   :568 shardtransactionsteps  ★ 跨分片事务的分步提交（仅 master sim，
--                              次分片另有 shard_mermkingwatcher，见 shardnetworking.lua:52）
--   :570 klaussackloot          小鸡与神秘雕像相关（Klaus Sack 的战利品机制）
--   :572 undertile              地板之下的洞穴层实体管理（双向世界）
--   :574 worldsettingstimer     ★ 世界设置变更的定时器回调（组件在 components/ 下有实体）
--   :575 timer                  通用定时器（DoPeriodicTask 的宿主）
--   :577 farming_manager        农场全局规则：季节掉率、肥沃度、腐化
--   :579 dockmanager            码头/龙骸类停靠点的全局管理
--   :580 vinebridgemanager      藤蔓桥的生成与维护（配合 :276 vine_bridge_fx 预制体）
--   :581 worldroutes            世界路线图数据（地图 UI 与传送点）
--   :583 playerspawner          ★ 出生点选择与出生流程（:269 SpawnAtNextLocation 的宿主）
--   :585 nightlightmanager      夜晚光照管理（无光道具、照明衰减）
--   :586 winonateleportpadmanager 汇智之帽传送基座的全局登记
--   :588 corpsepersistmanager    ★ 尸体跨会话保留（死亡掉落物不消失）
--   :591 skeletonsweeper        骨骼清理：分片扩容时清扫游离骨骼
--   :598 uniqueprefabids        预制体 ID 去重，防止同批生成重复实体
--
--【⚠ 关于「时钟类组件不在本文件」】
--   clock / seasons / worldtemperature / worldvoter / autosaver / worldreset /
--   shardstate 这 7 个组件注册在 prefabs/world_network.lua:52-61，
--   由 gamelogic.lua 挂到 TheWorld.net（net.lua 预制体）上，而不是 TheWorld 本体。
--   所以「世界 = TheWorld」严格说是 **两个实体**：TheWorld（本体）与 TheWorld.net
--   （联网壳）。这个分裂在 world.lua:423 `inst.net = nil` 与 :336-338 的
--   `if inst.net ~= nil then inst.net:PostInit() end` 处可以看得很清楚。
--   参见 networking.lua:186（TheWorld.net.components.worldcharacterselectlobby）。
--
--【★ 移植时最需要重写的三处】
--  · 419 行的重复世界检查：应改成 SpawnPrefab 前置检查，或在 :415 CreateEntity
--    之后补 inst:Remove()，避免实体泄漏；
--  · 463/466 行的 NOTES 明确警告「地图 finalize 之后再调用会崩溃」，
--    任何重排初始化顺序的改动都必须复查这两行；
--  · 491-493 行的 TODO：渲染层 handle 在世界销毁时没有释放，
--    现在靠「世界寿命 = 游戏寿命」掩盖了问题，多世界/重连场景会暴露。
--★★【第一条 require 决定了「世界 = 预制体」这句话的字面含义】
--   GroundTiles 来自 worldtiledefs.lua —— 它是**地形图层定义表**：
--   ground / creep / falloff 三个数组，每项是 {tile_id, layer_properties}。
--   第 460/496/507 行那三轮循环就是遍历这三张表建立渲染层。
--   ★ 也就是说 world.lua 里没有任何硬编码的地形数据，全部外置。
--   参见 01-报告/01-核心架构-实体预制体组件.md（预制体定义与资源声明的关系）。
local GroundTiles = require "worldtiledefs"
--★★【`require "components/map"` —— 一句没有赋值的 require，信息量极大】
--   它不返回任何东西，纯粹是**副作用 require**：执行 map.lua 的顶层代码，
--   把 Map 组件注册进全局 Class 注册表。
--   ★ 为什么需要它？因为第 445 行 inst.entity:AddMap() 与第 490 行
--   inst.Map:AddRenderLayer(handle) 都要用到 Map 组件，
--   而「注册」与「实例化」是两件事：require 只做前者。
--   注释 --extends Map component 明确指出 Map 扩展了底层 Map 组件。
--   参见 entityscript.lua:AddComponent（组件的注册表查找路径）。
require "components/map" --extends Map component

--★★★【assets：世界预制体的「资源闭包」—— 这是 prefab 机制的核心收益】
--   Prefab(name, fn, customassets, worldprefabs) 的第三个参数就是它（见第 615 行）。
--   ★ 为什么**世界**要显式声明音频、着色器、图集？
--     因为 prefab 在打包/下载时按需收集资源。世界的存在期 = 整个游戏的存在期，
--     所以凡是「世界活着就一定用得到」的资源都挂在世界预制体上，
--     避免每个用到它的实体各自重复声明一遍（模组化下载的依据）。
--   ★ 注意混用了 Asset 的六种类型，每种对应资源管线的一个类别：
--     SOUND        音频（music/sanity/amb_stream 三条环境音轨）
--     SHADER       着色器（uifade = UI 淡入淡出）
--     DYNAMIC_ATLAS + PKGREF  成对出现 ★ —— 前者是动态图集布局 xml，
--                     后者是被动态合成的纹理本体。加载器先读 xml 拿到各子图矩形，
--                     再把 PKGREF 的纹理裁进去，所以必须成对声明。
--     INV_IMAGE    HUD 图标（第 39-41 行是装备槽图标）
--     IMAGE        单张纹理
--     ANIM         动画包
--     SCRIPT       ★ 第 49 行把 rift_portal_defs.lua 声明为世界资源，
--                  即「裂隙传送门的定义只在装了世界的地方才打包」。
local assets =
{
--★ 三条环境音轨是**循环音床**，与 music.fsb 的结构化音乐不同：
--   sanity.fsb 随理智值变化，amb_stream.fsb 是环境随机流。
--   都是挂在世界上而非玩家身上 —— 环境音属于世界状态。
    Asset("SOUND", "sound/music.fsb"),
    Asset("SOUND", "sound/sanity.fsb"),
    Asset("SOUND", "sound/amb_stream.fsb"),
--★ SHADER 的生命周期值得注意：着色器在 GPU 上有状态，跨场景复用会脏。
--   把 uifade 声明为世界级资源，等于宣告「每次进游戏都要重新加载这份着色器」。
    Asset("SHADER", "shaders/uifade.ksh"),
--★ DYNAMIC_ATLAS / PKGREF 成对模式的三个实例（10-11、13-16、18-25）：
--   bigportraits/locked、random、random_none —— 它们是玩家选人界面的大头像，
--   以及「随机分配名字/金色名字」的两套文本图集。
--   ★ 与 networking.lua:671 GetAvailablePlayerColours 对照：
--     名字随机、颜色按加入顺序分配，颜色列表是**有序**的（注释里写明了）。
    Asset("DYNAMIC_ATLAS", "bigportraits/locked.xml"),
    Asset("PKGREF", "bigportraits/locked.tex"),

    Asset("DYNAMIC_ATLAS", "bigportraits/random.xml"),
    Asset("PKGREF", "bigportraits/random.tex"),
    Asset("DYNAMIC_ATLAS", "bigportraits/random_none.xml"),
    Asset("PKGREF", "bigportraits/random_none.tex"),

    Asset("DYNAMIC_ATLAS", "images/names_random.xml"),
    Asset("PKGREF", "images/names_random.tex"),

    Asset("DYNAMIC_ATLAS", "images/names_gold_random.xml"),
    Asset("PKGREF", "images/names_gold_random.tex"),

    Asset("DYNAMIC_ATLAS", "images/names_gold_cn_random.xml"),
    Asset("PKGREF", "images/names_gold_cn_random.tex"),

--★ 被注释掉的 portrait_frame 动画。原注释 "Not currently used, but likely
--   to come back" —— 保留在资源清单里是为了让打包器仍能看到它的存在，
--   ★ 但注意它**不会**被打包（Asset 构造未执行），所以注释是纯历史记录。
    -- Asset("ANIM", "anim/portrait_frame.zip"), -- Not currently used, but likely to come back
    
--★★【anim/frames_comp.zip 是游戏的「通用帧动画库」】
--   ★ 它不是某个实体专属动画，而是被众多 UI/小图标共用的帧集。
--     把它放在世界预制体上 = 「只要有世界就有帧动画」。
--   这与第 10 行把玩家头像挂在世界上是同一种思路：
--   按「存活期最长者持有」而不是按「使用者持有」来组织资源。
    Asset("ANIM", "anim/frames_comp.zip"),

    Asset("ANIM", "anim/frozen.zip"),
    Asset("ANIM", "anim/floating_items.zip"),

    Asset("DYNAMIC_ATLAS", "images/bg_spiral_anim.xml"),
    Asset("PKGREF", "images/bg_spiral_anim.tex"),
    Asset("DYNAMIC_ATLAS", "images/bg_spiral_anim_overlay.xml"),
    Asset("PKGREF", "images/bg_spiral_anim_overlay.tex"),

--★ 三个 INV_IMAGE 是装备槽 HUD 图标。equip_slot_body_hud / _head_hud / _hud
--   命名规律：[部位] + [hud 后缀]，最后一个是不带部位的通用槽位图标。
--   ★ 注意缩进用了 Tab（其余是空格）—— 混排是历史痕迹，无语义影响。
	Asset("INV_IMAGE", "equip_slot_body_hud"),
	Asset("INV_IMAGE", "equip_slot_head_hud"),
	Asset("INV_IMAGE", "equip_slot_hud"),

--★ waterfall_mask.tex 与第 45 行**完全重复**（同一个资源声明了两次）。
--   ⚠ 疑似疏漏：43 与 45 行的路径字符串一字不差。
--   推理：第 43 行与 45 行之间没有插入其它资源的意图（紧接着 46/47 行是 noise 纹理），
--   更像是编辑时复制粘贴留下的残留。
--   影响：无功能危害（资源加载器会去重或只是重复声明），但属于应当清理的死代码。
--   按本文件「只注释不改码」的约定，此处仅标注不修改。
	Asset("IMAGE", "images/waterfall_mask.tex"),

	Asset("IMAGE", "images/waterfall_mask.tex"),
	Asset("IMAGE", "levels/textures/waterfall_noise1.tex"),
	Asset("IMAGE", "levels/textures/waterfall_noise2.tex"),

--★★【唯一一条 Asset("SCRIPT") —— 值得单独讲】
--   资源管线里 SCRIPT 类型意味着「这段 Lua 需要被打包并可被 require」。
--   rift_portal_defs.lua 是「裂隙传送门」的定义表（传送门类型、目标世界配置）。
--   ★ 为什么它归世界管而不是某个 prefab 管？
--     因为传送门是**世界级设施**（两个世界之间的通道），
--     和第 216-217 行的 migration_portal / shard_network 属于同一类。
--   交叉引用：第 217 行 shard_network 预制体、shardnetworking.lua 的 ShardPortals。
    Asset("SCRIPT", "scripts/prefabs/rift_portal_defs.lua"),

    Asset("ANIM", "anim/poi_marker.zip"),
    Asset("ANIM", "anim/poi_stand.zip"),    

--★ 装饰物图集：南瓜雕刻（pumpkin_carving / pumpkin_carving2）、雪人（snowman）。
--   全部是万圣节/季节性装饰。两套 pumpkin_carving 说明 Halloween 有两种变体。
	Asset("DYNAMIC_ATLAS", "images/pumpkin_carving.xml"),
	Asset("PKGREF", "images/pumpkin_carving.tex"),
--★ 呼应第 43/45 行的重复声明问题：这里的 pumpkin_carving2 是**真实**的第二套，
--   与第 43 行的无意重复不同，不要混淆两类「重复」。

	Asset("DYNAMIC_ATLAS", "images/pumpkin_carving2.xml"),
	Asset("PKGREF", "images/pumpkin_carving2.tex"),

	Asset("DYNAMIC_ATLAS", "images/snowman.xml"),
	Asset("PKGREF", "images/snowman.tex"),
}

--★★【地形的全部资源来自 worldtiledefs 的合并，而不是本文件列举】
--   为什么用 pairs 而不是 ipairs？
--   ★ 因为 GroundTiles.assets 是一个**字典**（tile_id → 资源），不是数组。
--     pairs 遍历顺序不确定，但这不重要 —— 资源表的顺序不影响语义。
--   ★★ 对比第 409/434 行的 customprefabs / tags 用的是 ipairs：
--     那是**数组**，顺序有意义（预制体装载顺序会影响优先级）。
--     「遍历顺序是否重要」决定了用 pairs 还是 ipairs，本文件示范得很清楚。
for k, v in pairs(GroundTiles.assets) do
    table.insert(assets, v)
end

--★★★【prefabs 清单 —— 理解「世界即预制体」最重要的一张表】
--   第 615 行 Prefab(name, fn, customassets, worldprefabs) 的第四个参数就是它。
--   ★★ 语义：凡是「本世界可能出现」的预制体，都必须列在这里。
--     Prefab 系统据此建立预制体清单，SpawnPrefab 才能找到对应的构造工厂。
--   ★ 这张表就是「世界的内容边界声明」。世界能生成什么，完全由这张表决定；
--     表里没有的预制体，即使 SpawnPrefab 也不会被构造（找不到工厂）。
--   ★★ 这解释了为什么模组必须往里注册自己的预制体 —— 
--     否则模组实体在这个世界里根本不存在。
local prefabs =
{
--★ 列表开头是两个「基础设施」预制体：
--   sounddebugicon —— 声音调试用的小喇叭图标（开发工具）
--   entityproxy —— ★ 实体代理，用于在客户端持有服务端实体的引用而不复制其数据
--     （详见 01-报告/04-联机同步-模组系统-UI.md 的实体复制章节）
    "sounddebugicon",
    "entityproxy",

--★ minimap 在第 540 行被 SpawnPrefab 出来当 TheWorld 的成员（inst.minimap），
--   并且在第 358 行 OnRemoveEntity 里被 Remove。
--   ★ 交叉引用 networking.lua:660-663 —— 玩家迁移服务器前要先
--     SerializeUserSession 保存本地小地图，说明 minimap 是有持久状态的。
    "minimap",
--★★【第 74-83 行是一整组 evergreen（常青树）的变体矩阵】
--   命名规律：{base} + 可选修饰 {normal / short / tall / sparse / burnt / stump}
--   即「树种 × 形态 × 状态」的组合。★ 这是一种**用命名承载变体维度**的经典做法：
--   不需要额外的变体表，一个预制体名就把全部维度编码完了。
--   ★ burnt（烧毁）与 stump（树桩）是状态变体而非形态变体，混在同一后缀空间里
--     体现了「变体维度扁平化」的代价：命名空间会变长。
--   对比 twiggytree（第 85-88 行）与 deciduoustree（第 184-189 行）：
--   同一套后缀约定在三组树上复用，说明这是一份**全项目通用的变体规范**。
    "evergreen",
    "evergreen_normal",
    "evergreen_short",
    "evergreen_tall",
    "evergreen_sparse",
    "evergreen_sparse_normal",
    "evergreen_sparse_short",
    "evergreen_sparse_tall",
    "evergreen_burnt",
    "evergreen_stump",

--★ twiggytree 是「枯树」系列，后缀同样遵循 {normal/tall/short}。
--   ★ 注意它没有 sparse —— 因为枯树本就没有稀疏形态，可选维度随树种变化。
--   这一点值得注意：**变体后缀不是强制对齐的**，各 prefab 自由裁剪自己需要的维度。
    "twiggytree",
    "twiggy_tall",
    "twiggy_short",
    "twiggy_normal",

--★ sapling（树苗）与 sapling_moon（月亮树种）：
--   树苗是可以被移植/培育的幼树，sapling_moon 是特殊材质变体。
    "sapling",
    "sapling_moon",
--★ berrybush 三变体：berrybush（基型）、berrybush2（形态 2）、
--   berrybush_juicy（多汁变体，产出更多浆果）。
--   ★ 数字后缀（berrybush2）是无语义后缀，_juicy 是语义后缀，两者混用。
    "berrybush",
    "berrybush2",
    "berrybush_juicy",
    "grass",
    "rock1",
    "rock2",
--★ rock_flintless —— 「不含燧石」的石头变体。
--   ★ 这是**负向变体**：一个特性（产燧石）被关掉，其余与 rock1/rock2 相同。
--     游戏用独立预制体表达负向变体，而不是加一个布尔标志，
--     好处是可以在 prefab 层面直接覆写资源与组件。
    "rock_flintless",
    "rock_moon",
    "rock_petrified_tree",
    "rock_petrified_tree_tall",
    "rock_petrified_tree_short",
    "rock_petrified_tree_med",

--★★【第 105-118 行是「敌对生物大集合」，按攻击方式分族】
--   tallbirdnest（高鸟巢） / hound / firehound / icehound ——
--   ★ 三种 hound 共享同一预制体名后缀模式，只换前缀（fire/ice/基型），
--     对应三种伤害类型（普通/点燃/冰冻）。
--   krampus（圣诞老人怪，冬季限定）
--   mound（土堆，地下生物巢穴）
--   pigman / pighouse / pigking（猪人一家：普通/巢穴/首领）
--   mandrake（曼德拉草，靠近会秒杀，是「声音诱导」类威胁）
--   rook / bishop / knight（国际象棋三棋子 —— 等级递进的骑士型敌人）
--   ★ 设计意图：变体用「共享一个基类 + 若干差异化预制体」表达，
--     共享的部分（行为、AI、状态图）由 prefab 的继承机制处理。
    "tallbirdnest",
    "hound",
    "firehound",
    "icehound",
    "krampus",
    "mound",

    "pigman",
    "pighouse",
    "pigking",
    "mandrake",
    "rook",
    "bishop",
    "knight",

--★ critterlab —— 「生物实验室」，用于批量生成小动物。
--   ★ 这是 modder 与 spawning 相关的经典工具预制体（见 01-报告/04）。
    "critterlab",

--★ 掉落物与小动物群：goldnugget（金块）与 flint（燧石）是资源掉落，
--   crow（乌鸦）/ robin / robin_winter / canary（加泰罗尼亚金丝雀）
--   ★ 又一组 {基型}_{季节} 变体模式，robin 与 robin_winter 印证季节维度的通用性。
--   fireflies（萤火虫，夜晚发光）、log（原木）、spiderden（蜘蛛巢穴）
    "goldnugget",
    "crow",
    "robin",
    "robin_winter",
    "canary",
    "butterfly",
    "flint",
    "log",
    "spiderden",
    "fireflies",

--★★★【第 133-152 行是一整块地表（turf）矩阵 —— 地表类型是世界的「材质系统」】
--   road/rocky/forest/marsh/grass/savanna —— 六大生物群系地表
--   meteor —— ★ 陨石地表，由陨石撞击事件生成，是「世界事件留下的伤疤」
--   pebblebeach/shellbeach —— 两种海滩（鹅卵石/贝壳），差异是掉落物
--   cave —— 洞穴层地表
--   fungus / fungus_red / fungus_green / fungus_moon —— ★ 真菌四变体，
--     对应洞穴的三种蘑菇生态与月亮的特殊真菌
--   archive —— 档案馆（ facilitating? 实际是「档案馆」地表，深渊/遗迹相关）
--   sinkhole —— 天坑（会掉玩家下去的地表）
--   underrock —— ★ 「岩石之下」地表洞穴层专用
--   mud / deciduous / desertdirt
--   ★★ 命名规律：turf_{材质}_{修饰}。地表是**实例**（世界中铺了一大片），
--     材质定义在 worldtiledefs.lua，渲染层由第 460 行那轮循环建立。
--     交叉引用：components/groundcreep.lua 负责地表上的苔藓/路痕覆盖物。
    "turf_road",
    "turf_rocky",
    "turf_forest",
    "turf_marsh",
    "turf_grass",
    "turf_savanna",
    "turf_meteor",
    "turf_pebblebeach",
    "turf_shellbeach",
    "turf_cave",
    "turf_fungus",
    "turf_fungus_red",
    "turf_fungus_green",
    "turf_fungus_moon",
    "turf_archive",
    "turf_sinkhole",
    "turf_underrock",
    "turf_mud",
    "turf_deciduous",
    "turf_desertdirt",

--★★★【第 154-157 行：skeleton 与三个 skeleton_notplayer_N】
--   skeleton —— 玩家死亡后的骨架
--   skeleton_notplayer / _1 / _2 —— 「非玩家骨架」的三个变体
--   ⚠ 这里有一个值得注意的设计痕迹：三个变体只靠数字后缀区分，
--     没有语义命名（不像 hound 的 fire/ice）。
--   推理：这三个骨架大概率是**纯装饰用的随机骨架**（洞穴/废墟里散布），
--     数字只是复制出来的成本标记，语义上没有差别。
--   ★ 参见 skeleton_notplayer 的玩法作用——对应 :591 skeletonsweeper 组件：
--     清理游离骨架正是分片扩容时必须做的收尾工作。
    "skeleton",
    "skeleton_notplayer",
    "skeleton_notplayer_1",
    "skeleton_notplayer_2",
--★ insanityrock（疯狂之岩）与 sanityrock（理智之岩）：
--   ★ 一对镜像命名 —— 给理智加/减的两种石头，说明「反向变体」也用镜像后缀表达。
--   basalt（玄武岩）与其三种形态（basalt_pillar 等）
--   houndmound（猎犬土堆）、houndbone（猎犬骨）、pigtorch（猪人火把）
    "insanityrock",
    "sanityrock",
    "basalt",
    "basalt_pillar",
    "houndmound",
    "houndbone",
    "pigtorch",
--★ red/green/blue_mushroom —— 三色蘑菇，对应生命值/理智值/饱食度的回复。
--   ★ 又是 {基型}_{效果} 的命名法（第 154 行的镜像模式的正向版）。
    "red_mushroom",
    "green_mushroom",
    "blue_mushroom",
--★ mermhouse（美人鱼屋）—— 海洋相关建筑
--   flower_evil（ evil 花）与 blueprint（蓝图）
--   wormhole_limited_1 —— ★ 「限时」虫洞，带数字版本号：
--     wormhole 玩法（挖洞传送到洞穴）有过多次重做，用版本号保留旧资源。
--   diviningrod / diviningrodbase —— 探矿杖及其底座
--   maxwell_smoke（麦克斯威尔之烟）与三块 chessjunk（国际象棋残骸）
--   statue_transition / statue_transition_2 —— ★ 雕像过渡形态：
--     玩家用假人雕像从 Maxwell 世界脱困的道具，两代版本并存。
    "mermhouse",
    "flower_evil",
    "blueprint",
    "wormhole_limited_1",
    "diviningrod",
    "diviningrodbase",
    "maxwell_smoke",
    "chessjunk1",
    "chessjunk2",
    "chessjunk3",
    "statue_transition_2",
    "statue_transition",

--★ lightninggoat（闪电羊，秋季万圣节）、smoke_plant（烟叶，烟草来源）
--   acorn（橡实）、deciduoustree 五变体（第 184-189 行，与 evergreen 同构）
--   ★ buzzardspawner（第 190 行）—— ★ 这是「刷怪器」预制体：
--     周期性生成生物。与「生成点」spawnpoint 的区别是它会自己造生物。
--     参见 01-报告/03-世界生成与AI状态机.md（刷怪与 AI）。
    "lightninggoat",
    "smoke_plant",
    "acorn",
    "deciduoustree",
    "deciduoustree_normal",
    "deciduoustree_tall",
    "deciduoustree_short",
    "deciduoustree_burnt",
    "deciduoustree_stump",
    "buzzardspawner",

--★ glommer（哥布林 boss）与 statueglommer（石像形态）
--   ★ 这是一个「boss 的不同形态做成不同预制体」的例子：
--     boss 本体与它的召唤物/阶段形态平级，便于分别配置行为与掉落。
    "glommer",
    "statueglommer",

--★ cactus —— 沙漠地表带刺植物。单独成行是因为它不属于任何族，
--   列表里的空行（第 194、206 行）承担分组作用。
    "cactus",

--★★★【第 197-206 行：出生点与出生特效 —— 联机系统的基础设施预制体】
--   spawnlight_multiplayer —— ★ 联机出生光效（比单机版本更亮，用于多人聚集可见）
--   spawnpoint_multiplayer —— ★ 联机出生点标记实体
--   ⚠ 第 199-200 行 spawn_fx_huge / spawn_fx_large 被注释掉了，
--     只保留 medium / medium_static / ocean_static / small / tiny / small_high。
--   推理：large/huge 两档在联机里过于显眼（多人同屏会互相遮挡），
--     故被下调；而 _static 变体说明「特效不再带动画」——
--     ★ 猜测是关卡切换/分片加载时的性能考量（静态特效可被烘焙或跳过更新）。
--   交叉引用：:583 playerspawner 组件负责实际出生，:300 OnPlayerSpawn 负责回传。
    "spawnlight_multiplayer",
    "spawnpoint_multiplayer",
    --"spawn_fx_huge",
    --"spawn_fx_large",
    "spawn_fx_medium",
	"spawn_fx_medium_static",
	"spawn_fx_ocean_static",
    "spawn_fx_small",
    "spawn_fx_tiny",
    "spawn_fx_small_high",

--★★【第 208-214 行：一份被显式标注的「历史遗留清单」】
--   原注释：used to be in BACKEND_PREFABS constant。
--   ★★ 这是一个架构演进的记录：这三个预制体原先由后端常量
--     （游戏服务端的预制体白名单）管辖，后来统一收到世界预制体下。
--   hud —— HUD 本体（第 556 行 hudindicatablemanager 与它配套）
--   fire / character_fire —— 两种火焰：★ 火焰分「普通火」与「角色火」
--     说明火焰不只是视觉概念，还有附着在角色上的独立形态（篝火点燃的自身）。
--   shatter —— ★ 「碎裂」物，指可被打碎的物品的碎片（容器打碎后的碎屑）。
--   electrocute_fx —— 电击特效
--   第 214 行的裸 `--` 分隔符，标记这段注释块的结束（源码风格，非笔误）。
    -- used to be in BACKEND_PREFABS constant
    "hud",
    "fire",
    "character_fire",
    "shatter",
	"electrocute_fx",
    --

--★★★【第 216-217 行：两个「世界互联」设施，与本文件的分片主题直接相关】
--   migration_portal —— 迁移传送门：跨服务器/跨存档移动的通道
--   shard_network —— ★ 分片网络本体，与 shardnetworking.lua 配套。
--   ★ 这两个预制体是「世界不是孤岛」的物理体现：世界之间通过传送门相连，
--     而传送门的状态由分片网络维护（shardnetworking.lua:101-117 的门户绑定循环）。
--   交叉引用：shardnetworking.lua:125 Shard_UpdatePortalState、
--             components/worldmigrator.lua（传送门的组件）。
    "migration_portal",
    "shard_network",

--★★★【focalpoint —— 兴趣管理在 Lua 侧的唯一体现，全文件最关键的单行之一】
--   第 544 行：TheFocalPoint = SpawnPrefab("focalpoint")
--   第 545 行：TheCamera:SetTarget(TheFocalPoint)
--   ★★ 兴趣管理（interest management）决定「每个客户端需要收到哪些实体的复制」，
--     而这个决定的唯一输入就是「兴趣中心点」。
--   ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现：
--     Lua 只提供一个焦点实体，C++ 用它加半径决定复制集合。
--   参见 01-报告/04-联机同步-模组系统-UI.md:1318（兴趣管理：单一中心点 + 半径），
--        以及 01-报告/05-原生C++引擎层.md:660（WallUpdate 设置兴趣管理中心点）。
--   ★ 销毁配对：第 364-365 行在 OnRemoveEntity 里 TheFocalPoint:Remove() 并清空全局。
    "focalpoint",

--★★【第 221-228 行：五个 CLASSIFIED 预制体 —— 「客户端私有数据」的载体】
--   CLASSIFIED 标签（第 431 行给 TheWorld 也打了）意味着：
--   ★★ 只有拥有者客户端能看到该实体的数据，服务端不对全网广播。
--   这是 DST 实现「玩家私有数据」的方式 —— 给每个玩家发一个隐藏实体。
--   ★ 交叉引用 networking.lua:318：SerializeUserSession 序列化存档时
--     会把 player.player_classified.entity 一并传上去，
--     说明 classified 实体是存档持久化的一部分。
--   C++ 侧对应 SetClassifiedTarget，参见 01-报告/05-原生C++引擎层.md:521。
    -- Common classified prefabs
--★ 五个 classified 变体对应五种私有数据载体：
--   attunable_classified —— 可附魔物品的私有归属（谁能附魔它）
--   inventoryitem_classified —— 物品私有状态（如已读的书签）
--   writeable_classified —— 可书写物品的私有文本
--   container_classified —— ★ 容器私有状态（如小冰箱是谁的）
--   container_closed_receiveitem_classified —— 关闭状态下的容器接收目标
--   constructionsite_classified —— 建造蓝图的私有进度
    "attunable_classified",
    "inventoryitem_classified",
    "writeable_classified",
    "container_classified",
    "container_opener",
	"container_closed_receiveitem_classified",
    "constructionsite_classified",

--★ dummy 系列：dummytarget / dummytarget_lunar / dummytarget_shadow
--   ★ 又一组 {基型}_{来源} 变体：普通 / 月亮（月亮之力刷新）/ 暗影。
--   它们是「不可见的目标占位实体」，用于技能指示器与命中判定。
    "dummytarget",
    "dummytarget_lunar",
    "dummytarget_shadow",
--★ float_fx_front / float_fx_back —— 飘字特效的前后两层。
--   ★ 分前后两层是为了解决 UI 遮挡排序：伤害数字要在怪物血条之上，
--     某些提示又在血条之下，用两个预制体预留不同的渲染层。
    "float_fx_front",
    "float_fx_back",

--★ puffin —— 海鹦，北极/冰原生态。
    "puffin",

	-- summer carnival
--★ carnival_host（夏季嘉年华主持人）—— ★ 带年份/季节注释的预制体，
--   说明这类是限时活动内容，随版本加入或下线。
	"carnival_host",

	-- deprecated bird tacklesketch
--★★【第 242-247 行：六个已废弃的 oceanfishingbobber_{鸟}_{美术变体}】
--   原注释：deprecated bird tackle sketch。
--   ★ 这是美术资产废弃但**逻辑资源保留**的典型：
--     浮标模型换新了，但旧存档里还可能有旧浮标，需要保留构造工厂。
--   ★★ 与第 250-251 行的 slow_farmplot / fast_farmplot 同属一类：
--     旧预制体必须保留，否则旧存档加载时 SpawnPrefab 失败。
--     这正是「预制体清单不能随便删东西」的实证（见文件头 §一）。
	"oceanfishingbobber_malbatross_tacklesketch",
	"oceanfishingbobber_goose_tacklesketch",
	"oceanfishingbobber_crow_tacklesketch",
	"oceanfishingbobber_robin_tacklesketch",
	"oceanfishingbobber_robin_winter_tacklesketch",
	"oceanfishingbobber_canary_tacklesketch",

	-- Farming
--★★【两条明确标注「deprecated but still used in old worlds and mods」的预制体】
--   slow_farmplot / fast_farmplot —— 慢速/快速农场地块
--   ★★ 原注释里的 and mods 是关键词：不仅要兼容旧存档，
--     还要兼容**老模组**（模组可能硬编码引用这两个名字）。
--     删掉的后果是整个模组崩溃，而不只是存档轻微异常。
--   nutrients_overlay —— 土壤营养的覆盖显示（配合 :555 nutrients_visual_manager）
--   lordfruitfly —— 果蝇王（farm 相关）
	"slow_farmplot", -- deprecated but still used in old worlds and mods
    "fast_farmplot", -- deprecated but still used in old worlds and mods
    "nutrients_overlay",
    "lordfruitfly",

	-- YOT Catcoon
--★★【第 256-264 行：九个 kitcoon_{生物群系} —— 季节刷新的「浣熊怪」季节变体】
--   YOT（Year of the）Catcoon —— ★ 注释直接写了「猫年」限定，
--   所以 kitcoon_yot 与其它八个不是同一批内容，是生肖年的专属。
--   其余八个（forest/savanna/marsh/deciduous/grass/rocky/desert/moon）
--   ★ 与第 74-83 行的 evergreen 变体矩阵、以及 turf 地表（第 133 行）
--     的群系名**完全同源** —— 说明「八大生物群系」是贯穿全游戏的统一维度。
--   cookingrecipecard（第 266 行）—— 烹饪配方卡道具。
	"kitcoon_forest",
	"kitcoon_savanna",
	"kitcoon_marsh",
	"kitcoon_deciduous",
	"kitcoon_grass",
	"kitcoon_rocky",
	"kitcoon_desert",
	"kitcoon_moon",
	"kitcoon_yot",

	"cookingrecipecard",

    -- Pirates
--★ monkeyhut —— 猴子小屋（Pirates 海盗主题内容）。
    "monkeyhut",

	-- Planar
--★ planar_hit_fx / planar_resist_fx —— 饥荒联机版角色 planar 的特效。
--   ★ 在原注释「Planar」处，说明这是为联机版新增角色的兼容资源组。
	"planar_hit_fx",
	"planar_resist_fx",

	-- vinebridgemanager
--★ vine_bridge_fx —— 藤蔓桥特效，与第 580 行 vinebridgemanager 配套：
--   manager 负责逻辑（桥的生成/维护），fx 负责表现（视觉）。
	"vine_bridge_fx",

--★ snowball_item —— 雪球物品。列表的最后一项，无归属分组。
    "snowball_item",
}

--★★★【第 281-296 行：四个「运行期动态注册」的循环 —— 预制体清单可被改写】
--   ★★ 这是理解 prefab 系统的关键：prefabs 表不是静态字面量，
--     模块加载时可以通过 table.insert 往里追加条目。
--   farm_plant_defs.PLANT_DEFS —— ★ 所有可种植作物
--     数据驱动：新增作物只要在 defs 表里加一条，不必改 world.lua。
--   weed_defs.WEED_DEFS —— 杂草，同理
--   pocketdimensioncontainer_defs —— ★ 口袋维度容器（如坎特伯雷盒子的内部空间）
--   SINKENTITY_PREFABS —— ★ 需注意它**不是** require 来的，而是全局常量；
--     第 291 行的 require "ocean_util" 正是为了保证这个全局被定义。
--     原注释坦承："Only here just in case but it should not be needed."
--   ★ 循环写法统一：for _, v in pairs(...) do table.insert(prefabs, v.prefab) end
--     与第 64 行的资源合并是同一个模式（字典遍历 + 取出需要的字段）。
for _, v in pairs(require("prefabs/farm_plant_defs").PLANT_DEFS) do
	table.insert(prefabs, v.prefab)
end
for _, v in pairs(require("prefabs/weed_defs").WEED_DEFS) do
	table.insert(prefabs, v.prefab)
end
for _, v in pairs(require("prefabs/pocketdimensioncontainer_defs").POCKETDIMENSIONCONTAINER_DEFS) do
    table.insert(prefabs, v.prefab)
end

--★ 这条 require 的唯一目的是**副作用**：执行 ocean_util.lua 顶层代码，
--   赋值全局 SINKENTITY_PREFABS（下沉的实体清单）。
--   ⚠ 但紧接着的循环**完全没有保护**：若 SINKENTITY_PREFABS 为 nil，
--     第 292 行的 pairs(nil) 会直接报错，导致整个 world.lua 加载失败。
--   推理：原注释说 "it should not be needed" —— 暗示作者认为 SINKENTITY_PREFABS
--   其实由别处（引擎或更早的 require）已经定义，这行只是保险。
--   一旦那个「别处」不存在，这就是硬崩溃点。属结构性脆弱，非当前 bug。
require("ocean_util") -- Only here just in case but it should not be needed.
--★ 注意这里是**两层**嵌套循环（292→293），因为 SINKENTITY_PREFABS 的值
--   本身是一个「表 → 预制体名列表」的字典（第 293 行的 v 就是内层表）。
--   ★ 对比第 281-289 行：那些是单层循环 + .prefab 字段访问。
--     数据形状不同，遍历深度就不同 —— 预制体清单的结构由各 defs 模块自定。
for _, v in pairs(SINKENTITY_PREFABS) do
    for _, prefab in pairs(v) do
        table.insert(prefabs, prefab)
    end
end

--★★★ 分节线。以上是「预制体定义」的静态部分，以下是「世界实例的行为」。
--   架构含义：Prefab 的构造函数 fn 还没执行，现在处于**类定义**阶段。
--------------------------------------------------------------------------

--★★★【OnPlayerSpawn —— 联机出生流程在 Lua 侧的回调】
--   签名 (world, inst)：world 是派发事件的实体（= TheWorld），inst 是事件参数。
--   ★ 第 606 行 inst:ListenForEvent("ms_playerspawn", OnPlayerSpawn) 完成绑定。
--   ★★ ms_ 前缀约定：**m** = 「该事件通常只在服务端世界发生」，s = server。
--     引擎与 gamelogic 用 ms_ 前缀派发的事件，在客户端世界不会触发。
--     这是一种命名级约定（无类型系统时的标记法），本文件还有
--     ms_setworldsetting（worldsettings.lua:14）、ms_newmastersessionid、
--     ms_save、ms_startvote、ms_worldreset（见 shardnetworking.lua 与 networking.lua）。
--   整个函数体包在 DoTaskInTime(0, ...) 里 —— 见下方注记。
local function OnPlayerSpawn(world, inst)
--★★★【为什么整个函数体要包一层 DoTaskInTime(0, ...)？—— 本文件最重要的一个 trick】
--   DoTaskInTime(0) = 下一个刻（tick）执行，而不是立即执行。
--   ★★ 原因：**监听器注册时刻，事件源实体的状态可能还没准备好**。
--     具体到这里：ms_playerspawn 派发时，玩家实体刚创建、
--     TheWorld.components.playerspawner 可能还没把玩家放到最终出生点。
--     延迟一刻，等 playerspawner 完成 SpawnAtNextLocation 之后再去读位置。
--   ★ 这个「延迟一刻等状态稳定」的模式在本项目反复出现：
--     shardnetworking.lua:240/257/272/287 的 DoTaskInTime(0, ...)
--     networkclientrpc.lua 的整个 RPC 队列机制（:1675 入队、:1724 排空），
--     以及本文件 :340 的 inst:LongUpdate(0)。
--   ★★ 统一的心智模型：**事件回调里看到的世界是「刚发生变更」的世界，
--     而游戏逻辑往往需要「变更已落定」的世界。延迟一刻是两者之间唯一的缓冲。
--   参见 entityscript.lua 的 DoTaskInTime 实现（任务队列挂在实体上，实体死亡则任务取消）。
    inst:DoTaskInTime(0, function()
--★★【auto_teleport_players —— 一个纯粹的「调试/测试便利」开关】
--   语义：新人加入时，把玩家瞬移到任意一个已有玩家身边。
--   ★ 用途：开房主调试联机时，让所有客户端角色重叠在一起便于观察。
--   ⚠ 若在正式服务器上为真，会造成新玩家与老玩家重叠，
--     精确落在老玩家身上可能触发挤压/推挤逻辑，是明显的作弊面。
--   推理：它是 inst 上的裸字段（不是组件设置），没有暴露给玩家可见的开关，
--     应属开发者调试用。生产配置中必须确保为假。
        if TheWorld.auto_teleport_players then
--★ teleported 标志：保证**最多只传送一个玩家**（第 309 行的 and not teleported）。
--   ★ 为什么不是循环里逐个传送？
--     因为 teleport 的目标必须是「一个稳定的参照物」；如果每个新人都传送到前一个新人，
--     会形成一条漂移链。所以只认「第一个找到的老玩家」。
            local teleported = false

--★★★【Ents 表 —— 全局实体注册表，本文件最核心的数据结构】
--   local 变量 k 是 GUID（全局唯一实体号），v 是实体对象。
--   ★★★ Ents 定义在 main.lua:289（Ents = {}），**不是本文件**。
--   ★★ 它由引擎与 entityscript.lua 共同维护：
--     实体创建时注册（entityscript.lua:219 self.GUID = entity:GetGUID()），
--     实体移除时反注册（EntityScript:Remove 清理）。
--   ★ 遍历方式对比：本文件用的是 pairs（不关心顺序），
--     而 networking.lua:919 LookupPlayerInstByUserID 用 ipairs(AllPlayers)
--     （关心顺序，且 AllPlayers 是玩家专用有序表）。
--   ★⚠ 性能注记：pairs(Ents) 的代价是 O(全游戏实体数)。
--     这在一个出生事件里跑一次是可以接受的，但它说明
--     **Ents 不适合放在每帧热路径上**。若要每帧找某类实体，
--     应当建立索引表（如 playerspawner 的成员表）而不是扫全表。
--   交叉引用：networking.lua:25 Networking_SlashCmd 用 Ents[guid] 做 O(1) 直取 ——
--     知道 GUID 时务必走索引，不要学本行做全表遍历。
            for k,v in pairs(Ents) do
--★★【三个条件的合取，各有各的理由，不能删任何一个】
--   v:IsValid() —— 必查。★ 遍历期间其他实体可能已被移除，
--     访问已 Remove 的实体会拿到失效引用（DST 的实体移除是延迟的，
--     所以即使刚 Remove 也可能还在表里）。这是本文件唯一的有效性防御。
--   v:HasTag("player") —— ★ 用**标签**而非 prefab 名或组件判断。
--     标签是可继承的（见 01-报告/01-核心架构：prefab_tags），
--     玩家的所有衍生预制体（如巨型机器人皮肤）都自动带 player 标签，
--     而用 prefab 名判断会漏掉所有变体。
--   v ~= inst —— 排除新玩家自己（否则会传送到自己身上，无意义）。
--   and not teleported —— 见第 303 行。
                if v:IsValid() and v:HasTag("player") and v ~= inst and not teleported then
--★ inst.Transform:SetPosition(v.Transform:GetWorldPosition()) —— 复制的是**世界坐标**。
--   ★ 注意用的是 GetWorldPosition 而不是 v.Transform.position：
--     后者是局部坐标，只有在无父级变换时才等于世界坐标。
--   ★ 直接 SetPosition（而非插值移动）= 瞬移，玩家会看到一次视觉跳变。
                    inst.Transform:SetPosition(v.Transform:GetWorldPosition())
--★★★【inst:SnapCamera() —— 瞬移后必须强制同步相机，否则玩家会「看见自己飞过去」】
--   相机在客户端独立运行并有自己的平滑跟随逻辑（见 01-报告/05 的 TheCamera:Update）。
--   实体瞬移但相机还在旧位置并缓缓跟随，中间这段就是「拉镜头」，很难看。
--   ★ SnapCamera 把相机硬拉到目标位置，消除这段过渡。
--   ★ 这是一条通用的联机/瞬移规则：★ 任何 teleport 之后都要 SnapCamera。
--   参见 locomotor.lua 关于客户端预测与位置回滚的注记（同样是「表现层要跟上」）。
                    inst:SnapCamera()
                    teleported = true
                end
            end
        end
    end)
end

--★★★【DoGameDataChanged —— 把世界 Lua 状态「打包下发给所有客户端」】
--   数据源是 inst.state（第 529 行 = worldstate 组件的 data）。
--   三个字段构成「客户端 HUD 上显示的日历信息」：
--     day = inst.state.cycles + 1 —— ★ +1 因为 cycles 是「第几天已完成/正在经历」，
--     而 UI 要显示的是「今天几号」，两者差一天。这是易错点。
--     daysleftinseason  距离本季节结束还有几天
--     dayselapsedinseason 本季节已经过了几天
--   ★★ 注意这里**没有** daylength / 时钟信息 —— 那些走 clock 组件的 netvar。
--     本函数只负责「日历类」的汇总。
local function DoGameDataChanged(inst)
    inst.game_data_task = nil

--★ 这张表是纯数据，字段名与客户端 UI 的取值预期严格对应。
--   ⚠ 如果模组扩展了 worldstate 的 data 字段，这里不会自动带上 ——
--     想同步额外字段必须改这个函数。这是**加字段需双改**的耦合点。
    local game_data =
    {
        day = inst.state.cycles + 1,
        daysleftinseason = inst.state.remainingdaysinseason,
        dayselapsedinseason = inst.state.elapseddaysinseason,
    }
--★★★【TheNet:SetGameData(DataDumper(...)) —— 序列化 + 广播】
--   DataDumper(table, nil, false) —— 第三个参数是「是否包含引用」：
--   false = 不含 entity 引用。★ 理由：广播给所有客户端的数据必须可序列化，
--   而 entity 引用只在同一端内有效，跨端无法还原。
--   对比第 328 行的 SerializeWorldSession 用 ENCODE_SAVES，
--   以及 networkclientrpc.lua 里普遍用 true 的场景 —— 参数含义随用途而变。
--   ★★ 这一行是「服务端 → 客户端」数据流的一个标准样板：
--     状态在服务端 → DataDumper 转字符串 → TheNet 广播。
--     参见 01-报告/04-联机同步-模组系统-UI.md 的「实体复制 — 网络变量」章节。
    TheNet:SetGameData(DataDumper(game_data, nil, false))
--★ SetSeason 单独一行 —— 季节名与季节天数分开发送。
--   ★ 推理：季节在 SetGameData 里被「量化」成了天数（第 322-323 行），
--     但客户端 UI 还要显示季节**名**（春/夏/秋/冬的图标与配色），
--     而 season 字段不是数字，DataDumper 的编码路径不同，故单独发。
    TheNet:SetSeason(inst.state.season)
end

--★★★【OnGameDataChanged —— 「多个状态字段共用一次广播」的合并器】
--   问题：第 349-352 行连续监听 4 个字段。夜晚推进时，cycles 和
--   elapseddaysinseason 可能在同一刻同时变，若各自触发一次广播就是 4 倍浪费。
--   解法：用一个延迟任务做合并 —— 同刻多次调用只会排一个任务。
--   ★★ 模式识别：inst.game_data_task 作为「已排队」标志位，
--     典型的 **debounce（去抖）** 写法。
--   ★ 与第 301 行的 DoTaskInTime(0) 是同一套「延迟一刻」原语的两种用法：
--     那里用来等外部状态稳定，这里用来合并重复触发。
local function OnGameDataChanged(inst)
--★★ nil 检查即去抖开关：只有没排过队时才排。
--   标志位由 DoGameDataChanged 的**第一行**清空（第 317 行），
--   ★ 所以清理发生在任务真正执行时，而不是排队时 ——
--     期间到来的新变更会被合并进同一次广播。
--   ⚠ 边界：若某次广播后同刻又有变更，会再排一个任务，产生一次额外的广播。
--     这在跨刻边界时可能发生，是可接受的小瑕疵（多发一次而非漏发）。
    if inst.game_data_task == nil then
        inst.game_data_task = inst:DoTaskInTime(0, DoGameDataChanged)
    end
end

--★★★【PostInit —— 「实体已经建好」的收尾钩子，与 prefab 无关】
--   注意这是**全局函数**（第 335 行没有 local），在第 535 行挂为 inst.PostInit。
--   ★ 为什么必须做成全局函数而不是文件内的 local？
--     因为 Prefab 系统需要在实体初始化完成的特定时刻回调它，
--     这个回调点由框架（entityscript.lua / engine）触发，无法用闭包变量传入。
--     挂到 inst 上是给框架一个「取得到」的名字。
--   ★ 同一个文件里第 336/342/348 行的结构就是 PostInit 的四段职责。
local function PostInit(inst)
--★★★【第 336 行：if inst.net ~= nil —— 「TheWorld 与 TheWorld.net 是两个实体」的证据】
--   ★★ 完整调用链见文件头 §九 的注记：
--     TheWorld（本文件构造的 world prefab）与 TheWorld.net（net.lua 预制体）
--     是两个独立实体。net 由 gamelogic.lua 创建并挂到 TheWorld.net 字段上。
--   ★ 因此 PostInit 对 net 的处理是**条件性**的：单机模式下 net 为 nil。
--   ★ 这也是第 423 行 `inst.net = nil` 的意义 —— 显式初始化该字段为 nil，
--     保证后续 `if inst.net ~= nil` 判定的语义（而不是继承到脏值）。
--   交叉引用：networking.lua:186 TheWorld.net.components.worldcharacterselectlobby；
--             prefabs/world_network.lua:52-61 的 7 个时钟/存档类组件。
    if inst.net ~= nil then
        inst.net:PostInit()
    end

--★★★【inst:LongUpdate(0) —— 「以 0 延迟补跑一次长更新」】
--   ★ LongUpdate 是 DST 的「低频更新」钩子（默认约 1 秒一次），
--     与每帧的 OnUpdate 相对。传 0 表示「立刻补一次」，
--     目的是让刚创建的实体马上走一遍长更新初始化，而不是干等下一个周期。
--   ★★ 这是 world 初始化序列里唯一的一次「主动踢一下」：
--     世界的很多子管理器依赖长更新建立内部状态（比如把全表扫一遍建索引）。
--   ★ 与第 301 行的 DoTaskInTime(0) 共同构成本文件的时序工具箱：
--     「延迟一刻」用于等状态，「立即补跑」用于初始化。
--   参见 01-报告/01-核心架构：Update / LongUpdate / WallUpdate 三种更新频率。
    inst:LongUpdate(0)

--★★【遍历 components 调用每个组件的 OnPostInit —— 组件级的收尾钩子】
--   ★★ 与实体的 PostInit 对称：实体建完 → 组件各自再收尾一次。
--   典型用途：某组件的初始化依赖别的组件已经就绪，此时做最后的校验或索引建立。
--   ★ 判断存在性用 `v.OnPostInit ~= nil`（方法查找）而不是 hasComponent 之类，
--     因为 OnPostInit 是可选钩子 —— 大多数组件不需要它。
--   ★ 注意此处直接调用方法而非 v:OnPostInit() 传 self，
--     说明 Class 的方法在实例上被闭包绑定（见 class.lua 的 Class 实现）。
--   ⚠ 遍历 pairs(inst.components) 的顺序不确定 → 若两个组件的 OnPostInit
--     互相依赖对方的初始化结果，会出现非确定性 bug。设计时必须避免这类依赖。
    for k, v in pairs(inst.components) do
--★ 钩子存在性检查。第 342 行的 v 是组件实例，v.OnPostInit 是取它的方法字段。
        if v.OnPostInit ~= nil then
            v:OnPostInit()
        end
    end

--★★★★【ismastersim —— 本文件最关键的一次分流，也是全项目端判定的权威】
--   ★★★ 赋值在第 426 行：inst.ismastersim = TheNet:GetIsMasterSimulation()
--   ★★ 语义（三选一，不是二选一 —— 这是最容易搞错的地方）：
--     · 专用服务器（dedicated）  → true
--     · 房主（host，同时是 server 也是 client）→ true
--     · 纯客户端（client）      → false
--   ★ 所以 ismastersim 的准确语义是「**我是否持有权威模拟**」，
--     而不是「我是不是客户端」。房主虽然是客户端进程，但它是权威的。
--   ★★ 与 ismastershard（第 427 行）的区别 —— 多分片集群里：
--     主分片（表面）：  ismastersim=true,  ismastershard=true
--     次分片（洞穴）：  ismastersim=true,  ismastershard=false
--     纯客户端：        ismastersim=false, ismastershard=false
--   ★ 这三个布尔量（无 / 主sim / 主分片 / 纯客户端）构成完整的四种运行身份。
--     本文件用它们做了三处分流：:348（监听状态）、:564（提前 return）、
--     以及 networking.lua:660/723/734 的对应判断。
--   交叉引用：shardnetworking.lua:13 Shard_IsMaster 的判定式与此同源；
--             01-报告/04-联机同步-模组系统-UI.md 的「联机模式判断」小节。
    if inst.ismastersim then
--★★【四个 WatchWorldState —— 把 worldstate 的字段变更变成事件订阅】
--   ★★ 为什么监听四个字段而 OnGameDataChanged 只有一个？
--     因为 WatchWorldState 是**按字段**订阅的，而回调可以共用同一个函数
--     —— 订阅粒度不同，合并粒度由第 329 行的去抖完成。
--   ★ season / cycles / remainingdaysinseason / elapseddaysinseason
--     正是第 319-324 行 game_data 表里用到的全部四个字段。
--   ★★★ 这个「订阅集合」与「打包字段集合」必须严格一致：
--     少订阅一个 → 该字段变化不触发广播（客户端数据陈旧）；
--     多订阅一个 → 多一次无效广播（浪费）。
--   ⚠ 加字段时必须同改这三处（349-352 的订阅、319-324 的打包、客户端 UI）。
--   交叉引用：components/worldstate.lua（data 的实际定义处）。
        inst:WatchWorldState("season", OnGameDataChanged)
        inst:WatchWorldState("cycles", OnGameDataChanged)
        inst:WatchWorldState("remainingdaysinseason", OnGameDataChanged)
        inst:WatchWorldState("elapseddaysinseason", OnGameDataChanged)
--★★【第 353 行 DoGameDataChanged(inst) —— 补一次「初始广播」】
--   ★ 为什么监听之后还要立刻手动调一次？
--     因为监听只在**变化**时触发。新建世界的第一次状态是「从来没有广播过」，
--     若不补这一次，客户端要等到下一个字段变化才知道今天是第几天。
--   ★ 这是所有「订阅 + 初始同步」模式的必备半步。
--   ★ 手工调用（而非排任务）说明这里允许同步执行 —— 此刻网络层已就绪。
        DoGameDataChanged(inst)
    end
--★ PostInit 结束。回顾四段职责：
--   :336-338 net 实体收尾（条件性）→ :340 补跑一次长更新 →
--   :342-346 组件级收尾 → :348-354 主模拟才做的状态订阅。
--   ★★ 注意顺序：组件收尾（342）在状态订阅（348）**之前**。
--     这意味着 DoGameDataChanged 执行时所有组件已初始化完毕，
--     读 inst.state 安全。反过来写就会读到半初始化状态。
end

--★★★【OnRemoveEntity —— 世界销毁。与 PostInit 完全对称的逆过程】
--   ★ 同样是无 local 的全局函数，第 536 行挂为 inst.OnRemoveEntity。
--   ★ 为什么销毁逻辑比初始化简单这么多？
--     因为世界的绝大部分资源（渲染层 handle 见第 491 行的 TODO）
--     **没有在销毁时释放** —— 靠「世界寿命 = 游戏寿命」掩盖了。
--   所以这里只清理三样：一个成员实体 + 两个全局单例。
local function OnRemoveEntity(inst)
--★ inst.minimap:Remove() —— 删掉第 540 行创建的 minimap。
--   ★ 注意用的是 :Remove()（实体移除）而非成员表的置空 ——
--     因为 minimap 是真实体，必须走完整的实体生命周期（onremove 事件、组件清理）。
--   ⚠ 没有判空。若 minimap 创建失败（SpawnPrefab 返回 nil），这里会崩。
--     推理：第 540 行的 SpawnPrefab("minimap") 只要 minimap 在第 73 行的清单里
--     就必然成功；这是「清单即契约」的保证 —— 清单里列了就不会失败。
    inst.minimap:Remove()

--★★★【assert(TheWorld == inst) —— 销毁前的所有权断言】
--   ★★ 语义：如果现在要删的不是「当前的世界」，说明有逻辑错误。
--   为什么需要？防止在分片迁移/重连过程中误删他人世界的场景。
--   ★ 这是防御性编程的典型：正常路径永远为真，异常路径立刻暴露。
--   ★ 与第 543 行的 assert(TheFocalPoint == nil) 构成一对：
--     一个校验「我拥有它」，一个校验「我不重复拥有它」。
    assert(TheWorld == inst)
--★ TheWorld = nil —— 清空全局单例。
--   ★★ 必须清空：否则下一次 MakeWorld 的第 417 行检查会误判「世界已存在」，
--     导致新世界创建失败。这是「全局单例」纪律的核心要求。
--   ⚠ 若此处不清，第 543 行的 assert(TheFocalPoint == nil) 也会连锁失败。
    TheWorld = nil

--★★【第 363 行：assert(TheFocalPoint ~= nil) —— 销毁时的存在性断言】
--   ★ 与第 543 行创建时的 assert(TheFocalPoint == nil) 精确互逆。
--     一对断言把「创建—销毁」的配对契约写进了代码。
    assert(TheFocalPoint ~= nil)
--★ TheFocalPoint:Remove() —— 兴趣中心点实体随世界一同销毁。
--   ★★ 重要性：焦点实体是引擎层兴趣管理的输入（见文件头 §一 的 focalpoint 说明）。
--     世界没了而焦点还在，会导致引擎按一个已死实体的位置计算复制范围。
--   ⚠ 本机制在引擎层（C++ Sim），Lua 侧只有这个实体的生命周期管理。
--     参见 01-报告/04-联机同步-模组系统-UI.md:1318、05-原生C++引擎层.md:660。
    TheFocalPoint:Remove()
    TheFocalPoint = nil
end

--★★★【CreateTilePhysics —— 「地块碰撞」的定义入口，且可被完全替换】
--   ★★★ 设计要点：第 369-370 行优先用 inst.tile_physics_init（自定义实现），
--     只有为 nil 才走内置的两条 AddTileCollisionSet。
--   ★ 因此「物理覆盖」只需在初始化前给 inst.tile_physics_init 赋值即可，
--     无需继承、无需改本文件。这是本文件提供的**最佳扩展点**。
--   ★ 该字段的赋值点在第 450 行：inst.tile_physics_init = custom_data.tile_physics_init
--     来自 MakeWorld 的第 8 个参数 custom_data。
local function CreateTilePhysics(inst)
--★ 覆盖检查。tile_physics_init 的类型未做校验，赋非函数会在这里崩溃，
--   属「信任调用方」的约定式 API（custom_data 来自 MakeWorld 的调用者）。
    if inst.tile_physics_init ~= nil then
        inst:tile_physics_init()
    else
--★★【AddTileCollisionSet 的六个参数逐个读解 —— 这是理解地块碰撞的钥匙】
--   :373 COLLISION.LAND_OCEAN_LIMITS —— 碰撞组名：陆地与海洋的交界
--   :374 TileGroups.LandTiles —— ★★ 属于这个组的地图层：LandTiles
--   :375 false —— 「该组是否阻挡上层」标志（这里 false = 只作为被撞面）
--   :376 TileGroups.LandTiles —— ★★ 触发碰撞的地图层：同样是 LandTiles
--   :377 true —— 「是否阻挡下层」（true = 站在上面会被挡）
--   ★★ 参数 2/4 与 3/5 的配对关系：
--     (组→加入哪些层, 是否阻挡加入方) 与 (哪些层→对该组生效, 是否生效)。
--     理解成本高，但正是这种「双向声明」才能表达「站在 A 上不会掉进 B」这类规则。
--   :376 0.25 —— ★ 斜坡容差（0.25 格）：小于这个坡度视为平地，
--     避免在缓坡上把人弹飞。数值是手感调参，改动会影响所有角色移动。
--   :376 64 —— ★ 碰撞组优先级/阈值（64），同类参数，影响多组冲突时的胜出者。
        inst.Map:AddTileCollisionSet(
            COLLISION.LAND_OCEAN_LIMITS,
            TileGroups.LandTiles, false,
            TileGroups.LandTiles, true,
            0.25, 64
        )
--★★【第二组：不可通行地块（墙、悬崖），且带一个可切换的碰撞组】
--   :379 inst:CanFlyingCrossBarriers() and COLLISION.GROUND or COLLISION.LAND_OCEAN_LIMITS
--   ★★★ 这是本文件最巧妙的一行：碰撞组的名字在运行时决定。
--     判定式来自第 395 行的 CanFlyingCrossBarriers。
--   ★★ 语义：如果世界允许飞行者（幽灵/气球）穿越屏障，
--     那不可通行地块对它们就不算障碍 —— 于是把碰撞组换成 GROUND，
--     意思是「只对地面单位生效」。
--     对比第 373 行固定的 LAND_OCEAN_LIMITS（对所有人都生效的海陆交界）。
--   ★ 这就是「规则用数据表达」的典范：不变的是机制，变的只是一个组名。
--   :380-381 true / false —— 与第一组**恰好相反**的阻挡方向，
--     因为墙是「挡住别人」而不是「站在别人上面」。
--   :382 0.25 同第 376 行（斜坡容差），:382 128 优先级高于第一组的 64。
        inst.Map:AddTileCollisionSet(
            inst:CanFlyingCrossBarriers() and COLLISION.GROUND or COLLISION.LAND_OCEAN_LIMITS,
            TileGroups.ImpassableTiles, true,
--★ 注意第二组里 :380 是 true、:381 是 false，
--   与第一组的 (:375 false, :376 true) 正好对调。
--   ★ 推理：不可通行地块是「实体撞上它」，不是「实体站在它上面」，
--     所以它属于「加入方」而非「被加入方」。
            TileGroups.ImpassableTiles, false,
            0.25, 128
        )
    end
end

--★★【口袋维度容器 —— 「一个世界里的另一个世界」的一等公民】
--   两个函数构成最小 API：按名字存 / 按名字取。
--   ★ 这是「存储 + 接口」的直接手写示范，没有引入任何抽象基类。
--   用途：坎特伯雷盒子这类「随身携带的子世界」，其容器实体登记在此。
--   ★ 与 shardnetworking 的分片**完全不同** —— 必须区分清楚：
--     · 口袋维度 = 单个模拟进程内的子空间（这里，纯 Lua 字典）
--     · 分片 shard = 独立的模拟进程（shardnetworking.lua，走 SHARD_RPC）
--   ★ 挂载在第 608-610 行（主模拟分支内），因此只有服务端持有这张表。
local function SetPocketDimensionContainer(world, name, containerinst)
    world.PocketDimensionContainers[name] = containerinst
end

--★ Getter 是纯查表，无副作用。注意**返回 nil 不做校验**：
--   调用方必须自己处理「名字不存在」的情况。这是 Lua 的常见风格（信任调用方）。
local function GetPocketDimensionContainer(world, name)
    return world.PocketDimensionContainers[name]
end

--★★★【CanFlyingCrossBarriers —— 一个被挂到实体上的「策略函数」】
--   ★★★ 第 453 行 inst.CanFlyingCrossBarriers = CanFlyingCrossBarriers
--     把这个**文件级 local 函数**直接挂成实体的方法。
--   ★★ 为什么要这么绕？答案：可被模组/覆盖代码替换。
--     挂到 inst 上之后，模组可以写 world.CanFlyingCrossBarriers = 自己的函数，
--     而所有调用点（第 379 行）无需改动。这就是「策略注入」——
--     ★ 与第 453 行的 CanFlyingCrossBarriers、第 535-537 行的 PostInit 等
--       「Public member functions」区段是同一个模式。
--   ★ 函数名的选择式调用（inst:CanFlyingCrossBarriers()）会自动传入 self/world，
--     所以形参写的是 world 而不是 self —— ★ 注意这个签名：
--     它挂在实体上却被当 world 用，因为调用者是 `inst:CanFlyingCrossBarriers()`，
--     隐式参数就是 inst。命名与实际接收者不一致，是本文件的一处小瑕疵。
local function CanFlyingCrossBarriers(world) -- NOTES(JBK): Ghosts are flying in this case and has_ocean is backwards compatability.
--★★【两个条件都是「宽松兼容」的产物】
--   world.has_ocean —— 原注释标注 has_ocean 是「backwards compatability」
--     （向后兼容）：早期世界没有 has_ocean 字段，用它判断是否有海洋。
--   world.cancrossbarriers_flying —— 新字段，显式开关。
--   ★ 为什么是 or 而不是 and？
--     只要任一为真就允许飞行穿越 —— 保证老存档（只有 has_ocean）行为不变，
--     同时新世界可以用新字段单独控制。
--   ⚠ 副作用：想让飞行者**不能**穿越屏障的新世界，必须确保 has_ocean 为假。
--     若世界有海洋，cancrossbarriers_flying=false 会被 has_ocean=true 覆盖 ——
--     ⚠ 这是一个真实的语义缺口：两个布尔用 or 合并时无法表达「显式禁止」。
    return world.has_ocean or world.cancrossbarriers_flying
--★ 函数结束。参见文件头 §三 提到的移植注意事项。
end

--------------------------------------------------------------------------

--★★★★★【MakeWorld —— 本文件的心脏，也是理解「世界即预制体」的总钥匙】
--   七个参数，每个都有明确职责：
--     name              —— 预制体名（第 405 行用它判断是否要自引用）
--     customprefabs     —— ★ 额外预制体清单，与本文件的清单合并（第 408 行）
--     customassets      —— 额外资源，替换而非追加（第 615 行传给 Prefab）
--     common_postinit   —— ★ 「所有端都要跑」的初始化回调（第 547 行）
--     master_postinit   —— ★★ 「仅主模拟」跑的回调（第 593 行）
--     tags              —— ★ 给世界实体加的标签（第 433 行）
--     custom_data       —— ★★ 一个自由传参的口袋（第 402 行兜底为 {}），
--                         承载 tile_physics_init / common_preinit /
--                         cancrossbarriers_flying 三个定制点
--   ★★★ common_postinit 与 master_postinit 的二分是 DST 初始化架构的核心：
--     任何生物群系（地表、洞穴、森林）都要在这两个钩子里放自己的装配代码，
--     而**完全不需要改本文件**。本文件因此成为所有生物群系的公共基类。
--   参见 01-报告/01-核心架构-实体预制体组件.md（prefab 的继承与扩展）。
function MakeWorld(name, customprefabs, customassets, common_postinit, master_postinit, tags, custom_data)
--★★【custom_data = custom_data or {} —— 兜底，让后面可以无条件索引】
--   ★ 收益：后续第 450/452/455 行可以直接写 custom_data.xxx，
--     不必每处都做 `if custom_data ~= nil then`。这是「参数归一化」的典型写法。
	custom_data = custom_data or {}

--★ worldprefabs 是「本预制体可以 SpawnPrefab 出来的所有预制体」的最终清单。
--   ★★ 注意它与文件头的 prefabs 表**是两个不同的东西**：
--     文件头 prefabs（第 68-296 行）= 硬编码的基础清单
--     这里的 worldprefabs          = 实际传给 Prefab() 的那一份
--   ★ 二者通过「world 自引用 + customprefabs 追加」汇合（第 405-412 行）。
    local worldprefabs = {}
--★★★【name ~= "world" 时把 "world" 自己塞进清单 —— 自引用技巧】
--   ★★ 意图：当某个生物群系预制体（如 caves.lua 的 "cave"）复用本工厂时，
--     它也需要能生成标准 world 实体（用于生成洞穴世界的表层/传送等）。
--     而标准 world 预制体本身的清单里**不含自己**，所以要显式补上。
--   ★★ 若 name 已经是 "world"（第 618 行的首次调用）则不重复添加。
--   ★ 这是「预制体继承」在 Lua 里的手工实现方式：
--     没有类系统，而是「复用构造工厂 + 调整输入参数 + 合并清单」。
--   参见 gamelogic.lua 里对 MakeWorld 的多生物群系调用。
    if name ~= "world" then
        table.insert(worldprefabs, "world")
    end
--★★【customprefabs 用 ipairs（数组语义，顺序有意义）】
--   ★ 对比第 64 行与第 281-289 行用 pairs（字典语义，顺序无意义）。
--     这是本文件「遍历方式即语义」原则的第二次示范。
--   ★ 预制体清单的顺序影响 SpawnPrefab 的查找优先级吗？在 DST 里不影响，
--     但 ipairs 表达的是「这是一个有顺序的清单」的**意图**，属于防御性写法。
    if customprefabs ~= nil then
        for i, v in ipairs(customprefabs) do
            table.insert(worldprefabs, v)
        end
    end

--★★★★★【local function fn() —— 预制体的构造函数，MakeWorld 真正的实体工厂】
--   ★★★ 这个 fn 会被 Prefab(name, fn, ...) 接收，之后每次 SpawnPrefab("world")
--     都会执行一次。也就是说：**世界可以被反复创建**（虽然第 417 行会拦住第二个）。
--   ★ fn 的返回值是实体实例（第 612 行 return inst），Prefab 系统据此注册到 Ents。
--   ★★★ 整个函数体是一个「阶段化初始化」，分七段（见下方 AFTER 的阶段标注）：
--     ① 创建实体 + 建立单例（415-437）
--     ② 底层 C++ 组件（439-451）
--     ③ 地图渲染层三轮循环（459-523）
--     ④ 核心 Lua 组件与状态（525-532）
--     ⑤ 成员实体与相机焦点（534-545）
--     ⑥ 端分流：客户端在此提前返回（553-566）
--     ⑦ 仅主模拟的 15 个管理器组件（568-610）
--   ★★ 这套「先建通用骨架，再按端加料」的顺序，是任何多端游戏服务端的通用范式。
    local function fn()
--★ CreateEntity() —— 引擎侧工厂，返回一个裸实体（无 prefab 名、无组件）。
--   ★ 注意它**立刻**就注册进 Ents（GUID 已分配），所以下面第 422 行之前，
--     Ents 里已经有一个「没有完成的 world」了。这一点在第 417 行的失败分支里有影响。
--   参见 entityscript.lua:219（GUID 赋值与实体身份确立）。
        local inst = CreateEntity()

--★★★★★【⚠ 疑似缺陷 #1：重复世界检查会造成实体泄漏】
--   本行的意图正确（一个进程只能有一个世界），但**检查的位置错了**。
--   ── 推理依据（三条）──
--   1) 第 415 行 CreateEntity() 已经执行。该实体的 GUID 已分配，
--      且按 entityscript.lua 的约定已被放入 Ents 表。
--   2) 第 419 行 `return nil` 直接返回，**没有任何清理动作**：
--      既没有 inst:Remove()，也没有把实体从 Ents 摘掉。
--   3) 该实体的 GUID 被永久占用，而 Ents 里留下一具「没有 prefab 名、
--      没有组件、但 :IsValid() 可能为真」的僵尸记录。
--   ── 后果 ──
--   · 内存泄漏：一个越早期的僵尸实体。
--   · GUID 空间浪费：枚举循环（如第 305 行 pairs(Ents)）会遍历到它，
--     虽然 HasTag("player") 会过滤掉，但仍有遍历开销。
--   · 更隐蔽的问题：由于没有 prefab 名，任何 Print/调试输出会显示为 nil 前缀，
--     排查时容易误判为「幽灵实体」。
--   ── 正确的做法（仅记录，不修改）──
--   检查应在 CreateEntity() **之前**：即函数入口处先 if TheWorld ~= nil then return nil end。
--   或在失败分支补 inst:Remove()。
--   ★ 为什么这个缺陷很少触发？因为正常流程里 MakeWorld 只被调用一次，
--     且第 417 行的场景（同一个进程里连开两个世界）本来就属于异常路径。
--   ★ 它属于「异常路径不完整」，在移植时值得修正。
		if TheWorld ~= nil then
--★ 仅 print 不 assert —— ★ 与第 360/363/543 行的 assert 形成鲜明对比。
--   ★ 推理：这里**故意**不 assert，因为 MakeWorld 的调用方（gamelogic.lua）
--     可能合法地在探测「能否再建一个世界」，一个硬崩溃会破坏这种探测。
--     失败用「返回 nil + 打印」表达，是函数式 API 的常见约定。
--   ⚠ 但这也意味着调用方**必须检查返回值**，否则会在 nil 上继续操作。
			print("You cannot spawn multiple worlds!")
			return nil
		end

--★★★★★【TheWorld = inst —— 建立全局单例，世界从此有名字了】
--   ★★★ 这是整个 DST Lua 层最重要的一个全局赋值。
--   之后的每一行代码都可以用 TheWorld 指代世界，
--   无需从任何实体引用链上追溯。参见 main.lua:289 的 Ents 同级全局声明。
--   ★★ 赋值时机极其讲究：**在所有组件装配之前**。
--     因为接下来的代码（第 348 行的 ismastersim 判断、第 348-352 行的
--     WatchWorldState 等）以及任何被回调的代码都可能引用 TheWorld。
--     早赋值 = 早可用；晚赋值 = 初始化期间存在「TheWorld 是 nil」的窗口。
--   ★ 对称销毁在第 361 行（TheWorld = nil），
--     而第 360 行的 assert(TheWorld == inst) 保证「只有世界自己被删时才清全局」。
--   ★★ 推论：任何持有 TheWorld 的代码都必须容忍它为 nil —— 
--     这就是 networking.lua 里满地都是 `if TheWorld ~= nil` 的原因
--     （见 :147、:152、:157、:166、:186、:304、:659、:723、:734、:946、:952）。
        TheWorld = inst
--★★【inst.net = nil 与 inst.shard = nil —— 显式初始化两个「未来会被填」的字段】
--   ★ net 由 gamelogic.lua 创建 net.lua 预制体后挂上（见 prefabs/world_network.lua）。
--   ★ shard 与分片有关（见 shardnetworking.lua、:427 的 ismastershard）。
--   ★★ 为什么要显式置 nil 而不是不管？
--     Lua 里「未赋值的字段」读出来也是 nil，显式赋值不改变读取语义。
--     但显式化的价值是**声明意图**：让读者一眼看到这两个字段由外部填充。
--     ★ 这是一种常见的多文件协作约定，代价是本文件必须知道这两个字段的存在。
--   ★ 参见本文件第 336 行 `if inst.net ~= nil` 的条件性处理。
        inst.net = nil
        inst.shard = nil

--★★★★★【ismastersim = TheNet:GetIsMasterSimulation() —— 端判定的唯一权威】
--   ★★★ 详见本文件第 348 行的完整分析（四种运行身份）。
--   ★★ 赋值位置在此（第 426 行）而非使用处（第 348/564 行），
--     因为它要在 common_postinit（第 547 行）之前就绪 ——
--     ★ 生物群系的初始化代码常需要知道自己是不是权威端。
--   ★★ TheNet 是 C++ 侧对象（无 Lua 源码）。GetIsMasterSimulation 的语义：
--     「本进程是否持有模拟权威」。房主为真，专用服务器为真，纯客户端为假。
--   ⚠ 常见误用：把它当成「是不是单机」。正确写法是同时看 TheNet:IsDedicated()
--     （见第 553 行 `not TheNet:IsDedicated()`）——
--     ★ 两个谓词组合才能区分「房主」「专服」「客户端」三种情形。
--   参见 01-报告/04-联机同步-模组系统-UI.md 的联机模式判断小节。
        inst.ismastersim = TheNet:GetIsMasterSimulation()
--★★★【ismastershard —— 在 ismastersim 之上再分「主分片 / 次分片」】
--   inst.ismastershard = inst.ismastersim and not TheShard:IsSecondary()
--   ★★★ 逻辑：既是权威端，**且**不是次分片 → 才是主分片。
--   ★ 二分（主/次分片）的实际含义：
--     · 主分片 = 表层世界，持有跨分片的主状态（会话 id、投票、存档）
--     · 次分片 = 洞穴世界，是「附属」，状态需向主分片同步
--   ★ 对应判断实例：shardnetworking.lua:158/166/176/182/195 都用
--     `TheWorld.ismastershard` 作为「只有主分片才做这件事」的守卫。
--   ★ 与 Shard_IsMaster()（shardnetworking.lua:13）的关系：
--     后者是运行时函数判定，本行是实体上的缓存字段。两者同源。
--   ★ 「--V2C: Masters is hard」是作者对这套二元判定留下的吐槽注释：
--     分片与模拟权威的二维组合确实容易搞混，作者自己都觉得难。
--   TheShard 是 C++ 侧对象，无 Lua 源码。
        inst.ismastershard = inst.ismastersim and not TheShard:IsSecondary()
        --V2C: Masters is hard

--★★【两个内置标签，各有明确语义】
--   NOCLICK —— ★ 「鼠标点不中」。世界的点击应当穿透到地面/实体，
--     否则玩家点世界会一直命中世界本身。这是配合第 219 行 focalpoint 的常见配置。
--   CLASSIFIED —— ★★ 「私有数据」标记，同第 431 行下面 tile 提到的 classified 概念。
--     ⚠ 注意：世界自己带 CLASSIFIED 标签，但世界的 replicated 数据
--       （inst.state）仍通过第 325 行的 SetGameData 广播给全体客户端。
--       这说明 CLASSIFIED 是**实体粒度**的标记，不影响该实体的某些全局通道。
--     推理：SetGameData 是 TheNet 的全局广播接口，绕过了实体的可见性判定。
        inst:AddTag("NOCLICK")
        inst:AddTag("CLASSIFIED")

--★ tags 参数（MakeWorld 第 6 参）批量加标签，与第 430-431 行的内置标签并存。
--   ★ 用途：生物群系用它标记自己（如 cave 群系加 "cave" 标签）。
        if tags ~= nil then
            for i, v in ipairs(tags) do
                inst:AddTag(v)
            end
        end
--★ 阶段①结束。回顾此时 TheWorld 的状态：
--   已建立全局单例 + 打好两个标签 + 写入 ismastersim/ismastershard/net/shard 四个字段，
--   但**还没有任何组件**。从第 444 行起才逐步装配。
--   ★ 这段「先设好身份，再装能力」的顺序，保证后续任何代码读到的
--     ismastersim 都是可靠的。

--★★★【非网络实体：世界永不睡眠、且不持久化】
--   SetCanSleep(false) —— ★ 「休眠」在 DST 里指实体停止更新（省 CPU）。
--     实体可以睡，但**世界永远醒着** —— 因为世界一睡，逻辑刻就停摆。
--     ★ 这是理解世界特殊性的又一处证据：它虽是普通实体，却拿到了
--       「不许偷懒」的特权。参见 locomotor.lua 中关于休眠（doze/dormancy）的注记。
--   persists = false —— ★ 不参与存档。存档的是「世界内容」，不是「世界这个壳」。
--     所以存档里没有 TheWorld 实体，只有一堆内容实体的数据。
--     ★ 推论：加载存档时世界壳是**重新构建**的（本文件的 fn 跑一遍），
--     再把存档内容实体灌进来。这是「世界即预制体」的又一收益 —— 壳可重建。
        --[[Non-networked entity]]
        inst.entity:SetCanSleep(false)
        inst.persists = false

        --Add core components
--★★★【五个底层（C++）组件 —— 与 Lua 组件体系的对照】
--   ★ entity:AddTransform()   —— 坐标变换（位置/旋转/缩放）。C++ 侧。
--   ★ entity:AddMap()          —— 地图实体能力（本文件第 2 行 require 的 Map 组件扩展它）
--   ★ entity:AddPathfinder()   —— ★ 寻路能力。这一行是 locomotor 能工作的物理前提：
--       locator.lua 通过 TheWorld.Pathfinder 提交 A* 查询。
--       ⚠ 寻路算法本身在 C++ 侧，Lua 无源码。
--       参见 locomotor.lua 的 FindPath 与 01-报告/05-原生C++引擎层.md。
--   ★ entity:AddGroundCreep() —— 地表覆盖物（苔藓/路径）渲染能力
--   ★ entity:AddSoundEmitter() —— 声音发射器（本文件第 6-8 行的音频资源在此播放）
--   ★★ 与第 525 行起的 AddComponent 的区别：
--     entity:AddXxx  是**引擎侧**能力，一个实体只能加一次，是物理/渲染地基；
--     inst:AddComponent 是**Lua 侧**逻辑模块，可装几十个，是玩法地基。
--     两者是「引擎实体」与「Lua 实体脚本」两条正交的能力线。
--     参见 01-报告/01-核心架构-实体预制体组件.md。
        inst.entity:AddTransform()
        inst.entity:AddMap()
        inst.entity:AddPathfinder()
        inst.entity:AddGroundCreep()
        inst.entity:AddSoundEmitter()

--★ tile_physics_init 的注入点 —— custom_data（第 7 参）传入。
--   ★★ 这是本文件为生物群系预留的**物理层扩展点**，见第 368 行 CreateTilePhysics。
--   例如：洞穴世界的碰撞规则、玻璃世界（terrarium）的透明墙，都靠它覆盖。
        inst.tile_physics_init = custom_data.tile_physics_init

--★★【第 452 行原注释的「Intentionally not a table for searchability」值得展开】
--   inst.cancrossbarriers_flying = custom_data.cancrossbarriers_flying
--   ★ 这是一个**布尔字段**而不是一个「世界配置表」：
--     若做成表，就能承载任意多个开关，但那样就没法用 Ctrl+F 直接搜到
--     「谁读了这个字段」，也让「只有一个开关」这件事变得不明确。
--   ★★ 原注释本身就把「可搜索性」当作设计目标 —— 
--     这是一种「为未来维护者优化」的设计意识：在项目后期，
--     找到所有读写点比结构灵活性更重要。
--   ★ 参见 01-报告/00-注释规范与术语表.md（可搜索性约定）。
--   ⚠ 语义缺口见第 396 行：has_ocean 会覆盖本字段的 false。
        inst.cancrossbarriers_flying = custom_data.cancrossbarriers_flying -- Intentionally not a table for searchability.
--★★★【策略注入：把文件级函数挂成实例方法】
--   inst.CanFlyingCrossBarriers = CanFlyingCrossBarriers
--   ★ 这就是「可被覆盖的公开方法」的挂载方式。与第 535-537 行的
--     PostInit / OnRemoveEntity / CreateTilePhysics 同属一个区段。
--   ★★★ 注意第 453 行挂载的是**函数对象**，不是函数调用：
--     所以这里不是 inst.CanFlyingCrossBarriers() = ...（那样会立即执行）。
--     理解 Lua 的「函数是一等值」这一点，就理解了整个覆盖机制。
        inst.CanFlyingCrossBarriers = CanFlyingCrossBarriers

--★★【common_preinit —— ★ MakeWorld 第 7 参 custom_data 里的第二个钩子】
--   ★ 位置关键：在第 459 行地图初始化**之前**，在第 460 行那三轮循环前。
--   ★ 用途：生物群系在地图铺好之前先做定制（比如改变地表配置）。
--   ★★ 与 common_postinit（第 547 行）构成 pre/post 一对 —— 
--     「地图初始化之前」与「之后」。命名完全对称，便于记忆。
--   ★ custom_data 里三个定制点：tile_physics_init（物理）、
--     common_preinit（早期钩子）、cancrossbarriers_flying（飞行规则）。
        if custom_data.common_preinit ~= nil then
            custom_data.common_preinit(inst)
        end

--★★★★★【地图初始化：三轮循环建立渲染层 —— 本文件最长的机械代码段（459-523）】
--   ★★ 三轮循环严格对应 worldtiledefs.lua 的三张表：
--     第 460 行 ipairs(GroundTiles.ground)   → 地面 → inst.Map:AddRenderLayer
--     第 496 行 ipairs(GroundTiles.creep)    → 苔藓 → inst.GroundCreep:AddRenderLayer
--     第 507 行 ipairs(GroundTiles.falloff)  → 衰减 → inst.Map:AddFalloffTexture
--   ★ 为什么要建「渲染层」而不是直接画？
--     渲染层是 GPU 侧的独立纹理/图集，支持动态合批、材质替换、按层遮挡排序。
--     一张地图有几十种地表 → 几十个渲染层，但每层一次 draw call，
--     而不是每块地一次。这是开放世界地形的标准做法。
--   ★ 三个循环的 `unpack(data)` 完全一致，每项都是 {tile_id, layer_properties}：
--     数组式元组 —— 第一项是 tile_id（用于后续查表），第二项是图层属性。
--     ★ 用元组而非 table.key=value 是刻意的：省内存、省解析，
--       因为这张表在加载期要遍历上百次。
--   ⚠ 三轮循环的 CreateRenderLayer 参数**不完全一致**（见第 472 行 vs 498 行），
--     第 460 行那轮多了 atlas/texture_name 的默认值推导与 resolvefilepath，
--     另两轮直接透传。这说明 ground 表的 layer_properties 更「厚」
--     （带颜色信息），而 creep/falloff 的属性更简单。
        --Initialize map
        for i, data in ipairs(GroundTiles.ground) do
            local tile_id, layer_properties = unpack(data)
--★★【不可见地块组：两个「不能在地图 finalize 后调用」的警告】
--   GROUND_NOGROUNDOVERLAYS —— 「这一类地块上不铺地表覆盖物」
--   ★ 原注释两次出现完全相同的话：
--     "Do not call this after the map finalizes a crashing race condition may occur!"
--   ⚠★★ 这是全文件最强的警告，翻译过来：
--     「地图 finalize 之后再调用这些函数会崩溃（存在竞态）」。
--   ★★ 推理：finalize 是引擎把可变地图固化为不可变结构的时刻；
--     在那之后修改地块分组会与正在进行的贴图/网格构建并发，产生竞态。
--   ★ 因此这段代码**必须**在地图构建开始前跑完 —— 
--     也就是被放在第 459 行那三轮循环**之内**（紧跟 tile 解析），
--     而不是循环之后的独立步骤。这是「顺序即正确性」的例子。
--   ★ 移植时若把这两行挪到别处（例如挪进 common_postinit），会直接崩溃。
            if GROUND_NOGROUNDOVERLAYS[tile_id] then
                TileGroupManager:SetNoGroundOverlays(tile_id) -- NOTES(JBK): Do not call this after the map finalizes a crashing race condition may occur!
            end
--★★【隐形地块组：三件事，且比上面那组多一步】
--   GROUND_INVISIBLETILES —— 「这一类地块看不见」
--   :466 SetInvisibleTile      —— 标记为隐形（同样有 finalize 竞态警告）
--   :467 AddValidTile(LandTilesInvisible)  —— ★ 同时**加入**一个有效组：
--     隐形地块仍然是「合法地面」（玩家可以站在上面），只是画不出来。
--   :468 AddInvalidTile(LandTilesWithDefaultFalloff) —— ★ 同时**移出**一个组：
--     隐形地块不应该有默认的边缘衰减效果。
--   ★★★ 一次声明，两个方向的操作 —— 说明「隐形」不是单一维度：
--     渲染上不可见 ✓、碰撞上合法 ✓、视觉衰减上无效 ✓。
--     这种「每种隐藏各有各的处理」的设计避免了分支判断散落各处。
            if GROUND_INVISIBLETILES[tile_id] then
                TileGroupManager:SetInvisibleTile(tile_id) -- NOTES(JBK): Do not call this after the map finalizes a crashing race condition may occur!
                TileGroupManager:AddValidTile(TileGroups.LandTilesInvisible, tile_id)
                TileGroupManager:AddInvalidTile(TileGroups.LandTilesWithDefaultFalloff, tile_id)
            end
--★★★【CreateRenderLayer 的四个参数 —— 渲染层的完整定义】
--   :471 tile_id —— ★ 内嵌数组下标（注释直说 embedded map array value）。
--     它同时是「地图层的索引」与「这张图层的身份标识」，两者合一。
--   :472 layer_properties.atlas or resolvefilepath(GroundAtlas(layer_properties.name))
--     ★★ 两级回退：优先用显式给的 atlas；没有就按 name 去 GroundAtlas 查，
--       再套 resolvefilepath 把「游戏资源路径」转成「绝对文件路径」。
--     ★ 为什么这里要 resolvefilepath 而第 498 行不用？
--       因为 ground 表的 name 可能是逻辑名（如 "grass"）而非路径，
--       必须经 GroundAtlas() 映射；creep/falloff 表给的是完整路径，直接透传。
--     ★★ 这是全文件最能体现「数据驱动」的一行：
--       渲染层的贴图由 worldtiledefs 的数据决定，本文件只做「名字→路径」翻译。
--   :473 texture_name or resolvefilepath(GroundImage(name)) —— 主纹理，同模式。
--   :474 resolvefilepath(noise_texture) —— ★ 噪声纹理（无回退，必须给）。
--     用途：给地表加随机扰动，避免大面积同色贴图的「塑料感」。
            local handle = MapLayerManager:CreateRenderLayer(
                tile_id, --embedded map array value
                layer_properties.atlas or resolvefilepath(GroundAtlas(layer_properties.name)),
                layer_properties.texture_name or resolvefilepath(GroundImage(layer_properties.name)),
                resolvefilepath(layer_properties.noise_texture)
            )
--★ layer_properties._render_layer = i —— ★★★ 把循环下标写回数据表本身！
--   ★ 这是「双向引用」的建立：数据表 → 渲染层序号。
--   ★★ 为什么数据表需要知道自己的渲染层序号？
--     因为后续逻辑（比如生物群系代码、地表查询）拿着一个 layer_properties，
--     需要反查它对应哪个渲染层做特判（换贴图、改颜色）。
--   ⚠ 下划线前缀 _ 表示「内部字段」，是本项目的命名约定（见 class.lua 的属性约定）。
--   ★ 注意它写的是 `layer_properties`（worldtiledefs 里的原始数据），
--     而不是某个副本 —— ★ 所以这会**污染全局共享的数据表**。
--     在同一进程只建一次世界的前提下无害；多世界场景需要留意。
			layer_properties._render_layer = i

--★★【可选颜色：四组颜色，双模式设置 —— 昼夜与昼夜黄昏】
--   colors 为 nil 时整段跳过（这是可选字段）。
--   :480 primary_color / :481 SetPrimaryColor —— 主色
--   :482 secondary_color / :483 SetSecondaryColor —— 次色
--   ★ :484 secondary_color_dusk / :485 SetSecondaryColorDusk —— ★★ 「黄昏版次色」
--     地表颜色会随一天时间变化（SetSecondaryColorDusk 是引擎侧的黄昏通道）。
--     ★ 这意味着「白天地表颜色」与「黄昏地表颜色」是两个独立通道，
--       由引擎在昼夜循环中混合。Lua 只需各填一次。
--   :486 minimap_color / :487 SetMinimapColor —— ★ 小地图颜色，独立的第四组。
--     小地图不能靠缩放主图（地表在小地图上要简化），故单独指定。
--   ★★ 全部 /255 转成 0-1 浮点：引擎的 Set*Color 接受归一化颜色。
--     Lua 侧存储整数色（方便从数据文件写 255,0,0），边界处转换一次。
            local colors = layer_properties.colors
            if colors ~= nil then
				local primary_color = colors.primary_color
                MapLayerManager:SetPrimaryColor(handle, primary_color[1] / 255, primary_color[2] / 255, primary_color[3] / 255, primary_color[4] / 255)
				local secondary_color = colors.secondary_color
				MapLayerManager:SetSecondaryColor(handle, secondary_color[1] / 255, secondary_color[2] / 255, secondary_color[3] / 255, secondary_color[4] / 255)
				local secondary_color_dusk = colors.secondary_color_dusk
				MapLayerManager:SetSecondaryColorDusk(handle, secondary_color_dusk[1] / 255, secondary_color_dusk[2] / 255, secondary_color_dusk[3] / 255, secondary_color_dusk[4] / 255)
                local minimap_color = colors.minimap_color
                MapLayerManager:SetMinimapColor(handle, minimap_color[1] / 255, minimap_color[2] / 255, minimap_color[3] / 255, minimap_color[4] / 255)
            end

--★ inst.Map:AddRenderLayer(handle) —— 把 handle 挂到实体上。
--   ★★ 第 491-493 行的 TODO 是本文件最重要的一条技术债注释：
--     「本对象销毁时这些 handle 应当被释放，但现在因为地图寿命等于游戏寿命
--     所以不是问题；一旦这点改变，就必须正确清理，否则泄漏内存。」
--   ★★ 推理为什么现在不释放：渲染层是 GPU 资源，一个进程只建一次世界，
--     泄漏量有界（几十个句柄），不值得为此写清理代码。
--   ★ 但在「分片热重载」「快速重连」「单元测试反复建世界」场景下会累积。
--   ★ 移植建议：把渲染层 handle 收集到一个表，OnRemoveEntity 里统一释放。
            inst.Map:AddRenderLayer(handle)
            --TODO: When this object is destroyed, these handles really should be freed. At this time,
            --this is not an issue because the map lifetime matches the game lifetime but if this were
            --to ever change, we would have to clean up properly or we leak memory.
        end

--★★【creep（地表覆盖物）循环 —— 三轮中最简单的一轮】
--   对比第 460 行那轮：
--     · 无颜色处理（creep 没有昼夜色变）
--     · CreateRenderLayer 的参数**直接透传**（无 atlas 推导、无 resolvefilepath）
--     · 挂载目标是 inst.GroundCreep 而非 inst.Map（第 504 行）
--   ★ 说明 creep 数据的属性字段已经是完整路径，且颜色由别处（贴图自身）决定。
--   ★ 「creep」= 地衣/苔藓/踩出的路，是覆盖在基础地表之上的一层。
        for i, data in ipairs(GroundTiles.creep) do
            local tile_id, layer_properties = unpack(data)
            local handle = MapLayerManager:CreateRenderLayer(
                tile_id,
                layer_properties.atlas,
                layer_properties.texture_name,
                layer_properties.noise_texture
            )
--★ inst.GroundCreep:AddRenderLayer(handle) —— 挂到 GroundCreep 而非 Map。
--   ★ 与第 447 行 inst.entity:AddGroundCreep() 配套：那里建能力，这里挂内容。
            inst.GroundCreep:AddRenderLayer(handle)
        end

--★★★【falloff（衰减/过渡）循环 —— 第三轮，也是语义最特殊的一轮】
--   ★ falloff = 「从一种地表过渡到另一种」时的边缘羽化纹理。
--     例如草地与沙滩的交界处不是硬边，而是一段渐变 —— 那段就是 falloff。
--   ★ 它的作用是**消除硬边界的视觉突兀**，属于美术层面的必需配置，
--     不是物理数据。所以挂在 Map 但不参与任何碰撞判定。
        for i, data in ipairs(GroundTiles.falloff) do
            local tile_id, layer_properties = unpack(data)
            local handle = MapLayerManager:CreateRenderLayer(
                tile_id,
                layer_properties.atlas,
                layer_properties.texture_name,
                layer_properties.noise_texture
            )

--★★★【AddFalloffTexture 的五个布尔参数 —— 三个「谁说了算」的规则对】
--   :517 should_have_falloff          —— 这一层**自己**是否产生衰减
--   :518 should_have_falloff_result   —— 「有衰减」的最终结果（可被邻居覆盖）
--   :519 neighbor_needs_falloff        —— 这一层**是否需要**邻居配合
--   :520 neighbor_needs_falloff_result —— 「需要配合」的最终结果
--   ★★ 规律：**每个规则都成对出现「输入」与「结果」两个参数**。
--     结果参数的存在说明最终值可以由**双向协商**决定：
--     当 A 说「我需要你」而 B 说「我不提供」时，结果由协商决定，
--     而不是任一方单方面强制。
--   ★ 这是典型的「渐进式材质混合」需求：只有两侧都同意，过渡才成立。
--   ⚠ 代价：理解成本高，且无法从参数名看出协商规则（需查引擎文档）。
            inst.Map:AddFalloffTexture(
                handle,
                layer_properties.should_have_falloff,
                layer_properties.should_have_falloff_result,
                layer_properties.neighbor_needs_falloff,
                layer_properties.neighbor_needs_falloff_result
            )
        end

--★★★【阶段④：核心 Lua 组件 —— 三个「必需」组件 + 状态别名】
--   :525 worldsettings —— ★ 世界设置袋（键值对）。
--     组件本身只有 23 行（components/worldsettings.lua）：
--       一个 self.settings 表 + 一个 ms_setworldsetting 事件监听。
--     ★ 它是世界设置的**存储**，而设置的实际生效由各消费方负责。
--   :528 worldstate —— ★★ 世界 Lua 状态（cycles / season / 天数等）。
--   :529 inst.state = inst.components.worldstate.data —— ★★★ 关键别名。
--     ★★ 这行把组件的内部 data 表**直接暴露**成 inst.state 字段。
--       于是全游戏可以用 TheWorld.state.cycles 访问状态，
--       而不必写 TheWorld.components.worldstate.data.cycles。
--     ★ 这是「外观模式」的手工实现：省一次索引，且让访问语法更短。
--     ⚠ 代价：**别名即契约**。任何人替换了 inst.state 指向，
--       worldstate 组件就与调用方脱钩；反之修改 worldstate.data 会直接
--       穿透到所有读 inst.state 的地方（无中间层拦截）。
--       ★ 第 319-324 行与第 349-352 行都直接读写这份别名。
--     交叉引用：components/worldstate.lua（data 的实际字段定义）。
        inst:AddComponent("worldsettings")

        --Initialize lua world state
        inst:AddComponent("worldstate")
        inst.state = inst.components.worldstate.data

        --Initialize lua components
--★ groundcreep —— 地表覆盖物的 Lua 侧组件（对应第 447 行的 C++ AddGroundCreep）。
--   ★ 第 496-505 行已把渲染层挂到 inst.GroundCreep，这个组件提供逻辑（铺设/清除规则）。
        inst:AddComponent("groundcreep")

--★★★【阶段⑤：Public member functions —— 挂载本文件定义的四个函数】
--   PostInit（第 535 行）、OnRemoveEntity（536）、CreateTilePhysics（537）
--   ★★ 这四个函数在文件顶部定义（第 335/357/368 行），
--     全部是**无 local 的全局函数** —— 因为它们要成为实体的方法，
--     必须能被框架从实体上按名字取到。
--   ★ 挂载后它们可以互相调用，也可以被模组替换。
--   ★★ 这区「文件级 local 函数 + 实例方法」的组织方式，
--     是 DST 里实现「可覆盖的默认行为」的标准手法：
--     模组写 world.PostInit = function(...) ... 原调用 ... end 即可包裹。
        --Public member functions
--★ 三行挂载的是同一个概念的三种用途：
--   PostInit        —— 框架在实体初始化完成时回调
--   OnRemoveEntity  —— 框架在实体被移除时回调
--   CreateTilePhysics —— 供生物群系在合适时机手动调用
        inst.PostInit = PostInit
        inst.OnRemoveEntity = OnRemoveEntity
        inst.CreateTilePhysics = CreateTilePhysics

        --Initialize minimap
--★★【SpawnPrefab("minimap") —— 世界的第一个成员实体】
--   ★ 因为 minimap 在第 73 行的预制体清单里，所以这里一定成功。
--   ★ 成员实体的生命周期由世界管理：创建于第 540 行，销毁于第 358 行。
--   ★ 交叉引用 networking.lua:660-663 —— 玩家迁移服务器前要
--     SerializeUserSession 保存本地小地图，说明 minimap 有需持久化的状态。
--   ⚠ 没有判空。若 minimap 从清单里被移除，第 358 行会崩。
        inst.minimap = SpawnPrefab("minimap")

--★★★【阶段⑤续：兴趣中心点 —— 实体复制范围的锚】
--   第 543-545 行三行是一组：断言全局为空 → 创建 → 设为相机目标。
--   ★★ 详细意义见文件头 §一 的 focalpoint 说明：
--     这是兴趣管理（interest management）在 Lua 侧**唯一**的产出。
--   ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现：
--     C++ 用 TheFocalPoint 的位置加半径，决定给每个客户端复制哪些实体。
--     参见 01-报告/04-联机同步-模组系统-UI.md:1318、05-原生C++引擎层.md:660。
        --Initialize local focal point
--★★【assert(TheFocalPoint == nil) —— 「确保我不是第二个世界」】
--   ★ 与第 360 行销毁时的 assert(TheFocalPoint ~= nil) 精确互逆。
--   ★ 推理：若这条断言触发，说明 TheWorld 的清理（第 361 行）失败了，
--     或有人手动清了 TheWorld 却没走 OnRemoveEntity。
--   ★★ 这一对断言是「全局单例纪律」的可执行版本：
--     创建时断言「我不该存在」，销毁时断言「我存在过」。
        assert(TheFocalPoint == nil)
        TheFocalPoint = SpawnPrefab("focalpoint")
--★★★【TheCamera:SetTarget(TheFocalPoint) —— 相机跟随兴趣中心点】
--   ★★★ 双重身份：TheFocalPoint 同时是
--     ① 相机跟随目标（表现层：镜头对准哪里）
--     ② 兴趣管理中心点（网络层：给谁复制实体）
--   ★★ 把两者绑在一起的设计意图：
--     「玩家看到的画面中心」与「客户端需要的数据范围」理应是同一个中心，
--     否则玩家能看见的实体反而没被复制（画面里有「幽灵」）。
--   ★ 这是一个典型的「一个对象满足两个正交需求」的架构决策 ——
--     省了一次同步，也避免了两个中心不一致导致的诡异 bug。
--   ★ 推论：模组若想改复制半径，改焦点实体的影响面远大于想象中。
--   TheCamera 是 C++ 侧对象，无 Lua 源码。参见 01-报告/05-原生C++引擎层.md。
        TheCamera:SetTarget(TheFocalPoint)

--★★★【common_postinit —— 「所有端都要跑」的生物群系钩子】
--   ★★ 与第 593 行的 master_postinit 构成核心二分：
--     · common_postinit（第 547 行）：**每个进程**都跑一次（含纯客户端）。
--       用途：生物群系的地表配置、地图装饰、客户端可见的资源。
--     · master_postinit（第 593 行）：**仅主模拟**跑一次。
--       用途：服务端权威逻辑（刷怪、任务、存档相关）。
--   ★★ 这个二分让生物群系代码能安全地写「两端都要做的准备」
--     而不必自己判断 ismastersim —— 判断的责任被本文件收拢了。
--   ★ 位置在第 551 行 SetPrefabName **之前** ——
--     钩子执行时 prefab 名还没设好，因此钩子里不能依赖 self.prefab。
--     ★ 这是一个容易踩的顺序坑：prefabs 必须放到最后再设。
        if common_postinit ~= nil then
            common_postinit(inst)
        end

--★★★【SetPrefabName("world") —— ★★ 故意放在整个初始化的最后一步】
--   原注释："the actual prefab to load comes from gamelogic.lua, this is for postinitfns."
--   ★★ 翻译：真正决定「加载哪个预制体」的是 gamelogic.lua，这里设的名字
--     只是给 postinit 回调函数（PostInit 等）用的占位名。
--   ★★★ 为什么要放最后？三个理由（顺序即正确性）：
--     ① 第 547 行的 common_postinit 与第 593 行的 master_postinit
--        都会被框架当作 postinitfn 触发，它们**可能读 self.prefab**；
--        在名字就绪后才设，两者才能正确工作。
--     ② 第 540 行的 SpawnPrefab("minimap")、第 544 行的 SpawnPrefab("focalpoint")
--        都不需要世界的 prefab 名，提前设置没有收益。
--     ③ 若中途抛错，实体仍无 prefab 名，更容易在日志里被发现（不会伪装成半个 world）。
--   ★★ 与第 417 行的重复世界检查对照：那一处在最前面就 return nil，
--     永远不会执行到这行 —— 顺序保证了失败路径的隔离。
--   ⚠ 移植警告：任何在 fn 尾部之后插入代码的修改，都要确认是否抢在设名前面。
        inst:SetPrefabName("world") -- the actual prefab to load comes from gamelogic.lua, this is for postinitfns.

--★★★【阶段⑥的第一道分流：`not TheNet:IsDedicated()` —— 「是不是有画面的进程」】
--   ★★★ 为什么用 IsDedicated 而不是 ismastersim？
--     因为这里要判断的是「**有没有本地显示**」，与「是否权威」是两个正交维度：
--       · 房主（host）：      ismastersim=true,  IsDedicated=false → 需要 UI 组件
--       · 专用服务器：        ismastersim=true,  IsDedicated=true  → 不需要
--       · 纯客户端：          ismastersim=false, IsDedicated=false → 需要 UI 组件
--   ★★ 所以这一段三个组件在「房主」与「纯客户端」上都会装 ——
--     房主虽然权威，但同时也要显示画面。
--   ★★★ 这是全文件最该记住的一组对照：
--     ismastersim  = 「我是权威吗」（决定逻辑）
--     IsDedicated  = 「我有界面吗」（决定表现）
--     两者正交，组合起来才是完整的运行身份判定。
--   TheNet 是 C++ 侧对象，无 Lua 源码。参见 01-报告/04 的联机模式判断小节。
        if not TheNet:IsDedicated() then
--★★【三个纯表现组件：只在「有界面的进程」上装】
--   oceancolor —— ★ 海水颜色渐变。客户端逐帧根据玩家位置/时间算颜色，
--     服务端不需要，白装就是纯浪费。
--   nutrients_visual_manager —— 土壤营养的**视觉**部分。
--     ★★ 注意与第 577 行 farming_manager 的分工：
--       视觉（是否安装放肥料）在这里，逻辑（季节掉率、肥沃度）在 farming_manager。
--       ★ 「同一功能拆成表现组件 + 逻辑组件」是 DST 处理多端的通用手法。
--   hudindicatablemanager —— HUD 图标的全局注册与显示仲裁。
--     与第 209 行的 hud 预制体配套。
            inst:AddComponent("oceancolor")
            inst:AddComponent("nutrients_visual_manager")
            inst:AddComponent("hudindicatablemanager")
        end
--★ 裸 `--` 分隔符，标记「非专服专属段」结束（源码风格，非笔误）。
--   第 214 行有完全相同的用法。
        --
--★★★[walkableplatformmanager —— 可站平台的全局登记表 ★ 移动系统的关键依赖]
--   ★★ 它管的是船、矿车这类「能站上去的移动平台」。
--     locomotor.lua 的跳跃（hopping）机制要向它查询「哪些平台我能跳上」
--     并做容量预约（避免两个实体预约同一个平台位置）。
--   ★ 交叉引用：
--     · components/walkableplatformmanager.lua（组件本体）
--     · components/walkableplatform.lua（单个平台实体）
--     · locomotor.lua 的 ScanForPlatform / StartHopping（预约的消费者）
--   ★ **本组件在所有端都装**（不受 :553 或 :564 的条件限制），
--     因为客户端也要预测跳跃落点 —— ★ 跳跃是客户端预测行为，
--     客户端必须知道平台上有哪些空位才能做出正确的预测。
--   ★ 对比第 568 行起的一堆仅主模拟组件：这里体现的是「客户端需要预测」的例外。
        inst:AddComponent("walkableplatformmanager")

--★★[waterphysics —— 水体物理，且立刻配置弹性系数]
--   :562 restitution = 0.75 —— ★★★ 弹性系数 0.75 是硬编码的调参结果。
--   ★ restitution（恢复系数）= 碰撞后保留的速度比例。0.75 意味着
--     每次弹跳保留 75% 速度 —— 落水时有明显的「弹一下再沉」的观感。
--   ★ 为什么直接改组件字段而不是通过组件方法？
--     因为这是**世界级**的一次性配置，与具体实体无关；
--     水体物理组件被所有涉水实体共用，改一次即可全局生效。
--   ★★ 立即赋值（而非等组件的 OnPostInit）说明该字段是纯数据、
--     没有依赖初始化的副作用。
--   交叉引用：components/waterphysics.lua、components/drownable.lua（落水判定）。
        inst:AddComponent("waterphysics")
--★ 呼应第 561 行注记：waterphysics 是所有端共享的，
--   因为客户端也要预测落水（drownable 组件）。
        inst.components.waterphysics.restitution = 0.75

--★★★★★【★ 整个 MakeWorld 的性能命门：纯客户端在此直接返回】
--   if not inst.ismastersim then return inst end
--   ★★★ 这三行是整个文件最重要的性能设计：
--     第 568-610 行要装 15 个组件，任何一个都要做初始化工作、
--     监听事件、分配内存。纯客户端**一个都不需要**。
--     在这里 return，等于让纯客户端的世界初始化成本减少一大半。
--   ★★ 为什么不能靠「组件内部自己判断 ismastersim 然后立即返回」？
--     因为 AddComponent 本身的开销（创建组件对象、注册进表）已经发生了。
--     ★ 省成本要省在「不调用 AddComponent」这一层。
--   ★★★ 这是「早退（early return）」作为性能优化的教科书用例：
--     不是在每个组件内部各判一次，而是找到共同的汇合点，一次判断。
--   ★★ 对应 networking.lua:660/723/734 的三处 ismastersim / ismastershard 判断，
--     同一套判定被整个项目复用。
        if not inst.ismastersim then
            return inst
--★ 客户端在此返回。★ 注意此时客户端已经完成的东西：
--   · TheWorld 全局单例（第 422 行）
--   · 五个底层 C++ 组件（第 444-448 行）
--   · 地图全部渲染层（第 460-523 行）—— ★ 客户端必须有地图才能渲染
--   · worldstate + inst.state 别名（第 528-529 行）
--   · minimap 与 TheFocalPoint（第 540/544 行）
--   · 三个表现组件（第 554-556 行）
--   ★ 即「客户端拿到了完整的渲染能力，但没有服务端逻辑能力」。
--   ★ 这正是联机架构的精确表述：客户端是权威的**表现层副本**。
        end

--★★★★★[阶段⑦：仅主模拟的 15 个管理器组件 —— 文件头 §四 有逐个职责清单]
--   下列逐个组件的详细职责见文件头「【★ 23 个管理器组件逐个职责】」一节，
--   此处只标注设计上的分类与要点。
--   ┌─ 跨分片 / 网络 ────────────────────────────────┐
        inst:AddComponent("shardtransactionsteps")

--★ klaussackloot —— 小鸡（Klaus Sack）与神秘雕像的战利品机制。
--   ★ 名字来源是游戏内的 NPC「克laus·萨克」。归在主模拟是因为它影响掉落。
        inst:AddComponent("klaussackloot")

--★★[undertile —— 地板之下：洞穴层的实体管理]
--   ★★ 这是「双向世界」在 Lua 侧的管理者：表面世界与洞穴世界是同一存档的
--     两个区域，undertile 负责洞穴区域的实体生命周期。
--   ★ 与 shardnetworking 的关系：
--     洞穴在**分片模式**下可能是独立进程（次分片），
--     在**非分片模式**下则是同一个进程的「地下一层」。
--     ★ undertile 管的是后者（后者是默认的双向世界形态）。
--   ★ ★ 这是容易混淆的一点：**「地下」≠「分片」**。
--     双向世界的洞穴 = 同进程地下一层（undertile 管）；
--     分片集群的次分片 = 独立进程（shardnetworking.lua 管）。
        inst:AddComponent("undertile")

--★[worldsettingstimer —— 世界设置变更的定时回调]
--   ★★ 注意：AddComponent("worldsettingstimer") 这一行在本文件是**首次注册**该组件
--     的地方之一，但组件本体（components/worldsettingstimer.lua，236 行）
--     还会被 worldsettingsutil.lua:91/110/197/256 以及多个 prefab 挂载。
--   ★ worldsettingstimer 是「季节设置变更」的回调宿主 ——
--     DST 的世界设置是分级的（世界级/季节级），季节到来时世界级设置要变化，
--     这个组件负责在恰当的时机推送变更与重算。
--   交叉引用：components/worldsettingstimer.lua、worldsettingsutil.lua。
        inst:AddComponent("worldsettingstimer")
--★★[timer —— 通用定时器，是 DoPeriodicTask 等机制的实际宿主]
--   ★★ 单独提出来：entityscript.lua 的 DoPeriodicTask/DoTaskInTime 会把任务
--     挂到**实体**上，而世界的任务需要有一个全局的时钟源来驱动它们。
--     timer 组件提供这个源。
--   ★ 对比第 340 行的 inst:LongUpdate(0) —— 那是长更新钩子，
--     而 timer 是**周期性任务**的容器，两者都是「时间驱动的世界维护」。
        inst:AddComponent("timer")

--★ farming_manager —— 农场全局规则：季节掉率、土壤肥沃度、腐化。
--   ★ 与第 555 行 nutrients_visual_manager 的分工见该行注记（逻辑 vs 视觉）。
        inst:AddComponent("farming_manager")

--★ dockmanager —— 码头与龙骸（Fire Keeper）类停靠点的全局管理。
--   ★ 与第 275-276 行的 vinebridgemanager 同属「可交互世界设施的管理器」类别：
--     负责设施的注册、状态维护、以及在玩家交互时的调度。
        inst:AddComponent("dockmanager")
        inst:AddComponent("vinebridgemanager")
--★ worldroutes —— 世界路线图数据（地图 UI 与传送点路径）。
--   ★ 名字里的 routes 指的是「导航路线」而非「HTTP 路由」。
        inst:AddComponent("worldroutes")

--★★★[playerspawner —— 出生点选择与出生流程，全文件最常用的管理器]
--   ★★ 被 networking.lua:269 跨文件调用：
--     TheWorld.components.playerspawner:SpawnAtNextLocation(TheWorld, player)
--     —— 在 SpawnNewPlayerOnServerFromSim 里给新玩家选出生点。
--   ★ 与本文件第 300 行 OnPlayerSpawn 的关系（完整出生时序）：
--     ① 服务器侧：networking.lua:269 SpawnAtNextLocation 选点并放置
--     ② 服务器侧：networking.lua:270 SerializeUserSession 立刻存档新玩家
--     ③ 引擎派发 ms_playerspawn → 本文件第 606 行监听 → 第 301 行延迟一刻
--     ④ 第 302 行 auto_teleport_players 分支（调试用）
--   ★★ 这条链路横跨 networking.lua 与 world.lua 两个文件，
--     是理解「跨文件协作」的最好例子。
        inst:AddComponent("playerspawner")

--★ nightlightmanager —— 夜晚光照管理（照明半径、无光区域、光衰减）。
--   ★ 相关组件：moonlightcontroller、lightningreducer 等（各自在别处挂载）。
        inst:AddComponent("nightlightmanager")
--★ winonateleportpadmanager —— 汇智之帽（Winona）传送基座的全局登记。
--   ★ 命名规律：{角色名}*manager —— 角色专属功能的管理器。
        inst:AddComponent("winonateleportpadmanager")

--★★[corpsepersistmanager —— 尸体跨会话保留]
--   ★★ 解决的问题：玩家死亡掉落物在存档/重连后应当保留（可被找回），
--     但清理策略必须有一个统一的执行者，否则尸体会在世界里无限累积。
--   ★ 与 dt 的历史存档（rollback）相关：
--     回滚存档时实体状态变化，corpsepersistmanager 保证死亡物品的处理一致。
--   交叉引用：networking.lua:733 WorldRollbackFromSim（回滚请求的实现）。
        inst:AddComponent("corpsepersistmanager")

--★ 注释「World health management」引出下一个组件 ——
--   ★★ 这是一条有实质影响的注记： skeletonsweeper 清理的不是「垃圾」，
--     而是**世界膨胀的数据**（游离骨骼）。在多分片集群里，
--     每个分片都有一份实体表，扩容时会产生「本分片用不到的引用」，
--     必须清扫否则内存与查询成本随扩容次数线性增长。
        --World health management
--★★★[skeletonsweeper —— 分片扩容时的清扫者]
--   ★★ 结合第 154-157 行的 skeleton_notplayer / _1 / _2 三个预制体看：
--     洞穴里散布的装饰性骨架在分片反复载入/卸载时会累积成千上万，
--     skeletonsweeper 定期清理其中无主的。
--   ★ 这是「世界健康（world health）」字面意义上的组件 ——
--     它维护的不是玩法状态，而是**世界数据结构本身的健康度**。
        inst:AddComponent("skeletonsweeper")

--★★★【master_postinit —— 「仅主模拟」的生物群系钩子，与 common_postinit 精确二分】
--   ★★ 位置极讲究：在第 591 行 skeletonsweeper 之后、
--     第 598 行 uniqueprefabids 之前 —— 也就是「所有常规组件装完」之后。
--   ★ 含义：生物群系的主模拟逻辑可以假定常规管理器都已就绪。
--   ★★ 对照 common_postinit（第 547 行）：
--     · common_postinit 在第 551 行 SetPrefabName 之前（第 547 < 551）
--     · master_postinit  在第 551 行 SetPrefabName 之后（第 593 > 551）
--   ★★ 这意味着两个钩子看到的实体状态**不同**：
--     common_postinit 执行时 prefab 名还没设好，master_postinit 时已经设好。
--     ★ 这是一个真实可观察的差异，生物群系代码若依赖 self.prefab，
--       必须写在 master_postinit 里而不能写 common_postinit。
        if master_postinit ~= nil then
            master_postinit(inst)
        end

--★ 注释「Metrics」—— 下面这个组件归入「度量/统计」而非玩法。
        --Metrics
--★★[uniqueprefabids —— 预制体 ID 去重]
--   ★★ 解决的问题：批量生成（一次生成一堆）时，同一份 prefab 可能被重复登记，
--     导致计数器重复、清理逻辑错算、或者刷怪器生成数量异常。
--   ★ 与第 591 行 skeletonsweeper 同属「世界健康」类：
--     不产生玩法内容，只保证数据结构正确。
--   ★ 这个组件放在第 598 行（master_postinit 之后）是有理由的：
--     唯一性检查必须在生物群系逻辑装好之后才有意义。
        inst:AddComponent("uniqueprefabids")

--★★[UpdateServerWorldGenDataString —— 世界生成数据的对外广播]
--   ★★ 原注释给了两条关键信息：
--     "World gen data for server listing" —— 供**服务器列表界面**使用，
--     "Also updated in shardnetworking.lua for multilevel server clusters"
--     —— ★ 多层（多分片）集群里，这段逻辑在别处还要再跑一遍。
--   ★★ 精确对应：networking.lua:784 的同名函数，
--     那里第 789-796 行会合并各次分片的世界生成数据再统一上报。
--     本文件是「单世界」版本，networking.lua 是「集群」版本。
--   ★ 这正是文件头说的「双层 TheWorld」结构的又一体现：
--     网络相关的数据上报被单独放在 networking.lua 那一层。
        --World gen data for server listing
        --Also updated in shardnetworking.lua for multilevel server clusters
--★★【UpdateServerWorldGenDataString() —— 上报世界生成配置】
--   ★ 内容是 ShardGameIndex:GetGenOptions() 打包压缩后的字符串
--     （见 networking.lua:814 TheNet:SetWorldGenData(DataDumper(ZipAndEncodeSaveData(...))）。
--   ★ 用途：其他玩家在服务器列表里看到「这张图是哪个季节生成的、
--     哪些设置被改过」，可以据此决定是否加入。
--   ★★ 为什么只在上报时需要：这是给**未加入的玩家**看的元数据，
--     加入之后直接从存档读，不需要再广播。
        UpdateServerWorldGenDataString()

--★ inst.game_data_task = nil —— 初始化去抖标志位。
--   ★ 与第 317 行（DoGameDataChanged 里清空）、第 330 行（判空后排队）
--     构成完整的状态机。
--   ★★ 位置在第 602 行之后、所有事件监听之前 —— 
--     保证在 PostInit（第 331 行会用到它）之前标志位已就绪。
        inst.game_data_task = nil

--★★★[ListenForEvent("ms_playerspawn") —— 世界自己监听自己的事件]
--   ★★★ 这正是「TheWorld 是全局事件总线」的具体体现：
--     派发方是引擎/gamelogic，监听方是世界本体，绑定发生在本文件。
--   ★★ 对照：绝大多数事件是「实体监听自己」（source 默认是自己），
--     而这里是「世界监听世界里发生的事」—— 因为世界寿命最长、
--     任何代码都能通过 TheWorld 找到它。
--   ★ 这解释了「为什么用 TheWorld 充当全局事件源」的答案：
--     事件能力来自 entityscript.lua 的实体机制（:2966 ListenForEvent、
--     :3156 PushEvent_Internal），TheWorld 只是恰好是那个「人人可达、
--     永不死亡、恰好只有一个」的实体。
--   ★ ms_ 前缀约定见第 300 行注记。参见 01-报告/01-核心架构-实体预制体组件.md。
        inst:ListenForEvent("ms_playerspawn", OnPlayerSpawn)

--★★★[阶段⑦末尾：口袋维度容器的三个公开接口]
--   PocketDimensionContainers = {}   —— 名字 → 容器实体的字典
--   SetPocketDimensionContainer（第 609 行）—— 见第 387 行
--   GetPocketDimensionContainer（第 610 行）—— 见第 391 行
--   ★★ 「字典 + 两个方法」全部挂到实体上，与第 453 行 CanFlyingCrossBarriers
--     是同一套「公开 API 挂载」手法。
--   ★ 位置在仅主模拟分支内（第 564 行之后）→ ★ 只有服务端持有这张表。
--     理由：口袋维度（随身子世界）是服务端权威的世界内容，
--     客户端只渲染被复制出来的实体，不需要知道容器实体本身。
        inst.PocketDimensionContainers = {}
        inst.SetPocketDimensionContainer = SetPocketDimensionContainer
        inst.GetPocketDimensionContainer = GetPocketDimensionContainer
--★ 阶段⑦结束。回顾纯客户端（提前 return）与主模拟的差别，
--   唯一多出来的能力就是这 15 个管理器组件 ——
--   ★★ 它们合起来定义了「服务端权威」这个概念的具体内容：
--     玩家、刷怪、季节、农场、存档、投票、跨分片同步。
--   ★ 参见 01-报告/04-联机同步-模组系统-UI.md 的「谁负责什么」划分。

--★ return inst —— 构造函数返回实体实例，Prefab 系统据此完成注册。
--   ★ 这是 fn 的唯一出口。客户端在第 565 行提前 return，服务端走到底。
        return inst
    end

--★★★★★[Prefab(name, fn, customassets, worldprefabs) —— 预制体注册的四元组]
--   ★★★ 四个参数正是 §零 至 §一 声明的那些东西：
--     name         = "world"（或生物群系自定义名）
--     fn           = 本函数的内部函数（第 414 行起），构造实体
--     customassets = assets（第 615 行第二个参数传入，前面已合并 GroundTiles 资源）
--     worldprefabs = worldprefabs（第 404-412 行组装的清单）
--   ★★★ Prefab 的语义：
--     「登记一个蓝图 —— 名字、能造出什么、要带哪些资源、能造哪些子实体」。
--     登记之后 SpawnPrefab("world") 就能造出这个实体。
--   ★ 这就闭环了 §一 的问题：清单里的预制体是「世界能生什么」的边界，
--     而这张清单正是作为第四参数交给 Prefab 的。
--   交叉引用：01-报告/01-核心架构-实体预制体组件.md（Prefab/PrefabFiles 机制）。
    return Prefab(name, fn, customassets, worldprefabs)
end
--★ MakeWorld 函数结束（文件到第 618 行直接调用它）。
--   ★★★ 全文件结构回顾：
--     §零-§一  资源与预制体清单（世界「能有什么」）
--     §二-§四  五个行为函数（世界「怎么响应」）
--     §五      MakeWorld 工厂（世界「怎么被造出来」）
--     §十      自我调用闭环（世界「终于是个 prefab 了」）
--   ★ 一个文件同时回答了「世界有什么、怎么响应、怎么造」三个问题，
--     这正是把世界建模为 prefab 带来的统一性收益。

--★★★[return MakeWorld("world", prefabs, assets) —— 本文件的自我调用]
--   ★★★ 这是全文件最巧妙的一行：
--     定义 MakeWorld 工厂 → 立即用它造一个名为 "world" 的预制体 → 返回它。
--     所以 require("prefabs/world") 的返回值就是那个预制体定义。
--   ★★ 于是「世界」这件事的完整链条是：
--     world.lua 被 require → 产出 world 预制体 → gamelogic.lua SpawnPrefab("world")
--     → fn() 执行 → TheWorld 成立 → 世界的存在开始。
--   ★★ 注意只有三个参数：customprefabs / common_postinit / master_postinit /
--     tags / custom_data 都不传，全为 nil。
--     所以「标准世界」不带任何生物群系定制 ——
--     ★ 真正的生物群系（地表/洞穴/森林）在 gamelogic.lua 里再次调用
--       MakeWorld 并传入自己的钩子，从而产出变体预制体。
--   ★ 第 405 行的 `if name ~= "world"` 分支正是为此准备的自引用逻辑。
--   ★★★ 结论：**MakeWorld 既是工厂也是模板**，
--     「世界是一个 prefab」这句话在第 618 行得到最后的闭环。
return MakeWorld("world", prefabs, assets)
