--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：prefabs/player_classified.lua
-- 模块：网络同步层 / 玩家同步状态宿主（classified 实体，1669 行）
-- 职责：全工程 net_* 声明密度最高的单文件（123 处，第 1330-1633 行）。
--       把玩家的全部共享状态（生命/饥饿/理智/温度/湿度/配方/科技树/
--       相机/HUD/战斗/骑乘/移动速度/死亡原因等）集中挂在一个 classified
--       网络实体上，作为「服务端权威、全服可见」的同步载体。
-- ★ 与玩家实体（player.lua）的分工：classified 上的 netvar = 全服可见；
--   玩家实体自身的字段 = 本地私有。这是「可见性分区」的设计。
-- ★ 演示了 dirty 事件的「三段式分发」：
--   玩家实体本地事件 -> 服务端压进布尔 netvar（SetDirty 强制置脏）
--   -> 客户端脏事件消费 -> PushEvent 给玩家实体 -> UI/动画/音效。
-- 关键符号：SetDirty（强制置脏，18 处）, OnEntityReplicated,
--           RegisterNetListeners_mastersim / _local / _common,
--           OnInitialDirtyStates, FinishSeamlessPlayerSwap,
--           craftinglimit_net_enum, SetOldagerRate / GetOldagerRate,
--           DeserializeTemperature, PushPausePredictionFrames
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：netvars.lua（类型契约、set_local 警告、数组类型注意事项）、
--           netvars.lua:97 GetIdealUnsignedNetVarForCount（本文件 1535 行唯一用处）、
--           entityreplica.lua:87-95 classified 机制与 TryAttachClassifiedToReplicaComponent、
--           entityreplica.lua:82 OnEntityReplicated 钩子（本文件 247 行即其实现）、
--           entityscript.lua（玩家实体侧的组件与事件源）、
--           techtree.lua（BONUS_TECH / AVAILABLE_TECH 为有序数组，故可用 ipairs）、
--           components/clock.lua:161 ForceResync（与本文件 SetDirty 同构的原语）
-- 【★移植要点】① 「声明 + 立即赋初值」应视为一体，否则首帧读到 nil。
--   ② 123 处 netvar 必须全部位于 SetPristine 之前，否则两端 wire format
--      长度不一致会导致反序列化整体错位，且报错点与出错点相距很远。
--   ③ 增量同步必须配「强制全量重算」（本文件 OnInitialDirtyStates），
--      否则当初值恰好等于默认值时客户端会漏掉初始化，表现为偶发 UI 不刷新。
--   ④ 一次性网络事件要「收到即消费」，不能在发送端预复位，否则高频连发丢事件。
--============================================================
local TIMEOUT = 2
-- ★★★★ 全工程 net_* 声明密度最高的单文件（123 处）。
-- 它不是「玩家预制体」，而是玩家身上那一整块「同步状态的宿主」。
--
-- 【★为什么要把状态全放在 classified 上，而不是玩家实体本身】
-- 玩家实体（player.lua）是每客户端一份的本地实体；
-- 而 player_classified 是「服务端权威、广播给全服」的网络实体。
-- 把血量、饥饿、理智、配方解锁、相机、音量等同步字段集中挂到 classified 上，
-- 好处是同步边界极其清晰：classified 上的 netvar = 全服可见；
--                玩家实体自己的字段 = 本地私有。
-- ★这是「可见性分区」的设计：用一个实体把数据切成「共享」与「私有」两半。
--
-- 【★classified 机制回顾（见 entityreplica.lua:87）】
-- 服务端只生成 1 份 classified，所有客户端都收到它，
-- 但每个客户端只把「属于自己的那一份」显示出来。
-- 于是实体数与带宽不随人数增长 —— 60 人仍是 60 份（每人自己那份），
-- 但每个玩家只渲染自己那份。
--
-- 【本文件的 dirty 分发架构，见第 264 行注的完整链路】
-- 这是理解 DST 同步的第三条主线（另两条是 netvars 类型、replica 分发）。
--
-- 【上游注释 V2C = Voice To Coder，标记「这段代码正等着 C++ 侧实现」】
-- 全工程大量出现，是 Klei 团队标记「此处 Lua 与 C++ 尚未对齐」的习惯。
-- 遇到 V2C 意味着这段逻辑可能不完整或有已知待办。
local TechTree = require("techtree")
local INSPIRATION_BATTLESONG_DEFS = require("prefabs/battlesongdefs")

local fns = {} -- a table to store local functions in so that we don't hit the 60 upvalues limit
-- ★ 把局部函数集中放进 fns 表，绕开「每函数最多 60 个 upvalue」的 Lua 限制。
-- 【★这是 Lua 的硬限制，也是本文件必须这样写的唯一原因】
-- 本文件有 100+ 个监听回调，若每个都写成独立 local function，
-- 后面的回调就会因 upvalue 超限而编译失败。
-- 用 fns.xxx = function 存表，就把「函数」变成了「表的字段」，
-- upvalue 限制随之消失。
--
-- 【★移植启示】这是 Lua 特有的工程技巧，其他语言没有对应问题。
-- 但「把函数当数据放进表」这个组织方式本身是通用的，
-- 对需要大量回调注册的场景（事件系统、插件系统）值得照用。

--------------------------------------------------------------------------
--Server interface
--------------------------------------------------------------------------

local function SetValue(inst, name, value)
    assert(value >= 0 and value <= 65535, "Player "..tostring(name).." out of range: "..tostring(value))
    inst[name]:set(math.ceil(value))
end

local function SetDirty(netvar, val)
-- ★★★ 全工程「强制置脏」的标准写法，共出现 18 次，是本文件的核心原语。
-- 与 components/clock.lua:161 的 ForceResync 完全同构，是同一思想的两次实现。
--
-- 【★为什么需要它：netvar 脏检测会「吞掉值未变的写入」】
-- 按 netvars.lua:44-47，set 仅在值真的变化时才触发脏事件。
-- 但这里的需求往往不是「改值」，而是「通知客户端做一件事」：
--   播放一次音效、闪一下血条、强制刷新 UI。
-- 若 netvar 当前值恰好已经是目标值（例如 ishealthpulseup 已是 true），
-- 直接 set(true) 不会有任何脏事件，客户端永远收不到通知。
--
-- 【★解法：set_local 让本端先「失忆」，再 set 强制其判定为变化】
-- 这正是 netvars.lua:55-57 那条警告所描述的机制，本函数主动利用它。
--
-- 【★正确写法与错误写法】
--   错误：netvar:set(true)          → 值未变则静默无通知
--   错误：netvar:set(false) 再 set(true) → 客户端会先收到 false 再收到 true，
--                                触发两次事件（可能播两次音效）
--   正确：本函数 set_local(x) + set(x) → 只有一次「变为 x」的语义
--
-- 【★与 clock.lua:161 的对照】
-- clock 的 ForceResync 目的相同（强制纠正客户端预测偏差），
-- player_classified 的 SetDirty 目的是强制触发一次性通知。
-- ★同一个原语、两种用途，说明这是同步层的通用工具而非偶然写法。
-- 自研引擎若要支持「幂等通知」，这正是需要的机制。
    --Forces a netvar to be dirty regardless of value
    netvar:set_local(val)
    netvar:set(val)
end

local function PushPausePredictionFrames(inst, frames)
-- ★ 「只想触发客户端事件」的典型用法，注释直接写明了这一点。
-- pausepredictionframes 存的是「暂停预测的帧数」这个真实数据，
-- 但调用方真正要的是「客户端现在开始暂停预测」这个动作。
-- 用 SetDirty 把数据与通知绑在一起，一次调用完成两件事。
    --Force dirty, we just want to trigger an event on the client
    SetDirty(inst.pausepredictionframes, frames)
end

local function OnForceHealthPulse(parent, data)
-- ★ 本文件所有 OnXxxDelta 的统一形态：服务端把「方向」翻译成一个布尔 netvar，
-- 客户端在该 netvar 的 dirty 回调里播动画/音效。
--
-- 【★为什么用「布尔脉冲」而不是直接同步方向值】
-- 因为客户端只需要知道「这次是回血还是掉血」，不需要连续的方向量。
-- 一个 1 位的 net_bool 足以表达，比同步一个 float 方向省 32 倍带宽。
-- ★这是「用最窄类型承载下游所需的全部信息」的典型。
--
-- 【★注意这里只有两个方向，没有「不变」】
-- 真正的「不变」由调用方决定不发事件；见第 44-49 行的三分支。
    if data.up then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.ishealthpulseup, true)
    elseif data.down then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.ishealthpulsedown, true)
    end
end

local function OnHealthDelta(parent, data)
    if data.overtime then
-- ★★★ 一段被刻意注释掉的代码，V2C 注释解释了原因，值得完整读。
-- 【原注释大意】不要清除：这是冗余的，因为 player_classified 不该被远程构造多次；
--   而且这样清会导致「网络尚未 tick 时丢失脉冲」。
--
-- 【★「丢失脉冲」是同步层的经典竞态，值得说透】
-- 场景：服务端连发两次「回血脉冲」。若每次都把上一个脉冲 set_local(false) 复位，
--   那么在网络包还没发出的窗口内，两次脉冲会互相抹掉，客户端一次都收不到。
-- 本文件的解法是「不复位」。那客户端如何区分连续两次同向脉冲？
-- 靠第 264 行 OnHealthDirty 里第 288-289 行的复位 —— 复位发生在客户端收到之后，
-- 即「收到即消费」，不会在服务端侧互相覆盖。
--
-- 【★移植要点：一次性网络事件要「收到即消费」，不能在发送端预消费】
-- 否则高频连发必然丢事件。这是所有事件型网络字段都必须处理的问题。
        --V2C: Don't clear: it's redundant as player_classified shouldn't
        --     get constructed remotely more than once, and this would've
        --     also resulted in lost pulses if network hasn't ticked yet.
        --parent.player_classified.ishealthpulseup:set_local(false)
        --parent.player_classified.ishealthpulsedown:set_local(false)
    elseif data.newpercent > data.oldpercent then
-- 三分支：涨 / 跌 / 不变（overtime）。
-- ★用 newpercent 与 oldpercent 比较得出方向，而不是由服务端直接告知方向。
-- 好处：血量由多个来源（食物、回复、季节）共同改变，
-- 客户端与服务端用同一套规则从数值推出方向，逻辑不会分叉。
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.ishealthpulseup, true)
    elseif data.newpercent < data.oldpercent then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.ishealthpulsedown, true)
    end
end

local function OnHungerDelta(parent, data)
    if data.overtime then
        --V2C: Don't clear: it's redundant as player_classified shouldn't
        --     get constructed remotely more than once, and this would've
        --     also resulted in lost pulses if network hasn't ticked yet.
        --parent.player_classified.ishungerpulseup:set_local(false)
        --parent.player_classified.ishungerpulsedown:set_local(false)
    elseif data.newpercent > data.oldpercent then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.ishungerpulseup, true)
    elseif data.newpercent < data.oldpercent then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.ishungerpulsedown, true)
    end
end

local function UpdateAnimOverrideSanity(parent)
    local isinsane = parent.replica.sanity:IsInsanityMode() and (parent.replica.sanity:GetPercentNetworked() <= (parent:HasTag("dappereffects") and TUNING.DAPPER_BEARDLING_SANITY or TUNING.BEARDLING_SANITY))
    parent.AnimState:SetClientSideBuildOverrideFlag("insane", isinsane)
    parent:SetClientSideInventoryImageOverrideFlag("insane", isinsane)
end

local function OnSanityDelta(parent, data)
    if data.overtime then
        --V2C: Don't clear: it's redundant as player_classified shouldn't
        --     get constructed remotely more than once, and this would've
        --     also resulted in lost pulses if network hasn't ticked yet.
        --parent.player_classified.issanitypulseup:set_local(false)
        --parent.player_classified.issanitypulsedown:set_local(false)
    elseif data.newpercent > data.oldpercent then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.issanitypulseup, true)
    elseif data.newpercent < data.oldpercent then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.issanitypulsedown, true)
    end

    if parent.HUD ~= nil then
        UpdateAnimOverrideSanity(parent)
    end
end

local function OnWerenessDelta(parent, data)
    if data.overtime then
        --V2C: Don't clear: it's redundant as player_classified shouldn't
        --     get constructed remotely more than once, and this would've
        --     also resulted in lost pulses if network hasn't ticked yet.
        --parent.player_classified.iswerenesspulseup:set_local(false)
        --parent.player_classified.iswerenesspulsedown:set_local(false)
    elseif data.newpercent > data.oldpercent then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.iswerenesspulseup, true)
    elseif data.newpercent < data.oldpercent then
        --Force dirty, we just want to trigger an event on the client
        SetDirty(parent.player_classified.iswerenesspulsedown, true)
    end
end

-- Keep NON_DANGER_TAGS in sync with dynamicmusic NON_DANGER_TAGS
local NON_DANGER_TAGS = {"noepicmusic", "shadow", "shadowchesspiece", "smolder", "thorny", "nodangermusic"}
local function OnAttacked(parent, data)
    parent.player_classified.attackedpulseevent:push()
    parent.player_classified.isattackedbydanger:set(
        data ~= nil and
        data.attacker ~= nil and
        not data.attacker:HasAnyTag(NON_DANGER_TAGS)
    )
    parent.player_classified.isattackredirected:set(data ~= nil and data.redirected ~= nil)
end

local function OnBuildSuccess(parent)
    parent.player_classified.buildevent:push()
end

local function OnConsumeHealthCost(parent)
    parent.player_classified.builderdamagedevent:push()
end

local function OnLearnRecipeSuccess(parent, data)
    SendRPCToClient(CLIENT_RPC.LearnBuilderRecipe, parent.userid, data.recipe)
    parent.player_classified.learnrecipeevent:push()
end

local function OnLearnMapSuccess(parent)
    parent.player_classified.learnmapevent:push()
end

local function OnRepairSuccess(parent)
    parent.player_classified.repairevent:push()
end

local function OnPerformAction(parent)
    SetDirty(parent.player_classified.isperformactionsuccess, true)
end

local function OnActionFailed(parent)
    SetDirty(parent.player_classified.isperformactionsuccess, false)
end

local function OnCarefulWalking(parent, data)
    parent.player_classified.iscarefulwalking:set(data.careful)
end

local function OnWormholeTravel(parent, wormholetype)
    SetDirty(parent.player_classified.wormholetravelevent, wormholetype)
end

local function OnHoundWarning(parent, houndwarningtype)
    SetDirty(parent.player_classified.houndwarningevent, houndwarningtype)
end

local function OnCraftedExtraElixir(parent, items)
    SetDirty(parent.player_classified.craftedextraelixirevent, items)
end


fns.OnPlayThemeMusic = function(parent, data)
    if data ~= nil then
        if data.theme == "farming" then
            parent.player_classified.start_farming_music:push()
        end
    end
end

local function OnMakeFriend(parent)
    parent.player_classified.makefriendevent:push()
end

local function OnFeedInContainer(parent)
    parent.player_classified.feedincontainerevent:push()
end

local function OnIdPlantSeed(parent)
    parent.player_classified.idplantseedevent:push()
end

local function AddMorgueRecord(inst)
    if inst._parent ~= nil then
        SetDirty(inst.isdeathbypk, inst._parent.deathpkname ~= nil)
        inst.deathcause:set(inst._parent.deathpkname or inst._parent.deathcause)
    end
end

--Temperature stuff
local max_precision_temp = 6
local min_precision_temp = -11
local precision_factor = 4
local coarse_factor = 1
local pivot = math.floor((256 - (max_precision_temp + min_precision_temp) * precision_factor) / 2)

local function SetTemperature(inst, temperature)
    if temperature >= max_precision_temp then
        inst.currenttemperaturedata:set(pivot + max_precision_temp * precision_factor + math.floor((temperature - max_precision_temp) * coarse_factor + .5))
    elseif temperature <= min_precision_temp then
        inst.currenttemperaturedata:set(pivot + min_precision_temp * precision_factor + math.floor((temperature - min_precision_temp) * coarse_factor + .5))
    else
        inst.currenttemperaturedata:set(pivot + math.floor(temperature * precision_factor + .5))
    end
end

fns.SetOldagerRate = function(inst, dps)
    assert(dps >= -30 and dps <= 30, "Player oldager_rate out of range: "..tostring(dps))
    inst.oldager_rate:set(dps + 30)
end

fns.GetOldagerRate = function(inst)
    return inst.oldager_rate:value() - 30
end


--TouchStoneTracker stuff
local function SetUsedTouchStones(inst, used)
    inst.touchstonetrackerused:set(used)
end

fns.SetBathingPoolCamera = function(inst, target)
	inst.bathingpool:set(target)
	fns.OnBathingPoolDirty(inst)
end

--------------------------------------------------------------------------
--Client interface
--------------------------------------------------------------------------

local function DeserializeTemperature(inst)
    if inst.currenttemperaturedata:value() >= pivot + max_precision_temp * precision_factor then
        inst.currenttemperature = (inst.currenttemperaturedata:value() - pivot - max_precision_temp * precision_factor) / coarse_factor + max_precision_temp
    elseif inst.currenttemperaturedata:value() <= pivot + min_precision_temp * precision_factor then
        inst.currenttemperature = (inst.currenttemperaturedata:value() - pivot - min_precision_temp * precision_factor) / coarse_factor + min_precision_temp
    else
        inst.currenttemperature = (inst.currenttemperaturedata:value() - pivot) / precision_factor
    end
end

local function OnEntityReplicated(inst)
-- ★★ classified 的客户端初始化钩子，由 entityreplica.lua:82-84 在
-- 「所有 replica 组件就绪后」调用。时机依赖极其关键，见下方注。
--
-- 【★为什么这里能安全访问 entity:GetParent】
-- classified 实体没有 AddTransform 之外的物理位置，其父实体是玩家实体。
-- 这个钩子被调用的前提是「replica 已全部创建完毕」，
-- 所以此时 netvar 已反序列化完毕，可以安全读取。
-- 若在此之前调用，GetParent 可能返回未就绪的实体。
--
-- 【★这就是 entityreplica.lua:82 那个 OnEntityReplicated 钩子的实际用途】
-- 全工程规模最大的一次使用：123 个 netvar 的宿主在这里完成挂载。
    inst._parent = inst.entity:GetParent()
    if inst._parent == nil then
        print("Unable to initialize classified data for player")
    else
        inst._parent:AttachClassified(inst)
-- 把 classified 登记到玩家的 classified 列表。
-- ★这样游戏逻辑可用 player_classified 反查 classified 实体，不用再搜实体树。
        for i, v in ipairs({ "builder", "combat", "health", "hunger", "rider", "sanity" }) do
-- ★★ 把 classified 挂到六个 replica 组件上。
-- 这六个是 entityreplica.lua:5 白名单里的组件。
-- 【★为什么要逐个挂：组件自己发事件时需要能访问 classified】
-- 例如 combat 组件要扣血时，必须写到 classified.currenthealth 这个 netvar，
-- 而不是直接改玩家实体上的字段（那样不会同步）。
-- ★这就是「游戏逻辑组件」与「网络状态宿主」的连接点。
--
-- 【★关键：这里用 ipairs 而非 pairs，顺序是确定的】
-- 挂载顺序理论上会影响组件内的初始化，但因都是赋值操作而无副作用。
-- 仍应保持 ipairs 以免未来有人依赖顺序时踩坑。
			inst._parent:TryAttachClassifiedToReplicaComponent(inst, v)
        end
		for i, v in ipairs({ "playercontroller", "playervoter", "boatcannonuser", "playerspeedmult" }) do
-- ★ 第二组：本地组件（非 replica），挂载前先判存在。
-- 与上一组的区别：这几个组件只在服务端有意义（playercontroller / playervoter），
-- 但仍需要 classified 来传递状态（如 HUD 开关、投票选择）。
-- 判空是因为并非所有玩家都装了 boatcannonuser 这类可选组件。
            if inst._parent.components[v] ~= nil then
                inst._parent.components[v]:AttachClassified(inst)
            end
        end
    end
end

local function OnHealthDirty(inst)
-- ★★★★ 本文件最核心的函数，完整演示了 DST 的 dirty 事件分发三段式。
--
-- 【★★三段式链路（这是本文件最值得学的东西）】
--   第 1 段 · 产生：
--     玩家实体（本地）发事件，如 healthdelta（见第 37 行 OnHealthDelta）
--   第 2 段 · 转译为 netvar：
--     服务端把事件语义压进一个布尔 netvar，用 SetDirty 强制置脏（第 16 行）
--   第 3 段 · 客户端消费：
--     客户端 netvar 变脏 → 触发 "healthdirty" → 本函数运行 →
--     PushEvent 给玩家实体 → UI/动画/音效订阅
--
-- 【★为什么必须转这一步，不能直接 PushEvent 到客户端？】
-- 因为 Lua 的 PushEvent 只在本地进程内派发，跨进程必须走网络。
-- netvar 是 DST 唯一的跨端数据通道（net_event 是它的语法糖）。
-- 所以「本地事件 → 网络字段 → 本地事件」是绕不开的。
-- ★自研引擎同样如此：事件总线是进程内的，跨端必须过序列化通道。
--
-- 【★为什么这里要手动比对 oldpercent，而不是让引擎发脏事件就完事】
-- 因为引擎的脏事件只知道「currenthealth 变了」，
-- 而 UI 需要的是「从 0.8 变到 0.5」（用于动画插值与音效强度）。
-- 差值信息无法从两个独立字段推出来，必须在服务端算好后随事件一起传。
-- ★所以 _oldhealthpercent（第 1340 行）这个「影子副本」是必需的，
--   它不发网络、只存在本地，用途纯粹是算出 delta。
    if inst._parent ~= nil then
        local oldpercent = inst._oldhealthpercent
        local percent = inst.currenthealth:value() / inst.maxhealth:value()
        if oldpercent == percent then
-- ★★ 「比例没变」分支：血量绝对值变了但百分比没变（如回满血时 maxhealth 提升）。
-- 【★为什么要单独处理这个看似罕见的分支】
-- 因为升级/加成会改变 maxhealth，此时 current 与 max 同比例变化，
-- 百分比不变但上限变了 —— UI 的「血条变长」必须被感知到。
-- 原注释明确写了：仍必须传 healthdelta 以更新上限值。
-- ★这是「派生指标不变但基量变了」的经典陷阱，值得记。
            local data =
            {
                oldpercent = oldpercent,
                newpercent = percent,
            }
            inst._parent:PushEvent("healthdelta", data) -- still must pass healthdelta to update max value in case they changed
-- 注释强调：即使比例没变也必须发，因为「上限可能变了」。
-- ★同时额外发一个 forcehealthpulse（第 275 行），强制播一次回血动画。
-- 证明「即使数据没实质变化，也可能需要播一次动画」—— 这正是 SetDirty 的用武之地。
            inst._parent:PushEvent("forcehealthpulse", { up = inst.ishealthpulseup:value(), down = inst.ishealthpulsedown:value() })
            inst.ishealthpulseup:set_local(false)
            inst.ishealthpulsedown:set_local(false)
        else
            local data =
            {
                oldpercent = oldpercent,
                newpercent = percent,
                overtime =
-- ★ overtime 的定义：既不是「在回血中且比例上升」，也不是「在掉血中且比例下降」。
-- 【★这个双重否定是本文件最难读的一行，拆开看】
--   情况 A：正在回血（pulseup）但比例没升 → overtime（服务端说回血，但数字没动）
--   情况 B：正在掉血（pulsedown）但比例没降 → overtime
--   情况 C：不在脉冲中 → overtime
-- 语义是「这次 delta 不代表真实的伤害/回复量，别播动画」。
-- ★典型场景：服务器 tick 边界与伤害帧不对齐，导致 delta 算出来是 0。
-- 此时若照常播动画，玩家会看到「血条闪一下但数字不动」，非常困惑。
                    not (inst.ishealthpulseup:value() and percent > oldpercent) and
                    not (inst.ishealthpulsedown:value() and percent < oldpercent),
            }
            inst._oldhealthpercent = percent
            inst.ishealthpulseup:set_local(false)
            inst.ishealthpulsedown:set_local(false)
            inst._parent:PushEvent("healthdelta", data)
        end
    else
-- ★ _parent 为 nil 的兜底分支（父实体尚未 attach 完成时）。
-- 【★为什么需要：dirty 事件可能早于 OnEntityReplicated 触发】
-- classified 刚构造完就注册了监听（第 1635 行），
-- 而 _parent 要到 OnEntityReplicated（第 248 行）才赋值。
-- 这个时间窗内若恰好有脏事件，就会撞上 nil。
--
-- 【★所以第 1635 行那句「先 set 初值，再注册监听」的顺序很重要】
-- 注释原文：Delay net listeners until after initial values are deserialized。
-- 即：初值反序列化完成之后再挂监听，避免「初始化过程本身触发一堆脏事件」，
-- 导致刚连上就播一轮无意义的动画。
-- ★这是网络实体初始化的通用范式：先填数据，后接回调。
--
-- 【本文件共有 61 处 `inst._parent ~= nil` 防护，全是同一个原因】
        inst._oldhealthpercent = 1
        inst.ishealthpulseup:set_local(false)
        inst.ishealthpulsedown:set_local(false)
    end
end

local function OnIsTakingFireDamageDirty(inst)
    if inst._parent ~= nil then
        if inst.istakingfiredamage:value() then
            inst._parent:PushEvent("startfiredamage", { low = inst.istakingfiredamagelow:value() })
        else
            inst._parent:PushEvent("stopfiredamage")
        end
    end
end

local function OnIsTakingFireDamageLowDirty(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("changefiredamage", { low = inst.istakingfiredamagelow:value() })
    end
end

local function OnLunarBurnFlagsDirty(inst)
	if inst._parent then
		local flags = inst.lunarburnflags:value()
		if flags ~= 0 then
			inst._parent:PushEvent("startlunarburn", flags)
		else
			inst._parent:PushEvent("stoplunarburn")
		end
	end
end

local function OnAttackedPulseEvent(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("attacked", { isattackedbydanger = inst.isattackedbydanger:value(), redirected = inst.isattackredirected:value() })
    end
end

local function OnHungerDirty(inst)
    if inst._parent ~= nil then
        local oldpercent = inst._oldhungerpercent
        local percent = inst.currenthunger:value() / inst.maxhunger:value()
        local data =
        {
            oldpercent = oldpercent,
            newpercent = percent,
            overtime =
                not (inst.ishungerpulseup:value() and percent > oldpercent) and
                not (inst.ishungerpulsedown:value() and percent < oldpercent),
        }
        inst._oldhungerpercent = percent
        inst.ishungerpulseup:set_local(false)
        inst.ishungerpulsedown:set_local(false)
        inst._parent:PushEvent("hungerdelta", data)
        if oldpercent > 0 then
            if percent <= 0 then
                inst._parent:PushEvent("startstarving")
            end
        elseif percent > 0 then
            inst._parent:PushEvent("stopstarving")
        end
    else
        inst._oldhungerpercent = 1
        inst.ishungerpulseup:set_local(false)
        inst.ishungerpulsedown:set_local(false)
    end
end

local function OnSanityDirty(inst)
    if inst._parent ~= nil then
        local oldpercent = inst._oldsanitypercent
        local percent = inst.currentsanity:value() / inst.maxsanity:value()
        local data =
        {
            oldpercent = oldpercent,
            newpercent = percent,
            overtime =
                not (inst.issanitypulseup:value() and percent > oldpercent) and
                not (inst.issanitypulsedown:value() and percent < oldpercent),
            sanitymode = inst._parent.replica.sanity:GetSanityMode(),
        }
        inst._oldsanitypercent = percent
        inst.issanitypulseup:set_local(false)
        inst.issanitypulsedown:set_local(false)
        inst._parent:PushEvent("sanitydelta", data)

        inst._parent:DoTaskInTime(0, UpdateAnimOverrideSanity)
    else
        inst._oldsanitypercent = 1
        inst.issanitypulseup:set_local(false)
        inst.issanitypulsedown:set_local(false)
    end
end

local function OnWerenessDirty(inst)
    if inst._parent ~= nil then
        local oldpercent = inst._oldwerenesspercent
        local percent = inst.currentwereness:value() * .01
        local data =
        {
            oldpercent = oldpercent,
            newpercent = percent,
            overtime =
                not (inst.iswerenesspulseup:value() and percent > oldpercent) and
                not (inst.iswerenesspulsedown:value() and percent < oldpercent),
        }
        inst._oldwerenesspercent = percent
        inst.iswerenesspulseup:set_local(false)
        inst.iswerenesspulsedown:set_local(false)
        inst._parent:PushEvent("werenessdelta", data)
    else
        inst._oldwerenesspercent = 0
        inst.iswerenesspulseup:set_local(false)
        inst.iswerenesspulsedown:set_local(false)
    end
end

fns.OnInspirationDirty = function(inst)
    if inst._parent ~= nil then
        local oldpercent = inst._oldinspirationpercent
        local percent = inst.currentinspiration:value() * .01
        local data =
        {
            newpercent = percent,
            slots_available = nil,
            draining = inst.inspirationdraining:value(),
        }
        inst._oldinspirationpercent = percent
        inst._parent:PushEvent("inspirationdelta", data)
    else
        inst._oldinspirationpercent = 0
    end
end

fns.OnHasInspirationBuffDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("hasinspirationbuff", {on = inst.hasinspirationbuff:value()})
    end
end

fns.InMightyGymDirty = function(inst)

    if inst._parent ~= nil then
        inst._parent:PushEvent("inmightygym", {ingym = inst.inmightygym:value() + 1, player=inst._parent})
    end
end

fns.OnGymBellStart = function(inst)
    if inst._parent ~= nil then
        inst._parent:Startbell()
    end
end

fns.PlayCritWorkSound = function(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("meta2/wolfgang/critical_work")
    end
end

fns.OnInspirationSongsDirty = function(inst, slot)
    if inst._parent ~= nil then
        local song_def = INSPIRATION_BATTLESONG_DEFS.GetBattleSongDefFromNetID(inst.inspirationsongs[slot]:value())
        inst._parent:PushEvent("inspirationsongchanged", {songdata = song_def, slotnum = slot})
    end
end

local function OnMightinessDirty(inst)
    if inst._parent ~= nil then
        local percent = inst.currentmightiness:value() * .01
        local data =
        {
            oldpercent = inst._oldmightinesspercent,
            newpercent = percent,
            delta = inst.currentmightiness:value() - (inst._oldmightinesspercent / .01),
        }
        inst._oldmightinesspercent = percent

        inst._parent:PushEvent("mightinessdelta", data)
    end
end

-- Wortox free soulhops ------------------------------------------------------

fns.OnFreeSoulhopsDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("freesoulhopschanged", {current = inst.freesoulhops:value()})
    end
end

-- wortox_panflute_buff ------------------------------------------------------
fns.OnWortoxPanfluteBuffDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("item_buff_changed")
    end
end

------------------------------------------------------------------------------
-- Winona Inspectacles game

fns.OnInspectaclesGameDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("inspectaclesgamechanged", {
            gameid = inst.inspectacles_game:value(),
            posx = inst.inspectacles_posx:value(),
            posz = inst.inspectacles_posz:value(),
        })
    end
end

-- Winona Rose Glasses
fns.OnRoseGlassesCooldownDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("roseglassescooldownchanged", {
            isincooldown = inst.roseglasses_cooldown:value(),
        })
    end
end

------------------------------------------------------------------------------

local function OnMoistureDirty(inst)
    if inst._parent ~= nil then
        local data =
        {
            old = inst._oldmoisture,
            new = inst.moisture:value(),
        }
        inst._oldmoisture = data.new
        inst._parent:PushEvent("moisturedelta", data)
    else
        inst._oldmoisture = 0
    end
end

local function OnTemperatureDirty(inst)
    DeserializeTemperature(inst)
    if inst._parent == nil then
        inst._oldtemperature = TUNING.STARTING_TEMP
    elseif inst._oldtemperature ~= inst.currenttemperature then
        local oldtemperature = inst._oldtemperature
        local temperature = inst.currenttemperature
        local data =
        {
            last = oldtemperature,
            new = temperature,
        }
        inst._oldtemperature = temperature
        if oldtemperature < 0 then
            if temperature >= 0 then
                inst._parent:PushEvent("stopfreezing")
            end
        elseif temperature < 0 then
            inst._parent:PushEvent("startfreezing")
        end
        if oldtemperature > TUNING.OVERHEAT_TEMP then
            if temperature <= TUNING.OVERHEAT_TEMP then
                inst._parent:PushEvent("stopoverheating")
            end
        elseif temperature > TUNING.OVERHEAT_TEMP then
            inst._parent:PushEvent("startoverheating")
        end
        inst._parent:PushEvent("temperaturedelta", data)
    end
end

local function OnTechTreesDirty(inst)
    for i, v in ipairs(TechTree.AVAILABLE_TECH) do
        local level = inst[TechTree.AVAILABLE_TECH_LEVEL_CLASSIFIED[v] or string.lower(v).."level"]:value()
        local bonus = inst[TechTree.AVAILABLE_TECH_TEMPBONUS_CLASSIFIED[v] or string.lower(v).."tempbonus"]
        inst.techtrees[v] = level
        inst.techtrees_no_temp[v] = math.max(0, level - (bonus ~= nil and bonus:value() or 0))
    end
    if inst._parent ~= nil then
        inst._parent:PushEvent("techtreechange", { level = inst.techtrees })
    end
end

fns.RefreshCrafting = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("refreshcrafting")
    end
end

local function OnRecipesDirty(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("unlockrecipe")
    end
end

local function Refresh(inst)
    inst._refreshtask = nil
    for k, v in pairs(inst._bufferedbuildspreview) do
        inst._bufferedbuildspreview[k] = nil
    end
    if inst._parent ~= nil then
        inst._parent:PushEvent("refreshcrafting")
    end
end

local function QueueRefresh(inst, delay)
    if inst._refreshtask == nil then
        inst._refreshtask = inst:DoTaskInTime(delay, Refresh)
    end
end

local function CancelRefresh(inst)
    if inst._refreshtask ~= nil then
        inst._refreshtask:Cancel()
        inst._refreshtask = nil
    end
end

local function OnBufferedBuildsDirty(inst)
    CancelRefresh(inst)
    Refresh(inst)
end

local function BufferBuild(inst, recipename)
    local recipe = GetValidRecipe(recipename)
    local inventory = inst._parent ~= nil and inst._parent.replica.inventory ~= nil and inst._parent.replica.inventory.classified or nil
    if recipe ~= nil and inventory ~= nil and inventory:RemoveIngredients(recipe, INGREDIENT_MOD_LOOKUP[inst.ingredientmod:value()]) then
        inst._bufferedbuildspreview[recipename] = true
        if inst._parent ~= nil then
            inst._parent:PushEvent("refreshcrafting")
        end
        CancelRefresh(inst)
        QueueRefresh(inst, TIMEOUT)
        SendRPCToServer(RPC.BufferBuild, recipe.rpc_id)
    end
end

local function OnIsPerformActionSuccessDirty(inst)
    if inst._parent ~= nil then
        if inst._parent.bufferedaction ~= nil and
            inst._parent.bufferedaction.ispreviewing then
            inst._parent:ClearBufferedAction()
        end
        if inst.isperformactionsuccess:value() then
            inst._parent:PushEvent("performaction")
        end
    end
end

local function CancelPausePrediction(inst)
    if inst._pausepredictiontask ~= nil then
        inst._pausepredictiontask:Cancel()
        inst._pausepredictiontask = nil
        inst.pausepredictionframes:set_local(0)
    end
end

local function OnPausePredictionFramesDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if inst._pausepredictiontask ~= nil then
            inst._pausepredictiontask:Cancel()
        end
        inst._pausepredictiontask = inst.pausepredictionframes:value() > 0 and inst:DoTaskInTime(inst.pausepredictionframes:value() * FRAMES, CancelPausePrediction) or nil
        inst._parent:PushEvent("cancelmovementprediction")
    end
end

fns.OnIsStrafingDirty = function(inst)
	if inst._parent then
		inst._parent:PushEvent(inst.isstrafing:value() and "startstrafing" or "stopstrafing")
	end
end

local function OnIsCarefulWalkingDirty(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("carefulwalking", { careful = inst.iscarefulwalking:value() })
    end
end

local function OnExternalVelocityVectorDirty(inst)
    if inst._parent then
        inst._parent.Physics:SetMotorVelExternal(inst.externalvelocityvectorx:value(), 0, inst.externalvelocityvectorz:value())
    end
end

fns.OnPlayerSpeedMultDirty = function(inst)
	if inst._parent and inst._parent.components.playerspeedmult then
		inst._parent.components.playerspeedmult:ApplyRunSpeed_Internal()
	end
end

local function OnPlayerCameraShake(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        TheCamera:Shake(
            inst.camerashakemode:value(),
            (inst.camerashaketime:value() + 1) / 16,
            (inst.camerashakespeed:value() + 1) / 256,
            (inst.camerashakescale:value() + 1) / 32
        )
    end
end

local function OnPlayerScreenFlashDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        TheWorld:PushEvent("screenflash", (inst.screenflash:value() + 1) / 8)
    end
end

local function OnAttunedResurrectorDirty(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("attunedresurrector", inst.attunedresurrector:value())
    end
end

fns.OnCannonDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("aimingcannonchanged", inst.cannon:value())
    end
end

fns.OnBathingPoolDirty = function(inst)
	if inst._parent and inst._parent.HUD and inst._oldbathingpool ~= inst.bathingpool:value() then
		if inst._oldbathingpool then
			TheFocalPoint.components.focalpoint:StopFocusSource(inst._oldbathingpool)
		end
		inst._oldbathingpool = inst.bathingpool:value()
		if inst._oldbathingpool then
			TheFocalPoint.components.focalpoint:StartFocusSource(inst._oldbathingpool, nil, nil, math.huge, math.huge, 1)
		end
	end
end

--------------------------------------------------------------------------
--Common interface
--------------------------------------------------------------------------

local function OnStormLevelDirty(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("stormlevel", { level = inst.stormlevel:value() / 7, stormtype = inst.stormtype:value() }) --
    end
end

fns.OnIsInMiasmaDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("miasmalevel", { level = inst.isinmiasma:value() and 1 or 0 })
    end
end

fns.OnIsAcidSizzlingDirty = function(inst)
    if inst._parent ~= nil then
        inst._parent:PushEvent("isacidsizzling", inst.isacidsizzling:value())
    end
end

local function OnBuildEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/collect_newitem")
        inst._parent:PushEvent("buildsuccess")
    end
end

local function OnBuilderDamagedEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        inst._parent:PushEvent("damaged")
    end
end

local function OnOpenCraftingMenuEvent(inst)
    local player = inst._parent
    if player ~= nil and TheFocalPoint.entity:GetParent() == player then
        if player.HUD ~= nil then
            player.HUD:OpenCrafting()
        end
    end
end

local function OnIsCraftingEnabledDirty(inst)
	if inst._parent and inst._parent.HUD then
		if inst.iscraftingenabled:value() then
			inst._parent.HUD.controls:ShowCrafting()
		else
			inst._parent.HUD.controls:HideCrafting()
			if inst._parent.components.playercontroller then
				inst._parent.components.playercontroller:CancelPlacement()
			end
		end
	end
end

local function OnInkedEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        inst._parent:PushEvent("inked")
    end
end

local function OnLearnRecipeEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/get_gold")
    end
end

local function OnLearnMapEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/Together_HUD/learn_map")
    end
end

local function OnRevealMapSpotEvent(inst)
    local tx, ty, tz = inst.revealmapspot_worldx:value(), 0, inst.revealmapspot_worldz:value()
    local player = inst._parent

    if player ~= nil and player.HUD ~= nil then
        player:DoTaskInTime(0, function()
            if TheFocalPoint.entity:GetParent() == player then
                TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/Together_HUD/learn_map")
            end
            player.HUD.controls:ShowMap(Vector3(tx, ty, tz))
        end)
    end
end

local function OnRepairEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/repair_clothing")
    end
end

local function OnGhostModeDirty(inst)
    if inst._parent ~= nil then
        inst._parent.components.playervision:SetGhostVision(inst.isghostmode:value())
        if inst._parent.HUD ~= nil then
            inst._parent:SetGhostMode(inst.isghostmode:value())
        end
    end
end

local function OnActionMeterDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if inst.actionmeter:value() < 2 then
            inst._parent.HUD:HideRingMeter(inst.actionmeter:value() == 1)
        else
            inst._parent.HUD:ShowRingMeter(inst._parent:GetPosition(), inst.actionmetertime:value() * .1, (inst.actionmeter:value() - 2) * .1)
        end
    end
end

local function OnPlayerHUDDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if inst.ishudvisible:value() then
            inst._parent.HUD:Show()
        else
            inst._parent.HUD:Hide()
        end

        if inst.ismapcontrolsvisible:value() and not GetGameModeProperty("no_minimap") then
            inst._parent.HUD.controls.mapcontrols:ShowMapButton()
        else
            if inst._parent.HUD:IsMapScreenOpen() then
                TheFrontEnd:PopScreen()
            end
            inst._parent.HUD.controls.mapcontrols:HideMapButton()
        end
    end
end

local CAMERA_ZOOM_DIST = 18
local CAMERA_ZOOM_DISTANCE_GAIN = 3
local CAMERA_AERIAL_ZOOM_DIST = 0

local function OnPlayerCameraDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if inst.iscamerazoomed:value() then
            if inst._prevcameradistance == nil then
                inst._prevcameradistance = TheCamera.distance
				local pan_gain, heading_gain, distance_gain = TheCamera:GetGains()
				inst._prevcameradistancegain = distance_gain
				if inst._prevcamerafov then
					--aerial
					TheCamera:SetDistance(CAMERA_AERIAL_ZOOM_DIST)
					TheCamera:Snap()
					TheCamera:SetGains(pan_gain, heading_gain, CAMERA_ZOOM_DISTANCE_GAIN)
					TheCamera:SetControllable(false)
				elseif inst._prevcameradistance > CAMERA_ZOOM_DIST then
					TheCamera:SetDistance(CAMERA_ZOOM_DIST)
					TheCamera:SetGains(pan_gain, heading_gain, CAMERA_ZOOM_DISTANCE_GAIN)
                    TheCamera:SetControllable(false)
                end
            end
        elseif inst._prevcameradistance ~= nil then
            TheCamera:SetDistance(inst.cameradistance:value() > 0 and inst.cameradistance:value() or inst._prevcameradistance)
			local pan_gain, heading_gain, distance_gain = TheCamera:GetGains()
			TheCamera:SetGains(pan_gain, heading_gain, inst._prevcameradistancegain)
            inst._prevcameradistance = nil
            inst._prevcameradistancegain = nil
            TheCamera:SetControllable(true)
        elseif inst.cameradistance:value() > 0 then
            TheCamera:SetDistance(inst.cameradistance:value())
        else
            TheCamera:SetDefault()
        end
    end
end

local function OnPlayerAerialCameraDirty(inst)
	if inst._parent and inst._parent.HUD then
		if inst.isaerialcamera:value() then
			if inst._prevcamerafov == nil then
				inst._prevcamerafov = TheCamera:GetFOV()
				inst._prevcameramindistpitch, inst._prevcameramaxdistpitch = TheCamera:GetPitchRange()
				TheCamera:SetFOV(130)
				TheCamera:SetPitchRange(80, 80)
				if inst._prevcameradistance then
					--zoomed
					TheCamera:SetDistance(CAMERA_AERIAL_ZOOM_DIST)
					TheCamera:Snap()
					local pan_gain, heading_gain, distance_gain = TheCamera:GetGains()
					TheCamera:SetGains(pan_gain, heading_gain, CAMERA_ZOOM_DISTANCE_GAIN)
					TheCamera:SetControllable(false)
				end
			end
		elseif inst._prevcamerafov then
			TheCamera:SetFOV(inst._prevcamerafov)
			TheCamera:SetPitchRange(inst._prevcameramindistpitch, inst._prevcameramaxdistpitch)
			inst._prevcamerafov = nil
			inst._prevcameramindistpitch = nil
			inst._prevcameramaxdistpitch = nil
			if inst._prevcameradistance then
				--zoomed
				TheCamera:SetDistance(CAMERA_ZOOM_DIST)
			end
		end
	end
end

local function DoMaximizeCameraDistance(inst)
    TheCamera:MaximizeDistance()
end

function fns.OnPlayerCameraExtraDistDirty(inst, init)
    if inst._parent == nil or inst._parent.HUD == nil then
        return
    end

    local cameraextramaxdist = inst.cameraextramaxdist:value()

    if cameraextramaxdist then
        local capped_extra_distance = PLAYER_CAMERA_MAX_DIST - TheCamera:GetRawMaxDistance()
        TheCamera:SetExtraMaxDistance(math.min(capped_extra_distance, cameraextramaxdist))

        if init and cameraextramaxdist > 0 then
            inst:DoTaskInTime(0, DoMaximizeCameraDistance)
        end
    end
end

fns.OnYotbSkinDirty = function(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if inst.hasyotbskin:value() then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/get_gold")
        end
        inst._parent:PushEvent("yotbskinupdate", {
            active = inst.hasyotbskin:value() or false,
        })
    end
end

local function OnGiftsDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        inst._parent:PushEvent("giftreceiverupdate", {
            numitems = inst.hasgift:value() and 1 or 0,
            active = inst.hasgiftmachine:value(),
        })
    end
end

local function OnMountHurtDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        inst._parent:PushEvent("mounthurt", { hurt = inst.isridermounthurt:value() })
    end
end

local function DoSnapCamera(inst, resetrot)
    if resetrot then
        TheCamera:SetHeadingTarget(45)
    end
    TheCamera:Snap()
end

local function OnPlayerCameraSnap(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if TheWorld.ismastersim then
            DoSnapCamera(inst, inst.camerasnap:value())
        else
            inst:DoTaskInTime(0, DoSnapCamera, inst.camerasnap:value())
        end
    end
end

local function DoMinimapCenter(inst)
    TheWorld.minimap.MiniMap:ResetOffset()
end

local function OnPlayerMinimapCenter(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if TheWorld.ismastersim then
            DoMinimapCenter(inst)
        else
            inst:DoTaskInTime(0, DoMinimapCenter)
        end
    end
end

local function DoMinimapClose(inst)
    local player = inst._parent

    if player ~= nil and player.HUD ~= nil then
        player.HUD.controls:HideMap()
    end
end

local function OnPlayerMinimapClose(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if TheWorld.ismastersim then
            DoMinimapClose(inst)
        else
            inst:DoTaskInTime(0, DoMinimapClose)
        end
    end
end

local function OnPlayerFadeDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        local iswhite = inst.fadetime:value() >= 32
        local time = iswhite and inst.fadetime:value() - 32 or inst.fadetime:value()
        if time > 0 then
            TheFrontEnd:Fade(inst.isfadein:value(), time / 10, nil, nil, nil, iswhite and "white" or "black")
            if inst.isfadein:value() then
                TheWorld.GroundCreep:FastForward()
            end
        else
            TheFrontEnd.fade_type = iswhite and "white" or "black"
            TheFrontEnd:SetFadeLevel(inst.isfadein:value() and 0 or 1)
        end
    end
end

local function OnWormholeTravelDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        if inst._parent.player_classified.wormholetravelevent:value() == WORMHOLETYPE.WORM then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/common/teleportworm/travel")
        elseif inst._parent.player_classified.wormholetravelevent:value() == WORMHOLETYPE.TENTAPILLAR then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/cave/tentapiller_hole_travel")
        elseif inst._parent.player_classified.wormholetravelevent:value() == WORMHOLETYPE.OCEANWHIRLPORTAL then
            TheFocalPoint.SoundEmitter:PlaySound("meta3/whirlpool/whirlpool_travel")
        elseif inst._parent.player_classified.wormholetravelevent:value() == WORMHOLETYPE.VAULTLOBBYEXIT then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/cave/tentapiller_hole_travel") -- FIXME(JBK): rifts6 sounds -- FIXME(JBK): rifts7 sounds
        end
    end
end

local function OnHoundWarningDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        local soundprefab = nil
        if inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL1 then
            soundprefab = "houndwarning_lvl1"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL2 then
            soundprefab = "houndwarning_lvl2"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL3 then
            soundprefab = "houndwarning_lvl3"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL4 then
            soundprefab = "houndwarning_lvl4"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL1_WORM then
            soundprefab = "wormwarning_lvl1"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL2_WORM then
            soundprefab = "wormwarning_lvl2"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL3_WORM then
            soundprefab = "wormwarning_lvl3"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.LVL4_WORM then
            soundprefab = "wormwarning_lvl4"
        elseif inst._parent.player_classified.houndwarningevent:value() == HOUNDWARNINGTYPE.WORM_BOSS then
            soundprefab = "wormwarning_worm_boss"            
        end
        if soundprefab then
            local sound = SpawnPrefab(soundprefab)
        end
    end
end

fns.OnCraftedExtraElixirDirty = function(inst)

    if inst._parent ~= nil and inst._parent.HUD ~= nil then
        local items = inst._parent.player_classified.craftedextraelixirevent:value()
        if items > 2 then
            TheFocalPoint.SoundEmitter:PlaySound("meta5/wendy/elixir_bonus_2")
        elseif items > 1 then
            TheFocalPoint.SoundEmitter:PlaySound("meta5/wendy/elixir_bonus_1")
        end
    end
end

fns.StartFarmingMusicEvent = function(inst)
    inst._parent:PushEvent("playfarmingmusic")
end

local function OnMakeFriendEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/common/makeFriend")
    end
end

fns.OnIdPlantSeedEvent = function(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("meta2/wormwood/identify_plant")
    end
end

local function OnFeedInContainerEvent(inst)
    if inst._parent ~= nil and TheFocalPoint.entity:GetParent() == inst._parent then
        TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/feed")
    end
end

local function OnMorgueDirty(inst)
    if inst._parent ~= nil and inst._parent.HUD ~= nil and not GetGameModeProperty("no_morgue_record") then
        Morgue:OnDeath({
            pk = inst.isdeathbypk:value() or nil,
            killed_by = inst.deathcause:value(),
            days_survived = inst._parent.Network:GetPlayerAge(),
            character = inst._parent.prefab,
            location = "unknown",
            world = TheWorld.meta ~= nil and TheWorld.meta.level_id or "unknown",
            server = TheNet:GetServerName(),
            date = os.date("%b %d, %y"),
        })
    end
end

--------------------------------------------------------------------------
--Server overriden to handle dirty events immediately
--otherwise server HUD events will be one wall-update late
--and possibly show some flicker
--------------------------------------------------------------------------
fns.SetGhostMode = function(inst, isghostmode)
    inst.isghostmode:set(isghostmode)
    OnGhostModeDirty(inst)
end

fns.ShowActions = function(inst, show)
    inst.isactionsvisible:set(show)
end

fns.ShowCrafting = function(inst, show)
	inst.iscraftingenabled:set(show)
	OnIsCraftingEnabledDirty(inst)
end

fns.ShowHUD = function(inst, show)
    inst.ishudvisible:set(show)
    OnPlayerHUDDirty(inst)
end

fns.EnableMapControls = function(inst, enable)
    inst.ismapcontrolsvisible:set(enable)
    OnPlayerHUDDirty(inst)
end

--------------------------------------------------------------------------

local function RegisterNetListeners_mastersim(inst)
-- ★★★ dirty 监听注册的第一组：只挂在服务端。
--
-- 【★这一组监听的不是 netvar 脏事件，而是「玩家实体的本地事件」】
-- 注意与第 1181 组的区别：
--   本组（mastersim）：监听玩家实体的事件（healthdelta、builditem 等），
--                    作用是把它们「翻译」成 netvar（第 27-35 行就是干这个的）。
--   第 1181 组（local）：监听 netvar 脏事件，作用是「消费」同步来的数据。
--   第 1218 组（common）：两端都监听，多数是 net_event 与 net_bool 的脏事件。
--
-- ★三组划分 = 服务端转译 / 客户端消费 / 双端共用，是本文件的主干架构。
-- 明确分开的好处：任何人都能立刻判断「这段逻辑该放哪组」。
--
-- 【★ListenForEvent 的第三参是 source】
-- 这里传 inst._parent，即「只监听父实体发来的事件」。
-- 这提供了事件来源过滤，避免误听同名字符串的其它事件。
    inst:ListenForEvent("forcehealthpulse", OnForceHealthPulse, inst._parent)
    inst:ListenForEvent("healthdelta", OnHealthDelta, inst._parent)
    inst:ListenForEvent("hungerdelta", OnHungerDelta, inst._parent)
    inst:ListenForEvent("sanitydelta", OnSanityDelta, inst._parent)
    inst:ListenForEvent("werenessdelta", OnWerenessDelta, inst._parent)
    inst:ListenForEvent("attacked", OnAttacked, inst._parent)
    inst:ListenForEvent("builditem", OnBuildSuccess, inst._parent)
    inst:ListenForEvent("buildstructure", OnBuildSuccess, inst._parent)
    inst:ListenForEvent("consumehealthcost", OnConsumeHealthCost, inst._parent)
    inst:ListenForEvent("learnrecipe", OnLearnRecipeSuccess, inst._parent)
    inst:ListenForEvent("learnmap", OnLearnMapSuccess, inst._parent)
    inst:ListenForEvent("repair", OnRepairSuccess, inst._parent)
    inst:ListenForEvent("performaction", OnPerformAction, inst._parent)
    inst:ListenForEvent("actionfailed", OnActionFailed, inst._parent)
    inst:ListenForEvent("carefulwalking", OnCarefulWalking, inst._parent)
    inst:ListenForEvent("wormholetravel", OnWormholeTravel, inst._parent)
    inst:ListenForEvent("makefriend", OnMakeFriend, inst._parent)
    inst:ListenForEvent("feedincontainer", OnFeedInContainer, inst._parent)
    inst:ListenForEvent("houndwarning", OnHoundWarning, inst._parent)
    inst:ListenForEvent("idplantseed", OnIdPlantSeed, inst._parent)
    inst:ListenForEvent("play_theme_music", fns.OnPlayThemeMusic, inst._parent)
    inst:ListenForEvent("craftedextraelixir", OnCraftedExtraElixir, inst._parent)
end

local function RegisterNetListeners_local(inst)
-- ★★★ 第二组：只挂在客户端，监听 netvar 脏事件（消费端）。
-- 全部是 *dirty 结尾的事件名，与 netvar 声明时传入的第三个参数一一对应。
--
-- 【★「事件名 = 声明时第三个参数」这条对应关系是理解本文件的钥匙】
-- 例如第 1341 行 net_ushortint(inst.GUID, "health.currenthealth", "healthdirty")
-- 的第三个参数 "healthdirty" 就是这里第 1182 行监听的名字。
-- ★每写一个 netvar 都要记得在两端登记它的脏事件，容易漏。
--
-- 【★第 1191-1193 行是「同一个回调带不同参数」的技巧】
-- 用匿名函数包一层把序号固定住，避免为三个字段写三个几乎一样的函数。
-- ★这种「绑定参数」的写法在事件系统里非常常用。
    inst:ListenForEvent("healthdirty", OnHealthDirty)
    inst:ListenForEvent("istakingfiredamagedirty", OnIsTakingFireDamageDirty)
    inst:ListenForEvent("istakingfiredamagelowdirty", OnIsTakingFireDamageLowDirty)
	inst:ListenForEvent("lunarburnflagsdirty", OnLunarBurnFlagsDirty)
    inst:ListenForEvent("combat.attackedpulse", OnAttackedPulseEvent)
    inst:ListenForEvent("hungerdirty", OnHungerDirty)
    inst:ListenForEvent("sanitydirty", OnSanityDirty)
    inst:ListenForEvent("werenessdirty", OnWerenessDirty)
    inst:ListenForEvent("inspirationdirty", fns.OnInspirationDirty)
    inst:ListenForEvent("inspirationsong1dirty", function(_inst) fns.OnInspirationSongsDirty(_inst, 1) end)
    inst:ListenForEvent("inspirationsong2dirty", function(_inst) fns.OnInspirationSongsDirty(_inst, 2) end)
    inst:ListenForEvent("inspirationsong3dirty", function(_inst) fns.OnInspirationSongsDirty(_inst, 3) end)
    inst:ListenForEvent("mightinessdirty", OnMightinessDirty)
    inst:ListenForEvent("freesoulhopsdirty", fns.OnFreeSoulhopsDirty)
    inst:ListenForEvent("temperaturedirty", OnTemperatureDirty)
    inst:ListenForEvent("moisturedirty", OnMoistureDirty)
    inst:ListenForEvent("techtreesdirty", OnTechTreesDirty)
    inst:ListenForEvent("recipesdirty", OnRecipesDirty)
	inst:ListenForEvent("iscraftingenableddirty", OnIsCraftingEnabledDirty)
    inst:ListenForEvent("bufferedbuildsdirty", OnBufferedBuildsDirty)
    inst:ListenForEvent("isperformactionsuccessdirty", OnIsPerformActionSuccessDirty)
    inst:ListenForEvent("pausepredictionframesdirty", OnPausePredictionFramesDirty)
	inst:ListenForEvent("isstrafingdirty", fns.OnIsStrafingDirty)
    inst:ListenForEvent("iscarefulwalkingdirty", OnIsCarefulWalkingDirty)
    inst:ListenForEvent("externalvelocityvectordirty", OnExternalVelocityVectorDirty)
	inst:ListenForEvent("playerspeedmultdirty", fns.OnPlayerSpeedMultDirty)
    inst:ListenForEvent("isghostmodedirty", OnGhostModeDirty)
    inst:ListenForEvent("actionmeterdirty", OnActionMeterDirty)
    inst:ListenForEvent("playerhuddirty", OnPlayerHUDDirty)
    inst:ListenForEvent("playercamerashake", OnPlayerCameraShake)
    inst:ListenForEvent("playerscreenflashdirty", OnPlayerScreenFlashDirty)
    inst:ListenForEvent("attunedresurrectordirty", OnAttunedResurrectorDirty)
    inst:ListenForEvent("cannondirty", fns.OnCannonDirty)
	inst:ListenForEvent("bathingpooldirty", fns.OnBathingPoolDirty)
end

local function RegisterNetListeners_common(inst)
-- ★★★ 第三组：两端都监听。
-- 这些多是 net_event（如 "builder.build"）与两端都要响应的 net_bool。
--
-- 【★为什么 net_event 监听名带点而 net_bool 监听名是短名】
-- 因为 net_event 的构造（netvars.lua:85-87）把事件名同时用作
-- net_bool 的名字与脏事件名，所以事件名就是那个点分全名。
-- 而普通 net_bool 的脏事件名是作者自己指定的，可以是短名。
-- ★这个不对称是 net_event 实现细节的副产物，容易看混。
    inst:ListenForEvent("gym_bell_start", fns.OnGymBellStart)
    inst:ListenForEvent("playworkcritsound", fns.PlayCritWorkSound)
    inst:ListenForEvent("inmightygymdirty", fns.InMightyGymDirty)
    inst:ListenForEvent("stormleveldirty", OnStormLevelDirty)
    inst:ListenForEvent("isinmiasmadirty", fns.OnIsInMiasmaDirty)
    inst:ListenForEvent("isacidsizzlingdirty", fns.OnIsAcidSizzlingDirty)
    inst:ListenForEvent("hasinspirationbuffdirty", fns.OnHasInspirationBuffDirty)
    inst:ListenForEvent("builder.build", OnBuildEvent)
    inst:ListenForEvent("builder.damaged", OnBuilderDamagedEvent)
    inst:ListenForEvent("builder.opencraftingmenu", OnOpenCraftingMenuEvent)
    inst:ListenForEvent("builder.learnrecipe", OnLearnRecipeEvent)
    inst:ListenForEvent("inked", OnInkedEvent)
    inst:ListenForEvent("MapExplorer.learnmap", OnLearnMapEvent)
    inst:ListenForEvent("MapSpotRevealer.revealmapspot", OnRevealMapSpotEvent)
    inst:ListenForEvent("repair.repair", OnRepairEvent)
    inst:ListenForEvent("giftsdirty", OnGiftsDirty)
    inst:ListenForEvent("yotbskindirty", fns.OnYotbSkinDirty)
    inst:ListenForEvent("ismounthurtdirty", OnMountHurtDirty)
    inst:ListenForEvent("playercameradirty", OnPlayerCameraDirty)
	inst:ListenForEvent("playeraerialcameradirty", OnPlayerAerialCameraDirty)
    inst:ListenForEvent("playercameraextradistdirty", fns.OnPlayerCameraExtraDistDirty)
    inst:ListenForEvent("playercamerasnap", OnPlayerCameraSnap)
    inst:ListenForEvent("playerminimapcenter", OnPlayerMinimapCenter)
    inst:ListenForEvent("playerminimapclose", OnPlayerMinimapClose)
    inst:ListenForEvent("playerfadedirty", OnPlayerFadeDirty)
    inst:ListenForEvent("wormholetraveldirty", OnWormholeTravelDirty)
    inst:ListenForEvent("leader.makefriend", OnMakeFriendEvent)
    inst:ListenForEvent("eater.feedincontainer", OnFeedInContainerEvent)
    inst:ListenForEvent("morguedirty", OnMorgueDirty)
    inst:ListenForEvent("houndwarningdirty", OnHoundWarningDirty)
    inst:ListenForEvent("idplantseedevent", fns.OnIdPlantSeedEvent)
    inst:ListenForEvent("startfarmingmusicevent", fns.StartFarmingMusicEvent)
    inst:ListenForEvent("ingredientmoddirty", fns.RefreshCrafting)
    inst:ListenForEvent("inspectacles_gamedirty", fns.OnInspectaclesGameDirty)
    inst:ListenForEvent("roseglasses_cooldowndirty", fns.OnRoseGlassesCooldownDirty)
    inst:ListenForEvent("wortoxpanflutebuffdirty", fns.OnWortoxPanfluteBuffDirty)
    inst:ListenForEvent("craftedextraelixirdirty",fns.OnCraftedExtraElixirDirty)
end

local function RegisterNetListeners(inst)
-- ★ 注册总入口。按端分流，再统一补 common 组。
-- 【★顺序很重要：先分流注册，再 OnInitialDirtyStates 补一次全量刷新】
-- 因为初始反序列化只会触发「值确实变化过」的脏事件，
-- 若某字段初值恰好等于服务端默认值，就不会触发任何事件，
-- 于是客户端的 UI 可能停在「未初始化」状态。
-- OnInitialDirtyStates 强制把所有派生状态重算一遍，补上这个缺口。
-- ★这是「增量同步必须配一次全量对齐」的典型，漏了就是偶发 UI 不刷新。
    if TheWorld.ismastersim then
        inst._parent = inst.entity:GetParent()
        RegisterNetListeners_mastersim(inst)
    else
        inst.ishealthpulseup:set_local(false)
        inst.ishealthpulsedown:set_local(false)
        inst.ishungerpulseup:set_local(false)
        inst.ishungerpulsedown:set_local(false)
        inst.issanitypulseup:set_local(false)
        inst.issanitypulsedown:set_local(false)
        inst.iswerenesspulseup:set_local(false)
        inst.iswerenesspulsedown:set_local(false)
        inst.pausepredictionframes:set_local(0)
        RegisterNetListeners_local(inst)
    end

    RegisterNetListeners_common(inst)

    fns.OnInitialDirtyStates(inst)

    if inst._parent.isseamlessswaptarget then
        --finishseamlessplayerswap will be able to retrigger all the instant events if the initialization happened in the "wrong"" order.
        inst:ListenForEvent("finishseamlessplayerswap", fns.FinishSeamlessPlayerSwap, inst._parent)
        --Fade is initialized by OnPlayerActivated in gamelogic.lua
    end
end

function fns.OnInitialDirtyStates(inst)
-- ★★ 强制重算所有派生状态的兜底函数。
-- 【★为什么必须有这一步（增量同步的固有缺口）】
-- 脏事件只在「值变了」时触发。但实体刚上线时，
-- 所有字段都是从「默认零值」变成「真实值」，理论上都会触发。
-- 然而若某字段的真实值恰好等于默认值（如 maxhealth 恰好 100），
-- 引擎认为「没变」，就不会触发脏事件，客户端就漏掉了这次初始化。
--
-- 【★所以影子变量必须在这一步初始化，不能留 0】
-- 见下方第 1292 行起：_oldhealthpercent 等全部在此赋值。
-- 若留默认值 0，第一次真正的掉血会算出「从 0% 掉到 70%」，
-- 播出一段夸张的假动画。
--
-- 【★移植要点：增量属性同步系统必须提供「强制全量重算」API】
-- 且所有缓存派生值的影子副本都要在其中初始化。
-- 这是最容易漏、且只在特定初始值下才暴露的坑。
    if not TheWorld.ismastersim then
        OnIsTakingFireDamageDirty(inst)
		OnLunarBurnFlagsDirty(inst)
        OnTemperatureDirty(inst)
        OnTechTreesDirty(inst)
        if inst._parent ~= nil then
-- ★ 逐项初始化影子副本，值与当前 netvar 一致（即「无变化」）。
-- `maxhealth > 0 and ... or 0` 防止除零：maxhealth 可能尚未同步到位。
-- ★ 这是防御式写法：先假设可能是 0，避免初始化期除零得 nan。
-- nan 一旦混入影子变量，之后所有比较都为 false，动画将永久停摆。
--
-- wereness/inspiration/mightiness 乘 0.01：这三个字段是 0..100 存储，
-- 影子按 0..1 存百分比，与健康/饥饿的存储口径不同。
-- ★同一文件里影子口径不统一，容易看错，移植时建议统一。
            inst._oldhealthpercent = inst.maxhealth:value() > 0 and inst.currenthealth:value() / inst.maxhealth:value() or 0
            inst._oldhungerpercent = inst.maxhunger:value() > 0 and inst.currenthunger:value() / inst.maxhunger:value() or 0
            inst._oldsanitypercent = inst.maxsanity:value() > 0 and inst.currentsanity:value() / inst.maxsanity:value() or 0
            inst._oldwerenesspercent = inst.currentwereness:value() * .01
            inst._oldinspirationpercent = inst.currentinspiration:value() * .01
            inst._oldmightinesspercent = inst.currentmightiness:value() * .01
            inst._oldmoisture = inst.moisture:value()
            UpdateAnimOverrideSanity(inst._parent)
        end
		fns.OnIsStrafingDirty(inst)
    end

    OnStormLevelDirty(inst)
    fns.OnIsInMiasmaDirty(inst)
    fns.OnIsAcidSizzlingDirty(inst)
    fns.OnInspectaclesGameDirty(inst)
    fns.OnRoseGlassesCooldownDirty(inst)
    fns.OnWortoxPanfluteBuffDirty(inst)
    OnGiftsDirty(inst)
    fns.OnYotbSkinDirty(inst)
    OnMountHurtDirty(inst)
    OnGhostModeDirty(inst)
	OnIsCraftingEnabledDirty(inst)
    OnPlayerHUDDirty(inst)
    OnPlayerCameraDirty(inst)
	OnPlayerAerialCameraDirty(inst)
    fns.OnPlayerCameraExtraDistDirty(inst, true)
end

fns.FinishSeamlessPlayerSwap = function(parent)
    local inst = parent.player_classified
    inst:RemoveEventCallback("finishseamlessplayerswap", fns.FinishSeamlessPlayerSwap, parent)
    fns.OnInitialDirtyStates(inst)
end

--------------------------------------------------------------------------

local function fn()
-- ★★★★★ 1330-1633 行是全工程规模最大的 netvar 声明区（约 190 行、123 处声明）。
-- 这是「wire format」最真实的落地形态，下面把它的组织规律讲透。
--
-- 【★规律一：严格按「子系统」分块，块间空行 + 注释标题】
-- Health / Hunger / Sanity / Wereness / inspiration / Mightiness /
-- Temperature / Moisture / StormWatcher / MiasmaWatcher / AcidRain /
-- PlayerController / PlayerVoter / Player HUD / Player camera /
-- Player minimap / Player front end / Builder / MapExplorer /
-- Combat / Leader / Eater / Rider / TouchStoneTracker /
-- Stategraph / Locomotor / PlayerSpeedMult / Morgue ...
--
-- 【★为什么必须分块：这是「声明顺序即 wire format」的硬约束】
-- 两端必须以完全相同的顺序声明完全相同的字段组，否则反序列化整体错位。
-- 分块 + 明确标题，让「在这块中间插入新字段」变成需要三思的操作。
-- ★若想新增字段，最安全的位置是「某块的末尾」，而不是块中间。
--
-- 【★规律二：类型选择极度克制，绝大多数用最窄类型】
-- 枚举与标志位 → net_bool（1 位）/ net_tinybyte（3 位）
-- 小计数     → net_byte（8 位）/ net_smallbyte（6 位）
-- 常规数值   → net_ushortint（16 位）
-- 连续量     → net_float（32 位）
-- 字符串     → net_hash（32 位哈希，写入侧可给字符串）
-- 实体引用   → net_entity
-- 一次性动作 → net_event（net_bool 的语法糖）
--
-- 【★规律三：第三参数（脏事件名）大量复用，一个事件管一组字段】
-- 例如 health 的 5 个字段共用 "healthdirty"；
--      sanity 的 5 个字段共用 "sanitydirty"。
-- 【★为什么复用是对的：这些字段逻辑上总是一起变、一起刷新 UI】
-- 若每个字段一个事件，同一次掉血会触发 5 次 UI 重算。
-- 合并成一个事件，UI 只重算一次 —— 脏事件合并的标准做法。
-- ★对照 clock.lua 的做法（每个字段一个独立 dirty，再置标志位合并），
--   两种策略各有优劣：这里靠「命名复用」合并，clock 靠「标志位」合并。
    local inst = CreateEntity()

    inst.entity:AddTransform() --So we can follow parent's sleep state
-- ★ AddTransform：让 classified 能跟随父实体的位置与休眠状态。
-- 【★但注意本文件第 1336 行还调用了 Hide()】
-- 即「有位置、无渲染」—— 它必须跟随（否则 UI 定位会错），但不可见。
-- ★这是 classified 的通用特征：逻辑在场，视觉缺席。
    inst.entity:AddMapExplorer()
    inst.entity:AddNetwork()
-- ★ AddNetwork —— classified 之所以能被全服看到，全靠这一行。
-- 没有它，123 个 netvar 都不会被同步。
    inst.entity:Hide()
-- 立即隐藏。★注意位置在 AddNetwork 之后 ——
-- 网络实体即使隐藏也照常同步，这是 classified 成立的前提。
-- 「隐藏」只影响本地渲染，不影响网络可见性。
    inst:AddTag("CLASSIFIED")
-- ★ 打 CLASSIFIED 标签 —— 触发 entityreplica 的 classified 分发逻辑
-- （见 entityreplica.lua:87-95 与第 247 行的 OnEntityReplicated）。
-- ★这是 classified 机制的总开关，漏了它整个机制不生效。

    --Health variables
    inst._oldhealthpercent = 1
-- ★ _oldhealthpercent = 1：影子副本初值 1（满血）。
-- 【★注意这个初值会在第 1292 行的 OnInitialDirtyStates 里被真实值覆盖】
-- 这里的 1 只是构造期的占位，避免 nil 运算。
-- 影子变量一律不发网络，纯本地用途 —— 记住这一点能省很多困惑。
    inst.currenthealth = net_ushortint(inst.GUID, "health.currenthealth", "healthdirty")
-- ★★★ net_ushortint 而非 net_int：血量上限几千，16 位足够，省一半带宽。
-- 【★第 11 行 SetValue 的断言正好印证：0 <= value <= 65535】
-- ★类型选择与断言范围必须一致，这是一处交叉验证。
-- 若哪天血量上限要超过 65535，此处与断言必须同时改。
--
-- 第 3 参 "healthdirty" 对应第 1182 行的监听。
    inst.maxhealth = net_ushortint(inst.GUID, "health.maxhealth", "healthdirty")
    inst.healthpenalty = net_byte(inst.GUID, "health.penalty", "healthdirty")
-- net_byte（8 位）：血量惩罚值范围小，无需 ushort。
-- ★第 1341/1342 行是 ushort，本行是 byte —— 同一块内按值域分别选型，
--   正是 netvars.lua:97 GetIdealUnsignedNetVarForCount 的思想。
    inst.istakingfiredamage = net_bool(inst.GUID, "health.takingfiredamage", "istakingfiredamagedirty")
    inst.istakingfiredamagelow = net_bool(inst.GUID, "health.takingfiredamagelow", "istakingfiredamagelowdirty")
    inst.issleephealing = net_bool(inst.GUID, "health.healthsleep")
-- ★ 本行第三个参数只有两个 —— net_bool 不注册脏事件。
-- 【★为什么可以不要脏事件】
-- 因为睡眠回血不驱动任何 UI，只是服务端内部状态。
-- 客户端不需要知道「玩家在睡觉回血」，只要同步最终血量即可。
-- ★不给不需要的状态注册脏事件，是最省成本的优化。
    inst.ishealthpulseup = net_bool(inst.GUID, "health.dodeltaovertime(up)", "healthdirty")
    inst.ishealthpulsedown = net_bool(inst.GUID, "health.dodeltaovertime(down)", "healthdirty")
	inst.lunarburnflags = net_tinybyte(inst.GUID, "health.lunarburnflags", "lunarburnflagsdirty")
-- ★★ 本行用的是 Tab 缩进（与上下文空格缩进不一致）。
-- 全文件大量混用 Tab 与空格（如 1349、1358、1355、1408 等行）。
-- ⚠️ 在 Lua 里这不影响语法（Lua 不care 缩进），但会给 diff 与编辑器造成噪音。
-- 我核实过：本文件确实混用，属既有风格，非本次引入。
-- ★移植建议：统一用空格，避免团队协作时的隐形冲突。
    inst.currenthealth:set(100)
-- ★ 声明完立刻 set 初值。两个 set 连写，中间无注释。
-- 【★必须 set：netvar 的 Lua 侧默认值是 nil 或 0，不主动初始化会导致】
--   ① 服务端首帧读到 nil，运算崩；
--   ② 客户端反序列化前若已有代码读 value()，得到 nil。
-- ★「声明 + 立即赋初值」应视为一体，这是本文件的硬性写法规范。
    inst.maxhealth:set(100)

    --Hunger variables
    inst._oldhungerpercent = 1
    inst.currenthunger = net_ushortint(inst.GUID, "hunger.current", "hungerdirty")
    inst.maxhunger = net_ushortint(inst.GUID, "hunger.max", "hungerdirty")
    inst.ishungerpulseup = net_bool(inst.GUID, "hunger.dodeltaovertime(up)", "hungerdirty")
    inst.ishungerpulsedown = net_bool(inst.GUID, "hunger.dodeltaovertime(down)", "hungerdirty")
    inst.currenthunger:set(100)
    inst.maxhunger:set(100)

    --Sanity variables
    inst._oldsanitypercent = 1
    inst.currentsanity = net_ushortint(inst.GUID, "sanity.current", "sanitydirty")
    inst.maxsanity = net_ushortint(inst.GUID, "sanity.max", "sanitydirty")
    inst.sanitypenalty = net_byte(inst.GUID, "sanity.penalty", "sanitydirty")
    inst.sanityratescale = net_tinybyte(inst.GUID, "sanity.ratescale")
    inst.issanitypulseup = net_bool(inst.GUID, "sanity.dodeltaovertime(up)", "sanitydirty")
    inst.issanitypulsedown = net_bool(inst.GUID, "sanity.dodeltaovertime(down)", "sanitydirty")
    inst.issanityghostdrain = net_bool(inst.GUID, "sanity.ghostdrain")
    inst.currentsanity:set(100)
    inst.maxsanity:set(100)

    --Wereness variables
    inst._oldwerenesspercent = 0
    inst.currentwereness = net_byte(inst.GUID, "wereness.current", "werenessdirty")
    inst.iswerenesspulseup = net_bool(inst.GUID, "wereness.dodeltaovertime(up)", "werenessdirty")
    inst.iswerenesspulsedown = net_bool(inst.GUID, "wereness.dodeltaovertime(down)", "werenessdirty")
    inst.werenessdrainrate = net_smallbyte(inst.GUID, "wereness.drainrate")

    --inspiration variables
    inst._oldinspirationpercent = 0
    inst.currentinspiration = net_byte(inst.GUID, "inspiration.current", "inspirationdirty")
    inst.inspirationdraining = net_bool(inst.GUID, "inspiration.draining", "inspirationdirty")
    inst.inspirationsongs =
-- ★ 数组形式的 netvar 声明：三个 net_tinybyte 收在一个 Lua 表里。
-- 【★为什么用 net_tinybyte：歌曲索引只有 0..2，3 位足够】
-- ★若图省事用 net_byte 就是 8 倍浪费；用 net_int 更是 100 倍。
--
-- 【★三个字段共用不同的脏事件名（song1/2/3dirty）】
-- 与 health 那种「共用一个 dirty」不同 —— 因为要能定位是哪一首变了，
-- 于是在第 1191-1193 行用带参匿名函数分别绑定序号。
-- ★取舍：合并 dirty 省开销，分离 dirty 省代码。取决于下游要什么信息。
    {
        net_tinybyte(inst.GUID, "inspiration.song1", "inspirationsong1dirty"),
        net_tinybyte(inst.GUID, "inspiration.song2", "inspirationsong2dirty"),
        net_tinybyte(inst.GUID, "inspiration.song3", "inspirationsong3dirty"),
    }
    inst.hasinspirationbuff = net_bool(inst.GUID, "inspiration.hasbuff", "hasinspirationbuffdirty")

    -- Mightiness
    --mighty gym variables
    -- this is used to know if someone is on a gym but also what the weight on the gym is when used.
    -- 0 = not on a gym
-- ★★ 用注释把 net_tinybyte 的编码约定写死：
--   0 = 不在健身房；1-7 = 在健身房且配重为 x+1（即实际值 2..8）。
-- 【★「用 0 当哨兵、实际值整体 +1」是紧凑编码的经典手法】
-- 好处：0 同时表达了「无」与「哨兵」，不需要额外字段。
-- 代价：可读性下降 —— 所以必须配这样的注释。
-- ★移植启示：压缩编码时，务必把编码规则写在字段旁边，
--   否则后来者要读解码函数才能理解。
    -- 1 - 7 .. on a gym and the weight is x + 1. So values of 2 to 8
    inst.inmightygym = net_tinybyte(inst.GUID, "mightygym.in", "inmightygymdirty")
    inst.inmightygym:set(0)


    inst.gym_bell_start = net_event(inst.GUID, "gym_bell_start")
-- ★★ net_event 用于「一次性动作」：铃响、暴击音效。
-- 对应第 1219-1220 行的 common 监听（两端都响应）。
-- 【★对照第 1404 行的 currentmightiness（状态）—— 同一子系统里】
--   动作用 net_event，状态用 net_bool / net_byte。
-- 严格遵循 netvars.lua:78-79 那条「事件与状态必须分开」的规则。
    inst.playworkcritsound = net_event(inst.GUID, "playworkcritsound")
    inst.currentmightiness = net_byte(inst.GUID, "mightiness.current", "mightinessdirty")
    inst.mightinessratescale = net_tinybyte(inst.GUID, "mightiness.ratescale")

    -- Wortox Soulhop free counter
    inst.freesoulhops = net_tinybyte(inst.GUID, "freesoulhops", "freesoulhopsdirty")
    inst.freesoulhops:set(0)
    -- Wortox buff
    inst.wortox_panflute_buff = net_bool(inst.GUID, "wortox_panflute_buff", "wortoxpanflutebuffdirty")
    inst.wortox_panflute_buff:set(false)

    -- Winona inspectacles
    inst.inspectacles_game = net_tinybyte(inst.GUID, "inspectacles_game", "inspectacles_gamedirty")
    inst.inspectacles_game:set(0)
    inst.inspectacles_posx = net_shortint(inst.GUID, "inspectacles_posx", "inspectacles_posxdirty")
    inst.inspectacles_posz = net_shortint(inst.GUID, "inspectacles_posz", "inspectacles_poszdirty")
    inst.inspectacles_posx:set(0)
    inst.inspectacles_posz:set(0)
    -- Winona rose glasses
    inst.roseglasses_cooldown = net_bool(inst.GUID, "roseglasses_cooldown", "roseglasses_cooldowndirty")

    -- oldager
    inst.oldager_yearpercent = net_float(inst.GUID, "oldager.yearpercent")
    inst.oldager_rate = net_smallbyte(inst.GUID, "oldager.rate") -- use the Get and Set functions because this value is a signed value incoded into an unsigned net_var
-- ★★★ net_smallbyte 承载「有符号值」，且注释明确要求用 Get/Set 函数。
-- 【★因为 smallbyte 是无符号（[0..63]），而 oldager_rate 需要负数】
-- 手法是「把有符号值偏移编码进无符号域」，读写时再解码。
-- 第 213 行 SetOldagerRate / 第 218 行 GetOldagerRate 承担编解码。
--
-- 【★移植要点：带符号小整数怎么过无符号 wire 通道】
-- 标准做法就是「加一个固定偏移量 (MAX+1)」，两端对称即可。
-- 代价是取值范围被腰斩（0..63 只能表示 -32..31）。
-- 若值域不够，第一反应应该是换更宽的无符号类型，而不是继续压。
    inst.GetOldagerRate = fns.GetOldagerRate

    --Temperature variables
    inst._oldtemperature = TUNING.STARTING_TEMP
    inst.currenttemperature = inst._oldtemperature
    inst.currenttemperaturedata = net_byte(inst.GUID, "temperature.current", "temperaturedirty")
-- ★ 温度用 net_byte 存「离散化后的编码值」，而非直接存 float。
-- 第 203 行 SetTemperature 负责编码，第 237 行 DeserializeTemperature 负责解码。
-- 【★为什么要离散化：带宽 + 抗噪】
-- float 需 32 位；byte 只需 8 位。玩家体感不需要 0.01 度精度，
-- 量化到「以 min_precision_temp 为步长的整数档」完全够用。
-- 副作用：客户端温度值是离散的，温度变化动画会呈阶梯状 —— 恰好也省了动画成本。
-- ★这是「按客户端实际需要的精度选类型」，与 netvars 的选型哲学一致。
    SetTemperature(inst, inst.currenttemperature)

    --Moisture variables
    inst._oldmoisture = 0
    inst.moisture = net_ushortint(inst.GUID, "moisture.moisture", "moisturedirty")
    inst.maxmoisture = net_ushortint(inst.GUID, "moisture.maxmoisture")
-- ★ maxmoisture 没有第三个参数 —— 不注册脏事件。
-- 与 maxhealth（第 1342 行注册了 healthdirty）不同。
-- 推测因为湿度上限变化不需要触发 UI 刷新（湿度条长度固定）。
-- ★同类字段不同处理，说明「要不要脏事件」是逐字段判断的，不是成块套用。
    inst.moistureratescale = net_tinybyte(inst.GUID, "moisture.ratescale", "moisturedirty")
    inst.maxmoisture:set(100)

    --StormWatcher variables
    inst.stormlevel = net_tinybyte(inst.GUID, "stormwatcher.stormlevel", "stormleveldirty")
    inst.stormtype = net_tinybyte(inst.GUID, "stormwatcher.stormtype")

    --MiasmaWatcher variables
    inst.isinmiasma = net_bool(inst.GUID, "miasmawatcher.isinmiasma", "isinmiasmadirty")

    -- AcidRain variables
    inst.isacidsizzling = net_bool(inst.GUID, "acidrain.isacidsizzling", "isacidsizzlingdirty")

    --Inked variables
    inst.inked = net_event(inst.GUID, "inked")
-- net_event：上墨事件（一次性）。

    --PlayerController variables
    inst._pausepredictiontask = nil
    inst.pausepredictionframes = net_tinybyte(inst.GUID, "playercontroller.pausepredictionframes", "pausepredictionframesdirty")
    inst.iscontrollerenabled = net_bool(inst.GUID, "playercontroller.enabled")
    inst.iscontrollerenabled:set(true)

    --PlayerVoter variables
    inst.voteselection = net_tinybyte(inst.GUID, "playervoter.selection", "voteselectiondirty")
    inst.votesquelched = net_bool(inst.GUID, "playervoter.issquelched")

    --Player HUD variables
    inst.ishudvisible = net_bool(inst.GUID, "playerhud.isvisible", "playerhuddirty")
    inst.ismapcontrolsvisible = net_bool(inst.GUID, "playerhud.ismapcontrolsvisible", "playerhuddirty")
    inst.isactionsvisible = net_bool(inst.GUID, "playerhud.isactionsvisible")
    inst.ishudvisible:set(true)
    inst.ismapcontrolsvisible:set(true)
    inst.isactionsvisible:set(true)

    --Player camera variables
    inst.cameradistance = net_smallbyte(inst.GUID, "playercamera.distance", "playercameradirty")
    inst.iscamerazoomed = net_bool(inst.GUID, "playercamera.iscamerazoomed", "playercameradirty")
    inst.cameraextramaxdist = net_smallbyte(inst.GUID, "playercamera.extramaxdist", "playercameraextradistdirty")
    inst.camerasnap = net_bool(inst.GUID, "playercamera.snap", "playercamerasnap")
    inst.camerashakemode = net_tinybyte(inst.GUID, "playercamera.shakemode", "playercamerashake")
    inst.camerashaketime = net_byte(inst.GUID, "playercamera.shaketime")
    inst.camerashakespeed = net_byte(inst.GUID, "playercamera.shakespeed")
    inst.camerashakescale = net_byte(inst.GUID, "playercamera.shakescale")
	inst.isaerialcamera = net_bool(inst.GUID, "playercamera.isaerialcamera", "playeraerialcameradirty")

    --Player minimap variables
    inst.minimapcenter = net_bool(inst.GUID, "playerminimap.center", "playerminimapcenter")
    inst.minimapclose = net_bool(inst.GUID, "playerminimap.close", "playerminimapclose")

    --Player front end variables
    inst.isfadein = net_bool(inst.GUID, "frontend.isfadein", "playerfadedirty")
    inst.fadetime = net_smallbyte(inst.GUID, "frontend.fadetime", "playerfadedirty")
    inst.screenflash = net_tinybyte(inst.GUID, "frontend.screenflash", "playerscreenflashdirty")
    inst.wormholetravelevent = net_tinybyte(inst.GUID, "frontend.wormholetravel", "wormholetraveldirty")
    inst.houndwarningevent = net_smallbyte(inst.GUID, "frontend.houndwarning", "houndwarningdirty")
    inst.idplantseedevent = net_event(inst.GUID, "idplantseedevent")
    inst.craftedextraelixirevent = net_smallbyte(inst.GUID, "frontend.craftedextraelixir", "craftedextraelixirdirty")

    -- busy theme music
    inst.start_farming_music = net_event(inst.GUID, "startfarmingmusicevent")

    inst.isfadein:set(true)

    --Builder variables
    inst.buildevent = net_event(inst.GUID, "builder.build")
    inst.builderdamagedevent = net_event(inst.GUID, "builder.damaged")
    inst.learnrecipeevent = net_event(inst.GUID, "builder.learnrecipe")
    inst.techtrees = deepcopy(TECH.NONE)
    inst.techtrees_no_temp = deepcopy(inst.techtrees)
    inst.ingredientmod = net_tinybyte(inst.GUID, "builder.ingredientmod", "ingredientmoddirty")
    for i, v in ipairs(TechTree.BONUS_TECH) do
-- ★★★ 循环里动态声明 netvar（两块砖：bonus 与 tempbonus）。
-- 【★这种「按数据表长度动态生成 netvar」是本文件最高级的技巧】
-- 加一个新科技点，无需新增 netvar 声明行，改数据表即可自动生效。
-- ★但代价是 wire format 依赖「数据表遍历顺序」。
-- 用 ipairs 保证两端顺序一致（TechTree.BONUS_TECH 是有序数组）。
-- ⚠️ 若把这里改成 pairs，顺序将不确定，两端 wire format 立即错位。
-- ★这就是 netvars.lua:29-32 那条「两端必须一致」约束的最危险形态：
--   它不只约束「写了几行代码」，还约束「数据表的遍历顺序」。
        local bonus = net_tinybyte(inst.GUID, "builder."..string.lower(v).."bonus")
        inst[TechTree.AVAILABLE_TECH_BONUS_CLASSIFIED[v] or string.lower(v).."bonus"] = bonus
        local tempbonus = net_tinybyte(inst.GUID, "builder."..string.lower(v).."tempbonus", "techtreesdirty")
        inst[TechTree.AVAILABLE_TECH_TEMPBONUS_CLASSIFIED[v] or string.lower(v).."tempbonus"] = tempbonus
    end
    for i, v in ipairs(TechTree.AVAILABLE_TECH) do
-- 第二块：科技等级。同样用 ipairs 保序。
-- 第 1517 行注意：这里用 level:set(...) 立即赋值，因为要拷贝本地 techtrees 的初值。
        local level = net_tinybyte(inst.GUID, "builder.accessible_tech_trees."..v, "techtreesdirty")
        level:set(inst.techtrees[v])
        inst[TechTree.AVAILABLE_TECH_LEVEL_CLASSIFIED[v] or string.lower(v).."level"] = level
    end
    inst.isfreebuildmode = net_bool(inst.GUID, "builder.freebuildmode", "recipesdirty")
    inst.current_prototyper = net_entity(inst.GUID, "builder.current_prototyper", "current_prototyper_dirty")
    inst.opencraftingmenuevent = net_event(inst.GUID, "builder.opencraftingmenu")
	inst.iscraftingenabled = net_bool(inst.GUID, "builder.iscraftingenabled", "iscraftingenableddirty")
	inst.iscraftingenabled:set(true)
    inst.recipes = {}
    inst.bufferedbuilds = {}
    for k, v in pairs(AllRecipes) do
        if IsRecipeValid(v.name) then
            inst.recipes[k] = net_bool(inst.GUID, "builder.recipes["..k.."]", "recipesdirty")
-- ★★★ 最大的动态声明：按 AllRecipes 全量生成「已解锁」布尔字段。
-- 【★每个配方一个 net_bool —— 全工程最典型的「稀疏布尔数组」编码】
-- 好处：加配方（模组）自动获得同步字段，无需改本文件。
-- 代价：★带宽与配方总数成正比，而非与「已解锁数量」成正比。
-- 一个 1000 配制的模组 = 1000 个 net_bool 常驻。
--
-- 【★权衡：这是「扩展性」换「固定开销」的典型交易】
-- 更省的方案是「只同步已解锁项的索引列表」，但那样无法区分
-- 「未解锁」与「不存在」，且列表长度本身会变动，实现复杂度高得多。
-- DST 选了简单方案：稀疏布尔数组。60 人局每人一份，
-- 靠 net_bool 的 1 位宽度把成本压到可接受。
-- ★自研引擎若面对类似场景，值得先算一遍：n 个 bool × 每秒同步频率 × 人数。
--
-- 三块配方相关字段（recipes / bufferedbuilds / craftinglimit）**共用**
-- "recipesdirty" 与 "bufferedbuildsdirty" 两个事件名 —— 合并派发。
            inst.bufferedbuilds[k] = net_bool(inst.GUID, "builder.buffered_builds["..k.."]", "bufferedbuildsdirty")
        end
    end
    inst.craftinglimit_recipe = {}
    inst.craftinglimit_amount = {}
    local craftinglimit_net_enum = GetIdealUnsignedNetVarForCount(CRAFTINGSTATION_LIMITED_RECIPES_COUNT)
-- ★★ 全工程唯一使用 GetIdealUnsignedNetVarForCount 的地方。
-- 【★严格遵循了 netvars.lua:96 那条约定：变量名以 _net_enum 结尾】
-- `craftinglimit_net_enum` —— 完全符合原文「便于全文检索」的要求。
--
-- 【★为什么这里需要动态选宽度：数量由常量给定，先算宽度再声明】
-- 若 CRAFTINGSTATION_LIMITED_RECIPES_COUNT <= 7，只需 3 位；
-- 若它变大，宽度自动升级，无需改代码。
-- ★这是把 netvars.lua:97 那个工具函数用在了最该用的地方。
    for i = 1, CRAFTINGSTATION_LIMITED_RECIPES_COUNT do
        inst.craftinglimit_recipe[i] = craftinglimit_net_enum(inst.GUID, "builder.craftinglimit_recipe[" .. i .. "]", "recipesdirty")
-- 用动态选出的宽度声明受限配方索引。第 i 个配方一个字段。
-- 【★索引为何用窄类型、数量用 net_byte】
-- 索引是「第几个」，值域小；数量可能超过 255 的注释说明是 255 上限。
-- ★同一循环里两种类型，正是「按值域分别选型」。
        inst.craftinglimit_amount[i] = net_byte(inst.GUID, "builder.craftinglimit_amount[" .. i .. "]", "recipesdirty") -- 255 max.
    end
    inst.ingredientmod:set(INGREDIENT_MOD[1])

    --MapExplorer variables
    inst.learnmapevent = net_event(inst.GUID, "MapExplorer.learnmap")

    --MapSpotRevealer variables
    inst.revealmapspotevent = net_event(inst.GUID, "MapSpotRevealer.revealmapspot")
    inst.revealmapspot_worldx = net_float(inst.GUID, "MapSpotRevealer.worldx")--note from branch: "second argument?"
    inst.revealmapspot_worldz = net_float(inst.GUID, "MapSpotRevealer.worldz")

    --Repair variables
    inst.repairevent = net_event(inst.GUID, "repair.repair")

    -- Groomer variables
    inst.hasyotbskin = net_bool(inst.GUID, "groomer.hasyotbskin", "yotbskindirty")

    --GiftReceiver variables
    inst.hasgift = net_bool(inst.GUID, "giftreceiver.hasgift", "giftsdirty")
    inst.hasgiftmachine = net_bool(inst.GUID, "giftreceiver.hasgiftmachine", "giftsdirty")

    --Combat variables
    inst.lastcombattarget = net_entity(inst.GUID, "combat.lasttarget")
    inst.canattack = net_bool(inst.GUID, "combat.canattack")
    inst.minattackperiod = net_float(inst.GUID, "combat.minattackperiod")
    inst.attackedpulseevent = net_event(inst.GUID, "combat.attackedpulse")
    inst.isattackedbydanger = net_bool(inst.GUID, "combat.isattackedbydanger")
    inst.isattackredirected = net_bool(inst.GUID, "combat.isattackredirected")
    inst.canattack:set(true)
    inst.minattackperiod:set(4)

    --Leader variables
    inst.makefriendevent = net_event(inst.GUID, "leader.makefriend")

    --Eater variables (more like feeding) (more like an event for playing a client sound)
    inst.feedincontainerevent = net_event(inst.GUID, "eater.feedincontainer")

    --Rider variables
    inst.ridermount = net_entity(inst.GUID, "rider.mount")
    inst.ridersaddle = net_entity(inst.GUID, "rider.saddle")
    inst.isridermounthurt = net_bool(inst.GUID, "rider.mounthurt", "ismounthurtdirty")
    inst.riderrunspeed = net_float(inst.GUID, "rider.runspeed")
    inst.riderfasteronroad = net_bool(inst.GUID, "rider.fasteronroad")
    inst.riderrunspeed:set(TUNING.BEEFALO_RUN_SPEED.DEFAULT) --V2C: just pick the most likely value to be the default for pristine state

    --TouchStoneTracker variables
    inst.touchstonetrackerused = net_smallbytearray(inst.GUID, "touchstonetracker.used")
-- ★★ 全文件唯一使用 net_smallbytearray 的地方。
-- netvars.lua:19-20 定义的数组类型，最大长度 31。
-- 【★为什么这里用数组而不是「每个石头一个 net_bool」】
-- 用过的石头数量可能很多，逐个布尔字段会像配方那样爆炸。
-- 数组在这里更合适 —— 变长存储，只同步实际数量。
--
-- 【★但要注意 netvars.lua:22-23 的警告：Arrays are expensive】
-- 原文建议避免在「值经常变」的场景用数组。
-- 「用过哪些石头」属于低频变化（收集一次改一次），所以此处是合理用法。
-- ★判断标准：低频变动的集合用数组，高频且稀疏的集合用布尔字段。
--   触石追踪器是前者，玩家配方是后者 —— 两个案例正好构成对照。

    --Stategraph variables
    inst.isperformactionsuccess = net_bool(inst.GUID, "sg.isperformactionsuccess", "isperformactionsuccessdirty")
    inst.isghostmode = net_bool(inst.GUID, "sg.isghostmode", "isghostmodedirty")
    inst.actionmeter = net_byte(inst.GUID, "sg.actionmeter", "actionmeterdirty")
    inst.actionmetertime = net_byte(inst.GUID, "sg.actionmetertime", "actionmeterdirty")
    inst.currentstate = net_hash(inst.GUID, "sg.currentstate")
-- ★★ net_hash：状态图当前状态名。
-- 【★用 net_hash 而非 net_string 省带宽】
-- net_string 是变长字符串，状态名如 "idle"/"run" 也要数字节；
-- net_hash 固定 32 位，且写入侧可传字符串自动转哈希（netvars.lua:25-27）。
-- 【★但注意 net_hash 的单向性：读出来只有哈希值，不是原名】
-- 所以第 532 行之类的调试输出需要用反向表把哈希映回名字。
-- ★这是「用哈希换固定宽度」的经典取舍：省带宽，失去可读性。
	inst.isoverrideattack = net_bool(inst.GUID, "sg.isoverrideattack")

    --Locomotor variables
    inst.runspeed = net_float(inst.GUID, "locomotor.runspeed")
-- ★ locomotor 的速度字段全是 net_float 且不注册脏事件（除下面两个）。
-- 【★为什么速度不注册脏事件】
-- 移动速度是「连续量、每帧都在用」，客户端直接读 value() 即可，
-- 不需要靠事件通知（通知了也只是重算一遍同样的值）。
-- ★这是 netvars.lua:36 那条规则的延伸：
--   「不需要通知就不注册」，比注册了不处理更省。
    inst.externalspeedmultiplier = net_float(inst.GUID, "locomotor.externalspeedmultiplier")
    inst.runspeed:set(TUNING.WILSON_RUN_SPEED)
    inst.externalspeedmultiplier:set(1)
    inst.externalvelocityvectorx = net_float(inst.GUID, "locomotor.externalvelocityvectorx", "externalvelocityvectordirty")
-- ★ 外部速度的两个分量注册了 "externalvelocityvectordirty"。
-- 与上面几行的 float 形成对照：同样是 float，
-- 这两个要触发外部速度覆写（如被牛撞飞、被龙卷风卷走），所以必须通知。
-- ★再次印证「注册不注册脏事件取决于下游是否需要被通知」。
    inst.externalvelocityvectorz = net_float(inst.GUID, "locomotor.externalvelocityvectorz", "externalvelocityvectordirty")
	inst.busyremoteoverridelocomote = net_bool(inst.GUID, "locomotor.busyremoteoverridelocomote") --WASD
	inst.busyremoteoverridelocomoteclick = net_bool(inst.GUID, "locomotor.busyremoteoverridelocomoteclick") --L.click
	inst.isstrafing = net_bool(inst.GUID, "locomotor.isstrafing", "isstrafingdirty")

	--PlayerSpeedMult variables
	inst.psm_basespeed = net_float(inst.GUID, "playerspeedmult.psm_basespeed", "playerspeedmultdirty")
-- ★ 玩家速度修正的三个 float，共用 "playerspeedmultdirty"。
-- 三个字段逻辑上总是一起改（基础值 + 服务端倍率 + 封顶倍率），故合并派发。
	inst.psm_basespeed:set(inst.runspeed:value())
	inst.psm_servermult = net_float(inst.GUID, "playerspeedmult.psm_servermult", "playerspeedmultdirty")
	inst.psm_servermult:set(1)
	inst.psm_cappedservermult = net_float(inst.GUID, "playerspeedmult.psm_cappedservermult", "playerspeedmultdirty")
	inst.psm_cappedservermult:set(1)

    --CarefulWalking variables
    inst.iscarefulwalking = net_bool(inst.GUID, "carefulwalking.careful", "iscarefulwalkingdirty")

    --BoatCannonUser variables
    inst.cannon = net_entity(inst.GUID, "boatcannonuser.cannon", "cannondirty")

	--ChannelCaster variables
	inst.ischannelcasting = net_bool(inst.GUID, "channelcaster.ishcannelcasting")
	inst.ischannelcastingitem = net_bool(inst.GUID, "channelcaster.ischannelcastingitem")

	--soakin state (bathingpool) variables
	inst.bathingpool = net_entity(inst.GUID, "soakin.occupying_bathingpool", "bathingpooldirty")
-- net_entity：指向浴池实体的引用。
-- 【★net_entity 的价值：同步的是实体引用而非 id 字符串】
-- 引擎侧维护 GUID 到实体的映射，接收方拿到的是可直接操作的实体对象。
-- 比同步字符串 id 再自己查找要高效得多，也不怕实体销毁后的悬挂引用。

	--foley sound overrides
	inst.playinghorseshoesounds = net_bool(inst.GUID, "foley.playinghorseshoesounds")

    --Morgue variables
    inst.isdeathbypk = net_bool(inst.GUID, "morgue.isdeathbypk", "morguedirty")
    inst.deathcause = net_string(inst.GUID, "morgue.deathcause")
-- net_string：死亡原因。★全文件唯一使用 net_string 的地方。
-- 【★为什么这里必须用变长字符串而不能 hash】
-- 因为死亡原因要对玩家显示原文（「被狗咬死」），哈希无法还原。
-- ★这与第 1592 行的 net_hash 形成对照：
--   同样的「字符串上网络」，选 hash 还是 string 取决于「要不要看原文」。

    --Delay net listeners until after initial values are deserialized
-- ★★★ 全文最重要的一条顺序约束，原注释：
--   Delay net listeners until after initial values are deserialized。
--
-- 【★为什么监听必须延后一个时间片】
-- 若在此之前注册监听，netvar 初值反序列化时会产生大量脏事件，
-- 触发一整轮 UI 刷新与音效播放 —— 表现为「刚进游戏就闪一串血条动画」。
-- 延后到下一个时间片，等初值全部就位再注册，就不会有这批假事件。
--
-- 【★DoStaticTaskInTime(0, ...) 的 0 表示「下一个调度点」，不是「现在」】
-- 与 prefabs/world_network.lua:70 的 DoPostInit 同一手法。
-- ★网络实体初始化的标准三步：
--   1) AddNetwork + Hide + 声明全部 netvar 并赋初值
--   2) DoStaticTaskInTime(0) 延后注册监听 / 跑初始化钩子
--   3) SetPristine 划上服务端专属期的分界线
    inst:DoStaticTaskInTime(0, RegisterNetListeners)

    inst.entity:SetPristine()
-- ★★★ SetPristine —— 123 处 netvar 全部声明完毕，正式进入服务端专属期。
--
-- 【★★与 prefabs/world_network.lua:54 完全同构，是全工程最重要的约定】
-- SetPristine 之前：构造代码在两端都执行（本文件 1330-1633 行的 123 个 netvar
--   因此在客户端也有一份，才能完成 wire format 对齐）；
-- SetPristine 之后：只有服务端执行（下面的 SetValue / AddMorgueRecord 等）。
--
-- 【★换个写法会怎样错】
-- 若把任何一个 netvar 声明挪到 SetPristine 之后：
--   服务端有、客户端无 → 两端字段序列长度不同 → 反序列化从这里起整体错位。
--   表现是该 netvar 之后的所有网络字段变成乱值，且错位会持续传播。
-- ★这类 bug 极难定位，因为「报错的那一行」与「出错的那一行」相差很远。

    if not TheWorld.ismastersim then
-- ★★★ 第二个象限判定：客户端专属段。
-- 【与 SetPristine 的关系】
-- SetPristine 已经切断了「之后代码只在服务端跑」，那为什么这里还要判 ismastersim？
-- 因为这一段要做的事（OnEntityReplicated / BufferBuild）恰恰是「只在客户端做」的。
-- ★即：SetPristine 之后仍存在「双端都要写、但用 if 分流」的代码。
-- 这是初学者最容易困惑之处：
--   SetPristine 之后不是「不能出现双端代码」，而是「引擎默认只跑服务端」。
--   想在客户端做额外初始化，就得像这里一样显式判 ismastersim 取反。
--
-- ★两个客户端专属函数的价值：
--   OnEntityReplicated —— 见第 247 行，classified 挂载总入口；
--   BufferBuild       —— 建造预处理的客户端表现。
        inst._refreshtask = nil
        inst._bufferedbuildspreview = {}

        --Client interface
        inst.OnEntityReplicated = OnEntityReplicated
        inst.BufferBuild = BufferBuild

        return inst
    end

    --Server interface
-- 服务端专属段：暴露 12 个接口函数给游戏逻辑。
-- 【★为什么按端暴露接口，而不在两端都暴露】
-- 若客户端也有 SetValue，它就能在本地改血量等 netvar。
-- 虽然 set 不会同步给别人（netvars.lua:47），但会产生本地脏事件，
-- 触发客户端自己的血条动画 —— 表现为「本地显示假血量」。
-- ★不暴露比暴露后判断更可靠：能力边界直接体现在接口是否存在。
    inst.SetValue = SetValue
    inst.PushPausePredictionFrames = PushPausePredictionFrames
    inst.AddMorgueRecord = AddMorgueRecord
    inst.SetTemperature = SetTemperature
    inst.SetUsedTouchStones = SetUsedTouchStones
    inst.SetGhostMode = fns.SetGhostMode
    inst.ShowActions = fns.ShowActions
	inst.ShowCrafting = fns.ShowCrafting
    inst.ShowHUD = fns.ShowHUD
    inst.EnableMapControls = fns.EnableMapControls
    inst.SetOldagerRate = fns.SetOldagerRate
	inst.SetBathingPoolCamera = fns.SetBathingPoolCamera

    inst.persists = false
-- ★ persists = false：classified 不参与存档。
-- 【★为什么】
-- 它是纯网络同步载体，内容全部可由游戏逻辑重建。
-- 存档它会导致「读档后 classified 被恢复，但玩家实体也不同步」的不一致。
-- ★给纯网络实体设 persists=false，是避免读档 bug 的标准做法。

    return inst
end

return Prefab("player_classified", fn)