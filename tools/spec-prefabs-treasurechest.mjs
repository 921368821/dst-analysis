// spec-prefabs-treasurechest.mjs —— prefabs/treasurechest.lua 逐行深度注释的「行号 → 注释」映射
// 配合 build-prefabs-treasurechest.mjs 使用。
//
// 约定：
//   key   = 源文件行号（1-based），注释插入到该行「之后」
//   value = 注释数组（每项一行，均以 -- 开头；空字符串表示空行）
//
// ⚠️ 行号必须与源文件严格对应（源文件共 773 行）。

export default {
  // ══════════════ 文件头 ══════════════
  1: [
    '-- ============================================================',
    '-- treasurechest.lua —— 宝箱族（「预制体工厂 + 变体派生」的教科书）',
    '--',
    '-- 【这个文件演示了什么架构】',
    '-- 用一个 MakeChest(name, bank, build, indestructible, master_postinit,',
    '-- prefabs, assets, common_postinit, force_non_burnable) 工厂函数，',
    '-- 在末尾 return 里派生出 5 个宝箱变体 + 1 个独立特效实体。',
    '-- 5 个变体共用同一份 fn 代码体，差异全部通过「两个后置钩子」注入：',
    '--   common_postinit —— 两端都跑（A 段内，SetPristine 之前）',
    '--   master_postinit —— 仅服务端（C 段内）',
    '--',
    '-- 【★ 钩子的设计价值】这是预制体层实现「配置化差异」的标准手法：',
    '--   主干代码只写一遍共性，变体只写差异。没有继承、没有 if name == "xxx" 的散弹式分支。',
    '--   对比同文件第 132 行的 `if name == "pandoraschest" or name == "terrariumchest"`',
    '--   —— 这就是「散弹式分支」的反面教材：主干里混进了变体专属逻辑。',
    '--',
    '-- 【⚠️ 已读出的架构债（本人核实过行号）】',
    '-- 1) 第 132 行与第 96-99 行的 ChestsWithoutIcons 都是把「变体判定」写进主干，',
    '--    说明这套钩子机制没有覆盖「美术差异」这一类需求。',
    '-- 2) 第 769 行拼写错误：minotuar_master_postinit（多了个 a），',
    '--    定义处（第 538 行）与使用处一致所以能跑，但 grep 时容易漏。',
    '--',
    '-- 【上游来源】Klei Entertainment《Don\'t Starve Together》游戏脚本',
    '-- ============================================================',
  ],

  // ══════════════ 资源与依赖 ══════════════
  3: [
    '-- 【★ 资源清单的「分层」技巧】这里只声明了 upgraded（升级后）的动画包，',
    '-- 普通的 treasure_chest 动画包没在这里声明 —— 它在 MakeChest 内部的 default_assets 里。',
    '-- 原因见第 107 行：不同变体需要的公共动画不同，所以要「进函数再合并」，不能在文件头写死。',
    '-- ⇒ 资源清单可以是「文件级」也可以是「变体级」，两者用 JoinArrays 合并（第 107 行）。',
  ],
  5: [
    '-- 升级版宝箱动画包。★ 注意文件名带 _upgraded，而实际 bank 是 "chest_upgraded"',
    '-- （第 304 行）—— zip 文件名与 bank 名可以不同名，不必一致。',
  ],
  8: [
    '-- 【依赖清单】4 个子预制体：塌方特效、升级特效、月亮石碎片、塌掉的宝箱残骸。',
    '-- ★ collapsed_treasurechest 是「变体转实体」的关键：宝箱被打到超载时会变成另一个实体（第 230 行）。',
    '-- 在 DST 里，「同一个物体换个形态」有两条路：',
    '--   a) 换 AnimState 的 bank/build + 打 tag（轻，成本低，如 pighouse 的 burnt）',
    '--   b) ReplacePrefab / 换成另一个预制体（重，但能换组件结构，如第 450 行的 chest_mimic）',
    '-- ★ 本文件两种都用了，是很好的对照样本。',
  ],

  // ══════════════ 音效表 ══════════════
  18: [
    '-- 【★ 音效「表驱动 + 可覆写」的范式】',
    '-- 音效路径写进 inst.sounds（第 148 行，服务端赋值），回调里读 inst.sounds.open。',
    '-- ★ 好处：开箱音效可以按变体整表替换（第 760 行 ancient 就整张换成 ANCIENT_SOUNDS），',
    '-- 无需改动任何回调。移植时把这个模式抄走，比散落硬编码字符串好维护得多。',
  ],

  // ═════════════─ 通用回调 ══════════════
  24: [
    '-- 【★ 皮肤音效覆写三层】onopen 先查 inst.skin_open_sound（玩家皮肤带的自定义音效），',
    '-- 没有才回退到 inst.sounds.open。',
    '-- 这是 DST 皮肤系统的标准接入点：皮肤表可以给任意预制体挂自定义音效，',
    '-- 预制体本身无需任何改动。移植时把「皮肤覆写」放在回退链最前面。',
  ],
  36: [
    '-- onclose：PlayAnimation + PushAnimation("closed", false)。',
    '-- ★ PushAnimation 的第 2 参数 false = 播完停在最后一帧，不循环。',
    '-- 与 PlayAnimation("closed") 的区别：后者播完会回到 idle。',
    '-- 「关箱后要一直保持关闭姿态」这个需求，两行代码说清楚。',
  ],
  49: [
    '-- onhammered：锤爆宝箱的标准收尾序列。★ 顺序：灭火 → 掉战利品 → 倒空容器 → 塌方 → Remove。',
    '-- 第 54-56 行的容器检查是防御式的：烧毁状态下 components.container 可能已被移除（第 316 行注释提到）。',
  ],
  63: [
    '-- onhit：每敲一下就把东西全倒出来。',
    '-- ★ 设计意图：玩家敲宝箱的语义是「我要拿东西」，所以不等敲完就先倒出来。',
    '-- 这是「交互反馈即时性」的经典处理 —— 动作与反馈同步，不让玩家干等 4 秒。',
  ],
  74: [
    '-- 源码原注释 V2C: also used for restoredfromcollapsed。',
    '-- ★ 含义：onbuilt 同时被「玩家放置」与「从塌陷状态恢复」两条路径复用，',
    '-- 所以末尾第 340 行还专门注册了 restoredfromcollapsed 事件来调它。',
    '-- 一个回调服务两条路径，是预制体里常见的复用手法（移植时注意别把两条路径的差异也混进来）。',
  ],
  85: [
    '-- 【存读档】只存 burnt 一个布尔。容器内容由 container 组件自己存（inventory 组件）。',
    '-- ★ 这体现了存档的分工原则：预制体只存「跨组件的复合语义」，单一组件内部状态归组件自己管。',
  ],
  91: [
    '-- onload 同样只处理 burnt。data 为 nil 表示「新生成」，必须判空。',
  ],

  // ══════════════ ChestsWithoutIcons ══════════════
  97: [
    '-- ★ 这是一张「按名字排除小地图图标」的表：只有 boat_ancient_container 不画图标。',
    '-- 为什么不用 tag？—— 因为这个判断要在 SetPristine 之前做（第 115、120 行），',
    '-- 那时 AddComponent 还没开始，只能用普通 Lua 表 + 名字判断。',
    '-- ⚠️ 这暴露了钩子机制的一个盲区：变体专属的「表现层差异」无处安放，只能塞进主干。',
  ],
  100: [
    '-- ============================================================',
    '-- ★★★ MakeChest —— 预制体工厂函数。本文件的核心。',
    '--',
    '-- 【9 个参数逐个说】',
    '--   name                 —— 变体名，也是 Prefab 注册名与 MiniMap 图标名（第 121 行）',
    '--   bank / build         —— 动画命名空间',
    '--   indestructible       —— 是否不可破坏。第 159 行：为真则不加 lootdropper/workable/burnable',
    '--   master_postinit      —— 仅服务端钩子（第 184 行调用）',
    '--   prefabs              —— 依赖清单，可为 nil（第 107 行有判空）',
    '--   assets               —— 变体专属资源，可为 nil',
    '--   common_postinit      —— 两端钩子（第 138 行调用，★ 注意它在 SetPristine 之前）',
    '--   force_non_burnable   —— 强制不加 burnable（第 167 行，与 indestructible 是两条独立开关）',
    '--',
    '-- 【★ 为什么 common 与 master 两个钩子够用】',
    '-- DST 预制体的两端差异只有三类：',
    '--   1) 纯表现（图标、图层、tag）→ common_postinit 两端都跑',
    '--   2) 逻辑组件 / 事件 / 存档   → master_postinit 仅服务端',
    '--   3) AnimState 字段           → 直接写在 fn 里（两端都跑）',
    '-- 覆盖这三类就够绝大多数变体；覆盖不了的（如上节 ChestsWithoutIcons）只能打补丁。',
    '-- ============================================================',
  ],
  101: [
    '-- default_assets：所有宝箱共有的三个动画包。',
    '-- ★ ui_chest_3x3.zip / ui_chest_upgraded_3x3.zip 看着是 UI 资源，',
    '-- 实际是被 container 组件的 WidgetSetup（第 152 行）用来渲染物品格子的。',
    '-- ⇒ 物品容器格子不是每个预制体自己画的，而是 container 组件按名字去要动画包。',
  ],
  107: [
    '-- ★ JoinArrays（而非直接覆盖）：变体传入的 assets 与 default_assets 合并，不是替换。',
    '-- 「变体可以追加，不能删除公共资源」—— 这是合并语义，改成覆盖会让变体丢掉 UI 动画包。',
    '-- 判空写法 `assets ~= nil and JoinArrays(...) or default_assets` 依赖 Lua 的 and/or 真值语义，',
    '-- ★ 注意 JoinArrays 若返回空表会被当成假值走错分支 —— 本例不会，但移植时要小心。',
  ],

  // ══════════════ fn() ══════════════
  109: [
    '-- 【★ fn 的结构与 pighouse 完全同构：A 段 → SetPristine → 客户端返回 → C 段】',
    '-- 差别在于本文件把 A 段末尾插了两行钩子调用（第 138-140 行）。',
  ],
  115: [
    '-- ★ 两端都要跑同一个判断（第 120 行又判了一次）。',
    '-- 写两遍是因为第 116 行 AddMiniMapEntity 只在有图标时才执行，而第 121 行 SetIcon 需要组件存在。',
    '-- 抽成 if 块内联会更清晰，此处写成两个 if 属于风格差异，不影响正确性。',
  ],
  118: [
    '-- AddNetwork 必须排在小地图之后（与 pighouse 第 365-370 行同一约束）。',
  ],
  130: [
    '-- ★ scrapbook_* 系列是「图鉴系统」的钩子字段：本文件所有 scrapbook_ 字段都不参与网络同步，',
    '-- 由图鉴 UI 在服务端读取。',
    '-- 扫读源码时看到大量 scrapbook_ / docs_ 赋值会以为是杂物，实际是给「书页收集」用的元数据。',
  ],
  132: [
    '-- ⚠️ ★ 反面教材：变体专属逻辑被写进主干。',
    '-- 这一行在通用工厂里判名字，虽然能用，但每加一个变体就要回来改这里。',
    '-- 更好的做法是把 scrapbook_specialinfo 也做成变体参数。',
    '-- 本人已核实：这就是本文件唯一把变体判定泄漏进主干的地方，其余都走了钩子。',
  ],
  136: [
    '-- MakeSnowCoveredPristine（第 177 行的非 Pristine 版与之配对）。',
    '-- ★ 必须在 SetPristine 之前调用，理由见 pighouse.lua 第 389 行注释。',
  ],
  138: [
    '-- ★★★ common_postinit 的调用点 —— 在 SetPristine 之前（第 142 行）。',
    '-- ⇒ 变体的 common_postinit 可以设置任何会被网络快照带走的字段（tag、AnimState、layer 等）。',
    '-- 这是它与 master_postinit 的根本区别，写钩子时务必知道自己属于哪一侧。',
  ],
  142: [
    '-- ★★★ SetPristine：网络快照点。到此为止的设置会同步给客户端。',
    '-- 与 pighouse.lua 第 401 行、boat.lua 各变体的 SetPristine 是同一个角色。',
  ],
  144: [
    '-- 客户端在此返回。★ 客户端拿到的宝箱 = 外观 + 小地图图标 + 雪，',
    '-- 没有 container / workable / lootdropper —— 它「看起来是个箱子」但不能被搜刮。',
    '-- 物品格子由 container 组件的 replica 单独渲染，不由客户端的 fn 负责。',
  ],
  148: [
    '-- ★ inst.sounds = SOUNDS 在 C 段（服务端）。',
    '-- 看似与网络无关，为什么要放服务端？因为 onopen/onclose 回调（也是服务端函数）要用它。',
    '-- ★ 推论：音效路径本身不需要同步，客户端另有 replica 机制播放开箱音。',
  ],
  151: [
    '-- 【container 组件】物品容器。★ WidgetSetup(name) 用预制体名去查物品格布局，',
    '-- 这就是为什么 default_assets 里要有 ui_chest_3x3.zip。',
    '-- 不同尺寸的箱子（3x3 / 4x4）由不同的 ui_*.zip 动画包定义，靠名字约定关联。',
  ],
  155: [
    '-- ★★ skipclosesnd / skipopensnd = true：告诉 container 组件「别自己播开箱音」。',
    '-- 因为音效已经在 onopen/onclose 里播了（第 24、36 行），不关掉会播两遍。',
    '-- ⇒ 【坑】加自定义开箱音效时必须同时设这两个开关，否则双音。',
    '-- 这是「组件自带行为 vs 预制体覆写行为」冲突时，标准的两处同时改的解法。',
  ],
  159: [
    '-- ★ indestructible 的分支：不可破坏的宝箱（pandoraschest / minotaurchest）',
    '-- 不挂 lootdropper、不挂 workable、不加 burnable。',
    '-- ⇒ 不可破坏宝箱上没有 lootdropper，第 186 行 onhammered 若被误调会崩，',
    '-- 所以那里也做了 ~= nil 检查（第 53 行）。防御式编程的连锁反应。',
  ],
  167: [
    '-- ★ force_non_burnable 独立于 indestructible：sunkenchest 是 indestructible=false（第 772 行）',
    '-- 但传了 force_non_burnable=true，所以可锤（会出东西）却不可烧。',
    '-- ⇒ 这两个开关是正交的，组合出 4 种「宝箱耐受度」，比再写两个工厂函数优雅。',
  ],
  173: [
    '-- hauntable：闹鬼系统钩子。HAUNT_TINY 是最低档（宝箱上很难触发闹鬼）。',
    '-- ★ 所有组件都在 C 段，说明 Lua 组件不参与网络同步，其 replica 由组件自身处理。',
  ],
  180: [
    '-- 源码注释 Save / load is extended by some prefab variants —— ★ 明说了主干的存档钩子会被变体覆盖。',
    '-- 覆盖方式见第 410 行 regular_master_postinit 里的 `inst.OnLoad = regular_OnLoad`：',
    '-- 新函数里显式调用 onload（第 370 行）再补变体逻辑。',
    '-- ⇒ 【范式】覆写钩子时务必「先调父实现再补逻辑」，忘了调就会丢掉 burnt 的恢复。',
  ],
  184: [
    '-- ★★★ master_postinit 的调用点 —— 在 C 段（仅服务端）。',
    '-- 变体可以在这里 AddComponent、ListenForEvent、覆写 OnSave/OnLoad。',
  ],
  191: [
    '-- Prefab(name, fn, assets, prefabs)：★ 工厂函数返回的正是标准 Prefab 对象，',
    '-- 所以 5 个变体在全局表里是完全平级的 5 个名字，彼此没有父子关系。',
    '-- 「变体」在 DST 里不是继承出来的类型，只是调用同一段代码的不同参数。',
  ],

  // ══════════════ regular 变体 ══════════════
  194: [
    '-- 源码此处是分隔注释带（长注释块），后面每一节对应一个变体。',
    '-- ★ 这种「一个文件里横向铺开多个变体」的排版是 DST 变体文件的标准做法。',
  ],
  198: [
    '-- 【inspectable.getstatus】升级后显示 UPGRADED_STACKSIZE。',
    '-- ★ 用 inst._chestupgrade_stacksize 这个普通字段当标志，而不是读 upgradeable 组件 ——',
    '-- 因为升级可能被重置，字段由 OnUpgrade 显式维护（第 315 行置 true，没有任何地方置回 false）。',
    '-- ⚠️ 真实缺陷（本人核实过）：第 315 行只有 `inst._chestupgrade_stacksize = true`，',
    '-- 全文件 grep 无任何置回 false 的分支。也就是说 upgradeable 组件的升级被回退时，',
    '-- 这个标志不会清掉，检查文本会错报为已升级。实际影响很小（升级不可逆），故属「潜在」而非「触发」。',
  ],
  202: [
    '-- ConvertToCollapsed：把宝箱转成「塌陷残骸」实体的核心逻辑。',
    '-- ★ 这是「换实体」而非「换外观」：第 230 行 pile:SetChest(inst, burnt) 把原实体塞进残骸里。',
  ],
  208: [
    '-- ★ 临时改 lootdropper 的 min_speed/max_speed（第 212-213 行），掉落完再改回 nil（第 221-222 行）。',
    '-- 这是「临时覆写组件字段」的手法：借用组件的掉落物理但换手感。',
    '-- ⚠️ 陷阱：若在 DropLoot 执行期间实体被 Remove，第 221-222 行不会执行，',
    '-- 字段残留在组件上；因为组件随实体一起销毁，实际无害，但这个模式本身很脆弱。',
  ],
  214: [
    '-- burnt 分支的技巧：先 AddTag("burnt") 再 DropLoot 再 RemoveTag("burnt")。',
    '-- ★ 意图是「临时让 lootdropper 知道自己正在烧毁」，从而掉落烧毁版战利品。',
    '-- 全靠 tag 做状态传递，没有临时变量 —— 因为回调链很深，中间插一个布尔反而更容易漏清。',
  ],
  244: [
    '-- ★★ ShouldCollapse：判断宝箱是否因为「无限堆叠容量」而超载到要塌。',
    '-- 第 252 行 math.ceil(StackSize() / maxsize) 把「实际堆叠数」折算成「占了几格容量」，',
    '-- 累加得到 overstacks，超过阈值就塌。',
    '-- ⇒ 这是「升级给的福利也有代价」的设计：无限堆叠 → 容易超载 → 变成塌不回来的残骸。',
    '-- 第 246 行原注释说明前置条件：应该已经调过 DropEverything(nil, true)，所以剩下的都是超载物。',
  ],
  262: [
    '-- ★ 锤击时先判是否该塌，塌则转残骸并 return，不塌才走默认 onhammered（第 289 行）。',
    '-- 第 264 行 IsPassableAtPoint 分支：地形上放不下残骸时（沉在水里等），改为直接销毁并多掉一些。',
    '-- 第 271 行原注释：沉掉的会掉更多但会丢一部分 —— 平衡性上的有意取舍。',
  ],
  292: [
    '-- restoredfromcollapsed：从残骸恢复时的重建动画与音效。复用了 onbuilt 的音效字段。',
  ],
  302: [
    '-- DoUpgradeVisuals：★ 换 AnimState 的 bank + build 来表现「升级」。',
    '-- 第 303 行从当前 skin 名里剥掉 treasurechest_ 前缀，套到新 build 上 ——',
    '-- ⇒ 皮肤在换 build 之后仍能保持，是「皮肤与形态解耦」的关键一行。',
  ],
  312: [
    '-- ★★★ OnUpgrade：升级系统的接入点。upgradeable 组件调用它。',
    '-- 第 313 行读 numupgrades 只处理第 1 次升级 —— 宝箱只能升一次。',
    '-- 第 333 行把 upgradetype 置 nil：升级完成后清掉「待升级」标记，防止重复触发。',
  ],
  316: [
    '-- ★ 原注释由 Klei 工程师本人留下：The container component goes away in the burnt load',
    '-- but we still want to apply builds。',
    '-- ⇒ 读源码时看到 nil 检查不要当成「防御性冗余」，很多是踩过坑之后留下的补丁。',
  ],
  327: [
    '-- ★★ total_hide_frames = 6，原注释明确要求 Keep in sync with fx.lua! [CUHIDERFRAMES]。',
    '-- 升级特效动画播放期间宝箱要隐藏 6 帧，这个数字同时硬编码在别处。',
    '-- ⚠️ 真实技术债（本人核实过行号）：同一个 6 出现在 4 个位置 ——',
    '--   prefabs/treasurechest.lua:327（本行）、prefabs/dragonfly_chest.lua:165、',
    '--   fx.lua:3331、fx.lua:3364（两处都是 fx 定义）。',
    '-- 四处靠 [CUHIDERFRAMES] 这个注释标记人工同步，无任何编译期检查。',
    '-- 【移植建议】这类跨文件共享常量应收敛到 TUNING 或常量表；注释约定是最脆弱的一种同步。',
  ],
  333: [
    '-- ★ upgradetype = nil 的位置很关键：在所有 Upgrade 逻辑走完之后统一清空。',
    '-- 放在最后一行（337）之前，确保中途出错时升级标记还在，可以被重试。',
  ],
  335: [
    '-- 升级完成后 lootdropper 的战利品表被整体换成 alterguardianhatshard（原表被替换）。',
    '-- ★ 与 ConvertToCollapsed 的「临时改再改回」不同，这里是永久替换。',
  ],
  343: [
    '-- regular_OnBurnt：烧毁时的处理。★ 第 344-345 行先把升级态清干净再走塌陷逻辑。',
    '-- 第 316 行的注释在这里兑现了：第 347 行果然判 container ~= nil。',
  ],
  366: [
    '-- ★ regular_OnLoad：读档时若存档里有升级记录，当场补跑一次 OnUpgrade。',
    '-- 第 368 行 `OnUpgrade(inst)` 只传了一个参数 —— 但 OnUpgrade 第 313 行要读',
    '-- inst.components.upgradeable.numupgrades，此时组件已存在（upgradeable 自己会存）。',
    '-- 第 370 行显式调用通用 onload 收尾 burnt。★ 这就是第 180 行注释说的「扩展主干的存档」。',
  ],
  373: [
    '-- 【ondeconstructstructure 事件】拆除（长按拆除键）流程。与锤击走同一个塌陷判定。',
    '-- 第 384 行 no_delete_on_deconstruct = true：告诉拆除系统「别删，我变成残骸了」，',
    '-- ⇒ ★ 这是「函数返回前设置标志位」式的协程式协作：拆除系统读这个字段决定后续动作。',
  ],
  396: [
    '-- regular_common_postinit：两端钩子。★ SetDeploySmartRadius(0.5) 与 recipe 的 min_spacing/2 对齐，',
    '-- 注释明说这是为了防止放置时与其它建筑重叠。',
    '-- ⇒ 【坑】改了 recipe 的 min_spacing 却没改这里，放置检查会与实际间距不一致。',
  ],
  400: [
    '-- regular_master_postinit：服务端钩子。',
    '-- ★ 第 403-405 行的顺序：AddComponent 先，再 Configure。',
    '-- upgradeable.upgradetype 是直接赋字段（第 404 行），SetOnUpgradeFn 是方法（第 405 行）——',
    '-- 两种风格混用，见 pighouse.lua 第 417 行的同类说明。',
  ],

  // ══════════════ pandora 变体 ══════════════
  413: [
    '-- 源码分隔注释带。★ 每节结构一致：一张 adddeps 表 + 一个 master_postinit。',
  ],
  417: [
    '-- 【★ 图鉴依赖表】列出这个宝箱「图鉴里会解锁哪些物品」。',
    '-- ★ 这是数据驱动的绝佳范例：想改宝箱图鉴内容，只改这张表，不碰任何逻辑。',
    '-- 移植时把这类「纯数据 + 一行读取」的清单抽出来，策划就能自己配。',
  ],
  437: [
    '-- pandora_master_postinit：★ 本变体的核心是「重置陷阱」——监听世界的 resetruins 事件。',
    '-- 第 440 行的 ListenForEvent 第 3 参数传 TheWorld：表示监听的是世界对象而不是猪/物品，',
    '-- 这样回调签名变成 (inst, data)，data 就是事件数据。★ 这是 DST 事件系统的标准写法。',
  ],
  444: [
    '-- ★ 「这个宝箱要不要变成 mimic（拟态怪）」的三重判定：',
    '--   世界组件存在 → 组件启用 → 概率命中。',
    '-- 第 447 行概率来自 TUNING.CHEST_MIMIC_CHANCE，不是硬编码 —— 平衡性数值统一在 TUNING。',
    '-- ⇒ 【移植要点】概率型行为一律走 TUNING + TryLuckRoll（见第 556 行 crabking/deciduous 同款），',
    '-- 且要考虑玩家的 luck 修正，否则玩家会觉得「概率不对」。',
  ],
  450: [
    '-- ★★ ReplacePrefab(inst, "chest_mimic")：把现有实体换成另一个预制体，保留 GUID 与位置，',
    '-- 客户端因此不会看到「删一个生成一个」的闪烁。',
    '--',
    '-- ⚠️ ★ 这里有一处很容易看错的写法，务必分清：',
    '-- 回调是 function() 无参（第 440 行），所以 `inst` 是 pandora_master_postinit 的【形参】。',
    '-- 第 450 行的赋值把【形参本身】改成了新实体，因此第 453、456、461、468、473 行',
    '-- 读到的都是新实体 —— ★ 运行时完全正确，不是缺陷。',
    '-- 第 497 行同理（在另一个无参回调里），后续代码也全部基于新 inst。',
    '--',
    '-- ⇒ 【为什么仍值得警惕】这种「重绑定形参」的模式让「哪个实体在生效」只存在于阅读顺序里。',
    '-- 一旦有人在回调末尾追加一行捕获了旧 inst 的逻辑，或把某行挪到 ReplacePrefab 之前，',
    '-- 就会静默地对已不存在的旧实体操作，且 Lua 不会给任何警告。',
    '-- 【移植建议】写成 `local newinst = ReplacePrefab(inst, ...)` 并在后续统一用 newinst，',
    '-- 让「换实体」这件事在代码里显式可见。',
  ],
  461: [
    '-- scenariorunner 组件：用「剧本」驱动一个既有实体的行为。',
    '-- ★ 这是 DST 处理「已有实体中途获得一段剧情」的通用手法：',
    '-- 不换预制体、不重写逻辑，挂一个 runner 跑脚本。',
    '-- 与第 450 行的 ReplacePrefab 是两条不同的路线，此处选了「保留原实体 + 加剧本」。',
  ],
  477: [
    '-- ms_riftaddedtopool 事件：又一条会触发 mimic 的路径（月亮裂隙生成时）。',
    '-- ★ 第 485-486 行原注释解释了一个精妙的设计权衡：',
    '-- 这里只检查组件「存在」而不检查「启用」，是为了不依赖事件监听器的注册顺序。',
    '-- ⇒ 【可移植的设计模式】当 A 事件与 B 状态之间存在顺序依赖时，检查「存在性」比检查「状态」更稳。',
  ],

  // ══════════════ minotaur 变体 ══════════════
  521: [
    '-- 又一张 adddeps 表。★ 与 pandora 的差别只在物品清单，逻辑结构完全一致。',
  ],
  538: [
    '-- ⚠️ ★ 真实拼写错误：minotuar（多了字母 a），正确应为 minotaur。',
    '-- 本人已核实：第 538 行定义、第 769 行使用，两处拼写一致所以运行时正常。',
    '-- 影响仅为「grep minotaur_master_postinit 搜不到」，属代码整洁性问题而非功能缺陷。',
  ],
  545: [
    '-- ★ 注意第 545 行多了一个条件 `if not inst:IsAsleep() then`，把塌方特效限制在实体醒着时。',
    '-- 对比第 540 行的 pandora 版本：先判断 is_asleep 再决定播不播动画与音效。',
    '-- ⇒ 【DST 通则】生成特效前查 IsAsleep：睡着的实体不需要视觉表现，省掉一批无谓的 SpawnPrefab。',
  ],

  // ══════════════ terrarium 变体 ══════════════
  562: [
    '-- terrarium_GetStatus：用 and/or 链做三态返回。',
    '-- ★ 第 563 行的 inst.fx ~= nil 是「特效实体还在吗」而非组件状态 ——',
    '-- 服务端持有 fx 引用，客户端没有，因此这个状态只能服务端算。',
  ],
  568: [
    '-- ★★ terrarium_removefx 是「双向注册 + 解除」的完整示范：',
    '-- 第 572-573 行把两个事件监听都摘掉，避免重复触发与悬空回调。',
    '-- 第 574 行 KillSound("shimmer") 掐掉循环音。',
    '-- ⇒ 【范式】任何「挂上去的东西」都要成对摘掉：事件回调、SoundEmitter 通道、子实体引用。',
  ],
  598: [
    '-- terrarium_master_postinit。★ 第 600 行给 inspectable 装上 getstatus ——',
    '-- 工厂主干（第 150 行）只 AddComponent("inspectable") 而不设 getstatus，',
    '-- 所以各变体自行填充（regular 在第 319 行、sunken 在第 705 行，regular 烧毁时第 345 行清空）。',
    '-- ⇒ 说明 getstatus 这一层钩子没做进工厂，是本文件钩子机制的第三个盲区（前两个见第 97、132 行）。',
  ],
  602: [
    '-- ★ TUNING.SPAWN_EYEOFTERROR 开关：只有开了这个「眼球错误」特性才发微光特效。',
    '-- 第 603 行 DoTaskInTime(0, ...) 再一次印证「二次初始化必须推迟一帧」。',
  ],
  611: [
    '-- ⚠️ 风格不一致（本人核实过）：本闭包形参是 i（第 603 行 function(i)），',
    '-- 第 605-609 行全部用 i，唯独本行用 inst —— inst 是 terrarium_master_postinit 的形参（第 598 行）。',
    '-- 分析：DoTaskInTime 回调收到的 i 就是同一个实体（引擎回传 inst 自身），因此运行时无差别，不是缺陷。',
    '-- ⇒ 但【移植建议】统一用 i。这类混用一旦出现在「谁被替换成谁」的逻辑附近就会变成真 bug，',
    '-- 可参考第 450 行 pandora 的对照：那里因为要 ReplacePrefab 才必须区分两个指代。',
  ],

  // ══════════════ terrariumchest_fx 独立预制体 ══════════════
  617: [
    '-- ★★ 这是本文件里唯一「不走 MakeChest 工厂」的手写预制体 —— 一个纯客户端特效实体。',
    '-- 它的价值在于示范了另一个模式：★★ 父实体 + 独立特效子实体 的一对多关系。',
    '-- 第 632-644 行的 fx_front 又是第三层（父 → inst → fx_front），',
    '-- 用 SetFinalOffset(-3) 把它压到最底层做「箱体内部」的观感。',
    '-- ⇒ 【2.5D 渲染技巧】同一个 z 平面上，靠 FinalOffset 排前后：',
    '--   箱体 0 / 微光后层 +1 / 箱体前层 -3。数值是任意的，只要相对关系对。',
  ],
  621: [
    '-- ★ 特效实体也 AddNetwork —— 因为它有 SetParent（第 606 行）且服务端也要管它的生命周期。',
    '-- 与 pighouse 的窗户（无 Network）不同：那个纯视觉、这个有服务端逻辑。',
    '-- ⇒ 判据是「服务端是否需要感知这个实体的存在」，不是「它是不是特效」。',
  ],
  631: [
    '-- ★ 第 631 行的 not TheNet:IsDedicated() 嵌在 SetPristine（第 646 行）之后，',
    '-- 意味着 fx_front 只在有画面的机器上创建，但它的创建指令参与了网络快照 ——',
    '-- 即「客户端本地创建、服务端知晓编号但不管内容」。',
    '-- ⚠️ 这比 pighouse 的窗户复杂（窗户纯不联网），移植时容易搞混两种模式。',
  ],
  638: [
    '-- ★ fx_front 带 CLASSIFIED 标签但没带 NOCLICK：',
    '-- CLASSIFIED = 「分类子实体」的通用约定（在实体树里属于 inst 的一个命名子槽）。',
    '-- 不加 NOCLICK 是因为它有自己的 AnimState 且需要跟随父实体变换，不该被射线完全忽略。',
  ],
  652: [
    '-- ★ persists = false 放在 C 段（服务端）—— 与 pighouse 第 321 行放在函数体中间不同。',
    '-- 两者都合法，只要在 Remove 前设置即可。',
    '-- 【移植提示】persists 属于「存档策略」，位置无所谓；entity:AddXxx 属于「结构」，顺序有讲究。',
  ],

  // ══════════════ sunken 变体 ══════════════
  661: [
    '-- sunken_onhit：沉箱的受击表现。★ 与通用 onhit（第 63 行）的区别：',
    '-- 这里只 PlayAnimation 不倒空容器 —— 沉箱没法打开（第 719 行 canbeopened=false）。',
  ],
  675: [
    '-- 【★ 装备槽符号覆盖】sunkenchest 竟然可以装备（EQUIPSLOTS.BODY）——',
    '-- 举起宝箱时玩家模型被替换成宝箱的图案（第 679 行 OverrideSymbol）。',
    '-- ★ 这是「容器当装备」的玩法设计，也说明 component 可组合出预制体作者没预期的组合。',
  ],
  699: [
    '-- ★★ 依赖表来自别的模块：require("messagebottletreasures").GetPrefabs()。',
    '-- 收益：消息瓶宝藏的内容改了，这里自动跟着变，不用重复维护一张表。',
    '-- ⇒ 【可移植模式】当多个预制体共用一份清单时，让清单的定义方导出、这边 require，',
    '-- 而不是各抄一份。方向单一，出错面小。',
  ],
  701: [
    '-- sunken_master_postinit：这个变体加的组件最多（heavyobstaclephysics / inventoryitem /',
    '-- equippable / submersible / symbolswapdata），共 5 个。',
    '-- ⇒ 一个变体加 5 个组件而不改一行主干代码 —— 这就是「组合优于继承」的具体收益。',
  ],
  710: [
    '-- ★ inventoryitem.cangoincontainer = false：宝箱本身不能塞进别的容器。',
    '-- 配合第 713 行的 equippable，它变成了「可举着但不可入包」的道具。',
    '-- ⇒ 这类「反向能力」靠给组件字段赋 false 实现，是 Lua 动态性的直接体现；',
    '-- 在静态语言里需要专门造一个「不可入包物品」子类。',
  ],
  719: [
    '-- ★ container.canbeopened = false：直接改组件内部字段来禁用功能。',
    '-- 这也是第 688 行 sunken_GetStatus 能返回 LOCKED 的原因 —— 它读的就是这个字段。',
    '-- ⚠️ 陷阱：canbeopened 是 container 的实现细节，不是公开 API，升级 container 组件时要复查。',
  ],
  728: [
    '-- ANCIENT_SOUNDS：整表替换（第 760 行 inst.sounds = ANCIENT_SOUNDS）。',
    '-- ★ 印证第 18 行注释说的「表驱动 + 可覆写」：变体替换整张表，回调一行不改。',
  ],
  734: [
    '-- ancient_container_common_postinit：★ 又一个「两端钩子干表现层的事」的实例。',
    '-- 第 738 行 SetLayer(LAYER_WORLD_BACKGROUND) 让它渲染在背景层（配合第 735 行 OCEAN_BOAT 的 sortOrder）。',
    '-- 第 740-741 行两个 tag 说明它不可阻挡、不可交互 —— 因为它沉在海底。',
  ],
  750: [
    '-- ★ 原注释明写 This is called manually in boat.lua。',
    '-- ⇒ 跨文件耦合：treasurechest.lua 的 ancient 容器，其 OnPlaced 由 boat.lua 第 1543 行手动调用。',
    '-- ⚠️ 这是本文件唯一的跨文件硬耦合。若 boat.lua 那行被删，箱子会一直保持隐藏状态。',
    '-- 【移植建议】这种「手动调 OnPlaced」的约定应改为显式事件，否则无法静态追踪。',
  ],

  // ══════════════ return ══════════════
  766: [
    '-- ★★★ return 语句 —— 本文件的全部「变体派生声明」。9 个实体，全部平级。',
    '--',
    '-- 【逐个对照 MakeChest 参数，理解每列的作用】',
    '-- 1. treasurechest          —— 普通宝箱：可破坏可烧，挂了 upgradeable（支持升级）',
    '-- 2. treasurechest_placer   —— MakePlacer 派生的放置预览（★ 不走工厂）',
    '-- 3. pandoraschest          —— 第 4 参数 indestructible=true → 不可破坏（陷阱箱）',
    '-- 4. minotaurchest          —— 同样 indestructible=true',
    '-- 5. terrariumchest         —— 第 7 参数给了专属资源，第 4 参数 false → 可破坏',
    '-- 6. terrariumchest_fx      —— ★ 独立手写预制体，不走 MakeChest',
    '-- 7. sunkenchest            —— 第 9 参数 force_non_burnable=true → 可锤不可烧',
    '-- 8. boat_ancient_container —— 第 4 参数 true，第 8 参数 common_postinit 指定了背景层设置',
    '--',
    '-- 【★ 变体的四条主要维度】',
    '--   数值维度   —— 数据表（各 master_postinit 里的 adddeps、组件参数）',
    '--   能力维度   —— 布尔开关（indestructible / force_non_burnable）',
    '--   表现维度   —— common_postinit（两端可见的差异）',
    '--   形态维度   —— 独立手写预制体（fx）或运行时换实体（ReplacePrefab）',
    '-- ⇒ 【移植要点】前三类用工厂 + 钩子就够；第四类说明「变体」终归要能退化成独立文件。',
  ],
  767: [
    '-- ★ MakePlacer 出现在 return 里的位置很讲究：紧跟它服务的 treasurechest，',
    '-- 一眼能看出「这是这个箱子的放置预览」。',
    '-- 对比第 770 行的 terrariumchest 就没配 placer —— 因为它由配方直接放置，不需要预览。',
  ],
  768: [
    '-- pandoraschest：第 6 参数 prefabs 只给了 1 个子预制体（第 440 行的 reset 特效），',
    '-- 第 5 参数 master_postinit 传了 pandora_master_postinit。',
    '-- ⚠️ 注意第 3/4 个参数没写 false/true，而是靠位置对齐 ——',
    '-- ★ 这种 9 参数位置传参一旦在中间插入新参数就会全部错位，且 Lua 不会报错。',
    '-- 【移植建议】超过 5 个参数就该改成传一个 table 或命名参数，位置传参不可维护。',
  ],
  770: [
    '-- terrariumchest：★ 第 7 参数 assets 传了专属动画包，第 4 参数传 false（可破坏）。',
    '-- 对比第 772 行 sunkenchest 同样传了 assets —— 说明「变体专属资源」是工厂的正式能力。',
  ],
  771: [
    '-- 【★ 手工 Prefab 的典型三段式】assets / fn / deps 三个参数齐备，但注意第 4 参数 deps 给了',
    '-- "collapse_small" —— 即使 fx 用不到也声明了，属于「保守声明」，不影响正确性。',
  ],
  773: [
    '-- boat_ancient_container：★ 第 6 参数 prefabs 显式传了 nil（第 107 行的判空在此生效），',
    '-- 第 9 参数 force_non_burnable=true。',
    '-- ⇒ 完整展示了 9 个参数里 8 个都在用的情形，可作为「读懂工厂调用」的对照样本。',
  ],
};
