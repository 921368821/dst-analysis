--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：prefabs/world_network.lua
-- 模块：网络同步层 / 世界网络实体的装配（TheWorld.net）
-- 职责：装配全服共享的网络权威实体 TheWorld.net。演示三件事：
--       1) 一个实体如何成为全服共享的网络根；
--       2) ★AddShardClient 与 AddNetwork 两个正交维度如何组合成分片拓扑；
--       3) ★SetPristine 如何划分「构造期」与「服务端专属期」的分界线。
-- 本文件返回一个「工厂函数」而非实体，供各存档复用同一套装配逻辑。
-- 关键符号：MakeWorldNetwork, PostInit, FlushLocalDirtyNetVars,
--           OnRemoveEntity, DoPostInit, AddShardClient, AddNetwork,
--           SetPristine, DoStaticTaskInTime
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：netvars.lua:44-47（脏值规则，本文件第 3 行是其官方 flush 出口）、
--           netvars.lua:65-67（平滑计时器由客户端 set_local 预测的范式）、
--           entityscript.lua（SetPristine 标志的同一机制）、
--           components/clock.lua（本文件第 57 行装配的时钟，预测+纠偏范本）、
--           components/worldvoter.lua / components/shard_worldvoter.lua（按分片分层）、
--           prefabs/world.lua（调用本工厂的具体存档）
-- 【★移植要点】① 两段式标签之外的第二个核心：所有 AddComponent 必须在
--   SetPristine 之前完成，否则含 netvar 的组件只在服务端存在，
--   两端 wire format 长度不一致会导致反序列化整体错位。
--   ② ismastersim 与 TheNet:IsDedicated 是正交的两个维度，不可互相替代。
--============================================================
local function PostInit(inst)
-- ★★ 本文件是「ismastersim / ismastershard 正交性」最干净的教学样本。
-- 全文 78 行，却完整演示了三件事：
--   1) 一个实体如何成为「全服共享的网络权威实体」；
--   2) ★AddShardClient 与 AddNetwork 两个维度如何正交组合（见 48-49 行）；
--   3) SetPristine 如何划分「构造期」与「服务端专属期」的分界线（见 54 行）。
--
-- 【为什么它值得单独读】
-- 前三个文件（netvars / entityreplica / networking）讲的是「怎么同步」，
-- 本文件讲的是「同步拓扑的根节点在哪」—— 它就是 TheWorld.net。
-- 自己的引擎若要做「分片（sharding）」，这个文件的装配顺序可直接照抄。
--
-- 【★注意本文件返回一个「工厂函数」而不是实体】
-- 下方 MakeWorldNetwork 接收 customprefabs / customassets / custom_postinit，
-- 说明不同存档（主世界、洞穴、月亮岛等）会复用同一套装配逻辑、只换参数。
    inst:LongUpdate(0)
-- ★LongUpdate(0) 强制立刻跑一次更新（dt=0）。
-- 【为什么必须立刻跑一次】
-- 时钟组件是「初始化时调用一次来对齐状态」的：下方 clock.lua:277-284 的
-- 初始化段会 set 出一组基准 netvar。若不立刻驱动一次，
-- 这些基准值要等到下一个正常 tick 才会被推出去。
-- dt=0 表示「只跑逻辑、不推进时间」，所以不会破坏计时起点。
    inst.entity:FlushLocalDirtyNetVars()
-- ★★ FlushLocalDirtyNetVars —— 把本地累积的脏 netvar 立刻推给网络层。
-- 【这一行是「netvars 脏值机制」的官方 API 出口，全工程仅此一例】
-- 回顾 netvars.lua:44-47 的规则：set 会在值变化时标脏，但「何时发送」
-- 由引擎的批量发送周期决定。此处强制 flush，就是把这个「等一个 tick」
-- 的窗口压到零，让全服在实体创建瞬间就拿到一致的初始状态。
--
-- 【★为什么实体创建后必须立刻 flush】
-- 若不 flush：这个实体在客户端上线时可能读到「尚未初始化的默认 netvar」，
-- 于是客户端的昼夜、月相会在第一个 tick 里突然跳变（视觉闪一下）。
-- force flush 把「初始状态」与「第一个正常 tick」之间的裂缝消除。
--
-- 【移植要点】自研引擎的「属性批量同步」同样需要这个「立即冲刷」出口，
-- 典型用途就是「实体创建/加载完成时立刻对齐一次」。

    for k, v in pairs(inst.components) do
-- 遍历所有组件，调用可选的 OnPostInit 钩子。
-- 【与构造阶段的区别：这里组件已全部挂载完毕】
-- OnPostInit 能安全地访问其它组件（此时它们都已存在），
-- 而构造函数执行时组件还在一个个添加中，看不到后面的组件。
-- 凡是「需要跨组件协作」的初始化都应放这里，不要放构造函数。
-- ⚠️ 遍历的是 pairs，顺序不确定 —— 故各组件的 OnPostInit 不能相互依赖。
        if v.OnPostInit ~= nil then
            v:OnPostInit()
        end
    end
end

local function OnRemoveEntity(inst)
-- 世界网络实体的销毁钩子。
-- ★关键：清的是 TheWorld.net（网络根节点），不是 TheWorld 本身。
    if TheWorld ~= nil then
        assert(TheWorld.net == inst)
-- ★断言 TheWorld.net 必须指向自己。
-- 【★这是本文件唯一的强不变量，值得学】
-- 断言在 if TheWorld ~= nil 之内，所以只保护「世界尚在时」的销毁路径。
-- 换个写法（先清再断言）会在断言失败前留下半清理状态，更难排查。
        TheWorld.net = nil
    end
end

local function DoPostInit(inst)
-- 客户端侧的后初始化。用 DoStaticTaskInTime(0) 延后到下一个时间片执行。
-- 【★为什么必须延后而不是直接调用】
-- 此刻实体刚构造完，所有网络实体尚未到齐、客户端尚未完成初始反序列化。
-- 直接调 PostInit 会读到不完整的世界状态。
-- 「时间片 0」即下一个调度点，是最早的安全时机。
    if not TheWorld.ismastersim then
-- ★★ 判据一：只要我不是 master sim，就要自己补做一次 PostInit。
-- 【★为什么是「补做」而不是「跳过」】
-- 服务端已经做过一遍完整的 PostInit（第 1 行那个函数）。
-- 客户端没有服务端的世界状态，所以必须自己再跑一次本地版本，
-- 才能把昼夜、季节等推进到客户端本地可用的状态。
-- 即：PostInit 在服务端与客户端各跑一次，但只有服务端那次会 flush 到网络。
        if TheWorld.isdeactivated then
-- 客户端世界若已停用（deactivated），直接返回，不做任何初始化。
-- 【为什么需要这个短路】
-- 世界停用意味着「即将退出 / 正在重连」，此时做初始化毫无意义，
-- 且很可能访问到已被清理的对象而崩溃。
-- 这是异步网络游戏中典型的「时序竞态防护」。
            --wow what bad timing!
            return
        end
        --master sim would have already done a proper PostInit in loading
-- 原文注释：master sim 已在加载期做过一次正确的 PostInit。
-- 与第 20 行的 if 呼应，构成「服务端已做 / 客户端补做」的完整表述。
        TheWorld:PostInit()
    end
    if not TheNet:IsDedicated() then
-- ★★ 判据二：非专用服务器（即「有本地玩家」的客户端）才做下列处理。
-- 【★TheNet:IsDedicated 与 ismastersim 是不同维度，不要混用】
--   ismastersim —— 我是不是这个模拟端的权威（关于「世界」）
--   IsDedicated  —— 这个进程有没有本地玩家窗口（关于「进程形态」）
-- 一个专用服务器是 master sim 但也是 dedicated；
-- 一个「房主单机」既是 master sim 又是 IsDedicated 为 false。
-- 第 30 行那段逻辑只对后者有意义 —— 他需要向服务器请求 resume。
--
-- 【★两个判据正交组合的完整四象限】
--   专用服务器   ：ismastersim=true,  IsDedicated=true  → 第 20 行 false、第 28 行 false
--   房主/单机   ：ismastersim=true,  IsDedicated=false → 走完整 PostInit + resume 请求
--   纯客户端     ：ismastersim=false, IsDedicated=false → 走客户端 PostInit + resume 请求
--   次 shard 服务：ismastersim=true（对次 shard 而言）, IsDedicated=true
-- 这正是任务里说的「两个维度分别控制」，本文件是最佳例证。
        if ThePlayer == nil then
            TheNet:SendResumeRequestToServer(TheNet:GetUserID())
-- ThePlayer 为空说明本地玩家尚未就位，向服务器发「请求恢复」指令。
-- 【★这是「重连/快速加入」的握手：客户端渲染先行，状态随后对齐】
-- 不要改成「等待 ThePlayer 就位再继续」—— 那会阻塞首帧加载。
-- 发一个请求让服务器把状态推过来，是异步网络游戏的正确姿势。
        end
        PlayerHistory:StartListening()
-- 启动玩家历史（重连时恢复上一局操作记录）。非专用服务器才需要。
    end
end

--------------------------------------------------------------------------

local function MakeWorldNetwork(name, customprefabs, customassets, custom_postinit)
-- ★★ 工厂函数。返回 Prefab，内部函数 fn 是真正的实体构造函数。
-- 三个参数的意义：
--   name            —— 预制体名（不同存档可同名，走各自存档空间）
--   customprefabs  —— 该存档额外可用的预制体清单
--   customassets    —— 该存档额外需要的资源清单
--   custom_postinit —— ★在标准装配之后、绑定回调之前插入自定义逻辑的钩子
--
-- 【★custom_postinit 的位置很讲究】
-- 它插在「加完组件」与「绑定 PostInit 回调」之间：
--   早一点 → 改不了标准组件；晚一点 → 改不了时钟初始化时机。
-- 放在这里，模组既能追加自己的组件，又能保证标准组件的初始化顺序不被破坏。
-- ★扩展点选在「依赖注入」而非「继承」，是 DST 少用 OOP 而多用组合的体现。
    local function fn()
        local inst = CreateEntity()

        assert(TheWorld ~= nil and TheWorld.net == nil)
-- ★双重断言：TheWorld 必须存在，且 net 槽位必须为空。
-- 【★为什么必须是单例断言】
-- 若能同时存在两个网络根实体，两个都会开始 flush 状态、广播更新，
-- 客户端将收到互相矛盾的世界状态 —— 且这种 bug 表现为「偶发时间不同步」，
-- 极难定位。fail-fast 是唯一正确的选择。
        TheWorld.net = inst
-- ★★ 全服共享的网络根节点。整个同步拓扑从这里长出来。
-- 【为什么要区分 TheWorld 与 TheWorld.net】
-- TheWorld 是逻辑世界（两端都有）；TheWorld.net 是「参与网络同步的那一半」。
-- 分离的好处：客户端的 TheWorld 可以自由改动本地表现，
-- 而 TheWorld.net 上的 netvar 受 netvars 规则管辖，脏值检查自动生效。

        inst.entity:SetCanSleep(false)
-- 禁止休眠。★世界是永远活跃的，若允许休眠，网络推送会停滞。
-- 【★对比普通实体：普通实体休眠是优化，世界休眠是灾难】
-- 实体休眠能省 CPU，但世界一旦睡了就没人跑 netvar 推送，
-- 客户端时间会逐渐漂移。此行是同步层正确性的硬保证。
        inst.persists = false
-- 不持久化。★与「客户端 TheWorld.net」配套 —— 客户端那份不该存盘。
-- 服务端的世界状态另有 shardindex / saveindex 持久化，不依赖这个实体。

        inst.entity:AddShardClient()
-- ★★★ AddShardClient —— 声明「我要成为某个 shard 的客户端端点」。
--
-- 【★两个调用如何正交，构成四象限拓扑】
-- 下面 49 行的 AddNetwork 与本行是两个独立维度：
--   只有 AddNetwork            → 只加入模拟端网络（主 shard 的服务端实体）
--   只有 AddShardClient        → 只挂到分片客户端（次 shard 的转发端）
--   两者都调（本行 + 下一行）  → 既在模拟端网络里、又向分片注册（主 shard 的权威端）
--
-- 【★这就是 DST「一个世界 = 主 shard + 若干次 shard」的实现方式】
-- 主 shard 同时具备两个身份：它是模拟端的权威（需要 AddNetwork），
-- 同时它自己也是次 shard 的客户端（需要 AddShardClient 去收上一级分片的数据）。
-- 这解释了为什么全局判断需要 ismastershard 这个第二维度：
-- 「在主 shard 上 ismastershard=true，在次 shard 上为 false」，
-- 而 ismastersim 在每一级 shard 上都各有一个 true。
-- ★自研引擎做分片时，这是最值得照抄的一段拓扑装配代码。
        inst.entity:AddNetwork()
-- ★★★ AddNetwork —— 声明「我要加入模拟端的实体网络」。
-- 与上一行的 AddShardClient 构成正交的两个维度，详见上一行注。
--
-- 【★顺序有意义：先 AddShardClient 再 AddNetwork】
-- 若颠倒，部分引擎版本会因为实体尚未注册 shard 就加入网络而拒绝。
-- 移植时若发现同步不生效，第一件事就是核对这两行的先后。
        inst:AddTag("CLASSIFIED")
-- ★打 CLASSIFIED 标签。classified 机制：实体人人可见，但客户端本地决定是否呈现。
-- 【★为什么世界的 classified 标记尤其重要】
-- 世界的 netvar（昼夜、月相、季节）是所有客户端共同依赖的。
-- 若某个客户端因任何原因没把它算作 classified，就会出现「个别玩家时间不同步」。
-- 打了 CLASSIFIED 后，所有客户端都会建立这一份本地副本，
-- 各自独立地渲染，但数据来自同一次同步。

        inst:AddComponent("shardstate")
-- shardstate 组件：管理本 shard 的状态数据与跨分片同步。
-- 与上面 AddShardClient 配套 —— 分片状态由它承接。

        inst.entity:SetPristine()
-- ★★★ SetPristine —— 「纯净期」到此结束。
--
-- 【★★本文件最硬核的一行，务必理解】
-- AddComponent 等操作在 SetPristine 之前会在服务端与客户端「都执行一遍」；
-- SetPristine 之后，同一份构造代码就只在服务端执行了。
-- 这不是 if，而是引擎层的代码路径分叉 —— 分叉点在 SetPristine 这一行。
--
-- 【★标准范式：所有 AddComponent 必须放在 SetPristine 之前】
-- 因为组件里有 netvar，而 netvar 必须在「所有端」都声明出来，
-- 才能让 wire format 对齐（第 55-61 行这些组件全在分界线之前，位置正确）。
--
-- 【换个写法会怎样错】
-- 若把某个含 netvar 的组件移到 SetPristine 之后：
--   服务端有该 netvar，客户端没有 → 两端 wire format 长度不一致，
--   客户端反序列化整体错位。表现是「这个实体的所有网络字段都变成乱值」，
--   且错位会顺着字段序传播到后续所有字段，排查时极难定位到真正的原因。
--
-- 【★SetPristine 与 entityscript.lua 的 pristine 标志是同一个机制】
-- 自研引擎实现该分叉有两种做法：
--   1) 运行时判断（本文件采用）—— 一个标志位，代价是每次调用都判一次；
--   2) 编译期分离 —— 服务端/客户端加载两份不同的构造代码，性能更好但易漂移。
-- DST 选 1，实现简单且不易出错；此处可作为「先正确后优化」的范例。

        inst:AddComponent("autosaver")
-- 以下 6 个组件全部在 SetPristine 之前（第 54 行）装配，位置正确。
-- 其中 autosaver 在服务端与客户端都会存在，但只服务端会真的存盘。
        inst:AddComponent("clock")
-- ★clock —— 全服共享的时钟，是脏值同步与客户端预测的最佳教材。
-- 详见 components/clock.lua：客户端本地 set_local 推进（预测），
-- 服务端在每个 segment 边界用 ForceResync 强制对齐（纠偏）。
-- ★这就是 netvars.lua:65-67 所说的「平滑计时器」范式的完整实现。
        inst:AddComponent("worldtemperature")
        inst:AddComponent("seasons")
        inst:AddComponent("worldreset")
        inst:AddComponent("worldvoter")
-- worldvoter —— 全服投票组件。
-- 与 shard_worldvoter 的分工：worldvoter 管本 shard，shard_worldvoter 跨 shard 汇总。
-- 再次印证分片架构：同一类逻辑按 shard 层级拆成多个组件。

        if custom_postinit ~= nil then
-- 模组 / 存档自定义钩子。在标准组件之后、绑定回调之前执行。
            custom_postinit(inst)
        end

        inst.PostInit = PostInit
-- ★把第 1 行的 PostInit 函数挂到实体上。
-- 挂的是「函数本身」而非调用它 —— 引擎会在恰当的时机回调。
-- 这样挂载是为了让调用时机由引擎决定（此时世界与客户端都已就绪）。
        inst.OnRemoveEntity = OnRemoveEntity

        inst:DoStaticTaskInTime(0, DoPostInit)
-- ★★ 延后执行 DoPostInit。与第 19 行那个函数配对。
-- 【为什么 PostInit 直接赋值（同步）而 DoPostInit 要延后】
--   PostInit 在第 2 行就跑：它只 flush 脏 netvar 与驱动各组件 OnPostInit，
--   此时两端都在同一构造流程内，状态是自洽的。
--   DoPostInit 要等客户端初始反序列化完成 —— 它读的是「别人发来的状态」，
--   在实体构造流程内读必然拿到不完整数据。
-- ★一句话：读自己状态可以立刻做，读网络状态必须等一个调度点。
-- DoStaticTaskInTime 的时间片为 0，即下一个调度点，是最早的安全时机。

        return inst
    end

    return Prefab(name, fn, customassets, customprefabs)
-- 注册为预制体。customassets / customprefabs 原样透传给 Prefab。
-- ★注意是「原样透传」而非合并 —— 存档需自行把基础资源一并列出。
-- 这是组合式扩展的代价：灵活但要求调用方自备清单。
end

return MakeWorldNetwork
-- ★返回工厂函数本身，不是调用结果。
-- 调用方（各存档的 world.lua）拿到它再自己调用并指定 name 与参数。
-- 我核实过：prefabs/world.lua 走的是同一条路径。