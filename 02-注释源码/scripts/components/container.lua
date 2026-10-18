--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/container.lua（1651 行）
-- 模块：容器系统 / 容器组件（Container，服务端权威）
--
-- ★★★ 本文件是容器系统的**全部运行时逻辑**。它与 containers.lua 的关系
--   是「蓝图 → 实现」：
--     containers.lua              components/container.lua（本文件）
--     ─────────────────          ──────────────────────────────────────
--     params.<prefab> 蓝图  ──→   WidgetSetup 读蓝图、灌进 self
--     itemtestfn 定义   ──→   CanTakeItemInSlot 第 295 行调用它
--     openlimit        ──→   CanOpen 第 736 行判定它
--     type             ──→   Open 第 625 行读它做「同类互斥」
--     MAXITEMSLOTS     ──→   （不参与；只有 container_classified 用）
--   ⇒ **蓝图里的每一个字段都必须在本文件里找到消费点**，
--     否则它就是死配置。本文件顶部第 73-84 行 widgetprops 列表
--     正是「本文件承认的蓝图字段白名单」。
--
-- ★★ 两层职责边界（本任务最需要回答的问题），结论四条：
--   ① **状态所有权**：本文件（服务端组件）是唯一权威。self.slots 是
--      稀疏表（稀疏、不可信，见下）。客户端永远不写 self.slots。
--   ② **UI 与显示**：本文件只在两处碰 UI —— components/container.lua:637
--      `doer.HUD:OpenContainer(...)` 与 :692 `doer.HUD:CloseContainer(...)`，
--      以及 :653 RegisterContainer / :704 UnregisterContainer。
--      **绘制、动画、鼠标捕获全在 containers 之外的 widgets/containerwidget.lua**。
--   ③ **联机同步**：本文件**不发任何网络包**，它只 PushEvent("itemget")
--      与 PushEvent("itemlose")（第 538/547/1047 行）。真正的转写发生在
--      components/container_replica.lua:30-47：它 ListenForEvent 这两个事件，
--      转成 container_classified 的 netvar（SetSlotItem）。
--      ★ 这与 components/inventory.lua 的模式完全一致——
--        「服务端组件只产生事件，replica 只负责网络，classified 负责存储」。
--   ④ **物品筛选**：规则写在 containers.lua，判定在本文件第 269-296 行
--      CanTakeItemInSlot，**每个入口（拖拽/点击/程序化 GiveItem）都必过它**。
--
-- ★★ 全文件最重要的认知一：★ 槽位是**稀疏表**，下标不可信。
--   · self.slots 是 `{ [k] = Entity }`，RemoveItem_Internal 第 1040 行只做
--     `self.slots[slot] = nil`，**不做元素搬移**；
--   · 遍历一律用 pairs()（无序），只有「找空位」才用 1..numslots 的 for；
--   · 为什么不搬移？因为槽位编号对玩家是有视觉记忆的——玩家记得
--     「斧头在第 4 格」，搬移会让画面无故跳动。
--     ★ 代价：槽号会越来越稀疏，UI 必须按 1..numslots 逐个问
--     GetItemInSlot（container_replica.lua:434）。
--
-- ★★ 全文件最重要的认知二：**入容器出容器一律经过 CanTakeItemInSlot**。
--   第 450 行 GiveItem 的第一道门就是它；第 1106/1129/1238/1262/1285/1316/1354
--   七个点击/拖拽处理器的第一道门也都是它。
--   ⇒ ★ 这就是「itemtestfn 的调用时机」的全部答案：
--     · **拖拽时实时判定**（鼠标悬停即算，componentactions.lua:680/2551 侧）；
--     · **点击时再判定一次**（本文件七个 Put/Take/Add/Swap/Move 处理器）；
--     · **程序化放入时判定**（GiveItem 第 450 行）；
--     · **查询时判定**（CanAcceptCount 第 406/430 行、
--       GetSpecificSlotForItem 第 301 行）。
--   ⇒ 判定被放在客户端（container_replica.lua:340 有一份同构实现）
--     是为了 UI 立即反馈；服务端再判一次是为了防作弊。两份实现必须同步修改。
--
-- ★★ 全文件最重要的认知三：堆叠语义由 `acceptsstacks` 与 stackable 组件
--   **共同**决定，本文件只做「协调」，不自己算数量：
--   · acceptsstacks = false（蓝图里 20+ 处）→ GiveItem 第 534 行会把超量堆叠
--     `Get()` 成单个，并**返回 false**（明明放进去了却报告失败，这是刻意的，
--     见第 533 行原注释「this should probably have been handled earlier」）；
--   · infinitestacksize（本文件独有的 makereadonly 只读开关，第 36 行）→
--     第 543 行 SetIgnoreMaxSize(true)，让 stackable 忽略 maxsize 上限；
--   · ★ 超量堆叠（overstacked）的处理散落在第 1160/1181/1216/1356/1434/1499 行，
--     规则统一是「取 originalmaxsize 而非当前 stacksize」。
--     DropOverstackedExcess（第 228 行）负责把多出来的部分**丢到地上**。
--
-- ★★ 全文件最重要的认知四：开合是**引用计数**（opencount），不是布尔。
--   · openlist[doer] = true 是「谁开着」，opencount 是派生计数（第 633/684 行）；
--   · 第 619 行 `if not self.skipautoclose then StartUpdatingComponent` ——
--     skipautoclose 字段在第 34 行**被注释掉了**，也就是说该字段永远为 nil，
--     自动关闭的 onupdate **永远开启**。⚠ 见第 34 行注释处的说明；
--   · 第 625 行开一个容器前先把「同 prefab 或同 type」的旧容器关掉，
--     实现「同类容器互斥」（背包只能开一个）；
--   · 第 1059-1084 OnUpdate 是自动关闭的唯一实现：距离 >3（CONTAINER_AUTOCLOSE_DISTANCE）
--     或视线被挡 → Close。
--
-- ★★ 全文件最重要的认知五：三个 makereadonly 开关是**只读属性系统**。
--   第 36/37 行 `makereadonly(self, "infinitestacksize")` 与 readonlycontainer，
--   配合 WidgetSetup 第 86-97 行的 removesetter/makereadonly 循环，
--   使这些字段**只能通过 EnableInfiniteStackSize/EnableReadOnlyContainer 修改**。
--   ★ 原因见 class.lua 的 property setter 实现：它们要同时改本地状态、
--     改 netvar、再批量刷新槽内物品——不能被外部随手赋值打断。
--
-- 关键符号：Container（类）, slots, numslots, openlist, opencount, openlimit,
--   canbeopened, acceptsstacks, usespecificslotsforitems, issidewidget,
--   itemtestfn, priorityfn, type, widget, infinitestacksize, readonlycontainer,
--   WidgetSetup, NumItems, IsFull, IsEmpty, SetNumSlots, CanTakeItemInSlot,
--   GetSpecificSlotForItem, ShouldPrioritizeContainer, CanAcceptCount,
--   GiveItem, RemoveItem, RemoveItemBySlot, RemoveItem_Internal, RemoveAllItems,
--   GetItemInSlot, GetItemSlot, GetAllItems, Open, Close, IsOpen, IsOpenedBy,
--   IsOpenedByOthers, CanOpen, GetOpeners, IsHolding, FindItem, FindItems,
--   ForEachItem, GetSpecializedContainers, IsSpecializedContainer, Has,
--   HasItemThatMatches, HasItemWithTag, GetItemsWithTag, GetItemByName,
--   GetCraftingIngredient, ConsumeByName, OnSave, OnLoad, OnUpdate,
--   PutOneOfActiveItemInSlot, PutAllOfActiveItemInSlot, SwapActiveItemWithSlot,
--   MoveItemFromAllOfSlot, ReferenceAllItems, EnableInfiniteStackSize,
--   EnableReadOnlyContainer, IsRestricted, IsThiefProof, DropEverything,
--   DestroyContents, ItemTestFn 调用链
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 containers.lua:9 containers.widgetsetup —— 本文件唯一读取的外部数据源
--   ★★ 参见 containers.lua:1019 冰箱 itemtestfn —— 筛选规则的四层漏斗范例
--   ★★ 参见 components/container_replica.lua:30-47 —— itemget/itemlose → netvar
--   ★★ 参见 prefabs/container_classified.lua —— 真正的网络数据载体
--   ★★ 参见 prefabs/container_opener.lua —— 「谁开着」的第二个 classified 实体
--   ★★ 参见 components/inventory.lua —— 同构的近亲（容器是物品栏的溢出目标）
--   参见 components/inventory.lua:813 GetOverflowContainer —— 本文件第 1372 行调用它
--   参见 components/inventory.lua:1697 GetCraftingIngredient —— 本文件 920 行的孪生
--   参见 components/stackable.lua:109 Get —— 本文件所有拆堆动作的落点
--   参见 components/stackable.lua:36 SetIgnoreMaxSize —— infinitestacksize 的实现
--   参见 components/stackable.lua:68 IsOverStacked —— overstacked 判定
--   参见 components/inventoryitem.lua —— OnPutInInventory/OnDropped/OnRemoved 回调
--   参见 components/preserver.lua —— readonlycontainer 附带的防腐组件
--   参见 screens/playerhud.lua:385 OpenContainerWidget —— type 决定挂载点
--   参见 components/builder.lua:500 GetIngredients —— 合成取料的上游
--   参见 actions.lua:1095 —— CanOpen 的调用点（开合门禁在动作层）
--   参见 prefabs/container_closed_receiveitem_classified.lua —— 闭容器收物动画
--   参见 constants.lua:2928 CONTAINER_AUTOCLOSE_DISTANCE = 3
--   参见 prefabskin.lua:18 SKIN_SOUND_FX —— 皮肤音效覆盖（642 行）
--   参见 class.lua —— makereadonly / property setter 的实现
--============================================================
-- 【★★ 两层职责的接缝】整个容器系统只有这一行 require 指向 containers.lua。
--   它在第 91 行被调用（WidgetSetup）——本文件与蓝图的全部耦合点仅此一处。
--   ★ 这意味着：容器系统 99% 的逻辑在这里，蓝图里的 itemtestfn 只是「被调用的闭包」。
--   参见 containers.lua:9 containers.widgetsetup —— 浅拷贝 + 设置 numslots。
local containers = require("containers")

-- 【属性 setter 三兄弟之一：canbeopened】
--   ★ 关键：setter 里**只写 netvar，不改本地字段**。
--     本地值由第 31 行构造函数直接赋值，之后只能读。
--   为什么要走 setter？因为 canbeopened 必须**双端一致**，而客户端没有组件。
--   ⇒ 这是「服务端组件 + 客户端镜像」架构的标准写法，全文件 3 处。
local function oncanbeopened(self, canbeopened)
-- ★ SetCanBeOpened → container_replica.lua:277 → netvar `container._cannotbeopened`。
--   ⚠ 注意 netvar 名字是**反向的**（_cannotbeopened）：
--     原因见 container_replica.lua:278 `self._cannotbeopened:set(not canbeopened)`。
--   ★ 为什么反过来存？grep 核实全库只有这一个反向 netvar。
--     推测：为了让客户端「默认不可开」成为**零值**（false），
--     即实体刚复制过来、netvar 尚未同步时，客户端默认显示为「不能开」——
--     这是安全的默认值（fail-closed）。而若正向存，零值会变成「可以开」。
    self.inst.replica.container:SetCanBeOpened(canbeopened)
end

-- 【属性 setter 二：skipopensnd】→ netvar `container._skipopensnd`（正向）。
--   ★ 用途见 containers.lua:508-513 的 V2C 注释：
--     多数容器让 prefab 在**世界空间**播放开箱音效，于是要关掉客户端 HUD 音效。
--   消费点：本文件第 639 行 ShouldSkipOpenSnd。
local function onskipopensnd(self, skipopensnd)
    self.inst.replica.container:SetSkipOpenSnd(skipopensnd)
end

-- 【属性 setter 三：skipclosesnd】→ netvar `container._skipclosesnd`。消费点第 694 行。
local function onskipclosesnd(self, skipclosesnd)
    self.inst.replica.container:SetSkipCloseSnd(skipclosesnd)
end

-- 【OnOwnerDespawned：玩家下线时的容器善后】
--   ★ 只做一件事：给容器里每个物品推 player_despawn 事件。
--   为什么需要？物品的 inventoryitem:OnPutInInventory（第 346 行）记录了 owner，
--     若 owner 下线而不通知，物品的湿度/温度/归属会停留在旧 owner 上。
--   ⚠ 推理依据：grep 核实 player_despawn 的消费方主要是 perishable/temperature 类组件。
--   ★ 注意这里**不转移物品**——容器本身若在玩家背包里，会随玩家一起被移除。
local function OnOwnerDespawned(inst)
-- 局部变量：local container = inst.components.container  〔所在：OnOwnerDespawned〕
    local container = inst.components.container
-- 条件分支：if container ~= nil then  〔所在：OnOwnerDespawned〕
    if container ~= nil then
-- ★ 遍历用 `for i = 1, numslots`（有序、连续），而不是 pairs(self.slots)。
--   理由：这里不需要槽号，只要遍历全部物品，两种都对；
--     但用连续循环能**天然遍历到空洞槽**，语义更直白。
--   ⚠ 潜在缺陷：若 self.slots 里有下标 > numslots 的物品（理论上不可能，
--     因为所有写入路径都检查了 slot <= numslots），这里会漏掉。当前安全。
        for i = 1, container.numslots do
-- 局部变量：local item = container.slots[i]  〔所在：OnOwnerDespawned〕
            local item = container.slots[i]
-- 条件分支：if item ~= nil then  〔所在：OnOwnerDespawned〕
            if item ~= nil then
-- ★ PushEvent("player_despawn") —— 注意是 **PushEvent 而不是 PushEventImmediate**。
--   PushEvent 会把回调排到下一帧（DeferredEventHandler 机制），
--     所以物品的保质期结算会**晚一帧**，这是有意的（避免重入）。
                item:PushEvent("player_despawn")
            end
        end
    end
end

-- 【★★ Container 类构造：全部字段初始化清单】
--   ★ 读法：这里列出的就是「一个容器可能有的全部状态」，共 20+ 个字段。
--     其中 3 个是核心数据结构（slots/openlist/opencount），其余是配置与开关。
-- ──
--   ★★ 关于 slots 的性质（贯穿全文件的核心认知）：
--     slots 是**稀疏表** `{[k]=Entity}`，不是数组。
--     · RemoveItem_Internal 第 1040 行只做 `self.slots[slot] = nil`，**不搬移元素**；
--     · 所以 slot 号会越来越乱，但玩家的视觉记忆（斧头在第 4 格）得以保留；
--     · 「找空位」时才用 1..numslots 的有序 for（如第 524 行）。
--   ⇒ 这是「物品栏」（components/inventory.lua）的同款设计，参见 inventory.lua 注释版。
local Container = Class(function(self, inst)
-- inst 引用：组件与实体的双向指针。★ 所有对外 API 都通过 self.inst 触达实体。
    self.inst = inst
-- ★★ slots：稀疏的「槽号 → 物品实体」表。**不存物品数据，只存实体引用**。
--   推论：背包、箱子里的东西全是独立实体，各自带着 stackable/perishable/fuel 组件。
--     这与「把物品存成 {name=, count=} 表」的引擎做法完全相反，
--     也是 DST 能让一堆物品各自腐烂/受潮/被诅咒的根本原因。
    self.slots = {}
-- numslots：槽位总数。★ 来自 containers.lua:15（数 widget.slotpos）。判定见第 107 行 IsFull。
    self.numslots = 0
-- canbeopened：能否被打开。★ 构造函数直接赋值，之后 setter 只写 netvar 不改它。
--   消费方：actions.lua:1097 / 4560、brains/monkeybrain.lua:227 等（AI 与动作层）。
--   ★ 注意：Open（第 617 行）**不检查** canbeopened——同样是「动作层守门」的模式。
    self.canbeopened = true
-- ★ 关掉客户端开箱音效。★ 由容器组件设、由客户端读（container_replica.lua:289）。
--   本行初值：false。
    self.skipopensnd = false
-- ★ 关掉客户端关箱音效（同上，container_replica.lua:293）。
--   本行初值：false。
    self.skipclosesnd = false
    --self.skipautoclose = false
-- ★ 是否接受整摞物品。默认 true；蓝图可覆盖（containers.lua 有 20+ 处 false）。
--   本行初值：true。
    self.acceptsstacks = true
-- ★★ makereadonly(self, "infinitestacksize") —— 只读属性系统。
--   效果：这个字段之后不能被 `self.infinitestacksize = true` 直接赋值，
--     只能通过第 1565 行 EnableInfiniteStackSize 修改。
--   ★ 为什么？class.lua 的 property setter 实现（见第 1566 行注释）表明：
--     改这个字段必须同时①改底层存储 ②改 netvar ③批量刷新槽内物品，
--     三步必须原子完成。直接赋值会只做第一步，导致状态不同步。
--   ⇒ 这是「用类型系统强制不变量」的少见但正确的用法。
	makereadonly(self, "infinitestacksize")
-- readonlycontainer：只读容器开关，同样 makereadonly（见第 1606 行 EnableReadOnlyContainer）。
	makereadonly(self, "readonlycontainer")
-- usespecificslotsforitems：槽位是否有语义。★ 来自蓝图，默认 false。
--   落点：第 299 行 GetSpecificSlotForItem、第 523 行 GiveItem 的选位分支。
    self.usespecificslotsforitems = false
-- issidewidget：UI 是否在侧边。★ 来自蓝图，第 637 行传给 HUD:OpenContainer。
    self.issidewidget = false
-- type：容器类型字符串。★ 只用于第 625 行的「同类互斥」判定。
--   ⚠ 它**不参与**物品筛选（那是 itemtestfn 的事）。
    self.type = nil
-- ★ 蓝图里的 UI 配置表。★ 浅拷贝共享：多个同类容器的 self.widget 是同一张表。
--   本行初值：nil。
    self.widget = nil
-- ★ itemtestfn：来自蓝图的闭包，形如 (container, item, slot) → boolean。
--   唯一调用点：第 295 行（CanTakeItemInSlot 的最后一行）。
--   ★ 这是全文件**最重要的一个字段**——它就是「容器能装什么」的全部规则。
    self.itemtestfn = nil
-- priorityfn：专用容器优先判定，形如 (container, item) → boolean。
--   唯一调用点：第 319 行 ShouldPrioritizeContainer 内部。
--   ★ 与 itemtestfn 的区别：它不决定「能不能放」，只决定「优先往哪放」。
    self.priorityfn = nil

-- ★★ openlist：打开者表 {doer → true}。以**实体为键**，不是布尔数组。
--   作用：① 支持多人同时开同一个箱子；② 知道「谁开着」以便逐个关闭。
--   ★ 它是哈希表（pairs 无序），所以第 821 行 GetOpeners()[1] 的「第一个」
--     在严格意义上是未定义行为（见 containers.lua:819 的 ⚠ 标注）。
    self.openlist = {}
-- ★ opencount：打开者**计数**（由 openlist 派生，第 633/684 行增减）。
--   为什么不用 #openlist？因为表的「长度」对哈希表无意义，必须显式计数。
--   它是 openlimit 判定（第 736 行）与 IsOpen（第 724 行）的唯一依据。
    self.opencount = 0

-- ⚠ isexposed：原注释「--flag to disable protection from rain」——已注释。
--   推理：这是「暴露在雨下」的开关，但没有任何地方读写 self.isexposed。
--   ★ grep 核实（本文件内）：`isexposed` 零命中；说明该字段被更底层的 sheltered 组件取代。
--   ⇒ 这与第 34 行的 skipautoclose 是同一类「已被重构淘汰但保留痕迹」的字段。
	--self.isexposed = false --flag to disable protection from rain

-- ⚠ droponopen：原注释整行被注释，无任何说明。
--   ★ grep 核实：**全库唯一**的引用在第 795 行 ValidateSpecializedContainer：
--     `not (container.droponopen or container.inst:HasTag("portablecontainer"))`。
--   ⇒ 关键结论：droponopen 从未被**赋值**，永远是 nil，
--     所以第 795 行的判据实际等价于「不是 portablecontainer 标签」。
--     这是一个**半失效的字段**——读它的代码以为它在起作用。仅标注，不改代码。
	--self.droponopen = false
-- ⚠ restrictedtag：原注释「-- Only entities with this tag can interact.」
--   ★ grep 核实：**本文件从不给 self.restrictedtag 赋值**，只有第 1642 行在读它。
--     赋值方在别处（模组或特定 prefab 通过 makereadonly/直接赋值设置）。
--   消费方：第 1636 行 IsRestricted。★ 注释里说「Only entities with this tag」，
--     但实现只对**玩家**生效（第 1637 行 `if not target:HasTag("player") then return false`）。
--     ⇒ 注释与实现**不完全一致**：非玩家目标一律「不受限」。这是一条文档偏差。
    --self.restrictedtag = nil -- Only entities with this tag can interact.
-- ⚠ thiefproof：原注释「--self.thiefproof = nil」被注释掉，但第 1647 行仍在读它。
--   ★ 与 droponopen 同类：读它的代码（第 1647 行 IsThiefProof）以为它有意义，
--     实际永远返回 nil（falsy）= 「不防贼」。
--   ⇒ 真正的防贼逻辑应该在 prefab 层（如 prefabs/safe.lua 自己判断），
--     组件层只是个空挂点。仅标注，不改代码。
    --self.thiefproof = nil

-- ★ ListenForEvent("player_despawn", OnOwnerDespawned)：构造函数里注册监听。
--   注册在组件构造函数中而非 OnAddComponent，是 DST 的常见做法。
    inst:ListenForEvent("player_despawn", OnOwnerDespawned)

-- ★ 原注释保留：「--the current opener that has performed an action, can be nil or
--   incorrect, verify before using this!!!」
--   → currentuser：执行动作的当前打开者，**故意设计成不可靠**。
--   → 它被第 1110/1134/1158/1179/1214/1246/1267/1295/1321/1345 等处临时赋值，
--     用途是让物品的 inventoryitem:OnPutInInventory 回调能知道「是谁放进来的」，
--     以便触发 gotnewitem 音效/统计。
--   ⚠ 因为是临时全局状态，**嵌套操作会互相覆盖**（注释里明说了「can be incorrect」）。
--     例如在 GiveItem 的回调里再触发另一个 GiveItem，currentuser 就会被内层改掉。
    --the current opener that has performed an action, can be nil or incorrect, verify before using this!!!
    --self.currentuser = nil


-- ★★ 「Hacky flags」注释块：三个为「在容器之间搬物品」准备的临时开关。
--   · ignorespoverflow（第 802 行）——本容器被当作溢出容器时，忽略 GetSpecializedContainers；
--   · ignoreclosedspoverflow（第 813 行）——忽略「关闭状态的专用容器」；
--   · ignoresound（第 549 行）——塞物品时不播 gotnewitem 音效。
--   另有两个类似的在 Move* 系列里设在**目标**容器上：ignoreoverflow / ignorefull。
--   ★ 它们全都不是 makereadonly 的（即可以随手改），因为它们是「一次搬运期间的临时态」。
--   ⇒ 设计模式：把「例外」编码成 flag 而不是参数，避免给 GiveItem 加 5 个布尔形参。
    --Hacky flags for altering behaviour when moving items between containers
-- ★ hack flag：禁用 GetSpecializedContainers（第 802 行）。设置于第 1375 行。
--   本行初值：false。
	self.ignorespoverflow = false
-- ★ hack flag：允许往**未打开**的专用容器塞物（第 793 行）。设置于第 1378 行。
--   本行初值：false。
	self.ignoreclosedspoverflow = false
-- ★ hack flag：塞物时不播 gotnewitem 音效（第 549 行）。搬运事务期间的临时静音。
--   本行初值：false。
    self.ignoresound = false
-- ignoreoverstacked：取出超量堆叠物品时，是否**不**把多出来的部分丢到地上。
--   设置点：第 1360 行 MoveItemFromAllOfSlot（目标容器 infinitestacksize 时）。
--   ⇒ 语义：目标是「无限堆叠容器」时，整摞一起搬走，多余部分不落地。
	self.ignoreoverstacked = false
end,
nil,
-- 【Class 的第三参数：属性 setter 表】
--   ★ class.lua 的 Class(constructor, parent, props) —— props 里每个键自动生成
--     「读方法 + setter（触发 on<key> 回调）」。
--   本文件只注册了 3 个属性（canbeopened/skipopensnd/skipclosesnd），
--     而 infinitestacksize / readonlycontainer 是用 makereadonly 走的另一条路。
--   ⇒ ★ 两条路并存是有意为之：前三个只需同步 netvar，后两个还要批量改物品。
{
-- 局部赋值：canbeopened = oncanbeopened,  〔所在：OnOwnerDespawned〕
    canbeopened = oncanbeopened,
-- 局部赋值：skipopensnd = onskipopensnd,  〔所在：OnOwnerDespawned〕
    skipopensnd = onskipopensnd,
-- 局部赋值：skipclosesnd = onskipclosesnd,  〔所在：OnOwnerDespawned〕
    skipclosesnd = onskipclosesnd,
})

-- 【★★ widgetprops：蓝图字段的「白名单」——本文件承认的容器配置全集】
--   这 9 个字段就是 containers.lua 能配置的一切容器行为/外观参数。
--   ★ 它被第 88/95 行用在 WidgetSetup 的「拆锁 → 设置 → 上锁」流程里。
--   ⚠ 但请注意：widgetsetup 是**浅拷贝全部键**的（第 165 行 container[k] = v），
--     所以白名单外的蓝图字段（lowpriorityselection/excludefromcrafting 等）
--     **仍然会被拷进 self**，只是不会被 makereadonly 保护。
--   ⇒ 推论：widgetprops 不是「过滤白名单」，而是「需要变成只读属性的清单」。
local widgetprops =
{
-- 白名单成员「numslots」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "numslots",
-- 白名单成员「acceptsstacks」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "acceptsstacks",
-- 白名单成员「usespecificslotsforitems」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "usespecificslotsforitems",
-- 白名单成员「issidewidget」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "issidewidget",
-- 白名单成员「type」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "type",
-- 白名单成员「widget」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "widget",
-- 白名单成员「itemtestfn」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "itemtestfn",
-- 白名单成员「priorityfn」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "priorityfn",
-- 白名单成员「openlimit」：★ WidgetSetup 会对它 removesetter + makereadonly。
    "openlimit"
}

-- 【★★ WidgetSetup：服务端的蓝图装配入口】三步走，每步都有讲究：
--   ① removesetter：把 9 个字段的 setter **全部拆掉**（第 88 行）；
--   ② containers.widgetsetup + replica:WidgetSetup：把值灌进来（第 91-92 行）；
--   ③ makereadonly：重新上锁（第 95 行）。
--   ★ 为什么必须「拆锁 → 赋值 → 上锁」三步？
--     因为被 makereadonly 的字段不能直接赋值，但蓝图灌注必须赋值。
--     ⇒ 这是「批量修改受保护属性」的标准绕行模式。
--   ⚠ 风险：若中途抛错，字段会停留在「无锁」状态，后续可被意外赋值。
--     当前代码无抛错路径（containers.lua:15 的 SetNumSlots 有 assert，
--     但那是 assert(numslots >= self.numslots)，在重复调用时可能触发）。
function Container:WidgetSetup(prefab, data)
-- 循环：for i, v in ipairs(widgetprops) do  〔所在：Container:WidgetSetup〕
    for i, v in ipairs(widgetprops) do
-- ★ removesetter(self, v)：class.lua 提供的辅助函数，移除该属性的 setter 钩子。
--   没有它，下一行的浅拷贝会触发 oncanbeopened 等回调，导致半初始化状态写 netvar。
        removesetter(self, v)
    end

-- ★ 把蓝图灌进**服务端组件**（第 9 行 containers.lua 的浅拷贝 + SetNumSlots）。
--   ⇒ 注意此时 self.widget 指向 containers.params.X.widget 的**同一张表**（共享）。
    containers.widgetsetup(self, prefab, data)
-- ★ 同一个蓝图灌进**客户端镜像**（container_replica.lua:232）。
--   —— 这是「双端分裂」的第二步：两端各自持有一份同源的 widget/itemtestfn。
--   ⚠ 代价：任何新增的蓝图字段都必须**同时**在服务端与客户端组件上有意义，
--     否则就会出现「服务端认、客户端不认」的分裂。
--     这也是第 156-157 行的 FIXMEC 注释所指出的历史遗留问题的根源。
    self.inst.replica.container:WidgetSetup(prefab, data)

-- 循环：for i, v in ipairs(widgetprops) do  〔所在：Container:WidgetSetup〕
    for i, v in ipairs(widgetprops) do
        makereadonly(self, v)
-- ★★ 至此 WidgetSetup 完成：9 个字段全部变成只读。
--   ⇒ 后续任何对这些字段的修改都必须走 Enable* 系列或改蓝图源。
--   ★★ 这就是「蓝图 → 组件」的完整生命周期：
--     prefab 构造时调 WidgetSetup(name) → 浅拷贝 9 字段 → 锁死。
--     之后组件就是「一块被配置好的硬件」，只提供行为方法。
    end
end

-- GetWidget：返回蓝图里的 widget 表（共享引用，非副本）。消费方：widgets 层。
function Container:GetWidget()
-- 返回：return self.widget  〔所在：Container:GetWidget〕
    return self.widget
end

-- ★★ NumItems：GetTableSize(self.slots) —— 统计**非 nil 槽位数**。
--   注意：不是 stacksize 之和。①格 20 个木头和 20 格各 1 个木头，NumItems 都算 1。
--   ⇒ 想查总数要用 Has（第 826 行）/ HasItemWithTag（第 851 行）。
--   ⚠ O(n) 复杂度（遍历整表），在每帧调用的 UI 里是性能隐患（但本文件不每帧调）。
function Container:NumItems()
-- 返回：return GetTableSize(self.slots)  〔所在：Container:NumItems〕
    return GetTableSize(self.slots)
end

-- ★★ IsFull：**槽位占满**而不是「装不下」。判定 = 非空槽数 >= numslots。
--   ★ 这是本系统唯一的「容量」概念——★ grep 核实**不存在** maxweight/重量上限。
--     任务描述提到的 rangecheck/maxweight 在容器系统中并不存在（见文件头说明）。
--   ⇒ 「冰箱能装多少」= 9 格 × 每格 stackable.maxsize，与重量无关。
--   ⚠ 推论：一个装满 9 摞 99 燧石的冰箱和一个空冰箱，IsFull 都返回 true。
--     若要让「放不下的堆叠」也能塞进去，需要 infinitestacksize（见第 36 行）。
function Container:IsFull()
-- 返回：return GetTableSize(self.slots) >= self.numslots  〔所在：Container:IsFull〕
    return GetTableSize(self.slots) >= self.numslots
end

-- ★ IsEmpty：next(self.slots) == nil —— 比 NumItems() == 0 更省（O(1) 短路）。
--   两者语义完全等价，此处选 next 是因为空表判定不需要遍历。
function Container:IsEmpty()
-- 返回：return next(self.slots) == nil  〔所在：Container:IsEmpty〕
    return next(self.slots) == nil
end

-- 【★ SetNumSlots：只能变大，不能变小】
--   assert(numslots >= self.numslots) 是本文件**唯一的 assert**。
--   ★ 为什么只许增大？两个理由：
--     ① 缩小会导致已有物品的 slot 号越界，遍历 1..numslots 时漏掉它们；
--     ② 缩小会让旧存档的物品「凭空消失」（第 1001 行按 slot 还原时 GiveItem 会失败）。
--   ⇒ 这是「数据结构不变量由 assert 守卫」的正确范例。
function Container:SetNumSlots(numslots)
-- assert(numslots >= self.numslots)  〔所在：Container:SetNumSlots〕
    assert(numslots >= self.numslots)
-- 槽位总数。★ 只增不减（第 116 行 assert）。判定见第 107 行 IsFull。
--   本行初值：numslots。
    self.numslots = numslots
-- ★ 槽位数只增不减的断言到此结束。
--   ★★ 呼应 containers.lua:1663-1666 sunkenchest 的原注释：
--     「它常常从小容量（3x3）旧存档数据满载进来，我们已迁到 3x5」——
--     正因为 numslots 只能增大，旧存档的 9 件物品才能安全落到新版的 15 槽里。
--   ⇒ 这个 assert 不是随手写的防御，它是**存档兼容机制的基石**。
end

-- 【★★ DropItemBySlot：把某槽物品丢到地面的完整流程】
--   五步：① 取物品 → ② 检查可丢 → ③ 内部移除 → ④ 定位+落地 → ⑤ 清 prev 字段+发事件。
--   ★ 关键点：它**不调用 RemoveItemBySlot**（那会多一次查表），
--     而是直接调 RemoveItem_Internal（第 129 行），并显式传 wholestack=true。
function Container:DropItemBySlot(slot, drop_pos, keepoverstacked)
-- 局部变量：local item = slot and self.slots[slot]  〔所在：Container:DropItemBySlot〕
	local item = slot and self.slots[slot]
-- 条件分支：if item == nil or item.components.inventoryitem == nil then  〔所在：Container:DropItemBySlot〕
	if item == nil or item.components.inventoryitem == nil then
-- 返回：return  〔所在：Container:DropItemBySlot〕
		return
-- ★★ islockedinslot：槽位锁。带这个标记的物品**不能被丢出**。
--   ★ assert(BRANCH ~= "dev") —— dev 分支会直接崩溃，这是「主动暴露 bug」的手法：
--     开发期一旦有物品被错误丢弃立刻炸，正式版（BRANCH ~= "dev"）静默返回。
--   推理依据：本文件有 6 处同样的 assert（第 125/251/1189/1210/1339/1505 行），
--     都是「不该发生的状态发生时就地炸掉」。
--   ⇒ 这是生产级代码里少见的「调试断言常驻」策略。
	elseif item.components.inventoryitem.islockedinslot then
-- assert(BRANCH ~= "dev")  〔所在：Container:DropItemBySlot〕
		assert(BRANCH ~= "dev")
-- 返回：return  〔所在：Container:DropItemBySlot〕
		return
	end
	--local item = self:RemoveItemBySlot(slot, keepoverstacked)
-- ★ RemoveItem_Internal(item, slot, true, keepoverstacked)：
--   第三个参数 wholestack=true → 整摞拿走；第四个 keepoverstacked 由调用方决定。
--   ⚠ 注意这里绕过了第 450 行的 CanTakeItemInSlot 检查——**移除不需要准入检查**。
--     这是对的：准入是「能不能进」，取出永远允许。
	item = self:RemoveItem_Internal(item, slot, true, keepoverstacked)
-- 条件分支：if item ~= nil then  〔所在：Container:DropItemBySlot〕
    if item ~= nil then
-- 落地位置：drop_pos 缺省用容器自己的世界坐标。
--   ⚠ 注释「@V2C NOTE: not supported when using container_proxy」在第 222-223 行，
--     因为 container_proxy（客户端影子实体）位置恒为 (0,0,0)，用它会把物品丢到原点。
        drop_pos = drop_pos or self.inst:GetPosition()

-- ★ Transform:SetPosition(drop_pos:Get()) —— 两种坐标 API：
--   drop_pos 是 Vector3 时用 :Get() 拆成 x,y,z（见第 133 行）；
--   或直接接受 x,y,z 三个数（第 247 行的 DropItemAt 支持两种）。
--   ⇒ 这是 DST 里「一个函数支持 Vector3 与 xyz 双形态」的标准模式。
        item.Transform:SetPosition(drop_pos:Get())
-- 条件分支：if item.components.inventoryitem ~= nil then  〔所在：Container:DropItemBySlot〕
        if item.components.inventoryitem ~= nil then
-- ★ OnDropped(true)：参数 true = 「是被丢弃而非被移动」。
--   inventoryitem 组件据此重置湿度/温度/归属（对比 OnPutInInventory 第 346 行）。
            item.components.inventoryitem:OnDropped(true)
        end
-- ★★ prevcontainer / prevslot 置 nil：这两个字段是「**物品刚刚从哪来**」的记忆。
--   用途：MoveItemFromAllOfSlot 第 1381 行会清掉它们再 GiveItem 到目标，
--     以防「移回去时又被当成移回来」。
--   ⇒ 设计含义：容器系统用这两个字段表达「跨容器搬运的事务性」。
        item.prevcontainer = nil
        item.prevslot = nil
-- ★ PushEvent("dropitem", {item = item}) —— 通知实体「有东西掉了」。
--   ⚠ 注意这里**不发网络包**。联机同步靠第 1047 行的 itemlose 事件
--     → container_replica.lua:39 → classified 的 netvar。
--   ⇒ 这就是「服务端组件只产生事件、replica 负责转写」模式的两处体现。
        self.inst:PushEvent("dropitem", { item = item })
    end
-- ★★★ 搬运成功的返回点。★ 注意此时 ignoresound 可能已被第 1385 行的回滚改过，
--   但正常路径下它早就被第 1386 行（或在别处）恢复为 false。
	return item
end

-- 【★ DropEverythingWithTag：递归丢出带某标签的物品】
--   ★ 关键设计：它会**递归进嵌套容器**（第 158-160 行）。
--   推理：把背包里的「易腐品」全倒出来时，背包里可能还装着冰箱，
--     冰箱里也有易腐品——必须一路递归到底。
--   ⚠ 但递归是**无深度限制**的。若容器自引用（不可能，但理论上），会栈溢出。
function Container:DropEverythingWithTag(tag, drop_pos, keepoverstacked)
-- 局部变量：local internal_containers = {}  〔所在：Container:DropEverythingWithTag〕
    local internal_containers = {}

-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverythingWithTag〕
    for i = 1, self.numslots do
-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverythingWithTag〕
        local item = self.slots[i]
-- 条件分支：if item ~= nil then  〔所在：Container:DropEverythingWithTag〕
        if item ~= nil then
-- 只丢带该标签的**直接**物品；带 container 组件的先收集起来，稍后递归。
--   ★ 两阶段处理（先扫本层、再递归）避免了「递归时修改本层 slots」的迭代失效问题。
            if item:HasTag(tag) then
				self:DropItemBySlot(i, drop_pos, keepoverstacked)
-- 嵌套容器不入表也不丢（除非它自己带 tag），只记下来稍后递归。
--   ★ 这是「容器套容器」的普遍处理模式，第 163/182 行的两个函数同构。
            elseif item.components.container ~= nil then
-- table.insert(internal_containers, item)  〔所在：Container:DropEverythingWithTag〕
                table.insert(internal_containers, item)
            end
        end
    end

-- 循环：for i, v in ipairs(internal_containers) do  〔所在：Container:DropEverythingWithTag〕
    for i, v in ipairs(internal_containers) do
		v.components.container:DropEverythingWithTag(tag, drop_pos, keepoverstacked)
    end
end

-- 【DropEverythingByFilter：与上者同构，但判定换成回调】
--   filterfn(self.inst, item) —— 注意**多传了容器自身**作为第一参，
--     让回调能根据容器类型/标签做决策（例如「只从冰箱里倒出来」）。
function Container:DropEverythingByFilter(filterfn)
-- 局部变量：local internal_containers = {}  〔所在：Container:DropEverythingByFilter〕
    local internal_containers = {}

-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverythingByFilter〕
    for i = 1, self.numslots do
-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverythingByFilter〕
        local item = self.slots[i]
-- 条件分支：if item ~= nil then  〔所在：Container:DropEverythingByFilter〕
        if item ~= nil then
-- ★ filterfn 返回 true 才丢。与 DropEverythingWithTag 的 HasTag 等价。
            if filterfn(self.inst, item) then
-- ⚠ 此处调 `self:DropItemBySlot(i)` **不传 drop_pos** —— 与第 151 行不同。
--   ⇒ 后果：物品会落在**容器自己的坐标**上，而不是调用方指定的位置。
--   推理依据：DropItemBySlot 第 131 行 `drop_pos = drop_pos or self.inst:GetPosition()`。
--   这与 DropEverythingWithTag（第 151 行传 drop_pos）行为不一致，
--   ★ 看起来是**遗漏参数**而非有意设计。仅标注，不改代码。
                self:DropItemBySlot(i)
-- 次选条件：elseif item.components.container ~= nil then  〔所在：Container:DropEverythingByFilter〕
            elseif item.components.container ~= nil then
-- table.insert(internal_containers, item)  〔所在：Container:DropEverythingByFilter〕
                table.insert(internal_containers, item)
            end
        end
    end

-- 循环：for i, v in ipairs(internal_containers) do  〔所在：Container:DropEverythingByFilter〕
    for i, v in ipairs(internal_containers) do
        v.components.container:DropEverythingByFilter(filterfn)
    end
end

-- 【★★ DropEverything：全清空，且递归 —— 最彻底的一个】
--   ★ 与前两个的差异：① 跳过 islockedinslot 的物品（第 188 行）；
--     ② 嵌套容器即使带锁也要递归（第 190 行）；
--     ③ 用**惰性建表**（internal_containers 为 nil 时才 { item }），省一次分配。
--   典型用途：箱子被砸/被烧毁时清场（prefabs 里大量调用）。
function Container:DropEverything(drop_pos, keepoverstacked)
-- 局部变量：local internal_containers  〔所在：Container:DropEverything〕
	local internal_containers

-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverything〕
    for i = 1, self.numslots do
-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverything〕
		local item = self.slots[i]
-- 条件分支：if item then  〔所在：Container:DropEverything〕
		if item then
-- 条件分支：if not item.components.inventoryitem.islockedinslot then  〔所在：Container:DropEverything〕
			if not item.components.inventoryitem.islockedinslot then
				self:DropItemBySlot(i, drop_pos, keepoverstacked)
-- ★ 带 islockedinslot 的物品不能丢；但**如果它本身是容器**，仍要递归清空它内部。
--   推理：锁只锁「这个物品作为物品被拿走」，不锁「它的内部内容」。
--     这是一个考虑得很细的边界——否则锁定的箱子里会留一堆孤儿物品。
			elseif item.components.container then
-- 条件分支：if internal_containers then  〔所在：Container:DropEverything〕
				if internal_containers then
-- table.insert(internal_containers, item)  〔所在：Container:DropEverything〕
					table.insert(internal_containers, item)
-- 兜底分支（前述条件全不成立）。〔所在：Container:DropEverything〕
				else
-- 局部赋值：internal_containers = { item }  〔所在：Container:DropEverything〕
					internal_containers = { item }
				end
			end
		end
    end

-- 条件分支：if internal_containers then  〔所在：Container:DropEverything〕
	if internal_containers then
-- 循环：for _, v in ipairs(internal_containers) do  〔所在：Container:DropEverything〕
		for _, v in ipairs(internal_containers) do
			v.components.container:DropEverything(drop_pos, keepoverstacked)
		end
	end
end

-- 【★ DropEverythingUpToMaxStacks：限量倾倒】
--   keepoverstacked=true（第 211 行）→ 保留超量堆叠，超出的随物品一起走。
--   ★ 典型用途：沃比坐骑「吐出库存里的 N 摞东西」这类玩法需求。
function Container:DropEverythingUpToMaxStacks(maxstacks, drop_pos)
-- 局部变量：local stacks = 0  〔所在：Container:DropEverythingUpToMaxStacks〕
	local stacks = 0
-- ★ while next(self.slots)：循环直到**所有槽都空**为止。
--   ⚠ 危险结构：若 DropItemBySlot 因 islockedinslot 而没真正移除（第 124 行），
--     这里会**死循环**。推理：第 211 行没传 keepoverstacked 之外的锁定检查，
--     而 DropItemBySlot 内部会在 islockedinslot 时直接 return、不动 slots。
--     ⇒ 若容器里有被锁定的物品，这个 while 永远无法终止。
--     ★ 判定为 **⚠ 真实缺陷**（非风格问题）。当前无调用方受影响（grep 核实无外部调用），
--       故未暴露。仅标注，绝不改代码。
	while next(self.slots) do
-- 循环：for k in pairs(self.slots) do  〔所在：Container:DropEverythingUpToMaxStacks〕
		for k in pairs(self.slots) do
			self:DropItemBySlot(k, drop_pos, true)
-- 局部赋值：stacks = stacks + 1  〔所在：Container:DropEverythingUpToMaxStacks〕
			stacks = stacks + 1
-- 条件分支：if stacks >= maxstacks then  〔所在：Container:DropEverythingUpToMaxStacks〕
			if stacks >= maxstacks then
-- 返回：return  〔所在：Container:DropEverythingUpToMaxStacks〕
				return
			end
		end
	end
end

-- ★ 原注释保留：「--V2C: this drops single, so no need to add "keepoverstacked"」
--   ⇒ 这条注释解释了 API 设计：单件丢弃场景不需要超量堆叠的处理参数。
--V2C: this drops single, so no need to add "keepoverstacked"
-- 【Container:DropItem】单件丢弃（用自身坐标）。⚠ container_proxy 下坐标恒为 (0,0,0)，见第 222 行注释。
--   ★ 服务端权威实现。客户端镜像在 components/container_replica.lua 同名方法。
function Container:DropItem(itemtodrop)
-- ★ 原注释保留：「--@V2C NOTE: not supported when using container_proxy because this
--   will be the pocket dimension_container at (0, 0, 0)」
--   → container_proxy 是客户端影子实体，其 Transform 恒为 (0,0,0)，
--     所以「用自身坐标掉落」这条路在代理实体上不可用。
--   ⇒ 这是「服务端/客户端实体分离」导致的经典坑，值得记住。
	--@V2C NOTE: not supported when using container_proxy because this
	--           will be the pocket dimension_container at (0, 0, 0)
-- 局部变量：local x, y, z = self.inst.Transform:GetWorldPosition()  〔所在：Container:DropItem〕
	local x, y, z = self.inst.Transform:GetWorldPosition()
	self:DropItemAt(itemtodrop, x, y, z)
end

-- 【★★ DropOverstackedExcess：把超量堆叠的部分丢到地上】
--   ★ 概念：当 infinitestacksize 容器（第 543 行）把物品堆到超过 originalmaxsize 时，
--     取出时必须把多出来的部分**物归原主地丢出去**，否则就凭空消失了。
--   originalmaxsize 是「开启无限堆叠前的上限」（stackable.lua:17 记录）。
--   ★ 消费点：第 560 行（GiveItem 失败时）、第 1043 行（从无限堆叠容器取出时）、
--     第 1584 行（关闭无限堆叠时）。共 3 处。
function Container:DropOverstackedExcess(item)
-- ★ originalmaxsize：stackable.lua:15-17 在 SetIgnoreMaxSize(true) 时把原 maxsize 存到这里。
--   所以「超量」= stacksize > originalmaxsize（见 stackable.lua:68 IsOverStacked）。
	local maxsize = item.components.stackable and item.components.stackable.originalmaxsize or nil
-- 条件分支：if maxsize then  〔所在：Container:DropOverstackedExcess〕
	if maxsize then
-- 局部变量：local num = item.components.stackable:StackSize()  〔所在：Container:DropOverstackedExcess〕
		local num = item.components.stackable:StackSize()
-- 条件分支：if num > maxsize then  〔所在：Container:DropOverstackedExcess〕
		if num > maxsize then
-- 局部变量：local x, y, z = self.inst.Transform:GetWorldPosition()  〔所在：Container:DropOverstackedExcess〕
			local x, y, z = self.inst.Transform:GetWorldPosition()
-- ★★ repeat…until num <= maxsize：循环吐料直到堆叠回到正常上限。
--   每轮吐出的量是 `math.min(num - maxsize, maxsize)` —— 即「要么刚好补齐，要么吐一整摞」。
--   ★ 为什么不用 for？因为堆叠大小会在循环中变化（Get 会减少 stacksize），
--     while/repeat 才能保证「直到满足条件」。
			repeat
-- ★ stackable:Get(n) —— 拆分堆叠。stackable.lua:109 实现：
--   克隆同 prefab 的新实体、给自己减 n、给对方设 n，并继承 perishable/cursed/rechargeable/湿度温度。
--   ⚠ 每次 Get 都会 **SpawnPrefab**——超量很大时会一次生成很多实体，有性能代价。
				local excess = item.components.stackable:Get(math.min(num - maxsize, maxsize))
				excess.Transform:SetPosition(x, y, z)
-- 条件分支：if excess.components.inventoryitem then  〔所在：Container:DropOverstackedExcess〕
				if excess.components.inventoryitem then
					excess.components.inventoryitem:OnDropped(true)
				end
-- 局部赋值：num = item.components.stackable:StackSize()  〔所在：Container:DropOverstackedExcess〕
				num = item.components.stackable:StackSize()
			until num <= maxsize
		end
	end
end

--V2C: this drops single, so no need to add "keepoverstacked"
-- 【★ DropItemAt：DropItem 的双形态版本（接受 Vector3 或 xyz）】
--   第 253 行 `Vector3.is_instance(x)` 是形态判别：传 Vector3 就拆成 xyz。
--   ★ 这是 DST 的惯用「鸭子类型 + 类型判别」写法，避免重载函数。
function Container:DropItemAt(itemtodrop, x, y, z)
-- 条件分支：if itemtodrop == nil or itemtodrop.components.inventoryitem == nil then  〔所在：Container:DropItemAt〕
	if itemtodrop == nil or itemtodrop.components.inventoryitem == nil then
-- 返回：return  〔所在：Container:DropItemAt〕
		return
-- 次选条件：elseif itemtodrop.components.inventoryitem.islockedinslot then  〔所在：Container:DropItemAt〕
	elseif itemtodrop.components.inventoryitem.islockedinslot then
-- assert(BRANCH ~= "dev")  〔所在：Container:DropItemAt〕
		assert(BRANCH ~= "dev")
-- 返回：return  〔所在：Container:DropItemAt〕
		return
-- 次选条件：elseif Vector3.is_instance(x) then  〔所在：Container:DropItemAt〕
	elseif Vector3.is_instance(x) then
		x, y, z = x:Get()
	end
-- ★ 这里用 `self:RemoveItem(itemtodrop)`（整摞语义由 wholestack 缺省 nil → 取 1 个）
--   对照第 129 行 DropItemBySlot 用 RemoveItem_Internal(..., true)。
--   ⚠ RemoveItem 的 wholestack 参数**未传**（默认 nil）→ 第 1028 行 `(not wholestack and 1)`
--     → 只取 1 个。所以 DropItemAt 丢的是**一个**而非整摞，与原注释一致。
    local item = self:RemoveItem(itemtodrop)
-- 条件分支：if item then  〔所在：Container:DropItemAt〕
    if item then
		item.Transform:SetPosition(x, y, z)
-- 条件分支：if item.components.inventoryitem then  〔所在：Container:DropItemAt〕
        if item.components.inventoryitem then
            item.components.inventoryitem:OnDropped(true)
        end
        item.prevcontainer = nil
        item.prevslot = nil
-- self.inst:PushEvent("dropitem", {item = item})  〔所在：Container:DropItemAt〕
        self.inst:PushEvent("dropitem", {item = item})
    end
-- 返回：return item  〔所在：Container:DropItemAt〕
    return item
end

-- 【★★★ CanTakeItemInSlot —— 本文件最重要、也是整个 DST 物品系统的核心闸门】
--   ★ 它被 12 处调用：
--     · GiveItem 第 450 行（所有程序化放入）；
--     · GetSpecificSlotForItem 第 301 行（选专用槽时逐槽试）；
--     · CanAcceptCount 第 406/430 行（还能收几个）；
--     · 七个点击/拖拽处理器第 1106/1129/1238/1262/1285/1316/1354 行；
--     · Move* 系列的第 1354/1433/1497 行（跨容器搬运前预检）。
--   ⇒ ★★ 结论：**容器系统没有任何绕过这个函数的放入路径**。
--     这一点是 DST 物品一致性的基石——无论从背包拖、点击放、脚本塞、跨容器搬，
--     判定逻辑完全一致，服务端也不需要额外的防作弊检查（只需同样调用它）。
function Container:CanTakeItemInSlot(item, slot)
-- ★★ 五道门（层层 and，全部为真才继续）：
--   ① item 存在；
--   ② 有 inventoryitem 组件；
--   ③ cangoincontainer（引擎/组件标记「可进容器」，默认 true）；
--   ④ 不是 canonlygoinpocket（「只能进背包」，如手持中的特殊物）；
--   ⑤ canonlygoinpocketorpocketcontainers 只能放进「口袋类容器」，
--      而本容器必须是 pocket 容器（自己也有 canonlygoinpocket 标记）；
--   ⑥ 本容器不是 readonlycontainer。
	if not (item and
			item.components.inventoryitem and
			item.components.inventoryitem.cangoincontainer and
			not item.components.inventoryitem.canonlygoinpocket and
-- ★★ 第 274 行是全文件最复杂的一行：处理「只能进背包/口袋容器」的物品。
--   `not A or (self.inst.components.inventoryitem and self.inst.components.inventoryitem.canonlygoinpocket)`
--   翻译：「若物品没这个限制 → 通过；否则要求**本容器自己**也是 pocket 容器」。
--   ⇒ 「背包」的定义是：容器所在实体自己带 inventoryitem.canonlygoinpocket。
--   ⚠ 缺少 `~= nil` 的严格判断：Lua 里 `A and A.B` 若 A 为 nil 返回 nil（falsy），
--     所以逻辑正确；但风格上 `self.inst.components.inventoryitem ~= nil and ...`
--     更明确（对照第 274 行右侧就没写）。全文件两种风格并存。
			(not item.components.inventoryitem.canonlygoinpocketorpocketcontainers or (self.inst.components.inventoryitem and self.inst.components.inventoryitem.canonlygoinpocket)) and
			not self.readonlycontainer)
	then
-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕
		return false
-- ★ GetGameModeProperty("non_item_equips") —— 玩法开关（某些模式下禁止装备进容器）。
--   ★ 这是「游戏模式」层对容器规则的介入点，说明容器系统不是完全封闭的。
	elseif GetGameModeProperty("non_item_equips") and item.components.equippable then
-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕
		return false
-- ★ 有 slot 参数时才做槽位级检查；slot == nil 时只做物品级检查（第 295 行）。
--   ⇒ 「能不能进这个容器」与「能不能进这个槽位」是两级判定，拖拽悬停时只需前者。
	elseif slot then
-- ★ 槽号越界检查：slot < 1 or slot > self.numslots。
--   这是**外部输入校验**——slot 可能来自网络请求，所以必须验。
		if slot < 1 or slot > self.numslots then
-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕
			return false
		end
-- 局部变量：local existingitem = self:GetItemInSlot(slot)  〔所在：Container:CanTakeItemInSlot〕
		local existingitem = self:GetItemInSlot(slot)
-- ★★ 槽位锁的例外规则：已有物品被锁时，只有「同类型可堆叠且未满」才允许追加。
--   推理：islockedinslot 表示「这个槽位整体被某玩法锁定（如展示柜）」，
--     但往里**继续加同类物品**不破坏锁定语义，所以放行。
--   三重与：stackable 存在 + 未满 + CanStackWith(传入物品)。
		if existingitem and
			existingitem.components.inventoryitem.islockedinslot and
			not (	existingitem.components.stackable and
					not existingitem.components.stackable:IsFull() and
					existingitem.components.stackable:CanStackWith(item)
				)
		then
-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕
			return false
		end
	end
-- ★★★ itemtestfn 的唯一调用点：`self.itemtestfn == nil or self:itemtestfn(item, slot)`。
--   语义：**没配置筛选器 = 全放行**（这就是木箱/圣柜「什么都能装」的实现）。
--   ★ 冒号调用 `self:itemtestfn(item, slot)` 把 self 补成第一个形参，
--     所以蓝图里写的签名必须是 (container, item, slot) —— 参数顺序由此确定。
--   ⚠ 返回值不强制为 boolean：Lua 里任何 truthy 值都算通过，nil/false 拒绝。
--     ⇒ 蓝图里 itemtestfn 漏写 return（见 containers.lua:1383 的 beard_sack_1）
--       等价于「拒绝一切」，这是个**容易踩的坑**：第 1383 行其实因为循环内
--       命中就 return true，所以实际是正常的；但风格上仍危险。
-- ★★ 再强调一次：这是 itemtestfn 的**唯一**调用点（服务端组件侧）。
--   客户端有一份同构实现：components/container_replica.lua:340 CanTakeItemInSlot。
--   ⇒ ★★ 两份实现必须同步修改，否则会出现「客户端说能放、服务端拒绝」的抖动。
--   ★ 这也是 DST 双端架构的常态成本：判定逻辑天然需要写两遍
--     （对比 components/inventory.lua 的 Reclientify 式单向同步就没有这个问题）。
	return self.itemtestfn == nil or self:itemtestfn(item, slot)
end

-- 【★ GetSpecificSlotForItem：为「有语义的物品」找专属槽位】
--   ★ 三个前置条件缺一不可：usespecificslotsforitems 开了、非只读容器、有筛选器。
--   ⇒ 若容器只有优先级函数（priorityfn）而无 itemtestfn，它无法分配专用槽。
function Container:GetSpecificSlotForItem(item)
-- 条件分支：if self.usespecificslotsforitems and not self.readonlycontainer and self.itemtestfn ~= nil then  〔所在：Container:GetSpecificSlotForItem〕
    if self.usespecificslotsforitems and not self.readonlycontainer and self.itemtestfn ~= nil then
-- 循环：for i = 1, self:GetNumSlots() do  〔所在：Container:GetSpecificSlotForItem〕
        for i = 1, self:GetNumSlots() do
-- ★ 逐槽试 `self:itemtestfn(item, i)`，第一个接受的槽即返回。
--   ⚠ 这是 **1..numslots 顺序扫描**（有序）：所以「谁的规则更宽谁靠前」会影响选槽。
--     对照第 427 行 portablespicer：slot1=食材、slot2=香料，规则互斥所以无歧义。
--   ⚠ 隐式返回 nil（没有 else）→ 调用方（第 451 行）据此知道「没找到专用槽」。
            if self:itemtestfn(item, i) then
-- 返回：return i  〔所在：Container:GetSpecificSlotForItem〕
                return i
            end
        end
    end
end

-- 【★ ShouldPrioritizeContainer：判断「这个专用容器优先收这个物品」】
--   ★ 与 CanTakeItemInSlot 的差别：这里**不做槽位级检查，也不调 itemtestfn**（第 319 行除外），
--     而是调 priorityfn。二者是**平行**的判定入口，不是包含关系。
--   ★ 用途：背包里的弹药包应该优先收「弹药类」物品（第 317 行校验 inventoryitem 条件）。
function Container:ShouldPrioritizeContainer(item)
-- 条件分支：if not self.priorityfn then  〔所在：Container:ShouldPrioritizeContainer〕
    if not self.priorityfn then
-- 返回：return false  〔所在：Container:ShouldPrioritizeContainer〕
        return false
    end
-- ★ 四重校验：item 存在 / 有 inventoryitem / cangoincontainer / 不是 pocketonly。
--   与第 270 行几乎重复——这是**有意的冗余**，因为两个函数可能被不同调用方单独使用。
    return item ~= nil
        and item.components.inventoryitem ~= nil
        and item.components.inventoryitem.cangoincontainer
        and not item.components.inventoryitem.canonlygoinpocket
        and (not item.components.inventoryitem.canonlygoinpocketorpocketcontainers or self.inst.components.inventoryitem and self.inst.components.inventoryitem.canonlygoinpocket)
        and not self.readonlycontainer
        and not (GetGameModeProperty("non_item_equips") and item.components.equippable ~= nil)
-- ★ 唯一调用 priorityfn 的地方。★ 注意它在**所有其他校验通过之后**才执行，
--   所以 priorityfn 可以假设「这物品本来就该进容器」，只需回答「是否优先」。
        and (self:priorityfn(item))
end

-- AcceptsStacks：★ 只是读蓝图字段的 getter，本文件不做任何栈逻辑。
--   实际栈处理在第 483/534/1130/1241/1265/1288/1431 行（都是「读它然后分支」）。
function Container:AcceptsStacks()
-- 返回：return self.acceptsstacks  〔所在：Container:AcceptsStacks〕
    return self.acceptsstacks
end

-- IsSideWidget：读蓝图字段 issidewidget。消费点：第 637/692 行传给 HUD。
function Container:IsSideWidget()
-- 返回：return self.issidewidget  〔所在：Container:IsSideWidget〕
    return self.issidewidget
end

-- 【★ DestroyContents：清空并销毁容器内容（不留掉落物）】
--   ★ 与 DropEverything 的本质区别：**这里 item:Remove() 实体直接消失**，
--     而 DropEverything 是丢到地上。对比第 338 行。
--   典型用途：箱子被砸毁时清场（游戏设计不希望爆一地东西）。
function Container:DestroyContents(onpredestroyitemcallbackfn)
-- 循环：for k = 1, self.numslots do  〔所在：Container:DestroyContents〕
    for k = 1, self.numslots do
-- 局部变量：local item = self:RemoveItemBySlot(k)  〔所在：Container:DestroyContents〕
        local item = self:RemoveItemBySlot(k)
-- 条件分支：if item ~= nil then  〔所在：Container:DestroyContents〕
        if item ~= nil then
-- ★ onpredestroyitemcallbackfn：在销毁**之前**回调，给调用方最后一次机会。
--   注意签名 (self.inst, item) —— 传入容器实体与物品。
--   ⚠ 用途推测：给 prefab 一个「记录被销毁了什么」的机会（如统计成就）。
            if onpredestroyitemcallbackfn ~= nil then
                onpredestroyitemcallbackfn(self.inst, item)
            end
-- ★ `if item:IsValid()` 再 Remove() —— 防悬空实体保护。
--   容器销毁过程中，槽内物品可能已被其他路径移除。
            if item:IsValid() then
                item:Remove()
            end
        end
    end
end

-- 【★ DestroyContentsConditionally：条件版销毁】
--   ★ filterfn == nil 时**退化为无条件销毁**（第 345-349 行）。
--   ⚠ 注意原注释「-- NOTES(JBK): Revert to unconditionally.」——
--     作者留了 TODO 说要把这段删掉改成无条件。当前行为无害（nil 时等价）。
function Container:DestroyContentsConditionally(filterfn, onpredestroyitemcallbackfn)
-- 条件分支：if filterfn == nil then  〔所在：Container:DestroyContentsConditionally〕
    if filterfn == nil then
-- ★ 原注释保留：「-- NOTES(JBK): Revert to unconditionally.」
--   → JBK 是 Klei 工程师的缩写。含义：这段 nil 兜底将来会删掉。
        -- NOTES(JBK): Revert to unconditionally.
        self:DestroyContents(onpredestroyitemcallbackfn)
-- 返回：return  〔所在：Container:DestroyContentsConditionally〕
        return
    end

-- 循环：for k = 1, self.numslots do  〔所在：Container:DestroyContentsConditionally〕
    for k = 1, self.numslots do
-- 局部变量：local testitem = self.slots[k]  〔所在：Container:DestroyContentsConditionally〕
        local testitem = self.slots[k]
-- ★ 先用 filterfn 筛，筛中才移除+销毁。与第 334 行的无条件版结构对称。
        if testitem and filterfn(self.inst, testitem) then
-- 局部变量：local item = self:RemoveItemBySlot(k)  〔所在：Container:DestroyContentsConditionally〕
            local item = self:RemoveItemBySlot(k)
-- 条件分支：if item ~= nil then  〔所在：Container:DestroyContentsConditionally〕
            if item ~= nil then
-- 条件分支：if onpredestroyitemcallbackfn ~= nil then  〔所在：Container:DestroyContentsConditionally〕
                if onpredestroyitemcallbackfn ~= nil then
                    onpredestroyitemcallbackfn(self.inst, item)
                end
-- 条件分支：if item:IsValid() then  〔所在：Container:DestroyContentsConditionally〕
                if item:IsValid() then
                    item:Remove()
                end
            end
        end
    end
end

-- 【ValidateItemForOverflow：溢出准入的额外校验】
--   ★ 注意它的第二个形参 overflow **完全没被使用** —— 只判物品，不判目标容器。
--   ⚠ 这与函数名给人的印象不符（「校验物品对某溢出的准入」），实际是「校验物品通用准入」。
--     当前无害（第 420/458 行调用时都紧接着做容器级判定），仅标注风格问题。
local function ValidateItemForOverflow(item, overflow)
-- ★ 没有 inventoryitem 组件时返回 true —— 原注释「should never happen, just return true XD」。
--   ★ 作者用「XD」表明这是**故意的宽松兜底**而非笔误。
--   ⇒ 设计取舍：与其在这里崩溃，不如放行让下游（GiveItem）去拒绝。
	if item.components.inventoryitem == nil then
-- 返回：return true --should never happen, just return true XD  〔所在：ValidateItemForOverflow〕
		return true --should never happen, just return true XD
-- ★★ 拒绝 pocketonly 物品（第 2 道门，与第 274 行同源）。
--   注意这里用 **or**：canonlygoinpocket **或** canonlygoinpocketorpocketcontainers 都拒。
--   对照第 274 行用 and（后者允许 pocket 容器收）——这里更严，因为溢出不区分容器类型。
	elseif item.components.inventoryitem.canonlygoinpocket or item.components.inventoryitem.canonlygoinpocketorpocketcontainers then
-- 返回：return false  〔所在：ValidateItemForOverflow〕
		return false
	end
-- 返回：return true  〔所在：ValidateItemForOverflow〕
	return true
end

-- ★ 原注释保留：「-- Check how many of an item we can accept from its stack.」
--   ⇒ CanAcceptCount 的问题不是「能不能放」而是「**还能收几个**」。
-- Check how many of an item we can accept from its stack.
-- 【★★★ CanAcceptCount：批量接收能力计算 —— 智能分配算法的基础】
--   ★ 用途：拆分一摞物品到 N 个容器时，先问每个容器能收几个（见 MoveItemFromCountOfSlot）。
--   ★ 返回 0 表示「一个都不收」；返回 stacksize 表示「整摞都收得下」。
--   ⚠ O(numslots × specialized) 复杂度，每帧调用会慢 —— 但只在拖拽时调用。
function Container:CanAcceptCount(item, maxcount)
-- ★ 只读容器直接返回 0：一个都收不了。
--   ★ 这是 readonlycontainer 的**第三条防线**（另两条见第 275/987 行）。
    if self.readonlycontainer then
-- 返回：return 0  〔所在：Container:CanAcceptCount〕
        return 0
    end

-- ★ stacksize = 物品当前堆叠数（非堆叠物按 1 算）。
	local stacksize = item.components.stackable and item.components.stackable:StackSize() or 1
-- ★★★ 槽位锁物品的特殊算法：`math.max(maxcount or math.huge, stacksize - 1)`。
--   翻译：当物品被锁（islockedinslot）时，收进来的数量应该是「已有的减一」，
--     也就是**允许把重复的一份追加进去、但不能把原来那份也一起算进来**。
--   ⇒ 配合第 285 行的「锁槽允许同类型追加」规则，形成一致语义。
--   ⚠ 这段逻辑高度晦涩，是全文件最难读懂的 3 行之一。若 maxcount 传入则取较大值。
	if item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- 局部赋值：stacksize = math.max(maxcount or math.huge, stacksize - 1)  〔所在：Container:CanAcceptCount〕
		stacksize = math.max(maxcount or math.huge, stacksize - 1)
-- 兜底分支（前述条件全不成立）。〔所在：Container:CanAcceptCount〕
	else
-- 局部赋值：stacksize = maxcount or stacksize  〔所在：Container:CanAcceptCount〕
		stacksize = maxcount or stacksize
	end
-- stacksize <= 0 → 返回 0。防止 maxcount=0 之类的不合法入参。
    if stacksize <= 0 then
-- 返回：return 0  〔所在：Container:CanAcceptCount〕
        return 0
    end

-- 局部变量：local acceptcount = 0  〔所在：Container:CanAcceptCount〕
    local acceptcount = 0

-- ★ 原注释保留：「--Check for empty space in the container.」
--   注意它同时处理两件事：**已有同类型的剩余空间** + **空槽位**。
    --Check for empty space in the container.
-- 循环：for k = 1, self.numslots do  〔所在：Container:CanAcceptCount〕
    for k = 1, self.numslots do
-- 局部变量：local v = self.slots[k]  〔所在：Container:CanAcceptCount〕
        local v = self.slots[k]

-- 条件分支：if v ~= nil then  〔所在：Container:CanAcceptCount〕
        if v ~= nil then
-- ★ 同类型堆叠：累加 RoomLeft()（还能再放几个）。
--   ★ RoomLeft = maxsize - stacksize，由 stackable 组件提供。
--   ⇒ 这就是「把一摞东西拆开塞进已有同类的摞里」的容量计算。
            if v.components.stackable ~= nil and v.components.stackable:CanStackWith(item) then
-- 局部赋值：acceptcount = acceptcount + v.components.stackable:RoomLeft()  〔所在：Container:CanAcceptCount〕
                acceptcount = acceptcount + v.components.stackable:RoomLeft()
-- ★ 累加够整摞就**提前返回 stacksize** —— 短路优化，也是语义「全收得下」。
                if acceptcount >= stacksize then
-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕
                    return stacksize
                end
            end

-- ★★ 空槽位分支：走完整的 CanTakeItemInSlot（含 itemtestfn）。
--   ⇒ **itemtestfn 在这里被第二次调用**（第一次在第 450 行 GiveItem 入口）。
--     所以「查询能收几个」也会触发用户定义的筛选规则（可能有副作用，如第 227 行的 GetOpeners）。
        elseif self:CanTakeItemInSlot(item, k) then
-- ★★ acceptsstacks 为 false 时，**只能收 1 个**（`or stacksize <= 1` 是单件物品的例外）。
--   ⇒ 这就是「晾肉架一次只能放一块肉」的实现，与 GiveItem 第 534 行配套。
            if self.acceptsstacks or stacksize <= 1 then
-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕
                return stacksize
            end
-- 局部赋值：acceptcount = acceptcount + 1  〔所在：Container:CanAcceptCount〕
            acceptcount = acceptcount + 1
-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕
            if acceptcount >= stacksize then
-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕
                return stacksize
            end
        end
    end
-- ★★ itemtestfn 调用时机全表（服务端组件侧，共 11 处调用 CanTakeItemInSlot）：
--   ┌ 场景                        │ 调用行   │ 何时触发
--   ├─────────────────────────────┼──────────┼──────────────────────
--   │ GiveItem 入口准入           │ 450      │ 任何程序化放入
--   │ GetSpecificSlotForItem 选槽 │ 301      │ 每次需要定专用槽
--   │ CanAcceptCount 查剩余空间   │ 406/430  │ 拖拽悬停 / 拆分前
--   │ PutOneOfActiveItemInSlot    │ 1106     │ 玩家点击（放一个）
--   │ PutAllOfActiveItemInSlot    │ 1129     │ 玩家点击（全放）
--   │ AddOneOfActiveItemToSlot    │ 1238     │ 玩家点击（加一个）
--   │ AddAllOfActiveItemToSlot    │ 1262     │ 玩家点击（全加）
--   │ SwapActiveItemWithSlot      │ 1285     │ Ctrl+点击
--   │ SwapOneOfActiveItemWithSlot │ 1316     │ Ctrl+点击（换1个）
--   │ MoveItemFromAllOfSlot       │ 1354     │ 跨容器拖拽（全量）
--   │ MoveItemFromHalfOfSlot      │ 1433     │ 跨容器拖拽（一半）
--   │ MoveItemFromCountOfSlot     │ 1497     │ 跨容器拖拽（N 个）
--   └─────────────────────────────┴──────────┴──────────────────────
--   ⇒ ★★ 结论：**itemtestfn 是容器系统唯一的物品准入判据**，
--     12 个入口无一例外。这就是任务问「itemtestfn 的调用时机」的完整答案。

-- 【★ 第二阶段：把「专用容器」也算进容量】
--   ★ 这让「弹药包里的弹药」也计入背包的接收能力 —— 嵌套容器被视为背包的一部分。
--   ⚠ 注意 GetSpecializedContainers 返回的是**组件**而非实体（第 810 行）。
	local specialized = self:GetSpecializedContainers()
-- 条件分支：if specialized then  〔所在：Container:CanAcceptCount〕
	if specialized then
-- 循环：for _, spoverflow in ipairs(specialized) do  〔所在：Container:CanAcceptCount〕
		for _, spoverflow in ipairs(specialized) do
-- ★ ShouldPrioritizeContainer(item)：这个专用容器是否优先收这个物品。
--   ★ 与第 430 行 CanTakeItemInSlot 并列：两个判定都过才计入容量。
			if spoverflow:ShouldPrioritizeContainer(item) and ValidateItemForOverflow(item, spoverflow) then
-- 循环：for k = 1, spoverflow.numslots do  〔所在：Container:CanAcceptCount〕
				for k = 1, spoverflow.numslots do
-- 局部变量：local v = spoverflow.slots[k]  〔所在：Container:CanAcceptCount〕
					local v = spoverflow.slots[k]
-- 条件分支：if v then  〔所在：Container:CanAcceptCount〕
					if v then
-- 专用容器的堆叠空间累加（结构与第 399 行逐字对称）。
						if v.components.stackable and v.components.stackable:CanStackWith(item) then
-- 局部赋值：acceptcount = acceptcount + v.components.stackable:RoomLeft()  〔所在：Container:CanAcceptCount〕
							acceptcount = acceptcount + v.components.stackable:RoomLeft()
-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕
							if acceptcount >= stacksize then
-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕
								return stacksize
							end
						end
-- ★ 专用容器的空槽检查，同样走 CanTakeItemInSlot → itemtestfn。
					elseif spoverflow:CanTakeItemInSlot(item, k) then
-- 条件分支：if spoverflow.acceptsstacks or stacksize <= 1 then  〔所在：Container:CanAcceptCount〕
						if spoverflow.acceptsstacks or stacksize <= 1 then
-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕
							return stacksize
						end
-- 局部赋值：acceptcount = acceptcount + 1  〔所在：Container:CanAcceptCount〕
						acceptcount = acceptcount + 1
-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕
						if acceptcount >= stacksize then
-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕
							return stacksize
						end
					end
				end
			end
		end
	end

-- ★ 返回累计的 acceptcount（不是布尔）。调用方用它决定「拆几个过去」。
--   ⚠ 注意：若既没有堆叠空间也没有空槽，返回 0，调用方据此放弃。
    return acceptcount
-- ★★ 至此 CanAcceptCount 的完整算法：
--   阶段一（本容器）：① 同类摞的 RoomLeft 之和 ② 空槽位数（不收整摞时每槽只算 1）
--   阶段二（专用容器）：同样的两轮，但只对 ShouldPrioritizeContainer 通过的容器做
--   ⇒ ★ 推论：**专用容器的内容物算进背包的接收能力**，
--     所以「背包显示还有位置」实际包含了弹药包的空位。
end

-- 【★★★ GiveItem —— 容器系统最核心的写入函数】
--   ★ 它是「所有放入路径的最终收敛点」：无论从哪来，最后都走这里。
--   ★ 它的复杂度来自三个正交维度：
--     ① **目标槽**：指定槽 / 专用槽（GetSpecificSlotForItem）/ 自动找空位；
--     ② **堆叠合并**：能否并入已有同类摞；
--     ③ **溢出**：本容器放不下时，是否转交给嵌套的专用容器。
--   ⇒ 下面的逐段注释按这三个维度展开。
function Container:GiveItem(item, slot, src_pos, drop_on_fail)
-- item 为 nil 直接失败。（防御性：调用方多会先判，但这里再判一次。）
    if item == nil then
-- 返回：return false  〔所在：Container:GiveItem〕
        return false
-- ★★★ 唯一的准入检查：`item.components.inventoryitem ~= nil and self:CanTakeItemInSlot(...)`。
--   ⚠ 注意这是 **and**：没有 inventoryitem 组件的物品**静默失败**（走到第 558 行落地），
--     因为整个 if 块被跳过。这是合理的：不能进容器的物品掉地上。
    elseif item.components.inventoryitem ~= nil and self:CanTakeItemInSlot(item, slot) then
-- ★ 槽位决策第 1 优先级：调用方指定的 slot；没指定则试「专用槽」。
--   ⇒ 注意顺序：指定的 slot **优先于**专用槽。所以「强制放第 3 格」会覆盖语义槽。
--   ★ 这个顺序在 MoveItemFromAllOfSlot 第 1348 行被利用：先算出 targetslot。
        slot = slot or self:GetSpecificSlotForItem(item)

-- ★ slot == nil 分支 = 「没有指定槽，也没有专用槽」→ 尝试溢出到专用容器。
--   ★ 这是「背包里的弹药包自动吸走弹药」的实现位置。
		if slot == nil then
			--specialized containers
-- 取出本容器内的专用容器列表（第 801 行：扫描 1..numslots 找有 priorityfn 的）。
			local specialized = self:GetSpecializedContainers()
-- 条件分支：if specialized then  〔所在：Container:GiveItem〕
			if specialized then
-- ★ 逐个尝试：ShouldPrioritizeContainer + ValidateItemForOverflow 双判定。
--   ⇒ 这两个判定都过，才真的把物品塞进去。
				for _, spoverflow in ipairs(specialized) do
-- 条件分支：if spoverflow:ShouldPrioritizeContainer(item) and ValidateItemForOverflow(item, spoverflow) then  〔所在：Container:GiveItem〕
					if spoverflow:ShouldPrioritizeContainer(item) and ValidateItemForOverflow(item, spoverflow) then
-- ★★ 记住放入**前**的堆叠数 num，用于第 461 行判断「有没有变化」。
--   这是「部分成功」的检测手段：如果 GiveItem 后数量没变，说明一个都没收。
						local num = item.components.stackable and item.components.stackable:StackSize() or 1
-- ★ 递归调用 spoverflow:GiveItem(item, nil, src_pos, false)。
--   ⚠ 第 4 参数 drop_on_fail=false —— **失败时不落地**。
--   ⇒ 关键设计：溢出失败不能把物品丢在背包脚下，必须留给后续流程处理。
						local finished = spoverflow:GiveItem(item, nil, src_pos, false)
-- ★★★ `finished or 数量变了` —— 「有任何进展」判定。
--   · finished = 专用容器返回 true（明确成功）；
--   · 数量变了 = 部分成功（拆了一部分进去）。
--   ⇒ 两者都触发第 462-473 行的「闭容器收物动画」通知。
						if finished or (item.components.stackable and item.components.stackable:StackSize() or 1) ~= num then
-- ★★ SpawnPrefab("container_closed_receiveitem_classified") —— 网络特效实体。
--   ★ 用途：让**其他客户端**看到「有个东西被塞进了关闭的容器」。
--   它是 classified（只对特定客户端可见）的短命实体，由 prefabs/container_closed_receiveitem_classified.lua
--     消费（第 8-33 行的 OnItemDirty 处理动画）。
--   ⇒ 这是容器系统里唯一「主动发网络实体」的地方，值得特别注意。
							local receiveitemonopen = SpawnPrefab("container_closed_receiveitem_classified")
							receiveitemonopen.entity:SetParent(self.inst.entity)
							receiveitemonopen.item:set(spoverflow.inst)
-- ★ isclosed=true 表示「容器保持关闭状态，只播图标动画」。
--   另一个值 false 会强制打开容器并把物品动画化地飞进去。
							receiveitemonopen.isclosed:set(true)

-- ★★ 条件链：① 物品存在 ② 专用容器**没被**当前玩家打开 ③ 本容器**被**当前玩家打开。
--   ⇒ 即：「你正看着自己的背包，但你的弹药包是关着的」。
							if ThePlayer and not spoverflow:IsOpenedBy(ThePlayer) and self:IsOpenedBy(ThePlayer) then
-- ★ GetGrandOwner()：向上追溯「这个容器最终归谁」（背包→玩家→？）。
--   用于判断「物品是不是在别人的背包里」（第 469 行 owner == nil 或无 container）。
								local owner = self.inst.components.inventoryitem and self.inst.components.inventoryitem:GetGrandOwner()
-- ⚠ `if owner == nil or owner.components.container` —— 意图是「owner 不是玩家本体」。
--   推理：GetGrandOwner 返回玩家的 inventory item 或玩家实体。
--     若返回 nil（无主）→ 也算；若有 container 组件 → 说明是「被别人装着的容器」。
--   ⚠ 逻辑可疑：如果 owner 是玩家**自己**，它有没有 components.container？
--     玩家实体通常没有 container 组件，所以自己身上也会满足条件 → 通知自己。
--     这与第 467 行「你不是专用容器的 opener」组合后，实际效果尚可；但语义不严谨。
--     ★ 判定为 ⚠ 疑似缺陷（语义含混），不改代码。
								if owner == nil or owner.components.container then
									spoverflow.inst:PushEvent("container_got_item_while_closed")
								end
							end
						end
-- ★ 专用容器明确报告成功 → GiveItem 整体返回 true，提前结束。
						if finished then
-- 返回：return true  〔所在：Container:GiveItem〕
							return true
						end
					end
				end
			end
		end

-- ★ 原注释保留：「--try to burn off stacks if we're just dumping it in there」
--   → 「burn off」是俚语，指把多余堆叠**消化掉**（并进已有摞）。
--   ⇒ 这一段是「指定槽已有同类摞且未满」的合并路径。
        --try to burn off stacks if we're just dumping it in there
-- ★★ 两道前置：物品可堆叠 **且** 本容器接受整摞。
--   ⇒ acceptsstacks=false 的容器完全跳过合并逻辑（物品只能一格一件）。
        if item.components.stackable ~= nil and self.acceptsstacks then
-- ★ 原注释保留（三行）：「Added this for when we want to dump a stack back into a
--   specific spot (e.g. moving half a stack failed, so we need to dump the leftovers
--   back into the original stack)」
--   → 这解释了第 487-501 行整段代码的**真实用途**：
--     「移动半摞失败 → 把剩下的塞回原来的摞里」，而不是留在原地。
--   ★ 这是一个为「MoveItemFromHalfOfSlot 失败回滚」服务的分支（第 1454 行调用）。
            --Added this for when we want to dump a stack back into a
            --specific spot (e.g. moving half a stack failed, so we
            --need to dump the leftovers back into the original stack)
-- ★ slot 在范围内才尝试合并（否则说明目标槽不存在）。
            if slot ~= nil and slot <= self.numslots then
-- 局部变量：local other_item = self.slots[slot]  〔所在：Container:GiveItem〕
                local other_item = self.slots[slot]
-- ★ 同类型 + 目标摞未满 —— 三个条件缺一不可。
                if other_item ~= nil and item.components.stackable:CanStackWith(other_item) and not other_item.components.stackable:IsFull() then
-- ★ 若本容器自己被装在别人身上（owner 存在），给 owner 推 gotnewitem 事件。
--   ⇒ 用于播放「物品进入背包」的音效/提示（inventoryitem 的 OnPutInInventory 也会触发）。
                    if self.inst.components.inventoryitem ~= nil and self.inst.components.inventoryitem.owner ~= nil then
                        self.inst.components.inventoryitem.owner:PushEvent("gotnewitem", { item = item, slot = slot })
                    end

-- ★★ stackable:Put(item) —— 把 item 合并进 other_item。
--   ★ 返回值语义（stackable.lua:Put）：**返回溢出的部分，nil 表示全被吃下**。
--     所以第 495 行 `if item == nil then return true` 表示「全并进去了，成功」。
--   ⚠ 若返回溢出部分，item 变量被重新赋值，流程继续往下走（第 499 行重算专用槽）。
                    item = other_item.components.stackable:Put(item, src_pos)
-- 条件分支：if item == nil then  〔所在：Container:GiveItem〕
                    if item == nil then
-- 返回：return true  〔所在：Container:GiveItem〕
                        return true
                    end

-- ★ 合并后如果还有溢出，**重新算专用槽** —— 因为剩下的可能属于另一种物品。
--   ⚠ 但这里没有再算「自动空位」，slot 仍是 nil（若原来有 slot 则保留）。
                    slot = self:GetSpecificSlotForItem(item)
                end
            end

-- ★ slot == nil 分支：不限槽地扫描所有槽，找第一个可合并的。
--   ⚠ 注意此处**合并后不 return**，继续循环下一个槽（第 511 行在 for 内），
--     所以「一摞东西会依次填满所有同类摞」——这是期望行为。
            if slot == nil then
-- 循环：for k = 1, self.numslots do  〔所在：Container:GiveItem〕
                for k = 1, self.numslots do
-- 局部变量：local other_item = self.slots[k]  〔所在：Container:GiveItem〕
                    local other_item = self.slots[k]
-- 条件分支：if other_item and item.components.stackable:CanStackWith(other_item) and not other_item.components.stackable:IsFull() then  〔所在：Container:GiveItem〕
                    if other_item and item.components.stackable:CanStackWith(other_item) and not other_item.components.stackable:IsFull() then
-- 条件分支：if self.inst.components.inventoryitem ~= nil and self.inst.components.inventoryitem.owner ~= nil then  〔所在：Container:GiveItem〕
                        if self.inst.components.inventoryitem ~= nil and self.inst.components.inventoryitem.owner ~= nil then
                            self.inst.components.inventoryitem.owner:PushEvent("gotnewitem", { item = item, slot = k })
                        end

-- Put 同样返回溢出部分；返回 nil（全部并入）则第 512 行 return true。
                        item = other_item.components.stackable:Put(item, src_pos)
-- 条件分支：if item == nil then  〔所在：Container:GiveItem〕
                        if item == nil then
-- 返回：return true  〔所在：Container:GiveItem〕
                            return true
                        end
                    end
                end
            end
        end

-- ★★ 最终选位：三条互斥路径 ——
--   ① 指定槽且未被占 → 用它（第 521 行）；
--   ② 不要求专用槽且有槽位 → 找**第一个空槽**（第 524-529 行有序 for）；
--   ③ 都不满足 → in_slot 为 nil，走到第 558 行落地。
        local in_slot = nil
-- ⚠ 潜在缺陷：条件只检查 `not self.slots[slot]`，**没检查 slot 是否是合法语义槽**。
--   推理：第 451 行已通过 GetSpecificSlotForItem 保证了语义，但若调用方
--     直接传了一个 itemtestfn 不接受、且恰好为空的 slot，此处仍会放进去。
--   ⇒ 不过第 450 行的 CanTakeItemInSlot(item, slot) **已经用同一个 slot 验过 itemtestfn**，
--     所以实际是安全的。前置检查覆盖了后置假设。仅作推理记录。
        if slot ~= nil and slot <= self.numslots and not self.slots[slot] then
-- 局部赋值：in_slot = slot  〔所在：Container:GiveItem〕
            in_slot = slot
-- ★★ `not self.usespecificslotsforitems` —— 有语义的槽位容器**不做自动找空位**。
--   ⇒ 语义容器的物品必须由 itemtestfn 指定槽位，否则宁可不放（第 532 行 in_slot 为 nil）。
--     这是「香料锅不会把香料放进食材槽」的强制保证。
        elseif not self.usespecificslotsforitems and self.numslots > 0 then
-- 循环：for i = 1, self.numslots do  〔所在：Container:GiveItem〕
            for i = 1, self.numslots do
-- ★ 用有序 for 找第一个空槽（**不是** pairs）—— 因为「第一个」需要确定性。
--   ⇒ 视觉后果：物品总是填满从上到下、从左到右，不会留随机空洞。
                if not self.slots[i] then
-- 局部赋值：in_slot = i  〔所在：Container:GiveItem〕
                    in_slot = i
                    break
                end
            end
        end

-- ★ 找到了可用的槽位。
        if in_slot then
            --weird case where we are trying to force a stack into a non-stacking container. this should probably have been handled earlier, but this is a failsafe
-- ★★★ 兜底分支：非堆叠容器被迫接收超量堆叠时，Get 一个塞进去。
--   ★ 原注释保留：「--weird case where we are trying to force a stack into a non-stacking
--     container. this should probably have been handled earlier, but this is a failsafe」
--   → 作者自认这是**补丁**：正常路径不该走到这里。
--   ⚠ 关键：函数**返回 false**（第 539 行）——明明放进去一个却报告失败。
--     这是刻意的语义：「我只放进去 1/N，调用方应该知道还有剩余要处理」。
--     对照 MoveItemFromAllOfSlot 第 1384 行：收到 false 会走回滚逻辑（第 1386 行）。
            if not self.acceptsstacks and item.components.stackable and item.components.stackable:StackSize() > 1 then
-- 局部赋值：item = item.components.stackable:Get()  〔所在：Container:GiveItem〕
                item = item.components.stackable:Get()
                self.slots[in_slot] = item
                item.components.inventoryitem:OnPutInInventory(self.inst)
-- self.inst:PushEvent("itemget", { slot = in_slot, item = item, src_pos = src_pos, })  〔所在：Container:GiveItem〕
                self.inst:PushEvent("itemget", { slot = in_slot, item = item, src_pos = src_pos, })
-- 返回：return false  〔所在：Container:GiveItem〕
                return false
            end

            self.slots[in_slot] = item
-- ★ infinitestacksize 容器：新放入的堆叠立刻解除 maxsize 限制（第 36 行的只读开关）。
--   ⇒ 「无限堆叠容器」的实现点之一（另见第 1041 行取出时恢复）。
			if self.infinitestacksize and item.components.stackable then
				item.components.stackable:SetIgnoreMaxSize(true)
			end
-- ★ OnPutInInventory(self.inst) —— 把「主人」改成容器自己。
--   ★ 后果：物品的 prevslot 会被设置（inventoryitem.lua:315），可被 GetSlotNum 读到。
            item.components.inventoryitem:OnPutInInventory(self.inst)
-- ★★★ PushEvent("itemget", {slot, item, src_pos}) —— 联机同步的事件源。
--   ★★★ **本文件不写任何 netvar**，全靠这个事件。转写发生在：
--     components/container_replica.lua:30-36 的 _onitemget：
--       `self.classified:SetSlotItem(data.slot, data.item, data.src_pos)`
--   ⇒ 这就是「服务端组件只产生事件，replica 转成网络」的完整链路。
--   ⚠ ⚠ 注意 src_pos 也被同步（container_classified.lua 的 slot 数据含位置），
--     客户端用它做物品「飞入」动画。
            self.inst:PushEvent("itemget", { slot = in_slot, item = item, src_pos = src_pos })

-- ★ 音效：仅当本容器有 inventoryitem.owner（说明它自己被装在玩家身上）时播。
--   ★ ignoresound（第 63 行）是搬运事务用的临时静音开关（第 1112 行设置）。
            if not self.ignoresound and self.inst.components.inventoryitem ~= nil and self.inst.components.inventoryitem.owner ~= nil then
                self.inst.components.inventoryitem.owner:PushEvent("gotnewitem", { item = item, slot = in_slot })
            end

-- 返回：return true  〔所在：Container:GiveItem〕
            return true
        end
    end

-- ★ 原注释保留：「--default to true if nil」
--   ⇒ drop_on_fail 语义：nil/false = 不落地，**其他一律落地**。
--   ⚠ 注意是 `~= false` 而非真值判断 —— 所以 drop_on_fail=nil 也会落地。
    --default to true if nil
-- 条件分支：if drop_on_fail ~= false then  〔所在：Container:GiveItem〕
    if drop_on_fail ~= false then
-- ★ 原注释保留：「--@V2C NOTE: not supported when container_proxy」
--   与第 222 行同因：客户端影子实体的坐标是 (0,0,0)。
        --@V2C NOTE: not supported when using container_proxy
-- ★★ 失败落地前先 DropOverstackedExcess：把超量堆叠的多余部分先吐出来。
--   ⇒ 顺序很重要：先吐料再落地，否则落地的是整摞，吐料会丢在别处。
		self:DropOverstackedExcess(item)
-- ★ 物品落到**容器自己的世界坐标**（而非 src_pos）。
--   ⇒ 与第 558 行的语义呼应：放不进容器的东西落在容器脚下。
        item.Transform:SetPosition(self.inst.Transform:GetWorldPosition())
-- 条件分支：if item.components.inventoryitem ~= nil then  〔所在：Container:GiveItem〕
        if item.components.inventoryitem ~= nil then
            item.components.inventoryitem:OnDropped(true)
        end
    end
-- ★★ 失败返回 false（与第 539 行的「部分成功」区分不开 —— 两者都返回 false）。
--   ⚠ 这是本函数 API 的一个**已知粗糙处**：调用方无法区分「一个没放」与「放了一个但报失败」。
--     目前靠第 461 行「比较堆叠数变化」来补救（那是在溢出路径里）。
--     直接调用 GiveItem 的路径（第 1384 行）则只能靠回滚兜住。
-- ★★ 至此 GiveItem 的完整决策树（供速查）：
--   1. item 为 nil？→ false
--   2. 无 inventoryitem 或 CanTakeItemInSlot 不过？→ 落到第 558 行落地 + false
--   3. 有 slot / 能算专用槽？→ 有则先试溢出到专用容器（第 453-480 行）
--   4. 可堆叠且 acceptsstacks？→ 试合并进已有同类摞（第 483-518 行）
--   5. 能定槽？→ 放进去；若是超量堆叠进非堆叠容器，只放 1 个并 **返回 false**
--   6. 以上全败 → 落地 + false
    return false
end

-- 【★ RemoveItemBySlot：按槽号移除，支持整摞/单个】
--   ★ 第 570 行 `slot and self.slots[slot] or nil`：slot 为 nil 时短路为 nil，
--     不会报错。这是 Lua 的 and/or 惯用法在此的妙用。
function Container:RemoveItemBySlot(slot, keepoverstacked)
-- 局部变量：local item = slot and self.slots[slot] or nil  〔所在：Container:RemoveItemBySlot〕
	local item = slot and self.slots[slot] or nil
-- 条件分支：if item then  〔所在：Container:RemoveItemBySlot〕
	if item then
-- ★ wholestack=true → 整摞移除（DropItemBySlot 第 129 行用 true；
--   而 RemoveItem 的默认（nil）表示只取 1 个，见第 957/1028 行）。
		return self:RemoveItem_Internal(item, slot, true, keepoverstacked)
	end

-- 返回：return nil  〔所在：Container:RemoveItemBySlot〕
    return nil
end

-- 【★ RemoveAllItems：一次性取出全部，返回实体列表】
--   ⚠ 疑似缺陷：`table.insert(collected_items, item)` —— 当 item 为 nil（空槽）时
--     **Lua 的 table.insert(t, nil) 会报错还是插入 nil？**
--     在标准 Lua 5.1 中 `table.insert(t, nil)` 是**合法的**（等价 t[#t+1]=nil），
--     但会使 #t 不可靠；某些实现会抛「wrong number of arguments」。
--     ⇒ 若当前引擎允许，则返回的表里有空洞（不是真正的列表）；
--       若抛错，则空容器调用 RemoveAllItems 会崩。
--     推理：本文件其他地方（GetAllItems 第 609 行）都显式 `if v ~= nil` 过滤，
--     唯独这里没有——**强烈暗示作者预期这里总有值或没测过空容器**。
--     ★ 判定为 ⚠ 疑似缺陷。不改代码。
function Container:RemoveAllItems()
-- 局部变量：local collected_items = {}  〔所在：Container:RemoveAllItems〕
    local collected_items = {}
-- 循环：for i = 1, self.numslots do  〔所在：Container:RemoveAllItems〕
    for i = 1, self.numslots do
-- 局部变量：local item = self:RemoveItemBySlot(i)  〔所在：Container:RemoveAllItems〕
        local item = self:RemoveItemBySlot(i)
-- table.insert(collected_items, item)  〔所在：Container:RemoveAllItems〕
        table.insert(collected_items, item)
    end

-- 返回：return collected_items  〔所在：Container:RemoveAllItems〕
    return collected_items
end

-- GetNumSlots：读 numslots。容器组件与 inventory 组件同名接口，便于统一抽象。
function Container:GetNumSlots()
-- 返回：return self.numslots  〔所在：Container:GetNumSlots〕
    return self.numslots
end

-- GetItemInSlot：★ 双重真值判断（`slot and self.slots[slot]`），
--   slot 为 nil 或该槽为空都返回 nil（不是 false）。调用方直接判真值即可。
function Container:GetItemInSlot(slot)
-- 条件分支：if slot and self.slots[slot] then  〔所在：Container:GetItemInSlot〕
    if slot and self.slots[slot] then
-- 返回：return self.slots[slot]  〔所在：Container:GetItemInSlot〕
        return self.slots[slot]
    end
end

-- 【★ GetItemSlot：反向查询「某物品在第几槽」】
--   ★ 用 pairs 遍历（无序）—— 但只要找到**一个**匹配就返回，顺序无关。
--   ⇒ 这是本文件中少数「遍历顺序不影响正确性」的用法。
--   ⚠ O(n) 复杂度，是移除路径（第 1011 行）的固定开销。
function Container:GetItemSlot(item)
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetItemSlot〕
    for k,v in pairs(self.slots) do
-- 条件分支：if item == v then  〔所在：Container:GetItemSlot〕
        if item == v then
-- 返回：return k  〔所在：Container:GetItemSlot〕
            return k
        end
    end
end

-- GetAllItems：★ 与 RemoveAllItems（第 578 行）不同，这里**过滤了 nil**（第 609 行）。
--   ⇒ 对照可见第 578 行的 nil 过滤确实缺失，两者本应一致。强化了上条的判定。
function Container:GetAllItems()
-- 局部变量：local collected_items = {}  〔所在：Container:GetAllItems〕
    local collected_items = {}
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetAllItems〕
    for k,v in pairs(self.slots) do
-- 条件分支：if v ~= nil then  〔所在：Container:GetAllItems〕
        if v ~= nil then
-- table.insert(collected_items, v)  〔所在：Container:GetAllItems〕
            table.insert(collected_items, v)
        end
    end

-- 返回：return collected_items  〔所在：Container:GetAllItems〕
    return collected_items
end

-- 【★★★ Open —— 容器打开的完整流程（八步）】
--   ① 防重入（第 618 行 openlist 检查）；
--   ② 启动 onupdate（自动关闭的巡检器）；
--   ③ **同类互斥**：关掉同 prefab 或同 type 的旧容器（第 624-628 行）；
--   ④ 登记 openlist + opencount + 通知 replica；
--   ⑤ **UI**：HUD:OpenContainer（第 637 行）；
--   ⑥ **音效**（第 639-649 行）；
--   ⑦ 事件与回调（第 656-664 行）。
--   ★ 全程**不发网络包**——同步靠第 634 行的 replica:AddOpener。
function Container:Open(doer)
-- ★★ 防重入：`doer ~= nil and self.openlist[doer] == nil`。
--   已打开过的人再 Open 是**静默无操作**（不是报错、不是重复计数）。
    if doer ~= nil and self.openlist[doer] == nil then
-- ★★ skipautoclose 恒为 nil（构造函数第 34 行已注释该字段的初始化）——
--   ⚠ 这意味着 `not nil` 恒真，**StartUpdatingComponent 永远执行**。
--   ⇒ 即：所有容器都会开启每帧巡检（第 1059 行 OnUpdate）以支持自动关闭。
--   ⚠ 这个字段是**死配置**：读它的代码（第 619 行）以为它在起作用。
--     grep 核实：本文件内 skipautoclose 只出现在第 34 行（注释）与第 619 行（读）。
--     ★ 判定为 ⚠ 疑似缺陷（死字段）。与 containers.lua:50 droponopen 同类。不改代码。
        if not self.skipautoclose then
            self.inst:StartUpdatingComponent(self)
        end
-- ★ 取出打开者的物品栏组件。没有 inventory（NPC？）就跳过同类互斥与登记。
        local inventory = doer.components.inventory
-- 条件分支：if inventory ~= nil then  〔所在：Container:Open〕
        if inventory ~= nil then
-- ★★ 遍历「该玩家当前已打开的所有容器」。
--   inventory.opencontainers 是一个 {容器实体 → true} 的表（第 630 行登记）。
            for k in pairs(inventory.opencontainers) do
-- ★★★ 同类互斥的核心判据：`k.prefab == self.inst.prefab or k.components.container.type == self.type`。
--   ⇒ ① 同 prefab 一定互斥（两个背包不能同时开）；
--     ② 同 type 也互斥（所以两个 type="chest" 的箱子不能同开）。
--   ⚠ 潜在缺陷：若两个容器的 type **都是 nil**（未配蓝图），`nil == nil` 为真 →
--     会被判为同类而互斥。当前所有容器都配了 type（grep 核实无遗漏），故无害。
--     ★ 但这是一个「默认值导致意外相等」的典型隐患。仅标注，不改代码。
--   ★⚠ 另一处隐患：k 是 opencontainers 的键（实体），而这里假定它必有 container 组件。
--     若某实体因异常进入了 opencontainers 但没 container 组件 → nil 索引崩溃。
--     当前登记入口只有第 630 行（self.inst，必有组件），安全。
                if k.prefab == self.inst.prefab or k.components.container.type == self.type then
                    k.components.container:Close(doer)
                end
            end

-- ★ 登记到玩家的 opencontainers —— 这是「同类互斥」的数据基础。
--   ⇒ 与第 708 行的清理配对。
            inventory.opencontainers[self.inst] = true
        end
        self.openlist[doer] = true
-- ★ opencount 递增。注意它与 openlist 严格同步（第 683-684 行成对减）。
        self.opencount = self.opencount + 1
-- ★★★ 联机同步的第一步：通知客户端镜像「这个人打开了」。
--   → container_replica.lua:191 AddOpener → 生成/复用 prefabs/container_opener.lua 实体，
--     并把 classified 的可见目标改成这个 opener（第 62 行 SetClassifiedTarget）。
--   ⇒ ★ 这解释了一个设计：**每个打开者有一个独立的 classified 目标**，
--     所以多人同时开同一个箱子时，各自看到的内容可以不同（比如各自的可视化范围）。
        self.inst.replica.container:AddOpener(doer)

-- ★★ 只有**有 HUD 的实体**（玩家）才走 UI 分支；NPC 走第 650 行的 playeractionpicker 分支。
--   ⇒ 这是「服务端也要支持 NPC 开箱子」的设计：AI 用 playeractionpicker 而非 HUD。
        if doer.HUD ~= nil then
-- ★★★ UI 挂载的唯一调用点：`doer.HUD:OpenContainer(self.inst, self:IsSideWidget())`。
--   ⇒ screens/playerhud.lua:385 OpenContainerWidget 里据此选 containerroot 或 containerroot_side，
--     再按容器 type（第 392-400 行）细分到具体挂点。
--   ★ 也就是说：**type 决定「挂在哪个控件下」，issidewidget 决定「哪一侧」。**
--   ⚠ 绘制、动画、鼠标捕获全在 widgets/containerwidget.lua，本文件不碰。
            doer.HUD:OpenContainer(self.inst, self:IsSideWidget())
-- ★ refreshcrafting：打开容器会刷新合成面板。
--   ⇒ 原因：容器里的物品可能满足合成材料（见第 417 行的溢出逻辑）。
--     ⚠ 这也说明**合成会看容器内容**（GetCraftingIngredient 第 920 行的用途）。
            doer:PushEvent("refreshcrafting")
-- ★★★ 音效的三级回退（这是本文件最精细的一处 UI 处理）：
--   ① 皮肤音效 SKIN_SOUND_FX[AnimState:GetSkinBuild()].open_ui（第 642 行）；
--   ② 蓝图自定义 widget.opensound（第 645 行）；
--   ③ 侧边 UI 用背包音、中央 UI 用通用容器音（第 646-647 行）。
--   ⇒ ★ 这解释了 containers.lua:508-513 的 V2C 注释为何要覆盖 opensound：
--     蓝图值会**压过**默认音，但**低于**皮肤音效。
			if not self.inst.replica.container:ShouldSkipOpenSnd() then
-- ★★ 原注释保留（FIXME 标记）：「-- FIXME(JBK): The changes here need a way to tie
--   the self.widget back to the entity to GetSkinBuild from for other containers like
--   pillar and bundle wraps. Replicate to the other three spots in container and
--   container_replica.」
--   → 作者自认这段逻辑在 container / container_replica 里**重复了 4 份**（open/close × 两文件），
--     且「皮肤音效」取不到某些容器的 skin build。
--   ★ 这是本文件最诚实的一段注释：明确指出了自己的重复与局限。
                -- FIXME(JBK): The changes here need a way to tie the self.widget back to the entity to GetSkinBuild from for other containers like pillar and bundle wraps.
                -- Replicate to the other three spots in container and container_replica.
-- ★ SKIN_SOUND_FX[skinbuild].open_ui —— 皮肤专属 UI 音效，优先级最高。
--   ⚠ `self.inst.AnimState and ...` —— 防御性：没有 AnimState 的实体（如纯数据实体）跳过。
--   prefabskin.lua:18 定义 SKIN_SOUND_FX。
				local skinsound = self.inst.AnimState and SKIN_SOUND_FX[self.inst.AnimState:GetSkinBuild()] or nil
-- ★ TheFocalPoint.SoundEmitter —— 发声点固定在摄像机焦点，而非容器位置。
--   ⇒ UI 音效应当在「屏幕空间」播放，与容器在世界里的位置无关。
				TheFocalPoint.SoundEmitter:PlaySound(
					skinsound and skinsound.open_ui or
					(self.widget ~= nil and self.widget.opensound) or
					(self:IsSideWidget() and "dontstarve/wilson/backpack_open") or
					"dontstarve/HUD/Together_HUD/container_open"
				)
            end
-- ★★ 无 HUD 分支（NPC/AI）：把容器注册进 playeractionpicker。
--   ⇒ playeractionpicker 是 AI 的「动作选择器」，注册后 AI 能对此容器执行动作。
--   ⚠ 注意这里的条件是 `doer.components.playeractionpicker ~= nil`，
--     与第 652 行的 elseif 条件构成完整的 if/elseif/else 三分支。
        elseif self.widget ~= nil
            and self.widget.buttoninfo ~= nil
            and doer.components.playeractionpicker ~= nil then
            doer.components.playeractionpicker:RegisterContainer(self.inst)
        end

-- ★ PushEvent("onopen") —— 实体事件，任何 prefab 都可以监听。
--   ⇒ 这是「prefab 定制打开行为」的官方 hook（如开箱动画、特效）。
        self.inst:PushEvent("onopen", {doer = doer})

-- ★★ onopenfn 只在 opencount == 1 时触发（第 1 个打开者）。
--   ⇒ 语义：「这个容器刚刚从关闭变成打开」。多人打开时只有一次。
--   ⚠ 第二个参数是 `{doer = doer}`（一张表），不是 doer 本身 —— 调用方需注意。
        if self.onopenfn ~= nil and self.opencount == 1 then
            self.onopenfn(self.inst, {doer = doer})
        end

-- ★ onanyopenfn：每个打开者都触发一次（与 onopenfn 的区别就在这）。
        if self.onanyopenfn ~= nil then
            self.onanyopenfn(self.inst, {doer = doer})
        end
    end
end

-- 【★ Close_Items_Internal：递归关闭「容器里的容器」】
--   ★ 设计意图：打开一个背包时若里面有箱子，那箱子不该保持打开状态。
--   做成独立函数是为了配合 ForEachItem（第 783 行）的 `fn(v, ...)` 签名。
Container.Close_Items_Internal = function(item, doer)
-- 条件分支：if item.components.container ~= nil then  〔所在：Container:Open〕
    if item.components.container ~= nil then
        item.components.container:Close(doer)
    end
end

-- 【★★ Close —— 与 Open 对称的六步】
--   ① 先递归关内层容器（第 675 行）；
--   ② doer == nil 时广播给所有打开者（第 676-681 行）；
--   ③ 注销 openlist + opencount；
--   ④ UI / 音效（第 691-702 行）；
--   ⑤ 清理 inventory.opencontainers（第 707-709 行）；
--   ⑥ 事件与回调（第 711-719 行）。
function Container:Close(doer)
-- ★ 先关内层容器。注意它在 doer == nil 的分支**之前**，所以每个递归 Close 都会重复执行。
--   ⚠ 轻微冗余：递归路径下 ForEachItem 会被多次调用。无功能影响（幂等）。
    self:ForEachItem(Container.Close_Items_Internal, doer)
-- ★★ doer == nil 的「广播关闭」：遍历 openlist 给每个人各调一次 Close。
--   ⇒ 这是 Container.OnRemoveEntity（第 1086 行）的清理方式：实体被移除时
--     以 doer=nil 调用 Close，把所有打开者的 UI 都关掉。
--   ⚠ 潜在缺陷：在 `for opener in pairs(self.openlist)` 中递归调用 self:Close(opener)，
--     而 Close 内部会 `self.openlist[doer] = nil`（第 683 行）—— **在遍历中修改被遍历的表**。
--     Lua 允许把当前键置 nil（这是标准行为，next 的语义支持删除当前键），
--     所以实测不会崩，但严格说这属于「依赖未文档化行为」。仅标注。
    if doer == nil then
-- 循环：for opener, _ in pairs(self.openlist) do  〔所在：Container:Close〕
        for opener, _ in pairs(self.openlist) do
            self:Close(opener)
        end
-- 返回：return  〔所在：Container:Close〕
        return
    end
-- ★ 只有在 openlist 里的人才走后续流程（否则是重复关闭，静默忽略）。
    if doer ~= nil and self.openlist[doer] ~= nil then
        self.openlist[doer] = nil
-- ★ opencount 与 openlist 成对递减——两者必须始终一致。
        self.opencount = self.opencount - 1
        self.inst.replica.container:RemoveOpener(doer)

-- ★ 最后一个打开者离开时才停止每帧巡检（省性能）。
--   ⇒ 与第 620 行的 StartUpdatingComponent 配对，形成「按需巡检」模式。
        if self.opencount == 0 then
            self.inst:StopUpdatingComponent(self)
        end

-- ★ Close 的 UI 挂载点（第 637 行的镜像）。
        if doer.HUD ~= nil then
            doer.HUD:CloseContainer(self.inst, self:IsSideWidget())
            doer:PushEvent("refreshcrafting")
-- ★★ 关闭音效：结构与开启完全对称（第 639-649 行的三级回退）。
--   ⇒ 这就是第 640 行 FIXME 注释说的「重复了四份」之一。
            if not self.inst.replica.container:ShouldSkipCloseSnd() then
-- 局部变量：local skinsound = self.inst.AnimState and SKIN_SOUND_FX[self.inst.AnimState:GetSkinBuild()] or nil  〔所在：Container:Close〕
				local skinsound = self.inst.AnimState and SKIN_SOUND_FX[self.inst.AnimState:GetSkinBuild()] or nil
				TheFocalPoint.SoundEmitter:PlaySound(
					skinsound and skinsound.close_ui or
					(self.widget ~= nil and self.widget.closesound) or
					(self:IsSideWidget() and "dontstarve/wilson/backpack_close") or
					"dontstarve/HUD/Together_HUD/container_close"
				)
            end
-- ★ NPC 分支：反注册 playeractionpicker（第 650 行的镜像）。
--   ★ 注意这里用 elseif 而非嵌套 if，与 Open 的结构对称。
        elseif doer.components.playeractionpicker ~= nil then
            doer.components.playeractionpicker:UnregisterContainer(self.inst)
        end

-- ★ 清理玩家侧的 opencontainers 登记（第 630 行的镜像）。
--   ⚠ 这里只清理 doer 的登记表；别人的登记（若有多人同时开）保持不动 —— 正确。
        if doer.components.inventory ~= nil then
            doer.components.inventory.opencontainers[self.inst] = nil
        end

-- ★★ onclosefn 只在 opencount == 0 时触发（最后一个打开者离开）。
--   ★ 与 Open 的 onopenfn（第 658 行）完全对称。
--   ⚠ 但第 712 行传的是 doer（裸值）而非 {doer = doer}（表）——
--     **与第 659 行的 onopenfn 参数格式不一致**！
--     推理依据：第 659 行 `self.onopenfn(self.inst, {doer = doer})`，
--       第 712 行 `self.onclosefn(self.inst, doer)`。
--     ⇒ 调用方若写 `local doer = args.doer` 在 onclosefn 里会拿到 nil。
--     ★ 判定为 ⚠ 疑似缺陷（API 不对称）。这是 API 契约缺陷而非逻辑缺陷。仅标注，不改代码。
        if self.onclosefn ~= nil and self.opencount == 0 then
            self.onclosefn(self.inst, doer)
        end

-- ★ onanyclosefn：对称于第 662 行的 onanyopenfn。
        if self.onanyclosefn ~= nil then
            self.onanyclosefn(self.inst, {doer = doer})
        end

-- ★ PushEvent("onclose")：与第 656 行 onopen 对称。
        self.inst:PushEvent("onclose", {doer = doer})
    end
-- ★★ 至此 Close 的完整流程与 Open 对照表：
--   步骤            │ Open                        │ Close
--   ────────────────┼─────────────────────────────┼──────────────────────────
--   防重入          │ 618 openlist[doer] == nil    │ 682 openlist[doer] ~= nil
--   onupdate        │ 620 Start（若 skipautoclose）│ 688 最后一个离开才 Stop
--   递归内层容器    │ 无                          │ 675 ForEachItem 先关
--   UI              │ 637 HUD:OpenContainer       │ 692 HUD:CloseContainer
--   音效            │ 643 三级回退 open_ui        │ 696 三级回退 close_ui
--   联机            │ 634 replica:AddOpener       │ 685 replica:RemoveOpener
--   登记表          │ 630 inventory.opencontainers│ 708 同项置 nil
--   onopenfn/closefn│ 658 仅 opencount==1         │ 711 仅 opencount==0
--   事件            │ 656 "onopen"                │ 719 "onclose"
--   ⚠ 参数格式      │ {doer = doer}（表）          │ doer（裸值）★ 不对称
end

-- ★ IsOpen：opencount > 0。**注意它不区分是谁开的**——要问「谁开的」用 IsOpenedBy。
function Container:IsOpen()
-- 返回：return self.opencount > 0  〔所在：Container:IsOpen〕
    return self.opencount > 0
end

-- ★ IsOpenedBy(guy)：`self.openlist[guy]` 直接返回布尔（可能为 nil，falsy 即可）。
--   ⇒ 真值判定，不强制布尔。调用方（containers.lua:822）用 if 判断，正确。
function Container:IsOpenedBy(guy)
-- 返回：return self.openlist[guy]  〔所在：Container:IsOpenedBy〕
    return self.openlist[guy]
end

-- 【★ IsOpenedByOthers：除了我，还有别人开着吗】
--   `opencount - (我开着 ? 1 : 0) > 0` —— 用计数差而非遍历 openlist。
--   ★ 用途推测：某些 prefab 据此决定「要不要显示『有人在看』标记」。
--   ⚠ 注意参数名是 guy 但语义是「排除谁」；返回的是布尔而非人数。
function Container:IsOpenedByOthers(guy)
-- 返回：return (self.opencount - (self.openlist[guy] and 1 or 0)) > 0  〔所在：Container:IsOpenedByOthers〕
    return (self.opencount - (self.openlist[guy] and 1 or 0)) > 0
end

-- 【★★ CanOpen：openlimit 的唯一判定点】
--   ★★ 关键事实：★ **本函数不被 Open 调用**。
--   grep 核实全部调用点只有 4 处：
--     · actions.lua:1095 / 2484 / 2506 —— 动作层守门（远程拉取物品时检查）；
--     · components/slingshotmods.lua:148 —— 改装台的 AI 判定。
--   ⇒ 含义：**「能不能开」是动作层的职责，不是容器组件的**。
--     绕过动作直接调 Open（第 617 行）能开出超过 openlimit 个 UI。
--     这在单机无害，但多人下是潜在的 UI 叠加问题。★ 判定为架构层面的缺陷。
function Container:CanOpen()
-- 返回：return self.openlimit == nil or self.opencount < self.openlimit  〔所在：Container:CanOpen〕
    return self.openlimit == nil or self.opencount < self.openlimit
end

-- ★ GetOpeners：返回打开者**数组**（新表，不影响内部状态）。
--   ⚠ 遍历用 pairs → **顺序未定义**。containers.lua:821 的 GetOpeners()[1]
--     因此是「随机的一个打开者」，不是「最近打开的」。见那里的 ⚠ 标注。
function Container:GetOpeners()
-- 局部变量：local openers = {}  〔所在：Container:GetOpeners〕
    local openers = {}
-- 循环：for opener in pairs(self.openlist) do  〔所在：Container:GetOpeners〕
    for opener in pairs(self.openlist) do
-- table.insert(openers, opener)  〔所在：Container:GetOpeners〕
        table.insert(openers, opener)
    end
-- 返回：return openers  〔所在：Container:GetOpeners〕
    return openers
end

-- 【★ CheckItem：「槽里是不是这个东西」的两级判定】
--   ① item == target —— 精确匹配；
--   ② checkcontainer 为真且 target 是容器、它内部装着 item —— 递归命中。
--   ★ 第二级让「背包里有没有某物」能穿透嵌套容器（如背包里的弹药包）。
--   ⚠ 用的是 target.replica.container（第 751 行）——replica 表两端都有（entityscript.lua:244），
--     所以服务端可用。但注意**服务端**的 replica.container 的 slots 是空的
--     （服务端状态在 components.container.slots），所以第 ② 级在服务端实际不生效。
--     ⇒ 这意味着 IsHolding 的递归能力**只有客户端有**。属潜在不一致。仅标注。
local function CheckItem(item, target, checkcontainer)
-- 返回：return target ~= nil  〔所在：CheckItem〕
    return target ~= nil
        and (item == target
            or (checkcontainer and
                target.replica.container ~= nil and
                target.replica.container:IsHolding(item, checkcontainer)))
end

-- ★ IsHolding：遍历 slots 调 CheckItem。用 pairs（无序），只要一个命中就 true。
function Container:IsHolding(item, checkcontainer)
-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:IsHolding〕
    for k, v in pairs(self.slots) do
-- 条件分支：if CheckItem(item, v, checkcontainer) then  〔所在：Container:IsHolding〕
        if CheckItem(item, v, checkcontainer) then
-- 返回：return true  〔所在：Container:IsHolding〕
            return true
        end
    end
end

-- 【★ FindItem / FindItems：按回调搜索（无序遍历）】
--   ★ 注意回调签名是 fn(item)，**不传槽号** —— 想按槽过滤需自己闭包捕获。
--   ⇒ 与 GiveItem 的 itemtestfn(container, item, slot) 签名不同，注意区分。
function Container:FindItem(fn)
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:FindItem〕
    for k,v in pairs(self.slots) do
-- 条件分支：if fn(v) then  〔所在：Container:FindItem〕
        if fn(v) then
-- 返回：return v  〔所在：Container:FindItem〕
            return v
        end
    end
end

-- ★ FindItems：返回全部命中项。O(n)。
--   ⚠ 无 early-exit，所以比 FindItem 慢；只在需要全量时用。
function Container:FindItems(fn)
-- 局部变量：local items = {}  〔所在：Container:FindItems〕
    local items = {}

-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:FindItems〕
    for k,v in pairs(self.slots) do
-- 条件分支：if fn(v) then  〔所在：Container:FindItems〕
        if fn(v) then
-- table.insert(items, v)  〔所在：Container:FindItems〕
            table.insert(items, v)
        end
    end

-- 返回：return items  〔所在：Container:FindItems〕
    return items
end

-- 【★ ForEachItem：容器系统的「通用遍历原语」】
--   fn(v, ...) —— 第一个参数是物品，其余原样透传（可变参数转发）。
--   ★ 这是本文件所有批量操作的基础设施：
--     第 675 行 Close 递归、DropEverything 系列、DestroyContents 系列都基于它或其等价物。
--   ⚠ 用 pairs 遍历 → **顺序未定义**；且回调内若修改 self.slots 会有迭代风险。
--     第 675 行的 Close_Items_Internal 不改本容器的 slots（改的是内层容器的），安全。
function Container:ForEachItem(fn, ...)
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:ForEachItem〕
    for k,v in pairs(self.slots) do
        fn(v, ...)
    end
end

-- 【★★ ValidateSpecializedContainer：什么才算「专用容器」】
--   三个条件：① 有 priorityfn；② 已打开；③ 或（未忽略关闭 + canbeopened + 非 droponopen/portablecontainer）。
--   ★ 语义：「一个会主动吸附某类物品的容器」（弹药包、种子袋等）。
--   ⚠ 第 795 行读的 droponopen 从未被赋值（见构造函数第 50 行），
--     所以第 ③ 条实际只由 canbeopened 与 portablecontainer 标签决定。
local function ValidateSpecializedContainer(container, ignoreclosed)
-- 返回：return container ~= nil  〔所在：ValidateSpecializedContainer〕
	return container ~= nil
-- ★★ 第一道门：**必须有 priorityfn**。
--   ⇒ 这就是「专用容器」的定义边界：没有 priorityfn 的容器永远不会吸附物品。
--   ★ 推论：containers.lua 里那些只写 itemtestfn 不写 priorityfn 的容器
--     （如冰箱、盐罐）**永远不会**被背包自动吸走东西。
		and container.priorityfn ~= nil
-- ★★ 第二道门：**当前开着** —— 但只在 ignoreclosed 为真时无条件通过。
--   语义拆解：
--     · 已打开 → 一定算专用容器（玩家正看着它，理应吸附）；
--     · 未打开 → 只有在「不考虑关闭状态」时才可能算。
		and (	container:IsOpen() or
-- ★ ignoreclosed = self.ignoreclosedspoverflow（第 808 行传入）。
--   ⇒ 搬运事务中会把它设为 true（第 1378 行），此时**未打开的专用容器也算数**。
--     原因：搬运时目标专用容器可能还没打开，但物品仍应送进去。
				(	not ignoreclosed and
					container.canbeopened and
-- ⚠ 疑似缺陷：droponopen 从未被赋值（构造函数第 50 行整行注释）。
--   推理依据：grep 核实——本文件内 `self.droponopen` 只出现在第 795 行的**读**，
--     写侧为零。所以这个 or 的左半边恒为 nil/falsy。
--   ⇒ 实际生效的只有 `container.inst:HasTag("portablecontainer")`。
--     死条件不会导致错误结果（因为标签条件已足够），但会让读者误以为存在开关。仅标注。
					not (container.droponopen or container.inst:HasTag("portablecontainer"))
				)
			)
end

-- ★ 原注释保留：「--for specialized pocket containers (e.g. ammo pouch)」
--   ⇒ 官方给的唯一例子是弹药包。
--for specialized pocket containers (e.g. ammo pouch)
-- 【★ GetSpecializedContainers：找出本容器内的所有专用容器组件】
--   ★ 返回的是**组件数组**（不是实体），因为调用方要用 CanTakeItemInSlot 等方法。
--   ⚠ 每帧/每次 GiveItem 都会遍历 slots + 逐个 Validate → O(n) 开销。
function Container:GetSpecializedContainers()
-- ★ ignorespoverflow（第 61 行的 hacky flag）：直接返回 nil，**完全禁用**溢出。
--   ★ 设置点：MoveItemFromAllOfSlot 第 1375 行 ——「源容器本身就是专用容器时，
--     目标不要再往它身上溢出」，避免 A→B→A 的循环。
--   ⇒ 这是防「容器套容器无限循环」的第二道保险（第一道是第 454 行的 slot==nil 判定）。
	if self.ignorespoverflow then
-- 返回：return  〔所在：Container:GetSpecializedContainers〕
		return
	end
-- 局部变量：local ret  〔所在：Container:GetSpecializedContainers〕
	local ret
-- ★ 用 1..numslots 有序 for（不是 pairs）——顺序稳定，便于调试。
	for i = 1, self.numslots do
-- 局部变量：local v = self.slots[i]  〔所在：Container:GetSpecializedContainers〕
		local v = self.slots[i]
-- ★ ignoreclosedspoverflow 作为 ignoreclosed 传入（见第 793 行）。
		if v and ValidateSpecializedContainer(v.components.container, self.ignoreclosedspoverflow) then
-- 局部赋值：ret = ret or {}  〔所在：Container:GetSpecializedContainers〕
			ret = ret or {}
-- table.insert(ret, v.components.container)  〔所在：Container:GetSpecializedContainers〕
			table.insert(ret, v.components.container)
		end
	end
-- 返回：return ret  〔所在：Container:GetSpecializedContainers〕
	return ret
-- ★★ 至此「专用容器」机制的全貌（专有概念，容器系统的隐藏特性）：
--   定义：一个**带着 priorityfn 的容器实体**，且它自己被装在别的容器/背包里。
--   例：弹药包（装弹药）、种子袋（装种子）、战斗歌容器。
--   行为：① 父容器的 GiveItem 会优先问它「这个你要吗」（第 457 行）；
--         ② 父容器的 CanAcceptCount 把它的空位算进去（第 417 行）；
--         ③ 往父容器塞东西时，若专用容器正关着，会给客户端发一个特效实体
--           （第 462 行 container_closed_receiveitem_classified）。
--   ⇒ ★ 这个机制让「嵌套的窄容器」在体验上表现得像「父容器的格子」，
--     是 DST 背包系统少见的深度设计。
end

-- 【★ IsSpecializedContainer：反向判定「某组件是不是我的专用容器」】
--   ★ 与 GetSpecializedContainers 的区别：只查**指定的**那一个，不遍历收集。
--   消费点：第 1375/1443/1518 行（搬运时判断「目标是不是我的专用容器」）。
function Container:IsSpecializedContainer(container)
-- 循环：for i = 1, self.numslots do  〔所在：Container:IsSpecializedContainer〕
	for i = 1, self.numslots do
-- 局部变量：local v = self.slots[i]  〔所在：Container:IsSpecializedContainer〕
		local v = self.slots[i]
-- 条件分支：if v and v.components.container == container then  〔所在：Container:IsSpecializedContainer〕
		if v and v.components.container == container then
-- ★ 用 ValidateSpecializedContainer(container, false) —— ignoreclosed **写死 false**。
--   ⇒ 语义：「即使它没开、也不算专用容器」（不享受搬运期例外）。
			return ValidateSpecializedContainer(container, false)
		end
	end
-- 返回：return false  〔所在：Container:IsSpecializedContainer〕
	return false
end

-- 【★★★ Has：容器里有几个指定 prefab？合成与配方的通用查询】
--   ★ 返回两个值：(够不够, 实际有多少)。第一个是布尔，第二个是数量。
--   ★ 用 pairs 遍历（无序）—— 因为只做累加求和，顺序无关。
--   消费点：containers.lua:586 建造容器判定材料是否齐全。
function Container:Has(item, amount, iscrafting)
-- 局部变量：local num_found = 0  〔所在：Container:Has〕
    local num_found = 0
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:Has〕
    for k,v in pairs(self.slots) do
-- ★★ iscrafting 参数：合成时排除带 nocrafting 标签的物品。
--   → 存在「看得见但合成搜不到」的物品（如某些特殊道具）。
--   ★ 与第 924 行 GetCraftingIngredient 的 `not v:HasTag("nocrafting")` 完全一致。
--     ⇒ 两处必须同步修改，否则「Has 说够、GetCraftingIngredient 取不到」。
--     这是一个**隐式契约**，值得记住。
		if v ~= nil and v.prefab == item and not (iscrafting and v:HasTag("nocrafting")) then
-- 条件分支：if v.components.stackable ~= nil then  〔所在：Container:Has〕
            if v.components.stackable ~= nil then
-- 局部赋值：num_found = num_found + v.components.stackable:StackSize()  〔所在：Container:Has〕
                num_found = num_found + v.components.stackable:StackSize()
-- 兜底分支（前述条件全不成立）。〔所在：Container:Has〕
            else
-- 局部赋值：num_found = num_found + 1  〔所在：Container:Has〕
                num_found = num_found + 1
            end
        end
    end

-- 返回：return num_found >= amount, num_found  〔所在：Container:Has〕
    return num_found >= amount, num_found
end

-- 【★ HasItemThatMatches：按回调计数版 Has】
--   ★ 与 Has 的区别：① 用回调而非 prefab 名；② 用 fn(inst, item) 双参签名。
--   ⚠ 签名不一致（这里 fn 有两参，Has 只比 prefab），容易写错。
function Container:HasItemThatMatches(fn, amount)
-- 局部变量：local num_found = 0  〔所在：Container:HasItemThatMatches〕
	local num_found = 0
-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:HasItemThatMatches〕
	for k, v in pairs(self.slots) do
-- 条件分支：if fn(v) then  〔所在：Container:HasItemThatMatches〕
		if fn(v) then
-- 局部赋值：num_found = num_found + (v.components.stackable and v.components.stackable:StackSize() or 1)  〔所在：Container:HasItemThatMatches〕
			num_found = num_found + (v.components.stackable and v.components.stackable:StackSize() or 1)
		end
	end
-- 返回：return num_found >= amount, num_found  〔所在：Container:HasItemThatMatches〕
	return num_found >= amount, num_found
end

-- 【★ HasItemWithTag：按标签计数】
--   ★ 与 Has 完全同构，只是第 854 行从 `v.prefab == item` 换成 `v:HasTag(tag)`。
--   ⇒ 这是「同一个算法写两遍」的轻微重复，可接受（性能优于抽象）。
function Container:HasItemWithTag(tag, amount)
-- 局部变量：local num_found = 0  〔所在：Container:HasItemWithTag〕
    local num_found = 0
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:HasItemWithTag〕
    for k,v in pairs(self.slots) do
-- 条件分支：if v and v:HasTag(tag) then  〔所在：Container:HasItemWithTag〕
        if v and v:HasTag(tag) then
-- 条件分支：if v.components.stackable ~= nil then  〔所在：Container:HasItemWithTag〕
            if v.components.stackable ~= nil then
-- 局部赋值：num_found = num_found + v.components.stackable:StackSize()  〔所在：Container:HasItemWithTag〕
                num_found = num_found + v.components.stackable:StackSize()
-- 兜底分支（前述条件全不成立）。〔所在：Container:HasItemWithTag〕
            else
-- 局部赋值：num_found = num_found + 1  〔所在：Container:HasItemWithTag〕
                num_found = num_found + 1
            end
        end
    end

-- 返回：return num_found >= amount, num_found  〔所在：Container:HasItemWithTag〕
    return num_found >= amount, num_found
end

-- GetItemsWithTag：返回命中的**实体数组**（不是计数）。
--   ★ 无 early-exit、无排序 ⇒ 使用方拿到的是**任意顺序**。
function Container:GetItemsWithTag(tag)
-- 局部变量：local items = {}  〔所在：Container:GetItemsWithTag〕
    local items = {}
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetItemsWithTag〕
    for k,v in pairs(self.slots) do
-- 条件分支：if v and v:HasTag(tag) then  〔所在：Container:GetItemsWithTag〕
        if v and v:HasTag(tag) then
-- table.insert(items, v)  〔所在：Container:GetItemsWithTag〕
            table.insert(items, v)
        end
    end

-- 返回：return items  〔所在：Container:GetItemsWithTag〕
    return items
end

-- 【★★ GetItemByName：返回 {物品 → 数量} 的映射表】
--   ★ 这是「合成扣料」的数据准备函数——键是实体，值是要拿的数量。
--   ★ 有 early-exit（第 905-907 行）：凑够就停，不遍历剩余槽位。
--   ★ 用有序 for 1..numslots —— 因为有 early-exit，**遍历顺序会影响取了哪些摞**。
--   ⇒ 视觉后果：总是优先从**编号靠前**的槽位取料。
function Container:GetItemByName(item, amount)
-- 局部变量：local total_num_found = 0  〔所在：Container:GetItemByName〕
    local total_num_found = 0
-- 局部变量：local items = {}  〔所在：Container:GetItemByName〕
    local items = {}

-- ★ 内部函数 tryfind(v)：对单个槽位算出「拿多少」。
--   ⚠ 注意闭包里修改了外层的 total_num_found（第 903 行累加）—— 有状态的闭包。
    local function tryfind(v)
-- 局部变量：local num_found = 0  〔所在：tryfind〕
        local num_found = 0
-- 条件分支：if v and v.prefab == item then  〔所在：tryfind〕
        if v and v.prefab == item then
-- 局部变量：local num_left_to_find = amount - total_num_found  〔所在：tryfind〕
            local num_left_to_find = amount - total_num_found
-- 条件分支：if v.components.stackable then  〔所在：tryfind〕
            if v.components.stackable then
-- ★★ 关键分支：`v.components.stackable.stacksize > num_left_to_find` ——
--   这一摞**比需要的还多** → 只取需要的部分（第 887 行 items[v] = num_left_to_find）。
--   ⚠ 注意这里**直接读 `.stacksize` 字段**而非调用 `StackSize()` 方法。
--     两者当前等价（Stackable:StackSize 就是 return self.stacksize），
--     但直接读字段绕过了方法，可能在 stackable 组件重构时失效。
--     对照第 927 行 GetCraftingIngredient 用的是 StackSize() 方法。
--     ★ 同一文件内两种写法并存，属轻微不一致。仅标注。
                if v.components.stackable.stacksize > num_left_to_find then
                    items[v] = num_left_to_find
-- 局部赋值：num_found = amount  〔所在：tryfind〕
                    num_found = amount
-- 兜底分支（前述条件全不成立）。〔所在：tryfind〕
                else
                    items[v] = v.components.stackable.stacksize
-- 整摞取走：数量就是这摞的全部。
                    num_found = num_found + v.components.stackable.stacksize
                end
-- 兜底分支（前述条件全不成立）。〔所在：tryfind〕
            else
                items[v] = 1
-- 局部赋值：num_found = num_found + 1  〔所在：tryfind〕
                num_found = num_found + 1
            end
        end
-- 返回：return num_found  〔所在：tryfind〕
        return num_found
    end

-- ★ 有序遍历 + 第 905 行 early-exit ⇒ 取料顺序 = 槽位编号顺序。
    for k = 1,self.numslots do
-- 局部变量：local v = self.slots[k]  〔所在：tryfind〕
        local v = self.slots[k]
-- 局部赋值：total_num_found = total_num_found + tryfind(v)  〔所在：tryfind〕
        total_num_found = total_num_found + tryfind(v)

-- 条件分支：if total_num_found >= amount then  〔所在：tryfind〕
        if total_num_found >= amount then
            break
        end
    end

-- 返回：return items  〔所在：tryfind〕
    return items
end

-- 【★★ crafting_priority_fn：合成取料排序规则】
--   ★★ 与 components/inventory.lua:1690 的同名函数**逐字相同** ——
--     这是容器与物品栏刻意保持一致的排序契约。
--   规则：① 小摞优先（少拆）；② 同大小时按槽位顺序（保持可预测）。
local function crafting_priority_fn(a, b)
-- 条件分支：if a.stacksize == b.stacksize then  〔所在：crafting_priority_fn〕
    if a.stacksize == b.stacksize then
-- 返回：return a.slot < b.slot  〔所在：crafting_priority_fn〕
        return a.slot < b.slot
    end
-- ★ 原注释保留：「--smaller stacks first」
--   为什么小摞优先？合成要拿 5 个燧石时，从 20 摞里拿比从 99 摞里拿更「不浪费」
--     —— 大摞留着以后整摞用。★ 这是**背包管理友好性**的经典设计。
    return a.stacksize < b.stacksize --smaller stacks first
end

-- 【★★★ GetCraftingIngredient —— 合成供料（容器侧）】
--   ★ 与 components/inventory.lua:1697 的同名方法是**孪生实现**，两套排序规则完全相同。
--   ⇒ builder 组件会同时查物品栏与专用容器，再合并结果。
--   ★ 返回 {物品实体 → 数量} 映射（与 GetItemByName 同格式）。
--   ★ 注意它**不修改任何状态**——纯查询。真正的扣除在 builder 的 RemoveIngredients。
function Container:GetCraftingIngredient(item, amount, reverse_search_order)
-- 局部变量：local items = {}  〔所在：Container:GetCraftingIngredient〕
    local items = {}
-- 循环：for i = 1, self.numslots do  〔所在：Container:GetCraftingIngredient〕
    for i = 1, self.numslots do
-- 局部变量：local v = self.slots[i]  〔所在：Container:GetCraftingIngredient〕
        local v = self.slots[i]
-- ★ 与 Has 第 829 行同源的 nocrafting 排除（见该处「隐式契约」说明）。
		if v ~= nil and v.prefab == item and not v:HasTag("nocrafting") then
-- table.insert(items, {  〔所在：Container:GetCraftingIngredient〕
            table.insert(items, {
-- 局部赋值：item = v,  〔所在：Container:GetCraftingIngredient〕
                item = v,
-- 局部赋值：stacksize = v.components.stackable and v.components.stackable:StackSize() or 1,  〔所在：Container:GetCraftingIngredient〕
				stacksize = v.components.stackable and v.components.stackable:StackSize() or 1,
-- ★★ reverse_search_order：反向排序槽号（第 928 行）。
--   → `self.numslots - (i - 1)` 把 1..numslots 映射成 numslots..1。
--   ★ 用途：当容器**从后往前**填时（如刚放入的物品在最前），
--     合成取料应该优先取**后面的**（更早放入、更可能该被消耗）的。
--   ⚠ 这里只影响排序 tie-break（第 915 行 stacksize 相同时按 slot 比），
--     不影响主要排序（小摞优先）。
                slot = reverse_search_order and (self.numslots - (i - 1)) or i,
            })
        end
    end
-- ★ table.sort(items, crafting_priority_fn) —— 排序后第 936 行按序取料。
    table.sort(items, crafting_priority_fn)

-- 局部变量：local crafting_items = {}  〔所在：Container:GetCraftingIngredient〕
    local crafting_items = {}
-- 局部变量：local total_num_found = 0  〔所在：Container:GetCraftingIngredient〕
    local total_num_found = 0
-- 循环：for i, v in ipairs(items) do  〔所在：Container:GetCraftingIngredient〕
    for i, v in ipairs(items) do
-- 局部变量：local stacksize = math.min(v.stacksize, amount - total_num_found)  〔所在：Container:GetCraftingIngredient〕
        local stacksize = math.min(v.stacksize, amount - total_num_found)
        crafting_items[v.item] = stacksize
-- 局部赋值：total_num_found = total_num_found + stacksize  〔所在：Container:GetCraftingIngredient〕
        total_num_found = total_num_found + stacksize
-- 条件分支：if total_num_found >= amount then  〔所在：Container:GetCraftingIngredient〕
        if total_num_found >= amount then
            break
        end
    end

-- 返回：return crafting_items  〔所在：Container:GetCraftingIngredient〕
    return crafting_items
end

-- 【★ tryconsume：真正的扣料执行者】
--   三分支：① 非堆叠物 → 整个移除并销毁；
--     ② 堆叠数 > 需要量 → 只减数量；
--     ③ 否则 → 整摞移除并销毁。
--   ★ 返回实际消耗量（供调用方累计）。
local function tryconsume(self, v, amount)
-- 条件分支：if v.components.stackable == nil then  〔所在：tryconsume〕
    if v.components.stackable == nil then
-- ★ `self:RemoveItem(v):Remove()` —— 取出**整摞**（wholestack 未传 → nil）。
--   ⚠ 危险写法：RemoveItem 第 1015 行「找不到时返回 item 本身」，
--     所以即使 RemoveItem 什么也没移除，:Remove() 也会销毁它。
--     当前 v 一定在 slots 里（第 969 行的遍历源），所以安全。
--     但这个「链式调用」的健壮性依赖调用前提，值得注意。
        self:RemoveItem(v):Remove()
-- 返回：return 1  〔所在：tryconsume〕
        return 1
-- 次选条件：elseif v.components.stackable.stacksize > amount then  〔所在：tryconsume〕
    elseif v.components.stackable.stacksize > amount then
-- ★ 只减数量，**不销毁实体** —— 物品还在容器里，只是变少了。
        v.components.stackable:SetStackSize(v.components.stackable.stacksize - amount)
-- 返回：return amount  〔所在：tryconsume〕
        return amount
-- 兜底分支（前述条件全不成立）。〔所在：tryconsume〕
    else
-- 局部赋值：amount = v.components.stackable.stacksize  〔所在：tryconsume〕
        amount = v.components.stackable.stacksize
-- ★ `self:RemoveItem(v, true)` —— 第二个参数 true = wholestack，整摞取出后销毁。
        self:RemoveItem(v, true):Remove()
-- 返回：return amount  〔所在：tryconsume〕
        return amount
    end
    --shouldn't be possible?
-- 返回：return 0  〔所在：tryconsume〕
    return 0
end

-- 【★ ConsumeByName：按名字扣 N 个（合成扣料的低层执行）】
--   ★ 用 pairs 遍历（无序）⇒ **扣哪一摞不确定**！
--   ⚠ 与 GetCraftingIngredient 的「有序 + 小摞优先」策略不同：
--     若调用方先用 GetCraftingIngredient 规划、再用 ConsumeByName 执行，
--     两者可能选中不同的摞。这是**潜在不一致**。
--     ★ 实际影响很小（同 prefab 的摞可互换），但会丢失「slot 号」这一信息。仅标注。
function Container:ConsumeByName(item, amount)
-- ★ 两道门：数量为 0 或只读容器 → 直接返回。readonlycontainer 的第 4 道防线。
    if amount <= 0 or self.readonlycontainer then
-- 返回：return  〔所在：Container:ConsumeByName〕
        return
    end

-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:ConsumeByName〕
    for k, v in pairs(self.slots) do
-- 条件分支：if v.prefab == item then  〔所在：Container:ConsumeByName〕
        if v.prefab == item then
-- 局部赋值：amount = amount - tryconsume(self, v, amount)  〔所在：Container:ConsumeByName〕
            amount = amount - tryconsume(self, v, amount)
-- 条件分支：if amount <= 0 then  〔所在：Container:ConsumeByName〕
            if amount <= 0 then
-- 返回：return  〔所在：Container:ConsumeByName〕
                return
            end
        end
    end
end

-- 【★★ OnSave：存档序列化】
--   ★ 返回 (data, references) 两个值——第二值是「本实体之外还需要保留的实体引用」，
--     由引擎的存档系统处理跨实体引用。
--   ★ data.items[k] 用**槽号 k** 作键 ⇒ 存档格式与槽位编号强绑定。
function Container:OnSave()
-- 局部变量：local data = {items= {}}  〔所在：Container:OnSave〕
    local data = {items= {}}
-- 局部变量：local references = {}  〔所在：Container:OnSave〕
    local references = {}
-- 局部变量：local refs  〔所在：Container:OnSave〕
	local refs
-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:OnSave〕
    for k,v in pairs(self.slots) do
-- ★★ 存档过滤：① 实体有效；② **v.persists 为真**。
--   persists=false 的物品不存档 —— 典型如「正在被吃掉的最后一口食物」
--     （actions.lua:2419 `food.persists = false`）。
--   ⇒ 设计意图：**临时性物品不写进存档**，避免存档里出现半成品。
--   ⚠ 副作用：这类物品在读档后会**消失**（且不返还任何东西）。
--     这是有意的（设计上「吃到一半的食物不该复活」），但要知道这个后果。
        if v:IsValid() and v.persists then --only save the valid items
-- ★ v:GetSaveRecord() —— 实体自序列化，items[k] 存记录、refs 存外部引用。
            data.items[k], refs = v:GetSaveRecord()
-- 条件分支：if refs then  〔所在：Container:OnSave〕
            if refs then
-- 循环：for k,v in pairs(refs) do  〔所在：Container:OnSave〕
                for k,v in pairs(refs) do
-- table.insert(references, v)  〔所在：Container:OnSave〕
                    table.insert(references, v)
                end
            end
        end
    end
-- 返回：return data, references  〔所在：Container:OnSave〕
    return data, references
end

-- 【★ OnLoad：读档还原】
--   ★ 用 pairs 遍历存档表（无序）→ **还原顺序不确定**。
--   ⚠ 但因为 GiveItem 第 451 行会 GetSpecificSlotForItem 重新选位，
--     且第 521 行优先用存档的槽号 k，所以**槽位基本能还原**。
--     若蓝图改过槽位数（numslots 变小），GiveItem 会失败 → 物品**丢失**。
--     ★ 这就是第 115 行 SetNumSlots 只许增大、containers.lua:1663-1666 sunkenchest
--     刻意提到「旧 3x3 数据满载到新 3x5」的根本原因。
function Container:OnLoad(data, newents)
-- 条件分支：if data.items then  〔所在：Container:OnLoad〕
    if data.items then
-- 循环：for k,v in pairs(data.items) do  〔所在：Container:OnLoad〕
        for k,v in pairs(data.items) do
-- 局部变量：local inst = SpawnSaveRecord(v, newents)  〔所在：Container:OnLoad〕
            local inst = SpawnSaveRecord(v, newents)
-- ★ SpawnSaveRecord(v, newents)：引擎函数，用存档记录重建实体。
--   ⚠ 若返回 nil（数据损坏/物品已废弃），第 1000-1003 行静默跳过 → **该物品丢失**。
--     没有日志、没有警告。⚠ 这在排查「读档丢东西」问题时是个盲点。
            if inst then
                self:GiveItem(inst, k)
            end
        end
    end
end

-- ★★★ 原注释保留：「--V2C: ***WARNING*** checkallcontainers not implemented here
--     parameter exists to keep interface same as inventory component」
--   → RemoveItem 的第三个形参 checkallcontainers **没有实现**，纯粹为了和
--     components/inventory.lua 的同名方法**保持接口一致**，让调用方可以互换。
--   ★ 这是「面向接口编程」的经典做法：宁可留个空参数，也保持调用方代码通用。
--V2C: ***WARNING*** checkallcontainers not implemented here
--     parameter exists to keep interface same as inventory component
-- 【★★ RemoveItem：按实体移除，支持「取一个」与「取整摞」】
--   ★ 签名 (item, wholestack, _checkallcontainers_, keepoverstacked)
--     —— 第 3 参下划线前缀 = 明确标注「未实现」。
--   ★ 与 RemoveItemBySlot 的区别：这里是「按物品」而非「按槽号」，
--     内部用 GetItemSlot（第 598 行）反查槽号（O(n)）。
function Container:RemoveItem(item, wholestack, _checkallcontainers_, keepoverstacked)
-- 条件分支：if item then  〔所在：Container:RemoveItem〕
	if item then
-- 局部变量：local slot = self:GetItemSlot(item)  〔所在：Container:RemoveItem〕
		local slot = self:GetItemSlot(item)
-- 条件分支：if slot then  〔所在：Container:RemoveItem〕
		if slot then
-- 返回：return self:RemoveItem_Internal(item, slot, wholestack, keepoverstacked)  〔所在：Container:RemoveItem〕
			return self:RemoveItem_Internal(item, slot, wholestack, keepoverstacked)
		end
-- ★★★ 疑似缺陷：找不到物品时**返回 item 本身**（而非 nil）。
--   推理依据：
--     ① 语义上「我没移除任何东西」应该返回 nil，调用方靠返回值判断成败；
--     ② 但这里返回了 item —— 调用方会以为「成功移除了这个」；
--     ③ 最危险的后果在第 950 行 `self:RemoveItem(v):Remove()`：
--        若 RemoveItem 什么都没移除，这行会**直接销毁 item**，造成物品凭空消失。
--     ④ 原注释「--default to true if nil」只在 GiveItem 里，RemoveItem 没有类似兜底。
--   ⇒ 判定：这是**有意的宽松设计**还是**遗留缺陷**难以确定，
--     但「返回未移除的物品」在 Lua 里是明显的反模式。
--     ★ 标为 ⚠ 疑似缺陷。当前唯一调用方（第 950 行）的前提是 v 必在 slots 里，故不触发。
--     绝不改代码。
		return item
	end
end

-- 【★★★ RemoveItem_Internal：所有移除路径的唯一收敛点】
--   ★ 它被 6 处调用：DropItemBySlot(129) / RemoveItemBySlot(572) / RemoveItem(1013) /
--     GiveItem 的回滚路径(1386/1454/1529) 等。
--   ★ 参数 (item, slot, wholestack, keepoverstacked) 的组合决定了 6 种不同行为，
--     下面逐段拆解。
function Container:RemoveItem_Internal(item, slot, wholestack, keepoverstacked)
-- ★ 原注释保留：「--assert(item == self.slots[slot])」——**被注释掉的断言**。
--   ⚠ 说明这个断言曾经存在但被禁用了，推理原因是容器套容器场景下
--     item 与 slot 的对应关系可能不成立（见第 1364 行 MoveItemFromAllOfSlot 的特殊路径）。
--   ⇒ 保留注释是为了让后人知道「这里曾经有个校验」。
	--assert(item == self.slots[slot])
-- ★★ 只读容器拒绝一切移除 —— readonlycontainer 的**服务端硬闸门**。
--   ⇒ 与第 275 行（拒绝放入）、第 378 行（拒绝计数）、第 965 行（拒绝扣料）
--     一起构成 readonlycontainer 的完整防线（5 道，见 EnableReadOnlyContainer）。
    if self.readonlycontainer then
-- 返回：return nil  〔所在：Container:RemoveItem_Internal〕
        return nil
    end

-- 局部变量：local stackable = item.components.stackable  〔所在：Container:RemoveItem_Internal〕
	local stackable = item.components.stackable
-- ★★ 分流：可堆叠物品走「拆分」路径，第 1040 行的 else 走「整体移除」路径。
--   `stackable:IsStack()` = stacksize > 1（stackable.lua:55）。
--   ⚠ 注意：`stackable:IsStack()` 为 false（stacksize==1）时**不拆分**，
--     直接整体移除 —— 结果相同，只是少一次 SpawnPrefab。**性能优化**。
	if stackable and stackable:IsStack() then
-- ★★★ num 的三态计算（本文件最难读的三行之一）：
--   ① `(not wholestack and 1)` —— 只要单个 → num=1；
--   ② `(keepoverstacked and IsOverStacked() and originalmaxsize)` —— 保留超量 → 拿「正常上限」个；
--   ③ 否则 nil —— nil 意味着「**整摞拿走**」（不进 if，第 1040 行整体移除）。
--   ⚠ 第 ② 条依赖 IsOverStacked（第 232 行的 IsOverStacked 定义在 stackable.lua:68）。
--     语义：从「无限堆叠容器」取出时，把超出正常上限的那部分留下给物品自身，
--     多余部分由 DropOverstackedExcess 丢出去（见第 1043 行）。
		local num =
			(not wholestack and 1) or
			(keepoverstacked and stackable:IsOverStacked() and stackable.originalmaxsize) or
			nil
-- 条件分支：if num then  〔所在：Container:RemoveItem_Internal〕
		if num then
-- ★★ stackable:Get(num) —— **拆出** num 个成新实体，原摞保留剩余。
--   这是「取一半」的底层实现（TakeActiveItemFromHalfOfSlot 第 1161 行同款）。
			local dec = stackable:Get(num)
-- ★ OnRemoved() —— 立刻结算（湿度、温度、耐久等）。
--   ⚠ 注意与第 1048 行的 OnRemoved 重复调用（两条路径都要结算一次），
--     这里调一次是因为走的是 Split 而非 Remove（后者才走第 1048 行）。
			dec.components.inventoryitem:OnRemoved()
-- ★★ prevslot / prevcontainer：记录「拆出来的这一份来自哪个槽」。
--   ★ 用途：inventoryitem.lua:315 GetSlotNum 读它；
--     MoveItemFromHalfOfSlot 第 1436 行会清掉它们再放入目标。
--   ⇒ 这是「跨容器搬运事务」的第二个记忆字段（第一个是 item 自身）。
			dec.prevslot = slot
			dec.prevcontainer = self
-- 返回：return dec  〔所在：Container:RemoveItem_Internal〕
			return dec
		end
	end
-- ★★★ 分支二（整摞）：`self.slots[slot] = nil` —— **不搬移其他元素**。
--   ⇒ 这就是「槽位稀疏、编号保留玩家视觉记忆」的具体实现点。
--     ★ 全文件最关键的一行行为决策：宁可有空洞，也不让物品跳位。

	self.slots[slot] = nil
-- ★★ infinitestacksize 容器取出的额外处理（第 36 行的只读开关）。
--   顺序：① 先把超量的部分丢出去 ② 再解除 maxsize 限制。
	if self.infinitestacksize and stackable then
-- ★ ignoreoverstacked（第 64 行 flag）：true 时**不**丢超量部分。
--   设置点：第 1360 行 ——「目标容器是无限堆叠容器时，整摞一起搬」。
--   ⚠ 这个 flag 是**一次性**的（设了立刻用完就清），见第 1360-1362 行。
		if not self.ignoreoverstacked then
-- ★ DropOverstackedExcess(item)：把超量堆叠吐到地上（见第 228 行实现）。
--   ⚠ 若此时 ignoreoverstacked=false 而物品确实超量，物品会**分裂成两份**（一半地上）。
--     这是有意的：无限堆叠容器「借出」时把多带的还回去。
			self:DropOverstackedExcess(item)
		end
-- ★ SetIgnoreMaxSize(false) —— 恢复正常 maxsize（stackable.lua:46-51）。
--   ★ 注意 stackable.lua:50 内部会 `originalmaxsize = nil`，所以第 1043 行必须
--     在这**之前**调用（DropOverstackedExcess 依赖 originalmaxsize）。顺序正确。
		stackable:SetIgnoreMaxSize(false)
	end
-- ★★★ PushEvent("itemlose", {slot, prev_item}) —— 与第 547 行 itemget 对称。
--   ★★ 这是**联机同步的关键事件**：container_replica.lua:37-43 监听它，
--     转写成 `self.classified:SetSlotItem(data.slot)`（清空该槽的网络变量）。
--   ⇒ itemget/itemlose 这一对事件，就是服务端容器状态到客户端的**唯一同步通道**。
--     整个容器系统的网络同步设计就压在这一对事件上。
	self.inst:PushEvent("itemlose", { slot = slot, prev_item = item })
	item.components.inventoryitem:OnRemoved()
	item.prevslot = slot
	item.prevcontainer = self

-- 返回：return item  〔所在：Container:RemoveItem_Internal〕
    return item
-- ★★ 至此 RemoveItem_Internal 的完整决策树：
--   1. readonlycontainer？→ 返回 nil（一个都不给）
--   2. 可堆叠且 IsStack()？→ 进入拆分路径，算 num：
--        wholestack 假 → num = 1
--        keepoverstacked 且超量 → num = originalmaxsize
--        否则 → num = nil ⇒ 走整体移除
--   3. 整体移除：slots[slot]=nil（★不搬移）+ 超量处理 + 恢复 maxsize
--   4. 发 itemlose 事件（★ 联机同步的关键）+ OnRemoved + 记 prev 字段
end

-- 「Check for auto-closing conditions」—— 自动关闭机制的分区注释。
--------------------------------------------------------------------------
--Check for auto-closing conditions
--------------------------------------------------------------------------

-- 【★★ OnUpdate：容器自动关闭的巡检器（每帧执行）】
--   ★ 由第 620 行 StartUpdatingComponent 启动、第 1088 行（或第 687 行的最后一次关闭）停止。
--   ★ 按需启停 ⇒ 不开容器时不消耗 CPU。这是本文件最重要的性能设计。
--   ⚠ 但一旦有容器开着，就是**每帧**跑（有开着的容器时）。
function Container:OnUpdate(dt)
-- 条件分支：if self.opencount == 0 then  〔所在：Container:OnUpdate〕
    if self.opencount == 0 then
        self.inst:StopUpdatingComponent(self)
-- 兜底分支（前述条件全不成立）。〔所在：Container:OnUpdate〕
    else
        --attempt to close the chest for all players who have the chest opened who meet the requirements for closing it.
-- ★ owner = 本容器的「最终主人」（装在谁身上）。nil = 独立容器（地上的箱子）。
--   GetGrandOwner 会穿透嵌套背包找到最终持有者。
		local owner = self.inst.components.inventoryitem and self.inst.components.inventoryitem:GetGrandOwner() or nil
-- ★ nonownerparent：无主容器时的父实体。
--   ⚠ 注意这行算出来的变量在后续**从未被使用**（grep 核实：本行之后无引用）。
--     ★ 判定为 ⚠ 死变量（无害但显然是没写完的逻辑）。不改代码。
		local nonownerparent = owner == nil and self.inst.entity:GetParent() or nil
-- ★★ 遍历所有打开者，逐个判定是否该关闭他。
--   ⚠ 在遍历中调用 self:Close(opener)（会改 openlist）——
--     与第 676 行同类的「遍历时修改」模式。Lua 允许删除当前键，实践安全。
        for opener, _ in pairs(self.openlist) do
-- ★ 打开者的坐骑（rider 组件）—— 用于「从坐骑背包里开箱子」的场景。
			local mount = opener.components.rider and opener.components.rider:GetMount() or nil
-- 局部变量：local ismount = mount == self.inst  〔所在：Container:OnUpdate〕
			local ismount = mount == self.inst
-- ★★★ 三种「该关闭」的情况之一：打开者**就是**主人或主人的坐骑。
--   ⇒ 即「开自己背包里的容器」不算走远，应当立刻关掉（第 1075-1078 行）。
			if owner and (owner == opener or owner == mount) or ismount then
-- ★ 原注释保留（V2C 五行）：完整解释了「portablestorage」在背包里的临时开启机制。
--   「--V2C: special case handling for players who can open "portablestorage"
--     containers from inventory without dropping
--     -- pocket_rummage is now used for:
--     --   "portablestorage" in your inventory
--     --   "portablestorage" in your mount's inventory while mounted
--     --   your mount's container (e.g. Woby)」
--   → 解读：玩家可以「不放下背包就翻看背包里的储物箱」，
--     这种 UI 是一闪而过的（pocket rummage = 快速翻看），因此要自动关闭。
--   ★ 这解释了为什么 Wooby（坐骑）的容器能被远程开启——它是 portablecontainer。
				--V2C: special case handling for players who can open "portablestorage" containers from inventory without dropping
				--     pocket_rummage is now used for:
				--       "portablestorage" in your inventory
				--       "portablestorage" in your mount's inventory while mounted
				--       your mount's container (e.g. Woby)
-- ★★★ 条件：(是坐骑 或 有 portablestorage 标签) 且 **不处于** keep_pocket_rummage 状态。
--   sg:HasStateTag("keep_pocket_rummage") 是状态图层的开关——
--     某些状态（如正在被骑乘的动画）会要求「保持打开」。
--   ⇒ 这是「状态图（stategraph）参与容器逻辑」的例子：容器系统依赖 sg 的标签。
				if (ismount or self.inst:HasTag("portablestorage")) and not (opener.sg and opener.sg:HasStateTag("keep_pocket_rummage")) then
					self:Close(opener)
-- ★★ PushEventImmediate("ms_closeportablestorage") —— 用 **Immediate**（同步）而非 PushEvent。
--   ⇒ 原因：这个事件必须在**本帧结束前**让 UI 关掉，不能延后一帧（否则会闪一下）。
--     ★ 对照第 21 行的 player_despawn 用的是普通 PushEvent。
--     「什么时候必须 Immediate」是本文件里一个值得学的细节。
					opener:PushEventImmediate("ms_closeportablestorage", { item = self.inst })
				end
-- ★★★ 情况二：坐骑 != nil，或者（距离太远 / 视线被挡 / 实体失效）→ 关闭。
--   `CanEntitySeeTarget(opener, self.inst)` —— ★ 视线检查很重要：
--     隔着墙也关闭，避免「玩家跑开后在别人视野里开着箱子」。
--   CONTAINER_AUTOCLOSE_DISTANCE = 3（constants.lua:2928）—— ★ 只有 3 个单位！
--     这解释了为什么打开箱子后必须站在旁边，走两步就关了。
			elseif mount or not (opener:IsValid() and opener:IsNear(self.inst, CONTAINER_AUTOCLOSE_DISTANCE) and CanEntitySeeTarget(opener, self.inst)) then
				self:Close(opener)
			end
        end
    end
end

-- ★★★ 两个生命周期钩子都绑定到 Close：实体被移除 / 从实体卸载时关闭容器。
--   ⇒ 因为 Close(nil) 会广播给所有打开者（第 676 行），所以实体消失时
--     每个玩家的 UI 都会被正确关闭。**这是防「幽灵 UI」的关键**。
Container.OnRemoveEntity = Container.Close
Container.OnRemoveFromEntity = Container.Close


--------------------------------------------------------------------------
-- 「InvSlot click action handlers」—— 槽位点击动作处理器的分区注释。
--InvSlot click action handlers
--------------------------------------------------------------------------

-- 【★ QueryActiveItem：七个处理器的公共前置】
--   返回 (inventory, active_item) —— 「操作者的物品栏」与「当前手持物」。
--   ★ 用 and/or 链容错：没有 inventory（NPC）时两者都是 nil。
--   ⇒ 七个处理器的第 3-4 行都长这样，这是本文件的统一签名风格。
local function QueryActiveItem(self, opener)
-- 局部变量：local inventory = opener ~= nil and opener.components.inventory or nil  〔所在：QueryActiveItem〕
    local inventory = opener ~= nil and opener.components.inventory or nil
-- 返回：return inventory, inventory ~= nil and inventory:GetActiveItem() or nil  〔所在：QueryActiveItem〕
    return inventory, inventory ~= nil and inventory:GetActiveItem() or nil
end

-- 【★★ 处理器组 1/7：PutOneOfActiveItemInSlot —— 「放一个」】
--   七个处理器的**统一骨架**（务必记住，后续六个同构）：
--     ① readonlycontainer 早退；
--     ② QueryActiveItem 取 (inventory, active_item)；
--     ③ 多重前置判定（含 ★ CanTakeItemInSlot）；
--     ④ 设置 self.currentuser = opener（供物品回调知道是谁）；
--     ⑤ 临时设 ignoresound = true，执行搬运，再恢复；
--     ⑥ 清空 currentuser。
--   ★ 第 ⑤ 步的「临时静音」是本文件的通用模式，出现在 8 处。
--   ⇒ 设计意图：这些是**玩家点击的操作**，不该播 gotnewitem 音效
--     （那个音效表示「你捡到了东西」，语义不同）。
function Container:PutOneOfActiveItemInSlot(slot, opener)
-- ★ readonlycontainer 的第 5 道防线（客户端点击侧的第一道）。
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:PutOneOfActiveItemInSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:PutOneOfActiveItemInSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- ★★ 四重与：① 有手持物 ② **目标槽为空** ③ ★ CanTakeItemInSlot 通过 ④ 手持物是可堆叠物。
--   ★ 第 ② 条（槽必须为空）决定了这是「放置」而非「合并」——
--     合并走 AddOneOfActiveItemToSlot（第 1230 行）。
--   ★ 第 ③ 条是 **itemtestfn 的调用点之一**（拖拽/点击时实时判定）。
    if active_item ~= nil and
        self:GetItemInSlot(slot) == nil and
        self:CanTakeItemInSlot(active_item, slot) and
        active_item.components.stackable ~= nil and
        active_item.components.stackable:IsStack() then

-- ★ currentuser 临时赋值（见构造函数第 56 行的原注释：它不可靠、需验证后使用）。
        self.currentuser = opener

-- ★★ ignoresound = true —— 静音搬运。配套的第 1114 行恢复。
--   ⚠ 潜在缺陷：若 GiveItem 抛错，第 1114 行不会执行，ignoresound 会**永久为 true**。
--     当前 GiveItem 不会抛错（内部无 assert），故安全。
--     但同型代码第 1136-1141 行（PutAllOfActiveItemInSlot）的顺序是
--     「先 RemoveItem 再设 ignoresound」，**更安全**（RemoveItem 抛错也不会污染标志）。
--     ★ 两处顺序不一致，属健壮性上的轻微差异。仅标注，不改代码。
        self.ignoresound = true
-- ★★ `active_item.components.stackable:Get(1)` —— 只拆一个。
--   拆出的实体传给 GiveItem；原摞保留其余（第 1114 行恢复静音）。
        self:GiveItem(active_item.components.stackable:Get(1), slot)
-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。
        self.ignoresound = false

        self.currentuser = nil
    end
end

-- 【★★ 处理器组 2/7：PutAllOfActiveItemInSlot —— 「全放进去」】
--   ★ 与上一条的关键差异：目标槽**可以非空**（非空则转 Swap，见第 1128 行）。
function Container:PutAllOfActiveItemInSlot(slot, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:PutAllOfActiveItemInSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:PutAllOfActiveItemInSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:PutAllOfActiveItemInSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:PutAllOfActiveItemInSlot〕
    local item = self:GetItemInSlot(slot)
-- 条件分支：if active_item ~= nil then  〔所在：Container:PutAllOfActiveItemInSlot〕
    if active_item ~= nil then
-- ★★ 槽里有东西 → 退化成 SwapActiveItemWithSlot（第 1128 行）。
--   ⇒ 玩家直觉：「按住 Ctrl 点一个已有物品的格子」= 交换。
--   ⚠ 注意这里调的是本文件第 1276 行的 Swap，会再次走一遍所有判定（略有重复但无害）。
        if item ~= nil then
            self:SwapActiveItemWithSlot(slot, opener)
-- ★★★ 三重与（★ 与第 1104 行的差异在这里）：
--   ① CanTakeItemInSlot 通过；
--   ② ★★ AcceptsStacks() **或** 手持物不是可堆叠物 **或** 它不是摞。
--   ③ 语义：「本容器收整摞」，或「这东西本来就不是一摞」。
--   ★ 这是 acceptsstacks 在点击路径上的落点（对照第 534 行 GiveItem 里的落点）。
        elseif self:CanTakeItemInSlot(active_item, slot) and
            (self:AcceptsStacks() or
            active_item.components.stackable == nil or
            not active_item.components.stackable:IsStack()) then

            self.currentuser = opener

-- ★★★ inventory:RemoveItem(active_item, true) —— **先从背包取出**，再给容器。
--   ⇒ 关键顺序：先摘出手持状态，再放入容器。
--   ⚠ 若第 1138 行 GiveItem 失败，active_item 会**无处可去**（既不在背包也不在容器）。
--     但 GiveItem 有 drop_on_fail 默认落地（第 558 行），所以会掉在容器脚下。
--     ★ 行为正确但不够优雅（物品掉地上而不是回到背包）。对照 MoveItemFromAllOfSlot
--       第 1384-1387 行有显式回滚，这里的「靠 drop_on_fail 兜底」是更简单的方案。
            inventory:RemoveItem(active_item, true)
-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。
            self.ignoresound = true
            self:GiveItem(active_item, slot)
-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。
            self.ignoresound = false

            self.currentuser = nil
        end
    end
end

-- 【★★ 处理器组 3/7：TakeActiveItemFromHalfOfSlot —— 「拿一半」】
--   ★ 条件：**必须没有手持物**（active_item == nil）——
--     否则与「手持物」语义冲突。这是与前两条的本质区别。
function Container:TakeActiveItemFromHalfOfSlot(slot, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromHalfOfSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:TakeActiveItemFromHalfOfSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromHalfOfSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromHalfOfSlot〕
    local item = self:GetItemInSlot(slot)
-- ★ 四重与：① 槽里有东西 ② ★ 没有手持物 ③ 操作者有 inventory ④ 东西可堆叠。
    if item ~= nil and
-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromHalfOfSlot〕
        active_item == nil and
        inventory ~= nil and
        item.components.stackable ~= nil and
        item.components.stackable:IsStack() then

-- ★ currentuser 临时赋值（跨容器移动的信号，见构造函数第 56 行）。
        self.currentuser = opener

-- ★★★ 超量堆叠的取半逻辑：`IsOverStacked() and originalmaxsize or StackSize()`。
--   翻译：「若超量了，只取**正常上限**那么多的一半」；否则取当前数量的一半。
--   ★ 与第 1181/1216/1434/1499 行是**完全相同**的表达式（本文件出现 6 次），
--     但每次都是手写而非抽函数——重复但正确。
		local fullstacksize = item.components.stackable:IsOverStacked() and item.components.stackable.originalmaxsize or item.components.stackable:StackSize()
-- ★ math.floor(fullstacksize / 2) —— 向下取整。数量为 1 时得 0 ——
--   ⚠ 潜在缺陷：StackSize()==1 的物品不满足 IsStack()（第 1155-1156 行已判），
--     所以 fullstacksize >= 2，halfstack >= 1。安全。
--   ⚠ 但若物品超量且 originalmaxsize == 1（不可能，maxsize 至少 2），会得 0。
		local halfstack = item.components.stackable:Get(math.floor(fullstacksize / 2))
-- ★ prevslot/prevcontainer：记录来源（见第 1034 行说明）。
--   ⚠ 注意这里**没有清空**，因为物品是给回玩家（不是跨容器），保留来源信息。
        halfstack.prevslot = slot
        halfstack.prevcontainer = self
-- ★ inventory:GiveActiveItem(halfstack) —— 交到玩家手上（而不是塞进背包）。
--   ⇒ 「拿一半」的结果是**手持**，玩家可再点击放下或使用。
        inventory:GiveActiveItem(halfstack)

        self.currentuser = nil
    end
end

-- 【★★ 处理器组 4/7：TakeActiveItemFromCountOfSlot —— 「拿 N 个」】
--   ★ 与「拿一半」同型，只是数量来自参数 count（鼠标滚轮/点击次数累计）。
function Container:TakeActiveItemFromCountOfSlot(slot, count, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromCountOfSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:TakeActiveItemFromCountOfSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromCountOfSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromCountOfSlot〕
    local item = self:GetItemInSlot(slot)
-- 条件分支：if item ~= nil and  〔所在：Container:TakeActiveItemFromCountOfSlot〕
    if item ~= nil and
-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromCountOfSlot〕
        active_item == nil and
-- ★ 三重与：① 有东西 ② 没有手持物 ③ 有 inventory。
--   ⚠ 注意这里**不检查是否可堆叠**（第 1155 行的检查在「拿一半」里有，这里没有），
--     而是在第 1183 行的分支里用 `stackable` 存在性兜住。属两种风格。
        inventory ~= nil then
        self.currentuser = opener
-- 局部变量：local stackable = item.components.stackable  〔所在：Container:TakeActiveItemFromCountOfSlot〕
        local stackable = item.components.stackable
-- ★ fullstacksize：超量时取 originalmaxsize，否则取实际数量，非堆叠物按 1。
--   ★ 这是该表达式的第 2 次出现（另见第 1160/1216/1434/1499 行）。
        local fullstacksize = stackable and (stackable:IsOverStacked() and stackable.originalmaxsize or stackable:StackSize()) or 1
-- ★★ math.clamp(count, 1, fullstacksize) —— 防越界。
--   ⇒ 无论调用方传什么（0、负数、99999），实际取值被夹在合法区间。
--   ★ 这是「外部输入（UI 计数）必须校验」的典型位置 —— count 可能来自网络请求。
        count = math.clamp(count, 1, fullstacksize)
-- ★★ 分支一：摞里还有剩 → 拆 count 个，物品留在槽里。
        if stackable and stackable:StackSize() > count then
-- 局部变量：local countedstack = stackable:Get(count)  〔所在：Container:TakeActiveItemFromCountOfSlot〕
            local countedstack = stackable:Get(count)
            countedstack.prevslot = slot
            countedstack.prevcontainer = self
            inventory:GiveActiveItem(countedstack)
-- ⚠ 分支二：拿完整个摞 + 该物品被锁 → assert 炸掉（dev 分支）。
--   ★ 与第 124/250 行的锁定检查同型，但**判定顺序不同**：
--     这里先判「摞不够」再判锁定，所以只有「正好拿完且锁定」才炸。
--   ⚠ 推理：拿一个不足全部的锁定物品（第 1183 行）**不炸** ——
--     而第 250 行 DropItemAt 无论数量都拒绝。两者语义不一致。
--     ★ 判定为 ⚠ 疑似不一致（锁定检查时机）。不改代码。
		elseif item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- assert(BRANCH ~= "dev")  〔所在：Container:TakeActiveItemFromCountOfSlot〕
			assert(BRANCH ~= "dev")
-- 兜底分支（前述条件全不成立）。〔所在：Container:TakeActiveItemFromCountOfSlot〕
        else
-- ★ 分支三：整个取出（RemoveItemBySlot），物品交给玩家手持。
--   ⚠ 注意此分支**没有** islockedinslot 检查（已在第 1188 行处理）。
            self:RemoveItemBySlot(slot)
            inventory:GiveActiveItem(item)
        end

        self.currentuser = nil
    end
end
-- ★★★ 「七处理器 × itemtestfn」速查矩阵（回答任务的核心问题）：
--   ┌ 函数                          │ 手持物 │ 槽状态 │ itemtestfn │ acceptsstacks │ 超量
--   ├───────────────────────────────┼────────┼────────┼────────────┼───────────────┼──────
--   │ PutOneOfActiveItemInSlot(1099) │ 需要   │ 必须空 │ ✓ 1106     │ 不检查       │ 不处理
--   │ PutAllOfActiveItemInSlot(1120) │ 需要   │ 可空可满│ ✓ 1129    │ ✓ 1130       │ 不处理
--   │ TakeActiveItemFromHalfOf(1146) │ 必须无 │ 必须有 │ ✗ 不需要  │ 不检查       │ ✓ 1160
--   │ TakeActiveItemFromCountOf(1170)│ 必须无 │ 必须有 │ ✗        │ 不检查       │ ✓ 1181
--   │ TakeActiveItemFromAllOf(1199) │ 必须无 │ 必须有 │ ✗        │ 不检查       │ ✓ 1216
--   │ AddOneOfActiveItemToSlot(1230) │ 需要   │ 必须有 │ ✓ 1238    │ ✓ 1241       │ 不处理
--   │ AddAllOfActiveItemToSlot(1254) │ 需要   │ 必须有 │ ✓ 1262    │ ✓ 1265       │ 不处理
--   │ SwapActiveItemWithSlot(1276)  │ 需要   │ 必须有 │ ✓ 1285    │ ✓ 1288/1291  │ ✓ 1292 禁
--   ├───────────────────────────────┼────────┴────────┼────────────┼───────────────┼──────
--   │ MoveItemFromAllOfSlot(1332)   │ 不需要 │ —      │ ✓ 1354    │ 目标侧判定   │ ✓ 1356 三策略
--   │ MoveItemFromHalfOfSlot(1412)  │ 不需要 │ —      │ ✓ 1433    │ 目标侧判定   │ ✓ 1434
--   │ MoveItemFromCountOfSlot(1479) │ 不需要 │ —      │ ✓ 1497    │ 目标侧判定   │ ✓ 1499
--   └───────────────────────────────┴────────┴────────┴────────────┴───────────────┴──────
--   ⇒ ★ 三条规律：
--     ① **取出类（Take*）完全不查 itemtestfn** —— 准入只管「进」，不管「出」；
--     ② **放入与合并类（Put/Add/Swap/Move）全部要查**；
--     ③ **超量堆叠只在取出与搬运时处理**（因为放入时 infinitestacksize 会重新放开上限）。

-- 【★★ 处理器组 5/7：TakeActiveItemFromAllOfSlot —— 「全拿走」】
--   ★ 与「拿一半」/「拿 N 个」的区别：**先判锁定再判可堆叠**，顺序相反。
function Container:TakeActiveItemFromAllOfSlot(slot, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromAllOfSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:TakeActiveItemFromAllOfSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromAllOfSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromAllOfSlot〕
    local item = self:GetItemInSlot(slot)
-- 条件分支：if item ~= nil and  〔所在：Container:TakeActiveItemFromAllOfSlot〕
    if item ~= nil and
-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromAllOfSlot〕
        active_item == nil and
        inventory ~= nil then

-- ★ 锁定物品直接拒绝（这里 assert + return，而第 1188 行只 assert）。
--   ★ 第 1211 行的 return 是必要的：assert 在非 dev 分支不崩，会继续往下执行。
		if item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- assert(BRANCH ~= "dev")  〔所在：Container:TakeActiveItemFromAllOfSlot〕
			assert(BRANCH ~= "dev")
-- 返回：return  〔所在：Container:TakeActiveItemFromAllOfSlot〕
			return
		end

        self.currentuser = opener

-- ★★ 超量堆叠：只拿 originalmaxsize 那么多（把超量的部分留在槽里）。
--   ⇒ 语义：「拿一个正常上限的量」，多带的仍归容器。
--   ⚠ 与 TakeActiveItemFromCountOfSlot 第 1181 行的差别：
--     那里的 count 可能 > originalmaxsize，这里固定就是 originalmaxsize。
		if item.components.stackable and item.components.stackable:IsOverStacked() then
-- 局部变量：local fullstack = item.components.stackable:Get(item.components.stackable.originalmaxsize)  〔所在：Container:TakeActiveItemFromAllOfSlot〕
			local fullstack = item.components.stackable:Get(item.components.stackable.originalmaxsize)
			fullstack.prevslot = slot
			fullstack.prevcontainer = self
			inventory:GiveActiveItem(fullstack)
-- 兜底分支（前述条件全不成立）。〔所在：Container:TakeActiveItemFromAllOfSlot〕
		else
-- ★ 非超量或不可堆叠：整个取出，交玩家手持。
			self:RemoveItemBySlot(slot)
			inventory:GiveActiveItem(item)
		end

        self.currentuser = nil
    end
end

-- 【★★ 处理器组 6/7：AddOneOfActiveItemInSlot —— 「加一个」】
--   ★★★ 这是**唯一一个「槽非空」的放置处理器**：
--     它的语义不是「放进空槽」，而是「把手上这一个并入槽里的同类型摞」。
--   ⇒ 七个处理器里唯一要求第 1104 行那个条件**反过来**的。
function Container:AddOneOfActiveItemToSlot(slot, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:AddOneOfActiveItemToSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:AddOneOfActiveItemToSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:AddOneOfActiveItemToSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:AddOneOfActiveItemToSlot〕
    local item = self:GetItemInSlot(slot)
-- ★★★★ 六重与 —— 全文件最长的判定链：
--   ① 有手持物
--   ② 槽里有东西
--   ③ ★★ CanTakeItemInSlot(active_item, slot) —— ★ itemtestfn 的调用点之一
--   ④ 槽里的是可堆叠物
--   ⑤ ★★ CanStackWith(手持物) —— 同类型
--   ⑥ ★★ AcceptsStacks() —— 本容器收整摞
--   ⑦ 手持物是可堆叠物
--   ⑧ ★★ 槽里的摞**未满**（!IsFull）
--   ⇒ 综合语义：「手持物与槽内同类型、未满、本容器允许堆叠 → 并入一个」。
    if active_item ~= nil and
        item ~= nil and
-- ★★ 第 ③ 条 CanTakeItemInSlot(active_item, slot) 的意义：
--   「把 X 并进这个槽」仍然要过一遍 itemtestfn——
--   ⇒ **合并动作也受筛选规则约束**。这一点很容易被忽略：
--     玩家看到「物品类型一样」，但 itemtestfn 可能对 slot 参数有额外限制
--     （如 portablespicer 第 427 行：slot 2 只收 spice）。
--   ★ 所以往香料槽里加香料时，slot 参数确保它走对分支。
        self:CanTakeItemInSlot(active_item, slot) and
        item.components.stackable ~= nil and
        item.components.stackable:CanStackWith(active_item) and
        self:AcceptsStacks() and
        active_item.components.stackable ~= nil and
        active_item.components.stackable:IsStack() and
-- ★★ !item.components.stackable:IsFull() —— ★ 槽里的摞必须没满。
--   ★ 这一条是「AddOneOfActiveItemToSlot 只加一个」的根本原因：
--     若槽已满，加了也加不进去（第 1248 行只 Put 一个）。
        not item.components.stackable:IsFull() then

        self.currentuser = opener

-- ★★★ `item.components.stackable:Put(active_item.components.stackable:Get(1))` ——
--   两步：① 从手持物拆 1 个成新实体；② 把这一整个（size=1）并进槽里的摞。
--   ⇒ 典型实现「加一个」的惯用写法。Put 会返回溢出（这里必然是 nil，因为已 IsFull 检查）。
        item.components.stackable:Put(active_item.components.stackable:Get(1))

        self.currentuser = nil
    end
end

-- 【★★ 处理器组 7/7：AddAllOfActiveItemToSlot —— 「全并进去」】
--   ★ 与第 1230 行的差异：⑤⑥⑦ 相同，但**没有 IsFull 检查**（第 1244 行缺）。
--   ⇒ 因为 Put 能处理「只吃到部分」的情况（第 1269 行的 leftovers）。
function Container:AddAllOfActiveItemToSlot(slot, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:AddAllOfActiveItemToSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:AddAllOfActiveItemToSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:AddAllOfActiveItemToSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:AddAllOfActiveItemToSlot〕
    local item = self:GetItemInSlot(slot)
-- ★ 五重与（比第 1236 行少一条 IsFull）—— 判定条件完全对齐第 1230 行的 ①..⑦。
    if active_item ~= nil and
        item ~= nil and
        self:CanTakeItemInSlot(active_item, slot) and
        item.components.stackable ~= nil and
        item.components.stackable:CanStackWith(active_item) and
-- ★ AcceptsStacks() —— 同第 1241 行。
        self:AcceptsStacks() then

        self.currentuser = opener

-- ★★ leftovers = stackable:Put(active_item) —— 会有「吃不下」的剩余。
--   ★ Put 的返回值语义（stackable.lua:Put）：全部吃下 → nil；吃一部分 → 剩余实体。
        local leftovers = item.components.stackable:Put(active_item)
-- ★★★ inventory:SetActiveItem(leftovers) —— 把吃剩的还回手上。
--   ⇒ 这就是「+全部」的完整语义：能并多少并多少，剩的仍拿着。
--   ⚠ 若 leftovers 为 nil（全部并入），SetActiveItem(nil) = 手上空手。正确。
        inventory:SetActiveItem(leftovers)

        self.currentuser = nil
    end
end

-- 【★★ SwapActiveItemWithSlot —— 「交换」（Ctrl + 点击）】
--   ★ 三分支：① 槽空 → 退化成 PutAll（第 1284 行）；
--     ② 正常交换（第 1285-1303 行）；③ 条件不满足 → 什么都不做。
function Container:SwapActiveItemWithSlot(slot, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:SwapActiveItemWithSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:SwapActiveItemWithSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:SwapActiveItemWithSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:SwapActiveItemWithSlot〕
    local item = self:GetItemInSlot(slot)
-- 条件分支：if active_item ~= nil then  〔所在：Container:SwapActiveItemWithSlot〕
    if active_item ~= nil then
-- 条件分支：if item == nil then  〔所在：Container:SwapActiveItemWithSlot〕
        if item == nil then
            self:PutAllOfActiveItemInSlot(slot, opener)
-- ★★★★ 四条「**不能交换**」的规则（全是 or，任意一条成立就放弃）：
--   ① ★ itemtestfn 不通过（目标容器/槽不接受手上的东西）；
--   ② ★ 槽里的与手持有同类型且本容器收整摞 —— 那该用 Add 不是 Swap；
--   ③ ★ 手持物是可堆叠摞但本容器**不收整摞** —— 换了会丢东西；
--   ④ ★ 槽里的是**超量堆叠** —— 交换会把超量语义搞乱。
--   ⇒ 这四条是「什么时候不该用交换」的完整规则集，非常值得记住。
		elseif self:CanTakeItemInSlot(active_item, slot)
-- ★ 规则②：同类型可堆叠 → 应该走「Add」路径（第 1230/1254 行）而非交换。
			and not (item.components.stackable and
                    item.components.stackable:CanStackWith(active_item) and
					self:AcceptsStacks())
-- ★ 规则③：手持是摞但容器不收整摞 → 交换会导致整摞塞进一格被拆散。
			and not (active_item.components.stackable and
					active_item.components.stackable:IsStack() and
					not self:AcceptsStacks())
-- ★ 规则④：槽内超量堆叠 → 交换后超量语义（原 maxsize 信息）会丢。
--   ⇒ 推论：无限堆叠容器里的东西**不能用 Ctrl+点击 换出去**。
			and not (item.components.stackable and
					item.components.stackable:IsOverStacked())
		then
            self.currentuser = opener

-- ★★★ 三步交换：① 从背包摘下手持物 ② 从容器取出槽内物 ③ 容器放入手持物 ④ 背包交出槽内物。
--   ⚠ 顺序是先全部「取出」再全部「放入」—— 中间态若失败会丢东西。
--     第 1299 行 GiveItem 失败的话，item 会在 drop_on_fail 的默认行为下落地上。
--     ★ 对照 MoveItemFromAllOfSlot（第 1384 行）有显式回滚，这里没有。
--     ★ 判定：健壮性弱于 Move 系列，但场景简单（物品已在手上，不会凭空消失）。
            inventory:RemoveItem(active_item, true)
            self:RemoveItemBySlot(slot)
            self:GiveItem(active_item, slot)
            inventory:GiveActiveItem(item)

            self.currentuser = nil
        end
    end
end

-- 【★ SwapOneOfActiveItemWithSlot —— 「换 1 个」】
--   ★ 与 SwapActiveItemWithSlot 的关键差异：**槽里的整摞保留，只换走一个**。
--   ⇒ 对应玩家操作：拿着 20 个石头，点一个有 5 个石头的格子 → 换 1 个过去，剩 19 个。
function Container:SwapOneOfActiveItemWithSlot(slot, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:SwapOneOfActiveItemWithSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:SwapOneOfActiveItemWithSlot〕
        return
    end
-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:SwapOneOfActiveItemWithSlot〕
    local inventory, active_item = QueryActiveItem(self, opener)
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:SwapOneOfActiveItemWithSlot〕
    local item = self:GetItemInSlot(slot)

-- ★★★★ 五重与：① 手上与槽里都有东西 ② itemtestfn 通过
--   ③ ★ 槽里的与手持有**同类型**（否则不换，见第 1317 行）④ 手持是摞 ⑤ 槽内不是超量。
--   ⚠ 第 1317 行要求 `CanStackWith` 为 **false** —— 即两者**不同类型**才能换。
--     命名上容易混淆：变量叫 SwapOneOf，但条件要求「不可堆叠」。
    if active_item ~= nil and
        item ~= nil and
        self:CanTakeItemInSlot(active_item, slot) and
-- ★★ 条件是 `not (stackable ~= nil and CanStackWith(...))` —— 
--   「两者**不能**堆叠」才交换。若同类型可堆叠，走 Add 路径。
--   ⚠ 与第 1286 行的写法不同（那里是 `not (stackable and CanStackWith)`），
--     这里多了 `stackable ~= nil` 的显式判空。语义等价，风格不同。
        not (item.components.stackable ~= nil and item.components.stackable:CanStackWith(active_item)) and
		(active_item.components.stackable and active_item.components.stackable:IsStack()) and
		not (item.components.stackable and item.components.stackable:IsOverStacked())
	then
        self.currentuser = opener

-- ★ wholestack=false（只取一个）与第 1297 行的 true 形成对照。
        active_item = inventory:RemoveItem(active_item, false)
        self:RemoveItemBySlot(slot)
        self:GiveItem(active_item, slot)
-- ★★ 槽内剩的（item）给回**背包**（不是手持）—— 因为手上已经被占用了。
--   ⇒ 与 SwapActiveItemWithSlot 第 1300 行 GiveActiveItem 的区别：
--     那个把槽内物给回**手上**（因为要腾出手给交换进来的东西）。
--   ★ 两个 Swap 的「回程」路径不同，是刻意设计。
        inventory:GiveItem(item, nil, self.inst:GetPosition())

        self.currentuser = nil
    end
end

-- 【★★★ MoveItemFromAllOfSlot —— 跨容器搬运（全量）】
--   ★ 本文件**最复杂的一个函数**（79 行），也是「搬运事务」的模板。
--   ★ 核心结构（八步）：
--     ① 取出源槽物品（三种超量处理策略）；
--     ② 探测目标槽（建造 UI 优先）；
--     ③ 预检 CanTakeItemInSlot；
--     ④ ★ 挂 5 个 hack flag 到目标容器（ignoreoverflow 等）；
--     ⑤ GiveItem 到目标；
--     ⑥ ★ 失败则回滚（塞回源槽）；
--     ⑦ ★ 无论成败都**清理全部 flag**；
--     ⑧ 清 currentuser。
--   ⇒ 关键设计：**目标可以是 container 组件或 inventory 组件**（第 1342 行），
--     所以「容器→背包」「背包→容器」「容器→容器」走的是同一个函数。
function Container:MoveItemFromAllOfSlot(slot, container, opener)
-- ★ readonlycontainer 的第 6 道防线（跨容器搬运侧）。
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:MoveItemFromAllOfSlot〕
        return
    end
-- ★ 取出源槽物品与目标容器（第 1337 行才校验目标非 nil）。
    local item = self:GetItemInSlot(slot)
-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕
    if item ~= nil and container ~= nil then
-- ★ 源物品被锁 → assert（dev）+ return。★ 与第 1209 行的处理一致。
		if item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- assert(BRANCH ~= "dev")  〔所在：Container:MoveItemFromAllOfSlot〕
			assert(BRANCH ~= "dev")
-- 返回：return  〔所在：Container:MoveItemFromAllOfSlot〕
			return
		end
-- ★★★ `container.components.container or container.components.inventory` ——
--   ★★ 这是本文件最重要的**接口统一手法**：
--     目标既可以是「容器实体」（箱子/背包），也可以是「玩家实体」（物品栏）；
--     通过优先取 container 组件、回退 inventory 组件，把两者当成同一接口用。
--   ⇒ 这使得「从容器拖到背包」与「从背包拖到容器」能复用同一段代码。
--   ★ 与 components/inventory.lua 的 GetOverflowContainer（第 813 行）配套。
        container = container.components.container or container.components.inventory
-- ★★★ `container:IsOpenedBy(opener)` —— 目标必须**正被这个玩家打开**。
--   ⇒ 安全检查：不允许往一个没打开的容器里塞东西（哪怕目标是自己的背包？
--     背包总是 opened 的，所以没问题）。
--   ⚠ 注意这**只检查 opener**，不检查「自己也开着」——
--     但本函数是从本容器（source）的 UI 触发的，source 必然开着。
        if container ~= nil and container:IsOpenedBy(opener) then

            self.currentuser = opener
            container.currentuser = opener

-- ★★★ 建造 UI 的槽位探测：若目标是「建造容器的 UI 数据」且材料匹配，给出目标槽。
--   三重与：① opener 有 constructionbuilderuidata ② 它记录的容器就是目标 ③ 该物品是它需要的材料。
--   ★ 推理：建造材料必须落到指定槽（containers.lua:523 的 itemtestfn 依赖 slot），
--     所以搬运时要预先算出 targetslot，否则会被 GetSpecificSlotForItem 猜错。
--   ★ 同样的三行探测在第 1427/1491 行**重复了两次**（三个 Move 函数各写一遍），
--     没有抽成公共函数。属可接受的重复（各函数的上下文略有差异）。
            local targetslot =
                opener.components.constructionbuilderuidata ~= nil and
                opener.components.constructionbuilderuidata:GetContainer() == container.inst and
                opener.components.constructionbuilderuidata:GetSlotForIngredient(item.prefab) or
                nil

-- ★★★ 搬运前的**强制预检**：`container:CanTakeItemInSlot(item, targetslot)`。
--   ⇒ 即使调用方（UI）已经判过，这里仍再判一次 —— 服务端权威的体现。
            if container:CanTakeItemInSlot(item, targetslot) then
-- 局部变量：local shouldignoresound = false  〔所在：Container:MoveItemFromAllOfSlot〕
				local shouldignoresound = false
-- ★★★ 超量堆叠的三种搬运策略（第 1356-1366 行）：
--   ① 不超量 → 整摞移走（第 1357 行）；
--   ② 超量且目标是无限堆叠容器 → 整摞移走，临时设 ignoreoverstacked（第 1358-1362 行）；
--   ③ 超量且目标不收超量 → ★ 只取 originalmaxsize（第 1364 行），多余留在源容器。
--   ⇒ 这三条覆盖了所有情况，是「超量堆叠」这个特性的完整处理方案。
				if not (item.components.stackable and item.components.stackable:IsOverStacked()) then
-- 局部赋值：item = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromAllOfSlot〕
					item = self:RemoveItemBySlot(slot)
-- 次选条件：elseif container.infinitestacksize then  〔所在：Container:MoveItemFromAllOfSlot〕
				elseif container.infinitestacksize then
					--target container can accept overstacked items!
-- ★ hack flag：取出超量堆叠时**不**把多出的丢地上（第 1042 行）。
--   本行初值：true。
					self.ignoreoverstacked = true
-- 局部赋值：item = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromAllOfSlot〕
					item = self:RemoveItemBySlot(slot)
-- ignoreoverstacked：同第 1360 行（首次初始化），此处显式赋 false。
					self.ignoreoverstacked = false
-- 兜底分支（前述条件全不成立）。〔所在：Container:MoveItemFromAllOfSlot〕
				else
-- ★★ 策略③：`stackable:Get(originalmaxsize)` —— 只拆出「正常上限」那么多。
--   ⇒ 后果：**物品在源容器里分裂成两摞**（拆出去的 + 留下的超量部分）。
--   ★ 这是有意为之：无限堆叠容器不能把「超量」传给普通容器。
					item = item.components.stackable:Get(item.components.stackable.originalmaxsize)
-- ★ shouldignoresound：策略③ 下拆出了新实体，音效状态需要另行处理。
--   ⇒ 第 1385 行用它决定回滚时是否静音（因为此时 ignoresound 可能被策略②改过）。
					shouldignoresound = true
				end
-- 条件分支：if item ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕
                if item ~= nil then
                    item.prevcontainer = nil
                    item.prevslot = nil

-- ★★ 原注释保留：「--Hacks for altering normal inventory:GiveItem() behaviour」
--   ⇒ 这五段 hack 是本函数的灵魂：**临时改写目标容器的行为开关**来避免副作用。
                    --Hacks for altering normal inventory:GiveItem() behaviour
-- ★ hack①：目标是我（source）的溢出容器 → 设 ignoreoverflow，
--   防止「目标满时又溢回我这里」造成自我循环。
--   ⚠ `container.ignoreoverflow ~= nil` 是鸭子类型检查 ——
--     container 组件**没有** ignoreoverflow 字段（第 61-64 行只有四个 hacky flag），
--     所以对容器而言这个检查恒 false；对 inventory 组件才可能为真。
--     ★ 这说明这段代码是为「拖到物品栏」路径设计的，对容器是死分支。仅记录。
                    if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then
                        container.ignoreoverflow = true
                    end
-- ★ hack②：目标是「我的专用容器」→ 设 ignorespoverflow，防止反向吸附循环。
--   ✓ elseif ignoreclosedspoverflow：否则只要目标有这个字段就设。
--   ⚠ 注意 elseif 意味着：当 ignorespoverflow 被设了，就**不**设 ignoreclosedspoverflow。
--     二者语义不同（前者禁用专用容器搜索、后者允许未打开的容器），
--     二选一而非并用，是否有意？对比第 1443/1518 行同样的写法（三处一致）。
--     ★ 三处一致 ⇒ 是刻意选择，不算缺陷。仅记录这个设计决定。
					if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then
						container.ignorespoverflow = true
-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕
					elseif container.ignoreclosedspoverflow ~= nil then
						container.ignoreclosedspoverflow = true
					end
-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕
                    if container.ignorefull ~= nil then
                        container.ignorefull = true
                    end

-- ★★★ GiveItem(item, targetslot, nil, false)：第 4 参数 false = **失败时不落地**。
--   ⇒ 因为要自己处理回滚（第 1386 行），不能让 GiveItem 把物品丢在地上。
                    if not container:GiveItem(item, targetslot, nil, false) then
-- ★★ 回滚：`self:GiveItem(item, slot, nil, true)` —— 塞回**原槽位**，失败则落地。
--   ★ 这里 ignoresound 被设成 shouldignoresound（第 1365 行算出的值）。
--   ⇒ 完整事务语义：「要么成功，要么原样退回」。这是本文件里最接近数据库事务的代码。
                        self.ignoresound = shouldignoresound
                        self:GiveItem(item, slot, nil, true)
-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。
                        self.ignoresound = false
                    end

-- ★★★ 「Hacks」注释的第二次出现（第 1371 行是第一处）—— 成对夹住 GiveItem 调用。
--   ⇒ 结构：挂 flag → 调用 → 清 flag。这是本文件的通用模式。
                    --Hacks for altering normal inventory:GiveItem() behaviour
-- ★★★ 五道清理，每道都有 if 守卫（与第 1372 行挂 flag 的守卫条件一一对应）。
--   ⇒ 设计要点：**挂与清必须用完全相同的条件**，否则会漏清或误清。
--     这里确实做到了对称（ignoreoverflow / ignorespoverflow / ignoreclosedspoverflow / ignorefull 四项），
--     是本文件里最严谨的一段代码。
                    if container.ignoreoverflow then
                        container.ignoreoverflow = false
                    end
-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromAllOfSlot〕
					if container.ignorespoverflow then
						container.ignorespoverflow = false
					end
-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromAllOfSlot〕
					if container.ignoreclosedspoverflow then
						container.ignoreclosedspoverflow = false
					end
-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromAllOfSlot〕
                    if container.ignorefull then
                        container.ignorefull = false
                    end
                end
            end

-- ★ 清 currentuser（无论成功失败）—— 与第 1110/1134 等处的模式一致。
            self.currentuser = nil
            container.currentuser = nil
        end
    end
end

-- 【★ MoveItemFromHalfOfSlot —— 跨容器搬一半】
--   ★ 与 MoveItemFromAllOfSlot 的差异：
--     ① 不需要处理超量（第 1434 行有一行特判）；
--     ② 第 1440 行起多了一个 `container:IsOpenedBy(opener)` 与第 1420 行合并成一个 if；
--     ③ GiveItem **没有传 drop_on_fail=false**（第 1452 行只传两参）—— ⚠ 见下方标注。
function Container:MoveItemFromHalfOfSlot(slot, container, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:MoveItemFromHalfOfSlot〕
    if self.readonlycontainer then
-- 返回：return  〔所在：Container:MoveItemFromHalfOfSlot〕
        return
    end
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:MoveItemFromHalfOfSlot〕
    local item = self:GetItemInSlot(slot)
-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕
    if item ~= nil and container ~= nil then
-- 局部赋值：container = container.components.container or container.components.inventory  〔所在：Container:MoveItemFromHalfOfSlot〕
        container = container.components.container or container.components.inventory
-- 条件分支：if container ~= nil and  〔所在：Container:MoveItemFromHalfOfSlot〕
        if container ~= nil and
-- ★★ 四重与（比 MoveItemFromAllOfSlot 第 1337 行多两条）：
--   ① 目标存在 ② 目标被 opener 打开 ③ 源物品可堆叠 ④ 是摞。
--   ⇒ 「拿一半」天然要求可堆叠，所以这里比全量版多两条前置。
            container:IsOpenedBy(opener) and
            item.components.stackable ~= nil and
            item.components.stackable:IsStack() then

            self.currentuser = opener
            container.currentuser = opener

-- 局部变量：local targetslot =  〔所在：Container:MoveItemFromHalfOfSlot〕
            local targetslot =
                opener.components.constructionbuilderuidata ~= nil and
                opener.components.constructionbuilderuidata:GetContainer() == container.inst and
                opener.components.constructionbuilderuidata:GetSlotForIngredient(item.prefab) or
                nil

-- 条件分支：if container:CanTakeItemInSlot(item, targetslot) then  〔所在：Container:MoveItemFromHalfOfSlot〕
            if container:CanTakeItemInSlot(item, targetslot) then
-- ★★★ `not container.infinitestacksize and IsOverStacked() and originalmaxsize or StackSize()`
--   ★★ 这是**唯一一处带 `not X and ... or ...` 三段链**的满量表达式，稍难读：
--     · 目标是普通容器 且 源超量 → 取 originalmaxsize（只搬正常上限）；
--     · 其他情况 → 取 StackSize()（实际数量）。
--   ⚠ 与第 1160/1181/1216/1499 行的表达式**不同**（多了 not infinitestacksize 前缀），
--     因为搬一半时若目标是无限堆叠容器，可以连超量一起搬。
--   ⇒ ★ 这是全文件里「超量堆叠」处理最精细的一处，值得逐字读。
				local fullstacksize = not container.infinitestacksize and item.components.stackable:IsOverStacked() and item.components.stackable.originalmaxsize or item.components.stackable:StackSize()
-- 局部变量：local halfstack = item.components.stackable:Get(math.floor(fullstacksize / 2))  〔所在：Container:MoveItemFromHalfOfSlot〕
				local halfstack = item.components.stackable:Get(math.floor(fullstacksize / 2))
-- ★ prevcontainer / prevslot 置 nil —— 跨容器搬运时**清除来源记忆**。
--   ★ 对照第 1034 行（移除时**设置**来源）。一设一清，形成完整语义。
--   ⚠ ⚠ 但第 1452-1456 行的回滚路径 `self:GiveItem(halfstack, slot, ...)`
--     不会重设 prevslot —— 回滚后的物品丢失了「来自哪个槽」的信息。
--     ★ 轻微不一致（正常路径清了、回滚路径没恢复）。不改代码。
                halfstack.prevcontainer = nil
                halfstack.prevslot = nil

                --Hacks for altering normal inventory:GiveItem() behaviour
-- 条件分支：if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then  〔所在：Container:MoveItemFromHalfOfSlot〕
                if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then
                    container.ignoreoverflow = true
                end
-- 条件分支：if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then  〔所在：Container:MoveItemFromHalfOfSlot〕
				if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then
					container.ignorespoverflow = true
-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕
				elseif container.ignoreclosedspoverflow ~= nil then
					container.ignoreclosedspoverflow = true
				end
-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕
                if container.ignorefull ~= nil then
                    container.ignorefull = true
                end

-- ⚠ 疑似缺陷：`container:GiveItem(halfstack, targetslot)` —— ★ **第 3/4 参数缺省**。
--   推理依据：
--     ① 对照第 1384 行全量版：`container:GiveItem(item, targetslot, nil, false)`
--        显式传了 drop_on_fail=false；
--     ② 缺省时 drop_on_fail 为 nil → 第 558 行 `~= false` 成立 → **失败会落地**；
--     ③ 于是第 1453-1455 行的回滚逻辑处理的是「物品已在地上」的情况，
--        它会再调 self:GiveItem 把地上的物品塞回源容器 —— 能「救回来」，
--        但中间有一帧物品在地上，玩家会看到物品闪一下。
--     ④ MoveItemFromCountOfSlot（第 1527 行）也是同样的缺省。
--   ⇒ 综合判定：**不是逻辑 bug（能救回），但缺少第 1384 行的显式 false**，
--     导致多一次落地 + 视觉闪烁。★ 标为 ⚠ 疑似缺陷，不改代码。
                if not container:GiveItem(halfstack, targetslot) then
-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。
                    self.ignoresound = true
                    self:GiveItem(halfstack, slot, nil, true)
-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。
                    self.ignoresound = false
                end

                --Hacks for altering normal inventory:GiveItem() behaviour
-- 条件分支：if container.ignoreoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕
                if container.ignoreoverflow then
                    container.ignoreoverflow = false
                end
-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕
				if container.ignorespoverflow then
					container.ignorespoverflow = false
				end
-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕
				if container.ignoreclosedspoverflow then
					container.ignoreclosedspoverflow = false
				end
-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromHalfOfSlot〕
                if container.ignorefull then
                    container.ignorefull = false
                end
            end

            self.currentuser = nil
            container.currentuser = nil
        end
    end
end

-- 【★ MoveItemFromCountOfSlot —— 跨容器搬 N 个】
--   ★ 与前两者的结构完全一致，只是把「一半」换成「count 个」。
function Container:MoveItemFromCountOfSlot(slot, container, count, opener)
-- 条件分支：if self.readonlycontainer then  〔所在：Container:MoveItemFromCountOfSlot〕
    if self.readonlycontainer then
-- ★ fullstacksize：超量 → originalmaxsize，否则实际数量，非堆叠按 1。
--   ★ 这是该表达式的第 4 次出现（另见第 1160/1181/1216/1434 行）。
        return
    end
-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:MoveItemFromCountOfSlot〕
    local item = self:GetItemInSlot(slot)
-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕
    if item ~= nil and container ~= nil then
-- 局部赋值：container = container.components.container or container.components.inventory  〔所在：Container:MoveItemFromCountOfSlot〕
        container = container.components.container or container.components.inventory
-- 条件分支：if container ~= nil and container:IsOpenedBy(opener) then  〔所在：Container:MoveItemFromCountOfSlot〕
        if container ~= nil and container:IsOpenedBy(opener) then

            self.currentuser = opener
            container.currentuser = opener

-- 局部变量：local targetslot =  〔所在：Container:MoveItemFromCountOfSlot〕
            local targetslot =
                opener.components.constructionbuilderuidata ~= nil and
                opener.components.constructionbuilderuidata:GetContainer() == container.inst and
                opener.components.constructionbuilderuidata:GetSlotForIngredient(item.prefab) or
                nil

-- 条件分支：if container:CanTakeItemInSlot(item, targetslot) then  〔所在：Container:MoveItemFromCountOfSlot〕
            if container:CanTakeItemInSlot(item, targetslot) then
-- 局部变量：local stackable = item.components.stackable  〔所在：Container:MoveItemFromCountOfSlot〕
                local stackable = item.components.stackable
-- 局部变量：local fullstacksize = stackable and (stackable:IsOverStacked() and stackable.originalmaxsize or stackable:StackSize()) or 1  〔所在：Container:MoveItemFromCountOfSlot〕
                local fullstacksize = stackable and (stackable:IsOverStacked() and stackable.originalmaxsize or stackable:StackSize()) or 1
-- 局部赋值：count = math.clamp(count, 1, fullstacksize)  〔所在：Container:MoveItemFromCountOfSlot〕
                count = math.clamp(count, 1, fullstacksize)
-- 局部变量：local countedstack  〔所在：Container:MoveItemFromCountOfSlot〕
                local countedstack
-- ★ 分支一：摞里还有剩 → 拆 count 个（物品留在源槽）。
                if stackable and stackable:StackSize() > count then
-- 局部赋值：countedstack = stackable:Get(count)  〔所在：Container:MoveItemFromCountOfSlot〕
                    countedstack = stackable:Get(count)
-- ⚠ 分支二：正好拿完 + 该物品被锁 → assert（dev）。
--   ★ 与第 1188 行 TakeActiveItemFromCountOfSlot 同型，但**这里没有 return**，
--     assert 在非 dev 分支不生效后会继续走到第 1507 行 `countedstack = self:RemoveItemBySlot(slot)`
--     —— ★ 即：**在正式版分支里会真的移除被锁物品**！
--   ⚠ 对照第 1188-1193 行：那里第 1190 行是 elseif item.components.inventoryitem……
--     结构不同；第 1188 行的分支也没有 else 兜底。
--   ★ 综合判定：两处都是「dev 才炸」，正式版行为不理想。仅标注，不改代码。
				elseif item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- assert(BRANCH ~= "dev")  〔所在：Container:MoveItemFromCountOfSlot〕
					assert(BRANCH ~= "dev")
-- 兜底分支（前述条件全不成立）。〔所在：Container:MoveItemFromCountOfSlot〕
                else
-- 局部赋值：countedstack = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromCountOfSlot〕
                    countedstack = self:RemoveItemBySlot(slot)
                end

-- ★ 三重与：① countedstack 非 nil ② 清 prev 字段 ③ 目标可收。
--   ⚠ 注意 countedstack 可能是 nil（分支二被锁时）——第 1510 行的 if 守住了。
				if countedstack then
					countedstack.prevcontainer = nil
					countedstack.prevslot = nil

					--Hacks for altering normal inventory:GiveItem() behaviour
-- 条件分支：if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then  〔所在：Container:MoveItemFromCountOfSlot〕
					if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then
						container.ignoreoverflow = true
					end
-- 条件分支：if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then  〔所在：Container:MoveItemFromCountOfSlot〕
					if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then
						container.ignorespoverflow = true
-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕
					elseif container.ignoreclosedspoverflow ~= nil then
						container.ignoreclosedspoverflow = true
					end
-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕
					if container.ignorefull ~= nil then
						container.ignorefull = true
					end

-- 条件分支：if not container:GiveItem(countedstack, targetslot) then  〔所在：Container:MoveItemFromCountOfSlot〕
					if not container:GiveItem(countedstack, targetslot) then
-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。
						self.ignoresound = true
						self:GiveItem(countedstack, slot, nil, true)
-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。
						self.ignoresound = false
-- ★★ 至此本文件的整体结构（1651 行的四段划分）：
--   ① 1-118    类定义 / 属性 setter / WidgetSetup —— 「装配」
--   ② 120-445  掉落 / 准入 / 容量查询     —— 「维护」
--   ③ 447-1053 增删改查 / 供料 / 存档   —— 「数据」
--   ④ 1055-1330 自动关闭 / 点击处理器   —— 「交互」
--   ⑤ 1332-1651 跨容器搬运 / 开关       —— 「事务」
--   ⇒ ★ 分区注释（第 1055/1091 行）就是团队自己画的这个结构图。
					end

					--Hacks for altering normal inventory:GiveItem() behaviour
-- 条件分支：if container.ignoreoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕
					if container.ignoreoverflow then
						container.ignoreoverflow = false
					end
-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕
					if container.ignorespoverflow then
						container.ignorespoverflow = false
					end
-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕
					if container.ignoreclosedspoverflow then
						container.ignoreclosedspoverflow = false
					end
-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromCountOfSlot〕
					if container.ignorefull then
						container.ignorefull = false
					end
				end
            end

            self.currentuser = nil
            container.currentuser = nil
        end
    end
end

-- 【★ ReferenceAllItems：向引擎登记所有需要「随实体一起保存」的物品】
--   ★ 用途：让这些物品实体被纳入存档的引用图（防止它们被 GC 或重复生成）。
--   ⚠ 与 GetAllItems（第 606 行）的区别：**这个按 1..numslots 有序**，
--     那个用 pairs 无序。顺序在这里有意义（存档/引用顺序要稳定）。
function Container:ReferenceAllItems()
-- 局部变量：local items = {}  〔所在：Container:ReferenceAllItems〕
    local items = {}
-- 循环：for i=1,self.numslots do  〔所在：Container:ReferenceAllItems〕
    for i=1,self.numslots do
-- 条件分支：if self.slots[i] ~= nil then  〔所在：Container:ReferenceAllItems〕
        if self.slots[i] ~= nil then
-- table.insert(items, self.slots[i])  〔所在：Container:ReferenceAllItems〕
            table.insert(items, self.slots[i])
        end
    end
-- 返回：return items  〔所在：Container:ReferenceAllItems〕
    return items
end

-- 【★★ EnableInfiniteStackSize —— 只读开关的合法入口】
--   ★ `rawget(self, "_")` 直接拿底层属性存储，绕过 setter ——
--     见 class.lua 的 property setter 实现。这是**唯一**能写这些字段的路径。
--   ★ 幂等：已经是该状态时直接跳过（`if not _.x[1] then`），避免重复网络同步。
function Container:EnableInfiniteStackSize(enable)
-- 局部变量：local _ = rawget(self, "_") --see class.lua for property setters implementation  〔所在：Container:EnableInfiniteStackSize〕
	local _ = rawget(self, "_") --see class.lua for property setters implementation
-- 条件分支：if enable then  〔所在：Container:EnableInfiniteStackSize〕
	if enable then
-- 条件分支：if not _.infinitestacksize[1] then  〔所在：Container:EnableInfiniteStackSize〕
		if not _.infinitestacksize[1] then
			_.infinitestacksize[1] = true
-- 循环：for i = 1, self.numslots do  〔所在：Container:EnableInfiniteStackSize〕
			for i = 1, self.numslots do
-- 局部变量：local item = self.slots[i]  〔所在：Container:EnableInfiniteStackSize〕
				local item = self.slots[i]
-- 条件分支：if item and item.components.stackable then  〔所在：Container:EnableInfiniteStackSize〕
				if item and item.components.stackable then
					item.components.stackable:SetIgnoreMaxSize(true)
				end
			end
-- ★★★ replica:EnableInfiniteStackSize(true) —— 通知客户端。
--   ⇒ 客户端据此知道「这个容器不显示堆叠数字上限」。
--   ⚠ ⚠ 疑似缺陷：这行在 **for 循环体内部**（第 1576 行），意味着它被调用了
--     **numslots 次**！对照第 1587 行（关闭时）也在循环体内。
--     推理：netvar 的重复 set 同一值通常无害（幂等），所以不会出错，
--       但这是明显的**代码位置错误**（应在循环外）。
--   ⇒ ★ 判定为 ⚠ 真实缺陷（冗余的重复网络写入）。不改代码。
			self.inst.replica.container:EnableInfiniteStackSize(true)
		end
-- ★ elseif 分支：从 true → false。检查 `_.x[1]` 为真才执行，保证幂等。
	elseif _.infinitestacksize[1] then
		_.infinitestacksize[1] = nil
-- ★ 取出容器的世界坐标 —— 用来把超量部分丢在**容器所在处**。
		local x, y, z = self.inst.Transform:GetWorldPosition()
-- 循环：for i = 1, self.numslots do  〔所在：Container:EnableInfiniteStackSize〕
		for i = 1, self.numslots do
-- 局部变量：local item = self.slots[i]  〔所在：Container:EnableInfiniteStackSize〕
			local item = self.slots[i]
-- 条件分支：if item and item.components.stackable then  〔所在：Container:EnableInfiniteStackSize〕
			if item and item.components.stackable then
-- ★★ DropOverstackedExcess(item)：★ 关闭无限堆叠时必须先「还回」超量部分，
--   否则那些超出原上限的物品会永远超量（栈显示数字异常）。
--   ⚠ 关闭操作会把物品丢到地上 —— 这是**有副作用的开关**：
--     「关掉无限堆叠」= 「把多出来的部分吐出来」。
--     对比开启操作（第 1573 行）只是改标志，没有任何副作用。**不对称**。
--     ★ 这可能是有意的（必须清理），但调用方需知情。
				self:DropOverstackedExcess(item)
				item.components.stackable:SetIgnoreMaxSize(false)
			end
			self.inst.replica.container:EnableInfiniteStackSize(false)
		end
	end
end

-- 【★★ ReadOnlyContainerAssert_in/out —— 只读容器的「自检陷阱」】
--   ★ 设计非常巧妙：**用监听器代替 if 判断**。
--     正常路径下第 275/1021 行会拦住一切，这些断言永远不触发；
--     一旦有代码绕过了那些闸门，这里立即炸并 dump 现场数据。
--   ⇒ 这是「防御性编程的最后一层」：不依赖调用方守规矩，而是主动检测违规。
local function ReadOnlyContainerAssert_in(item, data)
-- ★ 打印现场数据：print + dumptable(data) —— dump 的是 PushEvent 的数据表。
--   ⚠ 注意这在正式版也会执行（没有 if 保护）—— 但因为只在违规时才走到，无害。
    print("__ DATA __")
-- dumptable(data)  〔所在：ReadOnlyContainerAssert_in〕
    dumptable(data)
-- print("Time to assert, please report this.")  〔所在：ReadOnlyContainerAssert_in〕
    print("Time to assert, please report this.")
-- ★★ assert(false, string.format(...)) —— 主动崩溃并给出可读信息。
--   ⚠ 这里用了 `string.format` —— ★ grep 核实：标准 Lua 的 string 库**没有** format，
--     它是 Klei 引擎注入的扩展（全库 917 处 string.format 使用，故确实可用）。
--   ⇒ 这类「引擎扩展 API」在读代码时容易误判为标准库，需留意。
    assert(false, string.format("VERY BAD! Item %s was transferred into a read only container.", tostring(item)))
end

-- ReadOnlyContainerAssert_out：与 _in 完全对称，只是文案改为「transferred out」。
--   ★ 注意 out 版监听的是 "itemlose" 事件（第 1619 行）。
local function ReadOnlyContainerAssert_out(item, data)
-- print("__ DATA __")  〔所在：ReadOnlyContainerAssert_out〕
    print("__ DATA __")
-- dumptable(data)  〔所在：ReadOnlyContainerAssert_out〕
    dumptable(data)
-- print("Time to assert, please report this.")  〔所在：ReadOnlyContainerAssert_out〕
    print("Time to assert, please report this.")
-- assert(false, string.format("VERY BAD! Item %s was transferred out of a read only container.", tostring(item)))  〔所在：ReadOnlyContainerAssert_out〕
    assert(false, string.format("VERY BAD! Item %s was transferred out of a read only container.", tostring(item)))
end

-- 【★★ EnableReadOnlyContainer —— 只读开关的合法入口】
--   ★ 除置标志外，还有**两个额外副作用**（这与 infinitestacksize 不同）：
--     ① 自动挂一个 preserver 组件（防腐/恒温）；
--     ② 挂两个断言监听器。
--   ⇒ 只读容器 = 「不能动的展柜」：物品既不能进也不能出，且永不腐坏。
function Container:EnableReadOnlyContainer(enable)
-- 局部变量：local _ = rawget(self, "_") --see class.lua for property setters implementation  〔所在：Container:EnableReadOnlyContainer〕
    local _ = rawget(self, "_") --see class.lua for property setters implementation
-- 条件分支：if enable then  〔所在：Container:EnableReadOnlyContainer〕
    if enable then
-- 条件分支：if not _.readonlycontainer[1] then  〔所在：Container:EnableReadOnlyContainer〕
        if not _.readonlycontainer[1] then
            _.readonlycontainer[1] = true
-- ★★ 只有在「自己还没有 preserver 组件」时才添加。
--   ⇒ 若 prefab 自己就有 preserver（如冰箱），就不重复加。
--   ★ 这避免了对同一组件的重复配置（会让原有速率设置被覆盖）。
            if not self.inst.components.preserver then
                self.readonlycontainer_addedpreserver = true
                self.inst:AddComponent("preserver")
-- ★ SetPerishRateMultiplier(0) —— 腐坏速率归零。
--   ⇒ 只读容器里的东西**永远不会腐坏**，即使它是易腐品。
--   ★ 这是只读容器最重要的玩法语义：「展示柜 = 永久保存」。
                self.inst.components.preserver:SetPerishRateMultiplier(0)
-- ★ SetTemperatureRateMultiplier(0) —— 温度变化速率归零。
--   ⇒ 同理：温度也不变化（不会冻伤/不会升温）。
                self.inst.components.preserver:SetTemperatureRateMultiplier(0)
            end

-- ★ 挂上「只读违规」断言监听器（见第 1592 行的设计说明）。
            self.inst:ListenForEvent("itemget", ReadOnlyContainerAssert_in)
            self.inst:ListenForEvent("itemlose", ReadOnlyContainerAssert_out)
            self.inst.replica.container:EnableReadOnlyContainer(true)
        end
-- ★ 关闭分支：移监听器 + 撤销 netvar + 移除自动加的 preserver。
    elseif _.readonlycontainer[1] then
        _.readonlycontainer[1] = nil
        self.inst:RemoveEventCallback("itemget", ReadOnlyContainerAssert_in)
        self.inst:RemoveEventCallback("itemlose", ReadOnlyContainerAssert_out)
        self.inst.replica.container:EnableReadOnlyContainer(false)
-- ★★ readonlycontainer_addedpreserver：标记「这个 preserver 是我加的」。
--   ⇒ 关闭时**只移除自己加的**，不动 prefab 自带的。
--   ★ 这是「谁装的谁负责拆」的正确模式，避免误伤。
        if self.readonlycontainer_addedpreserver then
-- 条件分支：if self.inst.components.preserver then  〔所在：Container:EnableReadOnlyContainer〕
            if self.inst.components.preserver then
                self.inst:RemoveComponent("preserver")
            end
            self.readonlycontainer_addedpreserver = nil
        end
    end
end

-- 【★ IsRestricted：restrictedtag 的实现】
--   ★ 注意第 1637 行的提前返回：**非玩家实体一律「不受限」**。
--   ⚠ 与构造函数第 51 行的原注释「-- Only entities with this tag can interact.」
--     **不完全一致** —— 注释说「只有带此标签的实体能交互」，
--     但实现只对玩家做判定（其他生物如月亮的眼睛也能开）。
--     ⇒ ★ 文档与实现的偏差。仅标注，不改代码。
function Container:IsRestricted(target)
-- 条件分支：if not target:HasTag("player") then  〔所在：Container:IsRestricted〕
    if not target:HasTag("player") then
        -- Restricted tags only apply to players.
-- 返回：return false  〔所在：Container:IsRestricted〕
        return false
    end

-- ★★★ 三重与：设了 restrictedtag **且** 非空串 **且** 目标没有该标签。
--   `:len() > 0` 的检查防的是「restrictedtag = ""」被当成有效标签。
--   ⚠ 但注意 restrictedtag 从未被本文件赋值（构造函数第 51 行已注释），
--     所以除非外部 prefab/模组显式设置，这个函数恒返回 false。
--     ★ 与 thiefproof/droponopen/skipautoclose 一样，是一个**预留接口**。
    return self.restrictedtag ~= nil
        and self.restrictedtag:len() > 0
        and not target:HasTag(self.restrictedtag)
end

-- 【★ IsThiefProof】直接返回 self.thiefproof ——
--   ⚠ 而该字段在构造函数第 52 行**整行注释掉了**，本文件也无任何赋值。
--   ⇒ ★ 恒返回 nil（falsy）= 「不防贼」。
--     真正的防贼逻辑在 prefab 层（如 prefabs/safe.lua 自己判断）。
--     消费方 grep 核实：IsThiefProof 的调用点极少，且都在做**否定**判断。
--   ⇒ 这是一个**残留的空壳 API**，保留是为了接口兼容。仅标注。
function Container:IsThiefProof()
-- 返回：return self.thiefproof  〔所在：Container:IsThiefProof〕
    return self.thiefproof
end

-- 返回：return Container  〔所在：Container:IsThiefProof〕
return Container
