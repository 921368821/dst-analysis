--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：networkclientrpc.lua
-- 模块：联机同步 / RPC（Remote Procedure Call）核心管线
-- 职责：DST 全部 Lua 侧远程过程调用的中枢。承担参数校验谓词（check*/opt*）、
--       三张内置 RPC 处理表（RPC / CLIENT_RPC / SHARD_RPC）的声明与编号分配、
--       限流队列的三条入队路径与逐帧排空、同刻重入保护（RPC_Timeline）、
--       模组 RPC 的注册与派发（namespace + id 二级索引）、
--       以及世界重置时一键关闭发送的熔断开关。
-- 关键符号：checkbool, checknumber, checkuint, checkstring, checkentity,
--           optbool, optnumber, optuint, optstring, optentity,
--           printinvalid, IsPointInRange, ConvertPlatformRelativePositionToAbsolutePosition,
--           RPC_HANDLERS, CLIENT_RPC_HANDLERS, SHARD_RPC_HANDLERS,
--           HandleRPC, HandleClientRPC, HandleShardRPC, HandleRPCQueue, TickRPCQueue,
--           AddModRPCHandler, HandleModRPC, MarkUserIDRPC, DisableRPCSending
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：update.lua:42（WallUpdate 排空队列）、networking.lua（连接生命周期）、
--           shardnetworking.lua（分片侧 RPC 封装）、
--           components/playercontroller.lua（OnRemote* 的实际实现）
-- ★ 实体复制 / 兴趣管理 / 心跳超时在本文件中没有实现：
--   ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现。
--   参见 01-报告/04-联机同步-模组系统-UI.md 与 01-报告/05-原生C++引擎层.md。
--============================================================
--
--【阅读导航】
--  §零   类型校验谓词（1-16）         —— ★★ check*/opt* 两族语义之别
--  §一   非法 RPC 的三段式处理（18-35）—— 打印 / 推事件 / dev 断言
--  §二   几何与范围原语（39-57）      —— ★ 4096 距离平方阈值与平台相对坐标
--  §三 ★★ RPC_HANDLERS 客户端→服务端（59-1386）—— 不可信方向的 100+ 处理器
--  §四 ★★ 三张表的编号机制（1388-1404）—— orderedPairs 决定终身编号
--  §五 ★ CLIENT_RPC_HANDLERS 服务端→客户端（1406-1535）—— 可信方向，无需校验
--  §六 ★ SHARD_RPC_HANDLERS 分片→分片（1537-1634）—— 第三条通道
--  §七 ★★★ 三个发送函数（1636-1660）—— 唯一的对外出口
--  §八 ★★★ 限流与三条队列（1662-1673）
--  §九 ★★★ HandleRPC 入队（1675-1722）
--  §十 ★★★ HandleRPCQueue 排空（1724-1796）—— 同刻重入保护 RPC_Timeline
--  §十一 模组 RPC 的元表机制（1804-1832）—— 大小写不敏感
--  §十二 ★★★ AddModRPCHandler（1834-1879）—— ⚠ 模组可无限抬高全局限流
--  §十三 模组 RPC 的收发（1881-1954）
--  §十四 注册表查询与 MarkUserIDRPC（1956-1993）
--  §十五 DisableRPCSending 熔断（1995-2004）
--
--【★★★ 三张表的分工（本文件最需要先记住的一件事）】
--  ┌──────────┬────────────────────┬──────────────────────┬────────────┐
--  │ 表       │ 方向                │ 处理表                │ 信任级别   │
--  ├──────────┼────────────────────┼──────────────────────┼────────────┤
--  │ RPC      │ 客户端 → 服务端     │ RPC_HANDLERS          │ ★★ 不可信  │
--  │          │ SendRPCToServer     │ :59-1386（约 90 个）  │ 必须逐个校验│
--  │ CLIENT_  │ 服务端 → 客户端     │ CLIENT_RPC_HANDLERS   │ 可信       │
--  │   RPC    │ SendRPCToClient     │ :1407-1519（16 个）   │ 无需校验   │
--  │ SHARD_   │ 分片 → 分片         │ SHARD_RPC_HANDLERS    │ 可信       │
--  │   RPC    │ SendRPCToShard      │ :1539-1618（13 个）   │ 无需校验   │
--  └──────────┴────────────────────┴──────────────────────┴────────────┘
--  ★★ 两条源码注释直接写明了信任前提，这是本文件的根本设计：
--     :1406 "these rpc's don't need special verification because
--             server->client communication is already trusted."
--     :1537 "these rpc's don't need special verification because
--             server<->server communication is already trusted."
--  ★★ 结论：**只有「客户端→服务端」这一个方向需要防御**。
--     其余两个方向的数据源在服务端（或可信分片）内部，
--     不经过不可信信道，因此省掉了每一个 handler 的校验代码。
--     这解释了整个文件 2004 行里，校验逻辑集中在前 1300 行的原因。
--
--【★★ 关于 C_ / V2C / C2V 命名约定】
--  ★★ 这套约定在 DST 的**注释**里被大量使用，不是 Lua 语法，是开发者的速记：
--    · V2C = **V**anilla **2** **C**lient —— 原版代码路径到客户端的桥接，
--      即「这是引擎(C++)为了客户端显示而调用 Lua 的地方」。
--      ★ 判定方法：注释里出现 V2C 且函数名以 Networking_ 开头（networking.lua），
--        或该函数只在一个方向存在 —— 基本都是 V2C。
--    · C2V = **C**lient **2** **V**anilla —— 客户端输入回到原版逻辑的桥接，
--      即「这是客户端发往服务器、由服务器执行的入口」。
--      ★ 判定方法：注释里有 C2V 且处理的是玩家输入（RPC_HANDLERS 里的全部）。
--    · C_  前缀（如果你在模组代码里见到 C_MyFunc）：约定俗成表示
--      「Client to Server」方向的自定义 RPC，即 C2V 的省略写法。
--      ★ 本文件里没有以 C_ 开头的函数名，但**参数校验谓词**沿用了同一风格：
--        checkbool / checknumber / checkuint / checkstring / checkentity
--        与它们的 opt* 可选版本。
--  ★★★ 这套命名的价值：在一个同时有 C++、Lua、原版、模组四层代码的项目里，
--    方向标注让「这个函数谁调谁」不必读实现就能判断。
--    跨层重构时它是最好的路标。
--  ★ 本文件里的实例：
--    · :428 world.lua 无关，此处 —— networkclientrpc.lua 全文没有 V2C/C2V 字样，
--      因为**这个文件本身就是 C2V 的实现**（名字已经说明了方向，无须再注）。
--    · 反向的例子：prefabs/world.lua:428 `--V2C: Masters is hard`、
--      networking.lua:23 `--V2C: This is for server side processing of
--      remote slash command requests`（★ 这句其实描述的是 C2V 语义，
--      说明注释里的方向标注并非总是严谨 —— 读实现才是准的）。
--    · networking.lua:749 `--V2C: ughh... well at least try to keep this
--      in sync with servercreationscreen.lua BuildTagsStringHosting()`。
--  参见 01-报告/00-注释规范与术语表.md。
--
--【本文件最重要的九条】
--  1. ★★★「入队而非立即执行」（HandleRPC:1675 + HandleRPCQueue:1724）：
--     收到 RPC 只做三件事——查表、校验发送者身份、限流、入队。
--     真正的执行发生在每帧一次的排空阶段。理由见 §九 与 §十 的注记。
--  2. ★★★ 限流额度是「入队」额度不是「执行」额度：
--     HandleRPC 自增（:1688），HandleRPCQueue 排空时自减（:1731-1736），
--     ★ 归零后必须清表（:1733-1734）—— 这是防内存泄漏的关键一行。
--  3. ★★★ ⚠ 模组可无限抬高全局限流（AddModRPCHandler:1848）：
--     每注册一个模组 RPC，RPC_QUEUE_RATE_LIMIT 就 +5，**没有上限**。
--     详见 §十二 的完整推理。
--  4. ★★★ 同刻重入保护（RPC_Timeline:1741-1750）：同一个 sender 在同一 tick
--     只允许有一条 RPC 正在执行；后来的排队等下一刻。
--     ★ 这不是为了限流（限流是 :1687 那件事），而是为了保证「同一玩家的多条输入
--     不会在同一刻交错执行」，否则 inventory 这类状态机操作会自相矛盾。
--  5. ★★ 处理器编号在加载期一次性分配（:1391-1395）：
--     `for k,v in orderedPairs(RPC_HANDLERS) do RPC[k] = i; i = i + 1 end`
--     ★★ 终身绑定：此后往 RPC_HANDLERS 加新键不会重新编号。
--     → 新增 handler 必须在**表定义里**，不能运行时追加（否则客户端与服务端
--       的 orderedPairs 顺序可能不同，导致 code 对不上）。
--     ★ 这是本文件最容易踩的坑，也是 AddModRPCHandler 存在的理由：
--       模组用 namespace+id 走独立通道，不占内置编号空间。
--  6. ★★ 距离校验：IsPointInRange(:43) 用 distsq <= 4096，即 64 格半径。
--     ★ 对**平台相对坐标**的 RPC 必须先转绝对坐标再校验（:102/:152/...），
--       否则可以用平台坐标绕过距离检查。
--  7. ★★ 平台相对坐标的二元约束（ConvertPlatformRelativePositionToAbsolutePosition:48）：
--     platform_relative 为真时 platform 必须非 nil，否则返回 nil（无值），
--     调用方统一用 `if x ~= nil then` 跳过 —— ★ 静默丢弃而非报错。
--  8. ★ USERID_RPCS(:1398)：标记某些 handler 的第一个参数**不是实体而是 userid 字符串**。
--     ★ 典型用途：玩家实体尚未生成时（选人阶段）就要处理 RPC。
--     ★ MarkUserIDRPC:1980 提供注册入口。参见 :1121 的注释。
--  9. ★★ DisableRPCSending(:1997)：世界重置时把六个发送函数整体替换为空函数，
--     ★ 用「重绑定全局函数」而非「逐个改标志位」—— 关闭后的调用成本 = 函数调用开销。
--     ★ 但注意它只关**发送**，接收侧（HandleRPCQueue）照旧。
--
--【★ 关于「实体复制 / 兴趣管理 / 心跳超时」】
--  ⚠ 本机制在引擎层（C++ Sim），Lua 侧无对应实现。
--  ★ 本文件只处理「显式的、带类型的 RPC 消息」，不负责实体的状态同步。
--    · 实体复制（netvar 增量同步）：引擎侧 ReplicaManager 风格机制。
--    · 兴趣管理：引擎侧依据 prefabs/world.lua:544 的 TheFocalPoint 计算复制范围。
--    · 心跳/超时断线：引擎侧与 TheNet 相关，Lua 无对应逻辑。
--  参见 01-报告/04-联机同步-模组系统-UI.md（1.4 兴趣管理 :1318；2.x RPC 全章）
--       与 01-报告/05-原生C++引擎层.md:521（GUID 标识与复制同步）。
--  ★★ 区分 RPC 与实体复用的口诀：
--    「RPC 是玩家主动做的事（点击、移动、合成），复制是世界发生的变化」。
--     前者必须校验与限流（本文件），后者由引擎按兴趣范围自动处理。
--
--【⚠ 本文件记录的疑似缺陷清单（共 5 处）】
--  A. :43-46 IsPointInRange 的 4096 阈值是硬编码，且**位置校验不等于合法性校验**。
--  B. :1848 模组可无限抬高全局限流（★ 用户核实的那个缺口，就在第 1848 行）。
--  C. :715 SwapOneOfActiveItemWithSlot 的背包分支是空的（源码 TODO）。
--  D. :1035 exitgym 全小写命名，且它是本文件里唯一绕过参数校验的 handler。
--  E. :1646/:1656 注释里的 `users`/`shards` 参数在签名中并不存在（文档过时）。
--★ 唯一一条 require：util。
--  ★ util.lua 提供 distsq / IsTableEmpty / deepcopy / SetTableReadOnly 等通用工具。
--    第 45 行的 distsq 就来自这里。
--  ★ 整个 2004 行的 RPC 管线只依赖这一个工具模块 —— 刻意保持轻依赖，
--    因为它在网络早期就要可用（比大部分玩法代码都早）。
require 'util'

--★★★【原注释 "Global so Mods can use them too" —— 一个刻意的全局泄漏】
--   ★★★ 五个 check* 函数全部是**无 local 的全局**（第 4-8 行）。
--   ★★ 为什么故意暴露给模组？
--     因为模组要写自己的 RPC handler，就必须做同样的参数校验。
--     如果这些谓词是 local，模组就得起见：
--       · 重复实现一遍（容易写错，安全策略分裂）
--       · 或 hack 进本文件的 upvalue（更糟）
--     ★ 暴露它们 = 「请用我们的校验器」，安全策略因此统一。
--   ★ 这是一个值得学习的取舍：**用一个受控的公共 API 换取全项目的一致性**。
--   ⚠ 代价：任何模组可以覆盖这些全局函数，从而把校验器改成永远返回 true。
--     ★ 这是真实风险：模组能削弱服务器的安全防线。
--     → 移植时应把这五个函数放进只读的模块表，或加一层不可篡改的封装。
--Global so Mods can use them too
--★★【checkbool —— 全族里唯一的特殊项：它把 nil 也算「合法」】
--   return val == nil or type(val) == "boolean"
--   ★★ 为什么布尔允许 nil？因为「按下」与「没按下」用 nil 表达，
--     或者说：isreleased 这类标志位不传（nil）就是 false。
--   ★★ 关键区别：**checkbool 是「值可为 nil 的 bool 检查」**，
--     而 optbool 是「nil 或 bool」（见第 10 行）。两者在这个文件里几乎同义，
--     ★ 真正的区别在于使用语境（见下面 AFTER 的说明）。
--   ★ 原注释第 3 行说 "Global so Mods can use them too"，
--     第 9 行的 `optbool = checkbool` 则是别名的来源。
function checkbool(val) return val == nil or type(val) == "boolean" end
--★ checknumber —— 最宽松的数值检查：只认 type == "number"。
--   ★ 不检查是否为整数、不检查范围（NaN / math.huge 都能通过）。
--     范围校验交给上层（如 IsPointInRange / IsRotationValid）。
--   ★ 这种「谓词只管类型，业务函数管范围」的分工是本文件的统一风格。
function checknumber(val) return type(val) == "number" end
--★★★【checkuint —— 用字符串正则来判断「无小数」，这是本文件最巧妙的一行】
--   return type(val) == "number" and tostring(val):find("%D") == nil
--   ★★ 技巧说明：tostring(number) 产生的字符串里，"%D" 匹配任何**非数字**字符。
--     整数如 "5" → 无非数字字符 → find 返回 nil → 判定为 uint ✓
--     小数如 "5.5" → 找到 "." → 判定为非 uint ✗
--     负数如 "-3" → 找到 "-" → 非 uint ✗（负数确实不该算 uint）
--     ★ 顺带把负数也排除了，一举两得。
--   ★★ 为什么不用 math.floor(val) == val？
--     因为它不能排除负数，且对 math.huge / NaN 的行为不可靠。
--     ★ 而 inventory slot 号**必须**是无符号整数，否则会出现 -1 号槽位。
--   ★★ 原注释第 15 行解释了为什么这个严格性是必要的：
--     "checkuint since non-integer inventory slots are not handled gracefully"
--     —— 非整数槽位会导致物品栏逻辑错乱（Lua 的 table 键是 1.5 而不是 2）。
--   ⚠ 边界：tostring(1e15) 在某些 Lua 实现下会变成 "1e+15"，含非数字字符 →
--     会被误判为非 uint。实践中槽位号远小于 10^15，不构成问题。
function checkuint(val) return type(val) == "number" and tostring(val):find("%D") == nil end
--★ checkstring —— 只认 string 类型。
--   ★ 注意它**不检查长度**。长度校验在各自的 handler 里做，
--     例如 networking.lua:54 的 `message:utf8len() > MAX_CHAT_INPUT_LENGTH`。
--   ★★ 印证「谓词管类型、业务管约束」的分工原则。
function checkstring(val) return type(val) == "string" end
--★★★【checkentity —— 全文件最需要警惕的一个谓词】
--   return type(val) == "table"
--   ★★★ 它**只检查是不是 table**，不检查这个 table 是不是一个合法实体！
--   ★★ 后果（推理）：
--     客户端可以传任意 table —— 一个普通 Lua 表、或者精心构造的、
--     带 GetPosition/IsValid 等方法（甚至带元表 __index 指向实体）的表。
--     这些表会在后续代码里被当作实体使用（`target.components.container` 等）。
--   ★★ 但攻击的实际收益有限，因为：
--     · 服务端访问 `x.components.foo` 时，普通表返回 nil，各 handler 有判空；
--     · 真正危险的操作（如 inventory 交互）还要过 IsOpenedBy(player) 这类
--       「以 player 为参数」的检查（第 536/565/584 行等），
--       而伪造的表无法通过 —— ★ 因为服务端比对的是真实 player 实体的状态。
--   ★★ 结论：checkentity 是个**弱检查**，安全网在 handler 内部。
--     → 移植时应改为 `type(val) == "table" and Ents[val.GUID] == val`
--       之类的真值检查，或至少确认 val.entity ~= nil。
--     → 参见 01-报告/04-联机同步-模组系统-UI.md:1115 的安全基线。
--   ★ optentity（第 13 行）是它的可选版本（允许 nil）。
function checkentity(val) return type(val) == "table" end
--★★【`optbool = checkbool` —— 十个字符解释了 check 族与 opt 族的真正关系】
--   ★★★ optbool 不是新函数，只是 checkbool 的**别名**。
--   ★★ 而 optbool 的定义（第 10 行）是 `val == nil or type(val) == "boolean"` ——
--     与 checkbool（第 4 行 `val == nil or type(val) == "boolean"`）**完全相同**！
--   ★★★ 推理：checkbool 从一开始就把 nil 当作合法，所以 checkbool ≡ optbool。
--     第 9 行这个赋值是为了与 optnumber/optuint/optstring/optentity 对称命名，
--     让「这个参数是可选的」在代码里看得出来。
--   ★★ 所以本文件里 checkbool 与 optbool 是同一个函数的两个名字。
--     而 checknumber ≠ optnumber（后者允许 nil），checkstring ≠ optstring 等。
--   ★ 这是「命名一致性」优先于「消除重复」的取舍 ——
--     可读性收益大于 DRY 收益。
optbool = checkbool
--★★【optnumber —— 「可为 nil 的数值」，与 checknumber 的唯一差别就是 nil】
--   ★ 语义：某些 RPC 参数是「可选的数值」，不传就是 nil，
--     而传了就必须是 number。例如 controlmods（手柄按键位）。
function optnumber(val) return val == nil or type(val) == "number" end
--★ optuint —— checkuint 的可选版本：多一个 nil 放行。
--   ★ 组合了第 6 行的字符串技巧与 nil 放行。
function optuint(val) return val == nil or (type(val) == "number" and tostring(val):find("%D") == nil) end
--★ optstring —— checkstring 的可选版本。
function optstring(val) return val == nil or type(val) == "string" end
--★ optentity —— checkentity 的可选版本（target / platform / spellbook 常可省略）。
--   ★★ 注意第 62 行的 LeftClick 校验里 optentity(target) 与 checkentity(target)
--     混用：target 可选而 item 必需（后者见第 727 行 checkentity(item)）。
--     ★ 选哪个取决于「这个参数缺席时业务是否还成立」，不是随意的。
function optentity(val) return val == nil or type(val) == "table" end
--★ opt* 族结束。五组 check/opt 谓词是整个 RPC 校验体系的地基 ——
--   ★ 全文件约 90 个 handler 里的每一个 if 语句都在调用它们。

--★★★【两条说明 pin 住整个校验哲学】
--   :15 "checkuint since non-integer inventory slots are not handled gracefully"
--       → 解释为什么槽位类参数必须用严格的 uint（第 6 行的原因）。
--   :16 "checknumber is generally enough for other cases"
--       → ★ 明确表态：**其余场合用宽松的 checknumber 就够了**。
--   ★★ 合起来是：不要过度校验。校验的目的是「防止类型混乱导致崩溃与作弊」，
--     而不是「保证语义合法」。语义合法性由业务代码负责。
--NOTE: checkuint since non-integer inventory slots are not handled gracefully
--      checknumber is generally enough for other cases
--★ 说明区结束。第 18 行起是诊断与几何原语，第 59 行起才是真正的处理器表。

--★★★【printinvalid —— 非法 RPC 的三段式处理，本文件的安全哲学集中体现】
--   ① 打印日志（含 userid 与 name，便于追查）；
--   ② 派发 invalidrpc 事件 —— ★ 这是给反作弊模组的正式接口；
--   ③ 仅 dev 分支 assert 崩溃（生产环境不崩）。
--   ★★ 三段设计的成熟之处：
--     · 生产环境永不因客户端 bug/攻击而崩溃（可用性优先）；
--     · 但完整留下证据链（可观测性优先）；
--     · 还留了第三方接入口（可扩展性优先）。
--     三者本可互相取舍，这里全都要 —— 这是成熟项目的典型做法。
--   参见 01-报告/04-联机同步-模组系统-UI.md:1115（安全基线）
--     与 :1532（对这三段设计的分析）。
--   ★ 它是 local（第 18 行），不对外暴露 —— 因为调用方千篇一律，
--     没有让模组替换它的必要（与第 4-8 行的 check* 形成对比，
--     ★ 说明「哪些东西该暴露」的判断标准是「模组是否需要复用」）。
local function printinvalid(rpcname, player)
--★ 日志格式："Invalid <RPC名> RPC from (<userid>) <name>"。
--   ★ 两个身份字段都打印：userid 是账号标识（唯一），name 是显示名（易读）。
--     ★ `player.userid or ""` 的 or 兜底是必需的 —— 因为 player 可能
--       是 userid 字符串（USERID_RPCS 场景），或一个尚未生成实体的新玩家。
    print(string.format("Invalid %s RPC from (%s) %s", rpcname, player.userid or "", player.name or ""))

    --This event is for MODs that want to handle players sending invalid rpcs
--★★★【PushEvent("invalidrpc") —— 「让模组自己决定怎么处理」的设计】
--   { player = player, rpcname = rpcname } —— 载荷极简，只有身份与 RPC 名。
--   ★★ 为什么不直接踢人？三个理由（推理）：
--     1) 客户端版本差异会产生合法的参数不匹配（模组加了新参数），
--        误踢会伤害正常玩家；
--     2) 踢人的判断策略因服而异（有的服宽松、有的严格）；
--     3) 反作弊需要的信息与动作，比引擎能提供的更丰富
--        （比如累计同一玩家的 invalidrpc 次数并在阈值时踢人）。
--   ★★ 这就是为什么反作弊做成模组而不是内置功能：
--     策略易变，而 API 稳定。
--   ★⚠ 注意 TheWorld 在此处可能为 nil（世界销毁期收到 RPC）。
--     推理：HandleRPCQueue:1739 只判 sender 实体有效性，不判 TheWorld。
--     → 移植时这里应加 `if TheWorld ~= nil then`。当前是既有行为，仅标注。
--   ★ 事件数据里没有 code 数字与 tick —— 若模组需要，得从别处拿。
    TheWorld:PushEvent("invalidrpc", { player = player, rpcname = rpcname })

--★ `if BRANCH == "dev"` —— 仅开发构建才崩溃。
--   ★★ 这是一个「编译期常量分支」，生产构建里是死代码。
--     内测时任何客户端 bug 会立刻暴露成明确的服务端崩溃，
--     远好过在正式服里静默丢弃。
--   ★ BRANCH 是构建常量，全项目多处使用（如 networking.lua:307 的 BRANCH ~= "dev"）。
    if BRANCH == "dev" then
        --Internal testing
--★ assert(false, msg) —— 主动崩溃，附带与上面 print 相同的消息格式。
--   ★ 重复构造消息字符串（而非复用）是本文件的小瑕疵，无功能影响。
        assert(false, string.format("Invalid %s RPC from (%s) %s", rpcname, player.userid or "", player.name or ""))
    end
end

--★★★【printinvalidplatform —— 「平台相对坐标用错了」的专项诊断】
--   ★★ 与 printinvalid 的区别：不派发事件、不崩溃，只打日志。
--     为什么级别更低？因为它是**可容忍的竞态**，不是攻击。
--   ★ 触发条件（第 31 行）：platform_relative 为真但 platform 为 nil。
--     即「客户端说这是平台相对坐标，但没告诉我们是哪个平台」。
--   ★★ 为什么会发生（推理）：
--     客户端与服务器的实体表存在一帧的同步差。客户端发 RPC 时
--     引用的平台实体，服务端可能尚未创建或已被移除。
--     → 这是**分布式系统中固有的时序竞态**，不是客户端 bug。
--   ★★ 所以处理方式必须是「记日志并丢弃」而非「报错」。
--     这解释了为什么后续一律用 `if x ~= nil then` 静默跳过。
local function printinvalidplatform(rpcname, player, action, relative_x, relative_z, platform, platform_relative)
	if platform_relative and platform == nil then
--★★【第 32 行的三目兜底：玩家不存在时用 math.huge 保证格式化不崩】
--   local player_pt = player ~= nil and player:GetPosition() or Vector3(math.huge, math.huge, math.huge)
--   ★★ 为什么用 math.huge 而不是 nil？因为下一步要访问 .x 和 .z 做格式化，
--     那样会崩。用 math.huge 打出来就是 "inf"，一眼看出「玩家不在」。
--   ★ 这是「诊断代码不应引入新崩溃」的防御式写法 —— 值得学习。
		local player_pt = player ~= nil and player:GetPosition() or Vector3(math.huge, math.huge, math.huge)
--★ 日志里带 Player 的 tostring（实体地址）与坐标，便于定位竞态发生的时刻。
--   ★ 注意 `VecUtil_Length(relative_x, relative_z)` 算出相对偏移的模长，
--     这个值能直接告诉你客户端「以为自己在哪」。
		print(string.format("FAILED TO FIND PLATFORM IN RPC: %s, Action: %s, Player: %s (%0.2f, %0.2f), Playform Offset: %0.2f, %0.2f (len: %0.2f)", rpcname, tostring(action), tostring(player), player_pt.x, player_pt.z, relative_x, relative_z, VecUtil_Length(relative_x, relative_z)))
	end
end
--★ printinvalidplatform 结束。它与 printinvalid 的分工：
--   · printinvalid      → 类型/参数非法，可能是攻击 → 事件 + dev 断言
--   · printinvalidplatform → 平台引用缺失，正常竞态 → 仅日志

--------------------------------------------------------------------------

--★★[IsRotationValid —— 旋转角的合法性检查]
--   return rot > -math.huge and rot < math.huge
--   ★★★ 这个检查的真实目的是**排除 NaN**！
--     因为 NaN 与任何值比较都返回 false（包括与自身），
--     所以 NaN 会让两个条件同时为假 → 返回 false → 被判定为非法。
--   ★ 而 ±math.huge 也确实该被拒（无穷大的旋转会让渲染矩阵变 NaN）。
--   ★★ 这是一个很克制的实现：两个比较同时干掉了 NaN 与无穷。
--   ★ 为什么需要它？因为 rotation 影响的是玩家面朝与放置朝向，
--     一个 NaN 角度会让该玩家的所有渲染对象消失（C++ 侧矩阵运算溢出）。
--   ★ 调用点：:154（RightClick）、:294（ControllerActionButtonDeploy）、
--     :981（MakeRecipeAtPoint）、:1312（PredictGallopTrip）。
local function IsRotationValid(rot)
	return rot > -math.huge and rot < math.huge
end

--★★★★★[IsPointInRange —— 本文件最重要的安全原语，反作弊的第一道几何闸门]
--   ★★ 判定式：distsq(x, z, px, pz) <= 4096
--   ★★★ 4096 = 64²，即**允许玩家在 64 格半径内点击/交互**。
--     · 用距离平方而非距离：省一次 sqrt，4096 这个阈值也更直观。
--     · 阈值 64 相对世界尺寸（几千格）很小，但相对玩家交互范围足够；
--       ★ 64 格 ≈ 4 个屏幕距离，在 DST 的镜头尺度下是合理的「看见才能点」。
--   ★★ 为什么这个检查至关重要（推理）：
--     恶意客户端可以构造「点击地图对面那个宝箱」的 RPC。
--     若无此检查，攻击者可以：
--       · 远程开箱/远程开门（container:IsOpenedBy 的前置被绕过）
--       · 远程触发 range-check 类交互（很多组件的校验基于「攻击者在自己附近」）
--       · 通过远距离交互绕过距离衰减、视线判定
--   ★ 所以每个带坐标的 RPC 都必须过这一关。
--   ★★ 调用点清单（约 9 处）：:104、:154、:269、:294、:347、:416、:460、
--     :981、:1249、:1287。反查这些行可以验证「没有遗漏」。
--   ⚠ 缺陷 A（位置校验不等于合法性校验）：
--     这个函数只管「离得够近」，不管「能不能看得到」（无视线判定）
--     也不管「这个实体是否可交互」。那些检查在各 handler 内分散完成。
--     → 移植时应把「距离 + 视线 + 可交互性」收敛成一个统一校验器。
--   ★ 参见 01-报告/04-联机同步-模组系统-UI.md:147（对这条规则的说明）。
local function IsPointInRange(player, x, z)
    local px, py, pz = player.Transform:GetWorldPosition()
    return distsq(x, z, px, pz) <= 4096
end
--★ IsPointInRange 结束。⚠ 缺陷 A 的完整表述见 BEFORE[43]。

--★★★★★[ConvertPlatformRelativePositionToAbsolutePosition —— 平台相对坐标的安全转换]
--   ★★★ 这是本文件安全设计里最精妙的一环。
--   ── 问题 ──
--     玩家站在船上（一个移动平台）上，点击海面。此时客户端发的是
--     「相对船的偏移 (2, 3)」，而不是绝对世界坐标。
--     ★ 为什么这样设计？见 §零 的说明：船在动，若客户端发绝对坐标，
--       网络往返的 100ms 里船已经移动，点击位置就会偏。
--       发相对坐标 + 平台引用，服务器可以用**当前**船的位置还原出正确的点。
--   ── 安全要点（第 49-52 行）──
--     platform_relative 为真时，platform 必须非 nil，否则**返回 nil**。
--     ★★ 这是「成对参数」约束：标记说「这是相对的」，就必须给出「相对谁」。
--       攻击者若只传 platform_relative=true 而 platform=nil，
--       就会得到 nil，进而被所有调用方的 `if x ~= nil then` 拦下。
--   ── 转换（第 54 行）──
--     platform.entity:LocalToWorldSpace(relative_x, 0, relative_z)
--     ★ 用平台的 Transform 把局部坐标还原成世界坐标。
--     ★★ 关键安全性质：还原出的坐标**必然落在平台范围内**，
--       所以 IsPointInRange 仍然有效 —— ★ 转换不提供绕过距离检查的途径。
--       这是「先转换再校验」顺序不可颠倒的原因。
--   ── 返回约定（第 56 行）──
--     return relative_x, relative_z —— ★ 只返回两个值，丢弃了 y。
--     因为后续所有用途都是 Vector3(x, 0, z)（贴地），不需要高度。
local function ConvertPlatformRelativePositionToAbsolutePosition(relative_x, relative_z, platform, platform_relative)
--★★[platform_relative 为假 → 原样返回，什么都不做]
--   ★ 语义：客户端没有使用平台相对坐标，说明它发的是绝对坐标，直接用。
--   ★★ 注意这个函数的「静默」性：两种失败（缺平台、非法平台）
--     都体现为返回 nil 或原值，不抛异常。
--     ★ 理由：这是**正常的竞态**（见 :30 的 printinvalidplatform 注释），
--       不能因此中断整个 RPC 流程。
    if platform_relative then
--★★[平台为 nil 时裸 return —— 只返回 nil，不返回第二个值]
--   ★★ Lua 语法点：裸 `return` 等价于 `return nil`，且只返回**一个**值。
--     所以调用方的 `local x, z = Convert(...)` 会得到 x=nil, z=nil。
--     ★ 所有调用方统一写 `if x ~= nil then`（:103/:153/:268/:293/:346/:415/:459/:980/:1248/:1311），
--       与这个「返回 nil」的约定严格配对。★ 这是一个跨十处的隐式契约。
--   ★⚠ 契约脆弱：若某处误写成 `if x and z then`，
--     当 x=nil 时短路，安全；写成 `if z ~= nil` 则会崩。移植时须逐一核对。
		if platform == nil then
			return
		end
		local y
--★★[LocalToWorldSpace —— 平台 Transform 的坐标变换]
--   ★ 第二个参数写死 0：相对高度不使用（只有 x/z 两个自由度）。
--   ★★ 平台可以是**任意朝向**的（翻覆的船、直立的门），
--     所以必须走完整的 LocalToWorldSpace 而不能简单相加偏移。
--   ★ platform.entity 是实体的底层 C++ 侧对象，Transform 挂在它上面。
--   ⚠ 若 platform 是攻击者伪造的 table（见 :8 的 checkentity 注记），
--     `platform.entity:LocalToWorldSpace` 会崩（table 里没有 entity）。
--     ★★ 这其实是 checkentity 弱检查的**意外保护**：
--       伪造表会在这一行崩掉，而不是被信任。
--       → 但也意味着「崩溃即漏洞」，不应依赖它当防线。
		relative_x, y, relative_z = platform.entity:LocalToWorldSpace(relative_x, 0, relative_z)
	end
    return relative_x, relative_z
end
--★★★ 几何原语区结束。三个函数的职责边界很清楚：
--   IsRotationValid (:39) —— 旋转角是否可用（专杀 NaN）
--   IsPointInRange (:43) —— 距离是否在允许范围内（安全闸门）
--   ConvertPlatformRelative...(:48) —— 平台相对坐标还原（含成对约束）
--   ★★ 三者都是**纯函数、无副作用、无状态** —— 便于推理与测试。
--     这在本文件（大量有状态逻辑）中是一股清流。

local RPC_HANDLERS =
--★★★★★★★★★【RPC_HANDLERS —— 本文件最核心的数据结构，约 90 个处理器（59-1386）】
--   ★★★ 方向：客户端 → 服务端（对应 C2V / CLIENT_TO_SERVER）。
--   ★★ 信任级别：★★ 不可信。这是全文件唯一需要逐个校验的方向。
--     因此下面每一个 handler 的结构都是同一个三段式：
--       ① 参数校验（check*/opt*）→ 不通过则 printinvalid 并 return
--       ② 坐标还原与范围检查（若带坐标）
--       ③ 转发给组件（playercontroller / inventory / builder ...）
--   ★★★ 这个三段式的高度一致性，就是「不可信输入处理」的标准形态。
--   ★★ 表内 key 是 RPC 名（字符串），value 是函数。
--     编号在 :1391-1395 之后统一分配，本段用名字便于阅读。
--   ★★ 每个 handler 的第一个参数 player 有两种可能：
--     · 绝大多数：玩家**实体**（可直接访问 .components）
--     · 少数（USERID_RPCS 标记的）：player **userid 字符串**
--       —— 见 :1398 与 :1121 的注释（选人阶段玩家实体尚未生成）。
--   ★★ 「player.components.xxx ~= nil」的重复判空无处不在，原因：
--     RPC 可能在玩家死亡/重生的空窗期到达，此时 components 已清空。
--     ★ 这是「异步消息到达时状态可能已变」的典型防御。
--   参见 01-报告/04-联机同步-模组系统-UI.md:116-120（三通道表）。
{
    LeftClick = function(player, action, x, z, target, isreleased, controlmods, noforce, mod_name, platform, platform_relative, spellbook, spell_id)
--★★★[LeftClick —— 90 个 handler 里参数最多的一个，也是最值得逐行读的样板]
--   ★★ 13 个参数：player, action, x, z, target, isreleased, controlmods,
--     noforce, mod_name, platform, platform_relative, spellbook, spell_id
--   ★★ 参数分五类（按可信度递增）：
--     ① 枚举/整数：action（动作 ID）、spell_id（法术 ID）
--     ② 坐标：x, z（★ 需范围校验）+ platform, platform_relative（坐标修饰）
--     ③ 实体引用：target, spellbook（★ checkentity 弱检查，见 :8）
--     ④ 布尔标志：isreleased, noforce, platform_relative
--     ⑤ 字符串：mod_name（模组名）、controlmods（手柄按键位数字）
--   ★★ 为什么这么多？客户端一次点击要携带全部上下文：
--     按在哪（target）、按在哪（x,z）、按的是什么键（controlmods）、
--     按的是哪个法术（spellbook+spell_id）、来自哪个模组（mod_name）。
--   ★★ mod_name 的存在是模组系统的要求：mods_description 里的 mod_name
--     是路由键，用来把动作分发给正确的模组逻辑。
		if not (	(	--these are either all nil
--★★★★★[第 62-90 行：二元校验 —— 「要么全 nil，要么全部合法」]
--   ★★★ 这是本文件最需要理解的校验范式，与其他 handler 的单一校验不同。
--   ── 为什么是二元的？──
--     RPC 编码时，未传的参数不会出现在数据里（不存在该字段），
--     Lua 侧读出来就是 nil。所以「全 nil」是一个**合法状态**，
--     代表「客户端只发了一个空包，用于唤起 onremotehandler」（见 :97-99）。
--   ── 如果只写「全部合法」的检查会怎样？──
--     空包会被判定为非法 → onremotehandler 永远收不到 → 该机制失效。
--   ── 如果只写「全 nil」的检查会怎样？──
--     任意混合的非法载荷（比如 action 是数字但 x 是字符串）会通过。
--   ── 因此 ──
--     `if not (A or B) then 非法 end` —— 两个合法状态缺一不可。
--     ★★ 这个 (全 nil) or (全部合法) 的结构在以下 handler 中重复出现：
--       LeftClick(:62)、RightClick(:114)、ControllerActionButton(:224)、
--       ControllerAltActionButton(:304)、PredictWalking(:426)、DoActionOnMap(:1130)。
--     ★ 「哪些 handler 用二元校验」取决于「该 RPC 是否支持空包」。
						action == nil and
--★ `--these are either all nil` —— ★ 源码自己给出的解释。
--   ★ 第一个分支：13 个参数必须**全部**为 nil（有 1 个非 nil 就不成立）。
--   ★ 注意这里的 and 连接是「必须全 nil」的严格表述，
--     而下面第 77 行那个分支是「必须全部合法」。
						x == nil and
						z == nil and
						target == nil and
						isreleased == nil and
						controlmods == nil and
						noforce == nil and
						mod_name == nil and
						platform == nil and
						platform_relative == nil and
						spellbook == nil and
						spell_id == nil
					) or
--★ `) or` —— 两个分支的连接点。
--   ★★★ 读法：`if not ( (全 nil) or (全部合法) ) then → 非法`。
--     ★ 注意最外层那个 not 覆盖了整个 or，
--       所以只要**任意一个合法分支成立**就算通过。
					(	--or all validated
--★ `--or all validated` —— 第二个分支的注释。
--   ★★ 这里开始逐参数校验，注意 check 与 opt 的选择差异：
--     checknumber(action/x/z) —— 必需
--     optentity(target)         —— 可选（点空气时没有 target）
--     optbool(isreleased)       —— 可选
--     optnumber(controlmods)    —— 可选（无手柄时没有）
--     optbool(noforce)          —— 可选
--     optstring(mod_name)       —— 可选（非模组动作为 nil）
--     optentity(platform)       —— ★ 可选（不在平台上点击时）
--     checkbool(platform_relative) —— ★★ 注意这里是 checkbool **不是** optbool！
--     optentity(spellbook)      —— 可选
--     optuint(spell_id)         —— 可选
						checknumber(action) and
						checknumber(x) and
						checknumber(z) and
						optentity(target) and
						optbool(isreleased) and
						optnumber(controlmods) and
						optbool(noforce) and
						optstring(mod_name) and
						optentity(platform) and
--★★[optentity(platform) 的语义 —— 为什么可选]
--   ★ platform 可以为 nil：当玩家不在任何可站平台上时点击。
--     此时 platform_relative 也必然是 nil/false（见第 86 行）。
--   ★★ 二者的联动约束（checkbool + optentity 的组合）：
--     · platform 为 nil 时 platform_relative 必为 nil（checkbool 放行 nil）；
--     · platform_relative 为 true 时 platform 必须非 nil ——
--       ★★ 这个约束在**这里并没有被强制**！
--       checkbool(platform_relative) 只检查类型，optentity(platform) 只检查
--       「可选且是 table」，二者组合允许 platform_relative=true 且 platform=nil。
--     ★ 该组合在第 49-52 行的转换函数里被安全地降级（返回 nil），
--       并在第 101 行由 printinvalidplatform 记录为竞态。
--       → 这是「校验层放行、业务层降级」的分工，本文件严格遵守。
						checkbool(platform_relative) and
						optentity(spellbook) and
						optuint(spell_id)
					)
				)
		then
--★ 校验通过后的缩进/格式（then 换行）—— 语法细节，无语义。
            printinvalid("LeftClick", player)
            return
        end
		local playercontroller = player.components.playercontroller
--★★[playercontroller 的取得 —— 几乎所有输入类 RPC 的第一跳]
--   ★★ playercontroller 是玩家输入的总路由组件。
--   ★ 它的 OnRemoteXxx 系列方法（:98/:105/:148/:155/:174/:190/...）
--     是「已经通过校验的输入」的最终归宿。
--   ★★ 为什么不在本文件里直接调用 locomotor / inventory / builder？
--     因为 playercontroller 负责：客户端预测状态的协调、
--     action 字符串到具体动作的解析、以及各种前置条件的二次校验。
--     ★ 「RPC 层只做格式校验，语义校验在组件层」的分层在此体现。
--   参见 components/playercontroller.lua（★ 建议一并阅读该文件的 OnRemote* 系列）。
		if playercontroller ~= nil then
			if action == nil then
--★★★[action == nil → 空包分支：只调 OnRemoteLeftClick() 不带参数]
--   ★★ 这就是第 62-90 行那个「全 nil」合法状态的唯一用途：
--     客户端发一个空 LeftClick，服务端只触发 onremotehandler，
--     用来「戳一下」服务端（比如确认服务端已就绪、或触发一次重新同步）。
--   ★ 注意这里 return 得早 —— 不会走到后面的坐标处理。
--   ★★ 若没有第 62 行那个「全 nil」分支，这个分支就永远进不去（
--     会被第 92 行 printinvalid 拦掉）。两个分支是配套设计的。
				playercontroller:OnRemoteLeftClick()
				return
			end
			printinvalidplatform("LeftClick", player, action, x, z, platform, platform_relative)
--★★[printinvalidplatform —— 平台坐标竞态的诊断点]
--   ★ 注意它传的第 4/5 参数是 x, z（转换**前**的相对坐标），
--     这样日志里的偏移量才有诊断价值（若传转换后的绝对坐标就无意义了）。
--   ★★ 调用顺序：先诊断，再转换（第 102 行）。
--     顺序不可颠倒 —— 转换会覆盖 x/z 变量，事后无法还原原始载荷。
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
--★★[转换的执行点 —— 与范围检查的顺序是安全关键]
--   ★ x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
--   ★★★ 顺序必须「先转换，后 IsPointInRange」（第 104 行）：
--     因为 IsPointInRange 比较的是世界坐标。
--     若不转换就检查，平台相对坐标会与玩家世界坐标比较，
--     得到无意义的结果 —— 安全的 RPC 会被误拒，不安全的反而可能通过。
--   ★★★ 这个「先归一化再校验」的顺序在本文件出现 10 次（见 §零 清单），
--     是移植时最容易搞错的一处。
			if x ~= nil then
--★★[if x ~= nil then —— 转换失败的静默跳过]
--   ★ 这与第 50 行的「裸 return」约定配对（见 :50 的注记）。
--   ★★ 为什么不报错？因为这是正常竞态（见 :30 的分析）。
--     若在此抛错，一个客户端的时序问题会拖垮整个服务器。
				if IsPointInRange(player, x, z) then
--★★★[IsPointInRange —— 距离闸门]
--   ★ 这是「客户端能点击多远」的唯一约束。
--   ★★ 通过后第 105 行才构造 Vector3(x, 0, z) —— ★ y 恒为 0：
--     因为这是**地面**交点，实体实际落地高度由组件自己算。
					playercontroller:OnRemoteLeftClick(action, Vector3(x, 0, z), target, isreleased, controlmods, noforce, mod_name, spellbook, spell_id)
				else
--★ else 分支只打印不惩罚 —— ★ 再次体现本文件的安全哲学：
--   「超距点击」可能是客户端预测误差，不一定是攻击。
--   ★ 对比 :107 与 :92：前者只打印，后者推 invalidrpc 事件。
--     区别在于**超距是合法参数组合下的越界行为**，而非法参数是格式错误。
					print("Remote left click out of range")
				end
			end
		end
--★ playercontroller 为 nil 时静默返回（玩家已死亡/正在重生）。
--   ★ 这是本文件出现频率最高的防御句式，约 40 处。
    end,
--★ LeftClick 结束。★★★ 请把它的结构记住 ——
--   后面 89 个 handler 全都是这个骨架的变体：
--     校验 → 坐标还原 → 范围检查 → 转发组件 → 防御性判空。
--   ★★ 读懂 LeftClick 等于读懂了这个文件 60% 的内容。

--★★[RightClick —— 与 LeftClick 的对照是理解「同类变体」的最佳样本]
--   ★ 12 个参数（比 LeftClick 少一个 spell_id，多一个 rotation）。
--   ★★ 二元校验的分支数比 LeftClick 少：只有两组可选参数检查，
--     因为 RightClick **不支持空包**（没有「只触发 handler」的需求）。
--     ★ 对比第 62 行 LeftClick 的三元结构（同 3 组，这里同 2 组）——
--       → 校验的「形状」由业务需求决定，不是套模板。
--   ★★ 多出的 rotation 引入了 IsRotationValid 检查（:154），
--     这是 NaN 防护的用武之地（见 :39 的注记）。
    RightClick = function(player, action, x, z, target, rotation, isreleased, controlmods, noforce, mod_name, platform, platform_relative)
--★★★【二元校验的「两分支」结构 —— 与 :62 的 LeftClick 逐字对照】
--   第一个分支（全 nil）：11 个参数全部为 nil（第 114-125 行）；
--   第二个分支（全部合法）：checknumber/optentity/... （第 128-138 行）。
--   ★★ 注意比 LeftClick 少一个参数（无 spellbook/spell_id），
--     所以「全 nil」分支的条件项也少一个。
--   ★ 这两个 handler 的校验结构完全对称 —— 维护时须同改。
		if not (	(	--these are either all nil
						action == nil and
						x == nil and
						z == nil and
						target == nil and
						rotation == nil and
						isreleased == nil and
						controlmods == nil and
						noforce == nil and
						mod_name == nil and
						platform == nil and
						platform_relative == nil
					) or
--★ 「--or all validated」—— 第二个分支开始。
--   ★★ RightClick 的参数校验逐项（与 :76 的 LeftClick 对照）：
--     checknumber(action), checknumber(x), checknumber(z),
--     optentity(target), optnumber(rotation), optbool(isreleased),
--     optnumber(controlmods), optbool(noforce), optstring(mod_name),
--     optentity(platform), checkbool(platform_relative)
--   ★★ 与 LeftClick 唯一的多出项是 **optnumber(rotation)**
--     （右键可以指定放置朝向），其余完全一致。
					(	--or all validated
						checknumber(action) and
						checknumber(x) and
						checknumber(z) and
						optentity(target) and
						optnumber(rotation) and
						optbool(isreleased) and
						optnumber(controlmods) and
						optbool(noforce) and
						optstring(mod_name) and
						optentity(platform) and
						checkbool(platform_relative)
					)
				)
--★ 校验失败的统一出口（与 :91 的 LeftClick 结构相同）。
--   ★ printinvalid("RightClick", player) —— 打上 RPC 名，便于日志聚合。
		then
            printinvalid("RightClick", player)
            return
        end
--★ playercontroller 取得（RightClick 版，与 :95 的 LeftClick 同）。
--   ★★ 所有「点击类」RPC 的统一落点。
		local playercontroller = player.components.playercontroller
		if playercontroller ~= nil then
			if action == nil then
				playercontroller:OnRemoteRightClick()
				return
			end
			printinvalidplatform("RightClick", player, action, x, z, platform, platform_relative)
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
			if x ~= nil then
--★★★[旋转有效性与距离检查的「与」条件 —— 为什么用 and 串联]
--   if IsPointInRange(player, x, z) and (rotation == nil or IsRotationValid(rotation)) then
--   ★★ 两层含义：
--     ① and 后的失败都只是打印，不派发事件 —— 与 :106 同样的宽松处理；
--     ② rotation == nil 短路 —— 「不传旋转」是合法的，只有传了才校验。
--   ★★ 注意失败时的 else 分支（第 156-158 行）打印的是 "out of range"，
--     即使真正的原因是「旋转是 NaN」。⚠ 日志文案与原因不匹配，
--     排查时会误导（以为距离有问题）。属轻微诊断缺陷，仅标注。
				if IsPointInRange(player, x, z) and (rotation == nil or IsRotationValid(rotation)) then
					playercontroller:OnRemoteRightClick(action, Vector3(x, 0, z), target, rotation, isreleased, controlmods, noforce, mod_name)
				else
					print("Remote right click out of range")
				end
			end
		end
    end,
--★ RightClick 结束。★★ 与 LeftClick 的对照小结（★ 两个最重要的 handler）：
--   · 共同点：二元校验 + 平台相对转换 + 范围检查 + 组件判空；
--   · 差异点：RightClick 多一个 rotation 校验（IsRotationValid）。
--   ★★ 理解这两处 = 理解本文件 60% 的 handler 结构。

--★★[ActionButton —— 「无坐标」的输入：只验参数不验距离]
--   ★★ 这是本文件里最简单的一类 handler：没有 x/z，因此不需要
--     ConvertPlatformRelativePositionToAbsolutePosition，也不需要 IsPointInRange。
--   ★★ 全部使用 opt* 谓词，没有「全 nil」分支 ——
--     因为「无坐标输入」没有空包语义（action 就是必需的）。
--   ★ 语义：点的是 UI 按钮（背包/建造栏），不是场景里的东西。
    ActionButton = function(player, action, target, isreleased, noforce, mod_name)
--★ 单行形式的 `if not (...) then` —— 与 LeftClick 的多行形式等价，
--   只是排版不同。★ 本文件两种写法混用，阅读时按语义而非排版去对应。
        if not (optnumber(action) and
                optentity(target) and
                optbool(isreleased) and
                optbool(noforce) and
                optstring(mod_name)) then
            printinvalid("ActionButton", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteActionButton(action, target, isreleased, noforce, mod_name)
        end
    end,

--★★[原注释 "V2C: isleftmouse & isreleased at the end because added a lot later"]
--   ★★★ 这条注释记录了一次**协议演进**，信息量很大：
--     · isleftmouse 与 isreleased 是**后加的两个参数**；
--     · 加在参数列表**末尾**而不是中间；
--     · ★★ 原因：RPC 的参数是按位置编码的。
--       若把新参数插在中间，所有旧客户端发来的参数位置会全部错位。
--     · ★★ 这就是「RPC 只能末尾追加参数」这条铁律的由来。
--   ★★ 与本文件 §四 的编号机制配套：
--     编号靠 orderedPairs 一次性分配（终身绑定），
--     参数靠位置编码（只能追加），★ 两者都不可动态变更。
--   ★→ 移植时的铁律：★ 任何 RPC 签名变更只能追加，且必须同时更新客户端。
	--V2C: isleftmouse & isreleased at the end because added a lot later
	AttackButton = function(player, target, forceattack, noforce, isleftmouse, isreleased)
        if not (optentity(target) and
                optbool(forceattack) and
				optbool(noforce) and
				optbool(isleftmouse) and
				optbool(isreleased)) then
            printinvalid("AttackButton", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
			playercontroller:OnRemoteAttackButton(target, forceattack, noforce, isleftmouse, isreleased)
        end
    end,

--★★[InspectButton —— 「必须有个东西可看」的最小 handler]
--   ★ 唯一校验是 checkentity(target)：**必须**有 target，不能省。
--   ★★ 因为「查看」这个动作没有「查看空气」的可能，
--     所以用 check 而非 opt —— ★ 校验强度由语义决定（呼应 :15-16 的说明）。
    InspectButton = function(player, target)
        if not checkentity(target) then
            printinvalid("InspectButton", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteInspectButton(target)
        end
    end,

--★★[ResurrectButton —— 零校验的 handler]
--   ★ 没有 printinvalid，没有参数校验（本来就没有参数）。
--   ★★★ 为什么可以零校验？推理：
--     · 没有任何可被滥用的载荷（无参数）；
--     · 复活本身有完整的前置条件检查（在复活组件里：是否死亡、是否在墓碑旁）；
--     · 重复调用是幂等的。
--   ★★ 这是「校验强度与攻击面成正比」的正确体现：
--     不是所有 handler 都需要同样的防御强度。
    ResurrectButton = function(player)
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteResurrectButton()
        end
    end,

--★ CharacterCommandWheelButton —— 角色指令轮盘（切换角色时弹出的操作菜单）。
--   ★ 命名惯例：xxxButton = 「按下了 xxx 按钮」。全文件统一。
	CharacterCommandWheelButton = function(player, target)
		if not checkentity(target) then
			printinvalid("CharacterCommandWheelButton", player)
			return
		end
		local playercontroller = player.components.playercontroller
		if playercontroller then
			playercontroller:OnRemoteCharacterCommandWheelButton(target)
		end
	end,

--★★[ControllerActionButton —— 手柄版 ActionButton，带二元校验]
--   ★★ 注意这里的二元校验与 :163 的手柄版 ActionButton **不同**：
--     ActionButton（:164）用的是纯 opt*；
--     ControllerActionButton（本行）用的是「全 nil or 全部合法」。
--   ★★ 为什么手柄版需要空包？推理：
--     手柄的「按下/松开」用同一个按钮 + action=nil 表达，
--     所以客户端会发「只有 isreleased/noforce 没有 action」的组合 ——
--     ★ 这正是「全 nil」分支要覆盖的场景之一。
--     ⚠ 但注意本行的「全 nil」分支要求 isreleased 与 noforce 也为 nil，
--       若客户端只传 isreleased=false，它会走到第二分支并因
--       `checknumber(action)` 失败而被判非法。
--       → 说明客户端实际上不会这么发（协议约定）。这是「契约靠约定」的脆弱处。
    ControllerActionButton = function(player, action, target, isreleased, noforce, mod_name)
--★★★【ControllerActionButton 校验区 —— 三分支嵌套的「格式怪」但语义清晰】
--   ★★★ 第 224-238 行的括号层次：
--     if not (
--         (   ① 全 nil 检查（第 225-229 行）
--         ) or
--         (   ② 全部合法检查（第 231-237 行）
--         )
--     ) then ... end
--   ★★★ 注意每个分支各自带一层括号，最后 `) or` 收尾。
--     ★ 这不是笔误 —— 是为了在「分支内含多个 and」时保持可读性。
--   ★★★ 与 :62 的 LeftClick 几乎同构（同样的二元校验形态）。
		if not (	(	--these are either all nil
						action == nil and
						target == nil and
						isreleased == nil and
						noforce == nil and
						mod_name == nil
					) or
--★ 「--or all validated」—— 第二分支。
--   ★★ ControllerActionButton 的参数校验（注意比鼠标版少几个）：
--     checknumber(action) —— 必需
--     checkentity(target)  —— ★★ 必需（不是 optentity！）
--     optbool(isreleased), optbool(noforce), optstring(mod_name)
--   ★★ 关键差异：★ target 用 **checkentity**（不可省略），
--     而鼠标版 ControllerActionButton 的对应项（第 232 行）也是 checkentity，
--     ★ 但鼠标版 ActionButton（:165）用的是 optentity。
--     → 手柄版的「操作对象」是必须明确的，鼠标版可以点空。
					(	--or all validated
						checknumber(action) and
						checkentity(target) and
						optbool(isreleased) and
						optbool(noforce) and
						optstring(mod_name)
					)
				)
		then
            printinvalid("ControllerActionButton", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteControllerActionButton(action, target, isreleased, noforce, mod_name)
        end
    end,

--★★[ControllerActionButtonPoint —— 手柄版的「点击场景某点」]
--   ★ 参数比 ControllerActionButton 多出 x, z, platform, platform_relative,
--     isspecial, spellbook, spell_id —— ★ 全部用 check*/opt* 无二元校验。
--   ★★ 与 LeftClick 的关键差异：LeftClick 支持空包（:97），本函数不支持。
--     推理：手柄的点击总是有目标点的，不需要「空包唤起 handler」语义。
--★★★【ControllerActionButtonPoint 校验区 —— 「全参数 opt」的宽松形态】
--   ★★★ 第 250-260 行：**没有**二元校验，只有一串 opt*/check* 的 and。
--     checknumber(action), checknumber(x), checknumber(z),
--     optbool(isreleased), optbool(noforce), optstring(mod_name),
--     optentity(platform), checkbool(platform_relative),
--     optbool(isspecial), optentity(spellbook), optuint(spell_id)
--   ★★ 与 ControllerActionButton（:224）的对比：
--     · 有二元校验（:224）↔ 无二元校验（本行）
--     ★ 因为「点位点击」总是有目标点的，不需要「空包唤起 handler」。
--   ★★ isspecial 是 optbool（可选）—— 手柄的「特殊键」标志。
	ControllerActionButtonPoint = function(player, action, x, z, isreleased, noforce, mod_name, platform, platform_relative, isspecial, spellbook, spell_id)
        if not (checknumber(action) and
                checknumber(x) and
                checknumber(z) and
                optbool(isreleased) and
                optbool(noforce) and
                optstring(mod_name) and
				optentity(platform) and
				checkbool(platform_relative) and
				optbool(isspecial) and
				optentity(spellbook) and
				optuint(spell_id)) then
            printinvalid("ControllerActionButtonPoint", player)
            return
        end
		local playercontroller = player.components.playercontroller
		if playercontroller ~= nil then
--★★[ControllerActionButtonPoint 的坐标处理 —— 与 :101-105 结构一致]
--   ★ printinvalidplatform → Convert（:267）→ if x ~= nil（:268）→ IsPointInRange（:269）
--   ★★ 与 LeftClick（:101-104）的四步流程逐字对应。
--   ★ 这一组「转换→检查→转发」的序列在文件里出现 10 次，是本文件最重复的模式。
			printinvalidplatform("ControllerActionButtonPoint", player, action, x, z, platform, platform_relative)
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
			if x ~= nil then
				if IsPointInRange(player, x, z) then
					playercontroller:OnRemoteControllerActionButtonPoint(action, Vector3(x, 0, z), isreleased, noforce, mod_name, isspecial, spellbook, spell_id)
				else
					print("Remote controller action button point out of range")
				end
			end
		end
    end,

--★★[ControllerActionButtonDeploy —— 「放置类」动作：多了 invobject 与 rotation]
--   ★ invobject 用 **checkentity**（必需）：放置动作必须指明要放什么。
--   ★ rotation 用 **optnumber**（可选）：不旋转时不传。
--   ★★ 第 291 行传给 printinvalidplatform 的 action 参数写死 nil：
--     因为诊断只需要 x/z/platform/platform_relative 四个信息。
    ControllerActionButtonDeploy = function(player, invobject, x, z, rotation, isreleased, platform, platform_relative)
        if not (checkentity(invobject) and
                checknumber(x) and
                checknumber(z) and
                optnumber(rotation) and
                optbool(isreleased) and
				optentity(platform) and
				checkbool(platform_relative)) then
            printinvalid("ControllerActionButtonDeploy", player)
            return
        end
		local playercontroller = player.components.playercontroller
		if playercontroller ~= nil then
			printinvalidplatform("ControllerActionButtonDeploy", player, nil, x, z, platform, platform_relative)
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
			if x ~= nil then
				if IsPointInRange(player, x, z) and (rotation == nil or IsRotationValid(rotation)) then
					playercontroller:OnRemoteControllerActionButtonDeploy(invobject, Vector3(x, 0, z), rotation, isreleased)
				else
					print("Remote controller action button deploy out of range")
				end
			end
		end
    end,
--★★ ControllerActionButton / ControllerActionButtonPoint 结束。
--   ★★ 手柄版与鼠标版是**平行实现**（同样的三层校验 + 坐标处理）。

--★★[ControllerAltActionButton —— Alt 键版，与 ActionButton 完全同构]
--   ★★ 与 :223 的 ControllerActionButton 逐字同构（除了函数名）。
--   ★★ 这是一对**平行实现**：同模版复制两份。
--   ★★ 风险（★ 移植必须注意）：加新动作类型时要**同改两处**，
--     否则手柄 Alt 键路径与普通路径行为不一致，表现为「手柄玩家少一个动作」。
--   ★ 与 locomotor.lua:782/882 的 PreviewAction / PushAction 是同一类问题，
--     ★ 这正是 locomotor 注释里点名的「移植时最需重写」的模式。
--★★★【ControllerAltActionButton —— 与 :223 逐字平行的「Alt 键」版】
--   ★★★ 校验代码与 ControllerActionButton（:224-242）完全相同。
--   ★★★ ★★ 这是本文件最需要警惕的一对平行实现：
--     · 两处代码几乎完全复制，只有函数名不同；
--     · ★ 未来若新增一种「手柄 Alt 键动作」，必须**同时**改这两处；
--       否则手柄 Alt 键玩家会遇到「某个动作无法触发」。
--   ★★ 这类「平行实现」是移植到新引擎时的常见 bug 源：
--     修正一个忘了另一个，就会出现「特定输入设备的功能缺失」。
--   ★ 参见 locomotor.lua:782/882 的 PreviewAction/PushAction 平行实现注记。
    ControllerAltActionButton = function(player, action, target, isreleased, noforce, mod_name)
		if not (	(	--these are either all nil
						action == nil and
						target == nil and
						isreleased == nil and
						noforce == nil and
						mod_name == nil
					) or
--★ 「--or all validated」—— 第二分支（与 :231 的第二分支逐字相同）。
--   ★★ 第 312-316 行与 ControllerActionButton 的 :232-236 一字不差。
--     ★ 这就是「平行实现」的直接证据 —— 加新参数时必须记得两处同改。
					(	--or all validated
						checknumber(action) and
						checkentity(target) and
						optbool(isreleased) and
						optbool(noforce) and
						optstring(mod_name)
					)
				)
--★ 校验失败出口（与 :240 相同）：printinvalid("ControllerAltActionButton", player)。
		then
            printinvalid("ControllerAltActionButton", player)
            return
        end
--★ playercontroller 取得（与 :243 同）：local playercontroller = player.components.playercontroller
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteControllerAltActionButton(action, target, isreleased, noforce, mod_name)
        end
--★ OnRemoteControllerAltActionButton 转发（与 :245 平行）。
    end,

--★★[ControllerAltActionButtonPoint —— Alt 键 + 点位，三者中参数最全]
--   ★★ 比 ControllerActionButtonPoint（:249）少 spellbook/spell_id，多 isspecial；
--     但参数顺序不同（isspecial 在 mod_name 之前）。
--   ⚠ 参数顺序不一致这件事本身值得注意：
--     RPC 按位置编码，两处若要「合并语义」必须严格对齐实际调用方，
--     否则会出现「值互换」的静默 bug。
    ControllerAltActionButtonPoint = function(player, action, x, z, isreleased, noforce, isspecial, mod_name, platform, platform_relative)
--★★★[ControllerAltActionButtonPoint 校验区 —— 「Alt 键 + 点位」的组合形态]
--   ★★ 参数校验（:330-338）：
--     checknumber(action), checknumber(x), checknumber(z),
--     optbool(isreleased), optbool(noforce), optbool(isspecial),
--     optstring(mod_name), optentity(platform), checkbool(platform_relative)
--   ★★ 与 ControllerActionButtonPoint（:250）对照，本 handler：
--     · ★★ 多了 isspecial（且位置在 mod_name 之前，:335）；
--     · ★★ 少了 spellbook / spell_id（Alt 键不触发法术）。
--   ★★★ 这正是「平行实现 + 各自演化」的结果：
--     两者起始相同（复制粘贴），后续各自增删参数。
--     ★ 后果：读代码时容易以为它们「应该一样」而误判。
        if not (checknumber(action) and
                checknumber(x) and
                checknumber(z) and
                optbool(isreleased) and
                optbool(noforce) and
                optbool(isspecial) and
                optstring(mod_name) and
				optentity(platform) and
				checkbool(platform_relative)) then
            printinvalid("ControllerAltActionButtonPoint", player)
            return
        end
		local playercontroller = player.components.playercontroller
		if playercontroller ~= nil then
			printinvalidplatform("ControllerAltActionButtonPoint", player, action, x, z, platform, platform_relative)
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
			if x ~= nil then
				if IsPointInRange(player, x, z) then
					playercontroller:OnRemoteControllerAltActionButtonPoint(action, Vector3(x, 0, z), isreleased, noforce, isspecial, mod_name)
				else
					print("Remote controller alt action button point out of range")
				end
			end
		end
    end,
--★★ ControllerAltActionButton / ControllerAltActionButtonPoint 结束。
--   ★★ 「Alt 键版」与「普通手柄版」又是平行实现。
--   ★★ ★ 至此手柄系共 6 个 handler，全部是鼠标版的平行实现：
--     · ControllerActionButton        ↔ ActionButton
--     · ControllerActionButtonPoint   ↔ LeftClick
--     · ControllerActionButtonDeploy  ↔ RightClick（放置）
--     · ControllerAltActionButton     ↔ ★（无鼠标对应）
--     · ControllerAltActionButtonPoint↔ ★（无鼠标对应）
--     · ControllerAttackButton        ↔ AttackButton
--   ★→ 移植时新增动作必须成对添加，★ 否则手柄玩家功能缺失。

--★★★[ControllerAttackButton —— 唯一允许 target == true 的 handler]
--   if not ((target == true or optentity(target)) and ...)
--   ★★★ 这个 target == true 是**特设的哨兵值**：
--     「攻击」这个动作的语义就是「对着攻击方向」，不一定有具体目标实体。
--     客户端传 true 表示「无目标的前方攻击」。
--   ★★ 为什么不用 nil？因为 nil 会被 optentity 放行（表示「可选参数没传」），
--     而这里需要区分「没传」与「明确表示无目标」两种语义 ——
--     ★★ 用 true 作为「明确的无目标」哨兵，是用值域区分语义的经典手法。
--   ★ 注意 AttackButton（:179）用的是纯 optentity，没有这个哨兵 ——
--     ★ 两个版本的攻击语义不同，不能互相套用。
    ControllerAttackButton = function(player, target, isreleased, noforce)
        if not ((target == true or optentity(target)) and
                optbool(isreleased) and
                optbool(noforce)) then
            printinvalid("ControllerAttackButton", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteControllerAttackButton(target, isreleased, noforce)
        end
    end,

--★★[StopControl —— 手柄按键释放的统一入口]
--   control 用 checknumber（必需）：释放必须指明是哪个按键。
--   ★★ 与 StopAllControls（:380）成对：前者精确释放一个，后者全释放。
--     ★ 这对 API 体现「能精确就不粗暴」的输入处理原则。
    StopControl = function(player, control)
        if not checknumber(control) then
            printinvalid("StopControl", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteStopControl(control)
        end
    end,

--★ StopAllControls —— 零参数、零校验（同 :205 的理由）。
--   ★★ 语义：玩家松开所有手柄键（或切换设备时），一次性清理。
--     ★ 这是「防御性全清」API，防止按键状态卡在按下。
    StopAllControls = function(player)
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteStopAllControls()
        end
    end,

--★★★[DirectWalking —— 「方向」而非「位置」，校验方式完全不同]
--   ★★★ 第 395 行：`if x * x + z * z < 1.01 then`
--   ★★ 关键区别：x/z 是**方向向量**，不是世界坐标。
--     所以不能用 IsPointInRange（那个要世界坐标），
--     而是判「向量模长是否接近 1」。
--   ★ 1.01 = 1² + 0.01² → 允许 1% 的浮点误差。
--     ★★ 为什么这里能接受「近似单位向量」而不严格校验：
--       方向会被后续代码归一化使用（steer），误差无害。
--   ★★ 第 396 行的原注释极有价值：
--     "x and z are directions, not positions, so we don't need it to
--      be platform relative"
--     → 方向与平台无关（船在动但「往前」这个方向不变），
--       所以本 RPC 不接受 platform 参数。
--   ★ 这解释了「为什么有些 RPC 带平台参数、有些不带」：
--     ★ 判据是「这个量是位置还是方向」。位置需要平台修正，方向不需要。
--   ★★ 安全影响：因为不涉及世界坐标，DirectWalking 无法被用于远程操作 ——
--     它只能让玩家朝某个方向走。这是「按语义选择校验强度」的又一例。
    DirectWalking = function(player, x, z)
        if not (checknumber(x) and
                checknumber(z)) then
            printinvalid("DirectWalking", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            if x * x + z * z < 1.01 then
                playercontroller:OnRemoteDirectWalking(x, z) -- x and z are directions, not positions, so we don't need it to be platform relative
            else
                print("Remote direct walking out of range")
            end
        end
    end,

--★★[DragWalking —— 「拖拽摇杆」版，坐标 + 平台，组合了两种语义]
--   ★★ 奇特的命名：Drag 指「摇杆被拖到某个偏移位置」，
--     此时 x/z 是**屏幕空间的偏移量**，但被当作世界坐标处理。
--   ★★ 因为要过 IsPointInRange，它走完整的「转换 + 范围检查」流程。
--     推理：拖拽偏移量被直接当作目标点使用，语义上接近「走向某处」。
--   ★ 与 DirectWalking 的对比：同属移动类，一个走方向校验，一个走位置校验。
    DragWalking = function(player, x, z, platform, platform_relative)
        if not (checknumber(x) and
                checknumber(z) and
				optentity(platform) and
				checkbool(platform_relative)) then
            printinvalid("DragWalking", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
			printinvalidplatform("DragWalking", player, nil, x, z, platform, platform_relative)
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
			if x ~= nil then
				if IsPointInRange(player, x, z) then
					playercontroller:OnRemoteDragWalking(x, z)
				else
					print("Remote drag walking out of range")
				end
			end
        end
    end,

--★★★★★[PredictWalking —— 客户端预测的行走包，本文件最语义复杂的 RPC]
--   ★★★ 它承载「客户端预测移动」的上报，是客户端预测机制的数据入口。
--   ★★ 参数：x, z（目标点）, isdirectwalking（方向还是位置）、isstart（开始）、
--     platform, platform_relative, overridemovetime（覆盖移动计时器）、isstop（停止）
--   ★★ 三元校验结构（第 426-447 行）—— 比 LeftClick 更复杂：
--     分支①：x/z/isdirectwalking/platform/platform_relative 全 nil 且 (isstart or isstop)
--             ★ 注意最后这个「二者之一必为真」—— 因为「开始」与「停止」
--               是这个 RPC 的真正目的，坐标反而可有可无。
--     分支②：x/z 是数字且 isdirectwalking/platform_relative 是 bool（非 nil）
--             ★★ 分支②用的是 **checkbool** 不是 optbool ——
--               意味着「传坐标就必须同时传方向模式与平台标志」，不许省略。
--     公共部分（第 442-446 行）：isstart 必须是 bool，overridemovetime 可选数字，
--               isstop 可选 bool。
--   ★★★ 最外层的括号结构是 `not ( (A or B) and C )`：
--     → 「（要么空包要么全对）**并且**公共部分合法」才算通过。
--       ★ 两个维度是**与**关系，而每个维度内部是**或**关系 ——
--         这是本文件最复杂的校验表达式，但结构其实是清晰的。
	PredictWalking = function(player, x, z, isdirectwalking, isstart, platform, platform_relative, overridemovetime, isstop)
--★ PredictWalking 结束。★★★ 回看它的三元校验（第 426-447 行）：
--   〔全nil 且 isstart/isstop〕 or 〔坐标全对〕 —— 然后 and 〔公共部分合法〕
--   ★★ 本文件最复杂的校验表达式，但只有两个维度：
--     「载荷形态」是或，「公共字段」是与。
--★★★【PredictWalking 的三元校验 —— ★★★ 本文件最复杂的校验表达式】
--   ★★★ 第 426-447 行的结构拆解（三层）：
--   ── 外层：not ( 载荷形态合法  and  公共字段合法 ) ──
--   ── 中层（载荷形态）：( 分支① ) or ( 分支② ) ──
--   ── 分支①（第 426-432 行）：全 nil 且 (isstart or isstop)
--     ★ x, z, isdirectwalking, platform, platform_relative 全为 nil；
--     ★★ 且 isstart 或 isstop 至少一个为真 ——
--       「无坐标」的模式必须表明意图（是开始预测还是停止预测）。
--   ── 分支②（第 434-440 行）：坐标齐备且类型严格
--     ★★ checkbool(isdirectwalking) / checkbool(platform_relative)
--       （**不是** optbool）—— 传了坐标就必须同时传这两个标志。
--   ── 公共部分（第 442-446 行）：isstart 必需，overridemovetime 可选，isstop 可选 ──
--   ★★★ 语义总结：「预测 RPC 有两种模式 ——
--     · 无坐标模式：只说「开始/停止」，不说「去哪里」；
--     · 有坐标模式：说「去哪里 + 是方向还是位置 + 是否平台相对 + 何时开始/停止」。
--   ★★ 这就是「一个 RPC 承载多种语义」的设计 —— 用参数的组合表达不同的子命令。
		if not (	(	(	--these are either all nil
--★★★[校验的最外层起点 —— ★ 括号层次的第一个「not (」]
--   ★★ 第 427 行的 `if not (` 开启了整个校验表达式，
--     ★ 对应第 447 行的 `)` 收尾（完整三层结构见 :426 的拆解）。
--   ★★ 读法：not ( (分支① or 分支②) and 公共部分 )
--     → 只有「形态合法」**且**「公共字段合法」才算通过。
							x == nil and
							z == nil and
							isdirectwalking == nil and
							platform == nil and
							platform_relative == nil and
							(isstart or isstop) -- one of these must be true
						) or
--★ 「--or all validated」—— ★ 第二个分支：坐标齐备且类型严格。
--   ★★★ 第 435-439 行逐项：
--     checknumber(x) 且 checknumber(z) —— 坐标必需且为数字
--     checkbool(isdirectwalking)   —— ★★ 不是 optbool：传坐标就必须传它
--     optentity(platform)          —— 平台可选
--     checkbool(platform_relative) —— ★★ 不是 optbool：必须传
--   ★★ 两个 checkbool（严格）是本分支与分支①的关键区别：
--     · 分支①（全 nil）里它们可以是 nil；
--     · ★ 分支②（有坐标）里它们必须是 bool —— 「有坐标就要说清坐标的含义」。
--   ★★ 这体现了「参数之间的语义约束」比「单个参数的类型」更值得校验。
						(	--or all validated
							checknumber(x) and
							checknumber(z) and
							checkbool(isdirectwalking) and
							optentity(platform) and
							checkbool(platform_relative)
						)
					) and
--★ 「--common for both cases」—— ★ 公共部分：不分分支，两种模式都要满足。
--   ★★★ 第 443-445 行：
--     checkbool(isstart)         —— isstart 是**必需 bool**（两种模式都要说明）
--     optnumber(overridemovetime) —— 可选：客户端可覆盖「移动计时器」
--     optbool(isstop)            —— 可选：停止标志
--   ★★ 理解：无论「无坐标」还是「有坐标」，都必须表明「这是开始还是继续/停止」
--     —— 预测协议需要知道状态机的转换方向。
					(	--common for both cases
						checkbool(isstart) and
						optnumber(overridemovetime) and
						optbool(isstop)
--★ 公共部分结束，第 447 行的 `)` 闭合最外层 not。
					)
				)
		then
            printinvalid("PredictWalking", player)
            return
        end
--★★★[remote_predicting 门禁 —— 预测协议的服务端开关]
--   if not playercontroller.remote_predicting then printinvalid(...); return
--   ★★★ 语义：客户端只有被服务端**开启**了预测，才能发 PredictWalking。
--   ★★ 为什么需要这个门禁（推理）：
--     客户端预测意味着「客户端先动、稍后被服务端纠正」。
--     如果服务端没有开启预测却收到预测包，说明客户端状态异常，
--     或攻击者在伪造预测包（可能用来插队动作）。
--     → 这是一个**协议握手**：先由服务端 SetMovementPredictionEnabled(:954)
--       开启，客户端才被允许发送。
--   ★★ 与 :954 的 SetMovementPredictionEnabled 构成一对，
--     完整的预测协议 = 服务端下发开关 + 客户端上报 + 服务端门禁。
--   ★ 交叉引用：locomotor.lua 的客户端预测相关章节；
--     components/playercontroller.lua 的 remote_predicting 字段。
--   ★★ 注意这里用的是 printinvalid（推事件 + 可能 dev 崩溃），
--     比「超距」严重 —— 因为协议握手被绕过更像攻击。
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
			if not playercontroller.remote_predicting then
				printinvalid("PredictWalking", player)
				return
--★ `elseif x then` —— 分流：有坐标走完整流程，无坐标走停止流程。
--   ★★ 这与第 426 行分支①的 `(isstart or isstop)` 呼应：
--     没有坐标时，一定是「开始预测」或「停止预测」这类无坐标指令。
			elseif x then
				printinvalidplatform("PredictWalking", player, nil, x, z, platform, platform_relative)
				local x1, z1 = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
--★★★[PredictWalking 的范围检查用「局部变量」而非覆盖原变量]
--   local x1, z1 = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
--   if x1 and not IsPointInRange(player, x1, z1) then
--   ★★★ 与 LeftClick（:102）的区别很重要：
--     · LeftClick：转换后**覆盖** x, z（因为原值不再需要）；
--     · 这里：转换到 x1/z1 **保留**原 x, z。
--   ★★ 为什么必须保留？见第 465 行：
--     传给组件的是 (x, z, ...) —— 也就是**平台相对坐标本身**，
--     同时另行传 platform（`platform_relative and platform or nil`）。
--     ★★★ 这是因为预测逻辑需要「相对平台的坐标 + 平台引用」，
--       由组件自己决定怎么还原 —— 服务端不提前还原成世界坐标。
--   ★★ 结论：同样的转换，在此只用于「验证坐标合法性」，不用于「使用坐标」。
--     推理：预测是对齐本地与服务端，组件需要同时拿到两种表示。
--   ★ 与 :460 行的 `if x1 and` —— 转换失败（x1 为 nil）时**不视为错误**，
--     直接放行进入第 465 行。⚠ 这与 LeftClick 的「失败即跳过」相反。
--     理由推测：预测包可能合法地不带坐标（停止预测），此时 x 本身就是 nil。
--     → 两条路径的容错策略不同，是有意的。
				if x1 and not IsPointInRange(player, x1, z1) then
					print("Remote predict walking out of range")
					return
				end
			end
--★★★[第 465 行：七个参数的转发，含一个精妙的条件表达式]
--   playercontroller:OnRemotePredictWalking(x, z, isdirectwalking, isstart,
--                                          platform_relative and platform or nil,
--                                          overridemovetime, isstop)
--   ★★★ `platform_relative and platform or nil` —— Lua 三目惯用法：
--     · platform_relative 为 true → 取 platform；
--     · platform_relative 为 false/nil → 取 nil；
--     ★★ 效果：只把平台传给「确实声明了平台相对」的调用。
--       若无条件传 platform，组件就必须自己判断是否平台相对，
--       判断责任被推给了下游。
--   ★★ 这是「在边界处归一化数据」的又一例（与 :102 的「先转换再校验」同源）。
--   ★ 参数顺序与 :425 的签名一致 —— 注意 x/z 是原始相对坐标（见 :460 注记）。
			playercontroller:OnRemotePredictWalking(x, z, isdirectwalking, isstart, platform_relative and platform or nil, overridemovetime, isstop)
        end
    end,
--★★ PredictWalking 结束。★★★ 它是「客户端预测」的数据入口，
--   ★★ 完整的预测协议链路（跨三个文件）：
--     · networking/networkclientrpc: SetMovementPredictionEnabled(:954) 下发开关；
--     · 本文件 :425 PredictWalking 上报预测；
--     · components/playercontroller.lua: OnRemotePredictWalking 执行与校正。
--   ★ 参见 locomotor.lua 的客户端预测章节。

--★★[PredictOverrideLocomote —— 预测的「覆盖方向」微调]
--   ★ 单个数值参数 dir（方向），optnumber 校验。
--   ★★ 语义：客户端预测移动时，额外上报一个「我希望转向哪」，
--     用于让服务端对齐客户端的转身决策（避免转身时来回抖动）。
--   ★ 这是「预测 + 校正」体系里的**方向同步**，与位置同步分离。
	PredictOverrideLocomote = function(player, dir)
		if not optnumber(dir) then
			printinvalid("PredictOverrideLocomote", player)
			return
		end
		local playercontroller = player.components.playercontroller
		if playercontroller ~= nil then
			playercontroller:OnRemotePredictOverrideLocomote(dir)
		end
	end,

--★★[StrafeFacing —— 唯一绕过 playercontroller 直接进 locomotor 的 handler]
--   ★★ 第 485-488 行：取 locomotor（不是 playercontroller）并调 OnStrafeFacingChanged。
--   ★★★ 唯一被检查的语义条件：
--     `player.sg and player.sg:HasStateTag("busy")` —— ★ 忙碌时不接受转向。
--     理由：玩家在演奏乐器/被束缚等「busy」状态时，转向是被禁的。
--   ★★ 这是「行为状态检查」的典型：不是检查数据合法性，而是检查
--     「当前是否允许这个动作」。★ 参见 locomotor.lua 的 stategraph 说明。
--   ★★ 为什么只有它直接进 locomotor？因为转向是移动的子能力，
--     playercontroller 不该为「斜向面朝」开个专属路由。
--   ⚠ player.sg 可能为 nil（实体尚未完全初始化），此时条件为 nil（假）→
--     会执行转向。⚠ 这是一个潜在的「未初始化窗口」，仅标注。
	StrafeFacing = function(player, dir)
		if not checknumber(dir) then
			printinvalid("StrafeFacing", player)
			return
		end
		local locomotor = player.components.locomotor
		if locomotor and not (player.sg and player.sg:HasStateTag("busy")) then
			locomotor:OnStrafeFacingChanged(dir)
		end
	end,
--★ StrafeFacing 结束。★ 本文件到这里（约 490 行）覆盖了全部「鼠标+手柄」输入类 RPC。
--   ★★ 注意规律：
--     · 带坐标的 → 转换 + 范围检查
--     · 带方向的 → 范数检查（或缺省）
--     · 手柄版 = 鼠标版的平行实现（★ 加动作要同改）

--★★★★★[StartHop —— 「成对参数约束」的最佳范例]
--   ★★★ 第 501-502 行是一对互斥检查：
--     if has_platform and (platform == nil or platform.components.walkableplatform == nil)
--         then return end   -- 声明有平台却没给平台 → 拒绝
--     if platform ~= nil and not has_platform
--         then return end   -- 给了平台却没声明 → 拒绝
--   ★★★ 语义：has_platform 是一次性 RPC 参数（因为 Lua 表里 nil 无法
--     与 false 区分，必须用独立布尔传递「有无」）；
--     而 platform 是实体引用。★ 二者必须一致，故需要两个方向都检查。
--   ★★★ 这正是 :48 转换函数里「platform_relative 为真则 platform 必非 nil」
--     那条约束的**完整实现**（转换函数只做降级，这里做主动拒绝）。
--   ★ 第 502 行的 platform.components.walkableplatform 检查：
--     ★★ 确认这个实体**真的是可站平台**（而非任意实体）。
--     这是 checkentity 弱检查（:8）被加强的一处 ——
--     ★ 说明「弱谓词 + 业务侧补强」确实是本文件的既定策略。
--   ★★ 与 :999 的 `if playercontroller == nil then return end` 相比，
--     这里用了紧凑的单行写法。两种风格并存，无语义差别。
    StartHop = function(player, x, z, platform, has_platform)
        if not (checknumber(x) and
                checknumber(z) and
                optentity(platform) and
                checkbool(has_platform)) then
            printinvalid("StartHop", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller == nil then return end
        if has_platform and (platform == nil or platform.components.walkableplatform == nil) then return end
        if platform ~= nil and not has_platform then return end

        playercontroller:OnRemoteStartHop(x, z, platform)

    end,

--★★[SteerBoat —— 船的操舵，同样是「方向」而非「位置」]
--   ★★ 与 DirectWalking（:387）同构：dir_x, dir_z 是方向向量。
--   ★★ 但缺少长度校验！
--     ⚠ 缺陷补充（同类 A 的轻微版）：DirectWalking 判了 `x*x+z*z < 1.01`，
--     SteerBoat 没有对应的范数检查。若 dir 传 (1e9, 1e9)，
--     steeringwheeluser:SteerInDir 会拿到超大方向值。
--     推理影响：SteerInDir 内部大概率只关心方向比例（会归一化），
--     故实际危害有限；但若内部直接乘以速度，就会产生异常移动。
--     → 移植时应补上范数检查，与 :395 对齐。
--   ★ 目标组件是 steeringwheeluser（操舵轮使用者），不是 locomotor。
    SteerBoat = function(player, dir_x, dir_z)
        if not (checknumber(dir_x) and
                checknumber(dir_z)) then
            printinvalid("SteerBoat", player)
            return
        end
        local steering_wheel_user = player.components.steeringwheeluser
        if steering_wheel_user ~= nil then
            steering_wheel_user:SteerInDir(dir_x, dir_z)
        end
    end,

--★ StopWalking —— 零参数零校验（同 :380）。
--   ★★ 与 :1107 ClearActionHold、:1100 RepeatHeldAction 同属
--     「玩家主动终止某个持续状态」的三件套。
    StopWalking = function(player)
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:OnRemoteStopWalking()
        end
    end,

--★★★[原注释："action" and "mod_name" are deprecated, but keep them for mod compatibility]
--   ★★★ 又一次「协议演进」的记录：两个参数已被废弃但保留。
--   ★★ 与 :178 的处理形成鲜明对比：
--     · :178（isleftmouse/isreleased）—— 新参数**追加到末尾**，旧位置不动；
--     · 本行（action/mod_name）—— 新参数**替换**了它们的位置（因为功能变了）。
--   ★★ 关键差异：追加参数是兼容的（旧客户端仍可用），
--     而替换参数位置是不兼容的（旧客户端的值会被当作新参数读）。
--     → 因此这里保留了 action/mod_name 的形参位置，但**不再使用它们**，
--       让新客户端不传、旧客户端传的值落在无害的位置。
--   ★ 这就是「废弃参数的正确处理方式」：保留签名，忽略内容。
--   ★★ 与 prefabs/world.lua:250 的 slow_farmplot（deprecated but still used）
--     是同一套向后兼容纪律的两面：参数与预制体都要留。
    --"action" and "mod_name" are deprecated, but keep them for mod compatibility
--★★[DoWidgetButtonAction —— 本文件防御最深的一个 handler]
--   ★★ 四层检查（第 533-543 行），逐层收紧：
--     ① 校验参数：仅 optentity(target)（为什么可选见 :529 的后注）
--     ② playercontroller 存在 且 :IsEnabled() 且 sg 不是 busy
--     ③ container 存在 且 container:IsOpenedBy(player)  ★★★ 最关键的一层
--     ④ widget.buttoninfo 存在 且 validfn 通过 且 fn 存在
--   ★★★ 第 ③ 层 IsOpenedBy(player) 是**授权检查**：
--     「这个容器确实是**你这个玩家**打开的」——
--     ★ 攻击者可以传别人的容器实体，但 IsOpenedBy 比对的是服务端记录的开箱关系，
--       伪造不出来。★ 这正是 :8 里 checkentity 弱检查的兜底防线。
--   ★★ 第 ④ 层的 validfn(target) 是**插件化的业务校验**：
--     buttoninfo 由模组/组件注册（validfn + fn），
--     validfn 为 nil 时视为通过（第 539 行的 `buttoninfo.validfn == nil or ...`）。
--   ★★ 这是「模组可扩展点」的标准形态：注册时提供 fn（做什么）
--     与可选的 validfn（能不能做）。
--   ★ 注意 :534 的 `not player.sg:HasStateTag("busy")` —— 同 :486 的语义检查。
--   ★★ 整段的意义：这是本文件「四层防御」的教科书样本。
--     对比 LeftClick 只有两层（校验 + 距离）——
--     ★ 因为 DoWidgetButtonAction 会触发**模组提供的任意回调函数**，
--       攻击面更大，必须更严。
    DoWidgetButtonAction = function(player, action, target, mod_name)
--★ target 用 optentity（可选）—— 推理：点空地时没有 widget，
--   但第 535 行的 `target ~= nil and target.components.container or nil`
--   已经处理了 nil 的情况，所以 target 可以是 nil。
        if not optentity(target) then
            printinvalid("DoWidgetButtonAction", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil and playercontroller:IsEnabled() and not player.sg:HasStateTag("busy") then
--★★[第 535 行：`target ~= nil and target.components.container or nil` 的双重防护]
--   ★★★ 这行有两个作用：
--     ① `target ~= nil and` —— 防止 target 为 nil 时索引崩溃；
--     ② `... or nil` —— ★ 把 false 归一化为 nil（Lua 的 and/or 三目陷阱）。
--   ★★★ 为什么需要 `or nil`？
--     若 target.components 为 nil，则 `X and Y` 求值为 nil（本该是 nil，OK）；
--     但若 target.components.container 为 false（不会发生，但类型上允许），
--     and/or 表达式会返回 false 而非 nil。
--     ★ 更实际的理由：`a and b or c` 模式在 b 为 false/nil 时会返回 c，
--       这里 c=nil，于是结果仍是 nil —— 行为正确。
--       ★ 这是防御性地写好「Lua 三目惯用法」的示范。
--   ★★ 第 536 行 container:IsOpenedBy(player) 再授权 —— 双重保险。
            local container = target ~= nil and target.components.container or nil
            if container ~= nil and container:IsOpenedBy(player) then
                local widget = container:GetWidget()
                local buttoninfo = widget ~= nil and widget.buttoninfo or nil
                if buttoninfo ~= nil and (buttoninfo.validfn == nil or buttoninfo.validfn(target)) and buttoninfo.fn ~= nil then
                    buttoninfo.fn(target, player)
                end
            end
        end
    end,

--★ ReturnActiveItem —— 归还手上的物品。零参数零校验。
--★★[ReturnActiveItem —— 物品栏 RPC 组的开始]
--   ★★ 从这里开始是一大组**结构完全相同**的物品栏操作 handler。
--   ★★★ 这组平行实现的共同骨架（三行）：
--     ① checkuint(slot) 且 optentity(container) 校验
--     ② 取 inventory（有时还要取 container 的组件）
--     ③ container == nil 时走背包方法；否则走容器方法，
--        ★★ 且都要检查 container:IsOpenedBy(player)
--   ★★ 为什么每个操作要写一个独立 RPC 而不是一个带操作码的通用 RPC？
--     ★ 答案在 §四 的编号机制：编号是**终身绑定**的，
--       一个通用 RPC 需要服务端维护操作码→函数的映射，
--       而分散成多个 RPC 由客户端选择要发哪个，无需额外分派。
--     ★★ 代价：表里有大量重复代码（约 250 行），换来的是零分派开销与零歧义。
--   ★★ 安全模型（关键）：★ container 分支的 IsOpenedBy(player) 是授权核心。
--     攻击者可以传任意容器实体，但只有自己打开过的容器才能通过。
    ReturnActiveItem = function(player)
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:ReturnActiveItem()
        end
    end,

--★★★[PutOneOfActiveItemInSlot —— 物品栏平行实现的第 1 号样板]
--   ★ slot 用 **checkuint**（不是 optuint）：槽位号必须给定且为非负整数。
--     ★ 这是 :15-16 那条说明的直接体现 —— 槽位必须是 uint。
--   ★ container 用 **optentity**：可以不给（= 操作自己的背包）。
--   ★★ 这两个谓词的选择不是随意的：
--     · 槽位是「指哪个格子」→ 必须有 → checkuint
--     · 容器是「操作谁的」→ 可以省略（默认自己）→ optentity
--   ★★ 对照整个文件：slot 类参数一律 checkuint，container 一律 optentity。
--     ★★ 这就是「校验强度由业务语义决定」的成规模体现。
    PutOneOfActiveItemInSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("PutOneOfActiveItemInSlot", player)
            return
        end
        local inventory = player.components.inventory
--★★[第 560 行：`if container == nil` —— 背包分支与容器分支的分流点]
--   ★★ 两个分支调用的是**同名但不同对象**的方法：
--     · 背包：inventory:PutOneOfActiveItemInSlot(slot)
--     · 容器：container:PutOneOfActiveItemInSlot(slot, player)
--   ★★ 注意容器版多传了 player —— ★ 因为容器操作需要知道「是谁在操作」，
--     用于权限与事件广播。这是容器与背包的本质差异。
--   ★★ 这种「同名方法分派到不同接收者」的设计省掉了大量 if/else，
--     ★ 但要求两边方法签名兼容（可选参数）。移植时要注意。
        if inventory ~= nil then
            if container == nil then
                inventory:PutOneOfActiveItemInSlot(slot)
            else
--★★★[第 564 行：`container = container.components.container` —— 覆盖形参的经典手法]
--   ★★★ 注意这里把**形参 container** 重新绑定为它的 container 组件：
--     · 进来时：container 是实体（客户端传来的引用）
--     · 出去时：container 是该实体的 container 组件
--   ★★ 为什么这么做？为了复用同一个变量名，让后续代码写成 `container:方法()`。
--     若不覆盖，就得再引入一个局部变量名（containercomp 之类），
--     然后在 8 个平行 handler 里都这么写一遍。
--   ★★★ 这是「用变量复用换代码简洁」的取舍，可读性略降但维护性提升。
--   ⚠ 副作用：执行到第 564 行后，原实体引用**丢失**了。
--     本例中不再需要它，所以安全。★ 但这是容易出错的模式，
--     移植/改写时若在覆盖后还要用实体引用，就会踩坑。
--   ★★ 第 565 行再检查 container ~= nil（实体可能没有 container 组件）
--     与 IsOpenedBy —— 双层防线。
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:PutOneOfActiveItemInSlot(slot, player)
                end
            end
        end
    end,

--★ PutAllOfActiveItemInSlot —— 样板 2 号。与 553 完全同构，只改方法名。
--   ★★ 验证了「平行实现」的规律：10 个 handler 共享同一个三段骨架。
    PutAllOfActiveItemInSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("PutAllOfActiveItemInSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
                inventory:PutAllOfActiveItemInSlot(slot)
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:PutAllOfActiveItemInSlot(slot, player)
                end
            end
        end
    end,

--★ TakeActiveItemFromHalfOfSlot —— 样板 3 号。
--   ★★ 方法名前缀 Take vs Put 区分方向，参数形态完全相同。
    TakeActiveItemFromHalfOfSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("TakeActiveItemFromHalfOfSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
                inventory:TakeActiveItemFromHalfOfSlot(slot)
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:TakeActiveItemFromHalfOfSlot(slot, player)
                end
            end
        end
    end,

--★★[TakeActiveItemFromCountOfSlot —— 第一个带「数量」的样板]
--   ★★ 多了 count 参数，用 checkuint（必需）：「取 N 个」必须给出 N。
--   ★★ 容器版签名：container:TakeActiveItemFromCountOfSlot(slot, count, player)
--     ★ 注意参数顺序是 (slot, count, player)，与背包版的 (slot, count) 不同，
--       player 被追加在末尾 —— 与本文件 §零 的「参数只能末尾追加」铁律一致。
    TakeActiveItemFromCountOfSlot = function(player, slot, container, count)
        if not (checkuint(slot) and
                optentity(container) and
                checkuint(count)) then
            printinvalid("TakeActiveItemFromCountOfSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
                inventory:TakeActiveItemFromCountOfSlot(slot, count)
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:TakeActiveItemFromCountOfSlot(slot, count, player)
                end
            end
        end
    end,

--★ TakeActiveItemFromAllOfSlot —— 样板 5 号（全部拿走）。
    TakeActiveItemFromAllOfSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("TakeActiveItemFromAllOfSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
                inventory:TakeActiveItemFromAllOfSlot(slot)
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:TakeActiveItemFromAllOfSlot(slot, player)
                end
            end
        end
    end,

--★★ 物品栏「平行实现」群组在此结束（第 546-724 行，约 180 行、10 个 handler）。
--   ★★ 这 180 行的价值不在逻辑（都是分派），而在**展示了「参数校验强度」
--     如何逐个按业务语义决策**：
--     · slot → checkuint（槽位不可负）
--     · eslot → checknumber（★ 装备槽位可以是负值语义）
--     · container → optentity（默认自己的背包）
--     · destcontainer → checkentity 或 optentity（视方向而定）
--     · IsOpenedBy 只在「从容器取」时检查，「往容器放」不检查
--   ★★ 参见 loc篇 §零 关于「RPC 只能末尾追加参数」的注记。
--★ AddOneOfActiveItemToSlot —— 样板 6 号（方向反转：Put→Add）。
    AddOneOfActiveItemToSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("AddOneOfActiveItemToSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
                inventory:AddOneOfActiveItemToSlot(slot)
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:AddOneOfActiveItemToSlot(slot, player)
                end
            end
        end
    end,

--★ AddAllOfActiveItemToSlot —— 样板 7 号。
    AddAllOfActiveItemToSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("AddAllOfActiveItemToSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
                inventory:AddAllOfActiveItemToSlot(slot)
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:AddAllOfActiveItemToSlot(slot, player)
                end
            end
        end
    end,

--★★[SwapActiveItemWithSlot —— 交换类，第 8 号样板]
--   ★★ swap 类不需要数量参数（整格交换），所以是 4 个参数的最简形态。
    SwapActiveItemWithSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("SwapActiveItemWithSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
                inventory:SwapActiveItemWithSlot(slot)
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:SwapActiveItemWithSlot(slot, player)
                end
            end
        end
    end,

--★★★[SwapOneOfActiveItemWithSlot —— ⚠ 疑似缺陷 C：背包分支是空的]
--   ★★★ 第 715 行：`--inventory:SwapOneOfActiveItemInSlot(slot) -- TODO: Make this!`
--   ★★★ 这是一条源码里的 TODO，暴露了一个**未完成的实现**：
--     · 容器版（第 719 行）是完整的：container:SwapOneOfActiveItemWithSlot(slot, player)
--     · 背包版被注释掉了 —— 即「用背包里某个槽位的物品与手持物交换」
--       这个操作在**背包上**不可用。
--   ── 推理这是缺陷而非设计 ──
--     1) 同组的 9 个 handler 全部有完整的背包分支；
--     2) 容器组件的方法名与背包组件完全同名（对照 :564 的覆盖手法，
--        两侧方法成对设计）；
--     3) 注释写的是 "TODO: Make this!" —— 作者自己标为待办，
--        而非「此处刻意不支持」。
--   ── 影响 ──
--     · 玩家无法从背包格与手持物做「部分交换」（一个堆叠物品换一半）。
--     · 对模组的影响更大：模组若依赖背包版该方法会拿到 nil。
--     · 不是崩溃级问题（返回空操作），是功能缺失。
--   ★ 按本文件「只注释不改码」的约定，此处仅标注不修改。
--   ★★ 注意第 714 行的 `if container == nil then` 分支体是**空的**（只有注释），
--     Lua 语法上合法（if 块不能为空是 Lua 的限制吗？不是，空 if 块合法），
--     实际行为 = 什么都不做。
    SwapOneOfActiveItemWithSlot = function(player, slot, container)
        if not (checkuint(slot) and
                optentity(container)) then
            printinvalid("SwapOneOfActiveItemWithSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            if container == nil then
--★★[第 715 行：被注释掉的调用与其 TODO 标记 —— 缺陷 C 的证据所在]
--   ★★ 注释内容 "--inventory:SwapOneOfActiveItemInSlot(slot) -- TODO: Make this!"
--   ★★ 「Make this!」的语气说明它是**待实现**，而非「不需要」。
--   ★★ 若真是设计上的不支持，通常会写成 "not supported" 或留空不加注释。
--   ★ 交叉引用：本文件 §十 的缺陷清单 C 条。
                --inventory:SwapOneOfActiveItemWithSlot(slot) -- TODO: Make this!
            else
                container = container.components.container
                if container ~= nil and container:IsOpenedBy(player) then
                    container:SwapOneOfActiveItemWithSlot(slot, player)
                end
            end
        end
    end,

--★★★[UseItemFromInvTile —— 第一个带 controlmods（手柄按键）的物品栏 handler]
--   ★★ 参数：action（动作 ID）、item（实体）、controlmods（按键位）、mod_name。
--   ★★ 第 736-738 行是本文件**唯一一处**的「Decode / 执行 / Clear」三明治：
--     playercontroller:DecodeControlMods(controlmods)  -- 解码按键组合
--     inventory:UseItemFromInvTile(item, action, mod_name)
--     playercontroller:ClearControlMods()              -- 清理
--   ★★ 为什么需要 Decode/Clear 配对？
--     controlmods 是一组「哪个键 + 哪个键」的组合，
--     inventory:UseItemFromInvTile 内部要读 playercontroller 上的解码结果
--     来决定「是用主键还是副键」。★ 清理解放状态，避免污染下一次操作。
--   ★★ 风险：若中间第 737 行抛错，第 738 行的 Clear 不会执行 →
--     解码状态残留到下一个 RPC。⚠ 理论上的异常路径泄漏。
--     → 移植时应改用 pcall/xpcall + finally 语义保证清理。
--   ★★ 对照 :753/:768/:784 的三个同族 handler（ControllerUseItemOn*FromInvTile），
--     它们**只有** ClearControlMods 而**没有** DecodeControlMods ——
--     ⚠ 因为它们的 controlmods 不在签名里（用手柄的 action 隐含了按键）。
--     ★ 这个不一致值得注意：同一族 handler 的按键处理方式不同。
    UseItemFromInvTile = function(player, action, item, controlmods, mod_name)
        if not (checknumber(action) and
                checkentity(item) and
                optnumber(controlmods) and
                optstring(mod_name)) then
            printinvalid("UseItemFromInvTile", player)
            return
        end
        local playercontroller = player.components.playercontroller
        local inventory = player.components.inventory
        if playercontroller ~= nil and inventory ~= nil then
            playercontroller:DecodeControlMods(controlmods)
            inventory:UseItemFromInvTile(item, action, mod_name)
            playercontroller:ClearControlMods()
        end
    end,

--★★[ControllerUseItemOnItemFromInvTile —— 手柄版「用 A 于 B」]
--   ★ 参数：action, item（被使用）, active_item（作用目标）, mod_name。
--   ★★ 两个 checkentity（都必需）：物品与目标都必须指定。
--   ★ 第 753 行只有 ClearControlMods 无 Decode（见 :725 的注记）。
    ControllerUseItemOnItemFromInvTile = function(player, action, item, active_item, mod_name)
        if not (checknumber(action) and
                checkentity(item) and
                checkentity(active_item) and
                optstring(mod_name)) then
            printinvalid("ControllerUseItemOnItemFromInvTile", player)
            return
        end
        local playercontroller = player.components.playercontroller
        local inventory = player.components.inventory
        if playercontroller ~= nil and inventory ~= nil then
            playercontroller:ClearControlMods()
            inventory:ControllerUseItemOnItemFromInvTile(item, active_item, action, mod_name)
        end
    end,

--★ ControllerUseItemOnSelfFromInvTile —— 手柄版「对自己使用」。
    ControllerUseItemOnSelfFromInvTile = function(player, action, item, mod_name)
        if not (checknumber(action) and
                checkentity(item) and
                optstring(mod_name)) then
            printinvalid("ControllerUseItemOnSelfFromInvTile", player)
            return
        end
        local playercontroller = player.components.playercontroller
        local inventory = player.components.inventory
        if playercontroller ~= nil and inventory ~= nil then
            playercontroller:ClearControlMods()
            inventory:ControllerUseItemOnSelfFromInvTile(item, action, mod_name)
        end
    end,

--★ ControllerUseItemOnSceneFromInvTile —— 手柄版「对场景使用」。
--   ★★ 三者的目标类型递进：B→B（物对物）、self（对己）、scene（对场景）。
--     ★ 与 :773 同一族的第四个成员是 UseItemFromInvTile（:725 鼠标版），
--       五个 handler 覆盖了「用物品」的全部目标类型。
    ControllerUseItemOnSceneFromInvTile = function(player, action, item, target, mod_name)
        if not (checknumber(action) and
                checkentity(item) and
                optentity(target) and
                optstring(mod_name)) then
            printinvalid("ControllerUseItemOnSceneFromInvTile", player)
            return
        end
        local playercontroller = player.components.playercontroller
        local inventory = player.components.inventory
        if playercontroller ~= nil and inventory ~= nil then
            playercontroller:ClearControlMods()
            inventory:ControllerUseItemOnSceneFromInvTile(item, target, action, mod_name)
        end
    end,

--★ InspectItemFromInvTile —— 查看物品。比 :194 的 InspectButton 多了实体来源。
    InspectItemFromInvTile = function(player, item)
        if not checkentity(item) then
            printinvalid("InspectItemFromInvTile", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:InspectItemFromInvTile(item)
        end
    end,

--★★[DropItemFromInvTile —— 掉落的 single 参数：★ optbool（可选布尔）]
--   ★★ 注意 single 用 optbool：可以传 nil（= 掉整个堆叠）。
--   ★ 对照 :9 的分析：optbool ≡ checkbool（都放行 nil）。
--     这里用 optbool 表达的是「语义上可选」，实际检查能力与 checkbool 相同。
--   ★★★ 这是「命名表达意图」的一个纯例子 ——
--     检查能力一样，但读者从名字知道「这参数可以不传」。
    DropItemFromInvTile = function(player, item, single)
        if not (checkentity(item) and
                optbool(single)) then
            printinvalid("DropItemFromInvTile", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:DropItemFromInvTile(item, single)
        end
    end,

--★ CastSpellBookFromInv —— 法术书施法（★ 召唤 DLC 相关）。
--   ★★ spell_id 用 checkuint（必需）：施法必须指定法术。
--   ★ 与 :1159 SetSkillActivatedState 的 skill_rpc_id 是同一类 ID。
	CastSpellBookFromInv = function(player, item, spell_id)
		if not (checkentity(item) and
				checkuint(spell_id)) then
			printinvalid("CastSpellBookFromInv", player)
			return
		end
		local inventory = player.components.inventory
		if inventory ~= nil then
			inventory:CastSpellBookFromInv(item, spell_id)
		end
	end,

--★ EquipActiveItem —— 装备手上的物品。零参数零校验。
    EquipActiveItem = function(player)
--★ 物品栏操作组告一段落。接下来是制作/配方、写作、popup、技能相关。
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:EquipActiveItem()
        end
    end,

--★★[EquipActionItem —— 「指定物品」的装备，item 用 optentity（可选）]
--   ★★ 推理为什么可选：客户端可能只发「装备」信号，具体物品由
--     服务端从 active item 推断（与 :824 的 EquipActiveItem 语义重叠）。
--     ★ 即 EquipActionItem 是 EquipActiveItem 的「显式版本」，
--       两者的区别只在 item 是否给定。
    EquipActionItem = function(player, item)
        if not optentity(item) then
            printinvalid("EquipActionItem", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:EquipActionItem(item)
        end
    end,

--★ SwapEquipWithActiveItem —— 手持物与装备栏交换。零参数零校验。
    SwapEquipWithActiveItem = function(player)
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:SwapEquipWithActiveItem()
        end
    end,

--★★[TakeActiveItemFromEquipSlot —— ★ eslot 用 checknumber 而非 checkuint]
--   ★★ 又是「谓词选择的语义依据」的例子：
--     · 背包 slot（第 553 行等）用 checkuint —— 因为槽位号不能为负；
--     · 装备 eslot（本行）用 checknumber —— ★★ 允许负数是有意义的！
--   ★★★ 推理：DST 的装备栏语义里，负数编号代表「特殊槽位」或
--     「按类型而非按位置」（例如「手/背/头」三个部位的枚举）。
--     若用 uint 会把这些合法调用全部误判为非法。
--   ★ 这处差异是「不能把校验器当模板套用」的实证。
--   ★ 参见 inventory 组件里 TakeActiveItemFromEquipSlotID 的槽位定义。
    TakeActiveItemFromEquipSlot = function(player, eslot)
        if not checknumber(eslot) then
            printinvalid("TakeActiveItemFromEquipSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:TakeActiveItemFromEquipSlotID(eslot)
        end
    end,

--★★★[MoveInvItemFromAllOfSlot —— 「源固定是背包」的移动系列]
--   ★★ 与前面 10 个平行 handler 的关键差异：
--     · destcontainer 用 **checkentity**（必需），不是 optentity！
--       ★ 理由：移动必须指明目的地，「移动到 nowhere」没有意义。
--     · 且**不检查 IsOpenedBy**（见 :866）。
--   ★★★ 为什么 destcontainer 不检查打开关系？
--     推理：目标容器不需要被打开（东西可以被塞进别人的冰箱），
--     ★★ 这是游戏的**功能性设定**（给邻居送东西），不是安全漏洞。
--     → 但它意味着容器操作不能只看「容器开着吗」。
--   ★★ 同组的第 3 个成员 MoveInvItemFromCountOfSlot（:884）多了 count。
--   ★★ 而接下来的 MoveItemFrom*Slot 系列（:897 起）反过来 ——
--     源 srccontainer 必需且检查 IsOpenedBy，目标 destcontainer 可选。
--     ★ 两组的方向完全相反，★ 改写时极易搞混。
    MoveInvItemFromAllOfSlot = function(player, slot, destcontainer)
--★★★[MoveInvItemFromAllOfSlot —— 「从背包挪到某容器」系列（3 个 handler）]
--   ★★★ 第 861-864 行校验：
--     checkuint(slot) 且 checkentity(destcontainer)
--   ★★ 关键点：★ destcontainer 用 **checkentity**（必需）——
--     「移动」必须指明目的地，否则语义不完整。
--   ★★ ★ 与接下来 :897 的 MoveItemFromAllOfSlot（源是容器）形成镜像：
--     · 本组：源=背包（固定），目标=容器（必需，不检查打开）；
--     · 下一组：源=容器（必需，**检查打开**），目标=可选（默认玩家）。
--   ★★★ 这个不对称是**有意的语义区分**（见 :897 的详细注记）。
--   ★ 本组共 3 个 handler：
--     · MoveInvItemFromAllOfSlot   (:860) 整格
--     · MoveInvItemFromHalfOfSlot  (:872) 半格
--     · MoveInvItemFromCountOfSlot(:884) 指定数量（多 count 参数，checkuint）
--   ★★ 三者结构完全平行，只改方法名与是否有 count。
        if not (checkuint(slot) and
                checkentity(destcontainer)) then
            printinvalid("MoveInvItemFromAllOfSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:MoveItemFromAllOfSlot(slot, destcontainer)
        end
    end,

    MoveInvItemFromHalfOfSlot = function(player, slot, destcontainer)
        if not (checkuint(slot) and
                checkentity(destcontainer)) then
            printinvalid("MoveInvItemFromHalfOfSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:MoveItemFromHalfOfSlot(slot, destcontainer)
        end
    end,

--★★[MoveInvItemFromCountOfSlot —— 带数量参数的第三个成员]
--   ★★ 校验（:885-887）：checkuint(slot) 且 checkentity(destcontainer) 且 checkuint(count)
--   ★★ 注意 count 也用 checkuint —— 数量不能为负（:6 的说明：槽位/数量类必用 uint）。
--   ★ 容器版调用：container:MoveItemFromCountOfSlot(slot, destcontainer, count, player)
--   ★★ 参数顺序：slot, 目标, count, player —— player 追加在末尾（同 :610 注记）。
    MoveInvItemFromCountOfSlot = function(player, slot, destcontainer, count)
        if not (checkuint(slot) and
                checkentity(destcontainer) and
                checkuint(count)) then
            printinvalid("MoveInvItemFromCountOfSlot", player)
            return
        end
        local inventory = player.components.inventory
        if inventory ~= nil then
            inventory:MoveItemFromCountOfSlot(slot, destcontainer, count)
        end
    end,

--★★ MoveInvItemFrom* 系列结束（3 个 handler，源=背包）。
--   ★★ 与接下来的 MoveItemFrom* 系列（源=容器）构成镜像，
--     ★★ 差异全在「是否检查 IsOpenedBy」——这是安全与功能的分界。
--★★★[MoveItemFromAllOfSlot —— 「源固定是容器」的移动系列，与 :860 镜像]
--   ★★ 镜像关系（★ 移植时必须成对理解）：
--     MoveInvItemFrom*Slot（:860-895）: checkentity(destcontainer)，不检查打开
--     MoveItemFrom*Slot    (:897-935): checkentity(srccontainer) + IsOpenedBy,
--                                            optentity(destcontainer)
--   ★★ 语义差异（推理）：
--     · 从背包拿 → 放进某容器：容器不需要开着（直接投递）
--     · 从某容器拿 → 放到背包/别处：★ 容器必须开着（要确认你有权取）
--   ★★★ 这是本文件里**唯一一处参数校验强度不对称**的地方，
--     且这个不对称是**有意的语义区分**，不是疏漏。
--   ★ 第 906 行的 `destcontainer or player` —— 目标缺省时是「玩家背包」。
    MoveItemFromAllOfSlot = function(player, slot, srccontainer, destcontainer)
--★★★★★[MoveItemFromAllOfSlot —— 「从某容器挪走」系列（★ 与 :897 镜像）]
--   ★★★ 第 898-900 行校验：
--     checkuint(slot) 且 checkentity(srccontainer) 且 optentity(destcontainer)
--   ★★★ 三个关键点（★ 与 MoveInvItem 系列逐一对照）：
--     ① srccontainer 用 **checkentity**（必需）—— 必须指明从哪取；
--     ② destcontainer 用 **optentity**（可选）—— 不给就是「放到自己背包」；
--     ③ ★★ 第 904-907 行检查 **IsOpenedBy(player)** —— ★ 只有本组检查！
--   ★★★ 为什么「从容器取」要检查打开，「往容器放」不检查（:897 对照组）？
--   ── 推理（语义与安全双重考虑）──
--     · 「往容器放」：可以把东西直接塞进别人的冰箱 —— 这是**游戏功能**
--       （给队友送物资），不需要打开。
--     · 「从容器取」：★ 必须打开才能拿 —— 这是**权限边界**，
--       ★ 防止玩家远程偷别人箱子里的东西。
--     ★★ 一个是功能设计，一个是安全设计 —— ★★ 这不是不对称，是**必需的区分**。
--   ★★ 第 906 行：`container:MoveItemFromAllOfSlot(slot, destcontainer or player, player)`
--     ★★ 第二个参数 `destcontainer or player` —— 目标缺省时传 player 实体
--       （因为容器方法需要一个「目标」参数，而背包就是玩家自己）。
--     ★ 这是「用实体当默认目标」的技巧。
--   ★★ 本组共 3 个 handler（:897/:910/:923），结构完全平行。
--   ★★★ ★★★ 移植警示：★ 这两组极易混淆（名字只差 Inv 的位置）。
--     建议移植时改为更明确的名字（如 TakeFromContainerTo / MoveFromInventoryTo）。
        if not (checkuint(slot) and
--★★「--or all validated」—— 本组校验（三关键点见 :898）。
--   ★★ checkuint(slot) 且 checkentity(srccontainer) 且 optentity(destcontainer)
--   ★★ 源必需、目标可选 —— 与 MoveInvItem 系列（:899 对照组）恰好相反。
                checkentity(srccontainer) and
                optentity(destcontainer)) then
            printinvalid("MoveItemFromAllOfSlot", player)
            return
        end
--★★★[第 904-907 行：容器组件取得 + IsOpenedBy 授权 + 默认目标]
--   ★★★ 三步逐一读解：
--     ① srccontainer.components.container —— 取容器组件（可能为 nil）；
--     ② container:IsOpenedBy(player) —— ★★★ 「我打开过这个箱子吗」的授权检查；
--     ③ container:MoveItemFromAllOfSlot(slot, destcontainer or player, player)
--   ★★ 第 906 行的三参数调用：
--     · slot                   —— 源容器里第几格
--     · destcontainer or player —— ★ 目标（缺省 = 玩家自己的背包）
--     · player                 —— 操作者（用于事件广播与权限记录）
--   ★★★ ② IsOpenedBy 是本组**唯一**的安全边界（:898 详细注记）：
--     「从容器取」必须验证开箱关系，防止玩家远程偷取他人箱子。
--   ★★ 与 MoveInvItem 系列（:861 等）对照：那里**没有** IsOpenedBy
--     —— 因为「往容器放」是允许的功能（给队友送物资）。
        local container = srccontainer.components.container
        if container ~= nil and container:IsOpenedBy(player) then
            container:MoveItemFromAllOfSlot(slot, destcontainer or player, player)
        end
    end,

--★ MoveItemFromHalfOfSlot —— 本组第 2 个（半格移动），结构与 :898 完全平行。
    MoveItemFromHalfOfSlot = function(player, slot, srccontainer, destcontainer)
        if not (checkuint(slot) and
                checkentity(srccontainer) and
                optentity(destcontainer)) then
            printinvalid("MoveItemFromHalfOfSlot", player)
            return
        end
        local container = srccontainer.components.container
        if container ~= nil and container:IsOpenedBy(player) then
            container:MoveItemFromHalfOfSlot(slot, destcontainer or player, player)
        end
    end,

--★★[MoveItemFromCountOfSlot —— 本组第 3 个（带数量），多一个 checkuint(count)]
--   ★★ 校验（:924-927）：
--     checkuint(slot) 且 checkentity(srccontainer) 且 optentity(destcontainer) 且 checkuint(count)
--   ★ 容器调用（:933）：container:MoveItemFromCountOfSlot(slot, destcontainer or player, count, player)
--   ★★ 参数顺序：slot, 目标, count, player —— 与 :884 的 MoveInvItemFromCountOfSlot
--     （slot, destcontainer, count, player）**顺序一致**。
--     ★ 这是两组之间的少数「对齐点」，移植时值得核对。
    MoveItemFromCountOfSlot = function(player, slot, srccontainer, destcontainer, count)
        if not (checkuint(slot) and
                checkentity(srccontainer) and
                optentity(destcontainer) and
                checkuint(count)) then
            printinvalid("MoveItemFromCountOfSlot", player)
            return
        end
        local container = srccontainer.components.container
        if container ~= nil and container:IsOpenedBy(player) then
            container:MoveItemFromCountOfSlot(slot, destcontainer or player, count, player)
        end
--★★ MoveItemFromCountOfSlot 结束。★★ 两组镜像 handler 到此全部完成。
    end,

--★★ MoveItemFrom* 系列结束（3 个 handler，源=容器）。
--   ★★ ★★★ 移植警示回顾：这两组名字极其相似，语义相反。
--     · MoveInvItemFrom*Slot: 背包 → 容器（destcontainer 检查类型，不检查打开）
--     · MoveItemFrom*Slot:    容器 → 背包/他处（srccontainer 检查打开，destcontainer 可选）
--   ★★ 若移植时混淆，会导致「玩家能远程偷别人箱子」或「无法正常送东西」。
--★★★★★[MakeRecipeFromMenu —— 「用数值 ID 反查配方」的经典模式]
--   ★★ 第 945-950 行：从 AllRecipes 里按 v.rpc_id == recipe 反查。
--   ★★★ 为什么要用数字 ID 而不是配方名？
--     · 带宽：数字比字符串短得多，配方 ID 是短整数。
--     · ★★ 安全：反查天然完成白名单校验 ——
--       客户端只能引用「AllRecipes 里真实存在的 rpc_id」。
--       ★★ 攻击者传一个不存在的 id，循环找不到匹配 → 什么都不发生。
--     · 稳定性：配方表会因模组增删，而 rpc_id 是稳定分配的。
--   ★★★ 这是一种优雅的「能力令牌（capability token）」设计：
--     传数字，服务端做反查，反查即校验。
--     ★ 对比若直接传配方名：那样还得额外校验「这个名字对应允许的配方」。
--   ★★★ ⚠ 但它的代价是 **O(n) 线性扫描**（每个 RPC 都扫一遍 AllRecipes）。
--     → 移植时应建 `rpc_id → recipe` 的反查表（一次构建，O(1) 查询）。
--     ★ 这与 §四 的编号机制呼应：★ 本文件里「数字 ID + 反查」被复用了两次
--       （这里与 :1980 的 MarkUserIDRPC），是一个成熟的模式。
--   ★★ 第 947 行的 skin_index 处理：`v.product` vs :984 的 `v.name`
--     ★★ 这里有个不一致：:947 用 v.product，:984 用 v.name 取 PREFAB_SKINS 的键。
--     PREFAB_SKINS 通常按「产品 prefab 名」索引，所以 :984 用 v.name 可能取不到。
--     ⚠ 但这只是**skin_index 为 nil 时**才走的分支（`:948 return` 提前返回），
--       实际多数情况下 skin_index 为 nil → 整个表达式短路，不求值。
--     → 属「潜伏的潜在缺陷」，仅标注不改。
    MakeRecipeFromMenu = function(player, recipe, skin_index)
        if not (checknumber(recipe) and
                optnumber(skin_index)) then
            printinvalid("MakeRecipeFromMenu", player)
            return
        end
        local builder = player.components.builder
        if builder ~= nil then
            for k, v in pairs(AllRecipes) do
                if v.rpc_id == recipe then
                    builder:MakeRecipeFromMenu(v, skin_index ~= nil and PREFAB_SKINS[v.product] ~= nil and PREFAB_SKINS[v.product][skin_index] or nil)
                    return
                end
            end
        end
    end,

--★★★[SetMovementPredictionEnabled —— 客户端预测协议的服务端开关]
--   ★★ 这个 RPC 看似普通，但它是 PredictWalking（:425）的前置条件：
--     · 服务端先通过它开启/关闭某玩家的客户端预测；
--     · 客户端只有被开启后才被允许发 PredictWalking；
--     · 服务端在 :454 用 remote_predicting 门禁验证。
--   ★★★ 完整的预测协议握手（三段）：
--     ① 服务端 → 客户端：本 RPC 下发开关
--     ② 客户端 → 服务端：PredictWalking 上报预测
--     ③ 服务端 → 客户端：校正回真实位置
--   ★★ 为什么要做成「服务端开启」而不是客户端自行决定？
--     因为预测会有分歧（客户端与服务端算出不同结果），
--     ★ 服务端必须能随时关闭某个玩家的预测来止损（网络差/作弊时）。
--   ★ 参见 locomotor.lua 的客户端预测章节与 playercontroller 的 remote_predicting。
    SetMovementPredictionEnabled = function(player, enabled)
        if not (checkbool(enabled)) then
            printinvalid("SetMovementPredictionEnabled", player)
            return
        end
		local playercontroller = player.components.playercontroller
		if playercontroller then
			playercontroller:OnRemoteToggleMovementPrediction(enabled)
        end
    end,

--★★[MakeRecipeAtPoint —— 「配方 + 坐标」的制作，坐标版三重校验]
--   ★★ 三个额外检查叠加在坐标类 RPC 上：
--     ① checknumber(x), checknumber(z), checknumber(rot) —— rot 是**必需**
--     ② ConvertPlatformRelativePositionToAbsolutePosition（第 979 行）
--     ③ IsPointInRange 且 IsRotationValid（第 981 行）
--   ★★ 与 :937 MakeRecipeFromMenu 的关系：一个在菜单里做、一个在场景里做。
--     ★ 二者共享「rpc_id 反查配方」的逻辑（第 982-987 行与 :945-950 行同构）。
--   ★★ 第 984 行的 `v.name` 取 PREFAB_SKINS（见 :947 的不一致注记）。
    MakeRecipeAtPoint = function(player, recipe, x, z, rot, skin_index, platform, platform_relative)
--★★★[MakeRecipeAtPoint 校验区 —— 「配方+坐标+朝向」的三重校验叠加]
--   ★★★ 第 966-972 行：
--     checknumber(recipe), checknumber(x), checknumber(z), checknumber(rot),
--     optnumber(skin_index), optentity(platform), checkbool(platform_relative)
--   ★★ 注意 **rot 是 checknumber（必需）** —— 与 :154/:294 的 rotation 可选不同：
--     · 「右键放置」可以不指定朝向（用默认）；
--     · ★「按坐标制作」必须指定朝向 —— 因为制作位置由坐标确定，朝向也必需。
--   ★★★ 三重校验的叠加顺序（★ 安全关键）：
--     ① 类型校验（此行）→ ② 坐标还原（:979）→ ③ 距离+旋转校验（:981）
--   ★★ 与 MakeRecipeFromMenu（:937）的对比：
--     · 菜单版：无坐标，只有「rpc_id 反查配方」；
--     · ★ 场景版：坐标 + 距离检查 + 「rpc_id 反查配方」。
--     ★★ 二者共享「反查配方」的核心（:982-987 与 :945-950 结构相同）。
--   ★ ★ 移植注记：:984 用 v.name 取 PREFAB_SKINS，与 :947 的 v.product 不一致
--     （见 :947 的注记，属潜伏的潜在缺陷）。
        if not (checknumber(recipe) and
                checknumber(x) and
                checknumber(z) and
                checknumber(rot) and
                optnumber(skin_index) and
				optentity(platform) and
				checkbool(platform_relative)) then
            printinvalid("MakeRecipeAtPoint", player)
            return
        end
		local builder = player.components.builder
		if builder ~= nil then
--★ printinvalidplatform —— 制作场景坐标的竞态诊断（与 :101/:151 等同构）。
			printinvalidplatform("MakeRecipeAtPoint", player, nil, x, z, platform, platform_relative)
--★ ConvertPlatformRelativePositionToAbsolutePosition —— 坐标还原（第三步之前）。
--   ★★ 与 :102（LeftClick）逐字相同的三步流程：
--     还原 → if x ~= nil → 距离+旋转检查。
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
			if x ~= nil then
--★ IsPointInRange 且 IsRotationValid —— 距离与旋转的双重检查。
--   ★★ 与 :154（RightClick）同构：坐标合法 + 旋转合法，才执行制作。
--   ★ 注意这里的失败提示也是 "out of range"（:989）——
--     ⚠ 与 :1082/:1233 同类的「日志文案不精确」问题。仅标注。
				if IsPointInRange(player, x, z) and IsRotationValid(rot) then
					for k, v in pairs(AllRecipes) do
						if v.rpc_id == recipe then
							builder:MakeRecipeAtPoint(v, Vector3(x, 0, z), rot, skin_index ~= nil and PREFAB_SKINS[v.name] ~= nil and PREFAB_SKINS[v.name][skin_index] or nil)
							return
						end
					end
				else
					print("Remote make recipe at point out of range")
				end
			end
		end
    end,

--★ MakeRecipeAtPoint 结束。★★ 与 MakeRecipeFromMenu(:937) 是一对：
--   · 菜单版：只在 UI 里点，无坐标；
--   · ★ 场景版：带坐标（需距离+旋转检查）。
--   ★★ 二者共享「rpc_id → recipe」的 O(n) 反查（建议改为哈希表，见 :945 注记）。
--★★[BufferBuild —— 「预缓冲」：把一次点击预演成可执行的动作]
--   ★★ 第 1002-1005 行有个细微差异：
--     `for k, v in pairs(AllRecipes) do if v.rpc_id == recipe then builder:BufferBuild(k) end end
--     ★★ 注意这里**没有 return**（对比 :947/:984 都有 return）。
--     后果：若多个配方共享同一 rpc_id，会执行多次 BufferBuild。
--   ★★ 但 builder:BufferBuild(k) 用的是 k（配方的键），不是 v ——
--     说明 AllRecipes 可能有多个键指向同一 recipe（不同分类下重复登记），
--     此时「多次调用」其实是**正确的**（每个分类都要标记缓冲状态）。
--   ★★ 这解释了「为什么这里不 return 而 :947 要 return」：
--     MakeRecipeFromMenu 只需执行一次（return），
--     而 BufferBuild 需要覆盖所有同 id 登记处。
--   ★ 差异细微但有意义 —— ★ 说明作者清楚这两个 handler 的语义差异。
    BufferBuild = function(player, recipe)
        if not checknumber(recipe) then
            printinvalid("BufferBuild", player)
            return
        end
        local builder = player.components.builder
        if builder ~= nil then
            for k, v in pairs(AllRecipes) do
                if v.rpc_id == recipe then
                    builder:BufferBuild(k)
                end
            end
        end
    end,

--★★[CannotBuild —— 「客户端告知服务端我建不了」的反向通道]
--   ★★★ 非常规设计：这是**客户端 → 服务端**的一个「失败上报」，
--     方向与其他 RPC 相反（其他都是「请求做某事」）。
--   ★★ 语义：客户端在建造菜单里点了一个当前条件不满足的配方，
--     服务端据此用该玩家的语言说出一句「无法建造：缺少 XX」。
--     ★★ 为什么要走 RPC 而不让服务端自己判断？
--       因为**失败原因要在客户端本地化**（GetString 第 1015 行）。
--       服务端不知道客户端语言，只能传 reason 让客户端查表。
--     ★★ 这是「服务端不持有语言状态」的正确设计。
--   ★ reason 用 checkstring（必需），且内容被限制在 GetString 的白名单里。
--   ★ 参见 01-报告/04 的「本地化在客户端」相关讨论。
	CannotBuild = function(player, reason)
        if not checkstring(reason) then
            printinvalid("CannotBuild", player)
            return
        end
--★ GetString(player, "ANNOUNCE_CANNOT_BUILD", reason, true) —— ★ player 是本地玩家。
--   ★★ 第四个参数 true 推测是「禁止跨语种回退」或「严格模式」。
--   ★★ 这是本文件少数几处「服务端用 player 查客户端资源」的地方 ——
--     因为 reason 是**枚举式**的短字符串，跨语言传输安全。
		local str = GetString(player, "ANNOUNCE_CANNOT_BUILD", reason, true)
		if str ~= nil then
			local talker = player.components.talker
			if talker ~= nil then
				talker:Say(str)
			end
		end
	end,

--★★★[WakeUp —— 叫醒睡着的玩家：★ 四重语义检查的典范]
--   ★★ 第 1026-1030 行的四个 and 条件：
--     ① playercontroller:IsEnabled()   —— 控制器未被禁用
--     ② player.sleepingbag ~= nil    —— ★ 玩家确实有个睡袋/帐篷实体
--     ③ sg:HasStateTag("sleeping")  —— 状态图确实处于睡眠态
--     ④ sg:HasStateTag("bedroll") or sg:HasStateTag("tent")
--   ★★★★ 第 ③ 与第 ④ 条的关系非常精妙：
--     · 「sleeping」是**状态**（正在睡）；
--     · 「bedroll」/「tent」是**载具类型**（睡在哪）；
--     ★★ 两者都是 sleeping 才同时成立？按字面看是「在睡觉 且 在床/帐篷里」。
--     ★ 这看似冗余，但推理其意图：
--       玩家可能处于 sleeping 状态但**不在**床/帐篷里（例如被强制放下），
--       此时不允许用 WakeUp RPC 叫醒。
--     → 语义检查必须覆盖「状态 + 上下文」，只看状态会误判。
--   ★★ 最终动作只有一个：player:PushEvent("locomote") —— 用 locomotion 事件叫醒。
--     ★ 复用 locomote 事件而非自定义事件，说明「叫醒」被建模成「开始移动」。
--   交叉引用：components/sleepingbaguser.lua、components/sleeper.lua。
    WakeUp = function(player)
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil and
            playercontroller:IsEnabled() and
            player.sleepingbag ~= nil and
            player.sg:HasStateTag("sleeping") and
            (player.sg:HasStateTag("bedroll") or player.sg:HasStateTag("tent")) then
            player:PushEvent("locomote")
        end
    end,
--★ WakeUp 结束。★★ 它与 :1035 的 exitgym 是「同一语义域（叫醒/中断）
--   的两种强度截然不同的实现」，★ 缺陷 D 的注记详见 BEFORE[1035]。

--★★★★⚠ [exitgym —— 缺陷 D：全小写命名 + 唯一绕过校验的 handler]
--   ★★ 问题一（命名）：全部 90 个 handler 都是 PascalCase（LeftClick、
--     DoWidgetButtonAction…），只有它是 exitgym。
--     推理：这很可能是**早期遗留**或外部系统（健身房 NPC）专用入口。
--     → 移植时统一改为 ExitGym。
--   ★★ 问题二（校验）：它**没有任何 printinvalid**，也**没有参数校验**
--     （本来也没参数）。
--     但与 :205 ResurrectButton、:380 StopAllControls、:520 StopWalking、
--     :824 EquipActiveItem 同为「零校验」，为何单列？
--     ★ 因为它调用的 playercontroller:IsEnabled() 检查与 :1024 的 WakeUp
--       形成了鲜明对比：
--       · WakeUp 校验了 4 层语义（睡袋 + 状态 + 载具）
--       · exitgym 只校验了 1 层（控制器是否启用）
--     ★★ 后果推断：玩家在被束缚/被 traps 困住时也可能通过 PushEvent("locomote")
--       触发移动相关逻辑，而 WakeUp 路径会拦住同类情况。
--     ⚠ 是否构成可利用漏洞取决于 locomote 事件的全部监听者，
--       本文件无法定论，故仅标注为「校验强度不一致」疑点。
--   ★★ 更重要的一点：★ exitgym 这个名字暗示它是**健身房（Workout Bench）**
--     机制的一部分 —— 玩家在健身时不能随意移动。
--   ⚠ 按本文件约定，此处只标注，不改代码。
    exitgym = function(player)
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil and
            playercontroller:IsEnabled() then
            player:PushEvent("locomote")
        end
    end,

--★★[SetWriteableText —— 「客户端写字」的 RPC]
--   ★★ 参数：target（要写的对象）+ text（内容）。text 用 optstring（可选）。
--   ★★★ 关键安全设计：★ text 是**字符串**，但它不会直接进存档。
--     第 1049-1051 行把写操作转交给 target 的 writeable 组件：
--       `local writeable = target.components.writeable`
--       `writeable:Write(player, text)`
--     ★★ 传了 player —— 组件内部才知道「谁写的」，
--       从而可以限制「只有拥有者能改」（★ 见 networking.lua:222 的 writeable_classified）。
--   ★★ 这是「RPC 只做转发，语义全交给组件」的最佳样本：
--     长度限制、XSS 过滤、所有权检查、存档写入，全部在组件里。
--   ★ 交叉引用：components/writeable.lua、prefabs/world.lua:224 writeable_classified。
    SetWriteableText = function(player, target, text)
--★ checkentity(target) —— target 必需（总要有个东西写）。
--   ★ optstring(text) —— text 可选：传 nil 可能表示「擦除」。
        if not (checkentity(target) and
                optstring(text)) then
            printinvalid("SetWriteableText", player)
            return
        end
        local writeable = target.components.writeable
        if writeable ~= nil then
            writeable:Write(player, text)
        end
    end,

--★ ToggleController —— 手柄连接/断开。isattached 用 checkbool（必需）。
--   ★ 注意这里调的是 playercontroller:ToggleController（不带 OnRemote 前缀），
--   ★ 与其他 handler 的 OnRemoteXxx 命名不一致 —— 属早期代码痕迹。
    ToggleController = function(player, isattached)
        if not checkbool(isattached) then
            printinvalid("ToggleController", player)
            return
        end
        local playercontroller = player.components.playercontroller
        if playercontroller ~= nil then
            playercontroller:ToggleController(isattached)
        end
    end,

--★ OpenGift —— 打开下一个礼物。零参数零校验。
--   ★★ 组件名 giftreceiver 说明这是「礼物接收」玩法（Steam 节日活动）。
    OpenGift = function(player)
        local giftreceiver = player.components.giftreceiver
        if giftreceiver ~= nil then
            giftreceiver:OpenNextGift()
        end
    end,

--★★★[ClosePopup —— ★ 「可插拔 RPC」的架构示范，也是全文件最抽象的 handler]
--   ★★★ 三个固定参数 + 一个变长参数列表 `(...)`：
--     popupcode（弹窗的数字 ID）、mod_name（模组名）、...（任意参数）
--   ★★★ 整个 handler 是一套「注册-校验-转发」协议：
--     ① GetPopupFromPopupCode(popupcode, mod_name) 取出弹窗对象
--     ② popup.validaterpcfn(...)  —— ★ 弹窗自己决定是否接受这些参数
--     ③ popup:Close(player, ...)   —— 执行关闭
--   ★★★ 价值：★ 新增一种弹窗**不需要改本文件**，只要它注册进 popup 注册表。
--     ★ 这就是「把校验与执行下沉到插件」的架构。
--   ★★ 与 :528 DoWidgetButtonAction 的对照：
--     · DoWidgetButtonAction 的 validfn 在 buttoninfo 上（来自 widget 注册）；
--     · ClosePopup 的 validaterpcfn 在 popup 上（来自 popup 注册）。
--     ★★ 两个都是「数据驱动的可扩展点」，只是数据源不同。
--   ★⚠ 注意第 1081 行：`if not popup.validaterpcfn(...) then`
--     ★★ 若某个 popup **没有** validaterpcfn 字段，这里会调用 nil → 崩溃。
--       对比第 1076 行的校验只检查了 popup 存在（GetPopupFromPopupCode 的返回值），
--       没有检查 validaterpcfn 的存在性。
--       ⚠ 这是「插件接口未强制约定」的典型脆弱点。
--       → 移植时应约定所有 popup 必须提供 validaterpcfn，
--         或用 `popup.validaterpcfn and popup.validaterpcfn(...)`。
--   ★★ 变长参数 (...) 的网络序列化：Lua 的 ... 会被打包成表，
--     跨端传输后顺序与类型保持 —— ★ 前提是调用方与 handler 对参数个数有共识。
    ClosePopup = function(player, popupcode, mod_name, ...)
--★★[第 1074-1076 行：校验条件里嵌了一个「函数调用」作为真值]
--   if not (checkuint(popupcode) and optstring(mod_name) and GetPopupFromPopupCode(popupcode, mod_name)) then
--   ★★★ 把「存在性检查」写成校验条件的一部分，简洁但有副作用：
--     ★ GetPopupFromPopupCode 会被调用一次（校验时），
--       然后第 1080 行**再调一次**（取对象）。重复查询。
--   ★ 若该函数有副作用（如计数、缓存），这里会双倍触发。
--   → 移植时应把结果存进局部变量复用。
--   ★★ 但这样写的好处是「校验通过即保证对象存在」，无需二次判空。
--     这是可读性 vs 效率的权衡。
        if not (checkuint(popupcode) and
                optstring(mod_name) and
                GetPopupFromPopupCode(popupcode, mod_name)) then
            printinvalid("ClosePopup", player)
            return
        end
--★ 第二次调用 GetPopupFromPopupCode —— 取实际对象。
--   ★ 与 :1076 的重复调用对应（见上方注记）。
        local popup = GetPopupFromPopupCode(popupcode, mod_name)
        if not popup.validaterpcfn(...) then
--★ `printinvalid("ClosePopup"..tostring(popup.id), player)` —— 拼接 popup.id。
--   ★ ★★ 对比 :1146 的 `printinvalid("DoActionOnMap PARAMS", player)` 与
--     :1162 的 `printinvalid("SetSkillActivatedState arguments", player)` ——
--     ★ 三处都往 RPC 名后面拼了额外文字（PARAMS/arguments/popup.id）。
--     推理：RPC 名是枚举（用于日志聚合/搜索），拼接额外信息会让日志
--     出现「同一个 RPC 的多条不同字符串」，**破坏可聚合性**。
--     ⚠ 轻微的可观测性缺陷（前三处日志无法被精确 grep 聚合）。仅标注。
            printinvalid("ClosePopup"..tostring(popup.id), player)
			popup:Close(player)
			return
        end
        popup:Close(player, ...)
    end,

--★★[RecievePopupMessage —— 与 ClosePopup 的完全镜像（消息方向）]
--   ★★★ 与 ClosePopup 的对称性：
--     · ClosePopup:      popup:Close(player, ...)           —— 客户端请求关闭
--     · RecievePopupMessage: popup:SendMessageToServer(...) —— 客户端发消息给服务端
--   ★★ 但 RecievePopupMessage **没有** validaterpcfn 检查（第 1097 行直接 SendMessageToServer）！
--   ⚠★★ 这是一个**明显的不对称**，值得深究：
--     · ClosePopup 有验证函数，RecievePopupMessage 没有；
--     · 推理：可能因为「发消息」的校验由 popup 的 SendMessageToServer 内部完成，
--       而「关闭」需要先确认弹窗当前状态允许关闭。
--     · 也可能是**遗漏**（写了 ClosePopup 时忘了给 Recieve 加）。
--   ★→ 移植时应确认：所有 popup 的 SendMessageToServer 是否都自行校验参数。
--     若依赖外部 validaterpcfn，则这里缺少校验 → 参数校验缺失。
--   ★★ 注意「Recieve」是拼写错误（应为 Receive），
--     但它已成为**协议的一部分**（两个方向的表里都叫这个名字），
--     所以不能改 —— ★ 「拼写错误一旦成为协议就不能修」的典型。
    RecievePopupMessage = function(player, popupcode, mod_name, ...)
        if not (checkuint(popupcode) and
                optstring(mod_name) and
                GetPopupFromPopupCode(popupcode, mod_name)) then
            printinvalid("RecievePopupMessage", player)
            return
        end

        GetPopupFromPopupCode(popupcode, mod_name):SendMessageToServer(player, ...)
    end,

--★ RepeatHeldAction —— 「按住持续动作」的重复触发。零参数零校验。
--   ★★★ 典型的「持续输入」机制：玩家按住鼠标左键时反复调用。
--     ★ 这类「按住类」操作天然是高频的 → ★ 需要限流关注（见 §八/§九）。
--     ★ 本文件未对这类 RPC 单独限流，靠统一的 :1687 每刻 20 条上限兜底。
    RepeatHeldAction = function(player)
        local playercontroller = player.components.playercontroller
        if playercontroller then
            playercontroller:RepeatHeldAction()
        end
    end,

--★ ClearActionHold —— 停止持续动作。与 :1100 配对。
--   ★ 三件套（三处）：RepeatHeldAction / ClearActionHold / StopControl / StopAllControls。
    ClearActionHold = function(player)
        local playercontroller = player.components.playercontroller
        if playercontroller then
            playercontroller:ClearActionHold()
        end
    end,

--★★★[GetChatHistory —— USERID_RPCS 的第一个实例，全文件最需要解释的 handler]
--   ★★ 参数：last_message_hash（必需 uint）、first_message_hash（可选 uint）。
--   ★★★ 第 1121 行的原注释是理解全局的钥匙：
--     "if the player is not yet spawned, 'player' will be that clients userid"
--   ★★ 含义：★ 这个 RPC 可能在**玩家实体生成之前**就被调用。
--     · 典型场景：玩家刚连上、走完选人界面，还没 SpawnPlayer；
--       此时聊天历史 UI 已经要显示过往消息了。
--     · 此时 HandleRPC 的 sender 是**玩家实体**，但这个 RPC 关心的是 userid；
--       ★ 用户id在实体生成前后都可获得，而实体可能还不存在。
--   ★★★ 机制：USERID_RPCS 标记（:1398/1980）让 HandleRPC（:1682-1684）
--     把 sender 从实体**替换**为 userid 字符串再传给 handler。
--       local userid = senderistable and sender.userid or nil
--       if USERID_RPCS[fn] then sender = userid or sender end
--   ★★ 所以第 1124 行能安全访问 player.userid（即使 player 是字符串）。
--   ★★★ 代价：★ handler 内部**不能**访问 player 实体（如 player.components）。
--     ★ 本 handler 只用 player.userid 和 player.sent_chat_history（字符串字段）——
--       完美契合。★ 凡是标记为 USERID_RPC 的 handler 都必须如此。
--   ★★ 这个标记机制的完整链路：
--     MarkUserIDRPC(:1980) 标记 → USERID_RPCS 表 → HandleRPC(:1682) 替换 sender
--     → handler 收到 userid 字符串。
--   ★ 交叉引用：chathistory.lua（聊天历史的发送与存储）。
    GetChatHistory = function(player, last_message_hash, first_message_hash)
        if not (checkuint(last_message_hash) and
                optuint(first_message_hash)) then
            printinvalid("GetChatHistory", player)
            return
        end

        --if the player is not yet spawned, "player" will be that clients userid.
--★★★[第 1122-1123 行：防重复请求的标志位 —— ChatHistory 的去重]
--   if not player.sent_chat_history then
--       player.sent_chat_history = true
--   ★★★ 这是**幂等性保护**：客户端可能重复请求同一批历史消息。
--     无保护会导致重复发送大量文本（带宽浪费 + UI 重复）。
--   ★★ 标志位挂在 player 上（可能是 userid 字符串），
--     ★ 而 Lua 字符串不能挂字段 —— 说明此处 player 实际上是**实体**
--       （含 userid 字段），或者 userid 被引擎包成了 table。
--   ⚠ 这是一个隐含假设：**标记为 USERID_RPC 的 handler，其 sender
--     仍需支持字段赋值**。→ 移植时需确认 userid 形式是 table 还是 string。
        if not player.sent_chat_history then
            player.sent_chat_history = true
            ChatHistory:SendChatHistory(player.userid, last_message_hash, first_message_hash)
        end
    end,

--★★★[原注释 "NOTES(JBK): OnMap RPCs are always world relative."]
--   ★★★ 「世界相对」= 不接受 platform 参数（对比 :102/:152 的平台相对）。
--   ★★ 推理：地图是全局的（不随平台移动），所以地图上的坐标
--     在任何平台上点击都一样 → 不需要平台修正。
--   ★★ 因此这个 handler 的签名里没有 platform/platform_relative，
--     也跳过了 ConvertPlatformRelativePositionToAbsolutePosition。
--   ★★★ 这是一条**显式声明的协议约束**：
--     「哪些 RPC 走平台相对，哪些不走」不是随意的，而是分类决定的。
--   ★★ 反例对照：:396 DirectWalking 的注释也强调
--     「x and z are directions, not positions, so we don't need platform」。
--     → 两处注释合起来定义了一套完整的「坐标语义分类」。
    -- NOTES(JBK): OnMap RPCs are always world relative.
--★★[DoActionOnMap —— 二元校验 + 两分支分派（地图坐标 vs 取消）]
--   ★★★ 第 1149-1156 行两个分支：
--     · actioncode 非 nil → playercontroller:OnMapAction(actioncode, ...) —— 执行动作
--     · actioncode 为 nil  → maptarget:PushEvent("cancelmaptarget", player) —— 取消
--   ★★ 这是「同一个 RPC 同时表达两个动作」的设计：
--     一个「地图交互」RPC，处理「点到了什么」与「取消选择」两种意图。
--   ★ 为什么合一？因为它们共享同一套上下文（地图、目标、玩家）。
--   ★★ 「取消」不用 platform（因为是地图全局概念，见 :1128）。
--   ★★ 第 1134 行在「全 nil」分支里写了 `checkentity(maptarget)`
--     （非 optentity）—— ★ 取消时必须有一个目标实体。
--     这是二元校验内部还能有细微差异的例子（★ 不是简单复制粘贴）。
    DoActionOnMap = function(player, actioncode, x, z, maptarget, mod_name)
		if not (	(	--these are either all nil
						actioncode == nil and
						x == nil and
						z == nil and
						checkentity(maptarget) and
						mod_name == nil
					) or
					(	--or all validated
						checknumber(actioncode) and
						checknumber(x) and
						checknumber(z) and
						optentity(maptarget) and
						optstring(mod_name)
					)
				)
		then
--★ printinvalid("DoActionOnMap PARAMS", ...) —— ⚠ 拼接额外字（见 :1082 注记）。
            printinvalid("DoActionOnMap PARAMS", player)
            return
        end
		if actioncode then
			local playercontroller = player.components.playercontroller
			if playercontroller then
				playercontroller:OnMapAction(actioncode, Vector3(x, 0, z), maptarget, mod_name)
			end
		else
			maptarget:PushEvent("cancelmaptarget", player)
        end
    end,

--★★★[SetSkillActivatedState —— 技能激活/解锁，★ 客户端与服务端版本完全对称]
--   ★★ 参数：skill_rpc_id（必需 number）、isunlocked（必需 bool）。
--   ★★★ 与 CLIENT_RPC_HANDLERS 里的同名 handler（:1483）**逐字对称**：
--     · 都是 skill_rpc_id → TheSkillTree:GetSkillNameFromID(prefab, id)
--     · 都用 isunlocked 决定 Activate/Deactivate
--   ★★ 对称的意义：★ 客户端本地先改 UI，服务端同时改状态，
--     双方用**完全相同的映射逻辑**，避免两端算出不同的技能名。
--   ★★ 第 1177-1180 行的注释解释了「为什么不能接受取消」：
--     "If design changes this should be uncommented for now respec only happens
--      during player selection screens or when we redefine the skill tree."
--     "Clients manually sending this in with the console will now be in a desync
--      state with their UI."
--   ★★★★ 这段注释揭示了一个**已知的安全性妥协**（重要）：
--     · 客户端可以在控制台手动发 SetSkillActivatedState(isunlocked=false)，
--       服务端**接受**这个请求（不加限制）；
--     · 结果：客户端的技能 UI 与服务端状态**不同步**（desync）；
--     · 作者明确知道这个风险，但选择「先不加限制」，因为
--       「取消技能」本应在选人界面完成。
--     · ★★ 这是一个「设计上先行、防御上后补」的决策记录。
--     ⚠ 严格来说这是一个**已知的可利用缺口**（客户端可自残/不同步）。
--       → 移植时若要严格，应当验证 isunlocked=true 时玩家确实拥有该技能的解锁条件。
--       但改为「拒绝 false」会导致控制台玩家 UI 不同步 ——
--       作者选择了「容忍不同步」而非「拒绝请求」。
    SetSkillActivatedState = function(player, skill_rpc_id, isunlocked)
        if not (checknumber(skill_rpc_id) and
                checkbool(isunlocked)) then
            printinvalid("SetSkillActivatedState arguments", player)
            return
        end

        local skill = TheSkillTree:GetSkillNameFromID(player.prefab, skill_rpc_id)
        if skill == nil then
--★ printinvalid("SetSkillActivatedState no skill with id", player, skill_rpc_id)
--   ⚠ 第 1168 行：第 3 个参数 skill_rpc_id 被传入 printinvalid，
--   但 printinvalid 的签名只有 (rpcname, player)（第 18 行）。
--   ★ 多余参数在 Lua 中**被静默忽略**，所以不会报错。
--   ⚠ 但这说明作者想记录「是哪个技能 ID 无效」的意图没能实现。
--     → 移植时应改为把 id 拼进第一个字符串参数。
--   ★ 这是「Lua 不会报错所以容易漏掉」的典型例子。
            printinvalid("SetSkillActivatedState no skill with id", player, skill_rpc_id)
            return
        end

        local skilltreeupdater = player.components.skilltreeupdater
        if skilltreeupdater then
            if isunlocked then
                skilltreeupdater:ActivateSkill(skill, nil, true)
            else
                -- NOTES(JBK): If design changes this should be uncommented for now respec only happens during player selection screens or when we redefine the skill tree.
                --skilltreeupdater:DeactivateSkill(skill, nil, true)
                -- Clients manually sending this in with the console will now be in a desync state with their UI.
                -- Similar actions like removing entities locally we can not protect against console use for all cases.
            end
        end
    end,

--★★[AddSkillXP —— 加技能经验：★ 无上限校验]
--   ★ amount 用 checknumber（必需），但**没有任何范围检查**。
--   ⚠ 客户端可以发 AddSkillXP(1e15) 或负数。
--   ★★ 推理影响：
--     · 经验值累积溢出：skilltreeupdater 内部大概用普通数字累加；
--       1e15 累加几次就会变成 inf 或精度崩溃。
--     · ★★ 更严重：客户端可以**自己给自己加经验**，刷满技能树。
--     · 但作者可能认为「经验值本身无害」或「技能树上限由角色属性卡限制」。
--   ⚠ 这是一个潜在的经济性漏洞（若技能影响战力）。
--     → 移植时应校验 amount 的合理范围（如 0 < amount <= 某个上限），
--       并考虑服务端侧经验来源校验。
--   ★★ 呼应 §零：checknumber 只管类型，不管范围。
--       → 这里的「不管」可能有业务后果。
    AddSkillXP = function(player, amount)
        if not (checknumber(amount)) then
            printinvalid("AddSkillXP", player)
            return
        end
        local skilltreeupdater = player.components.skilltreeupdater
        if skilltreeupdater then
            skilltreeupdater:AddSkillXP(amount, nil, true)
        end
    end,

--★★★[PostActivateHandshake —— 激活后的「确认握手」，与 :1512 完全对称]
--   ★★★ 与 CLIENT_RPC_HANDLERS 的同名 handler（:1512）配对：
--     · 本 handler（服务端侧）: player:OnPostActivateHandshake_Server(state)
--     · 客户端侧（:1512）:      ThePlayer:OnPostActivateHandshake_Client(state)
--   ★★★ 语义推测：角色激活（换角色/复活）涉及跨端状态切换，
--     客户端与服务端需要一次双向确认，确保「双方都准备好了」。
--   ★★ state 是 uint（不是 bool）—— 推测是一个「状态码/阶段号」，
--     而非简单的完成标志。
--   ★★ 「握手」（handshake）机制的一般模式：
--     A 发请求 → B 确认 → B 再确认 → A 结束。
--     ★ 目的：发现半失效连接（客户端以为连上了但服务端已重启等）。
--   ★ state 用 checkuint（必需）—— 握手状态码必须明确。
    PostActivateHandshake = function(player, state)
        if not (checkuint(state)) then
            printinvalid("PostActivateHandshake", player)
            return
        end

        player:OnPostActivateHandshake_Server(state)
    end,

--★★[OnScrapbookDataTaught —— 「图鉴数据学习」RPC，★ 直接调用实体方法]
--   ★★ 第 1211-1212 行：`if inst.OnScrapbookDataTaught then inst:OnScrapbookDataTaught(player, response) end`
--   ★★★ 这个 handler 的转发方式是「直接调实体上的方法」，而非调组件方法。
--   ★★ 推理含义：★ 「图鉴（Scrapbook）」是一个由多个实体各自实现的功能，
--     统一约定「每个相关实体都实现 OnScrapbookDataTaught 方法」。
--     这是一个「鸭子类型（duck typing）」约定，不是继承。
--   ★★★ 安全问题：★ inst 用的是 checkentity（弱检查，见 :8）。
--     攻击者传一个伪造 table，只要它有 OnScrapbookDataTaught 字段就被调用。
--     ⚠ 但由于是「调用自己表上的方法」，攻击者只能让**自己的数据表**执行 Lua 代码 ——
--       而攻击者能构造的 table 不含可执行的函数体（除非用 metatable 技巧，
--       跨端序列化会丢掉 metatable）。
--       ★★ 所以实际危害有限：序列化会剥除函数与 metatable。
--     → 这是「RPC 数据经序列化后天然受限」的安全优势，值得理解。
--   ★ response 参数未做类型校验（第 1206 行只校验了 inst）——
--     ⚠ 潜在的类型混乱风险（若 response 被当作 table 使用）。
    OnScrapbookDataTaught = function(player, inst, response)
        if not checkentity(inst) then
            printinvalid("OnScrapbookDataTaught", player)
            return
        end

        if inst.OnScrapbookDataTaught then
            inst:OnScrapbookDataTaught(player, response)
        end
    end,

--★★★[SetClientAuthoritativeSetting —— ⚠ 注释坦承了「校验在下游」的设计]
--   ★★★ 原注释："NOTES(JBK): Check passed in variables in the callback not in the RPC here."
--   ★★ 翻译：「校验传入的变量应该在回调里做，不是在这个 RPC 里做」。
--   ★★★ 为什么这样设计（推理）？
--     · 这是一个「元编程」型 RPC：它把 variable 和 value 原样传给实体方法；
--     · variable（要设置哪个设置）是个**字符串键**，
--       本文件无法知道合法键的集合（那是设置系统的知识）；
--     · ★★ 所以把「variable 是否合法」的知识下沉到回调里 ——
--       只有回调知道哪些变量可被客户端权威地设置。
--   ★★★ 这是合理的分层，但有代价：
--     ⚠ 本文件完全无法审计这个 RPC 的安全性（安全边界在别处）。
--       迁移/重写时若漏掉回调里的校验，就会开出一个大洞。
--   ★★ 没有 printinvalid —— 因为「无参数校验」是有意的，不是遗漏。
--   ★ 这是本文件里最「危险也最优雅」的一处：把校验推到信息更充分的地方。
    SetClientAuthoritativeSetting = function(player, variable, value)
        -- NOTES(JBK): Check passed in variables in the callback not in the RPC here.
        player:SetClientAuthoritativeSetting(variable, value)
    end,

--★ AOECharging —— 范围技能蓄力。rotation + startflag。
--   ★ startflag 用 optuint（可选）：蓄力开始/结束用不同值（或不传 = 结束）。
	AOECharging = function(player, rotation, startflag)
		if not (checknumber(rotation) and
				optuint(startflag)) then
			printinvalid("AOECharging", player)
			return
		end
		local playercontroller = player.components.playercontroller
		if playercontroller then
			playercontroller:OnRemoteAOECharging(rotation, startflag)
		end
	end,

--★ DoubleTapAction —— 双击动作。结构同 LeftClick 的坐标路径。
--   ★ ⚠ 第 1252 行：失败时打印 "Remote left click out of range" ——
--   ★★ 复制粘贴的痕迹：这是 DoubleTapAction，但日志写的是 left click。
--     ⚠ 影响可观测性（排查双击问题时会误以为查的是左键）。
--     这是本文件比 :1082 更严重的一处（日志文案错误，不只是拼接）。
--     仅标注，不改码。
	DoubleTapAction = function(player, action, x, z, noforce, mod_name, platform, platform_relative)
		if not (checknumber(action) and
				checknumber(x) and
				checknumber(z) and
				optbool(noforce) and
				optstring(mod_name) and
				optentity(platform) and
				checkbool(platform_relative)) then
			printinvalid("DoubleTapAction", player)
			return
		end
		local playercontroller = player.components.playercontroller
		if playercontroller then
			printinvalidplatform("DoubleTapAction", player, action, x, z, platform, platform_relative)
			x, z = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
			if x then
				if IsPointInRange(player, x, z) then
					playercontroller:OnRemoteDoubleTapAction(action, Vector3(x, 0, z), noforce, mod_name)
				else
					print("Remote left click out of range")
				end
			end
		end
	end,

--★★★[WobyCommand —— 执行「Woby」命令：★ 多层授权检查]
--   ★★ 第 1264-1270 行：
--     if player.woby_commands_classified then
--         player.woby_commands_classified:ExecuteCommand(cmd)
--     else print("Player cannot use Woby commands")
--   ★★★ 这是「client-authoritative 设置」的变体 —— 但用了不同的授权机制：
--     · 需要 player 上有一个 woby_commands_classified 实体（★ 前面 :230 行的 dummy 类类似物）；
--     · 有这个实体 → 可以执行命令；没有 → 拒绝。
--   ★★ 授权逻辑下沉到「实体是否存在」—— 一个「能力持有」的模型：
--     服务端决定是否给玩家这个 classified 实体，就等于决定了他能否用这个功能。
--   ★★ 对比 :1216 的 SetClientAuthoritativeSetting（校验在回调里），
--     这里用的是「持有即授权」的更直观模型。
--   ★ cmd 用 checkuint（必需）—— 命令是数字 ID（枚举）。
--   ★ 与 :937 的「rpc_id 反查」模式类似（数字 ID → 实际操作）。
	WobyCommand = function(player, cmd)
		if not checkuint(cmd) then
			printinvalid("WobyCommand", player)
			return
		end
		local playercontroller = player.components.playercontroller
		if playercontroller then
			if player.woby_commands_classified then
				player.woby_commands_classified:ExecuteCommand(cmd)
			else
				print("Player cannot use Woby commands")
			end
		end
	end,

--★★[InteractionTarget —— 「交互目标」的统一入口]
--   ★★ 参数：action（可选 number）、target（可选 entity）、x, z（可选 number）。
--   ★★★ 全部用 opt*（都可以不传）—— 因为这个 RPC 的语义是「宽泛的交互请求」，
--     具体是「对物交互」还是「对点交互」由哪些参数存在决定。
--   ★★ 第 1285-1293 行：
--     if x then  -- 有点坐标 → 走位置模式

--       -- ⚠ 第 1286 行有注释掉的 ConvertPlatformRelativePositionToAbsolutePosition！
--       if not IsPointInRange(player, x, z) then ... else pos = Vector3(x, 0, z) end
--     end
--   ★★★ 第 1286 行的注释是一个设计信号：
--     「这里曾经（或将来）要处理平台相对坐标，但现在被注释掉了」。
--     ⚠ 这意味着 InteractionTarget **不走平台相对转换** —— 
--       若客户端在船上发带坐标的 InteractionTarget，坐标会是船的局部坐标，
--       会被当成世界坐标 → 距离检查可能误判。
--     → 这是一个真实的协议不一致（与 LeftClick 等的规范做法不符）。仅标注。
--   ★★ 第 1294 行：pos 可能为 nil（x 存在但超距时 return），
--     或者 x 不存在时 pos 保持 nil（初始状态）—— 两种情况都传 nil 给组件。
	InteractionTarget = function(player, action, target, x, z)
		if not (optnumber(action) and
				optentity(target) and
                optnumber(x) and
                optnumber(z))
		then
			printinvalid("InteractionTarget", player)
			return
		end
		local playercontroller = player.components.playercontroller
		if playercontroller then
            local pos
			if x then
--★★[第 1286 行的注释掉的调用 —— 平台相对处理在此被刻意省略]
--   -- local x1, z1 = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
--   ★★ 这行明确被注释掉，且**参数列表里也没有 platform 相关参数**。
--   ★★ 与 LeftClick（:102）等对比：那些 handler 都做了转换。
--   ⚠ 所以 InteractionTarget 是一个「坐标语义 = 绝对世界坐标」的 handler。
--   ★ 这与其他「带坐标的 RPC」不同 —— ★ 移植时要特别标注这个 handler。
				-- local x1, z1 = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
				if not IsPointInRange(player, x, z) then
					print("Interaction Target out of range")
					return
                else
                    pos = Vector3(x, 0, z)
				end
			end
			playercontroller:OnRemoteInteractionTarget(action, target, pos)
		end
	end,

--★★[PredictGallopTrip —— 骑牛冲撞的预测（含 IsRotationValid 的特殊用法）]
--   ★★★ 第 1312 行：`if IsRotationValid(dir) and (speed == nil or speed > 0) then`
--   ★★ 这是 IsRotationValid 的第四个用法（见 :39）：
--     · 这里的 dir 是**方向角**（冲撞朝向），不是物品旋转。
--     · 同样用 IsRotationValid 排除 NaN / 无穷。
--   ★★ speed 用 `speed == nil or speed > 0` 的复合校验 ——
--     允许不传，但传了必须为正数（★ 不能是 0 或负数）。
--     ★ 这是「可选参数 + 条件约束」的校验写法（不是简单的 optnumber）。
--   ★★ 第 1313 行用 PushEventImmediate 而非 PushEvent：
--     ★★ 「立即」派发（同步执行回调），而普通 PushEvent 是排队执行。
--     理由：预测事件需要在同一帧内处理完，否则预测会滞后于移动。
--     ★ 参见 entityscript.lua 的 PushEvent / PushEventImmediate 区别。
	PredictGallopTrip = function(player, x, z, dir, speed, platform, platform_relative)
		if not (checknumber(x) and
				checknumber(z) and
				checknumber(dir) and
				optnumber(speed) and
				optentity(platform) and
				checkbool(platform_relative))
		then
			printinvalid("PredictGallopTrip", player)
			return
		end
--★ printinvalidplatform —— 这个 handler 也做平台相对诊断。
		printinvalidplatform("PredictGallopTrip", player, nil, x, z, platform, platform_relative)
		local x1, z1 = ConvertPlatformRelativePositionToAbsolutePosition(x, z, platform, platform_relative)
		if x1 then
			if IsRotationValid(dir) and (speed == nil or speed > 0) then
				player:PushEventImmediate("predict_gallop_trip", {
					x = x1,
					z = z1,
					dir = dir,
					speed = speed,
				})
			else
				print("Predict gallop trip out of range")
			end
		end
	end,

--★★★[UnplugModule —— 拔插模块：★ 双重技能校验，典型的「能力门槛」设计]
--   ★★★ 第 1336-1344 行：
--     if not (skilltreeupdater and skilltreeupdater:IsActivated("wx78_circuitry_betterunplug")) then
--         ★ 若玩家**没有**这个技能，则要求 moduleindex 必须是最后一个（不能拔中间插着模块的槽位）。
--   ★★★ 这段逻辑极其精细 —— 它揭示了「技能解锁了什么操作」的精确含义：
--     · 没有 wx78_circuitry_betterunplug 技能：只能拔掉**最末尾**的那个模块
--       （即「只有一颗的时候才能拔」，避免留下空隙导致无法安装）；
--     · 有技能：可以拔任意位置的模块。
--     ★ 这是「模组/角色专属操作」的粒度控制示例 ——
--       不只是「有/无权限」，而是「有/无更精细的操作范围」。
--   ★★ 第二处技能校验（:1356）wx78_allegiance_shadow（暗影插口）——
--     同样是技能门槛，然后查 IsSocketNameForPosition 再 TryToUnsocket。
--   ★★★ 整个 handler 展示了「服务端权威的能力检查」：
--     无论是拔插模块还是拔暗影插口，都要先查技能树（IsActivated）。
--     ★ 服务端用自己的 skilltreeupdater（权威状态）而非信任客户端。
	UnplugModule = function(player, modulebartype_or_socketposition, moduleindex)
--★★★★★[UnplugModule 校验区 —— ★「能力门槛 + 参数精度」的双重设计]
--   ★★★ 第 1326-1327 行：checknumber(modulebartype_or_socketposition) 且 optnumber(moduleindex)
--   ★★★ 参数的二元语义（★ 这是本 handler 的精髓）：
--     · moduleindex 为 nil  → 「拔插口（socket）」路径；
--     · moduleindex 非 nil   → 「拔模块（bar）」路径。
--     ★★ 用「可选的数值参数」表达「两种模式」，而非两个独立 RPC。
--     ★★ 这是 RPC 设计的一种取舍：一个 RPC 承担两种语义。
--   ★★ 两条路径各自的能力门槛（★ 见 :1336-1344 与 :1353-1364）：
--     · 拔模块：需技能 wx78_circuitry_betterunplug（★ 或 moduleindex 是最后一个）；
--     · 拔插口：需技能 wx78_allegiance_shadow。
--   ★★★ 整体是「服务端权威的能力校验」：
--     所有门槛都用服务端的 skilltreeupdater:IsActivated() 判定，
--     ★★ 完全不信任客户端上报的「我有这个技能」。
--   ★ 这是「客户端可请求、服务端定夺」的权限模型典范。
		if not (checknumber(modulebartype_or_socketposition) and
				optnumber(moduleindex))
		then
			printinvalid("UnplugModule", player)
			return
		end

--★★[第 1333 行：skilltreeupdater 取得 —— 两条路径共用的权威技能状态]
--   ★★★ 与 :1338 的 `skilltreeupdater and skilltreeupdater:IsActivated(...)`：
--     · skilltreeupdater 为 nil（组件缺失）→ 视为「无技能」；
--     · IsActivated 返回布尔。
--   ★★ 这是「能力校验的标准写法」：用服务端权威状态而非客户端请求。
        local skilltreeupdater = player.components.skilltreeupdater
		if moduleindex then
			local upgrademoduleowner = player.components.upgrademoduleowner
--★★★[第 1336-1344 行：★「没有技能时的降级规则」—— 本 handler 最精妙之处]
--   ★★★ 逻辑：如果玩家**没有** wx78_circuitry_betterunplug 技能，
--     则**只允许拔掉最后一个模块**（moduleindex == nummodules）。
--   ── 为什么这个降级规则合理？（推理）──
--     · 升级模块装在「电路棒（circuit bar）」的槽位上，是**连续排列**的；
--     · ★ 若允许拔掉中间某个，会在中间留下一个「空洞」；
--     · ★★ 而后续安装新模块需要「紧挨着的连续槽位」，空洞会阻碍安装；
--     · ★★ 所以「无技能」玩家被限制为「只能拔最末尾那个」，
--       ★ 保证剩余模块始终是「从头开始的连续段」，不会产生空洞。
--   ★★★ 这是一个「数据布局约束」驱动的权限设计 ——
--     ★ 权限规则来自「数据必须保持某种结构」的业务要求，而非任意设定。
--   ★ 第 1341 行的拒绝日志：`print("Cannot unplug module %i of %i", ...)`
--     ★ 格式串用 %i（整数），与 moduleindex 的整数语义一致（:1326 checknumber 允许浮点，
--       ★ 但 %i 会四舍五入——推断实际传入的一定是整数）。
--   ★★ 第 1339 行 `GetNumModules(modulebartype_or_socketposition)`：
--     ★ 获取该类型电路棒的模块总数（用于判断「是否最后一个」）。
--   ★ 对比 :1356（拔插口）的技能门槛是「硬性」的（无降级），
--     —— 因为拔插口不存在「空洞」问题。
			if upgrademoduleowner then
				-- Ensure we have the skill.
				if not (skilltreeupdater and skilltreeupdater:IsActivated("wx78_circuitry_betterunplug")) then
					local nummodules = upgrademoduleowner:GetNumModules(modulebartype_or_socketposition)
					if moduleindex ~= nummodules then
						print(string.format("Cannot unplug module %i of %i", moduleindex, nummodules))
						return
					end
				end
				local _module = upgrademoduleowner:GetModule(modulebartype_or_socketposition, moduleindex)
				if _module then
					player:PushEventImmediate("unplugmodule", _module)
				else
					print(string.format("Module %i not found", moduleindex))
				end
			end
		else
--★★★[第 1353-1365 行：拔「暗影插口」路径 —— 硬性技能门槛]
--   ★★★ 与拔模块路径的对比：
--     · 拔模块：无技能时有降级（只能拔最后一个）；
--     · ★ 拔插口（:1356）：无技能直接 return（完全禁止，无降级）。
--   ★★ 推理：因为暗影插口是「隐藏槽位」，拔它会影响别的东西
--     （暗影相关机制），没有「安全降级」可言。
--   ★★★ 第 1360 行：IsSocketNameForPosition(SOCKETNAMES.SHADOW, ...)
--     ★★ 先验证「这个位置确实是暗影插口名」—— 防止玩家传一个普通插口位置
--       混过技能检查（因为一旦拿到 wx78_allegiance_shadow 技能，
			local socketholder = player.components.socketholder
			if socketholder then
				--Ensure we have the skill.
				if not (skilltreeupdater and skilltreeupdater:IsActivated("wx78_allegiance_shadow")) then
					print("Shadow socket inaccessible")
					return
				end
--★★[IsSocketNameForPosition —— ★★ 「名字验证」防止技能门槛被绕过]
--   ★★★ 关键安全推理：
--     · 只要玩家有 wx78_allegiance_shadow 技能，:1356 的检查就通过；
--     · ★★ 若没有 IsSocketNameForPosition 验证，玩家可以传**任意**位置，
--       ★★ 用「暗影技能」去拔一个**普通**插口（绕过普通插口的其他限制）；
--     · ★★ 这是「有 A 权限 ≠ 有 B 权限」的经典漏洞，此处用名字验证堵住。
--   ★★★ 这体现了「权限检查要精确到资源类型」的原则。
				if socketholder:IsSocketNameForPosition(SOCKETNAMES.SHADOW, modulebartype_or_socketposition) then
					socketholder:TryToUnsocket(modulebartype_or_socketposition)
				else
					print("Shadow socket [%i] not found", modulebartype_or_socketposition)
				end
			end
		end
    end,

--★★ UnplugModule 结束。★★★ 它是本文件「权限设计」最复杂的 handler：
--   · 双路径（拔模块 / 拔插口）由可选参数区分；
--   · ★ 拔模块路径有「数据布局约束」驱动的降级规则（:1336-1344）；
--   · ★ 拔插口路径有硬性技能门槛 + 位置名字验证（:1356-1360）。
--   ★★ 核心原则：★ 权限检查用服务端权威状态（skilltreeupdater），
--     ★ 且精确到资源类型（不因有 A 权限就能操作 B 资源）。
--★ StopUsingDrone —— 停用无人机。零参数。
--   ★ 与 :1377 StopInspectingModules 同属「实体方法转发」类。
	StopUsingDrone = function(player)
		if player.StopUsingDrone then
			player:StopUsingDrone()
		else
			printinvalid("StopUsingDrone", player)
		end
	end,

--★ StopInspectingModules —— 停止检视模块。零参数。
	StopInspectingModules = function(player)
		if player.StopInspectingModules then
			player:StopInspectingModules()
		else
			printinvalid("StopInspectingModules", player)
		end
	end,

--★★★[第 1385 行："NOTES(JBK): RPC limit is at 128, with 1-127 usable."]]
--   ★★★★ 这条注释是全文件最重要的**协议约束**：
--     · RPC 数字 ID 上限是 128（推测是 C++ 侧的传输位宽限制）；
--     · ★★ 实际可用只有 1-127（0 保留为「无效/未分配」）。
--   ★★★ 为什么 0 不可用？因为 §四 的编号从 i=1 开始（第 1391 行 i = 1）。
--   ★★★★ 这个上限解释了本文件的整个设计取舍：
--     · ★ 为什么每个操作一个独立 RPC（而不是一个通用 RPC 带操作码）？
--       因为独立的 RPC 消耗的是**有限的 127 个编号**，所以它们「很宝贵」。
--     · ★ 为什么模组 RPC 不占这 127 个名额？
--       因为模组用 namespace + id 的二级索引（:1834 AddModRPCHandler），
--       id 由每个 namespace 独立从 1 开始（:1844 `id = #MOD_RPC_HANDLERS[namespace]`），
--       ★★ 完全绕开了 127 的全局上限。这是模组 RPC 架构的核心动机。
--     · ★★ 当前内置 handler 数量：约 90 个，距 127 还有余量，
--       但余量有限 —— ★ 这就是为什么不能无限新增内置 RPC。
--   ★ 参见 01-报告/04-联机同步-模组系统-UI.md 的 RPC 通道章节。
    -- NOTES(JBK): RPC limit is at 128, with 1-127 usable.
}
--★★★ RPC_HANDLERS 表结束。整个客户端→服务端方向的约 90 个 handler 都在上面。
--   ★★ 回顾本段的共同骨架（≈90 次重复）：
--     ① 参数校验（check*/opt*）→ 非法则 printinvalid + return
--     ② 坐标还原（若带 platform）→ 转换后 IsPointInRange
--     ③ 组件判空（player.components.xxx ~= nil）
--     ④ 语义检查（状态标签、容器打开、技能持有）
--     ⑤ 转发到组件
--   ★★★ 而「不可信方向」正是这 1300 行密集校验的根本原因。
--     （对比：客户端→客户端和分片→分片的两个表加起来不到 300 行，无需校验。）

RPC = {}

--★ RPC_HANDLERS 结束。★★ 接下来是编号机制（§四）——
--   「代码名 → 数字」的终身绑定，以及为什么它对模组不适用。
--Generate RPC codes from table of handlers
local i = 1
--★★★[i = 1 —— 编号从 1 开始（0 保留为「无效」的证据见 :1385 的注释）]
--   ★ 第 1385 行说「1-127 可用」，与此处的 `i = 1` 完全对应。
for k, v in orderedPairs(RPC_HANDLERS) do
--★★★★★[orderedPairs —— ★★ 编号机制的核心，也是本文件最需要警惕的设计]
--   for k, v in orderedPairs(RPC_HANDLERS) do RPC[k] = i; i = i + 1 end
--   ★★★ 关键点：**orderedPairs 按表的定义顺序**遍历（而非 pairs 的任意顺序）。
--     · RPC[k] = i 建立「名字 → 数字」的映射。
--     · ★★ i 递增，为每个 handler 分配**终身**编号。
--   ★★★★ 终身绑定的三重含义（★ 这是移植时的头号注意事项）：
--     1) 这个循环只在**加载时**执行一次。
--     2) 此后往 RPC_HANDLERS 里**新增键不会获得编号**（代码不再重跑）。
--     3) 顺序由表的字面定义顺序决定 —— ★★ 改动表内 handler 的排列顺序，
--        会**改变所有编号**，导致客户端与服务端对不上！
--   ★★★★ 推论（★★ 铁律）：
--     · ① 只能**在表定义里**新增 handler，绝不能在运行时 table.insert 追加；
--     · ② 绝不重排现有 handler（哪怕只是把两个换位置）；
--     · ③ ① 的原因是新键无编号，② 的原因是编号全变。
--   ★★ 这就是为什么模组 RPC 必须走 namespace + id 的独立通道（:1834）：
--     模组不能插入 RPC_HANDLERS（会重排）也不能追加（无编号），
--     所以设计了完全独立的编号空间。
--   ★★★ ⚠ 潜在风险：orderedPairs 依赖 Lua 表的插入顺序，
--     而 Lua 5.1 的表遍历对「整数键」与「哈希键」的顺序不保证。
--     RPC_HANDLERS 的键都是字符串（哈希键），Lua 5.1 的实现里哈希顺序
--     在同一版本内是确定的，但**不同 Lua 实现/版本可能不同**。
--     → 移植时应改用**显式数组**定义顺序（不依赖表遍历顺序）。
--   参见 01-报告/04-联机同步-模组系统-UI.md:106-114（对这段编号代码的分析）。
    RPC[k] = i
    i = i + 1
end
i = nil
--★ i = nil —— 立刻释放计数器变量（垃圾回收友好）。
--   ★ 这是「临时变量用完即弃」的习惯写法，Lua 社区常见。

local USERID_RPCS = {}
--★★★[USERID_RPCS = {} —— 「sender 不是实体而是 userid」的白名单表]
--   ★★★ 语义：一个 handler 函数 → true，表示「这个 handler 的第一个参数
--     是 userid 字符串而非玩家实体」。
--   ★★ 存在的原因（见 :1121 的完整分析）：
--     玩家实体尚未生成时，某些 RPC（聊天历史）必须能工作。
--   ★★ 机制（见 HandleRPC :1682-1684）：
--     if USERID_RPCS[fn] then sender = userid or sender end
--     —— 把 sender 从实体替换成 userid 字符串。
--   ★★★ 标记方式是「以函数为键」而非「以 RPC 名为键」：
--     · 因为 HandleRPC 里查到的是函数（fn），用它作键最直接。
--     · ★ 副作用：同一个函数若被注册为多个 RPC，标记会同时生效
--       （DST 里每个 handler 独立定义，所以不冲突）。
--   ★ 注册入口是 MarkUserIDRPC（:1980）。
--   ★★ 这张表为空时不生效；本文件中被标记的 handler 主要有 GetChatHistory（:1114）。

--Switch handler keys from code name to code value
for k, v in orderedPairs(RPC) do
--★★★[第 1401-1404 行：★「键从名字换成数字」的原地转换]
--   for k, v in orderedPairs(RPC) do
--       RPC_HANDLERS[v] = RPC_HANDLERS[k]  -- 用数字做键，值从名字键取出
--       RPC_HANDLERS[k] = nil              -- 删掉名字键
--   end
--   ★★★ 意图：把 RPC_HANDLERS 从「名字 → 函数」**就地改造**为「数字 → 函数」，
--     这样 HandleRPC（:1676 `local fn = RPC_HANDLERS[code]`）就能 O(1) 直接查。
--   ★★ 为什么这样绕（为什么不直接建一个新表）？
--     · 省内存：新表 + 复制 = 多一份表；就地改造 = 复用同一份。
--     · 省 GC：新表是临时垃圾，就地改造不产生额外垃圾。
--   ★★ 关键点：遍历的是 RPC（名字→数字），不是 RPC_HANDLERS ——
--     ★ 因为 RPC 表此刻还是「名字→数字」形态，正好用来做转换的驱动。
--       遍历顺序对结果无影响（因为用 v=数字去索引，不依赖顺序）。
--   ★★★ 改造后两个表并存：
--     · RPC         = 名字 → 数字（客户端发送时用：RPC.LeftClick = 1）
--     · RPC_HANDLERS = 数字 → 函数（服务端接收时用：RPC_HANDLERS[1]）
--   ★ 这是一份「双向映射表」的经典手工实现（名字↔数字）。
--   ★★★ ⚠ 改造后 RPC_HANDLERS 里不再有名字键 —— 
--     所以 §三 里所有的 RPC_HANDLERS.Xxx 引用若在运行时执行会拿到 nil。
--     → 这是「加载期一次性转换」的必然后果，移植时不能在本文件运行期再按名字查。
    RPC_HANDLERS[v] = RPC_HANDLERS[k]
    RPC_HANDLERS[k] = nil
end
--★ 编号与转换结束。接下来是 CLIENT_RPC_HANDLERS（服务端→客户端，可信方向）。

--★★★★★[第 1406 行："these rpc's don't need special verification because
--             server->client communication is already trusted."]
--   ★★★ 这是本文件**第二个**方向的信任前提声明（第一个在 :1537）。
--   ★★★ 它直接决定了 CLIENT_RPC_HANDLERS（:1409-1519）的写法：
--     · ★★ 16 个 handler 里**没有一个** printinvalid 调用；
--     · ★★ 几乎**没有一个**参数类型校验（直接用参数）；
--     · ★★ 几乎**没有一个** IsPointInRange（没有坐标需要校验）。
--   ★★ 对照 RPC_HANDLERS（90 个 handler，1300 行，层层校验）——
--     ★ 差异的根源就是这一行注释。
--   ★★ 安全推理：为什么服务端→客户端可信？
--     · 服务端是权威，数据源是它自己的组件；
--     · 客户端收到后直接执行（如 popup.fn），不存在「伪造可能」；
--     · ★ 客户端可能「崩溃/异常」，但这不是「安全问题」，是「兼容性问题」。
--   ★★ 为什么不加防御性判空？
--     本文件仍然有 ThePlayer ~= nil 的检查（:1706）与 component ~= nil（多处），
--     ★ 但**没有**参数校验 —— 那是纯粹的「类型安全」，与服务端无关。
--   参见 01-报告/04-联机同步-模组系统-UI.md:119（CLIENT_RPC 可信级别说明）。
--these rpc's don't need special verification because server->client communication is already trusted.
--★★★[CLIENT_RPC_HANDLERS —— 服务端 → 客户端方向的 16 个处理器（1407-1519）]
--   ★★★ 与 RPC_HANDLERS 的结构性差异（★ 对照学习最有效的方式）：
--     ┌──────────────────┬──────────────────┬──────────────────┐
--     │ 维度             │ RPC（:59）       │ CLIENT_RPC（本表）│
--     ├──────────────────┼──────────────────┼──────────────────┤
--     │ 第一个参数       │ player（发送者） │ ★★ 无（直接是数据）│
--     │ 参数校验         │ ★ 每 handler 必有 │ ★★ 无             │
--     │ printinvalid     │ ★ 每 handler 必有 │ ★★ 无             │
--     │ 坐标/范围检查    │ ★ 按需            │ ★★ 无（无坐标）   │
--     │ 组件判空         │ ★ 每 handler 必有 │ ★ 有（客户端状态）│
--     │ 行数             │ ≈1300 行          │ ≈110 行           │
--     └──────────────────┴──────────────────┴──────────────────┘
--   ★★★ ★★ 关键：★ 第一个参数的差异。
--     · RPC_HANDLERS 的 player 是「谁发的」（需要审计来源）
--     · CLIENT_RPC_HANDLERS 已经是「我的数据」（来源无需审计）
--     → 因此所有 handler 直接操作 ThePlayer（自己的玩家实体）。
--   ★★★ 绝无 TheNet:GetIsServer() 或 ismastersim 检查 ——
--     因为 CLIENT_RPC 只在客户端执行（服务端发出的消息到服务端无效）。
local CLIENT_RPC_HANDLERS =
{
--★★[ShowPopup —— 「弹窗显示」的通用协议（与 :1073 ClosePopup 配对）]
--   ★★★ 参数：popupcode, mod_name, show（是否显示）, ...（弹窗自定义数据）。
--   ★★ 第 1410 行：local popup = GetPopupFromPopupCode(popupcode, mod_name)
--   ★★ 第 1412-1414 行：`if popup then popup.fn(ThePlayer, show, ...) end`
--     ★★ 只有一个判空，没有其他检查 —— ★ 这就是「可信方向」的写法。
--   ★★ 与 ClosePopup（:1073）的对照：
--     · 关闭（C2V，:1073）: 有 validaterpcfn 验证
--     · 消息（V2C，本行）:  **无** 验证
--   ★★★ 这个不对称是有意义的：
--     · 服务端下发的数据不需要「防伪造」（服务端自己可信）；
--     · 客户端→服务端的 ClosePopup 才需要（防客户端乱关别人弹窗）。
--     ★★ 印证「校验强度由信任级别决定」，本文件严格执行这一原则。
--   ★ popup.fn 是「显示函数」（直接调用），与 :1083 的 popup:Close（方法调用）
--     形成对照 —— ★ 注意 fn 用点号（无 self），Close 用冒号（有 self）。
--     推理：fn 是「纯函数式」的显示入口，Close 是「方法式」的关闭操作。
    ShowPopup = function(popupcode, mod_name, show, ...)
        local popup = GetPopupFromPopupCode(popupcode, mod_name)

        if popup then
            popup.fn(ThePlayer, show, ...)
        end
    end,

--★★[RecievePopupMessage —— 客户端版本，与 :1089 完全镜像]
--   ★ 第 1421 行：popup:SendMessageToClient(ThePlayer, ...)
--   ★★ 与服务端版（:1097 的 SendMessageToServer）对称。
--   ★⚠ 同样没有 validaterpcfn —— 见 :1089 的不对称分析。
    RecievePopupMessage = function(popupcode, mod_name, ...)
        local popup = GetPopupFromPopupCode(popupcode, mod_name)

        if popup then
            popup:SendMessageToClient(ThePlayer, ...)
        end
    end,

--★★[LearnRecipe —— 教学配方：★ 用 {...} 捕获变长参数作为材料列表]
--   ★★★ 第 1427 行：`local ingredients = {...}`
--     把变长参数打包成 table（材料 ID 列表）。
--   ★★★ 第 1428 行的三重检查：
--     `if cookbookupdater and product and not IsTableEmpty(ingredients)`
--     ★★ 注意：这里**有**判空和空表检查 —— 说明客户端 RPC 并非「裸奔」，
--       而是做了「防客户端状态异常」的检查。
--     ★★ 区别：服务端→客户端的检查是「防御客户端崩溃」，
--       不是「防御恶意消息」。
--   ★★ 对比 LeftClick（:62）的 13 参数校验（防御恶意消息）——
--     性质根本不同。★ 读代码时区分这两类检查很重要。
    LearnRecipe = function(product, ...)
        local cookbookupdater = ThePlayer.components.cookbookupdater
        local ingredients = {...}
        if cookbookupdater and product and not IsTableEmpty(ingredients) then
            cookbookupdater:LearnRecipe(product, ingredients)
        end
    end,

--★ LearnFoodStats —— 教学食物属性（烹饪相关的数值知识）。
--   ★ 与 LearnRecipe 同族：都是「解锁图鉴/知识」类。
    LearnFoodStats = function(product)
        local cookbookupdater = ThePlayer.components.cookbookupdater
        if cookbookupdater and product then
            cookbookupdater:LearnFoodStats(product)
        end
    end,

--★ LearnPlantStage —— 教学植物生长阶段（农业知识图鉴）。
--   ★★ plant 和 stage 都做了判空（:1442 `plant and stage`）——
--     两个依赖参数都要检查。
    LearnPlantStage = function(plant, stage)
        local plantregistryupdater = ThePlayer.components.plantregistryupdater
        if plantregistryupdater and plant and stage then
            plantregistryupdater:LearnPlantStage(plant, stage)
        end
    end,

--★ LearnFertilizerStage —— 教学肥料知识。
    LearnFertilizerStage = function(fertilizer)
        local plantregistryupdater = ThePlayer.components.plantregistryupdater
        if plantregistryupdater and fertilizer then
            plantregistryupdater:LearnFertilizer(fertilizer)
        end
    end,

--★ TakeOversizedPicture —— 拍超大尺寸的「生物图鉴照片」（超过某尺寸）。
--   ★★ 参数：plant, weight（重量阈值）, beardskin, beardlength（体型定制）。
--     这个 RPC 揭示了一个游戏机制：玩家可以拍「超规格」的生物照片（游戏内趣味）。
    TakeOversizedPicture = function(plant, weight, beardskin, beardlength)
        local plantregistryupdater = ThePlayer.components.plantregistryupdater
        if plantregistryupdater and plant and weight then
            plantregistryupdater:TakeOversizedPicture(plant, weight, beardskin, beardlength)
        end
    end,

--★ RecieveChatHistory —— 接收聊天历史（与 :1114 GetChatHistory 配对）。
--   ★★★ 这是一个「双向 RPC 对」的例子：
--     · C2V: GetChatHistory  (:1114)  客户端请求历史
--     · V2C: RecieveChatHistory (本行) 服务端返回历史
--   ★★ 这是「请求-响应」模式，也是本文件中**唯一**一个需要往返的 RPC 对。
--   ★ ★「Recieve」是拼写错误（同 :1089），已成为协议标识，不能修改。
--   参见 chathistory.lua（聊天历史的存储与分页逻辑）。
    RecieveChatHistory = function(chat_history)
        ChatHistory:RecieveChatHistory(chat_history)
    end,

--★★[LearnBuilderRecipe —— ★ 用 PushEvent 而非组件方法，唯一的例外]
--   ThePlayer:PushEvent("LearnBuilderRecipe", {recipe = product})
--   ★★ 16 个 CLIENT_RPC 里**只有这一个**不走组件方法，而是推事件。
--   ★★ 推理：建造配方（builder recipe）涉及 UI 交互，
--     用事件让 UI 层订阅（解耦），而不是让 cookbook 组件直接改 UI。
--   ★★ 事件名「LearnBuilderRecipe」是 PascalCase，与其他事件（onuse 等）不同，
--     命名不规范，但 ★ 它是约定的接口名（模组可能监听），不能改。
    LearnBuilderRecipe = function(product)
        ThePlayer:PushEvent("LearnBuilderRecipe",{recipe=product})
    end,

--★★[UpdateAccomplishment —— 用通用 KV 存储「成就」进度]
--   ★★★ TheGenericKV:SetKV(name, "1") —— 通用键值存储。
--   ★★ 只存字符串「1」，不存数值 —— 「已解锁」的布尔语义。
--   ★ name 来自服务端（未校验）—— ★ 因为服务端可信。
--   ★★ TheGenericKV 是个全局 KV 存储，支持任何 name，
--     ★ 这是一个「开放式存储 API」——新成就无需改本文件。
    UpdateAccomplishment = function(name)
        TheGenericKV:SetKV(name, "1")
    end,

--★★★[UpdateCountAccomplishment —— 计数型成就，含单调递增保护]
--   ★★★ 第 1474 行：读取当前值（默认 0）
--   ★★★ 第 1476-1478 行：`if maxvalue ~= nil and current >= maxvalue then return end`
--     ★★ 这是「防溢出/防倒退」保护：达到上限就不再增加。
--   ★★ 第 1480 行：tostring(current + 1) —— ★★ 为什么加 1 而不是传新值？
--     推理：服务端只下发「增量为 1」的指令，实际值由客户端自己算。
--     ★★ 这是「增量同步」而非「绝对值同步」—— 节省带宽（1 字节 vs 多字节数字）。
--     ★★ 安全性：客户端只能 +1（不能直接跳到 10000）——
--       这其实是一个**隐式的速率限制**（每条 RPC 只 +1）。
--     ★ 但客户端可以**连发**这个 RPC 快速累加 —— → 速率受统一限流（:1687）约束。
--   ★ 泛化理解：这是「乐观更新 + 服务端放行」的典型实现。
    UpdateCountAccomplishment = function(name, maxvalue)
        local current = tonumber(TheGenericKV:GetKV(name) or 0)

        if maxvalue ~= nil and current >= maxvalue then
            return
        end

        TheGenericKV:SetKV(name, tostring(current + 1))
    end,

--★★★[SetSkillActivatedState —— 与 :1159 完全对称的客户端版本]
--   ★★★ 逐字对照服务端版（:1159-1183）：
--     · 都用 TheSkillTree:GetSkillNameFromID(prefab, skill_rpc_id)
--     · 都用 skilltreeupdater:ActivateSkill / DeactivateSkill
--   ★★★ 但有一个关键**不对称**：
--     · 服务端版（:1179-1180）：**只处理 isunlocked=true**（Deactivate 被注释掉）
--     · 客户端版（:1499-1501）：**两者都处理**（有 DeactivateSkill）
--   ★★★ 这个不对称的原因是：
--     · 服务端只「允许加锁」（安全优先 —— 见 :1177-1180 的分析）；
--     · 客户端要「双向响应」（UI 同步 —— 客户端收到 false 才移除技能图标）。
--   ★★ 一旦客户端收到 isunlocked=false（虽然服务端不会主动发 false），
--     它也能正确处理 UI。★ 这是一种「防御性对称」的设计。
--   ★★★ 另一个差异：服务端版检查 characterprefab 用 player.prefab，
--     客户端版用 ThePlayer.prefab（:1484）—— 各自的上下文。
    SetSkillActivatedState = function(skill_rpc_id, isunlocked)
        local characterprefab = ThePlayer.prefab or nil
        if characterprefab == nil then
            return
        end

        local skill = TheSkillTree:GetSkillNameFromID(characterprefab, skill_rpc_id)

        if skill == nil then
            return
        end

        local skilltreeupdater = ThePlayer.components.skilltreeupdater
        if skilltreeupdater then
            if isunlocked then
                skilltreeupdater:ActivateSkill(skill, nil, true)
            else
                skilltreeupdater:DeactivateSkill(skill, nil, true)
            end
        end
    end,

--★ AddSkillXP —— 客户端版本。amount 判空（:1507 `if ... and amount`）。
--   ★ 与服务端版（:1185）对称，同样**无范围检查**。
    AddSkillXP = function(amount)
        local skilltreeupdater = ThePlayer.components.skilltreeupdater
        if skilltreeupdater and amount then
            skilltreeupdater:AddSkillXP(amount, nil, true)
        end
    end,

--★★[PostActivateHandshake —— 客户端版本，与 :1196 对称]
--   ThePlayer:OnPostActivateHandshake_Client(state)
--   ★★ 与服务端版（:1202 的 OnPostActivateHandshake_Server）配对。
--   ★ 「_Server / _Client」后缀是明确的跨端标识 —— ★ 值得学习。
--   ★★★ 本函数**无判空**（直接调 ThePlayer:...），
--     与 :1483 的「characterprefab == nil then return」不同风格。
--     推理：激活握手时 ThePlayer 必然存在（否则不会有激活消息）。
    PostActivateHandshake = function(state)
        ThePlayer:OnPostActivateHandshake_Client(state)
    end,

--★ TryToTeachScrapbookData —— 教学图鉴数据（与 :1205 C2V 对应）。
--   ★ ★ 对比 :1205（C2V 版用 TheScrapbookPartitions）。
--     本行（V2C 版）用 TheScrapbookPartitions:TryToTeachScrapbookData(false, inst)。
--     ★ 注意 false 参数（推测是「非服务端/客户端标记」）。
    TryToTeachScrapbookData = function(inst)
        TheScrapbookPartitions:TryToTeachScrapbookData(false, inst)
    end,
}

--★★[CLIENT_RPC = {} —— 与 RPC（:1388）对称的编号表]
--   ★★★ 结构完全同构：编号 → 就地改造。
--   ★★ 两个方向的编号是**各自独立**的（都从 1 开始）——
--     因为两个方向的 code 在不同的网络消息类型里，数值相同不冲突。
--   ★★ 这是「按通道独立编号」的必然设计（见 :1391）。
CLIENT_RPC = {}

--Generate RPC codes from table of handlers
--★ i = 1 —— 重新初始化计数器（★★★ 注意：这里复用了第 1391 行的变量 i）]
--   ★★★ i 在 :1396 被设为 nil（:1401-1404 的转换循环结束后），
--     现在第 1524 行重新赋值 i = 1 为 CLIENT_RPC 编号。
--     ★ 说明 i 是**文件级局部变量**，跨越三个编号块复用。
--   ★→ 每个编号块结束后都置 nil（:1529）—— 防止误用。
i = 1
--★ for k, v in orderedPairs(CLIENT_RPC_HANDLERS) —— 与 :1392 同样的机制。
--   ★★ 完全同构：orderedPairs 保证顺序 → 编号终身绑定。
--   ★ 对照 RPC_HANDLERS（:1392）的注释，本处机制一致，约束相同。
for k, v in orderedPairs(CLIENT_RPC_HANDLERS) do
    CLIENT_RPC[k] = i
    i = i + 1
end
i = nil

--★★[第 1531-1535 行：CLIENT_RPC_HANDLERS 的键转换为数字（同 :1401）]
--   ★★★ 机制完全一致：遍历 CLIENT_RPC（名字→数字），
--     用数字给 CLIENT_RPC_HANDLERS 建键，删名字键。
--   ★ 结果：CLIENT_RPC_HANDLERS 变成「数字 → 函数」，供 :1707 的
--     `CLIENT_RPC_HANDLERS[code]` O(1) 查。
--Switch handler keys from code name to code value
for k, v in orderedPairs(CLIENT_RPC) do
    CLIENT_RPC_HANDLERS[v] = CLIENT_RPC_HANDLERS[k]
    CLIENT_RPC_HANDLERS[k] = nil
end

--★★★★★[第 1537 行："these rpc's don't need special verification because
--             server<->server communication is already trusted."]
--   ★★★ 第三个方向的信任前提声明。措辞更准确：「server<->server」（双向的服务端）
--     即分片间的通信 —— 分片都是服务端进程（见 prefabs/world.lua:426-427）。
--   ★★ 这是本文件的三方向信任模型总结：
--     · C2V（:1406）：服务端→客户端 —— 可信
--     · S2S（:1537）：分片→分片   —— 可信（★ 「分片也是服务端」）
--     · C2S（:59区）：客户端→服务端 —— ★ 不可信（唯一需要全部校验的）
--   ★★ 设计原则总结：★ **「凡是从客户端来的都不可信，其余都可信」**。
--these rpc's don't need special verification because server<->server communication is already trusted.
--★ WorldSettings_Overrides = require("worldsettings_overrides")
--   ★★★ 本文件唯一的第三条 require（除了 :1 的 util）。
--   ★★★ 加载时机极讲究：放在 SHARD_RPC_HANDLERS（:1539）**之前**。
--     ★ 为什么？因为 SyncWorldSettings（:1571）要在运行时用到这个表。
--       ★★ 但为什么不在文件顶部（:1）加载？
--       推理：worldsettings_overrides 可能很重（覆盖所有世界设置），
--       而 :1 的 util 是必须先加载的基础工具。
--       ★ 「就近加载」减少了所有环境下的无条件加载成本。
--       （注：即便如此，本文件被加载时它总会加载 —— 因为函数体内的引用
--        在 SyncWorldSettings 被调用前就要求 WorldSettings_Overrides 已赋值。）
--   ★ 对照 util 在 :1 加载 —— 两种就近/顶部加载并存的例子。
local WorldSettings_Overrides = require("worldsettings_overrides")
--★★★[SHARD_RPC_HANDLERS —— 分片 → 分片方向的 13 个处理器（1539-1618）]
--   ★★★ 这是第三条通道，专用于「多分片集群」的跨进程同步。
--     场景：主分片（表面）与次分片（洞穴）是两个独立的 Sim 进程
--     （见 prefabs/world.lua:426-427 的 ismastersim/ismastershard）。
--   ★★★ 与前两个方向的关键差异：
--     · ★★ 第一个参数是 **shardid**（分片 ID，字符串），不是 player/userid；
--     · ★ 分片通信**不涉及玩家数据**，故无 player 参数、无 userid 转换；
--     · ★ 信任级别：可信（同为服务端进程）。
--   ★★ 所有 handler 都以 shardid 为第一参数（如 :1541 ShardTransactionSteps）。
--   ★★★ 实际功能（13 个分三类）：
--     ① 事务同步（ShardTransactionSteps, PruneShardTransactionSteps, :1541-1557）
--        —— 跨分片的分步提交。
--     ② 设置同步（SyncWorldSettings, ResyncWorldSettings, :1571-1594）
--        —— 世界设置从主分片同步到次分片。
--     ③ 状态广播（SyncWorldStateTag, SyncBossDefeated, SyncMermKing*, :1596-1617）
--        —— boss 击败状态、月王/三叉戟/皇冠/护肩状态跨分片广播。
--   ★★ 这些 Sync* 函数在 shardnetworking.lua 有对应的 Lua 包装
--     （如 :24 Shard_SyncWorldSettings、:222 Shard_SyncBossDefeated）。
--   ★ 交叉引用：shardnetworking.lua（分片互联的完整逻辑）。
local SHARD_RPC_HANDLERS =
{
--★★★[ShardTransactionSteps —— ★ 跨分片事务的「分步提交」]
--   ★★★ 参数：shardid（发送方分片）、shardpayload_string（序列化的事务载荷）。
--   ★★★ 第 1542 行的注释揭示了一个协议细节：
--     "shardid is converted to an integer and must be back to string."
--     ★★ 「分片 ID 在传输中被转为整数，必须转回字符串」——
--       传输层做类型优化（字符串→整数省空间），接收端手动还原。
--       ★ 代价：本文件的 handler 里到处是 `shardid = tostring(shardid)`（:1542/:1552）。
--   ★★★ 第 1545-1548 行：安全沙箱 + 来源校验的双重保护：
--     RunInSandboxSafe(shardpayload_string) —— 反序列化载荷
--     if success and (shardid == shardpayload.originshardid
--                  or shardid == shardpayload.receivershardid) then
--       shardtransactionsteps:OnShardTransactionSteps(shardpayload)
--     ★★★ ★ 这是本文件**最严格的入站校验**：
--       ① RunInSandboxSafe 在沙箱里反序列化（防恶意 Lua 注入）。
--       ② ★★★ 校验发送方分片 ID 与载荷声明的 origin/receiver **一致**！
--     ★ 这一点很重要：它防止一个分片伪造另一个分片的事务。
--     ★★ 即使分片间「可信」，这里仍然校验 —— 说明「可信」不等于「不校验」，
--       而是「校验的是来源一致性，而非类型/范围」。
--   ★ RunInSandboxSafe 是全项目通用的安全反序列化（也见 :1572/:1576/:1908）。
--   ★ 对照 :1097（RecievePopupMessage 无校验）—— 严格程度差异巨大。
    ShardTransactionSteps = function(shardid, shardpayload_string)
--★★[第 1542 行：shardid = tostring(shardid) —— 手动类型还原]
--   ★★ 传输层把 shardid（字符串）转成了整数，接收时转回来。
--   ★ 这说明底层网络协议对分片 ID 做了压缩（可能转整数传输）。
--   ★→ 移植时若分片 ID 格式改变（如带前缀），这几处 tostring 都要改。
        shardid = tostring(shardid) -- shardid is converted to an integer and must be back to string.
        local shardtransactionsteps = TheWorld and TheWorld.components.shardtransactionsteps or nil
        if shardtransactionsteps then
            local success, shardpayload = RunInSandboxSafe(shardpayload_string)
--★★★[来源校验：shardid == originshardid or shardid == receivershardid]
--   ★★★ 这是本文件**最强的一道校验**，值得逐字理解：
--     · shardid 是「这个 RPC 从哪个分片来的」（由 HandleShardRPC 传入）；
--     · shardpayload.originshardid 是「事务的发起方」；
--     · shardpayload.receivershardid 是「事务的接收方」；
--   ★★ 条件：发送分片必须是「发起方」或「接收方」之一，否则拒绝。
--     ★★ 语义：只有「事务的两端之一」才能报告事务进展。
--     ★ 这防止了第三方分片注入虚假的事务状态。
--   ★★ 结合 :1545 的 RunInSandboxSafe —— 两层防护：
--     · 安全沙箱（防代码执行）+ 来源一致性（防数据伪造）。
--   ★★★ 这是「即使认为源可信，也做语义校验」的典范。
--     与 :1097（RecievePopupMessage 完全不校验）形成鲜明对照。
            if success and (shardid == shardpayload.originshardid or shardid == shardpayload.receivershardid) then
                shardtransactionsteps:OnShardTransactionSteps(shardpayload)
            end
        end
    end,
    PruneShardTransactionSteps = function(shardid, newfinalizedid)
        shardid = tostring(shardid) -- shardid is converted to an integer and must be back to string.
        local shardtransactionsteps = TheWorld and TheWorld.components.shardtransactionsteps or nil
        if shardtransactionsteps then
            shardtransactionsteps:OnPruneShardTransactionSteps(shardid, newfinalizedid)
        end
    end,

--★★[ReskinWorldMigrator —— 跨分片改传送门的皮肤]
--   ★★ 参数：shardid, migrator（传送门 ID）, skin_theme, skin_id, sessionid。
--   ★★★ 第 1560-1568 行：遍历 ShardPortals 找匹配的传送门，改其外观。
--   ★ 为什么需要同步皮肤？因为传送门外观取决于「这个门通向哪个世界」
--     （不同世界有不同主题）。跨分片时需要主分片告诉次分片「你的门该长什么样」。
--   ★★ TheSim:ReskinEntity 是 C++ 侧调用（无 Lua 源码）。
    ReskinWorldMigrator = function(shardid, migrator, skin_theme, skin_id, sessionid)
        for i,v in ipairs(ShardPortals) do
            if v.components.worldmigrator.id == migrator then
                local skinname = nil
                if skin_theme ~= "" then
                    skinname = v.prefab.."_"..skin_theme
                end
                TheSim:ReskinEntity( v.GUID, v.skinname, skinname, skin_id, nil, sessionid )
            end
        end
    end,

--★★★[SyncWorldSettings —— ★ 世界设置的跨分片同步机制]
--   ★★★ 这是「分片集群保持一致」的核心。
--   ★★ 三层保护：
--     ① RunInSandboxSafe(options_string) —— 反序列化（:1572）
--     ② if success —— 只在解析成功时应用（:1574）
--     ③ 遍历 WorldSettings_Overrides 三路分派（:1578-1587）
--   ★★★ 第 1578-1587 行的分派逻辑（三路）：
--     if WorldSettings_Overrides.Sync[option] then
--         WorldSettings_Overrides.Sync[option](value)   -- ★ 同步钩子（替代默认行为）
--     else
--         if Pre[option] then Pre[option](value) end      -- 变更前钩子
--         if Post[option] then Post[option](value) end    -- 变更后钩子
--     end
--   ★★ 三种钩子语义：
--     · Sync    = 「完全接管」（有自己的实现，不走 Pre/Post）
--     · Pre     = 「变更前」（可拦截/预处理）
--     · Post    = 「变更后」（可后处理/观察）
--   ★★★ 这是一个「可插拔的设置应用」系统：
--     某些设置（如季节长度）由 Sync 完全自定义逻辑，
--     其他走「应用前后各留一个钩子」的通用流程。
--   ★★ 对照发送侧（shardnetworking.lua:24 Shard_SyncWorldSettings）：
--     那里的 Customize.GetSyncOptions() 筛选出「可同步」的设置项，
--     ★ 发送与接收用同一个 sync_options 白名单，保证只同步该同步的。
--   ★ 详见 shardnetworking.lua:24-41 的注释（可选的交叉引用）。
    SyncWorldSettings = function(shardid, options_string)
--★★[第 1572-1573 行：RunInSandboxSafe + 打印「收到主分片的世界设置」]
--   ★★★ 打印日志带 shard 上下文，便于调试集群同步问题。
--     ★ 这与 :33（打印失败诊断）、:39（超距打印）是同一日志风格。
--   ★★ 第 1576 行也打印每个被应用的设置（option = value）——
--     ★★ 生产环境这种逐项打印可能造成日志膨胀（分片多时）。
--       但考虑到「设置同步」是低频操作（启动时/重同步），可接受。
--     ⚠ 若高频重同步（如频繁 ResyncWorldSettings）就会刷屏。
        local success, data = RunInSandboxSafe(options_string)
		print("[SyncWorldSettings] recieved world settings from master shard.", success)
        if success then
            for option, value in pairs(data) do
				print("[SyncWorldSettings] applying " .. option .. " = " .. value .. " from master shard.")

                if WorldSettings_Overrides.Sync[option] then
                    WorldSettings_Overrides.Sync[option](value)
                else
                    if WorldSettings_Overrides.Pre[option] then
                        WorldSettings_Overrides.Pre[option](value)
                    end
                    if WorldSettings_Overrides.Post[option] then
                        WorldSettings_Overrides.Post[option](value)
                    end
                end
            end
        end
    end,

--★★[ResyncWorldSettings —— 简单的转发，第 1592-1594 行]
--   Shard_SyncWorldSettings(shardid, true)
--   ★★ 这是「反方向」：次分片主动请求主分片重新发送设置。
--   ★ is_resync = true（第 33 行在发送侧用作日志文案「Resyncing」）。
--   ★★ 场景：次分片启动晚，错过了主分片的初始广播，需要主动拉取。
    ResyncWorldSettings = function(shardid)
        Shard_SyncWorldSettings(shardid, true)
    end,

--★★[SyncWorldStateTag —— 同步世界状态标签（开关型状态）]
--   ★★★ 参数：shardid, namespace（命名空间）, tag（标签名）, enabled（布尔）。
--   ★★ GetWorldStateTagObjectFromNamespace(namespace) —— 按命名空间取标签对象。
--     worldstatetagobject.SetTagEnabled(tag, enabled) —— 设置开关。
--   ★★ 这是「跨分片同步一个布尔状态」的最简形式。
--     ★ 命名空间 + 标签名 = 两级索引，避免命名冲突。
--   ★★ 对照 :1454 TakeOversizedPicture（V2C）：也是「命名空间」概念的应用。
--     ★ 命名空间模式在本文件反复出现（模组 RPC、popup、world tag）。
    SyncWorldStateTag = function(shardid, namespace, tag, enabled)
        local worldstatetagobject = GetWorldStateTagObjectFromNamespace(namespace)
        worldstatetagobject.SetTagEnabled(tag, enabled)
    end,

--★ SyncBossDefeated —— 同步 boss 击败状态。
--   ★★ 原注释："This should not be called often enough to warrant a lookup
--   table for bossprefab as an enum."
--   ★★★ 这条注释体现「性能优化的克制」：
--     ★ bossprefab 是字符串（预制体名），每次调用可以直接传；
--     ★ 作者认为调用频率低（每次 boss 击败一次），
--       不值得建「字符串→枚举」的查表来优化。
--     ★★ 这种「不需要优化的就不要优化」的判断很重要 ——
--       对比 :937 MakeRecipeFromMenu 的 O(n) 扫描（每次点击都发生，
--       ★ 那个确实值得优化 —— 因为它是高频）。
--   ★ 调用 Shard_SyncBossDefeated(bossprefab, shardid)（shardnetworking.lua:222）。
    SyncBossDefeated = function(shardid, bossprefab) -- NOTES(JBK): This should not be called often enough to warrant a lookup table for bossprefab as an enum.
        Shard_SyncBossDefeated(bossprefab, shardid)
    end,

    SyncMermKingExists = function(shardid, exists)
        Shard_SyncMermKingExists(exists, shardid)
    end,

    SyncMermKingTrident = function(shardid, exists)
        Shard_SyncMermKingTrident(exists, shardid)
    end,
    SyncMermKingCrown = function(shardid, exists)
        Shard_SyncMermKingCrown(exists, shardid)
    end,
    SyncMermKingPauldron = function(shardid, exists)
        Shard_SyncMermKingPauldron(exists, shardid)
    end,
}

--★★[SHARD_RPC = {} —— 第三个编号表，与前两个同构]
--   ★ 编号机制完全一致（orderedPairs → 终身编号 → 键转换）。
--   ★ 三个通道（RPC / CLIENT_RPC / SHARD_RPC）的编号**各自独立**，
--     都从 1 开始（因为它们在不同消息类型里传递）。
SHARD_RPC = {}

--Generate RPC codes from table of handlers
i = 1
for k, v in orderedPairs(SHARD_RPC_HANDLERS) do
    SHARD_RPC[k] = i
    i = i + 1
end
i = nil

--Switch handler keys from code name to code value
for k, v in orderedPairs(SHARD_RPC) do
    SHARD_RPC_HANDLERS[v] = SHARD_RPC_HANDLERS[k]
    SHARD_RPC_HANDLERS[k] = nil
end
--★★ 三个通道的编号与转换全部完成。此时三个表都是「数字 → 函数」形态：
--   · RPC_HANDLERS（:59）      —— 90 个 handler
--   · CLIENT_RPC_HANDLERS（:1407）—— 16 个 handler
--   · SHARD_RPC_HANDLERS（:1539）  —— 13 个 handler
--   ★ 接下来是发送（§七）、限流（§八）、入队（§九）、排空（§十）。

--★★★[SendRPCToServer —— ★ 三个发送函数之一，客户端→服务端]
--   ★★★ 第 1637 行的 assert：`assert(RPC_HANDLERS[code] ~= nil)`
--   ★★ 「发送前验证 code 有效」：防止发送一个未注册的 code。
--     ★ 这是**程序员错误检查**，不是安全检查（是本进程自己发的）。
--     ★ 用 assert 而非静默返回：这类错误应该立刻暴露（开发期崩溃）。
--   ★★ TheNet:SendRPCToServer(code, ...) —— C++ 侧调用，负责序列化与发送。
--   ★★★ 参数用 ... 变长转发：本文件不关心具体参数，交给 C++ 层序列化。
--     ★ 这就是「RPC 帧」的边界：Lua 只提供 code + 变长参数。
function SendRPCToServer(code, ...)
    assert(RPC_HANDLERS[code] ~= nil)
    TheNet:SendRPCToServer(code, ...)
end

--★★★[第 1641-1646 行：SendRPCToClient 的参数约定注释]
--   "--SendRPCToClient(CLIENT_RPC.RPCNAME, users, ...)"
--   "--users is either:"
--   "--nil == all connected clients"
--   "--userid == send to that userid"
--   "--table == list of userids to send to"
--   ★★★ 这段注释描述了 `users` 参数的三种形式：
--     · nil     → 广播给所有连接的客户端
--     · userid  → 发送给特定用户
--     · table   → 发送给用户列表
--   ★★ 这就是「服务端选择性广播」的参数设计（★ 但见缺陷 E）。
--   ★★★ 关于本文件的实现（SendRPCToClient:1647）——
--   ★★ 它只有 `function SendRPCToClient(code, ...)` —— ★ 没有显式的 users 参数！
--     users 是通过 ...（变长参数）隐含传入的（第一个变长参数即 users）。
--   ★ 确认：第 1649 行 TheNet:SendRPCToClient(code, ...) —— 把 users 一起转发给 C++。
--   ★★★ 所以 users 是「变长参数的第一个」，由 C++ 解释。
--     这就是为什么本文件的 Lua 侧看不到 users 形参 —— ★ 它在 ... 里。
--SendRPCToClient(CLIENT_RPC.RPCNAME, users, ...)
--users is either:
--nil == all connected clients
--userid == send to that userid
--table == list of userids to send to
--★★[第 1646 行："all users must be connected to the shard this command originated from"]
--   ★★★ 这是一个**重要的约束声明**：所有接收用户必须连接到「命令发起的那片」。
--   ★★ 推理（多分片场景）：
--     如果次分片（洞穴）发一个 V2C 给某玩家，但该玩家连接到的是主分片，
--     ★ 消息无法送达（跨分片的客户端连接是独立的）。
--   ★★ 所以分片代码在发 V2C 时必须确认玩家在本分片。
--     ★ 这解释了为什么需要 Shard_IsWorldAvailable（shardnetworking.lua:16）——
--       判断某分片是否可用（连接中）再发送。
--all users must be connected to the shard this command originated from
--★★[SendRPCToClient —— 服务端→客户端的发送函数]
--   ★ 结构与 SendRPCToServer（:1636）完全对称：
--     assert(CLIENT_RPC_HANDLERS[code] ~= nil) + TheNet:SendRPCToClient(code, ...)
--   ★★ 注意 users 参数隐含在 ... 中（见 :1641-1646 的注释分析）。
--   ★ ★ 三个发送函数的断言对象不同（RPC/CLIENT_RPC/SHARD_RPC_HANDLERS），
--     防止把 A 方向的 code 用 B 方向的函数发送。
function SendRPCToClient(code, ...)
    assert(CLIENT_RPC_HANDLERS[code] ~= nil)
    TheNet:SendRPCToClient(code, ...)
end

--★★★[第 1652-1656 行：SendRPCToShard 的参数约定]
--   "--SendRPCToShard(SHARD_RPC.RPCNAME, shards, ...)"
--   "--shards is either:"
--   "--nil == all connected shards"
--   "--shardid == send to that shard"
--   "--table == list of shards to send to"
--   ★★ 结构与 :1641 的 users 完全对称（shards ↔ users）。
--   ★★★ 这是三个发送函数参数约定的一致性体现。
--SendRPCToShard(SHARD_RPC.RPCNAME, shards, ...)
--shards is either:
--nil == all connected shards
--shardid == send to that shard
--table == list of shards to send to
--★ SendRPCToShard —— 分片→分片的发送函数。
--   ★ 结构与前两个对称：assert(SHARD_RPC_HANDLERS[code] ~= nil) + TheNet:SendRPCToShard。
function SendRPCToShard(code, ...)
    assert(SHARD_RPC_HANDLERS[code] ~= nil)
    TheNet:SendRPCToShard(code, ...)
end
--★★★ 三个发送函数区结束。它们是 Lua 侧对外暴露 RPC 能力的唯一出口：
--   SendRPCToServer  (:1636) → RPC_HANDLERS
--   SendRPCToClient  (:1647) → CLIENT_RPC_HANDLERS
--   SendRPCToShard   (:1657) → SHARD_RPC_HANDLERS
--   ★★ 每个都 assert 验证 code 有效 —— 防止方向混用。
--   ★ ★ 后面 §十五 的 DisableRPCSending 会把这三个函数整体替换为空函数。

--★★★★★[第 1662 行：RPC_QUEUE_RATE_LIMIT = 20 —— 限流的核心常量]
--   "-- Per logic tick."
--   ★★★ 语义：每个发送者每个**逻辑刻**最多入队 20 条 RPC。
--   ★★★ 关键理解：★ 这是「入队」额度，不是「执行」额度。
--     · HandleRPC（:1688）自增；
--     · HandleRPCQueue（:1731-1736）排空时自减。
--     ★★ 所以 20 条/刻是「同时在队列中待执行」的上限，
--       而不是「每秒 20 条」或「总共 20 条」。
--   ★★★ 为什么是「每刻」而不是「每秒」？
--     · 逻辑刻（tick）约 1/30 秒 → 20/刻 ≈ 600 条/秒 上限；
--     · ★ 这远高于正常玩家操作频率（人一秒点几下）。
--     · ★ 限流目的是防「单刻内突发大量 RPC 拖垮服务端」。
--   ★★ 20 这个数字的合理性：正常玩家单刻（33ms）能发几条？
--     快速连击/摇杆/持续输入可能单刻几条 —— 20 有余量。
--     而恶意客户端能单刻发几千条 → 被限流挡住。
--   ★ ★ 参见 01-报告/04-联机同步-模组系统-UI.md:1536-1567（限流的完整分析）。
local RPC_QUEUE_RATE_LIMIT = 20 -- Per logic tick.
--★★★★⚠[第 1663 行：RPC_QUEUE_RATE_LIMIT_PER_MOD = 5 —— ★★ 缺陷 B 的根源]
--   "--+this for every mod RPC added."
--   ★★★ 设计意图（善意的部分）：
--     模组注册的每个 RPC handler，给全局限流 +5。
--     ★ 意图是「用了更多模组功能 → 允许更多流量」，避免正常模组玩家被误伤。
--   ★★★★ ⚠ 但这造成了一个**严重的无上限漏洞**：
--     ★★ 第 1848 行 AddModRPCHandler 每注册一个 handler 就执行
--       `RPC_QUEUE_RATE_LIMIT = RPC_QUEUE_RATE_LIMIT + 5`，
--       ★★★ 而这个变量**没有上限**，且每个模组 handler 都触发一次。
--     ── 推理链条 ──
--     1) 模组通过 AddModRPCHandler(namespace, name, fn) 注册 handler；
--     2) 每次注册，RPC_QUEUE_RATE_LIMIT 全局 +5（:1848）；
--     3) ★ 该变量是全局的，**所有玩家、所有模组共享**；
--     4) ★★ 恶意模组注册 1000 个 handler → 限流变成 20 + 1000*5 = 5020；
--     5) ★★ 此时真正的攻击流量（单刻 5000 条）畅通无阻 —— 限流形同虚设。
--     ── 后果 ──
--     · 恶意模组可绕过限流，让攻击流量打到服务端；
--     · 所有正常玩家都被牵连（限流是全局的）；
--     · 服务端单刻要处理海量 RPC → CPU 打满 → 拒绝服务。
--   ★★★★ 这是**真实的安全缺口**（用户核实指出的那个缺口，第 1848 行执行，
--     根源常量在第 1663 行）。
--   ── 修复建议（仅记录，不改码）──
--     ① 每模组独立配额（per-namespace 限流，而非全局抬高）；
--     ② 全局硬上限（如 min(RPC_QUEUE_RATE_LIMIT, HARD_CAP)）；
--     ③ 只给「已知可信」模组放宽；
--     ④ 或者干脆不抬高全局（模组玩家偶尔超限 20 条可接受）。
--   ★★ 参见 01-报告/04-联机同步-模组系统-UI.md:1559-1565（完全相同的分析）与
--     :2381（修复方案清单）、:2926（陷阱 3：模组可无限抬高全局 RPC 限流）。
local RPC_QUEUE_RATE_LIMIT_PER_MOD = 5 -- +this for every mod RPC added.
--★★[RPC_Queue_Limiter = {} —— ★★ 「发送者 → 当前额度」的计数表]
--   ★★★ 键是 sender（玩家实体或 userid 字符串），值是「本刻已入队数」。
--   ★★★ 这是限流的**状态存储**。它的生命周期管理是本文件的关键：
--     · 自增：HandleRPC（:1688）—— 每入队一条 +1
--     · 自减：HandleRPCQueue（:1731-1736）—— 每排空一条 -1
--     · ★★ 清表：归零时置 nil（:1733-1734）—— 防内存泄漏的关键！
--   ★★★ 为什么计数器的清零如此重要（★ 移植必须照做）：
--     攻击者可以伪造**大量不同 sender**（如各种 userid），
--     让这张表不断新增键。若不清零，
--     ★★ 内存会随攻击持续增长 → 最终 OOM（拒绝服务的一种）。
--   ★ 第 1731 行的 `(RPC_Queue_Limiter[sender] or 1) - 1` ——
--     ★★ 归零逻辑：若当前是 1，减 1 得 0 → 置 nil 清表；
--       若 > 1，减 1 保留。★ 这个 or 1 兜底处理了「表里没有该 sender」的情况。
local RPC_Queue_Limiter = {}
--★★[RPC_Queue_Warned = {} —— 「已告警过的 sender」表]
--   ★★★ 用途：保证同一个 sender 超限**只打印一次**日志（:1692-1694）。
--   ★★ 为什么要「只打一次」？
--     若每超限一次就打日志，一个持续攻击的客户端能把服务器控制台刷爆
--     → 日志 I/O 本身成为 DoS 载体。
--   ★★ 代价：日志不会告诉你「攻击持续了多久」。
--     → 生产环境应把这张表接入监控，而非只看日志。
--   ★ 清表时机与 RPC_Queue_Limiter 同步（:1734）—— 归零时一并清。
local RPC_Queue_Warned = {}
--★★[RPC_Queue = {} —— ★★ 客户端→服务端的 RPC 队列（★ 主队列）]
--   ★★★ 这是一个「延迟处理」的队列：HandleRPC 入队，HandleRPCQueue 每帧排空。
--   ★★ 每项是 {fn, sender, data, tick} 四元组（:1689）：
--     · fn    = 处理函数（从 RPC_HANDLERS[code] 取出）
--     · sender= 发送者（实体或 userid）
--     · data  = RPC 载荷数据
--     · tick  = ★ 入队时的逻辑刻号（用于同刻重入保护，见 :1741）
--   ★★★ 队列存在的理由（★ 见 §九/§十 的详细分析）：
--     不立即执行，避免「在网络回调里执行游戏逻辑」的线程/时序问题。
local RPC_Queue = {}
--★★[RPC_Timeline = {} —— ★★ 同刻重入保护的状态表]
--   ★★★ 键是 sender，值是「该 sender 当前正在处理的 tick」。
--   ★★★ 用途（见 HandleRPCQueue :1741-1750）：
--     保证同一个 sender 在同一刻**只有一条 RPC 在执行**。
--   ★★ 为什么需要（推理）：
--     若玩家一连发「Put 到槽 1」「Put 到槽 2」等 RPC，
--     若在同一刻交错执行（比如第一个还没执行完，第二个就开始），
--     ★ 容器/背包这类状态机操作可能自相矛盾（顺序不确定 → 物品错乱）。
--   ★★ 解决方案：同一 sender 的 RPC 严格串行（一次只跑一条）。
--   ★ 每刻开始时清空（TickRPCQueue :1799）—— 每刻重置。
local RPC_Timeline = {}

--★★[RPC_Client_Queue = {} —— 服务端→客户端方向的队列]
--   ★★★ 与主队列的差异（★ 结构不同）：
--     · 主队列项：{fn, sender, data, tick} —— 四元组，有 sender
--     · 本队列项：{fn, data, tick}          —— 三元组，★ **无 sender**！
--   ★★ 为什么无 sender？因为这是**客户端收到**的消息（服务端→客户端），
--     客户端不需要知道「谁发的」（服务端是自己）。
--   ★★ 对照 CLIENT_RPC_HANDLERS（§五）—— 第一个参数就不是 player。
--     两处一致：客户端方向的消息不带发送者信息。
local RPC_Client_Queue = {}
--★ RPC_Client_Timeline —— 同刻重入保护的状态（客户端方向）。
--   ★★ 注意它是**单个变量**（不是表），因为客户端方向消息都发给本地玩家，
--     无需按 sender 区分。
local RPC_Client_Timeline

--★★[RPC_Shard_Queue = {} —— 分片→分片方向的队列]
--   ★ 结构与主队列相同：{fn, sender, data, tick}（四元组，有 sender）。
--   ★★ 因为分片方向也需要按发送分片做重入保护（每个分片独立）。
--   ★ ★ 三条队列的对比小结：
--     · RPC_Queue（主）：有 sender、有 limiter、每帧排空
--     · RPC_Client_Queue（V2C）：无 sender、无 limiter
--     · RPC_Shard_Queue（S2S）：有 sender、无 limiter、有重入保护
local RPC_Shard_Queue = {}
--★ RPC_Shard_Timeline —— 分片方向的同刻重入保护状态表。
local RPC_Shard_Timeline = {}
--★★★ 限流常量与队列声明区结束。接下来是本文件的「心脏」：
--   §九  HandleRPC / HandleClientRPC / HandleShardRPC —— 三条入队路径
--   §十  HandleRPCQueue —— 逐帧排空 + 同刻重入保护
--   ★★ 这两节是「为什么收到 RPC 不立即执行」的答案所在。

--★★★★★[HandleRPC —— ★★★ 本文件的心脏之一：客户端→服务端 RPC 的入口]
--   ★★★ 签名：HandleRPC(sender, tick, code, data)
--     · sender = ★ 发送者（玩家实体，或 userid 字符串）
--     · tick   = ★ 当前逻辑刻号
--     · code   = RPC 数字 ID
--     · data   = RPC 载荷（反序列化后的数据）
--   ★★★ ★★ 核心设计：**收到 RPC 不立即执行，只入队**（:1689）。
--   ★★★ 这就是「为什么收到 RPC 要入队而不是立即执行」的答案（见下方详解）。
--   ★★★★ 入队前做三件事：
--     ① 查表：RPC_HANDLERS[code] 找处理函数（:1676）
--     ② 校验发送者身份（:1678-1684）：必须是实体，或该 RPC 标记为 USERID_RPC
--     ③ 限流（:1686-1696）：检查额度，超限则丢弃并告警
--   ★★ 全函数**不做任何游戏逻辑** —— 只是「排队 + 计数」。
function HandleRPC(sender, tick, code, data)
--★★[local fn = RPC_HANDLERS[code] —— O(1) 查表]
--   ★ RPC_HANDLERS 已在 :1401-1404 被改造成「数字 → 函数」，所以这里直接查。
--   ★★ fn 为 nil 时（:1700）打印「Invalid RPC code」—— 说明收到了未注册的 code。
--     ★ 推理：客户端发了一个服务端不认识的 code（版本不匹配/恶意）。
--       ★ 注意这里**没有** printinvalid（不推事件）—— 
--       推理：连 code 都无效，说明是协议层问题而非参数问题，
--       推 invalidrpc 事件对模组没有意义（模组也无法处理未知 code）。
    local fn = RPC_HANDLERS[code]
--★ if fn ~= nil then —— 有效性检查的骨架。
--   ★ 注意结构：if/else 两个分支都只处理「无效」情形（:1700）。
--     · fn 无效 → 打印无效 code
--     · fn 有效 → 进入处理（:1678）
    if fn ~= nil then
--★★★[senderistable —— ★「发送者是实体还是 userid 字符串」的判定]
--   local senderistable = type(sender) == "table"
--   ★★★ 关键理解：★ sender 的类型决定了两件事。
--     ① 它是「实体表」（玩家）还是「字符串」（userid）？
--     ② HandleRPC 的第一参数类型在 DST 里是**不固定的**：
--       · 正常情况：sender 是玩家实体（table）；
--       · USERID_RPCS 的 RPC：sender 被替换成 userid 字符串；
--       · 未生成实体的新玩家：sender 可能是 userid 字符串。
--   ★★★ 用 type(sender) == "table" 判定（而不是 IsValid）：
--     因为此时实体可能「还没准备好」，但仍是 table；
--     ★ type 判定比「尝试访问字段」更安全（不会触发 __index）。
        local senderistable = type(sender) == "table"
--★★★[if USERID_RPCS[fn] or senderistable then —— ★★ 双重放行条件]
--   ★★★ 两个条件是「或」：
--     · USERID_RPCS[fn] 为真 → 该 RPC 允许 sender 是 userid 字符串（:1121 场景）
--     · senderistable 为真 → sender 是实体（正常情况）
--   ★★ else 分支（:1698）打印 "Invalid RPC sender: expected player, got userid"
--     ★ 语义：sender 是 userid 字符串，但这个 RPC **没有**标记 USERID_RPCS
--       → 拒绝（因为该 handler 需要实体参数，传字符串会崩）。
--   ★★★★ 这个守卫的价值（推理）：
--     若不检查，一个标记缺失的 handler 收到字符串 sender，
--     在访问 player.components（:61 等处）时会崩 ——
--     ★ 一个恶意客户端可以靠发特定 RPC 触发服务端崩溃（DoS）。
--     ★ 所以这是**安全边界**，不只是「防御性编程」。
--   ★→ 移植时：新增 handler 若第一个参数不是实体，必须调 MarkUserIDRPC（:1980）。
        if USERID_RPCS[fn] or senderistable then
--★★[local userid = senderistable and sender.userid or nil —— 提取 userid]
--   ★★★ 三目惯用法：实体 → sender.userid；字符串 → nil。
--   ★★ 提取 userid 是为了「把实体 sender 转换成字符串 userid」
--     （当 USERID_RPCS[fn] 成立时，见 :1682-1684）。
--   ★★ 注意这里能安全访问 sender.userid —— 因为 senderistable 为真（是实体 table）。
            local userid = senderistable and sender.userid or nil

--★★★[if USERID_RPCS[fn] then sender = userid or sender end —— ★ 类型替换]
--   ★★★ 语义：若该 RPC 标记为「以 userid 为第一参数」，
--     ★ 则把 sender（实体）替换为 userid（字符串）。
--   ★★ `userid or sender` 的兜底：若实体无 userid（异常），保留原实体。
--   ★★★ 替换后 handler 收到的是字符串，
            if USERID_RPCS[fn] then
                sender = userid or sender
            end

--★★★[local limit = RPC_Queue_Limiter[sender] or 0 —— ★★ 取当前额度]
--   ★★★ 「发送者 → 当前已入队数」的查表。
--   ★ or 0 兜底：没记录过 = 额度 0（还没入队过）。
--   ★★ sender 可能是实体或字符串，都可作表键（Lua 表键任意值）。
--     ★★★ 注意：★ 实体作表键意味着「每个玩家实体一个槽位」。
--       玩家实体销毁后，若不清表，这个槽位就成了泄漏 —— 
--       ★★ 这正是 :1739 的 `if type(sender)=="table" and not sender:IsValid()`
--         与 :1733-1734 的清表逻辑要存在的原因（见 :1664 的分析）。
            local limit = RPC_Queue_Limiter[sender] or 0
--★★★[if limit < RPC_QUEUE_RATE_LIMIT then —— ★★ 限流判定]
--   ★★★ 「当前额度 < 上限」→ 放行；否则拒绝。
--   ★★ 上限是 RPC_QUEUE_RATE_LIMIT（:1662，默认 20，但可被模组抬高，缺陷 B）。
--   ★★★ 这是「严格小于」：额度达到上限时（limit == 上限）就拒绝。
--     所以单刻最多入队 20 条（第 20 条时 limit 从 19→20，
            if limit < RPC_QUEUE_RATE_LIMIT then
--★★[RPC_Queue_Limiter[sender] = limit + 1 —— ★★ 入队前先占额度]
--   ★★★ 顺序（★ 关键）：★ 先自增计数器，再入队（:1689）。
--   ★★ 为什么这个顺序？保证「额度与队列长度一致」。
--     若反过来（先入队再计数），并发/异常时可能入队成功但没计数，
--     ★ 导致限流失效。
--   ★★ 自增发生在**入队时**（HandleRPC），
--     自减发生在**排空时**（HandleRPCQueue :1731）——
--     ★★★ 这就是「入队额度」而非「执行额度」的机制（见 :1662 注记）。
                RPC_Queue_Limiter[sender] = limit + 1
--★★★★★[table.insert(RPC_Queue, {fn, sender, data, tick}) —— ★ 入队]
--   ★★★ 「为什么收到 RPC 要入队而不是立即执行」的答案（★ 完整列举）：
--   ── 理由一：★ 时序确定性（最重要）──
--     · HandleRPC 由**网络层回调**触发（可能来自网络线程/反序列化时刻）；
--     · ★ 游戏逻辑（Update）期望在**确定的主循环时刻**执行；
--     · 若在网络回调里直接执行，某个 RPC 可能在「游戏状态半更新」时执行
--       （比如实体刚被创建但组件还没 ready）→ 逻辑错误。
--     · ★★ 入队后，所有 RPC 在 HandleRPCQueue（每帧一次，:1724）统一执行，
--       ★ 时刻确定（主循环末尾），状态一致。
--   ── 理由二：★ 公平性/顺序性 ──
--     · 入队保持了 RPC 的到达顺序（同一 sender 的相对顺序）；
--     · ★ 配合 RPC_Timeline 重入保护（:1741）保证串行执行。
--   ── 理由三：★ 限流的实施点 ──
--     · 限流在**入队**时实施（:1687-1688），而非执行时；
--     · ★ 入队即计数，保证「超量的 RPC 连队列都进不去」，
--       不占用处理资源。
--   ── 理由四：★ 批量处理效率 ──
--     · 一次性遍历队列（:1727）比逐个立即执行更缓存友好。
--   ★★ 这是「网络消息必须延迟到主循环处理」的通用模式 ——
--     参见 prefabs/world.lua:301 的 DoTaskInTime(0)（同一原语的另一次运用）。
--   ★★★ 四元组 {fn, sender, data, tick} 的 tick 是重入保护的关键（:1741）。
                table.insert(RPC_Queue, { fn, sender, data, tick })
            else
--★★★[第 1691-1694 行：超限时的「只告警一次」处理]
--   "-- This user is sending way too much for normal activity so take note of it."
--   ★★★ 注释措辞很有意思：「for normal activity」——
--     ★ 承认「超限不一定是攻击，可能是正常玩家操作（如超快连点）」。
--   ★★ 处理：只打印一次（RPC_Queue_Warned 守卫），然后**静默丢弃**。
--   ★★ 不踢人、不推事件 —— ★ 只是「丢弃 + 记录」。
--   ★★ 为什么超限不踢人（推理）？
--     · 正常玩家在网络抖动时也可能瞬时发多条（积压后一起到）；
--     · 踢人会误伤正常玩家；
--     · ★ 「丢弃超量」比「拒绝整个玩家」温和。
--   ⚠ 代价：攻击者可以利用这点（超量的部分被丢弃，但大部分仍被处理）。
--     真正的防护还是要靠 20 这个较小的上限。
                 -- This user is sending way too much for normal activity so take note of it.
--★★[if not RPC_Queue_Warned[sender] then —— 「只告警一次」的守卫]
--   ★★★ 与 RPC_Queue_Limiter（计数）配套的「告警去重」表。
--   ★★ 目的：防止攻击者把日志刷爆（见 :1665 的分析）。
                if not RPC_Queue_Warned[sender] then
                    RPC_Queue_Warned[sender] = true
--★ print("Rate limiting RPCs from", sender, userid, "last one being ID", tostring(code))
--   ★★ 日志含 sender、userid、code —— 便于追查是谁在被限流、发什么 RPC。
--     ★ 「last one being ID」指被丢弃的那条的 code。
                    print("Rate limiting RPCs from", sender, userid, "last one being ID", tostring(code))
                end
            end
        else
--★ else 分支：sender 是 userid 字符串但该 RPC 未标记 USERID_RPCS。
--   ★ 这是「协议不一致」的拒绝（见 :1679 的分析）——
--     攻击者不能靠发这种 RPC 触发服务端崩溃。
--   ★★ 注意这里只打印，不推事件 —— 因为这是「我方代码的协议假设被违反」，
--     模组无法处理。
            print("Invalid RPC sender: expected player, got userid")
        end
--★★[else 分支（:1700-1701）：fn 为 nil —— 无效 code]
--   print("Invalid RPC code: "..tostring(code))
--   ★★ 注意用字符串拼接而非 print 的多参数形式（与 :1694 不同风格）。
--   ★ 无效 code 说明客户端发了服务端不认识的 RPC（版本不匹配/恶意探测）。
    else
        print("Invalid RPC code: "..tostring(code))
    end
end

--★★★[HandleClientRPC —— 服务端→客户端 RPC 的入口（客户端侧）]
--   ★★★ 签名：HandleClientRPC(tick, code, data) —— ★★ **没有 sender**！
--   ★★★ 与 HandleRPC（:1675）的签名差异：
--     · HandleRPC:       (sender, tick, code, data) —— 有 sender
--     · HandleClientRPC: (tick, code, data)          —— ★ 无 sender
--   ★★ 无 sender 的原因：这是**客户端收到**的消息（来自服务端），
--     客户端不需要知道「谁发的」（服务端是自己，无 sender 概念）。
--     ★ 与 CLIENT_RPC_HANDLERS（§五）第一个参数无 player 一致。
--   ★★★ 第 1706 行：`if not ThePlayer then return end`
--     ★★ 「ThePlayer 为 nil 则所有 RPC 都无效」—— 这是 V2C 方向特有的守卫。
--     ★ 原因：客户端在「玩家尚未生成」的早期阶段会收到 V2C 消息，
--       此时 ThePlayer 不存在，执行 handler 会崩。
--     ★ → 早退（比 print + 报错更温和）。
--   ★★★ 但注意：★ HandleClientRPC **没有限流**（无 limiter）。
--     推理：服务端→客户端可信，服务端不会滥用自己的通道。
--     ★ 这与 §八 的限流只针对 C2S 方向一致。
function HandleClientRPC(tick, code, data)
--★★[if not ThePlayer then return end —— 「ThePlayer 为 nil 则所有 RPC 都无效」]
--   ★ 原注释："ThePlayer being nil means all rpc's are invalid."
--   ★★★ 推理：客户端在「选人界面」阶段（玩家实体未生成），
--     所有 CLIENT_RPC handler 都要访问 ThePlayer（§五：16 个全部如此），
--     ★ 此时访问会崩 → 所以直接 return，不处理任何 V2C。
--   ★★ 早退 vs 打印：这里不打印「无效」，因为**这是正常情况**（不是攻击/异常）。
--     ★ 对比 :1701 的 Invalid RPC code 会打印 —— 那是异常。
    if not ThePlayer then return end --ThePlayer being nil means all rpc's are invalid.
    local fn = CLIENT_RPC_HANDLERS[code]
    if fn ~= nil then
--★★[table.insert(RPC_Client_Queue, {fn, data, tick}) —— 入队（★ 三元组）]
--   ★★★ 注意是 {fn, data, tick} —— ★★ 无 sender（对比主队列的 {fn, sender, data, tick}）。
--   ★ 结构与主队列的差异见 :1669 的注记。
        table.insert(RPC_Client_Queue, { fn, data, tick })
    else
        print("Invalid RPC code: "..tostring(code))
    end
end

--★★★[HandleShardRPC —— 分片→分片 RPC 的入口]
--   ★★★ 签名：HandleShardRPC(sender, tick, code, data) —— 有 sender（同主队列）。
--   ★★ sender 是**分片 ID**（字符串），不是玩家。
--   ★★ 与 HandleRPC 的一个重要差异：
--     · HandleRPC 有 USERID_RPCS / senderistable 的类型校验（:1679）；
--     · ★ HandleShardRPC **没有**任何发送者校验 ——
--       ★ 因为分片是可信的（同为服务端进程，见 :1537 的信任声明）。
--   ★★ 且**没有限流** —— 理由同 HandleClientRPC。
--   ★★ 所以三条入队路径的校验强度递减：C2S（最强）> S2S（中，队列排空时校验）> V2C（弱）。
function HandleShardRPC(sender, tick, code, data)
    local fn = SHARD_RPC_HANDLERS[code]
    if fn ~= nil then
--★★[table.insert(RPC_Shard_Queue, {fn, sender, data, tick}) —— 分片队列入队]
--   ★ 与主队列同构（四元组，有 sender=分片id）。
        table.insert(RPC_Shard_Queue, { fn, sender, data, tick })
    else
        print("Invalid RPC code: "..tostring(code))
    end
end

--★★★★★[HandleRPCQueue —— ★★★ 每帧一次，逐帧排空三条队列]
--   ★★★ 由主循环调用（★ 参见 01-报告/05-原生C++引擎层.md:660 的 WallUpdate，
--     以及 update.lua:42 —— ★ 每帧的「实时更新」阶段）。
--   ★★★ 函数结构：三条队列各用一个独立循环排空（:1727 主、:1756 V2C、:1775 S2S）。
--   ★★★ 每个循环的模式完全相同：
--     ① 遍历队列（第 N 项）
--     ② 尝试执行（CallRPC / CallClientRPC / CallShardRPC）
--     ③ 执行成功 → 更新 Timeline（标记「本刻已处理」）；
--     ④ 「同刻已有处理」或「发送者无效」→ 处理或丢弃。
--   ★★ 关键点：★ 「执行」实际是调用 TheNet:CallRPC（:1743），
--     ★ 而 CallRPC 内部才真正执行 fn。
--     → 本函数只是「调度器」，真正的 handler 执行发生在 C++ 侧的 CallRPC 里。
function HandleRPCQueue()
--★★[local RPC_Queue_new = {} —— 「新队列」用于承接未能执行的项]
--   ★★★ 经典的「双缓冲」排空模式：
--     · 遍历**旧队列** RPC_Queue；
--     · 能执行的立即执行；
--     · ★ 不能执行的（同刻已有处理）放入 RPC_Queue_new（延到下刻）；
--     · 循环结束后 RPC_Queue = RPC_Queue_new（:1752）。
--   ★★ 为什么用「新队列」而不是原地删除？
--     遍历中修改正在遍历的表是危险操作。
--     ★ 双缓冲是最安全的做法（遍历只读旧，写新）。
--   ★★★ 这个模式在三条队列的排空中重复三次（:1725、:1754、:1773）。
    local RPC_Queue_new = {}
--★ local RPC_Queue_len = #RPC_Queue —— 记录长度（遍历时队列不再变）。
--   ★★ 注意先取长度再遍历 —— 若在遍历中往 RPC_Queue 加了新项（不该发生），
--     #RPC_Queue 会变，用固定长度保证遍历范围确定。
    local RPC_Queue_len = #RPC_Queue
--★★[for i = 1, RPC_Queue_len do —— 顺序遍历队列]
--   ★★ 顺序遍历保证了 RPC 的**执行顺序 = 入队顺序 = 到达顺序**。
--     ★ 这对「玩家连发多个操作」的正确性至关重要。
--   ★ 对比 HandleRPC 那里用的是 table.insert（追加），这里是按下标访问。
    for i = 1, RPC_Queue_len do
        local rpcdata = RPC_Queue[i]
--★ local fn, sender, data, tick = unpack(rpcdata) —— 解包四元组。
--   ★★ 解包成局部变量，后续逻辑用它们。
--   ★ 注意 unpack 在 Lua 5.1/5.2 是全局函数，5.3+ 是 table.unpack（局部）。
--     ★ 本项目是 Lua 5.1（游戏原生），unpack 是全局的。
        local fn, sender, data, tick = unpack(rpcdata)

--★★★★★[第 1731-1737 行：★★ 额度自减 + ★★ 清表（防泄漏的关键）]
--   ★★★ 三步逻辑：
--     local limit = (RPC_Queue_Limiter[sender] or 1) - 1  -- 减 1
--     if limit == 0 then
--         RPC_Queue_Limiter[sender] = nil   -- ★ 归零则清表键
--         RPC_Queue_Warned[sender] = nil     -- 告警标记也清
--     else
--         RPC_Queue_Limiter[sender] = limit  -- 未归零则保留
--     end
--   ★★★ 这与 HandleRPC 的自增（:1688）严格配对：入队+1，排空-1。
--   ★★★★ ★★ 「归零清表」是本文件防内存泄漏的核心（★ 必须照做）：
--     · 若不置 nil 而保留一个 0 值项，RPC_Queue_Limiter 会累积**每个曾发过 RPC 的发送者**的项；
--     · 攻击者可用大量伪造 sender（各种 userid）不断新增项 → 内存泄漏 → OOM；
--     · ★ 置 nil 让键彻底消失，攻击者的伪造 sender 无法积累。
--   ★★ `(RPC_Queue_Limiter[sender] or 1)` 的 or 1 兜底：
--     若该 sender 不在表里（理论上不该，但并发下可能），视为额度 1，减 1 得 0 → 置 nil。
--     ★ 这是「无论何种路径都不留残余」的最保险写法。
--   ★★ RPC_Queue_Warned 一并清：让下一次超限能重新告警一次（而非永久静默）。
--   ★ 参见 01-报告/04-联机同步-模组系统-UI.md:1545-1557（对该逻辑的分析，
--     明确指出「清表这一行是防内存泄漏的关键」）。
        local limit = (RPC_Queue_Limiter[sender] or 1) - 1
--★ if limit == 0 then —— 归零判断。
--   ★ 用 `== 0` 而非 `< 1`：因为额度不可能为负（自增自减配对）。
        if limit == 0 then
            RPC_Queue_Limiter[sender] = nil
            RPC_Queue_Warned[sender] = nil
        else
            RPC_Queue_Limiter[sender] = limit
        end

--★★★[if type(sender) == "table" and not sender:IsValid() then -- Ignore.]
--   ★★★ 「发送者实体已失效」→ 丢弃这条 RPC。
--   ★★★ 推理：玩家可能在「发 RPC → 服务器排空队列」之间死亡/断开，
--     此时 sender 实体已失效，强行执行 handler 会访问失效实体的组件 → 崩。
--     ★→ 丢弃是唯一安全选择。
--   ★★ 这是「延迟处理的必然后果」—— 入队时有效，排空时可能已失效。
--     ★ 这正是「不能立即执行」的一个附带理由（虽然不是主因）。
--   ★★ 与 S2C 方向对比（:1779）：那里判断的是「分片是否可用」，
--     而 C2V 方向判断的是「实体是否有效」—— 同一个丢弃点，两种判断。
        if type(sender) == "table" and not sender:IsValid() then
            -- Ignore.
--★★★★★[elseif RPC_Timeline[sender] == nil or RPC_Timeline[sender] == tick then]
--   ★★★ 「同刻重入保护」的核心判定（★ 与限流无关，是另一回事）：
--   ── 两种情况可执行 ──
--     · RPC_Timeline[sender] == nil  → 该 sender 本刻还没处理过任何 RPC（首次）
--     · RPC_Timeline[sender] == tick → 该 sender 本刻处理过，且这是同一条刻
--   ── 推理 ──
--     · RPC_Timeline[sender] 记录「该 sender 当前正在处理的 tick」；
--     · 如果它等于当前 tick，说明这个 sender 在本刻**已经有一条在处理**了；
--     · ★★ 严格串行：同一玩家同一刻只执行一条 RPC，其余排队到下刻。
--   ★★★★ 「同刻重入保护」的必要性（★ 重要区别于限流）：
--     ★★ 限流（:1687）是防「洪泛」（每刻最多 N 条）；
--     ★★ 重入保护（:1741）是防「同刻交错执行」（每刻只 1 条顺序执行）；
--     ★ 两者目的完全不同！限流是资源保护，重入是正确性保护。
--   ★★★ 为什么重入保护关乎正确性（推理）：
--     若玩家一连发「物品A→槽1」「物品B→槽1」等依赖顺序的 RPC，
--     若在同一刻交错执行（第一个的 handler 还没跑完，第二个就开始），
--     ★ 背包/容器这类状态机操作会基于「过时的状态」执行 → 物品错乱。
--     → 串行执行保证每个操作都基于「上一个操作的最终结果」。
--   ★★ 「nil 或 == tick」的判定保证了「每刻第一条必执行，后续排队」。
        elseif RPC_Timeline[sender] == nil or RPC_Timeline[sender] == tick then
--★ "-- Invoke." —— 可执行分支的标记注释。
            -- Invoke.
--★★★[if TheNet:CallRPC(fn, sender, data) then —— ★★ 实际执行在 C++ 侧]
--   ★★★ CallRPC 由 TheNet（C++）提供，它内部真正调用 fn(sender, data)。
--   ★★ 「执行」这个动作发生在 C++ 的 CallRPC 里，不是本文件。
--   ★★ CallRPC 返回 true/false —— ★ 这是一个「是否成功执行」的信号？
--   ★ 推理：可能是「该 RPC 是否被 C++ 接受执行」（如校验）。
--     无论如何，:1744-1745 只在成功时更新 Timeline。
--   ★★ 注意本文件**不直接调用 fn** —— 一切都通过 TheNet:CallRPC。
--     推测 CallRPC 内部会做参数打包、异常保护（try/catch）等工作。
--     ★→ 这解释了为什么 handler 里可以放心写 player.components.xxx（:61 等），
--       崩溃会被 C++ 层捕获吗？—— 不一定，但至少有一层隔离。
            if TheNet:CallRPC(fn, sender, data) then
--★★[RPC_Timeline[sender] = tick —— ★★ 执行成功后标记「本刻已处理」]
--   ★★★ 这是重入保护的状态更新：一旦某 sender 执行了一条，
--     就把它的 Timeline 标记为当前 tick ——
--     ★★ 后续同 sender 的 RPC 在本刻会被拦下（:1741），排队到下刻。
--   ★★★ 注意只在 CallRPC 返回 true 时更新（:1743 的 if 保护）。
--     ★ 若 CallRPC 失败（返回 false），不更新 → 下条仍可尝试。
                RPC_Timeline[sender] = tick
            end
--★★★[else 分支：同刻已有处理 → 放入新队列，延到下刻]
--   ★★★ 「-- Pending.」—— 排队，不是丢弃！
--     ★★ 与限流的「丢弃」（:1690 附近）不同：
--       · 超限 → **丢弃**（攻击防护，不再处理）；
--       · 同刻冲突 → **延后**（正常流程，保证顺序）。
--     ★★★ 这是两种不同的过载处理策略。
--   ★ table.insert(RPC_Queue_new, rpcdata) —— 把整条（四元组）搬进新队列。
--   ★ RPC_Timeline[sender] = 0 —— ★★ 设为 0（而非保持 tick）——
--     ★ 推测：0 是一个「标记为待处理」的特殊值；
--       下刻（tick != 0）时 `RPC_Timeline[sender] == tick` 为假，
--       ★★ 但 `RPC_Timeline[sender] == nil` 也为假（0 不是 nil）——
--       ★★★ 那这条怎么执行？—— 需要结合 TickRPCQueue（:1799 每刻清空）。
--       ★ 下刻开始时 TickRPCQueue 把 RPC_Timeline = {}（清空），
--         所以这条在下刻时 sender 的 Timeline 是 nil → 可执行。
--       ★★★ 设为 0 的作用：防止本刻内被再次误判为「可执行」。
--         （若保持 tick，同 tick 的后续项会以为「是我这条」而重复执行。）
        else
            -- Pending.
            table.insert(RPC_Queue_new, rpcdata)
--★★[RPC_Timeline[sender] = 0 —— 「本刻已处理，且已排队到下刻」的标记]
--   ★★★ 详细推理见上方 :1746 的注记。
--   ★ 关键：TickRPCQueue（:1798）每刻开头会 `RPC_Timeline = {}` 清空，
--     ★ 所以「0」的存活期只有本刻剩余时间（防本刻重复处理）。
            RPC_Timeline[sender] = 0
        end
    end
--★★[RPC_Queue = RPC_Queue_new —— 换上新队列（含未能执行的项）]
--   ★★★ 双缓冲模式的收尾：旧队列（已执行的项被丢弃，
    RPC_Queue = RPC_Queue_new

--★★[RPC_Client_Queue_new = {} —— V2C 队列的新队列（V2C 排空开始）]
--   ★★★ V2C 排空循环（:1754-1771）比 C2V 简单，因为：
--     · 无 sender（:1760 用单个 RPC_Client_Timeline 变量，不用表）；
--     · 无额度自减（不限流，:1669 注记）；
--     · 无发送者有效性检查（:1739 的 IsValid 在 V2C 不适用）。
--   ★★★ 核心仍是同刻重入保护（:1760），但只有一个全局 Timeline。
    local RPC_Client_Queue_new = {}
    local RPC_Client_Queue_len = #RPC_Client_Queue
    for i = 1, RPC_Client_Queue_len do
--★ local fn, data, tick = unpack(rpcdata) —— 解包三元组（无 sender）。
        local rpcdata = RPC_Client_Queue[i]
        local fn, data, tick = unpack(rpcdata)

--★★[if RPC_Client_Timeline == nil or RPC_Client_Timeline == tick then]
--   ★★★ 与 :1741 同构，但用**单个变量**（非表）——
--     ★ 因为 V2C 只有一个接收者（本地客户端），无需按 sender 区分。
--   ★ 排空期间 V2C 消息严格串行（同一刻只执行一条）。
        if RPC_Client_Timeline == nil or RPC_Client_Timeline == tick then
            -- Invoke.
--★ if TheNet:CallClientRPC(fn, data) then —— V2C 实际执行（C++ 侧）。
--   ★ 参数结构与 CallRPC（:1743）类似，但函数名不同（ClientRPC）。
            if TheNet:CallClientRPC(fn, data) then
                RPC_Client_Timeline = tick
            end
        else
            -- Pending.
            table.insert(RPC_Client_Queue_new, rpcdata)
            RPC_Client_Timeline = 0
        end
    end
    RPC_Client_Queue = RPC_Client_Queue_new

--★★[RPC_Shard_Queue_new = {} —— S2S 队列的新队列（分片排空开始）]
--   ★★★ S2S 排空循环（:1773-1795）的特殊性：
--     · ★ 有额外的「分片可用性」检查（:1779）；
--     · ★★ 有一个「处理中触发同帧另一个 shard RPC」的警告（:1786-1787）。
    local RPC_Shard_Queue_new = {}
    local RPC_Shard_Queue_len = #RPC_Shard_Queue
    for i = 1, RPC_Shard_Queue_len do
        local rpcdata = RPC_Shard_Queue[i]
--★ local fn, sender, data, tick = unpack(rpcdata) —— 解包四元组（有 sender=分片）。
        local fn, sender, data, tick = unpack(rpcdata)

--★★★[if not Shard_IsWorldAvailable(tostring(sender)) and tostring(sender) ~= TheShard:GetShardId() then]
--   ★★★ 「分片不可用」的丢弃条件（比 C2V 的 IsValid 更语义化）：
--   ── 两个条件（and 连接）都成立才丢弃 ──
--     · Shard_IsWorldAvailable(sender) 为假 → 该分片未连接
--     · sender ≠ 本分片 ID → 不是自己
--   ★★ 推理：若一个 RPC 来自「已断开的分片」且不是自己，丢弃。
--     ★ 「已断开」意味着它的网络状态异常，消息不可信/无意义。
--   ★★ Shard_IsWorldAvailable（shardnetworking.lua:16）——
--     判断某分片是否在 ShardConnected 表里（连接状态）。
--   ★★★ 为什么 S2S 要检查而 C2V 只检查 IsValid？
--     · C2V: 检查「玩家实体是否还活着」；
--     · S2S: 检查「分片连接是否还在」—— 不同的失效维度。
--   ★★ tostring(sender) 的两次调用 —— 转字符串以匹配 shard id 格式。
        if not Shard_IsWorldAvailable(tostring(sender)) and tostring(sender) ~= TheShard:GetShardId() then
            -- Ignore.
--★★[elseif RPC_Shard_Timeline[sender] == nil or RPC_Shard_Timeline[sender] == tick then]
--   ★ 与 :1741 逐字同构的分片版重入保护。
        elseif RPC_Shard_Timeline[sender] == nil or RPC_Shard_Timeline[sender] == tick then
            -- Invoke.
--★ if TheNet:CallShardRPC(fn, sender, data) then —— S2S 实际执行。
--   ★ 第三个函数名（CallShardRPC）。
            if TheNet:CallShardRPC(fn, sender, data) then
                RPC_Shard_Timeline[sender] = tick
            end
--★★★[第 1786-1787 行：★★ 「处理中触发同帧 shard RPC」的警告]
--   if RPC_Shard_Queue[RPC_Shard_Queue_len + 1] then
--       print("Shard RPC invoked another RPC in the same frame and will be dropped!
--             "Delay shard RPCs sending more shard RPCs to itself by a frame minimally
--             or try handling RPCs in a different way.")
--   ★★★ 检测方式：★ 检查固定长度之后是否有多出的项（RPC_Shard_Queue_len + 1）。
--     ★ 若 handler 执行过程中往队列追加了新项（RPC_Shard_Queue_len + 1 位置有值），
--       说明「handler 内部又发了一个 shard RPC」——
--       ★★ 而这个新项本刻不会被处理（因为遍历范围固定为 len），且下一刻
--       会因为「重入保护」被延后 —— 实际就是「被丢弃」。
--   ★★★ 这是一个**自我诊断的警告**，揭示了一个已知的架构约束：
--     ★★ 「handler 执行期间不要同步发 shard RPC 给自己的分片」。
--     · 为什么会自己发给自己？如 shardnetworking.lua:240 的 DoTaskInTime(0, ...)
--       延迟一帧发 shard RPC（避免同帧问题）；
--     · 但若某个 handler 忘记延迟，就会触发这个警告。
--   ★★★ 这是一条「给开发者的架构约束提醒」——
--     说明 S2S 方向确实存在「重入」隐患，作者用警告来提示。
--   ★ 移植时务必理解这条约束，否则会遇到「shard RPC 莫名丢失」。
            if RPC_Shard_Queue[RPC_Shard_Queue_len + 1] then
                print("Shard RPC invoked another RPC in the same frame and will be dropped! Delay shard RPCs sending more shard RPCs to itself by a frame minimally or try handling RPCs in a different way.")
            end
        else
            -- Pending.
            table.insert(RPC_Shard_Queue_new, rpcdata)
            RPC_Shard_Timeline[sender] = 0
        end
    end
--★★[RPC_Shard_Queue = RPC_Shard_Queue_new —— 换上新分片队列]
--   ★ 三条队列的排空至此全部完成。
    RPC_Shard_Queue = RPC_Shard_Queue_new
end

--★★★[TickRPCQueue —— ★ 每刻开头重置重入保护状态]
--   RPC_Timeline = {}
--   RPC_Client_Timeline = nil
--   RPC_Shard_Timeline = {}
--   ★★★ 三行分别重置三条方向的重入保护状态表。
--   ★★★ 关键理解：★ 这些状态是「每刻」有效的（不是每帧）：
--     · 每刻（tick）开始时清空；
--     · 本刻内每个 sender 只执行一条 RPC；
--     · 下刻清空后可以再执行。
--   ★★★ 「每刻」而非「每帧」的原因（★ 性能权衡）：
--     · 逻辑刻远慢于帧（1/30s vs 60fps → 约 2 帧/刻）；
--     · ★ 若每帧清空，玩家一帧内可能被执行两条交错 RPC → 破坏串行；
--     · ★★ 所以用逻辑刻做「串行窗口」，既保证顺序，又不过度限制。
--   ★★ 谁调用 TickRPCQueue？推测在主循环的刻开始处（早于 HandleRPCQueue）。
--     ★ 参见 01-报告/05-原生C++引擎层.md:660（WallUpdate 是每帧，而逻辑刻是 Update）。
--   ★★★ 这是「重入保护的清空」—— 与 RPC_Queue_Limiter 的「归零清表」（:1733）不同：
--     · RPC_Queue_Limiter：按 sender 归零时清（防泄漏）
--     · RPC_Timeline：每刻无条件整体清（重置串行窗口）
function TickRPCQueue()
    RPC_Timeline = {}
    RPC_Client_Timeline = nil
    RPC_Shard_Timeline = {}
--★★★ TickRPCQueue 结束。★★★ 至此「RPC 的完整生命周期」闭合：
--   ① 编号分配（加载期，:1391-1634）—— 名字↔数字终身绑定
--   ② 发送（:1636-1660）—— 三个方向各一个函数
--   ③ 接收入队（:1675-1722）—— 查表 + 校验 + 限流 + 入队（不执行）
--   ④ 排空执行（:1724-1796）—— 每帧一次，CallRPC 实际执行
--   ⑤ 重置（:1798-1802）—— 每刻清空重入保护状态
--   ★★ 这五步构成了完整的 RPC 管线。§十一 起是模组 RPC 的扩展机制。
end

--★★★[__index_lower —— ★★ 「大小写不敏感」的元表钩子]
--   local function __index_lower(t, k)
--       return rawget(t, string.lower(k))
--   end
--   ★★★ 目的：让表访问**忽略大小写**。
--     t.FooBar → 实际查 t["foobar"]
--   ★★★ 为什么需要？（推理，模组场景）：
--     · 模组开发者写 RPC 名时可能用各种大小写（MyFunc / myfunc / MYFUNC）；
--     · 若区分大小写，同一个模组在不同地方写法不同就会注册出多个 handler；
--     · ★ 大小写不敏感消除了这类「拼写不一致」的困扰。
--   ★★★ 用 rawget（而非直接 t[k]）的原因：
--     ★ 若用 t[k]，且 t 自己有 __index 元表 → 无限递归风险；
--     ★ rawget 绕过元表，直接读原始键 —— 防止递归。
--     ★ 这是「元表实现里必须用 rawget/rawset」的经典理由。
local function __index_lower(t, k)
    return rawget(t, string.lower(k))
end

--★★★[__newindex_lower —— 写入时同样转小写]
--   local function __newindex_lower(t, k, v)
--       rawset(t, string.lower(k), v)
--   end
--   ★★★ 关键机制：★ __newindex 只在「**键不存在**」时被触发！
--     · 若 t 已经有一个 key（非 nil），赋值不会走 __newindex；
--     · 所以「首次写入」时才转小写。
--     · ★ 这意味着：一旦写入后，后续访问都通过 __index_lower 转小写查找，
--       而实际存的键已经是小写 —— 匹配。
--   ★★ 但有个边界情况：
--     若某处用 t.Foo = x 而 t 里已有 "Foo" 键（大写，未转小写），
--     __newindex 不会触发（键存在），导致大小写不一致。
--     ★ 本文件靠「所有键都经由元表首次写入」来保证一致性。
--   ★★★ ★ 与 __index_lower 配对：「读和写都转小写」→ 访问不敏感。
local function __newindex_lower(t, k, v)
    rawset(t, string.lower(k), v)
end

--★★[setmetadata —— 「给表装上大小写不敏感元表」的小工具]
--   setmetatable(tab, { __index = __index_lower, __newindex = __newindex_lower })
--   ★★★ 两个钩子都装：读 + 写都转小写。
--   ★★★ 「元表的元表」现象：
--     · 这个 setmetatable 的返回值是一个**新表**（{__index=..., __newindex=...}），
--       它本身没有元表。
--     · 而被 setmetatable 的目标 tab 现在有了元表 → 它的访问会触发钩子。
--   ★★ 简单封装：避免每次都写完整的 setmetatable 调用。
--   ★ 本文件在 6 个表上调用它（:1825-1832，六个成对出现）。
local function setmetadata( tab )
    setmetatable(tab, { __index = __index_lower, __newindex = __newindex_lower })
end

--★★★[模组 RPC 的六张表：★★ 三对（注册表 + 处理表）]
--   MOD_RPC = {}                    -- 模组→服务器：名字→{namespace, id}
--   MOD_RPC_HANDLERS = {}           -- 模组→服务器：id→函数
--   CLIENT_MOD_RPC = {}             -- 服务器→客户端：名字→{namespace, id}
--   CLIENT_MOD_RPC_HANDLERS = {}    -- 服务器→客户端：id→函数
--   SHARD_MOD_RPC = {}              -- 分片→分片：名字→{namespace, id}
--   SHARD_MOD_RPC_HANDLERS = {}     -- 分片→分片：id→函数
--   ★★★ 关键观察：
--     · ★ 三对结构完全平行（C2V / V2C / S2S 各一对）；
--     · ★★ 与内置 RPC 的根本区别：
--         内置（§四）：单层「名字↔数字」，编号 1-127 有全局上限（:1385）；
--         ★ 模组（本节）：★★ 两级「namespace + id」，每个 namespace 独立编号
--           （:1844 `id = #MOD_RPC_HANDLERS[namespace]`），★★ 无全局上限。
--     · ★★ 这就是模组 RPC 必须走独立通道的根本原因（见 :1844 注记）。
--   ★ 六张表在 :1825-1832 全部装上大小写不敏感元表。
MOD_RPC = {}
MOD_RPC_HANDLERS = {}

CLIENT_MOD_RPC = {}
CLIENT_MOD_RPC_HANDLERS = {}

SHARD_MOD_RPC = {}
SHARD_MOD_RPC_HANDLERS = {}

--★★[六行 setmetadata —— 给六张表及其 namespace 子表都装元表]
--   ★★★ 注意是**成对**调用：外层表（MOD_RPC 等）+ 之后新增的 namespace 子表
--     （:1839/:1840 在 AddModRPCHandler 里也调用 setmetadata）。
--   ★★ 为什么要给「namespace 子表」也装？
--     因为 MOD_RPC[namespace] 是「名字→id 表」，按名字查 handler 时
setmetadata(MOD_RPC)
setmetadata(MOD_RPC_HANDLERS)

setmetadata(CLIENT_MOD_RPC)
setmetadata(CLIENT_MOD_RPC_HANDLERS)

setmetadata(SHARD_MOD_RPC)
setmetadata(SHARD_MOD_RPC_HANDLERS)
--★★ 模组 RPC 六张表的元表装配结束。接下来是三个 Add*ModRPCHandler（:1834-1879）。
--   ★ ★★★ 回看本节的整体设计意图（§十一 + §十二）：
--     · 内置 RPC：单层名字↔数字，编号 1-127 有上限（:1385），只能加载期分配；
--     · 模组 RPC：★ 两级 namespace+id，每 namespace 独立编号，无全局上限；
--       可运行时动态注册。
--     · ★★ 后者是对前者的必要补充：模组不能重排内置表（会改编号），
--       也不能无限新增（127 不够），所以必须走独立通道。

--★★★★★[AddModRPCHandler —— ★★ 模组 RPC 的注册入口，也是缺陷 B 的执行点]
--   ★★★ 签名：AddModRPCHandler(namespace, name, fn)
--     · namespace = ★ 模组名（用于隔离，同模组的 handler 归一组）
--     · name      = RPC 的名字（供 SendModRPCToServer 用）
--     · fn        = 处理函数
--   ★★★ 三步注册（:1835-1848）：
--     ① 若该 namespace 首次出现，创建它的子表 + 装元表（:1835-1841）
--     ② 把 fn 追加到处理表，id = 表长度（:1843-1844）
--     ③ ★★ 把该 id 记录到「名字→id」表（:1844）
--     ④ ★★★ 全局限流 +5（:1848）—— ★★ 缺陷 B！
--   ★★★★ ★★★ 模组 RPC 的 id 分配机制（★ 与内置完全不同）：
--     · 第 1843 行 `table.insert(MOD_RPC_HANDLERS[namespace], fn)` 追加
--     · 第 1844 行 `MOD_RPC[namespace][name] = { namespace = namespace, id = #MOD_RPC_HANDLERS[namespace] }`
--   ★★★ id 是「数组下标」—— 每个 namespace 从 1 开始，独立计数。
--     ★★ 这是「两级索引」：namespace（第一级）+ id（第二级）。
--     ★★ 好处：★ 不占内置的 1-127 编号空间（:1385），各模组互不干扰。
--   ★★ 发送时传（namespace, id）两个参数，接收时也用两者查（:1897-1898）。
function AddModRPCHandler(namespace, name, fn)
--★★[if MOD_RPC[namespace] == nil then —— 「首次见到这个 namespace」的守卫]
--   ★★★ 惰性初始化：第一次注册某 namespace 时才创建它的两张子表。
--   ★★ 为什么用 nil 判断而不是 table 里查？
--     因为 MOD_RPC_HANDLERS[namespace] 是数组，第 0 项 nil。
--   ★★ 若不用守卫，每次注册都重建表会丢失已有 handler。
    if MOD_RPC[namespace] == nil then
        MOD_RPC[namespace] = {}
        MOD_RPC_HANDLERS[namespace] = {}

--★★[setmetadata(MOD_RPC[namespace]) + setmetadata(MOD_RPC_HANDLERS[namespace])]
--   ★★★ 给新建的 namespace 子表也装大小写不敏感元表。
--   ★★ 这样「模组写 name 时用任何大小写，发送时都能匹配」。
--   ★ ★ 注意：处理表 MOD_RPC_HANDLERS[namespace] 是**数组**（按 id 索引），
--     给数组装元表是为了 id 转换时也大小写不敏感（虽然 id 是数字，
        setmetadata(MOD_RPC[namespace])
        setmetadata(MOD_RPC_HANDLERS[namespace])
    end

--★★[table.insert(MOD_RPC_HANDLERS[namespace], fn) —— 处理函数按序追加]
--   ★★★ id 由数组长度隐式决定（下一个空位）。
--   ★★ 注意：这个追加是**运行时动态**的（不像内置 RPC 是加载期一次分配）。
--     ★★ 这正是模组 RPC 的灵活性来源：
--       · 可以在任何时候注册新的 handler（启动时、游戏中）；
--       · id 是「注册顺序」，服务端/客户端都按相同顺序注册。
--     ★★ ⚠ 隐含要求：★ 服务端与客户端的**注册顺序必须完全一致**
--       （否则 id 对不上，调用错 handler）。
--       ★ 这是模组 RPC 的隐式契约：加载顺序敏感。
    table.insert(MOD_RPC_HANDLERS[namespace], fn)
--★★★[MOD_RPC[namespace][name] = { namespace = namespace, id = #... }]
--   ★★★ 「名字→id 记录」的建立。返回的是一个「元数据对象」：
--     { namespace = "MyMod", id = 3 }
--   ★★★ 这个对象就是 SendModRPCToServer 的第一个参数（:1881 id_table）：
--     SendModRPCToServer(MOD_RPC.MyMod.MyFunc, arg1, arg2)
--   ★★ 发送时：先由名字拿到这个元数据，再取 .namespace 和 .id 发给 C++。
--     ★ 这就是「两级索引」在发送侧的体现。
--   ★★★ 设计价值：★ 发送侧只需「名字」，内部自动转成 (namespace, id)，
--     ★ 模组代码完全不用关心 id 的数值。
--     ★★ 但它也暴露了「id 是运行时分配的」这一事实（:1843）。
    MOD_RPC[namespace][name] = { namespace = namespace, id = #MOD_RPC_HANDLERS[namespace] }

--★★[setmetadata(MOD_RPC[namespace][name]) —— 给「名字项」也装元表]
--   ★★ 这一处元表装在「{namespace, id} 这个元数据表」上。
--   ★★ 意义：让模组可以用任意大小写访问 .namespace / .id 字段。
--     ★ 这是「大小写不敏感」贯彻到每一层的体现。
--   ★★★ ⚠ 副作用：MOD_RPC[namespace][name] 现在也被当作「不区分大小写的表」
--     → 若误访问不存在的字段，会返回 nil（与普通表一样），无实质区别。
    setmetadata(MOD_RPC[namespace][name])

--★★★★⚠[第 1848 行：★★ 缺陷 B 的执行点 —— 全局限流无上限抬高]
--   RPC_QUEUE_RATE_LIMIT = RPC_QUEUE_RATE_LIMIT + RPC_QUEUE_RATE_LIMIT_PER_MOD
--   ★★★★ 这行代码是「模组可无限抬高全局限流」的执行处。
--   ── 完整推理链 ──
--   1) RPC_QUEUE_RATE_LIMIT 是文件级局部变量（:1662），初始 20；
--   2) 本行每次执行都把它 +RPC_QUEUE_RATE_LIMIT_PER_MOD（=5，:1663）；
--   3) ★★ 没有任何上限检查（没有 min、没有 clamp）；
--   4) ★★ 而 AddModRPCHandler 可被任意模组反复调用（注册 N 个 handler 就 +N*5）；
--   ── 攻击路径（推理）──
--     · 恶意模组在自己的初始化里循环调用 AddModRPCHandler 数千次；
--       → 限流被抬到几万；
--     · 该模组（或它协同的攻击客户端）发海量 RPC；
--       → 限流形同虚设，服务端单刻要处理海量 RPC → CPU 打满 → 拒绝服务；
--     · ★★ 且限流是**全局**的，所有正常玩家（包括不用该模组的）
--       都受影响（更糟：无法通过「不用这个模组」来规避）。
--   ── 为什么这是真实缺口（而非误报）──
--     · 本文件确实没有 per-namespace 配额机制；
--     · 确实没有全局硬上限；
--     · ★ 详见 :1663 的常量注记与 01-报告/04-联机同步-模组系统-UI.md:1559-1565，
--       以及 :2381（修复清单）、:2926（陷阱 3）。
--   ── 修复方向（仅记录，不改码）──
--     ① 「每模组独立配额」：把 limiter 从「按 sender」改成「按 sender+namespace」；
--     ② 「全局硬上限」：RPC_QUEUE_RATE_LIMIT = min(总量, HARD_CAP)；
--     ③ 或直接去掉本行（模组玩家的 20 条/刻通常够用）。
--   ★ 按本文件约定（只注释不改码），此处标注不修改。
    RPC_QUEUE_RATE_LIMIT = RPC_QUEUE_RATE_LIMIT + RPC_QUEUE_RATE_LIMIT_PER_MOD
end

--★★[AddClientModRPCHandler —— 服务器→客户端版，与 C2V 版结构相同]
--   ★★★ 唯一差异：★ 第 1864 行之后**没有** `RPC_QUEUE_RATE_LIMIT = ... +5`。
--   ★★★ 为什么不需要？（推理）：
--     · 限流是针对「客户端→服务端」的（不可信方向，:1687）；
--     · V2C（服务器→客户端）**不限流**（服务端可信，见 :1537/:1669）；
--     · ★✓ 所以 V2C 模组 RPC 不需要也不应该抬高限流。
--   ★★ 这个差异恰好证明「限流专为不可信方向设计」这个原则的一致执行。
--   ★★ 但也暴露一个**潜在的遗漏风险**：
--     若将来给 S2S 方向也加上全局 limiter，
--     ★ 这个函数也需要相应修改（加配额）。
--     → 移植时应把「哪些方向需要限流」显式化，而非依赖「刚好只有 C2V 加了」。
function AddClientModRPCHandler(namespace, name, fn)
    if CLIENT_MOD_RPC[namespace] == nil then
        CLIENT_MOD_RPC[namespace] = {}
        CLIENT_MOD_RPC_HANDLERS[namespace] = {}

        setmetadata(CLIENT_MOD_RPC[namespace])
        setmetadata(CLIENT_MOD_RPC_HANDLERS[namespace])
    end

    table.insert(CLIENT_MOD_RPC_HANDLERS[namespace], fn)
    CLIENT_MOD_RPC[namespace][name] = { namespace = namespace, id = #CLIENT_MOD_RPC_HANDLERS[namespace] }

    setmetadata(CLIENT_MOD_RPC[namespace][name])
end

--★★[AddShardModRPCHandler —— 分片→分片版，同样不加限流]
--   ★ 与 :1851 同理：S2S 方向不经 limiter（:1715 无 limiter）。
--   ★★★ 三个 Add*ModRPCHandler 函数结构几乎完全相同，
--     ★ 唯一实质差异就是「C2V 版有那行缺陷 B」。
--     ★★ 这又是一次「平行实现」（本文件 §十 提到的模式）。
function AddShardModRPCHandler(namespace, name, fn)
    if SHARD_MOD_RPC[namespace] == nil then
        SHARD_MOD_RPC[namespace] = {}
        SHARD_MOD_RPC_HANDLERS[namespace] = {}

        setmetadata(SHARD_MOD_RPC[namespace])
        setmetadata(SHARD_MOD_RPC_HANDLERS[namespace])
    end

    table.insert(SHARD_MOD_RPC_HANDLERS[namespace], fn)
    SHARD_MOD_RPC[namespace][name] = { namespace = namespace, id = #SHARD_MOD_RPC_HANDLERS[namespace] }

    setmetadata(SHARD_MOD_RPC[namespace][name])
end
--★★ 三个 Add*ModRPCHandler 结束。★★★ ★★ 缺陷 B 就在这里（:1848）。
--   三个函数的唯一实质差异：C2V 版有那行 +5（:1848），另两个没有。
--   ★★ 这是「限流专为不可信方向设计」原则的体现，

--★★★[SendModRPCToServer —— 模组版的发送函数（客户端→服务端）]
--   ★★★ 签名：SendModRPCToServer(id_table, ...) —— ★ id_table 是「名字元数据」。
--   ★★★ 第 1882 行的断言比内置版（:1637）严格得多：
--     assert(id_table.namespace ~= nil and MOD_RPC_HANDLERS[id_table.namespace] ~= nil
--            and MOD_RPC_HANDLERS[id_table.namespace][id_table.id] ~= nil)
--   ★★★ 三重校验：
--     ① id_table.namespace 存在（是不是合法的注册元数据）
--     ② 该 namespace 的处理表已注册
--     ③ 该 id 在处理表里有对应 handler
--   ★★ 对比内置 SendRPCToServer（:1637）只有一层 `RPC_HANDLERS[code] ~= nil`。
--     ★ 为什么模组版更严？
--     · 模组 RPC 是两级索引（namespace + id），校验天然需要多层；
--     · ★ 且防止「模组代码 bug（用了未注册的 id）」导致运行时错误。
--   ★★★ 接收侧（:1897-1898）用同样的两级查找。
--   ★ TheNet:SendModRPCToServer(namespace, id, ...) —— C++ 侧发送。
function SendModRPCToServer(id_table, ...)
    assert(id_table.namespace ~= nil and MOD_RPC_HANDLERS[id_table.namespace] ~= nil and MOD_RPC_HANDLERS[id_table.namespace][id_table.id] ~= nil)
    TheNet:SendModRPCToServer(id_table.namespace, id_table.id, ...)
end

--★ SendModRPCToClient —— 服务器→客户端版模组 RPC 发送。
--   ★ 三重校验同构（对应 CLIENT_MOD_RPC_HANDLERS）。
function SendModRPCToClient(id_table, ...)
    assert(id_table.namespace ~= nil and CLIENT_MOD_RPC_HANDLERS[id_table.namespace] ~= nil and CLIENT_MOD_RPC_HANDLERS[id_table.namespace][id_table.id] ~= nil)
    TheNet:SendModRPCToClient(id_table.namespace, id_table.id, ...)
end

--★ SendModRPCToShard —— 分片→分片版模组 RPC 发送。
--   ★ 三重校验同构（对应 SHARD_MOD_RPC_HANDLERS）。
function SendModRPCToShard(id_table, ...)
    assert(id_table.namespace ~= nil and SHARD_MOD_RPC_HANDLERS[id_table.namespace] ~= nil and SHARD_MOD_RPC_HANDLERS[id_table.namespace][id_table.id] ~= nil)
    TheNet:SendModRPCToShard(id_table.namespace, id_table.id, ...)
end

--★★★★[HandleModRPC —— ★★ 模组 RPC 的客户端→服务端接收（服务端侧）]
--   ★★★ 签名：HandleModRPC(sender, tick, namespace, code, data)
--     ★★ 比内置 HandleRPC（:1675）多一个 **namespace** 参数！
--     ★ 这就是「两级索引」的接收侧：先按 namespace 找处理表，再按 code 找函数。
--   ★★★ 整体结构与 HandleRPC（:1675）高度对应：
--     ┌──────────────────────────────────────────────────────┐
--     │ 步骤          │ HandleRPC(:1675) │ HandleModRPC(:1896) │
--     ├──────────────────────────────────────────────────────┤
--     │ 有效性        │ RPC_HANDLERS[code]│ MOD_RPC_HANDLERS[ns]│
--     │ 发送者类型校验 │ ★ 有(:1679)      │ ★ 有(:1901)        │
--     │ USERID_RPC    │ ★ 支持          │ ★ 支持(:1904)      │
--     │ 限流          │ ★ 有(:1687)      │ ★ 有(:1909)        │
--     │ 入队          │ ★ 同队列        │ ★ 同队列(:1911)    │
--     │ 告警去重      │ ★ 有            │ ★ 有(:1914)        │
--     └──────────────────────────────────────────────────────┘
--   ★★★ 关键：**模组 RPC 与内置 RPC 共用同一条队列和同一套限流**。
--     ★ 这正是缺陷 B 危害的根源：
--       模组 handler 走的限流计数器 RPC_Queue_Limiter 就是内置那个，
--       ★ 所以抬高全局限额会同时放宽内置 RPC 的流量控制。
function HandleModRPC(sender, tick, namespace, code, data)
--★ if MOD_RPC_HANDLERS[namespace] ~= nil then —— ★ 第一级查找：namespace]
--   ★★ 两级查找的第一步：确认这个模组注册过 handler。
--     ★ 若没注册（namespace 不存在），后续 else 分支打印「无效 namespace」。
--   ★★★ 这是模组 RPC 与内置 RPC 的一个关键差异：
--     · 内置（:1676）只有一级查找（code → 函数）；
--     · ★ 模组（本行）两级（namespace → 表，code → 函数）。
--     · 原因：见 :1844（两级索引设计）。
    if MOD_RPC_HANDLERS[namespace] ~= nil then
--★ local fn = MOD_RPC_HANDLERS[namespace][code] —— 第二级查找：code→函数]
--   ★★ 与内置的 `RPC_HANDLERS[code]` 相比多了一层 namespace。
--   ★ code 来自 C++ 层（由发送方传的 id，:1883）。
        local fn = MOD_RPC_HANDLERS[namespace][code]
        if fn ~= nil then
--★★[senderistable —— 与内置 HandleRPC（:1678）同构]
--   ★★★ 模组 RPC 复用了完全相同的发送者类型判定与 USERID_RPC 机制。
--   ★★ 这说明模组 RPC 被当作「一等公民」对待（与内置同等校验）。
--     ★ 参见 §九 的详细分析。
            local senderistable = type(sender) == "table"
            if USERID_RPCS[fn] or senderistable then
                local userid = senderistable and sender.userid or nil

                if USERID_RPCS[fn] then
                    sender = userid or sender
                end

                local limit = RPC_Queue_Limiter[sender] or 0
--★★★[if limit < RPC_QUEUE_RATE_LIMIT then —— ★★ 模组 RPC 用同一个 limiter]
--   ★★★ 这是缺陷 B 的**危害确认点**：
--     · 模组 RPC 的限流检查用的是**同一个 RPC_Queue_Limiter**（:1908/:1910）；
--     · ★★★ 而 AddModRPCHandler（:1848）把这个全局限额抬高了；
--     · ★★ 所以：**模组抬高限额 → 真正攻击流量（无论来自内置还是模组 RPC）
--       都能畅通**。这正是报告 04:1559-1565 分析的「全局抬高」危害。
--   ★★ 推理：这个设计本身是「善意」的（想给模组用户更多余量），
--     但因为 limiter 是全局共享的，变成了「一个模组的配额，全服受益/受害」。
--   ── 正确的设计（对照建议）──
--     应该维护 per-(sender, namespace) 的独立计数器，
--     ★ 让模组 A 的宽松配额只作用于模组 A 的 RPC，不影响内置 RPC 和其他模组。
                if limit < RPC_QUEUE_RATE_LIMIT then
                    RPC_Queue_Limiter[sender] = limit + 1
--★ table.insert(RPC_Queue, {fn, sender, data, tick}) —— ★ 与内置共用队列]
--   ★★★★ 关键：★ 模组 RPC 与内置 RPC 入**同一条队列** RPC_Queue。
--   ★★★ 后果（缺陷 B 的具体危害）：
--     · 一个玩家发送「100 个模组 A 的 RPC + 5000 个内置 RPC」，
--       它们**共用**同一个额度计数器；
--     · ★ 若模组 A 把限额抬到 5020，则这个玩家的 5100 个 RPC 全部通过；
--     · ★★★ 而如果 limiter 是 per-namespace 的，只有那 100 个模组 RPC
--       会因「模组 A 有配额」而放宽，5000 个内置 RPC 仍受 20 的原始限额约束。
--   ★★ 这就是「全局抬高」比「独立配额」危险的精确原因。
                    table.insert(RPC_Queue, { fn, sender, data, tick })
                else
                     -- This user is sending way too much for normal activity so take note of it.
                    if not RPC_Queue_Warned[sender] then
                        RPC_Queue_Warned[sender] = true
--★ print("Rate limiting RPCs from [MOD]", sender, userid, ...) —— 模组版告警日志]
--   ★★ 与内置版（:1694）的区别：多了 [MOD] 标记与 namespace 信息，
--     ★ 便于区分「是模组 RPC 被限流」。
                        print("Rate limiting RPCs from [MOD]", sender, userid, "last one being ID", tostring(code), "of namespace", tostring(namespace))
                    end
                end
            else
                print("Invalid RPC sender: expected player, got userid")
            end
        else
            print("Invalid RPC code: ", namespace, code)
        end
    else
        print("Invalid RPC namespace: ", namespace, code)
    end
end

--★★★[HandleClientModRPC —— 服务器→客户端的模组 RPC 接收]
--   ★★★ 签名：HandleClientModRPC(tick, namespace, code, data) —— ★ 无 sender。
--     ★ 与内置 HandleClientRPC（:1705）一致（V2C 无 sender）。
--   ★★★ 结构：两级查找 + 入 V2C 队列。
--   ★★ 注意：★ 同样没有 ThePlayer 为 nil 的检查？
--     对比内置 HandleClientRPC（:1706）有 `if not ThePlayer then return end`。
--     ★⚠ 模组版**没有**这个检查。
--     ★★★ 推理影响：若在 ThePlayer 为 nil 时收到模组 V2C，
function HandleClientModRPC(tick, namespace, code, data)
    if CLIENT_MOD_RPC_HANDLERS[namespace] ~= nil then
        local fn = CLIENT_MOD_RPC_HANDLERS[namespace][code]
        if fn ~= nil then
--★ table.insert(RPC_Client_Queue, {fn, data, tick}) —— ★★ 与内置共用 V2C 队列]
--   ★★ 模组 RPC 与内置 RPC 在**三个方向**都共用队列。
--     ★ 这是缺陷 B 在 S2S/V2C 方向的对应（虽然那两方向不限流，危害较小）。
            table.insert(RPC_Client_Queue, { fn, data, tick })
        else
            print("Invalid RPC code: ", namespace, code)
        end
    else
        print("Invalid RPC namespace: ", namespace, code)
    end
end

--★★★[HandleShardModRPC —— 分片→分片的模组 RPC 接收]
--   ★★★ 签名：HandleShardModRPC(sender, tick, namespace, code, data) —— 有 sender。
--   ★★★ 结构：两级查找 + 入 S2S 队列。
--   ★★ 与内置 HandleShardRPC（:1715）同构（同样无发送者校验、无限流）。
function HandleShardModRPC(sender, tick, namespace, code, data)
    if SHARD_MOD_RPC_HANDLERS[namespace] ~= nil then
        local fn = SHARD_MOD_RPC_HANDLERS[namespace][code]
        if fn ~= nil then
--★ table.insert(RPC_Shard_Queue, {fn, sender, data, tick}) —— 与内置共用 S2C 队列]
            table.insert(RPC_Shard_Queue, { fn, sender, data, tick })
        else
            print("Invalid RPC code: ", namespace, code)
        end
    else
        print("Invalid RPC namespace: ", namespace, code)
    end
end
--★★★ 六个 Handle*ModRPC 结束。★★★ 模组 RPC 的收发至此完整：
--   注册（Add*ModRPCHandler）→ 发送（Send*ModRPC*）→ 接收入队（Handle*ModRPC）
--   ★★ 三对收发函数与内置的六个 Handle*/Send* 严格对应。
--   ★★ 但 ★ 模组 RPC 与内置 RPC 共用三条队列和同一个 limiter ——
--     ★★ 这是缺陷 B（:1848 抬高全局限流）能产生全局危害的结构性原因。

--★★[GetModRPCHandler —— 「名字→handler 函数」的反查]
--   ★★★ MOD_RPC_HANDLERS[namespace][MOD_RPC[namespace][name].id]
--   ★★★ 两级下钻：先用 name 拿 id，再用 id 拿函数。
--   ★★ 这是 MarkUserIDRPC（:1988）内部用的工具。
--   ★★★ ⚠ 隐患：若 name 未注册，MOD_RPC[namespace][name] 为 nil，
--     → .id 访问 nil 会崩溃（attempt to index a nil value）。
--     ★ 即：★ GetModRPCHandler 对「未注册的 name」不安全（无判空）。
--     → 移植时应加判空，或在文档中声明「只对已注册的 name 调用」。
--   ★★ 这三个 Get*ModRPCHandler 函数是「public API」，
--     模组可能直接调用它们 → 这个隐患对模组也可见。
function GetModRPCHandler(namespace, name)
    return MOD_RPC_HANDLERS[namespace][MOD_RPC[namespace][name].id]
end

function GetClientModRPCHandler(namespace, name)
    return CLIENT_MOD_RPC_HANDLERS[namespace][CLIENT_MOD_RPC[namespace][name].id]
end

function GetShardModRPCHandler(namespace, name)
    return SHARD_MOD_RPC_HANDLERS[namespace][SHARD_MOD_RPC[namespace][name].id]
end
--★★ 三对 Get*ModRPC* 查询函数结束。★ 它们是给模组用的「反射式 API」：
--   GetModRPCHandler (:1956) —— 名字→handler 函数
--   GetModRPC        (:1968) —— 名字→id 元数据
--   （以及对应的 Client/Shard 版本）
--   ★★ 存在意义：让模组能在运行时查询「某个 RPC 是否注册了、它的 handler 是谁」，
--     便于动态组合/包装。
--   ★ ⚠ GetModRPCHandler 对未注册的名字会崩溃（见 :1956 注记）——
--     而 GetModRPC 是安全的（返回 nil）。这是两者唯一的健壮性差异。

--★ GetModRPC —— 只拿「名字→id 元数据」，不拿 handler 函数。
--   ★★★ MOD_RPC[namespace][name] —— 一级下钻（返回 {namespace, id}）。
--   ★ ★ 比 GetModRPCHandler 安全：只查一层，返回 nil 时不崩溃。
--   ★ ★ 用途：模组在发包前确认「这个名字注册过」再取 id。
function GetModRPC(namespace, name)
    return MOD_RPC[namespace][name]
end

function GetClientModRPC(namespace, name)
    return CLIENT_MOD_RPC[namespace][name]
end

function GetShardModRPC(namespace, name)
    return SHARD_MOD_RPC[namespace][name]
end

--★★★★★[MarkUserIDRPC —— ★★ 「标记该 RPC 以 userid 为第一参数」的注册入口]
--   ★★★ 签名：MarkUserIDRPC(namespace, name) 或 MarkUserIDRPC(name) —— ★ 双签名！
--   ★★★ 第 1981-1984 行的参数归一化：
--     if not name then            -- 只传了一个参数
--         name = namespace       --   → 它其实是 name
--         namespace = nil        --   → namespace 未指定
--     end
--   ★★★ 这是「可选第二参数」的经典实现：不靠默认值靠 if。
--     ★ 若只传一个参数（内置 RPC 的情况），走 :1990 分支。
--   ★★★ 两分支（第 1987-1991 行）：
--     if namespace then  -- 模组 RPC
--         fn = GetModRPCHandler(namespace, name)
--     else               -- 内置 RPC
--         fn = RPC_HANDLERS[RPC[name]]  -- ★ 两级：名字→数字→函数
--     end
--   ★★ 内置分支的 RPC[name] —— 用名字查编号，再编号查函数。
--     ★ 注意此时 RPC_HANDLERS 已是「数字→函数」（:1401 转换后），
--       所以 RPC_HANDLERS[RPC[name]] 是正确的两级查找。
--   ★★★ 最后一行：USERID_RPCS[fn] = true —— ★★ 用「函数」作键标记。
--     ★ 标记的是「这个函数对应的 handler 收 userid 而非实体」。
--     ★ 消费点：HandleRPC（:1682）与 HandleModRPC（:1904）。
--   ★★★ 内置 RPC 的例子：GetChatHistory（:1114）——
--     它在选人阶段（玩家实体未生成）就要用，故必须标记。
--   ★→ 移植规则：★ 若新增一个「第一个参数不是实体」的 RPC，
--     必须调 MarkUserIDRPC，否则 HandleRPC 会拒绝（:1698）
function MarkUserIDRPC(namespace, name)
    if not name then
        name = namespace
        namespace = nil
    end

    local fn
    if namespace then
        fn = GetModRPCHandler(namespace, name)
    else
--★ fn = RPC_HANDLERS[RPC[name]] —— ★ 内置 RPC 的两级查找]
--   ★★★ RPC[name] 拿编号（:1401-1404 建立的「名字→数字」映射）；
--     RPC_HANDLERS[编号] 拿函数（:1401 改造后的「数字→函数」映射）。
--   ★★★ 这正是「双向映射表」的标准用法 —— 两张表各存一方向。
--   ★★ 若 name 不存在（模组拼错），RPC[name] 为 nil，
--     → RPC_HANDLERS[nil] 在 Lua 中是合法的（返回 nil），不崩溃。
--     → 但 USERID_RPCS[nil] = true 会**崩溃**（table index is nil）！
--     ⚠ 这是一个隐患：MarkUserIDRPC("不存在的名字") 会崩溃。
--     → 移植时应先 `if fn ~= nil then`。仅标注，不改码。
        fn = RPC_HANDLERS[RPC[name]]
    end
--★★[USERID_RPCS[fn] = true —— ★★ 用函数作键的标记]
--   ★★★ 与 :1398 的 USERID_RPCS 表对应。
--   ★★ 「以函数为键」的必要性：
--     · HandleRPC/HandleModRPC 里查到的是**函数**（fn），
--       标记表用函数作键可以直接查（:1682 `if USERID_RPCS[fn]`）；
--     · 若用 RPC 名作键，HandleRPC 收到的是 code（数字），还要反查名字。
--     ★★ 所以「以函数为键」是最直接的实现。
    USERID_RPCS[fn] = true
end
--★★ MarkUserIDRPC 结束。★★★ 回顾它的完整链路（§九 的核心机制）：
--   ① MarkUserIDRPC(:1980) 标记某 handler「以 userid 为第一参数」；
--   ② 标记存入 USERID_RPCS[fn]（:1992，以函数为键）；
--   ③ HandleRPC(:1682) / HandleModRPC(:1904) 检查该标记，把 sender 从实体替换为 userid 字符串。
--   ★★ 三个函数构成一条完整的「userid 型 RPC」支持链。
--   ★★ 典型用例：GetChatHistory(:1114) —— 玩家实体未生成时也要能请求聊天历史。

--For gamelogic to deactivate world on a client when
--server has initiated a reset or world regeneration
--★★★★★[DisableRPCSending —— ★★ 世界重置/重生成时的一键熔断]
--   ★★★ 原注释：
--     "For gamelogic to deactivate world on a client when
--      server has initiated a reset or world regeneration"
--   ★★★ 场景：服务端发起世界重置/重生成时，客户端需要「进入不活跃态」，
--     此时停止一切 RPC 发送（避免在世界卸载过程中发包出错）。
--   ★★★★ 实现手法：★★ 直接把六个发送函数**替换成空函数**。
--     ★★★ 这是「重绑定全局函数」而非「设置一个标志位」：
--     · 关闭后的调用成本 = 函数调用开销（立即返回空），
--       ★ 连 if 判断都不需要（标志位方案还要在每个发送点判 if）。
--     · ★★ 干净：无需修改任何调用点——它们调用的是全局 SendRPCToServer，
--       ★ 替换全局定义即对所有调用点生效。
--   ★★★★ ⚠ 三个重要事实：
--     ① ★★ 只关「发送」，接收侧（HandleRPCQueue :1724）**照旧**；
--     ② ★ 替换是**全局永久**的（除非重新 require 本文件才恢复）；
--     ③ ★ 这是一个 **monkey patch**（猴子补丁）—— 直接改写已定义的全局函数。
--   ★★ 「关发送但仍收」是合理的：客户端停止主动动作，但服务端仍可推送状态
--     （如世界重置的进度、倒计时）。
--   ★★★ 这是「重置期间冻结客户端」的一个简化手段。
--   交叉引用：networking.lua:722 WorldResetFromSim（服务端发起重置）、
--             gamelogic.lua（调用 DisableRPCSending 的地方）。
function DisableRPCSending()
--★★[SendRPCToServer = function() end —— ★ 把内置发送函数替换为空函数]
--   ★★ 这是「全局函数重绑定」：SendRPCToServer 原本是 :1636 的真实实现，
--     现在被一个空函数覆盖 —— 所有调用 SendRPCToServer 的代码
--     ★ 都自动变成「什么都不做」。
--   ★★★ 与 :1999 的 SendModRPCToServer = SendRPCToServer 配对：
--     模组版发送函数也被替换，且**指向同一个空函数**（复用）。
--   ★★ 复用而非各写一个空函数：省内存（同一个闭包被多处引用）。
--     ★ 空函数无捕获变量 → 所有空函数其实是同一个对象（Lua 优化）。
    SendRPCToServer = function() end
--★★[SendModRPCToServer = SendRPCToServer —— ★★ 模组版也指向空函数]
--   ★★★ 「让六个发送函数都指向同一个空函数」的配对写法。
--   ★★★ 内置版（:1998）先变空，然后这里让模组版也指向它 ——
--     ★ 顺序有意义：必须先定义空函数，再引用它。
    SendModRPCToServer = SendRPCToServer
--★★[SendRPCToClient = function() end —— 服务端→客户端发送也被禁用]
--   ★★★ 注意：V2C 发送也被关。
--     ★ 在「客户端正在重置」时，客户端本来也不该发 V2C（那是服务端发的），
--       但这里一并关闭是「一刀切」的思路（简单彻底）。
    SendRPCToClient = function() end
--★ SendModRPCToClient = SendRPCToClient —— 模组版 V2C 也指向空函数。
    SendModRPCToClient = SendRPCToClient
--★ SendRPCToShard = function() end —— ★ 分片发送也被禁用。
--   ★★★ 一个客户端（纯客户端）通常不用发 shard RPC（那是服务端进程的事），
--     但这里一并关闭是「宁可多关」的思路。
    SendRPCToShard = function() end
--★ SendModRPCToShard = SendRPCToShard —— 模组版分片发送也指向空函数。
--   ★★★ 至此六个发送函数全部熔断（:1998-2003）。
    SendModRPCToShard = SendRPCToShard
end
--★★★ DisableRPCSending 结束。整个文件至此完整闭合。
--   ★★★ 全文件结构总览（19 节）：
--     §零   类型校验谓词（check*/opt*）—— 安全地基
--     §一   非法 RPC 三段式处理 —— 安全哲学
--     §二   几何与范围原语（IsPointInRange 等）
--     §三   RPC_HANDLERS（90 个不可信方向 handler）
--     §四   编号机制（orderedPairs 终身绑定）
--     §五   CLIENT_RPC_HANDLERS（16 个，V2C 可信）
--     §六   SHARD_RPC_HANDLERS（13 个，S2S 可信）
--     §七   三个发送函数
--     §八   限流常量与三条队列
--     §九 ★ HandleRPC 入队（不立即执行的答案）
--     §十 ★ HandleRPCQueue 排空（同刻重入保护）
--     §十一 大小写不敏感元表
--     §十二 ★★ AddModRPCHandler（缺陷 B 执行点）
--     §十三 模组 RPC 收发
--     §十四 查询 API 与 MarkUserIDRPC
--     §十五 DisableRPCSending 熔断
--   ★★★ 本文件回答了三个核心问题：
--     1) 「不可信输入如何安全处理」→ §零/§一/§二/§三
--     2) 「为什么收到 RPC 不立即执行」→ §九（时序/公平/限流/效率）
--     3) 「三条方向如何分工」→ §三/§五/§六 的信任模型
--   ★★ 已知缺陷（详见文件头清单）：
--     A（:43 位置≠合法性）、B（:1848 ★ 模组抬限流）、C（:715 空实现）、
--     D（:1035 exitgym）、E（:1646/:1656 文档过时）
