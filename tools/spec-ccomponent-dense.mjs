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
  "OnOwnerDespawned#1+1": [
    "-- 局部变量：local container = inst.components.container  〔所在：OnOwnerDespawned〕",
  ],
  "OnOwnerDespawned#1+2": [
    "-- 条件分支：if container ~= nil then  〔所在：OnOwnerDespawned〕",
  ],
  "OnOwnerDespawned#1+4": [
    "-- 局部变量：local item = container.slots[i]  〔所在：OnOwnerDespawned〕",
  ],
  "OnOwnerDespawned#1+5": [
    "-- 条件分支：if item ~= nil then  〔所在：OnOwnerDespawned〕",
  ],
  "OnOwnerDespawned#1+17": [
    "-- ★ 关掉客户端开箱音效。★ 由容器组件设、由客户端读（container_replica.lua:289）。",
    "--   本行初值：false。",
  ],
  "OnOwnerDespawned#1+18": [
    "-- ★ 关掉客户端关箱音效（同上，container_replica.lua:293）。",
    "--   本行初值：false。",
  ],
  "OnOwnerDespawned#1+20": [
    "-- ★ 是否接受整摞物品。默认 true；蓝图可覆盖（containers.lua 有 20+ 处 false）。",
    "--   本行初值：true。",
  ],
  "OnOwnerDespawned#1+26": [
    "-- ★ 蓝图里的 UI 配置表。★ 浅拷贝共享：多个同类容器的 self.widget 是同一张表。",
    "--   本行初值：nil。",
  ],
  "OnOwnerDespawned#1+46": [
    "-- ★ hack flag：禁用 GetSpecializedContainers（第 802 行）。设置于第 1375 行。",
    "--   本行初值：false。",
  ],
  "OnOwnerDespawned#1+47": [
    "-- ★ hack flag：允许往**未打开**的专用容器塞物（第 793 行）。设置于第 1378 行。",
    "--   本行初值：false。",
  ],
  "OnOwnerDespawned#1+48": [
    "-- ★ hack flag：塞物时不播 gotnewitem 音效（第 549 行）。搬运事务期间的临时静音。",
    "--   本行初值：false。",
  ],
  "OnOwnerDespawned#1+53": [
    "-- 局部赋值：canbeopened = oncanbeopened,  〔所在：OnOwnerDespawned〕",
  ],
  "OnOwnerDespawned#1+54": [
    "-- 局部赋值：skipopensnd = onskipopensnd,  〔所在：OnOwnerDespawned〕",
  ],
  "OnOwnerDespawned#1+55": [
    "-- 局部赋值：skipclosesnd = onskipclosesnd,  〔所在：OnOwnerDespawned〕",
  ],
  "OnOwnerDespawned#1+60": [
    "-- 白名单成员「numslots」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+61": [
    "-- 白名单成员「acceptsstacks」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+62": [
    "-- 白名单成员「usespecificslotsforitems」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+63": [
    "-- 白名单成员「issidewidget」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+64": [
    "-- 白名单成员「type」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+65": [
    "-- 白名单成员「widget」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+66": [
    "-- 白名单成员「itemtestfn」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+67": [
    "-- 白名单成员「priorityfn」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "OnOwnerDespawned#1+68": [
    "-- 白名单成员「openlimit」：★ WidgetSetup 会对它 removesetter + makereadonly。",
  ],
  "Container:WidgetSetup#1+1": [
    "-- 循环：for i, v in ipairs(widgetprops) do  〔所在：Container:WidgetSetup〕",
  ],
  "Container:WidgetSetup#1+8": [
    "-- 循环：for i, v in ipairs(widgetprops) do  〔所在：Container:WidgetSetup〕",
  ],
  "Container:GetWidget#1+1": [
    "-- 返回：return self.widget  〔所在：Container:GetWidget〕",
  ],
  "Container:NumItems#1+1": [
    "-- 返回：return GetTableSize(self.slots)  〔所在：Container:NumItems〕",
  ],
  "Container:IsFull#1+1": [
    "-- 返回：return GetTableSize(self.slots) >= self.numslots  〔所在：Container:IsFull〕",
  ],
  "Container:IsEmpty#1+1": [
    "-- 返回：return next(self.slots) == nil  〔所在：Container:IsEmpty〕",
  ],
  "Container:SetNumSlots#1+1": [
    "-- assert(numslots >= self.numslots)  〔所在：Container:SetNumSlots〕",
  ],
  "Container:SetNumSlots#1+2": [
    "-- 槽位总数。★ 只增不减（第 116 行 assert）。判定见第 107 行 IsFull。",
    "--   本行初值：numslots。",
  ],
  "Container:DropItemBySlot#1+1": [
    "-- 局部变量：local item = slot and self.slots[slot]  〔所在：Container:DropItemBySlot〕",
  ],
  "Container:DropItemBySlot#1+2": [
    "-- 条件分支：if item == nil or item.components.inventoryitem == nil then  〔所在：Container:DropItemBySlot〕",
  ],
  "Container:DropItemBySlot#1+3": [
    "-- 返回：return  〔所在：Container:DropItemBySlot〕",
  ],
  "Container:DropItemBySlot#1+5": [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:DropItemBySlot〕",
  ],
  "Container:DropItemBySlot#1+6": [
    "-- 返回：return  〔所在：Container:DropItemBySlot〕",
  ],
  "Container:DropItemBySlot#1+10": [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DropItemBySlot〕",
  ],
  "Container:DropItemBySlot#1+14": [
    "-- 条件分支：if item.components.inventoryitem ~= nil then  〔所在：Container:DropItemBySlot〕",
  ],
  "Container:DropEverythingWithTag#1+1": [
    "-- 局部变量：local internal_containers = {}  〔所在：Container:DropEverythingWithTag〕",
  ],
  "Container:DropEverythingWithTag#1+3": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverythingWithTag〕",
  ],
  "Container:DropEverythingWithTag#1+4": [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverythingWithTag〕",
  ],
  "Container:DropEverythingWithTag#1+5": [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DropEverythingWithTag〕",
  ],
  "Container:DropEverythingWithTag#1+9": [
    "-- table.insert(internal_containers, item)  〔所在：Container:DropEverythingWithTag〕",
  ],
  "Container:DropEverythingWithTag#1+14": [
    "-- 循环：for i, v in ipairs(internal_containers) do  〔所在：Container:DropEverythingWithTag〕",
  ],
  "Container:DropEverythingByFilter#1+1": [
    "-- 局部变量：local internal_containers = {}  〔所在：Container:DropEverythingByFilter〕",
  ],
  "Container:DropEverythingByFilter#1+3": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverythingByFilter〕",
  ],
  "Container:DropEverythingByFilter#1+4": [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverythingByFilter〕",
  ],
  "Container:DropEverythingByFilter#1+5": [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DropEverythingByFilter〕",
  ],
  "Container:DropEverythingByFilter#1+8": [
    "-- 次选条件：elseif item.components.container ~= nil then  〔所在：Container:DropEverythingByFilter〕",
  ],
  "Container:DropEverythingByFilter#1+9": [
    "-- table.insert(internal_containers, item)  〔所在：Container:DropEverythingByFilter〕",
  ],
  "Container:DropEverythingByFilter#1+14": [
    "-- 循环：for i, v in ipairs(internal_containers) do  〔所在：Container:DropEverythingByFilter〕",
  ],
  "Container:DropEverything#1+1": [
    "-- 局部变量：local internal_containers  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+3": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+4": [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+5": [
    "-- 条件分支：if item then  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+6": [
    "-- 条件分支：if not item.components.inventoryitem.islockedinslot then  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+9": [
    "-- 条件分支：if internal_containers then  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+10": [
    "-- table.insert(internal_containers, item)  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+11": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+12": [
    "-- 局部赋值：internal_containers = { item }  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+18": [
    "-- 条件分支：if internal_containers then  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverything#1+19": [
    "-- 循环：for _, v in ipairs(internal_containers) do  〔所在：Container:DropEverything〕",
  ],
  "Container:DropEverythingUpToMaxStacks#1+1": [
    "-- 局部变量：local stacks = 0  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  "Container:DropEverythingUpToMaxStacks#1+3": [
    "-- 循环：for k in pairs(self.slots) do  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  "Container:DropEverythingUpToMaxStacks#1+5": [
    "-- 局部赋值：stacks = stacks + 1  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  "Container:DropEverythingUpToMaxStacks#1+6": [
    "-- 条件分支：if stacks >= maxstacks then  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  "Container:DropEverythingUpToMaxStacks#1+7": [
    "-- 返回：return  〔所在：Container:DropEverythingUpToMaxStacks〕",
  ],
  "Container:DropItem#1": [
    "-- 【Container:DropItem】单件丢弃（用自身坐标）。⚠ container_proxy 下坐标恒为 (0,0,0)，见第 222 行注释。",
    "--   ★ 服务端权威实现。客户端镜像在 components/container_replica.lua 同名方法。",
  ],
  "Container:DropItem#1+3": [
    "-- 局部变量：local x, y, z = self.inst.Transform:GetWorldPosition()  〔所在：Container:DropItem〕",
  ],
  "Container:DropOverstackedExcess#1+2": [
    "-- 条件分支：if maxsize then  〔所在：Container:DropOverstackedExcess〕",
  ],
  "Container:DropOverstackedExcess#1+3": [
    "-- 局部变量：local num = item.components.stackable:StackSize()  〔所在：Container:DropOverstackedExcess〕",
  ],
  "Container:DropOverstackedExcess#1+4": [
    "-- 条件分支：if num > maxsize then  〔所在：Container:DropOverstackedExcess〕",
  ],
  "Container:DropOverstackedExcess#1+5": [
    "-- 局部变量：local x, y, z = self.inst.Transform:GetWorldPosition()  〔所在：Container:DropOverstackedExcess〕",
  ],
  "Container:DropOverstackedExcess#1+9": [
    "-- 条件分支：if excess.components.inventoryitem then  〔所在：Container:DropOverstackedExcess〕",
  ],
  "Container:DropOverstackedExcess#1+12": [
    "-- 局部赋值：num = item.components.stackable:StackSize()  〔所在：Container:DropOverstackedExcess〕",
  ],
  "Container:DropItemAt#1+1": [
    "-- 条件分支：if itemtodrop == nil or itemtodrop.components.inventoryitem == nil then  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+2": [
    "-- 返回：return  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+3": [
    "-- 次选条件：elseif itemtodrop.components.inventoryitem.islockedinslot then  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+4": [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+5": [
    "-- 返回：return  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+6": [
    "-- 次选条件：elseif Vector3.is_instance(x) then  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+10": [
    "-- 条件分支：if item then  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+12": [
    "-- 条件分支：if item.components.inventoryitem then  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+17": [
    "-- self.inst:PushEvent(\"dropitem\", {item = item})  〔所在：Container:DropItemAt〕",
  ],
  "Container:DropItemAt#1+19": [
    "-- 返回：return item  〔所在：Container:DropItemAt〕",
  ],
  "Container:CanTakeItemInSlot#1+8": [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  "Container:CanTakeItemInSlot#1+10": [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  "Container:CanTakeItemInSlot#1+13": [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  "Container:CanTakeItemInSlot#1+15": [
    "-- 局部变量：local existingitem = self:GetItemInSlot(slot)  〔所在：Container:CanTakeItemInSlot〕",
  ],
  "Container:CanTakeItemInSlot#1+23": [
    "-- 返回：return false  〔所在：Container:CanTakeItemInSlot〕",
  ],
  "Container:GetSpecificSlotForItem#1+1": [
    "-- 条件分支：if self.usespecificslotsforitems and not self.readonlycontainer and self.itemtestfn ~= nil then  〔所在：Container:GetSpecificSlotForItem〕",
  ],
  "Container:GetSpecificSlotForItem#1+2": [
    "-- 循环：for i = 1, self:GetNumSlots() do  〔所在：Container:GetSpecificSlotForItem〕",
  ],
  "Container:GetSpecificSlotForItem#1+4": [
    "-- 返回：return i  〔所在：Container:GetSpecificSlotForItem〕",
  ],
  "Container:ShouldPrioritizeContainer#1+1": [
    "-- 条件分支：if not self.priorityfn then  〔所在：Container:ShouldPrioritizeContainer〕",
  ],
  "Container:ShouldPrioritizeContainer#1+2": [
    "-- 返回：return false  〔所在：Container:ShouldPrioritizeContainer〕",
  ],
  "Container:AcceptsStacks#1+1": [
    "-- 返回：return self.acceptsstacks  〔所在：Container:AcceptsStacks〕",
  ],
  "Container:IsSideWidget#1+1": [
    "-- 返回：return self.issidewidget  〔所在：Container:IsSideWidget〕",
  ],
  "Container:DestroyContents#1+1": [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:DestroyContents〕",
  ],
  "Container:DestroyContents#1+2": [
    "-- 局部变量：local item = self:RemoveItemBySlot(k)  〔所在：Container:DestroyContents〕",
  ],
  "Container:DestroyContents#1+3": [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DestroyContents〕",
  ],
  "Container:DestroyContentsConditionally#1+1": [
    "-- 条件分支：if filterfn == nil then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "Container:DestroyContentsConditionally#1+4": [
    "-- 返回：return  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "Container:DestroyContentsConditionally#1+7": [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "Container:DestroyContentsConditionally#1+8": [
    "-- 局部变量：local testitem = self.slots[k]  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "Container:DestroyContentsConditionally#1+10": [
    "-- 局部变量：local item = self:RemoveItemBySlot(k)  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "Container:DestroyContentsConditionally#1+11": [
    "-- 条件分支：if item ~= nil then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "Container:DestroyContentsConditionally#1+12": [
    "-- 条件分支：if onpredestroyitemcallbackfn ~= nil then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "Container:DestroyContentsConditionally#1+15": [
    "-- 条件分支：if item:IsValid() then  〔所在：Container:DestroyContentsConditionally〕",
  ],
  "ValidateItemForOverflow#1+2": [
    "-- 返回：return true --should never happen, just return true XD  〔所在：ValidateItemForOverflow〕",
  ],
  "ValidateItemForOverflow#1+4": [
    "-- 返回：return false  〔所在：ValidateItemForOverflow〕",
  ],
  "ValidateItemForOverflow#1+6": [
    "-- 返回：return true  〔所在：ValidateItemForOverflow〕",
  ],
  "Container:CanAcceptCount#1+2": [
    "-- 返回：return 0  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+7": [
    "-- 局部赋值：stacksize = math.max(maxcount or math.huge, stacksize - 1)  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+8": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+9": [
    "-- 局部赋值：stacksize = maxcount or stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+12": [
    "-- 返回：return 0  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+15": [
    "-- 局部变量：local acceptcount = 0  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+18": [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+19": [
    "-- 局部变量：local v = self.slots[k]  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+21": [
    "-- 条件分支：if v ~= nil then  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+23": [
    "-- 局部赋值：acceptcount = acceptcount + v.components.stackable:RoomLeft()  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+25": [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+31": [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+33": [
    "-- 局部赋值：acceptcount = acceptcount + 1  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+34": [
    "-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+35": [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+41": [
    "-- 条件分支：if specialized then  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+42": [
    "-- 循环：for _, spoverflow in ipairs(specialized) do  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+44": [
    "-- 循环：for k = 1, spoverflow.numslots do  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+45": [
    "-- 局部变量：local v = spoverflow.slots[k]  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+46": [
    "-- 条件分支：if v then  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+48": [
    "-- 局部赋值：acceptcount = acceptcount + v.components.stackable:RoomLeft()  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+49": [
    "-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+50": [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+54": [
    "-- 条件分支：if spoverflow.acceptsstacks or stacksize <= 1 then  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+55": [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+57": [
    "-- 局部赋值：acceptcount = acceptcount + 1  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+58": [
    "-- 条件分支：if acceptcount >= stacksize then  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:CanAcceptCount#1+59": [
    "-- 返回：return stacksize  〔所在：Container:CanAcceptCount〕",
  ],
  "Container:GiveItem#1+2": [
    "-- 返回：return false  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+9": [
    "-- 条件分支：if specialized then  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+11": [
    "-- 条件分支：if spoverflow:ShouldPrioritizeContainer(item) and ValidateItemForOverflow(item, spoverflow) then  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+28": [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+41": [
    "-- 局部变量：local other_item = self.slots[slot]  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+48": [
    "-- 条件分支：if item == nil then  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+49": [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+57": [
    "-- 循环：for k = 1, self.numslots do  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+58": [
    "-- 局部变量：local other_item = self.slots[k]  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+59": [
    "-- 条件分支：if other_item and item.components.stackable:CanStackWith(other_item) and not other_item.components.stackable:IsFull() then  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+60": [
    "-- 条件分支：if self.inst.components.inventoryitem ~= nil and self.inst.components.inventoryitem.owner ~= nil then  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+65": [
    "-- 条件分支：if item == nil then  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+66": [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+75": [
    "-- 局部赋值：in_slot = slot  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+77": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+79": [
    "-- 局部赋值：in_slot = i  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+88": [
    "-- 局部赋值：item = item.components.stackable:Get()  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+91": [
    "-- self.inst:PushEvent(\"itemget\", { slot = in_slot, item = item, src_pos = src_pos, })  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+92": [
    "-- 返回：return false  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+106": [
    "-- 返回：return true  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+111": [
    "-- 条件分支：if drop_on_fail ~= false then  〔所在：Container:GiveItem〕",
  ],
  "Container:GiveItem#1+115": [
    "-- 条件分支：if item.components.inventoryitem ~= nil then  〔所在：Container:GiveItem〕",
  ],
  "Container:RemoveItemBySlot#1+1": [
    "-- 局部变量：local item = slot and self.slots[slot] or nil  〔所在：Container:RemoveItemBySlot〕",
  ],
  "Container:RemoveItemBySlot#1+2": [
    "-- 条件分支：if item then  〔所在：Container:RemoveItemBySlot〕",
  ],
  "Container:RemoveItemBySlot#1+6": [
    "-- 返回：return nil  〔所在：Container:RemoveItemBySlot〕",
  ],
  "Container:RemoveAllItems#1+1": [
    "-- 局部变量：local collected_items = {}  〔所在：Container:RemoveAllItems〕",
  ],
  "Container:RemoveAllItems#1+2": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:RemoveAllItems〕",
  ],
  "Container:RemoveAllItems#1+3": [
    "-- 局部变量：local item = self:RemoveItemBySlot(i)  〔所在：Container:RemoveAllItems〕",
  ],
  "Container:RemoveAllItems#1+4": [
    "-- table.insert(collected_items, item)  〔所在：Container:RemoveAllItems〕",
  ],
  "Container:RemoveAllItems#1+7": [
    "-- 返回：return collected_items  〔所在：Container:RemoveAllItems〕",
  ],
  "Container:GetNumSlots#1+1": [
    "-- 返回：return self.numslots  〔所在：Container:GetNumSlots〕",
  ],
  "Container:GetItemInSlot#1+1": [
    "-- 条件分支：if slot and self.slots[slot] then  〔所在：Container:GetItemInSlot〕",
  ],
  "Container:GetItemInSlot#1+2": [
    "-- 返回：return self.slots[slot]  〔所在：Container:GetItemInSlot〕",
  ],
  "Container:GetItemSlot#1+1": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetItemSlot〕",
  ],
  "Container:GetItemSlot#1+2": [
    "-- 条件分支：if item == v then  〔所在：Container:GetItemSlot〕",
  ],
  "Container:GetItemSlot#1+3": [
    "-- 返回：return k  〔所在：Container:GetItemSlot〕",
  ],
  "Container:GetAllItems#1+1": [
    "-- 局部变量：local collected_items = {}  〔所在：Container:GetAllItems〕",
  ],
  "Container:GetAllItems#1+2": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetAllItems〕",
  ],
  "Container:GetAllItems#1+3": [
    "-- 条件分支：if v ~= nil then  〔所在：Container:GetAllItems〕",
  ],
  "Container:GetAllItems#1+4": [
    "-- table.insert(collected_items, v)  〔所在：Container:GetAllItems〕",
  ],
  "Container:GetAllItems#1+8": [
    "-- 返回：return collected_items  〔所在：Container:GetAllItems〕",
  ],
  "Container:Open#1+6": [
    "-- 条件分支：if inventory ~= nil then  〔所在：Container:Open〕",
  ],
  "Container.Close_Items_Internal#1+1": [
    "-- 条件分支：if item.components.container ~= nil then  〔所在：Container:Open〕",
  ],
  "Container:Close#1+3": [
    "-- 循环：for opener, _ in pairs(self.openlist) do  〔所在：Container:Close〕",
  ],
  "Container:Close#1+6": [
    "-- 返回：return  〔所在：Container:Close〕",
  ],
  "Container:Close#1+21": [
    "-- 局部变量：local skinsound = self.inst.AnimState and SKIN_SOUND_FX[self.inst.AnimState:GetSkinBuild()] or nil  〔所在：Container:Close〕",
  ],
  "Container:IsOpen#1+1": [
    "-- 返回：return self.opencount > 0  〔所在：Container:IsOpen〕",
  ],
  "Container:IsOpenedBy#1+1": [
    "-- 返回：return self.openlist[guy]  〔所在：Container:IsOpenedBy〕",
  ],
  "Container:IsOpenedByOthers#1+1": [
    "-- 返回：return (self.opencount - (self.openlist[guy] and 1 or 0)) > 0  〔所在：Container:IsOpenedByOthers〕",
  ],
  "Container:CanOpen#1+1": [
    "-- 返回：return self.openlimit == nil or self.opencount < self.openlimit  〔所在：Container:CanOpen〕",
  ],
  "Container:GetOpeners#1+1": [
    "-- 局部变量：local openers = {}  〔所在：Container:GetOpeners〕",
  ],
  "Container:GetOpeners#1+2": [
    "-- 循环：for opener in pairs(self.openlist) do  〔所在：Container:GetOpeners〕",
  ],
  "Container:GetOpeners#1+3": [
    "-- table.insert(openers, opener)  〔所在：Container:GetOpeners〕",
  ],
  "Container:GetOpeners#1+5": [
    "-- 返回：return openers  〔所在：Container:GetOpeners〕",
  ],
  "CheckItem#1+1": [
    "-- 返回：return target ~= nil  〔所在：CheckItem〕",
  ],
  "Container:IsHolding#1+1": [
    "-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:IsHolding〕",
  ],
  "Container:IsHolding#1+2": [
    "-- 条件分支：if CheckItem(item, v, checkcontainer) then  〔所在：Container:IsHolding〕",
  ],
  "Container:IsHolding#1+3": [
    "-- 返回：return true  〔所在：Container:IsHolding〕",
  ],
  "Container:FindItem#1+1": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:FindItem〕",
  ],
  "Container:FindItem#1+2": [
    "-- 条件分支：if fn(v) then  〔所在：Container:FindItem〕",
  ],
  "Container:FindItem#1+3": [
    "-- 返回：return v  〔所在：Container:FindItem〕",
  ],
  "Container:FindItems#1+1": [
    "-- 局部变量：local items = {}  〔所在：Container:FindItems〕",
  ],
  "Container:FindItems#1+3": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:FindItems〕",
  ],
  "Container:FindItems#1+4": [
    "-- 条件分支：if fn(v) then  〔所在：Container:FindItems〕",
  ],
  "Container:FindItems#1+5": [
    "-- table.insert(items, v)  〔所在：Container:FindItems〕",
  ],
  "Container:FindItems#1+9": [
    "-- 返回：return items  〔所在：Container:FindItems〕",
  ],
  "Container:ForEachItem#1+1": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:ForEachItem〕",
  ],
  "ValidateSpecializedContainer#1+1": [
    "-- 返回：return container ~= nil  〔所在：ValidateSpecializedContainer〕",
  ],
  "Container:GetSpecializedContainers#1+2": [
    "-- 返回：return  〔所在：Container:GetSpecializedContainers〕",
  ],
  "Container:GetSpecializedContainers#1+4": [
    "-- 局部变量：local ret  〔所在：Container:GetSpecializedContainers〕",
  ],
  "Container:GetSpecializedContainers#1+6": [
    "-- 局部变量：local v = self.slots[i]  〔所在：Container:GetSpecializedContainers〕",
  ],
  "Container:GetSpecializedContainers#1+8": [
    "-- 局部赋值：ret = ret or {}  〔所在：Container:GetSpecializedContainers〕",
  ],
  "Container:GetSpecializedContainers#1+9": [
    "-- table.insert(ret, v.components.container)  〔所在：Container:GetSpecializedContainers〕",
  ],
  "Container:GetSpecializedContainers#1+12": [
    "-- 返回：return ret  〔所在：Container:GetSpecializedContainers〕",
  ],
  "Container:IsSpecializedContainer#1+1": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:IsSpecializedContainer〕",
  ],
  "Container:IsSpecializedContainer#1+2": [
    "-- 局部变量：local v = self.slots[i]  〔所在：Container:IsSpecializedContainer〕",
  ],
  "Container:IsSpecializedContainer#1+3": [
    "-- 条件分支：if v and v.components.container == container then  〔所在：Container:IsSpecializedContainer〕",
  ],
  "Container:IsSpecializedContainer#1+7": [
    "-- 返回：return false  〔所在：Container:IsSpecializedContainer〕",
  ],
  "Container:Has#1+1": [
    "-- 局部变量：local num_found = 0  〔所在：Container:Has〕",
  ],
  "Container:Has#1+2": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:Has〕",
  ],
  "Container:Has#1+4": [
    "-- 条件分支：if v.components.stackable ~= nil then  〔所在：Container:Has〕",
  ],
  "Container:Has#1+5": [
    "-- 局部赋值：num_found = num_found + v.components.stackable:StackSize()  〔所在：Container:Has〕",
  ],
  "Container:Has#1+6": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:Has〕",
  ],
  "Container:Has#1+7": [
    "-- 局部赋值：num_found = num_found + 1  〔所在：Container:Has〕",
  ],
  "Container:Has#1+12": [
    "-- 返回：return num_found >= amount, num_found  〔所在：Container:Has〕",
  ],
  "Container:HasItemThatMatches#1+1": [
    "-- 局部变量：local num_found = 0  〔所在：Container:HasItemThatMatches〕",
  ],
  "Container:HasItemThatMatches#1+2": [
    "-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:HasItemThatMatches〕",
  ],
  "Container:HasItemThatMatches#1+3": [
    "-- 条件分支：if fn(v) then  〔所在：Container:HasItemThatMatches〕",
  ],
  "Container:HasItemThatMatches#1+4": [
    "-- 局部赋值：num_found = num_found + (v.components.stackable and v.components.stackable:StackSize() or 1)  〔所在：Container:HasItemThatMatches〕",
  ],
  "Container:HasItemThatMatches#1+7": [
    "-- 返回：return num_found >= amount, num_found  〔所在：Container:HasItemThatMatches〕",
  ],
  "Container:HasItemWithTag#1+1": [
    "-- 局部变量：local num_found = 0  〔所在：Container:HasItemWithTag〕",
  ],
  "Container:HasItemWithTag#1+2": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:HasItemWithTag〕",
  ],
  "Container:HasItemWithTag#1+3": [
    "-- 条件分支：if v and v:HasTag(tag) then  〔所在：Container:HasItemWithTag〕",
  ],
  "Container:HasItemWithTag#1+4": [
    "-- 条件分支：if v.components.stackable ~= nil then  〔所在：Container:HasItemWithTag〕",
  ],
  "Container:HasItemWithTag#1+5": [
    "-- 局部赋值：num_found = num_found + v.components.stackable:StackSize()  〔所在：Container:HasItemWithTag〕",
  ],
  "Container:HasItemWithTag#1+6": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:HasItemWithTag〕",
  ],
  "Container:HasItemWithTag#1+7": [
    "-- 局部赋值：num_found = num_found + 1  〔所在：Container:HasItemWithTag〕",
  ],
  "Container:HasItemWithTag#1+12": [
    "-- 返回：return num_found >= amount, num_found  〔所在：Container:HasItemWithTag〕",
  ],
  "Container:GetItemsWithTag#1+1": [
    "-- 局部变量：local items = {}  〔所在：Container:GetItemsWithTag〕",
  ],
  "Container:GetItemsWithTag#1+2": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:GetItemsWithTag〕",
  ],
  "Container:GetItemsWithTag#1+3": [
    "-- 条件分支：if v and v:HasTag(tag) then  〔所在：Container:GetItemsWithTag〕",
  ],
  "Container:GetItemsWithTag#1+4": [
    "-- table.insert(items, v)  〔所在：Container:GetItemsWithTag〕",
  ],
  "Container:GetItemsWithTag#1+8": [
    "-- 返回：return items  〔所在：Container:GetItemsWithTag〕",
  ],
  "Container:GetItemByName#1+1": [
    "-- 局部变量：local total_num_found = 0  〔所在：Container:GetItemByName〕",
  ],
  "Container:GetItemByName#1+2": [
    "-- 局部变量：local items = {}  〔所在：Container:GetItemByName〕",
  ],
  "tryfind#1+1": [
    "-- 局部变量：local num_found = 0  〔所在：tryfind〕",
  ],
  "tryfind#1+2": [
    "-- 条件分支：if v and v.prefab == item then  〔所在：tryfind〕",
  ],
  "tryfind#1+3": [
    "-- 局部变量：local num_left_to_find = amount - total_num_found  〔所在：tryfind〕",
  ],
  "tryfind#1+4": [
    "-- 条件分支：if v.components.stackable then  〔所在：tryfind〕",
  ],
  "tryfind#1+7": [
    "-- 局部赋值：num_found = amount  〔所在：tryfind〕",
  ],
  "tryfind#1+8": [
    "-- 兜底分支（前述条件全不成立）。〔所在：tryfind〕",
  ],
  "tryfind#1+12": [
    "-- 兜底分支（前述条件全不成立）。〔所在：tryfind〕",
  ],
  "tryfind#1+14": [
    "-- 局部赋值：num_found = num_found + 1  〔所在：tryfind〕",
  ],
  "tryfind#1+17": [
    "-- 返回：return num_found  〔所在：tryfind〕",
  ],
  "tryfind#1+21": [
    "-- 局部变量：local v = self.slots[k]  〔所在：tryfind〕",
  ],
  "tryfind#1+22": [
    "-- 局部赋值：total_num_found = total_num_found + tryfind(v)  〔所在：tryfind〕",
  ],
  "tryfind#1+24": [
    "-- 条件分支：if total_num_found >= amount then  〔所在：tryfind〕",
  ],
  "tryfind#1+29": [
    "-- 返回：return items  〔所在：tryfind〕",
  ],
  "crafting_priority_fn#1+1": [
    "-- 条件分支：if a.stacksize == b.stacksize then  〔所在：crafting_priority_fn〕",
  ],
  "crafting_priority_fn#1+2": [
    "-- 返回：return a.slot < b.slot  〔所在：crafting_priority_fn〕",
  ],
  "Container:GetCraftingIngredient#1+1": [
    "-- 局部变量：local items = {}  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+2": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+3": [
    "-- 局部变量：local v = self.slots[i]  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+5": [
    "-- table.insert(items, {  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+6": [
    "-- 局部赋值：item = v,  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+7": [
    "-- 局部赋值：stacksize = v.components.stackable and v.components.stackable:StackSize() or 1,  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+14": [
    "-- 局部变量：local crafting_items = {}  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+15": [
    "-- 局部变量：local total_num_found = 0  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+16": [
    "-- 循环：for i, v in ipairs(items) do  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+17": [
    "-- 局部变量：local stacksize = math.min(v.stacksize, amount - total_num_found)  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+19": [
    "-- 局部赋值：total_num_found = total_num_found + stacksize  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+20": [
    "-- 条件分支：if total_num_found >= amount then  〔所在：Container:GetCraftingIngredient〕",
  ],
  "Container:GetCraftingIngredient#1+25": [
    "-- 返回：return crafting_items  〔所在：Container:GetCraftingIngredient〕",
  ],
  "tryconsume#1+1": [
    "-- 条件分支：if v.components.stackable == nil then  〔所在：tryconsume〕",
  ],
  "tryconsume#1+3": [
    "-- 返回：return 1  〔所在：tryconsume〕",
  ],
  "tryconsume#1+4": [
    "-- 次选条件：elseif v.components.stackable.stacksize > amount then  〔所在：tryconsume〕",
  ],
  "tryconsume#1+6": [
    "-- 返回：return amount  〔所在：tryconsume〕",
  ],
  "tryconsume#1+7": [
    "-- 兜底分支（前述条件全不成立）。〔所在：tryconsume〕",
  ],
  "tryconsume#1+8": [
    "-- 局部赋值：amount = v.components.stackable.stacksize  〔所在：tryconsume〕",
  ],
  "tryconsume#1+10": [
    "-- 返回：return amount  〔所在：tryconsume〕",
  ],
  "tryconsume#1+13": [
    "-- 返回：return 0  〔所在：tryconsume〕",
  ],
  "Container:ConsumeByName#1+2": [
    "-- 返回：return  〔所在：Container:ConsumeByName〕",
  ],
  "Container:ConsumeByName#1+5": [
    "-- 循环：for k, v in pairs(self.slots) do  〔所在：Container:ConsumeByName〕",
  ],
  "Container:ConsumeByName#1+6": [
    "-- 条件分支：if v.prefab == item then  〔所在：Container:ConsumeByName〕",
  ],
  "Container:ConsumeByName#1+7": [
    "-- 局部赋值：amount = amount - tryconsume(self, v, amount)  〔所在：Container:ConsumeByName〕",
  ],
  "Container:ConsumeByName#1+8": [
    "-- 条件分支：if amount <= 0 then  〔所在：Container:ConsumeByName〕",
  ],
  "Container:ConsumeByName#1+9": [
    "-- 返回：return  〔所在：Container:ConsumeByName〕",
  ],
  "Container:OnSave#1+1": [
    "-- 局部变量：local data = {items= {}}  〔所在：Container:OnSave〕",
  ],
  "Container:OnSave#1+2": [
    "-- 局部变量：local references = {}  〔所在：Container:OnSave〕",
  ],
  "Container:OnSave#1+3": [
    "-- 局部变量：local refs  〔所在：Container:OnSave〕",
  ],
  "Container:OnSave#1+4": [
    "-- 循环：for k,v in pairs(self.slots) do  〔所在：Container:OnSave〕",
  ],
  "Container:OnSave#1+7": [
    "-- 条件分支：if refs then  〔所在：Container:OnSave〕",
  ],
  "Container:OnSave#1+8": [
    "-- 循环：for k,v in pairs(refs) do  〔所在：Container:OnSave〕",
  ],
  "Container:OnSave#1+9": [
    "-- table.insert(references, v)  〔所在：Container:OnSave〕",
  ],
  "Container:OnSave#1+14": [
    "-- 返回：return data, references  〔所在：Container:OnSave〕",
  ],
  "Container:OnLoad#1+1": [
    "-- 条件分支：if data.items then  〔所在：Container:OnLoad〕",
  ],
  "Container:OnLoad#1+2": [
    "-- 循环：for k,v in pairs(data.items) do  〔所在：Container:OnLoad〕",
  ],
  "Container:OnLoad#1+3": [
    "-- 局部变量：local inst = SpawnSaveRecord(v, newents)  〔所在：Container:OnLoad〕",
  ],
  "Container:RemoveItem#1+1": [
    "-- 条件分支：if item then  〔所在：Container:RemoveItem〕",
  ],
  "Container:RemoveItem#1+2": [
    "-- 局部变量：local slot = self:GetItemSlot(item)  〔所在：Container:RemoveItem〕",
  ],
  "Container:RemoveItem#1+3": [
    "-- 条件分支：if slot then  〔所在：Container:RemoveItem〕",
  ],
  "Container:RemoveItem#1+4": [
    "-- 返回：return self:RemoveItem_Internal(item, slot, wholestack, keepoverstacked)  〔所在：Container:RemoveItem〕",
  ],
  "Container:RemoveItem_Internal#1+3": [
    "-- 返回：return nil  〔所在：Container:RemoveItem_Internal〕",
  ],
  "Container:RemoveItem_Internal#1+6": [
    "-- 局部变量：local stackable = item.components.stackable  〔所在：Container:RemoveItem_Internal〕",
  ],
  "Container:RemoveItem_Internal#1+12": [
    "-- 条件分支：if num then  〔所在：Container:RemoveItem_Internal〕",
  ],
  "Container:RemoveItem_Internal#1+17": [
    "-- 返回：return dec  〔所在：Container:RemoveItem_Internal〕",
  ],
  "Container:RemoveItem_Internal#1+33": [
    "-- 返回：return item  〔所在：Container:RemoveItem_Internal〕",
  ],
  "Container:OnUpdate#1+1": [
    "-- 条件分支：if self.opencount == 0 then  〔所在：Container:OnUpdate〕",
  ],
  "Container:OnUpdate#1+3": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:OnUpdate〕",
  ],
  "Container:OnUpdate#1+9": [
    "-- 局部变量：local ismount = mount == self.inst  〔所在：Container:OnUpdate〕",
  ],
  "QueryActiveItem#1+1": [
    "-- 局部变量：local inventory = opener ~= nil and opener.components.inventory or nil  〔所在：QueryActiveItem〕",
  ],
  "QueryActiveItem#1+2": [
    "-- 返回：return inventory, inventory ~= nil and inventory:GetActiveItem() or nil  〔所在：QueryActiveItem〕",
  ],
  "Container:PutOneOfActiveItemInSlot#1+2": [
    "-- 返回：return  〔所在：Container:PutOneOfActiveItemInSlot〕",
  ],
  "Container:PutOneOfActiveItemInSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:PutOneOfActiveItemInSlot〕",
  ],
  "Container:PutOneOfActiveItemInSlot#1+15": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  "Container:PutAllOfActiveItemInSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  "Container:PutAllOfActiveItemInSlot#1+2": [
    "-- 返回：return  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  "Container:PutAllOfActiveItemInSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  "Container:PutAllOfActiveItemInSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  "Container:PutAllOfActiveItemInSlot#1+6": [
    "-- 条件分支：if active_item ~= nil then  〔所在：Container:PutAllOfActiveItemInSlot〕",
  ],
  "Container:PutAllOfActiveItemInSlot#1+17": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。",
  ],
  "Container:PutAllOfActiveItemInSlot#1+19": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  "Container:TakeActiveItemFromHalfOfSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  "Container:TakeActiveItemFromHalfOfSlot#1+2": [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  "Container:TakeActiveItemFromHalfOfSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  "Container:TakeActiveItemFromHalfOfSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  "Container:TakeActiveItemFromHalfOfSlot#1+7": [
    "-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromHalfOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+2": [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+6": [
    "-- 条件分支：if item ~= nil and  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+7": [
    "-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+10": [
    "-- 局部变量：local stackable = item.components.stackable  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+14": [
    "-- 局部变量：local countedstack = stackable:Get(count)  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+19": [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromCountOfSlot#1+20": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:TakeActiveItemFromCountOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+2": [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+6": [
    "-- 条件分支：if item ~= nil and  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+7": [
    "-- 局部赋值：active_item == nil and  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+11": [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+12": [
    "-- 返回：return  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+18": [
    "-- 局部变量：local fullstack = item.components.stackable:Get(item.components.stackable.originalmaxsize)  〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:TakeActiveItemFromAllOfSlot#1+22": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:TakeActiveItemFromAllOfSlot〕",
  ],
  "Container:AddOneOfActiveItemToSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  "Container:AddOneOfActiveItemToSlot#1+2": [
    "-- 返回：return  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  "Container:AddOneOfActiveItemToSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  "Container:AddOneOfActiveItemToSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:AddOneOfActiveItemToSlot〕",
  ],
  "Container:AddAllOfActiveItemToSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  "Container:AddAllOfActiveItemToSlot#1+2": [
    "-- 返回：return  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  "Container:AddAllOfActiveItemToSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  "Container:AddAllOfActiveItemToSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:AddAllOfActiveItemToSlot〕",
  ],
  "Container:SwapActiveItemWithSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  "Container:SwapActiveItemWithSlot#1+2": [
    "-- 返回：return  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  "Container:SwapActiveItemWithSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  "Container:SwapActiveItemWithSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  "Container:SwapActiveItemWithSlot#1+6": [
    "-- 条件分支：if active_item ~= nil then  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  "Container:SwapActiveItemWithSlot#1+7": [
    "-- 条件分支：if item == nil then  〔所在：Container:SwapActiveItemWithSlot〕",
  ],
  "Container:SwapOneOfActiveItemWithSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  "Container:SwapOneOfActiveItemWithSlot#1+2": [
    "-- 返回：return  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  "Container:SwapOneOfActiveItemWithSlot#1+4": [
    "-- 局部变量：local inventory, active_item = QueryActiveItem(self, opener)  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  "Container:SwapOneOfActiveItemWithSlot#1+5": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:SwapOneOfActiveItemWithSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+2": [
    "-- 返回：return  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+5": [
    "-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+7": [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+8": [
    "-- 返回：return  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+23": [
    "-- 局部变量：local shouldignoresound = false  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+25": [
    "-- 局部赋值：item = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+26": [
    "-- 次选条件：elseif container.infinitestacksize then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+28": [
    "-- ★ hack flag：取出超量堆叠时**不**把多出的丢地上（第 1042 行）。",
    "--   本行初值：true。",
  ],
  "Container:MoveItemFromAllOfSlot#1+29": [
    "-- 局部赋值：item = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+30": [
    "-- ignoreoverstacked：同第 1360 行（首次初始化），此处显式赋 false。",
  ],
  "Container:MoveItemFromAllOfSlot#1+31": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+35": [
    "-- 条件分支：if item ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+45": [
    "-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+48": [
    "-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+55": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  "Container:MoveItemFromAllOfSlot#1+62": [
    "-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+65": [
    "-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromAllOfSlot#1+68": [
    "-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromAllOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+2": [
    "-- 返回：return  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+4": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+5": [
    "-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+6": [
    "-- 局部赋值：container = container.components.container or container.components.inventory  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+7": [
    "-- 条件分支：if container ~= nil and  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+15": [
    "-- 局部变量：local targetslot =  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+21": [
    "-- 条件分支：if container:CanTakeItemInSlot(item, targetslot) then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+23": [
    "-- 局部变量：local halfstack = item.components.stackable:Get(math.floor(fullstacksize / 2))  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+28": [
    "-- 条件分支：if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+31": [
    "-- 条件分支：if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+33": [
    "-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+36": [
    "-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+41": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。",
  ],
  "Container:MoveItemFromHalfOfSlot#1+43": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  "Container:MoveItemFromHalfOfSlot#1+47": [
    "-- 条件分支：if container.ignoreoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+50": [
    "-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+53": [
    "-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromHalfOfSlot#1+56": [
    "-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromHalfOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+1": [
    "-- 条件分支：if self.readonlycontainer then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+4": [
    "-- 局部变量：local item = self:GetItemInSlot(slot)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+5": [
    "-- 条件分支：if item ~= nil and container ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+6": [
    "-- 局部赋值：container = container.components.container or container.components.inventory  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+7": [
    "-- 条件分支：if container ~= nil and container:IsOpenedBy(opener) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+12": [
    "-- 局部变量：local targetslot =  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+18": [
    "-- 条件分支：if container:CanTakeItemInSlot(item, targetslot) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+19": [
    "-- 局部变量：local stackable = item.components.stackable  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+20": [
    "-- 局部变量：local fullstacksize = stackable and (stackable:IsOverStacked() and stackable.originalmaxsize or stackable:StackSize()) or 1  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+21": [
    "-- 局部赋值：count = math.clamp(count, 1, fullstacksize)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+22": [
    "-- 局部变量：local countedstack  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+24": [
    "-- 局部赋值：countedstack = stackable:Get(count)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+26": [
    "-- assert(BRANCH ~= \"dev\")  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+27": [
    "-- 兜底分支（前述条件全不成立）。〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+28": [
    "-- 局部赋值：countedstack = self:RemoveItemBySlot(slot)  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+36": [
    "-- 条件分支：if container.ignoreoverflow ~= nil and container:GetOverflowContainer() == self then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+39": [
    "-- 条件分支：if container.ignorespoverflow ~= nil and container:IsSpecializedContainer(self) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+41": [
    "-- 次选条件：elseif container.ignoreclosedspoverflow ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+44": [
    "-- 条件分支：if container.ignorefull ~= nil then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+48": [
    "-- 条件分支：if not container:GiveItem(countedstack, targetslot) then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+49": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 true。",
  ],
  "Container:MoveItemFromCountOfSlot#1+51": [
    "-- ignoresound：同第 63 行（首次初始化），此处显式赋 false。",
  ],
  "Container:MoveItemFromCountOfSlot#1+55": [
    "-- 条件分支：if container.ignoreoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+58": [
    "-- 条件分支：if container.ignorespoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+61": [
    "-- 条件分支：if container.ignoreclosedspoverflow then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:MoveItemFromCountOfSlot#1+64": [
    "-- 条件分支：if container.ignorefull then  〔所在：Container:MoveItemFromCountOfSlot〕",
  ],
  "Container:ReferenceAllItems#1+1": [
    "-- 局部变量：local items = {}  〔所在：Container:ReferenceAllItems〕",
  ],
  "Container:ReferenceAllItems#1+2": [
    "-- 循环：for i=1,self.numslots do  〔所在：Container:ReferenceAllItems〕",
  ],
  "Container:ReferenceAllItems#1+3": [
    "-- 条件分支：if self.slots[i] ~= nil then  〔所在：Container:ReferenceAllItems〕",
  ],
  "Container:ReferenceAllItems#1+4": [
    "-- table.insert(items, self.slots[i])  〔所在：Container:ReferenceAllItems〕",
  ],
  "Container:ReferenceAllItems#1+7": [
    "-- 返回：return items  〔所在：Container:ReferenceAllItems〕",
  ],
  "Container:EnableInfiniteStackSize#1+1": [
    "-- 局部变量：local _ = rawget(self, \"_\") --see class.lua for property setters implementation  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+2": [
    "-- 条件分支：if enable then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+3": [
    "-- 条件分支：if not _.infinitestacksize[1] then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+5": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+6": [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+7": [
    "-- 条件分支：if item and item.components.stackable then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+16": [
    "-- 循环：for i = 1, self.numslots do  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+17": [
    "-- 局部变量：local item = self.slots[i]  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "Container:EnableInfiniteStackSize#1+18": [
    "-- 条件分支：if item and item.components.stackable then  〔所在：Container:EnableInfiniteStackSize〕",
  ],
  "ReadOnlyContainerAssert_in#1+2": [
    "-- dumptable(data)  〔所在：ReadOnlyContainerAssert_in〕",
  ],
  "ReadOnlyContainerAssert_in#1+3": [
    "-- print(\"Time to assert, please report this.\")  〔所在：ReadOnlyContainerAssert_in〕",
  ],
  "ReadOnlyContainerAssert_out#1+1": [
    "-- print(\"__ DATA __\")  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  "ReadOnlyContainerAssert_out#1+2": [
    "-- dumptable(data)  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  "ReadOnlyContainerAssert_out#1+3": [
    "-- print(\"Time to assert, please report this.\")  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  "ReadOnlyContainerAssert_out#1+4": [
    "-- assert(false, string.format(\"VERY BAD! Item %s was transferred out of a read only container.\", tostring(item)))  〔所在：ReadOnlyContainerAssert_out〕",
  ],
  "Container:EnableReadOnlyContainer#1+1": [
    "-- 局部变量：local _ = rawget(self, \"_\") --see class.lua for property setters implementation  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  "Container:EnableReadOnlyContainer#1+2": [
    "-- 条件分支：if enable then  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  "Container:EnableReadOnlyContainer#1+3": [
    "-- 条件分支：if not _.readonlycontainer[1] then  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  "Container:EnableReadOnlyContainer#1+22": [
    "-- 条件分支：if self.inst.components.preserver then  〔所在：Container:EnableReadOnlyContainer〕",
  ],
  "Container:IsRestricted#1+1": [
    "-- 条件分支：if not target:HasTag(\"player\") then  〔所在：Container:IsRestricted〕",
  ],
  "Container:IsRestricted#1+3": [
    "-- 返回：return false  〔所在：Container:IsRestricted〕",
  ],
  "Container:IsThiefProof#1+1": [
    "-- 返回：return self.thiefproof  〔所在：Container:IsThiefProof〕",
  ],
  "Container:IsThiefProof#1+4": [
    "-- 返回：return Container  〔所在：Container:IsThiefProof〕",
  ],
};

export const AFTER = {};
