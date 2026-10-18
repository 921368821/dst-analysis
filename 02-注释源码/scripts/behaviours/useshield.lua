--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/useshield.lua
-- 模块：行为树节点库 / 防御
-- 职责：「举盾」状态机：ShouldShield 判定是否值得举盾 → Visit 驱动举盾/放下 → OnStop 收尾，
--       附带 OnAttacked 事件回调与 TimeToEmerge（从地里钻出）计时。
-- 关键符号：UseShield, UseShield:Visit, UseShield:ShouldShield, UseShield:OnAttacked,
--           UseShield:TimeToEmerge, UseShield:OnStop
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/combat.lua, components/shield.lua（举盾能力源）,
--           stategraph, behaviourtree.lua（OnStop 与 Reset 的区别）
--============================================================
UseShield = Class(BehaviourNode, function(self, inst, damageforshield, shieldtime, hidefromprojectiles, hidewhenscared, data)
--[[
-- useshield.lua —— 举盾防御节点（UseShield）：按累计伤害/威胁状态临时进入防御姿态
--
-- 【★★★ 本文件是「事件驱动型节点」的范本，与其他所有节点都不同】
-- 前面的节点（approach/follow/chaseandattack/runaway）都是「轮询型」：
--   Visit 每帧问一次「现在该做什么」。
-- 本文件是「事件驱动型」：
--   · 构造时注册 5 个事件监听（第 30-34 行），威胁由**事件**推给它
--   · Visit 只负责在合适的时机 PushEvent 让 stategraph 切换姿态
--   · 第 28 行甚至直接调 brain:ForceUpdate() 把沉睡的大脑**强行唤醒**
--★★ 这是 DST AI 性能体系的核心手法（brain.lua:170-175）：
--   ForceUpdate → bt:ForceUpdate()（让下次 GetSleepTime 返回 0）
--                + BrainManager:Wake(self)（把大脑移出 Hibernate）
--   ★★ 有了它，正在深度休眠的大脑能在被电击的**同一帧**重新决策，
--     而不必等 Sleep 队列到期。
--   ★ 移植要点：**休眠机制必须有事件驱动的唤醒通道**，
--     否则「沉睡期间发生紧急事件」会延迟到下一次自然醒，最坏情况是几十秒。
--     这是自研 AI 最容易漏掉的一条。
--
-- 【★ 状态设计：谁持有「该不该防御」的判断】
--   本节点把判断拆成两半：
--     · ShouldShield()（第 55 行）—— 每帧算一次的「此刻要不要举盾」
--     · 累积量（damagetaken / projectileincoming / scareendtime）—— 事件写入
--   ★★ 事件负责「累加证据」，Visit 负责「综合判断」——职责分离得很干净。
--]]
--★★ 6 个形参：inst / damageforshield / shieldtime / hidefromprojectiles /
--   hidewhenscared / data。
--★ 依然是「平铺 4 个 + data 表 1 个」的折中结构（对照 wander 的纯 data 表）。
--★ ★ 本文件是最好的折中范例：核心开关平铺（写起来方便），
--   低频/高级选项收进 data（不占位置）。移植时按「调用频率」决定怎么分组。
    BehaviourNode._ctor(self, "UseShield")
    self.inst = inst
    self.damageforshield = damageforshield or 100
--★ damageforshield = 100：累计受伤到这个值就举盾。
--★ 默认值 100 是「值得为之防御」的量级 —— 游戏设计判断，不是技术必然。
    self.hidefromprojectiles = hidefromprojectiles or false
--★ hidefromprojectiles：躲投射物时是否完全缩起来（而非正常举盾）。
--★ 与第 95 行的处理联动 —— 记下 incoming 但不累加伤害，直接 return。
    self.scareendtime = 0
--★★★ 三个「事件累积量」，全部由事件回调写入、Visit 读取：
--   scareendtime    —— 惊吓状态何时结束（第 21 行写入）
--   damagetaken     —— 累计受伤量（第 92 行累加）
--   projectileincoming —— 有投射物来袭（第 96 行置位）
--★ 另有 timelastattacked（第 8 行）与 shieldendtime（第 52/81/110 行）
--   构成「举盾持续多久」的时间控制。
--★★ 这就是本节点的「共享黑板」形态：
--   事件系统 = 写入方，节点 = 读取方，self 字段 = 通信介质。
--   ★ 对比黑板的其他用法（如 self.inst.topdog 共享索敌结果），
--     这里用的是「节点私有字段 + 事件」的局部黑板，耦合更低。
    self.damagetaken = 0
    self.timelastattacked = 1
--★ timelastattacked 初值 1 —— 刻意给一个「很早的时间戳」。
--   ★★ 这是一处精心设计的初值：TimeToEmerge（第 50 行）算 `t - timelastattacked > shieldtime`，
--     初值 1 意味着「上次被攻击是 1 秒前」，游戏刚开始时也立刻满足，
--     于是可以立即从地下钻出来。
--   ★ 若初值写成 0，则开局时要等 shieldtime 秒才能起身 —— 微小但真实的体验 bug。
--★ 这种「用初值表达初始状态」的技巧值得记住。
    self.shieldtime = shieldtime or 2
--★ shieldtime = 2：最后一次被攻击后 2 秒才钻出来。
--★ 这就是「盾持续多久」，决定防御姿态的黏性。
    self.projectileincoming = false
--★ projectileincoming 初值 false，与第 96 行的置位配对。

    if data then
--★★ data 表的五个可选开关（逐项直接取，不设默认值）：
--   dontupdatetimeonattack —— 不在「被攻击」时更新时间，改在节点启动时更新
--   usecustomanims         —— 用自定义动画，不播 hit_shield
--   dontshieldforfire      —— 着火时不举盾
--   checkstategraph        —— 检查「忙碌中且不可打断」状态（第 60 行）
--   shouldshieldfn         —— 完全自定义「要不要举盾」，可返回持续时长
--★ 与 wander 的 `data and data.x or 默认值` 不同，这里是 `self.x = data.x`（nil 即可）。
--   因为这五项都是「布尔/nil 语义」，不需要数值兜底 —— 写法正确且更简洁。
        self.dontupdatetimeonattack = data.dontupdatetimeonattack
        self.usecustomanims = data.usecustomanims
        self.dontshieldforfire = data.dontshieldforfire
        self.checkstategraph = data.checkstategraph
        self.shouldshieldfn = data.shouldshieldfn -- shouldshieldfn CAN optionally return a time to shield for.
--★★ 原注释（保留）：shouldshieldfn CAN optionally return a time to shield for.
--   翻译：shouldshieldfn **可以**（大写强调）额外返回一个举盾时长。
--★★ 这条注释很关键：它说的是「多返回值」这一 Lua 特性，
--   体现在第 67 行的 `return should_shield, time_to_shield or nil`。
--   ★ 移植要点：Lua 函数天然支持多返回值，
--     让一个回调同时返回「是否」与「多久」，比拆成两个回调干净得多。
    end

    if hidewhenscared then
--★ hidewhenscared 为真才注册惊吓监听 —— 按需注册，省一个监听。
--★ ★ 移植要点：事件监听不是免费的（每次事件都要做一次表查找），
--     不用的监听就不要注册。构造器里用开关决定注册哪些监听是好习惯。
        self.onepicscarefn = function(inst, data) self.scareendtime = math.max(self.scareendtime, data.duration + GetTime() + math.random()) end
--★★★ 惊吓持续时间的计算：`data.duration + GetTime() + math.random()`。
-- ★三层含义：
--   · GetTime()      —— 当前时刻
--   · data.duration  —— 惊吓本身持续多久（来自事件源）
--   · math.random()  —— **加一个 [0,1) 的随机小数**
-- ★★ 最后那个随机数是为了「让不同生物的举盾时长错开」，
--   避免全场生物在同一毫秒同时起身 —— 视觉上很关键。
-- ★ 移植要点：**群体同步行为要用微小随机打散**，否则「整齐划一」看起来很假。
-- ★ 第 21 行用 math.max 而非直接赋值：多次惊吓取最晚的那个结束时刻，
--   而不是「最后一次惊吓覆盖前面的」—— 保证防御不会被打断得太早。
--★ 三个事件的回调签名也各不相同：
--   epicscare           → function(inst, data)  data 有 duration 字段
--   attacked             → function(inst, data)  data 有 attacker / damage
--   hostileprojectile    → function()              无参数
--   firedamage/startfiredamage → function()        无参数
-- ★★ 说明框架的事件负载是**不统一**的，接入时必须逐个确认签名，
--   不能想当然。移植自己的事件系统时应统一签名以避免这类坑。
        self.inst:ListenForEvent("epicscare", self.onepicscarefn)
    end

    self.onattackedfn = function(inst, data) self:OnAttacked(data.attacker, data.damage) end
    self.onhostileprojectilefn = function() self:OnAttacked(nil, 0, true) end
    self.onfiredamagefn = function() self:OnAttacked() end
	self.onelectrocutefn = function() self.inst.brain:ForceUpdate() end
--★★★★【本文件最值得学的一行】self.inst.brain:ForceUpdate()
--
-- 一个「被电击」事件触发的**唯一**动作：强行唤醒大脑。
-- ★★ 为什么电击需要它？因为第 105 行的逻辑依赖 HasStateTag("electrocute")，
--   而电击状态的变化由 stategraph 驱动，不由行为树驱动。
--   若大脑此刻在 Hibernate（零 CPU），它就永远看不到电击状态结束，
--   于是会**卡在举盾状态里出不来**（第 133 行永远不满足 TimeToEmerge）。
--
-- ★ ForceUpdate 的实现（brain.lua:170-175，我已核实）：
--     bt:ForceUpdate()      → 下次 GetSleepTime 直接返回 0（不睡）
--     BrainManager:Wake()   → 把大脑从 Hibernate 移回 updaters
--   两者缺一不可：前者保证「这次一定会被更新」，后者保证「它会被更新」。
--
-- ★★★★ 移植要点（本文件的最强收获）：
--   **凡是「状态变化由外部系统驱动」的 AI，都必须有一条事件唤醒通道。**
--   典型的外部状态：被电击/被冻结/着火/被推走 —— 它们不由 AI 决定，
--   却会影响 AI 的决策。休眠 + 无唤醒 = 永久卡死。
--   这类 bug 在开发期几乎必然出现（因为测试时很少「恰好在休眠时被打」），
--   上线后才暴露。这也是为什么 DST 给每个节点都认真处理 OnStop/ForceUpdate。

    self.inst:ListenForEvent("attacked", self.onattackedfn)
    self.inst:ListenForEvent("hostileprojectile", self.onhostileprojectilefn)
    self.inst:ListenForEvent("firedamage", self.onfiredamagefn)
    self.inst:ListenForEvent("startfiredamage", self.onfiredamagefn)
	self.inst:ListenForEvent("startelectrocute", self.onelectrocutefn)
end)

function UseShield:OnStop()
--★★ OnStop 摘掉全部 6 个监听，与构造器注册的一一对应。
--★ 第 38 行的判空是因为 onepicscarefn 只在 hidewhenscared 时才创建（第 20-23 行）。
--★ ★ 移植要点：**注册与反注册必须成对，且反注册前要判空**。
--   忘记判空会在 RemoveEventCallback(nil) 时静默失败或报错。
--★ 再次强调本目录通病（behaviourtree.lua:287-298）：
--   只有 bt:Stop() 会调 OnStop；每轮思考后的 Reset 不会。
--   所以「行为反复重来」时监听会一直挂着，这是安全的；
--   风险在于「重建 bt 而不先 Stop 旧的」→ 监听累积。
    if self.onepicscarefn ~= nil then
        self.inst:RemoveEventCallback("epicscare", self.onepicscarefn)
    end
    self.inst:RemoveEventCallback("attacked", self.onattackedfn)
    self.inst:RemoveEventCallback("hostileprojectile", self.onhostileprojectilefn)
    self.inst:RemoveEventCallback("firedamage", self.onfiredamagefn)
    self.inst:RemoveEventCallback("startfiredamage", self.onfiredamagefn)
	self.inst:RemoveEventCallback("startelectrocute", self.onelectrocutefn)
end

function UseShield:TimeToEmerge()
--★★★ TimeToEmerge —— 决定「什么时候可以从盾里钻出来」的三重与条件。
--
-- 【三个条件全满足才返回 true】
--   ① 距上次被攻击已超过 shieldtime      （第 50 行）
--   ② 当前惊吓已结束（t >= scareendtime）  （第 51 行）
--   ③ 自定义盾时长已到 或 未设              （第 52 行）
--
--★★★ 这就是「防御姿态的解除条件」——与 leashandavoid 的双阈值滞回同源思想，
--   但这里用的是「时间」而非「距离」：
--   · 进入靠事件累积（受击/受惊/投射物）
--   · 退出靠静默超时（安静 2 秒 + 惊吓结束）
-- ★★ 关键洞察：**防御是「被激发的」，所以解除条件必然是「威胁不再持续」**，
--   而「威胁是否还在持续」最可靠的信号就是「安静了多久」。
--   ★ 移植要点：几乎所有「临时状态」都该有一个静默超时，
--     否则状态会永久卡住。DST 这里用 2 秒，是个好起点。
    local t = GetTime()
    return t - self.timelastattacked > self.shieldtime
--★ 静默超时：t - timelastattacked > shieldtime。
--★ ⚠️ 用的是严格大于；恰好等于 2.0 秒时仍不算结束。微小差异，无影响。
        and t >= self.scareendtime
        and (self.shieldendtime == nil or t >= self.shieldendtime)
--★ shieldendtime 为 nil 表示「没设自定义时长」→ 该条件自动满足。
--★ 三重与里的 or nil 项，作用是「让没配自定义时长的走默认逻辑」。
end

function UseShield:ShouldShield()
--★★ ShouldShield —— 「此刻要不要举盾」的完整判断链，优先级从上到下。
-- ★★ 这个函数的结构值得学：**硬性否决 → 状态检查 → 自定义 → 默认规则**。
--   自定义回调（shouldshieldfn）放在默认规则**之前**，
--   意味着上层可以覆盖内建判断 —— 这是很好的扩展点设计。
-- ★ 移植要点：扩展点的优先级顺序要在设计时明确，
--   否则「自定义却没生效」会是最难查的 bug。
    if self.inst.components.health:IsDead() then
--★ 硬否决 1：已死不举盾。显然。
--★ 但它必须排在最前 —— 否则死人会进入防御状态并卡住（无头骑士效应）。
        return false
    end

    if self.checkstategraph and (self.inst.sg:HasStateTag("busy") and not self.inst.sg:HasStateTag("caninterrupt")) then
--★★ 硬否决 2：状态图「忙且不可打断」时不举盾。
--   条件：checkstategraph 开关开 + HasStateTag("busy") + 不 HasStateTag("caninterrupt")
-- ★★ 语义：正在播放某个不能被打断的动作（如挖矿、开门动画）时不要插举盾。
-- ★★★ 这是**跨系统协作的典范**：行为树节点主动尊重状态图的状态标签，
--   避免两个系统同时争夺实体的控制权。
--   ★ 移植要点：动作系统与 AI 系统并存时，
--     必须有明确的「谁在控制实体」仲裁规则。本行就是那条规则的代码化。
-- ⚠️ 第 60 行直接访问 self.inst.sg 而不判空 ——
--   我已核实本文件其他处（如第 87 行）都有 `if self.inst.sg ~= nil then` 的保护。
--   这里没有，说明作者假定「用 UseShield 的实体必有 stategraph」。
--   标注为「隐含前提」：非缺陷，但对「无 sg 实体」不健壮。
        return false
    end

    if self.shouldshieldfn then
--★ 自定义判断：若提供了 shouldshieldfn，优先听它的。
--★ 第 65 行一次调用取两个返回值（是否 + 举盾时长）。
        local should_shield, time_to_shield = self.shouldshieldfn(self.inst)
        if should_shield then
            return should_shield, time_to_shield or nil
--★★★ `return should_shield, time_to_shield or nil` —— 双返回值的转交。
-- ★★ `time_to_shield or nil` 是纯粹的防御：若回调只返回 true，
--   time_to_shield 就是 nil，加 or nil 无变化。
--   ★ 语义上没做任何事，纯粹是「表达意图：没有时长就是没有」。
--   标注为「冗余但无害」：也可写成 return should_shield, time_to_shield。
--★ 真正的消费点在第 109-111 行：time_to_shield 非 nil 时设 shieldendtime。
        end
    end

    return (self.damagetaken > self.damageforshield or
--★★★★ 内建的四条「举盾理由」，任一成立即举盾：
--   ① 累计伤害超过阈值     —— 被打得够多了，用盾回本
--   ② 正在受到火焰伤害     —— 除非 dontshieldforfire（第 72 行）
--   ③ 有投射物来袭
--   ④ 处于惊吓状态中
--★★ 这四条都是「累积量」而非「瞬时状态」，且都由事件写入 ——
--   印证了文件头的判断：事件负责攒证据，Visit 负责综合判断。
--★ 返回值只有布尔（无时长），所以自定义时长只能通过 shouldshieldfn 提供。
-- ★★ 注意第 74 行：返回的是表达式本身（Lua 的 if 无 else 时最后一行即返回值），
--   没有显式 return true —— 简洁但要求读者知道这个惯用法。
            (not self.dontshieldforfire and self.inst.components.health.takingfiredamage) or
            self.projectileincoming or
            GetTime() < self.scareendtime)
end

function UseShield:OnAttacked(attacker, damage, projectile)
--★ OnAttacked 是四个事件的共同落点（第 25-27 行的三个回调都调它）。
--★★ 关键设计：**不同事件传不同参数，用 nil 表达「信息缺失」**：
--   attacked            → OnAttacked(attacker, damage)         两个都有
--   hostileprojectile   → OnAttacked(nil, 0, true)              只有 projectile=true
--   firedamage          → OnAttacked()                         全缺
--★ 于是一个函数处理三类威胁，靠参数是否为 nil 分流（第 84/91/95 行）。
--★ ★ 移植要点：用 nil 占位比定义多个回调更省，但**必须清楚每个位置可能缺什么**，
--   否则会出现「以为 damage 一定有值」的隐蔽 bug。
    if not self.inst.sg:HasStateTag("frozen") then
--★ 冰冻状态下不响应 —— 无法在举盾时被打断举盾动画。
--★ 语义：「被冻结的生物不做任何防御反应」，合理。
        if not self.dontupdatetimeonattack then
--★ 只有「不在受击时更新时间」的模式下才更新 timelastattacked。
--★★ 这解释了 dontupdatetimeonattack 的用途（第 113-119 行）：
--   默认：每次挨打都续期 → 持续挨打就一直举盾（合理）
--   开启：只在开始举盾时记一次 → 盾时长固定（适合「一次性护盾」）
-- ★ 移植要点：这类开关本质是「计时起点放哪」的策略差异，
--   写成配置项就变成了一族行为，参数化做得非常到位。
            self.timelastattacked = GetTime()
            self.shieldendtime = nil -- If we we had a custom shield end time, clear it and rely on time last attacked now.
--★ 被攻击时清掉自定义结束时刻，改回「按最后一次受击计时」。
--★ 原注释有一处笔误：if we **we** had（重复了一个 we），不影响理解。
--★★ 语义优先级的体现：默认逻辑优先于自定义时长。
        end

        if not self.usecustomanims and
--★★ 已经在举盾且不是投射物 → 播「被击中」动画，然后 return。
--   三条件：不用自定义动画 + 当前状态名恰为 "shield" + 不是投射物
-- ★★ 注意这里**直接访问 sg.currentstate.name**（精确匹配状态名而非状态标签）。
--   多数地方用 HasStateTag，这里用名字 —— 说明「shield」是个具体状态，
--   而不是一个标签（否则应该给它加标签）。属合理的精确匹配。
-- ★★ return 的重要性：返回后**不累加 damage、不置 projectileincoming**。
--   即「盾已经挡下了这次攻击，不再重复计数」。
--   ★ 移植要点：这是「防御成功 → 不推进威胁累积量」的短路，
--     避免了「明明挡住了却还在累加伤害导致无限举盾」。
                self.inst.sg.currentstate.name == "shield" and not projectile then
            self.inst.AnimState:PlayAnimation("hit_shield")
            self.inst.AnimState:PushAnimation("hide_loop")
            return
        end

        if damage then
--★ 累加伤害。damage 为 nil 时跳过（第 91 行的 if 保护）。
--★ ★ 移植要点：这就是第 77 行「参数可能缺失」的直接后果 —— 必须判 nil。
            self.damagetaken = self.damagetaken + damage
        end

        if projectile and self.hidefromprojectiles then
--★ 投射物 + hidefromprojectiles → 记下 incoming 并 return。
--★★ 同样用 return 短路：不累加 damage（第 95 行在第 91 行之后）。
--   即「躲起来时把伤害视为 0」—— 因为躲开了就不该扣血阈值。
--★ projectileincoming 在第 107 行被清零，即每次进入 RUNNING 都重置。
            self.projectileincoming = true
            return
        end
    end
end

function UseShield:Visit()
--★★ Visit —— 本节点的结构与其他节点有一个显著不同：**有 return**。
-- ★★ 对照 chaseandattack/approach 的「顺序双 if」，本文件是：
--     READY 段执行完就 return；只有 RUNNING 段独立执行。
-- ★★ 这样做是**必需**的，因为第 130 行的判断依赖第 104 行的局部变量
--   （time_to_shield 只在 READY 段赋值）。
--   若写成顺序双 if，同帧内 RUNNING 段也能跑，会用到 nil 值。
-- ★ 移植要点：局部变量的作用域决定了结构 ——
--   有跨段依赖就用 return 隔开，没有就用顺序双 if 少一次判断。
    if self.status == READY  then
        local should_shield, time_to_shield = self:ShouldShield()
		if (should_shield or self.inst.sg:HasStateTag("shield")) and not self.inst.sg:HasAnyStateTag("electrocute", "shield_end") then
--★★★★【进入条件 —— 四重判断，是本节点最精妙的一处】
--   第 104 行：ShouldShield() 返回 (should_shield, time_to_shield)
--   第 105 行：
--     (should_shield 或 已经在举盾中) 且 不在 electrocute 且 不在 shield_end
--
-- ★★ 逐条解释为什么这样写：
--   ① `or HasStateTag("shield")` —— 已在举盾就**继续**举盾，
--     即使 ShouldShield 已返回 false。因为「退出」由 TimeToEmerge 决定，
--     而不是由 ShouldShield 决定。
--     ★★ 这是本文件架构的核心：ShouldShield 管【进入】，TimeToEmerge 管【退出】。
--     两者分离避免了「条件一变就退出」的抖动。
--   ② 排除 electrocute —— 被电击时不能举盾（第 131 行也会因此 FAILED）。
--     ★ 一致性：进入时排除 + RUNNING 时判 FAILED，两处呼应。
--   ③ 排除 shield_end —— 「正在结束」的过渡态不能被重新拉回。
--     ★ 防抖：否则可能在结束动画中途又 PushEvent("entershield") 反复。
-- ★★★★ 移植要点：「进入条件」要考虑「当前是否已在目标状态」，
--     否则节点会被自己的判定结果卡在边缘。
            self.damagetaken = 0
--★ 进入时清空两个累积量 —— 防御是「一次性的」，不累积上一轮的伤。
--★★ 与 chaseandattack 第 48 行重置 numattacks 完全同构：
--   进入新阶段时清空累积计数，是所有「计数型节点」的通用纪律。
            self.projectileincoming = false

            if time_to_shield then
--★ 有自定义时长 → 记录结束时刻（TimeToEmerge 的第三个条件会用到）。
--★ 只有第 67 行返回了时长时才生效，默认路径下 shieldendtime 保持 nil。
                self.shieldendtime = GetTime() + time_to_shield
            end

            if self.dontupdatetimeonattack then
--★★★ dontupdatetimeonattack 分支 —— 与第 79 行是配对的。
--   因为这个模式不在「被攻击」时更新时间（第 79 行被跳过），
--   所以必须在**节点启动时**记一次，否则第 50 行的静默判定永远不满足，
--   节点会永久卡在 RUNNING。
--★★ 典型的「两处修改必须成对」：第 79 行跳过更新，这里补上。
                -- If we're not updating on attack, we have to update when we
                -- start running the node instead.
                self.timelastattacked = GetTime()
                if not self.inst.sg:HasStateTag("shield") then
--★ 双重判断：只有「还没在举盾」时才推 entershield 事件。
--★ 防抖：已在举盾时不重复推事件（stategraph 已在该状态里，推了也没用）。
                    self.inst:PushEvent("entershield")
--★ PushEvent 是行为树与 stategraph 的通信手段。
--★★ 全节点只用了两个事件名：entershield（进入）/ exitshield（退出）。
--   ★ 移植要点：**行为树不直接控制动画，而是推事件让状态图自己决定怎么演**。
--     这样动画、声音、特效都能在状态图里统一编排，不会与 AI 逻辑打架。
                end
            else
                self.inst:PushEvent("entershield")
--★ 默认模式直接推 entershield（无需判断当前状态 —— 因为第 105 行已排除已在举盾的重复进入？
--   实际上第 105 行的 or 分支允许「已在举盾」也进来，此时会重复推事件）。
--⚠️【疑似冗余 · 已核实】对比第 117-118 行有 HasStateTag("shield") 判空，
--   第 121 行没有。后果：若因 should_shield 从 false 变 true 而重复进入 READY 段，
--   会再次推 entershield。stategraph 通常能容忍（已在该状态则忽略），故无害。
            end

            self.status = RUNNING
        else
            self.status = FAILED
        end
    end

    if self.status == RUNNING then
--★★ RUNNING 段：决定「什么时候解除防御」，三条路径。
		if self.inst.sg:HasStateTag("electrocute") then
--★ 被电击 → FAILED（强制放弃防御）。
--★ 与第 105 行的排除项呼应：电击状态下不会进入，也不会持续。
			self.status = FAILED
		elseif not self:TimeToEmerge() or
--★★★ 核心分支：两个 or 条件**都表示「继续举盾」**：
--   not TimeToEmerge()                 —— 时间没到，继续
--   正在受火焰伤害（且未禁用火焰防御）    —— 火还没灭，继续
-- ★★ 于是 else 分支才是「结束」：PushEvent("exitshield") + SUCCESS。
-- ★★★ 注意第 135 行那个略显奇怪的写法：`self.status = RUNNING`。
--   它是**自我赋值**（进来时就是 RUNNING）。
--   推测原意是写 SUCCESS 或其他值，改动时漏改了；
--   但从语义上恰好无害 —— 「继续」就是不改变状态。
--   我已核实第 133-135 行的条件成立时确实是「维持 RUNNING」，语义正确。
--   标注为「已核实的冗余赋值」：无害，但读代码时会让人困惑。
                (not self.dontshieldforfire and self.inst.components.health.takingfiredamage) then
--★ 着火时「不结束防御」—— 因为火还没灭，钻出来会被烧。
--★ 与第 72 行的 dontshieldforfire 开关对应：
--   默认（不设）→ 着火也举盾（第 72 行 true 分支）
--   开启        → 着火不举盾（第 72 行 false 分支），
--                  此处也不再续期，会正常结束。
            self.status = RUNNING
        else
            self.inst:PushEvent("exitshield")
--★ 结束防御：推 exitshield 事件 + SUCCESS。
--★★ SUCCESS 的语义是「防御这一轮成功完成」，
--   与第 126 行的 FAILED（不满足进入条件）形成对照。
-- ★★ 对父节点（Sequence/Priority）而言：
--   · SUCCESS → 举盾成功，继续下一个行为
--   · FAILED → 没能举盾（不需要防御或被电击），也继续
--   两者都会让父节点前进，但语义不同，便于调试与后续决策。
-- ★ 本节点**没有** self:Sleep —— 故 GetSleepTime 返回 0，大脑每帧都跑。
--   这在防御这种「需要即时响应」的场景下是合理的，
--   且本节点靠事件唤醒（第 28 行）而非轮询节流，CPU 开销可控。
            self.status = SUCCESS
        end
    end
end