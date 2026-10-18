--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：stategraph.lua
-- 模块：核心框架 / 表现层状态机（StateGraph Runtime）
-- 职责：定义 DST 的**表现层** AI 框架。角色的每一个动作（待机、行走、
--       攻击、受惊、死亡、僵直…）都是它的一个状态。承担四类职责：
--       ① 状态图的定义与组装（State / StateGraph / 三个 Handler 值对象），
--          以及四个模组注入点；
--       ② 全局调度（StateGraphWrangler / SGManager）：把任意多个状态图
--          实例按「唤醒 / 定时睡 / 冬眠」三态组织，保证帧率无关的时间推进
--          与零 CPU 的空闲态；
--       ③ 单实例的状态转移（StateGraphInstance）：GoToState 十二步、
--          标签体系、timeout、timeline 执行、事件缓冲与两级派发；
--       ④ 动作路由（ActionHandler）与客户端预测支持（FastForward /
--          ServerStateMatches）。
--       ——它只回答「我现在看起来该做什么动作」，不回答「我要去哪、
--       要不要打它」。后者是决策层的职责，由 brain.lua + 行为树负责。
-- 关键符号：StateGraphWrangler, SGManager, ActionHandler, EventHandler,
--           TimeEvent, FrameEvent, SoundTimeEvent, SoundFrameEvent,
--           State, StateGraph, StateGraphInstance,
--           GoToState, PushEvent, HandleEvent, HandleEvents,
--           ClearBufferedEvents, SetTimeout, StartAction, PreviewAction,
--           AddStateTag, RemoveStateTag, HasStateTag, HasAnyStateTag,
--           HasState, InNewState, GetTimeInState, PlayRandomAnim,
--           UpdateState, Update, Start, Stop,
--           ServerStateMatches, FastForward
--           ——全局表：SGManager, SGTagsToEntTags
-- ★★ 三层记忆（必须先记住，错误集中在这）：
--     statemem —— 「本状态的工作区」，**每次 GoToState 都被清空**（550 行）。
--               对应 bug-patterns.md 的 H2 条目。
--     mem      —— 跨状态持久数据，只随实体销毁而清（343 行）。
--     实例字段  —— tags / timeout / timelineindex / timeinstate，
--               换状态时按需重置。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：class.lua（六个类的共同基座）,
--           brain.lua（同构孪生的调度层，决策层）,
--           entityscript.lua:1148 SetStateGraph（装配与初始进状态）,
--           entityscript.lua:1307 PushEvent_Internal（事件路由入口）,
--           entityscript.lua:1600 PerformPreviewBufferedAction,
--           update.lua:288 主循环驱动（另有 214 行的静态 tick 事件路径）,
--           behaviourtree.lua:533 PriorityNode（决策层的思考周期散布）,
--           stategraphs/commonstates.lua（CommonStates / CommonHandlers 复用库）,
--           stategraphs/SGbat.lua（一个完整的最小实例）,
--           actions.lua:3305（statemem 标志的另一种用法对照）,
--           sched//scheduler.lua（DoTaskInTime 的同源设计）,
--           bug-patterns.md H1 / H2 / H3 / F3（对应条目）
--============================================================
--
--【阅读导航】
--  §零   模块头与调度表（1-11）        —— ★★ 四张集合表 + 一个二级索引
--  §一   SendToList 集合路由（13-25）  —— ★ 反查表维护的唯一入口
--  §二   四种状态迁移入口（27-73）     —— 唤醒/休眠/定时睡的三态协议
--  §三   注销与清理（76-107）          —— ★★ 作者自认的维护债
--  §四   主循环 Update/UpdateEvents    —— ★★ 换表法与刻末批处理
--         （109-157）
--  §五   三个值对象（159-211）         —— ActionHandler/EventHandler/TimeEvent
--  §六   State 类（213-262）           —— ★★ 状态是数据不是类层次
--  §七   两级事件派发（264-272）       —— ★★ 事件归属校验
--  §八   StateGraph 组装（274-325）    —— 四个 mod 注入点
--  §九   StateGraphInstance（332-403）—— ★★ 三层记忆与三处不对称
--  §十   动作路由（405-461）           —— ★★ Preview/Start 平行且不对称
--  §十一 事件缓冲（463-494）           —— ★★ 换表式清空
--  §十二 状态标签白名单（500-527）     —— ★★ tag → 实体 tag 全量同步
--  §十三 ★★ GoToState（529-600）       —— 本文件最重要的一步，12 步顺序
--  §十四 标签运行时操作（602-639）
--  §十五 SetTimeout 与 UpdateState     —— ★★ 重入检测（startstate 快照）
--         （641-690）
--  §十六 limbo 生命周期 Start/Stop     —— 状态图停摆协议
--         （692-716）
--  §十七 ★★ Update 休眠裁决（718-744） —— 三态返回值的定义处
--  §十八 客户端预测三件套（746-759）   —— FastForward / ServerStateMatches
--
--【★★ 本文件最重要的八条】
--  1. 三层记忆（statemem / mem / 实例字段）的生命周期截然不同：
--     statemem 每次 GoToState 清空（550 行），mem 永不清。
--  2. GoToState 的 12 步顺序是刻意设计的，两条不变量必须记牢：
--     onexit 能读到即将丢弃的 statemem；onenter 只能靠 params 拿数据。
--  3. 换表法（118-119 / 490 / 149-150）出现三次，
--     解决同一个问题：遍历期间增删表是未定义行为。
--  4. 事件刻末批处理（145 行 UpdateEvents）—— 代价是延迟一帧，
--     收益是事件处理永不重入正在跑的 Update。
--  5. Update 返回三态（0 / 正数 / nil）决定实例的生死（718-744 行）。
--     写了 onupdate → 永远返回 0 → 永不休眠（bug-patterns.md F3）。
--  6. 事件归属校验（265 行 data.state == self.name）：
--     延迟处理的事件必须由「入队时所在状态」的处理器消费。
--  7. SGTagsToEntTags 白名单做「全量同步」而非「只加不减」（559-565 行）：
--     漏删会导致实体标签永不消失，症状是「AI 看起来坏了」。
--  8. 四个 mod 注入点（289 / 301 / 313 / 321）都发生在构造期，
--     且 mod 后注入 → 同名覆盖原版。这是模组生态的技术基础。
--
--【★★★ 本文件收录的疑似缺陷（均为代码阅读推断，未在运行时验证）】
--  ⚠ 1. 第 100 行 `self.tickwaiters[inst] = nil` 是空操作：
--       tickwaiters 是二级表，第一层键是 tick 号，从未有以实例为键的条目。
--       正确写法见 brain.lua:93-95（遍历所有桶）。
--       被 85-88 行的 old_list 摘除掩盖，实际影响是「桶可能滞留」。
--  ⚠ 2. 第 438-439 行 is_going_to_action_state 在 GoToState **之前**设置，
--       而 550 行会清空 statemem → 新状态 onenter 读到的一定是 nil。
--       表现为「执行动作时物品栏被误关」（SGwilson.lua:631 恒为假）。
--  ⚠ 3. 第 442 行读 self.statemem.no_predict_fastforward 恒为 nil：
--       该字段从未被写进 statemem（242/570 行都在别的命名空间）。
--       「按状态禁止预测快进」是死代码，修复应改读 self.no_predict_fastforward。
--  ⚠ 4. 第 682 行 self:Update(extra_time) 的 extra_time 参数被丢弃：
--       Update（718 行）不接收参数，内部用真实时间差重算 dt。
--       掉帧补偿的意图未达成，实际只是多跑一次 Update。
--  ⚠ 5. 第 737 行 self.currentstate.onupdate 无判空：
--       若状态图的 defaultstate 拼错，GoToState（532 行）软失败后
--       currentstate 仍为 nil，实例却已注册 → 下帧 Update 在此崩溃。
--  ⚠ 6. 第 261 行 table.sort + 第 209-210 行比较器不稳定：
--       同一时刻的多个 TimeEvent 触发顺序未定义
--       （与 bug-patterns.md A6 同族）。
--  ⚠ 7. 第 596 行 lasttags 置 nil 与 551 行赋值构成的 API 一致性不足：
--       SGbearger.lua:2235 直接索引、sharkboi.lua:85 加了判空，
--       说明「只在 onenter 期间有效」这条约定未被强制、未被文档化。
--
--【★ 与其他文件的对照（同构孪生 / 同一思想的三次应用）】
--  · brain.lua:2   BrainWrangler —— 与 StateGraphWrangler 同构孪生，
--                  字段名完全一致，但实现细节已各自演化（见 14 行对照）。
--  · brain.lua:136 _safe_updaters —— 换表法的变体（写进数组而非换表）。
--  · entityscript.lua:61 StopUpdatingComponents —— 同一思想的第四次应用。
--  · behaviours/ behaviourtree.lua:533 PriorityNode —— 决策层的对应物，
--    同样有 period 散布（lasttime 随机初始化）防「上百只怪同刻动作」。
--  · stategraphs/commonstates.lua CommonHandlers —— 事件处理器的复用库，
--    是 300 个状态图文件不必各自重写「被打断怎么办」的原因。
--
--【★ 移植时最需要注意的四处不对称】
--  ① PreviewAction 与 StartAction 是两份平行实现（405 / 430），
--     且行为不一致（statemem 标志、预测快进、无 handler 兜底），
--     改动作路由时必须同改，否则联机表现与本地不一致。
--  ② StartAction 在 handler.condition 为假时隐式落出返回 nil，
--     调用方（locomotor）已走到目标位置却等不到状态切换 →
--     「走到某东西面前站着不做任何事」（bug-patterns.md H1 条目）。
--  ③ stategraph 与 brain 的 Sleep 差一个 +1（64 行 vs brain.lua:72），
--     亚帧睡眠的处理方式不同，照抄会产生抖动。
--  ④ stategraph 的 stategraph.lua:113 唤醒时只写 updaters 不写
--     instances 反查表，而 brain.lua:127-128 两处都写。移植应采用后者。
--★★ 本文件唯一的 require 是 class.lua。整套状态图框架建立在 Class() 的
--   元表继承之上：ActionHandler / EventHandler / TimeEvent / State /
--   StateGraph / StateGraphInstance 六个类全部由它派生。
--   没有 require("class") 的话下面所有 Class(...) 都会是 nil 调用。
--   ★ 对比 brain.lua：它连 require 都没有，因为大脑不用类继承体系，
--     只有 Brain 一个类，且大脑的"多态"靠行为树（behaviourtree.lua）实现。
--   参见 class.lua:150 的 Class() 实现。
require("class")

--★★★【StateGraphWrangler：全游戏所有状态图的「调度局」】
--   它是本文件的第一个类，也是唯一带全局单例的类（见 11 行 SGManager）。
--   ★★ 设计要点：**状态图实例（StateGraphInstance）之间完全不认识彼此**，
--     每个实体有自己的状态图、各自的当前状态、各自的时间线。
--     但"谁来驱动它们更新"必须集中管理，否则就是 N 个协程每帧 resume。
--     这个 Wrangler 就是那个"集中的驱动方"。
--   ★ 与 brain.lua 的 BrainWrangler 是**同构孪生**：
--     字段名一模一样（instances/updaters/tickwaiters/hibernaters），
--     连注释风格都是同一批人（NOTES(JBK)）写的。
--     详见 brain.lua:2 的对照注释。
--   —— 下面是它的五张表，理解这五张表就理解了整个调度模型：
--   self.instances   —— 反查表：{ [状态图实例] = 它当前所在的那张集合表 }
--                      ★ 这是"反向索引"，让 SendToList 能在 O(1) 内把对象
--                        从旧集合挪走，不必遍历所有集合去搜索。
--                      若没有它，每次状态切换都要扫 4 张表 × N 个对象。
--   self.updaters   —— 本帧需要更新的（正向集合）
--   self.tickwaiters—— { [目标 tick 号] = { 实例=true, ... } }
--                      ★★ 这是**二级索引**：按"哪一帧醒来"分组，而不是一个平表。
--                        醒来时只需查一张表，不用遍历全部等待者。
--   self.hibernaters—— 休眠的（完全不占 CPU）
--   self.haveEvents  —— 本帧有待处理缓冲事件的实例
StateGraphWrangler = Class(function(self)
--【★ 反查表 instances：键是 StateGraphInstance，值是它所属的集合表】
--   值为 nil 表示"这个状态图实例根本没被注册"（已 Stop 或还没 Start）。
--   后面几乎每个入口方法（OnEnterNewState / OnSetTimeout / Hibernate /
--   Wake / Sleep / OnPushEvent）开头都是 `if self.instances[inst] then`，
--   ★ 那句判断的语义就是：**"你还活着吗？没被注销的话我才理你。**"
--   这是整套框架防悬垂引用的总闸门。
        self.instances = {}
--【updaters：本帧要跑 Update 的实例集合】
--   ★ 注意它是**键和值都是实例**的集合（inst=true），不是数组。
--     集合语义（去重 + O(1) 删除）是 Lua 里模拟 Set 的标准写法。
        self.updaters = {}
--【★★ tickwaiters：唯一的二级索引 —— 按「醒来时刻」分桶】
--   结构：{ [tick号] = { [实例]=true } }
--   ★ 为什么不给等待者单独一张平表 + 一个醒来时间字段？
--     因为那样每帧都要遍历全部等待者找谁该醒了，复杂度 O(等待总数)。
--     分桶后每帧只查 self.tickwaiters[current_tick] 一张桶，O(1)定位。
--   ★ 这是本文件最值得学的性能技巧：把"按时间筛选"从
--     「每帧全扫 + 逐个比较时间」换成「插入时按时间归桶」。
--   ⚠ 代价：桶本身不会自动回收历史，只能靠 Update 里 115 行的
--     `self.tickwaiters[current_tick] = nil` 逐帧擦除。
--     若某帧的 Update 没被调用（游戏暂停/断网），桶会残留。
        self.tickwaiters = {}
--【hibernaters：休眠者集合】
--   ★ 语义：状态图活着，但完全不参与更新。省的是 CPU 而不是内存。
--     参见 132-140 行：Update() 返回 nil 就进这里。
--   ★★ 与 scheduler.lua 的 HIBERNATE 是同一思想（见 03-参考架构/02_scheduler），
--     但实现方式不同：scheduler 用协程 yield，这里用集合进出。
--     集合法的优势是**不会泄漏协程**——参见 bug-patterns.md A5/A7。
        self.hibernaters = {}
--【★★ haveEvents：待处理事件集合 —— 与前四者语义完全不同】
--   ★ 它**不是**互斥的"第四种状态"，而是正交的一个标记位：
--     一个实例可以同时在 updaters 里、并且 haveEvents[k] == true。
--   原因：状态图的 Update 和 HandleEvents 是**分开两趟**跑的
--     （见 145 行 Update 末尾才调 self:UpdateEvents()）。
--   ★★ 为什么要分两趟？——这是 H3 bug 的根源：
--     如果在 Update 里立刻处理事件，事件处理里再调 GoToState，
--     就会重入当前正在跑的 Update，导致状态被切换两次。
--     分趟之后，事件处理永远发生在"所有状态的 Update 都跑完之后"，
--     天然免疫重入。参见 bug-patterns.md 的 H3 条。
        self.haveEvents = {}
end)

--★★★【SGManager：进程级唯一的状态图调度单例】
--   ★★ 全文件所有的 SGManager:xxx 调用都指向这**同一个对象**
--     （stategraph.lua 里没有别的 StateGraphWrangler() 调用）。
--     这意味着：**全游戏所有实体的所有状态图，共用这一份调度表。**
--   为什么用全局单例而不是挂在 TheWorld 上？
--     · 无需 TheWorld 存在即可工作（编辑器预览、单元测试都能跑）
--     · update.lua:288 直接 `SGManager:Update(i)` 就能驱动，零耦合
--   代价：无法做「两个世界各自跑一套状态图」的隔离测试。
--   参见 update.lua:288 的主循环调用点，
--   以及 update.lua:214 的**静态 tick**路径（暂停界面也要跑事件）。
SGManager = StateGraphWrangler()

--★★★【SendToList：把实例在四张集合表之间搬家 —— 本文件最核心的 12 行】
--   统一签名：SendToList(inst, list)，list 为 nil 表示「注销」。
--   ★★ 它必须同时做**两件事**，缺一不可：
--     ① 从旧集合删除：old_list[inst] = nil
--     ② 写入反查表：self.instances[inst] = list
--        并在 list 非 nil 时 list[inst] = true
--   少做①→ 实例同时出现在两张表里，会被更新两次（表现为怪物抽搐）。
--   少做②→ 下次 SendToList 找不到旧集合，实例被永久钉死在旧表里。
--   ★ 三重冗余设计：一张反查表 + 一张正向表，二者必须同步。
--     这是典型的"空间换查询复杂度"——用一份内存维护 O(1) 的删除。
--   ⚠ 对比 brain.lua:39 的同名函数，那边多了一层
--     `old_list ~= list" 的早退判断（避免重复搬运），本文件没有。
--     说明两个文件的这段代码是**独立演化**的，不是同一份复制。
--   参见 brain.lua:39 的对照注释。
function StateGraphWrangler:SendToList(inst, list)
--【★ 反查：拿到这个实例当前在哪张表里】
--   nil = 未注册（已 Stop）。此时 21 行的 list 赋值也不会执行任何事。
    local old_list = self.instances[inst]
--【从旧集合摘除】键删除，Lua 表长度随之收缩，无内存泄漏。
    if old_list then
--【注意：即使 old_list 就是 list，这两行也只是白做一遍，没有副作用】
--   stategraph.lua 的 SendToList 是**无条件重写**的（无脑补早退），
--   ★ 代价是每次状态切换都要两三次哈希写入，在有上千状态图时是可测量的开销。
--   brain.lua 那边后来补了 `old_list ~= list` 判断，说明这是已知的优化点。
        old_list[inst] = nil
    end

--【★★ 反查表更新 —— 这一行是整套机制的枢纽】
--   它让后续任何 SendToList 都能立刻知道"从哪儿挪走"。
--   ★ 也让所有入口方法的 `if self.instances[inst]` 守卫成为可能。
    self.instances[inst] = list

--【list 非 nil 才写入 —— 传 nil 表示注销，这是 RemoveInstance 的路径】
    if list then
--【★ 值恒为 true：这是"集合"的标准编码 —— 键在集合里，值无意义】
--   不用数组是因为数组的 O(1) 删除在 Lua 里不存在（table.remove 会搬移元素）。
        list[inst] = true
    end

end

--★★【OnEnterNewState：任何状态切换都会调它 —— 由 GoToState 末尾触发】
--   ★★ 这是「状态机的心跳保证」：进入新状态就保证自己被唤醒到 updaters。
--     因为新状态可能带 timeline / timeout，但旧状态可能已经休眠了。
--   ★ 那句 `if self.instances[inst]` 守卫的语义：
--     实例还在调度系统里（没被 Stop），才把它捞回来。
--     若它已被 Stop（进入 limbo），GoToState 仍会改状态，但**不会重新注册**——
--     ★ 这是刻意的：limbo 里的实体不该重新开始消耗 CPU。
--   ⚠ 但注意：此时 GoToState 的 onenter 已经被调用过了（590 行在 599 行之前），
--     所以"状态被改了却不更新"是可能的。limbo 期间状态图状态通常无意义，
--     但若有人在 limbo 里切状态并依赖 onenter 的副作用，就会踩坑。
function SGManager:OnEnterNewState(inst)
    if self.instances[inst] then
        self:SendToList(inst, self.updaters)
    end
end

--★【OnSetTimeout：SetTimeout 会先叫醒实例再设 timeout】
--   顺序很关键：先确保自己在 updaters 里，再设 timeout，
--   否则可能在设完 timeout 之后立刻被休眠，永远等不到 ontimeout。
--   参见 641-644 行 SetTimeout 的实现。
function StateGraphWrangler:OnSetTimeout(inst)
    if self.instances[inst] then
        self:SendToList(inst, self.updaters)
    end
end

--★★【OnPushEvent：实体事件路由进状态图的入口 —— 返回值决定是否缓存】
--   返回 true  = 事件会被塞进 bufferedevents，等本帧末统一处理
--   返回 false = 实例已注销，事件被**静默丢弃**（不报错、不打印）
--   ★ 调用方在 entityscript.lua:1307：
--       elseif self.sg:IsListeningForEvent(event) and SGManager:OnPushEvent(self.sg) then
--           self.sg:PushEvent(event, data)
--     ★★ 注意是两个短路条件：先问「当前状态/全局表有没有人监听」，
--       再问「调度系统还认不认你」。
--     第一个条件是**性能优化**：没人监听的事件连缓存都不做。
--   ★ 这个返回值设计（成功与否即布尔）是 Lua 里很干净的做法，
--     避免了「登记 + 返回句柄」的两步 API。
function StateGraphWrangler:OnPushEvent(inst)
    if self.instances[inst] then
--【★ 打标记而非入队：事件本体存在实例自己的 bufferedevents 里】
--   haveEvents 只回答「这个实例有事要办」，不回答「办什么事」。
--   ★ 分工：调度系统管「何时办」，实例自己管「办什么」。
        self.haveEvents[inst] = true
--【★ 注意这里 return true 的位置在 if 内部】
--   未注册的实例返回 false，让调用方知道事件丢了。
		return true
    end
--【未注册路径：返回 false 静默丢弃】
--   ⚠ 这是一种**设计性吞异常**：实例刚被 Stop 就来了个事件，什么都不发生。
--     实践中这是对的（实体都要没了，响应事件没意义），
--     但排查"怪物死了却不播死亡音效"这类问题时要知道有这个静默路径。
	return false
end

--【★ Hibernate：让状态图进入零 CPU 状态】
--   ★ 为什么状态图需要主动休眠？因为 onupdate 是每帧跑的，
--     上千个远处怪物的状态图加起来就是巨大的纯浪费。
--     而它们的 onupdate 往往什么都不做（只是摆姿势）。
--   ★★ 休眠与「Sleep（定时睡）」的区别：
--     Hibernate = 睡到有人叫醒（Wake / OnEnterNewState / OnSetTimeout）
--     Sleep     = 睡到某个 tick 号，届时自动醒来
--   参见 bug-patterns.md 的 F3「状态图永不休眠」条目。
function StateGraphWrangler:Hibernate(inst)
    if self.instances[inst] then
        self:SendToList(inst, self.hibernaters)
    end
end

--【★ Wake：唤醒一个休眠中的状态图】
--   用法：事件来了、locomotor 报告到位了、被打断了 —— 都需要 Wake。
--   典型：locomotor 抵达目标后调 inst.sg:Wake() 让状态图继续决策。
function StateGraphWrangler:Wake(inst)
    if self.instances[inst] then
       self:SendToList(inst, self.updaters)
    end
end

--★★★【Sleep：把「我要睡 N 秒」翻译成「我在第 T 帧醒来」】
--   ★★ 这是本文件最精巧的一处：把时间语义（秒）翻译成帧号，
--     于是调度系统可以完全用整数 tick 做索引，无需每帧比较时间。
--   三步：
--     ① 秒 → 帧数（除以 GetTickTime，即每帧时长）
--     ② 帧数 → 绝对目标 tick（当前 tick + 帧数，floor 取整）
--     ③ 目标 tick → 归入对应的桶
--   ★ 与 scheduler.lua 的 DoTaskInTime 思路完全一致，
--     区别是那边用协程，这边用集合桶。参见 03-参考架构/02_scheduler。
function StateGraphWrangler:Sleep(inst, time_to_wait)
    if self.instances[inst] then
--【秒 → 帧】GetTickTime() 是 C++ 侧的固定帧长（FRAMES=1/30）。
--   ★ 用固定帧长换算而非累加真实时间，是为了保证**帧对齐**：
--     同一 tick 内所有 Sleep 的实例会在同一帧一起醒，批量处理，局部性好。
        local sleep_ticks = time_to_wait/GetTickTime()
--【★ 零帧下限保护】睡 0 帧 = 下帧就醒，那不如不睡（省一次搬运）。
--   强制成 1 帧，保证至少有一次真正的休眠。
        if sleep_ticks == 0 then sleep_ticks = 1 end

--★★★【★ 行号细节：这里的 +1 与 brain.lua:72 不同 —— 值得单独讲】
--   stategraph.lua:  math.floor(GetTick() + sleep_ticks) + 1
--   brain.lua:72:     math.floor(GetTick() + sleep_ticks)
--   ★★ 差异的后果：
--     · stategraph 无条件 +1，保证目标 tick **一定在未来**，
--       即使 sleep_ticks 是 0.4 帧这种亚帧睡眠也被抬到下一帧。
--     · brain 不加 1，靠 74 行的 `if target_tick > GetTick()` 兜底；
--       若目标 tick 就是当前 tick，**这次 Sleep 静默失效**，
--       大脑会保持 awake 直到下一帧被重新 Sleep。
--   ⚠ 疑似不一致（低危）：同一份调度思想的两处实现产生了细微差异，
--     移植代码时若照抄 brain 的版本到状态图，会引入亚帧抖动。
--     推理依据：62 行的 `sleep_ticks == 0 → 1` 保护在 brain 里也有（70 行），
--     说明两份代码同源；差异是后续演化中只改了一边。
        local target_tick = math.floor(GetTick() + sleep_ticks) + 1
--【取出（或新建）目标 tick 的桶】
        local waiters = self.tickwaiters[target_tick]

--【★ 懒建桶：只有真有实例要睡时才分配，避免给每个 tick 号留空表】
        if not waiters then
            waiters = {}
--【登记到 tickwaiters[target_tick]】
--   ★ SendToList 会自动把实例从 updaters 移出，所以这里不需要额外摘除。
            self.tickwaiters[target_tick] = waiters
        end
--【★★ 关键副作用：调用 Sleep 等于把自己从 updaters 摘出去】
--   这就是「休眠」的实现方式——**不在 updaters 里，自然就不会被 Update 到**。
--   没有额外的标志位，没有协程挂起。极简。
        self:SendToList(inst, waiters)
    end
end


--★★【OnRemoveEntity：实体被彻底销毁时的清理钩子】
--   ★★ 注意参数语义**在这个文件里是反的**：这里 inst 是 EntityScript，
--     而本文件其他所有方法（RemoveInstance 等）的 inst 是 StateGraphInstance。
--     83-84 行的 V2C 官方注释专门吐槽了这一点：
--     "inst is inst.sg, yo! Pretty much everywhere in this file except OnRemoveEntity"
--   ★ 这条注释本身就是「历史遗留混乱」的自认，
--     也是阅读本文件时最容易踩的坑。移植时务必区分两个 inst。
--   由 entityscript.lua 的 Remove 流程调用（经 EntityScript:OnRemove）。
function StateGraphWrangler:OnRemoveEntity(inst)
--【★ 用 inst.sg 去查反查表 —— 因为反查表的键是 StateGraphInstance】
--   没挂过状态图的实体，inst.sg 为 nil，查表返回 nil，安全跳过。
    if self.instances[inst.sg] then
--【显式写 SGManager 而非 self：与文件里其他地方风格不一致，
--   但两者指向同一单例，无功能差异。纯历史遗留。】
        SGManager:RemoveInstance(inst.sg)
    end
end

--★★★【RemoveInstance：把实例从调度系统的所有视野里彻底抹掉】
--   ★★ 这个函数的结构本身就是一段注释：
--     85-88  按反查表正常摘除
--     92     丢弃未处理事件
--     98-102 兜底清扫所有集合
--   94-97 的 V2C 注释说得很直白："looks like this file was not maintained
--   correctly, and instances are not always being moved to lists via :SendToList"。
--   ★★ 这是**作者承认的维护债**：历史上有些路径没走 SendToList，
--     导致反查表可能不准，所以只能在注销时暴力清扫五张表兜底。
--   → 移植建议：把注销写成"只依赖反查表 + 断言未注册"，
--     别学这套清扫，否则同样的悬垂引用会在别处复发。
function StateGraphWrangler:RemoveInstance(inst)
    --V2C: #legacycode: inst is inst.sg, yo! Pretty much
    --     everywhere in this file except OnRemoveEntity
--【正常路径：反查表说的那张表】
    local old_list = self.instances[inst]
    if old_list ~= nil then
--【★ 注意 `~= nil` 而非 `if old_list then`：语义等价但风格更明确】
        old_list[inst] = nil
    end

    --V2C: If the sg removes itself, or its entity, during our event
    --     handling loop, then we need to drop any remaining events.
--★★【★ 丢弃未处理的缓冲事件 —— 这一行防止了一种很难查的崩溃】
--   场景：实体在自己的**事件处理器里**销毁自己（Remove / RemoveFromScene）。
--   此时 UpdateEvents 正在 `for k, event in ipairs(buff_events)` 遍历，
--   若不清空，遍历会继续访问已销毁实体的后续事件 → 崩溃或幽灵行为。
--   ★★ 而且这里的实现很讲究：ClearBufferedEvents 是**换表**不是清空
--     （见 490-494 行 `self.bufferedevents = {}`），
--     于是正在跑的 ipairs 持有的是旧表引用，遍历自然结束，不会看到新表。
--   ★ 这与 480-483 行的检查是配套的：HandleEvents 里检测
--     `buff_events ~= self.bufferedevents` 就知道「表被换了，提前收工」。
--   ⚠ 两者必须成对存在，只改一处会引入遍历中的悬垂。
    inst:ClearBufferedEvents()

--【★★★ 以下四行是「作者自认的维护债」的兜底清扫，移植时应当删掉】
--   ★ 为什么反查表会不准？——因为 AddInstance（第 105 行）之外，
--     还有路径直接写集合表而忘了更新 instances。
--     更可能的原因是历史版本里存在过这样的代码路径，后被删了，
--     但兜底清扫留了下来。
--   ⚠ 代价：每个实体销毁时都要写 5 次哈希表。
--     高频生成/销毁（刷怪、掉落物）时这项开销是可测量的。
    --V2C: looks like this file was not maintained correctly,
    --     and instances are not always being moved to lists
    --     via :SendToList(...)
    --     so we'll just clear ourselves from everywhere possible
--【① 清反查表 —— 必须在最前面，后续 SendToList 才会正确跳过】
    self.instances[inst] = nil
--【② 清 updaters。若实例当时在这张表里（比如正被 Update 遍历），
--   这会造成 pairs 遍历中的删键 —— Lua 规范允许删除**当前键**，
--   但删除**尚未访问到的键**是未定义行为。
--   ★ Update 里 123 行的 `not k.stopped` 检查就是为这个场景兜底的。】
    self.updaters[inst] = nil
--⚠【★★ 疑似缺陷：`self.tickwaiters[inst] = nil` 是无效的】
--   推理依据：tickwaiters 是**二级表**，键是 tick 号（数字），
--     值是 { 实例 = true } 的集合（见 6 行注释与 65-70 行的构造）。
--     `self.tickwaiters[inst] = nil` 试图用「实例」当第一层键，
--     而第一层从来就没有以实例为键的条目 —— 这一行永远是**空操作**。
--   ★ 对照 brain.lua:93-95 的正确写法：
--       for k,v in pairs(self.tickwaiters) do v[inst] = nil end
--     那里遍历所有桶，把实例从每个桶里摘掉，才是对的。
--   ★★ 实际影响：绝大多数情况被掩盖了，因为 85-88 行的 old_list 摘除
--     已经把实例从它真正所在的桶里删掉了；而且 Update 时还有
--     123 行的 `k.stopped and` 与 `k.inst:IsValid()` 双重守卫，
--     悬垂实例被捞回来也只会跳过更新。
--   ★★ 但仍有一个真实的泄漏窗口：**桶本身永远不会被回收**。
--     桶只在 Update 的 115 行 `tickwaiters[current_tick] = nil` 时擦除。
--     若某实例 Sleep 到第 T 帧后在第 T 帧之前被 Remove，
--     它留在 tickwaiters[T] 里直到第 T 帧到来才被清空 —— 这本身无害；
--     真正的问题是若该实例再也不会被 115 行擦到（例如游戏暂停），桶会滞留。
--   → 结论：**不是崩溃级缺陷，但是「兜底清扫写了却写错了」这一事实，
--     恰恰证明了 94-97 行 V2C 注释所说的维护债是真实存在的。**
--     正确做法应与 brain.lua 一致：遍历所有 tickwaiters 桶。
--   ⚠ 本条为代码阅读推断，未在运行时验证。
    self.tickwaiters[inst] = nil
--【③ 清 hibernaters】
    self.hibernaters[inst] = nil
--【④ 清 haveEvents —— 防止已销毁的实例被 UpdateEvents 捞起来调 HandleEvents】
--   ★ 若不清，473 行的 assert 会通过，但 476 行的 IsValid 会拦下；
--     双保险。
    self.haveEvents[inst] = nil
end

--★★【AddInstance：注册一个状态图实例】
--   hibernate 参数决定初始落在哪张表 —— 通常来自 `inst:IsAsleep()`。
--   ★★ 关键设计：**注册时就已经考虑了休眠态**。
--     也就是说一个刚被创建就处于睡眠态的实体（离屏、地洞），
--     它的状态图从头到尾都不会跑一帧 onupdate。
--   调用点：entityscript.lua:1156 `SGManager:AddInstance(self.sg, self:IsAsleep())`。
--   ⚠ 对比：brain.lua:100 的 AddInstance **没有** hibernate 参数，
--     永远进 updaters —— 大脑的休眠靠 137 行 `not k.inst:IsAsleep()` 逐帧过滤。
--     两种做法性能特征不同：集合法 O(1) 完全不遍历；
--     逐帧过滤法每帧都要遍历一次（即使实体在睡觉）。
function StateGraphWrangler:AddInstance(inst, hibernate)
--【★ 一行完成「选表 + 登记」】
--   hibernate 为真 → 初始就进休眠表（IsAsleep 的实体走这条路）。
	self:SendToList(inst, hibernate and self.hibernaters or self.updaters)
end

--★★★【Update：整个状态图系统的唯一驱动入口（每帧每 tick 调一次）】
--   调用点：update.lua:288，在 `for i = last_tick_seen + 1, tick do` 循环里。
--   ★★ 为什么要 `for i = ...` 这个循环而不是只调一次？
--     因为一次 update 可能跨过多个 tick（掉帧、存档回读、时间跳跃）。
--     引擎必须把欠下的 tick 全部补上，否则计时器会累积漂移。
--     ★ 这也解释了 tickwaiters 为什么用 tick 号索引：补 tick 时直接按号取桶。
--   本函数五个阶段：
--     ① 唤醒到期的等待者（110-116）
--     ② 换表实现「快照遍历」（118-119）
--     ③ 逐个 Update 并按返回值决定去向（122-142）
--     ④ 关闭 profiler（143）
--     ⑤ 处理缓冲事件（145）
--   ★ 参照 bug-patterns.md 的 F3 条目：本函数第 ③ 段是「永不休眠」的源头。
function StateGraphWrangler:Update(current_tick)
--【★ 取本 tick 该醒的桶 —— O(1)，这是 6 行二级索引的全部回报】
    local waiters = self.tickwaiters[current_tick]
--【桶可能不存在（没人在这一帧醒），跳过即可】
    if waiters then
        for k,v in pairs(waiters) do
--【★ 只写 updaters，不动 instances 反查表 —— 依赖 SendToList 的搬家语义】
--   ⚠ 这里直接写表而不调 SendToList，于是 self.instances[k] **仍指向旧的桶**。
--     后果：下一次 SendToList 会先 `old_list[inst] = nil`（正确，桶马上被弃），
--     再写反查表 —— 结果仍然正确，但依赖了「旧桶随后被丢弃」这一事实。
--   ★ 对照 brain.lua:127-128，那边**同时**写了两处：
--       self.updaters[k] = true
--       self.instances[k] = self.updaters   ← stategraph 缺这一行
--     ★★ 这是两处实现的又一处不一致，且 stategraph 这边是**更弱**的版本。
--     推理依据：一旦某个路径在 113 行之后、SendToList 之前查询 instances[k]，
--     拿到的会是过期的桶。目前代码里没有这样的路径，所以没暴露。
--     移植时应采用 brain 的写法（两处都写）。
            self.updaters[k] = true
        end
--【★★ 擦除空桶 —— 防止 tickwaiters 无限增长的关键一行】
--   ★ 只在**本 tick**擦除。若某个桶因异常残留，会永久占用内存。
--   对应 100 行那个写错的兜底清扫，本行的存在让内存最终仍能回收，
--   这也是为什么 100 行的缺陷至今没暴露。
        self.tickwaiters[current_tick] = nil
    end

--★★★【★★ 本文件最重要的性能技巧：换表 = 零成本快照遍历】
--   经典问题：用 pairs 遍历一张表，同时在循环里往里加元素，是**未定义行为**
--     （可能漏遍历、可能报错、可能死循环）。
--   三种解法：
--     ① 收集键到数组再遍历（复制一遍，有分配开销）
--     ② 标记删除法（打墓碑，遍历后清扫，表会膨胀）
--     ③ **换表**（本文件采用）：把旧表整体让出去，遍历旧表；
--        新表从空开始，循环里的新增自然落到新表，下一帧才被处理。
--   ★★ 换表法的优雅之处：
--     · 零分配（只新建一个空表，不新建数组）
--     · 零拷贝（旧表直接给局部变量用）
--     · 天然实现「本帧新增下帧生效」的确定性语义
--   ⚠ 语义代价：循环里调 Sleep/Wake 的实例，**本帧不会被再次处理**，
--     必须等下一帧。对绝大多数玩法无害，但做「本帧必须生效」时要注意。
--   ★★ 同一思想在本项目出现三次：
--     · stategraph.lua:118-119（本处，换表法）
--     · brain.lua:136-144（换表法的变体：写进 _safe_updaters 数组）
--     · entityscript.lua 的 StopUpdatingComponents（全局待停队列，延迟删）
--   三者动机相同：让「遍历期间的增删」变成良定义行为。
    local updaters = self.updaters
--【★★ 核心一行：self.updaters 指向一张全新的空表】
--   循环里（122 行）用的是局部变量 updaters，即旧的表。
--   所以 136 行的 `self.updaters[k] = true` 写的是**新表** ——
--   语义就是「这个实例下一帧继续更新」。
--   ★ 这就是为什么 132-140 段的结果处理必须分三种情况，见那里。
    self.updaters = {}

--【★ Profiler 区间：整批 updaters 的耗时，挂在 C++ 侧的性能剖析器上】
--   ★ 性能排查时的第一个抓手：`TheSim:ProfilerPush("updaters")` 对应的时间
--     段就是状态图系统的总开销。它与 126 行的 per-prefab 段是嵌套的。
    TheSim:ProfilerPush("updaters")
--【遍历旧表（= 本帧开始时的活跃集合）】
    for k,v in pairs(updaters) do
--★★★【★ 两道守卫，每一道都对应一类真实的崩溃场景】
--   ① `not k.stopped` —— 状态图已 Stop（实体进 limbo）就别更了。
--      为什么需要？注释自述："The k.stopped check is for the condition of
--      iterating the loop causes the stategraph of another stategraph to go invalid"
--      ★ 翻译成人话：**A 状态图的 onupdate 里创建/销毁了 B 实体，
--        导致 B 的状态图在本轮迭代中失效。**
--        由于本文件用「换表法」，B 的状态图已被从旧表摘走（若走 SendToList），
--        但若 B 的实体是通过 RemoveInstance 硬删的，旧表里仍有它的键。
--        没有这道检查就会对已停止的状态图跑 Update → 空指针崩溃。
--   ② `k.inst:IsValid()` —— 实体本身是否还活着。
--      ★ 这是**第二道**独立防线：实体销毁与状态图注销是两个独立事件，
--        不保证顺序。IsValid 检查兜住「实体没了但 sg 还引用着」的情况。
--   ★★★ 两道守卫缺一不可，这是本文件最重要的防御式编程范例：
--     **在「遍历可变全局集合」的循环里，必须假设被遍历者随时会失效。**
        if not k.stopped and k.inst:IsValid() then -- NOTES(JBK): The k.stopped check is for the condition of iterating the loop causes the stategraph of another stategraph to go invalid.
--【★ 提前抓 prefab 名，只为 profiler 用】
--   ⚠ 性能注意：这行在热路径上每帧每个实例都执行一次 table 索引。
--     虽然便宜，但这类「只为调试存在」的代码在正式构建里是纯开销。
            local prefab = k.inst.prefab
--【无 prefab 就不 push profiler —— 保证 129 行的 Pop 也被跳过（129 行同样判断）】
--   ★ push/pop 必须严格配对，这里的双重判断维持了配对不变式。
            if prefab ~= nil then
			     TheSim:ProfilerPush(k.inst.prefab)
            end
--★★★【★ Update 的返回值决定实例的下一站 —— 全套休眠协议的核心】
--   三种返回值（详见 737-743 行 StateGraphInstance:Update 的实现）：
--     · 返回 > 0  → 一个秒数 → 睡那么久（Sleep）
--     · 返回 0    → 「下一帧还要更新我」→ 留在新表
--     · 返回 nil  → 「我没事了」→ Hibernate（彻底休眠）
--   ★★ 这三态协议是状态图性能的全部关键：
--     绝大多数状态（idle/attack 等）只在 timeline 关键时刻更新，
--     所以它们的 Update 返回一个「距下一个 timeline 点还有多久」，
--     状态图就能整段时间睡着不耗 CPU。
--   ⚠ bug-patterns.md 的 F3 条目警告：一旦某状态写了 onupdate，
--     737-739 行会直接 return 0，**这个状态图就永远每帧更新**，
--     即使实体在屏幕外。这是「加了音效后性能掉一个数量级」的常见根因。
            local sleep_amount = k:Update()
            if prefab ~= nil then
                TheSim:ProfilerPop()
            end
--【★ 分流：返回值非 nil 才有后续处理】
            if sleep_amount then
--【★ 正数 = 睡一个具体时长 → 走 tickwaiters 分桶路径（59-73 行）】
--   ★ 注意这里没有对 sleep_amount 做上界检查：一个返回 1e9 的状态
--     会把实例送进 10 亿帧后的桶 —— 实际上等于永久休眠（语义正确）。
                if sleep_amount > 0 then
--【送进睡眠队列，注意它同时把自己从旧表摘除（SendToList 的副作用）】
                  self:Sleep(k, sleep_amount)
                else
--★★【★ 返回 0 → 写进**新**的 self.updaters → 下一帧继续】
--   ★ 这一行是 118-119 换表法的直接受益者：
--     因为循环遍历的是旧表，在旧表上删自己不会破坏遍历；
--     而「继续更新」的意图写到了新表上，天然延迟一帧，语义清晰。
--   ★ 典型使用者：带 onupdate 的状态（见 737 行），
--     以及 682 行 timeline 中途切状态时递归 Update 返回的 0。
                    self.updaters[k] = true
                end
            else
--★★【★ 返回 nil → Hibernate：完全不更新，直到有人 Wake】
--   ★★ 这是状态图的「默认节能模式」，绝大多数状态都走这条路。
--     典型：进入 attack 状态后，attacktimeline 跑完、onupdate 结束，
--     Update 就返回 nil → 状态图睡着 → 直到攻击目标死亡事件把它叫醒。
--   ★ 与 HIBERNATE 的对称：Hibernate 进去，Wake 出来。
--   ⚠ 一旦某状态图再也没有事件能 Wake 它，它就永久沉睡。
--     排查「怪物站着不动也不做动作」时应优先怀疑这里。
                self:Hibernate(k)
            end
        end
    end
--【Profiler 区间结束】
    TheSim:ProfilerPop()

--★★★【★★ 「所有状态更新完之后」才处理事件 —— H3 的结构性解法】
--   ★★★ 这是本文件第二个最重要的设计决策。
--   场景推演：若在 128 行的 Update 里就处理事件，
--     事件处理器调 GoToState → 129-141 的分流逻辑会基于「已经算过的状态」
--     再算一次 → 同一帧内状态被切换两次 → 行为不确定。
--   把 UpdateEvents 放在 145 行（所有实例都跑完之后）：
--     · 事件处理只会影响**下一帧**的 Update，顺序完全确定
--     · 事件处理里可以自由切状态、Remove 实体、销毁状态图
--       （因为已经不在遍历 updaters 了，不会有遍历中失效问题）
--   ⚠ 代价：**事件响应延迟一帧**（1/30 秒）。
--     对音效/动画无感，对「点一下就攻击」的即时反馈有轻微延迟。
--     ★ 原版对此的补偿是 PushEventImmediate（entityscript.lua:1319），
--       绕过缓冲直接 HandleEvent —— 代价是放弃了上面的免疫性。
--   ★ 详见 bug-patterns.md 的 H3 条目（三套事件机制时序对照）。
    self:UpdateEvents()
end

--★★【UpdateEvents：事件总线的「刻末批处理」阶段】
--   ★★ 与 Update 的换表法同构：haveEvents 也用换表法（第 150 行）。
--   同样的收益：事件处理器里新 PushEvent 的事件会落到新表，下一帧才处理。
--   ★ 这就是「刻末批处理」的实现：同一帧内所有状态更新完，
--     再把这一帧攒下的事件一次性按 tick 顺序发放。
--   ⚠ 遍历 evs 时没有 k.stopped / IsValid 守卫 ——
--     全靠 RemoveInstance 的 102 行 `haveEvents[inst] = nil` 兜底。
--     若某事件处理器销毁了**另一个**待处理实例的状态图，
--     由于 haveEvents 已经换表，那一行写的是新表，**不会**清掉旧表里的键！
--     ⚠ 这是一个真实存在的窄窗口。后果：下一帧 haveEvents 又被捞起来，
--     但 HandleEvents 里 476 行的 IsValid 会拦住，不会崩 —— 静默浪费一帧。
--     与 Update 里那两道守卫相比，这里的防御明显更弱。
function StateGraphWrangler:UpdateEvents()
--【取出待处理集合（局部变量）】
    local evs = self.haveEvents
--【★★ 换表：与 118-119 完全同构的双缓冲】
    self.haveEvents = {}

--【Profiler：事件处理阶段】
    TheSim:ProfilerPush("events")
--【遍历本帧攒下的所有「有事件待处理」的实例】
    for k,v in pairs(evs) do
--【★ HandleEvents 内部会逐条派发给当前状态/全局处理器，见 473-488 行】
--   ★ 注意 HandleEvent 与 HandleEvents 是两个不同职责的方法：
--     · HandleEvent（463）= 派发**一条**事件
--     · HandleEvents（473）= 派发**缓冲队列里全部**事件
        k:HandleEvents()
    end
--【Profiler 结束】
    TheSim:ProfilerPop()
end

--★★★【ActionHandler：动作 → 状态的路由表项】
--   解决的问题：**「玩家挖了一下地面」这件事，该进哪个状态？**
--   这个映射在不同生物之间差异巨大（蝙蝠挖土 = flyaway 逃走，
--     蜘蛛挖地 = 钻进去），所以它是**每个状态图各自提供的数据**。
--   用法见 stategraphs/SGbat.lua:6-22 的 actionhandlers 表。
--   ★ 典型写法：ActionHandler(ACTIONS.GOHOME, function(inst) ... end)
--   ★★ 注意 ActionHandler 可以完全不给 deststate —— 那时表示
--     「这个动作不改变状态，直接执行」（见 453-455 行的 PerformBufferedAction）。
--   ★ 它与 EventHandler 的本质区别：
--     ActionHandler 由**玩家的操作**触发（预测 + 网络同步）
--     EventHandler  由**游戏事件**触发（本地，或网络复制后）
--   ★ 前者必须处理预测（见 441-449 行的 FastForward），后者不需要。
ActionHandler = Class(
    function(self, action, state, condition)

--【★ action 是发起点（状态图无法决定去哪，得靠调用方给出动作类型）】
        self.action = action

--★★★【★ deststate 的「字符串 or 函数」双形态 —— 一个很实用的设计】
--   写成字符串：ActionHandler(ACTIONS.PICKUP, "eat_enter")
--     → 恒定映射，省去写函数的样板代码。见 SGbat.lua:19-20。
--   写成函数：ActionHandler(ACTIONS.GOHOME, function(inst, ba) ... end)
--     → 运行时根据 bufferedaction 的 target 决定目标状态。见 SGbat.lua:7-13。
--   ★★ 为什么用统一函数式而不是在分支里判断？
--     因为 ActionHandler 会被**多个动作共用同一个处理函数**（如 SGbat 里
--     PICKUP / STEAL / EAT 都映射到 eat_enter），
--     表驱动让「哪些动作归哪个状态」一目了然，加动作只需加一行。
--   ★ 同时兼容两种形态，代价是每次派发多一次 type() 判断（微小开销）。
        if type(state) == "string" then
            self.deststate = function(_) return state end
--【★ 字符串分支：把常量包成常量函数，抹平两种形态的调用差异】
--   ★★ 这是「适配器模式」的最小实现：让下游（411/435 行）
--     只需要知道 `deststate(inst, bufferedaction)` 返回状态名，
--     完全不需要关心它原本是字符串还是函数。
--   ★ `_` 作为参数名表示「这个位置我不用，但签名必须一致」。
        else
            self.deststate = state
--【函数分支：原样保留调用者的函数】
        end

--【★ condition：可选的前置条件函数（返回 false 则动作不被接受）】
--   ⚠⚠ 这个可选条件是 bug-patterns.md **H1 条目**「相邻问题」的根因，
--     详见本文件 430-461 行 StartAction 的详细说明。
        self.condition = condition
    end)

--★★【EventHandler：游戏事件 → 状态图的处理器】
--   与 ActionHandler 的区别：没有 condition，也没有 deststate ——
--   处理器自己决定要不要 GoToState。
--   ★ 这是**完全开放**的形态，因为事件的语义千差万别
--     （受击、死亡、冻结、被攻击、醒来……），没法用一张路由表概括。
--   典型写法见 SGbat.lua:27-32 的 events 表。
--   ★★ 复用机制：CommonHandlers 提供了大量开箱即用的处理器
--     （OnAttacked / OnDeath / OnFreeze / OnAttack …），
--     定义在 stategraphs/commonstates.lua。
--     ★ 这就是为什么 300 个状态图文件不需要各自重写「被打断怎么办」。
EventHandler = Class(
    function(self, name, fn)
--★★【★ defline：记录「这个处理器定义在哪个文件哪一行」】
--   ★ debug.getinfo(3, "Sl") 的 3 是**调用栈深度**：
--     1 = getinfo 自身，2 = EventHandler 的 Class 构造器，
--     3 = 真正写 EventHandler(...) 的那一层。
--   ★★ 这个「硬编码的栈深度 3」是一个隐式契约：
--     EventHandler **必须**在状态图文件的顶层直接调用。
--     若有人在中间包一层工厂函数，defline 就会指向工厂而非定义处。
--   用途：调试时能立刻知道是哪个 prefab 的哪个状态图注册了这个事件，
--     对「为什么我的 mod 事件没生效」这类问题非常有用。
--   ⚠ 代价：每次构造都调用一次 debug.getinfo —— 反射有成本。
--     但处理器只在状态图加载时构造一次（不是每帧），可以接受。
        local info = debug.getinfo(3, "Sl")
--【★ 格式化成 "文件名:行号" 字符串，方便直接跳转/搜索】
        self.defline = string.format("%s:%d", info.short_src, info.currentline)
--【★ 参数断言：EventHandler 只接受字符串名字】
        assert (type(name) == "string")
--【断言必须是函数 —— 在加载期就拦住拼写错误，而不是运行时 nil 调用崩溃】
        assert (type(fn) == "function")
--★★【★ 事件名统一转小写 —— 事件名因此大小写不敏感】
--   ★ 目的：让 `sg:PushEvent("OnDeath")` 与 `PushEvent("ondeath")` 等价，
--     消除一类极难排查的 bug（名字大小写不匹配导致处理器永不触发）。
--   ★ 同时 266 行用 self.events[eventname] 查表，
--     而查表时**不会**再转小写 —— ⚠ 这意味着 PushEvent 传入的
--     名字若含大写字母，将匹配不上小写键。
--   ⚠ 疑似不一致（低危）：构造侧规范化、查询侧不规范化。
--     推理依据：250 行 `self.events[v.name] = v` 与
--     402 行 `self.events[event]` / 266 行都是直接用原字符串索引。
--     实践上原版所有 PushEvent 调用点都用全小写，所以从未暴露。
--     移植时若允许大写事件名，必须两侧都转小写。
        self.name = string.lower(name)
        self.fn = fn
    end)

--★★★【TimeEvent：timeline 上的一个「绝对时刻事件」】
--   ★★★ 这是状态图实现「多阶段动作」的核心原语。
--   为什么需要它？看一个真实的攻击 timeline（SGbat.lua:11 帧处）：
--     TimeEvent(8*FRAMES,  播咬击音效)
--     TimeEvent(11*FRAMES, 真正 DoAttack 造成伤害)
--   角色摆出攻击姿势要 8 帧，伤害在第 11 帧才结算。
--   ★★ 如果用 onupdate + 计数器实现这些帧，会让状态图每帧更新（F3 性能杀手）；
--     用 timeline 则可以只在 8/11 帧醒两次，其余时间整段休眠。
--   ★★ 这就是 F3 条目给出的「正确写法」：
--     onenter / onexit / ontimeout 是「点」，timeline 是「帧」，onupdate 是「每帧」，
--     **能写成时间点的一律不要写成 onupdate 里的时间比较。**
TimeEvent = Class(
    function(self, time, fn)
--【★ 与 EventHandler 同样的 defline 溯源机制（见 175 行说明）】
--   ★ 注意这里的栈深度 3 也依赖「TimeEvent 在状态图顶层被调用」。
        local info = debug.getinfo(3, "Sl")
        self.defline = string.format("%s:%d", info.short_src, info.currentline)
--【断言 time 必须是数字 —— 单位是**秒**】
        assert (type(time) == "number")
        assert (type(fn) == "function")
--【★ time 是相对**进入状态那一刻**的秒数，不是绝对时间】
--   进度计算在 UpdateState 的 668 行：`timeline[idx].time <= self.timeinstate`。
        self.time = time
--【fn 的签名统一为 function(inst) —— 无参调用（见 678 行）】
--   ★ 与 EventHandler 的 fn(inst, data) 不同：timeline 不携带数据，
--     因为时间点的语义就是「到这个时刻做这件事」，不需要 payload。
        self.fn = fn
    end)

--★★【FrameEvent：以「帧」为单位的 TimeEvent 语法糖】
--   ★ 为什么需要它？因为时间线的绝大多数节点都跟动画帧对齐，
--     用 FRAMES（1/30 秒）表达远比「0.2666667 秒」直观。
--   ★ 见 SGbat.lua:340 `TimeEvent(7*FRAMES, ...)` ——
--     读代码时能立刻知道「这是第 7 帧」，对应美术资源里的第 7 张动画帧。
--   ★ 与美术协作的关键：状态图时间线的帧号必须与动画帧号对齐，
--     否则会出现「伤害帧到了但动画还没张嘴」的经典 desync。
function FrameEvent(frame, fn)
--【frame * FRAMES = 帧转秒，交给 TimeEvent 统一处理】
	return TimeEvent(frame * FRAMES, fn)
end

--★★【SoundTimeEvent：播放音效的语法糖，语义是「这个时间点响一次」】
--   ★ 注意没有 loop 参数 —— timeline 里的音效天然是一次性的。
--     需要循环音效的生物（如狼嚎）要用 SoundFrameEvent 或在 onenter 里 PlaySound。
function SoundTimeEvent(time, sound_event)
    return TimeEvent(time, function(inst)
--【★ 直接调 SoundEmitter —— 状态图与音频系统的唯一耦合点】
--   ⚠ 因此：静音关掉声音（opts.mute_sfx）时这些声音不会被跳过，
--     仍会走 PlaySound 调用（引擎内部再决定是否发声）。
--     这点与 205 行的 SoundFrameEvent 同理。
        inst.SoundEmitter:PlaySound(sound_event)
    end)
end

--★★【SoundFrameEvent：帧版本的音效语法糖】
--   ★ 与 SoundTimeEvent 的唯一区别是单位（帧 vs 秒）+ 多一个 vol 参数。
function SoundFrameEvent(frame, sound_event, vol)
    return TimeEvent(frame * FRAMES, function(inst)
--【★ 三参数 PlaySound：第三参数是音量，覆盖 SoundEmitter 的默认音量】
--   ★ 为什么需要音量覆盖？因为同一个动画时间点上，
--     不同生物/不同状态的音效强度应该不同（如幼小动物叫得更轻）。
        inst.SoundEmitter:PlaySound(sound_event, nil, vol)
    end)
end

--★★【Chronological：timeline 的排序比较器】
--   ★★★ 为什么**必须**排序？因为 timeline 是用 ipairs 顺序读的，
--     而开发者在状态图里写 TimeEvent 时未必按时间先后排列。
--     忘记排序的后果极其隐蔽：时间线会**乱序触发**，
--     比如「伤害帧」在「起手音效」之前执行。
--   ★ 262 行的 table.sort 就是靠它。
--   ⚠ 稳定性的隐患：table.sort **不是稳定排序**。
--     两个 time 完全相同的 TimeEvent 的相对顺序是未定义的，
--     且结果依赖 Lua 实现与初始顺序。
--     ⚠ 疑似缺陷（低危但真实）：同刻事件顺序不可预期。
--     推理依据：比较器只比较 a.time < b.time，相等时返回 false，
--       交由排序算法自行决定 —— 标准 sort 不保证保序。
--       这与 bug-patterns.md A6「定时器以 table 为键，同刻到期顺序随机」
--       是同一族问题。
--     实践影响：写「同一时刻先切状态再播音效」这类代码会随机失效。
--     → 规避：把两个事件的时间错开 1 帧，或合并成一个。
local function Chronological(a, b)
--【★ 严格小于 —— 相等时不交换（由 sort 算法决定最终顺序）】
--   ⚠ 若要保证稳定，应写 `a.time < b.time or (a.time == b.time and idx_a < idx_b)`。
	return a.time < b.time
end

--★★★【★★ State：状态图的原子单位 —— 「一个动作」的定义】
--   ★★ 关键认知：**State 是数据，不是类层次。**
--     状态之间没有继承关系（「攻击」不是「待机」的子类）。
--     状态之间只有**转移关系**，由 GoToState 显式建立。
--   ★★★ 这与「面向继承的层次状态机」的根本区别，也是本框架的优势：
--     · 状态可以自由复用（CommonStates 库就是复用 State 对象）
--     · 状态可以按条件动态生成（mod 注入，见 313-318 行）
--     · 没有「深继承链」导致的状态爆炸
--   详见 03-参考架构/08_statemachine.lua 开头的设计取舍分析。
--   ★ 一个 State 对象被**所有**使用它的状态图实例共享（不是 per-instance 的）。
--     因此 State 里**绝不能存运行时数据** —— 所有运行时数据都在
--     StateGraphInstance 上（currentstate / statemem / mem / tags …）。
--     ★★ 这是本文件最容易犯的设计错误：
--     在 State 里挂一个 self.mytarget 字段会被所有实体共享！
State = Class(
    function(self, args)
--【★ 与 EventHandler / TimeEvent 同样的 defline 溯源，见 175 行】
        local info = debug.getinfo(3, "Sl")
        self.defline = string.format("%s:%d", info.short_src, info.currentline)

--【★★ name 是唯一必填字段 —— 状态图靠名字查找状态（530 行）】
--   ★ 用名字而非对象引用做键，是为了让 StateGraph 能被序列化、被动态构造，
--     也是 mod 注入（316 行 self.states[v.name] = v）的前提。
--   ⚠ 代价：拼错名字只在 GoToState 时才报错（533 行 print 而非 assert），
--     运行时不易发现。见 529-600 行的详细说明。
        assert(args.name, "State needs name")
--【状态名 —— 全状态图内必须唯一】
        self.name = args.name
--★★【★ onenter：进入状态的那一刻执行一次】
--   ★ 典型职责：PlayAnimation、设目标、起冷却、切 tag。
--   ★★ 参数是 (inst, params)：params 来自 GoToState 的第二个实参（529 行）。
--     ★ 这是状态间传递数据的主要手段 —— 因为 statemem 每次切换都会被清空，
--       需要传值时应该用 params。参见 bug-patterns.md 的 H2 条目。
--   ⚠ params 没有类型检查，传错类型只在运行时报错。
        self.onenter = args.onenter
--★★★【★ onexit：离开状态的那一刻执行一次】
--   ★★ 命名坑：这个字段叫 onexit 而不是 ondone / onleave。
--     而且它的**第二个参数是下一个状态的名字**（539 行）而不是 params：
--         self.currentstate.onexit(self.inst, statename)
--     ★ 于是可以写出「离开攻击状态时才播放受击硬直」这类逻辑。
--   ★★ 调用时机极早：在 GoToState 的 538-540 行，
--     也就是**在 statemem 被清空（550 行）之前**。
--     ★★★ 因此 onexit 里能读到即将被丢弃的 statemem！
--     这是清理/交接数据的**最后窗口**。
--   ⚠ 对比 onenter 是「清空之后」调用（591 行），只能读 params。
--     两者能读到的数据范围不同，这是本文件极隐蔽的不对称点。
--   ⚠ 若当前状态没有任何转移路径（比如它是终态），onexit 可能永不执行。
        self.onexit = args.onexit
--【★ onupdate：每帧执行 —— ★★ 性能敏感区，见 bug-patterns.md F3】
--   参数 (inst, dt)：dt 是自上次 Update 以来经过的秒数。
--   ★★★ 铁律：**能不用就不用。**
--     写了 onupdate 的状态会让整个状态图永久每帧更新（737 行）。
--     正确做法是把「持续判断」拆成 onenter（起点）+ timeline（各时刻）+
--     ontimeout（终点）。
        self.onupdate = args.onupdate
--【★ ontimeout：SetTimeout 计时到期时执行一次】
--   ★ 用于「动作持续 N 秒后自动回到待机」这类逻辑。
--   ★★ 与 timeline 的区别：ontimeout 由状态**主动**设置（SetTimeout），
--     timeline 由状态**静态声明**。前者动态，后者固定。
--   ★ 两者可以共存：timeline 管中间帧，ontimeout 管兜底退出。
--   ⚠ 忘了 SetTimeout 就不会有 ontimeout —— 不会有任何提醒。
        self.ontimeout = args.ontimeout

--【★ tags：本状态激活时自动拥有的标签集合】
--   ★★ tag 是状态图对外暴露的「布尔属性」，其他系统靠它提问：
--     · locomotor 检查 tag "busy" 决定是否允许移动
--     · combat 检查 tag "noattack" 决定是否禁止攻击
--     · AI（brain）检查 tag "idle" 决定是否可被打扰
--   ★ 这是状态图与外部系统解耦的关键机制：
--     locomotor 不需要知道有哪些状态，只需要问「现在忙不忙」。
--   ★★ tag 的自动同步到实体标签见 551-566 行 —— 这是很少被注意的机制。
        self.tags = {}
        if args.tags then
--【★ 用 ipairs 遍历 args.tags 数组，转成哈希集合 self.tags】
--   为什么转？状态内部用哈希查（self.tags[k]）是 O(1)，
--   而 AddStateTag（603 行）也是往哈希里写。统一成哈希才能动态增删。
--   ⚠ 注意 k 被丢弃了：args.tags 里的顺序信息不被保留（本来也不需要）。
            for k, v in ipairs(args.tags) do
--【★★ 数组 → 哈希集合的转换：这是 State 内部唯一的 tag 存储形式】
                self.tags[v] = true
            end
        end

--★★【★★★ client_prediction 分支：State 构造里最容易被忽略的 11 行】
--   ★★ 这段代码处理**客户端预测**的服务端状态校验，
--     是 DST 联机表现一致性的关键，机制在 749-752 行 ServerStateMatches。
--   ★★★ 设计要点：同一份状态定义要同时服务两端，
--     所以用「哪个参数被提供」来区分两端：
--       · 提供 server_states  → 这是个「客户端预测状态」
--         → 记录哪些服务端状态与之等价，并编译成 hash 集合
--       · 没提供               → 这是个「服务端状态」
--         → 记录 no_predict_fastforward（能不能跳过预测快进）
--   ★ 为什么用 hash(v)：server_states 列表里存的是状态名，
--     而网络上传的 currentstate 是 hash 值（见 751 行 :value()）。
--     提前转成 hash 集合，服务端一收到就能 O(1) 判断。
--   ⚠⚠ 这个 if/else 是**互斥**的：同时提供 server_states 和
--     no_predict_fastforward 的状态，no_predict_fastforward 会被静默丢弃。
--     推理依据：它们分别在 if 与 else 两个分支里赋值，没有合并。
--     → 实践约束：一个状态要么是客户端预测态，要么是服务端态，不能兼顾。
		--#V2C #client_prediction
--【★ 判定依据：args.server_states 非 nil → 客户端侧使用的状态】
		if args.server_states ~= nil then
--【--client player only：注释明确标注这一分支只给客户端玩家用】
			--client player only
--【★ 编译成 { [hash(状态名)] = true } 的服务端状态白名单】
--   服务端会把自己的当前状态名 hash 上来，客户端比对是否在白名单里。
--   不在白名单 → 说明客户端的预测跑偏了 → 走纠正流程。
			self.server_states = {}
			for _, v in ipairs(args.server_states) do
--【★ hash() 是 C++ 侧提供的字符串哈希 —— 与 751 行的 :value() 同源】
				self.server_states[hash(v)] = true
			end
--【★ forward_server_states：本次切换时要把**上一个状态**的白名单沿用过来】
--   场景：客户端连续预测了 attack → attackpre → attackpost 三个状态，
--     服务端只发「当前在 attackpost」。若 attackpost 自己的白名单不含
--     attack，服务端就无法确认客户端的预测过程是否合法。
--     于是沿用上一个状态的白名单，把整条预测路径都声明为「服务端认可」。
			self.forward_server_states = args.forward_server_states
		else
--【--server player only：服务端玩家分支】
			--server player only
--【★ no_predict_fastforward：标记本状态是否禁止「预测快进」】
--   ★★ 预测快进（FastForward，755 行）指：客户端预测执行了一个动作，
--     于是把状态图时间往前拨，让动画立刻演到位，避免一帧延迟的视觉卡顿。
--     某些状态（如挖洞的第三阶段）不能这么做，否则会和权威结果冲突。
--   ★ 读取点在 442 行：`self.statemem.no_predict_fastforward or ...`
--   ⚠⚠ 疑似缺陷：这里把标志存到了 **State 对象**（self.no_predict_fastforward），
--     而 442 行读的是 **statemem.no_predict_fastforward**，两者不是同一个存储位置！
--     推理依据：
--       · 242 行：self.no_predict_fastforward（State 实例字段）
--       · 570 行：self.no_predict_fastforward = state.no_predict_fastforward
--         （拷到 StateGraphInstance 字段，也不是 statemem）
--       · 442 行：self.statemem.no_predict_fastforward（statemem 内）
--     没有任何一行把 State 的这个字段写进 statemem，因此 442 行的条件
--     `self.statemem.no_predict_fastforward` **恒为 nil**。
--     实际效果：442 行退化为只看 bufferedaction.options.no_predict_fastforward，
--     而后者由 locomotor.lua:890 设置，所以功能没有完全失效，
--     但「按状态禁止预测快进」这条能力是**死代码**。
--     → 修复方向应是读 self.no_predict_fastforward（570 行已经拷过来了）。
--   ⚠ 本条为代码阅读推断，未在运行时验证。
			self.no_predict_fastforward = args.no_predict_fastforward
		end

--【★★ events：本状态私有的事件处理器表】
--   ★★★ 这是状态图事件路由的**第一优先级**层（见 463-471 行）：
--       先问当前状态的私有处理器；没处理掉，才问状态图全局处理器。
--   ★ 为什么需要「状态私有」这一层？举例「受击」：
--     · 在 attack 状态里被受击 → 应该打断攻击、播硬直
--     · 在 idle 状态里被受击 → 也应该播硬直，但不用打断什么
--     · 在 dead 状态里被受击 → 应该忽略
--     同一个事件在不同状态下的处理完全不同，
--     所以「处理函数」必须能绑定在状态上，而不是全局唯一。
--   ★ 存储形式：哈希表，键是小写事件名（见 179 行与 249 行）。
        self.events = {}
        if args.events ~= nil then
            for k,v in pairs(args.events) do
--【★ 加载期断言：只接受 EventHandler 对象】
--   ⚠ 注意用的是 is_a 而不是类型判断 —— 支持子类（Class 体系的元表继承）。
                assert(v:is_a(EventHandler), "non-EventHandler in event list")
--【★ 建立「小写事件名 → EventHandler」索引（见 179 行的小写化）】
--   ⚠ 若 State 的 events 与 StateGraph 的 events 里有同名事件，
--     **状态私有优先**（465-470 行的两级派发）。
                self.events[v.name] = v
            end
        end

--★★★【timeline：本状态的时间线表】
--   ★★ 注意这是**每个状态各自持有**的（不是实例级），
--     所以时间线是「状态的固有属性」，所有用这个状态的实体共享同一份定义。
--   ★ StateGraphInstance 上的 timelineindex（337 行）才是实例级的游标。
--   ★★ 二者的关系：定义共享（State.timeline）+ 进度独立（实例的 timelineindex）。
        self.timeline = {}
        if args.timeline ~= nil then
            for k,v in ipairs(args.timeline) do
--【★ 加载期断言：只接受 TimeEvent 对象】
                assert(v:is_a(TimeEvent), "non-TimeEvent in timeline")
--【★ 追加而非赋值：支持 CommonStates 把额外时间点插进来】
--   ★ CommonStates.AddCombatStates 之类会往已有状态的 timeline 里追加节点，
--     所以必须是 table.insert，不能覆盖。
                table.insert(self.timeline, v)
            end
        end

--★★【排序 timeline —— 见 209 行 Chronological 的详细分析】
--   ★★ 排序在**构造期**做一次，不是每帧。这是本文件性能设计的一贯原则：
--     把能提前算的都在加载期算掉，运行期只做查表。
		table.sort(self.timeline, Chronological)
--【State 类构造结束】
	end)

--★★★【★ State:HandleEvent：事件派发的第一级 —— 「当前状态是否处理这条事件」】
--   ★★★ 那个 `data.state == self.name` 判断是本函数最精妙也最容易忽略的设计：
--   问题：事件是**延迟处理**的（缓冲区，见 145 行）。
--     若事件入队时在 idle 状态，出队时状态已变成 attack ——
--     此时该用 idle 的处理器还是 attack 的？
--   ★ 原版答案：**用入队时的那个状态的处理器**。
--     实现方式就是 PushEvent 时把当前状态名塞进 data.state（394 行），
--     这里比对 —— 不一致就**跳过**。
--   ★★ 为什么这个语义是对的？
--     事件语义上属于「入队那一刻的世界」，
--     强行用当前状态的处理器会导致「状态切了但事件处理逻辑不匹配」的时序 bug。
--     例如「受击」在 idle 时入队，若中途切到「攻击中」，
--     用攻击的处理器去处理受击事件是错的（它会去打断攻击）。
--   ⚠ 代价：事件可能被**静默丢弃**（因为状态名对不上）。
--     排查「某事件处理器从来没被调用过」时应首先怀疑这里。
--   ★ 两个放行条件：
--     ① type(data) ~= "table"  → data 不是表（是 nil/数字/布尔），无从比对，放行
--     ② data.state == nil       → 外部直接构造的 data 没带状态标记，放行
--     ③ data.state == self.name → 正是入队时所在的状态，放行
function State:HandleEvent(sg, eventname, data)
--★★★【★★ 事件归属校验 —— 见上方详细说明】
--   ★ 这行是整个「延迟事件」机制的正确性基石，
--     删掉它会导致难以复现的时序 bug（bug-patterns.md H3 同族）。
	if type(data) ~= "table" or data.state == nil or data.state == self.name then
--【查本状态的私有处理器表】
        local handler = self.events[eventname]
        if handler ~= nil then
--★【★ 调用处理器并把返回值透传 —— true 表示「我处理了，别再往下派」】
--   约定：处理器**返回真值**即表示消费了该事件。
--   ★ 看 463-471 行的两级派发正是靠这个返回值决定要不要问全局表。
--   ⚠ 处理器忘记 return true 是极常见的错误 ——
--     表现为「事件同时被状态处理器和全局处理器响应」（重复响应）。
--     例如既播了两遍受击音效，又被 locomotor 响应。
            return handler.fn(sg.inst, data)
        end
    end
--【★ 未处理（返回 false），交给 StateGraphInstance 去问全局表（466 行）】
    return false
end

--★★★【★★ StateGraph：一个状态图的完整定义 —— 纯数据，无运行时状态】
--   ★★ 五个构造参数的职责：
--     name           —— 状态图的名字（用于 mod 注入的命名空间，见 289 行）
--     states         —— State 集合，键为状态名
--     events         —— 全局 EventHandler 集合
--     defaultstate   —— 初始状态名（entityscript.lua:1159 首次 GoToState）
--     actionhandlers —— ActionHandler 集合
--   ★★★ 关键性质：StateGraph 是**共享的不可变定义**。
--     全游戏所有同种生物共用一个 StateGraph 对象（比如 50 只蝙蝠共用 SGbat）。
--     运行时状态全在 StateGraphInstance 上（332 行）。
--     → 这是典型的「定义 / 实例」分离，使得 300 个状态图文件
--       在内存里只占很小一份，而每只怪物的状态互不干扰。
--   ★ 返回值就是一个 StateGraph 对象，状态图文件最后一行通常是：
--       return StateGraph("bat", states, events, "init", actionhandlers)
--     参见 stategraphs/SGbat.lua:396。
--   ⚠ StateGraph 本身没有 SetState / AddState 方法 ——
--     任务清单里提到的 AddState 在本版本中并不存在（见文件头说明）。
--     状态只能在构造时通过 states 表一次性给出，或由 mod 在 313-318 行注入。
StateGraph = Class( function(self, name, states, events, defaultstate, actionhandlers)
--【★ 加载期断言：名字必填 —— 因为它同时是 mod 注入的命名空间】
    assert(name and type(name) == "string", "You must specify a name for this stategraph")
--【★ StateGraph 也做 defline 溯源，见 175 行说明】
    local info = debug.getinfo(3, "Sl")
    self.defline = string.format("%s:%d", info.short_src, info.currentline)
    self.name = name
--【★ defaultstate：构造时只记录，第一次 GoToState 由实体侧触发】
--   调用链：entityscript.lua:1158-1159
--       SGManager:AddInstance(self.sg, self:IsAsleep())
--       self.sg:GoToState(self.sg.sg.defaultstate)
--   ★ 注意 `self.sg.sg` 的双重 sg 很反直觉：
--     第一个 sg 是 StateGraphInstance，第二个是 StateGraph 定义。
--     本文件里 inst.sg 恒指 StateGraphInstance（见 76 行）。
    self.defaultstate = defaultstate

    --reindex the tables
--【★ 注释写着 "reindex the tables" —— 这三个表都要从数组重建成以名字/动作为键的哈希】
--   因为构造参数里给的是数组（{ActionHandler(...), ActionHandler(...)}），
--   而运行时要用 O(1) 查找，所以必须 reindex。
    self.actionhandlers = {}
--【有 actionhandlers 才处理（允许纯被动状态图）】
    if actionhandlers then
        for k,v in pairs(actionhandlers) do
--【★ 加载期类型断言：把写错类型挡在启动期，而不是运行时 nil 调用】
            assert( v:is_a(ActionHandler),"Non-action handler added in actionhandler table!")
--【★★ 关键索引：键是 ACTIONS.xxx（动作对象），值是 ActionHandler】
--   ★ 这就是「动作 → 状态」路由表的实现，
--     运行时用 bufferedaction.action 直接查（407/432 行），O(1)。
--   ★ 键是动作对象而非动作名字符串：省一次字符串比较，且动作对象全局唯一。
            self.actionhandlers[v.action] = v
        end
    end
--★★★【★ 模组注入点 1：StategraphActionHandler —— 动作路由的扩展】
--   ★★ 三个 mod 注入点构成完整的扩展协议（本文件共 4 处）：
--     ① StategraphActionHandler（289）—— 加动作路由
--     ② StategraphEvent（301）        —— 加全局事件处理器
--     ③ StategraphState（313）        —— 加/覆盖状态
--     ④ StategraphPostInit（321）     —— 任意改造整个 StateGraph
--   ★★ 设计要点：mod 数据在**本表构造之后**注入，
--     所以 mod 可以覆盖原版的动作路由（同名覆盖），
--     也可以纯新增。这是「开放而非封闭」的具体体现。
--   ★ GetPostInitData(类型名, 状态图名) —— 两个维度：
--     类型名决定注入到哪个扩展点，状态图名决定作用于哪些状态图。
--     意味着 mod 可以写「只对狼生效」的状态图补丁。
--   ⚠ 同名覆盖是**无警告**的：mod 若拼错原版动作名，
--     不会报错，只是默默没生效（或覆盖了别的）。
	for k,modhandlers in pairs(ModManager:GetPostInitData("StategraphActionHandler", self.name)) do
		for i,v in ipairs(modhandlers) do
--【★ mod 提供的也必须是真 ActionHandler（同 285 行的断言）】
			assert( v:is_a(ActionHandler),"Non-action handler added in mod actionhandler table!")
--【★ 同名覆盖：mod 后注入的赢。原版先注入（原版代码在上），mod 后（此处）】
--   ★ 这就是模组能改写原版行为的技术基础。
			self.actionhandlers[v.action] = v
		end
	end

--【events 索引开始】
    self.events = {}
    for k,v in pairs(events) do
--【全局事件处理器的类型断言】
        assert( v:is_a(EventHandler),"Non-event added in events table!")
--【★★ 全局事件表索引：键是小写事件名（见 179 行）】
--   ★ 与状态私有事件表（249 行）结构相同，查询优先级见 465-470 行。
        self.events[v.name] = v
    end
--【★ 模组注入点 2：StategraphEvent —— 全局事件处理的扩展】
	for k,modhandlers in pairs(ModManager:GetPostInitData("StategraphEvent", self.name)) do
		for i,v in ipairs(modhandlers) do
--【mod 事件也必须是 EventHandler】
			assert( v:is_a(EventHandler),"Non-event added in mod events table!")
--【同名覆盖事件处理器】
			self.events[v.name] = v
		end
    end

--【★ states 索引开始 —— 三个索引的最后一个】
--   ★★★ states 是**最重要的索引**：GoToState 全靠它（530 行）。
--     也是三个表里**唯一有运行时遍历需求**的（见下方遍历顺序说明）。
    self.states = {}
    for k,v in pairs(states) do
--【★ 状态对象的类型断言 —— 保证 GoToState 拿到的都是 State】
        assert( v:is_a(State),"Non-state added in state table!")
--★★【★ 核心索引：状态名 → State 对象。GoToState 的全部查找依据】
--   ★★ 注意这是 pairs 遍历建索引（307 行的表是数组，键是数字）。
--   ⚠ 若 states 表里有两个同名状态，后遍历到的会覆盖先前的 —— 无警告。
--     这在 CommonStates 往已存在的状态表里追加内容时可能发生。
        self.states[v.name] = v
    end
--【★ 模组注入点 3：StategraphState —— 替换整个状态的扩展】
--   ★★★ 这是最强的扩展点：mod 可以提供一个同名 State，
--     完全替换原版某状态的行为（onenter/onupdate/timeline 全换）。
--   ★ 典型用途：mod 想改狼的攻击前摇时长，
--     只需注入一个同名 attack 状态并给出自己的 timeline。
	for k,modhandlers in pairs(ModManager:GetPostInitData("StategraphState", self.name)) do
		for i,v in ipairs(modhandlers) do
--【★ 断言 mod 注入的是 State —— 同 310 行】
			assert( v:is_a(State),"Non-state added in mod state table!")
--【★★ 覆盖：mod 的同名状态替换原版状态】
--   ⚠ 由于原版注入在前（307-312 行）、mod 在后，mod 总是赢家。
--     这是有意的，也是模组生态的基础。
			self.states[v.name] = v
		end
    end

	-- apply mods
--★★★【★ 模组注入点 4：StategraphPostInit —— 拿到完整 StateGraph 对象随意改造】
--   ★★★ 与前三个的区别：前三只能「加/覆盖某个条目」，
--     这里拿到的是**整个 StateGraph 对象**，可以做任何事
--     （加 tag、改 defaultstate、甚至塞运行时状态）。
--   ★ GetPostInitFns 返回的是函数列表而非数据表（对比 GetPostInitData）。
--   ★★ 风险：mod 拿到对象后若替换了 self.states 而不是修改它，
--     会静默丢掉 mod 自己的注入（顺序依赖）。
--     3/4 号注入点都在 321 行之前执行，所以 4 号里可以安全看到全部注入结果。
	local modfns = ModManager:GetPostInitFns("StategraphPostInit", self.name)
	for i,modfn in ipairs(modfns) do
--【★ 回调签名只有 (self)，即整个 StateGraph —— 没有隔离，改坏了就是改坏了】
		modfn(self)
	end
--【StateGraph 构造结束】
end)

--★★【__tostring：调试输出 —— 被注释掉的诊断信息揭示了一个设计变更】
--   ★ 328 行末尾那段被注释掉的 "(currentstate=...)" 说明：
--     早期版本的 tostring 会打印当前状态与已停留时间，
--     后来因为 StateGraph 本身**没有** currentstate（那是实例的状态）
--     而被移除。
--   ★★★ 这印证了本文件最核心的结构性事实：
--     **StateGraph 是纯定义，不持有任何运行时状态。**
--   ★ 若需要运行时信息，要打印 StateGraphInstance（373 行才是完整版）。
function StateGraph:__tostring()
    return "Stategraph : "..self.name--.. " (currentstate="..self.currentstate.name..":"..self.timeinstate..")"
end


--★★★【★★ StateGraphInstance：状态图的运行时实例 —— 本文件真正的数据所在】
--   ★★ 与 StateGraph 的关系：定义（N 个实体共享 1 份）/ 实例（每实体 1 份）。
--     所有会随时间变化的东西都在实例上，定义上一点都没有。
--   实体侧的持有方式：`inst.sg`（entityscript.lua:1157）。
--   ★★★ 注意这个反直觉的命名：
--     inst.sg            = StateGraphInstance（运行时）
--     inst.sg.sg         = StateGraph（定义）
--     inst.sg.currentstate= State（当前状态对象）
--     三层嵌套，写代码时极易混淆。建议始终用完整的 self.sg.sg.states。
--   构造参数：(stategraph=定义, inst=宿主实体)。
StateGraphInstance = Class( function (self, stategraph, inst)
--【★ 指向 StateGraph 定义 —— 只读，永不修改】
--   ⚠ 唯一会被读写的反例：外部代码有时会 monkey-patch 定义
--     （如 prefab 里给 sg.sg.states.xxx 打补丁），这是 mod 的常规手法。
    self.sg = stategraph
--【★★ currentstate = nil —— 刻意留空，由构造方显式 GoToState 决定初始状态】
--   ★ 为什么不在构造函数里直接进 defaultstate？
--     因为构造时实体可能还没准备好（组件没装配完、位置没设置），
--     onenter 里若访问 inst.components.xxx 会崩。
--   ★★ 于是形成一条严格的初始化契约（entityscript.lua:1156-1159）：
--       AddInstance（注册）→ GoToState(defaultstate)（此时实体已就绪）
--   ⚠ 违反顺序会导致 onenter 访问未初始化的组件。
    self.currentstate = nil
--【★ timeinstate = 0 —— 「本状态已停留秒数」，timeline 的进度基准】
--   ★★ 与 344 行的 statestarttime 的区别很重要：
--     · timeinstate   = **累计活跃时长**，每帧加 dt（651 行）
--     · statestarttime= 进入状态的**绝对时刻**（598 行，只赋值一次）
--   ★ 所以休眠中的状态图，其 timeinstate 增长会远慢于真实时间
--     （因为休眠期间不 Update，不加 dt）。
--   ★★ 这是刻意的：timeline 的语义是「动画帧」，
--     而动画只在活跃时推进，休眠不该推进动画进度。
--     → 推论：状态图休眠期间，时间线是「暂停」的。
    self.timeinstate = 0
--【★ lastupdatetime = 0 —— 上次 Update 的绝对时刻，用于算 dt】
--   ★ 为 0 而非 nil：见 720-722 行，`if self.lastupdatetime then` 对 0 为真
--     （Lua 里 0 是真值），所以首帧会算出一个巨大的 dt。
--   ⚠ 但实际上 GoToState 末尾（597 行）会把它设为 GetTime()，
--     所以这个 0 只在「构造后未进任何状态就被 Update」时才会用上。
--     那种情况下 718 行的 Update 会因为 currentstate 为 nil 而在 728 行崩 ——
--     见 728 行的 ⚠ 说明。
    self.lastupdatetime = 0
--★★【★ timelineindex：timeline 的实例级游标 —— 定义共享、进度独立】
--   ★ 指向 State.timeline（253 行）里的下一个待触发节点下标。
--   ★★ nil 的含义有**两种**，务必区分：
--     ① 这个状态没有 timeline（584-588 行的 else 分支）
--     ② timeline 已播完（672-674 行播完时置 nil）
--   ★★ 668 行的 while 条件依赖这个字段做短路：
--     `self.timelineindex and ...` —— nil 时整段跳过，零开销。
--   ★ 这是本文件的性能技巧：timeline 播完后连 while 判断都是常量 false。
    self.timelineindex = nil
--【★★ laststate：上一个状态对象 —— 实现 InNewState 的唯一依据】
--   ★ 对比 lasttags（551 行，只在 onenter 期间有效）：
--     laststate 是**永久**的（直到下次 GoToState）；
--     lasttags 是**瞬态**的（591 行 onenter 之后立刻被清空）。
--   ⚠ 这个不对称经常让人误用。
    self.laststate = nil
--★★★【★★ bufferedevents：延迟事件队列 —— 事件机制的数据载体】
--   ★★ 这是整个「刻末批处理」设计的落地容器：
--     PushEvent（392 行）只往这里塞；
--     HandleEvents（473 行）在刻末统一取出并派发。
--   ★ 它是**实例级**的，不是 SGManager 级 ——
--     所以事件本体与「谁该处理」的调度标记是分开的（见 8 行 haveEvents）。
--   ★★★ 换表式清空（490-494 行）而非逐个置 nil，是本文件最关键的技巧：
--     正因为是换表，正在遍历旧表的 ipairs（478 行）才不会崩。
--     → 92 行的 RemoveInstance 与 480 行的检查都依赖这一点。
--     详见 490-494 行的详细说明。
    self.bufferedevents={}
--【★ inst：宿主实体。State 里的一切 self.inst 都指向它】
--   ★ 事件处理器签名 function(inst, data) 的 inst 就是它（268/469 行）。
    self.inst = inst
--【★ tags：当前状态的标签集合 —— 状态图对外暴露的「布尔属性」】
--   ★★★ 由 GoToState 从 State.tags 复制而来（553-557 行），
--     并可运行时增删（AddStateTag / RemoveStateTag，602-614 行）。
--   ★ 这就是为什么 tag 能跨越状态边界存在：
--     运行时加的 tag（如 monster:AddStateTag("nointerrupt")）
--     会在**下一次** GoToState 时被重置（552 行 self.tags = {}）。
--   ⚠ 因此「永久 tag」必须走实体标签（inst:AddTag）而非状态 tag。
	self.tags = {}
--★★★【★★★ statemem：本文件最重要的易错点 —— 「本状态的工作区」】
--   ★★★ 三层记忆的分工（本文件必须背下来的表）：
--     ┌ statemem ┬ 每次 GoToState 被**清空**（550 行）
--     │          └ 用途：本状态内部的工作数据（当前攻击目标、进度标记…）
--     │            ★★ 见下方 H2 说明
--     ├ mem      ┬ 跨状态**保留**，只随实体销毁而清
--     │          └ 用途：整个状态图生命周期内都需要的数据（配置、缓存）
--     └ 实体自身 ┬ 存 inst 上或组件上
--                └ 跨实体/跨机制的共享数据
--   ⚠⚠⚠ H2 缺陷（本项目 bug-patterns.md 已收录）：
--     「跨状态传递的数据丢失（statemem 在 GoToState 时被清空）」
--     —— 根因就是本行的对应清空语句 stategraph.lua:550。
--     若你的 timeline 事件在 20 帧后触发，期间发生任何 GoToState，
--     statemem 里的数据就没了。
--     → 原版的正确用法：把数据塞进 statemem 后，**只在同一个状态的
--       timeline 里消费**（即「写入者与读取者必须是同一次状态进入」）。
--     → 跨状态要传的，用 GoToState 的 params 参数（onenter 收到）或 mem。
--   ⚠ 本条已核实源码：550 行确实是 `self.statemem = {}`，无条件清空。
    self.statemem = {}
--★★【mem：跨状态持久数据 —— statemem 的正确替代品】
--   ★ 全文件只有构造时初始化一次，GoToState 从不清它。
--   ★ 典型用途：状态图级别的缓存、AI 参数、跨状态的目标记忆。
--   ⚠ 代价：实体不销毁就不会释放，长生命周期的怪物要注意别无限增长。
    self.mem = {}
--【★ statestarttime：进入当前状态的绝对时刻（GetTime() 基准）】
--   ★ 与 335 行的 timeinstate 的区别见 335 行注释。
--   ★ GetDebugTable（363 行）与 __tostring（374 行）都用它显示「停留时间」，
--     但那显示的是**真实**停留时间（含休眠），不是 timeinstate。
    self.statestarttime = 0
end)

--★★【RenderDebugUI：调试面板注册 —— 提供「打开状态历史」入口】
--   ★ 由 debugui 框架反射调用（方法名固定为 RenderDebugUI）。
--   ★★ 只有**开发构建**会走这条路，正式构建里 debugui 模块不存在。
--   ★ 注意 351 行的 require 写在函数体内（惰性加载）：
--     因为 dbui_no_package/debug_nodes 是个大模块，
--     无条件 require 会拖慢所有实体状态图的加载。
--   ★ 这是一个很值得学的惰性加载范式。
function StateGraphInstance:RenderDebugUI(ui, panel)
	-- Don't have a specific stategraph debugger for DebugNodeName, but viewing
	-- our History is pretty useful.
--【★ 按钮文案带上实体名 —— 调试时能区分一堆同种怪物】
	if ui:Button("Open History for: ".. tostring(self.inst)) then
--【★★★ 惰性 require 的典型写法：只在用户真的点按钮时才加载调试模块】
--   ★ 代价：拼错的模块名要到运行时点击才报错，而非启动时。
		local DebugNodes = require "dbui_no_package/debug_nodes"
		SetDebugEntity(self.inst)
		panel:PushNode(DebugNodes.DebugHistory())
	end
end

--★★【GetDebugTable：把内部状态导出成一张可读的表 —— 排查状态机问题的主力工具】
--   ★★★ 导出内容与排查价值对照：
--     name     → 状态图名，确认加载的是哪个文件
--     current  → 当前状态名，99% 的「AI 卡住了」都靠这一行定位
--     ticks    → 已停留**帧**数（除以 FRAMES 换算）—— 数值异常小 = 刚进状态就卡
--     tags     → 状态标签，注意这是**快照**（shallowcopy）
--     statemem → ★ 最有用：能直接看到本状态工作区里有什么、还剩什么
--   ★★ 「statemem 是空的」本身就是一条诊断信息：
--     说明状态刚进入（onenter 没写任何东西），或发生了意外的 H2 数据丢失。
--   ★ shallowcopy 而非 deepcopy：状态表可能有大量键，深拷贝在调试路径上太贵。
--     只需「看一眼」的语义下浅拷贝足够。
function StateGraphInstance:GetDebugTable()
--【Profiler：GetDebugTable 本身也会被性能剖析器统计】
--   ★ 说明这个方法在开发期被调用得很频繁（debugui 每帧刷新）。
	TheSim:ProfilerPush("[SGI] GetDebugTable")

	local ret = {
		name = self.sg.name,
--【★ current 可能为 nil（未进任何状态），所以要有 <>None 兜底】
		current = self.currentstate and self.currentstate.name or "<None>",
--【★ 除以 FRAMES 把秒转成帧 —— 显示单位与动画帧对齐，便于对照排查】
--   ★ 用 GetTimeInState()（383 行）而非 timeinstate（335 行）：
--     前者含休眠时长，反映「实际卡了多久」，排查问题时更有用。
		ticks = math.floor(self:GetTimeInState() / FRAMES),
--【★ shallowcopy：浅拷贝，防止 UI 拿到的是活引用被误改】
--   ★ tags / statemem 都是哈希表，用浅拷贝即可（值是布尔/标量）。
		tags = shallowcopy(self.tags),
--★★【★ statemem 快照 —— 调试 H2 类数据丢失问题的关键入口】
--   ★★ 用法：状态卡住时看这张表。如果本该有值却是空的，
--     大概率就是被某次意外的 GoToState 清掉了（550 行）。
		statemem = shallowcopy(self.statemem),
	}

	TheSim:ProfilerPop()

	return ret
end

--★★【__tostring：实例的完整调试字符串 —— 比定义版（327 行）信息多得多】
--   ★ 格式：sg 名 + 状态名 + 已停留时间 + 全部 tag。
--   ★ 用于 print(inst.sg) 或塞进错误信息。
function StateGraphInstance:__tostring()
--【★★ 三段信息一次打完：哪个状态图、哪个状态、停了多久】
--   ★ 注意用 GetTime() - statestarttime（含休眠），与 363 行一致。
--   ⚠ 访问 self.currentstate.name 不做 nil 检查 ——
--     若实例还没进任何状态就会崩。
--     实践中调用 tostring 的地方通常已经进状态了，故不视为缺陷。
    local str =  string.format([[sg="%s", state="%s", time=%2.2f]], self.sg.name, self.currentstate.name, GetTime() - self.statestarttime)
    str = str..[[, tags = "]]
    for k,v in pairs(self.tags) do
        str = str..tostring(k)..","
    end
    str = str..[["]]
    return str
end

--★★【GetTimeInState：真实停留时长 —— 与 timeinstate 的区别是本文件的经典考点】
--   ★ timeinstate（335 行）    = 累计被 Update 的时长（休眠时不增长）
--   ★ GetTimeInState()（本函数）= GetTime() - statestarttime（含休眠）
--   ★★ 什么时候必须用 GetTimeInState：
--     · 冷却判定（「被攻击后 1 秒内免疫」）—— 玩家感知的是真实时间
--     · 调试显示
--   ★★ 什么时候必须用 timeinstate：
--     · timeline 进度（668 行）—— 因为动画在休眠时不推进
--     · ontimeout 判定相关逻辑
--   ⚠ 混用会造成「看起来卡住了其实只是睡了」的误判。
function StateGraphInstance:GetTimeInState()
    return GetTime() - self.statestarttime
end

--★★【PlayRandomAnim：从动画列表里随机播一个 —— 状态表现层的基础工具】
--   ★ 用法：idle 状态在 onenter 里调它，让怪物待机动作有变化。
--   ★★ 这就是「状态驱动动画」在本文件里的**唯一**直接入口：
--     状态图本身不碰 AnimState，只通过这类 helper 间接触发。
--     （另一个入口是状态图文件里直接 inst.AnimState:PlayAnimation(...)，
--       更常见，见 SGbat.lua 的 anims 表。）
function StateGraphInstance:PlayRandomAnim(anims, loop)
    local idx = math.floor(math.random() * #anims)
--★【★ AnimState:PlayAnimation —— 真正驱动骨骼/精灵动画的 C++ 调用】
--   ★★ anims[idx+1] 的 +1 不能省：
--     math.floor(math.random() * #anims) 的取值范围是 [0, #anims-1]（含 0）。
--     ★ 因为 Lua 的 math.random() 可能返回恰好 0（概率极低但非零），
--       直接用 anims[idx] 有约 1/#anims 的概率拿到 nil → 崩溃。
--     +1 把 [0, n-1] 平移成 [1, n]，这是 Lua 里取随机表元素的惯用手法。
--   ★ 这是一个很值得记住的防御性细节：Lua 的 math.random() 不是 (0,1) 开区间。
    self.inst.AnimState:PlayAnimation(anims[idx+1], loop)
end

--★★★【★★ PushEvent：把事件放进缓冲区 —— 不是立即处理！】
--   ★★ 语义澄清（很多误解来自这里）：
--     · PushEvent       = 入队，**当前帧不处理**，等刻末统一派发
--     · HandleEvent     = 立即派发一条
--     · HandleEvents    = 派发缓冲队列里的全部
--   ★ 为什么必须延迟？因为 Update 期间改状态会重入（145 行的详细分析）。
--     延迟到刻末就完全免疫了。
--     ★ 代价：事件响应最慢延迟一帧（1/30 秒）。
--   ★ PushEvent 的调用方通常是 EntityScript:PushEvent（entityscript.lua:1307），
--     那里还先做了 IsListeningForEvent 的短路判断。
function StateGraphInstance:PushEvent(event, data)
--【★ 有 data 就地打上状态标记 —— 见 265 行的「事件归属校验」机制】
    if data then
        data.state = self.currentstate.name
    else
--★★★【★ 无 data 时现场造一个只带状态标记的 data —— 保证 265 行的比对总能用上】
--   ★★★ 这就是「事件归属」机制的写入端：
--     无论事件带不带 payload，都必须带上「入队时的状态名」，
--     否则 265 行的 data.state == nil 分支会放行，
--     事件就可能被错误状态的处理器消费。
--   ★ 写成 data = {state = ...} 而非复用 data 表，是为了不污染调用方的表。
        data = {state = self.currentstate.name}
    end
--【★★ 入队：{name=事件名, data=载荷} 作为一个整体追加】
--   ★ 用 table.insert 而非 hashed 结构 —— 事件必须**保序**（先进先出）。
--     这是本文件唯一需要顺序语义的结构。
--   ⚠ 无上限。理论上事件可以无限堆积（每帧 PushEvent 不被处理时），
--     实际有 145 行的每帧清空做保证。
    table.insert(self.bufferedevents, {name=event, data=data})
end

--★★【IsListeningForEvent：任一层有人监听就算「在听」】
--   ★★★ 调用点在 entityscript.lua:1307，是事件入队的**前置门卫**：
--       elseif self.sg:IsListeningForEvent(event) and SGManager:OnPushEvent(self.sg) then
--   ★★ 为什么要这个门卫？——性能。
--     若当前状态和全局表都没人监听这个事件，入队纯属浪费：
--     占内存、进表、刻末还要遍历一次却什么都不做。
--     ★ 游戏里每秒广播的事件量极大（见 bug-patterns.md F1），
--       这个判断是热路径上最重要的一道过滤。
--   ★★ 注意是「或」语义：状态私有（402 左）或全局（402 右）任一命中即算。
--     优先级（谁先处理）见 463-471 行，是另一个问题。
--   ⚠ 但 hasEvents 标记仍会被设置（39 行）—— 即使没人监听也会入队？
--     不会：entityscript.lua:1307 是 `and` 短路，
--     IsListeningForEvent 为假就不调 PushEvent，OnPushEvent 也不会被调。
--     两道门卫是串联的。
function StateGraphInstance:IsListeningForEvent(event)
    return self.currentstate.events[event] ~= nil or self.sg.events[event] ~= nil
end

--★★★【★★ PreviewAction：玩家「按住不放」时的即时反馈路径 —— 预测的关键】
--   ★★ 这条路径与 StartAction（430 行）是**平行实现**，必须成对理解：
--     PreviewAction = 按下的瞬间（客户端预测，立刻给反馈，不等服务端）
--     StartAction    = 服务端权威执行（真正做事）
--   ★★ 为什么需要 Preview：联机时按下攻击到服务器回包有 100-300ms 延迟，
--     没有预测的话角色会「按了没反应」。
--   ★★ PreviewAction 的三条出口（务必逐一对照理解）：
--     ① 有 handler 且 condition 为假 → 什么都不做（return nil）
--        ⚠ 见 409 行 ⚠ 与 H1 条目
--     ② 有 handler 且 deststate 返回状态名 → 切状态，return true
--     ③ 无 handler 且动作非 instant → 切到通用 previewaction 状态
--     ④ 其他情况 → 走 PerformPreviewBufferedAction（真正的底层预览）
--   ★★ 注意：PreviewAction **不设置** statemem.is_going_to_action_state，
--     而 StartAction 设置（438 行）。这个不对称有实际后果，见 438 行 ⚠。
function StateGraphInstance:PreviewAction(bufferedaction)
    if self.sg.actionhandlers ~= nil then
        local handler = self.sg.actionhandlers[bufferedaction.action]
        if handler ~= nil then
--⚠⚠【★★ 疑似缺陷：condition 为假时**静默返回 nil**，与 H1 条目同族】
--   ★ 推理依据：此处 `return`（无值）即返回 nil，调用方看到 nil 就当
--     「预览未被受理」，但**没有任何日志**。
--     若 handler.condition 写得比较严格（例如「必须手上有正确的工具」），
--     玩家会看到「按住攻击键，角色毫无反应」。
--   ★★ bug-patterns.md 的 H1 条目记录的正是这个现象
--     （「走到某东西面前站着不做任何事」），根因指向 StartAction:430。
--     PreviewAction 是同一模式的两处实现之一。
--   → 排查方法：在 condition 内首行加
--     print("[sg] preview reject", self.inst.prefab, bufferedaction.action)
--   ⚠ 本条为代码阅读推断，未在运行时验证。
            if handler.condition ~= nil and not handler.condition(self.inst) then
                return
--【★ deststate 存在时才走状态切换分支；否则落到 420 行】
            elseif handler.deststate ~= nil then
--【★ 运行时才调 deststate —— 同一个 handler 可以根据上下文选不同状态】
                local state = handler.deststate(self.inst, bufferedaction)
--【★ 返回 nil 表示「这个动作现在不该发生」—— deststate 有权拒绝】
--   ★ 见 SGbat.lua:7-13 的例子：GOHOME 时若目标是 sinkhole 就返回 flyaway，
--     否则返回 action。deststate 也可以返回 nil 来表达「拒绝」。
                if state ~= nil then
--【★★ 真正的预测动作：立刻切到「起手」状态，动画马上播出来】
--   ★ 这是玩家感知「即时」的全部来源。
--   ⚠ 与 439 行 StartAction 的 GoToState 相比，缺少 441-449 的快进逻辑，
--     也缺少 438 行的 statemem 标志。两个方法的差异见 430 行的对照说明。
                    self:GoToState(state)
                    return true
                else
                    return
                end
            end
--★★【★ 无 handler 的兜底路径：非瞬时动作统一进 previewaction 状态】
--   ★★ 语义：状态图没为这个动作定义专门状态时，
--     用一个通用的「正在预览动作」状态顶一下。
--   ★ 为什么排除 instant 动作？instant 动作（如 USEITEM）
--     没有起手动作，不需要视觉反馈，直接执行即可。
--   ⚠⚠ 隐藏坑：走这条路径时**不检查动作是否合法**——
--     任何没配 handler 的动作都会切到 previewaction 状态。
--     若某个状态图漏配了某个动作的 handler，
--     表现是「角色摆出动作姿势但什么都没做」，而不是报错。
--     → 排查「角色做了个奇怪动作」，先查该状态图的 actionhandlers 表是否缺项。
        elseif not bufferedaction.action.instant then
--【★ 通用状态名 —— 各状态图需自行定义这个状态，见 stategraphs/commonstates.lua】
            self:GoToState("previewaction")
            return true
        end
    end

--★【★★ 最后的兜底：交还给实体的预览机制（EntityScript:PerformPreviewBufferedAction）】
--   ★ 这条路径通常会：把物品举起来 / 显示挖掘进度条 / 播放预演音效。
--   ★ 与 414 行是**互斥**的两条路：有 deststate 就不会走到这里。
    self.inst:PerformPreviewBufferedAction()
    return true
--【PreviewAction 结束，无条件返回 true —— 「预览已被受理」】
end

--★★★【★★ StartAction：动作的权威执行 —— 与 PreviewAction 平行且不对称】
--   ★★ 两者的差异表（★ 移植时必须同改，否则联机表现不一致）：
--     ┌────────────────────┬──────────────────┬──────────────────┐
--     │                    │ PreviewAction     │ StartAction      │
--     ├────────────────────┼──────────────────┼──────────────────┤
--     │ is_going_to_      │ 不设置            │ ★设置(438)      │
--     │   action_state     │                   │                  │
--     │ 预测快进            │ 不做              │ ★做(441-449)    │
--     │ 无 handler 兜底    │ 切 previewaction   │ ✘ 直接返回 nil  │
--     │ handler 存在但     │ return nil         │ ✘ 落出函数=nil  │
--     │ condition 为假     │                   │                  │
--     └────────────────────┴──────────────────┴──────────────────┘
--   ★★ 为什么要 is_going_to_action_state 这个标志？
--     因为 GoToState 会清空 statemem（550 行），状态切换的副作用
--     （比如关闭容器 UI）无法区分「用户主动关闭」与「动作导致的切换」。
--     SGwilson.lua:631 就靠它判断「物品栏是否该保持打开」。
--   ⚠⚠ 但 438 行设置的时机在 GoToState(439) **之前**，
--     而 GoToState 的 550 行会清空 statemem —— 这个标志很可能立刻被抹掉！
--     详见 438 行的详细分析。
function StateGraphInstance:StartAction(bufferedaction)
--【★ 与 406 行同样的 nil 判断，但写得更宽松（没有 ~= nil，直接 if）】
--   ★ 因为 actionhandlers 在 StateGraph 构造时必定被 reindex 成哈希表（282 行），
--     这里永不为 nil。
    if self.sg.actionhandlers then
        local handler = self.sg.actionhandlers[bufferedaction.action]
--【查动作路由表】
        if handler then
--★★【★ condition 校验 —— 与 409 行的写法差异很大，注意对比】
--   ★ 本行是 `if not handler.condition or handler.condition(self.inst) then`：
--     · condition 为 nil → 视为通过（动作处理器可以无条件生效）
--     · condition 有值   → 调用它，返回 true 才通过
--   ★★ 对比 409 行 PreviewAction 的写法：
--       `if handler.condition ~= nil and not handler.condition(self.inst) then`
--     ★ 两者逻辑上等价，但**结构完全相反**：
--       本行是「通过则执行主体」，条件不通过时**落出函数返回 nil**；
--       PreviewAction 是「不通过则提前 return」，通过时继续往下。
--     ★★ 这个结构差异直接导致了 H1 缺陷的差异：
--       PreviewAction 的不通过路径有一行 `return` 显式离开；
--       StartAction 的不通过路径是**隐式落出**，更隐蔽。
--   ⚠⚠ H1 缺陷（bug-patterns.md 已收录，根因即此处）：
--     condition 为假 → 函数落出 → 返回 nil →
--     调用方（locomotor 等）已经走到目标位置了，
--     却等不到任何状态切换 → 「走到某东西面前站着不做任何事」。
--     ⚠ 推理依据：434-458 的 if 嵌套里，condition 为假时没有任何 else，
--       函数体直接结束，隐式返回 nil。
--     ⚠ 这是代码阅读推断，未在运行时验证。
--     → 规避：调用方（locomotor:PushAction）应检查 StartAction 的返回值，
--       为假时至少打印一条日志。
            if not handler.condition or handler.condition(self.inst) then
--【★ deststate 存在才走状态切换；否则 453 行直接执行动作】
                if handler.deststate then
--【★ 与 412 行相同：运行时决定目标状态】
                    local state = handler.deststate(self.inst, bufferedaction)
                    if state then
--⚠⚠⚠【★★ 疑似缺陷：标志在 GoToState 之前设置，而 GoToState 会清空 statemem】
--   ★★★ 严格执行顺序（本行 → 439 行 → 550 行）：
--       438: self.statemem.is_going_to_action_state = true   ← 设置
--       439: self:GoToState(state)
--              └─ 550: self.statemem = {}                    ← 清空！
--       591: self.currentstate.onenter(self.inst, params)     ← 新状态读取
--   ★★ 也就是说：**新状态的 onenter 里读 statemem.is_going_to_action_state
--     读到的一定是 nil**，因为它在 439 行就被清了。
--   ⚠ 推理依据：
--     · 550 行确实是 `self.statemem = {}`（无条件清空，已核实）
--     · 439 与 550 之间没有其他对 statemem 的赋值
--     · 439 行 GoToState 内部在 550 行之前只读不写 statemem
--       （538 onexit 会读，但那是 onexit 不是 onenter）
--   ★★ 佐证：actions.lua:3305 也用同样的顺序，但那里是**故意**的：
--       --V2C: kinda hack since USEITEM is instant action, and the useableitem will
--             likely force state change (bad!) instead.
--             act.doer.sg.statemem.is_going_to_action_state = true
--             local ret = ...StartUsingItem(doer)
--             --And clear it now in case no state change happened
--             act.doer.sg.statemem.is_going_to_action_state = nil
--     → 那里的模式是「设了立刻清，因为状态切换会清它，只是不切就手动清」，
--       说明作者**清楚** statemem 会被 GoToState 清空。
--       但本文件 438-439 行的写法与之矛盾：设了之后立刻就切状态，
--       等于没设。
--   ★★★ 实际影响：SGwilson.lua:631 的判断
--       `if not stayopen and inst.sg.statemem.is_going_to_action_state then`
--       在**通过 StartAction 进入**目标状态的路径上恒为假，
--       表现为「执行动作时物品栏被误关」（本应保持打开却关上了）。
--   → 修复方向：把设置移到 GoToState **之后**（440 行之后），
--     或改用 onenter 的 params 传入。
--   ⚠ 本条为代码阅读推断，未在运行时验证。
						self.statemem.is_going_to_action_state = true
--【★★ 进入动作状态 —— 注意它会清空 statemem（550 行），见 438 行 ⚠】
                        self:GoToState(state)

--★★【★ 预测快进段：让客户端动画立刻演到位，消除一帧延迟】
--   ★★ 问题背景：客户端预测执行了动作 → 状态切到「起手」→
--     但时间线的第 0 帧是在**下一次** Update 才触发（因为时间已过）。
--     如果不管，动画会慢一帧起步，看起来「手先动了、姿势后跟上」。
--   ★ 解法：把 lastupdatetime 往前拨 time_to_fastforward（FastForward，755 行），
--     于是下次 Update 算出的 dt 变大，时间线立刻追赶到当前位置。
--   ★ 同时把 AnimState 的时间也推进，保证动画与状态图同步。
--   ⚠ 条件严格：必须是「远端玩家 + 服务端权威 + 非 no_predict_fastforward」，
--     否则会给非预测路径也快进，造成状态与权威结果错位。
						--V2C: (#HACK?) skip frames for predicted actions
--★【★ 双重豁免检查：状态级（statemem）与动作级（options）任一禁止就不快进】
--   ⚠⚠ 疑似缺陷：self.statemem.no_predict_fastforward **恒为 nil**。
--     推理依据：State 的这个字段在 242 行存为 self.no_predict_fastforward，
--       570 行拷到 StateGraphInstance 的 self.no_predict_fastforward，
--       **没有任何一行把它写进 statemem**。
--       而 statemem 每次 GoToState 都被清空（550 行），
--       439 行刚执行完更是全新的空表。
--     → 条件退化为只看 bufferedaction.options.no_predict_fastforward。
--     → 「按状态禁止预测快进」这条能力实际是死代码。
--     → 修复方向：改读 self.no_predict_fastforward（570 行已备好）。
--   ⚠ 本条为代码阅读推断，未在运行时验证。
						if not (self.statemem.no_predict_fastforward or bufferedaction.options.no_predict_fastforward) then
--【★ 取 playercontroller —— 只有玩家有，怪物走不到这个分支】
							local playercontroller = self.inst.components.playercontroller
--★★【★ 双重条件：remote_predicting（正在预测别人）且 remote_authority（我是权威）】
--   ★★ 两个词容易混：
--     · remote_predicting = 我在替**别的玩家**做预测
--       （比如我要看队友砍树，本地先演一遍）
--     · remote_authority  = 我是这段操作的权威方
--   ★★ 为什么要两个都满足？因为只有「替他人预测且我有权威」的场景下，
--     快进才不会与真正的权威结果冲突。
--   ★ 怪物实体没有 playercontroller（443 行判空），自动跳过。
							if playercontroller ~= nil and playercontroller.remote_predicting and playercontroller.remote_authority then
--【★ 一帧的时长就是快进的基准量】
								local dt = GetTickTime()
--★★【★ 把 AnimState 的播放时间也推进同样的量 —— 动画与状态图必须同步】
--   ★★ 这一行是本段最容易被漏掉的细节：
--     只快进状态图（447 行）而不动 AnimState，
--     就会「逻辑已到第 3 帧，动画还在第 0 帧」，
--     表现为起手姿势慢半拍。
--   ★ GetCurrentAnimationTime 拿的是当前动画已播放时长。
--   ⚠ 依赖 AnimState 存在。玩家实体一定有，但若某 prefab 无 AnimState，
--     会在此崩（无判空）。实践中动作类 prefab 都有 AnimState。
								self.inst.AnimState:SetTime(self.inst.AnimState:GetCurrentAnimationTime() + dt)
--【★ FastForward：只改 lastupdatetime（见 755 行），不动其他时间基准】
--   ★★ 这是个**极小但极关键**的手法：
--     不改 timeinstate、不改 statestarttime，只改「上次更新时间」，
--     于是下一次 Update 的 dt 变大，UpdateState 自动把 timeline 追上来。
--   ★ 副作用最小化 —— 这就是它比「直接加 timeinstate」更优的原因。
								self:FastForward(dt)
							end
						end
                    else
                        return
                    end
                else
--【★ 无 deststate 的动作：不切状态，直接执行（ACTIONS 的 strfn/doer_fn）】
--   ★ 这条路径用于「纯数据操作」类动作（开关箱子、捡东西）。
--   ★ 与 426 行的 PerformPreviewBufferedAction 的区别：
--     这里是**真执行**（产生实际效果），那里只是预览。
                    self.inst:PerformBufferedAction()
                end

--【★ return true：动作已被受理。调用方据此决定是否清掉缓冲动作】
--   ★★ 这个返回值是调用方唯一的反馈通道：
--     true  → 动作进入了动作状态，接下来由状态图的 timeline 推进
--     nil   → 动作没被受理（434 行条件不通过）
--   ⚠ 也正因如此，434 行的静默失败会一路传到 locomotor，
--     形成 bug-patterns.md H1 描述的「走到跟前站着不做任何事」。
                return true
            end
        end
    end
end

--★★★【★★ HandleEvent：两级事件派发 —— 状态私有优先，全局兜底】
--   ★★★ 派发顺序（★ 这个顺序决定了一堆「重复响应」的 bug）：
--       ① 先问 currentstate.events[eventname]（状态私有，如 attack 的受击处理）
--       ② 若 ① 返回非真值（没处理），再问 sg.events[eventname]（全局，如 CommonHandlers）
--   ★ 为什么状态私有优先？举例「受击」：
--     · 在 attack 状态：必须用 attack 的处理器（它知道怎么打断攻击）
--     · 在 idle 状态：attack 的处理器根本不该被调用
--     → 只有「当前状态明确说自己要处理」才轮得到全局处理器，
--       这个优先级保证了状态相关的正确性。
--   ★★ 双重保险：状态私有处理器内部还会做 265 行的「事件归属校验」，
--     确保用的是入队时的状态而非当前状态。
--   ⚠ 处理器必须 return true 表示「我处理了」，否则会**双重响应**。
function StateGraphInstance:HandleEvent(eventname, data)
	data = data or {}
--★★【★ 第一级：问当前状态。`not ...` 取反是为了走「未处理」分支】
--   ★ 若状态处理器返回 nil/false → 进入 466 行问全局表。
--   ★★ 这里的 `not` 是必要的：不能写成 `if ... then` 然后在 else 里
--     问全局，那样会丢掉「返回 nil 但确实处理了」的语义。
	if not self.currentstate:HandleEvent(self, eventname, data) then
--【★ 第二级：问状态图全局事件表（含 mod 注入的）】
		local handler = self.sg.events[eventname]
		if handler ~= nil then
--【★ 全局处理器的调用签名与状态私有一致：fn(inst, data)】
--   ★ 注意没有「处理了就 return」的约定 —— 全局处理器是最后一级，
--     没有后续派发，所以返回值无所谓。
			handler.fn(self.inst, data)
		end
	end
end

--★★★【★★ HandleEvents：把缓冲队列里的事件全部派发出去】
--   ★ 由 SGManager:UpdateEvents（154 行）每帧调用一次。
--   ★★★ 三个关键点：
--     ① 事件保序处理（ipairs 从头到尾）
--     ② 每个事件处理后都检测「缓冲表是否被换掉」（480 行）
--     ③ 派发前检测实体有效性（476 行）
--   ★★ 顺序很重要：「受击」与「死亡」同时入队时，
--     必须按入队顺序处理，否则可能出现「死后又播受击音效」。
function StateGraphInstance:HandleEvents()
--【★★ 防御性断言：绝不在没有状态时派发事件】
--   ★ 因为 HandleEvent 内部要访问 currentstate（465 行），
--     currentstate 为 nil 会直接崩。
--   ⚠ 用 assert 而非 if return：说明作者认为「无状态时有事件」是不可接受的。
--     实际触发路径：状态图已 Stop 但实体还活着 → 但 Stop 时
--     92 行 ClearBufferedEvents 已经清空了，所以正常不会触发。
    assert(self.currentstate ~= nil, "we are not in a state!")

--★★★【★ 实体有效性检查 —— 事件处理期间实体可能已被销毁】
--   ★ 场景：队列里有 3 个事件，第 1 个的处理函数里调了 inst:Remove()。
--     若不检查，第 2、3 个事件会操作已销毁的实体 → 崩溃或幽灵行为。
--   ★ 与 480 行是**互补**的两道保险：
--     476 行拦「实体死了」，480 行拦「缓冲表被换了」（状态图死了）。
    if self.inst:IsValid() then
        local buff_events = self.bufferedevents
--【★ 用局部变量 buff_events 持有当前表 —— 这是换表检测能生效的前提】
        for k, event in ipairs(buff_events) do
--【★★ 逐条派发，每条独立走 463 行的两级派发】
			self:HandleEvent(event.name, event.data)
--★★★【★★ 「表被换掉了」的检测 —— 与 92 行 RemoveInstance 配套】
--   ★★ 原理：ClearBufferedEvents（490 行）是**换表**（self.bufferedevents = {}），
--     不是逐个置 nil。所以局部变量 buff_events 仍指向旧表，
--     而 self.bufferedevents 已指向新表，两者不等 → 说明发生了清除。
--   ★ 为什么必须提前收工？
--     若某个事件处理器销毁了实体 → RemoveInstance → 92 行 ClearBufferedEvents。
--     此时**旧表里剩下的事件已经无效**（处理的实体都没了），
--     继续遍历只会浪费并可能触发幽灵行为。
--     → return 直接退出，连末尾的 ClearBufferedEvents 都不执行（已经清了）。
--   ★★★ 这三行（476/480/92）是同一套防御的三面，缺一不可：
--     · 92 行   提供「换表」这个动作
--     · 480 行  检测到换表并止损
--     · 476 行  兜住「实体死了但表没换」的情况
--   ⚠ 修改本文件时绝不能只删一处。
            if buff_events ~= self.bufferedevents then
                --V2C: This happens if ClearBufferedEvents() is called in a state handler
                return
            end
        end
    end

    self:ClearBufferedEvents()
end

--★★★【★★ ClearBufferedEvents：换表式清空 —— 本文件最精妙的技巧之一】
--   ★★★ 为什么不能逐个置 nil / 用 table.remove？
--     因为**可能正在被遍历**（478 行 ipairs）。
--     Lua 中在遍历中修改表（增删键）是未定义行为。
--     换表则完全绕开：正在遍历的旧表一个字节都没动，
--     新表是干净的空表，遍历自然按原长度结束。
--   ★★ 三个受益者：
--     ① 478 行的 ipairs 安全（旧表不受影响）
--     ② 480 行可以靠「表引用变了」来检测到清除发生
--     ③ 92 行 RemoveInstance 可以放心调用它来丢弃事件
--   ★ 与 118-119（updaters 换表）是**完全同构**的手法，
--     同一个作者在同一个文件里的两次应用。
--   ★ 与 SGManager:UpdateEvents 的 haveEvents 换表（149-150）
--     是同一思想在三个层次的第三次应用。
function StateGraphInstance:ClearBufferedEvents()
--【★ 空队列时直接返回 —— 绝大多数帧队列都是空的，这个早退很值钱】
    if #self.bufferedevents > 0 then
--【★★ 换表：旧表交给还在遍历的 ipairs，新表接住后续 PushEvent】
--   ★★ 于是「处理期间新来的事件」会自动落到新表，下一帧才处理。
--     这就是「刻末批处理」能自洽的最后一环。
        self.bufferedevents = {}
    end
end

--★★【InNewState：「本帧是否刚进入新状态」—— 供外部判断该做什么初始化】
--   ★ 用法：Brain 或组件在 onupdate 里问「状态刚变了吗」，
--     是的话做一次性的准备工作（如重新寻路）。
--   ★★ 实现是极简的引用比较：laststate ~= currentstate。
--   ⚠ 局限：只在**恰好那一帧**为真。
--     如果某系统休眠了、错过了这一帧，就永远等不到 true。
--     → 所以更可靠的做法是把初始化写在 onenter 里。
--     InNewState 只适合「不一定需要重新初始化」的轻量检查。
function StateGraphInstance:InNewState()
--【★ 纯引用比较 —— 没有时间窗口判断，也没有「进入第几帧」的概念】
	return self.laststate ~= self.currentstate
end

--★★★【★★ SGTagsToEntTags：状态 tag → 实体 tag 的自动同步白名单】
--   ★★ 这是全文件最容易被忽略、但影响面极广的一段机制。
--   ★ 机制（实现在 551-566 行）：
--     状态图每次 GoToState，都把这张表里的每个 key 检查一遍：
--       · 当前状态有这个 tag → inst:AddTag(key)
--       · 当前状态没有这个 tag → inst:RemoveTag(key)
--     ★★ 结果：实体标签自动跟随状态图变化，无需任何手工同步。
--   ★★★ 为什么需要这层间接？——因为外部系统只认实体标签：
--     · locomotor 检查 inst:HasTag("busy") 决定能否移动
--     · combat 检查 "noattack" 决定能否攻击
--     · interactable / highlighted 等交互逻辑检查 "doing"
--     · AI 检查 "idle" 决定能否被打扰
--     若状态图直接改实体标签，这些外部系统就得改成问状态图 ——
--     耦合爆炸。白名单机制提供了稳定的中间层。
--   ★★ 为什么用**白名单**而不是全部同步？
--     因为实体标签种类极多（含 mod 标签、组件标签），
--     全量同步会误伤别的系统。所以只有这一小撮「状态语义标签」才自动同步。
--   ⚠ 白名单是**硬编码**的：新增状态 tag 想同步到实体，
--     必须先加到这张表里，否则静默失效。
--   ⚠ AddStateTag（602 行）/ RemoveStateTag（609 行）也会走同一条同步路径，
--     所以运行期动态加 tag 同样会同步到实体 —— 这一点是自洽的。
--List with the quotes so the code is more searchable as tags
local SGTagsToEntTags =
{
--【★ attack：正在攻击。combat 与 locomotor 都查这个】
    ["attack"] = true,
--【★ autopredict：自动预测相关（玩家输入相关）】
    ["autopredict"] = true,
--★★【busy：忙碌中 —— ★ 最常被查的标签】
--   ★ locomotor / brain 都会查它来决定「现在能不能被打扰/能不能移动」。
    ["busy"] = true,
--【dirt：在土里（如土怪埋土状态）】
    ["dirt"] = true,
--★【doing：正在执行某个动作 —— ★ 物品栏自动暂停的判定依据】
--   ★ 玩家打开物品栏时会暂停世界；「doing」状态的角色不应被暂停。
--   ★ 典型：砍树中（doing）→ 打开物品栏 → 树不应该停止被砍。
    ["doing"] = true,
--【fishing：钓鱼中】
    ["fishing"] = true,
--【flight：飞行中】
    ["flight"] = true,
--★【hiding：躲藏中（如躲草丛）】
    ["hiding"] = true,
--★【idle：空闲 —— ★ 「可被打扰」的判据】
--   ★ Brain 用它判断是否切换到警觉状态；locomotor 用它允许玩家指令。
    ["idle"] = true,
--【invisible：隐身中】
    ["invisible"] = true,
--【lure：诱饵状态（如被海象吸引的鱼饵）】
    ["lure"] = true,
--★【moving：移动中】
    ["moving"] = true,
--【nibble：啃咬中（兔子吃草）】
    ["nibble"] = true,
--★【noattack：禁止攻击 —— AI 与战斗系统的互斥标记】
--   ★★★ 用途：被眩晕/受击硬直时，AI 不该继续追打。
--     Brain 与 combat 都会查它来中止攻击序列。
--   ★ 这也是 H1「抢占重置」的痛点之一：
--     若 noattack 没有正确加上，怪物会在硬直中继续攻击。
    ["noattack"] = true,
--【nopredict：禁止客户端预测】
    ["nopredict"] = true,
--【pausepredict：暂停预测】
    ["pausepredict"] = true,
--【sleeping：睡眠中】
    ["sleeping"] = true,
--★【working：劳作中（采矿/伐木）】
    ["working"] = true,
--【boathopping：跳船动作中 —— 船移动的判定依据】
    ["boathopping"] = true,
--★★【★ 表里唯一的例外：shouldautopausecontrollerinventory 不在字母序末尾】
--   ★ 它本该按字母序排在最后，但被放在 boathopping 之后，
--     因为 522 行原本是最后一项，后来新增时直接追加了。
--   ★★ 这个 tag 的特殊语义（★ 注释原文是关键）：
--     即使角色处于 doing 状态，也**仍然**要自动暂停物品栏。
--   ★ 这正是 actions.lua / 背包 UI 的核心判定依据：
--     绝大多数 doing 状态会暂停世界，但这个标记状态例外。
--   ★ 例子：openslingshotmods 状态（装填弹枪）——
--     「doing」本该暂停世界，但装填时玩家必须能开背包换弹药。
--   ★★ 设计模式：白名单之外再加一层「例外」标记，
--     避免了为每个特例都去改主判定逻辑。
	["shouldautopausecontrollerinventory"] = true, --autopause even if "doing", see "openslingshotmods" state
}

--★★【HasState：状态图里是否存在这个状态 —— 「能力查询」而非「当前状态」】
--   ★★ 与 HasStateTag（616 行）区分：
--     · HasState(name)     → 这个**状态图定义里**有没有这个状态
--     · HasStateTag(tag)    → **当前**状态有没有这个标签
--   ★ 典型用途：mod 或通用逻辑想「如果这生物有这个状态就用特殊处理」，
--     需要先确认状态存在（不同生物的状态图不一样）。
--   ★★ 这是 313-318 行 mod 注入 State 的读取侧：
--     mod 注入的状态可用 HasState 检查是否成功注入。
function StateGraphInstance:HasState(statename)
--【★ 查的是定义表 self.sg.states，不是当前状态 —— 定义与运行时的又一次分离】
    return self.sg.states[statename] ~= nil
end

--★★★【★★★★ GoToState —— 本文件最重要、也最需要小心的一个函数】
--   ★★ 它是状态图唯一的转移入口。执行顺序共 12 步，顺序本身就是设计：
--     ① 530  查状态（不存在则 print + return，不崩）
--     ② 538  调旧状态的 onexit（★ 在清空 statemem **之前**，能读到旧数据）
--     ③ 550  清空 statemem（★★ H2 缺陷的根因）
--     ④ 551  保存 lasttags（供新状态 onenter 用）
--     ⑤ 552  重建 tags + 同步到实体标签（558-566）
--     ⑥ 568  客户端预测分支（server_states / no_predict_fastforward）
--     ⑦ 579  清 timeout
--     ⑧ 580  记录 laststate / 切换 currentstate / timeinstate 归零
--     ⑨ 584  重置 timelineindex（★ timeline 从头开始）
--     ⑩ 590  调新状态的 onenter（★ 在清空 statemem **之后**，只能读 params）
--     ⑪ 594  广播 newstate 事件
--     ⑫ 599  通知调度器唤醒自己
--   ★★★ 顺序中最重要的两条不变量：
--     · onexit 能读到即将被丢弃的 statemem（清理的最后窗口）
--     · onenter 只能靠 params 拿数据（statemem 已清空）
--     违反这个心智模型是本文件最常见的编程错误来源。
--   ★★ 三条调用路径（都汇入这里）：
--     · 状态文件的 onenter/onupdate/timeline 里显式调（最常见）
--     · EventHandler 里调（如 CommonHandlers.OnAttacked → GoToState("hit")）
--     · StartAction/PreviewAction 经 deststate 调（414/439 行）
--   ★★ 它**可以**重入（自身内部调它），这是设计允许的：
--     UpdateState 的 661/681 行专门检测了「新状态 != 进入时的状态」并提前退出。
function StateGraphInstance:GoToState(statename, params)
--★【★★ 按名字查状态 —— 整个状态图就是一张「状态名 → State」的哈希表】
--   ★ 名字是唯一标识（见 219 行），这是状态图可序列化、可动态构造的基础。
--   ★★ 性能：这是一次哈希查找，O(1)。
--     GoToState 在怪物密集场景下调用极频繁（每次受击/每次目标变化），
--     所以不能做成线性扫描。定义与查找的分离在这里体现了价值。
    local state = self.sg.states[statename]

--★★【★ 容错：状态不存在时打印并返回，而不是 assert 崩掉】
--   ★★ 这是刻意的「软失败」设计，原因有三：
--     ① mod 移除或改名状态后，实体仍可能在跑旧状态图
--     ② 存档里的状态名可能对不上当前版本的状态图
--     ③ 崩掉整个游戏对一个 mod 来说代价太大
--   ⚠ 代价：拼错状态名**不会**中断开发，只会在运行时打一行 print。
--     表现是「AI 莫名其妙不动」，日志里只有一行 TRIED TO GO TO INVALID STATE。
--   ⚠⚠ 排查陷阱：状态名是**字符串**，没有编译期检查。
--     536 行的 assert 被注释掉了（见那行注释），说明作者主动选择了软失败。
--     → 建议：在开发构建里打开 print，或自己加断言。
    if not state then
--★★【★ 错误日志格式：实体 + 状态名，连玩的人是谁都能看出来】
--   ★ 第一项是 self.inst，会被 __tostring 转成含 sg 名/状态名的长字符串（373 行），
--     所以这一行 print 的信息量其实很大。
		print (self.inst, "TRIED TO GO TO INVALID STATE", statename)
		return
    end
--★【★ 被注释掉的 assert —— 作者主动放弃「状态不存在就崩」】
--   保留它作为设计决策的证据：曾经想用硬失败，后来改成软失败 + 日志。
    --assert(state ~= nil, "State not found: " ..tostring(self.sg.name).."."..tostring(statename) )

--★★★【★★ onexit 的调用点 —— 本行是「清理的最后窗口」的关键】
--   ★★ 它在 550 行清空 statemem **之前**执行，所以：
--     ✓ 可以读到即将被丢弃的 statemem（做清理或交接）
--     ✗ 不可以读 params（params 是 onenter 的参数）
--   ★★ 第二参数是**下一个状态的名字**（539 行传 statename），
--     于是可以写「离开攻击状态时才播硬直」这类分支逻辑。
--   ⚠ 与 onenter 的对称性缺口：
--     onenter(inst, params) ← GoToState 的 params
--     onexit(inst, statename) ← 下一个状态名
--     ★ 两个钩子的第二参数**语义完全不同**，极易混淆。
--   ⚠ onexit 只在「有当前状态」时被调（538 行判空），
--     所以第一次进状态时不会有 onexit。
    if self.currentstate ~= nil and self.currentstate.onexit ~= nil then
--★【★ 传的是「下一个状态名」而非 params —— onexit 的第二参数语义】
--   ★ 用法示例：CommonStates 里的「离开 attack 时清除目标锁定」类逻辑。
        self.currentstate.onexit(self.inst, statename)
    end

--【★★「Record stats」段 —— 整套「状态耗时统计」机制被整体注释掉】
--   ★★ 543 行 KAJ 的 TODO 说明它被废弃的原因：
--     「what are we going to do with metrics?」—— 指标数据没有去处。
--   ★ 这暴露了一个重要事实：
--     **状态图本可以支持「每个状态累计耗时」的统计**，
--     用于 AI 调试与平衡性分析（哪个状态占比过高）。
--     保留注释是为了后人知道这个能力存在过。
--   ★ 若要复活：需要配套一个「把统计画出来」的界面，
--     否则数据只累积不消费，纯浪费内存。
    -- Record stats
--【★ 废弃指标机制的 TODO —— 「这些数据拿去干什么」是真正的阻塞点】
-- KAJ: TODO: commented out for now, what are we going to do with metrics?
--【被注释的统计代码：只对本地玩家统计，且要求「玩家在键盘前」】
--   ★ 三个限制条件说明它是为**本地调试**设计的，不是通用统计。
--    if METRICS_ENABLED and self.inst == ThePlayer and self.currentstate and not IsAwayFromKeyBoard() then
--【★ dt 用 GetTime() - statestarttime（含休眠的真实时长）】
--   ★ 与 UpdateState 用 timeinstate（活跃时长）不同，这里要的是真实时长。
--        local dt = GetTime() - self.statestarttime
--【★ clever 的写法：先判空再累加，因此不依赖 currentstate.time 是否预先存在】
--   注释原文点明：「works even if currentstate.time is nil」
--   ⚠ 但这里累加的是 State 对象上的字段 —— 而 State 是**所有实体共享**的！
--     ★★ 若复活这段统计，它会把所有同种实体的时间累加到同一处。
--     这是「定义/实例分离」原则的一个陷阱，注释里的 currentstate.totaltime
--     写法本身就是错的（应为 StateGraphInstance 上的字段）。
--   ⚠ 说明：这是被注释掉的死代码，不影响运行；但复活时必须修正。
--        self.currentstate.totaltime = self.currentstate.totaltime and (self.currentstate.totaltime + dt) or dt  -- works even if currentstate.time is nil
--        --print(self.currentstate.name," time in state= ", self.currentstate.totaltime)
--    end

--★★★★★【★★★ GoToState 的第 ③ 步 —— statemem 无条件清空，H2 缺陷的根因】
--   ★★★ 已核实：本项目 bug-patterns.md 的 H2 条目
--     「跨状态传递的数据丢失（statemem 在 GoToState 时被清空）」
--     根因即本行。逐字引用条目：
--       「每次 GoToState 都会清空 statemem。如果你的 timeline 事件在
--         20 帧后触发，而期间有任何其他 GoToState 调用（包括被打断、
--         被事件驱动的跳转），statemem 里的数据就没了。」
--   ★★ 原版为什么这样设计？——**故意的，且是正确的**：
--     statemem 的语义就是「本次状态进入的工作区」。
--     若不清空，每次进状态都要先清理上一状态的残留（防御性编程），
--     到处都要写清理代码，而且残留数据可能造成难查的串味 bug。
--     ★ 换句话说：清空是把「生命周期管理责任」从每个状态转移到了框架。
--   ★★ 正确用法（原版就是这么用的）：
--     数据在 onenter 写进 statemem，**只在同一个状态的 timeline 里消费**。
--     「写入者与读取者必须属于同一次状态进入」—— 这样清空不会造成影响。
--     ★ 例：SGwilson.lua:631 读 is_going_to_action_state 属于「本次进入的写入、
--       本次进入的读取」，但写入发生在 GoToState **之前**（438 行），
--       于是反而踩了坑 —— 详见 438 行的 ⚠ 分析。
--   ★★ 跨状态要传数据的两条正路：
--     ① GoToState(name, params) → 新状态 onenter(inst, params) 收到
--       ★ 这是最规范的通道，params 是专门为此设计的（591 行）
--     ② 写进 self.mem（343 行，跨状态保留）
--   ⚠ 再次强调：这是源码核实结论，非推断。
    self.statemem = {}
--★★★【★ lasttags：保存上一个状态的标签，供新状态 onenter 读取】
--   ★★★ 用途：「继承」上一个状态的某个标记。
--     典型：被打断（staggered）后进入攻击状态，希望攻击状态也带 staggered，
--       就靠 `inst.sg.lasttags["staggered"]` 读出来再 AddStateTag。
--   ★ 真实用例：
--     · stategraphs/SGbearger.lua:2235  `inst.sg.lasttags["staggered"]`
--     · stategraphs/SGbearger.lua:2242  同上（在 pst 里）
--     · stategraphs/SGbishop.lua:704/711    `lasttags["stunned"]`
--     · stategraphs/SGbuzzard.lua:1127/1134 `lasttags["stunned"]`
--     · prefabs/sharkboi.lua:85/89           `lasttags["digging"]`
--   ★★ ⚠⚠ 重要陷阱：lasttags 是**瞬态**的，596 行在 onenter 之后就清空了！
--     所以它**只在 onenter 里有效**。
--     · SGbearger/SGbishop 的用法在 CommonStates.AddElectrocuteStates 的
--       anims 表里（被 onenter 调用）→ 安全。
--     · ⚠ 但 sharkboi.lua:85 写的是 `inst.sg.lasttags and inst.sg.lasttags["digging"]`，
--       带了 nil 检查 —— 说明作者知道它可能为 nil。
--     · ⚠ 而 SGbearger.lua:2235 直接 `inst.sg.lasttags["staggered"]` 无检查，
--       若该代码路径在 onenter 之外被调用会崩。
--   ★★★ 这是本文件一个真实的、一致性不足的 API 设计：
--     lasttags 的有效窗口（onenter 期间）没有被任何机制强制或文档化，
--     导致同一种用法在不同文件里有的加判空有的不加。
--   ⚠ 推理依据：596 行 `self.lasttags = nil` 无条件执行，
--     而 onenter（591 行）在它之前，两者之间没有其他重入点。
--   ⚠ 若第一次进状态（lasttags 来自 334 行构造时的 self.tags）？
--     实际上 551 行会先 `self.lasttags = self.tags`，而 341 行构造时
--     tags = {}，所以第一次进状态时 lasttags 是空表（不是 nil），
--     读 lasttags["x"] 得 nil → 安全。真正为 nil 的只有 onenter 之后。
	self.lasttags = self.tags
--★★【★ tags 全量重建 —— 新状态的标签是「替换」不是「继承」】
--   ★ 语义：状态图标签是**当前状态的属性**，不跨状态保留。
--     需要继承的语义，用 lasttags 显式读出来再自己加（551 行）。
--   ⚠ 但运行期动态加的 tag（AddStateTag）也会被这里清掉 ——
--     这就是 341 行 ⚠ 说的「永久 tag 必须走实体标签」。
    self.tags = {}
--【★ State.tags 永远是表（225 行构造时初始化为 {}），判空是防御性写法】
    if state.tags ~= nil then
        for k, v in pairs(state.tags) do
--【★ 复制 State.tags 到实例 tags —— 定义（共享）→ 实例（私有）】
--   ★★ 浅拷贝单个表的内容，不是共享引用，所以
--     实例的 tags 与 State.tags 完全独立。
--     这就是「一个 State 被所有实体共享，但每个实体的标签互不干扰」。
            self.tags[k] = true
        end
    end
--★★★【★★ 实体标签同步的唯一入口 —— 只在服务端（或无网络的实体）执行】
--   ★★ 两个条件缺一不可：
--     · TheWorld.ismastersim —— 服务端才允许改实体标签
--     · self.inst.Network == nil —— 无网络实体（怪物）两端都算
--   ★★ 为什么客户端不能改？
--     实体标签参与网络同步（标签变化要发给客户端）。
--     客户端本地改标签会造成两端不一致（客户端以为自己 busy，
--     服务端不 busy → 交互表现错乱）。
--     ★ 例外：无网络实体（怪物）的标签根本不参与同步，
--       所以客户端本地改也无害。
--   ★★ 这是「服务器权威」原则在本文件的具体落点，
--     与 568 行的客户端预测分支是同一个思想的两个面。
--   ⚠ 但注意：客户端的 self.tags 仍会被 553-557 行更新（只是不同步到实体），
--     所以客户端的 HasStateTag 查询是本地准确的，只是实体标签不同步。
    if TheWorld.ismastersim or self.inst.Network == nil then
        for k, v in pairs(SGTagsToEntTags) do
--【★★ 遍历整张白名单表（约 20 项）逐个比对 —— 每次 GoToState 都做一次】
--   ★ 性能注意：这是每次状态切换的固定开销，约 20 次哈希查询。
--     状态切换在怪物密集场景下极频繁，但这个量级（几十 ns）仍可接受。
--   ★★ 遍历顺序由 pairs 决定 → **顺序不确定**。
--     但因为每个 key 的操作是独立的（AddTag/RemoveTag），顺序不影响结果。
--     ★ 这与 bug-patterns.md E4「pairs 顺序」是不同性质的问题：
--       那里是顺序影响结果，这里顺序不影响结果。
            if self.tags[k] then
--【★ 有这个 tag → 给实体打上】
                self.inst:AddTag(k)
            else
--★★【★ 没有这个 tag → **移除**实体上的标签】
--   ★★★ 这个「反向」操作是最容易被忽略的设计要点：
--     它不是「只加不减」，而是**全量同步**——
--     保证实体标签与状态图标签永远一致。
--   ★★ 举例说明必要性：
--     怪物在 attack 状态（实体有 busy 标签），
--     被打断进入 hit 状态（无 busy），
--     若只做「加」不做「删」，实体会**永远**带 busy 标签 →
--     locomotor 认为它一直很忙 → 它再也不响应任何移动指令。
--     ★★ 这类「标签永不消失」的 bug 极难排查，因为它看起来像 AI 逻辑坏了。
--   ⚠ 注意：AddTag/RemoveTag 是**实体级** API（不是状态图级），
--     所以任何系统直接 inst:AddTag("busy") 都会被下一次 GoToState 抹掉。
--     → 想设永久标签，只能用白名单外的名字，或每帧重设。
                self.inst:RemoveTag(k)
            end
        end
    end

--★★★【★ 客户端预测分支 —— 服务端与客户端在此分道扬镳】
--   ★★★ 两条互斥路径（服务端 / 客户端各走一条，见 232-243 行的对应构造）：
--     服务端：记录 no_predict_fastforward（能不能快进）
--     客户端：记录 server_states（哪些服务端状态算合法）
--   ★★ 为什么要这么写在一个 if/else 里？
--     因为「服务端状态」和「客户端预测状态」是两类互斥的状态，
--     服务端不需要知道客户端的预测白名单，反之亦然。
--   ★★ 收益：**省掉了每帧的端判断**。
--     GoToState 是热路径，若每帧判断 `if TheWorld.ismastersim` 会多一次分支；
--     更重要的是省掉了无用字段的写入。
--   ★ 代价：两端行为不同，调试时必须分端思考。
	--#V2C #client_prediction
--【★ ismastersim 判定：这是 DST 里判断「我是不是服务端」的标准写法】
--   ★ 全工程统一使用，见 entityscript.lua、network*.lua 等。
	if TheWorld.ismastersim then
--★★【★ 服务端路径：把状态的 no_predict_fastforward 拷到实例】
--   ⚠⚠ 疑似缺陷（与 442 行配对分析）：
--     这里拷到的是 **self.no_predict_fastforward**（实例字段），
--     而 442 行读的是 **self.statemem.no_predict_fastforward**。
--     ★ 两者不是同一个存储位置，且没有任何一行把它们连起来。
--     → 442 行的条件 `self.statemem.no_predict_fastforward` 恒为 nil，
--       「按状态禁止预测快进」的能力形同死代码。
--     → 修复方向：把 442 行改成读 `self.no_predict_fastforward`，
--       因为本行已经把值备好了。
--   ⚠ 推理依据：242 行存 State 字段、570 行拷到实例字段、
--     442 行读 statemem 字段 —— 三处两套命名空间，无交叉赋值。
--   ⚠ 本条为代码阅读推断，未在运行时验证。
		self.no_predict_fastforward = state.no_predict_fastforward
--【客户端路径开始】
	else
--★★★【★★ 客户端路径：计算本次状态切换后「哪些服务端状态算合法」】
--   ★★★ 这个表达式的语义（★ 展开讲）：
--       结果 = (上一状态要「转发」 且 上一状态有白名单) ? 上一状态白名单
--                                                          : 新状态白名单
--   ★ 「转发」（forward_server_states）的含义见 239 行：
--     客户端预测了一条路径（如 attackpre → attack），
--     服务端只会上报最终状态，客户端需要把整条路径都声明为合法。
--   ★★ 为什么用 and/or 链而不是 if？——热路径省分支。
--     ⚠ 但这正是 bug-patterns.md **D1 条目**的形态（and/or 三元），
--       在这里**恰好安全**，因为三个分支的值都是「表」或 false/nil，
--       不会被「假值表」坑到（Lua 里只有 false/nil 是假值，空表是真值）。
--       ★ 对比 D1 的经典坑：「返回 0 被当 falsy」——这里没有这种风险。
		self.server_states =
--【★ 第一重条件：必须有「上一个状态」—— 第一次进状态时为 nil，直接走 or 分支】
--   ★ 这是正确的：第一次进状态没有「转发路径」的概念。
			self.currentstate ~= nil and
--★【★ 第二重条件：上一状态要求转发白名单（见 239 行的完整说明）】
--   ★ 这个标志由状态作者在 State 定义里给出，属于**显式声明**。
			self.currentstate.forward_server_states and
--【★ 第三重条件：上一状态确实有白名单表】
--   ★ 与 574 连起来读：只有「要求转发」且「有东西可转发」才转发。
			self.currentstate.server_states or
--★【★ or 分支：否则用新状态自己的白名单 —— ★ 这就是正常的客户端预测路径】
--   ★★ 举例：`State{name="attack", server_states={"attack", "attackpre"}}`
--     进入 attack 时，服务端报 attack 或 attackpre 都算客户端预测正确。
--   ★ 服务端校验点：ServerStateMatches（749 行）。
			state.server_states
	end

--★★【★ 清 timeout —— 换状态即作废旧的定时器】
--   ★★★ 为什么必须清？——因为 timeout 是**实例级**的，
--     而 ontimeout 是 State 上的钩子。
--     若不换状态就换了状态，A 状态设的 3 秒定时器会在 B 状态里触发，
--     调用 B 的 ontimeout —— 语义完全错乱。
--   ★ 这与 statemem 清空（550 行）是同一类问题：
--     **所有「绑定到当前状态」的实例级数据都必须在换状态时重置。**
--     本文件的重置清单：statemem(550) / tags(552) / timeout(579) /
--                    timelineindex(584) / timeinstate(582)。
    self.timeout = nil
--【★ laststate = currentstate —— 给 InNewState（496 行）提供比较基准】
--   ★★★ 这行与 581 行是一对，必须连续看：
--     先存旧，再换新。顺序反了 InNewState 就永远为假。
    self.laststate = self.currentstate
--★★★【★ currentstate = state —— 唯一的「当前状态」真相来源】
--   ★ 全文件所有 currentstate 的读写都以此为准。
--   ★ 由 StateGraph 定义持有 → 见 274 行「定义/实例分离」的核心论述。
    self.currentstate = state
--★★【★ timeinstate 归零 —— timeline 的进度基准重置】
--   ★★ 注意 statestarttime 要到 598 行才更新，
--     所以在 onenter（591 行）执行期间，GetTimeInState() 仍返回**旧值**。
--   ⚠ 这是一个隐蔽的时序细节：
--     在 onenter 里调 GetTimeInState() 得到的是「上一个状态停留了多久」，
--     不是 0。若要拿本状态的停留时间，onenter 里应该用 0。
    self.timeinstate = 0

--★★★【★ timelineindex 重置为 1 —— 时间线从头开始播放】
--   ★★★ 这里是 timeline 进度的**唯一重置点**。
--   ★ 两个分支的语义（★ 别搞混）：
--     · timeline 非空 → index = 1，状态图会开始按时间推进
--     · timeline 为空（nil）→ index = nil，668 行的 while 整段跳过
--   ★ 为什么要判空而不是无条件设 1？
--     因为 337 行的 while 用 `self.timelineindex and` 做短路，
--     设成 nil 比「index=1 但 timeline 是空表」更快短路。
--     ★ 性能考虑：没有 timeline 的状态（F 大多数静态状态）
--       每帧的 while 判断变成一次常量 false。
    if self.currentstate.timeline ~= nil then
        self.timelineindex = 1
    else
--【★ 无 timeline → 游标置 nil，进入 668 行的零开销短路路径】
        self.timelineindex = nil
    end

--★★★【★★ onenter 的调用点 —— 状态切换的最后一环】
--   ★★ 参数 (inst, params)：params 就是 GoToState 第二实参的原样透传。
--     ★★ 这是**跨状态传数据的正规通道**：
--       GoToState("chase", {target = t}) → onenter(inst, {target = t})
--       因为 statemem 已被清空（550 行），params 是唯一能带数据过来的方式。
--   ★★★ 与 onexit（538 行）的三点不对称，必须记住：
--     ① 数据来源：onenter 拿 params，onexit 拿下一个状态名
--     ② statemem：onenter 执行时 statemem 已清空；onexit 执行时尚未清空
--     ③ 首次进入：onexit 不会调（无旧状态），onenter 会调
--   ⚠ onenter 里再调 GoToState 是**合法且常见**的（状态跳转链），
--     但会让 580-582 行的赋值被覆盖，
--     所以 laststate 会是「被跳过的那个状态」。
--     ★ UpdateState 的 661/681 行就是为此做了检测。
    if self.currentstate.onenter ~= nil then
--★【★ onenter(inst, params) —— ★ 唯一能拿到 params 的地方】
--   ★ 典型：CommonStates 的战斗状态在 onenter 里读 ba（bufferedaction）
--     来决定是被谁攻击的。
        self.currentstate.onenter(self.inst, params)
    end

--★★★【★ 广播 newstate 事件 —— 状态切换的对外通知机制】
--   ★★★ 这是「其他系统感知状态变化」的标准途径：
--       inst:ListenForEvent("newstate", function(inst, data) ... end)
--       data.statename 是新状态名。
--   ★ 典型用途：
--     · locomotor 监听它来重置移动计时器
--     · 组件监听它来重新计算加成
--     · 成就系统监听它来统计行为
--   ★★ 为什么在 onenter **之后**发？
--     保证监听者看到的是一个「已完全就绪」的状态。
--     若在 onenter 之前发，监听者可能读到半初始化的状态。
--   ★★ 注意这是 PushEvent（非 immediate），所以监听者收到事件时
--     本帧的 Update 已经跑完 —— 又是一次刻末批处理。
--   ⚠ 副作用：状态图自己若监听 newstate，事件会进 339 行的缓冲队列，
--     在刻末由 HandleEvents 派发（而状态私有事件优先，见 463 行）。
    self.inst:PushEvent("newstate", {statename = statename})

--★★★【★ lasttags 清空 —— 再次强调：它只在 onenter 期间有效】
--   ★★★ 这是本文件一个**未被文档化、一致性不足**的 API：
--     · SGbearger.lua:2235 / SGbishop.lua:704 直接 `lasttags["x"]` 无判空
--     · sharkboi.lua:85 写 `lasttags and lasttags["x"]` 有判空
--   ⚠ 推理依据：本行无条件置 nil，而 551 行的赋值在每次 GoToState 开头，
--     所以从 591 行 onenter 返回之后 lasttags 一定是 nil。
--     若某段代码在 onenter 之外读 lasttags → 索引 nil → 崩溃。
--   ⚠ 正确写法应是 551 行保留、或提供 `HasLastStateTag` 之类的访问器。
--     现状是「每个调用点自己判断」，容易漏。
--   ★ 保留本行的原因：不让 lasttags 一直持有上一状态的 tag 表，
--     减少内存驻留 + 避免误以为它一直有效。
	self.lasttags = nil
--【★★ lastupdatetime = GetTime() —— 下一次 Update 的 dt 基准】
--   ★★★ 这一行同时解决了「首次进状态的 dt 爆炸」问题：
--     若不设，718 行会算出「从上次更新到现在的全部时间」作为 dt，
--     一次性推进整个 timeline —— 表现为「刚进状态动画就跳到结尾」。
--   ★ 参见 336 行的初始值 0 与那里的 ⚠ 说明。
    self.lastupdatetime = GetTime()
--【★ statestarttime = lastupdatetime —— 两个时间戳同源，语义不同】
--   ★ statestarttime 是「进入状态的那一刻」，供 GetTimeInState 用；
--     lastupdatetime 是「上次 Update 的时刻」，供算 dt 用。
--     ★ 换状态时它们相等；之后各自独立演化（状态图休眠时
--       lastupdatetime 不更新而 statestarttime 更早，dt 会变大）。
    self.statestarttime = self.lastupdatetime
--★★★【★ 最后一步：通知调度器「我进新状态了，叫醒我」】
--   ★★ 对应 27 行的 OnEnterNewState。
--   ★★ 为什么必须在 GoToState 的**最后**？
--     因为此刻 currentstate/tags/statemem 才全部就绪，
--     此刻被唤醒执行 Update 才安全。
--   ★★ 更关键的理由（★ 框架级洞察）：
--     如果 GoToState 在 Update 循环**中途**被调用，
--     此刻的实例可能正躺在 tickwaiters 的桶里（已从 updaters 移走）。
--     这一句把它捞回 updaters，保证本帧后续或下帧一定会被更新。
--     ★ 参见 109 行 Update 的双缓冲换表法：
--       捞回的是**新表**，所以最早也要下一帧才生效。
--   ⚠ 若实例已被 Stop（limbo），28 行的守卫会阻止重新注册 ——
--     但 onenter 已经执行过了（见 27 行的 ⚠ 说明）。
    SGManager:OnEnterNewState(self)
end

--★★【AddStateTag：运行期给当前状态动态加标签 —— 跨状态图的通用开关】
--   ★★★ 为什么需要动态加？——因为「打断时临时禁用某能力」是通用需求：
--     components/mightygym.lua:457  `player.sg:AddStateTag("nointerrupt")`
--       → 注释："Make the player treat this like a dismounting action."
--       （把玩家当「正在下坐骑」处理，动作不可被打断）
--     prefabs/player_common_extensions.lua:587  `AddStateTag("busy")`
--     actions.lua:1551  `AddStateTag("idle") -- allow talker state to take over`
--       → ★ 加 idle 让 talker 状态能接管（典型「临时让出控制权」）
--   ★★ 与状态定义里 tags 的区别：
--     · State.tags    → 每次进这个状态都会重新施加（持久于该状态）
--     · AddStateTag  → 只对**当前这一次进入**有效（下次 GoToState 被 552 清掉）
--   ★ 这个差异正是它的价值：「临时补丁」而非「修改状态定义」。
function StateGraphInstance:AddStateTag(tag)
--【★ 写的是 self.tags（实例级），不是 State.tags（共享定义）】
--   ★★ 若写 State.tags 会污染**所有**使用该状态的实体 —— 绝不能这么写。
--     502 行 SGTagsToEntTags 的注释里也强调过「所有状态共享」。
    self.tags[tag] = true
--★★【★ 同步到实体标签 —— 与 GoToState 的 558-566 行同一套白名单机制】
--   ★★ 这是本函数最容易漏掉的一半：
--     只加 self.tags 不加实体标签，外部系统（locomotor/combat）根本看不到。
--   ★ 条件与 558 行完全一致（服务端 或 无网络实体），
--     客户端不加标签是为了防止同步不一致（见 558 行的详细分析）。
    if SGTagsToEntTags[tag] and (TheWorld.ismastersim or self.inst.Network == nil) then
        self.inst:AddTag(tag)
    end
end

--★★【RemoveStateTag：动态移除标签 —— 与 AddStateTag 完全对称】
--   ★★ 使用场景：actions.lua:1551 的反向用法，
--     「临时让出 idle 权限，谈完话再拿回来」。
--   ★★ 注意与 GoToState 的 563 行区分：
--     · 563 行是「全量同步」：遍历白名单，把没的标签都删掉
--     · 本行是「精准移除」：只删指定的某一个标签
--   前者管一致性，后者管临时性。
function StateGraphInstance:RemoveStateTag(tag)
    self.tags[tag] = nil
    if SGTagsToEntTags[tag] and (TheWorld.ismastersim or self.inst.Network == nil) then
        self.inst:RemoveTag(tag)
    end
end

--★★【HasStateTag：查当前状态的标签 —— 外部系统问状态图的第一入口】
--   ★★★ 这是「状态图对外接口」里最高频的一个：
--     · brain 检查 "idle" 决定是否进入警觉
--     · locomotor 检查 "busy" 决定能否移动
--     · combat 检查 "noattack" 决定能否攻击
--   ★★ 查的是 self.tags（实例级），包含了运行时动态添加的，
--     所以它反映的是「当前真实状态」，比 State.tags 更准。
--   ⚠ 但注意：若在客户端，self.tags 会被更新（553-557），
--     只是不与实体标签同步（558 行）——
--     所以 HasStateTag 在两端都准确，但 HasTag("busy") 只在服务端准确。
function StateGraphInstance:HasStateTag(tag)
	return self.tags[tag] == true
end

--★★【HasAnyStateTag：变参形式的批量查询 —— 「满足其中任一」】
--   ★★ 为什么需要它？——因为「例外情况」多：
--     「除了 idle 和 sleeping，其他状态都要能被打扰」
--   ★ 与 HasStateTag 的分工：
--     · 一个标签 → HasStateTag("busy")（O(1) 直接哈希）
--     · 一组标签 → HasAnyStateTag("busy", "doing") 或 HasAnyStateTag({...})
--   ★ 两种调用形态（表格 / 变参）都要支持，
--     因为调用点的书写习惯不统一，且 Lua 没有函数重载。
function StateGraphInstance:HasAnyStateTag(...)
--【★ select(1, ...) 取第一个参数 —— 兼容「表格 或 单值」两种形态的技巧】
--   ★ Lua 的 select(n, ...) 中 n 为负数时取倒数，1 就是第一个。
	local tags = select(1, ...)
--【★ 表格分支：传进来的就是一张标签数组（典型是字面量 {"a","b"}）】
--   ★ 用 ipairs 遍历数组。
	if type(tags) == "table" then
--【★ 找到任一即返回 true（短路）—— 命中即停，不遍历剩余的】
		for i, v in ipairs(tags) do
--【★ 整个数组都没命中才走到这里】
			if self.tags[v] then
				return true
			end
		end
--★★【★ 非表格分支：单个标签值的快速路径】
--   ★★ 这个分支其实是「变参调用」的规范化：
--     · 单值调用 → 走这里，O(1) 一次哈希查
--     · 多值调用 → 第一个参数是字符串也走这里，然后 632 行循环剩下的
--   ★ 也就是说 **table 分支只在使用者显式传了表时触发**。
--     传 {"busy"} 与传 "busy" 走不同路径但结果相同。
	else
		if self.tags[tags] then
			return true
		end
--【★ 遍历剩余的变参（第 2 个到第 n 个）】
--   ★ select("#", ...) 返回**参数总数**，不是「最后一个参数」，
--     这是 select 最常被误解的地方。
--   ★★ 性能：变参调用会创建栈上的参数列表，
--     远高于直接传表的效率。热路径上应优先传表。
		for i = 2, select("#", ...) do
			if self.tags[select(i, ...)] then
				return true
			end
		end
	end
--【★ 都没命中 → 返回 false。调用方据此判断「可以打断/可以移动」】
    return false
end

--★★★【SetTimeout：设定「本状态最多停留多久」—— ontimeout 的触发源】
--   ★★★ 参数单位是**秒**。置 nil 表示取消定时。
--   ★★ 典型用法：「攻击状态最多持续 3 秒，3 秒后自动回到待机」
--     onenter:  inst.sg:SetTimeout(3)
--     ontimeout: inst.sg:GoToState("idle")
--   ★★ 与 timeline 的分工（★ 本文件的核心性能原则）：
--     · timeline  → 状态内部的各个「时刻」（帧级精度）
--     · SetTimeout → 状态的「兜底退出」（秒级精度）
--   ★★ 关键收益（这是 F3 性能原则的实践）：
--     用了 SetTimeout 后，状态图可以**在 timeout 到期前整段休眠**，
--     因为 Update 会在 733 行算出「还剩多久到 timeout」并睡到那一刻。
--     若改用 onupdate 里的时间比较，就得每帧更新（F3 性能杀手）。
--   ★★ 顺序很重要：先 OnSetTimeout 唤醒（642 行）再设 timeout（643 行），
--     否则可能设完之后立刻休眠，永远等不到 ontimeout。见 33 行说明。
function StateGraphInstance:SetTimeout(time)
--【★★ 先唤醒（642）再设值（643）—— 顺序不能反，否则会睡死】
--   ★ 推演错误顺序的后果：设 timeout → 此时实例在 hibernaters →
--     永远不会被 Update → timeout 永不到期 → 状态永久卡住。
--   ★ 这也是本文件「先唤醒后操作」统一风格的又一个例证
--     （对比 599 行 GoToState 末尾才唤醒，因为那里是全部就绪后才需要）。
    SGManager:OnSetTimeout(self)
    self.timeout = time
end

--★★★【★★ UpdateState：单个状态图实例的每帧推进 —— 时间线的执行引擎】
--   ★★ 它做三件事，顺序固定：
--     ① 累加 timeinstate
--     ② 处理 timeout 到期（调用 ontimeout）
--     ③ 处理 timeline（逐个触发到点的 TimeEvent）
--   ★ 三步都要检测「状态是否在过程中被换掉了」，
--     因为 ontimeout / TimeEvent 内部完全可以调 GoToState。
--     ★★ 这就是本函数全部复杂度的来源：**状态切换的重入处理。**
function StateGraphInstance:UpdateState(dt)
--【★ 防御：没有当前状态就什么都不做。Update 的调用前提是实例已注册】
--   ★ 这是为了容忍 334 行 currentstate 初始为 nil 的窗口。
--   ⚠ 但 728 行的 Update 没有同样的判空，见那里的 ⚠ 说明。
    if not self.currentstate then
        return
    end

--【★★ 累加 timeinstate —— timeline 的唯一进度来源】
--   ★★ 关键：这是**活跃时长**，休眠期间本函数不被调用，所以不增长。
--     所以时间线在休眠时是「暂停」的。
--   ★ 与 statestarttime / GetTimeInState 的区别见 383 行说明。
--   ⚠ dt 可能异常大（长时间休眠后的第一帧），见 718-722 行的说明。
    self.timeinstate = self.timeinstate + dt
--★★★【★ startstate：记住「进入本函数时的状态」—— 重入检测的基准】
--   ★★★ 这是本函数的核心技巧：
--     在处理 timeout/timeline 之前拍一张快照，
--     之后凡是调用了可能换状态的钩子，都跟这张快照比对。
--     若不同 → 说明发生了状态切换 → **立刻收工**，
--     因为剩下的时间线属于旧状态，继续跑就是错的。
--   ★ 两处检测：661 行（ontimeout 后）、681 行（timeline 内）。
--   ★★ 替代方案（更笨但更直观）：每次调用钩子后重新检查 self.currentstate，
--     但那样无法区分「切走又切回同一状态」，
--     而 652 行的快照法能正确处理「A → B → A」的情况（仍然收工，保守但安全）。
    local startstate = self.currentstate


--【★ 只在设了 timeout 时才处理（579 行保证换状态时会清空）】
    if self.timeout then
--【★★ 倒计时递减 —— 这是 timeout 的唯一实现，非常简单】
--   ★ 时间线不是「绝对时间触发」而是「每帧递减后比较」，
--     好处是天然与 Update 频率对齐，无需处理跨帧补触发。
        self.timeout = self.timeout - dt
--★【★ 浮点误差容差：0.0001 秒（0.1 毫秒）】
--   ★★★ 为什么需要 epsilon？
--     浮点减法会累积误差：`3.0 - 0.1 - 0.1 - ... ` 可能得到 -1e-16 而不是 0。
--     若严格用 `timeout < 0`，可能永远触发不了（或晚一帧）。
--   ★ epsilon 的选择：0.0001 秒远小于一帧（0.033 秒），
--     所以不会造成「提前触发」的可感知误差。
--   ★ 这与 bug-patterns.md D3「需要迟滞双带」的思路一致：
--     浮点/临界判定处必须留容差，否则会随机抖动。
        if self.timeout < 0.0001 then --epsilon for floating point error
--【★ 触发后立刻清 timeout —— 防止 ontimeout 里没换状态时被反复触发】
--   ★★ 这一点很重要：ontimeout 未必会换状态
--     （也可能只是发个事件、或做一次检查）。
--     不清的话下一帧 timeout 还是负数，会**每帧触发**。
            self.timeout = nil
--【★ 有 ontimeout 钩子才调 —— 没设钩子的状态设了 timeout 也白设】
            if self.currentstate.ontimeout then
--★【★ ontimeout(inst) —— 只传实体，不传别的（对比 onenter 有 params）】
--   ★ ontimeout 的签名刻意精简：它是「时间到了」的通知，
--     不需要额外上下文。
                self.currentstate.ontimeout(self.inst)
--★★★【★★ 重入检测 ①：ontimeout 导致了状态切换 → 立刻收工】
--   ★★★ 为什么必须收工？
--     因为 668 行的 while 循环用的是 **self.currentstate.timeline** ——
--     状态已经换了，接下来的 timeline 是**新状态**的，
--     而 timeinstate 还没归零（582 行在新状态里才归零）。
--     继续跑会用「新状态的 timeline + 旧状态的 timeinstate」，
--     结果是随机触发新状态的时间点。
--   ★ 这是本文件最典型的「时序陷阱」，也是难查 bug 的高发点。
--   ⚠ 若 ontimeout 没换状态（startstate == currentstate），继续执行，
--     这是正常路径。
                if startstate ~= self.currentstate then
                    return
                end
            end
        end
    end

--★★★【★★★ timeline 的执行 while 循环 —— 本文件最精巧的一段】
--   ★★ 循环条件四重短路：
--     ① self.timelineindex          —— 有游标（无 timeline 或已播完 → nil）
--     ② currentstate.timeline[idx] —— 游标位置真的有节点
--     ③ .time <= self.timeinstate  —— 且已到点
--   ★★★ 为什么是 while 而不是 if？
--     因为一帧可能跨过**多个**时间线节点（掉帧、dt 很大、
--     或 FastForward 快进后追赶），必须把欠下的节点全部补上。
--     ★ 这就是 755 行 FastForward 能生效的前提：
--       快进制造出大 dt，while 循环一次性追上调过的所有节点。
--   ★★ 若写成 if，FastForward 只会触发一个节点，动画与逻辑就脱节了。
--   ★ 排序前提（261 行 table.sort）在这里生效：
--     因为是 while 顺序推进，若 timeline 未排序会乱序触发。
    while self.timelineindex and self.currentstate.timeline[self.timelineindex] and self.currentstate.timeline[self.timelineindex].time <= self.timeinstate do

--【★ 先取当前游标位置 —— 后面要用它算「欠了多久」（677 行）】
		local idx = self.timelineindex
--★【★ 游标前移 —— 必须在调用 fn 之前前移，防止 fn 内部递归触发同一节点】
--   ★★★ 先推进再调用是关键的防御：
--     若 TimeEvent 的 fn 内部间接导致本函数被重入，
--     已推进的游标能保证同一节点不会重复触发。
        self.timelineindex = self.timelineindex + 1
--★★【★ 播完检测 —— 置 nil 让 668 行的 while 下次直接短路】
--   ★ 这是「性能友好型终止」：不仅不重复检查，
--     连 737-742 行的休眠决策都因为 timelineindex 为 nil 而更简单。
--   ★ 与 587 行（无 timeline 时的初始 nil）是同一个「nil 即结束」的约定。
        if self.timelineindex > #self.currentstate.timeline then
            self.timelineindex = nil
--【★ 时间线播完 → timelineindex = nil。★ 三个 nil 的含义见 337 行】
        end

--【★ old_time：记录调用 fn **之前**的时间，用于 681 行的检测】
        local old_time = self.timeinstate
--★★★【★ extra_time = 当前时间 - 本节点应触发时间 = 本节点「迟到了」多少】
--   ★★★ 这是补偿掉帧的机制：
--     假设 timeline 里 3 帧和 11 帧各有一个节点（伤害在 11 帧），
--     某帧卡顿，timeinstate 一次跳过了两帧。
--     伤害节点的 extra_time > 0，说明「按真实时间它其实早该触发了」。
--   ★ 用途（682 行）：把欠下的时间补喂给新状态的 Update，
--     否则新状态的时间线会整体延后（看起来「攻击慢了半拍」）。
--   ★★ 这是本文件处理「掉帧」的核心技巧，值得单独记住。
        local extra_time = self.timeinstate - self.currentstate.timeline[idx].time
--★【★ 真正执行时间线节点：fn(inst) —— ★ 不传 dt、不传任何上下文】
--   ★★★ 这就是「时间线」的纯粹性：节点只知道「到点了，该做这件事」。
--   ⚠ 危险之处：fn 里可以调 GoToState（时间线经常这么干，
--     例如「攻击 11 帧处打出伤害后进入后摇状态」），
--     而 681 行就是为此准备的检测。
--   ★★ 另一个危险：fn 里可以 Remove 实体。
--     此时 self.inst 已失效，但 681 行只检查了状态切换，
--     后续 687 行的 onupdate 会访问失效实体。
--     ⚠ 这是一个未被覆盖的边界（推理：681 行的两个条件都不覆盖实体销毁）。
--     实践中时间线里的 Remove 通常会同时切状态（进 corpse 状态），
--     所以被 681 行的第一个条件捕获了。
        self.currentstate.timeline[idx].fn(self.inst)


--★★★【★★ 重入检测 ② —— 本函数最关键的一行】
--   ★★★ 两个条件，语义完全不同：
--     ① startstate ~= self.currentstate
--       → 状态被换掉了（TimeEvent 里调了 GoToState）
--       → 收工：剩下的 timeline 属于旧状态，无意义
--     ② old_time > self.timeinstate
--       → ★★ timeinstate **被重置变小了**！
--       → 这只可能是 GoToState 造成的（582 行归零），
--         说明换成了**同一个状态**（startstate === currentstate）。
--       → 收工的原因不同：时间线已经从头开始了，
--         不能用旧的 timeinstate 继续推进。
--   ★★ 条件 ② 是条件 ① 的补充，覆盖「A → A」这个 652 行提到的情况。
--   ★ 之后立刻 return 0（683 行）—— 返回 0 的含义见 128 行：
--     「下一帧继续更新我」。因为刚换状态，必须立刻再跑一次。
--   ⚠ 极端情况：若某时间线节点反复触发「A → A」，
--     会形成「每次 Update 都换一次状态」的死循环（每帧重置时间线）。
--     ⚠ 本条为代码阅读推断，未在运行时验证。
        if startstate ~= self.currentstate or old_time > self.timeinstate then
--★★【★ 把「迟到的 extra_time」补喂给新状态 —— 掉帧补偿的落点】
--   ★★ 注意调用的是 **self:Update（718 行）而非 self:UpdateState（646 行）**：
--     Update 是完整的一拍（算 dt + 推进 + 决定休眠），
--     UpdateState 只是内部推进引擎。
--     ★ 这里要的是「新状态推进一次」的效果，所以用 Update。
--   ★★ 更微妙的一点：Update 里会重新算 dt = GetTime() - lastupdatetime，
--     也就是说 extra_time 这个参数**根本没被用上**！
--     ⚠ 推理依据：718 行 `function StateGraphInstance:Update()` 不接收参数，
--       682 行传的 extra_time 被丢弃。
--     实际效果：新状态会在「当前真实时刻」再推进一步，
--       而不是「欠下的 extra_time 之后」。
--     ⚠ 这是一个**疑似缺陷（中等）**：掉帧补偿的意图没有达成，
--       实际只是多跑了一次 Update。
--       预期写法应是 self:UpdateState(extra_time)。
--     ⚠ 本条为代码阅读推断，未在运行时验证。
            self:Update(extra_time)
--【★★ return 0：告诉调度器「下一帧还要更新我」（见 128 行三态协议）】
--   ★ 为什么不是 return nil（休眠）？
--     因为刚发生了状态切换，必须立刻验证新状态能否正常推进。
--     ★ 若这一步返回 nil 休眠了，新状态可能永远不更新 → 卡死。
            return 0
        end
    end

--★★【onupdate：每帧钩子 —— ★★ 性能敏感区，见 bug-patterns.md F3】
--   ★★ 铁律：能不用就不用。写了它，737 行就会让整个状态图每帧更新。
--   ★ 正确做法：把「持续判断」拆成 onenter（起点）+
--     timeline（各时刻）+ ontimeout（终点）+ onexit（清理）。
--   ★ 参数 (inst, dt)：dt 是本帧的真实时长，可用于帧率无关的运动积分。
--   ⚠ 与 onenter 不同，onupdate 在休眠状态下**不会**被调用
--     （因为整个 Update 都不跑）。
    if self.currentstate.onupdate ~= nil then
        self.currentstate.onupdate(self.inst, dt)
--【UpdateState 结束 —— 返回值由外层 Update（718 行）决定，不在这里】
    end
end

--★★★【★ Start：从 limbo 恢复 —— 由 EntityScript:ReturnToScene 调用】
--   ★★ 注释（--@V2C）说明了精确的调用契约：
--     「should only be called from EntityScript:ReturnToScene (legacy behaviour)」
--     「this means OnStart is only triggered when exiting limbo」
--   ★★ limbo 机制：实体「离开世界」（存档加载中、被其他世界替换）时
--     被移出场景（RemoveFromScene → Stop），回来时再 Start。
--     limbo 期间实体保留在内存里但不更新、不显示。
--   ★ 为什么状态图要在 limbo 时停？
--     因为 limbo 实体不该消耗 CPU（参见 27 行的守卫说明）。
--     ★★ 这是性能优化的重要一环：存档切换/世界切换时
--       几百个实体的状态图全部停止更新。
--@V2C: should only be called from EntityScript:ReturnToScene (legacy behaviour)
--      this means OnStart is only triggered when exiting limbo
function StateGraphInstance:Start(hibernate)
--★★【★ 守卫：只有处于 stopped 状态才允许 Start】
--   ★★ 为什么要这个守卫？—— 防重复启动。
--     若实体重复调用 ReturnToScene，Start 会被调多次，
--     701 行的 AddInstance 会重复注册（虽然集合语义会去重），
--     但 OnStart 钩子会被调多次 → 副作用叠加。
--   ★ 注意守卫条件是 `not self.stopped`：
--     构造函数（332 行）**没有**初始化 stopped 字段，所以首次是 nil，
--     `not nil` 为真 → return。
--     ★★★ 即「构造函数后 sg 已经在跑（由 AddInstance 注册）」，
--       stopped 只是 Stop 时打的标记。
--     对比 brain.lua:167 `self.stopped = true` —— 那边初始就是 true。
--     ⚠ 两处初始值不同是刻意的：状态图注册与 Brain 注册的时机不同
--       （见 334 行的初始化契约说明）。
	if not self.stopped then
		return
--【★ OnStart 钩子：可选的子类扩展点，在正式注册之前调用】
--   ★ 顺序：OnStart → 清 stopped 标记 → AddInstance（注册）。
--   ★ 所以 OnStart 里可以访问 self.sg / self.inst，且状态图即将恢复。
	elseif self.OnStart then
        self:OnStart()
    end
	self.stopped = nil
--★★【★ AddInstance 重新注册 —— hibernate 参数由调用方（ReturnToScene 链路）传入】
--   ★ 与 Stop 的 RemoveInstance（715 行）严格配对。
--   ★★ 配对的完整性是内存安全的关键：
--     漏 Stop → 实体已消失但状态图还在调度表里（每帧被遍历，
--       靠 123 行的 k.stopped 兜住不崩，但纯浪费 CPU）；
--     漏 Start → 实体回来了但状态图不更新（完全静默的失效）。
	SGManager:AddInstance(self, hibernate)
end

--★★★【★ Stop：进入 limbo —— 与 Start 严格配对】
--   ★★ 注释同样标注了契约：只能由 EntityScript:RemoveFromScene 调用。
--   ★★ 停止流程比启动多一步（710 行 HandleEvents），值得单独讲，见下。
--@V2C: should only be called from EntityScript:RemoveFromScene (legacy behaviour)
--      this means OnStop is only triggered when entering limbo
function StateGraphInstance:Stop()
--【★ 守卫：已经在 stopped 就不重复停（与 695 行对称）】
	if self.stopped then
		return
	end
--★★★【★ Stop 里**先处理完缓冲事件**，再注销 —— 这个顺序很讲究】
--   ★★ 为什么？——「不把已发生的事丢掉」：
--     若实体在进 limbo 前刚 PushEvent 了什么（比如「死亡」），
--     直接注销会丢掉这个事件，导致状态图停在死亡前的样子。
--   ★★ 但注意：HandleEvents 里若处理器又调了 GoToState，
--     GoToState 末尾会调 OnEnterNewState（599 行）——
--     而 714 行的 stopped 还没设，27 行的守卫会通过 → 重新注册！
--   ⚠ 推理依据：710 行 HandleEvents → 处理器 GoToState →
--     599 行 OnEnterNewState → 28 行 `if self.instances[inst]` →
--     此时实例还没被 RemoveInstance，instances 仍有它 → 重新 SendToList 到 updaters。
--     然后 715 行 RemoveInstance 才把它清掉。
--     ★ 结论：结果正确（最终是注销状态），但过程有「注册了又被移除」的浪费。
--     属于「能工作但不优雅」，不构成缺陷。
    self:HandleEvents()
--【★ OnStop 钩子：在注销前调用，此时状态图仍可用】
    if self.OnStop then
        self:OnStop()
    end
--【★ 打上 stopped 标记 —— 123 行的 k.stopped 检查就是读它】
--   ★★ 与 696/697 行的 Start 配对：Start 读它决定能否启动。
--   ★ 注意它在 HandleEvents **之后**设，正是为了让 710 行
--     处理事件期间状态图仍被视为「运行中」。
    self.stopped = true
--★【★★ RemoveInstance：注销 —— 与 Start 的 AddInstance（701 行）配对】
--   ★ RemoveInstance 内部会调 92 行 ClearBufferedEvents，
--     丢弃剩余事件（因为实体要进 limbo 了，剩下的多半也没意义）。
    SGManager:RemoveInstance(self)
end

--★★★【★★★★ Update：决定「本拍之后还要不要继续更新」—— 全文件性能的枢纽】
--   ★★★★ 它是 SGManager:Update（128 行）调用的目标，
--     其返回值直接决定实例的生死（Sleep / 留在表里 / Hibernate）。
--   ★★★ 五个步骤：
--     ① 算 dt（719-723）
--     ② 推进状态机（725 → UpdateState）
--     ③ 算出「距下一个关键点还有多久」（727-735）
--     ④ 按 onupdate 的有无决定优先级（737-739）
--     ⑤ 返回给调度器（740-743）
--   ★★ 步骤 ③ 是本函数的精髓：**把「下一次该醒来的时刻」计算出来**，
--     于是状态图可以整段安睡，不必每帧空转去检查时间。
--   ★★ 这就是 F3 性能原则「能写成时间点的一律不要写成 onupdate」
--     在框架层的落地实现。
function StateGraphInstance:Update()
--【★ dt 初值 0 —— 保证 first run 时不会算出一个巨大的 dt】
    local dt = 0
--【★ 判 lastupdatetime 存在 —— 336 行构造时是 0（真值），所以这里总为真】
--   ⚠ 见 336 行的 ⚠：初值 0 会导致首次算出「从纪元开始的 dt」。
--     实践中不触发，因为 GoToState 的 597 行会先把它设为 GetTime()。
    if self.lastupdatetime then
--★【★ dt 用真实时间差，而不是固定帧长 GetTickTime()】
--   ★★ 这是「时间真实」而非「帧真实」的关键：
--     掉帧时 dt 变大 → timeinstate 加速推进 → timeline 正确追上；
--     帧率无关的动画与逻辑由此保证。
--   ★ 注释里的 `--+ GetTickTime()` 是历史痕迹：
--     曾经打算用固定帧长（更稳定但会丢时间），
--     改成真实时间差（更准确，能自动补偿掉帧）。
--   ⚠ 副作用：dt 可能很大（如切换世界回来时），
--     一次 Update 可能推进整条 timeline（668 行的 while 就是为此存在）。
        dt = GetTime() - self.lastupdatetime --+ GetTickTime()
    end
--★【★ 立刻更新基准 —— 即使下面出错也不会反复算出同一个大 dt】
    self.lastupdatetime = GetTime()

--★★【★ 推进状态机 —— 若过程中切了状态，本函数的后续计算用新状态的数据】
--   ★★ 注意 UpdateState（646 行）返回 nil，本函数不使用它的返回值。
--     状态切换的影响通过 self.currentstate 间接体现（728/737 行读它）。
    self:UpdateState(dt)

--★【★ time_to_sleep = 「距下一个 timeline 节点还有多久」】
--   ★★★ 这是「睡多久」的精确计算，让状态图可以睡到**恰好**错过节点之前。
    local time_to_sleep = nil
--⚠⚠【★★ 疑似缺陷：此处未判空 self.currentstate】
--   ⚠ 推理依据：
--     · UpdateState（647 行）有 `if not self.currentstate then return end` 守卫
--     · 但本行 `self.currentstate.timeline` **没有任何守卫**
--     · 728 行的 `self.timelineindex and` 短路在 currentstate 为 nil 时
--       是否生效取决于 timelineindex 的值——
--       若实例从未进过状态，timelineindex 是构造时的 nil（337 行），
--       短路成立，不会崩；
--       但若实例进过状态又被人为把 currentstate 置 nil，则崩。
--   ★ 实际触发路径分析：GoToState 在状态不存在时（532-535 行）
--     **直接 return，不改 currentstate**。
--     所以「实例注册了但从未成功进状态」是可能的：
--       entityscript.lua:1159 的首次 GoToState 若因 defaultstate 拼错而失败，
--       实例仍在 updaters 里，currentstate 为 nil。
--       下一帧 Update：725 行 UpdateState 被 647 行守卫拦住，
--       728 行若 timelineindex 为 nil 则短路通过，
--       733 行 self.timeout 为 nil 跳过，
--       ★ 737 行 `self.currentstate.onupdate` → **对 nil 取字段 → 崩溃**。
--   ★★★ 所以真正的崩溃点是 737 行，不是 728 行。
--     728 行只是第一个没有守卫的访问。
--   → 触发条件：状态图的 defaultstate 名字写错。
--     这是一个「配置错误导致运行时空指针」的真实陷阱。
--   ⚠ 本条为代码阅读推断，未在运行时验证。
    if self.timelineindex and self.currentstate.timeline and self.currentstate.timeline[self.timelineindex] then
--【★ 相减得到「还需等待的秒数」，可为 0 或负（节点已到点但还没触发）】
--   ★ 负值不会出错：668 行的 while 会立刻补触发，然后 741 行返回负值，
--     134 行的 `sleep_amount > 0` 判断为假 → 走 136 行继续更新 → 自愈。
        time_to_sleep = self.currentstate.timeline[self.timelineindex].time - self.timeinstate
    end


--★★★【★ timeout 与 timeline 的「先到先睡」仲裁】
--   ★★ 逻辑：若 timeout 更早（或没有 timeline），就按 timeout 睡。
--   ★★ 用 `not time_to_sleep or time_to_sleep > self.timeout` 而非简单的 min，
--     是为了处理「没有 timeline」的 nil 情况 ——
--     ★ 注意这是 and/or 的另一种用法，但**这次是安全的**：
--       条件表达的是布尔值，不会出现「返回 0 被当 falsy」。
--       对比 bug-patterns.md D1 的坑，此处没有。
--   ★ 举例：状态有 timeout=3 秒、无 timeline → 睡 3 秒；
--     状态有 timeline（下一个节点 1 秒后）和 timeout=3 秒 → 睡 1 秒，
--     醒来后再睡 2 秒（timeout 已递减）。
--   ★★★ 这就是「状态图能在整段时间安睡」的完整实现，
--     同时服务 timeline 驱动的动作和 timeout 驱动的兜底。
    if self.timeout and (not time_to_sleep or time_to_sleep > self.timeout) then
--【★ 覆盖为 timeout —— timeout 更早，先睡到它】
        time_to_sleep = self.timeout
    end

--⚠⚠⚠【★★ 关键：onupdate 的存在与否决定「永不休眠」】
--   ★★★ 这一行是 bug-patterns.md **F3 条目**「状态图永不休眠」的根因：
--       if self.currentstate.onupdate then
--           return 0
--   ★★★ 为什么必须这样？——onupdate 的语义就是「每帧调用」。
--     若有 onupdate 却返回睡眠值，onupdate 就不叫每帧了，语义自相矛盾。
--     ★ 所以这是**正确的**设计，只是后果严重：
--       一个写了 onupdate 的状态，会让整个状态图**永久每帧更新**。
--   ⚠⚠ 连带 bug：本行也是上面 728 行 ⚠ 提到的崩溃点 ——
--     currentstate 为 nil 时访问 .onupdate 会崩。
--   ★★★ F3 的完整症状（bug-patterns.md 原文）：
--     「一个 idle 状态如果写了空的 onupdate = function(inst, dt) end，
--       性能立刻掉一个数量级——状态图永远返回"每帧更新"，
--       即使实体已经离玩家很远。」
--   ★★ 修复原则（条目原文）：
--     「onenter / onexit / ontimeout 是"点"，timeline 是"帧"，
--       onupdate 是"每帧"。能写成时间点的一律不要写成 onupdate 里的时间比较。」
    if self.currentstate.onupdate then
--【★★ return 0 = 「下一帧继续更新我」（见 128 行三态协议）】
--   ⚠ 这就是 F3 的执行点：0 被 133 行判断为「不是正数」，
--     走 136 行 `self.updaters[k] = true` 留在表里 → 每帧都跑。
        return 0
--【★ 没有 onupdate → 走休眠分支，能睡就睡】
    elseif time_to_sleep then
--★【★ return time_to_sleep = 「睡这么久」—— 状态图省 CPU 的主路径】
--   ★★ 走 134 行的 Sleep → 归入 tickwaiters 桶 → 完全不参与更新。
--   ★ 这是绝大多数状态在绝大多数时间里的归宿。
        return time_to_sleep
--【★ 兜底：既没 onupdate 也没 timeout/timeline → 冬眠】
    else
--★【★ return nil = 「我没事了」→ Hibernate（见 139 行）】
--   ★★ nil 是三个返回值里唯一「表示没有值」的，
--     靠 132 行的 `if sleep_amount then` 与 nil 的 falsy 特性区分。
--   ★★★ 注意这条路径意味着「除非有人 Wake 我，否则我永远不动」。
--     任何需要这个状态继续动作的逻辑，都必须确保有 Wake 路径。
--     ⚠ 排查「怪物卡住不动」时，第一件事就是确认：
--       它当前状态是否既没 onupdate、也没 timeout、也没 timeline，
--       且本该有的后续事件没有 Wake 它。
        return nil
--【Update 结束 —— ★ 三态协议（0 / 正数 / nil）在此完成】
    end
end

--------------------------------------------------------------------------
--#V2C #client_prediction

--★★★【★ ServerStateMatches：客户端预测的合法性校验 —— 联机一致性的守门人】
--   ★★ 机制（三步）：
--     ① 本地必须有 player_classified（服务端镜像实体）
--        → 没有说明还没收到服务端的任何信息，保守返回 false
--     ② 取出服务端上报的当前状态名（currentstate 是网络变量，:value() 取 hash）
--     ③ 检查该 hash 是否在本地状态的 server_states 白名单里
--   ★★ 判定逻辑是「**白名单包含**」而非「完全相等」：
--     因为客户端可能预测经过了中间状态（attackpre），
--     服务端只上报最终状态 attack，只要 attackpre 声明了
--     `server_states = {"attack"}` 就算合法。
--   ★ 这是「预测容差」的表达方式，比严格相等实用得多。
function StateGraphInstance:ServerStateMatches()
--★★【★ V2C 注释：刻意不做 nil 检查，「让开发期所有错误都崩出来」】
--   ★★ 这条注释是一份设计哲学声明：
--     与 532 行的「状态不存在就 print 不崩」形成鲜明对比 ——
--       · 面向**用户数据**的路径（状态名来自存档/网络）→ 软失败
--       · 面向**开发者逻辑**的路径（server_states 未初始化）→ 硬失败
--   ★ 理由：server_states 为 nil 只可能是客户端状态定义漏了
--     server_states 参数（写代码时的疏忽），
--     这种情况应当在开发期就暴露，而不是带病上线。
--   ★★★ 这是本项目一条重要的取舍原则，值得记住：
--     **对不可信输入降级，对程序员疏忽硬失败。**
	--V2C: don't nil check self.server_states; should catch all errors during dev
--★【★ 两条件短路：先查有无服务端镜像，再查白名单】
--   ★ 短路顺序正确：没有镜像时不该去访问它（否则崩）。
	return self.inst.player_classified ~= nil and self.server_states[self.inst.player_classified.currentstate:value()]
--★【★ 查白名单：self.server_states 是 572-577 行 GoToState 时算好的】
--   ★★ 二者的对应关系：
--     · 客户端每进一次状态，GoToState 的 571-577 行重算一次 server_states
--     · 服务端每次上报 currentstate，客户端用 751 行校验一次
--   ★★ 闭环成立，客户端与服务端的状态序列保持一致。
--   ⚠ 隐患：若客户端在两次上报之间来回切状态，
--     最后一次 GoToState 算出的 server_states 就成了「唯一判据」，
--     早先的预测路径信息丢失。
--     ★ 这正是 forward_server_states（239 行）要缓解的问题：
--       沿用上一状态的白名单，把整条预测路径都算作合法。
end

--★【★ FastForward：预测快进的唯一实现 —— ★ 整个函数只有一行】
--   ★★ 注释自称 "#hack: use sparingly"（慎用），这个自评很诚实。
--   ★ 原理：lastupdatetime 往前拨 time 秒，
--     于是下次 Update 的 dt（721 行）凭空多了 time，
--     timeinstate 一次推进 time 秒，timeline 立刻追到当前位置。
--   ★★ 为什么这个 hack 相对安全？
--     它只影响「时间计算」，不触碰任何状态数据：
--       · statemem 不变
--       · timelineindex 不变（仍在正确位置）
--       · 668 行的 while 会把欠下的节点补触发（这正是想要的效果）
--   ★ 三处调用点：
--     · stategraph.lua:447  StartAction 里的预测快进
--     · FastForward 自身（无其他内部调用）
--   ⚠ 危险：若一个状态有多条时间线且都在同一瞬间到点，
--     快进会一次性触发多个节点。
--     ★ 缓解：真正使用它的场景（447 行）已限定在
--       「起手状态」的早期，此时通常只有 1-2 个节点。
--#V2C #hack: use sparingly... ^^""
--【★ 参数 time 单位是秒；调用方传的是 GetTickTime()（447 行的一帧时长）】
--   ★★ 也就是说实际只用「一帧」这个量做快进，
--     目的是消除「按下动作后动画慢一帧起步」的视觉延迟，
--     而非跳过整段前摇。
function StateGraphInstance:FastForward(time)
--★★【★ 核心一行：把「上次更新时间」往前拨 = 让时间凭空前进 time 秒】
--   ★★ 为什么减去而不是加？
--     dt = GetTime() - lastupdatetime（721 行）。
--     lastupdatetime 减小 → dt 增大 → 追赶到当前真实时刻。
--   ★★ 这个手法之所以优雅：只动一个「基准时间戳」，
--     整个时间推进体系（timeinstate / timeline / timeout）
--     都会自动跟随，无需任何补偿逻辑。
--   ★★ 参见 118-119 行的换表法、490 行的换表清空法：
--     本文件的「最小干预」哲学一脉相承 ——
--     改一个数据源，让既有机制自然产生正确结果。
	self.lastupdatetime = self.lastupdatetime - time
end

--------------------------------------------------------------------------
