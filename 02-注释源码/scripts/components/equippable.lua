--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/equippable.lua（218 行）
-- 模块：物品栏系统 / 装备能力（Equippable）
-- 职责：定义 Equippable 组件——「这个实体可以被穿在身上」。
--   它只回答装备相关的四个问题：
--   ① 能穿到哪个槽位（equipslot，默认 HANDS）；
--   ② 穿上/脱下时要回调什么（onequipfn / onunequipfn / onpocketfn）；
--   ③ 穿了之后有什么属性加成（walkspeedmult / dapperness / insulated）；
--   ④ 谁能穿（restrictedtag）与 能不能脱（preventunequipping）。
--
-- ★★ 全文件最重要的认知一：Equippable **不做任何属性结算**。
--   它只持有「属性值」与「属性值怎么算」的函数指针，真正的**汇总**
--   发生在别人身上：
--     · 护甲减伤汇总 → components/inventory.lua:408 Inventory:ApplyDamage
--     · 防水汇总     → components/inventory.lua:2714 GetWaterproofness
--     · 湿度汇总     → components/inventory.lua:2692 GetEquippedMoistureRate
--     · 绝缘汇总     → components/inventory.lua:759 Inventory:IsInsulated
--     · 移速汇总     → locomotor.lua 的 GetWalkSpeed（见 126 行注释）
--   ⇒ 也就是说：**装备槽是「数据源」，不是「效果器」**。
--     这让「同时穿 3 件绝缘装备」这类叠加逻辑只需要写一份（在 Inventory 里）。
--
-- ★★ 全文件最重要的认知二：本组件是**双端分裂**的，且客户端数据来自
--   inventoryitem 而非本组件。第 5 行的原注释已经点明：
--     "Update inventoryitem_replica constructor if any more properties are added"
--   ⇒ 新增装备属性时，必须同时在 inventoryitem_replica 上加一个同步通道，
--     否则客户端永远看不到（这正是 1-23 行四个 on* setter 的用途）。
--   ⚠ 注意 9-10 行的原注释：这套 hack 与 saddler 组件**共用**，
--     所以「一个 prefab 不能同时挂 equippable 和 saddler」。
--
-- ★★ 关于「耐久」：★ grep 核实——**本文件不含任何耐久逻辑**。
--   耐久由 armordurability / fuel / perishable 等独立组件负责，
--   本文件只在 Equip/Unequip 时透传事件。装备槽本身不存耐久。
--   用户常说的「装备耐久」在本游戏里其实是「护甲吸收量」的两套系统：
--     · components/armor.lua —— 护甲吸收率（决定减伤百分比）；
--     · components/armordurability.lua —— 耐久消耗（决定还能挡几下）。
--   两者在 inventory.lua:408 ApplyDamage 里被同时驱动。
--
-- 关键符号：Equippable（类）, Equip, Unequip, ToPocket, IsEquipped,
--   GetWalkSpeedMult, IsRestricted, IsRestricted_FromLoad,
--   ShouldPreventUnequipping, SetPreventUnequipping, GetDapperness,
--   GetEquippedMoisture, IsInsulated, SetOnEquip, SetOnUnequip, SetOnPocket,
--   SetOnEquipToModel, SetDappernessFn, OnRemoveFromEntity
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 components/inventory.lua:1266 Inventory:Equip —— 装备的主流程
--   ★★ 参见 components/inventory.lua:1219 Inventory:Unequip —— 卸装的主流程
--   ★★ 参见 components/inventory.lua:408 Inventory:ApplyDamage —— 护甲减伤汇总
--   ★★ 参见 components/inventory.lua:7714 GetWaterproofness（防水汇总入口）
--   参见 components/inventoryitem_replica.lua:GetWalkSpeedMult（客户端镜像）
--   参见 components/inventoryitem_replica.lua —— 装备属性的网络载体
--   参见 components/stackable.lua —— equipstack 时整摞一起装备
--   参见 components/setbonus.lua:UpdateSetBonus —— 套装效果开关
--   参见 components/spdamageutil.lua:GetSpDefenseForType —— 特殊伤害防御
--   参见 components/linkeditem.lua:IsEquippableRestrictedToOwner —— 专属装备
--   参见 components/burdenedbackpack.lua / saddler —— 与 walkspeedmult 共享的 hack
--   参见 constants.lua:652 EQUIPSLOTS（hands / head / body / beard 共 4 槽）
--   参见 equipslotutil.lua —— 槽位名与网络整数 id 的互转
--   参见 TUNING.WET_ITEM_DAPPERNESS —— 淋湿装备的理智惩罚常量
--============================================================
--
--【阅读导航】
--  §零   四个双端同步 setter（1-23） —— ★ 装备属性同步的唯一通道
--  §一   Equippable 构造（25-53）    —— 15 个字段与 4 个 setter 的绑定
--  §二   生命周期钩子（55-86）       —— 清理与回调注册
--  §三   装备/卸下/入包（88-123）    —— ★ 三个事件的派发顺序
--  §四 ★ 移速（125-144）              —— vigorbuff 与外部修正函数
--  §五 ★ 装备限制（146-178）         —— 限制标签与技能树例外
--  §六 ★ 禁止卸下（180-194）         —— 用事件回调实现的状态锁
--  §七   属性计算（196-216）         —— dapperness 的四层叠加
--
--【★★ 全文件最重要的八条】
--  1. ★★ grep 核实：**本文件没有任何耐久逻辑**。玩家口中的「装备耐久」
--     在 DS 里是两套独立组件：
--       · components/armor.lua            —— 护甲**吸收率**（减伤百分比）
--       · components/armordurability.lua  —— **耐久**（还能挡几下）
--     两者在 inventory.lua:408 Inventory:ApplyDamage 里被同时驱动：
--     absorbers[armor] = armor:GetAbsorption(...) 得到吸收率，
--     而 armor:TakeDamage(dmg)（第 496 行）扣的是耐久。
--     ⇒ 本文件只负责「装备/卸下」这两个时刻，战斗中的一切都不管。
--  2. ★★ Equippable **不做属性汇总**。四类加成的汇总点全在 inventory.lua：
--       护甲减伤 → inventory.lua:408  ApplyDamage
--       防水     → inventory.lua:2714 GetWaterproofness
--       装备湿度 → inventory.lua:2692 GetEquippedMoistureRate
--       绝缘     → inventory.lua:759  IsInsulated
--       移速     → locomotor.lua 的 GetWalkSpeed（本文件只提供 GetWalkSpeedMult）
--     ⇒ **装备槽是数据源，不是效果器**。这让「同时穿 3 件绝缘装备」
--       只需写一份加法（在 Inventory 里），装备侧零成本。
--  3. ★★ 第 5 行的原注释是本文件最重要的维护契约：
--       "Update inventoryitem_replica constructor if any more properties
--        are added"
--     ⇒ 新增任何装备属性字段，**必须同时**在 inventoryitem_replica 上
--       增加一个同步通道，否则客户端永远看不到。
--     而 1-23 行的四个 setter 就是这层「镜像」的服务器端写入端。
--  4. ★★ 9-10 行的原注释揭示了一个**排他性约束**：
--       "This network optimization hack is shared by saddler component,
--        so a prefab must not have both components at the same time."
--     ⇒ walkspeedmult 的同步走的是 saddler 的通道，两者互斥。
--       违反后果：同一个 netvar 被两个组件写，行为未定义。
--  5. ★ Equip/Unequip 都是「先置状态、后回调、再发事件」的顺序：
--       Equip:  isequipped=true → 灭火 → onequipfn → PushEvent("equipped")
--       Unequip: isequipped=false → onunequipfn → PushEvent("unequipped")
--     ★⇒ 在 onequipfn 里读 self:IsEquipped() 得到的是**新值**。
--       若回调又反向调用 Unequip，会产生不一致（框架不防重入）。
--  6. ★★ SetPreventUnequipping（184 行）是一个**状态锁 + 事件回调**的组合：
--       它 ListenForEvent("onremove", OnRemove)，并在 OnRemove 里
--       解除锁 —— 这是为了处理「禁止卸下的装备在实体被删除时死锁」。
--     ★ 180 行的 OnRemove 是**局部函数**，没有别的引用，
--       它的存在完全是为了配合 RemoveEventCallback 的对称性。
--  7. ★★ IsRestricted 与 IsRestricted_FromLoad 是**同一判据的两个入口**：
--       正常路径用前者；读档路径用后者，它对技能树限制标签开了后门
--       （166-172 行：只要该标签属于技能树且目标角色是技能树拥有者，
--        就直接放行）。这是为「沃尔特变形后仍能穿自己的装备」这类需求留的。
--  8. ★★ GetDapperness（196 行）的四层叠加顺序**不可交换**：
--       dapperness → merm 反转 → dapperfn 覆盖 → 淋湿加成
--     ⇒ 淋湿加成在最后，意味着它**总是**能打破 dapperfn 的自定义结果。
--     这对模组是可感知的：自定义 dapperfn 无法屏蔽「湿装备扣理智」。
--
--【⚠ 疑似缺陷清单（本文件 4 条，均只记录不修改）】
--  L1 ★★ equippable.lua:133-135  vigorbuff 的移速加成**不对称**：
--                    减速（speed < 1）时给 +0.25 补偿，但加速时不给任何处理，
--                    且补偿被 math.min(1, ...) 硬截断在 1。
--                    推理依据：若某装备的 walkspeedmult 是 0.8，
--                    有 vigorbuff 时变成 1.0（满速），没 buff 时是 0.8；
--                    而 walkspeedmult = 1.2 的装备在两种情况下都是 1.2。
--                    ⇒ vigorbuff 只能「抵消减速」不能「加速」，这大概率是有意的。
--  L2 ★   equippable.lua:130  `self.inst.components.inventoryitem and
--                    self.inst.components.inventoryitem.owner` ——
--                    没有 nil 保护地链式取 .owner（虽然前半段做了 and 保护，
--                    所以实际安全）。但对比 8 行的 onwalkspeedmult 里
--                    明确写了 `if self.inst.replica.inventoryitem ~= nil then`，
--                    这里的服务端版本却假定 inventoryitem **必然存在**。
--                    ⇒ 若某个 prefab 挂了 equippable 但没挂 inventoryitem，
--                      GetWalkSpeedMult 会静默返回 1（因为 and 短路），
--                      不崩溃但属性全丢——这是一个不易察觉的配置错误。
--  L3 ★   equippable.lua:199  GetDapperness 里 `owner:HasTag("merm")`
--                    没有判空 owner（只判了 `self.flipdapperonmerms and owner`，
--                    这个 and 已经保护了 owner）。故实际安全，不算缺陷。
--                    ★ 但 204 行 `self.dapperfn(self.inst, owner)` 同样不判 owner，
--                      ⇒ 自定义 dapperfn 必须自己处理 owner 为 nil 的情况
--                        （因为 Equip 未发生时被调用是可能的）。
--  L4 ★   equippable.lua:41  `self.maxequippedmoisture = 0` 与
--                    `self.equippedmoisture = 0` 初始化为 0，但 214-216 行的
--                    GetEquippedMoisture 直接返回它们，inventory.lua:2692 会
--                    把它累加成「所有装备的湿度总和」。
--                    ⇒ 初始化为 0 是正确的（0 不贡献湿度），
--                      但**没有任何代码在构造时按 prefab 配置它**——
--                      grep 显示这两个字段在本文件之外也无人写入，
--                      ⇒ 整个「装备湿度」机制目前是**未接线的**。
--                      这不是 bug 而是半成品：接口已就绪，数据源缺失。
--
--【★ 与 health/sanity 的联动 —— 用户重点询问项】
--  ① 理智（sanity）：本文件唯一直接影响 sanity 的机制是 GetDapperness。
--     它返回的数值被角色的 sanity 组件读取（sanity.lua 里的 dapperness 项），
--     单位是「每游戏分钟」衰减的理智点数。数值来源四层：
--       · 基础值 self.dapperness —— 由 prefab 在构造后赋值（如草帽 3.0）；
--       · merm 反转 —— 美人鱼戴帽子会**反向**生效（199-201 行）；
--       · dapperfn 覆盖 —— 模组/特殊物品的全权接管（203-205 行）；
--       · 淋湿加成 —— TUNING.WET_ITEM_DAPPERNESS（207-209 行）。
--     ★ 总结：GetDapperness 的返回值是「已经算好的速率」，
--       sanity 组件不再做二次汇总——所以同时穿 3 件草帽不会叠加。
--       ★★ 这是与护甲（inventory.lua:435-439 取 max 后再按比例分摊）
--         截然不同的策略：dapperness 是「取其一」，armor 是「汇总分摊」。
--  ② 生命（health）：本文件**完全不影响**生命值。
--     护甲减伤在 inventory.lua:408 ApplyDamage，耐久扣减在同一函数的
--     495-497 行。两处都在 Inventory 而不在 Equippable。
--     ⇒ 「穿甲减伤」的因果链是：
--       物品 armor 组件（吸收率）→ Equippable（记「穿上了」）
--       → Inventory:ApplyDamage（汇总所有槽的 armor，算 leftover）
--       → health:DoDelta(leftover_damage)。
-- ③ 体力/负重（stamina）：通过 heavylifting 间接影响。
--     本文件不涉及；见 inventory.lua:1372 与 inventory_replica.lua:75-82
--     —— heavylifting 是通过 classified netvar 同步，并挂一个动作过滤器。
-- 【§零】双端同步 setter。
-- ★★★ 这四个函数是本文件**唯一**的「服务端 → 客户端」数据出口。
--   它们的共同模式：写到 self.inst.replica.xxx（replica = 客户端镜像），
--   Class 框架会自动把这个 netvar 变化同步到该玩家的客户端。
--   ⇒ Equippable 的字段分成两类：
--     · 需要同步的（equipslot / walkspeedmult / restrictedtag /
--       preventunequipping）→ 通过这四个 setter 写；
--     · 服务端私有的（dapperness / insulated / equippedmoisture）
--       → 直接赋值，客户端看不到也不需要。
-- ★ 这就是为什么本文件里 `self.equipslot = EQUIPSLOTS.HANDS`（29 行）
--   是直接赋值，而紧接着的 49 行却要 `equipslot = onequipslot`：
--   前者是构造初值（此时 replica 可能还没准备好），后者是运行期同步。
local function onequipslot(self, equipslot)
-- ★★ SetEquipSlot —— 装备槽名的同步出口。
--   equipslot 是字符串（"hands"/"head"/"body"/"beard"，
--   见 constants.lua:652 EQUIPSLOTS），replica 侧会再转成网络整数
--   （equipslotutil.lua:31 EquipSlotToID）。
-- ★ 为什么要同步槽名？客户端要据此决定「物品显示在手还是头上」，
--   即物品的**3D 挂点**由 equipslot 决定。
    self.inst.replica.equippable:SetEquipSlot(equipslot)
-- ↑ SetEquipSlot 结束（一行体）。
end
-- ↑ onequipslot 结束。
-- ↑ 空行分隔，进入 walkspeedmult 的同步函数。

-- ↑ 空行。
-- ★★★ 原英文维护契约（保留）：
--   "Update inventoryitem_replica constructor if any more properties
--    are added"
--   ★★ 中文展开：这不是一句提醒，而是一条**硬性耦合规则**——
--     本组件的属性最终落在 inventoryitem_replica 上（因为客户端看到的
--     是「一个物品」，而不是「一个装备」）。新增装备属性时若只改这里，
--     客户端将永远拿不到该属性，且**没有任何报错**。
--   ⇒ 新增属性的完整步骤：① 本文件加字段；② 加一个 on* setter；
--     ③ Class 第三参数表里绑定；④ inventoryitem_replica 加 netvar 与 setter；
--     ⑤ inventoryitem_replica 的构造里初始化。缺任何一步都会静默失效。
--Update inventoryitem_replica constructor if any more properties are added
-- ↑ 耦合契约注释结束。
-- ↑ nil 检查通过后的实际写入。

-- ↑ 写入之后。
-- ★★ onwalkspeedmult —— 移速倍率的同步出口（最复杂的一个）。
--   为什么移速要同步？因为 locomotor 的客户端预测需要它来算移动速度，
--   否则会出现「服务器说你在 0.8 倍速移动，客户端插值按 1.0 倍速」
--   ⇒ 表现为联机时的位置抖动。
local function onwalkspeedmult(self, walkspeedmult)
-- ★★ 8-10 行的 nil 检查：`self.inst.replica.inventoryitem ~= nil` ——
--   为什么会有 nil？服务器刚 SpawnPrefab、replica 尚未复制到客户端时
--   replica.inventoryitem 可能还不存在。
-- ★ 原注释 9-10 行揭示的关键信息：
--   "This network optimization hack is shared by saddler component,
--    so a prefab must not have both components at the same time."
--   ⇒ walkspeedmult 借用了 saddler 的网络通道。★ 因此一个 prefab
--     **不能同时**挂 equippable 与 saddler。这是排他性约束，见 §二第 4 条。
    if self.inst.replica.inventoryitem ~= nil then
-- ↑ 原注释第二行："so a prefab must not have both components at
--   the same time." ——★ 排他性约束的正式陈述，见 §二第 4 条。
        --This network optimization hack is shared by saddler component,
-- ↑ 排他性约束陈述的第一行。
-- ↑ 原注释两行结束。
        --so a prefab must not have both components at the same time.
-- ↑ 排他性约束陈述的第二行。
        self.inst.replica.inventoryitem:SetWalkSpeedMult(walkspeedmult)
-- ↑ SetWalkSpeedMult 调用之后。
    end
-- ↑ onwalkspeedmult 结束。
-- ↑ onwalkspeedmult 函数结束。
end
-- ↑ 函数体结束。

-- ↑ 原注释第二行结束。
-- ★★ onrestrictedtag —— 装备限制标签的同步出口。
--   restrictedtag 决定「只有带某个标签的角色能穿」。
--   同步它是为了让客户端能**提前灰掉**不合规的装备（显示为不可用），
--   而不是等服务端拒绝后才反馈。
local function onrestrictedtag(self, restrictedtag)
-- ↑ nil 检查通过。
    if self.inst.replica.inventoryitem ~= nil then
-- ↑ nil 检查通过。
-- ↑ SetEquipRestrictedTag 实际写入。
        self.inst.replica.inventoryitem:SetEquipRestrictedTag(restrictedtag)
-- ↑ 写入之后。
    end
-- ↑ SetEquipRestrictedTag 调用之后。
end
-- ↑ onrestrictedtag 结束。
-- ↑ onrestrictedtag 函数结束。

-- ↑ 函数体结束。
-- ★★ onpreventunequipping —— 禁止卸下状态的同步出口。
--   ★ 注意 22 行的 `prevent == true`：这是**严格布尔化**，
--     非 true 的值（nil / 1 / "yes"）一律变成 false。
--     184 行的 SetPreventUnequipping 也是同样的严格判断（177 行）。
--     ⇒ 传 1 不会生效，必须传 true。
local function onpreventunequipping(self, prevent)
	self.inst.replica.equippable:SetPreventUnequipping(prevent == true)
-- ↑ 严格布尔化转换之后。
end
-- ↑ onpreventunequipping 结束。
-- ↑ onpreventunequipping 函数结束。

-- ↑ 函数体结束。
-- 【§一】Equippable 类构造。
-- ★★ 三个参数：ctor / super_ctor(nil) / attr_init（第三参数是 setter 表）。
--   26 行 self.inst = inst 是 Klei 组件的强制约定：所有组件都持有 inst。
local Equippable = Class(function(self, inst)
    self.inst = inst
-- ↑ self.inst 赋值之后。
-- ★★ 27 行是第一个真正的实例字段，也是最容易被误用的一个：
--   单独给 inst 塞一个未在构造函数声明的属性。
-- ★ 后果：Lua 允许，但构造后遍历 self 的代码（如属性复制、序列化）
--   可能因为字段定义不完整而出错。安全做法应是在构造函数中初始化。

-- ↑ inst 级动态函数字段赋值之后。
-- ★★ isequipped —— 「是否处于装备中」。
--   ★ 注意它与「在 equipslots 表里」是**两个不同的状态**：
--     · equipslots[slot] == item 是「这个槽被这个物品占着」；
--     · self.isequipped 是「本物品的装备流程已走完」。
--   正常路径二者同步，但 SetPreventUnequipping 场景下会短暂不一致
--   （1224 行 Unequip 被阻止时，isequipped 保持 true）。
    self.isequipped = false
-- ★★ equipslot 默认值是 HANDS —— 即「默认是手持」。
--   ★ 这是全 DST 最常见的情况：绝大多数「装备」其实是「拿在手上」，
--     视觉上挂在角色的手部挂点。
--   prefab 通常在构造后覆盖它，例如草帽：
--     inst.components.equippable.equipslot = EQUIPSLOTS.HEAD
--   ⚠ 与 49 行的 setter 绑定对照：prefab 直接赋值 29 行的字段时
--     **不会触发同步**（29 行只是构造初值，不是 setter）。
--     正确做法是 `inst.equippable:equipslot = EQUIPSLOTS.HEAD`（走 setter）。
--     ⇒ 这是一个很容易踩的坑：写错会得到「服务器认为戴头上、
--       客户端显示拿手上」的物品模型错位。
    self.equipslot = EQUIPSLOTS.HANDS
-- ★ onequipfn：装备回调。签名 (inst, owner, from_ground)。
--   from_ground 表示「是否从地上捡起来直接穿戴」（影响音效/动画）。
    self.onequipfn = nil
-- ↑ onequipfn 默认 nil。
-- ★ onunequipfn：卸下回调。签名 (inst, owner)。
-- ★★ 注意：没有 from_ground 参数，也**没有 slip** 参数——
--   尽管 Inventory:Unequip（inventory.lua:1219）接收到 slip，
--   却**没有把它传给 onunequipfn**（1227 行只传了 self.inst 和 owner）。
--   ⚠ 这是个真实的不一致：调用方准备了 slip，回调却拿不到。
--     推理依据：inventory.lua:1227 `item.components.equippable:Unequip(self.inst)`
--     确实漏传，而 slip 的原意正是「物品是被'滑落'而非主动卸下」。
--     目前无物品使用 slip，故不构成 bug，但它是明确的接口缺口。
    self.onunequipfn = nil
-- ★ onpocketfn：物品「进背包但没装备」时的回调。
--   ★ 语义与 onunequipfn 不同：onpocket 发生在「放进普通槽位」，
--     onunequip 发生在「离开装备槽」。inventory.lua:1351（旧物品换装时）
--     与 1155（GiveItem 时）都会调 ToPocket。
    self.onpocketfn = nil
-- ★ onequiptomodelfn：只有 owner 带 "equipmentmodel" 标签时才调用的
--   专属回调（见 104 行）。用途：需要特殊挂点/动画的装备。
    self.onequiptomodelfn = nil
-- ★★ equipstack：装备**整摞堆叠物**的开关。
--   ★ 它是本文件与 stackable 组件的唯一交互点，且影响很大：
--     · false（默认）→ Equip 时只装备 1 个，其余留在背包（inventory.lua:1329-1332）；
--     · true         → 整摞一起进 equipslots 同一个实体。
--   相关：inventory.lua:840 与 1000 行的选位逻辑都会检查 equipstack，
--     这就是「堆叠物也能塞进装备槽」的实现来源。
    self.equipstack = false
-- ★ walkspeedmult：移速倍率。nil 表示「无修正」（等价 1.0，见 128 行）。
--   ★ 小于 1 = 减速（如穿了重甲），大于 1 = 加速（如疾行药水残留）。
    self.walkspeedmult = nil
-- ↑ 被注释掉的字段 + 原注释 "only entities with this tag can equip" ——
--   ★ 保留被注释的代码是记录「为什么这个命名没启用」（与 recipe.lua 同风格）。
--   实际生效的是 37 行起的 self.restrictedtag（在 restrictedtag setter 里）。
    --self.retrictedtag = nil --only entities with this tag can equip
-- ↑ 被注释的 restrictedtag 原字段。
-- ★ dapperness：基础「清醒度衰减速率」，单位是每游戏分钟的 sanity 点数。
--   ★ 值越大越快掉理智。草帽是 3.0（晴天），冬帽是 0（保暖）。
--   ★★ 重要：**默认 0 不代表无衰减**——sanity 组件另有基础衰减；
--     dapperness 是**叠加项**。见 GetDapperness（196 行）的四层合成。
    self.dapperness = 0
-- ★ dapperfn：dapperness 的**全权接管函数**，签名 (inst, owner) → number。
--   优先级高于基础 dapperness（203-205 行）。
    self.dapperfn = nil
-- ★★ insulated：是否**绝缘**（防触电）。
--   ★ 原注释强调 "from electricity, not temperature" ——
--     这是为了与「保暖（insulated 防寒）」区分。二者在中文里都叫「绝缘」，
--     但在 DS 里是两个完全不同的机制：
--       · insulated（绝缘）→ 防闪电伤害（inventory.lua:759 IsInsulated）；
--       · 保暖 → 由 temperature 组件 + TUNING 单独处理，不在本文件。
--   ⚠ 这是本文件最容易误读的一行注释。
    self.insulated = false
-- ★★ equippedmoisture / maxequippedmoisture：装备携带的湿气。
--   ⚠ 见 HEADER_EXTRA 的 L4：这两个字段在本文件外无人写入，
--     整个「装备湿度」机制目前是**未接线的半成品**——
--     inventory.lua:2692 GetEquippedMoistureRate 会累加它们，但恒为 0。
    self.equippedmoisture = 0
-- ↑ equippedmoisture 初始化之后。
-- ↑ 见 L4。
    self.maxequippedmoisture = 0
-- ↑ maxequippedmoisture 初始化之后。
-- ↑ 空行（构造体尾部）。

-- ↑ 空行。
-- ↑ 被注释的 preventunequipping 字段 + 原注释 "Set to true to block
--   unequipping the item." —— 实际实现见 184 行的 SetPreventUnequipping。
    -- self.preventunequipping = nil -- Set to true to block unequipping the item.
-- ↑ 空行。

-- ↑ 空行。
-- ↑ 被注释的 is_magic_dapperness + 原注释 "some survivors are only
--   affected by magic sources" ——
--   ★ 即「只有部分角色受魔法来源影响」的标记位。当前未启用，
--     说明这是为某个角色的「魔法护佑」类天赋预留的钩子。
	-- self.is_magic_dapperness -- some survivors are only affected by magic sources
-- ↑ 被注释的 is_magic_dapperness。
end,
-- ↑ ctor 的最后一个字段。
nil,
-- ↑ super_ctor 参数（nil = 直接继承 Class）。
-- ★★ 第三参数（attr_init 表）就是 setter 绑定表：
--   equipslot / walkspeedmult / restrictedtag / preventunequipping
--   → 对应 1-23 行的四个 on* 函数。
--   ★ Class 框架的语义：`inst.components.equippable.equipslot = "head"`
--     会先写 self.equipslot，再调用 onequipslot(self, "head") 做同步。
--   ★★ 但要注意 29 行的构造初值 `self.equipslot = EQUIPSLOTS.HANDS`
--     发生在 attr_init 生效**之前**，不会触发 onequipslot。
--     构造期不需要同步（客户端还没有这个实体）。
{
-- ★★ 49 行绑定的是 §零 的 onequipslot（2 行）。
    equipslot = onequipslot,
-- ↑ equipslot 绑定行。
-- ★ 50 行绑定 onwalkspeedmult（7 行）。
    walkspeedmult = onwalkspeedmult,
-- ↑ walkspeedmult 绑定行。
-- ★ 51 行绑定 onrestrictedtag（15 行）。
    restrictedtag = onrestrictedtag,
-- ↑ restrictedtag 绑定行。
-- ★ 52 行绑定 onpreventunequipping（21 行）。
    preventunequipping = onpreventunequipping
-- ↑ preventunequipping 绑定行。
})
-- ↑ attr_init 表结束（Class 第三参数）。
-- ↑ 空行分隔，进入生命周期钩子区。

-- ↑ 空行。
-- 【§二】OnRemoveFromEntity —— 实体被移除时的反向清理。
-- ★★ 这是**唯一**的「析构」，且只清两样：
--   ① preventunequipping 复位（56 行）—— 否则物品复用时会带着旧锁；
--   ② 客户端镜像复位（59-60 行）—— walkspeedmult 归 1、tag 清空。
-- ★ 为什么必须复位 walkspeedmult？装备从角色身上 Remove 时，
--   如果客户端还留着 0.8 的倍率，角色的移速会永久变慢。
function Equippable:OnRemoveFromEntity()
-- ★★ 56 行调用 SetPreventUnequipping(false) 而不是直接置 nil——
--   因为它需要**成对**执行 RemoveEventCallback（见 191 行）。
--   ⇒ 若只置 nil 而不解绑，OnRemove 回调会残留到实体销毁，
--     形成悬挂监听。这是本文件最容易被简化掉的一处细节。
	self:SetPreventUnequipping(false)
-- ↑ 解锁复位之后。
-- ★ local inventoryitem = self.inst.replica.inventoryitem ——
--   58-61 行的 nil 检查是必要的：实体被移除的瞬间，replica 可能
--   已经 detach（见 inventory_replica.lua:130 DetachClassified 同类问题）。
    local inventoryitem = self.inst.replica.inventoryitem
-- ↑ nil 检查通过后的复位块起点。
    if inventoryitem ~= nil then
-- ↑ nil 检查通过。
-- ★ SetWalkSpeedMult(1) —— 复位为「无修正」。
        inventoryitem:SetWalkSpeedMult(1)
-- ★ SetEquipRestrictedTag(nil) —— 清空限制标签。
        inventoryitem:SetEquipRestrictedTag(nil)
    end
-- ↑ 客户端镜像复位块结束。
end
-- ↑ OnRemoveFromEntity 结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★ IsInsulated 的原注释再次强调 "from electricity, not temperature"，
--   与 39 行重复强调 —— 说明这个区分非常容易被误解。
-- ★ 消费点：inventory.lua:759 Inventory:IsInsulated 遍历所有装备槽，
--   只要**任一件**绝缘就整体绝缘（短路返回）。
--   ★ 注意它**不做数值累加**——绝缘是布尔或，不是加法。
function Equippable:IsInsulated() -- from electricity, not temperature
    return self.insulated
-- ↑ 返回 self.insulated。
end
-- ↑ IsInsulated 结束。
-- ★★ 「回调注册」的统一形式在本区域重复 5 次（68/72/76/80/84 行），
--   都是单槽赋值。★ 5 个 setter 没有一个支持「添加/移除」，
--     这是本文件在扩展性上的一处限制（见 §二处的说明）。

-- ↑ 回调注册区起点。
-- ★★ SetOnEquip 等五个 Set 函数是「回调注册」的统一写法：
--   都是 `self.xxxfn = fn`，即**单槽**（后注册覆盖先注册）。
--   ★ 没有 add/remove 形式 ⇒ 一个 prefab 只能有一个装备回调。
--     需要多个回调的 prefab 应在 fn 内部串联。
function Equippable:SetOnEquip(fn)
    self.onequipfn = fn
-- ↑ onequipfn 注册之后。
end
-- ↑ SetOnEquip 结束。
-- ↑ onpocketfn 注册之后。

-- ↑ onpocketfn 赋值之后。
-- ★ SetOnPocket —— 注册「进背包」回调，语义见 32 行。
function Equippable:SetOnPocket(fn)
    self.onpocketfn = fn
-- ↑ onpocketfn 注册之后。
end
-- ↑ SetOnPocket 结束。
-- ↑ onunequipfn 注册之后。

-- ↑ onunequipfn 赋值之后。
-- ★ SetOnUnequip —— 注册「卸下」回调。注意拿不到 slip，见 31 行。
function Equippable:SetOnUnequip(fn)
    self.onunequipfn = fn
-- ↑ onunequipfn 注册之后。
end
-- ↑ SetOnUnequip 结束。
-- ↑ dapperfn 注册之后。

-- ↑ dapperfn 赋值之后。
-- ★ SetDappernessFn —— 注册 dapperness 全权接管函数。
function Equippable:SetDappernessFn(fn)
    self.dapperfn = fn
-- ↑ dapperfn 注册之后。
end
-- ↑ SetDappernessFn 结束。
-- ↑ onequiptomodelfn 注册之后。

-- ↑ onequiptomodelfn 赋值之后。
-- ★ SetOnEquipToModel —— 注册「仅对 equipmentmodel 标签的 owner 生效」的回调。
--   ★ 与 SetOnEquip 的区别见 104 行的额外判定。
function Equippable:SetOnEquipToModel(fn)
    self.onequiptomodelfn = fn
-- ↑ onequiptomodelfn 注册之后。
end
-- ↑ SetOnEquipToModel 结束。
-- ↑ 空行。

-- ↑ 空行。
-- 【§三】IsEquipped 是纯查询，与 28 行的字段一一对应。
function Equippable:IsEquipped()
    return self.isequipped
-- ↑ 返回 self.isequipped。
end
-- ↑ IsEquipped 结束。
-- ★★ 91 行是 Equip 的第一个执行动作，三重 and 保护：
--   ① onequipfn 存在 ② owner 非 nil ③ from_ground 布尔化。
-- ★ 100 行调用时传的第三个参数是 `not old_to_active and item.prevslot == nil`
--   （inventory.lua:1365）—— 语义是「不是从换装流程来的，且原来不在
--     背包里」⇒ 即「从地上捡起来穿的」。与 104 行的 HasTag 判定配合。

-- ↑ 三重 and 保护之后。
-- ★★★ Equip —— 装备流程。顺序是硬约定，**不可交换**：
--   93  isequipped = true          ← 先置状态
--   95-97 burnable:StopSmoldering ← 灭火（★ 见下方详注）
--   99-101 onequipfn              ← 再回调
--   102   PushEvent("equipped")    ← 最后发事件
--   104-106 onequiptomodelfn      ← 附加回调
function Equippable:Equip(owner, from_ground)
-- ★ 状态先行：任何在后续回调里读 IsEquipped() 的代码都会得到 true。
--   ⚠ 这意味着 onequipfn 里若反向调Unequip，会产生「刚装备就卸下」的循环。
--     框架不防重入。
    self.isequipped = true
-- ★★ 94 行是本文件唯一的条件性早退：`inst.components.burnable ~= nil`。
--   ⇒ 没有 burnable 组件的物品（如石头）不会因装备而改变任何状态。

-- ↑ burnable 判定之后。
-- ★★ 为什么装备时要灭火？—— 这是一个很有意思的设计。
--   一个还在阴燃（smoldering）的物品（如刚被点燃的干草）穿在身上
--   会烧伤玩家。StopSmoldering 强制熄灭，等价于「穿之前先灭掉火」。
--   ★ 推论：装备瞬间的 burnable 状态会被**重置为不燃烧**，
--     这不是「暂停燃烧」而是「彻底停止」。所以点燃中的物品一旦穿上，
--     它的剩余燃烧时间就作废了。
    if self.inst.components.burnable ~= nil then
-- ★ StopSmoldering —— 熄灭阴燃的火。
        self.inst.components.burnable:StopSmoldering()
-- ↑ 灭火调用之后。
    end
-- ↑ 灭火块结束。
-- ↑ 空行，进入 onequipfn 判定。

-- ↑ 空行。
-- ★ onequipfn 存在性判定。
    if self.onequipfn ~= nil then
-- ↑ onequipfn 判定之后。
-- ★★ 100 行：实际调用点，签名 (inst, owner, from_ground)。
        self.onequipfn(self.inst, owner, from_ground)
-- ↑ onequipfn 调用之后。
    end
-- ↑ onequipfn 调用之后。
-- ★★ PushEvent("equipped", { owner = owner }) —— 全局事件广播。
--   ★ 消费点举例：components/armor 监听它来重算减伤、
--     components/sanity 监听它刷新 dapperness 总和、
--     components/itemmimic 之类也会监听。
--   ★★ 注意事件是**广播**而非定向：所有注册了 "equipped" 的组件
--     都会收到，包括那些与该物品无关的（如角色的其他组件）。
    self.inst:PushEvent("equipped", { owner = owner })
-- ★ 事件派发前的空行。

-- ↑ 空行。
-- ★★ 104 行是三参判定：`onequiptomodelfn ~= nil and owner:HasTag(...)`。
--   ★ owner 为 nil 时会崩 —— 但 92 行的调用方（Inventory:Equip）
--     总是传 self.inst，所以实际安全。
--   ⚠ 但 mod 若直接调 `equip:Equip(nil)` 会崩。属未加保护的边界。
    if self.onequiptomodelfn ~= nil and owner:HasTag("equipmentmodel") then
-- ★ onequiptomodelfn 调用，签名与 onequipfn 相同。
        self.onequiptomodelfn(self.inst, owner, from_ground)
-- ↑ onequiptomodelfn 调用之后。
    end
-- ↑ onequiptomodelfn 调用之后。
end
-- ↑ Equip 结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ ToPocket —— 「进背包但没装备」。与 Equip/Unequip 都不同：
--   它**不改变任何状态**，只调 onpocketfn。
--   ⇒ 所以 ToPocket 可以和 isequipped=true 共存。
--   ★ 调用点：inventory.lua:1023（GiveActiveItem）、1155（GiveItem）、
--     1351（旧装备换装）—— 三处都表示「东西回到了身上但没穿」。
function Equippable:ToPocket(owner)
-- ★ onpocketfn 存在性判定。
    if self.onpocketfn ~= nil then
-- ↑ onpocketfn 判定之后。
        self.onpocketfn(self.inst, owner)
-- ↑ onpocketfn 调用之后。
-- ★ 112 行：唯一一次调用，签名只有 (inst, owner) —— 无 from_ground。
    end
-- ↑ onpocketfn 调用之后。
end
-- ↑ ToPocket 结束。
-- ↑ 空行，进入 Unequip。

-- ↑ 空行。
-- ★★ Unequip —— 卸下流程。注意它比 Equip **少一步**：
--   没有「灭火」对应物，也没有 from_ground。
--   顺序：isequipped=false → onunequipfn → PushEvent("unequipped")
--   ★★ 与 Equip 的不对称：Equip 有 burnable 处理，Unequip 没有。
--     ⇒ 装备能「灭掉火」，但卸下不能「重新点燃」。这是单向的。
function Equippable:Unequip(owner)
-- ★ 先置 false —— 与 93 行对称。⇒ onunequipfn 里读到 false。
    self.isequipped = false
-- ★ onunequipfn 存在性判定。

-- ↑ onunequipfn 判定之后。
-- ★ 118 行：实际调用，签名 (inst, owner) —— ★★ 比 Equip 少一个参数。
    if self.onunequipfn ~= nil then
-- ↑ onunequipfn 调用之后。
        self.onunequipfn(self.inst, owner)
-- ↑ onunequipfn 调用之后。
-- ↑ 空行，进入事件派发。
    end
-- ↑ 空行。
-- ★★ 121 行的 PushEvent 是 Unequip 的最后一步，
--   与 93-106 行的顺序对照：Equip 是「状态→副作用→回调→事件」，
--   Unequip 是「状态→回调→事件」。两者的「回调」都在「事件」之前。
--   ★ 这个顺序对监听 "equipped" 的组件很重要：
--     事件处理时，物品的 isequipped 已经是最新的。

-- ↑ PushEvent 之后。
-- ★ PushEvent("unequipped") 的消费点与 "equipped" 对称。
--   ★ 但 inventory.lua:1241 还会额外发一个 "unequip" 事件
--     （1241 行）—— 那是 Inventory 层的、带 eslot 与 slip 信息的版本。
--   ⇒ ★ 存在**两套**卸装事件：
--       · 本文件的 "unequipped"（只有 owner，用于物品自身逻辑）；
--       · Inventory 的 "unequip"（item + eslot + slip，用于 UI 与音效）。
--     两者在 inventory.lua:1227 前后连续触发。
    self.inst:PushEvent("unequipped", { owner = owner })
end
-- ↑ Unequip 结束。
-- ↑ 空行分隔，进入移速区。

-- ↑ 空行。
-- ★★★ 原英文注释（保留）："Keep logic in sync with
--   inventoryitem_replica::GetWalkSpeedMult()" ——
--   ★★ 这是本文件第二条硬性耦合契约（第一条是 5 行）。
--     服务器与客户端各有一份 GetWalkSpeedMult 的实现，
--     **必须逐字符一致**，否则联机时客户端预测的速度与服务端不符，
--     表现为角色位置抖动/瞬移。
--   ⇒ 修改本函数时必须同步修改 inventoryitem_replica 的对应函数。
-- Keep logic in sync with inventoryitem_replica::GetWalkSpeedMult()
-- 【§四】GetWalkSpeedMult —— 移速倍率的**服务端权威计算**。
-- ★★ 四步流程（顺序重要）：
--   128  取基础值 self.walkspeedmult 或 1.0（nil 默认 1.0）
--   130-132  取 owner（通过 inventoryitem.owner）
--   133-135 若减速且 owner 带 vigorbuff → +0.25 补偿（见 L1）
--   137-140 若 owner 有外部修正函数 → 交由它处理
function Equippable:GetWalkSpeedMult()
-- ★ 函数体入口。

-- ↑ 函数体入口。
-- ★★ `self.walkspeedmult or 1.0` —— nil 走默认 1.0。
--   ⇒ 「未设置」与「设为 1」在结果上无法区分（设计上不需要区分）。
    local speed = self.walkspeedmult or 1.0

-- ↑ 基础值取得之后。
-- ★★ owner 的取得路径是 `self.inst.components.inventoryitem.owner`，
--   **不是**直接 `self.inst.components.inventory.owner`。
--   为什么多一层？因为「装备所在的位置」由 inventoryitem 记录，
--   它可能是角色的背包、装备槽、甚至一个箱子。
--   ⚠ 见 L2：这条链假定 inventoryitem 必然存在，否则整段被 and 短路，
--     返回未加修正的 speed（1.0），静默丢失所有移速属性。
    local owner = self.inst.components.inventoryitem and self.inst.components.inventoryitem.owner
-- ★★ owner 存在 + 已装备 —— 进入修正流程。

-- ↑ 修正流程进入点。
-- ★★ `if owner and self.isequipped then` —— 双重条件。
--   ★ isequipped 的意义：防止「物品还在装备槽里但 Unequip 已被调过」
--     的中间态影响移速计算（例如 SetPreventUnequipping 阻止卸下时）。
--   ★ 即：移速修正**只在真正装备着时**生效。
    if owner and self.isequipped then
-- ⚠ 见 L1：vigorbuff 只补偿减速、不处理加速。
-- ★ 这是有意设计：vigorbuff（韦斯勒的「活力」天赋）的语义是
--   「让韦斯勒不被重装备拖慢」，而不是「让韦斯勒跑得更快」。
-- ★ 但 math.min(1, ...) 的硬截断意味着：
--   walkspeedmult = 0.7 → 有 buff 时是 0.95（+0.25），不是 1.0。
--   ⇒ 补偿是**固定 0.25**，不是「补满到 1.0」。
        if speed < 1 and owner:HasTag("vigorbuff") then
            speed = math.min(1, speed + 0.25)
-- ↑ +0.25 补偿。
        end
-- ↑ math.min(1, ...) 硬截断。

-- ↑ vigorbuff 块结束。
-- ★★ owner.inventory_EquippableWalkSpeedMultModifier ——
--   这是一个**挂在 owner 实体上的动态函数字段**，不是组件方法。
--   签名：(owner, speed, inst) → speed。
--   ★ 这是给角色/模组留的**最终裁决权**：在自己上挂一个函数，
--     就能对任何装备的移速做最终修正（含加速）。
--   ★ 这恰好补上了 L1 说的「vigorbuff 不能加速」的限制。
        local speedmodifierfn = owner.inventory_EquippableWalkSpeedMultModifier
-- ★ 外部修正函数的存在性判定。
        if speedmodifierfn ~= nil then
-- ↑ 外部函数判定之后。
            speed = speedmodifierfn(owner, speed, self.inst)
-- ↑ 外部修正函数调用。
-- ★ 140 行：交出最终裁决权，返回值直接成为 speed。
        end
-- ↑ 外部修正调用之后。
    end
-- ↑ 外部修正块结束。
-- ↑ 空行。

-- ↑ 空行。
    return speed
-- ↑ 返回 speed。
end
-- ↑ GetWalkSpeedMult 结束。
-- ↑ 空行分隔。

-- ↑ 空行。
-- ★★★ 原英文注释（保留）："V2C: reminder to update replica version
--   as well XD" —— 作者自己的提醒：改本文件也要改 replica。
--   与 5 行、125 行构成三处耦合声明。
--V2C: reminder to update replica version as well XD
-- ↑ V2C 提醒注释结束。
-- 【§五】IsRestricted —— 「这个物品 target 能不能穿」。
-- ★★ 三重短路判定：
--   148-151 target 必须是 player 或 possessedbody（其他实体一律放行）
--   152-158 linkeditem 专属装备（只能主人穿）
--   159-161 restrictedtag 标签匹配
function Equippable:IsRestricted(target)
-- ★★ 148-151 行的原注释 "restricted tags and links only apply to players"
--   —— 即 AI/NPC 即使没有对应标签也能穿（避免 AI 无法装备）。
--   ★ 这是一个务实的例外：如果要求所有实体都有玩家标签，
--     猪猪、蜜蜂等生物将无法穿戴玩家装备类的物品。
	if not target:HasAnyTag("player", "possessedbody") then
-- ★ 149 行：标签限制的入口。
		--restricted tags and links only apply to players
-- ↑ 标签限制入口。
		return false
-- ↑ 原注释「restricted tags and links only apply to players」结束。
-- ↑ 原英文注释结束。
	end
-- ↑ 原注释结束。
-- ★ linkeditem：模组/特殊道具的「专属装备」机制。
--   IsEquippableRestrictedToOwner 为 true 时，只有 GetOwnerUserID
--   匹配的角色能穿。
    local linkeditem = self.inst.components.linkeditem
-- ★ IsEquippableRestrictedToOwner 判定（专属装备）。
    if linkeditem and linkeditem:IsEquippableRestrictedToOwner() then
-- ↑ 专属装备判定。
-- ★ GetOwnerUserID —— 主人 userid。
        local owneruserid = linkeditem:GetOwnerUserID()
-- ↑ 取得主人 userid。
-- ★ `owneruserid ~= target.userid` —— 主人 ID 不同则拒绝。
--   ★ 注意 155 行的 and 链：`owneruserid and owneruserid ~= target.userid`。
--     若 owneruserid 为 nil（未绑定主人），则**不拒绝** ——
--     即未绑定的专属装备人人可穿。
        if owneruserid and owneruserid ~= target.userid then
-- ★ 主人不匹配 → 返回 true（被禁止）。
            return true
-- ↑ 拒绝分支判定。
-- ★★ 157 行是「返回 true」—— 语义是「**被禁止**穿」。
--   ⇒ 若 owneruserid 为 nil，156 行的 and 短路为 false，
--     不会走到 157 行 ⇒ 未绑定的专属装备**人人可穿**。
        end
-- ↑ 拒绝返回。
    end
-- ↑ linkeditem 判定块结束。
-- ★★★ restrictedtag 的三段判定：非 nil + 长度 > 0 + target 无此标签。
--   ★ `self.restrictedtag:len() > 0` 这一段是必要的防御：
--     若某 prefab 把 restrictedtag 设为空串，HasTag("") 的行为不确定
--     （可能匹配一切），显式挡掉空串更安全。
--   ★★ 这是「唯一被拒绝才 return true」的判定，
--     所以 IsRestricted 语义是「**被禁止**穿」而非「可以」穿。
    return self.restrictedtag ~= nil
-- ★★ 160 行 `self.restrictedtag:len() > 0` —— 空串防御。
--   若某 prefab 误设 restrictedtag = ""，HasTag("") 在 Klei 的实现里
--   可能匹配到意外的对象，所以显式挡掉。
        and self.restrictedtag:len() > 0
-- ↑ 空串防御判定。
-- ★ 最终判定：target 不带该标签 ⇒ 被禁止。
        and not target:HasTag(self.restrictedtag)
-- ↑ 最终返回。
end
-- ↑ IsRestricted 结束。
-- ↑ 空行分隔。

-- ↑ 空行。
-- ★★ IsRestricted_FromLoad —— 读档路径的变体。
-- ★★ 165 行原注释给出了**唯一**的语义差异（保留）：
--   "If a player is resolving equipment from a snapshot load assume the
--    player has the tag only if the tag is from a skill tree." ——
--   ★ 中文：读档重建装备时，只有当限制标签**来自技能树**时，
--     才认定「目标角色理应拥有该标签」。
--   ⇒ 这是给技能树装备开的读档后门：升级前不能穿的角色，
--     升级后读档仍能正确认领自己解锁的装备。
--   ★ 调用点：inventory.lua:1270 Equip 的入口判定（isloading 时走本函数）。
function Equippable:IsRestricted_FromLoad(target)
-- ★★ 165 行原注释是本函数的**全部语义差异**（保留）：
--   "If a player is resolving equipment from a snapshot load assume the
--    player has the tag only if the tag is from a skill tree."
--   ⇒ 读档时，若限制标签来自技能树，认定该角色「本应拥有」它。
    -- NOTES(JBK): If a player is resolving equipment from a snapshot load assume the player has the tag only if the tag is from a skill tree.
-- ↑ 原注释第一行。
-- ★★ `type(SKILLTREE_EQUIPPABLE_RESTRICTED_TAGS[...]) == "table"` ——
--   这个 type 判断是为了区分两种数据形态：
--     · 单个 prefab 名（字符串）：标签只对某个角色开放；
--     · 表（prefab → true）：标签对一组角色开放。
--   ★⚠ 注意下一行的写法：
--     167 行在 type=="table" 分支里访问 [target.prefab]，
--     而 170 行在 elseif 分支里直接与 target.prefab 比较字符串。
--     两种形态的处理是分开的，逻辑正确但可读性差。
    if type(SKILLTREE_EQUIPPABLE_RESTRICTED_TAGS[self.restrictedtag]) == "table" then
-- ★★ 167 行是 table 形态的判定：`SKILLTREE...[tag][target.prefab]`。
--   命中（值为真）⇒ return false（不被禁止）。
--   ★ 即：技能树限制的标签，对「技能树里列出的那些角色」完全放行。
        if SKILLTREE_EQUIPPABLE_RESTRICTED_TAGS[self.restrictedtag][target.prefab] then
-- ↑ table 形态判定。
-- ↑ 放行返回。
            return false
-- ↑ 放行返回之后。
        end
-- ↑ table 形态的技能树标签判定。
-- ★ 字符串形态：`SKILLTREE_... [tag] == target.prefab` ——
--   直接比较角色 prefab 名。命中则放行（return false = 不被禁止）。
    elseif SKILLTREE_EQUIPPABLE_RESTRICTED_TAGS[self.restrictedtag] == target.prefab then
-- ★ 171 行：字符串形态命中 → 放行。
        return false
-- ↑ 字符串形态放行之后。
    end
-- ↑ table 形态判定结束。
-- ★ 非技能树标签 → 走标准判定。
--   ⇒ 两个函数的**唯一**差异就是这一个 if/elseif 分支。
    return self:IsRestricted(target)
end
-- ↑ IsRestricted_FromLoad 结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★ ShouldPreventUnequipping —— 纯查询。
--   ★★ 177 行的 `== true` 是严格布尔：见 21 行的同步侧也是同一约定。
--     184 行 SetPreventUnequipping 里对非 true 值统一存 false / nil，
--     所以这里不会遇到「1」这类脏值。
function Equippable:ShouldPreventUnequipping()
-- ★★ 177 行的 `== true` 与 22 行的 `prevent == true` 构成一对：
--   服务端存储（184 行）用 nil / true，replica 同步用 true / false。
--   ⇒ 整个 preventunequipping 机制的布尔化是**双端一致的**。
	return self.preventunequipping == true
-- ↑ 严格布尔返回。
end
-- ↑ ShouldPreventUnequipping 结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ local function OnRemove(inst) —— 局部函数，无其它引用。
--   ★★ 它的存在**唯一目的**是给 RemoveEventCallback 提供一个可比较的引用，
--     从而在 191 行能精确解绑。
--   ⚠ 若把它改成匿名闭包，191 行的解绑就会失败（Lua 中两个闭包不相等），
--     导致 OnRemove 永久残留。这是一处必须保持写法的细节。
local function OnRemove(inst)
-- ★★ 181 行在实体移除时**强制解除锁**。
--   ★★★ 这是本文件最巧妙的一处设计，推理链如下：
--     ① SetPreventUnequipping(true) 让物品「不可卸下」；
--     ② 若物品在装备状态下被外部 Remove（例如掉线清理、传送销毁），
--        装备槽会残留一个**已失效的实体引用**；
--     ③ 而 blocked 的物品永远无法通过 Unequip 移出装备槽 —— 死锁。
--   ⇒ 实体一被移除就先解锁，让上层有机会正常清理。
--     这与 55 行 OnRemoveFromEntity 的复位是同一类防御，
--     但**路径不同**（前者是组件的 OnRemoveFromEntity，
--     此处是监听 inst 的 "onremove" 事件）。
    inst.components.equippable:SetPreventUnequipping(false)
end
-- ↑ OnRemove 函数结束。
-- ↑ OnRemove 局部函数结束。

-- ↑ OnRemove 函数结束。
-- ★★ SetPreventUnequipping —— 「加锁/解锁」二态函数。
--   ★ 它不是简单的 setter：会同时管理一个事件回调的生命周期。
function Equippable:SetPreventUnequipping(shouldprevent)
-- ↑ 加锁/解锁二分起点。
-- ★★ 185-189 是「加锁」分支：只在**从未锁定**时才加，
--   保证 ListenForEvent 不会被重复注册。
--   ★ 用 `if not self.preventunequipping then` 做幂等保护。
    if shouldprevent then
-- ↑ 加锁分支判定。
-- ★★ 186 行是幂等保护的判定：仅在「当前未锁」时才加锁。
		if not self.preventunequipping then
-- ↑ 幂等判定。
-- ★★ 187 行注册回调 —— 注意是**先注册、后赋值**（188 行才置 true）。
--   ⇒ 若 ListenForEvent 内部同步派发了 onremove（不会，但理论上），
--     OnRemove 会看到 preventunequipping 仍为 nil。实践中无影响，
--     但这个顺序是刻意的防御式写法。
			self.inst:ListenForEvent("onremove", OnRemove)
-- ★ 188 行：置 true（在注册之后）。
			self.preventunequipping = true
-- ↑ 置 true 之后。
        end
-- ↑ 加锁块结束。
-- ★★ 190-193 是「解锁」分支，同样幂等（elseif 保证已在锁时才处理）。
	elseif self.preventunequipping then
-- ★★ RemoveEventCallback("onremove", OnRemove) —— 无第三个参数，
--   因为 180 行的 OnRemove 是无 upvalue 的局部函数。
--   ⚠ 若 OnRemove 捕获了变量（闭包），就必须用完全相同的闭包引用，
--     而 Lua 无法做到 ⇒ 这也是 180 行必须写成无捕获局部函数的原因。
		self.inst:RemoveEventCallback("onremove", OnRemove)
-- ★ 192 行 `self.preventunequipping = nil` 而不是 false ——
--   nil 让 186 行的 `if not self.preventunequipping` 在下次加锁时成立。
--   ⇒ nil 与 false 在此等价，用 nil 是为了与 55 行的初始化（未定义）一致。
		self.preventunequipping = nil
-- ★ 193 行：置 nil。
    end
-- ↑ 置 nil 之后。
end
-- ↑ SetPreventUnequipping 结束。
-- ↑ 空行分隔，进入 dapperness 区。

-- ↑ 空行。
-- 【§七】GetDapperness —— ★ 本文件最需要小心顺序的函数。
-- ★★ 四层合成，顺序不可交换：
--   197  local dapperness = self.dapperness      ① 基础值
--   199-201 merm 反转                            ② 条件反转
--   203-205 self.dapperfn 覆盖                   ③ 函数接管
--   207-209 淋湿加成                             ④ 无条件追加
-- ⇒ ★ 关键性质：第④层在第③层**之后**，所以
--     「湿装备的理智惩罚」**永远**能打破 dapperfn 的自定义结果。
function Equippable:GetDapperness(owner, ignore_wetness)
-- ★ 基础值。★ 注意是**拷贝**成局部变量，后续都是改局部。
--   ⇒ 本函数不修改 self.dapperness（纯函数语义），
--     可安全地被多次调用（sanity 每帧都可能调）。
    local dapperness = self.dapperness
-- ★ 198 行：先取基础值到局部变量。

-- ↑ 基础值拷贝之后。
-- ★★ `self.flipdapperonmerm and owner and owner:HasTag("merm")` ——
--   美人鱼戴帽子会让衰减**反向**（变成回理智）。
--   ★ 三重 and 保护：字段存在 + owner 非 nil + 有标签。
--   ★ flipdapperonmerm 字段在本文件**未初始化**（构造函数没设），
--     属 prefab 自行设置的额外字段。这是本文件唯一「未声明」的字段。
    if self.flipdapperonmerms and owner and owner:HasTag("merm") then
-- ★ 反转：直接取负。若基础值是 0，-0 == 0 无害。
        dapperness = -dapperness
-- ↑ merm 反转之后。
-- ↑ merm 反转块结束。
    end
-- ↑ merm 反转之后。
-- ↑ 空行。

-- ↑ 空行。
-- ★ dapperfn 存在性判定。
    if self.dapperfn ~= nil then
-- ↑ dapperfn 判定。
-- ★★ dapperfn 覆盖：结果**替换**而非叠加。
--   ⚠ 见 L3：签名 (inst, owner) 中 owner 可能为 nil，
--     自定义 dapperfn 必须自行处理（本函数不保证 owner 存在）。
--   ★ 对比 merm 反转是「取负」（保留），这里是「替换」（丢弃）——
--     所以 dapperfn 会**丢掉** flipdapperonmerm 的反转效果。
        dapperness = self.dapperfn(self.inst, owner)
    end
-- ↑ dapperfn 覆盖块结束。
-- ↑ 空行，进入湿气判定。

-- ↑ 空行。
-- ★★ 207 行 `if not ignore_wetness and self.inst:GetIsWet()` ——
--   ★★ 注意是 `not ignore_wetness`（**取反**而非直接判断）——
--     即默认**计入**湿气惩罚，调用方可用 ignore_wetness=true 排除。
--   ★ 这是一个容易看错的双重否定。
--   ★ GetIsWet 是 inst 上的方法（来自 moisture 组件），
--     说明湿气是**物品自身的状态**，不是装备槽的状态。
    if not ignore_wetness and self.inst:GetIsWet() then
-- ★ TUNING.WET_ITEM_DAPPERNESS —— 湿装备的额外衰减常量。
--   ★ 因为它在最后无条件追加，所以：
--     即使某物品的 dapperfn 返回了 0（表示「不掉理智」），
--     淋湿后仍然会掉。这就是 HEADER_EXTRA 第 8 条说的「不可交换」。
        dapperness = dapperness + TUNING.WET_ITEM_DAPPERNESS
    end
-- ↑ 湿气加成块结束。
-- ↑ 湿气加成块之后。

-- ↑ 湿气块之后。
    return dapperness
-- ↑ 返回 dapperness。
end
-- ↑ GetDapperness 结束。
-- ↑ 空行。

-- ↑ 空行。
-- ★★ GetEquippedMoisture 返回一个**新表** { moisture, max }。
--   ★ 每次调用都新建表（热路径上的小 GC 压力），
--     消费点 inventory.lua:2692 GetEquippedMoistureRate 会逐个装备调用一次。
--   ⚠ 见 L4：两个字段恒为 0，该机制目前未接线。
function Equippable:GetEquippedMoisture()
    return { moisture = self.equippedmoisture, max = self.maxequippedmoisture }
-- ↑ 返回 { moisture, max }。
end
-- ↑ GetEquippedMoisture 结束。
-- ↑ GetEquippedMoisture 之后。

-- ↑ 返回新表之后。
-- ↑ 类定义返回。本文件以 return Class 结束（与 recipe.lua 的全局风格不同）。
return Equippable
-- ↑ 文件末行（换行产生的空串）。

-- ↑ 文件末尾空串（split 产生）。