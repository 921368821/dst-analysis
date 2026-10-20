// spec-actions-p2.mjs —— actions.lua 深度注释规格 第 2 部分
// 覆盖：ACTIONS 表 353-741（动作原型声明）+ 编号映射 743-764
// 锚点范围：353 ~ 764

export const BEFORE = {
  // ══════════════════════════════════════════════════════════════
  // §二 ACTIONS 表 · 总论与基础动作
  // ══════════════════════════════════════════════════════════════
  "self.fn#1+46": [
    "--★★【HIGH_ACTION_PRIORITY = 10 —— 全文件唯一的高优先级常量】",
    "--   ★★ 保留的英文注释写明了它的**使用契约**：",
    "--     「高优先级的意图是作为快捷标志，用于那些我们预期一旦可用就永远",
    "--       压过其他动作的动作。」",
    "--     「我们同时预期**不会有两个** HIGH_ACTION_PRIORITY 动作同时可用。」",
    "--   ★★★ 这个「不变量」完全靠人工维护，框架不校验。",
    "--     实际使用者（全部数得出，共 10 个）：",
    "--       JUMPIN_MAP(432) BLINK(457) BLINK_MAP(458)",
    "--       TOGGLE_DEPLOY_MODE(460) COMPARE_WEIGHABLE(492)",
    "--       CATAOE(522) CAST_NET(564)",
    "--       PLANTREGISTRY_RESEARCH(574) DIRECTCOURIER_MAP(690)",
    "--   ★ 观察：全部是「打开某个界面 / 传送到某处」这类**界面型**动作。",
    "--     共同点是它们会立刻改变玩家的操作模式（开地图、开轮盘、进入建造），",
    "--     此时应该压过一切具体交互，否则会出现「右键想开轮盘却砍了树」。",
    "--   ★★ 若模组新增了一个 HIGH 动作且与上述某个在同一目标上同时可用，",
    "--     排序结果将由 playercontroller 的收集顺序决定 —— 不可预测。",
  ],

  "self.fn#1+50": [
    "--★★★【ACTIONS 表 —— 240 个动作原型的声明，385 行纯数据】",
    "--",
    "--★★ 为什么是「一张大表」而不是分散注册？",
    "--   因为动作之间存在**同名字段的密集对照**（哪些 mount_valid、哪些优先 3、",
    "--   哪些是地图专用）。集中在一处才能一眼看出「这类动作的统一约定」，",
    "--   也能发现异常值（如 RUMMAGE=-1 与 CHANGEIN=0 的注释「必须比 RUMMAGE 大」）。",
    "--   ★ 例证：395 行 CHANGEIN 的行尾注释明确引用了 405 行 RUMMAGE 的值，",
    "--     「-- Must be bigger than RUMMAGE.」这种跨行约束只有集中排列才写得出来。",
    "--",
    "--★★【每一条声明只写「与默认值不同的字段」】",
    "--   于是 `REPAIR = Action({ mount_valid=true, encumbered_valid=true })` 只有 12 字符，",
    "--   而 `TOSS = Action({priority=1, rmb=true, distance=8, mount_valid=true})` 也只有 60。",
    "--   ★ 这是数据驱动的可读性红利：Action({}) 的默认值设计得足够小，",
    "--     使得 95% 的声明都能一眼看出「这个动作特殊在哪」。",
    "--",
    "--★★【表内注释按 DLC 分组，这是唯一有组织的地方】",
    "--   --Quagmire(534) --WEBBER(618) --WANDA(624) --WOLFGANG(627)",
    "--   --WX78(640) --MAXWELL(649) --WOODIE(656) --WINONA(659) --Rifts(662)",
    "--   -- Hallowed Nights 2024(672) -- Winter's Feast 2024(675) -- Meta 5(679)",
    "--   -- Deck O' Cards(694) -- Rifts 5(699) -- Winter 2025(708)",
    "--   -- Year of the Clockwork Knight(712) -- Meta 6(715) -- Rifts 7(731)",
    "--   -- Crow Carnival 2026(736)",
    "--   ★★ 这个分组**暴露了一个真实的维护问题**：新增动作时永远追加到末尾，",
    "--     所以顺序大致等于「该功能加入游戏的时间」。查找某个动作属于哪个",
    "--     角色/季节，只能靠名字猜。",
    "--   ★ 对比 357 行的动作在文件头 360 行就出现了，而 WEBBER 在 618 ——",
    "--     「基础动作」在前，「DLC 动作」在后，两者并未严格分离。",
  ],
  "self.fn#1+52": [
    "--★ REPAIR：修理 / 给月亮神像供能（月亮门槛 repairable_moon_altar）",
    "--   mount_valid + encumbered_valid ⇒ 骑着牛、拿着大理石也能供。",
    "--   ★ 印证了 317 行 encumbered_valid 的用途：供能是基地维护，不能被背包满拦住。",
  ],
  "self.fn#1+53": [
    "--★ READ：读书 / 读告示。只需 mount_valid（书在手上）。",
    "--   ★ 对比 385 行 TALKTO 也只有 mount_valid + encumbered_valid ——",
    "--     两者同属「手持物 + 骑乘兼容」的轻交互族。",
  ],
  "self.fn#1+54": [
    "--★★ DROP 是全表信息量最大的一行声明，六个字段各有含义：",
    "--   priority=-1        ⇒ 兜底。「对地面丢东西」永远排最后，",
    "--                        避免抢走更具体的动作（比如对箱子丢）。",
    "--   floating_valid=true ⇒ 可以从浮空平台丢出去",
    "--   is_relative_to_platform ⇒ ★★ 相对船体坐标（329 行）",
    "--                        船在动，用世界坐标会丢到水里",
    "--   extra_arrive_dist=ExtraDropDist ⇒ §零 的碰撞半径余量",
    "--   ⚠ 没有 rm！丢东西可以是左键或右键，由 fn 自行决定（1173 行读",
    "--     act.options.wholestack）。",
  ],
  "self.fn#1+55": [
    "--★ TRAVEL：完全空的 Action()。它的实现不在 fn 里 ——",
    "--   3699 行 fn 只做 `if act.target.travel_action_fn then ... end`，",
    "--   即**由实体自带回调**。这是「无内容动作」的标准形态：",
    "--   动作只负责被选中，具体做什么由目标实体决定。",
  ],
  "self.fn#1+56": [
    "--★★ CHOP：砍树。四类工具动作的模板（另三个是 MINE / HAMMER / DIG）。",
    "--   distance=1.75 ⇒ 比默认 4 格近得多。为什么？",
    "--     ★★ 因为砍树的判定是 workaction（workable 组件的 GetWorkAction），",
    "--       走近 4 格才能砍会让玩家觉得「明明够得着却砍不到」",
    "--       ——1.75 正好是树的碰撞半径加上手臂长度。",
    "--   invalid_hold_action=true ⇒ 砍完不会自动连砍下一棵（见 339 行）",
    "--   ⚠ 没有 canforce ⇒ 不能「隔空砍树」。这与 NET（可强制）形成对比。",
  ],
  "self.fn#1+57": [
    "--★★ ATTACK：攻击。三条注释说明了一切：",
    "--   priority=2 ⇒ 比 PICKUP(1) 高。为什么？",
    "--     ★★ 因为玩家拿着武器对着敌人时，几乎总是想攻击；",
    "--       而「捡起来」永远是次优解。",
    "--   canforce=true ⇒ 允许强制（长矛、铳子这类需要更宽射程的武器）",
    "--   行尾注释「No custom range check, attack already handles that」：",
    "--     ★★★ 因为 320 行的耦合，canforce=true 而没有 rangecheckfn 时，",
    "--       rangecheckfn 就是 nil，locomotor.lua:931 的检查自然跳过。",
    "--       范围由 combat 组件自己在攻击瞬间判定。",
    "--     ★ 这不是 bug 而是**分工**：攻击距离取决于武器而非动作。",
    "--   invalid_hold_action=true ⇒ 长按攻击不自动连击下一目标",
  ],
  "self.fn#1+58": [
    "--★ EAT：吃东西。floating_valid ⇒ 可以站在浮空平台（船）上吃。",
    "--   ★ fn（793 行）是三分支的「能力探测」：",
    "--     edible → eater:Eat（普通玩家）",
    "--     soul  → souleater:EatSoul（韦伯）",
    "--     oceanfishable → 装鱼竿（韦伯带鱼）",
    "--   ★★ 一个动作服务三种完全不同的角色，靠**目标有没有某个组件**来分派。",
    "--     这是 DST 消除「角色专属动作」的主要手法。",
  ],
  "self.fn#1+59": [
    "--★★ PICK：采摘 / 翻找 / 搜索。这是唯一用了自定义 rangecheckfn 的基础动作。",
    "--   ★ 三件套：canforce=true / rangecheckfn=PickRangeCheck（§零 18 行）/",
    "--     extra_arrive_dist=ExtraPickRange（§零 35 行）。",
    "--   ★★ 「可强制 + 自定义范围」的标准范例：玩家可以隔着一定距离采摘，",
    "--     因为植物往往比玩家判定框小。",
    "--   ★ 而 PICKUP（捡起掉落物）用的是 priority=1 而非 canforce ——",
    "--     捡东西不需要强制，因为掉落物通常就在脚下。",
  ],
  "self.fn#1+60": [
    "--★★ PICKUP：捡起掉落物。与 PICK 的区别是「目标是地面上的东西」。",
    "--   priority=1 ⇒ 比 PICK 高一档。为何？",
    "--     ★★ 因为「捡」是零思考的下意识行为，「采摘」需要判断。",
    "--       玩家同时能碰到地上的一堆东西和一个浆果丛时，",
    "--       框架必须先问「捡」而不是「摘」。",
    "--   mount_valid ⇒ 骑着牛也能捡（很常用）",
    "--   extra_arrive_dist=ExtraPickupRange（§零 154 行，固定 0.75 水面余量）",
  ],
  "self.fn#1+61": [
    "--★ MINE：采矿。与 CHOP 完全同构（只有 distance 不同，MINE 用默认）。",
    "--   ★★ 为什么挖矿可以用默认距离而砍树要 1.75？",
    "--     因为矿脉通常是单个石头，体积小，走近 4 格反而容易「够不着」。",
    "--   ★★ 这与 PickRangeCheck 的动机相反（那里是「目标小所以要走近」），",
    "--     这里是「目标小所以不能走太近 —— 否则会走过它」。",
  ],
  "self.fn#1+62": [
    "--★★ DIG：挖掘。与 CHOP/MINE 的唯一差别是 rmb=true。",
    "--   ★ 这意味着**右键才能挖**（左键通常是别的用途）。",
    "--   ★ 所以「四类工具动作同构」并不完全：DIG 还多了输入键位约定。",
    "--   ★★ 呼应 310 行的注释「rmb 只对工具有效」—— DIG 正是「工具」。",
  ],
  "self.fn#1+63": [
    "--★ GIVE：给 NPC 送东西。canforce + DefaultRangeCheck（§零 16 行）。",
    "--   ★★ GIVE 家族的三个动作全部 priority=3（GIVETOPLAYER/GIVEALLTOPLAYER/",
    "--     FEEDPLAYER）。为什么是全表最高的常规优先级？",
    "--     因为「把东西给某个特定的人」是极强的意图，",
    "--     必须压过「对地面丢东西」(-1)、「采摘」(0)、「攻击」(2)。",
    "--   ★ 对照 405 行 RUMMAGE=-1 的注释「CHANGEIN 必须比 RUMMAGE 大」，",
    "--     可以看出这一组的 priority 是成体系设计的。",
  ],
  "self.fn#1+64": [
    "--★ GIVETOPLAYER：给玩家 1 个。priority=3（与 GIVE 同级，靠 canforce/rmb 区分）。",
  ],
  "self.fn#1+65": [
    "--★ GIVEALLTOPLAYER：给玩家全部。",
    "--   ★★ 与 GIVETOPLAYER 的差别完全在 fn 里（2362-2382 行）：",
    "--     前者 CanAcceptCount(act.invobject, 1)，后者 CanAcceptCount(act.invobject)。",
    "--   ★ 两行代码的差别 = 一个游戏的「全给」功能。",
  ],
  "self.fn#1+66": [
    "--★ FEEDPLAYER：喂别人吃。注意 rmb=true（右键喂）——",
    "--   ★★ 因为喂食与「给东西」在按键上刻意分开，避免误操作：",
    "--     右键 = 我给你食物（善意），左键 = 给东西（可能是交易）。",
    "--   ★ fn（2400 行）有一长串 sg 状态标签检查（idle / busy / attacking /",
    "--     sleeping / playerghost / wereplayer），是全文件最长的单次判定链之一。",
  ],
  "self.fn#1+67": [
    "--★ DECORATEVASE：装饰花瓶。与 RUMMAGE 配对使用（RUMMAGE 的 strfn 会返回",
    "--   「DECORATE」，见 1153 行）。",
    "--   ★ 又是 priority 缺省 0 的一对，说明它们靠 **target 上的标签**区分",
    "--     而不是靠 priority。",
  ],
  "self.fn#1+68": [
    "--★ COOK：烹饪（放材料进锅）。priority=1 高于 STORE(0)。",
    "--   ★★ 优先级理由很实在：锅里已经有东西时，「继续放材料」比「打开锅」",
    "--     更符合直觉。",
    "--   ★ 呼应 2001 行 stroverridefn 的注释：为了不破坏容器里对 COOK 串的",
    "--     访问方式，这里用 stroverridefn 而非 strfn 返回 SPICE。",
  ],
  "self.fn#1+69": [
    "--★ FILL：装水（从水源往容器里灌）。空的 Action()：无距离、无优先级。",
    "--   ★ fn（2120 行）是「双向」动作：source 与 filled 谁是 target 都行，",
    "--     所以**没有**优先级的必要。",
  ],
  "self.fn#1+70": [
    "--★ FILL_OCEAN：直接从海里装水。is_relative_to_platform + ExtraDropDist。",
    "--   ★★ is_relative_to_platform 的必要场景：站在船上往海里倒/装水。",
    "--   ★ 2160 行 `ACTIONS.FILL_OCEAN.fn = ACTIONS.FILL.fn` —— T12 同构模板。",
    "--     两者 fn 相同但 stroverridefn 不同（2161 行强制显示 FILL 串）。",
  ],
  "self.fn#1+71": [
    "--★ DRY：晾干。空 Action()，逻辑全在 dryer 组件。",
  ],
  "self.fn#1+72": [
    "--★★ ADDFUEL：加燃料。三个字段共同表达「这是玩家维护动作」：",
    "--   mount_valid  骑着牛也能添柴",
    "--   paused_valid ★★ 游戏暂停时也能添柴（房主福利）",
    "--   ★★ 326 行说 paused_valid 全文件只有 4 个动作用，ADDFUEL 是其中之一。",
    "--     理由：服务器管理员需要能保证所有人都有火。",
  ],
  "self.fn#1+73": [
    "--★ ADDWETFUEL：加湿燃料（韦伯）。2207 行 fn 直接 = ADDFUEL.fn。",
  ],
  "self.fn#1+74": [
    "--★★ LIGHT：点火。priority=-4 —— 全表**最低**的优先级之一（与 WALKTO 并列）。",
    "--   ★★ 为什么点火这么不重要？因为「点火」几乎总是「先走过去再点」，",
    "--     玩家的真实意图是到达火堆，所以必须让位。",
    "--   ★ 对照 384 行 LOOKAT=-3、386 行 WALKTO=-4 —— 这一档是「兜底移动」。",
  ],
  "self.fn#1+75": [
    "--★ EXTINGUISH：灭火。priority=0（默认），与 LIGHT 的 -4 形成有趣对比：",
    "--   ★★ 灭火是默认级，而点火是最低级。",
    "--     推断：灭火通常只有右键一个明确入口，没有左键的竞争；",
    "--     而点火要和「走过去」「看一眼」竞争。",
  ],
  "self.fn#1+76": [
    "--★★ STOKEFIRE：添柴（拨旺火）。四个字段都很讲究：",
    "--   rmb=true ⇒ 右键（与 ADDFUEL 的左键区分）",
    "--   distance=8 ⇒ 8 格！比其他动作远得多，因为长矛/火把可以远程拨火",
    "--   mount_valid ⇒ 骑着牛也能拨",
    "--   invalid_hold_action ⇒ 拨火是长动作",
    "--   ★ fn（2879 行）还额外检查 `HasTag(\"controlled_burner\")` 与",
    "--     `HasTag(\"stokeablefire\")` —— 两个标签双重确认。",
  ],
  "self.fn#1+77": [
    "--★★ LOOKAT：查看。四处细节：",
    "--   priority=-3  兜底档",
    "--   instant=true  ★★ 查看是瞬间的，不播「弯腰看」动画",
    "--   distance=3    ★ 保留的行内英文注释 --[[for close inspection]] 说明",
    "--                     这是为了「凑近看」而不是「远远看」",
    "--   ghost_valid + mount_valid + encumbered_valid ⇒ 幽灵/骑乘/超重都能看",
    "--   ★★ instant 与 distance 的组合值得注意：instant 让 locomotor 直接",
    "--     PushBufferedAction，但仍会「走过去」，只是不做长动作流程。",
    "--     fn（1220 行）里显式调 locomotor:Stop() 解释了这个组合。",
  ],
  "self.fn#1+78": [
    "--★ TALKTO：对话。instant + priority=3 + ghost_valid。",
    "--   ★★ ghost_valid 的原因：幽灵可以与 NPC 说话（这是韦伯的核心玩法之一）。",
    "--   ★ priority=3 表示「明确意图」，与 GIVE 家族同级。",
  ],
  "self.fn#1+79": [
    "--★ WALKTO：走到。priority=-4（与 LIGHT 并列最低）。",
    "--   ★★ WALKTO 是「最后的兜底」：当没有任何具体动作可用时，",
    "--     「走过去」永远可用，所以它的优先级必须最低，",
    "--     否则会抢走所有具体交互。",
    "--   ghost_valid ⇒ 幽灵能走到某处（MOON 门），是韦伯核心机制",
    "--   invalid_hold_action ⇒ 按住鼠标不会连续「走」",
  ],
  "self.fn#1+80": [
    "--★ INTERACT_WITH：互动（照料作物）。distance=1.5 很近。",
    "--   ★ 因为「照料」需要贴身操作，与 1.75 的砍树同属近距离族。",
    "--   ★ 它还有 theme_music_fn（1558 行）：对作物互动时播 farming 音乐。",
  ],
  "self.fn#1+81": [
    "--★ BAIT：放饵。空 Action()，fn（1594 行）直接 trap:SetBait。",
    "--   ★★ 这是 T1 纯转发模板的最简样本，建议作为阅读入门。",
  ],
  "self.fn#1+82": [
    "--★★ CHECKTRAP：检查陷阱。priority=2 —— 与 ATTACK 同级。",
    "--   ★ 推断：检查陷阱时玩家拿着武器，攻击不该抢走它；",
    "--     而检查又比「捡地上的东西」(1) 更具体。",
    "--   ★ mount_valid ⇒ 骑牛也能查陷阱（猎人常见操作）。",
  ],
  "self.fn#1+83": [
    "--★ BUILD：建造。空 Action()，fn（2609 行）只有两行：",
    "--   转发给 builder:DoBuild(recipe, 点, 朝向, 皮肤)。",
    "--   ★★ 注意 recipe 来自 act.recipe —— **动作实例**携带配方，",
    "--     而 Action 原型不知道配方。这是「原型 vs 实例」分层的又一例证。",
  ],
  "self.fn#1+84": [
    "--★ PLANT：种植。空 Action()。fn（2619 行）有两分支：",
    "--   grower:PlantItem（普通种植）与 winter_treestand（冬季树支架）。",
  ],
  "self.fn#1+85": [
    "--★ HARVEST：收获。空 Action()。fn（2638 行）是**七分支 if 链**：",
    "--   crop / harvestable / stewer / dryer / dryingrack / occupiable /",
    "--   quagmire_tappable。这是「一个动作服务七种作物」的例子。",
    "--   ★★ 全部靠「目标有没有某个组件」分派 —— 与 EAT 的三分支同源。",
  ],
  "self.fn#1+86": [
    "--★ GOHOME：回家（牛棚/洞穴）。空 Action()。",
    "--   ★ fn（2943 行）带一句保留的英文自嘲：「this is gross. make it better",
    "--     later.」—— 作者自己也知道这一坨 if 嵌套该重构。",
    "--   ★★ 该 fn 会**销毁执行者**（`act.doer:Remove()`，2957/2960 行）。",
    "--     全文件唯一一个会删除 doer 的玩家动作。",
  ],
  "self.fn#1+87": [
    "--★ SLEEPIN：睡觉。空 Action()。fn（2686 行）用 `or` 链同时处理",
    "--   「手上的睡袋」与「地上的睡袋」两种情况。",
  ],
  "self.fn#1+88": [
    "--★★ CHANGEIN：换衣服。四行声明里藏着全表最重要的一条行尾注释：",
    "--   `-- Must be bigger than RUMMAGE.`",
    "--   ★★★ 这是一条**跨行动作的硬约束**：405 行的 RUMMAGE 是 -1，",
    "--     所以 CHANGEIN 必须 ≥ 0，否则「打开衣柜」会被「翻找」抢走。",
    "--   ★★ 为什么 RUMMAGE 要压到 -1？因为「翻找」是个**泛用**动作，",
    "--     任何带 container 的东西都能翻找，包括衣柜。",
    "--     若两者同级，收集候选动作时的遍历顺序会决定谁赢 —— 不可预测。",
    "--     于是把泛用动作压低、专用动作抬高。",
    "--   ★★★ 这是本文件 priority 设计意图最清晰的证据，也是唯一一处",
    "--     用自然语言写下的约束。读懂它就理解了 priority 的全部用法。",
  ],
  "self.fn#1+89": [
    "--★ HITCHUP：拴牛。priority=-1（与 RUMMAGE 同档，也是泛用动作）。",
    "--   ★ mount_valid 未设 ⇒ **不能骑着牛再拴另一头牛**。符合直觉。",
  ],
  "self.fn#1+90": [
    "--★ MARK：标记。distance=2（很近，标记是在地图上画的点）。",
  ],
  "self.fn#1+91": [
    "--★ UNHITCH：解开拴绳。distance=2。priority=-1 与 HITCHUP 对称。",
  ],
  "self.fn#1+92": [
    "--★ HITCH：被拴住时的跟随动作。priority=-1，**无距离**（distance=nil）。",
    "--   ★★ 这是「无距离」的正确用例：牛被拴住后自动走向桩子，",
    "--     不该有距离约束。fn（2747 行）只做两件事，清 hitchingspot 并 SetHitched。",
    "--   ★⚠ L6：fn 没有 return 值 ⇒ 返回 nil ⇒ BufferedAction:Do() 视为失败。",
    "--     对 AI 用的动作而言「失败但已生效」没有副作用（HITCH 只被",
    "--     brains/beefalobrain.lua:171 使用，AI 不关心返回值），",
    "--     但若玩家也能触发就会「点了没反应」。",
  ],
  "self.fn#1+93": [
    "--★★ EQUIP：装备。字段极多，因为「装备」要处理的状态最多：",
    "--   priority=0 + instant=true ⇒ 瞬间完成（换装不该有动画延迟）",
    "--   mount_valid/encumbered_valid/floating_valid/paused_valid 四个 true",
    "--   ★★ 这四个标记全开，说明 EQUIP 被视作「永远不会出错的操作」——",
    "--     无论玩家在什么状态下，换装都应该允许。",
    "--     这是很合理的设计判断：装备失败会让人完全无法玩。",
  ],
  "self.fn#1+94": [
    "--★ UNEQUIP：卸下。与 EQUIP 镜像但 priority=-2（低于 DROP 的 -1）。",
    "--   ★★ 为什么卸装备比丢东西优先级低？",
    "--     因为「丢」是完全放弃，「卸」只是换回背包 —— 玩家的犹豫度不同。",
    "--   ★ strfn（858 行）会根据物品类型返回 \"HEAVY\" 变体（区分重物）。",
  ],
  "self.fn#1+95": [
    "--★ 402 行是被注释掉的 OPEN_SHOP —— 保留 commented-out 代码的样本。",
    "--   ★★ 商店功能在 Klei 商城时代被移除，但代码位置留着，",
    "--     方便未来 DLC 复活时知道该往哪放。这是有意保留而非遗忘。",
  ],
  "self.fn#1+96": [
    "--★ SHAVE：刮胡子。mount_valid（坐着也能刮）。",
    "--   ★ strfn（2813 行）会在手柄模式下返回 \"SELF\" ——",
    "--     因为手柄没有「点自己」的操作，必须靠 strfn 区分。",
  ],
  "self.fn#1+97": [
    "--★ STORE：把物品放进箱子/锅/冰箱。与 COOK(1) / RUMMAGE(-1) 形成三档：",
    "--   ★★ 「打开箱子翻找」(-1) → 「把东西放进去」(0) → 「往锅里放材料」(1)",
    "--     这是一个完整的、由 priority 编码的**交互语义层级**。",
  ],
  "self.fn#1+98": [
    "--★★ RUMMAGE：翻找容器。priority=-1 —— 全表最低的非负以下档位之一。",
    "--   ★★★ 它是「priority 设计」的锚点：",
    "--     · 泛用性最高（任何 container 都触发）⇒ 必须压低",
    "--     · 395 行 CHANGEIN 的注释直接依赖它",
    "--     · 1152-1157 行 strfn 还要为它做特殊分支（decoratable / unwrappable）",
    "--   ★★ fn（1051 行）是全文件最长的动作实现（80 行），因为「打开容器」",
    "--     要处理：代理容器（container_proxy）、变身容器（container_transform）、",
    "--     骑乘中的自己、角色专属限制（CanOpenCharacterSpecificContainer）、",
    "--     黑暗中静默失败、口袋维度容器……",
    "--   ★ 每一个 elseif 分支都是历史上某个功能留下的痕迹。",
  ],
  "self.fn#1+99": [
    "--★★ 保留的英文注释解释了 DEPLOY_TILEARRIVE 为什么还在：",
    "--   「DEPLOY_TILEARRIVE should stay a hold action.」",
    "--   ★★ 即「它是按住的」—— 铺地板需要按住不放。",
    "--     408 行的声明里确实**没有** invalid_hold_action，与 DEPLOY(407) 相反。",
    "--   ★ 两者的对比非常 instructive：",
    "--     DEPLOY           invalid_hold_action=true  → 放单个物品不重复",
    "--     DEPLOY_TILEARRIVE 无 invalid_hold_action    → 铺地板可以按住连续",
    "--   ★ 同一个 fn（1662 行 `ACTIONS.DEPLOY_TILEARRIVE.fn = ACTIONS.DEPLOY.fn`），",
    "--     两个截然不同的输入手感。这是最能说明「Action 是数据」的例子。",
  ],
  "self.fn#1+100": [
    "--★★ DEPLOY：放置。三个字段：",
    "--   distance=1.1  ★★ 全表最小的 distance。为什么？",
    "--     因为放置需要**精确位置**。1.1 格意味着「必须站得很近，",
    "--     否则放下去会挡住自己的路」。",
    "--   extra_arrive_dist=ExtraDeployDist ⇒ §零 的介质矩阵，最终总射程 8",
    "--   invalid_hold_action=true ⇒ 放一个物品不会连续放",
  ],
  "self.fn#1+101": [
    "--★ DEPLOY_TILEARRIVE：铺地板/地面格子。用 customarrivecheck=CheckTileWithinRange",
    "--   （§零 121 行）—— 因为目标不是实体而是**格子**。",
    "--   theme_music=\"farming\" ⇒ 铺地板时播农场主题。",
    "--   ★★ 保留的英文注释说明了它未来复用时的陷阱：",
    "--     「如果将来用于非农业用途，需要换成 theme_music_fn。」",
    "--     这是作者主动留下的技术债提示，非常难得。",
  ],
  "self.fn#1+102": [
    "--★ DEPLOY_FLOATING：放置浮空物品。do_not_locomote ⇒ 原地放，不走过去。",
    "--   ★★ 为什么浮空放置不需要走过去？因为浮空物（如浮标、告示牌）",
    "--     总是放在**当前所在**的位置，走过去反而会改变落点。",
    "--   ★ floating_valid + invalid_hold_action 同为 true。",
  ],
  "self.fn#1+103": [
    "--★ PLAY：演奏乐器 / 吹哨子。mount_valid。",
    "--   ★ strfn（2833 行）里 coach_whistle 分支会返回 COACH_ON/COACH_OFF ——",
    "--     沃尔夫冈的「教练模式」用同一动作实现开关切换。",
  ],
  "self.fn#1+104": [
    "--★ CREATE：创造。空 Action()。",
  ],
  "self.fn#1+105": [
    "--★ JOIN：加入。空 Action()。",
  ],
  "self.fn#1+106": [
    "--★ NET：网捕。priority=3 + canforce + DefaultRangeCheck。",
    "--   ★★ priority=3 表示「强意图」：拿网子的玩家几乎一定是要抓。",
    "--   ★ fn（1853 行）是「四工具动作」之外的第五种：它不走 DoToolWork，",
    "--     而是自己判断 workaction===ACTIONS.NET 后调 WorkedBy。",
    "--   ⚠ L5：1871 行无条件 `return true` —— 见该行注释。",
  ],
  "self.fn#1+107": [
    "--★★ CATCH：接住。distance=math.huge —— **无限距离**！",
    "--   ★★ 这是 locomotor 的特殊约定：locomotor.lua:947 判定",
    "--     `distance ~= nil and distance >= math.huge` ⇒ 「实质瞬间」，",
    "--     直接 FaceMovePoint + PushBufferedAction，不走路。",
    "--     同样的写法在 CASTUNSUMMON(496)/ROW/TACKLE/DASH 等处出现。",
    "--   ★ 语义：捕蝇草类的「接」不需要走近，因为目标会自己飞来。",
    "--   ★ fn（1874 行）只有 `return true` —— 真正的接住在捕蝇草组件里。",
  ],
  "self.fn#1+108": [
    "--★★ FISH_OCEAN：海钓。三个字段是「海洋三件套」：",
    "--   rmb=true                        ⇒ 右键抛竿",
    "--   customarrivecheck=CheckFishingOceanRange ⇒ §零 68 行，探针法",
    "--   is_relative_to_platform=true    ⇒ 船动时坐标不漂",
    "--   disable_platform_hopping=true   ⇒ 不跳到邻船",
    "--   ★★ 注意 fn（1878 行）**永远失败**：",
    "--     `return false, \"TOODEEP\"`",
    "--     这不是 bug —— 玩家在「太深」的位置抛竿，失败提示正是反馈本身。",
    "--     ★ 「用失败原因做 UI 反馈」的样本。",
  ],
  "self.fn#1+109": [
    "--★ FISH：钓鱼（淡水）。空 Action()。",
    "--   ★ 与 FISH_OCEAN 对比：本动作连 customarrivecheck 都没有，",
    "--     因为钓池塘/河不需要特殊到达判定。",
  ],
  "self.fn#1+110": [
    "--★★ REEL：收线。instant=true ⇒ 收线是单次点击（不是按住）。",
    "--   ★★ fn（1890 行）是一个**三态分派**：",
    "--     有鱼上钩 → Reel() / 咬钩但没刺中 → Hook() / 否则 → StopFishing()",
    "--   ★ 一个动作 = 收线 + 刺 + 取消，全部靠状态判断。",
    "--   ★ strfn（1904 行）用 client 副本 replica.fishingrod 来决定显示哪个词，",
    "--     保证 UI 与实际状态一致。这是「strfn 必须只读副本」的好例子。",
  ],
  "self.fn#1+111": [
    "--★ OCEAN_FISHING_POND：鱼塘。空 Action()。fn（1384 行）只检查虚拟海洋标签。",
  ],
  "self.fn#1+112": [
    "--★★ OCEAN_FISHING_CAST：投竿。priority=3 + invalid_hold_action。",
    "--   ★★ 海洋三件套之二（customarrivecheck=CheckOceanFishingCastRange，",
    "--     探针距离 1.5 而不是 0.25 —— 要助跑空间）。",
    "--   ★ priority=3：拿鱼竿对着水时，投竿要压过一切其他动作。",
  ],
  "self.fn#1+113": [
    "--★★ OCEAN_FISHING_REEL：收深海鱼。priority=5 —— 全表最高的非 HIGH 值。",
    "--   ★★ 为什么是 5？因为钓鱼是一个「长流程」：",
    "--     玩家一旦上钩，必须保证收线动作不会被任何其他动作抢走。",
    "--     priority=5 让它压过 CASTSPELL(3) 等全部常规动作。",
    "--   do_not_locomote ⇒ 收线时不移动",
    "--   silent_fail ⇒ §二 提到的唯一用户：收线失败太频繁，别吵玩家。",
    "--   ★★ 值得注意：priority=5 > HIGH_ACTION_PRIORITY/2，说明",
    "--     「界面型动作」与「流程型动作」的优先级是同一个连续谱。",
  ],
  "self.fn#1+114": [
    "--★ OCEAN_FISHING_STOP：停止钓鱼。instant=true。",
    "--   ★ fn（1416 行）示范了 T5 模板：显式 GoToState + 调组件方法。",
    "--     `act.doer.sg:GoToState(\"oceanfishing_stop\")`",
  ],
  "self.fn#1+115": [
    "--★ OCEAN_FISHING_CATCH：钓上鱼。priority=6 —— 全表最高（除 HIGH=10）。",
    "--   ★★ 比 REEL(5) 高一档，因为「上钩」是整个流程的**终点**，",
    "--     必须在同一帧被抓住，不能给任何其他动作插队的机会。",
    "--   instant=true ⇒ 拿到就结束。",
  ],
  "self.fn#1+116": [
    "--★★ CHANGE_TACKLE：装子弹 / 换诱饵。priority=3 + instant + mount_valid。",
    "--   ★★ 保留的英文注释透露了它已被泛化：",
    "--     「this is now a generic 'put item into the container of the",
    "--       equipped hand item'」",
    "--   ★ 所以 1444-1524 行那 80 行实现其实是一个通用的",
    "--     「往手持物的容器里塞东西」引擎（含堆叠、特定槽位、替换三种情形）。",
    "--   ★ 这是本文件里「注释说明了重构历史」的又一例。",
  ],
  "self.fn#1+117": [
    "--★ POLLINATE：授粉（韦伯）。空 Action()。fn（2850 行）两分支：",
    "--   有目标 → Pollinate(target)；无目标 → CreateFlower()（凭空造花）。",
  ],
  "self.fn#1+118": [
    "--★ FERTILIZE：施肥。priority=1 —— 高于 STORE(0)，因为「对着作物」比",
    "--   「对着箱子」更具体。",
    "--   ★★ fn（1806 行）是**六分支**的组件探测（crop/grower/pickable/",
    "--     quagmire_fertilizable/fertilizable），且注意 1823 行的回退：",
    "--     没作用于目标时**可以给自己施肥**（对泥土堆）。",
  ],
  "self.fn#1+119": [
    "--★ SMOTHER：闷火。priority=1 + mount_valid。",
    "--   ★★ fn（1838 行）用 `act.invobject or act.doer` ——",
    "--     意味着「用物品闷」与「用手闷」都是同一个动作（T7 模板）。",
    "--   ★ 而 485 行 STARTCHANNELING 的注释提到「priority 高于 smother」，",
    "--     说明两者会在同一目标（水泵）上竞争。",
  ],
  "self.fn#1+120": [
    "--★ MANUALEXTINGUISH：手动灭火（用冰块）。priority=1。",
    "--   ★ fn（1846 行）要求 invobject 有 \"frozen\" 标签 + 目标在燃烧，",
    "--     并调用 Extinguish 带回热量的版本。",
  ],
  "self.fn#1+121": [
    "--★ LAYEGG：产蛋。空 Action()。fn（2890 行）用 `not canbepicked` 判定",
    "--   「现在是否可以采蛋」。",
  ],

  // ══════════════════════════════════════════════════════════════
  // §三 ACTIONS 表 · 物品 / 容器 / 建造族
  // ══════════════════════════════════════════════════════════════
  "self.fn#1+122": [
    "--★ HAMMER：锤击。第四个工具动作（CHOP/MINE/DIG 之外）。",
    "--   ★ priority=3（而非缺省 0）—— 拿锤子时锤击是强意图。",
    "--   ★★ 注意 HAMMER 是四工具中**唯一**有 priority 的。",
    "--     原因在 componentactions.lua:3063：",
    "--       workable = function(inst, action, right)",
    "--           return (right or action ~= ACTIONS.HAMMER)",
    "--              and inst:HasTag(action.id..\"_workable\")",
    "--     ★★ `right or action ~= HAMMER` 意味着「锤击只能右键触发」，",
    "--       且这个特判**写在 componentactions 里而不是 Action 字段里**。",
    "--       呼应 310 行的注释：rmb 字段只对工具有效。",
  ],
  "self.fn#1+123": [
    "--★★ TERRAFORM：改造地形（树叶变木头、草变土）。tile_placer=\"gridplacer\"。",
    "--   ★ 这是「批量改造」的入口，fn（2860 行）只转发给 terraformer 组件。",
    "--   ★ 批量操作的代价：无法 instant（要按住），也无法 canforce。",
  ],
  "self.fn#1+124": [
    "--★ JUMPIN：跳进（门 / 洞穴）。ghost_valid + encumbered_valid。",
    "--   ★★ fn（2969 行）是 T5 模板的典范：",
    "--     它**检查 sg 当前状态**（currentstate.name == \"jumpin_pre\"），",
    "--     只有在「准备跳」的动画帧里才切到 jumpin 状态。",
    "--   ★★★ 这是 DST 的「两阶段动作」模式：",
    "--     动作 → sg 切到 *_pre → 动画中再触发同一动作 → 切到正式状态。",
    "--     ★ 出现三次：JUMPIN(2972) / CLIMB(6971) / SITON(5993) /",
    "--       JUMPIN_MAP(3029) / TELEPORT(3061)。",
    "--     ★★ 目的：让长距离传送（Winona 的洞）有「蓄力」的表现，且能被打断。",
    "--     ⚠ 副作用：fn 在非 *_pre 状态下返回 nil（失败），",
    "--       这使得重复触发同一动作会被静默忽略。",
  ],
  "self.fn#1+125": [
    "--★ JUMPIN_MAP：地图版跳跃。HIGH_ACTION_PRIORITY + rmb + map_action + closes_map。",
    "--   ★★ 四字段组合的含义：打开地图 → 右键点一个位置 → 立刻关地图 → 传过去。",
    "--   ★ 呼应 §零 276 行的英文注释「translate normal actions the player could",
    "--     do in the game but done on the map instead」。",
  ],
  "self.fn#1+126": [
    "--★ TELEPORT：传送（给物品）。rmb=true + distance=2（很近）。",
    "--   ★ fn（3057 行）也是两阶段：检查 sg 处于 dolongaction 或 give 状态。",
    "--     ★★ `elseif act.target ~= nil and sg.currentstate.name == \"give\"` ——",
    "--       意味着「对别人使用传送物」这个意图被编码成**送礼动作的变体**。",
    "--       这是「复用已有状态」而不是新造状态的典型。",
  ],
  "self.fn#1+127": [
    "--★ RESETMINE：重置地雷（炸了之后重置引信）。priority=3。",
  ],
  "self.fn#1+128": [
    "--★★ ACTIVATE：激活。priority=2 + invalid_hold_action。",
    "--   ★★ 这是「最泛用的动作」：门、箱子、机关、洞穴… 全走它。",
    "--     因此它的 strfn 与 stroverridefn 都被设计成**委托给实体**：",
    "--       strfn         → act.target:GetActivateVerb(doer)",
    "--       stroverridefn → act.target:OverrideActivateVerb(doer)",
    "--   ★★ 这是一个值得学的模式：**通用动作 + 实体自描述 UI**。",
    "--     模组新增可激活物时，只要实现这两个方法即可，无需动 actions.lua。",
    "--   ★ fn（3082 行）还做了 activatable/CanActivate/DoActivate 三段，",
    "--     其中 3091 行的注释「for legacy reasons, nil will be true」说明",
    "--     DoActivate 返回 nil 被当作成功 —— 又一处「为兼容牺牲严格性」。",
  ],
  "self.fn#1+129": [
    "--★★ OPEN_CRAFTING：打开制作台。distance=nil（不用距离，靠状态图）",
    "--   + extra_arrive_dist=ExtraOpenCraftingRange（§零 266 行的「反向」计算）。",
    "--   ★★ priority=2 与 ACTACTIVATE 同级：对着制作台时，「打开」优先于「翻找」。",
  ],
  "self.fn#1+130": [
    "--★ MURDER：谋杀（杀掉手里的生物并抢走战利品）。priority=1 + mount_valid。",
    "--   ★★★ fn（3153 行）是全文件**唯一执行完整处决流程**的动作：",
    "--     取出物品 → 播放 murder 音效 → 推 murdered/killed 事件 →",
    "--     生成战利品 → 转移背包 → Remove()",
    "--   ★ 3170 行「NOTES(JBK): Push the events before spawning any giving any",
    "--     loot.」是关键的顺序说明：事件必须先于战利品掉落，",
    "--     否则监听 killed 的模组/成就拿不到正确的死亡时刻。",
    "--   ★★ 3157 行的 `RemoveFromOwner(true, true)` 双 true 是「连同堆叠一起」，",
    "--     保证处决整堆。",
  ],
  "self.fn#1+131": [
    "--★ HEAL：治疗。mount_valid + extra_arrive_dist=ExtraHealRange（§零 246 行，",
    "--   那个针对 Brightshades 的补丁）。",
  ],
  "self.fn#1+132": [
    "--★ INVESTIGATE：调查。空 Action()。fn（2896 行）读 knownlocations。",
  ],
  "self.fn#1+133": [
    "--★ UNLOCK：解锁。空 Action()。fn（3215 行）里保留了被注释掉的 Lock 分支 ——",
    "--   ★★ 说明「重新上锁」功能曾存在后被移除，但 Unlock/Lock 的接口设计",
    "--     在 components/lock.lua 里仍然对称。",
  ],
  "self.fn#1+134": [
    "--★ USEKLAUSSACKKEY：开魔法高礼帽。空 Action()。",
  ],
  "self.fn#1+135": [
    "--★ TEACH：教（ scrapbook / 地图 / 菜谱扫描）。mount_valid。",
    "--   ★ strfn（3236 行）四分支显示不同动词（NOTES/SCRAPBOOK/READ/SCAN）。",
  ],
  "self.fn#1+136": [
    "--★ TURNON：开机（研究机器）。priority=2 + invalid_hold_action。",
    "--   ★★ T4 模板：`if tar.components.machine and not tar.components.machine:IsOn()`",
    "--     —— 只在「关着的时候」提供这个动作。这就是「用状态控制可用性」。",
  ],
  "self.fn#1+137": [
    "--★ TURNOFF：关机。与 TURNON 严格镜像（检查 IsOn 为真）。",
    "--   ★ strfn（3280 行）在有 hasemergencymode 标签时显示 \"EMERGENCY\"。",
  ],
  "self.fn#1+138": [
    "--★ SEW：缝补。mount_valid。",
    "--   ★ strfn（1003 行）在用胶带时返回 \"PATCH\"（缝 vs 补的语义区分）。",
  ],
  "self.fn#1+139": [
    "--★★ STEAL：偷窃。声明里没有任何特殊字段，但行尾注释很重要：",
    "--   「NOTES(JBK): If range check changes here do the appropriate checks in",
    "--     the action.fn.」",
    "--   ★★★ 这条注释解释了 811 行那段重复的距离检查为何存在：",
    "--     动作**没有**声明 canforce/rangecheckfn，所以没有统一的范围校验，",
    "--     fn 里就自己手写了一个 `GetDistanceSqToInst < 16`。",
    "--   ★★ 于是 16 这个魔数与 16 行的 DefaultRangeCheck 完全独立。",
    "--     改一处不会影响另一处 —— 这是本文件已知的技术债，注释已明确警告。",
  ],
  "self.fn#1+140": [
    "--★ USEITEM：使用物品。priority=1 + instant。",
    "--   ★★ fn（3293 行）里有一处**语义可疑**的检查：",
    "--     3302 行 `act.doer.components.inventory:IsOpenedBy(act.doer)`",
    "--     Inventory:IsOpenedBy(guy) 的实现（inventory.lua:2015）是",
    "--       return self.isopen and self.isvisible and guy == self.inst",
    "--     传入自己 ⇒ 判断「自己的背包是否开着且可见」，对玩家而言几乎恒为假。",
    "--     ⚠ 推测原意是 `GetOpenContainer() ~= nil`（手里拿着东西）。",
    "--     ★ 若确实恒假，则 useableitem 组件的物品（草、浆果的自动使用）",
    "--       在某些状态下无法使用。记为疑似缺陷，见 p7。",
  ],
  "self.fn#1+141": [
    "--★ USEITEMON：对某物使用。distance=2 + priority=1 + mount_valid。",
    "--   ★★ 有 pre_action_cb（3322 行）：手柄模式下先关手柄背包。",
    "--     注释解释「socketable 组件在客户端也可读」⇒ 可以纯客户端判断。",
  ],
  "self.fn#1+142": [
    "--★ STOPUSINGITEM：停止使用。priority=1。",
  ],
  "self.fn#1+143": [
    "--★★ USEEQUIPPEDITEM：使用已装备的物品。priority=1 + mount_valid，",
    "--   **无 instant** —— 行尾注释「use case similar to USEITEM except not instant」。",
    "--   ★★ USEITEM 与 USEEQUIPPEDITEM 的 instant 差异是有意的：",
    "--     USEITEM 是「拿起即用」（一次性），USEEQUIPPEDITEM 是「按住持续用」。",
    "--   ★ fn（3368 行）同样有 3374 行那个 IsOpenedBy 疑似问题。",
  ],
  "self.fn#1+144": [
    "--★ STOPUSINGEQUIPPEDITEM：停止使用装备物。priority=1 + **instant** + mount_valid。",
    "--   ★★ 与 450 行紧邻但 instant 相反（450 无，451 有），且 3380 行：",
    "--     `ACTIONS.STOPUSINGEQUIPPEDITEM.strfn = ACTIONS.USEEQUIPPEDITEM.strfn`",
    "--     注释写明「same fn, diff str table」——",
    "--     ★★ 一个微妙的对照：函数共用，字符串表不同。",
    "--     复用 fn 但不复用 strfn，于是 UI 上两者仍可区分。",
  ],
  "self.fn#1+145": [
    "--★ TAKEITEM：拿取（从架子上拿特定物品）。",
    "--   ★ fn（3388 行）开头有英文注释解释它与 PICK/HARVEST 的区别：",
    "--     「用于拿取**指定**物品，而不是像 Pick/Harvest 那样生成物品」。",
    "--   ★★ 这是「取出」与「产出」的语义区别：TAKEITEM 不产生新物品。",
  ],
  "self.fn#1+146": [
    "--★ TAKESINGLEITEM：拿单个。与 TAKEITEM 共用 strfn 但 fn 不同（3418 行",
    "--   传 false 表示不拿整堆）。这是 T12 模板的「只共用一半」变体。",
  ],
  "self.fn#1+147": [
    "--★ MAKEBALLOON：做气球（韦伯）。mount_valid。",
  ],
  "self.fn#1+148": [
    "--★ CASTSPELL：施法（魔杖）。priority=-1 + rmb + distance=20 + mount_valid。",
    "--   ★★ distance=20 —— 极远。因为魔杖是远程的。",
    "--   ★ priority=-1（泛用档）：拿魔杖对着怪时，攻击(2) 会赢。合理。",
  ],
  "self.fn#1+149": [
    "--★ CAST_POCKETWATCH：施法（阿比盖尔的怀表）。行尾注释提到",
    "--   「pocketwatch_mountedcast 标签」。★ 同样是 priority=-1 + rmb + mount_valid。",
  ],
  "self.fn#1+150": [
    "--★★ BLINK：闪现（韦伯）。HIGH_ACTION_PRIORITY + rmb + distance=36 + mount_valid",
    "--   + encumbered_valid。",
    "--   ★★ distance=36 是全表第二远（仅次于 SET_HEADING 的 9999）。",
    "--     36 是「灵魂跳跃」的理论最大距离。",
    "--   ★ encumbered_valid：背着东西也能跳（代价在 fn 里按负重打折，见 3650 行）。",
    "--   ★★ 高优先级 + 右键的组合意味着「右键永远优先闪现」，",
    "--     除非该场景下某个 HIGH 动作也可用（如 BLINK_MAP）。",
  ],
  "self.fn#1+151": [
    "--★ BLINK_MAP：地图闪现。HIGH + customarrivecheck=ArriveAnywhere + rmb +",
    "--   mount_valid + encumbered_valid + map_action。",
    "--   ★★ 3630 行之后的 ACTIONS_MAP_REMAP[ACTIONS.BLINK.code]（3604 行）",
    "--     是本文件最复杂的函数（62 行）：它要计算消耗多少灵魂、",
    "--     处理船上的 fogrevealer 瞄准辅助、算 distanceperhop…",
    "--   ★ 那段代码是「地图动作重映射」的教科书。详见 p5。",
  ],
  "self.fn#1+152": [
    "--★ COMBINESTACK：合并堆叠。mount_valid + extra_arrive_dist=ExtraPickupRange。",
    "--   ★★★ 复用 ExtraPickupRange（§零 154 行）而不是新建一个，",
    "--     是因为「把两个堆叠合起来」与「从水里捡起来」的到达条件相同。",
    "--   ★ 4634 行的 DoActionAutoEquip 把它列入**不自动装备**白名单，",
    "--     否则合并堆叠时会把物品塞进手里打断操作。",
  ],
  "self.fn#1+153": [
    "--★ TOGGLE_DEPLOY_MODE：切换放置模式。HIGH + instant + mount_valid +",
    "--   floating_valid。",
    "--   ★★ 1672 行 `ACTIONS.TOGGLE_DEPLOY_MODE.strfn = ACTIONS.DEPLOY.strfn` ——",
    "--     复用 strfn 但不共用 fn（没有自己的 fn）。",
    "--     这是 T12 的变体：只借 UI 字符串。",
  ],
  "self.fn#1+154": [
    "--★ SUMMONGUARDIAN：召唤守护者（阿比盖尔）。rmb=false + distance=5。",
    "--   ★★ 显式写 rmb=false 很少见（不写默认也是 nil≈false）。",
    "--     ★ 说明作者在「这个必须左键」的语义上想要**显式声明**，",
    "--       大概是为了与周围 rmb=true 的动作做视觉对比。",
  ],
  "self.fn#1+155": [
    "--★★ HAUNT：附身。ghost_valid + ghost_exclusive + canforce +",
    "--   DefaultRangeCheck + mindistance=2。",
    "--   ★★★ ghost_exclusive=true（315 行）⇒ 幽灵专属动作。",
    "--   ★ mindistance=2（312 行）—— 全文件仅 2 处用到 mindistance 之一。",
    "--     ★★ 语义不是「距离下限」而是「太近不行」：",
    "--       玩家幽灵需要靠近目标，但 2 格内附身会「吓跑」对方。",
    "--     ⇒ mindistance 是一个**反向**约束，判断逻辑在别处。",
  ],
  "self.fn#1+156": [
    "--★ UNPIN：拔图钉。空 Action()。",
  ],
  "self.fn#1+157": [
    "--★ STEALMOLEBAIT：偷鼹鼠的诱饵。rmb=false + distance=0.75（极近）。",
    "--   ★★ 距离 0.75 说明这是「必须贴着鼹鼠才能偷」的技能动作。",
  ],
  "self.fn#1+158": [
    "--★ MAKEMOLEHILL：造鼹鼠丘。priority=4 + distance=0（原地）。",
    "--   ★★ priority=4 —— 很高，因为这是鼹鼠玩家的核心技能，",
    "--     必须压过几乎所有其他动作。",
    "--   ★ fn（3721 行）两个分支生成两种丘（molehill / molebathill）。",
  ],
  "self.fn#1+159": [
    "--★ MOLEPEEK：鼹鼠偷看。rmb=false + distance=1。",
    "--   ★ fn（3738 行）只 PushEvent(\"peek\") —— 纯粹的信号动作。",
  ],
  "self.fn#1+160": [
    "--★★ FEED：喂食。priority=1 + rmb=true + mount_valid。",
    "--   ★★ 有趣的是 FEED 与 FEEDPLAYER 都是 rmb=true，但优先级不同（1 vs 3）。",
    "--     ★ 推测：喂 NPC 比喂玩家更需要「明确指向」，所以优先级更高。",
    "--   ★★ fn（3749 行）是本文件**最长的单动作实现之一**（106 行），",
    "--     因为「喂饱的宠物可能会死（吃肉）」需要完整的处决 + 战利品流程。",
    "--     ★ 3825-3854 行还保留了一整段**被注释掉的旧实现**（30 行）——",
    "--       保留了「处决流程的参考版本」，方便对照理解重构原因。",
  ],
  "self.fn#1+161": [
    "--★ UPGRADE：升级。rmb=true + priority=1。",
  ],
  "self.fn#1+162": [
    "--★ HAIRBALL：吐毛球（韦伯）。rmb=false + distance=3。",
  ],
  "self.fn#1+163": [
    "--★ CATPLAYGROUND：猫玩闹（猫猫）。rmb=false + distance=1。",
  ],
  "self.fn#1+164": [
    "--★ CATPLAYAIR：猫空中玩闹。rmb=false + distance=2。",
  ],
  "self.fn#1+165": [
    "--★ FAN：扇风。rmb=true + mount_valid。",
  ],
  "self.fn#1+166": [
    "--★ ERASE_PAPER：擦纸。rmb=true + mount_valid。",
  ],
  "self.fn#1+167": [
    "--★ DRAW：画画。空 Action()。",
    "--   ★★ 4255 行在函数中间插了一行 `require(\"components/drawingtool\")` ——",
    "--     在 actions.lua 的函数体中间 require！这是为了延迟加载：",
    "--     drawingtool 可能是个很大的组件文件，只在真正画时才需要。",
    "--   ★★ 若 require 被重复执行（玩家画第二次画时），Lua 的 require 会",
    "--     查缓存返回，所以安全。但这个位置仍然很反直觉。",
  ],
  "self.fn#1+168": [
    "--★ BUNDLE：打包。rmb=true + priority=2。",
  ],
  "self.fn#1+169": [
    "--★ BUNDLESTORE：打包后放入容器。instant=true。",
    "--   ★ 2598 行 `ACTIONS.BUNDLESTORE.fn = ACTIONS.STORE.fn` —— T12 模板。",
    "--   ★★ strfn（2588 行）会在「正在为这个容器施工」时返回 \"CONSTRUCT\"，",
    "--     即**同一个动作在建造语境下显示成另一个词**。",
  ],
  "self.fn#1+170": [
    "--★ WRAPBUNDLE：捆扎完成。instant=true。",
  ],
  "self.fn#1+171": [
    "--★ UNWRAP：拆包。rmb=true + priority=2。",
  ],
  "self.fn#1+172": [
    "--★ PEEKBUNDLE：窥视包内。rmb=true + priority=2。",
  ],
  "self.fn#1+173": [
    "--★ BREAK：破坏。rmb=true + priority=2。",
    "--   ★ strfn（4376 行）在目标有 pickapart 标签时返回 \"PICKAPART\"。",
  ],
  "self.fn#1+174": [
    "--★ CONSTRUCT：施工。priority=1 + distance=2.5。",
    "--   ★★★ 这是本文件里**分支最多的 strfn**（4393-4405 行）：",
    "--     手上没材料 → OFFER_TO / REPAIR / REBUILD",
    "--     手上材料 + 目标是工地 → STORE",
    "--     手上材料 + 目标是材料堆 → OFFER",
    "--   ★★ 五种显示名对应五条完全不同的流程，是「一个动作多种语义」的极致。",
  ],
  "self.fn#1+175": [
    "--★ STOPCONSTRUCTION：停止施工。priority=1 + instant + distance=2。",
  ],
  "self.fn#1+176": [
    "--★ APPLYCONSTRUCTION：应用材料（放最后一个材料）。priority=1 + instant。",
  ],
  "self.fn#1+177": [
    "--★ 484 行的行内注释 `--channeling for scene entity` 是一处**分类标记**。",
    "--   ★★ 它把动作分成两类：",
    "--     · channeling for scene entity（485/486）—— 对场景物体引导",
    "--     · channeling for equipped item（488/489）—— 用手持物品引导",
    "--   ★ 两组都有 START/STOP 成对，且 fn 名称遵循同一命名法。",
  ],
  "self.fn#1+178": [
    "--★★ STARTCHANNELING：对物体引导（抽水机等）。priority=2 + distance=2.1。",
    "--   ★★ 保留的英文注释是一句**设计权衡记录**：",
    "--     「保持比 smother 更高的优先级，让水泵能用；但如果以后有更多",
    "--       东西变得可引导，就需要另做处理。」",
    "--   ★★★ 这是全文件最重要的一条「未来隐患」注释：",
    "--     它承认 priority=2 是为了压过 SMOTHER(426 行 priority=1) 而硬设的，",
    "--     并且明确指出扩展时会冲突。",
  ],
  "self.fn#1+179": [
    "--★ STOPCHANNELING：停止引导。instant + distance=2.1（与 START 一致）。",
  ],
  "self.fn#1+180": [
    "--★ 487 行的行内注释标记「第二个 channeling 类别」。",
  ],
  "self.fn#1+181": [
    "--★ START_CHANNELCAST：用装备引导。priority=-1 + rmb + do_not_locomote。",
    "--   ★★ do_not_locomote：引导时人不能移动（与 SCENE 版不同，",
    "--     因为手持物品的引导本来就是站桩）。",
  ],
  "self.fn#1+182": [
    "--★ STOP_CHANNELCAST：停止用装备引导。与 488 对称。",
  ],
  "self.fn#1+183": [
    "--★ 490 行单个 `--` 注释是「空注释块」的收尾，标记前面这一段结束。",
  ],
  "self.fn#1+184": [
    "--★ APPLYPRESERVATIVE：涂防腐剂（盐）。空 Action()。",
  ],
  "self.fn#1+185": [
    "--★★ COMPARE_WEIGHABLE：比重量。HIGH_ACTION_PRIORITY + encumbered_valid。",
    "--   ★★★ 这是 encumbered_valid 最合理的用例：",
    "--     玩家**正在**搬重物（超重）时，反而需要能上称。",
    "--     4124 行 fn 印证：没手持物时会去查 BODY 槽的装备。",
    "--   ★★ LOCAL 辅助函数 COMPARE_WEIGHABLE_TEST（4628 行）用标签交叉验证：",
    "--     目标是 trophiescale_XX 且物品是 weighable_XX。",
    "--   ★ 这是「标签即类型」的典型：不需要继承、不需要查表。",
  ],
  "self.fn#1+186": [
    "--★ WEIGH_ITEM：称重（电子秤）。空 Action()。",
    "--   ★ fn（4660 行）用一个漂亮的表达式同时确定「谁是秤谁是物」：",
    "--     `weigher ~= act.target and act.target or act.invobject`",
    "--   ★★ 这种「三元 Lua」写法要求读者熟悉 Lua 的 and/or 惯用法。",
  ],
  "self.fn#1+187": [
    "--★ START_CARRAT_RACE：开赛（嘉年华）。rmb=true。",
  ],
  "self.fn#1+188": [
    "--★ CASTSUMMON：召唤幽灵。rmb=true + mount_valid + priority=3。",
  ],
  "self.fn#1+189": [
    "--★ CASTUNSUMMON：收回幽灵。mount_valid + distance=math.huge + priority=3。",
    "--   ★★ distance=math.huge：「在任意远处收回」—— 幽灵跟着你，不需要靠近。",
  ],
  "self.fn#1+190": [
    "--★ COMMUNEWITHSUMMONED：与幽灵交流。rmb=true + mount_valid + priority=2。",
    "--   ★ strfn（3680 行）根据 has_aggressive_follower 标签切换「改为攻击/改为防御」，",
    "--     即「同一动作，一键切换幽灵指令」。",
  ],
  "self.fn#1+191": [
    "--★ TELLSTORY：讲故事。rmb=true + distance=3。",
    "--   ★★ 1574 行保留的英文注释解释了 stroverridefn 的用意：",
    "--     「我们只是返回同样的字符串，但因为它被『覆盖』了，",
    "--       它不会显示目标：例如不会显示『Tell Story Portable Campfire』。」",
    "--   ★★★ 这解释了 bufferedaction.lua:53-64 的 overriden 机制：",
    "--     stroverridefn 返回 (str, true) 时，第二个返回值告诉调用方",
    "--     「我已经完全接管了这个字符串，别再拼接目标名」。",
    "--   ★ 对比 strfn：strfn 返回的只是**修饰词**（会与目标名拼接）。",
    "--     ★ 这是两种字符串钩子的根本区别，见 bufferedaction.lua:52。",
  ],
  "self.fn#1+192": [
    "--★ PERFORM：表演。rmb=true + distance=1.5 + invalid_hold_action。",
  ],
  "self.fn#1+193": [
    "--★ 500 行空行把「基础动作」与「投掷/季节动作」分隔开。",
    "--   ★ 这不是硬分组，但确实形成了本表最长的一个视觉段落（359-499）。",
  ],

  // ══════════════════════════════════════════════════════════════
  // §四 ACTIONS 表 · 投掷 / 季节 / 船只 / 农场
  // ══════════════════════════════════════════════════════════════
  "self.fn#1+194": [
    "--★★ TOSS：投掷。priority=1 + rmb=true + distance=8 + mount_valid。",
    "--   ★★ distance=8 与 170 行 `ExtraDeployDist` 里的 `8 - DEPLOY.distance`",
    "--     是同一个 8。两处独立字面量，靠注释而非常量关联。",
    "--   ★ fn（3934 行）是本文件最复杂的投掷实现（47 行），要处理：",
    "--     无手持物时用手持物（须有 special_action_toss 标签）、",
    "--     物品有 equippable 时检查限制、伪装检查、投掷偏移量（targetoffset）。",
  ],
  "self.fn#1+195": [
    "--★ TOSS_MAP：地图投掷。HIGH + ArriveAnywhere + rmb + map_action + closes_map。",
    "--   ★★ 4003 行 `ACTIONS_MAP_REMAP[ACTIONS.TOSS.code]` 是地图重映射的",
    "--     第二个实例（第一个是 ACTIVATE 1277 行，第三个是 BLINK 3604 行）。",
    "--     它做了 min/max 距离夹取与「目标必须是真水面」的校验。",
  ],
  "self.fn#1+196": [
    "--★ NUZZLE：蹭。空 Action()。fn（4057 行）只 return true（连 print 都是注释）。",
    "--   ★★ 4059 行有一行被注释掉的 print，作者自己把它去掉了。",
  ],
  "self.fn#1+197": [
    "--★ WRITE：写（告示牌）。空 Action()。",
    "--   ★ fn（4064 行）里又一处「黑暗中静默失败」（4075 行 CanEntitySeeTarget）。",
  ],
  "self.fn#1+198": [
    "--★ ATTUNE：调频（韦伯）。空 Action()。",
  ],
  "self.fn#1+199": [
    "--★★ REMOTERESURRECT：远程复活。rmb=false + ghost_valid + ghost_exclusive。",
    "--   ★★ ghost_exclusive ⇒ 只有幽灵能用「复活自己」的道具。",
    "--     与 HAUNT 同族。fn（4098 行）读 attuner 的调频目标。",
  ],
  "self.fn#1+200": [
    "--★★ REVIVE_CORPSE：复活尸体。rmb=false + **actionmeter=true**。",
    "--   ★★ 全文件唯一使用 actionmeter 的动作（§一 327 行已详述）。",
    "--     玩家按住复活尸体时会看到进度环 —— 因为「读条」是必要的反馈。",
    "--   ★ 对比普通的复活（用骨头）不需要读条，所以没有 actionmeter。",
  ],
  "self.fn#1+201": [
    "--★ MIGRATE：迁移（狼人传送？）。rmb=false + encumbered_valid + ghost_valid。",
  ],
  "self.fn#1+202": [
    "--★ MOUNT：骑乘。priority=1 + rmb=true + encumbered_valid。",
    "--   ★★ fn（4122 行）是全文件**判定链最长**的动作之一（24 行，7 个分支）：",
    "--     战斗中的生物（除战斗坐骑）→ 不可骑",
    "--     无 rideable / canride 为假 / 已死 / 冰冻 / 已被拴 → 不可骑",
    "--     已被骑 → INUSE",
    "--     dogrider_only 标签与骑手不符 → 不可骑",
    "--   ★ 每一条都有对应的失败原因或静默 false，是「穷举式校验」的范本。",
  ],
  "self.fn#1+203": [
    "--★ DISMOUNT：下坐骑。priority=1 + instant + rmb + mount_valid + encumbered_valid。",
    "--   ★★ mount_valid=true 的含义特殊：下坐骑时当然还骑着，",
    "--     这个标记保证「骑着时能下马」这件事不被 mount_valid 拦住。",
    "--     ★ 这是 mount_valid 语义最容易误解的一处，注释里隐含但没写明。",
  ],
  "self.fn#1+204": [
    "--★ SADDLE：上鞍。priority=1。",
  ],
  "self.fn#1+205": [
    "--★ UNSADDLE：卸鞍。priority=3（比 SADDLE 高）+ rmb=false。",
    "--   ★★ priority 不对称（1 vs 3）：卸鞍是「明确指令」，上鞍是「顺手」。",
  ],
  "self.fn#1+206": [
    "--★ BRUSH：刷毛。priority=3 + rmb=false。",
  ],
  "self.fn#1+207": [
    "--★ ABANDON：遗弃。rmb=true。fn（4200 行）两分支：",
    "--   petleash（韦伯的宠物）或 follower（跟随者）。",
    "--   ★★ 4202-4208 行有一段特殊逻辑：如果玩家没解锁 ORPHANAGE 科技树，",
    "--     却「看起来应该能」（10 格内有 critterlab），则静默失败。",
    "--     英文注释说「we could've been in range but the pet was out of range」——",
    "--     即「距离判定已经放行了，但宠物实际不在附近，所以别真删」。",
  ],
  "self.fn#1+208": [
    "--★ PET：撸。空 Action()。fn（4218 行）对 crittertraits 与 kitcoon 各推一个事件。",
  ],
  "self.fn#1+209": [
    "--★ DISMANTLE：拆除。rmb=true。fn（4550 行）有完整的拆除前置检查：",
    "--   容器打开中 → INUSE；非空 → NOTEMPTY；不可打开（烹饪中）→ COOKING。",
    "--   ★★ 三种失败原因都是玩家会立刻理解的，很好的一致性设计。",
  ],
  "self.fn#1+210": [
    "--★ TACKLE：冲撞。rmb=true + distance=math.huge + invalid_hold_action。",
    "--   ★ distance=math.huge：冲撞是「朝一个方向扑」，不需要锁定目标距离。",
  ],
  "self.fn#1+211": [
    "--★ GIVE_TACKLESKETCH：给鱼饵图纸。空 Action()。",
  ],
  "self.fn#1+212": [
    "--★ REMOVE_FROM_TROPHYSCALE：从荣誉榜上取下物品。空 Action()。",
  ],
  "self.fn#1+213": [
    "--★ CYCLE：循环（唱歌贝壳、高尔夫球座）。rmb=true + priority=2。",
    "--   ★ strfn（5155 行）按 singingshell / golf_tee 标签返回 TUNE / PAR。",
    "--   ★ 这是「同一个组件 cyclable 服务多个道具」的例子。",
  ],
  "self.fn#1+214": [
    "--★ 521 行空行标记「季节/扩展动作」段的开始。",
  ],
  "self.fn#1+215": [
    "--★★ CASTAOE：范围施法。HIGH + rmb + mount_valid + distance=8 +",
    "--   invalid_hold_action。",
    "--   ★★ 它是 HIGH 动作里唯一的「战斗」类，说明「开局必须能放 AOE」",
    "--     比「攻击单个目标」更不能让路。",
    "--   ★★ 另有一处特殊待遇：playercontroller.lua:4563-4574 允许",
    "--     施法在 busy 状态下重复（CanRepeatCast）。见 §五 的说明。",
  ],
  "self.fn#1+216": [
    "--★ 523 行空行。",
  ],
  "self.fn#1+217": [
    "--★ HALLOWEENMOONMUTATE：万圣节月相药水。priority=-1。",
    "--   ★★ fn（4582 行）里有一行**被注释掉的判据**（4585 行）：",
    "--     `--or (not act.target:HasTag(\"flying\") and not IsPassableAtPoint(...))`",
    "--   ★ 这行注释揭示了一个被**放宽**的限制：曾要求目标不能飞行、",
    "--     且必须站在可通行地面上。现在去掉了 —— 大概是为了允许在船上使用。",
    "--   ★★ 保留被注释掉的判据是好习惯：它记录了「为什么现在的逻辑更宽松」。",
  ],
  "self.fn#1+218": [
    "--★ 525 行空行。",
  ],
  "self.fn#1+219": [
    "--★ WINTERSFEAST_FEAST：冬至节盛宴。priority=1。",
    "--   ★★★ fn（5198-5201）是全文件**最极端的空实现**：",
    "--       function(act)",
    "--           return true",
    "--           -- Logic is handled from stategraph; action is never actually performed",
    "--       end",
    "--   ★★ 注意 return true **写在注释之前** —— 也就是说后面那行注释",
    "--     在语法上已经不可达（虽然注释本来就不影响语义）。",
    "--     ★ 作者的意图是「return true 之后的代码不会执行」，",
    "--       于是把说明放在了后面。写法古怪但意图清晰。",
    "--   ★★ 为什么会这样？因为「吃宴席」的表演（坐下、吃、多人同时）",
    "--     必须在状态图里实现，动作本身只是个触发信号。",
  ],
  "self.fn#1+220": [
    "--★ 527 行空行。",
  ],
  "self.fn#1+221": [
    "--★ BEGIN_QUEST：接任务。空 Action()。",
  ],
  "self.fn#1+222": [
    "--★ ABANDON_QUEST：放弃任务。空 Action()。",
  ],
  "self.fn#1+223": [
    "--★ 530 行空行。",
  ],
  "self.fn#1+224": [
    "--★ SING：唱歌。rmb=true + mount_valid。",
  ],
  "self.fn#1+225": [
    "--★★ SING_FAIL：唱歌失败。rmb=true + mount_valid —— 与 SING 声明完全相同！",
    "--   ★★★ 这是 T6 影子动作最纯粹的一个例子：",
    "--     两个 Action 的**声明一字不差**，只有 fn 不同。",
    "--       SING      fn → 有 singinginspiration 就 Sing（5235 行）",
    "--       SING_FAIL fn → `return true`（5246 行）",
    "--   ★★ 为什么要这样？见 SGwilson.lua:1301：",
    "--       ActionHandler(ACTIONS.SING_FAIL, \"sing_fail\")",
    "--     ★ 失败时要走**另一个状态**（sing_fail），而状态图按动作 id 路由。",
    "--       如果复用 SING，SG 无法区分「正常唱」与「唱失败」这两个事件。",
    "--   ★★ 本质上：影子动作 = 「同一个玩家意图，不同的执行结果」",
    "--     在状态图里的两个不同状态。这是一种很 economical 的建模。",
  ],
  "self.fn#1+226": [
    "--★ 533 行空行 —— 标记从「基础/通用动作」到「Quagmire 等 DLC 动作」的分界。",
  ],
  "self.fn#1+227": [
    "--★ 534 行的 `--Quagmire` 标记引入了第一批带玩法归属的动作。",
    "--   ★★ 534-741 共 200 行里，约 60% 属于某个角色或季节。",
    "--     这解释了为什么表尾越积越长：每加一个角色就追加一段。",
  ],
  "self.fn#1+228": [
    "--★★ TILL：开垦。distance=0.5（极近！）+ theme_music=\"farming\"。",
    "--   ★★ distance=0.5 是全表最小值。为什么？",
    "--     因为开垦要求玩家**站在田的正中间**，否则格子会被算到隔壁。",
    "--     ★ 这是「格子级精度」要求到达距离的例子，与 CheckTileWithinRange",
    "--       （§零 121 行）呼应 —— 两者一起把开垦做成了「精准站位」交互。",
  ],
  "self.fn#1+229": [
    "--★ PLANTSOIL：种土。theme_music=\"farming\"，无距离。",
  ],
  "self.fn#1+230": [
    "--★ INSTALL：安装（Quagmire）。空 Action()。",
  ],
  "self.fn#1+231": [
    "--★ TAPTREE：接树液管。priority=1 + rmb=true。",
  ],
  "self.fn#1+232": [
    "--★ SLAUGHTER：屠宰。canforce + DefaultRangeCheck。",
    "--   ★ fn（4772 行）里有**独立的手写距离检查**（4778 行 IsNear(target, 2)），",
    "--     与 446 行 STEAL 的做法相同：没有声明 rangecheckfn 就自己写。",
    "--   ★★ 这里是 2 而 DefaultRangeCheck 是 4 —— 屠宰允许更近。",
  ],
  "self.fn#1+233": [
    "--★ REPLATE：换盘子。空 Action()。",
  ],
  "self.fn#1+234": [
    "--★ SALT：腌渍。空 Action()。",
  ],
  "self.fn#1+235": [
    "--★ 542 行空行。",
  ],
  "self.fn#1+236": [
    "--★ BATHBOMB：浴弹。空 Action()。",
  ],
  "self.fn#1+237": [
    "--★ 544 行空行。",
  ],
  "self.fn#1+238": [
    "--★ COMMENT：点评（动物花纹）。distance=4。",
    "--   ★★ fn（2908 行）区分 npc_talker 与 talker 两套组件 ——",
    "--     「能评论」这个玩法同时对玩家与 NPC 开放。",
  ],
  "self.fn#1+239": [
    "--★ WATER_TOSS：水中投掷。priority=3 + rmb + CheckOceanFishingCastRange",
    "--   + is_relative_to_platform + disable_platform_hopping。",
    "--   ★★ 3982 行 `ACTIONS.WATER_TOSS.fn = ACTIONS.TOSS.fn` —— T12 模板。",
    "--     与 TOSS 的差别：priority(3 vs 1) 与 customarrivecheck（有 vs 无）。",
    "--   ★ priority=3 保证「对着水面投掷」压过「对地面投掷」。",
  ],
  "self.fn#1+240": [
    "--★ 547 行空行 + 548 行 `-- boats` 标记：船只动作段开始。",
    "--   ★★ 549-601 共 53 行全是船相关动作，是 ACTIONS 表里最大的单一主题块。",
    "--     共同特征：几乎全部有 distance 且都带 invalid_hold_action，",
    "--     因为船上操作必须「按住」且不能误触。",
  ],
  "self.fn#1+242": [
    "--★ RAISE_SAIL：升帆。distance=1.25 + invalid_hold_action。",
    "--   ★★ 4810 行保留的英文注释直言「this name is backwards」：",
    "--     「raising 在这里意味着『把帆升满』」—— 作者认为命名反了但不改。",
    "--   ★★ 这种「明知命名不佳但保留」的情况是重构债的化石，注释是唯一的线索。",
  ],
  "self.fn#1+243": [
    "--★ LOWER_SAIL：降帆。distance=1.25 + invalid_hold_action。",
    "--   ★★ 4821 行又一句「this name is backwards」：",
    "--     「lowering 意味着『把帆卷起来』」。同样不改。",
  ],
  "self.fn#1+244": [
    "--★ LOWER_SAIL_BOOST：加速降帆。distance=1.25 + invalid_hold_action。",
    "--   ★ fn（4829 行）叠加两个乘数：expertsailor 的力量 × 船员加成。",
  ],
  "self.fn#1+245": [
    "--★★ LOWER_SAIL_FAIL：降帆失败。distance=1.25 + **do_not_locomote** +",
    "--   invalid_hold_action。",
    "--   ★★ 与 551 行的唯一差别是 do_not_locomote=true。",
    "--     含义：失败时玩家已经站在那了，不要再走一次。",
    "--     ★ 又一个 T6 影子动作 —— 连距离都要抄一遍，",
    "--       说明「影子动作必须完整复制声明」是这个模式的固有负担。",
  ],
  "self.fn#1+246": [
    "--★ RAISE_ANCHOR：抛锚。distance=2.5 + invalid_hold_action。",
  ],
  "self.fn#1+247": [
    "--★ LOWER_ANCHOR：起锚。distance=2.5 + invalid_hold_action。",
  ],
  "self.fn#1+248": [
    "--★ EXTEND_PLANK：伸出跳板。distance=2.5 + invalid_hold_action。",
  ],
  "self.fn#1+249": [
    "--★ RETRACT_PLANK：收回跳板。distance=2.5 + invalid_hold_action。",
  ],
  "self.fn#1+250": [
    "--★ ABANDON_SHIP：弃船。distance=2.5 + priority=4 + invalid_hold_action。",
    "--   ★★ priority=4 很高：弃船是「不可逆」的极端操作，需要玩家明确意图。",
  ],
  "self.fn#1+251": [
    "--★ MOUNT_PLANK：上跳板。distance=0.5 —— 极近，呼应 TILL 的精度要求。",
  ],
  "self.fn#1+252": [
    "--★ DISMOUNT_PLANK：下跳板。distance=2.5。",
    "--   ★★ 注意与 MOUNT_PLANK 不对称：上要 0.5，下要 2.5。",
    "--     推断：上跳板要在板根（判定点），下跳板可以远远走下。",
  ],
  "self.fn#1+253": [
    "--★ REPAIR_LEAK：补船漏。distance=2.5 + invalid_hold_action。",
  ],
  "self.fn#1+254": [
    "--★★ STEER_BOAT：掌舵。**arrivedist=0.1**（全表最小）。",
    "--   ★★ 0.1 格 —— 必须站得极近才能掌舵。",
    "--     原因：舵要求「抓住舵柄」，站太远就抓不到。",
    "--   invalid_hold_action ⇒ 掌舵不会自动重复。",
    "--   ★ 它是全表**唯一**使用 arrivedist 而非 distance 的动作（另有 WOBY_PICKUP）。",
  ],
  "self.fn#1+255": [
    "--★★ SET_HEADING：设定航向。distance=9999 + do_not_locomote。",
    "--   ★★★ 9999 不是「无限」的等价写法吗？是的，但作者选择了具体数字。",
    "--     ★★ 差别在于：locomotor.lua:947 判断 `>= math.huge`，",
    "--       而 9999 < math.huge，所以它**不会**走「实质瞬间」那条分支！",
    "--     ★★★ 这是一个真实的差异：",
    "--       distance=math.huge → 走 947 行分支 → FaceMovePoint + Push",
    "--       distance=9999        → 走最后的 else 分支 → GoToPoint(9999 格外)",
    "--     ★ 幸而 do_not_locomote=true（945 行）在前面就拦住了，",
    "--       所以结果一致 —— 但这是**两个标志的巧合**，不是设计。",
    "--       ★ 同一份「转但不移动」的需求，这里用 (9999 + do_not_locomote)，",
    "--         另一边 420 行 BOAT_MAGNET 与 596 行 BOAT_CANNON_SHOOT 也用 9999。",
    "--   ★ 与 414 行 CATCH 用的是真正的 math.huge。对比之下更明显。",
  ],
  "self.fn#1+256": [
    "--★ STOP_STEERING_BOAT：停止掌舵。**instant=true** —— 与 SET_HEADING 配对。",
  ],
  "self.fn#1+257": [
    "--★★ CAST_NET：撒网。HIGH + rmb + distance=12 + mount_valid",
    "--   + disable_platform_hopping。",
    "--   ★ distance=12 —— 海钓投竿的 1.2 倍。",
    "--   ★★ 这是 HIGH 动作里唯一的「渔具」类，理由与 BLINK 类似：",
    "--     撒网是长按蓄力动作，必须保证不被其他交互打断启动。",
  ],
  "self.fn#1+258": [
    "--★ ROW_FAIL：划桨失败。ArriveAnywhere + disable_platform_hopping +",
    "--   skip_locomotor_facing + invalid_hold_action。",
    "--   ★★ ArriveAnywhere 让它「立即触发」—— 失败不需要走过去。",
    "--   ★★ fn（1335 行）有一段极有价值的英文注释：",
    "--     「不能靠返回 false 来触发失败串，因为返回 false 会跳过",
    "--       finite uses 回调，桨就不会掉耐久。」",
    "--   ★★★ 这解释了 T6 影子动作的**根本动机**：",
    "--     有些副作用（耐久、语音）必须执行，但动作仍要报告「成功」，",
    "--     否则 inventory 的 finiteuses 回调不会跑。",
    "--     ⇒ 于是只能「真的成功」，失败反馈全部手动 Say（1343 行）。",
  ],
  "self.fn#1+259": [
    "--★★ ROW：划桨。priority=3 + CheckRowRange + is_relative_to_platform",
    "--   + disable_platform_hopping + invalid_hold_action。",
    "--   ★★ ROW 与 ROW_CONTROLLER（567 行）的 fn 相同（1372/1376 行都调 row()），",
    "--     但 ROW 有 CheckRowRange 而 ROW_CONTROLLER 没有。",
    "--   ★ 推断：手柄玩家不需要「探针检查站位」，因为摇杆输入本身保证了站在船上。",
    "--     ★★★ 这是「按输入设备分出两个动作」的少见做法。",
  ],
  "self.fn#1+260": [
    "--★ ROW_CONTROLLER：手柄划桨。priority=3 + is_relative_to_platform",
    "--   + disable_platform_hopping + do_not_locomote + invalid_hold_action。",
    "--   ★ do_not_locomote ⇒ 手柄玩家原地划。",
  ],
  "self.fn#1+261": [
    "--★ BOARDPLATFORM：上船。customarrivecheck=CheckIsOnPlatform（§零 99 行）。",
    "--   ★★ fn（1380 行）只有 `return true`。这是 T5 的极端样本。",
  ],
  "self.fn#1+262": [
    "--★ OCEAN_TOSS：往海里扔。priority=3 + rmb + CheckOceanFishingCastRange",
    "--   + is_relative_to_platform + disable_platform_hopping。",
    "--   ★ 5174 行 fn 用 oceanthrowable 组件 + 手动 Launch（与 TOSS 的",
    "--     complexprojectile:Launch 不同路径）。",
  ],
  "self.fn#1+263": [
    "--★ UNPATCH：拆补丁（Quagmire 临时）。distance=0.5。",
  ],
  "self.fn#1+264": [
    "--★★ POUR_WATER：浇水。rmb + tile_placer=\"gridplacer\" +",
    "--   show_tile_placer_fn + extra_arrive_dist=ExtraPourWaterDist（1.5）。",
    "--   ★★ 它是**唯一一个 tile_placer + show_tile_placer_fn 同时使用**的动作：",
    "--     有高亮框（因为要连续浇多格），且高亮逻辑要判断是否农田（141 行）。",
    "--   ★ 注释互证：§零 148 行的英文注释说「悬停农田上时，",
    "--     POUR_WATER_GROUNDTILE 会抢先」—— 即 572 行的动作。",
  ],
  "self.fn#1+265": [
    "--★★ POUR_WATER_GROUNDTILE：浇单个地面格子。rmb +",
    "--   CheckTileWithinRange + tile_placer=\"gridplacer\" + theme_music=\"farming\"。",
    "--   ★★ 5421 行 `ACTIONS.POUR_WATER_GROUNDTILE.fn = ACTIONS.POUR_WATER.fn`",
    "--     —— T12 模板。",
    "--   ★★ 注意两者都**没有 priority**（默认 0），所以「浇一格」与「浇一片」",
    "--     是同级竞争。§零 148 行承认了这个竞争并用渲染守卫兜底。",
  ],
  "self.fn#1+266": [
    "--★ PLANTREGISTRY_RESEARCH_FAIL：植物研究失败。priority=-1。",
    "--   ★★ 与 PLANTREGISTRY_RESEARCH（574 行 HIGH）成对。",
    "--     失败版 priority=-1 而成功版 HIGH —— 优先级差 11，",
    "--     保证了「成功研究」永远压过「失败研究」。",
    "--   ★ fn（5426 行）返回 false + 失败原因（FERTILIZER / ITEMMIMIC）。",
  ],
  "self.fn#1+267": [
    "--★ PLANTREGISTRY_RESEARCH：植物研究。priority=HIGH_ACTION_PRIORITY。",
    "--   ★★ 优先级 10 与所有界面动作同级 —— 因为「打开研究界面」",
    "--     与「传送到地图某点」一样会改变操作模式。",
    "--   ★ 5432 行在 fn 开头 require 了 weed_defs（5501 行）—— 又一处延迟加载。",
  ],
  "self.fn#1+268": [
    "--★ ASSESSPLANTHAPPINESS：评估作物心情。priority=1。",
  ],
  "self.fn#1+269": [
    "--★ ATTACKPLANT：攻击作物（减压）。空 Action()。",
  ],
  "self.fn#1+270": [
    "--★ PLANTWEED：种草（替代作物）。空 Action()。",
  ],
  "self.fn#1+271": [
    "--★ ADDCOMPOSTABLE：加堆肥。空 Action()。",
  ],
  "self.fn#1+272": [
    "--★★ WAX：上蜡。encumbered_valid + **mindistance=1.5**。",
    "--   ★★ 全文件仅 2 处 mindistance 之一（另一处是 HAUNT）。",
    "--     语义：涂蜡需要看清蜡面，贴太近反而看不清（§一 312 行已述）。",
    "--   ★ encumbered_valid：手上拿着东西也要能涂。",
  ],
  "self.fn#1+273": [
    "--★ APPRAISE：鉴定。空 Action()。fn（768 行）是本文件**第一个 fn**。",
  ],
  "self.fn#1+274": [
    "--★ UNLOAD_WINCH：绞盘卸货。rmb=true + priority=3。",
  ],
  "self.fn#1+275": [
    "--★ USE_HEAVY_OBSTACLE：使用重型障碍物。encumbered_valid + rmb + priority=1。",
    "--   ★★ 与 COMPARE_WEIGHABLE(492) 并列使用 encumbered_valid 的两个动作，",
    "--     都是「超重状态下才需要做的事」。语义高度一致。",
  ],
  "self.fn#1+276": [
    "--★ ADVANCE_TREE_GROWTH：催长树。空 Action()。",
  ],
  "self.fn#1+277": [
    "--★ 584 行空行。",
  ],
  "self.fn#1+278": [
    "--★★ ROTATE_BOAT_CLOCKWISE：船顺时针旋转。show_secondary_input_right=true",
    "--   + rmb=true + priority=1。",
    "--   ★★ show_secondary_input_right 是 342 行那个字段的唯一用户。",
    "--     它的存在说明「按键提示」本身也需要被数据驱动 ——",
    "--     因为这个动作绑定右键但长得像左键动作，UI 必须显式纠正。",
  ],
  "self.fn#1+279": [
    "--★ ROTATE_BOAT_COUNTERCLOCKWISE：船逆时针旋转。show_primary_input_left=true",
    "--   + priority=1。",
    "--   ★★ 两个旋转动作**刻意镜像**（一个显示右键提示，一个显示左键提示），",
    "--     因为手柄上左右两个摇杆/按键对应两个方向。",
  ],
  "self.fn#1+280": [
    "--★ ROTATE_BOAT_STOP：停止旋转。空 Action()。",
  ],
  "self.fn#1+281": [
    "--★ 588 行空行。",
  ],
  "self.fn#1+282": [
    "--★ BOAT_MAGNET_ACTIVATE：激活船磁铁。空 Action()。",
  ],
  "self.fn#1+283": [
    "--★ BOAT_MAGNET_DEACTIVATE：取消船磁铁。空 Action()。",
  ],
  "self.fn#1+284": [
    "--★ BOAT_MAGNET_BEACON_TURN_ON：信标开启。rmb=true + priority=3。",
  ],
  "self.fn#1+285": [
    "--★ BOAT_MAGNET_BEACON_TURN_OFF：信标关闭。rmb=true + priority=3。",
    "--   ★★ 与 591 完全对称（都是 rmb + priority=3），是成对设计的样本。",
  ],
  "self.fn#1+286": [
    "--★ 593 行空行。",
  ],
  "self.fn#1+287": [
    "--★ BOAT_CANNON_LOAD_AMMO：装炮弹。distance=1.4 + mount_valid",
    "--   + paused_valid + rmb=true + priority=3。",
    "--   ★★ paused_valid 第二次出现（第一次是 ADDFUEL）——",
    "--     理由相同：房主暂停时也要能管船。",
    "--   ★ 5030 行 fn 显示：空手时会在背包里自动找炮弹（FindItem），",
    "--     手上有东西时只用手上的。两种输入路径共用一个动作。",
  ],
  "self.fn#1+288": [
    "--★ BOAT_CANNON_START_AIMING：开始瞄准。distance=1.4。",
    "--   ★ 有 pre_action_cb（5049 行）关法术轮盘。",
  ],
  "self.fn#1+289": [
    "--★★ BOAT_CANNON_SHOOT：开炮。distance=9999 + do_not_locomote。",
    "--   ★ 与 562 行 SET_HEADING 同样的 (9999 + do_not_locomote) 组合。",
    "--     fn（5066 行）有一个双分支：有 boatcannonuser 就用玩家的炮，",
    "--     否则直接把目标的炮开火（NPC 触发）。",
  ],
  "self.fn#1+290": [
    "--★ BOAT_CANNON_STOP_AIMING：停止瞄准。instant=true。",
  ],
  "self.fn#1+291": [
    "--★ 598 行空行。",
  ],
  "self.fn#1+292": [
    "--★ OCEAN_TRAWLER_LOWER：放下拖网。distance=2.8 + rmb=true。",
  ],
  "self.fn#1+293": [
    "--★ OCEAN_TRAWLER_RAISE：升起拖网。distance=2.8 + rmb=true。",
  ],
  "self.fn#1+294": [
    "--★ OCEAN_TRAWLER_FIX：修拖网。distance=2.8。",
  ],
  "self.fn#1+295": [
    "--★ 602 行空行。",
  ],
  "self.fn#1+296": [
    "--★ EMPTY_CONTAINER：清空容器。空 Action()。",
    "--   ★★ fn（959 行）有一处很有意思的「保留注释」：",
    "--     964 行 `--act.target.components.container:DropEverything()` 被注释掉，",
    "--     改成调用 `workable.onwork` 回调。",
    "--   ★★ 保留了被注释的旧实现，读者能看出「清空」曾被重新设计为",
    "--     「触发目标自己的 onwork 逻辑」——可能只是显示一下。",
  ],
  "self.fn#1+297": [
    "--★ 604 行空行。",
  ],
  "self.fn#1+298": [
    "--★ CARNIVAL_HOST_SUMMON：召唤主持人。空 Action()。",
  ],
  "self.fn#1+299": [
    "--★ 606 行空行。",
  ],
  "self.fn#1+300": [
    "--★ 607 行的 `-- YOTB` 标记：Year of the Buffalo 系列。",
  ],
  "self.fn#1+301": [
    "--★ YOTB_SEW：缝纫。priority=1 + mount_valid。",
  ],
  "self.fn#1+302": [
    "--★ YOTB_STARTCONTEST：开始比赛。空 Action()。",
    "--   ★ fn（5580 行）有一段有趣的分支：主持人「有反应」(GetHostVisible) 时",
    "--     会区分「是你」→ RIGHTTHERE 与「别人」→ NORESPONSE。",
  ],
  "self.fn#1+303": [
    "--★ YOTB_UNLOCKSKIN：解锁皮肤。空 Action()。",
  ],
  "self.fn#1+304": [
    "--★ 611 行空行。",
  ],
  "self.fn#1+305": [
    "--★ CARNIVALGAME_FEED：喂嘉年华游戏。mount_valid。",
  ],
  "self.fn#1+306": [
    "--★ 613 行空行。",
  ],
  "self.fn#1+307": [
    "--★ 614 行的 `-- YOT_Catcoon` 标记。",
  ],
  "self.fn#1+308": [
    "--★ RETURN_FOLLOWER：归还跟随者（猫猫）。空 Action()。",
  ],
  "self.fn#1+309": [
    "--★ HIDEANSEEK_FIND：捉迷藏找藏身处。rmb=true + priority=1 + mount_valid。",
  ],
  "self.fn#1+310": [
    "--★ 617 行空行。",
  ],
  "self.fn#1+311": [
    "--★ 618 行的 `-- WEBBER` 标记：韦伯专属动作段。",
    "--   ★★ 有趣：韦伯的动作**不全在这个段里** —— BLINK(457)、",
    "--     REMOTERESURRECT(506)、BLINK_MAP(458) 都在前面的通用段。",
    "--   ★ 分组依据是「作者写这段时的心情」而非「谁能用」。",
  ],
  "self.fn#1+312": [
    "--★ MUTATE_SPIDER：变异蜘蛛。priority=2。",
  ],
  "self.fn#1+313": [
    "--★ HERD_FOLLOWERS：驱赶跟随者群。mount_valid。",
  ],
  "self.fn#1+314": [
    "--★ REPEL：驱赶。mount_valid。",
  ],
  "self.fn#1+315": [
    "--★ BEDAZZLE：眩光。空 Action()。fn（5641 行）是 T2 模板的干净样本。",
  ],
  "self.fn#1+316": [
    "--★ 623 行空行。",
  ],
  "self.fn#1+317": [
    "--★ 624 行的 `-- WANDA` 标记。",
  ],
  "self.fn#1+318": [
    "--★ DISMANTLE_POCKETWATCH：拆怀表。mount_valid。",
  ],
  "self.fn#1+319": [
    "--★ 626 行空行。",
  ],
  "self.fn#1+320": [
    "--★ 627 行的 `-- WOLFGANG` 标记。",
  ],
  "self.fn#1+321": [
    "--★★ LIFT_DUMBBELL：举哑铃。priority=2 + **mount_valid=false**。",
    "--   ★★ 唯一显式写 mount_valid=false 的动作 —— 显式声明「默认值之外」",
    "--     是一件有噪音的事，作者却写了，因为后面 630/631/632/635 行",
    "--     也都重复了一遍。",
    "--   ★ 行尾注释「Higher than TOSS」解释了 priority=2：",
    "--     ★★ 举哑铃要压过投掷（438 行 TOSS 的 priority=3 其实是更高）——",
    "--       等等，3 > 2，所以这个注释在数值上**与 TOSS 的声明矛盾**。",
    "--   ★★★ 可能的解释：这里的「TOSS」指的是别的动作，或者注释指的是",
    "--     「原版设计时的 TOSS 优先级」。不管哪种，这是一个可疑之处。",
  ],
  "self.fn#1+322": [
    "--★ 629 行空行。",
  ],
  "self.fn#1+323": [
    "--★ STOP_LIFT_DUMBBELL：停止举哑铃。priority=2 + mount_valid=false + instant。",
  ],
  "self.fn#1+324": [
    "--★ ENTER_GYM：进健身房。mount_valid=false + invalid_hold_action。",
  ],
  "self.fn#1+325": [
    "--★ UNLOAD_GYM：卸载杠铃。mount_valid=false。",
  ],
  "self.fn#1+326": [
    "--★ 633 行空行 + 634 行注释 `Minigame actions:` —— 引入 4 个小游戏动作。",
    "--   ★★ 这组是 §6 的独特子型：动作本身没有业务逻辑，",
    "--     全部表现与结算在 SGwilson.lua 的 minigame 状态里。",
    "--   ★ 它们的共同字段：do_not_locomote + disable_platform_hopping",
    "--     + skip_locomotor_facing + invalid_hold_action。",
    "--     ★★ 四字段组合 = 「站在原地、按住、动画固定、动作中不可被其他动作抢占」。",
    "--       这就是「禁止一切干扰」的表达方式。",
  ],
  "self.fn#1+327": [
    "--★ 634 行的注释标记了「小游戏动作」这一子类。",
  ],
  "self.fn#1+328": [
    "--★ LEAVE_GYM：离开健身房。mount_valid=false + instant。",
  ],
  "self.fn#1+329": [
    "--★ LIFT_GYM_SUCCEED_PERFECT：举重完美成功。四字段全开（见 634 行说明）。",
    "--   ★★ 三兄弟（LIFT_GYM_SUCCEED_PERFECT / LIFT_GYM_SUCCEED / LIFT_GYM_FAIL）",
    "--     的声明**完全相同**，只有 pre_action_cb 的铃声不同（perfect/succeed/fail）。",
    "--     ★ 又一个 T6 影子动作的变体，且是三个一组的。",
    "--   ★★ 唯一区别在 pre_action_cb —— 声音在动作**开始前**就响了，",
    "--     保证玩家不需要等 fn 执行。",
  ],
  "self.fn#1+330": [
    "--★ LIFT_GYM_SUCCEED：举重成功。四字段全开。",
  ],
  "self.fn#1+331": [
    "--★ LIFT_GYM_FAIL：举重失败。四字段全开。",
  ],
  "self.fn#1+332": [
    "--★ 639 行空行。",
  ],
  "self.fn#1+333": [
    "--★ 640 行的 `-- WX78` 标记。",
  ],
  "self.fn#1+334": [
    "--★ APPLYMODULE：安装模块。mount_valid。",
  ],
  "self.fn#1+335": [
    "--★ APPLYMODULE_FAIL：安装失败。mount_valid + instant。",
    "--   ★★ 与 APPLYMODULE(641 行) 的唯一差别是 instant=true。",
    "--     推断：失败是瞬间的（没有模块位了，立刻失败），成功是长按的。",
  ],
  "self.fn#1+336": [
    "--★ REMOVEMODULES：卸下模块。mount_valid。",
  ],
  "self.fn#1+337": [
    "--★ REMOVEMODULES_FAIL：卸下失败。mount_valid + instant。",
  ],
  "self.fn#1+338": [
    "--★ CHARGE_FROM：充电。distance=1.25 + mount_valid=false。",
  ],
  "self.fn#1+339": [
    "--★ 646 行空行。",
  ],
  "self.fn#1+340": [
    "--★ ROTATE_FENCE：旋转栅栏。rmb=true。",
  ],
  "self.fn#1+341": [
    "--★ 648 行空行。",
  ],
  "self.fn#1+342": [
    "--★ 649 行的 `-- MAXWELL` 标记。",
  ],
  "self.fn#1+343": [
    "--★ USEMAGICTOOL：使用魔杖。mount_valid + priority=1。",
  ],
  "self.fn#1+344": [
    "--★ STOPUSINGMAGICTOOL：停止使用。mount_valid + priority=2 + distance=math.huge",
    "--   + do_not_locomote。",
    "--   ★ priority=2 高于 USEMAGICTOOL(1)，保证「停止」总能赢。",
  ],
  "self.fn#1+345": [
    "--★ USESPELLBOOK：打开法术书。instant + mount_valid + priority=2。",
    "--   ★★ priority=2（而非 1）—— 与 STOPUSINGMAGICTOOL 同档，",
    "--     说明「打开界面」与「停止施法」需要互相压制。",
  ],
  "self.fn#1+346": [
    "--★ CLOSESPELLBOOK：关闭法术书。instant + mount_valid + priority=2。",
  ],
  "self.fn#1+347": [
    "--★ CAST_SPELLBOOK：施放法术。mount_valid。",
  ],
  "self.fn#1+348": [
    "--★ 655 行空行。",
  ],
  "self.fn#1+349": [
    "--★ 656 行的 `-- WOODIE` 标记。",
  ],
  "self.fn#1+350": [
    "--★ USE_WEREFORM_SKILL：使用狼形技能。rmb=true + distance=math.huge。",
  ],
  "self.fn#1+351": [
    "--★ 658 行空行。",
  ],
  "self.fn#1+352": [
    "--★ 659 行的 `-- WINONA` 标记。",
  ],
  "self.fn#1+353": [
    "--★ REMOTE_TELEPORT：远程传送。rmb=true + invalid_hold_action + mount_valid。",
  ],
  "self.fn#1+354": [
    "--★ 661 行空行。",
  ],
  "self.fn#1+355": [
    "--★ 662 行的 `-- Rifts` 标记：第二波大型更新。",
  ],
  "self.fn#1+356": [
    "--★ SCYTHE：镰刀。rmb=true + distance=1.8 + rangecheckfn=DefaultRangeCheck",
    "--   + invalid_hold_action。",
    "--   ★★ 这是四工具动作之外的第五个，特点是**同时**有 rmb、rangecheckfn",
    "--     与 invalid_hold_action。",
  ],
  "self.fn#1+357": [
    "--★ SITON：坐下。invalid_hold_action=true。",
    "--   ★★ fn（5990 行）是两阶段模式：检查 sg 处于 \"start_sitting\"。",
    "--     与 JUMPIN/CLIMB 同族（见 431 行的说明）。",
  ],
  "self.fn#1+358": [
    "--★ 665 行空行 + 666 行 `-- Rifts / Meta QoL` 标记。",
  ],
  "self.fn#1+360": [
    "--★ INCINERATE：焚烧。priority=1 + mount_valid。",
  ],
  "self.fn#1+361": [
    "--★ 668 行空行。",
  ],
  "self.fn#1+362": [
    "--★ 669 行的 `-- Rifts 4` 标记。",
  ],
  "self.fn#1+363": [
    "--★ BOTTLE：装瓶。mount_valid。",
  ],
  "self.fn#1+364": [
    "--★ 671 行空行。",
  ],
  "self.fn#1+365": [
    "--★ 672 行的 `-- Hallowed Nights 2024` 标记 —— 按**年份**分组。",
    "--   ★★ 这是全表唯一的按年份标注的段，与前面按角色分组的风格不同。",
    "--     说明到 2024 年时团队的组织方式变了（按活动排期而非按角色）。",
  ],
  "self.fn#1+366": [
    "--★ CARVEPUMPKIN：雕刻南瓜。distance=1.5。",
  ],
  "self.fn#1+367": [
    "--★ 674 行空行。",
  ],
  "self.fn#1+368": [
    "--★ 675 行的 `-- Winter's Feast 2024` 标记。",
  ],
  "self.fn#1+369": [
    "--★ DECORATESNOWMAN：装饰雪人。distance=1.5 + encumbered_valid",
    "--   + invalid_hold_action。",
    "--   ★★★ 这是本文件里**最复杂的单个动作 fn**（6087-6166 行，80 行）：",
    "--     它要处理「手上没东西 → 戴帽子 / 用物品装饰 / 叠雪球」三种模式，",
    "--     每种模式还有 CanBegin/CanStack 前置检查与黑暗中静默失败。",
    "--   ★ 而且 6117-6130 与 6146-6159 是**两段几乎相同的代码**",
    "--     （叠小雪球 vs 叠大雪球），只有取装备的来源不同。",
  ],
  "self.fn#1+370": [
    "--★ START_PUSHING：开始推。distance=1.5 + rmb=true + priority=1",
    "--   + invalid_hold_action。",
  ],
  "self.fn#1+371": [
    "--★ 678 行空行。",
  ],
  "self.fn#1+372": [
    "--★ 679 行的 `-- Meta 5` 标记。",
    "--   ★★ 「Meta」指元进度（Metabolic）。这些动作服务养成系统。",
  ],
  "self.fn#1+373": [
    "--★ APPLYELIXIR：涂灵药。mount_valid。",
  ],
  "self.fn#1+374": [
    "--★ NABBAG：抓取（网袋）。rmb=true + distance=1.8 + rangecheckfn",
    "--   + invalid_hold_action。",
    "--   ★ 与 SCYTHE(663) 同型。两个都是「远程工具 + 精确距离」。",
  ],
  "self.fn#1+375": [
    "--★ GRAVEDIG：挖坟。rmb=true + invalid_hold_action + distance=1.8。",
  ],
  "self.fn#1+376": [
    "--★ MUTATE：变异。priority=2 + invalid_hold_action + mount_valid。",
    "--   ★★ 与 WEBBER 段的 MUTATE_SPIDER(619 行 priority=2) 同名不同物。",
    "--     ★ 这是命名冲突的隐患：搜 MUTATE 会同时命中两个玩法。",
  ],
  "self.fn#1+377": [
    "--★★ WOBY_PICKUP：狗捡东西。**arrivedist = 2**（不是 distance）。",
    "--   ★★ 与 STEER_BOAT(561) 并列使用 arrivedist 的两个动作。",
    "--     语义：狗要站在 2 格外才能「够到」物品 —— 这是**宠物的拾取距离**，",
    "--     而不是玩家的手能伸多远。",
    "--   ★ fn（6245 行）用 components.container（狗的口袋）而非 inventory。",
  ],
  "self.fn#1+378": [
    "--★ WOBY_PICK：狗采摘。extra_arrive_dist=ExtraWobyForagingDist（§零 262 行，",
    "--   大型生物 +1 格）。",
    "--   ⚠ L10：6286 行的 validfn 语义存疑，详见 p8。",
  ],
  "self.fn#1+379": [
    "--★★ CONTAINER_INSTALL_ITEM：把物品装进容器。priority=3 + rmb=true",
    "--   + instant + mount_valid。",
    "--   ★ priority=3 很高：这是「整理背包」的精细操作，",
    "--     必须能压过普通的 GIVE(370 行) 与 STORE(404 行)。",
    "--   ★ 有 pre_action_cb（6331 行）：装不下时播「否定音效」。",
    "--     ★★ 这是本文件中 pre_action_cb 的**第三个用途**：立即负反馈。",
    "--       与 LIFT_GYM 的敲铃同类。",
  ],
  "self.fn#1+380": [
    "--★ MODSLINGSHOT：改装弹弓。mount_valid。",
  ],
  "self.fn#1+381": [
    "--★ STOPMODSLINGSHOT：停止改装。instant + mount_valid。",
  ],
  "self.fn#1+382": [
    "--★ DASH：冲刺。distance=math.huge + mount_valid + invalid_hold_action。",
  ],
  "self.fn#1+383": [
    "--★★ DIRECTCOURIER_MAP：地图直递快递。HIGH + ArriveAnywhere + rmb +",
    "--   instant + map_action + map_only + map_works_on_unexplored + closes_map。",
    "--   ★★ 唯一同时设置了 map_only **和** map_works_on_unexplored 的动作。",
    "--     原因是沃尔特的新技能要在**未探索**区域也能直接发快递。",
    "--   ⚠ L1：3461 行 maponly_checkvalidpos_fn 有一处运算符优先级 bug，详见 p5。",
  ],
  "self.fn#1+384": [
    "--★ WHISTLE：吹口哨召回狗。rmb=true + distance=math.huge +",
    "--   invalid_hold_action。",
  ],
  "self.fn#1+385": [
    "--★ ACTIVATE_CONTAINER：激活容器（点按钮）。priority=1 + mount_valid。",
    "--   ★ fn（2108 行）走 `act.target.cookbuttonfn` ——",
    "--     与 TRAVEL(3699) 的 travel_action_fn 同型：**实体自带回调**。",
  ],
  "self.fn#1+386": [
    "--★ 693 行空行。",
  ],
  "self.fn#1+387": [
    "--★ 694 行的 `-- Deck O' Cards` 标记。",
  ],
  "self.fn#1+388": [
    "--★ DRAW_FROM_DECK：抽牌。priority=2 + distance=1.8 + mount_valid。",
  ],
  "self.fn#1+389": [
    "--★ FLIP_DECK：翻牌堆。mount_valid。",
  ],
  "self.fn#1+390": [
    "--★ ADD_CARD_TO_DECK：加牌进牌堆。mount_valid + canforce + DefaultRangeCheck。",
    "--   ★★ 又一组 canforce + DefaultRangeCheck 组合（共 13 个，见 §五 清单）。",
  ],
  "self.fn#1+391": [
    "--★ 698 行空行。",
  ],
  "self.fn#1+392": [
    "--★ 699 行的 `-- Rifts 5` 标记。",
  ],
  "self.fn#1+393": [
    "--★★ POUNCECAPTURE：扑抓。priority=3 + distance=5 + canforce",
    "--   + rangecheckfn=MakeRangeCheckFn(7)。",
    "--   ★★ 唯一在 ACTIONS 表里**直接调用 MakeRangeCheckFn** 的地方。",
    "--     distance=5（要走到 5 格内）但允许 rangecheck 到 7 格 ——",
    "--     ★★ 这就是「走到 5 格停下，但若在 5-7 格之间仍可执行」的组合。",
    "--       即「允许的判定范围 ⊇ 允许的移动范围」，多出来的 2 格是余量，",
    "--       避免玩家「明明看见扑到了却没反应」。",
    "--   ★ 703 行 DIVEGRAB 用完全相同的参数组合 —— 成对设计。",
  ],

  // ══════════════════════════════════════════════════════════════
  // §五 编号与网络映射（743-764）
  // ══════════════════════════════════════════════════════════════
  "self.fn#1+394": [
    "--★ 701 行空行。",
  ],
  "self.fn#1+395": [
    "--★ 702 行的 `-- rifts5.1` 标记 —— 小版本号。",
  ],
  "self.fn#1+396": [
    "--★★ DIVEGRAB：潜水抓取。声明与 700 行 POUNCECAPTURE **逐字相同**。",
    "--   ★★ 两个不同玩法用了完全相同的动作规格 ——",
    "--     因为它们的技术需求确实一样（远程扑击）。",
    "--   ★ 这再次印证「Action 是数据」：玩法差异全在 fn 里。",
  ],
  "self.fn#1+397": [
    "--★ STARTELECTRICLINK：开始电线连接。priority=2 + invalid_hold_action。",
  ],
  "self.fn#1+398": [
    "--★ ENDELECTRICLINK：结束电线连接。priority=1 + invalid_hold_action。",
    "--   ★★ priority 比 START 低一档（2 vs 1）。",
    "--     推断：连接中时，结束应该比「开始新连接」更容易触发。",
  ],
  "self.fn#1+399": [
    "--★ REMOVELUNARBUILDUP：清除月雹堆积。priority=3 + invalid_hold_action。",
  ],
  "self.fn#1+400": [
    "--★ 707 行空行。",
  ],
  "self.fn#1+401": [
    "--★ 708 行的 `-- Winter 2025` 标记。",
  ],
  "self.fn#1+402": [
    "--★ SOAKIN：泡澡。invalid_hold_action=true。",
  ],
  "self.fn#1+403": [
    "--★ TRANSFER_CRITTER：转移宠物。invalid_hold_action=true。",
  ],
  "self.fn#1+404": [
    "--★ 711 行空行。",
  ],
  "self.fn#1+405": [
    "--★ 712 行的 `-- Year of the Clockwork Knight` 标记。",
  ],
  "self.fn#1+406": [
    "--★★ JOUST：马上决斗。rmb=true + distance=math.huge + invalid_hold_action",
    "--   + silent_generic_fail。",
    "--   ★★ 唯一使用 silent_generic_fail 的动作（§一 323 行）。",
    "--     决斗失败会频繁发生，每次都播完整提示太吵。",
    "--   ★ fn（6663 行）最后 `return joustuser:CanJoust()` ——",
    "--     ★★ 注意：这里返回的是「能不能」而不是「做了没有」。",
    "--       是个语义上的小瑕疵：调用方无法从返回值知道是否真的开始了决斗。",
  ],
  "self.fn#1+407": [
    "--★ 714 行空行。",
  ],
  "self.fn#1+408": [
    "--★ 715 行的 `-- Meta 6` 标记。",
  ],
  "self.fn#1+409": [
    "--★ STARTREMOVINGMODULE：开始拆模块。mount_valid + invalid_hold_action。",
  ],
  "self.fn#1+410": [
    "--★★ REMOVEMODULE：拆模块。mount_valid + invalid_hold_action + **instant**。",
    "--   ★★ 行尾注释是关键：「The action we use when we're already in the UI.」",
    "--     ★★★ 「已经进入界面」时还需要一个动作？这是一个很反直觉的设计。",
    "--     推断：拆模块流程是「按住 STARTREMOVINGMODULE → 进入界面 →",
    "--       在界面里逐个点 REMOVEMODULE」。后者是 instant 的。",
    "--     ★ 两个动作共用 upgrademoduleowner 组件的 StartInspecting/StopInspecting。",
  ],
  "self.fn#1+411": [
    "--★ STOPREMOVINGMODULE：停止拆模块。mount_valid + invalid_hold_action。",
  ],
  "self.fn#1+412": [
    "--★ MAPSCOUT_MAP：地图侦察。instant + mount_valid + map_only",
    "--   + map_works_on_unexplored + map_works_on_impassable。",
  ],
  "self.fn#1+413": [
    "--★ MAPSCOUT_MAP_TOOFAR：目标太远。instant + mount_valid + map_only",
    "--   + map_works_on_unexplored + map_works_on_impassable。",
    "--   ★★ 与 719 行声明**完全相同**，但 6820 行：",
    "--     `ACTIONS.MAPSCOUT_MAP_TOOFAR.maponly_checkvalidpos_fn = ACTIONS.MAPSCOUT_MAP.maponly_checkvalidpos_fn`",
    "--     ★ 复用同一个校验函数，但 stroverridefn 与 pre_action_cb 完全不同 ——",
    "--       太远时播「否定音效」（6826 行）而 fn 只 return true。",
    "--   ★★★ 「失败」被建模成了一个动作，而不是让 fn 返回 false。",
    "--     这是 T6 影子动作的第三种用途：**表达「够不着」这个状态**。",
  ],
  "self.fn#1+414": [
    "--★ MAPSCOUTSELECT_MAP：选择侦察目标。instant + mount_valid + rmb=true",
    "--   + map_only + map_works_on_unexplored + map_works_on_impassable。",
  ],
  "self.fn#1+415": [
    "--★ STARTMAPDELIVER：开始地图投递。rmb=true。",
  ],
  "self.fn#1+416": [
    "--★ MAPDELIVER_MAP：地图投递。map_only + closes_map。",
    "--   ★★ 全表唯一不带 mount_valid 的 map_only 动作。",
  ],
  "self.fn#1+417": [
    "--★ SWAPBODIES_MAP：地图换身。ArriveAnywhere + rmb=true + map_only",
    "--   + map_works_on_unexplored + closes_map。",
  ],
  "self.fn#1+418": [
    "--★ TOGGLEWXSCREECH：切换尖啸。priority=1 + invalid_hold_action。",
  ],
  "self.fn#1+419": [
    "--★ TOGGLEWXSHIELDING：切换护盾。priority=0 + invalid_hold_action。",
    "--   ★★ priority 不对称（1 vs 0）。SCREECH 是「主动释放」，",
    "--     SHIELDING 是「被动开关」。",
  ],
  "self.fn#1+420": [
    "--★ 727 行空行 + 728 行注释解释 EQUIPONBODY 的存在理由。",
  ],
  "self.fn#1+421": [
    "--★★ 728 行保留的英文注释说明了 EQUIPONBODY 的存在理由：",
    "--   「一个给**附身的身体**装备物品的专属动作，但仍能往它的背包里放东西。」",
    "--   ★★ 这解释了它与 GIVEALLTOPLAYER(372) 的分工：",
    "--     GIVE 系列给**活着的玩家**（inventory 已打开），",
    "--     EQUIPONBODY 给**被附身的身体**（可直接操作其 inventory）。",
    "--   ★★ 换句话说：GIVE 的检查 `IsOpenedBy(act.target) or HasTag(\"playerghost\")`",
    "--     （2348 行）在附身场景下不成立，于是需要一个新动作。",
  ],
  "self.fn#1+422": [
    "--★★ EQUIPONBODY：给被附身的身体装备。priority=3 + canforce",
    "--   + rangecheckfn=DefaultRangeCheck。",
    "--   ★ priority=3（与 GIVE 同级）：两者都是「给别人东西」，不该互相压制。",
  ],
  "self.fn#1+423": [
    "--★ 730 行空行。",
  ],
  "self.fn#1+424": [
    "--★ 731 行的 `-- Rifts 7` 标记。",
  ],
  "self.fn#1+425": [
    "--★ CLIMB：攀爬。ghost_valid + encumbered_valid。",
    "--   ★ 与 JUMPIN(431) 同族的两阶段模式（见 431 行说明）。",
  ],
  "self.fn#1+426": [
    "--★ STARTVAULTORBTELEPORT：开始金库球传送。rmb=true。",
  ],
  "self.fn#1+427": [
    "--★ VAULTORBTELEPORT_MAP：金库球地图传送。ArriveAnywhere + rmb=true",
    "--   + map_only + map_works_on_unexplored + closes_map。",
  ],
  "self.fn#1+428": [
    "--★ 735 行空行。",
  ],
  "self.fn#1+429": [
    "--★ 736 行的 `-- Crow Carnival 2026` 标记 —— 最新内容。",
    "--   ★★ 全表最后 4 个动作。可以看到新增动作的典型形状：",
    "--     声明极简（1-3 个字段），逻辑全在 fn 里。",
  ],
  "self.fn#1+430": [
    "--★ GOLF_START_AIMING：高尔夫瞄准。rmb=true + invalid_hold_action。",
  ],
  "self.fn#1+431": [
    "--★ GOLF_STOP_AIMING：停止瞄准。instant=true。",
  ],
  "self.fn#1+432": [
    "--★ GOLF_START_CHARGING：高尔夫蓄力。distance=9999 + do_not_locomote",
    "--   + invalid_hold_action。",
    "--   ★ 第三个使用 (9999 + do_not_locomote) 组合的动作（562/596/739）。",
  ],
  "self.fn#1+433": [
    "--★★ TERRAFORM_REMOVE：移除地形（高尔夫）。CheckInsideGolfGame + rmb=true",
    "--   + invalid_hold_action + **keepgroundactionhint=true**。",
    "--   ★★ 全表唯一使用 keepgroundactionhint（350 行）的动作。",
    "--     因为高尔夫的球位标记是**无名临时实体**，",
    "--     若不留住地面动作提示，玩家松手后不知道还能点什么。",
  ],
  "self.fn#1+434": [
    "--★ 741 行 ACTIONS 表结束。",
    "--★★ 统计（可核对）：",
    "--   · 动作原型总数 ≈ 240 条",
    "--   · 带 priority 的 ≈ 130 条（其余用默认 0）",
    "--   · 用 HIGH_ACTION_PRIORITY 的 = 10 条（见 353 行清单）",
    "--   · 带 canforce 的 = 13 条：PICK(366) GIVE(370) GIVETOPLAYER(371)",
    "--     GIVEALLTOPLAYER(372) FEEDPLAYER(373) NET(413) HAUNT(462)",
    "--     SLAUGHTER(539) POUNCECAPTURE(700) DIVEGRAB(703) EQUIPONBODY(729)",
    "--     ADD_CARD_TO_DECK(697)",
    "--   · 有 customarrivecheck 的 = 10 条",
    "--   · 有 stroverridefn 的 ≈ 45 条",
    "--   · 有 pre_action_cb 的 = 10 条",
    "--   · 有 actionmeter 的 = 1 条（REVIVE_CORPSE）",
    "--   · distance = math.huge 的 = 6 条",
    "--   · distance = 9999 的 = 3 条（562/596/739）",
    "--   · _FAIL 影子动作 = 8 条",
    "--★ 注意：ACTIONS 表里**只有声明**，一个 fn 都没有。",
    "--   所有实现都在 743 行之后。这是刻意的分层。",
  ],

  // ══════════════════════════════════════════════════════════════
  // §五 编号映射
  // ══════════════════════════════════════════════════════════════
  "self.fn#1+436": [
    "--★★★【ACTIONS_BY_ACTION_CODE —— 字符串 id 到整数 code 的双向映射】",
    "--",
    "--★★ 为什么需要它？联机时不可能传字符串。",
    "--   客户端点一下按钮 → SendRPCToServer(RPC.ActionButton, actioncode, ...)",
    "--   （playercontroller.lua:2356）→ 服务端 ACTIONS_BY_ACTION_CODE[code] 还原。",
    "--   ★ 这就是「协议里的一切枚举都用整数」的标准做法。",
    "--",
    "--★★★⚠⚠ 最重要的隐患：code 由**遍历顺序**决定，而遍历用的是",
    "--   `orderedPairs`（745 行）—— 按字母序！",
    "--   ★★ 后果：任何在 ACTIONS 表里**插入新动作**的改动，",
    "--     都可能让后面所有动作的 code 全部偏移。",
    "--   ★ 而 code 已经写进了玩家的存档之外的世界状态（正在进行的动作），",
    "--     也被写进了某些模组的硬编码值。",
    "--   ★★★ 因此：**动作 id 的字母序是这个协议的一部分**。",
    "--     重命名一个动作等于破坏协议。",
    "--   ★ 模组用独立的 MOD_ACTIONS_BY_ACTION_CODE（754 行）规避了这一点，",
    "--     因为模组的 code 从 1 开始单独计数（modutil.lua:466）。",
    "--   ★ 这是本文件最值得记住的隐式契约，代码里没有任何注释说明。",
  ],
  "self.fn#1+438": [
    "--★ orderedPairs 保证遍历顺序 = id 的字典序。",
    "--   ★★ 这一点在 743 行的注释里**没有**被点明，是隐含契约。",
    "--   ★ 参见 util.lua 的 orderedPairs 定义。",
  ],
  "self.fn#1+440": [
    "--★★ v.str = STRINGS.ACTIONS[k] or \"ACTION\"",
    "--   ★★ 兜底值 \"ACTION\"（而不是报错或空串）的理由：",
    "--     新加的动作如果忘了在 STRINGS 里定义，UI 会显示英文 \"ACTION\"，",
    "--     这比崩溃或显示 nil 更容易被语言包维护者发现。",
    "--   ★★ 这是「把缺失暴露出来但不致命」的好设计。",
  ],
  "self.fn#1+441": [
    "--★ v.id = k —— 把字符串 id 回写到动作对象上。",
    "--   ★★★ 这个回写极其重要，因为下游全部靠它：",
    "--     · entityscript.lua:1799 CanDoAction 检查 `self:HasTag(action.id..\"_tool\")`",
    "--     · componentactions.lua:3065 检查 `inst:HasTag(action.id..\"_workable\")`",
    "--     · bufferedaction.lua:65 用 action.id 查 STRINGS",
    "--   ★★★ 于是「加一个新动作」要让它可用，需要：",
    "--     ① ACTIONS 表声明 ② STRINGS 定义 ③ 目标 prefab 加对应标签。",
    "--     三处缺一不可。这是最容易漏的一处。",
  ],
  "self.fn#1+443": [
    "--★ v.code = #ACTION_IDS —— 用当前长度当 code，即从 1 开始连续编号。",
  ],
  "self.fn#1+444": [
    "--★ 反向表。注意它是 code → action 对象，**不是** id → action。",
    "--   ★ 因为 id → action 直接用 ACTIONS[id] 就行，不需要额外表。",
  ],
  "self.fn#1+447": [
    "--★ MOD_ACTIONS_BY_ACTION_CODE：模组动作的独立编号空间。",
    "--   ★★ 结构是 [mod_name][code] → action，两层索引。",
    "--   ★ 由 modutil.lua:468-470 在 AddAction 中填充。",
  ],
  "self.fn#1+449": [
    "--★ ACTION_MOD_IDS：模组的动作 id 列表，注释说明它在 modutil 中被填。",
    "--   ★ 与 MOD_ACTIONS_BY_ACTION_CODE 不同：这里存 id（供遍历），",
    "--     那里存 action 对象（供 O(1) 查找）。",
  ],
  "IsItemInReadOnlyContainer#1": [
    "--★ IsItemInReadOnlyContainer —— 本文件里**唯一**的普通局部函数（用途辅助）。",
    "--   ★★ 它定义在这里但全文没有调用点 —— 它是被其它文件 require 走的",
    "--     （作为 actions.lua 的 upvalue 之一，通过 require(\"actions\") 拿到）。",
    "--   ★ 注意它被声明为 `local` —— 也就是说它**无法**被外部访问。",
    "--   ⚠疑似缺陷 L13：定义了一个 local 函数却从不使用，且不可被外部访问。",
    "--     最可能的解释是作者忘了删，或者原本打算 export。",
  ],
  "IsItemInReadOnlyContainer#1+6": [
    "--★ 764 行是 IsItemInReadOnlyContainer 的结束（763 行 return）。",
    "--★ 到此「动作声明与编号」部分结束（743-765 行）。",
    "--  从 766 行开始是 6300 行的动作实现。",
  ],
};

export const AFTER = {};
