--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/inventory.lua（2755 行，DST 物品栏的唯一权威实现）
-- 模块：物品栏系统 / 服务端权威库存（Inventory）
-- 职责：回答「这个实体身上现在有什么东西、放得下吗、装得下吗」。
--   它同时承担四个通常被拆开的职责：
--   ① 槽位模型 —— itemslots（普通槽）/ equipslots（装备槽）/ activeitem（手持）
--      三张表 + 一个「溢出容器」（背包）指针，构成完整的物品视图；
--   ② 增删改查 —— GiveItem / RemoveItem / Equip / Unequip 四条主干，
--      每一条都带「往哪放、放不下怎么办、要不要通知客户端」三层决策；
--   ③ 联机同步的事件源 —— 本文件**只 PushEvent**，不发网络数据；
--      真正的网络同步在 inventory_replica.lua:22-26 监听这五个事件
--      并写进 inventory_classified 的 netvar（见下）；
--   ④ 合成供料 —— Has / GetCraftingIngredient / ConsumeByName 三件套，
--      为 components/builder.lua 的扣除逻辑提供「取哪几个、按什么顺序」。
--
-- ★★ 全文件最重要的认知一：**Inventory 不持有物品数据，只持有实体引用**。
--   itemslots[3] 存的是一个 Entity，不是 {name=..., count=...} 这样的结构体。
--   物品的一切属性（可堆叠 / 会腐烂 / 可燃 / 是武器）都挂在实体自己的
--   组件上（inst.components.stackable / perishable / fuel / weapon）。
--   ⇒ 推论：本文件里所有 `item.components.X ~= nil` 判定，都是
--   「按标签能力查询」而不是「按类型分派」。新增一种物品能力，
--   只需加一个组件 + 一个 if，不需要改 Inventory 的任何分派表。
--   ★ 这正是 DST 相对多数引擎「物品大枚举表」的设计优势。
--
-- ★★ 全文件最重要的认知二：**槽位下标是稀疏的、不可信的**。
--   · itemslots 是以 1..maxslots 为下标的数组，但可能只有 [1] 和 [7] 有值；
--   · 大量查询用 pairs() 遍历（无序），只有涉及「找空位/排序」时才用
--     1..maxslots 的 for 循环（有序）；
--   · 为什么存稀疏？因为 RemoveItem 时只是 self.itemslots[k] = nil（1407 行），
--     不做元素搬移。搬移会让「物品在客户端的显示位置」无故跳变，
--     而背包是有视觉记忆的——玩家会记住「斧头在第 4 格」。
--   ★ 代价：槽位编号会越来越乱，UI 必须容忍空洞（inventory 的贴图绘制
--     是按 1..maxslots 逐个问 GetItemInSlot 的，见 777 行）。
--
-- ★★ 全文件最重要的认知三：**客户端从不查询服务端的状态，它读 netvar**。
--   本文件 1085 行附近大量 `self.inst:PushEvent("itemget", {...})`，这些事件
--   在**服务端**被 inventory_replica.lua:22-26 的匿名函数接住，转写成
--   inventory_classified 的 netvar（self.classified:SetSlotItem 等）。
--   客户端 inventory_replica.lua:332 GetItems() 读的是 classified 而非本组件。
--   ⚠ grep 核实：本文件**不存在** Reclientify / RepackInventory / GetSlots /
--     GetItems 四个方法（全库 grep 零命中）。任务描述里提到的这三个
--     「联机同步机制」函数在 DST 中并不存在，请勿按图索骥：
--     · 取代 Reclientify 的是 classified 的 netvar 自动同步（见上）；
--     · 取代 RepackInventory 的是 GetNextAvailableSlot（813 行）的选位算法；
--     · 取代 GetSlots/GetItems 的是 inventory_replica.lua:332 GetItems()
--       与 GetEquips()（340 行）——它们是**只读快照**，不是活表。
--
-- 关键符号：Inventory（类）, itemslots, equipslots, activeitem, maxslots,
--   GiveItem, RemoveItem, RemoveItemBySlot, Equip, Unequip, SetActiveItem,
--   GiveActiveItem, DropItem, DropEverything, GetNextAvailableSlot,
--   CanTakeItemInSlot, CanAcceptCount, GetOverflowContainer,
--   GetSpecializedContainers, GetCraftingIngredient, ConsumeByName,
--   ApplyDamage, GetWaterproofness, GetEquippedMoistureRate,
--   OnSave, OnLoad, TransferInventory, SwapEquipment
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 components/inventory_replica.lua —— 事件 → netvar 的转写层
--   ★★ 参见 prefabs/inventory_classified.lua —— 真正的网络数据载体
--   参见 components/inventoryitem.lua:315 GetSlotNum（prevslot 的来源）
--   参见 components/inventoryitem.lua:344 OnPutInInventory（湿气继承点）
--   参见 components/inventoryitem.lua:468 RemoveFromOwner（拆卸的统一入口）
--   参见 components/equippable.lua —— 装备槽与属性加成的另一半
--   参见 components/stackable.lua —— Put/Get/SetStackSize 的堆叠语义
--   参见 components/container.lua:Container —— 溢出容器与专用容器
--   参见 components/builder.lua:500 GetIngredients —— 合成取料入口
--   参见 components/builder.lua:546 RemoveIngredients —— 合成扣料执行
--   参见 components/builder.lua:592 HasCharacterIngredient —— 角色代价判定
--   参见 recipe.lua —— 配方数据结构（本文件的产出目标）
--   参见 equipslotutil.lua:31 EquipSlotToID（槽位名 ↔ 网络整数）
--   参见 constants.lua:652 EQUIPSLOTS（仅 4 槽：hands/head/body/beard）
--   参见 prefabs/player_classified.lua —— heavylifting / floaterheld 的消费点
--============================================================
--
--【阅读导航】
--  §零   事件回调与类构造（1-97）    —— ★★ 六个 ignore* 临时开关
--  §一   数量查询（99-115）          —— ★★ NumItems 与 NumStackedItems 的区别
--  §二 ★★ 库存转移与装备交换（117-190）
--  §三 ★ 存档与读档（192-325）      —— ★ references 与 isloading
--  §四   装备查询（327-406）        —— 三个标签族查询
--  §五 ★★★ ApplyDamage（408-500）  —— ★★ 全文件唯一的伤害结算算法
--  §六   手持物品操作（502-586）    —— ★ 五个槽位选择函数
--  §七 ★★ 查询接口（588-719）      —— ★★ 六个遍历函数的范围差异
--  §八 ★★★ 选位算法（801-1010）   —— ★★ GetNextAvailableSlot / CanAcceptCount
--  §九 ★★ 溢出与专用容器（1456-1504）
--  §十★★★ GiveItem（1012-1217）    —— ★★★ 全文件最核心的函数
--  §十一★★ 装备与卸下（1219-1388）—— ★★ Equip 的 12 个步骤
--  §十二★★ RemoveItem（1390-1454） —— ★★ 兜底 return item 的含义
--  §十三 ★ 合成供料（1690-1799）    —— ★★ crafting_priority_fn 排序
--  §十四   丢弃与清空（1801-1999）  —— ★ 三种 DropEverything
--  §十五   调试与开合（2001-2124）  —— ★ isopen vs isvisible
--  §十六 ★★ 槽位点击动作（2126-2257）—— ★★ 11 个 InvSlot 处理器
--  §十七   物品使用（2259-2511）    —— ★ CanAccessItem 权限闸门
--  §十八★★ 移入容器（2513-2690）  —— ★★ constructionbuilderuidata 联动
--  §十九 ★ 属性汇总（2692-2755）    —— ★★ 湿度/防水/装备查询
--
--【★★ 全文件最重要的十二条】
--  1. ★★ 本文件持有的是**实体引用**，不是数据结构。
--     itemslots[3] 是一个 Entity 实例，**不是** {name=...,count=...}。
--     ⇒ 所有「物品属性」都来自实体上的组件：
--       stackable（堆叠）/ perishable（腐坏）/ fuel（燃料）/
--       weapon（武器）/ armor（护甲）/ equippable（装备）…
--     一个物品能做什么，由它挂了哪些组件决定，**不由本文件的 if 链决定**。
--     ★ 这是 DST 物品系统的核心设计：组件组合优于类型继承。
--     对比 actions.lua 的 ACTIONS 表：动作是**原型 + 编号**，
--     而物品是**实例 + 组件**，两者的扩展方式完全不同。
--  2. ★★ 槽位模型 = 两个数组 + 一个活跃槽：
--       self.itemslots[1..maxslots]   普通背包格，**稀疏**
--       self.equipslots[槽位名]       装备槽，键是字符串（constants.lua:652）
--       self.activeitem              「手上拿着」的那一个（最多一个）
--     ★★ 手上物品**不占背包格**。这解释了为什么 GiveItem 在背包满时
--       仍会把物品塞进 activeitem（1178-1186 行）而不是丢弃。
--  3. ★★ ★ 关键设计：背包满了物品仍能拿在手上（1178 行判定 maxslots > 0）。
--     这是有意为之：避免玩家「捡了东西却被迫扔掉上一件」，
--     也让「手上拿一件 + 背包满」成为合法状态。
--     ★ 推论：activeitem 是一个**溢出缓冲**，不是「当前选中项」。
--  4. ★★ GetNextAvailableSlot（813 行）的搜索顺序就是「物品栏的优先级」：
--       ① 能合并的堆叠（先查装备槽 equipstack，再查普通槽）
--       ② 溢出容器（背包本体）里的堆叠
--       ③ 专用容器（弹药袋等）里的堆叠
--       ④ 空槽：溢出容器 → 专用容器 → 背包
--     ★★ 关键：**永远先尝试合并已有堆叠**，最后才开新槽。
--       这就是为什么 20 个石头不会占 20 格。
--  5. ★★ CanAcceptCount（912 行）回答的是「一次能收多少」，
--     与 GetNextAvailableSlot 回答的「下一个放哪」是两回事。
--     ★ 912 行的 stacksize 计算有个易错点：islockedinslot 时用
--       `math.max(maxcount or math.huge, stacksize - 1)`，
--       意思是最多只从这一摞里取一个（保底），其余可另开槽。
--  6. ★★ ★ Reclientify / RepackInventory 在本文件**不存在**。
--     grep 全库核实：这两个名字零命中。UI 同步的真正机制是：
--       本文件 PushEvent("itemget") / ("itemlose") / ("equip") …
--       → inventory_replica.lua:22-26 的服务端监听器接住
--       → 转成 inventory_classified 的 netvar（SetSlotItem/SetSlotEquip）
--       → 客户端 inventory_replica 的 dirty 回调刷新 UI。
--     ⇒ 「槽位变化如何反映到客户端」的三层链路：
--       Inventory(本文件) → inventory_replica(服务端中转) →
--       inventory_classified(netvar) → 客户端 UI。
--  7. ★★ 装备槽与普通槽的四个本质差异：
--     ① 键类型：字符串槽名 vs 整数下标；
--     ② 容量：固定 4 个（EQUIPSLOTS）vs maxslots（GetMaxItemSlots）；
--     ③ 能否堆叠：equipstack=true 时整摞一起装备（equippable.lua:34）；
--     ④ 有副作用：装备会触发 onequipfn / PushEvent("equip")，
--        并可能改变容器（背包穿到 BODY 槽就成溢出容器）。
--  8. ★★ 装备槽就是「溢出容器」的来源：1369-1371 行，
--     任何带 container 组件的物品穿到 BODY 槽，都会成为 GetOverflowContainer
--     的返回值（1459 行）。⇒ **背包是一个穿在身上的物品**。
--  9. ★★ 六个 ignore* 开关是本文件最大的技术债（38-44 行注释自称 Hacky）。
--     它们都是**实例字段**而非局部变量，因此可重入但不隔离：
--     ★ 风险点在 2537-2556 行——手工置位/复位，若中途 return 会泄漏。
--     实际上 2544 行的 GiveItem 若抛错，标志会永久为 true。
-- 10. ★★ RemoveItem（1390 行）的兜底是 `return item`（1453 行）：
--     找不到也返回传入的 item（不返回 nil）。
--     ★ 这让「RemoveItem 后接 :Remove()」的链式调用成为可能
--       （1758/1765/1953 行都这么用）。
--     ⚠ 代价：调用方无法靠返回值区分「成功取出」与「本来就不在这」。
--       若需要区分，必须先自己 IsHolding。
-- 11. ★★ 合成供料的顺序由 crafting_priority_fn（1690 行）决定：
--     **小堆先吃**，同大小时按槽位序号。
--     ★ 为什么小堆优先？为了让 GetCraftingIngredient 的结果在
--       「刚好够」时尽量**用完一整摞**，减少留下的零散堆叠。
-- 12. ★★ 本文件**不做联机同步**，只做事件派发与权威计算。
--     这是 Klei 的分层：sim 层（这里）→ replica 层 → classified → UI。
--     ⇒ 推论：本文件的函数**不需要**判断 ismastersim，
--       因为它根本不会在纯客户端上被调用。
--     ★ 唯一需要判断的是 71 行的 replica.inventory.classified ~= nil。
--【⚠ 疑似缺陷清单（本文件 14 条，均只记录不修改代码）】
--  L1 ★★★ inventory.lua:1643  GetOverflowContainer 把 BODY 槽物品的
--     container 组件当作背包本体，但其 numslots 可能为 0（尚未 OnLoad）。
--     推理依据：1459 行只检查 canbeopened，不检查 slots/numslots 就绪。
--     读档过程中（OnLoad 里 301 行 GiveItem 早于 311 行 Equip）
--     若某物品带 container 但 numslots 未初始化，GetNextAvailableSlot
--     的 `for k = 1, overflow:GetNumSlots()` 会取到无效值。
--     影响：极可能是良性的（numslots 默认 0 → 循环不执行），
--     但作者在 1456-1458 行自己写了 TODO 说这块「不是最大问题但有后果」，
--     可见作者也知道这里不干净。
--  L2 ★★★ inventory.lua:1540/1673/1703/2107  四处遍历 opencontainers，
--     都写 `container_inst.components.container or
--     container_inst.components.inventory`。
--     ★ 但 2078 行（Hide）**只取** .components.container，没做 or 兜底，
--     且直接 `k.components.container.stay_open_on_hide`。
--     ⇒ 若某个 opencontainers 成员只有 inventory 组件，
--       Hide() 会崩（attempt to index nil）。
--     推理依据：1443 行的注释说明 opencontainers 里确实可能混有两种组件的实体，
--     否则那三处 or 兜底就没有必要。
--  L3 ★★  inventory.lua:1929-1965  DestroyContents 的 equipslots 循环用
--     `for _, item in pairs(self.equipslots)`，但循环体内 1953 行调
--     `self:RemoveItem(item)` → 1417 行 Unequip → **修改了被遍历的表**。
--     推理依据：Unequip 在 1240 行执行 `self.equipslots[equipslot] = nil`。
--     在 Lua 中，遍历时把当前键置 nil 是**允许**的（不会导致漏遍历），
--     所以实际不会崩——但这是脆弱写法：若将来 RemoveItem 改成
--     `table.remove` 或新增别的键，就会出现「跳过元素」的经典 bug。
--     同样的模式也出现在 1824/1860 行（DropEverything 的装备循环）。
--     ★ 正确写法是先收集到临时表再遍历。
--  L4 ★★  inventory.lua:1522  Has() 检查 activeitem 时**没有**排除
--     nocrafting 之外的特殊条件，且 1509 行明确 `local iscrafting = checkallcontainers`。
--     ★ 问题：第三参数叫 checkallcontainers（是否检查打开的容器），
--       却复用来当 iscrafting（是否排除 nocrafting）。
--     这两个语义被强行合并，导致一个诡异后果：
--     `inv:Has("rock", 1, false)` 传入的是**不算 nocrafting 的语义**，
--     而 `inv:Has("rock", 1, true)` 排除 nocrafting。
--     原注释 "this is the current assumption, so make it explicit"（1508 行）
--     正是作者在承认这是个将就的设计。
--     ⇒ 影响：若将来有第三种「Has 的用途」，这个二义性必然出问题。
--  L5 ★   inventory.lua:1380  Equip 末尾 `return true` 与函数开头的多个
--     裸 return（1273/1281）混用。1266 行的签名没有声明返回值，
--     而 2452 行的 EquipActiveItem 直接 `self:Equip(...)` 忽略返回值，
--     2486 行的 SwapEquipWithActiveItem 也是。
--     ★ 这不是缺陷，但**不一致**：有的路径 return true，有的返回 nil。
--       模组若写 `if inventory:Equip(item) then` 会在「item == olditem」
--       （1339 行条件不成立）时拿到 nil 而误判为失败。
--  L6 ★   inventory.lua:553  SelectActiveItemFromSlot 里
--     `assert(BRANCH ~= "dev")` —— 在 dev 分支下会**中断执行**。
--     同样的 assert 出现在 729/1252/2187/2200/2517/2658 行，共 6 处。
--     ★ 这意味着「锁在槽里的物品被取出」在开发版会 crash 而非优雅处理。
--     推测是原作者留的「这个分支不该走到」的标记，从未清理。
--     ⚠ 对模组作者而言：锁槽物品的任何移动都会在 dev 版炸掉。
--  L7 ★★  inventory.lua:1457  CheckMigrationPets 的递归无深度上限。
--     286 行 `CheckMigrationPets(inst, v)` 在容器套容器时递归。
--     正常存档深度有限，但**恶意/损坏的存档**或
--     mod 制造的深层容器结构可能栈溢出。
--     ★ 对比：Lua 的递归深度没有硬限制，直到爆栈。
--  L8 ★   inventory.lua:2139  PutOneOfActiveItemInSlot 调用
--     `active_item.components.stackable:Get(1)` —— 条件里已检查
--     StackSize() > 1，所以 Get(1) 安全。
--     ★ 但 2138 行先置 ignoresound=true，2140 行复位。
--       若 GiveItem 中途抛错（见 §十九 L9），ignoresound 泄漏。
--     ⇒ 与 L9 是同一类「标志泄漏」问题的不同实例。
--  L9 ★★★ inventory.lua:1344/1358/1314/1199/1201 等处大量
--     「置 silentfull/ignoresound → 操作 → 复位」的三行模式。
--     ★★ 若中间的调用**抛错**（Lua 无 try/finally），标志永不复位。
--     这是本文件最普遍的结构性隐患，共约 12 处。
--     DST 的 Lua 环境没有异常机制，所以只能靠「保证不抛错」来规避。
--     ⚠ 一旦某个 mod 的 inventoryitem:OnPickup 抛错，整个玩家的
--       silentfull 就永久为 true，此后背包满时**永远不再播提示音**。
--     ★ 这是「无异常机制语言 + 全局可变状态」的经典代价。
--  L10 ★  inventory.lua:27  onowner setter 里
--     `self.inst.replica.inventory:SetHeavyLifting(...)` 无 replica 判空。
--     对比 equippable.lua:8 的 onwalkspeedmult 有 `if replica ~= nil` 保护。
--     ★ 说明不同组件对「replica 一定存在」的假设不一致。
--     在 classified 尚未 attach 的窗口期（玩家刚生成），
--     replica.inventory 存在但 .classified 可能为 nil，
--     SetHeavyLifting 内部有判空（inventory_replica.lua:180）所以安全。
--     ⇒ 实际不崩，属防御风格不一致。
--  L11 ★★ inventory.lua:219  OnSave 的 activeitem 排除条件：
--     `not (activeitem.components.equippable and
--      self.equipslots[...equipslot] == activeitem)`。
--     ★ 含义：若 activeitem 同时穿着在装备槽上，只存装备槽那份。
--     ★★ 但这意味着**若装备槽那份存失败**，activeitem 也不存 →
--       物品彻底丢失。推理：208 行的 equip 循环有 `if v.persists` 保护，
--       而 219 行的排除条件**没有检查 persists**。
--       所以「不 persists 的装备同时是 activeitem」时，两处都不存。
--       这可能是有意的（不 persist 的东西本就不该进存档），
--       但 activeitem 那条路没有独立的 persists 兜底，属不对称。
--  L12 ★   inventory.lua:2007 GetDebugString 里 `item.prefab or "prefab"` ——
--     prefab 字段几乎总有值，这个兜底是死代码。
--     且 2012 行 string.format("...", GetWaterproofness()) 的格式串里
--     **没有 %d/%s 占位符**给 waterproofness，
--     多余的实参在 Lua 里被忽略。
--     ★⇒ 这是一个真 bug：Waterproofness 永远不会被打印。
--     推理依据：格式串只有 " waterproofness:" 一个常量段，
--             没有 %d，self:GetWaterproofness() 的值被丢弃。
--  L13 ★   inventory.lua:2544 与 2593/2644/2671  MoveItemFrom* 系列，
--     `container.ignorespoverflow ~= nil` 的判空写法：
--     ignorespoverflow 是 **boolean**（1482 行 `if self.ignorespoverflow then`），
--     初始值在 inventory 构造函数里是 **false 而非 nil**（40 行）。
--     ⇒ `~= nil` 对布尔值**永远为真**。
--     ★★ 后果：2538/2587/2638/2665 行的条件退化为
--       「只要 container 是 specialized container 就置 ignorespoverflow」，
--       ignorespoverflow=false 的普通容器也会被置 true。
--     ★ 作者本意应是「这个字段存在吗」（面向 inventory 而非 container），
--       但 inventory 和 container 是两种不同的组件，字段语义并不通用。
--     这看起来是一个真实的逻辑缺陷——但影响被 2551 行的复位掩盖了
--     （用同样的 `if container.ignorespoverflow then` 复位，恒真）。
--     ⇒ 净效果：功能上碰巧正确（置 true 再置 false），
--       但判定条件失去了原意，若中途 2544 行抛错则标志泄漏。
--  L14 ★   inventory.lua:1858-1866  DropEverythingByFilter 的装备循环
--     与 1860 行前一行（普通槽循环）之间没有空行，且两段代码
--     **完全重复**了 1801-1835 的 DropEverythingWithTag 结构。
--     ★ 这是典型的复制粘贴遗留：WithTag、ByFilter、DropEverything 三个函数
--       共享同一骨架但各写一遍。
--     ⇒ 任一处需要修复（如 L3 的遍历修改问题）都要改三处，
--       极易漏改。
--【★ 关于任务提到的「模组物品兼容性」】
--  本文件对模组的态度是「**完全开放，靠命名约定**」，无任何注册表：
--   · 自定义槽位数 → 重写 GetMaxItemSlots 或直接改 self.maxslots
--     （服务端可写，客户端在 72 行被 makereadonly 锁住）；
--   · 自定义装备槽 → 往 EQUIPSLOTS（constants.lua:652）加项，
--     equipslotutil.lua:16 会在 Initialize 时把它变成网络 ID。
--     ★ 注意 20 行的 assert(EQUIPSLOT_COUNT <= 63)：
--       因为 ID 要塞进 net byte。⇒ **模组最多只能加到 63 个装备槽**。
--     ★ 但 EQUIPSLOT_NAMES 是数组下标映射，ID 从 1 开始，
--       所以实际可用上限约 62 个。这个限制**不会**在加第 64 个槽时
--       才报错，而是在 Initialize（世界初始化）时一次性 assert。
--   · 自定义标签（stackable/equipstack/canonlygoinpocket）→
--     只需给 prefab 挂对应组件，本文件无需改动；
--   · 自定义容器 → 实现 GetOverflowContainer 或覆盖它。
--  ★ 兼容性风险点：L2 的 Hide() 崩溃、L13 的布尔判空，
--    以及 L9 的标志泄漏——这三处是模组最容易踩到的坑。
-- 【§零】模块头部。两个 require 的用途完全不同，值得分开讲：
--
-- ★ EquipSlot = require("equipslotutil") —— 装备槽的「编号 ↔ 名字」转换器。
--   为什么需要它？因为 equipslots 的键是**字符串**（EQUIPSLOTS.HANDS = "hands"），
--   而 ApplyDamage 需要**按顺序遍历所有槽**（411 行 EquipSlot.Count()）。
--   ⇒ 只有 equipslotutil 能提供「第 i 个槽的名字」。
--   ★ 关键约束在 equipslotutil.lua:16：`assert(EQUIPSLOT_COUNT <= 63)`。
--     因为槽位 ID 要用 netvar 同步（byte 上限 255 但要留余量），
--     所以**模组不能无限加装备槽**。加到 64 个会在世界初始化时炸。
--   交叉引用：equipslotutil.lua:16 InitializeSlots 的 table.reverse_inplace。
--     ★ 那次反转是为了让 ID 的顺序 = EQUIPSLOT_NAMES 的字典序，
--       保证各平台一致（注释明确说了 determinism 的动机）。
local EquipSlot = require("equipslotutil")
-- ↑ 两个 require 结束。
-- ★ SpDamageUtil = require("components/spdamageutil") —— 特殊伤害工具。
--   ★ 「特殊伤害」指火焰、寒冰、腐蚀等**元素伤害**，与普通伤害分开结算。
--   392 行用它做「装备是否提供某类特殊伤害防御」的查询，
--   456-492 行用它做特殊伤害的分摊计算。
--   ★ 为什么元素伤害要单独分摊？因为元素的减伤来源是**抗性标记**
--     （如防火帽的 fireproof tag）而非护甲值，且不同元素的
--     防御效果**不能互相叠加**——所以需要一套独立的分配算法。
local SpDamageUtil = require("components/spdamageutil")
-- ↑ SpDamageUtil 引用。

-- ↑ 空行分隔。
-- ★★ OnDeath —— 玩家死亡回调。
-- ★ 关键：`DropEverything(true)` 的 true 是 ondeath 参数。
--   ★ ondeath=true 会让 DropEverything 遵守 keepondeath 标签（1878 行）：
--     某些物品（如任务道具、韦斯的记忆）在死亡时**不掉落**。
--   ⇒ 这是「死亡掉落」与「主动丢弃」的语义分叉点。
--   交叉引用：components/health.lua 在玩家死亡时 PushEvent("death")。
local function OnDeath(inst)
-- ↑ OnDeath 函数结束（单行体）。
    if inst.components.inventory ~= nil then
-- ↑ 组件存在性检查（OnDeath 内）。
        inst.components.inventory:DropEverything(true)
-- ★★ DropEverything(true) —— true = ondeath（见 1878 行）。
    end
-- ↑ 组件检查块结束。
end
-- ↑ OnDeath 函数结束。

-- ↑ 空行分隔。
-- ★★ OnOwnerDespawned —— 玩家**消失**（非死亡）时的回调。
-- ★★ 与 OnDeath 的本质区别：不丢弃物品，只**通知每个物品**。
--   「消失」指：进传送门、坐船、被幽灵拖走、玩家离线等。
--   ⇒ 物品必须自己决定这段时间怎么处理（冻结、隐藏、跟随等）。
--   ★ 为什么只遍历这三张表？因为「玩家持有的物品」= 
--     itemslots ∪ equipslots ∪ {activeitem}。缺一不可。
--   ★★ 注意这是 pairs 遍历，无序 —— 所以事件的触发顺序不确定。
--     对于「通知型」事件这没问题（物品之间无依赖）。
--   交叉引用：playercontroller.lua 在 respawn/despawn 时派发
--     PushEvent("player_despawn")。
local function OnOwnerDespawned(inst)
-- ↑ OnOwnerDespawned 函数头。
    if inst.components.inventory ~= nil then
-- ↑ 组件存在性检查（OnOwnerDespawned 内）。
-- ★ itemslots 遍历：只发 player_despawn 事件，不做任何状态改变。
-- ★ 用 pairs 而非 1..maxslots：性能（可能有大量 nil 槽）。
        for slot, item in pairs(inst.components.inventory.itemslots) do
-- ↑ itemslots 遍历开始。
            item:PushEvent("player_despawn")
-- ★ 通知「主人消失了」，不丢弃。
        end
-- ↑ itemslots 遍历结束。
-- ★★ equipslots 遍历：同样只发事件。
-- ★★ 装备槽里的物品同样需要知道「主人消失了」——
--   例如韦斯的胡子在主人消失时应该停下跟随。
        for slot, equip in pairs(inst.components.inventory.equipslots) do
-- ↑ equipslots 遍历开始。
            equip:PushEvent("player_despawn")
-- ★ 装备槽同样通知。
        end
-- ↑ equipslots 遍历结束。
-- ★★★ activeitem 单独处理 —— 它不在前两个循环里。
-- ★ 这是三张表结构的必然要求：activeitem 是**单个引用**不是数组。
-- ⇒ 任何「遍历玩家所有物品」的逻辑都必须写三段。
--   本文件里这种三段式出现了 4 次（10 行、192 行、1849 行、1944 行）。
        if inst.components.inventory.activeitem ~= nil then
-- ↑ activeitem 处理块。
            inst.components.inventory.activeitem:PushEvent("player_despawn")
-- ★★★ 手上物品单独通知（不在前两个循环内）。
        end
-- ↑ activeitem 通知块结束。
    end
-- ↑ 组件检查块结束。
end
-- ↑ OnOwnerDespawned 函数结束。

-- ↑ 空行。
-- ★★ onheavylifting —— 「负重影响动作」的 setter。
--   这是 Class 的第三个参数（属性 setter 表）之一，见 78-81 行。
-- ★★ 机制：heavylifting 变了 → replica 那边收到 netvar 变化 →
--   inventory_replica.lua:75 _OnHeavyLiftingDirty 挂/摘**动作过滤器**：
--     PushActionFilter(HeavyLiftingActionFilter, ...) 其中过滤器只允许
--     `action.encumbered_valid == true` 的动作通过。
--   ⇒ ★ 这就是「负重过高时不能跳跃/攻击」的联机实现。
--     关键：**不是**在服务端拒绝执行，而是在客户端**过滤掉按钮**。
--     服务端仍有兜底检查（actions.lua 的 MakeRangeCheckFn 等）。
--   ★ 这解释了为什么 heavylifting 必须同步：客户端要靠它隐藏按钮。
local function onheavylifting(self, heavylifting)
-- ↑ onheavylifting 函数头。
-- ★ 直接调 replica 接口同步。inventory_replica.lua:179 SetHeavyLifting。
-- ★ 这里没有判空 replica —— 因为 Inventory 组件的存在本身就保证了
--   replica 存在（DST 的组件镜像机制：每个组件都有对应 replica）。
--   ★ 对比 equippable.lua:8 的 onwalkspeedmult 就有判空。
--     同一份代码库里两种风格并存（见 L10）。
    self.inst.replica.inventory:SetHeavyLifting(heavylifting)
-- ↑ SetHeavyLifting 调用。
end
-- ↑ SetHeavyLifting 调用结束。

-- ↑ onheavylifting 函数结束。
-- ★ onfloaterheld —— 「手持漂浮物」的 setter。
-- ★★★ floaterheld 的效果比 heavylifting 复杂得多：
--   inventory_replica.lua:92 _OnFloaterHeldDirty 做两件事：
--     ① PushActionFilter(FloaterHeldActionFilter) 过滤非 floating_valid 动作；
--     ② inst.sg:HandleEvent("sg_startfloating") —— **改状态图**！
--   ⇒ ★ 手持钓鱼竿会让角色进入「钓鱼浮标」状态，
--     由状态图接管移动逻辑。参见 stategraph 家族的 sg_startfloating 标签。
--   ★ 1374 行 `item.components.playerfloater and true` 说明：
--     只有带 playerfloater 组件的物品才能触发。
local function onfloaterheld(self, floaterheld)
-- ↑ onfloaterheld 函数头。
	self.inst.replica.inventory:SetFloaterHeld(floaterheld or false)
-- ↑ SetFloaterHeld 调用。
end
-- ↑ SetFloaterHeld 调用结束。

-- ↑ onfloaterheld 函数结束。
-- 【§零】Class 构造函数的开始。Class 是 Klei 的继承框架（class.lua）。
-- ★ 三个参数：(ctor, super_ctor, attr_init_table)。
--   76 行 nil = super_ctor（Object 无父类构造），
--   78-81 行是属性 setter 表。
local Inventory = Class(function(self, inst)
-- ↑ Class 构造开始。
    self.inst = inst
-- ★★ self.inst = inst —— Klei 组件的强制约定。

-- ↑ 空行。
-- ★★ isopen —— 物品栏是否「打开」（逻辑状态）。
-- ★★ isvisible —— 物品栏 UI 是否「可见」（表现状态）。
-- ★★ 两者不是一回事！见 §十五 的详细说明：
--   isopen 为 true 但 isvisible 为 false 的状态确实存在
--   （如 Open 后立刻 Hide、或死亡时 corpse 实体）。
--   inventory_replica.lua:4-6 就是利用这一点：
--   尸体（tag:corpse）打开后立刻 Hide，保留逻辑打开但不显示 UI。
--   ⇒ ★ 这是「逻辑与表现分离」的一个漂亮实例。
    self.isopen = false
-- ↑ isopen/isvisible 初始化。
    self.isvisible = false
-- ★ isvisible 初始化为 false（与 isopen 独立）。

-- ↑ 空行。
-- ★★ 原英文注释保留："Hacky flags for altering behaviour when
--   moving items between containers"
-- ★★ 作者自己承认这是 hack。这是本文件**最重要的技术债声明**。
-- ★ 为什么必须是 hack？因为容器之间搬运物品时，需要临时**绕过**
--   一些正常的溢出限制（比如「背包满时不能塞」在搬运语境下不成立）。
--   ★ 但这些标志是**实例字段**（不是函数局部变量），意味着：
--     ① 可以在嵌套调用中被内层代码读取（可能是想要的，可能是灾难）；
--     ② 忘记复位会**永久**影响该物品栏（见 L9）。
--   ★ 若设计得当，这些应该是参数或栈上的局部状态。
    --Hacky flags for altering behaviour when moving items between containers
-- ↑ 原英文注释保留。
-- ★ ignoreoverflow —— 忽略「溢出到背包」的行为。
--   典型用途：1150-1164 行，把物品从一个栏「挤」到另一个栏时，
--   不想让背包（overflow）抢先把物品收走。
--   ★ 复位点在 1160 附近和 2537-2556 行。
    self.ignoreoverflow = false
-- ↑ ignoreoverflow 字段。
-- ★ ignorespoverflow —— 忽略「专用容器溢出」（sp = specialized）。
--   ★ 专用容器 = 弹药袋、金币袋这类**只收特定物品**的口袋（1481 行）。
--   区别于普通 overflow（= 背包本体，1459 行）。
	self.ignorespoverflow = false
-- ↑ ignorespoverflow 字段。
-- ★ ignoreclosedspoverflow —— 忽略「专用容器必须打开才能放」的限制。
--   1488 行传入 ValidateSpecializedContainer 的第三个参数。
--   ★ 场景：把物品从**背包**拖到**未打开的弹药袋**（某些快捷操作）。
	self.ignoreclosedspoverflow = false
-- ↑ ignoreclosedspoverflow 字段。
-- ★★ ignorefull —— 「假装没满」。
--   ★★ 1171 行的作用：`if self.ignorefull then return false end` ——
--     背包满时**直接返回失败**，而不是像 1178 行那样塞进 activeitem、
--     或者 1209 行那样丢到地上。
--   ★ 这是搬运场景的正确行为：宁可失败也不要把物品丢地上。
--   ★ 使用点：337-361 ReturnActiveActionItem 里临时置 true。
    self.ignorefull = false
-- ↑ ignorefull 字段。
-- ★ silentfull —— 静默的「满」。
--   ★ 1213 行：`if shouldwisecrack and not (isloading or silentfull) ...`
--     抑制「inventoryfull」事件（玩家看到的「背包已满」提示）。
--   ★ 与 ignorefull 的区别：ignorefull **改变行为**（直接失败），
--     silentfull **只抑制提示**（行为照常）。
--   ★ 使用场景：装备替换时旧物品自动回背包（1344 行），
--     这时不该弹「背包已满」因为那只是内部重排。
    self.silentfull = false
-- ↑ silentfull 字段。
-- ★ ignoresound —— 忽略「获得物品的声音/特效」。
--   ★ 1099 行：`if new_item and not self.ignoresound then PushEvent("gotnewitem")`。
--   ★ 用于「物品实际没进背包、只是路过」的场合（如 2544-2547 行：
--     往容器塞失败又塞回来，不该播两次音）。
    self.ignoresound = false
-- ↑ ignoresound 字段。

-- ↑ 空行。
-- ★★ itemslots —— 普通背包格。**数组**，键为 1..maxslots。
-- ★★ 它是稀疏的：中间的槽可以为空（nil）。
--   ★ 为什么不用紧凑数组？因为增删频繁，稀疏数组的增删是 O(1)，
--     而 table.insert/table.remove 会移动所有元素（O(n)）并打乱顺序。
--     ★ 玩家体验：拾取的物品总是进**第一个空格**，不重排。
--   ★★ 代价：遍历必须小心 nil（见 1405 行的 pairs 用法）。
--   ★★ 稀疏性导致 GetItemInSlot 与 GetNextAvailableSlot 的语义不同：
--     前者是 O(1) 直接索引，后者要 O(maxslots) 扫描找空位。
    self.itemslots = {}
-- ↑ itemslots 初始化。
-- ★★ maxslots —— 背包格子数。由 GetMaxItemSlots 决定（游戏模式相关）。
-- ★ 常量定义在 constants.lua 的 MAXITEMSLOTS = 15（4 人份）/ 20 等。
-- ★★ 注意：这里是 `TheNet:GetServerGameMode()` —— **服务端模式**。
--   客户端走 197 行的 replica 版本。
-- ★★ 72 行 makereadonly(self, "maxslots") 把这个字段在**客户端**设为只读，
--   防止客户端自己改背包大小（反作弊 + 防止 UI 与服务端不一致）。
--   ⇒ ★ 这揭示了 DST 的一个通用模式：
--     **服务端算好一切，客户端只读**。所有需要同步的字段都在
--     71-75 行被 makereadonly 保护（maxslots/acceptsstacks/ignorescangoincontainer）。
--   交叉引用：class.lua 的 makereadonly。
    self.maxslots = GetMaxItemSlots(TheNet:GetServerGameMode())
-- ↑ maxslots 初始化。

-- ↑ 空行。
-- ★★ equipslots —— 装备槽。**哈希表**，键是字符串槽位名。
-- ★★ 与 itemslots 的四个根本差异：
--   ① 键类型：整数下标 vs 字符串槽名（EQUIPSLOTS.HANDS = "hands"）
--   ② 数量：固定 4 个 vs maxslots
--   ③ 可堆叠：equipstack 时可多堆 vs 普通槽只放一个实体
--   ④ 有副作用：装备会触发属性/事件（onunequipfn、setoverflow 等）
-- ★★ 因为是字符串键，遍历顺序不确定 —— 所以 411 行用
--   EquipSlot.Count() 做**有序**遍历（419 行的 resistance 检查依赖顺序）。
--   ★ 这就是文件头 require EquipSlot 的根本原因。
    self.equipslots = {}
-- ↑ equipslots 初始化。
-- ★ heavylifting —— 「正在负重」标志（身上 BODY 槽有 heavy 标签物品）。
-- ★ 1372 行装备时 set，1234 行卸下时清。
-- ★ 24 行的 setter 把它同步到客户端 → 客户端据此过滤动作。
-- ★★ 注意 heavylifting **只由 BODY 槽决定**（1372 行在 eslot==BODY 分支内），
--   不是所有 heavy 物品。这与 1305-1310 行的「手持 heavy 会挤掉身上 heavy」
--   逻辑配套。
    self.heavylifting = false
-- ↑ heavylifting 初始化。
	--self.floaterheld = nil
-- ★ floaterheld 字段被注释掉（未初始化，靠 1236/1374 赋值）。

-- ↑ 空行。
-- ★★ activeitem —— 「当前拿在手上的物品」。**最多一个**。
-- ★★ 它是一个**特殊槽位**：
--   · 不占用 itemslots 的任何一格（1178 行证明：背包满了也能塞手上）；
--   · 但如果这件物品同时是 equippable，它也可能出现在 equipslots 里；
--   · OnSave 219 行专门处理了「同一实体在两个槽」的重复保存问题。
-- ★★ 语义：这是 UI 的「操作对象」。绝大多数动作（吃、装备、使用）
--   都以 activeitem 为参数。
-- ★ 它是**唯一**能被 SetActiveItem 设为 nil 而不影响背包内容的地方，
--   所以它是「取出到手上」这个操作的目的地。
    self.activeitem = nil
-- ↑ activeitem 初始化。
-- ★ acceptsstacks —— 是否接受「整摞」物品。
-- ★ 某些容器（如特定 mod 容器）设为 false，则只能进单件。
-- ★ 与 equipstack（equippable.lua:34）不同：
--   acceptsstacks 是**接收方**的限制，equipstack 是**物品方**的限制。
-- ★ 两者都影响 936/959 行的判断：`if self.acceptsstacks or stacksize <= 1`。
    self.acceptsstacks = true
-- ↑ acceptsstacks 初始化。
-- ★ ignorescangoincontainer —— 「忽略 can_goin_container 检查」。
--   232 行：`if not (item and item.components.inventoryitem and
--   (cangoincontainer or self.ignorescangoincontainer))`
--   ★ 即：本栏宣称「我什么都收」，无视物品的 cangoincontainer 标记。
--   用途：某些特殊容器（如展示柜）不遵守常规限制。
    self.ignorescangoincontainer = false
-- ↑ ignorescangoincontainer 初始化。
-- ★★ opencontainers —— 当前打开的**外部容器**列表。
-- ★★★ 这是合成系统能「从旁边的箱子里取材料」的机制基础。
--   关键：Has/RemoveItem/GetCraftingIngredient 都有 checkallcontainers 参数，
--   为 true 时会遍历这个列表去打开的容器里找物品（1536-1546 等）。
-- ★★★ ★★ 因此「站在箱子前合成」能成功，纯粹靠这个列表。
--   而「不打开箱子」则合成失败 —— 因为容器不在列表里。
-- ★ 列表的 key 是**实体**（不是组件），所以 1443 行需要
--   `container_inst.components.container or ...inventory` 来取组件。
-- ★★ 这也是 L2 的根源：不同位置的解包写法不一致。
    self.opencontainers = {}
-- ↑ opencontainers 初始化。
-- ★ opencontainerproxies —— 「容器代理」列表。
-- ★ 用于 2747 行 GetOpenContainerProxyFor(master)：
--   按 master 反查 proxy。这是给「一个容器对应多个 UI 代理」的场景。
--   典型用途：韦斯的「钟表追踪箱子」需要独立 UI 代理。
-- ★ 与 opencontainers 的区别：proxies 是**客户端 UI 侧的影子**，
--   master 是真实容器。所以是「多对一」的映射。
	self.opencontainerproxies = {}
-- ↑ opencontainerproxies 初始化。

-- ↑ 空行。
-- ★ dropondeath —— 死亡时是否掉落全部物品。默认 true。
-- ★ 59-60 行注册 OnDeath；83-95 行的 Enable/Disable 可以在运行时切换。
--   ★ 切换场景：某些形态（如「幽灵状态」）下物品不掉落。
-- ★★ 97 行：组件被移除时**自动禁用**（等价于解绑事件）。
--   ⇒ 这是防止「实体已销毁但回调还在」的常见模式。
    self.dropondeath = true
-- ↑ dropondeath 初始化。
-- ★ ListenForEvent("death") —— 监听死亡事件。
-- ★ 只在服务端有效（本文件不判 ismastersim，因为组件本身只在服务端跑）。
    inst:ListenForEvent("death", OnDeath)
-- ↑ death 事件注册。

-- ↑ 空行。
-- ★★ isexternallyinsulated = SourceModifierList(inst, false, boolean)
-- ★★★ 这是本文件唯一用到 SourceModifierList 的地方，语义值得展开：
--   SourceModifierList 是一个「**带来源的布尔聚合器**」。
--   与普通 boolean 的区别：普通 boolean 是**最后写入者赢**，
--   而 SourceModifierList 是「**所有来源 AND 起来**」或按类型 OR 起来，
--   任何一个来源撤销自己时，该来源的贡献消失，不会误伤别人的设置。
-- ★ 参数：(inst, 默认值false, 类型=boolean)。
-- ★★ 用途：770 行 IsInsulated 读它。
--   ⇒ 效果：多个系统（装备、防寒道具、buff）都能独立设置绝缘，
--     只有全部撤销才变成 false。避免了「A 关闭把 B 的开也关了」的问题。
-- ★★ 交叉引用：components/playercontroller.lua、components/buffs 等也用
--   SourceModifierList 来管理 buff 效果的所有权。
--   这是 DST 处理「多方影响同一布尔属性」的标准方案。
    self.isexternallyinsulated = SourceModifierList(inst, false, SourceModifierList.boolean)
-- ↑ isexternallyinsulated 初始化。

-- ↑ 空行。
	-- self.noheavylifting = false
-- ★ noheavylifting 被注释掉（Equip:1271 会读它，默认为 nil）。
	--self.ignorecombat = false
-- ★ ignorecombat 被注释掉（未使用的历史字段）。
    --self.force_no_insulation = nil
-- ★ force_no_insulation 被注释掉（755 行会写它）。
    --self.thiefproof = nil
-- ★ thiefproof 被注释掉（★ 262 行读它 ⇒ 返回 nil —— 见 L10b）。

-- ↑ 空行。
-- ★ ListenForEvent("player_despawn") —— 监听玩家消失。
-- ★★ 与 death 的区别：player_despawn **不丢弃物品**，只通知。
--   「消失」= 传送、离线、进洞穴等。这是 OnOwnerDespawned 的触发点。
    inst:ListenForEvent("player_despawn", OnOwnerDespawned)
-- ↑ player_despawn 事件注册。

-- ↑ 空行。
-- ★★★ makereadonly 三连 —— 本文件**最重要的反作弊/防不一致机制**。
-- ★★★ 判据 `inst.replica.inventory.classified ~= nil` 极其精确：
--   replica.inventory 存在（任何客户端都存在这个 replica 组件），
--   但 classified 是**服务端为该客户端专门创建的**（inventory_replica.lua:16
--   SpawnPrefab("inventory_classified")）。
--   ★★ 含义：**只有服务端授权的客户端**才能读到这个 classified，
--     于是只有这些客户端上的 maxslots/acceptsstacks/ignorescangoincontainer
--     才是**服务端认可的只读值**。
--   ⇒ 未被授权的客户端（偷窥者、非该玩家客户端）上这些字段仍可写，
--     但它们**看不到**这个玩家的物品栏 UI，无从作弊。
-- ★ 这解释了 inventory_replica.lua 的整个架构：
--   数据访问权限 = Network:SetClassifiedTarget（147/158 行）。
-- ★ 三个字段的选择逻辑：
--   · maxslots —— 影响 UI 格子数，必须与服务端一致；
--   · acceptsstacks —— 影响拖拽行为；
--   · ignorescangoincontainer —— 影响能否放入某物品。
-- ★★ 为什么客户端需要这些值？纯 UI：客户端要画格子、要判断
--   拖拽是否合法。客户端**不做权威判定**（那是 205/230 行的 CanTakeItemInSlot
--   在服务端执行）。
-- ★★ 对比：receive side 的 GetNumSlots（197 行）直接转发给服务端组件。
--   两个层次职责分明：客户端算 UI，服务端算规则。
    if inst.replica.inventory.classified ~= nil then
-- ↑ makereadonly 三连（仅客户端）。
        makereadonly(self, "maxslots")
-- ★★ makereadonly(self, "maxslots") —— 仅客户端生效（见 71 行判据）。
        makereadonly(self, "acceptsstacks")
-- ★ makereadonly(acceptsstacks) —— 防止客户端自行改规则。
        makereadonly(self, "ignorescangoincontainer")
-- ★ makereadonly(ignorescangoincontainer) —— 同上。
    end
-- ↑ makereadonly 块结束。
end,
-- ↑ Class 构造的 super_ctor 参数（nil）。
nil,
-- ↑ attr_init 表开始。
{
-- ↑ attr_init 表（setter 绑定）开始。
    heavylifting = onheavylifting,
-- ★ heavylifting 绑定 onheavylifting。
	floaterheld = onfloaterheld,
-- ★ floaterheld 绑定 onfloaterheld。
})
-- ↑ attr_init 表结束 / Class 调用结束。

-- ↑ 空行。
-- ★ EnableDropOnDeath —— 幂等地开启死亡掉落。
-- ★ 84 行的守卫 `if not self.dropondeath` 保证不会重复注册事件监听。
-- ★ 这类「幂等 setter」在 Klei 代码里很常见，值得学习。
function Inventory:EnableDropOnDeath()
-- ↑ EnableDropOnDeath 结束。
    if not self.dropondeath then
-- ★ 幂等守卫（只在他处已关闭时才开启）。
        self.dropondeath = true
-- ★ 置位。
        self.inst:ListenForEvent("death", OnDeath)
-- ★ 注册 death 监听（与 60 行同款）。
    end
-- ↑ 守卫块结束。
end
-- ↑ EnableDropOnDeath 结束。

-- ★ DisableDropOnDeath —— 幂等地关闭。93 行对称地移除监听。
-- ★★ 97 行把这个函数直接赋给 OnRemoveFromEntity，
--   意味着「组件被移除时自动解绑 death 事件」。
--   ★ 这是防止内存泄漏/悬挂回调的重要模式。
function Inventory:DisableDropOnDeath()
-- ↑ DisableDropOnDeath 结束。
    if self.dropondeath then
-- ★ 幂等守卫。
        self.dropondeath = false
-- ★ 复位。
        self.inst:RemoveEventCallback("death", OnDeath)
-- ★ 解绑 death 监听（与 86 行对称）。
    end
-- ↑ 守卫块结束。
end
-- ↑ DisableDropOnDeath 结束。

-- ★★ `Inventory.OnRemoveFromEntity = Inventory.DisableDropOnDeath`
-- ★★ 函数别名赋值，零成本地把「禁用掉落」复用为「清理钩子」。
-- ★ 妙处：DisableDropOnDeath 的语义（移除 death 监听）与清理需求完全一致。
-- ★★ 这种「正交职责的函数复用」是 Lua 缺少多态时的常见技巧。
Inventory.OnRemoveFromEntity = Inventory.DisableDropOnDeath
-- ↑ 函数别名赋值（清理钩子）。

-- ↑ 空行。
-- 【§一】NumItems —— 「占了几个格子」。
-- ★★ 与 NumStackedItems（108 行）对比：
--   · NumItems()      —— 数**格子数**（一个 stack 占 1 格）；
--   · NumStackedItems() —— 数**物品个数**（一个 stack 占 N 格）。
-- ★★ ★ 这是本文件最常见的误用点：UI 显示「8/20」用 NumItems，
--   而「我有多少个草」用 NumStackedItems。
-- ★ O(n) 遍历（pairs 整个表）。maxslots 很小（≤20），可接受。
function Inventory:NumItems()
-- ↑ NumItems 函数头。
    local num = 0
-- ★ 计数器初始化。
    for _ in pairs(self.itemslots) do
-- ★★ 只取键（`_`）—— 不关心键值，只要计数。
        num = num + 1
-- ★ 自增。
    end
-- ↑ 遍历结束。

    return num
-- ↑ return num（格子数）。
end
-- ↑ NumItems 结束。

-- ★★ NumStackedItems —— 「一共有多少个物品（展开堆叠）」。
-- ★★ 111 行的三元表达式是 Lua 惯用法：
--   `(cond and A) or B` —— 若 A 为真/非 nil 取 A，否则取 B。
--   ★★★ ★ 但这里有**陷阱**：若 A 为 nil 或 false，整个表达式退化为 B。
--     本例中 A 是 StackSize()（返回数字，恒为真值，除非为 0）。
--     ★ 若 stacksize 为 0（空堆），`and 0 or 1` 会得到 **1**（因为 0 在 Lua
--     里是真值！所以实际上 stacksize=0 时得到 0，是正确的）。
--     ★ 真正的陷阱是：若 stacksize 为 0，`0` 是真值 → 取 0。正确。
--     ⇒ 这行虽然绕但正确。注释里提一下是因为可读性差。
function Inventory:NumStackedItems()
-- ↑ NumStackedItems 函数头。
    local num = 0
-- ★ 计数器初始化。
    for _, item in pairs(self.itemslots) do
-- ★ 这次要 item 值（为了读 stackable）。
        num = num + ((item.components.stackable == nil and 1)
-- ★★ 三元表达式：无 stackable 记 1，否则记 StackSize()。
            or item.components.stackable:StackSize())
-- ★★ 续行（or 后半段）。
    end
-- ★ 累加。
    return num
-- ↑ return num（个数，≠ 格子数）。
end
-- ↑ NumStackedItems 结束。

-- ★★ 原英文注释保留："GuaranteeItems deprecated.
--   Rethink logic for multiplayer if you want to resurrect it."
-- ★★★ 这是一个**已废弃 API 的墓碑**。GuaranteeItems 曾用于
--   「把物品从 A 转到 B 并保证成功」，但联机下有问题：
--   两个玩家的操作存在竞态。Klei 直接删了。
-- ★★ 对读者的价值：它标记了一个「看起来该有但被刻意放弃」的能力。
--   移植/重构时若想「补上」这个功能，先读这条注释。
--GuaranteeItems deprecated.
-- ↑ 已废弃 API 的墓碑注释。
--Rethink logic for multiplayer if you want to resurrect it.
-- ↑ 原英文注释第二行保留。

-- ↑ 空行。
-- 【§一】TransferInventory —— 「把整个背包（含装备与手上）转给另一个实体」。
-- ★★★ 核心用途：**变形换装**（韦斯的胡子/假人变角色）与
--   麦克斯韦的「灵魂转移」、沃尔的「借壳」等。
-- ★★★ 它是本文件里最复杂的「整体搬运」函数，遍历三张表：
--   ① itemslots（128 行）
--   ② equipslots（135 行）—— 注意要区分「受限制装备」与「普通装备」
--   ③ activeitem（150 行）
-- ★★ 为什么装备要区分？因为**某些装备只允许特定角色穿**
--   （restrictedtag，equippable.lua:147）。给错角色时必须走 GiveItem
--   而不是 Equip，否则会破坏 restricted 约束。
function Inventory:TransferInventory(receiver)
-- ↑ TransferInventory 函数头。
    if not receiver.components.inventory then return end
-- ★★ 接收方必须有 inventory 组件，否则裸 return（无返回值）。

-- ↑ 早退。
    local inv = receiver.components.inventory
-- ★ 取接收方的 inventory 组件（局部别名，简化后续书写）。

-- ↑ 空行。
-- ★★★ 原英文注释保留（JBK 署名）：解释 TransferInventory 的过滤规则。
--   "Weapons that are given to specific entities to use have the
--    \"nosteal\" tag but also do not persist."
--   "The tag can not be used because of Wanda watches for this
--    TransferInventory function to work."
-- ★★★ 这段注释解释了一个**很微妙的 bug 修复**：
--   · 某些专属武器（如查尔斯的小熊）带 nosteal 标签（不可被偷走）；
--   · 它们也不 persist（不存档，临时发放）；
--   · 一开始作者想用 nosteal 标签来过滤（130 行 `if item.persists`），
--   · 但 Wanda 需要通过 TransferInventory 来「借出」物品（1351 行），
--     如果过滤 nosteal 会破坏 Wanda 的玩法。
--   ⇒ 最终用 `persists` 作为过滤条件：会存档的才转移。
-- ★★ 「nosteal 标签不能用 + persists 可以用」的推理链，
--   是理解 TransferInventory 语义的**必要背景**。
    -- NOTES(JBK): Weapons that are given to specific entities to use have the "nosteal" tag but also do not persist.
-- ↑ 原英文注释保留（JBK）。
    --             The tag can not be used because of Wanda watches for this TransferInventory function to work.
-- ↑ 原英文注释第三行保留（nosteal 标签不能用的原因）。
    --             The restriction that specific entities that have these unique weapons must also make them not persist.
-- ↑ 原英文注释第四行保留（约束：专属武器必须不 persist）。
-- ★★ 遍历 itemslots 并逐个 RemoveItemBySlot + GiveItem。
-- ★★ 注意 129 行的 RemoveItemBySlot 会**修改 self.itemslots**（1407 行置 nil），
--   而我们正在 pairs 遍历它 —— 这是允许的（Lua 允许删除当前键），
--   但**不能新增键**。这里只删不加，安全。
-- ★★ 130 行的 `if item and item.persists` —— 两个过滤条件：
--   · item 非 nil（RemoveItemBySlot 可能返回 nil）；
--   · item.persists —— 决定是否转移。
-- ★★★ 若 item 存在但不 persists，**物品就被丢弃了**（既不在旧背包，
--   也不在新的）。这是有意的（见 125 行注释：专属武器本就是临时的）。
    for k in pairs(self.itemslots) do
-- ↑ itemslots 搬运循环开始。
        local item = self:RemoveItemBySlot(k)
-- ★★★ 按槽号取出（会修改被遍历的表，见 HEADER_EXTRA 说明）。
        if item and item.persists then
-- ★★ 双重过滤：取出成功 + 会存档。
            inv:GiveItem(item)
-- ★ 交给接收方。
        end
-- ↑ 过滤块结束。
    end
-- ↑ itemslots 搬运循环结束。

-- ★★ 遍历 equipslots：先 Unequip 再决定给新主人 Equip 还是 GiveItem。
-- ★★ 139 行的判断：`equip.components.equippable and IsRestricted(receiver)`
--   ★ 若新主人不能穿（受限装备），就丢进背包而不是硬塞。
-- ★★ 138 行的 `if inv.equipslots ~= nil` ——
--   ★★ 防御性检查：接收方的 inventory 组件**可能没有 equipslots**
--     （某些非玩家实体只有简化 inventory）。121 行只检查了
--     `receiver.components.inventory` 是否存在，没检查其结构。
--     ⇒ 这里补上了缺失的结构检查。
--   ★ 这是「防御性编程」的典型：上层检查太宽松，下层补一刀。
    for k in pairs(self.equipslots) do
-- ↑ equipslots 搬运循环开始。
        local equip = self:Unequip(k)
-- ★★ Unequip 取下装备（★ 不传 force ⇒ 锁住的不会被取下）。
        if equip and equip.persists then
-- ★ 取出成功且会存档才转移。
            if inv.equipslots ~= nil then
-- ★★ 接收方有装备槽才能穿。
                if equip.components.equippable and equip.components.equippable:IsRestricted(receiver) then
-- ★★★ 受限装备判定（★ 与 TransferInventory 的不同策略）。
                    inv:GiveItem(equip)
-- ★ 受限 → 只能放背包。
                else
-- ↑ else 分支。
                    inv:Equip(equip)
-- ★ 不受限 → 直接穿给对方。
                end
-- ↑ 受限判定的 if/else 结束。
            else
-- ↑ else 分支。
                inv:GiveItem(equip)
-- ★ 对方没有装备槽 → 放背包。
            end
-- ↑ 结构分支结束。
        end
-- ↑ persists 过滤块结束。
    end
-- ↑ equipslots 搬运循环结束。

    local activeitem = self:GetActiveItem()
-- ★★ 取手上的物品。
    if activeitem and activeitem.persists then
-- ★ 同样有 persists 过滤。
        receiver.components.inventory:GiveActiveItem(activeitem)
-- ★★ GiveActiveItem（★ 不是 GiveItem —— 手上的状态也要转移）。
    end
-- ↑ 过滤块结束。
end
-- ↑ TransferInventory 结束（三段全走完）。

-- 【§一】SwapEquipment —— 「两个实体的装备互换」。
-- ★★ 与 TransferInventory 的区别：
--   · TransferInventory 是「A 全部给 B」（单向）；
--   · SwapEquipment 是「A 的装备 ↔ B 的装备」（双向对换）。
-- ★★ 用途：变形换角色时，装备要跟着「穿在身上的身体」走，
--   但物品归玩家所有 —— 所以是 swap。
-- ★★ 关键：遍历 EQUIPSLOTS **所有**槽位（166 行），
--   对每个槽做「两边都卸下 → 交叉装备」。
-- ★ 这保证了「A 的帽子 ↔ B 的帽子」的对称交换。
function Inventory:SwapEquipment(other, equipslot_to_swap, force)
-- ↑ SwapEquipment 函数头。
    if other == nil then
-- ★★ other 为 nil（无效目标）→ 返回 false（★ 返回布尔非 nil）。
        return false
-- ↑ 早退。
    end
-- ↑ 空行。

    local other_inventory = other.components.inventory
-- ★ 取对方的 inventory 组件。
    if other_inventory == nil or other_inventory.equipslots == nil then
-- ★★ 必须同时有 inventory 且有 equipslots（比 121 行更严）。
        return false
-- ★ 早退。
    end
-- ↑ 结构守卫结束。

-- ↑ 空行。
-- ★★ `for _, equipslot in pairs(EQUIPSLOTS)` —— 遍历全局装备槽常量表。
-- ★★ 注意用的是 pairs(EQUIPSLOTS) 而非 1..EquipSlot.Count()：
--   EQUIPSLOTS 是 constants.lua:652 的哈希表 {HANDS,HEAD,BODY,BEARD}。
--   ★ pairs 顺序不确定，但因为每个槽独立处理，顺序不影响结果。
-- ★★ equipslot_to_swap 参数（第三参数）支持只换**指定槽**。
--   nil = 全部换。这是「换头不换手」这类细粒度操作的实现。
    for _, equipslot in pairs(EQUIPSLOTS) do
-- ↑ 装备槽遍历开始。
        if equipslot_to_swap == nil or equipslot_to_swap == equipslot then
-- ★★ equipslot_to_swap 为 nil → 全槽交换；否则只换那一槽。
-- ★★ `self:Unequip(equipslot, nil, force)` —— 第三个参数 force=true。
-- ★★ force=true 的语义（1224 行）：**忽略 preventunequipping**。
-- ★ 为什么强制？因为「防止卸下」的装备（如被施了「粘住」debuff 的装备）
--   在 swap 场景下必须能移动，否则换装功能会卡死。
-- ★★ 安全隐患：force 会**破坏** equippable 的 preventunequipping 状态。
--   1227 行 `Unequip` 调用后，equippable.isequipped 会被置 false，
--   但 preventunequipping 标志仍为 true。等物品被重新装备时，
--   它依然是「粘住」状态。这是**符合预期**的（debuff 应该持续）。
            local my_equipitem = self:Unequip(equipslot, nil, force)
-- ↑ Unequip(force=true) 开始。
            local ot_equipitem = other_inventory:Unequip(equipslot, nil, force)
-- ★★ 对方也卸下（★ 传 force，可突破防卸锁）。

-- ↑ 空行。
            if my_equipitem ~= nil then
-- ★★ 我的装备要交给对方了。
                if my_equipitem.components.equippable and not my_equipitem.components.equippable:IsRestricted(other) then
-- ★★★ 对方能穿吗？（双重保护：组件存在 + 非受限）。
                    other_inventory:Equip(my_equipitem)
-- ★ 能穿 → 穿到对方身上。
                else
-- ↑ else 分支。
                    other_inventory:GiveItem(my_equipitem)
-- ★ 不能穿 → 丢进对方背包。
                end
-- ↑ 判定块结束。
            end
-- ↑ 我的装备处理结束。

            if ot_equipitem ~= nil then
-- ★★ 对方的装备换给我（★ 与 171-177 完全对称）。
                if ot_equipitem.components.equippable and not ot_equipitem.components.equippable:IsRestricted(self.inst) then
-- ★ 我能穿吗？
                    self:Equip(ot_equipitem)
-- ★ 能穿 → 穿到我身上。
                else
-- ↑ else 分支。
                    self:GiveItem(ot_equipitem)
-- ★ 不能穿 → 丢进我背包。
                end
-- ↑ 判定块结束。
            end
-- ↑ 对方装备处理结束。
        end
-- ↑ if equipslot_to_swap 块结束。
    end
-- ↑ EQUIPSLOTS 遍历结束。

    return true
-- ★★ 全部处理完 → 返回 true。
end
-- ↑ SwapEquipment 结束。

-- 【§三】OnSave —— 序列化整个背包。
-- ★★ 存档结构：{ items = { [槽号] = 记录 }, equip = { [槽名] = 记录 } }
-- ★★★ 三个关键设计：
--   ① items/equip 分开存 —— 因为读回时走不同的路径（GiveItem vs Equip）；
--   ② **records 共享**：body/hat/head 三个字段指向**同一个 record 对象**
--      （199 行 `data.items[k], refs = v:GetSaveRecord()` 只调一次），
--      靠 SpawnSaveRecord 的引用机制在读档时还原为同一实体；
--   ③ references 数组处理**跨存档引用**（某些实体引用其他实体）。
-- ★★ 「三个槽共享一个 record」是最巧妙的部分：
--   它让「帽子同时是身上/头上/帽子栏物品」这个**事实**被正确表达。
-- ★★★ 与 219 行的 activeitem 排除逻辑配合：
--   若某物品既是装备又在手上，只存一次（存装备那份）。
function Inventory:OnSave()
-- ↑ OnSave 函数头。
    local data = {items= {}, equip = {}}
-- ★★ 存档结构：items（按槽号）与 equip（按槽名）分开。

-- ↑ 空行。
-- ★★ references —— 跨实体引用列表。
-- ★ GetSaveRecord 的第二个返回值就是「本实体引用了哪些其他实体」。
-- ★ 这些引用必须在存档里保持 ID 稳定，否则读档后引用会指向别的实体。
-- ★★ 为什么需要 references？因为某些物品内部持有对**其他 prefab**
--   的引用（如「背包里的容器指向它的 owner」），存读时必须能重建。
-- ★ 累加到总的 references 里返回 → 由上层（entitysave2）统一处理。
    local references = {}
-- ↑ references 初始化。
    local refs = {}
-- ★ refs —— 循环内的临时引用表（★ 每轮被覆写）。
-- ★ 遍历 itemslots 时**跳过不 persist 的物品**（198 行 `if v.persists`）。
-- ★★ 与 130 行的 TransferInventory 一致：**不 persist 就不存**。
--   语义：临时发放的物品（专属武器、特效道具）不写存档。
    for k,v in pairs(self.itemslots) do
-- ↑ itemslots 序列化循环。
        if v.persists then
-- ★★★ 只存会存档的物品。
-- ★★ `data.items[k], refs = v:GetSaveRecord()` —— 双重赋值。
-- ★★ 这行同时做了两件事：
--   ① `data.items[k] = ...` 把记录写进 items 表；
--   ② `refs = ...` 捕获引用列表（Lua 多返回值赋值）。
-- ★★ ★ 注意 refs 是**局部变量**，每次循环被覆盖 —— 所以 201 行
--   必须在同一轮迭代内累加（这正是 201-204 行做的事）。
--   如果 refs 提到循环外累加，就会**丢失**前面几轮的数据。
-- ★ 这是「循环内多返回值」的标准处理模式。
            data.items[k], refs = v:GetSaveRecord()
-- ↑ GetSaveRecord 多返回值赋值。
            if refs then
-- ★ 本轮 prefab 返回了引用列表？
                for k,v in pairs(refs) do
-- ★ 遍历引用列表（★ 复用了外层的 k,v 变量）。
                    table.insert(references, v)
-- ★ 累加进总引用表。
                end
-- ↑ 引用遍历结束。
            end
-- ↑ if refs 块结束。
        end
-- ↑ persists 块结束。
    end
-- ↑ itemslots 序列化循环结束。

-- ★ equipslots 存档：逻辑与 itemslots 完全对称。
-- ★★ 但键是**槽位名字符串**（数据.k，211 行 `data.equip[k]`），
--   与 itemslots 的整数键不同。读档时 311 行 `self:Equip(item)`
--   **不传槽位**，让 Equip 从 item 的 equippable.equipslot 自行决定。
--   ⇒ ★ 存档里的槽名其实只用于「校验/顺序」，不用于决定装备位置。
    for k,v in pairs(self.equipslots) do
-- ↑ equipslots 序列化循环。
        if v.persists then
-- ★ 装备槽同样只存会存档的。
            data.equip[k], refs = v:GetSaveRecord()
-- ★★ 键是槽位名（data.equip[k]）。
            if refs then
-- ★ 同样有引用列表处理。
                for k,v in pairs(refs) do
-- ★ 遍历引用。
                    table.insert(references, v)
-- ★ 累加。
                end
-- ↑ 引用遍历结束。
            end
-- ↑ if refs 块结束。
        end
-- ↑ persists 块结束。
    end
-- ↑ equipslots 序列化循环结束。

-- ★★★ activeitem 的存档条件 —— 这行有**四个**与/或条件，逐个拆解：
--   ① self.activeitem 存在；
--   ② self.activeitem.persists（要存档）；
--   ③ **不是**「已经穿在装备槽上的同一实体」：
--      `not (activeitem.components.equippable and
--       self.equipslots[activeitem.components.equippable.equipslot]
--        == activeitem)`
-- ★★★ ★★ ③ 的含义：若这件物品**同时**是 activeitem 且穿着在装备槽上，
--   它已经被 208 行的 equipslots 循环存过了 → 不要重复存。
--   ★ 这是「同一个实体在两个槽里只存一次」的去重。
-- ★★ ⚠ 隐患（见 L11）：③ **不检查 persist**。若装备槽那份因为
--   不 persist 被 209 行跳过，而 activeitem 这份又被 ③ 排除，
--   ⇒ 物品**彻底丢失**。
--   这在实践中要求：任何能同时进 activeitem 和 equipslots 的物品，
--   其 persists 状态必须自洽（要么都存要么都不存）。
    if self.activeitem and self.activeitem.persists and not (self.activeitem.components.equippable and self.equipslots[self.activeitem.components.equippable.equipslot] == self.activeitem) then
-- ↑ activeitem 存档条件（四重判断）。
        data.activeitem, refs = self.activeitem:GetSaveRecord()
-- ★★ 手上物品存档（★ 条件复杂，见 219 行详解）。
        if refs then
-- ★ 引用列表处理。
            for k,v in pairs(refs) do
-- ★ 遍历引用。
                table.insert(references, v)
-- ★ 累加。
            end
-- ↑ 引用遍历结束。
        end
-- ↑ if refs 块结束。
    end
-- ↑ activeitem 存档块结束。

    return data, references
-- ★★★ 返回 (data, references) —— 两个返回值。
end
-- ↑ OnSave 结束。

-- 【§三】CanTakeItemInSlot —— 「能否把 item 放进指定槽」。
-- ★★★ 本文件被调用最多的函数之一，是所有物品移动的**前置闸门**。
-- ★★ 四层校验（231-250 行）：
--   ① item 有 inventoryitem 组件 且 (cangoincontainer 或忽略检查)；
--   ② 游戏模式属性 non_item_equips 时，带 equippable 的不能进普通栏；
--   ③ 槽号在 [1, maxslots] 范围内；
--   ④ 目标槽若有物品，检查它是否 lockedinslot。
-- ★★ ★ ★★ 关键设计：`slot` 参数**可以为 nil**！
--   nil 时**跳过 ③④**，只检查 ①②。
--   ⇒ 这是「只问物品类型是否合适，不问具体槽位」的轻量查询。
--   ★ 为什么允许 nil？因为 CanAcceptCount（912 行）循环里就是
--   用 `self:CanTakeItemInSlot(item, k)` 传具体槽的；
--   而其他外部代码（如 UI 拖拽预检）可能只想问「这东西能放进来吗」。
function Inventory:CanTakeItemInSlot(item, slot)
-- ↑ CanTakeItemInSlot 函数头（四层校验）。
-- ★★ 第一层校验：`if not (item and item.components.inventoryitem and
--   (cangoincontainer or ignorescangoincontainer))`
-- ★★★ 这是「反向判断」写法：条件不满足就 return false。
--   展开为正向：**必须同时满足**：
--     · item 非 nil；
--     · item 有 inventoryitem 组件（否则它不是物品，是个实体）；
--     · item.cangoincontainer 为真 **或** 本栏 ignorescangoincontainer。
-- ★★ cangoincontainer 是物品自己的标记（inventoryitem.lua:17 的 setter）。
--   默认由 prefab 的 inventoryitem:canbepickedup 派生。
-- ★ 第三个条件用了 or：**栏的设置可以覆盖物品的设置**。
--   ⇒ 某些栏（如展示用容器）无视 cangoincontainer 限制。
	if not (item and item.components.inventoryitem and (item.components.inventoryitem.cangoincontainer or self.ignorescangoincontainer)) then
-- ↑ 第一层校验（cangoincontainer）。
		return false
-- ★ 第一层校验失败 → 返回 false。
-- ★★ 第二层：`GetGameModeProperty("non_item_equips") and item.components.equippable`
-- ★★★ 这是一个**游戏模式级**的特殊规则。
--   non_item_equips 直译「非物品装备」——某些模式（如剧情关卡）
--   禁止「可装备物」进入普通背包（避免玩家把装备当材料丢掉）。
-- ★ 对应客户端：inventory_replica.lua:211 有**同样的检查**，
--   说明这是「双端都要判定」的规则。
-- ★★ GetGameModeProperty 是模式查询函数，联机下两端结果必须一致
--   （都读同一个服务端模式）。
	elseif GetGameModeProperty("non_item_equips") and item.components.equippable then
-- ↑ 第二层校验（non_item_equips 游戏模式）。
		return false
-- ★ 第二层（non_item_equips）失败 → 返回 false。
-- ★ `elseif slot then` —— **slot 非 nil 才继续**（第二层的分支）。
-- ★★ 这就是「slot 可以为 nil」的落地点：nil 时直接跳到 251 行 return true。
-- ★ 注意 slot=0 与 slot=nil 不同：0 会进入本分支并在 237 行被拦下。
	elseif slot then
-- ↑ slot 非 nil 才继续。
-- ★★ `if slot < 1 or slot > self.maxslots` —— 槽位越界检查。
-- ★★★ 注意是 `< 1` 不是 `<= 0`：槽位从 1 开始（不是 0）。
-- ★ 这与 47 行的 maxslots 语义一致：有效槽号是 1..maxslots。
-- ★ ★ 防越界很重要：self.itemslots[999] = item 不会崩（Lua 允许任意键），
--   但会让物品「消失」（不在 1..maxslots 范围内，UI 不显示，
--   GetFirstItemInAnySlot 找不到，可能卡在存档里）。
--   ⇒ 这个检查是**数据完整性**的守卫，不只是「性能优化」。
		if slot < 1 or slot > self.maxslots then
-- ↑ 槽位越界检查。
			return false
-- ★★★ 槽号越界 → 返回 false。
		end
-- ↑ 越界块结束。
-- ★ `local existingitem = self:GetItemInSlot(slot)` —— 目标槽的现有物品。
		local existingitem = self:GetItemInSlot(slot)
-- ↑ 取目标槽现有物品。
-- ★★★ 第四层的判定：`if existingitem and islockedinslot and not (可堆叠例外)`
-- ★★ 语义：**锁定的槽位不能被替换**，除非新物品能和它合并堆叠。
-- ★★★ 「可堆叠例外」的三重条件（243-246 行）：
--   · existingitem 有 stackable 组件；
--   · 它**没满**（not IsFull）；
--   · 且能与新物品合并（CanStackWith）。
-- ★★ 为什么锁定的槽位可以「合并」？因为 lockedinslot 的语义是
--   「这个物品不能被单独拿走/丢弃」（如韦斯的套索？或 mod 的传送锚点），
--   但如果只是往它上面**加**同种物品，不算「移动」它。
-- ★★ islockedinslot 的其他用法见 6 处 assert（见 L6）。
-- ★★ ★ 注意 4-6 行有多余的括号和 tab 缩进不一致，说明这段是后期
--   快速加的，没有走正常的格式化。Klei 源码里很常见。
		if existingitem and
-- ↑ 第四层校验（islockedinslot）。
			existingitem.components.inventoryitem.islockedinslot and
-- ★★★ 目标槽的物品是否「锁定」。
			not (	existingitem.components.stackable and
-- ★★ 三重「可堆叠例外」条件（第①重：有 stackable）。
					not existingitem.components.stackable:IsFull() and
-- ★ 第②重：它没满。
					existingitem.components.stackable:CanStackWith(item)
-- ★ 第③重：与新物品同类。
				)
-- ↑ 例外条件收尾。
		then
-- ↑ if 的 then 起始。
			return false
-- ★★★ 锁定且不可合并 → 拒绝。
		end
-- ↑ 锁定判定块结束。
	end
-- ↑ elseif slot 块结束。
	return true
-- ★★★ 全部通过 → 允许放入。
end
-- ↑ CanTakeItemInSlot 结束。

-- ★ AcceptsStacks —— 查询是否接受整摞。直接返回字段，无逻辑。
-- ★ 客户端同款在 inventory_replica.lua:232（带 nil 兜底）。
function Inventory:AcceptsStacks()
-- ↑ AcceptsStacks 结束。
    return self.acceptsstacks
-- ↑ return acceptsstacks。
end
-- ↑ AcceptsStacks 结束。

-- ★ IgnoresCanGoInContainer —— 查询是否忽略 cangoincontainer。
function Inventory:IgnoresCanGoInContainer()
-- ↑ IgnoresCanGoInContainer 结束。
    return self.ignorescangoincontainer
-- ↑ return ignorescangoincontainer。
end
-- ↑ IgnoresCanGoInContainer 结束。

-- ★ IsThiefProof —— 「防偷」。
-- ★⚠ 疑似缺陷 L10b：构造函数（64-67 行）里 self.thiefproof 是**注释掉的**！
--   即字段未初始化，IsThiefProof() 返回 nil 而非 false。
--   ★ 多数调用方用 `if inv:IsThiefProof() then` —— nil 是假值，行为正确。
--   ★ 但若有人写 `== false` 或 `not x` 之外的处理就会出问题。
--   ⇒ 这是「未初始化字段返回 nil」的经典隐患。作者注释掉它说明
--     可能是「暂时不用但保留接口」。
function Inventory:IsThiefProof()
-- ↑ IsThiefProof 结束（字段未初始化）。
    return self.thiefproof
-- ★★ return thiefproof —— ★ 字段未初始化（67 行注释掉）⇒ 返回 nil。
end
-- ↑ IsThiefProof 结束（★ 存在 nil/false 类型不一致）。

-- ★★ CheckMigrationPets —— **存档迁移兼容**（局部函数）。
-- ★★★ 这个函数的存在是为了处理「存档格式变更」：
--   某些老存档里，宠物（petleash）存法与新版本不同，
--   读档时需要把老格式迁移到新格式。
-- ★ 三种 petleash 变体：
--   ① item.components.petleash（韦斯的宠物项圈）；
--   ② item.components.migrationpetowner（迁移专用）；
--   ③ 递归进容器（283 行）—— 因为容器里的项圈也有宠物。
-- ★★ 递归（286 行 CheckMigrationPets(inst, v)）是**无限深度**的，
--   见 L7。
-- ★★ ⚠ 这个函数名里的「Migration」指的是**存档迁移**，
--   与「玩家变形态（morph）」不是一回事。初读极易混淆。
local function CheckMigrationPets(inst, item)
-- ↑ CheckMigrationPets 函数头（存档迁移）。
    if inst.migrationpets ~= nil then
-- ↑ 性能守卫（无待迁移宠物则跳过）。
        if item.components.petleash ~= nil then
-- ★ 有 petleash → 收集它牵的宠物。
            for k, v in pairs(item.components.petleash:GetPets()) do
-- ↑ petleash 分支。
                table.insert(inst.migrationpets, v)
-- ★ 逐个加入 migrationpets。
            end
-- ↑ petleash 遍历结束。
        end
-- ↑ if 块结束。

        if item.components.migrationpetowner ~= nil then
-- ↑ migrationpetowner 分支。
            local pets = item.components.migrationpetowner:GetAllPets()
-- ★ 取迁移专用组件的所有宠物。
            if pets ~= nil then
-- ★ pets 非 nil 判定。
                for _, pet in ipairs(pets) do
-- ★ 遍历宠物列表。
                    table.insert(inst.migrationpets, pet)
-- ★ 加入 migrationpets。
                end
-- ↑ 宠物遍历结束。
            end
-- ↑ if pets 块结束。
        end
-- ↑ migrationpetowner 块结束。

        if item.components.container ~= nil then
-- ↑ 递归进容器。
            for k, v in pairs(item.components.container.slots) do
-- ★★★ 递归进容器（★ 无深度上限 —— 见 L7）。
                if v ~= nil then
-- ★ 槽里有东西才递归。
                    CheckMigrationPets(inst, v)
-- ★★ 递归调用自身（★ 无限深度风险）。
                end
-- ↑ if v 块结束。
            end
-- ↑ 容器遍历结束。
        end
-- ↑ if container 块结束。
    end
-- ↑ if migrationpets 块结束。
end
-- ↑ CheckMigrationPets 结束。

-- 【§三】OnLoad —— 反序列化。
-- ★★ isloading 标志在整个读档期间为 true（294/324 行）。
-- ★★ ★ isloading 的三个用途（全文搜索）：
--   ① 1213 行：读档时**不触发**「inventoryfull」事件（防止误报）；
--   ② 1270 行：Equip 时用 IsRestricted_FromLoad 而不是 IsRestricted
--      （见 equippable.lua:164，读档时对技能树标签宽容）；
--   ③ 1178-1186 行：读档时也会塞 activeitem（无特殊处理）。
-- ★★ 机制上是「全局加载锁」的局部版本。
function Inventory:OnLoad(data, newents)
-- ↑ OnLoad 函数头。
    self.isloading = true
-- ★★★ isloading = true（影响 1213/1270 两处判定）。

-- ↑ 空行。
-- ★ 读 items —— 用 pairs 遍历存档的 items 表。
-- ★★ 注意是 pairs 而非顺序遍历（存档表本身是哈希）。
    if data.items ~= nil then
-- ↑ 读 items 循环。
        for k, v in pairs(data.items) do
-- ★ 遍历存档的 items（哈希表，无序）。
-- ★★ SpawnSaveRecord(v, newents) —— 从存档记录**重建实体**。
-- ★ 返回 nil 表示「这个 prefab 现在不存在」（mod 被卸载了）。
--   ⇒ 300 行的 `if item ~= nil` 检查是必要的防御。
-- ★ 300 行的 CheckMigrationPets 在 GiveItem **之前**调用 ——
--   因为迁移可能会改变 petleash 的内容，需要在进背包前完成。
            local item = SpawnSaveRecord(v, newents)
-- ↑ SpawnSaveRecord 重建实体。
            if item ~= nil then
-- ★ 重建成功（★ 可能为 nil —— prefab 已卸载）。
                CheckMigrationPets(self.inst, item)
-- ★★★ 迁移检查在 GiveItem **之前**（迁移会改变内容）。
-- ★★ `self:GiveItem(item, k)` —— **指定原始槽号 k** 放回。
-- ★★★ ★ 这就是「槽位保持」的实现：存档记了槽号，读档按原槽放回。
--   玩家不会发现读档后背包顺序变了。这是重要的体验细节。
-- ★★ 但注意：若原槽已被占用（读档顺序问题），GiveItem 内部
--   （1094-1096 行）会回退到 GetNextAvailableSlot 找空位。
--   ⇒ 极端情况下顺序可能变，但只在槽位冲突时。
                self:GiveItem(item, k)
-- ↑ GiveItem 按原槽号放回（槽位保持）。
            end
-- ↑ if item 块结束。
        end
-- ↑ items 循环结束。
    end

-- ★ 读 equip —— 同样用 pairs。
    if data.equip ~= nil then
-- ↑ 读 equip 循环。
        for k, v in pairs(data.equip) do
-- ★ 遍历存档的 equip。
            local item = SpawnSaveRecord(v, newents)
-- ★ 重建装备实体。
            if item ~= nil then
-- ★ 重建成功。
                CheckMigrationPets(self.inst, item)
-- ★ 迁移检查（同样在 Equip 之前）。
-- ★★ `self:Equip(item)` —— **不传槽位**。
-- ★★★ 为什么？因为装备槽是 item 自己的属性（equippable.equipslot）。
--   存档里的 equip[k] 的 k 只是用来遍历的 key，实际装备位置由
--   equippable 组件决定。
-- ★★ 这与 301 行的 GiveItem(item, k) 形成对比：
--   普通槽的 k 是**有意义的**（要恢复到原位），
--   装备槽的 k 是**冗余的**（由 item 自带）。
-- ★ 小心：若某个 mod 的装备在读档后 equipslot 变了，
--   会装备到新槽位而非存档槽位 —— 这是「装备槽由物品定义」的设计后果。
                self:Equip(item)
-- ↑ Equip（不传槽位）。
-- ★★ Equip（★ 不传槽位 —— 槽由 equippable.equipslot 决定）。
            end
-- ↑ if item 块结束。
        end
-- ↑ equip 循环结束。
    end

-- ★ activeitem 的存档 → 读档时走 GiveItem 而非专门的「设为手上」。
-- ★★ 320 行的 `self:GiveItem(item)` 不指定槽位。
-- ★★ ★ 为什么不直接 SetActiveItem？因为 GiveItem 会走完整的检查链
--   （能否进栏、满不满、有没有同类可堆叠），最终可能落到某个空槽
--   而不是 activeitem。这是合理的：**读档后物品位置可以微调**。
-- ★ 与 301 行同理（普通槽也允许微调）。
    if data.activeitem ~= nil then
-- ↑ 读 activeitem。
        local item = SpawnSaveRecord(data.activeitem, newents)
-- ★ 重建手上物品。
        if item ~= nil then
-- ★ 重建成功。
            CheckMigrationPets(self.inst, item)
-- ★ 迁移检查。
            self:GiveItem(item)
-- ★★ GiveItem（★ 不是 GiveActiveItem —— 靠兜底落到 activeitem）。
        end
-- ↑ if item 块结束。
    end
-- ↑ activeitem 块结束。

    self.isloading = nil
-- ★★★ isloading = nil（★ 用 nil 而非 false，与本文件其他标志一致）。
end
-- ↑ OnLoad 结束。

-- 【§四】DropActiveItem —— 丢下手持物品。
-- ★★★ 330-331 行的顺序是**关键**：先 DropItem 再 SetActiveItem(nil)。
-- ★★ 若反过来（先清空 activeitem 再 DropItem(activeitem)），
--   DropItem 里 733 行的 RemoveFromOwner 会找不到 owner。
--   ⇒ 「先操作，后清状态」是处理「物品同时在两处」的标准顺序。
-- ★ 返回值是掉落的实体（可能为 nil，如果 RemoveFromOwner 返回 nil）。
function Inventory:DropActiveItem()
-- ↑ DropActiveItem 函数头。
	local active_item = nil
-- ★ 返回值初始化为 nil（手上没东西时）。
    if self.activeitem ~= nil then
-- ★ 手上确实有东西？
        active_item = self:DropItem(self.activeitem, true)
-- ★★★ 先丢（★ 顺序不可颠倒，见 BEFORE 注释）。
        self:SetActiveItem(nil)
-- ★★★ 后清状态（触发 newactiveitem 事件）。
    end
-- ↑ if 块结束。
	return active_item
-- ★★ return active_item（可能为 nil）。
end
-- ↑ DropActiveItem 结束。

-- ★★ ReturnActiveActionItem —— 「动作完成后把手上的东西放回去」。
-- ★★★ 337 行的条件极其绕，解开：
--   `item ~= nil and item == self.activeitem and
--    (self.inst.bufferedaction ~= nil) == not instant`
-- ★ 拆解最后一个比较：
--   `(有动作) == (不是瞬时)` ⟺ 两种情况：
--     ① 有动作 且 不是瞬时 → true == true；
--     ② 无动作 且 是瞬时 → false == false。
--   ⇒ 「正在执行一个长动作」时调用 instant=false，
--     「刚完成一个瞬时动作」时调用 instant=true。
-- ★★ ★ 338-341 行的三个 hack 标志是本函数的核心：
--   在「把手上的东西塞回背包」时，必须：
--     · ignorefull（背包满了也要塞）；
--     · ignoreoverflow（不要让背包本体抢走）；
--     · ignorespoverflow（不要让专用容器抢走）。
--   ⇒ 目的：**优先塞回玩家点的那个槽**，而不是任意槽。
-- ★★ 「Hacks for altering normal inventory:GiveItem() behaviour」
--   作者再次自认 hack。
function Inventory:ReturnActiveActionItem(item, instant)
-- ↑ ReturnActiveActionItem 函数头（三重条件）。
    if item ~= nil and item == self.activeitem and (self.inst.bufferedaction ~= nil) == not instant then
-- ★★★ 时机判定的第三段（三重等式，见 BEFORE 详解）。
        --Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 原注释保留（Hacks）。
        self.ignorefull = true
        self.ignoreoverflow = true
		self.ignorespoverflow = true

        if self:GiveItem(item) then
-- ↑ GiveItem 成功后 SetActiveItem(nil)。
            self:SetActiveItem(nil)

			if not instant then
				--Super hacks...
-- ★★ 「Super hacks...」（原注释保留）。
-- ★★★ 349-352 行在 GiveItem 成功后**修正 bufferedaction**：
--   349 行：`doerownsobject = item.components.inventoryitem:IsHeldBy(self.inst)`
--     含义：动作开始时「物品归玩家」，现在还给玩家了，
--     重新确认所有权（防止动作中途判定失效）。
--   351 行：`initialtargetowner = item.components.inventoryitem.owner`
--     含义：动作目标是这件物品，重新记录目标主人。
-- ★★★ 这两行说明 ReturnActiveActionItem 是「动作执行完毕后的收尾」，
--   而动作的合法性判定依赖这些字段，所以必须同步更新。
-- ★ 交叉引用：bufferedaction.lua 的 IsValid/TestForStart 依赖
--   doerownsobject 和 initialtargetowner 判定动作是否还有效。
-- ★★ 这就是「跨系统状态同步」的经典案例：
--   物品状态变了 → bufferedaction 的快照必须跟着更新。
				if item == self.inst.bufferedaction.invobject then
-- ↑ 原注释保留（Super hacks）。
					self.inst.bufferedaction.doerownsobject = item.components.inventoryitem:IsHeldBy(self.inst)
				end
				if item == self.inst.bufferedaction.target then
					self.inst.bufferedaction.initialtargetowner = item.components.inventoryitem.owner
				end
			end
        end

        --Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 三个 hack 标志复位。
        self.ignorefull = false
        self.ignoreoverflow = false
		self.ignorespoverflow = false
    end
end

-- ★ HasAnyEquipment —— 是否有任何装备。next(表) ~= nil 是判非空惯用法。
-- ★★ next() 在 Lua 里遍历哈希表；空表返回 nil，非空返回第一个 key。
--   这是 O(1) 的判空（不需要遍历所有元素）。
function Inventory:HasAnyEquipment()
-- ↑ HasAnyEquipment 结束。
    return next(self.equipslots) ~= nil
end

-- ★ IsWearingArmor —— 是否穿了护甲（遍历查 armor 组件）。
-- ★ 注意用 pairs（不需要顺序）—— 找到就 return。
function Inventory:IsWearingArmor()
-- ↑ IsWearingArmor 结束。
    for k, v in pairs(self.equipslots) do
        if v.components.armor ~= nil then
            return true
        end
    end
end

-- ★ ArmorHasTag —— 带**指定标签**的护甲检查（368 行的加强版）。
-- ★ 与 IsWearingArmor 的区别：368 只问「有没有护甲」，
--   这里问「有没有**带某标签**的护甲」。
function Inventory:ArmorHasTag(tag)
-- ↑ ArmorHasTag 结束。
    for k, v in pairs(self.equipslots) do
        if v.components.armor ~= nil and v:HasTag(tag) then
            return true
        end
    end
end

-- ★ EquipHasTag —— 任何装备带指定标签（不限 armor 组件）。
-- ★ 与 ArmorHasTag（376）的区别：不限组件类型。
-- ★ 用于「身上有没有带 xxx 标签的东西」类判定（如 debuff 检查）。
function Inventory:EquipHasTag(tag)
-- ↑ EquipHasTag 结束。
    for k, v in pairs(self.equipslots) do
        if v:HasTag(tag) then
            return true
        end
    end
end

-- ★ EquipHasSpDefenseForType —— 是否有**特殊伤害防御**（元素伤害）。
-- ★★ 用 SpDamageUtil.GetSpDefenseForType(v, sptype) > 0 逐件查询。
-- ★ 与 ApplyDamage（456 行）不同：这里只问「有没有」，
--   那里问「各防御多少、怎么分摊」。
-- ★★ 这是「防御查询」的统一入口，也说明 SpDamageUtil 封装了
--   「查 prefab 的 fireproof/frostproof 等标签」逻辑。
function Inventory:EquipHasSpDefenseForType(sptype)
-- ↑ EquipHasSpDefenseForType 结束。
	for k, v in pairs(self.equipslots) do
		if SpDamageUtil.GetSpDefenseForType(v, sptype) > 0 then
			return true
		end
	end
end

-- 【§五】IsHeavyLifting —— 查询是否负重过高。
-- ★ 直接返回字段。heavy 标签的物品在 1305-1310 行有特殊处理：
--   装备 heavy 到 BODY 槽时会踢掉手上的东西，反之亦然。
-- ★★ 这是「一个槽位排斥另一个槽位」的唯一实例。
function Inventory:IsHeavyLifting()
-- ↑ IsHeavyLifting 结束。
    return self.heavylifting
end

-- ★ IsFloaterHeld —— 查询是否手持漂浮物（钓鱼竿等）。
-- ★ `or false` 确保返回布尔而非 nil（因为 floaterheld 未初始化，50 行注释）。
function Inventory:IsFloaterHeld()
-- ↑ IsFloaterHeld 结束。
	return self.floaterheld or false
end

-- 【§五】★★ ApplyDamage —— **护甲减伤计算**。本文件最复杂的函数。
-- ★★★ 职责：把「原始伤害」转换成「实际扣血量 + 剩余特殊伤害」。
-- ★★ 输入：damage（数值）、attacker、weapon、spdamage（特殊伤害表）。
--   输出：leftover_damage（实际伤害）、spdamage（剩余特殊伤害）。
-- ★★★ 算法五步（408-500 行）：
--   ① 遍历装备槽，收集「吸收量」（absorbers 表）；
--   ② 算吸收比例（absorbed_percent = max）；
--   ③ 按比例扣血（absorbed_damage = damage × percent）；
--   ④ 按各护甲的吸收量**分配伤害损耗**（armor_damage 表）；
--   ⑤ 特殊伤害（元素伤害）单独按防御值分摊。
-- ★★★ ★ 核心设计决策（见 433-442 行的注释）：
--   **护甲吸收率取 max，不是 sum**。
--   ⇒ 穿 10 件护甲也不会叠加成 100% 吸收，最多是最强那件的吸收率。
--   ★ 这与「护甲损耗按比例分配」形成对比：
--     减伤取 max（玩家角度的合理设计），
--     耐久损耗按 absorb 量分配（让每件护甲都参与消耗）。
--   ⇒ 玩家视角：一件强甲 + 一件弱甲，效果=强甲，
--     但两件的耐久都在掉。这是一个微妙的平衡设计。
-- ★★ 遍历顺序（411 行 for slotid = 1, ...）保证了**确定性**：
--   「第一个能完全抵抗的装备返回 0」（419 行 return 0），
--   ⇒ 多个抵抗源时，**槽位顺序决定谁生效**。
--   ★ 这是有意设计：优先身上靠前的槽（如 BODY > HANDS）。
function Inventory:ApplyDamage(damage, attacker, weapon, spdamage)
-- ↑ ApplyDamage 函数头（五步算法）。
-- ★★ absorbers 表：`{ [armor组件] = 吸收量 }` —— 用**组件**做 key。
-- ★★★ 为什么用组件而非实体？因为一个实体可能挂多个 armor 组件，
--   且下面要调 armor 组件的方法（GetAbsorption/TakeDamage）。
-- ★★ 用组件做 key 还意味着「同一个组件被算两次会覆盖而非累加」
--   —— 421-422 行的 `absorbers[armor] = ...` 是赋值不是 `+`。
-- ★ damagetypemult：元素抗性倍率，初始 1，425 行逐件**相乘**。
--   ⇒ 穿两件各抗 10% 的装备 = 0.9 × 0.9 = 0.81（不是 0.8）。
--   ★ 这是「独立乘算」的常见简化（真实防具通常不叠加）。
    local absorbers = {}
-- ↑ absorbers/damagetypemult 初始化。
	local damagetypemult = 1
-- ★★★ `for slotid = 1, EquipSlot.Count()` —— 用** EquipSlot 的 API**
--   遍历所有装备槽（而不是 pairs(self.equipslots)）。
-- ★★★ 为什么？两个原因：
--   ① **确定性**：pairs(哈希表) 顺序随机，多件护甲的 max 计算会抖动；
--      用有序的 slotid 遍历保证同样的装备永远得到同样的结果。
--      ★ 这是联机游戏必须保证的：客户端预测与服务端必须一致！
--   ② **获取槽名**：EquipSlot.FromID(slotid) 把 ID 转回槽名
--      才能索引 self.equipslots[slotname]。
-- ★★ ★★ 这是文件头 require equipslotutil 的**唯一**用处（见 §零注释）。
-- ★★ CompareSlot.Count() ≤ 63 的限制在这里生效：
--   遍历次数 = 装备槽总数，mod 加太多槽会显著影响每次伤害计算的性能。
    for slotid = 1, EquipSlot.Count() do
-- ↑ 有序遍历所有装备槽（确定性）。
-- ★ EquipSlot.FromID(slotid) —— ID → 槽名。
-- ★ 这是 equipslotutil 的核心功能：网络传的是 ID（数字），
--   本地表的 key 是字符串，必须转换。
-- ★★ 初始化保证确定性（equipslotutil.lua:20 的 table.reverse_inplace）。
        local slotname = EquipSlot.FromID(slotid)
-- ↑ EquipSlot.FromID（ID → 槽名）。
-- ★ local v = self.equipslots[slotname] —— 取出该槽的物品。
-- ★ 如果该槽空，v 为 nil，414 行 `if v then` 跳过。
        local v = self.equipslots[slotname]
-- ↑ 取出该槽物品。
-- ★ `if v then` —— 跳过空槽（装备槽是稀疏的，不是所有槽都有东西）。
        if v then
-- ↑ 跳过空槽。
            --check resistance
-- ★★ 抵抗（resistance）优先级最高：优先于护甲。
-- ★ 三个 and 条件：
--   · 有 resistance 组件；
--   · HasResistance(attacker, weapon) —— 对这个攻击者/武器有抵抗；
--   · ShouldResistDamage() —— 「现在应该抵抗吗」（可能消耗次数）。
-- ★★★ ★ 关键：419 行直接 `return 0, nil` —— **完全免疫，提前返回**！
--   ★★ 这意味着：只要有一件装备能完全抵抗，**整个 ApplyDamage 结束**，
--     后面的槽位不再遍历，护甲也不会扣耐久。
--   ⇒ ★★ 「第一个满足的槽位决定结果」的确定性依赖（见函数头注释）。
--   ★ 使用场景：「小洋葱护盾」（完全抵挡一次伤害）等道具。
--   ★★ 排序依赖：416 行在 421 行（护甲）**之前**检查，
--     说明 resistance 是设计上的「绝对优先」。
            if v.components.resistance ~= nil and
-- ↑ resistance 优先级最高（完全免疫）。
                v.components.resistance:HasResistance(attacker, weapon) and
                v.components.resistance:ShouldResistDamage() then
-- ★ ResistDamage —— 消耗抵抗（如护盾用掉一次）。
-- ★ ★★ 然后 return 0, nil —— 「零伤害，无特殊伤害残留」。
--   这两个返回值的含义：0 = 玩家不受伤害；nil = 元素伤害也被清空。
--   ★★ 注意这里 return 0 而不是 return damage —— 伤害被完全消除。
                v.components.resistance:ResistDamage(damage, attacker)
-- ↑ ResistDamage + return 0（提前返回）。
                return 0, nil
-- ★ elseif armor —— 「否则看看有没有护甲」。
-- ★ 与 resistance 是 if/elseif，所以一件装备不能同时被两个系统处理。
-- ★★★ 注意：**护甲不是提前 return**（不像 resistance），
--   而是把吸收量记录下来，最后统一计算（430-442 行）。
--   ★ 这是「收集 → 汇总」的两阶段模式。
            elseif v.components.armor ~= nil then
-- ↑ elseif armor（记录吸收量）。
-- ★★ absorbers[armor] = armor:GetAbsorption(attacker, weapon)
-- ★ GetAbsorption 返回吸收量（如 0.8 = 吸收 80% 伤害）。
-- ★★★ 参数 (attacker, weapon) 表明吸收率可以**因攻击者/武器而异**。
--   例：某些护甲对特定敌人吸收更高（如对蜘蛛的护盾）。
-- ★★ 「赋值」而非累加：一件装备一个 armor 组件，不叠加。
                absorbers[v.components.armor] = v.components.armor:GetAbsorption(attacker, weapon)
-- ↑ absorbers[armor] = 吸收率（赋值非累加）。
            end
-- ★ damagetyperesist —— 元素抗性组件（与 armor 并列，不是互斥）。
-- ★★ 与 416 行的 resistance（完全抵抗）是**不同组件**：
--   · resistance = 完全免疫（触发即 return 0）；
--   · damagetyperesist = 部分减伤（乘算降低伤害）。
-- ★★★ 注意这个 if 不在 elseif 里 —— 可以和 armor 同时存在。
--   即「既穿护甲又有元素抗性」是合法的组合。
            if v.components.damagetyperesist ~= nil then
-- ↑ damagetyperesist（部分减伤，可与护甲共存）。
-- ★★ damagetypemult *= resist —— **乘算**降低元素伤害。
-- ★★ 逐件相乘（不是取 min 或 max）。
--   ⇒ 多件抗性叠加可能导致伤害趋近于零（0.5 × 0.5 = 0.25）。
--   ★ 这是「独立乘算」的常见简化。设计上应确保单件抗性不强。
-- ★★ ★ 注意：这个乘法在「护甲吸收」**之前**（430 行才应用）。
--   ⇒ 元素抗性会**同时**降低「扣血量」和「护甲损耗」。
--   ★ 这是合理的：抗性高时护甲受到的损耗也小。
                damagetypemult = damagetypemult * v.components.damagetyperesist:GetResist(attacker, weapon)
-- ↑ damagetypemult *= 抗性（乘算叠加）。
            end
        end
    end

-- ★★ `damage = damage * damagetypemult` —— 应用元素抗性。
-- ★★★ ★ 顺序关键：抗性**先于**护甲计算。
--   展开后的总伤害：`最终伤害 = 原伤害 × 抗性倍率 × (1 - 护甲吸收率)`。
-- ★ 430 行之后的 damage 才是「实际进入护甲计算的值」。
	damage = damage * damagetypemult
-- ↑ 应用元素抗性（先于护甲）。
-- ↑ 原注释：print("Incoming damage", damage) —— 调试用（已注释）。
-- ★ 保留注释掉的 print 是 Klei 风格：标记调试历史。
	-- print("Incoming damage", damage)
-- ↑ 注释掉的调试 print。

-- ★★★ 吸收计算：absorbed_percent（减伤率）和 total_absorption（分配用）。
-- ★★★ ★★ 核心设计（435-439 行）：
--   `absorbed_percent = math.max(amt, absorbed_percent)` —— **取最大值**！
--   ★★ 即：**穿多件护甲不减伤叠加，只取最强那件的吸收率**。
--   ★★★ 设计理由（推测）：
--   · 避免玩家穿满护甲就无敌（否则堆叠护甲是最优解）；
--   · 让「换更好的护甲」比「穿更多护甲」更有价值；
--   · 护甲的价值在于**分类**（抗火/抗寒/抗雷），而非数量。
--   ★★ total_absorption（累加）只用于**分配耐久损耗**（450-452 行），
--     不影响玩家实际减伤。
--   ⇒ 详见 HEADER_EXTRA 的核心设计注释。
-- ★★ 若想让多件护甲叠加减伤，需改成 `absorbed_percent + amt`
--   或某种 max 封顶公式。这是平衡性改动，风险高。
	local absorbed_percent = 0
-- ↑ 吸收计算（取 max vs 累加）。
	local total_absorption = 0
	for armor, amt in pairs(absorbers) do
		-- print("\t", armor.inst, "absorbs", amt)
-- ★★ `math.max(amt, absorbed_percent)` —— ★ 减伤率**取最大值**。
-- ★★★ 这行是整个 ApplyDamage 的灵魂。
--   若改成 `absorbed_percent + amt`（累加），穿 3 件 50% = 150% 吸收 = 免疫。
--   ★ 取 max 意味着：**护甲品质比数量重要**。这是关键平衡决策。
-- ★★★ ★ 但注意 total_absorption 是累加的（438 行），
--   所以「减伤取 max，耐久分摊按 sum」——两个不同策略并存。
--   ⇒ 这是本函数最精妙也最容易误改的地方。
		absorbed_percent = math.max(amt, absorbed_percent)
-- ↑ 减伤率取最大值（灵魂行）。
-- ★ total_absorption += amt —— 累加所有护甲的吸收量。
-- ★★ 这个值**只用于** 451 行分配耐久损耗，不影响减伤。
--   · 若一件强甲 + 一件弱甲，总吸收 = 0.8 + 0.3 = 1.1；
--   · 玩家减伤仍是 0.8（取 max）；
--   · 但耐久损耗按比例分配：强甲承担 0.8/1.1 ≈ 73%，弱甲 27%。
--   ★★ 即：**弱甲也会因为强甲的存在而少扣耐久**。
--   平衡效果：让多穿护甲成为「耐久分散」的策略。
		total_absorption = total_absorption + amt
-- ↑ 累加吸收量（用于分摊）。
	end

-- ★★★ absorbed_damage = damage × absorbed_percent —— 被吸收的伤害量。
-- ★★★ leftover_damage = damage - absorbed_damage —— 实际扣血量。
-- ★★ 这是**减伤的最终公式**：
--   实际扣血 = 原伤害 × 抗性倍率 × (1 - max(各护甲吸收率))
-- ★ 三行代码，最核心的公式。
-- ★★ 注意 leftover_damage **不会**为负（因为 absorbed_percent ≤ 1）。
	local absorbed_damage = damage * absorbed_percent
-- ↑ absorbed_damage / leftover_damage 公式。
	local leftover_damage = damage - absorbed_damage

	-- print("\tabsorbed%", absorbed_percent, "total_absorption", total_absorption, "absorbed_damage", absorbed_damage, "leftover_damage", leftover_damage)

-- ★★ armor_damage 表：`{ [armor组件] = 该护甲应扣的耐久 }`。
-- ★★★ 它与 absorbers 的区别：
--   · absorbers（409 行）：收集阶段，吸收率；
--   · armor_damage（446 行）：分配阶段，实际扣多少耐久。
-- ★ 这是「收集 → 计算 → 分配 → 结算」四阶段模式的最后一步。
-- ★ 若 total_absorption 为 0（无护甲），整个 447-453 块跳过。
	local armor_damage = {}
-- ↑ armor_damage 初始化。
-- ★ `if total_absorption > 0 then` —— 只有有护甲时才分配。
-- ★★ 此时记录统计：ProfileStatsAdd("armor_absorb", absorbed_damage)
--   上报给分析系统（只影响开发/运营统计，不影响游戏逻辑）。
-- ★★ ★ 注意 448 行的统计在 `total_absorption > 0` 内 ——
--   即只有真正挡了伤害才上报。合理。
	if total_absorption > 0 then
-- ↑ 只有有护甲才分配。
		ProfileStatsAdd("armor_absorb", absorbed_damage)

-- ★★★ 分配耐久损耗：每件护甲分得 `absorbed_damage × (它/total)`。
-- ★★ 450-452 行的循环：
--   `armor_damage[armor] = absorbed_damage × amt/total + armor:GetBonusDamage()`
-- ★★★ GetBonusDamage —— 「额外损耗」。某些护甲（如易损的）承受更多损耗。
--   这是个**加成项**（+ 号），意味着这类护甲扣耐久更快。
-- ★★★ ★ 设计含义：**护甲越强，掉耐久越快**（因为它吸收了更多）。
--   强甲吸得多 → 分到的 absorbed_damage 更多 → 耐久掉得更快。
--   ★ 这是鼓励玩家「换装升级」而非「一套穿到死」的正向反馈。
-- ★★★ 注意：减伤取 max（不叠加），但耐久损耗按 sum 分摊。
--   两套策略并存，是本函数最精妙的设计（见 433-439 行注释）。
		for armor, amt in pairs(absorbers) do
-- ↑ 耐久损耗分配循环。
			armor_damage[armor] = absorbed_damage * amt / total_absorption + armor:GetBonusDamage(attacker, weapon)
		end
	end

-- ★「应用特殊伤害」（spdamage 段）。
-- ★★★ 与普通伤害**完全独立**：
--   · 普通伤害看 armor（护甲吸收率，取 max）；
--   · 特殊伤害看 spdefenders（元素防御值，逐件累加）。
-- ★★ 为什么要分开？因为元素伤害的减伤来自**标签**（fireproof）
--   而不是护甲数值，且**不同元素可以叠加**（防火+防雷同时生效）。
-- ★ spdamage 的类型：`{ [sptype] = 伤害量 }`（如 {fire=20, frost=10}）。
-- ★ 这是 spdamageutil 的数据结构约定。
	--Apply special damage
-- ↑ 特殊伤害段开始。
-- ★ `if spdamage ~= nil then` —— 只有调用者传了特殊伤害才进入。
-- ★★ 与普通伤害的分工：普通伤害用 armor，特殊伤害用元素抗性。
-- ★ 两套系统**互不干扰**：护甲不会减火伤，火抗不会减普攻。
	if spdamage ~= nil then
-- ↑ if spdamage ~= nil。
-- ★★ 遍历每种特殊伤害类型（fire/frost/lightning/...）。
-- ★ `for sptype, dmg in pairs(spdamage)` —— sptype 是伤害类型名。
-- ★★ 458 行：特殊伤害也乘 damagetypemult（元素抗性）。
--   ⇒ 即「特殊伤害也可以被元素抗性组件进一步减伤」。
-- ★★★ 这是一个双重减伤点：如防火装备的 damagetyperesist 组件
--   既可能降低火伤（自身），又可能降低「其它特殊伤害」。
		for sptype, dmg in pairs(spdamage) do
-- ↑ 遍历元素伤害类型。
			dmg = dmg * damagetypemult
-- ★★ spdefenders 表：`{ [实体] = 剩余防御值 }`。
-- ★★ 与 absorbers 用组件做 key 不同，这里用**实体**做 key。
-- ★ 原因：SpDamageUtil.GetSpDefenseForType 返回的是「实体对某元素的防御值」，
--   且要扣除剩余防御，所以必须能定位实体来调用后续逻辑。
-- ★ count 追踪还有多少个防御者（用于 while 循环的终止）。
-- ★★★ ★ 这里是**累加逻辑**（与护甲取 max 不同）：
--   多件元素抗性**叠加**（count += 1），因为元素抗性不像护甲那样
--   「取最强就够」——防火+防寒是两种不同的抗性，
--   同一种元素（fire）穿两件也可以叠加。
-- ★★ 这是本文件里「减伤取 max（护甲）」vs「减伤可叠加（元素）」的对比点。
			local spdefenders = {}
-- ↑ spdefenders 池化分摊（与护甲取 max 不同）。
			local count = 0
			for eslot, equip in pairs(self.equipslots) do
-- ★★ GetSpDefenseForType(equip, sptype) —— 查实体对某元素的防御值。
-- ★ 遍历**所有装备槽**（461 行），累加有防御的。
-- ★★ 元素防御来自**标签**（如 fireproof 标签）：
--   SpDamageUtil.GetSpDefenseForType 内部查 equip:HasTag(tag)。
-- ★ 若 def > 0，说明这件装备能防御这种元素，加入 spdefenders。
				local def = SpDamageUtil.GetSpDefenseForType(equip, sptype)
-- ↑ GetSpDefenseForType 查元素防御。
-- ★ `if def > 0` —— 只收录有防御的装备。
-- ★★ 若 def = 0（无防御），不影响特殊伤害的分摊。
				if def > 0 then
-- ↑ 只收录有防御的。
					count = count + 1
					spdefenders[equip] = def
				end
			end
-- ★★★ `while dmg > 0 and count > 0` —— **特殊伤害的分摊循环**。
-- ★★★ 算法（与护甲完全不同）：
--   ① 每次循环把剩余伤害**均分**给所有还在列表里的防御者：
--      `splitdmg = dmg / count`；
--   ② 每个防御者尝试吸收 splitdmg：
--      若防御值 > splitdmg → 全部吸收，防御值 -= splitdmg；
--      否则 → 防御值归零，count--（这个防御者「用完了」）；
--   ③ 重复直到伤害耗尽（dmg=0）或防御者用完（count=0）。
-- ★★★ ★ 这是「池化分摊」算法：把伤害当水，防御值当容量，
--   逐轮平分直到某方枯竭。
-- ★★ 与护甲的对比：
--   · 护甲：取 max（一刀切），预先算好比例；
--   · 元素：池化分摊（动态迭代）。
-- ★★★ 为什么元素要用池化？因为不同元素的防御值差异大
--   （防火帽 +10 防火、防霜披风 +8 防寒），
--   池化能保证「防御值高的装备优先多扛」。
--   护甲是同类（都是 armor），取 max 合理。
-- ★★ 若某件装备的防御值特别高（远大于 splitdmg），
--   它会在多轮循环中持续吸收（count 减得慢）。
--   这就是「更强的元素抗性能扛更多」的实现。
-- ★⚠ 性能：O(防御者数量 × 循环轮数)，但循环轮数通常很少
--   （一轮基本就能分完，除非某件装备防御值极高）。
			while dmg > 0 and count > 0 do
-- ↑ 池化分摊主循环。
-- ★★★ splitdmg = dmg / count —— 把剩余伤害**均分**给防御者。
-- ★★ 每轮循环都重新计算（因为 count 会变），这是池化分摊的核心。
-- ★ 若某防御者这次没能全部吸收，下次分摊时它的 count 就被排除
--   （477-478 行 count -= 1），分母缩小，剩余伤害分给还活着的。
-- ★★★ 这就是「强者多扛」的数学表达。
				local splitdmg = dmg / count
-- ↑ splitdmg 均分。
				for k, v in pairs(spdefenders) do
					local defended
-- ★★ 「防御值 > 本轮分摊量」= 这件装备能全吃下这轮伤害。
-- ★ defended = splitdmg —— 它吸收了全部 splitdmg。
-- ★ spdefenders[k] = v - splitdmg —— 防御值扣减，但**仍在列表里**。
-- ★★ 即「防御值 > 0 就继续参与下一轮分摊」。
					if v > splitdmg then
-- ↑ 防御值 > 分摊量（继续参与）。
						defended = splitdmg
						spdefenders[k] = v - splitdmg
					else
-- ★★ 「防御值 ≤ 本轮分摊量」= 这件装备的防御**用完了**。
-- ★ defended = v —— 它只能吸收 v（比 splitdmg 少）。
-- ★ spdefenders[k] = nil —— 从防御者列表移除。
-- ★ count = count - 1 —— 分摊人数减少（后续 splitdmg 会变大）。
-- ★★★ ★ 这是「防御耗尽」的判定。下一轮 count 变小，
--   剩余伤害分给更强的防御者。
-- ★ 举例：dmg=100，防御者 A(def=30) B(def=50)：
--   第1轮：splitdmg=50。A: 30<50 → 用完（count=1），吸收30。B: 50=50 → 用完，吸收50。dmg=20。
--   count=0 → 退出。剩余 20 伤害（480 行减去已防御部分）。
--   ⇒ 最终 spdamage.fire = 20（溢出伤害）。
						defended = v
-- ↑ 防御值 ≤ 分摊量（耗尽，移出）。
						spdefenders[k] = nil
						count = count - 1
					end
-- ★★ dmg = dmg - defended —— 扣除本件装备吸收的部分。
-- ★★★ 循环内逐件扣除，循环结束后 dmg = 未被吸收的剩余伤害。
-- ★★ 这就是为什么 487 行 `spdamage[sptype] = dmg > 0 and dmg or nil`。
-- ★ 注意：count 减 1 也会让 469 行下轮 splitdmg 变大。
					dmg = dmg - defended
-- ↑ 扣除已防御部分。
-- ★ local armor = k.components.armor —— 该实体的护甲组件（可能为 nil）。
-- ★★ 用于 482-483 行把特殊伤害也记入 armor_damage（消耗耐久）。
-- ★★★ ★ 注意：特殊伤害消耗的是「护甲耐久」而非「元素抗性耐久」。
--   即「防火帽」这种元素抗性装备，穿防火帽挡火时也会扣普通护甲的耐久？
--   ⇒ 实际中：防火帽通常也挂 armor 组件（提供基础减伤+元素抗性）。
--   ⇒ 所以挡火会同时消耗它的护甲耐久。合理（护甲在「工作」）。
-- ★ 若该实体只有元素抗性无 armor 组件（如纯药水效果），
--   跳过（482 行的 nil 检查）。
					local armor = k.components.armor
-- ↑ 取护甲组件（可能 nil）。
					if armor ~= nil then
						armor_damage[armor] = (armor_damage[armor] or 0) + defended
					end
				end
			end
-- ★★★ `spdamage[sptype] = dmg > 0 and dmg or nil` —— 溢出伤害回写。
-- ★★★ 这是「三元表达式」的 Lua 惯用法：
--   若 dmg > 0（还有溢出）→ 值为 dmg（真值）→ 返回 dmg；
--   若 dmg = 0（完全吸收）→ `and` 得 0 → 0 是**真值**（Lua 只有 nil/false 是假）
--     → `or nil` 不触发 → 返回 0？不对！
-- ★★ ★ 等等，这里有坑：dmg = 0 时，`dmg > 0` 为 false → 短路返回 false →
--   `false or nil` = **nil**。
-- ★★ 所以：dmg > 0 → dmg；dmg ≤ 0 → nil。
--   「完全吸收」→ 该类型标记为 nil（从表里删除/置 nil）。
-- ★★★ 这就是 Lua 三元 `(cond and A or B)` 的经典陷阱：
--   当 A 为 false/nil 时会退化为 B。本例恰好「完全吸收 → nil」
--   正是我们想要的结果，所以这个写法是**正确的**。
-- ★ 但对不熟悉的人来说是**误导性代码**。可读性差。
			spdamage[sptype] = dmg > 0 and dmg or nil
-- ↑ 溢出伤害回写（三元陷阱）。
		end
-- ★★ `if next(spdamage) == nil then spdamage = nil end` ——
--   所有元素伤害都被完全吸收 → 整个 spdamage 表置 nil。
-- ★★ next(spdamage) == nil 表示「表空」。
-- ★ 这样调用者能通过 `spdamage == nil` 判断「没有残留特殊伤害」。
-- ★★★ 为什么需要这个？返回值语义：spdamage=nil 表示「打完了，连元素伤都清了」。
--   若返回一个全 nil 的表（如 {fire=nil}），调用者难以区分。
		if next(spdamage) == nil then
-- ↑ 全部吸收则 spdamage 置 nil。
			spdamage = nil
		end
	end

-- ★「应用护甲耐久损耗」。
-- ★★★ 把 446-492 收集的 armor_damage 真正结算（调用 TakeDamage）。
-- ★★ 这是「收集 → 计算 → 分配 → **结算**」的第四阶段。
-- ★ 注意：此处**不处理** spdamage（元素伤害）的耐久，
--   元素抗性的耐久在 482-483 行的循环里已累加进 armor_damage。
	--Apply armor durability loss
-- ↑ 护甲耐久结算段。
-- ★★★ 遍历 armor_damage，调用每个 armor 组件的 TakeDamage。
-- ★★ 这是护甲扣耐久的**唯一**执行点。整个 ApplyDamage 的最终目的之一。
-- ★★★ 注意变量名复用：`for armor, dmg in pairs(armor_damage)`
--   这里的 armor 是 armor_damage 的 key（armor 组件），dmg 是损耗量。
-- ★ 这行调用 armor:TakeDamage(dmg) 扣耐久。
-- ★★ 注意：普通伤害 + 元素伤害的损耗已**合并**在 armor_damage 里，
--   这里一次性扣除。若某装备既挡了普攻又挡了火，会合并扣一次。
	for armor, dmg in pairs(armor_damage) do
-- ↑ TakeDamage 调用（扣耐久）。
		armor:TakeDamage(dmg)
	end

-- ★★★ 返回 (leftover_damage, spdamage) —— 实际扣血量 + 剩余元素伤害。
-- ★★ 两个返回值对应调用方的期望：
--   · leftover_damage：扣多少血（可能是 0，若被 resistance 完全抵抗）；
--   · spdamage：剩余的特殊伤害（可能被清空为 nil）。
-- ★ 典型调用方：health.lua 收到伤害后 DoDelta(leftover_damage)。
-- ★ 若 spdamage 非 nil，health 或 sanity 会继续处理元素伤害。
	return leftover_damage, spdamage
-- ↑ 返回 (leftover_damage, spdamage)。
end

-- 【§六】GetActiveItem —— 「手上拿着的」。
-- ★★ 全文件被外部调用最多的查询函数（几乎所有操作都针对手上物品）。
-- ★ 与 GetEquippedItem（773 行）的区别：
--   · activeitem = 任意可拿的东西（草、石子、食物）；
--   · equippeditem = 只限 equippable 组件的装备。
-- ★ 客户端版本：inventory_replica.lua:308（读 classified）。
function Inventory:GetActiveItem()
-- ↑ GetActiveItem 结束（纯查询）。
    return self.activeitem
end

-- ★★ IsItemEquipped —— 「这件装备穿在哪个槽」。
-- ★★★ ★ 返回**槽位名**（字符串，如 "head"）而不是布尔！
--   这是本文件最容易被误用的函数之一：
--     if inv:IsItemEquipped(x) then   -- 永远为真（非 nil 槽名就是真值）
--   ⇒ 正确写法必须是 `if inv:IsItemEquipped(x) ~= nil then`。
-- ★ 用法：1035 行 GiveItem 里用它判断「这件要给的装备是否正穿着」。
-- ★★ 复杂度 O(装备槽数)，最多 4 次比较。
function Inventory:IsItemEquipped(item)
-- ↑ IsItemEquipped 结束（返回槽名而非布尔！）。
    for k,v in pairs(self.equipslots) do
        if v == item then
            return k
        end
    end
end

-- ★★ SelectActiveItemFromEquipSlot —— 「把装备槽里的东西拿到手上」。
-- ★★ 流程（顺序关键）：
--   ① 516 行备份旧的 activeitem；
--   ② 517 行 Unequip（从槽里取出）；
--   ③ 518 行 GiveActiveItem（放到手上）；
--   ④ 520-522 行把旧的手上物品塞回背包（如果它没被自动穿上）。
-- ★★★ ★ 这就是「换装」语义：手上和装备槽**互换**，不是单向取出。
-- ★ 与 548 行 SelectActiveItemFromSlot（普通槽版）的差异：
--   普通槽版不需要 Unequip，直接操作 itemslots。
function Inventory:SelectActiveItemFromEquipSlot(slot)
-- ↑ SelectActiveItemFromEquipSlot 结束（装备↔手上互换）。
    if self.equipslots[slot] then
-- ★ local olditem = self.activeitem —— 备份，稍后要还回背包。
        local olditem = self.activeitem
-- ↑ 备份旧 activeitem。
-- ★★ self:Unequip(slot) —— 注意**不传 force**。
-- ★★ ⇒ 若装备带 preventunequipping（1224 行），Unequip 返回 nil，
--   518 行 GiveActiveItem(nil) 无操作，520 行把旧物还回。
--   ★ 净效果：**什么都没发生**。这是对「粘住」装备的正确保护。
        local newitem = self:Unequip(slot)
-- ↑ Unequip（不带 force）。
        self:GiveActiveItem(newitem)
-- ↑ GiveActiveItem(卸下的装备)。

-- ★★★ `if olditem and not self:IsItemEquipped(olditem) then` ——
--   ★★ 这个判定是**必要的**：如果旧的手上物品恰好也被穿在身上
--     （如玩家同时手持并穿着同一件可堆叠装备），
--     就**不要**把它塞回背包（否则会与装备槽里的实体冲突）。
-- ★★★ 这揭示了一个 DST 的不变量：
--   **同一个实体可以同时是 activeitem 和 equipslots[x]**。
--   OnSave:219 行专门为这个情况做了去重处理。
-- ★ 这是「多槽位共享一个实体」在 DST 里唯一允许的情形。
        if olditem and not self:IsItemEquipped(olditem) then
-- ↑ 「旧物未被同时穿着」判定。
            self:GiveItem(olditem)
-- ★ 旧物品塞回普通背包（不指定槽）。
        end
-- ↑ 「旧物未同时穿着」块结束。
    end
-- ↑ if 块结束。

    return self.activeitem
-- ★★ return self.activeitem（★ 可能已换人）。
end
-- ↑ SelectActiveItemFromEquipSlot 结束。

-- ★★ CombineActiveStackWithSlot —— 「把手上的一摞与槽里的合并」。
-- ★★★ 三步：
--   ① 529 行同时查两个表（itemslots 优先，再查 equipslots）；
--   ② 535 行验证**可合并**（stackable + CanStackWith）；
--   ③ 539-545 行两种合并方式：
--     · stack_mod 且手上是堆叠 → 手上减 1、槽里加 1（保留两摞）；
--     · 否则 → 整摞 Put 进槽里，手上拿到溢出的部分（Put 的返回值）。
-- ★★★ stack_mod 参数是「只挪一个还是整摞挪」：
--   · stack_mod=true → 只挪 1 个（用于「点一下放一个」）；
--   · stack_mod=nil → 整摞合并。
function Inventory:CombineActiveStackWithSlot(slot, stack_mod)
-- ↑ CombineActiveStackWithSlot 结束。
-- ★★ `self.itemslots[slot] or self.equipslots[slot]` —— 同时查两张表。
-- ★★★ ★ 这是本文件**唯一**把普通槽与装备槽当同一空间处理的地方！
--   因为 UI 上「合并到槽」的点击可能落在装备槽上（equipstack 装备）。
-- ★★ 隐含约定：**装备槽的键与普通槽的键在同一命名空间**。
--   普通槽键是 1..maxslots（整数），装备槽键是 "hands"/"head" 等（字符串），
--   ⇒ 两者不会冲突（整数 ≠ 字符串）。这是「多态键」的设计。
    local invitem = self.itemslots[slot] or self.equipslots[slot]
-- ↑ 同时查两张表（唯一的多态键处）。
    if invitem == nil then
-- ★ 目标槽没东西（或槽号非法）→ 直接返回。
        return
-- ↑ 早退。
    end
-- ↑ 空位检查块结束。

    local handitem = self.activeitem
-- ★ 取手上的东西（合并的另一方）。
-- ★★ `if not (handitem and handitem.components.stackable and
--   handitem.components.stackable:CanStackWith(invitem)) then return end`
-- ★ 三个条件与运算：手上非空 + 手上可堆叠 + 两者可合并。
-- ★★ 注意这里**不检查槽内物品是否可堆叠**——
--   而 543 行 `invitem.components.stackable:Put(handitem)` 会崩。
-- ★★★ 潜在隐患：如果槽内是一个不可堆叠的物品（如石块），
--     543 行的 Put 就不存在。
--   ★ 实际上安全：CanStackWith(invitem) 会返回 false
--     （stackable.lua 的实现会检查对端是否可堆叠），所以 535 行就 return 了。
--   ⇒ 这是 CanStackWith 的**契约保证**，不是隐含假设。
	if not (handitem and handitem.components.stackable and handitem.components.stackable:CanStackWith(invitem)) then
-- ↑ 可合并判定。
        return
-- ★★ 不可合并 → 什么都不做（静默失败）。
    end
-- ↑ 判定块结束。

-- ★★★ 两条路径的分叉点。
-- ★★ stack_mod 且手上是堆叠 → 只挪 1 个：
--   540 行手上减 1；541 行槽里加 1。
-- ★★★ ★ 注意这里用的是 **SetStackSize**（正规 setter，走 onchange），
--   而不是直接改 stacksize 字段。★ 所以不是 hack，事件会正常触发。
    if stack_mod and handitem.components.stackable:IsStack() then
-- ↑ 两条合并路径的分叉。
-- ★ SetStackSize(StackSize() - 1) —— 手上从 N 变 N-1。
-- ★★ ★★ 边界隐患：若手上只有 1 个（N=1）且是 stack，539 行条件成立，
--   540 行把它减到 0 —— 一个 stacksize=0 的「空堆」实体。
--   ★ stackable.lua 的 SetStackSize(0) 通常会触发实体 Remove，
--     但这里没检查返回值。若不 Remove，槽里会多一个 stacksize=0 的实体。
-- ★★ 这是一个真实的边界隐患，值得在移植时留意。
        handitem.components.stackable:SetStackSize(handitem.components.stackable:StackSize() - 1)
-- ↑ 手上减 1。
-- ★ SetStackSize(StackSize() + 1) —— 槽里的加 1。
        invitem.components.stackable:SetStackSize(invitem.components.stackable:StackSize() + 1)
-- ↑ 槽里加 1。
    else
-- ★★ else 分支：整摞合并（Put 的返回值即溢出部分）。
-- ★★★ `local leftovers = invitem.components.stackable:Put(handitem)` ——
--   整摞合并。Put 的返回值是「没放进去的部分」。
-- ★★ ★ 关键：Put 不会**移动**原实体，只是改数量；
--   多余的部分会**新生成一个实体**返回（stackable.lua 的行为）。
--   ⇒ 544 行把 leftovers 设为新的 activeitem —— 手上的东西换了实体。
-- ★★ 这就是「合并后手上还剩多少」的实现：手上一摞 10 个，
--   槽里那摞最多 10 → 合并后手上还剩 0 个（leftovers 为 nil，实体被 Remove）。
-- ★ 若槽里那摞还能装（不满），leftovers 就是剩余部分。
-- ★★ 注意：这里 SetActiveItem(leftovers) 没有 nil 检查，
--   但 1250 行 SetActiveItem(item) 第一行就是 `if item and ...`，
--   ⇒ nil 时会走到 1254 行 `elseif item == nil or ...` 分支，
--   把 activeitem 置 nil + PushEvent。这是**正确**的（手上确实空了）。
        local leftovers = invitem.components.stackable:Put(handitem)
-- ↑ 整摞 Put，返回溢出部分。
        self:SetActiveItem(leftovers)
-- ↑ 溢出的成为新手上的。
    end
-- ↑ if/else 结束。
end
-- ↑ CombineActiveStackWithSlot 结束。

-- ★★ SelectActiveItemFromSlot —— 「把普通槽里的东西拿到手上」。
-- ★★★ 流程（与装备槽版的差异）：
--   ① 552 行检查 islockedinslot（锁定物品不能取出）；
--   ② 558 行**直接从 itemslots 摘除**（不需要 RemoveItem）；
--   ③ 559 行 PushEvent("itemlose") 通知客户端；
--   ④ 561 行设为 activeitem；
--   ⑤ 563-565 行把旧的手上物品塞回**原来的槽位**（slot）。
-- ★★ ★ 与装备槽版的关键差异：旧物品**回到原槽**而不是任意槽。
--   这让「A↔B 交换」保持位置稳定，玩家体验更好。
function Inventory:SelectActiveItemFromSlot(slot)
-- ↑ SelectActiveItemFromSlot 结束（普通槽↔手上互换）。
	local newitem = self.itemslots[slot]
-- ★★★ 取目标槽物品（★ 只查 itemslots，不查 equipslots）。
	if newitem == nil then
-- ★★ 槽为空 → 直接返回（★ 返回 nil 而非 activeitem）。
        return
-- ↑ 早退。
-- ★★ 锁定物品不能取出 —— 553 行 assert(BRANCH ~= "dev") 见 L6。
-- ★★ ⚠ 这个 assert 在 dev 分支下会**中断执行**（抛错）。
--   生产环境（BRANCH ~= "dev"）则静默 return。
-- ★ 这是「开发期崩溃、生产期静默」的典型写法 —— 作者用它来
--   标记「这个分支在正常流程下不应该走到」。
-- ★★ 风险：若某个 mod 提供了带 islockedinslot 且玩家可操作的物品，
--   dev 版会 crash。这是 L6 说的隐患。
	elseif newitem.components.inventoryitem and newitem.components.inventoryitem.islockedinslot then
-- ↑ 锁定物品 assert（见 L6）。
-- ↑ 空值判定块结束。
		assert(BRANCH ~= "dev")
-- ★★ 锁定物品 assert（见 L6：dev 版崩溃）。
		return
-- ★ 生产环境静默返回。
    end
-- ↑ 锁定判定块结束。

    local olditem = self.activeitem
-- ★ 备份旧的手上物品。
-- ★★★ `self.itemslots[slot] = nil` —— 直接摘除，不走 RemoveItem。
-- ★★ 为什么可以直接置 nil？因为：
--   · 这是「移动到手上」不是「丢弃」，不需要 RemoveFromOwner；
--   · owner 字段保持不变（物品仍属于该实体）；
--   · 不需要触发 OnRemoved（那是「离开 owner」才要的）。
-- ★★★ 这就是「同一实体在两个槽位」的合法实现方式。
-- ★★ 与 1407 行 RemoveItem 的处置**完全相同** —— 都是直接置 nil。
--   ⇒ 槽位摘除永远是「置 nil」，不做数组压缩。
    self.itemslots[slot] = nil
-- ↑ 直接置 nil 摘除（不做数组压缩）。
-- ★★★ PushEvent("itemlose", { slot = slot, prev_item = newitem }) ——
-- ★★ ★ 这是**槽位变化的联机通知点**！
--   inventory_replica.lua:24 监听 itemlose →
--     `self.classified:SetSlotItem(data.slot)`（**不传 item** = 清空该槽）。
--   ⇒ ★★★ 这就是任务提到的「槽位变化如何反映到客户端」的答案之一：
--     本文件 PushEvent → replica 转 netvar → classified → 客户端 UI。
-- ★★ data 里带 prev_item 是给**本地监听者**用的（客户端要播音效），
--   classified 不传它（只传 slot）。
-- ★ 对照 1151 行的 itemget：`{ item = inst, slot = slot, src_pos = src_pos }`。
--   ⇒ itemget 传 item（设置槽），itemlose 不传（清空槽）。
    self.inst:PushEvent("itemlose", { slot = slot, prev_item = newitem })
-- ★★★ itemlose 事件 = 槽位清空的通知（联机同步点）。

-- ★★★ 摘除（直接置 nil，不走 RemoveItem）。
-- ★ self:SetActiveItem(newitem) —— 设为手上物品。
-- ★ SetActiveItem（1250 行）会 PushEvent("newactiveitem")，
--   inventory_replica.lua:22 监听它 → SetActiveItem(data.item)。
-- ★★ 于是「拿物品到手上」在客户端的完整同步是**两个事件**：
--   itemlose（旧槽清空）+ newactiveitem（新手上物品）。
    self:SetActiveItem(newitem)
-- ↑ SetActiveItem 触发 newactiveitem。

-- ↑ 空行（事件在 559 行已发）。
    if olditem ~= nil then
-- ★ 有旧东西才处理。
-- ★★★ `self:GiveItem(olditem, slot)` —— 旧物品回到**同一个槽位**。
-- ★★★ ★ 这实现了「交换」的语义：手上↔槽位的原子交换。
--   若 GiveItem 失败（槽位被抢/锁定），会走 1171 行的兜底。
-- ★★ 注意传了 slot（指定槽），所以 1086-1089 行会走
--   can_use_suggested_slot 分支，尝试精确放回原位。
-- ★ 若原槽的锁定状态变了，GiveItem 会选新位置。
-- ★★★ 这就是「拖拽交换」在背包里的实现。
        self:GiveItem(olditem, slot)
-- ★★★ 旧物回到同一槽位（交换语义）。
    end
-- ↑ if 块结束。

    return self.activeitem
-- ★★ return self.activeitem。
end
-- ↑ SelectActiveItemFromSlot 结束。

-- ★★ ReturnActiveItem —— 「把手上的东西放回背包」。
-- ★★ 两条路径（575 行分叉）：
--   · stack_mod 且是堆叠 → 只放回 1 个（Get 一个出来），剩余留手上；
--   · 否则 → 整个放回，手上清空。
-- ★★★ 每条路径都有失败兜底：DropItem（577/582 行）。
--   ⇒ 「背包满时点格子」= 把东西丢在地上。这符合玩家预期。
-- ★★ 注意 stack_mod 路径下，activeitem **不会**被清空（577 行只 GiveItem）。
--   因为手上还留着 N-1 个。只有非 stack_mod 路径才 SetActiveItem(nil)。
function Inventory:ReturnActiveItem(slot, stack_mod)
-- ↑ ReturnActiveItem 结束。
    if self.activeitem == nil then
-- ★★ 手上没东西 → 直接返回。
        return
-- ↑ 早退。
    end
-- ↑ 空值判定块结束。

-- ★★★ `if stack_mod and stackable ~= nil and IsStack()` —— 只放回 1 个。
-- ★★ 三个条件：stack_mod 为真 + 有 stackable + 是堆叠（非单个）。
-- ★ 576 行 Get() 取出 1 个 —— 返回的是**新实体**。
-- ★★ ★ 注意：原 activeitem **不受影响**（stacksize 不变）。
--   ⇒ 「shift+点击格子」= 从手上的一摞里分 1 个到槽位。
-- ★ 这是标准的「拆分堆叠」交互。
    if stack_mod and self.activeitem.components.stackable ~= nil and self.activeitem.components.stackable:IsStack() then
-- ↑ 「只放回 1 个」路径。
        local item = self.activeitem.components.stackable:Get()
-- ★★ Get() 取出 1 个（新实体）；★ 原 activeitem 不受影响。
-- ★★ `if not self:GiveItem(item, slot) then self:DropItem(item)` ——
--   ★★★ 失败兜底：**丢到地上**而不是静默消失。
-- ★★ 为什么可以丢地上？因为这个 item 是从 Get() 新建的实体，
--   即使 GiveItem 失败它也不会消失。
-- ★ ★ 但注意：这会造成**物品散落在地上**（若背包满）。
--   玩家的东西不会消失（重要保证），但会掉在地上一地。
        if not self:GiveItem(item, slot) then
-- ↑ GiveItem 失败则丢地上。
            self:DropItem(item)
-- ★★ GiveItem 失败 → 丢地上（★ 东西不会消失）。
        end
-- ↑ if 块结束。
    else
-- ★ else 分支：整件放回。
        if not self:GiveItem(self.activeitem, slot) then
-- ★ GiveItem（★ 指定槽位）。
            self:DropItem(self.activeitem)
-- ★★★ 失败兜底：丢地上。
        end
-- ↑ if 块结束。
        self:SetActiveItem(nil)
-- ★★★ SetActiveItem(nil) —— 只有非 stack_mod 路径才清空。
    end
-- ↑ else 块结束。
end
-- ↑ ReturnActiveItem 结束。

-- 【§七】GetNumSlots —— 背包格数（客户端 197 行同款）。
-- ★ 纯查询。★ 72 行 makereadonly 保证客户端改不了。
function Inventory:GetNumSlots()
-- ↑ GetNumSlots 结束。
    return self.maxslots
-- ★ return maxslots（★ 客户端不可改，72 行 makereadonly）。
end
-- ↑ GetNumSlots 结束。

-- ★★ GetItemSlot —— 「这件物品在第几格」。
-- ★★★ 返回**整数槽号**或 nil（不在 itemslots 里）。
-- ★★ ★ 重要局限：**只查 itemslots，不查 equipslots 和 activeitem**！
--   ⇒ 一件装备着的物品，GetItemSlot 返回 nil。
-- ★ 这是 1286-1296 行 Equip 的逻辑基础：「记录它原来在哪一格」。
-- ★★ 复杂度 O(maxslots)，≤ 20 次比较。
-- ★ 对比 506 行的 IsItemEquipped（查装备槽），两者互补。
function Inventory:GetItemSlot(item)
-- ↑ GetItemSlot 结束（只查 itemslots）。
    for k,v in pairs(self.itemslots) do
-- ★★ 反向查询：遍历 itemslots 找匹配。
        if item == v then
-- ★ 找到了？
            return k
-- ★★ return 槽号（★ 找不到返回 nil）。
        end
-- ↑ if 块结束。
    end
-- ↑ 遍历结束。
end
-- ↑ GetItemSlot 结束（★ 不查装备槽/手上）。

-- ★★ CheckItem —— 局部辅助函数，判定「item 是否等于 target（或在其容器内）」。
-- ★★★ 三段条件：
--   ① target 非 nil；
--   ② item == target（直接相等）；
--   ③ checkcontainer 为真 且 target 有 container 组件 且容器装着 item。
-- ★★ ★ checkcontainer 参数的含义：
--   true  → 「item 在 target 里（直接或在容器中）」算持有；
--   false → 只认「item 就是 target 本身」。
-- ★★ 设计用途：「我是否持有 X 木材」—— 若 X 在我背包里的箱子里，
--   算不算持有？checkcontainer=true 就算。
local function CheckItem(item, target, checkcontainer)
-- ↑ CheckItem 局部函数结束。
    return target ~= nil
-- ★★★ 条件①：target 必须非 nil。
        and (item == target
-- ★ 条件②：item 就是 target 本身。
            or (checkcontainer and
-- ★★★ 条件③：checkcontainer 开启。
				target.components.container and
-- ★ target 有 container 组件。
				target.components.container:IsHolding(item, checkcontainer)))
-- ★★★ 递归查容器的持有关系（★ 容器可再嵌套）。
end
-- ↑ CheckItem 结束。

-- ★★ IsHolding —— 「我是否持有这个物品」。
-- ★★★ 三个来源（顺序）：
--   ① activeitem（609 行）；
--   ② 如果 item 是装备 → 查对应装备槽（610-612 行）；
--   ③ 遍历 itemslots（616 行）。
-- ★★ ★ 注意第②步的巧妙：只查 item 自己声明的 equipslot，
--   而不是遍历所有装备槽！⇒ 复杂度从 O(装备槽数) 降到 O(1)。
-- ★★★ ★★ 注意：**没有查 overflow（背包本体）**！
--   ⇒ 「背包里装着的东西算不算持有」——通过 overflow 间接算，
--     但 overflow 里的物品**不算**在这个 IsHolding 里。
-- ★★ ★★ 与 634 行的 FindItem（含 overflow）语义不同！
--   ⇒ ★★ 同一个概念「持有」，IsHolding / FindItem / Has 三个函数
--     的搜索范围**各不相同**。这是本文件最大的语义不一致点。
--   ★ 矩阵见 638 行的详细对照表。
function Inventory:IsHolding(item, checkcontainer)
-- ↑ IsHolding 结束（★ 不含 overflow）。
    if CheckItem(item, self.activeitem, checkcontainer) or
-- ★★★ 三来源判定的起点：手上 或 对应装备槽。
		(	item.components.equippable and
-- ★ item 是装备（才有 equipslot 可查）。
			CheckItem(item, self:GetEquippedItem(item.components.equippable.equipslot), checkcontainer)
-- ★★ ★ O(1) 查该物品自己声明的装备槽（而非遍历 4 个）。
		)
-- ↑ or 表达式结束。
	then
-- ↑ if 的 then 起始。
        return true
-- ★ 命中 → true。
    end
-- ↑ or 块结束。
    for k, v in pairs(self.itemslots) do
-- ★★ 遍历普通槽。
        if CheckItem(item, v, checkcontainer) then
-- ★ 命中判断（★ 用 CheckItem 而非 ==，故含容器递归）。
            return true
-- ★★ 命中 → true。
        end
-- ↑ if 块结束。
    end
-- ↑ 遍历结束。
end
-- ↑ IsHolding 结束（★ 隐式返回 nil = false）。

-- ★★ FindItem —— 「找出第一个满足 fn 的物品」。
-- ★★★ 搜索范围（623-635 行）：
--   ① itemslots（624 行）；
--   ② activeitem（630 行）；
--   ③ **overflow**（634-635 行，递归调用 overflow:FindItem）。
-- ★★ ★ 与 IsHolding 的差异：FindItem **包含** overflow！
--   ⇒ ★ 这就是三种语义不一致的具体体现（见 608 行注释）。
-- ★★★ ★ 与 FindItems 的差异：FindItem **不含** equipslots！
--   ⇒ 找「我穿着的装备」不能用 FindItem，要用 FindItems。
-- ★★ 为什么 itemslots 在 activeitem 之前？
--   ⇒ 顺序即优先级：**优先从背包格找，再看手上**。
--   合理：手上东西是「临时持有」，背包才是「真正拥有」。
function Inventory:FindItem(fn)
-- ↑ FindItem 结束（★ 不含 equipslots，含 overflow）。
    for k,v in pairs(self.itemslots) do
-- ★★ 第一步：遍历普通槽。
        if fn(v) then
-- ★ 谓词命中？
            return v
-- ★★ 立即返回第一个命中（★ 顺序无保证：pairs）。
        end
-- ↑ if 块结束。
    end
-- ↑ 普通槽遍历结束。

    if self.activeitem and fn(self.activeitem) then
-- ★★ 第二步：手上的东西。
        return self.activeitem
-- ★ 命中即返回。
    end
-- ↑ if 块结束。

    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow（★ 含背包本体，与 IsHolding 不同）。
    return overflow ~= nil and overflow:FindItem(fn) or nil
-- ★★★ 递归委托（★ 若无 overflow 则返回 nil/false）。
end
-- ↑ FindItem 结束。

-- ★★ FindItems —— FindItem 的批量版本（返回数组）。
-- ★★★ 搜索范围比 FindItem **多一个**：
--   ① itemslots（641）；② **equipslots**（647）；③ activeitem（653）；
--   ④ overflow（657）。
-- ★★★ ★★ 五函数的搜索范围矩阵（★★★ 移植时必看）：
--              itemslots | equipslots | activeitem | overflow
--     IsHolding      ✓         ✓(直接)     ✓           ✗
--     FindItem       ✓         ✗           ✓           ✓
--     FindItems      ✓         ✓           ✓           ✓
--     Has            ✓         ✗           ✓           ✓
--     ForEachItem    ✓         ✓           ✓           ✓
--   ⇒ ★ 这是本文件最大的语义不一致点：选错函数会导致「找不到物品」。
--     例如「删除我穿的所有上衣」必须用 FindItems/ForEachItem，
--     用 FindItem 会漏掉 equipslots 里的。
-- ★★ 657-661 行的递归：overflow:FindItems 也要拼接结果。
function Inventory:FindItems(fn)
-- ↑ FindItems 结束（★ 含 equipslots + overflow）。
    local items = {}
-- ★ 结果数组初始化。

    for k,v in pairs(self.itemslots) do
-- ★★ 第一段：普通槽（★ 与 FindItem 同）。
        if fn(v) then
-- ★ 谓词命中？
            table.insert(items, v)
-- ★ 加入结果。
        end
-- ↑ if 块结束。
    end
-- ↑ 第一段结束。

    for k,v in pairs(self.equipslots) do
-- ★★ ★★ 第二段：装备槽（★ FindItem 没有这一段！）。
        if fn(v) then
-- ★ 谓词命中？
            table.insert(items, v)
-- ★ 加入结果。
        end
-- ↑ if 块结束。
    end
-- ↑ 第二段结束。

    if self.activeitem and fn(self.activeitem) then
-- ★ 第三段：手上。
        table.insert(items, self.activeitem)
-- ★ 加入结果。
    end
-- ↑ if 块结束。

    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow。
    if overflow ~= nil then
-- ★ 有 overflow 才递归。
        for k, v in pairs(overflow:FindItems(fn)) do
-- ★★ 遍历 overflow 的结果。
            table.insert(items, v)
-- ★ 逐个加入。
        end
-- ↑ 遍历结束。
    end
-- ↑ if 块结束。

    return items
-- ★★ return items（数组）。
end
-- ↑ FindItems 结束（★ 范围最全的查找之一）。

-- ★★ ForEachItem —— 「对每件物品做点什么」。
-- ★★★ 搜索范围最全（与 FindItems 相同）：itemslots + equipslots +
--   activeitem + overflow 递归。
-- ★★ ★ 与 FindItems 的差异：**不返回数组**（省内存），
--   而是直接回调 fn。适用于「批量修改」场景（如全部染黄）。
-- ★★ ForEachItem(fn, ...) 的 `...` 参数转发 —— 变参透传给 fn。
--   这是「避免闭包捕获」的写法（Klei 代码风格）。
-- ★★ ⚠ 回调里若修改了物品列表（如 RemoveItem），遍历会出问题。
--   679 行 overflow:ForEachItem(fn, ...) 也是递归。
function Inventory:ForEachItem(fn, ...)
-- ↑ ForEachItem 结束（范围最全）。
    for k,v in pairs(self.itemslots) do
-- ★★ 第一段：普通槽。
        fn(v, ...)
-- ★ 直接回调（★ 不返回值，省内存）。
    end
-- ↑ 第一段结束。

    for k,v in pairs(self.equipslots) do
-- ★ 第二段：装备槽。
		fn(v, ...)
-- ★ 回调。
    end
-- ↑ 第二段结束。

    if self.activeitem then
-- ★ 手上有东西才回调。
		fn(self.activeitem, ...)
-- ★ 回调。
    end
-- ↑ if 块结束。

    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow。
    if overflow ~= nil then
-- ★ 有则递归。
        overflow:ForEachItem(fn, ...)
-- ★★ 委托（★ 变参 ... 一并透传）。
    end
-- ↑ if 块结束。
end
-- ↑ ForEachItem 结束。

-- ★★ ForEachWetableItem —— 「对每件**可淋湿**的物品做点什么」。
-- ★★★ ★★ 与 ForEachItem 的唯一差异：**不递归 overflow**！
-- ★ 原注释保留："Items that can get wet are inventory, equipment,
--   and activeitem." —— 三张表，无递归。
-- ★★ ★ 原因：会淋湿的物品是「身上/手上的」，
--   而 overflow（背包）里的东西不会被淋湿。
-- ★★ 这个差异说明「淋湿」是**装备相关**而非「持有相关**的概念。
function Inventory:ForEachWetableItem(fn, ...)
-- ↑ ForEachWetableItem 结束（★ 不递归 overflow）。
    -- Items that can get wet are inventory, equipment, and activeitem.
-- ↑ 原英文注释保留（三张表，无递归）。
    for k,v in pairs(self.itemslots) do
-- ★ 普通槽段。
        fn(v, ...)
-- ★ 回调。
    end
-- ↑ 第一段结束。

    for k,v in pairs(self.equipslots) do
-- ★ 装备槽段。
		fn(v, ...)
-- ★ 回调。
    end
-- ↑ 第二段结束。

    if self.activeitem then
-- ★ 手上段。
		fn(self.activeitem, ...)
-- ★ 回调。
    end
-- ↑ if 块结束。
end
-- ★★ ↑ 不递归 overflow（★ 与 ForEachItem 的唯一差异）。

-- ★★ ForEachEquipment —— 只遍历 equipslots。
-- ★ 最小范围的遍历。最常用（如「所有装备掉耐久」）。
function Inventory:ForEachEquipment(fn, ...)
-- ↑ ForEachEquipment 结束。
    for k,v in pairs(self.equipslots) do
-- ★ 装备槽遍历。
        fn(v, ...)
-- ★ 回调。
    end
-- ↑ 遍历结束。
end

-- ★★ ForEachItemSlot —— 只遍历 itemslots。
-- ★ ★ 与 99 行 NumItems 的范围完全一致（都是普通槽，不含装备/手上）。
function Inventory:ForEachItemSlot(fn, ...)
-- ↑ ForEachItemSlot 结束。
    for k,v in pairs(self.itemslots) do
-- ★ 普通槽遍历。
        fn(v, ...)
-- ★ 回调。
    end
-- ↑ 遍历结束。
end

-- ★★ RemoveItemBySlot —— 「把第 k 格的物品整个取出」。
-- ★★★ 与 RemoveItem 的关系：
--   · RemoveItemBySlot(slot, ...) —— 按**槽号**取，wholestack 默认为 **true**；
--   · RemoveItem(item, wholestack, ...) —— 按**实体**取，wholestack 由调用方决定。
-- ★★★ ★ `RemoveItem(item, true, nil, keepoverstacked)` 的三个参数：
--   · true = wholestack（整摞取出，不拆分成单个）；
--   · nil = checkallcontainers（不搜索打开的容器）；
--   · keepoverstacked 透传。
-- ★★ ★ 整摞取出是「按槽操作」的语义（槽里就是一摞，全拿走）。
--   而 RemoveItem 按实体操作时可能只取一个（1397 行）。
-- ★★ 注意：取出后**不销毁**实体，只是从背包移除。
--   调用方决定是 GiveItem（放别处）还是 :Remove()（销毁）。
-- ★ 714 行的 `if slot and self.itemslots[slot]` —— 双重保护。
--   slot 为 nil 或该槽为空时，返回 nil（不报错）。
function Inventory:RemoveItemBySlot(slot, keepoverstacked)
-- ↑ RemoveItemBySlot 结束（wholestack 默认 true）。
    if slot and self.itemslots[slot] then
-- ★★ 双重守卫：槽号有效且该槽有东西。
        local item = self.itemslots[slot]
-- ★ 取物品（用于返回）。
		self:RemoveItem(item, true, nil, keepoverstacked)
-- ★★★ RemoveItem(整摞) —— ★ wholestack=true 是「按槽操作」的语义。
        return item
-- ★★ return item（★ 找不到则隐式返回 nil）。
    end
-- ↑ if 块结束。
end
-- ↑ RemoveItemBySlot 结束。

-- 【§七】DropItem —— 「把物品丢到地上」。
-- ★★★ 本文件唯一的「物品离开背包」出口（除了 RemoveItem+Remove）。
-- ★★★ 五步流程（721-753 行）：
--   ① 722-731 行：合法性检查（nil / 无 inventoryitem / 锁定物品）；
--   ② 733 行：RemoveFromOwner —— 真正脱离 owner（会触发 OnRemoved）；
--   ③ 736-740 行：设置掉落位置（pos 参数或 owner 的位置）；
--   ④ 742-744 行：OnDropped（切到掉落状态，如熄灭火把）；
--   ⑤ 749 行：PushEvent("dropitem") 通知 UI。
-- ★★ ★ 733 行的 `or item` 是**兜底**：若 RemoveFromOwner 返回 nil，
--   就把传入的 item 当作已掉落。
--   ★ 这与其他函数的「找不到也返回」风格一致（见 1453 行）。
function Inventory:DropItem(item, wholestack, randomdir, pos, keepoverstacked)
-- ↑ DropItem 函数头（五步流程）。
-- ★★ `if item == nil or item.components.inventoryitem == nil then return` ——
--   ★ 双重检查：item 非空 + 是「可放入物品栏的东西」。
-- ★★ 为什么检查 inventoryitem 组件？因为不是所有实体都能被拿起
--   （如地面上的树、火焰）。这是「物品资格」的判定。
    if item == nil or item.components.inventoryitem == nil then
-- ↑ 资格检查。
        return
-- ★★ 无物品资格 → 静默返回（★ 注意 723 行在 if 体内）。
-- ★★★ islockedinslot 的第二道检查（见 713 行的第一道）。
-- ★★ 条件：物品锁定 **且**（要整摞丢 **或** 它不是堆叠）。
-- ★★★ 语义拆解：
--   · wholestack（整摞丢）→ 拒绝；
--   · 非堆叠（单个）→ 拒绝；
--   · 是堆叠且只丢一个（wholestack=false）→ 允许。
-- ★★★ ★ 推理：锁定的「一摞」不能被整摞丢掉（丢走了道具就没了），
--   但可以从里面「抽走一个」（这个动作不算破坏道具）。
-- ★ 这是 islockedinslot 的完整语义（另见 241 行的合并例外）。
	elseif item.components.inventoryitem.islockedinslot and
-- ↑ islockedinslot 的丢弃限制。
		(	wholestack or
-- ★★★ 锁定的「整摞」不可丢。
			not (item.components.stackable and item.components.stackable:IsStack())
-- ★ 锁定的「非堆叠单件」不可丢。
		)
-- ★★ 续行收尾（与 724 行的 and 组合）。
	then
-- ↑ if 的 then 起始。
		assert(BRANCH ~= "dev")
-- ★★ assert（dev 版崩，见 L6）。
		return
-- ★ 生产环境静默返回。
    end
-- ↑ 判定块结束。

-- ★★★ `local dropped = item.components.inventoryitem:RemoveFromOwner(
--   wholestack, keepoverstacked) or item` ——
-- ★★ ★★★ 这是本文件**最需要理解的一行**：
--   RemoveFromOwner 返回的是「实际脱离背包的那个实体」，
--   当 wholestack=false 且 item 是堆叠时，
--   它返回的是**新拆出来的单个实体**（inventoryitem.lua:468 的行为），
--   而原实体（剩下的 N-1 个）留在背包里。
-- ★★★ `or item` 的兜底含义：若 RemoveFromOwner 返回 nil
--   （如物品本来就不在背包里），则把 item 本身当作「掉落物」处理。
--   ★ 这让 DropItem 可以用在「物品在手上」的场景（733 行调用时，
--     item 可能是 activeitem 而不在 itemslots 里）。
-- ★★ 后续代码用的是 `dropped`（不是 `item`）——
--   ★★★ 这是本行最重要的一课：**丢弃堆叠的一部分时，
--     真正落地的是新实体，不是传入的那个**。
	local dropped = item.components.inventoryitem:RemoveFromOwner(wholestack, keepoverstacked) or item
-- ★★★ RemoveFromOwner + `or item` 兜底（最关键一行）。

-- ↑ 空行（733 行的 RemoveFromOwner 是关键）。
-- ★★ `if dropped ~= nil then` —— 虽然 733 行有 or 兜底，
--   这里仍检查 —— 因为 733 行的兜底只在 RemoveFromOwner 返回 nil 时生效。
-- ★ 双重防御，Klei 代码的常见风格。
    if dropped ~= nil then
-- ↑ 双重防御。
-- ★★ 位置设置：优先用 pos 参数（736 行），否则用 owner 的当前位置（739 行）。
-- ★ pos 是 **Vector3 对象**（不是坐标三元组）：`pos:Get()` 取坐标。
-- ★★★ pos 参数的来源：
--   · 2428 行 DropItemFromInvTile 传 GetRemotePredictPositionExternal()；
--     客户端预测的掉落位置（避免联机时物品瞬移回服务端位置）。
-- ★★ 这是**客户端预测**在物品掉落上的应用 —— 见 2428 行注释。
        if pos ~= nil then
-- ↑ 位置设置分叉。
            dropped.Transform:SetPosition(pos:Get())
-- ★★ pos 参数路径：pos:Get() 取坐标。
        else
-- ↑ if pos 块结束。
-- ★ else 分支：用 owner 的世界坐标。
-- ★★★ `self.inst.Transform:GetWorldPosition()` ——
--   ★ 用 Transform 而不是 inst:GetPosition()：
--     Transform 组件是物理世界里的真实位置（考虑动画偏移），
--     GetPosition 是实体原点的位置。
-- ★⇒ 物品会掉在角色的**脚边**而非身体中心。细节但重要。
            dropped.Transform:SetPosition(self.inst.Transform:GetWorldPosition())
-- ↑ 用 Transform 拿世界坐标（脚边而非身体中心）。
        end
-- ↑ else 块结束。

-- ★★ `if dropped.components.inventoryitem ~= nil then` ——
--   又一次检查（733 行的兜底可能让 dropped 是无组件的实体）。
-- ★ OnDropped(randomdir) —— 「掉落时」的钩子：
--   · randomdir 非 nil → 随机方向弹开（有初速度）；
--   · randomdir 为 nil → 原地掉落。
-- ★★★ 典型实现：火把掉落时熄灭、海水中的物品立即销毁。
        if dropped.components.inventoryitem ~= nil then
-- ↑ OnDropped 钩子。
            dropped.components.inventoryitem:OnDropped(randomdir)
-- ★★★ OnDropped 钩子（★ randomdir 决定是否有弹开速度）。
        end
-- ↑ if 块结束。

        dropped.prevcontainer = nil
-- ★★★ 清空位置记忆（★ 落地后不再「记得」原槽）。
        dropped.prevslot = nil
-- ★★★ 同上，清容器记忆。

-- ↑ 空行。
-- ★★★ PushEvent("dropitem", { item = dropped }) ——
-- ★★ UI 同步点：客户端播放「物品掉到地上」的动画/音效。
-- ★★ 注意 data 里传的是 `dropped`（可能不是原 item）——
--   正确性：客户端应该显示**真正落地的那一个**。
-- ★★ 这是 733 行 `or item` 兜底设计的**必要配套**：
--   若事件里传原 item，客户端会显示错。
        self.inst:PushEvent("dropitem", { item = dropped })
-- ★★★ dropitem 事件（传真正落地的实体）。
    end
-- ↑ if dropped 块结束。

    return dropped
-- ★★ return dropped（★ 可能是新实体，见 733 行）。
end
-- ↑ DropItem 结束。

-- ★ ForceNoInsulated —— 「强制不绝缘」。
-- ★★★ 与 equippable.lua 的 insulated 是**反向**的强制开关。
-- ★ 760 行：`if self.force_no_insulation then return false` ——
--   强制优先级**最高**，压过任何装备的绝缘效果。
-- ★★★ 用途：某些 buff/debuff 强制剥夺绝缘能力（如「潮湿」状态）。
function Inventory:ForceNoInsulated(force) -- electricity, not temperature
-- ↑ ForceNoInsulated 结束。
    self.force_no_insulation = force or nil
-- ★★ force or nil —— 用 nil 而非 false 表示「未强制」。
end
-- ↑ ForceNoInsulated 结束。

-- ★★ IsInsulated —— 「是否绝缘（防触电）」。
-- ★★★ 判定顺序（优先级从高到低）：
--   ① 760 行 force_no_insulation → 强制 false；
--   ② 764-768 行遍历装备，任一件 IsInsulated → true；
--   ③ 770 行 isexternallyinsulated（外部 SourceModifierList）→ 聚合值。
-- ★★★ ★ 第②步是**短路返回**（任一件即可），不是累加。
--   ⇒ 绝缘是**布尔或**，不是数值加法。与防水（2714 行）不同！
-- ★ 对比 GetWaterproofness（2714 行）：那里是**累加** waterproofness 值。
-- ★★ 两种汇总策略并存的原因：
--   · 绝缘是定性的（有/无），累加无意义；
--   · 防水是定量的（防水度百分比），累加有意义（1.0 = 完全防水）。
-- ★★★ ★ 注意 765 行 `v and v.components.equippable:IsInsulated()`
--   直接索引 .components.equippable **没有 nil 检查**！
--   ⇒ 若某件装备没有 equippable 组件，这里会崩。
--   ⚠ 按设计能进 equipslots 的必然有 equippable，所以是「隐含契约」；
--     但与 370 行 IsWearingArmor（`v.components.armor ~= nil` 有检查）
--     风格不一致。同一文件内两种防御强度。
function Inventory:IsInsulated() -- from electricity, not temperature
-- ↑ IsInsulated 结束（三级判定，布尔或）。
    if self.force_no_insulation then
-- ★★ 强制开关优先（★ 压过所有装备的绝缘）。
        return false
-- ★ 强制返回 false（不绝缘）。
    end
-- ↑ 强制块结束。

-- ★★ 遍历装备查绝缘。短路：找到就 return true。
    for k,v in pairs(self.equipslots) do
-- ↑ 装备槽绝缘遍历。
        if v and v.components.equippable:IsInsulated() then
-- ★★ 遍历装备；★ 注意 .components.equippable 无 nil 检查（隐含契约）。
            return true
-- ★★★ 短路：任一件绝缘即整体绝缘（★ 布尔或，不累加）。
        end
-- ↑ if 块结束。
    end
-- ↑ 装备遍历结束。

-- ★★ `return self.isexternallyinsulated:Get()` ——
-- ★★ 最后一层：外部绝缘源（SourceModifierList 聚合）。
-- ★ 与 62 行的构造对应。这层是「装备之外的绝缘来源」
--   （如韦斯的物品提供全局绝缘、某些 buff）。
-- ★★★ 62 行初始化为 `SourceModifierList(inst, false, boolean)`，
--   即默认 false。所以这里返回 false（除非有外部源开启）。
    return self.isexternallyinsulated:Get()
-- ↑ 外部 SourceModifierList 层。
end
-- ★★ 兜底：外部 SourceModifierList 的聚合结果。

-- ↑ IsInsulated 结束（三级：强制 > 装备 > 外部）。
-- ★★ GetEquippedItem(eslot) —— 「这个装备槽里有什么」。
-- ★ 与 502 行 GetActiveItem 的区别：只查装备槽。
-- ★★ 是 1305-1320 行「重物互斥」逻辑的基础。
function Inventory:GetEquippedItem(eslot)
-- ↑ GetEquippedItem 结束。
    return self.equipslots[eslot]
-- ★ return equipslots[eslot]（★ 键是字符串槽名）。
end
-- ↑ GetEquippedItem 结束。

-- ★★ GetItemInSlot(slot) —— 「第 slot 槽有什么」。
-- ★★★ O(1) 直接索引（数组）。槽号为 nil 时返回 nil。
-- ★ ★ 对比 GetItemSlot（592 行）反向查询（O(n)）。
--   两者构成「正查/反查」对。
function Inventory:GetItemInSlot(slot)
-- ↑ GetItemInSlot 结束（O(1)）。
    return self.itemslots[slot]
-- ★ return itemslots[slot]（★ O(1) 数组索引）。
end
-- ↑ GetItemInSlot 结束。

-- ★★ GetFirstItemInAnySlot —— 「任何一格里的第一件东西」。
-- ★★★ 用 1..maxslots 的**有序**遍历（而非 pairs）。
-- ★★ ★ 为什么要有序？因为要「第一格」——pairs 无序无法保证。
-- ★ 用途：某些需要「随便拿一件东西」的逻辑（自动合成、丢弃）。
-- ★ 复杂度 O(maxslots)，最坏情况扫全表。
function Inventory:GetFirstItemInAnySlot()
-- ↑ GetFirstItemInAnySlot 结束（有序遍历）。
    for k = 1, self.maxslots do
-- ★★ 有序遍历（★ 为「第一格」必须有序，pairs 不行）。
        local item = self.itemslots[k]
-- ★ 取该槽物品。
        if item then
-- ★ 有东西？
            return item
-- ★★ return 第一件找到的。
        end
-- ↑ if 块结束。
    end
-- ↑ 遍历结束（全空则继续）。
    return nil
-- ★★ 遍历完都没有 → return nil。
end
-- ↑ GetFirstItemInAnySlot 结束。

-- ★★ IsFull —— 「背包是否已满」。
-- ★★★ 有序遍历 1..maxslots，找**任何一个空槽**。
-- ★★ ★ 注意：只看 itemslots，**不看** overflow（背包本体）、
--   不看 activeitem、不看 equipslots。
--   ⇒ 「背包满了」= 普通槽全满。即便背包本体还有空间，也算「满」。
--   这是**刻意的简化**（玩家认知里的「背包满了」就是这个意思）。
-- ★★ 陷阱：若 maxslots 为 0（某些非玩家实体），
--   循环不执行 → 直接 return true（恒满）。这是正确的。
-- ★ 对应客户端：inventory_replica.lua:378 IsFull（走 classified）。
function Inventory:IsFull()
-- ↑ IsFull 结束（★ 只看 itemslots）。
    for k = 1, self.maxslots do
-- ★★ IsFull：找任何一个空槽。
        if not self.itemslots[k] then
-- ★★ 找到空槽 → 不满（★ 立即返回）。
            return false
-- ↑ if 块结束。
        end
    end
-- ↑ 遍历结束（★ 无空槽 = 满）。

    return true
-- ★★ return true（全满）。
end
-- ↑ IsFull 结束（★ maxslots=0 时恒返回 true）。

-- 【§八】ValidateItemForOverflow —— 「这物品能进 overflow（背包）吗」。
-- ★★★ 四种判定（801-810 行）：
--   ① 无 inventoryitem 组件 → **返回 true**（放行！见 803 行注释）；
--   ② canonlygoinpocket → false（只能进口袋，不能进 overflow）；
--   ③ canonlygoinpocketorpocketcontainers → 特殊判定（807 行）；
--   ④ 其他 → true。
-- ★★★ ★ ① 的 `return true --should never happen, just return true XD`
--   是本文件最直白的「防御性放行」：明知道不该发生，但选择放行
--   而不是崩溃。作者自己都标了 XD。
-- ★★ ② 与 ③ 的区别：
--   · canonlygoinpocket = 「只能进口袋（玩家自己的物品栏）」；
--   · canonlygoinpocketorpocketcontainers = 「能进口袋或口袋里装的东西」。
-- ★★ 设计意图：某些关键物品不能被「丢进箱子里再拿出来」绕过限制。
local function ValidateItemForOverflow(item, overflow)
-- ↑ ValidateItemForOverflow 结束（★ 803 行是「明知不该发生却放行」）。
	if item.components.inventoryitem == nil then
-- ★★★ 无 inventoryitem 组件 → 放行（★ 原注释：should never happen, XD）。
		return true --should never happen, just return true XD
-- ↑ ★★ 作者自嘲的放行分支。
-- ★ canonlygoinpocket —— 「只能进口袋」。
-- ★★ 与 overflow 的关系：overflow 是**别人给的背包**，
--   而「口袋」= 玩家自己的 itemslots。
--   ⇒ 这个标记的物品即使玩家穿了背包，也不能进那个背包。
	elseif item.components.inventoryitem.canonlygoinpocket then
-- ↑ canonlygoinpocket 分支。
		return false
-- ★★ canonlygoinpocket → 拒绝。
-- ★★★ canonlygoinpocketorpocketcontainers —— 条件放行。
-- ★ 807 行：`overflow.inst.components.inventoryitem ~= nil and
--   overflow.inst.components.inventoryitem.canonlygoinpocket`
-- ★★★ ★ 语义：只有在「overflow 本身是个只能进口袋的物品」时才放行。
-- ★★★ 这是一条**递归性的限制链**：
--   「只能进口袋」的物品放进背包时，
--   只有当那个背包也是「只能进口袋」的物品时才允许。
--   ⇒ 类比：套娃。只能进口袋的东西，只能放进另一个只能进口袋的东西里。
-- ★★ ⚠ 但注意：overflow 通常是「背包」（有 container 组件），
--   而 canonlygoinpocket 的物品（如韦斯的钟表）没有 container 组件
--   ⇒ 这个条件几乎总是 false。⇒ ③ 与 ② 实际效果相近。
-- ★ 这可能是「为 mod 预留的钩子」而非实用功能。
	elseif item.components.inventoryitem.canonlygoinpocketorpocketcontainers then
-- ↑ 套娃式的 canonlygoinpocketorpocketcontainers 判定。
		return overflow.inst.components.inventoryitem ~= nil and overflow.inst.components.inventoryitem.canonlygoinpocket
-- ★★★ 套娃判定：overflow 本身也是「只能进口袋」的才放行。
	end
-- ↑ elseif 块结束。
	return true
-- ★★ 默认放行。
end
-- ↑ ValidateItemForOverflow 结束。

--Returns the slot, and the container where the slot is (self.itemslots, self.equipslots or self:GetOverflowContainer())
-- ↑ 原英文注释保留（返回 slot 与 container 两个值）。
-- 【§八】★★ GetNextAvailableSlot —— 「下一个可用槽在哪」。
-- ★★★★ 本文件**最核心的选位算法**。GiveItem 完全依赖它。
-- ★★★ 返回 `(slot, container)` 二元组：
--   · slot = 槽位号（数字）；
--   · container = 该槽所属的容器组件（itemslots/equipslots/overflow）。
-- ★★★ ★ 搜索顺序（八级，对应 HEADER_EXTRA 第 4 条）：
--   ① 装备槽里可合并的 equipstack 堆叠（839 行）；
--   ② 普通槽里可合并的堆叠（846 行）；
--   ③ overflow 里可合并的堆叠（858 行）；
--   ④ 专用容器里可合并的堆叠（871 行）；
--   ⑤ overflow 的空位（885 行，需 prioritize_overflow）；
--   ⑥ 专用容器的空位（893 行）；
--   ⑦ 普通槽的空位（903 行）；
--   ⑧ 全失败 → (nil, self.itemslots)（908 行）。
-- ★★★★★ ★★ 核心不变式：**永远先尝试合并已有堆叠**（①-④），
--   最后才找空位（⑤-⑦）。
--   ⇒ 这就是「20 个石头只占 1 格」的根本原因。
-- ★★ 若找不到，返回 `(nil, self.itemslots)`（908 行）。
--   注意：**第二个返回值仍是 itemslots**（不是 nil）。
--   ⇒ 调用方（如 1095 行）会用 container == self.itemslots 判断。
function Inventory:GetNextAvailableSlot(item)
-- ★★★ GetNextAvailableSlot 函数头（八级搜索）。
-- ★★ `local overflow = self:GetOverflowContainer()` —— 取背包本体。
-- ★★ 注意这里**没有**检查 self.ignoreoverflow ——
--   GetOverflowContainer 内部（1460 行）会检查。
    local overflow = self:GetOverflowContainer()
-- ↑ 取 overflow。
-- ★ prioritize_overflow —— 「优先放 overflow」。
-- ★★★ `overflow:ShouldPrioritizeContainer(item)` ——
--   overflow 组件自己决定「这件物品该优先进背包」。
-- ★★★ 典型：弹药袋这类专用容器会被指定为优先。
-- ★★ 效果（848/852 行）：若为 true，找到可合并的普通槽后
--   **不立即返回**，而是暂存起来（inv_slot/inv_pref），
--   继续看 overflow 有没有更好的位置。
-- ★★★ 这就是「优先」的实现：**先不急着定，继续找**。
	local prioritize_overflow = overflow ~= nil and overflow:ShouldPrioritizeContainer(item)
-- ↑ prioritize_overflow 判定。
-- ★★ useoverflow —— 「这件物品允许进 overflow 吗」。
-- ★ ValidateItemForOverflow（801 行）的结果。
-- ★ 与 815 的区别：
--   · prioritize_overflow = 「overflow 想要它」；
--   · useoverflow = 「overflow 有资格收它」。
-- ★ 两个都要 true 才可能在 overflow 里放置。
	local useoverflow = overflow ~= nil and ValidateItemForOverflow(item, overflow)
-- ↑ useoverflow 资格判定。

-- ↑ 原注释保留（specialized containers）。
	--specialized containers
-- ★ 空行。
-- ★★ 专用容器（specialized）的获取与预排序。
-- ★★ 820-835 行把「想要这件物品的专用容器」重排到数组**前面**：
--   825 行筛出 ShouldPrioritizeContainer 为真的；
--   828-829 行用双指针 j 把它们移到前端（稳定重排）；
--   832 行若一个都没有则置 nil（避免后续空循环）。
-- ★★★ 这是个**手写的稳定 partition**，不是 table.sort。
-- ★★ 为什么要重排？因为 870 行按 ipairs 遍历，
--   顺序 = 优先级。★ 专用容器的**顺序**会影响物品落在哪个容器。
	local specialized = self:GetSpecializedContainers()
-- ↑ 专用容器重排起点。
-- ★ `if specialized then` —— ★ 注意：**空表在 Lua 里是 truthy**！
-- ★★★ 所以 GetSpecializedContainers 返回空表时也会进入本分支。
-- ★★ 这依赖 832-834 行把空表转成 nil 才能让后续的
--   `specialized and ...` 判定正确。
-- ★★ ⚠ 脆弱点：若删掉 832-834 行的空表转 nil，
--   820 行的 if 会进（空表 truthy），然后 870 的 ipairs 空转，
--     功能上不出错但多几次无用的 table 操作。
	if specialized then
-- ↑ 注意空表是 truthy。
		local j = 1
-- ★★★ 双指针 j —— 原地稳定重排的写指针。
		for i = 1, #specialized do
-- ★ 遍历原数组（读指针 i）。
			local spoverflow = specialized[i]
-- ★ 取当前候选容器。
-- ★★★ `specialized[i] = nil` —— **就地压缩**数组。
-- ★★ 这是「过滤数组」的经典 Lua 技巧：用双指针原地过滤。
-- ★★★ ★ 关键安全前提：GetSpecializedContainers（1481 行）
--   返回的是**新表**（`ret = ret or {}` + table.insert），
--   所以这里修改不会污染任何持久状态。
-- ★★ 若该函数改成返回共享表，这里就会**破坏状态**。
--   ⇒ ★ 这是一个隐式但重要的耦合，值得在注释里记下。
			specialized[i] = nil
-- ↑ 就地压缩（★ 依赖「新表」前提）。
			if spoverflow:ShouldPrioritizeContainer(item) and
-- ★★ 双重条件：它想要这件物品 且 物品有资格进去。
				ValidateItemForOverflow(item, spoverflow)
-- ★ 续行（资格判定）。
			then
-- ↑ then 起始。
				specialized[j] = spoverflow
-- ★★★ 写到 j 位置（★ j <= i，故为原地压缩，不覆盖未读数据）。
				j = j + 1
-- ★ 写指针前移。
			end
-- ↑ if 块结束。
		end
-- ↑ 重排循环结束。
-- ★★ 空表转 nil —— 让后续的 `specialized and` 判定语义正确。
-- ★★ `#specialized <= 0` 用的是长度运算符 #（等价于 #t == 0）。
-- ★★★ ★ 这是**唯一**让 820 行的 `if specialized then` 逻辑正确的地方。
-- ★ 若删掉，848 行的 `or specialized` 会是**真值**，
--   导致 848-853 走「暂存」分支而非「立即返回」，**行为改变**。
		if #specialized <= 0 then
-- ↑ 空表转 nil（维持后续语义正确）。
			specialized = nil
-- ★★★ 一个候选都没有 → 置 nil（★ 关键：让后续 and 判定正确）。
		end
-- ↑ if #specialized <= 0 块结束。
	end
-- ↑ if specialized 块结束。

-- ★★★ 堆叠合并搜索 —— 第一级：装备槽。
-- ★★ `if item.components.stackable ~= nil then` ——
--   只有**可堆叠的物品**才需要找合并位置。
--   不可堆叠的物品直接跳到 884 行找空位。
-- ★★★ 这是一个大 if（837-882 行），把整个「堆叠合并」搜索包起来。
-- ★ 缩进是 tab/空格混用（Klei 源码风格），不影响语义。
    if item.components.stackable ~= nil then
-- ↑ 堆叠合并大 if 开始。
        --check for stacks that aren't full
-- ↑ 原英文注释保留（check for stacks that aren't full）。
-- ★★★ 第一级：遍历 equipslots 找可合并的 equipstack 装备。
-- ★★★ 四重条件（840 行，全部与运算）：
--   ① v.components.equippable.equipstack —— 这件装备支持整摞装备；
--   ② v.components.stackable 存在 —— 它本身是可堆叠物；
--   ③ not IsFull() —— 它还没装满；
--   ④ CanStackWith(item) —— 与新物品同类。
-- ★★★ ★ 条件①是 DST 的一个特色机制：**整摞装备**。
--   例如「一摞石头 = 一个小石头堆」，装备时整摞带上。
-- ★★★ ★★ 841 行 `return k, self.equipslots` ——
--   返回的是**装备槽名**和**装备槽表**！
--   ⇒ 调用方（1095 行 GiveItem）会通过 container == self.equipslots
--     判断走「装备」分支（1135-1138 行）。
--   ★★★ 这就是「同一个 GiveItem 能处理三种容器」的实现。
-- ★ ★★ 注意：这一级**没有** prioritize_overflow 判定（直接 return）。
--   ⇒ 「装备槽里的可合并堆叠」优先级最高，无条件返回。
        for k, v in pairs(self.equipslots) do
-- ↑ 第一级：装备槽堆叠。
            if v.components.equippable.equipstack and v.components.stackable and not v.components.stackable:IsFull() and v.components.stackable:CanStackWith(item) then
-- ★★★ 装备槽堆叠的四重条件（★ 第①重：equipstack 支持整摞装备）。
                return k, self.equipslots
-- ★★★ return (槽名, equipslots) —— ★★ 返回装备槽表！
            end
-- ↑ if 块结束。
        end
-- ↑ equipslots 遍历结束。

-- ★★★ 第二级：遍历 itemslots 找可合并的堆叠。
-- ★★ 为什么要暂存（inv_slot/inv_pref）而不是直接返回？
-- ★★★ 因为 848 行的条件：`if prioritize_overflow or specialized then`
--   · 若无需优先（都没有），852 行**立即返回**（最高效路径）；
--   · 若需要优先，849-850 行**暂存**并继续搜索，
--     看看 overflow/专用容器里有没有更好的位置。
-- ★★★ 这就是「优先」机制的实现：**找到候选但不立即定**。
        local inv_slot, inv_pref
-- ↑ 第二级：普通槽堆叠（带暂存逻辑）。
        for k, v in pairs(self.itemslots) do
-- ★★ 普通槽堆叠遍历。
            if v.components.stackable and not v.components.stackable:IsFull() and v.components.stackable:CanStackWith(item) then
-- ★★★ 三重条件：有 stackable + 没满 + 同类。
				if prioritize_overflow or specialized then
-- ★★ 需不需要「暂存」？（overflow 优先或有专用容器）。
                    inv_slot, inv_pref = k, self.itemslots
-- ★★★ 暂存候选（★ 不立即返回，留给 overflow/专用容器机会）。
                    break
-- ★★ break —— 找到第一个可合并的普通槽就停（★ 不继续找更好的）。
                else
-- ↑ else 分支。
                    return k, self.itemslots
-- ★★ 无优先需求 → 立即返回（最高效路径）。
                end
-- ↑ if/else 结束。
            end
-- ↑ if 块结束。
        end
-- ↑ itemslots 遍历结束。

-- ★★★★ 第三级：overflow 里的堆叠搜索。
-- ★★★ 两个进入条件（857 行）：
--   ① useoverflow 为真（物品有资格进 overflow）；
--   ② 没有更好的普通槽候选（`not (inv_slot and inv_pref)`）
--      **或** overflow 有优先权（prioritize_overflow）。
-- ★★ ★ 第二个条件是「溢出」逻辑的核心：
--   普通槽有可合并的地方就用普通槽，**除非** overflow 要优先。
-- ★★★ 这就是「优先」的真实含义：**凌驾于普通槽之上**。
		if useoverflow and (prioritize_overflow or not (inv_slot and inv_pref)) then
-- ↑ 第三级：overflow 堆叠。
			for k, v in pairs(overflow.slots) do
-- ★★ overflow 堆叠遍历（★ 第三次调用 ValidateItemForOverflow，见 847 行同类）。
				if v.components.stackable and not v.components.stackable:IsFull() and v.components.stackable:CanStackWith(item) then
-- ★★★ 三重条件（同 847 行）。
-- ★★ `if specialized and not prioritize_overflow` ——
--   有专用容器要，但 overflow 不优先 → 暂存 overflow 的槽位，
--   继续看专用容器（873 行可能立即返回）。
-- ★★★ 三方博弈的第三种情况：专用容器 > overflow > 普通槽。
					if specialized and not prioritize_overflow then
-- ↑ 专用容器优先于 overflow 的暂存。
-- ★★ 专用容器优先而 overflow 不优先 → 暂存。
						inv_slot, inv_pref = k, overflow
-- ★★★ 暂存 overflow 的槽位。
						break
-- ★ break（找不到更好的就停在第一个）。
					end
-- ↑ if 块结束。
					return k, overflow
-- ★★ 否则立即返回（★ overflow 不需要优先时才走这）。
                end
-- ↑ if 块结束。
            end
-- ↑ overflow 遍历结束。
        end
-- ↑ 条件块结束。

-- ★★ 第四级：遍历专用容器（重排后的顺序 = 优先级）找堆叠。
-- ★★★ 与第二级不同：这里**没有**暂存逻辑，直接 return。
-- ★★★ 原因：专用容器已经是「最高优先级」了（经过了 820 行的重排）。
-- ★ 871-876 行遍历 specialized 里每个容器的 slots 数组。
		if specialized then
-- ↑ 第四级：专用容器堆叠。
			for _, spoverflow in ipairs(specialized) do
-- ★★ 专用容器堆叠遍历（★ 顺序 = 820 行的重排优先级）。
				for k, v in pairs(spoverflow.slots) do
-- ★ 遍历该容器的槽。
					if v.components.stackable and not v.components.stackable:IsFull() and v.components.stackable:CanStackWith(item) then
-- ★★★ 三重条件（同 847 行）。
						return k, spoverflow
-- ★★ return (槽, 专用容器) —— ★ 直接返回，不暂存。
					end
-- ↑ if 块结束。
				end
-- ↑ 槽遍历结束。
			end
-- ↑ 专用容器遍历结束。
		end
-- ↑ 条件块结束。

-- ★★★ `if (prioritize_overflow or specialized) and inv_slot and inv_pref then` ——
--   ★ 兜底返回：若之前暂存了候选且确实需要优先，现在返回它。
-- ★★★ 这是「暂存-延迟决定」模式的终点。
-- ★★ 若两者都不为真，852 行早就返回了，走不到这里。
		if (prioritize_overflow or specialized) and inv_slot and inv_pref then
-- ↑ 暂存候选的兜底返回。
            return inv_slot, inv_pref
-- ★★★ 返回之前暂存的候选（★ 「暂存-延迟决定」的终点）。
        end
-- ↑ if 块结束。
-- ↑ 堆叠合并搜索块结束（837-882 的大 if）。
    end
-- ↑ 堆叠合并块结束。

-- ↑ 堆叠合并大 if 结束。
-- ★★★ 空位搜索 —— 第一级：overflow 的空槽。
-- ★★ 条件：`useoverflow and prioritize_overflow` ——
--   只有「overflow 要这件物品」时才在 overflow 里找**空位**。
--   ★★★ ★ 与堆叠搜索（857 行）同构：**优先才进**。
-- ★★★ 886 行双重检查：`CanTakeItemInSlot(item, k) and not overflow.slots[k]`
--   —— 既要「允许放」又要「槽是空的」。
--   ★ CanTakeItemInSlot 是 container 的同名方法（container.lua），
--     与本文件 231 行的版本**同构但不同实现**（容器版接受 numslots 概念）。
	if useoverflow and prioritize_overflow then
-- ↑ 空位搜索一级：overflow。
        for k = 1, overflow:GetNumSlots() do
-- ★★ overflow 空位：遍历 1..GetNumSlots()。
            if overflow:CanTakeItemInSlot(item, k) and not overflow.slots[k] then
-- ★★★ 双重检查：能放 且 槽为空。
                return k, overflow
-- ★★ return (槽, overflow)。
            end
-- ↑ if 块结束。
        end
-- ↑ 遍历结束。
    end
-- ↑ 条件块结束。

-- ★★★ 空位搜索 —— 第二级：专用容器的空槽。
-- ★★★ 与 884 的差异：**没有 prioritize_overflow 条件**。
--   ⇒ 专用容器**总是**参与空位搜索（在 ①-④ 都没找到之后）。
-- ★★★ 设计理由：专用容器（弹药袋）是玩家的明确意图，
--   应该优先于普通背包格被填充。
-- ★ 顺序：专用容器**在**普通背包格**之前**（892 在 902 之前）。
-- ★★ 这就是「弹药会优先进弹药袋」的完整实现。
	if specialized then
-- ↑ 空位搜索二级：专用容器（优先于普通格）。
		for _, spoverflow in ipairs(specialized) do
-- ★★ 专用容器空位遍历（★ 无优先级条件，总参与）。
			for k = 1, spoverflow:GetNumSlots() do
-- ★ 遍历槽。
				if spoverflow:CanTakeItemInSlot(item, k) and not spoverflow.slots[k] then
-- ★★ 双重检查。
					return k, spoverflow
-- ★ return (槽, 专用容器)。
				end
-- ↑ if 块结束。
			end
-- ↑ 槽遍历结束。
		end
-- ↑ 专用容器遍历结束。
	end
-- ↑ if specialized 块结束。

-- ★★★ 空位搜索 —— 第三级（最后）：普通背包格的空位。
-- ★★ 这是**兜底**：所有容器都不行才用普通格。
-- ★ 904 行 `self:CanTakeItemInSlot(item, k)` 复用本文件的判定（231 行）。
--   ★★ 与 886 行的 overflow 版调用**不同方法**（自己的 vs 容器的），
--     但语义一致。
-- ★★ ★ 有序遍历 1..maxslots ⇒ 优先填前面的格子。
--   ⇒ 玩家的背包会「从上往下」填满，符合直觉。
    --check for empty space in the container
-- ↑ 空位搜索三级：普通格（兜底）。
    for k = 1, self.maxslots do
-- ★★★ 普通槽空位：有序遍历（★ 优先填靠前的格子）。
        if self:CanTakeItemInSlot(item, k) and not self.itemslots[k] then
-- ★★ 双重检查（★ 用本文件的 CanTakeItemInSlot）。
            return k, self.itemslots
-- ★★ return (槽, self.itemslots) —— ★★ 第二值是**表**不是容器组件。
        end
-- ↑ if 块结束。
    end
-- ↑ 遍历结束。
-- ★★ `return nil, self.itemslots` —— 找不到时的返回值。
-- ★★★ ★ 第二返回值仍是 self.itemslots（不是 nil）。
--   这是一个**约定**而非语义需要。
-- ★★ 调用方（1095 行）只检查第一个返回值。
--   ⇒ 1085-1169 行的 `if slot then` 分支自然覆盖了「找不到」的情况。
    return nil, self.itemslots
-- ↑ 找不到时的 (nil, self.itemslots)。
end
-- ↑ GetNextAvailableSlot 结束（908 行的 return 是函数隐式返回）。

-- 【§八】★ CanAcceptCount —— 「这物品能一次接收多少个」。
-- ★★★ 与 GetNextAvailableSlot 的分工：
--   · GetNextAvailableSlot = 「下一个放哪」（返回槽号）；
--   · CanAcceptCount = 「能收多少个」（返回数量）。
-- ★★★ ★★ 两者的搜索顺序**几乎一致**但目的不同：
--   GetNextAvailableSlot 找到就返回；CanAcceptCount 累加所有空间。
-- ★★ 典型用途：「拖动时显示能放多少个」。
--Check how many of an item we can accept from its stack
-- ↑ CanAcceptCount 函数头。
-- ★★ 913 行：`stacksize = item.components.stackable and StackSize() or 1` ——
--   「这物品现在有几个」（对可堆叠物）或「1 个」（对单件）。
-- ★★ 若 stackable 存在但 stacksize=0（空堆），得到 0，
--   然后 919 行 `if stacksize <= 0 then return 0` —— 返回 0。
-- ★ 这是对「空堆实体」的正确处理（既不是 1 也不是原值）。
function Inventory:CanAcceptCount(item, maxcount)
-- ↑ stacksize 计算起点。
	local stacksize = item.components.stackable and item.components.stackable:StackSize() or 1
-- ★★ 当前数量（★ 三元表达式，注意 0 在 Lua 里是真值）。
-- ★★★ islockedinslot 的特殊处理（914-918 行）：
--   · 锁定物品：`stacksize = math.max(maxcount or math.huge, stacksize - 1)`
--     ⇒ 效果：**至少允许取 1 个**（即使 stacksize 只有 1）。
--     若 maxcount 有值，取 max(maxcount, stacksize-1)。
--   · 普通物品：`stacksize = maxcount or stacksize`。
-- ★★★ ★ 设计推理：
--   锁定物品「不能整摞拿走」，但「可以抽走一个」。
--   所以能接受的数量是 stacksize - 1（下界 0）？
--   ⇒ 但如果 stacksize = 1，stacksize - 1 = 0 → 一个都不能拿！
--   ★★ `math.max(..., math.huge)` 的作用：maxcount 为 nil 时用 math.huge，
--     于是 `math.max(math.huge, stacksize - 1)` = math.huge ——
--     「不限制」（因为调用方只是问「能不能放」，不给具体数量）。
--   ⇒ ★★ 结论：islockedinslot 时若不传 maxcount，返回**无限**。
--   ★ 若传了 maxcount = 5，stacksize = 3：max(5, 2) = 5。
--     ★ 这是一个**过估**（over-estimate）。
--     ★ 但 931/940 行的早返回会兜住，最终返回真实值，不崩。
	if item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- ↑ islockedinslot 的特殊容量计算。
		stacksize = math.max(maxcount or math.huge, stacksize - 1)
-- ★★★ 锁定物品：至少允许 1 个（★ maxcount 为 nil 时用 math.huge ⇒ 无限）。
	else
-- ↑ else 分支。
		stacksize = maxcount or stacksize
-- ★★ 普通物品：直接用 maxcount 或实际数量。
	end
-- ↑ if/else 结束。
-- ★★ `if stacksize <= 0 then return 0` —— 零个可接受时立即返回。
-- ★ 这是提前退出优化（避免无意义的遍历）。
-- ★ ★★ 边界：stacksize = 0（空堆）或负数（异常）都走这里。
    if stacksize <= 0 then
-- ↑ 零容量早退。
        return 0
-- ★★ 零容量 → 返回 0（★ 空堆的防御）。
    end
-- ↑ 早退块结束。

-- ★★ acceptcount —— 累加器。从 0 开始。
    local acceptcount = 0
-- ↑ 累加器初始化。

-- ↑ 空行。
-- ★★★ 主循环：遍历 1..maxslots 的普通槽。
-- ★★★ 两分支：
--   ① 928-934 行：槽内有物品且**可合并** → 加 RoomLeft；
--   ② 935-943 行：槽**为空**且允许放 → 
--     「acceptsstacks 或 stacksize<=1」直接返回全部（936-938）；
--     否则 acceptcount += 1（每个空格算 1 个位置）。
-- ★★★ ★★ 938 行的快速返回：`if self.acceptsstacks or stacksize <= 1 then`
--   ⇒ 解释：「本栏接受整摞」或「就 1 个东西」时，
--     **有一个空槽就够了**（可以全放进去）→ 返回 stacksize。
--   ⇒ 这是 acceptsstacks 字段的核心作用（54 行的初始化在此兑现）。
-- ★★ 943 行则是不接受整摞时，每个空格只能放 1 个 → 逐格累加。
    --check for empty space in the container
-- ↑ 主循环开始。
    for k = 1, self.maxslots do
-- ★★ 主循环开始。
        local v = self.itemslots[k]
-- ★ 取槽内物品。
        if v ~= nil then
-- ★★ if 槽有东西 → 走「合并」分支。
-- ★★ 可合并判定：`v.components.stackable ~= nil and CanStackWith(item)`。
-- ★ ★ 注意这里**没有** IsFull() 检查 —— 因为下面用 RoomLeft()。
-- ★★ RoomLeft() 返回「还能装几个」，所以已满的堆叠 RoomLeft=0，
--   加 0 不影响结果。**更优雅**的写法（比 840 行的三重条件简洁）。
            if v.components.stackable ~= nil and v.components.stackable:CanStackWith(item) then
-- ↑ 可合并判定（无 IsFull 检查，用 RoomLeft）。
-- ★★★ acceptcount += RoomLeft —— 「这一摞还能装几个」。
-- ★★ RoomLeft 是 stackable 的方法（stackable.lua）。
                acceptcount = acceptcount + v.components.stackable:RoomLeft()
-- ↑ 累加 RoomLeft。
-- ★★ `if acceptcount >= stacksize then return stacksize` —— 够早退。
-- ★★★ 提前返回（已经能装下全部）。避免无谓的继续遍历。
-- ★ ★ 返回的是 stacksize（**上限**），不是 acceptcount（实际累加值）。
--   ⇒ 二者在这一刻相等（因为 acceptcount 刚超过 stacksize）。
--   ★ 但若 acceptcount 一次跳了很多（RoomLeft 很大），返回值被**截断**。
--   ★ 这是有意的：「最多能收 stacksize 个」（不会超发）。
                if acceptcount >= stacksize then
-- ↑ 够早退（返回 stacksize 而非累加值）。
                    return stacksize
-- ★★★ 够了 → 立即返回 stacksize（★ 截断，不返回累加值）。
                end
-- ↑ if 块结束。
            end
-- ↑ 可合并判定块结束。
-- ★★★ 空槽分支：能否放这个物品。
-- ★ `elseif self:CanTakeItemInSlot(item, k)` —— 复用 231 行的判定。
-- ★ ★★★ ★ 注意：这里**没有**显式的「k 槽为空」检查，
--   因为 926-927 行的 `local v = self.itemslots[k]` + `if v ~= nil`
--   已经保证了：elseif 分支意味着 v 为 nil（空槽）。
-- ★★ 结构是 `if v ~= nil then (可合并判定) elseif (可以放) then`。
        elseif self:CanTakeItemInSlot(item, k) then
-- ↑ 空槽分支。
-- ★★★ `if self.acceptsstacks or stacksize <= 1 then return stacksize` ——
--   ★★★ 快速路径：**一个空槽就能装下全部**。
-- ★★ 两种触发：
--   · acceptsstacks = true —— 本栏接受整摞；
--   · stacksize <= 1 —— 就一个物品，任何空槽都行。
-- ★★★ ★ 这是「整摞进背包」的判定点。
-- ★ 与 939 行的逐格累加互斥：acceptsstacks 时**永远不进** 939。
            if self.acceptsstacks or stacksize <= 1 then
-- ★★★ acceptsstacks 的快速路径。
                return stacksize
-- ★★★ 一个空槽就能装下全部（acceptsstacks 或只有 1 个）。
            end
-- ↑ if 块结束。
            acceptcount = acceptcount + 1
-- ★★★ 不接受整摞时：每个空格只算 1 个位置。
            if acceptcount >= stacksize then
-- ★ 够了？
                return stacksize
-- ★ 返回 stacksize。
            end
-- ↑ if 块结束。
        end
-- ↑ 空槽分支结束。
    end
-- ↑ 主循环结束。

-- ★★★ overflow 的容量计算 —— 与普通槽**完全同构**的逻辑。
-- ★★ 949 行用 `overflow.numslots`（不是 GetNumSlots()）——
--   两者对 container 组件等价（container.lua 的 GetNumSlots 返回 numslots）。
-- ★★ ★★ 条件 947 行：`if overflow and ValidateItemForOverflow(...)` ——
--   只有 overflow **有资格收**才计算它的容量。
-- ★★ 与 GetNextAvailableSlot 的 857 行逻辑一致（都检查 useoverflow）。
    local overflow = self:GetOverflowContainer()
-- ↑ overflow 容量计算（与普通槽同构）。
	if overflow and ValidateItemForOverflow(item, overflow) then
-- ★★ overflow 有且有资格收 → 算它的容量。
		--check for empty space in our backpack
-- ↑ 原英文注释保留（check for empty space in our backpack）。
		for k = 1, overflow.numslots do
-- ★★ 遍历 1..overflow.numslots（★ 直接读字段而非 GetNumSlots()）。
			local v = overflow.slots[k]
-- ★ 取槽内物品。
			if v then
-- ★★ 槽有东西 → 合并分支。
				if v.components.stackable and v.components.stackable:CanStackWith(item) then
-- ★★ 可合并判定。
					acceptcount = acceptcount + v.components.stackable:RoomLeft()
-- ★★★ 累加 RoomLeft（★ 与普通槽同构）。
					if acceptcount >= stacksize then
-- ★ 够了？
						return stacksize
-- ★ 返回 stacksize。
					end
-- ↑ if 块结束。
				end
-- ↑ 合并分支结束。
			elseif overflow:CanTakeItemInSlot(item, k) then
-- ★★ 槽为空 → 看能否放。
				if overflow.acceptsstacks or stacksize <= 1 then
-- ★★★ 快速路径（acceptsstacks 或 1 个）。
					return stacksize
-- ★ 返回 stacksize。
				end
-- ↑ if 块结束。
				acceptcount = acceptcount + 1
-- ★ 逐格累加 1。
				if acceptcount >= stacksize then
-- ★ 够了？
					return stacksize
-- ★ 返回 stacksize。
                end
-- ↑ if 块结束。
            end
-- ↑ 空槽分支结束。
        end
-- ↑ overflow 槽遍历结束。
    end
-- ↑ if 块结束。

-- ★★★ 专用容器的容量计算。
-- ★★ 973 行**又**检查了一次 ShouldPrioritizeContainer：
--   `if spoverflow:ShouldPrioritizeContainer(item) and ...`
-- ★★★ ★ 注意与 GetNextAvailableSlot（869-877 行）的差异：
--   · GetNextAvailableSlot 的专用容器搜索**没有**这个条件
--     （因为 820-835 行已经预先重排过）；
--   · CanAcceptCount 这里**需要**再判一次（没有重排步骤）。
-- ★★ 两条路径的等价实现，但 CanAcceptCount 更直接。
	local specialized = self:GetSpecializedContainers()
-- ↑ 专用容器容量计算。
	if specialized then
-- ★ 有专用容器。
		for _, spoverflow in ipairs(specialized) do
-- ★★ 遍历（★ 顺序即优先级）。
			if spoverflow:ShouldPrioritizeContainer(item) and ValidateItemForOverflow(item, spoverflow) then
-- ★★★ 双重条件（★ 820 行未重排，故此处需再判一次）。
				for k = 1, spoverflow:GetNumSlots() do
-- ★ 遍历该容器的槽。
					local v = spoverflow.slots[k]
-- ★ 取槽内物品。
					if v then
-- ★★ 槽有东西 → 合并分支。
						if v.components.stackable and v.components.stackable:CanStackWith(item) then
-- ★★ 可合并判定。
							acceptcount = acceptcount + v.components.stackable:RoomLeft()
-- ★ 累加 RoomLeft。
							if acceptcount >= stacksize then
-- ★ 够了？
								return stacksize
-- ★ 返回 stacksize。
							end
-- ↑ if 块结束。
						end
-- ↑ 合并分支结束。
					elseif spoverflow:CanTakeItemInSlot(item, k) then
-- ★★ 槽为空 → 看能否放。
						if spoverflow.acceptsstacks or stacksize <= 1 then
-- ★★★ 快速路径。
							return stacksize
-- ★ 返回 stacksize。
						end
-- ↑ if 块结束。
						acceptcount = acceptcount + 1
-- ★ 逐格累加。
						if acceptcount >= stacksize then
-- ★ 够了？
							return stacksize
-- ★ 返回 stacksize。
						end
-- ↑ if 块结束。
					end
-- ↑ 空槽分支结束。
				end
-- ↑ 槽遍历结束。
			end
-- ↑ 双重条件块结束。
		end
-- ↑ 专用容器遍历结束。
	end
-- ↑ if specialized 块结束。

-- ★★★ 装备槽的容量（最后一级，与 GetNextAvailableSlot 的 839 行对应）。
-- ★★ 999-1005 行：遍历 equipslots，累加 equipstack 装备的 RoomLeft。
-- ★★★ ★ 注意：这一级放在**最后**（997 行之后），
--   而 GetNextAvailableSlot 把它放在**最前**（839 行）！
-- ★★ ★★ 两者的顺序**不一致**——这是一个真实的行为差异：
--   · GetNextAvailableSlot：装备槽的堆叠优先级最高；
--   · CanAcceptCount：装备槽的容量最后计算。
-- ★★ 影响：CanAcceptCount 返回的数字可能偏大（因为它把所有空间都加了），
--   而实际 GetNextAvailableSlot 放的第一个位置可能不同。
-- ★★★ 但由于 CanAcceptCount 只返回一个**总数**（不指位置），
--   这个顺序差异**不影响正确性**，只影响「是否早退」的时机。
-- ★★ ⇒ 结论：无功能 bug，但两个函数的搜索顺序应统一以减少维护困惑。
    if item.components.stackable ~= nil then
-- ↑ 装备槽容量（★ 顺序与 GetNextAvailableSlot 不一致）。
        --check for equip stacks that aren't full
-- ↑ 原英文注释保留（check for equip stacks that aren't full）。
        for k, v in pairs(self.equipslots) do
-- ★ 遍历装备槽。
            if v.components.equippable.equipstack and v.components.stackable ~= nil and v.components.stackable:CanStackWith(item) then
-- ★★★ 三重条件（★ 注意：没有 IsFull 检查，用 RoomLeft 兜底）。
                acceptcount = acceptcount + v.components.stackable:RoomLeft()
-- ★ 累加 RoomLeft。
                if acceptcount >= stacksize then
-- ★ 够了？
                    return stacksize
-- ★ 返回 stacksize。
                end
-- ↑ if 块结束。
            end
-- ↑ 条件块结束。
        end
-- ↑ equipslots 遍历结束。
    end
-- ↑ if stackable 块结束。

-- ★★ `return acceptcount` —— 累加完毕的真实容量。
-- ★★★ ★ 不变式：**返回值永远 ≤ stacksize**。
--   证明：所有累加点后都有 `if acceptcount >= stacksize then return`；
--   ⇒ 走到这里的 acceptcount 必然 < stacksize。
-- ★ 这个不变式很重要：CanAcceptCount 永不超发。
    return acceptcount
-- ★★★ 返回 acceptcount（不变式：≤ stacksize）。
end
-- ↑ CanAcceptCount 结束（1009 行的 return 是隐式返回）。

-- ↑ 空行。
-- 【§十】★ GiveActiveItem —— 「强制把某物设为手上物品」。
-- ★★★ 与 GiveItem 的分工：
--   · GiveActiveItem 无条件塞进手上（不管背包满不满）；
--   · GiveItem 会找槽位，可能塞进背包、也可能塞进手上（兜底）。
-- ★★ 三步（1013-1026 行）：
--   ① 1014 行先 ReturnActiveItem 把旧的手上物品放回背包；
--   ② 1016 行 OnPickup（可能返回 false 表示「拒绝被拿起」）；
--   ③ 1019-1024 行设为 activeitem + 事件 + ToPocket 通知。
-- ★★ 注意：参数是 inst（单个物品），没有 slot / src_pos 参数。
--   ⇒ GiveActiveItem 是「专用路径」，不能指定位置。
function Inventory:GiveActiveItem(inst)
-- ↑ GiveActiveItem 结束（无条件塞进手上）。
-- ★★ `if inst ~= nil and inst:IsValid()` —— 双重有效性检查。
-- ★★ 注意：这里检查了 IsValid，但 GiveItem（1030 行）也检查。
--   两者都有 ⇒ 这是 Klei 的一致风格（防御式编程）。
-- ★★ 1030 行的顺序不同：`inst.components.inventoryitem == nil or
--   not inst:IsValid()` —— **先查组件再查有效性**。
--   ⇒ 顺序颠倒会崩（对已销毁实体取 .components）。
-- ★ 这是本文件里「防御性顺序」的一个范例。
    if inst ~= nil and inst:IsValid() then
-- ↑ 有效性判定。
-- ★★ self:ReturnActiveItem() —— **先把旧的手上物品放回背包**。
-- ★★★ ★ 这是 GiveActiveItem 的「腾位」动作。
--   如果不先清掉旧的，新的就无处安放（手上只能有一个）。
-- ★★ ★★ 但注意：ReturnActiveItem 可能**失败并把旧物丢地上**（570-586 行）。
--   ⇒ 给一个物品设置手上物品，可能导致另一个物品掉在地上！
--   ★ 这个副作用值得知道：某些「自动使用」的逻辑会引发意外掉落。
-- ★★ 对比 GiveItem：它**不**调 ReturnActiveItem，
--   而是靠 1178 行的 `if self.activeitem == nil` 判定只在手上为空时才塞。
        self:ReturnActiveItem()
-- ★★★ 先腾位（ReturnActiveItem 可能丢地上）。
-- ★★★ assert —— 「必须带 inventoryitem 组件」。
-- ★★ 这一行是**硬断言**（dev 版会崩，生产版也崩，与 BRANCH 无关）。
-- ★★ 错误信息带 prefab 名便于排查：`inst.entity:GetPrefabName()`。
-- ★★ ★ 这是本文件唯一的「无条件 assert」，它守的是一个不变式：
--   「凡是能进入 GiveActiveItem 的东西，都必须带 inventoryitem」。
-- ★ 为什么在 GiveActiveItem 而不在 GiveItem 里 assert？
--   因为 GiveItem（1031 行）用 print 警告后 return（更宽松），
--   而 GiveActiveItem 是「内部专用路径」，可以严格。
-- ★ ⇒ ★ 两种错误处理风格的对比：
--   · GiveActiveItem（严格，崩）—— 认为是编程错误；
--   · GiveItem（宽松，打印）—— 认为是运行时数据问题。
        assert(inst.components.inventoryitem ~= nil, inst.entity:GetPrefabName().." in inventory is lacking inventoryitem component")
-- ★★★ 硬断言（必带 inventoryitem）。
-- ★★★ `if not inst.components.inventoryitem:OnPickup(self.inst) then` ——
--   ★★ ★ OnPickup 的返回值语义是**反向**的：
--     · 返回 **false/nil** → 正常，继续放入背包；
--     · 返回 **true** → 「对象已被销毁」，**中止**后续操作。
--   ★★★ 这个语义很反直觉（返回 true 表示「别继续了」），
--     但它统一了「拿起时如果实体被销毁（如被烧光）」的场景。
-- ★★ 对照 GiveItem:1055：`local objectDestroyed = ...OnPickup(...)`
--   106 行 `if objectDestroyed then return end` —— 变量名直接说明了语义。
--   ⇒ ★★ 两处对同一返回值的处理一致，但**命名不同**
--     （GiveActiveItem 用 `not` 取反，GiveItem 用正命名）。
-- ★★★ 对比 733 行的 RemoveFromOwner：那里返回的是**实体**而非布尔。
--   ⇒ 「返回 true = 失败」与「返回实体 = 成功」是两种不同的约定。
-- ★★ inventoryitem.lua 的 OnPickup 内部可能：设 owner、
--   触发 buff、处理「物品有跟随主人行为」的逻辑。
        if not inst.components.inventoryitem:OnPickup(self.inst) then
-- ↑ OnPickup（返回 true = 对象已销毁，中止）。
            inst.components.inventoryitem:OnPutInInventory(self.inst)
-- ★★ OnPutInInventory —— 与 1055 行的 OnPickup 配对。

-- ↑ 空行。
            self:SetActiveItem(inst)
-- ★★★ SetActiveItem → PushEvent("newactiveitem") → 客户端同步。
-- ★★★ PushEvent("itemget", { item = inst, slot = nil }) ——
-- ★★ ★ 注意 `slot = nil`：这是「物品进了手上」的联机通知。
--   inventory_replica.lua:23 监听 → SetSlotItem(data.slot, data.item)
--   其中 data.slot 为 nil ⇒ SetSlotItem(nil, item)。
-- ★★★ ★★ 在 inventory_classified.lua:27 SetSlotItem 里，
--   slot 为 nil 会被转成一个**特殊索引**（用于「手上物品」）。
--   ⇒ 这是「第三张表（activeitem）」在网络层的体现：
--     它用一个特殊 slot 编号混在槽位数组里。
-- ★★ 交叉引用：prefabs/inventory_classified.lua:27-40 的 SetSlotItem。
            self.inst:PushEvent("itemget", { item = inst, slot = nil })
-- ★★★ itemget 事件（slot=nil 表示「进入手上」）。

-- ↑ 空行。
-- ★★ `if inst.components.equippable ~= nil then ToPocket()` ——
-- ★★★ ToPocket（equippable.lua:109）只调 onpocketfn，不改状态。
-- ★★ 语义：「这件装备现在在背包里（而非穿着）」。
-- ★★ ★ 注意 GiveItem 也有同样的调用（1154-1156 行），
--   但 Equip 流程里是 1351 行（旧装备换下时）—— 三处都要调。
-- ★ ★★ 遗漏任何一处都会导致 onpocketfn 少被调一次。
-- ★ 这是「装备物品进出背包」的事件一致性维护。
            if inst.components.equippable ~= nil then
-- ↑ ToPocket 通知。
                inst.components.equippable:ToPocket()
-- ★ ToPocket（★ 只对 equippable 的物品）。
            end
-- ↑ if equippable 块结束。
        end
-- ↑ if OnPickup 返回块结束。
    end
-- ↑ if inst 有效性块结束。
end
-- ↑ GiveActiveItem 结束。

-- 【§十】★★★★★ GiveItem —— 「把物品放进物品栏」。
-- ★★★★★★ 本文件**最重要**的函数。几乎所有物品流转都经过它。
-- ★★★★★ 它有 205 行、约 45 个分支，包含 8 级回退策略。
-- ★★ 完整流程（按代码顺序）：
--   ① 1030-1033 行 资格检查（失败则 return）；
--   ② 1035-1039 行 若已装备 → 先 Unequip（避免状态冲突）；
--   ③ 1041-1049 行 判断是否「新物品」（决定是否播音效）；
--   ④ 1051-1053 行 若属于别人 → RemoveFromOwner 强夺；
--   ⑤ 1055-1058 行 OnPickup（可能中止）；
--   ⑥ 1062-1084 行 尝试复原 prevslot / prevcontainer（位置记忆）；
--   ⑦ 1086-1089 行 校验建议槽位是否可用；
--   ⑧ 1091-1096 行 自动选槽（GetNextAvailableSlot）；
--   ⑨ 1098-1166 行 按 container 类型分别处理（四种分支）；
--   ⑩ 1167-1216 行 都没成功 → 六层兜底（见 1167 起的注释）。
-- ★★★ ★★ 返回值语义**极不统一**（这是本函数最大的坑）：
--   · 成功放入普通槽 → `return slot`（1166 行，**数字**）；
--   · 成功放入 overflow → `return true`（1168 行，**布尔**）；
--   · 成功塞进 activeitem → `returnvalue = true` → `return true`（1216 行）；
--   · 失败（ignorefull） → `return false`（1172 行）；
--   · 失败（其他） → 可能 `return false`（1162 行）或落到 1216。
-- ★★★ ⇒ 调用方**只能做真假判断**，不能依赖具体值：
--   `if inv:GiveItem(x) then ... end` 是唯一正确的用法。
--   ★⚠ 若调用方写 `local slot = inv:GiveItem(x)` 然后当槽号用，会出错。
function Inventory:GiveItem(inst, slot, src_pos)
-- ★★★★★★ GiveItem 函数头（45 个分支、8 级回退）。
-- ★★ 资格检查（1030-1033 行）：
--   `if inst.components.inventoryitem == nil or not inst:IsValid()`
-- ★★★ 顺序很关键：**先查组件**（防对已销毁实体取属性），
--   **再查 IsValid**。反过来会崩。
-- ★★ 1031 行 print 警告 + 1032 行 return（不是 assert）。
--   ⇒ 与 1015 行的 assert 形成对比（宽松 vs 严格）。
    if inst.components.inventoryitem == nil or not inst:IsValid() then
-- ↑ 资格检查（先组件后 IsValid）。
        print("Warning: Can't give item because it's not an inventory item.")
-- ★★ 警告 + return（★ 宽松策略，非 assert）。
        return
-- ↑ 早退。
    end
-- ↑ 资格检查块结束。

-- ★★★ `local eslot = self:IsItemEquipped(inst)` —— 判断是否正穿着。
-- ★★★ ★ 为什么要先查这个？因为「给一件已装备的物品」会状态冲突：
--   它同时在 equipslots 和（可能）activeitem 里。
-- ★★ 1038 行 Unequip(eslot) —— 先脱下来再放进背包。
-- ★★★ ★ 注意：1038 行**不传 force**。
--   ⇒ 若装备带 preventunequipping，Unequip 返回 nil，
--     但**代码继续往下走**（不检查返回值）！
--   ★★★ ⚠ 这是一个真实的逻辑缺陷（见 L15）：
--     「给一件粘住的装备」会导致它仍在 equipslots 里，
--     然后流程继续，可能在别处又放一份 → **实体在两个槽里**。
--   ★ 正确做法应该是 `if self:Unequip(eslot) == nil then return false end`。
    local eslot = self:IsItemEquipped(inst)
-- ↑ 查是否已装备。

-- ↑ 空行。
    if eslot then
-- ★★ 确实正穿着？
       self:Unequip(eslot)
-- ★★★ Unequip（★ 不传 force —— 见 L15）。
    end
-- ↑ if eslot 块结束。

-- ★★ `local new_item = inst ~= self.activeitem` —— 是否「新物品」。
-- ★★★ ★ 这个布尔决定 1099 行是否播 "gotnewitem" 事件（音效）。
-- ★★ 语义：
--   · new_item = true → 这是**新拿到**的物品（要播音）；
--   · new_item = false → 它本来就在手上（只是换个位置，不播音）。
-- ★★ 1043-1049 行再排除一种情况：它穿着在装备槽上，
--   也算「不新」（因为它已经在身上了）。
-- ★★★ ★⇒ new_item 的完整定义：**既不在手上、也不在装备槽上**。
--   这就是「拾取音只在真正拾取时响」的精确实现。
    local new_item = inst ~= self.activeitem
-- ↑ new_item 判定起点。
    if new_item then
-- ★★ 排除「已穿着」的情况。
        for k, v in pairs(self.equipslots) do
-- ★ 遍历装备槽。
            if v == inst then
-- ★ 是这件？
                new_item = false
-- ★★★ 改成「不新」⇒ 不播 gotnewitem 音。
                break
-- ★ 找到就停。
            end
-- ↑ if 块结束。
        end
-- ↑ equipslots 遍历结束。
    end
-- ↑ if new_item 块结束。

-- ★★★ `if inst.components.inventoryitem.owner and ... ~= self.inst then`
--   RemoveFromOwner(true) —— **强夺**别人的物品。
-- ★★★ ★ wholestack=true 表示「整摞拿走」。
--   ★ 为什么强夺时一定是整摞？
--     因为 partial 拿取会让原持有者还剩一部分，而两人都声称拥有它，
--     状态会混乱。整摞转移是唯一自洽的做法。
-- ★★★ ★★ 场景：从箱子/另一个实体手里拿东西。
--   注意 1467 行 RemoveItem 的 checkallcontainers 参数做的是同一件事
--   （只是走了不同路径）。
-- ★★ 与 733 行 DropItem 的 RemoveFromOwner(wholestack, ...) 同源。
-- ★★ ★ 潜在问题：RemoveFromOwner 会触发旧主人的 OnRemoved，
--   可能导致旧主人的 UI 刷新（正确的），但也可能触发其他副作用。
    if inst.components.inventoryitem.owner and inst.components.inventoryitem.owner ~= self.inst then
-- ↑ 强夺他人物品（整摞）。
        inst.components.inventoryitem:RemoveFromOwner(true)
-- ★★★ RemoveFromOwner(true) —— 整摞强夺（★ 返回值未使用）。
    end
-- ↑ if owner 块结束。

-- ★★★ `local objectDestroyed = ...:OnPickup(self.inst, src_pos)` ——
-- ★★★ ★ 注意比 GiveActiveItem（1016 行）**多了 src_pos 参数**！
--   src_pos = 物品被拿起的坐标（用于飞行动画起点）。
--   ★ src_pos 的来源：
--     · 2428 行 DropItemFromInvTile 不传；
--     · 2513 行 MoveItemFromAllOfSlot 传 nil；
--     · 具体由调用方决定，常见于「从远处飞过来」的 mod。
-- ★★ 1057 行 `if objectDestroyed then return end` —— 中止且**无返回值**。
--   ★⇒ 调用方拿到 nil，视为「失败」。语义与 return false 略有差异
--     （nil vs false），但 `if not x` 都为真。
    local objectDestroyed = inst.components.inventoryitem:OnPickup(self.inst, src_pos)
-- ↑ OnPickup（带 src_pos）。
    if objectDestroyed then
-- ★★ 对象被销毁 → 中止（★ 无返回值 ⇒ nil）。
        return
-- ★ 早退。
    end
-- ↑ if 块结束。

-- ★★★ 位置记忆机制 —— 本函数第二块核心逻辑（1062-1084 行）。
-- ★★ 概念：每个物品记住了自己「上次在哪个槽/哪个容器」，
--   存在 item.prevslot 和 item.prevcontainer 两个字段上。
-- ★★★ ★ 由 RemoveItem（1400 行）与 RemoveItemBySlot 等处写入，
--   由本函数读取。⇒ 这是一个**跨调用的状态记忆**机制。
-- ★★ 三级回退：
--   ① 1062 行 无 prevcontainer → 直接用 prevslot；
--   ② 1066 行 有 prevcontainer → 尝试放回原容器；
--   ③ 都不行 → slot = nil，走自动选槽（1095 行）。
-- ★★★ ★ 设计意图：物品「回到它离开的地方」，而非乱塞。
--   典型体验：把斧头从第 3 格拖到箱子，再拿回来 → 回到第 3 格。
    local can_use_suggested_slot = false
-- ↑ 位置记忆三级回退起点。

-- ↑ 空行。
-- ★★ `if not slot and inst.prevslot and not inst.prevcontainer then` ——
--   「没有指定槽，但知道上次在哪一格（且不在容器里）」。
-- ★★ ⇒ 直接 `slot = inst.prevslot`，跳过 1086 行的校验？
--   ★★★ **不会**——1086 行仍会校验 `can_use_suggested_slot`；
--   若该槽已被占用，1094 行会回退到自动选槽。
-- ★★★ ★ 这就是「位置记忆」的完整实现：
--   「优先回原位」而非「直接进原位」。
    if not slot and inst.prevslot and not inst.prevcontainer then
-- ↑ 「无容器 → 直接用 prevslot」。
        slot = inst.prevslot
-- ★★ 「用记忆中的槽号」。
    end
-- ↑ if 块结束。

-- ★★★ 有 prevcontainer 的情况 —— 尝试放回**原来的容器**。
-- ★★★ 四重校验（1067-1079 行）：
--   1067 行 原容器仍有效且仍被自己打开；
--   1068-1072 行 那个槽现在是空的 → 直接放回并 return true；
--   1073-1079 行 那个槽有东西但**可堆叠合并** → Put 进去并 return true；
-- ★★ 注意这里 return 的是 **true**（不是槽号）——
--   因为已经放好了，不需要槽号。
-- ★★★ ★ 这就是「把物品放回刚才拿出来的箱子」的自动复原。
    if not slot and inst.prevslot and inst.prevcontainer then
-- ↑ 「有容器 → 尝试放回原容器」。
        if inst.prevcontainer.inst:IsValid() and inst.prevcontainer:IsOpenedBy(self.inst) then
-- ★★★ 原容器仍有效且仍被我打开？
            local item = inst.prevcontainer:GetItemInSlot(inst.prevslot)
-- ★ 查那个槽现在有什么。
            if item == nil then
-- ★★ 槽是空的 → 尝试放回原位。
                if inst.prevcontainer:GiveItem(inst, inst.prevslot) then
-- ★ 委托容器放回。
                    return true
-- ★★★ 成功 → 立即 return true（★ 注意返回 true 非槽号）。
                end
-- ↑ if item == nil 块结束。
-- ★★★ 四重条件的合并判定（1073-1077 行）：
--   ① itemInSlot 可堆叠；
--   ② CanStackWith(inst) —— 同类；
--   ③ inst.prevcontainer:AcceptsStacks() —— 容器接受整摞；
--   ④ CanTakeItemInSlot(inst, inst.prevslot) —— 槽位允许；
--   ⑤ Put(inst) == nil —— ★★★ **合并后没有剩余**才算成功！
-- ★★★ ★ 条件⑤是最关键的一行：Put 返回 leftovers（没放进去的）。
--   若 leftovers ~= nil，说明合并后还有剩余 —— 这次「放回」没完成，
--   于是不 return，继续走 1081-1083 行的清理逻辑。
-- ★★ 设计推理：「放回原容器」是一个**尽力而为**的操作，
--   只在完全成功时才提前返回；否则回落到普通选位。
-- ★★ ★★ 注意此分支**没有**把 inst 放进任何地方就继续往下走了，
--   这意味着 inst 仍在「手上」（如果有的话）或无处可去。
--   后续 1095 行会给它找新位置。行为正确。
            elseif item.components.stackable ~= nil and
-- ↑ 放回原容器的四重条件（含 Put==nil）。
-- ★ elseif 槽有东西 → 尝试堆叠合并。
                item.components.stackable:CanStackWith(inst) and
-- ★★ 条件② 同类。
                inst.prevcontainer:AcceptsStacks() and
-- ★ 条件③ 容器接受整摞。
                inst.prevcontainer:CanTakeItemInSlot(inst, inst.prevslot) and
-- ★ 条件④ 槽位允许。
                item.components.stackable:Put(inst) == nil then
-- ★★★ 条件⑤ Put 无剩余 ⇒ 完全合并成功。
                return true
-- ★★ 成功 → return true。
            end
-- ↑ elseif 块结束。
        end
-- ↑ if 原容器块结束。
-- ★★★ 放回原容器失败 → **清除记忆并重置槽位**：
--   1081-1082 行 prevcontainer/prevslot 置 nil（记忆失效）；
--   1083 行 slot = nil（强制走自动选槽）。
-- ★★ ★ 这是一次「状态回滚」：既然回不去，就忘掉这段记忆，
--   当作「第一次见到这个物品」处理。
-- ★★ 这样设计的好处：不会在失败状态上反复重试。
        inst.prevcontainer = nil
-- ★★★ 失败 → 清记忆 + 重置槽位。
        inst.prevslot = nil
-- ★★★ 清掉 prevslot（记忆失效）。
        slot = nil
-- ★★★ slot = nil（强制重新选位）。
    end
-- ↑ if prevcontainer 块结束。

-- ★★★ 建议槽位的合法性校验（1086-1089 行）。
-- ★★★ `can_use_suggested_slot` 的条件（1088 行）：
--   ① slot <= self.maxslots（在范围内）；
--   ② olditem == nil（空槽）**或** olditem 可与 inst 堆叠；
--   ③ CanTakeItemInSlot(inst, slot) —— 231 行的完整校验。
-- ★★★ ★ 注意条件②用 `olditem and olditem.components.stackable and ...`
--   —— 若 olditem 为 nil，整个 and 链得 nil（falsy），
--   但 `olditem == nil or (...)` 的前半段已是 true，所以整体为 true。
-- ★★ 这是「空槽 或 可堆叠」的经典写法。
-- ★★★ ★ 若 can_use_suggested_slot 为 false，1094-1095 行会重新选槽。
--   ⇒ ★ 记忆槽位只是「建议」，不是「命令」。
    if slot then
-- ↑ 建议槽位校验。
        local olditem = self:GetItemInSlot(slot)
-- ★ 取建议槽的现有物品。
        can_use_suggested_slot = slot ~= nil and slot <= self.maxslots and ( olditem == nil or (olditem and olditem.components.stackable and olditem.components.stackable:CanStackWith(inst))) and self:CanTakeItemInSlot(inst,slot)
-- ★★★★ 四重条件的巨型表达式（★ 见 BEFORE 的逐条拆解）。
    end
-- ↑ if slot 块结束。

-- ★★★ 三者的取得（1091-1093 行）：
--   · overflow = 背包本体；
--   · specialized = 专用容器（弹药袋等）；
--   · container = **默认值是 self.itemslots**。
-- ★★ 注意 1093 行：`local container = self.itemslots` 是默认值，
--   1095 行若重选会覆盖它。
-- ★★★ ★ 这三个变量在 1098-1166 行的四路分支中被用作「判别式」。
    local overflow = self:GetOverflowContainer()
-- ↑ 三容器取得。
	local specialized = self:GetSpecializedContainers()
-- ★ 专用容器列表。
    local container = self.itemslots
-- ★★★ container 默认值是 self.itemslots（★ 后面用作「判别式」）。
-- ★★★ `if not can_use_suggested_slot then slot, container = GetNextAvailableSlot(inst) end`
-- ★★★ ★ 这是「记忆失效后的重新选位」。
-- ★★ ★ GetNextAvailableSlot 返回 (slot, container)，
--   所以这里**同时**覆盖了 slot 和 container 两个变量。
-- ★★★ ★ 这就是「container 判别式」的来源：
--   1098 行之后用 `container == overflow` / `== self.equipslots`
--   等比较来决定走哪条分支。
-- ★★ 若 can_use_suggested_slot 为 true，container 保持默认值 itemslots，
--   ⇒ 走 1139-1152 行的「普通槽」分支。正确。
    if not can_use_suggested_slot then
-- ★★★ 记忆失效 → 重新选位（同时覆盖 slot 与 container）。
        slot, container = self:GetNextAvailableSlot(inst)
-- ★★ 重选：同时覆盖 slot 与 container。
    end
-- ↑ if not can_use_suggested_slot 块结束。

-- ★★★ 找到槽位后的分派（1098-1166 行）—— **四条路**。
-- ★★★ 按 container 的身份分派：
--   ① 1104 行 container == overflow      → 背包本体；
--   ② 1112 行 container ∈ specialized    → 专用容器（最复杂）；
--   ③ 1135 行 container == equipslots    → 装备槽；
--   ④ 1139 行 否则（== itemslots）        → 普通槽。
-- ★★★ ★ 顺序有意义：overflow 在前，因为 GetNextAvailableSlot
--   可能返回 overflow 的槽；specialized 在第二，因为它有额外逻辑。
    if slot then
-- ★★★ 四路分派起点。
-- ★★ `if new_item and not self.ignoresound then PushEvent("gotnewitem")` ——
-- ★★★ ★ 三重条件：
--   · new_item（1041 行算的）：既不在手上也不在装备槽上；
--   · not ignoresound：没静音；
-- ★★ 注意此时**还没真正放入**（只是决定放哪了），
--   但音效事件已发 —— 因为后续操作可能失败（1160 行）。
-- ★★ ★ 这是「先播音后操作」的顺序。
--   若 1160 行的 leftover 处理失败，音效已经播过了 —— 轻微不一致。
-- ★ data 里带 slot（1100 行），客户端据此播「掉进某格」的音。
-- ★ 交叉引用：inventory_replica 不监听 gotnewitem（只有 itemget/itemlose/equip），
--   ⇒ ★★ gotnewitem 是**纯本地事件**（服务端 PushEvent 给自己听）。
--   ★ 这解释了为什么它不需要 netvar 同步。
        if new_item and not self.ignoresound then
-- ★★★ gotnewitem 事件（纯本地，不同步）。
            self.inst:PushEvent("gotnewitem", { item = inst, slot = slot })
-- ★★★ gotnewitem 事件（★ 纯本地，不进 classified）。
        end
-- ↑ if 块结束。

-- ★★ leftovers —— 「没放进去的部分」。初始化为 nil。
-- ★★★ ★ 贯穿整个 1098-1164 行的核心变量：
--   每个分支都可能产生 leftovers（堆叠没装完的情况），
--   最后由 1159 行统一处理（递归 GiveItem）。
-- ★★ leftovers 非 nil 意味着「部分成功」，需要后续补投。
        local leftovers = nil
-- ↑ leftovers 初始化。
-- ★★ 分支①：目标是 overflow（背包本体）。
-- ★★ `if itemInSlot then` —— 该槽有东西（可合并）；
--   否则 `overflow:GiveItem(inst, nil, src_pos)` 直接交给容器处理。
-- ★★★ ★ 注意「空槽时委托」的设计（1109 行）：
--   overflow 是 container 组件，它有自己的 GiveItem，逻辑更复杂。
--   本文件不重复实现，而是**委托**。
-- ★★ ⇒ 这体现了「容器与背包的对称性」：
--   两者的 GiveItem 是同构的（可互相调用）。
-- ★★ 1110 行 return true —— 委托成功即返回。
        if overflow ~= nil and container == overflow then
-- ↑ 分支①：overflow。
            local itemInSlot = overflow:GetItemInSlot(slot)
-- ★ 取 overflow 目标槽的现有物品。
            if itemInSlot then
-- ★★ 槽有东西 → 合并。
                leftovers = itemInSlot.components.stackable:Put(inst, src_pos)
-- ★★ Put 的返回值即 leftovers。
            else
-- ★ else：槽为空。
                overflow:GiveItem(inst, nil, src_pos)
-- ★★★ 委托 overflow:GiveItem（★ 容器自己处理完整逻辑）。
                return true
-- ★★ 委托成功 → return true。
            end
-- ↑ if itemInSlot 块结束。
-- ★★★ 分支②：目标是专用容器（specialized）—— 本分支最复杂。
-- ★★★ 它包含一个**「自动打开」的子流程**（1113-1119 行）：
--   若容器没被打开、可以打开、且不是「掉落即开」或「可携带」的容器，
--   就先 Open(self.inst) 并生成一个 "container_closed_receiveitem_classified"。
-- ★★★ ★ 这个 classified prefab 的作用（1116-1118 行）：
--   在客户端显示一个「闭着的容器正在接收物品」的 UI 提示，
--   并把 container_transform 挂到容器上（1117 行 SetParent）。
-- ★★ 1118 行 `Network:SetClassifiedTarget(self.inst)` ——
--   ★★★ 只同步给 self.inst（该玩家），不广播给所有人。
--   ⇒ 这是**定向同步**：只有操作者的客户端能看到这个提示。
-- ★★★ ★ 这是「私有 UI 提示」的实现方式，值得学习。
-- ★★ 1114 行的三个排除条件：
--   · not IsOpenedBy(self.inst)：已经打开的不用再开；
--   · not container.canbeopened：不能自动开的（如背包本身）；
--   · not (droponopen or portablestorage)：
--     「掉落即开」或「可携带」的容器不该被自动打开。
		elseif specialized and table.contains(specialized, container) then
-- ↑ 分支②：专用容器（含自动打开流程）。
			local receiveitemonopen
-- ★★ UI 代理变量（nil = 不需要）。
			if not container:IsOpenedBy(self.inst) and container.canbeopened and not (container.droponopen or container.inst:HasTag("portablestorage")) then
-- ★★★★ 四重排除的「需要自动打开」判定。
				container:Open(self.inst)
-- ★★★ 自动打开容器（★ 副作用：真的打开了！）。
				receiveitemonopen = SpawnPrefab("container_closed_receiveitem_classified")
-- ★★ 生成「闭容器接收物品」的 classified prefab。
				receiveitemonopen.entity:SetParent(container.inst.entity)
-- ★ 挂到容器实体下（跟随移动）。
				receiveitemonopen.Network:SetClassifiedTarget(self.inst)
-- ★★★ Network:SetClassifiedTarget(self.inst) —— ★ 只同步给操作者。
-- ★★ receiveitemonopen —— 「正在接收物品」的 UI 代理（可能为 nil）。
-- ★★★ ★ 变量的生命周期：
--   1113 行初始化为 nil（默认不生成）；
--   1116-1118 行在「需要自动打开」时生成；
--   1123-1132 行用它填充内容（item + isstack）。
-- ★★ 若不需要自动打开，它保持 nil，1123/1129 行的 if 自然跳过。
-- ★★★ 这就是「零成本可选功能」的写法：
--   用 nil 代替布尔标志，简化分支。
			end
-- ↑ receiveitemonopen UI 代理（可为 nil）。
-- ↑ 自动打开块结束。
-- ★★ `local itemInSlot = container:GetItemInSlot(slot)` —— 查目标槽。
-- ★★ 与分支①的 1105 行同构，但用的是 container 的方法。
			local itemInSlot = container:GetItemInSlot(slot)
-- ↑ 查目标槽。
-- ★★ itemInSlot 存在 → 尝试堆叠合并。
-- ★★★ 1122 行 `leftovers = itemInSlot.components.stackable:Put(inst, src_pos)`
--   ★ 与 1107 行同构：Put 的返回值是「没装进去的」。
-- ★★ 1123-1126 行：若生成了 UI 代理，填充「堆叠中」状态：
--   receiveitemonopen.item:set(itemInSlot) —— 显示目标物品；
--   receiveitemonopen.isstack:set(true) —— 标记是堆叠合并。
-- ★★★ ★ 这就是客户端看到的「物品飞进容器里并与已有堆叠合并」的表现。
-- ★★ ★★ 注意：本分支**没有**像分支①那样在成功时 return！
--   而是继续走到 1159 行处理 leftovers，最后 1166 行 return slot。
--   ⇒ 语义差异：分支①的空槽路径「立即返回 true」，
--     而本分支统一返回 slot（数字）。
--   ★ 这是 1029 行注释里说的「返回值不统一」的又一处证据。
			if itemInSlot then
-- ↑ 槽内有物 → Put 合并。
				leftovers = itemInSlot.components.stackable:Put(inst, src_pos)
-- ★★ 合并路径的 leftovers（★ 本分支不立即 return）。
				if receiveitemonopen then
-- ★ 有 UI 代理才填内容。
					receiveitemonopen.item:set(itemInSlot)
-- ★ 显示目标物品（合并到的那一摞）。
					receiveitemonopen.isstack:set(true)
-- ★★★ isstack=true 标记「这是合并」。
				end
-- ↑ if receiveitemonopen 块结束。
-- ★★ itemInSlot 为空 → 委托 container:GiveItem。
-- ★★ 1129-1132 行填充 UI 代理（非堆叠状态）。
-- ★★★ 1133 行 `return true` —— **委托成功立即返回**。
-- ★★ 与分支①的 1110 行对称。
			else
-- ↑ 槽为空 → 委托 container:GiveItem。
				container:GiveItem(inst, nil, src_pos)
-- ★ 空槽路径：委托容器。
				if receiveitemonopen then
-- ★ 有 UI 代理才填。
					receiveitemonopen.item:set(inst)
-- ★ 显示物品本身。
					receiveitemonopen.isstack:set(false)
-- ★★★ isstack=false（非合并）。
				end
-- ↑ if receiveitemonopen 块结束。
				return true
-- ★★ 委托成功 → return true。
			end
-- ↑ if itemInSlot 块结束。
-- ★★ 分支③：目标是装备槽。
-- ★★★ ★ 注意这个分支**没有 else**（空槽的情况）！
--   只有 `if self.equipslots[slot] then` —— 有东西时才 Put 合并。
-- ★★★ ★★ 这意味着：**装备槽的「空槽」路径在这里什么都不做**！
--   1136 行的 if 不成立时，整个 if 语句块被跳过，
--   直接走到 1159 行（leftovers 为 nil）和 1166 行（return slot）。
--   ⇒ ★★ 结果：**物品没有真的被放进去**，但函数返回了槽号！
-- ★★★ ⚠ 这是一个真实的缺陷（见 L16）：
--   当 GetNextAvailableSlot 返回一个**空的装备槽**时，
--   GiveItem 会「声称成功但什么也没做」。
--   ★ 实际影响：GetNextAvailableSlot 只在 840 行返回装备槽，
--     而 840 行的条件要求 `not IsFull()` —— 即该装备槽**一定有东西**。
--   ⇒ 所以实际不会触发。这是「靠上游约束侥幸正确」的情况。
-- ★★ ★ 正确写法应该有 else 分支处理空槽装备（如 1139 那样的直接赋值）。
-- ★★★ 这说明 GetNextAvailableSlot 的返回约定（「装备槽只会返回非空槽」）
--   是一个**未被文档化的隐含契约**。
        elseif container == self.equipslots then
-- ↑ 分支③：装备槽（★ 无 else —— 见 L16）。
            if self.equipslots[slot] then
-- ★★ 装备槽有东西才处理（★ 空槽路径缺失 —— 见 L16）。
                leftovers = self.equipslots[slot].components.stackable:Put(inst, src_pos)
-- ★★ Put 合并。
            end
-- ↑ if equipslots[slot] 块结束。
-- ★★ 分支④：普通槽（itemslots）—— 最常见的情况。
-- ★★★ 三分支（1140-1152 行）：
--   ① 1141-1144 行 槽里有东西且**满了** → leftovers = inst（放不进去）；
--   ② 1146 行 槽里有东西但没满 → Put 合并；
--   ③ 1148-1152 行 槽是空的 → **直接赋值** + OnPutInInventory + itemget 事件。
-- ★★★ ★ 分支③是唯一「真正放入」普通槽的地方。
-- ★★★ ★★ 分支①为什么要清 prevcontainer/prevslot（1143-1144 行）？
--   因为「这个物品放不进这个槽」，所以它的「位置记忆」也失效了。
--   ⇒ 与 1081-1083 行的逻辑一致（失败即清记忆）。
-- ★★ ★ 1149 行 `self.itemslots[slot] = inst` —— 真正的写入点。
-- ★★ 注意：**没有**调 OnPickup（1055 行已经调过了）。
-- ★★★ 1150 行 OnPutInInventory —— 与 OnPickup 配对的回调。
--   inventoryitem.lua:344 的实现会处理湿气继承等。
-- ★★ 1151 行 PushEvent("itemget", {...}) —— 联机同步的关键事件！
--   inventory_replica.lua:23 → SetSlotItem(slot, item, src_pos)。
-- ★★★ ★★ 这是「普通槽放入」在客户端的**唯一**通知来源。
--   对比 1140 行的「合并到已有堆叠」—— **不发 itemget 事件**！
--   ⇒ ★★ 因为堆叠合并不改变槽位里的「实体」，
--     classified 的 dirty 监听（OnStackItemDirty）会自动处理数量变化。
--   ★ 这解释了为什么合并路径不需要显式事件。
-- ★ ★★ src_pos 也被传递了（用于客户端飞行动画起点）。
        else
-- ↑ 分支④：普通槽（唯一真正放入的地方）。
            if self.itemslots[slot] ~= nil then
-- ★★★ 普通槽有东西？
                if self.itemslots[slot].components.stackable:IsFull() then
-- ★★★ 已满 → 整个放不进去。
                    leftovers = inst
-- ★★ leftovers = inst（原物品）。
                    inst.prevcontainer = nil
-- ★★★ 清位置记忆（★ 与 1081 行同思想：放不进就忘掉）。
                    inst.prevslot = nil
-- ★★★ 同上，清槽记忆。
                else
-- ↑ else 分支。
                    leftovers = self.itemslots[slot].components.stackable:Put(inst, src_pos)
-- ★★ 没满 → Put 合并。
                end
-- ↑ if IsFull 块结束。
            else
-- ★★ else 分支：槽是空的（★ 唯一真正写入的路径）。
                self.itemslots[slot] = inst
-- ★★★★ self.itemslots[slot] = inst —— 实际写入点。
                inst.components.inventoryitem:OnPutInInventory(self.inst)
-- ★★ OnPutInInventory 回调。
                self.inst:PushEvent("itemget", { item = inst, slot = slot, src_pos = src_pos })
-- ★★★★ itemget 事件 —— 普通槽放入的联机同步点。
            end
-- ↑ if/else 块结束。

-- ★★ `if inst.components.equippable then ToPocket()` ——
-- ★★★ ★ 注意：分支①（overflow）与分支②（specialized）里
--   **没有**这个调用！只有分支④（普通槽）有。
-- ★★★ ⚠ 这是一个**真实的不一致**（见 L17）：
--   「把装备放进背包本体 / 专用容器」不会触发 onpocketfn，
--   「把装备放进普通槽」会触发。
--   ⇒ 后果：从背包本体里拿出装备时，onpocketfn 的调用次数不对称。
--   ★★ 推断：分支①委托给了 container:GiveItem，
--     容器内部的 GiveItem 自己会调 ToPocket（container.lua 里的对应逻辑）。
--   ★ 若如此则**不是** bug 而是「委托的间接调用」。
--   ★★ 但分支②（specialized）的委托也可能这样处理 ⇒ 推测无缺陷。
--     记录为「需核实」而非确定缺陷。
            if inst.components.equippable then
-- ↑ ToPocket（★ 仅此分支有 —— 见 L17）。
                inst.components.equippable:ToPocket()
-- ★ ToPocket（★ 仅此分支有 —— 见 L17）。
            end
-- ↑ if equippable 块结束。
        end
-- ↑ else 分支结束。

-- ★★★ leftovers 的统一处理（1159-1164 行）。
-- ★★★ `if leftovers then ... self:GiveItem(leftovers)` —— **递归调用**！
-- ★★ ★ 递归深度：理论上可以很深（每层产生一个 leftover）。
--   实际收敛：leftovers 是「没装下的部分」，再 GiveItem 时
--   会找下一个可容纳的位置，所以通常 1-2 层就收敛。
-- ★★★ 1160-1163 行的双重条件：`if not self:GiveItem(leftovers) and self.ignorefull`
--   · 先无条件 GiveItem（递归）；
--   · 若失败**且** ignorefull 为真 → `return false`（明确失败）。
-- ★★★ ★ 注释写着 "Hack: should only reach here when moving items between
--   containers" —— 作者承认这是搬运场景专用的。
-- ★★★ ★⚠ 但**没有前置校验**：非搬运场景也会走到这里。
--   若递归 GiveItem 也失败（背包真的满了），leftovers 会被
--   1178 行的兜底处理（塞手上或丢地上）。
--   ⇒ 在搬运场景下：物品可能被丢在地上（见 L4）。
        if leftovers then
-- ★★★ leftovers 递归处理。
            if not self:GiveItem(leftovers) and self.ignorefull then
-- ★★★★ `not GiveItem and ignorefull` —— 短路：先无条件递归。
                --Hack: should only reach here when moving items between containers
-- ↑ 原英文注释保留（Hack: moving between containers）。
                return false
-- ★★ 明确失败（★ 搬运场景专用）。
            end
-- ↑ if 块结束。
        end
-- ↑ if leftovers 块结束。

-- ★★ `return slot` —— ★★★ **返回槽号（数字）而非 true**。
-- ★★★★ 这是「返回值不统一」的核心证据（见 1029 行注释）。
-- ★★ 后果：调用方不能假设返回布尔。
-- ★★★ ★★ 特别注意：**即使东西没真正放进去也返回 slot**
--   （见 1135 行分支③的分析）。
-- ★★ 对比 1168 行的 `return true`（overflow 兜底路径）—— 同一函数
--   两种返回风格。这给调用方制造了真实的歧义。
        return slot
-- ★★ return slot（★ 返回数字不是 true）。
-- ★★ `elseif overflow ~= nil and overflow:GiveItem(inst, nil, src_pos, false)` ——
-- ★★★★ 兜底①：再试一次 overflow。
-- ★★★ ★ 注意第四个参数 `false` —— 查 container.lua 的签名：
--   `container:GiveItem(item, slot, src_pos, ignoreeverything)`。
--   false = 不忽略任何东西（正常判定）。
-- ★★★ ★ 为什么这里会有冗余重试？（见 L10）
--   因为 1095 行的 GetNextAvailableSlot **已经**考虑了 overflow，
--   若它没返回 overflow 的槽，说明 overflow 里没有可用位置了。
--   ⇒ 这一行理论上**永远不会成功**。是纯冗余（但也无害）。
-- ★★ 它的真正价值可能是**兜底防御**：
--   若 GetNextAvailableSlot 因为某种原因漏掉了 overflow，这里能救。
-- ★★★ ★ 注意它成功时 `return true`（不是槽号）—— 第三次不一致。
    elseif overflow ~= nil and overflow:GiveItem(inst, nil, src_pos, false) then
-- ★★★★ 兜底①：再试 overflow（理论上永不成功 —— 见 L10）。
        return true
-- ★★★ return true（★ 第三种返回风格：不是槽号）。
    end
-- ↑ if overflow 兜底块结束。

-- ★★ `if self.ignorefull then return false end` —— 兜底②的提前退出。
-- ★★★ ★ 这就是 ignorefull（42 行）的兑现点：
--   「假装没满」= 满时不走任何兜底，直接失败。
-- ★★ 1176 行的 returnvalue 初始化为 false ——
--   ★★ ★ 注意：**兜底③-⑥ 即使执行了也不一定返回 true**！
--   只有 1186 行（塞 activeitem）和 1205 行（合并）才设 true。
--   ⇒ 1208 行的 DropItem 分支**不设 returnvalue** ⇒ 返回 false。
-- ★★ ★★★ 语义：「物品掉地上了」被报告为「GiveItem 失败」。
--   这在语义上是**正确**的（东西确实没进背包），
--   但对调用方是个陷阱：它需要自己检查物品是否还在。
    if self.ignorefull then
-- ★★★ 兜底②：ignorefull → 明确失败。
        return false
-- ★★★ return false（★ ignorefull 时明确失败）。
    end
-- ↑ if ignorefull 块结束。

    --can't hold it!
-- ★★ 原英文注释保留（can't hold it!）。
-- ★★ `local returnvalue = false` —— 最终返回值（默认失败）。
-- ★★ ★ 它会在 1186（塞手上）或 1205（合并进手上）时被设为 true。
    local returnvalue = false
-- ↑ returnvalue 初始化。
-- ★★ shouldwisecrack —— 「要不要播『背包满』提示」。
-- ★★★ ★ 它在 1206 行会被置 false（合并路径不播），
--   1213 行据此决定是否 PushEvent("inventoryfull")。
-- ★★ 命名里的 crack 是「裂开」的拟声词（背包裂了放不下）。
-- ★★ ★ 1213 行的三重排除：`not (isloading or silentfull) and maxslots > 0`。
--   ① isloading：读档时不播；
--   ② silentfull：内部重排时不播（1344 等行置位）；
--   ③ maxslots > 0：非玩家实体（无背包）不播。
-- ★★ ★⇒ 「背包满」的精确语义：**普通槽满 + 没有兜底成功 + 非内部操作**。
    local shouldwisecrack = true
-- ↑ shouldwisecrack 初始化。
-- ★★★★ 兜底③：塞进 activeitem（1178-1186 行）—— ★ 最重要的兜底。
-- ★★★ 四重条件：
--   ① self.activeitem == nil —— **手上是空的**；
--   ② self.maxslots > 0 —— 这是「有背包」的实体（排除怪物等）；
--   ③ ValidateItemForOverflow(inst, self) —— 物品资格允许；
--   ④ not (playercontroller and isclientcontrollerattached) ——
--     ★★★ 见下方详解。
-- ★★★ ★★ 条件①是这个分支能生效的**关键**：
--   手上已经有东西时，这个分支不执行，会落到 1190 或 1208 行。
-- ★★★ ★★ 条件③传的是 **self**（不是 overflow）——
--   ★ 注意 ValidateItemForOverflow(item, overflow) 的第二参数是「目标容器」；
--     传 self.items Inventory 是因为「手上」等价于「自己的口袋」，
--     用 804 行的 canonlygoinpocket 判定最合适。
-- ★★★★ 条件④的详解（★ 联机安全的核心）：
--   `not (self.inst.components.playercontroller ~= nil and
--     self.inst.components.playercontroller.isclientcontrollerattached)`
--   ⇒ 语义：「服务端不要主动往 activeitem 里塞东西」。
-- ★★★ ★ 推理：activeitem 在客户端是**预测状态**——
--   玩家按「使用」键时客户端会**立即**把物品设为 activeitem（预测），
--   服务端稍后确认。若服务端此时也塞一件到 activeitem，
--   两者会打架（客户端以为是 A，服务端塞了 B）。
-- ★★★ ★★ 所以：**当客户端控制器已挂载（正在玩）时，
--   服务端不再自动占用 activeitem**，避免预测冲突。
--   ⇒ ★ 这解释了 HEADER_EXTRA 第 3 条的机制：
--     「背包满了物品仍能拿在手上」在**离线/服务器端**成立，
--     但在**玩家操作中**由客户端预测负责。
-- ★★ 交叉引用：playercontroller.lua 的客户端预测逻辑。
    if self.activeitem == nil and
-- ★★★★ 兜底③：塞进 activeitem（四重条件）。
        self.maxslots > 0 and
-- ★★ 条件②：有背包（排除怪物）。
		ValidateItemForOverflow(inst, self) and
-- ★★ 条件③：物品有资格进口袋。
        not (self.inst.components.playercontroller ~= nil and
-- ★★★★ 条件④：服务端未在客户端控制中（★ 见 BEFORE 详解）。
            self.inst.components.playercontroller.isclientcontrollerattached) then
-- ★↑ 条件④的续行。

-- ↑ 四重条件块结束。
-- ★★ OnPutInInventory —— 与 1150 行同款（放入的回调）。
-- ★★ ★ 注意这里**没有** PushEvent("itemget")！
--   ⇒ ★★ 与 1151 行不同：塞进 activeitem **不发** itemget 事件。
-- ★★★ ★ 那客户端怎么知道？—— 靠 1020 行的模式？不对，
--   1012 行 GiveActiveItem 才发。这里是 GiveItem 的兜底。
-- ⚠ ★★★ 这意味着「背包满时手上多了件东西」这个状态变化，
--   **可能没有同步到客户端**！
--   推理：inventory_replica 的 classified 只有「槽位」和「activeitem」
--   两个概念，itemget 是槽位事件。塞 activeitem 需要 newactiveitem。
-- ★★★ ★⚠ 但 1185 行 SetActiveItem(inst) 会 PushEvent("newactiveitem")
--   （1256 行）—— ★★★ **这就够了**！
--   ⇒ 所以是**正确的**：itemget 不需要，newactiveitem 才是。
-- ★★ 这解释了 1020 行为什么用 slot=nil 发 itemget ——
--   那是「物品从某处进入物品栏」的通用通知。
        inst.components.inventoryitem:OnPutInInventory(self.inst)
-- ↑ OnPutInInventory。
        self:SetActiveItem(inst)
-- ★★★ SetActiveItem → 物品拿在手上（★ 背包满也不丢）。
        returnvalue = true
-- ★★ 宣告成功。
-- ★★ 兜底④：HandleLeftoversFn 钩子。
-- ★★★ ★ 这是一个**实例字段上的自定义回调**（构造函数未初始化）。
-- ★★ 语义：「物品放不下时，让容器自己决定怎么办」。
-- ★★★ 典型用途：某些特殊 inventory（如商店）拒绝交易时
--   把物品退还给玩家而不是丢地上。
-- ★★ 签名：(self.inst, inst) —— 持有者 + 无处可去的物品。
-- ★★ ★ 注意：**这个钩子存在时，兜底⑤⑥ 完全不执行**
--   （是 elseif 链）。⇒ 钩子负全部责任。
    elseif self.HandleLeftoversFn ~= nil then
-- ★★ 兜底④：HandleLeftoversFn 钩子（完全接管）。
		self.HandleLeftoversFn(self.inst, inst)
-- ★★ 自定义处理钩子（★ 完全接管，不再往下走）。
	else
-- ↑ elseif 块结束。
-- ★★★ 兜底⑤：合并进现有 activeitem（1190-1206 行）。
-- ★★★ 五重条件：
--   · self.activeitem 存在且**不等于** inst；
--   · activeitem 可堆叠；
--   · inst 可堆叠；
--   · CanStackWith —— 同类；
--   · activeitem **没满**（not IsFull）。
-- ★★★ ★ 这是「手上有一摞能装的」的最后一个希望。
-- ★★ 1196 行 `Put(inst, self.inst:GetPosition())` ——
--   ★★★ 注意第二个参数是**坐标**（self.inst:GetPosition()），
--     而其他地方（1107/1122/1146 行）传的是 **src_pos 对象**。
--   ★★★ ⚠ 这是一个**类型不一致**（见 L18）：
--     stackable:Put 的第二参数在不同调用点传了不同类型。
--     推理：若 Put 内部对 src_pos 调用 :Get()，传坐标会崩。
--     ★ 需核实 stackable.lua 的 Put 签名。
-- ★★ 1198-1202 行的 silentfull 包裹（防止播「背包满」）。
-- ★★ ★ 1204 行 PushEvent("gotnewitem", { toactiveitem = true }) ——
--   ★★★ 注意 toactiveitem=true 而没有 slot —— 这是「合并进手上」的专用标记。
--   ⇒ 客户端据此播「东西到手上了」的表现。
-- ★★ 1205 行 `returnvalue = true` —— 终于成功。
-- ★★ 1206 行 `shouldwisecrack = false` —— 不播「背包满」。
        if self.activeitem and self.activeitem ~= inst and
-- ★★★ 兜底⑤：合并进现有 activeitem。
            self.activeitem.components.stackable and
-- ★★ 条件②：手上那摞可堆叠。
            inst.components.stackable and
-- ★ 条件③：新物品可堆叠。
            inst.components.stackable:CanStackWith(self.activeitem) and
-- ★ 条件④：同类。
            not self.activeitem.components.stackable:IsFull()
-- ★ 条件⑤：手上那摞没满。
        then
-- ↑ 五重条件块结束。
            local leftovers = self.activeitem.components.stackable:Put(inst, self.inst:GetPosition())
-- ★★★ Put（★ 第二参传坐标而非 Vector3 —— 见 L18）。

            if leftovers ~= nil then
-- ★ 有溢出部分（手上装不下全部）。
                self.silentfull = true
-- ★★ 静音包裹开始（★ 抑制「背包满」提示）。
                self:GiveItem(leftovers)
-- ★★ 递归给溢出部分。
                self.silentfull = false
-- ★★ 静音包裹结束（★ 无异常机制 ⇒ 泄漏风险 L9）。
            end

-- ↑ if leftovers 块结束。
            self.inst:PushEvent("gotnewitem", { item = inst, toactiveitem = true, })
-- ★★★ gotnewitem（★ toactiveitem=true 标记「到手上了」）。
            returnvalue = true
-- ★★ 宣告成功。
            shouldwisecrack = false
-- ★★★ shouldwisecrack = false（★ 不播「背包满」）。
        else
-- ↑ else 分支。
-- ★★★ 兜底⑥：丢到地上（1208-1211 行）—— **最后手段**。
-- ★★ `if self.HandleLeftoversShouldDropFn == nil or ...(...) then` ——
--   ★★★ 另一个钩子：决定「**是否应该**丢地上」。
--   · nil（未设置）→ 丢；
--   · 返回 false → **不丢**（留给调用方处理！）。
-- ★★ ★ 这与 HandleLeftoversFn（1187 行）是**两个不同的钩子**：
--   · HandleLeftoversFn = 「完全接管处理」；
--   · HandleLeftoversShouldDropFn = 「只否决丢地上这一步」。
-- ★★★ 「否决后不丢」的后果：物品处于**无处安放**状态，
--   它仍在调用方手里（可能是 activeitem 或还没归属任何栏）。
--   ⇒ ★★ 这是给「这台机器不接受这个物品」的场景留的出口。
-- ★ 1209 行 `self:DropItem(inst, true, true)` —— 整摞、随机方向。
-- ★★ 注意 returnvalue **不设为 true** —— 报告「失败」。
            if self.HandleLeftoversShouldDropFn == nil or self.HandleLeftoversShouldDropFn(self.inst, inst) then
-- ★★★ 兜底⑥：丢地上（HandleLeftoversShouldDropFn 可否决）。
                self:DropItem(inst, true, true)
-- ★★★ 最后手段：丢到地上（★ returnvalue 仍是 false）。
            end
-- ↑ if 块结束。
        end
-- ↑ else 块结束。
    end
-- ↑ elseif 链结束。
-- ★★★ 「背包满」提示（1213-1215 行）。
-- ★★ 条件：shouldwisecrack 且 非 loading 且 非 silentfull 且 maxslots > 0。
-- ★★★ ★★ 1214 行 PushEvent("inventoryfull", { item = inst }) ——
--   这是玩家听到「背包已满」提示音的来源。
-- ★★ ★ inventoryreplica **不监听** inventoryfull ——
--   ⇒ 它是纯本地事件（服务端自己播）。
-- ★★ 与 gotnewitem 同理：不需要 netvar。
-- ★★ ★★ 注意：1213 行的 if 之后**缩进不对**（第 1214 行没有额外缩进），
--   但 1215 行的 end 正确配对。Lua 不在意缩进。
-- ★★ ★★ 重要：只有走到 1216 行才 return，但 1213-1215 的提示
--   在 returnvalue 为 true 的路径上也会执行！
--   ⇒ 也就是说「塞进了手上」（1186 行）之后，
--     若 shouldwisecrack 仍为 true（1186 分支没有置 false）
--     会**同时**播「背包满」。
--   ⚠ 这是一个轻微的不一致（见 L19）：塞手上成功却提示背包满。
--   ★ 玩家体验：东西拿在手上但听到「背包满」—— 其实合理（确实满了）。
    if shouldwisecrack and not (self.isloading or self.silentfull) and self.maxslots > 0 then
-- ★★★ 「背包满」提示（三重排除）。
    self.inst:PushEvent("inventoryfull", { item = inst })
-- ★★★ inventoryfull 事件（★ 纯本地，玩家听到的提示音）。
    end
-- ↑ if 块结束。
    return returnvalue
-- ★★ return returnvalue（★ 可能 false 即使东西已落地 —— 见 L19）。
end
-- ↑ GiveItem 结束。

-- 【§十一】★ Unequip —— 「从装备槽取下」。
-- ★★ 三参数：equipslot（槽名）、slip（是否被挤掉）、force（强行）。
-- ★★★ ★ 本函数的核心设计：**总是把槽清空并派发事件**，
--   唯一的提前退出是 1224 行的 preventunequipping 保护。
-- ★★ ★ 重要：Unequip **不负责安置物品**。
--   它只负责「取出」，由调用方决定 GiveItem / DropItem / 放手上。
-- ★★ ★ 这是与 713 行 RemoveItemBySlot 相同的「只取不放」风格。
-- ★★ ★★ 与 Equip（1266 行）对照，Unequip 简单得多：
--   · 无 prevslot/prevcontainer 处理；
--   · 无溢栈拆分；
--   · 无旧物品安置（那是 Equip 负责的）。
--   ⇒ ★ Equip 承担了「换装时旧物品去哪」的复杂逻辑。
function Inventory:Unequip(equipslot, slip, force)
-- ↑ Unequip 函数头（三参数）。
-- ★ local item = self.equipslots[equipslot] —— 取该槽的物品。
-- ★★ 1221 行的 print 被注释掉了 —— 「Inventory:Unequip」调试点。
-- ★ ★★ 注意：item 为 nil 时，整个 1222-1238 块被跳过，
--   直接执行 1240 行（清空，本就是空的）和 1241 行（派发事件）。
--   ⇒ ★★★ 空槽 Unequip **也会派发 "unequip" 事件**（item=nil）！
--   这可能让监听者困惑（收到一个 item 为 nil 的 unequip）。
--   ★ 推断：监听者（inventory_replica:26）只取 data.eslot，忽略 item。
--     所以无害。
    local item = self.equipslots[equipslot]
-- ↑ 取该槽物品。
    --print("Inventory:Unequip", item)
-- ↑ 被注释掉的调试 print（★ 常用于排查「Unequip 没触发」）。
    if item ~= nil then
-- ★★ 有东西才处理。
-- ★★ `if item.components.equippable ~= nil then` —— 只对有组件的做处理。
-- ★★ ★ 1224 行的 preventunequipping 保护（唯一的提前退出）：
--   `if not force and ShouldPreventUnequipping() then return nil` ——
--   ★★★ ★ force=true 时**跳过**保护（强行卸下）。
--   ★★★ ★ 这是 force 参数唯一的用途，非常明确。
-- ★★ ★★★ ⚠ 注意这个 return **跳过了 1240-1245 行**！
--   ⇒ 提前退出时：槽保持不变（正确），但也不会：
--     · 派发 "unequip" 事件（1241）；
--     · 更新 setbonus（1244）。
--   ★ 这是正确的（什么都没发生）。
        if item.components.equippable ~= nil then
-- ↑ equippable 分支起点。
			if not force and item.components.equippable:ShouldPreventUnequipping() then
-- ★★★ preventunequipping 保护（force 可绕过）。
                return nil
-- ★★★ 锁定装备 → 拒绝卸下（★ 返回 nil 而非 false）。
            end
-- ★ 早退。
-- ★★★ `item.components.equippable:Unequip(self.inst)` —— 触发卸装回调。
-- ★★ ★★★ **⚠ 这里不传 slip**（对比 1219 行接收了 slip 参数）！
--   equippable.lua:115 Unequip(owner) 的签名也只有 owner。
--   ⇒ ★★ slip 在本函数里被接收（1224 行用了？否！）——
--     ★ grep 核实：slip 只在 1241 行的 PushEvent 里用了，
--       **onunequipfn 拿不到 slip**。
--   ★★ 这是一个**接口缺口**（详见 equippable.lua:31 处的分析）。
--   ⇒ 后果：无法实现「因负重而被挤掉时物品要特殊处理」的回调。
-- ★★ 1228-1231 行的 overflow 特判：
--   若卸下的正是 overflow（背包），派发 "setoverflow" 空事件。
--   ★ 1364-1371 行装备时会派发带 overflow 参数的同名事件。
--   ⇒ ★★★ 这是一对「设置/清空 overflow」的握手事件。
--   ★ 消费方：inventory_replica 或 HUD（决定是否显示背包 UI）。
            item.components.equippable:Unequip(self.inst)
-- ★★★ Equip 回调（★ 不传 slip —— 接口缺口）。
            local overflow = self:GetOverflowContainer()
-- ★ 取 overflow（用于判断是否卸的是背包）。
            if overflow ~= nil and overflow.inst == item then
-- ★★ 卸下的正是 overflow？
                self.inst:PushEvent("setoverflow", {})
-- ★★★ PushEvent("setoverflow", {}) —— ★ 空表 = 「清空背包引用」。
            end
-- ↑ if 块结束。
        end
-- ↑ if equippable 块结束。
-- ★★ BODY 槽的特殊处理（1233-1237 行）：
--   · BODY → heavylifting = false（卸下重物不再负重）；
--   · HANDS → floaterheld = nil（卸下钓鱼竿不再漂浮）。
-- ★★★ ★ 这两个字段是 24/28 行 setter 同步的源头的**清理端**。
-- ★★ 1372/1374 行是设置端。四处配对。
-- ★★★ 注意这里**不触发 setter 的 nil 保护**：
--   `self.floaterheld = nil` 会让 onfloaterheld 收到 nil，
--   而 29 行 `SetFloaterHeld(floaterheld or false)` 会转成 false。
--   ⇒ ★ 安全（replica 侧是 bool netvar，不能是 nil）。
-- ★★ 但 1234 行 heavylifting = false 是布尔，安全。
-- ★ ★★ 这两行是「卸下装备的反向副作用」，与 equippable 的 onunequipfn
--   是**并行**机制：一个在 Inventory 层，一个在装备层。
        if equipslot == EQUIPSLOTS.BODY then
-- ↑ BODY/HANDS 的副作用清理。
            self.heavylifting = false
-- ★★ BODY → 取消负重。
		elseif equipslot == EQUIPSLOTS.HANDS then
-- ★ elseif 分支。
			self.floaterheld = nil
-- ★★ HANDS → 取消漂浮（★ 置 nil 而非 false）。
        end
-- ↑ if/elseif 块结束。
    end
-- ↑ if item 块结束。

-- ★★★ `self.equipslots[equipslot] = nil` —— 清空槽位。
-- ★★ ★ 无论 item 是否为 nil 都执行（1222 的 if 不控制这行）。
--   ⇒ ★ 空槽 Unequip 也会走到这里（无害）。
-- ★★ ★★ 注意这行在 1222 的 if 块**外面**（缩进层级：函数体第一层）。
--   ⇒ 即使 item 没有 equippable 组件，槽也会被清空。
-- ★★★ 这是**必须的**：如果槽里的东西不认 equippable，
--   也不能永远卡在装备槽里。
    self.equipslots[equipslot] = nil
-- ★★★ 清空槽位（在 if 块外）。
-- ★★★ PushEvent("unequip", { item, eslot, slip }) —— 联机同步点。
-- ★★ ★ inventory_replica.lua:26 监听 → `SetSlotEquip(data.eslot)`
--   （**不传 item** = 清空装备槽）。
-- ★★★ ★★ 这是「装备槽清空」在客户端的唯一通知来源。
-- ★★ 与 equippable.lua:122 的 PushEvent("unequipped") 是**两套事件**：
--   · "unequipped"（equippable）—— 只有 owner，物品自身逻辑用；
--   · "unequip"（inventory）—— 带 eslot + slip，UI 与同步用。
-- ★★★ ⇒ ★ 两个事件在同一函数里连续派发（1227 与 1241），
--   监听者必须知道该听哪个。
-- ★★ ★★ slip 字段在这里**第一次也是唯一一次**被传出 Unequip 函数体，
--   ⇒ 见 1227 行的接口缺口分析。
-- ★★ onunequipfn 已经调过了（1227 行），setbonus 还没（1243 行）。
-- ★★★ 事件顺序：unequipped → unequip → setbonus 更新。
--   ⇒ 监听 "unequip" 时 setbonus 尚未更新。
    self.inst:PushEvent("unequip", {item=item, eslot=equipslot, slip=slip})
-- ★★★ unequip 事件（联机同步点，带 slip）。

-- ↑ 空行。
-- ★★ setbonus（套装加成）—— 卸下时关闭效果。
-- ★★★ ★ 只有带 setbonus 组件的物品才有（如护甲套装）。
-- ★★ `UpdateSetBonus(self, false)` —— false = 卸下。
-- ★★ 136-138 行 Equip 时会用 true 更新（1383 行）。
-- ★★★ ★ 成对关系：Equip→UpdateSetBonus(inv, true)，
--   Unequip→UpdateSetBonus(inv, false)。
-- ★★★ ★ 注意这里在 1240 清空槽**之后**：
--   ⇒ UpdateSetBonus 内部遍历 equipslots 时，已经看不到这件装备。
--   ★★ 推断：setbonus 的实现是「重新计算整个套装」，而非「加/减单项」。
--   ⇒ ★ 这是「幂等重算」而非「增量更新」，更健壮。
    if item ~= nil and item.components.setbonus ~= nil then
-- ↑ setbonus 更新（槽已清空后）。
        item.components.setbonus:UpdateSetBonus(self, false)
-- ★★ setbonus 关闭（★ 槽已清空后调用 ⇒ 看不到自己）。
    end
-- ↑ if setbonus 块结束。

    return item
-- ★★ return item（★ 锁住时返回 nil，正常时返回原实体）。
end
-- ↑ Unequip 结束。

-- 【§十一】★ SetActiveItem —— 「设置手上物品」。
-- ★★★ ★ 四种情形（1250-1263 行）：
--   ① item 有 islockedinslot → assert + 拒绝（1251-1253）；
--   ② item == nil → 清空（1254 的第一个分支）；
--   ③ item 可进容器 → 正常设置（1254 的第二个分支）；
--   ④ item 不可进容器 → **丢到地上**（1262）。
-- ★★★ ★ 这是「设置手上物品」的**总闸门**，所有路径都经过它。
-- ★★ ★ 1262 行的兜底很关键：不允许拿的东西
--   **不是静默失败，而是丢地上**。
--   ⇒ ★ 与 GiveItem 的兜底逻辑一致（不吞物品）。
function Inventory:SetActiveItem(item)
-- ↑ SetActiveItem 函数头（四种情形）。
-- ★★ 锁定物品不能设为手上 —— 1252 行 assert（见 L6）。
-- ★★★ ★ 注意：这里 assert 之后是 **return**（不是错误提示）。
--   ⇒ dev 版崩、生产版静默忽略。
-- ★★★ ★ 为什么锁定物品不能拿在手上？
--   因为它「必须留在原槽」（如任务物品/传送锚点）。
-- ★★ 1254 行的双分支：`item == nil or item.components.inventoryitem.cangoincontainer`
--   ★★★ 注意这里**没有**检查 `item and`（与 1251 不同）——
--     因为 `item == nil` 是第一个条件，短路保护了后半段。
--   ★ 这是「用 == nil 做短路前置」的合法写法（Lua 的 == 不会崩）。
	if item and item.components.inventoryitem.islockedinslot then
-- ↑ 锁定物品 assert。
		assert(BRANCH ~= "dev")
-- ★★ assert（见 L6）。
		return
-- ★ 静默返回（★ 不改变任何状态）。
	elseif item == nil or item.components.inventoryitem.cangoincontainer then
-- ↑ if 块结束。
-- ★★ `self.activeitem = item` —— 真正的赋值点。
-- ★★ ★ 不论 item 是 nil 还是实体，都执行这行。
-- ★★★ 1256 行 PushEvent("newactiveitem", {item = item}) ——
--   inventory_replica.lua:22 监听 → classified:SetActiveItem(data.item)。
-- ★★ ★★★ 这是「手上物品」在网络层的**唯一**同步点。
--   ⇒ ★★★ 客户端的 activeitem 完全依赖这个事件。
-- ★★ 1258-1260 行：若物品有 onactiveitemfn 钩子则调用。
--   ★ 这是 inventoryitem 的扩展点（inventoryitem.lua 的 onactiveitemfn）。
--   ★★ 与 equippable 的 ToPocket 不同：这里不检查 equippable 组件，
--     而用 inventoryitem 的专属钩子。分层清晰。
        self.activeitem = item
-- ↑ 真正的赋值点。
        self.inst:PushEvent("newactiveitem", {item=item})
-- ★★★★ newactiveitem 事件 —— 手上物品的联机同步点。

-- ★★ onactiveitemfn —— 「成为手上物品」的钩子。
-- ★★★ 三重保护：item 非 nil + 有 inventoryitem + 有 onactiveitemfn。
-- ★★ 这是 inventoryitem 组件的字段（非 equi ppable）。
--   签名 (item, owner) —— 与 equippable 的 onpocketfn 类似的「回传自身」。
-- ★★★ ★ 效果举例：某些物品在手上会显示 UI 指示器。
        if item and item.components.inventoryitem and item.components.inventoryitem.onactiveitemfn then
-- ↑ onactiveitemfn 钩子。
            item.components.inventoryitem.onactiveitemfn(item, self.inst)
-- ★ onactiveitemfn 钩子调用。
        end
-- ↑ if 块结束。
    else
-- ↑ else 分支。
-- ★★ `else self:DropItem(item, true, true)` —— 不可拿的东西丢地上。
-- ★★★ ★ 注意：**没有 PushEvent("newactiveitem")**。
--   ⇒ activeitem 保持原值（没被改成这个不可拿的物品）。
--   ★ 这是正确的：先检查再赋值，避免「设了又撤销」的闪烁。
-- ★★ wholestack=true, randomdir=true —— 与 GiveItem 的兜底一致。
        self:DropItem(item, true, true)
-- ★★ 不可拿的东西 → 丢地上（不发 newactiveitem）。
    end
-- ↑ else 块结束。
end
-- ↑ SetActiveItem 结束。

-- 【§十一】★★★ Equip —— 「装备一件物品」。全文件第二复杂的函数。
-- ★★★ 三参数：item、old_to_active（换下旧装备给手上）、
--   no_animation（不播动画）、force_ui_anim（强制 UI 动画位置）。
-- ★★★★ 十二个步骤：
--   ① 1267-1274 行 准入检查（五重，见下）；
--   ② 1277-1281 行 确定槽位与旧物品、保护旧装备；
--   ③ 1286-1302 行 **记录 prevslot/prevcontainer**（位置记忆）；
--   ④ 1304-1321 行 **重物互斥**（BODY 与 HANDS 不能同时有 heavy）；
--   ⑤ 1324-1332 行 从原位置取出（手拆堆叠）；
--   ⑥ 1334-1337 行 若是从手上拿的，先取出；
--   ⑦ 1339-1348 行 安置拆分出来的 leftovers；
--   ⑧ 1349-1362 行 **安置旧装备**（最复杂）；
--   ⑨ 1364-1366 行 真正装备（写入 equipslots）；
--   ⑩ 1368-1375 行 BODY/HANDS 的副作用（overflow/heavylifting）；
--   ⑪ 1377-1380 行 派发 equip 事件 + 统计；
--   ⑫ 1382-1384 行 套装效果更新。
-- ★★★ ★ 与 Unequip 的对照：Unequip 30 行，Equip 120 行。
--   原因：「穿上去」涉及换装（旧的去哪）、堆叠拆分、溢出、副作用。
function Inventory:Equip(item, old_to_active, no_animation, force_ui_anim)
-- ★★★★ Equip 函数头（12 个步骤）。
-- ★★★★★ 准入检查（1267-1274 行）—— 五重 or 条件：
--   ① item == nil；
--   ② 没有 equippable 组件；
--   ③ item 已失效；
--   ④ **受限装备**（不是读档时用 IsRestricted_FromLoad）；
--   ⑤ self.noheavylifting 且 item 有 "heavy" 标签。
-- ★★★ ★★ 第④条的细节（1270 行）—— ★★★ 双路径判定：
--   `(not self.isloading and IsRestricted(self.inst))
--    or (self.isloading and IsRestricted_FromLoad(self.inst))`
--   · 正常路径 → 严格判定；
--   · 读档路径 → 宽松判定（技能树标签例外，见 equippable.lua:164）。
-- ★★★ ★ 这与 OnLoad（293 行）设置的 isloading 标志配合：
--   读档时的装备不能因为「角色还没升级完」而被拒绝。
-- ★★★ ★★ 全条件用 or 连接，任一成立就 return（无返回值 = nil）。
-- ★★ ⚠ 注意返回的是 **nil 而非 false**（见 L5）。
-- ★★★ 条件⑤的 noheavylifting：字段未初始化（64 行注释掉了），
--   所以默认为 nil（falsy）⇒ 该条件默认不成立。
--   ⇒ ★ 「禁止负重」的实体可以设 self.noheavylifting = true 来禁用 heavy 装备。
    if item == nil or
-- ★★★★★ 五重准入检查（含 isloading 双路径）。
        item.components.equippable == nil or
-- ★★ 准入条件②：没有 equippable 组件。
        not item:IsValid() or
-- ★ 条件③：实体已失效。
        (not self.isloading and item.components.equippable:IsRestricted(self.inst) or self.isloading and item.components.equippable:IsRestricted_FromLoad(self.inst)) or
-- ★★★★ 条件④：受限装备（★ isloading 双路径）。
        (self.noheavylifting and item:HasTag("heavy"))
-- ★ 条件⑤：禁负重实体 + heavy 标签。
    then
-- ↑ or 链结束。
        return
-- ★★★ 任一成立 → return（★ 无返回值 ⇒ nil，见 L5）。
    end
-- ↑ 准入检查块结束。
    -----
-- ↑ 注释分隔线（★ 作者用来分段）。
    
-- ↑ 空行。
-- ★★★ `local eslot = item.components.equippable.equipslot` —— 目标槽。
-- ★★ ★ 槽名来自**物品自身**的组件，不是调用方指定。
--   ⇒ ★★★ 「这个物品能穿哪」是**物品的固有属性**。
-- ★★ ★ 呼应 equippable.lua:29 的坑：若 prefab 直接赋值 equipslot
--   （绕过 setter），客户端会显示错位。这里读的是同一个字段。
-- ★★ 1278 行 `local olditem = self.equipslots[eslot]` —— 该槽原有物品。
    local eslot = item.components.equippable.equipslot
-- ↑ 目标槽来自物品自身。
    local olditem = self.equipslots[eslot]
-- ★★ 取该槽原有物品。
-- ★★ 1279-1281 行：旧装备的「粘住」保护。
-- ★★★ ★ `if olditem ~= nil and ShouldPreventUnequipping() then return` ——
--   ★★★ 这里**没有 force 参数**！Equip 的签名里有 force_ui_anim，
--     但**没有** force（用于绕过 preventunequipping）。
--   ⇒ ★★ 结论： Equip 无法强行替换「粘住」的装备。
--   ★★ 与 Unequip 的第三个参数 force 形成不对称：
--     Unequip 有 force（可强行卸），Equip 没有。
--   ⇒ ★ 若某件装备不可卸且已穿着，**无法替换它**。
--   ★★★ 这在实践中很少见（preventunequipping 通常是临时 buff），
--     但它是一个**明确的能力缺口**。
-- ★★ ⚠ 返回 nil（不设返回 true）→ 见 L5。
    if olditem ~= nil and olditem.components.equippable:ShouldPreventUnequipping() then
-- ★★★ 旧装备的粘住保护（★ 无 force 参数 —— 能力缺口）。
        return
-- ★★★ 旧装备被粘住 → 拒绝替换（★ 无 force 参数）。
    end
-- ★ 早退。

-- ↑ 保护块结束。
    -----
-- ↑ 注释分隔线。
-- ★★ iscontroller —— 「当前是否处于客户端控制器已挂载状态」。
-- ★★★ ★ 与 GiveItem:1181 的同一判定。语义：
--   「这个实体正在被某个客户端操控中」。
-- ★★ 1286-1302 行用它决定 prevcontainer 的取法（1291-1295 行）。
-- ★★ ★★ 三层嵌套的 if/else 结构，展开：
--   若有 prevslot（普通槽来的）→ prevcontainer = nil（1288 行）；
--   否则（从容器来的）：
--     · iscontroller → prevcontainer = owner.components.container（1292 行）；
--     · 非 controller → owner.components.inventoryitem and
--       owner.components.container（1294 行，多一层 inventoryitem）。
-- ★★★ ⚠ 为什么非 controller 要多一层 inventoryitem？
--   推理：非玩家实体（如 NPC）的 owner 可能是「持有它的实体」，
--   它的「容器」要通过 inventoryitem.owner 再取一层。
--   ★ 这是「非玩家实体」的层级差异。属实现细节。
-- ★★★ ★★★ 1298-1302 行的「controller 换装同槽」特殊处理：
--   `if iscontroller and olditem and item.prevslot then`
--     olditem.prevcontainer = item.prevcontainer
--     olditem.prevslot = item.prevslot
--   ⇒ ★★★ **把新物品的位置记忆转移给旧物品**！
--   设计推理：controller 换装时（如客户端预测的换装），
--   新物品「借住」了旧物品的位置记忆；换装后旧物品要去那里，
--   所以把记忆**复制**给旧物品，让它回原位。
--   ★★ 这是「位置记忆」机制在换装场景下的精细处理。
	local iscontroller = self.inst.components.playercontroller and self.inst.components.playercontroller.isclientcontrollerattached
-- ↑ iscontroller + 位置记忆写入（三层嵌套）。

-- ↑ 空行。
-- ★★★ `item.prevslot = self:GetItemSlot(item)` —— 记录原槽位。
-- ★★★ ★ 这是「位置记忆」的**写入点**（GiveItem 时读取）。
-- ★★ ★★ 与 RemoveItem 的 1410 行（`item.prevslot = prevslot`）不同：
--   · RemoveItem 写的是 inventoryitem:GetSlotNum() 的结果（1395 行）；
--   · Equip 写的是遍历 itemslots 找到的槽号（592 行）。
-- ★★ 两者结果应该一致，但**路径不同**。若有差异会导致记忆错位。
-- ★★★ ★★ 注意 1287 行 `if item.prevslot then prevcontainer = nil`：
--   从普通槽来的物品，容器必然是 nil（清空残留记忆）。
--   ⇒ ★ 这保证了「位置记忆」是完整的一对（slot + container），
--     不会出现「有槽号但容器指向别处」的矛盾状态。
    item.prevslot = self:GetItemSlot(item)
-- ★★★ 位置记忆写入点。
	if item.prevslot then
-- ★★ 来自普通槽（有 prevslot）？
		item.prevcontainer = nil
-- ★★★ 清容器记忆（★ 保持「槽+容器」成对一致）。
	else
-- ★ else 分支：来自容器或未知位置。
		local owner = item.components.inventoryitem.owner
-- ★ 取当前 owner。
		if iscontroller then
-- ★ controller 路径？
			item.prevcontainer = owner and owner.components.container or nil
-- ★★ 直接取 owner 的 container（★ 玩家场景）。
		else
-- ★ else：非 controller。
			item.prevcontainer = owner and owner.components.inventoryitem and owner.components.container or nil
-- ★★★ 多一层 inventoryitem（★ 非玩家实体的层级差异）。
		end
-- ↑ if/else 块结束。
		item.prevslot = item.prevcontainer and item.prevcontainer:GetItemSlot(item) or nil
-- ★★★ 槽号从容器反查。
	end
-- ↑ if/else 块结束。
	--controller swaps to the same slot
-- ↑ 原英文注释保留（controller swaps to the same slot）。
	if iscontroller and olditem and item.prevslot then
-- ★★★ 换装同槽的三重条件。
		olditem.prevcontainer = item.prevcontainer
-- ★★ 把新物品的位置记忆**转移**给旧装备。
		olditem.prevslot = item.prevslot
-- ★★ 同上（槽号）。
	end
-- ↑ if 块结束。
    -----
-- ↑ 注释分隔线。
-- ★★★★ 重物互斥（1304-1321 行）—— ★ 本函数最「游戏性」的部分。
-- ★★★ 两个对称分支：
--   · 1305 行：装 HANDS 时，若 BODY 有 heavy → **丢掉 BODY 的 heavy**；
--   · 1310 行：装 heavy 到 BODY 时，若 HANDS 有东西 → 放回或丢掉。
-- ★★★ ★ 设计意图：玩家不能「一手拿重物 + 一身重甲」。
--   负重（heavylifting）是单一资源，不能叠加。
-- ★★★ ★ 1307 行 `heavyitem:HasTag("heavy")` —— 标签驱动，不是组件。
-- ★★★ ★★ 1308 行 `self:DropItem(heavyitem, true, true)` ——
--   ★ 注意是**直接丢掉**，不是先尝试放回背包。
--   ⇒ ★★ 玩家的重甲会被**扔在地上**！
--   ★★★ 这是一个**明确的设计决策**（原注释没有说明）：
--     拿枪时穿的重甲会被丢弃，而不是进背包。
--   ★★ 为什么不用 GiveItem？因为 GiveItem 可能塞进手上（1178 行），
--     而手上正在被「手」占据，会冲突。
--   ★★ ⇒ ★★ 这是「宁可丢地上也不进背包」的取舍：
--     保证「手上的东西一定是玩家主动拿的」。
-- ★★ 1310-1320 行的 BODY 分支更「温柔」：
--   · 1313 行若手上有东西且可进容器 → **放回背包**（silentfull 包裹）；
--   · 1317 行 else → 丢地上。
-- ★★ ★ 两个分支的不对称（HANDS 直接丢 vs BODY 先尝试放回）
--   值得注意。可能是有意的（HANDS 槽被新物品占据，无处安置）。
    --heavy lifting
-- ★★★★ 重物互斥（HANDS 与 BODY）。
    if item.components.equippable.equipslot == EQUIPSLOTS.HANDS then
-- ★★ 分支①：装到 HANDS。
        local heavyitem = self:GetEquippedItem(EQUIPSLOTS.BODY)
-- ★ 取 BODY 槽的物品。
        if heavyitem ~= nil and heavyitem:HasTag("heavy") then
-- ★★ 它是重物？
            self:DropItem(heavyitem, true, true)
-- ★★★★ 直接**丢弃**（★ 不尝试放背包 —— 见 BEFORE 详解）。
        end
-- ↑ if 块结束。
    elseif item.components.equippable.equipslot == EQUIPSLOTS.BODY and item:HasTag("heavy") then
-- ★★ 分支②：装 heavy 到 BODY。
        local handitem = self:GetEquippedItem(EQUIPSLOTS.HANDS)
-- ★ 取 HANDS 槽的物品。
        if handitem ~= nil then
-- ★ 手上有东西？
            if handitem.components.inventoryitem.cangoincontainer then
-- ★★ 它能进背包吗？
                self.silentfull = true
-- ★ 静音包裹开始。
				self:GiveItem(handitem, nil, force_ui_anim and self.inst:GetPosition() or nil)
-- ★★ 放回背包（★ force_ui_anim 时带动画位置）。
                self.silentfull = false
-- ★ 静音包裹结束。
            else
-- ★ else 分支：不能进背包。
                self:DropItem(handitem, true, true)
-- ★★ 丢弃。
            end
-- ↑ if/else 块结束。
        end
-- ↑ if handitem 块结束。
    end
-- ↑ if/elseif 块结束。
    -----
-- ↑ 注释分隔线。

-- ★★★ 从原位置取出物品（1324-1332 行）。
-- ★★★ 三分支：
--   1325-1326 行 没有 inventoryitem 组件（诡异）→ RemoveItem；
--   1327-1328 行 IsHeld()（在手上）→ RemoveFromOwner(equipstack, true)；
--   1329-1332 行 是堆叠且**不支持整摞装备** → 拆出一个，leftovers = 剩下的。
-- ★★★ ★★★ 1329 行是「装备堆叠」的核心：
--   `elseif stackable ~= nil and IsStack() and not equipstack then`
--     · 手上拿 20 个石头、装备不支持整摞 → 只装备 1 个；
--     · 剩下 19 个成为 leftovers，1340 行放回背包。
-- ★★ ⇒ ★ 这就是 equipstack（equippable.lua:34）标志的实际作用。
-- ★★★ ★ 1326 行的 `or item` 兜底：RemoveItem 返回 nil 时用原 item。
--   ★★★ ★ 但 1326 行有个真实缺陷（见 L20）：
--     `if item.components.inventoryitem == nil then item = self:RemoveItem(...)`
--     ★ 此时 item.components.inventoryitem 是 nil，
--       RemoveItem 内部（1395 行）`item.components.inventoryitem and ...`
--       会短路，所以不崩。**侥幸安全**。
-- ★★ 1328 行 RemoveFromOwner(equipstack, true) 的 keepoverstacked=true ——
--   ★ 「保留过度堆叠」：若这摞超过了标准上限（如 99），保留而不拆分。
--   用于「背包里的堆叠上限临时提高」的场景。
    local leftovers = nil
-- ↑ 从原位置取出（三分支）。
    if item.components.inventoryitem == nil then
-- ★★ 分支①：无 inventoryitem 组件（★ 异常情况）。
        item = self:RemoveItem(item, item.components.equippable.equipstack, nil, true) or item
-- ★ RemoveItem + `or item` 兜底（★ 侥幸安全，见 L20）。
    elseif item.components.inventoryitem:IsHeld() then
-- ★★ 分支②：正在手上。
        item = item.components.inventoryitem:RemoveFromOwner(item.components.equippable.equipstack, true) or item
-- ★★ RemoveFromOwner(equipstack, keepoverstacked=true)。
    elseif item.components.stackable ~= nil and item.components.stackable:IsStack() and not item.components.equippable.equipstack then
-- ★★★★ 分支③：是堆叠且不支持整摞装备。
        leftovers = item
-- ★★ leftovers = 剩下的那摞。
        item = item.components.stackable:Get()
-- ★★★ item = Get() —— 取出 1 个去装备。
    end
-- ↑ if/elseif 块结束。

-- ★★ `if item == self.activeitem then` —— 装备的正是手上那件。
-- ★★★ leftovers = self.activeitem（**整个**作为 leftovers）；
-- ★★★ ★★★ 然后 SetActiveItem(nil) 清空手上。
-- ★★ ★★ 这里有个微妙的交互：1327 行已经处理过 IsHeld 的情况
--   （RemoveFromOwner 会清空 activeitem），所以 1334 行通常不成立。
--   ★★★ ★ 但如果 1327 行没走（IsHeld 为 false 但 item == activeitem）——
--     这个分支就是唯一的清理点。属防御性代码。
-- ★★★ ★★ 注意：leftovers 在这里被**覆盖**（若 1330 行已赋值）。
--   ⇒ ★ 若 1329 行拆过堆叠，1335 行会用 activeitem 覆盖 leftovers。
--   ⚠ 这是一个潜在的逻辑覆盖（见 L21），但实际不冲突
--     （IsHeld 为 true 时 1327 已处理，1334 不成立）。
    if item == self.activeitem then
-- ↑ 若是从手上拿的。
        leftovers = self.activeitem
-- ★★ leftovers = 手上那件（★ 可能覆盖 1330 的值，见 L21）。
        self:SetActiveItem(nil)
-- ★★★ SetActiveItem(nil) 清空手上。
    end
-- ↑ if item == activeitem 块结束。

-- ★★★ `if olditem ~= item then` —— 「真的换了东西」。
-- ★★★ ★ 若同一件物品重复 Equip 到同一槽，此条件不成立，
--   直接跳到 1387 行（返回 nil，不做任何事）。
-- ★★ 场景：客户端重复请求装备同一物品。★ 这是幂等保护。
-- ★★★ ★ 与 1279 行的 protectunequipping 保护是**两层**：
--   一层挡「粘住的旧装备」，一层挡「重复装备同一件」。
    if olditem ~= item then
-- ★★★ 幂等保护（同一物品重复装备）。
-- ★★ 1340-1348 行：安置 leftovers（拆出来的部分）。
-- ★★★ 两个分支：
--   · old_to_active → GiveActiveItem（放到手上，1342 行）；
--   · 否则 → GiveItem + silentfull 包裹（1344-1346 行）。
-- ★★ ★★ silentfull 的作用：抑制「背包满」提示。
--   ★★★ 因为「装备时拆出的剩余」进背包是**预期行为**，
--     不该提示玩家背包满。
-- ★★ force_ui_anim 参数在这里兑现（1345 行）：
--   传 self.inst:GetPosition() 作为 src_pos，让客户端播「飞入背包」的动画。
-- ★★★ ★ force_ui_anim 只影响 UI 动画，不影响逻辑位置。
        if leftovers ~= nil then
-- ↑ 安置 leftovers。
            if old_to_active then
-- ★★ 换下/split 出来的东西要去手上？
                self:GiveActiveItem(leftovers)
-- ★ GiveActiveItem。
            else
-- ★ else 分支。
                self.silentfull = true
-- ★ 静音包裹开始。
				self:GiveItem(leftovers, nil, force_ui_anim and self.inst:GetPosition() or nil)
-- ★★ GiveItem 回背包。
                self.silentfull = false
-- ★ 静音包裹结束。
            end
-- ↑ if/else 块结束。
        end
-- ↑ if leftovers 块结束。
-- ★★★★ 安置旧装备（1349-1362 行）—— ★★ 本函数最复杂的分支。
-- ★★ 四步：
--   ① 1350 行 Unequip(eslot) —— 把旧装备取下；
--   ② 1351 行 ToPocket() —— 通知「回到背包」；
--   ③ 1352-1354 行 若旧装备**不能进背包** → OnRemoved + 丢地上；
--   ④ 1355-1361 行 否则 → 放手上（old_to_active）或放回背包。
-- ★★★ ★★ 1352 行的判定：
--   `not olditem.components.inventoryitem.cangoincontainer and
--    not self.ignorescangoincontainer`
--   ⇒ 「旧装备不能进任何容器，且本栏不忽略这个限制」→ 丢地上。
-- ★★ ★★ 这是「换下不能拿的东西」的兜底（如换下湿的物品？）。
--   ★ 1353 行 OnRemoved 先调（通知「已被移除」），再 DropItem。
-- ★★★ ★ 1355 行的 old_to_active 判定：
--   `old_to_active` 由调用方传入（1284 行算出 iscontroller）。
-- ★★ 1284 行的实参：`self:Equip(item, not old_to_active and item.prevslot == nil)`
--   ⇒ old_to_active = 「不是 controller 且物品原本不在槽里」。
-- ★★★ ★ 翻译成白话：**手动装备时，旧的装备会被拿到手上**；
--   controller 自动装备时，旧的直接进背包（因为手被占用了）。
-- ★★★ ★★★ 这就是「手动换装」的体验：换下的帽子自动拿在手上。
-- ★★ 1358-1360 行的 silentfull 包裹（与 1344 同理）。
        if olditem ~= nil then
-- ★★★★ 安置旧装备（最复杂分支）。
            self:Unequip(eslot)
-- ★★ Unequip 旧装备（★ 槽位在 1366 才写新物品）。
            olditem.components.equippable:ToPocket()
-- ★★ ToPocket 通知（「回到背包」）。
            if olditem.components.inventoryitem ~= nil and not olditem.components.inventoryitem.cangoincontainer and not self.ignorescangoincontainer then
-- ★★★★ 旧装备不能进任何容器？
                olditem.components.inventoryitem:OnRemoved()
-- ★★ OnRemoved 通知。
                self:DropItem(olditem)
-- ★★★ 丢地上。
            elseif old_to_active then
-- ★ elseif 换下手上的？
                self:GiveActiveItem(olditem)
-- ★★★ GiveActiveItem（★ 这是「手动换装」的体验）。
            else
-- ★ else 分支。
                self.silentfull = true
-- ★ 静音包裹开始。
				self:GiveItem(olditem, nil, force_ui_anim and self.inst:GetPosition() or nil)
-- ★★ 给回背包。
                self.silentfull = false
-- ★ 静音包裹结束。
            end
-- ↑ if/elseif/else 块结束。
        end
-- ↑ if olditem 块结束。

-- ★★★ `item.components.inventoryitem:OnPutInInventory(self.inst)` ——
--   「正式进入物品栏」的回调。
-- ★★★ ★ 与 Unequip 的顺序对照（这是关键）：
--   ① 1350 行 Unequip(eslot) —— **旧装备先被取下**；
--   ② 1364 行 OnPutInInventory —— 新物品登记；
--   ③ 1365 行 Equip 回调；
--   ④ 1366 行 `self.equipslots[eslot] = item` —— **槽位最后才写入**。
-- ★★★ ★★ 1366 行是**最后**写入槽位，这个顺序至关重要：
--   ⇒ ★★★ 在 1366 行之前，item 还不在任何槽里。
--   ★★★ 若在 1364-1365 行触发的回调里查询 equipslots，
--     **看不到**这件装备。这是「事件时序」的重要保证。
-- ★★ 1365 行：`Equip(self.inst, not old_to_active and item.prevslot == nil)`
--   ★★★ 第三个参数 from_ground：
--     「不是 controller 且物品原本不在槽里」⇒ 「从地上捡起来穿的」。
--   ⇒ ★★★ 这与 equippable.lua:104 的 HasTag("equipmentmodel")
--     配合：只有「从地上捡起来穿」的才触发 model 回调。
-- ★★★ ★ 设计推理：换下的旧装备「回背包」（from_ground=false），
--   而新捡的装备「从地上来」（from_ground=true）。
--   ⇒ 音效/动画会不同。
        item.components.inventoryitem:OnPutInInventory(self.inst)
-- ↑ OnPutInInventory（在写入槽位之前！）。
        item.components.equippable:Equip(self.inst, not old_to_active and item.prevslot == nil)
-- ★★★ Equip 回调（★ 第三参 from_ground = 「不是 controller 且原本不在槽」）。
-- ★★★ `self.equipslots[eslot] = item` —— ★ 真正的槽位写入点。
-- ★★ ★ 与 1407/1240 行的 `= nil` 对称：**装备槽也是「直接赋值」**。
--   ⇒ 槽位从不压缩/重排。
-- ★★★ ★★ 关键：这是本函数里**唯一**写 equipslots 的地方。
-- ★★★ ★ 1368-1375 行的条件链依赖 eslot（1277 行算的）。
        self.equipslots[eslot] = item
-- ★★★ 槽位写入点（本函数唯一）。

-- ↑ 空行。
-- ★★★ BODY 槽的副作用（1368-1372 行）：
-- ★★ 1369-1371 行：**若新装备有 container 组件 → 派发 setoverflow**。
--   ★★★★★ 这就是「背包 = 穿在身上的物品」的实现：
--     BODY 槽的物品若带 container，它就成为 GetOverflowContainer 的返回。
--   ★★★ ★ 与 Unequip 的 1228-1231 行配对：
--     穿上 → PushEvent("setoverflow", { overflow = item })；
--     脱下 → PushEvent("setoverflow", {})。
--   ★ 消费方：inventory_replica 或 HUD（决定背包 UI 的内容源）。
-- ★★ 1372 行 heavylifting = item:HasTag("heavy") ——
--   ★★★ 注意是**直接赋值**（触发 24 行的 setter → 同步客户端）。
--   ★★ 这就是「负重」的判定：BODY 槽有 heavy 标签。
-- ★★ ★ 与 1305-1309 行的「重物互斥」配合：
--     穿上 heavy 到 BODY → heavylifting = true → 客户端过滤动作。
        if eslot == EQUIPSLOTS.BODY then
-- ↑ BODY/HANDS 副作用（setoverflow / heavylifting / floaterheld）。
            if item.components.container ~= nil then
-- ★★ 新装备带 container 组件？
                self.inst:PushEvent("setoverflow", { overflow = item })
-- ★★★ setoverflow 事件（★ 与 Unequip:1230 配对的握手）。
            end
-- ↑ if 块结束。
            self.heavylifting = item:HasTag("heavy")
-- ★★★ heavylifting = HasTag("heavy") —— 「负重」的唯一判定点。
-- ★★ HANDS 槽的副作用：floaterheld。
-- ★★ `self.floaterheld = item.components.playerfloater and true` ——
--   ★★★ 「有 playerfloater 组件则为 true，否则为 **false**」（不是 nil）。
--   ★★ 因为 29 行的 setter 会 `SetFloaterHeld(floaterheld or false)`，
--     传 nil 也会转 false，所以两等价。写成 `and true` 更明确。
-- ★★ ★ 效果：客户端收到 floaterheld=true → 进入「漂浮」状态图（见 28 行注释）。
		elseif eslot == EQUIPSLOTS.HANDS then
-- ↑ HANDS 的 floaterheld 赋值。
			self.floaterheld = item.components.playerfloater and true
-- ★★ floaterheld = 有 playerfloater 组件（★ and true 转布尔）。
        end
-- ↑ if/elseif 块结束。

-- ★★★ PushEvent("equip", { item, eslot, no_animation }) ——
--   ★★★ ★★★ 联机同步的核心事件（inventory_replica.lua:25）：
--     `self.classified:SetSlotEquip(data.eslot, data.item)`
--   ⇒ ★★★ 这是「装备槽设置」在客户端的**唯一**通知来源。
--   ★★★ 与 1241 行的 unequip 配对。
-- ★★ ★ data 里有 no_animation —— 联机时用于抑制客户端的装备动画
--   （如批量加载时不要播一堆动画）。
-- ★★ 1378-1380 行：统计数据（METRICS_ENABLED 时）。
--   ★ `ProfileStatsAdd("equip_"..item.prefab)` —— 按 prefab 统计装备次数。
--   ★ 只上报，不影响逻辑。
        self.inst:PushEvent("equip", { item = item, eslot = eslot, no_animation = no_animation })
-- ★★★ equip 事件（联机同步核心）。
        if METRICS_ENABLED and item.prefab ~= nil then
-- ★ 统计开关（仅开发/运营版本开启）。
            ProfileStatsAdd("equip_"..item.prefab)
-- ★★ ProfileStatsAdd("equip_"+prefab) —— ★ 与 gameplay 无关。
        end
-- ↑ if 块结束。

-- ★★ setbonus 更新 —— 与 Unequip 的 1243 行配对。
-- ★★★ ★ `UpdateSetBonus(self, true)` —— true = 穿上。
-- ★★ ★★ 注意这里在 1366 行（槽位已写入）**之后**调用：
--   ⇒ ★★★ setbonus 遍历 equipslots 时**能看到**新装备。
--   ★★★ 与 Unequip 的顺序对照（1243 在 1240 之后）：
--     Equip：写入槽 → 更新 setbonus（能看到自己）；
--     Unequip：清空槽 → 更新 setbonus（看不到自己）。
--   ⇒ ★★ 两次都是「幂等重算整个套装」，所以都正确。
-- ★★ 1386 行 `return true` —— 成功。
-- ★★ ★ 与 L5 对照：失败路径返回 nil，成功返回 true。
--   ⇒ ★★ `if inv:Equip(x) then` 在「同一物品重复装备」时为假。
        if item.components.setbonus ~= nil then
-- ↑ setbonus 更新（槽已写入后）。
            item.components.setbonus:UpdateSetBonus(self, true)
-- ★★ setbonus 开启（★ 槽已写入后 ⇒ 能看到自己）。
        end
-- ↑ if setbonus 块结束。

        return true
-- ★★ return true —— 成功。
    end
-- ↑ if olditem ~= item 块结束。
end
-- ↑ Equip 结束。

-- 【§十二】★★★ RemoveItem —— 「从物品栏取出物品」。
-- ★★★ 四参数：item（要取的）、wholestack（整摞还是单个）、
--   checkallcontainers（是否搜索打开的容器）、keepoverstacked（保留过度堆叠）。
-- ★★★★ 六个查找位置（按顺序）：
--   ① 1397 行 非整摞且是堆叠 → **拆分一个**返回（1398-1403）；
--   ② 1405-1414 行 itemslots；
--   ③ 1416-1422 行 activeitem；
--   ④ 1424-1432 行 equipslots；
--   ⑤ 1434-1438 行 overflow（递归）；
--   ⑥ 1440-1451 行 所有打开的容器（若 checkallcontainers）。
-- ★★★ ★★ 1453 行的兜底 `return item` —— ★ 本函数最重要的设计：
--   六个位置都没找到时，**返回传入的 item 本身**（而非 nil）。
-- ★★★ 这让链式调用 `self:RemoveItem(v):Remove()` 成为可能
--   （见 1758/1765/1953 行）。
-- ★★★ ★ 代价：调用方无法区分「成功取出」与「本来就不在这」。
--   ⇒ ★★ 需要区分时必须先自己 IsHolding。
-- ★★ ★★ 顺序的重要性：②③④ 的顺序体现了
--   「先查最可能的」的思路（普通槽 > 手上 > 装备 > 背包 > 容器）。
function Inventory:RemoveItem(item, wholestack, checkallcontainers, keepoverstacked)
-- ↑ RemoveItem 函数头（六个查找位置）。
    if item == nil then
-- ★★ item 为 nil → 返回 nil（★ 链式调用会崩，见 L2）。
        return
-- ★ 早退。
    end
-- ↑ 空值判定块结束。

-- ★★ `local prevslot = item.components.inventoryitem and GetSlotNum() or nil` ——
-- ★★★ ★ 「读取物品当前所在槽位」用于写入位置记忆。
-- ★★ 注意用了 `and ... or nil` 的链式：
--   · 无 inventoryitem 组件 → GetSlotNum 不调用 → nil；
--   · 有组件 → 返回槽号（可能是 0？）。
-- ★★★ ★★ **注意**：inventoryitem.lua:315 GetSlotNum 的实现
--   是遍历 itemslots 找匹配，**不查 equipslots 和 activeitem**。
--   ⇒ ★★ 所以 1424 行（从装备槽取出）写入的 prevslot 是 **nil**！
--   ⇒ ★★★ 后果：卸下的装备不记得自己原来穿在哪（这本就不重要，
--     因为 Equip 会从 equippable.equipslot 知道该穿哪）。
-- ★★ 交叉引用：inventoryitem.lua:315 GetSlotNum。
    local prevslot = item.components.inventoryitem and item.components.inventoryitem:GetSlotNum() or nil
-- ↑ prevslot 取得（★ GetSlotNum 不查装备槽/手上）。

-- ↑ 空行。
-- ★★★★ 情况①：非整摞 + 是堆叠 → **拆分一个**（1397-1403 行）。
-- ★★★ ★ 这是「拿一个」的语义（wholestack=false 且是堆叠）。
-- ★★ 1398 行 `local dec = item.components.stackable:Get()` ——
--   ★★★ Get() 无参数时返回**一个**新实体（stackable.lua 的行为）。
-- ★★ 1399 行 `dec.components.inventoryitem:OnRemoved()` ——
--   ★★★ 注意：对**新拆出的实体**调 OnRemoved，而不是原实体。
--   ⇒ ★★★ 推理：被取出的那个已经「离开物品栏」，
--     所以要通知它自己。原实体还在栏里（stacksize 减 1），不该通知。
-- ★★ ★★★ 1400-1401 行：把**原实体的槽位**记忆**复制给新实体**：
--   `dec.prevslot = prevslot; dec.prevcontainer = nil`
--   ⇒ ★★★ ★ 设计推理：新实体是「刚刚被拿出来的」，
--     它应该记住自己来自哪个槽（这样 GiveItem 能把它放回去）。
--   ★★ ★ 这就是「位置记忆」的写入点之一（另一个是 1410 行）。
-- ★★ 1402 行 `return dec` —— **返回新实体，不是原实体**。
-- ★★★ ★★★ 这是本函数的第一个「惊喜」：
--   RemoveItem(item, false) 返回的是一个**不同的实体**。
--   ⇒ ★★ 调用方若写 `local x = inv:RemoveItem(item)` 然后用 x，
--     必须知道 x 可能不是 item 本身。
-- ★★ ★ 对比 wholesack=true 时（1405 行起）返回的是原实体。
    if not wholestack and item.components.stackable ~= nil and item.components.stackable:IsStack() then
-- ★★★★ 情况①：拆分一个（返回新实体！）。
        local dec = item.components.stackable:Get()
-- ★★★ Get() 取出 1 个（新实体）。
        dec.components.inventoryitem:OnRemoved()
-- ★★ 对**新实体**调 OnRemoved（原实体还在栏里）。
        dec.prevslot = prevslot
-- ★★ 把原实体的槽记忆复制给新实体。
        dec.prevcontainer = nil
-- ★★ 清容器记忆。
        return dec
-- ★★★ return dec（★ 返回的不是入参！）。
    end
-- ↑ 拆分分支结束。

-- ★★ 情况②：在 itemslots 里找。
-- ★★ 1407 行 `self.itemslots[k] = nil` —— 直接置 nil（不压缩数组）。
-- ★★★ ★ 1408 行 PushEvent("itemlose") —— 联机同步（与 559 行同款）。
--   inventory_replica:24 → SetSlotItem(k)（清空该槽）。
-- ★★ 1409 行 OnRemoved —— 「离开 owner」的回调。
--   ★★ 与 1399 行的对比：那里对「新实体」调，这里对「原实体」调。
-- ★★ ★★ 1410-1411 行位置记忆：
--   `item.prevslot = prevslot; item.prevcontainer = nil` ——
--   ★★★ ★ 与 1400 行的区别：这里写的是 **prevslot 变量**（1395 行取的值），
--     而不是当前槽号 k！
--   ★★ 两者通常相同（prevslot 就是它所在的槽）。
--   ★ ★★ 若 GetSlotNum 的实现与实际所在槽不一致（见 1395 行分析），
--     这里就会写入错误的记忆。
-- ★★ 1412 行 `return item` —— 返回**原实体**。
    for k, v in pairs(self.itemslots) do
-- ↑ 情况②：itemslots。
        if v == item then
-- ★★ 找到这个实体？
            self.itemslots[k] = nil
-- ★★★ 直接置 nil（★ 不压缩数组 —— 槽位顺序稳定）。
            self.inst:PushEvent("itemlose", { slot = k, prev_item = item })
-- ★★ itemlose 事件（★ 联机同步：清空该槽）。
            item.components.inventoryitem:OnRemoved()
-- ★ OnRemoved 回调。
            item.prevslot = prevslot
-- ★★ 写入位置记忆（用 prevslot 变量，非 k）。
            item.prevcontainer = nil
-- ★★ 清容器记忆。
            return item
-- ★★ return item（原实体）。
        end
-- ↑ if 块结束。
    end
-- ↑ itemslots 遍历结束。

-- ★★ 情况③：就是 activeitem（手上那件）。
-- ★★ 1417 行 `self:SetActiveItem()` —— **无参数** = 置 nil（清空手上）。
-- ★★★ ★ 注意这里用 SetActiveItem() 而不是直接 `= nil`：
--   因为要触发 "newactiveitem" 事件（客户端同步）。
-- ★★★ ★ 对比 1407 行的 `itemslots[k] = nil`（直接赋值不派事件，
--     而是单独 PushEvent itemlose）。两种「清空」都有事件，只是机制不同。
-- ★★ 1418 行 PushEvent("itemlose", { activeitem = true, prev_item = item }) ——
--   ★★★ ★ 注意这里**同时**推了 itemlose 事件，
--     且 data 里的 key 是 **activeitem = true**（不是 slot）。
--   ⇒ ★★★ 这是「手上物品被取走」的通知方式。
--   ★★ 对比 1408 行（key 是 slot）—— 两种 key 供监听者区分。
-- ★★★ ★★ 1420 行的原注释 `--keep current prevcontainer, prevslot` ——
--   ★★★★ **这是一处刻意的例外**！
--   前面的分支（1410/1400）都清空了 prevslot/prevcontainer，
--   而这里**保留**。
-- ★★★★ 推理：手上的东西被拿走时，它的「位置记忆」是**手上**；
--   而 prevcontainer/prevslot 记录的是「它上次在哪个具体槽/容器」。
--   ⇒ ★★ 若此时清空，物品就彻底「失忆」了；
--     保留则意味着「如果失败还会放回原处」。
-- ★★★ 这与 1081-1083 行的「失败即清记忆」策略**相反**。
--   ⇒ ★★ 两处策略不一致，但各有理由（这里是有意的「保留回滚余地」）。
-- ★★ 注释用了 `--` 前缀（不是 `--[[ ]]`），说明它是给开发者看的说明。
    if item == self.activeitem then
-- ↑ 情况③：activeitem（★ 刻意保留位置记忆）。
        self:SetActiveItem()
-- ★★ SetActiveItem() —— 无参 = 置 nil（★ 触发 newactiveitem）。
        self.inst:PushEvent("itemlose", { activeitem = true, prev_item = item })
-- ★★ itemlose 事件（★ key 是 activeitem=true 而非 slot）。
        item.components.inventoryitem:OnRemoved()
-- ★ OnRemoved。
		--keep current prevcontainer, prevslot
-- ★★★ 原注释：刻意**保留** prevcontainer/prevslot（★ 全文唯一例外）。
        return item
-- ★★ return item。
    end
-- ↑ if item == activeitem 块结束。

-- ★★ 情况④：在 equipslots 里（穿在身上）。
-- ★★★ ★ 1426 行 `self:Unequip(k, nil, true)` —— **第三个参数 force=true**！
-- ★★★★ ★★ 这是本文件里 force 参数的**第二个**使用点（第一个是 168 行）。
--   语义：「即使 preventunequipping 也要卸下」。
-- ★★★ ★★★ 1426 行的原注释（★ 完整的推理链）：
--   "force unequip even if prevents unequipping, since we're going ahead
--    with dropping it already"
--   ⇒ ★★ 「反正都要丢掉了，锁不锁无所谓」。
--   ★★★ 这是**一致性优先**的判断：既然决定移除，
--     就不能因为锁而卡住（会导致物品卡在装备槽成为幽灵）。
-- ★★ ★★★ 与 1038 行 GiveItem 里的 Unequip 对比：
--   · 1038 行：**不传 force** → 锁住时留下（见 L15 的缺陷）；
--   · 1426 行：**传 force** → 无论如何都卸下。
--   ⇒ ★★★ 两处相同操作、不同策略 ⇒ L15 的缺陷更加确凿。
-- ★★ 1427-1429 行：与 1409-1411 行同款（OnRemoved + 位置记忆）。
-- ★★ 1430 行 `return item`。
    for k, v in pairs(self.equipslots) do
-- ↑ 情况④：equipslots（★ 传 force=true）。
        if v == item then
-- ★★ 在装备槽找到？
			self:Unequip(k, nil, true) --force unequip even if prevents unequipping, since we're going ahead with dropping it already
-- ★★★★ Unequip(k, nil, force=true) —— ★ 忽略防卸锁。
            item.components.inventoryitem:OnRemoved()
-- ★ OnRemoved。
            item.prevslot = prevslot
-- ★ 位置记忆。
            item.prevcontainer = nil
-- ★ 清容器记忆。
            return item
-- ★ return item。
        end
-- ↑ if 块结束。
    end
-- ↑ equipslots 遍历结束。

-- ★★ 情况⑤：overflow（背包本体）里 —— **递归调用**。
-- ★★ `overflow:RemoveItem(item, wholestack, nil, keepoverstacked)` ——
--   ★★★ 第三参数传 nil（不是 checkallcontainers）：
--     ⇒ ★★ 在背包里查找时**不搜索打开的其他容器**（避免无限递归）。
--   ★★★ 这是「递归深度控制」：只递归一层，不无限展开。
-- ★★ 1436-1438 行：若 overflow 找到了就返回。
-- ★★ ★ 注意 overflow_item 可能是「拆分出的新实体」（container 版同样语义）。
-- ★★ ★⇒ 调用方拿到的可能不是原 item（同 1397 行的「惊喜」）。
    local overflow = self:GetOverflowContainer()
-- ↑ 情况⑤：overflow（递归，不无限展开）。
	local overflow_item = overflow and overflow:RemoveItem(item, wholestack, nil, keepoverstacked)
-- ★★ 递归到 overflow（★ 第三参传 nil ⇒ 不无限递归）。
    if overflow_item then
-- ★ overflow 找到了？
        return overflow_item
-- ★★ return overflow_item（★ 也可能是拆出的新实体）。
    end
-- ↑ if 块结束。

-- ★★ 情况⑥：搜索**所有打开的容器**（仅当 checkallcontainers 为真）。
-- ★★ 1441 行 `local containers = self.opencontainers` —— 
--   ★★★ ★★★ ★ 「从打开的箱子等容器里拿东西」的机制。
--   这是「背包不足时从旁边的箱子取」的底层支持。
-- ★★ 1442 行遍历，1443 行取组件：
--   ★★ `container_inst.components.container or container_inst.components.inventory`
--   ★★★ ★ 注意这个 **or 兜底**：opencontainers 里可能混有两种组件的实体
--     （container 组件 = 箱子；inventory 组件 = 另一个玩家的物品栏）。
--   ⇒ ★★ 「打开另一个玩家的背包」也走这个机制。
-- ★★ ★★ 1444 行的三重排除：
--   · `container ~= overflow`：跳过背包本体（已单独处理）；
--   · `not container.excludefromcrafting`：排除「不参与合成」的容器；
--   · `not container.readonlycontainer`：排除只读容器（如展示柜）。
-- ★★★ ★★ excludefromcrafting 与 readonlycontainer 是**两种不同的排除**：
--   · excludefromcrafting = 「东西在里面，但不能用来合成」；
--   · readonlycontainer = 「只能看，不能拿」。
-- ★★ ★★ 1436 行还漏了一个排除条件（对比 1541 行有 `container ~= overflow`）：
--   1444 行有 `container ~= overflow` ✓，但 1435 行的 overflow_item 已处理过。
--   ⇒ 无重复处理。正确。
    if checkallcontainers then
-- ↑ 情况⑥：所有打开的容器。
        local containers = self.opencontainers
-- ★★ 打开的容器列表。
        for container_inst in pairs(containers) do
-- ★ 遍历（★ pairs，无序）。
            local container = container_inst.components.container or container_inst.components.inventory
-- ★★★ `or .components.inventory` 兜底（★ Hide:2078 没有这个兜底）。
            if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
-- ★★★★ 四重排除：存在 + 非 overflow + 参与合成 + 非只读。
				local container_item = container:RemoveItem(item, wholestack, nil, keepoverstacked)
-- ★★ 委托容器的 RemoveItem（★ 签名同构）。
                if container_item then
-- ★ 找到了？
                    return container_item
-- ★ return。
                end
-- ↑ if 块结束。
            end
-- ↑ 排除块结束。
        end
-- ↑ 容器遍历结束。
    end
-- ↑ if checkallcontainers 块结束。

-- ★★★★ `return item` —— ★★★★★ 本函数最重要的兜底。
-- ★★★★★ 「六个位置都没找到 → 把传入的 item 原样返回」。
-- ★★★★ 设计动机：让调用方的链式调用成为可能——
--   `self:RemoveItem(v):Remove()` （1758 行 tryconsume）
--   `self:RemoveItem(item):Remove()`  （1953 行 DestroyContents）
-- ★★ 若这里返回 nil，上述链式调用全部崩溃。
-- ★★★ ★ 代价：调用方**无法**区分：
--   · 「成功从物品栏取出」；
--   · 「本来就不在物品栏里」（兜底）。
-- ★★★ ★★ 但这个代价在实践中可以接受，因为：
--   「取出」这个动作的效果（物品脱离栏位）在两种情况下都是「无需处理」。
-- ★★ ★★★ 与 1392 行的 `if item == nil then return end` 对照：
--   · 传入 nil → 返回 **nil**（不是 item）；
--   · 传入实体但找不到 → 返回**该实体**。
--   ⇒ ★★ 链式调用若传入 nil 会崩（见 L2）。
--   ★★ 现有调用点都判了空（713/1758/1953 等），所以安全。
    return item
-- ★★★★★ 兜底 return item（让链式调用成为可能）。
end
-- ★★★★★ 兜底 return item（★ 让链式调用成为可能）。

-- ↑ RemoveItem 结束。
-- 【§十四】★★★ GetOverflowContainer —— 「返回当前穿在身上的背包」。
-- ★★★★ 这是本文件的**架构支点**：整个物品栏系统的三层结构由此串联。
-- ★★★ 三层结构全貌：
--   self.itemslots  →  GetOverflowContainer()  →  overflow.slots
--        ↑                  ↑                            ↑
--     玩家普通栏        BODY 槽的 container              背包的格子
-- ★★★ 判定逻辑（1460-1466 行）：
--   ① 1460 行 ignoreoverflow → 直接返回 nil（临时禁用）；
--   ② 1463 行 取 BODY 槽的物品；
--   ③ 1464-1466 行 该物品有 container 组件 **且** canbeopened → 返回它。
-- ★★★ ★★ 为什么第三个条件要 canbeopened？
--   因为「不能打开的容器」不应该被当成背包——
--   如某些只能通过特定方式取物的容器（母鸡的蛋篮？）。
-- ★★★ ★ 所以「背包」的定义是：「BODY 槽上、能打开的 container 组件物品」。
--   ⇒ 穿上背包 = 获得额外格子。这是 DST 物品系统的优雅之处。
-- NOTE TODO (Omar): We may want to update the usage of GetOverflowContainer to support multiple overflow containers it is not the biggest deal but many inventory mechanics currently miss out
-- ↑ GetOverflowContainer 上方的原注释（三行 TODO，见 L1）。
-- on Wilsons beard storage causing some consequences like items not going into the storage automatically or FindItems not including it.
-- ↑ 原注释第 2 行保留（Wilson 胡子存储的后遗症）。
-- If we ever do more general containers that are attached to the player like the backpack or Wilsons beard than it is something we should really do.
-- ↑ 原注释第 3 行保留（若扩展「贴身容器」应重构此处）。
function Inventory:GetOverflowContainer()
-- ★★ GetOverflowContainer 函数体开始。
    if self.ignoreoverflow then
-- ★★ 临时禁用 → 裸 return（★ 注意：返回 nil 而非 false）。
        return
-- ★ 早退。
    end
-- ↑ if 块结束。
    local item = self:GetEquippedItem(EQUIPSLOTS.BODY)
-- ★★ 取 BODY 槽的物品（★ 装备槽用 GetEquippedItem）。
    return (item ~= nil and item.components.container ~= nil and item.components.container.canbeopened)
-- ★★★★ 三重条件：非空 + 有 container + canbeopened。
        and item.components.container
-- ★★ 返回 container 组件（★ 不是实体！）。
        or nil
-- ★ or nil（★ 条件不成立时）。
end
-- ↑ GetOverflowContainer 结束。

-- ★★ ValidateSpecializedContainer —— 局部辅助函数（1469-1478 行）。
-- ★★★ 五重条件：
--   ① container 非 nil；
--   ② 有 priorityfn（★ 「有优先级函数」才是「专用容器」的标志）；
--   ③ 已被我打开 **或**（未打开但允许忽略关闭状态且符合条件）；
--   ④ canbeopened（可以打开）；
--   ⑤ 不是「掉落即开」也不是「可携带」。
-- ★★★ ★★ 条件②是核心：**priorityfn 的存在与否就是「专用容器」的定义**。
--   这是一个**鸭子类型**判定：不查类、不查标签，只看「有没有这个方法」。
--   ⇒ ★★ mod 只要给容器实现一个 priorityfn 方法，它就自动成为专用容器，
--     无需注册任何东西。**这就是本文件的模组兼容性设计**。
-- ★★★ ★★ ignoreclosed 参数（第三个）的作用：
--   为 true 时跳过第③④⑤重 → 只认「已打开」的容器。
--   调用点：1488 行传入 self.ignoreclosedspoverflow；
--   1500 行传 false（IsSpecializedContainer 总是宽松判定）。
-- ★★ ★★ 1475 行的标签与 1114 行不同（见 L11）：
--   · 1475 行（ValidateSpecializedContainer）用 "portablecontainer"；
--   · 1114 行（GiveItem 自动开容器）用 "portablestorage"。
--   ⇒ ★★★ **两个不同的标签**，且都没有解释。移植时务必注意。
local function ValidateSpecializedContainer(self, container, ignoreclosed)
-- ↑ ValidateSpecializedContainer 局部函数。
	return container ~= nil
-- ★★ 条件①：容器存在。
		and container.priorityfn ~= nil
-- ★★★★ 条件②：有 priorityfn（★ 这就是「专用容器」的定义）。
		and (	container:IsOpenedBy(self.inst) or
-- ★ 条件③a：已被我打开。
				(	not ignoreclosed and
-- ★★ 条件③b 的第一重：不要求已打开。
					container.canbeopened and
-- ★ 第二重：可以打开。
					not (container.droponopen or container.inst:HasTag("portablecontainer"))
-- ★★★ 第三重：非「掉落即开」且非「可携带」（★ 标签用 portablecontainer）。
				)
-- ↑ 条件③b 结束。
			)
-- ↑ or 表达式结束。
end
-- ↑ ValidateSpecializedContainer 结束。

--for specialized pocket containers (e.g. ammo pouch)
-- ↑ 原英文注释保留（specialized pocket containers）。
-- ★★ GetSpecializedContainers —— 「我的专用口袋容器列表」。
-- ★★★ 「专用容器」= 弹药袋、金币袋这类**只收特定物品**的口袋。
-- ★★ 三步（1482-1493 行）：
--   ① 1482 行 ignorespoverflow → 返回 nil（临时禁用）；
--   ② 1486-1492 行 **只遍历 itemslots**（普通背包格）；
--   ③ 1488 行用 ValidateSpecializedContainer 过滤。
-- ★★★ ★★ 注意 ②：**专用容器必须放在普通背包格里**！
--   ⇒ ★★ 它不能装备在身上，也不能放在另一个专用容器里。
--   ⇒ ★★★ 这是「口袋套口袋」被禁止的原因（防止无限套娃）。
--   ★★ 对比 overflow（背包）：它必须**穿在 BODY 槽**上。
--   ⇒ ★★★ 两种容器的存放位置**完全分离**：
--     · overflow（通用背包）→ equipslots[BODY]；
--     · specialized（专用口袋）→ itemslots（普通格）。
-- ★★★ ★ 这解释了为什么 GiveItem 里两个分支互斥（1104 vs 1112）。
-- ★★ 1489 行 `ret = ret or {}` —— 惰性建数组。
-- ★★ ★★ 返回的是**新表**（重要！GetNextAvailableSlot:824 会就地修改它）。
function Inventory:GetSpecializedContainers()
-- ↑ GetSpecializedContainers 结束（返回新表）。
	if self.ignorespoverflow then
-- ★★ 临时禁用 → 裸 return nil。
		return
-- ★ 早退。
	end
-- ↑ if 块结束。
	local ret
-- ★★ ret 惰性初始化（★ 返回的是**新表**）。
	for k = 1, self.maxslots do
-- ★★ 只遍历 itemslots（★ 专用容器必须放在普通格）。
		local v = self.itemslots[k]
-- ★ 取该格物品。
		if v and ValidateSpecializedContainer(self, v.components.container, self.ignoreclosedspoverflow) then
-- ★★ 双重判定：非空 + ValidateSpecializedContainer。
			ret = ret or {}
-- ★ 惰性建数组。
			table.insert(ret, v.components.container)
-- ★★ 加入列表（★ **存的是 container 组件不是实体**）。
		end
-- ↑ if 块结束。
	end
-- ↑ 遍历结束。
	return ret
-- ★★ return ret（★ 可能 nil 也可能空表）。
end
-- ↑ GetSpecializedContainers 结束。

-- ★★ IsSpecializedContainer(container) —— 「这个 container 是不是我的专用容器」。
-- ★★★ 与 1481 行互逆：一个枚举列表，一个反查单个。
-- ★★ 1497 行遍历 itemslots（理由同 1486 行）。
-- ★★ 1500 行 ValidateSpecializedContainer(..., false) ——
--   ★★★ 第三参数传 **false**（不传 ignoreclosedspoverflow）。
--   ⇒ ★★ 「是不是专用容器」是**客观属性**，
--     与「此刻是否允许往里塞」无关。
-- ★★ 这是 2538/2587/2638/2665 行「container:IsSpecializedContainer(self)」
--   调用的正是本函数（从 container 侧反向调用 inventory）。
-- ★★★ ★ 注意那个反向调用传的是 **self**（inventory）作为参数——
--   但本函数的第一参数期望的是 container！
--   ⇒ ★★★ ★★ 这是一个**签名不匹配**（见 L22）：
--     2538 行 `container:IsSpecializedContainer(self)` 里，
--     container 是 container 组件，它也有同名方法（container.lua），
--     而**不是**本函数的 IsSpecializedContainer。
--   ⇒ ★★ 修正：2538 行调用的是 **container.lua 的** IsSpecializedContainer，
--     参数是 inventory。两侧同构。这是「同名方法互调」的常见模式。
function Inventory:IsSpecializedContainer(container)
-- ↑ IsSpecializedContainer 结束（★ 与 container.lua 同名方法互调）。
	for k = 1, self.maxslots do
-- ★ 只遍历 itemslots（★ 与 1486 同）。
		local v = self.itemslots[k]
-- ★ 取该格物品。
		if v and v.components.container == container then
-- ★★ 就是这个 container？
			return ValidateSpecializedContainer(self, container, false)
-- ★★ ★ 传 false（不传 ignoreclosedspoverflow）—— 「客观属性」判定。
		end
-- ↑ if 块结束（★ 找到即返回，不继续）。
	end
-- ↑ 遍历结束。
	return false
-- ★★ 不是我的专用容器 → return false。
end
-- ↑ IsSpecializedContainer 结束。

--Note(Peter): We don't care about v.skinname for inventory Has requests.
-- ↑ 原英文注释保留（不区分 skinname，Peter 的注记）。
-- 【§十五】★ Has —— 「我有多少个某 prefab 的物品」。
-- ★★★ 三个参数：item（prefab 名）、amount（要几个）、
--   checkallcontainers（是否搜索打开的容器）。
-- ★★★ 返回 **两个值**：`(够不够, 实际有多少)`。
-- ★★ 这个双返回值是本文件的一贯风格（Has / HasItemWithTag /
--   HasItemThatMatches 都是）。
-- ★★★ ★★ 1508-1509 行的原注释（★ 一个将就的设计）：
--   "--V2C: this is the current assumption, so make it explicit"
--   `local iscrafting = checkallcontainers`
-- ★★★★ ⚠ 这是 L4 描述的**二义性缺陷**：
--   第三个参数的**名字**叫 checkallcontainers，
--   但它的**值**被当作 iscrafting（是否排除 nocrafting 标签）使用。
--   ⇒ ★★ 「是否搜索打开的容器」与「是否排除 nocrafting」被强行绑定。
--   ★★ 后果：`Has("rock", 1, false)` 会**统计** nocrafting 物品；
--     `Has("rock", 1, true)` 会**排除**它们。
--   ★★ 原注释「make it explicit」说明作者知道这是将就，但没改。
-- ★★★ ★ nocrafting 标签的用途：
--   标了此标签的物品**不能用来合成**（如任务道具、装饰品）。
--   ★★ 1513 行 `not (iscrafting and v:HasTag("nocrafting"))` ——
--     只有 iscrafting 为真时才检查标签。
function Inventory:Has(item, amount, checkallcontainers)
-- ↑ Has 函数头（返回「够不够, 有多少」）。
	--V2C: this is the current assumption, so make it explicit
-- ★★★ 原英文注释保留："this is the current assumption, so make it explicit"。
	local iscrafting = checkallcontainers
-- ★★★★ iscrafting = checkallcontainers —— ★★ L4 的二义性源头。

    local num_found = 0
-- ★ 计数器初始化。
-- ★★ 遍历 itemslots 统计。
-- ★★ 1514-1518 行的三元表达式（与 108 行同款）：
--   有 stackable → 加 StackSize；否则加 1。
-- ★★ ★ **只比较 prefab 名**（1513 行 `v.prefab == item`），
--   ★★★ ★★ 不比较 skinname。原注释 1506 行明说：
--   "Note(Peter): We don't care about v.skinname for inventory Has requests."
--   ⇒ ★★★ ★★ 这是一个**明确的设计取舍**：
--     给「皮肤版物品」和「普通版物品」视为同一种材料。
--   ★★ 后果：玩家不能用「皮肤版」冒充材料数量（可以），
--     但反过来也不能区分——若某配方要求特定皮肤，Has 会误判。
--   ★★ 设计理由：配方 ingredients 里写的是 prefab 名（recipe.lua），
--     没有 skinname 概念。保持一致。
    for k, v in pairs(self.itemslots) do
-- ↑ itemslots 统计（★ 不区分 skinname）。
		if v and v.prefab == item and not (iscrafting and v:HasTag("nocrafting")) then
-- ★★★ 三重条件：非空 + prefab 相同 + 非 nocrafting（或不算合成）。
            if v.components.stackable ~= nil then
-- ★★ 可堆叠？
                num_found = num_found + v.components.stackable:StackSize()
-- ★ 加 StackSize（★ 堆叠展开计数）。
            else
-- ★ else 分支。
                num_found = num_found + 1
-- ★ 加 1。
            end
-- ↑ if/else 块结束。
        end
-- ↑ 条件块结束。
    end
-- ↑ itemslots 遍历结束。

-- ★★ activeitem 也统计 —— 与 itemslots 同款判定。
-- ★★★ ★ 注意这里**同样**排除了 nocrafting（1522 行）。
--   ⇒ ★★ 手上的东西也能用来合成。
	if self.activeitem ~= nil and self.activeitem.prefab == item and not (iscrafting and self.activeitem:HasTag("nocrafting")) then
-- ↑ activeitem 统计。
        if self.activeitem.components.stackable ~= nil then
-- ★★ 手上物品的可堆叠判定。
            num_found = num_found + self.activeitem.components.stackable:StackSize()
-- ★ 加 StackSize。
        else
-- ★ else 分支。
            num_found = num_found + 1
-- ★ 加 1。
        end
-- ↑ if/else 块结束。
    end
-- ↑ activeitem 块结束。

-- ★★ overflow 递归统计 —— `overflow:Has(item, amount, iscrafting)`。
-- ★★★ ★ 第三参数传的是 **iscrafting**（不是 checkallcontainers）。
--   ⇒ ★★ 确认了二义性向下传递。
-- ★★ `num_found = num_found + overflow_found` ——
--   ★★★ ★ **忽略了 overflow_enough**（第一个返回值）！
--   ⇒ ★★ 只累加数量，不做「够了吗」的短路。
-- ★★★ ★★ 这是一个**性能上的缺陷**（见 L23）：
--   若物品栏里已有 100 个石头，而背包里也有 100 个，
--   Has("rock", 1) 会**完整遍历**背包的每一格——
--   因为没有任何 early-exit。
--   ★★ 对照 931/979 行的 CanAcceptCount 有 `>= stacksize` 早退。
--   ⇒ ★★ Has 家族**普遍缺少早退**，在大背包 + 高数量时会慢。
-- ★★ 这在「合成时检查材料」的热路径上尤其明显（每次都全量扫描）。
    local overflow = self:GetOverflowContainer()
-- ★★ overflow 统计（★ 忽略 enough，无早退 —— 见 L23）。
    if overflow ~= nil then
-- ★ 有 overflow 才统计。
		local overflow_enough, overflow_found = overflow:Has(item, amount, iscrafting)
-- ★★ 递归（★ 第一返回值 overflow_enough 被**丢弃** —— 见 L23）。
        num_found = num_found + overflow_found
-- ★ 只累加数量（★ 无「够了」的早退）。
    end
-- ↑ if 块结束。

-- ★★ 打开的容器统计 —— 与 RemoveItem:1440 的结构完全同构。
-- ★★★ ★ 三重排除（1541 行）：`container ~= overflow`、
--   `not excludefromcrafting`、`not readonlycontainer`。
-- ★★ ★★ 对照 1440 行的注释：那里说「排除不参与合成的容器」，
--   这里的 excludefromcrafting 名字直接点明了含义。
-- ★★ ★★ 1541 行的 `container ~= overflow` 是**必需的**：
--   因为 1531-1534 行已经统计过 overflow 了。
-- ★★ ★ 同样忽略了 container_enough（1542 行）—— 与 1532 同病。
    if checkallcontainers then
-- ↑ 打开的容器统计（三重排除）。
        local containers = self.opencontainers
-- ★ 打开的容器列表。

        for container_inst in pairs(containers) do
-- ★ 遍历。
            local container = container_inst.components.container or container_inst.components.inventory
-- ★★ `or .components.inventory` 兜底（第 3 处同款）。
            if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
-- ★★★★ 三重排除（★ 与 1444 行同款）。
				local container_enough, container_found = container:Has(item, amount, iscrafting)
-- ★★ 递归（★ container_enough 同样被丢弃）。
                num_found = num_found + container_found
-- ★ 累加数量。
            end
-- ↑ 排除块结束。
        end
-- ↑ 容器遍历结束。
    end
-- ↑ if checkallcontainers 块结束。

    return num_found >= amount, num_found
-- ★★★ return (够不够, 实际有多少) —— 双返回值契约。
end
-- ↑ Has 结束。

-- ★★ HasItemThatMatches(fn, amount) —— 「有多少物品满足谓词」。
-- ★★★ 与 Has 的差异：Has 用 prefab 名相等，本函数用**任意谓词**。
-- ★★★ ★ 这是「按条件检查材料」的实现，如「有没有任何可燃物」。
-- ★★ 1555 行的三元：`v.components.stackable and StackSize() or 1` ——
--   ★★★ ★ 注意这里**没有** `~= nil` 检查，直接 .StackSize()：
--     `v.components.stackable and X or 1` 在 stackable 存在时取 X。
--     ★ 安全（短路）。但若 StackSize() 返回 nil 会退化成 1。
-- ★★ ★ 搜索范围：itemslots + activeitem + overflow。
--   ⇒ ★★ **不含 equipslots，也不含打开的容器**。
--   ★ 与 Has 的范围不同（Has 也不含 equipslots，但 Has 的第三参数
--     可以打开容器搜索）。
-- ★★★ ★ 所以「我身上穿的装备算不算 HasItemThatMatches」= **不算**。
-- ★★ 这可能是有意的（谓词通常是关于材料的）。
function Inventory:HasItemThatMatches(fn, amount)
-- ↑ HasItemThatMatches 结束（★ 不含 equipslots —— 见 L24）。
	local num_found = 0
-- ★ 计数器。
	for k, v in pairs(self.itemslots) do
-- ★ 遍历普通槽。
		if fn(v) then
-- ★ 谓词命中？
			num_found = num_found + (v.components.stackable and v.components.stackable:StackSize() or 1)
-- ★★ 累加（★ 三元表达式：可堆叠算 StackSize，否则 1）。
		end
-- ↑ if 块结束。
	end
-- ↑ 遍历结束。

	if self.activeitem and fn(self.activeitem) then
-- ★ 手上物品也查。
		num_found = num_found + (self.activeitem.components.stackable and self.activeitem.components.stackable:StackSize() or 1)
-- ★ 累加（★ 同款三元）。
	end
-- ↑ if 块结束。

	local overflow = self:GetOverflowContainer()
-- ★ 取 overflow。
	if overflow then
-- ★ 有则递归。
		local overflow_enough, overflow_found = overflow:HasItemThatMatches(fn, amount)
-- ★★ 递归（★ 第一返回值同样被丢弃）。
		num_found = num_found + overflow_found
-- ★ 累加。
	end
-- ↑ if 块结束。

	return num_found >= amount, num_found
-- ★★★ return (够不够, 多少)。
end
-- ↑ HasItemThatMatches 结束。

-- ★★ HasItemWithTag(tag, amount) —— 「有多少带某标签的物品」。
-- ★★★ 与 HasItemThatMatches 的关系：
--   HasItemWithTag 是**特例** —— fn 就是 HasTag(tag)。
-- ★★★ ★ 但实现是**独立重写**的（不调用 HasItemThatMatches），
--   ⇒ ★★ 代码重复。若行为需要同步，得改两处。
-- ★★ 搜索范围同样：itemslots + activeitem + overflow（不含装备/容器）。
-- ★★★ ★ ★★ 这是本文件的一个**语义缺口**（见 L24）：
--   「身上有没有带 X 标签的东西」应该包含**装备**，
--   但本函数（和 Has 家族）都不查 equipslots。
-- ★★ 正确的做法是 FindItems（667 行）或 ForEachEquipment（701 行）。
-- ★ ★★ 这解释了 384 行 EquipHasTag 存在的必要性——
--   「查装备」必须用专门的方法。
function Inventory:HasItemWithTag(tag, amount)
-- ↑ HasItemWithTag 结束（★ 独立重写而非复用）。
    local num_found = 0
-- ★ 计数器。
    for k, v in pairs(self.itemslots) do
-- ★ 遍历普通槽。
        if v and v:HasTag(tag) then
-- ★ 带该标签？
            if v.components.stackable ~= nil then
-- ★ 可堆叠？
                num_found = num_found + v.components.stackable:StackSize()
-- ★ 加 StackSize。
            else
-- ★ else。
                num_found = num_found + 1
-- ★ 加 1。
            end
-- ↑ if/else 块结束。
        end
-- ↑ if 块结束。
    end
-- ↑ 遍历结束。

    if self.activeitem and self.activeitem:HasTag(tag) then
-- ★ 手上物品也查。
        if self.activeitem.components.stackable ~= nil then
-- ★ 可堆叠？
            num_found = num_found + self.activeitem.components.stackable:StackSize()
-- ★ 加 StackSize。
        else
-- ★ else。
            num_found = num_found + 1
-- ★ 加 1。
        end
-- ↑ if/else 块结束。
    end
-- ↑ if 块结束。

    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow。
    if overflow ~= nil then
-- ★ 有则递归。
        local overflow_enough, overflow_found = overflow:HasItemWithTag(tag, amount)
-- ★★ 递归（★ 第一返回值丢弃）。
        num_found = num_found + overflow_found
-- ★ 累加。
    end
-- ↑ if 块结束。

    return num_found >= amount, num_found
-- ★★★ return (够不够, 多少)。
end
-- ↑ HasItemWithTag 结束（★ 独立重写，未复用 HasItemThatMatches）。

-- ★★ GetItemsWithTag(tag) —— 「返回所有带某标签的物品」。
-- ★★★ 与 HasItemWithTag 的差异：返回**数组**而非计数。
-- ★★ ★★ 注意本函数**会展开 overflow**（1615 行递归），
--   与 HasItemWithTag 一致。
-- ★★ ★★ 1610 行 `table.insert(items, self.activeitem)` ——
--   ★★★ ⚠ 与 1605 行不同：1605 行有 `if v and v:HasTag(tag)` 双重检查，
--     而 1610 行只有 HasTag 检查（activeitem 一定非 nil，1609 行判过）。
--   ★ 一致，只是写法略省。
-- ★★ 1616-1618 行拼接 overflow 的结果。
function Inventory:GetItemsWithTag(tag)
-- ↑ GetItemsWithTag 结束（会展开 overflow）。
    local items = {}
-- ★ 结果数组。
    for k, v in pairs(self.itemslots) do
-- ★ 遍历普通槽。
        if v and v:HasTag(tag) then
-- ★ 带该标签？
            table.insert(items, v)
-- ★★ 加入结果（★ 返回的是**实体数组**不是 prefab 名）。
        end
-- ↑ if 块结束。
    end
-- ↑ 遍历结束。

    if self.activeitem and self.activeitem:HasTag(tag) then
-- ★ 手上物品也查（★ 1599 行版本只数数量）。
        table.insert(items, self.activeitem)
-- ★ 加入结果。
    end
-- ↑ if 块结束。

    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow。
    if overflow ~= nil then
-- ★ 有则递归（★ 这里**展开**而非计数）。
        local overflow_items = overflow:GetItemsWithTag(tag)
-- ★★ 递归取数组。
        for _, item in ipairs(overflow_items) do
-- ★ 遍历 overflow 的结果。
            table.insert(items, item)
-- ★ 逐个加入。
        end
-- ↑ 遍历结束。
    end
-- ↑ if 块结束。

    return items
-- ★★ return items（数组）。
end
-- ↑ GetItemsWithTag 结束。

-- 【§十六】★ GetItemByName(item, amount, checkallcontainers) ——
--   「找出 amount 个某 prefab 的物品，返回 {物品→数量} 映射」。
-- ★★★ ★★ 返回结构是 **反向映射**：`{ [物品实体] = 数量 }`。
--   ★★★ ★ 为什么用实体做 key？因为调用方（builder）要拿实体去扣除。
--   ★★★ ★ 这个映射的 key 是 Entity，value 是整数。
--   ★★ ★★ 原注释（★ 与 Has 同款取舍）：
--   "Note(Peter): We don't care about v.skinname for inventory
--    GetItemByName requests." —— 同 1506 行，不区分皮肤。
-- ★★ ★★ 这是 builder.lua:500 GetIngredients 用的函数，
--   它需要知道「用哪几个具体物品来合成」。
function Inventory:GetItemByName(item, amount, checkallcontainers) --Note(Peter): We don't care about v.skinname for inventory GetItemByName requests.
-- ↑ GetItemByName 函数头（返回 {实体→数量} 映射）。
    local total_num_found = 0
-- ★★ 两个累加器（总找到数 + 结果映射）。
    local items = {}
-- ★★ items = { [实体] = 数量 } —— ★ 反向映射。

-- ★★ tryfind —— 局部辅助函数（1628-1646 行）。
-- ★★★ ★ 核心逻辑（1631-1643 行）：`num_left_to_find = amount - total_num_found`
--   ★★★ ★★ 这里有一个**精妙的截断**（1633-1635 行）：
--     `if v.components.stackable.stacksize > num_left_to_find then`
--       items[v] = num_left_to_find   ← ★ **只标记需要的数量**！
--       num_found = amount           ← 宣告「够了」
--     else
--       items[v] = 整摞数量
--   ⇒ ★★★ 效果：返回的映射里，每个物品的数量都是**精确需求**，
--     而不是整摞的量。
-- ★★★ ★★ 这就是 builder.lua:546 RemoveIngredients 能正确扣除的原因：
--     它按 `for i = 1, v do RemoveItem(k, false)`（556-560 行）
--     **逐个**扣，只扣映射里标记的数量。
-- ★★★ ★ ★★ 推论：合成 3 个东西需要 5 个材料但只有一摞 10 个时，
--     返回 {那一摞=5}，扣料时只扣 5 个，**剩下 5 个留在背包**。
-- ★★★ ★ 这是「精确扣料」的实现，比「整摞拿走再补回」优雅得多。
-- ★ ★★ 1635 行 `num_found = amount`（不是 +=）——
--   ★★ 一个微妙的赋值：宣告「找到的总量已达需求」。
--   ★★ 因为这一摞就够补齐剩余需求，多找也没意义。
    local function tryfind(v)
-- ↑ tryfind 局部函数。
        local num_found = 0
-- ★★ 本次找到的数量（★ 局部）。
        if v and v.prefab == item then
-- ★ prefab 相同？
            local num_left_to_find = amount - total_num_found
-- ★★★ ★ 精确需求：剩余还要多少。
            if v.components.stackable then
-- ★ 可堆叠？
                if v.components.stackable.stacksize > num_left_to_find then
-- ★★★ 摞里的量 > 剩余需求？
                    items[v] = num_left_to_find
-- ★★★ items[v] = **剩余需求**（★ 只标记要拿的，不整摞记）。
                    num_found = amount
-- ★★ num_found = amount（★ 宣告「够了」而非实际数）。
                else
-- ★ else 分支：整摞都不够。
                    items[v] = v.components.stackable.stacksize
-- ★★★ items[v] = 整摞数量（★ 这就是「精确扣料」的另一面）。
                    num_found = num_found + v.components.stackable.stacksize
-- ★ 累加实际找到数。
                end
-- ↑ if/else 块结束。
            else
-- ★ else：非堆叠单件。
                items[v] = 1
-- ★★ items[v] = 1。
                num_found = num_found + 1
-- ★ 累加。
            end
-- ↑ if/else 块结束。
        end
-- ↑ if 块结束。
        return num_found
-- ★★ return num_found（★ 交给调用方累加到 total）。
    end
-- ↑ tryfind 结束。

-- ★★ 1648-1654 行：遍历 itemslots（有**顺序**的 for 循环 + 早退）。
-- ★★★ ★★ 与 1530 行的 Has 不同，这里有**早退**：
--   `if total_num_found >= amount then break end`（1651-1653）。
-- ★★ ★★ 这是性能差异的关键（对照 L23）。
-- ★★ ★★ 1648 行用 `for k = 1, self.maxslots`（有序）而非 pairs：
--   ⇒ ★★★ 确定性：**总是从低槽位开始取**。
--   ⇒ ★★ 合成用掉的材料总是背包靠前的部分。
    for k = 1,self.maxslots do
-- ↑ itemslots 有序遍历（★ 有早退）。
        local v = self.itemslots[k]
-- ★ 取该格物品（★ 有序遍历）。
        total_num_found = total_num_found + tryfind(v)
-- ★ 累加本格找到数。
        if total_num_found >= amount then
-- ★★★ 够了就 break（★ 与 Has 的无早退不同）。
            break
-- ★ 跳出。
        end
-- ↑ if 块结束。
    end
-- ↑ itemslots 遍历结束。

    if self.activeitem and self.activeitem.prefab == item and total_num_found < amount then
-- ★ 手上物品（★ 需 prefab 相同且还没凑够）。
        total_num_found = total_num_found + tryfind(self.activeitem)
-- ★ 累加。
    end
-- ↑ if 块结束。

-- ★★ overflow 递归 —— 注意第二参数是「剩余需求」。
-- ★★ 1662 行 `overflow:GetItemByName(item, (amount - total_num_found))` ——
--   ★★★ ★ 传入**剩余量**而不是原始 amount。
--   ★★★ 这是「增量查询」：先查普通栏，不够的部分才去 overflow 查。
-- ★★ 1661 行 `and total_num_found < amount` —— 够了就不查了。
    local overflow = self:GetOverflowContainer()
-- ↑ overflow 递归（传「剩余需求」）。
    if overflow and total_num_found < amount then
-- ★★★ overflow（★ 需还没凑够）。
        local overflow_items = overflow:GetItemByName(item, (amount - total_num_found))
-- ★★ 递归（★ 传**剩余需求**而非原始 amount）。
        for k,v in pairs(overflow_items) do
-- ★ 遍历 overflow 的结果映射。
            items[k] = v
-- ★★ 合并 overflow 的结果（★ key 是实体，不会覆盖）。
            total_num_found = total_num_found + v
-- ★ 累加数量。
        end
-- ↑ overflow 结果遍历结束。
    end
-- ↑ if overflow 块结束。

-- ★★ 打开的容器递归 —— 结构与 1660/1440/1536 完全同构。
-- ★★★ ★ 四处遍历 opencontainers（1440/1536/1669/1702）
--   是**完全相同的代码**，只有排除条件微调。
--   ⇒ ★★★ 这是本文件最大的复制粘贴重复（4 处 × 10 行）。
-- ★★ ★★ 1675 行同样传「剩余需求」`amount - total_num_found`。
    if checkallcontainers and total_num_found < amount then
-- ↑ 打开的容器递归（第 4 处复制粘贴）。
        local containers = self.opencontainers
-- ★ 打开的容器列表（★ 1673 行的无用赋值的孪生行）。

        for container_inst in pairs(containers) do
-- ★ 遍历。
-- ★★ 1673 行 `local containers = self.opencontainers` ——
--   ★★★ ★★ 这行是**无用赋值**（见 L25）：
--   下一行 1674 行立即用 pairs(containers) 重新遍历它，
--   而中间没有任何对它的修改。
-- ★★ 唯一可能的用途：避免遍历时容器被修改导致的问题——
--   但没有 copy 或快照。
-- ★★ ★ 与 1537/1702 行的同名局部变量对比：那里也一样是无用赋值。
--   ⇒ ★★★ 三处同样的「无害冗余」，可能是模板复制的残留。
            local container = container_inst.components.container or container_inst.components.inventory
-- ★★★ 无用赋值（见 L25）。
            if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
-- ★★★★ 三重排除（★ 与 1444/1541 行同款）。
                local container_items = container:GetItemByName(item, (amount - total_num_found))
-- ★★ 传「剩余需求」递归。
                for k,v in pairs(container_items) do
-- ★ 遍历容器返回的映射。
                    items[k] = v
-- ★ 合并进总映射。
                    total_num_found = total_num_found + v
-- ★ 累加。
                end
-- ↑ 内层遍历结束。
            end
-- ↑ 排除块结束。
            if total_num_found >= amount then
-- ★ 够了就停（★ ★ 相比 Has 家族，这里**有**早退）。
                break
-- ★ break。
            end
-- ↑ if 块结束。
        end
-- ↑ 容器遍历结束。
    end
-- ↑ if checkallcontainers 块结束。

    return items
-- ★★ return items（★ 可能不满 —— 不返回「够不够」）。
end
-- ↑ GetItemByName 结束。

-- 【§十七】★★ crafting_priority_fn —— ★★ 合成取料的排序规则。
-- ★★★ 这是本文件**唯一**的排序函数，作用是决定
--   「合成时优先吃掉哪些堆叠」。
-- ★★★ 三行逻辑：
--   ① 数量相同时 → 按槽位序号小的优先；
--   ② 否则 → **数量小的堆叠优先**（`return a.stacksize < b.stacksize`）。
-- ★★★★★ ★★ 为什么「小堆先吃」？（这是本函数的灵魂，详见下方详解）
-- ★★ ★★ 对照 Lua table.sort 的契约：返回 true 表示 a 应排在 b **之前**。
--   ★ `a.stacksize < b.stacksize` = 「数量少的排前面」。
-- ★★★ ★ 「数量相等则槽位小者优先」保证了**确定性**。
--   若没有这条，两个等大的堆叠的相对顺序取决于 table.sort 的实现，
--   而 Lua 的 table.sort **不稳定**。
--   ⇒ ★★★ 加上槽位比较后，结果完全确定，联机两端一致。
-- ★★ ★★ 这一点非常重要：**排序必须确定**，否则
--   「服务端与客户端各自算一遍」的逻辑会分歧。
local function crafting_priority_fn(a, b)
-- ★★★★★ crafting_priority_fn 结束（小堆优先 + 确定性）。
    if a.stacksize == b.stacksize then
-- ★★ 数量相同 → 按槽位序号定序（★ 保证排序确定性）。
        return a.slot < b.slot
-- ★★★ return a.slot < b.slot —— ★★ table.sort 不稳定，此行是关键。
    end
-- ↑ if 块结束。
    return a.stacksize < b.stacksize --smaller stacks first
-- ★★★★ return a.stacksize < b.stacksize —— ★★ 「小堆先吃」的核心。
end
-- ↑ 原英文注释保留（smaller stacks first）。

-- ↑ crafting_priority_fn 结束。
-- 【§十七】★★★ GetCraftingIngredient —— 「合成时该吃哪些物品」。
-- ★★★★ builder.lua:500 GetIngredients 的实际实现。
-- ★★★★ 返回 `{ [物品实体] = 数量 }` 映射（同 GetItemByName）。
-- ★★★★ 四个搜索源的**顺序极其重要**：
--   ① 1702-1713 行 **打开的容器**（最先！）；
--   ② 1715-1734 行 **普通背包槽**（按 crafting_priority_fn 排序）；
--   ③ 1736-1744 行 overflow（背包本体）；
--   ④ 1746-1751 行 activeitem（手上）；
-- ★★★★ ★★ 顺序的推理（从 1710-1712、1731-1733、1741-1743、
--   1753 的早退逻辑可以反推）：
--   · 1710 行：容器里够了就 **return**（后面全部不看）；
--   · 1731 行：普通槽够了就 return（不看 overflow 和手上）；
--   · 1741 行：overflow 够了就 return；
--   · 1753 行：全部走完，返回手上凑的那部分。
--   ⇒ ★★★ 这是一个**贪心（greedy）**算法：
--     「先到先用，不回头」。
-- ★★★ ★★ 与 GetItemByName（1624 行）的顺序**不同**！
--   GetItemByName：普通槽 → overflow → 打开的容器。
--   GetCraftingIngredient：打开的容器 → 普通槽 → overflow → 手上。
--   ⇒ ★★★ ★ 这是一个**真实的语义差异**（见 L26）：
--     「站在箱子边合成」时，合成会**优先消耗箱子里的材料**，
--     而 GetItemByName 优先消耗背包里的。
--   ★ 推断：这是**故意的**——玩家站在箱子边，
--     语义上「用箱子里的东西做」最符合直觉。
-- ★★★ ★★★ 1746 行的 activeitem 处理有个**独立区块**：
--   它没有早退，只是**追加**到 crafting_items（第 4 项）。
--   ★★★ ★ 与前三项不同：手上物品只在「其他都不够」时被用上。
function Inventory:GetCraftingIngredient(item, amount)
-- ↑ GetCraftingIngredient 函数头（四个搜索源）。
-- ★ local overflow = self:GetOverflowContainer() —— 取背包（用于排除）。
-- ★★ ★★ 注意 1703 行的排除条件里会用到它（`container ~= overflow`），
--   避免重复统计（overflow 在 1736 行单独处理）。
    local overflow = self:GetOverflowContainer()
-- ↑ 取 overflow（用于排除）。
    local crafting_items = {}
-- ★★ 结果映射（★ key = 实体，value = 数量）。
    local total_num_found = 0
-- ★ 累加器。

-- ★★ 搜索源①：**打开的容器**（优先）。
-- ★★★ ★ 1705 行 `container:GetCraftingIngredient(item, 剩余量, true)` ——
--   ★★★ ★★ 第三个参数 true 的含义：
--     推测是「是否递归搜索嵌套容器」。
--   ★★ ★★ 这说明 container.lua 有一个**同名方法**，
--     与 Inventory 的完全同构（互递归）。
-- ★★ ★ 1705-1708 行把结果**合并**进 crafting_items。
--   ★★★ ★ 注意 1706 行用 `crafting_items[k] = v`（直接覆盖），
--     不是累加 —— 若同一物品在两个容器里，只会记后一个的数量。
--   ⇒ ★★★ ⚠ 这是一个**潜在缺陷**（见 L27）：
--     1702 行遍历的多个容器可能装着**同一个 prefab 的不同实体**，
--     但 key 是实体，所以不会覆盖。
--   ★★★ 重新评估：key 是 Entity（不是 prefab 名），
--     所以 `crafting_items[k] = v` 不会覆盖——每个实体一个 key。
--   ⇒ ★★ **不是缺陷**。这是「实体为 key」设计的正确性保障。
-- ★★★ ★★ 但若同一实体在两个容器里（不应该发生）会覆盖。
--   属「不可能状态」的保护性覆盖。
-- ★ 1710-1712 行：够了就 return（★ 贪心的体现）。
    for container_inst in pairs(self.opencontainers) do
-- ↑ 搜索源①：打开的容器（★ 优先）。
        local container = container_inst.components.container or container_inst.components.inventory
-- ★★ `or .components.inventory` 兜底（第 4 处同款）。
        if container and container ~= overflow and not container.excludefromcrafting and not container.readonlycontainer then
-- ★★★★ 三重排除（★ 第 4 处复制粘贴）。
            for k, v in pairs(container:GetCraftingIngredient(item, amount - total_num_found, true)) do
-- ★★ 递归（★ 第三参 true = 递归嵌套容器）。
                crafting_items[k] = v
-- ★ 合并进结果。
                total_num_found = total_num_found + v
-- ★ 累加。
            end
-- ↑ 结果遍历结束。
        end
-- ↑ 排除块结束。
        if total_num_found >= amount then
-- ★★★ 够了就 return（★ 贪心：后面全不看）。
            return crafting_items
-- ★ 提前返回。
        end
-- ↑ if 块结束。
    end
-- ↑ 打开的容器遍历结束。

-- ★★ 搜索源②：**普通背包槽**（按优先级排序后取）。
-- ★★★ ★★ 1718 行的条件：`v.prefab == item and not v:HasTag("nocrafting")` ——
--   ★★★ ★★ ★★ **nocrafting 在这里是硬排除**（与 Has 的二义性不同！）。
--   ⇒ ★★ GetCraftingIngredient **无条件**排除 nocrafting。
--   ★★ 对比 Has（1509 行）：那里 nocrafting 与 checkallcontainers 绑定。
--   ⇒ ★★★ 两处对 nocrafting 的处理**不一致**（有意或无意）。
--   ★★★ ★★ 1719-1723 行构造排序用的临时记录：
--     { item = v, stacksize = ..., slot = i }
--   ★★ 注意字段名 stacksize 复用了 stackable 组件的概念，
--     但这里是「该摞的数量」（单件则为 1）。
    local items = {}
-- ↑ 搜索源②：普通槽（构造排序记录）。
    for i = 1, self.maxslots do
-- ★★ 有序遍历（★ 普通槽，1..maxslots）。
        local v = self.itemslots[i]
-- ★ 取该格物品。
		if v ~= nil and v.prefab == item and not v:HasTag("nocrafting") then
-- ★★★★ prefab 相同 **且** 非 nocrafting（★ 硬排除，见 1509 行的对照）。
            table.insert(items, {
-- ★★ 构造排序用的临时记录。
                item = v,
-- ★ item = 该实体。
				stacksize = v.components.stackable and v.components.stackable:StackSize() or 1,
-- ★★★ stacksize（★ 可堆叠则数量，否则 1）。
                slot = i,
-- ★ slot = 槽号（★ 用于确定性排序的第二关键字）。
            })
-- ↑ 记录表结束。
        end
-- ↑ if 块结束。
    end
-- ★★★ `table.sort(items, crafting_priority_fn)` —— ★★ 排序发生处。
-- ★★ ★★★ 这是 crafting_priority_fn 的**唯一**调用点（grep 核实）。
-- ★★★ ★★ 排序的作用（★ 见 1690 行的详解）：
--   小堆优先 → 让「刚好够」时尽量用完一整摞。
-- ★★ ★★ 举例：需要 3 个材料，背包有 [2 个的摞] 和 [5 个的摞]。
--   · 不排序（pairs 顺序）：可能先用 5 个的摞取 3 个 → 留下 2 个的摞；
--   · 排序后（小堆优先）：先用 2 个的摞 → 再从 5 个的摞取 1 → 
--     留下一个整齐的 4 个的摞。
-- ★★★ ★ 「留下整齐的堆叠」是背包整洁度的关键。
-- ★★ ★★★ 注意：这是**唯一**对 itemslots 做 table.sort 的地方，
--   其余遍历都是 pairs（有顺序）或有序 for。
    table.sort(items, crafting_priority_fn)
-- ★★★ 排序发生处（小堆优先 → 留下整齐堆叠）。
-- ★★★ 逐个消耗（贪心）：只取需要的量。
-- ★★ ★★ 1728 行 `math.min(v.stacksize, 剩余量)` —— ★ 关键：
--   · 摞里的数量够剩余需求 → 只取剩余需求（`items[v.item] = 剩余`）；
--   · 不够 → 整摞取（`items[v.item] = 全部`），继续下一摞。
-- ★★★ ★★ 这就是「精确扣料」的实现（与 1631 行的 tryfind 同思想，
--   但这里用了 math.min 更简洁）。
-- ★★ 1729 行 `crafting_items[v.item] = stacksize` —— key 是实体。
-- ★★ ★★ 1731-1733 行早退：够了就 return。
-- ★★★ ★ 注意这里 return 时**不会**再查 overflow 和手上。
--   ⇒ ★★ ★★★ 这是本函数与 GetItemByName 的**语义差异**：
--     「站在箱子边合成时，箱子里的材料优先被消耗，
--       即使背包里也有」——先到先用。
    for i, v in ipairs(items) do
-- ↑ 贪心消耗（math.min 精确取量）。
        local stacksize = math.min(v.stacksize, amount - total_num_found)
-- ★★★ ★ 精确取量：min(整摞量, 剩余需求)。
        crafting_items[v.item] = stacksize
-- ★★ 记入结果（★ key 是实体）。
        total_num_found = total_num_found + stacksize
-- ★ 累加。
        if total_num_found >= amount then
-- ★ 够了就 return（★ ★ 与 GetItemByName 的顺序差异核心）。
            return crafting_items
-- ★ 提前返回。
        end
-- ↑ if 块结束。
    end
-- ↑ 贪心循环结束。

-- ★★ 搜索源③：**overflow**（背包容体）。
-- ★★ ★★ 1737 行 `overflow:GetCraftingIngredient(item, 剩余量)` ——
--   ★★★ 注意这里**只传两个参数**（对比 1705 行传了三个 true）。
--   ⇒ ★★ 「是否递归嵌套容器」这个参数在 overflow 上没传。
--   ★★ 影响：背包里的箱子（背包套背包？）不会被递归搜索。
--   ★★★ ★ 这是一个**细微的不一致**（见 L28）。
--   ★★ 1741-1743 行早退（够了就 return，不看手上）。
    if overflow then
-- ↑ 搜索源③：overflow（★ 只传两参 —— 见 L28）。
        for k,v in pairs(overflow:GetCraftingIngredient(item, amount - total_num_found)) do
-- ★★ 递归到 overflow（★ ★ 只传两参 —— 见 L28）。
            crafting_items[k] = v
-- ★ 合并结果。
            total_num_found = total_num_found + v
-- ★ 累加。
        end
-- ↑ 结果遍历结束。
        if total_num_found >= amount then
-- ★ 够了就 return（★ 仍不看手上的）。
            return crafting_items
-- ★ 提前返回。
        end
-- ↑ if 块结束。
    end
-- ↑ overflow 块结束。

-- ★★ 搜索源④：**activeitem**（手上）—— 最后，且**不早退**。
-- ★★★ ★★ 1747-1750 行的写法很特殊：
--   `crafting_items[self.activeitem] = math.min(数量, 剩余量)`
-- ★★ ★★ 直接算好数量塞进去，**没有循环、没有早退**。
--   ⇒ ★★★ 因为它只有一个候选，够不够都得记。
-- ★★ ★★ 若剩余量已经是负数（前面凑超了）？
--   `math.min(stacksize, 负数)` = 负数！
--   ⇒ ★★★ ⚠ 这会在 crafting_items 里塞一个**负数量**！
--   ⚠⚠ 见 L29：这是一个真实的边界缺陷。
-- ★★★ 推理：前面三个源都有 `if total >= amount then return` 的早退，
--   所以到达 1746 行时 total_num_found < amount，剩余量 > 0。
--   ⇒ ★★ **实际上安全**。早退保证了剩余量必为正。
--   ★★ 结论：不是缺陷，是「依赖上游早退保证」的脆弱正确。
-- ★★★ ★★ 若将来有人在 1744 行后加了分支而忘记早退，就会崩。
-- ★★★ ★★ 1746 行的条件也排除了 nocrafting（与 1718 行一致）。
	if self.activeitem ~= nil and self.activeitem.prefab == item and not self.activeitem:HasTag("nocrafting") then
-- ↑ 搜索源④：activeitem（不早退，靠上游保证剩余为正）。
		crafting_items[self.activeitem] = math.min(
-- ★★ 手上物品：直接算好数量。
			self.activeitem.components.stackable and self.activeitem.components.stackable:StackSize() or 1,
-- ★★★ 第一参：手上的数量（★ 三元表达式）。
			amount - total_num_found
-- ★★★ 第二参：剩余需求（★ 依赖上游早退保证为正 —— 见 L29）。
		)
-- ↑ math.min 调用结束。
    end
-- ↑ if 块结束。

-- ★★ `return crafting_items` —— 全部走完，返回结果。
-- ★★★★ ★★ **注意此时不再检查是否真的够了**：
--   函数会返回一份「可能不足」的映射，由调用方判断。
-- ★★★ ★ 调用方（builder.lua:500）确实需要自己检查：
--   它把结果交给 RemoveIngredients 扣除，扣多少算多少。
-- ★★ ★★ 推断：builder 应该有独立的「材料是否够」的判定
--   （在 recipes.lua 或 builder 的别处）。
-- ★★★ ★ 但注意：这个函数**不返回「是否足够」**的布尔！
--   ⇒ ★★ 相比 Has（返回「够不够」+「有多少」），
--     GetCraftingIngredient **信息量更少**。
-- ★★ 这是一个**接口设计的不对称**（见 L30）。
    return crafting_items
-- ★★★ return crafting_items（★ 不返回「是否足够」—— 见 L30）。
end
-- ↑ GetCraftingIngredient 结束（1753 行的 return 是隐式返回）。

-- 【§十七】★★ tryconsume —— 局部辅助函数：吃掉 N 个物品。
-- ★★★★ 三分支（1757-1767 行）：
--   ① 无 stackable（单件）→ RemoveItem + Remove（1758）；
--   ② 数量 > amount → 减 amount 个（1760-1762）；
--   ③ 数量 <= amount → 整摞移除（1763-1767）。
-- ★★★ ★★★ 分支①的链式调用：`self:RemoveItem(v):Remove()` ——
--   ★★★ ★ 这就**依赖** 1453 行的兜底（RemoveItem 找不到也返回 v）。
--   ★★★ 若 RemoveItem 返回 nil（传入 nil），这里会崩 —— 见 L2。
-- ★★ ★★ 返回值语义（三个分支各不相同）：
--   · 分支①：返回 **1**（吃了一个）；
--   · 分支②：返回 **amount**（吃了 amount 个）；
--   · 分支③：返回 **amount = stacksize**（★ 改了 amount 的值！）。
-- ★★★ ★★ 分支③的 `amount = v.components.stackable.stacksize` 会
--   **重新赋值参数**！返回的是实际的 stacksize，不是请求的 amount。
--   ⇒ ★★ 这正是调用方需要的：「实际吃了多少」。
-- ★★ ★★ 1768-1769 行的 `return 0` 与注释 "--shouldn't be possible?" ——
--   ★★★ 三重 if/elseif 已覆盖所有情况，这个 return 0 **不可达**。
--   ★★ 但它是防御性的（万一 stacksize 为负等异常）。
-- ★★★ 注意作者自己标了「?」（不确定），说明这是「保险起见」。
local function tryconsume(self, v, amount)
-- ↑ tryconsume 结束（三分支，返回「实际吃掉数」）。
    if v.components.stackable == nil then
-- ★★ 分支①：非堆叠单件。
        self:RemoveItem(v):Remove()
-- ★★★ 链式调用（★ 依赖 1453 行兜底才不崩）。
        return 1
-- ★★ return 1 —— 「实际吃掉 1 个」。
    elseif v.components.stackable.stacksize > amount then
-- ★★ 分支②：摞里的量 > 需求量。
        v.components.stackable:SetStackSize(v.components.stackable.stacksize - amount)
-- ★ SetStackSize 递减（★ 走 setter，事件正常）。
        return amount
-- ★★ return amount（★ 吃了要的那个数）。
    else
-- ★ else 分支：整摞都不够。
        amount = v.components.stackable.stacksize
-- ★★★★ ★★ 重新赋值 amount 为实际 stacksize（★ 关键设计！）。
        self:RemoveItem(v, true):Remove()
-- ★★★ 整摞移除（★ wholestack=true）+ 销毁。
        return amount
-- ★★ return amount（★ 是**实际**吃掉的数，不是请求数）。
    end
    --shouldn't be possible?
-- ↑ 原英文注释保留（shouldn't be possible?）。
    return 0
-- ★★ return 0 —— ★ 理论不可达的防御分支。
end
-- ↑ tryconsume 结束。

-- 【§十七】★ ConsumeByName(item, amount) —— 「吃掉 N 个某 prefab 的物品」。
-- ★★★ 用于「消耗材料」的场景（如某些 buff 的持续消耗、事件惩罚）。
-- ★★★ 原注释（同 1506/1624 行的取舍）：不区分 skinname。
-- ★★★ ★★ 三个搜索源的顺序：**普通槽 → 手上 → overflow**。
--   ★★ ★★ 注意与 GetCraftingIngredient 的顺序**完全不同**：
--     GetCraftingIngredient：容器 → 普通槽 → overflow → 手上；
--     ConsumeByName：      普通槽 → 手上 → overflow。
--   ⇒ ★★★ 连本文件内部的「消耗顺序」都不统一（见 L26 的延伸）。
-- ★★ ★★ 1797 行 `overflow:ConsumeByName(item, amount)` ——
--   ★★★ ★ 注意传的是**剩余的 amount**（1781/1789 行已减去吃掉的）。
--   ★★★ 且**没有返回值接收**：overflow 吃掉了多少，本函数不知道。
--   ⇒ ★★ 函数返回 nil（无返回值），调用方无法知道实际消耗量。
-- ★★★ ★ 这与 1782/1790 行的早退 `if amount <= 0 then return end` 配合：
--   够早就 return，不会白跑 overflow。
-- ★★ ★★ 1781 行 `amount = amount - tryconsume(self, v, amount)` ——
--   ★★★ ★★ 这是「剩余量递减」的标准贪心模式。
--   ★★★ ★★ 注意 tryconsume 返回的是**实际吃掉的数量**（见 1756 行），
--     所以 `amount - 实际吃掉的` 才是正确的剩余量。
--   ★★ 若 tryconsume 返回的是「请求的数量」，就会算错。
--     ⇒ ★★★ ★ 这就是 1756 行分支③「重设 amount」的价值所在。
function Inventory:ConsumeByName(item, amount) --Note(Peter): We don't care about v.skinname for inventory ConsumeByName requests.
-- ↑ ConsumeByName 函数头（★ 搜索顺序与取料不同）。
    amount = amount or 1
-- ★ amount 默认 1（★ nil ⇒ 只吃一个）。
    if amount <= 0 then
-- ★★★ 数量为 0 或负 → 直接返回（★ 不做任何事）。
        return
-- ★ 早退。
    end
-- ↑ 守卫块结束。

    for k = 1, self.maxslots do
-- ★★ 有序遍历普通槽（★ 消耗顺序：从低槽位开始）。
        local v = self.itemslots[k]
-- ★ 取该格物品。
        if v ~= nil and v.prefab == item then
-- ★ prefab 相同？
            amount = amount - tryconsume(self, v, amount)
-- ★★★★ ★ 剩余量递减（★ 减去**实际**吃掉的数 —— 见 1764 行）。
            if amount <= 0 then
-- ★ 吃够了？
                return
-- ★ 提前返回。
            end
-- ↑ if 块结束。
        end
-- ↑ if 块结束。
    end
-- ↑ itemslots 遍历结束。

    if self.activeitem ~= nil and self.activeitem.prefab == item then
-- ★★ 手上物品（★ 排在 overflow 之前 —— 与取料顺序不同）。
        amount = amount - tryconsume(self, self.activeitem, amount)
-- ★ 剩余量递减。
        if amount <= 0 then
-- ★ 吃够了？
            return
-- ★ 提前返回。
        end
-- ↑ if 块结束。
    end
-- ↑ activeitem 块结束。

    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow。
    if overflow ~= nil then
-- ★ 有则处理。
        overflow:ConsumeByName(item, amount)
-- ★★★★ 递归（★ ★ 返回值未接收 —— 不知道实际吃了多少）。
    end
-- ↑ if 块结束。
end
-- ↑ ConsumeByName 结束（★ 无返回值）。

-- 【§十四】★ DropEverythingWithTag(tag) —— 「丢掉所有带某标签的东西」。
-- ★★★ 用途：玩家死亡时丢任务道具（"taskitems"）、
--   被诅咒时丢某些东西（"curseditem"）等。
-- ★★★★ 三段循环 + 一个「容器递归」收尾（1802-1835 行）：
--   ① 1804-1811 行 activeitem；
--   ② 1813-1822 行 itemslots；
--   ③ 1824-1830 行 equipslots；
--   ④ 1832-1834 行 对收集到的容器递归调用自身。
-- ★★★ ★★ 核心设计（★★★ 「延迟到循环结束后再递归」）：
--   循环中遇到「带 tag 的」→ 立刻丢掉；
--   遇到「是容器的」→ **暂存到 containers 表**，不立即递归。
--   ★★★ 为什么要延迟？因为 1878 行的 DropItem 会修改 self.itemslots，
--     而我们正在遍历它。递归进去会引发**嵌套遍历**。
--   ⇒ ★★★ 先把所有容器收集起来，循环结束后统一递归。
--   ⇒ ★★ 这是「避免在遍历中修改被遍历对象」的标准做法（比 L3 的写法好）。
-- ★★★ ★ 与 L3 对照：DestroyContents（1929 行）在装备循环里**直接**调
--   RemoveItem（会修改 equipslots），而这里**只 DropItem 装备**
--   （DropItem → RemoveFromOwner → 可能 Unequip → 修改 equipslots！）。
--   ⇒ ★★ 等一下，1824-1830 行也在遍历 equipslots 时调 DropItem，
--     而 DropItem 内部会 Unequip（1426 行）→ `equipslots[k] = nil`。
--   ⇒ ★★★ 这就是 L7 描述的「遍历中修改」，本函数也有同样的问题。
--   ★★ 区别：本函数遍历的是 equipslots（哈希表），
--     RemoveItem 删的是同一个键。Lua 允许「遍历时给当前键赋 nil」。
--     ⇒ ★ 实际安全，但脆弱。
function Inventory:DropEverythingWithTag(tag)
-- ↑ DropEverythingWithTag 结束（★ 三段循环 + 延迟递归）。
    local containers = {}
-- ★★ 待递归的容器列表（★ 延迟到循环后处理）。

-- ★ activeitem 处理 —— 与后面两段结构相同。
-- ★★ ★★ 注意 1807 行：`self:SetActiveItem(nil)` **在** DropItem 之后。
--   ⇒ ★★★ 顺序与 327 行 DropActiveItem 一致（先丢再清状态）。
-- ★★ 1808 行 `elseif self.activeitem.components.container ~= nil` ——
--   ★★★ 「不是目标 tag，但是个容器」→ 收集起来等下递归。
--   ★★ 这意味着：背包（overflow）也会被递归检查。
--   ★★★ ⇒ 「丢光背包里所有任务道具」也会生效。合理。
    if self.activeitem ~= nil then
-- ↑ activeitem 处理。
        if self.activeitem:HasTag(tag) then
-- ★★ 带目标标签？
            self:DropItem(self.activeitem, true, true)
-- ★ 整摞、随机方向丢弃。
            self:SetActiveItem(nil)
-- ★★★ SetActiveItem(nil) 清状态（★ 在 DropItem 之后）。
        elseif self.activeitem.components.container ~= nil then
-- ★ elseif 分支。
            table.insert(containers, self.activeitem)
-- ★★ 不是目标但是容器 → 收集起来。
        end
-- ↑ elseif 块结束。
    end
-- ↑ activeitem 块结束。

-- ★★ itemslots 循环 —— **有序 for**（1..maxslots）。
-- ★★ ★★ 注意这里用的是有序 for 而非 pairs：
--   ⇒ ★★★ 因为循环体里 DropItem 会把 itemslots[k] 置 nil，
--     用 for 遍历时该槽位后续不再访问（for 不回退），安全。
--   ★★ 对比 128/1824 行的 pairs 遍历（会有 L7 的问题）。
-- ★★★ ★ 这里的选择比 1824 行更稳妥！
    for k = 1, self.maxslots do
-- ↑ itemslots 循环（有序 for，★ 比装备循环更稳妥）。
        local v = self.itemslots[k]
-- ★ 取该格物品。
        if v ~= nil then
-- ★ 非空才处理。
            if v:HasTag(tag) then
-- ★ 带目标标签？
                self:DropItem(v, true, true)
-- ★ 丢弃。
            elseif v.components.container ~= nil then
-- ★ else 分支。
                table.insert(containers, v)
-- ★ 是容器 → 收集。
            end
-- ↑ else 块结束。
        end
-- ↑ if v 块结束。
    end
-- ↑ itemslots 循环结束。

-- ★★ equipslots 循环 —— **pairs**（与前面两段不同！）。
-- ★★★ ★★★ 这是一个**真实的不一致**（见 L7）：
--   · itemslots 循环（1813 行）用有序 for；
--   · equipslots 循环（1824 行）用 pairs。
--   ★★ 循环体 DropItem → RemoveFromOwner → Unequip → `equipslots[k] = nil`。
--   ⇒ ★★★ 在 pairs 遍历中给**当前键**赋 nil 是允许的（不会漏遍历），
--     所以实际安全。
--   ★★★ ★ 但 1860 行（ByFilter 版）和 1957 行（DestroyContents 版）
--     同样是 pairs 遍历 + 修改。**三处同样的写法**。
--   ⇒ ★★★ 结论：这是「一致的不安全」—— 全文件统一用 pairs，
--     依赖 Lua 的 next 语义。移植时若改成 table.remove 就会全崩。
    for k, v in pairs(self.equipslots) do
-- ★★ equipslots 循环（pairs，见 L7）。
        if v:HasTag(tag) then
-- ★ 带目标标签？
            self:DropItem(v, true, true)
-- ★ 丢弃（★ DropItem 会 Unequip ⇒ 修改被遍历的表，见 L7）。
        elseif v.components.container ~= nil then
-- ★ else 分支。
            table.insert(containers, v)
-- ★ 是容器 → 收集。
        end
-- ↑ else 块结束。
    end
-- ↑ equipslots 循环结束（★ 用 pairs）。

-- ★★★ 容器递归 —— 循环结束后统一处理。
-- ★★★ ★★ `v.components.container:DropEverythingWithTag(tag)` ——
--   ★★★ ★★★ 这是**跨组件的同名方法递归调用**：
--     Inventory:DropEverythingWithTag（这里）
--       ↕ 互相调用
--     Container:DropEverythingWithTag（container.lua）
--   ⇒ ★★★ ★★ 两个组件实现了**完全同构**的递归算法。
-- ★★ 这与 GetOverflowContainer / GetSpecializedContainers 的
--   「容器与背包的对称性」是同一套设计思想。
-- ★★★★ ★★ 递归无深度上限（与 L7 的 CheckMigrationPets 同病）：
--   容器套容器可以无限深，理论上会爆栈。
--   ★ 实践中容器嵌套不超过 2-3 层。
    for i, v in ipairs(containers) do
-- ★★★ 容器递归（延迟到循环结束后）。
        v.components.container:DropEverythingWithTag(tag)
-- ★★★ 跨组件递归（★ 与 container.lua 的同名方法互调）。
    end
-- ↑ 容器递归循环结束。
end
-- ↑ DropEverythingWithTag 结束。

-- ★★ DropEverythingByFilter(filterfn) —— 「丢掉所有满足谓词的东西」。
-- ★★★★ 与 1801 行 DropEverythingWithTag **完全同构**，只是判定方式不同：
--   · WithTag：`v:HasTag(tag)`；
--   · ByFilter：`filterfn(self.inst, v)`。
-- ★★★ ★★ ByFilter 的谓词**多一个参数**：owner（self.inst）。
--   ★★★ ⇒ ★★ 谓词签名是 `(owner, item) -> boolean`。
--   ★★★ 为什么要传 owner？因为某些判定需要知道「谁在丢」：
--   如「只丢本人物品，不丢临时授予的装备」。
-- ★★★ ★★ 1841/1852/1861 三处的 filterfn 调用**完全相同**，
--   加上 1805/1816/1825 三处的 HasTag 调用，
--   ⇒ ★★★ 两个函数可以**完全合并**为「判定函数 + 丢弃」的模板。
--   ★★ 这就是 L14 描述的复制粘贴问题。
function Inventory:DropEverythingByFilter(filterfn)
-- ↑ DropEverythingByFilter 结束（★ 与 WithTag 完全同构）。
    local containers = {}
-- ★ 待递归容器列表。

    if self.activeitem ~= nil then
-- ★ 手上有东西？
        if filterfn(self.inst, self.activeitem) then
-- ★★ 谓词命中（★ 签名 (owner, item)）。
            self:DropItem(self.activeitem, true, true)
-- ★ 丢弃。
            self:SetActiveItem(nil)
-- ★ SetActiveItem(nil)。
        elseif self.activeitem.components.container ~= nil then
-- ★ else 分支。
            table.insert(containers, self.activeitem)
-- ★ 是容器 → 收集。
        end
-- ↑ else 块结束。
    end
-- ↑ activeitem 块结束。

    for k = 1, self.maxslots do
-- ★ 有序遍历普通槽。
        local v = self.itemslots[k]
-- ★ 取该格物品。
        if v ~= nil then
-- ★ 非空才处理。
            if filterfn(self.inst, v) then
-- ★ 谓词命中？
                self:DropItem(v, true, true)
-- ★ 丢弃。
            elseif v.components.container ~= nil then
-- ★ else 分支。
                table.insert(containers, v)
-- ★ 是容器 → 收集。
            end
-- ↑ else 块结束。
        end
-- ↑ if v 块结束。
    end
-- ↑ itemslots 循环结束。

    for k, v in pairs(self.equipslots) do
-- ★★ 装备槽遍历（★ pairs —— 与 itemslots 的有序 for 不同，见 L7）。
        if filterfn(self.inst, v) then
-- ★ 谓词命中？
            self:DropItem(v, true, true)
-- ★ 丢弃（★ 会 Unequip ⇒ 修改表）。
        elseif v.components.container ~= nil then
-- ★ else 分支。
            table.insert(containers, v)
-- ★ 是容器 → 收集。
        end
-- ↑ else 块结束。
    end
-- ↑ equipslots 循环结束。

    for i, v in ipairs(containers) do
-- ★ 遍历待递归容器。
        v.components.container:DropEverythingByFilter(filterfn)
-- ★★★ 跨组件递归（★ 传同一个 filterfn）。
    end
-- ↑ 递归循环结束。
end
-- ↑ DropEverythingByFilter 结束。

-- 【§十四】★★★ DropEverything —— 「丢掉所有东西」。最常被调用的清理函数。
-- ★★★★ 三参数：ondeath（是否死亡导致）、keepequip（保留装备）。
-- ★★★★ 六个特判（★ 每个都有存在理由）：
--   ① 1874-1877 行 wilderness 模式下 ondeath 被**强制改为 false**；
--   ② 1878 行 activeitem 的 keepondeath；
--   ③ 1887 行 普通槽的 keepondeath **且** 不是 curseditem；
--   ④ 1888 行 islockedinslot → 不丢（除非是容器）；
--   ⑤ 1907-1909 行 EmptyBeard（威尔逊的胡子要单独清）；
--   ⑥ 1912 行 装备的 keepondeath。
-- ★★★ ★★ 1874-1877 行是**模式覆盖**（★ 很有意思的设计）：
--   `if HasTag("player") and not GetGhostEnabled() and not revivable_corpse then`
--     `ondeath = false`
--   ★★★ 推理：荒野模式（wilderness）里死亡不会变成幽灵、
--     也不产生可复活尸体 ⇒ 玩家会被「重开」⇒ 物品必须**全部**掉出。
--   ⇒ ★★ 「keepondeath 的物品在荒野模式下也会掉」——
--     因为一旦重开，这些物品就永远失去了。
--   ★★★ ★★ 这是「死亡规则随模式变化」的正确处理位置。
--   ★★ 注释解释：某些物品（如 Wanda 的手表）正常情况下留在栏里，
--     但荒野模式强制重开，必须全掉。
function Inventory:DropEverything(ondeath, keepequip)
-- ↑ DropEverything 函数头（六个特判）。
    if self.inst:HasTag("player") and not GetGhostEnabled() and not GetGameModeProperty("revivable_corpse") then
-- ★★★★ 荒野模式的判定（★ 三重与）。
        -- NOTES(JBK): This is for items like Wanda's watches that normally stick inside the inventory but Wilderness mode will force the player to reroll so drop everything.
-- ↑ 原注释保留（JBK：Wanda 手表在荒野模式必须掉）。
        ondeath = false
-- ★★★ ondeath = false —— ★ 强制「当作不是死亡」⇒ keepondeath 失效。
    end
-- ↑ 模式判定块结束。
-- ★★★ activeitem 的丢弃判定（1878-1881 行）。
-- ★★ `not (ondeath and self.activeitem.components.inventoryitem.keepondeath)` ——
--   ★★★ ★★ keepondeath 标签的语义：**只在死亡时保留**。
--   ★★★ ★★ 双重否定：
--     · ondeath 为 false（主动调用）→ 无论有没有标签都**丢掉**；
--     · ondeath 为 true 且有 keepondeath → **保留**。
--   ⇒ ★★★ ★「keepondeath」不是「永不丢弃」，是「死亡时不丢弃」。
-- ★★ 1879 行 `DropItem(self.activeitem, true, true)` —— 整摞、随机方向。
-- ★★ 1880 行 SetActiveItem(nil) —— 在 DropItem **之后**清状态。
    if self.activeitem ~= nil and not (ondeath and self.activeitem.components.inventoryitem.keepondeath) then
-- ↑ activeitem 丢弃（keepondeath 双重否定）。
        self:DropItem(self.activeitem, true, true)
-- ★ 丢弃手上的东西。
        self:SetActiveItem(nil)
-- ★ SetActiveItem(nil)。
    end
-- ↑ activeitem 块结束。

-- ★★ internal_containers —— 收集「锁定但有内容」的容器。
-- ★★★ ★★ 1887-1897 行的四重判定：
--   ① ondeath 和 keepondeath → 跳过（保留）；
--   ② components.curseditem → 跳过（诅咒物品不能掉）；
--   ③ islockedinslot → **不丢普通物品，但如果是容器要收集**；
--   ④ 否则 → DropItem。
-- ★★★ ★★ 1888-1896 行的分支是本函数最微妙的部分：
--   `if not v.components.inventoryitem.islockedinslot then`
--     DropItem(v)              ← 普通锁定物品：丢掉？不对，见下
--   `elseif v.components.container then`
--     收集起来                 ← 锁定的容器：收集其内容并丢容器自身
-- ★★★ ★★ 重新解读：islockedinslot 的物品**不进第一个分支**（不丢），
--   只在「且是容器」时被收集。
--   ⇒ ★★ 等等，条件是 `if NOT islockedinslot then DropItem`。
--     所以：**非锁定 → 丢；锁定且是容器 → 收集；锁定非容器 → 什么都不做**。
--   ★★★ ★★ 这意味着：锁定物品（非容器）在死亡时**保留在背包里**。
--   ★★ 这是 islockedinslot 的第四种语义（前三种见 241/552/724 行）。
--   ⇒ ★★ 汇总 islockedinslot 的全部语义：
--     ① 241 行：锁定槽不能被替换（但可堆叠合并）；
--     ② 552 行：锁定物品不能被拿到手上；
--     ③ 724 行：锁定物品不能被丢弃（非堆叠时）；
--     ④ 1888 行：锁定物品在 DropEverything 时保留。
--   ★★★ ★ 这是一个「全局禁止移动」的复合标志。
-- ★★ 1891-1895 行的惰性建表：`internal_containers = internal_containers or {v}`
--   ★★★ 与 1889-1894 的 if/else 是**等价**的两种写法（后者更啰嗦）。
-- ★★ ★ 隐含约定：锁定的容器**内容会被清空，但容器本身保留**。
--   理由：容器本身被锁定（不能丢弃），但它的内容不是。
-- ★★ 1900-1904 行：循环结束后统一递归清空容器内容。
-- ★★★ `v.components.container:DropEverything()` —— **无参数**！
--   ⇒ ★★★ 与 1833 行的 `DropEverythingWithTag(tag)` 不同。
--   ⇒ Container:DropEverything 的签名**没有 ondeath 参数**。
--   ★★ 这意味着容器里的 keepondeath 物品**不会被保留**。
--   ⚠ 见 L31：一个潜在的不一致。
	local internal_containers
-- ↑ internal_containers 收集起点。

-- ↑ 空行。
    for k = 1, self.maxslots do
-- ★★ 有序遍历普通槽（★ 比 equipslots 的 pairs 更稳妥）。
        local v = self.itemslots[k]
-- ★ 取该格物品。
        if v ~= nil and not (ondeath and v.components.inventoryitem.keepondeath) and not v.components.curseditem then
-- ★★★★ 三重排除：非 keepondeath + 非 curseditem + （在下一层）。
			if not v.components.inventoryitem.islockedinslot then
-- ★★★ 分支①：非锁定物品 → 丢弃。
				self:DropItem(v, true, true)
-- ★★ 整摞、随机方向。
			elseif v.components.container then
-- ★ else 分支：锁定物品。
				if internal_containers then
-- ★ 是容器？（★ 累加器已存在）。
					table.insert(internal_containers, v)
-- ★ 追加收集。
				else
-- ★ else 分支。
					internal_containers = { v }
-- ★★ 惰性建表（★ `{ v }` 即单元素数组）。
				end
-- ↑ if/else 块结束。
			end
-- ↑ elseif 块结束。
        end
-- ↑ if 块结束。
    end
-- ↑ itemslots 循环结束。

	if internal_containers then
-- ★ 有待清理的锁定容器？
		for _, v in ipairs(internal_containers) do
-- ★ 遍历它们。
			v.components.container:DropEverything()
-- ★★★ 递归清空内容（★ **无参数** ⇒ 容器内的 keepondeath 不保留，见 L31）。
		end
-- ↑ 递归循环结束。
	end
-- ↑ if 块结束。

-- ★★ `if not keepequip then` —— 是否丢掉装备。
-- ★★ ★ 1907-1909 行：`self.inst.EmptyBeard()` ——
--   ★★★ 威尔逊的胡子是**独立实体**，存在实体字段上而非装备槽。
--   ⇒ ★★★ 需要专门清理。这说明「物品栏视图」并非总是三张表——
--     某些角色的特殊「装备」挂在实体字段上。
-- ★★ 1911-1915 行：遍历装备槽丢弃。
-- ★★★ ★ 1912 行的 keepondeath 判定：
--   `not (ondeath and v.components.inventoryitem.keepondeath)` ——
--   与 1878 行同款语义。
-- ★★★ ★★ 注意：**装备槽的循环没有 islockedinslot 保护**！
--   （对比 1888 行的普通槽有）。
--   ⇒ ★★★ 锁定装备在死亡时**会被丢掉**。
--   ★★ 这可能是有意的（死亡时所有装备都该掉），
--     也可能是遗漏（普通槽保护了，装备槽没有）。见 L32。
    if not keepequip then
-- ★★ keepequip 分支。
        if self.inst.EmptyBeard ~= nil then
-- ↑ EmptyBeard（威尔逊的胡子是独立实体）。
            self.inst:EmptyBeard()
-- ★★ 威尔逊的胡子（★ 独立实体，不在 equipslots）。
        end
-- ↑ EmptyBeard 块结束。

        for k, v in pairs(self.equipslots) do
-- ★ 遍历装备槽（★ pairs，见 L7）。
            if not (ondeath and v.components.inventoryitem.keepondeath) then
-- ★★★ keepondeath 双重否定（★ 与 1878 行同款语义）。
                self:DropItem(v, true, true)
-- ★ 丢弃。
            end
-- ↑ if 块结束。
        end
-- ↑ equipslots 循环结束。
    end
-- ↑ if not keepequip 块结束。
end
-- ↑ DropEverything 结束。

-- ★★ DropEquipped(keepBackpack, keepPreventUnequipping) ——
--   「只丢装备」。
-- ★★★ 两个保留条件（1921-1922 行）：
--   · keepBackpack 为真 且 有 "backpack" 标签 → 保留；
--   · keepPreventUnequipping 为真 且 ShouldPreventUnequipping → 保留。
-- ★★★ ★★ 1921 行的 backpack 标签：
--   与 GetOverflowContainer（1463 行）不同——那里是 BODY 槽 + container 组件，
--   这里是**标签**判定。
--   ⇒ ★★★ 两处判定「什么是背包」的方式**不一致**：
--     · GetOverflowContainer：位置（BODY 槽）+ 组件（container）；
--     · DropEquipped：标签（backpack）。
--   ★★ 推断：标签是给「哪些东西算背包」的**显式声明**，
--     而 GetOverflowContainer 是「结构推导」。
--   ★★★ ★ ⇒ 若某件带 backpack 标签但没有 container 组件的物品，
--     它会被 DropEquipped 保留，却不是 overflow。语义缝隙。
-- ★★ 1922 行 `v.components.equippable and ShouldPreventUnequipping()` ——
--   有 equippable 组件才检查（双重保护，参照 172 行的风格）。
function Inventory:DropEquipped(keepBackpack, keepPreventUnequipping)
-- ↑ DropEquipped 结束（★ backpack 标签 vs 组件判定不一致）。
    for k, v in pairs(self.equipslots) do
-- ★ 遍历装备槽（★ ★ 没有 islockedinslot 保护 —— 见 L32）。
		if not (keepBackpack and v:HasTag("backpack")) and
-- ★★ 保留背包？
			not (keepPreventUnequipping and v.components.equippable and v.components.equippable:ShouldPreventUnequipping())
-- ★★ 保留「防卸锁」的装备？
		then
-- ↑ then 起始。
            self:DropItem(v, true, true)
-- ★ 丢弃。
        end
-- ↑ 条件块结束。
    end
-- ↑ equipslots 循环结束。
end
-- ↑ DropEquipped 结束。

-- ★★ DestroyContents —— 「销毁所有物品内容」。
-- ★★★★ 与 DropEverything 的区别：
--   · DropEverything 丢到**地上**（物品还存在）；
--   · DestroyContents **彻底删除**（:Remove()，实体消失）。
-- ★★★★ 用途：清理不该存在的物品（如召唤物过期、mod 重置）。
-- ★★ onpredestroyitemcallbackfn —— 销毁前回调。
--   ★★★ ★★ 签名 `(self.inst, item)` —— 与 1837 行的 filterfn 同款。
--   ★★★ 这个回调让调用方能在销毁前「看一眼」每件物品，
--     如做统计或转移（比如把物品转移给主人）。
-- ★★★ ★★ ★★ 关键的**递归顺序**（1937-1938 行）：
--   `if item.components.container then container:DestroyContents(fn) end`
--   然后才 `item:Remove()`。
--   ⇒ ★★★ **先清空容器内容，再删容器本身**。
--   ★★ 顺序反了会导致容器被删后内容泄漏。
-- ★★★ ★★ 这就是「容器本体与内容分离处理」的统一模式
--   （与 1888-1904 行的 internal_containers 思路一致）。
-- ★★★ ★★ 1935 行的 `if item:IsValid()` ——
--   ★★★ 回调函数**可能删掉了物品**（回调里调 :Remove()），
--   所以必须重新检查有效性！
--   ⇒ ★★ 这是「回调可能破坏不变式」的标准防御。
-- ★★ ★★ 1944-1955 行：itemslots 循环，结构同上。
--   ★★★ 1953 行 `self:RemoveItem(item):Remove()` ——
--   ★★★ ★★ 又是链式调用，**依赖** 1453 行的兜底。
--   ★★ 与 1936 行的 `SetActiveItem(nil); item:Remove()` 不同：
--     这里是 RemoveItem（因为物品在 itemslots 里）；
--     那里是 SetActiveItem（因为它就是 activeitem）。
-- ★★★ ★★ 1957-1965 行：equipslots 循环（pairs —— 见 L3）。
--   ★★★ ★★ 1964 行 `self:RemoveItem(item):Remove()` ——
--     RemoveItem 会走 1426 行的 `Unequip(k, nil, true)`（force），
--     ⇒ ★★★ ★ 强制卸下「粘住」的装备。因为要销毁，没有理由尊重锁。
function Inventory:DestroyContents(onpredestroyitemcallbackfn)
-- ↑ DestroyContents 结束（★ 先清容器再删本体）。
    if self.activeitem then
-- ★ 手上有东西？
        local item = self.activeitem
-- ★ 取局部引用（★ 后面 activeitem 会被置 nil）。
        if onpredestroyitemcallbackfn then
-- ★ 有回调？
            onpredestroyitemcallbackfn(self.inst, item)
-- ★★ 回调（★ 可能删掉 item ⇒ 1935 行要复查）。
        end
-- ↑ 回调块结束。
        if item:IsValid() then
-- ★★★ IsValid 复查（回调可能已删掉物品）。
            self:SetActiveItem(nil)
-- ★★ SetActiveItem(nil) —— ★ 在回调之后（★ 若回调删了物品则这里白做）。
            if item.components.container then
-- ★ 是容器？
                item.components.container:DestroyContents(onpredestroyitemcallbackfn)
-- ★★★ 递归清空内容（★ 先清内容再删本体）。
            end
-- ↑ if 块结束。
            item:Remove()
-- ★★★ item:Remove() —— 彻底删除（★ 与 DropItem 的「丢地上」不同）。
        end
-- ↑ IsValid 块结束。
    end
-- ↑ activeitem 块结束。

    for k = 1, self.maxslots do
-- ★ 有序遍历普通槽。
        local item = self.itemslots[k]
-- ★ 取该格物品。
        if item then
-- ★ 非空才处理。
            if onpredestroyitemcallbackfn then
-- ★ 有回调？
                onpredestroyitemcallbackfn(self.inst, item)
-- ★ 回调。
            end
-- ↑ 回调块结束。
            if item.components.container then
-- ★ 是容器？
                item.components.container:DestroyContents(onpredestroyitemcallbackfn)
-- ★ 递归清空内容。
            end
-- ↑ if 块结束。
            self:RemoveItem(item):Remove()
-- ★★★ RemoveItem + :Remove() —— ★ 依赖 1453 行兜底的链式调用。
        end
-- ↑ if item 块结束。
    end
-- ↑ itemslots 循环结束。

    for _, item in pairs(self.equipslots) do
-- ★ 遍历装备槽（★ ★ ★ pairs + 循环内修改 —— 见 L3）。
        if onpredestroyitemcallbackfn then
-- ★ 有回调？
            onpredestroyitemcallbackfn(self.inst, item)
-- ★ 回调。
        end
-- ↑ 回调块结束。
        if item.components.container then
-- ★ 是容器？
            item.components.container:DestroyContents(onpredestroyitemcallbackfn)
-- ★ 递归清空内容。
        end
-- ↑ if 块结束。
        self:RemoveItem(item):Remove()
-- ★★★ RemoveItem（★ 内部走 1426 行的 force=true Unequip）+ :Remove()。
    end
-- ↑ equipslots 循环结束。
end
-- ↑ DestroyContents 结束。

-- ★★ BurnNonpotatableInContainer(container) —— 「把不能煮的东西烧成灰」。
-- ★★ 用途：烹饪锅放入 nonpotatable 标签的东西时，把它变 ash。
-- ★★★ 五步（1969-1977 行）：
--   ① 1969 行遍历容器的所有槽（用 container.numslots）；
--   ② 1970 行检查 "nonpotatable" 标签；
--   ③ 1971 行 RemoveItem(整摞) 取出；
--   ④ 1972-1973 行 SpawnPrefab("ash") 并**继承原名**；
--   ⑤ 1974-1975 行放回 ash，删掉原物品。
-- ★★★ ★★ 1973 行 `itemash.components.named:SetName(olditem.name)` ——
--   ★★★ ★★ 「灰烬继承原名」是个有趣的细节：
--   玩家看到「一堆灰」时，上面的文字是原物品名。
--   ⇒ ★★ 这是「保留信息」的设计（玩家知道烧掉的是什么）。
-- ★★★ ★★ 与 cooking.lua / cookpot 的关系：
--   烹饪系统发现不可烹饪的物品时调本函数。
--   ★★ 这是「容器组件作为入参」的例子——
--     参数类型是 container 组件，不是 inventory 组件。
function Inventory:BurnNonpotatableInContainer(container)
-- ↑ BurnNonpotatableInContainer 结束（灰烬继承原名）。
    for j = 1,container.numslots do
-- ★★ 遍历容器的所有槽（★ 直接读 container.numslots）。
        if container.slots[j] and container.slots[j]:HasTag("nonpotatable") then
-- ★★ 双重条件：槽有物 + nonpotatable 标签。
            local olditem = container:RemoveItem(container.slots[j], true)
-- ★ 取出原物品（整摞）。
            local itemash = SpawnPrefab("ash")
-- ★★ 生成灰烬 prefab。
            itemash.components.named:SetName( olditem.name )
-- ★★★ 灰烬继承原名（★ 保留信息：玩家知道烧掉了什么）。
            container:GiveItem(itemash,j)
-- ★ 灰烬放回同一槽。
            olditem:Remove()
-- ★★★ 删除原物品。
        end
-- ↑ if 块结束。
    end
-- ↑ 槽遍历结束。
end
-- ↑ BurnNonpotatableInContainer 结束。

-- ★★ ReferenceAllItems —— 「返回所有物品的引用列表」。
-- ★★★ 三段（1982-1997 行）：itemslots + equipslots + overflow 递归。
-- ★★★ ★★ 与 FindItems（638 行）的对比：
--   · FindItems 用 fn 筛选，**不含 activeitem**；
--   · ReferenceAllItems **不含 activeitem**（✓ 一致）；
--   · FindItems 按数组返回，ReferenceAllItems 按 table.insert 也返回数组。
-- ★★★ ★★ 两者的范围完全相同！都是：itemslots + equipslots + overflow。
--   ⇒ ★★★ ★ ReferenceAllItems 就是「无条件版的 FindItems(always true)」。
-- ★★★ ★ 用途：存档系统的引用收集（确保所有物品都被保存）。
--   ★★ 这是「遍历范围」的**权威定义**之一（与 OnSave:197-217 对照）。
-- ★★ ★★ 与 OnSave 的差异：OnSave 用 pairs，ReferenceAllItems 用有序 for。
--   ⇒ ★★ ★★ **同一个概念的两处遍历用了不同方式**（见 L33）。
--   影响：存档顺序可能与引用顺序不同，但都不依赖顺序。
function Inventory:ReferenceAllItems()
-- ↑ ReferenceAllItems 结束（★ 与 FindItems 范围相同）。
    local items = {}
-- ★ 结果数组。
    for i=1,self.maxslots do
-- ★ 有序遍历普通槽（★ ★ 与 OnSave 的 pairs 不同，见 L33）。
        if self.itemslots[i] ~= nil then
-- ★ 非空才收。
            table.insert(items, self.itemslots[i])
-- ★ 加入列表。
        end
-- ↑ if 块结束。
    end
-- ↑ itemslots 遍历结束。
    for k,v in pairs(self.equipslots) do
-- ★ 遍历装备槽。
        if v ~= nil then
-- ★ 非空才收。
            table.insert(items, v)
-- ★ 加入列表。
        end
-- ↑ if 块结束。
    end
-- ↑ equipslots 遍历结束。
    local container = self:GetOverflowContainer()
-- ★ 取 overflow。
    if container ~= nil then
-- ★ 有则递归。
        for i,item in ipairs(container:ReferenceAllItems()) do
-- ★ 遍历容器的引用列表。
            table.insert(items, item)
-- ★ 加入列表。
        end
-- ↑ 遍历结束。
    end
-- ↑ if 块结束。
    return items
-- ★★ return items（★ ★ 不含 activeitem —— 与 FindItems 一致）。
end
-- ↑ ReferenceAllItems 结束。

-- 【§十五】★ GetDebugString —— 「调试用的可读描述」。
-- ★★ 2006 行 `item.prefab or "prefab"` —— prefab 兜底。
-- ★★ ★★ ⚠ 见 L12：2012 行的 string.format 有 bug——
--   `string.format("... waterproofness:", self:GetWaterproofness())`
--   格式串里**没有 %d 或 %s**，所以 waterproofness 的值被**完全丢弃**。
--   ⇒ ★★★ 这是一个确定的缺陷：调试信息里永远看不到防水值。
-- ★★ 2007-2009 行：堆叠物品显示 " xN"。
-- ★★ ★ 输出格式：`count: prefab1, prefab2 x5`。
function Inventory:GetDebugString()
-- ↑ GetDebugString 结束（★ L12：format 缺占位符）。
    local s = ""
-- ★ 字符串累加器。
    local count = 0
-- ★ 计数器。
    for k, item in pairs(self.itemslots) do
-- ★ 遍历普通槽（★ pairs，无序）。
        count = count + 1
-- ★ 自增。
        s = s..(count > 1 and ", " or ": ")..(item.prefab or "prefab")
-- ★★ 拼 prefab 名（★ 第一个用 ": "，其余用 ", "）。
        if item.components.stackable ~= nil and item.components.stackable:IsStack() then
-- ★ 是堆叠？
            s = s.." x"..tostring(item.components.stackable:StackSize())
-- ★ 追加 " xN"。
        end
-- ↑ if 块结束。
    end
-- ↑ 遍历结束。

    return count..": "..s..string.format(" waterproofness:", self:GetWaterproofness())
-- ★★★★ ⚠ L12：格式串**没有 %d** ⇒ waterproofness 的值被丢弃！
end
-- ↑ GetDebugString 结束。

-- 【§十五】★★ IsOpenedBy(guy) —— 「这个物品栏是不是正被 guy 打开着」。
-- ★★★ `return self.isopen and self.isvisible and guy == self.inst` ——
-- ★★★★ 三重与条件，★ 每一项都有讲究：
--   ① isopen —— 逻辑上开着；
--   ② isvisible —— UI 上可见；
--   ③ guy == self.inst —— 「我打开的」（排除别人打开我的）。
-- ★★★ ★★ ①②③ **都必要**，缺一不可：
--   · 只有 isopen：尸体那种「开着但不可见」的会被误判（见 2042 行 Open 的做法）；
--   · 只有 isvisible：某些 UI 可见但逻辑已关的边界情况会误判；
--   · 没有 ③：任何人的物品栏都会认为「被打开了」。
-- ★★★ ★★ ③ 的必要性最直观：这份检查被大量用于
--   「这个容器是不是我打开的」（1472 行 ValidateSpecializedContainer）。
--     若不检查 owner，任何人都会被当成「已打开它」。
function Inventory:IsOpenedBy(guy)
-- ↑ IsOpenedBy 结束（三重与条件）。
    return self.isopen and self.isvisible and guy == self.inst
-- ★★★ 三重与：isopen + isvisible + owner == 自己。
end
-- ↑ IsOpenedBy 结束。

-- 【§十五】★ Show —— 「让 UI 可见（但逻辑上仍开着）」。
-- ★★★★ 与 Open 的区别（★★ 关键设计）：
--   · Open（2037 行）：逻辑开启 + UI 可见 + 打开 overflow；
--   · Show（这里）：**只让 UI 可见**，不改变 isopen。
-- ★★★★ 2020 行 `if not self.isopen then return end` ——
--   ★★★ ★★ 关键守卫：**没打开就不能显示**。
--   ⇒ ★★ Show 只能「让已打开的栏变得可见」，不能凭空打开。
--   ★★ 这保证了「逻辑状态」是「表现状态」的前提。
-- ★★★ ★★ 2024 行在 2026 行的 isvisible 检查**之前**：
--   `replica:OnShow()` 先派发（即使已经可见也派发）。
--   ★★ ⇒ ★★ OnShow 是**幂等**的（重复调用无害）。
--   对比 Open（2038 行）：OnOpen 也在 2040 行守卫之前。
--   ⇒ ★★ 两个函数都是「先派发网络事件，再判本地状态」。
--   ★★★ 理由：replica 的 OnShow/OnOpen 会操作 classified 的 netvar
--     （inventory_replica.lua:163/145），需要无条件同步。
-- ★★★ ★★★ Show 的实际用途（2060 行 Hide 的对称）：
--   Hide 把 UI 藏起来但**保持 isopen**，这样 overflow 容器继续收集物品；
--   Show 再把 UI 显示出来。
--   ⇒ ★★★ 「看不见但仍开着」是完全合法的中间状态（见 2060 行）。
-- ★★ 2054-2056 行的 rebuild_snapping：
--   ★★★ 「重建时吸附」标记——UI 重建物品栏时保持滚动位置。
--   ★★★ 这解决了「打开背包时 UI 重建导致滚动跳回顶部」的问题。
--   ★★ 与 inventory_replica.lua:124-126 的同名标记呼应。
function Inventory:Show()
-- ↑ Show 结束（★ 只改 isvisible，不改 isopen）。
    if not self.isopen then
-- ★★ 没打开就不能显示（★ 逻辑状态是表现状态的前提）。
        return
-- ★ 早退。
    end
-- ↑ 守卫块结束。

    self.inst.replica.inventory:OnShow()
-- ★★★ OnShow 在守卫之后、isvisible 检查**之前**（★ 幂等同步）。

    if self.isvisible then
-- ★ 已可见就停（★ 但 OnShow 已发过）。
        return
-- ★ 早退。
    end
-- ↑ if 块结束。

    if self.inst.HUD ~= nil then
-- ★ 有 HUD 才操作（★ 非玩家实体没有 HUD）。
        self.inst.HUD.controls:ShowCraftingAndInventory()
-- ★ 显示合成与物品栏 UI。
    end
-- ↑ if 块结束。

    self.isvisible = true
-- ★★★ isvisible = true（★ ★ 不动 isopen）。
end
-- ↑ Show 结束。

-- 【§十五】★★ Open —— 「打开物品栏」。
-- ★★★★ 四步（2038-2057 行）：
--   ① 2038 行 replica:OnOpen()（网络同步，见下）；
--   ② 2040-2042 行 幂等守卫（已开则返回）；
--   ③ 2044-2046 行 显示 HUD；
--   ④ 2048-2049 行 置 isopen + isvisible；
--   ⑤ 2051-2057 行 打开 overflow 容器。
-- ★★★ ★★ 2038 行的 OnOpen —— ★★★ 联机同步的核心：
--   inventory_replica.lua:145 OnOpen 做两件事：
--     ① `self.classified.Network:SetClassifiedTarget(self.inst)`
--        ★★★ 把 classified 的**网络访问权限授予该玩家**！
--     ② `self.classified.visible:set(true)` —— 同步可见状态。
--   ⇒ ★★★★ ★★ 这就是任务提到的「联机同步」的**权限层**：
--     背包数据通过 classified 的 Network 授权机制控制可见性，
--     而不是「所有客户端都能读，客户端自己决定显示」。
--   ★★★ 对比 DetachClassified（inventory_replica.lua:130）：
--     断线/销毁时清空并推 inventoryclosed 事件。
-- ★★★ ★★ 2051-2053 行：`overflow:Open(self.inst)` ——
--   ★★★ 打开背包（overflow）本身，让它的格子并入物品栏显示。
--   ★★ ★★ 这是「穿上背包后格子数增加」的实现。
-- ★★ 2054-2056 行：UI 重建时的吸附标记（同 2055 行）。
function Inventory:Open()
-- ↑ Open 结束（★ OnOpen 授予 classified 访问权限）。
    self.inst.replica.inventory:OnOpen()
-- ★★★★ OnOpen —— ★★★ 授予 classified 网络访问权限。

    if self.isopen then
-- ★ 已打开就停（★ 但 OnOpen 已执行过 ⇒ 幂等撤/授权）。
        return
-- ★ 早退。
    end
-- ↑ if 块结束。

    if self.inst.HUD ~= nil then
-- ★ 有 HUD？
        self.inst.HUD.controls:ShowCraftingAndInventory()
-- ★ 显示 UI。
    end
-- ↑ if 块结束。

    self.isopen = true
-- ★★★ isopen = true（★ 逻辑状态开启）。
    self.isvisible = true
-- ★★★ isvisible = true（★ 表现状态同时开启）。

    local overflow = self:GetOverflowContainer()
-- ★★★ 打开 overflow（穿上背包后格子增加）。
    if overflow ~= nil then
-- ★ 有 overflow（穿着背包）？
        overflow:Open(self.inst)
-- ★★★ overflow:Open(self.inst) —— ★ 背包容器也「打开」。
        if self.inst.HUD ~= nil and self.inst.HUD.controls.inv.rebuild_pending then
-- ★★ UI 需要重建且正在重建中？
            self.inst.HUD.controls.inv.rebuild_snapping = true
-- ★★★ rebuild_snapping = true —— ★ 重建时保持滚动位置。
        end
-- ↑ if 块结束。
    end
-- ↑ if overflow 块结束。
end
-- ↑ Open 结束。

-- 【§十五】★★★ Hide —— 「隐藏 UI 但保持逻辑打开」。★★ 精妙设计。
-- ★★★★ 五步（2061-2088 行）：
--   ① 2061-2063 行 幂等守卫（未开则返回）；
--   ② 2065 行 replica:OnHide()（同步 visible=false）；
--   ③ 2067-2069 行 幂等守卫（本就不可见则返回）；
--   ④ 2071 行 **ReturnActiveItem()**（把手上物品放回背包）；
--   ⑤ 2077-2081 行 关闭除背包外的所有容器；
--   ⑥ 2087 行 **只置 isvisible = false**（不动 isopen）。
-- ★★★★★ ★★ 2087 行的「只置 isvisible」是本函数的核心：
--   ⇒ ★★★ 逻辑上物品栏**仍然开着**（overflow 继续收集物品）；
--     只是 UI 不显示了。
--   ★★★ ★★ 这个中间态的用途（★★ 推断）：
--     · 背包收起（默认不显示）但仍能收东西；
--     · 死亡时尸体「开着但不可见」（inventory_replica.lua:4-6 的用法）；
--     · 某些 UI 流程临时隐藏而不完全关闭。
--   ★★ ⇒ ★★ 若 Hide 置 isopen=false（像 Close 那样），
--     overflow 就停止收集，行为会不同。
-- ★★★ ★★ 2067-2069 行的**双守卫**结构：
--   第一个守卫（2061）防「没开就藏」，第二个（2067）防「重复藏」。
--   ★★ 但注意 2065 行的 OnHide 在**第二守卫之前**——
--     与 Open 的 OnOpen 一样是「先同步再判本地」。
-- ★★ ★★ 2071 行 ReturnActiveItem ——
--   ★★★ 隐藏物品栏时把手上的东西收起来（防止「看不见的手」）。
--   ★★★ 这是必要的：UI 隐藏了，玩家看不到手上是什么。
-- ★★ ★★ 2073-2081 行：关闭打开的容器，但**排除背包**。
--   原注释保留："Don't close backpack, its widget will be hidden instead"
--   ★★★ ★★ 「背包的 UI 会被一起隐藏，不需要单独 Close」。
--   2075 行 `overflow = overflow ~= nil and overflow.inst or nil` ——
--   ★★★ 从 container 组件反查**实体**（因为 opencontainers 的 key 是实体）。
-- ★★★ ⚠ 2078 行 `k.components.container.stay_open_on_hide` ——
--   ★★★ ★★ **没有 nil 保护**（见 L2）：
--     1443/1540/1673/1703 四处都写了 `or ...components.inventory` 兜底，
--     唯独这里假定所有 opencontainers 成员都有 container 组件。
--   ⇒ ★★★ 真实隐患：若某成员只有 inventory 组件 → 崩。
--   ★★ stay_open_on_hide 标签的语义：
--   「隐藏物品栏时不关闭我」（某些容器希望保持打开状态）。
function Inventory:Hide()
-- ↑ Hide 函数头（★ 只隐藏 UI，保持逻辑打开）。
    if not self.isopen then
-- ★★ 第一个守卫：没打开就没什么可藏。
        return
-- ★ 早退。
    end
-- ↑ 守卫块结束。

    self.inst.replica.inventory:OnHide()
-- ★★★ OnHide（★ 同步 visible=false）。

    if not self.isvisible then
-- ★★ 第二个守卫：本来就不可见。
        return
-- ★ 早退。
    end
-- ↑ 守卫块结束。

    self:ReturnActiveItem()
-- ★★★ ReturnActiveItem（UI 隐藏了要收手）。

-- ↑ 空行。
    --Don't close backpack, its widget will be hidden instead
-- ↑ 原英文注释保留（Don't close backpack）。
    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow 组件。
    overflow = overflow ~= nil and overflow.inst or nil
-- ★★★ 反查**实体**（★ opencontainers 的 key 是实体）。

-- ↑ 空行。
    for k, v in pairs(self.opencontainers) do
-- ★★ 关闭容器（★ 2078 行无 nil 保护 —— 见 L2）。
        if k ~= overflow and not k.components.container.stay_open_on_hide then
-- ★★★★ ⚠ L2：`k.components.container.stay_open_on_hide` **无 nil 保护**。
			k.components.container:Close(self.inst)
-- ★ 关闭该容器。
        end
-- ↑ if 块结束。
    end
-- ↑ 容器遍历结束。

    if self.inst.HUD ~= nil then
-- ★ 有 HUD？
        self.inst.HUD.controls:HideCraftingAndInventory()
-- ★ 隐藏 UI。
    end
-- ↑ if 块结束。

    self.isvisible = false
-- ★★★★★ 只置 isvisible = false（核心设计）。
-- ★★★ 只置 isvisible = false（★ ★★ isopen 保持不变 —— 核心设计）。
end
-- ↑ Hide 结束。

-- 【§十五】★★ Close —— 「完全关闭物品栏」。
-- ★★★★ 与 Hide 的区别（★ 三点，务必分清）：
--   ① Close 置 **isopen = false**（Hide 不动）；
--   ② Close 关闭**所有**容器（含背包，2102-2104 行）；
--   ③ Close **不检查** stay_open_on_hide（对比 2078 行）。
-- ★★★ ★★ ② 是关键的语义差异：
--   Hide 保留 overflow（因为逻辑还开着）；
--   Close 关掉 overflow（因为逻辑已关闭）。
--   ⇒ ★★★ 「背包的容器是否继续收集物品」由 isopen 决定（2051 行）。
-- ★★★ ★★ 2097-2099 行：keepactiveitem 参数控制是否收手。
--   Close(keepactiveitem) 为真 → **不**调 ReturnActiveItem。
--   ★★★ ★★ 2106-2108 行：关闭所有打开的容器，**无条件**。
--   ★★ 与 Hide 的 2077-2081 行对比：那里有 `not stay_open_on_hide` 排除。
--   ⇒ ★★ 语义差异**没有任何注释说明**（见 L9）。
-- ★★ ★★ 2091 行 OnClose 在 2093 行守卫**之前** ——
--   inventory_replica.lua:152 OnClose 做两件事：
--     ① `SetClassifiedTarget(self.classified)` —— ★★★ **撤销访问权限**；
--     ② `visible:set(false)`。
--   ⇒ ★★★ ★★★ ① 是整个联机机制的**收尾**：
--     关闭背包 = 撤销客户端对 classified 的读取权限。
--   ★★★ 这解释了 OnOpen 的 SetClassifiedTarget(self.inst) 为何必要：
--     它是权限的授予，OnClose 的 SetClassifiedTarget(self.classified) 是撤销。
--   ★★ 2093-2095 行的守卫在 OnClose 之后，所以即使已关闭也会撤权。
--   ★★ ★ 幂等（重复 Close 无害）。
function Inventory:Close(keepactiveitem)
-- ↑ Close 函数头（★ 置 isopen = false + 关所有容器）。
    self.inst.replica.inventory:OnClose()
-- ★★★★ OnClose —— ★★★ **撤销** classified 访问权限。

    if not self.isopen then
-- ★ 已关闭就停（★ 但权限已撤销 ⇒ 幂等）。
        return
-- ★ 早退。
    end
-- ↑ 守卫块结束。

    if not keepactiveitem then
-- ★ keepactiveitem 为假才收手。
        self:ReturnActiveItem()
-- ★ ReturnActiveItem。
    end
-- ↑ if 块结束。

    local overflow = self:GetOverflowContainer()
-- ★ 取 overflow。
    if overflow ~= nil then
-- ★ 有则关闭（★ ★ 与 Hide 不同：这里关背包）。
		overflow:Close(self.inst)
-- ★ overflow:Close(self.inst)。
    end
-- ↑ if 块结束。

    for k, v in pairs(self.opencontainers) do
-- ★★ 无条件关闭所有容器（对比 Hide 的排除逻辑）。
		k.components.container:Close(self.inst)
-- ★★ 无条件关闭所有容器（★ ★ 无 stay_open_on_hide 判定 —— 见 L9）。
    end
-- ↑ 容器遍历结束。

    if self.inst.HUD ~= nil then
-- ★ 有 HUD？
        self.inst.HUD.controls:HideCraftingAndInventory()
-- ★ 隐藏 UI。
    end
-- ↑ if 块结束。

    self.isopen = false
-- ★★★ isopen = false（★ 与 Hide 的唯一本质区别）。
    self.isvisible = false
-- ★★★ isvisible = false。
end
-- ↑ Close 结束。

-- ★★ CloseAllChestContainers —— 「关闭所有箱子」。
-- ★★★ 用途：玩家切换角色形态、或触发剧情时关闭所有 UI。
-- ★★ ★★ 2120 行 `k.components.container.type == "chest"` ——
--   ★★★ ★★ 这里**只处理 type == "chest" 的容器**。
--   ⇒ ★★ 背包（overflow）的 type 不是 chest，不会被关。
--   ★★★ 这与 Close（2106 行关闭全部）不同。
-- ★★★ ⚠ ★★ 2120 行**没有** or 兜底（同 2078 行的 L2 问题）：
--   `k.components.container.type` —— 若 k 没有 container 组件则崩。
--   ★★ 推理：能进 opencontainers 且需要「关闭」的都应该有 container 组件。
--     参照 1540 行的 or 兜底，这里是不一致的隐含假设。
function Inventory:CloseAllChestContainers()
-- ↑ CloseAllChestContainers 结束（★ 2120 行同样无 or 兜底）。
	for k in pairs(self.opencontainers) do
-- ★ 遍历打开的容器。
		if k.components.container.type == "chest" then
-- ★★★★ ⚠ L2：`k.components.container.type` 同样**无 or 兜底**。
			k.components.container:Close(self.inst)
-- ★ 只关 type == "chest" 的（★ 背包不是 chest）。
		end
-- ↑ if 块结束。
	end
-- ↑ 容器遍历结束。
end
-- ↑ CloseAllChestContainers 结束。

-- 【§十六】★★ InvSlot 点击动作处理器家族。
-- ★★★★ ★★ 这段的分隔注释（2126-2128 行）用了三个横杠，
--   是 Klei 源码里的「章节标记」风格（本文件只此一处）。
-- ★★★★★ 2130-2257 行共 **11 个处理器**，全部是
--   「玩家在物品栏 UI 上点击/拖拽」的服务端入口。
-- ★★★★ 它们可以分为三类：
--   ① 放入手上物品到某槽：PutOneOf/ PutAllOf（2130/2144）；
--   ② 从某槽取到手上：TakeActiveItemFromHalf/Count/All（2160/2174/2195）；
--   ③ 合并与交换：CombineActiveStackWithSlot（528，在别处）、
--     AddOneOf/ AddAllOf/ Swap（2208/2225/2240）。
-- ★★★★ ★★ 这 11 个函数的共同模式：
--   · 全部**不检查 isopen/isvisible**（因为只有 UI 可见时才会被调）；
--   · 全部以 self:GetItemInSlot(slot) 拿物品；
--   · 大量使用 ignoresound / silentfull 包裹（L9 的标志泄漏隐患）。
-- ★★★★ ★★ stack_mod 参数：区分「整摞」与「一个」，
--   对应 UI 上的「点击」与「shift+点击」。
--------------------------------------------------------------------------
--InvSlot click action handlers
-- ↑ 原注释保留（InvSlot click action handlers）。
--------------------------------------------------------------------------
-- ↑ 分隔线（本文件唯一用三横杠的地方）。

-- ★★ PutOneOfActiveItemInSlot —— 「把手上的 1 个放进某槽」。
-- ★★★ 五重条件（2132-2136 行）：
--   · activeitem 非 nil；
--   · 目标槽**为空**（`GetItemInSlot(slot) == nil`）；
--   · CanTakeItemInSlot（231 行）；
--   · activeitem 可堆叠；
--   · StackSize() > 1（★ 至少 2 个才能「分一个出去」）。
-- ★★★ ★ 2139 行 `GiveItem(stackable:Get(1), slot)` ——
--   Get(1) 取出 1 个（新实体），然后放进指定槽。
-- ★★★ ★★ ignoresound 包裹（2138/2140 行）：
--   这是「玩家主动操作」，不该播「拾取音」。
--   ⇒ ★★ 若 2139 行抛错，ignoresound 泄漏（L9）。
function Inventory:PutOneOfActiveItemInSlot(slot)
-- ↑ PutOneOfActiveItemInSlot 结束。
    local active_item = self:GetActiveItem()
-- ★ 取手上的东西。
    if active_item ~= nil and
-- ★ 非空。
        self:GetItemInSlot(slot) == nil and
-- ★★ 目标槽必须是空的（★ 满了就该 Add 而不是 Put）。
        self:CanTakeItemInSlot(active_item, slot) and
-- ★ 槽位允许放入。
        active_item.components.stackable ~= nil and
-- ★ 可堆叠？
        active_item.components.stackable:StackSize() > 1 then
-- ★★ 至少有 2 个（★ 只有一个时无「分一个」可言）。

-- ↑ 五重条件块结束。
        self.ignoresound = true
-- ★ 静音包裹开始。
        self:GiveItem(active_item.components.stackable:Get(1), slot)
-- ★★ Get(1) 取出 1 个并放进指定槽。
        self.ignoresound = false
-- ★ 静音包裹结束（★ 中途抛错则泄漏，见 L8）。
    end
-- ↑ 条件块结束。
end
-- ↑ PutOneOfActiveItemInSlot 结束。

-- ★★ PutAllOfActiveItemInSlot —— 「把手上的全部放进某槽」。
-- ★★★★ 与 2130 行的差异：
--   · 条件是 `AcceptsStacks() or 非堆叠 or 只有1个`（2149-2151）；
--   · 2153 行先 RemoveItem(整摞) 再 GiveItem —— ★★ **先取出再放入**。
-- ★★★ ★★ 2153-2155 行的顺序（★ 关键）：
--   `self:RemoveItem(active_item, true)` 先把手上东西取下来，
--   然后 `self:GiveItem(active_item, slot)` 再放进去。
--   ⇒ ★★★ ★★ 为什么？**避免自我冲突**：
--     若不先取出，GiveItem 会看到「这物品已在手上」，
--     可能走 1041 行的 new_item 判定出错，或在选位时找到自己。
--   ★★ 实际上 GiveItem(同一实体) 通常能正确处理（1055 行 OnPickup），
--     但先取出更安全。
-- ★★★ ★★ 2153 行的 RemoveItem 依赖 1453 行的兜底（返回原实体）。
-- ★★ ignoresound 包裹（2154/2156）。
function Inventory:PutAllOfActiveItemInSlot(slot)
-- ↑ PutAllOfActiveItemInSlot 结束（★ 先取出再放入）。
    local active_item = self:GetActiveItem()
-- ★ 取手上的东西。
    if active_item ~= nil and
-- ★ 非空。
        self:GetItemInSlot(slot) == nil and
-- ★★ 目标槽必须为空。
        self:CanTakeItemInSlot(active_item, slot) and
-- ★ 槽位允许。
        (self:AcceptsStacks() or
-- ★★ 条件①：本栏接受整摞。
        active_item.components.stackable == nil or
-- ★ 条件②：不是堆叠（单件）。
        active_item.components.stackable:StackSize() == 1) then
-- ★ 条件③：只有 1 个。

-- ↑ 条件块结束。
        self:RemoveItem(active_item, true)
-- ★★★ 先 RemoveItem（★ 避免自我冲突，见 BEFORE 详解）。
        self.ignoresound = true
-- ★ 静音包裹开始。
        self:GiveItem(active_item, slot)
-- ★ GiveItem 到指定槽。
        self.ignoresound = false
-- ★ 静音包裹结束。
    end
-- ↑ 条件块结束。
end
-- ↑ PutAllOfActiveItemInSlot 结束。

-- ★★ TakeActiveItemFromHalfOfSlot —— 「把槽里的一半拿到手上」。
-- ★★★★ 三重条件（2162-2165 行）：槽有物 + 手上为空 + 可堆叠且 >1。
-- ★★★ ★★ 2167 行 `Get(math.floor(StackSize() / 2))` —— 对半分。
-- ★★★ ★★ ★★ 注意 `math.floor`：**奇数时「拿走少的一半」**。
--   栈 = 5 → floor(2.5) = 2 → 手上 2 个，槽里剩 3 个。
--   ⇒ ★★★ 这与 UI 预期（可能期望 3/2）可能相反。
--   ★★ 对比 2160 行的语义：玩家预期「一半」= 一半，
--     奇数时给少的一半是常见的实现选择（保证手上的一定能放下）。
--   ★★ 这是一个**值得注意的边界行为**（奇数堆叠的分法）。
-- ★★★ 2168-2169 行：位置记忆设为该槽（★ 记住从哪拿的）。
-- ★★★ 与 MoveItemFromHalfOfSlot（2564 行）的区别：
--   那里设的是 `prevcontainer = nil`（因为进的是容器）。
-- ★★★ ⇒ ★★ 两处都写 prevslot = slot，区别只在 prevcontainer。
--   ★ 这是「位置记忆」在各种操作中的一致应用。
function Inventory:TakeActiveItemFromHalfOfSlot(slot)
-- ★★ TakeActiveItemFromHalfOfSlot 结束（★ 奇数时拿走少的一半）。
    local item = self:GetItemInSlot(slot)
-- ★ 取槽内物品。
    if item ~= nil and
-- ★ 非空。
        self:GetActiveItem() == nil and
-- ★★ 手上必须是空的。
        item.components.stackable ~= nil and
-- ★ 可堆叠。
        item.components.stackable:StackSize() > 1 then
-- ★★ 至少有 2 个（★ 对半分才有意义）。

-- ↑ 四重条件块结束。
        local halfstack = item.components.stackable:Get(math.floor(item.components.stackable:StackSize() / 2))
-- ★★★ ★★ math.floor(N/2) —— ★ 奇数时**拿走少的一半**。
        halfstack.prevslot = slot
-- ★★ 记位置记忆（★ 记住从哪拿的）。
        halfstack.prevcontainer = nil
-- ★★ 清容器记忆。
        self:GiveActiveItem(halfstack)
-- ★ GiveActiveItem。
    end
-- ↑ 条件块结束。
end
-- ↑ TakeActiveItemFromHalfOfSlot 结束。

-- ★★ TakeActiveItemFromCountOfSlot(slot, count) —— 「从槽里拿 N 个到手上」。
-- ★★★ 条件比 2160 宽松：只要求槽有物 + 手上为空（2176-2177）。
--   ★★★ 不要求「可堆叠且 >1」——因为单件物品也能拿。
-- ★★★★ 2179 行的 `fullstacksize` 计算（★ 值得注意）：
--   `stackable and (IsOverStacked() and originalmaxsize or StackSize()) or 1`
--   ★★★ ★★ 三个分支：
--   · 没有 stackable → 1（单件物品）；
--   · IsOverStacked（过度堆叠，>maxsize）→ 用 originalmaxsize；
--     ★★ 为什么用 originalmaxsize？因为玩家看到的是 N 个，
--       上限判断应该用「标准上限」而非「当前过度堆叠数」。
--       例：一摞石头因为 buff 变成 150（max 99），
--       玩家拖 99 个应该合法（拖 150 个不合理）。
--   · 普通情况 → StackSize()。
-- ★★ ★★ 这是「过度堆叠（overstacked）」机制的一个交互细节。
-- ★★★★ 2180 行 `math.clamp(count, 1, fullstacksize)` —— 钳制。
--   ★★★ ★ 保证 count 在 [1, 实际数量] 之间。
--   ★★ 防的是「UI 传来一个越界的 count」（如拖动条超界）。
-- ★★★ ★★ 2186 行 `elseif islockedinslot then assert` ——
--   2181 行的 `if stackable and StackSize() > count` 不成立时，
--   走 2188 行的 else（整个拿走）。但**锁定物品不能整个拿走**！
--   ⇒ ★★★ 所以要先检查锁定（2186 行），阻止这个路径。
--   ★★★ ★ 这是 L6 那类 assert 的**正确用法**：
--     不是「不该走到」，而是「阻止不该发生的事」。
-- ★★ 2189-2190 行：RemoveItemBySlot + GiveActiveItem（整摞拿走）。
function Inventory:TakeActiveItemFromCountOfSlot(slot, count)
-- ↑ TakeActiveItemFromCountOfSlot 结束（★ overstacked 的上限处理）。
    local item = self:GetItemInSlot(slot)
-- ★ 取槽内物品。
    if item ~= nil and
-- ★ 非空。
        self:GetActiveItem() == nil then
-- ★★ 手上必须为空。
        local stackable = item.components.stackable
-- ★ 取 stackable 组件（可能 nil）。
        local fullstacksize = stackable and (stackable:IsOverStacked() and stackable.originalmaxsize or stackable:StackSize()) or 1
-- ★★★★ fullstacksize（★ 过度堆叠用 originalmaxsize —— 见详解）。
        count = math.clamp(count, 1, fullstacksize)
-- ★★★ math.clamp 钳制（★ 防 UI 传来越界值）。
        if stackable and stackable:StackSize() > count then
-- ★★ 摞里比要的多？
            local countedstack = stackable:Get(count)
-- ★ Get(count) 取出 count 个。
            countedstack.prevslot = slot
-- ★ 记槽记忆。
            countedstack.prevcontainer = nil
-- ★ 清容器记忆。
            self:GiveActiveItem(countedstack)
-- ★ GiveActiveItem。
		elseif item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- ★★ ★ 锁定物品 → 拒绝（★ ★ 但这条在 count < stacksize 时被绕过，见 L38）。
			assert(BRANCH ~= "dev")
-- ★ assert（dev 版崩）。
        else
-- ★ else 分支：整个拿走。
            self:RemoveItemBySlot(slot)
-- ★ RemoveItemBySlot。
            self:GiveActiveItem(item)
-- ★ GiveActiveItem。
        end
-- ↑ if/elseif/else 块结束。
    end
-- ↑ 条件块结束。
end
-- ↑ TakeActiveItemFromCountOfSlot 结束。

-- ★★ TakeActiveItemFromAllOfSlot —— 「把槽里的全部拿到手上」。
-- ★★ 条件最宽松：槽有物 + 手上为空（2197-2198）。
-- ★★★ ★★ 2199-2202 行：**先检查锁定**（与 2174 行的顺序相反）。
--   ★★ 2174 行：先算 count 分支，最后才查锁定（2186 行）；
--   ★★ 2195 行：一进来就查锁定（2199 行）。
--   ⇒ ★★★ ★★ **同一逻辑两种顺序**，结果一致但风格不同。
-- ★★★ 2186 vs 2199 的另一个差异：
--   · 2186 行 `elseif item.components.inventoryitem and ... islockedinslot`；
--   · 2199 行 `if item.components.inventoryitem and ... islockedinslot`。
--   ★★ 条件写法完全一样，只是 if/elseif 位置不同。
--   ★★★ 推断：2195 行是后来加的（补了 2174 行的漏洞）。
-- ★★★ ★★ 两处 assert 都在 `BRANCH ~= "dev"` 下 —— 见 L6。
function Inventory:TakeActiveItemFromAllOfSlot(slot)
-- ↑ TakeActiveItemFromAllOfSlot 结束（★ 锁定检查顺序与 2174 不同）。
    local item = self:GetItemInSlot(slot)
-- ★ 取槽内物品。
    if item ~= nil and
-- ★ 非空。
        self:GetActiveItem() == nil then
-- ★★ 手上为空。
		if item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- ★★ ★ 先检查锁定（★ ★ 与 2174 行的顺序不同）。
			assert(BRANCH ~= "dev")
-- ★ assert。
			return
-- ★ 静默返回。
		end
-- ↑ if 块结束。
        self:RemoveItemBySlot(slot)
-- ★ RemoveItemBySlot。
        self:GiveActiveItem(item)
-- ★ GiveActiveItem。
    end
-- ↑ 条件块结束。
end
-- ↑ TakeActiveItemFromAllOfSlot 结束。

-- ★★ AddOneOfActiveItemToSlot —— 「把手上 1 个加到槽里已有的摞」。
-- ★★★★ 条件**八重**（2211-2219 行）：槽有物 + 手上非 nil +
--   CanTakeItemInSlot + 槽可堆叠 + CanStackWith + AcceptsStacks +
--   手上可堆叠 + 手上 >1 个 + **槽没满**。
-- ★★★ ★★ 2219 行的 `not item.components.stackable:IsFull()` ——
--   ★★★ ★★ **这是 AddOne 与 CombineActiveStackWithSlot 的差异**：
--   528 行的 Combine 没有检查 IsFull（它用 Put 自行处理）；
--   2208 行的 AddOne **显式要求槽没满**。
--   ⇒ ★★ 若槽满了，AddOne 直接什么都不做（静默失败）。
-- ★★ ★ 2221 行 `item.components.stackable:Put(active_item.components.stackable:Get(1))` ——
--   ★★★ ★★ 「取 1 个 → Put 进槽」一步完成，**不经过 GiveItem**。
--   ⇒ ★★★ ★★ 因为这里**不是新物品进背包**，而是合并，
--     所以不走 GiveItem 的完整流程（也不发 itemget 事件）。
--   ★★★ ★ 客户端如何知道数量变了？——
--     inventory_classified.lua:512 OnStackItemDirty ——
--     ★★★ ★★ **堆叠数量变化由独立的 dirty 监听处理**，
--     不需要 slot 层面的事件。
--   ⇒ ★★ 这解释了 1098-1152 行「合并时不发 itemget」的合理性。
-- ★★★ ★★ 四个条件用了 `and` 串联但**没有括号分组**：
--   `... not item.components.stackable:IsFull() then`（2219 行）
--   ★★ 由于全部是 and 运算，优先级相同，括号省略是安全的。
--   ★★ 但可读性差（对比 528 行的 Combine 有括号）。
function Inventory:AddOneOfActiveItemToSlot(slot)
-- ↑ AddOneOfActiveItemToSlot 结束（★ 不走 GiveItem，不发 itemget）。
    local active_item = self:GetActiveItem()
-- ★ 取手上的东西。
    local item = self:GetItemInSlot(slot)
-- ★ 取槽内物品（★ 与 AddAll 都需要它）。
    if active_item ~= nil and
-- ★★ 手上非空。
        item ~= nil and
-- ★ 槽内非空。
        self:CanTakeItemInSlot(active_item, slot) and
-- ★ 槽位允许。
        item.components.stackable ~= nil and
-- ★ 槽内可堆叠。
        item.components.stackable:CanStackWith(active_item) and
-- ★ 同类。
        self:AcceptsStacks() and
-- ★ 本栏接受整摞。
        active_item.components.stackable ~= nil and
-- ★ 手上可堆叠。
        active_item.components.stackable:StackSize() > 1 and
-- ★★ 手上至少有 2 个。
        not item.components.stackable:IsFull() then
-- ★★★ ★ 槽**没满**（★ 与 CombineActiveStackWithSlot 的差异）。

-- ↑ 八重条件块结束。
        item.components.stackable:Put(active_item.components.stackable:Get(1))
-- ★★★★ 「取 1 个 → Put 进槽」一步完成（★ ★ 不走 GiveItem，不发 itemget）。
    end
-- ↑ 条件块结束。
end
-- ↑ AddOneOfActiveItemToSlot 结束。

-- ★★ AddAllOfActiveItemToSlot —— 「把手上全部加到槽里」。
-- ★★★★ 条件比 2221 行少（2219 行的 IsFull 检查没有）：
--   2211-2233 行只检查「可堆叠 + CanStackWith + AcceptsStacks」。
-- ★★★ ★★ 2235-2236 行：
--   `local leftovers = item.components.stackable:Put(active_item)`
--   `self:SetActiveItem(leftovers)`
--   ★★★ ★★ 与 528 行 CombineActiveStackWithSlot 的 else 分支（543-544 行）
--   **完全同构**！两处代码重复。
--   ⇒ ★★★ 这是同一个逻辑在两个地方各写一遍（见 L34）。
-- ★★★ ★★ 与 AddOne 的差异：
--   AddOne 只放 1 个，手上保留其余；
--   AddAll 全放，手上只留装不下的部分（leftovers）。
-- ★ ★★ 注意 AddAll 没有 ignoresound 包裹（AddOne 也没有）。
--   ★★★ 但 2130/2144 行有。⇒ ★★ 不一致：
--     「从手上放东西」：PutOne/PutAll 有静音，AddOne/AddAll 没有。
--     ★ 推断：PutXxx 是「放进空槽」（新物品），AddXxx 是「合并」（无新物品），
--       gotnewitem 的 new_item 判定（1041 行）本就为 false，无需静音。
--       ⇒ ★★★ 这是**正确的**，不是缺陷。设计很精细。
function Inventory:AddAllOfActiveItemToSlot(slot)
-- ↑ AddAllOfActiveItemToSlot 结束（★ 与 528 行 Combine 同构）。
    local active_item = self:GetActiveItem()
-- ★ 取手上的东西。
    local item = self:GetItemInSlot(slot)
-- ★ 取槽内物品。
    if active_item ~= nil and
-- ★ 手上非空。
        item ~= nil and
-- ★ 槽内非空。
        self:CanTakeItemInSlot(active_item, slot) and
-- ★ 槽位允许。
        item.components.stackable ~= nil and
-- ★ 槽内可堆叠。
        item.components.stackable:CanStackWith(active_item) and
-- ★ 同类。
        self:AcceptsStacks() then
-- ★ 本栏接受整摞（★ ★ 没有 IsFull 检查 —— 与 AddOne 不同）。

-- ↑ 条件块结束。
        local leftovers = item.components.stackable:Put(active_item)
-- ★★ Put 全部（★ 溢出的成为 leftovers）。
        self:SetActiveItem(leftovers)
-- ★★★ SetActiveItem(leftovers) —— ★ 与 543-544 行同构。
    end
-- ↑ 条件块结束。
end
-- ↑ AddAllOfActiveItemToSlot 结束。

-- ★★ SwapActiveItemWithSlot —— 「手上物品与槽内物品交换」。
-- ★★★★ 条件（2243-2250 行）—— ★★★ 三重「不」：
--   · CanTakeItemInSlot；
--   · not (可堆叠合并 且 AcceptsStacks) —— 若能合并就不「交换」；
--   · not (手上 >1 个 且 not AcceptsStacks) —— 不能整摞交换。
-- ★★★ ★★ 这两个「not」条件的意义：
--   ① 若两者可合并 → 应该「合并」（AddAll），不交换；
--   ② 若手上是摞且本栏不接受整摞 → 无法整摞交换，不做。
--   ⇒ ★★★ 交换只在「两者不兼容」时发生。
--   ★★ ★ 这与 548 行 SelectActiveItemFromSlot 的区别：
--   那里是「槽 → 手上」（单向取出）；
--   这里是「双向互换」。
-- ★★★ ★★ 2252-2255 行的四步：
--   ① RemoveItem(手上, 整摞) —— 取出手上的；
--   ② RemoveItemBySlot(slot) —— 取出槽里的；
--   ③ GiveActiveItem(槽里的) —— 槽里的上手；
--   ④ GiveItem(手上的, slot) —— 手上的进那个槽。
--   ★★★ ★★★ **注意这是「四步独立操作」，没有原子性保证**：
--   若第③步的 GiveActiveItem 失败（不可能，手上刚被清空），
--   或第④步失败（槽刚被清空，不会），会出问题。
--   ★★ 实际上因为「先全部取出再放入」，所以不会冲突。
--   ★★★ ★★ 这个「先清空再放入」的顺序保证了不会自我冲突
--     （与 2144 行的 PutAll 同款思路）。
-- ★★ ★ 注意 ① 和 ② 都用 RemoveItem，且 ① 传 wholestack=true。
--   ⇒ ★★★ 整摞交换。
function Inventory:SwapActiveItemWithSlot(slot)
-- ↑ SwapActiveItemWithSlot 结束（★ 先清空再放入）。
    local active_item = self:GetActiveItem()
-- ★ 取手上的东西。
    local item = self:GetItemInSlot(slot)
-- ★ 取槽内物品。
    if active_item ~= nil and
-- ★ 手上非空。
        item ~= nil and
-- ★ 槽内非空。
        self:CanTakeItemInSlot(active_item, slot) and
-- ★ 槽位允许。
        not (item.components.stackable ~= nil and item.components.stackable:CanStackWith(active_item) and
-- ★★★ 排除①：若两者可合并且本栏接受整摞 → 应该 AddAll 而非交换。
            self:AcceptsStacks()) and
-- ↑ 排除① 结束。
        not (active_item.components.stackable ~= nil and
-- ★★★ 排除②：手上是摞但本栏不接受整摞 → 无法整摞交换。
            active_item.components.stackable:StackSize() > 1 and
-- ★ 续行。
            not self:AcceptsStacks()) then
-- ↑ 排除② 结束。

-- ↑ 条件块结束。
        self:RemoveItem(active_item, true)
-- ★★★ 先取出手上的（★ 与 2153 行同款「先清空再放入」）。
        self:RemoveItemBySlot(slot)
-- ★★ 再取出槽里的（★ 至此两件都在「无主」状态）。
        self:GiveActiveItem(item)
-- ★★ 槽里的上手。
        self:GiveItem(active_item, slot)
-- ★★ 手上的进那个槽。
    end
-- ↑ 条件块结束。
end
-- ↑ SwapActiveItemWithSlot 结束。

-- 【§十七】★★ CanAccessItem —— ★★ 本文件后半段的「权限闸门」。
-- ★★★★ 2183-2433 行的**每一个** UI 处理器都先调它。
-- ★★★ 三重判定（2260-2267 行）：
--   ① isvisible —— 物品栏 UI 可见；
--   ② item 非 nil；
--   ③ item 有 inventoryitem 组件；
--   ④ owner == self.inst（在我这儿）**或**
--      owner 有 container 组件 且 该容器是我打开的 且 非只读。
-- ★★★★ ④ 的第三种情况（2264-2267 行）★★ 是关键：
--   「我打开的箱子里的东西」也算可访问。
--   ★★★ ★ 因为 opencontainers 里的物品 owner 是「箱子」，
--     而箱子有 container 组件 ⇒ 通过。
--   ★★★ ★ 这就是「箱子 UI 与背包 UI 共享一套处理器」的机制。
-- ★★★ ★★ readonlycontainer 的排除（2267 行）：
--   展示柜等只读容器里的东西**不能被使用**。
-- ★★★ ★★ 2260 行的 `not self.isvisible` 守卫：
--   ★★★ 「物品栏不可见时不能操作其中的物品」。
--   ★★ 这防止了「通过 RPC 直接操作不可见的背包」——
--     一个服务端安全边界。
--   ★★★ ★ 参照 2143 行 Show 的设计：isvisible 是「UI 可见」标志，
--     而 UI 不可见时玩家看不到也点不到，用它做守卫很自然。
function Inventory:CanAccessItem(item)
-- ↑ CanAccessItem 结束（★ 权限闸门，★ 箱子物品也算可访问）。
    if not self.isvisible or item == nil or item.components.inventoryitem == nil then
-- ★★★★ 四重守卫：不可见 / nil / 无 inventoryitem。
        return false
-- ★ 拒绝访问。
    end
-- ↑ 守卫块结束。
    local owner = item.components.inventoryitem.owner
-- ★★ 取 owner（★ 可能是箱子而非玩家）。
    return owner == self.inst or (owner ~= nil and
-- ★★★★ 双重 or：owner 是我 或（owner 是容器 且 我开着它 且 非只读）。
            owner.components.container ~= nil and
-- ★ 续行。
            owner.components.container:IsOpenedBy(self.inst) and
-- ★ ★ IsOpenedBy —— 复用了 2015 行的三重判定。
            not owner.components.container.readonlycontainer)
-- ★ 排除只读容器。
end
-- ↑ CanAccessItem 结束。

-- ★★ UseItemFromInvTile —— 「在物品栏 UI 上使用某物品」。
-- ★★★ 这是**物品栏 UI 交互的核心入口**。
-- ★★★★ 四重入口守卫（2271-2273 行）：
--   ① `not self.inst.sg:HasStateTag("busy")` —— 角色不在忙；
--   ② CanAccessItem(item)；
--   ③ 有 playeractionpicker 组件。
-- ★★★ ★ ①「不在忙」的检查：
--   ★★ 角色状态图带 "busy" 标签时（如正在被电击、正在受控），
--     不能使用物品。
--   ★★ 这个模式在 2270/2305/2337/2368/2425 五处重复出现。
-- ★★ sg = stategraph（角色状态图）。
-- ★★★★ 2274-2283 行：SetClientRequestedAction 包裹的动作收集。
-- ★★★ ★★ 这是**客户端动作请求**的标记机制：
--   ① SetClientRequestedAction(actioncode, mod_name) —— 标记「客户端想要这个动作」；
--   ② 在包裹内收集可用动作（某些动作收集逻辑会看这个标记）；
--   ③ ClearClientRequestedAction() —— 清除标记。
-- ★★★ ★★★ 标记的作用（推理）：
--   动作收集时，服务器可以根据「客户端请求的是哪个动作」
--   来调整候选列表（如优先返回请求的动作）。
--   ★★ 这是一个「客户端意图 → 服务端响应」的单向通道。
-- ★★★★ 2276-2282 行的两分支：
--   · 手上有东西 → GetUseItemActions(item, activeitem, true)（对物品使用手上物）；
--   · 手上空的 → GetInventoryActions(item)（直接使用该物品）。
-- ★★★ 第三参数 true 的含义：推测是「这是从 UI 触发的」。
-- ★★★ 2285 行 `local act = actions[1]` —— ★★ **只取第一个**。
--   ⇒ ★★★ 物品栏 UI 的点击**不支持多动作选择**（不像场景交互）。
--   ★★ 若有多个可用动作，只执行第一个（按 playeractionpicker 的优先级排）。
function Inventory:UseItemFromInvTile(item, actioncode, mod_name)
-- ↑ UseItemFromInvTile 结束（★ 只取 actions[1]）。
    if not self.inst.sg:HasStateTag("busy") and
-- ★★ 角色不忙？
        self:CanAccessItem(item) and
-- ★★ 物品可访问？
        self.inst.components.playeractionpicker ~= nil then
-- ★★ 有 playeractionpicker？
        local actions
-- ★ 动作列表（★ 两个分支分别赋值）。
        SetClientRequestedAction(actioncode, mod_name)
-- ★★★ 标记「客户端想要这个动作」（★ 见 BEFORE 的机制说明）。
        if self:GetActiveItem() ~= nil then
-- ★★ 手上有东西？
            --use the active item on the inventory item
-- ↑ 原英文注释保留（use the active item on the inventory item）。
            actions = self.inst.components.playeractionpicker:GetUseItemActions(item, self:GetActiveItem(), true)
-- ★★ 收集「用手上物作用于该物品」的动作列表。
        else
-- ↑ else 分支。
            --just use the inventory item
-- ↑ 原英文注释保留（just use the inventory item）。
            actions = self.inst.components.playeractionpicker:GetInventoryActions(item)
-- ★★ 收集「直接使用该物品」的动作列表。
        end
-- ↑ if/else 块结束。
        ClearClientRequestedAction()
-- ★★★ ClearClientRequestedAction —— ★ 与 2275 行成对。

		local act = actions[1]
-- ★★★★ ★★ 只取 actions[1] —— ★★ 物品栏 UI 不支持多动作选择。
-- ★★★ 2286-2292 行：地图动作的特殊处理。
-- ★★ `playercontroller:GetMapTarget(act)` —— 「这个动作是否指向地图某处」。
-- ★★★ ★★ 典型：望远镜、地图、罗盘这类「打开地图」的动作。
--   ★★★ ★ 若是指向地图的：PullUpMap(maptarget, act.action) 并 return ——
--   ★★ **直接返回，不走 locomotor**（不需要走过去）。
-- ★★★ ★ 这就是「在物品栏里用望远镜」与「对着望远镜用望远镜」的区别。
-- ★★ 2287 行的组件检查（playercontroller 可能不存在）。
-- ★★★ ★★ 2293-2301 行的判定：`if act == nil then return`；
--   `elseif actioncode == nil or (act.action.code == actioncode and mod_name 匹配)`。
--   ★★★ ★★ 这是「动作码校验」：
--   · actioncode 为 nil（本地直接调用）→ 无条件执行；
--   · actioncode 有值 → 必须与收集到的动作**一致**才执行。
--   ★★★ ★★ 为什么？防作弊/防竞态：
--   客户端可能上报「我要用动作 A」，但服务端算出来是动作 B。
--   ★★ 若不校验就执行 B，玩家会觉得「我点了 A 却做了 B」。
--   ★★★ ★★ 这是一个**客户端意图校验**的范式（★ 见 2358/2321/2408 行同款）。
-- ★★ 2297-2300 行是三段注释掉的 print（远程使用失败的日志）。
--   ★★★ 注释掉说明「这类失败太常见，不需要日志」。
-- ★★ 2296 行 `locomotor:PushAction(act, true)` —— 第二个参数 true 是「强制」。
--   ★★★ 强制意味着「忽略某些前置条件，直接执行」。
--   ★★ 参见 locomotor.lua:882 PushAction 的第二参数语义。
        if self.inst.components.playercontroller then
-- ★★★ 地图动作特例（PullUpMap 后直接返回）。
            local maptarget = self.inst.components.playercontroller:GetMapTarget(act)
-- ★ 有 playercontroller？
            if maptarget ~= nil then
-- ★★★ 地图动作？
                self.inst.components.playercontroller:PullUpMap(maptarget, act.action)
-- ★★ 弹出地图并 return（★ 不走 locomotor）。
                return
-- ★ 早退。
            end
-- ↑ if 块结束。
        end
-- ↑ if 块结束。
		if act == nil then
-- ★★ 动作码校验（★ 客户端意图校验范式）。
            return
-- ★★ 无可用动作 → 直接返回。
        elseif actioncode == nil or (act.action.code == actioncode and act.action.mod_name == mod_name) then
-- ★★★★ 动作码校验（★ 本地调用 or 码与 mod 都要匹配）。
           	self.inst.components.locomotor:PushAction(act, true)
-- ↑ PushAction(act, true)。
-- ★★ 校验通过 → 执行（★ 第二参 true = 强制）。
        --elseif mod_name ~= nil then
-- ↑ 被注释掉的模组失败日志。
            --print("Remote use inventory item failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
-- ↑ 注释的续行。
        --else
-- ↑ else 分支（注释）。
            --print("Remote use inventory item failed: "..tostring(ACTION_IDS[actioncode]))
-- ↑ 注释的续行。
        end
-- ↑ 动作码校验块结束。
    end
-- ↑ 入口守卫块结束。
end
-- ↑ UseItemFromInvTile 结束。

-- ★★ ControllerUseItemOnItemFromInvTile —— 「用手上物品对背包里的物品」。
-- ★★ 守卫比 2270 多了 CanAccessItem(active_item)（2308 行）。
--   ⇒ ★★ 两件物品都要可访问（防止用不可见的手上物品作弊）。
-- ★★★ ★★ 2311 行 `playercontroller:GetItemUseAction(active_item, item)` ——
--   ★★★ 与 2278 行的 GetUseItemActions **不同**：
--   · GetUseItemActions(目标, 手上的, true) —— 返回**候选列表**；
--   · GetItemUseAction(手上的, 目标) —— 直接返回**单个动作**。
--   ★★★ ★ 这里的顺序也是反的（active_item 在前）。
--   ★★ 这就是 Controller 版本与键盘鼠标版本的区别。
-- ★★★ ★★ 2322-2326 行的原注释（★ 重要的 V2C 记录）：
--   "--V2C: Usability improvement for DST, we don't need to close
--    the window for actions since it does not pause in DST"
--   ★★★ ★★ 这说明：DS（单机）需要在执行动作时关闭物品栏窗口（因为游戏暂停），
--   ★★ DST 不暂停，所以不需要关。DST 相比 DS 的一次体验改进。
--   ★★ 2328 行 return true —— 唯一返回 true 的地方（2319/2321 都不返回）。
function Inventory:ControllerUseItemOnItemFromInvTile(item, active_item, actioncode, mod_name)
-- ↑ ControllerUseItemOnItemFromInvTile 结束。
    if not self.inst.sg:HasStateTag("busy") and
-- ★ 角色不忙。
        self:CanAccessItem(item) and
-- ★ 目标物品可访问。
        self:CanAccessItem(active_item) and
-- ★★ ★ 手上物品也可访问（★ 比 2270 行多这一重）。
        self.inst.components.playercontroller ~= nil then
-- ★ 有 playercontroller。
        SetClientRequestedAction(actioncode, mod_name)
-- ★ SetClientRequestedAction。
        local act = self.inst.components.playercontroller:GetItemUseAction(active_item, item)
-- ★★★ ★ 直接返回**单个**动作（★ 与 GetUseItemActions 的列表不同）。
        ClearClientRequestedAction()
-- ★ ClearClientRequestedAction。

        local maptarget = self.inst.components.playercontroller:GetMapTarget(act)
-- ★ 地图动作？
        if maptarget ~= nil then
-- ★ 弹地图。
            self.inst.components.playercontroller:PullUpMap(maptarget, act.action)
-- ★ 早退。
            return
-- ↑ if 块结束。
        end
        if act == nil then
-- ★ 无动作 → 返回。
            return
-- ★ 早退。
        elseif actioncode == nil or (act.action.code == actioncode and act.action.mod_name == mod_name) then
-- ★★★★ 动作码校验（同 2295 行）。
            --V2C: Usability improvement for DST, we don't need to close
-- ★★★ V2C 注释：DS 需要关窗口，DST 不需要。
-- ↑ 原注释保留（DST 不需要关窗口）。
            --     the window for actions since it does not pause in DST
-- ↑ 原注释的续行。
            --[[if self.inst.HUD ~= nil then
-- ↑ 被块注释掉的关窗口代码（长注释块形式）。
                self.inst.HUD.controls.inv:CloseControllerInventory()
-- ↑ 注释掉的代码。
            end]]
-- ↑ ]] 结束。
            self.inst.components.locomotor:PushAction(act, true)
-- ★ PushAction。
            return true
-- ★★ return true（★ 本函数唯一返回 true 的地方）。
        --elseif mod_name ~= nil then
-- ↑ 被注释掉的模组失败日志。
            --print("Remote controller use inventory item on item failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
-- ↑ 注释续行。
        --else
-- ↑ else 分支（注释）。
            --print("Remote controller use inventory item on item failed: "..tostring(ACTION_IDS[actioncode]))
-- ↑ 注释续行。
        end
-- ↑ 校验块结束。
    end
-- ↑ 守卫块结束。
end
-- ↑ ControllerUseItemOnItemFromInvTile 结束。

-- ★★ ControllerUseItemOnSelfFromInvTile —— 「对物品栏里的物品对自己用」。
-- ★★★★ 2344-2348 行的两分支（★ 重要）：
--   · 2344 行 物品**没装备** → GetItemSelfAction(item)（用它对自己）；
--   · 2346 行 物品**已装备** → 构造 ACTIONS.UNEQUIP（卸下）。
-- ★★★ ★★ 2346 行的三重条件：
--   · maxslots > 0（有背包的玩家）；
--   · not HasTag("heavy")（不是重物）；
--   · not GetGameModeProperty("non_item_equips")（模式允许）。
--   ★★★ ★★ 重物为什么不能从物品栏卸？
--   ⇒ 重物需要走「专门的卸下流程」（1305-1309 行的互斥逻辑）。
--     从物品栏直接卸会破坏那个逻辑。
--   ★★ 非物品栏玩家（maxslots=0）没有物品栏 UI，此函数不会被调用。
-- ★★★★ 2347 行 `BufferedAction(self.inst, nil, ACTIONS.UNEQUIP, item)` ——
--   ★★★ ★★ 手动构造一个 BufferedAction 来执行卸下。
--   ★★★ 这是本文件**唯一**构造 BufferedAction 的地方（2419/2428/2447 还有几处）。
--   ★★★ ★ 为什么不用 direct call？因为「卸下」是一个**动作**，
--     需要走完整的动作流程（动画、音效、buffer 打断机制）。
--   ★★ 第三个参数 ACTIONS.UNEQUIP，第四个是目标物品。
-- ★★★ ★★ 2350 行 ClearClientRequestedAction 在两个分支之后调用。
--   ★★★ 注意 2343 行也有一次 SetClientRequestedAction ——
--     所以这个函数有「两次 set 一次 clear」？不，是 set→分支→clear。正确。
function Inventory:ControllerUseItemOnSelfFromInvTile(item, actioncode, mod_name)
-- ↑ ControllerUseItemOnSelfFromInvTile 结束。
    if not self.inst.sg:HasStateTag("busy") and
-- ★ 角色不忙。
        self:CanAccessItem(item) and
-- ★ 物品可访问。
        self.inst.components.playercontroller ~= nil then
-- ★ 有 playercontroller。
        local act = nil
-- ★ 动作变量（★ 两个分支分别赋值）。

        SetClientRequestedAction(actioncode, mod_name)
-- ★ SetClientRequestedAction。
        if not (item.components.equippable ~= nil and item.components.equippable:IsEquipped()) then
-- ★★ 该装备**没穿在身上**？
            act = self.inst.components.playercontroller:GetItemSelfAction(item)
-- ★★ 对自己用（★ GetItemSelfAction）。
        elseif self.maxslots > 0 and not (item:HasTag("heavy") or GetGameModeProperty("non_item_equips")) then
-- ★★★★ 已穿着 → 三重条件：可卸 + 非重物 + 模式允许。
            act = BufferedAction(self.inst, nil, ACTIONS.UNEQUIP, item)
-- ★★ 手动构造 UNEQUIP 的 BufferedAction。
-- ↑ 条件块结束。
        end
-- ↑ if/elseif 块结束。
        ClearClientRequestedAction()
-- ★ ClearClientRequestedAction。

        local maptarget = self.inst.components.playercontroller:GetMapTarget(act)
-- ★ 地图动作？
        if maptarget ~= nil then
-- ★ 弹地图。
            self.inst.components.playercontroller:PullUpMap(maptarget, act.action)
-- ★ 早退。
            return
-- ↑ if 块结束。
        end
        if act == nil then
-- ★ 无动作 → 返回。
            return
-- ★ 早退。
        elseif actioncode == nil or (act.action.code == actioncode and act.action.mod_name == mod_name) then
-- ★★★★ 动作码校验（第 3 处同款）。
            self.inst.components.locomotor:PushAction(act, true)
-- ★ PushAction。
        --elseif mod_name ~= nil then
-- ↑ 被注释掉的失败日志。
            --print("Remote controller use inventory item on self failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
-- ↑ 注释续行。
        --else
-- ↑ else 分支（注释）。
            --print("Remote controller use inventory item on self failed: "..tostring(ACTION_IDS[actioncode]))
-- ↑ 注释续行。
        end
-- ↑ 校验块结束。
    end
-- ↑ 守卫块结束。
end
-- ↑ ControllerUseItemOnSelfFromInvTile 结束。

-- ★★ ControllerUseItemOnSceneFromInvTile —— 「用背包里的物品对场景中的东西」。
-- ★★★★ 本文件**最复杂**的 UI 处理器（四层分支）。
-- ★★★★ 2374-2395 行的分支结构：
--   ① 2374-2385 行 物品**已装备** → 优先对自己用；
--     若不是手持物且动作不匹配 → 改用「对场景目标用」；
--   ② 2386-2388 行 物品的 grandowner 不是我 → **放弃**（无效）；
--   ③ 2389-2395 行 普通情况 → GetItemUseAction(item, target)。
-- ★★★★ ★★ 2374-2385 行的精细逻辑：
--   · 已装备的物品在 Controller 上「对场景用」时，先试「对自己用」；
--   · 2382 行 `CanEntitySeeTarget(self.inst, target)` ——
--     ★★★ ★ **视线检查**：能看见场景目标才允许改用「对场景」。
--   ★★★ 这是一个重要的校验：防止隔着墙/屏幕外使用。
--   ★★ 参见 actions.lua 的 CanEntitySeeTarget 用法（simutil.lua:547）。
-- ★★★★ ★★ 2386-2388 行的「放弃」分支（原注释 ★ 极有价值）：
--   "--V2C: This is now invalid as playercontroller will now send this
--    case to the proper call to move items between controllers."
--   ★★★ ★★ 意思是：「物品的主人不是」这个情况**已经无效**了，
--     因为 playercontroller 现在会走「控制器间移动物品」的正确路径。
--   ⇒ ★★★ ★ 这是「V2C（Verbs to Craft，从 DS 移植到 DST）」的审计记录：
--     作者逐条检查旧逻辑是否还有用，标注哪些已废弃。
--   ★★ 保留这个分支（而不是删掉）是为了「防御性兜底」。
-- ★★★★ 2389-2395 行的四重条件（★ 含一个特殊标签）：
--   · actioncode == nil（本地调用）；
--   · target == nil（无目标）；
--   · CanEntitySeeTarget（能看见）；
--   · target 有 "pocketdimension_container" 标签 **且** 我有
--     "usingmagiciantool" 标签 —— ★★★ 魔术师特例。
--   ★★★ ★★★ 最后一条是「维度口袋」的例外：
--     魔术师（WX78）能对着「维度口袋容器」使用物品，
--     即使看不见（该容器不在物理空间里）。
--   ★★ 这是 mod 与本体协作的一个特例标记。
-- ★★★★ 2403-2404 行的双重排除：`act.action == ACTIONS.UNEQUIP or == ACTIONS.DROP` ——
--   ★★★ ★★ 「对场景用」不应该变成「卸下」或「丢弃」。
--   ★★★ ★ 为什么要排除？因为 2375 行的 GetItemSelfAction 可能返回
--     UNEQUIP（对已装备物品对自己用 = 卸下），
--     而「对场景用」的语义应该是别的动作。
--   ★★★ ⇒ ★★★ **「对自己用」的结果需要被否决**。
--   ★★★ 这解释了 2374-2376 行为何要先试「对自己用」：
--     可能是为了「装备的物品对场景用 = 先卸下？」——
--     实际被 2403 行否决了。
--   ★★★ ★ 这段逻辑**绕了一圈又回到起点**（见 L35）：
--     2374-2376 行算出一个动作，2403 行又把它丢掉。
--     ⇒ 净效果：已装备物品对场景用时，只会走 2382 行的分支。
-- ★★ 2405-2407 行：actioncode == nil 时额外调 DoActionAutoEquip ——
--   ★★★ 「自动装备」：让角色在需要时自动拿起手上的装备。
--   ★★ 参见 playercontroller.lua:4634 DoActionAutoEquip。
function Inventory:ControllerUseItemOnSceneFromInvTile(item, target, actioncode, mod_name)
-- ↑ ControllerUseItemOnSceneFromInvTile 结束（四层分支）。
    if not self.inst.sg:HasStateTag("busy") and
-- ★ 角色不忙。
        self:CanAccessItem(item) and
-- ★ 物品可访问。
        self.inst.components.playercontroller ~= nil then
-- ★ 有 playercontroller。
        local act = nil
-- ★ 动作变量。
        SetClientRequestedAction(actioncode, mod_name)
-- ★ SetClientRequestedAction。
        if item.components.equippable ~= nil and item.components.equippable:IsEquipped() then
-- ★★ 该装备**穿在身上**？
            act = self.inst.components.playercontroller:GetItemSelfAction(item)
-- ★★ 先试「对自己用」。
            if actioncode ~= nil and
-- ★★★★ 四重条件：有 actioncode、有 target、装在手上、且算出的动作不匹配。
                target ~= nil and
-- ★ 续行（有目标）。
                item.components.equippable.equipslot == EQUIPSLOTS.HANDS and
-- ★ 续行（手持槽）。
                not (act ~= nil and
-- ★★ 「且算出的动作不是客户端要的」判定。
                    act.action.code == actioncode and
-- ★ 续行。
                    act.action.mod_name == mod_name) then
-- ★ 续行收尾。
                act = CanEntitySeeTarget(self.inst, target) and
-- ★★★★ ★ 视线检查（★ 防止隔空使用）。
                    self.inst.components.playercontroller:GetItemUseAction(item, target) or
-- ★★ 改用「对场景目标用」。
                    nil
-- ★ or nil（★ 看不清则置 nil）。
            end
-- ↑ 四重条件块结束。
        elseif item.components.inventoryitem:GetGrandOwner() ~= self.inst then
-- ★★★ 「已无效」分支（V2C 审计记录）。
-- ↑ if 块结束。
            --V2C: This is now invalid as playercontroller will now send this
-- ↑ 原注释保留（V2C: This is now invalid...）。
            --     case to the proper call to move items between controllers.
-- ↑ 原注释的续行。
		elseif actioncode == nil
-- ★ elseif 分支（★ ★ 用 or 连接多条件）。
			or target == nil
-- ★ 本地调用。
			or CanEntitySeeTarget(self.inst, target)
-- ★ 无目标。
			or (target:HasTag("pocketdimension_container") and self.inst:HasTag("usingmagiciantool"))
-- ★★★ 魔术师「维度口袋」特例。
-- ★ 看得见。
			then
-- ↑ or 链结束。
            act = self.inst.components.playercontroller:GetItemUseAction(item, target)
-- ★★ 对场景目标用。
        end
-- ↑ if/elseif 块结束。
        ClearClientRequestedAction()
-- ★ ClearClientRequestedAction。

        local maptarget = self.inst.components.playercontroller:GetMapTarget(act)
-- ★ 地图动作？
        if maptarget ~= nil then
-- ★ 弹地图。
            self.inst.components.playercontroller:PullUpMap(maptarget, act.action)
-- ★ 早退。
            return
-- ↑ if 块结束。
        end
		if act == nil or act.action == ACTIONS.UNEQUIP or act.action == ACTIONS.DROP then
-- ★★★ 排除 UNEQUIP / DROP（对场景用不应变成卸下）。
            return
-- ★★ ★ 排除「无动作 / UNEQUIP / DROP」（★ 对场景用不应变成卸下）。
        elseif actioncode == nil then
-- ★★ 本地调用（actioncode 为 nil）。
            self.inst.components.playercontroller:DoActionAutoEquip(act)
-- ★★★ DoActionAutoEquip —— ★ 自动装备（让角色拿起需要的装备）。
            self.inst.components.locomotor:PushAction(act, true)
-- ★ PushAction。
        elseif act.action.code == actioncode and act.action.mod_name == mod_name then
-- ★★ 码与 mod 都要匹配才执行。
            self.inst.components.locomotor:PushAction(act, true)
-- ★ PushAction。
        --elseif mod_name ~= nil then
-- ↑ 被注释掉的失败日志。
            --print("Remote controller use inventory item on scene failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
-- ↑ 注释续行。
        --else
-- ↑ else 分支（注释）。
            --print("Remote controller use inventory item on scene failed: "..tostring(ACTION_IDS[actioncode]))
-- ↑ 注释续行。
        end
-- ↑ 校验块结束。
    end
-- ↑ 守卫块结束。
end
-- ↑ ControllerUseItemOnSceneFromInvTile 结束。

-- ★★ InspectItemFromInvTile —— 「查看物品的详细信息」。
-- ★★★ 条件：CanAccessItem + 有 inspectable 组件。
-- ★★ 2420 行构造 BufferedAction(..., ACTIONS.LOOKAT, item)。
-- ★★★ ★ LOOKAT 动作会播放「举起物品端详」的动画。
-- ★ ★★ 与 2337 行的 UNEQUIP 构造是同一模式（都要走动作流程）。
function Inventory:InspectItemFromInvTile(item)
-- ↑ InspectItemFromInvTile 结束（LOOKAT 动作）。
    if self:CanAccessItem(item) and item.components.inspectable ~= nil then
-- ★★ 双重条件：可访问 + 有 inspectable 组件。
        self.inst.components.locomotor:PushAction(BufferedAction(self.inst, nil, ACTIONS.LOOKAT, item), true)
-- ★★ 构造 LOOKAT 的 BufferedAction（★ 举起物品端详）。
    end
-- ↑ 条件块结束。
end
-- ↑ InspectItemFromInvTile 结束。

-- ★★ DropItemFromInvTile —— 「从物品栏丢弃物品」。
-- ★★★★ 四重守卫（2425-2427 行）：不忙 + CanAccessItem + 有 playercontroller。
-- ★★★ ★★ 2428 行的位置计算（★ 客户端预测的核心）：
--   `playercontroller:GetRemotePredictPositionExternal() or self.inst:GetPosition()`
--   ★★★ ★★ 语义：「如果客户端在做位置预测，用预测位置；否则用真实位置」。
--   ★★★ ★★ 这是**联机手感**的关键：
--     客户端预测玩家位置（走一步动画已经播了但服务端还没确认），
--     此时丢弃物品应该落在**客户端看到的位置**，而不是服务端位置。
--   ★★★ ★ 否则会出现「物品掉在身后/瞬移」的现象。
--   ★★ 交叉引用：playercontroller.lua 的位置预测机制。
--   ★ ★★ 这个位置作为 DropItem 的第 4 个参数（736 行用 pos:Get()）。
-- ★★★★ 2429-2430 行的两个 buffaction 选项：
--   · wholestack = 不是「单个丢」—— 反向映射（single 为真 = 丢一个）；
--   · instant = sg 有 "overridelocomote" 标签 —— ★★★ 即「立即执行」；
--   ★★★ ★★ instant 的判定用的是 **overridelocomote 状态标签**：
--     若角色状态图允许「覆盖移动」，说明当前处于可立即执行的状态
--     （如站着不动、或者在某些特殊状态）。
--   ★★ 详见 stategraph 家族对 overridelocomote 的定义。
function Inventory:DropItemFromInvTile(item, single)
-- ↑ DropItemFromInvTile 结束。
    if not self.inst.sg:HasStateTag("busy") and
-- ★ 角色不忙。
        self:CanAccessItem(item) and
-- ★ 物品可访问。
        self.inst.components.playercontroller ~= nil then
-- ★ 有 playercontroller。
		local buffaction = BufferedAction(self.inst, nil, ACTIONS.DROP, item, self.inst.components.playercontroller:GetRemotePredictPositionExternal() or self.inst:GetPosition())
-- ★★★ 客户端预测位置（★ 联机手感关键）。
        buffaction.options.wholestack = not (single and item.components.stackable ~= nil and item.components.stackable:IsStack())
-- ★★★★ wholestack 反向映射（★ single 为真 = 丢一个 ⇒ wholestack=false）。
		buffaction.options.instant = self.inst.sg ~= nil and self.inst.sg:HasStateTag("overridelocomote")
-- ★★★ instant 由状态标签 overridelocomote 决定（★ 见详解）。
        self.inst.components.locomotor:PushAction(buffaction, true)
-- ★ PushAction。
    end
-- ↑ 守卫块结束。
end
-- ↑ DropItemFromInvTile 结束。

-- ★★ CastSpellBookFromInv —— 「用法术书施法」。
-- ★★★★ 五重条件（2436-2439 行）：
--   · 有 playercontroller 且不忙；
--   · item 是自己 或 CanAccessItem；
--   · item 有 spellbook 组件；
--   · item 是自己 或 CanBeUsedBy(self.inst)。
-- ★★★ ★★ 2445-2446 行的双分支（★ 精巧）：
--   `local target = item == self.inst and item or nil`
--   `local invobject = item ~= self.inst and item or nil`
--   ★★★ ★★ 即：
--   · item 是自己（法术书是角色的一部分，如韦斯戴在头上）→ target = 自己；
--   · item 是手上的书 → invobject = 书，target = nil。
--   ★★★ ★⇒ ★★★ **同一件物品在两个分支里占据不同的参数位置**。
--   ★★★ 这是「同一 prefab 既可当目标又可当道具」的自适应处理。
-- ★★ 2441-2443 行：指定法术（可选）。
-- ★★ 2447 行 `spell_action or ACTIONS.CAST_SPELLBOOK` ——
--   优先用 spellbook 组件自带的动作，否则用默认。
function Inventory:CastSpellBookFromInv(item, spell_id)
-- ↑ CastSpellBookFromInv 结束（★ 同物双参数位）。
	if self.inst.components.playercontroller and
-- ★★ 有 playercontroller。
		not self.inst.components.playercontroller:IsBusy() and
-- ★★ 不忙（★ 用 IsBusy() 而非 sg:HasStateTag，与其他函数不同）。
		(item == self.inst or self:CanAccessItem(item)) and
-- ★★ item 是自己 或 可访问。
		item.components.spellbook and (item == self.inst or item.components.spellbook:CanBeUsedBy(self.inst))
-- ★★ 有 spellbook 且（是自己 或 CanBeUsedBy）。
	then
-- ↑ 四重条件块结束。
		if spell_id ~= nil then
-- ★ 指定法术？
			item.components.spellbook:SelectSpell(spell_id)
-- ★ SelectSpell。
		end
-- ↑ if 块结束。
		local spell_action = item.components.spellbook:GetSpellAction()
-- ★ 取法术动作（★ 可能为 nil）。
		local target = item == self.inst and item or nil
-- ★★★ ★ item 是自己 → target = 自己（★ 与下一行互斥）。
		local invobject = item ~= self.inst and item or nil
-- ★★★ ★ item 是手上的书 → invobject = 书（★ 同一物品占另一参数位）。
		local buffaction = BufferedAction(self.inst, target, spell_action or ACTIONS.CAST_SPELLBOOK, invobject)
-- ★★ 构造 BufferedAction（★ 动作优先用书自己的，否则默认）。
		self.inst.components.locomotor:PushAction(buffaction, true)
-- ★ PushAction。
	end
-- ↑ 条件块结束。
end
-- ↑ CastSpellBookFromInv 结束。

-- 【§二十二】★ EquipActiveItem —— 「把手上装备到对应槽」。
-- ★★★ 条件（2454-2456 行）：手上有 equippable **且**该槽**为空**。
-- ★★★★ ★★★ 2458 行：`self:Equip(active_item, true, active_item.components.equippable.equipslot)`
--   ★★★ ★★ 三个参数：
--   · item = active_item；
--   · old_to_active = **true**（★ 换下的装备拿到手上）；
--   · no_animation = **equipslot（槽名字符串）** —— ★★★ ★★ **BUG！**
--   ★★★★★★ ⚠ 见 L36：第三个参数是 no_animation（布尔），
--     这里传的却是 **equipslot 字符串**。
--   ★★★ ★★★ 在 Lua 里，字符串是 truthy，所以 no_animation 等价于 true。
--     ⇒ ★★★ 行为上「恰好」是「不播动画」，但**语义完全错了**。
--   ★★★ ★★ 推测作者本意是第四个参数 force_ui_anim，或想传 no_animation=true。
--   ★★★ 这是本文件**最明确的一个 bug**，且 grep 核实 2492 行有同样错误。
-- ★★★★ 对比 2486 行 SwapEquipWithActiveItem（2492 行）：
--   `self:Equip(active_item, true, active_item.components.equippable.equipslot)`
--   ★★★ ★★ **完全相同的错误**！两处都传了 equipslot 当 no_animation。
--   ⇒ ★★★ 这说明是**复制粘贴**导致的，不是笔误。
-- ★★ 条件要求「该槽为空」（2456 行）—— 所以不会换下任何东西，
--   old_to_active=true 实际无作用（没有旧装备）。
--   ⇒ ★★ 这解释了为什么这个 bug 没被发现：**两处都是空槽场景**。
function Inventory:EquipActiveItem()
-- ↑ EquipActiveItem 结束（★ L36：第三参数传错）。
    local active_item = self:GetActiveItem()
-- ★ 取手上的东西。
    if active_item ~= nil and
-- ★ 非空。
        active_item.components.equippable ~= nil and
-- ★★ 有 equippable 组件。
        self:GetEquippedItem(active_item.components.equippable.equipslot) == nil then
-- ★★★ ★ 该槽必须是**空的**（★ 与 2486 行 Swap 相反）。

-- ↑ 三重条件块结束。
        self:Equip(active_item, true, active_item.components.equippable.equipslot)
-- ★★★★ ⚠ L36：第三参传 **equipslot 字符串**给 no_animation 布尔位！
    end
-- ↑ 条件块结束。
end
-- ↑ EquipActiveItem 结束。

-- ★★ EquipActionItem —— 「装备某件物品（动作调用版）」。
-- ★★★★ 2463-2469 行的参数处理（★ 值得注意）：
--   · item 为 nil → 用 activeitem；
--   · item 非 nil 但 grandowner 不是我 → **return**（拒绝）。
-- ★★★ ★★ 2465-2469 行的结构：
--   `elseif item ~= nil and (item.components.inventoryitem == nil or
--    item.components.inventoryitem:GetGrandOwner() ~= self.inst) then return`
--   ★★★ ★★ 注意这里**又**检查了 inventoryitem == nil（与 2467 的 or）。
--   ★★ GetGrandOwner() 的语义：「往上追溯所有容器后的最终所有者」。
--   ★★★ ★ 这是「物品在我背包里 vs 物品在我打开的箱子里」的区分。
--   ★★ ⇒ ★★ 只有真正属于我的物品才能被装备。
-- ★★★★ 2470-2483 行：只处理 HANDS 槽的装备（2472 行判定）。
--   ★★★ ★★ 为什么只处理手上？
--   ★★ 因为这个函数是「拿起工具准备干活」的入口，
--     帽子这类不需要「手持动作」。
--   ★★★ ★★ 2474-2477 行：堆叠拆分（与 Equip:1329 同款）：
--   `if stackable and stacksize > 1 and not equipstack then`
--     2475 行 Get(stacksize - 1) —— 把「剩下的 N-1 个」拿下来；
--     2476 行 GiveItem(stack) —— 放回背包。
--   ★★★ ★★ 注意这里是 `stacksize - 1`（**留下 1 个装备**，其余拆出），
--     与 Equip:1331 的 `Get()`（**取走 1 个**，其余留背包）**恰好相反**。
--   ★★★ ★ 两处结果相同（都是「装备 1 个，其余在背包」），
--     但实现路径相反。这是**同一语义的两种实现**（见 L37）。
-- ★★★ 2478 行 `self:Equip(item)` —— **无参数**（其余都默认）。
-- ★★★ ★ 与 2458 行不同：**不传** no_animation ⇒ 播动画。
--   ★★ 手动装备播动画，自动装备不播 —— 合理的差异。
-- ★★★ 2480-2482 行：若装备后 activeitem 还是它，清空手上的记录。
--   ★★★ ★ 为什么要清？因为 Equip 已经把它移到 equipslots 了，
--     activeitem 的引用应该消失（否则它同时在两处）。
-- ★★ ★★ 对比 GiveItem:1041 的 new_item 判定也处理了这个「同体两槽」情形。
function Inventory:EquipActionItem(item)
-- ↑ EquipActionItem 结束（★ 只处理 HANDS）。
    if item == nil then
-- ★★ 没指定物品 → 用手上的。
        item = self:GetActiveItem()
-- ★ 赋值。
    elseif item ~= nil
-- ★ elseif 分支（★ 注意 Lua 允许 elseif 跨行）。
        and (item.components.inventoryitem == nil or
-- ★ 无 inventoryitem 组件。
            item.components.inventoryitem:GetGrandOwner() ~= self.inst) then
-- ★★ grandowner 不是我 → 拒绝（★ 「在我打开的箱子里」不算）。
        return
-- ★ 早退。
    end
-- ↑ 参数处理块结束。
    if item ~= nil and
-- ★ 物品非空。
        item.components.equippable ~= nil and
-- ★ 有 equippable。
        item.components.equippable.equipslot == EQUIPSLOTS.HANDS then
-- ★★★ ★ 只处理 HANDS 槽（★ 帽子不走这个入口）。
        if not item.components.equippable:IsEquipped() then
-- ★ 还没装备？
            if item.components.stackable ~= nil and item.components.stackable.stacksize > 1 and not item.components.equippable.equipstack then
-- ★★★ 三重条件：可堆叠 + 大于 1 + 不支持整摞装备。
                local stack = item.components.stackable:Get(item.components.stackable.stacksize - 1)
-- ★★ 堆叠拆分（★ 与 Equip 的拆分方向相反，语义相同）。
-- ★★ Get(stacksize - 1) —— ★★ **留下 1 个**，其余拆出（与 1331 行相反）。
                self:GiveItem(stack)
-- ★ 拆出的放回背包。
            end
-- ↑ if 块结束。
            self:Equip(item)
-- ★★ Equip（★ 无参数 ⇒ 播动画，★ 与 2458 行不同）。
        end
-- ↑ if IsEquipped 块结束。
        if self:GetActiveItem() == item then
-- ★★ 装备后 activeitem 还指着它？
            self:SetActiveItem()
-- ★★★ SetActiveItem() 清空（★ 消除「同体两槽」的残留引用）。
        end
-- ↑ if 块结束。
    end
-- ↑ 三重条件块结束。
end
-- ↑ EquipActionItem 结束。

-- ★★ SwapEquipWithActiveItem —— 「手上的装备与已装备的交换」。
-- ★★★ 与 2452 行 EquipActiveItem 的差异（★ 只有条件不同）：
--   · 2452 行：要求该槽**为空**；
--   · 2486 行：要求该槽**非空**（2490 行 `~= nil`）。
-- ★★★★ ★★★ 2492 行有一个与 2458 行**完全相同的 bug**：
--   `self:Equip(active_item, true, active_item.components.equippable.equipslot)`
--   ★★★ ★★ 第三参数传 equipslot（字符串）而非布尔 → 见 L36。
--   ★★★ ★★ ★ 这里更严重：因为本函数**必然会换下旧装备**，
--     old_to_active=true 生效 → 旧装备进 activeitem。
--     而 no_animation 被当作 true（碰巧）→ 不播动画。
--   ⇒ ★★★ 若作者本意是「播动画」，那这里的表现是错的。
--   ★★ 玩家体验：「双击手上的装备与已装备的交换」应该有动画。
function Inventory:SwapEquipWithActiveItem()
-- ↑ SwapEquipWithActiveItem 结束（★ L36：同样的错误）。
    local active_item = self:GetActiveItem()
-- ★ 取手上的东西。
    if active_item ~= nil and
-- ★ 非空。
        active_item.components.equippable ~= nil and
-- ★ 有 equippable。
        self:GetEquippedItem(active_item.components.equippable.equipslot) ~= nil then
-- ★★★★ ★ 该槽必须**非空**（★ ★ 与 2456 行的 `== nil` 相反）。

-- ↑ 三重条件块结束。
        self:Equip(active_item, true, active_item.components.equippable.equipslot)
-- ★★★★ ⚠ L36：同样的参数错误（★ ★ 这里必然换下旧装备，影响更大）。
    end
-- ↑ 条件块结束。
end
-- ↑ SwapEquipWithActiveItem 结束。

-- ★★ TakeActiveItemFromEquipSlot —— 「把装备槽里的东西拿到手上」。
-- ★★★ 与 514 行 SelectActiveItemFromEquipSlot 的差异（★★★ 重要）：
--   · 514 行：无论 maxslots 如何，都走 SelectActiveItemFromEquipSlot；
--   · 2496 行：**按 maxslots 分流**（2501-2505 行）。
-- ★★★★ 2501-2505 行的两个分支：
--   · maxslots > 0 → SelectActiveItemFromEquipSlot（正常的「换上」）；
--   · maxslots == 0 → `DropItem(self:Unequip(eslot), true, true)`
--     ★★★ ★★ 直接**丢弃**！
--   ★★★ ★★★ 推理：没有背包的实体（如某些 NPC）卸下装备，
--     东西无处可放 ⇒ 只能丢地上。
--   ★★ 这是「没有背包时的降级处理」。
-- ★★ ★ 注意 2504 行的链式：`DropItem(self:Unequip(eslot), ...)` ——
--   ★★★ Unequip 可能返回 nil（若 preventunequipping），
--     而 DropItem(722 行) 有 `if item == nil ... return` 的守卫，安全。
-- ★★ 与 2509 行的 ID 版（2510 行 `EquipSlot.FromID(slotid)`）配对。
-- ★★★ 2510 行是 EquipSlot 的**第二个**使用点（第一个是 412 行）。
function Inventory:TakeActiveItemFromEquipSlot(eslot)
-- ↑ TakeActiveItemFromEquipSlot 结束（★ 无背包则丢弃）。
    local item = self:GetEquippedItem(eslot)
-- ★ 取该装备槽的物品。
    if item ~= nil and
-- ★ 非空。
        self:GetActiveItem() == nil then
-- ★★ 手上必须为空。

-- ↑ 三重条件块结束。
        if self.maxslots > 0 then
-- ★★★ 有背包（★ 决定是「换上」还是「丢弃」）。
            self:SelectActiveItemFromEquipSlot(eslot)
-- ★★ 正常路径：换上（★ 内部会 Unequip + GiveActiveItem）。
        else
-- ★ else 分支：无背包。
            self:DropItem(self:Unequip(eslot), true, true)
-- ★★★★ 链式 `DropItem(self:Unequip(eslot))` —— ★★ 无处可放只能丢地上。
        end
-- ↑ if/else 块结束。
    end
-- ↑ 三重条件块结束。
end
-- ↑ TakeActiveItemFromEquipSlot 结束。

function Inventory:TakeActiveItemFromEquipSlotID(eslotid)
    self:TakeActiveItemFromEquipSlot(EquipSlot.FromID(eslotid))
-- ★★ EquipSlot.FromID（★ EquipSlot 的第二个使用点）。
end
-- ↑ TakeActiveItemFromEquipSlotID 结束。

-- 【§十八】★★ MoveItemFromAllOfSlot —— 「把背包物品移到打开的容器」。
-- ★★★★ 五步（2514-2561 行）：
--   ① 2516-2519 行 锁定检查（islockedinslot → 拒绝）；
--   ② 2521-2522 行 取 container 组件 + 检查 IsOpenedBy；
--   ③ 2524 行 **currentuser = self.inst**（★★ 关键，见下）；
--   ④ 2526-2530 行 **constructionbuilderuidata 联动**（★★ 见下）；
--   ⑤ 2532-2557 行 取出 + 放入 + 标志复位。
-- ★★★★ ★★ 2524 行的 `container.currentuser = self.inst` ——
--   ★★★★ 「临时标记当前用户」的经典技巧：
--   · container:GiveItem 内部需要知道「是谁在放」，以便：
--     · 触发该用户可见的事件（音效/动画）；
--     · 权限校验（只能放进自己打开的容器）；
--     · 联机同步（只给该用户推 netvar）。
--   · ★★ **不需要把 user 作为参数传进 GiveItem**——
--     ★★★ ★★★ 用一个「临时全局变量」代替参数传递。
--   ★★★ 这是 Klei 代码里**极常见**的模式（搜索 currentuser 可找到几十处）。
--   ★★★ ★★ 代价：① 不能嵌套（内层会覆盖外层）；
--     ② 必须记得复位（2559 行做了）；
--     ③ 若中途 return/抛错则泄漏。
-- ★★★★ ★★ 2526-2530 行的建造 UI 联动（★★ 特殊场景）：
--   `constructionbuilderuidata:GetContainer() == container.inst and
--    GetSlotForIngredient(item.prefab) or nil`
--   ★★★ ★★ 语义：若这个容器是**建造界面**的料箱，
--     就自动定位到「这个物品应该放的槽位」。
--   ★★★ 这是「建造界面把物品拖到料箱」的体验优化：
--     材料自动落到正确的格子。
--   ★★ ★★ 用了 `and ... or nil` 的短路模式：
--     前半为真取 GetSlotForIngredient 的值，为假取 nil。
--   ⚠ ★★ 若 GetSlotForIngredient 返回 **0**（数字），
--     `and 0 or nil` 会得到 **nil**（因为 0 在 Lua 里是真值，所以不会…）
--   ★★ 重新推理：Lua 里只有 nil/false 是假，**0 是真值**。
--     所以 `X and 0 or nil` = 0（正确）。★ 无陷阱。
--   ★★ 与 108 行注释的同类讨论呼应（0 是真值）。
-- ★★★★ 2532-2548 行：取出 → 尝试放入 → 失败则放回。
--   ★★★ ★★ 2533-2535 行：**先清空位置记忆**再放入。
--     `item.prevcontainer = nil; item.prevslot = nil`
--   ★★★ ★★ 为什么？因为即将放进另一个容器，
--     若失败要放回原槽（2546 行），需要知道放哪。
--     ★★ 对比 2533 行的 RemoveItemBySlot 会**设置** prevslot。
--     2534-2535 行的显式清空是在 RemoveItemBySlot **之后**，覆盖它。
--     ⇒ ★★ 意图：不让 GiveItem 走「回原位」路径（1066 行），
--       而是当作「第一次放这个物品」。
--   ★★★ ★★ 这与 1081-1083 行的「失败即清记忆」正好相反，
--     这里是「成功路径也清记忆」。因为 GiveItem 已指定 targetslot。
-- ★★★★ ★★ 2537-2542 行的三个标志设置（★ L13 的舞台）：
--   `if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self)`
--   ★★★ ★★ **这里 `~= nil` 对布尔值永远为真**（见 L13）：
--     ignorespoverflow 是 boolean，初始化为 false（40 行）不是 nil。
--   ⇒ ★★★ 判定退化：「只要是专用容器就置 ignorespoverflow=true」。
--   ★★★ 后果：普通容器（ignorespoverflow=false）也会被置 true，
--     但随后 2551 行同样用 `if container.ignorespoverflow then` 复位（恒真），
--     ⇒ ★★ 净效果正确（置了又复位），但判定条件失去了原意。
--   ★★ 作者本意应是「这个字段存在吗」（针对 inventory 而非 container）。
-- ★★★★ 2544-2548 行：GiveItem 失败则**放回原槽**（2546 行）。
--   ★★★ 这是「事务性」操作：要么成功移入，要么原地不动。
--   ★★ ignoresound 包裹（2545/2547）——失败回填不该播音。
-- ★★ 2551-2556 行：三个标志复位。
--   ★★ ★★ 注意 `ignoreclosedspoverflow` 的复位用了同样的 `if ... then`
--     而**设置**时用的是 `elseif container.ignoreclosedspoverflow ~= nil then`
--     （2540 行）—— ★ 两处判定方式**不一致**。
--   ★★★ 若设置时走了 2540 分支（置 true），复位时也走 2554 分支（置 false）。
--     配对正确。若设置时置了 ignorespoverflow（2538），复位走 2551。
--     ⇒ ★★ 两个分支互斥，复位也没有同时清两个 —— 正确。
-- ★★★ 2559 行 `container.currentuser = nil` —— ★ 复位（在所有路径之后）。
--   ★★★ 但 2532 行 `if container:CanTakeItemInSlot(item, targetslot) then`
--     **若不成立，2532-2557 整块被跳过**，直接到 2559 行。
--   ⇒ ★★ currentuser 仍被正确复位（2532 的失败不跳过 2559）。
--   ★★★ ★ 缩进上 2559 行在 2556 的 end 之后，与 if 同级。正确。
function Inventory:MoveItemFromAllOfSlot(slot, container)
-- ↑ MoveItemFromAllOfSlot 结束。
    local item = self:GetItemInSlot(slot)
-- ★ 取源槽的物品。
    if item ~= nil and container ~= nil then
-- ★★ 非空且目标容器非 nil。
		if item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- ★★ 锁定物品 → 拒绝移动。
			assert(BRANCH ~= "dev")
-- ★ assert。
			return
-- ★ 静默返回。
		end
-- ↑ if 块结束。

        container = container.components.container
-- ★★ 取容器的 container 组件（★ 入参是实体）。
        if container ~= nil and container:IsOpenedBy(self.inst) then
-- ★★★ 有组件且是我打开的。

-- ↑ if 块结束。
            container.currentuser = self.inst
-- ★★★★ currentuser = self.inst（临时全局变量代替参数）。

            local targetslot =
-- ★★ 建造 UI 联动（自动定位材料槽）。
                self.inst.components.constructionbuilderuidata ~= nil and
-- ★★ 建造 UI 的容器是不是这个？
                self.inst.components.constructionbuilderuidata:GetContainer() == container.inst and
-- ★★ 精确比对 container.inst。
                self.inst.components.constructionbuilderuidata:GetSlotForIngredient(item.prefab) or
-- ★★ ★ GetSlotForIngredient —— ★ 自动定位材料该放的槽。
                nil
-- ★ or nil（★ 三重 and 不成立则 nil）。

-- ↑ targetslot 赋值结束。
            if container:CanTakeItemInSlot(item, targetslot) then
-- ★★ 容器能接收？
                item = self:RemoveItemBySlot(slot)
-- ★★ 从源槽取出（★ 会设置 prevslot）。
                item.prevcontainer = nil
-- ★★★ 清容器记忆（★ 与 2533 设置的 prevslot 配对）。
                item.prevslot = nil
-- ★★★ 清槽记忆（★ 让 GiveItem 走「首次投放」而非「回原位」）。

-- ↑ 空行。
				--Hacks for altering normal inventory:GiveItem() behaviour
-- ★★★ 标志设置（★ L13：~= nil 对布尔恒真）。
				if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then
-- ★★★★ ⚠ L13：`ignorespoverflow ~= nil` 对布尔恒真（★ 判定退化）。
					container.ignorespoverflow = true
-- ★ 置 ignorespoverflow（★ 普通容器也会被置 true）。
				elseif container.ignoreclosedspoverflow ~= nil then
-- ★ elseif 分支。
					container.ignoreclosedspoverflow = true
-- ★★★ ★ 同样是布尔判空（★ 与 2538 不同的写法，效果相同）。
				end
-- ↑ if/elseif 块结束。

                if not container:GiveItem(item, targetslot, nil, false) then
-- ★★ 委托容器放入（★ 第四参 false = 不忽略任何限制）。
                    self.ignoresound = true
-- ★ 静音包裹开始。
                    self:GiveItem(item, slot)
-- ★★ 失败 → 放回**原槽**（★ 事务性操作）。
                    self.ignoresound = false
-- ★ 静音包裹结束。
                end
-- ↑ if 块结束。

				--Hacks for altering normal inventory:GiveItem() behaviour
				if container.ignorespoverflow then
-- ↑ 标志复位。
-- ↑ 原注释保留（Hacks for altering normal GiveItem）。
					container.ignorespoverflow = false
-- ★★ 复位 ignorespoverflow（★ ★ 恒真 ⇒ 总会被复位）。
				end
-- ↑ if 块结束。
				if container.ignoreclosedspoverflow then
-- ★ 复位 ignoreclosedspoverflow。
					container.ignoreclosedspoverflow = false
-- ★ 赋 false。
				end
-- ↑ if 块结束。
            end
-- ↑ CanTakeItemInSlot 块结束。

            container.currentuser = nil
-- ★★★ currentuser = nil 复位。
        end
-- ↑ IsOpenedBy 块结束（★ currentuser 在 2559 复位）。
    end
-- ↑ if 块结束。
end
-- ↑ MoveItemFromAllOfSlot 结束。

-- ★★ MoveItemFromHalfOfSlot —— 「把背包里的一半移到容器」。
-- ★★★★ 与 2513 行的差异：
--   · 2570-2571 行 额外要求「可堆叠且是堆叠」；
--   · 2582 行 取一半而非全部。
-- ★★★ ★★ 2582 行 `Get(math.floor(StackSize() / 2))` ——
--   与 2167 行 TakeActiveItemFromHalfOfSlot **完全相同**。
--   ★★★ 同样的「奇数时拿走少的一半」行为。
-- ★★★ ★★ 2583-2584 行清空位置记忆（同 2534-2535）。
-- ★★★★ 2586-2591 行的标志设置（★ **顺序与 2537 行不同**）：
--   ★★★ ★★ 2587 行 `container.ignorespoverflow ~= nil and IsSpecializedContainer`
--   ★★★ 2589-2590 行 `elseif container.ignoreclosedspoverflow ~= nil then`
--   ★★★ ★★ 与 2537-2542 行的结构完全相同（两分支 if/elseif）。
-- ★★ ★★ 2593-2597 行：GiveItem 失败则放回原槽。
--   ★★★ ★ 注意 2593 行 `container:GiveItem(halfstack, targetslot)` ——
--   ★★ 只传了**两个参数**（对比 2544 行传四个）。
--   ★★ 缺 src_pos 和 ignoreeverything。推测无害（可选参数）。
-- ★★★★ 2599-2605 行：三个标志复位（与 2550-2556 同构）。
-- ★★★ 2608 行 currentuser = nil 复位。
function Inventory:MoveItemFromHalfOfSlot(slot, container)
-- ↑ MoveItemFromHalfOfSlot 结束。
    local item = self:GetItemInSlot(slot)
-- ★ 取源槽物品。
    if item ~= nil and container ~= nil then
-- ★★ 非空且有容器。
        container = container.components.container
-- ★ 取 container 组件。
        if container ~= nil and
-- ★★ 有组件且我打开着。
            container:IsOpenedBy(self.inst) and
-- ★ 可堆叠。
            item.components.stackable ~= nil and
-- ★ 是堆叠（非单个）。
            item.components.stackable:IsStack() then
-- ↑ 四重条件块结束。

            container.currentuser = self.inst
-- ★★ currentuser = self.inst（★ 2524 行同款）。

            local targetslot =
-- ★ targetslot 起点。
                self.inst.components.constructionbuilderuidata ~= nil and
-- ★ 建造 UI 判定。
                self.inst.components.constructionbuilderuidata:GetContainer() == container.inst and
-- ★ 比对容器。
                self.inst.components.constructionbuilderuidata:GetSlotForIngredient(item.prefab) or
-- ★★ 取材料槽位。
                nil
-- ★ or nil。

-- ↑ targetslot 赋值结束。
            if container:CanTakeItemInSlot(item, targetslot) then
-- ★ 容器能接收？
                local halfstack = item.components.stackable:Get(math.floor(item.components.stackable:StackSize() / 2))
-- ★★ 取一半（★ 与 2167 行逐字相同）。
-- ★★★ ★★ 2583 行是 2582 行的 then 体首行（★ halfstack 在此定义）。
                halfstack.prevcontainer = nil
-- ★★ 清容器记忆。
                halfstack.prevslot = nil
-- ★★ 清槽记忆。

				--Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 空行。
				if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then
-- ★★★ L13 同款判定。
					container.ignorespoverflow = true
-- ★ 置 ignorespoverflow。
				elseif container.ignoreclosedspoverflow ~= nil then
-- ★ elseif 分支。
					container.ignoreclosedspoverflow = true
-- ★ 置 ignoreclosedspoverflow。
				end
-- ↑ if/elseif 块结束。

                if not container:GiveItem(halfstack, targetslot) then
-- ★★ 委托（★ ★ 只传两参 —— 对比 2544 行的四参）。
                    self.ignoresound = true
-- ★ 静音包裹。
                    self:GiveItem(halfstack, slot)
-- ★ 失败放回原槽。
                    self.ignoresound = false
-- ★ 静音包裹结束。
                end
-- ↑ if 块结束。

				--Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 原注释保留（Hacks）。
				if container.ignorespoverflow then
-- ★ 复位 ignorespoverflow。
					container.ignorespoverflow = false
-- ★ 赋 false。
				end
-- ↑ if 块结束。
				if container.ignoreclosedspoverflow then
-- ★ 复位 ignoreclosedspoverflow。
					container.ignoreclosedspoverflow = false
-- ★ 赋 false。
				end
-- ↑ if 块结束。
            end
-- ↑ CanTakeItemInSlot 块结束。

            container.currentuser = nil
-- ★★ currentuser = nil 复位（★ 2608 与 2573 成对）。
        end
-- ↑ 条件块结束。
    end
-- ↑ if 块结束。
end
-- ↑ MoveItemFromHalfOfSlot 结束。

-- ★★ MoveItemFromCountOfSlot(slot, container, count) ——
--   「把指定数量移到容器」。
-- ★★★★ 与前两个的差异：多一个 count 参数，逻辑分三支（2628-2684 行）：
--   ① 2632 行 摞里数量 > count → 取 count 个（2633 行）；
--   ② 2657 行 **锁定物品** → assert 拒绝；
--   ③ 2659 行 否则 → 整个拿走（2660 行）。
-- ★★★★ ★★ 2629-2631 行的 fullstacksize 计算（★ 同 2179 行）：
--   `stackable and (IsOverStacked() and originalmaxsize or StackSize()) or 1`
--   ★★★ ★★ 与 2179 行 TakeActiveItemFromCountOfSlot **逐字相同**。
--   ⇒ ★★★ 同一逻辑在两处重复实现（见 L37 的同类问题）。
-- ★★★★ 2632 行的判定：`if stackable and StackSize() > count` ——
--   ★★★ ★★ **注意**：没有像 2181 行那样同时检查 islockedinslot。
--   ★★★ 锁定检查在 2657 行（作为 elseif）。
--   ⇒ ★★★ 若物品锁定且 StackSize() > count，会走 2632 分支，
--     **跳过锁定检查**，从锁定槽里「偷」走 count 个！
--   ⚠⚠ 见 L38：这是一个**真实的逻辑漏洞**。
-- ★★★ ★★★ 对比 2174 行 TakeActiveItemFromCountOfSlot：
--   那里 2181 行的条件**相同**，锁定检查也在 2186 行（elseif）。
--   ⇒ ★★ **同样的漏洞存在于两个函数**。
--   ★★★ 漏洞细节：islockedinslot 的物品，count < stacksize 时，
--     会从锁定槽里拆出 count 个放到容器，主物品留在槽里。
--   ★★ 这违反了 724 行的语义（「锁定物品不能被移动」）。
--   ★★★ ★ 但实际影响可能很小：lockedinslot 的物品通常不是堆叠的。
--     若是堆叠（如某个「整摞锁定」物品），才会触发。
-- ★★★★ 2637-2642 行的标志设置（★ 与前两处同构）。
-- ★★★★ 2644-2648 行：GiveItem 失败则放回原槽。
--   ★★★ ★★ 2645 行 `self.ignoresound = true` 包裹放回。
-- ★★★★ 2650-2683 行：标志复位（★ 注意这个块**特别长**，17 行）。
--   ★★★ ★★ 2664-2669 行的标志设置（else 分支也有一份！）。
--   ★★★ ⇒ ★★★ 三个分支（2632/2659/2660）**各自有一份标志设置与复位**。
--   ★★★ ★ 这是「复制粘贴」导致的代码膨胀：
--     2637-2642（分支①）、2664-2669（分支③）—— 两份相同代码。
--   ★★ 而 2586/2537 各只有一份。⇒ ★★ MoveItemFromCountOfSlot 最冗长。
-- ★★★★ 2687 行 currentuser = nil 复位。
function Inventory:MoveItemFromCountOfSlot(slot, container, count)
-- ↑ MoveItemFromCountOfSlot 结束（★ L38：锁定检查漏网）。
    local item = self:GetItemInSlot(slot)
-- ★ 取源槽物品。
    if item ~= nil and container ~= nil then
-- ★★ 非空且有容器。
        container = container.components.container
-- ★ 取 container 组件。
        if container ~= nil and
-- ★★ 有组件。
            container:IsOpenedBy(self.inst) then
-- ★ 我打开着。

-- ↑ 三重条件块结束。
            container.currentuser = self.inst
-- ★★ currentuser = self.inst（第 3 处同款）。

            local targetslot =
-- ★ targetslot 起点。
                self.inst.components.constructionbuilderuidata ~= nil and
-- ★ 建造 UI 判定。
                self.inst.components.constructionbuilderuidata:GetContainer() == container.inst and
-- ★ 比对容器。
                self.inst.components.constructionbuilderuidata:GetSlotForIngredient(item.prefab) or
-- ★ 取材料槽位。
                nil
-- ★ or nil。

-- ↑ targetslot 赋值结束。
            if container:CanTakeItemInSlot(item, targetslot) then
-- ★ 容器能接收？
                local stackable = item.components.stackable
-- ★ 取 stackable（可能 nil）。
                local fullstacksize = stackable and (stackable:IsOverStacked() and stackable.originalmaxsize or stackable:StackSize()) or 1
-- ★★ fullstacksize 计算（★ 与 2179 行逐字相同）。
                count = math.clamp(count, 1, fullstacksize)
-- ★★ math.clamp 钳制（★ 与 2180 行同款）。
                if stackable and stackable:StackSize() > count then
-- ★★ 摞里比要的多？
                    local countedstack = stackable:Get(count)
-- ★ Get(count) 取出。
                    countedstack.prevcontainer = nil
-- ★★ 清容器记忆。
                    countedstack.prevslot = nil
-- ★★ 清槽记忆。

					--Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 空行。
					if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then
-- ★ 标志设置（分支①）。
-- ★★★★ L13 同款判定（第 3 处）。
						container.ignorespoverflow = true
-- ★ 置 ignorespoverflow。
					elseif container.ignoreclosedspoverflow ~= nil then
-- ★ elseif 分支。
						container.ignoreclosedspoverflow = true
-- ★ 置 ignoreclosedspoverflow。
					end
-- ↑ if/elseif 块结束。

                    if not container:GiveItem(countedstack, targetslot) then
-- ★★ 委托放入。
                        self.ignoresound = true
-- ★ 静音包裹。
                        self:GiveItem(countedstack, slot)
-- ★ 失败放回原槽。
                        self.ignoresound = false
-- ★ 静音包裹结束。
                    end
-- ↑ if 块结束。

					--Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 原注释保留（Hacks）。
					if container.ignorespoverflow then
-- ★ 复位 ignorespoverflow。
						container.ignorespoverflow = false
-- ★ 赋 false。
					end
-- ↑ if 块结束。
					if container.ignoreclosedspoverflow then
-- ★ 复位 ignoreclosedspoverflow。
						container.ignoreclosedspoverflow = false
-- ★ 赋 false。
					end
-- ↑ if 块结束。
				elseif item.components.inventoryitem and item.components.inventoryitem.islockedinslot then
-- ★★ elseif：锁定物品 → assert（★ ★★ 但 2632 分支会绕过它，见 L38）。
					assert(BRANCH ~= "dev")
-- ★ assert（dev 版崩）。
                else
-- ★ else 分支：整个拿走。
                    item = self:RemoveItemBySlot(slot)
-- ★ RemoveItemBySlot。
                    item.prevcontainer = nil
-- ★★ 清容器记忆。
                    item.prevslot = nil
-- ★★ 清槽记忆。

					--Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 空行。
					if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then
-- ★ 标志设置（分支③，★ 复制粘贴的第二份）。
-- ★★★★ L13 同款判定（★ ★ 复制粘贴的第 2 份）。
						container.ignorespoverflow = true
-- ★ 置 ignorespoverflow。
					elseif container.ignoreclosedspoverflow ~= nil then
-- ★ elseif 分支。
						container.ignoreclosedspoverflow = true
-- ★ 置 ignoreclosedspoverflow。
					end
-- ↑ if/elseif 块结束。

                    if not container:GiveItem(item, targetslot, nil, false) then
-- ★★ 委托放入（★ 第四参 false）。
                        self.ignoresound = true
-- ★ 静音包裹。
                        self:GiveItem(item, slot)
-- ★ 失败放回原槽。
                        self.ignoresound = false
-- ★ 静音包裹结束。
                    end
-- ↑ if 块结束。

					--Hacks for altering normal inventory:GiveItem() behaviour
-- ↑ 原注释保留（Hacks）。
					if container.ignorespoverflow then
-- ★ 复位 ignorespoverflow。
						container.ignorespoverflow = false
-- ★ 赋 false。
					end
-- ↑ if 块结束。
					if container.ignoreclosedspoverflow then
-- ★ 复位 ignoreclosedspoverflow。
						container.ignoreclosedspoverflow = false
-- ★ 赋 false。
					end
-- ↑ if 块结束。
                end
-- ↑ if/elseif/else 块结束。
            end
-- ↑ CanTakeItemInSlot 块结束。

            container.currentuser = nil
-- ↑ currentuser = nil 复位。
-- ★★ currentuser = nil 复位（第 3 处）。
        end
-- ↑ 条件块结束。
    end
-- ↑ if 块结束。
end
-- ↑ MoveItemFromCountOfSlot 结束（★ 全文件最长函数之一）。

-- 【§二十四】★ GetEquippedMoistureRate(slot) —— 「装备携带的湿度」。
-- ★★★★ 两个分支（2695-2710 行）：
--   · 给了 slot → 只查那**一格**（但用的是 GetItemInSlot，普通槽！）；
--   · 没给 → 遍历所有**装备槽**。
-- ★★★★ ★★ 2696 行 `local item = self:GetItemInSlot(slot)` ——
--   ★★★ ★★★ **这是普通槽查询**（777 行的 GetItemInSlot），
--     而不是 GetEquippedItem（773 行，装备槽查询）。
--   ⇒ ★★★ ★★ 给了 slot 时查的是**普通背包格**，不是装备槽！
--   ⚠⚠ 这几乎肯定是**一个 bug**（见 L39）：
--     · 无参调用（2692 行最常见）→ 遍历 equipslots，正确；
--     · 有参调用（slot 参数）→ 查 itemslots，**语义错误**。
--   ★★★ 推测原意应该是 `self:GetEquippedItem(slot)`。
--   ★★ grep 核实：本文件的调用方在别处（inventory_classified 或 buff）。
--   ★★★ ★★ 但从代码看，slot 分支明显是「装备湿度查单槽」，
--     用 GetItemInSlot 显然是笔误。
-- ★★★★ 2698 行 `equippable:GetEquippedMoisture()` 返回 `{moisture, max}`。
--   ★★★ ★★ 累加方式：moisture 和 max **分别累加**（2699-2700 行）。
--   ★★★ ★ 这不是「求最大值」而是「求总和」——
--     即所有装备的湿气上限加总。
--   ★★ ★★ 对比 equippable.lua:214 GetEquippedMoisture 返回单件的值。
--     这里是「全装备加总」。
--   ★★★ ★★ 推断：这是「装备总容量」的概念——
--     所有装备合起来能携带多少湿气。
--   ★★★ ⚠ 但 equippable.lua 的 L4 指出：
--     equippedmoisture/maxequippedmoisture 字段**无人写入**（恒为 0）。
--   ⇒ ★★★ ★★ 所以本函数目前**恒返回 0, 0**！
--   ★★★ ★ 这是「接口已就绪、数据源缺失」的半成品（见 equippable L4）。
function Inventory:GetEquippedMoistureRate(slot)
-- ↑ GetEquippedMoistureRate 结束（★ L39：slot 分支查错表）。
    local moisture = 0
    local max = 0
    if slot then
-- ★★ 给了 slot？
        local item = self:GetItemInSlot(slot)
-- ★★★★ ⚠ L39：GetItemInSlot（★ 普通槽）而非 GetEquippedItem（装备槽）！
        if item and item.components.equippable then
-- ★ 是装备类物品？
            local data = item.components.equippable:GetEquippedMoisture()
-- ★ 取湿度数据。
            moisture = moisture + data.moisture
-- ★ 累加当前湿度。
            max = max + data.max
-- ★ 累加上限。
        end
-- ↑ if 块结束。
    else
-- ★ else 分支：遍历装备槽。
        for k,v in pairs(self.equipslots) do
-- ★ 遍历 equipslots。
            if v and v.components.equippable then
-- ★ 是装备类物品？
                local data = v.components.equippable:GetEquippedMoisture()
-- ★ 取湿度数据。
                moisture = moisture + data.moisture
-- ★ 累加。
                max = max + data.max
-- ★ 累加。
            end
-- ↑ if 块结束。
        end
-- ↑ equipslots 遍历结束。
    end
-- ↑ else 块结束。
    return moisture, max
-- ★★ return (moisture, max) —— ★★ 双返回值。
end
-- ↑ GetEquippedMoistureRate 结束（★ 目前恒返回 0,0 —— 见 equippable L4）。

-- ★★ GetWaterproofness(slot) —— 「防水度」。
-- ★★★★ 三段（2715-2733 行）：
--   ① 2715-2717 行 全局短路：moisture 组件说有防水背包 → 返回 1；
--   ② 2719 行 累加器初始化为 0；
--   ③ 2721-2732 行 两个分支：给 slot 查单件 / 不给则遍历装备槽累加。
-- ★★★ ★★ 2715-2717 行的短路：
--   `if inst.components.moisture ~= nil and GetWaterproofInventory()`
--   ★★★ ★★ 「防水背包」是个**角色级能力**（韦斯的雨伞等），
--     直接返回 1.0（完全防水）。
--   ★★★ ★ 这是「角色能力优先于装备」的体现。
--   ★★ 对比 IsInsulated（759 行）的三层判定，那里没有这种短路。
-- ★★★★ ★★ 与 IsInsulated 的核心差异（★ 见 759 行注释）：
--   · IsInsulated：**布尔或**（任一件绝缘就整体绝缘）；
--   · GetWaterproofness：**数值累加**（各件防水度相加）。
--   ⇒ ★★★ 2737 行的 `IsWaterproof()` = `GetWaterproofness() >= 1` ——
--     ★★★ 「累加到 1 才算完全防水」。
--   ★★★ ★★ 这解释了为什么单件防水伞给 1.0，两件 0.5 的也能凑成 1.0。
--   ★★ 2718/2720 行的注释掉的 print（调试残留）。
-- ★★★★ ★★ 2722 行 `local item = self:GetItemInSlot(slot)` ——
--   ★★★ ★★ **与 2696 行同样的问题**（见 L39）：
--     给了 slot 时查的是**普通背包格**，不是装备槽。
--   ⚠⚠ 同样的疑似 bug。★ 两个函数犯了同一个错，
--     强烈暗示是复制粘贴所致。
-- ★★★★ 2727-2731 行：无参时遍历 **equipslots** 累加 waterproofer。
--   ★★★ ★★ 累加各装备的 `waterproofer:GetEffectiveness()`。
--   ★★★ ★ 正确使用 equipslots（对比 2722 行的错误分支）。
function Inventory:GetWaterproofness(slot)
-- ↑ GetWaterproofness 结束（★ 累加，与 IsInsulated 的布尔或不同）。
    if self.inst.components.moisture ~= nil and self.inst.components.moisture:GetWaterproofInventory() then
-- ★★ 有 moisture 组件且背包级防水？
        return 1
-- ★★★ 直接返回 1（★ 完全防水，★ 短路压过装备累加）。
    end
-- ↑ if 块结束。

-- ↑ 被注释掉的调试 print。
    local waterproofness = 0
-- ★ 累加器初始化。

-- ↑ 被注释掉的调试 print。
    if slot then
-- ★★ 给了 slot？
        local item = self:GetItemInSlot(slot)
-- ★★★ 同样用 GetItemInSlot（★ L39 的第二处）。
-- ★★★★ ⚠ L39：同样用 GetItemInSlot（★ 与 2696 行同款错误）。
        if item and item.components.waterproofer then
-- ★ 有 waterproofer？
            waterproofness = waterproofness + item.components.waterproofer:GetEffectiveness()
-- ★ 累加有效性。
        end
-- ↑ if 块结束。
    else
-- ★ else：遍历装备槽。
        for k,v in pairs(self.equipslots) do
-- ★ 遍历 equipslots（★ ★ 这里用的是**正确**的 equipslots）。
            if v and v.components.waterproofer then
-- ★ 有 waterproofer？
                waterproofness = waterproofness + v.components.waterproofer:GetEffectiveness()
-- ★ 累加有效性。
            end
-- ↑ if 块结束。
        end
-- ↑ equipslots 遍历结束。
    end
-- ↑ else 块结束。
    return waterproofness
-- ★★ return waterproofness（★★ 数值累加，与 IsInsulated 的布尔或不同）。
end
-- ↑ GetWaterproofness 结束。

-- ★★ IsWaterproof —— 「是否完全防水」。
-- ★★★ ★★ `return self:GetWaterproofness() >= 1` ——
--   ★★★ 「累加防水度达到 1」才算完全防水。
--   ★★★ ★ 与 IsInsulated 的布尔或**形成鲜明对比**。
--   ★★ 两种汇总策略的取舍：
--   · 防水是定量的（数值），累加有意义（半件+半件=完全防水）；
--   · 绝缘是定性的（有/无），累加无意义。
function Inventory:IsWaterproof()
-- ↑ IsWaterproof 结束（≥ 1 才算完全防水）。
    return self:GetWaterproofness() >= 1
-- ★★ >= 1 才算完全防水（★ 累加到 1）。
end
-- ↑ IsWaterproof 结束。

-- ★★ TransferComponent(newinst) —— 「把整个 inventory 组件转给新实体」。
-- ★★ 2741-2743 行：EmptyBeard 清理（威尔逊）。
-- ★★★ 2744 行 `self:TransferInventory(newinst)` ——
--   ★★★ ★★ 委托给 TransferInventory（120 行），把三张表全转过去。
-- ★★★ ★★ 用途：**形态转换**（换角色）。
--   ★★★ 转移后**本物品栏变空**，newinst 获得全部物品。
-- ★★★ ★ 注意没有把新物品栏的 maxslots 改过来 ——
--   maxslots 属于**实体**（47 行），不是可转移的状态。
--   ⇒ ★★★ 若两个实体的 maxslots 不同（如人形 → 四足），
--     转移可能出现「物品超出新栏位容量」。
--   ★★★ ★ 这是「inventory 是绑在实体上的组件」的直接后果。
-- ★★★ ★★ 对比 SwapEquipment（156 行）：那个是**交换装备**，
--   这个是**转移所有物品**。
function Inventory:TransferComponent(newinst)
-- ↑ TransferComponent 结束（形态转换）。
    if self.inst.EmptyBeard ~= nil then
-- ★ 有 EmptyBeard 钩子（★ 威尔逊）。
        self.inst:EmptyBeard()
-- ★★ EmptyBeard() —— ★ 转型前清胡子。
    end  
-- ↑ if 块结束。
    self:TransferInventory(newinst)
end
-- ↑ TransferComponent 结束。

-- ★★ GetOpenContainerProxyFor(master) —— 「按 master 反查容器代理」。
-- ★★★★ 2748-2752 行：遍历 opencontainerproxies，找匹配 master 的。
-- ★★★ ★★ 这是本文件对 `opencontainerproxies`（57 行）的**唯一**读取点。
--   ⇒ ★★ 该字段由 container_proxy.lua 写入，本文件只读。
-- ★★★ 用途：韦斯的「钟表追踪箱子」等需要一个独立的 UI 代理，
--   通过 master 找到它来刷新 UI。
-- ★★★ ★★ 返回值可能是 nil（找不到）—— 调用方必须判空。
-- ★★★ ★★ 2749 行 `k.components.container_proxy:GetMaster()` ——
--   无 nil 检查。若某成员没有 container_proxy 组件会崩。
--   ★★ 参照 1540 行的 or 兜底风格，这里是「隐含契约」。
function Inventory:GetOpenContainerProxyFor(master)
-- ↑ GetOpenContainerProxyFor 结束（★ 唯一读取点）。
	for k in pairs(self.opencontainerproxies) do
-- ★★ 遍历容器代理（★ 本文件对该字段的唯一读取点）。
		if k.components.container_proxy:GetMaster() == master then
-- ★★★★ ⚠ `k.components.container_proxy` 无 nil 保护。
			return k
-- ★★★ return 匹配的代理实体。
		end
-- ↑ if 块结束。
	end
-- ↑ 代理遍历结束。
end
-- ↑ GetOpenContainerProxyFor 结束（★ 找不到返回 nil）。

return Inventory
-- ↑ 文件末行（return Inventory 之后）。