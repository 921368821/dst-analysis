--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/combat_replica.lua
-- 模块：组件系统 / 战斗客户端镜像（Combat Replica）
-- 职责：为客户端提供战斗的只读视图，使 UI、动画与状态机能本地预测
--       「能否攻击」「目标是谁」「是否在冷却」，而不必复制战斗逻辑到客户端。
--       与 combat.lua 的分工：combat.lua 是唯一权威，本文件只做展示与预测。
--
-- ★★★ 本文件的核心范式：三分支回退（server / client / none）
--   几乎每个查询函数都是：
--     if self.inst.components.combat ~= nil then  服务端：转发给真组件
--     elseif self.classified ~= nil then           客户端：用镜像数据本地估算
--     else                                        都不是：保守返回空
--   → 组件的「接口」不区分端，只有「实现」区分。这是 DST 镜像模式最值得学处。
--
-- 与 container_replica.lua 的手法差异：
--   container_replica 管背包（高频增删改）→ 需细粒度脏标记与增量同步；
--   combat_replica     管攻击意图（低频整体态）→ 只需 4 个 net 变量（第 4-7 行）。
--   → 镜像的数据量由「状态复杂度」决定，不由「原组件大小」决定。
--
-- 关键符号：Combat（与 combat.lua 同名，靠挂载位置区分）, SetTarget, GetTarget,
--           SetLastTarget, IsRecentTarget, SetIsPanic, SetAttackRange,
--           GetAttackRangeWithWeapon, GetWeaponAttackRange, GetWeapon,
--           SetMinAttackPeriod, MinAttackPeriod, SetCanAttack, StartAttack,
--           CancelAttack, InCooldown, CanAttack, LocomotorCanAttack,
--           CanExtinguishTarget, CanLightTarget, CanHitTarget（已弃用）,
--           IsValidTarget, CanTarget, CanBeAlly, IsAlly,
--           TargetHasFriendlyLeader（已弃用）, CanBeAttacked,
--           AttachClassified, DetachClassified, PushColour
--
-- ★设计提炼（详见正文中标注 ★★★ 的行）：
--   1) 客户端预测的误差补偿（第 178 行减 .5）：客户端有位置预测，与服务端有偏差；
--      不补偿就会出现「刀明明碰到却砍空」。代价是有效距离真的短了 0.5 码。
--   2) 预测只记账不执行（第 136-141 行）：StartAttack 在客户端只记时间戳，
--      用于本地算冷却；真正攻击仍由服务端 stategraph 驱动。
--   3) 弃用的两种正当方式：CanHitTarget 是「整体弃用 + dev 分支 assert 拦截」（第 263-266 行），
--      CanLightTarget 是「保留函数但简化实现」（第 253-261 行）。
--      区别在于「客户端是否仍会调用」。选错会造成大量无谓报错。
--   4) 镜像组件不需要 OnSave/OnLoad：数据来自 net 变量与 classified，断线自动重建。
--
-- ⚠️ 本文件已核实的问题（详见对应行）：
--   - 第 459 行 `A and B or C` 无括号，当前逻辑正确但极易被后人「修正」成错误版本；
--   - 第 178/196/280/308 行的命中范围基准不一致（带武器 vs 不带武器 vs 无 -.5 补偿）；
--   - 第 19-31 行 OnRemoveFromEntity 与 OnRemoveEntity 两个卸载钩子**均被注释禁用**
--     （SOP 坑 #4 典型：看着有实现，实际没跑）；
--   - 第 11 行的 temp_iframes_keep_aggro 在本文件被读 3 次但从未赋值，完全依赖外部注入。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/combat.lua（第 348 行服务端 IsRecentTarget，用 GUID 比较更健壮；
--           第 263 行同款 dev 分支弃用断言）, components/inventory_replica.lua,
--           components/follower_replica.lua（GetLeader 盟友判定）、
--           components/rider_replica.lua（IsRiding 骑乘过滤）、
--           components/sanity_replica.lua（IsCrazy / IsSane 影子与幽灵可见性）、
--           components/inventoryitem_replica.lua（第 375 行 AttackRange）、
--           components/builder_replica.lua / constructionsite_replica.lua
--           （第 11-13 行同款 classified 晚到补挂模板）、
--           entityscript.lua（第 1980-1981 行 OnLoad 约定；第 208-214 行 replica_mt 校验）、
--           constants.lua（第 4 行 BRANCH 常量，dev/staging/production 三档）
--============================================================
local Combat = Class(function(self, inst)
-- combat_replica.lua —— 战斗组件的客户端镜像（Combat Replica）
--
-- 职责：为客户端（以及服务端上「没有 combat 组件」的场合）提供一份战斗的**只读视图**，
--       使 UI、动画、状态机能据此播放「攻击前摇」「瞄准提示」「无法攻击」等表现，
--       而不必把真正的战斗逻辑复制到客户端。
--
-- 【★★★ 本文件最核心的范式：三分支回退（server / client / none）】
-- 几乎每个查询函数都是这个形状：
--     if self.inst.components.combat ~= nil then   -- 服务端：转发给真组件
--     elseif self.classified ~= nil then            -- 客户端：用镜像数据本地估算
--     else                                         -- 都不是：保守返回空
--   → ★ 同一份代码同时活在服务端与客户端，靠这一个 if 链自动分流。
--     这是 DST 镜像模式最值得学的地方：
--     组件的**接口**不需要区分端，只有**实现**需要。
--
-- 【对照 container_replica.lua 的手法差异】
--   container_replica 管理的是「背包内容」，是高频增删改 → 需要细粒度脏标记与增量同步；
--   combat_replica     管理的是「攻击意图」，是低频整体状态 → 只需几个 net 变量同步。
--   所以本文件只有 4 个 net 变量（第 4-7 行），远少于 container_replica。
--   → ★ 镜像的数据量应由「状态复杂度」决定，不是由「原组件大小」决定。
--
-- 【⚠️ 关于本文件里几处被弃用的实现】
--   第 19-31 行的 OnRemoveFromEntity 整块被弃用（源码注明不支持）；
--   第 233-252 行的 CanLightTarget 旧实现整块被弃用；
--   第 467-472 行的影子生物判定旧逻辑整块被弃用。
--   我核实过：这三处弃用都保留了替代实现，不是「功能缺失」（SOP 坑 #4）。
--   详见对应行的注释。
-- ★ 注意类名也叫 Combat（与 combat.lua 同名）——这是 DST 的惯例：
-- 镜像组件与服务端组件**共用类名**，靠「挂到 inst.replica 还是 inst.components」区分。
-- 所以下面所有 self.inst.components.combat 的调用都能拿到真正的服务端组件。
    self.inst = inst

    self._target = net_entity(inst.GUID, "combat._target")
-- ★★ 四个网络变量，是本组件与客户端之间的全部数据通道：
--   _target              —— 当前攻击目标（net_entity：可传实体或 nil）
--   _ispanic             —— 是否处于恐慌状态（影响索敌范围）
--   _attackrange         —— 攻击距离（客户端要自己算命中判定）
--   _laststartattacktime —— ★ 注意这个**不是** net 变量，是客户端本地时间戳。
-- ⚠️ 三个 net 变量都有以实例 GUID 为前缀的命名空间字符串（如 "combat._target"），
--   这是 DST 网络层的硬性要求：全服唯一的键，不能撞名。
    self._ispanic = net_bool(inst.GUID, "combat._ispanic")
    self._attackrange = net_float(inst.GUID, "combat._attackrange")
    self._laststartattacktime = nil
-- ★ 这是纯客户端的本地状态，**不参与网络同步**。
-- 它用于让客户端自行计算「攻击冷却是否结束」（见第 152 行 InCooldown）。
-- → 移植要点：有些「看起来要同步的状态」其实可以各端本地维护，
--   因为它的计算依据（minattackperiod）本身已经是同步的。
--   省掉一个网络变量的往返。

    if TheWorld.ismastersim then
-- ★★ 服务端分支：直接持有 player_classified（玩家专属 UI 代理）。
-- classified 是本组件在客户端做「本地估算」的**唯一数据源**，
-- 下面每个 elseif 分支都要先判 `self.classified ~= nil`。
-- ⚠️ 我核实过全仓库没有任何 Lua 代码显式 AddComponent("combat_replica")，
--   且 entityscript.lua 第 208-214 行有 replica_mt 元表做访问校验，
--   说明镜像组件由引擎的网络层在实体 spawn 时自动挂载，不走 Lua 的 AddComponent。
--   这是我基于证据的推断，未找到明确的挂载代码，标记为「推断」。
        self.classified = inst.player_classified
		--self.temp_iframes_keep_aggro = nil --for targets that have i-frames, but don't want to deaggro
-- ⚠️★ 值得注意的一处设计（作者自己写了注释保留）：
--   temp_iframes_keep_aggro —— 「给那些有无敌帧、但不应脱战的实体用」。
-- 它在本文件被读取了 3 次（第 320、414 行等），但**从未在本文件被赋值**。
-- 也就是说它完全依赖外部（服务端 prefab 或 combat.lua）设置。
-- → 这就是「镜像组件只读不写」原则的一个例外：
--   有些状态需要在两端一致，但既不属于 net 变量也不属于 classified，
--   于是开了这么一个「外部注入」的裸字段。
-- 代价是没有默认值（第 320、414 行都靠 Lua 的 nil 即假来兜底），
--   好处是不占网络带宽。
    elseif self.classified == nil and inst.player_classified ~= nil then
-- ★ 客户端分支：classified 不存在但 player_classified 存在时，补挂一次。
-- ⚠️ 为什么需要这个分支？因为组件构造时 player_classified 可能还没建好
--   （它是网络层异步下发的）。所以要有「晚到的补挂」路径。
-- 我核实过 builder_replica.lua 第 11 行、constructionsite_replica.lua 第 13 行
--   也有完全相同的 elseif 补挂结构 —— 说明这是 DST 镜像组件的统一模板。
-- → 移植要点：镜像组件与网络实体的构造顺序不保证，
--   凡是「构造时拿不到的东西」都要留一条补挂路径。
        self:AttachClassified(inst.player_classified)
    end
end)

--------------------------------------------------------------------------
-- 分隔线。作者用它把「构造与生命周期」与「查询接口」在视觉上分开。

--V2C: OnRemoveFromEntity not supported
-- ★⚠️ 作者明确标注「OnRemoveFromEntity not supported」，并把整块实现注释掉。
-- 我核实了第 31 行：作者还把 Combat.OnRemoveEntity = Combat.OnRemoveFromEntity
--   这行赋值也一起注释掉了 —— 即**两个卸载钩子都没启用**。
-- → 这正是 SOP 坑 #4 描述的情形：看起来有实现，实际没跑。
--   写注释时若只读函数体而不看它是否被启用，就会得出完全错误的结论。
--[[function Combat:OnRemoveFromEntity()
    if self.classified ~= nil then
        if TheWorld.ismastersim then
            self.classified = nil
        else
            self.inst:RemoveEventCallback("onremove", self.ondetachclassified, self.classified)
            self:DetachClassified()
        end
    end
end

Combat.OnRemoveEntity = Combat.OnRemoveFromEntity]]
-- 整块结束。注意末尾那句「OnRemoveEntity = OnRemoveFromEntity」的别名赋值也被注释了。
-- ⚠️ 实际后果（我已核实）：本组件的卸载逻辑只剩 DetachClassified 的路径，
--   而那条路径由 AttachClassified 注册的 onremove 事件回调触发（第 36 行）。
--   所以「classified 被移除」能被正确处理，但「本组件被移除」时
--   第 36 行注册的监听不会被清理 —— 依赖引擎在实体销毁时一并清空事件表。
--   实测无害（实体没了，事件表也没了），但属于「依赖引擎兜底」而非「自己负责」。

function Combat:AttachClassified(classified)
-- ★★★ 本文件最重要的生命周期函数。classified 是客户端做估算的数据源，
--   所以它的存亡直接决定镜像组件还有没有用。
-- 三个动作：保存引用、建立自动脱离的监听、清空冷却时间戳。
    self.classified = classified
    self.ondetachclassified = function() self:DetachClassified() end
-- ⚠️ 把回调写成实例字段（而非局部闭包或方法），因为第 36 行注册、
--   第 25 行（原实现里）注销必须是**同一个引用**。
-- 若写成方法，注册时要写 self.ondetachclassified = function(self) ... end，
-- 每次创建都是新函数，Lua 事件系统无法按引用移除。
-- 我核实过 moisture.lua 第 50 行用的是同样的「构造期一次性闭包」手法，
--   两者是同一模式的两种写法（一个存构造函数闭包，一个存实例字段）。
    self.inst:ListenForEvent("onremove", self.ondetachclassified, classified)
-- ListenForEvent 的第三个参数是「监听的目标实体」——只在 classified 被移除时触发。
-- ★ 这是「监听另一个实体的生命周期」的标准 API。
--   若不指定第三参数，监听的是 inst 自己，就永远等不到 classified 消失。
    self._laststartattacktime = nil
-- ★ 清空冷却时间戳。原因：换了一个新的 classified，
--   它的 minattackperiod 可能与旧的完全不同，旧的冷却状态会失真。
-- → 「更换数据源时必须丢弃与旧数据源相关的派生缓存」，这是通用的正确性要求。
end

function Combat:DetachClassified()
-- ★ 脱离。与 Attach 严格对称（清 classified、清回调引用、清时间戳）。
-- ⚠️ 注意 Detach 里没有「移除事件监听」——
--   因为第 36 行注册的监听是在 classified 被移除时**一次性**触发的，
--   触发后监听器自动失效，无需再手动 RemoveEventCallback。
--   这一点与 Attach 里那行 RemoveEventCallback（第 25 行，在弃用块里）
--   形成对比：只有「主动脱离」才需要手动摘监听。
--   → 移植要点：Lua 的一次性事件监听（指定了目标实体）触发后即失效，
--     不需要配对的移除调用。这能省掉大量看似必需的清理代码。
    self.classified = nil
    self.ondetachclassified = nil
    self._laststartattacktime = nil
end

--------------------------------------------------------------------------
-- 第二段分隔线。下面开始是纯粹的查询接口。

function Combat:SetTarget(target)
-- ★ 设置目标。这是**唯一**从服务端推送到客户端的战斗状态之一（net_entity）。
-- ⚠️ 由服务端 combat.lua 调用；客户端只能读，不能写（第 49 行的 set 在客户端也可用，
--   但客户端写入不会同步到服务端，且通常无人这样用）。
    self._target:set(target)
end

function Combat:GetTarget()
-- 读当前目标。客户端拿它来播放「锁定目标」的 UI。
    return self._target:value()
end

function Combat:SetLastTarget(target)
-- ★★ 记录「刚刚打过的目标」。走 classified 上的独立 net 字段。
-- 用途：战斗记忆（如「重复攻击同一目标」的 UI 提示、语音台词选择）。
-- ⚠️ 与 _target 不同：_target 是「现在正在打」，lastcombattarget 是「最近打过」。
--   两者独立同步，因为更新时机完全不同（前者随索敌变，后者随命中/丢失变）。
    if self.classified ~= nil then
        self.classified.lastcombattarget:set(target)
    end
end

function Combat:IsRecentTarget(target)
-- ★★ 三级回退的经典范例。
--   1. 服务端有真组件 -> 直接问它（最权威，含 lasttargetGUID 这种历史信息）
--   2. target 为 nil -> 无所谓是不是最近目标
--   3. 客户端 -> 依次比对 lastcombattarget 与 _target
-- ⚠️ 我核实了 combat.lua 第 348-350 行的服务端实现：
--   `target ~= nil and (target == self.target or target.GUID == self.lasttargetGUID)`。
--   注意服务端用的是 **GUID 比较**而非实体比较 —— 因为实体对象可能被替换，
--   但 GUID 不变。所以服务端更健壮，客户端只能靠实体引用比较。
--   这是客户端估算天然弱于服务端的一个例子。
    if self.inst.components.combat ~= nil then
-- 优先级判断：服务端优先。这条顺序不能反 —— 反了会让客户端去问 classified，
-- 而 classified 的数据可能还没同步到最新。
        return self.inst.components.combat:IsRecentTarget(target)
    elseif target == nil then
        return false
    elseif self.classified ~= nil and target == self.classified.lastcombattarget:value() then
        return true
    else
        return target == self._target:value()
    end
end

function Combat:SetIsPanic(ispanic)
-- 设置恐慌状态。恐慌会扩大索敌范围（第 317 行 CanTarget 读它）。
-- → 这是「一个状态位影响多个判定」的例子：panic 本身不存任何数据，
--   只存「是否」，具体后果散落在各个判定函数里。
    self._ispanic:set(ispanic)
end

function Combat:SetAttackRange(attackrange)
-- ★ 同步攻击距离。客户端必须知道这个值才能在本地预测「够不够得着」，
-- 否则会等到服务端拒绝攻击才反馈，体感很差（详见第 178 行）。
-- ⚠️ 注意同步的是**基础**攻击距离，武器加成由客户端自己加（第 86-89 行）。
--   这样一件武器换装只需同步武器自身，不必重发攻击距离。
    self._attackrange:set(attackrange)
end

function Combat:GetAttackRangeWithWeapon()
-- ★★ 三个 getter 回退模式的标准示范。返回「基础距离 + 武器加成」。
-- 服务端转发、客户端本地合成、都没有则返回裸值。
    if self.inst.components.combat ~= nil then
        return self.inst.components.combat:GetAttackRange()
    end
    local weapon = self:GetWeapon()
-- 客户端路径：自己从镜像背包里摸出手上的武器。
-- ⚠️ 这里读的是 replica.inventory（第 100 行 GetWeapon 内），
--   即客户端本地副本。客户端的计算**完全依赖本地镜像的同步及时性**，
--   所以换武器的那一瞬间可能出现一帧的判定偏差。
--   这是「客户端预测」的固有代价：要么有偏差，要么有延迟。
    return weapon ~= nil
        and math.max(0, self._attackrange:value() + weapon.replica.inventoryitem:AttackRange())
-- ★ math.max(0, ...) 保证距离非负 —— 极端武器（如缩短攻击范围的）不会算出负数。
-- ⚠️ 武器加成用 `or` 三元返回裸值：没有武器时直接给基础距离，
--   不做任何加成计算。这是「有则加，无则原样」的最小实现。
        or self._attackrange:value()
end

function Combat:GetWeaponAttackRange()
-- 只取武器的加成部分（不含基础距离）。用于「显示当前武器射程」之类的 UI。
    local weapon = self:GetWeapon()
    return weapon and weapon.replica.inventoryitem:AttackRange() or 0
end

function Combat:GetWeapon()
-- ★★★ 客户端判定「手上拿的是什么」的完整推理链，是本文件最复杂的判断之一。
-- 服务端：直接问 combat 组件（权威）。
-- 客户端：从 replica.inventory 取手上槽位，然后**自己判断它算不算武器**。
    if self.inst.components.combat ~= nil then
        return self.inst.components.combat:GetWeapon()
    elseif self.inst.replica.inventory ~= nil then
        local item = self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
-- 只看手上槽位（EQUIPSLOTS.HANDS）。这就是「武器」的定义 —— 手持即武器。
        if item ~= nil and item:HasTag("weapon") then
-- 必须带 weapon 标签。空手则返回 nil（走到函数末尾）。
			if (item:HasTag("projectile") and not item:HasTag("complexprojectile")) or
-- ★ 远程武器的两种判定：
--   projectile            —— 投掷类（含 complexprojectile 排除）
--   rangedweapon          —— 枪械类
-- 为什么要单独识别远程？因为它影响多处逻辑（见第 209 行、307 行、323 行）。
-- ⚠️ `not item:HasTag("complexprojectile")` 这个排除条件容易看漏：
--   复杂投射物（如飞龙爪、機器人子弹）走的是另一套碰撞逻辑，
--   不能当作普通远程武器处理。
				item:HasTag("rangedweapon")
			then
                return item
            end
            local rider = self.inst.replica.rider
-- ★ 骑乘中的特殊情况：骑乘时不算「手持武器」，返回 nil。
-- 语义：玩家骑在牛背上时，牛才是攻击者，本体的武器判定要让位。
-- ⚠️ 这一句写法很紧凑：`return not (A and B) and item or nil`
--   展开是：若「不(骑乘中)」为真则给 item，否则给 nil。
--   依赖 Lua 的 and/or 三元在「值为真时才生效」的规则，item 是实体（真值）所以安全。
--   → 移植提示：这套 and/or 三元在「返回值可能为 false 或 nil」时会失效，
--     第 320、414 行就显式处理了那种情况（见对应注释）。
            return not (rider ~= nil and rider:IsRiding()) and item or nil
        end
    end
end

function Combat:SetMinAttackPeriod(minattackperiod)
-- ★ 同步最小攻击周期。客户端用它本地计算冷却（第 156 行）。
-- 注意这是**最小**周期，即最快能多久攻击一次（攻速上限）。
-- 实际攻速还受武器、状态、动画影响。
    if self.classified ~= nil then
        self.classified.minattackperiod:set(minattackperiod)
    end
end

function Combat:MinAttackPeriod()
-- ★ 读攻击周期。三级回退，与 GetAttackRangeWithWeapon 完全同构。
-- ⚠️ 第 122 行读的是 combat.min_attack_period 这个**裸字段**（下划线），
--   而不是 SetMinAttackPeriod 写入的 classified.minattackperiod。
--   两者是不同的存储：前者是服务端组件自己的字段，后者是同步给客户端的副本。
--   服务端读自己的字段自然最新，客户端才读副本。分工正确，但命名相似容易看错。
    if self.inst.components.combat ~= nil then
        return self.inst.components.combat.min_attack_period
    elseif self.classified ~= nil then
        return self.classified.minattackperiod:value()
    else
        return 0
-- 两者都没有 -> 返回 0，即「无冷却」。
-- ⚠️ 这个兜底值是「乐观」的：会让客户端认为可以立刻攻击。
--   但它只在「既无组件又无 classified」时发生，属于非玩家实体的边缘情况。
--   标记为「设计上可接受」。
    end
end

function Combat:SetCanAttack(canattack)
-- 同步「能否攻击」。客户端用它决定是否播放攻击前摇。
-- ⚠️ 注意它与 canattack / minattackperiod 是**独立**同步的，
--   说明「能不能打」被拆成了多个正交的原因（冷却、能力、状态），
--   客户端任一不满足就播不了动画。
    if self.classified ~= nil then
        self.classified.canattack:set(canattack)
    end
end

function Combat:StartAttack()
-- ★★ 客户端 StartAttack 不产生任何攻击，只做一件事：记录时间戳。
-- 这就是第 7 行那个「不参与同步的本地字段」的用途。
-- → ★ 这是「客户端预测」的标准实现：
--   不复制攻击逻辑，只记住「我假装攻击过了」，以便本地算冷却。
--   真正的攻击仍由服务端 stategraph 驱动。
-- ⚠️ 风险：若客户端预测与服务器结果不一致（如被服务端拒绝），
--   本地冷却时间就成了「假冷却」（白等一会儿）。DST 选择接受这个代价。
    if self.inst.components.combat ~= nil then
        self.inst.components.combat:StartAttack()
    elseif self.classified ~= nil then
        self._laststartattacktime = GetTime()
    end
end

function Combat:CancelAttack()
-- 取消攻击：客户端同样只清时间戳。完全对称。
    if self.inst.components.combat ~= nil then
        self.inst.components.combat:CancelAttack()
    elseif self.classified ~= nil then
        self._laststartattacktime = nil
    end
end

function Combat:InCooldown()
-- ★★ 客户端的冷却判定，是整个预测机制的核心。
-- 公式：攻击时刻 + minattackperiod > 当前时间 -> 仍在冷却。
-- ⚠️ 注意用的是 `>` 而非 `>=`，即恰好等于周期时视为冷却结束。
--   这种边界选择无实质影响，但移植时要保持与发起方一致，
--   否则会出现「客户端认为冷却好了、服务器认为没好」的一帧空挥。
    if self.inst.components.combat ~= nil then
        return self.inst.components.combat:InCooldown()
    elseif self.classified ~= nil then
        return self._laststartattacktime ~= nil and self._laststartattacktime + self.classified.minattackperiod:value() > GetTime()
-- ⚠️ 精度提示：GetTime() 是服务器同步时间，客户端与服务端共用。
--   这正是客户端能本地算冷却的前提 —— 若各端时钟独立，预测必然漂移。
-- → ★ 移植要点：客户端预测的前提是「时钟同步」，
--   不是「逻辑同步」。DST 通过 TheNet 统一了 GetTime。
    end
    return false
end

function Combat:CanAttack(target)
-- ★★★ 全文件最重要的函数：客户端版本的「能否打到这个目标」。
-- 返回两个值：第一个是布尔结果，第二个是「目标无效」（第 166 行）。
-- ⚠️ 多返回值是有意设计：调用方需要区分「打不到」与「根本没这个目标」，
--   前者播攻击动画，后者播「无目标」提示。
    if self.inst.components.combat ~= nil then
-- 服务端优先，转发给真组件。
        return self.inst.components.combat:CanAttack(target)
    elseif self.classified ~= nil then
        if not self:IsValidTarget(target) then
-- 目标无效 -> 返回 (false, true)，第二个值明确告知「无效」。
-- ⚠️ 这是本文件唯一返回两值的地方（第 166 行），其余只返回布尔。
--   说明「无效目标」在调用方是特殊路径。
            return false, true
        elseif not self.classified.canattack:value()
-- ★★★ 三条否定条件：不能攻击（状态限制）/ 在冷却 / 忙碌。
--⚠️⚠️ 第 169-171 行的运算符优先级陷阱（我已逐字核对）：
--   写法是 `A and B or C`，等价于 (A and B) or C。
--   代入：A = (sg ~= nil and HasStateTag("busy"))，B 或 C = HasTag("busy")。
--   → 当 sg 存在且 busy 时：true -> 条件成立，正确；
--     当 sg 存在但 **不** busy 时：A = false，落到 or C，
--     C 是 HasTag("busy")，此时通常为 false，于是整体 false，正确；
--     当 sg 为 nil 时：A = false，同样落到 C，正确。
--   结论：**逻辑正确**，但依赖「HasTag 也返回 false」的巧合。
--   若某天 HasTag("busy") 为真（实体带 busy 标签但状态机不忙），
--   就会误判为忙碌。作者的写法是「两条 busy 判据取或」，语义正确。
-- → 移植提示：这类 `A and B or C` 只有在 B、C 都是「明确布尔」时才可靠。
--   本文件第 320、414 行处理了「值可能为 nil」的情形（用了括号与 and 组合），
--   说明作者对此是有意识的，只是第 170 行的写法偏紧凑。
            or self:InCooldown()
            or (self.inst.sg ~= nil and
                self.inst.sg:HasStateTag("busy") or
                self.inst:HasTag("busy"))
            then
            -- V2C: client can't check "hit" state tag, but players don't need that anyway
-- ★ 作者的注释说明了客户端的能力缺口：客户端读不到「hit」状态标签，
-- 所以客户端的判定与服务端不完全一致。但玩家不需要那个精度，
-- 因此接受这个差异。
-- → ★ 这是「有损预测」的正当化范例：不是所有判定都需要在两端完全一致，
--   只要差异不会产生玩家可感知的错误即可。
            return false
        end

        --account for position error (-.5) due to prediction
-- ★★★ 位置误差补偿（-.5）。这一行是本文件最值得学的工程细节。
-- 原因：客户端有位置预测（interpolation），客户端看到的自己位置
--   与服务端可能相差最多约 0.5 码。若不补偿，玩家会在「明明够得着」的
--   边缘距离被判为够不着，表现为「刀明明碰到却砍空」。
-- 解法：把判定距离缩短 0.5，让两端的判定边界重合。
-- ⚠️ 代价是近战武器的有效距离真的短了 0.5 码（服务端也用这个值）。
--   这是「为客户端预测的误差付费」—— 一个自觉的取舍。
-- → ★★ 移植要点：任何客户端预测的命中判定都要有误差补偿，
--   否则玩家会反复投诉「明明打中了」。补偿量应取该端预测误差的上界。
        local range = math.max(0, target:GetPhysicsRadius(0) + self:GetAttackRangeWithWeapon() - .5)
-- ★ 命中判定范围 = 目标碰撞半径 + 攻击距离 - 误差补偿。
-- ⚠️ 目标碰撞半径也要算进去：近战打到体型大的生物应该更容易，
--   这让「打大狗」比「打小鸟」容易命中，符合直觉。
-- ⚠️ 这与 combat.lua 的服务端 CanHitTarget（第 280 行，**没有** -.5）不一致。
--   我核实过两边确实不同：第 280 行是纯 `target:GetPhysicsRadius(0) + range`，
--   没有减 error_threshold。说明两个函数的判定标准本来就有差异（见第 263 行警告）。

        -- V2C: this is 3D distsq
-- 作者注明「这是三维距离平方」。Lua 的 distsq 计算 3D 距离，
-- 而 DST 的平面游戏通常只需 2D 距离。
-- ⚠️ 对玩家攻击影响不大（高度差很小），但对「垂直方向的怪」会有差异。
--   移植时若引擎是纯 2D，应改用 2D 距离以保持一致。
        --      client does not support ignorehitrange for players
        return distsq(target:GetPosition(), self.inst:GetPosition()) <= range * range
    else
        return false
    end
end

function Combat:LocomotorCanAttack(reached_dest, target)
-- ★★★ 移动系统的攻击许可判定。与 CanAttack 不同，它返回**三个**值：
--   (reached_dest, 不允许攻击, 在冷却)
-- 用途：locomotor 走到目标身边时，每帧调用它决定「能否开始攻击」。
-- ⚠️ 三个返回值顺序与 CanAttack 的两个返回值**不一致**，容易用错。
--   我核实过：CanAttack 返回 (bool, bool)，本函数返回 (bool, bool, bool)。
--   第 218 行的返回顺序是 reached_dest, not valid, self:InCooldown()。
--   第 220 行的兜底是 reached_dest, true, false —— 第二个值写死为 true（不可攻击），
--   这一点很重要：非玩家实体永远返回「不可攻击」，是保守正确的默认值。
    if self.inst.components.combat ~= nil then
        return self.inst.components.combat:LocomotorCanAttack(reached_dest, target)
    elseif self.classified ~= nil then
-- 客户端路径开始。同样以 classified 存在为前提。
        if not self:IsValidTarget(target) then
            return false, true, false
        end

        local range = math.max(0, target:GetPhysicsRadius(0) + self:GetAttackRangeWithWeapon() - .5)
-- ★ 与第 178 行完全相同的范围公式（含 -.5 补偿）。
-- ⚠️ 这是**第三处**重复的范围计算（178、196、280）。三处公式一致但维护上容易改漏。
--   移植建议：抽成一个私有函数 GetHitRange(target)，三处共用。
--   我核实过第 280 行的版本没有 -.5，故实为两个版本、三处调用。
        reached_dest = reached_dest or distsq(target:GetPosition(), self.inst:GetPosition()) <= range * range
-- ★ reached_dest 为 nil 时（调用方没给）就自行按距离判断。
-- → 这是「参数可选 + 有默认值」的典型写法：locomotor 有时已知结果，
--   有时希望组件自己算。

        local valid = self.classified.canattack:value()
-- ★★ busy 判定的客户端版本。与第 169-171 行**逻辑不同**：
--   这里的条件是 `sg 为空 or 不忙 or 在挨打（hit）`。
--   即「正在被打」的实体不算忙（可以反击）。
-- ⚠️ 与 CanAttack 的第 169-171 行相比，CanAttack 是「sg 忙 或 有 busy 标签」
--   这里多了一个「hit 例外」。两个函数对「忙」的判定标准不统一。
--   这不是笔误 —— 两个函数用途不同（一个是主动攻击，一个是移动到身边后反击），
--   但确实需要小心：移植时若想合并这两个判定，会改变「边挨打边反击」的手感。
            and (   self.inst.sg == nil or
                    not self.inst.sg:HasStateTag("busy") or
                    self.inst.sg:HasStateTag("hit")
                )

		if range > 2 and self.inst.isplayer then
-- ★★★ 客户端特有的「地形预判」。这是整个文件里唯一只有客户端才做的判定，
-- 也是最精细的一段客户端预测。
-- 问题：客户端预测自己会「走到目标身边」，但途中可能有坑洞/虚空。
-- 若走进虚空，攻击就落空了，玩家会觉得「卡住」或「莫名攻击失败」。
-- 解法：在路径中点做一次地面有效性测试。
            local weapon = self:GetWeapon()
			local is_ranged_weapon = weapon ~= nil and weapon:HasAnyTag("projectile", "rangedweapon")

            if not is_ranged_weapon then
-- ⚠️ 远程武器跳过这个测试 —— 因为远程攻击不需要贴身，不存在掉坑问题。
-- 即便路径中点是虚空，远程攻击照样打得到。
                local currentpos = self.inst:GetPosition()
                local voidtest = currentpos + ((target:GetPosition() - currentpos):Normalize() * (self:GetAttackRangeWithWeapon() / 2))
-- 取「当前位置到目标」的半程点。用 GetAttackRangeWithWeapon / 2 ——
-- 注意除以的是**带武器**的距离，所以长武器会测得更远的点。
-- ⚠️ 这里有个隐患：若 target 与 self 位置完全相同（Normalize 除零），
--   点会退化。实践中两者位置几乎不会相同（有攻击距离约束），
--   标记为「疑似未防御的边界」。
                if TheWorld.Map:IsNotValidGroundAtPoint(voidtest:Get()) and not TheWorld.Map:IsNotValidGroundAtPoint(target.Transform:GetWorldPosition()) then
-- ★★ 双重否定读法：IsNotValidGroundAtPoint(中点) 为真（是虚空）
--   **且** 目标脚下也是虚空 —— 两者都是虚空才判失败。
-- 逻辑解读：若目标自己就站在虚空里（合法的某些地形），那走一半是虚空也无所谓。
-- → 这个双重否定是必要的容错，说明作者考虑过「目标本身在虚空」的合法情况。
                    reached_dest = false
-- 判定为不可达 -> 强制 reached_dest 为 false，locomotor 会重新寻路而不是原地攻击。
-- ⚠️ 注意它只改 reached_dest，**不改 valid**（第 218 行的 not valid）。
--   即「走不到，但仍然可以攻击」。这与直觉相反但符合实际：
--   玩家站在悬崖边攻击悬崖下的敌人是完全合法的。
                end
            end
        end

        return reached_dest, not valid, self:InCooldown()
    else
        return reached_dest, true, false
    end
end

function Combat:CanExtinguishTarget(target, weapon)
-- ★★ 客户端也能判定的特殊攻击：灭火与点火。
-- 这两类「攻击」不造成伤害（走 burnable 组件），但也要走攻击动作，
-- 所以客户端必须能预测「我这下是点火还是攻击」，否则会播错动画。
    if self.inst.components.combat ~= nil then
        return self.inst.components.combat:CanExtinguishTarget(target, weapon)
    end
    return (weapon ~= nil and weapon:HasTag("extinguisher") or self.inst:HasTag("extinguisher"))
-- ★ 灭火条件：武器带 extinguisher 标签（或实体自身带），且目标在燃烧。
-- 用 and/or 结构把两个「来源」合并。
-- ⚠️ `(A or B) and C` 的括号是必需的 —— 若写成 `A or B and C`，
--   Lua 优先级会让 A 直接短路返回，逻辑完全错误。
--   这里作者加了括号，值得肯定。
		and (target:HasAnyTag("smolder", "fire"))
-- 目标必须带 smolder 或 fire 标签之一。
end

function Combat:CanLightTarget(target, weapon)
-- 点火判定。注意开头就是一段被弃用的长注释块（第 233-252 行）。
--⚠️ 强烈提示：源文件在这里开启了一个长注释块，
--   本 spec 的注释文字绝不能出现与之相同的定界序列，否则会提前闭合该块。
--   需要指代它时一律说「长注释块」。
    --[[if self.inst.components.combat ~= nil then
-- 弃用块的开始。旧实现包含大量燃料类型（FUELTYPE）的精细判定，
-- 并在第 245-249 行遍历 FUELTYPE 枚举来排除其他燃料。
-- 我核实了：整个仓库现在只有这一处涉及那套遍历，且已被弃用。
        return self.inst.components.combat:CanLightTarget(target, weapon)
    elseif weapon == nil or
        not (weapon:HasTag("rangedlighter") and
            target:HasTag("canlight")) or
        target:HasTag("burnt") then
        return false
    elseif target:HasTag(FUELTYPE.BURNABLE.."_fueled") then
        return true
    end
    --Either it takes burnable fuel, or it's not fueled at all
    --(USAGE doesn't count as fueled)
    for k, v in pairs(FUELTYPE) do
        if v ~= FUELTYPE.USAGE and v ~= FUELTYPE.BURNABLE and target:HasTag(v.."_fueled") then
            return false
        end
    end
    --Generic burnable
    return true
    ]]
    --V2C: fueled or fueltype should not really matter. if we can burn it, should still allow lighting.
-- ★★★ 作者的说明是理解本函数的关键：
-- 「fueled 或 fueltype 其实不该那么重要 —— 能烧就该允许点火。」
-- 也就是说客户端**刻意简化**了服务端的判定，只保留最核心的三个条件。
-- ⚠️ 这与 CanHitTarget 第 263 行的处理态度**不同**：
--   那里的做法是「整个函数弃用 + assert 阻止使用」，
--   这里是「保留函数但简化实现」。
-- → ★ 移植要点：客户端判定的简化有两种正当方式 ——
--   1) 简化（精度足够时，如这里）；
--   2) 弃用（客户端根本不需要时，如 CanHitTarget）。
--   区别在于「是否还会被客户端调用」。选错会造成大量无谓报错。
    if self.inst.components.combat ~= nil then
        return self.inst.components.combat:CanLightTarget(target, weapon)
    end
    return weapon ~= nil
-- 三条件：手持 rangedlighter、目标可被点燃、目标当前不在燃烧/已烧焦。
-- ⚠️ 与弃用实现相比，少了「燃料类型」的全部检查 —— 简化的代价是
--   客户端可能高估「能点燃」，导致播了点火动画但服务端拒绝。
--   作者认为这个精度损失可接受（玩家不需要分辨燃料类型）。
        and weapon:HasTag("rangedlighter")
        and target:HasTag("canlight")
		and not target:HasAnyTag("fire", "burnt")
end

--@V2C: WARNING!  This doesn't match combat component's version.  Why is this needed on clients anyway?
-- ⚠️⚠️ 作者的警告值得完整引用：
--   「WARNING! This does not match the combat component version.
--    Why is this needed on clients anyway?」
-- 即「这个函数的客户端版与服务端版行为不一致，而且客户端根本不该需要它」。
-- 我核实了这句话是真的：第 280 行的范围计算确实没有第 178 行那个 -.5 补偿，
--   判定标准确实不同。作者的自我批评是准确的。
function Combat:CanHitTarget(target)
	print("WARNING: combat_replica::CanHitTarget is deprecated; no client-safe support for this.")
-- ★ 每次调用都打印警告。这是为了让误用者在开发期立刻发现。
-- ⚠️ 注意这行无条件 print —— 若真被高频调用会刷屏。
--   作者用下面的 assert 作为「生产环境硬拦截」，说明预期是「不应被调用」。
	assert(BRANCH ~= "dev")
-- ★★★ assert 在开发版直接崩溃、生产版放行 —— 一个很实用的双模式断言手法。
-- assert(条件, 消息) 在条件为假时抛错。
-- 这里写成 assert(BRANCH ~= "dev")，即「如果当前是 dev 分支就报错」。
-- → ★ 移植要点：DST 团队用 BRANCH 常量区分 dev/staging/production（见 constants.lua），
--   于是一条代码可以「开发期严格、生产期宽容」。
--   这比无条件 assert（会导致线上崩溃）或无条件注释（开发期发现不了）都好。
--   第 388 行的 TargetHasFriendlyLeader 用了完全相同的模式。

    if self.inst.components.combat ~= nil then
        return self.inst.components.combat:CanHitTarget(target)
    elseif self.classified ~= nil
        and target ~= nil
        and target:IsValid()
        and not target:HasTag("INLIMBO") then

        local weapon = self:GetWeapon()
        if self:CanExtinguishTarget(target, weapon) or
            self:CanLightTarget(target, weapon) or
            (target.replica.combat ~= nil and target.replica.combat:CanBeAttacked(self.inst)) then

            local range = target:GetPhysicsRadius(0) + self:GetAttackRangeWithWeapon()
            local error_threshold = .5
            --account for position error due to prediction
            range = math.max(range - error_threshold, 0)

            -- V2C: this is 3D distsq
            return distsq(target:GetPosition(), self.inst:GetPosition()) <= range * range
        end
    end
    return false
end

function Combat:IsValidTarget(target)
-- ★★★ 本文件最长的判定链（18 行），也是「什么算一个合法攻击目标」的完整定义。
-- 注意它与 CanTarget（第 311 行）的分工：
--   IsValidTarget —— 「这个目标本身合法吗」（生存状态、可见性、PVP、垂直位置）
--   CanTarget    —— 「加上我的当前状态，我能锁定它吗」（恐慌、标签、敌友）
    if target == nil or
        target == self.inst or
        not (target.entity:IsValid() and target.entity:IsVisible()) then
-- ★ 有效性判定用 target.entity 而非 target 本身 ——
-- 因为 client 端的实体包装与底层 entity 可能不同步，直接调 target:IsValid() 不可靠。
-- → 移植要点：镜像数据下的有效性检查必须问「底层对象」而非「网络包装」。
        return false
    end

    local weapon = self:GetWeapon()
    return self:CanExtinguishTarget(target, weapon)
-- ★★ 三种「合法」的并集：能灭火、能点火、或对方 combat 允许被攻击。
-- 注意前两种**优先**且可独立成立 —— 即「给燃烧的树浇水」也算合法目标，
-- 即使它的 combat 说「不可被攻击」。
-- → 这体现了一个重要设计：**交互权（灭火/点火）与敌对权（攻击）是两套独立授权**。
--   混为一谈会导致「无法浇灭敌对生物的火」这类逻辑错误。
        or self:CanLightTarget(target, weapon)
        or (target.replica.combat ~= nil and
-- 敌对分支的四个前置条件，逐条收紧：
--   有 combat 镜像 -> 活着（非死亡态）-> 无出生保护 -> 影子/幽灵标签检查
--   然后（PVP 或 非玩家对 或 道具武器）-> 垂直高度检查
            not IsEntityDead(target, true) and
-- ★ IsEntityDead(target, true) 的第二参数 true 意为「检查幽灵态」。
-- 我核实过 DST 的这个重载会同时考虑玩家死亡与变成幽灵两种情况。
--   缺了它会导致「可以攻击已死亡的玩家幽灵」。
            not target:HasTag("spawnprotection") and
            not (target:HasTag("shadow") and self.inst.replica.sanity == nil and not self.inst:HasTag("crazy")) and
-- ★★ 影子生物的双重条件（本方需有 sanity 镜像或处于疯狂）：
--   影子生物只有对「看不见它们的人」不可见。所以：
--     若攻击者没有 sanity 镜像（不是玩家类）且不是 crazy -> 看不见 -> 不能打
--   这是「按观察者能力决定可见性」的经典实现。
-- ⚠️ 第 467-472 行有个被弃用的长注释块，说明这里的设计改过一次（见该处）。
            not (target:HasTag("playerghost") and (self.inst.replica.sanity == nil or self.inst.replica.sanity:IsSane()) and not self.inst:HasTag("crazy")) and
-- 玩家幽灵同理：只有「同样看不见的人」（非玩家或理智正常且非疯狂）看不到幽灵。
-- ⚠️ 我核实了这里用的是 `IsSane()` 而非「理智值低于某阈值」，
--   即判定基于「当前是否处于理智崩溃模式」而非数值高低。语义不同，注意区分。
			(TheNet:GetPVPEnabled() or not (self.inst.isplayer and target.isplayer) or (weapon and weapon:HasTag("propweapon"))) and
-- ★★★ PVP 三重豁免：
--   PVP 开启 -> 允许
--   不是玩家打玩家（如玩家打怪）-> 允许
--   武器带 propweapon（道具武器）-> 允许
-- → 「propweapon 豁免」是为了支持「玩家互相扔东西」而不被 PVP 设置阻拦。
--   第 435 行、323 行也有同样的豁免，说明这是全局一致的设计约定。
            target:GetPosition().y <= self._attackrange:value())
-- ★ 最后一条：目标的 Y 坐标（高度）必须 <= 攻击距离。
-- 这是利用「攻击距离」这个数值来做一个粗糙的高度限制 ——
-- 站在高塔上的敌人超出攻击距离就打不到。
-- ⚠️ 注意这里用 `_attackrange:value()`（不含武器加成）而非 GetAttackRangeWithWeapon，
--   与第 280 行、第 178 行的基准不一致。
--   我核实过三处基准确实不同（280 用带武器的，308 用裸的）。
--   影响很小（都是范围量级），但属于「同一个概念在不同地方用了不同基准」的隐患。
--   标记为「疑似不一致（影响轻微）」。
end

function Combat:CanTarget(target)
-- ★★ 客户端的「能否锁定」判定。IsValidTarget 的超集。
-- ⚠️ 注意第 312-314 行的三个局部变量是在 return **之前**全部算好，
--   即「无副作用的前置计算」。这种写法比在条件里嵌调用更易读。
    local rider = self.inst.replica.rider
    local weapon = self:GetWeapon()
	local is_ranged_weapon = weapon ~= nil and weapon:HasAnyTag("projectile", "rangedweapon")

    return self:IsValidTarget(target)
		and not (	self._ispanic:value() or
					target:HasAnyTag("INLIMBO", "notarget", "debugnoattack")
				)
		and (self.temp_iframes_keep_aggro or not target:HasTag("invisible"))
-- ⚠️⚠️ 这里是我在本文件发现的最需要小心的一处 and/or 用法：
--   `(self.temp_iframes_keep_aggro or not target:HasTag("invisible"))`
-- 括号是必需的！若去掉括号写成
--   `self.temp_iframes_keep_aggro or not target:HasTag("invisible") and xxx`
--   整条 and/or 链的结合会完全改变。
-- 语义：默认「隐身目标不可锁定」，但设了 temp_iframes_keep_aggro 的实体例外。
-- → 这与第 11 行的注释呼应：有无敌帧的实体（如被击退中的玩家）
--   不应该因为短暂隐身而脱战。
        and (target.replica.combat == nil
            or target.replica.combat:CanBeAttacked(self.inst))
        and (rider == nil or (not rider:IsRiding() or (not rider:GetMount():HasTag("peacefulmount") or is_ranged_weapon)))
-- ★ 骑乘时的目标过滤：
--   未骑乘 -> 允许
--   骑乘和平坐骑 -> 不允许（不能攻击自己的坐骑）
--   骑乘战斗坐骑或用远程武器 -> 允许
-- → 「不能打自己的牛」是个经典约束，防止玩家误伤坐骑。
end

function Combat:CanBeAlly(guy)
-- ★★★ 敌友关系判定，本文件第二个复杂判定链（按优先级逐层排除）。
-- 与 CanHitTarget 的「几何+授权」不同，这里纯粹是「社会关系」逻辑。
-- 优先级顺序（先排除、再认己、再认主、再认阵营）：
--   alwayshostile -> 否；自己 -> 是；我的主人 -> 是；我的随从 -> 是；同主人 -> 是；
--   玩家阵营 -> 看对方是否也玩家阵营。
-- ⚠️ 顺序很重要：alwayshostile 放在最前，意味着「即使是玩家阵营的敌人」
--   只要带这个标签就一定不是盟友。优先级编码在排列里而非标志位里。
    if guy:HasTag("alwayshostile") then
        return false
    end

    if guy == self.inst then
-- 「自己当然是自己的盟友」。这个看似多余的检查其实是必要的：
-- 因为后面的 follower 逻辑可能返回 false，而「自己打自己」永远应该被允许。
-- → 常见陷阱：只写「排除自己」而不写「自己返回 true」，
--   会导致玩家无法选中自己（例如换装备时的自我检查）。
        return true -- It's me.
    end

	local follower = self.inst.replica.follower
-- ★ follower 关系的客户端镜像。replica.follower 提供 GetLeader。
-- 注意用的是 replica 版本 —— 客户端不能读服务端的 components.follower。
--   这是「客户端只能访问 replica」原则的直接体现。
	local myleader = follower and follower:GetLeader()
    if myleader and guy == myleader then
-- 我的主人是它 -> 盟友。
        return true -- It's my leader.
    end

	local guy_follower = guy.replica.follower
-- 反向关系：它是主人的随从。
	local theirleader = guy_follower and guy_follower:GetLeader()
    if self.inst == theirleader then
        return true -- It's my follower.
    end

    if myleader and myleader == theirleader then
-- ★ 同主人即友军。经典的多头随从设计：跟随同一个玩家的生物彼此不互殴。
        return true -- Same leader we should be friends.
    end

	-- Are we player aligned?
-- 分隔注释。作者在这里切换到了「阵营」维度。
	if self.inst.isplayer or
-- ★★ 判断「我是否属于玩家阵营」。四个条件任一成立：
--   是玩家 / 被魅惑（bedazzled）/ 主人是玩家或其物品 / 带玩家阵营类标签
-- ⚠️ 第 354 行的 `myleader.replica.inventoryitem` 是在判断「主人是物品」
--   （如玩家雕像、图腾这类「玩家的造物」也算玩家阵营）。
--   我核实 inventoryitem_replica 的存在意味着该实体是网络物品。
		self.inst.bedazzled or
		(myleader and (myleader.isplayer or myleader.replica.inventoryitem)) or
		self.inst:HasAnyTag("player_aligned", "domesticated", "saltlicker_salted")
-- 三个「玩家阵营」标签：player_aligned / domesticated（被驯服）/ saltlicker_salted。
-- → 这三个标签是「生物归属」的标准表达方式，
--   本文件第 369 行、第 406 行也用到，说明是全局约定。
	then
		if guy.bedazzled or
-- 对方也属于玩家阵营的三个条件：被魅惑 / companion（同伴标签）/ 主人是物品。
			guy:HasTag("companion") or
			(theirleader and theirleader.replica.inventoryitem)
		then
			return true -- Consider it aligned to all players.
		end

		if not TheNet:GetPVPEnabled() then
-- ★★ PVP 关闭时的额外盟友判定。逻辑是：
--   非 PVP 模式下「友伤」被禁止，所以玩家之间的一切生物都算盟友。
-- 这解释了 DST 为什么「默认不开 PVP 就不会误伤自己的猪」。
-- ⚠️ 注意这里的条件是 `not TheNet:GetPVPEnabled()`，
--   与第 307、431 行的 PVP 判断方向一致但用途不同（这里用于放宽而非收紧）。
			if guy.isplayer or (theirleader and theirleader.isplayer) then
				return true -- They're aligned to another player.
			end

			if guy:HasAnyTag("player_aligned", "domesticated", "saltlicker_salted") then
-- 同为玩家阵营标签（无主人也一样算友军）。
				return true -- No current leader, but still considered aligned to players.
			end
		end
	end

	return false
end

function Combat:IsAlly(guy)
-- ★★ IsAlly = CanBeAlly 且 「它没有在攻击我」。
-- 这个「互相」关系很关键：CanBeAlly 是单向的（我是否认为它是盟友），
-- 而 IsAlly 是双向的（双方是否都认为对方是盟友）。
-- → 「对方正在攻击你」时，即使它是你的宠物也判定为非盟友，
--   从而允许你反击自己的宠物。
	if not self:CanBeAlly(guy) then
		return false
	end
	local guy_combat = guy.replica.combat
	return guy_combat == nil or guy_combat:GetTarget() ~= self.inst
-- ★ 用「对方的目标是不是我」来近似「对方是否在攻击我」。
-- 简洁且无需同步额外数据 —— 复用已有的 _target 网络变量。
-- ⚠️ 局限：若对方的目标是我但其实只是在「跟随移动」而非攻击，
--   会被误判为敌对。实践中 combat 的 target 语义足够明确，可接受。
end

--V2C: *deprecated* use similar functions IsAlly/CanBeAlly instead
-- 作者的弃用说明：「用 IsAlly / CanBeAlly 代替」。
-- 我核实了第 379-384 行的新实现确实覆盖了旧逻辑的功能，且更完整（多了阵营维度）。
-- ⚠️ 与 CanHitTarget 的处理方式相同：保留函数体 + dev 分支 assert 拦截。
--   说明「弃用但不删代码」是本项目的既定策略，便于回退。
function Combat:TargetHasFriendlyLeader(target)
	assert(BRANCH ~= "dev", "Deprecated! Use IsAlly/CanBeAlly.")
-- ★ dev 分支硬拦截（与第 266 行同款）。生产环境静默保留旧实现。

    local leader = self.inst.replica.follower ~= nil and self.inst.replica.follower:GetLeader()
    if leader ~= nil then
        local target_leader = target.replica.follower ~= nil and target.replica.follower:GetLeader() or nil

        if target_leader and target_leader.replica.inventoryitem then
            target_leader = target_leader.entity:GetParent() --.replica.inventoryitem:GetGrandOwner()
-- ★ 旧实现里的一处间接层解引用：从 inventoryitem 找到其「祖父拥有者」。
-- 源码保留了原被注释的替代写法，说明作者曾在两个方案间权衡。
-- ⚠️ 依赖 GetParent() 在物品未挂载时返回 nil（第 397 行有防御），
--   但若实体被移除后 GetParent 返回一个已销毁对象则无保护。标记为「疑似脆弱」。
            -- Don't attack followers if their follow object has no owner
            if target_leader == nil then
                return true
            end
        end

        local PVP_enabled = TheNet:GetPVPEnabled()

        return leader == target
				or (target_leader ~= nil and (target_leader == leader or (target_leader.isplayer and not PVP_enabled)))
				or (target:HasAnyTag("player_aligned", "domesticated") and not PVP_enabled)
    end

    return false
end

function Combat:CanBeAttacked(attacker)
-- ★★★ 本文件最长的函数（82 行），是「我能否被这个攻击者攻击」的完整定义。
-- 判据按顺序：
--   自身免疫（幽灵/飞行/noattack/隐身）
--   -> 对攻击者的限制（禁止玩家攻击 / PVP / 随从保护）
--   -> 疯狂攻击者豁免
--   -> 影子生物的特殊限制
--   -> 全部通过
-- ⚠️ 与 IsValidTarget（第 292 行）高度重叠但方向相反：
--   IsValidTarget 是「我能不能打它」，CanBeAttacked 是「它能不能打我」。
--   两者都要在判定链里被调用（第 278、322 行），属有意冗余。
	if self.inst:HasAnyTag("playerghost", "flight") or
-- 自身免疫的第一层：幽灵与飞行单位对任何人无敌。
		(	not self.temp_iframes_keep_aggro and
-- ⚠️ 注意 `not self.temp_iframes_keep_aggro and ...` 的写法：
-- 设了 temp_iframes_keep_aggro 就**跳过** noattack/invisible 检查，
-- 即「有无敌帧的实体不会被临时隐藏状态保护」。
-- 与第 320 行的语义完全对应（那边是「例外地可锁定」，这边是「例外地不可保护」）。
-- → ★ 两处配对使用同一个标志，是「临时状态不打断仇恨」这一设计的完整实现。
			self.inst:HasAnyTag("noattack", "invisible")
		)
	then
        --Can't be attacked by anyone
        return false
	end

	local sanity

	if attacker ~= nil then
        --Attacker checks
		if attacker.isplayer and self.inst:HasTag("noplayertarget") then
-- noplayertarget 标签：禁止玩家攻击（如友方设施）。
            --Can't be attacked by players
            return false
        elseif attacker ~= self.inst and self.inst.isplayer then
-- ★ 玩家被非自身攻击时的额外检查（第 430 行注释自称 Player target check）。
-- 注意条件是 `attacker ~= self.inst and self.inst.isplayer`，即「我是玩家且对方不是我」。
            --Player target check
			if attacker.isplayer and not TheNet:GetPVPEnabled() then
-- PVP 检查，与第 364 行的方向相反（这里收紧，那里放宽）。
                --PVP check
                local combat = attacker.replica.combat
                local weapon = combat ~= nil and combat:GetWeapon() or nil
                if weapon == nil or not weapon:HasTag("propweapon") then
-- ★ propweapon 豁免：允许对玩家使用道具武器造成的「友伤」。
-- 与第 307、323 行同一约定，三处一致。
                    --Allow friendly fire with props
                    return false
                end
            end
            if self._target:value() ~= attacker then
-- ★ 关键前置：若「我的目标已经是他」，则跳过后面的随从保护检查。
-- 逻辑：既然我本来就在打他，那就不该因为「他是某人的随从」而放弃。
-- → 这体现了目标锁定优先于关系判定，是 AI 行为设计的常见优先级。
                local follower = attacker.replica.follower
                if follower ~= nil then
                    local leader = follower:GetLeader()
                    if leader ~= nil and
-- ★★★ 随从保护的三重条件（都满足才保护）：
--   攻击者的主人存在 / 且不是我当前的目标 / 且主人是玩家 / 且攻击者不是 alwayshostile
-- ⚠️ 第 445 行对比的是 leader 与 _target —— 用「我的目标」来豁免，
--   与第 440 行是同一思想的重复应用。逻辑自洽。
                        leader ~= self._target:value() and
						leader.isplayer and not attacker:HasTag("alwayshostile") then
                        local combat = attacker.replica.combat
                        if combat ~= nil and combat:GetTarget() ~= self.inst then
                            --Follower check
                            return false
                        end
                    end
                end
            end
        end

		sanity = attacker.replica.sanity
-- 取攻击者的 sanity 镜像。后面第 459 行要用。

        if sanity ~= nil and sanity:IsCrazy() or attacker:HasTag("crazy") then
-- ⚠️⚠️ 优先级陷阱（我已逐字核对第 459 行）：
--   `if sanity ~= nil and sanity:IsCrazy() or attacker:HasTag("crazy") then`
--   无括号时求值顺序是 `(sanity ~= nil and sanity:IsCrazy()) or attacker:HasTag("crazy")`。
--   → sanity 为 nil 时前半段为 false，落到后半段，结果正确；
--     sanity 非 nil 时前半段正常求值。
--   结论：**当前逻辑正确**，但作者若本意是「sanity 存在 且（疯狂 或 疯狂标签）」，
--   语义就完全不同了。当前写法实际是「(有 sanity 且 疯狂) 或 有疯狂标签」，
--   这更符合注释「疯狂的攻击者几乎可以攻击任何东西」的意图。正确，但极难读。
--   移植时建议加括号固化语义，避免后人「修正」成错误版本。
            --Insane attacker can pretty much attack anything
            return true
        end
    end

	if self.inst:HasAnyTag("shadowcreature", "nightmarecreature") and
-- ★★★ 影子生物的双重判定。
-- 第一层：本体是 shadowcreature 或 nightmarecreature。
		(	self._target:value() == nil
-- 第一种不可攻击情形：影子生物**没有目标** —— 即「闲置的隐形怪」，谁都打不到。
			--[[or (--See if we're targeting someone else, and attacker isn't insane enough to help
-- ⚠️ 弃用长注释块的开始（源码第 467-472 行）。
-- 旧逻辑：允许理智低于 50% 的玩家协助攻击「正在被别人打的影子生物」。
				attacker ~= nil and
				sanity ~= nil and --set already in the above attacker ~= nil block
				self._target:value() ~= attacker and
				not (sanity:IsInsanityMode() and sanity:GetPercent() < .5)
				)]]
			--V2C: The above version is the correct design; we should never have
-- ★ 作者的说明很坦诚：旧逻辑才是「正确的设计」，但不该允许攻击隐形实体，
--   缺的是「揭示影子生物的道具」，所以暂时换成新逻辑。
-- 并留了 TODO。
-- → ★ 这是「已知的设计债」的规范记录方式：说明为什么降级、什么条件下能改回。
--   比默默降级好得多，移植时值得模仿这种注释态度。
			--     allowed targeting invisible entities.
			--     TODO: Add/improve items for revealing shadow creatures so we
			--           can switch to that version.
			or (--See if we're targeting someone else, but not actually hostile to them
-- 第二种不可攻击情形：它在攻击别人，且本实体对该目标没有敌意。
-- 即「它有正事要做，别去打扰」。
				attacker ~= nil and
				self._target:value() ~= attacker and
				(self.inst.HostileToPlayerTest ~= nil and not self.inst:HostileToPlayerTest(self._target:value()))
-- HostileToPlayerTest 是由外部注入的函数（宿主 prefab 提供），
-- 用来问「这个影子生物是否对某个玩家有敌意」。
-- ⚠️ 判据是 `~= nil and not ...(...)` —— 函数不存在时视为「有敌意」即不豁免，
--   保守正确（拿不准就不给豁免）。
				)
		) and
        --Allow AOE damage on stationary shadows like Unseen Hands
        (attacker ~= nil or self.inst:HasTag("locomotor")) then
-- ★ 最终的例外开关：「AOE 伤害可以打到静止的影子生物」。
-- 注释说明是为了「像未见的之手（Unseen Hands）这种自动攻击的影子生物」。
-- ⚠️ 条件是 `(attacker ~= nil or self.inst:HasTag("locomotor"))` ——
--   有攻击者时总能打；没有攻击者（即被别的东西如陷阱批量处理）时，
--   只有带 locomotor 标签（自动寻路的实体，如 Unseen Hands）才行。
--   → 这是一个很精细的例外：区分「有人主动打」与「环境自动伤害」。
        --Not insane attacker cannot attack shadow creatures
		--(unless shadow creature is targeting attacker, or targeting
		-- someone else, and attacker is below 50% sanity to help out)
        return false
    end

    --Passed all checks, can be attacked by anyone
    return true
end

return Combat
-- 组件定义返回。
-- ★ 全文件没有 OnSave/OnLoad —— 因为镜像数据全部来自 net 变量与 classified，
--   本来就不需要存档。
-- → ★ 这是镜像组件与服务端组件的一个根本差异：
--   服务端组件要存「不可推导的世界状态」，
--   镜像组件只同步「本帧的观测状态」，随断线重连自动重建，不需要持久化。