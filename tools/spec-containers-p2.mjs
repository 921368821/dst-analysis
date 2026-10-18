/**
 * spec-containers-p2.mjs —— containers.lua 第 392-900 行
 * portablespicer / bundle_container / construction_container / 蘑菇灯 / 灯柱 / 寄居蟹屋 / 冬季树 / sisturn / 供奉锅
 */

export const BEFORE = {
  392: ["-- ── portablespicer（便携香料锅）区块 ──"],
  396: [
    "-- 便携香料锅：2 格，**每格内容物不同**（slot 1 = 食材，slot 2 = 香料）。",
    "--   ★ 这就是 usespecificslotsforitems = true 的意义：**槽位有语义**，",
    "--     物品必须进指定的那一格，由 itemtestfn 里的 slot 参数强制（第 425 行）。",
  ],
  405: [
    "-- slotbg 逐槽不同：cook_slot_food.tex / cook_slot_spice.tex ——",
    "--   ★ 底纹在**告诉玩家「这一格放什么」**，这是槽位语义最直观的 UI 表达。",
  ],
  421: [
    "-- usespecificslotsforitems = true → 落点在 components/container.lua:298",
    "--   GetSpecificSlotForItem：逐槽试 itemtestfn(item, i)，第一个通过的就是目标槽。",
    "--   ★ 关键：GiveItem 第 451 行 `slot = slot or self:GetSpecificSlotForItem(item)`，",
    "--     所以**未指定槽位时也会走专用槽分配**，不会随便找个空位。",
  ],
  425: [
    "-- 【★ itemtestfn 范例 E：按槽位分派的三分支】全文件最清晰的一个「槽位语义」样板。",
    "--   三个分支分别对应：slot==1（食材槽）、slot==2（香料槽）、slot==nil（不指定槽位时）。",
    "--   ★ slot == nil 分支是必需的：因为拖拽悬停判定时槽位可能未确定，",
    "--     若不写 nil 分支，拖拽时会被判为「不能放」而卡住。",
    "--   ⚠ 注意每个分支都写了 `and not spicedfood` / `HasTag(\"spice\")`：",
    "--     规则是互斥的，香料不能当食材、已调味的菜不能再当食材——",
    "--     这类「状态互斥」是容器筛选里最难表达的一类规则。",
  ],
  426: [
    "-- ★ 首行 `item.prefab ~= \"wetgoop\"`：一种具体的「烂糊糊」不可入锅。",
    "--   ⚠ 这是**硬编码 prefab 名**的白名单，与第 1732 行 seedpouch 用",
    "--     `string.match(item.prefab, \"_seeds\")` 做前缀/后缀匹配相比，",
    "--     健壮性差得多（新物品必须改这里）。这类硬编码在本文件里约有 20 处。",
  ],
  429: [
    "-- slot == nil 的兜底分支：两种都接受，等价于「不限槽」。",
  ],
  446: ["-- ── bundle_container（包扎容器）区块 ──"],
  450: [
    "-- 绷带包：2x2 = 4 格，WRAPBUNDLE 按钮。",
    "--   ★ type = \"cooker\" 但它根本不烹饪——再次说明 type 只是 UI 方位标记，无语义。",
  ],
  474: [
    "-- 【itemtestfn 范例 F：多标签黑名单】HasAnyTag 一次性排除四类标签。",
    "--   irreplaceable（剧情物）、_container（容器本身，防止容器套容器）、",
    "--   bundle（成品绷带）、nobundling（不可包扎物）。",
    "--   ★ 「排除容器本身」是一条通用规则——几乎所有语义容器都会写它，",
    "--     防止玩家把背包塞进背包导致溢出链递归。",
  ],
  486: [
    "-- bundle 的 validfn 与前几个不同：要求「非空 **且** 不是只读容器」。",
    "--   IsReadOnlyContainer（container_replica.lua:336）读的是 netvar readonlycontainer，",
    "--   ⇒ 只读容器（如展示柜）里明明有东西，按钮也不能点。",
  ],
  490: ["-- ── construction_container（建造容器）区块 ──"],
  494: [
    "-- 【★ 建造容器：全文件最特殊的一个】它的槽位内容**由玩家角色决定**，不由容器决定。",
    "--   判定逻辑在 itemtestfn（第 523 行）：问「你是谁？你手上的建造蓝图要什么材料？」",
    "--   ★ 所以这个容器不需要知道建造配方——它只是把角色组件当数据源。",
  ],
  501: [
    "-- pos.x = 300：建造 UI 在屏幕**最右侧**（远离中央的角色与准星）。",
  ],
  508: [
    "-- ★ 原注释保留（V2C）：这是全文件**唯一一段解释音效归属**的注释，务必读：",
    "--   「override the default widget sound, which is heard only by the client",
    "--    -most containers disable the client sfx via skipopensnd/skipclosesnd,",
    "--     and play it in world space through the prefab instead.」",
    "--   ⇒ 翻译成本项目的话：",
    "--     · 大部分容器走**世界空间音效**（prefab 自己播放，所有人听见）；",
    "--     · 于是要关掉客户端 HUD 音效（skipopensnd/skipclosesnd），",
    "--       否则会「一个人听两遍」（世界一遍 + HUD 一遍，只有本人听见 HUD 那遍）；",
    "--     · 但建造容器想用**专属 HUD 音效**，所以反过来：覆盖 opensound/closesound。",
    "--   消费点见 components/container.lua:645 `self.widget.opensound`。",
  ],
  515: [
    "-- usespecificslotsforitems = true：建造材料**必须按序进指定槽**（第 4 格放木材…）。",
    "--   ★ 目标槽由 itemtestfn 第 528 行 `GetIngredientForSlot(slot)` 算出——",
    "--     它把「当前槽号」翻译成「这个槽该放什么 prefab」，是双向映射。",
  ],
  519: [
    "-- for x = -1.5 to 1.5 step 1 → 4 个槽，间距 110（比常规 75/80 宽，为了放长材料图标）。",
  ],
  523: [
    "-- 【★ itemtestfn 范例 G：向「角色」要答案】本文件最巧妙的一个 itemtestfn。",
    "--   它不查物品自身，而是查 container.inst 的**父实体**（也就是玩家）：",
    "--     doer = container.inst.entity:GetParent() —— 容器的父实体就是拿它的人。",
    "--   ★ 为什么这样？因为建造蓝图（constructionbuilderuidata）挂在玩家身上，",
    "--     而容器是个「被玩家拖着走的临时 UI 实体」（portablecontainer 语义）。",
    "--   ⇒ 设计启示：itemtestfn 不只是「物品过滤器」，它可以是一段**任意查询**。",
    "--     这解释了为什么框架从不试图给 itemtestfn 限定职责边界。",
  ],
  525: [
    "-- ★ entity:GetParent() 返回承载该实体的父（玩家背包或手上的物理实体）。",
    "--   ⚠ 潜在脆弱点：若容器不在任何人身上（刚放地上），parent 为 nil → 判定 false，",
    "--     即「地面上的建造容器不接受任何东西」。第 526 行的 doer ~= nil 正是守这个。",
  ],
  526: [
    "-- 三重与：① 有人拿着 ② 拿的人有建造 UI 数据 ③ 该槽要求的材料正好是这个 prefab。",
    "--   ★ 第 528 行的 == item.prefab 是**精确 prefab 匹配**，比标签判定严格得多。",
    "--     建造配方要求 2 根木头就是 2 根木头，不能用「等价物」。",
  ],
  539: [
    "-- 建造的 validfn 只需「非空」：材料齐不齐由 builder 组件自己判，容器不管。",
  ],
  543: [
    "-- ★ deepcopy + 改一个字段 = 派生新蓝图。",
    "--   这是本文件最重要的复用手法，后面 20+ 处派生（saltbox/merm_armory/winter_tree 等）都用它。",
    "--   ⚠ 代价：deepcopy 是**值拷贝**，widget.slotpos 里的 Vector3 会被重新构造，",
    "--     所以改一个槽位坐标不影响原版（这正是我们想要的）。",
  ],
  546: [
    "-- 第三个建造派生：REBUILD（重建）动作，与 REPAIR 共用同一套 UI。",
  ],
  549: ["-- ── enable_shadow_rift_construction_container（月影裂隙献祭容器）区块 ──"],
  553: [
    "-- 第四次派生：裂隙献祭。它比普通建造容器多一步——**要弹确认框**。",
  ],
  555: [
    "-- 槽位缩到 1 个：献祭只需要一件东西。★ 用整体替换而非逐项修改，更清晰。",
  ],
  575: [
    "-- 【★ IsConstructionSiteComplete：本地函数，服务端也会跑】",
    "--   判定「容器里的材料 + 建造站已有的材料」是否已够建成。",
    "--   ⚠ 注意第 576 行取的是 inst.replica.container —— 这个函数**只在客户端跑**",
    "--     （第 623 行的 overrideactionfn 有 `doer.HUD ~= nil` 守卫），",
    "--     因为它的目的是「决定要不要弹确认框」，纯 UI 决策。",
  ],
  578: [
    "-- 容器为空直接返回 false：没材料不可能建成。",
  ],
  579: [
    "-- ★ 用 and/or 链实现「三元」：doer 没组件 → nil。",
    "--   Lua 没有 ?: 运算符，and/or 是标准替代（注意 or 后面必须是 nil/false）。",
    "--   ⚠ 这写法有陷阱：若 GetConstructionSite() 返回 false 也会落到 nil，但本例安全。",
  ],
  586: [
    "-- ★★ 这行揭示了一个**双计数**设计：new_count（容器里的） + old_count（站点已有的）。",
    "--   → 说明建造材料可以「一半放容器、一半已在建造站」，两者相加才算数。",
    "--   ⚠ 疑似缺陷：`local complete, new_count = container:Has(...)` 的 complete 未被使用。",
    "--     推理依据：Lua 的 `a, b = f()` 只取前两个返回值，而此处 complete 之后再没出现；",
    "--     作者真正需要的只有 new_count（因为要和 old_count 相加）。",
    "--     这不是逻辑错误（Lua 允许未使用的局部量），但属于死变量。仅标注，不改代码。",
  ],
  588: [
    "-- ★ 加法比较：这就是「容器 + 站点」的合并计数。",
    "--   ⚠ 变量名 new_count 实为「容器内该 prefab 的总数」，与 count 无冲突但易误解。",
  ],
  592: [
    "-- ingredients 为 nil（建造站没返回材料表）→ 保守返回 false。",
  ],
  603: [
    "-- 【EnableRiftsPopUpGoBack】取消回调：只弹回上一层。",
    "--   ★ TheFrontEnd:PopScreen() 是全局前端栈操作——这是**客户端 UI 栈**的通用操作，",
    "--     与容器系统无关，只是搭了个便车。",
  ],
  607: [
    "-- 【EnableRiftsDoAct】与第 331 行同构的服务端/客户端双端模板。",
  ],
  615: [
    "-- 【★ fn 与 overrideactionfn 的分工】一个「默认动作」被拆成两个函数：",
    "--   · overrideactionfn —— 先问「要不要弹框」；",
    "--   · fn —— 没有弹框时，直接执行。",
    "--   ★ 这样拆分的好处：普通建造容器复用 fn 模板，裂隙容器只在前面插一个拦截层。",
  ],
  616: [
    "-- ★ 若 overrideactionfn 返回 true（已弹框并处理），fn 就不再执行。",
  ],
  622: [
    "-- 【★ overrideactionfn：UI 拦截层】这是本文件里唯一「非纯数据」的逻辑块之一。",
    "--   它做三件事：判断是否材料齐全 → 弹 RiftConfirmScreen → 返回 true 表示「已处理」。",
    "--   ★ 返回布尔值作为「是否已消费事件」的信号，是回调式设计的常见约定。",
  ],
  623: [
    "-- 两个前置：doer 存在（有玩家）、且有 HUD（**说明必须是有 UI 的人类玩家**）。",
    "--   ⇒ NPC（无 HUD）走不到这里，会落到第 618 行的直接执行路径。",
  ],
  625: [
    "-- 局部函数即闭包：捕获 doer，弹框的 OK 回调里执行动作后关掉弹窗。",
    "--   ★ 顺序很关键：**先执行再 Pop**，因为执行可能触发新的界面。",
  ],
  631: [
    "-- RiftConfirmScreen(title, body, buttons) —— 文件头 require 的那个 UI 模块。",
    "--   ★ 这再次证明本文件不是纯数据表：它直接 new 了一个 Screen。",
  ],
  644: [
    "-- ⚠ 疑似缺陷：params.enable_lunar_rift_construction_container = params.enable_shadow_...",
    "--   引用赋值（原注释说「lunar is same as shadow, just different strings specified in prefab」）。",
    "--   推理依据：原注释解释了「只有字符串不同」，即差异由 prefab 的 POPUP_STRINGS 提供——",
    "--     这是**有意的共享**，属合理设计。仅记录，便于区分于第 43/137 行的无解释共享。",
  ],
  646: ["-- ── mushroom_light（蘑菇灯）区块 ──"],
  650: ["-- 蘑菇灯：4 竖格，只放「灯燃料」与「灯芯」。"],
  670: [
    "-- 【itemtestfn 范例 H：双标签白名单 + burnt 守卫】与第 374 行 cookpot 同型。",
    "--   lightbattery（灯油等燃料）/ lightcontainer（灯芯等）；burnt 后全拒。",
  ],
  674: ["-- ── mushroom_light2 区块 ──"],
  678: [
    "-- deepcopy 后**整体覆盖 itemtestfn**：蘑菇灯 2 额外接受「孢子」。",
    "--   ★ 覆盖整个函数而不是改函数体，是派生式配置最干净的做法。",
  ],
  680: [
    "-- 三个标签：lightbattery / spore / lightcontainer。",
    "--   ★ 注意 spore 这个标签是 wormwood（蕨类学家）机制的通用接口。",
  ],
  684: ["-- ── yots_lantern_post（永夜灯柱）区块 ──"],
  688: [
    "-- ★ 把三个标签提成局部常量 LIGHT_TAGS，供第 703 行与第 713 行复用。",
    "--   这是全文件里少见的「提成常量」写法——其余地方都是重复字符串字面量。",
  ],
  702: [
    "-- 第 671 行的复用版：把 FOODTYPE 风格的枚举换成 LIGHT_TAGS 常量。",
    "--   ★ 对比第 681 行 mushroom_light2 用的是内联三标签表——**风格不统一**，",
    "--     两个几乎相同的 itemtestfn，一个提常量一个内联。仅记录风格问题。",
  ],
  720: ["-- ── hermithouse2（寄居蟹屋 2）区块 ──"],
  724: [
    "-- 寄居蟹屋：2x2 = 4 格，只放「装饰品」（hermithouse_ornament）。",
    "--   ★ 这类「装饰槽」容器让玩家把收集品摆在房里——纯装饰玩法，无功能影响。",
  ],
  745: [
    "-- 又一张 slotbg 常量，4 格共用同一张贴图。",
  ],
  751: [
    "-- 单标签白名单（与缝纫机第 327 行同型），是最简形态。",
  ],
  755: ["-- ── winter_tree（冬季树）区块 ──"],
  759: [
    "-- 冬季树：8 格（2x4），放节日装饰。",
    "--   ★ 与背包（8 格）同一个 slotpos 公式与同一张美术 ui_backpack_2x4，",
    "--     说明「8 格 2x4 布局」在本文件里被复用了很多次。",
  ],
  778: [
    "-- 【★ 双标签白名单】winter_ornament 或 hermithouse_ornament，外加 burnt 守卫。",
    "--   ★ 注意：hermithouse_ornament 同时被第 751 行的寄居蟹屋接受——",
    "--     **同一个物品可以被两个不同容器接受**，这在本系统里完全合法。",
    "--     ⇒ 推论：itemtestfn 是「每个容器各自为政」的闭包，没有任何全局物品-容器映射表。",
  ],
  782: [
    "-- ⚠ 疑似缺陷：连续三行引用赋值 winter_twiggytree / winter_deciduoustree /",
    "--   winter_palmconetree = params.winter_tree，未用 deepcopy。",
    "--   推理依据：本文件派生蓝图时 **deepcopy 是主流写法**（第 116/128/678/944/950/1047/2297 行等），",
    "--     这里三处连用赋值显得是「图省事」。当前无后续修改故无害；",
    "--     但模组若改 params.winter_tree.widget.* 会同时影响三种树。",
    "--     与第 43/137/168 行同属一类技术债。**不改代码，仅标注**。",
  ],
  786: ["-- ── sisturn（露西的花槽）区块 ──"],
  790: [
    "-- 花槽：2x2 = 4 格。openlimit = 1（第 815 行）：**同一人同时只能开一个花槽**。",
    "--   ★ 这是「专用小容器设 openlimit」的典型：避免误开一堆花槽把屏幕塞满。",
  ],
  818: [
    "-- 【★ itemtestfn 范例 I：依赖「打开者」的动态规则】全文件最复杂的一个 itemtestfn。",
    "--   它先确定「谁开着这个容器」（owner），再根据 owner 的**技能树解锁情况**",
    "--   决定接受哪些物品。⇒ 判定输入不只是 (item, slot)，还有「世界状态 + 玩家进度」。",
    "--   ★ 双端分支与第 199 行同理：服务端用 GetOpeners()[1]，客户端用 IsOpenedBy(ThePlayer)。",
  ],
  819: [
    "-- 服务端取「第一个打开者」：多人同开时以先开的人为准。",
  ],
  821: [
    "-- ⚠ 潜在缺陷：GetOpeners()[1] 在 openlist 无序（pairs）的情况下**不保证是最近打开者**。",
    "--   推理依据：openlist 是以实体为键的哈希表，pairs 遍历顺序未定义。",
    "--   实际影响很小（两人同开一花槽的技能解锁状态通常相同），但严格说是未定义行为。",
    "--   ★ 对照第 1523 行 slingshot 的 itemtestfn 用了**完全相同**的写法，",
    "--     说明这是「通用模式」而非笔误。仅标注，不改代码。",
  ],
  826: [
    "-- ★ 原注释保留：「NOTE: can have no owner when loading」。",
    "--   推理：存档加载期间不会有任何玩家 openlist，owner 为 nil。",
    "--   此时**必须放行**，否则读档后玩家从花槽里取不出花瓣（物品被锁死）。",
    "--   ⇒ 「加载期例外」是容器筛选的第三类工程性开口（前两类见第 200/202 行）。",
  ],
  827: [
    "-- 三选一放行：无 owner（加载中）**或** 拥有 wendy_sisturn_3 技能 → 接受三种花瓣；",
    "--   否则只接受普通 petals。",
    "--   ★ skilltreeupdater:IsActivated 是「技能树节点是否已解锁」的统一查询接口。",
  ],
  831: [
    "-- 未解锁时：只接受最基础的 petals。",
  ],
  834: ["-- ── offering pot（供奉锅）区块 ──"],
  838: [
    "-- 供奉锅：2x2 = 4 格，**只放海藻（kelp）**。",
    "--   ★ 这是「单一物品容器」的极端：整个 4 格容器只接受一个 prefab。",
  ],
  865: [
    "-- 【itemtestfn 范例 J：prefab 精确匹配】`item.prefab == \"kelp\"`。",
    "--   ⚠ 与 HasTag 相比，预fab 精确匹配不容错：把「海藻」换成任何带 forofferingpot 标签的物品都不行。",
    "--     但反过来它也最严格——不会出现「顺带收进奇怪东西」的投诉。",
    "--   ★ 两种风格在本文件里并存，按「语义有多确定」选：",
    "--     确定（只有一个 prefab 合法）→ 精确匹配；不确定（一类物品）→ 标签。",
  ],
  869: ["-- ── offering pot II（供奉锅 II）区块 ──"],
  873: [
    "-- 二代供奉锅：3x2 = 6 格（从 4 格扩到 6 格），美术 ui_chest_3x2。",
    "--   ★ 注意它**没有 itemtestfn 字段**，而是在第 904 行单独赋值——",
    "--     两种写法等价，但「先建表后补函数」在这里更清晰。",
  ],
  904: [
    "-- ★ 函数指针共享：二代锅复用一代的判定（同第 259 行的模式）。",
    "--   正确写法，与第 543 行的 deepcopy 形成对照：",
    "--     · 表结构要改 → deepcopy 再改字段；",
    "--     · 只共享判定逻辑 → 直接赋函数指针。",
  ],
};

export const AFTER = {};