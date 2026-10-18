--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：netvars.lua
-- 模块：网络同步层 / 网络变量（Network Variable）类型契约
-- 职责：DST 同步层的「类型契约」。声明 13 种 net_* 网络变量的位宽与值域、
--       set / value / set_local 三件套的语义（含脏值检测规则）、
--       一次性触发事件 net_event 的约定，以及整数宽度选择器
--       GetIdealUnsignedNetVarForCount。
-- ★★ 本文件不含同步实现：13 个 net_* 构造器全部是 C++ 内建函数
--       （见文件首行注释指向的 luanetworkvariable.cpp），Lua 侧零实现。
--       它是「Lua 与 C++ 双份真相」的一份，宽度表在 C++ 里也有一份。
-- 关键符号：net_bool .. net_ushortarray（类型表，仅注释）、net_event、
--           net_event:push、GetIdealUnsignedNetVarForCount
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：entityreplica.lua（replica 分发链路，本层的另一半）、
--           class.lua:176（Class 构造器调用约定 c._ctor(obj, ...)）、
--           components/clock.lua:161 ForceResync（set_local 的官方对冲手段）、
--           prefabs/player_classified.lua:1330-1520（wire format 实战声明区）、
--           components/clientpickupsoundsuppressor.lua:23（不用 net_event 的反例）
-- 【★已核实缺陷】net_event 构造器只接受 (guid, event) 两个业务实参，
--       第三个实参被 Lua 静默丢弃；alterguardian_phase1/2/3 传了第三个实参
--       却按其生效，详见下方第 85 行注。
--============================================================
--V2C: TODO: work
--     Keep this file up to date with luanetworkvariable.cpp
-- NOTES(JBK): Keep this up to date with GetIdealUnsignedNetVarForCount below if more unsigned integers are created.
-- ★★ 本文件是DST 同步层的「类型契约」，但它自己几乎不含同步逻辑 ——
-- 因为 13 个 net_* 构造器全部是 C++ 内建函数（luanetworkvariable.cpp 注册），
-- Lua 侧没有任何一行实现。我已核实：全树 grep 不到 net_bool = 或 function net_bool。
--
-- 【整个同步层只有 2 个 Lua 文件是本真的】
--   · netvars.lua（本文件）—— 类型契约 + net_event 这一个薄包装
--   · entityreplica.lua —— replica 的创建与分发链路
-- 其余（networking / networkclientrpc / shardnetworking）都建立在 C++ 的 TheNet 之上。
--
-- 【★移植要点：netvar 的「声明顺序」就是 wire format】
-- C++ 侧反序列化一个实体时，按 Lua 侧声明 net_* 的先后顺序逐个读取字节。
-- 所以同一实体在服务端与客户端必须「以完全相同的顺序声明完全相同的一组 netvar」，
-- 否则整个实体的反序列化会错位失败 —— 不是某个字段错，是从那行起全部错位。
-- 这条约束在下方 29-32 行有原文说明，也是模组用 netvar 风险极高的根因：
-- 模组改了声明顺序，服务端与客户端 mod 版本不一致时必然炸。
--
-- 【★脏值检测（dirty check）的语义在下方 44-67 行，是本文件最值得抄的部分】
--[[

    net_bool                1-bit boolean
    net_tinybyte            3-bit unsigned integer   [0..7]
    net_smallbyte           6-bit unsigned integer   [0..63]
    net_byte                8-bit unsigned integer   [0..255]
    net_shortint            16-bit signed integer    [-32767..32767]
    net_ushortint           16-bit unsigned integer  [0..65535]
    net_int                 32-bit signed integer    [-2147483647..2147483647]
    net_uint                32-bit unsigned integer  [0..4294967295]
    net_float               32-bit float
    net_hash                32-bit hash of the string assigned
    net_string              variable length string
    net_entity              entity instance
    net_bytearray           array of 8-bit unsigned integers (max size = 31)
    net_smallbytearray      array of 6-bit unsigned integers (max size = 31)
    net_ushortarray         array of 16-bit unsigned integers (max size = 31)

    * Arrays are expensive.  Avoid using them, especially if the values
      will change often.

    * net_hash can be set by a hash or string (automatically converted to
      hash), but only returns the hash value when read.  The network cost
      is the same as a 32-bit unsigned integer.

    * netvars must exist and be declared identically on server and clients
      for each entity, otherwise entity deserialization will fail.  Note
      that this means if a MOD uses netvars, then server and clients must
      all have the same MOD active.

    * Server and clients may register different listeners for dirty events.

    * netvar dirty events are triggered before lua update.

--]]
-- ⚠️ 上面这段长注释块就是完整的 wire format 速查表。设计上有三条硬规则值得学：
--
-- 【规则一：位宽必须与语义域严格匹配，不留「余量」】
--   列举一个：net_tinybyte 只有 3 位、值域 [0..7]。
--   拿它存「枚举下标」是安全的，拿它存「数量」就迟早溢出。
--   DST 里的标准做法是让每个字段自己匹配类型，而不是全表统一用 net_int ——
--   一个玩家身上挂了上百个 netvar，宽度差 1 位在 60 人房里就是每秒差几百 KB。
--
-- 【规则二：数组类型一律限量 31 个，且原文直言「Arrays are expensive」】
--   31 这个上限来自「长度也要占位」的实现方式，不是随便定的。
--   自己写同步层时，数组字段应当优先用「定长 net_* 序列」替代动态数组。
--
-- 【规则三：net_hash 可以写入字符串、读出来只有哈希值】
--   写入侧自动把字符串转哈希，读取侧拿不到原文。这是个单向门，
--   写代码时别指望 round-trip 拿回原始名字，否则会出现「设置对了但不生效」。

----------------------------------------------------------------------------

--[[

    netvar:set(x)
-- ★★★ 脏值检测三件套之一：set —— 唯一的「权威写」入口。
-- 只有 set 会产生网络同步与脏事件，且脏事件「仅在值真的变了时」才触发。
--
-- 【为什么「仅在值真的变了时」是性能命门】
-- 一个实体的脏事件会驱动 UI、音效、特效重播。若每帧无条件广播，
-- 60 人 × 每人数百 netvar × 每帧 60 次 = 带宽直接爆炸。
-- 脏值检测让「静止不动」的成本降到接近零：只有变化的那几个字段走网络。
-- 代价是 C++ 侧必须为每个 netvar 保存上一帧的值 —— 即内存换带宽。
    - Call on the server to set the value, which will be synced to clients.
    - Dirty event is triggered on server and clients (only if value has
      actually changed).
-- ⚠️ 注意 set 只应在服务端调用。客户端调用 set 不会同步给任何人，
-- 是个典型误用：DST 里大量组件把「加血」写成两端都能调的样子，
-- 实际只有服务端那半边真正生效，客户端那半边是纯粹的死代码。

    netvar:value()
-- 三件套之二：value —— 读当前值。服务端与客户端都可读。
-- ★读到的永远是「本端当前值」：客户端读到的是「上次同步来的值」或
-- 「自己用 set_local 预测过的值」，不保证与服务端此刻一致。
-- 这正是客户端预测（prediction）能成立的前提，见 clock.lua 的 OnUpdate。
    - Call on the server or clients to read the current value.

    netvar:set_local(x)
-- ★★★ 三件套之三：set_local —— 「本地写」，不触发同步、不触发脏事件。
-- 它是客户端预测的唯一入口，也是本文件最容易被误用的 API。
--
-- 【★set_local 的代价：服务端的下一次 set 必定是脏的】
-- 原文写得很明确（第55-57 行）：既然无法知道客户端把值预测成了多少，
-- 服务端 C++ 侧只能保守假设「客户端可能已经改成任何值了」，
-- 于是把「上次同步值」的影子作废 —— 下一次服务端 set 无论值是否真变，都会重发。
-- 也就是说：set_local 用得越频繁，服务端的无效重发就越多。
-- 自己写同步层时，这个「保守作废」是必须照抄的正确性保证，
-- 否则客户端预测会让两端状态永久性漂移。
    - Call on the server or clients to set the value without triggering
      a sync or dirty event.
    - NOTE: this results in the next server set(x) to be dirty regardless
            of whether the value changed, since we assume the client may
            have set_local(x) to any arbitrary value.

    * set_local is generally used in code paths shared between server and
-- 【★set_local 的正确用法：让「服务端与客户端共用的同一条代码路径」去调它】
-- 这是本段最重要的一句工程建议（第59-63 行）。
-- 典型形态：
--     function tick(dt) self.timer:set_local(self.timer:value() - dt) end
-- 这行代码两端都会跑。服务端那半边算完会顺手 set（同步给所有人），
-- 客户端那半边只 set_local（本地推进，不占带宽）。
--
-- 【换个写法会怎样错】
-- 若拆成 ismastersim 两个分支各自实现，客户端分支就会缺一个「回正」机制：
-- 客户端预测久了必然与服务商脱节，而服务端因为不知道客户端预测到哪了，
-- 只能整体重发整个字段来纠正 —— 带宽浪费，且瞬移感明显。
-- 原文第65-67 行给的正是这个例子：平滑计时器由客户端本地推进，
-- 服务端只在「每个segment 结束时强制对齐一次」。
      clients.  Clients may have enough information (such as elapsed time)
      to estimate and update the value locally.  Sharing the code path also
      allows the server to be aware that the value is being updated locally
      on clients.

    * Example usage of set_local(x) is to let clients update smooth timer
      ticks locally.  Server saves bandwidth by only needing set(x) to
      force a resync every now and then.

--]]

----------------------------------------------------------------------------

--[[

    net_event (as a wrapper over net_bool)
-- net_event 不是新的线格式类型，它就是 net_bool 的语法糖（第86 行有构造实现）。
-- 存在的唯一理由：把「一次性触发」和「状态」在类型上区分开，避免误用。
    net_event:push()

    * Use events for one-shot triggers such as a sound FX, but not state
-- ★原文这条规则是硬约束：一次性触发（音效、特效）用 net_event，
-- 状态变化必须用 net_bool。
-- 【为什么不能统一用 net_bool】
-- 用 net_bool 表达「播放音效」时，「已经为true」会吞掉后续的重复触发 ——
-- 因为脏事件只在值变化时触发。所以状态必须能靠「值本身」表达，
-- 而一次性事件必须每次都能重新触发。两者的数据结构要求正好相反。
-- ⚠️ 源码 components/clientpickupsoundsuppressor.lua:23 有作者的显式印证：
--    那里同时需要 true 与 false 两个方向，就故意不用 net_event 而用 net_bool。
      changes (which should use net_bool instead).

--]]

require("class")
-- 引入 Class 工具。net_event 是全文件唯一的 Lua 类实例。
-- 依赖方向：netvars.lua 依赖 class.lua，反向不依赖 —— 保持单向。

net_event = Class(function(self, guid, event)
-- ★ net_event 构造器。注意签名只有三个参数：(self, guid, event)。
--
-- 【本文件唯一可写的 Lua 逻辑：把「事件名」同时用作 net_bool 的名字与脏事件名】
-- 第三个实参 event 被同时填进 net_bool 的第 2、3 个位置，
-- 所以「事件名 == 线上的字段名 == 脏事件名」三者是同一个字符串。
-- 这就是为什么下方 frostybreather 那样使用时，客户端监听事件名
-- 必须写完整的点分路径（如 "frostybreather.breathevent"）而不是短名。
--
-- 【★核实到的真实缺陷：第 3 个实参会被静默丢弃】
-- 依据一：class.lua:176 的调用约定是 c._ctor(obj, ...)，即 self 被对象占掉，
--   所以本函数实际只接受 (guid, event) 两个业务实参。Lua 对多余实参不报错，
--   直接丢弃 —— 传第三个参数不会警告，也不会生效。
-- 依据二：prefabs/alterguardian_phase1.lua:405 确实传了第三个实参：
--   net_event(inst.GUID, "alterguardian_phase1._musicdirty", "musicdirty")
--   期望是「线上字段名用长名、脏事件名用短名 musicdirty」，
--   但实际生效的脏事件名是长名 "alterguardian_phase1._musicdirty"。
-- 依据三：同一文件第 417 行监听的是 inst:ListenForEvent("musicdirty", OnMusicDirty)，
--   事件名对不上，该监听在客户端永远不会由这个 netvar 触发。
--   同型写法也出现在 alterguardian_phase2.lua:349/356 与 phase3.lua:390/397。
-- 后果判断（未核实运行时表现，仅静态推导）：
--   第 99-100 行的 SetNoMusic 在服务端 push 后紧接着直接调 OnMusicDirty(inst)，
--   所以服务端侧行为正常；受影响的是依赖网络事件的那一侧。
-- ⚠️ 我未运行游戏，无法确认这是否造成可观察的异常，故标注为静态推导而非实测缺陷。
--
-- 【移植启示】若要支持「字段名与脏事件名不同」，正确做法是改写构造器为：
--     self._bool = net_bool(guid, event, dirtyevent or event)
-- 让调用方显式传第三个参数并被接收，而不是像现在这样传了就丢。
    self._bool = net_bool(guid, event, event)
end)

function net_event:push()
-- 触发一次事件。两行代码的顺序有讲究，不能只写第二行。
    self._bool:set_local(true)
-- ★先 set_local(true)：让服务端本地立刻处于「已触发」状态，
-- 这样服务端自身逻辑无需等待网络回环就能响应（低延迟）。
-- 这一步也顺带把客户端那边的预测状态推到 true，
-- 与上面 44-47 行「set 仅在值真变时才是脏」的规则配套：
-- 若省略本行、只调下一行 set(true)，在某些时序下会因值已是 true 而不触发脏事件。
    self._bool:set(true)
-- ★再 set(true)：走权威通道，把变更同步给所有客户端，由它们各自触发脏事件。
-- 【为什么两步都不能少】
--   只有 set(true)  —— 服务端本地要等网络往返才生效，本地反馈延迟明显。
--   只有 set_local —— ★永远同步不出去，客户端永远收不到这个事件。
-- 组合起来才是「本地立即响应 + 全网可靠送达」，也是所有事件型网络字段的标准范式。
end


-- NOTES(JBK): This should be used sparingly but it will return a networked variable integer that best holds the count requirement.
-- ⚠️ 原文自己写了两个使用约束，都在文件顶部第 1-3 行：
--   约束一：本文件必须与 luanetworkvariable.cpp 保持同步；
--   约束二：本函数也必须与 C++ 侧同名实现保持同步。
-- 即这是「Lua 与 C++ 双份真相」，改了一边不改另一边会导致宽度不匹配而静默读错值。
-- ★这正是 4-38 行那条「两端声明必须一致」规则的根源：宽度表本身在 C++ 里。
-- Caller should assign this as a variable with a suffix of _net_enum for file searches.
-- ★返回值是「类型本身」（net_tinybyte 这个函数），不是实例。
-- 调用方必须自己再传 (guid, name, dirtyevent) 造出实例：
--     local n = GetIdealUnsignedNetVarForCount(#LIST)  -- n 是 net_byte 这个函数
--     self.count = n(inst.GUID, "my.count", "countdirty")
-- 原文要求调用方把结果赋给一个以 _net_enum 结尾的变量名，便于全文检索 ——
-- 这是很值得学的可维护性约定：让「宽度决策点」在全工程里可被 grep 出来。
function GetIdealUnsignedNetVarForCount(count)
-- 按「值域上界」选最窄的无符号整型。纯查表，O(1) 无循环。
--
-- 【★这个函数的真正价值：用「值域」而不是「大概够用」来定宽度】
-- 自研引擎最常见的带宽浪费，就是所有计数器都用 int/int32。
-- 一个 0..7 的枚举用 int32 存，光这一项就是 net_tinybyte 的 10 倍宽度。
-- 照抄这个「上界 → 最窄类型」的查表思路即可，代价为零。
    if count <= 7 then
-- 注意判定顺序：从最窄往上试。因为 0..7 同时也满足后面所有条件，
-- 必须先命中窄的那个。若把顺序写反（从 uint 往下试），会全部退化成 net_uint。
        return net_tinybyte
    elseif count <= 63 then
        return net_smallbyte
    elseif count <= 255 then
        return net_byte
    elseif count <= 65535 then
        return net_ushortint
    elseif count <= 4294967295 then
        return net_uint
    end
    return nil -- Intentional in case something is trying to have an integer net var way out of spec.
-- ★返回 nil 而非兜底成一个宽类型 —— 这是有意的防御式设计。
-- 传入超出 uint32 范围的数量（如误把一个超大表的长度传进来），
-- 宁可让调用方在 nil 上立刻崩掉，也不要静默截断成一个错误的窄类型，
-- 那样会变成「同步了错误数据但没有任何报错」，排查成本高一个数量级。
--
-- 【★移植要点】原注释写明这是 "Intentional"。
-- 自己写类似的选择器时，不要图省事写个 return net_int 兜底 ——
-- 静默降级比快速失败危险得多，这是网络层特有的失败模式。
end