--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/health.lua
-- 模块：组件系统 / 生命值（Health）
-- 职责：全游戏唯一的血量容器与扣血汇聚点。承担伤害结算（DoDelta）、
--       吸收/减伤/承伤上限、温度与饥饿的非致死保护、火焰伤害计时与
--       每秒上限、月光灼烧标记、回复源管理、生命惩罚（penalty）、
--       死亡事件与尸体化、存档序列化、联机副本同步等职责。
--       全游戏 120+ 处调用方最终都收敛到 DoDelta 一条路径上，
--       所以它的参数语义就是整个游戏「生存压力」的总契约。
-- 关键符号：Health, DoDelta, SetVal, SetPercent, GetPercent, IsDead,
--           GetMaxWithPenalty, SetPenalty, DeltaPenalty, Kill, ForceKill,
--           DoFireDamage, StartRegen, AddRegenSource, RemoveRegenSource,
--           SetAbsorptionAmount, RegisterLunarBurnSource, CanFadeOut,
--           TransferComponent, OnSave, OnLoad
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：util/sourcemodifierlist.lua（修饰器容器）,
--           components/health_replica.lua（客户端镜像）,
--           components/combat.lua（战斗扣血主入口）,
--           components/hunger.lua / components/temperature.lua（环境扣血）,
--           components/revivablecorpse.lua（复活）,
--           componentutil.lua（CanEntityBecomeCorpse）,
--           simutil.lua（ErodeAway）, class.lua（属性 setter 机制）
--============================================================
--
--【阅读导航】
--  §一  属性 setter 回调层（3-60）      —— health 字段变化如何驱动副本同步与战斗阈值
--  §二  构造与存档（62-186）            —— 全部状态字段的初始化清单、只存三样的 OnSave
--  §三  火焰伤害（188-253）             —— 状态机、点燃前摇、每秒 120 点上限
--  §四  月光灼烧（255-316）             —— 位标志归约、来源自摘除
--  §五  回复体系（318-438）             —— 单例 StartRegen vs 多源 AddRegenSource
--  §六  上限与惩罚（440-526）           —— GetMaxWithPenalty 现算、三代减伤机制
--  §七  死亡流程（528-611）             —— SetVal、事件顺序契约、尸体化、淡出
--  §八  DoDelta 全解（613-649）         —— ★ 全游戏所有生存压力的最终汇聚点
--  §九  组件迁移（651-663）             —— TransferComponent 的迁移清单
--
--【全文件最重要的五条】
--  1. DoDelta:613 是七级流水线，顺序不可交换；返回实际生效的 amount。
--  2. DoDelta:629 的 externalreduction 因 `afflicter ~= nil` 短路而对环境伤害无效。
--  3. DoDelta:628 的一代 absorb 若为 nil 会崩（bug-patterns.md 收录的 nil 陷阱）。
--  4. SetVal:585-590 世界事件必须先于实体事件，否则死亡时自删的 prefab 会让世界拿到死实体。
--  5. ForceUpdateHUD:150 用 DoDelta(0, ...) 兼作「HUD 刷新」的通用手段。
--★★ 本文件唯一的硬依赖只有 SourceModifierList。参见 util/sourcemodifierlist.lua:8
--   —— 它是 DST 的「带来源标记的修饰器容器」，自动处理来源实体被 Remove 时
--   摘除修饰器（见 sourcemodifierlist.lua 的 SetModifier 里注册的 onremove 监听）。
--   本文件用它承载 absorb / reduction / 火焰伤害倍率三组外部修正。
local SourceModifierList = require("util/sourcemodifierlist")

--★★★【血量→战斗阈值 的隐式联动钩子】这是全文件最容易被忽略的一段。
--   读取 panic_thresh（逃跑阈值）再原样写回自己，纯粹是为了触发
--   components/combat.lua 里 panic_thresh 的属性 setter 副作用——
--   该 setter 会按当前血量百分比重算「是否进入恐慌状态」并同步到副本。
--   ★ 为什么要这么绕？因为血量是纯数据字段（currenthealth），
--   血量变化本身不该知道战斗组件的存在。用「自赋值触发 setter」把
--   两个组件的耦合点收敛成一个纯函数调用，避免 health 直接依赖 combat。
--   ⚠ 移植到强类型语言时这条「自赋值触发副作用」的约定会丢失，
--     必须改成显式的 healthpercentchanged 回调。
--★★ 参见 components/combat.lua 的 panic_thresh 属性 setter ——
--   本文件通过自赋值触发它。同文件 combat.lua:653 是 DoDelta 的主调用方，
--   它把 combat 的 damage 计算结果作为 amount 传入，并消费 DoDelta 的返回值
--   来判定「实际造成的伤害」。
local function onpercent(self)
--★ nil 守卫：不是所有挂了 health 的实体都有 combat（树人、物品、雕像等）。
--   组件之间只做「弱存在」检查，绝不假设对方一定在。
    if self.inst.components.combat ~= nil then
        self.inst.components.combat.panic_thresh = self.inst.components.combat.panic_thresh
    end
end

--★★【onmaxhealth】上限变化的三件事：同步副本 → 通知可修理性 → 通知战斗阈值。
--   为什么 SetMax 要通知 repairable？因为「护甲/船体能否修理」取决于
--   当前耐久是否低于满值；上限一变，判定基准就变了。
local function onmaxhealth(self, maxhealth)
--★【replica 同步的唯一入口】血量上限写进 player_classified 的 netvar，
--   由 netvars.lua 的脏标记机制在下一网络帧广播给客户端。
--   参见 netvars.lua 的 netvar 定义。
--★★ 参见 components/health_replica.lua:57 SetMax ——
--   内部走 `self.classified:SetValue("maxhealth", max)` 写 netvar。
--   参见 netvars.lua 的 netvar 声明；netvar 的「声明顺序即 wire format」约束
--   记录在 bug-patterns.md 的 B1。
    self.inst.replica.health:SetMax(maxhealth)
    local repairable = self.inst.components.repairable
    if repairable then
--★ `(self.currenthealth or maxhealth) < maxhealth`：构造期 currenthealth 可能为 nil
--   （读档时序），此时按「满血」处理，即不提示修理。
--   ★ 注意这里读的是 raw self.currenthealth 而非 GetMaxWithPenalty()，
--     所以带 penalty 的实体修理提示判定用的是「未扣罚」的上限——有意为之。
        repairable:SetHealthRepairable((self.currenthealth or maxhealth) < maxhealth)
    end
    onpercent(self)
end

--★★★【oncurrenthealth：血量变化的下游扇出点】每次 currenthealth 被赋值都会触发。
--   三件事：① 同步 current；② 同步 isdead 标志；③ 通知 repairable；
--   ④ 回调 onpercent 触发战斗阈值重算。
--   ★★ 关键设计：isdead 是**通过 netvar 与 tag 双通道**下发的。
--     血量数值走 player_classified，而「是否死亡」额外走实体 tag，
--     因为 tag 参与兴趣管理与点击检测，客户端逻辑（如 locomotor）
--     需要在血量数值尚未到达时就能提前中止移动。参见 locomotor.lua:1457。
local function oncurrenthealth(self, currenthealth)
--★★ 参见 components/health_replica.lua:51 SetCurrent / :130 SetIsDead。
--   health_replica.lua:41 GetPenaltyPercent_Client 揭示了惩罚的定点数同步（/200）。
    self.inst.replica.health:SetCurrent(currenthealth)
--★ 死亡判定用 `<= 0` 而不是 `== 0`——因为 minhealth 机制允许血量停在负数区间，
--   0 只是一个阈值而不是必须精确命中的值。
--★ 参见 components/locomotor.lua:1457 ——
--   移动组件每帧检查 `self.inst.components.health:IsDead()`，
--   死掉就立刻 Clear() 中断移动。也就是说「死亡」会通过 health 组件
--   影响 locomotor 的行为，是两个组件之间最直接的一处耦合。
    self.inst.replica.health:SetIsDead(currenthealth <= 0)
    local repairable = self.inst.components.repairable
    if repairable then
        repairable:SetHealthRepairable(currenthealth < self.maxhealth)
    end
    onpercent(self)
end

--★ 火焰状态也要下发：客户端用它播「正在燃烧」的音效/特效与屏幕效果，
--   所以必须是 netvar 而不是纯服务端字段。
local function ontakingfiredamage(self, takingfiredamage)
    self.inst.replica.health:SetIsTakingFireDamage(takingfiredamage)
end

--★ 二次伤害（low damage）单独一路 netvar：客户端据此决定播弱特效还是强特效，
--   避免每帧同步布尔翻转造成的抖动。
--   ⚠ 这里做了 `== true` 归一化，把 nil 也压成 false——
--     因为 health.lua 里 takingfiredamagelow 用 nil 表示「无低伤阶段」，
--     而 netvar 不能传 nil。参见下方 203/215/247 行的 nil 语义。
local function ontakingfiredamagelow(self, takingfiredamagelow)
    self.inst.replica.health:SetIsTakingFireDamageLow(takingfiredamagelow == true)
end

--★ 月光灼烧用位标志（bit flags）而不是布尔：同一次召唤可以叠加多种灼烧源
--   （例：守卫者多种攻击同时附加），客户端按位判断要播哪种特效。
--   `or 0` 是 nil 守卫：lunarburnflags 为 nil 表示「无灼烧」。
--   ★ 注意本行用 Tab 缩进（原文件混用 Tab 与空格），但缩进差异不影响 Lua 语义。
local function onlunarburnflags(self, lunarburnflags)
	self.inst.replica.health:SetLunarBurnFlags(lunarburnflags or 0)
end

--★ penalty（生命惩罚）也同步：客户端 HUD 要画出「实际可用血量上限」的缺口。
local function onpenalty(self, penalty)
--★ 参见 components/health_replica.lua:63 SetPenalty ——
--   内部 assert(penalty >= 0 and penalty <= 1) 并做 ×200 定点化。
--   也就是说 penalty 的上界（0.75）由 tuning.lua:2161 保证，
--   而 replica 侧的 assert 是最后一道防线。
    self.inst.replica.health:SetPenalty(penalty)
end

--★ canmurder / canheal 走 tag 而非 netvar（见 health_replica.lua:192-214），
--   因为它们本质是「能力开关」，客户端多处逻辑（含 UI）都要按 tag 快速判断。
local function oncanmurder(self, canmurder)
    self.inst.replica.health:SetCanMurder(canmurder)
end

local function oncanheal(self, canheal)
    self.inst.replica.health:SetCanHeal(canheal)
end

--★★【只在作弊开启时生效】invincible 的 tag 下发被 CHEATS_ENABLED 包住。
--   理由：这是调试可视化，不允许在正常对局里给实体留下「无敌」痕迹
--   （tag 会被客户端逻辑读到，可能被用来判断该不该攻击）。
--   ★ 与 SetInvincible 不同：SetInvincible 无条件 PushEvent，但 tag 仍然
--     只在作弊模式下挂——事件给服务端逻辑用，tag 给客户端逻辑用。
local function oninvincible(self, invincible)
    if CHEATS_ENABLED then --use this to visualize godmode on the client
        if invincible then
            self.inst:AddTag("invincible")
        else
            self.inst:RemoveTag("invincible")
        end
    end
end

--★★★【Health 类的构造：全部状态字段的初始化清单】
--   这个类只有一个构造函数，第二个参数 base=nil 表示不继承任何类，
--   第三个参数是「属性 setter 表」——参见 class.lua:82 的 Class() 实现：
--   一旦传入 props，类的 __index/__newindex 就换成 __index/__newindex 函数，
--   于是 `self.currenthealth = x` 会走 class.lua 的 setter 表派发。
--   ★★★ 这是 DST 组件类的通用范式：构造函数只做数据初始化，
--     「字段变化 → 副作用」的绑定交给 props 表声明式描述。
--★★ 参见 class.lua:82 Class(base, _ctor, props) —— 本行是 Class 的第一个实参（构造器），
--   第二个实参 nil 表示「不继承任何基类」，所以 Health 是独立类（不是 StandardEntity 的子类）。
--   class.lua:75 removesetter 是客户端分支用来摘除 setter 的函数。
local Health = Class(function(self, inst)
    self.inst = inst
--★ 默认上限 100。注意这是**未扣 penalty** 的裸上限；实际可用上限由
--   GetMaxWithPenalty() 现算，参见 524 行。
    self.maxhealth = 100
--★ minhealth 是「血量地板」，默认 0。注意语义：设成正数可以让实体
--   永远不掉到 0 以下（不会死），同时 SetVal 会 PushEvent("minhealth")。
    self.minhealth = 0
    self.currenthealth = self.maxhealth
    self.invincible = false

--★★【被删掉的字段与「注释即墓碑」惯例】
--   这段注释揭示了一条重要的工作流：Klei 把一些字段从构造函数里删掉
--   （改为「读不到就当默认值」），但保留注释作为记忆，
--   因为老模组可能还在写 self.vulnerabletoheatdamage。
--   ★ 关键：`self.vulnerabletoheatdamage` 现在默认 nil，代码里按 nil→true 解释，
--     所以老模组写 false 依然有效，写 true 也有效，删掉也有效。
--   ⚠ 强类型移植时无法表达这种「nil 即 true」的语义，必须补默认值。
    --V2C: Not used at all, but who knows about MODs?
    --     Save memory instead by making nil default to true
    --self.vulnerabletoheatdamage = true
    -----

    self.takingfiredamage = false
    self.takingfiredamagetime = 0
    --self.takingfiredamagelow = nil
	--self.lunarburns = nil
	--self.lunarburnflags = nil
	--self.lastlunarburnpulsetick = nil
--★ 火焰伤害总倍率 = fire_damage_scale（基础） × externalfiredamagemultipliers（外部，multiply）
--   × burnable 的受控燃烧伤害倍率。三者相乘，见 190 行 GetFireDamageScale。
    self.fire_damage_scale = 1
--★ 参见 util/sourcemodifierlist.lua:60 SetModifier(source, m, key) ——
--   本行用默认 multiply 语义（火焰倍率相乘），与 92/93 行的 additive 区分。
    self.externalfiredamagemultipliers = SourceModifierList(inst)
--★ fire_timestart = 1：刚着火后的 1 秒内不结算伤害（只有低伤特效）。
--   设计意图是「点燃有前摇」，避免擦到火就秒杀。
    self.fire_timestart = 1
--★★【每秒火焰伤害上限的计数器】firedamageinlastsecond 累加本秒内已造成的火焰伤害，
--   超过 TUNING.MAX_FIRE_DAMAGE_PER_SECOND(=120) 就截断。
--   设计意图：防止「站在大火里」在一秒内被瞬秒，火焰必须是可逃离的持续压力。
--   firedamagecaptimer 是「本秒窗口的到期时刻」（下一个整秒）。
    self.firedamageinlastsecond = 0
    self.firedamagecaptimer = 0
    self.nofadeout = false
    self.penalty = 0
--★ disable_penalty 来自 TUNING.HEALTH_PENALTY_ENABLED（默认 true）。
--   难度/世界设置可以整体关掉生命惩罚系统（山庄难度、战败标记等）。
    self.disable_penalty = not TUNING.HEALTH_PENALTY_ENABLED

--★★★【已废弃字段与新机制的对照 —— 移植必读的 nil 陷阱源头】
--   absorb / playerabsorb 是一代减伤机制：直接写一个 0~1 的比例，
--   在 DoDelta 里做 `amount * (1 - absorb)`。
--   ★ 为什么废弃？因为它是**全局无来源的**，无法区分「谁给的减伤」，
--     也就无法在来源实体死亡时自动回收。二代 externalabsorbmodifiers
--     用 SourceModifierList 解决了这一点（见 92 行）。
--   ⚠⚠ 但旧字段**并未被删除**，628 行仍在读它们——这意味着：
--      只要调用过 SetAbsorptionAmount，行为就会与新机制叠加。
--      强类型移植时若把 absorb 声明成「必填非空 float」并给默认值 0，
--      语义恰好等价；但若声明成 Optional 且忘了初始化，
--      628 行的 `self.absorb` 就会是 nil，参与 `1 - (nil or ...)` 运算直接崩。
--      ★ 这正是本项目 bug-patterns.md 收录的「护甲 nil 吸收率」坑的根因。
    self.absorb = 0 -- DEPRECATED, please use externalabsorbmodifiers instead
    self.playerabsorb = 0 -- DEPRECATED, please use externalabsorbmodifiers instead

--★★【externalabsorbmodifiers：二代百分比减伤】
--   SourceModifierList(inst, 0, additive) 的三个参数含义：
--     · inst        —— 归属实体，用于自动注册 onremove 清理
--     · base_value=0—— 基值 0（注意不是默认的 1！），
--                      因为这里存的是「吸收率」而非「倍率」，0 才是无吸收
--     · fn=additive —— 多个来源用**加法**合并（吸收率相加），而非乘法。
--   ★★ 语义：Get() 返回累计吸收率 p（0~1+），实际伤害 × (1 - p)。
--     调用方示例：prefabs/foodbuffs.lua:7（BUFF_PLAYERABSORPTION_MODIFIER = 1/3，
--     即「伤害减少三分之一」，这与玩家直觉的「+33% 防御」同义，
--     但在数值上是减法语义，不是 1/1.33 的乘法规避——误差更小。
--★★ 参见 util/sourcemodifierlist.lua:8 SourceModifierList 构造签名
--   `Class(function(self, inst, base_value, fn, dirtycb)`。
--   util/sourcemodifierlist.lua:28 是 multiply（默认），:32 是 additive（本文件用后者），
--   :36 是 boolean。util/sourcemodifierlist.lua:60 SetModifier 内部会为实体来源
--   自动注册 onremove 清理，:46 RecalculateModifier 是重算入口。
    self.externalabsorbmodifiers = SourceModifierList(inst, 0, SourceModifierList.additive)
--★★【externalreductionmodifiers：三代「固定值减免」】
--   同样是 additive、基值 0，但语义完全不同：Get() 返回一个**绝对血量**，
--   在 DoDelta 里直接从 amount 里减掉。
--   调用方示例：prefabs/ghostly_elixirs.lua:235 的幽灵药剂护盾，
--   TUNING.GHOSTLYELIXIR_PLAYER_SHIELD_REDUCTION = 50（一次性免 50 点伤害）。
--   ★★ 三代机制的设计动机逐层递进：
--     一代 absorb          —— 无来源、无法回收（已废弃）
--     二代 externalabsorb  —— 有来源、百分比、有回收
--     三代 externalreduction—— 有来源、固定值、有回收，为「一次性的巨大打击缓冲」
--   ⚠⚠ 已知缺陷：三代在 health.lua:629 的应用方式有 bug，见该行注释。
    self.externalreductionmodifiers = SourceModifierList(inst, 0, SourceModifierList.additive)    

--★ destroytime：尸体（不 fadeout 的实体）延迟销毁时间。nil 时 SetVal 里用 2 秒。
    self.destroytime = nil
--★ canmurder / canheal 默认全开；由 specific prefab 关闭。
--   canmurder=false 的实体（如友方雕像）不能被玩家攻击致死。
    self.canmurder = true
    self.canheal = true

--★★★【非致死保护三兄弟：nonlethal_temperature / nonlethal_hunger / nonlethal_pct】
--   这是「保底不死」机制，DoDelta 的第一条判定就用它们（见 616 行）。
--   语义：血量百分比低于 nonlethal_pct 时，如果伤害来源是 temperature 或 hunger，
--        则完全免疫该次伤害。
--   ★ 设计意图：这是 DST 送给「已经快饿死/冻死」的玩家的一条活路，
--     避免玩家在准备不足时被环境直接秒杀而毫无补救机会。
--     对应 UI 上的「致命温度/致命饥饿」提示阈值。
--   ⚠ 但 TUNING.NONLETHAL_TEMPERATURE / NONLETHAL_HUNGER 默认是 **false**，
--     即该保护默认关闭；NONLETHAL_PERCENT 默认 0.2（20%）。
--     也就是说：**代码路径存在但默认不生效**，只有开了对应世界设置才会免疫。
    self.nonlethal_temperature = TUNING.NONLETHAL_TEMPERATURE
    self.nonlethal_hunger = TUNING.NONLETHAL_HUNGER
    self.nonlethal_pct = TUNING.NONLETHAL_PERCENT
end,
nil,
--★★【属性 setter 表】与构造函数第三参数配对。参见 class.lua:82-105：
--   传入 props 后，Class() 会为每个实例建 obj._ = { key = { 原值, setterfn } }，
--   并把 __newindex 指向 class.lua 的 __newindex，实现「赋值即回调」。
--   ★ 由此得到一条铁律：给 currenthealth 赋值**永远不会失败**，
--     但会同步触发网络写入与战斗阈值重算——热路径上要避免无谓赋值。
--★★ 参见 class.lua:82 中 `if props ~= nil then c.__index = __index; c.__newindex = __newindex`
--   —— 传入 props 才会启用属性 setter 派发。
--   class.lua:64 addsetter 是运行期追加 setter 的接口。
{
    maxhealth = onmaxhealth,
    currenthealth = oncurrenthealth,
    takingfiredamage = ontakingfiredamage,
    takingfiredamagelow = ontakingfiredamagelow,
	lunarburnflags = onlunarburnflags,
    penalty = onpenalty,
    canmurder = oncanmurder,
    canheal = oncanheal,
    invincible = oninvincible,
})

--★★【OnRemoveFromEntity：清理三类「自持资源」】
--   组件被移除时必须：① 停周期任务；② 摘掉所有事件监听；③ 清状态。
--   ★ 这里没做「停机前的最后一次结算」——任务被 Cancel 后不会再跑，
--     所以 regensources 里的回复是纯粹丢失的（不会补发）。
function Health:OnRemoveFromEntity()
--★ StopRegen 停的是「全局单例回复」（StartRegen 建的），
--   与下面的多来源回复（AddRegenSource 建的）不是同一套。
    self:StopRegen()

--★ 先判 nil 再遍历：regensources 是懒创建的（AddRegenSource 里才建表）。
    if self.regensources ~= nil then
        for source, _ in pairs(self.regensources) do
            self:RemoveRegenSource(source)
        end
    end

--★★【月光灼烧源的「自摘除」机制】
--   灼烧源若是实体，自动 ListenForEvent("onremove") 把自己摘掉。
--   ★ 为什么用 pairs 而不需要快照？因为 RemoveEventCallback 不改 regensources 表，
--     只改实体的事件表——Lua 的 pairs 遍历安全。
--   （对比 bug-patterns.md A6：那种危险来自「遍历中往同一张表增删 key」。）
	if self.lunarburns then
		for source in pairs(self.lunarburns) do
			if EntityScript.is_instance(source) then
				self.inst:RemoveEventCallback("onremove", self._onremovelunarburn, source)
			end
		end
		self.lunarburns = nil
		self.lunarburnflags = nil
		self.lastlunarburnpulsetick = nil
		self._onremovelunarburn = nil
--★ 显式 PushEvent("stoplunarburn")：因为摘除监听时不会有「最后一个源消失」的
--   语义事件，必须在这里手动补一个完整清理通知。
		self.inst:PushEvent("stoplunarburn")
	end

--★ 组件卸载也要重算一次战斗阈值——因为此刻 currenthealth 可能已被外部改过，
--   而 panic_thresh 的下游（逃跑 AI）还在按旧值决策。
    onpercent(self)
end

--★★【已废弃的空函数：函数签名保留是 ABI 兼容手段】
--   RecalculatePenalty 曾经负责「扣罚后重算上限」，现在被 GetMaxWithPenalty()
--   的「每次现算」取代了。但函数体保留为空并注明 deprecated，
--   ★ 目的是：老模组如果 override 或调用它，不会因为 nil 调用而崩。
--     这是重构时的通用做法——删函数容易，删函数会炸别人的模组。
--   ⚠ 强类型移植时若把空实现删掉，Lua 侧的 nil 调用会变成「方法不存在」错误。
function Health:RecalculatePenalty()
    --deprecated, keeping the function around so mods don't crash
end

--★★【SetInvincible 与 IsInvincible 的三源合流】
--   SetInvincible 只改字段 + 发事件；真正「无敌」还要看状态图标签。
--   为什么要分事件和字段两条路？见 486 行的 V2C 注释。
function Health:SetInvincible(val)
    self.invincible = val
--★ PushEvent("invincibletoggle", {invincible=val}) 供服务端逻辑响应；
--   客户端视觉（tag）由 oninvincible 在 CHEATS_ENABLED 下单独处理。
    self.inst:PushEvent("invincibletoggle", { invincible = val })
end

--★★★【ForceUpdateHUD：用「0 伤害」骗过整条 DoDelta 管线】
--   DoDelta(0, overtime, nil, true, nil, true) 的六个参数逐个看：
--     amount=0        —— 不改变血量，但仍然会走 SetVal → 触发 oncurrenthealth
--     overtime        —— 直接透传，区分「定时扣血」与「即时扣血」
--     cause=nil       —— 不给死亡原因（因为不会死）
--     ignore_invincible=true —— 无敌时也要刷新 HUD
--     afflicter=nil   —— 无施加者
--     ignore_absorb=true    —— 跳过护甲/减伤（虽然 amount=0 本来也无影响）
--   ★★ 设计精髓：**扣 0 点血当作「UI 刷新」的通用手段**。
--     这样就不必在 SetMaxHealth / SetPenalty / 读档 等十几个地方
--     各写一份「手动同步一遍 replica」的样板代码。
--   ⚠ 代价：会真的 PushEvent("healthdelta")，让所有监听者被唤醒一次。
--     所以热路径（如 DeltaPenalty 连续调用）要注意事件风暴。
function Health:ForceUpdateHUD(overtime)
    self:DoDelta(0, overtime, nil, true, nil, true)
end

--★★【OnSave：只存三样东西】
--   刻意**不存**的：regen（回复源）、lunarburns（月光灼烧）、
--   fire 状态、invincible。理由是这些都属于「临时状态」，读档后应重新建立。
--   ★ 设计判据：能重建的（回复源会被道具重新施加）不存；
--     重建不了的（invincible 是关卡脚本设的）由关卡 OnLoad 重新设置。
--★ 参见 entityscript.lua 的 GetSaveRecord / OnSave 约定 ——
--   组件的 OnSave 返回表会被合并进实体的存档记录。
function Health:OnSave()
    return
    {
        health = self.currenthealth,
--★ penalty 只在 > 0 时才写：避免大量实体的存档里出现 "penalty": 0 的噪音，
--   存档体积在 DST 里是真实成本（上千个实体时差异可观）。
        penalty = self.penalty > 0 and self.penalty or nil,
--★★ maxhealth 的条件保存：只有显式设过 save_maxhealth 的实体才写上限。
--   绝大多数实体上限就是 100，写进存档纯属冗余。
--   ★ save_maxhealth 标志由外部（通常是特定 prefab 的构造代码）设置，
--     health.lua 自己从不设它——所以这里只读不写。
		maxhealth = self.save_maxhealth and self.maxhealth or nil
    }
end

--★★【OnLoad：读档顺序有严格讲究】
--   ① maxhealth 必须**先**恢复——因为后面的 SetVal 要用 GetMaxWithPenalty() 封顶；
--   ② penalty 恢复时走 SetPenalty 而非直接赋值，以便触发副本同步；
--   ③ health / percent / penalty 三选一恢复，最后 ForceUpdateHUD 补一次同步。
--   ⚠ 关键陷阱：data.maxhealth 存在时，若没同时恢复 health，
--     实体会以构造函数给的 currenthealth=100 上限存档值可能出现矛盾。
--     实际不会发生，因为 OnSave 总是一起写这两个字段。
function Health:OnLoad(data)
	if data.maxhealth ~= nil then
		self.maxhealth = data.maxhealth
	end

--★★ haspenalty 的三重校验：非 nil、> 0、< 1。
--   ★ < 1 是防御性检查：TUNING.MAXIMUM_HEALTH_PENALTY = 0.75 已经封顶，
--     但存档可能被外部工具改坏；这里宁可忽略非法值也不让脏数据进来。
    local haspenalty = data.penalty ~= nil and data.penalty > 0 and data.penalty < 1
    if haspenalty then
        self:SetPenalty(data.penalty)
    end

    if data.invincible ~= nil then
        self.invincible = data.invincible
    end
    if data.health ~= nil then
--★ SetVal(data.health, "file_load")：cause 传固定字符串 "file_load"。
--   ★ 意义在于：死亡时若有残留的「致命伤害监听」，可以据此区分读档与真实伤害。
--     搜 prefabs 可找到监听 "file_load" 的地方。
        self:SetVal(data.health, "file_load")
        self:ForceUpdateHUD(true)
--★★★【percent 分支：专为 setpieces（关卡演出）保留】
--   英文原注释直接写了 "used for setpieces!"。
--   某些剧情 prefab 用 "percent" 字段表达「以百分比形式恢复血量」，
--   因为它们的 maxhealth 在运行期会被剧情改过，写绝对值不可靠。
--   ★ SetPercent 内部已含 ForceUpdateHUD，所以这里不能再调一次（否则事件翻倍）。
    elseif data.percent ~= nil then
        -- used for setpieces!
        -- SetPercent already calls ForceUpdateHUD
        self:SetPercent(data.percent, true, "file_load")
--★ 只有 penalty 被恢复（血量本身没变）时，也要刷新一次 HUD——
--   因为 penalty 改变了「可用上限」，血条缺口必须重画。
    elseif haspenalty then
        self:ForceUpdateHUD(true)
    end
end

--★ FIRE_TIMEOUT = 0.5 秒：最后一次火焰伤害后 0.5 秒才判定「火焰已灭」。
--   为什么要延迟？因为 DoFireDamage 会被高频调用（站在火里每帧调用），
--   若立即判定熄灭，takingfiredamage 会疯狂翻转，netvar 每帧变一次，
--   客户端特效会疯狂重播。0.5 秒的迟滞窗口是必需的防抖。
local FIRE_TIMEOUT = .5

--★★★【GetFireDamageScale：火焰伤害倍率的唯一读取点】
--   三项相乘，缺一不可：
--     ① self.fire_damage_scale            —— 实体自身的基础倍率
--     ② externalfiredamagemultipliers:Get() —— 外部倍率（multiply 语义，基值 1）
--     ③ burnable:GetControlledBurn().damage —— 「受控燃烧」伤害（如篝火被扑灭后余烬）
--   ★ 注意 ③ 的双重否定：只有 GetControlledBurn() 返回非 nil 才能取 .damage，
--     否则整个 `a and b and c.damage or 1` 短路到 1。
--     这是 Lua 的经典「and/or 三元」写法，也是它最容易出错的地方：
--     若 c.damage 恰为 0 或 false，表达式会错误地返回 1。
--   ⚠ 强类型移植时这行是最危险的：`controlledburn.damage == 0` 会走到 `or 1`，
--     导致「受控燃烧 0 伤害」被误判成「倍率 1」。必须改写成显式三段 if。
function Health:GetFireDamageScale()
    return self.fire_damage_scale * self.externalfiredamagemultipliers:Get() * (self.inst.components.burnable and self.inst.components.burnable:GetControlledBurn() and self.inst.components.burnable:GetControlledBurn().damage or 1)
end

--★★【DoFireDamage：火焰伤害的状态机入口】
--   被 burnable / burning / explosive 等组件在着火期间持续调用。
--   整体分三段：① 状态转换（点燃 / 进入低伤阶段）；② 结算本次伤害；③ 事件派发。
--   ★ 三条出口条件互不相同，移植时最容易漏：
--     · IsInvincible()  → 完全跳过（连 takingfiredamage 都不置位）
--     · not instant 且 mult <= 0 → 进低伤阶段但不掉血（防燃烧护符「挡火但不灭火」）
--     · not instant 且 mult > 0  → 进低伤阶段，等 fire_timestart 秒后才真掉血
--★★ 参见 components/burnable.lua 的燃烧更新循环 —— 它是本函数的调用方之一。
--   火焰倍率的另一来源 burnable:GetControlledBurn() 定义在 components/burnable.lua。
function Health:DoFireDamage(amount, doer, instant)
--★★【V2C 原注释】「not instant」通常意味着「正在燃烧，或正被点着」。
--   这是理解整个火焰系统的钥匙：instant = 一次性火焰伤害（如爆炸点燃的瞬时火）；
--   非 instant = 持续燃烧。二者走的是同一条 DoDelta 路径，但时序判定不同。
    --V2C: "not instant" generally means that we are burning or being set on fire at the same time
    local mult = self:GetFireDamageScale()
--★★ 双条件 `(not instant or mult > 0)` 的含义：
--   · instant=true  → 只要没无敌就处理（哪怕 mult<=0，也要走状态转换去「灭火」）
--   · instant=false → 只有 mult>0 才处理
--   ★ 这样设计是为了让「火焰抗性护符」（mult 变 0）能够**立即中断**燃烧：
--     走进火里 → 触发低伤阶段 → 之后 mult 被护符压到 0 → 走 elseif 分支停伤。
    if not self:IsInvincible() and (not instant or mult > 0) then
        local time = GetTime()
--★ 进入火焰状态只在「第一次」时执行（if not self.takingfiredamage）。
--   状态转换只发生一次，后续每帧调用只走结算段——这是每帧热路径的优化。
        if not self.takingfiredamage then
            self.takingfiredamage = true
            self.takingfiredamagestarttime = time
--★★★【低伤阶段的两种进入条件】
--   ① `self.fire_timestart > 1 and not instant`：fire_timestart 默认 1，
--      所以**默认情况下这个条件为假**——即正常点燃时不会进低伤阶段。
--   ② `mult <= 0`：火焰抗性把伤害压到 0，此时进低伤阶段（还在烧，但不掉血）。
--   ★ 条件①存在的意义是给「自定义点燃延迟」的具体物留出口：
--     某个 prefab 把 fire_timestart 设成 2，就会得到「着火后前 2 秒只冒烟不掉血」。
--   ⚠ 陷阱：takingfiredamagelow 在 203 行被设为 **true**（不是 false），
--     在 215/247 行被设为 **nil**。true/nil 混用是有意的：
--     nil 表示「这个维度不适用」，见 32 行 ontakingfiredamagelow 的 == true 归一化。
            if (self.fire_timestart > 1 and not instant) or mult <= 0 then
                self.takingfiredamagelow = true
            end
--★ StartUpdatingComponent 把组件加进每帧更新队列——
--   注意这个队列在 update.lua 的 NewUpdatingEnts 里，参见 update.lua:270。
--   ★ 实体休眠（IsAsleep）时 StartUpdatingComponent 会被跳过，
--     所以火焰状态在休眠实体上「冻结」；OnEntityWake 时不会自动续上，
--     要靠 DoFireDamage 被再次调用（burnable 的更新）来恢复。
            self.inst:StartUpdatingComponent(self)
            self.inst:PushEvent("startfiredamage", { low = self.takingfiredamagelow })
--★ ProfileStatsAdd("onfire")：遥测埋点，用于统计「有多少实体曾着火」。
--   ★ 这类 Profile* 调用是性能分析基础设施，正式构建里是空函数。
            ProfileStatsAdd("onfire")
        end

--★ lastfiredamagetime 每帧都刷——它是 OnUpdate 里「火焰熄灭」判定的唯一依据。
        self.lastfiredamagetime = time

--★★★【真正掉血的时间闸门】`(instant or 已燃烧超过 fire_timestart 秒) and amount > 0`
--   ★ 这行是「点燃前摇」的实现：非 instant 时必须熬过 fire_timestart 秒。
--     结合 202 行的低伤阶段，形成完整的时序：
--       0s 点燃 → [可能进低伤阶段] → 前摇期不掉血 → fire_timestart 秒后开始掉血
--   ⚠ 注意 `amount > 0` 意味着「0 伤害的火焰」永远不会触发结算分支，
--     因此也不会走到 233 行把 takingfiredamagelow 置 true 的逻辑——
--     也就是说 amount=0 的调用会让状态永久停在「非低伤」阶段。
        if (instant or time - self.takingfiredamagestarttime > self.fire_timestart) and amount > 0 then
            if mult > 0 then
--★ 低伤阶段退出：真实伤害开始前，先把 low 标志清掉并广播，
--   让客户端把弱特效切换成强特效。
                if self.takingfiredamagelow then
                    self.takingfiredamagelow = nil
                    self.inst:PushEvent("changefiredamage", { low = false })
                end

                --We're going to take damage at this point, so make sure it's not over the cap/second
--★★【每秒上限的滑动窗口】`if self.firedamagecaptimer <= time then`
--   firedamagecaptimer 初值 0，time 是 GetTime()（大数），
--   所以第一次进来必然重置。这就是「每秒 120 点」窗口的实现。
--   ★ 窗口是「硬切」的（不是滑动窗口），所以理论上 1.0s 内可造成 240 点：
--     前一秒末尾 120 + 后一秒开头 120。属于有意为之的宽松设计。
                if self.firedamagecaptimer <= time then
                    self.firedamageinlastsecond = 0
                    self.firedamagecaptimer = time + 1
                end

--★★【每���伤害截断】amount 被压到「本秒剩余配额」。
--   如果本秒配额已用尽，amount 会变成 0 甚至负数：
--   若 firedamageinlastsecond 恰好等于 120，则 amount = 0；
--   ⚠ 若因浮点误差导致 firedamageinlastsecond > 120，amount 变负数，
--     下一行 -amount * mult 变成**正数**，即「火焰治疗玩家」！
--     实际发生概率极低（需要 120 被精确命中），但这是真实的理论缺陷。
--     防御只需把 226 行的结果再 math.max(..., 0) 一次。
                if self.firedamageinlastsecond + amount > TUNING.MAX_FIRE_DAMAGE_PER_SECOND then
                    amount = TUNING.MAX_FIRE_DAMAGE_PER_SECOND - self.firedamageinlastsecond
                end

--★★★【火焰伤害的 DoDelta 调用形态 —— 五个参数里有三个非常规】
--   `self:DoDelta(-amount * mult, false, <cause 字符串>, nil, doer)`
--     amount = -amount * mult —— 负号在内、倍率在外，注意运算顺序
--     overtime = false       —— 火焰是「持续状态」而非「一次性伤害」，
--                                所以 overtime=false 让下游能区分
--     cause = 字符串          —— doer 的 nameoverride 或 prefab 名；没有 doer 时是 "fire"
--                                ★ 用字符串而非实体，是为了让存档/统计有稳定可读的 key
--     ignore_invincible = nil —— 遵守无敌状态（上面 197 行已判过，此处是双保险）
--     afflicter = doer       —— ★ 唯一传实体的参数：这个**施加者**
--   ★★ afflicter 与 cause 的分工是 DoDelta 的核心设计：
--     cause  = 「伤害的类型标签」，进 healthdelta 事件、决定死亡原因文案
--     afflicter = 「谁造成的」，决定能否享受 playerabsorb、
--                能否触发 externalreduction、能否被计入击杀统计
--   ⚠ 常见误用：用实体当 cause（如 cookiecutterdrill.lua:46 传了 self.inst），
--     会让 cause 变成 Entity 对象而非字符串，下游做字符串比较的逻辑会失效。
--★★ 对比 components/combat.lua:653 的 DoDelta 调用：
--   那里是 `DoDelta(-damage, nil, cause_name, nil, cause)` ——
--   刻意把 cause 放字符串、afflicter 放实体，与本行完全同构。
--   ★ 这是全文件最值得模仿的调用范式。
                self:DoDelta(-amount * mult, false, doer ~= nil and (doer.nameoverride or doer.prefab) or "fire", nil, doer)
--★ "firedamage" 事件在每次结算后派发，供「火焰伤害统计」「受击特效」等监听。
                self.inst:PushEvent("firedamage")

--★ 累加的是「未乘倍率」的 amount —— 因为上面 225 行已经把 amount 截断成配额，
--   而 229 行才乘 mult。所以配额统计的是「原始伤害额度」而非实际掉血。
--   ★ 意图：上限针对的是「火焰的原始威胁」，与抗性无关——
--     抗性应该由 mult 单独承担，两条机制互不干扰。
                self.firedamageinlastsecond = self.firedamageinlastsecond + amount
--★ mult<=0 的镜像分支：进低伤阶段但不结算。
--   与 212 行的进入条件配对，构成「进低伤 ↔ 出低伤」的双向状态机。
            elseif not self.takingfiredamagelow then
                self.takingfiredamagelow = true
                self.inst:PushEvent("changefiredamage", { low = true })
            end
        end
    end
end

--★★【OnUpdate：火焰熄灭的迟滞判定】只有这一个用途，
--   而它需要占一个每帧更新槽位——这是「用帧循环换迟滞逻辑」的代价。
function Health:OnUpdate(dt)
    local time = GetTime()

--★★ 迟滞判定的唯一条件：距最后一次火焰伤害调用超过 0.5 秒。
--   ★ 之所以能这样简化：DoFireDamage 每帧被调用时都会刷 lastfiredamagetime，
--     所以「不再被调用」等价于「调用间隔超过 0.5 秒」。
--   ⚠ 副作用：如果某个 burnable 因为自身逻辑停了更新（不再调 DoFireDamage），
--     实体会在 0.5 秒内「自动熄灭」——即使视觉上还在烧。
    if time - self.lastfiredamagetime > FIRE_TIMEOUT then
--★ 先清 takingfiredamage 再清 low，顺序有意义：
--   takingfiredamage=false 时 takingfiredamagelow 还短暂为 true，
--   但因为二者分别 netvar，客户端会在同一帧内都收到，无中间态。
        self.takingfiredamage = false
        if self.takingfiredamagelow then
            self.takingfiredamagelow = nil
        end
--★ 主动退出更新队列——不这么做的话，每帧都会空跑这个函数。
--   ★ 这是 health.lua 里唯一的每帧更新点，火焰熄灭后立刻归零，开销为零。
        self.inst:StopUpdatingComponent(self)
        self.inst:PushEvent("stopfiredamage")
        ProfileStatsAdd("fireout")
    end
end

--★ 月光灼烧标志的读取包装，nil 安全。
function Health:GetLunarBurnFlags()
	return self.lunarburnflags or 0
end

--★★【CalcLunarBurnFlags：位或归约】
--   把所有来源的 flags 按位或起来。bit.bor 是 DST 注入的位运算库提供的。
--   ★ 为什么用位或而不是加法？因为位标志要求「同时具备所有效果」时
--     客户端能按位判断出是哪几种。相加会破坏这个性质。
--   ⚠ 无参调用保护：这里直接遍历 self.lunarburns，
--     而 RegisterLunarBurnSource 的第一个分支会把它置为非 nil，
--     所以实际调用总是安全的——但作为公开方法它缺一个 nil 守卫。
function Health:CalcLunarBurnFlags()
	local flags = 0
	for k, v in pairs(self.lunarburns) do
		flags = bit.bor(flags, v)
	end
	return flags
end

--★★★【RegisterLunarBurnSource：灼烧源注册（三个分支）】
--   分支 1：第一个源 → 建表、存 flags、注册 onremove 自摘、广播开始事件
--   分支 2：已存在的源且 flags 变了 → 更新后重算总标志，有变化才广播
--   分支 3（隐含）：已存在的源且 flags 没变 → 什么都不做
--   ★ 设计要点：**只在「总标志」变化时才广播事件**。
--     这样两个源叠加（A 消失）时，客户端不会收到无意义的更新。
function Health:RegisterLunarBurnSource(source, flags)
--★ 懒建表：lunarburns 为 nil 说明「还没有任何源」，是分支判定的依据。
	if self.lunarburns == nil then
--★ _onremovelunarburn 只创建一次并被所有源共享——避免每个源都建一个闭包。
		self._onremovelunarburn = function(src) self:UnregisterLunarBurnSource(src) end
		self.lunarburns = { [source] = flags }
		self.lunarburnflags = flags
		if EntityScript.is_instance(source) then
			self.inst:ListenForEvent("onremove", self._onremovelunarburn, source)
		end
--★★【`if flags ~= 0` 才广播 startlunarburn】
--   第一个源注册时如果 flags=0（无灼烧），静默初始化、不广播。
--   ★ 这是「注册」与「生效」的分离：注册只是建立跟踪，
--     只有非零标志才代表真的有灼烧效果。
		if flags ~= 0 then
			self.inst:PushEvent("startlunarburn", flags)
		end
--★ flags 变化才进分支——避免每帧调 RegisterLunarBurnSource 造成的写放大。
	elseif self.lunarburns[source] ~= flags then
		if self.lunarburns[source] == nil and EntityScript.is_instance(source) then
			self.inst:ListenForEvent("onremove", self._onremovelunarburn, source)
		end
		self.lunarburns[source] = flags
		flags = self:CalcLunarBurnFlags()
		if flags ~= self.lunarburnflags then
--★ 被注释掉的 assert(flags ~= 0)：
--   说明曾怀疑「startlunarburn 事件不应带 0 标志」，但发现有合法路径会推 0
--   （所有源的 flags 都是 0 时总标志为 0），于是放弃了这个断言。
			--assert(flags ~= 0)
			self.lunarburnflags = flags
			self.inst:PushEvent("startlunarburn", flags)
		end
	end
end

--★ UnregisterLunarBurnSource 用 `self.lunarburns[source]` 双重判空，
--   既保证源存在也保证它的 flags 非零/非 nil。
function Health:UnregisterLunarBurnSource(source)
	if self.lunarburns and self.lunarburns[source] then
		if EntityScript.is_instance(source) then
			self.inst:RemoveEventCallback("onremove", self._onremovelunarburn, source)
		end
		self.lunarburns[source] = nil
--★★【`next(self.lunarburns) == nil` —— 最后一个源被摘除的判定】
--   摘完后表变空，就该整体清理并广播 stoplunarburn。
--   ★ 与 RegisterLunarBurnSource 的「懒建表」严格配对：
--     nil ↔ 空 ↔ nil，两个方向都不会留下半初始化状态。
		if next(self.lunarburns) == nil then
			self.lunarburns = nil
			self.lunarburnflags = nil
			self.lastlunarburnpulsetick = nil
			self._onremovelunarburn = nil
			self.inst:PushEvent("stoplunarburn")
		else
--★ 源还在但总标志变了：重算并按是否为零分别广播 start / stop。
			local flags = self:CalcLunarBurnFlags()
			if flags ~= self.lunarburnflags then
				self.lunarburnflags = flags
				if flags ~= 0 then
					self.inst:PushEvent("startlunarburn", flags)
--★ 归零时推 stoplunarburn 而不是 startlunarburn(0)，
--   与 RegisterLunarBurnSource:276 的「0 标志不广播」形成一致约定。
				else
					self.inst:PushEvent("stoplunarburn")
				end
			end
		end
	end
end

--★ DoRegen 是周期任务的回调。第一个参数 inst 是 DoPeriodicTask 的约定，
--   第二个 self 是构造时传的 param。
local function DoRegen(inst, self)
    --print(string.format("Health:DoRegen ^%.2g/%.2fs", self.regen.amount, self.regen.period))
--★★【回复不作用于死人】`if not self:IsDead()`。
--   ★ 为什么要判？因为 DoRegen 是周期任务，若实体在死亡到移除之间还活着，
--     周期任务会继续触发并把「负血量往上加」——那会触发假死亡逻辑。
--   ★ 这是「周期任务必须自己判断有效性」的典型；health.lua 里三处 regen 都这么做。
    if not self:IsDead() then
--★ `DoDelta(amount, true, "regen")` —— 注意 overtime=true！
--   ★★★ 语义：回复是「定时」的持续恢复，标记为 overtime 后，
--     下游（连杀奖励、血条动画、音效节流）会知道这是缓慢回复而非战斗行为。
--   ★★ 同时「regen」作为 cause 字符串，会出现在 healthdelta 事件的 cause 字段里，
--     供「谁在给我回血」的 UI 提示使用。
        self:DoDelta(self.regen.amount, true, "regen")
    --else
        --print("    can't regen from dead!")
    end
end

--★★★【Klei 工程师 DiogoW 的公开建议】
--   "Consider using Health:AddRegenSource, specially for players."
--   为什么专门提玩家？因为 StartRegen 是**单例**的——
--   任何新调用都会覆盖掉旧的回复（见 interruptcurrentregen）。
--   玩家身上可能同时挂着多种回复（食物、装备、队友技能），
--   单例模型根本装不下，所以才有 AddRegenSource 的多源模型。
-- NOTES(DiogoW): Consider using Health:AddRegenSource, specially for players.
--★★【StartRegen：单例回复，带一个纯粹为兼容而加的第三参数】
--   原始英文注释把「为什么加这个参数」说得非常清楚：
--   有些模组依赖「StartRegen 不打断已有任务」的老行为；
--   现在默认改成「重启任务」，想让老模组维持原状只需传 false。
--   ★★★ 这是向后兼容的教科书案例：改变默认行为时，
--     不删参数、不报错，而是加一个「回到旧行为」的开关。
--   ⚠ 强类型移植时这个「可选布尔 + 语义翻转」的约定极易丢失。
function Health:StartRegen(amount, period, interruptcurrentregen)
    -- We don't always do this just for backwards compatibility sake. While unlikely, it's possible some modder was previously relying on
    -- the fact that StartRegen didn't stop the existing task. If they want to continue using that behavior, they now just need to add
    -- a "false" flag as the last parameter of their StartRegen call. Generally, we want to restart the task, though.
--★ `interruptcurrentregen ~= false` —— 判定写成了「不等于 false」而非「为真」，
--   所以 nil 也会走「打断」分支。这是刻意的：新增参数在旧调用点全是 nil，
--   必须让 nil 表现为新行为，否则等于没改。
    if interruptcurrentregen ~= false then
        self:StopRegen()
    end

--★ regen 表懒建，与 regensources 一样。但注意：StopRegen 会把 self.regen 置 nil，
--   所以「regen 存在」等价于「有一个活跃的全局回复」。
    if self.regen == nil then
        self.regen = {}
    end
    self.regen.amount = amount
    self.regen.period = period

--★★★【只有 task 为 nil 才建周期任务】这是本函数最关键的一行。
--   若 interruptcurrentregen == false（旧行为），此时 regen.task **已存在**，
--   于是：新的 amount / period 被写进 self.regen，但**周期任务本身不重建**——
--   任务捕获的是 DoRegen 闭包里的 self，self.regen.amount 会被读到新值，
--   但 period 仍是旧值。
--   ⚠⚠ 疑似缺陷：传 false 时 period 变更不生效，只有 amount 变更生效。
--     推理依据：DoPeriodicTask(self.regen.period, ...) 的 period 在建任务时固化，
--     回调里只读 self.regen.amount 而不读 period（见 318-325 行 DoRegen）。
--     若调用方以为「period 也更新了」，实际刷新频率仍是旧的。
    if self.regen.task == nil then
--★★ 周期任务的生命周期完全由 self.regen.task 持有。
--   一旦 self.regen 被置 nil 而 task 未 Cancel，任务就成了「孤儿」——
--   它仍会每 period 秒调 DoRegen，而 DoRegen 读 self.regen.amount 会崩溃。
--   所以 StopRegen（448 行）必须先 Cancel 再置 nil，顺序不能反。
        self.regen.task = self.inst:DoPeriodicTask(self.regen.period, DoRegen, nil, self)
    end
end

--★★【DoRegenFromSource：与 DoRegen 的唯一区别是 cause 带上 key】
--   `DoDelta(amount, true, "regen_"..key)` ——
--   ★ 设计意图：让 healthdelta 事件的 cause 字段能区分「哪种回复」。
--     UI / 音效 / 成就系统靠这个前缀识别「这是回复而非伤害」。
--   ★ key 由 AddRegenSource 的调用方传入，是回复来源的语义标识。
local function DoRegenFromSource(inst, self, amount, key)
    if not self:IsDead() then
        self:DoDelta(amount, true, "regen_"..key)
    end
end

--★★★【AddRegenSource：两级索引的来源表】
--   结构：self.regensources[source].tasks[key] = { task, amount, period }
--     外层 source —— 谁给的（可为实体，也可为任意字符串 key）
--     内层 key     —— 该来源内的哪一路回复（同一来源可有多路）
--   ★ 为什么需要两级？因为一个装备可能同时给「持续回血」和「回满时额外奖励」，
--     移除时也要能单独撤掉一路。这就是 key 参数存在的全部理由。
function Health:AddRegenSource(source, amount, period, key)
--★ key 默认 "key"：不传 key 时只有一路，直接用占位符。
    key = key or "key"

    if self.regensources == nil then
        self.regensources = {}
    end

--★ src_params 为 nil 判定「该来源首次注册」。
    local src_params = self.regensources[source]

    if src_params == nil then
--★ 注意任务创建时传的 param 是 (nil, self, amount, key) 四个参数——
--   DoPeriodicTask 的约定是 (fn, id, param...)，param 展开为回调实参，
--   再往前加 inst 作为隐式 self。所以 DoRegenFromSource(inst, self, amount, key)。
        self.regensources[source] = {
            tasks = { [key] = 
                {
                    task = self.inst:DoPeriodicTask(period, DoRegenFromSource, nil, self, amount, key),
                    amount = amount,
                    period = period,
                }
            }
        }

--★★★【来源是实体时，自动注册 onremove 清理】
--   这是 DST 的通用约定（util/sourcemodifierlist.lua 内部也是同一套）：
--   「凡是按实体索引的缓存，都必须能自摘除」，否则会引用已销毁的实体。
--   ★ 这条约定对应的 bug 模式收录在 bug-patterns.md 的 A7（事件监听未注销）。
--   ⚠ 强类型移植时若用弱引用或 GC 代替显式摘除，
--     会遇到「实体已销毁但缓存仍在」的逻辑错误——GC 只管内存，不管语义。
        -- If the source is an object, then add a onremove event listener to cleanup if source is removed from the game.
--★ EntityScript.is_instance 判定 source 是真实体还是字符串/数字。
--   ★ 这是移植陷阱：强类型语言没有「既是字符串又是实体」的动态类型，
--     必须把 source 显式建模成一个 sealed class / tagged union。
        if EntityScript.is_instance(source) then
--★ onremove 闭包捕获了 self 与 source（作为参数传入，不是闭包变量）——
--   ★★★ 这里很讲究：`onremove = function(source)` 的 source 是**回调实参**，
--     即被移除的那个实体，而不是闭包捕获的注册源 key。
--     两者可能不同（同一实体的 onremove 可能被多次触发），用实参更安全。
            self.regensources[source].onremove = function(source)
                for key, data in pairs(self.regensources[source].tasks) do
                    data.task:Cancel()
                end
                self.regensources[source] = nil
            end

            self.inst:ListenForEvent("onremove", self.regensources[source].onremove, source)
        end

--★ 已有该来源且已有该 key —— 进入「参数是否变化」的判定。
    elseif src_params.tasks[key] ~= nil then
        local data = src_params.tasks[key]

--★★★【参数未变则什么都不做】这是最重要的性能优化。
--   很多 prefab 会在每帧或每次事件里重复调用 AddRegenSource（参数相同），
--   若无条件 Cancel + 重建任务，会造成任务表剧烈抖动（协程池压力）。
--   ★ 这里的 `data.amount ~= amount or data.period ~= period` 短路判定
--     把「幂等调用」的成本降到两次比较。
        if data.amount ~= amount or data.period ~= period then
            data.task:Cancel()

--★ Cancel 旧任务 → 建新任务 → 回写参数。三步缺一不可，
--   少回写 data.amount/data.period 会导致下次调用误判「参数变了」而重复重建。
            data.task = self.inst:DoPeriodicTask(period, DoRegenFromSource, nil, self, amount, key)
            data.amount = amount
            data.period = period
        end

--★ else 分支：来源已存在但该 key 是新的 → 直接加一路任务，
--   不需要重算 onremove（外层已经有了）。
    else
        src_params.tasks[key] = 
        {
            task = self.inst:DoPeriodicTask(period, DoRegenFromSource, nil, self, amount, key),
            amount = amount,
            period = period,
        }
    end
end

--★ 英文原注释：key 可选，不传就移除整个来源。
-- Key is optional if you want to remove the entire source.
--★★★【RemoveRegenSource：两段式移除】
--   传 key → 移除该来源的某一路；剩余还有路就提前返回
--   不传 key（或该来源的路已全部移除）→ 移除整个来源（含 onremove 监听）
function Health:RemoveRegenSource(source, key)
--★ `self.regensources ~= nil and self.regensources[source] or nil` ——
--   双重 nil 安全的链式写法。移除操作**必须可重入**：
--   ★ 典型场景是 onremove 自摘除与外部显式移除撞车，
--     此时第二次调用会看到 nil 并安静返回，不会崩。
    local src_params = self.regensources ~= nil and self.regensources[source] or nil

    if src_params == nil then
        return
    
    elseif key ~= nil then
--★★⚠【疑似缺陷：未判 src_params.tasks[key] 是否存在】
--   `src_params.tasks[key].task:Cancel()` 直接下钻两层。
--   推理依据：上面 413 只判了 `key ~= nil`，没判 `src_params.tasks[key] ~= nil`。
--     若调用方传了一个不存在的 key（例如来源已换过 key 命名），
--     在 Lua 里会得到 "attempt to index a nil value" 的运行时错误。
--   对比 385 行的同类代码（`elseif src_params.tasks[key] ~= nil`）——
--     那里做了判定，这里没有，属明显的不一致。
--   ★ 正确写法应是 `local d = src_params.tasks[key]; if d ~= nil then d.task:Cancel() end`。
        src_params.tasks[key].task:Cancel()
        src_params.tasks[key] = nil

--★ 提前返回：这一路还有别的 key，不该拆掉整个来源。
        if next(src_params.tasks) ~= nil then
            -- This source still has other keys.

            return
        end
    end

    -- Remove the entire source.
--★ 拆来源时必须反注册 onremove，否则 self.regensources 里会残留指向已死实体的闭包。
    if src_params.onremove ~= nil then
        self.inst:RemoveEventCallback("onremove", src_params.onremove, source)
    end

    for key, data in pairs(self.regensources[source].tasks) do
        data.task:Cancel()
    end

    self.regensources[source] = nil

--★ 表空了就把整个 self.regensources 置 nil —— 与「懒建」配对，避免空表驻留。
    if not next(self.regensources) then
        self.regensources = nil
    end
end

--★ SetAbsorptionAmount 写的是一代字段 absorb（已废弃但仍生效，见 89 行）。
--   ★ 实际使用方：alterguardian_phase1.lua（守卫者阶段一护盾）、
--     toadstool.lua（蟾蜍蛙按等级吸收酸雨）、wathgrithr.lua、
--     woodie.lua（海狸/沃勒摩斯形态）、fence.lua（栅栏完全免疫）。
--     共同特征：都是「按形态/状态整体改一次」的减伤，
--     不需要按来源分别回收——所以留在旧字段上反而合适。
function Health:SetAbsorptionAmount(amount)
    self.absorb = amount
end

--★ playerabsorb 是「仅对玩家攻击者生效」的吸收率。
--   唯一使用方：prefabs/walls.lua:347 的 playerdamagemod（墙的世界设置减伤）。
--   ★ 与 absorb 的区别在 DoDelta:628 的条件表达式里体现。
function Health:SetAbsorptionAmountFromPlayer(amount)
    self.playerabsorb = amount
end

--★★【StopRegen：必须先 Cancel 再置 nil】顺序即安全契约。
--   若先置 nil，孤儿任务会在下次触发时读 self.regen.amount 崩溃。
function Health:StopRegen()
    --print("Health:StopRegen")
    if self.regen ~= nil then
        if self.regen.task ~= nil then
--★ 奖励类道具（如某些食物的「治疗上限」）会读 GetPercentWithPenalty 来决定效果量。
            --print("   stopping task")
            self.regen.task:Cancel()
            self.regen.task = nil
        end
        self.regen = nil
    end
end

--★★【SetPenalty：生命惩罚的收敛点】
--   penalty 是「永久性降低可用血量上限」的比例，0 ~ TUNING.MAXIMUM_HEALTH_PENALTY(0.75)。
--   ★ 语义等价于「最大血量打折」：GetMaxWithPenalty() = maxhealth * (1 - penalty)。
--     所以 penalty=0.75 意味着只能用 25% 的血量上限。
--   ★ 游戏内表现：DST 的「战败标记」「灵魂jaar」等机制会施加惩罚，
--     用来制造「越死越弱」的心理压力与死亡螺旋。
function Health:SetPenalty(penalty)
    --print("Health:SetPenalty", self.disable_penalty)
--★ disable_penalty 短路：整个机制可由 TUNING.HEALTH_PENALTY_ENABLED 全局关闭，
--   而且是**静默关闭**（不发事件、不同步副本）。
--   ⚠ 移植陷阱：这一行让 SetPenalty 成为「可能什么都不做」的函数，
--     调用方不能假设赋值成功。强类型版本应显式返回 bool 表示是否生效。
	if not self.disable_penalty then
--★★ 英文原注释点明了硬边界：「Penalty should never be less than 0% or ever above 75%」
--   与 tuning.lua:2161 的 MAXIMUM_HEALTH_PENALTY = 0.75 一致。
--   ★ math.clamp 同时防住「负惩罚（变相加血）」和「超过 75%（回血）」。
		--Penalty should never be less than 0% or ever above 75%.
		self.penalty = math.clamp(penalty, 0, TUNING.MAXIMUM_HEALTH_PENALTY)
	end
end

--★★★【DeltaPenalty：惩罚的增量接口 + 立刻封顶】
--   `SetPenalty(self.penalty + delta)` 然后 `ForceUpdateHUD(false)`。
--   ★★ 为什么必须紧跟 ForceUpdateHUD？因为惩罚只改「上限」不改「当前血量」。
--     如果当前血量原本高于新的上限，SetPenalty 之后 currenthealth 可能 > 上限，
--     造成「血条溢出」和「IsHurt() 判定错误」。
--     ForceUpdateHUD 里的 DoDelta(0) → SetVal → 触发 572 行的封顶逻辑，
--     把 currenthealth 压回上限内。
--   ★ 这是「改上限必须连带收敛当前值」的通用套路，在 506 行 SetMaxHealth 也一样。
--   ⚠ ForceUpdateHUD 传的是 false（overtime=false），即视为「即时变化」而非定时变化。
--★ 外部施加生命惩罚的入口。搜 prefabs 可找到调用方（如各种战败标记相关实体）。
--   参见 tuning.lua:2161 MAXIMUM_HEALTH_PENALTY = 0.75。
function Health:DeltaPenalty(delta)
    self:SetPenalty(self.penalty + delta)
    self:ForceUpdateHUD(false) --handles capping health at max with penalty
end

function Health:GetPenaltyPercent()
    return self.penalty
end

--★ GetPercent 返回 0~1 的原始血量百分比，**不含惩罚**。
--   ★★ 对比 GetPercentWithPenalty（481 行）用 GetMaxWithPenalty 作分母。
--     两者在 penalty=0 时完全相同；有惩罚时前者会 > 1。
--   ★ 选择建议：UI 血条应该用 GetPercentWithPenalty（否则会画到超出槽外），
--     而「血量百分比」类逻辑（如 SetPercent 的入参语义）用 GetPercent。
function Health:GetPercent()
    return self.currenthealth / self.maxhealth
end

--★ GetPercentWithPenalty：分母换成「实际可用上限」。
--   ★ 客户端的对应实现在 health_replica.lua:80 MaxWithPenalty()，
--     用 `maxhealth * (1 - healthpenalty/200)` —— 惩罚值以 ×200 定点数同步（见 66 行），
--     因为 netvar 只支持整数。这是个典型的「网络带宽优先于精度」决策。
function Health:GetPercentWithPenalty()
    return self.currenthealth / self:GetMaxWithPenalty()
end

--★★★【IsInvincible：三源合流】
--   ① self.invincible 字段（SetInvincible 设置）
--   ② 状态图标签 "temp_invincible"（临时无敌，由具体 AI 状态图挂）
--   ★★ 为什么不把 ② 也做成字段？因为「临时无敌」是**状态图的一个状态**——
--     状态图进入/退出时会自动增删标签，天然带生命周期管理，无需手工清理。
--     这是「用状态图标签承载瞬时状态」的典范用法。
function Health:IsInvincible()
--★★★【V2C 注释解释了「为什么玩家不能只靠 temp_invincible」】
--   原文：don't use "temp_invincible" for players, since they also need to use
--   "invincibletoggle" event, which doesn't work with "temp_invincible".
--   ★★★ 翻译成人话：God Mode（作弊无敌）需要让**客户端知道**自己无敌了，
--     以便禁用攻击、显示心形特效等。而状态图标签只在服务端有意义，
--     且不触发 invincibletoggle 事件。所以玩家必须走 self.invincible 字段路径。
--   ★ 这条注释揭示了一条通用原则：**跨端可见的瞬时状态必须走 netvar 或 tag，
--     状态图标签只能用于服务端内部逻辑**。
	--V2C: don't use "temp_invincible" for players, since they also need to use
	--     "invincibletoggle" event, which doesn't work with "temp_invincible".
    return self.invincible or (self.inst.sg and self.inst.sg:HasStateTag("temp_invincible"))
end

--★ GetDebugString 给调试模式（长按 Debug 键）用，显示血量与回复配置。
function Health:GetDebugString()
    local s = string.format("%2.2f / %2.2f", self.currenthealth, self:GetMaxWithPenalty())
    if self.regen ~= nil then
        s = s..string.format(", regen %.2f every %.2fs", self.regen.amount, self.regen.period)
    end
    return s
end

--★★★【SetCurrentHealth：唯一的裸血量写入口，且不做任何夹取】
--   直接赋值 → 触发 oncurrenthealth（同步副本 + 通知 repairable + 战斗阈值）。
--   ⚠⚠ 但它**绕过了 SetVal 的全部封顶/地板逻辑**（572/576 行）。
--     所以 currenthealth 可以被设成 500（超过上限）或 -10（低于 0 而不死）。
--     唯一调用方是读档路径与外部强制设置，属于「信任调用方」的接口。
--   ⚠ 强类型移植建议：给这个方法改名 SetCurrentHealthUnclamped，
--     或强制内部走 SetVal，避免使用者误以为它是安全写入。
function Health:SetCurrentHealth(amount)
    self.currenthealth = amount
end

--★★★【SetMaxHealth：上限与当前值一起改，然后封顶】
--   `self.currenthealth = amount` 让血量直接等于新上限（满血），
--   再 ForceUpdateHUD(true) 触发 SetVal 走封顶逻辑。
--   ★★ 为什么要多这一次 ForceUpdateHUD？因为 SetPenalty 可能已生效，
--     「满血」应该是 GetMaxWithPenalty() 而不是 maxhealth。
--     直接赋 amount 会让 currenthealth 超过实际可用上限。
--   ⚠ 这里同时赋了 maxhealth 和 currenthealth，两个 setter 都会触发，
--     所以会产生两次 replica 写入（SetMax + SetCurrent）。可以优化但无害。
function Health:SetMaxHealth(amount)
    self.maxhealth = amount
    self.currenthealth = amount
    self:ForceUpdateHUD(true) --handles capping health at max with penalty
end

--★ SetMinHealth 设置血量地板。设成正数 = 该实体不会真正死亡。
--   ★ 实际用途：部分「不该死」的特殊实体，或剧情里锁血的单位。
function Health:SetMinHealth(amount)
    self.minhealth = amount
end

--★★★【SetMaxDamageTakenPerHit：单次伤害上限，符号取负是刻意的存储技巧】
--   传入正数（如 20）表示「单次最多受 20 点伤」，
--   内部存成 -20，因为 DoDelta 的 amount 约定是「负数为伤害」。
--   ★★ 存负值是为了让 636 行的比较式 `amount < self.maxdamagetakenperhit`
--     能同时表达「amount 是伤害（负）」与「上限（负）」，
--     比较方向与扣血方向一致，不需要额外取反。
--   ★ nil 传参表示「取消上限」（517 行直接赋 nil）。
function Health:SetMaxDamageTakenPerHit(maxdamagetakenperhit)
    if maxdamagetakenperhit ~= nil and maxdamagetakenperhit > 0 then
        maxdamagetakenperhit = -maxdamagetakenperhit
    end
    self.maxdamagetakenperhit = maxdamagetakenperhit
end

--★ IsHurt 用 GetMaxWithPenalty 作分母：惩罚状态下即使血量等于裸上限，
--   也算「受伤了」（因为达不到可用上限）。这与 UI 血条的缺口逻辑一致。
function Health:IsHurt()
    return self.currenthealth < self:GetMaxWithPenalty()
end

--★★★【GetMaxWithPenalty：现算而非存储】
--   这是本文件最重要的一个设计决策：**不缓存「惩罚后的上限」**。
--   ★ 好处：任何路径改 maxhealth 或 penalty 都自动生效，
--     不存在「缓存与真值不一致」的中间态。
--   ★ 代价：每次都要一次乘法和一次减法——但这个开销可忽略。
--   ★★ 凡是读「上限」的地方都必须用本函数而不是裸 self.maxhealth：
--     DoDelta 的封顶（572）、IsHurt（521）、GetPercentWithPenalty（482）、
--     SetVal 的地板计算（568）、GetDebugString（492）。
--     漏掉任何一处都会导致惩罚状态下的不一致。
function Health:GetMaxWithPenalty()
    return self.maxhealth - self.maxhealth * self.penalty
end

--★★★【Kill：把自己打死，但尊重无敌】
--   DoDelta(-currenthealth, nil, nil, nil, nil, true) 参数逐个看：
--     amount = -currenthealth —— 一次扣到 0 底
--     overtime = nil, cause = nil —— 无类型标签（不是被谁杀的）
--     ignore_invincible = nil  —— ★ 遵守无敌状态：无敌时 Kill() 无效
--     ignore_absorb = true    —— ★ 跳过护甲：否则满护甲的实体打不死自己
--   ★★ `_ignore_maxdamagetakenperhit` 是为「绕过单次伤害上限」而设的临时标志。
--     很多实体的 maxdamagetakenperhit 只允许单次受 10 点伤，
--     若不绕过，Kill() 会被截断成 10 点伤害根本打不死。
--   ⚠ 这是**用成员变量当临时参数**的手法，Lua 里没有栈式参数覆盖的干净写法。
--     它不协程安全：若 DoDelta 内部触发的 death 事件处理里再调一次 Kill()，
--     标志已被置 nil，行为就会不同。实际不发生，但强类型移植时
--     应该改成显式的私有方法 doDeltaUncapped(amount, ...)。
function Health:Kill()
    if self.currenthealth > 0 then
		--V2C: didn't want to change external interface of DoDelta for this one internal use case
--★ 置 true → 调 DoDelta → 置 nil。严格 try/finally 形态（虽然没用 pcall）。
		self._ignore_maxdamagetakenperhit = true
        self:DoDelta(-self.currenthealth, nil, nil, nil, nil, true)
		self._ignore_maxdamagetakenperhit = nil
    end
end

--★★★【ForceKill = Kill + ignore_invincible=true】
--   两行差异（541 行 vs 532 行）就是全部语义：ForceKill 能打死无敌的实体。
--   ★ 用途：任务/调试/剧情强杀。搜 prefabs 可找到调用方。
--   ⚠ 但即使 ForceKill 也**不能**绕过 616 行的非致死保护判定——
--     因为那个检查在 DoDelta 的最前面，早于任何 ignore_* 参数。
--     也就是说：开了 NONLETHAL_TEMPERATURE 的世界里，
--     血量已低于 20% 的玩家，ForceKill 也杀不死。这是个真实的行为陷阱。
function Health:ForceKill() -- To bypass invincible
    if self.currenthealth > 0 then
        --V2C: didn't want to change external interface of DoDelta for this one internal use case
		self._ignore_maxdamagetakenperhit = true
        self:DoDelta(-self.currenthealth, nil, nil, true, nil, true)
		self._ignore_maxdamagetakenperhit = nil
    end
end

--★ IsDead 用 <= 0。与 oncurrenthealth:20 的 netvar 判定保持一致。
function Health:IsDead()
    return self.currenthealth <= 0
end

--★★★【SetPercent：按比例设血，附带一次 HUD 刷新】
--   `SetVal(self.maxhealth * percent, cause)` —— ★ 用的是**裸上限**不是惩罚后上限，
--     所以 percent=1 在有惩罚时会被 SetVal 的封顶压回。
--   `DoDelta(0, overtime, cause, true, nil, true)` —— ★ 零伤害刷新 HUD，
--     参数含义同 ForceUpdateHUD（150 行）。
--   ★ 两个参数（overtime / cause）从入参透传给 DoDelta，
--     目的很单纯：让这次「刷新」在 healthdelta 事件里带上正确的上下文，
--     使得依赖 cause 做分支的监听者不会看到「无因变化」。
--★ 复活时血量通常通过 SetPercent(0.5) 恢复 —— 参见 revivablecorpse.lua 的
--   revive_health_percet 字段（注意原变量名拼写为 percet 而非 percent）。
function Health:SetPercent(percent, overtime, cause)
    self:SetVal(self.maxhealth * percent, cause)
    self:DoDelta(0, overtime, cause, true, nil, true)
end

--★★【CanFadeOut：故意不做 IsValid() 检查】
--   英文原注释 "Intentional lack of IsValid()." 后面直接跟代码，什么都没解释。
--   结合 597-598 行的 V2C 注释才明白：**这是刻意的「不掩盖 bug」策略**。
--   若死亡时能安全地淡出，那么「死亡事件里把自己 Remove 掉」这类错误
--   就会被静默吞掉；让 prefab 显式设 nofadeout=true 才能让这段逻辑安全跑，
--   编译期就能暴露所有「死亡时自行移除」的实体。
--   ★★ 这是一个非常值得学习的错误处理哲学：
--     「防御性检查」有时候是在掩盖调用方的 bug。
function Health:CanFadeOut()
    -- Intentional lack of IsValid().
    return not self.nofadeout and not self.is_corpsing
end

--★ OnCorpsingEntitySleep：实体在「化为尸体」前就休眠时的补偿处理。
--   需求是「立刻进入 corpse 状态」，但状态图对休眠实体不调度，
--   所以只能靠 entitysleep 事件 + 手动 GoToState。
local function OnCorpsingEntitySleep(inst) -- Go instantly to corpse state
--★ PushEventImmediate 绕过事件队列立即派发——因为实体马上就休眠了，
--   排队的事件可能永远不被处理。参见 entityscript.lua 的 PushEventImmediate。
    inst.sg:GoToState("corpse")
    inst:PushEventImmediate("forcecorpsereplace")
end

--★★★【SetVal：血量赋值的真正实现，是整个文件的心脏】
--   所有路径（DoDelta / SetPercent / Kill / SetCurrentHealth）最终都汇到这里。
--   它做四件事：① 事件预告；② 上限封顶；③ 地板兜底；④ 死亡判定。
--   ★ 设计意图：这是一个**可取消点**——
--     监听者可以改 data.val。虽然 data 是临时表且没有返回值通道，
--     但监听者可以通过闭包间接改 self.currenthealth 来达到同样效果。
--     实际用途见 prefabs 里监听该事件的地方。
function Health:SetVal(val, cause, afflicter)
--★ old_health 用于死亡判定（571 行）与 healthdelta 事件。
    local old_health = self.currenthealth
--★ ★★★ 关键：封顶用 GetMaxWithPenalty()，不是裸 maxhealth。
--   这是「惩罚状态下的血量收敛点」——所有超额血量在此被削掉。
    local max_health = self:GetMaxWithPenalty()
--★★ `math.min(self.minhealth or 0, max_health)` —— 地板也要受上限约束。
--   ★ 为什么要 min？如果 minhealth 被设成 200 而 maxhealth 只有 100，
--     地板高于上限会导致「满血 = 死」这种荒谬状态。
--   ★ `self.minhealth or 0` 同时兼容「minhealth 未设置」与「显式设 0」。
    local min_health = math.min(self.minhealth or 0, max_health)

--★ pre_health_setval 事件的数据表是一次性分配（每帧都可能分配 → GC 压力）。
--   ★ 性能敏感：热路径上每帧一次 table 分配。移植时可用对象池或栈分配。
    self.inst:PushEvent("pre_health_setval", {val=val, old_health=old_health})

--★★【上限封顶】`if val > max_health then val = max_health end`
--   ★ 设计意图：血量是「不能溢出」的物理量，回血超出上限的部分直接丢弃。
--     这与多数游戏「回血溢出转化为治疗量」的设计相反——
--     DST 明确选择了「丢弃」，因为它要保证血条读数与实际值严格一致。
    if val > max_health then
        val = max_health
    end

--★★★【地板兜底与 minhealth 事件】
--   `val <= min_health` → 强制设为 min_health，并 PushEvent("minhealth")。
--   ★★ 语义：minhealth > 0 时这实际上**阻止了死亡**（因为 571 行的死亡判定
--     要求 currenthealth <= 0，而这里被兜到了 min_health > 0）。
--   ★ minhealth 事件的用途：让「血量触底」的实体能播放特殊反馈，
--     或在触底时做特殊处理（如韦爵的「半血」形态）。
--   ⚠ 注意这里的分支意味着：设置了 minhealth 的实体**永远不会触发 death 事件**，
--     即使被 DoDelta 扣到 0 以下。这是「免死」的正确实现，但也意味着
--     任何「靠 DoDelta(-99999) 强杀」的需求都会失效，必须改用 Kill/ForceKill。
    if val <= min_health then
        self.currenthealth = min_health
        self.inst:PushEvent("minhealth", { cause = cause, afflicter = afflicter })
    else
        self.currenthealth = val
    end

--★★★【死亡判定的四个条件：老血 > 0 且 新血 <= 0】
--   ★★ 「老血 > 0」这个条件保证**死亡事件只触发一次**：
--     实体死后若还有周期任务在扣血（或者别人又打了一下），
--     老血已经是 0，不会重复触发 death。
--   ★ 这是「幂等事件」的标准写法，避免了「尸体生成多份」的严重 bug。
--★★★【复活相关】health.lua **本身不含任何 revive 接口**。
--   复活由外部完成：revivablecorpse.lua:75 Revive(reviver) 推 "respawnfromcorpse"，
--   玩家的复活流程在 components/playercontroller.lua:2212 附近。
--   ★ 为什么放在外部？因为 health 只管「血量归零」，
--     而「复活点是半血还是满血」「复活后是否保留装备」属于玩法规则。
--   ⚠ 但 health.lua 的 583 行「老血 > 0 才触发 death」对复活至关重要：
--     复活流程通常先 SetVal(复活血量) 再做其余，
--     必须确保复活时 currenthealth 已被置为正数，death 事件才不会重放。
--     参见 components/revivablecorpse.lua:11 的 revive_health_percet = 0.5。
    if old_health > 0 and self.currenthealth <= 0 then
--★★【JBK 的注释解释了事件顺序的历史包袱】
--   "Make sure to keep the events fired up to date with the explosive component."
--   意思是：这段死亡事件派发的顺序与 components/explosive.lua 里的
--   死亡处理有隐式耦合，改动顺序会导致爆炸物行为异常。
--   ★ 教训：跨组件的隐式顺序依赖一定要写在注释里。
        -- NOTES(JBK): Make sure to keep the events fired up to date with the explosive component.
--★★★【世界事件必须先于实体事件 —— 极易踩的坑】
--   英文原注释："Push world event first, because the entity event may invalidate
--   itself -- i.e. items that use .nofadeout and manually :Remove() on 'death' event"。
--   ★★★ 完整场景：某些物品（用 nofadeout 的）在自己的 death 事件处理里
--     直接调 self:Remove()。如果先派发实体 death 事件，实体已被销毁，
--     随后派发的 TheWorld:PushEvent("entity_death", {inst = 已死实体}) 就会
--     把一个无效实体塞给全世界（世界监听者可能去访问它的 Transform）。
--   ★ 所以顺序必须是：先告知世界（让世界的监听者拿到活着的实体引用），
--     再告知实体自己（它可能自杀）。
--   ⚠⚠ 这是本文件里**最值得记住的顺序契约**。移植到任何语言都必须保留。
--★★★ 参见 entityscript.lua 的 PushEvent / PushEventImmediate ——
--   本行用 PushEvent 是因为实体此刻还有效（只是血量归零）。
--   对比 561 行 OnCorpsingEntitySleep 用的 PushEventImmediate。
--   参见 entityscript.lua 的 ListenForEvent / RemoveEventCallback（本文件 273/295 使用）。
        --Push world event first, because the entity event may invalidate itself
        --i.e. items that use .nofadeout and manually :Remove() on "death" event
--★ causeofdeath 只记 afflicter（施加者实体），不记 cause 字符串。
--   ★ 语义分工：cause（"fire"/"hunger"）是类型，afflicter（实体）是凶手。
--     「谁杀了我」用凶手，「怎么死的」用类型。
--   ⚠ 注意这里赋在 PushEvent **之前**——因为下面的 death 事件处理里
--     就可能去读 self.causeofdeath，顺序反了就读不到。
        self.causeofdeath = afflicter or nil
--★ CanEntityBecomeCorpse 判定尸体化资格。参见 componentutil.lua:1298。
        local is_corpsing = CanEntityBecomeCorpse(self.inst)
--★★ 世界级死亡事件。用途：成就/统计/任务监听（每个玩家的每次死亡都会经过）。
--   ★ 数据表一次性分配了 4 个字段，是全世界每帧都可能发生的分配。
--★ 参见 componentutil.lua:1298 CanEntityBecomeCorpse —— 尸体化资格判定。
--   TheWorld:PushEvent 的定义在 entityscript.lua 的 World 类里。
        TheWorld:PushEvent("entity_death", { inst = self.inst, cause = cause, afflicter = afflicter, corpsing = is_corpsing })
--★ 实体级死亡事件。对应客户端的 isdead tag（见 20 行）。
--★ 参见 components/locomotor.lua:1457 的死亡检查与 components/playercontroller.lua
--   的死亡处理，以及 stategraphs/SGwilson.lua 的死亡状态。
        self.inst:PushEvent("death", { cause = cause, afflicter = afflicter, corpsing = is_corpsing })
--★ is_corpsing 在事件派发**之后**才赋值——
--   因为 CanFadeOut（557 行）要读它，必须先有值。
        self.is_corpsing = is_corpsing

		--Here, check if killing player or monster
--★★【统计类型的分流】玩家击杀与生物击杀是两条独立成就线。
--   ★ `(self.inst.isplayer and "TotalPlayersKilled") or "TotalEnemiesKilled"`
--     是 Lua 的 and/or 三元写法：isplayer 为真则取前者，否则取后者。
--   ★★★ 重要：这个统计**无论死活都触发**——生物死亡也算「击杀」。
--     所以它统计的是「发生了几次死亡」，不是「玩家主动杀了几个」。
--     afflicter 作为第 3 参数传入用于排除自杀。
        local notify_type = (self.inst.isplayer and "TotalPlayersKilled") or "TotalEnemiesKilled"
--★ 参见 events / playerdeaths.lua —— 玩家死亡事件的后续统计。
        NotifyPlayerProgress(notify_type, 1, afflicter)

--★★★【V2C 注释：fadeout 与手动 Remove 的互斥契约】
--   "If 'death' handler removes ourself, then the prefab should explicitly set
--   nofadeout = true. Intentionally NOT using IsValid() here to hide those bugs."
--   ★★★ 设计契约：
--     · prefab 在自己的 death 处理里 Remove 自己 → 必须设 nofadeout = true
--     · 没设 → CanFadeOut 返回 true → 走 ErodeAway 淡出路径
--       而此时实体可能已经被移除，erode_task 就成了对死体的操作
--   ★ 故意不判 IsValid()：如果判了，「忘记设 nofadeout」这个 bug 就被掩盖，
--     表现为「实体没淡出也没消失」这类幽灵 bug。
--     不判，则立刻暴露成可复现的问题。
--   ★★ 这是上一条 CanFadeOut 注释的展开，二者必须一起读。
        --V2C: If "death" handler removes ourself, then the prefab should explicitly set nofadeout = true.
        --     Intentionally NOT using IsValid() here to hide those bugs.
--★ CanFadeOut 分支：正常淡出路径。
        if self:CanFadeOut() then
--★ 加 NOCLICK 标签：淡出中的尸体不能被点击——否则玩家能反复点开一个半透明的尸体。
            self.inst:AddTag("NOCLICK")
--★★ `self.inst.persists = false` —— 淡出中的实体不再进存档。
--   ★ 防止「玩家在尸体淡出的 2 秒内存档，读档后尸体又回来了」的时间旅行 bug。
            self.inst.persists = false
--★ destroytime or 2：默认可配置延迟。ErodeAway 定义在 simutil.lua:570。
--★ 参见 simutil.lua:570 ErodeAway —— 淡出实现。
            self.inst.erode_task = self.inst:DoTaskInTime(self.destroytime or 2, ErodeAway)
--★★ 尸体化分支：实体不淡出，而是转成「可交互的 corpse」。
--   条件是 CanFadeOut() 为 false 且 is_corpsing 为真——
--   即实体自己声明了「我要变尸体」（nofadeout 或自带尸体逻辑）。
        elseif self.is_corpsing then
--★ 休眠实体无法靠状态图自己跳转，所以走 560 行的补偿路径。
            if self.inst:IsAsleep() then
                OnCorpsingEntitySleep(self.inst)
--★ 清醒实体则监听「即将休眠」事件。这是「状态图与组件生命周期」的标准协作。
            else
                self.inst:ListenForEvent("entitysleep", OnCorpsingEntitySleep)
            end
        end
    end
end

--★★★★★【DoDelta —— 全游戏所有生存压力的最终汇聚点】
--   120+ 处调用方（战斗、火焰、饥饿、温度、溺水、腐蚀、船体、
--   爆炸物、月光、护盾道具……）的每一次伤害或回复都走这里。
--   它是一条**七级流水线**，顺序不可交换：
--     ① 非致死保护（616）  → 环境保底，最先拦
--     ② redirect 钩子（623） → 模组完全接管（盾/无敌/吸收转移）
--     ③ 无敌拦截（625）    → 无敌/传送中
--     ④ 吸收与减伤（627）  → 一代+二代百分比、三代固定值
--     ⑤ deltamodifierfn（632）→ 模组改写 amount
--     ⑥ 单次伤害上限（636） → maxdamagetakenperhit
--     ⑦ 落地：SetVal + 事件（640-647）
--   ★★ 顺序即语义，几个关键点：
--     · ① 在 ③ 之前 → 意味着**非致死保护连 ForceKill 都绕不过**（见 541 行注释）
--     · ② 在 ③ 之前 → 模组可以用 redirect 实现「无敌」（返回 true 吞掉伤害）
--     · ④ 在 ⑤ 之前 → 模组看到的是**已减免**的 amount
--     · ⑥ 在最后 → 上限作用于**最终值**，是最强的兜底
--   ---------------------------------------------------------------
--   完整参数表：
--     amount           正数=回复，负数=伤害。伤害一般传 -x。
--                     ★ 这是唯一带符号的参数，全文件所有减法都靠它。
--     overtime          true=定时/持续伤害（DoRegen/温度/饥饿都用 true），
--                     false/nil=一次性/即时伤害。
--                     ★ 语义是「这次变化是慢慢发生的还是突然发生的」，
--                       下游用它决定要不要播大血条动画/是否算连击。
--     cause             伤害**类型**的字符串标识：
--                     "fire" "cold" "hot" "hunger" "drowning" "acidrain"
--                     "regen" "regen_<key>" "NIL"（combat 无 cause 时的默认）
--                     ★★ 616 行的非致死保护直接用 cause 字符串做判定，
--                       所以自定义伤害不传标准 cause 字符串就会失去保底保护。
--     ignore_invincible  true=无视无敌。★ 只有 Kill/ForceKill/SetPercent/ForceUpdateHUD 用。
--     afflicter         造成伤害的**实体**（或 nil）。决定：
--                       · 能否享受 playerabsorb（628 行）
--                       · 能否享受 externalreduction（629 行）
--                       · 死亡时 causeofdeath 与击杀统计（587/595 行）
--     ignore_absorb     true=跳过吸收/减伤。
--                       ★ 注意 627 行的 `amount < 0 and not ignore_absorb`：
--                         它对**回复无效**（因为本来就在 amount<0 分支里），
--                         所以这个参数的实际作用是「本次伤害不走减伤」。
--   返回值：实际生效的 amount（已减免），或 0（被拦截）。
--   ★★ 返回值被 combat.lua:653 用来计算「实际打了多少伤害」→ 决定击杀归属。
--★★ 参见 entityscript.lua:1714 Remove —— 组件卸载会触发 OnRemoveFromEntity（116 行），
--   那里停掉所有 regen 任务与事件监听。
function Health:DoDelta(amount, overtime, cause, ignore_invincible, afflicter, ignore_absorb)
--★ old_percent 在扣血**之前**取，后面用于 healthdelta 事件与 ondelta 回调。
    local old_percent = self:GetPercent()

--★★★【第一级：非致死保护】
--   条件：血量百分比 ≤ nonlethal_pct(0.2) **且**（cause 是温度 **或** cause 是饥饿）
--         **且** 对应的 nonlethal_temperature / nonlethal_hunger 开关为真。
--   ★★★ 三个 and 缺一不可，是「双重授权」：
--     · 低血量（≤20%）
--     · 来源是环境（cold/hot/hunger，不含 drowning/酸雨/火焰）
--     · 且该类别的非致死保护被世界设置开启
--   ★ 注意第二个括号里的写法：
--     `((cause == "cold" or cause == "hot") and self.nonlethal_temperature) or
--      (cause == "hunger" and self.nonlethal_hunger)`
--     这是 Lua 的 and/or 链式三元：前者为真取 nonlethal_temperature，
--     否则取后者。⚠ 如果 nonlethal_temperature 恰为 false，
--     表达式会继续评估 or 的右边——对于 cause=="cold" 的情况，
--     右边是 `(false and ...)` = false，结果为 false，正确。
--     但这个「靠 or 短路修正」的模式极其脆弱：只要 nonlethal_temperature
--     是 nil（而非 false），`true and nil` = nil，再 or 右边 → 走错分支。
--   ⚠⚠ 强类型移植必须改写成显式的 if/elseif/else 链。
--★★ 参见 components/temperature.lua:519（cold）与 :521（hot）、
--   components/hunger.lua:160（hunger）—— 这三处是 nonlethal_* 保护服务的唯一来源。
--   参见 tuning.lua:6834-6837 的 NONLETHAL_TEMPERATURE / NONLETHAL_HUNGER /
--   NONLETHAL_PERCENT 三项默认值。
    if old_percent <= self.nonlethal_pct and
		(((cause == "cold" or cause == "hot") and self.nonlethal_temperature) or
		(cause == "hunger" and self.nonlethal_hunger)) then

--★ 返回 0 而非 nil：调用方（如 combat.lua）会做算术，0 比 nil 安全。
        return 0
    end

--★★★【第二级：redirect 钩子 —— 模组的完全接管点】
--   `self.redirect(inst, amount, overtime, cause, ignore_invincible, afflicter, ignore_absorb)`
--   ★★ 设计：**返回真值即表示「我已处理」**，函数立刻返回 0，什么都不做。
--   ★ 这是 DST 模组实现「伤害转移 / 全伤害免疫 / 自定义护盾」的标准入口。
--   ★ 关键设计：redirect 放在**无敌判定之前**，
--     所以它连无敌状态都能绕——模组可以据此实现「无敌期间也受某类伤害」。
--   ★ 签名与 DoDelta 完全一致（除 redirect 本身），便于模组包装转发。
--   ⚠ 但 redirect 存在 self 上且无类型约束，任何模组误设都会静默吞掉所有伤害。
    if self.redirect ~= nil and self.redirect(self.inst, amount, overtime, cause, ignore_invincible, afflicter, ignore_absorb) then
        return 0
--★★★【第三级：无敌与传送拦截】
--   ★ `or self.inst.is_teleporting` 是「传送中免疫伤害」——
--     传送是一个原子操作，中途被打断会导致实体落在非法位置。
--     搜 prefabs 可找到设置 is_teleporting 的地方。
--   ★★ 隐患：`(self:IsInvincible() or self.inst.is_teleporting)` 可能为 nil，
--     在 `not ignore_invincible and (...)` 里 nil 被当假处理，语义正确，
--     但这依赖了「not nil == true」这个 Lua 特性。强类型语言需要显式 bool。
    elseif not ignore_invincible and (self:IsInvincible() or self.inst.is_teleporting) then
        return 0
--★★【第四级：吸收与减伤 —— 只对伤害生效】
--   `elseif amount < 0 and not ignore_absorb`
--   ★ 双重守卫：必须是伤害（负数）且调用方没要求跳过。
--   ⚠★ 常见误用：把「治疗道具」也写成 DoDelta(x, false, "...") 但漏传
--     ignore_absorb —— 结果无害（因为 amount>0 不进这个分支），
--     但会让读者困惑。真正的误用是**给负数回复传了 true**。
    elseif amount < 0 and not ignore_absorb then        
--★★★★★【减伤公式第一段：百分比吸收 —— 三个坑都在这一行】
--   `amount = amount * math.clamp(1 - ABSORB_TOTAL, 0, 1) * math.max(1 - externalabsorb, 0)`
--   ABSORB_TOTAL 的求值（and/or 链式三元）：
--     self.playerabsorb ~= 0 and afflicter ~= nil and afflicter:HasTag("player")
--       and (self.playerabsorb + self.absorb)
--     or self.absorb
--   ⚠⚠⚠ 坑一【nil 陷阱 —— 本项目 bug-patterns.md 收录的那一条】：
--     if self.absorb 被写成 nil（而非 0），这条 and/or 链的最终结果是 nil，
--     于是 `1 - nil` 立刻抛 "attempt to perform arithmetic on a nil value"。
--     构造函数（89 行）把 absorb 初始化为 0，所以**游戏本体安全**；
--     但任何外部代码写 `inst.components.health.absorb = nil` 就会崩。
--     ★★ 更隐蔽的变体：如果 `self.playerabsorb + self.absorb` 恰好等于 0，
--       在 Lua 里 0 是 **truthy**，所以不会误落到 or 分支——这点是幸运的。
--       但在**强类型语言**里，若把 0 建模成「假值」或用 Optional 表达，
--       这个三元就会走进错误分支，得到 self.absorb 而非两者之和。
--       这正是「Lua 的 and/or 三元在强类型移植中必然出事」的典型案例。
--   ⚠⚠ 坑二【afflicter 的隐式类型约束】：
--     `afflicter:HasTag("player")` 假定 afflicter 是实体。
--     若某个调用方误传了字符串（很多模组会传 prefab 名字符串），
--     这里会崩。Compare 229 行的 DoFireDamage：它把字符串放在 **cause**、
--     实体放在 **afflicter**，正是为了避开这个坑。
--   ⚠ 坑三【两层吸收重复计算】：
--     一代（absorb/playerabsorb，已废弃）与二代（externalabsorbmodifiers）
--     是**相乘**而非相加（两个独立的 ×(1-p)）。
--     若同时设了 50% 和 50%，实际伤害是 25%——叠乘而非叠加 100%。
--     这与「护甲叠加」的直觉完全相反，属于易被误用的设计。
--   ★ 防御意图：`math.clamp(..., 0, 1)` 防一代吸收率超过 100% 导致负伤害（回血）；
--     `math.max(1 - externalabsorb, 0)` 只防下界，★ 不防上界——
--     所以二代吸收率可以超过 1（完全免疫且继续「负吸收」），
--     只要不超过 1 就不会反向回血。
--   ★ 顺带解释调用方：prefabs/foodbuffs.lua:7 传入 BUFF_PLAYERABSORPTION_MODIFIER
--     = 1/3，即「伤害 × 2/3」。这是 `1 - p` 语义的直接体现。
        amount = amount * math.clamp(1 - (self.playerabsorb ~= 0 and afflicter ~= nil and afflicter:HasTag("player") and self.playerabsorb + self.absorb or self.absorb), 0, 1) * math.max(1 - self.externalabsorbmodifiers:Get(), 0)
--★★★★★【减伤公式第二段：固定值减免 —— 用户指出的已知缺陷就在这里】
--   `amount = afflicter ~= nil and math.min(0, amount + REDUCTION) or amount`
--   意图：externalreductionmodifiers 存的是**绝对减免量**
--   （TUNING.GHOSTLYELIXIR_PLAYER_SHIELD_REDUCTION = 50，即一次性免 50 血），
--   应当在 amount 上减去；并用 math.min(0, ...) 钳制「最多只能把伤害减到 0，
--   绝不能减成正数（那样就变成治疗了）」。
--   ★★★ 核实结论：缺陷不在 math.min(0,...) 本身，而在于它**前面的 and/or 短路**：
--     条件是 `afflicter ~= nil`。而环境类伤害（温度/饥饿/溺水/酸雨/腐蚀/船体）
--     的调用方一律**不传 afflicter**，例如：
--       components/temperature.lua:519  DoDelta(-hurtrate*dt, true, "cold")
--       components/temperature.lua:521  DoDelta(-..., true, "hot")
--       components/hunger.lua:160        DoDelta(-hurtrate*dt, true, "hunger")
--       components/drownable.lua:378     DoDelta(delta, false, "drowning", true, nil, true)
--     于是 afflicter == nil → 整个 and/or 表达式取 or 分支 → amount 原样返回。
--   ★★ 结论【对用户假设的精确修正】：
--     ① math.min(0, ...) 的语义是正确的（防治疗），它不是缺陷本身；
--     ② 真正让 externalreduction 对环境伤害失效的是 `afflicter ~= nil` 这个前置条件；
--     ③ 但两者的**外部可观测后果一致**——玩家看到的就是
--        「幽灵药剂护盾不挡冻伤/饥饿/溺水」，于是被记为缺陷。
--   ⚠⚠ 设计层面的疑问：作者为什么要求 afflicter 非 nil？
--     合理推测是「固定减免只针对可归因的攻击」，避免环境伤害被护盾完全免疫
--     （那会让护盾成为万能解）。但**没有注释说明这一点**，
--     且用 and/or 链式写法把这个业务规则伪装成了技术细节——这才是缺陷的真正所在：
--     一个「有意为之的业务规则」被写成了「看不出意图的短路表达式」。
--   ⚠ 另一处 and/or 三元陷阱：若 REDUCTION 恰好使 `amount + REDUCTION` 等于 0，
--     math.min(0,0) 返回 0，而 **0 在 Lua 里是 truthy**，所以不会误落到 or 分支。
--     这点又是幸运的（见 628 行坑一的对比）。
--   ⚠ 若 afflicter 非 nil 但 REDUCTION 为 0（未设置护盾），
--     `math.min(0, amount + 0) = amount`（amount 为负），
--     负数在 Lua 里是 truthy，所以结果仍是 amount——正确但绕。
        amount = afflicter ~= nil and math.min(0, amount + self.externalreductionmodifiers:Get()) or amount
    end

--★★★【第五级：deltamodifierfn —— 模组改写点】
--   与 redirect 的区别：redirect 返回真值表示「我全处理了」；
--   deltamodifierfn 返回值**直接成为新的 amount**，继续走后面的流水线。
--   ★ 设计意图：让模组能「加 5 点伤害」「按距离缩放」而不必自己实现护盾。
--   ★★ 位置很讲究：在吸收减伤**之后**、单次上限**之前**——
--     所以模组看到的是已减免的值，而它的修改结果仍受上限保护。
--   ⚠ 模组若返回 nil，则 amount 变 nil，后续 SetVal(currenthealth + nil) 崩溃。
--     这是个未加保护的扩展点。
    if self.deltamodifierfn ~= nil then
        amount = self.deltamodifierfn(self.inst, amount, overtime, cause, ignore_invincible, afflicter, ignore_absorb)
    end

--★★★【第六级：单次伤害上限】
--   `if self.maxdamagetakenperhit ~= nil and amount < self.maxdamagetakenperhit`
--     and not self._ignore_maxdamagetakenperhit then amount = self.maxdamagetakenperhit`
--   ★★★ 比较方向是「amount（负）小于上限（负）」即「伤害超过上限」：
--     上限 -20，amount = -50 → -50 < -20 成立 → 截断成 -20。
--   ★ `_ignore_maxdamagetakenperhit` 是 Kill/ForceKill 用的旁路开关。
--   ⚠⚠ 疑似缺陷【旁路开关的作用域太宽】：
--     该检查在吸收减伤与 deltamodifierfn **之后**，
--     所以 Kill() 的 DoDelta 虽然 ignore_absorb=true（跳过减伤），
--     但仍要靠这个标志绕过上限。设计上正确。
--     真正的问题是：`_ignore_maxdamagetakenperhit` 是组件成员变量，
--     若 DoDelta 内部触发的事件处理里再进一次 DoDelta（如 death 事件里的连锁伤害），
--     内层会继承这个标志而意外跳过上限。当前代码路径不产生这种重入，
--     但这个隐患在重构时极易被引入。
--   ★ 用途示例：巨型生物（BETTER_HERDING 之类）设很小的单次上限，
--     避免被一次高频小伤害（如 numerous spines 的 DoPeriodicTask）瞬秒。
    if self.maxdamagetakenperhit ~= nil and amount < self.maxdamagetakenperhit and not self._ignore_maxdamagetakenperhit then
        amount = self.maxdamagetakenperhit
    end

--★ 落地：把 amount 加到当前血量上。**这里是唯一真正改血量的地方**。
--   ★ 注意调的是 SetVal 而不是裸赋值 —— 封顶、地板、死亡判定全在里面。
    self:SetVal(self.currenthealth + amount, cause, afflicter)

--★★★【healthdelta 事件 —— 本文件订阅量最大的事件】
--   一次性分配 7 字段的表。★ 这是血量变化的主要广播出口：
--     oldpercent / newpercent —— 供 UI 做平滑动画与「刚刚掉了多少」
--     overtime               —— 供下游区分定时/即时
--     cause                  —— 供下游分支（谁造成的）
--     afflicter              —— 供击杀归属与吸收计算
--     amount                 —— ★ 已减免后的实际值，
--       所以监听者看到的是「真实掉血」而非「原始伤害」。
--   ⚠ 性能：每次扣血都分配一个 table。温度/饥饿这类每帧扣血的热路径，
--     每秒会分配 30 个表。移植时这里是 GC 压力点。
--   ⚠ 另一注意：即使 amount=0（ForceUpdateHUD 的零伤害刷新），
--     这个事件**依然会派发**。所以监听者必须能容忍 newpercent == oldpercent。
    self.inst:PushEvent("healthdelta", { oldpercent = old_percent, newpercent = self:GetPercent(), overtime = overtime, cause = cause, afflicter = afflicter, amount = amount })

--★★【ondelta 回调：比事件更早、更轻的一档】
--   与 healthdelta 事件的区别：
--     · ondelta 是直接函数引用，零事件分发开销（热路径友好）
--     · healthdelta 走完整事件总线，能被任意监听者订阅
--   ★ 谁在用 ondelta？搜 prefabs 可见部分角色用它在血量变化时切形态/播特效。
    if self.ondelta ~= nil then
--★★ 英文原注释 "Re-call GetPercent on the slight chance that 'healthdelta' changed it."
--   这揭示了一个**真实的重入风险**：healthdelta 的监听者可能反过来改血量
--   （例如「触发即回血」的道具、或事件处理里调 SetVal）。
--   ★ 所以 ondelta 拿到的 newpercent 未必等于本函数算出的值——
--     必须现取，而不是复用中间变量。
--   ⚠ 这也是「事件派发中允许状态被改变」的必然要求。
        -- Re-call GetPercent on the slight chance that "healthdelta" changed it.
--★ ondelta 签名与 healthdelta 的数据一一对应，参数名完全一致。
        self.ondelta(self.inst, old_percent, self:GetPercent(), overtime, cause, afflicter, amount)
    end
--★★ 返回实际生效的 amount。这是 combat.lua 判定「打了多少伤害」的依据。
    return amount
end

--★★★【TransferComponent：把血量状态迁移到新实体】
--   典型场景：武器耐久耗尽、物品变形（如耐久物品换成新形态）、
--   玩家换 prefab（韦爵变形）等。旧实体的 health 组件状态要继承给新实体。
--   ★★★ 迁移清单（★ 刻意只迁这四样）：
--     ① 血量百分比（不是绝对值！）—— 因为新实体 maxhealth 可能不同
--     ② 是否正在燃烧
--     ③ 燃烧起始时刻（决定低伤阶段是否已过）
--     ④ 最后一次火焰伤害时刻（决定新实体的火焰迟滞窗口从哪算起）
--   ★★ 为什么不迁 penalty / invincible / absorb：
--     这些是「施加在实体上的效果」，属于旧实体的语境。
--     迁移它们会让新实体凭空获得不该有的减伤。
function Health:TransferComponent(newinst)
    local newcomponent = newinst.components.health
--★ SetPercent 迁的是比例而非绝对值——正确的选择，因为 maxhealth 常变。
    newcomponent:SetPercent(self:GetPercent())

--★ 直接赋值 takingfiredamage 会触发 setter → 同步副本。
    newcomponent.takingfiredamage = self.takingfiredamage
--★ 只有「正在燃烧」才需要补齐后面三个字段——非燃烧态无需复制时序数据。
    if newcomponent.takingfiredamage then
        newcomponent.takingfiredamagestarttime = self.takingfiredamagestarttime
        newcomponent.takingfiredamagelow = self.takingfiredamagelow
--★★ StartUpdatingComponent：新实体必须立刻接上帧更新，
--   否则 DoFireDamage 里设置的燃烧状态会永远等不到 OnUpdate 的熄灭判定。
--   ★ 这是「状态迁移必须连带迁移调度状态」的典型——
--     只搬数据不搬调度，会导致「状态存在但无人维护」。
        newinst:StartUpdatingComponent(newcomponent)
--★ 向新实体补发 startfiredamage 事件，让它的状态图/特效立刻进入燃烧表现。
        newinst:PushEvent("startfiredamage", { low = newcomponent.takingfiredamagelow })
    end
--★★ lastfiredamagetime 无论是否燃烧都要迁移。
--   理由：新实体若在 0.5 秒内又被点燃，火焰迟滞判定应以**旧实体的最后时刻**
--   为基准，才能保持「刚灭的火不会立刻重新烧起来」的连续手感。
--   ★ 这个字段无条件迁移是本函数里最容易被写漏的一行。
    newcomponent.lastfiredamagetime = self.lastfiredamagetime
end

return Health
