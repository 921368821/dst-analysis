--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：networking.lua
-- 模块：联机同步 / 玩家连接全生命周期与存档持久化入口
-- 职责：承担网络层派发给 Lua 的全部回调。包含聊天与公告的收发、
--       斜杠命令的服务端执行、玩家角色/皮肤的合法性校验（反作弊第一道闸）、
--       出生与无缝换角色的落地、玩家持久化存档的序列化（SerializeUserSession）、
--       模组列表对齐与下载、开服/加入/迁移三个流程的编排、
--       以及服务器标签与世界生成元数据字符串的生成。
-- 关键符号：Networking_SlashCmd, Networking_Say, ValidateSpawnPrefabRequest,
--           SerializeUserSession, DeleteUserSession, JoinServer, MigrateToServer,
--           StartDedicatedServer, DownloadMods, UpdateServerTagsString,
--           UpdateServerWorldGenDataString, GetDefaultServerData, LookupPlayerInstByUserID
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：networkclientrpc.lua（RPC 管线本体）、prefabs/world.lua:401 MakeWorld,
--           shardnetworking.lua（分片集群的 worldgen 数据合并）、
--           usercommands.lua（斜杠命令与投票）、chathistory.lua（聊天历史）
-- ★ 兴趣管理（兴趣中心点）在本文件中没有实现：
--   ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现；
--   Lua 唯一提供的是 prefabs/world.lua:544 的 TheFocalPoint 兴趣中心点实体。
--   参见 01-报告/04-联机同步-模组系统-UI.md:1318 与 05-原生C++引擎层.md:660。
--============================================================
--
--【阅读导航】
--  §零   依赖与首个实例启动（1-20）  —— os.execute 拉起第二个游戏进程
--  §一 ★ 聊天与公告（23-137）        —— 网络层派发给 Lua 的消息落地点
--  §二   说话/Twitch/皮肤校验（139-192）
--  §三 ★★★ 角色与皮肤合法性校验（194-246）—— 反作弊第一道闸门
--  §四 ★ 出生与无缝换角色（248-299）—— 跨 networking/world 两文件的链路
--  §五 ★★★ SerializeUserSession（301-330）—— 玩家持久化存档的序列化
--  §六   模组列表对齐与下载（332-489）—— 联机前的模组协商
--  §七 ★★★ JoinServer（491-644）     —— 加入流程的 UI 与协议编排
--  §八 ★★★ MigrateToServer（646-669）—— 跨服务器迁移：为什么必须重开进程
--  §九   颜色分配与重置/回滚（671-746）
--  §十 ★★ 标签与世界生成元数据（748-815）
--  §十一 GetDefaultServerData（817-847）—— 开服参数快照
--  §十二 ★★ StartDedicatedServer（849-882）—— 专服启动时序
--  §十三 快速加入评分（884-916）    —— 纯客户端侧的启发式排序
--  §十四 玩家查询与连接事件（918-955）
--  §十五 好友管理器（957-1003）     —— 唯一的 UI 状态持有者
--
--【★★★ 本文件最重要的九条】
--  1. ★★★「回调集合」而非「类」：本文件的函数全是**无 local 的全局函数**，
--     因为它们由 **C++ 网络层在特定时刻调用**（消息到达、存档时机、UI 事件）。
--     网络层只知道函数名，不持有实例 —— 所以必须是全局可查的名字。
--     ★ 对比 networkclientrpc.lua 的 HandleRPC（本文件的「对偶」：那边是接收端入口，
--       这边是被调用的具体实现）。
--  2. ★★★ 三种联机模式的识别（★ 最重要的判定）：
--     · TheNet:IsDedicated()          —— 「本进程有没有界面」（专服为真）
--     · TheNet:GetIsMasterSimulation() —— 「我是否持有模拟权威」（房主/专服为真）
--     · TheWorld.ismastersim           —— ★ 上述判定的**缓存字段**（见 prefabs/world.lua:426）
--     · TheWorld.ismastershard         —— 「我是否是主分片」（多分片集群用）
--     ★★ 组合起来区分四种身份：房主 / 专服 / 次分片 / 纯客户端。
--     ★ 注意：GetIsServer() 是第三个谓词，本文件第 14 行与 :304 用它，
--       语义上接近 ismastersim 但不完全等同（后者才与分片无关的纯权威概念）。
--     ★ 权威定义在 prefabs/world.lua:426-427，本文件处处引用那两个字段。
--  3. ★★★ SerializeUserSession（:303）是玩家存档的唯一出口：
--     双重归属校验（第 304 行）→ GetSaveRecord() 取全部组件存档 →
--     DataDumper 序列化 → TheNet:SerializeUserSession 交给存档层。
--     ★★ 两个判断值得记：
--       · 归属校验：player == ThePlayer（本地玩家）**或** GetIsServer()（服务端）
--         → ★ 含义：客户端只允许存自己的存档；服务端可以存任何人的。
--       · `userid:len() > 0` —— ★ 排除「还没有 userid 的实体」（如刚生成的 NPC）。
--  4. ★★★ 「一进程一世界」决定了 MigrateToServer 必须重启进程（:646）：
--     本文件第 418 行的 SpawnSecondInstance 已经示范了「开第二个进程」的做法；
--     MigrateToServer 用 StartNextInstance 走同一条路。
--     ★★ 原因：TheWorld 是全局单例（prefabs/world.lua:422），换服务器意味着换世界，
--       ★ 无法在同一个 Lua 状态里安全地「换掉」它 —— 只能重启。
--  5. ★★ ValidateSpawnPrefabRequest（:194）是反作弊第一道闸门：
--     白名单（DST_CHARACTERLIST / MODCHARACTERLIST）+ 归属校验（CheckClientOwnership）
--     + 降级策略（非法角色 → 回退到第一个合法角色而非踢人）。
--     ★ 第 201 行的 NOTES 记录了一个「行政级」入侵记录（[WERR] 日志）。
--  6. ★★ DownloadMods（:347）是联机模组协商的实现，约 140 行、四层嵌套：
--     临时关闭多余模组 → 检查必需模组 → 缺失则下载 → 下载后校验版本。
--     ★ 版本不符会明确报错（:462-463），而非静默降级。
--  7. ★★ JoinServer（:498）是纯 UI 编排，但藏着两个条件判断（:558/:628）：
--     「服务端开了模组」与「客户端模组被禁」的警告弹窗，
--     且都带 `not IsMigrating()` —— ★ 迁移过程中不弹窗（因为马上要重启）。
--  8. ★★ UpdateServerTagsString（:748）有源码自嘲：
--     "ughh... well at least try to keep this in sync with
--      servercreationscreen.lua BuildTagsStringHosting()"
--     ★★ 这是**已知的重复实现**，移植时必须两处同改（★ 双维护点）。
--  9. ★★ 存档写入分两级（★ 理解本文件的关键）：
--     · 玩家级：SerializeUserSession(:303) —— 每个玩家一份
--     · 世界级：SerializeWorldSession(:328) —— 整个存档一份（带回调）
--     ★★ 世界级会**回调**（onsaved，见 :862-866），因为它是异步落盘；
--       玩家级无回调（存档层内部处理）。
--
--【★ 已知缺陷与脆弱点（详见各锚点处的 ⚠ 注记）】
--  · :438-448 的二次校验循环里 `known_mods_good` 逻辑正确但版本比较依赖
--    modinfo_name（第 462 行）在 mod 缺失时会崩（潜在缺陷）。
--  · :336 的 pcall 结果 `status` 被丢弃，JSON 解析失败时仍会读 result_data。
--  · :15 的 `os.execute("start "..exepath)` 用字符串拼接启动进程 —— Windows 特有。
--  · :748 的标签字符串与 servercreationscreen.lua 重复实现（源码自承）。
--★★★[五条 UI 依赖 —— ★ 本文件的「界面属性」一览]
--   ★★★ 与 networkclientrpc.lua（零 UI 依赖）形成鲜明对比：
--     · networkclientrpc.lua 只 require util（:1）—— ★ 纯逻辑，无界面；
--     · ★ 本文件 require 了 5 个 screens/widgets 模块 —— 大量 UI 编排。
--   ★★ 原因分工（★ 理解本文件定位的关键）：
--     · networkclientrpc.lua = 「网络消息进游戏」的管道（无 UI）；
--     · ★ networking.lua = 「网络消息进游戏后要显示/提示什么」的落地（含 UI）。
--     · ★ 所以 JoinServer(:498)、after_client_mod_message(:557) 都在拼 UI 控件。
--   ★ 精确说：本文件既有纯逻辑（SerializeUserSession :303），
--     也有重 UI（JoinServer :498-644 的 150 行），是二者混合体。
--   ★★ 移植启示：若引擎不需要前端 UI，可剥离第 491-644 段，保留其余。
local InputDialogScreen = require "screens/redux/inputdialog"
local PopupDialogScreen = require "screens/redux/popupdialog"
local Widget = require "widgets/widget"
local ImageButton = require "widgets/imagebutton"
local Text = require "widgets/text"
local ConnectingToGamePopup = require "screens/redux/connectingtogamepopup"

--★★[UserCommands = require("usercommands") —— 唯一一条逻辑依赖]
--   ★★★ 它是本文件唯一非 UI 的 require，且被用了 4 次：
--     · :27 RunTextUserCommand —— 执行玩家发的斜杠命令
--     · :110/:113/:116/:119 SendCommandMetricsEvent —— 管理命令的遥测上报
--     · :123 GetCommandFromHash —— 从命令哈希取命令定义（投票用）
--   ★ 这也是「C2V」方向的体现（:27 执行的是客户端发来的命令）。
local UserCommands = require("usercommands")

--★ FirstStartupForNetworking = false —— ★ 首次启动标志（全局，无 local）
--   ★★★ 语义：区分「游戏刚启动（此时还在主菜单）」与「游戏中」。
--   ★ 用处见第 12-19 行 SpawnSecondInstance。
--   ★★★ 注意它是全局变量（无 local）—— 因为要跨文件共享
--     （main.lua 或 gamelogic.lua 可能读写它）。
--   ★ 在第 17 行被重置为 false（用掉之后立刻清）。
FirstStartupForNetworking = false

--★★★[SpawnSecondInstance —— ★「开第二个游戏进程」的 Windows 实现]
--   ★★★ 场景：房主在游戏中开新世界，DST 需要**两个游戏实例**同时运行
--     （一个继续当前世界，一个开新世界）。
--   ★★★ 第 15-16 行是本函数的核心：
--     local exepath = CWD.."\\..\\bin\\dontstarve_r.exe"
--     os.execute("start "..exepath)   -- run it in a separate process,
--                                        -- or we'll be frozen until it exits
--   ★★★ 两个设计要点：
--     ① ★ 路径推导：CWD（当前工作目录）+ "\\..\\bin\\dontstarve_r.exe"
--       → 从当前目录往上两级找 bin —— 说明 CWD 是 data/scripts 之类。
--       ★ `_r` 后缀是 release 版（与 `dontstarve.exe` 的 debug 版相对）。
--     ② ★ 原注释 "or we'll be frozen until it exits" —— ★★★ 关键信息：
--       ★ 「os.execute 在 Windows 上会**等待**子进程结束」；
--       ★ 必须用 `start` 命令（cmd 的 start 会立即返回，不等待）。
--       若直接 os.execute(exepath)，游戏会卡住直到新进程退出 ——
--       ★★ 而新进程在等这个进程退出 —— 死锁。
--   ★★ 这是 Windows 特有的行为差异（Linux 的 os.execute 不会阻塞）。
--     ★ 移植到 Linux/Mac 时**必须**去掉 start 前缀。
--   ★★ 依赖 CWD 的相对路径推导也很脆弱（换安装结构就失效）。
--   ★ 相关：:646 MigrateToServer 用 StartNextInstance（另一套跨进程机制）。
function SpawnSecondInstance()
    if FirstStartupForNetworking then
--★★[if TheNet:GetIsServer() then —— 「只有服务端能开第二实例」]
--   ★★ 为什么限制在服务端（房主/专服）？
--     推理：只有房主才有「另一个世界」的概念（专服是给所有人玩的，不开世界）。
--     纯客户端不需要开新世界。
--   ★★ GetIsServer 与 ismastersim 的区别（★ 见文件头注记 2）：
--     · GetIsServer() —— 「我是服务端吗」（房主 true、专服 true、客户端 false）
--     · ismastersim   —— 「我是权威吗」（房主 true、专服 true、客户端 false）
--     ★★ 在**单分片**世界里两者等价；在**多分片集群**里，
--       次分片也是「服务端」但可能不需要开新世界。
--     ★ 实际差异极小，本文件多处用 GetIsServer()。
        if TheNet:GetIsServer() then
            local exepath = CWD.."\\..\\bin\\dontstarve_r.exe"
            os.execute("start "..exepath)   -- run it in a separate process, or we'll be frozen until it exits
--★ FirstStartupForNetworking = false —— 「用掉了就清掉」，防止重复开进程
--   ★★ 单次性标志：函数可能被多次调用，但只能开一次进程。
            FirstStartupForNetworking = false
        end
    end
end
--★ SpawnSecondInstance 结束。★★ 它示范了「用 os.execute 开第二个进程」，
--   ★ 与 :650 的 StartNextInstance 是本文件的两处跨进程机制。


--★★★[Networking_SlashCmd —— ★★ 「C2V」方向的回调：服务端执行远程斜杠命令]
--   ★★★ 原注释 "V2C: This is for server side processing of remote slash command requests"
--     ★★ 注意这个注释的措辞矛盾（V2C 却描述服务端处理客户端请求 → 实为 C2V）。
--     ★ 说明源码里的方向标注并非总严谨（见文件头关于 V2C/C2V 的说明）。
--   ★★★ 签名：Networking_SlashCmd(guid, userid, cmd)
--     · guid    —— 发送者的实体 GUID（可能为 nil/无效）
--     · userid  —— 发送者的账号 ID
--     · cmd     —— 命令文本
--   ★★ 第 25 行的双来源回退是本函数最值得理解的设计：
--     local caller = Ents[guid] or TheNet:GetClientTableForUser(userid)
--     ★★ 原注释 "Either an actual entity or a table with some data."
--   ★★★ 为什么需要两个来源？
--     · 正常情况：guid 有效 → Ents[guid] 拿到玩家实体（可以访问 components）；
--     · ★ 异常情况：玩家还没生成实体（刚连上）→ Ents[guid] 为 nil；
--       ★★ 此时退而求其次用 GetClientTableForUser(userid) —— 
--       ★★ 拿到的是 C++ 侧的「客户端信息表」（含 userid/name 等基础数据，
--         但**没有** components）。
--   ★★★ 这与 networkclientrpc.lua:1398 的 USERID_RPCS 是**同一个问题的两种解法**：
--     · 那边：RPC 明确标记「本 handler 收 userid」；
--     · ★ 这边：运行时探测「实体拿不到就退到客户端表」。
--   ★★ 安全考量：UserCommands.RunTextUserCommand(cmd, caller, true)
--     第三个参数 true —— ★ 推测是「来自远程/需额外校验」的标志。
--     ★★ 推理：远程发来的命令必须在**服务端**执行，且权限要按 userid 判定
--       （而不是按实体 —— 因为实体可能不存在）。
--     ★ 第 27 行的第三个参数 true 与第 24 行的函数注释共同说明：
--       「这条命令被视为远程请求」→ 权限校验走 userid 路径。
--   ★★ 参见 networkclientrpc.lua:1073 的 userid RPC 与 usercommands 的命令解析。,
--V2C: This is for server side processing of remote slash command requests
function Networking_SlashCmd(guid, userid, cmd)
    local caller = Ents[guid] or TheNet:GetClientTableForUser(userid) -- NOTES(JBK): Either an actual entity or a table with some data.
--★ if caller ~= nil then —— 两种来源都拿不到时静默丢弃
--   ★ 推理：连客户端表都没有 → 这个 userid 完全不认识 → 丢弃。
--   ★ 不打印错误 —— 与 networkclientrpc.lua 的 printinvalid 不同（那是 RPC 层）。
    if caller ~= nil then
        UserCommands.RunTextUserCommand(cmd, caller, true)
    end
end
--【机制：C2V 斜杠命令入口】客户端发来的斜杠命令在服务端落地。
--   ★ 核心：双来源取 caller（Ents[guid] → GetClientTableForUser(userid)），
--     解决「玩家实体尚未生成」的时序问题。参见 :25 的详解。
--★★ 参见 networkclientrpc.lua:1675 HandleRPC（RPC 管线的接收端入口），
--   ★★ 参见 networkclientrpc.lua:1398 USERID_RPCS（同一时序问题的显式标记解法）。

--★★★[Networking_Announcement —— ★ 全文件的「公告基类」，几乎所有提示都走它]
--   ★★★ 签名：Networking_Announcement(message, colour, announce_type)
--   ★★★ 三个参数的角色：
--     · message —— 文本（★ 若为 nil 直接返回，所以它可以是无条件调用的）
--     · colour  —— RGBA（默认 {1,1,1,1}，即不透明白）
--     · ★★ announce_type —— ★ 公告类型（决定显示样式与是否进历史）
--   ★★ announce_type 的取值在本文件随处可见：
--     "default"（:35）、"mod"（:72）、"death"（:79）、"resurrect"（:83）、
--     "join_game"（:92）、"leave_game"（:96）、"kicked_from_game"（:100）、
--     "banned_from_game"（:104）、"vote"（:130）、"dice_roll"（:136）
--     ★★ 这是一个「用字符串枚举代替子类型」的轻量设计 ——
--       便于模组新增类型而不用改本文件。
--   ★ ChatHistory:OnAnnouncement(message, colour, announce_type)
--     ★★ 注意落点是 ChatHistory（聊天历史）而非直接 UI ——
--       ★ 说明所有公告都被**记入历史**，玩家可以往上翻看。
--   ★ 交叉引用：chathistory.lua。
function Networking_Announcement(message, colour, announce_type)
    if message then
        colour = colour or {1, 1, 1, 1}
--★★[if not announce_type or announce_type == "" then —— 空类型兜底]
--   ★★ 两个条件都用 or：既处理 nil（没传），又处理空串（传了但空）。
--     ★ 推理：模组或旧代码可能传空串，用 or 统一兜底。
--   ★ 默认 "default" —— 通用样式。
        if not announce_type or announce_type == "" then
            announce_type = "default"
        end
        ChatHistory:OnAnnouncement(message, colour, announce_type)
    end
end

--★ Networking_SkinAnnouncement —— 皮肤获取公告。
--   ★★★ 三个参数全部判空（第 42 行）——
--     ★ 推理：三个都是必需信息（用户名、颜色、皮肤名），缺一无法显示。
--     ★ 与 :31 的 message 可为 nil 形成对比（那里的 message 是可选的）。
function Networking_SkinAnnouncement(user_name, user_colour, skin_name)
    if user_name and user_colour and skin_name then
        ChatHistory:OnSkinAnnouncement(user_name, user_colour, skin_name)
    end
end

--★ Networking_SystemMessage —— 系统消息（如「你被踢了」）。
--   ★ 与 :31 的区别：走 OnSystemMessage（系统消息专用通道），
--     ★★ 推测在 UI 上有不同样式（如红色警告）。
function Networking_SystemMessage(message)
    if message then
        ChatHistory:OnSystemMessage(message)
    end
end
--【机制：公告消息总线】所有网络公告最终都落到 ChatHistory。
--   ★ announce_type 是字符串枚举（12 种），加新类型不必改本文件。
--   ★★ 可覆盖钩子 Networking_Announcement_GetDisplayName(:87) 改变名字显示。

--★★★★★[Networking_Say —— ★★ 玩家说话：★ 本文件最需要逐行理解的函数]
--   ★★★ 签名：Networking_Say(guid, userid, name, prefab, message, colour,
--                    whisper, isemote, user_vanity)
--   ★★★ 九个参数，但核心只有三个：guid（谁说的）、message（说了什么）、
--     whisper（悄悄话还是公开）。
--   ★★ 它的「双通道」结构（第 61-67 行）：
--     ① 「世界内说话」：让该实体的 talker 组件发声（第 61-63 行）；
--     ② 「聊天框显示」：记入 ChatHistory（第 65-67 行）。
--     ★★ 为什么两个都要？玩家的话同时出现在「头顶气泡」和「聊天框」里。
--   ★★ 参见 components/talker.lua（气泡）、chathistory.lua（聊天框）、,
function Networking_Say(guid, userid, name, prefab, message, colour, whisper, isemote, user_vanity)
--★★★★★[第 54-56 行：★ 长度限制 —— 本函数的第一道防线]
--   if message ~= nil and message:utf8len() > MAX_CHAT_INPUT_LENGTH then return end
--   ★★★ 三个细节：
--     ① ★★ `message:utf8len()` —— ★ 用 UTF-8 感知的长度而非 #message。
--       ★★ 推理：`:len()` 统计字节数（中文 1 字 = 3 字节），
--         若用 #message 会把「7 个汉字的句子」误判为超长。
--         ★★ 这是一个对中文玩家直接相关的正确性细节。
--     ② ★ 提前 return（静默丢弃）—— 超长直接不显示，不报错不打警告。
--     ★★ 推理：超长可能是客户端 bug（输入框限制失效），也可能是攻击。
--       ★ 两种情况都不该让服务端崩或刷屏 —— 静默丢弃是安全的默认。
--     ③ ★★ 检查在**最前面**（早于任何实体操作）——
--       「先校验，后使用」的标准顺序。
--   ★ MAX_CHAT_INPUT_LENGTH 是全局常量（客户端输入框也用它）。
--   ★★ 对比 networkclientrpc.lua 的 checkstring：那里只查类型、不查长度，
--     ★ 因为「哪些 RPC 的参数需要长度限制」是业务知识，由本函数负责。
--     → 这是「谓词管类型、业务管约束」分工的又一例（见 networkclientrpc §零）。
    if message ~= nil and message:utf8len() > MAX_CHAT_INPUT_LENGTH then
        return
    end

--★★[local netid = TheNet:GetNetIdForUser(userid) —— 取网络 ID]
--   ★★★ netid 是「这个连接的网络标识」（区别于 userid 账号标识）。
--   ★★★ 为什么需要它？第 62 行把它传给 talker:Say 作为最后一个参数，
--     ★★ 用途：让气泡里的文字能正确归属（区分「同名玩家的不同连接」）。
--   ★★ 推测它用于消息的「作者标记」，让客户端知道这条气泡是谁发的
--     （比 guid 更底层，因为它在 C++ 网络层）。
	local netid = TheNet:GetNetIdForUser(userid)

    local entity = Ents[guid]
--★★★[第 61 行：`if not isemote and entity ~= nil and entity.components.talker ~= nil then`]
--   ★★★ 三个条件：
--     · not isemote —— ★★ 表情动作**不产生气泡**。
--       推理：isemote=true 表示「这是表演动作」（跳舞、唱歌），
--       ★★ 那应该走表演系统的表现（音乐/特效），而非说话气泡。
--     · entity ~= nil —— Ents[guid] 可能无效（玩家刚走）。
--     · ★ entity.components.talker ~= nil —— 该实体有说话组件。
--       推理：不是所有实体都能说话（怪物、物品没有 talker 组件）。
--   ★★ 三重防御：动作类型 + 实体存在 + 组件存在。
--   ★ 对比 :63 行的 ChatHistory:OnSay **没有** isemote 判断 ——
--     ★★★ 推测表情动作**也会**进聊天历史（只是没有气泡）。
--     ★★ 这是一个「同一事件、两路呈现、不同规则」的典型例子。
    if not isemote and entity ~= nil and entity.components.talker ~= nil then
--★★★[第 62 行：talker:Say 的十个参数与其中的三处精妙处理]
--   entity.components.talker:Say(not entity:HasTag("mime") and message or "", nil, nil, nil, true, colour, TEXT_FILTER_CTX_CHAT, netid)
--   ★★★★ 三处需要展开：
--     ① ★★★ `not entity:HasTag("mime") and message or ""` —— 哑剧特殊处理：
--       ★ mime（哑剧演员）说的是「无声的台词」—— 气泡里要显示台词文字，
--         但**实际不发声**；非 mime 玩家才真正说话。
--       ★★ 这里用 `A and B or ""`：若 HasTag("mime") 为真，
--         `not true and message` = false，`false or ""` = ""（空串）；
--         若为假，`not false and message` = message，`message or ""` = message。
--       ★★★ 注意：这正是 :1073/1080 里讨论的「Lua and/or 三目陷阱」的正确用法 ——
--         关键是中间的 `message` 一定为真值（上面已判过 ~= nil 且非超长）。
--       ★ 所以这里安全。而 :1076 的 `GetPopupFromPopupCode(...)` 作为中间值
--         就有风险（若返回 false 会取 or 的右值）—— 对比可见两处的严谨性差异。
--     ② ★★ 第 5 个参数 `true` —— 推测是「立即显示/不排队」。
--     ③ ★★ colour + TEXT_FILTER_CTX_CHAT —— 颜色与文本过滤上下文：
--       ★ TEXT_FILTER_CTX_CHAT 告诉过滤器「这是聊天内容」
--         （而非告示牌/书籍等其他文本来源），过滤规则可分别配置。
--     ★ netid（最后）—— 见 :58 的注记。
--   ★★ 整体：一个调用里塞了「哑剧判定 + 颜色 + 过滤上下文 + 网络归属」，
--     ★ 是本文件最密集的一行。
        entity.components.talker:Say(not entity:HasTag("mime") and message or "", nil, nil, nil, true, colour, TEXT_FILTER_CTX_CHAT, netid)
    end

    if message then
        ChatHistory:OnSay(guid, userid, netid, name, prefab, message, colour, whisper, isemote, user_vanity)
    end
end
--【机制：玩家发言双通道】同一句话走两条呈现路径。
--   · 世界气泡：talker:Say（:62，★ 含 mime 哑剧置空、颜色、过滤上下文、netid）；
--   · 聊天框：ChatHistory:OnSay（:66，★ 表情动作也进聊天历史）。
--   ★ 长度防护：:54 的 message:utf8len() > MAX_CHAT_INPUT_LENGTH（★ UTF-8 感知）。
--★★ 参见 components/talker.lua（气泡渲染）、chathistory.lua（聊天历史）；
--   ★★ 参见 networkclientrpc.lua:1233（DoubleTapAction 用同样的过滤上下文机制）。

--★★[Networking_ModOutOfDateAnnouncement —— 模组版本过旧警告]
--   ★★ IsRail() 分支 —— ★ 「Rail」是 WeGame/腾讯代理的版本（国服渠道）。
--     ★ 推理：不同渠道的模组版本体系不同，需要不同的提示文案。
--     ★★★ 这个分支本身泄露了一个重要信息：★ DST 有非 Steam 的发行渠道。
--   ★★ 两条 STRINGS 分别对应两渠道（OUT_OF_DATE_RAIL vs OUT_OF_DATE）。
--   ★ 注意 announce_type = "mod"（模组专用样式）。
function Networking_ModOutOfDateAnnouncement(mod)
    if IsRail() then
        Networking_Announcement(string.format(STRINGS.MODS.VERSIONING.OUT_OF_DATE_RAIL, mod), nil, "mod")
    else
        Networking_Announcement(string.format(STRINGS.MODS.VERSIONING.OUT_OF_DATE, mod), nil, "mod")
    end
end

--★ Networking_DeathAnnouncement —— 死亡公告（type="death"）。
--   ★★★ 这是 Networking_Announcement（:31）的**薄包装**：
--     固定 announce_type，转发其余参数。
--   ★★★ 6 个这样的包装（:78/:82/:91/:95/:99/:103/:122/:135），
--     ★★ 它们的存在只有一个理由：★ 给 C++/其他文件一个稳定的调用点。
--     转发后本文件不必到处写字符串字面量，改文案只需改这一处。
function Networking_DeathAnnouncement(message, colour)
    Networking_Announcement(message, colour, "death")
end

--★ Networking_ResurrectAnnouncement —— 复活公告（type="resurrect"）。
function Networking_ResurrectAnnouncement(message, colour)
    Networking_Announcement(message, colour, "resurrect")
end

--★★★[Networking_Announcement_GetDisplayName —— ★ 唯一的「可覆盖钩子」]
--   ★★★ 原注释 "For ease of overriding in mods" —— ★★★ 专为模组覆盖而设。
--   ★★★ 它是一个恒等函数（return name），存在的意义纯粹是「一个可替换的点」：
--     · 模组写 Networking_Announcement_GetDisplayName = function(name) ... end
--     · 就能改变**所有**公告里玩家名的显示方式（加前缀、变色等）。
--   ★★ 与 :31 的 announcement_type 字符串枚举是同一套扩展哲学：
--     · 「字符串枚举」= 加新类型不改本文件；
--     · ★「恒等钩子」= 改行为不改本文件。
--   ★★ 4 个公告函数（:91/:95/:99/:103）都经过它。
--   ★ 注意它**只**用于「加入/离开/踢出/封禁」四类，玩家自己说话（:66）
--     走的是 ChatHistory:GetDisplayName（见 :136 的对照）—— ★ 两条不同的路径。
--For ease of overriding in mods
function Networking_Announcement_GetDisplayName(name)
    return name
end

--★ Networking_JoinAnnouncement —— 「XX 加入了游戏」。
--   ★★ type="join_game"。经 GetDisplayName 处理名字。
function Networking_JoinAnnouncement(name, colour)
    Networking_Announcement(string.format(STRINGS.UI.NOTIFICATION.JOINEDGAME, Networking_Announcement_GetDisplayName(name)), colour, "join_game")
end

--★ Networking_LeaveAnnouncement —— 「XX 离开了游戏」。type="leave_game"。
function Networking_LeaveAnnouncement(name, colour)
    Networking_Announcement(string.format(STRINGS.UI.NOTIFICATION.LEFTGAME, Networking_Announcement_GetDisplayName(name)), colour, "leave_game")
end

--★ Networking_KickAnnouncement —— 「XX 被踢出」。type="kicked_from_game"。
function Networking_KickAnnouncement(name, colour)
    Networking_Announcement(string.format(STRINGS.UI.NOTIFICATION.KICKEDFROMGAME, Networking_Announcement_GetDisplayName(name)), colour, "kicked_from_game")
end

--★ Networking_BanAnnouncement —— 「XX 被封禁」。type="banned_from_game"。
function Networking_BanAnnouncement(name, colour)
    Networking_Announcement(string.format(STRINGS.UI.NOTIFICATION.BANNEDFROMGAME, Networking_Announcement_GetDisplayName(name)), colour, "banned_from_game")
end

--★★[第 107-108 行：TODO V2C —— ★ 两条自承的未完成注记]
--   "-- TODO V2C: Call these appropriately from C"
--   "-- these should only run on the server. Could also call
--    SendCommandMetricsEvent directly if you prefer."
--   ★★★ 解析：
--     ① "Call these appropriately from C" —— ★ C++ 侧应该调用这四个遥测函数，
--       但**尚未接线**（TODO）。→ 它们现在可能是死代码。
--     ② ★ "these should only run on the server" —— ★ 明确它们是服务端专用。
--     ③ ★ "Could also call SendCommandMetricsEvent directly" ——
--       承认这几个包装函数**可以省略**，直接调 SendCommandMetricsEvent 即可。
--   ★★ 这段注释是「作者的自省记录」，价值很高：
--     · 它说明当前架构尚未完成（管理命令的遥测没接上）；
--     · ★ 也说明这层包装的存在是**历史选择**而非必要设计。
--   ★ 移植提示：★ 这四个函数可以视为可选的遥测层，
--     若新引擎不需要管理操作遥测，可整体删除。
-- TODO V2C: Call these appropriately from C
-- these should only run on the server. Could also call SendCommandMetricsEvent directly if you prefer.
--★★[Networking_KickMetricsEvent —— 管理操作遥测（踢人）]
--   ★★★ 签名：Networking_KickMetricsEvent(caller, target)
--     ★ caller —— 谁执行的（房主/控制台/投票）
--     ★ target —— 踢谁
--   ★★ 注释里提到的第三个参数（被注释掉）：`-- source)`
--     ★ 「source」= 命令发起源（console / slashcommand / vote）。
--     ★★★ 它被注释掉了 —— ★ 说明**实际实现不需要区分来源**，
--       或区分逻辑在 SendCommandMetricsEvent 内部。
--     ★ 这是一个「接口预留」的痕迹：签名曾考虑过 source。
--   ★ UserCommands.SendCommandMetricsEvent("kick", target, caller)
--     ★★ 注意参数顺序与本函数签名不同（target 在前，caller 在后）——
--       转发时重排，容易看错。
function Networking_KickMetricsEvent(caller, target) -- source) -- source is where the command was issued, i.e. console, slashcommand, vote
    UserCommands.SendCommandMetricsEvent("kick", target, caller)
end
--★ Networking_BanMetricsEvent —— 封禁遥测。与 :109 完全同构。
function Networking_BanMetricsEvent(caller, target) -- source) -- source is where the command was issued, i.e. console, slashcommand, vote
    UserCommands.SendCommandMetricsEvent("ban", target, caller)
end
--★ Networking_RollbackMetricsEvent —— 回滚存档遥测（无 target，只有 caller）。
--   ★★ 与前两个的差异：SendCommandMetricsEvent("rollback", nil, caller)
--     ★ target 传 nil —— 回滚不针对特定玩家。
function Networking_RollbackMetricsEvent(caller) -- source) -- source is where the command was issued, i.e. console, slashcommand, vote
    UserCommands.SendCommandMetricsEvent("rollback", nil, caller)
end
--★ Networking_RegenerateMetricsEvent —— 重生成世界遥测。同样无 target。
function Networking_RegenerateMetricsEvent(caller) -- source) -- source is where the command was issued, i.e. console, slashcommand, vote
    UserCommands.SendCommandMetricsEvent("regenerate", nil, caller)
end

--★★★[Networking_VoteAnnouncement —— ★ 投票结果公告（含命令哈希反查）]
--   ★★★ 第 123 行：`local command = UserCommands.GetCommandFromHash(commandid)`
--     ★★ commandid 是**哈希**（不是名字），需要反查回命令定义。
--     ★ 与 networkclientrpc.lua:937 的 rpc_id 反查是同一模式（数字/哈希→实体对象）。
--   ★★ 第 124 行的 `if command ~= nil and command.vote then`：
--     · command 存在（哈希有效）；
--     · ★★ command.vote 为真（**这是一个投票型命令**）。
--     ★★ 双重校验的意义：只有「确实带投票机制的命令」才播报投票结果。
--   ★★★ 第 125-126 行：投票名的格式化（可被命令自定义）：
--     ResolveCommandStringProperty(command, "votenamefmt", STRINGS...DEFAULTVOTENAMEFMT)
--     ★★ 「可解析的命令字符串属性」机制：命令定义里可以指定自己的格式串，
--       没有则用全局默认值。→ ★ 命令可以自定义 UI 文案。
--     ★★ 第 126 行：`targetname:len() > 0 and targetname or ""`
--       —— 目标名为空时用空串（投票可以针对「无人」？如「重生成世界」）。
--   ★★ 第 127-129 行的 fmt 三元选择：
--     fmt = passed and (VotePassedFmt or DEFAULT) or (VoteFailedFmt or DEFAULT)
--     ★★ 注意结构：passed 为真时取「通过」格式串（且有 or 兜底），
--       否则取「失败」格式串。
--     ★ 这是一个「双重兜底」的写法（每个分支都再 or 一次默认值）。
--   ★★ 第 131 行 `return command.name` —— ★★ 返回命令名！
--     ★★★ 这不是无意的：返回值供调用方使用（如 UI 显示、后续逻辑）。
--     ★ 命令非投票型时隐式返回 nil（第 133 行没有 return）。
function Networking_VoteAnnouncement(commandid, targetname, passed)
    local command = UserCommands.GetCommandFromHash(commandid)
    if command ~= nil and command.vote then
        local fmt = ResolveCommandStringProperty(command, "votenamefmt", STRINGS.UI.NOTIFICATION.DEFAULTVOTENAMEFMT)
        local votename = string.format(fmt, targetname:len() > 0 and targetname or "")
        fmt = passed and
            ResolveCommandStringProperty(command, "votepassedfmt", STRINGS.UI.NOTIFICATION.DEFAULTVOTEPASSEDFMT) or
            ResolveCommandStringProperty(command, "votefailedfmt", STRINGS.UI.NOTIFICATION.DEFAULTVOTEFAILEDFMT)
        Networking_Announcement(string.format(fmt, votename), nil, "vote")
        return command.name
    end
end

--★★[Networking_RollAnnouncement —— 骰子结果公告]
--   ★★ 第 136 行的复合 string.format：
--     STRINGS.UI.NOTIFICATION.DICEROLLED 包含 3 个占位符
--     · ChatHistory:GetDisplayName(name, prefab) —— ★★ 注意用的是 ChatHistory 的
--       而不是 :87 的 Networking_Announcement_GetDisplayName！
--       ★★★ 两条不同的名字显示路径（见 :86 的注记）。
--     · table.concat(rolls, ", ") —— ★★ 把骰子数组拼成 "3, 5, 2"
--     · max —— 最大可能值
--   ★★ rolls 是一个数组（一次投多颗骰子），需要拼接。
--   ★ announce_type = "dice_roll"。
function Networking_RollAnnouncement(userid, name, prefab, colour, rolls, max)
    Networking_Announcement(string.format(STRINGS.UI.NOTIFICATION.DICEROLLED, ChatHistory:GetDisplayName(name, prefab), table.concat(rolls, ", "), max), colour, "dice_roll")
end
--★★★ 聊天与公告区结束（§一）。★★★ 结构小结：
--   · 1 个基类（Networking_Announcement :31）；
--   · 8 个固定 type 的薄包装（:78/:82/:91/:95/:99/:103/:122/:135）；
--   · 1 个可覆盖钩子（Networking_Announcement_GetDisplayName :87）；
--   · 1 个带参数校验的实现（Networking_Say :53）。
--   ★★ 全部落在 ChatHistory —— 所有网络消息都进聊天历史（可上翻）。
--【机制：管理操作遥测】四个 MetricsEvent 函数（踢/封/回滚/重生成）。
--   ★★ 源码自承（C 侧尚未接线，见 :107 TODO）：目前接近死代码。
--★★ 参见 usercommands.lua（命令注册/权限/投票的实现）；
--   ★★ 参见 networkclientrpc.lua:1258 WobyCommand（另一条命令下发通道）。

--★★[Networking_Talk —— 「实体说话」（非聊天）]
--   ★★ 与 Networking_Say（:53）的区别：
--     · :53 是**玩家**在聊天框/头顶说话（有 ChatHistory 参与）；
--     · ★ :139 是**实体**说话（怪物、NPC），只有头顶气泡，无聊天记录。
--   ★★★ 签名：Networking_Talk(guid, message, duration, text_filter_context, original_author)
--     · duration —— ★★ 气泡显示时长（可为 nil = 默认）；
--     · ★★ text_filter_context —— 文本过滤上下文；
--     · ★★ original_author —— ★ 原始作者（★ 代理说话时用：
--       ★ 「X 通过鹦鹉说了话」这类玩法需要标记真正的说话者）。
--   ★★★ 第 142 行的参数：
--     entity.components.talker:Say(message, duration, nil, nil, true, nil,
--                               text_filter_context, original_author)
--     ★★ 注意第 6 个参数是 **nil**（对比 :62 传的是 colour）——
--       NPC 说话不需要玩家专属颜色。
--   ★ 交叉引用：components/talker.lua。
function Networking_Talk(guid, message, duration, text_filter_context, original_author)
    local entity = Ents[guid]
    if entity ~= nil and entity.components.talker ~= nil then
        entity.components.talker:Say(message, duration, nil, nil, true, nil, text_filter_context, original_author)
    end
end
--★ Networking_Talk 结束。★ 与 :53 的 Networking_Say 是「玩家说」与「实体说」之分。

--★★[OnTwitchMessageReceived —— ★★ Twitch 联动的三个回调之一]
--   ★★★ 三个 Twitch 回调（:146/:156/:165）结构完全一致：
--     if TheWorld ~= nil then TheWorld:PushEvent("twitch...", {...}) end
--   ★★★ 共同模式：★ 把网络层回调**转发成世界事件**。
--   ★★ 为什么这么做（★ 关键理解）？
--     · 网络层（Twitch 集成在 C++/SDK 侧）只认全局函数名；
--     · ★ 但游戏逻辑（谁关心 Twitch 消息）应该通过事件订阅解耦；
--     · ★★ PushEvent 正是这个「网络 → 游戏」的桥（TheWorld 是全局事件总线，
--       见 prefabs/world.lua:606 的同类用法）。
--   ★★★ 三个事件的载荷各不相同：
--     · twitchmessage: {username, message, colour}
--     · twitchloginresult: {success, result}
--     · twitchstatusupdate: {status}
--   ★★ 为什么都有 `if TheWorld ~= nil`？
--     ★ These callbacks can fire before the world exists (loading screens).
--     ★ → 推送前必须确认世界存在，否则 PushEvent 会崩。
--   ★ 这解释了本文件为何到处都是 `TheWorld ~= nil` 检查 ——
--     ★ 网络回调的到达时刻**不受游戏生命周期控制**。
--   ★★ 这是「外部系统集成」的通用模式：外部系统（Steam/Twitch/云存档）
--     随时可能回调，游戏侧必须容忍「此时游戏还没准备好」。
function OnTwitchMessageReceived(username, message, colour)
    if TheWorld ~= nil then
        TheWorld:PushEvent("twitchmessage", {
            username = username,
            message = message,
            colour = colour,
        })
    end
end
--【机制：Twitch/外部系统回调桥】三个 Twitch 回调全部「转成世界事件」。
--   ★★ 模式：网络层只认全局函数名 → PushEvent 桥接给游戏逻辑（解耦）。
--   ★ 都有 `if TheWorld ~= nil` 保护：外部系统随时可能回调，游戏未就绪时会崩。
--★★ 参见 prefabs/world.lua:606（TheWorld 作为全局事件总线的同款桥接）。

--★ OnTwitchLoginAttempt —— Twitch 登录结果。载荷 {success, result}。
function OnTwitchLoginAttempt(success, result)
    if TheWorld ~= nil then
        TheWorld:PushEvent("twitchloginresult", {
            success = success,
            result = result,
        })
    end
end

--★ OnTwitchChatStatusUpdate —— Twitch 聊天状态变化。载荷 {status}。
function OnTwitchChatStatusUpdate(status)
    if TheWorld ~= nil then
        TheWorld:PushEvent("twitchstatusupdate", {
            status = status,
        })
    end
end
--★★★ Twitch 联动三个回调结束（:146/:156/:165）。
--   ★★ 共同模式：网络层回调 → TheWorld:PushEvent（带 TheWorld ~= nil 保护）。
--   ★ 与 prefabs/world.lua:606 的 ms_playerspawn 是同类「网络/引擎 → 世界事件」桥接。
--★★ 参见 shardnetworking.lua:151（跨分片会话 id 的同款「推事件」模式）。

--★★★[ValidateRecipeSkinRequest —— ★ 配方皮肤请求的合法性校验]
--   ★★★ 签名：(user_id, prefab_name, skin) → 返回 validated_skin 或 nil
--   ★★★ 第 175-181 行三重校验（★ 层层收紧）：
--     ① `skin ~= nil and skin ~= ""` —— 必须指定皮肤；
--     ② ★★ TheInventory:CheckClientOwnership(user_id, skin) —— ★★★ 归属校验：
--       ★★ 「这个皮肤是否属于该 user_id」—— ★★★ 这是安全核心。
--       ★★ 推理：若不校验，玩家可以请求**别人的**皮肤（例如付费皮肤）。
--       ★ CheckClientOwnership 是服务端权威的皮肤归属判断。
--     ③ `table.contains(PREFAB_SKINS[prefab_name], skin)` —— ★★ 白名单：
--       ★★ 这个皮肤是否可用于该预制体（皮肤有适用对象限制）；
--       ★★★ 校验存在 PREFAB_SKINS 里 —— 防止「把 A 的皮肤用到 B 上」。
--     ④ `SKINS_EVENTLOCK[skin] == nil or IsSpecialEventActive(...)` —— ★★ 活动限定：
--       ★★ 某些皮肤是限时活动专属（如万圣节限定皮肤）；
--       ★★ 活动未开启时不可用。
--   ★★★ 四个条件的语义层次：
--     ① 存在性 → ② 归属（安全）→ ③ 适用性（业务）→ ④ 时效性（活动）
--   ★★ 设计模式：「逐层收窄的过滤器」—— 每层淘汰一批可能。
--   ★★ 参见 prefabs/world.lua:222-228（classified 实体族）与 networkclientrpc.lua:1089。,
function ValidateRecipeSkinRequest(user_id, prefab_name, skin)
    local validated_skin = nil
    if skin ~= nil and skin ~= "" and TheInventory:CheckClientOwnership(user_id, skin) then
        if table.contains( PREFAB_SKINS[prefab_name], skin ) then
            if SKINS_EVENTLOCK[skin] == nil or IsSpecialEventActive(SKINS_EVENTLOCK[skin]) then
                validated_skin = skin
            end
        end
    end
    return validated_skin
end
--【机制：三重玩家所有权校验】CheckClientOwnership 是服务端权威判断。
--   ★★ 三层语义（:177 的四条件）：存在性 → 玩家所有权 → 预制体适用性 → 活动时效。
--   ★ 失败的返回是 nil（不算错误，只是「不设这个皮肤」）。
--★★ 参见 prefabs/world.lua:431（CLASSIFIED 标签的语义来源）。

--★★★[VerifySpawnNewPlayerOnServerRequest —— ★★ 请求生成新玩家的前置闸门]
--   ★★★ 第 186 行的巨型条件（★ 三个 or 分支）：
--     ① TheWorld == nil                              → 无世界
--     ② TheWorld.net == nil                          → ★ 无网络层
--     ③ worldcharacterselectlobby ~= nil
--        and not worldcharacterselectlobby:CanPlayersSpawn()  → ★★ 角色选择大厅不允许生成
--   ★★★ 条件③ 最有意思（★ 理解 DST 的选人流程）：
--     · TheWorld.net.components.worldcharacterselectlobby —— ★★ 选人大厅组件，
--       挂在 **net 实体**上（不是 TheWorld 本体），见 prefabs/world.lua:423；
--     · ★★ CanPlayersSpawn() —— 大厅有「当前是否允许生成玩家」的规则；
--     ★★ 推理：某些模式（如角色轮换、竞技场）不允许中途加入生成玩家。
--   ★★★ 三个条件都导致同一个动作：★★ TheNet:Kick(user_id) + return false
--   ★★ 设计决策：★ 拒绝时**踢人**而非静默忽略。
--     ★ 推理：这是「无效的加入请求」—— 客户端试图加入但被规则拒绝，
--       ★ 踢出能让客户端立刻回到菜单（否则它会一直等一个不会来的世界）。
--     ★★ 但也可能过于激进（客户端可能不知道原因）——
--       ★ 若能区分「正在选人（稍后重试）」与「不允许加入（踢出）」会更好。
--       ★ 当前实现把所有情况都归为踢出。仅标注。
function VerifySpawnNewPlayerOnServerRequest(user_id)
	if TheWorld == nil or TheWorld.net == nil or (TheWorld.net.components.worldcharacterselectlobby ~= nil and not TheWorld.net.components.worldcharacterselectlobby:CanPlayersSpawn()) then
		TheNet:Kick(user_id)
		return false
	end

	return true
end
--★ VerifySpawnNewPlayerOnServerRequest 结束。★★ 它是「请求生成」的前置闸门：
--   不通过就 TheNet:Kick(user_id)（见 :187）。
--   ★ 与 :194 ValidateSpawnPrefabRequest 是一对：
--     · 本函数 = 「能不能生成」（角色选择大厅规则）；
--     · :194    = 「生成成什么样」（外观合法性）。

--★★★★★[ValidateSpawnPrefabRequest —— ★★★ 本文件最长的校验函数，也是最重要的反作弊闸门]
--   ★★★ 签名（7 个参数）：
--     (user_id, prefab_name, skin_base, clothing_body, clothing_hand,
--      clothing_legs, clothing_feet, allow_seamlessswap_characters)
--     ★★ 前 7 个是玩家请求的「外观描述」，最后 1 个是服务端权限标志。
--   ★★★ 返回：validated_prefab + 4 个服饰（skin_base 与四件衣物）。
--   ★★★ ★★★ 全函数的核心策略（★ 必须理解的设计哲学）：
--     「★★ 非法输入不是拒绝，而是**降级到合法值**」。
--     · 非法角色 → 回退到列表第一个合法角色（第 226-230 行）；
--     · 未拥有的皮肤 → 不设置（第 218-223 行的分支）；
--     · 未拥有的衣物 → 不设置（第 232-243 行）。
--   ★★ 为什么降级而非拒绝（推理）：
--     · 「拒绝」= 踢玩家，可能误伤（客户端 bug 导致参数不符）；
--     · ★「降级」= 玩家仍能进游戏，只是外观变成默认 —— 用户体验好；
--     · ★★ 而**安全性依然完整**：非法值根本不会进入游戏状态。
--     · ★★★ 这就是「安全不靠拒绝，靠替换」的成熟思路。
--   ★ 交叉引用：:249 SpawnNewPlayerOnServerFromSim（消费本函数返回值）。
function ValidateSpawnPrefabRequest(user_id, prefab_name, skin_base, clothing_body, clothing_hand, clothing_legs, clothing_feet, allow_seamlessswap_characters)
--★★[第 195 行：两张角色白名单分别判定]
--   local in_mod_char_list = table.contains(MODCHARACTERLIST, prefab_name)
--   ★★ MODCHARACTERLIST 是「模组添加的角色」白名单（服务器管理员授权的）；
--   ★★ 与 DST_CHARACTERLIST（原版角色）并列，形成两个来源。
--   ★★ 注意这里只判定「在不在列表里」，不检查**是否拥有该模组**——
--     ★ 推测在更早的环节（连服时的模组同步，:347 DownloadMods）已保证。
    local in_mod_char_list = table.contains(MODCHARACTERLIST, prefab_name)

--★★★[第 197 行：ExceptionArrays —— ★ 带「例外名单」的白名单计算]
--   local valid_chars = ExceptionArrays(DST_CHARACTERLIST, MODCHARACTEREXCEPTIONS_DST)
--   ★★★ 「主名单 + 例外名单」的合并：
--     · DST_CHARACTERLIST —— 原版可玩角色；
--     · ★ MODCHARACTEREXCEPTIONS_DST —— 模组声明的「我要覆盖/新增的角色」。
--   ★★ 为什么需要「例外」机制（推理）？
--     · 模组可能**替换**某个原版角色的形象（如给韦斯换个外观）；
--     · ★★ 若模组只是追加，白名单会与原版冲突（同名）；
--     · ★ ExceptionArrays 就是解决「替换 vs 追加」的合并策略。
--   ★★★ 返回值 valid_chars 是**实际可用**的角色列表，第 226 行会取 [1] 作为兜底。
--   ★ 交叉引用：MODCHARACTEREXCEPTIONS_DST 相关的模组配置（modoverrides）。
    local valid_chars = ExceptionArrays(DST_CHARACTERLIST, MODCHARACTEREXCEPTIONS_DST)
    local in_valid_char_list = table.contains(valid_chars, prefab_name)

--★★★[第 200-205 行：★★ 无缝换角色的权限检查 + 入侵记录]
--   if table.contains(SEAMLESSSWAP_CHARACTERLIST, prefab_name) and not allow_seamlessswap_characters then
--   ★★★ 原注释："NOTES(JBK): This is not assertion level of importance but
--   it is administrative note worthy level to know someone tried breaking things."
--   ★★★ 这条注释的翻译：「这不至于要 assert，但对行政/管理层面有必要知道
--     有人在试图破坏规则」。
--   ★★★ 第 202-203 行：既把合法性置假，也把模组角色判定置假：
--     in_valid_char_list = false
--     in_mod_char_list = false
--     ★★ 两个都置假 → 后面第 226-229 行的兜底会把角色降级成第一个合法角色。
--     ★ 效果：「你不能换这个角色，但游戏继续」。
--   ★★ 第 204 行的 [WERR] 日志：
--     print(string.format("[WERR] Player with ID %s tried spawning as %s without
--                       having permissions to do so!", user_id or "?", prefab_name or "?"))
--     ★★ [WERR] 前缀 = **W**arning **ERR**or（区别于普通 print 的无前缀）。
--       ★ 推理：带前缀的日志便于 grep 与监控告警。
--     ★★ 这是「安全事件」的日志约定（与 networkclientrpc 的 invalidrpc 呼应）。
--     ★★ 但注意：★ 只是**记日志**，不踢人不封禁 ——
--       ★ 若恶意玩家反复尝试，日志会成为唯一的线索。
--       → 生产环境应把 [WERR] 接入告警系统。
--     ★★ "tried spawning as" —— 说明这是**已知**的绕过尝试，
--       说明作者考虑过「客户端伪造请求角色」的攻击面。
    if table.contains(SEAMLESSSWAP_CHARACTERLIST, prefab_name) and not allow_seamlessswap_characters then
        -- NOTES(JBK): This is not assertion level of importance but it is administrative note worthy level to know someone tried breaking things.
        in_valid_char_list = false
        in_mod_char_list = false
        print(string.format("[WERR] Player with ID %s tried spawning as %s without having permissions to do so!", user_id or "?", prefab_name or "?"))
    end

--★[第 207-212 行：六个 validated_ 变量的初始化]
--   ★★ 先全部置 nil/原值，后续按条件逐个填充 —— 「收集-验证-返回」模式。
--   ★★ ★ validated_prefab 初始化为**请求值**（不是 nil）——
--     ★ 因为「合法时直接用请求值，非法时才降级」（第 214-230 行）。
    local validated_prefab = prefab_name
    local validated_skin_base = nil
    local validated_clothing_body = nil
    local validated_clothing_hand = nil
    local validated_clothing_legs = nil
    local validated_clothing_feet = nil

--★★★[第 214-223 行：皮肤校验（三层，与 :175 的 ValidateRecipeSkinRequest 同源）]
--   if in_valid_char_list then
--       if skin_base == prefab_name.."_none" then
--           -- If default skin, we do not need to check
--           validated_skin_base = skin_base
--       elseif TheInventory:CheckClientOwnership(user_id, skin_base) then
--           --check if the skin_base actually belongs to the prefab
--           if table.contains( PREFAB_SKINS[prefab_name], skin_base ) then
--               validated_skin_base = skin_base
--           end
--       end
--   ★★★ 三层结构：
--     ① ★★ 【特例短路】skin_base == prefab_name.."_none" → 直接放行。
--       ★★ 「无皮肤」是默认状态（拼 prefab 名 + _none 后缀），
--         ★ 不需要归属检查（没有皮肤可偷）。
--       ★★ 这是「默认值免检」的经典优化。
--     ② ★ 归属检查：CheckClientOwnership(user_id, skin_base)；
--     ③ ★★ 适用性检查：table.contains(PREFAB_SKINS[prefab_name], skin_base)
--       ★★ 原注释 "check if the skin_base actually belongs to the prefab" ——
--         ★ 「归属」在这里指「属于这个预制体」而非「属于这个玩家」。
--       ★★ 两个「归属」概念的区分（容易混淆，务必分清）：
--         · ② 归属 = **玩家的所有权**（你买了吗）
--         · ③ 归属 = **预制体的适用性**（这皮肤能用于这个角色吗）
--   ★★ 若 ② 或 ③ 任一失败 → validated_skin_base 保持 nil → 不设置皮肤。
--   ★ 三层与 :175 的 ValidateRecipeSkinRequest 是同一套校验范式。
    if in_valid_char_list then
        if skin_base == prefab_name.."_none" then
            -- If default skin, we do not need to check
            validated_skin_base = skin_base
        elseif TheInventory:CheckClientOwnership(user_id, skin_base) then
            --check if the skin_base actually belongs to the prefab
            if table.contains( PREFAB_SKINS[prefab_name], skin_base ) then
                validated_skin_base = skin_base
            end
        end
--★★[第 224-225 行：模组角色分支 —— ★「模组角色不能用皮肤」]
--   elseif in_mod_char_list then
--       --if mod character, don't use a skin
--   ★★★ 注释明确了业务规则：★ 模组角色不使用皮肤系统。
--   ★★ 推理：模组角色是模组自定义的外观体系，不接入原版皮肤。
--   ★★ 该分支**什么都不做**（只有注释）→ validated_skin_base 保持 nil。
--     ★ 这是一个「显式空分支」—— 用注释说明「故意什么都不做」。
--     ★ 比留空更好（避免后来者以为漏写了）。
    elseif in_mod_char_list then
        --if mod character, don't use a skin
--★★★[第 226-230 行：★★ 双层兜底 —— 非法角色的降级策略]
--   elseif table.getn(valid_chars) > 0 then
--       validated_prefab = valid_chars[1]
--   else
--       validated_prefab = DST_CHARACTERLIST[1]
--   end
--   ★★★ 两级兜底：
--     ① ★ valid_chars 非空 → 取**第一个**合法角色；
--     ② ★★ valid_chars 为空（模组把角色全禁了）→ 取 DST_CHARACTERLIST[1]。
--   ★★ 第② 层是「最后的保险」：★ 保证 validated_prefab 永远非 nil。
--     ★★★ 推理：若这里也返回 nil，调用方（:249）会崩。
--       ★ 「永远返回一个合法值」是这类校验函数的契约。
--   ★★ table.getn 是 Lua 5.1 的长度函数（5.2+ 是 #）—— ★ 本项目是 5.1。
--   ★★ 「取第一个」而非「随机」：★ 保证降级结果是**确定的**（可重现）。
--     ★ 对测试与调试友好。
--   ★★ ⚠ 注意：★★★ 整个 if/elseif/else 链**没有 else 分支**处理
--     「in_valid_char_list 为真但皮肤校验失败」之外的情况 ——
--     ★ 实际上第 214 行的 if 覆盖了「合法角色」，第 224/226/228 覆盖其余，
--       ★ 链条是完备的（合法/模组/有兜底/全兜底）。
    elseif table.getn(valid_chars) > 0 then
        validated_prefab = valid_chars[1]
    else
        validated_prefab = DST_CHARACTERLIST[1]
    end

--★★★[第 232-243 行：四件衣物的校验 —— ★★★ 完全平行的四行代码]
--   if clothing_body ~= "" and TheInventory:CheckClientOwnership(user_id, clothing_body) and IsClothingItem(clothing_body) then
--       validated_clothing_body = clothing_body
--   end
--   ★★★ 三个条件：
--     ① clothing_body ~= "" —— ★ 空串表示「不穿」（不是 nil！）。
--       ★★ 推理：服饰参数用**空串**而非 nil 表示「无」，
--         ★ 与 :215 的 _none 皮肤是不同的表示方式。
--       ★ 这是一个不一致的地方（皮肤用 _none 后缀，服饰用空串）——
--         ⚠ 但都能工作，仅记录。
--     ② ★★ CheckClientOwnership —— 归属校验（同 :218）；
--     ③ ★★ IsClothingItem —— 物品类型校验：
--       ★★ 关键：★ 防止把**非衣物**物品当作衣物穿上！
--       ★★ 攻击者若能穿上武器，属性判定会出问题。
--     ★★★ 三个条件缺一不可：**存在 + 拥有 + 是衣物**。
--   ★★ 四行（body/hand/legs/feet）完全平行，只是变量名不同。
--     ★ 又一处「平行实现」—— 加新装备部位必须四处同改。
--   ★★ 注意这四行**没有**「else」—— 校验失败就是不设置该服饰
--     （降级为「不穿」），符合本函数「降级而非拒绝」的总策略。
--   ★★ 参见 components/skinner.lua 与 prefabs/world.lua:540（minimap 持久化呼应）。,
    if clothing_body ~= "" and TheInventory:CheckClientOwnership(user_id, clothing_body) and IsClothingItem(clothing_body) then
        validated_clothing_body = clothing_body
    end
    if clothing_hand ~= "" and TheInventory:CheckClientOwnership(user_id, clothing_hand) and IsClothingItem(clothing_hand) then
        validated_clothing_hand = clothing_hand
    end
    if clothing_legs ~= "" and TheInventory:CheckClientOwnership(user_id, clothing_legs) and IsClothingItem(clothing_legs) then
        validated_clothing_legs = clothing_legs
    end
    if clothing_feet ~= "" and TheInventory:CheckClientOwnership(user_id, clothing_feet) and IsClothingItem(clothing_feet) then
        validated_clothing_feet = clothing_feet
    end

    return validated_prefab, validated_skin_base, validated_clothing_body, validated_clothing_hand, validated_clothing_legs, validated_clothing_feet
end
--★★★ ValidateSpawnPrefabRequest 结束。★★★ 本文件最重要的反作弊闸门，
--   ★★ 核心哲学复述（★ 移植时必须保留）：
--     「非法输入不是拒绝，而是降级到合法值」。
--   ★ 四层校验：
--     ① 角色白名单（DST + 模组例外名单合并）；
--     ② 无缝换角色权限（服务端标志）+ [WERR] 入侵日志；
--     ③ 皮肤三重校验（默认值免检 / 所有权 / 适用性）；
--     ④ 四件衣物平行校验（存在 + 所有权 + 是衣物）。
--   ★★ 恒定契约：返回值中 validated_prefab **永远非 nil**（两级兜底，:226-230）。
--【机制：非法输入降级而非拒绝】ValidateSpawnPrefabRequest 的总策略。
--   ★★★ 角色白名单 = DST_CHARACTERLIST + ExceptionArrays(MODCHARACTEREXCEPTIONS_DST)；
--   ★ 两级兜底（:226/:229）保证 validated_prefab 永远非 nil —— 调用方永不崩。
--   ★★ 四件衣物平行校验（:232-243）：存在 + 拥有 + IsClothingItem（防穿武器）。
--   ★ [WERR] 日志（:204）= 安全事件约定，★ 不踢人只留证据链。
--★★ 参见 prefabs/world.lua:222-228（classified 实体族 —— 私有数据的载体）；
--   ★★ 参见 prefabs/world.lua:583 playerspawner（出生流程的下游组件）；
--   ★★ 参见 networkclientrpc.lua:937（「数字 ID + 反查」的白名单模式）。

--★★★[第 248 行原注释 "NOTES(JBK): [Searchable \"SN_SKILLSELECTION\"] skillselection"]
--   ★★★ 这是一条「可搜索标记」：作者刻意写了 SN_SKILLSELECTION 这样的标记串，
--     ★ 目的是让后来者能通过 grep 找到「技能选择相关的所有代码」。
--   ★★ 这是一种「文档即代码」的技巧：在注释里埋入检索关键词。
--     ★ 类似的标记还见于 prefabs/world.lua 的 NOTES(JBK)（多处）。
--     ★★ 推测是团队内部约定：看到 NOTES(姓名) 表示「这条有历史包袱，别乱改」。
-- NOTES(JBK): [Searchable "SN_SKILLSELECTION"] skillselection 
--★★★★★[SpawnNewPlayerOnServerFromSim —— ★★ 新玩家生成的落地执行]
--   ★★★ 原注释说明「从 Sim 调用」—— ★ 即由 C++ 侧在生成玩家后回调。
--   ★★★ 九个参数全是外观与技能：
--     (player_guid, skin_base, body, hand, legs, feet,
--      starting_item_skins, skillselection, skinoverrides)
--   ★★★ 函数体四段（★ 顺序有讲究）：
--     ① 设置外观（skinner 的连续调用，第 253-259 行）；
--     ② 触发 OnNewSpawn 钩子并**清空它**（第 261-264 行）；
--     ③ 设置技能（第 266-267 行）；
--     ④ ★★ 选点放置 + 立即存档（第 269-270 行）。
--   ★★★ 第 250-251 行：Ents[player_guid] 取玩家，nil 则整个函数跳过。
--   ★★ 推理：玩家在生成瞬间必定存在（这是「生成后」的回调）；
--     ★ 判空是防御（GUID 传错/实体已销毁）。
function SpawnNewPlayerOnServerFromSim(player_guid, skin_base, clothing_body, clothing_hand, clothing_legs, clothing_feet, starting_item_skins, skillselection, skinoverrides)
    local player = Ents[player_guid]
    if player ~= nil then
--★★[第 252-259 行：六行 skinner 调用 —— ★「外观设置」的完整序列]
--   local skinner = player.components.skinner
--   skinner:SetClothing(clothing_body)
--   skinner:SetClothing(clothing_hand)
--   skinner:SetClothing(clothing_legs)
--   skinner:SetClothing(clothing_feats)  -- 实际是 clothing_feet
--   skinner:SetSkinName(skin_base)
--   skinner:SetSkinMode("normal_skin")
--   skinner:SetSkinOverrides(skinoverrides)
--   ★★★ 为什么必须**逐件**设置而不能一次传四个？
--     推理：skinner 的 API 是单件设置 —— 四个部位是四次调用。
--     ★★ 这意味着「新增装备部位」要改两处（本文件 + skinner 组件）。
--   ★★★ SetSkinMode("normal_skin") —— ★★★ 为什么必须显式设为「普通皮肤」？
--     ★★ 因为 DST 的皮肤有「模式」（normal_skin / 其他），
--       ★ 若是「伪装模式」（把自己变成别人），外观计算完全不同。
--       ★★★ 这里强制 normal —— ★ 因为**玩家生成时必须是自己的脸**。
--       ★ 这是「初始化为安全状态」的做法。
--   ★★ SetSkinOverrides(skinoverrides) —— ★ 皮肤覆盖（部分替换外观元素）。
--     ★ 推测用于「保留某些自定义元素」的场景（如玩家自定义的胡须）。
--   ★★★ 第 261-263 行 OnNewSpawn 的一次性钩子：
--     if player.OnNewSpawn ~= nil then
--         player:OnNewSpawn(starting_item_skins)
--         player.OnNewSpawn = nil     -- ★★ 调完立刻清空！
--     end
--     ★★ 「一次性」设计：只在本函数调用，之后置 nil 防止重复触发。
--       ★★ 这是「钩子 + 自毁」模式：保证「只做一次」。
--     ★ starting_item_skins —— 新手物品的皮肤（新号赠送物的外观）。
        local skinner = player.components.skinner
        skinner:SetClothing(clothing_body)
        skinner:SetClothing(clothing_hand)
        skinner:SetClothing(clothing_legs)
        skinner:SetClothing(clothing_feet)
        skinner:SetSkinName(skin_base)
        skinner:SetSkinMode("normal_skin")
        skinner:SetSkinOverrides(skinoverrides)

        if player.OnNewSpawn ~= nil then
            player:OnNewSpawn(starting_item_skins)
            player.OnNewSpawn = nil
        end

--★★★[第 266-267 行：技能树设置 —— ★★ 注意它无条件调用（无判空）]
--   local skilltreeupdater = player.components.skilltreeupdater
--   skilltreeupdater:SetPlayerSkillSelection(skillselection)
--   ★★ 与第 252 行的 skinner 不同，这里**没有判空**。
--     ★★ 推理：玩家实体必定有 skilltreeupdater 组件（所有玩家都有）。
--       ★ 对比 networkclientrpc.lua 里大量的 `xxx ~= nil then` 判空 ——
--       ★ 差异的原因：★ RPC 是异步的（状态可能变化），
--         而这里在「刚生成」时同步执行（状态确定）。
--     ★★ 这是一个值得学习的区分：★ 何时需要防御性判空，取决于「时机是否确定」。
        local skilltreeupdater = player.components.skilltreeupdater
        skilltreeupdater:SetPlayerSkillSelection(skillselection)

--★★★[第 269 行：★★ 跨文件调用 —— 本文件与 world.lua 的接缝]
--   TheWorld.components.playerspawner:SpawnAtNextLocation(TheWorld, player)
--   ★★★ 完整跨文件链路（★ 理解 DST 生成流程的最佳样本）：
--     ① 本文件 ValidateSpawnPrefabRequest(:194) 校验外观请求；
--     ② C++ 生成玩家实体后回调本文件 SpawnNewPlayerOnServerFromSim(:249)；
--     ③ 本文件设置外观与技能（第 253-267 行）；
--     ④ ★★ 本文件调用 world.lua 的 playerspawner 选点放置；
--     ⑤ ★ 本文件 SerializeUserSession(:303) 立即存档；
--     ⑥ ★★ 引擎派发 ms_playerspawn → prefabs/world.lua:300 OnPlayerSpawn。
--   ★★★ 六步里有三步在本文件、两步在 world.lua、一步在引擎 ——
--     ★★ 「一次玩家生成」横跨两个文件 + 引擎，这是不错的架构切分。
--   ★★ 签名细节：SpawnAtNextLocation(TheWorld, player) ——
--     ★ 把 TheWorld 作为第一个参数传入（虽然组件本身就挂在 TheWorld 上）。
--     ★ 推测是为了「明确这是哪个世界的出生点系统」（多世界集群时的正确性）。
        TheWorld.components.playerspawner:SpawnAtNextLocation(TheWorld, player)
--★★★[第 270 行：★★ 生成后立即存档 —— 为什么这一步至关重要]
--   SerializeUserSession(player, true)
--   ★★★ 第二个参数 true = isnewspawn（第 303 行的形参名）。
--   ★★ 语义：「这是新生成的玩家」→ 存档层需要区别处理：
--     · ★ 可能触发「首次进入」的初始化（新手物品、教程标记）；
--     · ★ 可能避免覆盖已有存档（若重连到同一存档）。
--   ★★★ 为什么要**立即**存档（而不是等自动存档）？
--     ★★ 推理：玩家刚生成的瞬间是「数据最脆弱」的：
--       若此时服务端崩溃/存档损坏，玩家会回到上一个存档点，
--       ★★ 而那次生成（或这次购买的皮肤、技能）就白费了。
--       ★ 立即存档 = 「确认这次生成已落盘」。
--   ★★ 与 :663（迁移前存档 ThePlayer）同一哲学：
--     ★★ 「在状态即将发生重大变化前，先把数据落盘」。
        SerializeUserSession(player, true)        
    end
end

--★★[第 274 行："--TheNet:SpawnSeamlessPlayerReplacement(userid, prefab_name, ...)"]
--   ★★★ 被注释掉的 C++ 侧函数名 —— ★ 揭示了「无缝换角色」的完整入口。
--   ★★★ 「无缝」（seamless）的含义：
--     · ★★ 不重开进程/不重连，直接把玩家实体「变身」成另一个角色；
--     · ★ 常用于「角色轮换」类玩法（如竞技场的三角色模式）。
--   ★★ 对比 MigrateToServer（:646）必须重启进程 ——
--     ★★ 换服务器 = 重启进程（世界变了），换角色 = 复用进程（世界不变）。
--     ★ 这个区分是理解本文件两个「换」的关键。
--TheNet:SpawnSeamlessPlayerReplacement(userid, prefab_name, skin_base, clothing_body, clothing_hand, clothing_legs, clothing_feet)
--★★★[SpawnSeamlessPlayerReplacementFromSim —— 「无缝换角色」的落地]
--   ★★★ 与 SpawnNewPlayerOnServerFromSim（:249）的对比：
--     ┌──────────────────┬──────────────────────┬──────────────────────┐
--     │                  │ 新生成 (:249)         │ 无缝替换 (:275)      │
--     ├──────────────────┼──────────────────────┼──────────────────────┤
--     │ 玩家实体         │ ★ 新建                │ ★ 复用（换外观）    │
--     │ OnNewSpawn 钩子   │ ★ 有，并清空          │ ★★ 无（不是新生成）  │
--     │ 技能树           │ ★ SetPlayerSkillSelection│ ★★ 不设置（保留原技能）│
--     │ 额外处理         │ ★ 无                  │ ★★ seamlessplayerswapper│
--     │ 事件             │ ★ 无                  │ ★ ms_seamlesscharacterspawned│
--     │ 存档             │ ★ isnewspawn=true     │ ★ isnewspawn=true    │
--     └──────────────────┴──────────────────────┴──────────────────────┘
--   ★★★ 三处关键差异：
--     ① ★★ 不调 OnNewSpawn —— 因为玩家已存在，不是新生成；
--     ② ★★ 不设置技能 —— ★★ 换角色时保留原有技能（角色换了，成长不重置）；
--     ③ ★★ 调 seamlessplayerswapper:OnSeamlessCharacterSwap(old_player_guid)
--       —— ★★ 迁移「旧角色」的状态到新角色（背包、技能、位置）。
--   ★★★ 第 286-288 行的 wapper 调用（★ 三行）：
--     if player.components.seamlessplayerswapper then
--         player.components.seamlessplayerswapper:OnSeamlessCharacterSwap(
--             old_player_guid ~= nil and Ents[old_player_guid] or nil)
--     end
--     ★★ 第 287 行的 `old_player_guid ~= nil and Ents[old_player_guid] or nil`：
--       把「GUID 或 nil」转换成「实体或 nil」—— 若 GUID 无效则传 nil。
--       ★ 三目惯用法的又一个实例（对比 :62 的 mime 处理）。
--     ★ 判空 `then` 保护：组件可能不存在（非竞技场模式）。
function SpawnSeamlessPlayerReplacementFromSim(player_guid, old_player_guid, skin_base, clothing_body, clothing_hand, clothing_legs, clothing_feet)
    local player = Ents[player_guid]
    if player ~= nil then
        local skinner = player.components.skinner
        skinner:SetClothing(clothing_body)
        skinner:SetClothing(clothing_hand)
        skinner:SetClothing(clothing_legs)
        skinner:SetClothing(clothing_feet)
        skinner:SetSkinName(skin_base)
        skinner:SetSkinMode("normal_skin")

		if player.components.seamlessplayerswapper then
			player.components.seamlessplayerswapper:OnSeamlessCharacterSwap(old_player_guid ~= nil and Ents[old_player_guid] or nil)
		end

--★★[第 290 行：TheWorld:PushEvent("ms_seamlesscharacterspawned", player)]
--   ★★ 换角色完成后广播世界级事件（ms_ 前缀，见 prefabs/world.lua:300 注记）。
--   ★★★ 推理：换角色会影响很多东西（UI 要重建、任务要重置、图鉴要刷新）——
--     ★ 这些都不该由本函数直接调用，而应通过事件让订阅者自行响应。
--     ★★ 这就是「TheWorld 作为全局事件总线」的典型用例。
--   ★★ 与新生成（:249）不同：★ 新生成不发事件，无缝替换要发 ——
--     ★ 因为替换影响的是「全世界的认知」，需要广播。
        TheWorld:PushEvent("ms_seamlesscharacterspawned", player)

--★★[第 292 行：SerializeUserSession(player, true) —— 换角色后立即存档]
--   ★★★ 与 :270 相同的调用，isnewspawn 同样为 true。
--   ★★ 推理：换角色是重大状态变化（新角色 + 迁移的背包/技能），
--     ★ 必须立即落盘，否则崩溃会导致玩家「角色换了但没存档」。
--   ★ 交叉引用：:303 SerializeUserSession 的详细分析。
        SerializeUserSession(player, true)
    end
end
--【机制：无缝换角色（seamless swap）】复用进程与世界，只换实体外观。
--   ★★★ 与「新生成」的三处差异：
--     · 不调 OnNewSpawn（玩家已存在）；
--     · ★ 不设技能（换角色保留成长）；
--     · ★ 调 seamlessplayerswapper:OnSeamlessCharacterSwap（旧状态迁移）。
--   ★★ 广播 ms_seamlesscharacterspawned（:290）—— 影响全世界的认知。
--   ★★ 与 MigrateToServer(:646) 的对比：换角色复用进程，换服务器必须重启。
--★★ 参见 prefabs/world.lua:601（cluster 场景需另行同步 worldgen 数据的自承注记）。


--★★[RequestedLobbyCharacter —— ★ 大厅里的「角色请求」事件]
--   ★★★ 把 7 个参数打包成一个表推事件：
--     TheWorld:PushEvent("ms_requestedlobbycharacter", {userid=..., prefab_name=...,
--         skin_base=..., clothing_body=..., clothing_hand=..., clothing_legs=..., clothing_feet=...})
--   ★★ 注意「userid=」没有空格（第 298 行）—— 风格细节，无语义。
--   ★★★ 这是「大厅请求生成角色」的中转：
--     · 客户端在选人界面选了角色 → 引擎回调本函数；
--     · ★★ 本函数**不直接生成**，只推事件；
--     · ★★ 由订阅者（角色选择大厅组件）决定何时、如何生成。
--   ★★ 为什么要中转而不是直接生成（★ 关键理解）：
--     · ★ 大厅的规则（如「选满 3 人才能开始」）由大厅组件掌握；
--     · ★★ 本文件不该知道这些规则 —— 中转让职责分离。
--   ★★ 对比 :249（生成后的落地）直接执行 ——
--     ★★ 区别：「请求」推事件，「确认」直接执行。
--   ★ 交叉引用：net.lua 的 worldcharacterselectlobby 组件（:186 提及）。
function RequestedLobbyCharacter(userid, prefab_name, skin_base, clothing_body, clothing_hand, clothing_legs, clothing_feet)
	TheWorld:PushEvent("ms_requestedlobbycharacter", {userid=userid, prefab_name=prefab_name, skin_base=skin_base, clothing_body=clothing_body, clothing_hand=clothing_hand, clothing_legs=clothing_legs, clothing_feet=clothing_feet})
end
--★★★ 出生与无缝换角色区结束（§四）。★★ 两者的对照见 :275 的表格。
--   ★★ 「一进程一世界」的架构含义（★ 参见文件头注记 4）：
--     · 换角色（:275）→ 复用进程与世界，只换实体外观；
--     · ★ 换服务器（:646 MigrateToServer）→ 必须重启进程。

--★★★[第 301-302 行：★ 「这个函数也会被 Sim 调用」的源码警告]
--   "--NOTE: this is called from sim as well, so please check it before any
--    interface changes! (NetworkManager)"
--   ★★★ 关键信息：
--     · 「Sim」= C++ 侧的模拟/网络层；
--     · ★★ 本函数**同时**被 Lua 代码与 C++ 调用 —— ★ 双重调用方。
--     · ★★★ 因此改动它之前必须检查 C++ 侧（NetworkManager）的调用点。
--   ★★ 这是一条「跨语言边界」警告，极其重要：
--     ★ 在纯 Lua 项目里改函数只需看调用点；在 DST 里还要看 C++。
--     ★ ★ 移植时的教训：★ 与 C++ 有交互的函数应集中管理并标注。
--NOTE: this is called from sim as well, so please check it before any
--      interface changes! (NetworkManager)
--★★★★★[SerializeUserSession —— ★★★ 玩家持久化存档的唯一出口]
--   ★★★ 签名：SerializeUserSession(player, isnewspawn)
--     · player    —— 玩家实体
--     · isnewspawn —— 是否新生成（区分「首次进入」与「更新存档」）
--   ★★★ ★★ 函数体只有 15 行，却承载了全部玩家数据的持久化。
--   ★★★ 四个关键点（★ 逐行读解）：
--     ① 归属校验（第 304 行）—— ★ 见下方详解；
--     ② GetSaveRecord() 取存档数据（:306）；
--     ③ DataDumper 序列化（:307）；
--     ④ TheNet:SerializeUserSession 交给存档层（:318）。
--   ★★ 本文件另有两个存档函数，形成完整的三级体系：
--     · 玩家级：SerializeUserSession   (本函数) —— 每个玩家一份
--     · 世界级：SerializeWorldSession (:328) —— 整个存档一份
--     · ★ 删除：DeleteUserSession       (:322) —— 玩家离开时清理
--   ★ 交叉引用：components 的 GetSaveRecord / OnSave 方法（各组件自行贡献数据）。
--   ★★ 参见 01-报告/04-联机同步-模组系统-UI.md 的存档持久化章节。
function SerializeUserSession(player, isnewspawn)
--★★★★★[第 304 行：★★★ 四重条件的归属校验 —— 本函数的安全核心]
--   if player ~= nil and player.userid ~= nil and player.userid:len() > 0
--       and (player == ThePlayer or TheNet:GetIsServer()) then
--   ★★★★ 四个条件，逐一读解：
--     ① player ~= nil —— 实体存在（防御性）；
--     ② player.userid ~= nil —— ★★ 玩家有 userid；
--     ③ player.userid:len() > 0 —— ★★ userid 非空串：
--       ★★★ 为什么要专门判空串？
--       ★★ 推理：实体可能有 userid 字段但值为 "" ——
--         这在「玩家实体刚创建但账号还没绑定」时会发生；
--       ★★ 而 userid 是存档的**主键** —— 空主键会导致存档写到错误的文件
--         或覆盖他人存档。
--       ★★ 这是「空主键」防护，比判 nil 更严格 —— ★ 关键的安全细节。
--     ④ ★★★ `player == ThePlayer or TheNet:GetIsServer()` —— ★★ 最关键的一条件：
--       ★★★ 语义：
--         · 在**客户端**：只有**本地玩家**（ThePlayer）可以存自己的存档；
--         · ★ 在**服务端**：任何玩家都可以存（服务端是权威）；
--       ★★★ 为什么客户端要限制？
--       ★★ 因为客户端可能在收到「别的玩家的实体」数据，
--         若允许它 SerializeUserSession(别人的玩家)，
--         ★★ 就会把别人的存档内容发到存档层 —— ★ 数据泄漏/覆盖风险。
--       ★★ 这一条件是「客户端不得代表他人写存档」的安全保证。
--       ★ → 对应 networkclientrpc.lua 的同类边界（SetClientAuthoritativeSetting）。
--   ★★★ ★★ 双向理解：
--     · 谁**读**存档：客户端读自己的，服务端读所有人的；
--     · ★ 谁**写**存档：同一个条件保证「写的范围 = 读的范围」。
--   ★★ 对照 :323 的 DeleteUserSession 用了**完全相同**的条件 ——
--     ★★ 读写权限必须一致（能写就能删），这是本文件的一致性体现。
    if player ~= nil and player.userid ~= nil and player.userid:len() > 0 and (player == ThePlayer or TheNet:GetIsServer()) then
        --we don't care about references for player saves
--★★★★★[第 306 行：GetSaveRecord() —— ★ 存档数据的真正来源]
--   local playerinfo--[[, refs]] = player:GetSaveRecord()
--   ★★★ 一个被拆解的自调用：原本返回 playerinfo 和 refs（两个值），
--     ★ 但只接收第一个（playerinfo），第二个用 --[[ ]] 注释掉。
--   ★★★ 这个写法的含义：
--     · ★★★ GetSaveRecord 返回【数据表, 引用表】；
--     · ★ 「引用表」（refs）是「本表里哪些字段是实体引用」的映射；
--     · ★★ 注释掉它 = 「本函数不使用引用信息」。
--   ★★★ ★★ 为什么在这里不需要 refs？（★ 结合第 307 行理解）
--     · DataDumper(data, nil, BRANCH ~= "dev") —— 第三个参数控制是否含引用；
--     · ★ 在非 dev 构建里不含引用；
--     · ★★ 推论：存档序列化**不需要**引用信息 —— 实体引用在跨进程后无法还原，
--       ★ 只保存「可序列化的纯数据」。
--   ★★★ ★★ GetSaveRecord 的实现（★ 重要机制）：
--     玩家实体的存档数据来自**所有组件的协作**：
--     · ★ 每个组件实现 OnSave(self, data) 往 data 里塞自己的字段；
--     · ★ 引擎/实体层调用所有组件的 OnSave，汇总成 playerinfo。
--     · ★★ 所以「玩家存档的格式」= 所有玩家组件的字段之并集 ——
--       ★★★ 这意味着 ★ **加一个组件的字段就会改变存档格式**。
--       ★ ★ 兼容性由此而来：旧存档缺新字段，新代码要容忍 nil。
--     · ★ 交叉引用：entityscript.lua 的 GetSaveRecord / OnSave，
--       以及各组件的 OnSave 方法（如 locomotor、inventory）。
--   ★★★ 这一行是「组件系统如何影响存档格式」的枢纽。
        local playerinfo--[[, refs]] = player:GetSaveRecord()
--★★★[第 307 行：DataDumper 的第三参数 —— ★★ 「按构建分支决定是否含引用」]
--   local data = DataDumper(playerinfo, nil, BRANCH ~= "dev")
--   ★★★ 三个参数：
--     · playerinfo —— 要序列化的表；
--     · nil       —— 第二个参数（推测是「已有数据的合并目标」或「过滤表」）；
--     · ★★ BRANCH ~= "dev" —— 第三个参数：**非开发构建则含引用**。
--   ★★★ 为什么按构建分支决定？（★ 关键推理）
--     · ★ 开发构建（dev）：不含引用 —— 便于调试（数据全可读、无实体句柄）；
--     · ★★ 发布构建：★**含引用** —— ★★★ 这很重要！
--       ★★★ 推理：存档需要记录「这个物品实体对应哪个实体」——
--         比如背包里的物品在存档中是「实体引用」，
--         ★★ 加载时才能恢复「这是同一个物品」。
--         ★ 含引用 = 保留实体间的关联信息。
--   ★★★ 对比第 325 行的 DoGameDataChanged：DataDumper(game_data, nil, false)
--     ★★ 那里恒为 false（广播数据**永不**含引用）。
--     ★★ 差异完全正确：
--       · 存档数据 → 需要引用（恢复实体关联）；
--       · 广播数据 → ★ 不能含引用（客户端无法还原服务端实体句柄）。
--     ★ 这是「同一序列化函数，两种用途，两种配置」的清晰范例。
--   ★★ ★ 移植警示：这一行是**存档兼容性**的关键 ——
--     ★ 改变第三参数会让旧存档无法加载。务必保持语义一致。
        local data = DataDumper(playerinfo, nil, BRANCH ~= "dev")

--★★[第 309 行：metadataStr 初始化为空串 —— 服务端专属的附加数据]
--   ★★★ 对比第 318 行传给 TheNet 的四个参数里有两个字符串：
--     · data（玩家存档本体）
--     · ★ metadataStr（元数据，仅服务端非空）
--   ★ 推理：元数据不进入普通存档，而是单独传（可能用于服务器列表展示）。
        local metadataStr = ""

--★★★[第 311-316 行：★★ 服务端专属的 metadata]
--   if TheNet:GetIsServer() then
--       local metadata = {
--           character = player.prefab,   -- ★ 角色名（如 wilson）
--       }
--       metadataStr = DataDumper(metadata, nil, BRANCH ~= "dev")
--   end
--   ★★★ 语义：★ 只有服务端会传「玩家用的是哪个角色」的元数据。
--   ★★★ 推理：这个信息**不需要存在玩家存档里**（存档里已有），
--     ★ 但服务器列表/管理界面需要在**不加载完整存档**时显示角色。
--     ★★ 元数据 = 「轻量索引」，供列表展示。
--   ★★ 推理 metadataStr 与 data 分开传的第二个理由：
--     · ★ metadata 可以被服务器缓存/索引（无需解压完整存档）；
--     · ★★ 两者生命周期可能不同（元数据可能先写、存档后写）。
--   ★★ 参见 01-报告/04-联机同步-模组系统-UI.md 的存档持久化章节，与 :328 世界级存档。
--   ★★★ 与 :818 GetDefaultServerData 的「元数据」概念呼应（都是轻量索引）。
        if TheNet:GetIsServer() then
            local metadata = {
                character = player.prefab,
            }
            metadataStr = DataDumper(metadata, nil, BRANCH ~= "dev")
        end

--★★★★★[第 318 行：★ 交给存档层的最终调用]
--   TheNet:SerializeUserSession(player.userid, data, isnewspawn == true,
--                               player.player_classified.entity or nil, metadataStr)
--   ★★★ 五个参数逐一读解：
--     ① player.userid —— ★★ 主键（存档归属的账号）。
--     ② data —— ★ 序列化后的存档数据（第 307 行）。
--     ③ isnewspawn == true —— ★★ 注意这个写法！
--       ★★★ `isnewspawn == true` 而不是直接传 isnewspawn ——
--       ★★★ 因为第 303 行的形参可能传入 nil 或真值，
--         ★★ 强制 `== true` 把「非真值」统一成 false。
--         ★★ 这是「参数规范化」：保证 C++ 侧收到的一定是布尔。
--       ★ 理由：Lua 的 truthy 规则下，nil/0/"" 都是假，
--         ★ 但若 C++ 侧期待明确的 true/false，最好显式规范化。
--     ④ ★★ `player.player_classified.entity or nil` —— ★★★ classified 实体！
--       ★★ player_classified 是玩家的「私有数据实体」（prefabs/world.lua:222-228）；
--       ★★ 它的实体句柄要与存档一起保存 ——
--         ★★★ 因为 classified 实体承载玩家的私有数据（皮肤拥有权等），
--           ★★★ 存档加载后需要重新绑定到新创建的 classified 实体。
--       ★★★ 这解释了 prefabs/world.lua:431 为什么 TheWorld 也带 CLASSIFIED 标签
--         （同类机制），也解释了 writeable_classified 等为何存在。
--       ★★ `or nil`：若 player_classified 不存在（异常/旧存档），传 nil 而非崩。
--     ⑤ metadataStr —— 服务端元数据（:311-316）。
--   ★★ 「五参数传递」本身是 C++ 接口设计，Lua 侧不关心内部。
        TheNet:SerializeUserSession(player.userid, data, isnewspawn == true, player.player_classified ~= nil and player.player_classified.entity or nil, metadataStr)
    end
end
--【机制：玩家持久化唯一出口】SerializeUserSession（★ 跨语言边界，:301 警告）。
--   ★★★★ 四步：
--     ① 归属校验（:304）★★ `player == ThePlayer or GetIsServer()`
--        —— 客户端只能存自己的，服务端可存任何人（防越权写他人存档）；
--     ② GetSaveRecord()（:306）—— ★ 各组件 OnSave 汇总，改组件即改存档格式；
--     ③ DataDumper(..., BRANCH ~= "dev")（:307）—— ★ dev 不含引用、发布含引用
--        （对比 :325 的恒 false：广播数据永不���引用）；
--     ④ TheNet:SerializeUserSession（:318）—— 五参数含 classified 实体句柄。
--   ★★ DeleteUserSession(:322) 用完全相同的条件（能写就能删 = 权限一致）。
--   ★ 世界级存档 SerializeWorldSession(:328)：异步 + callback + ENCODE_SAVES。
--★★ 参见 entityscript.lua（GetSaveRecord 与各组件 OnSave 的汇总路径）；
--   ★★ 参见 locomotor.lua（提供存档字段的组件实例之一）；
--   ★★ 参见 01-报告/04-联机同步-模组系统-UI.md 的存档持久化章节。

--★★[DeleteUserSession —— 删除玩家存档（玩家永久离开）]
--   ★★★ 与 :303 用了**完全相同**的四重条件（第 323 行）—— ★★ 刻意一致。
--   ★★★ 语义：在玩家「永久离开」（而非临时断线）时清理其存档。
--     ★★ 重要区别：
--       · 断线重连 → SerializeUserSession（保存以便回来）；
--       · ★ 永久离开 → DeleteUserSession（清理不再需要）。
--     ★★ 谁决定「永久」？推测由 C++ 在玩家超出重连窗口时调用。
--   ★★ ★★ 读写条件一致的重要性（★ 见 :304 的分析）：
--     「能写就能删」—— 若删除的条件比写入宽松，会成为越权删除的入口。
--     ★ 一致性 = 安全的必要条件。
function DeleteUserSession(player)
    if player ~= nil and player.userid ~= nil and player.userid:len() > 0 and (player == ThePlayer or TheNet:GetIsServer()) then
        TheNet:DeleteUserSession(player.userid)
    end
end

--★★★[SerializeWorldSession —— ★★ 世界级存档的序列化]
--   ★★★ 签名：SerializeWorldSession(data, session_identifier, callback, metadataStr)
--   ★★★ 与玩家级（:303）的关键差异：
--     · ★★ 多一个 callback —— ★★★ 因为世界存档是异步落盘的，
--       需要回调告知「存好了」；
--     · ★★ session_identifier —— 世界存档的标识（哪个存档）。
--   ★★★ 第 329 行：
--     TheNet:SerializeWorldSession(data, session_identifier, ENCODE_SAVES, callback, metadataStr or "")
--     ★★ ENCODE_SAVES —— ★ 压缩/加密存档的开关常量。
--       ★★ 对比 :307 的 `BRANCH ~= "dev"`（按分支决定引用），
--         ★ 这里的引用控制被换成了 ENCODE_SAVES ——
--         ★★ 即「世界存档固定要编码压缩」（为了体积）。
--     ★★ 这解释了前面的 packet size 问题（:813 注释「Likely to exceed data size limit」）。
--   ★★ 世界存档 vs 玩家存档的分工：
--     · 世界存档 = 世界内容（地图、季节进度、任务、实体位置）；
--     · 玩家存档 = 玩家个人数据（背包、属性、皮肤）。
--     ★★ 两者独立存储 —— 玩家的存档不随世界存档一起清空（除非 DeleteUserSession）。
--   ★ 交叉引用：:862 onsaved 回调（StartDedicatedServer 里的实际使用）。
function SerializeWorldSession(data, session_identifier, callback, metadataStr)
    TheNet:SerializeWorldSession(data, session_identifier, ENCODE_SAVES, callback, metadataStr or "")
end
--★★ 参见 :862 onsaved（本文件唯一使用异步回调的存档路径）。

--★★[ReportAction —— 「行为上报」（如举报、反馈）]
--   ★★★ 第 333 行：TheSim:ReportAction(userid, items, item_counts, users, cb)
--     ★★ 参数：userid（举报人）、items（被举报的物品）、item_counts、users。
--   ★★★ 第 334-343 行：回调处理（★ 值得注意的防御式写法）。
--   ★★ 第 335 行直接 print 三参数（调试用，生产也打印 —— 有点吵）。
--   ★★ 第 336 行：`local status, result_data = pcall(function() return json.decode(result_str) end)`
--     ★★★ pcall 包裹 json.decode —— 防止服务端返回非法 JSON 时崩溃。
--     ★★ ⚠ 但第 337 行只检查了 cb ~= nil，**没有检查 status**！
--       ★★★ 推理：若 decode 失败，result_data 是**错误消息字符串**，
--         ★★ 而第 338 行会访问 result_data.Result（字符串的 .Result → nil），
--           然后 `(result_data.Result == "NONE" and 2) or ...` 全为假 → param = 1。
--         ★★ 后果：不会崩溃，但会得到「param = 1」（错误状态）。
--       ★★★ 这属「静默降级」—— 可用但丢失了错误信息。
--       ⚠ 严格说应该检查 status 并在失败时走专门的错误分支。仅标注。
--   ★★ 第 338-340 行：把字符串状态映射成数字码：
--     local param = (result_data.Result == "NONE" and 2) or
--                   (result_data.Result == "DONE" and 3) or 1
--     ★★ 映射表：NONE→2、DONE→3、其它→1（默认）。
--     ★ 三目惯用法的链式写法（and/or 嵌套）。
--   ★★ callback 的 param 是给 UI 用的（决定显示什么反馈）。
function ReportAction( userid, items, item_counts, users, cb )
	TheSim:ReportAction( userid, items, item_counts, users,
		function(result_str, isSuccessful, resultCode)
			print(result_str, isSuccessful, resultCode)
			local status, result_data = pcall( function() return json.decode(result_str) end )
			if cb ~= nil then
				local param = (result_data.Result == "NONE" and 2) or
								(result_data.Result == "DONE" and 3) or
								1
				cb(param)
			end
		end
	)
end
--★ ReportAction 结束。★ 行为上报（举报/反馈）的一个薄封装。

--★★★★★[DownloadMods —— ★★ 联机前的模组对齐，140 行四层嵌套的复杂流程]
--   ★★★ 整体流程（★ 五阶段）：
--     ① 临时关闭服务端不需要的本地模组（:375-397）；
--     ② 检查必需模组是否齐备（:399-426）；
--     ③ 缺失则从创意工坊下载（:432-477）；
--     ④ 下载后二次校验版本（:437-464）；
--     ⑤ 启用服务端要求的模组（:348-364 的内部函数）。
--   ★★ 核心问题：★ 「客户端的模组集合」必须与「服务端要求的集合」对齐，
--     但客户端可能有额外的本地模组（单机用的）。
--   ★★★ 解法的关键概念（★ 贯穿全函数）：
--     「临时启用/禁用」（TempEnable / TempDisable）——
--     ★★ 不修改玩家的永久配置，只在本次会话生效。
--   ★★ 第 348 行的内部函数 enable_server_mods 定义在**最前面**，
--     ★★ 但在最末尾才被调用（:429/:450）—— 提前定义以确保可用。
--   ★ 交叉引用：KnownModIndex（模组索引，模组系统核心对象）。
function DownloadMods( server_listing )
    local function enable_server_mods()
        print("We now have the required mods, enable them for server")
--★★★[第 350-355 行：临时启用「所有客户端都需要」的模组]
--   for k,mod in pairs(server_listing.mods_description) do
--       if mod.all_clients_require_mod then
--           KnownModIndex:TempEnable(mod.mod_name)
--   ★★★ all_clients_require_mod —— ★ 「服务端声明所有客户端都必须有的模组」。
--   ★★ 这些模组（如官方地图、剧情包）必须在所有客户端存在，否则世界不同步。
--   ★★ TempEnable 而非 Enable —— ★★ 只在本次会话启用，不写进配置。
--     ★★ 因为下次进别的服（不需要这个模组）时不应该有它。
--   ★ 第 353 行的 print("Temp Enabling "..mod.mod_name) —— 调试日志。
        for k,mod in pairs(server_listing.mods_description) do
            if mod.all_clients_require_mod then
                print("Temp Enabling " .. mod.mod_name)
                KnownModIndex:TempEnable(mod.mod_name)
            end
        end

--★★★[第 357-360 行：★★ 模组配置的沙箱应用]
--   local success, temp_config_data = RunInSandboxSafe(server_listing.mods_config_data)
--   if success and temp_config_data then
--       KnownModIndex:SetTempModConfigData( temp_config_data )
--   ★★★ RunInSandboxSafe —— ★★ 本文件第二次使用安全沙箱。
--     ★（第一次见 networkclientrpc.lua:1545 的 SHARD_RPC）。
--     ★★ 用它的原因：mods_config_data 来自**服务端**，是序列化数据。
--     ★★ 若直接执行（load），服务端就能在客户端执行任意 Lua ——
--       ★★★ 这是「远程代码执行」漏洞。RunInSandboxSafe 杜绝了这一点。
--   ★★★ success 检查 —— 沙箱执行失败时不应用配置（防御性）。
--   ★★ 沙箱的具体限制（推测）：只允许数据表构造，禁止函数定义/IO/元表操作。
--   ★★★ 这是本文件里最重要的安全实践之一（★ 服务端→客户端方向仍需沙箱！）。
--   ★★ 注意：即便 networking.lua 声称「服务端→客户端可信」（networkclientrpc §五），
--     ★★ 这里依然用了沙箱 —— 因为「信任」不等于「值得执行任意代码」。
--     ★★ 这是比「信任模型」更严格的实践。
        local success, temp_config_data = RunInSandboxSafe(server_listing.mods_config_data)
        if success and temp_config_data then
            KnownModIndex:SetTempModConfigData( temp_config_data )
        end

        print("Mods are setup for server, save the mod index and proceed.")
        KnownModIndex:Save()
    end

--★★[第 366-373 行：内部辅助函数 server_listing_contains]
--   local function server_listing_contains(mod_desc_table, mod_name )
--       for _,mod in pairs(mod_desc_table) do if mod.mod_name == mod_name then return true end end
--       return false
--   ★★★ 一个「线性查找」小工具。
--   ★★★ 第 367 行的遍历用 pairs 而非 ipairs —— ★ 正确选择！
--     ★ 因为 mods_description 是「数组」但源自网络数据，用 pairs 更防御（
--       ★ 即使它意外是字典也能工作）。
--   ★★ 这是「防御性遍历」的另一个例证（对比 prefabs/world.lua:64 用 pairs 是因为字典）。
--   ★★ O(n) 查找 —— 本文件未建索引表（与 networkclientrpc:945 的反查同理）。
--     ★ 在「每次会话一次」的流程里，O(n) 完全可接受。
    local function server_listing_contains(mod_desc_table, mod_name )
        for _,mod in pairs(mod_desc_table) do
            if mod.mod_name == mod_name then
                return true
            end
        end
        return false
    end

--★★★[第 375 行：print("DownloadMods and temp disable") —— 进入模组对齐流程的标志]
--   ★★ 调试日志。每会话一次，不算吵。
    print("DownloadMods and temp disable")

--★★[第 377 行：KnownModIndex:UpdateModInfo() —— 刷新本地模组信息]
--   ★★★ 必须在决策前调用 —— ★ 保证「本地有哪些模组」是最新状态
--     （创意工坊可能在游戏运行期间下载了新模组）。
--   ★★ 第 439 行在下载后又调了一次同样的方法 —— ★「用最新数据重新校验」。
--     ★ 这是「两阶段校验」的模式：下载前查一次，下载后查一次。
    KnownModIndex:UpdateModInfo()
--★★★[第 378-389 行：★★★ 临时禁用在服务端不需要的模组]
--   for _,mod_name in pairs(KnownModIndex:GetServerModNames()) do
--       local modinfo = KnownModIndex:GetModInfo(mod_name)
--       if not modinfo.client_only_mod then
--           if server_listing_contains( server_listing.mods_description, mod_name ) then
--               --we found it, so leave the mod enabled
--           else
--               --this mod is required by all clients but the server doesn't have
--               --it enabled or it's a server mod, so locally disable it temporarily.
--               KnownModIndex:TempDisable(mod_name)
--   ★★★ 决策逻辑（★ 三个条件的层层过滤）：
--     ① ★ 遍历「服务端模组」（GetServerModNames —— 客户端装的服务端侧模组）；
--     ② ★ if not modinfo.client_only_mod —— ★★ 排除纯客户端模组：
--       ★★ 推理：纯客户端模组（如 UI 美化）不影响世界同步，
--         ★★ 所以**不禁用** —— 玩家想在哪个游戏都用它。
--       ★★ 这是「区分影响范围」的设计：只有影响世界的模组才需要对齐。
--     ③ ★★ 服务端的 mods_description 里找不到 → 临时禁用：
--       ★★ 原注释解释了两条可能：
--         「this mod is required by all clients but the server doesn't have it enabled
--           OR it's a server mod（纯服务端模组，客户端不需要）」
--       ★★ 两种情况都导致「本地禁用」—— 因为本地用不上它。
--   ★★ 第 384-385 行有被注释的 print —— ★ 作者调试后去掉（太吵）。
    for _,mod_name in pairs(KnownModIndex:GetServerModNames()) do
        local modinfo = KnownModIndex:GetModInfo(mod_name)
        if not modinfo.client_only_mod then
            if server_listing_contains( server_listing.mods_description, mod_name ) then
                --we found it, so leave the mod enabled
            else
                --this mod is required by all clients but the server doesn't have it enabled or it's a server mod, so locally disable it temporarily.
                --print("Temp disabling ",mod_name)
                KnownModIndex:TempDisable(mod_name)
            end
        end
    end
--★★[第 390-396 行：服务端禁用客户端模组时的处理]
--   if server_listing.client_mods_disabled then
--       --temp disable all the client enabled mods
--       for _,mod_name in pairs(KnownModIndex:GetClientModNames()) do
--           KnownModIndex:TempDisable(mod_name)
--   ★★★ 服务端声明「客户端模组必须全部关闭」（如赛事服/兼容性问题）。
--   ★★★ 注意：★ 这里**没有** client_only_mod 判断 —— 全部禁用。
--     ★ 推理：服务端要求「一个客户端模组都不许有」，因为可能与世界逻辑冲突。
--   ★★ 第 397 行 KnownModIndex:Save() —— ★★★ 临时状态也要存？
--     ★★ 推理：TempEnable/TempDisable 可能是内存态，
--       ★★ Save() 把当前的「临时配置」写进配置文件，避免下次启动还生效。
--       ★ 推测 Temp* 系列会改配置文件，而 Save 提交这些改动。
--       ⚠ 但这与「临时」的语义有点矛盾（详见 :397 的分析）。
    if server_listing.client_mods_disabled then
		--temp disable all the client enabled mods
		for _,mod_name in pairs(KnownModIndex:GetClientModNames()) do
			print("Temp disabling client mod", mod_name)
			KnownModIndex:TempDisable(mod_name)
		end
    end
--★★[第 397 行：KnownModIndex:Save() —— 提交模组索引状态]
--   ★★★ 为什么临时启停后要 Save？
--     推理：TempEnable/TempDisable 改变了模组索引的状态，
--       ★ Save() 把它持久化（写到模组配置文件）。
--   ★★ 潜在矛盾（★ 值得注意的设计细节）：
--     · 「临时」（Temp）暗示「本次会话有效」；
--     · ★★ 但 Save() 把它**写进配置文件** —— ★ 跨会话持久化了。
--     ★★★ 可能的解释：
--       · Temp* 记录的是「临时标记」，而真正的启用/禁用由启动时读取；
--       · ★ 或者 Temp* 的「临时」是指「不修改玩家手动设置的模组列表」。
--     ★★★ 无论哪种，★ 「Temp 语义 + Save 持久化」的组合容易让移植者困惑，
--       ★ 注释里也没说清，建议移植时明确 Temp* 与 Save 的交互。
    KnownModIndex:Save()

--★★★[第 399 行：if server_listing.mods_enabled then —— ★★ 「服务端开模组」的总开关]
--   ★★★ 这是一个大 if（约 90 行）的入口，第 486 行有对应的 else。
--   ★★★ else 分支（第 486-488 行）极简：
--     TheNet:ServerModsDownloadCompleted(true, "", "")
--     ★★ 「服务端没开模组 → 什么都不用做，直接报完成」。
--     ★★★ 统一用 ServerModsDownloadCompleted 告知 C++ 侧结果（:430/:451/:463/
--       :471/:473/:483/:487）—— ★★ 无论成功失败都走这一个出口。
--     ★★★ 这是「单一完成出口」的设计（保证 C++ 侧不会等不到回调）。
    if server_listing.mods_enabled then
        --verify that you have the same mods enabled as the server
--★★★[第 401-423 行：★★★ 必需模组的检查与下载请求]
--   ★★★ 三个状态标志（★ 本函数的控制流骨架）：
--     · have_required_mods —— ★ 所有必需模组本地都有；
--     · needed_mods_in_workshop —— ★ 所有必需模组在创意工坊上存在；
--     · mod_count —— ★ 服务端描述的模组总数。
--   ★★★ 第 404 行遍历 mods_description 的循环体：
--     ① ★★ Profile:GetAutoSubscribeModsEnabled() → TheSim:SubscribeToMod(mod_name)
--       ★★ 「自动订阅」：让这个模组以后自动更新（Steam 的订阅机制）。
--       ★★ 这是一个用户体验特性（而非必需逻辑）。
--     ② ★★ mod.all_clients_require_mod 判断是否必需；
--     ③ ★★ DoesModExist(mod_name, mod.version) —— ★★ 版本精确检查！
--       ★★ 注意传了 version —— 「本地有同名模组但版本不同」也算没有。
--       ★★★ 这是「版本锁定」的严格策略：★ 模组版本不一致会导致世界不同步。
--     ④ ★★ QueueDownloadTempMod(mod_name, mod.version) —— 请求下载；
--       ★ can_dl_mod 为假 → needed_mods_in_workshop = false（工坊上找不到）。
--   ★★★ 第 424-426 行：mod_count == 0 的异常检测：
--     print("ERROR: Mods are enabled but the mods_description table has none in it?")
--     ★ 「服务端说开了模组，但描述表是空的」—— ★ 协议异常。
--     ★★★ 注意：**只记录不处理**（继续往下走）。
--       ★ 推测：这种异常罕见，且强行中断可能导致玩家无法进任何有模组的服。
--       ★ 「记录 + 继续」是务实的选择。仅标注。
        local have_required_mods = true
        local needed_mods_in_workshop = true
        local mod_count = 0
--★★★[第 404-423 行：★★★ 模组检查主循环的逐段拆解]
--   ★★★ 循环遍历 server_listing.mods_description（服务端要求的模组列表）：
--   ── 段①（第 405 行）：计数 ──
--     mod_count = mod_count + 1
--     ★★★ 为什么要计数？
--       ★ 第 424-426 行用它检测「声明了模组但列表为空」的协议异常。
--       ★★ 计数本身就是「循环了多少」的证据。
--   ── 段②（第 407-409 行）：★ 自动订阅 ──
--     if Profile:GetAutoSubscribeModsEnabled() then TheSim:SubscribeToMod(mod.mod_name) end
--     ★★★ 「自动订阅」= 打开 Steam 的创意工坊订阅（自动收更新）。
--     ★★ 依赖玩家的 Profile 设置（是否想自动更新）。
--       ★ 推测还涉及平台特性（Steam 才有订阅机制）。
--     ★★ 这是「用户体验」功能，不影响能否进服（可选）。
--   ── 段③（第 411-414 行）：★ 版本精确检查 ──
--     if mod.all_clients_require_mod then
--         if not KnownModIndex:DoesModExist( mod.mod_name, mod.version ) then
--             print("Failed to find mod "..mod.mod_name.." v:"..mod.version )
--             have_required_mods = false
--     ★★★ DoesModExist(mod_name, version) —— ★★ 「有且版本对」才算存在。
--       ★★★ 严格版本检查的理由（★ 关键推理）：
--       ★★ 模组版本不一致会导致**世界不同步**——
--         ★★ 实体、物品、配方在不同玩家客户端表现不同 → 联机崩溃。
--       ★★ 所以「有旧版本」等于「没有」。
--       ★★ 这与 sandbox 里「大概相似的版本」（:879 TryDefaultEncodeUserPath）不同。
--     ── 段④（第 416-420 行）：★ 请求下载 ──
--         local can_dl_mod = TheSim:QueueDownloadTempMod(mod.mod_name, mod.version)
--         if not can_dl_mod then
--             print("Unable to download mod " .. mod.mod_name .. " from ModWorkshop")
--             needed_mods_in_workshop = false
--     ★★★ 三个标志的分工（★ 控制流骨架）：
--       · have_required_mods  —— 至少一个必需模组本地没有（需要下载）；
--       · ★★ needed_mods_in_workshop —— 有模组连工坊上都找不到（无法下载）；
--       · ★★★ 两者是不同维度的失败，「工坊上没有」比「本地没有」更严重。
--     ★★ can_dl_mod（能否排队下载）为假 → 判定「工坊上没有」；
--       ★ 推理：★ 连排队都不行 = 工坊里确实没这个模组。
--       ★★ 推测区分：Steam 订阅制模组不能「临时下载」（只能订阅后下载）。
--   ★★★ ★★★ 循环体只对 all_clients_require_mod 的模组做检查
--     ——★ 非必需模组（「可选」的）不检查（没有也能进服）。
        for k,mod in pairs(server_listing.mods_description) do
            mod_count = mod_count + 1

            if Profile:GetAutoSubscribeModsEnabled() then
                TheSim:SubscribeToMod(mod.mod_name)
            end

            if mod.all_clients_require_mod then
                if not KnownModIndex:DoesModExist( mod.mod_name, mod.version ) then
                    print("Failed to find mod "..mod.mod_name.." v:"..mod.version )

                    have_required_mods = false
                    local can_dl_mod = TheSim:QueueDownloadTempMod(mod.mod_name, mod.version)
                    if not can_dl_mod then
                        print("Unable to download mod " .. mod.mod_name .. " from ModWorkshop")
                        needed_mods_in_workshop = false
                    end
                end
            end
        end
        if mod_count == 0 then
            print("ERROR: Mods are enabled but the mods_description table has none in it?")
        end

--★★★[第 428-431 行：★★ 快速路径 —— 模组已齐备，直接完成]
--   if have_required_mods then
--       enable_server_mods()
--       TheNet:ServerModsDownloadCompleted(true, "", "")
--   ★★★ 三步：启用 → 报成功。
--   ★★ 「mod_count == 0 的异常」也会走这条路（第 424 行只记录不 return）——
--     ★ 意味着「开了模组但列表为空」会被当作「模组已齐备」。
--     ★ 这个行为其实是合理的（没有必需模组 = 无需下载）。
--★★★[第 428-431 行：★★ 「模组已齐备」的快速路径]
--   if have_required_mods then
--       enable_server_mods()
--       TheNet:ServerModsDownloadCompleted(true, "", "")
--   ★★★ 三步：启用服务端模组 → 上报成功 → 空串。
--   ★★ 「本地已有 → 跳过下载」是优化路径（:428 vs :449 两条路径都汇聚于此）。
--   ★★★ 上报的三参数：(成功标志, 消息, 错误码)。成功时后两空。
        if have_required_mods then
            enable_server_mods()
            TheNet:ServerModsDownloadCompleted(true, "", "")
        else
--★★★[第 432-433 行：需要下载的分支]
--   if needed_mods_in_workshop then
--       TheSim:StartDownloadTempMods(function(success, msg) ... end)
--   ★★★ 异步下载：★ 传入回调，下载完成后继续流程。
--   ★★★ 两个失败原因的区分（★ 关键设计）：
--     · needed_mods_in_workshop 为真 → 尝试下载；
--     · ★★ 为假 → 直接告知「工坊上不存在」（第 478-485 行）。
--   ★★ 为什么区分？（★ 用户体验）
--     · 「下载失败」（网络问题）→ 可重试；
--     · ★「工坊上没有这个模组」→ 重试无用，需要人工处理 → 不同错误码。
            if needed_mods_in_workshop then
                TheSim:StartDownloadTempMods(
                    function( success, msg )
--★★★[第 435-451 行：★★ 下载成功后的二次校验]
--   if success then
--       --downloading of mods succeeded, now double check if the right versions exists,
--       --if it doesn't then we downloaded the wrong version
--   ★★★ 原注释点明了「二次校验」的必要性：
--     ★★ 下载成功**不代表版本正确** ——
--       ★★ 工坊上的最新版可能不是服务端要求的版本。
--     ★★ 所以必须下载后重新 DoesModExist（带 version）检查。
--   ★★★ 第 439 行：KnownModIndex:UpdateModInfo() —— ★★ 先刷新！
--     ★★★ 原注释 "Make sure we're verifying against the latest data in the
--     mod folder" —— ★ 下载的文件需要先被索引才能检查。
--     ★★ 没有这一步，DoesModExist 会看不到刚下载的模组。
--   ★★★ 第 440-447 行：重新遍历校验，追踪失败的具体模组：
--     all_mods_good = false
--     mod_with_invalid_version = mod    -- ★★ 记下是哪个模组版本不对
--   ★★ 记住「哪个」是为了生成准确的错误消息（第 452-464 行）。
                        if success then
                            --downloading of mods succeeded, now double check if the right versions exists, if it doesn't then we downloaded the wrong version
                            local all_mods_good = true
                            local mod_with_invalid_version = nil
                            KnownModIndex:UpdateModInfo() --Make sure we're verifying against the latest data in the mod folder
                            for k,mod in pairs(server_listing.mods_description) do
                                if mod.all_clients_require_mod then
                                    if not KnownModIndex:DoesModExist( mod.mod_name, mod.version, mod.version_compatible ) then
                                        all_mods_good = false
                                        mod_with_invalid_version = mod
                                    end
                                end
                            end

--★★★[第 449-451 行：★★ 二次校验通过 → 与快速路径相同的完成流程]
--   if all_mods_good then
--       enable_server_mods()
--       TheNet:ServerModsDownloadCompleted(true, "", "")
--   ★★★ 与第 428-431 逐字相同 —— ★ 「两条路径，同一终点」。
--   ★★ 这是「早返回/多路径汇聚」的设计：
--     · 路径一：模组本来就有 → 启用 → 完成；
--     · 路径二：下载后校验通过 → 启用 → 完成；
--     · ★★ 两条路径的收尾代码相同，避免重复。
--   ★ 注意重复本身（两处相同的三行）—— 可提取为函数，但当前可读性尚可。
                            if all_mods_good then
                                enable_server_mods()
                                TheNet:ServerModsDownloadCompleted(true, "", "")
--★★★★[第 452-464 行：★★ 版本不符的错误报告（★ 最细致的一处）]
--   ★★★ 第 452-458 行：获取工坊上的实际版本号用于对比。
--     workshop_version = ""
--     if KnownModIndex:GetModInfo(...) ~= nil then
--         workshop_version = KnownModIndex:GetModInfo(...).version
--     else
--         print("ERROR: " .. (mod_with_invalid_version.mod_name or "")
--               .. " has no modinfo, why??? ")
--     end
--     ★★★ 三层兜底：
--       ① 有 modinfo → 用其 version；
--       ② 无 modinfo → 记录异常（"has no modinfo, why???"）；
--       ③ ★★ 第 459-461 行：if workshop_version == nil then workshop_version = "" end
--       ★★★ 注意有两层空值处理（else 分支给 ""，再判 nil 给 ""）——
--         ★ 冗余但安全（因为 GetInfo 可能返回 version 为 nil 的表）。
--   ★★★ 第 462 行的错误消息（★ 用户体验的关键）：
--     local version_mismatch_msg = "The server's version of "
--         .. mod_with_invalid_version.modinfo_name   -- ⚠ 注意是 modinfo_name！
--         .. " does not match the version on the Steam Workshop. Server version: "
--         .. mod_with_invalid_version.version
--         .. " Workshop version: " .. workshop_version
--     ★★★★ ⚠ 疑似缺陷：★ modinfo_name 字段的可疑性
--       · 前面记录的字段是 mod_name（第 454 行用）；
--       · ★★ 这里用的是 modinfo_name —— ★ 推测是作者笔误；
--       · ★★★ 若为 nil，字符串拼接会产出 "... of nil does not ..."。
--       ★ 这是「消息生成路径上的字段名笔误」，属低危但影响用户看到的错误文本。
--       → 移植时应修正为 mod_name。仅标注，不改码。
--   ★★★ 第 463 行：
--     TheNet:ServerModsDownloadCompleted(false, version_mismatch_msg,
--                             "SERVER_MODS_WORKSHOP_VERSION_MISMATCH")
--     ★★ 第三个参数是**机器可读的错误码**（供 C++/UI 判断该显示什么）。
--     ★ 全部错误码列举：
--       SERVER_MODS_WORKSHOP_VERSION_MISMATCH（版本不符）
--       SERVER_MODS_WORKSHOP_ACCESS_DENIED（访问被拒）
--       SERVER_MODS_WORKSHOP_FAILURE（下载失败）
--       SERVER_MODS_NOT_ON_WORKSHOP / _RAIL（工坊上不存在）
--     ★★★ 「错误码 + 人类可读消息」的双通道设计（★ 良好实践）：
--       · 错误码供程序判断（稳定，不随文案变化）；
--       · 消息供人阅读（可本地化、可详细）。
                            else
                                local workshop_version = ""
                                if KnownModIndex:GetModInfo(mod_with_invalid_version.mod_name) ~= nil then
                                    workshop_version = KnownModIndex:GetModInfo(mod_with_invalid_version.mod_name).version
                                else
                                    print("ERROR: " .. (mod_with_invalid_version.mod_name or "") .. " has no modinfo, why???" )
                                end
                                if workshop_version == nil then
                                    workshop_version = ""
                                end
                                local version_mismatch_msg = "The server's version of " .. mod_with_invalid_version.modinfo_name .. " does not match the version on the Steam Workshop. Server version: " .. mod_with_invalid_version.version .. " Workshop version: " .. workshop_version
                                TheNet:ServerModsDownloadCompleted(false, version_mismatch_msg, "SERVER_MODS_WORKSHOP_VERSION_MISMATCH" )
                            end
--★★★[第 465-477 行：★★ 下载失败的处理与渠道区分]
--   else
--       local sku = ""
--       if IsRail() then sku = "_RAIL" end
--       if msg == "Access to mod denied" then
--           TheNet:ServerModsDownloadCompleted(false, msg,
--                             "SERVER_MODS_WORKSHOP_ACCESS_DENIED"..sku)
--       else
--           TheNet:ServerModsDownloadCompleted(false, msg,
--                             "SERVER_MODS_WORKSHOP_FAILURE"..sku)
--   ★★★ 两个设计细节：
--     ① ★★★ sku 后缀区分渠道（Rail vs Steam）；
--       ★★ 为什么要区分？（★ 关键推理）
--       ★ 创意工坊有两套：Steam Workshop 与 Rail（WeGame/国服工坊）；
--       ★★ 两边的创意工坊是**不同的服务器** ——
--         ★★ 所以「下载失败」的**原因和提示**也不同（用户去不同地方下载）。
--       ★ 错误码带渠道后缀，C++ 侧才能给出正确的引导（如「去 WeGame 下载」）。
--     ② ★★ 第 470 行用 `msg == "Access to mod denied"` 精确匹配字符串 ——
--       ★★ 这种「按错误文案分支」很脆弱（改文案就失效）；
--         ★ 更好的做法是错误码枚举。仅标注为脆弱点。
--   ★★★ 这一段整体是「失败分类上报」的最佳实践样本。
                        else
                            local sku = ""
                            if IsRail() then
                                sku = "_RAIL"
                            end
                            if msg == "Access to mod denied" then
                                TheNet:ServerModsDownloadCompleted(false, msg, "SERVER_MODS_WORKSHOP_ACCESS_DENIED"..sku)
                            else
                                TheNet:ServerModsDownloadCompleted(false, msg, "SERVER_MODS_WORKSHOP_FAILURE"..sku)
                            end
                        end
                    end
                )
--★★★[第 478-485 行：★★ 「模组不在工坊上」的最终处理]
--   else
--       local error = "SERVER_MODS_NOT_ON_WORKSHOP"
--       if IsRail() then error = "SERVER_MODS_NOT_ON_WORKSHOP_RAIL" end
--       TheNet:ServerModsDownloadCompleted(false,
--         "You don't have the required mods to play on this server and they don't
--          exist on the Workshop. You will need to download them manually.", error)
--   ★★★ 这是「无法自动恢复」的情况 —— ★ 只能让玩家手动下载。
--   ★★ 消息明确告知了「这是不可自动解决的问题」+「你需要手动下载」。
--     ★★ 良好的错误 UX：不甩锅（不报错），给可执行的指引。
--   ★★ 注意此处消息是**英文硬编码**（未走 STRINGS 本地化）——
--     ★★ 对比第 462 行的 version_mismatch_msg 也是硬编码英文。
--     ★★★ 说明这些错误消息**没有本地化**（或本地化在 C++ 侧）。
--       ★ 移植时应纳入本地化体系。仅标注。
            else
                local error = "SERVER_MODS_NOT_ON_WORKSHOP"
                if IsRail() then
                    error = "SERVER_MODS_NOT_ON_WORKSHOP_RAIL"
                end
                TheNet:ServerModsDownloadCompleted(false, "You don't have the required mods to play on this server and they don't exist on the Workshop. You will need to download them manually.", error )
            end
        end
    else
        TheNet:ServerModsDownloadCompleted(true, "", "")
    end
end
--★★★ DownloadMods 结束（142 行）。★★★ 模组对齐流程的五阶段（见 :347 的总览）：
--   ① 临时禁用多余模组（:378-396）
--   ② 检查必需模组（:401-426）
--   ③ 缺失则下载（:432-477）
--   ④ ★ 下载后二次校验版本（:437-464）——「下载成功 ≠ 版本正确」
--   ⑤ 启用并完成（enable_server_mods + ServerModsDownloadCompleted）
--   ★★ 核心安全实践：RunInSandboxSafe（:357）—— 服务端传来的配置必须沙箱执行。
--   ★★ 错误码体系（★ 良好实践）：机器可读错误码 + 人类可读消息双通道，
--     且带渠道后缀（Rail vs Steam）以区分不同创意工坊。
--【机制：联机模组对齐】DownloadMods（142 行，五阶段）。
--   ★★ 安全基石：RunInSandboxSafe(:357) —— ★★ 即便「服务端可信」，
--     ★★ 来自服务端的代码仍必须沙箱执行（防远程代码执行）。
--   ★★ 版本锁定：DoesModExist(name, version)（:412/:442）——
--     ★★ 「有旧版本」等于「没有」（版本不一致会导致世界不同步）。
--   ★★ 二阶段校验（:439 刷新 + :440-447 重新检查）——
--     ★★ 「下载成功 ≠ 版本正确」。参见 shardnetworking.lua:74-88 的同类沙箱解码。
--   ★★ 错误码体系：机器码 + 人类消息双通道，带渠道后缀（_RAIL）。
--   ★★ 参见 networkclientrpc.lua:1848 ⚠ 缺陷 B（模组可无限抬高全局 RPC 限流）。
--★★ 参见 shardnetworking.lua:74-88（同源的「沙箱 + 严格结构校验」解码手法）；
--   ★★ 参见 networkclientrpc.lua:1848 ⚠ 缺陷 B（模组扩展点的另一处问题）。

--★★[ShowConnectingToGamePopup —— 「正在连接」弹窗的防重入封装]
--   ★★★ 第 493 行的条件：只有当前**不在这三个界面**时才推新界面：
--     · ConnectingToGamePopup（「正在连接」）
--     · QuickJoinScreen（快速加入）
--     · HostCloudServerPopup（云服务器）
--   ★★ 为什么要排除这三个？
--     ★ 推理：它们是「正在连接」流程中的相关界面；
--       ★★ 若在它们之上再推一个「正在连接」弹窗 → 界面叠加错乱。
--   ★★ 第 492 行的 nil 保护：active_screen 可能为 nil（刚启动还没界面）。
--   ★ 这是一个「幂等的 UI 弹窗」辅助函数。
function ShowConnectingToGamePopup()
    local active_screen = TheFrontEnd:GetActiveScreen()
    if active_screen == nil or (active_screen.name ~= "ConnectingToGamePopup" and active_screen.name ~= "QuickJoinScreen" and active_screen.name ~= "HostCloudServerPopup") then
        TheFrontEnd:PushScreen(ConnectingToGamePopup())
    end
end

--★★★★★[JoinServer —— ★★★ 「加入服务器」的完整编排（146 行）]
--   ★★★ 签名：JoinServer(server_listing, optional_password_override)
--     · server_listing —— 服务器列表项（含 guid / 是否有密码 / 模组信息等）；
--     · ★ optional_password_override —— 已知密码时跳过输入框。
--   ★★★ 函数体是「三个嵌套的内部函数 + 层层回调」（★ 典型的 UI 流程编排）：
--     ┌──────────────────────────────────────────────────────────────┐
--     │ send_response(:499) ────────── 真正发起连接的地方              │
--     │      ↑ 被 after_mod_warning 调用                             │
--     │ on_cancelled(:509) ────────── 用户取消                        │
--     │      ↑ 被密码框/警告框的取消按钮调用                          │
--     │ after_mod_warning(:517) ────── 密码输入 → send_response       │
--     │      ↑ 被 after_client_mod_message 调用                       │
--     │ after_client_mod_message(:557) ★ 模组警告弹窗 → 下一步        │
--     │      ↑ 被第 628 行的检查或直接调用                            │
--     │ ★ 主流程入口：客户端模组禁用检查 → 模组警告 → 密码 → 连接    │
--     └──────────────────────────────────────────────────────────────┘
--   ★★★ ★★ 流程顺序（★ 理解关键）：
--     ① 客户端模组被禁警告（:628）→ ② 服务端模组警告（:558）
--     → ③ 密码输入（:518）→ ④ 真正连接（:501）
--   ★★ 为什么模组警告在密码**之前**？
--     ★★ 推理：★ 密码验证在服务端，而模组警告是本地决策。
--       ★★ 更重要的是：★★ 「取消」路径不消耗服务端资源 ——
--         ★★ 若先发连接请求再弹警告，取消就浪费了一次连接。
--       ★ 这是一个很实际的优化：**先本地确认，再发起网络请求**。
function JoinServer(server_listing, optional_password_override)
--★★★[send_response —— ★★ 真正发起连接的地方]
--   local function send_response(password)
--       -- Just pass the guid in here, the network manager should have this listing
--       local start_worked = TheNet:JoinServerResponse( false, server_listing.guid, password )
--   ★★★★ 函数名 JoinServerResponse 与本函数 JoinServer 极易混淆 ——
--     ★★ 注意区分：
--       · JoinServer（:498）—— ★ 本文件：UI 编排层；
--       · ★ JoinServerResponse（:501）—— C++ 侧：实际发起连接。
--   ★★★ 第 501 行的三个参数：
--     · false —— ★★ 推测是 is_retry 或 is_cancelled 标志：
--       ★★ false = 「不是取消，是真正开始连接」；
--       ★★ 对照第 510 行 on_cancelled：`TheNet:JoinServerResponse(true)`
--         ★★★ true = 「取消」—— ★ 这是同一接口的两种语义！
--       ★★ 一个函数 + 一个布尔 = 「确认/取消」二态协议。
--       ★ 设计巧妙：一个接口覆盖开始与取消。
--     · guid —— 服务器标识（原注释说明「network manager should have this listing」，
--       ★★★ 即「服务端列表信息网络管理器已经有了，只传 guid 即可」——
--       ★★ 省去重复传递整张列表（带宽/复杂度优化）。
--     · password —— 密码（可能为空串）。
--   ★★★ 第 503-505 行：
--     if start_worked then DisableAllDLC() end
--     ★★ ★★★ 重要：★ 连接**成功发起**后就禁用所有 DLC！
--       ★★★ 推理：DLC 内容（如角色/皮肤）是账号相关的，
--         ★★ 「即将进入的世界」决定了哪些 DLC 生效。
--       ★★ 为什么在「发起」而非「成功」后禁用？
--         ★★ 因为 DLC 状态必须在**加载世界前**就绪 ——
--           ★★★ 若等到连接成功再设，加载阶段会用到错误的 DLC 状态。
--         ★★ 「提前准备」是关卡切换的正确做法。
--   ★★ 第 506 行 ShowConnectingToGamePopup() —— 显示等待界面。
--     ★ 注意它在 if **外面**（无论 start_worked 是否为真都弹）——
--       ★ 推理：即使用户输入了错误密码，也需要显示「正在连接（验证）」。
--       ★★ 错误反馈由后续流程（超时/失败）处理。
    local function send_response(password)
        -- Just pass the guid in here, the network manager should have this listing
        local start_worked = TheNet:JoinServerResponse( false, server_listing.guid, password )

        if start_worked then
            DisableAllDLC()
        end
        ShowConnectingToGamePopup()
    end

--★★★[on_cancelled —— 取消路径]
--   local function on_cancelled()
--       TheNet:JoinServerResponse(true)
--       local screen = TheFrontEnd:GetActiveScreen()
--       if screen ~= nil and screen.name == "ConnectingToGamePopup" then
--           screen:Close()
--   ★★★ 第 510 行：JoinServerResponse(true) —— ★★ 告诉网络层「用户取消」。
--     ★★ 与 :501 的 false 构成二态（见 send_response 的分析）。
--     ★★★ 这个 true 不可省略：网络层可能已经建立了连接尝试，
--       ★★ 必须显式通知取消，否则会留下悬挂的连接。
--   ★★★ 第 512-514 行：关闭「正在连接」弹窗（若它在最前）。
--     ★★ 为什么要判 screen.name？因为取消可能发生在多个弹窗之间，
--       ★★ 只关闭确实在显示的那个（避免关错界面）。
    local function on_cancelled()
        TheNet:JoinServerResponse(true)
        local screen = TheFrontEnd:GetActiveScreen()
        if screen ~= nil and screen.name == "ConnectingToGamePopup" then
            screen:Close()
        end
    end

--★★★[after_mod_warning —— ★★ 密码输入与连接发起的决策点]
--   ★★★ 第 518 行条件（★ 关键判断）：
--     if server_listing.has_password
--        and (optional_password_override == "" or optional_password_override == nil) then
--   ★★★ 两个条件的合取：
--     ① has_password —— 服务器有密码；
--     ② ★★ 没有已知的密码覆盖 —— ★ 即「我们不知道密码」。
--   ★★★ 为什么要判断 #2？因为「已记住的密码」场景下要跳过输入框。
--     ★★ 这支持免密加入（如上次输入过，服务端已记录）。
--   ★★ 第 519-537 行：构建密码输入对话框（InputDialogScreen）。
--     ★ 两个按钮：「加入」（:523）与「取消」（:530）。
--     ★ 第 525-526 行：JOIN 按钮 → PopScreen（弹出对话框）→ send_response(实际密码)。
--     ★ 第 532-533 行：CANCEL 按钮 → PopScreen → on_cancelled()。
--   ★★★ ★★ 三个方法的组合构成对话框的自定义：
--     · :538 password_prompt_screen.edit_text.OnTextEntered = function() ...
--       ★ 「回车即确认」的快捷键；
--     · :546 if not Profile:GetShowPasswordEnabled() then
--       password_prompt_screen.edit_text:SetPassword(true)
--       ★★ 「密码框」模式（显示为掩码）—— 但**可由玩家设置关闭**。
--       ★★ 这个设置的意义：有些玩家为了方便想看到自己输入的字符。
--     · :550-551 SetForceEdit(true) + OnControl(CONTROL_ACCEPT, false)
--       ★★ 「强制进入编辑态」并主动触发 CONTROL_ACCEPT ——
--       ★★★ 即「打开对话框时光标已经就绪，可直接输入」。
--       ★★ 这是「降低交互成本」的 UI 打磨（不用先点一下输入框）。
    local function after_mod_warning()
--★★★[第 518-557 行：★★ 密码对话框内部的全部逻辑]
--   ★★★ 第 519-537 行：构建 InputDialogScreen（密码输入框）：
--     · 标题：STRINGS.UI.SERVERLISTINGSCREEN.PASSWORDREQUIRED
--     · 按钮数组：[{text=JOIN, cb=..}, {text=CANCEL, cb=..}]
--     · ★★ 末尾的 true 参数 = 「密码框模式」（不直接显示输入内容）。
--   ★★★ 两个按钮的回调（第 524/531 行）：
--     · JOIN 按钮：弹出色对话框 → send_response(输入的密码)；
--     · ★★ CANCEL 按钮：弹出色对话框 → on_cancelled()。
--     ★★★ 注意：两个按钮都先 PopScreen（关掉对话框）再执行逻辑。
--       ★★ 因为 send_response 之后会弹新的「连接中」界面（:506），
--         ★★★ 不先关掉对话框会导致界面栈错乱。
--       ★★ 「界面栈管理」是这类回调编排的核心纪律。
--   ★★★★ 三个「输入框定制」（★ UI 打磨）：
--     ① :538 password_prompt_screen.edit_text.OnTextEntered = function()
--       ★★★ 「按回车」的快捷键。输入非空则确认，为空则重新聚焦。
--     ② :546 if not Profile:GetShowPasswordEnabled() then
--       password_prompt_screen.edit_text:SetPassword(true)
--       ★★★ 「是否显示密码」的玩家设置（§7 的可覆盖钩子思路类似）。
--     ③ :550-551 password_prompt_screen.edit_text:SetForceEdit(true)
--       password_prompt_screen.edit_text:OnControl(CONTROL_ACCEPT, false)
--       ★★★ 「强制聚焦」—— 打开对话框时光标已在输入框内，可直接敲键盘。
--       ★★★ 关键 UX 细节：★★ 打开就能输入，不用多点一次。
--       ★★ 第 551 行 OnControl(CONTROL_ACCEPT, false) 是「模拟一次接受键」。
--         ★★★ 这在 DST 的 UI 体系里是一种「主动激活输入」的惯用法。
        if server_listing.has_password and (optional_password_override == "" or optional_password_override == nil) then
--★★[第 519-537 行：密码对话框的构造参数]
--   ★★★★ InputDialogScreen(标题, 按钮数组, true) 的三参数：
--     ① 标题：STRINGS.UI.SERVERLISTINGSCREEN.PASSWORDREQUIRED（需要密码）；
--     ② 按钮数组：[{JOIN}, {CANCEL}]（★ 数组顺序即 Tab 焦点顺序）；
--     ③ ★★ true —— 「密码框模式」（输入内容显示为掩码）。
--   ★★★ 注意：★ 这里的 true 是「对话框自己的」密码模式，
--     ★★ 与 :546-548 的 SetPassword(true)（输入框自己的）是两套机制。
--     ★★ 前者创建时就声明，后者在设置允许显示时才不启用。
            local password_prompt_screen
            password_prompt_screen = InputDialogScreen( STRINGS.UI.SERVERLISTINGSCREEN.PASSWORDREQUIRED,
                                            {
                                                {
                                                    text = STRINGS.UI.SERVERLISTINGSCREEN.JOIN,
--★★[第 524-527 行：JOIN 按钮回调]
--   cb = function()
--       TheFrontEnd:PopScreen()   -- ★★ 先关对话框
--       send_response( password_prompt_screen:GetActualString() )  -- ★ 再发起连接
--   ★★★ 两个要点：
--     ① ★★ GetActualString() —— ★★ 「获取输入框的实际内容」；
--       ★★ 而不是读 edit_text 字段 —— InputDialogScreen 封装了输入状态。
--       ★★ 「实际内容」= ★ 经过输入框自己的处理（掩码、限制）后的值。
--     ② ★★ PopScreen 在前 —— ★ 因为 send_response 会弹新的界面（:506），
--       ★★ 必须先关旧的（见本段 BEFORE 的分析）。
                                                    cb = function()
                                                        TheFrontEnd:PopScreen()
                                                        send_response( password_prompt_screen:GetActualString() )
                                                    end
                                                },
                                                {
--★★[第 530-535 行：CANCEL 按钮回调]
--   cb = function()
--       TheFrontEnd:PopScreen()  -- 关对话框
--       on_cancelled()           -- ★ 通知网络层取消
--   ★★★ 与 JOIN 平行，区别只在后续动作（send_response vs on_cancelled）。
                                                    text = STRINGS.UI.SERVERLISTINGSCREEN.CANCEL,
                                                    cb = function()
                                                        TheFrontEnd:PopScreen()
                                                        on_cancelled()
                                                    end
                                                },
                                            },
                                        true )
--★★★[第 538-545 行：★ OnTextEntered —— 「回车即确认」]
--   password_prompt_screen.edit_text.OnTextEntered = function()
--       if password_prompt_screen:GetActualString() ~= "" then
--           TheFrontEnd:PopScreen()
--           send_response( password_prompt_screen:GetActualString() )
--       else
--           password_prompt_screen.edit_text:SetEditing(true)
--   ★★★★ 两个分支的设计意图：
--     ① ★ 输入非空 → 同 JOIN 按钮（PopScreen + send_response）；
--     ② ★★ 输入为空 → 不关闭，★ 而是 SetEditing(true) —— 重新聚焦。
--       ★★★ 为什么空输入不关对话框？
--       ★★ 推理：★ 空密码提交是**无意义**的（服务器要密码）。
--         ★★ 若关闭了对话框，玩家就得重新打开—— ★★ 体验很差。
--         ★★ 「空输入 = 重新聚焦」是一个优雅的「就地拒绝」。
--       ★★ 对比：很多 UI 在空输入时会关窗口或报错，这里选择「拦住不让走」。
            password_prompt_screen.edit_text.OnTextEntered = function()
                if password_prompt_screen:GetActualString() ~= "" then
                    TheFrontEnd:PopScreen()
                    send_response( password_prompt_screen:GetActualString() )
                else
                    password_prompt_screen.edit_text:SetEditing(true)
                end
            end
--★★[第 546-551 行：★★ 「是否显示密码」+ 「强制聚焦」]
--   if not Profile:GetShowPasswordEnabled() then
--       password_prompt_screen.edit_text:SetPassword(true)
--   end
--   TheFrontEnd:PushScreen(password_prompt_screen)
--   password_prompt_screen.edit_text:SetForceEdit(true)
--   password_prompt_screen.edit_text:OnControl(CONTROL_ACCEPT, false)
--   ★★★★ 三步收尾（★ 都是 UX 细节）：
--     ① ★ SetPassword(true) —— ★ 仅当玩家设置「不显示密码」时才启用掩码。
--       ★★ 玩家设置优先于默认值（尊重用户偏好）。
--     ② ★★ PushScreen —— 必须在 SetPassword 之后（配置好再显示）。
--     ③ ★★★ SetForceEdit(true) + OnControl(CONTROL_ACCEPT, false) ——
--       ★★★ 「打开即聚焦」：
--       ★· SetForceEdit(true) 强制输入框进入编辑态；
--       ★· ★★ OnControl(CONTROL_ACCEPT, false) 主动发送一个「接受」控制事件，
--         ★★★ 触发系统级的「调出软键盘」（移动端场景）。
--       ★★★ 这是 DST 支持移动端/Steam Deck 的输入处理惯例。
--       ★★ 效果：★ 打开对话框 → 键盘弹出、焦点就绪 → 玩家直接输入。
--       ★★ 「零点击输入」是优秀的移动端 UX 标准。
            if not Profile:GetShowPasswordEnabled() then
                password_prompt_screen.edit_text:SetPassword(true)
            end
            TheFrontEnd:PushScreen(password_prompt_screen)
            password_prompt_screen.edit_text:SetForceEdit(true)
            password_prompt_screen.edit_text:OnControl(CONTROL_ACCEPT, false)
        else
--★ send_response( optional_password_override or "" ) —— 无密码路径直接连接
--   ★★★ `optional_password_override or ""`：
--     · 有已知密码 → 用它；
--     · ★ 没有 → ★★ 传空串（不是 nil）—— 因为 C++ 侧期望字符串。
--     ★ 与 :518 的判断呼应：走到这行说明不需要密码输入。
--★ send_response( optional_password_override or "" ) —— 「无需密码」路径
--   ★★★ 与密码路径的对比：
--     · 密码路径：send_response(GetActualString()) —— 用输入的密码；
--     · ★ 本路径：send_response(optional_password_override or "")
--       ★★ 用「已知密码」或「空串」（服务器无密码时）。
--   ★★ 二者最终都走同一条 send_response 路径（:501 的 JoinServerResponse）。
            send_response( optional_password_override or "" )
        end
    end

--★★★[after_client_mod_message —— ★★ 「服务端开了模组」的警告弹窗]
--   ★★★ 第 558-561 行的四条件合取（★ 逐条推理）：
--     ① server_listing.mods_enabled —— 服务端要求模组；
--     ② ★★ not IsMigrating() —— ★★ 迁移过程中不弹！
--       ★★★ 为什么？迁移（:646）会重启进程，此时弹窗毫无意义
--         （马上要关掉了）。★ 与 file header 注记 7 一致。
--     ③ (server_listing.dedicated or not server_listing.owner)
--       ★★ 「不是自己开的房」：专服 or 非房主 → 才需要警告；
--       ★★★ 推理：★ 房主自己开的服，他知道有模组，不用警告；
--         ★ 而加入别人的服 → 玩家可能没装 → 需要知情同意。
--     ④ ★★ Profile:ShouldWarnModsEnabled() —— ★★ 玩家设置：
--       ★★ 「是否要警告我服务端有模组」—— 可关闭。
--       ★★★ 这是「用户偏好控制提示」的尊重设计（不强制弹窗骚扰）。
--   ★★★ 综上：这弹窗有「4 个条件同时满足」才出现 —— ★ 设计克制。
    local function after_client_mod_message()
--★★ after_mod_warning 结束。★★ 密码输入与连接发起的决策点。
		if server_listing.mods_enabled and
			not IsMigrating() and
			(server_listing.dedicated or not server_listing.owner) and
			Profile:ShouldWarnModsEnabled() then

--★★[第 563-581 行：手工构建复选框 UI（★ 少见的底层 UI 操作）]
--   ★★★ 这里不用现成控件，而是手工创建：
--     · Widget("checkbox_parent") —— 空容器；
--     · ImageButton(...) —— 复选框图像按钮；
--     · Text(...) —— 说明文字；
--     · Image(...) —— 背景图（后加但 MoveToBack 到最底层）。
--   ★★★ 第 566-579 行是布局计算（★ 典型的「算好每个元素的位置」）：
--     textW, textH = text:GetRegionSize()   -- 文字尺寸
--     imageW, imageH = checkbox:GetSize()   -- 复选框尺寸
--     checkbox_x = -textW/2 - (imageW*2)    -- 复选框在文字左侧
--     ★ text:SetRegionSize(region, 50)     -- 固定文字区域（防换行）
--     ★★ 手工布局是为了让复选框紧贴文字左侧（居中对齐）。
--   ★★★ 第 580-581 行：
--     checkbox_parent.do_warning = true     -- ★★★ 状态存在**容器**上
--     checkbox_parent.focus_forward = checkbox -- ★ 焦点指向复选框
--   ★★ 「状态存在容器上」是本项目 UI 的常见模式（便于闭包访问）。
--   ★★ focus_forward —— 焦点管理（打开对话框后第一个可聚焦控件）。
			local checkbox_parent = Widget("checkbox_parent")
			local checkbox = checkbox_parent:AddChild(ImageButton("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0}))
			local text = checkbox_parent:AddChild(Text(CHATFONT, 30, STRINGS.UI.SERVERLISTINGSCREEN.SHOW_MOD_WARNING))
			local textW, textH = text:GetRegionSize()
			local imageW, imageH = checkbox:GetSize()
			text:SetVAlign(ANCHOR_LEFT)
			text:SetColour(0,0,0,1)
			local checkbox_x = -textW/2 - (imageW*2)
			local region = 600
			checkbox:SetPosition(checkbox_x, 0)
			text:SetRegionSize(region,50)
			text:SetPosition(checkbox_x + textW/2 + imageW/1.5, -10)
			local bg = checkbox_parent:AddChild(Image("images/ui.xml", "single_option_bg.tex"))
			bg:MoveToBack()
			bg:SetClickable(false)
			bg:ScaleToSize(textW + imageW + 40, 50)
			bg:SetPosition(-75,2)
			checkbox_parent.do_warning = true
			checkbox_parent.focus_forward = checkbox
--★★[第 582-589 行：复选框的点击切换逻辑]
--   checkbox:SetOnClick(function()
--       checkbox_parent.do_warning = not checkbox_parent.do_warning
--       if checkbox_parent.do_warning then ... checkbox_off.tex ...
--       else ... checkbox_on.tex ... end
--   ★★★ 切换布尔 + 换贴图（off/on）。
--   ★★★ ★★ 注意一个 ★★ 潜在的不一致：
--     · 第 564 行创建时用的是 **checkbox_off**（未勾选）；
--     · ★ 第 584 行 do_warning = true 时切回 **checkbox_off**；
--     · 第 586 行 do_warning = false 时切到 **checkbox_on**。
--   ★★★★ ⚠ 这里 off/on 的语义**看起来是反的**：
--     · 「要警告」（do_warning=true）→ 显示 off（未勾选）？
--     · 「不警告」（do_warning=false）→ 显示 on（已勾选）？
--     ★★★ 推理：★ 这取决于贴图命名约定 ——
--       ★ 若 on/off 表示「这个选项是否启用」而非「是否勾选警告」，
--         则逻辑正确（启用警告 = on）。
--       ★★ 但贴图名是 checkbox_on/off，配合 do_warning 变量名，
--         ★ 极易混淆（读代码的人会以为这里有 bug）。
--     ★★★ 结论：★ 语义可能正确但**命名极具误导性**，属可读性问题。
--       → 移植时应重命名为 do_warn_mods 并确认贴图语义。仅标注。
			checkbox:SetOnClick(function()
				checkbox_parent.do_warning = not checkbox_parent.do_warning
				if checkbox_parent.do_warning then
					checkbox:SetTextures("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0})
				else
					checkbox:SetTextures("images/ui.xml", "checkbox_on.tex", "checkbox_on_highlight.tex", "checkbox_on_disabled.tex", nil, nil, {1,1}, {0,0})
				end
			end)
--★★[第 590-604 行：警告框的菜单项（继续/取消）]
--   ★★★ 三项：复选框（{widget=...}）+ 继续 + 取消。
--   ★★★ 每个 item 有 offset（Vector3）—— ★ 手工调整位置。
--   ★★★ 第 594-597 行「继续」按钮的回调：
--     Profile:SetWarnModsEnabled(checkbox_parent.do_warning)  -- ★★ 保存玩家选择
--     TheFrontEnd:PopScreen()                                 -- 关闭警告框
--     after_mod_warning()                                     -- ★★ 继续下一步（密码等）
--   ★★ 关键：★ 把玩家的选择**保存到 Profile**，下次同类警告直接沿用。
--     ★★ 即「不要每次都问我」—— 记住偏好。
--   ★★★ 第 599-603 行「取消」按钮：PopScreen + on_cancelled()。
			local menuitems =
			{
				{widget=checkbox_parent, offset=Vector3(250,70,0)},
				{text=STRINGS.UI.SERVERLISTINGSCREEN.CONTINUE,
					cb = function()
						Profile:SetWarnModsEnabled(checkbox_parent.do_warning)
						TheFrontEnd:PopScreen()
						after_mod_warning()
					end, offset=Vector3(-90,0,0)},
				{text=STRINGS.UI.SERVERLISTINGSCREEN.CANCEL,
					cb = function()
						TheFrontEnd:PopScreen()
						on_cancelled()
					end, offset=Vector3(-90,0,0)}
			}

--★★[第 606-620 行：警告弹窗的最终布局调整（★ 纯视觉微调）]
--   ★★★ 第 607 行创建 PopupDialogScreen（标题 + 正文 + 菜单项）。
--   ★★★ 第 608-620 行是**大量手工微调**（SetScale/SetPosition/SetFocusChangeDir）：
--     · :608-609 缩放（标题放大、正文缩小）；
--     · :611-617 ★★★ 手工设置焦点移动方向（MOVE_DOWN/RIGHT/LEFT/UP）；
--       ★★ 这在告诉输入系统：「Tab 键如何在这个弹窗内循环」。
--       ★★★ 推测是修复一个手柄/键盘导航的焦点 bug。
--     · :618-620 三个按钮的绝对位置微调。
--   ★★ 这些细节反映「这个弹窗是在某个 UI 上手写出来的」（而非复用标准组件）。
--   ★ 移植提示：★ 这类纯 UI 微调在新引擎里应丢弃（由布局系统替代）。
			--let the user know the warning about mods
            local mod_warning = PopupDialogScreen(STRINGS.UI.SERVERLISTINGSCREEN.MOD_WARNING_TITLE, STRINGS.UI.SERVERLISTINGSCREEN.MOD_WARNING_BODY, menuitems)
            mod_warning.dialog.actions.items[1]:SetScale(1)
            mod_warning.dialog.body:SetScale(0.8)
            mod_warning.dialog.body:SetPosition(0, 40, 0)
			mod_warning.dialog.actions.items[1]:SetFocusChangeDir(MOVE_DOWN, mod_warning.dialog.actions.items[2])
			mod_warning.dialog.actions.items[1]:SetFocusChangeDir(MOVE_RIGHT, nil)
			mod_warning.dialog.actions.items[2]:SetFocusChangeDir(MOVE_LEFT, nil)
			mod_warning.dialog.actions.items[2]:SetFocusChangeDir(MOVE_RIGHT, mod_warning.dialog.actions.items[3])
			mod_warning.dialog.actions.items[2]:SetFocusChangeDir(MOVE_UP, mod_warning.dialog.actions.items[1])
			mod_warning.dialog.actions.items[3]:SetFocusChangeDir(MOVE_LEFT, mod_warning.dialog.actions.items[2])
            mod_warning.dialog.actions.items[3]:SetFocusChangeDir(MOVE_UP, mod_warning.dialog.actions.items[1])
			mod_warning.dialog.actions.items[1]:SetPosition(305,55,0)
			mod_warning.dialog.actions.items[2]:SetPosition(105,-10,0)
            mod_warning.dialog.actions.items[3]:SetPosition(355,-10,0)

			TheFrontEnd:PushScreen( mod_warning )
		else
			after_mod_warning()
		end
	end

--★★★[第 628-642 行：★★ 「客户端模组被禁」警告 —— 入口检查]
--   if server_listing.client_mods_disabled and
--       not IsMigrating() and
--       (server_listing.dedicated or not server_listing.owner) and
--       AreAnyClientModsEnabled() then
--   ★★★ 四个条件（★ 注意前三个与 :558 的模组警告**完全相同**）：
--     ① client_mods_disabled —— 服务端要求关客户端模组；
--     ② ★ not IsMigrating() —— 迁移时不弹（同上）；
--     ③ ★ (dedicated or not owner) —— 不是自己的房（同上）；
--     ④ ★★ AreAnyClientModsEnabled() —— ★★ 「本地真的有客户端模组吗」
--   ★★★★ 第 ④ 个条件是本检查独有的（:558 没有对应物）——
--     ★★ 推理：★ 如果玩家一个客户端模组都没装，就没必要警告。
--       ★ 这是「避免无意义提示」的克制设计。
--     ★★ 与第 ② 条件的对比：
--       · :558 的条件「服务端开了模组」是恒定的（不变），
--       · ★ :628 的条件「我有没有客户端模组」是动态的（要看本地）。
--   ★★★ 第 633-639 行：创建「客户端模组被禁用」弹窗（只有一个「继续」按钮）。
--     ★★ 注意：**没有「取消」**（只能「继续」）——
--       ★★ 推理：这是一个「告知」而非「确认」（没有选择余地）。
--       ★ 「知道了」→ PopScreen → after_client_mod_message（继续流程）。
--   ★★★ 第 640-641 行：else 分支直接调用 after_client_mod_message。
--   ★★ 整体流程入口：第 628 行检查（客户端模组）→ 第 558 行检查（服务端模组）
--     → 密码 → 连接。
	if server_listing.client_mods_disabled and
		not IsMigrating() and
		(server_listing.dedicated or not server_listing.owner) and
		AreAnyClientModsEnabled() then

		local client_mod_msg = PopupDialogScreen(STRINGS.UI.SERVERLISTINGSCREEN.CLIENT_MODS_DISABLED_TITLE, STRINGS.UI.SERVERLISTINGSCREEN.CLIENT_MODS_DISABLED_BODY,
			{{ text=STRINGS.UI.SERVERLISTINGSCREEN.CONTINUE, cb = function()
						TheFrontEnd:PopScreen()
						after_client_mod_message()
			end }})

		TheFrontEnd:PushScreen( client_mod_msg )
	else
		after_client_mod_message()
	end

end
--★★★ JoinServer 结束（146 行）。★★★ 流程编排的完整回顾（见 :498 的流程图）：
--   ① client_mods_disabled 检查（:628）→ 只有本地有客户端模组才警告
--   ② mods_enabled 检查（:558）→ 「所有客户端需要模组」警告（4 条件）
--   ③ 密码输入（:518）→ 已记住密码则跳过
--   ④ send_response → TheNet:JoinServerResponse → 连接 + DisableAllDLC
--   ★★ 设计要点：
--     · ★★ 「先本地确认，再发起连接」—— 取消不浪费网络请求；
--     · ★★ 「先模组后密码」—— 模组警告是本地决策，密码验证是服务端；
--     · ★★ 不 IsMigrating() 时不弹窗（迁移要重启进程）；
--     · ★★ 用户选择被保存到 Profile（不重复打扰）。
--【机制：加入服务器编排】JoinServer（146 行，四层嵌套回调）。
--   ★★★ 流程：客户端模组警告 → 服务端模组警告 → 密码 → 连接。
--   ★★ 两条设计原则：
--     · ★★ 「先本地确认，再发起网络请求」—— 取消不浪费服务端资源；
--     · ★★ 「先模组后密码」—— 模组是本地决策，密码验证是服务端；
--   ★★ 两个 not IsMigrating() 守卫（:559/:629）—— 迁移要重启进程，弹窗无意义。
--   ★★ JoinServerResponse(false=开始/true=取消, guid, password)（:501/:510）——
--     ★ 一个接口 + 一个布尔 = 「确认/取消」二态协议；★ 只传 guid（列表已在网管）。
--   ★ DisableAllDLC() 在「发起」时而非「成功」后（:503）—— 关卡切换前必须就绪。

--★★★★★[MigrateToServer —— ★★★ 跨服务器迁移：★★ 为什么必须重启进程]
--   ★★★ 签名：MigrateToServer(serverIp, serverPort, serverPassword, serverNetId)
--   ★★★ 核心问题：为什么不 JoinServer（:498）那样直接连？
--   ★★★★ 推理（三条）：
--     ① ★★ 「一个进程一个世界」：TheWorld 是全局单例（prefabs/world.lua:422）；
--       ★★ 换服务器 = 换世界 —— ★★ 无法在同一 Lua 状态里安全替换 TheWorld；
--       ★★★ 若强行替换，全局的 Ents、事件监听、组件状态都会混乱。
--     ② ★★ 跨服务器时**玩家身份要重新建立**（新连接、新客户端表）；
--       ★★ 同一个进程里既有旧连接又有新连接 → 状态冲突。
--     ③ ★★ 最简单可靠：重启进程，一切干净。
--   ★★ 这就是为什么本文件有两套加入机制（JoinServer vs MigrateToServer）。
--   ★★ ★ 迁移的典型场景：分片集群的「从洞穴传回主分片」——
--     ★★ 那其实是「换一个分片服务器」，算作迁移。
--   ★★ 交叉参考：shardnetworking.lua:216 migration_portal 预制体。
function MigrateToServer(serverIp, serverPort, serverPassword, serverNetId)
--★★★[do_join_server 内部函数 —— ★ 真正执行迁移的地方]
--   local function do_join_server()
--       serverNetId = serverNetId or ""
--       StartNextInstance({
--           reset_action = RESET_ACTION.JOIN_SERVER,
--           serverIp = serverIp, serverPort = serverPort,
--           serverPassword = serverPassword, serverNetId = serverNetId,
--   ★★★ 三层设计：
--     ① do_join_server 是**回调**（第 659/667 行才调用）——
--       ★ 因为迁移前要先存档（:663），存档是异步/需要时机的。
--     ② StartNextInstance —— ★★ 「启动下一个实例」的引擎接口。
--       ★★ 与 :12 的 SpawnSecondInstance（os.execute）不同：
--         ★★★ 这是引擎提供的**正规**跨进程机制（非硬编码 exe 路径）。
--         ★★ ★ 推测它会：启动新进程 → 传入这些参数 → 当前进程退出。
--     ③ reset_action = RESET_ACTION.JOIN_SERVER —— ★★ 「重置动作」枚举：
--       ★★ 告诉新实例「启动后要做什么」：加服务器（vs 读档等）。
--       ★ 对照 :717 DoReset 用 RESET_ACTION.LOAD_SLOT（读存档）。
--       ★★ 两个 RESET_ACTION 对应两种「下次启动做什么」。
    local function do_join_server()
        serverNetId = serverNetId or ""

        StartNextInstance({
            reset_action = RESET_ACTION.JOIN_SERVER,
            serverIp = serverIp,
            serverPort = serverPort,
            serverPassword = serverPassword,
            serverNetId = serverNetId,
        })
    end

--★★★[第 659-668 行：★★ 迁移前存档 —— 「重大变化前先落盘」]
--   if InGamePlay() then
--       if ThePlayer ~= nil and TheWorld ~= nil and not TheWorld.ismastersim then
--           --Got here before player deactivation, so
--           --we will need to save local minimap now.
--           SerializeUserSession(ThePlayer)
--       do_join_server()
--   else
--       DoLoadingPortal(do_join_server)
--   ★★★ 三层判断：
--     ① ★★ InGamePlay() —— 「当前在游戏中吗」？
--       ★★ 推理：在菜单里迁移 vs 在世界里迁移，处理不同。
--     ② ★★★ 条件组合：ThePlayer 存在 且 TheWorld 存在 且 **not ismastersim**
--       ★★★ ★★ 最有意思的是「not ismastersim」——
--       ★★★ 推理：★ 注释说 "Got here before player deactivation" ——
--         ★★ 迁移请求在玩家「停用」之前就到了（ThePlayer 还存在）；
--         ★★ 但 ★ 只在「非主模拟端」（即客户端）才存档。
--       ★★★ 为什么客户端要存档 ThePlayer？
--         ★★ 因为客户端上可能有**本地状态**（小地图探索数据等）
--           ★★★ 这些数据只存在客户端（不与世界同步）——
--           ★★ 迁移（重启进程）会丢失 → 必须先存。
--         ★★★ 这就是原注释说的 "we will need to save local minimap now"。
--       ★★ ★ 若在服务端（ismastersim），玩家数据由服务端统一存，不需本地存。
--       ★★★ 双重条件（ThePlayer and TheWorld and not ismastersim）确保：
--         客户端 + 有玩家实体 → 才存档。
--     ③ ★★ DoLoadingPortal(do_join_server) —— ★ 「加载遮罩」：
--       ★★ 迁移是异步的（要等存档完成），需要一个过渡界面。
--       ★★ DoLoadingPortal 显示加载界面，回调里执行 do_join_server。
--       ★★ 这是「异步操作必须有 UI 反馈」的实践。
    if InGamePlay() then
        if ThePlayer ~= nil and TheWorld ~= nil and not TheWorld.ismastersim then
            --Got here before player deactivation, so
            --we will need to save local minimap now.
            SerializeUserSession(ThePlayer)
        end
        do_join_server()
    else
        DoLoadingPortal(do_join_server)
    end
end
--★★★ MigrateToServer 结束（24 行）。★★ 与 JoinServer 的核心区别：
--   · JoinServer —— 同进程内换世界（客户端切服务器，不重启）；
--   · ★ MigrateToServer —— ★★ 重启进程换世界（因为跨服务器无法在同一 TheWorld 内切换）。
--   ★★ 「一个进程一个世界」（prefabs/world.lua:422）是这个区别的根本原因。
--   ★★ 跨进程机制有两个：SpawnSecondInstance(:12, os.execute 硬编码路径)
--     与 StartNextInstance(:650, 引擎正规接口) —— ★ 推荐后者。
--【机制：跨服务器迁移】MigrateToServer（24 行）。
--   ★★★★ 为什么必须重启进程（三条推理）：
--     ① ★★ 一进程一世界（TheWorld 全局单例，prefabs/world.lua:422）；
--     ② 跨服务器需重建玩家身份（旧新连接状态冲突）；
--     ③ ★★ 最简单可靠：重启即净。
--   ★ 迁移前存档（:663）只对客户端做 —— ★★ 因为本地小地图数据只存在客户端，
--     ★★ 重启会丢；服务端存档由服务端统一管理（故用 not ismastersim 守卫）。
--   ★ StartNextInstance(:650) 是引擎正规接口（优于 :12 的 os.execute 硬编码路径）。
--★★ 参见 prefabs/world.lua:422（TheWorld 全局单例赋值 —— 迁移必须重启的根因）；
--   ★★ 参见 prefabs/world.lua:417（重复世界检查，本文件重启策略的对照面）；
--   ★★ 参见 prefabs/world.lua:543（focalpoint 的创建/销毁对称断言）。

--★★★[GetAvailablePlayerColours —— ★★ 玩家颜色的分配策略（★ 与 UI 资源联动）]
--   ★★★ 第 672-681 行的注释块（★ 罕见的完整设计说明）：
--     · 返回一个**有序**的颜色列表 + 一个默认色；
--     · ★★ 默认色**不在列表里**（只在数据缺失/出错时用）；
--     · ★★ 颜色按**加入顺序**分配 —— 模组可预随机化这个列表；
--     · ★★ 若玩家在同一服务器的同一 session 回来，会拿到上次的颜色
--       （若没被别人占用）。
--   ★★★ 「按加入顺序分配」的设计后果：
--     · ★★ 前 N 个进服的玩家固定拿前 N 个颜色；
--     · ★★ 这不是随机的 → 可能「同一个房间总看到同样的角色颜色」；
--       ★ 但换来了**可预测性**（队友能互相认出）。
--   ★★ 「session 内保留颜色」：靠服务器记录（存档/服务端内存）。
--   ★★ 模组预随机化 = 直接打乱这个有序列表（shuffle）。
--   ★★ ★ 交叉引用（★ 见 prefabs/world.lua:10-25 的资源注记）：
--     ★★ prefabs/world.lua 声明了 images/names_random.xml 等图集，
--       ★★ 那些图集正是「给每个颜色配套的随机名字文本图」——
--       ★★ 即「颜色 + 名字」的配对呈现。
--   ★★ 这是本文件与 world.lua 的一个交叉呼应点。
function GetAvailablePlayerColours()
    -- -Return an ordered list of player colours, and a default colour.
    --
    -- -Default colour should not be in the list, and it is only used
    --  when data is not available yet or in case of errors.
    --
    -- -Colours are assigned in order as players join, so modders can
    --  prerandomize this list if they want random assignments.
    --
    -- -Players will be reassigned their previous colour on a server if
    --  it hasn't been used, and the server is in the same session.

--★★[第 683 行原注释 "Using a better colour theme to match world tones"]
--   ★★★ 说明选色标准：★ 与游戏世界色调协调（不是纯随机）。
--   ★★ 24 个颜色（第 686-709 行）：从 TOMATO（番茄红）到 THISTLE（蓟紫）。
--   ★★ 命名全是大写颜色常量（PLAYERCOLOURS.TOMATO 等）。
--   ★★ 第 712 行的 return colours, DEFAULT_PLAYER_COLOUR
--     ★★ 返回「列表 + 默认色」—— 两个返回值。
--     ★ 与第 672-675 行的注释呼应（默认色单独给）。
--   ★★ 第 711 行的 TODO："forward to a mod function before returning?"
--     ★★ 又是「预留模组钩子」的痕迹 —— ★ 想加但没加。
--     ★ 反映出「模组可扩展」是贯穿全项目的追求。
    --Using a better colour theme to match world tones
--★★★[第 684-712 行：★★ 24 个玩家颜色的具体列表]
--   ★★★ 颜色的组织（★ 按色系分组，★ 值得注意的细节）：
--     · 红色系：TOMATO, RED, PERU, FIREBRICK, INDIANRED(推测)
--     · 棕色系：TAN, BURLYWOOD, CHOCOLATE, BROWN, BISQUE
--     · 紫色系：PLUM, DARKPLUM, VIOLETRED, MEDIUMPURPLE, THISTLE
--     · 浅色系：EGGSHELL, SALMON, ROSYBROWN, LIGHTTHISTLE, PINK
--     · 黄色系：LEMON, GOLDENROD, SANDYBROWN, LIGHTGOLD, LIGHTGOLDENRODYELLOW(推测)
--     · 紫色系：PALEVIOLETRED, LIGHTTHISTLE
--   ★★★ ★★ 顺序安排的意义（★ 关键推理）：
--     ★★ 玩家按加入顺序拿颜色（见 :677 注释），
--       ★★ 所以「列表前面的颜色」= 「先到的玩家」拿到的颜色。
--       ★★★ 作者故意把**饱和度高、区分度大**的颜色排在前面（TOMATO, TAN, PLUM...）
--         ★★ 这样「先到的几个玩家」颜色最醒目、最好辨认。
--       ★★★ 这是一个「按分配优先级排序的设计」—— ★ 非字典序，是精心排的。
--   ★★★ PLAYERCOLOURS.X 是颜色常量（★ 定义在别处，★ 推测是预烘焙的纹理文件）。
--     ★ 这些颜色最终要变成玩家角色的**贴图/材质色**。
--   ★★★ 整体：★ 24 个颜色覆盖各种色系，保证多人（最多 8 人）时颜色不撞。
--     ★★ 24 > 8（最大玩家数）—— 足够分配且有余量。
    local colours =
    {
        PLAYERCOLOURS.TOMATO,
        PLAYERCOLOURS.TAN,
        PLAYERCOLOURS.PLUM,
        PLAYERCOLOURS.BURLYWOOD,
        PLAYERCOLOURS.RED,
--★★[第 691-711 行：颜色列表的中段]
--   ★★★ 中段颜色（BURLYWOOD, RED, PERU, DARKPLUM, EGGSHELL, SALMON,
--     CHOCOLATE, VIOLETRED, SANDYBROWN, BROWN, BISQUE, PALEVIOLETRED,
--     GOLDENROD, ROSYBROWN, LIGHTTHISTLE, PINK, LEMON, FIREBRICK,
--     LIGHTGOLD, MEDIUMPURPLE, THISTLE)
--   ★★ 注意颜色名都是标准 CSS/X11 命名（TOMATO, BISQUE, THISTLE...）——
--     ★★ 这些是成熟的「公认色名」，保证跨平台一致的颜色。
--   ★★★ ★★ 排列观察：★ 没有明显的色系分组，★ 看起来像「按视觉区分度排列」：
--     · 相邻的颜色刻意**不同色系**（避免两人相邻拿到的颜色接近）；
--       ★★ 例如 TOMATO(红) → TAN(米) → PLUM(紫) → BURLYWOOD(棕) → RED(红)
--         ★★★ 注意 TOMATO 和 RED 都偏红但相隔 4 位。
--     · ★★ 这是「抗撞色」设计：★ 最大化前 8 色的相互区分度。
--   ★★★★ 移植启示：★ 如果移植到自定义引擎，
--     ★★ 不要简单地随机取色或按字母排序——
--     ★★ 应该保留「相邻颜色不同系 + 饱和度递变」的排序逻辑。
--     ★★★ 这一条注释记录了原版的设计意图，避免后来者「优化」成字典序。
        PLAYERCOLOURS.PERU,
        PLAYERCOLOURS.DARKPLUM,
        PLAYERCOLOURS.EGGSHELL,
        PLAYERCOLOURS.SALMON,
        PLAYERCOLOURS.CHOCOLATE,
        PLAYERCOLOURS.VIOLETRED,
        PLAYERCOLOURS.SANDYBROWN,
        PLAYERCOLOURS.BROWN,
        PLAYERCOLOURS.BISQUE,
        PLAYERCOLOURS.PALEVIOLETRED,
        PLAYERCOLOURS.GOLDENROD,
        PLAYERCOLOURS.ROSYBROWN,
        PLAYERCOLOURS.LIGHTTHISTLE,
        PLAYERCOLOURS.PINK,
        PLAYERCOLOURS.LEMON,
        PLAYERCOLOURS.FIREBRICK,
        PLAYERCOLOURS.LIGHTGOLD,
        PLAYERCOLOURS.MEDIUMPURPLE,
        PLAYERCOLOURS.THISTLE,
    }
    --TODO: forward to a mod function before returning?
    return colours, DEFAULT_PLAYER_COLOUR
--★★ GetAvailablePlayerColours 结束。★★ 24 色 + 默认色。
--   ★ ★★ 关键：★ 列表顺序即分配优先级（见 :684 与 :691 的分析）。
end
--★★ GetAvailablePlayerColours 结束。★★ 24 色 + 默认色。
--   ★★ 关键特性：有序（按加入顺序分配）、可被模组预随机化、session 内保持。
--【机制：玩家颜色分配】24 色有序表 + 默认色。
--   ★★ 三个设计点：
--     · ★ 有序分配（按加入顺序，:677 注释）；
--     · ★ 默认色不在列表内（只在数据缺失时用）；
--     · ★★ 列表顺序经过精心排布（:684/:691）—— ★ 相邻色不同色系、
--       ★★ 高区分度颜色靠前，★ 保证「先到的玩家颜色最醒目」。
--   ★ 模组可预随机化（shuffle）此列表（:711 TODO 预留钩子）。

--★★★[DoReset —— ★「读档重启」的最小实现]
--   ★★★ 只做一件事：StartNextInstance({ reset_action = RESET_ACTION.LOAD_SLOT, save_slot = ShardGameIndex:GetSlot() })
--   ★★★ 与 :647 do_join_server 的对比（同构，不同参数）：
--     · JOIN_SERVER：需要 serverIp/port/password/netId
--     · ★ LOAD_SLOT：★ 只需要 save_slot（★ 读本地存档）。
--   ★★ 「重载当前存档」= 重启进程 + LOAD_SLOT。
--   ★ 交叉参考：:722 WorldResetFromSim（重置世界）和 :733 WorldRollbackFromSim（回滚）。
local function DoReset()
    StartNextInstance({
        reset_action = RESET_ACTION.LOAD_SLOT,
        save_slot = ShardGameIndex:GetSlot()
    })
end

--★★★[WorldResetFromSim —— ★★ 「重置世界」（回到空白存档）]
--   ★★★ 第 723 行的守卫：`if TheWorld ~= nil and TheWorld.ismastersim then`
--     ★★ **只有主模拟端**才能重置世界（客户端不能）。
--     ★★ 这是服务端专用操作（★ 权限控制）。
--   ★★★ 三步（第 724-729 行）：
--     ① print("Received world reset request") —— 记录请求；
--     ② TheWorld:PushEvent("ms_worldreset") —— ★★ 广播世界重置事件；
--     ③ ShardGameIndex:Delete(DoReset, true) —— ★★ 删除存档并重启。
--   ★★★ 第 725 行的 ms_worldreset 事件：
--     ★★ 让世界里的系统（UI、清理逻辑）知道「世界要重置了」。
--     ★ ms_ 前缀 = 服务端世界事件（见 prefabs/world.lua:300 注记）。
--     ★★ 对比 DisableRPCSending（networkclientrpc.lua:1997）：
--       ★★ 重置时客户端会调 DisableRPCSending 冻结发送（客户端侧）。
--       ★★★ 这里（服务端侧）广播 ms_worldreset → 通知客户端准备。
--       ★★★ 两个文件的配合 = 重置流程的跨端协议。
--   ★★★ 第 726-729 行：ShardGameIndex:Delete(回调, true)
--     · 第一个参数 DoReset —— ★★ 删除完成后调它（重启去读档）；
--     · ★★ 第二个参数 true —— ★★ 原注释 "true causes world gen options to be preserved"：
--       ★★★ 「保留世界生成选项」！这是关键的语义：
--       ★★ 重置世界 = 清空地图内容，但**保留生成配置**（季节/世界设置等）；
--         ★★★ 即「用同样的设置重新生成一个新世界」。
--         ★★ 这是「保设置、重内容」的语义，区别于「彻底删档」。
function WorldResetFromSim()
    if TheWorld ~= nil and TheWorld.ismastersim then
        print("Received world reset request")
        TheWorld:PushEvent("ms_worldreset")
        ShardGameIndex:Delete(
            DoReset,
            true -- true causes world gen options to be preserved
        )
    end
end
--★★ WorldResetFromSim 结束。重置 = 删存档 + 重启读档（保留世界生成设置）。
--   ★ 与 :715 DoReset 的区别：★ DoReset 是「读档重启」，
--     ★ 而这里是「删档后读档重启」（Delete 的回调里调 DoReset 逻辑）。
--   ★ 两个「重置」概念：
--     · WorldReset（:722）—— 清空世界内容，保留生成设置；
--     · ★ DoReset（:715）—— 只是重启去读档（存档不变）。

--★★★★★[WorldRollbackFromSim —— ★★★ 存档回滚（★ 本文件最精妙的逻辑）]
--   ★★★ 第 734 行守卫：`if TheWorld ~= nil and TheWorld.ismastershard then`
--     ★★★ 注意是 **ismastershard**（不是 ismastersim）—— ★★ 比 :723 更严格！
--     ★★★ 推理：★ 回滚涉及**跨分片数据**（多个存档快照），
--       ★★ 必须由主分片统一执行（分片集群里只有主分片管全局存档）。
--       ★★ 语义：只有主分片能做跨存档回滚。
--   ★★★★ 第 736-741 行：★★ 回滚步数的「自动调整」—— 本函数的核心]
--     if count > 0 then
--         if TheWorld.net == nil or
--             TheWorld.net.components.autosaver == nil or
--             GetTime() - TheWorld.net.components.autosaver:GetLastSaveTime() < 30 then
--             count = count + 1
--   ★★★ 原注释的逻辑（第 737-739 行条件）：
--     「如果距离上次自动存档不到 30 秒，就把回滚步数 +1」
--   ★★★★ 为什么？★★ 这是本函数最值得理解的设计：
--     ★★ 场景：管理员执行「回滚 1 步」（count=1），期望回到「上一个存档点」；
--     ★★★ 但若刚刚（<30 秒）刚自动存档过：
--       · ★ 「上一个存档点」可能就是「刚刚那个」（因为它太新了）；
--       · ★★ 若真回滚到它，玩家感觉「什么都没变」；
--       · ★★★ 正确的做法：★ 再往前多退一步，跳过这个「刚保存的点」。
--     ★★★★ 三个 or 条件的意图：
--       · TheWorld.net == nil —— 没有网络层（单机）→ +1；
--       · autosaver 组件不存在 → 不知道上次存档时间 → +1；
--       · ★★ 距上次存档 < 30 秒 → 「那个点太新」→ +1。
--     ★★ 为什么是 30 秒？（★ 经验值）
--       · 一个合理的「太新」窗口（玩家刚存完就回滚等于没回滚）。
--     ★★ 这是一个「用户体验修正」：★ 让「回滚 1 步」真的回滚一步。
--   ★★★ 第 742 行：TheNet:TruncateSnapshots(TheWorld.meta.session_identifier, -count)
--     ★★★ 三个参数：session_identifier（当前会话）、★ 负数 count（保留最近 N 个，截断其余）、
--       ★★ 即「回滚 count 个存档快照」。
--   ★★★ 第 744 行 DoReset() —— ★★★ 回滚后必须重启（读档才能生效）。
--     ★★ 顺序：截断快照 → 重启 → 读被截断后的存档。
--     ★★★ 与 :722 的 Delete(DoReset, true) 同构（★ 截断/删除 + 重启）。
--   ★★ 交叉参考：net.lua 的 autosaver 组件（自动存档，管理 GetLastSaveTime）。
--   ★★ 这就是网络侧 RPC 回滚与引擎层实体状态回滚的完整链路（★ 服务器本地回滚，非云端）。
function WorldRollbackFromSim(count)
    if TheWorld ~= nil and TheWorld.ismastershard then
        print("Received world rollback request: count="..tostring(count))
        if count > 0 then
            if TheWorld.net == nil or
                TheWorld.net.components.autosaver == nil or
                GetTime() - TheWorld.net.components.autosaver:GetLastSaveTime() < 30 then
                count = count + 1
            end
            TheNet:TruncateSnapshots(TheWorld.meta.session_identifier, -count)
        end
        DoReset()
    end
end
--★★★ WorldRollbackFromSim 结束（14 行）。★★ 本函数的核心是两个「修正」：
--   ① ★★ 时序：ismastershard（比 ismastersim 严格，因为涉及跨分片快照）。
--   ② ★★ 步数修正：若 30 秒内刚自动存档过，count +1（见 :736 的详解）。
--     ★★ 这两个修正让它成为「真正可用」的回滚 —— 而非机械地回退 N 个快照。
--   ★★ 完整流程：修正步数 → TruncateSnapshots → DoReset 重启读档。
--   ★ 交叉参考：net.lua 的 autosaver 组件（GetLastSaveTime）。
--【机制：存档回滚的两个修正】WorldRollbackFromSim。
--   ★★ ismastershard（比 ismastersim 严格）—— 回滚涉及跨分片快照，只主分片能做。
--   ★★ 步数修正（:736-741）：距上次自动存档 < 30 秒则 count+1，
--     ★★★ 理由：刚存的那个点「太新」，真回滚到它玩家会以为没回滚。
--   ★★ 「从数据布局约束推导权限」的典范（UnplugModule :1336 的同类手法）。
--★★ 参见 prefabs/world_network.lua:52-61（autosaver / clock / seasons 等 7 个组件的注册处 ——
--   ★★ ★ 注意它们挂在 TheWorld.net 上，不在 TheWorld 本体，见 prefabs/world.lua 文件头注记）。

--★★★[UpdateServerTagsString —— ★★ 服务器标签的生成（★ 有已知的重复实现）]
--   ★★★ 原注释（第 749-750 行）：
--     "--V2C: ughh... well at least try to keep this in sync with
--      servercreationscreen.lua BuildTagsStringHosting()"
--   ★★★★ 「ughh...」—— ★★★ 作者的自嘲，★ 但信息极重要：
--     ★★ ★ 这个函数与 servercreationscreen.lua 的 BuildTagsStringHosting()
--       ★★ 是**重复实现**（两处算同一批标签）。
--     ★★ 必须「尽量保持同步」—— 意思是「很容易不同步」。
--   ★★★ 为什么是重复实现（推理）？
--     · 「创建服务器界面」（UI 侧）与「实际生成标签」（运行时侧）都需要它；
--     · ★★ 但两者在不同文件/不同上下文，且显示的是「预设列表」vs「实际生效」。
--     · ★★ 这是历史遗留的技术债（★ 移植时应合并为一个函数）。
--   ★★★ 函数体（:752-781）：
--     逐个检查游戏设置（pvp / friends_only / lan_only / clan），
--     每个为真就往 tagsTable 加一个字符串；
--     最后 TheNet:SetServerTags(BuildTagsStringCommon(tagsTable))。
--   ★★★ 第 775 行的特殊处理：世界生成位置（location）：
--     local locationtag = STRINGS.TAGS.LOCATION[string.upper(worlddata.location)]
--     ★★ 把 location 转大写后查表 —— 枚举规范化的常规做法。
--   ★★★ 第 781 行：BuildTagsStringCommon(tagsTable) —— 把数组拼成字符串。
--     ★★ 由 C++ 或工具函数提供（推测用逗号分隔）。
--     ★ 交给 TheNet:SetServerTags —— C++ 广播给服务器列表。
function UpdateServerTagsString()
    --V2C: ughh... well at least try to keep this in sync with
    --     servercreationscreen.lua BuildTagsStringHosting()

    local tagsTable = {}

    table.insert(tagsTable, GetGameModeTag(TheNet:GetDefaultGameMode()))

--★★[第 756-770 行：四个游戏设置的标签注入]
--   · TheNet:GetDefaultPvpSetting()      → STRINGS.TAGS.PVP
--   · TheNet:GetDefaultFriendsOnlyServer() → STRINGS.TAGS.FRIENDSONLY
--   · TheNet:GetDefaultLANOnlyServer()     → STRINGS.TAGS.LOCAL
--   · ★★ TheNet:GetDefaultClanID() ~= ""  → STRINGS.TAGS.CLAN
--   ★★ 注意 clan 的判断是「ID 非空」而非布尔 —— ★ 因为「是否 clan 限定」
--     ★★★ 由「有没有 clan ID」决定（★ 与 :838 的 GetDefaultClanOnly 形成对比）。
--   ★★★ 全部用 GetDefaultXxx 系列 —— ★ 「默认值」而非当前值。
--     ★★★ 推理：★ 这是**服务器预设**（开服时定的），不是运行时可变。
--       ★ 与 :817 GetDefaultServerData 呼应（那些设置被存进存档）。
    if TheNet:GetDefaultPvpSetting() then
        table.insert(tagsTable, STRINGS.TAGS.PVP)
    end

    if TheNet:GetDefaultFriendsOnlyServer() then
        table.insert(tagsTable, STRINGS.TAGS.FRIENDSONLY)
    end

    if TheNet:GetDefaultLANOnlyServer() then
        table.insert(tagsTable, STRINGS.TAGS.LOCAL)
    end

    if TheNet:GetDefaultClanID() ~= "" then
        table.insert(tagsTable, STRINGS.TAGS.CLAN)
    end

--★★[第 772-779 行：世界生成元数据（★ location 标签）]
--   local worldoptions = ShardGameIndex:GetGenOptions()
--   ★★★ ShardGameIndex 是「存档索引」—— 存储当前世界的生成配置。
--     ★★ 「生成配置」= 世界长什么样（季节、地形、生物群系）。
--     ★★ 与 :786 的 deepcopy(ShardGameIndex:GetGenOptions()) 同源。
--   ★★★ ★★ 注意第 773 行：local worlddata = worldoptions or nil
--     ★★ 这个 `or nil` 是**无意义的**（如果 worldoptions 为 nil，or nil 还是 nil）。
--       ★ 它像是一个「防 nil 的习惯」或「原代码可能是 worldoptions or something」。
--       ★★ 低危但暗示代码演进。仅标注，不改。
--   ★★★ 第 774-778 行：
--     if worlddata ~= nil and worlddata.location ~= nil then
--         local locationtag = STRINGS.TAGS.LOCATION[string.upper(worlddata.location)]
--         if locationtag ~= nil then table.insert(tagsTable, locationtag) end
--   ★★★ 三层：worlddata 存在 → location 存在 → 标签查得到。
--     ★★ 每一层都判空 → ★ 防御性良好。
--     ★★ string.upper 规范化（★ 枚举存储规范）。
    local worldoptions = ShardGameIndex:GetGenOptions()
    local worlddata = worldoptions or nil
    if worlddata ~= nil and worlddata.location ~= nil then
        local locationtag = STRINGS.TAGS.LOCATION[string.upper(worlddata.location)]
        if locationtag ~= nil then
            table.insert(tagsTable, locationtag)
        end
    end

--★ TheNet:SetServerTags(...) —— 提交标签（广播给服务器列表）。
--   ★★★ 「服务器标签」= 服务器列表界面显示的分类标签（PVP/好友限定等）。
--   ★★ 这个函数需要与 prefabs/world.lua:602 的 UpdateServerWorldGenDataString
--     以及本文件 :789 的 GetAvailablePlayerColours 一起理解（都是「对外元数据」）。
    TheNet:SetServerTags(BuildTagsStringCommon(tagsTable))
end
--★ UpdateServerTagsString 结束。★ 输出的是「分类标签」而非世界数据（:784 管后者）。
--   ★ ★★ 源码自承：与 servercreationscreen.lua 的 BuildTagsStringHosting() 重复实现。

--★★★[UpdateServerWorldGenDataString —— ★★ 世界生成元数据的广播（★ 多分片合并）]
--   ★★★ 与 :748 的区别（★ 两个函数管两类元数据）：
--     · :748 UpdateServerTagsString      —— 「分类标签」（PVP/好友等）
--     · ★ :784 UpdateServerWorldGenDataString —— 「世界生成数据」（季节/地形等）
--   ★★★★ 函数体（:785-814）：
--     ① :785-787 收集本分片的生成数据（clusteroptions 数组）；
--     ② :789-796 ★★ 若本分片是主分片，合并所有次分片的数据；
--     ③ :798-811 压缩/裁剪各分片的 overrides；
--     ④ :814 ★ 打包广播。
--   ★★★ 第 789 行的守卫：`if TheShard:IsMaster() then` —— ★★ 只有主分片才合并！
--     ★★★ 推理：★ 只有主分片「知道」所有分片（其他分片只知道自己）。
--       ★★ 次分片只广播自己的数据（不合并）。
--     ★★ 这与 prefabs/world.lua:601 的原注释呼应：
--       "Also updated in shardnetworking.lua for multilevel server clusters"
--   ★★★ 这个「主分片汇总全集群元数据」的模式（★ 重要架构）：
--     · 服务器列表需要一个**统一视图**（「这个集群的世界是什么样的」）；
--     · ★★ 而信息分散在各分片 → 主分片收集并汇总。
--     ★ 与 shardnetworking.lua 的分片互联配合。
function UpdateServerWorldGenDataString()
    local clusteroptions = {}
--★★[第 786 行：deepcopy(ShardGameIndex:GetGenOptions()) —— ★★ 必须深拷贝！]
--   local worldoptions = deepcopy(ShardGameIndex:GetGenOptions())
--   ★★★ 为什么必须深拷贝（★ 关键）：
--     · 第 800-810 行**会修改** world.overrides（`world.overrides[option] = nil`）；
--     · ★★ 若不拷贝，★ 这些修改会污染 ShardGameIndex 的真实配置！
--       ★★★ 即「裁剪未使用的 overrides」会**永久删除**存档里的设置。
--     · ★★ 这是本函数最容易出错的地方 —— 拷贝是正确性保障。
--   ★ deepcopy 是本文件唯一的深拷贝调用（对比 :798 的 require("map/customize")）。
    local worldoptions = deepcopy(ShardGameIndex:GetGenOptions())
    table.insert(clusteroptions, worldoptions or {})

    if TheShard:IsMaster() then
        -- Merge secondary shard worldgen data
--★★★[第 791-796 行：★★ 合并次分片的世界生成数据]
--   for k, v in pairs(Shard_GetConnectedShards()) do
--       if v.world ~= nil and v.world[1] ~= nil then
--           table.insert(clusteroptions, v.world[1])
--   ★★★★ 三层防护：
--     ① ★★ Shard_GetConnectedShards() —— ★ 返回**深拷贝**的连接表（shardnetworking.lua:146）。
--       ★★★ 关键：★ 用拷贝返回值 → 修改它不会影响真实的分片状态。
--     ② v.world ~= nil —— 有世界数据；
--     ③ ★★ v.world[1] ~= nil —— ★★ 取「数组第一个元素」。
--       ★★★★ 为什么是 [1]？推理：
--       ★ shardnetworking.lua:74-88 里，world_data 经过沙箱解码后是一个表，
--       ★★ 其「唯一键是 str」（第 82-83 行检查 count==1），
--       ★★ 之后 world_data = 解码结果（第 88 行）—— 是一个「复数数组」？
--       ★★ 结合 shardnetworking.lua:792 的 `v.world[1] ~= nil`，
--         ★★ 可以确定：★ world_data 解码后是「以版本号等为键的表」，
--           ★★ [1] 取的是「第一项」（可能是「版本 1 的数据」或「主配置」）。
--       ★★★ 推断：world_data 是个「多版本配置列表」（前向兼容设计）。
--       ★ 取 [1] 是「取当前生效的版本」。
--   ★★★ 交叉参考：shardnetworking.lua:73-91（world_data 的沙箱解码）。
        for k, v in pairs(Shard_GetConnectedShards()) do
            if v.world ~= nil and v.world[1] ~= nil then
                table.insert(clusteroptions, v.world[1])
            end
        end
    end

--★★[第 798 行：require("map/customize") —— ★★ 运行时 require（函数内）]
--   local Customize = require"map/customize"
--   ★★★ 为什么在函数内 require（而非文件顶部）？
--     推理：★ map/customize 可能很重（世界自定义选项的完整定义），
--       ★★ 而本函数并非每次都调用（仅服务器启动/重置时）。
--       ★★ 延迟加载 → 节省启动时间。
--     ★★ 对比 :1-6 的顶部 require（UI 依赖，那个必须要）。
--   ★★★ ★ 这也与 shardnetworking.lua:1 的 Customize = require("map/customize") 对应
--     ★★★ —— 同一模块，两处加载（一个在顶部、一个在函数内）。
--     ★★ shardnetworking.lua 在顶部 require（因为 Shard_SyncWorldSettings 常用），
--       ★ networking.lua 在函数内（因为只在特定时机用）。
    local Customize = require"map/customize"
    for i,world in ipairs(clusteroptions) do
--★★★★[第 800-811 行：★★ 元数据的裁剪（★ 「广播前瘦身」）]
--   for i,world in ipairs(clusteroptions) do
--       if world.overrides == nil then
--           -- gjans: I'm not sure how we got this far without crashing,
--           -- but this isn't the right time to crash.
--           world.overrides = {}
--       else
--           for option,value in pairs(world.overrides) do
--               -- we can aggressively prune these for network purposes, as
--               -- the only use after this is the server info screen.
--               if value == "default" or not Customize.ValidateOption(option, value, world.location) then
--                   world.overrides[option] = nil
--   ★★★★ 这段代码处理两件事，都是「在 nil 上操作会崩」的防御：
--     ① world.overrides 为 nil 时初始化为 {} ——
--       ★★ 原注释：「gjans: I'm not sure how we got this here without crashing,
--       but this isn't the right time to crash」；
--       ★★★ 即「不确定为什么会到这里，但此刻不能崩」。
--       ★★ 这是「防御到作者自己都觉得奇怪」的程度 —— ★ 说明数据源有不确定性。
--     ② ★★ 裁剪无效的 overrides（两个条件）：
--       · ★ value == "default" —— ★ 是默认值就不广播；
--         ★★ 推理：★ 「默认」的值不需要传（接收方自己会用默认）。
--         ★★ 大量默认值会造成带宽浪费（每个 option 一项）。
--       · ★ Customize.ValidateOption(option, value, location) 为假 ——
--         ★★ 无效的设置不广播（可能来自旧版本/损坏的存档）。
--     ★★★ 原注释（第 805 行）："we can aggressively prune these for network
--       purposes, as the only use after this is the server info screen."
--       ★★★ 关键：「这个数据之后唯一的用途是服务器信息界面」——
--       ★★ 所以「放心大胆地裁剪」（aggressively prune）。
--       ★★ 裁剪的依据：★ 服务器列表不需要精确的生成配置，只需「大致的描述」。
--   ★★★ 这是一个「元数据瘦身」的标准实践：★ 广播前删掉一切非必需项。
        if world.overrides == nil then
            -- gjans: I'm not sure how we got this far without crashing, but this isn't the right time to crash.
            world.overrides = {}
        else
            for option,value in pairs(world.overrides) do
                -- we can aggressively prune these for network purposes, as the only use after this is the server info screen.
                if value == "default" or not Customize.ValidateOption(option, value, world.location) then
                    world.overrides[option] = nil
                end
            end
        end
    end

--★★★[第 813 行：★★ 源码自承的技术债]
--   "--V2C: TODO: Likely to exceed data size limit with custom multilevel worlds"
--   ★★★ 「自定义多层世界时，很可能超出数据大小限制」。
--   ★★★ 这是对第 814 行行为的预判（**已知问题**）：
--     · :814 把 clusteroptions（所有分片的配置）打包压缩后广播；
--     · ★★ 分片越多、每个世界的 overrides 越多 → 数据越大；
--     · ★★ 超过某个数据大小限制（网络层上限）→ ★ 广播失败或截断。
--   ★★★ 认识到的解决方向（未实现）：
--     ★· 分批广播（每个分片一条消息）；
--     ★· 进一步压缩（当前已 ZipAndEncodeSaveData）；
--     ★· 只广播「与默认值不同的项」（当前已部分裁剪）。
--   ★★ 这是本文件「明确记录的已知限制」。
--   ★ 与 :790 的 TODO（modinfo_name）和 :107 的 TODO（V2C 遥测未接）
--     并列构成本文件的「技术债清单」。
    --V2C: TODO: Likely to exceed data size limit with custom multilevel worlds
--★★★[第 814 行：★ 世界生成元数据的最终广播]
--   TheNet:SetWorldGenData(DataDumper(ZipAndEncodeSaveData(clusteroptions), nil, true))
--   ★★★★ 三层序列化（★ 注意每层的含义）：
--     ① ZipAndEncodeSaveData(clusteroptions) —— ★★ 压缩 + 编码：
--       · Zip（压缩）—— 数据量大，压缩节省带宽；
--       · ★ Encode（编码）—— 安全/序列化（与 DataDumper 配合）。
--       ★★ 与 :329 的 ENCODE_SAVES 呼应（同一种编码）。
--     ② DataDumper(..., nil, true) —— ★ 序列化（第三参数 true = 含引用）：
--       ★★ 注意这里恒为 true（含引用），与 :307 的按分支决定不同。
--       ★★ 推理：★ 这不是存档，是「广播给未知客户端的元数据」；
--         ★★ 含引用版本对客户端更友好（解压即得完整数据）。
--       ★ ★ 这里的选择反映了「广播数据 vs 存档数据」的差异（:307 注记的呼应）。
--     ③ TheNet:SetWorldGenData —— C++ 广播。
--   ★★★ 与 :325 SetGameData（DoGameDataChanged）的对比：
--     · :325 —— 日常游戏状态（日期/季节），轻量，频繁；
--     · ★ :814 —— 世界生成配置，重，稀疏（启动/重置时）。
--     ★★ 不同频率、不同量级 → 不同策略（一个 DataDumper，一个 Zip+DataDumper）。
    TheNet:SetWorldGenData(DataDumper(ZipAndEncodeSaveData(clusteroptions), nil, true))
end
--★★★ UpdateServerWorldGenDataString 结束（32 行）。★★ 核心机制：
--   · ★★ 主分片汇总全集群（:789-796）——只有主分片知道所有分片；
--   · ★★ 深拷贝防污染（:786）——因后面会修改 overrides；
--   · ★★ 广播前裁剪（:800-811）——「只有服务器信息界面用」，放心大胆删；
--   · ★★ Zip + DataDumper 双重序列化（:814）；
--   · ★★ 已知限制（:813）：自定义多层世界可能超数据大小限制。
--【机制：集群元数据汇总】UpdateServerWorldGenDataString。
--   ★★ 三层防护：
--     · ★★ deepcopy（:786）—— 因随后会改 overrides（★ 不拷贝会污染存档配置）；
--     · ★★ Shard_GetConnectedShards()（:791）返回深拷贝 —— 同样是防污染；
--     · ★★ 广播前裁剪（:800-811）—— 「之后唯一用途是服务器信息界面」，放心删。
--   ★★ 只有主分片合并全集群（:789）—— ★ 次分片不知道别人。
--   ★★ 已知限制（:813 自承）：自定义多层世界可能超数据大小限制。
--   ★★ 交叉引用：shardnetworking.lua:119-120 —— 分片增删后必须重新上报。
--★★ 参见 prefabs/world.lua:600-602（同款调用的单世界版本）；
--   ★★ 参见 shardnetworking.lua:119-120（分片增删后重新上报的触发点）。

--★★★[GetDefaultServerData —— ★★ 开服参数的一次性快照]
--   ★★★ 用途：★ 把当前服务器设置「打包」成一张表，存进存档。
--     ★★ 为什么存进存档？
--       ★★ 因为服务器设置（如 pvp、max_players、隐私类型）需要在
--         ★★ 客户端加载/进服时读取（不只是开服时用）。
--       ★★ 所以「开服时快照一次，之后从存档读」—— 而不是每次实时查询。
--   ★★★ 第 818-821 行的重要注释：
--     "--V2C: Note for online_mode: As long as StartServer/StartDedicatedServers
--      has been called before this, then TheNet:IsOnlineMode() should return
--      the desired value."
--   ★★★ 这条注释揭示了 ★★★ 一个重要的时序约束：
--     · IsOnlineMode() 的值依赖「StartServer 已被调用」；
--     · ★★ 若在 StartServer 之前调用 GetDefaultServerData，
--       ★★ GetDefaultServerData(:827) 会返回**错误**的 online_mode。
--     ★★★ 这就是 :849 StartDedicatedServer 的调用顺序（:860）敏感的原因。
--   ★★★ 返回值是一张表（:822-846），字段分三组：
--     · 基本设置（pvp/game_mode/playstyle/online_mode/encode_user_path/...）
--     · ★ 隐私设置（privacy_type = friends/local/clan/public —— 组合判断）
--     · ★★ clan 子表（id/only/admin）
--   ★★ privacy_type 是「四选一」的组合逻辑（:835-839）：
--     (GetDefaultFriendsOnlyServer() and FRIENDS) or
--     (GetDefaultLANOnlyServer() and LOCAL) or
--     (GetDefaultClanOnly() and CLAN) or PUBLIC
--     ★★ 注意 GetDefaultClanOnly()（bool）vs :768 的 GetDefaultClanID() ~= ""。
--       ★ 二者是不同概念：「是否 clan 限定」vs「clan 的 ID」。
--       ★ privacy_type 用前者（语义），:768 的标签用后者（有无 clan）。
--   ★★★ 第 829 行 use_legacy_session_path = nil —— 固定置 nil（向后兼容标记）：
--     ★ 推断：旧版存档路径格式的标记；新版恒为 nil（用新路径）。
function GetDefaultServerData()
    --V2C: Note for online_mode:
    --     As long as StartServer/StartDedicatedServers has been
    --     called before this, then TheNet:IsOnlineMode() should
    --     return the desired value.
    return
    {
        pvp = TheNet:GetDefaultPvpSetting(),
        game_mode = TheNet:GetDefaultGameMode(),
		playstyle = TheNet:GetServerPlaystyle(),
        online_mode = TheNet:IsOnlineMode(),
        encode_user_path = TheNet:GetDefaultEncodeUserPath(),
        use_legacy_session_path = nil,
        max_players = TheNet:GetDefaultMaxPlayers(),
        name = TheNet:GetDefaultServerName(),
        password = TheNet:GetDefaultServerPassword(),
        description = TheNet:GetDefaultServerDescription(),
        server_language = TheNet:GetDefaultServerLanguage(),
--★★[第 835-839 行：privacy_type 的四级优先级组合]
--   privacy_type =
--       (TheNet:GetDefaultFriendsOnlyServer() and PRIVACY_TYPE.FRIENDS) or
--       (TheNet:GetDefaultLANOnlyServer() and PRIVACY_TYPE.LOCAL) or
--       (TheNet:GetDefaultClanOnly() and PRIVACY_TYPE.CLAN) or
--       PRIVACY_TYPE.PUBLIC
--   ★★★★ 四个 or 串联 = 「按优先级选第一个为真的」：
--     优先级：FRIENDS > LOCAL > CLAN > PUBLIC。
--   ★★★ 为什么是 or 链（而不是多个独立字段）？
--     ★★ 因为隐私设置是**互斥的**（一个服务器只有一种隐私级别）。
--     ★★ 单一字段比「四个布尔」更简洁、更不易矛盾。
--   ★★★ 第 877 行读回这个值（slot_server_data.use_legacy_session_path）——
--     ★ 说明隐私信息被持久化到存档，跨会话保持。
        privacy_type =
            (TheNet:GetDefaultFriendsOnlyServer() and PRIVACY_TYPE.FRIENDS) or
            (TheNet:GetDefaultLANOnlyServer() and PRIVACY_TYPE.LOCAL) or
            (TheNet:GetDefaultClanOnly() and PRIVACY_TYPE.CLAN) or
            PRIVACY_TYPE.PUBLIC,
        clan =
        {
            id = TheNet:GetDefaultClanID(),
            only = TheNet:GetDefaultClanOnly(),
            admin = TheNet:GetDefaultClanAdmins(),
        },
    }
end
--★ GetDefaultServerData 结束。★★ 返回「开服设置的快照表」，存进存档供客户端读。
--   ★ ★★ 关键约束（:818 注释）：必须在 StartServer 之后调用，否则 online_mode 错。
--【机制：开服参数快照】GetDefaultServerData → 存进存档供客户端读。
--   ★★ 时序约束（:818 注释）：必须在 StartServer 之后调用，
--     ★★★ 否则 IsOnlineMode() 返回错误值（:827）。
--   ★ privacy_type 四选一（:835-839）—— 用单字段表达互斥的隐私级别。
--★★ 参见 prefabs/world.lua:426-427（ismastersim / ismastershard 的权威赋值处）。

--★ ★★★ 【小节标记】StartDedicatedServer 的第 1 阶段在此（:851-852 StartServer）。
function StartDedicatedServer()
    print("Starting Dedicated Server Game")
    local start_in_online_mode = not TheNet:IsDedicatedOfflineCluster()
    local server_started = TheNet:StartServer(start_in_online_mode)
    if server_started == true then
        DisableAllDLC()

--★★★[第 856-857 行：★★ 时序保证（★ 与 GetDefaultServerData:818 呼应）]
--   "--V2C: From now on, we want to actually write data into
--    a slot before initiating LOAD_SLOT action on it!"
--   ★★★ 翻译：「从现在起，我们要在对一个槽位发起 LOAD_SLOT 动作**之前**，
--   ★★ 真正往那个槽位里写入数据」。
--   ★★★ 为什么这个顺序至关重要？
--     · StartServer 已调用（:852）→ online_mode 等设置就绪；
--     · ★★ 此时 GetDefaultServerData() 返回正确值（:860）；
--     · ★★★ 先 SetServerShardData 写入（:869/:879）；
--     · ★★★ 写入完成后（onsaved 回调）才 StartNextInstance 读档（:865）。
--     · ★★ 若顺序反了（先读档后写入）→ ★★ 读到空槽位 → 崩或重置。
--   ★★★ 这是本函数「存档 → 重启 → 读档」三阶段的顺序保证。
        --V2C: From now on, we want to actually write data into
        --     a slot before initiating LOAD_SLOT action on it!

        local slot = ShardGameIndex:GetSlot()
        local serverdata = GetDefaultServerData()

--★★★[第 862-866 行：★★ onsaved 回调 —— 「存档完成后再重启」]
--   local function onsaved()
--       TheNet:SetServerPlaystyle(ShardGameIndex:GetServerData().playstyle or PLAYSTYLE_DEFAULT)
--       UpdateServerTagsString()
--       StartNextInstance({ reset_action = RESET_ACTION.LOAD_SLOT, save_slot = slot })
--   ★★★★ 回调做三件事（★ 顺序有讲究）：
--     ① SetServerPlaystyle —— ★ 读回刚存的 playstyle 并设置：
--       ★★★ 为什么要「读回再设」？推理：
--       ★ 存档里存的 playstyle 可能与当前不同（比如之前存的）；
--       ★★ 「以存档为准」重设一次 → ★ 保证重启后行为一致。
--       ★★ `or PLAYSTYLE_DEFAULT` 兜底（存档里没有该字段时）。
--     ② UpdateServerTagsString() —— ★★★ 为什么这里要更新标签？
--       ★★★ 因为第 860 行的 GetDefaultServerData + SetServerShardData
--         ★★★ 可能**改变了**服务器设置 → ★ 标签需重新计算。
--       ★★ 标签反映的是「服务器设置」→ 设置变了，标签就得变。
--       ★★★ 交叉参考：:748 UpdateServerTagsString 与 world.lua:602 的同名调用。
--       ★★ 这里在存档之后调（不是之前）—— 因为依据的是「存好的设置」。
--     ③ StartNextInstance —— ★★ 与 :715 DoReset **完全相同**的一行。
--       ★★ 复用 DoReset 的写法（但这里内联而非调用 DoReset）。
--       ★★ 推测不能直接调 DoReset，因为它内部用 ShardGameIndex:GetSlot()，
--         ★ 而这里要确保用同一个 slot（:859）。
--   ★★★ ★★ 整个函数的时序（★ 移植必须严格保持）：
--     StartServer → SetServerShardData（异步）→ onsaved → SetServerPlaystyle
--     → UpdateServerTagsString → StartNextInstance(LOAD_SLOT)
        local function onsaved()
			TheNet:SetServerPlaystyle(ShardGameIndex:GetServerData().playstyle or PLAYSTYLE_DEFAULT)
            UpdateServerTagsString()
            StartNextInstance({ reset_action = RESET_ACTION.LOAD_SLOT, save_slot = slot })
        end

--★★★[第 868-880 行：★★ 空存档 vs 已有存档的分支处理]
--   if ShardGameIndex:IsEmpty() then
--       ShardGameIndex:SetServerShardData(nil, serverdata, onsaved)
--   else
--       if TheNet:GetServerIsClientHosted() then
--           local slot_server_data = ShardGameIndex:GetServerData(slot)
--           --V2C: new flags added, with backward compatibility
--           if not serverdata.encode_user_path and slot_server_data.encode_user_path then
--               serverdata.encode_user_path = TheNet:TryDefaultEncodeUserPath()
--           end
--           serverdata.use_legacy_session_path = slot_server_data.use_legacy_session_path
--       end
--       ShardGameIndex:SetServerShardData(nil, serverdata, onsaved)
--   end
--   ★★★★ 三个分支（★ 逐个读解）：
--     ① ★★ IsEmpty() → 全新服务器：直接 SetServerShardData（无兼容处理）。
--       ★★ 没有旧数据，就无「向后兼容」的必要。
--     ② ★★★ else + GetServerIsClientHosted()：已有存档 + 房主托管 →
--       ★★ 读出 slot 里的旧数据（slot_server_data），做向后兼容：
--       · ★★ encode_user_path：
--         条件 `not serverdata.encode_user_path and slot_server_data.encode_user_path` ——
--         ★★★ 「新数据没设这个字段，但旧数据有」→ 说明这是「新增字段」的补齐；
--         ★★ `TheNet:TryDefaultEncodeUserPath()` —— 用「当前默认值」补上。
--         ★★★ 这就是向后兼容的典型手法：★ 新字段用默认值填补。
--       · ★ use_legacy_session_path：
--         ★★★ `serverdata.use_legacy_session_path = slot_server_data.use_legacy_session_path`
--         ★★★ 直接把**旧值搬过来** —— ★★ 为什么？
--         ★★ 推理：★ 这个标记「一旦设定就不该改变」（旧路径的存档已按旧规则写）；
--           ★★ 强行改会与已有存档不兼容。
--           ★★★ 所以「保持原样」是正确的向后兼容。
--       · 注释「new flags added, with backward compatibility」直接点明了意图。
--     ③ else + 非房主托管（有存档但不是房主托管，如专服）：
--       ★★ 跳过兼容处理（因为专服的存档格式由服务端统一管理）。
--   ★★★ ★★ 「向后兼容」是本函数的核心工程约束（★ 存档格式的演进管理）：
--     · 新增字段 → 用默认值补（旧存档缺失）；
--     · 历史字段 → 保持旧值（不能改语义）。
--   ★★ 这与 networking.lua:829 的 use_legacy_session_path = nil 呼应。
        if ShardGameIndex:IsEmpty() then
            ShardGameIndex:SetServerShardData(nil, serverdata, onsaved)
        else
            if TheNet:GetServerIsClientHosted() then
                local slot_server_data = ShardGameIndex:GetServerData(slot)
                --V2C: new flags added, with backward compatibility
                if not serverdata.encode_user_path and slot_server_data.encode_user_path then
                    serverdata.encode_user_path = TheNet:TryDefaultEncodeUserPath()
                end
                serverdata.use_legacy_session_path = slot_server_data.use_legacy_session_path
            end
            ShardGameIndex:SetServerShardData(nil, serverdata, onsaved)
        end
    end
end
--★★★ StartDedicatedServer 结束（34 行）。★★ 三阶段时序（见 :856-866 的分析）：
--   ① StartServer（网络层就绪）
--   ② SetServerShardData（写入开服设置，处理向后兼容）
--   ③ onsaved 回调：SetServerPlaystyle + UpdateServerTagsString
--      → StartNextInstance(LOAD_SLOT) 重启读档
--   ★★ 「先存档后重启」的顺序是硬约束（:856 注释明确）。
--【机制：专服启动三阶段时序】StartDedicatedServer（顺序是硬约束）。
--   ① StartServer（:852）—— 网络层就绪，online_mode 确定；
--   ② SetServerShardData（:869/:879）—— 写入开服设置 + 向后兼容处理；
--   ③ onsaved 回调（:862-866）★★ 存档完成**之后**才重启：
--      SetServerPlaystyle（读回存档以存档为准）→ UpdateServerTagsString
--      → StartNextInstance(LOAD_SLOT)。
--   ★★ ②→③ 的顺序理由（:856 注释）：先写数据，再对该槽位发起 LOAD_SLOT。
--   ★★ 向后兼容（:872-877）：新字段用默认值补（encode_user_path）、
--     历史字段保持旧值（use_legacy_session_path）—— ★ 两类字段两种策略。
--★★ 参见 prefabs/world.lua:553（IsDedicated 的另两个模式判定）；
--   ★★ 参见 prefabs/world.lua:564-566（客户端提前 return 的性能命门）。

--★★★[JoinServerFilter —— ★ 「过滤器」钩子：★ 目前无条件通过]
--   return true
--   ★★★ 为什么有一个恒返回 true 的函数？
--     ★ 推理：它是「服务器列表过滤」的扩展点 ——
--       模组可以覆盖它来实现「只显示好友的服务器」等功能。
--     ★★ 与 :87 Networking_Announcement_GetDisplayName 同一套「恒等钩子」哲学。
--   ★★★ 这类「空钩子」是模组系统的常见手法：
--     ★ 引擎不实现功能，只提供位置，让模组填。
function JoinServerFilter()
    return true
end

--★★★★★[CalcQuickJoinServerScore —— ★★ 快速加入的服务器排序算法]
--   ★★★ 签名：CalcQuickJoinServerScore(server) → 分数或 -1
--   ★★★ 第 889-891 行注释（★ 契约说明）：
--     · 返回分数：分数越高优先级越高；
--     · ★★ 返回 -1：拒绝这个服务器（不进快速加入列表）。
--   ★★★★ 第 893-900 行的「硬性过滤」（★ 8 个条件全满足才继续）：
--     ① not server.pvp            —— 非 PVP
--     ② ★ server.dedicated        —— ★★ 是专服（★ 见下方分析）
--     ③ not server.has_password   —— 无密码
--     ④ not server.mods_enabled   —— 无模组
--     ⑤ mode == "survival"        —— 生存模式
--     ⑥ current_players < max     —— 未满员
--     ⑦ ★★ ping > 0 and ping < 200 —— 延迟合理
--   ★★★★ 为什么筛选要这么严（★ 理解快速加入的设计意图）：
--     ★★ 「快速加入」= 一键进一个「标准、友好」的服务器。
--     · ★ PVP（:893）—— ★ 快速加入应避免战斗服；
--     · ★★ 专服（:894）—— ★★★ 最反直觉的一条！为什么排除房主开的服？
--       ★★★ 推理：★ 房主开的房通常是「朋友的小房间」，
--         ★★ 而快速加入面向「随便找个服玩」的场景；
--         ★★ 房主的服通常人少/不公开 → 匹配快速加入的目的。
--       ★★ 或者：★ 房主可能就是你自己（排除自己的房）。
--     · 无密码（:895）/ 无模组（:896）—— ★★ 避免「进不去」或「加载失败」；
--     · ping（:899）—— ★★ < 200ms 保证基本可玩。
--   ★★★ 不满足任一条 → 第 915 行 return -1（拒绝）。
function CalcQuickJoinServerScore(server)
	-- Return the score for the server.
	-- Highest scored servers will have the highest priority
	-- Return -1 to reject the server

	if (not server.pvp)														-- not PVP
		and server.dedicated												-- is a dedicated server
		and (not server.has_password)										-- not passworded
		and (not server.mods_enabled)										-- not modded
		and string.lower(server.mode) == "survival"							-- survival game mode
		and server.current_players < server.max_players						-- not full
		and (server.ping > 0 and server.ping < 200)							-- filter out bad pings
	then
--★★★[第 901-912 行：★ 评分模型（★ 只在通过了硬性过滤后才计算）]
--   ★★★ 加分项（★ 每条都有明确的意图）：
--     ① :903 friend_playing        +10  ★★★ 最高权重
--     ② :904 _has_character_on_server +4  ★★ 有我的角色（可继续上次进度）
--     ③ :905 current_players >= 3  +3  ★★ 人数较多（社区活跃）
--     ④ :906 current_players > 0   +2  ★ 有人（空服不热闹）
--     ⑤ :907 belongs_to_clan        +1  ★ 同 clan
--     ⑥ :908 season == AUTUMN       +2  ★★★ 秋季（★ 特殊加成，见下方分析）
--   ★★★ 减分项：
--     ⑦ :910 current_players == 0  -1  ★★ 空服减分（与 :906 的 +2 相对）
--   ★★★★ 设计意图分析（★ 值得学习）：
--     · ★★ 「朋友在玩」+10 是压倒性的权重 —— ★ 「和朋友一起玩」是第一优先；
--     · ★★ 「有我的角色」+4 —— 「我想接着玩我的存档」；
--     · ★★★ :908 的秋季 +2 ★★★ 极其特殊 —— ★ 为什么秋季？
--       ★★★ 推理（★ 推测）：★ 秋季是 DST 的「最适合生存的季节」（资源丰富）；
--         ★★ 而春季是新手期、夏季炎热、冬季严寒 —— 秋季体验最佳。
--         ★★ 这是一个「游戏平衡考虑融入推荐算法」的体现。
--       ★★★ 移植启示：★ 「推荐算法」可以编码游戏体验偏好，不只是社交属性。
--     · ★★ :906 与 :910 的微妙关系：
--       「1-2 人 +2」「3+ 人 +3」「0 人 -1」——
--       ★★★ 即「有人 +2，比 3 人少 1 分，但比空服高 3 分」；
--       ★★ 目标分数区间：找到「热闹但不拥挤」的服。
--   ★★★ 全部条件用**同一行的尾随注释**标注（与本文件其他部分风格不同），
--     ★ 说明这部分是「一行一规则」的快速写法。
		local score = 0

		if server.friend_playing then										score = score + 10		end
		if server._has_character_on_server then								score = score + 4		end
		if server.current_players >= 3 then									score = score + 3		end
		if server.current_players > 0 then									score = score + 2		end
		if server.belongs_to_clan then										score = score + 1		end
		if server.season ~= nil and server.season == SEASONS.AUTUMN then	score = score + 2		end

		if server.current_players == 0 then									score = score - 1		end

		return score
	end

	return -1
end
--★★ CalcQuickJoinServerScore 结束（29 行）。★★ 一个「推荐算法」的完整样本：
--   · ★★ 硬过滤（8 条件）→ 拒绝返回 -1；
--   · ★★ 软评分（+10 到 -1）→ 分数越高越优先。
--   ★★ 值得学习的两点：
--     · ★ 把「游戏体验偏好」（秋季+2、空服-1）编入推荐；
--     · ★ 硬过滤与软评分分离（「能不能进」vs「哪个更好」）。
--   ★ ★ 房主托管排除（:894）是最反直觉但合理的设计（见 :894 分析）。
--【机制：服务器推荐算法】CalcQuickJoinServerScore（★ 硬过滤 + 软评分两段式）。
--   ★★ 硬过滤（8 条件→-1）：非 PVP / ★★ 专服 / 无密码 / 无模组 / 生存 /
--     未满 / 0 < ping < 200。
--     · ★★ 「排除专服」最反直觉但合理（:894 分析）—— 房主的房多是小房间。
--   ★★ 软评分：朋友+10 > 有角色+4 > 3人+3 > 有人+2 > 秋季+2 > 同clan+1 > 空服-1。
--     ★★★ 秋季 +2（:908）—— 把「游戏体验偏好」编入推荐（★ 最值得学习的一条）。
--★★ 参见 prefabs/world.lua:430（世界实体的标签体系）与 networking.lua:748（标签生成）。

--★★★[LookupPlayerInstByUserID —— ★ userid → 玩家实体的查找]
--   ★★★ 签名：LookupPlayerInstByUserID(userid) → 玩家实体或 nil
--   ★★★★ 第 919-923 行：遍历 AllPlayers 找 userid 匹配的。
--     ① ★★ 用 ipairs(AllPlayers) —— ★★ **顺序**数组：
--       ★ 对比 prefabs/world.lua:305 用 pairs(Ents)（字典、无序）；
--       ★★ 这里的 AllPlayers 是「有序的玩家列表」（可能有顺序意义，如房主优先）；
--       ★★ 所以用 ipairs。
--     ② ★★ 若有多个匹配，返回**第一个**（ipairs 顺序）；
--       ★★ 推理：正常情况下 userid 唯一 → 只有一个匹配。
--     ③ 返回 v 或隐式 nil（找不到时函数末尾无 return）。
--   ★★★ 为什么需要这个函数（★ 与 Ents[guid] 的区别）：
--     · Ents[guid] 是「GUID → 实体」（networkclientrpc.lua 大量使用）；
--     · ★★ 本函数是「userid → 实体」—— ★★ 两者索引维度不同！
--     ★★ 因为游戏逻辑里更常用 userid（如「找到 XX 玩家」）。
--   ★★★ 性能：★ O(n) 遍历（n = 玩家数 ≤ 8，★ 完全可接受）。
--     ★ ★ 对比 AllPlayers 若是 1000 人就需要索引表，但 DST 最多 8 人。
--     ★→ 移植到 MMO 时必须改为 userid → entity 的哈希索引。
function LookupPlayerInstByUserID(userid)
    for i,v in ipairs(AllPlayers) do
        if v.userid == userid then
            return v
        end
    end
end
--★★ LookupPlayerInstByUserID 结束。★ userid → 实体（O(n) 遍历，DST 规模下可接受）。
--   ★ ★ 与 Ents[guid]（networkclientrpc 大量使用）是不同的索引维度。
--【机制：userid → 玩家实体】LookupPlayerInstByUserID。
--   ★ 用 ipairs(AllPlayers)（有序玩家列表），与 Ents[guid] 是不同索引维度。
--   ★★ O(n) 遍历：DST 最多 8 人可接受；★ 移植到 MMO 必须改为哈希索引。

-- returns the client table with only the players in it, removing the dedicate host object if needed
--★★★[GetPlayerClientTable —— ★★ 客户端表的一个精妙修正]
--   ★★★ 第 926 行原注释："returns the client table with only the players in
--   it, removing the dedicate host object if needed"
--   ★★ 「dedicate host object」—— 专服的主机对象（不是真玩家）。
--   ★★★★ 三分支逻辑（第 929-942 行）：
--     ① ClientObjs == nil                  → return {}
--       ★★★ 「返回空表而非 nil」—— ★ 保证调用方拿到的是合法的空列表。
--     ② ★★ GetServerIsClientHosted()       → return ClientObjs（原样返回）
--       ★★★ 房主托管时**不移除**主机对象。
--     ③ 专服托管时 → 移除 v.performance ~= nil 的项（:937-940）。
--   ★★★★ 第 ②③ 分支的推理（★ 关键理解）：
--     ★★ 主机对象（dedicate host）在「房主」时是**真实玩家**（有游戏内的角色）；
--     ★★ 但在**专服**时，它只是一个「承载主机身份的对象」，不是玩家。
--     · ★ 所以房主（GetServerIsClientHosted 为真）→ 保留（有角色）；
--     · ★★ 专服（为假）→ 移除（只该算真玩家）。
--   ★★★★ 第 936-940 行的移除循环：
--     for i, v in ipairs(ClientObjs) do
--         if v.performance ~= nil then
--             table.remove(ClientObjs, i)
--             break                    -- ★★★ 只移除第一个就 break
--     ★★★ 「performance ~= nil」—— 主机对象的识别标志？
--       ★★★ 这个字段名暗示「性能统计」数据 —— 推测主机对象携带了
--         ★★★ 额外的性能/主机信息，普通玩家没有。
--       ★★ 用「是否存在某字段」来区分主机对象（鸭子类型识别）。
--       ★ ★★ 这是脆弱的识别方式（若玩家也有 performance 字段则误删）。
--     · ★ break —— ★★ 最多移除一个（假设最多一个主机对象）。
--       ★★★ 同时避免了 table.remove 在 ipairs 遍历中的「跳过元素」问题。
--   ★★ 对比 networking.lua:936 的 GetPlayerClientTable 与 :918 的
--     LookupPlayerInstByUserID —— 两个「玩家查找」的不同维度。
function GetPlayerClientTable()
    local ClientObjs = TheNet:GetClientTable()
    if ClientObjs == nil then
        return {}
    elseif TheNet:GetServerIsClientHosted() then
        return ClientObjs
    end

    --remove dedicate host from player list
    for i, v in ipairs(ClientObjs) do
        if v.performance ~= nil then
            table.remove(ClientObjs, i)
            break
        end
    end
    return ClientObjs
end
--★★ GetPlayerClientTable 结束。★★ 关键：「房主托管 vs 专服托管」决定是否移除主机对象。
--   ★ ★ 与 :918 LookupPlayerInstByUserID 一起构成本文件的两大「玩家查找」入口。
--【机制：主机对象剔除】GetPlayerClientTable。
--   ★★★ 房主托管时保留主机对象（有真实角色）；专服托管时剔除。
--   ★ 用 `v.performance ~= nil` 字段存在性做鸭子类型识别（:937）。
--   ★ break 一次 —— 同时规避了 table.remove 在 ipairs 中的跳过问题。
--★★ 参见 prefabs/world.lua:431-432（CLASSIFIED 标签 —— 主机对象与之无关，仅作对照）。

--★★★[ClientAuthenticationComplete —— ★ 玩家认证完成事件]
--   ★★★ 第 946-948 行：
--     if TheWorld ~= nil and TheWorld:IsValid() then
--         TheWorld:PushEvent("ms_clientauthenticationcomplete", {userid = userid})
--   ★★★★ 四点分析：
--     ① ★★★ **双重存在性检查**：TheWorld ~= nil 且 TheWorld:IsValid() ——
--       ★★★ 对比 :946 同文件的 TheWorld ~= nil 单检查 ——
--       ★★ 这里多了一个 IsValid() —— ★ 因为 PushEvent 需要**活着的实体**。
--       ★★ 推理：TheWorld 可能非 nil 但已失效（OnRemoveEntity 已跑但全局没清？
--         ★ 或世界销毁过程中）—— ★ 推事件给死实体会崩。
--     ② ★★ PushEvent 是「世界事件」的标准转发（见 prefabs/world.lua 注）。
--     ③ ★ ms_ 前缀（服务端世界事件）；
--       ★★ clientauthenticationcomplete = 客户端「认证完成」。
--       ★★★ 什么是「认证」？（★ 推理）
--       ★· 客户端连上 → 服务器验证 Steam 凭证 → ★ 认证完成；
--       ★★ 这是一个**安全关口**（防止未授权客户端）。
--       ★★ 认证前客户端只能做有限的事，认证后才被允许进世界。
--     ④ 载荷只有 {userid} —— ★ 因为「谁认证完成了」是唯一需要的信息。
--   ★★★ 对比 :951 ClientDisconnected（同构，事件名不同）。
--   ★ 这两个回调是「连接生命周期的两端」（连上 vs 断开）。
function ClientAuthenticationComplete(userid)
	if TheWorld ~= nil and TheWorld:IsValid() then
		TheWorld:PushEvent("ms_clientauthenticationcomplete", {userid = userid})
	end
end

--★★[ClientDisconnected —— 玩家断开连接事件]
--   ★★★ 结构与 :945 完全同构，只换事件名 ms_clientdisconnected。
--   ★★ 断连时游戏逻辑关心：「存档」「归还物品」「踢出投票」等清理。
--   ★ ★ 交叉参考：:303 SerializeUserSession（断连前/后的存档时机）。
function ClientDisconnected(userid)
	if TheWorld ~= nil and TheWorld:IsValid() then
		TheWorld:PushEvent("ms_clientdisconnected", {userid = userid})
	end
end
--★★★ 连接事件区结束（:945/:951）。★★ 两个回调都是「世界事件转发」：
--   · ms_clientauthenticationcomplete —— 认证完成（安全关口通过）；
--   · ms_clientdisconnected —— 断开连接。
--   ★ ★ 都带 TheWorld ~= nil and IsValid() 双重检查（世界可能已销毁）。
--【机制：连接生命周期事件】认证完成 / 断开连接。
--   ★★ 都用 `TheWorld ~= nil and TheWorld:IsValid()` —— ★★ 双重检查。
--     ★★ PushEvent 需要活实体（prefabs/world.lua:606 同款 ms_ 约定）。
--★★ 参见 prefabs/world.lua:606 与 shardnetworking.lua:151（ms_ 事件命名约定的两处源头）。

--------------------------------------------------------------------------
--★★★[第 958 行：_friendsmanager —— ★ 本文件唯一的「模块级状态变量」]
--   local _friendsmanager = nil
--   ★★★ 这是本文件**第一个也是唯一一个** local 变量（在函数外）。
--   ★★★ 为什么需要它（★ 关键理解）：
--     ★ 好友管理器的 UI（widgets）由某个**具体界面**创建并持有；
--     ★★ 但 Networking_PartyInvite(:971) 等回调是**全局函数**（由 C++ 调用）；
--     ★★ 全局函数无法访问「某个界面的局部变量」—— ★★ 需要一个文件级变量来共享。
--     ★★★ 这就是 _friendsmanager 的作用：★★ 「全局回调 → UI 实例」的桥。
--   ★★★ 下划线前缀 _ 表示「私有」（模块内可见，不导出为全局）。
--   ★★★ 第 960-962 行的 UnregisterFriendsManager 就是清空它的函数。
local _friendsmanager = nil

local function UnregisterFriendsManager(inst)
    _friendsmanager = nil
end

--★★★[RegisterFriendsManager —— ★★ UI 实例的注册与自动注销]
--   function RegisterFriendsManager(widg)
--       if _friendsmanager == nil then
--           _friendsmanager = widg
--           widg.inst:ListenForEvent("onremove", UnregisterFriendsManager)
--   ★★★★ 三点：
--     ① ★★ 幂等：只在首次注册时设置（★ 多个界面可能都想注册）。
--     ② ★★ ★ 注册时立刻挂上 onremove 监听 —— ★★ 「UI 销毁时自动注销」！
--       ★★★ 这是本文件最优雅的设计之一：
--         · 任何界面关闭时，实例触发 onremove；
--         · ★★ 监听器自动把 _friendsmanager 清空；
--         · ★★ 从而避免「回调访问已销毁的 UI」。
--       ★★★ 这比手动在关闭流程里调 UnregisterFriendsManager 更可靠。
--       ★ ★ 「监听对象的销毁事件来管理引用」是很好的资源管理模式。
--     ③ ★★★ widg.inst —— ★ widget 有 .inst 字段（底层实体），
--       ★ 用它 ListenForEvent 而不是 widg 本身。
--       ★ 推理：★ ListenForEvent 是**实体**的方法，widget 通过 .inst 持有实体。
--   ★★★ 第 960-962 行的 UnregisterFriendsManager 极简：
--     local function UnregisterFriendsManager(inst) _friendsmanager = nil end
--     ★ ★★ 形参 inst 未用（只作为监听器签名需要）。
--   ★★★ 参见：prefabs/world.lua:944 的同类模式
--     （focalpoint 的创建/销毁对称）。
function RegisterFriendsManager(widg)
    if _friendsmanager == nil then
        _friendsmanager = widg
        widg.inst:ListenForEvent("onremove", UnregisterFriendsManager)
    end
end

--★★★[Networking_PartyInvite —— ★★★ 好友系统的六个全局回调之一]
--   ★★★ 文件末尾共有六个 party/friends 回调（:971/:977/:983/:989/:995/:999）：
--     · Networking_PartyInvite      —— 收到组队邀请
--     · Networking_JoinedParty       —— 加入组队成功
--     · Networking_LeftParty         —— 离开组队
--     · Networking_PartyChanged      —— 组队状态变更
--     · Networking_PartyServer       —— 组队服务器信息（:995，唯一不用 friendsmanager）
--     · Networking_PartyChat         —— 组队聊天
--   ★★★★ 六个的共同模式（★ 极简但有防御）：
--     if _friendsmanager ~= nil then _friendsmanager:XXX(...) end
--     ★★ 全部先判空 —— 因为 UI 可能没开（回调到达与界面打开无关）。
--   ★★★ 这些是「Steam 好友/组队」功能（C++ 层）向游戏逻辑的转接口。
function Networking_PartyInvite(inviter, partyid)
    if _friendsmanager ~= nil then
        _friendsmanager:ReceiveInvite(inviter, partyid)
    end
end

--★★ Networking_JoinedParty —— 加入组队后切到「队伍」标签页。
--   ★★ 注意：回调不仅通知 UI，还**指定了 UI 行为**（SwitchToPartyTab）。
--     ★ 即「状态变化 → 界面自动切换」。
function Networking_JoinedParty()
    if _friendsmanager ~= nil then
        _friendsmanager:SwitchToPartyTab()
    end
end

--★★ Networking_LeftParty —— 离开组队后切回「好友」标签页。
--   ★★ 与 :977 的 SwitchToPartyTab 配对（★ 切过去再切回来）。
function Networking_LeftParty()
    if _friendsmanager ~= nil then
        _friendsmanager:SwitchToFriendsTab()
    end
end

--★★ Networking_PartyChanged —— 组队变更时刷新队伍标签页。
--   ★★ RefreshPartyTab（刷新而非切换）—— 保持当前标签，只更新内容。
function Networking_PartyChanged()
    if _friendsmanager ~= nil then
        _friendsmanager:RefreshPartyTab()
    end
end

--★★[Networking_PartyServer —— ★★ 唯一不用 friendsmanager 的回调]
--   print("Party server: "..ip..":"..tostring(port))
--   ★★★ 为什么不走 _friendsmanager？
--     ★★ 推理：★ 组队服务器信息（IP:端口）可能是自动加入的流程；
--       ★★ 它需要在**无 UI 界面**时也能处理（比如命令行或自动流程）；
--       ★★ 所以只打印，不依赖 UI。
--     ★★ 也可能是「尚未实现」—— 只有 print 说明功能未完成。
--   ★★ 注意 tostring(port) —— ★ 防御性转字符串（port 可能是数字或字符串）。
function Networking_PartyServer(ip, port)
    print("Party server: "..ip..":"..tostring(port))
end

--★ Networking_PartyChat —— 组队聊天消息。
--   ★★ 与 :53 Networking_Say（世界聊天）的区别：
--     · :53 是**世界内**聊天（进 ChatHistory，有聊天框）；
--     · ★ :999 是**队伍**聊天（进 friendsmanager，可能在独立面板）。
--   ★ ★ 两种聊天渠道的不同落地方式。
function Networking_PartyChat(chatline)
    if _friendsmanager ~= nil then
        _friendsmanager:ReceivePartyChat(chatline)
    end
end
--★★★★★ networking.lua 到此结束（1003 行）。★★ 全文件结构回顾（15 节）：
--   §零   依赖与第二实例启动（1-20）—— os.execute 跨进程
--   §一   聊天与公告（23-137）—— 1 基类 + 8 包装 + 1 可覆盖钩子
--   §二   说话/Twitch（139-171）—— 网络回调 → 世界事件
--   §三 ★★★ 角色皮肤合法性校验（173-246）—— 反作弊第一道闸门
--   §四 ★ 出生与无缝换角色（248-299）—— 跨 networking/world 的链路
--   §五 ★★★ SerializeUserSession（301-330）—— 玩家持久化
--   §六   模组对齐与下载（332-489）—— 沙箱、版本锁、错误码体系
--   §七 ★★★ JoinServer（491-644）—— UI 编排（先本地后网络）
--   §八 ★★★ MigrateToServer（646-669）—— 重启进程换世界
--   §九   颜色与重置/回滚（671-746）—— 回滚步数修正
--   §十 ★★ 标签与世界生成元数据（748-815）—— 主分片汇总全集群
--   §十一 GetDefaultServerData（817-847）—— 开服参数快照
--   §十二 ★★ StartDedicatedServer（849-882）—— 先存档后重启
--   §十三 快速加入评分（884-916）—— 推荐算法
--   §十四 玩家查询与连接事件（918-955）
--   §十五 好友管理器（957-1003）—— 全局回调 → UI 的桥
--   ★★★ 本文件回答的三个核心问题：
--     1) 「玩家数据怎么持久化」→ §五（GetSaveRecord + DataDumper + TheNet）；
--     2) 「三种联机模式怎么区分」→ 各处 ismastersim/ismastershard/IsDedicated 的组合；
--     3) 「连接生命周期怎么走完」→ §七/§八/§十二（加入/迁移/开服）。
--【机制：全局回调 → UI 实例的桥】_friendsmanager（★ 本文件唯一的模块级状态）。
--   ★★ 为什么需要它：网络层只认全局函数名，而 UI 实例由某个界面局部持有
--     ★★ → 必须用文件级变量做桥（:958）。
--   ★★★ 最优雅的一处（:964 RegisterFriendsManager）：
--     ★★ 注册时立刻 ListenForEvent("onremove") —— ★「UI 销毁时自动注销」，
--       ★★ 比手动在关闭流程里调注销更可靠（避免回调访问已销毁 UI）。
--   ★ 六个 party/friends 回调（:971-:999）全部先判空 —— ★ 回调与界面打开无关。
--★★ 参见 prefabs/world.lua:543-545（focalpoint 创建/销毁对称的另一处范例）；
--   ★★ 参见 prefabs/world.lua:360-366（OnRemoveEntity 的完整清理时序）。
