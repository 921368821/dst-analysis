--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：brains/braincommon.lua
-- 模块：AI 大脑 / 公共底座（brains/ 下 191 个大脑共用）
-- 职责：不是某只生物的大脑，而是【行为节点工厂库】。导出造子树的函数，
--       把 behaviours/ 的原子节点组装成可复用的复合子树，供所有具体大脑调用。
--       内容分五段：
--         1) 盐渍跟随（FindSaltlick / AnchorToSaltlick）—— 缓存+失效校验范式
--         2) 恐慌系列（PanicTrigger / PanicWhenScared）—— 惊吓时间轴与状态翻转记忆器
--         3) 帮工策略表（AssistLeaderDefaults）—— Starter/KeepGoing/FindNew 三钩子
--         4) 捡拾与交付（NodeAssistLeaderPickUps）—— 软锁互斥 + 两阶段优先级
--         5) WX78 附身机甲（PossessChassisNode）
-- 关键符号：AssistLeaderDefaults, NodeAssistLeaderDoAction,
--           NodeAssistLeaderPickUps, PanicWhenScared, PanicTrigger,
--           ShouldTriggerPanic, ElectricFencePanicTrigger, PossessChassisNode,
--           AnchorToSaltlick, FindTillPosition
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：brain.lua（三段式大脑运行时机制，本文件是其节点层实现）,
--           behaviours/（29 个原子决策节点，本文件的原料）,
--           behaviours/chattynode.lua, behaviours/panic.lua, behaviours/leash.lua,
--           components/follower.lua, components/trader.lua, components/eater.lua
--============================================================
require "behaviours/wander"
--[ [
-- braincommon.lua —— 全DST 大脑共用的「行为节点工厂库」
--
-- ★ 定位：这不是某只生物的大脑，而是 brains/ 目录下 191 个大脑文件的公共底座。
--   几乎每个 xxxbrain.lua 的第 10-15 行都是 require "brains/braincommon"。
--   它导出的不是节点实例，而是【造节点的函数】——传 inst 进去，返回一棵行为树子树。
--
-- 【与 brain.lua 的分工】
--   brain.lua   —— 大脑的「运行时机制」：三段式状态集合、双缓冲迭代、休眠协作。
--   behaviours/ —— 29 个「决策节点」的原子实现（Wander / Follow / RunAway ...）。
--   braincommon.lua —— 把原子节点按「通用需求」组装成可复用的复合子树。
--   xxxbrain.lua   —— 具体生物的「组装实例」，声明自己的优先级与条件。
--
-- 【★ 最重要的三件事】
-- 1) 全文件只用两个组合器就能表达一切：
--    WhileNode(条件, 名字, 子树)  —— 「只要条件成立就一直跑子树」
--    PriorityNode({...}, 间隔)    —— 「按数组顺序逐个试，第一个成功的赢」
--    ★ 排列顺序即优先级，这是整个 DST AI 唯一真正的「控制流」。
-- 2) 事件注册/注销成对出现，且都用「猴子补丁」包一层 OnStop：
--    典型如 AnchorToSaltlick（第 67-76 行）、PanicWhenScared（第 170-176 行）。
--    这是节点级资源的标准清理手法，比组件级 OnRemoveFromEntity 更贴近节点生命周期。
-- 3) AssistLeaderDefaults（第 287-407 行）是「跟随者帮工」的策略表：
--    每个动作（MINE/CHOP/DIG/TILL）都有 Starter / KeepGoing / FindNew 三个钩子。
--    ★ 这个「三钩子」结构是全DST 跟随 AI 的通用范式，值得整段照抄。
--
-- 【⚠️ 容易踩的坑】
-- · 本文件被 191 个大脑共享，任何改动都是全局行为变更，改动成本极高。
-- · 大量函数直接假定 inst 挂了 follower / combat / inventory 组件，
--   没有做 nil 检查 —— 调用方（具体大脑）必须保证组件存在，否则运行时崩。
-- · FindTillPosition（第 248 行）、NodeAssistLeaderPickUps（第 565 行）
--   里用 inst.digtile、parameters.xxx 把「跨帧记忆」挂在实体上，
--   这是 DST 的通用手法（实体即状态容器），但意味着脑与实体强耦合。
--] ]
require "behaviours/panic"

local BrainCommon = {}
--------------------------------------------------------------------------

local TIME_TO_SEEK_SALT = 16
-- 舔盐的时间阈值（秒）。盐渍猪的盐有保质期，剩余时间越少越急着去舔。
-- ★ 这个数字是「提前量」：不是「盐要过期了才去」，而是「还剩 16 秒就出发」，
--   因为跑过去 + 舔完需要时间。这是一个很容易被忽略的「提前行动」设计。

local function OnSaltlickPlaced(inst)
-- 盐渍被吃掉时清掉缓存。
-- ★ 注意它用的是 inst:RemoveEventCallback 而不是在 OnStop 里统一清 ——
--   因为这个事件监听的生命周期独立于节点（AnchorToSaltlick 启停都可能重建它）。
    inst._brainsaltlick = nil
    inst:RemoveEventCallback("saltlick_placed", OnSaltlickPlaced)
end

local FINDSALTLICK_MUST_TAGS = { "saltlick" }
-- 索敌标签表。注意语义：MUST_TAGS 是「必须全部具备」，CANT_TAGS 是「一个都不能有」。
-- INLIMBO —— 正在加载/卸载，加载中的实体不可交互
-- fire / burnt —— 会烧掉或已烧毁的盐渍不值得去舔
local FINDSALTLICK_CANT_TAGS = { "INLIMBO", "fire", "burnt" }

local function FindSaltlick(inst)
-- ★ FindSaltlick 的关键设计：不是每次都重新搜，而是「条件性重搜」。
-- 第 18-23 行是一个 OR 起来的大条件，只要全部不成立才不进 if，即：
--   缓存为空 / 缓存已失效 / 自己没盐渍 tag / 缓存进入 limbo /
--   缓存正在燃烧 / 缓存已烧毁 —— 任意一条成立就重搜。
-- ★ 这就是「缓存 + 失效条件」的教科书写法：DST 里凡是反复 FindEntity 的地方
--   基本都是这个形状，因为 FindEntity 涉及空间查询，是这里的性能热点。
-- 第 24 行 hadsaltlick 记录「重搜前是否有缓存」，用来决定事件监听的挂/摘。
-- ⚠️ 事件注册条件是「从无到有」（第 27 行 not hadsaltlick），而不是每次都注册。
--   若写成每次都 ListenForEvent，会在同一个实体上注册多个回调 —— 重复触发。
    if inst._brainsaltlick == nil or
        not inst._brainsaltlick:IsValid() or
        not inst:HasTag("saltlick") or
        inst._brainsaltlick:IsInLimbo() or
        (inst._brainsaltlick.components.burnable ~= nil and inst._brainsaltlick.components.burnable:IsBurning()) or
        inst._brainsaltlick:HasTag("burnt") then
        local hadsaltlick = inst._brainsaltlick ~= nil
        inst._brainsaltlick = FindEntity(inst, TUNING.SALTLICK_CHECK_DIST, nil, FINDSALTLICK_MUST_TAGS, FINDSALTLICK_CANT_TAGS)
-- 真正的空间查询。FindEntity 是 DST 的通用空间检索，
-- ★ 参数顺序：inst, 半径, 额外过滤函数, MUST_TAGS, CANT_TAGS（, ONE_OF_TAGS）。
--   注意 TheSim:FindEntities 是另一个函数，参数顺序不同（x,y,z,半径,...），
--   两者在本文件里混用（第 230、503 行 vs 第 25 行），移植时极易搞错。
        if inst._brainsaltlick ~= nil then
            if not hadsaltlick then
                inst:ListenForEvent("saltlick_placed", OnSaltlickPlaced)
            end
        elseif hadsaltlick then
            inst:RemoveEventCallback("saltlick_placed", OnSaltlickPlaced)
        end
    end
    return inst._brainsaltlick ~= nil
end

local function WanderFromSaltlickDistFn(inst)
-- ★ WanderFromSaltlickDistFn：让「距盐渍的距离」随剩余时间收紧。
--   盐渍还剩 16 秒 → 在 CHECK_DIST*0.75 处晃荡
--   盐渍还剩  8 秒 → 距离线性收紧到 USE_DIST*0.75
-- 这是「渐进逼近」手法：不用专门的「走向目标」节点，靠调大 Wander 的半径收敛。
-- 第 41 行 Remap 把 [8,16] 映射到 [USE_DIST*.75, CHECK_DIST*.75]，
-- ⚠️ Remap 的四参分别是 (值, 旧下界, 旧上界, 新下界, 新上界)，共 5 个参数。
-- 第 38 行 GetTimeLeft 返回 nil 时用 or 0 兜底 —— 此时 t=0 会让结果落在映射区外，
--   所以第 42 行的 or 分支（无定时器时用最大距离）是必要的防御。
    local t = inst.components.timer ~= nil and (inst.components.timer:GetTimeLeft("salt") or 0) or nil
    return t ~= nil
        and t < TIME_TO_SEEK_SALT
        and Remap(math.max(TIME_TO_SEEK_SALT * .5, t), TIME_TO_SEEK_SALT * .5, TIME_TO_SEEK_SALT, TUNING.SALTLICK_USE_DIST * .75, TUNING.SALTLICK_CHECK_DIST * .75)
        or TUNING.SALTLICK_CHECK_DIST * .75
end

local function ShouldSeekSalt(inst)
-- ShouldSeekSalt：有目标盐渍 + 有定时器 + 剩余时间不足。三个条件缺一不可。
    return inst._brainsaltlick ~= nil
        and inst.components.timer ~= nil
        and (inst.components.timer:GetTimeLeft("salt") or 0) < TIME_TO_SEEK_SALT
end

local function AnchorToSaltlick(inst)
-- ★ AnchorToSaltlick：WhileNode + Wander 的组合，节点被反复进出。
-- 第 52 行 WhileNode 条件里调 FindSaltlick —— ★ 条件函数带副作用是这里的刻意的：
--   每帧重新校验缓存，「缓存失效」这个时机和「进入节点」自动同步。
--   代价是条件函数不再是纯函数，读代码时容易误判它只是判断。
-- 第 61 行 GetPosition() 或 inst:GetPosition() 的兜底：目标没了就原地站。
    local node = WhileNode(
        function()
            return FindSaltlick(inst)
        end,
        "Stay Near Salt",
        Wander(inst,
            function()
                return inst._brainsaltlick ~= nil
                    and inst._brainsaltlick:IsValid()
                    and inst._brainsaltlick:GetPosition()
                    or inst:GetPosition()
            end,
            WanderFromSaltlickDistFn)
    )

    local _OnStop = node.OnStop
-- ★★ 「猴子补丁 OnStop」—— 本文件最值得学的一段。
-- 手法：先存下原 OnStop，再用自己的函数替换它，替换后的函数里
--   (1) 做本节点自己的清理（摘事件监听、清缓存）
--   (2) 再回调原 OnStep/OnStop（如果存在）
-- 为什么必须这样写：WhileNode 内部的 Panic/Wander 节点是别人的实例，
--   你不能直接改它们的 OnStop（那是共享对象，改了会污染所有使用者）。
-- ★ 这就是「不修改共享节点，只在本节点外面包一层」的标准解法。
-- ⚠️ 漏掉第 74 行 _OnStop(node) 的回调，就会破坏被包装节点原有的退出清理。
-- ⚠️ 另一个坑：这里只回调 OnStop，没回调 OnStart。若被包装节点在 OnStart 里
--   也注册了资源，本文件没有对应的 OnStart 补丁 —— 属于不对称清理，
--   本文件里的 Panic/Wander 恰好不依赖 OnStart，所以现状是安全的，但很脆弱。
    node.OnStop = function()
        if inst._brainsaltlick ~= nil then
            inst:RemoveEventCallback("saltlick_placed", OnSaltlickPlaced)
            inst._brainsaltlick = nil
        end
        if _OnStop ~= nil then
            _OnStop(node)
        end
    end

    return node
end

BrainCommon.ShouldSeekSalt = ShouldSeekSalt
BrainCommon.AnchorToSaltlick = AnchorToSaltlick

--------------------------------------------------------------------------

local function ShouldTriggerPanic(inst)
-- ★ ShouldTriggerPanic：恐慌的触发条件是「三个独立来源的 OR」。
--   health.takingfiredamage —— 正在受火焰伤害
--   health:GetLunarBurnFlags() ~= 0 —— 月亮灼烧（月亮石机制，独立于火焰）
--   hauntable.panic —— 被鬼附身/hauntable 组件强制恐慌
-- ★ 移植价值：把「什么情况下该慌」集中成一个纯函数，而不是散落在各个节点里。
-- ⚠️ 该函数没有末尾 return，隐式返回 nil（或原函数的返回值）。
--   在 Lua 里 nil 为假，所以调用方用它当条件是对的，**不是缺陷**。
-- ⚠️ 但第 87-88 行混用了空格与 Tab 缩进，属风格问题（SOP 坑 6 的同类），Lua 不 care。
	return (inst.components.health and (inst.components.health.takingfiredamage or inst.components.health:GetLunarBurnFlags() ~= 0))
		or (inst.components.hauntable ~= nil and inst.components.hauntable.panic)
end

BrainCommon.ShouldTriggerPanic = ShouldTriggerPanic
BrainCommon.PanicTrigger = function(inst)
-- 把「恐慌」包装成一个独立节点工厂，暴露给所有大脑调用。
-- ★ 这是 braincommon 的核心价值主张：把「条件 + 动作」的配对固化，
--   调用方只需一行 BrainCommon.PanicTrigger(inst) 就得到完整子树。
-- 参数条件在 WhileNode 里，所以每帧重新求值 —— 火焰停了会自动退出恐慌。
    return WhileNode(function() return ShouldTriggerPanic(inst) end, "PanicTrigger", Panic(inst))
end

--------------------------------------------------------------------------

require("behaviours/avoidelectricfence")
local function ShouldAvoidElectricFence(inst)
-- 电栅栏恐慌。条件是 prefab/buff 设置的 inst.panic_electric_field 字段。
-- ★ 这是「外部注入条件」的典型：大脑自己不判断电击，
--   而是由电栅栏组件在触发时打标记，大脑只负责读标记。
-- 好处是判定逻辑集中在施加伤害的那一侧，避免每个生物重复实现「我被电了吗」。
    return inst.panic_electric_field ~= nil
end

BrainCommon.ShouldAvoidElectricFence = ShouldAvoidElectricFence
BrainCommon.ElectricFencePanicTrigger = function(inst)
    return WhileNode(function() return ShouldAvoidElectricFence(inst) end, "ElectricShock", AvoidElectricFence(inst))
end

BrainCommon.HasElectricFencePanicTriggerNode = function(inst)
-- 反查接口：节点是否真的在跑。注释明说这个标志由 AvoidElectricFence 节点自己设置。
-- ⚠️ 跨文件隐式契约：braincommon 读一个由 behaviours/ 节点写入的私有字段。
--   仿写时务必把这类「谁写谁读」写清楚，否则改 behaviours/ 就会静默破坏 brains/。
    return inst._has_electric_fence_panic_trigger --Set in AvoidElectricFence
end

--------------------------------------------------------------------------

local function ShouldTriggerPanicShadowCreature(inst)
-- 影子生物专属恐慌。同样是「外部打标记，大脑只读」。
-- ⚠️ 第 115 行源码自带的 TODO 承认这是临时方案：标记由
--   hermitcrabtea_moon_tree_blossom_buff 设置，注释原文建议扩展成更好的系统。
--   这是原作者留的技术债标注，不是我们的判断。
    return inst._shadow_creature_panic_task ~= nil -- Set by hermitcrabtea_moon_tree_blossom_buff. Expand this to a better system if we do more with panicking shadow creatures
end

BrainCommon.ShouldTriggerPanicShadowCreature = ShouldTriggerPanicShadowCreature
BrainCommon.PanicTriggerShadowCreature = function(inst)
    return WhileNode(function() return ShouldTriggerPanicShadowCreature(inst) end, "PanicTriggerShadowCreature", Panic(inst))
end

--------------------------------------------------------------------------

local function PanicWhenScared(inst, loseloyaltychance, chatty)
-- ★★ PanicWhenScared —— 全文件逻辑最密的一个工厂函数。
--
-- 【它解决的问题】被「epicscare」（大吓人事件）惊吓后：
--   1) 恐慌逃跑，且可选地喊台词（chatty）
--   2) 可选地「吓掉忠诚」—— 跟随者可能因此脱离主人（第 138-153 行）
--   3) 惊吓期间主动放弃战斗目标（第 155-168 行）
--
-- 【★ scareendtime 的时间轴设计（第 126-129 行）】
--   这是一个「取最大值而非累加」的时间戳合并：
--   多个 epicscare 事件可能重叠，data.duration + GetTime() + math.random()
--   取 max 意味着「最后一次惊吓结束的时刻」，而不是「惊吓总时长」。
--   ⚠️ 加 math.random() 是为了避免多只猪同时被吓时结束时间完全相同，
--   否则它们会同时结束恐慌、同时开始做下一件事，行为看起来很机械。
--
-- 【★ 第 155-168 行的 scared 变量是个记忆器】
--   条件函数里比较「当前是否在惊吓中」与「上次认为是否在惊吓」，
--   仅在【状态翻转】的那一刻执行副作用（放弃战斗目标），而不是每帧都放弃。
-- ⚠️ 这是本函数最精妙也最容易写错的地方：如果只写 if GetTime() < scareendtime then GiveUp() end，
--   会在惊吓的每一帧反复调 GiveUp，虽不致命但浪费，且会打断其他战斗逻辑。
    local scareendtime = 0
    local function onepicscarefn(inst, data)
        scareendtime = math.max(scareendtime, data.duration + GetTime() + math.random())
    end
    inst:ListenForEvent("epicscare", onepicscarefn)
-- 注册 epicscare 监听。注意用的是 inst:ListenForEvent（实体级），
-- 事件来源由调用方决定，与 inst 无关 —— 即「不管谁吓的，我都要反应」。

    local panicscarednode = Panic(inst)

    if chatty ~= nil then
-- 可选台词：把恐慌子树包一层 ChattyNode，让它带语音/气泡。
        panicscarednode = ChattyNode(inst, chatty, panicscarednode)
    end

    if loseloyaltychance ~= nil and loseloyaltychance > 0 then
-- ★ 吓掉忠诚的分支（第 138-153 行）。设计上很讲究：
-- 用 ParallelNode 而不是 SequenceNode —— 一边恐慌，一边并行地每 3 秒抽一次签。
-- 若用 SequenceNode，签检会排在恐慌后面，恐慌不结束就永远抽不到签。
-- 第 146 行 GetLoyaltyPercent() > 0 是前置门：已经没忠诚的不用再抽。
-- 第 147 行 TryLuckRoll(leader, chance, 公式id) —— 把「是否失去忠诚」交给
--   幸运值系统统一裁决，因此不同幸运值的玩家被吓后的表现会不同。
        panicscarednode = ParallelNode{
            panicscarednode,
            LoopNode({
                WaitNode(3),
                ActionNode(function()
                    local leader = inst.components.follower ~= nil and inst.components.follower:GetLeader() or nil
-- ⚠️ 这里连取 leader 都要判两次（短路：leader ~= nil and ... 里的 hasLeader 局部变量），
--   因为 GetLoyaltyPercent() 若在无 leader 时调用可能出错。防御式写法，值得学。
                    if leader ~= nil and
                        inst.components.follower:GetLoyaltyPercent() > 0 and
                        TryLuckRoll(leader, loseloyaltychance, LuckFormulas.LoseFollowerOnPanic) then
                        inst.components.follower:SetLeader(nil)
                    end
                end),
            }),
        }
    end

    local scared = false
    panicscarednode = WhileNode(
        function()
            if (GetTime() < scareendtime) ~= scared then
                if inst.components.combat ~= nil then
                    inst.components.combat:SetTarget(nil)
                end
                scared = not scared
            end
            return scared
        end,
        "PanicScared",
        panicscarednode
    )

    local _OnStop = panicscarednode.OnStop
    panicscarednode.OnStop = function()
        inst:RemoveEventCallback("epicscare", onepicscarefn)
        if _OnStop ~= nil then
            _OnStop(panicscarednode)
        end
    end

    return panicscarednode
end

BrainCommon.PanicWhenScared = PanicWhenScared

--------------------------------------------------------------------------

local function IsUnderIpecacsyrupEffect(inst)
    return inst:HasDebuff("ipecacsyrup_buff")
end

BrainCommon.IsUnderIpecacsyrupEffect = IsUnderIpecacsyrupEffect
BrainCommon.IpecacsyrupPanicTrigger = function(inst)
    return WhileNode(function() return BrainCommon.IsUnderIpecacsyrupEffect(inst) end, "IpecacsyrupPanicTrigger", Panic(inst))
end

--------------------------------------------------------------------------
-- Actions: MINE, CHOP, DIG, TILL
-- 以下进入「帮工动作」的标签表。MINE/CHOP/DIG/TILL 四种动作共用一批排除标签。
-- ★ 三个 CANT_TAGS 完全相同，说明「不可被采集」的理由对四动作是一致的：
--   carnivalgame_part —— 嘉年华小游戏的道具，偷了会破坏玩法
--   event_trigger     —— 剧情触发器，交互会卡死剧情
--   waxedplant        —— 上蜡的植物（不能采集，否则破坏蜡覆层机制）
-- ⚠️ 这三条是「玩法保护」而非「物理不可达」。移植时容易漏掉最后一类。

local MINE_TAGS = { "MINE_workable" }
local MINE_CANT_TAGS = { "carnivalgame_part", "event_trigger", "waxedplant" }
local CHOP_TAGS = { "CHOP_workable" }
local CHOP_CANT_TAGS = { "carnivalgame_part", "event_trigger", "waxedplant" }
local DIG_ONEOF_TAGS = { "farm_debris", "tree" }
-- DIG 用的是 ONE_OF_TAGS 语义：「farm_debris 或 tree 之一即可」。
-- ⚠️ 与 MINE/CHOP 的 MUST 语义不同。作者第 224 行注释说明了原因：
--   「我们把树也算进来，所以要确认它是可挖的树桩」，靠 IsDigValid 二次筛。
-- 这就是 ONE_OF 与 MUST 的正确用法：先用便宜的标签粗筛，再用贵的函数细筛。
local DIG_CANT_TAGS = { "carnivalgame_part", "event_trigger", "waxedplant" }
local SOILMUST = { "soil" }
local SOILMUSTNOT = { "merm_soil_blocker", "farm_debris", "NOBLOCK" }

--------------------------------

local function GetLeader(inst)
    return inst.components.follower and inst.components.follower:GetLeader()
end

--------------------------------

local function IsDeciduousTreeMonster(guy)
    return guy.monster and guy.prefab == "deciduoustree"
end

local function FindDeciduousTreeMonster(inst, finddist)
    return FindEntity(inst, finddist / 3, IsDeciduousTreeMonster, CHOP_TAGS)
end

--------------------------------

local function IsDigValid(guy, inst) -- we include trees, so make sure it's a diggable tree (i.e. stump)
    return guy.components.workable ~= nil and guy.components.workable:GetWorkAction() == ACTIONS.DIG
end

local function CollectTillSites(inst, digsites, tile)
-- CollectTillSites：围绕一个 tile 找可以耕种的格。
-- ⚠️ 第 232 行 #soils < 9 是「这个格子里的土不够多就放弃」—— 防止玩家在
--   已挖得稀烂的地上反复找到同一批位置。注意这里只统计半径 2 内的 soil 实体。
-- 第 233-237 行用一个奇特的循环：dist=4/3，for dx=-4/3, 4/3, 4/3 只跑 dx=0；
--   dz 同理只跑 0。★ 也就是说当前实现只在格子正中心取样一个点。
-- ⚠️ 疑似：作者可能原意是 3x3 取样（步长 4/3 ≈ 1.333，起点写错），
--   但也可能是刻意只要中心点。已对照第 234/236 行字面确认循环体只执行一次，
--   属于「写法可疑但不能断定是 bug」，故标为疑似，不下定论。
-- 第 238 行 CanTillSoilAtPoint 才是真正的合法性判定（地图层面能否耕）。
    local cent = Vector3(TheWorld.Map:GetTileCenterPoint(tile[1], 0, tile[2]))
    local soils = TheSim:FindEntities(cent.x, 0, cent.z, 2, SOILMUST, SOILMUSTNOT)

    if #soils < 9 then
        local dist = 4/3
        for dx=-dist,dist,dist do
            local dobreak = false
            for dz=-dist,dist,dist do
                local localsoils = TheSim:FindEntities(cent.x+dx,0, cent.z+dz, 0.21, SOILMUST, SOILMUSTNOT)
                if #localsoils < 1 and TheWorld.Map:CanTillSoilAtPoint(cent.x+dx,0,cent.z+dz) then
                    table.insert(digsites,{pos = Vector3(cent.x+dx,0,cent.z+dz), tile = tile })
                end
            end
        end
    end

    return digsites
end

local function FindTillPosition(inst)
-- ★ FindTillPosition 的两级策略：
--   有 inst.digtile（上次定的目标）→ 只看那一个格子
--   没有 → 扫 9x9 个采样点（步长 4，实际覆盖 36x36 单位）找 FARMING_SOIL
-- 第 277-278 行 ★ 有一个真实的小缺陷：连续两次 math.random(1,#digsites)，
--   分别取 .pos 和 .tile，两次独立随机 → 可能返回 A 点的位置配 B 点的 tile。
--   已逐字核对第 277、278 行确认是两次独立调用。
-- ⚠️ 影响有限（digsites 常常只有 1-2 个候选），但属真实的实现瑕疵，非笔误级别。
--   inst.digtile 后续只用于「下次只看这个格子」，所以错配的后果是轻微的。
    local tiles = {}

    if not inst.digtile then
        -- collect garden tiles in a 9x9 grid
        local RANGE = 4
        local pos = Vector3(inst.Transform:GetWorldPosition())

        for x=-RANGE,RANGE,1 do
            for z=-RANGE,RANGE,1 do
                local tx = pos.x + (x*4)
                local tz = pos.z + (z*4)
                local tile = TheWorld.Map:GetTileAtPoint(tx, 0, tz)
                if tile == WORLD_TILES.FARMING_SOIL then
                    table.insert(tiles,{tx,tz})
                end
            end
        end
    else
        table.insert(tiles,inst.digtile)
    end

    -- find diggable places in those tiles.
    local digsites = {}
    for i,tile in ipairs(tiles)do
        digsites = CollectTillSites(inst,digsites, tile)
    end

    if #digsites > 0 then
        local pos = digsites[math.random(1,#digsites)].pos
        inst.digtile = digsites[math.random(1,#digsites)].tile
        return pos
    end

    inst.digtile = nil
end

-----------

local AssistLeaderDefaults = {
-- ★★★ 全文件最值得整段照抄的结构：跟随者帮工的「三钩子」策略表。
--
-- 【为什么是三个钩子而不是一个】帮工行为有三段截然不同的判断，
-- 分别对应三段式大脑的不同阶段，混在一起写必然纠缠：
--   Starter   —— 「要不要开始」      → 进入 SCHEDULE 阶段时求值一次
--   KeepGoing —— 「要不要继续」      → DISTANCE 阶段每帧求值（节点还在跑时）
--   FindNew   —— 「具体做什么」      → HEALTH 阶段调用，返回 BufferedAction
--
-- 【四个动作的差异只在数据，不在结构】
--   MINE —— 最简单，无缓存目标
--   CHOP —— 有 inst.tree_target 缓存，且能「偷」跟随者已选好的树（第 340-345 行）
--   DIG  —— 有 inst.stump_target 缓存，额外用 IsDigValid 校验
--   TILL —— 特殊：不用 FindEntity，而是 FindTillPosition 返回坐标，
--           再 SpawnPrefab 一个 merm_soil_marker（第 401 行）当视觉标记
--           ★ 这种「AI 决策顺手发一个特效实体」的做法很 DST：
--             决策与表现的耦合放在最内层，外层调用者完全不需要知道。
--
-- 【★ 所有 FindNew 的统一两段式搜索】
--   先以 inst 为中心找，找不到再以 leader 为中心找（第 300-305、332-337、369-374 行）。
--   ★ 意义：帮工能捡到「主人身边但自己够不着」的东西，同时不会跑太远。
--     这是「以谁为中心」这个参数化设计的典型收益。
--
-- 【本表被导出为 BrainCommon.AssistLeaderDefaults（第 409 行）】
-- 注释原文写 "Mod support access" —— ★ 模组可以替换这张表里的钩子来改写帮工 AI，
--   而不必复制整个 NodeAssistLeaderDoAction。这是很干净的扩展点。
    MINE = {
        Starter = function(inst, leaderdist, finddist)
-- MINE.Starter：看主人状态图是否带 mining 标签。
-- ★ 用 sg:HasStateTag 而不是直接问「主人是否在挖矿」，是 DST 状态图的通用解耦手法：
--   大脑不需要知道状态图里状态叫什么名字，只认标签。改状态图名不会破坏大脑。
-- 第 291 行连 leader.sg 都要判非空 —— 因为 sg 可能尚未初始化。
            local leader = GetLeader(inst)
            return leader ~= nil and leader.sg ~= nil and leader.sg:HasStateTag("mining")
        end,
        KeepGoing = function(inst, leaderdist, finddist)
-- MINE.KeepGoing：只要还在主人附近就继续挖。
-- ⚠️ 注意与 FindNew 的距离参数不同：KeepGoing 用 leaderdist（KEEP_CHOPPING_DIST=10），
--   FindNew 用 finder_finddist（SEE_TREE_DIST=15）。
--   ★ 这是有意的不对称：「继续」的条件比「重新找」的半径更小，
--   形成迟滞（hysteresis），避免在边界反复开工/收工。
            local leader = GetLeader(inst)
            return leader ~= nil and inst:IsNear(leader, leaderdist)
        end,
        FindNew = function(inst, leaderdist, finddist)
            local target = FindEntity(inst, finddist, nil, MINE_TAGS, MINE_CANT_TAGS)

            if target == nil then
                local leader = GetLeader(inst)
                if leader then
                    target = FindEntity(leader, finddist, nil, MINE_TAGS, MINE_CANT_TAGS)
                end
            end

            if target ~= nil then
                return BufferedAction(inst, target, ACTIONS.MINE)
            end
        end,
    },
    CHOP = {
-- CHOP 的三个钩子。★ 三者开头都有 if inst.tree_target ~= nil then return true end，
--   即「缓存目标存在时无条件继续」，把稳定性判断外包给缓存层。
        Starter = function(inst, finddist)
            if inst.tree_target ~= nil then
                return true
            end
            local leader = GetLeader(inst)
            return (leader ~= nil and leader.sg ~= nil and leader.sg:HasAnyStateTag("chopping", "spinning"))
-- ★ CHOP.Starter 里额外查 FindDeciduousTreeMonster —— 会走的树怪也要砍。
--   这是「目标类型扩展」的例子：主线需求（树）之外补一个特殊需求（树怪）。
                or FindDeciduousTreeMonster(inst, finddist) ~= nil
        end,
        KeepGoing = function(inst, leaderdist, finddist)
            if inst.tree_target ~= nil then
                return true
            end
            local leader = GetLeader(inst)
            return (leader ~= nil and inst:IsNear(leader, leaderdist))
                or FindDeciduousTreeMonster(inst, finddist) ~= nil
        end,
        FindNew = function(inst, leaderdist, finddist)
            local target = FindEntity(inst, finddist, nil, CHOP_TAGS, CHOP_CANT_TAGS)

            if target == nil then
                local leader = GetLeader(inst)
                if leader then
                    target = FindEntity(leader, finddist, nil, CHOP_TAGS, CHOP_CANT_TAGS)
                end
            end

            if target ~= nil then
                if inst.tree_target ~= nil then
-- ★ CHOP.FindNew 的「目标窃取」逻辑（第 340-345 行）：
--   若 inst.tree_target 已被预先指定（由外部/状态图设置），直接用它并清空缓存；
--   否则优先砍树怪。
-- 设计意图：状态图可以在更上层决定「这棵树归我砍」，大脑只负责执行。
                    target = inst.tree_target
                    inst.tree_target = nil
                else
                    target = FindDeciduousTreeMonster(inst, finddist) or target
                end

                return BufferedAction(inst, target, ACTIONS.CHOP)
            end
        end,
    },
    DIG = {
        Starter = function(inst, finddist)
            if inst.stump_target ~= nil then
                return true
            end
            local leader = GetLeader(inst)
            return (leader ~= nil and leader.sg ~= nil and leader.sg:HasStateTag("digging"))
        end,
        KeepGoing = function(inst, leaderdist, finddist)
            if inst.stump_target then
                return true
            end
            local leader = GetLeader(inst)
            return leader ~= nil and inst:IsNear(leader, leaderdist)
        end,
        FindNew = function(inst, leaderdist, finddist)
            local target = FindEntity(inst, finddist, IsDigValid, nil, DIG_CANT_TAGS, DIG_ONEOF_TAGS)

            if target == nil then
                local leader = GetLeader(inst)
                if leader then
                    target = FindEntity(leader, finddist, IsDigValid, nil, DIG_CANT_TAGS, DIG_ONEOF_TAGS)
                end
            end

            if target ~= nil then
                if inst.stump_target ~= nil then
                    target = inst.stump_target
                    inst.stump_target = nil
                end

                return BufferedAction(inst, target, ACTIONS.DIG)
            end
        end,
    },
    TILL = {
        Starter = function(inst, finddist)
            local leader = GetLeader(inst)
            return (leader ~= nil and leader.sg ~= nil and leader.sg:HasStateTag("tilling"))
        end,
        KeepGoing = function(inst, leaderdist, finddist)
            local leader = GetLeader(inst)
            return leader ~= nil and inst:IsNear(leader, leaderdist)
        end,
        FindNew = function(inst, leaderdist, finddist)
            local pos = FindTillPosition(inst)
            local tool = inst.components.inventory ~= nil and inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HANDS) or nil
            if pos then
                pos = Vector3(pos.x -0.02 + math.random()*0.04,0,pos.z -0.02 + math.random()*0.04)

                local marker = SpawnPrefab("merm_soil_marker")
                marker.Transform:SetPosition(pos.x, pos.y, pos.z)
                return BufferedAction(inst, nil, ACTIONS.TILL, tool, pos)
            end
        end,
    },
}
-- Mod support access.
BrainCommon.AssistLeaderDefaults = AssistLeaderDefaults

-- NOTES(JBK): This helps followers do a task once they see the leader is doing an act.
-- 源码作者原注释：这套机制是让跟随者「看到主人做某动作后跟着做一次」。
-- ★ 关键设计：动作是高度上下文相关的（挖矿要矿，砍树要树，耕地要土），
--   所以 Starter/KeepGoing/FindNew 各动作一套 —— 见上面的 AssistLeaderDefaults。
--   注释明确说 "defaults above to help clarify context"。
--            Since actions are very context sensitive, there are defaults above to help clarify context.
local function NodeAssistLeaderDoAction(self, parameters)
-- ★★ NodeAssistLeaderDoAction 的「可覆盖」设计：
-- 第 417-419 行 —— parameters.starter or defaults.Starter
--   ★ 模组可以只覆盖其中一两个钩子，其余走默认。这是「策略表的策略表」。
-- ⚠️ 前提是 parameters.action 必须命中 defaults（AssistLeaderDefaults[action]）。
--   第 415 行 AssistLeaderDefaults[action] 若 action 是未知值 → defaults 为 nil，
--   第 417 行 parameters.starter or defaults.Starter 就会在 defaults 为 nil 时崩。
-- ⚠️ 属「隐式契约」：调用方必须传合法 action（MINE/CHOP/DIG/TILL）。
--   本文件内部 4 处调用都合法（第 470、476、481、486 行），已逐一核对。
    local action = parameters.action
    local defaults = AssistLeaderDefaults[action]

    local starter = parameters.starter or defaults.Starter
    local keepgoing = parameters.keepgoing or defaults.KeepGoing
    local finder = parameters.finder or defaults.FindNew

    local keepgoing_leaderdist = parameters.keepgoing_leaderdist or TUNING.FOLLOWER_HELP_LEADERDIST
-- 两个距离参数的默认值。所有大脑共用同一套跟随者帮工距离手感。
    local finder_finddist = parameters.finder_finddist or TUNING.FOLLOWER_HELP_FINDDIST

    local function ifnode()
-- 三个匿名条件函数，把「钩子 + 距离参数」重新打包成节点需要的无参函数。
-- ★ 这层适配是必需的：钩子签名是 (inst, leaderdist, finddist)，
--   而节点的条件/动作回调签名是 () —— 适配层在此产生。
        return starter(self.inst, keepgoing_leaderdist, finder_finddist)
    end
    local function whilenode()
        return keepgoing(self.inst, keepgoing_leaderdist, finder_finddist)
    end
    local function findnode()
        return finder(self.inst, keepgoing_leaderdist, finder_finddist)
    end
    local looper
    if parameters.chatterstring then
-- ★ 有无台词走两条不同分支（第 434-438 行）：
--   有 chatterstring → LoopNode{ConditionNode(whilenode), ChattyNode(...DoAction...)}
--   无 chatterstring → LoopNode{ConditionNode(whilenode), DoAction(...)}
-- LoopNode = 无限循环；ConditionNode 只在条件为真时执行下一个节点。
-- ★ 结构含义：每轮循环先问「还该继续吗」，不该继续就整轮跳过（即退出）。
        looper = LoopNode{ConditionNode(whilenode), ChattyNode(self.inst, parameters.chatterstring, DoAction(self.inst, findnode, "DoAction_Chatty", parameters.shouldrun, 3))}
    else
        looper = LoopNode{ConditionNode(whilenode), DoAction(self.inst, findnode, "DoAction_NoChatty", parameters.shouldrun, 3)}
    end

    return IfThenDoWhileNode(ifnode, whilenode, action, looper)
-- IfThenDoWhileNode(if, while, name, do) —— 三段式大脑语义的一次性表达：
--   「若 if 成立，则在 while 成立期间反复执行 do」。
-- ★ 这是本文件与 brain.lua 机制最直接的对应：
--   brain.lua 的 SCHEDULE/DISTANCE/HEALTH 三段，就是这个模式的一般化版本。
--   读懂这一行，就理解了 DST 大脑的骨架。
end

BrainCommon.NodeAssistLeaderDoAction = NodeAssistLeaderDoAction

--------------------------------------------------------------------------
-- NOTES(JBK): This helps followers pickup items for a PLAYER leader.
-- 源码原注释：这个节点帮跟随者为【玩家】主人捡东西，捡到后交给主人，
-- 交不了（背包满/没开容器）就丢在地上。
--            They pickup if they are able to, then give them to their leader, or drop them onto the ground if unable to.

local function Unignore(inst, sometarget, ignorethese)
-- IgnoreThis / Unignore 的机制（第 449-460 行）：「软锁」。
-- 一次只允许一个 worker 盯住同一个物品，防止一群跟随者同时扑向同一个物品。
-- ★ 用 leader:DoTaskInTime(5, ...) 定 5 秒后自动解锁 —— 即使 worker 死了也不会永久锁死。
-- ★ 这是无状态环境下实现互斥的经典手法：没有锁表，就用「定时器到点自动释放」。
-- ⚠️ 缺陷风险：定时器挂在 leader 上，若 leader 在 5 秒内被卸载，锁永不释放。
--   不过该表是每次 OnStart 重建的局部变量（见各大脑调用处），影响有限。
    ignorethese[sometarget] = nil
end
local function IgnoreThis(sometarget, ignorethese, leader, worker)
    if ignorethese[sometarget] and ignorethese[sometarget].task ~= nil then
        ignorethese[sometarget].task:Cancel()
        ignorethese[sometarget].task = nil
    else
        ignorethese[sometarget] = {worker = worker,}
    end
    ignorethese[sometarget].task = leader:DoTaskInTime(5, Unignore, sometarget, ignorethese)
end

local function PickUpAction(inst, pickup_range, pickup_range_local, furthestfirst, positionoverride, ignorethese, wholestacks, allowpickables, custom_pickup_filter, itemoverridefn)
-- ★★ PickUpAction —— 参数极多（10 个），值得按「组」来读：
--   pickup_range / pickup_range_local  —— 两个搜索半径（见第 502-507 行）
--   furthestfirst                        —— 优先最远的还是最近的
--   positionoverride                     —— 搜索中心点（默认是 leader）
--   ignorethese                          —— 软锁表
--   wholestacks / allowpickables         —— 叠整堆 / 允许捡 bush 之类
--   custom_pickup_filter / itemoverridefn —— 两个完全自定义的逃生舱
--
-- 【第 463-473 行：先把手上的东西丢掉】
--   这是为了腾手。⚠️ 但注意它在任何参数检查之前就执行，
--   即「即使这一轮什么都不捡，也会先把 activeitem 丢掉」——
--   ⚠️ 疑似设计瑕疵：捡东西失败也会丢下手持物。已核对第 463-473 行确认无条件执行。
--   影响：手上有东西且附近没得捡时，手持物被丢弃。对 AI 而言损失很小，但语义上不对。
--
-- 【第 475-485 行：wholestacks 的两种含义】
--   true  → 只捡「背包里已有同类且没满」的那个物品（凑整堆），满了直接放弃
--   false → 背包满了直接放弃
-- ★ 两种都用了「早退返回 nil」，即「不行动」，而不是退而求其次去捡别的。
    local activeitem = inst.components.inventory:GetActiveItem()
    if activeitem ~= nil then
        inst.components.inventory:DropItem(activeitem, true, true)
        if ignorethese ~= nil then
            if ignorethese[activeitem] and ignorethese[activeitem].task ~= nil then
                ignorethese[activeitem].task:Cancel()
                ignorethese[activeitem].task = nil
            end
            ignorethese[activeitem] = nil
        end
    end
    local onlytheseprefabs
    if wholestacks then
        local item = inst.components.inventory:GetFirstItemInAnySlot()
        if item ~= nil then
            if (item.components.stackable == nil or item.components.stackable:IsFull()) then
                return nil
            end
            onlytheseprefabs = {[item.prefab] = true}
        end
    elseif inst.components.inventory:IsFull() then
        return nil
    end

    local leader = GetLeader(inst)
    if leader == nil then
        return nil
    end

    local container = leader.components.inventory or leader.components.container
-- ★★ 第 492-495 行是一个 ★ 真实的边界条件（不是缺陷，但极易踩）：
--   container == nil，或「主人有 inventory 但这个 container 没被主人打开」→ 返回 nil。
--   源码自己的注释：Inventory existing and it being opened so the action can work.
-- ★ 解读：物品必须能「通过主人的背包」转交，所以要求容器当前处于打开状态。
--   容器的 IsOpenedBy 才是真正的判据，inventory 只用来区分「是背包还是箱子」。
-- ⚠️ 移植要点：这一行同时用了 and / or / not 的混合短路，括号位置改变语义，
--   拆成两行更好读（对照第 528 行 mermbrain 里是同样写法）。
    if container == nil or (leader.components.inventory and not container:IsOpenedBy(leader)) then -- Inventory existing and it being opened so the action can work.
        return nil
    end

    local item, pickable
-- itemoverridefn 是「完全接管选品」的逃生舱；否则走标准的 FindPickupableItem。
-- 第 502-507 行 ★ 两段搜索：先小半径（range_local）再大半径（range）。
--   小半径优先 = 优先捡自己脚边的，减少乱跑。
-- ⚠️ 第 503 行传的 inst:GetPosition() 作为排除中心，
--   第 506 行传的 positionoverride —— 两者语义不同，注意别抄混。
    if itemoverridefn then
        item = itemoverridefn(inst, leader)
        pickable = item and item:HasTag("pickable") or nil
    else
        if pickup_range_local ~= nil then
            item, pickable = FindPickupableItem(leader, pickup_range_local, furthestfirst, inst:GetPosition(), ignorethese, onlytheseprefabs, allowpickables, inst, custom_pickup_filter)
        end
        if item == nil then
            item, pickable = FindPickupableItem(leader, pickup_range, furthestfirst, positionoverride, ignorethese, onlytheseprefabs, allowpickables, inst, custom_pickup_filter)
        end
    end
    if item == nil then
        return nil
    end

    if ignorethese ~= nil then
        IgnoreThis(item, ignorethese, leader, inst)
    end

    return BufferedAction(inst, item, item.components.trap ~= nil and ACTIONS.CHECKTRAP or pickable and ACTIONS.PICK or ACTIONS.PICKUP)
-- ★ 动作三分支：陷阱物品要「检查」，可摘的要「摘」，其余「捡」。
--   item.components.trap ~= nil and ACTIONS.CHECKTRAP
--   pickable and ACTIONS.PICK
--   ACTIONS.PICKUP
-- 语义：不能直接拿走的东西，先「检查」（拆陷阱）而不是硬拿。
end

local function GiveAction(inst)
-- GiveAction：把手上的东西给主人。
-- 第 523 行 ★ 注释明说 "intentionally backwards"：
--   先取 GetFirstItemInAnySlot 再取 GetActiveItem，
--   目的是「优先给最大的那堆」，而不是优先给手上拿的那个。
-- ⚠️ 这是有意为之，不是笔误 —— 作者专门写了注释。
-- 第 537-543 行 ★ 按主人类型三选一：
--   玩家 → GIVEALLTOPLAYER（直接给玩家，可能走联机 RPC）
--   有 trader 组件 → GIVE（摆上货架交易）
--   有 container → STORE（存进箱子）
--   都没有 → action 为 nil → 第 545 行早退。
-- ★ 这是「同一个意图，按对象类型分派到不同动作」的干净范例。
    local leader = GetLeader(inst)
    local container = leader and (leader.components.inventory or leader.components.container) or nil
    local item = inst.components.inventory:GetFirstItemInAnySlot() or inst.components.inventory:GetActiveItem() -- This is intentionally backwards to give the bigger stacks first.
    if leader == nil or item == nil then
        return nil
    end

    if container == nil or (leader.components.inventory and not container:IsOpenedBy(leader)) then -- Inventory existing and it being opened so the action can work.
        return nil
    end

    if container:CanAcceptCount(item, 1) <= 0 then
        return nil
    end

    local action
    if leader.isplayer then
        action = ACTIONS.GIVEALLTOPLAYER
    elseif leader.components.trader then
        action = ACTIONS.GIVE
    elseif leader.components.container then
        action = ACTIONS.STORE
    end

    if not action then
        return nil
    end

    return BufferedAction(inst, leader, action, item)
end

local function DropAction(inst)
-- DropAction：交不了就丢在地上。
-- 第 560 行 ba.options.wholestack = true —— 丢的是整堆而非一个。
-- ★ 第 559 行 BufferedAction(inst, leader, ...) 的第二个参数是「目标」而非接收者，
--   这里的语义是「对着主人丢下」；接收者其实是 item 参数（第 4 参）。
--   参数顺序容易看错，是 BufferedAction 最常见的误读点。
    local leader = GetLeader(inst)
    local item = inst.components.inventory:GetFirstItemInAnySlot()
    if leader == nil or item == nil then
        return nil
    end

    local ba = BufferedAction(inst, leader, ACTIONS.DROP, item)
    ba.options.wholestack = true
    return ba
end

local function AlwaysTrue() return true end
-- ★ AlwaysTrue 作为「无条件」的默认值 —— 全DST 大量使用这个惯用法。
--   比直接写 function() return true end 少一次函数分配，可读性也不差。
local function NodeAssistLeaderPickUps(self, parameters)
-- ★★ NodeAssistLeaderPickUps 的参数拆解（第 566-578 行）：
--   几乎全是 parameters.xxx 的透传，真正的逻辑在 PickUpAction/GiveAction 里。
-- 第 572-573 行 ★ 区分「函数型 positionoverride」与「值型 positionoverride」：
--   positionoverridefn（函数，每帧求值）与 positionoverride（静态值）。
-- ★ 这样设计是为了让「跟着主人走」的动态中心与「固定在出生点」的静态中心共存。
--   shadowwaxwellbrain 的 worker 就用函数型（第 384 行 positionoverride = GetSpawn），
--   而函数型还会被调用两次（第 581、600 行），★ 意味着 GetSpawn 被每帧求值多次，
--   移植时若 overridefn 有副作用会出问题 —— GetSpawn 是纯函数所以安全。
    local cond = parameters.cond or AlwaysTrue
    local pickup_range = parameters.range
    local pickup_range_local = parameters.range_local
	local give_cond = parameters.give_cond
	local give_range_sq = parameters.give_range ~= nil and parameters.give_range * parameters.give_range or nil
    local furthestfirst = parameters.furthestfirst
	local positionoverridefn = type(parameters.positionoverride) == "function" and parameters.positionoverride or nil
	local positionoverride = positionoverridefn == nil and parameters.positionoverride or nil
    local ignorethese = parameters.ignorethese
    local wholestacks = parameters.wholestacks
    local allowpickables = parameters.allowpickables
    local custom_pickup_filter = parameters.custom_pickup_filter
    local itemoverridefn = parameters.itemoverridefn

    local function CustomPickUpAction(inst)
-- 捡东西时挂成功/失败回调，推成实体事件对外广播。
-- ★ 这是「大脑内部状态 → 对外事件」的解耦出口：
--   prefab 或状态图可以 ListenForEvent("braincommon_pickup_success") 而不侵入大脑代码。
        local ba = PickUpAction(inst, pickup_range, pickup_range_local, furthestfirst, positionoverridefn ~= nil and positionoverridefn(inst) or positionoverride, ignorethese, wholestacks, allowpickables, custom_pickup_filter, itemoverridefn)
        if ba then
            ba:AddFailAction(function()
                inst:PushEvent("braincommon_pickup_failed", ba)
            end)
            ba:AddSuccessAction(function()
                inst:PushEvent("braincommon_pickup_success", ba)
            end)
        end
        return ba
    end

	local give_cond_fn = give_range_sq ~= nil and
-- ★ give_cond_fn 的三态合成（第 593-603 行），非常值得学：
--   有 give_range → 造一个闭包：先查 give_cond，再查与主人的距离是否在 give_range 内
--   没有 give_range → 直接用调用方给的 give_cond
--   都没有     → AlwaysTrue
-- ⚠️ 第 600 行 ★ 注意：闭包里 positionoverride 可能是 nil（第 573 行），
--   此时靠 `or self.inst:GetPosition()` 兜底到自己的位置。
--   但若传了 positionoverridefn 就取函数值 —— 又一次求值（第 600 行）。
-- ★ 这段是「参数化条件」的标准写法：把「多个可选条件」合成成一个统一签名。
		function()
            if give_cond and not give_cond() then
                return false
            end
            
            local leader = GetLeader(self.inst)
			return leader ~= nil and leader:GetDistanceSqToPoint(positionoverridefn ~= nil and positionoverridefn(self.inst) or positionoverride or self.inst:GetPosition()) < give_range_sq
		end
		or give_cond
		or AlwaysTrue

    return PriorityNode({
-- ★★ 最终结构（这是本函数的决策核心）：
--
--   PriorityNode({
--       WhileNode(cond,            "BC KeepPickup", DoAction(捡东西)),
--       WhileNode(give_cond_fn,    "BC Should Bring To Leader",
--           PriorityNode({ GiveAction, DropAction }, .25)),
--   }, .25)
--
-- 【两个阶段的优先级关系】
--   第一阶段（优先级高）：条件 cond 成立时只捡不交，避免「边捡边交」导致手上反复清空。
--   第二阶段：不再满足 cond（通常是离主人太远/该收工了）才把手上东西送去或丢下。
-- ★ 这解释了为什么 Give/Drop 优先级必须低于 Pickup：否则永远在送东西，没空捡。
--
-- 【PriorityNode 的第二参数 .25（第 613 行）】
--   是「重新评估间隔（秒）」，不是概率。配合 WhileNode 的每帧条件求值，
--   构成「条件每帧检查、动作每 0.25 秒才允许重新开始」的节奏。
-- ★ 这个节流是 DST 性能的关键手法：条件判断很便宜但仍要限频到 0.25s。
        WhileNode(cond, "BC KeepPickup",
            DoAction(self.inst, CustomPickUpAction, "BC CustomPickUpAction", true)),
        WhileNode(give_cond_fn, "BC Should Bring To Leader",
			PriorityNode({
				DoAction(self.inst, GiveAction, "BC GiveAction", true),
				DoAction(self.inst, DropAction, "BC DropAction", true),
			}, .25)),
    },.25)
end
BrainCommon.NodeAssistLeaderPickUps = NodeAssistLeaderPickUps

--------------------------------------------------------------------------

local SEE_POSSESSABLE_CHASSIS_DIST = 10
-- 以下三段是 WX78 的「附身机甲」机制，与通用大脑逻辑无关，单独成节。
local POSESSABLE_CHASSIS_TAGS = { "possessable_chassis" }
local NO_POSSESSABLE_CHASSIS_TAGS = { "NOCLICK" }

local function IsPossessableChassisValid(guy, inst)
-- 已有机甲（linkeditem 有 owner）视为无效 —— 不能附身已被人附身的。
-- ★ 互斥判定走组件而非 tag，是「行为契约用组件表达」的例子。
    return guy.components.linkeditem == nil or guy.components.linkeditem:GetOwnerInst() ~= nil
end

local function SelectPossessableChassis(self)
-- SelectPossessableChassis：把找到的机甲缓存到 self（脑）而不是 inst（实体）。
-- ★ 注意这个差异：脑里的字段脑自己管，实体上的字段要跨脑共享。
--   WX78 只有一个脑，用 self 没差别；但若多脑共享就得分清。
	self.possessable_chassis = FindEntity(self.inst, SEE_POSSESSABLE_CHASSIS_DIST, IsPossessableChassisValid, POSESSABLE_CHASSIS_TAGS, NO_POSSESSABLE_CHASSIS_TAGS)
	return self.possessable_chassis ~= nil
end

local function CheckPossessableChassis(self)
-- CheckPossessableChassis：每次用缓存前重新校验（IsValid + tag 还在）。
-- ⚠️ 与 FindSaltlick（第 17 行）同构的「缓存 + 失效校验」模式，全DST 反复出现。
	return self.possessable_chassis:IsValid() and self.possessable_chassis:HasTag("possessable_chassis")
end

local function GetPossessableChassisPos(inst)
-- GetPossessableChassisPos：给 Leash 节点用的目标坐标提供者。
-- ⚠️ 第 637-639 行 `if not inst.brain then return end` 的注释是 "Just in case??" ——
--   ★ 作者自己都不确定这个判空是否必要，标为防御性代码，非缺陷。
-- 第 641 行校验通过才给坐标，否则 nil（Leash 收到 nil 会原地不动）。
    if not inst.brain then -- Just in case??
        return
    end

	return CheckPossessableChassis(inst.brain) and inst.brain.possessable_chassis:GetPosition() or nil
end

local POSSESS_DIST = .5
-- 附身距离的两个阈值：0.5 开始拉近，0.4 就算贴上了。
-- ★ 内外双阈值 = 迟滞，防止在边界反复「走过去-退回来」。
--   同一个模式在本文件出现多次（第 41 行 Remap、第 644 行、第 396 行 pigbrain），
--   是 DST 处理「距离边界抖动」的统一手法。
local POSSESS_DIST_INNER = POSSESS_DIST - .1
local function PossessChassis(self, update_rate)
-- ★ PossessChassis 的三段结构：
--   IfNode(先找到机甲) → PriorityNode{
--       FailIfSuccessDecorator(Leash 拉近，贴上了就算成功并终止后续)
--       IfNode(机甲仍有效 → 推 possess_chassis 事件)
--       FaceEntity(朝向机甲)
--   }
-- ★ FailIfSuccessDecorator 的作用：Leash 成功（到达）就短路掉整个 PriorityNode，
--   不再执行后面的附身动作 —— 因为已经贴上了，下一轮自然会触发。
--   这是「用装饰器表达『到达即完成』」的手法，避免再套一层 WhileNode。
-- 第 651 行 ★ PushEventImmediate 而非 PushEvent：
--   立即派发（不排队等下一帧），因为附身是状态切换，时机敏感。
--   ★ 这是 DST 里「需要立刻生效」的标准手段，与普通 PushEvent 的语义差别很关键。
    return IfNode(function() return SelectPossessableChassis(self) end, "possess chassis",
			PriorityNode({
                FailIfSuccessDecorator(Leash(self.inst, GetPossessableChassisPos, POSSESS_DIST, POSSESS_DIST_INNER, true)),
				IfNode(function() return CheckPossessableChassis(self) end, "possess",
					ActionNode(function() self.inst:PushEventImmediate("possess_chassis", { target = self.possessable_chassis }) end)),
				FaceEntity(self.inst,
					function() return self.possessable_chassis end,
					function() return CheckPossessableChassis(self) end),
			}, update_rate))
end

BrainCommon.PossessChassisNode = PossessChassis

return BrainCommon