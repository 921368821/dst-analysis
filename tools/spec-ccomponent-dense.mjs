/**
 * spec-ccomponent-dense.mjs —— components/container.lua 密集注释
 *
 * 由 gen-dense-ccomp.mjs 依据 FIELD_C_DOC / FN_DOC / LOCAL_FN_DOC 三张人工表生成：
 *   · 构造函数每个字段都有**专属释义 + 初值说明**
 *   · 每个函数（含 10 个局部函数）都有**职责一句话**
 *   · 控制流行写「这一步在做什么决策」，不复述语法
 *   · 重复出现的字段只写「同第 N 行 + 本行实际值」
 */

export const HEADER_EXTRA = [];

export const BEFORE = {
  16: [
    "-- 局部变量：local container = inst.components.container  〔所在：OnOwnerDespawned〕",
  ],
  17: [
    "-- 条件分支：if container ~= nil then  〔所在：OnOwnerDespawned〕",
  ],
  19: [
    "-- 局部变量：local item = container.slots[i]  〔所在：OnOwnerDespawned〕",
  ],
  20: [
    "-- 条件分支：if item ~= nil then  〔所在：OnOwnerDespawned〕",
  ],
  32: [
    "-- ★ 关掉客户端开箱音效。★ 由容器组件设、由客户端读（container_replica.lua:289）。",
    "--   本行初值：false。",
  ],
  33: [
    "-- ★ 关掉客户端关箱音效（同上，container_replica.lua:293）。",
    "--   本行初值：false。",
  ],
  35: [
    "-- ★ 是否接受整摞物品。默认 true；蓝图可覆盖（containers.lua 有 20+ 处 false）。",
    "--   本行初值：true。",
  ],
  41: [
    "-- ★ 蓝图里的 UI 配置表。★ 浅拷贝共享：多个同类容器的 self.widget 是同一张表。",
    "--   本行初值：nil。",
  ],
  61: [
    "-- ★ hack flag：禁用 GetSpecializedContainers（第 802 行）。设置于第 1375 行。",
    "--   本行初值：false。",
  ],
  62: [
    "-- ★ hack flag：允许往**未打开**的专用容器塞物（第 793 行）。设置于第 1378 行。",
    "--   本行初值：false。",
  ],
  63: [
    "-- ★ hack flag：塞物时不播 gotnewitem 音效（第 549 行）。搬运事务期间的临时静音。",
    "--   本行初值：false。",
  ],
  68: [
    "-- 局部赋值：canbeopened = oncanbeopened,  〔所在：OnOwnerDespawned〕",
  ],
  69: [
    "-- 局部赋值：skipopensnd = onskipopensnd,  〔所在：OnOwnerDespawned〕",
  ],
  70: [
    "-- 局部赋值：skipclosesnd = onskipclosesnd,  〔所在：OnOwnerDespawned〕",
  ],
  75: [
    "-- 白名单成员「numslots」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  76: [
    "-- 白名单成员「acceptsstacks」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  77: [
    "-- 白名单成员「usespecificslotsforitems」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  78: [
    "-- 白名单成员「issidewidget」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  79: [
    "-- 白名单成员「type」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  80: [
    "-- 白名单成员「widget」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  81: [
    "-- 白名单成员「itemtestfn」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  82: [
    "-- 白名单成员「priorityfn」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  83: [
    "-- 白名单成员「openlimit」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  87: [
    "-- 循环：for i, v in ipairs(widgetprops) do  〔所在：Container:WidgetSetup〕",
  ],
  94: [
    "-- 循环：for i, v in ipairs(widgetprops) do  〔所在：Container:WidgetSetup〕",
  ],
  100: [
    "-- 返回：return self.widget  〔所在：Container:GetWidget〕",
  ],
  104: [
    "-- 返回：return GetTableSize(self.slots)  〔所在：Container:NumItems〕",
  ],
  108: [
    "-- 返回：return GetTableSize(self.slots) >= self.numslots  〔所在：Container:IsFull〕",
  ],
  112: [
    "-- 返回：return next(self.slots) == nil  〔所在：Container:IsEmpty〕",
  ],
  116: [
    "-- assert(numslots >= self.numslots)  〔所在：Container:SetNumSlots〕",
  ],
  117: [
    "-- 槽位总数。★ 只增不减（第 116 行 assert）。判定见第 107 行 IsFull。",
    "--   本行初值：numslots。",
  ],
  121: [
    "-- 局部变量：local item = slot and self.slots[slot]  〔所在：Container:DropItemBySlot〕",
  ],
  122: [
    "-- 条件分支：if item == nil or item.components.inventoryitem == nil then  〔所在：Container:DropItemBySlot〕",
  ],
  123: [
    "-- 返回：return  〔所在：Container:DropItemBySlot〕",
  ],
  125: [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:DropItemBySlot〕",
  ],
  126: [
    "-- 返回：return  〔所在：Container:DropItemBySlot〕",
  ],
  130: [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DropItemBySlot〕",
  ],
  134: [
    "-- 条件分支：if item.components.inventoryitem ~= nil then  〔所在：Container:DropItemBySlot〕",
  ],
  145: [
    "-- 局部变量：local internal_containers = {}  〔所在：Container:DropEverythingWithTag〕",
  ],
  147: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverythingWithTag〕",
  ],
  148: [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverythingWithTag〕",
  ],
  149: [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DropEverythingWithTag〕",
  ],
  153: [
    "-- table.insert(internal_containers, item)  〔所在：Container:DropEverythingWithTag〕",
  ],
  158: [
    "-- 循环：for i, v in ipairs(internal_containers) do  〔所在：Container:DropEverythingWithTag〕",
  ],
  164: [
    "-- 局部变量：local internal_containers = {}  〔所在：Container:DropEverythingByFilter〕",
  ],
  166: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverythingByFilter〕",
  ],
  167: [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverythingByFilter〕",
  ],
  168: [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DropEverythingByFilter〕",
  ],
  171: [
    "-- 次选条件：elseif item.components.container ~= nil then  〔所在：Container:DropEverythingByFilter〕",
  ],
  172: [
    "-- table.insert(internal_containers, item)  〔所在：Container:DropEverythingByFilter〕",
  ],
  177: [
    "-- 循环：for i, v in ipairs(internal_containers) do  〔所在：Container:DropEverythingByFilter〕",
  ],
  183: [
    "-- 局部变量：local internal_containers  〔所在：Container:DropEverything〕",
  ],
  185: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverything〕",
  ],
  186: [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverything〕",
  ],
  187: [
    "-- 条件分支：if item then  〔所在：Container:DropEverything〕",
  ],
  188: [
    "-- 条件分支：if not item.components.inventoryitem.islockedinslot then  〔所在：Container:DropEverything〕",
  ],
  191: [
    "-- 条件分支：if internal_containers then  〔所在：Container:DropEverything〕",
  ],
  192: [
    "-- table.insert(internal_containers, item)  〔所在：Container:DropEverything〕",
  ],
  193: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:DropEverything〕",
  ],
  194: [
    "-- 局部赋值：internal_containers = { item }  〔所在：Container:DropEverything〕",
  ],
  200: [
    "-- 条件分支：if internal_containers then  〔所在：Container:DropEverything〕",
  ],
  201: [
    "-- 循环：for _, v in ipairs(internal_containers) do  〔所在：Container:DropEverything〕",
  ],
  208: [
    "-- 局部变量：local stacks = 0  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  210: [
    "-- 循环：for k in pairs(self.slots) do  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  212: [
    "-- 局部赋值：stacks = stacks + 1  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  213: [
    "-- 条件分支：if stacks >= maxstacks then  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  214: [
    "-- 返回：return  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  221: [
    "-- 【Container:DropItem】单件丢弃（用自身坐标）。⚠ container_proxy 下坐标恒为 (0,0,0)，见第 222 行注释。",
    "--   ★ 服务端权威实现。客户端镜像在 components/container_replica.lua 同名方法。",
  ],
  224: [
    "-- 局部变量：local x, y, z = self.inst.Transform:GetWorldPosition()  〔所在：Container:DropItem〕",
  ],
  230: [
    "-- 条件分支：if maxsize then  〔所在：Container:DropOverstackedExcess〕",
  ],
  231: [
    "-- 局部变量：local num = item.components.stackable:StackSize()  〔所在：Container:DropOverstackedExcess〕",
  ],
  232: [
    "-- 条件分支：if num > maxsize then  〔所在：Container:DropOverstackedExcess〕",
  ],
  233: [
    "-- 局部变量：local x, y, z = self.inst.Transform:GetWorldPosition()  〔所在：Container:DropOverstackedExcess〕",
  ],
  237: [
    "-- 条件分支：if excess.components.inventoryitem then  〔所在：Container:DropOverstackedExcess〕",
  ],
  240: [
    "-- 局部赋值：num = item.components.stackable:StackSize()  〔所在：Container:DropOverstackedExcess〕",
  ],
  248: [
    "-- 条件分支：if itemtodrop == nil or itemtodrop.components.inventoryitem == nil then  〔所在：Container:DropItemAt〕",
  ],
  249: [
    "-- 返回：return  〔所在：Container:DropItemAt〕",
  ],
  250: [
    "-- 次选条件：elseif itemtodrop.components.inventoryitem.islockedinslot then  〔所在：Container:DropItemAt〕",
  ],
  251: [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:DropItemAt〕",
  ],
  252: [
    "-- 返回：return  〔所在：Container:DropItemAt〕",
  ],
  253: [
    "-- 次选条件：elseif Vector3.is_instance(x) then  〔所在：Container:DropItemAt〕",
  ],
  257: [
    "-- 条件分支：if item then  〔所在：Container:DropItemAt〕",
  ],
  259: [
    "-- 条件分支：if item.components.inventoryitem then  〔所在：Container:DropItemAt〕",
  ],
  264: [
    "-- self.inst:PushEvent(\"dropitem\", {item = item})  〔所在：Container:DropItemAt〕",
  ],
  266: [
    "-- 返回：return item  〔所在：Container:DropItemAt〕",
  ],
  277: [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  279: [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  282: [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  284: [
    "-- 局部变量：local existingitem = self:GetItemInSlot(slot)  〔所在：Container:CanTakeItemInSlot〕",
  ],
  292: [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  299: [
    "-- 条件分支：if self.usespecificslotsforitems and not self.readonlycontainer and self.itemtestfn ~= nil then  〔所在：Container:GetSpecificSlotForItem〕",
  ],
  300: [
    "-- 循环：for i = 1, self:GetNumSlots() do  〔所在：Container:GetSpecificSlotForItem〕",
  ],
  302: [
    "-- 返回：return i  〔所在：Container:GetSpecificSlotForItem〕",
  ],
  309: [
    "-- 条件分支：if not self.priorityfn then  〔所在：Container:ShouldPrioritizeContainer〕",
  ],
  310: [
    "-- 返回：return false  〔所在：Container:ShouldPrioritizeContainer〕",
  ],
  323: [
    "-- 返回：return self.acceptsstacks  〔所在：Container:AcceptsStacks〕",
  ],
  327: [
    "-- 返回：return self.issidewidget  〔所在：Container:IsSideWidget〕",
  ],
  331: [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:DestroyContents〕",
  ],
  332: [
    "-- 局部变量：local item = self:RemoveItemBySlot(k)  〔所在：Container:DestroyContents〕",
  ],
  333: [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DestroyContents〕",
  ],
  345: [
    "-- 条件分支：if filterfn == nil then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  348: [
    "-- 返回：return  〔所在：Container:DestroyContentsConditionally〕",
  ],
  351: [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:DestroyContentsConditionally〕",
  ],
  352: [
    "-- 局部变量：local testitem = self.slots[k]  〔所在：Container:DestroyContentsConditionally〕",
  ],
  354: [
    "-- 局部变量：local item = self:RemoveItemBySlot(k)  〔所在：Container:DestroyContentsConditionally〕",
  ],
  355: [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  356: [
    "-- 条件分支：if onpredestroyitemcallbackfn ~= nil then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  359: [
    "-- 条件分支：if item:IsValid() then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  369: [
    "-- 返回：return true --should never happen, just return true XD  〔所在：ValidateItemForOverflow〕",
  ],
  371: [
    "-- 返回：return false  〔所在：ValidateItemForOverflow〕",
  ],
  373: [
    "-- 返回：return true  〔所在：ValidateItemForOverflow〕",
  ],
  379: [
    "-- 返回：return 0  〔所在：Container:CanAcceptCount〕",
  ],
  384: [
    "-- 局部赋值：stacksize = math.max(maxcount or math.huge, stacksize - 1)  〔所在：Container:CanAcceptCount〕",
  ],
  385: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:CanAcceptCount〕",
  ],
  386: [
    "-- 局部赋值：stacksize = maxcount or stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  389: [
    "-- 返回：return 0  〔所在：Container:CanAcceptCount〕",
  ],
  392: [
    "-- 局部变量：local acceptcount = 0  〔所在：Container:CanAcceptCount〕",
  ],
  395: [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:CanAcceptCount〕",
  ],
  396: [
    "-- 局部变量：local v = self.slots[k]  〔所在：Container:CanAcceptCount〕",
  ],
  398: [
    "-- 条件分支：if v ~= nil then  〔所在：Container:CanAcceptCount〕",
  ],
  400: [
    "-- 局部赋值：acceptcount = acceptcount + v.components.stackable:RoomLeft()  〔所在：Container:CanAcceptCount〕",
  ],
  402: [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  408: [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  410: [
    "-- 局部赋值：acceptcount = acceptcount + 1  〔所在：Container:CanAcceptCount〕",
  ],
  411: [
    "-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕",
  ],
  412: [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  418: [
    "-- 条件分支：if specialized then  〔所在：Container:CanAcceptCount〕",
  ],
  419: [
    "-- 循环：for _, spoverflow in ipairs(specialized) do  〔所在：Container:CanAcceptCount〕",
  ],
  421: [
    "-- 循环：for k = 1, spoverflow.numslots do  〔所在：Container:CanAcceptCount〕",
  ],
  422: [
    "-- 局部变量：local v = spoverflow.slots[k]  〔所在：Container:CanAcceptCount〕",
  ],
  423: [
    "-- 条件分支：if v then  〔所在：Container:CanAcceptCount〕",
  ],
  425: [
    "-- 局部赋值：acceptcount = acceptcount + v.components.stackable:RoomLeft()  〔所在：Container:CanAcceptCount〕",
  ],
  426: [
    "-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕",
  ],
  427: [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  431: [
    "-- 条件分支：if spoverflow.acceptsstacks or stacksize <= 1 then  〔所在：Container:CanAcceptCount〕",
  ],
  432: [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  434: [
    "-- 局部赋值：acceptcount = acceptcount + 1  〔所在：Container:CanAcceptCount〕",
  ],
  435: [
    "-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕",
  ],
  436: [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  449: [
    "-- 返回：return false  〔所在：Container:GiveItem〕",
  ],
  456: [
    "-- 条件分支：if specialized then  〔所在：Container:GiveItem〕",
  ],
  458: [
    "-- 条件分支：if spoverflow:ShouldPrioritizeContainer(item) and ValidateItemForOverflow(item, spoverflow) then  〔所在：Container:GiveItem〕",
  ],
  475: [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  488: [
    "-- 局部变量：local other_item = self.slots[slot]  〔所在：Container:GiveItem〕",
  ],
  495: [
    "-- 条件分支：if item == nil then  〔所在：Container:GiveItem〕",
  ],
  496: [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  504: [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:GiveItem〕",
  ],
  505: [
    "-- 局部变量：local other_item = self.slots[k]  〔所在：Container:GiveItem〕",
  ],
  506: [
    "-- 条件分支：if other_item and item.components.stackable:CanStackWith(other_item) and not other_item.components.stackable:IsFull() then  〔所在：Container:GiveItem〕",
  ],
  507: [
    "-- 条件分支：if self.inst.components.inventoryitem ~= nil and self.inst.components.inventoryitem.owner ~= nil then  〔所在：Container:GiveItem〕",
  ],
  512: [
    "-- 条件分支：if item == nil then  〔所在：Container:GiveItem〕",
  ],
  513: [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  522: [
    "-- 局部赋值：in_slot = slot  〔所在：Container:GiveItem〕",
  ],
  524: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:GiveItem〕",
  ],
  526: [
    "-- 局部赋值：in_slot = i  〔所在：Container:GiveItem〕",
  ],
  535: [
    "-- 局部赋值：item = item.components.stackable:Get()  〔所在：Container:GiveItem〕",
  ],
  538: [
    "-- self.inst:PushEvent(\"itemget\", { slot = in_slot, item = item, src_pos = src_pos, })  〔所在：Container:GiveItem〕",
  ],
  539: [
    "-- 返回：return false  〔所在：Container:GiveItem〕",
  ],
  553: [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  558: [
    "-- 条件分支：if drop_on_fail ~= false then  〔所在：Container:GiveItem〕",
  ],
  562: [
    "-- 条件分支：if item.components.inventoryitem ~= nil then  〔所在：Container:GiveItem〕",
  ],
  570: [
    "-- 局部变量：local item = slot and self.slots[slot] or nil  〔所在：Container:RemoveItemBySlot〕",
  ],
  571: [
    "-- 条件分支：if item then  〔所在：Container:RemoveItemBySlot〕",
  ],
  575: [
    "-- 返回：return nil  〔所在：Container:RemoveItemBySlot〕",
  ],
  579: [
    "-- 局部变量：local collected_items = {}  〔所在：Container:RemoveAllItems〕",
  ],
  580: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:RemoveAllItems〕",
  ],
  581: [
    "-- 局部变量：local item = self:RemoveItemBySlot(i)  〔所在：Container:RemoveAllItems〕",
  ],
  582: [
    "-- table.insert(collected_items, item)  〔所在：Container:RemoveAllItems〕",
  ],
  585: [
    "-- 返回：return collected_items  〔所在：Container:RemoveAllItems〕",
  ],
  589: [
    "-- 返回：return self.numslots  〔所在：Container:GetNumSlots〕",
  ],
  593: [
    "-- 条件分支：if slot and self.slots[slot] then  〔所在：Container:GetItemInSlot〕",
  ],
  594: [
    "-- 返回：return self.slots[slot]  〔所在：Container:GetItemInSlot〕",
  ],
  599: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetItemSlot〕",
  ],
  600: [
    "-- 条件分支：if item == v then  〔所在：Container:GetItemSlot〕",
  ],
  601: [
    "-- 返回：return k  〔所在：Container:GetItemSlot〕",
  ],
  607: [
    "-- 局部变量：local collected_items = {}  〔所在：Container:GetAllItems〕",
  ],
  608: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetAllItems〕",
  ],
  609: [
    "-- 条件分支：if v ~= nil then  〔所在：Container:GetAllItems〕",
  ],
  610: [
    "-- table.insert(collected_items, v)  〔所在：Container:GetAllItems〕",
  ],
  614: [
    "-- 返回：return collected_items  〔所在：Container:GetAllItems〕",
  ],
  623: [
    "-- 条件分支：if inventory ~= nil then  〔所在：Container:Open〕",
  ],
  669: [
    "-- 条件分支：if item.components.container ~= nil then  〔所在：Container:Open〕",
  ],
  677: [
    "-- 循环：for opener, _ in pairs(self.openlist) do  〔所在：Container:Close〕",
  ],
  680: [
    "-- 返回：return  〔所在：Container:Close〕",
  ],
  695: [
    "-- 局部变量：local skinsound = self.inst.AnimState and SKIN_SOUND_FX[self.inst.AnimState:GetSkinBuild()] or nil  〔所在：Container:Close〕",
  ],
  724: [
    "-- 返回：return self.opencount > 0  〔所在：Container:IsOpen〕",
  ],
  728: [
    "-- 返回：return self.openlist[guy]  〔所在：Container:IsOpenedBy〕",
  ],
  732: [
    "-- 返回：return (self.opencount - (self.openlist[guy] and 1 or 0)) > 0  〔所在：Container:IsOpenedByOthers〕",
  ],
  736: [
    "-- 返回：return self.openlimit == nil or self.opencount < self.openlimit  〔所在：Container:CanOpen〕",
  ],
  740: [
    "-- 局部变量：local openers = {}  〔所在：Container:GetOpeners〕",
  ],
  741: [
    "-- 循环：for opener in pairs(self.openlist) do  〔所在：Container:GetOpeners〕",
  ],
  742: [
    "-- table.insert(openers, opener)  〔所在：Container:GetOpeners〕",
  ],
  744: [
    "-- 返回：return openers  〔所在：Container:GetOpeners〕",
  ],
  748: [
    "-- 返回：return target ~= nil  〔所在：CheckItem〕",
  ],
  756: [
    "-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:IsHolding〕",
  ],
  757: [
    "-- 条件分支：if CheckItem(item, v, checkcontainer) then  〔所在：Container:IsHolding〕",
  ],
  758: [
    "-- 返回：return true  〔所在：Container:IsHolding〕",
  ],
  764: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:FindItem〕",
  ],
  765: [
    "-- 条件分支：if fn(v) then  〔所在：Container:FindItem〕",
  ],
  766: [
    "-- 返回：return v  〔所在：Container:FindItem〕",
  ],
  772: [
    "-- 局部变量：local items = {}  〔所在：Container:FindItems〕",
  ],
  774: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:FindItems〕",
  ],
  775: [
    "-- 条件分支：if fn(v) then  〔所在：Container:FindItems〕",
  ],
  776: [
    "-- table.insert(items, v)  〔所在：Container:FindItems〕",
  ],
  780: [
    "-- 返回：return items  〔所在：Container:FindItems〕",
  ],
  784: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:ForEachItem〕",
  ],
  790: [
    "-- 返回：return container ~= nil  〔所在：ValidateSpecializedContainer〕",
  ],
  803: [
    "-- 返回：return  〔所在：Container:GetSpecializedContainers〕",
  ],
  805: [
    "-- 局部变量：local ret  〔所在：Container:GetSpecializedContainers〕",
  ],
  807: [
    "-- 局部变量：local v = self.slots[i]  〔所在：Container:GetSpecializedContainers〕",
  ],
  809: [
    "-- 局部赋值：ret = ret or {}  〔所在：Container:GetSpecializedContainers〕",
  ],
  810: [
    "-- table.insert(ret, v.components.container)  〔所在：Container:GetSpecializedContainers〕",
  ],
  813: [
    "-- 返回：return ret  〔所在：Container:GetSpecializedContainers〕",
  ],
  817: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:IsSpecializedContainer〕",
  ],
  818: [
    "-- 局部变量：local v = self.slots[i]  〔所在：Container:IsSpecializedContainer〕",
  ],
  819: [
    "-- 条件分支：if v and v.components.container == container then  〔所在：Container:IsSpecializedContainer〕",
  ],
  823: [
    "-- 返回：return false  〔所在：Container:IsSpecializedContainer〕",
  ],
  827: [
    "-- 局部变量：local num_found = 0  〔所在：Container:Has〕",
  ],
  828: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:Has〕",
  ],
  830: [
    "-- 条件分支：if v.components.stackable ~= nil then  〔所在：Container:Has〕",
  ],
  831: [
    "-- 局部赋值：num_found = num_found + v.components.stackable:StackSize()  〔所在：Container:Has〕",
  ],
  832: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:Has〕",
  ],
  833: [
    "-- 局部赋值：num_found = num_found + 1  〔所在：Container:Has〕",
  ],
  838: [
    "-- 返回：return num_found >= amount, num_found  〔所在：Container:Has〕",
  ],
  842: [
    "-- 局部变量：local num_found = 0  〔所在：Container:HasItemThatMatches〕",
  ],
  843: [
    "-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:HasItemThatMatches〕",
  ],
  844: [
    "-- 条件分支：if fn(v) then  〔所在：Container:HasItemThatMatches〕",
  ],
  845: [
    "-- 局部赋值：num_found = num_found + (v.components.stackable and v.components.stackable:StackSize() or 1)  〔所在：Container:HasItemThatMatches〕",
  ],
  848: [
    "-- 返回：return num_found >= amount, num_found  〔所在：Container:HasItemThatMatches〕",
  ],
  852: [
    "-- 局部变量：local num_found = 0  〔所在：Container:HasItemWithTag〕",
  ],
  853: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:HasItemWithTag〕",
  ],
  854: [
    "-- 条件分支：if v and v:HasTag(tag) then  〔所在：Container:HasItemWithTag〕",
  ],
  855: [
    "-- 条件分支：if v.components.stackable ~= nil then  〔所在：Container:HasItemWithTag〕",
  ],
  856: [
    "-- 局部赋值：num_found = num_found + v.components.stackable:StackSize()  〔所在：Container:HasItemWithTag〕",
  ],
  857: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:HasItemWithTag〕",
  ],
  858: [
    "-- 局部赋值：num_found = num_found + 1  〔所在：Container:HasItemWithTag〕",
  ],
  863: [
    "-- 返回：return num_found >= amount, num_found  〔所在：Container:HasItemWithTag〕",
  ],
  867: [
    "-- 局部变量：local items = {}  〔所在：Container:GetItemsWithTag〕",
  ],
  868: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetItemsWithTag〕",
  ],
  869: [
    "-- 条件分支：if v and v:HasTag(tag) then  〔所在：Container:GetItemsWithTag〕",
  ],
  870: [
    "-- table.insert(items, v)  〔所在：Container:GetItemsWithTag〕",
  ],
  874: [
    "-- 返回：return items  〔所在：Container:GetItemsWithTag〕",
  ],
  878: [
    "-- 局部变量：local total_num_found = 0  〔所在：Container:GetItemByName〕",
  ],
  879: [
    "-- 局部变量：local items = {}  〔所在：Container:GetItemByName〕",
  ],
  882: [
    "-- 局部变量：local num_found = 0  〔所在：tryfind〕",
  ],
  883: [
    "-- 条件分支：if v and v.prefab == item then  〔所在：tryfind〕",
  ],
  884: [
    "-- 局部变量：local num_left_to_find = amount - total_num_found  〔所在：tryfind〕",
  ],
  885: [
    "-- 条件分支：if v.components.stackable then  〔所在：tryfind〕",
  ],
  888: [
    "-- 局部赋值：num_found = amount  〔所在：tryfind〕",
  ],
  889: [
    "-- 兜底分支（前述条件全不成立）。〔所在：tryfind〕",
  ],
  893: [
    "-- 兜底分支（前述条件全不成立）。〔所在：tryfind〕",
  ],
  895: [
    "-- 局部赋值：num_found = num_found + 1  〔所在：tryfind〕",
  ],
  898: [
    "-- 返回：return num_found  〔所在：tryfind〕",
  ],
  902: [
    "-- 局部变量：local v = self.slots[k]  〔所在：tryfind〕",
  ],
  903: [
    "-- 局部赋值：total_num_found = total_num_found + tryfind(v)  〔所在：tryfind〕",
  ],
  905: [
    "-- 条件分支：if total_num_found >= amount then  〔所在：tryfind〕",
  ],
  910: [
    "-- 返回：return items  〔所在：tryfind〕",
  ],
  914: [
    "-- 条件分支：if a.stacksize == b.stacksize then  〔所在：crafting_priority_fn〕",
  ],
  915: [
    "-- 返回：return a.slot < b.slot  〔所在：crafting_priority_fn〕",
  ],
  921: [
    "-- 局部变量：local items = {}  〔所在：Container:GetCraftingIngredient〕",
  ],
  922: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:GetCraftingIngredient〕",
  ],
  923: [
    "-- 局部变量：local v = self.slots[i]  〔所在：Container:GetCraftingIngredient〕",
  ],
  925: [
    "-- table.insert(items, {  〔所在：Container:GetCraftingIngredient〕",
  ],
  926: [
    "-- 局部赋值：item = v,  〔所在：Container:GetCraftingIngredient〕",
  ],
  927: [
    "-- 局部赋值：stacksize = v.components.stackable and v.components.stackable:StackSize() or 1,  〔所在：Container:GetCraftingIngredient〕",
  ],
  934: [
    "-- 局部变量：local crafting_items = {}  〔所在：Container:GetCraftingIngredient〕",
  ],
  935: [
    "-- 局部变量：local total_num_found = 0  〔所在：Container:GetCraftingIngredient〕",
  ],
  936: [
    "-- 循环：for i, v in ipairs(items) do  〔所在：Container:GetCraftingIngredient〕",
  ],
  937: [
    "-- 局部变量：local stacksize = math.min(v.stacksize, amount - total_num_found)  〔所在：Container:GetCraftingIngredient〕",
  ],
  939: [
    "-- 局部赋值：total_num_found = total_num_found + stacksize  〔所在：Container:GetCraftingIngredient〕",
  ],
  940: [
    "-- 条件分支：if total_num_found >= amount then  〔所在：Container:GetCraftingIngredient〕",
  ],
  945: [
    "-- 返回：return crafting_items  〔所在：Container:GetCraftingIngredient〕",
  ],
  949: [
    "-- 条件分支：if v.components.stackable == nil then  〔所在：tryconsume〕",
  ],
  951: [
    "-- 返回：return 1  〔所在：tryconsume〕",
  ],
  952: [
    "-- 次选条件：elseif v.components.stackable.stacksize > amount then  〔所在：tryconsume〕",
  ],
  954: [
    "-- 返回：return amount  〔所在：tryconsume〕",
  ],
  955: [
    "-- 兜底分支（前述条件全不成立）。〔所在：tryconsume〕",
  ],
  956: [
    "-- 局部赋值：amount = v.components.stackable.stacksize  〔所在：tryconsume〕",
  ],
  958: [
    "-- 返回：return amount  〔所在：tryconsume〕",
  ],
  961: [
    "-- 返回：return 0  〔所在：tryconsume〕",
  ],
  966: [
    "-- 返回：return  〔所在：Container:ConsumeByName〕",
  ],
  969: [
    "-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:ConsumeByName〕",
  ],
  970: [
    "-- 条件分支：if v.prefab == item then  〔所在：Container:ConsumeByName〕",
  ],
  971: [
    "-- 局部赋值：amount = amount - tryconsume(self, v, amount)  〔所在：Container:ConsumeByName〕",
  ],
  972: [
    "-- 条件分支：if amount <= 0 then  〔所在：Container:ConsumeByName〕",
  ],
  973: [
    "-- 返回：return  〔所在：Container:ConsumeByName〕",
  ],
  980: [
    "-- 局部变量：local data = {items= {}}  〔所在：Container:OnSave〕",
  ],
  981: [
    "-- 局部变量：local references = {}  〔所在：Container:OnSave〕",
  ],
  982: [
    "-- 局部变量：local refs  〔所在：Container:OnSave〕",
  ],
  983: [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:OnSave〕",
  ],
  986: [
    "-- 条件分支：if refs then  〔所在：Container:OnSave〕",
  ],
  987: [
    "-- 循环：for k,v in pairs(refs) do  〔所在：Container:OnSave〕",
  ],
  988: [
    "-- table.insert(references, v)  〔所在：Container:OnSave〕",
  ],
  993: [
    "-- 返回：return data, references  〔所在：Container:OnSave〕",
  ],
  997: [
    "-- 条件分支：if data.items then  〔所在：Container:OnLoad〕",
  ],
  998: [
    "-- 循环：for k,v in pairs(data.items) do  〔所在：Container:OnLoad〕",
  ],
  999: [
    "-- 局部变量：local inst = SpawnSaveRecord(v, newents)  〔所在：Container:OnLoad〕",
  ],
  1010: [
    "-- 条件分支：if item then  〔所在：Container:RemoveItem〕",
  ],
  1011: [
    "-- 局部变量：local slot = self:GetItemSlot(item)  〔所在：Container:RemoveItem〕",
  ],
  1012: [
    "-- 条件分支：if slot then  〔所在：Container:RemoveItem〕",
  ],
  1013: [
    "-- 返回：return self:RemoveItem_Internal(item, slot, wholestack, keepoverstacked)  〔所在：Container:RemoveItem〕",
  ],
  1022: [
    "-- 返回：return nil  〔所在：Container:RemoveItem_Internal〕",
  ],
  1025: [
    "-- 局部变量：local stackable = item.components.stackable  〔所在：Container:RemoveItem_Internal〕",
  ],
  1031: [
    "-- 条件分支：if num then  〔所在：Container:RemoveItem_Internal〕",
  ],
  1036: [
    "-- 返回：return dec  〔所在：Container:RemoveItem_Internal〕",
  ],
  1052: [
    "-- 返回：return item  〔所在：Container:RemoveItem_Internal〕",
  ],
  1060: [
    "-- 条件分支：if self.opencount == 0 then  〔所在：Container:OnUpdate〕",
  ],
  1062: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:OnUpdate〕",
  ],
  1068: [
    "-- 局部变量：local ismount = mount == self.inst  〔所在：Container:OnUpdate〕",
  ],
  1095: [
    "-- 局部变量：local inventory = opener ~= nil and opener.components.inventory or nil  〔所在：QueryActiveItem〕",
  ],
  1096: [
    "-- 返回：return inventory, inventory ~= nil and inventory:GetActiveItem() or nil  〔所在：QueryActiveItem〕",
  ],
  1101: [
    "-- 返回：return  〔所在：Container:PutOneOfActiveItemInSlot〕",
  ],
  1103: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:PutOneOfActiveItemInSlot〕",
  ],
  1114: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  1121: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  1122: [
    "-- 返回：return  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  1124: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  1125: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  1126: [
    "-- 条件分支：if active_item ~= nil then  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  1137: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。",
  ],
  1139: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  1147: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  1148: [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  1150: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  1151: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  1153: [
    "-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  1171: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1172: [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1174: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1175: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1176: [
    "-- 条件分支：if item ~= nil and  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1177: [
    "-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1180: [
    "-- 局部变量：local stackable = item.components.stackable  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1184: [
    "-- 局部变量：local countedstack = stackable:Get(count)  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1189: [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1190: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  1200: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1201: [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1203: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1204: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1205: [
    "-- 条件分支：if item ~= nil and  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1206: [
    "-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1210: [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1211: [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1217: [
    "-- 局部变量：local fullstack = item.components.stackable:Get(item.components.stackable.originalmaxsize)  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1221: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  1231: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  1232: [
    "-- 返回：return  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  1234: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  1235: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  1255: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  1256: [
    "-- 返回：return  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  1258: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  1259: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  1277: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  1278: [
    "-- 返回：return  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  1280: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  1281: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  1282: [
    "-- 条件分支：if active_item ~= nil then  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  1283: [
    "-- 条件分支：if item == nil then  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  1308: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  1309: [
    "-- 返回：return  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  1311: [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  1312: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  1334: [
    "-- 返回：return  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1337: [
    "-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1339: [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1340: [
    "-- 返回：return  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1355: [
    "-- 局部变量：local shouldignoresound = false  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1357: [
    "-- 局部赋值：item = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1358: [
    "-- 次选条件：elseif container.infinitestacksize then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1360: [
    "-- ★ hack flag：取出超量堆叠时**不**把多出的丢地上（第 1042 行）。",
    "--   本行初值：true。",
  ],
  1361: [
    "-- 局部赋值：item = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1362: [
    "-- ignoreoverstacked：同第 1360 行（首次初始化），此处显式赋 false。",
  ],
  1363: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1367: [
    "-- 条件分支：if item ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1377: [
    "-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1380: [
    "-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1387: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  1394: [
    "-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1397: [
    "-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1400: [
    "-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  1413: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1414: [
    "-- 返回：return  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1416: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1417: [
    "-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1418: [
    "-- 局部赋值：container = container.components.container or container.components.inventory  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1419: [
    "-- 条件分支：if container ~= nil and  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1427: [
    "-- 局部变量：local targetslot =  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1433: [
    "-- 条件分支：if container:CanTakeItemInSlot(item, targetslot) then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1435: [
    "-- 局部变量：local halfstack = item.components.stackable:Get(math.floor(fullstacksize / 2))  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1440: [
    "-- 条件分支：if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1443: [
    "-- 条件分支：if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1445: [
    "-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1448: [
    "-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1453: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。",
  ],
  1455: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  1459: [
    "-- 条件分支：if container.ignoreoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1462: [
    "-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1465: [
    "-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1468: [
    "-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  1480: [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1483: [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1484: [
    "-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1485: [
    "-- 局部赋值：container = container.components.container or container.components.inventory  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1486: [
    "-- 条件分支：if container ~= nil and container:IsOpenedBy(opener) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1491: [
    "-- 局部变量：local targetslot =  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1497: [
    "-- 条件分支：if container:CanTakeItemInSlot(item, targetslot) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1498: [
    "-- 局部变量：local stackable = item.components.stackable  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1499: [
    "-- 局部变量：local fullstacksize = stackable and (stackable:IsOverStacked() and stackable.originalmaxsize or stackable:StackSize()) or 1  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1500: [
    "-- 局部赋值：count = math.clamp(count, 1, fullstacksize)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1501: [
    "-- 局部变量：local countedstack  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1503: [
    "-- 局部赋值：countedstack = stackable:Get(count)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1505: [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1506: [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1507: [
    "-- 局部赋值：countedstack = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1515: [
    "-- 条件分支：if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1518: [
    "-- 条件分支：if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1520: [
    "-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1523: [
    "-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1527: [
    "-- 条件分支：if not container:GiveItem(countedstack, targetslot) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1528: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。",
  ],
  1530: [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  1534: [
    "-- 条件分支：if container.ignoreoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1537: [
    "-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1540: [
    "-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1543: [
    "-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  1556: [
    "-- 局部变量：local items = {}  〔所在：Container:ReferenceAllItems〕",
  ],
  1557: [
    "-- 循环：for i=1,self.numslots do  〔所在：Container:ReferenceAllItems〕",
  ],
  1558: [
    "-- 条件分支：if self.slots[i] ~= nil then  〔所在：Container:ReferenceAllItems〕",
  ],
  1559: [
    "-- table.insert(items, self.slots[i])  〔所在：Container:ReferenceAllItems〕",
  ],
  1562: [
    "-- 返回：return items  〔所在：Container:ReferenceAllItems〕",
  ],
  1566: [
    "-- 局部变量：local _ = rawget(self, \"_\") --see class.lua for property setters implementation  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1567: [
    "-- 条件分支：if enable then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1568: [
    "-- 条件分支：if not _.infinitestacksize[1] then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1570: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1571: [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1572: [
    "-- 条件分支：if item and item.components.stackable then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1581: [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1582: [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1583: [
    "-- 条件分支：if item and item.components.stackable then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  1594: [
    "-- dumptable(data)  〔所在：ReadOnlyContainerAssert_in〕",
  ],
  1595: [
    "-- print(\"Time to assert, please report this.\")  〔所在：ReadOnlyContainerAssert_in〕",
  ],
  1600: [
    "-- print(\"__ DATA __\")  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  1601: [
    "-- dumptable(data)  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  1602: [
    "-- print(\"Time to assert, please report this.\")  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  1603: [
    "-- assert(false, string.format(\"VERY BAD! Item %s was transferred out of a read only container.\", tostring(item)))  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  1607: [
    "-- 局部变量：local _ = rawget(self, \"_\") --see class.lua for property setters implementation  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  1608: [
    "-- 条件分支：if enable then  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  1609: [
    "-- 条件分支：if not _.readonlycontainer[1] then  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  1628: [
    "-- 条件分支：if self.inst.components.preserver then  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  1637: [
    "-- 条件分支：if not target:HasTag(\"player\") then  〔所在：Container:IsRestricted〕",
  ],
  1639: [
    "-- 返回：return false  〔所在：Container:IsRestricted〕",
  ],
  1648: [
    "-- 返回：return self.thiefproof  〔所在：Container:IsThiefProof〕",
  ],
  1651: [
    "-- 返回：return Container  〔所在：Container:IsThiefProof〕",
  ],
};

export const AFTER = {};
