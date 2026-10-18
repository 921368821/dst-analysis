--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/container_replica.lua
-- 模块：组件系统 / 容器客户端镜像（Container Replica）
-- 职责：容器（箱子/背包/晾衣绳等）的客户端镜像。负责容器界面的开启与关闭、
--       槽位合法性判定（CanTakeItemInSlot）、物品查询（GetItemInSlot/Has）、
--       槽位点击操作的 RPC 请求转发（Put*/Take*/Add*/Swap*/Move*系列）、
--       观察者管理（AttachOpener / AddOpener）与只读容器标记。
-- ★ 定位：这是「replica 模式」的最佳样本——同名方法与
--   components/container.lua（服务端权威）高度重合，但一个改数据、一个只读副本。
--   客户端只发意图请求，真正变更一律由服务端确认后广播。
-- 关键符号：Container, Open, Close, CanTakeItemInSlot, GetSpecificSlotForItem,
--           ShouldPrioritizeContainer, IsOpenedBy, IsBusy, AttachOpener,
--           DetachOpener, AddOpener, RemoveOpener, WidgetSetup,
--           RefreshLocalPlayerUI, OnRemoveEntity
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/container.lua（服务端权威实现，方法名一一对应）,
--           components/inventoryitem.lua（CanGoInContainer 等物品属性）,
--           components/stackable.lua（IsFull / CanStackWith 堆叠判定）,
--           widgets/containerwidget.lua（容器 UI 控件）,
--           widgets/inventorybar.lua（HUD 容器条）,
--           networking.lua / networkclientrpc.lua（槽位操作的 RPC 通道）,
--           classed.lua（classified 子实体）, replica.lua（replica 机制本体）
--============================================================
local containers = require("containers")
--[[
-- container_replica.lua —— 容器组件的客户端镜像（Container Replica）
--
-- ★★ 这个文件是理解 DST 联机架构的最佳样本，因为它把「双端分工」
--   写得极其直白：
--     components/container.lua         —— 服务端权威，管数据
--     components/container_replica.lua  —— 客户端镜像，管界面
--   两者方法名高度重合（Open / Close / CanTakeItemInSlot / GetItemInSlot...），
--   但实现完全不同。这正是「replica 模式」的典型形态。
--
-- 【★ 最重要的一条纪律】
--   replica 里的方法**只读客户端数据，绝不能改服务端状态**。
--   凡是「放东西 / 拿东西 / 删东西」的操作，都必须走 RPC 交给服务端。
--   本文件里所有 Put*/Take*/Add*/Swap*/Move* 系列方法都是「发请求」而非「真操作」，
--   这就是 replica 与普通组件最大的区别。
--
-- 【判定权威的写法】
--   几乎每个方法开头都是同一个模式：
--     if self.inst.components.container ~= nil then
--         -- 有服务端组件 → 转发过去（单机/host 情形）
--     else
--         -- 纯客户端 → 走 replica 分支
--     end
--   这个二分支结构贯穿全文件。host 玩家身上两者都有，走第一条。
--]]

local Container = Class(function(self, inst)
    self.inst = inst

    self._cannotbeopened = net_bool(inst.GUID, "container._cannotbeopened")
    self._skipopensnd = net_bool(inst.GUID, "container._skipopensnd")
    self._skipclosesnd = net_bool(inst.GUID, "container._skipclosesnd")
    self._isopen = false
    self._numslots = 0
    self.acceptsstacks = true
    self.usespecificslotsforitems = false
    self.issidewidget = false
    self.type = nil
    self.widget = nil
    self.itemtestfn = nil
    self.priorityfn = nil
    self.opentask = nil
    self.openers = {}
    self.opener = nil

    if TheWorld.ismastersim then
        self.classified = SpawnPrefab("container_classified")
        self.classified.entity:SetParent(inst.entity)
        self.classified.Network:SetClassifiedTarget(self.inst)

        --Server intercepts messages and forwards to clients via classified net vars
        self._onitemget = function(inst, data)
            self.classified:SetSlotItem(data.slot, data.item, data.src_pos)
            if inst.components.inventoryitem ~= nil and
                inst.components.inventoryitem.owner ~= nil and
                inst.components.inventoryitem.owner.HUD ~= nil then
                inst.components.inventoryitem.owner:PushEvent("refreshcrafting")
            end
        end
        self._onitemlose = function(inst, data)
            self.classified:SetSlotItem(data.slot)
            if inst.components.inventoryitem ~= nil and
                inst.components.inventoryitem.owner ~= nil and
                inst.components.inventoryitem.owner.HUD ~= nil then
                inst.components.inventoryitem.owner:PushEvent("refreshcrafting")
            end
        end
        inst:ListenForEvent("itemget", self._onitemget)
        inst:ListenForEvent("itemlose", self._onitemlose)
    else
        containers.widgetsetup(self)

        if self.classified == nil and inst.container_classified ~= nil then
            self.classified = inst.container_classified
            inst.container_classified.OnRemoveEntity = nil
            inst.container_classified = nil
            self:AttachClassified(self.classified)
        end
        if self.opener == nil and inst.container_opener ~= nil then
            self.opener = self.inst.container_opener
            inst.container_opener.OnRemoveEntity = nil
            inst.container_opener = nil
            self:AttachOpener(self.opener)
        end
    end
end)

local function SetOpener(self, opener)
-- SetOpener：记录「谁打开了这个容器」。
-- ⚠️ 这是客户端的**本地状态**，不是权威数据——
--   真正的权威在服务端 container 组件里。客户端记录它只是为了决定
--   「这个容器该不该为我显示界面」。
    self.classified.Network:SetClassifiedTarget(opener or self.inst)
    if self.inst.components.container ~= nil then
        for k, v in pairs(self.inst.components.container.slots) do
            v.replica.inventoryitem:SetOwner(self.inst)
        end
    else
        --Shouldn't be reachable.
        assert(false)
    end
end

--------------------------------------------------------------------------

--V2C: OnRemoveFromEntity not supported
-- ⚠️ 注意这里：OnRemoveFromEntity 被整段注释掉了（第 79 行起），
--   源码自己的说明是 "--V2C: OnRemoveFromEntity not supported"。
--
-- 【为什么会这样】
--   该钩子由引擎在「实体从世界移除」时调用，但容器销毁涉及
--   classified / opener 两个子实体的联动，引擎层的调用时机并不可靠，
--   于是官方选择「不支持这个钩子」，改在第 111 行的 OnRemoveEntity 里处理。
--
-- ★ 这是一条重要的移植经验：
--   遇到「引擎声称支持但实际不可靠」的钩子，不要硬用，
--   宁可换一条自己控制得了的路径。注释掉并写明原因，
--   比留一个时灵时不灵的钩子安全得多。
--
-- ★★ 反面教材价值：这一段被注释的代码留在文件里，
--   后来者可能误以为它是有效实现而照抄。
--   仿写时务必看清注释掉的代码块——它们记录的是「试过但不行」，
--   而不是「还没写」。
--[[function Container:OnRemoveFromEntity()
    if self.classified ~= nil then
        if TheWorld.ismastersim then
            self.classified:Remove()
            self.classified = nil
            self.inst:RemoveEventCallback("itemget", self._onitemget)
            self.inst:RemoveEventCallback("itemlose", self._onitemlose)
            if self._onputininventory ~= nil then
                self.inst:RemoveEventCallback("onputininventory", self._onputininventory)
                self.inst:RemoveEventCallback("ondropped", self._ondropped)
                self._onputininventory = nil
                self._ondropped = nil
                self._owner = nil
            end
        else
            self.classified._parent = nil
            self.inst:RemoveEventCallback("onremove", self.ondetachclassified, self.classified)
            self:DetachClassified()
        end
    end
    if self.opener and not TheWorld.ismastersim then
        self.opener._parent = nil
        self.inst:RemoveEventCallback("onremove", self.ondetachopener, self.opener)
        self:DetachOpener()
    elseif TheWorld.ismastersim then
        for player, opener in pairs(self.openers) do
            opener:Remove()
            self.openers[player] = nil
        end
    end
end]]

function Container:OnRemoveEntity()
-- ★ OnRemoveEntity：实体销毁时的清理。
-- ⚠️ 注意开头的 if TheWorld.ismastersim —— 这个函数**只在服务端执行**。
--   它负责把 classified（分类子实体）与所有 opener（开启者）一并 Remove()，
--   因为这些子实体是服务端生成的，客户端无权销毁。
--
-- 【所以客户端的清理在哪里？】
--   不在这个函数里。客户端的界面关闭依赖：
--     · 第 137 行 OpenContainer 的对偶路径
--     · 第 315 行 RefreshLocalPlayerUI 的刷新时机
--     · 以及引擎侧对「已移除实体」的界面兜底
--   换句话说，**客户端清理是分散且隐式**的，这也是第 78 行
--   「OnRemoveFromEntity not supported」注释的背景：
--   引擎没有提供可靠的客户端销毁回调，官方只能靠别的方式兜住。
--
-- ★ 经验：读replica 文件时要特别注意 ismastersim 判断——
--   它决定了某段代码「在服务端还是客户端跑」，
--   而这直接决定了你能不能信任它对客户端 UI 的影响。
	if TheWorld.ismastersim then
		if self.classified then
			self.classified:Remove()
			self.classified = nil
		end
		for player, opener in pairs(self.openers) do
			opener:Remove()
			self.openers[player] = nil
		end
	elseif self.opener then
		self.opener._parent = nil
		self:DetachOpener()
	end
end

--------------------------------------------------------------------------
--Client triggers open/close based on receiving access to classified data
--------------------------------------------------------------------------

local function OnRefreshCrafting(inst)
    if ThePlayer ~= nil and ThePlayer.HUD ~= nil then
        ThePlayer:PushEvent("refreshcrafting")
    end
end

local function OpenContainer(inst, self, snap)
-- ★ OpenContainer：真正打开界面。
-- 注意 snap 参数：是否把界面「吸附」到容器所在位置（跟随移动）。
-- 对应下方 Open 里 doer.HUD:OpenContainer 的第二个参数 IsSideWidget()。
    self.opentask = nil

    --V2C: don't animate to and from the backpack position
    --     when re-opening inventory as Werebeaver->Woodie
    local inv = snap and ThePlayer ~= nil and ThePlayer.HUD ~= nil and ThePlayer.HUD.controls.inv or nil
    snap = inv ~= nil and not inv.rebuild_pending

    self:Open(ThePlayer)
    OnRefreshCrafting(inst)

    if snap and inv.rebuild_pending then
        inv.rebuild_snapping = true
    end
end

function Container:AttachClassified(classified)
    self.classified = classified

    self.ondetachclassified = function() self:DetachClassified() end
    self.inst:ListenForEvent("onremove", self.ondetachclassified, classified)

    classified:InitializeSlots(self:GetNumSlots())
end

function Container:DetachClassified()
    self.inst:RemoveEventCallback("onremove", self.ondetachclassified, self.classified)
    self.classified = nil
    self.ondetachclassified = nil
end

function Container:AttachOpener(opener)
-- AttachOpener / DetachOpener：开启与关闭的对偶操作。
-- ★ 这两个函数是「隐式契约」的典型例子：
--   Attach 里做的每个动作，Detach 必须精确撤销一次。
--   漏掉任何一步，UI 就会残留（对应 bug-patterns CTR9「两个函数构成隐式契约」）。
--   仿写建议：写完 Attach 后立刻写 Detach，逐行对照检查。
    self.opener = opener

    self.ondetachopener = function() self:DetachOpener() end
    self.inst:ListenForEvent("onremove", self.ondetachopener, opener)

    local inv = self.issidewidget and ThePlayer ~= nil and ThePlayer.HUD ~= nil and ThePlayer.HUD.controls.inv or nil
    self.opentask = self.inst:DoTaskInTime(0, OpenContainer, self, inv ~= nil and (not inv.shown or inv.rebuild_snapping))

    self.inst:ListenForEvent("itemget", OnRefreshCrafting)
    self.inst:ListenForEvent("itemlose", OnRefreshCrafting)
end

function Container:DetachOpener()
    self.inst:RemoveEventCallback("onremove", self.ondetachopener, self.opener)
    self.opener = nil
    self.ondetachopener = nil
    self.inst:RemoveEventCallback("itemget", OnRefreshCrafting)
    self.inst:RemoveEventCallback("itemlose", OnRefreshCrafting)
    OnRefreshCrafting(self.inst)
    self:Close()
end

function Container:AddOpener(opener)
-- AddOpener / RemoveOpener：多观察者场景（别人也能看你打开的容器）。
-- 与 Attach/Detach 的区别：前者管「界面」，这里管「知情者列表」。
    local opencount = self.inst.components.container.opencount
    if opencount == 1 then
        --standard logic.
        SetOpener(self, opener)
    elseif opencount > 1 then
        self.classified.Network:SetClassifiedTarget(nil)
        if self.inst.components.container ~= nil then
            for k, v in pairs(self.inst.components.container.slots) do
                v.replica.inventoryitem:SetOwner(self.inst)
            end
        end
    end
    self.openers[opener] = self.inst:SpawnChild("container_opener")
    self.openers[opener].Network:SetClassifiedTarget(opener)
end

function Container:RemoveOpener(opener)
    local opencount = self.inst.components.container.opencount
    if opencount == 0 then
        SetOpener(self, nil)
    elseif opencount == 1 then
        SetOpener(self, table.getkeys(self.inst.components.container.openlist)[1])
    elseif opencount > 1 then
        self.classified.Network:SetClassifiedTarget(nil)
        if self.inst.components.container ~= nil then
            for k, v in pairs(self.inst.components.container.slots) do
                v.replica.inventoryitem:SetOwner(self.inst)
            end
        end
    end
    if self.openers[opener] then
        self.openers[opener]:Remove()
        self.openers[opener] = nil
    end
end

--------------------------------------------------------------------------
--Server initialization requires param since prefab property is not set yet
--------------------------------------------------------------------------

function Container:WidgetSetup(prefab, data)
-- WidgetSetup：由服务端下发的 UI 构建数据。
-- ★ 这是「UI 完全由代码驱动」的具体体现：
--   服务端下发一个 prefab 名 + 参数表，客户端据此实例化控件。
--   没有布局引擎，没有 prefab 编辑器，一切都是数据。
    containers.widgetsetup(self, prefab, data)
    if self.classified ~= nil then
        self.classified:InitializeSlots(self:GetNumSlots())
    end

    if self._onputininventory == nil then
        self._owner = nil
        self._ondropped = function(inst)
            if self._owner ~= nil then
                local owner = self._owner
                self._owner = nil
                if owner.HUD ~= nil then
                    owner:PushEvent("refreshcrafting")
                end
            end
        end
        self._onputininventory = function(inst, owner)
            self._ondropped(inst)
            self._owner = owner
            if owner ~= nil and owner.HUD ~= nil then
                owner:PushEvent("refreshcrafting")
            end
        end
        self.inst:ListenForEvent("onputininventory", self._onputininventory)
        self.inst:ListenForEvent("ondropped", self._ondropped)
    end
end

--------------------------------------------------------------------------
--Common interface
--------------------------------------------------------------------------

function Container:GetWidget()
    return self.widget
end

function Container:SetNumSlots(numslots)
    self._numslots = numslots
end

function Container:GetNumSlots()
    return self._numslots
end

function Container:SetCanBeOpened(canbeopened)
    self._cannotbeopened:set(not canbeopened)
end

function Container:CanBeOpened()
    return not self._cannotbeopened:value()
end

function Container:SetSkipOpenSnd(skipopensnd)
    self._skipopensnd:set(skipopensnd)
end

function Container:ShouldSkipOpenSnd()
    return self._skipopensnd:value()
end

function Container:SetSkipCloseSnd(skipclosesnd)
    self._skipclosesnd:set(skipclosesnd)
end

function Container:ShouldSkipCloseSnd()
    return self._skipclosesnd:value()
end

function Container:EnableInfiniteStackSize(enable)
	if self.classified then
		self.classified.infinitestacksize:set(enable)
	end
end

function Container:IsInfiniteStackSize()
    if not self.classified then
        return false
    end

    return self.classified.infinitestacksize:value()
end

local function RefreshLocalPlayerUI(self) -- Call from server handles server is client case.
-- RefreshLocalPlayerUI：本地玩家界面刷新。
-- 注释特别写了 "Call from server handles server is client case"——
-- host 玩家既在服务端又在客户端，需要服务端主动触发客户端 UI 更新。
-- 这是「服务器与客户端同体」的特例处理，移植时很容易漏。
    for player, opener in pairs(self.openers) do
        if player.HUD then
            player:PushEvent("refreshcrafting")
            if player.HUD.controls then
                local widget = player.HUD.controls.containers[self.inst]
                if widget then
                    widget:Refresh()
                end
            end
        end
    end
end

function Container:EnableReadOnlyContainer(enable)
    if self.classified then
        self.classified.readonlycontainer:set(enable)
        RefreshLocalPlayerUI(self)
    end
end

function Container:IsReadOnlyContainer()
	return self.classified ~= nil and self.classified.readonlycontainer:value()
end

function Container:CanTakeItemInSlot(item, slot)
-- ★★★ CanTakeItemInSlot —— 判定某物品能否放进某槽位，校验链很长。
-- 【顺序即优先级，任何一步不过就return false】
--  1) item 及其 replica.inventoryitem 必须存在
--  2) 物品本身允许进容器（CanGoInContainer）且不是「只能进口袋」
--  3) 「只能进口袋或口袋类容器」的特殊物品，额外要求目标容器自己也标记为口袋
--  4) 只读容器 → 拒绝
--  5) 特殊游戏模式（non_item_equips）下，不接受「需要装备槽的物品」
--  6) slot 给了的话：必须落在 [1, numslots] 区间内
--  7) 目标槽位已有物品且被锁定 → 只有「可堆叠且未满且同类」才允许放入
--  8) 最后交给自定义钩子 itemtestfn 裁决
--
-- 【⚠️ 全函数都在读 replica】
--   这意味着客户端用「本地副本」做判定，而服务端会用真实数据再判一次。
--   两端数据不一致时会出现「客户端能放、服务端拒绝」的错位——
--   典型表现就是物品「弹回去」。这类问题见 bug-patterns B1/B3/B4。
--   正确做法是：客户端判定只用于 UI 即时反馈，**服务端必须独立再校验一次**，
--   绝不能信任客户端传来的合法性结论。
	local inventoryitem = item and item.replica.inventoryitem
	if inventoryitem == nil then
		return false
	elseif not inventoryitem:CanGoInContainer() or inventoryitem:CanOnlyGoInPocket() then
		return false
	elseif inventoryitem:CanOnlyGoInPocketOrPocketContainers() then
		local my_inventoryitem = self.inst.replica.inventoryitem
		if not (my_inventoryitem and my_inventoryitem:CanOnlyGoInPocket()) then
			return false
		end
	end

	if self:IsReadOnlyContainer() then
		return false
	elseif GetGameModeProperty("non_item_equips") and item.replica.equippable then
		return false
	elseif slot then
		if slot < 1 or slot > self:GetNumSlots() then
-- 槽位越界检查。注意是闭区间 [1, numslots]。
-- ⚠️ 这里没做 nil 检查就调GetNumSlots，说明调用方保证 self 有效。
			return false
		end
		local existingitem = self:GetItemInSlot(slot)
		local existing_inventoryitem = existingitem and existingitem.replica.inventoryitem
		if existing_inventoryitem and existing_inventoryitem:IsLockedInSlot() then
-- 锁定槽位：已有物品被 IsLockedInSlot 标记时，不允许被替换。
-- 唯一例外是「可堆叠 + 未满 + 同类」——因为堆叠不改变槽位的归属物品。
-- 这个例外条件写得很紧凑，三个 and 缺一不可，抄的时候容易漏。
			local existing_stackable = existingitem.replica.stackable
			if not (existing_stackable and
					not existing_stackable:IsFull() and
					existing_stackable:CanStackWith(item))
			then
				return false
			end
		end
	end
	return self.itemtestfn == nil or self:itemtestfn(item, slot)
-- 自定义校验钩子作为最后一道关口。
-- ★ 移植经验：把「通用规则」与「特例规则」分层——
--   通用规则写死在函数里（如越界、只读），特例交给钩子。
--   反过来做（什么都塞进钩子）会导致调用点散落各处、难以追踪。
end

function Container:GetSpecificSlotForItem(item)
-- GetSpecificSlotForItem：找出唯一适合放该物品的槽位。
-- ⚠️ 注意：找不到时**没有 return nil**，Lua 会隐式返回 nil。
--   多数情况下没问题，但若上游用「多个返回值」接收就会踩坑。
--   另外这里的条件用了 itemtestfn 存在性做前置，语义上等价于「启用指定槽位」。
    if self.usespecificslotsforitems and not self:IsReadOnlyContainer() and self.itemtestfn ~= nil then
        for i = 1, self:GetNumSlots() do
            if self:itemtestfn(item, i) then
                return i
            end
        end
    end
end

function Container:ShouldPrioritizeContainer(item)
-- ShouldPrioritizeContainer：物品应优先放进这个容器吗。
-- ★ 关键：它**完整重复了 CanTakeItemInSlot 的一整套前置条件**（第 390-396 行）。
-- 这就是 bug-patterns CTR9 所说的「隐式契约」——
-- 两处判定必须永远保持一致，改一处忘了另一处，
-- 就会出现「UI 说该放这里，实际放进去失败」的不一致。
-- 正确解法是抽出一个公共函数让两处共用，或至少加注释互相标注。
    if not self.priorityfn then
        return false
    end
    return item ~= nil
        and item.replica.inventoryitem ~= nil
        and item.replica.inventoryitem:CanGoInContainer()
        and not item.replica.inventoryitem:CanOnlyGoInPocket()
        and (not item.replica.inventoryitem:CanOnlyGoInPocketOrPocketContainers() or self.inst.replica.inventoryitem and self.inst.replica.inventoryitem:CanOnlyGoInPocket())
        and not self:IsReadOnlyContainer()
        and not (GetGameModeProperty("non_item_equips") and item.replica.equippable ~= nil)
        and (self:priorityfn(item))
end

function Container:AcceptsStacks()
    return self.acceptsstacks
end

function Container:IsSideWidget()
    return self.issidewidget
end

Container.SetOpener = function() end --deprecated, kept in case a mod calls this function.
-- ⚠️ 已废弃的空实现，特意保留给可能仍在调用它的模组。
-- 这是很好的向后兼容做法：删除接口前先留一个 no-op，
-- 让老模组调用时不报错。移植时若要下线接口，可参考这个模式。

function Container:IsOpenedBy(guy)
-- IsOpenedBy：判断是否由此人打开。
-- ⚠️ 两条分支的语义明显不同：
--   有服务端组件 → 转发给权威实现；
--   无服务端组件 → 判断「我是打开者 且 界面开着 且 有 classified 且 是本机玩家」。
-- 后者那句 `guy == ThePlayer` 就是 bug-patterns ACT6「IsOpenedBy(doer) 恒为假」的来源：
-- 传入非本机玩家时永远返回 false。这是客户端镜像的固有局限，不是缺陷。
    if self.inst.components.container ~= nil then
        return self.inst.components.container:IsOpenedBy(guy)
    else
        return self.opener ~= nil and self._isopen and self.classified ~= nil and guy ~= nil and guy == ThePlayer
    end
end

function Container:IsHolding(item, checkcontainer)
    if self.inst.components.container ~= nil then
        return self.inst.components.container:IsHolding(item, checkcontainer)
    else
        return self.opener ~= nil and self.classified ~= nil and self.classified:IsHolding(item, checkcontainer)
    end
end

function Container:FindItem(fn)
	if self.inst.components.container then
		return self.inst.components.container:FindItem(fn)
	elseif self.opener and self.classified then
		return self.classified:FindItem(fn)
	end
end

function Container:GetItemInSlot(slot)
    if self.inst.components.container ~= nil then
        return self.inst.components.container:GetItemInSlot(slot)
    else
        return self.opener ~= nil and self.classified ~= nil and self.classified:GetItemInSlot(slot) or nil
    end
end

function Container:GetItems()
    if self.inst.components.container ~= nil then
        return self.inst.components.container.slots
    else
        return self.opener ~= nil and self.classified ~= nil and self.classified:GetItems() or {}
    end
end

function Container:IsEmpty()
    if self.inst.components.container ~= nil then
        return self.inst.components.container:IsEmpty()
    else
        return self.opener ~= nil and self.classified ~= nil and self.classified:IsEmpty()
    end
end

function Container:IsFull()
    if self.inst.components.container ~= nil then
        return self.inst.components.container:IsFull()
    else
        return self.opener ~= nil and self.classified ~= nil and self.classified:IsFull()
    end
end

function Container:Has(prefab, amount, iscrafting)
    if self.inst.components.container ~= nil then
		return self.inst.components.container:Has(prefab, amount, iscrafting)
    elseif self.classified ~= nil and self.opener ~= nil then
		return self.classified:Has(prefab, amount, iscrafting)
    else
        return amount <= 0, 0
    end
end

function Container:HasItemWithTag(tag, amount)
    if self.inst.components.container ~= nil then
		return self.inst.components.container:HasItemWithTag(tag, amount)
    elseif self.classified ~= nil and self.opener ~= nil then
        return self.classified:HasItemWithTag(tag, amount)
    else
        return amount <= 0, 0
    end
end

function Container:Open(doer)
-- ★★★ Open —— 打开容器。
-- 【结构】同样是「有服务端组件则转发，否则走客户端」的二分支。
--
-- 【⚠️ 一个真实的设计缺陷】
--   函数里**从未调用 CanBeOpened()**（见第 281 行定义）。
--   也就是说「这个容器允不允许被打开」这个判定被完全绕过了。
--   调用方必须自己保证只在合法情况下调用 Open。
--   一旦有模组直接调 Open 而不先问 CanBeOpened，就会打开一个本不该打开的容器。
--   这正是 bug-patterns CTR8「CanOpen 不被 Open 调用（守门人失效）」。
--   移植建议：在 Open 开头补一道 CanBeOpened 检查，
--   或明确文档化「调用方必须自行校验」并把它变成契约。
    if self.inst.components.container ~= nil then
        if self.opentask ~= nil then
            self.opentask:Cancel()
            self.opentask = nil
        end
        self.inst.components.container:Open(doer)
    elseif self.classified ~= nil and
-- 客户端分支的四个前置条件：已分类、未在打开中、有操作者、且是本机玩家。
-- ⚠️ doer == ThePlayer 这个判断意味着：客户端只允许「自己」打开界面。
--   多人联机时别人的容器由服务端转发通知，不走这里。
        self.opentask == nil and
        doer ~= nil and
        doer == ThePlayer then
        if doer.HUD == nil then
            self._isopen = false
        elseif not self._isopen then
            doer.HUD:OpenContainer(self.inst, self:IsSideWidget())
			if not self:ShouldSkipOpenSnd() then
-- 音效选择：一长串 or 构成优先级链。
--   皮肤专属音效 > 控件自带音效 > 侧边栏专用 > 通用 HUD 音效。
-- ★ 这种「优先级递减的 or 链」是处理「多来源可覆盖默认值」的常用技巧，
--   移植时值得复用。注意每个分支都做了 nil 保护，避免中间项为 nil 时崩。
				local skinsound = self.inst.AnimState and SKIN_SOUND_FX[self.inst.AnimState:GetSkinBuild()] or nil
				TheFocalPoint.SoundEmitter:PlaySound(
					skinsound and skinsound.open_ui or
					(self.widget ~= nil and self.widget.opensound) or
					(self:IsSideWidget() and "dontstarve/wilson/backpack_open") or
					"dontstarve/HUD/Together_HUD/container_open"
				)
            end
            self._isopen = true
        end
    end
end

function Container:Close()
-- Close：与 Open 完全对称。
-- ★ 对照阅读价值很高：
--   Open  里先 Cancel opentask 再走分支，Close 里也是先 Cancel。
--   两者的判空顺序一致，说明这是有意的对称设计。
--   仿写时把 Open/Close 放在一起写，能显著减少不对称 bug。
    if self.opentask ~= nil then
        self.opentask:Cancel()
        self.opentask = nil
    end
    if self.inst.components.container ~= nil then
        self.inst.components.container:Close()
    elseif self._isopen then
        if ThePlayer ~= nil and ThePlayer.HUD ~= nil then
            ThePlayer.HUD:CloseContainer(self.inst, self:IsSideWidget())
			if not self:ShouldSkipCloseSnd() then
				local skinsound = self.inst.AnimState and SKIN_SOUND_FX[self.inst.AnimState:GetSkinBuild()] or nil
				TheFocalPoint.SoundEmitter:PlaySound(
					skinsound and skinsound.close_ui or
					(self.widget ~= nil and self.widget.closesound) or
					(self:IsSideWidget() and "dontstarve/wilson/backpack_close") or
					"dontstarve/HUD/Together_HUD/container_close"
				)
            end
        end
        self._isopen = false
    end
end

function Container:IsBusy()
-- IsBusy：容器是否正在被占用（如正在被服务器处理操作）。
-- ⚠️ 这里用了「或」：classified 为空 **或** opener 为空 **或** classified 忙，
--   就算忙。语义偏保守（宁可认为忙）。
--   当 classified/opener 任一为 nil 时直接判忙——
--   因为此时状态不完整，不宜乐观假设可用。
    return self.inst.components.container == nil and ((self.classified == nil or self.opener == nil) or self.classified:IsBusy())
end

--------------------------------------------------------------------------
--InvSlot click action handlers
--------------------------------------------------------------------------

--only the "client" should be calling these functions, even in cases where the client turns out to be the server, so using ThePlayer as opener should probably work out.

function Container:PutOneOfActiveItemInSlot(slot)
-- ★★★ 以下所有 Put*/Take*/Add*/Swap*/Move* 方法都是「发 RPC 请求」，
--   而不是在客户端直接改数据。这与普通组件的同名方法语义完全不同。
--
-- 【为什么这样设计】
--   客户端直接改数据会造成「客户端与服务端状态分叉」，
--   而 DST 采取服务器权威：所有变更必须由服务端确认后再广播回来。
--   客户端只负责「发起意图 + 临时 UI 反馈」。
--
-- 【代价与常见问题】
--   · 网络延迟时物品会有「弹回」感（见 bug-patterns B7 缺预测）
--   · 客户端无法立即确认成功，UI 需要额外的 pending 状态
--   · 每个方法都要处理「请求发出后、确认回来前用户又操作了」的竞态
--
-- 移植建议：把这批方法统一加注释标明「请求」语义，
-- 避免后来者误以为改了这里就真的改了数据。
    if self.inst.components.container ~= nil then
        self.inst.components.container:PutOneOfActiveItemInSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:PutOneOfActiveItemInSlot(slot)
    end
end

function Container:PutAllOfActiveItemInSlot(slot)
    if self.inst.components.container ~= nil then
        self.inst.components.container:PutAllOfActiveItemInSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:PutAllOfActiveItemInSlot(slot)
    end
end

function Container:TakeActiveItemFromHalfOfSlot(slot)
    if self.inst.components.container ~= nil then
        self.inst.components.container:TakeActiveItemFromHalfOfSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:TakeActiveItemFromHalfOfSlot(slot)
    end
end

function Container:TakeActiveItemFromCountOfSlot(slot, count)
    if self.inst.components.container ~= nil then
        self.inst.components.container:TakeActiveItemFromCountOfSlot(slot, count, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:TakeActiveItemFromCountOfSlot(slot, count)
    end
end

function Container:TakeActiveItemFromAllOfSlot(slot)
    if self.inst.components.container ~= nil then
        self.inst.components.container:TakeActiveItemFromAllOfSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:TakeActiveItemFromAllOfSlot(slot)
    end
end

function Container:AddOneOfActiveItemToSlot(slot)
    if self.inst.components.container ~= nil then
        self.inst.components.container:AddOneOfActiveItemToSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:AddOneOfActiveItemToSlot(slot)
    end
end

function Container:AddAllOfActiveItemToSlot(slot)
    if self.inst.components.container ~= nil then
        self.inst.components.container:AddAllOfActiveItemToSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:AddAllOfActiveItemToSlot(slot)
    end
end

function Container:SwapActiveItemWithSlot(slot)
    if self.inst.components.container ~= nil then
        self.inst.components.container:SwapActiveItemWithSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:SwapActiveItemWithSlot(slot)
    end
end

function Container:SwapOneOfActiveItemWithSlot(slot)
    if self.inst.components.container ~= nil then
        self.inst.components.container:SwapOneOfActiveItemWithSlot(slot, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:SwapOneOfActiveItemWithSlot(slot)
    end
end

function Container:MoveItemFromAllOfSlot(slot, container)
    if self.inst.components.container ~= nil then
        self.inst.components.container:MoveItemFromAllOfSlot(slot, container, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:MoveItemFromAllOfSlot(slot, container)
    end
end

function Container:MoveItemFromHalfOfSlot(slot, container)
    if self.inst.components.container ~= nil then
        self.inst.components.container:MoveItemFromHalfOfSlot(slot, container, ThePlayer)
    elseif self.classified ~= nil then
        self.classified:MoveItemFromHalfOfSlot(slot, container)
    end
end

function Container:MoveItemFromCountOfSlot(slot, container, count)
    if self.inst.components.container ~= nil then
        self.inst.components.container:MoveItemFromCountOfSlot(slot, container, count, ThePlayer)
    elseif self.classified ~= nil then
-- ★ 文件在 return Container 处结束——没有独立的 OnRemoveFromEntity。
-- 结合第 78 行的说明可知：期望的销毁钩子被注释掉了，
-- 实际生效的是第 111 行的 OnRemoveEntity，而它**只跑服务端**。
--
-- ★★ 经验：任何「服务端会删、客户端有本地状态」的组件，
--   都必须确认存在一条**在客户端真正生效**的清理路径。
--   本文件是一个很好的对照案例：
--     期望钩子 OnRemoveFromEntity → 被注释（引擎不支持）
--     实际钩子 OnRemoveEntity   → 存在，但被 ismastersim 限制在服务端
--   也就是说**客户端侧没有对称的销毁回调**，
--   只能依赖引擎对已移除实体的界面兜底。
--   读别人的代码时，先确认钩子是否真的在用、跑在哪个端，别读注释掉的。
        self.classified:MoveItemFromCountOfSlot(slot, container, count)
    end
end

--------------------------------------------------------------------------

return Container