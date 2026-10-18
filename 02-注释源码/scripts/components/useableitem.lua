--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/useableitem.lua
-- 模块：组件系统 / 物品使用（UseableItem，无目标端）
-- 职责：「按使用键」类物品的最小协议 —— 资格判定（CanInteract，依赖
--       equippable 副本的已装备状态）、使用中状态（inuse 字段 + inuse 标签）、
--       开始使用（StartUsingItem，回调可返回 false 否决）与停止使用
--       （StopUsingItem）。
-- 【协议四要素】① CanInteract ② StartUsingItem ③ inuse 状态（字段+标签）
--       ④ StopUsingItem。物品交互统一抽象的最小充分集合。
-- 【与 useabletargeteditem.lua 的关系】两个【平行】的独立实现，非继承：
--       本文件无目标（手电筒、药水）；对方有目标（挤奶、喂食）。
--       调度方分别是 actions.lua:3299-3309 与 actions.lua:3338-3350。
-- 关键符号：UseableItem, CanInteract, StartUsingItem, StopUsingItem,
--           SetOnUseFn, SetOnStopUseFn, inuse, onusefn, onstopusefn,
--           stopuseevents
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/useabletargeteditem.lua（有目标端，建议对照阅读）,
--           components/toggleableitem.lua（同类协议的另一个平行实现）,
--           components/equippable.lua 与 inventoryitem_replica（IsEquipped 判定源）,
--           actions.lua（USEITEM / STOPUSINGITEM 动作层调度）,
--           componentutil.lua（makeuseable 之类的批量挂载辅助）
--============================================================
local function oninuse(self, inuse)
-- ============================================================
-- components/useableitem.lua —— 「可直接使用」组件（56 行的极简协议）
--
-- 【这个文件解决什么问题】
-- DST 里「按使用键」有两类完全不同的物品：
--   A. 无目标的：手电筒、治疗药水、工具切换 —— useableitem.lua（本文件）
--   B. 有目标的：给牛挤奶、给 NPC 喂食 —— useabletargeteditem.lua
-- 两者是「同一个协议的两个实现」，共四要素：
--   ① 能不能用（CanInteract）→ ② 开始用（StartUsingItem）
--   → ③ 使用中状态（inuse 字段 + 标签）→ ④ 停止用（StopUsingItem）
-- 本文件是 A 端，B 端见 components/useabletargeteditem.lua。
-- ★ 建议把两个文件对照着读，它们是理解「物品交互统一抽象」的最佳样本。
--
-- 【★ 为什么这个抽象值得学 —— 对自研游戏的三条直接结论】
-- 1) 「能不能用」与「用起来会怎样」彻底解耦：
--    CanInteract（第 33 行）只回答资格，不产生任何副作用；
--    StartUsingItem（第 37 行）才执行。
--    于是「显示提示」可以只调前者，「真正扣道具」只发生在后者。
-- 2) 状态用「字段 + 标签」双写（第 1-7 行的属性钩子）：
--    字段供逻辑判断，标签供 HasTag 式查询（音效/UI/AI 跨系统读取）。
-- 3) 回调返回 false 可以【否决】使用（第 40 行），
--    且否决后 inuse 自动回落为 false —— 见第 39-41 行的巧妙写法。
--
-- 【⚠️ 容易踩的坑】
-- * 本组件【不含任何条件冷却/消耗扣减】，那些都写在 prefab 的回调里。
-- * 第 34 行 CanInteract 依赖 inst.replica.equippable ——
--   意味着「没装备的物品按使用键」会被判为不可交互（静默无反应）。
-- ============================================================

-- 属性钩子：inuse 字段被赋值时同步标签。
-- ★ 注意方向：true → AddTag，false → RemoveTag。
--   用 if/else 而非 AddOrRemoveTag，是与 useabletargeteditem.lua 第 18 行
--   写法的风格差异（那边用了 AddOrRemoveTag）。两种都对，
--   但同一工程内不统一会让读代码的人多花一次确认。
-- ★ 「inuse」标签的消费者：装备栏图标灰显、角色说话时收起手持物、音效。
--   这些都是【跨系统】读取，所以必须走标签而不是直接摸组件字段。
    if inuse then
        self.inst:AddTag("inuse")
    else
        self.inst:RemoveTag("inuse")
    end
end

local UseableItem = Class(function(self, inst)
-- 构造函数。第 11-14 行四个字段全部给了显式初值。
-- ⚠️ 第 14 行 stopuseevents 从未被本文件【写入】过 ——
--   它是个预留的外部钩子字段（某个 prefab 直接写 self.stopuseevents = fn）。
--   本轮全库搜索未找到给它赋值的调用方，标为未核实。
	self.inst = inst
	self.onusefn = nil
	self.onstopusefn = nil
	self.inuse = false
	self.stopuseevents = nil
end,
nil,
{
    inuse = oninuse,
})

function UseableItem:OnRemoveFromEntity()
-- OnRemoveFromEntity：摘掉 inuse 标签，防止实体被回收后标签残留。
-- ⚠️ 注意它【只摘标签，不调 onstopusefn】：
--   也就是说物品在被移除时不会触发「停止使用」的回调。
--   对「喝药过程中物品被销毁」这类边缘情况，回调里的清理逻辑不会跑。
--   这是「回调 vs 清理」分离的常见取舍：本组件只管标签，对外行为由 prefab 兜底。
    self.inst:RemoveTag("inuse")
end

function UseableItem:SetOnUseFn(fn)
	self.onusefn = fn
end

function UseableItem:SetOnStopUseFn(fn)
	self.onstopusefn = fn
end

function UseableItem:CanInteract(doer)
-- ★★★ CanInteract(doer) —— 「能不能用」的唯一判定口。
--   三个条件全满足才返回 true：
--   a) 当前不在使用中（第 34 行前半）；
--   b) 有 equippable 副本组件；
--   c) 该副本【处于装备状态】。

-- 【⚠️ 第 c 条是最容易误解的地方】
--   IsEquipped() 问的是「这个物品现在是否被穿在身上」，
--   而【不是】「这个物品是否被 doer 装备」。
--   也就是说它没有校验 doer 与实际持有者是否一致。
--   推断依据：本组件挂在物品身上，而物品在客户端的装备状态是全局事实，
--   所以「已装备」本身就隐含了「被某个角色装备着」。
-- ⚠️ doer 参数在函数体内【完全没被使用】 —— 但调用方照样传它：
--   actions.lua 第 3300 行 useableitem:CanInteract(act.doer)。
--   对比 toggleableitem.lua 第 13-15 行的 CanInteract(doer) 直接 return true。
--   ★ 这是为「将来要做『谁按的』判断」预留的扩展点（DST 大量用这种预留签名）。
--   （本人已对照 actions.lua:3300 与 components/toggleableitem.lua:13-15 核实。）

-- 【★ 为什么必须查副本的 equippable 而不是本地的】
--   因为「是否装备」这个事实由客户端 UI 侧驱动，服务端的 equippable
--   未必与客户端同步到位。查副本组件相当于「问客户端的答案」。
-- ⚠️ 风险：若实体没有 equippable 副本（如纯服务端实体），
--   第 34 行的副本判空条件为假，整式变 false，
--   表现为「按使用键毫无反应」而不是报错。
--   ★ 排查提示：物品「没反应」时先确认它到底是不是 equippable 的。
    return not self.inuse and self.inst.replica.equippable ~= nil and self.inst.replica.equippable:IsEquipped()
end

function UseableItem:StartUsingItem()
-- ★★★ StartUsingItem —— 「开始使用」。

-- 【★ 第 38-41 行的三行技巧是本文件最值得学的地方】
--   第 38 行：先乐观地置 inuse = true；
--   第 39 行：有回调就调它；
--   第 40 行：把【回调的返回值】再赋回 inuse。
--   于是形成语义：回调返回 false → inuse 被回落为 false；
--                        回调返回 nil（没写 return）→ 保持 true。
-- ⚠️ 关键陷阱：写成 if 回调返回值 then self.inuse = true end
--   会把「回调没写 return」的常见写法判成失败。
--   现在这个写法用「用返回值覆盖」而不是「用返回值决定」，
--   正确处理了 Lua 里「nil 与 true 都不是 false」这一事实。
-- ★ 判定用的是「不等于 false」而不是逻辑非：
--   无 return（nil）→ 不等于 false → 保持 inuse。
--   返回 0 或空串 → 同样视为「使用成功」。
-- ⚠️ 这个宽松判定是刻意的：绝大多数 onusefn 只是「做点事」不返回值，
--   若严格要求返回 true，prefab 侧会到处踩坑。

-- 【第 43-45 行：第二个钩子，与 onusefn 语义完全不同】
--   onusefn       = 「要做什么」（药水回血、切换工具）
--   stopuseevents = 「开始使用时要监听哪些全局事件」（如等 1.5 秒后自动关手电筒）
-- ⚠️ 名字极易误解：stopuseevents 在【开始】时被调用，不是停止时。
--   它是「注册停止条件」，由 prefab 自行实现（内部大概会 ListenForEvent）。
--   本轮未找到给它赋值的 prefab，标为未核实。

-- 【第 46 行：返回值】
--   StartUsingItem 的返回值会直接被 actions.lua 第 3309 行 return 给动作层，
--   动作层据此决定动作成功与否。返回 false 会触发动作失败（播手势/提示）。
--   （本人已对照 actions.lua:3306-3309 核实：ret 被直接 return。）
	self.inuse = true
	if self.onusefn then
		self.inuse = self.onusefn(self.inst) ~= false
	end

	if self.stopuseevents then
		self.stopuseevents(self.inst)
	end
	return self.inuse
end

function UseableItem:StopUsingItem()
-- ★ StopUsingItem：与 StartUsingItem 对称的收尾。
--   第 50 行【先】置 inuse = false，【后】调 onstopusefn。
-- ★ 顺序含义：回调内部若再查实体的 inuse 标签，会看到已经摘掉了。
--   与 StartUsingItem 的顺序（先置 true 再回调）保持一致，
--   回调里读到的永远是【本次操作后的状态】。
-- ⚠️ 与 StartUsingItem 不同，这里没有把回调返回值覆盖回 inuse：
--   onstopusefn 无法「否决」停止。这意味着「停下」是强制的。
--   这是对的 —— 停止往往是资源清理（关手电筒、取消吟唱），不该被否决。
-- ⚠️ 没有对称的幂等保护：重复调 StopUsingItem 会重复调 onstopusefn。
--   推断调用方（actions.lua STOPUSINGITEM，第 3357-3362 行）保证配对。
--   （本人已对照 actions.lua:3357-3362 核实该动作只调 StopUsingItem。）
	self.inuse = false
	if self.onstopusefn then
		self.onstopusefn(self.inst)
	end
end
-- 文件结束。全文 56 行，是 components/ 下最小的协议类组件之一。
-- ★ 但它承载了「物品交互统一抽象」的最小充分集合：
--   资格判定 + 状态字段 + 状态标签 + 开始回调 + 停止回调 + 开始时注册停止条件。
--   自研游戏照抄这六个要素即可覆盖大部分「按使用键」物品。
--   剩下的（多阶段、蓄力、目标选择）由 useabletargeteditem.lua 与
--   bufferedaction 体系补足。

-- 【★ 与 useabletargeteditem.lua 的差异对照（迁移时最容易搞混）】
--   本文件 useableitem.lua            目标端 useabletargeteditem.lua
--   ------------------------------------------------------
--   StartUsingItem() 无参             StartUsingItem(target, doer) 两参
--   CanInteract(doer) 用 doer         CanInteract() 完全无参
--   StartUsingItem 返回 1 个值       StartUsingItem 返回 2 个值（success, reason）
--   inuse 乐观预置再覆盖（第 40 行）  inuse_targeted 成功后置（对方第 122-126 行）
--   单一状态开关                     另有 inventory_disableable / canselftarget 副状态
-- ★★★ 结论：这不是「基类 + 子类」，而是两个【平行】的独立实现。
--   它们共享「四要素协议」，但代码毫无继承关系，靠 actions.lua 分别调度：
--   actions.lua:3299-3309 走 useableitem；
--   actions.lua:3338-3350 走 useabletargeteditem。
-- ⚠️ 自研游戏若要统一抽象，应把二者收敛为一个带「有无目标」分支的组件，
--   或定义一个薄接口让两者都实现 —— 而不是像 DST 这样各写一遍。
--   DST 选择平行实现的原因推测是：两者状态语义差异太大（见上表后两行），
--   强行合并会让每个物品都要处理无关分支。

return UseableItem