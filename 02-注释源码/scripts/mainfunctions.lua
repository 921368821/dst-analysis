--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：mainfunctions.lua（2589 行）
-- 模块：全局函数总表 + 存档系统入口（SaveGame / 会话序列化）
--
-- ★★★ 本文件的核心认知：它是 Lua **全局命名空间的手写扩展**，不是模块。
--   文件里 200 多个 `function Xxx()` 全部没有 local（除了少数几个带 local 的
--   内部辅助函数），也就是说它们在 load 时就**注入到全局环境 _G**。
--   ⇒ 推论 1：别的文件可以在任何地方直接调用本文件的函数，不需要 require。
--             这就是为什么 mainfunctions.lua 必须在引擎启动**最早**期被加载。
--   ⇒ 推论 2：本文件不能被安全地重复 require（会重复定义并重新初始化状态）。
--   ⇒ 推论 3：想找某个全局函数在哪被用，直接 Grep 全 scripts 目录即可。
--
-- ★★ 关于存档：本文件只负责「写」（SaveGame），**不负责「读」**。
--   本文件没有 LoadGame 函数——读档路径全部在 gamelogic.lua：
--     gamelogic.lua:1044  DoLoadWorldFile / :1056 DoLoadWorld
--     gamelogic.lua:368   PopulateWorld（真正把 savedata 灌回世界）
--     gamelogic.lua:1031  UpgradeSaveFile（跨版本迁移入口，见本文件 1018 行）
--   本文件的 SaveGame（1068 行）与 gamelogic.lua 的 PopulateWorld（368 行）
--   是**同一份数据结构的两个方向**：写出去的字段名，读回来时逐字对应。
--   ⇒ 排查「某字段没存上/没读到」时，必须把这两边一起看。
--
-- 分区索引表（★ 重点区域已标星，按行号直接跳转）：
--
--  #  行号区间      分区                          职责一句话
--  ────────────────────────────────────────────────────────────
--  01    1   -  16   模块头                        requires / DEBUG_MODE / 三个全局开关
--  02   18   -  46   持久化字符串 ★               SavePersistentString / ErasePersistentString
--  03   48   -  65   小工具                       Print / SecondsToTimeString
--  04   67   - 137   Prefab 注册 ★                ShouldIgnoreResolve / RegisterPrefabsImpl
--  05  139   - 247   Prefab 文件加载与模组资源      LoadPrefabFile / Mod*Assets
--  06  249   - 343   成就与平台服务                RegisterAchievements / AwardPlayerAchievement
--  07  347   - 411   实体生成                     SpawnPrefabFromSim / SpawnPrefab / PrefabExists
--  08  413   - 436   ★ 存档坐标解析                ResolveSaveRecordPosition（平台局部坐标）
--  09  438   - 484   ★ 存档实体还原                SpawnSaveRecord（newents 表的构建点）
--  10  486   - 556   实体生命周期                 CreateEntity / OnRemoveEntity / RemoveEntity
--  11  558   - 587   时间函数                     GetTime / GetTick / GetStaticTime
--  12  589   - 668   脚本加载与调试               LoadScript / GetDebugString / SetDebugEntity
--  13  670   - 761   休眠与唤醒 ★                 OnEntitySleep / OnEntityWake / PhysicsWake
--  14  763   - 812   服务器暂停状态机 ★           OnServerPauseDirty（三种 pause）
--  15  814   - 835   复制与加载保护               ReplicateEntity / DisableLoadingProtection
--  16  837   - 851   NIS 播放                     PlayNIS
--  17  853   - 950   本地暂停体系 ★               IsPaused / SetPause / 自动暂停 DoAutopause
--  18  952   - 1064  外部设置 + 世界生成覆盖 ★★   UpdateWorldGenOverride（含跨版本迁移）
--  19 1066   - 1274  ★★★ SaveGame 存档主流程      本文件最重要区域，见下方专项说明
--  20 1276   - 1300  JSON 消息处理                ProcessJsonMessage
--  21 1302   - 1321  字体                         LoadFonts / UnloadFonts
--  22 1323   - 1408  手柄检测弹窗                 CheckControllers（Steam Deck 特判）
--  23 1410   - 1440  启动入口 ★                   Start（配置目录权限自检）
--  24 1444   - 1541  实例重置 ★                   GlobalInit / SimReset（换档/重开的中枢）
--  25 1543   - 1679  退出与错误展示               RequestShutdown / DisplayError
--  26 1681   - 1757  重启 ★                       savefn / DoRestart（保存后重启）
--  27 1759   - 1929  断线处理                     OnPlayerLeave / OnNetworkDisconnect
--  28 1931   - 1993  账号事件 / 焦点              OnAccountEvent / OnFocusLost
--  29 1995   - 2132  ★ 玩家会话（存档的用户侧）    SerializeUserSession 的对面
--  30 2134   - 2198  控制台执行 / 加载状态        ExecuteConsoleCommand / NotifyLoadingState
--  31 2200   - 2423  ★★ 世界状态标签（位域编码）   CreateWorldStateTag（假 base64）
--  32 2425   - 2457  存档退出 + 音量降噪           SaveAndShutdown / CreateRepeatedSound...
--  33 2459   - 2487  防沉迷通知 / shell 命令       DisplayAntiAddictionNotification
--  34 2489   - 2520  文件哈希告警 UI              ShowBadHashUI
--  35 2522   - 2589  登录流同步 + 完整性校验 ★    DataBundleFileHashes（哈希比对）
--
-- ★★★ SaveGame（1066-1274 行）阶段划分 —— 全项目最重要的数据流程：
--   阶段 A  1068-1077  守卫：客户端直接拒绝；TheNet:StartWorldSave() 打开写入窗口
--   阶段 B  1079-1107  遍历 Ents，逐个 GetSaveRecord()，收集 GUID 交叉引用
--   阶段 C  1109-1166  地图与网络层：tiles / nav / persistdata / world_network
--   阶段 D  1168-1187  玩家快照列表 + 逐个 SerializeUserSession + 回填 id
--   阶段 E  1189-1199  模组清单 + 6 条结构断言（fail-fast）
--   阶段 F  ★★1201-1238  序列化 + NaN/Inf 拦截（本文件最高价值区域）
--   阶段 G  1241-1273  落盘回调：快照轮转 → ShardGameIndex → EndWorldSave
--   ⚠ 注意阶段 F 的错误处理是 `error()` 硬抛，不是软降级——见 1219 行注释。
--
-- ★★ NaN/Inf 拦截的精确位置（bug-patterns.md C 类「NaN 永久损坏存档」）：
--   判据构造  1203-1208   patterns 表，按 BRANCH 分叉
--     · BRANCH=="dev"   → {"=nan", "=-nan", "=inf", "=-inf"}
--     · 正式版          → {"=-1.#IND", "=1.#QNAN", "=1.#INF", "=-1.#INF"}
--   扫描位置    1214-1221  对普通字段（save 的每个 key）做 string.find
--   扫描位置    1230-1237  对 data.ents（按 prefab 分组的实体表）做同样的扫描
--   判据本质    ★ 对**序列化后的文本**做纯文本子串匹配，而不是数值比较。
--   为什么这样设计 → 见 1214 行与 1230 行的长注释（含 tonumber("nan")==nil 陷阱）。
--
-- 关键符号：
--   SaveGame / ResolveSaveRecordPosition / SpawnSaveRecord / SpawnPrefab /
--   CreateEntity / RemoveEntity / OnRemoveEntity / ReplicateEntity /
--   SavePersistentString / ErasePersistentString / UpdateWorldGenOverride /
--   RegisterPrefabsImpl / LoadPrefabFile / ShouldIgnoreResolve /
--   CreateWorldStateTag / WORLDSTATETAGS / BuildTagsStringCommon /
--   GetTime / GetStaticTime / SetPause / DoAutopause / DoRestart / Shutdown /
--   ParseUserSessionData / ResumeExistingUserSession / RestoreSnapshotUserSession
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 gamelogic.lua:368 PopulateWorld —— SaveGame 的**逆过程**（读档）
--   ★★ 参见 gamelogic.lua:1031 UpgradeSaveFile —— 跨版本迁移的实际执行者
--   ★★ 参见 gamelogic.lua:168 LoadAssets / :777 WriteServerSaveTempFile
--   ★★ 参见 savefileupgrades.lua:31 utilities —— 迁移函数登记表（本文件 1019 行调用）
--   ★★ 参见 savefileupgrades.lua:367 UpgradeWorldgenoverrideFromV1toV2（本文件 1019 行）
--   参见 shardindex.lua / shardsaveindex.lua —— ShardGameIndex 的 Save/WriteTimeFile
--   参见 saveindex.lua —— 存档索引与非分片存档
--   参见 dumper.lua DataDumper —— 阶段 F 的序列化器（把 table 转成 Lua 源码文本）
--   参见 entityscript.lua:GetSaveRecord —— 阶段 B 的 record 生产者
--   参见 entityscript.lua:SetPersistData —— 阶段 G 之后的反序列化消费者
--   参见 components/worldstate.lua —— clock / seasons 的持有者（本文件 1268 行取值）
--   参见 components/playerspawner.lua —— ms_playerdespawn 的监听者（1774 行注释提及）
--   参见 walkableplatformmanager.lua:GetPlatformWithUID（428 行坐标还原）
--   参见 modindex.lua / modutil.lua / mods.lua —— ModManager:GetModRecords（1189 行）
--   参见 prefabs/global.lua —— SPECIAL_EVENT_GLOBAL_PREFABS 等常量
--   参见 scheduler.lua —— scheduler:ExecuteInTime（1367 行等处大量使用）
--   参见 frontend.lua FrontEnd() —— 1416 行创建的屏幕管理器
--   参见 networkclientrpc.lua / networking.lua —— StartWorldSave / EndWorldSave 的实现在 C++
--   参见 profile.lua Profile —— DoAutopause 读的用户偏好（916 行）
--   参见 constants.lua —— BGCOLOURS / LoadingStates / BRANCH / VERBOSITY_LEVEL
--   参见 util.lua —— shallowcopy / deepcopy / known_assert / TrackedAssert / RunInSandboxSafe
--   参见 wordfilter.lua / knownerrors.lua —— ERRORS 表（1638 行已知错误提示）
--   参见 03-参考架构/09_savegame.lua —— 本项目自建的存档模块参考实现（含 NaN 测试用例）
--============================================================
--============================================================
-- 文件头：模块依赖与全局状态标志
--============================================================
local PopupDialogScreen = require "screens/redux/popupdialog"
local WorldGenScreen = require "screens/worldgenscreen"
local HealthWarningPopup = require "screens/healthwarningpopup"
local Stats = require("stats")

local DebugNodes = CAN_USE_DBUI and require("dbui_no_package/debug_nodes") or nil
local DebugConsole = CAN_USE_DBUI and require("dbui_no_package/debug_console") or nil

require "scheduler"
--require "skinsutils"

local DEBUG_MODE = BRANCH == "dev"

SimTearingDown = false
SimShuttingDown = false
PerformingRestart = false

-- 【分区 02】持久化字符串（Persistent String）—— 全局 KV 数据
--
-- ★ 机制：Persistent String 是**独立于世界存档**的一份全局键值数据，
--   它的生命周期是「跨存档、跨世界、跨角色」的，只跟着存档槽走。
--   本文件只提供 Lua 侧的薄封装，真正的存取在 C++（TheSim:SetPersistentString）。
--   典型用途：worldgenoverride.lua（本文件 971 行）、customcommands.lua（1425 行）。
--
-- ★★ 设计要点：为什么必须有 TheFrontEnd 分支？
--   保存是**异步**的（C++ 落盘要时间），所以必须有 callback。
--   但玩家点保存时可能正停在主菜单（TheFrontEnd 存在），此时不弹存档
--   图标会让人以为没保存；而在游戏中（TheFrontEnd 为 nil）弹图标又多余。
--   ⇒ 两个分支的唯一差别就是「要不要包一层图标」。callback 语义完全一致。
function SavePersistentString(name, data, encode, callback)
    if TheFrontEnd then
        TheFrontEnd:ShowSavingIndicator()
        local function cb()
            TheFrontEnd:HideSavingIndicator()
            if callback then
                callback()
            end
        end
-- ★ 注意 `encode or false`：第 3 个参数决定 C++ 是否对该字符串做编码，
--   显式 or false 是为了把 nil 归一化成合法的布尔值——
--   Lua 里参数不传就是 nil，而 C++ 侧期望的是明确的 true/false。
-- ⚠ 疑似缺陷（设计约束，非 bug）：若调用方忘记传 encode，值被静默当成 false，
--   即「不编码」。这在 lua 侧无法区分「显式传 false」与「忘了传」。
        TheSim:SetPersistentString(name, data, encode or false, cb)
    else
        TheSim:SetPersistentString(name, data, encode or false, callback)
    end
end

-- 【分区 02 续】删除一个持久化字符串。
-- ★ 为什么删除也要包图标：ErasePersistentString 同样是异步落盘，
--   常用于「重置世界生成设置」这类需要清缓存的操作，玩家需要反馈。
function ErasePersistentString(name, callback)
    if TheFrontEnd then
        TheFrontEnd:ShowSavingIndicator()
        local function cb()
            TheFrontEnd:HideSavingIndicator()
            if callback then
                callback()
            end
        end
        TheSim:ErasePersistentString(name, cb)
    else
        TheSim:ErasePersistentString(name, callback)
    end
end

-- 【分区 03】小工具
--
-- ★ Print(verbosity, ...) 的设计是「按全局 VERBOSITY_LEVEL 过滤的 print」。
--   这样调试语句可以保留在正式版代码里而不刷屏——按 VERBOSITY 编译期/启动期
--   统一关闭即可，不需要到处删代码。参见 1573 行 Print(VERBOSITY.DEBUG, ...)。
function Print( msg_verbosity, ... )
    if msg_verbosity <= VERBOSITY_LEVEL then
        print( ... )
    end
end

-- 【分区 03 续】秒 → 「分:秒」显示串。
-- ★ 三分支不是为了美观，而是为了匹配三种 UI 语境：
--   · 有分钟 → "3:07"（战斗计时/技能 CD）
--   · 纯秒且 >9 → "42"（补给的倒计时）
--   · 纯秒且 <=9 → "7"（最后几秒的紧迫感，刻意不补零）
-- ⚠ 注意用 math.floor 而非字符串截断：负数或浮点误差下 floor 行为可预期。
function SecondsToTimeString( total_seconds )
    local minutes = math.floor(total_seconds / 60)
    local seconds = math.floor(total_seconds - minutes*60)

    if minutes > 0 then
        return string.format("%d:%02d", minutes, seconds)
    elseif seconds > 9 then
        return string.format("%02d", seconds)
    else
        return string.format("%d", seconds)
    end
end

--============================================================
-- 【分区 04】Prefab 注册（1/2）—— 决定「哪些资源需要加载、哪些跳过」
--============================================================
---PREFABS AND ENTITY INSTANTIATION

-- ★★ ShouldIgnoreResolve：资源解析的**白名单反函数**（黑名单）。
--   prefab 的 assets 表里声明了上百个资源文件，这个函数决定哪些真正去磁盘找路径。
--   跳过任何一个都会在后面的 assert 里炸（见 122 行），所以这张表必须精确。
--
-- 【四类跳过规则及其理由】：
--   ① INV_IMAGE / MINIMAP_IMAGE —— 物品栏图标与小地图图标由 UI 单独加载，
--      不走 prefab 的资源解析管线。加载它们只会浪费内存。
--   ② .dyn + PKGREF —— 动态骨骼包的包引用。★ 这是「玩家自定义外观」相关资源，
--      它们的实际路径在运行期才确定，注册期解析必然失败，只能延后。
--   ③ 专用服务器（TheNet:IsDedicated()）下的全部音频/视频：
--      SOUNDPACKAGE / SOUND / .ogv / .fev(PKGREF) / fsb
--      —— 理由：dedicated server 没有渲染与音频设备，加了纯浪费内存与 IO，
--      而且 FEV/FEB 体积极大，是服务器内存占用的头号来源。
--
-- ⚠ 疑似缺陷（低风险）：第 ③ 组的分号与缩进（81-95 行用 `;` 而 73-78 用 `if`），
--   风格不一致但语义相同；不修改。
-- ★ 设计代价：因为专服跳过音频，**服务器上不能依赖音效事件驱动逻辑**
--   （例如靠 playsound 触发的成就/任务），必须用独立的数据通道。
function ShouldIgnoreResolve( filename, assettype )
-- ★ 库存物品图标：跳过（UI 单独加载，见分区 04 注释）。
    if assettype == "INV_IMAGE" then
        return true
    end
-- ★ 小地图图标：同样跳过。
    if assettype == "MINIMAP_IMAGE" then
        return true
    end
-- ★★ 动态骨骼包 + PKGREF：★ 这是唯一一条「按文件名后缀 + 类型」的联合判据。
--   ★ 原因：玩家的自定义外观骨骼路径运行期才确定，注册期解析必然失败。
    if filename:find(".dyn") and assettype == "PKGREF" then
        return true
    end

-- ★★★ 下面是「仅专用服务器」的分支：专服没有渲染与音频设备，
--   加载 SOUND/SOUNDPACKAGE/视频/FEV/FSB 纯属浪费内存与 IO。
--   ★★ 这是 DST 专用服务器能在一台小机器上跑上百人的关键优化之一。
    if TheNet:IsDedicated() then
        if assettype == "SOUNDPACKAGE" then
            return true
        end
        if assettype == "SOUND" then
            return true
        end
-- ★ .ogv = 预渲染过场动画（如通关动画），服务端不需要。
        if filename:find(".ogv") then
            return true
        end
-- ★ .fev 是 Klei 自研音频格式，体积大，必须排除。
        if filename:find(".fev") and assettype == "PKGREF" then
            return true
        end
        if filename:find("fsb") then
            return true
        end
-- ★ 注意此处缩进用的是 Tab（原文如此），与上下两空格不一致，仅风格问题。
	end
    return false
end


-- ★ modprefabinitfns：按 prefab 名缓存模组注入的「构造后钩子」列表。
--   缓存而非每次查询，是因为 GetPostInitFns 会遍历全部模组环境，很慢，
--   而预制体实例化是高频操作（每次种一棵草都会走一遍）。
local modprefabinitfns = {}

-- ★ RegisterPrefabsImpl：预制体注册的**唯一真正实现**。
--   所有入口（RegisterPrefabs / RegisterSinglePrefab / LoadPrefabFile）
--   都汇聚到这里，差别只在传进来的 resolve_fn 不同。
-- ★★ 为什么要这样设计（回调注入）：
--   「注册一个 prefab」要干两件事——① 解析所有资源路径 ② 登记到全局表。
--   但**怎么解析**有三种需求：
--     · 同步严格解析（模组/正式内容，失败即崩）→ RegisterPrefabsResolveAssets
--     · 异步批量校验（大批预加载资源，失败延后报错）→ VerifyPrefabAssetExistsAsync
--   把 resolve_fn 作为参数传入，让「登记」逻辑只写一遍，避免三份重复代码。
function RegisterPrefabsImpl(prefab, resolve_fn)
    --print ("Register " .. tostring(prefab))
    -- allow mod-relative asset paths

-- ★ 只对未被黑名单过滤的 asset 调用解析器——与 69 行的黑名单严格配对。
    for i,asset in ipairs(prefab.assets) do
        if not ShouldIgnoreResolve(asset.file, asset.type) then
       		resolve_fn(prefab, asset)
        end
    end

-- ★ 这一行是模组定制预制体的挂载点。PrefabPostInit 是「仅针对某个 prefab 名」
--   的钩子，模组可用它给别人的 prefab 换贴图/改组件而不 fork 源文件。
    modprefabinitfns[prefab.name] = ModManager:GetPostInitFns("PrefabPostInit", prefab.name)
-- ★ Prefabs 是全局名字 → 预制体定义的查找表。SpawnPrefab（403 行）全靠它。
--   ★ 因此这里是存档里 prefab 字符串的**唯一解析入口**——
--     存档中存的是 prefab 名（如 "grass"),读档时靠这张表还原成真对象。
--     ⇒ 若某个 prefab 在新版本被删除/改名，读档就会拿到 nil（见 353 行兜底）。
    Prefabs[prefab.name] = prefab

    TheSim:RegisterPrefab(prefab.name, prefab.assets, prefab.deps)
end

-- resolve_fn 的实现之一：**同步严格解析**。
local function RegisterPrefabsResolveAssets(prefab, asset)
	--print(" - - RegisterPrefabsResolveAssets: " .. asset.file, debugstack())
    local resolvedpath = resolvefilepath(asset.file, prefab.force_path_search, prefab.search_asset_first_path)
-- ★★ fail-fast：资源找不到立刻 assert，绝不「悄悄跳过」。
--   理由：资源缺失在开发期几乎必然是拼写错误或路径改动，硬报错能第一时间
--   定位；若此处放行，等到渲染时才发现只会得到一个更难查的空模型。
-- ⚠ 疑似缺陷（低影响）：assert 消息里用 ".." 拼接，未对 asset.file 做 tostring
--   保护。若 asset.file 是 nil，字符串拼接会抛「attempt to concatenate a nil」
--   ——错误信息本身报错，反而掩盖了真正的文件名。不修改。
    assert(resolvedpath, "Could not find "..asset.file.." required by "..prefab.name)
    TheSim:OnAssetPathResolve(asset.file, resolvedpath)
    asset.file = resolvedpath
end

-- resolve_fn 的实现之二：**异步批量校验**（第 130 行）。
local function VerifyPrefabAssetExistsAsync(prefab, asset)
	-- this is being done to prime the HDD's file cache and ensure all the assets exist before going into game
	--TheSim:VerifyFileExistsAsync(asset.file)
-- ★★ 关键设计：这里刻意**不解析**路径，只把文件丢进「存在性批量校验」队列。
--   原始英文注释说得很清楚：目的是「预热 HDD 文件缓存并确保进游戏前资源都在」。
--   为什么重要：批量校验让磁盘 IO 可以并行摊开（AddBatch 是批量的），
--   而 resolvefilepath 是同步阻塞的；大资源包用同步解析会卡出可见的加载停顿。
--   ⇒ 权衡：这条路径下 asset.file 保持相对路径，真正解析延后到加载期。
--   ★ 这解释了 1458 行的断言：这两个模式**互斥**，不能同时开启。
	TheSim:AddBatchVerifyFileExists(asset.file)
end

-- 批量注册入口（一次传多个 prefab）。
function RegisterPrefabs(...)
    for i, prefab in ipairs({...}) do
		RegisterPrefabsImpl(prefab, RegisterPrefabsResolveAssets)
	end
end

-- ★ 单个注册入口。同样汇聚到 RegisterPrefabsImpl，只是 resolve_fn 固定。
function RegisterSinglePrefab(prefab)
	RegisterPrefabsImpl(prefab, RegisterPrefabsResolveAssets)
end

-- ★ PREFABDEFINITIONS：prefab 名 → 定义，与 Prefabs 的区别是
--   PREFABDEFINITIONS 保存的是**文件里声明的原始对象**（含 assets/deps 清单），
--   而 Prefabs 是「已经解析过、可直接实例化」的运行时视图。
PREFABDEFINITIONS = {}

--============================================================
-- 【分区 05】Prefab 文件加载（1/2）—— loadfile + 返回值约定
--============================================================
function LoadPrefabFile( filename, async_batch_validation, search_asset_first_path )
    --not is used as cast to boolean
    --this check ensures that both values are not defined, while still allowing both to be undefined.
-- ★★ 为什么断言的是「not A or not B」而不是「not (A and B)」？
--   源码英文注释特意解释了：「not is used as cast to boolean」。
--   两个开关都是「三态」：未定义(false) / 显式 false / 显式 true。
--   作者想要的效果是「只要用户**定义了任何一个**就算开启」，因此两个都 false
--   才合法。写成 not A or not B 恰好等价于 not (A and B)。
--   ⚠ 提示：这里用的是 A or B 的真值化语义；若未来有人改成 and 会静默改变行为。
    assert(not async_batch_validation or not search_asset_first_path, "search_asset_first_path and async_batch_validation cannot both be defined")
    --print("Loading prefab file "..filename)
-- ★ loadfile 返回 (chunk, err)。第二返回值在失败时是**错误消息字符串**。
    local fn, r = loadfile(filename)
    assert(fn, "Could not load file ".. filename)
-- ★★★ 这里是最经典的 loadfile 陷阱，也是本文件最重要的防御性代码之一：
--   `if type(fn) == "string"` 判断的**不是** chunk，而是 err。
--   换句话说：这段代码把「chunk 是不是函数」和「err 是不是字符串」混用一个
--   变量来判断——这依赖 Lua 的 loadfile 契约：成功时 err 为 nil，失败时 fn 为 nil。
--   ★ 为什么 dev 分支要特殊处理（154-159 行）：
--     在开发分支里改 prefab 却忘了提交 updateprefab，是极常见的错误，
--     作者希望用 DEV_FAILED_TO_LOAD_PREFAB 这个具名错误码上报，
--     而不是抛一段人看不懂的堆栈。known_assert 会把错误登记到 knownerrors.lua。
    if type(fn) == "string" then
        local error_msg = "Error loading file "..filename.."\n"..fn
        if DEBUG_MODE then
            -- Common error in development when working in a branch (we don't
            -- submit updateprefab changes in branches).
            print(error_msg)
            known_assert(false, "DEV_FAILED_TO_LOAD_PREFAB")
        end
        assert(false, error_msg)
    end
-- ★ 补一道类型断言：文件必须返回可调用 chunk（function）。
--   若 prefab 文件忘了 return 任何东西，这里会给出明确错误。
    assert( type(fn) == "function", "Prefab file doesn't return a callable chunk: "..filename)
-- ★ `{fn()}` 强制把返回值**表化**成数组。这是 prefab 文件的调用约定：
--   一个 prefab 文件可以返回 1 个或多个 Prefab 对象，返回值被收集成数组。
--   ★ 注意这不是 `{fn(), fn()}`——fn 只被调用一次，多返回值全部装进同一张表。
    local ret = {fn()}

    if ret then
        for i,val in ipairs(ret) do
-- ★ 双重校验：既要像表（type==table），又要通过 is_a(Prefab) 元类检查。
--   is_a 是类.lua 提供的元类系统，prefab 文件若返回了别的东西会被这里挡住。
            if type(val)=="table" and val.is_a and val:is_a(Prefab) then
-- ★ 记录「这个 prefab 要优先在自己的目录找资源」——模组资源覆盖的关键。
--   配合 121 行的 resolvefilepath 第三参数。
                val.search_asset_first_path = search_asset_first_path
				if async_batch_validation then
					RegisterPrefabsImpl(val, VerifyPrefabAssetExistsAsync)
				else
					RegisterSinglePrefab(val)
	            end
                PREFABDEFINITIONS[val.name] = val
            end
        end
    end

    return ret
end


-- 【分区 05 续】模组前端/预加载资源管理
local MOD_FRONTEND_PREFABS = {}
-- ★★ ModUnloadFrontEndAssets：卸载模组资源。传 nil 表示「全部卸载」。
--   设计上成对出现 UnloadPrefabs + UnregisterPrefabs，顺序不能反：
--   先把 C++ 侧的资源实例卸掉，再注销注册表里的名字。
function ModUnloadFrontEndAssets(modname)
    if modname == nil then
        TheSim:UnloadPrefabs(MOD_FRONTEND_PREFABS)
        TheSim:UnregisterPrefabs(MOD_FRONTEND_PREFABS)
        MOD_FRONTEND_PREFABS = {}
    else
-- ⚠ 疑似缺陷（低影响）：table.removearrayvalue 的第二参传的是**字符串**，
--   若该工具要求元素本身（数组里存的是字符串，所以是对的）；
--   但外层 { } 强行把返回值包成单元素表，若未找到则得到 {nil}，
--   随后 IsTableEmpty({nil}) 的行为取决于其实现，存在把 {nil} 当非空的可能。
--   ★ 这条路径只在模组卸载时触发，未找到时不会崩，但语义可疑。不修改。
        local prefab = {table.removearrayvalue(MOD_FRONTEND_PREFABS, "MODFRONTEND_"..modname)}
        if not IsTableEmpty(prefab) then
            TheSim:UnloadPrefabs(prefab)
            TheSim:UnregisterPrefabs(prefab)
        end
    end
end

-- ★ ModReloadFrontEndAssets：模组的前端资源热重载。
-- ★★ 为什么要 shallowcopy（203 行）：
--   assets 是**模组代码里的表**。如果直接把它的引用存进预制体，模组后续修改
--   这个表就会意外地影响已注册的资源。复制一份切断引用，是防御式编程。
--   同样的三行在 ModPreloadAssets（236 行）里一字不差地重复——
--   说明这两个函数是复制粘贴出来的，可以合并但没必要。
function ModReloadFrontEndAssets(assets, modname)
    assert(KnownModIndex:DoesModExistAnyVersion(modname), "modname "..modname.." must refer to a valid mod!")
    if assets then
        ModUnloadFrontEndAssets(modname)

        assets = shallowcopy(assets) --make a copy so that changes to the table in the mod code don't do anything funky

        for i, v in ipairs(assets) do
-- ★ modroot 让 resolvefilepath_soft 在模组目录内做软解析（找不到不报错）。
--   用 _soft 后缀是因为模组资源本来就可能缺失（例如本地模组还在开发）。
            local modroot = MODS_ROOT..modname.."/"
            resolvefilepath_soft(v.file, nil, modroot)
        end
-- ★ 给所有模组前端资源套一个虚拟 prefab 名 "MODFRONTEND_<modname>"，
--   这样一次 Unload/Unregister 就能整批处理（见 190 行）。
--   ★ 这是「用命名空间做批量管理」的典型手法，避免逐个资源记账。
        local prefab = Prefab("MODFRONTEND_"..modname, nil, assets, nil)
-- ★ 登记进批处理表，供 ModUnloadFrontEndAssets 批量卸载。
        table.insert(MOD_FRONTEND_PREFABS, prefab.name)
        RegisterSinglePrefab(prefab)
        TheSim:LoadPrefabs({prefab.name})
    end
end

-- 【分区 05 续】预加载资源（ModPreloadAssets）
-- ★★★ MOD_PRELOAD_PREFABS 与 MOD_FRONTEND_PREFABS 的逻辑**完全对称**
--   （183-214 vs 216-247），只有 Prefab 名前缀不同（MODFRONTEND_ / MODPRELOAD_）。
--   ★ 两者的区别在于「加载时机」：前端资源在进游戏前用，
--     预加载资源是为进游戏后提前把大资源读进内存。
local MOD_PRELOAD_PREFABS = {}
-- ★ 与 ModUnloadFrontEndAssets 严格镜像（传 nil 卸载全部）。
function ModUnloadPreloadAssets(modname)
    if modname == nil then
        TheSim:UnloadPrefabs(MOD_PRELOAD_PREFABS)
        TheSim:UnregisterPrefabs(MOD_PRELOAD_PREFABS)
        MOD_PRELOAD_PREFABS = {}
    else
        local prefab = {table.removearrayvalue(MOD_PRELOAD_PREFABS, "MODPRELOAD_"..modname)}
        if not IsTableEmpty(prefab) then
            TheSim:UnloadPrefabs(prefab)
            TheSim:UnregisterPrefabs(prefab)
        end
    end
end

function ModPreloadAssets(assets, modname)
    assert(KnownModIndex:DoesModExistAnyVersion(modname), "modname "..modname.." must refer to a valid mod!")
    if assets then
        ModUnloadPreloadAssets(modname)

-- ★ 同样的 shallowcopy 防御（236 行与 203 行一字不差）—— 复制粘贴产物。
        assets = shallowcopy(assets) --make a copy so that changes to the table in the mod code don't do anything funky

        for i, v in ipairs(assets) do
            local modroot = MODS_ROOT..modname.."/"
            resolvefilepath_soft(v.file, nil, modroot)
        end
        local prefab = Prefab("MODPRELOAD_"..modname, nil, assets, nil)
-- ★ 与 210 行镜像：登记进 MOD_PRELOAD_PREFABS。
        table.insert(MOD_PRELOAD_PREFABS, prefab.name)
        RegisterSinglePrefab(prefab)
        TheSim:LoadPrefabs({prefab.name})
    end
end

--============================================================
-- 【分区 06】成就与平台服务（Steam/PSN/主机成就）
--============================================================
function RegisterAchievements(achievements)
    for i, achievement in ipairs(achievements) do
        --print ("Registering achievement:", achievement.name, achievement.id.steam, achievement.id.psn)
-- ★ 一个成就要登记到**三套** ID 空间：游戏内 name、Steam id、PSN id。
--   主机与 PC 的成就系统完全独立，必须同时注册。
        TheGameService:RegisterAchievement(achievement.name, achievement.id.steam, achievement.id.psn)
    end
end

-- LoadAchievements：与 LoadPrefabFile 结构几乎完全一致的加载器。
-- ★ 注意与 prefab 加载器的差异：这里 dev 分支**没有**特殊处理，
--   直接 assert(false, ...)。成就文件出错比 prefab 出错少见，且不常热更。
function LoadAchievements( filename )
    --print("Loading achievement file "..filename)
    local fn, r = loadfile(filename)
    assert(fn, "Could not load file ".. filename)
    if type(fn) == "string" then
        assert(false, "Error loading file "..filename.."\n"..fn)
    end
    assert( type(fn) == "function", "Achievements file doesn't return a callable chunk: "..filename)
    local ret = {fn()}

    if ret then
        for i,val in ipairs(ret) do
            if type(val)=="table" then --and val.is_a and val:is_a(Achievements)then
                RegisterAchievements(val)
            end
        end
    end

    return ret
end

-- LoadHapticEffects：手柄震动效果定义加载。同样是「loadfile → 收集返回值」。
-- ★ 嵌套两层 ipairs（第 289 行）：外层遍历文件返回的表，内层遍历每个表的元素。
--   这说明 haptics 文件的返回约定是「表套表」，与 prefab 文件的「一维数组」不同。
function LoadHapticEffects( filename )
    local fn, r = loadfile(filename)
    assert(fn, "Could not load file ".. filename)
    if type(fn) == "string" then
        assert(false, "Error loading file "..filename.."\n"..fn)
    end
    assert( type(fn) == "function", "Haptics file doesn't return a callable chunk: "..filename)
    local ret = {fn()}

    if ret then
        for i,val in ipairs(ret) do
            if type(val)=="table" then
                for i, effect in ipairs(val) do
                    TheHaptics:RegisterEffect(effect)
                end
            end
        end
    end

    return ret
end

-- ★★ AwardFrontendAchievement vs AwardPlayerAchievement 的区别：
--   前者不带玩家（纯 UI/全局成就），后者带 userid（进度型成就）。
--   ★ 注意两者都被 IsConsole() 包住——**PC 上这两个函数是空操作**。
--     因为 Steam 成就由 steamworks 侧自行处理，LUA 不参与。
-- ⚠ 疑似缺陷：`IsConsole()` 在 PCLuaLib 里通常定义为 `not IsSteam()`，
--   若某平台（如 RAIL）既非 Steam 也非传统主机，这套成就逻辑会整体失效。
--   由于无法从本文件确认 IsConsole 的定义，此处仅标注为待核实风险。不修改。
function AwardFrontendAchievement( name )
    if IsConsole() then
	    TheGameService:AwardAchievement(name, nil)
    end
end

function AwardPlayerAchievement( name, player )
	if IsConsole() then
-- ★ 双重校验 player 非空 **且** 有 player 标签——防止把成就发给非玩家实体。
--   tostring(player.userid) 是主机侧要求的字符串形式账号 ID。
        if player ~= nil and player:HasTag("player") then
		    TheGameService:AwardAchievement(name, tostring(player.userid))
	    else
		    print( "AwardPlayerAchievement Error:", name, "to", tostring(player) )
	    end
    end
end

-- ★ NotifyPlayerProgress：上报成就**进度**（如「砍了 100 棵树」→ 30/100）。
--   ★ 与 Award 的区别：不发奖，只推进度。主机侧显示进度条。
function NotifyPlayerProgress( name, value, player )
	if IsConsole() then
        if player ~= nil and player:HasTag("player") then
		    TheGameService:NotifyProgress(name, value, tostring(player.userid))
	    else
		    print( "NotifyPlayerProgress Error:", name, "to", tostring(player) )
	    end
    end
end

-- ★ NotifyPlayerPresence：★ 上报**在线状态/等级/天数**（如 PSN 好友列表）。
--   ★ 注意 else 分支（330 行）传 nil 而非报错 —— 缺失玩家时仍上报，
--     说明这个接口允许「与某玩家无关」的存在状态上报。
--   ★ 对比 Award/NotifyProgress 的 else 是 print 报错（307-311 行）。
--     ⇒ 同一个文件里两种错误风格并存，属风格不统一，不作为缺陷。
function NotifyPlayerPresence( name, level, days, player )
	if IsConsole() then
        if player ~= nil and player:HasTag("player") then
		    TheGameService:NotifyPresence(name, level, days, tostring(player.userid))
	    else
		    TheGameService:NotifyPresence(name, level, days, nil)
	    end
    end
end


-- ★ AwardRadialAchievement：范围成就。FindPlayersInRange 找出范围内所有玩家
--   逐个授予。注意它复用了 AwardPlayerAchievement，因此同样受 IsConsole 限制。
function AwardRadialAchievement( name, pos, radius )
	if IsConsole() then
        local players = FindPlayersInRange( pos.x, pos.y, pos.z, radius, true )
        for k,player in pairs(players) do
		    AwardPlayerAchievement(name, player)
	    end
    end
end



--============================================================
-- 【分区 07】实体生成（1/2）—— 存档/调试双用途的底层 spawn
--============================================================
function SpawnPrefabFromSim(name)
-- ★★ `string.sub(name, string.find(name, "[^/]*$"))` 是一个「取路径末段」的惯用法：
--   find 返回「从第一个非 / 字符开始到结尾」的**起始位置** i，
--   string.sub(name, i) 于是取出该位置到结尾，即文件名部分。
--   等价于现代写法 s:match("([^/]*)$")。作用是容忍带目录前缀的 prefab 名。
    name = string.sub(name, string.find(name, "[^/]*$"))
    name = string.lower(name)

-- ★ Prefabs 查表失败的处理（353-358 行）是**降级 + 上报**而非崩溃：
--   存档里可能有已下线模组的实体，读档时必然查不到。
--   ⇒ 硬崩会让整个存档玩不了，所以这里返回 -1 让调用方跳过。
--   ★ 只有在「无模组 + 服务器未启用模组」的纯净环境下才额外打印堆栈——
--     因为那时还找不到，一定是官方 bug，值得上报。这是很好的分级诊断设计。
    local prefab = Prefabs[name]
    if prefab == nil then
        print( "Can't find prefab " .. tostring(name) )
        if not AreAnyModsEnabled() and not TheNet:GetServerModsEnabled() then
            print("This is bug reportable if found please send the following stack trace.")
            print(_TRACEBACK())
        end
        return -1
    end

-- ⚠ 疑似缺陷（低影响）：361 行 `if prefab then` 是**死判断**——
--   上面 352 行已经 `return -1` 处理了 prefab == nil 的情况，
--   走到 361 行时 prefab 必然非 nil。且若 prefab 真为 nil，397 行无 return，
--   函数会隐式返回 nil 而非 -1（与 358 行的约定不一致）。不修改。
    if prefab then
        local inst = prefab.fn(TheSim)

        if inst ~= nil then

-- ★★★ SetPrefabName 是**存档关键**：inst.prefab 是存档中记录的实体类型字符串。
--   注意用 `inst.prefab or name` 兜底——个别 prefab 的构造函数不设置 self.prefab。
--   ⇒ 读档时就是靠这个字段去 Prefabs 表里找对应的构造器（见 SpawnSaveRecord 440 行）。
            inst:SetPrefabName(inst.prefab or name)

-- ★ 两段 modfns 调用的原因（374-381 行）：
--   先用 inst.prefab（可能已被 prefab 构造函数改写成别的名字），
--   如果它和请求的名字不同，再用**原始请求名**再查一次。
--   ⇒ 保证「改名生成」的实体也能被模组钩到。
            local modfns = modprefabinitfns[inst.prefab or name]
            if modfns ~= nil then
                for k,mod in pairs(modfns) do
                    mod(inst)
                end
            end
            if inst.prefab ~= name then
                modfns = modprefabinitfns[name]
                if modfns ~= nil then
                    for k,mod in pairs(modfns) do
                        mod(inst)
                    end
                end
            end

            for k,prefabpostinitany in pairs(ModManager:GetPostInitFns("PrefabPostInitAny")) do
                prefabpostinitany(inst)
            end

            if TheWorld then
                TheWorld:PushEvent("entity_spawned", inst)
            end

-- ★ 返回 GUID（整数），这是实体在存档与世界中的**唯一标识**。
--   ★★ 存档表达：GUID 不写进每条记录，而是作为 saved_ents / newents 的**键**。
--     参见 1183 行 `saved_ents[k].id = k` 与 462 行 `newents[saved.id] = ...`。
--   ★ 好处：GUID 一旦分配就永不复用（实体死亡不复用），因此存档里的 GUID 天然无歧义。
            return inst.entity:GetGUID()
        else
            print( "Failed to spawn", name )
            return -1
        end
    end
end

-- 【分区 07 续】SpawnPrefab —— 游戏逻辑里 99% 的生成入口
function PrefabExists(name)
    return Prefabs[name] ~= nil
end

-- ★★ 与 SpawnPrefabFromSim 的区别（关键）：
--   SpawnPrefabFromSim（347 行）= 直接在**本地**执行 prefab 构造函数（单机/调试/服务器），
--   SpawnPrefab（这里）      = 通过 TheSim 请求，**跨网络到服务器**执行。
--   ★ 在服务器上两者最终都会本地构造（TheSim 在本地），
--     但 SpawnPrefab 是「客户端也能调」的统一入口，客户端调它会发 RPC。
function SpawnPrefab(name, skin, skin_id, creator, skin_custom)
    name = string.sub(name, string.find(name, "[^/]*$"))
-- ★ 皮肤合法性检查：IsItemId 判定一个 skin 字符串是否是合法的物品 ID，
--   不是则丢弃（skin = nil）。这防止存档/网络里的伪造皮肤名导致错误。
    if skin and not IsItemId(skin) then
        print("Unknown skin", skin)
		skin = nil
    end
-- ★★ TheSim:SpawnPrefab 是**权威生成入口**。返回值 guid 再用 Ents 查回实体。
--   这依赖 Ents 全局表在 SpawnPrefab 返回前已被填好（见 CreateEntity 493 行）。
--   ⇒ 若 TheSim 内部是异步的，Ents[guid] 会是 nil；实际是同步的，所以安全。
    local guid = TheSim:SpawnPrefab(name, skin, skin_id, creator, skin_custom)
    return Ents[guid]
end

-- 【分区 07 续】ReplacePrefab：原位替换实体（保位置换类型）。
-- ★ 典型用途：四季/事件把某个 prefab 换成另一个（保持地形对齐不跳变）。
-- ★ 注意它不复制任何业务数据——只是「删旧建新 + 对齐坐标」，
--   调用方负责把需要保留的状态显式搬过去。
function ReplacePrefab(original_inst, name, skin, skin_id, creator)
    local x,y,z = original_inst.Transform:GetWorldPosition()

    local replacement_inst = SpawnPrefab(name, skin, skin_id, creator)
    replacement_inst.Transform:SetPosition(x,y,z)

    original_inst:Remove()

    return replacement_inst
end

--============================================================
-- 【分区 08】★★ 存档位置解析 —— 读档时实体该出现在哪
--============================================================
local function ResolveSaveRecordPosition(data)
-- ★★★ 为什么存档坐标有两套（这是移动平台带来的真实难题）：
--   ① 绝对坐标（data.x/y/z）：实体在世界空间的位置。
--   ② 平台局部坐标（data.puid + data.rx/ry/rz）：实体挂在移动平台上时的位置。
-- ★★ 关键坑：若只存绝对坐标，平台移动后，实体就会**留在平台原来的位置**，
--   表现为「实体掉在海上/掉进水里」。所以有平台时必须存局部坐标。
--   puid = platform UID，移动平台管理器用它反查平台实体。
	if data.puid ~= nil then
		local walkableplatformmanager = TheWorld.components.walkableplatformmanager
		if walkableplatformmanager ~= nil then
			local platform = walkableplatformmanager:GetPlatformWithUID(data.puid)
			if platform ~= nil then
-- ★ LocalToWorldSpace：把平台局部坐标换算回世界坐标。
--   `data.rx or 0` 的 or 0 兜底：**旧存档**里没有 rx/ry/rz 字段（那时还没这功能），
--   缺失就必须当 0，否则局部坐标求解失败。
--   ★ 这就是「跨版本迁移」在存档里的典型形态：不是显式的升级函数，
--     而是**读取侧用默认值容忍旧数据**。比升级函数更鲁棒（无需判断版本号）。
				local x, y, z = platform.entity:LocalToWorldSpace(data.rx or 0, data.ry or 0, data.rz or 0)
				return x, y, z, platform
			end
		end
	end
-- ★ 无平台时的退路：直接用绝对坐标。`or 0` 同样兜底缺失字段。
--   ⚠ 注意这里返回 3 个值，而上方 return 返回 4 个值（含 platform）。
--     Lua 中「少返回几个值」是安全的（调用方 platform 得 nil），但这属于
--     隐式契约，改动时需谨慎——调用方必须处理 platform 可能为 nil。
	return data.x or 0, data.y or 0, data.z or 0
end

--============================================================
-- 【分区 09】★★★ SpawnSaveRecord —— 读档时把一条存档记录还原成实体
--============================================================
--
-- ★★★ 这是 SaveGame（1089 行 GetSaveRecord）的**镜像函数**，也是整个存档
--   系统里信息量最大的一个函数。它回答一个问题：存档里的一条记录，
--   如何变回世界里的一个活实体？五个步骤：
--     ① SpawnPrefab 生成实体（440 行）——按 prefab 名找构造器
--     ② 落位（447-448 行）——ResolveSaveRecordPosition 解析平台局部坐标
--     ③ 建表（459-466 行）——把实体登记进 newents，供后续记录查找
--     ④ 补挂 scenariorunner（468-476 行）——存档驱动的组件
--     ⑤ SetPersistData（477 行）——真正灌入业务数据
function SpawnSaveRecord(saved, newents)
    --print(string.format("~~~~~~~~~~~~~~~~~~~~~SpawnSaveRecord [%s, %s, %s]", tostring(saved.id), tostring(saved.prefab), tostring(saved.data)))
-- ★ 存档里存的是 `saved.prefab`（字符串），靠 Prefabs 表换成构造器。
--   ★ 这就是为什么 Prefabs 表（114 行）不能随便删条目：删了就等于删存档格式。
    local inst = SpawnPrefab(saved.prefab, saved.skinname, saved.skin_id)

    if inst then
-- ★ alt_skin_ids：备用皮肤 ID 列表（一个物品可有多套外观时的降级序列）。
--   ★ 存档里恢复它而不是重新计算，因为它是玩家此前**主动选择**的结果，
--     重新计算会丢失玩家的选择。
		if saved.alt_skin_ids then
			inst.alt_skin_ids = saved.alt_skin_ids
		end

-- ★ 解析出 4 个值，最后一个是 platform（可能为 nil）。
--   platform 会被继续传递（见 456 行），因为**解析完位置后平台对象本身**
--   后面还有用——这是一个「位置解析要顺带返回解析依据」的设计。
		local x, y, z, platform = ResolveSaveRecordPosition(saved)
		inst.Transform:SetPosition(x, y, z)
-- ★★ 这里做**有效性检查**，而不是直接信任存档：
--   Transform:SetPosition 可能让实体立即失效（比如落进了虚空/未加载区域）。
--   失效后必须 return nil 让调用方跳过，否则后续 SetPersistData 会操作野指针。
--   ★ 存档读取永远不可信：可能来自旧版本、被手改、或来自已卸载模组。
        if not inst.entity:IsValid() then
            --print(string.format("SpawnSaveRecord [%s, %s] FAILED - entity invalid", tostring(saved.id), saved.prefab))
            return nil
-- ★★ 快照存档的特殊路径（is_snapshot_save_record）：
--   服务器回滚（rollback）时读的是**历史快照**，此时不重新计算平台归属，
--   而是把刚才解析出的 platform **硬塞进 _snapshot_platform**，
--   供之后 GetSaveRecord 再次快照时复用。
--   ★ 这是一个「为快照机制开后门」的设计，代价是实体上多了一个私有字段。
		elseif saved.is_snapshot_save_record then
			--V2C: We won't properly attach to platforms when restoring snapshot save records.
			--     ie. inst:GetCurrentPlatform() will likely return nil
			--     Workaround for passing our platform over to the GetSaveRecord()
			inst._snapshot_platform = platform
		end

--============================================================
-- ★★★ newents 表 —— 存档还原期间的「GUID → 实体」索引
--============================================================
-- ★★ 这是读档最核心的数据结构。读档是**两遍**的：
--   第一遍生成所有实体（此时实体之间还不知道彼此存在），
--   第二遍才注入 persistdata（此时才能解析实体间的引用，如「谁拿着谁」）。
--   newents 就是把第一遍的结果传给第二遍的桥。
-- ★ 与 SaveGame 1085 行 saved_ents 严格对称：
--     写：saved_ents[GUID] = record              （1089-1099 行）
--     读：newents[record.id] = {entity=inst, data=...}（462 行）
--   ⇒ 改存档格式时，这两处必须同步改。
        if newents then
            --this is kind of weird, but we can't use non-saved ids because they might collide
-- ★★ 源码英文注释直接承认「this is kind of weird」——这里确实是存档系统里
--   最诡异的一段代码。原因是存档里同时存在**有 id** 和**无 id** 的记录：
--     · 有 id：被别的实体引用过（属于 references，1183 行回填）
--     · 无 id：完全孤立的实体，从没被谁引用
--   ★ 无 id 的记录如果用「自己」当键（464 行 newents[inst]），
--     就不会与其他无 id 记录冲突——因为 inst 是唯一对象引用。
--   ★ 为什么这样设计（关键推论）：
--     源码 460 行写得很清楚：「we can't use non-saved ids because they might
--     collide」——不能临时造 id，因为**可能撞上存档里已有的 id**。
--     存档 id 是 GUID，一旦复用会导致两个实体互相引用。
--     ⇒ 唯一安全的「键」就是对象本身的引用——Lua 表用 table 当键天然不冲突。
--   ★★ 这解释了整个存档系统的 id 设计原则：
--     **只给「被引用过」的实体发持久 id**，其余用对象身份兜底。
            if saved.id  then
                newents[saved.id] = {entity=inst, data=saved.data}
            else
                newents[inst] = {entity=inst, data=saved.data}
            end
        end

--============================================================
-- ④ 场景组件的特殊处理：scenariorunner 是「存档驱动的组件」
--============================================================
-- ★★ 这里的模式值得单独指出：scenariorunner **不是 prefab 自带的**，
--   而是因为存档数据里出现了 scenario / scenariorunner 字段才被动态挂上。
--   ⇒ 存档可以「凭空创造」一个预制体定义里不存在的组件。
--   ★ 这是一个非常危险但也非常有用的扩展点：它让 mod 能通过存档注入行为。
--   ⚠ 风险：若存档数据被篡改，SetScript 的内容会被当代码加载。
--     不过整份存档本来就来自可信来源（服务器），故原版未做校验。
        -- Attach scenario. This is a special component that's added based on save data, not prefab setup.
        if saved.scenario or (saved.data and saved.data.scenariorunner) then
            if inst.components.scenariorunner == nil then
-- ★ 幂等保护：只有确实缺组件才 AddComponent（重复添加会报错）。
                inst:AddComponent("scenariorunner")
            end
            if saved.scenario then
                inst.components.scenariorunner:SetScript(saved.scenario)
            end
        end
-- ★★★ 第 ⑤ 步：SetPersistData 是**真正注入业务数据**的地方。
--   它会递归调用所有组件的 OnLoad —— 组件的 OnLoad 里通常还会去 newents
--   里查别的实体。这就形成了「两遍还原」的第二遍。
--   ★ 必须在 Transform 设置（448 行）之后：组件的 OnLoad 常常会立刻
--     根据坐标做事（如放置装饰、检查脚下地形）。
        inst:SetPersistData(saved.data, newents)

    else
        print(string.format("SpawnSaveRecord [%s, %s] FAILED", tostring(saved.id), saved.prefab))
    end

    return inst
end

-- 【分区 10】实体生命周期（1/3）—— CreateEntity
function CreateEntity(name)
-- ★★★ Ents 是**全局 GUID → EntityScript 的映射表**，本文件多处依赖它：
--   OnRemoveEntity / RemoveEntity / SpawnPrefab(410) / PushEntityEvent 等。
--   注意 C++ 侧 CreateEntity 只造了个裸实体，Ents[guid] = scr 这一行
--   才让 Lua 侧「看得见」它。
    local ent = TheSim:CreateEntity()
    local guid = ent:GetGUID()
    local scr = EntityScript(ent)
    if name ~= nil then
        scr.name = name
    end
-- ★ NumEnts 统计当前实体总数，供调试与性能监控用。
    Ents[guid] = scr
    NumEnts = NumEnts + 1
    return scr
end

local debug_entity = nil
local debug_table = nil

--============================================================
-- 【分区 10 续】OnRemoveEntity —— 实体销毁的**唯一收口**
--============================================================
-- ★★★ 这个函数的价值在于「清理的完整性」：一个实体被销毁时，
--   所有按 GUID 索引它的全局表都必须同步清理，否则就是内存泄漏 + 野指针。
--   本文件负责四张表，Brain/SGManager 各管一张：
--     PhysicsCollisionCallbacks（503 行）
--     Ents（517 行）
--     UpdatingEnts + num_updating_ents（519-522 行）
--     StaticUpdatingEnts（524 行）/ WallUpdatingEnts（528 行）
function OnRemoveEntity(entityguid)

    PhysicsCollisionCallbacks[entityguid] = nil

    local ent = Ents[entityguid]
    if ent then

        if debug_entity == ent then
            debug_entity = nil
        end

-- ★ 先通知 AI 与状态图管理器「这个实体要死了」，再动表。
--   顺序很重要：SGManager 可能需要访问该实体的数据来清理自己的状态。
        BrainManager:OnRemoveEntity(ent)
        SGManager:OnRemoveEntity(ent)

-- ★★ KillTasks：杀掉该实体身上所有 DoTaskInTime 定时任务。
--   ★ 这是存档/读档安全的关键之一——如果一个实体的定时任务在它
--     被销毁后仍触发，闭包里持有的实体引用就成了悬垂引用。
--   ★ 读档时旧实体被批量销毁、同一预制体的新实体被批量创建，
--     若定时任务没杀干净，会出现「两个玩家都在执行同一个任务」的诡异 bug。
        ent:KillTasks()
        NumEnts = NumEnts - 1
        Ents[entityguid] = nil

        if UpdatingEnts[entityguid] then
            UpdatingEnts[entityguid] = nil
            num_updating_ents = num_updating_ents - 1
        end

        if StaticUpdatingEnts[entityguid] then
            StaticUpdatingEnts[entityguid] = nil
        end

        if WallUpdatingEnts[entityguid] then
            WallUpdatingEnts[entityguid] = nil
        end
    end
end

-- 【分区 10 续】RemoveEntity —— 删除的对外入口（含延迟机制）
function RemoveEntity(guid)
    local inst = Ents[guid]
    if inst then
        --certain things(like seamless player swapping) need to delay the despawning on a local client until they have ran their own code.
-- ★★★ delayclientdespawn：客户端延迟销毁机制。
--   英文注释说明了场景：无缝换人（seamless player swapping）时，
--   客户端刚收到玩家的销毁事件就立刻删掉会破坏后续代码的执行，
--   所以先标记「应延迟」，等换人逻辑跑完再真正删除。
--   ★ 推断：后续会检查 delayclientdespawn_attempted 并在安全点真正 Remove。
-- ⚠ 疑似缺陷：这里只**置位** delayclientdespawn_attempted 就直接 return，
--   本文件内没有任何地方消费这个标志去真正执行 inst:Remove()。
--   若消费点在别处（推测在 networking.lua / playerspawner），则设计正确；
--   若不存在，则实体永远不会真正被删除（泄漏）。不修改，仅标注需核实。
        if inst.delayclientdespawn then
            inst.delayclientdespawn_attempted = true
            return
        end
        inst:Remove()
    end
end

function PushEntityEvent(guid, event, data)
    local inst = Ents[guid]
    if inst then
        inst:PushEvent(event, data)
    end
end

function GetEntityDisplayName(guid)
    local inst = Ents[guid]
    return inst ~= nil and inst:GetDisplayName() or ""
end

--============================================================
-- 【分区 11】时间函数 —— 三套时钟的区别是本文件最容易搞混的地方
--============================================================
-- ★ 三种时间：
--   ① 真实时间（GetTimeReal）—— 真实世界时钟，不受暂停/倍速影响。用于 UI 动画。
--   ② 游戏时间（GetTime）—— TheSim:GetTick() * ticktime，受暂停/倍速影响。
--   ③ 静态时间（GetStaticTime）—— 「静态 tick」，世界没在跑时冻结。
-- ★★ 存档为什么关心时间：世界天数/季节由 clock 驱动（见 1268 行 metadata.clock），
--   它来自 world_network.persistdata，与本节函数同源。
------TIME FUNCTIONS

function GetTickTime()
    return TheSim:GetTickTime()
end

-- ★★ ticktime 在文件加载时**只读一次**并缓存为 upvalue。
--   ★ 为什么可以这样做：ticktime 是固定的单帧时长（引擎常量），不会变。
--   ★ 收益极小但无害——省掉每次 GetTime 的 C++ 跨语言调用开销。
--   ⚠ 疑似缺陷（理论风险）：若引擎支持运行时改变 tick 长度（如自适应帧率），
--     缓存的 ticktime 会变成过期值，导致游戏时间整体偏移。
--     DST 目前固定 1/30 或 1/60，故实际安全。不修改。
local ticktime = GetTickTime()
function GetTime()
    return TheSim:GetTick()*ticktime
end

function GetStaticTime()
-- ★★ GetStaticTick 是「世界静止时的 tick 计数」。
--   ★ 设计目的：让「与世界的推进同步」的逻辑（季节、日出）能在世界静止时
--     保持一个稳定的基准值，避免用真实时间导致大跳变。
    return TheSim:GetStaticTick()*ticktime
end

function GetTick()
    return TheSim:GetTick()
end

function GetStaticTick()
    return TheSim:GetStaticTick()
end

function GetTimeReal()
    return TheSim:GetRealTime()
end

function GetTimeRealSeconds()
-- ★ GetRealTime 返回毫秒，这里做单位换算成秒。
--   ⚠ 注意与 GetTime 的单位一致性：GetTime 是 tick*ticktime（也是秒）。
    return TheSim:GetRealTime() / 1000
end

-- 【分区 12】脚本加载与调试
---SCRIPTING
local Scripts = {}

-- ★★ LoadScript 的缓存语义：同名文件只 loadfile 一次。
--   ★ Scripts 这张缓存表存的是**执行后的返回值**（593-597 行）。
--   ⚠ 潜在问题：loadfile("scripts/"..filename) 失败时，assert(type(scriptfn)
--     == "function") 的错误消息会是 Lua 的错误字符串而非文件名，
--     排错体验较差。不修改。
function LoadScript(filename)
    if not Scripts[filename] then
        local scriptfn = loadfile("scripts/" .. filename)
        assert(type(scriptfn) == "function", scriptfn)
        Scripts[filename] = scriptfn()
    end
    return Scripts[filename]
end

function RunScript(filename)
    local fn = LoadScript(filename)
    if fn then
        fn()
    end
end

-- ★ GetEntityString 用于调试面板：按 GUID 取实体的调试串。
function GetEntityString(guid)
    local ent = Ents[guid]

    if ent then
        return ent:GetDebugString()
    end

    return ""
end

-- ★★ GetExtendedDebugString 是一个**互斥的三选一调试视图**：
--   ① 调试实体存在 → 显示 AI（brain）串
--   ② 否则若开了声音调试 → 显示音效串（第二个返回值 24 大概是保留/行数）
--   ③ 否则若开了世界状态调试 → 打印 worldstate 组件的转储
--   ④ 最后兜底显示当前屏幕名
--   ★ 优先级顺序反映「调试时最想先看什么」。elseif 链保证互斥。
function GetExtendedDebugString()
-- ★ 三选一调试视图的分支本体（设计说明见上方 618 行注释）。
    if debug_entity and debug_entity.brain then
        return debug_entity:GetBrainString()
-- ★ SOUNDDEBUG_ENABLED 是编译期常量（由调试菜单开关写入）。
    elseif SOUNDDEBUG_ENABLED then
        return GetSoundDebugString(), 24
    elseif WORLDSTATEDEBUG_ENABLED then
        return TheWorld and TheWorld.components.worldstate and TheWorld.components.worldstate:Dump()
    end

-- ★ 兜底分支：不在游戏里就显示当前界面名，帮玩家/客服定位卡在哪个界面。
    if TheFrontEnd and TheFrontEnd:GetActiveScreen() then
        return "Current screen:" .. TheFrontEnd:GetActiveScreen().name
    end
    return ""
end

-- ★ GetDebugString：★ 调试面板（F1 之类）的主文本。
--   ★ 与 GetExtendedDebugString 的区别：本函数**先打印 scheduler**（636 行），
--     是「诊断当前帧在跑什么」；后者是「看某个子系统内部状态」。
--   ★ 排查卡顿时 GetDebugString 更常用 —— 能看出调度器积压。
function GetDebugString()

    local str = {}
    table.insert(str, tostring(scheduler))

-- ★ 有调试实体时附加其详细串（分隔线用于视觉隔断）。
    if debug_entity then
        table.insert(str, "\n-------DEBUG-ENTITY-----------------------\n")
        table.insert(str, debug_entity.GetDebugString and debug_entity:GetDebugString() or "<no debug string>")
    end

    return table.concat(str)
end

-- debug_entity / debug_table 是调试焦点，由 SetDebugEntity 维护。
function GetDebugEntity()
    return debug_entity
end

-- ★★ SetDebugEntity 维护「选中态」：C++ 侧 SetSelected 会画描边高亮。
--   ★ 切换时先取消旧的（651-653 行）再设置新的，避免出现两个高亮实体。
-- ============================================================
-- SetDebugEntity：设置/清除调试焦点（含高亮描边）
-- ============================================================
function SetDebugEntity(inst)
    if debug_entity ~= nil and debug_entity:IsValid() then
        debug_entity.entity:SetSelected(false)
    end
    if inst ~= nil and inst:IsValid() then
        debug_entity = inst
        inst.entity:SetSelected(true)
    else
        debug_entity = nil
    end
end

-- ============================================================
-- Get/SetDebugTable：调试用的「任意表」通道
-- ============================================================
-- ★ 这是一个给调试 UI 用的**万能引用槽**：调试面板可以把任意表塞进来，
--   再在屏幕上交互式浏览。这是老式调试工具的常见设计。
function GetDebugTable()
    return debug_table
end

function SetDebugTable(tbl)
    debug_table = tbl
end

--============================================================
-- 【分区 13】★★ 休眠与唤醒 —— 存档性能的核心机制
--============================================================
-- ★★★ 为什么需要这套机制：
--   一个 DST 世界有上千个实体（草、石头、机器），但每帧只有玩家附近少数在动。
--   「休眠（sleep）」= 让远离玩家的实体停止思考：不跑 AI、不跑状态图、不跑发射器。
--   ★ 唤醒/休眠的判据由引擎（C++）根据距离与可见性计算，本文件只处理**回调**。
--   ★★ 与存档的关系：休眠实体不更新 ⇒ 其状态更稳定 ⇒ 存档更可预测；
--     读档后引擎会重新判断哪些实体需要唤醒。
function OnEntitySleep(guid)
    local inst = Ents[guid]
    if inst then
        inst:PushEvent("entitysleep")

        if inst.OnEntitySleep then
            inst:OnEntitySleep()
        end

-- ★★ _DisableBrain_Internal：立刻关闭该实体的 AI 大脑。
--   ★ 注意「_Internal」后缀——这类函数绕过正常的检查，直接改内部状态，
--     为的是在休眠这种批量操作里省掉开销。
		inst:_DisableBrain_Internal()

        if inst.sg then
-- ★ SGManager:Hibernate：状态图进入冬眠（保留当前状态，不推进）。
--   ★ 与 KillTasks 的区别：Hibernate 是**暂停**状态图，KillTasks 是杀定时器。
--     两者都做，因为休眠既要停逻辑也要停一次性回调。
            SGManager:Hibernate(inst.sg)
        end

		inst.sleepstatepending = nil

        if inst.emitter then
            EmitterManager:Hibernate(inst.emitter)
        end

-- ★ 遍历所有组件调 OnEntitySleep —— 组件级的休眠钩子。
--   ★ 采用「遍历组件」而非「在实体上写一个总函数」的设计，让各组件自治。
--   ★ 典型使用者：可燃组件会停止火焰特效、声音组件会停掉循环音。
        for k,v in pairs(inst.components) do
            if v.OnEntitySleep then
                v:OnEntitySleep()
            end
        end
    end
end

--============================================================
-- 【分区 13 续】OnEntityWake —— 与 OnEntitySleep 严格镜像
--============================================================
function OnEntityWake(guid)
    local inst = Ents[guid]
    if inst then
        inst:PushEvent("entitywake")

        if inst.OnEntityWake then
            inst:OnEntityWake()
        end

-- ★★★ 这段英文注释记录了一个**已知的设计取舍**（V2C: Vote Comment）：
--   「若客户端上的网络实体也需要正常工作，应该用较慢的 :HasTag("INLIMBO")
--    检查。但客户端上不应该有能休眠的网络实体。」
-- ★★ 解读：客户端为了性能用了 IsInLimbo()（快，字段直读）而不是 HasTag
--   （慢，要查标签表）。作者明确论证了「客户端不会有休眠的网络实体」，
--   所以可以接受这个风险。
-- ⚠ 这是一个**依赖外部不变量的优化**：若将来某个机制让客户端实体
--   也能休眠（源游标 D2 的某些 mod 曾做到），这里就会漏判。不修改。
        --V2C: Note that if this needs to work properly for networked
        --     entities on clients, then should use the slower check
        --     :HasTag("INLIMBO").  But there should be no networked
        --     entities on clients that can go to sleep.
-- ★ 注意休眠是无条件的，唤醒则检查 IsInLimbo —— 这个不对称是有意的。
--   休眠总是安全的（没人会因为多睡而崩溃），唤醒则必须确认实体已「入场」。
        if not inst:IsInLimbo() then
			inst:_EnableBrain_Internal()
            if inst.sg then
                SGManager:Wake(inst.sg)
            end
        end

-- ★ 清空 sleepstatepending（休眠待定标志）—— 唤醒后不再有挂起的休眠请求。
		inst.sleepstatepending = nil

        if inst.emitter then
            EmitterManager:Wake(inst.emitter)
        end

-- ★ 与 OnEntitySleep 尾部（691 行）镜像：通知所有组件。
        for k,v in pairs(inst.components) do
            if v.OnEntityWake then
                v:OnEntityWake()
            end
        end
    end
end

-- ============================================================
-- OnPhysicsWake / OnPhysicsSleep：物理引擎级别的休眠（区别于 AI 休眠）
-- ============================================================
-- ★★ 必须分清两套休眠：
--   · 上一节的 sleep/wake 是**游戏逻辑**休眠（不思考、不跑状态图）；
--   · 本节的 physics wake/sleep 是**物理引擎**休眠（不参与碰撞计算）。
-- ★ 二者独立：一个实体可以「逻辑醒着但物理睡着」（静止的雕像）。
-- ★★ 这两个函数**只通知组件**，不碰 AI/状态图 —— 印证了上面的区分。
function OnPhysicsWake(guid)
    local inst = Ents[guid]
    if inst then
        if inst.OnPhysicsWake then
            inst:OnPhysicsWake()
        end

        for k, v in pairs(inst.components) do
            if v.OnPhysicsWake then
                v:OnPhysicsWake()
            end
        end
    end
end

-- ★ OnPhysicsSleep：结构与 OnPhysicsWake 完全一致。
function OnPhysicsSleep(guid)
    local inst = Ents[guid]
    if inst then
        if inst.OnPhysicsSleep then
            inst:OnPhysicsSleep()
        end

        for k,v in pairs(inst.components) do
            if v.OnPhysicsSleep then
                v:OnPhysicsSleep()
            end
        end
    end
end

--============================================================
-- 【分区 14】★★★ 服务器暂停状态机 —— 三种 pause 的区别
--============================================================
-- ★★★ 本文件里最容易看错的一段：pause 有**三种**，语义不同！
--   ① Paused          —— 真暂停（菜单打开）。有静音 mix、有 HUD 提示。
--   ② Autopaused      —— 「假装没暂停」：打开地图/合成界面时暂停，但表现上
--                        不当暂停处理（不加 mix、不显示暂停文字）。
--   ③ GameAutopaused  —— 「连暂停都不承认」：非专用服务器上所有玩家都在
--                        大厅时触发。既无顶部文字，也不推静音 mix。
-- ★ 这三者是**正交**的标志位，不是互斥状态，故命名都有 Autopause 前缀。
--============================================================
-- 【分区 14 续】三个暂停标志的声明
--============================================================
-- ★ 三个模块级变量（Paused / Autopaused / GameAutopaused）
--   对应 767 行 OnServerPauseDirty 的三个入参。
-- ★★ 为什么要分三个变量而不是一个数字标志：
--   三者在**表现层**的差异极大（声音 mix / HUD / 顶部文字），
--   合成一个枚举会导致 if 分支里反复解包，直接用三个布尔最简单。
local Paused = false
local Autopaused = false
local GameAutopaused = false

function OnServerPauseDirty(pause, autopause, gameautopause, source)
-- ★★★ 源码英文注释是理解这段代码的钥匙，逐条翻译：
--   「autopause 意味着我们暂停了，但我们不**表现得像**暂停了，
--     这类情况比如打开地图导致的自动暂停。」
--   「gameautopause 意味着我们暂停了，但我们真的不表现得像暂停，
--     连承认都不承认。只在非专用服务器且所有玩家都在大厅时发生。
--     gameautopause 没有顶部信息文字，也不推那个让游戏变聋的 sound mix。」
    --autopause means we are paused but we don't act like it,
    --this would be for stuff like autpausing from the map being open.

    --gameautopause means we are paused, but we really don't act like it, like not even acknowledge it at all.
    --this only occurs when a non dedicated server has all players in the lobby.
    --gameautopause has no information text, at the top of the screen, and doesn't push the sound mix that deafens the game.

-- ★★★ 这里算出了 4 个派生布尔量，后面全部依赖它们做**状态跃迁**判断：
--   WasPaused / IsPaused —— 任一形式暂停（用于打印日志）
--   WasNormalPaused / IsNormalPaused —— 「真暂停」（用于决定 sound mix）
-- ★★ 为什么要区分 Was 和 Is：mix 的 Push/Delete 必须成对且只在
--   「从非暂停进入暂停」和「离开暂停」这两个**跃迁点**执行，
--   不能在每次回调里都 Push（否则会重复叠加）。
    local WasPaused = Paused or Autopaused or GameAutopaused
    local IsPaused = pause or autopause or gameautopause

    local WasNormalPaused = (Paused or Autopaused) and not GameAutopaused
    local IsNormalPaused = (pause or autopause) and not gameautopause

    if WasPaused and not IsPaused then
        print("Server Unpaused")
    elseif not Paused and pause then
        print("Server Paused")
    elseif (autopause or gameautopause) and not pause then
        print("Server Autopaused")
    end

    Paused = pause
    Autopaused = autopause
    GameAutopaused = gameautopause

-- ★★ 声音 mix 的精确管理：只在跃迁点 Push/Pop，其余情况不动。
--   ★ 这就是前面区分 NormalPaused 的原因——自动暂停**不该**让玩家失聪。
    if not WasNormalPaused and IsNormalPaused then
        TheMixer:PushMix("serverpause")
    elseif not IsNormalPaused then
        TheMixer:DeleteMix("serverpause")
    end

    if ThePlayer and ThePlayer.HUD then
        ThePlayer.HUD:SetServerPaused(pause)
    end

    if TheFrontEnd then
-- ★ 暂停提示文字的优先级：真暂停显示 source（谁触发的，如服务器管理员），
--   自动暂停显示字面量 "autopause"，其余（gameautopause）**不显示**。
-- ★ 这正是 770-773 行那句「gameautopause 没有信息文字」的代码落点。
-- ⚠ 疑似缺陷（极低风险）：`pause and source or autopause and "autopause" or nil`
--   依赖 Lua 的 and 高于 or。当 pause 为真但 source 为 nil/假值时，
--   会错误地落到 autopause 分支显示 "autopause"。
--   推理依据：表达式在 pause=true, source=nil 时求值为 (nil) or ("autopause")
--   = "autopause"，与「source 非空」的意图不符。
--   实际不触发的原因：服务器发起真暂停时必然附带 source。不修改。
        TheFrontEnd:SetServerPauseText(pause and source or autopause and "autopause" or nil)
    end

    if TheWorld then
        TheWorld:PushEvent("serverpauseddirty", {pause = pause, autopause = autopause, gameautopause = gameautopause, source = source})
    end

    TheHaptics:PauseEffects(IsNormalPaused)
end

-- 【分区 15】ReplicateEntity —— 实体复制（含无缝换人补丁）
function ReplicateEntity(guid)
    local inst = Ents[guid]

    local _ThePlayer
-- ★★★ seamlessswaptarget：无缝换人目标。
--   ★ 这是一个非常精细的 hack：某些预制体在复制时**要求 ThePlayer 指向自己**
--     （例如只有「当前玩家」的组件才允许被复制），所以这里临时把全局
--     ThePlayer 换成目标实体，复制完再换回来。
--   ★ 全局变量做临时改写必须配对还原（825-827 行），作者用 _ThePlayer 局部备份。
    if inst.isseamlessswaptarget then
        _ThePlayer = ThePlayer
        ThePlayer = inst
    end

    inst:ReplicateEntity()

    if _ThePlayer then
        ThePlayer = _ThePlayer
    end
end

-- DisableLoadingProtection：解除玩家的加载保护。
-- ★ 加载保护的作用：防止玩家实体在数据尚未加载完成时被 AI/状态图操作，
--   导致用默认值（如饥饿度 0）覆盖真实存档数据。ResumeExistingUserSession
--   在 SetPersistData **之后**才调用 EnableLoadingProtection（见 2078-2079），
--   这个顺序是刻意的。
function DisableLoadingProtection(guid)
    local player = Ents[guid]
    if player then
        player:DisableLoadingProtection()
    end
end

------------------------------

function PlayNIS(nisname, lines)
    local nis = require ("nis/"..nisname)
    local inst = CreateEntity()

    inst:AddComponent("nis")
    inst.components.nis:SetName(nisname)
    inst.components.nis:SetInit(nis.init)
    inst.components.nis:SetScript(nis.script)
    inst.components.nis:SetCancel(nis.cancel)
    inst.entity:CallPrefabConstructionComplete()
    inst.components.nis:Play(lines)
    return inst
end

--============================================================
-- 【分区 17】★★ 本地暂停体系（与分区的服务器暂停是两套）
--============================================================
-- ★ 三层结构：
--   paused          —— 本地玩家主动暂停（菜单）
--   simpaused       —— 模拟暂停（★ DST 里不使用，见 875 行注释）
--   default_time_scale —— 默认时间倍率（加速/减速）
local paused = false
local simpaused = false
local default_time_scale = 1

function IsPaused()
    return paused
end

function IsSimPaused()
    return simpaused
end

-- ★★ global("PlayerPauseCheck") 的作用是「**声明而不定义**」：
--   强制该名字为全局变量（若不存在则置 nil），避免其他脚本先定义局部同名
--   变量导致本文件的 SetPause 读不到。英文注释："function not defined when
--   this file included" —— 即本文件加载时该函数还不存在，稍后由别处定义。
-- ★ 这是 Lua 里处理「前向引用」的常用手法。
global("PlayerPauseCheck")  -- function not defined when this file included

function SetDefaultTimeScale(scale)
    default_time_scale = scale
    if not paused then
        TheSim:SetTimeScale(default_time_scale)
    end
end

-- ★★ V2C 注释（DST 单机 → 联机 移植时加的）：「我们在 DST 里不用这个」。
--   SetSimPause 变成了只置标志的空壳。★ 这类 V2C 注释在本文件非常多，
--     是研究 DST 如何从 Don’t Starve 单机移植而来的珍贵史料。
---------------------------------------------------------------------
--V2C: We don't use this in DST
function SetSimPause(val)
    simpaused = val
end

-- SetServerPaused：请求服务器暂停（toggle 或显式）。
function SetServerPaused(pause)
    -- Ignore if an imgui window is open & has focus
    if CAN_USE_DBUI then
		if TheFrontEnd:IsImGuiWindowFocused() then
	        return
		end
    end

-- ★ pause 为 nil 时取反当前状态 = 「切换」语义（toggle）。
--   这种「nil = toggle」的设计在 OnNetworkDisconnect 里也大量复用。
    if pause == nil then pause = not TheNet:IsServerPaused(true) end
    TheNet:SetServerPaused(pause)
end

--============================================================
-- 【分区 17 续】★★ 自动暂停的三种来源与引用计数
--============================================================
-- ★★ autopausecount 是**引用计数**：地图打开 +1，关闭 -1。
--   ⇒ 多个来源同时要求暂停时，计数归零才真正恢复。
-- ★ 为什么用计数而不是布尔：合成界面、地图、控制台可以叠加开启，
--   布尔会在任一来源关闭时过早恢复。
local autopausecount = 0
function SetAutopaused(autopause)
    autopausecount = autopausecount + (autopause and 1 or -1)
-- ★★ 计数自检：负数说明配对错误（关了没开的），>5 说明有泄漏。
--   ⚠ 疑似缺陷（真实缺陷，仅 DEBUG 下暴露）：
--     条件 `DEBUG_MODE and autopausecount < 0 or autopausecount > 5`
--     因 Lua 的 and 优先级高于 or，实际解析为
--       (DEBUG_MODE and autopausecount < 0) or (autopausecount > 5)
--     ⇒ **正式版（DEBUG_MODE=false）下前半段恒为 false**，
--       于是「autopausecount > 5」在**任何分支**（含正式版）都会触发 assert(false)！
--     作者本意显然是 `DEBUG_MODE and (autopausecount < 0 or autopausecount > 5)`，
--     即「只在 dev 分支检查」。
--   ★ 推理依据：若作者只想在 dev 检查，就必然要写括号；
--     而当前写法让 dev-only 的保护变成了全分支生效的崩溃点。
--   ★ 影响：一旦有 6 个以上自动暂停来源同时开启（例如大地图 + 多层 UI），
--     正式版会直接 assert 崩溃。不修改代码，仅标注。
	if DEBUG_MODE and autopausecount < 0 or autopausecount > 5 then
		print("ERROR: autopausecount is invalid:", autopausecount)
		assert(false)
	end
    DoAutopause()
end

-- ★★ craftingautopause 是**布尔**而非计数（与 autopausecount 不同）。
--   ★ 设计差异的理由：合成界面是唯一入口、互斥的，不需要引用计数。
local craftingautopause = false
function SetCraftingAutopaused(autopause)
    craftingautopause = autopause
    DoAutopause()
end

local consoleautopausecount = 0
function SetConsoleAutopaused(autopause)
    consoleautopausecount = consoleautopausecount + (autopause and 1 or -1)
    DoAutopause()
end

-- ★★ DoAutopause 是三个来源的**汇聚点**：任一来源要求且用户开了对应选项，
--   就自动暂停。最后 `and not TheFrontEnd:IsControlsDisabled()` 是一个守卫：
--   ★ 当 UI 正在禁用输入时（切屏中）不要自动暂停，否则会打断切屏流程。
-- ★ Profile:Get*Enabled() 三个方法都是**用户偏好**——玩家可以全部关掉，
--   这也是 DoAutopause 必须每次重新求值而不能缓存布尔的原因。
function DoAutopause()
    TheNet:SetAutopaused(
        ((autopausecount > 0 and Profile:GetAutopauseEnabled())
         or (craftingautopause and Profile:GetCraftingAutopauseEnabled())
         or (consoleautopausecount > 0 and Profile:GetConsoleAutopauseEnabled())
		) and not TheFrontEnd:IsControlsDisabled()
    )
end

-- V2C: DST 的 sim 暂停改由网络检查实现，并会回调到 LUA 这里。
---------------------------------------------------------------------
--V2C: DST sim pauses via network checks, and will notify LUA here
-- ★★ 空的 OnSimPaused —— 而且英文注释解释了**为什么**可以为空：
--   「这里大概不该做任何事，因为 sim 现在是暂停的，
--    这里触发的任何东西大概率都不会真的生效。」
--   ★ 这是诚实的设计注释：与其写注定无效的代码，不如留空并说明。
function OnSimPaused()
    --Probably shouldn't do anything here, since sim is now paused
    --and most likely anything triggered here won't actually work.
end

function OnSimUnpaused()
    if TheWorld ~= nil then
        TheWorld:PushEvent("ms_simunpaused")
    end
end
---------------------------------------------------------------------

-- 【分区 17 续】SetPause —— 本地暂停的唯一入口
function SetPause(val,reason)
    if val ~= paused then
        if val then
-- ★ PushMix/PopMix 成对：mix 是一个「音频混音层」，压低/静音某类音源。
--   ★ 与分区 14 的 serverpause mix 是两套独立层。
            paused = true
            TheMixer:PushMix("pause")
        else
            paused = false
            TheMixer:PopMix("pause")
        end
    end
-- ★ 英文注释坦承："probably don't need this check"（大概不需要这个判断）。
--   同时给出了真正的约束：「必须在 SetTimeScale 之后做」。
--   ★ 即：PlayerPauseCheck 是个可选钩子，由别的文件定义（865 行 global 声明）。
    if PlayerPauseCheck then   -- probably don't need this check
        PlayerPauseCheck(val, reason)  -- must be done after SetTimeScale
    end
end

--============================================================
-- 【分区 18】外部设置 + ★★ 世界生成覆盖（跨版本迁移案例）
--============================================================
--- EXTERNALLY SET GAME SETTINGS ---
-- ★ Settings 是**由外部注入**的全局表：它的内容来自启动参数（C++ →
--   SetInstanceParameters → JSON 解码），而不是本文件的逻辑算出来的。
--   ★ 用途：换档/重开时把上一次的资产选择、角色、模组等参数带到新实例。
--   ⇒ 参照 SimReset（1521 行）：它正是往 Settings 里塞参数的地方。
Settings = {}
function SetInstanceParameters(settings)
    if settings ~= "" then
        --print("SetInstanceParameters:",settings)
-- ★ 空串防御：`settings ~= ""` 而非 `settings ~= nil`。
--   C++ 侧在无参数时传空串，若只判 nil 会走到 json.decode("") 报错。
-- ⚠ 轻微不一致：962 行 Purchases 用同样的判空，但没有 Settings 的空串防御，
--   两者行为一致（同为空串时都跳过），故此处不作为缺陷。仅备注。
        Settings = json.decode(settings)
    end
end

Purchases = {}
function SetPurchases(purchases)
    if purchases ~= "" then
        Purchases = json.decode(purchases)
    end
end


--============================================================
-- 【分区 18 续】★★ UpdateWorldGenOverride —— 一条完整的存档迁移链示范
--============================================================
-- ★★★ 这是本文件里**唯一能看到的跨版本迁移实际调用点**，非常值得研究：
--   它演示了持久化数据的「读 → 升级 → 合并 → 写回」四步闭环。
-- ★ 数据载体是一个 persistent string 文件：../worldgenoverride.lua
--   —— 故意存在**存档目录之外**，因为它是「这台服务器的世界生成设置」，
--     与具体哪个存档无关。
local function UpdateWorldGenOverride(overrides, cb, slot, shard)
    local Levels = require("map/levels")
    local filename = "../worldgenoverride.lua"

-- ★ 写入时区分了「单机存档」与「集群分片存档」两套 API：
--   分片时用 SetPersistentStringInClusterSlot(slot, shard, ...)。
--   ⇒ 这是「同一份逻辑，两种存储拓扑」的适配层，本文件多处出现此模式。
    local function SetPersistentString(str)
        if shard ~= nil then
            TheSim:SetPersistentStringInClusterSlot(slot, shard, filename, str, false, cb)
        else
            TheSim:SetPersistentString(filename, str, false, cb)
        end
    end

-- ============================================================
-- 迁移链第 3 步：**序列化回 Lua 源码文本**
-- ============================================================
-- ★★ 注意生成的是「Lua 源码」而不是 JSON：因为这个文件会被 loadfile 执行，
--   需要的是可执行代码。所以才需要第 998-1005 行那段手工的键名校验
--   （只允许合法的标识符，否则用 ["..."] 形式强行转义）。
-- ⚠ 疑似缺陷（安全性，非当前可利用）：998 行的正则 `^[_%a][_%w]*$` 校验后，
--   非标识符的键会被 %q 转义——这对**键**是安全的。但 1001-1005 行对**值**
--   只区分 string 与其他：布尔值走 tostring 得到 "true"/"false"（合法 Lua），
--   数字也合法。但若值是 nil，tostring(nil) = "nil"（合法）；
--   ★ 唯一危险情形是「值本身是一个含 Lua 代码的字符串」——%q 会正确转义，
--     故实际是安全的。结论：此处无缺陷，仅记录分析过程。
    local function GenerateWorldGenOverride(savedata)
        local out = {}
        table.insert(out, "return {")
        table.insert(out, "\toverride_enabled = true,")

        local worldgen_preset = savedata.worldgen_preset or savedata.preset
        if worldgen_preset and Levels.GetDataForWorldGenID(worldgen_preset) then
            table.insert(out, string.format("\tworldgen_preset = %q,", worldgen_preset))
        end

        local settings_preset = savedata.settings_preset or savedata.preset
        if settings_preset and Levels.GetDataForWorldGenID(settings_preset) then
            table.insert(out, string.format("\tsettings_preset = %q,", settings_preset))
        end

        table.insert(out, "\toverrides = {")
        for name, value in orderedPairs(savedata.overrides) do
-- ★ 键名合法性检查：合法标识符直接写，否则用 ["..."] 括起来。
--   ★ 这是防止「键名含空格或特殊字符」导致生成非法 Lua 源码的关键一步。
            if not name:match('^[_%a][_%w]*$') then
                name = string.format("[%q]", name)
            end
            if type(value) == "string" then
                value = string.format("%q", value)
            else
                value = tostring(value)
            end
            table.insert(out, string.format("\t\t%s = %s,", name, value))
        end
        table.insert(out, "\t},")
        table.insert(out, "}")

        SetPersistentString(table.concat(out, "\n"))
    end

-- ============================================================
-- 迁移链第 1 步：**读出** → 沙盒解析
-- ============================================================
-- ★★★ RunInSandboxSafe 是**沙盒执行**：在一个受控环境里跑这段 Lua 源码，
--   拿回返回值。它是「反序列化不可信文本」的标准姿势。
-- ★★ 为什么必须沙盒：worldgenoverride.lua 是磁盘上的文件，可能被玩家改坏
--   或来自旧版本。沙盒保证它最多返回个表，不会执行 os.execute 之类。
    local function onload(load_success, str)
        if load_success == true then
            local success, savedata = RunInSandboxSafe(str)
            if success and savedata then
-- ============================================================
-- 迁移链第 2 步：★★ **跨版本升级**（本文件唯一的迁移调用点）
-- ============================================================
-- ★★★ UpgradeWorldgenoverrideFromV1toV2 —— 把 V1 结构升级为 V2。
-- ★ 完整迁移链的设计要点（本文件能看到的全部内容）：
--   ① 迁移函数住在**独立的 savefileupgrades.lua**（59912 字节的大文件），
--      而不是在调用点就地处理。
--      ★ 理由：升级逻辑要长期累积、长期保留（老存档可能永远升级不上），
--        与业务逻辑混在一起会变成不可维护的泥潭。
--   ② 迁移以**函数注册表**形式组织：savefileupgrades.lua:31 的 utilities 表
--      集中登记所有升级函数，主流程只负责按顺序调用。
--   ③ ★ 迁移在**读取后立即执行**（onload 回调里第 2 行就调），
--      而不是「等写入时再升」——保证内存里的状态永远是最新版本的形状。
--   ④ ★ 真正的存档升级（不是 worldgenoverride）是另一条路：
--      gamelogic.lua:1031 UpgradeSaveFile，在读档主流程里执行。
--      ⇒ 迁移分两类：世界存档（gamelogic）+ 附属持久化数据（本文件）。
--   ⑤ 参见 gamelogic.lua:1044 DoLoadWorldFile —— 读档的总入口。
                local savefileupgrades = require("savefileupgrades")
                savedata = savefileupgrades.utilities.UpgradeWorldgenoverrideFromV1toV2(savedata)
-- ★ 升级后判断是否启用；未启用则**不覆盖**用户已有的设置文件。
--   ★ 这个「没开就不动」的短路很重要：避免每次启动都重写配置文件。
                if savedata.override_enabled then
                    local worldgen_preset = savedata.worldgen_preset or savedata.preset
-- ★★ 预设数据的 fallback 链：worldgen_preset → settings_preset → 空表。
--   ★ savedata.worldgen_preset or savedata.preset 是**兼容旧字段名**的典型写法：
--     新字段优先，缺失时回退到旧字段名。这就是「字段改名」的标准处理方式，
--     详见文件头「跨版本迁移钩子」小节。
                    local worldgen_presetdata = {overrides = {}}
                    if worldgen_preset then
                        worldgen_presetdata = Levels.GetDataForWorldGenID(worldgen_preset) or worldgen_presetdata
                    end

                    local settings_preset = savedata.settings_preset or savedata.preset
                    local settings_presetdata = {overrides = {}}
                    if settings_preset then
                        settings_presetdata = Levels.GetDataForSettingsID(settings_preset) or settings_presetdata
                    end

                    local location = worldgen_presetdata.location or "forest"

                    local Customize = require("map/customize")
                    local defaultoptions = Customize.GetOptionsWithLocationDefaults(location, true)

                    savedata.overrides = savedata.overrides or {}

                    for override_name, override_option in pairs(overrides) do
-- ★★★ 覆盖合并算法（本函数最精妙的部分）：
--   对每个「本次请求覆盖的项」，先算出「当前生效值」（四层 fallback：
--     worldgen 预设 → settings 预设 → 该地点的默认值 → 全局默认值），
--   然后判断「这次要覆盖的值是否真的不同于当前生效值」：
--     · 不同 → 写进 savedata.overrides（成为一条持久覆盖）
--     · 相同 → 显式写 nil（**撤销**这条覆盖，让它回落到预设/默认）
--   ★★★ 「相同则写 nil」是这套系统的精髓：覆盖项记录的是**差量**。
--     这样预设升级（默认值变了）能自动生效，而用户的个性化选择不丢。
--   ⚠ 副作用：nil 值从表里「消失」，因此 overrides 表里不会保留 nil 项，
--     序列化时也就不会浪费空间。这是特性而非缺陷。
                        local current_option = (worldgen_presetdata.overrides[override_name] or settings_presetdata.overrides[override_name]) or defaultoptions[override_name] or Customize.GetDefaultForOption(override_name)
                        if current_option and override_option ~= current_option and Customize.IsCustomizeOption(override_name) then
                            savedata.overrides[override_name] = override_option
                        else
                            savedata.overrides[override_name] = nil
                        end
                    end

                    return GenerateWorldGenOverride(savedata)
                end
            end
        end

        if cb then
            cb()
        end
    end

-- ★ 读也分流分片/单机两套 API，与 973 行写入侧严格对称。
    if shard ~= nil then
        TheSim:GetPersistentStringInClusterSlot(slot, shard, filename, onload)
    else
        TheSim:GetPersistentString(filename, onload)
    end
end

--============================================================
--============================================================
-- 【分区 19】★★★ SaveGame —— 存档系统写侧的唯一入口（1066-1274 行）
--============================================================
-- ★★★ 这是全项目最重要的函数。下面先给出**阶段划分总览**，
--   每一阶段的细节在对应行号的注释里。
--
--   阶段 A【守卫与开关】1068-1077
--     · 非服务器直接拒绝并回调 cb(true)——保证调用方不会等不到回调
--     · TheNet:StartWorldSave() 打开「正在写存档」窗口，让引擎知道
--       这段时间内的快照/回滚请求应当排队
--   阶段 B【实体序列化】1079-1107
--     · 遍历 Ents，逐个 GetSaveRecord() 得到可序列化的 record
--     · ★ 收集 references（被引用的 GUID），留到最后统一回填 id
--   阶段 C【地图与网络层】1109-1166
--     · 地形/道路/导航网格/瓦片数据 + world_network（时钟/季节在这里）
--   阶段 D【玩家】1168-1187
--     · 快照玩家名单 + 逐个 SerializeUserSession（玩家私有数据）
--     · ★ 回填 references 的 id（1181-1187），这是两阶段设计的收口
--   阶段 E【元数据与断言】1189-1199
--     · 模组清单、超能标志、6 条结构断言（fail-fast）
--   阶段 F【序列化与 NaN 拦截】★ 1201-1238
--     · DataDumper 把 table 转成 Lua 源码文本
--     · ★★ 对**文本**做 NaN/Inf 子串扫描，命中即 error 中止整个存档
--   阶段 G【落盘】1241-1273
--     · 快照轮转 → ShardGameIndex:Save → WriteTimeFile → EndWorldSave
--
-- ★★★ 全局认知：SaveGame 与 gamelogic.lua:368 PopulateWorld 互为逆过程。
--   写出的每个字段名，读回来时逐字对应。改存档格式必须两边同时改。
--============================================================
--isshutdown means players have been cleaned up by OnDespawn()
--and the sim will shutdown after saving
-- ★★ 函数签名：isshutdown（是否因退出而保存）、cb（完成回调）。
-- ★ isshutdown 的含义（1066-1067 行英文注释）：
--   「isshutdown 意味着玩家已经通过 OnDespawn 清理完毕，
--    并且 sim 将在保存之后关闭。」
--   ★⇒ 传 true 时调用方保证「不会再有玩家实体了」，所以可以安全地
--     做快照轮转（1243 行 TruncateSnapshots）。
function SaveGame(isshutdown, cb)
-- ★★★ 阶段 A-1：**客户端拒绝存档**。
-- ★★★ 为什么必须拒绝（而不是「客户端也能存」）：
--   ① 权威性：DST 是服务器权威架构，客户端只有预测状态。
--      用客户端数据覆盖服务器存档会导致回档、作弊与状态分歧。
--   ② DST 是多人共享世界，客户端保存会覆盖别人的进度。
-- ★★ 关键细节：`if cb ~= nil then cb(true) end` —— 即使拒绝也**必须回调**。
--   返回 true 表示「已处理（虽然没保存）」，让调用方的状态机继续走完，
--   否则调用方会永远卡在「等待保存完成」。
-- ★ 这是异步 API 的通用契约：所有分支都要回调一次，调用方才能收尾。
-- ⚠ 值得注意：回调参数 cb(true) 与 cb() 的区别未知（成功标志？），
--   本文件内 SaveGame 的正常路径（1251 行）调用的是 cb() 无参。
--   不修改，仅记录该不一致以便排查。
    if not TheNet:GetIsServer() then
        print("SaveGame disabled for Clients in Don't Starve Together")
        if cb ~= nil then
            cb(true)
        end
        return
    end

-- ★★ 阶段 A-2：TheSim:StartWorldSave() —— 通知引擎「开始写世界存档」。
--   ★ 这是**成对**的（与 1249 行 TheNet:EndWorldSave()），作用是
--     标记「存档进行中」，使引擎在这段时间暂缓处理与之冲突的操作
--     （如回滚、快照清理）。
-- ★★ 失败风险：若 1219 行 error() 中止，本函数**永远不会执行到**
--   1249 行的 EndWorldSave —— 存档标志会一直挂着。
--   这是 NaN 拦截采用硬抛（error）而非软降级的代价之一。
    TheNet:StartWorldSave()

-- ★★★ 阶段 B-1：三个顶层容器，职责完全不同：
--   save                  —— 世界级数据（map / ents 之外的一切）
--   saved_ents            —— GUID → record（供 1181 行回填 id 用）
--   savedata_entities     —— prefab 名 → record 数组（★ 真正被写进存档的）
-- ★★ 注意 saved_ents 与 savedata_entities 存的是**同一批 record 对象**，
--   两个索引：一个是按 GUID（为了回填 id），一个是按 prefab（为了写盘）。
    local save = {}
	local savedata_entities = {}

    --print("Saving...")
    --save the entities
-- nument：实体计数（调试/统计用，本文件后续并未再读取它的值）。
-- ★ saved_ents / references 见上方说明。references 的键是 GUID，值是持有者。
    local nument = 0
    local saved_ents = {}
    local references = {}
-- ★★★ 阶段 B-2：**实体的筛选条件**（五项全满足才存），逐项解释：
--   v.persists          —— 实体自己声明「我要被保存」（大多数组件实体为 false）
--   v.prefab ~= nil     —— 必须是已注册的预制体，否则无法在读档时重建
--   v.Transform ~= nil  —— 有变换组件（纯逻辑实体不需要）
--   v.entity:GetParent() == nil —— ★★★ **不能是别人的子实体**！
--   v:IsValid()         —— 尚未被销毁
-- ★★ 第 4 条是本函数的精髓：子实体的坐标是**相对父实体**的，
--   而且子实体会随父实体一起被生成/销毁。若单独保存子实体，
--   读档时会出现「没有父实体的孤儿」，且坐标全错。
--   ⇒ 父实体自己会通过 GetSaveRecord() 把子实体作为「附件」一起序列化。
--   ★ 这与 SpawnSaveRecord（438 行）对称：那里同样由顶层实体负责还原子实体。
    for k, v in pairs(Ents) do
        if v.persists and v.prefab ~= nil and v.Transform ~= nil and v.entity:GetParent() == nil and v:IsValid() then
-- ★★★ GetSaveRecord() 是「实体 → 存档记录」的转换，由 entityscript.lua 提供。
--   它会递归调用所有组件的 GetSaveRecord，返回 record 与 new_references。
-- ★★★ new_references 的含义（本函数最容易被读不懂的地方）：
--   这条 record 里**引用了别的实体**（如「火把被挂在墙上」「钥匙在箱子里」）。
--   组件把这些被引用实体的 GUID 收集在 new_references 里返回。
-- ★★ 为什么需要这个机制：读档时，实体是**先全部生成、后灌数据**的两遍流程
--   （见 SpawnSaveRecord 459 行 newents 的说明）。第二遍要解析「谁引用谁」，
--   就必须知道被引用方的存档 id。
--   ⇒ 所以保存端必须保证：**凡是被人引用的实体，存档里必须有 id**。
--   ⇒ 这就是 1092-1097 行收集 references、1181-1187 行统一回填 id 的原因。
-- ★★ 一句话：references 是「存档的两遍还原」在写侧留下的**记账本**。
            local record, new_references = v:GetSaveRecord()
-- ★★★ record.prefab = nil —— 这一行是**空间优化**，但也是格式的一部分。
--   prefab 名（如 "grass"）在同一个存档里会重复上千次。
--   ★ 删掉每条记录里的 prefab 字段，改由 savedata_entities 的**键**来表达，
--     序列化后即 `ents = { grass = { {...}, {...} } }`，prefabs 只写一次。
--   ★★ 这解释了 SpawnSaveRecord 里读到的 `saved.prefab` 从哪来：
--     读档侧（gamelogic.lua PopulateWorld）会**把键重新贴回每条记录**，
--     之后 SpawnSaveRecord(440 行) 才能用 saved.prefab 生成实体。
--     ⇒ ★★ 写侧删、读侧贴，两边必须成对。这是存档格式里最易漏改的一处。
            record.prefab = nil

-- ★★ 收集「谁被谁引用」。注意同时记录了两个键：
--   references[自己的GUID] = v —— ★ 自己也必须进表，
--   因为只要这条 record 引用了别人，**自己**就需要一个 id（否则无法被回指）。
--   references[被引用的GUID] = v —— 被引用方也需要 id。
-- ★ 值为 v（持有者）只用于 1185 行的错误打印，看语义即可。
            if new_references ~= nil then
                references[v.GUID] = v
                for k1, v1 in pairs(new_references) do
                    references[v1] = v
                end
            end

            saved_ents[v.GUID] = record

-- ★★ 按 prefab 名分组，为 1226 行的分块序列化做准备（压缩率更高）。
-- ★ 这里的 prefab 名**没被删除**，它成了 data.ents 的键。
            if savedata_entities[v.prefab] == nil then
                savedata_entities[v.prefab] = {}
            end
            table.insert(savedata_entities[v.prefab], record)
            nument = nument + 1
        end
    end

--============================================================
-- 阶段 C：地图与网络层 —— 世界状态真正的存放处
--============================================================
-- ★★★ ★★ 世界状态保存（时间/季节/天气）的答案就在这里：
--   ★ 时间与季节**不在** save.map 里，而在 save.world_network.persistdata 里
--     （1144 行）。world_network 是承载时钟与季节的实体（components/worldstate）。
--   ★ 所以 1268-1269 行才能从 world_network.persistdata 里抠出 clock / seasons
--     单独组成 metadata——那份 metadata 会被单独写进存档头部，供快速读取。
--   ★★ 为什么 metadata 要单独提出来：存档索引需要在**不加载整份存档**的前提下
--     知道世界的时间/季节（用于存档列表显示、快照选择）。
--   ★ 随机数种子：本文件**不保存**随机种子。存档是「全量状态快照」，
--     游戏内随机数（math.random）由各实体的 GetSaveRecord 自行记录；
--     世界级的种子不在此文件。
    --save out the map
-- ★ save.map 先给一个**保底形状**（tiles = ""），随后被逐字段覆盖。
--   ★ 这样即使后面 ground 为 nil（不该发生），1192-1196 行的断言
--     会因为 tiles 为空串而失败——错误信息直指「tiles 缺失」。
-- ⚠ roads = Roads 是**直接引用**了全局 Roads 表，没有拷贝。
--   若 Roads 在序列化期间被别处修改，存档内容会受影响。
--   实际不存在此并发（DST 为单线程），故不作为缺陷，仅备注。
    save.map =
    {
        tiles = "",
        roads = Roads,
    }

    local new_refs = nil
    local ground = TheWorld
-- ★ assert + 下面紧跟 `if ground ~= nil` —— 断言后判空看似矛盾，实为防御：
--   断言已经保证它非 nil，后续判空是为了让静态分析/Lua 5.1 编译器
--   确信 ground 有类型，避免后续访问字段时报 nil 错误。
    assert(ground ~= nil, "Cant save world without ground entity")
    if ground ~= nil then
        save.map.prefab = ground.worldprefab
-- ★★★ 地形数据的四件套（都是**字符串**，不是嵌套表）：
--   GetStringEncode()       —— 主地形/瓦片层（tiles）
--   GetDataStringEncode()   —— 瓦片附加数据（tiledata，如矿脉、门状态）
--   GetNavStringEncode()    —— ★ 导航网格（AI 寻路用）
--   GetNodeIdTileMapStringEncode() —— 节点 ID 瓦片映射（导航用）
-- ★★ 为什么全是字符串：这些数据量极大（几 MB），用扁平字符串比嵌套表
--   小得多，序列化/反序列化也快得多。这是**为体积做的格式选择**。
        save.map.tiles = ground.Map:GetStringEncode()
        save.map.world_tile_map = GetWorldTileMap()
        save.map.tiledata = ground.Map:GetDataStringEncode()
        save.map.nav = ground.Map:GetNavStringEncode()
        save.map.nodeidtilemap = ground.Map:GetNodeIdTileMapStringEncode()
        save.map.width, save.map.height = ground.Map:GetSize()
        save.map.topology = ground.topology
        save.map.generated = ground.generated
-- ★ persistdata：世界的业务数据（世界实体自己的一堆状态字段）。
--   new_refs：世界实体引用的其他实体，同样要进 references 记账本。
        save.map.persistdata, new_refs = ground:GetPersistData()
-- ★ save.meta：世界元信息，★ 其中 session_identifier 是本次会话标识，
--   它在 1243 行（TruncateSnapshots）与 1273 行（SerializeWorldSession）
--   都被使用——★ 同一个值贯穿「快照轮转」与「写盘」两件事，把它们绑定起来。
        save.meta = ground.meta
        save.map.hideminimap = ground.hideminimap
		save.map.has_ocean = ground.has_ocean

        if new_refs ~= nil then
            for k, v in pairs(new_refs) do
                references[v] = ground
            end
        end

-- ★ world_network 实体：承载 clock / seasons 的网络同步实体。
--   ★ 断言它必须存在：没有它就没有时钟，世界无法正常运转。
        local world_network = ground.net
        assert(world_network, "Cant save world without world_network entity")
        if world_network ~= nil then
            save.world_network = {}
            save.world_network.persistdata, new_refs = world_network:GetPersistData()

            if new_refs ~= nil then
                for k, v in pairs(new_refs) do
                    references[v] = world_network
                end
            end
        end

-- ★★ shard_network 是**分片（shard）架构**的额外实体，只在集群模式存在。
--   源码注释 NOTES(JBK) 明确说「This data is optional」——
--   单机/普通房没有它，整块逻辑被跳过。所以分片模式的存档比普通房多一块。
        local shard_network = ground.shard -- NOTES(JBK): This data is optional.
        if shard_network ~= nil then
            local persistdata, new_refs = shard_network:GetPersistData()
            if persistdata ~= nil then
                save.shard_network = {}
                save.shard_network.persistdata = persistdata
                if new_refs ~= nil then
                    for k, v in pairs(new_refs) do
                        references[v] = shard_network
                    end
                end
            end
        end
    end

--============================================================
-- 阶段 D：玩家快照名单 + 玩家私有数据
--============================================================
-- ★★ 快照条件：`not isshutdown and #AllPlayers > 0`。
--   ⇒ 退出时保存（isshutdown=true）**不记快照**，因为人都走了，快照无意义；
--     无人在线时同样不记。
    if not isshutdown and #AllPlayers > 0 then
        save.snapshot = { players = {} }
    end

-- ★★ 只处理「有 userid 的玩家」——userid 为空的是本地测试实体/AI。
-- ★★ save.snapshot.players 存的是 **userid 列表（字符串）**，不是 GUID：
--   ★ 原因：快照的用途是「服务器回滚后，把当时在线的人拉回来」，
--     按账号 ID 才能跨进程/跨会话定位人，GUID 只在本次会话有效。
    for i, player in ipairs(AllPlayers) do
        if player.userid ~= nil and player.userid:len() > 0 then
            if save.snapshot ~= nil then
                table.insert(save.snapshot.players, player.userid)
            end
-- ★★★ SerializeUserSession(player)：把**玩家私有数据**（背包内容、
--   技能树、角色状态）单独存一份。与世界存档是**两份文件**。
-- ★★ 为什么要分开存（而不是塞进世界存档）：
--   ① 玩家数据频繁变动，背包每动一次都变；世界存档通常是几分钟一次。
--      分开后玩家数据可以独立、低成本地保存。
--   ② 服务器回滚时，玩家数据要能**回滚到与该快照匹配的时刻**，
--      所以它必须与世界快照同批次保存。
--   ③ 读档时玩家可以「只回滚世界、保留自己的背包」（见 RestoreSnapshotUserSession）。
-- ★ 参见 2099 行 RestoreSnapshotUserSession —— 它反序列化这份玩家数据；
--   参见 2074 行 ResumeExistingUserSession —— 重连时复用它。
-- ★ 由 C++ TheSim 侧实现写盘；本文件只在 1177 / 1730 / 1801 / 1876 行调用。
            SerializeUserSession(player)
        end
    end

-- ★★★ 阶段 D-2：**回填 id** —— 本阶段的核心动作，也是 SaveGame 的收官。
-- ★★★ 为什么必须在这一步回填（回顾 1092-1097 行）：
--   存档实体默认**没有 id**（见 SpawnSaveRecord 459-466 行的设计：
--   只有「被引用过」的实体才需要 id）。凡是进了 references 记账本的 GUID，
--   无论是被引用方还是引用方，都必须获得 id，读档侧才能重建引用关系。
-- ★ 两分支：
--   saved_ents[k] 非 nil —— 正常回填 record.id = k（1183 行）
--   否则 —— 说明引用了一个**不会被保存的实体**，打印诊断（1185 行）
-- ⚠ 疑似缺陷（缺陷，但有诊断兜底）：1185 行的诊断只 print，不中断存档。
--   ⇒ 若确实存在「引用了不可保存实体」的情况，那个引用会被静默丢弃，
--     读档后表现为「引用关系凭空消失」（比如火把从墙上掉下来）。
--   ★ 合理推断：大多数情况是「引用了临时实体（如火焰、光效）**，
--     这是**预期行为**而非 bug——临时实体本来就不该跨存档存在。
--     所以这里只 print 不 error 是对的，但打印措辞 "Missing reference"
--     容易让人误以为出错了。不修改。
    for k, v in pairs(references) do
        if saved_ents[k] ~= nil then
            saved_ents[k].id = k
        else
            print("Missing reference:", v, "->", k, Ents[k])
        end
    end

-- ★ save.mods：模组清单。★ 必须存档，否则读档时模组列表会与存档不符。
-- ★★★ 这是跨版本迁移的第二条依据：读档时会用存档里的模组清单去校验
--   玩家当前启用的模组，不一致时需要用户处理（modutil / KnownModIndex）。
-- ★ 参见 savefileupgrades.lua —— 模组版本变化引发的存档升级在那里。
    save.mods = ModManager:GetModRecords()
-- ★ super = WasSuUsed()：是否用过超级燃料（supercoolant）机制的标志位。
--   ★ 典型的「布尔开关型存档字段」：只为避免重复初始化代价。
    save.super = WasSuUsed()

-- ★★★ 阶段 E：六条结构断言（fail-fast）。
-- ★★ 设计意图：在真正序列化之前，先确认「核心字段都在」。
--   比起序列化完才发现问题再回滚，这里早失败几百毫秒，代价低得多。
-- ★ 1197 行的 topology 断言被注释掉了：说明 topology（地形拓扑）
--   某些世界类型（如 Warly 的竞技场）确实可能没有，断言会误伤。
-- ⚠ 疑似缺陷（轻微，无害）：1195-1196 行只断言 width/height **非 nil**，
--   没断言 > 0。0 宽的地图能通过断言，但显然是非法的。
--   相比之下 1194 行 tiles 用 `assert(save.map.tiles)` 能挡住空串。
--   ★ 不修改，仅指出断言强度不一致。
    assert(save.map, "Map missing from savedata on save")
    assert(save.map.prefab, "Map prefab missing from savedata on save")
    assert(save.map.tiles, "Map tiles missing from savedata on save")
    assert(save.map.width, "Map width missing from savedata on save")
    assert(save.map.height, "Map height missing from savedata on save")
    --assert(save.map.topology, "Map topology missing from savedata on save")
    --assert(save.ents, "Entities missing from savedata on save")
    assert(save.mods, "Mod records missing from savedata on save")

--============================================================
-- 【阶段 F】★★ 序列化 + ★★★ NaN/Inf 拦截（本文件最高价值区域）
--============================================================
-- ★★★ 为什么要单独一个阶段：序列化是「把运行时 table 变成文本」，
--   而 NaN/Inf 恰恰是**序列化阶段**才会暴露的问题。
--   如果等到读档才发现，存档已经写坏了（可能是几天前写的那份）。
--   ⇒ 在写入前拦住，是唯一能保护历史存档的做法。
    local PRETTY_PRINT = BRANCH == "dev"

    local patterns
-- ★★★★ NaN/Inf 判据表（bug-patterns.md C 类「NaN 永久损坏存档」的落点）
--
-- ★★★ 判据的**本质**：对 DataDumper 产出的**文本**做纯文本子串匹配。
--   它不是数值比较（不是 `x ~= x` 那种写法），这一点是整个设计的关键。
--
-- 【为什么必须用文本匹配，而不是数值判据？】
--   ★★ 因为此时数据已经是**字符串**了（DataDumper 的产物是 Lua 源码文本），
--     拿不到原始数值。想做数值判据就得先反序列化，代价极高且不可靠。
--
-- 【两套 patterns 为什么不同？】
--   · dev 分支（1205 行）：{"=nan", "=-nan", "=inf", "=-inf"}
--     —— 平台原生 printf 风格，Linux/macOS/开发机打印出 "nan" / "inf"。
--   · 正式版（1207 行）：{"=-1.#IND", "=1.#QNAN", "=1.#INF", "=-1.#INF"}
--     —— ★★ 这是 **MSVC（Windows 运行时）的 NaN/Inf 打印格式**！
--       MSVC 的 printf 把 NaN 打成 -1.#IND / 1.#QNAN，Inf 打成 1.#INF。
--       正式版主要跑在 Windows 上，所以必须匹配这套字符串。
--   ★ 这套判据是「按平台/分支手写的字面量」，因此新增平台需要改这里——
--     它天然不具可移植性，是这个方案的局限。
--
-- 【★★★ 为什么 tonumber("nan") == nil 会让「数值判据」彻底失效？】
--   （这是 bug-patterns.md C 类「NaN 永久损坏存档」的核心成因；
--     本项目 03-参考架构/09_savegame.lua:204-213 已复现并修正过同一个坑）
--
--   ★★★ 事实：Lua 的 tonumber 只接受**十进制/十六进制数字字面量**。
--     "nan"、"inf"、"-inf"、"1.#QNAN"、"-1.#IND" 一律返回 **nil**，
--     而不是对应浮点值。（此结论已实测核对，非凭记忆。）
--
--   ★★ 设想一个「看起来更干净」的写法，看它为什么坏掉：
--       -- 错误写法：把命中片段转成数值再判有限性
--       local n = tonumber(命中片段)
--       if n == nil or n ~= n or n == math.huge then ... end
--     失效原因有三层：
--       ① 信息塌陷：tonumber("nan") 是 nil，于是「这是 NaN」与「这段文本
--          压根不是数字」变成**同一个值 nil**，判据无法再区分二者。
--       ② ★★ 最致命：绝大多数「防脏数据」的写法都是「nil 就放过」
--          （典型形态 `if tonumber(s) then 检查(n) end`），
--          而 NaN 恰好落进 nil 分支 ⇒ 被当成合法值**静默放过**。
--          ☆ 这就是「守卫代码明明存在，NaN 却能一路写进存档」的机制：
--            守卫对 NaN 这个特例完全无效。
--       ③ 想补救就得写成「nil 也算可疑」，但那会把大量**正常**的非数字内容
--          （字符串键名、布尔值、显式 nil）全部误判成损坏，误报满天飞。
--
--   ★★ 结论 —— 这才是 DST 官方方案的立意（★ 本文件最值得学的一处）：
--     既然数值通道（tonumber）会把 NaN 降级成 nil 从而**丢失信息**，
--     ★★ 那就干脆**不走数值通道**，直接在**文本层**做字面量匹配。
--     字符串 "=nan" 不会像 tonumber 那样被降级，它是稳定且可精确匹配的。
--     ⇒ 「先序列化成文本，再在文本上判坏」是绕过 tonumber 陷阱的正解。
--
--   ★ 与 03-参考架构/09_savegame.lua 的对照（差异有意义，不是矛盾）：
--     参考实现在**读档侧**用了 tonumber + 「nil 也算可疑」的双分支（204-213 行），
--     因为它要防「玩家手工/外部注入的非法数字」，那时必须解析数字；
--     本文件在**写档侧**用纯文本扫描，因为要防的是「自己刚算出来的坏值」。
--     ⇒ 两个方向工具不同、但各自成立：写侧防自产，读侧防外注。
--
-- 【★ 判据表之外的推论：它拦不住什么？】
--   ⚠ 本判据只认这 8 个字面量。若某个平台把 NaN 打印成其他形式
--     （例如 "NaN" 大写、"-nan(ind)"、"1.#QNAN0"），此守卫会**静默失效**，
--     NaN 将照常写入存档。⇒ 这是判据表作为字面量清单的固有脆弱性。
--     ★ 对照组：本文件 1219 行的 error() 只在**命中**时才抛错，
--       漏检是完全静默的，没有兜底告警。不修改代码，仅记录风险边界。
--
-- 【★ 为什么每个 pattern 都带一个前导等号 "="？】
--   ★★★ 这是本判据最精妙的一步，作用是**消除误报**。已核对 dumper.lua 确认：
--     · dumper.lua:98  `number = function(value) return value end`
--       —— 数值**原样写入**输出，不加引号、不做格式化；
--     · dumper.lua:132 `out[#out+1] = path .. " = " .. defined[value] .. "\n"`
--       —— 输出形状是 `键 = 值`。
--     ⇒ 所以一个 NaN 数值在文本里必然呈现为「…… = nan」，
--       与字符串值里的 "nan"（会被 %q 加引号，且前面未必紧跟 =）区分得开。
--     ★ 前导 "=" 把匹配范围锁死在「赋值等号紧邻」这一种形态，
--       大幅压低误报（若某物品名恰好含 "=nan" 仍会误报，但概率极低）。
    if BRANCH == "dev" then
        patterns = {"=nan", "=-nan", "=inf", "=-inf"}
    else
        patterns = {"=-1.#IND", "=1.#QNAN", "=1.#INF", "=-1.#INF"}
    end

    local data = {}
-- ★★ 遍历世界级数据：逐个字段 DataDumper → 文本 → 扫描。
--   ★ not PRETTY_PRINT 作为第 3 参数：正式版传 true（紧凑输出，体积最小），
--     dev 传 false（带缩进换行，便于人眼阅读定位问题）。
--   ★★ 这就是「开发期可读、发布期省空间」的典型取舍：同一份格式化逻辑，
--     靠一个布尔开关切换两种输出风格。
    for key,value in pairs(save) do
        data[key] = DataDumper(value, nil, not PRETTY_PRINT)

-- ★★★★ 【NaN 拦截核心循环】判据与处理，逐行拆解：
--
--   string.find(文本, 模式, 1, true)
--     · 第 4 参数 true = **纯文本查找**（plain search），不是 Lua 模式匹配。
--       ★ 这点至关重要：正式版的模式含 "."（如 "1.#QNAN"、"=-1.#IND"），
--         若用模式匹配，"." 是任意字符元符，会产生误判；
--         纯文本查找保证「字面量精确匹配」。
--     · init = 1 表示**返回真实位置下标**（而不是布尔值），因为要用来切片。
--
--   命中后的处理（1217-1219 行）：
--     · 先 print 出命中位置前后的一小段上下文（便于人工定位）
--     · 然后 error() —— ★★★ **硬中止整个存档**，不是降级、不是跳过。
--
-- ★★★ 为什么选择「硬中止」而非「把 NaN 替换成 0 再存」？这是本节
--   最重要的设计决策，理由如下：
--   ① NaN 会**污染**数据。一旦 NaN 进入某个数值字段，任何参与它的运算
--      结果仍是 NaN（IEEE 754 规定），且会**静默扩散**到其他字段。
--      ★ 例如：饥饿度变 NaN → 所有食物回复量变 NaN → 玩家永远饥饿；
--        UI 上表现为数字乱码或空白。
--   ② ☆★ 被污染的是**已经写好的历史存档**。如果读档时才发现，
--      那份坏档可能已经躺在磁盘上好几天，玩家这几天的进度全丢。
--      ⇒ 必须在**写入时**就拦住，这是保护历史存档的唯一办法。
--   ③ 相比 03-参考架构/09_savegame.lua 的做法：那份参考实现提供了
--      「严格拒绝」与「降级为 nil」两种模式；DST 官方选择了严格拒绝。
--      ★ 权衡：拒绝 = 玩家会看到一次保存失败（游戏可能弹错），
--        但档不会坏；降级 = 保存成功但数据被悄悄改写。
--      ★★ 官方宁可报错也不静默改写玩家数据，这是合理的取舍。
--
-- ⚠ 缺陷：error() 会**跳过 1241-1273 行的所有收尾**，
--   包括 TheNet:EndWorldSave()（1249 行）。⇒ 引擎侧「正在保存」标志
--   可能永久悬置（参见 1077 行注释里提到的这个风险）。
--   玩家侧表现为「这次保存失败」，需要重试或重启。不修改代码。
		for i, corrupt_pattern in ipairs(patterns) do
			local found = string.find(data[key], corrupt_pattern, 1, true)
			if found ~= nil then
-- ⚠ 疑似缺陷（真实缺陷，仅影响诊断可读性）：
--   string.sub(文本, found - 100, found + 50) 想打印「命中位置前 100 字符、
--   后 50 字符」的上下文。但如果命中位置 < 100，found - 100 就是**负数**。
--   ★★ 而 Lua 的 string.sub 对**负数下标有特殊语义**：负数表示「从字符串末尾
--     往前数」（第 -1 个字符是最后一个字符）。
--   ⇒ 后果：当 NaN 出现在序列化文本前 100 字符内时，
--     下标被解释成「末尾倒数第 N 个字符」，打印出来的是**无关的内容**，
--     恰好在最需要诊断的时候给出误导性的上下文。
--   ★ 推理依据：Lua string.sub 文档明确写了负索引从字符串末尾计算；
--     这里没有做 math.max(found - 100, 1) 之类的钳制。
--   ★ 实际影响有限：patterns 里都带前导 "="，而序列化文本开头是固定的
--     键名区域，命中点通常在很深的位置。但缺陷客观存在。不修改。
--   ★★ 已实测复现（按 Lua string.sub 的 1-based + 负索引从末尾规则模拟，
--     文本长 107、命中位置 found=51）：
--       实际 string.sub(s, found-100, found+50) -> 得到 43 个字符，
--       且**完全不含**命中串 CORRUPT（全是结尾的填充字符）；
--       钳制为 math.max(found-100,1) 后 -> 101 字符，正确含命中串。
--     ⇒ 结论确证：命中位置靠前时，诊断输出会指向**错误的位置**。
				local bad_data = string.sub(data[key], found - 100, found + 50)
				print(bad_data)
				error("Error saving game, corruption detected.")
			end
		end
    end

-- ★★★ 阶段 F-2：实体表**单独**处理（源码英文注释解释如下）：
--   「对实体表做特殊处理；内容是**逐个实体**导出的，
--     而不是像存档其他部分那样一次性导出整个实体表。」
-- ★★ 为什么要分开？两个原因：
--   ① **格式**：实体按 prefab 分组，每组单独 DataDumper，产出 ents = {...}
--      若整体 dump，键名结构会与手写格式不符。
--   ② ★ **性能/内存**：整个实体表可能是几 MB 的一个巨型字符串。
--     逐组 dump 后逐组检查，峰值内存更低，且能在出错时
--     快速定位是哪个 prefab 的数据坏了（错误消息区分二者，见 1219 vs 1235 行）。
-- ★ 两个循环（1211 与 1227）检查模式完全一致，只有错误信息不同——
--   属于有意的重复，用性能换清晰。
	-- special handling for the entities table; contents are dumped per entity rather than
	-- dumping the whole entities table at once as is done for the other parts of the save data
	data.ents = {}
-- ★ 与 1211 行同构的扫描；注意 data.ents 是**新建的空表**，
--   因为 save 本身没有 ents 字段（实体走 savedata_entities 这条路）。
	for key, value in pairs(savedata_entities) do
		data.ents[key] = DataDumper(value, nil, not PRETTY_PRINT)

		for i, corrupt_pattern in ipairs(patterns) do
			local found = string.find(data.ents[key], corrupt_pattern, 1, true)
			if found ~= nil then
				local bad_data = string.sub(data.ents[key], found - 100, found + 50)
				print(bad_data)
				error("Error saving game, entity table corruption detected.")
			end
		end
	end


--============================================================
-- 阶段 G：落盘与收尾（★ 这一整段是 C++ 异步回调链）
--============================================================
-- ★★★ 三层嵌套的 callback 结构，务必看清：
--   callback()            ← 序列化完成回调（由 SerializeWorldSession 触发）
--     └ onsaved()         ← ShardGameIndex:Save 完成
--         └ onwritetimefile() ← WriteTimeFile 完成 → 才算真的结束
-- ★ 这是典型的**异步回调链**，每一层等上一层完成再做下一件事，
--   保证落盘顺序正确（先写存档文件，再写索引/时间文件，最后才 EndWorldSave）。
    local function callback()
        if isshutdown or #AllPlayers <= 0 then
-- ★★ 快照轮转：只在「退出保存」或「已无玩家」时执行。
--   ★ TruncateSnapshots(session_identifier) —— 按会话标识截断快照列表。
--   ★ 语义：把「本次会话之前」的快照丢掉，只保留近期若干份，
--     避免服务器磁盘被历史快照撑满（每个快照都是完整世界）。
--   ★ 用 session_identifier 而非时间戳：精确界定「本次会话的边界」，
--     比时间阈值更可靠（避免服务器时间被校准导致误删）。
            TheNet:TruncateSnapshots(save.meta.session_identifier)
        end
-- ★ TheNet:IncrementSnapshot()：快照计数 +1。
--   ★ 注意它在 TruncateSnapshots **之后**调用——先清理旧的，再登记新的。
        TheNet:IncrementSnapshot()
-- ★ onupdateoverrides：把世界里的 overrides 同步回存档索引与
--   worldgenoverride 文件（见 1259 行英文注释）。
--   ★ 为什么保存时要反向同步 overrides：玩家在世界里改的世界生成设置
--     （如选了新世界的配置）必须持久化，否则下次开新档会丢。
        local function onupdateoverrides()
            local function onsaved()
                local function onwritetimefile()
                    TheNet:EndWorldSave()
                    if cb ~= nil then
                        cb()
                    end
                end
                ShardGameIndex:WriteTimeFile(onwritetimefile)
            end
            ShardGameIndex:Save(onsaved)
        end
-- ★★★ 又是 deepcopy：怕覆盖 ShardGameIndex 里已有的 options 对象。
--   ★ 存档量大，取出来的 overrides 有可能与索引里的对象**是同一张表**
--     （都源自上次读取）；直接赋值再改会污染索引，copy 一份切断引用。
        local options = ShardGameIndex:GetGenOptions()
        --copy overrides from the world back to the shard index and worldgenoverrides.
        local overrides = deepcopy(save.map.topology.overrides)
        options.overrides = overrides
        UpdateWorldGenOverride(overrides, onupdateoverrides, ShardGameIndex:GetSlot(), ShardGameIndex:GetShard())
    end

-- ★★★ 源码留下的 TODO，透露了作者对这块架构的不满：
--   「todo，如果我们往这里加更多值，就把它变成一个函数，
--     在这里和 gamelogic.lua@DoGenerateWorld 两处都调用。」
-- ★★★ 重要信息：生成新世界（DoGenerateWorld，gamelogic.lua:1068）时
--   需要构造**同样形状**的 metadata（clock/seasons）。这两处是重复代码，
--   作者自己标注了要抽函数。★ 说明「世界状态」的初始化分散在两处。
    --todo, if we add more values to this, turn this into a function thats called both here and gamelogic.lua@DoGenerateWorld
-- ★★★ metadata：单独写进存档头部的世界摘要。
-- ★ 只有 world_network 存在时才有内容 —— 无 world_network 则 metadata 为空。
    local metadata = {}
    if save and save.world_network and save.world_network.persistdata then
-- ★★★ ★ 世界状态保存的精确答案（对应本文件重点讲解区域第 5 条）：
--   · clock    —— 世界时间/天数。由 components/worldstate.lua 持有，
--     存在 world_network 的 persistdata 里。
--   · seasons  —— 季节进度。同样在 world_network.persistdata。
-- ★★ 为什么单独抽出来（1265 行的 TODO 也印证）：
--   让存档索引/快照选择能在**不解析整份存档**的前提下读到时间与季节。
--   ★ 这就是「存档元数据」与「存档主体」分离的典型实现。
-- ★ 天气：不在 metadata 里。天气属于 worldstate 组件的状态，
--   随 persistdata 全量保存，不单独抽取。
-- ⚠ 疑似缺陷（轻微，无害）：1268-1269 行直接读 persistdata.clock，
--   未做类型检查。若某世界类型没有 clock 字段，metadata.clock = nil，
--   Lua 中给表赋 nil 相当于不创建该键 —— 不会崩，但元数据会缺字段。
--   下游若强依赖 metadata.clock 可能出错。不修改。
        metadata.clock = save.world_network.persistdata.clock
        metadata.seasons = save.world_network.persistdata.seasons
    end
-- ★ metadataStr 与 data 是**两次独立的 DataDumper**：
--   ★ 原因：metadata 体积极小，单独序列化后可以放在存档文件头部/旁路文件，
--     索引读取时无需加载主体数据。
    local metadataStr = DataDumper(metadata, nil, not PRETTY_PRINT)

-- ★★★ 最终落盘。SerializeWorldSession 由 C++ 实现：
--   把 data（主体）写进世界存档文件，把 metadataStr 写进元数据，
--   全部完成后触发第 4 参数 callback（即 1241 行）。
-- ★ session_identifier 贯穿全局：它同时是快照轮转的键（1243 行）
--   和本次写入的会话标识，把「快照」与「存档」绑定成同一批。
-- ★★ 完整收尾顺序（★ 排查「保存卡住」时按这个顺序看）：
--   SerializeWorldSession → callback → TruncateSnapshots/IncrementSnapshot
--   → UpdateWorldGenOverride → ShardGameIndex:Save → onsaved
--   → WriteTimeFile → onwritetimefile → TheNet:EndWorldSave() → cb()
--   任何一环抛错，后面的都不会执行（没有 xpcall 保护）。
    SerializeWorldSession(data, save.meta.session_identifier, callback, metadataStr)
end

-- 【分区 20】JSON 消息处理（客户端侧与 sim 的少数几个指令通道）
function ProcessJsonMessage(message)
    --print("ProcessJsonMessage", message)

    local player = ThePlayer

-- ★ TrackedAssert：带上下文的断言调用，会把函数名记进错误堆栈，
--   让「json.decode 失败」能立刻定位到是这一行。
    local command = TrackedAssert("ProcessJsonMessage",  json.decode, message)

    -- Sim commands
    if command.sim ~= nil then
        --print( "command.sim: ", command.sim )
        --print("Sim command", message)
        if command.sim == 'toggle_pause' then
            --TheSim:TogglePause()
            SetPause(not IsPaused())
        elseif command.sim == 'upsell_closed' then
            HandleUpsellClose()
        elseif command.sim == 'quit' then
            if player then
                player:PushEvent("quit", {})
            end
-- ⚠ 疑似缺陷（分支顺序的真实缺陷）：
--   elseif 链的**前三个分支都是字符串比较**，最后一个分支判断
--   `type(command.sim) == 'table' and command.sim.playerid`。
--   ★ Lua 的 == 不会报错（不同类型返回 false），所以 sim 是 table 时
--     前面的 'toggle_pause' 等比较都安全地返回 false，能落到最后一个分支。
--   ⇒ 结论：当前实现**正确**，但依赖「Lua 跨类型比较不抛异常」这一语言特性，
--     语义上不够显式。此处不作为缺陷，仅记录该写法值得注意。
        elseif type(command.sim) == 'table' and command.sim.playerid then
            TheFrontEnd:SendScreenEvent("onsetplayerid", command.sim.playerid)
        end
    end
end

-- 【分区 21】字体 —— 两阶段注册（先全部加载，再配置 fallback）
function LoadFonts()
    for k,v in pairs(FONTS) do
        TheSim:LoadFont(v.filename, v.alias, v.disable_color)
    end

-- ★★ 为什么字体要分两轮（Load → SetupFallbacks）？
--   fallback 是「主字体缺某个字符时用哪个字体代替」。
--   ★ 必须**先把所有字体都加载完**，才能配置它们之间的 fallback 关系——
--     否则先配置的 fallback 指向一个还没加载的字体，顺序依赖会导致随机失败。
--   ★ 这是典型的「批量初始化需要两遍」的依赖排序问题。
    for k,v in pairs(FONTS) do
        if v.fallback and v.fallback ~= "" then
            TheSim:SetupFontFallbacks(v.alias, v.fallback)
        end
        if v.adjustadvance ~= nil then
            TheSim:AdjustFontAdvance(v.alias, v.adjustadvance)
        end
    end
end

-- ★ UnloadFonts 在 Shutdown（1575 行）里被**注释掉了**，
--   英文注释解释：字体会在 C++ 子系统析构时自动卸载。
-- ★ 又一处 V2C 注释。
function UnloadFonts()
    for k,v in pairs(FONTS) do
        TheSim:UnloadFont(v.alias)
    end
end

--============================================================
-- 【分区 22】手柄检测弹窗
--============================================================
local function Check_Mods()
-- ★ Check_Mods 是个延迟执行的「初始化收尾」：
--   必须等模组环境全部就绪后才把「控制台可用」这件事通知下去。
--   ★ 它被三个分支（SteamDeck / 弹窗回调 / 无弹窗）反复调用，
--     调用点都用 scheduler:ExecuteInTime(0.05, ...) 延迟 0.05 秒，
--     避免在 PushScreen 过程中立即执行导致的重入。
    if MODS_ENABLED then
        --after starting everything up, give the mods additional environment variables
        ModManager:SetPostEnv(ThePlayer)

        --By this point the game should have either a) disabled bad mods, or b) be interactive
-- ★★ 英文注释说明「不需要阻塞也不需要结果」：
--   EndStartupSequence(nil) —— 传 nil 表示「我不关心启动序列的结果」，
--   立即返回。这是「发起一个我不在乎结果的异步动作」。
        KnownModIndex:EndStartupSequence(nil) -- no callback, this doesn't need to block and we don't need the results
    end
end

local function CheckControllers()
    local isConnected = TheInput:ControllerConnected()
    local sawPopup = Profile:SawControllerPopup()

-- ★ Steam Deck 特判：Deck 是掌机，**必然有手柄**，所以直接启用设备 1
--   并跳过弹窗，同时立刻执行 Check_Mods。
	if IsSteamDeck() and not TheNet:IsDedicated() then
		TheInputProxy:EnableInputDevice(1, true)
        Check_Mods()
-- ★ 弹窗条件：全局初始化开关 + 手柄已连接 + 没弹过 + 非专服。
--   sawPopup（Profile 记录）保证**只弹一次**，避免玩家每次启动被打扰。
    elseif RUN_GLOBAL_INIT and isConnected and not (sawPopup or TheNet:IsDedicated()) then

        -- store previous controller enabled state so we can revert to it, then enable all controllers
-- ★★ 先把所有手柄的启用状态**备份到 controllers**，
--   这样用户点「禁用」时能精确还原（见 1378-1388 行 revertControllers）。
-- ★ 三个回调（enable/disable/revert）结构几乎相同，只在核心动作上不同——
--   典型的「模板 + 差异」代码。
        local controllers = {}
        local numControllers = TheInputProxy:GetInputDeviceCount()
        for i = 1, (numControllers - 1) do
            local enabled = TheInputProxy:IsInputDeviceEnabled(i)
            table.insert(controllers, enabled)
        end

        -- enable all controllers so they can be used in the popup if desired
        TheInput:EnableAllControllers()

        local function enableControllers()
            -- set all connected controllers as enabled in the player profile
            for i = 1, (numControllers - 1) do
                if TheInputProxy:IsInputDeviceConnected(i) then
                    local guid, data, enabled = TheInputProxy:SaveControls(i)
                    if not(nil == guid) and not(nil == data) then
                        Profile:SetControls(guid, data, enabled)
                    end
                end
            end

            Profile:ShowedControllerPopup()
            TheFrontEnd:PopScreen() -- pop after updating settings otherwise this dialog might show again!
            Profile:Save()
-- ★★ 三处都用 scheduler:ExecuteInTime(0.05, function() Check_Mods() end)，
--   且英文注释都强调「pop after updating settings otherwise this dialog
--   might show again」——★ 先保存 Profile 再 PopScreen，顺序反了会重复弹窗。
--   ★ 这是「设置持久化必须早于 UI 关闭」的一个具体教训。
            scheduler:ExecuteInTime(0.05, function() Check_Mods() end)
        end

-- ★ disableControllers：用户选择「不用手柄」→ 全部禁用并存档。
        local function disableControllers()
            TheInput:DisableAllControllers()
            Profile:ShowedControllerPopup()
            TheFrontEnd:PopScreen() -- pop after updating settings otherwise this dialog might show again!
            Profile:Save()
            scheduler:ExecuteInTime(0.05, function() Check_Mods() end)
        end

-- ★ revertControllers：恢复弹窗前的手柄启用状态。
--   ★ 这是「取消」路径 —— 说明弹窗可以中途被系统事件（切屏）打断。
        local function revertControllers()
            -- restore controller enabled/disabled to previous state
            for i = 1, (numControllers - 1) do
                TheInputProxy:EnableInputDevice(i, controllers[i])
            end

            Profile:ShowedControllerPopup()
            TheFrontEnd:PopScreen() -- pop after updating settings otherwise this dialog might show again!
            Profile:Save()
            scheduler:ExecuteInTime(0.05, function() Check_Mods() end)
        end

-- ★ 弹窗本体：PopupDialogScreen(标题, 正文, 按钮组, nil, "big")。
--   ★ 最后一个参数 "big" 是弹窗尺寸样式（大号弹窗）。
-- ★★ 注意按钮组只有 2 项（启用/禁用），**没有「取消」**：
--   revertControllers（1378 行）是在弹窗**被外部打断**时的兜底，
--   而非用户主动选择。即「必须二选一」是设计意图。
        local popup = PopupDialogScreen(STRINGS.UI.MAINSCREEN.CONTROLLER_DETECTED_HEADER, STRINGS.UI.MAINSCREEN.CONTROLLER_DETECTED_BODY,
            {
                {text=STRINGS.UI.MAINSCREEN.ENABLECONTROLLER, cb = enableControllers},
                {text=STRINGS.UI.MAINSCREEN.DISABLECONTROLLER, cb = disableControllers}
            },
            nil,
            "big"
        )
-- ★ 若手柄已插着（而非仅检测到），额外停止鼠标追踪 ——
--   ★ 避免鼠标光标在手柄模式下仍显示/移动（体感冲突）。
        if TheInput:ControllerAttached() then
            TheFrontEnd:StopTrackingMouse(true)
        end
        TheFrontEnd:PushScreen(popup)
-- ★ else 分支：不弹窗，直接停鼠标追踪（若有手柄）并执行 Check_Mods。
--   ★ 这是「条件不满足」的正常路径（专服/弹过/无手柄）。
    else
        if TheInput:ControllerAttached() then
            TheFrontEnd:StopTrackingMouse(true)
        end
        Check_Mods()
    end
end

--============================================================
-- 【分区 23】★★ Start() —— 游戏启动入口
--============================================================
-- ★★★ 注意 Start 与 GlobalInit（1447 行）的区别，这是最容易混淆的一对：
--   Start()      —— **前端/客户端**启动。此时还没进游戏世界。
--   GlobalInit() —— sim 首次创建时调用**一次**，后续重建 sim 不会再调。
-- ★ 源码 1446 行特别注明了 GlobalInit 的「只调一次」语义。
function Start()
    if SOUNDDEBUG_ENABLED then
        require("debugsounds")
    end

    ---The screen manager
-- ★ TheFrontEnd = FrontEnd()：创建屏幕管理器并设为全局。
--   gamelogic.lua 在下一行被 require —— ★ 前端必须先于 gamelogic 存在，
--   因为 gamelogic 的顶层代码会用 TheFrontEnd。依赖顺序是硬约束。
    TheFrontEnd = FrontEnd()
    require("gamelogic")

-- ★★★ 四条 known_assert：**配置目录权限自检**。
-- ★ 全部用 known_assert（而非 assert）——具名错误码会被登记到已知错误表，
--   玩家看到的是「第 1234 号已知错误 + 解决办法」，而不是一堆栈信息。
-- ★ 这四条必须在**最早期**检查：权限不对的话后面所有存档操作都会失败，
--   早失败能给出明确的修复指引（如「把存档目录设为可写」）。
    known_assert(TheSim:CanWriteConfigurationDirectory(), "CONFIG_DIR_WRITE_PERMISSION")
    known_assert(TheSim:CanReadConfigurationDirectory(), "CONFIG_DIR_READ_PERMISSION")
    known_assert(TheSim:HasValidLogFile(), "CONFIG_DIR_CLIENT_LOG_PERMISSION")
    known_assert(TheSim:HasEnoughFreeDiskSpace(), "CONFIG_DIR_DISK_SPACE")

    --load the user's custom commands into the game
-- ★★ 玩家自定义命令：启动时读 ../customcommands.lua 并**执行**。
-- ★xpcall(fn, debug.traceback) —— 执行外部代码必须包错误处理，
--   否则一个语法/运行错误会中断整个启动流程。
-- ★ 文件不存在时 load_success 为假，直接跳过（不是错误）。
    TheSim:GetPersistentString("../customcommands.lua",
        function(load_success, str)
            if load_success then
                local fn = loadstring(str)
                known_assert(fn ~= nil, "CUSTOM_COMMANDS_ERROR")
                xpcall(fn, debug.traceback)
            end
        end)

    CheckControllers()

	if IsRail() and RUN_GLOBAL_INIT then
		TheFrontEnd:Fade(FADE_IN, SCREEN_FADE_TIME)
		TheFrontEnd:PushScreen( HealthWarningPopup() )
	end
end

--------------------------

--============================================================
-- 【分区 24】实例重置（1/2）—— GlobalInit：sim 首次创建
--============================================================
exiting_game = false

-- ★★★ 这行英文注释是本文件最重要的语义约定之一：
--   「sim 首次创建时被调用 ONCE。sim 后续重建时不会再被调用！」
-- ★★ 推论：DST 里「回主菜单再进游戏」「换档」都会重建 sim，但 GlobalInit
--   **只跑一次**。因此任何「每次进游戏都要重做」的初始化都不能放这里。
--   ⇒ 对比 Start（1410 行）：Start 每次前端启动都会跑。
--   ★ 这解释了 1449-1450 行：预加载的全局 prefab 只在首次加载，
--     因为它们是全局单例，重复加载会重复创建。
-- Gets called ONCE when the sim first gets created. Does not get called on subsequent sim recreations!
function GlobalInit()
    TheSim:LoadPrefabs({ "global" })
    TheSim:LoadPrefabs(SPECIAL_EVENT_GLOBAL_PREFABS)
    TheSim:LoadPrefabs(FESTIVAL_EVENT_GLOBAL_PREFABS)
    LoadFonts()
    if PLATFORM == "PS4" then
        PreloadSounds()
    end
    TheSim:SendHardwareStats()
    FirstStartupForNetworking = true
end

-- ============================================================
-- DoLoadingPortal：进入加载界面的转场（已不再用 portal，纯白屏淡出）
-- ============================================================
-- ★ 英文注释坦承了这个妥协：「不再有 portal 了，就淡出到"白色"。
--   也许我们该用滑动淡出到加载界面？」
-- ★ 附带上报 Stats.PushMetricsEvent("joinfromscreen") —— 记录玩家从哪个
--   界面进来的，用于统计（哪个入口最受欢迎）。
function DoLoadingPortal(cb)
	local values = {}
    local screen = TheFrontEnd:GetActiveScreen()
	values.join_screen = screen ~= nil and screen.name or "other"
	values.special_event = screen ~= nil and screen.event_id or nil
	Stats.PushMetricsEvent("joinfromscreen", TheNet:GetUserID(), values)

	--No portal anymore, just fade to "white". Maybe we want to swipe fade to the loading screen?
	TheFrontEnd:Fade(FADE_OUT, SCREEN_FADE_TIME, cb, nil, nil, "white")
end

-- This is for joining a game: once we're done downloading the map, we load it and simreset
-- ============================================================
-- LoadMapFile：加载本地存档地图
-- ============================================================
-- ★★ 同步 vs 转场的选择（★ 这是一个重要的状态机约束）：
--   InGamePlay() 为真 → 必须**同步**换实例。
--   ★ 原因：此时屏幕栈上还留着大厅/加载等界面，若走淡出转场，
--     那些界面会在 SimReset 之后仍然存在，导致状态错乱。
--   不在游戏中 → 可以先淡出再换（对玩家而言有转场效果）。
function LoadMapFile(map_name)
    local function do_load_file()
        DisableAllDLC()
        StartNextInstance({ reset_action = RESET_ACTION.LOAD_FILE, save_name = map_name })
    end

    if InGamePlay() then
        -- Must be a synchronous load if we're in any game play state (including lobby screen)
        do_load_file()
    else
        DoLoadingPortal(do_load_file)
    end
end

function JapaneseOnPS4()
    if PLATFORM=="PS4" and APP_REGION == "SCEJ" then
        return true
    end
    return false
end

-- ============================================================
-- StartNextInstance：★★ 换实例的中枢（★ 存档重启的必经之路）
-- ============================================================
-- ★★★ 这个函数把「上一局的战绩数据」打包成 match_results 传给下一实例。
--   MvpCards / WxpData / PlayerStats / Outcome（战绩卡、经验、统计、胜负）
--   ★ 三元表达式的巧思：`TheWorld ~= nil and TheWorld.GetMvpAwards ~= nil`
--     —— 先判「世界存在」再判「方法存在」，避免对 nil 调用方法。
--     方法在 TheWorld 上不存在 ⇒ 说明这不是主 sim（可能是分片）⇒
--     退回到 TheFrontEnd.match_results（前端自己记的那份）。
-- ★⇒ 这套「World 有就用 World 的，否则用前端的」是 DST 处理
--   「同一局在主 sim / 分片 sim 之间数据共享」的通用套路，本文件多处出现。
function StartNextInstance(in_params)
    local match_results =
    {
        mvp_cards = TheWorld ~= nil and TheWorld.GetMvpAwards ~= nil and TheWorld:GetMvpAwards() or TheFrontEnd.match_results.mvp_cards,
        wxp_data = TheWorld ~= nil and TheWorld.GetAwardedWxp ~= nil and TheWorld:GetAwardedWxp() or TheFrontEnd.match_results.wxp_data,
        player_stats = TheWorld ~= nil and TheWorld.GetPlayerStatistics ~= nil and TheWorld:GetPlayerStatistics() or TheFrontEnd.match_results.player_stats,
        outcome = TheWorld ~= nil and TheWorld.GetMatchOutcome ~= nil and TheWorld:GetMatchOutcome() or TheFrontEnd.match_results.outcome,
    }

    if TheNet:GetIsServer() then
-- ★ NotifyLoadingState 通知客户端「开始加载」并带上战绩。
        NotifyLoadingState(LoadingStates.Loading, match_results)
    end

    local params = in_params or {}
    params.last_reset_action = Settings.reset_action
    params.match_results = match_results
-- ★ params 里这三项是**纯表现层**数据：loading_screen_image（随机图）、
--   loading_screen_keys（加载界面显示哪些按键提示）。
--   ⇒ 换实例时要传过去，才能在新实例里继续显示这些小功能。
    params.load_screen_image = global_loading_widget.image_random
    params.loading_screen_keys = BuildListOfSelectedItems(Profile, "loading")

    SimReset(params)
end

-- ============================================================
-- ForceAssetReset：强制重置资源集（出错后的逃生门）
-- ============================================================
-- ★ 设置成一个**不可能存在的资源集名** "FORCERESET"，
--   从而让下次启动时找不到资源、降级到全新下载。
--   ★ 这是「用一个非法值表达『请忘掉缓存』」的实用技巧。
-- ★ 唯一调用点：DisplayError 里玩家点「禁用所有模组」按钮（1607-1613 行）。
function ForceAssetReset()
    Settings.current_asset_set = "FORCERESET"
    Settings.current_world_asset = nil
    Settings.current_world_specialevent = nil
    Settings.current_world_extraevents = nil
end

--============================================================
-- 【分区 24 续】★★ SimReset —— ★ 实例重置的实际执行者
--============================================================
-- ★★★ SimReset 的三步（★ 换档/重开/回主菜单都会走这里）：
--     ① 把当前设置**快照**进 instanceparameters（要带到下一实例的东西）
--     ② json.encode 成字符串（跨 Lua/C++ 边界只能传字符串）
--     ③ TheSim:Reset() —— 引擎销毁并重建 sim
-- ★★ 注意 1522 行 SimTearingDown = true：这是给**其他代码**看的信号，
--   表示「正在拆解中，别做多余的事」。文件头那三个全局标志的第一个。
function SimReset(instanceparameters)
    SimTearingDown = true

    if instanceparameters == nil then
        instanceparameters = {}
    end
-- ★★★ 「last_」前缀的含义：**上一个实例**的值，存下来用于下一实例判断
--   「这次是不是换了资源/角色/模组」，必要时做清理或迁移。
--   这是「跨实例状态传递」的标准做法：Lua 局部变量活不过 SimReset，
--   只能靠 Settings（全局表，1527 行它还是活着的）来搬运。
    instanceparameters.last_asset_set = Settings.current_asset_set
    instanceparameters.last_world_asset = Settings.current_world_asset
    instanceparameters.last_world_specialevent = Settings.current_world_specialevent
    instanceparameters.last_world_extraevents = Settings.current_world_extraevents
    instanceparameters.loaded_characters = Settings.loaded_characters
-- ★ loaded_mods = ModManager:GetUnloadPrefabsData() —— 卸载预制体时的数据，
--   ★ 也要带到下一实例：否则卸载时无法恢复某些全局状态。
-- ★★ 模组是唯一能在「实例之间」携带数据的东西：Lua 沙盒会被完全销毁，
--   全局表全部丢失，只有这个专门的通道能把数据送出去。
    instanceparameters.loaded_mods = ModManager:GetUnloadPrefabsData()
-- ★★ BACKEND 模式（专用服务器）才需要这两项：
--   memoizedFilePaths —— 缓存的文件路径表，避免重启后重复做路径解析（慢）；
--   chatHistory —— 聊天记录，跨重启保留。
--   ★ 只在 BACKEND 分支带上，说明这两项对客户端是负担（内存），不必传。
-- ★ ChatHistory:GetChatHistory() 参见 chathistory.lua。
    if Settings.current_asset_set == "BACKEND" then
        instanceparameters.memoizedFilePaths = GetMemoizedFilePaths()
        instanceparameters.chatHistory = ChatHistory:GetChatHistory()
    end

-- ★★ json.encode → SetInstanceParameters → TheSim:Reset()。
--   ★ SetInstanceParameters（954 行）就是接收端，会 json.decode 回来。
--   ★ 完整闭环：本行 encode → SetInstanceParameters decode → 下个实例可读。
-- ★ 这也是文件头说的「外部设置注入」的实际通路。
    local params = json.encode(instanceparameters)
    TheSim:SetInstanceParameters(params)
    TheSim:Reset()
end

--============================================================
-- 【分区 25】退出流程（1/2）
--============================================================
function RequestShutdown()
-- ★★ exiting_game 守卫：**重入保护**。
--   RequestShutdown 可能被多处触发（玩家点退出、系统事件、
--   DynamicCloudSyncDelete、云同步），必须保证只执行一次。
--   ★ 典型触发竞态：系统同时发出「窗口关闭」和「云存档同步删除」。
    if exiting_game then
        return
    end
    exiting_game = true

-- ★ 非专服才弹「正在退出」对话框——专服没有界面。
    if not TheNet:GetServerIsDedicated() then
        TheFrontEnd:PushScreen(
            PopupDialogScreen(STRINGS.UI.QUITTINGTITLE, STRINGS.UI.QUITTING, {})
        )
    end

-- ★ GetIsHosting：判断本机是否同时在开一个专用服务器进程。
--   若是，要先把它停掉（StopDedicatedServers），否则会留下僵尸进程。
-- ★ IsDynamicCloudShutdown 决定是否「立刻」停（正常退出会给它收尾时间，
--   云同步触发的快速退出会立即停）。
    if TheNet:GetIsHosting() then
        TheSystemService:StopDedicatedServers(not IsDynamicCloudShutdown)
    end

    Shutdown()
end

-- DoWorldOverseerShutdown：世界 overseer（管理者实体）主动收场。
-- ★ 让世界里的「管理者 AI」知道要退出了，从而触发它自己的清理/结算逻辑
--   （比如让 boss 停止行动）。★ 必须发生在 SimShuttingDown 之前——
--   因为一旦 sim 开始销毁，就没法再执行有意义的游戏逻辑了。
function DoWorldOverseerShutdown()
    if TheWorld ~= nil and TheWorld.ismastershard and TheWorld.components.worldoverseer ~= nil then
        TheWorld.components.worldoverseer:QuitAll()
    end
end

-- ============================================================
-- Shutdown —— ★ 真正关闭 sim
-- ============================================================
-- ★★ 注释里明确警告了此时的代码环境有多危险：
--   「警告，我们不想在这里跑太多代码。我们正处于一种
--     「资源已加载但路径映射混乱」的奇怪中间状态。」
-- ★ 所以 1575-1581 行把卸载资源的代码**全部注释掉了**——
--   由 C++ 子系统析构来处理。这是很清醒的工程判断。
function Shutdown()
    DoWorldOverseerShutdown()

    SimShuttingDown = true

    Print(VERBOSITY.DEBUG, 'Ending the sim now!')

    --V2C: Assets will be unloaded when the C++ subsystems are deconstructed
    --UnloadFonts()

    -- warning, we don't want to run much code here. We're in a strange mix of loaded assets and mapped paths
    -- as a bonus, the fonts are unloaded, so no asserting...
    --TheSim:UnloadAllPrefabs()
    --ModManager:UnloadPrefabs()

    TheSim:Quit()
end

-- ============================================================
-- DisplayError —— 错误展示（★ 玩家可见的错误界面）
-- ============================================================
-- ★★ 第一件事就是 SetPause(true)：出错时必须冻结游戏，
--   否则后续逻辑可能在错误状态上继续跑。
-- ★★ global_error_widget 守卫：**同一个错误只弹一次**。
--   ★ 这是防「弹窗风暴」的关键——某个每帧触发的错误会反复调 DisplayError，
--     没有这个守卫玩家会被几百个弹窗淹没。
function DisplayError(error)

    SetPause(true,"DisplayError")
    if global_error_widget ~= nil then
        return nil
    end

-- ★ 英文注释："Failsafe since sometimes the error screen is no shown"
--   （兜底：有时候错误界面根本不显示）—— 所以无论如何都要 print，
--   保证日志里有记录。这是个很实用的容错思维。
    print (error) -- Failsafe since sometimes the error screen is no shown

    local modnames = ModManager:GetEnabledModNames()

-- ★★ 两个分支：有模组 / 无模组，给完全不同的按钮组。
--   有模组 → 强烈暗示「是你的模组导致的」，并提供「禁用所有模组」按钮。
--   ★ 这是对玩家最有价值的自助修复路径（不用等官方发版）。
    if #modnames > 0 then
        local modnamesstr = ""
        for k,modname in ipairs(modnames) do
            modnamesstr = modnamesstr.."\""..KnownModIndex:GetModFancyName(modname).."\" "
        end

        local buttons = nil
        if IsNotConsole() then
            buttons = {
                {text=STRINGS.UI.MAINSCREEN.SCRIPTERRORQUIT, cb = function() TheSim:ForceAbort() end},
                {text=STRINGS.UI.MAINSCREEN.MODQUIT, cb = function()
                                                            KnownModIndex:DisableAllMods()
                                                            ForceAssetReset()
                                                            KnownModIndex:Save(function()
                                                                TheSim:ResetError()
                                                                SimReset()
                                                            end)
                                                        end},
                {text=STRINGS.UI.MAINSCREEN.MODFORUMS, nopop=true, cb = function() VisitURL("https://forums.kleientertainment.com/forum/79-dont-starve-together-beta-mods-and-tools/") end }
            }

            -- Add reload save button if we're on dev
-- ★ dev 分支才加「重启」按钮：正式版加了会让玩家反复重启尝试，
--   掩盖真实问题；开发时自己重启更方便。
            if BRANCH == "dev" then
                table.insert(buttons, 1, {text=STRINGS.UI.MAINSCREEN.SCRIPTERRORRESTART, cb = function()
                                                                                                TheSim:ResetError()
                                                                                                c_reset()
                                                                                            end})
            end
        end
        SetGlobalErrorWidget(
                STRINGS.UI.MAINSCREEN.MODFAILTITLE,
                error,
                buttons,
                ANCHOR_LEFT,
                STRINGS.UI.MAINSCREEN.SCRIPTERRORMODWARNING..modnamesstr,
                20
                )
    else
        local buttons = nil

        -- If we know what happened, display a better message for the user
-- ★★ known_error_key：具名已知错误 → 取 ERRORS 表里的友好文案。
--   ★ 这就是 Start() 里那几条 known_assert 的价值兑现处：
--     断言时给出错误码，这里负责翻译成人话。
--   ★ 参见 knownerrors.lua —— 错误码 → 消息 + 帮助链接的登记表。
-- ⚠ 疑似缺陷（真实缺陷，作用域受限）：1665 行
--   `elseif known_error.url ~= nil then` 直接对 known_error 取字段，
--   但该分支只保证 known_error **非 nil**（1639 行判过）。
--   ★ 推理：known_error 若为 nil，`known_error.url` 会抛
--     "attempt to index field 'known_error' (a nil value)"。
--     触发条件：在 1639-1641 行**成功**取得 known_error 的前提下，
--     却走进了 1665 行的 elseif —— 这在 1663 行已判过 known_error_key
--     与 ERRORS[key] 均非 nil 时不可能发生，故实际不可达。
--     结论：逻辑冗余/写法不严谨，但当前不可触发。不修改。
        local known_error = known_error_key ~= nil and ERRORS[known_error_key] or nil
        if known_error ~= nil then
            error = known_error.message
        end

-- ★ 无模组分支：按钮只有「退出」，比有模组时少得多。
        if IsNotConsole() then
            buttons = {
                {text=STRINGS.UI.MAINSCREEN.SCRIPTERRORQUIT, cb = function() TheSim:ForceAbort() end},
            }

            -- Add reload save button if we're on dev
            if BRANCH == "dev" then
                table.insert(buttons, 1, {text=STRINGS.UI.MAINSCREEN.SCRIPTERRORRESTART, cb = function()
                                                                                                TheSim:ResetError()
                                                                                                c_reset()
                                                                                            end})
-- ★★ 追加调试控制台按钮的条件：`not Profile:GetThreadedRenderEnabled()`。
--   ★ 推理：多线程渲染开启时弹出调试控制台会导致渲染崩溃，
--     故仅在单线程渲染下才提供该按钮。这是一个**兼容性守卫**。
                if not Profile:GetThreadedRenderEnabled() then
                    table.insert(buttons, 1, {text=STRINGS.UI.MAINSCREEN.SCRIPTERROR_DEBUG, cb = function()
                        if not TheFrontEnd:FindOpenDebugPanel(DebugNodes.DebugConsole) then
                            DebugNodes.ShowDebugPanel(DebugNodes.DebugConsole, false)
                        end
                    end})
                end
            end

-- ★★ 错误分类的完整判定链（1663-1667 行）：
--   · 已知错误 → 提供 GETHELP 按钮（跳官方帮助页）
--   · 未知错误 → 提供 ISSUE 按钮（跳 bug 提交页）
--   ★ 注意顺序：**未知时优先给「上报」，已知时优先给「求助」**。
--     逻辑合理：已知错误有现成解法，未知错误需要人工介入。
            if known_error_key == nil or ERRORS[known_error_key] == nil then
                table.insert(buttons, {text=STRINGS.UI.MAINSCREEN.ISSUE, nopop=true, cb = function() VisitURL("https://forums.kleientertainment.com/klei-bug-tracker/dont-starve-together/") end })
            elseif known_error.url ~= nil then
                table.insert(buttons, {text=STRINGS.UI.MAINSCREEN.GETHELP, nopop=true, cb = function() VisitURL(known_error.url) end })
            end
        end

-- ★ SetGlobalErrorWidget 的最后两个参数：对齐方式 + 存活秒数。
--   ★ 已知错误给 30 秒（要让玩家读完链接），未知错误只给 20 秒。
        SetGlobalErrorWidget(
                STRINGS.UI.MAINSCREEN.MODFAILTITLE,
                error,
                buttons,
                known_error ~= nil and ANCHOR_MIDDLE or ANCHOR_LEFT,
                nil,
                known_error ~= nil and 30 or 20
                )
    end
end

-- ============================================================
-- SetPauseFromCode / InGamePlay / IsMigrating
-- ============================================================
-- ★★ 两种暂停的区别（★ 与分区 17 的 IsPaused 互补）：
--   SetPause（937 行）= 改**游戏状态**（是否暂停）
--   SetPauseFromCode（这里）= 在**代码请求暂停**时，顺带弹出暂停界面。
--   ★ 二者分工：一个是状态，一个是 UI 表现。这里甚至不看状态，
--     只判 inGamePlay —— 因为调用方要的就是「弹界面」这个动作。
function SetPauseFromCode(pause)
    if pause then
        if inGamePlay and not IsPaused() then
            local PauseScreen = require "screens/redux/pausescreen"
            TheFrontEnd:PushScreen(PauseScreen())
        end
    end
end

-- ★ inGamePlay 是全局布尔：本文件多处（1192、1713、1876、1976 行）用它判断
--   「是否处于游戏中」。它由 gamelogic.lua 维护。
function InGamePlay()
    return inGamePlay
end

-- ============================================================
-- IsMigrating —— ★ 判定「正在换实例/迁移」
-- ============================================================
-- ★★★ 作者自己承认这个判定是**凑合的**（注释原文）：
--   「目前唯一真正能告诉我们正在迁移的方法，是我们既不在 FE 也不在
--     游戏里，结果就是没有界面……比如没有活动界面，
--     或者只有个『正在连接游戏』弹窗。
--     ★ 这个应该改进，YARK YARK YARK」
--   「V2C: Who dat? ----------^」（这是谁写的？）
-- ★★ 判据 = 没有任何界面，或只有 ConnectingToGamePopup 且界面栈深度<=1。
-- ★★ 为什么要区分「迁移中」：迁移期间弹「已断开连接」对话框是**错的 UX**
--   （玩家只是换图，不是掉线）。这个判断被 1817、1883、1804 行反复使用。
function IsMigrating()
    --Right now the only way to really tell if we are migrating is if we are neither in FE or in gameplay, which results in no screen...
    --      e.g. if there is no active screen, or just a connecting to game popup
    --THIS SHOULD BE IMPROVED YARK YARK YARK
    --V2C: Who dat? ----------^
    local screen = TheFrontEnd:GetActiveScreen()
    return screen == nil or (screen.name == "ConnectingToGamePopup" and TheFrontEnd:GetScreenStackSize() <= 1)
end

--DoRestart helper
--============================================================
-- 【分区 26】★★ 重启流程 —— 保存并重启的完整链条
--============================================================
-- ★★★ postsavefn / savefn / DoRestart 构成一个两阶段回调结构：
--   DoRestart(save) -- 淡出 → savefn（保存）→ postsavefn（重启）
--   ★★ 关键点：**必须先把界淡出，再开始保存**。
--     因为保存耗时（几秒），不淡出的话玩家会看着游戏卡住。
local function postsavefn()
-- ============================================================
-- postsavefn：重启的最终环节（无论是否保存都会执行）
-- ============================================================
-- ★★ 这个函数的顺序有讲究：
--     ① Disconnect(true) 先断网（★ true 参数含义推测为「强制/立即」）
--     ② EnableAllMenuDLC 恢复 DLC（临时禁用的要还回来）
--     ③ 停专用服务器进程
--     ④ StartNextInstance 起新实例
--     ⑤ inGamePlay = false / PerformingRestart = false —— ★ 复位全局标志
--   ★ 第 ⑤ 步是必须的：这些标志若不复位，重启后会永久卡在「正在重启」
--     状态，再也进不了游戏。这是**必须成对复位**的典型案例。
    TheNet:Disconnect(true)
    EnableAllMenuDLC()

    if TheNet:GetIsHosting() then
        TheSystemService:StopDedicatedServers(not IsDynamicCloudShutdown)
    end

    StartNextInstance()
    inGamePlay = false
    PerformingRestart = false
end

--DoRestart helper
-- ============================================================
-- savefn：保存环节（★ 三分支，各不相同）
-- ============================================================
-- ★★★ 三个分支的判定与动作：
--   ① TheWorld == nil     → 没世界（纯前端），无需保存，直接重启。
--   ② TheWorld.ismastersim → ★ 主 sim：走完整的分片存档保存。
--   ③ 否则（分片 sim）    → ★ 只存玩家私有数据（SerializeUserSession），
--                              不存世界（世界由主 sim 负责）。
-- ★★★ 这就是「分片（shard）架构」的写盘分工：
--   每个分片进程各自保存自己的玩家数据，但世界只有主 sim 保存一次。
--   ★ 若分片也去存世界，会导致多进程竞争写同一个世界存档 → 损坏。
local function savefn()
    if TheWorld == nil then
        postsavefn()
    elseif TheWorld.ismastersim then
-- ★ DoWorldOverseerShutdown 与 DoRestart 一一对应（1562 行那个函数）。
        DoWorldOverseerShutdown()

-- ★★★ v:OnDespawn() —— 逐个「退场」。
--   ★ 这是 1066-1067 行 isshutdown 语义的前因：调用方在这里先让玩家退场，
--     然后 SaveGame(isshutdown=true) 才可以安全地做快照轮转（1243 行）。
--   ★⇒ 顺序不可颠倒：必须先 OnDespawn 清理完玩家，SaveGame 才敢删快照。
--   ★ 参见 1774 行 ms_playerdespawn 事件 —— 存档实际发生在那里（英文注释）。
        for i, v in ipairs(AllPlayers) do
            v:OnDespawn()
        end
-- ★★ EnableStorage(true)：临时**打开存档写入权限**。
--   ★ 这是存档系统的权限门：平时是关闭的（防止意外写盘），
--     只有在明确要保存时才开启。
--   ★ 与 Start() 里的 CanWriteConfigurationDirectory 检查配套：
--     启动时检查权限能不能用，真正保存时才打开开关。
        TheSystemService:EnableStorage(true)
-- ★★★ ShardGameIndex:SaveCurrent(cb, true)：分片存档索引的「保存当前世界」。
--   ★ 第 2 参数 true —— 推测含义是「强制/立即」或「含玩家数据」。
--     参见 shardindex.lua / shardsaveindex.lua。
--   ★ 与 SaveGame 的关系：SaveGame（1068 行）负责**内容**，
--     SaveCurrent 负责**索引与登记**（这个存档叫什么、什么时候的）。
--     ★ 两者配合完成一次完整保存。
        ShardGameIndex:SaveCurrent(postsavefn, true)
    else
        SerializeUserSession(ThePlayer)
        postsavefn()
    end
end

-- ============================================================
-- DoRestart(save) —— 入口
-- ============================================================
-- ★ PerformingRestart 守卫：防止连续触发多次重启（与 exiting_game 同类思路）。
-- ★ TheFrontEnd:Fade(FADE_OUT, 1, 回调) —— ★ 淡出 1 秒，回调里才真正做事，
--   实现「先转场后干活」。fade 的第 4、5 参传 nil 说明用的是默认颜色。
function DoRestart(save)
    print("DoRestart:", save)

	Settings.match_results = {}

    if not PerformingRestart then
        PerformingRestart = true
        ShowLoading()
        TheFrontEnd:Fade(FADE_OUT, 1, save and savefn or postsavefn)
    end
end

-- ★★ IsDynamicCloudShutdown 是另一个全局标志（文件头第三个）。
-- ★ 下方英文注释：「这些目前没被使用，等 Steam 动态云同步功能最终启用时会用上。」
--   —— 又一处诚实的「未来功能」标注。
IsDynamicCloudShutdown = false

--these are currently unused, they will be used on Steam Dynamic Cloud Syncing is eventually enabled.
-- ★ OnDynamicCloudSyncReload：云同步要求回滚到存档点。
--   参数 0 的含义推测是「回滚多少个版本/到第几个快照」。
function OnDynamicCloudSyncReload()
    TheNet:SendWorldRollbackRequestToServer(0)
end

function OnDynamicCloudSyncDelete()
    IsDynamicCloudShutdown = true
    DoRestart(false)
end

local screen_fade_time = .25

--============================================================
-- 【分区 27】断线处理
--============================================================
function OnPlayerLeave(player_guid, expected)
-- ★★ 全函数用 TheWorld.ismastersim 守卫：断线事件**只有主 sim 处理**。
--   ★ 分片/客户端收到这个事件必须忽略，否则会重复推送玩家离开。
    if TheWorld.ismastersim and player_guid ~= nil then
        local player = Ents[player_guid]
        if player ~= nil then
-- ★★★ 这段 V2C 注释记录了一个**行为变更**：
--   「这里以前是用来宣告玩家离开的。现在我们在玩家真正断开时才宣告，
--     但分片迁移导致的断开不算。」
-- ★ 关键：原代码（1769 行）被注释掉了。取而代之的是两个事件。
-- ★★ 为什么区分「真正断开」和「迁移断开」：迁移时玩家其实没走，
--   若宣告离开会造成误报（「XX 离开了游戏」）。这是分片架构带来的新问题。
            --V2C: #spawn #despawn
            --     This was where we used to announce player left.
            --     Now we announce it when you actually disconnect
            --     but not during a shard migration disconnection.
            --TheNet:Announce(string.format(STRINGS.UI.NOTIFICATION.LEFTGAME, player:GetDisplayName()), player.entity, true, "leave_game")

            --Save must happen when the player is actually removed
            --This is currently handled in playerspawner listening to ms_playerdespawn
-- ★★★ ms_playerdisconnected（带 wasExpected）与 ms_playerdespawn 两事件。
-- ★★ 分工：disconnected 携带「是否预期内」信息（如迁移），
--   despawn 是纯粹的「玩家实体没了」。
-- ★★ 关键线索（1771-1772 行英文注释）：
--   「保存必须发生在玩家**真正被移除**的时候。
--     这目前由 playerspawner 监听 ms_playerdespawn 来处理。」
--   ⇒ ★★ 真正的存档触发点**不在本文件**，在 components/playerspawner.lua。
--     本文件只负责派发事件。这条线索对排查「什么时候存盘」极重要。
            TheWorld:PushEvent("ms_playerdisconnected", {player=player, wasExpected=expected})
            TheWorld:PushEvent("ms_playerdespawn", player)
        end
    end
end

-- Receive a message that does not disconnect the user
-- ============================================================
-- OnPushPopupDialog：不掉线的通知弹窗（服务端可下发）
-- ============================================================
-- ★ 服务器可以给客户端推一个不打断游戏的对话框（如警告、公告）。
-- ★ or ...DEFAULT 的兜底：message 是**键**，不是文案本身。
--   ★ 服务端只传 key，文案从本地化表取 —— 好处是省带宽 + 支持多语言。
function OnPushPopupDialog( message )
    local title = STRINGS.UI.POPUPDIALOG.TITLE[message] or STRINGS.UI.POPUPDIALOG.TITLE.DEFAULT
    message = STRINGS.UI.POPUPDIALOG.BODY[message] or STRINGS.UI.POPUPDIALOG.BODY.DEFAULT

    local function doclose( )
        TheFrontEnd:PopScreen( )
    end

    TheFrontEnd:PushScreen( PopupDialogScreen(title, message, { {text=STRINGS.UI.POPUPDIALOG.OK, cb = function() doclose( ) end}  }) )
    local screen = TheFrontEnd:GetActiveScreen()
    if screen then
        screen:Enable()
    end
end

-- ============================================================
-- OnDemoTimeout：试玩版到期
-- ============================================================
-- ★ 试玩到期要保存玩家进度（1801 行），再重启。
-- ★★ 1804 行的短路：只有「在游戏中」或「正在迁移」才需要重启。
--   已在主菜单就什么都不用做（should_reset 为假）。
function OnDemoTimeout()
	print("Demo timed out")
	if not IsMigrating() then
		TheSystemService:StopDedicatedServers(not IsDynamicCloudShutdown)
	end
	if ThePlayer ~= nil then
		SerializeUserSession(ThePlayer)
	end
	local should_reset = true
	should_reset = should_reset and (InGamePlay() or IsMigrating())

	DoRestart(should_reset)
end

-- Receive a disconnect notification
-- ============================================================
-- OnNetworkDisconnect —— ★ 断线对话框（★ 本文件最长的条件分支链）
-- ============================================================
-- ★★ 函数签名 6 个参数，全部可选。参数含义（据用法推断）：
--   message            —— 断开原因码（本地化键，如 E_BANNED）
--   should_reset       —— 客户端是否认为需要重置实例
--   force_immediate_reset —— 服务器要求立即断开（不做提示）
--   details            —— 服务器下发的附加数据（含 help_button）
--   miscdata           —— 额外回调（如「离线模式」的收尾）
function OnNetworkDisconnect( message, should_reset, force_immediate_reset, details, miscdata)
    -- The client has requested we immediately close this connection
-- ★ force_immediate_reset：客户端主动要求立即关闭连接。
--   走 DoRestart(true) 且**不弹任何对话框** —— 服务器说了算。
    if force_immediate_reset == true then
        DoRestart(true)
        return
    end

-- ★★ 迁移期间不停专用服务器：停了就没法继续迁移了。
--   ★ 与 1804 行是同一个判断的两次应用。
    if not IsMigrating() then
        TheSystemService:StopDedicatedServers(not IsDynamicCloudShutdown)
    end

    local accounts_link = nil
	local help_button = nil
    local play_offline = nil
-- ============================================================
-- 按钮收集（★★ 三段 if 嵌套，值得单独读）
-- ============================================================
-- ★★ 这段代码的模式：**收集候选按钮，再用三层 if 把它们挪进固定槽位**。
--   accounts_link / help_button / play_offline 各自有语义和顺序要求：
--     ① 被封禁（E_BANNED）→ 可能有 accounts_link（主机平台）和 play_offline
--   ② details.help_button 永远存在，但槽位取决于 ① 的结果
--   ③ play_offline 若还没位置，就填剩下的空位
-- ★★★ 为什么要这么绕？因为按钮是按**顺序**传给 PopupDialogScreen 的，
--   「OK / 账号 / 帮助 / 离线」这个顺序不能变，但按钮的有无因条件而异。
--   ⇒ 用「先收集、再按优先级填槽」的方式保证顺序稳定。
-- ⚠ 疑似缺陷（极轻微）：1837 行 `if accounts_link == nil then accounts_link =
--   details.help_button` —— 把 help_button 赋给了 accounts_link 槽位。
--   ★ 结合上下文看，这**可能**是笔误（本该赋给 help_button），
--     但也可能是「服务器只提供一个按钮时，按帮助按钮的语义展示」。
--     无法从单文件判定，不作为确定缺陷，仅标注存疑。不修改。
    if message == "E_BANNED" then
-- ★★ 被封禁（E_BANNED）的特殊 UI：主机平台给「账号管理」入口。
--   ★ 只有 IsRail()（主机）或有 net overlay 时才提供该入口，
--     因为 PC/Steam 的账号管理在游戏外进行。
        if (IsRail() or TheNet:IsNetOverlayEnabled()) then
            accounts_link = {text=STRINGS.UI.NETWORKDISCONNECT.ACCOUNTS, cb = function() TheFrontEnd:GetAccountManager():VisitAccountPage() end}
        end
-- ★★ play_offline：被封禁时允许「以离线模式继续玩」
--   （单机玩，不受封禁影响）。★ 这是主机版特有的宽容处理。
--   ⚠ 注意它会 PopScreen 再调 miscdata 回调 —— 顺序是先关界面后执行收尾。
        play_offline = {text=STRINGS.UI.MAINSCREEN.PLAYOFFLINE, cb = function()
            TheFrontEnd:PopScreen()
            if miscdata then
                miscdata()
            end
        end}
    end

-- ★★ details.help_button 的去向（★ 槽位分配的三段逻辑，见上方注释）：
--   若 accounts_link 空 → help_button 顶替账号链接的位置；
--   否则 → 落到 help_button 自己的位置。
--   ★ 推测：服务器可下发一个「帮助」按钮，而某些封禁场景下
--     「账号管理」与「帮助」只能二选一展示。
	if details ~= nil then
		if accounts_link == nil then
			accounts_link = details.help_button
		else
			help_button = details.help_button
		end
	end

-- ★ play_offline 的兜底：再没有位置就顶替 help_button。
--   ★ 三段 if 下来，四个候选按钮最终被塞进四个固定槽位，
--     顺序恒为：OK、账号、帮助、离线。
    if play_offline ~= nil then
        if accounts_link == nil then
            accounts_link = play_offline
            play_offline = nil
        elseif help_button == nil then
            help_button = play_offline
            play_offline = nil
        end
    end

-- ★ message 是键 → 取本地化文案。TITLE 与 BODY 各有一套表。
    local title = STRINGS.UI.NETWORKDISCONNECT.TITLE[message] or STRINGS.UI.NETWORKDISCONNECT.TITLE.DEFAULT
    message = STRINGS.UI.NETWORKDISCONNECT.BODY[message] or STRINGS.UI.NETWORKDISCONNECT.BODY.DEFAULT

-- ★★★ 三个「当前界面」的特判，每个都要先取消加入流程：
--   ConnectingToGamePopup → 直接弹掉
--   QuickJoinScreen        → JoinServerResponse(true) 取消加入 + 换下一台服务器
--   HostCloudServerPopup   → 取消 + 报错
-- ★ JoinServerResponse(true) 是**必须调用**的：否则「正在加入」的请求
--   会永远挂着，主界面被卡在等待状态。这是网络状态机的收尾义务。
    local screen = TheFrontEnd:GetActiveScreen()
    if screen then
		if screen.name == "ConnectingToGamePopup" then
			TheFrontEnd:PopScreen()
		elseif screen.name == "QuickJoinScreen" then
		    TheNet:JoinServerResponse( true ) -- cancel join
            TheNet:Disconnect(false)
			screen:TryNextServer(title, message)
			return
		elseif screen.name == "HostCloudServerPopup" then
		    TheNet:JoinServerResponse( true ) -- cancel join
            TheNet:Disconnect(false)
            screen:OnError(message)
			return
		end
    end

-- ★★★ 「如果我们打算序列化用户会话，现在就做。再晚就来不及了。」
-- ★★ 这条注释解释了为什么这里要提前保存：断线对话框是异步弹出的，
--   而**稍后（第 1883 行）可能会重置实例**（SimReset 会销毁所有状态），
--   那时再保存数据就已经没了（玩家实体可能已随世界销毁）。
-- ★ 同样的防御性保存也出现在 1801（demo 超时）与 1730 行。
--   ⇒ 规律：★「所有可能导致 SimReset 的路径，都必须在 reset 之前保存玩家数据」。
    --If we plan to serialize a user session, we should do it now.  It will be too late later.
    if ThePlayer ~= nil then
        SerializeUserSession(ThePlayer)
    end

    --Don't need to reset if we're in FE already
    --NOTE: due to migration, we can be in neither gameplay nor FE
    --      INVALID_CLIENT_TOKEN is a special case; we want to
    --      boot the user back to the main menu even if they're in the FE
-- ★★ 三个条件任一成立才需要重置：
--   InGamePlay()        —— 正在游戏里
--   IsMigrating()       —— 正在迁移
--   message == "INVALID_CLIENT_TOKEN" —— ★ 特例：即使在主菜单也要重置！
-- ★★ 注释解释了为什么这个特例要做：令牌失效是严重状态问题，
--   必须把用户踢回主菜单重新走登录流程，哪怕他本来就在主菜单。
-- ★ 三个条件混在一起是因为「重置」在这里的含义是「回到可重新加入的状态」。
    should_reset = should_reset and (InGamePlay() or IsMigrating() or message == "INVALID_CLIENT_TOKEN")
-- doquit：对话框点了 OK 之后做什么。
    local function doquit( should_reset )
        if should_reset == true then
            DoRestart(false) --don't save again
        else
            TheNet:Disconnect(false)
            TheFrontEnd:PopScreen()
            -- Make sure we try to enable the screen behind this
            local screen = TheFrontEnd:GetActiveScreen()
            if screen then
                screen:Enable()
            end
        end
    end

-- ★★★ 这段 if/else 的作用是「处理淡入动画与弹窗的竞态」：
--   若当前正在淡入（fade level > 0）且方向是淡入中（fadedir == false 表示"
--   淡入动画已完成/正在展示），就把弹窗**延迟**到当前淡入结束后再显示
--   （1899-1909 行：替换 fadecb 回调，动画结束后才 PushScreen）。
--   否则直接显示（1918-1927 行）。
-- ★★ 竞态的本质：PushScreen 与 Fade 同时发生会导致界面被动画覆盖、
--   或弹窗一闪而过。所以要排队而不是硬插。
-- ⚠ 1919-1926 行整块被注释掉了：原本「先淡出再弹窗」的方案被放弃，
--   改为直接弹窗。推测原因是淡出会打断对话框的可读性。不修改。
    if TheFrontEnd:GetFadeLevel() > 0 then --we're already fading
-- ============================================================
-- 淡入竞态的两种处理路径
-- ============================================================
-- ★★ fadedir == false：淡入动画**已经播完**（只是画面还暗）。
--   ⇒ 此时直接 PushScreen 会打断淡入，必须挂到 fadecb 上延迟。
        if TheFrontEnd.fadedir == false then
-- ★ 保存原回调，再包一层：先执行原回调，再弹对话框。
--   ★ 这就是「装饰器（decorator）」模式：包装而非替换。
--   ★ 若原回调为 nil（1902 行的判断），则跳过。
            local cb = TheFrontEnd.fadecb
            TheFrontEnd.fadecb = function()
                if cb then cb() end
                TheFrontEnd:PushScreen( PopupDialogScreen(title, message, { {text=STRINGS.UI.NETWORKDISCONNECT.OK, cb = function() doquit( should_reset ) end}, accounts_link, help_button, play_offline }) )
                local screen = TheFrontEnd:GetActiveScreen()
                if screen then
                    screen:Enable()
                end
                TheFrontEnd:Fade(FADE_IN, screen_fade_time)
            end
-- ★ else：淡入动画**正在进行中** —— 此时 PushScreen 是安全的
--   （动画会继续，弹窗叠加在上面）。所以不必延迟，直接弹。
        else
            TheFrontEnd:PushScreen( PopupDialogScreen(title, message, { {text=STRINGS.UI.NETWORKDISCONNECT.OK, cb = function() doquit( should_reset ) end}, accounts_link, help_button, play_offline }) )
            local screen = TheFrontEnd:GetActiveScreen()
            if screen then
                screen:Enable()
            end
            TheFrontEnd:Fade(FADE_IN, screen_fade_time)
        end
-- ============================================================
-- 正常路径：根本没在淡入 → 直接弹窗
-- ============================================================
-- ★ 注意整块被注释的旧实现（1919 / 1925 行）：
--   原本想「先淡出再弹窗」，现改为直接弹窗。
-- ★ 推测原因：先淡出会让玩家在黑屏中多等一次淡出时间。
    else
        -- TheFrontEnd:Fade(FADE_OUT, screen_fade_time, function()
            TheFrontEnd:PushScreen( PopupDialogScreen(title, message, { {text=STRINGS.UI.NETWORKDISCONNECT.OK, cb = function() doquit( should_reset ) end}, accounts_link, help_button, play_offline }) )
            local screen = TheFrontEnd:GetActiveScreen()
            if screen then
                screen:Enable()
            end
            -- TheFrontEnd:Fade(FADE_IN, screen_fade_time)
        -- end)
    end
-- ★ return true：这个返回值供 C++ 侧判断「已处理该断连通知」。
    return true
end

--============================================================
-- 【分区 28】账号事件监听（登录/登出/封禁等）
--============================================================
OnAccountEventListeners = {}

-- ★ 监听器模式：注册到全局数组，由 OnAccountEvent（1948 行）统一广播。
-- ★ 为什么用数组而不是 map：需要**注册顺序**，且同一函数可能被注册多次
--   （不同对象各有自己的方法）。
function RegisterOnAccountEventListener( listener )
    table.insert( OnAccountEventListeners, listener )
end

-- ============================================================
-- RemoveOnAccountEventListener：按引用移除监听器
-- ============================================================
-- ⚠ 疑似缺陷（真实缺陷，但可容忍）：
--   用 **pairs** 遍历 OnAccountEventListeners 数组，却用线性递增的 index
--   去 table.remove。★ 两个问题：
--     ① pairs 遍历数组**不保证顺序**，index 与实际被访问的元素无对应关系；
--     ② 即使顺序恰好一致，table.remove 会**移动后续元素**，
--        而 for 的 pairs 迭代在表被修改时行为未定义。
--   ★ 后果：可能删错监听器，或漏删。多监听器时才会显现。
--   ★ 正确写法应用 ipairs（按下标稳定遍历），或反向 for 倒序删除。
--   ★ 实际影响：账号事件监听器数量很少（通常 1-3 个），且删错的后果
--     仅仅是多收到一次回调，通常无害。故原版一直没被发现。不修改。
function RemoveOnAccountEventListener( listener_to_remove )
    local index = 1
    for k,listener in pairs(OnAccountEventListeners) do
        if listener == listener_to_remove then
            table.remove( OnAccountEventListeners, index )
            break
        end
        index = index + 1
    end
end

-- ============================================================
-- OnAccountEvent：广播（★ 所有监听器都会被无条件通知）
-- ============================================================
-- ★ listener:OnAccountEvent(...) 是**方法调用**（冒号），
--   所以监听器是**对象**而非函数 —— 它们需要持有状态。
function OnAccountEvent( success, event_code, custom_message )
    for k,listener in pairs(OnAccountEventListeners) do
        if listener ~= nil then
            listener:OnAccountEvent( success, event_code, custom_message )
        end
    end
end

-- ============================================================
-- TintBackground：背景染色（★ 大量被注释掉的 DLC 分支）
-- ============================================================
-- ★ 整个函数体只剩一行有效代码，1957-1960 行是被注释的「按 DLC 染色」
--   旧逻辑（巨人 DLC 紫色、否则灰色）。
-- ★ 现在统一用 BGCOLOURS.FULL。★ 这是 DLC 内容下线后的清理痕迹。
function TintBackground( bg )
    --if IsDLCEnabled(REIGN_OF_GIANTS) then
    --    bg:SetTint(unpack(BGCOLOURS.PURPLE))
    --else
        -- bg:SetTint(unpack(BGCOLOURS.GREY))
        bg:SetTint(unpack(BGCOLOURS.FULL))
    --end
end

-- NOTES(JBK): Keeping this for PC Steam/RAIL only for now.
-- ★★ platforms_supporting_audio_focus：一份**显式白名单**。
--   只有这四个平台在切出窗口时会静音。
-- ★★ 为什么用白名单而不是 `not IsMobile()`：
--   新增平台时，默认**不**静音（需要显式加入）。
--   ★ 这是安全默认值：漏加一个平台的代价（不静音）远小于
--     误加一个平台的代价（手机上切出去就静音，用户以为没声音）。
local platforms_supporting_audio_focus = {
    ["WIN32_STEAM"] = true,
    ["WIN32_RAIL"] = true,
    ["LINUX_STEAM"] = true,
    ["OSX_STEAM"] = true,
}

-- Global for saving game on Android focus lost event
-- ============================================================
-- OnFocusLost：★ Android 上失焦即自动存档
-- ============================================================
-- ★★★ 这是一个非常实用的移动端设计：Android 切出去（来电、切 App）
--   系统随时可能杀掉进程，所以**失焦时立刻存盘**。
--   ★ 注意它不走 SaveGame，直接调 ShardGameIndex:SaveCurrent() ——
--     说明这是一个较轻量的保存（可能只存索引与玩家数据）。
-- ★ 条件严格：必须是 ANDROID 且 inGamePlay（避免在主菜单触发）。
function OnFocusLost()
    --check that we are in gameplay, not main menu
    if PLATFORM == "ANDROID" and inGamePlay then
        SetPause(true)
        ShardGameIndex:SaveCurrent()
    end
    if platforms_supporting_audio_focus[PLATFORM] and Profile:GetMuteOnFocusLost() then
        TheMixer:SetLevel("master", 0)
    end
end

-- OnFocusGained：对称的恢复。★ 注意它只解除 SetPause，**不恢复音量**；
--   音量在下面由 Profile:GetMuteOnFocusLost() 独立控制。
function OnFocusGained()
    --check that we are in gameplay, not main menu
    if PLATFORM == "ANDROID" and inGamePlay then
        SetPause(false)
    end
    if platforms_supporting_audio_focus[PLATFORM] and Profile:GetMuteOnFocusLost() then
        TheMixer:SetLevel("master", 1)
    end
end

--============================================================
-- 【分区 29】★★★ 玩家会话 —— 存档「用户侧」的完整生命周期
--============================================================
-- ★★★ 玩家私有数据的四个动作，本文件各有一个对应函数：
--   写（分开）  SaveGame:1177  SerializeUserSession（存所有在线玩家）
--   写（单个）  savefn:1730 / OnDemoTimeout:1801 / OnNetworkDisconnect:1876
--   读（重连）  ResumeExistingUserSession（2074 行）—— 复用世界里的玩家实体
--   读（快照）  RestoreSnapshotUserSession（2099 行）—— 新建玩家实体
-- ★★ 为什么需要两种读法：
--   · 重连：世界还在，玩家实体可能还在（切后台/短暂断线）→ 复用实体，
--     灌数据即可（省一次生成，且保留位置）。
--   · 快照恢复：世界被回滚过，玩家实体不存在 → 必须从零生成（2107 行）。
-- ★ 三条写路径的共同点：★ 都在「可能发生 SimReset 之前」执行。
local function OnUserPickedCharacter(char, skin_base, clothing_body, clothing_hand, clothing_legs, clothing_feet)
-- ============================================================
-- OnUserPickedCharacter：玩家在角色选择界面确定后（本地流程）
-- ============================================================
-- ★★ 函数签名 6 个角色相关参数：char（角色名）+ 5 个皮肤槽
--   （基础皮肤、身体、手、腿、脚）。★ 皮肤被单独拆出来而不是打包，
--   是因为需要在客户端侧查 Profile 后再发给服务器（见 starting_skins）。
    local function doSpawn()
        TheFrontEnd:PopScreen()

        local starting_skins = {}
        --get the starting inventory skins and send those along to the spawn request
-- ★ GetUniquePotentialCharacterStartingInventoryItems：
--   算出该角色可能拥有的初始物品（如 wilson 的指南针）。
--   第二参数 true 的含义推测为「要包含皮肤类物品」。
        local inv_item_list = GetUniquePotentialCharacterStartingInventoryItems(char, true)

        for _, item in ipairs(inv_item_list) do
            if PREFAB_SKINS[item] then
-- ★ starting_skins：把每个初始物品对应的**上次使用的皮肤**打包发给服务器。
-- ★ 设计意图：★ 换角色重进时，物品皮肤要保持玩家上次的选择，
--   而不是回退到默认 —— 属于「体验一致性」的细节。
                local skin_name = Profile:GetLastUsedSkinForItem(item)
                starting_skins[item] = skin_name
            end
        end
-- ★★★ 技能树选择的处理：全 0 视为「未选择」，用 nil 上报。
--   ★ 为什么要归一化：服务器端用 nil 判断「该角色还没点过技能树」，
--     若上报全 0 的表，服务器会误以为「玩家选了「什么都不学」」。
--   ★ 这是「用 nil 表达『无选择』而非『空选择』」的典型处理。
        local selection = TheSkillTree:GetPlayerSkillSelection(char)
        local has_selection = false
        for _, v in ipairs(selection) do
            if v ~= 0 then
                has_selection = true
                break
            end
        end
        if not has_selection then
            selection = nil
        end

        -- FIXME(JBK): skinoverrides: Player selections from UI.
        local skinoverrides = {}
-- ⚠ 疑似缺陷（承认式 hack，作者自己标了 FIXME + HACK）：
--   wx78 的头部件动画皮肤被**硬编码**为「拥有即自动带上」。
--   ★★ 问题：玩家若手动关掉这个部件动画，刷新后会被强制打开；
--     且该物品已拥有就直接应用，不询问玩家。
--   ★ 源码注释诚实地写了两处 FIXME(JBK) 与 HACK，说明这是临时方案。
--   ★ 猜测的历史原因：该部件无法通过正常皮肤系统应用，只能走后门。
--   ⚠ 只对 wx78 生效，其他角色的 idle 动画没有类似 hack。不修改。
        if char == "wx78" and TheInventory:CheckOwnership("idleanimations_wx78_headadjust") then -- FIXME(JBK): skinoverrides: HACK
            table.insert(skinoverrides, "idleanimations_wx78_headadjust")
        end

        TheNet:SendSpawnRequestToServer(char, skin_base, clothing_body, clothing_hand, clothing_legs, clothing_feet, starting_skins, selection, skinoverrides)
    end

    TheFrontEnd:Fade(FADE_OUT, 1, doSpawn, nil, nil, "white")
end

-- ============================================================
-- ResumeRequestLoadComplete：★ 「继续游戏」请求的回调
-- ============================================================
-- ★★★ 成功时**什么都不做**（注释解释了原因）：
--   「如果成功就什么都不用做，游戏会在用户玩家数据下载完成后
--     自动激活并淡入。」⇒ 成功路径由引擎驱动。
-- ★★ 失败路径才需要手工兜底：删会话文件 + 回角色选择界面。
--   TheNet:DeleteUserSession 清理半成品会话，避免下次又失败。
function ResumeRequestLoadComplete(success)
    --If successful then don't do anything, game will automatically
    --activate and fade in once the user's player is downloaded
    if not success then
        TheNet:DeleteUserSession(TheNet:GetUserID())
        local LobbyScreen = require "screens/redux/lobbyscreen"
        TheFrontEnd:PushScreen(LobbyScreen(Profile, OnUserPickedCharacter, false))
        TheFrontEnd:Fade(FADE_IN, 1, nil, nil, nil, "white")
        TheWorld:PushEvent("entercharacterselect")
-- ★★★ 2042-2057 行是一整块被注释掉的代码（--[[ ]] 块注释）。
-- ★ 内容是「客户端本地读取会话文件以恢复合成菜单配置」。
-- ★★ 为什么被禁用：注释里没有任何说明（与本文件其他地方的风格不同）。
--   ★ 合理推断：本地会话文件在某些平台/架构下不可靠（路径权限、同步时序），
--     Klei 选择不依赖它。TheCraftingMenuProfile 因此不再从本地恢复。
-- ★ 保留注释而非删除，是留作后人参考的常见做法。
--[[
	else
		local session_file = TheNet:GetLocalClientUserSessionFile()
        if session_file then
            print("Loading Local Client Session Data from:", session_file)

            TheNet:DeserializeUserSession(session_file, function(success, str)
                if success and str ~= nil and #str > 0 then
                    local playerdata = ParseUserSessionData(str)
                    if playerdata ~= nil and playerdata.crafting_menu ~= nil then
                        TheCraftingMenuProfile:DeserializeLocalClientSessionData(playerdata.crafting_menu)
                    end
                end
            end)
        end
]]
    end
end

--============================================================
-- 【分区 29 续】★★ ParseUserSessionData —— 会话反序列化入口
--============================================================
-- ★★ 「data is raw string data from save file」—— 原始字符串（源码注释）。
-- ★★★ RunInSandboxSafe：沙盒执行并拿回返回值。
-- ★★ 为什么必须沙盒：这份数据是**从磁盘读出来的文本**，来源不可完全信任
--   （可能损坏、可能来自旧版本、理论上可能被本地文件篡改）。
--   沙盒保证它只能构造数据，不能执行危险操作。
-- ★ 参见 1016 行 —— 同一函数在 worldgenoverride 的读取处也用了。
--data is raw string data from save file
function ParseUserSessionData(data)
    local success, playerdata = RunInSandboxSafe(data)
    if success and playerdata ~= nil then
        --print(playerdata, playerdata.prefab)
        --Here we can do some validation on data and/or prefab if we want
        --e.g. Resuming a mod character without the mod loaded?
-- ★ 返回两个值：playerdata（数据表）与 prefab（角色名）。
-- ★ 为什么第二个值单独返回：调用方（2106 行）需要先判 prefab 非空才生成实体。
-- ⚠ 2066-2067 行的英文注释「这里我们可以对数据和/或 prefab 做校验，
--   比如：恢复一个没装对应模组的 mod 角色？」——
--   ★★ 这是一个**已知未实现**的校验缺口：模组被卸载后读档，
--     prefab 不存在于 Prefabs 表，SpawnPrefab 会失败（返回 nil）。
--     目前依赖 2107 行的 `if player ~= nil` 兜底，即「静默放弃恢复该玩家」。
--     后果：玩家数据没丢（文件还在），但当次不会自动进游戏。
--   属于可接受的降级，不作为缺陷。记录以便理解。
        return playerdata, playerdata.prefab
    end
    return nil, ""
end

--data is lua table
--============================================================
-- ★★★ ResumeExistingUserSession —— 玩家重连（★ 复用已有实体）
--============================================================
-- ★ 这条路径的特点：**不新建实体**，而是接管世界里已有的那个玩家实体。
--   典型场景：短暂断线重连、客户端崩溃后重连。
-- ★ 全函数用 `if TheNet:GetIsServer()` 守卫：写操作必须服务端权威。
function ResumeExistingUserSession(data, guid)
    if TheNet:GetIsServer() then
        local player = Ents[guid]
        if player ~= nil then
-- ★★★ ★★ 灌数据与解除保护的顺序（★ 关键，参见 830 行注释）：
--     ① SetPersistData 先灌数据
--     ② 再 EnableLoadingProtection
-- ★★★ 顺序为什么不能反：
--   加载保护的作用是「数据没灌完之前，不许 AI/状态图碰这个实体」
--   （否则组件会用默认值覆盖即将到来的存档值）。
--   ★ 先解除保护 ⇒ 若此时有别的系统抢先访问实体，就可能污染数据。
--   ⇒ 必须「灌完 → 再放行」。这是异步加载的标准次序纪律。
            player:SetPersistData( data.data or {} )
            player:EnableLoadingProtection()

            -- Spawn the player to last known location
-- ★★★ 金库房间的特殊处理（★ 很有意思的防卡死设计）：
--   若恢复的位置在金库房间里，把玩家挪到金库大厅中心。
--   ★★ 为什么：存档里的坐标可能是「已经离开的房间」——
--     读档时那个房间可能还没生成/已变布局。
--     若不挪走，玩家会被生成为**卡在实体内**（inaccessible），
--     表现为「读档后动不了，必须重启」。
--   ★ 这是「存档位置可能在读档瞬间变得不可用」的经典防御。
-- ★ GetVaultLobbyCenterMarker 若返回 nil，则保持原坐标不动（不做二次保护）。
			local x, y, z, platform = ResolveSaveRecordPosition(data)
            if TheWorld.Map:IsPointInVaultRoom(x, y, z) then
                local vault_lobby_center = TheWorld.components.vaultroommanager:GetVaultLobbyCenterMarker()
                if vault_lobby_center then
                    x, y, z = vault_lobby_center.Transform:GetWorldPosition()
                end
            end
-- ★ SpawnAtLocation（playerspawner 的组件方法）：真正的位置生成 + 出生流程。
--   最后参数 true 推测为「这是恢复/重生，不要走正常出生动画与提示」。
			TheWorld.components.playerspawner:SpawnAtLocation(TheWorld, player, x, y, z, true)
-- ★ 平台上再检测一次归属（与 SpawnSaveRecord 的逻辑对称）。
			if platform ~= nil then
				player.components.walkableplatformplayer:TestForPlatform()
			end

            return player.player_classified ~= nil and player.player_classified.entity or nil
        end
    end
end

--============================================================
-- ★★★ RestoreSnapshotUserSession —— 快照恢复（★ 新建实体）
--============================================================
-- ★★ 与 ResumeExistingUserSession 的核心区别：这里 **SpawnPrefab** 了
--   一个全新玩家实体（2107 行），因为世界已回滚，原实体不存在。
-- ★★ 回溯整个函数是**异步**的（DeserializeUserSession 有回调），
--   注意 return 的位置在回调**内部**（2126 行）——
--   ⇒ 该函数在异步场景下的返回值其实不可靠，调用方不应依赖它。
--   ★ 这是「回调式 API 的常见陷阱」，值得注意。
function RestoreSnapshotUserSession(sessionid, userid)
    local file = TheNet:GetUserSessionFile(sessionid, userid)
    if file ~= nil then
        print("Restoring user: "..file)
        TheNet:DeserializeUserSession(file, function(success, str)
            if success and str ~= nil and #str > 0 then
                local playerdata, prefab = ParseUserSessionData(str)
-- ★★ 三重校验：数据非空、尺寸 > 0、prefab 非空字符串。
--   GetTableSize(playerdata) > 0 排除了「空数据文件」——
--   ★ 空会话文件在服务器异常退出时可能出现，直接恢复会生成一个
--     什么都没有的空玩家（表现为「幽灵玩家」：能连接但没血没背包）。
                if playerdata ~= nil and GetTableSize(playerdata) > 0 and prefab ~= nil and prefab ~= "" then
                    local player = SpawnPrefab(prefab)
                    if player ~= nil then
-- ★★ userid 手动赋值：快照里记录了「当时是谁」，这里还原。
--   ★ is_snapshot_user_session = true —— ★ 关键标记！
--   ⇒ 它让后续逻辑知道「这个玩家是从快照恢复的」，可以采取不同的策略：
--     跳过某些欢迎流程、不重复发放初始奖励、不触发「首次登录」逻辑。
--   ★ 这是一个「来源标记（provenance tag）」的典型用法。
                        player.userid = userid
						player.is_snapshot_user_session = true
                        player:SetPersistData(playerdata.data or {})
						local x, y, z, platform = ResolveSaveRecordPosition(playerdata)
-- ⚠ 疑似缺陷（真实缺陷，值得关注）：
--   这里用 `player.Physics:Teleport(x, y, z)`，
--   而 ResumeExistingUserSession（2089 行）用的是
--   `playerspawner:SpawnAtLocation(...)`。
--   ★ 两条恢复路径用了**不同的定位方式**。Teleport 只改坐标，
--     不触发 playerspawner 的出生流程（音效、装备检查、位置合法性校验等）。
--   ★ 推理依据：这两条路径的语义本应一致（都是把玩家放回存档位置），
--     却在实现上分叉，说明至少有一条是简化过的。
--   ★ 实际后果推测：快照恢复的玩家可能缺少某些出生时初始化，
--     表现为「位置对但少了一些初始化」。不修改，仅标注。
						player.Physics:Teleport(x, y, z)
						if platform ~= nil then
							player.components.walkableplatformplayer:TestForPlatform()
-- ★★★ 这段英文注释坦承了一个**已知的困惑**（V2C 注释）：
--   「TestForPlatform 在这个上下文里做的**不是**你以为的事……
--     player:GetCurrentPlatform() 会返回意外的 nil。
--     未来或许应该重构一下，但现在先这样：」
-- ★★ 完整解读：2115 行调 TestForPlatform() 想让玩家附着到平台上，
--   但实测 GetCurrentPlatform() 仍返回 nil（附着没生效）。
--   ⇒ 作者的权宜之计是**再手动塞一个 _snapshot_platform**（2120 行），
--     这个字段会被 SpawnSaveRecord 456 行读取，用于下次快照时保留平台归属。
--   ★★ 这是「用私有字段绕过公共 API 不正确」的一个真实的坑，
--     而且与 SpawnSaveRecord:456 完全对应（同一个字段名的两个使用点）。
-- ⚠ 风险：_snapshot_platform 是私有约定，不在任何组件接口里，
--   若有人清理该字段，两处代码会静默失效。不修改。
							--V2C: TestForPlatform does NOT do what you think it does in this context...
							--     player:GetCurrentPlatform() returns unexpected nil
							--     Might consider refactoring in the future.
							--     But for now:
							player._snapshot_platform = platform
                        end
-- ★ 2122-2124 行：合成菜单配置恢复被再次注释掉（同 2042 行那块）。
--   ★ 两处都禁用，说明这是**整体废弃**的功能，不是临时开关。
						--if playerdata.crafting_menu ~= nil then
						--	TheCraftingMenuProfile:DeserializeLocalClientSessionData(playerdata.crafting_menu)
						--end

                        return player.player_classified ~= nil and player.player_classified.entity or nil
                    end
                end
            end
        end)
    end
end

--============================================================
-- 【分区 30】控制台执行 / 加载状态
--============================================================
-- ★★★ ExecuteConsoleCommand：执行任意 Lua 字符串（★ 高危接口）
-- ★★ 注意参数签名与直觉不同：第二个参数叫 guid 但实际是**实体 GUID**，
--   第三个第四个参数叫 x, z —— ★ 没有 y！
--   ★ 因为控制台命令是在 2D（XZ 平面）地图上执行的，y 由地形决定。
-- Execute arbitrary lua
function ExecuteConsoleCommand(fnstr, guid, x, z)
-- ★★★ ThePlayer 的临时改写（与 817 行 ReplicateEntity 同一手法）：
--   控制台命令常需以某个玩家身份执行（如 "giveitem" 给玩家东西），
--   所以临时把 ThePlayer 指向目标实体，执行完还原。
--   ★ 必须成对还原（2148-2150 行），否则全局状态被污染。
    local saved_ThePlayer
    if guid ~= nil then
        saved_ThePlayer = ThePlayer
        ThePlayer = guid ~= nil and Ents[guid] or nil
    end
-- ★★ overridepos：临时覆写「输入位置」，让控制台命令的坐标强制取这里。
--   `x ~= nil and z ~= nil` 双判：只有给了完整坐标才覆写，
--   否则置 nil（恢复真实位置）。
-- ⚠ 2143 行 pcall(loadstring(fnstr)) 有个细节：loadstring 返回的是函数，
--   pcall 成功时 status=true 而**函数并未被调用**（没有第二行的 fn()）。
--   ★★★ 这看起来像个缺陷：pcall 包裹 loadstring 只是校验语法，不执行。
--   ★ 推理依据：标准写法应是 `pcall(loadstring(fnstr))` 后紧跟 `()`，
--     或 `pcall(function() return loadstring(fnstr)() end)`。
--   ★ 但需谨慎：C++ 侧调用本函数时可能已经包了一层执行逻辑，
--     也可能 fnstr 本身就要求「返回函数」。无法从单文件确定。
--   ★ 标注为「存疑，需与调用方（C++/debugkeys）对照确认」。不修改。
    TheInput.overridepos = x ~= nil and z ~= nil and Vector3(x, 0, z) or nil

    local status, r = pcall(loadstring(fnstr))
    if not status then
        nolineprint(r)
    end

    if guid ~= nil then
        ThePlayer = saved_ThePlayer
    end
    TheInput.overridepos = nil
end

-- ============================================================
-- LoadingStates：加载状态枚举（★ 客户端 UI 的状态机驱动）
-- ============================================================
-- ★ 五个状态构成一条进度链：
--   None → Loading → Generating → DoneGenerating → DoneLoading
--   ★ Generating 拆成「开始生成」与「生成完毕」两态，是为了在"
--     生成完成前就能把 WorldGenScreen 弹出来显示进度条。
LoadingStates =
{
    None = 0,
    Loading = 1,
    Generating = 2,
    DoneGenerating = 3,
    DoneLoading = 4,
}

-- ============================================================
-- NotifyLoadingState：★ 服务端广播加载状态 → 客户端切界面
-- ============================================================
-- ★ 双端分发：客户端走 UI 逻辑，服务端转发给所有客户端（2196 行）。
-- ★ 服务端**自己不开界面**，只做转发 —— 职责分离。
function NotifyLoadingState(loading_state, match_results)
    if TheNet:GetIsClient() then
        --Let gamelogic know not to handle player deactivation messages
-- ★★ DeactivateWorld()：先让客户端的旧世界「失活」。
-- ★★ 注释说明了原因：「让 gamelogic 知道不要处理玩家失活消息」。
--   ★★★ 这是一个**竞态防护**：切换世界时，旧世界的 ms_playerdespawn
--     之类的事件会陆续到达客户端；若不先失活，gamelogic 会把它们
--     当成新世界的玩家事件处理 → 触发错误的 UI（死亡提示、离开提示等）。
--   ⇒ 顺序：先 DeactivateWorld（关门），再切界面。
        DeactivateWorld()
        --
-- ★★★ 两种加载界面的策略分支，由游戏模式属性 hide_worldgen_loading_screen 控制：
--   【隐藏模式】（2169-2180 行）：整个世界生成过程**不显示**任何界面，
--     直接黑屏/淡出。对「无限模式/洞穴」等快速生成的游戏更友好。
--   【显示模式】（2182-2193 行）：弹 WorldGenScreen 显示生成进度。
-- ★☆ 用 GetGameModeProperty 做特性开关 —— 游戏模式可以自带一个默认策略，
--   无需改引擎代码。这是本项目常见的扩展模式。
        if GetGameModeProperty("hide_worldgen_loading_screen") then
			if loading_state == LoadingStates.Loading then
-- ★★ 淡出时长取巧：`TheFrontEnd:GetFadeLevel() < 1 and 1 or 0`
--   —— 已经全黑（fade level 1）就**不再等**（时长 0，立即 PopScreen）；
--   否则等 1 秒淡出完成再弹窗。
--   ★ 这是「根据当前动画状态自适应等待」的实用技巧。
				TheFrontEnd:Fade(FADE_OUT, TheFrontEnd:GetFadeLevel() < 1 and 1 or 0,
					function()
						TheFrontEnd:PopScreen()
					end)
-- ★ match_results 从 JSON 解码存到 TheFrontEnd —— 对应 1493 行
--   StartNextInstance 里编码的那份（战绩卡要在加载界面显示）。
				if match_results ~= nil then
					TheFrontEnd.match_results = json.decode(match_results)
				end
				ShowLoading()
			elseif loading_state == LoadingStates.Generating or loading_state == LoadingStates.DoneGenerating then
				ShowLoading()
			end
		else
			if loading_state == LoadingStates.Loading then
				ShowLoading()
				TheFrontEnd:Fade(FADE_OUT, 1)
			elseif loading_state == LoadingStates.Generating then
-- ★★★ 一个很巧的技巧：用**临时实体 + 延迟任务**来延后 0.15 秒执行 UI 操作。
--   Why：不能直接改界面，因为当前可能还在世界初始化过程中（不安全）。
--   ★ CreateEntity():DoTaskInTime(0.15, ...) 借用了游戏实体的调度器，
--     这是本文件里反复出现的「临时实体 + 定时任务」惯用法
--     （另见 2475 行 DisplayAntiAddictionNotification）。
-- ★ 任务结束必须 `inst.entity:Retire()` 回收临时实体，否则会泄漏。
				CreateEntity():DoTaskInTime(0.15, function(inst)
					TheFrontEnd:PopScreen()
					TheFrontEnd:PushScreen(WorldGenScreen(nil, nil, nil))
					inst.entity:Retire()
				end)
			elseif loading_state == LoadingStates.DoneGenerating then
				TheFrontEnd:PopScreen()
			end
		end
    elseif TheNet:GetIsServer() then
-- ★ 服务端转发：把 match_results **编码**成 JSON 再发（网络只能传字符串）。
        TheNet:NotifyLoadingState(loading_state, json.encode(match_results))
    end
end

--============================================================
-- 【分区 31】★★★ 世界状态标签 —— 位域 + 假 base64 编码
--============================================================
-- ★★★ 这是一个**自己实现的位域压缩编码器**，用来把几十个世界进度布尔量
--   压进服务器标签（tag）字符串里。理解它是理解 DST「世界进度」的钥匙。
--
-- ★ 为什么需要它（2200 行之后的 NOTES 注释给了完整理由）：
--   「世界状态标签被合并进**一个**待解析的标签串。
--     由于服务器标签总共最多 **1024 个字符**，必须足够紧凑
--     才能支持大量标签。为此我们使用**位域**，
--     并用每个词最多 **6 位**的假 base64 编码。
--     想加自己标签系统的 mod 应当使用自己的命名空间 token。」
--
-- 【编码方案逐项拆解】：
--   ① 命名空间：形如 "WS:"，以冒号结尾，是前缀与身份标识。
--      ★ 冒号同时是**编码字符串的起始标记**（见 IsTagEncoded）。
--   ② 每个标签占 1 bit：WORDS[w] 存放第 w 个 6 位「词」里的标签。
--   ③ 每 6 个标签凑成一个「词」，用 BASE64_CHARS 里**一个字符**表示。
--      ★ 6 位 → 恰好 64 种取值 = base64 字母表的 64 个字符。
--      例：标签 A/B/C 启用 → wordvalue = 1+2+4 = 7 → BASE64_CHARS 第 8 个字符 'H'。
--   ④ 编码结果：命名空间 + 每个词一个字符，如 "WS:H"。
--   ★★ 于是「10 个世界进度标签」只占 2 个字符 + 前缀，
--     而不是 10 个长字符串 —— 1024 字符的预算能装下极多标签。
--
-- ★ 与存档的关系：世界进度标记（天体圆球是否找到等）不进存档文件，
--   而是编码进**服务器标签**，随服务器列表一起广播给客户端。
--   ⇒ 玩家在服务器列表里就能看到「这局已通关天体」等进度，无需进游戏。

-- ★ 标准 base64 字母表（含 + / 两个符号）。
-- ★ 只用到**前 64 个字符**做「假 base64」，因为单个字符只承载 6 位。
local BASE64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
-- ★ 反查表：字符 → 数值。DecodeTags（2256 行）靠它把字符还原成 wordvalue。
-- ★ 预先建表而不是每次查字符串，O(1) vs O(64)，解码时差距明显。
local BASE64_LOOKUP = {}
for i = 1, #BASE64_CHARS do
    BASE64_LOOKUP[BASE64_CHARS:sub(i, i)] = i - 1
end
-- ★ WORLDSTATE_NAMESPACES 是**双重用途**的表：
--   · 键（namespace）→ 对象，用于按名查；
--   · ★★ 还被当**数组**用（2328 行 table.insert），于是 2345 行的
--     `for _, namespace in ipairs(WORLDSTATE_NAMESPACES)` 遍历的是
--     **表内的字符串键**，而不是值！
--   ★ 这是一个「既当 map 又当 array」的技巧（Lua 表没有类型区分）。
--   ★ 副作用：可以直接 `for _, ns in pairs(WORLDSTATE_NAMESPACES)`
--     同时拿到键与值，比分开两张表更省内存。
local WORLDSTATE_NAMESPACES = {}
-- ============================================================
-- CreateWorldStateTag：创建一个命名空间的标签对象
-- ============================================================
-- ★★ 守卫条件（2208 行）：命名空间已存在 **或** 不含冒号 → 返回 nil。
--   两条规则：
--   ① 唯一性：同名不能重复创建，否则会覆盖掉已有标签表。
--   ② ★★ 必须含冒号：因为编码字符串以 namespace 开头（2237 行），
--     IsTagEncoded（2251 行）靠前缀比对来识别归属。
--     没有冒号会导致前缀冲突 —— 例如命名空间 "AB" 与 "ABC" 无法区分。
--   ★ 这是「可解析编码」的基本要求：前缀必须自终止。
function CreateWorldStateTag(namespace, atlas)
    if WORLDSTATE_NAMESPACES[namespace] or not namespace:find(":") then
        return nil
    end

-- ★ object 用 upvalue 声明（局部），稍后 2309 行才真正赋值。
--   ★ 原因：Lock()（2231 行）要把 object 的某些字段设为 nil，
--     必须等 object 存在才能操作 —— 所以所有闭包都延迟到 object 建好才调用。
    local object
    local namespacelen = #namespace

    local TAGS = {}
    local WORDS = {[1] = {},}
    local wordindex = 1
    local wordbit = 1
-- ============================================================
-- DeclareTag：声明一个新标签（分配一个 bit 位）
-- ============================================================
-- ★★★ 核心逻辑：位分配器（bit cursor）。
--   wordbit / wordindex 这对游标实现了「顺序占位」：
--     每声明一个标签，wordbit 左移一位；
--     ★★ 填满 64 后重置。
-- ⚠ 疑似缺陷（真实缺陷，值得深究）：
--   2224 行 `if wordbit == 64 then`。
--   ★ 追踪：wordbit 从 1 开始，每次 lshift 一位。
--     位序列：1, 2, 4, 8, 16, 32, **64**, 128, ...
--     ⇒ 当 wordbit 变成 64 时条件成立，重置为 1 并换词。
--     这本身是**对的**（6 个标签/词：1,2,4,8,16,32 对应第 1 到第 6 个标签），
--     第 7 个标签才启用新词。
--   ★★ 但真正的缺陷在于：**比较用 == 而不是 >=**。
--     只要某次 lshift 的结果不是恰好 64（比如因浮点精度或将来改动），
--     条件就永远不成立，wordbit 会持续增长到 128、256……
--     而 DecodeTags（2259 行）**硬编码 `for i = 1, 6`** 只解 6 位。
--     ⇒ 一旦 wordbit 越过 64 且未重置，第 7 个及之后的标签
--       写入的位**永远解不回来**（编码时会加进去，解码时那个 bit 从不被检查）。
--   ★★ 这是「编码端与解码端对位宽的隐式约定不一致」——
--     编码端靠 ==64 推断位宽，解码端靠字面量 6 硬编码。
--   ★ 两处应当共享同一个常量。当前只有 10 个标签（2357-2366 行），
--     远未触及 64，故实际不会触发。★ 属于「埋着的雷」。不修改。
    local function DeclareTag(tag)
        if TAGS[tag] == nil then
            TAGS[tag] = {bit = wordbit, enabled = false}
            table.insert(WORDS[wordindex], tag)
-- ★ wordbit = bit.lshift(wordbit, 1)：左移一位 = 下一个标签的位掩码。
            wordbit = bit.lshift(wordbit, 1)
            if wordbit == 64 then
                wordbit = 1
                wordindex = wordindex + 1
                WORDS[wordindex] = {}
            end
        end
    end
-- ============================================================
-- Lock：把对象冻结为只读
-- ============================================================
-- ★★ 为什么要「冻结」：CreateWorldStateTag 返回后，调用方拿到的是一个
--   共享的全局对象。若它能继续 DeclareTag，任何人都能在运行期往里塞标签，
--   而已生成的编码字符串不会包含新标签 —— 导致**标签被声明了却永远不生效**。
--   ⇒ 冻结 = 把「声明期」与「使用期」在类型层面分开。
-- ★ 技巧：直接从 object 上删掉方法字段（置 nil），调用时报 "attempt to call
--   a nil value"。比设置只读标志更简单也更彻底。
-- ★★ 注意 2315-2316 行的分组注释：Lock/Lock 之后列出的函数
--     才是「Lock 之后仍可安全调用」的（EncodeTags/SetTagEnabled 等）。
    local function Lock() -- Makes the object read only.
        object.DeclareTag = nil
        object.Lock = nil
    end

-- ============================================================
-- EncodeTags：状态 → 编码字符串
-- ============================================================
-- ★★ 编码算法（逐词求位或和）：
--   wordvalue = 所有启用的标签的 bit 之**和**（不是或）。
--   ★ 为什么可以用加法：每个标签占**互不相同**的位（1/2/4/8/16/32），
--     位之间不重叠，故求和 == 按位或。这是位域编码的标准前提。
--   ★ 前提由 DeclareTag 的位分配器保证（2219 行），二者是配套设计。
    local function EncodeTags() -- Returns stored stated into encoded string.
        local encoded = {namespace}
        for word = 1, wordindex do
            local wordvalue = 0
            for _, tag in ipairs(WORDS[word]) do
                local tagdata = TAGS[tag]
                if tagdata.enabled then
                    wordvalue = wordvalue + tagdata.bit
                end
            end
-- ★★★ wordvalue + 1：★ 这里有个容易看错的 +1。
--   BASE64_CHARS 的下标从 **1** 开始，而 wordvalue 的范围是 **0-63**。
--   ⇒ wordvalue=0（无标签启用）→ 下标 1 → 字符 'A'；
--     wordvalue=63（6 位全开）→ 下标 64 → 字符 '/'。
--   ★ 这正是「假 base64」的映射：字符位序即 6 位取值。
            table.insert(encoded, BASE64_CHARS:sub(wordvalue + 1, wordvalue + 1))
        end
        return table.concat(encoded)
    end
-- ============================================================
-- IsTagEncoded：判断一个编码串是否属于本命名空间
-- ============================================================
-- ★★ 只比对**前缀**（前 namespacelen 个字符）。
--   ★ 效率考虑：解码时要对每个命名空间都试一次，前缀比对是 O(len)。
-- ⚠ 潜在局限：只要前缀匹配就返回 true，不校验后续字符合法性。
--   若某命名空间是另一个的前缀（如 "W:" 与 "WS:"），短的可能被误判。
--   ★ 这就是 2208 行强制要求「必须含冒号」的价值：冒号保证了"
--     前缀互不包含（"WS:" 不可能是 "WS:FOO:" 的前缀，反之亦然）。
--   当前只有 "WS:" 一个命名空间，暂无问题。记录该设计约束。
    local function IsTagEncoded(encoded_maybe)
        return encoded_maybe:sub(1, namespacelen) == namespace
    end
-- ============================================================
-- DecodeTags：编码字符串 → 状态（★ 带 merge 选项）
-- ============================================================
-- ★★★ merge 参数的意义（★ 这是一个容易被忽略的语义）：
--   merge = false → 完全覆盖：编码里没出现的标签被**置为 false**；
--   merge = true  → 合并：编码里是 0 的标签**保持原值**。
-- ★ 2263 行 `enabled or (merge and object.GetTagEnabled(tag)) or false`
--   就是这个语义的全部实现。
-- ★★ 用途：多来源的世界进度（如主世界 + 洞穴的进度）可以叠加，
--     用 merge 逐个 DecodeTags 而不必担心互相覆盖。
-- ⚠ 注意 2263 行里的 `and` / `or` 链依赖 Lua 的短路语义，
--   若 GetTagEnabled 返回 false，则后半段为 false，最终结果是 false —— 正确。
--   但若某标签值为 nil（未声明就被访问），`TAGS[tag].enabled`（2276 行）
--   会报 nil 索引错误。⇒ 对未声明的标签调用 DecodeTags 是危险的。不修改。
    local function DecodeTags(encoded, merge) -- Writes encoded string into stored state with an optional merging of the current state.
        if object.IsTagEncoded(encoded) then
            for word = 1, wordindex do
-- ★★ `BASE64_LOOKUP[...] or 0`：字符查不到时**兜底为 0**。
--   ★ 意义：即使编码串被截断（末尾少一个字符），后面的词按「无标签」处理，
--     不会崩溃。这是一种「宽容解码」策略。
                local wordvalue = BASE64_LOOKUP[encoded:sub(word + namespacelen, word + namespacelen)] or 0
                local tags = WORDS[word]
                local wordbit = 1
-- ⚠ 前面 2224 行埋的雷在此显形：`for i = 1, 6` 是**硬编码的位宽**。
--   ★ 它必须与 DeclareTag 的「6 位一词」规则严格一致，
--     但两处没有任何共享常量或断言保护。
--   ★ 另：`local tags = WORDS[word]` 可能为 nil（编码串比实际词数长时），
--     此时 `tags[i]` 会报错。⇒ 截断的编码串在此仍可能出错。不修改。
                for i = 1, 6 do
                    local tag = tags[i]
                    if tag then
                        local enabled = bit.band(wordvalue, wordbit) ~= 0
                        object.SetTagEnabled(tag, enabled or (merge and object.GetTagEnabled(tag)) or false)
                        wordbit = bit.lshift(wordbit, 1)
                    else
                        break
                    end
                end
            end
-- ★★ 解码后立刻上报（仅主机）：UpdateServerTagsString()。
--   ★ 让服务器列表里的标签立即刷新 —— 用户能看到「进度刚被改变」。
--   ⚠ 注意 DecodeTags 里这个调用**没有 donotupdate 参数**的等价物，
--     与 SetTagEnabled 的设计不对称：解码是批量操作，调用一次即可。
            if TheNet:GetIsHosting() then
                UpdateServerTagsString()
            end
        end
    end
-- ============================================================
-- SetTagEnabled：设置单个标签
-- ============================================================
-- ★★★ 三层守卫，逐层收紧：
--   ① 值没变就不做任何事（2276 行）—— 避免无谓的网络与文件写。
--   ② 只有**主机**才继续（2278 行）—— 客户端无权改世界状态。
--   ③ ★ 分片架构：非主分片要 RPC 通知主分片（2282-2284 行）。
--     ★★ 注释解释了原因：「总是更新主分片，这样服务器列表上的标签才能更新。」
--   ★⇒ 世界进度可以发生在任何分片上（如洞穴分片发现天体），
--     但**服务器列表只有主分片负责**，所以必须同步过去。
    local function SetTagEnabled(tag, enabled, donotupdate)
        if TAGS[tag].enabled ~= enabled then
            TAGS[tag].enabled = enabled
            if TheNet:GetIsHosting() then
                if not donotupdate then
                    UpdateServerTagsString()
                end
                if not Shard_IsMaster() then -- Always update the master shard so tags can be updated on the server listing.
                    SendRPCToShard(SHARD_RPC.SyncWorldStateTag, SHARDID.MASTER, namespace, tag, enabled)
                end
            end
        end
    end
    local function GetTagEnabled(tag)
        return TAGS[tag].enabled
    end
-- ============================================================
-- ClearAllTags：全部清空
-- ============================================================
-- ★★★ 一个非常巧妙的实现：`object.DecodeTags(namespace)`。
--   ★ 传「只有命名空间、没有词」的裸串进去：
--     IsTagEncoded 通过（前缀匹配）；
--     每个词的字符都是空串 → BASE64_LOOKUP[""] = nil → or 0 → 全 0；
--     ⇒ 所有标签被置为 false。
--   ★★ 即「用解码一个空编码来达到清空」，避免了写一个独立的清空循环。
--   ★ 这是「把编码当作唯一真相来源」的优雅体现。
    local function ClearAllTags()
        object.DecodeTags(namespace)
    end
-- ForEachTag / DebugPrintTags：遍历与调试打印（★ 注意用 ipairs 而非 pairs）
-- ★ 这里必须用 ipairs：**遍历 WORDS 里的标签列表**是有序数组。
    local function ForEachTag(fn)
        for word = 1, wordindex do
            for _, tag in ipairs(WORDS[word]) do
                fn(tag)
            end
        end
    end

    local function DebugPrintTags()
        print("WorldStateTags for namespace", namespace)
        object.ForEachTag(function(tag)
            print(">", tag, object.GetTagEnabled(tag))
        end)
    end

-- ★★★ 闭包对象表：★ 2304-2306 与 2313-2325 的分组注释是本函数的设计核心。
--   2315-2316 行注释写着「Safe from Lock functions.」（Lock 之后仍安全），
--   ⇒ 凡是**会改变编码结果**的操作（DeclareTag/Lock）必须在 Lock 前定义完，
--     其余（编码/解码/查询）可以一直用。
-- ★ 这就是「冻结只关闭写入口，不关闭读入口」的具体实现。
    object = {
        namespace = namespace, -- Read only reference.
-- ★★ namespace_nocolon = namespace:sub(1, -2)：去掉末尾冒号。
--   ★ 用途注释明说是「For STRINGS use」—— 即查本地化字符串表时
--     用不带冒号的 key。因为命名空间 "WS:" 是编程用的，
--     而 UI 显示的名字要用可翻译的字符串。
--   ★ 两种命名空间表示法并存，是「内部标识 vs 外部展示」的分离。
        namespace_nocolon = namespace:sub(1, -2), -- For STRINGS use.
        atlas = atlas,
        -- Functions.
        DeclareTag = DeclareTag,
        Lock = Lock,
        -- Safe from Lock functions.
        EncodeTags = EncodeTags,
        IsTagEncoded = IsTagEncoded,
        DecodeTags = DecodeTags,
        SetTagEnabled = SetTagEnabled,
        GetTagEnabled = GetTagEnabled,
        ClearAllTags = ClearAllTags,
        ForEachTag = ForEachTag,
        -- Debug.
        DebugPrintTags = DebugPrintTags,
    }
-- ★ 同时登记进 map（2327）与 array（2328）—— 见 2206 行的双重用途说明。
    WORLDSTATE_NAMESPACES[namespace] = object
    table.insert(WORLDSTATE_NAMESPACES, namespace)

    return object
end
-- ============================================================
-- 查询辅助：按命名空间 / 按标签反查 / 遍历全部
-- ============================================================
-- ★ GetWorldStateTagObjectFromTag（2335 行）是**反查**：给一个标签串，
--   找出它属于哪个命名空间的对象。供 2381 行「合并分片标签」时去重。
function GetWorldStateTagObjectFromNamespace(namespace)
    return WORLDSTATE_NAMESPACES[namespace]
end
function GetWorldStateTagObjectFromTag(tag)
    for _, namespace in ipairs(WORLDSTATE_NAMESPACES) do
        local worldstatetagobject = GetWorldStateTagObjectFromNamespace(namespace)
        if worldstatetagobject.IsTagEncoded(tag) then
            return worldstatetagobject
        end
    end
    return nil
end
function ForEachWorldStateTagObject(fn, ...)
    for _, namespace in ipairs(WORLDSTATE_NAMESPACES) do
        local worldstatetagobject = GetWorldStateTagObjectFromNamespace(namespace)
        fn(worldstatetagobject, ...)
    end
end

-- ★★★★ 上面 2351-2354 行的 NOTES 注释是整个编码方案的设计文档，
--   已完整翻译在分区 31 的开头。逐条强调：
--   ★ 「服务器标签最多 1024 字符」—— 硬预算，编码方案存在的根本原因。
--   ★ 「每个词最多 6 位」—— 决定了为什么用 base64 字母表（2^6=64）。
--   ★ 「mod 想加自己的标签系统应当用自己的命名空间」——
--     这是给 mod 作者的**明确契约**：不要往 "WS:" 里塞私有标签，
--     否则会与官方标签抢位（第 7 位之后就会冲突，见 2224 行的雷）。
-- NOTES(JBK): World state tags are combined into one tag string that is parsed.
-- Since server tags has a maximum of 1024 characters total this should be compact to support many tags.
-- For this we will use a bit field and encode the tag with a fake base64 encoding of 6 bits per word max.
-- For mods that want to add their own world state tag system they should use their own namespace token.
-- ★★ 官方命名空间 "WS:" 与其配套的 XML（atlas = 图集资源，用于 UI 图标）。
--   ★ atlas 字段说明这些标签在 UI 上有对应图标（如天体圆球图标）。
--   ★★ 2357-2367 行是全部官方标签的声明 —— 这就是**世界进度的完整清单**：
--     -- 森林 --
--     CELESTIAL_ORB_FOUND   天体圆球已获得
--     CELESTIAL_PORTAL_BUILT 天体传送门已建造
--     CRABBY_HERMIT_HAPPY   蟹老板开心（好感度）
--     LUNAR_RIFTS_ACTIVE     月裂
--     -- 洞穴 --
--     ATRIUM_KEY_FOUND       中庭钥匙
--     ARCHIVES_ENERGIZED     档案已充能
--     SHADOW_RIFTS_ACTIVE    暗影裂隙
-- ★★ 注意：这些是**世界级**进度（与具体玩家无关），所以放世界标签而非存档。
WORLDSTATETAGS = CreateWorldStateTag("WS:", "images/worldprogressionfilters.xml") -- This namespace is reserved for the base game.
-- Forest.
WORLDSTATETAGS.DeclareTag("CELESTIAL_ORB_FOUND")
WORLDSTATETAGS.DeclareTag("CELESTIAL_PORTAL_BUILT")
WORLDSTATETAGS.DeclareTag("CRABBY_HERMIT_HAPPY")
WORLDSTATETAGS.DeclareTag("LUNAR_RIFTS_ACTIVE")
-- Caves.
WORLDSTATETAGS.DeclareTag("ATRIUM_KEY_FOUND")
-- ★ 被注释掉的空标签声明 + FIXME 注释：
--   「这里有个 CELESTIAL_PORTAL_BUILT 的东西就好了（给洞穴用）。」
-- ★★ 值得注意：★**注释掉 DeclareTag 并不会释放它占用的位**？
--   会释放 —— 因为它压根没执行过（注释是纯文本，不参与运行）。
--   但★ 若将来有人取消注释，标签会占用下一个可用位（ATRIUM 之后），
--   改变后续标签的位号。★ 这不影响兼容性，因为编码是自描述的
--   （同一版本内编解码一致），但**跨版本**时位号变化会导致：
--   旧存档/旧服务器列表里的标签串被新版本误解。
--   ★⇒ 因此注释里的 FIXME 其实隐含了一个约束：
--     ★★ 世界状态标签的**声明顺序必须保持稳定**，只能在末尾追加。
--   ⚠ 这是一个未被文档化的脆弱点，记录下来。不修改。
--WORLDSTATETAGS.DeclareTag("") -- FIXME(JBK): It would be nice for a CELESTIAL_PORTAL_BUILT thing here for caves.
WORLDSTATETAGS.DeclareTag("ARCHIVES_ENERGIZED")
WORLDSTATETAGS.DeclareTag("SHADOW_RIFTS_ACTIVE")
-- ★ 同样被注释掉的 VAULT_KEY_FOUND + FIXME(rifts7: 金库钥匙进度标记)。
--   ★ 说明「计划中的标签」被保留为注释，是作者的常见做法。
-- WORLDSTATETAGS.DeclareTag("VAULT_KEY_FOUND") -- FIXME(JBK): rifts7: Vault key progress flag.
-- ★★ WORLDSTATETAGS.Lock() —— ★★★ 官方标签在此冻结。
--   ★★★ 这是**极其关键**的一行。调用它意味着：
--     ① 位分配已定稿，从现在起任何 DeclareTag 调用都会报错；
--     ② ★ 编码结果从此固定，服务器列表里的标签串永久有效。
--   ★★★ 为什么必须在文件加载时就 Lock（而不是按需或运行期）：
--     服务器标签要在**游戏开始前**就发给客户端（大厅里就能看到进度），
--     那时必须已经有确定的编码。若运行期还能加标签，
--     已经发出的标签串就与新状态不一致了。
--   ⇒ ★ 声明期与广播期必须在同一进程内、加载期完成。
WORLDSTATETAGS.Lock()


--============================================================
-- BuildTagsStringCommon：★★ 组装最终的服务器标签串
--============================================================
-- ★★ 四类来源 + 三步处理，顺序很重要：
--   来源：① 投票标签 ② 分片标签（合并）③ 模组标签 ④ 测试标签 ⑤ 语言标签
function BuildTagsStringCommon(tagsTable)
    -- Vote command tags (controlled by master server only)
-- ★ 投票标签只由**主服务器**控制，且要玩家开启了该投票设置。
    if not TheShard:IsSecondary() and TheNet:GetDefaultVoteEnabled() then
        table.insert(tagsTable, STRINGS.TAGS.VOTE)
    end

-- ★★ 只有主分片负责合并其它分片的标签（避免每个分片都发一遍）。
--   ★ 分片标签用逗号分隔（2380 行 v.tags:split(",")），
--     ★ 而世界状态标签是「前缀+base64」的单块（无需分隔，因其自描述）。
--   ★ 两种编码共存于同一个字符串，靠 IsTagEncoded 的前缀判断区分。
    if TheShard:IsMaster() then
        -- Merge secondary shard tags
        for k, v in pairs(Shard_GetConnectedShards()) do
            if v.tags ~= nil then
                for i, tag in ipairs(v.tags:split(",")) do
-- ★★ 去重关键：分片带来的标签若**已经是世界状态标签**，就跳过。
--   ★ 为什么需要？分片的标签串可能包含主分片已有的世界状态标签，
--     直接塞进列表会造成标签重复（服务器列表会显示两遍）。
                    if not GetWorldStateTagObjectFromTag(tag) then
                        table.insert(tagsTable, tag)
                    end
                end
            end
        end
    end

    -- Mods tags
    for i, mod_tag in ipairs(KnownModIndex:GetEnabledModTags()) do
        table.insert(tagsTable, mod_tag)
    end

    -- Beta tag (forced to front of list)
-- ★★★ 两个细节：
--   ① 测试分支（BETA）标签被**连续两次插到表头**（2396-2397 行），
--      结果是 [publicBeta, currentBeta, ...原有标签...]。
--   ② ★★ 2400-2401 行注释极其重要：
--      「语言标签强制放在列表首位，**不要在槽位 1 放别的东西**，
--        否则语言检测会失败！」
--   ★★ 这是一个**位置即语义**的设计：客户端靠「第一个标签是语言」
--     来自动选择界面语言。因此构建顺序是**协议的一部分**，不能改。
    if BRANCH == "staging" and CURRENT_BETA > 0 then
        table.insert(tagsTable, 1, BETA_INFO[CURRENT_BETA].SERVERTAG)
        table.insert(tagsTable, 1, BETA_INFO[PUBLIC_BETA].SERVERTAG)
    end

    -- Language tag (forced to front of list, don't put anything else at slot 1, or language detection will fail!)
-- ★★ 这行紧跟上面的警告：`table.insert(tagsTable, 1, 语言)`。
--   ★ 必须放在最后一步（所有其他来源都插完之后），否则会被别人挤走。
--   ★ 注意 `or ""`：语言表里查不到时插空串，配合 2409 行的空值过滤。
    table.insert(tagsTable, 1, STRINGS.PRETRANSLATED.LANGUAGES[LOC.GetLanguage()] or "")

-- ============================================================
-- 去重拼接（★ 逗号分隔，★ 大小写统一 + 去空白）
-- ============================================================
-- ★★ 2408 行三重处理：`v:lower():match("^%s*(.-%S)%s*$") or ""`
--   · :lower()      —— 统一小写（服务器标签大小写不敏感）
--   · :match(...)   —— 去掉首尾空白
--   · or ""        —— 全空白的结果转成空串
-- ★★ 2409-2412 行：跳过空串、跳过重复、避免以逗号开头。
--   `tagsString:len() > 0 and (tagsString..","..v) or v`
--   ★ 这是 Lua 里拼 CSV 的惯用法：首个元素不加逗号。
    -- Concat unique tags
    local tagged = {}
    local tagsString = ""
    for i, v in ipairs(tagsTable) do
        --trim whitespace
        v = v:lower():match("^%s*(.-%S)%s*$") or ""
        if v:len() > 0 and not tagged[v] then
            tagged[v] = true
            tagsString = tagsString:len() > 0 and (tagsString..","..v) or v
        end
    end

-- ★★★ 世界状态标签被**前置**（拼在最前面），而语言标签在槽位 1。
--   ⚠ 疑似缺陷（真实缺陷，但影响面小）：
--     2418 行 `tagsString = worldstatetagobject.EncodeTags() .. "," .. tagsString`
--     ★★ 当 WORLDSTATETAGS 为空串时（即所有标签都未启用，EncodeTags 返回
--       "WS:"），结果会变成 "WS:," + 原有标签 —— **多出一个空标签**。
--     客户端按逗号 split 后会得到一个空串元素。
--   ★ 推理依据：EncodeTags 即使全 false 也会输出命名空间本身（2237 行
--     `local encoded = {namespace}` 无条件先放命名空间），
--     所以 EncodeTags() 至少返回 "WS:"，恒不为空串。
--     ⇒ 本行的 `..","..` 前置逻辑**永远会产生至少一个逗号**。
--   ★ 实际影响：服务器列表多显示一个空标签，多数客户端 split 后忽略空串，
--     故不致命；但严格解析的第三方工具可能报错。不修改。
    if Shard_IsMaster() then
        for _, namespace in ipairs(WORLDSTATE_NAMESPACES) do
            local worldstatetagobject = GetWorldStateTagObjectFromNamespace(namespace)
            tagsString = worldstatetagobject.EncodeTags() .. "," .. tagsString
        end
    end

    return tagsString
end

-- ============================================================
-- SaveAndShutdown：★ 「保存并退出」的正式入口
-- ============================================================
-- ★★★ 与 savefn（1718 行）的区别：
--   SaveAndShutdown 的成功回调是**直接 Shutdown**（1543 行那个），
--   而 savefn 的回调是 postsavefn（会重启）。
--   ⇒ 一个「退出游戏」，一个「重启游戏」。
-- ★ 守卫：`if not TheWorld then return end` —— 无世界时什么都不做。
-- ★ 主体与 savefn 的主 sim 分支完全相同（1722-1728 行 vs 2430-2434 行），
--   属于复制粘贴。不修改。
function SaveAndShutdown()
    if not TheWorld then
        return
    end
    if TheWorld.ismastersim then
        for i, v in ipairs(AllPlayers) do
            v:OnDespawn()
        end
        TheSystemService:EnableStorage(true)
        ShardGameIndex:SaveCurrent(Shutdown, true)
    end
end

-- ============================================================
-- IsInFrontEnd：判断是否在前端（主菜单）
-- ============================================================
-- ★★ 判据：`reset_action == nil 或 == LOAD_FRONTEND`。
--   ★ 为什么要看 reset_action（而不是一个布尔标志）：
--     reset_action 是**上一个实例**传来的意图（1511 行 SimReset 携带），
--     它是判断「本次启动为什么而发生」的权威依据。
--   ★★ 这是「用『意图』而非『状态』判断」的典范：状态可能是多义的，
--     而意图唯一。
function IsInFrontEnd()
	return Settings.reset_action == nil or Settings.reset_action == RESET_ACTION.LOAD_FRONTEND
end

-- ============================================================
-- CreateRepeatedSoundVolumeReduction：重复音效的降噪闭包工厂
-- ============================================================
-- ★★★ 闭包工厂模式：返回一个函数，闭包内保存 last_played_time。
-- ★ 用途（三个实例见 2459-2461 行）：鼠标悬停音效在快速划过菜单时会连成一片
--   刺耳噪音，于是「短时间内重复触发就降低音量」。
-- ★★ 设计要点：
--   · 参数 copy 成 lower_sound_repeat_time / reduced_volume_percent（2444-45 行）
--     ★ 为什么？防止调用方后续修改变量导致行为突变（闭包捕获引用而非值）。
--   · 先判断后更新 last_played_time（2450-2454 行）—— 顺序不能反。
-- ★ 返回值是音量系数（1.0 或降低后的值），由调用方乘到音效上。
function CreateRepeatedSoundVolumeReduction(repeat_time, lowered_volume_percent)
    local last_played_time = GetTime()
    local lower_sound_repeat_time = repeat_time
    local reduced_volume_percent = lowered_volume_percent
    return function()
        local current_time = GetTime()

        local sound_volume = 1
        if current_time - last_played_time <= lower_sound_repeat_time then
            sound_volume = reduced_volume_percent
        end

        last_played_time = current_time
        return sound_volume
    end
end

-- ★★★ 三个全局降噪器，**阈值与降量成对定义**（逐行对照）：
--   ClickMouseoverSoundReduction       0.25 秒内重复 → 0.75 音量（最敏感）
--   LuckSoundReduction                 0.75 秒内重复 → 0.50 音量（注释写 0.5，
--                                        代码是 0.75 秒 —— 见下方 ⚠）
--   UpgradeModuleMouseoverSoundReduction 1.0 秒内重复 → 0.65 音量（最宽松）
-- ⚠ 疑似缺陷（文档与代码不符，极轻微）：
--   2460 行注释写「if fired in the last 0.5 seconds, reduce the volume to 50%」，
--   但代码第一个参数是 **0.75**（重复判定窗口），而**音量是 0.50**（符合注释）。
--   ★ 即注释的「0.5 seconds」与实际的 0.75 矛盾 —— 应是注释笔误或参数调整后
--     未同步更新注释。音量 0.50 与注释一致，故只有时间窗口对不上。不修改。
ClickMouseoverSoundReduction = CreateRepeatedSoundVolumeReduction(0.25, 0.75) --if fired in the last 0.25 seconds, reduce the volume to 75%
LuckSoundReduction = CreateRepeatedSoundVolumeReduction(0.75, 0.50) --if fired in the last 0.5 seconds, reduce the volume to 50%
UpgradeModuleMouseoverSoundReduction = CreateRepeatedSoundVolumeReduction(1.0, 0.65) --if fired in the last 1.0 seconds, reduce the volume to 65%

--============================================================
-- 【分区 33】防沉迷通知 / 被忽略的 shell 命令
--============================================================
local currently_displaying = nil
-- ============================================================
-- DisplayAntiAddictionNotification：防沉迷提示
-- ============================================================
-- ★★ 去重（2465 行）：`notification ~= currently_displaying` 才显示。
--   ★ 防止同一个通知被服务端反复推送，导致屏幕上堆满文字。
-- ★ 创建裸 Text widget 挂到屏幕上（无需 TheFrontEnd 屏幕栈）。
function DisplayAntiAddictionNotification( notification )
    if notification ~= currently_displaying then
        local Text = require "widgets/text"
        local title = Text(CHATFONT_OUTLINE, 35)
        title:SetString(STRINGS.ANTIADDICTION[notification])
        title:SetPosition(0, -50, 0)
        title:Show()
        title:SetVAnchor(ANCHOR_TOP)
        title:SetHAnchor(ANCHOR_MIDDLE)
        currently_displaying = notification

-- ★ 10.5 秒后自动清除（2475 行）+ 回收临时实体。
--   ★ 与 2186 行同一惯用法：CreateEntity():DoTaskInTime 做延时清理。
-- ⚠ 轻微风险：若此时**正在关服/切实例**，回调可能不执行，
--   字体会泄漏到下一次会话（表现为残留文字）。因 widget 随屏幕栈销毁，
--   实际影响很小。不修改。
        CreateEntity():DoTaskInTime(10.5, function(inst)
            title:Kill()
            inst.entity:Retire()
            currently_displaying = nil
        end)
    end
end

-- ============================================================
-- 被忽略的 shell 命令（★ 平台/测试相关的空实现）
-- ============================================================
-- ★ RCINIL = 「RC 接口的空实现」，赋给三个 RCI* 全局。
--   ★ 含义：某些平台（如主机）没有这些 shell 能力，
--     用空函数占位，让通用代码不必到处做平台判断。
--   ★ 这是一种「null object」模式：用合法但无效的实现替代 null 检查。
--shell commands that are ignored
local RCINIL = function() end
RCITimeout = RCINIL
RCIFileLock = RCINIL
RCIFileUnlock = RCINIL

require("dlcsupport")

-- ============================================================
-- ShowBadHashUI：databundle 损坏时弹窗
-- ============================================================
-- ★★ 状态机守卫（2492 行）：只有 HashesMessageState == "SHOW_WARNING"
--   才弹。★ 其它状态（"MISSING_HASHES"、"CHOSE_TO_PLAY_ANYWAY"、
--   "MISSING_DATABUNDLES"）都不弹 —— 见 2545 行 DataBundleFileHashes 的赋值。
-- ★ 这是一个「由校验结果驱动的单向弹窗」，且天然只弹一次
--   （2496 行立刻把状态改成 "SHOWING_POPUP"）。
function ShowBadHashUI()
    if HashesMessageState ~= "SHOW_WARNING" then
        return
    end
-- ★ 英文注释解释了**产品决策**：「后端不希望在游戏客户端不稳定时看到错误。」
--   ⇒ 这是「玩家体验优先于后端可观测性」的一个明确取舍。
    -- Backend does not want to see errors when a game client is in an unstable state.
    HashesMessageState = "SHOWING_POPUP"
    --TheNet:SetQuietBackendErrorsReason(HashesMessageState) We faked the HashesMessageState prior to this callback.

    SetGlobalErrorWidget(STRINGS.UI.MAINSCREEN.BAD_HASHES_TITLE, STRINGS.UI.MAINSCREEN.BAD_HASHES_BODY, {
        {
            text = STRINGS.UI.MAINSCREEN.BAD_HASHES_PLAY,
            cb = function()
-- ★★★ 「还是继续玩」按钮：把状态改为 CHOSE_TO_PLAY_ANYWAY 并上报后端。
--   ★ 英文注释再次强调「尤其后端不希望玩家选择继续玩时"
--     那些格式错误的后端请求造成错误弹窗。」
--   ⇒ 即使玩家明知状态不稳定也要玩，也**不**记录为后端错误。
--   ★ 这个取舍让后端统计不被「已知可忽略的错误」污染。
                -- Backend especially does not want to see errors when a player chooses to play anyway with an unstable game state.
                HashesMessageState = "CHOSE_TO_PLAY_ANYWAY"
                TheNet:SetQuietBackendErrorsReason(HashesMessageState)
                global_error_widget:GoAway()
            end
        },{
            text = STRINGS.UI.MAINSCREEN.BAD_HASHES_INSTRUCTIONS,
            cb = function()
                VisitURL("https://support.klei.com/hc/en-us/articles/360029555352-DST-Is-Crashing-DST-Won-t-Start")
            end
        },{
            text = STRINGS.UI.MAINSCREEN.ASKQUIT,
            cb = function()
                RequestShutdown()
            end
        },
    })
end

--============================================================
-- 【分区 35】★★ 登录流同步 + 完整性校验
--============================================================
-- ★★ 这一整段解决的是「客户端文件被篡改/损坏」的问题（联机必备）：
--   ① BeginDataBundleFileHashes —— 校验开始，**关掉登录按钮**
--   ② DataBundleFileHashes —— 校验回调，比对哈希，决定弹不弹窗
-- ★ 核心目标：★「让游戏能同步地等待校验完成后再开始登录流程」
--   —— 否则客户端可能在文件还没校验完时就连上服务器，导致资源错误。
-- Login flow sync.
-- ★ login_button 是模块级状态（闭包共享），由 2534 行的注入函数设置。
-- ★★ 为什么用「hook 一个按钮」而不是全局禁用：
--   登录按钮在不同平台/界面下由不同代码创建，
--   让它们主动上报按钮实例（HookLoginButtonForDataBundleFileHashes），
--   比在别处硬找按钮更解耦。
local login_button = nil
local function TurnOffLoginButton()
    if login_button then
        login_button:_TurnOff()
    end
end
local function TurnOnLoginButton()
    if login_button then
        login_button:_TurnOn()
    end
end
-- ============================================================
-- HookLoginButtonForDataBundleFileHashes：注入登录按钮
-- ============================================================
-- ★ 只记录引用（login_button = button），不做别的。
--   ★ 名字很长但很明确 —— 用「做什么+给谁用」命名，便于搜索。
function HookLoginButtonForDataBundleFileHashes(button)
    login_button = button
end

-- Integrity check callbacks.
-- ============================================================
-- BeginDataBundleFileHashes：校验开始
-- ============================================================
-- ★★ 英文注释是关键：「完整性检查器正在运行，这里用它让游戏"
--   尽量同步地等待其完成后才开始登录流程。」
--   IsIntegrityChecking = true 供其他代码查询「现在正在校验」。
-- ★ TurnOffLoginButton：★ 先禁用在文件校验完成前禁止玩家登录，
--   否则用损坏的资源连接服务器会得到难以诊断的崩溃。
function BeginDataBundleFileHashes()
    -- The integrity checker is running things use this to let the game try to be synchronous and wait for its completion before login flow starts.
    IsIntegrityChecking = true
    TurnOffLoginButton()
end

-- ============================================================
-- ★★ DataBundleFileHashes：校验回调（本文件最后的大函数）
-- ============================================================
-- ★★★★ 2550 行英文注释交代了这项检查的**存在理由**（非常清晰）：
--   「作为**通用**完整性检查，以防平台未能正确修补
--     data/databundles/*.zip 里的文件。
--     一般来说游戏本体总是能成功修补的，但有时 databundle 不能。
--     这样做是希望玩家能在加载世界或游玩时遇到问题**之前**自行解决。
--     若玩家选择继续玩，我们不希望来自格式错误的后端请求
--       冒出更难以调试的错误弹窗。
--     这个函数目前只为允许宏 DO_GAMEFILE_INTEGRITY_CHECKS 的平台调用。」
-- ★★ 三层含义：① 检查平台补丁失败 ② 让玩家自助修复 ③ 保护后端
function DataBundleFileHashes(calculatedhashes)
    -- NOTES(JBK): General integrity check in case the platform did not patch the files in data/databundles/*.zip properly.
    -- Generally the game binary always succeeds in patching and sometimes the databundles do not.
    -- This is made in the hope that players will be able to self serve a fix before experiencing issues when loading a game world or inside a game world.
    -- If a player chooses to play anyway we do not want to see errors pop up from malformed backend requests that are harder to debug.
    -- This function is only currently being called for platforms that allow the macro DO_GAMEFILE_INTEGRITY_CHECKS.
-- ★ 置 nil 表示「校验结束」。注释强调："This is the response we are done here."
--   （这就是「我们到此结束」的信号）—— 一个明确的生命周期结束标记。
    IsIntegrityChecking = nil -- This is the response we are done here.
    TurnOnLoginButton()
    login_button = nil
-- ★★★ 用 io.open 直接读文件 —— 这是本文件**少见的直接文件 IO**。
--   ★ 几乎所有存档 IO 都走 TheSim（本文件 18-46 行的持久化字符串等），
--     这里用标准 io 是因为要读的是**游戏安装目录内**的固定文件。
-- ★ 为什么不在模拟器沙盒里做：databundles 在沙盒之外。
    local hashesfile = io.open("databundles/hashes.txt", "r")
-- ★ 没有哈希文件 → 静默 bail out，并上报 "MISSING_HASHES"。
--   ★ 注意：**不弹窗**（只有 SHOW_WARNING 才弹，见 2492 行）。
--   ★ 因为没有参考哈希就无从判断对错，弹窗只会困扰玩家。
    if hashesfile == nil then
        -- No hash file to do basic checks with bail out and quiet backend errors.
        HashesMessageState = "MISSING_HASHES"
        TheNet:SetQuietBackendErrorsReason(HashesMessageState)
        return
    end

-- ★★★ 逐行解析 hashes.txt：格式为「文件名 空格 哈希」。
--   ★ pattern `"^(.+) (.-)$"` 用**贪婪 + 非贪婪**组合：
--     · (.+) 贪婪吃掉尽可能多 → 文件名（含路径，不含最后一个空格前的内容）
--     · (.-) 非贪婪 + $ 锚定 → 哈希（可含空格，因为 .+ 已吃掉分隔空格）
--   ★ 这个正则是为了兼容「哈希串里含空格」的情况。
    for line in hashesfile:lines() do
        local filename, hash = line:match("^(.+) (.-)$")
        if filename and hash then
-- ★★★ 2565-2566 行是两个防御性清洗，**看起来多余但实际必需**：
--   ① gsub("[\r\n]", "") —— ★ 注释自己承认：「移除上面那个过度延展"
--     的模式可能带进来的任何换行符」。
--     ★★ 推理：`(.-)$` 中 . 也能匹配 \n（Lua 的 . 不排除换行），
--       所以哈希可能带上文件末尾的换行符。Windows 上尤其容易出问题。
--       ⇒ 这是「先修正则、后清洗」的正确示范。
--   ② gsub("\\", "/") —— 统一路径分隔符。
--     ★ 原因：Windows 用反斜杠，校验时两边可能不一致。
--   ★★ 两行合起来体现了「从外部读来的数据必须先规范化再比较」
--     这一通用原则。
            hash = hash:gsub("[\r\n]", "") -- Remove any newlines from the over extending pattern above.
            hash = hash:gsub("\\", "/") -- Consistent path delimiters.
            if hash ~= "" then
                local calculatedhash = calculatedhashes[filename]
                if calculatedhash then
-- ★★ 三种结果的处理（★ 整个校验流程的判定表）：
--   ① 哈希不匹配（2570 行）→ 打印 + 置 "SHOW_WARNING" → 会弹窗（2491 行）
--   ② 哈希表里有、但没算出来（2575 行）→ "MISSING_DATABUNDLES"，静默
--   ③ 有哈希表且都匹配 → 什么都不做，正常游戏
                    if calculatedhash ~= hash then
                        print("A bad filehash was detected for:", filename, hash, "got this:", calculatedhash)
                        HashesMessageState = "SHOW_WARNING"
                        TheNet:SetQuietBackendErrorsReason("SHOWING_POPUP") -- Fake the value of HashesMessageState we do not differentiate if the warning is pending to show.
                    end
-- ★★ 情形 ② 的推理注释非常精彩，值得完整理解：
--   「hashes.txt 里有哈希，但我们没有算出对应文件的哈希。
--     这可能发生在玩家为了 modding 解压了 databundle 并删除了 zip 时。
--     ★ 若发生此情况，玩家很可能手动删过 databundle 压缩包，
--       应当知道崩溃来自他们的行为。」
--   ★★★ 推理链：解压 modding → zip 被删 → 哈希缺失 → 但游戏本体仍能跑。
--     ⇒ 所以这不是「损坏」，是「用户主动行为」，不必打扰他。
--   ★ 但仍然上报后端（2581 行）—— 静默不等于不记录。
                elseif HashesMessageState ~= "SHOW_WARNING" then
                    -- We have a hash in hashes.txt that we did not calculate a hash for.
                    -- This can happen if a player extracts a databundle for modding and deletes the zip.
                    -- If this happens it is highly likely the player manually deleted a databundle zip and should know that crashes are from their activities.
                    -- Backend team does not want to get alerted to these crashes.
                    HashesMessageState = "MISSING_DATABUNDLES"
                    TheNet:SetQuietBackendErrorsReason(HashesMessageState)
                end
            end
        end
    end

-- ★ 显式 close 并置 nil。虽然 Lua 有 GC 自动关闭，
--   显式关闭文件在「读完立刻释放句柄」上更可靠。
    io.close(hashesfile)
    hashesfile = nil
end