/**
 * spec-ccomponent-p2.mjs —— components/container.lua 第 367-720 行
 * CanAcceptCount / GiveItem / Remove* / Open / Close
 */

export const BEFORE = {
  "ValidateItemForOverflow#1": [
    "-- 【ValidateItemForOverflow：溢出准入的额外校验】",
    "--   ★ 注意它的第二个形参 overflow **完全没被使用** —— 只判物品，不判目标容器。",
    "--   ⚠ 这与函数名给人的印象不符（「校验物品对某溢出的准入」），实际是「校验物品通用准入」。",
    "--     当前无害（第 420/458 行调用时都紧接着做容器级判定），仅标注风格问题。",
  ],
  "ValidateItemForOverflow#1+1": [
    "-- ★ 没有 inventoryitem 组件时返回 true —— 原注释「should never happen, just return true XD」。",
    "--   ★ 作者用「XD」表明这是**故意的宽松兜底**而非笔误。",
    "--   ⇒ 设计取舍：与其在这里崩溃，不如放行让下游（GiveItem）去拒绝。",
  ],
  "ValidateItemForOverflow#1+3": [
    "-- ★★ 拒绝 pocketonly 物品（第 2 道门，与第 274 行同源）。",
    "--   注意这里用 **or**：canonlygoinpocket **或** canonlygoinpocketorpocketcontainers 都拒。",
    "--   对照第 274 行用 and（后者允许 pocket 容器收）——这里更严，因为溢出不区分容器类型。",
  ],
  "ValidateItemForOverflow#1+9": [
    "-- ★ 原注释保留：「-- Check how many of an item we can accept from its stack.」",
    "--   ⇒ CanAcceptCount 的问题不是「能不能放」而是「**还能收几个**」。",
  ],
  "Container:CanAcceptCount#1": [
    "-- 【★★★ CanAcceptCount：批量接收能力计算 —— 智能分配算法的基础】",
    "--   ★ 用途：拆分一摞物品到 N 个容器时，先问每个容器能收几个（见 MoveItemFromCountOfSlot）。",
    "--   ★ 返回 0 表示「一个都不收」；返回 stacksize 表示「整摞都收得下」。",
    "--   ⚠ O(numslots × specialized) 复杂度，每帧调用会慢 —— 但只在拖拽时调用。",
  ],
  "Container:CanAcceptCount#1+1": [
    "-- ★ 只读容器直接返回 0：一个都收不了。",
    "--   ★ 这是 readonlycontainer 的**第三条防线**（另两条见第 275/987 行）。",
  ],
  "Container:CanAcceptCount#1+5": [
    "-- ★ stacksize = 物品当前堆叠数（非堆叠物按 1 算）。",
  ],
  "Container:CanAcceptCount#1+6": [
    "-- ★★★ 槽位锁物品的特殊算法：`math.max(maxcount or math.huge, stacksize - 1)`。",
    "--   翻译：当物品被锁（islockedinslot）时，收进来的数量应该是「已有的减一」，",
    "--     也就是**允许把重复的一份追加进去、但不能把原来那份也一起算进来**。",
    "--   ⇒ 配合第 285 行的「锁槽允许同类型追加」规则，形成一致语义。",
    "--   ⚠ 这段逻辑高度晦涩，是全文件最难读懂的 3 行之一。若 maxcount 传入则取较大值。",
  ],
  "Container:CanAcceptCount#1+11": [
    "-- stacksize <= 0 → 返回 0。防止 maxcount=0 之类的不合法入参。",
  ],
  "Container:CanAcceptCount#1+17": [
    "-- ★ 原注释保留：「--Check for empty space in the container.」",
    "--   注意它同时处理两件事：**已有同类型的剩余空间** + **空槽位**。",
  ],
  "Container:CanAcceptCount#1+22": [
    "-- ★ 同类型堆叠：累加 RoomLeft()（还能再放几个）。",
    "--   ★ RoomLeft = maxsize - stacksize，由 stackable 组件提供。",
    "--   ⇒ 这就是「把一摞东西拆开塞进已有同类的摞里」的容量计算。",
  ],
  "Container:CanAcceptCount#1+24": [
    "-- ★ 累加够整摞就**提前返回 stacksize** —— 短路优化，也是语义「全收得下」。",
  ],
  "Container:CanAcceptCount#1+29": [
    "-- ★★ 空槽位分支：走完整的 CanTakeItemInSlot（含 itemtestfn）。",
    "--   ⇒ **itemtestfn 在这里被第二次调用**（第一次在第 450 行 GiveItem 入口）。",
    "--     所以「查询能收几个」也会触发用户定义的筛选规则（可能有副作用，如第 227 行的 GetOpeners）。",
  ],
  "Container:CanAcceptCount#1+30": [
    "-- ★★ acceptsstacks 为 false 时，**只能收 1 个**（`or stacksize <= 1` 是单件物品的例外）。",
    "--   ⇒ 这就是「晾肉架一次只能放一块肉」的实现，与 GiveItem 第 534 行配套。",
  ],
  "Container:CanAcceptCount#1+40": [
    "-- 【★ 第二阶段：把「专用容器」也算进容量】",
    "--   ★ 这让「弹药包里的弹药」也计入背包的接收能力 —— 嵌套容器被视为背包的一部分。",
    "--   ⚠ 注意 GetSpecializedContainers 返回的是**组件**而非实体（第 810 行）。",
  ],
  "Container:CanAcceptCount#1+43": [
    "-- ★ ShouldPrioritizeContainer(item)：这个专用容器是否优先收这个物品。",
    "--   ★ 与第 430 行 CanTakeItemInSlot 并列：两个判定都过才计入容量。",
  ],
  "Container:CanAcceptCount#1+47": [
    "-- 专用容器的堆叠空间累加（结构与第 399 行逐字对称）。",
  ],
  "Container:CanAcceptCount#1+53": [
    "-- ★ 专用容器的空槽检查，同样走 CanTakeItemInSlot → itemtestfn。",
  ],
  "Container:CanAcceptCount#1+67": [
    "-- ★ 返回累计的 acceptcount（不是布尔）。调用方用它决定「拆几个过去」。",
    "--   ⚠ 注意：若既没有堆叠空间也没有空槽，返回 0，调用方据此放弃。",
  ],
  "Container:GiveItem#1": [
    "-- 【★★★ GiveItem —— 容器系统最核心的写入函数】",
    "--   ★ 它是「所有放入路径的最终收敛点」：无论从哪来，最后都走这里。",
    "--   ★ 它的复杂度来自三个正交维度：",
    "--     ① **目标槽**：指定槽 / 专用槽（GetSpecificSlotForItem）/ 自动找空位；",
    "--     ② **堆叠合并**：能否并入已有同类摞；",
    "--     ③ **溢出**：本容器放不下时，是否转交给嵌套的专用容器。",
    "--   ⇒ 下面的逐段注释按这三个维度展开。",
  ],
  "Container:GiveItem#1+1": [
    "-- item 为 nil 直接失败。（防御性：调用方多会先判，但这里再判一次。）",
  ],
  "Container:GiveItem#1+3": [
    "-- ★★★ 唯一的准入检查：`item.components.inventoryitem ~= nil and self:CanTakeItemInSlot(...)`。",
    "--   ⚠ 注意这是 **and**：没有 inventoryitem 组件的物品**静默失败**（走到第 558 行落地），",
    "--     因为整个 if 块被跳过。这是合理的：不能进容器的物品掉地上。",
  ],
  "Container:GiveItem#1+4": [
    "-- ★ 槽位决策第 1 优先级：调用方指定的 slot；没指定则试「专用槽」。",
    "--   ⇒ 注意顺序：指定的 slot **优先于**专用槽。所以「强制放第 3 格」会覆盖语义槽。",
    "--   ★ 这个顺序在 MoveItemFromAllOfSlot 第 1348 行被利用：先算出 targetslot。",
  ],
  "Container:GiveItem#1+6": [
    "-- ★ slot == nil 分支 = 「没有指定槽，也没有专用槽」→ 尝试溢出到专用容器。",
    "--   ★ 这是「背包里的弹药包自动吸走弹药」的实现位置。",
  ],
  "Container:GiveItem#1+8": [
    "-- 取出本容器内的专用容器列表（第 801 行：扫描 1..numslots 找有 priorityfn 的）。",
  ],
  "Container:GiveItem#1+10": [
    "-- ★ 逐个尝试：ShouldPrioritizeContainer + ValidateItemForOverflow 双判定。",
    "--   ⇒ 这两个判定都过，才真的把物品塞进去。",
  ],
  "Container:GiveItem#1+12": [
    "-- ★★ 记住放入**前**的堆叠数 num，用于第 461 行判断「有没有变化」。",
    "--   这是「部分成功」的检测手段：如果 GiveItem 后数量没变，说明一个都没收。",
  ],
  "Container:GiveItem#1+13": [
    "-- ★ 递归调用 spoverflow:GiveItem(item, nil, src_pos, false)。",
    "--   ⚠ 第 4 参数 drop_on_fail=false —— **失败时不落地**。",
    "--   ⇒ 关键设计：溢出失败不能把物品丢在背包脚下，必须留给后续流程处理。",
  ],
  "Container:GiveItem#1+14": [
    "-- ★★★ `finished or 数量变了` —— 「有任何进展」判定。",
    "--   · finished = 专用容器返回 true（明确成功）；",
    "--   · 数量变了 = 部分成功（拆了一部分进去）。",
    "--   ⇒ 两者都触发第 462-473 行的「闭容器收物动画」通知。",
  ],
  "Container:GiveItem#1+15": [
    "-- ★★ SpawnPrefab(\"container_closed_receiveitem_classified\") —— 网络特效实体。",
    "--   ★ 用途：让**其他客户端**看到「有个东西被塞进了关闭的容器」。",
    "--   它是 classified（只对特定客户端可见）的短命实体，由 prefabs/container_closed_receiveitem_classified.lua",
    "--     消费（第 8-33 行的 OnItemDirty 处理动画）。",
    "--   ⇒ 这是容器系统里唯一「主动发网络实体」的地方，值得特别注意。",
  ],
  "Container:GiveItem#1+18": [
    "-- ★ isclosed=true 表示「容器保持关闭状态，只播图标动画」。",
    "--   另一个值 false 会强制打开容器并把物品动画化地飞进去。",
  ],
  "Container:GiveItem#1+20": [
    "-- ★★ 条件链：① 物品存在 ② 专用容器**没被**当前玩家打开 ③ 本容器**被**当前玩家打开。",
    "--   ⇒ 即：「你正看着自己的背包，但你的弹药包是关着的」。",
  ],
  "Container:GiveItem#1+21": [
    "-- ★ GetGrandOwner()：向上追溯「这个容器最终归谁」（背包→玩家→？）。",
    "--   用于判断「物品是不是在别人的背包里」（第 469 行 owner == nil 或无 container）。",
  ],
  "Container:GiveItem#1+22": [
    "-- ⚠ `if owner == nil or owner.components.container` —— 意图是「owner 不是玩家本体」。",
    "--   推理：GetGrandOwner 返回玩家的 inventory item 或玩家实体。",
    "--     若返回 nil（无主）→ 也算；若有 container 组件 → 说明是「被别人装着的容器」。",
    "--   ⚠ 逻辑可疑：如果 owner 是玩家**自己**，它有没有 components.container？",
    "--     玩家实体通常没有 container 组件，所以自己身上也会满足条件 → 通知自己。",
    "--     这与第 467 行「你不是专用容器的 opener」组合后，实际效果尚可；但语义不严谨。",
    "--     ★ 判定为 ⚠ 疑似缺陷（语义含混），不改代码。",
  ],
  "Container:GiveItem#1+27": [
    "-- ★ 专用容器明确报告成功 → GiveItem 整体返回 true，提前结束。",
  ],
  "Container:GiveItem#1+35": [
    "-- ★ 原注释保留：「--try to burn off stacks if we're just dumping it in there」",
    "--   → 「burn off」是俚语，指把多余堆叠**消化掉**（并进已有摞）。",
    "--   ⇒ 这一段是「指定槽已有同类摞且未满」的合并路径。",
  ],
  "Container:GiveItem#1+36": [
    "-- ★★ 两道前置：物品可堆叠 **且** 本容器接受整摞。",
    "--   ⇒ acceptsstacks=false 的容器完全跳过合并逻辑（物品只能一格一件）。",
  ],
  "Container:GiveItem#1+37": [
    "-- ★ 原注释保留（三行）：「Added this for when we want to dump a stack back into a",
    "--   specific spot (e.g. moving half a stack failed, so we need to dump the leftovers",
    "--   back into the original stack)」",
    "--   → 这解释了第 487-501 行整段代码的**真实用途**：",
    "--     「移动半摞失败 → 把剩下的塞回原来的摞里」，而不是留在原地。",
    "--   ★ 这是一个为「MoveItemFromHalfOfSlot 失败回滚」服务的分支（第 1454 行调用）。",
  ],
  "Container:GiveItem#1+40": [
    "-- ★ slot 在范围内才尝试合并（否则说明目标槽不存在）。",
  ],
  "Container:GiveItem#1+42": [
    "-- ★ 同类型 + 目标摞未满 —— 三个条件缺一不可。",
  ],
  "Container:GiveItem#1+43": [
    "-- ★ 若本容器自己被装在别人身上（owner 存在），给 owner 推 gotnewitem 事件。",
    "--   ⇒ 用于播放「物品进入背包」的音效/提示（inventoryitem 的 OnPutInInventory 也会触发）。",
  ],
  "Container:GiveItem#1+47": [
    "-- ★★ stackable:Put(item) —— 把 item 合并进 other_item。",
    "--   ★ 返回值语义（stackable.lua:Put）：**返回溢出的部分，nil 表示全被吃下**。",
    "--     所以第 495 行 `if item == nil then return true` 表示「全并进去了，成功」。",
    "--   ⚠ 若返回溢出部分，item 变量被重新赋值，流程继续往下走（第 499 行重算专用槽）。",
  ],
  "Container:GiveItem#1+52": [
    "-- ★ 合并后如果还有溢出，**重新算专用槽** —— 因为剩下的可能属于另一种物品。",
    "--   ⚠ 但这里没有再算「自动空位」，slot 仍是 nil（若原来有 slot 则保留）。",
  ],
  "Container:GiveItem#1+56": [
    "-- ★ slot == nil 分支：不限槽地扫描所有槽，找第一个可合并的。",
    "--   ⚠ 注意此处**合并后不 return**，继续循环下一个槽（第 511 行在 for 内），",
    "--     所以「一摞东西会依次填满所有同类摞」——这是期望行为。",
  ],
  "Container:GiveItem#1+64": [
    "-- Put 同样返回溢出部分；返回 nil（全部并入）则第 512 行 return true。",
  ],
  "Container:GiveItem#1+73": [
    "-- ★★ 最终选位：三条互斥路径 ——",
    "--   ① 指定槽且未被占 → 用它（第 521 行）；",
    "--   ② 不要求专用槽且有槽位 → 找**第一个空槽**（第 524-529 行有序 for）；",
    "--   ③ 都不满足 → in_slot 为 nil，走到第 558 行落地。",
  ],
  "Container:GiveItem#1+74": [
    "-- ⚠ 潜在缺陷：条件只检查 `not self.slots[slot]`，**没检查 slot 是否是合法语义槽**。",
    "--   推理：第 451 行已通过 GetSpecificSlotForItem 保证了语义，但若调用方",
    "--     直接传了一个 itemtestfn 不接受、且恰好为空的 slot，此处仍会放进去。",
    "--   ⇒ 不过第 450 行的 CanTakeItemInSlot(item, slot) **已经用同一个 slot 验过 itemtestfn**，",
    "--     所以实际是安全的。前置检查覆盖了后置假设。仅作推理记录。",
  ],
  "Container:GiveItem#1+76": [
    "-- ★★ `not self.usespecificslotsforitems` —— 有语义的槽位容器**不做自动找空位**。",
    "--   ⇒ 语义容器的物品必须由 itemtestfn 指定槽位，否则宁可不放（第 532 行 in_slot 为 nil）。",
    "--     这是「香料锅不会把香料放进食材槽」的强制保证。",
  ],
  "Container:GiveItem#1+78": [
    "-- ★ 用有序 for 找第一个空槽（**不是** pairs）—— 因为「第一个」需要确定性。",
    "--   ⇒ 视觉后果：物品总是填满从上到下、从左到右，不会留随机空洞。",
  ],
  "Container:GiveItem#1+85": [
    "-- ★ 找到了可用的槽位。",
  ],
  "Container:GiveItem#1+87": [
    "-- ★★★ 兜底分支：非堆叠容器被迫接收超量堆叠时，Get 一个塞进去。",
    "--   ★ 原注释保留：「--weird case where we are trying to force a stack into a non-stacking",
    "--     container. this should probably have been handled earlier, but this is a failsafe」",
    "--   → 作者自认这是**补丁**：正常路径不该走到这里。",
    "--   ⚠ 关键：函数**返回 false**（第 539 行）——明明放进去一个却报告失败。",
    "--     这是刻意的语义：「我只放进去 1/N，调用方应该知道还有剩余要处理」。",
    "--     对照 MoveItemFromAllOfSlot 第 1384 行：收到 false 会走回滚逻辑（第 1386 行）。",
  ],
  "Container:GiveItem#1+96": [
    "-- ★ infinitestacksize 容器：新放入的堆叠立刻解除 maxsize 限制（第 36 行的只读开关）。",
    "--   ⇒ 「无限堆叠容器」的实现点之一（另见第 1041 行取出时恢复）。",
  ],
  "Container:GiveItem#1+99": [
    "-- ★ OnPutInInventory(self.inst) —— 把「主人」改成容器自己。",
    "--   ★ 后果：物品的 prevslot 会被设置（inventoryitem.lua:315），可被 GetSlotNum 读到。",
  ],
  "Container:GiveItem#1+100": [
    "-- ★★★ PushEvent(\"itemget\", {slot, item, src_pos}) —— 联机同步的事件源。",
    "--   ★★★ **本文件不写任何 netvar**，全靠这个事件。转写发生在：",
    "--     components/container_replica.lua:30-36 的 _onitemget：",
    "--       `self.classified:SetSlotItem(data.slot, data.item, data.src_pos)`",
    "--   ⇒ 这就是「服务端组件只产生事件，replica 转成网络」的完整链路。",
    "--   ⚠ ⚠ 注意 src_pos 也被同步（container_classified.lua 的 slot 数据含位置），",
    "--     客户端用它做物品「飞入」动画。",
  ],
  "Container:GiveItem#1+102": [
    "-- ★ 音效：仅当本容器有 inventoryitem.owner（说明它自己被装在玩家身上）时播。",
    "--   ★ ignoresound（第 63 行）是搬运事务用的临时静音开关（第 1112 行设置）。",
  ],
  "Container:GiveItem#1+110": [
    "-- ★ 原注释保留：「--default to true if nil」",
    "--   ⇒ drop_on_fail 语义：nil/false = 不落地，**其他一律落地**。",
    "--   ⚠ 注意是 `~= false` 而非真值判断 —— 所以 drop_on_fail=nil 也会落地。",
  ],
  "Container:GiveItem#1+112": [
    "-- ★ 原注释保留：「--@V2C NOTE: not supported when container_proxy」",
    "--   与第 222 行同因：客户端影子实体的坐标是 (0,0,0)。",
  ],
  "Container:GiveItem#1+113": [
    "-- ★★ 失败落地前先 DropOverstackedExcess：把超量堆叠的多余部分先吐出来。",
    "--   ⇒ 顺序很重要：先吐料再落地，否则落地的是整摞，吐料会丢在别处。",
  ],
  "Container:GiveItem#1+114": [
    "-- ★ 物品落到**容器自己的世界坐标**（而非 src_pos）。",
    "--   ⇒ 与第 558 行的语义呼应：放不进容器的东西落在容器脚下。",
  ],
  "Container:GiveItem#1+119": [
    "-- ★★ 失败返回 false（与第 539 行的「部分成功」区分不开 —— 两者都返回 false）。",
    "--   ⚠ 这是本函数 API 的一个**已知粗糙处**：调用方无法区分「一个没放」与「放了一个但报失败」。",
    "--     目前靠第 461 行「比较堆叠数变化」来补救（那是在溢出路径里）。",
    "--     直接调用 GiveItem 的路径（第 1384 行）则只能靠回滚兜住。",
  ],
  "Container:RemoveItemBySlot#1": [
    "-- 【★ RemoveItemBySlot：按槽号移除，支持整摞/单个】",
    "--   ★ 第 570 行 `slot and self.slots[slot] or nil`：slot 为 nil 时短路为 nil，",
    "--     不会报错。这是 Lua 的 and/or 惯用法在此的妙用。",
  ],
  "Container:RemoveItemBySlot#1+3": [
    "-- ★ wholestack=true → 整摞移除（DropItemBySlot 第 129 行用 true；",
    "--   而 RemoveItem 的默认（nil）表示只取 1 个，见第 957/1028 行）。",
  ],
  "Container:RemoveAllItems#1": [
    "-- 【★ RemoveAllItems：一次性取出全部，返回实体列表】",
    "--   ⚠ 疑似缺陷：`table.insert(collected_items, item)` —— 当 item 为 nil（空槽）时",
    "--     **Lua 的 table.insert(t, nil) 会报错还是插入 nil？**",
    "--     在标准 Lua 5.1 中 `table.insert(t, nil)` 是**合法的**（等价 t[#t+1]=nil），",
    "--     但会使 #t 不可靠；某些实现会抛「wrong number of arguments」。",
    "--     ⇒ 若当前引擎允许，则返回的表里有空洞（不是真正的列表）；",
    "--       若抛错，则空容器调用 RemoveAllItems 会崩。",
    "--     推理：本文件其他地方（GetAllItems 第 609 行）都显式 `if v ~= nil` 过滤，",
    "--     唯独这里没有——**强烈暗示作者预期这里总有值或没测过空容器**。",
    "--     ★ 判定为 ⚠ 疑似缺陷。不改代码。",
  ],
  "Container:GetNumSlots#1": ["-- GetNumSlots：读 numslots。容器组件与 inventory 组件同名接口，便于统一抽象。"],
  "Container:GetItemInSlot#1": [
    "-- GetItemInSlot：★ 双重真值判断（`slot and self.slots[slot]`），",
    "--   slot 为 nil 或该槽为空都返回 nil（不是 false）。调用方直接判真值即可。",
  ],
  "Container:GetItemSlot#1": [
    "-- 【★ GetItemSlot：反向查询「某物品在第几槽」】",
    "--   ★ 用 pairs 遍历（无序）—— 但只要找到**一个**匹配就返回，顺序无关。",
    "--   ⇒ 这是本文件中少数「遍历顺序不影响正确性」的用法。",
    "--   ⚠ O(n) 复杂度，是移除路径（第 1011 行）的固定开销。",
  ],
  "Container:GetAllItems#1": [
    "-- GetAllItems：★ 与 RemoveAllItems（第 578 行）不同，这里**过滤了 nil**（第 609 行）。",
    "--   ⇒ 对照可见第 578 行的 nil 过滤确实缺失，两者本应一致。强化了上条的判定。",
  ],
  "Container:Open#1": [
    "-- 【★★★ Open —— 容器打开的完整流程（八步）】",
    "--   ① 防重入（第 618 行 openlist 检查）；",
    "--   ② 启动 onupdate（自动关闭的巡检器）；",
    "--   ③ **同类互斥**：关掉同 prefab 或同 type 的旧容器（第 624-628 行）；",
    "--   ④ 登记 openlist + opencount + 通知 replica；",
    "--   ⑤ **UI**：HUD:OpenContainer（第 637 行）；",
    "--   ⑥ **音效**（第 639-649 行）；",
    "--   ⑦ 事件与回调（第 656-664 行）。",
    "--   ★ 全程**不发网络包**——同步靠第 634 行的 replica:AddOpener。",
  ],
  "Container:Open#1+1": [
    "-- ★★ 防重入：`doer ~= nil and self.openlist[doer] == nil`。",
    "--   已打开过的人再 Open 是**静默无操作**（不是报错、不是重复计数）。",
  ],
  "Container:Open#1+2": [
    "-- ★★ skipautoclose 恒为 nil（构造函数第 34 行已注释该字段的初始化）——",
    "--   ⚠ 这意味着 `not nil` 恒真，**StartUpdatingComponent 永远执行**。",
    "--   ⇒ 即：所有容器都会开启每帧巡检（第 1059 行 OnUpdate）以支持自动关闭。",
    "--   ⚠ 这个字段是**死配置**：读它的代码（第 619 行）以为它在起作用。",
    "--     grep 核实：本文件内 skipautoclose 只出现在第 34 行（注释）与第 619 行（读）。",
    "--     ★ 判定为 ⚠ 疑似缺陷（死字段）。与 containers.lua:50 droponopen 同类。不改代码。",
  ],
  "Container:Open#1+5": [
    "-- ★ 取出打开者的物品栏组件。没有 inventory（NPC？）就跳过同类互斥与登记。",
  ],
  "Container:Open#1+7": [
    "-- ★★ 遍历「该玩家当前已打开的所有容器」。",
    "--   inventory.opencontainers 是一个 {容器实体 → true} 的表（第 630 行登记）。",
  ],
  "Container:Open#1+8": [
    "-- ★★★ 同类互斥的核心判据：`k.prefab == self.inst.prefab or k.components.container.type == self.type`。",
    "--   ⇒ ① 同 prefab 一定互斥（两个背包不能同时开）；",
    "--     ② 同 type 也互斥（所以两个 type=\"chest\" 的箱子不能同开）。",
    "--   ⚠ 潜在缺陷：若两个容器的 type **都是 nil**（未配蓝图），`nil == nil` 为真 →",
    "--     会被判为同类而互斥。当前所有容器都配了 type（grep 核实无遗漏），故无害。",
    "--     ★ 但这是一个「默认值导致意外相等」的典型隐患。仅标注，不改代码。",
    "--   ★⚠ 另一处隐患：k 是 opencontainers 的键（实体），而这里假定它必有 container 组件。",
    "--     若某实体因异常进入了 opencontainers 但没 container 组件 → nil 索引崩溃。",
    "--     当前登记入口只有第 630 行（self.inst，必有组件），安全。",
  ],
  "Container:Open#1+13": [
    "-- ★ 登记到玩家的 opencontainers —— 这是「同类互斥」的数据基础。",
    "--   ⇒ 与第 708 行的清理配对。",
  ],
  "Container:Open#1+16": [
    "-- ★ opencount 递增。注意它与 openlist 严格同步（第 683-684 行成对减）。",
  ],
  "Container:Open#1+17": [
    "-- ★★★ 联机同步的第一步：通知客户端镜像「这个人打开了」。",
    "--   → container_replica.lua:191 AddOpener → 生成/复用 prefabs/container_opener.lua 实体，",
    "--     并把 classified 的可见目标改成这个 opener（第 62 行 SetClassifiedTarget）。",
    "--   ⇒ ★ 这解释了一个设计：**每个打开者有一个独立的 classified 目标**，",
    "--     所以多人同时开同一个箱子时，各自看到的内容可以不同（比如各自的可视化范围）。",
  ],
  "Container:Open#1+19": [
    "-- ★★ 只有**有 HUD 的实体**（玩家）才走 UI 分支；NPC 走第 650 行的 playeractionpicker 分支。",
    "--   ⇒ 这是「服务端也要支持 NPC 开箱子」的设计：AI 用 playeractionpicker 而非 HUD。",
  ],
  "Container:Open#1+20": [
    "-- ★★★ UI 挂载的唯一调用点：`doer.HUD:OpenContainer(self.inst, self:IsSideWidget())`。",
    "--   ⇒ screens/playerhud.lua:385 OpenContainerWidget 里据此选 containerroot 或 containerroot_side，",
    "--     再按容器 type（第 392-400 行）细分到具体挂点。",
    "--   ★ 也就是说：**type 决定「挂在哪个控件下」，issidewidget 决定「哪一侧」。**",
    "--   ⚠ 绘制、动画、鼠标捕获全在 widgets/containerwidget.lua，本文件不碰。",
  ],
  "Container:Open#1+21": [
    "-- ★ refreshcrafting：打开容器会刷新合成面板。",
    "--   ⇒ 原因：容器里的物品可能满足合成材料（见第 417 行的溢出逻辑）。",
    "--     ⚠ 这也说明**合成会看容器内容**（GetCraftingIngredient 第 920 行的用途）。",
  ],
  "Container:Open#1+22": [
    "-- ★★★ 音效的三级回退（这是本文件最精细的一处 UI 处理）：",
    "--   ① 皮肤音效 SKIN_SOUND_FX[AnimState:GetSkinBuild()].open_ui（第 642 行）；",
    "--   ② 蓝图自定义 widget.opensound（第 645 行）；",
    "--   ③ 侧边 UI 用背包音、中央 UI 用通用容器音（第 646-647 行）。",
    "--   ⇒ ★ 这解释了 containers.lua:508-513 的 V2C 注释为何要覆盖 opensound：",
    "--     蓝图值会**压过**默认音，但**低于**皮肤音效。",
  ],
  "Container:Open#1+23": [
    "-- ★★ 原注释保留（FIXME 标记）：「-- FIXME(JBK): The changes here need a way to tie",
    "--   the self.widget back to the entity to GetSkinBuild from for other containers like",
    "--   pillar and bundle wraps. Replicate to the other three spots in container and",
    "--   container_replica.」",
    "--   → 作者自认这段逻辑在 container / container_replica 里**重复了 4 份**（open/close × 两文件），",
    "--     且「皮肤音效」取不到某些容器的 skin build。",
    "--   ★ 这是本文件最诚实的一段注释：明确指出了自己的重复与局限。",
  ],
  "Container:Open#1+25": [
    "-- ★ SKIN_SOUND_FX[skinbuild].open_ui —— 皮肤专属 UI 音效，优先级最高。",
    "--   ⚠ `self.inst.AnimState and ...` —— 防御性：没有 AnimState 的实体（如纯数据实体）跳过。",
    "--   prefabskin.lua:18 定义 SKIN_SOUND_FX。",
  ],
  "Container:Open#1+26": [
    "-- ★ TheFocalPoint.SoundEmitter —— 发声点固定在摄像机焦点，而非容器位置。",
    "--   ⇒ UI 音效应当在「屏幕空间」播放，与容器在世界里的位置无关。",
  ],
  "Container:Open#1+33": [
    "-- ★★ 无 HUD 分支（NPC/AI）：把容器注册进 playeractionpicker。",
    "--   ⇒ playeractionpicker 是 AI 的「动作选择器」，注册后 AI 能对此容器执行动作。",
    "--   ⚠ 注意这里的条件是 `doer.components.playeractionpicker ~= nil`，",
    "--     与第 652 行的 elseif 条件构成完整的 if/elseif/else 三分支。",
  ],
  "Container:Open#1+39": [
    "-- ★ PushEvent(\"onopen\") —— 实体事件，任何 prefab 都可以监听。",
    "--   ⇒ 这是「prefab 定制打开行为」的官方 hook（如开箱动画、特效）。",
  ],
  "Container:Open#1+41": [
    "-- ★★ onopenfn 只在 opencount == 1 时触发（第 1 个打开者）。",
    "--   ⇒ 语义：「这个容器刚刚从关闭变成打开」。多人打开时只有一次。",
    "--   ⚠ 第二个参数是 `{doer = doer}`（一张表），不是 doer 本身 —— 调用方需注意。",
  ],
  "Container:Open#1+45": [
    "-- ★ onanyopenfn：每个打开者都触发一次（与 onopenfn 的区别就在这）。",
  ],
  "Container.Close_Items_Internal#1": [
    "-- 【★ Close_Items_Internal：递归关闭「容器里的容器」】",
    "--   ★ 设计意图：打开一个背包时若里面有箱子，那箱子不该保持打开状态。",
    "--   做成独立函数是为了配合 ForEachItem（第 783 行）的 `fn(v, ...)` 签名。",
  ],
  "Container:Close#1": [
    "-- 【★★ Close —— 与 Open 对称的六步】",
    "--   ① 先递归关内层容器（第 675 行）；",
    "--   ② doer == nil 时广播给所有打开者（第 676-681 行）；",
    "--   ③ 注销 openlist + opencount；",
    "--   ④ UI / 音效（第 691-702 行）；",
    "--   ⑤ 清理 inventory.opencontainers（第 707-709 行）；",
    "--   ⑥ 事件与回调（第 711-719 行）。",
  ],
  "Container:Close#1+1": [
    "-- ★ 先关内层容器。注意它在 doer == nil 的分支**之前**，所以每个递归 Close 都会重复执行。",
    "--   ⚠ 轻微冗余：递归路径下 ForEachItem 会被多次调用。无功能影响（幂等）。",
  ],
  "Container:Close#1+2": [
    "-- ★★ doer == nil 的「广播关闭」：遍历 openlist 给每个人各调一次 Close。",
    "--   ⇒ 这是 Container.OnRemoveEntity（第 1086 行）的清理方式：实体被移除时",
    "--     以 doer=nil 调用 Close，把所有打开者的 UI 都关掉。",
    "--   ⚠ 潜在缺陷：在 `for opener in pairs(self.openlist)` 中递归调用 self:Close(opener)，",
    "--     而 Close 内部会 `self.openlist[doer] = nil`（第 683 行）—— **在遍历中修改被遍历的表**。",
    "--     Lua 允许把当前键置 nil（这是标准行为，next 的语义支持删除当前键），",
    "--     所以实测不会崩，但严格说这属于「依赖未文档化行为」。仅标注。",
  ],
  "Container:Close#1+8": [
    "-- ★ 只有在 openlist 里的人才走后续流程（否则是重复关闭，静默忽略）。",
  ],
  "Container:Close#1+10": [
    "-- ★ opencount 与 openlist 成对递减——两者必须始终一致。",
  ],
  "Container:Close#1+13": [
    "-- ★ 最后一个打开者离开时才停止每帧巡检（省性能）。",
    "--   ⇒ 与第 620 行的 StartUpdatingComponent 配对，形成「按需巡检」模式。",
  ],
  "Container:Close#1+17": [
    "-- ★ Close 的 UI 挂载点（第 637 行的镜像）。",
  ],
  "Container:Close#1+20": [
    "-- ★★ 关闭音效：结构与开启完全对称（第 639-649 行的三级回退）。",
    "--   ⇒ 这就是第 640 行 FIXME 注释说的「重复了四份」之一。",
  ],
  "Container:Close#1+29": [
    "-- ★ NPC 分支：反注册 playeractionpicker（第 650 行的镜像）。",
    "--   ★ 注意这里用 elseif 而非嵌套 if，与 Open 的结构对称。",
  ],
  "Container:Close#1+33": [
    "-- ★ 清理玩家侧的 opencontainers 登记（第 630 行的镜像）。",
    "--   ⚠ 这里只清理 doer 的登记表；别人的登记（若有多人同时开）保持不动 —— 正确。",
  ],
  "Container:Close#1+37": [
    "-- ★★ onclosefn 只在 opencount == 0 时触发（最后一个打开者离开）。",
    "--   ★ 与 Open 的 onopenfn（第 658 行）完全对称。",
    "--   ⚠ 但第 712 行传的是 doer（裸值）而非 {doer = doer}（表）——",
    "--     **与第 659 行的 onopenfn 参数格式不一致**！",
    "--     推理依据：第 659 行 `self.onopenfn(self.inst, {doer = doer})`，",
    "--       第 712 行 `self.onclosefn(self.inst, doer)`。",
    "--     ⇒ 调用方若写 `local doer = args.doer` 在 onclosefn 里会拿到 nil。",
    "--     ★ 判定为 ⚠ 疑似缺陷（API 不对称）。这是 API 契约缺陷而非逻辑缺陷。仅标注，不改代码。",
  ],
  "Container:Close#1+41": [
    "-- ★ onanyclosefn：对称于第 662 行的 onanyopenfn。",
  ],
  "Container:Close#1+45": [
    "-- ★ PushEvent(\"onclose\")：与第 656 行 onopen 对称。",
  ],
};

export const AFTER = {};