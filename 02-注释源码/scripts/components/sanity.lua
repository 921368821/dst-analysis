--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/sanity.lua
-- 模块：组件 / 生存状态 / 理智值（Sanity）
-- 职责：定义 Sanity 组件 —— 全游戏最复杂的数值系统之一。负责把「光照、
--       潮湿、装扮（dapperness）、周目光环（aura）、幽灵玩家、物品修饰、
--       角色特性」等十余种来源折算成一个每秒速率 rate，逐帧积分进current，
--       再据此驱动 sane/insane/lunacy 状态迁移、网络同步与 UI 事件。
--       ★ 它同时是「容器式」组件：既管玩家（inst.replica.sanity），
--         也管怪物（pigman / ghost 等带 sanity 组件的 prefab）。
-- 关键符号：Sanity, Sanity:Recalc, Sanity:OnUpdate, Sanity:DoDelta,
--           Sanity:RecalcGhostDrain, Sanity:GetPercent,
--           Sanity:GetPercentWithPenalty, Sanity:GetMaxWithPenalty,
--           Sanity:SetPercent, Sanity:SetInducedInsanity,
--           Sanity:SetInducedLunacy, Sanity:RecalculatePenalty,
--           Sanity:EnableLunacy, Sanity:UpdateMode_Internal,
--           Sanity:AddSanityAuraImmunity, Sanity:TransferComponent,
--           _replica_setcurrent, _replica_setissane,
--           LIGHT_SANITY_DRAINS, SCRATCHPAD_AURANAMES
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/sanity_replica.lua（客户端镜像）, constants.lua
--           （SANITY_MODE_* / RATE_SCALE）, tuning.lua（全部数值常量）,
--           components/sanityaura.lua（光环数据源）, components/moisture.lua,
--           util/sourcemodifierlist.lua（修饰器列表）, gamemodes.lua:274
--           （GetGhostSanityDrain）, scheduler.lua（周期/长更新调度）
--============================================================
--【★ easing 是「缓动函数库」】sanity 用它把湿度映射成平滑的理智惩罚。
--   之所以要缓动：湿度是 0~100 的连续量，若线性映射，理智下降速度会在
--   湿度刚过 0 时突然产生难以察觉的阶跃感；inSine 让「刚沾湿」几乎无损、
--   「快湿透」惩罚陡增，体感更自然。
local easing = require("easing")
--【SourceModifierList —— 全DST 最重要的数值解耦工具】
--它解决的问题：一个数值会被十几个来源同时影响（帽子、食物、天气、角色特性）。
--若每个来源各自去改self.current，就会出现「谁先改、谁后减」的顺序耦合。
--   SourceModifierList 把它改成一组「加性/乘性贡献」，
--   每帧只做一次 Get() 求和，见 sanity.lua:87、:95、:590。
--   参见 util/sourcemodifierlist.lua。
local SourceModifierList = require("util/sourcemodifierlist")

--【★★★ 「强制状态」覆盖层 —— 全文件最精妙的一处设计】
--问题：游戏里有三类状态会「无视」真实理智值直接改显示：
--     ① inducedinsanity（被强拉进疯狂，如DDLC 头带）
--     ② inducedlunacy（被强拉进 enlightenment）
--     ③ penalty（代价机制压低上限，如 Maxwell 的影子仆从）
--   若在数据源上直接改 self.current，就再也无法恢复，且会被本帧的
--   速率积分立刻「挣」回来（自相矛盾）。
--做法：self.current 保持真实值不动，只在「同步给客户端」这一步做覆盖。
--   于是本文件里出现大量「显示用值」与「真实值」分叉的函数对：
--     GetPercent / GetRealPercent、GetPercentWithPenalty / GetPercent、
--     IsSane 的两个分支。
--★ 注意参数顺序被刻意打乱成 (self, replica_sanity, current, max, ...)，
--   这样调用方只需写 self.inst.replica.sanity 而不用反复 self.inst.replica 取值。
local function _replica_setcurrent(self, replica_sanity, current, max, penalty, inducedinsanity, inducedlunacy)
--   下面是优先级链：inducedinsanity > inducedlunacy > current。
	replica_sanity:SetCurrent(
--  ⚠ 疑似缺陷（原作者自己标注的）：
--     源码把 (inducedlunacy and inducedinsanity and 0) 整行注释掉了，
--     旁边写着 redundant（多余）。
--     推理依据：若两者同时为真，当前代码走第 7 行返回 0；
--       而被注释的写法返回的也正好是 0 —— 行为完全等价，故可安全删除。
--     但真正的隐患在于它**没有被禁止**：两个 forced 标志来自不同来源
--       （SetInducedInsanity / SetInducedLunacy，见 sanity.lua:331、:354），
--       互不排斥，理论上可同时成立。目前靠「二者同为 0 值」侥幸无害。
		--(inducedunacy and inducedinsanity and 0) or --redundant
--   ① 被强制疯狂：显示 0。注意这里**不看当前是否本来就已经很低**，
--      强制疯狂就是 0，把玩家按在理智崩溃的表现上。
		(inducedinsanity and 0) or
--   ② 被强制 enlightenment：显示 max*(1-penalty)。
--      ★ 不是 1-penalty（比例）而是 max*(1-penalty)（绝对值），
--        因为分类显示的 currentsanity 与 maxsanity 是两个独立的网络字段，
--        必须给出一个「绝对理智值」才能让客户端自行做比例计算。
--        若只发比例，maxsanity 的网络插值会让 UI 抖动。
		(inducedlunacy and max * (1 - penalty)) or
		current
	)
end

--【★★★ sane 标志的「模式互换」】这是本文件最容易看错的地方。
--IsSane() 并不是简单地「self.sane 为真」，而是一个**随 mode 翻转的映射**：
--     在 INSANITY 模式：sane=true  表示「理智正常」，sane=false 表示「疯狂」
--     在 LUNACY   模式：sane=true  表示「开悟正常」，sane=false 表示「开悟」
--   ★ 也就是说 self.sane 这个字段的语义本身是「没有处于特殊态」，
--     而IsSane() 把它翻译成当前模式下玩家视角的「是否正常」。
--   好处：模式切换时无需重置任何数值，只需换掉翻译函数，
--         阈值判定逻辑（DoDelta，sanity.lua:391）也能对称复用。
local function _replica_setissane(self, replica_sanity, sane, mode, inducedinsanity, inducedlunacy)
--   先按当前模式决定「基线」，再用另一个 forced 标志做反向覆盖。
	if mode == SANITY_MODE_INSANITY then
--     INSANITY 模式：正常 = sane且没被强制疯狂；
--       但若被强制开悟，即使 sane 也算不正常（or inducedlunacy）。
		replica_sanity:SetIsSane(sane and not inducedinsanity or inducedlunacy or false)
--   LUNACY 模式：与上面**完全对称**。else 分支不写条件，
--     是靠「mode 只有两种取值」这个不变量成立的（见 constants.lua:1234-1235）。
--     ⚠ 疑似脆弱点：若将来加入第三种 mode，这里会静默走错分支。
	else--if mode == SANITY_MODE_LUNACY then
--     LUNACY 模式：正常 = sane 且没被强制开悟；
--       被强制疯狂则一律不正常。
		replica_sanity:SetIsSane(sane and not inducedlunacy or inducedinsanity or false)
	end
end

--【属性 setter：max】Class 第三参数表（sanity.lua:126）把字段写入变成函数调用，
--   好处：改字段后自动同步网络，调用方无脑写 self.max = x 即可，不会漏同步。
--   onmax 额外处理了一个边界：若正被强制开悟，理智上限变了，
--     必须把「显示用的 current」一起重算，否则会出现上限变了但比例跳变。
local function onmax(self, max)
	local replica_sanity = self.inst.replica.sanity
	replica_sanity:SetMax(max)
--   ★ 条件带了 and not self.inducedinsanity：
--     若同时被强制疯狂，第7 行会覆盖成 0，这里就不用（也不该）重算。
	if self.inducedlunacy and not self.inducedinsanity then
		--see _replica_setcurrent
		replica_sanity:SetCurrent(max * (1 - self.penalty))
	end
end

--【属性 setter：current】同样自动触发 _replica_setcurrent 的覆盖逻辑。
local function oncurrent(self, current)
	_replica_setcurrent(self, self.inst.replica.sanity, current, self.max, self.penalty, self.inducedinsanity, self.inducedlunacy)
end

--【属性 setter：ratescale】ratescale 是给 UI 用的「+1/-1 箭头」提示档位。
--   ★ 它是**瞬时导数**而非累积量，所以不需要 forced 覆盖 ——
--     强制疯狂时箭头依然应该反映真实增减，否则玩家会觉得「数值不动了」。
--   档位定义见 constants.lua:2404的 RATE_SCALE（NEUTRAL=0 起，共7 档）。
local function onratescale(self, ratescale)
    self.inst.replica.sanity:SetRateScale(ratescale)
end

--【属性 setter：mode】模式（疯狂/开悟）切换时，需要同时刷新两样东西：
--     ① sanitymode 字段本身 ② sane 标志（因为 IsSane 的映射变了）。
--   ★ 这解释了为什么 UpdateMode_Internal（:175）切模式后必须调用 DoDelta(0) ——
--     不是为了改数值，而是借DoDelta「顺手」触发一次全量同步。
local function onmode(self, mode)
	local replica_sanity = self.inst.replica.sanity
	replica_sanity:SetSanityMode(mode)
	_replica_setissane(self, replica_sanity, self.sane, mode, self.inducedinsanity, self.inducedlunacy)
end

--【属性 setter：sane】仅需重算 sane 映射，数值不变。
local function onsane(self, sane)
	_replica_setissane(self, self.inst.replica.sanity, sane, self.mode, self.inducedinsanity, self.inducedlunacy)
end

--【属性 setter：inducedinsanity】被外力强制疯狂（如游戏里的头带道具）。
--   ★ 关键设计：它**不改 self.current**（真实理智照常流动），
--     只改 forced 标志。所以摘掉头带后理智不会「跳回」，而是接着原值继续算。
--     若改成直接扣血，就无法区分「本来快疯了」与「被道具按下去」。
local function oninducedinsanity(self, inducedinsanity)
	local replica_sanity = self.inst.replica.sanity
--   同时刷新 sane 与 current：forced 状态变了，两个显示量都要重算。
	_replica_setissane(self, replica_sanity, self.sane, self.mode, inducedinsanity, self.inducedlunacy)
	_replica_setcurrent(self, replica_sanity, self.current, self.max, self.penalty, inducedinsanity, self.inducedlunacy)
end

--【属性 setter：inducedlunacy】与 inducedinsanity 严格对称。
--   使用方见 prefabs/hats.lua:3387（强制开悟类帽子）。
local function oninducedlunacy(self, inducedlunacy)
	local replica_sanity = self.inst.replica.sanity
	_replica_setissane(self, replica_sanity, self.sane, self.mode, self.inducedinsanity, inducedlunacy)
	_replica_setcurrent(self, replica_sanity, self.current, self.max, self.penalty, self.inducedinsanity, inducedlunacy)
end

--【属性 setter：penalty —— 「代价机制」的入口】
--   penalty 是 0~1 的比例，表示「永久压低理智上限」，例如 Maxwell 携带影子。
--   ★ 与 forced 标志不同，penalty 是**真实**上限的一部分：
--     它会参与 DoDelta 里的钳制（sanity.lua:387）与所有百分比计算。
--     所以它是不可逆的（除非主动移除对应 penalty 项）。
local function onpenalty(self, penalty)
	local replica_sanity = self.inst.replica.sanity
--   同步给客户端的比例值。客户端侧见 sanity_replica.lua:107 的 SetPenalty，
--   那里做了 0~1 的assert 并以 *200 定点传输（省带宽）。
	replica_sanity:SetPenalty(penalty)
	if self.inducedlunacy and not self.inducedinsanity then
		--see _replica_setcurrent
		replica_sanity:SetCurrent(self.max * (1 - penalty))
	end
end

--【属性 setter：ghost_drain_mult —— 「幽灵玩家」惩罚】
--   在有房主掉线留下幽灵的世界里，活着的人会被持续抽理智。
--   这里同步的只是一个 bool（是否 >0），因为 UI 只需要显示一个图标。
--   ★ 具体倍率由 RecalcGhostDrain（:456）按人数动态算，不逐帧同步。
local function onghostdrainmult(self, ghostdrainmult)
--   实现在 sanity_replica.lua:230，只写 ghostdrainmult > 0 这个布尔量。
    self.inst.replica.sanity:SetGhostDrainMult(ghostdrainmult)
end

--【★★★ 构造函数：整个组件的状态声明集中在此】
--   注意本组件**没有 OnSave 之外的注册式更新**（对比 hunger 用 DoPeriodicTask），
--   而是在末尾用 StartUpdatingComponent 把自己挂进每帧更新队列（:122）。
--   原因是 sanity 的衰减速率依赖光照/湿度/aura 这些每帧都在变的状态，
--   必须每帧重算（详见:510Recalc 的说明）。
local Sanity = Class(function(self, inst)
    self.inst = inst
--   ★ 默认 max=100，但玩家的真实值由角色 prefab 覆盖，
--     例如 prefabs/willow.lua:169 的 SetMax(TUNING.WILLOW_SANITY)。
--     tuning.lua 中 wilson_sanity = 200，所以默认 100 只是「无角色时的占位」。
    self.max = 100
    self.current = self.max

--   mode 默认 SANITY_MODE_INSANITY（constants.lua:1234，值为 0）。
--   ★ 在 Lua 里 0 是真值，所以这里绝不能写成 if self.mode 判断模式。
	self.mode = SANITY_MODE_INSANITY
--   ★ _lunacy_sources：开悟模式是「有源」的概念，不是布尔开关。
--     用 boolean 型 SourceModifierList 是因为它必须能同时挂多个来源，
--     且来源全部移除后要能自动回落到疯狂模式。
--     这样想：某个装备/能力让你开悟，脱下就自动恢复正常。
	self._lunacy_sources = SourceModifierList(inst, false, SourceModifierList.boolean)

--   rate：当前的「每秒理智变化量」，是整个组件的核心状态变量。
--   ★ 它是导数不是存量。真正改变理智的是 rate*dt（见 :609）。
    self.rate = 0
--   ratescale：rate 的**分档量化结果**（0~6），专供 UI 画箭头。
--   为什么要分档而不是直接显示小数：rate 是个浮点数，每帧抖动，
--   箭头会疯狂闪烁。分档后只有跨越阈值才变，视觉上稳定得多。
    self.ratescale = RATE_SCALE.NEUTRAL
--   ★ rate_modifier：最终的总乘数，在所有分项求和**之后**才乘（:598）。
--     顺序很重要——它要压住的是「总速率」，而不是某一项。
--     实际用途：Willow 因火灾而更容易疯狂，rate_modifier=1.1（prefabs/willow.lua:171）。
    self.rate_modifier = 1
--   sane：见 _replica_setissane 的解释——它存的是「未处于特殊态」。
    self.sane = true
--   fxtime：给 UI/音效用的计时器，本组件内不读，由外部（sanity_fx 之类）写入。
    self.fxtime = 0
--   dapperness：基础「体面度」。它与装备上的 dapperness 相加，
--   最终乘 TUNING.SANITY_DAPPERNESS 得到回理智速率（见 :523）。
--   典型来源：Maxwell 默认带 DAPPERNESS_LARGE（prefabs/waxwell.lua:303）。
    self.dapperness = 0
--   ★ externalmodifiers：外部物品的**加性**理智速率修正。
--     「加性」意味着它直接以「每秒多少点」参与求和（:590），
--     而不是乘一个百分比——这对「每秒 +1.5 理智」这类数值最直观。
--   使用方：components/itemaffinity.lua:44（装备亲和）、
--     prefabs/ancienttree_fruits.lua:539（负向：-DAPPERNESS_MED_LARGE）。
	self.externalmodifiers = SourceModifierList(self.inst, 0, SourceModifierList.additive)
--   以下四个字段是「两对forced 标志 + 各自的来源集合」。
--   ★ 为什么不用 SourceModifierList 而是裸的哈希表？
--     因为 forced 状态需要「显式列出是哪个 source 造成的」以便精准解除，
--     而 SourceModifierList 的 SetModifier/RemoveModifier 也能做到，
--     这里选择裸表是为了在 OnSave 时能枚举（目前未使用，属预留）。
    self.inducedinsanity = nil
    self.inducedinsanity_sources = nil
    self.inducedlunacy = nil
    self.inducedlunacy_sources = nil
--   night_drain_mult：夜间理智流失的角色系数。
--   ★ 写在构造函数里但从不在本文件内被修改——它是留给角色 prefab 的外部接口：
--     prefabs/wendy.lua:368（WENDY_SANITY_MULT=0.75，夜间掉得慢）、
--     prefabs/wolfgang.lua:96-98（分体质两档）。
    self.night_drain_mult = 1

--   ⚠ 已废弃。保留字段是为了兼容老存档/老 mod 直接读写 neg_aura_mult 的写法。
--     新的正确入口是下面的 neg_aura_modifiers（乘性 SourceModifierList）。
    self.neg_aura_mult = 1 -- Deprecated, use the SourceModifier below
--   neg_aura_modifiers：负向光环（depression aura）的乘数。
--   ★ 默认 SourceModifierList 的语义是**乘性**（第4~5 个参数可指定），
--     所以它与externalmodifiers（加性）刻意用不同实例。
    self.neg_aura_modifiers = SourceModifierList(self.inst)
--   neg_aura_absorb：负向光环的「吸收比例」（0~1），0 = 完全不吸收。
--   ★ 与 neg_aura_mult 的区别：mult 是乘性缩放**所有**负光环，
--     absorb 是按比例**抵消**负光环的伤害。
--     典型用途：蜂巢帽抵消 50% 的理智光环（prefabs/hats.lua:2057，
--     TUNING.ARMOR_HIVEHAT_SANITY_ABSORPTION = .5）。
--   使用点在 Recalc 的:570 与 :582（两处几乎相同，见那里的详细说明）。
    self.neg_aura_absorb = 0

	--self.neg_aura_immune = nil --deprecated, use self.neg_aura_immune_sources below
--   neg_aura_immune_sources：完全免疫负向光环。
--   ⚠ 注意与 sanity_aura_immune_sources（:110）的区别：
--     这个只挡「负」的，全免疫那个连帽子带来的正sanity 光环也一起挡掉。
	self.neg_aura_immune_sources = SourceModifierList(inst, false, SourceModifierList.boolean)
--   dapperness_mult：体面度总乘数。
--   ⚠ 疑似缺陷：本文件内**没有任何一处写入它**（全仓库搜索无赋值点），
--     而 :512 用它做 `if self.dapperness_mult ~= 0` 的短路判断。
--     推理依据：默认值 1（真值）使条件恒成立，故当前无害；
--     但若将来有人想「关掉体面度」，会写成 dapperness_mult = 0，
--       此时整个 dapper_delta 分支被跳过——这是**唯一**能关掉它的路径，
--       语义上与「乘数为 0」一致，所以其实不算 bug，只是文档缺失。
--     记录于此以免后人误以为是死代码而删除。
    self.dapperness_mult = 1
--   penalty：0~1 的「理智上限惩罚比例」。由 RecalculatePenalty 统一维护（:199），
--   外部只能通过 AddSanityPenalty / RemoveSanityPenalty 增删条目。
    self.penalty = 0

--   ★ sanity_penalties 是一个「key → 比例」的字典而不是累加变量。
--     为什么要字典：同一个来源可能反复 Add/Remove，
--     若用累加变量必须由调用方自己配对加减，极易漏掉Remove 导致永久扣减。
--     用字典后，key 就是幂等令牌——重复 Add 同key 只是覆盖同一个值。
--   典型来源：Maxwell 的影子仆从按「种类」分别记账，
--     见 prefabs/waxwell.lua:58，key 为小写化后的 prefab 名。
    self.sanity_penalties = {}

--   ghost_drain_mult：幽灵玩家造成的理智抽取倍率，由 RecalcGhostDrain 写入。
--   ★ 初值为 0（= 不受影响），而构造函数末尾 :123 立刻调了一次 RecalcGhostDrain，
--     所以第一帧就是对的——否则刚进世界会闪一下错误图标。
    self.ghost_drain_mult = 0

--   ★ custom_rate_fn：角色自定义速率函数的注入点（最高优先级的扩展口）。
--     它返回的仍是「速率」而非「增量」，所以之后才乘 dt（:609）。
--   使用方：prefabs/willow.lua:170（柳树因火灾额外掉理智）、
--     prefabs/walter.lua:1184。注意 woodie.lua:1200 显式置回 nil，
--     说明角色切换时必须清理——因为组件常驻不销毁。
    self.custom_rate_fn = nil

	--self.sanity_aura_immune = false --deprecated, use self.sanity_aura_immune_sources below
--   ★ sanity_aura_immune_sources：免疫**一切**sanity 光环（含正向）。
--     源码注释说得很清楚：is unaffected by ANY auras。
--   ⚠ 与 :99 的 neg_aura_immune_sources 语义重叠但不等价：
--     前者连「让人变清醒」的光环也挡掉，后者只挡负的。
	self.sanity_aura_immune_sources = SourceModifierList(inst, false, SourceModifierList.boolean) -- is unaffected by ANY auras
--   sanity_aura_immunities：按**标签**分类的部分免疫（如 Wendy 免疫幽灵相关）。
--   ★ 这是个二层结构：{ 标签名 → 该标签的 SourceModifierList }。
--     懒初始化（见 AddSanityAuraImmunity :213），没有免疫需求时不建表。
    --self.sanity_aura_immunities = nil -- protects against specific auras, like Wendy with the ghosts
	--self.player_ghost_immune = false --deprecated, use self.player_ghost_immune_sources below
--   player_ghost_immune_sources：免疫「幽灵玩家」惩罚。
--   ★ 与 ghost_drain_mult 是两条独立路径：
--     前者让 RecalcGhostDrain 直接算出 0（:457），
--     所以 UI 图标也一并消失；二者不是叠加关系。
	self.player_ghost_immune_sources = SourceModifierList(inst, false, SourceModifierList.boolean)

	--self.light_drain_immune = false --deprecated, use self.light_drain_immune_sources below
--   light_drain_immune_sources：免疫光照带来的理智流失（:531）。
--   注意它**不免疫**潮湿与 dapperness，只挡light_delta 这一项。
	self.light_drain_immune_sources = SourceModifierList(inst, false, SourceModifierList.boolean)

--【★★ 三个「上一次的值」—— 边沿触发（edge detection）的缓存】
--   DoDelta 每次都跑（每帧），但「变得疯狂」「变得开悟」这类事件只该在
--   **跨越阈值的那一刻**发一次，否则每帧都会重复 PushEvent。
--   做法：把旧值存下来，下次比较。三个缓存各管一种边沿：
--     _oldissane  —— 正常/异常 翻转（sanity.lua:410）
--     _oldpercent —— 给外部算增量用（sanity.lua:405、:408）
--     _oldmode    —— 模式切换时也要补发状态事件（sanity.lua:410）
--   ★ 必须在 StartUpdatingComponent **之前**初始化完成，
--     否则第一次 Recalc 会拿 nil 与布尔值比较而误触发事件。
    self._oldissane = self:IsSane()
    self._oldpercent = self:GetPercent()
	self._oldmode = self.mode

--   ★ StartUpdatingComponent：注册进主循环的每帧更新队列。
--     对应本组件的 Sanity:OnUpdate（:437）。
--   参见 entityscript.lua 的 StartUpdatingComponent 与 update.lua 的更新循环。
--   为什么不用 DoPeriodicTask（hunger 的做法）：
--     光照值 LightWatcher 每帧都在变，节拍化会导致速率积分产生锯齿。
    self.inst:StartUpdatingComponent(self)
--   构造期立即算一次幽灵倍率，保证 UI 首次刷新时数据已正确。
    self:RecalcGhostDrain()
end,
nil,
--【★ Class 的第三个参数：属性 setter 表】
--   格式为 { 字段名 = setter 函数 }。此后所有 self.字段 = 值 的写入
--   都会自动调用对应 setter，实现「数据变更即同步」。
--   ★ 这是本文件所有 onXXX 函数存在的唯一理由——
--     把「改一个字段」和「把它推给客户端」绑定，杜绝漏同步的 bug。
--   同时它也意味着 setter 会在**构造期间**被触发（因为构造函数里逐个赋值），
--     所以这些函数内部一律不能假设 replica 已就绪 ——
--     这就是为什么 onmax（:22）等函数体内没有 nil 检查也能跑。
{
--   依次是：max / current / ratescale / mode / sane /
--         inducedinsanity / inducedlunacy / penalty / ghost_drain_mult。
    max = onmax,
    current = oncurrent,
    ratescale = onratescale,
	mode = onmode,
    sane = onsane,
    inducedinsanity = oninducedinsanity,
    inducedlunacy = oninducedlunacy,
    penalty = onpenalty,
    ghost_drain_mult = onghostdrainmult,
})

--【★ IsSane：唯一的「对外语义翻译」入口】
--   前面所有 _replica_setissane 的换算逻辑，这里是权威版本；
--   replica 侧读的是网络 bool（sanity_replica.lua:201），
--   两者必须保持一致，否则会出现「UI 说正常但实际在疯狂」。
function Sanity:IsSane()
--   两个分支除 forced 标志的名字互换外完全对称——见 :13 的说明。
	if self.mode == SANITY_MODE_INSANITY then
		return self.sane and not self.inducedinsanity or self.inducedlunacy or false
	else--if self.mode == SANITY_MODE_LUNACY then
		return self.sane and not self.inducedlunacy or self.inducedinsanity or false
	end
end

--【IsInsane：只关心「在疯狂模式下是否崩溃」】
--   ★ 注意末尾的 and not self.inducedlunacy：
--     被强制开悟的人，即使在疯狂模式下，也不算 IsInsane ——
--     因为开悟的表现会完全覆盖疯狂。这与 IsSane 的优先级一致。
function Sanity:IsInsane()
	return self.mode == SANITY_MODE_INSANITY and (not self.sane or self.inducedinsanity) and not self.inducedlunacy
end

--   IsEnlightened：IsInsane 的镜像（开悟模式 + 崩溃态）。
function Sanity:IsEnlightened()
	return self.mode == SANITY_MODE_LUNACY and (not self.sane or self.inducedlunacy) and not self.inducedinsanity
end

--   IsCrazy：早期版本的接口，已废弃。保留是为了不破坏老 mod。
function Sanity:IsCrazy()
	-- deprecated
    return self:IsInsane()
end

--   SetSanityMode：已废弃的空函数。
--   ⚠ 它**不是**真的无害：若某个 mod 调它来切模式，
--     不会有任何报错，但也不会生效——属于静默失败。
--     正确入口是 EnableLunacy（:184）。
function Sanity:SetSanityMode(mode)
	-- Deprecated
end

--   下面两个是 mode 的直接判定，IsInsanityMode 比 `mode == SANITY_MODE_INSANITY`
--   更可读，且未来若加第三种模式只需改这里。
function Sanity:IsInsanityMode()
	return self.mode == SANITY_MODE_INSANITY
end

function Sanity:IsLunacyMode()
	return self.mode == SANITY_MODE_LUNACY
end

function Sanity:GetSanityMode()
	return self.mode
end

--【★ UpdateMode_Internal：模式切换的唯一实际执行点】
--   ★ 为什么每帧都要调（见 OnUpdate :438）而不是在 EnableLunacy 里调一次：
--     源码注释直接给了原因 ——「since we may not know when lunacy sources
--     are removed」。来源可以被外部随意置空（如装备被销毁），
--     组件无法收到通知，只能靠每帧轮询 SourceModifierList 的变化。
--   代价是每帧一次哈希表查找，相对整个 Recalc 可忽略。
function Sanity:UpdateMode_Internal()
	local mode = self._lunacy_sources:Get() and SANITY_MODE_LUNACY or SANITY_MODE_INSANITY
	if self.mode ~= mode then
		self.mode = mode
		self.inst:PushEvent("sanitymodechanged", { mode = self.mode })
--   ★ DoDelta(0)：传 0 增量，借这次调用把「模式已变」同步出去，
--     因为 onmode（:38）需要新的 mode 才能算对 sane。
--     这是一种「用正常流程顺带完成状态同步」的技巧，写法上很巧。
		self:DoDelta(0)
	end
end

--【EnableLunacy：开悟模式的唯一对外入口】
--   ★ 形参是 enable 而非「设成某状态」，配合 source 做引用计数：
--     两个来源同时要开悟时，任一撤销都**不会**退出开悟模式。
--     这是 boolean 型 SourceModifierList 的核心价值。
--   第二个参数 source 通常传 inst 自身（生成器 ID），见 :185。
function Sanity:EnableLunacy(enable, source)
	self._lunacy_sources:SetModifier(self.inst, enable, source)
	self:UpdateMode_Internal()
end

--【★★AddSanityPenalty：代价机制的写入端】
--   ★ 签名是 (key, mod) —— mod 是**比例**不是点数。
--     例如 waxwell.lua:58 传入 TUNING.SHADOWWAXWELL_SANITY_PENALTY[种类] = .2，
--     含义是「带 1 个该影子，理智上限降 20%」。
--     用比例而非点数，是为了在 max 因角色而异时仍有一致的手感。
function Sanity:AddSanityPenalty(key, mod)
--   ★ 覆盖式写入：同一个 key 再次 Add 会替换旧值而非累加。
--     所以waxwell.lua 里用pet 作为 key 传进来是安全的。
    self.sanity_penalties[key] = mod
    self:RecalculatePenalty()
end

--   Remove：删key 后立刻重算，保证「摘掉最后一个影子立刻恢复上限」。
function Sanity:RemoveSanityPenalty(key)
    self.sanity_penalties[key] = nil
    self:RecalculatePenalty()
end

--【RecalculatePenalty：把所有 penalty 条目折算成一个 0~1 的比例】
--   ★ 每次增删都全量重算（而不是增量加减）——
--     因为字典的遍历顺序不确定，增量法在「同一 key 重复覆盖」时必然算错。
--     条目数量极少（个位数），全量重算的代价可忽略，
--     换来的是「不可能算错」，这是典型的正确性优先取舍。
function Sanity:RecalculatePenalty()
    local penalty = 0

    for k,v in pairs(self.sanity_penalties) do
        penalty = penalty + v
    end

--   ★★ 上限约束：players cannot go lower than 5 max sanity。
--     硬底线是「无论代价叠多少，理智上限至少 5 点」，
--     换算成比例就是 1 - 5/max（max 通常 200，故为 0.975）。
--   ★ 设计意图（源码注释也解释了）：
--     被 min() 截断后，实际 penalty 会**小于**调用方累加出来的总和。
--     于是「上限被截断了，就说明还得继续移除若干条目才降得回来」——
--     换句话说，惩罚到了顶，移除的收益也会随之递减，形成天然的平衡。
--   参见 tuning.lua:2162 的 MAXIMUM_SANITY_PENALTY = 0.9：
--     那是**建造/生成时**的准入门槛（waxwelljournal.lua:134），
--     与这里的 1-5/max 是两套不同的限制，不要混淆。
    -- players cannot go lower than 5 max sanity. The sanity_penalties penalty will actually go beyond,
    -- so they will still have to remove enough sanity_penalties to get back above the 5 max sanity cap
--   ⚠ 疑似缺陷（边界）：这里直接除以 self.max，未做 max <= 5 的防护。
--     推理依据：若 max 被设成小于 5（SetMax 允许传任意值，:312），
--       1-5/max 将变成负数，min() 会得到负 penalty，
--       于是 GetMaxWithPenalty（:323）返回 > max 的「上限」，
--       反而让玩家理智变多。
--     实际影响：极低——所有角色 max 都远大于 5（Wilson 200），
--       且这条路径需外部主动传小值才能触发。
--     ★ 但它揭示了一个真实约束：本组件默认 max 必须 > 5，
--       构造函数里的默认 100 是安全的。
    self.penalty = math.min(penalty, 1-(5/self.max))

--   同样借 DoDelta(0) 把新的上限同步出去。
    self:DoDelta(0)
end

--【按标签的部分光环免疫 ——懒初始化 + 两级收缩】
--   与 :110 的「全免疫」不同，这里是「只免疫带某个 tag 的光环」，
--   典型需求：Wendy 只免疫「幽灵」类光环，但帽子带来的正面光环照吃。
function Sanity:AddSanityAuraImmunity(tag, source)
--   ★ 两级懒初始化：整张表不存在时才建；某个 tag 的 SourceModifierList
--     也不存在时才建。绝大多数实体一生都不会用到，所以必须懒。
	local sources
	if self.sanity_aura_immunities == nil then
		self.sanity_aura_immunities = {}
	else
		sources = self.sanity_aura_immunities[tag]
	end
--   首次为该 tag 创建免疫列表。参数 (inst, false, boolean) 分别是：
--     inst —— 归属实体（SourceModifierList 需要它来触发事件）；
--     false —— 初值为「无免疫」；
--     boolean —— 取值模式：多个来源做「或」运算，全移除才回false。
	if sources == nil then
		sources = SourceModifierList(self.inst, false, SourceModifierList.boolean)
		self.sanity_aura_immunities[tag] = sources
	end
--   source or self.inst：允许外部指定「谁提供的免疫」，
--     不指定就记在实体自己名下。
	sources:SetModifier(source or self.inst, true)
end

--   Remove 的对称实现，同样做两级收缩（:232-237）。
--   ★ 注意它是**在 RemoveSanityAuraImmunity 时清理**，
--     而 Recalc 里（:552-564）也有一份相同的清理逻辑——
--     那里是因为实体的 tag 可能被外部改掉，必须每帧重新校验。
function Sanity:RemoveSanityAuraImmunity(tag, source)
	if self.sanity_aura_immunities then
		local sources = self.sanity_aura_immunities[tag]
		if sources then
			sources:RemoveModifier(source or self.inst)
			if not sources:Get() then
				self.sanity_aura_immunities[tag] = nil
				if next(self.sanity_aura_immunities) == nil then
					self.sanity_aura_immunities = nil
				end
			end
		end
	end
end

--下面四个是「一次性开关」式免疫，接口刻意做成对称的SetXxxImmunity：
--   之所以不合并成一个带枚举参数的函数，是为了调用处可读性——
--     SetLightDrainImmune 比 SetImmunity(IMMUNITY_LIGHT_DRAIN) 直观得多。
function Sanity:SetFullAuraImmunity(immunity, source)
	self.sanity_aura_immune_sources:SetModifier(source or self.inst, immunity)
end

function Sanity:SetNegativeAuraImmunity(immunity, source)
	self.neg_aura_immune_sources:SetModifier(source or self.inst, immunity)
end

--   SetPlayerGhostImmunity：屏蔽幽灵玩家惩罚（配合 RecalcGhostDrain :457）。
function Sanity:SetPlayerGhostImmunity(immunity, source)
	self.player_ghost_immune_sources:SetModifier(source or self.inst, immunity)
end

--   SetLightDrainImmune：屏蔽光照衰减（配合 Recalc :531）。
--   ★ 注意屏蔽的是「光照这一项」，潮湿惩罚（:526）与体面度回血仍然生效。
function Sanity:SetLightDrainImmune(immunity, source)
	self.light_drain_immune_sources:SetModifier(source or self.inst, immunity)
end

--【★ OnSave：只存三样东西，且刻意「少存」】
--   存：current（当前理智）、sane（是否正常）、mode（疯狂/开悟）。
--   ★ 不存：penalty / inducedinsanity / inducedlunacy / dapperness / 所有修饰器。
--     理由：这些都是「由世界状态与装备推导出来的」，
--     存档后角色 prefab 的 OnSpawn 会重新装配一遍（见 waxwell.lua:58、
--     willow.lua:170-171），若同时存档就会双重施加。
--     ★ 这是组件存档的通用原则：**只存不可推导的内部状态**。
--     参见 hunger.lua:177 的同类取舍（那里更进一步，满值时存 nil）。
function Sanity:OnSave()
    return
    {
        current = self.current,
        sane = self.sane,
        mode = self.mode,
    }
end

--【OnLoad：注意「赋值顺序」与「不触发 setter」】
--   ★ 关键：这里直接写 self.sane / self.current，
--     由于 Class 属性表（:126）会拦截赋值，**其实会触发 setter**——
--     于是加载时就会把状态推给 replica。
--     但 onmode（:38）在这里**没有**被调用，因为 mode 是在 self.sane 之后
--     才赋值的；所幸紧接着的 DoDelta(0)（:276）会把 sane 一起补同步。
--   ⚠ 疑似缺陷：若 data.current 为 nil（:274），则不会调 DoDelta(0)，
--     此时 OnLoad 里 self.sane = data.sane 触发的 onsane（:44）
--     读到的 self.mode 仍是构造函数里的默认值，而非存档的 mode。
--     推理依据：onsane → _replica_setissane(... self.mode ...) 要求 mode 正确。
--     实际影响：几乎为零——OnLoad 里 current 与 sane 通常成对存在。
function Sanity:OnLoad(data)
    if data.sane ~= nil then
        self.sane = data.sane
    end

--   mode 的默认值 0 即 SANITY_MODE_INSANITY（constants.lua:1234）。
--   ★ 同样是靠「0 是真值」的反直觉性：这里用 `or 0` 兜底是因为
--     mode 为 nil 时才走默认，而 nil 才是假值。
    self.mode = data.mode or 0

    if data.current ~= nil then
        self.current = data.current
--   借 DoDelta(0) 触发一次 sanitydelta 事件，
--     让 UI/音效在读档后立刻同步，而不是等下一帧 Recalc。
        self:DoDelta(0)
    end
end

--【★★百分比家族：四个函数，两两成对，是本文件最易误用的 API】
--
--   GetRealPercent()        = current / max
--     「裸」比例。完全无视 penalty 与两个 forced 标志。
--     用途：内部计算、以及「这个比例到底是多少」的真实查询。
--
--   GetPercent()            = forced 覆盖后的比例
--     给 UI 显示用。forced 疯狂 → 0；forced 开悟 → 1-penalty。
--     ★ 注意分母始终是 max（**不是**惩罚后的上限），
--       所以带penalty 的玩家满血时 GetPercent() 只有 0.975，
--       而不是 100% —— 这是刻意的：让玩家看见自己「上限被压了」。
--
--   GetPercentWithPenalty() = current / (max - max*penalty)
--     「相对有效上限」的比例。同样无视 forced 标志，
--       但 forced 开悟时直接返回 1（满），与 GetPercent 的 1-penalty 不同。
--     ★ 这个函数才是「惩罚之下我还有多少血」的答案。
--
--   GetMaxWithPenalty()     = max - max*penalty
--     有效上限本身。
--
--   ⚠ 四个函数对 forced 标志的处理各不相同（两个无视、两个覆盖），
--     这不是疏漏而是各有用处，但调用方必须清楚选哪个。
function Sanity:GetPenaltyPercent()
    return self.penalty
end

function Sanity:GetRealPercent()
    return self.current / self.max
end

--   ★ 这里的 `and / or` 链实现了「优先级短路」：
--     inducedinsanity 为真 → 整个表达式短路为 0（且不再看 penalty）；
--     否则看 inducedlunacy → 1 - penalty；
--     都为假 → 退回 GetRealPercent()。
--     这与 _replica_setcurrent（:4）的三段优先级完全对应。
function Sanity:GetPercent()
	--NOTE: (self.inducedlunacy and self.inducedinsanity) ==> 0
    return (self.inducedinsanity and 0)
		or (self.inducedlunacy and 1 - self.penalty)
        or self:GetRealPercent()
end

--   ★ 注意 forced 开悟时返回 1 而非 1-penalty（与 :291 不同）。
--     推理依据：开悟是「更高层级」的表现，即便上限被压也应显示为满，
--     否则会出现「已开悟但血条不满」的割裂感。属于有意的层级优先。
function Sanity:GetPercentWithPenalty()
	--NOTE: (self.inducedlunacy and self.inducedinsanity) ==> 0
    return (self.inducedinsanity and 0)
        or (self.inducedlunacy and 1)
--   分母是 GetMaxWithPenalty 的等价表达式（:324）——
--     此处内联而非调用，是为了避免在每帧路径上多一次函数调用。
--     ★ 这也是上面 GetPercent 返回 0.975 的原因：
--       分子封顶在 max*(1-penalty)，分母是 max，比值自然上不去 1。
        or self.current / (self.max - (self.max * self.penalty))
end

--【★ SetPercent：外部「按比例设置理智」的标准入口】
--   ★ 用 target - current 求差再走 DoDelta，而不是直接赋值。
--     原因：DoDelta 会夹逼（:387）、跑阈值判定（:391）、
--     发事件（:405）。直接赋值会绕过全部这些逻辑，导致 UI 不刷新。
--     所有外部改理智的代码都应走它，参见 prefabs/waxwell.lua:135。
function Sanity:SetPercent(per, overtime)
--   ★ 分母用 max 而非有效上限：
--     传入 1.0 表示「填满原始上限」，而 DoDelta 会再夹逼到惩罚后的上限。
--     两段配合的净效果是「SetPercent(1) 总是尽可能填满」，符合直觉。
    local target = per * self.max
    local delta = target - self.current
    self:DoDelta(delta, overtime)
end

function Sanity:GetDebugString()
    return string.format("%2.2f / %2.2f at %2.4f. Penalty %2.2f, Mode %s", self.current, self.max, self.rate, self.penalty, self.mode == SANITY_MODE_INSANITY and "INSANITY" or "LUNACY")
end

--   SetMax 同时把 current 也设成 amount ——
--   ★ 这是刻意的「满血换装」语义：换角色/换上限时不希望半血。
--     副作用：无法「只改上限不改当前值」，若将来需要，得另开接口。
function Sanity:SetMax(amount)
    self.max = amount
    self.current = amount
    self:DoDelta(0)
end

--   SetCurrent：直接指定绝对值。注意它**不做夹逼**，
--   但随后的 DoDelta(0) 会把值夹到 [0, 有效上限]（:387）。
--   ★ 与 SetMax 的区别：这里没有连带改 max。
function Sanity:SetCurrent(amount)
    self.current = amount
    self:DoDelta(0)
end

--   GetMaxWithPenalty：与 GetPercentWithPenalty（:299）的分母同源。
function Sanity:GetMaxWithPenalty()
    return self.max - (self.max * self.penalty)
end

function Sanity:GetRateScale()
    return self.ratescale
end

--【★★ SetInducedInsanity：引用计数式forced 标志】
--   ★ 它不用 SourceModifierList，而是裸哈希表 { [src] = true }，
--     因为需要「任一来源移除就清除最后一个则回落」的语义。
--     src 通常是施加效果的道具实体（prefabs/amulet.lua:117传 inst）。
--   用道具实体做 key 还有个好处：道具被销毁时若调用方忘了传 false，
--     至少哈希表不会泄漏道具引用（bool值不持有引用）。
function Sanity:SetInducedInsanity(src, val)
    if val then
        if self.inducedinsanity_sources == nil then
            self.inducedinsanity_sources = { [src] = true }
        else
            self.inducedinsanity_sources[src] = true
        end
--   移除分支。注意与添加分支的**不对称**：
--   ⚠ 疑似缺陷（极轻微）：添加分支（:332-337）没有把 val 强制置 true，
--     完全依赖调用方传入的 val；移除分支却在 :342/:344 显式改写了 val。
--     推理依据：若调用方以 val=1（真值但非 true）调用添加，
--       self.inducedinsanity 会变成 1 而非 true；
--       再以 val=0 移除时，:347 的 `1 ~= nil` 成立，仍能正确翻转。
--       实际无害，但两分支写法不对称，属风格瑕疵。
    elseif self.inducedinsanity_sources ~= nil then
        self.inducedinsanity_sources[src] = nil
--   最后一个来源被移除 → 把整张表置 nil 并把 val 回落为 nil（假值）。
--   ★ 用 next() 检测「表是否空」，这是 Lua 里判断哈希表清空的标准写法。
        if next(self.inducedinsanity_sources) == nil then
            self.inducedinsanity_sources = nil
            val = nil
        else
            val = true
        end
    end
--   ★ 只有「布尔值真正翻转」才做事——这是 forced 标志的幂等保证：
--     重复用同一个 src 调Set(true) 不会重复触发 DoDelta 与 PushEvent。
    if self.inducedinsanity ~= val then
        self.inducedinsanity = val
        self:DoDelta(0)
--   推inducedinsanity 事件供外部（如 UI 图标）响应。
        self.inst:PushEvent("inducedinsanity", val)
    end
end

--   SetInducedLunacy：与 SetInducedInsanity 逐行对称。
--   两个函数没有抽公共逻辑，是可读性优先的取舍（复制优于错误抽象）。
--
--   ★★ 与 SetInducedInsanity（:331）的区别只有两处：
--     ① 操作的字段不同（本函数动 self.inducedlunacy，:371）；
--     ② 推的事件不同（本函数推 "inducedlunacy"，:373）。
--     其余的引用计数、幂等保证、边沿触发全部同构。
--
--   ★★ 一个重要的语义辨析（极易混淆）：
--     inducedlunacy（被外力强制开悟，本函数）≠ lunacy 模式（:175）。
--       · 模式是全局的玩法分支，由 _lunacy_sources 决定，
--         会改变整套光照数值表（:468），影响极大；
--       · forced 开悟只是「显示层覆盖」，真实理智照常流动（:55），
--         不改变任何速率计算。
--     ★ 举例：戴上强制开悟的帽子，GetPercent() 会显示 1-penalty，
--       但此时若处于疯狂模式，实际承受的仍是疯狂模式的光照惩罚。
--       两套系统完全正交。
--
--   ★ 使用方：prefabs/hats.lua:3387（某顶帽子赋予开悟）。
--   对应的 insanity 版本见 prefabs/amulet.lua:117 与 hats.lua:2855。
--
--   ⚠ 引用计数的一个隐含前提：调用方传回的 src 必须与Add 时**同一个对象**。
--     因为这是按值（对象引用）做键的哈希表，不是按 prefab 名。
--     推理依据：若src 换成一个等效的新实体，
--       RemoveSanity 找不到原键，会造成 forced 状态永久残留。
--       现有调用方（amulet / hats）都传同一个 inst，行为正确。
function Sanity:SetInducedLunacy(src, val)
    if val then
        if self.inducedlunacy_sources == nil then
            self.inducedlunacy_sources = { [src] = true }
        else
            self.inducedlunacy_sources[src] = true
        end
    elseif self.inducedlunacy_sources ~= nil then
        self.inducedlunacy_sources[src] = nil
        if next(self.inducedlunacy_sources) == nil then
            self.inducedlunacy_sources = nil
            val = nil
        else
            val = true
        end
    end
--   ★ 边沿检测：只有布尔值真正翻转才做事，保证幂等。
--     重复 SetLunacy(inst, true) 不会重复发事件或重复 DoDelta。
    if self.inducedlunacy ~= val then
        self.inducedlunacy = val
--   ★ DoDelta(0) 借道全量同步：forced 状态变了，
--     必须让 replica 重新算一次显示值（走 _replica_setcurrent 的覆盖链）。
--     与 :349 完全对称。
        self:DoDelta(0)
--   推 inducedlunacy 事件。
--   ⚠ 注意与 UpdateMode_Internal（:179）推的 sanitymodechanged 是
--     两个不同事件：前者是「被强制」，后者是「模式真的切了」。
--     UI 若只想响应玩法变化，应监听 sanitymodechanged 而非本事件。
        self.inst:PushEvent("inducedlunacy", val)
    end
end

--【★★★★★ DoDelta：理智值唯一的写入口 —— 阈值判定与事件都在这里】
--   全文件最关键的一个函数。职责链条：
--     ① 两个提前退出通道（redirect / ignore）
--     ② 夹逼到 [0, 有效上限]
--     ③ sane 标志的双模式阈值判定（带迟滞）
--     ④ 推sanitydelta 事件（含 oldpercent / newpercent / overtime）
--     ⑤ 边沿检测 → gosane / goinsane / goenlightened
--   ★ 它被大量地方以 delta=0 调用，目的不是改数值，
--     而是「借这次机会把状态重新广播一遍」。
function Sanity:DoDelta(delta, overtime)
--   ① 通道一：redirect。把「数值变化」整个外包给外部，
--   ★ 典型用途是 mod 用「另一个数值系统」接管理智（如改成恐惧值）。
--     一旦 redirect 存在，本函数后续逻辑（含夹逼与事件）**全部不执行**，
--     责任完全转移——所以 redirect 的实现方必须自己发事件。
--   对比 hunger.lua:129 的同款设计，两者保持一致。
    if self.redirect ~= nil then
        self.redirect(self.inst, delta, overtime)
        return
    end

--   ② 通道二：ignore。静默忽略所有 delta，连事件都不发。
--   ★ 与 redirect 的区别：ignore 仍会「什么都不做」而 redirect 是「交给别人做」。
--   ignore 通常由外部（剧情/过场）临时置位；
--     OnUpdate（:444）也用它做短路，防止白算一整个 Recalc。
    if self.ignore then
        return
    end

--   ★★ 夹逼到 [0, max - max*penalty]。
--     注意这是**唯一**把 penalty 落到「真实数值」上的地方：
--       所有倍率、所有外部 delta 都会被这道墙拦住，
--       所以带代价机制的角色永远不可能靠吃东西把理智刷回满。
--   这是「代价」在数值层面的最终 enforcement。
    self.current = math.min(math.max(self.current + delta, 0), self.max - (self.max * self.penalty))

--   ★★ 必须用裸的 current/max 算比例，不能用 GetPercent()。
--   源码注释：must calculate it due to inducedinsanity。
--   原因：forced 疯狂时 GetPercent() 恒为 0，
--     若拿它做阈值判定，被强制疯狂的人会立刻被判成 insane，
--     解除强制后又要经历一次迟滞上升——状态来回抖动。
--   ★ 这是「forced 只影响显示、不影响真实状态」这一设计的关键守卫。
    -- must calculate it due to inducedinsanity ...
    local percent_ignoresinduced = self.current / self.max
--   ★★★ 阈值判定 —— 全游戏理智系统的核心规则。
--   两个模式各有一对阈值，且都是**迟滞（hysteresis）**设计：
--
--     INSANITY 模式（tuning.lua:2176-2177）：
--       崩溃：percent <= 30/200 = 0.15
--       恢复：percent >= 35/200 = 0.175
--       → 15% 崩溃、17.5% 恢复，中间5 个百分点是「缓冲带」。
--
--     LUNACY 模式（tuning.lua:2179-2180）：
--       开悟：percent >= 170/200 = 0.85
--       脱离：percent <= 165/200 = 0.825
--       → 85% 开悟、82.5% 脱离，方向相反（开悟要「高」，疯狂要「低」）。
--
--   ★★ 为什么必须留缓冲带：若两个阈值相等，
--     理智恰好停在线上时，每帧的微小浮动都会让 sane反复翻转，
--     造成疯狂音效/滤镜每秒闪一次（flapping）。缓冲带让状态「粘住」。
	if self.mode == SANITY_MODE_INSANITY then
--   ⚠ 重要事实修正：阈值是 15%，**不是 1/3（33%）**。
--   TUNING.SANITY_BECOME_INSANE_THRESH = 30/200（tuning.lua:2177）。
--   分子 30 与分母 200 里的 200 是「设计基准理智值」，
--     而非角色真实 max（Wilson 也是 200，但角色各异）。
--     所以判定用的是**比例**而不是绝对点数——换角色时手感一致。
		if self.sane and percent_ignoresinduced <= TUNING.SANITY_BECOME_INSANE_THRESH then --30
			self.sane = false
--   迟滞的对侧：需要涨到 0.175 才算恢复。
--   ⚠ 这意味着在 0.15~0.175 区间内玩家处于「已崩溃但正在回升」的灰态，
--     此时 sanity 继续扣会直接维持崩溃状态。属于有意设计。
		elseif not self.sane and percent_ignoresinduced >= TUNING.SANITY_BECOME_SANE_THRESH then --35
			self.sane = true
		end
	else
--     LUNACY 模式的判定方向与上面相反：理智**够高**才开悟。
--     ★ 所以开悟是靠「白天+ 光环」堆出来的，天然与「夜晚挨饿掉理智」互斥。
		if self.sane and percent_ignoresinduced >= TUNING.SANITY_BECOME_ENLIGHTENED_THRESH then
			self.sane = false
--     开悟模式的迟滞对侧：掉到 0.825 以下才脱离开悟。
		elseif not self.sane and percent_ignoresinduced <= TUNING.SANITY_LOSE_ENLIGHTENMENT_THRESH then
			self.sane = true
		end
	end

--   ★★ 每次 DoDelta 都推sanitydelta（含 delta=0 的空转调用）。
--     载荷里的 overtime 标记「这次变化是不是持续性伤害」，
--       供 UI 决定用哪种动画（渐变 vs 瞬跳）。
--     sanitymode 也一并带上，因为开悟/疯狂下同一个百分比
--       的视觉含义完全不同。
--   下游消费者：screens/playerhud.lua、components/colourcube.lua:342、
--     prefabs/hats.lua:3571、prefabs/horrorfuel.lua:60。
    self.inst:PushEvent("sanitydelta", { oldpercent = self._oldpercent, newpercent = self:GetPercent(), overtime = overtime, sanitymode = self.mode })

--   ★ 重新取一次 GetPercent——因为 sanitydelta 的监听者
--     「有可能反过来改了理智」（例如吃到理智食物后同步更新 UI）。
--     这行注释道出了事件驱动的经典陷阱：
--       事件参数是在修改前算的，若被回调改动了状态，参数就过时了。
--   所以 _oldpercent 必须用**事后**的值，否则下一帧的增量会算错。
    -- Re-call GetPercent on the slight chance that "sanitydelta" changed it.
    self._oldpercent = self:GetPercent()

--   ★★ 边沿检测：只在「是否正常」翻转，或「模式变了且当前不正常」时触发。
--     第二个条件 (not self._oldissane and self.mode ~= self._oldmode) 处理：
--       玩家本已崩溃，此时模式从疯狂切成开悟 —— 需要补发一次
--       goenlightened 让 UI 从「疯狂滤镜」切到「开悟滤镜」，
--       否则画面会卡在错误状态直到下次恢复清醒。
--   ★ 这正是 :180 那句 DoDelta(0) 的价值所在：
--     模式一变就立刻借DoDelta 把这条路径走一遍。
	if self:IsSane() ~= self._oldissane or (not self._oldissane and self.mode ~= self._oldmode) then
        self._oldissane = self:IsSane()
--   分支一：恢复正常 → 触发 onSane 回调 + gosane 事件。
--   ★ onSane/onInsane/onEnlightened 是「留给外部的回调钩子」，
--     它们由 prefab 挂上去（如 prefabs/willow.lua 的 onInsane），
--     用于播放动画/音效。这是本文件与业务逻辑解耦的接缝。
        if self._oldissane then
            if self.onSane ~= nil then
                self.onSane(self.inst)
            end
--   gosane：恢复正常的对外事件。客户端侧由 sanity_replica.lua:36 重发一份，
--   所以各端UI 能各自响应而不必等网络同步。
            self.inst:PushEvent("gosane")
--   ProfileStatsSet：写入 Steam 成就统计（went_sane / went_insane /
--     went_enlightened，:424与 :430 同理）。成就系统靠这三个事件。
            ProfileStatsSet("went_sane", true)
        else
--   ★ 分支二：崩溃。但要区分是「疯狂」还是「开悟」——
--     因为两者的表现、事件、成就完全不同。
			if self.mode == SANITY_MODE_INSANITY then
				if self.onInsane ~= nil then
					self.onInsane(self.inst)
				end
				self.inst:PushEvent("goinsane")
				ProfileStatsSet("went_insane", true)
--   LUNACY 模式下的同类崩溃，语义上是「开悟」而非「疯狂」。
			else --self.mode == SANITY_MODE_LUNACY
				if self.onEnlightened ~= nil then
					self.onEnlightened(self.inst)
				end
				self.inst:PushEvent("goenlightened")
				ProfileStatsSet("went_enlightened", true)
			end
        end
    end
--   ★ _oldmode 在函数最末尾统一更新，而不是在各分支里更新。
--     这样无论走哪个分支，缓存都保持一致——
--     避免了「某条新分支忘了更新缓存」这类易错点。
	self._oldmode = self.mode
end

--【★★★ OnUpdate：每帧驱动 —— 为什么 sanity 必须每帧更新】
--   对比 hunger.lua:38 的 DoPeriodicTask(UPDATE_PERIOD=1, ...)：
--     hunger 每秒算一次就够了——饥饿是匀速的，1 秒粒度的误差肉眼不可见。
--     sanity 不行：它要读光照（LightWatcher 每帧变）、潮湿（每帧变）、
--           aura（怪物随时进出范围 20 格）。若节拍到 1 秒，
--           速率积分会出现明显锯齿，且阈值判定（:391）会被延迟最多 1 秒。
--   所以 sanity 走 StartUpdatingComponent 的每帧队列（:122），
--     hunger 走周期任务。这是两个组件最根本的架构分歧。
--
--   ⚠ 注意 dt 是本帧时长（秒）。游戏的「正常帧」是 1/30 秒，
--     掉帧时 dt 变大，所以 OnUpdate 里的积分天然是「按真实时间」的，
--     不受帧率影响——这也是 :609 用 rate*dt 而非 rate*固定值的原因。
function Sanity:OnUpdate(dt)
--   ★ 每帧先轮询开悟来源（:175）。
--     放在最前面是有意的：若本帧刚切成开悟模式，
--     后续 Recalc（:510）读 LIGHT_SANITY_DRAINS[self.mode]（:528）
--     就能立刻拿到新模式的那一套数值表，当帧生效，无需等下一帧。
	self:UpdateMode_Internal() --since we may not know when lunacy sources are removed

--【★ 「本帧是否要真正结算理智」的总闸门】
--   以下任一条件成立就跳过 Recalc（不改变理智值）：
--     IsInvincible()   —— 无敌（开局保护等）
--     spawnprotection  —— 标签形式的出生保护
--     sg:HasStateTag("sleeping") —— 睡觉中
--       ★ 注释特意说明了原因：sleeping 期间已不再 invincible，
--         但睡着时也不该掉理智，所以要单独判断。
--     is_teleporting   —— 传送中（防止传送前后数值跳变）
--     (self.ignore and self.redirect == nil) —— 外部要求静默；
--       ★注意那个 and self.redirect == nil：redirect 存在时
--         即使 ignore 为真也要继续，因为 redirect 自己要拿到 delta。
--   ⚠ 疑似缺陷（极轻微）：self.inst.sg 可能为 nil（非状态图实体挂了本组件），
--     此时 sg:HasStateTag 会索引 nil 报错。
--     推理依据：本组件通常只挂在有状态图的角色/怪物上；
--       但 :122 对任何实体都可用，理论上存在触发路径。
--       实际影响：未观察到。
    if not (self.inst.components.health:IsInvincible() or
            self.inst:HasTag("spawnprotection") or
            self.inst.sg:HasStateTag("sleeping") or --need this now because you are no longer invincible during sleep
            self.inst.is_teleporting or
            (self.ignore and self.redirect == nil)) then
--   真正的结算入口：Recalc(dt)（:510）—— 全游戏最复杂的数值计算。
        self:Recalc(dt)
    else
--   跳过结算时**仍然**要做两件事，源码注释强调 Always want to update badge。
--   ① 幽灵倍率必须刷新（:448）：玩家上下线会改变倍率，
--     若因为在睡觉/传送而不刷新，图标就会与实际不符。
        --Always want to update badge
        self:RecalcGhostDrain()

--   ★② 把 rate 与 ratescale 归零。
--     源码注释：Disable arrows。
--     为什么要显式归零：ratescale 是有记忆的字段，
--       若不清，玩家在「无敌期间」仍会看到理智在掉的箭头，
--       而实际值一动不动 —— 误导玩家去做无意义的补救。
--     这体现了一个通用 UI 原则：**指示器必须与真实状态严格一致**，
--       哪怕只在「暂时不计算」时也要显式表达。
--   ⚠ 但注意 rate 被直接赋值，而 ratescale 也直接赋值——
--     由于两者都在属性表里（:127-135），赋值会自动同步到 replica。
--     而 rate **不在**属性表里（它是纯本地量，不参与网络同步）。
        --Disable arrows
        self.rate = 0
        self.ratescale = RATE_SCALE.NEUTRAL
    end
end

--【★★ RecalcGhostDrain：按人数算「幽灵玩家」惩罚倍率】
--   场景：多人联机时有房主掉线留下幽灵（ghost player），
--     活着的人会被持续抽理智作为代价。
--   三个提前退出条件：
--     GetGhostSanityDrain(TheNet:GetServerGameMode()) —— 世界设置里没开这项；
--       ★ 函数见 gamemodes.lua:274，读的是 worldsettings 的 ghost_sanity_drain。
--     player_ghost_immune_sources:Get() —— 本人被免疫（:250）。
function Sanity:RecalcGhostDrain()
	if GetGhostSanityDrain(TheNet:GetServerGameMode()) and not self.player_ghost_immune_sources:Get() then
--   从 shard_players 拿全局人数。注意是 **TheWorld.shard**，
--   即这是「跨分片」的统计——同世界不同分片的玩家也算在一起。
        local num_ghosts = TheWorld.shard.components.shard_players:GetNumGhosts()
        local num_alive = TheWorld.shard.components.shard_players:GetNumAlive()
--   ★★ group_resist：人数优势带来的抗性。
--     人越多，每个幽灵的影响越小：group_resist = 1 - ghosts/alive。
--     ⚠ 疑似缺陷（边界）：`num_alive > num_ghosts and ... or 0` 的写法，
--       当 num_alive <= num_ghosts 时返回 0（即「无抗性」）。
--       推理依据：这种情况只可能是「全员都是幽灵」（活人 0），
--         此时也确实不该再算抗性；而且下一行 :462 会用 math.min 兜住，
--         所以不会算出负数。属于「碰巧正确」，不是 bug。
--     ★ 注意 num_alive == 0 时会走 or 0 分支，避免了除零——
--       这是这个三元表达式真正的价值所在。
        local group_resist = num_alive > num_ghosts and 1 - num_ghosts / num_alive or 0

--   ★★★ 最终倍率 = min(幽灵数, 3) * (1 - 抗性²)。
--     两个设计细节：
--     ① math.min(..., TUNING.MAX_SANITY_GHOST_PLAYER_DRAIN_MULT=3)：
--        人海战术无效，幽灵最多按 3 个算。这是防止人数堆叠的硬上限。
--     ② 抗性被**平方**（group_resist * group_resist）：
--        让抗性增长更陡——少量幽灵时几乎不减，
--        幽灵接近活人数量时抗性迅速崩到 0。
--        用平方而非线性，是为了让「团灭边缘」的惩罚来得更突然，
--        强化「快被团灭」的紧张感。
--   具体每秒扣多少在 :588 乘以 TUNING.SANITY_GHOST_PLAYER_DRAIN。
        self.ghost_drain_mult = math.min(num_ghosts, TUNING.MAX_SANITY_GHOST_PLAYER_DRAIN_MULT) * (1 - group_resist * group_resist)
    else
        self.ghost_drain_mult = 0
    end
end

--【★★★ LIGHT_SANITY_DRAINS：按「模式 × 时段」的二维速率表】
--   本文件所有数值都来自 tuning.lua，且**不是常量而是表达式**。
--   默认配置下（tuning.lua:20-29：seg_time=30、day_segs=10、night_segs=2）
--     可算出day_time = 300 秒、night_time = 60 秒。由此（tuning.lua:2182-2194）：
--
--   INSANITY 模式（正常）：
--     DAY=0白天不回理智（旧式 100/(day_time*32) 已被注释掉，
--        改成 0 意味着「白天必须靠 dapperness/光环主动回」，见 tuning.lua:2182）
--     NIGHT_LIGHT = NIGHT_MID = -100/(60*20) = -0.083/秒
--        ★ 有光与微光**数值完全相同**——这一档已被有意抹平，
--          意味着「有火把」和「勉强看得见」对理智是一回事。
--     NIGHT_DARK = -100/(60*2) = -0.833/秒 ← 全黑，10 倍惩罚
--        ★ 这就是「摸黑赶路危险」的数值来源：全黑时 200 点理智
--          仅能支撑约 240 秒（4 分钟）夜路。
--
--   LUNACY 模式（开悟）：
--     DAY = +100/(300*32) = +0.0104/秒 ← 唯一能回理智的路
--     NIGHT_LIGHT = NIGHT_MID = 0 ← 夜间有光不惩罚
--     NIGHT_DARK = -100/(60*10) = -0.167/秒 ← 比疯狂模式轻 5 倍
--     ★ 设计意图清晰：开悟模式把「黑暗惩罚」大幅削弱，
--       鼓励玩家用开悟角色摸黑探索，代价是不能靠光照抵消白天的亏空。
local LIGHT_SANITY_DRAINS =
{
	[SANITY_MODE_INSANITY] = {
		DAY = TUNING.SANITY_DAY_GAIN,
		NIGHT_LIGHT = TUNING.SANITY_NIGHT_LIGHT,
		NIGHT_DIM = TUNING.SANITY_NIGHT_MID,
		NIGHT_DARK = TUNING.SANITY_NIGHT_DARK,
	},
	[SANITY_MODE_LUNACY] = {
		DAY = TUNING.SANITY_LUNACY_DAY_GAIN,
		NIGHT_LIGHT = TUNING.SANITY_LUNACY_NIGHT_LIGHT,
		NIGHT_DIM = TUNING.SANITY_LUNACY_NIGHT_MID,
		NIGHT_DARK = TUNING.SANITY_LUNACY_NIGHT_DARK,
	},
}

--   GetAuraMultipliers：负向光环的总乘数。
--   ★ 注意它把已废弃的 neg_aura_mult（:94）也乘了进去——
--     为了兼容老 mod 的直接赋值。
function Sanity:GetAuraMultipliers()
    return self.neg_aura_mult * self.neg_aura_modifiers:Get()
end

--★ 空间查询的两个标签过滤表。sanity aura 的实体必须带 "sanityaura"
--   标签（见 components/sanityaura.lua:10，在构造时 AddTag）。
--   ★ 为什么用标签而非 components 检查：FindEntities 是 C++ 侧的
--     空间索引查询，能按标签走预建索引，比遍历 Lua 表快一个数量级。
--     这是「用 tag 系统给组件做空间索引」的典型手法。
local SANITYRECALC_MUST_TAGS = { "sanityaura" }
--   CANT_TAGS：排除在视野/判定外的实体。
--   ★ 每一项都有明确理由：
--     FX          —— 纯特效，不该影响理智
--     NOCLICK     —— 不可交互物（纯装饰），排除可减少无效计算
--     DECOR       —— 装饰品
--     INLIMBO     —— ★ 在limbo（未入世界）中的实体，位置尚未确定，
--                    若参与 aura 计算会算出错误距离。
--                    limbo 机制见 entityscript.lua 的 IsInLimbo。
local SANITYRECALC_CANT_TAGS = { "FX", "NOCLICK", "DECOR","INLIMBO" }
--   ★★ 源码原注释（NOTES(JBK)）说明了 scratchpad 的存在理由，
--     值得完整保留理解其设计：
--     「这个重算在**一帧内会发生很多次**，所以我们复用同一张表
--      作为所有 sanity 组件的 scratch pad，以免不断制造新表触发 GC。」
--   ★ 这是一个明确的性能权衡：用「共享可变状态」换「零分配」。
--     安全性依据：Recalc 是同步执行、不含yield 的纯计算，
--     所以在单帧内不会被打断，不存在并发/重入问题。
--     ⚠ 风险：若将来 Recalc 里加入任何 yield（如协程化），
--       这张共享表就会互相污染。改动此函数时务必留意。
-- NOTES(JBK): This recalculation happens so many times in one frame we will reuse this table for all sanity components as a scratch pad to not stomp on garbage collection.
local SCRATCHPAD_AURANAMES = {}
local SCRATCHPAD_AURANAMES_ENDPOS = 0
--   ★ 该函数做两件事，注意副作用：
--     ① 检测同名是否用过（用于「同源光环只算一次」）；
--     ② 若没用过，**顺手把它记进 scratchpad**。
--   所以它名叫 Has...BeenUsed，实为「Has...，顺便记一笔」。
--   为什么需要去重见 :550 与 :568 的说明（baseauraname 机制）。
local function SCRATCHPAD_AURANAMES_HasBaseAuraNameBeenUsed(v)
    local has_baseauraname_beenused = false
    local baseauraname = v.components.sanityaura.baseauraname
--   ★ baseauraname 是「光环来源的归并名」。
--     语义（见 components/sanityaura.lua:18）：
--       名字相同的光环视为同一个，只计一次；假定同名光环强度相同。
--   为什么需要：一个玩家身上的 5 个同类 debuff 若各自成一个实体，
--     就会被叠加 5 次；归并后只算1 次。
--     ★ 这个去重只在**本帧、本组件**范围内有效，
--       所以 scratchpad 必须在每次 Recalc 开头清空（:544）。
    if baseauraname then
        for i = 1, SCRATCHPAD_AURANAMES_ENDPOS do
            if SCRATCHPAD_AURANAMES[i] == baseauraname then
                has_baseauraname_beenused = true
                break
            end
        end
        if not has_baseauraname_beenused then
            SCRATCHPAD_AURANAMES_ENDPOS = SCRATCHPAD_AURANAMES_ENDPOS + 1
            SCRATCHPAD_AURANAMES[SCRATCHPAD_AURANAMES_ENDPOS] = baseauraname
        end
    end
    return has_baseauraname_beenused
end
--【★★★★★ Sanity:Recalc(dt) —— 全游戏最复杂的单次数值计算】
--   把五六类来源折算成一个「每秒速率」self.rate，再由 :609 积分进 current。
--   速率公式（:590）：
--     rate = 体面度 + 潮湿惩罚 + 光照 + 光环 + 幽灵 + 外部修饰
--            × (角色 custom_rate_fn) × rate_modifier
--   ★ 核心思想：**先算瞬时导数，再乘 dt 积分**。
--     这样每项都能独立表达成「每秒多少点」，可读性与可调性都远好于
--     把所有因素揉成一个每帧增量。这也是 sanity 与 hunger 最大的结构差异：
--     hunger 直接算增量（hunger.lua:154），sanity 算速率。
--   ★ 各分项是**加性**的（不是乘性），这让组合爆炸的问题被彻底避开——
--     加任何新来源只需加一行，不影响已有来源的量纲。
function Sanity:Recalc(dt)
--   局部变量统一在开头声明成 0，后面逐项累加。
--   ★ 这样做的好处：即使某个分项因免疫等原因整块跳过，
--     它也已经是合法的 0 值，不会出现 nil 参与运算。
	local dapper_delta = 0
--   dapper_delta：体面度带来的回理智。
--   ★ 外层判断 dapperness_mult ~= 0 是一个「快速跳过」优化：
--     为 0 时无需遍历全部装备槽（那是本函数最热的内层循环）。
--     注意 :100 提到 dapperness_mult 在全仓库没有写入点，
--       所以这个分支实际上永远会进——保留它是为了给未来/外部 mod 留口子。
	if self.dapperness_mult ~= 0 then
--   total_dapperness 起点是「自身的基础体面度」（:86），
--   再叠加身上每一件装备的体面度。
		local total_dapperness = self.dapperness
--   ★ 遍历所有装备槽（equipslots），累加装备的 dapperness。
--     这是本函数唯一的「遍历实体身上其他实体」的地方。
--   ⚠ 假设 inst 必有 inventory 组件。对无inventory 的实体（如某些道具）
--     挂 sanity 会报错——与 :442 的 sg 假设同性质。
		for k, v in pairs(self.inst.components.inventory.equipslots) do
            local equippable = v.components.equippable
            if equippable ~= nil then
--   ★ 取得单件装备的体面度，优先用角色自定义函数。
--     get_equippable_dappernessfn 是给角色用的钩子，
--       用于实现「同类装备只算一次」等定制规则。
--     使用方：prefabs/walter.lua:1188、prefabs/wanda.lua:429、
--       prefabs/waxwell.lua:304（三位都用了同名的自定义函数）。
--   ★★ 注意这里的 `and ... or` 写法有个陷阱：
--     若自定义函数返回 0（合法的「无体面度」），
--       Lua 会因 0 为真值而正常返回 0 —— 这是对的；
--       但若返回 false 或 nil，就会**错误地**回退到 GetDapperness。
--       这属于 `and/or` 惯用法的固有缺陷，当前调用点未触发。
                local item_dapperness = self.get_equippable_dappernessfn ~= nil and self.get_equippable_dappernessfn(self.inst, equippable) or equippable:GetDapperness(self.inst, self.no_moisture_penalty)
                total_dapperness = total_dapperness + item_dapperness
            end
		end

--   先乘总乘数，再乘全局系数。
		total_dapperness = total_dapperness * self.dapperness_mult
--   ★ dapper_delta = total_dapperness × TUNING.SANITY_DAPPERNESS（=1，tuning.lua:2174）。
--     系数之所以是 1：调平衡时不想动所有引用点，就在这里统一乘一个 1。
--     它是 mod 调整「体面度效用」的标准旋钮。
		dapper_delta = total_dapperness * TUNING.SANITY_DAPPERNESS
	end

--   ★★ moisture_delta：潮湿带来的理智惩罚。
--   两个提前退出：无 moisture 组件（怪物）→ 0；
--     no_moisture_penalty 为真 → 0。
--   ★ no_moisture_penalty 的使用者是「不怕湿」的角色：
--     prefabs/wormwood.lua:795、prefabs/wurt.lua:644。
--     ★★ 缓动函数 inSine 的四个参数（easing.lua:155）解读：
--       t  = 当前湿度；b = 0（起始值）；
--       c  = TUNING.MOISTURE_SANITY_PENALTY_MAX（= -100/(day_time*6)，
--            默认即 -100/(300*6) = -0.0556/秒，是**负值**）；
--       d  = 该实体的最大湿度。
--     代入 inSine(t,b,c,d) = -c·cos(t/d·π/2) + c + b：
--       湿度 0% → 0（无惩罚）；
--       湿度 100% → c（吃满 -0.0556/秒）。
--     ★ 为什么用 sin 缓动而非线性：inSine 在 t/d 接近 1 时导数趋于 0，
--       也就是「快要湿透时惩罚反而涨得慢」，避免玩家在临界点被突然猛扣。
--       月光之石（Moonrock Armor）这类道具的价值正在于抬高 d（最大湿度）。
    local moisture_delta = (self.inst.components.moisture == nil or self.no_moisture_penalty) and 0 or easing.inSine(self.inst.components.moisture:GetMoisture(), 0, TUNING.MOISTURE_SANITY_PENALTY_MAX, self.inst.components.moisture:GetMaxMoisture())

--   ★ 按当前模式取对应的光照数值表（:468）。
--     这是本函数唯一一处按 mode 分流的地方——
--     其余分项（体面度/潮湿/光环/幽灵）两种模式完全相同。
--     ★ 说明 mode 影响的是「光照这一项的严重程度」，而非整体机制。
    local light_sanity_drain = LIGHT_SANITY_DRAINS[self.mode]
--   light_delta 先置 0，保证免疫时被跳过也是 0（:531）。
	local light_delta = 0

--   ★ 光照免疫短路（SetLightDrainImmune，:254）。
--     放在最外层意味着免疫后**完全不读光照**，连 LightWatcher 都不查——
--     既有语义正确性（免疫就是无视），也省了一次空间查询。
	if not self.light_drain_immune_sources:Get() then
--   ★★ 白天判定：TheWorld.state.isday 且不在洞穴里。
--     为什么还要加 not HasTag("cave")：
--       洞穴内部永远按「夜晚光照」结算，无论地表是不是白天。
--       洞穴是玩家避难所，若按白天处理就会一直回理智，
--       洞内的黑暗就不再有威胁了。
--     这是「光照」与「时间」两个维度解耦的例子。
        if TheWorld.state.isday and not TheWorld:HasTag("cave") then
--   白天取值：INSANITY 模式为 0（不回理智），LUNACY 模式为小幅回理智。
--     ★ 换言之普通角色白天**只能靠 dapperness 回血**，这是本作的核心节奏：
--       「白天梳毛/穿草帽，夜晚必须点灯」。
            light_delta = light_sanity_drain.DAY
        else
--   ★★ night 分支：先取光照值 lightval。
--     CanEntitySeeInDark(inst) —— 夜视类能力（阿比盖尔等）。
--       夜视时直接给 0.9（一个确定的高值），绕过 LightWatcher 查询。
--       0.9 > SANITY_HIGH_LIGHT(0.6) 会命中下一行的NIGHT_LIGHT 档。
--     否则读 inst.LightWatcher:GetLightValue()——
--       ★ 这是 C++ 侧的平滑光照值（考虑火把/荧光棒/洞穴/天气），
--         是整个理智系统唯一的「环境感知」入口。
--   ⚠ 疑似缺陷（轻微）：LightWatcher 未做nil 检查。
--     推理依据：绝大多数实体都有 LightWatcher，但若某 prefab 禁用光照系统，
--       这里会索引 nil。仅影响该 prefab，不影响主流程。
            local lightval = CanEntitySeeInDark(self.inst) and .9 or self.inst.LightWatcher:GetLightValue()
            light_delta =
--   ★★★ 三档光照判定，用 `and/or` 链实现「首个命中即返回」：
--     光照 > 0.6（SANITY_HIGH_LIGHT）→ NIGHT_LIGHT（有光，轻微惩罚）
--     光照 < 0.1（SANITY_LOW_LIGHT）→ NIGHT_DARK（全黑，重罚）
--     其余→ NIGHT_DIM（微光）
--   ★ 阈值刻意设得宽（0.1~0.6 是「微光」），
--     因为玩家很少把光照精确控制在某个值上——
--     宽区间让「拿着火把」与「有点微光」的手感差异不刺眼。
--     而两端的惩罚差 10 倍（见 :468的推导），
--     真正传达的信息只有一条：「全黑很危险」。
                (   (lightval > TUNING.SANITY_HIGH_LIGHT and light_sanity_drain.NIGHT_LIGHT) or
                    (lightval < TUNING.SANITY_LOW_LIGHT and light_sanity_drain.NIGHT_DARK) or
                    light_sanity_drain.NIGHT_DIM
--   ★ night_drain_mult 在这里、且**只在夜间分支**生效。
--     所以 Wendy（:92 默认 1，prefabs/wendy.lua:368 设为 0.75）
--     获得的是「夜间惩罚减 25%」，白天不受影响。
--     ★ 这是把角色特性做「窄」而非「宽」的设计：影响面小，玩家易理解。
                ) * self.night_drain_mult
        end
    end

--   ★★ 清空 scratchpad 的位置标记（不是清空数组）。
--     只重置游标 ENDPOS=0 而保留数组内容，
--     这样已分配的槽位被复用，**整帧零分配**。
--     数组会随见过的不同 baseauraname 数量增长到峰值后稳定，
--     属于典型的「预热后不再增长」模式。
--   ⚠ 这段代码（:544-576）不yield，所以 scratchpad 是安全的；
--     若将来在此插入任何 yield，必须改为局部表。见 :490 的警告。
    SCRATCHPAD_AURANAMES_ENDPOS = 0
--   aura_delta：周目光环的总贡献。
    local aura_delta = 0
--   ★ 全光环免疫短路（SetFullAuraImmunity，:242）。
--     ★ 注意与 :531 的区别：光照免疫只跳过光照项，
--       全光环免疫跳过的是这一整块搜索，是更强力的开关。
    if not self.sanity_aura_immune_sources:Get() then
--   ★ 取自身世界坐标。空间查询是球形的（SANITY_AURA_SEACH_RANGE=20，
--     tuning.lua:2224），所以三轴都要传。
        local x, y, z = self.inst.Transform:GetWorldPosition()
--   ★★ TheSim:FindEntities —— 本函数唯一的空间查询。
--     半径 20 格，标签过滤见 :488-489。
--   ⚠ 性能提示：这是本函数最重的一步，每帧每实体执行一次。
--     多人游戏里每个玩家每帧都做一次 20 格球形查询，
--     靠的正是 C++ 侧的空间索引 + 标签索引（见 :488 的说明）。
--   ★ 与 hunger 的对比：hunger 完全没有空间查询（hunger.lua），
--     这是两个组件复杂度差异的另一体现。
        local ents = TheSim:FindEntities(x, y, z, TUNING.SANITY_AURA_SEACH_RANGE, SANITYRECALC_MUST_TAGS, SANITYRECALC_CANT_TAGS)
--   遍历查到的每个实体。
        for i, v in ipairs(ents) do
--   两道过滤：必须有 sanityaura 组件；且不能是自己。
--     ★ 排除自己很重要——某些实体会给自己挂 sanityaura（自buff），
--       若不排除会把自己也算进去，造成正反馈。
            if v.components.sanityaura ~= nil and v ~= self.inst then
                local is_aura_immune = false
--   ★★★ 按标签的部分免疫判定（配合 :213 的注册接口）。
--     对每个已注册的免疫标签，检查该光环实体是否带这个 tag；
--     带则整个跳过（is_aura_immune=true）。
--     ★ 这里的 is_aura_immune 是「当前这个光环」的标志，
--       与 self.sanity_aura_immune_sources 的「全局免疫」不同层次。
                if self.sanity_aura_immunities ~= nil then
                    for tag, sources in pairs(self.sanity_aura_immunities) do
--   ★ 惰性清理：某个标签的免疫列表已全部失效（sources:Get() 为假），
--     就把它删掉。这是把 :227 的清理逻辑搬到了热路径上——
--     因为这里的免疫来源是**外部被动**变化的，
--     无法依赖调用方及时调 Remove。
--   ⚠ 这段代码在 pairs() 遍历中删除当前键，
--     在 Lua 里是**允许**的（只删不清空整个表是未定义行为），
--     但删除 self.sanity_aura_immunities 整体后紧接 break 是必需的，
--     否则会索引到 nil。代码确实这么写了，处理正确。
                        if not sources:Get() then
                            self.sanity_aura_immunities[tag] = nil
                            if next(self.sanity_aura_immunities) == nil then
                                self.sanity_aura_immunities = nil
                                break
                            end
--   实体确实带该标签 → 本光环被免疫，跳过。
                        elseif v:HasTag(tag) then
                            is_aura_immune = true
                            break
                        end
                    end
                end

--   未被标签免疫，进入实际计算。
                if not is_aura_immune then
--   ★★ 同源光环去重（scratchpad，:493）。
--     ★★ 命名容易误读：函数返回 true 表示「**已经**用过」→应当跳过。
--       若为 false（首次见到），本函数已把它记入 scratchpad，
--       后续同名光环都会被跳过。
--     效果：同一个 debuff 来源挂 5 个实体，只扣一次理智。
                    if not SCRATCHPAD_AURANAMES_HasBaseAuraNameBeenUsed(v) then
--   ★ GetAura：向光环方询问它对本观察者的强度。
--     实现在 components/sanityaura.lua:26 —— 它内部会做距离衰减：
--       除以 max(1, distsq)，所以光环强度随距离平方衰减。
--     ★ 用 distsq（距离平方）而非距离做分母，
--       是为了让衰减「起步就明显」，避免光环边缘出现一截平的有效区。
                        local aura_val = v.components.sanityaura:GetAura(self.inst)
--   ★★★ 负向光环的三层处理（这一行是全文件最难读的一行）：
--       ① 若 aura_val < 0（负向）：
--            · 若 neg_aura_absorb > 0 → 取 absorb × (-aura_val)，
--              即**按比例抵消**一部分负伤害（注意结果仍是负数，
--              因为 absorb < 1），然后乘负光环总乘数；
--            · 否则保持原值，再乘总乘数。
--       ② 若 aura_val >= 0（正向）：完全不动，也不乘总乘数。
--     ★★ 这就是 neg_aura_mult / neg_aura_modifiers 的语义：
--       它们只放大/缩小「负」光环，对正向光环（帽子给的 +sanity）无影响。
--       设计上很合理——「削弱负面情绪」不该让人更开心。
--   ⚠ 疑似缺陷（写法脆弱，非行为错误）：这一行以及 :582 是同一段逻辑的复制，
--     用了密集的 `and/or` 嵌套且未加括号分组，
--     可读性极低且极易在后续修改时出错。
--     推理依据：逻辑本身经逐步求值验证是正确的，
--       只是 Lua 的 and/or 没有优先级括号，
--       一旦有人漏写括号就会静默改变语义。
--     建议（仅记录，不改代码）：改写成 if 语句即可。
                        aura_val = (aura_val < 0 and (self.neg_aura_absorb > 0 and self.neg_aura_absorb * -aura_val or aura_val) * self:GetAuraMultipliers() or aura_val)
--   累加进 aura_delta。
--   ★ 负光环免疫（neg_aura_immune_sources，:246）在最后一步生效：
--     前面算出的负值被直接丢弃（加 0），
--     而正向光环不受此免疫影响。
                        aura_delta = aura_delta + ((aura_val < 0 and self.neg_aura_immune_sources:Get()) and 0 or aura_val)
                    end
                end
            end
        end
    end

--   ★★★ 坐骑（mount）的光环也要算——且是单独处理的。
--     为什么不能靠上面的 FindEntities：骑乘时实体与坐骑的相对位置特殊，
--     且坐骑的 aura 可能不带"sanityaura" 标签检索路径，
--     所以显式取 rider 的挂载物再做一次同样计算。
--     ★ 因此牛（牛友/沃夫）与骑乘怪（如阿比盖尔的牛）都能影响理智。
    local mount = self.inst.components.rider and self.inst.components.rider:IsRiding() and self.inst.components.rider:GetMount() or nil
--   坐骑自身带sanityaura 组件时才处理（很多坐骑没有）。
    if mount ~= nil and mount.components.sanityaura ~= nil then
--   ★ 坐骑也走去重检查——所以「玩家身上与坐骑上同名光环」只算一次，
--     防止骑牛时同种 debuff 被算两遍。
--     这也说明 scratchpad 的游标从 :544 清空后，
--       在整个 Recalc 内是**跨两个代码块共享**的。
        if not SCRATCHPAD_AURANAMES_HasBaseAuraNameBeenUsed(mount) then
--   坐骑光环的取值与去重，与 :569-571 逻辑完全一致（再次复制而非抽象）。
--   ★ 注意这里没有再写一遍 neg_aura_absorb 的处理说明，
--     因为它与 :570 逐字符相同——两处若只改一处就会产生行为分叉。
            local aura_val = mount.components.sanityaura:GetAura(self.inst)
            aura_val = (aura_val < 0 and (self.neg_aura_absorb > 0 and self.neg_aura_absorb * -aura_val or aura_val) * self:GetAuraMultipliers() or aura_val)
            aura_delta = aura_delta + ((aura_val < 0 and self.neg_aura_immune_sources:Get()) and 0 or aura_val)
        end
    end

--   ★ Recalc 里也调一次 RecalcGhostDrain（:456）。
--     看似与 OnUpdate 的 else 分支（:448）重复，实则必要：
--       正常结算路径（:445）里OnUpdate 走的是 if 分支，不会调它。
--     即两处分别覆盖「结算时」与「不结算时」，保证每帧恰好更新一次。
    self:RecalcGhostDrain()
--   ★ ghost_delta = TUNING.SANITY_GHOST_PLAYER_DRAIN × ghost_drain_mult。
--     常量本身是 -100/(night_time*30)（tuning.lua:2193），
--       默认即 -100/(60*30) = -0.0556/秒（负值）。
--     与倍率相乘后，最大惩罚 = 0.0556 × 3 ≈ 0.167/秒（对应 3 个幽灵且无抗性）。
--     ★ 注意它**没有乘 night_drain_mult**——
--       幽灵惩罚与光照无关，白天夜里一样扣。
    local ghost_delta = TUNING.SANITY_GHOST_PLAYER_DRAIN * self.ghost_drain_mult

--   ★★★★★ 速率汇总 —— 本组件的核心一行。
--     六项加性相加：
--       dapper_delta   体面度（正）
--       moisture_delta 潮湿（负）
--       light_delta    光照（正/负，随模式与时段）
--       aura_delta     光环（正/负）
--       ghost_delta    幽灵玩家（负或 0）
--       externalmodifiers:Get() 外部物品修正（可正可负，:87）
--     ★ 为什么是加性：各项量纲统一为「每秒点数」，
--       加法让每一项都能独立调参、互不干扰。
--     ★★ 这是全游戏最需要平衡的公式：任何一个 TUNING 常量改动都会
--       直接改变玩家的生存节奏，所以它也是 mod 改动最频繁的地方。
    self.rate = dapper_delta + moisture_delta + light_delta + aura_delta + ghost_delta + self.externalmodifiers:Get()

--   ★ custom_rate_fn：角色自定义速率（:107）。
--   ★★ 源码注释交代了一个重要的顺序约定：
--       「dt param was added for wormwood's custom rate function」
--        「dt shouldn't have been applied to the return value yet」
--     翻译：这个函数返回的**还是速率**，不是增量；
--       所以它的 dt 参数只是「提供给你参考」，
--       绝对不要再乘一次 dt，否则会被积分两次（:609 会统一乘）。
--     ★ 这是给扩展者的显式警告，也是最容易踩的坑。
--   实现方：prefabs/willow.lua:170、prefabs/walter.lua:1184。
    if self.custom_rate_fn ~= nil then
        --NOTE: dt param was added for wormwood's custom rate function
        --      dt shouldn't have been applied to the return value yet
--   ★ 注意是加进 self.rate（速率），而非加进最终的 delta。
        self.rate = self.rate + self.custom_rate_fn(self.inst, dt)
    end

--   ★★ 最后统一乘 rate_modifier（:83）。
--     ★ 这是全局总乘数，作用范围最大。
--     Willow 因火灾而更易疯狂：rate_modifier = 1.1（tuning.lua:3756
--       WILLOW_SANITY_MODIFIER = 1.1，prefabs/willow.lua:171）。
--     ★ 放在最后意味着它同时放大正向与负向速率——
--       Willow 不只是更容易掉理智，也更容易回得慢（回得慢是因为
--       它的基础恢复来源少，而非此系数）。
    self.rate = self.rate * self.rate_modifier
--   ★★★ ratescale 分档 —— 只影响 UI 箭头，不影响任何数值。
--     阈值不对称：正侧 0.2/0.1/0.01，负侧 0.3/0.1/0.02。
--     ★ 负侧阈值更高（0.3 vs 0.2，0.02 vs 0.01），
--       说明「快速掉理智」比「缓慢回升」更值得引起玩家警觉，
--       是有意的不对称设计。
--     档位值见 constants.lua:2404。
--     ⚠ 注意这段是 `and/or` 链，依赖 RATE_SCALE 各值非0/非nil；
--       RATE_SCALE.NEUTRAL = 0 排在最后作为默认值，不会被短路吃掉，
--       因此是安全的。
    self.ratescale =
        (self.rate > .2 and RATE_SCALE.INCREASE_HIGH) or
        (self.rate > .1 and RATE_SCALE.INCREASE_MED) or
        (self.rate > .01 and RATE_SCALE.INCREASE_LOW) or
        (self.rate < -.3 and RATE_SCALE.DECREASE_HIGH) or
        (self.rate < -.1 and RATE_SCALE.DECREASE_MED) or
        (self.rate < -.02 and RATE_SCALE.DECREASE_LOW) or
        RATE_SCALE.NEUTRAL

--   ★ 源码里保留的调试打印（已注释）。
--     ★ 值得注意它打印的是 self.rate*dt（**增量**），
--       而不是 rate 本身——印证了「rate 是导数、rate*dt 才是增量」。
--     排查理智问题时取消这行注释是最快的手段。
    --print (string.format("dapper: %2.2f light: %2.2f TOTAL: %2.2f", dapper_delta, light_delta, self.rate*dt))
--   ★★★★★ 积分 —— 整个组件的最终落点。
--     DoDelta(rate × dt, true) 的两个参数：
--       rate × dt —— 速率乘本帧时长 = 本帧应变化的值；
--       true          —— overtime 标记，表示这是「持续性变化」，
--                       UI 会用它决定用渐变动画而非瞬跳。
--     ★ 为什么 dt 在这里而不是在 Recalc 内部乘：
--       保持 self.rate 是纯净的「每秒速率」，
--       才能被 GetDebugString（:308）、ratescale（:599）复用。
--     ★★ 这就是与hunger 的结构性差异：
--       hunger 每秒算一次并直接扣（hunger.lua:154），
--       sanity 每帧算速率再积分，所以 sanity 对帧率完全免疫。
    self:DoDelta(self.rate * dt, true)
end

--【TransferComponent：组件转移时的数值交接】
--   场景：玩家被传送/复活导致实体重建，组件要迁移到新实体上。
--   ★ 用 GetPercent/SetPercent 传「比例」而非绝对值，
--     因为新旧实体的 max 可能不同（如换角色）。
--   ★ 对比 hunger.lua:171 的 TransferComponent：写法完全对称，
--     两个组件在这一处的设计刻意保持一致，便于维护者形成肌肉记忆。
function Sanity:TransferComponent(newinst)
    local newcomponent = newinst.components.sanity
    newcomponent:SetPercent(self:GetPercent())
end

--   ★★ LongUpdate = OnUpdate —— 把同一个函数同时挂到两个更新钩子上。
--     什么是长更新（LongUpdate）：DST 主循环有两条更新通道——
--       普通更新（每帧）与长更新（按更长间隔，服务于非活跃实体）。
--     ★ 这里是**同一个引用**，不是包装函数，因此行为完全一致：
--       长更新时照样按传入的 dt 积分，所以数值变化与帧率无关。
--     ★ 对比 hunger.lua:167：hunger 的 LongUpdate 只调 DoDec(dt, true)，
--       第二个参数 true = ignore_damage，即「只扣饥饿、不扣血」。
--       这是本质区别：hungry 在长更新期间**不会**造成伤害，
--         而 sanity 的长更新会完整结算。
--       推测原因：sanity 的变化无害（不会直接致死），
--         而饥饿的伤害需要更精确的节奏控制。
Sanity.LongUpdate = Sanity.OnUpdate

return Sanity
