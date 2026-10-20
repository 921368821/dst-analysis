// spec-sanity-p1.mjs —— sanity.lua 注释规格 第1部分：行 1–210
// 说明：key = 源文件行号；值为要插入的注释行数组（每行必须以 -- 开头）。
// BEFORE 插在该代码行之前，AFTER 插在该代码行之后。代码行永远由构建脚本从源文件复制。
// 行号基准：components/sanity.lua（619 行）

export const BEFORE = {
  // ============ 依赖 ============
  1: [
    "--【★ easing 是「缓动函数库」】sanity 用它把湿度映射成平滑的理智惩罚。",
    "--   之所以要缓动：湿度是 0~100 的连续量，若线性映射，理智下降速度会在",
    "--   湿度刚过 0 时突然产生难以察觉的阶跃感；inSine 让「刚沾湿」几乎无损、",
    "--   「快湿透」惩罚陡增，体感更自然。",
  ],
  2: [
    "--【SourceModifierList —— 全DST 最重要的数值解耦工具】",
    "--它解决的问题：一个数值会被十几个来源同时影响（帽子、食物、天气、角色特性）。",
    "--若每个来源各自去改self.current，就会出现「谁先改、谁后减」的顺序耦合。",
    "--   SourceModifierList 把它改成一组「加性/乘性贡献」，",
    "--   每帧只做一次 Get() 求和，见 sanity.lua:87、:95、:590。",
    "--   参见 util/sourcemodifierlist.lua。",
  ],

  // ============ _replica_setcurrent ============
  "_replica_setcurrent#1": [
    "--【★★★ 「强制状态」覆盖层 —— 全文件最精妙的一处设计】",
    "--问题：游戏里有三类状态会「无视」真实理智值直接改显示：",
    "--     ① inducedinsanity（被强拉进疯狂，如DDLC 头带）",
    "--     ② inducedlunacy（被强拉进 enlightenment）",
    "--     ③ penalty（代价机制压低上限，如 Maxwell 的影子仆从）",
    "--   若在数据源上直接改 self.current，就再也无法恢复，且会被本帧的",
    "--   速率积分立刻「挣」回来（自相矛盾）。",
    "--做法：self.current 保持真实值不动，只在「同步给客户端」这一步做覆盖。",
    "--   于是本文件里出现大量「显示用值」与「真实值」分叉的函数对：",
    "--     GetPercent / GetRealPercent、GetPercentWithPenalty / GetPercent、",
    "--     IsSane 的两个分支。",
    "--★ 注意参数顺序被刻意打乱成 (self, replica_sanity, current, max, ...)，",
    "--   这样调用方只需写 self.inst.replica.sanity 而不用反复 self.inst.replica 取值。",
  ],
  "_replica_setcurrent#1+1": [
    "--   下面是优先级链：inducedinsanity > inducedlunacy > current。",
  ],
  "_replica_setcurrent#1+3": [
    "--   ① 被强制疯狂：显示 0。注意这里**不看当前是否本来就已经很低**，",
    "--      强制疯狂就是 0，把玩家按在理智崩溃的表现上。",
  ],
  "_replica_setcurrent#1+4": [
    "--   ② 被强制 enlightenment：显示 max*(1-penalty)。",
    "--      ★ 不是 1-penalty（比例）而是 max*(1-penalty)（绝对值），",
    "--        因为分类显示的 currentsanity 与 maxsanity 是两个独立的网络字段，",
    "--        必须给出一个「绝对理智值」才能让客户端自行做比例计算。",
    "--        若只发比例，maxsanity 的网络插值会让 UI 抖动。",
  ],
  "_replica_setcurrent#1+2": [
    "--  ⚠ 疑似缺陷（原作者自己标注的）：",
    "--     源码把 (inducedlunacy and inducedinsanity and 0) 整行注释掉了，",
    "--     旁边写着 redundant（多余）。",
    "--     推理依据：若两者同时为真，当前代码走第 7 行返回 0；",
    "--       而被注释的写法返回的也正好是 0 —— 行为完全等价，故可安全删除。",
    "--     但真正的隐患在于它**没有被禁止**：两个 forced 标志来自不同来源",
    "--       （SetInducedInsanity / SetInducedLunacy，见 sanity.lua:331、:354），",
    "--       互不排斥，理论上可同时成立。目前靠「二者同为 0 值」侥幸无害。",
  ],

  // ============ _replica_setissane ============
  "_replica_setissane#1": [
    "--【★★★ sane 标志的「模式互换」】这是本文件最容易看错的地方。",
    "--IsSane() 并不是简单地「self.sane 为真」，而是一个**随 mode 翻转的映射**：",
    "--     在 INSANITY 模式：sane=true  表示「理智正常」，sane=false 表示「疯狂」",
    "--     在 LUNACY   模式：sane=true  表示「开悟正常」，sane=false 表示「开悟」",
    "--   ★ 也就是说 self.sane 这个字段的语义本身是「没有处于特殊态」，",
    "--     而IsSane() 把它翻译成当前模式下玩家视角的「是否正常」。",
    "--   好处：模式切换时无需重置任何数值，只需换掉翻译函数，",
    "--         阈值判定逻辑（DoDelta，sanity.lua:391）也能对称复用。",
  ],
  "_replica_setissane#1+1": [
    "--   先按当前模式决定「基线」，再用另一个 forced 标志做反向覆盖。",
  ],
  "_replica_setissane#1+2": [
    "--     INSANITY 模式：正常 = sane且没被强制疯狂；",
    "--       但若被强制开悟，即使 sane 也算不正常（or inducedlunacy）。",
  ],
  "_replica_setissane#1+3": [
    "--   LUNACY 模式：与上面**完全对称**。else 分支不写条件，",
    "--     是靠「mode 只有两种取值」这个不变量成立的（见 constants.lua:1234-1235）。",
    "--     ⚠ 疑似脆弱点：若将来加入第三种 mode，这里会静默走错分支。",
  ],
  "_replica_setissane#1+4": [
    "--     LUNACY 模式：正常 = sane 且没被强制开悟；",
    "--       被强制疯狂则一律不正常。",
  ],

  // ============ onmax ============
  "onmax#1": [
    "--【属性 setter：max】Class 第三参数表（sanity.lua:126）把字段写入变成函数调用，",
    "--   好处：改字段后自动同步网络，调用方无脑写 self.max = x 即可，不会漏同步。",
    "--   onmax 额外处理了一个边界：若正被强制开悟，理智上限变了，",
    "--     必须把「显示用的 current」一起重算，否则会出现上限变了但比例跳变。",
  ],
  "onmax#1+3": [
    "--   ★ 条件带了 and not self.inducedinsanity：",
    "--     若同时被强制疯狂，第7 行会覆盖成 0，这里就不用（也不该）重算。",
  ],

  // ============ oncurrent / onratescale / onmode / onsane ============
  "oncurrent#1": [
    "--【属性 setter：current】同样自动触发 _replica_setcurrent 的覆盖逻辑。",
  ],
  "onratescale#1": [
    "--【属性 setter：ratescale】ratescale 是给 UI 用的「+1/-1 箭头」提示档位。",
    "--   ★ 它是**瞬时导数**而非累积量，所以不需要 forced 覆盖 ——",
    "--     强制疯狂时箭头依然应该反映真实增减，否则玩家会觉得「数值不动了」。",
    "--   档位定义见 constants.lua:2404的 RATE_SCALE（NEUTRAL=0 起，共7 档）。",
  ],
  "onmode#1": [
    "--【属性 setter：mode】模式（疯狂/开悟）切换时，需要同时刷新两样东西：",
    "--     ① sanitymode 字段本身 ② sane 标志（因为 IsSane 的映射变了）。",
    "--   ★ 这解释了为什么 UpdateMode_Internal（:175）切模式后必须调用 DoDelta(0) ——",
    "--     不是为了改数值，而是借DoDelta「顺手」触发一次全量同步。",
  ],
  "onsane#1": [
    "--【属性 setter：sane】仅需重算 sane 映射，数值不变。",
  ],

  // ============ oninducedinsanity / oninducedlunacy ============
  "oninducedinsanity#1": [
    "--【属性 setter：inducedinsanity】被外力强制疯狂（如游戏里的头带道具）。",
    "--   ★ 关键设计：它**不改 self.current**（真实理智照常流动），",
    "--     只改 forced 标志。所以摘掉头带后理智不会「跳回」，而是接着原值继续算。",
    "--     若改成直接扣血，就无法区分「本来快疯了」与「被道具按下去」。",
  ],
  "oninducedinsanity#1+2": [
    "--   同时刷新 sane 与 current：forced 状态变了，两个显示量都要重算。",
  ],
  "oninducedlunacy#1": [
    "--【属性 setter：inducedlunacy】与 inducedinsanity 严格对称。",
    "--   使用方见 prefabs/hats.lua:3387（强制开悟类帽子）。",
  ],

  // ============ onpenalty ============
  "onpenalty#1": [
    "--【属性 setter：penalty —— 「代价机制」的入口】",
    "--   penalty 是 0~1 的比例，表示「永久压低理智上限」，例如 Maxwell 携带影子。",
    "--   ★ 与 forced 标志不同，penalty 是**真实**上限的一部分：",
    "--     它会参与 DoDelta 里的钳制（sanity.lua:387）与所有百分比计算。",
    "--     所以它是不可逆的（除非主动移除对应 penalty 项）。",
  ],
  "onpenalty#1+2": [
    "--   同步给客户端的比例值。客户端侧见 sanity_replica.lua:107 的 SetPenalty，",
    "--   那里做了 0~1 的assert 并以 *200 定点传输（省带宽）。",
  ],

  // ============ onghostdrainmult ============
  "onghostdrainmult#1": [
    "--【属性 setter：ghost_drain_mult —— 「幽灵玩家」惩罚】",
    "--   在有房主掉线留下幽灵的世界里，活着的人会被持续抽理智。",
    "--   这里同步的只是一个 bool（是否 >0），因为 UI 只需要显示一个图标。",
    "--   ★ 具体倍率由 RecalcGhostDrain（:456）按人数动态算，不逐帧同步。",
  ],
  "onghostdrainmult#1+1": [
    "--   实现在 sanity_replica.lua:230，只写 ghostdrainmult > 0 这个布尔量。",
  ],

  // ============ 构造函数 ============
  "onghostdrainmult#1+4": [
    "--【★★★ 构造函数：整个组件的状态声明集中在此】",
    "--   注意本组件**没有 OnSave 之外的注册式更新**（对比 hunger 用 DoPeriodicTask），",
    "--   而是在末尾用 StartUpdatingComponent 把自己挂进每帧更新队列（:122）。",
    "--   原因是 sanity 的衰减速率依赖光照/湿度/aura 这些每帧都在变的状态，",
    "--   必须每帧重算（详见:510Recalc 的说明）。",
  ],
  "onghostdrainmult#1+6": [
    "--   ★ 默认 max=100，但玩家的真实值由角色 prefab 覆盖，",
    "--     例如 prefabs/willow.lua:169 的 SetMax(TUNING.WILLOW_SANITY)。",
    "--     tuning.lua 中 wilson_sanity = 200，所以默认 100 只是「无角色时的占位」。",
  ],
  "onghostdrainmult#1+9": [
    "--   mode 默认 SANITY_MODE_INSANITY（constants.lua:1234，值为 0）。",
    "--   ★ 在 Lua 里 0 是真值，所以这里绝不能写成 if self.mode 判断模式。",
  ],
  "onghostdrainmult#1+10": [
    "--   ★ _lunacy_sources：开悟模式是「有源」的概念，不是布尔开关。",
    "--     用 boolean 型 SourceModifierList 是因为它必须能同时挂多个来源，",
    "--     且来源全部移除后要能自动回落到疯狂模式。",
    "--     这样想：某个装备/能力让你开悟，脱下就自动恢复正常。",
  ],
  "onghostdrainmult#1+12": [
    "--   rate：当前的「每秒理智变化量」，是整个组件的核心状态变量。",
    "--   ★ 它是导数不是存量。真正改变理智的是 rate*dt（见 :609）。",
  ],
  "onghostdrainmult#1+13": [
    "--   ratescale：rate 的**分档量化结果**（0~6），专供 UI 画箭头。",
    "--   为什么要分档而不是直接显示小数：rate 是个浮点数，每帧抖动，",
    "--   箭头会疯狂闪烁。分档后只有跨越阈值才变，视觉上稳定得多。",
  ],
  "onghostdrainmult#1+14": [
    "--   ★ rate_modifier：最终的总乘数，在所有分项求和**之后**才乘（:598）。",
    "--     顺序很重要——它要压住的是「总速率」，而不是某一项。",
    "--     实际用途：Willow 因火灾而更容易疯狂，rate_modifier=1.1（prefabs/willow.lua:171）。",
  ],
  "onghostdrainmult#1+15": [
    "--   sane：见 _replica_setissane 的解释——它存的是「未处于特殊态」。",
  ],
  "onghostdrainmult#1+16": [
    "--   fxtime：给 UI/音效用的计时器，本组件内不读，由外部（sanity_fx 之类）写入。",
  ],
  "onghostdrainmult#1+17": [
    "--   dapperness：基础「体面度」。它与装备上的 dapperness 相加，",
    "--   最终乘 TUNING.SANITY_DAPPERNESS 得到回理智速率（见 :523）。",
    "--   典型来源：Maxwell 默认带 DAPPERNESS_LARGE（prefabs/waxwell.lua:303）。",
  ],
  "onghostdrainmult#1+18": [
    "--   ★ externalmodifiers：外部物品的**加性**理智速率修正。",
    "--     「加性」意味着它直接以「每秒多少点」参与求和（:590），",
    "--     而不是乘一个百分比——这对「每秒 +1.5 理智」这类数值最直观。",
    "--   使用方：components/itemaffinity.lua:44（装备亲和）、",
    "--     prefabs/ancienttree_fruits.lua:539（负向：-DAPPERNESS_MED_LARGE）。",
  ],
  "onghostdrainmult#1+19": [
    "--   以下四个字段是「两对forced 标志 + 各自的来源集合」。",
    "--   ★ 为什么不用 SourceModifierList 而是裸的哈希表？",
    "--     因为 forced 状态需要「显式列出是哪个 source 造成的」以便精准解除，",
    "--     而 SourceModifierList 的 SetModifier/RemoveModifier 也能做到，",
    "--     这里选择裸表是为了在 OnSave 时能枚举（目前未使用，属预留）。",
  ],
  "onghostdrainmult#1+23": [
    "--   night_drain_mult：夜间理智流失的角色系数。",
    "--   ★ 写在构造函数里但从不在本文件内被修改——它是留给角色 prefab 的外部接口：",
    "--     prefabs/wendy.lua:368（WENDY_SANITY_MULT=0.75，夜间掉得慢）、",
    "--     prefabs/wolfgang.lua:96-98（分体质两档）。",
  ],
  "onghostdrainmult#1+25": [
    "--   ⚠ 已废弃。保留字段是为了兼容老存档/老 mod 直接读写 neg_aura_mult 的写法。",
    "--     新的正确入口是下面的 neg_aura_modifiers（乘性 SourceModifierList）。",
  ],
  "onghostdrainmult#1+26": [
    "--   neg_aura_modifiers：负向光环（depression aura）的乘数。",
    "--   ★ 默认 SourceModifierList 的语义是**乘性**（第4~5 个参数可指定），",
    "--     所以它与externalmodifiers（加性）刻意用不同实例。",
  ],
  "onghostdrainmult#1+27": [
    "--   neg_aura_absorb：负向光环的「吸收比例」（0~1），0 = 完全不吸收。",
    "--   ★ 与 neg_aura_mult 的区别：mult 是乘性缩放**所有**负光环，",
    "--     absorb 是按比例**抵消**负光环的伤害。",
    "--     典型用途：蜂巢帽抵消 50% 的理智光环（prefabs/hats.lua:2057，",
    "--     TUNING.ARMOR_HIVEHAT_SANITY_ABSORPTION = .5）。",
    "--   使用点在 Recalc 的:570 与 :582（两处几乎相同，见那里的详细说明）。",
  ],
  "onghostdrainmult#1+30": [
    "--   neg_aura_immune_sources：完全免疫负向光环。",
    "--   ⚠ 注意与 sanity_aura_immune_sources（:110）的区别：",
    "--     这个只挡「负」的，全免疫那个连帽子带来的正sanity 光环也一起挡掉。",
  ],
  "onghostdrainmult#1+31": [
    "--   dapperness_mult：体面度总乘数。",
    "--   ⚠ 疑似缺陷：本文件内**没有任何一处写入它**（全仓库搜索无赋值点），",
    "--     而 :512 用它做 `if self.dapperness_mult ~= 0` 的短路判断。",
    "--     推理依据：默认值 1（真值）使条件恒成立，故当前无害；",
    "--     但若将来有人想「关掉体面度」，会写成 dapperness_mult = 0，",
    "--       此时整个 dapper_delta 分支被跳过——这是**唯一**能关掉它的路径，",
    "--       语义上与「乘数为 0」一致，所以其实不算 bug，只是文档缺失。",
    "--     记录于此以免后人误以为是死代码而删除。",
  ],
  "onghostdrainmult#1+32": [
    "--   penalty：0~1 的「理智上限惩罚比例」。由 RecalculatePenalty 统一维护（:199），",
    "--   外部只能通过 AddSanityPenalty / RemoveSanityPenalty 增删条目。",
  ],
  "onghostdrainmult#1+34": [
    "--   ★ sanity_penalties 是一个「key → 比例」的字典而不是累加变量。",
    "--     为什么要字典：同一个来源可能反复 Add/Remove，",
    "--     若用累加变量必须由调用方自己配对加减，极易漏掉Remove 导致永久扣减。",
    "--     用字典后，key 就是幂等令牌——重复 Add 同key 只是覆盖同一个值。",
    "--   典型来源：Maxwell 的影子仆从按「种类」分别记账，",
    "--     见 prefabs/waxwell.lua:58，key 为小写化后的 prefab 名。",
  ],
  "onghostdrainmult#1+36": [
    "--   ghost_drain_mult：幽灵玩家造成的理智抽取倍率，由 RecalcGhostDrain 写入。",
    "--   ★ 初值为 0（= 不受影响），而构造函数末尾 :123 立刻调了一次 RecalcGhostDrain，",
    "--     所以第一帧就是对的——否则刚进世界会闪一下错误图标。",
  ],
  "onghostdrainmult#1+38": [
    "--   ★ custom_rate_fn：角色自定义速率函数的注入点（最高优先级的扩展口）。",
    "--     它返回的仍是「速率」而非「增量」，所以之后才乘 dt（:609）。",
    "--   使用方：prefabs/willow.lua:170（柳树因火灾额外掉理智）、",
    "--     prefabs/walter.lua:1184。注意 woodie.lua:1200 显式置回 nil，",
    "--     说明角色切换时必须清理——因为组件常驻不销毁。",
  ],
  "onghostdrainmult#1+41": [
    "--   ★ sanity_aura_immune_sources：免疫**一切**sanity 光环（含正向）。",
    "--     源码注释说得很清楚：is unaffected by ANY auras。",
    "--   ⚠ 与 :99 的 neg_aura_immune_sources 语义重叠但不等价：",
    "--     前者连「让人变清醒」的光环也挡掉，后者只挡负的。",
  ],
  "onghostdrainmult#1+42": [
    "--   sanity_aura_immunities：按**标签**分类的部分免疫（如 Wendy 免疫幽灵相关）。",
    "--   ★ 这是个二层结构：{ 标签名 → 该标签的 SourceModifierList }。",
    "--     懒初始化（见 AddSanityAuraImmunity :213），没有免疫需求时不建表。",
  ],
  "onghostdrainmult#1+44": [
    "--   player_ghost_immune_sources：免疫「幽灵玩家」惩罚。",
    "--   ★ 与 ghost_drain_mult 是两条独立路径：",
    "--     前者让 RecalcGhostDrain 直接算出 0（:457），",
    "--     所以 UI 图标也一并消失；二者不是叠加关系。",
  ],
  "onghostdrainmult#1+47": [
    "--   light_drain_immune_sources：免疫光照带来的理智流失（:531）。",
    "--   注意它**不免疫**潮湿与 dapperness，只挡light_delta 这一项。",
  ],
  "onghostdrainmult#1+49": [
    "--【★★ 三个「上一次的值」—— 边沿触发（edge detection）的缓存】",
    "--   DoDelta 每次都跑（每帧），但「变得疯狂」「变得开悟」这类事件只该在",
    "--   **跨越阈值的那一刻**发一次，否则每帧都会重复 PushEvent。",
    "--   做法：把旧值存下来，下次比较。三个缓存各管一种边沿：",
    "--     _oldissane  —— 正常/异常 翻转（sanity.lua:410）",
    "--     _oldpercent —— 给外部算增量用（sanity.lua:405、:408）",
    "--     _oldmode    —— 模式切换时也要补发状态事件（sanity.lua:410）",
    "--   ★ 必须在 StartUpdatingComponent **之前**初始化完成，",
    "--     否则第一次 Recalc 会拿 nil 与布尔值比较而误触发事件。",
  ],
  "onghostdrainmult#1+53": [
    "--   ★ StartUpdatingComponent：注册进主循环的每帧更新队列。",
    "--     对应本组件的 Sanity:OnUpdate（:437）。",
    "--   参见 entityscript.lua 的 StartUpdatingComponent 与 update.lua 的更新循环。",
    "--   为什么不用 DoPeriodicTask（hunger 的做法）：",
    "--     光照值 LightWatcher 每帧都在变，节拍化会导致速率积分产生锯齿。",
  ],
  "onghostdrainmult#1+54": [
    "--   构造期立即算一次幽灵倍率，保证 UI 首次刷新时数据已正确。",
  ],

  // ============ 属性表 ============
  "onghostdrainmult#1+57": [
    "--【★ Class 的第三个参数：属性 setter 表】",
    "--   格式为 { 字段名 = setter 函数 }。此后所有 self.字段 = 值 的写入",
    "--   都会自动调用对应 setter，实现「数据变更即同步」。",
    "--   ★ 这是本文件所有 onXXX 函数存在的唯一理由——",
    "--     把「改一个字段」和「把它推给客户端」绑定，杜绝漏同步的 bug。",
    "--   同时它也意味着 setter 会在**构造期间**被触发（因为构造函数里逐个赋值），",
    "--     所以这些函数内部一律不能假设 replica 已就绪 ——",
    "--     这就是为什么 onmax（:22）等函数体内没有 nil 检查也能跑。",
  ],
  "onghostdrainmult#1+58": [
    "--   依次是：max / current / ratescale / mode / sane /",
    "--         inducedinsanity / inducedlunacy / penalty / ghost_drain_mult。",
  ],

  // ============ IsSane / IsInsane / IsEnlightened ============
  "Sanity:IsSane#1": [
    "--【★ IsSane：唯一的「对外语义翻译」入口】",
    "--   前面所有 _replica_setissane 的换算逻辑，这里是权威版本；",
    "--   replica 侧读的是网络 bool（sanity_replica.lua:201），",
    "--   两者必须保持一致，否则会出现「UI 说正常但实际在疯狂」。",
  ],
  "Sanity:IsSane#1+1": [
    "--   两个分支除 forced 标志的名字互换外完全对称——见 :13 的说明。",
  ],
  "Sanity:IsInsane#1": [
    "--【IsInsane：只关心「在疯狂模式下是否崩溃」】",
    "--   ★ 注意末尾的 and not self.inducedlunacy：",
    "--     被强制开悟的人，即使在疯狂模式下，也不算 IsInsane ——",
    "--     因为开悟的表现会完全覆盖疯狂。这与 IsSane 的优先级一致。",
  ],
  "Sanity:IsEnlightened#1": [
    "--   IsEnlightened：IsInsane 的镜像（开悟模式 + 崩溃态）。",
  ],
  "Sanity:IsCrazy#1": [
    "--   IsCrazy：早期版本的接口，已废弃。保留是为了不破坏老 mod。",
  ],
  "Sanity:SetSanityMode#1": [
    "--   SetSanityMode：已废弃的空函数。",
    "--   ⚠ 它**不是**真的无害：若某个 mod 调它来切模式，",
    "--     不会有任何报错，但也不会生效——属于静默失败。",
    "--     正确入口是 EnableLunacy（:184）。",
  ],
  "Sanity:IsInsanityMode#1": [
    "--   下面两个是 mode 的直接判定，IsInsanityMode 比 `mode == SANITY_MODE_INSANITY`",
    "--   更可读，且未来若加第三种模式只需改这里。",
  ],
  "Sanity:UpdateMode_Internal#1": [
    "--【★ UpdateMode_Internal：模式切换的唯一实际执行点】",
    "--   ★ 为什么每帧都要调（见 OnUpdate :438）而不是在 EnableLunacy 里调一次：",
    "--     源码注释直接给了原因 ——「since we may not know when lunacy sources",
    "--     are removed」。来源可以被外部随意置空（如装备被销毁），",
    "--     组件无法收到通知，只能靠每帧轮询 SourceModifierList 的变化。",
    "--   代价是每帧一次哈希表查找，相对整个 Recalc 可忽略。",
  ],
  "Sanity:UpdateMode_Internal#1+5": [
    "--   ★ DoDelta(0)：传 0 增量，借这次调用把「模式已变」同步出去，",
    "--     因为 onmode（:38）需要新的 mode 才能算对 sane。",
    "--     这是一种「用正常流程顺带完成状态同步」的技巧，写法上很巧。",
  ],
  "Sanity:EnableLunacy#1": [
    "--【EnableLunacy：开悟模式的唯一对外入口】",
    "--   ★ 形参是 enable 而非「设成某状态」，配合 source 做引用计数：",
    "--     两个来源同时要开悟时，任一撤销都**不会**退出开悟模式。",
    "--     这是 boolean 型 SourceModifierList 的核心价值。",
    "--   第二个参数 source 通常传 inst 自身（生成器 ID），见 :185。",
  ],

  // ============ Penalty ============
  "Sanity:AddSanityPenalty#1": [
    "--【★★AddSanityPenalty：代价机制的写入端】",
    "--   ★ 签名是 (key, mod) —— mod 是**比例**不是点数。",
    "--     例如 waxwell.lua:58 传入 TUNING.SHADOWWAXWELL_SANITY_PENALTY[种类] = .2，",
    "--     含义是「带 1 个该影子，理智上限降 20%」。",
    "--     用比例而非点数，是为了在 max 因角色而异时仍有一致的手感。",
  ],
  "Sanity:AddSanityPenalty#1+1": [
    "--   ★ 覆盖式写入：同一个 key 再次 Add 会替换旧值而非累加。",
    "--     所以waxwell.lua 里用pet 作为 key 传进来是安全的。",
  ],
  "Sanity:RemoveSanityPenalty#1": [
    "--   Remove：删key 后立刻重算，保证「摘掉最后一个影子立刻恢复上限」。",
  ],
  "Sanity:RecalculatePenalty#1": [
    "--【RecalculatePenalty：把所有 penalty 条目折算成一个 0~1 的比例】",
    "--   ★ 每次增删都全量重算（而不是增量加减）——",
    "--     因为字典的遍历顺序不确定，增量法在「同一 key 重复覆盖」时必然算错。",
    "--     条目数量极少（个位数），全量重算的代价可忽略，",
    "--     换来的是「不可能算错」，这是典型的正确性优先取舍。",
  ],
  "Sanity:RecalculatePenalty#1+7": [
    "--   ★★ 上限约束：players cannot go lower than 5 max sanity。",
    "--     硬底线是「无论代价叠多少，理智上限至少 5 点」，",
    "--     换算成比例就是 1 - 5/max（max 通常 200，故为 0.975）。",
    "--   ★ 设计意图（源码注释也解释了）：",
    "--     被 min() 截断后，实际 penalty 会**小于**调用方累加出来的总和。",
    "--     于是「上限被截断了，就说明还得继续移除若干条目才降得回来」——",
    "--     换句话说，惩罚到了顶，移除的收益也会随之递减，形成天然的平衡。",
    "--   参见 tuning.lua:2162 的 MAXIMUM_SANITY_PENALTY = 0.9：",
    "--     那是**建造/生成时**的准入门槛（waxwelljournal.lua:134），",
    "--     与这里的 1-5/max 是两套不同的限制，不要混淆。",
  ],
  "Sanity:RecalculatePenalty#1+9": [
    "--   ⚠ 疑似缺陷（边界）：这里直接除以 self.max，未做 max <= 5 的防护。",
    "--     推理依据：若 max 被设成小于 5（SetMax 允许传任意值，:312），",
    "--       1-5/max 将变成负数，min() 会得到负 penalty，",
    "--       于是 GetMaxWithPenalty（:323）返回 > max 的「上限」，",
    "--       反而让玩家理智变多。",
    "--     实际影响：极低——所有角色 max 都远大于 5（Wilson 200），",
    "--       且这条路径需外部主动传小值才能触发。",
    "--     ★ 但它揭示了一个真实约束：本组件默认 max 必须 > 5，",
    "--       构造函数里的默认 100 是安全的。",
  ],
  "Sanity:RecalculatePenalty#1+11": [
    "--   同样借 DoDelta(0) 把新的上限同步出去。",
  ],
};

export const AFTER = {};