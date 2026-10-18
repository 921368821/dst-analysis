--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：shardnetworking.lua
-- 模块：联机同步 / 分片（Shard）集群网络
-- 职责：DST「一个存档 = 多个模拟分片」架构下的分片互联层。承担分片连接状态表
--       的维护、传送门与分片的双向绑定、世界设置在分片间的同步、
--       跨分片投票与存档请求的转发、以及月王/首领战利品状态的跨分片广播。
-- 关键符号：ShardPortals, ShardList, ShardConnected, Shard_IsMaster,
--           Shard_IsWorldAvailable, Shard_SyncWorldSettings, Shard_OnShardConnected,
--           Shard_UpdateWorldState, Shard_UpdatePortalState, Shard_GetConnectedShards,
--           Shard_UpdateMasterSessionId, Shard_WorldSave, Shard_StartVote,
--           Shard_OnDiceRollRequest, Shard_SyncBossDefeated, Shard_SyncMermKingExists
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：networkclientrpc.lua:1539 SHARD_RPC_HANDLERS（分片通道本体）、
--           prefabs/world.lua:427 ismastershard（分片主控标记）、
--           components/shardtransactionsteps.lua（跨分片事务）
--           TheShard / SendRPCToShard 为 C++ 侧对象，无 Lua 源码
--============================================================
--
--【阅读导航】
--  §零   依赖与全局状态（1-10）
--  §一 ★★★ 分片身份判定（12-22）
--  §二 ★★★ 世界设置的跨分片同步（24-41）
--  §三 ★★ 连接建立时的握手（43-62）
--  §四 ★★★★ Shard_UpdateWorldState（68-121）—— 本文件的心脏
--  §五   传送门与分片的双向绑定（125-143）
--  §六   调试与存档/投票转发（145-188）
--  §七 ★★★ 骰子冷却（192-218）
--  §八 ★★ 月王与首领状态的跨分片广播（222-291）
--  §九   跨分片事务的包装（293-305）
--
--【★★★ 本文件最重要的八条】
--  1. ★★★「分片」（shard）是什么 —— 必须先讲清，否则整个文件读不懂：
--     ★★★ 一个「存档」可以由**多个独立的模拟进程**共同构成。这些进程叫分片。
--     · 主分片（master shard）= ★ 承载「主分片状态」的进程（通常是表层世界）；
--     · 次分片（secondary shard）= ★ 附属进程（通常是洞穴世界）。
--     ★★ 两个关键事实：
--       (a) 每个分片都是**完整的模拟**（有自己的 TheWorld、自己的实体表），
--           所以各自都能跑 TheNet:StartServer —— 「一个进程一个世界」。
--       (b) 分片之间**不共享内存**，只能通过 SHARD_RPC（networkclientrpc.lua:1539）
--           互相发消息。★ 这就是本文件存在的全部理由。
--     ★★★ 与 prefabs/world.lua 的关系：
--     · TheWorld.ismastersim（第 426 行）→ 「我是权威模拟吗」（每个分片都是 true）；
--     · ★ TheWorld.ismastershard（第 427 行）→ 「我是主分片吗」（只有主分片 true）；
--     ★ 换句话说：ismastersim 区分「客户端 vs 服务端」，
--     ★★ ismastershard 区分「主分片 vs 次分片」—— ★ 两个正交维度。
--     参见 prefabs/world.lua:426-427 与 shardnetworking.lua:13。
--  2. ★★★ 三张全局表（:7-10）承担不同的角色，不可混用：
--     · ShardPortals  = 所有 worldmigrator 传送门实体（跨分片传送门）
--     · ShardList     = ★ 「有哪些分片存在」的布尔集合（world_id → true）
--     · ★★ ShardConnected = 「有哪些分片已连接」及其元数据
--       （world_id → {ready, tags, world, shard_name}）—— ★ 完整信息在后者。
--     ★ 三者都是**全局无 local**（第 7/9 行），供全项目访问。
--     ★★ ShardConnected 是 local（第 10 行）—— 只有本文件与外部通过函数访问。
--  3. ★★ Shard_IsMaster 的判定式（第 13 行）看似怪异，实则周全：
--     return TheShard:IsMaster() or TheNet:GetIsMasterSimulation() and not TheShard:IsSecondary()
--     ★★ 两个分支覆盖不同场景：
--       · 分支A：TheShard:IsMaster() —— ★ 主分片直接返回 true；
--       · 分支B：(权威模拟) and (非次分片) —— ★★ 兼容「分片系统未启用」的情况：
--         ★ 在普通（非分片）服务器上，TheShard 可能未正确报告，
--         ★★ 于是用「我是权威且不是次分片」来推断「我是主」。
--     ★★ 这是一种「多路径推断同一语义」的写法，为兼容各种部署形态。
--  4. ★★★ Shard_UpdateWorldState（第 68 行）是本文件的心脏：
--     ★ 它由 ShardManager 在「分片连接或断开」时调用，负责：
--       ① 解码新连接分片的 world_data（第 73-91 行，双层沙箱 + 结构校验）；
--       ② 更新 ShardConnected / ShardList（第 92-93 行）；
--       ③ 握手：同步世界设置（第 95 行）；
--       ④ ★★★ 重新绑定所有传送门（第 101-117 行）—— 分片变化会让传送门失效；
--       ⑤ 刷新服务器标签与世界数据（第 119-120 行）。
--     ★★ 关键理解：★ **分片的连接状态一变，所有传送门都要重新评估**
--       （因为传送门可能指向刚连上/刚断开的分片）。
--  5. ★★★ world_data 的「双层沙箱解码」（第 74/84 行）值得细读 ——
--     这是本文件安全设计的精华，详见 §四 的拆解。
--  6. ★★ 传送门绑定的三分支（第 102-116 行）—— 「连上」「断开」「不匹配」：
--     · ready 且目标分片空闲/自动 → 绑定到新分片；
--     · ★★ ready 但 portal.linkedWorld == world_id → 已绑定到这个分片，
--       只需刷新（ValidateAndPushEvents）；
--     · ★★ ready 但 portal.linkedWorld == 别的分片 → 「不匹配的永久世界」，禁用。
--     ★★★ 第三种情况揭示了一个重要概念：★「永久世界」（permanent world）——
--       一个传送门可以「固定指向某个特定分片」，而非动态绑定。
--  7. ★★★ 投票/存档/会话 id 的转发（第 151-188 行）全部「无条件推给主分片」：
--     · 条件统一是 `if TheWorld ~= nil and TheWorld.ismastershard then`；
--     ★★ 语义：★ 次分片收到这些请求 → 转成事件推给主分片 → 主分片处理。
--     ★ 「投票」「存档」都是**全局状态**，只能由主分片裁定。
--     ★ 第 152 行的注释解释了 TheWorld 可能为 nil（连接发生在世界生成期间）。
--  8. ★★ 骰子冷却（第 194-218 行）是本文件唯一的「限流/防刷」机制：
--     · RecentDiceRolls = { user_id → 冷却结束时刻 }；
--     · 每次请求先清理过期项，再检查是否在冷却，最后写入新冷却；
--     ★★★ TUNING.DICE_ROLL_COOLDOWN 是冷却时长（★ 可调平衡参数）。
--     ★★ 这是「按玩家限频」的简单范式（与 networkclientrpc 的限流同源思想）。
--
--【★ 关于「实体复制 / 兴趣管理 / 心跳超时」】
--  ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现。
--  ★ 分片之间**不复制实体** —— 它们是两个独立的模拟进程。
--    分片间同步的是「稀疏的状态」（世界设置、会话 id、投票、boss 状态、
--    月王部件），★ 走 SHARD_RPC 显式传输，而不是实体复制。
--    ★★ 这是「分片」与「复制」的分工：
--      · 复制（引擎层）= 同一模拟内，客户端之间的实体同步；
--      · ★ 分片 RPC（本文件）= 不同模拟之间，少量状态的显式同步。
--    参见 01-报告/04-联机同步-模组系统-UI.md 与 05-原生C++引擎层.md。
--  ★ 跨分片的数据一致性由 shardtransactionsteps 组件保证（:58-61 引用），
--    参见 components/shardtransactionsteps.lua。
--★★★[本文件唯一的 require —— ★ 引入世界自定义选项的定义]
--   ★ Customize 提供 GetSyncOptions()（哪些设置可跨分片同步）
--     与 ValidateOption(option, value, location)（设置值是否合法）。
--   ★★ 两个 API 分别在第 25 行（发送侧）与 networking.lua:806（接收侧裁剪）使用，
--     ★★ 构成「发送侧筛选 → 接收侧校验」的完整闭环。
--   ★★ 注意：接收侧的对应 require 在 networking.lua:798（函数内延迟加载），
--     ★ 同一个模块两处不同加载时机（见 networking.lua:798 注记）。
local Customize = require("map/customize")

--★★★ 分节标记。【 Shard Networking 】—— 本文件的标题栏。
--------------------------------------------------------------------------
--[[ Shard Networking ]]
--------------------------------------------------------------------------

--★★★[ShardPortals = {} —— ★★ 全局传送门注册表]
--   ★★★ 它收集**所有可跨分片传送的传送门实体**（含 worldmigrator 组件）。
--   ★★★ 三张表中的第一个（详见文件头注记 2）：
--     · ShardPortals   = 所有传送门实体（供第 101/127 行遍历）；
--     · ShardList      = 分片存在性集合（第 93/98 行维护）；
--     · ShardConnected = 分片连接详情（★ 本文件的核心状态）。
--   ★★ ★ 关键：★ 本表存的是**实体**，不是 ID。
--     ★ 这意味着它会持有实体的强引用 ——
--       ★★★ 传送门被移除后必须从这里摘掉，否则会泄漏。
--       ★★ 本文件只往里加（通过 worldmigrator 组件）★★ 却从不删除！
--       ⚠ 这是一个潜在的引用泄漏点（见下方 ⚠ 注记）。
--   ★★ 写入方（推测）：components/worldmigrator.lua 在实例化时往里注册。
--     ★ 参见 networkclientrpc.lua:1560（ReskinWorldMigrator 遍历 ShardPortals）。
--   ⚠ 疑似缺陷（★★ 轻量，仅记录不修改）：
--     ★ 本文件从未把 ShardPortals[x] 置 nil（只有第 101 行只读遍历）。
--     ★★ 若 worldmigrator.lua 没有对称的注销逻辑，
--       ★★ 传送门被删除后其实体仍被本表强引用 → 内存泄漏。
--     ★→ 移植时须确认 worldmigrator 的注册/注销是否成对。
ShardPortals = {}

--★★★[ShardList = {} —— ★ 「有哪些分片存在」的布尔集合]
--   ★★★ 只有 true 值（第 93/98 行）—— ★ 是一个 set，不是 map。
--   ★★★ 维护时机（第 93/98 行，都在 Shard_UpdateWorldState 里）：
--     · ready  → ShardList[world_id] = true
--     · not ready → ShardList[world_id] = nil
--   ★★★ 与 ShardConnected 的关系（★ 关键区分）：
--     · ShardList 是**「存在」**的粗粒度标记（无元数据）；
--     · ★ ShardConnected 是**「已连接」**的详细记录（含 world/tags/shard_name）。
--     ★★★ 两表在第 92-93 与 97-98 行**同时**增删 —— 所以实际内容相同。
--       ★★ 推理：ShardList 是「面向查询的轻量视图」，
--         ★★ ShardConnected 是「面向使用的完整数据」。
--     ★ ★ 本文件内部查询用的是 ShardConnected（第 17/127 行），
--       ★ ShardList 主要是给外部（UI/列表）用的「存在性」查询。
ShardList = {}
--★★[ShardConnected = {} —— ★★ 本文件的核心状态表]
--   ★★★ 这是唯一用 local 声明的三张表之一 —— ★★ 外部不直接访问它，
--     ★★ 必须通过 Shard_IsWorldAvailable(:16) / Shard_GetConnectedShards(:145) 查询。
--   ★★★ 值的结构（第 92 行揭示）：
--     { ready = true, tags = tags, world = world_data, shard_name = shard_name }
--     ★★ 四个字段：
--       · ready    —— ★ 恒为 true（表的存在本身即「已连接」，
--         ★★★ 因为断开时第 97 行把整个项置 nil —— ★ 所以 ready 是冗余字段）；
--       · tags     —— 该分片的标签（供服务器列表显示）；
--       · world    —— ★★ 世界生成数据（★ 解码后的结构，详见 §四）；
--       · shard_name —— ★★ 分片名（"Master" 或 "Caves"，见第 67 行注释）。
--   ★★★ 「断开即删除」而非「标记 ready=false」（第 97 行）：
--     ★★ 用「项的存在」表达连接状态 —— 简化查询（无需判 ready 字段）。
--     ★★ 代价：ready 字段冗余（永远为 true）。
local ShardConnected = {}
--★★ 三张全局表声明区结束。★★★ 记住它们分工（见文件头注记 2）：
--   · ShardPortals   —— 所有传送门实体（强引用，需注意注销对称）；
--   · ShardList      —— 分片存在性 set（给外部查询用）；
--   · ★ ShardConnected —— 分片连接详情（local，本文件核心状态）。

--★★★[Shard_IsMaster —— ★★ 「我是主分片吗」的权威判定]
--   ★★★ 第 13 行的判定式（★ 看似怪异，实则周全）：
--     return TheShard:IsMaster() or TheNet:GetIsMasterSimulation() and not TheShard:IsSecondary()
--   ★★★ 逐项拆解（★ 三个谓词的组合）：
--     · TheShard:IsMaster() —— ★★ 分支A：「我就是主分片」→ true；
--     · TheNet:GetIsMasterSimulation() —— ★★ 分支B第一条件：「我是权威模拟」
--       ★★ （即我不是客户端；★ 客户端的 ismastersim 为 false）；
--     · ★★ not TheShard:IsSecondary() —— 分支B第二条件：「我不是次分片」
--       ★★ （次分片也是权威模拟，但不该当主）。
--   ★★★★ 为什么要两个分支（★ 关键推理）：
--     ★★ 分支A 覆盖「分片系统正常运行」的情况（主分片自报家门）；
--     ★★ 分支B 覆盖「★ 分片系统未启用/未就绪」的情况：
--       ★★ 在普通单进程服务器上，TheShard 的状态可能不可靠或未初始化，
--         ★★ 于是用「是权威 且 不是次分片」来推断「我是主」。
--       ★★ 这是一种「多路径推断同一语义」的兼容性写法，
--         ★★ 保证在任何部署形态下都返回正确结果。
--     ★★★ 注意运算符优先级：and 优先于 or，
--       ★★ 所以实际是 `IsMaster() or (IsMasterSimulation() and not IsSecondary())`。
--       ★★ 这个优先级恰好符合语义，但 ★ 缺少括号使意图不明确（可读性问题）。
--       ★ ★ 移植时建议加括号（不改变语义）。仅标注。
--   ★★ 与 prefabs/world.lua 的 ismastershard（:427）对照：
--     · 那里是 **一次性的字段**（初始化时算好，存到 TheWorld 上）；
--     · ★ 这里是 **每次调用的函数**（实时查询 TheShard）。
--     ★★ 两者同源：都判断「是权威 且 不是次分片」。
--       ★ 字段版适合频繁判断（省函数调用）；函数版适合动态查询。
--   ★★ 本文件的选择（函数）可能因为 TheShard 状态会变化（连接/断开）。
--   TheShard 是 C++ 侧对象，无 Lua 源码。
function Shard_IsMaster()
    return TheShard:IsMaster() or TheNet:GetIsMasterSimulation() and not TheShard:IsSecondary()
end

--★★★[Shard_IsWorldAvailable —— ★★ 「某个分片可用吗」（供发送方判断）]
--   ★★★★ 第 17 行的判定：
--     return world_id ~= nil and (ShardConnected[world_id or SHARDID.MASTER] ~= nil
--             or world_id == TheShard:GetShardId())
--   ★★★★ 三个条件的逐个读解：
--     ① ★ world_id ~= nil —— ★★ 「必须明确指定分片」：
--       ★★ 注意第 17 行 `world_id or SHARDID.MASTER` 这个兜底 ——
--         ★★★ 它是**死代码**！因为条件①已保证 world_id ~= nil，
--           ★★ 所以 `world_id or SHARDID.MASTER` 永远等于 world_id。
--         ★★★ 这是一个「防御性写法残留」—— ★ 可能早期版本条件①不存在。
--       ⚠ 若想让 world_id=nil 时默认查 MASTER，条件①应该改成 `world_id ~= nil or ...`。
--         ★ 仅标注，不改码。
--     ② ★★ ShardConnected[world_id] ~= nil —— 「在已连接表里」；
--       ★★ 这是主要判据（见 :10 的「存在即已连接」设计）。
--     ③ ★★ world_id == TheShard:GetShardId() —— 「就是我自己」：
--       ★★★ 为什么要单独判断自己？
--       ★★ 因为 ★★ 自己不会出现在 ShardConnected 表里
--         ★★ （表里只记「别人」—— 见第 67 行注释 "should never be called
--         with for our own world_id"）。
--       ★★★ 所以「查询自己可用吗」必须走这条特例。
--   ★★ 这个函数的用途（★ 调用点分析）：
--     · networkclientrpc.lua:1779 HandleRPCQueue 的分片队列排空时
--       —— ★★ 「这个分片还连着吗？断了就丢弃它发来的 RPC」。
--     · shardnetworking.lua:127（通过 ShardConnected 直接遍历）。
--   ★★ 交叉参考：networkclientrpc.lua:1779 的双重判断
--     （不可用 且 不是自己 → 丢弃）。
function Shard_IsWorldAvailable(world_id)
    return world_id ~= nil and (ShardConnected[world_id or SHARDID.MASTER] ~= nil or world_id == TheShard:GetShardId())
end

--★★[Shard_IsWorldFull —— ⚠ 空实现（TODO）]
--   -- TODO
--   ★★★ 函数体为空 → 隐式返回 nil（永远是假）。
--   ★★★ 推测语义：「某分片是否满了（人数已满）」。
--   ⚠ 疑似缺陷（★★ 未实现的功能点，仅记录不修改）：
--     · 调用方若用 `if Shard_IsWorldFull(id) then ...` 判容量，
--       ★★ 会永远走进「不满」分支 —— ★ 即「限流容量检查形同虚设」。
--     · ★ 这是一个「预留 API 但未实现」的痕迹。
--     ★★ 实际影响：★ 若某处分片跳转逻辑依赖它做「满了就换另一个分片」，
--       ★★ 该逻辑当前不会生效。
--     ★→ 移植时应确认：容量判定是否需要在分片层做，
--       ★  或应由服务端（更权威的数据源）提供。
function Shard_IsWorldFull(world_id)
    -- TODO
end
--★ §一 结束。★★ 三张查询/判定函数：
--   Shard_IsMaster (:12)  —— ★「我是主分片吗」（双分支推断，兼容多部署形态）；
--   Shard_IsWorldAvailable (:16) —— ★「某分片可用吗」（含「自己」的特例）；
--   ★★ Shard_IsWorldFull (:20) —— ⚠ 空实现（TODO）—— 「分片满了吗」永远返回假。

--★★★[Shard_SyncWorldSettings —— ★★ 世界设置从主分片同步到次分片]
--   ★★★★ 签名：Shard_SyncWorldSettings(world_id, is_resync)
--     · world_id —— 目标分片（发给谁）；
--     · ★ is_resync —— ★★ 是否为「重新同步」（只影响日志文案）。
--   ★★★ 函数体（:25-40）：
--     ① 拿到「可同步的设置」白名单与本分片的生成选项；
--     ② ★★ 遍历 overrides，挑出白名单内的项；
--     ③ 非空则通过 SHARD_RPC.SyncWorldSettings 发出。
--   ★★★ 第 25-26 行：两个数据源
--     · ★ Customize.GetSyncOptions() —— ★★ 「哪些设置允许跨分片同步」
--       ★★ 的白名单（★ 由世界自定义系统定义）。
--       ★★★ 为什么需要白名单？推理：
--         ★★ 有些设置是「本分片独有」的（如洞穴专属设置）；
--         ★★ 强行同步会破坏分片的独立性。
--       ★★ 这是一个「能力约束」：只有声明可同步的才传。
--     · ★ ShardGameIndex:GetGenOptions() —— ★★ 本分片的世界生成选项。
--       ★★ 这是设置的**数据源**（overrides 在其中）。
--       ★ 交叉参考：networking.lua:772/786 也在读 ShardGameIndex:GetGenOptions()。
--   ★★★★ 第 28-36 行：★★★ 筛选循环（★ 逐行读解）
--     local sync_settings = {}
--     if worldoptions.overrides then
--         for option, value in pairs(worldoptions.overrides) do
--             if sync_options[option] then
--                 sync_settings[option] = value
--                 print("[SyncWorldSettings] " .. (is_resync and "Resyncing" or "Sending")
--                       .. " master world option " .. option .. " = " .. value
--                       .. " to secondary shards.")
--   ★★★ 四点：
--     ① ★★ 只同步「被修改过的项」（overrides = 覆盖默认值的设置）；
--       ★★ 未修改的用默认即可，不必传（★ 省带宽）。
--       ★ 交叉参考：networking.lua:800-810 的裁剪是同一思想（那里还裁掉
--       ★ "default" 值的项）。
--     ② ★★ `sync_options[option]` —— ★★ 白名单过滤；
--     ③ ★★ 日志逐项打印 —— ★ 对应 prefabs/world.lua 风格（帮助调试分片同步）；
--     ④ ★★★ is_resync 区分文案（"Resyncing" vs "Sending"）——
--       ★★ 语义：初次同步 vs 重新请求同步（见 :1592 ResyncWorldSettings）。
--   ★★★★ 第 38-40 行：非空才发送
--     if not IsTableEmpty(sync_settings) then
--         SendRPCToShard(SHARD_RPC.SyncWorldSettings, world_id, DataDumper(sync_settings, nil, true))
--   ★★ 三点：
--     ① IsTableEmpty —— 没有要同步的就**不发**（★ 避免空消息）；
--     ② ★ SendRPCToShard —— 分片通道（networkclientrpc.lua:1657）；
--     ③ ★ DataDumper(sync_settings, nil, true) —— 序列化（第三参数 true 含引用）。
--       ★ 接收侧（networkclientrpc.lua:1571-1590）用 RunInSandboxSafe 解码
--       ★★ 沙箱 + WorldSettings_Overrides 三路钩子应用。
function Shard_SyncWorldSettings(world_id, is_resync)
    local sync_options = Customize.GetSyncOptions()
    local worldoptions = ShardGameIndex:GetGenOptions()

    local sync_settings = {}
--★★[第 29 行：`if worldoptions.overrides then` —— 保护「没有 overrides」的情况]
--   ★★★ overrides 是「世界生成中被修改的设置」—— 可能为 nil（新世界）。
--   ★★ 没有它就跳过同步（不发空消息）。
--   ★★★ 注意：★★ 本函数不修改 overrides（只读）——
--     ★★ 对比 networking.lua:786 用 deepcopy 是因为那里**要修改**。
--       ★★ 同一个数据源，两处因用途不同而采取不同策略（★★★★ 值得学习）。
    if worldoptions.overrides then
        for option, value in pairs(worldoptions.overrides) do
            if sync_options[option] then
                sync_settings[option] = value
                print("[SyncWorldSettings] " .. (is_resync and "Resyncing" or "Sending") .. " master world option " .. option .. " = " .. value .. " to secondary shards.")
            end
        end
    end

--★ IsTableEmpty(sync_settings) —— 「没有要同步的项就不发」
--   ★★ 省略空消息的价值：★ 分片 RPC 有序列化/网络开销；
--     ★★ 大量「无变化」的分片本来就不需要消息。
    if not IsTableEmpty(sync_settings) then
        SendRPCToShard(SHARD_RPC.SyncWorldSettings, world_id, DataDumper(sync_settings, nil, true))
    end
end
--★★ §二 结束。Shard_SyncWorldSettings 是「主分片 → 次分片」推送世界设置的单向通道。
--   ★★ 三步：取白名单 → 筛 overrides → 序列化发送。
--   ★ ★ 「推拉」的另一半（次分片请求重发）在 networkclientrpc.lua:1592
--     ResyncWorldSettings 与本文件 :48 互相配合。

--★★★★[Shard_OnShardConnected —— ★★ 分片连接后的握手]
--   ★★★★ 原注释（第 44 行）："NOTES(JBK): Only should be called when
--   the shard state is REMOTESHARDSTATE.READY."
--   ★★★ 契约：★ 只能在「分片状态为 READY」时调用 —— ★★ 即「连接完成」而非「连接中」。
--     ★★★ 这很重要：只有在 READY 时才能同步设置（否则对方还没准备好）。
--     ★ 调用方是 Shard_UpdateWorldState 的 ready 分支（第 72/95 行）。
--   ★★★★★ 函数体（:45-61）★★★ 三个步骤：
--   ── 步骤①（:45-49）：★★ 谁发起同步？──
--     if Shard_IsMaster() then
--         Shard_SyncWorldSettings(world_id)          -- ★ 我是主 → 我推给它
--     else
--         SendRPCToShard(SHARD_RPC.ResyncWorldSettings, SHARDID.MASTER)  -- ★ 我是次 → 我拉
--   ★★★★ 推拉模型（★ 关键理解）：
--     · ★★ 主分片「主动推」（Shard_SyncWorldSettings）——
--       ★★ 因为主分片持有权威设置（它是「源头」）；
--     · ★★ 次分片「主动拉」（ResyncWorldSettings）——
--       ★★ 请主分片重发（因为主分片连上时会自动推，
--         ★★ 但次分片连上时主分片不一定知道该推给谁）。
--     ★★★ 这是一个「谁先连上谁负责」的握手设计：
--       · 主先连 → 主推；
--       · ★ 次先连 → 次拉（触发主推）。
--       ★★ 两种时序都能收敛到「设置一致」。
--   ── 步骤②（:50-57）：★★ 主分片额外同步 mermkingwatcher ──
--     if Shard_IsMaster() then
--         if TheWorld then
--             local shard_mermkingwatcher = TheWorld.shard.components.shard_mermkingwatcher
--             if shard_mermkingwatcher then
--                 shard_mermkingwatcher:ResyncNetVars()
--   ★★★ 三层取组件：TheWorld → .shard → .components → .shard_mermkingwatcher
--     ★★ 注意这条路径是 **TheWorld.shard.components**（不是 TheWorld.components）；
--       ★★★ 因为 shard 是分片概念（TheWorld.shard 在 world.lua:424 初始化）。
--     ★★ ResyncNetVars() —— ★ 重新同步网络变量（月王相关状态）。
--       ★ 这属于「细粒度的状态同步」（本文件 §八 也有类似）。
--   ── 步骤③（:58-61）：★★ 事务步骤组件感知新分片 ──
--     local shardtransactionsteps = TheWorld and TheWorld.components.shardtransactionsteps or nil
--     if shardtransactionsteps then
--         shardtransactionsteps:OnShardConnected(world_id)
--   ★★★ 第 58 行：`TheWorld and X or nil` 的三目惯用法
--     ★★ 作用：当 TheWorld 为 nil 时，结果为 nil（不会崩）。
--     ★★ 等价于 `if TheWorld then ... end` 但返回 nil 而非 false。
--     ★ ★ 是 networkclientrpc.lua:1155（SpawnSeamlessPlayerReplacement）同款写法。
--   ★★★ OnShardConnected 让事务系统知道「有新分片了」
--     ★★ （可能需要重新协商跨分片事务的参与者）。
function Shard_OnShardConnected(world_id, tags, world_data, shard_name)
    -- NOTES(JBK): Only should be called when the shard state is REMOTESHARDSTATE.READY.
    if Shard_IsMaster() then
        Shard_SyncWorldSettings(world_id)
    else
        SendRPCToShard(SHARD_RPC.ResyncWorldSettings, SHARDID.MASTER)
    end
--★ 第二次 `if Shard_IsMaster()` —— ★★ 与第 45 行重复判定（可合并但未合并）。
--   ★★★ 步骤①（同步设置）与步骤②（同步月王网络变量）都只在主分片执行。
--   ★ ★ 这两个 if 相邻且条件相同 —— 属于可简化的小冗余（无功能影响）。
    if Shard_IsMaster() then
        if TheWorld then
            local shard_mermkingwatcher = TheWorld.shard.components.shard_mermkingwatcher
            if shard_mermkingwatcher then
                shard_mermkingwatcher:ResyncNetVars()
            end
        end
    end
    local shardtransactionsteps = TheWorld and TheWorld.components.shardtransactionsteps or nil
    if shardtransactionsteps then
        shardtransactionsteps:OnShardConnected(world_id)
    end
end
--★★ §三 结束。Shard_OnShardConnected —— 分片连接后的三步握手：
--   ① 同步世界设置（主推 / 次拉）；
--   ② 主分片额外同步月王网络变量；
--   ③ 通知事务步骤组件有新分片。
--   ★ ★ 这三步让「分片加入」后状态趋于一致。
--★★★[第 63-67 行：★ Shard_UpdateWorldState 的契约注释（★ 关键）]
--   ★★★ 四行注释，每一条都重要：
--   ★★ (a) "Called from ShardManager whenever a shard is connected or
--        disconnected" —— ★★★ 本函数由 C++ 的 ShardManager 调用，
--        ★★ 覆盖「连接」与「断开」两种事件（不只是连接）。
--   ★★ (b) "to automatically update known portal states" —— ★★★
--        ★★★ 本函数的存在意义：★ 分片状态变化 → 传送门要重新绑定。
--   ★★ (c) "tags and worldgen options are also passed through here for all
--        shards" —— 三个参数对所有分片都传（不只是主分片）。
--   ★★ (d) ★★ "NOTE: should never be called with for our own world_id"
--        —— ★★★ 本函数**不会**为自己的 world_id 调用。
--        ★★★ 这就是 :16 Shard_IsWorldAvailable 需要「或等于自己」特例的原因
--          （见 :17 的分析）。
--        ★★ 也就是说：★ ShardConnected 表里只记录「其他分片」，不含自己。
--   ★★ 最后一句注释："shard_name on default worldgen will be either
--   'Master' or 'Caves'" —— ★★★ 分片名的来源。
--     ★★★ 这揭示了 DST 默认双向世界的分片划分：主 = Master（表层），
--       ★★★ 次 = Caves（洞穴）。
--     ★★ 双向世界（surface + caves）是 DST 最经典的分片形态。
--     ★ ★ 参见 prefabs/world.lua 的 prefabs 清单里没有 caves.lua，
--       ★★ 说明洞穴世界也是通过 MakeWorld 的同一工厂（:401）构造的变体。
--Called from ShardManager whenever a shard is connected or
--disconnected, to automatically update known portal states
--tags and worldgen options are also passed through here for all shards
--NOTE: should never be called with for our own world_id
-- shard_name on default worldgen will be either "Master" or "Caves"
--★★★★★[Shard_UpdateWorldState —— ★★★ 本文件的心脏（★ 54 行）]
--   ★★★★★ 签名：Shard_UpdateWorldState(world_id, state, tags, world_data, shard_name)
--     · world_id   —— 分片标识；
--     · state      —— ★★ 分片状态（REMOTESHARDSTATE.READY 等）；
--     · tags       —— 分片标签；
--     · world_data —— ★★ 世界生成数据（★ 字符串或已解码表）；
--     · shard_name —— 分片名（"Master"/"Caves"）。
--   ★★★★★ 函数体的五个阶段（★ 逐段读解）：
--   ── 阶段①（:69-70）：★★ 状态判定与日志 ──
--     local ready = state == REMOTESHARDSTATE.READY
--     print("World "..world_id.."("..(shard_name or "n/a")..") is now "
--           ..(ready and 'connected' or 'disconnected'))
--     ★★★ 两点：
--       · ready 判定用常量 REMOTESHARDSTATE.READY（★ C++ 侧枚举）；
--       · ★ 日志里的 shard_name or "n/a" —— ★★ 对 nil 做兜底（%s 打印 nil 会出问题）。
--   ── 阶段②（:72-95）：★★ ready 分支——更新状态 + 握手 ──
--   ── 阶段③（:96-99）：★★ not ready 分支——清理状态 ──
--   ── 阶段④（:101-117）：★★★ 传送门重新绑定（★ 真正的价值所在）──
--   ── 阶段⑤（:119-120）：★★ 刷新对外元数据 ──
--   ★★★ ★★★ 阶段④是理解本函数的关键：
--     ★★ 「为什么分片变化要重扫所有传送门」——
--       ★★ 因为传送门可能指向刚连上（现在可用）或刚断开（现在不可用）的分片；
--       ★★ 不重扫就会出现「传送门指向一个已断开的分片」。
--     ★★ 而遍历 ShardPortals（第 101 行）是唯一知道所有传送门的方式。
function Shard_UpdateWorldState(world_id, state, tags, world_data, shard_name)
--★★[第 69-70 行：ready 判定与连接状态日志]
--   ★★★ 「connected / disconnected」的措辞用词很准确：
--     ★★ 断开（disconnected）不只是「不在了」，而是「明确断了」。
--     ★★ 日志对运维（服务器管理员）友好。
    local ready = state == REMOTESHARDSTATE.READY
    print("World "..world_id.."("..(shard_name or "n/a")..") is now "..(ready and 'connected' or 'disconnected'))

    if ready then
--★★★[第 73-91 行：★★★ world_data 的「双层沙箱解码」（★ 本文件安全设计的精华）]
--   ★★★★ 第 73 行：`if world_data ~= nil and #world_data > 0 then`
--     ★★ #world_data > 0 —— 非空字符串检查（不是 table 长度）。
--   ★★★★★ 解码的三层结构（★ 必须理解，这是本文件最硬核的部分）：
--   ── 第一层（:74）：RunInSandboxSafe(world_data) ──
--     ★★★ 先把 world_data（**字符串**）当「Lua 代码」在沙箱里执行。
--     ★★★ 为什么？推理（★ 关键）：
--       ★★ world_data 是「序列化的数据」，序列化的逆操作是「执行 Lua 构造代码」；
--       ★★★ 但执行代码 = 执行任意逻辑 = ★★ 危险（若是恶意分片发的）。
--       ★★★ RunInSandboxSafe 把执行限制在沙箱内（只能构造数据，不能做 IO/函数定义等）。
--       ★★ 「反序列化即执行」是序列化系统的固有风险，沙箱是必须的防线。
--     ★★ 交叉参考：networkclientrpc.lua:1545/1572/1908 也用 RunInSandboxSafe。
--   ── 第二层（:76-86）：★★★ 结构校验 + 二次解码 ──
--     if success and type(data) == "table" and type(data.str) == "string" then
--         local count = 0
--         for _ in pairs(data) do count = count + 1; if count > 1 then break end end
--         --make sure data.str is the only entry in the table
--         if count == 1 then
--             success, data = RunInSandboxSafe(TheSim:DecodeAndUnzipString(data.str))
--     ★★★★★ 原注释（第 82 行）：★ "make sure data.str is the only entry in the table"
--     ★★★★ 为什么必须校验「只有一个键」（★ 关键推理）：
--       ★★ 第一层解码后 data 是一个表 —— ★ 但它的内容**由发送方控制**；
--       ★★★ 如果它有多个键，或 str 之外还有别的东西，
--         ★★★ 就说明发送方塞了「额外数据」—— ★★ 这可能是攻击或错误。
--       ★★ 只接受「恰好一个键且名为 str」—— ★★★ 极严格的结构校验。
--       ★★ 这防止了「发送方在 str 之外塞入任意键值对」（数据注入）。
--     ★★★★ 第 78-81 行的计数技巧：
--       for _ in pairs(data) do count = count + 1; if count > 1 then break end end
--       ★★★ ★★ 只数到 2 就 break —— ★★ 「快速失败」优化。
--         ★★ 不需要数完（超过 1 就不合法了）；
--         ★★ 这是「短路遍历」的经典写法（性能考虑）。
--       ★★ 遍历 pairs（无序）只数个数 —— 与顺序无关，正确。
--     ★★★★ 第三层（:88）：world_data = success and data or {}
--       ★★★ 成功用解码结果，失败用空表。
--       ★★ 「失败也继续」（降级为空）—— 不抛错、不中断整个流程。
--       ★★ 与 :96 的 else 分支（直接 world_data = {}）呼应。
--   ★★★★ ★★ 为什么需要「双层」（74 + 84 两次 RunInSandboxSafe）？
--     ★★ 因为数据是「压缩 + 编码 + 嵌套」的：
--       · 第 74 行：解开第一层（可能是 {str = "压缩串"} 的包装）；
--       · ★★ 第 84 行：TheSim:DecodeAndUnzipString(data.str) 解压并再沙箱解开。
--       ★★★ 两次都在沙箱里 —— ★★★ 因为「解压缩后的内容也是代码」。
--       ★★★ ★★ 这是一个「分层数据传递 + 每层沙箱」的安全范式。
--   ★★ ★ 接收侧对应代码：networkclientrpc.lua:1571-1590 SyncWorldSettings
--     （也是 RunInSandboxSafe + 白名单应用）。
--     ★★ 「发送侧筛选白名单 + 接收侧沙箱 + 结构校验」= 三层防护。
        if world_data ~= nil and #world_data > 0 then
            local success, data = RunInSandboxSafe(world_data)

            if success and type(data) == "table" and type(data.str) == "string" then
                local count = 0
                for _ in pairs(data) do
                    count = count + 1
                    if count > 1 then break end
                end
                --make sure data.str is the only entry in the table
                if count == 1 then
--★★★[第 84 行：★ 第二层沙箱解码 —— 数据的真正形态在这里]
--   success, data = RunInSandboxSafe(TheSim:DecodeAndUnzipString(data.str))
--   ★★★★ 逐段读解：
--     · ★★ TheSim:DecodeAndUnzipString(data.str) —— ★★ C++ 侧调用：
--       先解压（unzip）再解码（decode），得到「内层数据」。
--       ★★ 为什么用 zip？因为世界数据可能很大 → 压缩省带宽。
--       ★★ 对应发送侧的 ZipAndEncodeSaveData（networking.lua:814）。
--     · ★★ RunInSandboxSafe(...) —— ★★ 包裹执行，防止解码产物是恶意代码。
--   ★★★ ★★★ 注意赋值给同一对变量（success, data）——
--     ★★ 覆盖了第一层的结果（success 和 data 都被重新赋值）。
--     ★★ 若第二层失败，success 变 false → 第 88 行会走降级（world_data = {}）。
--   ★★★ 这一行的位置（缩进更深）表示它在「count == 1」条件内 ——
--     ★★ 只有结构校验通过才会二次解码（见 :83 的 if）。
                    success, data = RunInSandboxSafe(TheSim:DecodeAndUnzipString(data.str))
                end
            end

--★★[第 88 行：`world_data = success and data or {}` —— 降级处理]
--   ★★★ 两分支：
--     · success 为真且 data 非 nil → 用 data；
--     · ★★ 否则 → 用空表 {}。
--   ★★ ★★★ 「解码失败不当成致命错误」—— 继续用空数据运行。
--     ★★ 理由：world_data 只是「世界生成的描述信息」，
--       ★★ 拿不到它不影响分片的基本连接与游戏进行。
--       ★★★ 「优雅降级」优于「整体失败」。
--   ★ ★ 与第 92 行（存进 ShardConnected）呼应 —— 空表也照存。
            world_data = success and data or {}
        else
            world_data = {}
        end
--★★★[第 92-95 行：★★★ 状态更新 + 触发握手]
--   ShardConnected[world_id] = { ready = true, tags = tags, world = world_data, shard_name = shard_name }
--   ShardList[world_id] = true
--   Shard_OnShardConnected(world_id, tags, world_data, shard_name)
--   ★★★★ 三行三步（★ 顺序重要）：
--     ① ★★ 先更新 ShardConnected（存下完整元数据）；
--       ★★ 必须在握手**之前** —— 因为握手（:24 等）可能查询 ShardConnected。
--     ② ★★ 再更新 ShardList（存在性标记，见 :9 的分析）；
--       ★★ 两表同时更新，保持一致。
--     ③ ★★ 最后调 Shard_OnShardConnected 触发握手（设置同步等）。
--       ★★★ 「先更新状态，后触发动作」—— ★ 顺序保证动作能读到新状态。
--   ★★★ 存进 ShardConnected 的 world_data 就是第 88 行降级后的结果
--     ★★ （可能是 {} 若解码失败）。
--   ★ 交叉参考：networking.lua:791 用 Shard_GetConnectedShards() 读这些数据。
        ShardConnected[world_id] = { ready = true, tags = tags, world = world_data, shard_name = shard_name }
        ShardList[world_id] = true

        Shard_OnShardConnected(world_id, tags, world_data, shard_name)
    else
--★★[第 96-99 行：★★ not ready 分支 —— 断开时的清理]
--   ShardConnected[world_id] = nil
--   ShardList[world_id] = nil
--   ★★★ 两行把分片从两张表里**移除**（不是标记 ready=false）。
--   ★★ 与 :92 的「新增」对称。
--   ★★★ ★★ 注意：这个分支**不调任何握手**（不需要——分片都没了）。
--   ★★ 但它**也不做任何传送门处理**—— ★★ 那由后面的第 101-117 行统一处理！
--     ★★★ 关键：★ 传送门逻辑（第 101 行）在 if/else **外面**，
--       ★★ 所以「断开」也会触发传送门重新评估（这正是第 114 行禁用逻辑的意义）。
--       ★★★ 见 :101-117 的分析。
        ShardConnected[world_id] = nil
        ShardList[world_id] = nil
    end

--★★★★★[第 101-117 行：★★★ 传送门与分片的三分支绑定（★ 本函数真正的价值）]
--   ★★★ 为什么要遍历 ShardPortals（★ 回顾）：
--     ★★ 分片的连接状态变了 → 所有传送门可能需要重新评估绑定。
--     ★★ 这是「分片变化 → 世界设施重连」的传播机制。
--   ★★★★★ 循环体（第 102-116 行）的三分支结构（★ 逐个读解）：
--   ── 分支①（:102-108）：★★ ready 且「可绑定」→ ★★ 绑定到新分片 ──
--     if ready and (v.components.worldmigrator.linkedWorld == nil
--                 or v.components.worldmigrator.auto == true) then
--         if v.components.worldmigrator.shard_name == nil or
--             v.components.worldmigrator.shard_name == shard_name then
--             v.components.worldmigrator:ClearDisabledWithReason("MISSINGSHARD")
--             v.components.worldmigrator:SetDestinationWorld(world_id)
--   ★★★ 两个外层条件（可以绑定的两种情况）：
--     · ★ linkedWorld == nil —— 「还没绑定过」（空闲传送门）；
--     · ★ auto == true —— 「自动传送门」（★ 允许被重新指向）。
--       ★★★ auto 的语义：★ 「这个门会自动跟着分片变化走」。
--       ★★ 与之对立的是「固定门」（绑定后不自动改）。
--     ★★ ★ 两个条件的 or：★ 空闲的 OR 自动的 → 可以绑定。
--       ★★ 已绑定的**非自动**门 → 不碰（尊重既有绑定）。
--   ── 内部条件（:104）：★★ shard_name 匹配 ──
--     if v.components.worldmigrator.shard_name == nil or
--         v.components.worldmigrator.shard_name == shard_name then
--   ★★★★ shard_name 的三层语义（★ 关键理解）：
--     · nil —— 「不挑分片名」（任意分片都能绑定）；
--     · ★★ == shard_name —— 「只去名为 X 的分片」（如只去 Caves）；
--     · ★★★ 不匹配 —— ★★ 「这个门不是给这个分片用的」→ 不绑定。
--       ★★★ 所以 shard_name 是「传送门的目的地偏好」。
--       ★★ 例如：地表到洞穴的门 shard_name="Caves"，洞穴到地表的是 "Master"。
--   ── 绑定动作（:106-107）──
--     ClearDisabledWithReason("MISSINGSHARD") —— ★★ 解除「因缺分片而禁用」的状态；
--       ★★ 「WithReason」= 带上原因（用于 UI 提示）。
--     SetDestinationWorld(world_id) —— ★★ ★★ 设置目的地为新分片。
--       ★★ 这才是「真正绑定」—— 传送门现在指向 world_id。
--   ── 分支②（:109-111）：★★ ready 但「已绑定到此分片」→ ★ 刷新 ──
--     elseif v.components.worldmigrator.linkedWorld == world_id then
--         v.components.worldmigrator:ClearDisabledWithReason("MISSINGSHARD")
--         v.components.worldmigrator:ValidateAndPushEvents()
--   ★★★ 这个分支的条件：「这个门已经绑到刚连上的分片了」。
--     ★★ 动作：解除禁用 + ValidateAndPushEvents（校验并推事件）。
--       ★★ 「推事件」可能触发 UI 更新（门可用 → 提示玩家）。
--   ── 分支③（:112-116）：★★ ready 但「绑到别的永久分片」→ ★★ 禁用 ──
--     else
--         print(string.format("Skipping portal[%s] (different permanent world)",
--               tostring(v.components.worldmigrator.id)))
--         v.components.worldmigrator:SetDisabledWithReason("MISSINGSHARD")
--         v.components.worldmigrator:ValidateAndPushEvents()
--   ★★★★ 关键概念：「different permanent world」（★ 不同的永久世界）——
--     ★★★★ 这个分支揭示了「永久世界」的概念：
--       ★★ 有些传送门是**永久绑定**到某个特定世界的（不是自动跟随分片）；
--       ★★ 当有**新**分片连上时，这些门**不应该**被改指向新分片；
--       ★★★ 所以它们被「跳过」（Skipping）并（重新）禁用。
--       ★★★ 「永久世界」= 「固定的、不会因为分片增删而改变的传送目的地」。
--     ★★ 「Skipping portal[...]」日志打印了门的 id（而非实体），
--       ★★ 因为 id 是稳定的标识（实体引用会变）。
--     ★★ SetDisabledWithReason —— ★★ 禁用并说明原因（MISSINGSHARD）。
--   ★★★★ ★★ 为什么分支③ 也要 ValidateAndPushEvents？
--     ★★ 因为「从能用变成不能用」也是状态变化 → 需要通知 UI。
--       ★★ 「变好」和「变坏」都要推事件（对称处理）。
--   ★★★ ★★★ 「MISSINGSHARD」这个 reason 的双重含义（★ 值得注意）：
--     ★★ 它同时用在「解除禁用」（分支①/②）和「设置禁用」（分支③）！
--     ★★★ 推理：MISSINGSHARD = 「因缺少分片而不可用」，
--       ★★ 分支①/② 是「分片回来了所以恢复」，
--       ★★ 分支③ 是「这个门要去的分片不是这个，所以仍不可用」。
--       ★★★ 同一 reason 覆盖「缺失」和「不匹配」两种不可用 —— ★ 略粗糙但实用。
    for k, v in pairs(ShardPortals) do
--★★[第 102-103 行：分支①的两个「可绑定」条件]
--   ★★★ 再次强调：★ linkedWorld == nil（空闲）OR auto == true（自动）。
--   ★★★ ★ 为什么 auto 的门可以被重指向？
--     ★★ auto = 「自动门」的语义就是「自动寻找可用分片」——
--       ★★ 所以分片增删时它需要跟着变（否则「新分片来了但门还指着旧的」）。
--       ★★ 这对「洞穴传送门」等设施很重要（保证可达性）。
--     ★★★ 与「固定门」对比：固定门不自动变（尊重玩家的设定）。
--       ★★ 这是「自动化 vs 手动」的经典权衡。
        if ready and (v.components.worldmigrator.linkedWorld == nil
                    or v.components.worldmigrator.auto == true) then
--★★[第 104 行：shard_name 匹配检查（★ 传送门的目的地偏好）]
--   ★★★★ 三种 shard_name 值的语义（★ 再强调，见上方分支①的详解）：
--     · nil —— ★ 「不挑」（这个门去任何分片都行）；
--     · "Caves" / "Master" —— ★★ 「只去这个分片」；
--     · ★★★ 不匹配 —— ★★ 这个门不是为这个分片准备的 → 不绑定。
--   ★★★ 例：「去洞穴的门」shard_name="Caves"，只有 Caves 分片连上才绑定；
--     ★「回地表的门」shard_name="Master"，同理。
            if v.components.worldmigrator.shard_name == nil or v.components.worldmigrator.shard_name == shard_name then
                -- Bind unused portals to this new server, mm-mm!
                v.components.worldmigrator:ClearDisabledWithReason("MISSINGSHARD")
                v.components.worldmigrator:SetDestinationWorld(world_id)
            end
--★★[第 109 行：分支②条件「已绑定到刚连上的分片」]
--   elseif v.components.worldmigrator.linkedWorld == world_id then
--   ★★★ 场景：这个门本来就指向 world_id，现在 world_id 连上了 → 恢复它。
--   ★★ 与分支①的区别：① 是「设置绑定」（SetDestinationWorld），
--     ★★ ② 是「确认绑定」（只刷新状态）。
--   ★★★ 两条路径都调 ClearDisabledWithReason —— ★ 解除禁用。
        elseif v.components.worldmigrator.linkedWorld == world_id then
            v.components.worldmigrator:ClearDisabledWithReason("MISSINGSHARD")
            v.components.worldmigrator:ValidateAndPushEvents()
        else
--★★[第 113 行：分支③的日志 —— 「跳过这个门（不同的永久世界）」]
--   print(string.format("Skipping portal[%s] (different permanent world)", tostring(...)))
--   ★★★ 日志措辞 "Skipping portal[...] (different permanent world)" ——
--     ★★ 明确说「因为是不同的永久世界而跳过」—— 揭示了「永久世界」概念。
--     ★★ 这也是给运维的诊断信息（「为什么这个门没绑上新分片？」）。
--   ★★★ 「Skipping」而非「Disabling」—— ★ 但紧接着又 SetDisabledWithReason。
--     ★★★ 措辞与动作略有出入（跳过绑定，但仍禁用）—— 略粗糙。仅记录。
            print(string.format("Skipping portal[%s] (different permanent world)", tostring(v.components.worldmigrator.id)))
            v.components.worldmigrator:SetDisabledWithReason("MISSINGSHARD")
            v.components.worldmigrator:ValidateAndPushEvents()
        end
    end

--★★★[第 119-120 行：★★ 刷新对外元数据（★ 跨文件协作）]
--   UpdateServerTagsString()
--   UpdateServerWorldGenDataString()
--   ★★★★ 为什么分片变化后要刷新这两个？
--     · UpdateServerTagsString —— ★★ 服务器标签（含分片信息）需更新；
--     · ★★ UpdateServerWorldGenDataString —— ★★ 更重要：
--       ★★ 它会合并所有分片的世界生成数据（networking.lua:789-796）——
--       ★★★ **新增/移除了一个分片，合并结果就变了** → 必须重新上报。
--       ★★★ 这就是分片互联的「元数据同步」环节。
--   ★★★ 交叉参考：
--     · networking.lua:748 UpdateServerTagsString；
--     · networking.lua:784 UpdateServerWorldGenDataString（内含合并逻辑）。
--   ★★ ★ 顺序：先 tags 后 worldgen —— 两者独立，无依赖。
--   ★ ★ 这两个函数定义在 networking.lua（本文件是跨文件调用）。
    UpdateServerTagsString()
    UpdateServerWorldGenDataString()
end
--★★★★★ §四 结束。Shard_UpdateWorldState —— 本文件的心脏（54 行）。
--   ★★★ 五个阶段回顾：
--     ① ready 判定与日志（:69-70）；
--     ② ready 分支：双层沙箱解码 + 状态更新 + 握手（:72-95）；
--     ③ not ready 分支：清理两张表（:96-99）；
--     ④ ★★★ 传送门三分支重绑（:101-117）—— 真正的价值；
--     ⑤ 刷新对外元数据（:119-120）。
--   ★★★ 两个核心机制（移植时必须理解）：
--     · ★ 「双层沙箱 + 严格结构校验」（:74-84）解 world_data；
--     · ★ 「分片变化 → 传送门重绑」（:101-117），三分支：
--         空闲/自动 → 绑定；已绑此片 → 恢复；固定到别的 → 禁用。

--★★★[第 123-124 行：Shard_UpdatePortalState 的契约注释]
--   "--Called from worldmigrator whenever a new portal is"
--   "--spawned to automatically link it with known shards"
--   ★★★ 契约：★ 由 worldmigrator 在「新传送门生成」时调用。
--   ★★★ 与 Shard_UpdateWorldState（:68）是一对「双向触发」：
--     · :68 —— ★★ 分片状态变了 → 重扫所有门（本文件 §四 阶段④）；
--     · ★ 本函数 —— ★★ 新门生成了 → 给它找一个分片。
--     ★★★ 两者共同保证「分片与传送门」的双向一致性。
--   ★ ★ 「自动链接到已知分片」（link it with known shards）——
--     ★ 用 ShardConnected（已知分片）来给新门找归属。
--Called from worldmigrator whenever a new portal is
--spawned to automatically link it with known shards
--★★★[Shard_UpdatePortalState —— ★★ 新传送门的反向绑定（★ 与 :68 对称）]
--   ★★★★ 逻辑（:126-143）：
--     ① ★★ 若 linkedWorld == nil（门还空闲）：
--        ★★ 遍历 ShardConnected，★ 找一个能接受这个门的分片并绑定；
--        ★★ 若找不到 → 禁用并提示「没有可用分片」；
--     ② ★★ 若 linkedWorld ~= nil（已绑定）：
--        ★★ 只解除禁用 + 刷新（不改变绑定）。
--   ★★★★ 第 126-140 行：分支①的逐段读解
--     if inst.components.worldmigrator.linkedWorld == nil then
--         for k, v in pairs(ShardConnected) do
--             -- Bind to first available shard that can be
--             if inst.components.worldmigrator.shard_name == nil or
--                 inst.components.worldmigrator.shard_name == v.shard_name then
--                 v.components... ClearDisabledWithReason("MISSINGSHARD")
--                 inst.components.worldmigrator:SetDestinationWorld(k)
--                 return
--   ★★★★ 与 Shard_UpdateWorldState（:101-117）对照（★ 理解差异）：
--     ┌────────────────────┬─────────────────────────┬──────────────────────┐
--     │                    │ UpdateWorldState(:101)  │ UpdatePortalState(本) │
--     ├────────────────────┼─────────────────────────┼──────────────────────┤
--     │ 触发方             │ ★ 分片状态变化            │ ★ worldmigrator 生成    │
--     │ 遍历方向           | ★★ 门→分片（遍历 ShardPortals）│ ★★ 分片→门（遍历 ShardConnected）│
--     │ 数量               │ ★ 多（所有门）            │ ★ 一个（刚生成的门）     │
--     │ 绑定条件           │ ★★ 空闲 OR auto          │ ★★ linkedWorld == nil  │
--     │ shard_name 检查    │ ✓（:104）              │ ✓（:129）             │
--     │ 找不到目标         │ ★★ 禁用（:114）           │ ★★ 禁用（:137）         │
--     │ 绑定动作           │ SetDestinationWorld      │ SetDestinationWorld    │
--     └────────────────────┴─────────────────────────┴──────────────────────┘
--   ★★★★ 第 129 行：同样的 shard_name 匹配
--     if inst.components.worldmigrator.shard_name == nil or
--         inst.components.worldmigrator.shard_name == v.shard_name then
--     ★★ 语义与 :104 完全相同：
--       · nil → 不挑分片；
--       · == v.shard_name → ★★ 只去这个 shard_name 的分片。
--       ★ 遍历的是 ShardConnected（v = {ready, tags, world, shard_name}），
--         ★★ 所以 v.shard_name 是分片自己的名字。
--       ★★★ 对照 :101-104：那里遍历 ShardPortals（v = 门），
--         ★★ 所以检查的是「门的 shard_name vs 分片的 shard_name」（入参）。
--         ★★★ ★ 两处检查方向不同但语义对称：
--           :101 —— 门.shard_name vs shard_name（形参，本次连接的分片）；
--           :129 —— 门.shard_name vs v.shard_name（表里各分片的名字）。
--         ★ ★ 都是「门的偏好 == 分片的名字」。
--   ★★★★ 第 133 行：`return` —— ★★ 绑定后立即返回（只绑一个分片）
--     ★★ 原注释第 128 行："Bind to first available shard that can be"
--     ★★★ 「first available」—— ★★ 一个门只去一个分片（绑定即确定）。
--       ★★ 「哪个分片」取决于 pairs 的遍历顺序（★ 无序！）——
--         ★★★ 所以「绑到哪个」是不确定的（若有多个匹配分片）。
--         ★★ 实践中「去洞穴」通常只有一个匹配分片，无歧义。
--   ★★★★ 第 136-138 行：★ 找不到可用分片的处理
--     print(string.format("Skipping portal[%s] (no available shard [%s] connected)", ...))
--     inst.components.worldmigrator:SetDisabledWithReason("MISSINGSHARD")
--     inst.components.worldmigrator:ValidateAndPushEvents()
--   ★★★ 与 :113 的「Skipping portal[...] (different permanent world)」区分：
--     · :113 —— ★★ 「这个门固定去别的世界」（不是没分片，是分片不对）；
--     · ★ :136 —— ★★ 「没有任何可用分片」（真的没分片连着）。
--     ★★ 两种「不可用」的原因不同，但都用 MISSINGSHARD 标记。
--   ★★★ 第 141-142 行：分支②（已绑定）
--     inst.components.worldmigrator:ClearDisabledWithReason("MISSINGSHARD")
--     inst.components.worldmigrator:ValidateAndPushEvents()
--     ★★ 与 :110-111 完全相同 —— 「已绑定 → 恢复并刷新」。
--   ★★★ ★★ 关键：分支②**不检查分片是否可用**——
--     ★★ 因为「已绑定」的门本来就该指向那个分片。
--     ★★ 若那个分片不可用，由 Shard_UpdateWorldState(:109-116) 负责禁用。
--     ★★★ 两种函数分工：★ UpdateWorldState 管「分片侧的变化」，
--       ★ UpdatePortalState 管「门侧的生成」。
function Shard_UpdatePortalState(inst)
    if inst.components.worldmigrator.linkedWorld == nil then
        for k, v in pairs(ShardConnected) do
            -- Bind to first available shard that can be
            if inst.components.worldmigrator.shard_name == nil or inst.components.worldmigrator.shard_name == v.shard_name then
                -- Bind unused portals to this new server, mm-mm!
                inst.components.worldmigrator:ClearDisabledWithReason("MISSINGSHARD")
                inst.components.worldmigrator:SetDestinationWorld(k)
                return
            end
        end
--★★[第 136 行：找不到可用分片的日志 —— 与 :113 的措辞对比]
--   ★★★ 本行消息："(no available shard [%s] connected)"
--   ★★ 对比 :113 的 "(different permanent world)"：
--     · ★ :136 —— 「没有可用分片连接」；
--     · ★★ :113 —— 「不同的永久世界」。
--   ★★★ 两种「门不可用」的原因，日志措辞不同但 reason 都用 MISSINGSHARD。
--   ★ ★ 这种「统一 reason + 不同日志」的设计在排障时以日志为准。
        print(string.format("Skipping portal[%s] (no available shard [%s] connected)", tostring(inst.components.worldmigrator.id), inst.components.worldmigrator.shard_name or "n/a"))
        inst.components.worldmigrator:SetDisabledWithReason("MISSINGSHARD")
        inst.components.worldmigrator:ValidateAndPushEvents()
        return
--★★[第 140 行：分支①的 end —— 「空闲门且找不到分片」的处理完毕]
--   ★★★ 注意 return 已在 :133/:139，★ 所以走到这里的都是「循环完没找到」的情况。
    end
    inst.components.worldmigrator:ClearDisabledWithReason("MISSINGSHARD")
    inst.components.worldmigrator:ValidateAndPushEvents()
end
--★★★★★ §五 结束。Shard_UpdatePortalState —— 新传送门的反向绑定。
--   ★★★ 与 §四（Shard_UpdateWorldState）构成「双向触发」：
--     · 分片状态变 → UpdateWorldState 重扫所有门（:68）；
--     · ★ 新门生成 → UpdatePortalState 给门找分片（本函数）。
--   ★★ 两者共同保证「分片 ↔ 传送门」的一致性。

--★★[Shard_GetConnectedShards —— ★★ 调试接口（★ 返回深拷贝）]
--   return deepcopy(ShardConnected)
--   ★★★ 原注释第 145 行："-- useful for debugging" —— ★★ 明确是调试用途。
--   ★★ 返回**深拷贝**（而非原表）—— ★★ 关键设计：
--     ★★ 防止外部修改内部状态（表里含实体引用等复杂结构）。
--     ★★ deepcopy 递归复制（util.deepcopy），保证外部拿到的是快照。
--   ★★ 调用方（networking.lua:791 UpdateServerWorldGenDataString）：
--     · ★ 遍历 v.world[1] 取世界数据（见 networking.lua:792 的分析）；
--     · ★ 用拷贝 → 后续处理不影响真实的 ShardConnected。
--   ★ ★ 「调试接口」用 deepcopy 而非返回原表，是良好的封装习惯。
function Shard_GetConnectedShards() -- useful for debugging
    return deepcopy(ShardConnected)
end
--★ Shard_GetConnectedShards 结束。★ 返回 ShardConnected 的深拷贝（调试接口）。

--★★★ 分节线。【 分节标记】（源码风格，★ 划分第 2 大块：会话/存档/投票）。
--   ★★ 前半（§〇-§五）处理「分片状态」；
--   ★★ 后半（§六-§九）处理「跨分片的状态转发」。
--------------------------------------------------------------------------

--★★★[Shard_UpdateMasterSessionId —— ★★ 会话 id 的跨分片同步]
--   ★★★★ 签名：Shard_UpdateMasterSessionId(session_id)
--   ★★★ 第 152 行原注释（★ 重要的时序说明）：
--     "-- this will be nil if the connection happens during worldgen;
--      it will be sent on game start"
--   ★★★★ 「TheWorld 为 nil」的场景：
--     ★★ 分片连接发生在「世界生成期间」—— ★★ 此时世界实体还没建好。
--       ★★★ 所以 session_id 要等到「游戏开始」（游戏启动后）才发送。
--       ★ ★ 这是「有些数据要延后发送」的时序处理。
--   ★★★★ 第 153 行：TheWorld:PushEvent("ms_newmastersessionid", session_id)
--   ★★★ 「主分片的会话 id」需要同步给次分片（★ 存档/快照的会话标识）。
--     · session_id 是存档/快照体系的标识（见 :742 的 TruncateSnapshots）；
--     · ★★★ 次分片需要它来对齐自己的存档序列。
--   ★★★ ★ 这是一个「主分片的权威数据广播给次分片」的模式（★ 与 §八 月王广播同源）。
--     · TheWorld:PushEvent 而非 SendRPCToShard —— ★★ 因为**每个分片独立执行**本函数；
--       ★★ 主分片执行时推事件给本地，次分片执行时同样推给本地。
--       ★★★ 也就是说：★★ 不是「主推给次」，而是「各自收到这个值后本地使用」。
--     ★ ★ 消息由分片层（ShardManager）负责投递到各分片。
function Shard_UpdateMasterSessionId(session_id)
    if TheWorld ~= nil then -- this will be nil if the connection happens during worldgen; it will be resent on game start
        TheWorld:PushEvent("ms_newmastersessionid", session_id)
    end
end
--★★ §六 之一：会话 id 同步（:151 Shard_UpdateMasterSessionId）。
--   ★★★ 跨分片状态转发的第一个例子：主分片的 session_id 要让各分片知晓。

--★★★[Shard_WorldSave —— ★★ 跨分片存档请求（★ 只主分片执行）]
--   ★★★★ 第 158 行条件：`if TheWorld ~= nil and TheWorld.ismastershard then`
--     ★★ 只有主分片才响应存档 —— ★★ 因为存档由主分片统一管理。
--     ★★ ismastershard（不是 ismastersim）—— 见文件头注记 7。
--   ★★★★ 第 159 行：TheWorld:PushEvent("ms_save")
--     ★★★ 「存档」是个事件，不是一个函数调用 ——
--       ★★ 因为存档逻辑（写文件、维护快照序列）由 autosaver 组件负责，
--       ★★★ 监听 ms_save 事件（不直接调 autosaver:Save()）。
--       ★★ 「事件解耦」—— 存档的具体实现不关心谁触发的保存。
--     ★ 交叉引用：net.lua 的 autosaver 组件（见 :739 的 GetLastSaveTime）。
--   ★★★ 另一个分支（★ 推测）：
--     若 ismastershard 为假（次分片），★ 不响应存档请求。
--     ★★ 因为存档是全局的，由主分片协调（次分片的存档由事务系统合并，
--       ★★ 见 Shard_CreateTransaction_TransferInventoryItem :296）。
function Shard_WorldSave()
    if TheWorld ~= nil and TheWorld.ismastershard then
        TheWorld:PushEvent("ms_save")
    end
end
--★★ Shard_WorldSave 结束。★ 「ms_save」事件存档（只有主分片执行）。

--★★★ 分节线。【 分节标记】（投票相关，§七 之前）。
--------------------------------------------------------------------------

--★★★[Shard_StartVote —— ★★ 跨分片投票的发起]
--   ★★★★ 第 166 行条件：与 :158 相同的 ismastershard 守卫。
--   ★★★ 第 167-172 行：TheWorld:PushEvent("ms_startvote", {commandhash=..., starteruserid=..., targetuserid=...})
--   ★★★★ 载荷的三个字段（★ 投票的完整信息）：
--     · ★ commandhash —— ★★ 投票对应的「命令哈希」（如 kick ban reset）；
--       ★ 交叉参考：networking.lua:122-123 VoteAnnouncement 用 GetCommandFromHash；
--       ★★ 与它对应，这里是「发起投票」时的命令标识。
--     · ★ starteruserid —— ★ 发起投票的玩家（用于显示「XX 发起投票」）；
--     · ★★ targetuserid —— ★★ 投票目标（如踢谁）；★ **可能为 nil**（无目标的投票）。
--   ★★★★ 四个投票函数的统一模式（★ 全是「主分片执行 → 推事件」）：
--     · Shard_StartVote      (:165) 发起投票 → ms_startvote；
--     · Shard_StopVote       (:175) 结束投票 → ms_stopvote；
--     · Shard_ReceiveVote    (:181) 收到玩家投票 → ms_receivevote；
--     · ★★ 都是 ismastershard 守卫 + PushEvent。
--     ★★ 语义：★★ 投票是「全局状态」，只有主分片裁定。
--       ★★ 次分片收到的投票请求，转成事件给主分片（或本地不处理）。
--     ★ ★ 与 :151 Shard_UpdateMasterSessionId 一样，是「跨分片状态转发」的模式。
function Shard_StartVote(command_id, starter_id, target_id)
    if TheWorld ~= nil and TheWorld.ismastershard then
        TheWorld:PushEvent("ms_startvote", {
            commandhash = command_id,
            starteruserid = starter_id,
            targetuserid = target_id,
        })
    end
end

--★★[Shard_StopVote —— ★★ 结束投票]
--   ★★★ 第 177 行：TheWorld:PushEvent("ms_stopvote") —— ★ 无载荷。
--   ★★ 「停止」不需要参数（★ 相比 StartVote 的三字段载荷）。
--   ★★★ 与 :165 的 StartVote 配对（投票的「开始」与「结束」）。
function Shard_StopVote()
    if TheWorld ~= nil and TheWorld.ismastershard then
        TheWorld:PushEvent("ms_stopvote")
    end
end

--★★[Shard_ReceiveVote —— ★★ 收到玩家的投票]
--   ★★★★ 第 183-186 行：TheWorld:PushEvent("ms_receivevote", {selection=..., userid=...})
--     · ★ selection —— ★★ 玩家投了哪个选项（如「赞成」/「反对」）；
--       ★★ 这是一个枚举（玩家点了哪个投票选项）。
--     · ★ userid —— ★★ 投票人。
--     ★★ 两个字段：★★ 「谁投的」+「投什么」—— 投票的完整信息。
--   ★★★ 为什么 ReceiveVote 也要 ismastershard 守卫？
--     ★★ 因为投票结果需要主分片统计（★ 全局裁定）。
--   ★ ★ 「投票」是本文件 §六-§七 的典型：★ 主分片权威 + 次分片转发。
function Shard_ReceiveVote(selection, user_id)
    if TheWorld ~= nil and TheWorld.ismastershard then
        TheWorld:PushEvent("ms_receivevote", {
            selection = selection,
            userid = user_id,
        })
    end
end
--★★★ §六-§七 投票区结束。四个函数（:165/:175/:181 + 说明）全是
--   「主分片执行 → 推事件」的跨分片转发：
--     · Shard_StartVote   → ms_startvote（三字段载荷）；
--     · Shard_StopVote    → ms_stopvote（无载荷）；
--     · Shard_ReceiveVote → ms_receivevote（selection + userid）。
--   ★★ 投票是「全局状态」，只有主分片（ismastershard）裁定。

--★★★ 分节线。【 分节标记】（骰子冷却，§七）。
--------------------------------------------------------------------------

--★★★[RecentDiceRolls = {} —— ★★ 本文件唯一的局部状态表]
--   ★★★ 结构：{ user_id → 冷却结束时刻 }。
--   ★★★ 与文件头注记 8 呼应：★ 这是「按玩家限频」的简单范式。
--   ★ ★ 与 networkclientrpc.lua 的 RPC_Queue_Limiter（:1664）同源思想：
--     ★ 都是「记录每个主体的计数/状态，超限则拒绝」。
--     ★★ 但这里的实现更简单（无清理过期项的性能考虑问题）。
--   ★★ 注意是 local（不用外部访问）—— 比 ShardConnected 更私有。
local RecentDiceRolls = {}

--★★★[Shard_OnDiceRollRequest —— ★★ 骰子投掷的限频（★ 完整拆解）]
--   ★★★★ 签名：Shard_OnDiceRollRequest(user_id) → true/false
--   ★★★ 第 195-197 行：非主分片直接拒绝
--     if TheWorld == nil or not TheWorld.ismastershard then return false end
--     ★★ 两个守卫：
--       · TheWorld == nil —— ★★ 没有世界 → 无法判断（拒绝）；
--       · ★ not ismastershard —— ★★ 非主分片 → 骰子功能在此不生效。
--       ★★ 推测：★ 骰子可能是某种「跨分片共享的玩法」（如服务器抽奖）。
--   ★★★★ 第 199-209 行：★★ 清理过期冷却（★ 性能维护）
--     local curt = GetTime()
--     local toremove = {}
--     for id, endt in pairs(RecentDiceRolls) do
--         if curt > endt then table.insert(toremove, id) end
--     for _, id in ipairs(toremove) do RecentDiceRolls[id] = nil end
--   ★★★★ 这个「先收集后删除」的两步清理（★ 值得学习）：
--     ★★ 不能在 pairs 遍历中直接删（★ 遍历期间改表会漏项/崩）；
--     ★★ 所以先用 toremove 收集要删的键，再在第二个循环统一删。
--     ★★★ 这是 Lua 中安全删除表元素的经典范式。
--   ★★ 清理目的：★★ 防止 RecentDiceRolls 无限增长（内存）。
--     ★★ 与 :1664 RPC_Queue_Limiter 的「归零清表」同源（防泄漏）。
--   ★★★★ 第 211-214 行：★ 冷却检查
--     --Check that user is not still on cooldown
--     if RecentDiceRolls[user_id] ~= nil then return false end
--   ★★★ 简化检查：★ 只要表里有该用户（未过期的，已清理过）→ 在冷却中 → 拒绝。
--     ★★★ 关键：★★ 因为 :199-209 已经清理了过期项，
--       ★★★ 所以「还在表里」= 「冷却未过」。不需要比较时间。
--       ★★★ 这是「清理先行 + 简化判断」的组合优化。
--   ★★★★ 第 216 行：写入新冷却
--     RecentDiceRolls[user_id] = curt + TUNING.DICE_ROLL_COOLDOWN
--   ★★★ 「当前时间 + 冷却时长」= 冷却结束时刻。
--     ★★ TUNING.DICE_ROLL_COOLDOWN —— ★★ 「平衡参数表」（可调）。
--       ★★ 冷却时长在 TUNING 里定义（★ 策划可调，不硬编码）。
--     ★★★ 这是「平衡参数集中管理」的实践（与 locomotor 等的常量表同源）。
--   ★★ 最终 return true（第 217 行）—— ★ 允许投掷。
--   ★★★ ★★ 整体是「限频」的完整范式：
--     ① 权限守卫（非主分片拒绝）；
--     ② 清理过期；
--     ③ 冷却检查（在表里=冷却中）；
--     ④ 写入新冷却；
--     ⑤ 返回是否允许。
function Shard_OnDiceRollRequest(user_id)
--★★[第 195 行：TheWorld == nil or not ismastershard —— 双守卫]
--   ★★★ ★ 与 :158/:166/:176/:182 相同的守卫模式。
--     · TheWorld 为 nil → 拒绝（世界都没了）；
--     · 非主分片 → 拒绝（骰子只在主分片可用）。
    if TheWorld == nil or not TheWorld.ismastershard then
        return false
    end

    --Clear out old rolls
--★★[第 200-206 行：★★ 过期冷却的收集（★ 先收集后删除的第一阶段）]
--   ★★★ 「收集」阶段：遍历 RecentDiceRolls，找出已过期的（curt > endt）。
--   ★★ `local curt = GetTime()` —— 取当前时间（秒）。
--   ★ ★★ 与 networkclientrpc 的「逻辑刻」不同，这里用 GetTime()（墙上时间）。
--     ★★ 因为骰子冷却是「现实时间」概念（不需要与逻辑刻同步）。
    local curt = GetTime()
    local toremove = {}
    for id, endt in pairs(RecentDiceRolls) do
        if curt > endt then
            table.insert(toremove, id)
        end
    end
    for _, id in ipairs(toremove) do
        RecentDiceRolls[id] = nil
    end

    --Check that user is not still on cooldown
    if RecentDiceRolls[user_id] ~= nil then
        return false
    end

--★★[第 216 行：写入新冷却 —— TUNING 可调参数]
--   RecentDiceRolls[user_id] = curt + TUNING.DICE_ROLL_COOLDOWN
--   ★★★ 两个设计点：
--     · ★★ 用 TUNING 里的常量而非硬编码数字；
--       ★★ 策划可在 TUNING 表里调整冷却时长（★ 无需改代码）。
--     · ★★ 存「结束时刻」而非「剩余时间」——
--       ★★★ 为什么？★ 因为判断时只需比较「是否过期」（清理后）。
--       ★★ 存结束时刻的语义更明确（「这个用户冷却到 X 时刻」）。
--   ★ ★ 若存「剩余时间」，每次请求要减一次（且要处理浮点误差）。
    RecentDiceRolls[user_id] = curt + TUNING.DICE_ROLL_COOLDOWN
    return true
end
--★★★ §七 结束。Shard_OnDiceRollRequest —— 骰子限频（★ 完整范式）。
--   ★★ 五步：
--     ① 权限守卫（TheWorld 非 nil + ismastershard）；
--     ② 清理过期冷却（先收集后删除，Lua 安全范式）；
--     ③ 冷却检查（在表里=冷却中，因已清理过）；
--     ④ 写入新冷却（curt + TUNING.DICE_ROLL_COOLDOWN）；
--     ⑤ 返回是否允许（true/false）。
--   ★ ★ 与 networkclientrpc.lua:1664 的 RPC_Queue_Limiter 同源思想（按主体限频）。

--★★★ 分节线。【 分节标记】（月王/首领同步，§八）。
---------------------------------------------

--★★★[Shard_SyncBossDefeated —— ★★ boss 击败状态的跨分片广播]
--   ★★★★ 原注释："NOTES(JBK): Flipped shardid argument order to make calling
--   this easier elsewhere." —— ★★★ 「翻转了 shardid 参数顺序，让别处调用更方便」。
--     ★★ 函数签名是 (bossprefab, shardid)，而 RPC 的顺序是 (shardid, bossprefab)。
--     ★★★ 在 :225/228 处做转换（接收 shardid 补默认值）。
--   ★★★★ 第 223-229 行：主分片/次分片分支
--     if Shard_IsMaster() then
--         if TheWorld then
--             TheWorld:PushEvent("master_shardbossdefeated", {bossprefab=..., shardid=...})
--     else
--         SendRPCToShard(SHARD_RPC.SyncBossDefeated, SHARDID.MASTER, bossprefab)
--   ★★★★ 两个分支：
--     ★★ 主分片分支（:224-226）：
--       · ★★ 推事件 master_shardbossdefeated 给本地（供主分片逻辑处理）；
--       · ★★ 载荷含 shardid（★ 谁击败的 boss —— shardid or 默认）。
--       · ★★★ 这正是 :222 注释里「翻转参数顺序」的原因 ——
--         ★★★ 推事件时 shardid 作为载荷字段「放第二位」更自然（bossprefab 第一）；
--         ★★ 所以函数参数也按这个顺序设计（bossprefab 在前）。
--     ★★ 次分片分支（:228）：
--       · ★★ SendRPCToShard 通知主分片「我击败了这个 boss」。
--       · ★★ bossprefab 作为 RPC 参数（SHARD_RPC.SyncBossDefeated，
--         ★★★ 接收侧在 networkclientrpc.lua:1601）。
--   ★★★★ 「shardid or TheShard:GetShardId()」（:225）—— ★★ 默认值填充：
--     · ★★ 若调用方未提供 shardid（比如在本分片击败的），
--       ★★ 用自己的 shard_id 作为默认值。
--       ★★ 这让调用方可以省略 shardid（简化调用）。
--   ★★★ ★★ 与 :151/:157/投票的「主分片执行」模式的对比：
--     · 投票/存档：★ 只有主分片执行（次分片请求 → 主分片处理）；
--     · ★ boss：★★ 主分片处理本地 + 次分片 RPC 上报。
--     ★★★ boss 场景是「双向」：次分片也有 boss（月王在洞穴），
--       ★★ 所以次分片要上报给主分片（主分片统筹记录）。
function Shard_SyncBossDefeated(bossprefab, shardid) -- NOTES(JBK): Flipped shardid argument order to make calling this easier elsewhere.
    if Shard_IsMaster() then
        if TheWorld then
--★★[第 225 行：shardid or TheShard:GetShardId() —— 默认值填充]
--   ★★★ 若 boss 在本分片被击败（调用方没传 shardid），
--     ★★★ 用自己的 shard_id 作为「谁击败的」。
--   ★★ 这简化了调用方：「在本分片击败」时不必传 shardid。
--   ★ ★ 这个「or 默认值」的模式在 :257/:272/:287 也重复（DoTaskInTime 的延迟）。
            TheWorld:PushEvent("master_shardbossdefeated", {bossprefab = bossprefab, shardid = shardid or TheShard:GetShardId(),})
        end
    else
        SendRPCToShard(SHARD_RPC.SyncBossDefeated, SHARDID.MASTER, bossprefab)
    end
end

---------------------------------------------

--★★★[Shard_SyncMermKingExists —— ★★ 月王存在状态同步（★ 与 Boss 的差异）]
--   ★★★★ 签名：(exists, shardid) —— ★ 「存在」布尔（不是击败）。
--   ★★★★ 第 235-244 行：主次分片分支
--     if Shard_IsMaster() then
--         if TheWorld then TheWorld:PushEvent("master_shardmermkingexists", {exists=..., shardid=...}) end
--     else
--         TheWorld:DoTaskInTime(0, function() -- ★★ 延迟一帧
--             SendRPCToShard(SHARD_RPC.SyncMermKingExists, SHARDID.MASTER, exists)
--   ★★★★ ★★ 与 Shard_SyncBossDefeated 的关键差异（★ 第 240 行注释）：
--     ★★★ "This should be delayed a frame to let loading correctly handle
--        the RPC message."
--     ★★★ 「延迟一帧，让 loading 正确处理这条 RPC 消息」。
--     ★★★★ 为什么？推理（★ 关键理解）：
--       ★★ 月王生成/消失通常发生在**世界加载期间**；
--         ★★ 加载期间发 RPC → 消息可能在网络层未就绪时被丢弃或错乱；
--         ★★★ 延迟一帧（DoTaskInTime(0)）→ 等加载流程走完一帧再发。
--       ★★ 这是「时序敏感操作的延迟保护」（见文件头 §一 的「延迟一帧」原语）。
--     ★★ 与 :222 boss（直接发，不延迟）对比：
--       ★ boss 击败通常发生在**游戏中**（加载已完成）→ 直接发安全。
--       ★★ 月王存在变化发生在**加载期** → 需延迟。
--     ★★★★ 所以四个 MermKing 函数（:240/:257/:272/:287）★ 全都延迟一帧，
--       ★★★ 因为它们都可能在加载期被调用。
--   ★★★ 「存在的月王」是一个**全局状态**：主分片记录「月王在哪个分片」。
--     ★★ 用于跨分片逻辑（如「月王在哪」来决定掉落归属等）。
function Shard_SyncMermKingExists(exists, shardid) -- NOTES(JBK): Flipped shardid argument order to make calling this easier elsewhere.
    if Shard_IsMaster() then
        if TheWorld then
            TheWorld:PushEvent("master_shardmermkingexists", {exists = exists, shardid = shardid or TheShard:GetShardId(),})
        end
    else
--★★★[第 240 行：DoTaskInTime(0, ...) 的注释 —— 「延迟一帧」的公开理由]
--   TheWorld:DoTaskInTime(0, function() -- NOTES(JBK): This should be delayed
--       a frame to let loading correctly handle the RPC message.
--       SendRPCToShard(SHARD_RPC.SyncMermKingExists, SHARDID.MASTER, exists)
--   ★★★ 精确理由：★ 「延迟一帧让 loading 正确处理这条 RPC」。
--   ★★ 这印证了 prefabs/world.lua:301 的「DoTaskInTime(0) = 延迟一刻」原语
--     ★★★ 在跨文件、跨场景下的普遍应用（网络消息尤其敏感）。
        TheWorld:DoTaskInTime(0, function() -- NOTES(JBK): This should be delayed a frame to let loading correctly handle the RPC message.
            SendRPCToShard(SHARD_RPC.SyncMermKingExists, SHARDID.MASTER, exists)
        end)
    end
end

-- Merm King buffs --------------------------

--★★★[第 246-248 行：★ 「Merm King buffs」小节标记 + Shard_SyncMermKingTrident]
--   ★★ 第 246 行 "-- Merm King buffs --------------------------" 分节。
--   ★★★ 月王的三个部件（三叉戟/皇冠/护肩）各有独立的同步函数。
--   ★★ 函数签名：(exists, shardid) —— 「部件是否已被捡起」。
--   ★★★★ 第 249-261 行：与 Shard_SyncMermKingExists（:234）★ 完全同构：
--     · 主分片：推事件 master_shardmermkingtrident（:251）；
--     · 次分片：DoTaskInTime(0, ...) 延迟一帧 + SendRPCToShard（:257）。
--   ★★★ ★★ 五个函数（:222 boss + :234/:248/:263/:278 四个月王）★★ 高度同构。
--     ★★ 都是「主分片推事件 / 次分片延迟上报」的「跨分片状态广播」模板。
--     ★★★ 只有载荷/event 名/bossprefab 字段不同。
--   ★★★ 四个 MermKing 的载荷都有 `pickedup = exists`：
--     ★★ 第 252 行 `"pickedup = exists"` —— ★★ 字段名是 pickedup（已拾取）。
--       ★★ 与 Shard_SyncMermKingExists 的 `exists = exists`（:237）不同。
--       ★★ 语义微差：「部件已被捡起」vs「月王存在」。
function Shard_SyncMermKingTrident(exists, shardid) -- Flipped shardid argument order to make calling this easier elsewhere.
    if Shard_IsMaster() then
        if TheWorld then
            TheWorld:PushEvent("master_shardmermkingtrident", {
                pickedup = exists,
                shardid = shardid or TheShard:GetShardId(),
            })
        end
    else
        TheWorld:DoTaskInTime(0, function() -- This should be delayed a frame to let loading correctly handle the RPC message.
            SendRPCToShard(SHARD_RPC.SyncMermKingTrident, SHARDID.MASTER, exists)
        end)
    end
end

--★★[Shard_SyncMermKingCrown —— ★★ 月王皇冠同步（:263）]
--   ★★★ 与 Trident（:248）完全同构（:264-275），只有 event 名不同。
--   ★★★ 「皇冠」也是月王的可拾取部件（buff 道具）。
function Shard_SyncMermKingCrown(exists, shardid)
    if Shard_IsMaster() then
        if TheWorld then
            TheWorld:PushEvent("master_shardmermkingcrown", {
                pickedup = exists,
                shardid = shardid or TheShard:GetShardId(),
            })
        end
    else
        TheWorld:DoTaskInTime(0, function() -- This should be delayed a frame to let loading correctly handle the RPC message.
            SendRPCToShard(SHARD_RPC.SyncMermKingCrown, SHARDID.MASTER, exists)
        end)
    end
end

--★★[Shard_SyncMermKingPauldron —— ★★ 月王护肩同步（:278）]
--   ★★★★ 与前三个完全同构（:279-290），最后一个 MermKing 部件。
--   ★★★ ★ 至此月王有四个同步函数：
--     · :234 MermKingExists（存在性）；
--     · :248 Trident（三叉戟）；:263 Crown（皇冠）；:278 Pauldron（护肩）。
--   ★★★ 全部「主分片推事件 / 次分片延迟上报」。
function Shard_SyncMermKingPauldron(exists, shardid)
    if Shard_IsMaster() then
        if TheWorld then
            TheWorld:PushEvent("master_shardmermkingpauldron", {
                pickedup = exists,
                shardid = shardid or TheShard:GetShardId(),
            })
        end
    else
        TheWorld:DoTaskInTime(0, function() -- This should be delayed a frame to let loading correctly handle the RPC message.
            SendRPCToShard(SHARD_RPC.SyncMermKingPauldron, SHARDID.MASTER, exists)
        end)
    end
end
--★★★ §八 结束。月王与首领状态的跨分片广播（五个函数）。
--   ★★ 五个函数高度同构（★ 平行实现）：
--     · Shard_SyncBossDefeated    (:222) —— boss 击败（参数顺序被特意翻转）；
--     · ★ 四个 MermKing 函数（:234/:248/:263/:278）—— 月王存在/三叉戟/皇冠/护肩。
--   ★★★ 共同模式：
--     · 主分片 → 推事件 master_shard* ；
--     · ★ 次分片 → DoTaskInTime(0) 延迟一帧 + SendRPCToShard（★ 「等 loading」）；
--     · ★★ boss 直接发，MermKing 延迟发（因可能在加载期调用）。
--   ★★ 这五种「跨分片全局状态」的同步，是本文件的核心用途之一。

--★★★ 分节线。【 分节标记】（ShardTransactionSteps 包装，§九）。
--   "-- ShardTransactionSteps wrappers" —— ★★ 下面都是「跨分片事务」的薄包装。
---------------------------------
-- ShardTransactionSteps wrappers

--★★★[Shard_CreateTransaction_TransferInventoryItem —— ★★ 跨分片「物品转移」事务]
--   ★★★★ 第 297-304 行：
--     TheWorld.components.shardtransactionsteps:CreateTransaction(
--         shardid, SHARDTRANSACTIONTYPES.TRANSFERINVENTORYITEM,
--         { item = item, migrationdata = migrationdata })
--   ★★★★ 这是一个**极薄的包装**（转发到组件）：
--     · shardid —— ★★ 目标分片（物品要转移到哪里）；
--     · ★★ SHARDTRANSACTIONTYPES.TRANSFERINVENTORYITEM —— ★★ 事务类型枚举；
--       ★★★ 事务类型说明「这个事务做什么」—— ★ 可扩展（其他类型用其他枚举）；
--       ★★ 与 networkclientrpc 的 rpc_id 是同一思想（数字枚举标识操作）。
--     · ★★ { item = item, migrationdata = migrationdata } —— ★ 事务载荷：
--       ★ item —— ★★ 要转移的物品实体；
--       · ★★ migrationdata —— ★★ 「迁移数据」：
--         ★★★ 推测是「从源世界到目标世界的转换规则」（如换季节/传送门类型）。
--         ★★ 跨分片物品不能简单复制（不同世界的规则可能不同），
--           ★★★ 需要「迁移元数据」来正确落地。
--   ★★★★ 为什么需要「事务」（★ 分步提交）？
--     ★★★ 跨分片转移物品涉及**两个分片的状态**：
--       · 源分片：移除物品；
--       · ★ 目标分片：生成物品。
--     ★★★ 若中途失败（断线/崩溃），需要**回滚或重试**。
--       ★★ 事务 = ★ 「要么都做，要么都不做」/ 「分步但可协调」。
--     ★★★ 这就是 components/shardtransactionsteps.lua 的职责（分步提交）。
--   ★★ 交叉引用：
--     · components/shardtransactionsteps.lua（事务组件）；
--     · networkclientrpc.lua:1541 ShardTransactionSteps（接收侧）；
--     · :58 shardtransactionsteps:OnShardConnected（事务感知新分片）。
function Shard_CreateTransaction_TransferInventoryItem(shardid, item, migrationdata)
--★★[第 297 行：直接访问 TheWorld.components.shardtransactionsteps]
--   ★★★ 注意没有判空 —— ★★ 因为这个组件是「主分片必有」的
--     （prefabs/world.lua:568 在 ismastersim 分支添加）。
--   ★★ ★ 与 :58 的防御式写法（TheWorld and ... or nil）不同 ——
--     ★ 这里因为是主分片专用路径（组件必定存在），可以不判。
--   ★ ★ 但这依赖「只主分片调用」的隐式契约（见 :158 的守卫模式）。
    TheWorld.components.shardtransactionsteps:CreateTransaction(
        shardid,
        SHARDTRANSACTIONTYPES.TRANSFERINVENTORYITEM,
        {
            item = item,
            migrationdata = migrationdata,
        }
    )
end
--★★★ §九 结束。Shard_CreateTransaction_TransferInventoryItem —— 跨分片物品转移事务。
--   ★★★ 一个薄包装，转发到 shardtransactionsteps 组件的 CreateTransaction。
--   ★★ 关键概念：跨分片操作涉及「两个分片的状态」，需「事务」保证一致性
--     （要么都做、要么都不做 / 分步可协调）。
--   ★ ★ 这也解释了 :58 为什么在分片连接时要调 OnShardConnected ——
--     事务参与者变化时需要重新协商。

---------------------------------
--★★ 分节线（结尾）。
--   ★★★★ shardnetworking.lua 到此结束（307 行）。★★★ 全文件结构回顾（9 节）：
--     §〇   依赖与全局状态（1-10）—— 三张表分工
--     §一 ★★★ 分片身份判定（12-22）
--     §二 ★★★ 世界设置的跨分片同步（24-41）
--     §三 ★★ 连接建立时的握手（43-62）
--     §四 ★★★★ Shard_UpdateWorldState（68-121）—— ★ 本文件的心脏
--     §五   传送门与分片的双向绑定（125-143）
--     §六   调试与存档/会话/投票转发（145-188）
--     §七 ★★★ 骰子冷却（192-218）
--     §八 ★★ 月王与首领状态的跨分片广播（222-291）
--     §九   跨分片事务的包装（293-305）
--   ★★★ 本文件回答的核心问题：「分片如何协作」：
--     1) 分片身份怎么判定 → §一（ismastershard，双分支推断）；
--     2) 分片连上/断开怎么处理 → §四（状态表 + 传送门重绑）；
--     3) 跨分片如何同步状态 → §二/§六/§八（SHARD_RPC + 事件）；
--     4) 分片间操作用什么保证 → §九（事务，分步提交）。
