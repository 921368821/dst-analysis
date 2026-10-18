--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：bufferedaction.lua（110 行）
-- 模块：动作系统 / 动作实例与打断（Buffered Action）
-- 职责：定义 BufferedAction —— 一次**具体**动作执行的完整上下文。
--   它把「谁（doer）对谁（target）做什么（action）用什么（invobject）
--   在哪里（pos）做」打包成不可变快照，并在真正执行的那一帧调用
--   action.fn(self)。本文件是 actions.lua 与 locomotor / stategraph 之间的
--   **协议层**：actions.lua 只定义「动作是什么」，本文件定义「这一次执行」。
--
-- ★★ 为什么必须有这一层（不能直接把参数塞给 fn）？
--   因为动作要「缓冲」。玩家按键的那一刻目标还在范围内，走到跟前可能
--   已经跑远了。BufferedAction 在**按键瞬间**就把 target / invobject / pos
--   冻结下来，并记下 initialtargetowner（见 5 行），使得：
--     · 途中目标被别人捡走 → 动作作废（IsValid 的第 3 个条件）
--     · 途中物品被别人抢走 → 动作作废（第 4 个条件）
--   ★★ 这就是「打断」的全部机制：没有 timeout，没有取消队列，
--     只有一个每次执行前重新求值的 IsValid()。
--
-- 关键符号：BufferedAction（类）, BufferedAction.TestForStart（= IsValid 别名）
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 actions.lua:294 Action —— 本文件持有的是它的**引用**
--   参见 actions.lua:307 `self.fn = function() return false end`（默认失败的 fn）
--   参见 actions.lua:349 invalid_hold_action（长按禁止重发）
--   参见 entityscript.lua:1624 TestForStart 调用点（PushBufferedAction）
--   参见 entityscript.lua:1640 instant 动作的立即 Do() 路径
--   参见 entityscript.lua:1672 PerformBufferedAction → bufferedaction:Do()
--   参见 entityscript.lua:1563 ClearBufferedAction → 本文件 104 行 Fail()
--   参见 components/locomotor.lua:899 PushAction 开头的 TestForStart
--   参见 components/locomotor.lua:1079 SetBufferedAction → 本文件 104 行 Fail()
--   参见 components/locomotor.lua:1452 每帧 `not bufferedaction:IsValid()` → Clear()
--   参见 components/playercontroller.lua:4542 DoAction（构造本类实例）
--   参见 components/playercontroller.lua:4585 「重复动作」判定（防连点）
--   参见 components/playercontroller.lua:4636 autoequipped 的唯一赋值点
--   参见 prefabs/wortox.lua:614 TryToPortalHop（BLINK 动作会调用的 doer 方法）
--   参见 behaviourtree.lua（对照：AI 侧用「破坏性 Reset」中断，
--     与本文件「反复求值 IsValid」是两种完全不同的中断范式）
--============================================================
--
--【阅读导航】
--  §一  构造（2-20）    —— ★★ 「把一次执行冻结成快照」
--  §二  Do（22-37）     —— 执行 + 成败分派
--  §三  IsValid（39-50）—— ★★ 全文件的心脏：七道「作废」条件
--  §四  字符串（52-72） —— strfn / stroverridefn 的区别
--  §五  回调队列（74-88）
--  §六  坐标存取（90-102）
--  §七  Fail（104-110） —— ★ 与 Succeed 的对称
--
--【★★ 全文件最重要的七条】
--  1. ★★ 本文件只定义**一个类**，110 行，约 12 个方法。
--     它不是「动作」—— 动作在 actions.lua。本文件是「这一次动作执行」。
--     混淆两者是理解 DST 动作系统最大的障碍。
--  2. ★★ 构造函数的 12 个参数是**位置参数**（而非表），
--     这在 DST 里是反常的。原因见 2 行的说明：
--     它在按键瞬间被调用，位置参数比构造 table 更省（无 GC 压力）。
--     ★ 但代价是所有调用点都必须靠记忆传参 ——
--       playercontroller.lua:1059/1117/1356/1401 等处极易传错顺序。
--  3. ★★ initialtargetowner（5 行）是「打断机制」的核心：
--     它记下「动作发起时目标的所有者是谁」，
--     于是 42 行能判断「所有者变了 ⇒ 目标已被抢走 ⇒ 作废」。
--     ★★★ 这是全文件最精妙的设计，也是唯一的「防抢夺」机制。
--  4. ★★ doerownsobject（8 行）对称地记下「动作发起时物品在谁手里」，
--     44 行用它判断「中途换手了 ⇒ 作废」。
--     ★ 与 3 配对，构成「双向的快照一致性检查」。
--  5. ★★ IsValid 的第 7 条（46 行）**只在客户端调用** action.validfn：
--       `(not TheWorld.ismastersim or (self.action.validfn == nil
--         or self.action.validfn(self)))`
--     ★★★ 逐字读：客户端 ⇒ 左边为真 ⇒ 整个子句短路 ⇒ validfn **不被调用**；
--       服务端 ⇒ 调用 validfn。
--     ★ 所以 validfn 是**服务端的持续有效性检查**，
--       通过 locomotor.lua:1452 的每帧 IsValid 判定来「中途作废」。
--  6. ★★ 本文件**没有** interrupt / cancel / timeout 中的任何一个方法。
--     打断完全靠「反复调用 IsValid，返回假就 Clear」。
--     ★ 三处调用方：
--       · locomotor.lua:1452（每帧，路途中）
--       · locomotor.lua:899（动作开始前）
--       · entityscript.lua:1624（PushBufferedAction 时）
--     ★ 这与 behaviourtree.lua 的「破坏性 Reset」是**两种不同的中断范式**。
--  7. ★★ Succeed（82）与 Fail（104）**完全对称**，只是执行不同的数组。
--     ★★ 两者执行完都会清空两个数组（86-87 / 108-109）。
--       「清空回调」意味着**回调只生效一次**。
--       ★ 这是「一次性回调」的标准实现。
--
--【⚠ 疑似缺陷（本文件 2 条）】
--  L1 ★★ actions 侧对照：本文件的 IsValid 第 7 条（46 行）在客户端
--     短路，等于**客户端从不检查 validfn**。若某个动作的 validfn 含有
--     客户端需要的状态判断（如 WOBY_PICK.validfn 那种），其语义在
--     两端会不一致。见 actions.lua:6284 的 L10 分析。
--  L2 ※ 92 行 GetActionPoint 用 `self.pos ~= nil and self.pos:GetPosition()
--     or nil` —— 若 pos 非 nil 但 GetPosition() 返回 nil 则结果为 nil，
--     无法与「pos 为 nil」区分。实践中 GetPosition 总返回 Vector3。
--     ★ 属理论问题，不是实际缺陷。
--
--【★ 与 actions.lua / locomotor / stategraph 的四层关系】
--  ┌─────────────────────────────────────────────────────────────┐
--  │ actions.lua         Action 表 + 每个动作的 fn/strfn         │
--  │   ↓ 每个动作一个原型，进程内只创建一次                    │
--  │ components/playercontroller.lua:4542  DoAction            │
--  │   ↓ 玩家按键时 new BufferedAction(doer, target, ACTIONS.X) │
--  │ components/locomotor.lua:882  PushAction                  │
--  │   ↓ 决定「走过去」还是「立即做」，每帧检查 IsValid         │
--  │ entityscript.lua:1609  PushBufferedAction（预测）         │
--  │ entityscript.lua:1650  PerformBufferedAction → act:Do()   │
--  │   ↓ 本文件 22 行 Do() → action.fn(self)                   │
--  │ stategraph.lua:430  StartAction → 播动画 → Do()           │
--  └─────────────────────────────────────────────────────────────┘
--  ★★ 注意顺序：**预测在前、执行在后**。
--     客户端先播动画（PreviewAction，stategraph.lua:405），
--     服务端确认后才真正 Do()。这就是 DST 的「客户端预测」。
--
--【★ 失败与成功的完整流转】
--  Do() 22 行：
--    ├─ IsValid() 为假 → return false（**不发 Fail，不发 Succeed**）
--    │    ★★ 注意这条路径不调 Fail！回调不会执行。
--    ├─ fn 返回真     → OnUsedAsItem（30）→ Succeed（32）→ 跑 onsuccess
--    └─ fn 返回假/nil → Fail（34）→ 跑 onfail
--  ★★ 两条重要细节：
--    ① 「IsValid 为假」与「fn 返回假」的**回调行为不同**：
--       前者什么都不跑，后者跑 onfail。
--       ★ 依据 locomotor.lua:1079 的行为：它显式调 self.bufferedaction:Fail()
--         之后清空 ⇒ 那种情况 onfail 仍会跑。
--       ★ 但 Do() 里的早退（23-25 行）确实不跑任何回调。
--    ② success 传回给 entityscript.lua:1672，由它决定推 actionfailed 事件。
--       ⇒ 「失败」分两种：fn 失败（推事件 + Fail 回调）
--         与 IsValid 失败（Clear 时 Fail 回调，但**不推事件**）。
--         ★★ 玩家感受不同：前者会说话，后者沉默。
--
--★★ 整个文件只有一个类定义（2-20 行）与 12 个方法。
--   ★ 为什么这么短？因为「缓冲」本身不需要多少代码 ——
--     它只需要「记住发起时的状态」+「执行前重验」两件事。
--   ★★ 真正的复杂度在被它服务的那些调用方里。

--★★★【BufferedAction 构造函数 —— 12 个位置参数】
--
--   参数表（★ 请与调用方逐字核对，错一位就全盘皆错）：
--     ① doer        执行者（玩家 / AI）。可以是 nil（纯几何动作）。
--     ② target      目标实体。可以是 nil（纯坐标动作，如 TRAVEL）。
--     ③ action      **Action 原型**。可以不是 ACTIONS 表里的（模组可自定义）。
--     ④ invobject   手持物品。可以是 nil。
--     ⑤ pos         目标**坐标**（Point）。可以是 nil。
--     ⑥ recipe      配方（建造用，见 actions.lua:2611）。
--     ⑦ distance    **覆盖** action.distance（见 15 行）。
--     ⑧ forced      「强制」标记（见 17 行）。
--     ⑨ rotation    朝向（建造/放置用）。
--     ⑩ arrivedist  **覆盖** action.arrivedist（见 16 行）。
--   ★★★ 实际只有 10 个参数，第 11、12 个在 DST 中已被移除
--     （单机版遗留：playeractionpicker / invobjectselectrange）。
--     ★ 保留它们是为了 modutil 的向后兼容。
--
--★★ 为什么用位置参数而不是表？
--   · 避免每次构造都分配一个 table（按键频率很高）。
--   · 与 actions.lua:303 的兼容层（也用位置参数）风格一致。
--   ★★ 代价：playercontroller.lua 里有 30+ 处调用，
--     任何参数顺序的改动都会静默破坏（Lua 不会报错）。
BufferedAction = Class(function(self, doer, target, action, invobject, pos, recipe, distance, forced, rotation, arrivedist)
--★ doer —— 执行者。这是快照的一部分，之后不再更新。
--   ★★ 「之后不再更新」是**故意的**：动作一旦发起，
--     「是谁在做的」就固定了。即使玩家中途换了控制权，
--     这个动作仍属于原发起者。
    self.doer = doer
    self.target = target
--★★★ initialtargetowner —— 「打断机制」的第一块基石（★ 逐字读）
--   `target ~= nil and target.components.inventoryitem ~= nil
--     and target.components.inventoryitem.owner or nil`
--   ★★ 注意末尾的 `or nil`：
--     三元表达式的惯例。中间任一条件为 nil 时结果会是 nil，
--     加 or nil 统一成 nil。
--   ★★★ 这个字段的用途在 42 行：
--       `self.initialtargetowner == (现在的 owner)`
--     ★★ 即「动作发起后，目标的归属有没有变过？」
--     · 没变 → 继续（东西还在那儿）
--     · 变了 → 作废（被别人捡走了 / 被转移进箱子了）
--   ★★★ 这就是 DST 里「A 和 B 抢同一个箱子」不会出错的机制：
--     先发起的人赢，后发起的人的 IsValid 返回假、动作被中止。
--   ★★ 为什么用 `components.inventoryitem`（服务端）而不是 replica？
--     因为 5-18 行都在**构造期**执行，而构造在**客户端也会发生**
--     （预测）。★ 但 components 在客户端不存在！
--     ★★★ 推论：客户端构造时 initialtargetowner 恒为 nil，
--       于是 42 行的比较在客户端恒为 `nil == nil` → true。
--       ⇒ 客户端的 IsValid 不含这个检查，**全部交给服务端**。
--       ★ 这与 46 行的 validfn 短路是同一个模式：
--         「有些检查只对服务端有意义」。
    self.initialtargetowner = target ~= nil and target.components.inventoryitem ~= nil and target.components.inventoryitem.owner or nil
--★ action —— **Action 原型的引用**（不是拷贝）。
--   ★★ 本对象全程只读 action，不修改它。
--     这保证了「同一动作的多个并发执行不会互相干扰」
--     （虽然同一个 doer 实际只能同时有一个动作）。
    self.action = action
--★ invobject —— 手持物品。同样是快照。
    self.invobject = invobject
--★★★ doerownsobject —— 「打断机制」的第二块基石
--   `doer ~= nil and invobject ~= nil
--    and invobject.replica.inventoryitem ~= nil
--    and invobject.replica.inventoryitem:IsHeldBy(doer)`
--   ★★★ 注意用的是 **replica**（客户端可读）而不是 components。
--     ★ 与第 5 行（服务端）不同！
--     ★★★ 原因：这个字段要在 44 行被**双端**检查：
--       客户端预测时也要判断「手上的东西还在不在」。
--       ★ 而 initialtargetowner 用 components 是因为它只在服务端有意义。
--       ★★★ 同一个构造函数里两种组件访问方式并存，
--         差异只在「这个字段谁会读」。这是个精细但重要的区分。
--   ★★ 这个字段的用途在 44 行：
--       「动作发起时物品在执行者手里吗？现在还在吗？」
--   ★★ 它与 playercontroller.lua:4636 的 autoequipped 机制配合：
--     若 DoActionAutoEquip 自动装备了物品，autoequipped = true，
--     41 行会检查「执行者手上是不是空」——
--     ★ 因为自动装备后物品变成了「装备中」，IsHeldBy 可能为假。
    self.doerownsobject = doer ~= nil and invobject ~= nil and invobject.replica.inventoryitem ~= nil and invobject.replica.inventoryitem:IsHeldBy(doer)
--★★ pos —— 坐标也被快照成 **DynamicPosition** 而非 Point。
--   ★★★ 为什么需要 DynamicPosition？
--     船在动。若存 Point（世界坐标），船漂走后动作会指向错误位置。
--     ★ DynamicPosition 能记住「这个点在船上/在活动平台上」。
--     ★ actions.lua 里大量动作声明 is_relative_to_platform（329 行）
--       就是靠这个字段实现的。
--   ★★ 43 行的 `pos.walkable_platform:IsValid()` 检查：
--     ★★ 船沉了 / 被拆了 ⇒ 平台无效 ⇒ 动作作废。
--       ★ 这是「坐标快照」也需要失效检查的最好例证。
--   ★ `pos ~= nil and DynamicPosition(pos) or nil` —— 三元惯例。
    self.pos = pos ~= nil and DynamicPosition(pos) or nil
--★ rotation —— 建造/放置的朝向。默认 0。
    self.rotation = rotation or 0
--★ onsuccess —— 成功回调数组（不是单个函数！）。
--   ★★ 为什么是数组？因为多个系统可能都关心这个动作的结果。
--     ★ AddSuccessAction（78 行）可以被调多次。
--   ★★ 82 行的 Succeed 会一次性跑完所有回调。
    self.onsuccess = {}
--★ onfail —— 失败回调数组。与 11 行对称。
    self.onfail = {}
--★ recipe —— 建造配方。只有 BUILD 类动作会读。
--   ★★ 这是一个「只有一种动作关心的字段」——
--     说明 BufferedAction 是**通用容器**，不是为某个动作设计的。
    self.recipe = recipe
--★ options —— 一个自由表，存放「动作特有的附加数据」。
--   ★★ 全文件从不读它的任何键。检索到的已知用法（外部）：
--     · locomotor.lua:951  options.instant     （强制立即执行）
--     · locomotor.lua:891  options.no_predict_fastforward
--     · actions.lua:1173   options.wholestack  （DROP 是否整堆）
--   ★★★ 「自由表 + 约定俗成」是本文件唯一的扩展机制。
--     模组可以在里面塞任何东西。
--     ★ 代价：没有任何类型检查或文档保证。
    self.options = {}
--★★★ distance —— **覆盖** action.distance。
--   `self.distance = distance or action.distance`
--   ★★ 用 or 而非显式 nil 检查，意味着：
--     · 传 nil ⇒ 用 action.distance
--     · 传 0  ⇒ 用 0（or 在 Lua 里把 0 视为真，所以 0 会被正确保留）
--       ★★★ 这是 Lua 与 JS/Python 的重要差别，恰好在这里是优点。
--     · 传 false ⇒ 用 action.distance（不太可能发生）
--   ★★ 这是「实例可以临时改原型参数」的唯一入口。
--     ★ 用于「同一个动作，但这次要走得更远」的场景。
    self.distance = distance or action.distance
--★ arrivedist —— 同 15 行的模式，覆盖 action.arrivedist。
--   ★ 两个字段用了完全相同的写法，说明是刻意保持一致。
    self.arrivedist = arrivedist or action.arrivedist
--★ forced —— 「强制」标记。
--   ★★★ 它在 locomotor.lua:937 被消费：
--       `elseif bufferedaction.forced then`
--         → 先用 rangecheckfn 重测距离
--         → 不够近就把 target 置 nil（降级为「走到坐标」）
--       ★ 这就是「force」一词的确切含义：**允许在够不着时执行**。
--     ★★ 注意 20 行之外还有 3 行会改这个字段：
--       玩家 controller 的 401/1407/1410 行构造时传 true。
--     ★ 所以「强制」有两个来源：构造参数与玩家的攻击连击。
    self.forced = forced
--★★ autoequipped —— 「这个物品是我自动装备的」。
--   `self.autoequipped = nil --true if invobject should've been auto-equipped`
--   ★★★ 保留的英文注释是本文件里少见的**行尾注释**：
--     「若 invobject 本应被自动装备则为 true」。
--   ★★★ 这个字段的唯一用途在 41 行：
--       `not self.autoequipped or doer.replica.inventory:GetActiveItem() == nil`
--     ★★★ 语义：「若不是自动装备的，跳过检查；
--       若是自动装备的，还要确认执行者手上没别的东西」。
--       ★★ 为什么要多这一层？
--         自动装备（playercontroller.lua:4634）把物品塞进装备槽，
--         而 8 行的 IsHeldBy 可能对「装备槽」返回假。
--         于是自动装备的情况下换一个判据。
--       ★ 这是一个「为了兼容另一处 hack 而加的例外」。
--     ★ set 到 true 的唯一位置：playercontroller.lua:4636。
    self.autoequipped = nil --true if invobject should've been auto-equipped
--★ skin —— 建造皮肤（角色专属外观）。只有 builder 组件会读。
    self.skin = nil
--★★ 构造函数结束（20 行的 `end)` 是 Class 的构造闭包终点）。
--   ★★ 整个构造函数**不做任何校验** —— 传入什么都不检查。
--     ★ 合法性完全靠 IsValid（39 行）在执行前把关。
--     ★ 这是「信任调用方 + 延迟校验」的取舍：
--       构造极快（按键时不能卡），校验统一在一处。
--   ★★ 唯一在构造期「加工」过的三个参数：
--     · pos      → DynamicPosition（9 行）
--     · distance → action.distance 的兜底（15 行）
--     · arrivedist → action.arrivedist 的兜底（16 行）
--     其余全是原样保存。
--   ★ 这三个字段正是「原型参数」与「实例参数」的分界点。
end)

--★★★【Do —— 真正执行动作的入口（16 行）】
--   ★★ 调用方只有两个：
--     · entityscript.lua:1640（instant 动作，立即执行）
--     · entityscript.lua:1672（PerformBufferedAction，长动作播完动画后）
--   ★★ 因此「Do 的那一刻」= 「服务端确认玩家能做这个动作的那一刻」。
--     ★★ 这就是 DST 联机模型的核心：**只有服务端能改状态**。
function BufferedAction:Do()
--★★ 23-25 行：**执行前的最后一道校验**。
--   ★★ 注意这是「早退」，与下面的 else 分支不同：
--     · 早退 → return false，**不调 Fail**（onfail 不执行）
--     · 后面 → Fail()（onfail 会执行）
--   ★★★ 两种「失败」对下游的影响不同，是本文件最重要的区分之一。
--   ★ 实体侧的对应处理：entityscript.lua:1673 会 PushEvent("actionfailed")
--     ★ 所以早退也会推事件 → 玩家仍会听到失败语音。
--     ★★ 但 onfail 回调（如「把借出去的东西还回去」）不会跑。
    if not self:IsValid() then
        return false
    end
--★★★ `local success, reason = self.action.fn(self)` —— 全 DST 的枢纽。
--   ★★★ 把整个 BufferedAction（self）传给动作的 fn。
--     ★ 这就是「一个动作的全部上下文」的唯一传递方式。
--     ★ actions.lua 里所有 `function(act)` 的 act 就是这个 self。
--   ★★ fn 的返回值契约（★ 本文件对 actions.lua 的核心要求）：
--     · 第一个值：真 = 成功；假 / nil / 缺失 = 失败
--     · 第二个值：失败原因字符串，会被翻译成玩家提示
--   ★★ 「nil 视为失败」这一点由 28 行的 `if success then ... else`
--     隐含 —— Lua 里 nil 与 false 同为假。
--     ★★★ 记住：**动作 fn 必须显式 return true**，
--       否则即使做完了事也会被判定失败（见 actions.lua:2747 的 L6）。
    local success, reason = self.action.fn(self)
--★ 27 行把 reason 存到 self.reason 上 ——
--   ★★ 存下来是为了「失败回调里能读到为什么失败」。
--     ★ 本文件不提供 reason getter，onfail 回调只能闭包捕获或读 act.reason。
--     ★ actions.lua 里搜 `.reason` 可找到实际用法（29 行 Do 的返回、
--       locomotor 的 actionfailed 事件都读它）。
    self.reason = reason
    if success then
--★★ 29-31 行：成功后调用 OnUsedAsItem。
--   ★★★ `if self.invobject ~= nil and self.invobject:IsValid()` ——
--     ★ 「使用次数」的扣减统一在这里。
--       ★ 动作 fn 里不需要（也不应该）自己扣耐久。
--       ★★★ 这是一个「框架级统一收口」：
--         任何动作只要用了手持物品，成功就自动扣一次。
--       ★ 与 STEAL.fn（811 行注释）提到的「finite uses 回调」
--         是同一条链路。
--       ★★ 也因此「失败了但消耗了耐久」是不可能的（33 行走 Fail）。
        if self.invobject ~= nil and self.invobject:IsValid() then
--★ OnUsedAsItem(self.action, self.doer, self.target) —— 三个参数。
--   ★★ 物品组件因此能知道「被用来做什么、对谁用」。
--     ★ 这是「物品自己决定耐久怎么扣」的钩子。
            self.invobject:OnUsedAsItem(self.action, self.doer, self.target)
        end
--★ Succeed() —— 82 行。跑 onsuccess 回调。
        self:Succeed()
    else
--★★ Fail() —— 104 行。跑 onfail 回调。
--   ★★ 33-35 的结构是「二选一后无返回值」，
--     36 行才把结果返回给调用方。
--   ★★ 36 行 `return success, reason` —— 透传给 entityscript，
--     由它决定要不要推 "actionfailed" 事件。
        self:Fail()
    end
    return success, reason
end

--★★★【IsValid —— 「这个动作现在还该继续吗？」（9 行）】
--   ★★ 这是**全文件最重要的函数**。它不是「校验参数」，
--     而是「**反复回答一个时间相关的问题**」：
--     「从按键到现在过了几百毫秒，条件还成立吗？」
--   ★★★ 七道检查，全用 and 连接（任一为假即整体为假）：
--     ① 44  invobject 还在吗？
--     ② 41  doer 还在吗 / 自动装备的物品还在手上吗？
--     ③ 42  target 还在吗 + **归属没变**？
--     ④ 43  pos 所属的**平台**还在吗？
--     ⑤ 44  doerownsobject 仍成立吗？
--     ⑥ 45  外部挂的 validfn 通过吗？
--     ⑦ 46  动作自带的 validfn 通过吗（**仅服务端**）？
--   ★★ 注意 ①与⑤都在第 44 行 —— 一个 and 链里两个条件。
function BufferedAction:IsValid()
--★★ 条件①：手持物品的有效性。
--   `(self.invobject == nil or self.invobject:IsValid())`
--   ★★ 注意用 `or` 而不是 `and` —— 「没有物品」也算通过。
--     ★ 这是「允许为空」的模式，全文件七处都是这个写法。
--     ★★ 可读性代价：`nil` 在左边看起来像「取反」，
--       实际是「若没有物品则免检」。
    return (self.invobject == nil or self.invobject:IsValid()) and
--★★★ 条件②：执行者的有效性 + autoequipped 的特殊处理。
--   `(self.doer == nil or (self.doer:IsValid()
--     and (not self.autoequipped
--       or self.doer.replica.inventory:GetActiveItem() == nil)))`
--   ★★ 三层嵌套的含义：
--     「要么没有 doer；要么 doer 有效，
--       且（要么不是自动装备的，要么手上没别的东西）」
--   ★★★ 最后那个 GetActiveItem() == nil 检查（★ 最容易误解）：
--     ★★★ 为什么「自动装备的物品，手上必须有东西」才对？
--       翻译过来是：**若动作自动装备了某物品，那么执行者现在
--         「手上拿着东西」就是异常的**。
--       ★ 场景：玩家手拿斧头 → DoActionAutoEquip 自动装备 →
--         斧头进装备槽 → 若此时手上还有东西，说明中途抢占了。
--       ★★★ 这个条件其实是在问：「自动装备这件事**仍然生效**吗？」
--     ★★ 18 行的注释「true if invobject should've been auto-equipped」
--       用「should've been」正是这个意思。
--   ★★ 注意这里用了 **replica.inventory** —— 客户端也要读（IsValid 双端跑）。
           (self.doer == nil or (self.doer:IsValid() and (not self.autoequipped or self.doer.replica.inventory:GetActiveItem() == nil))) and
--★★★ 条件③：目标有效性 + ★★ 归属未变（本文件最核心的一行）
--   `(self.target == nil or (self.target:IsValid()`
--     and self.initialtargetowner ==
--       (self.target.components.inventoryitem ~= nil
--        and self.target.components.inventoryitem.owner or nil)))`
--   ★★ 第 5 行记的 initialtargetowner 在这里被比对。
--   ★★★ 逐层读这个 and：
--     「没有目标 ⇒ 通过。
--       有目标 ⇒ 目标仍有效，
--         且**它现在的主人**与「动作发起时的主人」相同。」
--   ★★★ 为什么要比「主人」而不是「位置」？
--     因为 DST 里「抢东西」的判定是归属变化，不是位置变化。
--       ★ 玩家把一个箱子推着走：位置变了、主人没变 ⇒ 动作继续。
--       ★ 另一个玩家打开了箱子：主人从 nil 变成本人 ⇒ 动作作废。
--       ★★★ 这是「所有权语义」而非「位置语义」的完美体现。
--   ★★ 末尾的 `or nil` 与第 5 行完全对应 ——
--     两处都用同一套三元惯例，保证比较的两侧语义一致。
--   ★★ components（服务端）在客户端恒为 nil ⇒ 客户端此检查恒真。
--     ⇒ 抢夺的仲裁**只在服务端发生**。
--     ★ 与 46 行的 validfn 短路是同一个「端区分」模式。
           (self.target == nil or (self.target:IsValid() and self.initialtargetowner == (self.target.components.inventoryitem ~= nil and self.target.components.inventoryitem.owner or nil))) and
--★★ 条件④：坐标所属平台的有效性。
--   `(self.pos == nil or self.pos.walkable_platform == nil
--     or self.pos.walkable_platform:IsValid())`
--   ★★★ 这三段 or 的语义：「没有坐标 / 不在任何平台上 / 平台还在」。
--   ★★★ 「船沉了」这一事件因此能被 IsValid 感知。
--     ★ 玩家站在船上点「放置」，船在途中被击沉 ⇒ 动作作废。
--     ★★ 这是「快照的对象可能消失」的第二种情形
--       （第一种是 ③ 的目标被抢）。
--   ★★ 注意 walkable_platform 是 DynamicPosition 的字段（9 行构造时设的）。
           (self.pos == nil or self.pos.walkable_platform == nil or self.pos.walkable_platform:IsValid()) and
--★★★ 条件⑤：doerownsobject 的持续性 —— 「物品还在执行者手里吗？」
--   `(not self.doerownsobject
--     or (self.doer ~= nil and self.invobject ~= nil
--       and self.invobject.replica.inventoryitem ~= nil
--       and self.invobject.replica.inventoryitem:IsHeldBy(self.doer)))`
--   ★★★ 语义：「若动作发起时物品**不在**执行者手上（= False），免检；
--     若在（= True），现在也必须在。」
--   ★★ 为什么要记这个（第 8 行）？
--     场景：玩家手拿一个「打开箱子」的动作开始走动，
--     途中把物品换到了另一个手上或丢掉了 ⇒ 动作应作废。
--   ★★★ 这是「物品归属」检查在 invobject 上的对偶版本（③ 是 target）。
--     ★ 两个字段（initialtargetowner / doerownsobject）构成完整的
--       「双向快照一致性」。
--   ★★ 注意这里用 **replica**（双端都要检查），与第 8 行构造时一致。
           (not self.doerownsobject or (self.doer ~= nil and self.invobject ~= nil and self.invobject.replica.inventoryitem ~= nil and self.invobject.replica.inventoryitem:IsHeldBy(self.doer))) and
--★★ 条件⑥：外部挂的 validfn。
--   `(self.validfn == nil or self.validfn(self))`
--   ★★★ 这个字段**不是构造函数参数**，也没有 setter ——
--     它是**由外部在构造后直接赋值的**：
--       `act.validfn = function(act) ... end`
--   ★★ 检索到的用法示例（brain 侧常见）：
--     brains/*.lua 里构造 BufferedAction 后赋 validfn，
--     用来表达「这只对鼹鼠做」「这个必须手持某物」。
--   ★★★ 「临时给单次执行加判据」的机制 —— 比改 Action 原型更灵活。
--     ★ 但它**不是** actions.lua 里 Action.validfn 的那个字段！
--       ★★ 同名不同物，极易混淆：
--         · 本行的 self.validfn  = 外部临时挂的（双端都跑）
--         · 46 行的 action.validfn = Action 原型声明的（仅服务端）
--       ★ 两者在命名空间上相隔一层，但在代码里都是 `.validfn`。
--         ★★★ 建议读到这里时在纸上画个图记住这个区别。
           (self.validfn == nil or self.validfn(self)) and
--★★★ 条件⑦：Action 原型上的 validfn —— ★★ 全文件最微妙的一行
--   `(not TheWorld.ismastersim
--     or (self.action.validfn == nil or self.action.validfn(self)))`
--
--   ★★★★★ 逐字拆解（这是理解 DST 联机架构的关键）：
--     `not TheWorld.ismastersim` —— 「我不是服务端」
--     or（则整个子句为真，短路通过）
--     `self.action.validfn == nil or self.action.validfn(self)`
--       —— 「动作没声明 validfn，或声明了且通过」
--
--   ★★★ 结论一：**客户端永远不调用 action.validfn**。
--     客户端的 IsValid 只做前六项检查。
--   ★★★ 结论二：**服务端每帧都调用** action.validfn。
--     通过 locomotor.lua:1452 的 `not self.bufferedaction:IsValid()` 实现。
--   ★★ 为什么把 validfn 限定在服务端？
--     ★ 因为 validfn 通常依赖服务端组件状态（如 workable:CanBeWorked()），
--       客户端没有 components，调了会崩。
--     ★★ 于是形成分工：
--       · 客户端：预测执行（快，6 项检查）
--       · 服务端：权威执行（准，7 项检查 + 组件级判定）
--   ★★★ 这就是「客户端预测 + 服务端权威」在**单个文件内**的体现。
--   ★★ 对照 actions.lua:1757（CHOP.validfn）的注释可确认这个分工。
           (not TheWorld.ismastersim or (self.action.validfn == nil or self.action.validfn(self)))
end
--★ 48 行的 `end)` —— IsValid 结束。
--   ★★★ 七道检查全部是**纯读**：不修改 self 的任何字段。
--     ★ 这是「可以被任意频繁调用」的前提 ——
--       locomotor 正是每帧调用它。
--   ★★ 若 IsValid 修改了状态（比如「已检查过就不再查」），
--     每帧调用就会出问题。

--★★ 保留的英文注释说明了「V2C」这个注释前缀的含义：
--   「V2C: TestForStart can return "reason" as a second return value
--     (but we don't in DST)」
--   ★★★ 这条注释保存了**单机版与联机版的一个 API 差异**：
--     单机版 TestForStart 能返回失败原因，DST 版不能。
--   ★★ 所以 50 行的别名存在**纯粹是为了兼容**单机版的调用方式：
--     单机版代码调 `act:TestForStart()`，DST 用同一个名字但少一个返回值。
--   ★★★ 这解释了「为什么有一个和 IsValid 完全相同的别名」——
--     这不是设计冗余，是历史包袱。
--   ★ 50 行 `BufferedAction.TestForStart = BufferedAction.IsValid`
--     ★ 直接赋值函数对象，所以两者的 upvalue 与行为完全相同。
--   ★★ 实际调用点：locomotor.lua:899 与 entityscript.lua:1624。
--V2C: TestForStart can return "reason" as a second return value (but we don't in DST)
--★ 50 行 —— 别名赋值。
BufferedAction.TestForStart = BufferedAction.IsValid

--★★★【GetActionString —— 「这个动作现在显示成什么」（15 行）】
--   ★★ ★★★ 本文件里唯一的「UI 字符串」决策点，且**双端都跑**。
--   ★★ 它有**三级优先级**（这是整个 DST 动作 UI 的规范）：
--     ① doer:ActionStringOverride(act)      —— 执行者最高优先
--     ② action.stroverridefn(act)            —— 动作原型完全覆盖
--     ③ GetActionString(action.id, strfn(act)) —— 默认串 + 修饰词
--   ★★★ 第③级的两个参数是本文件与 actions.lua 的接缝：
--     · action.id     ← actions.lua:748 赋的值（字符串）
--     · strfn(act)    ← actions.lua 里定义的「修饰词」函数
--     ★ stringutil.lua:331 GetActionString 负责拼接。
--   ★★ 绝���顺序即优先级：**先问执行者，再问动作，最后用默认**。
--     ★ 为什么执行者优先？
--       因为「我在这个语境下要换个说法」是最具体的需求
--       （如吃撑了时把「吃」改成「太饱了」）。
--   ★★ 全部在客户端可用：replica 组件 + 标签都是客户端可读的。
function BufferedAction:GetActionString()
--★ `local str, overriden = nil, nil` —— 两个返回值都要初始化。
--   ★★ overriden 的含义：「我已经完全接管了这个字符串」。
--     ★★★ 传上去之后，调用方（如 locomotor 的调试输出、
--       mapscreen.lua:1417 的 HUD 提示）会知道「不要拼目标名」。
--     ★ 这就是 actions.lua:1574 那条注释说的：
--       「返回同样的字符串，但因为它被覆盖了，
--         它不会显示目标：例如不会显示『Tell Story Portable Campfire』。」
--     ★★ `overriden` 的拼写（应为 overridden）是一个笔误，
--       但因为是局部变量名，不影响任何外部行为。
    local str, overriden = nil, nil
--★★ 54-56 行：执行者覆盖（第一优先级）。
--   ★★ 条件检查的是 `doer.ActionStringOverride ~= nil`（实例字段），
--     不是方法存在性 —— 写法略绕但正确。
--   ★★★ 这个钩子的存在意味着：**角色可以自定义所有动作的文案**。
--     ★ 例如韦伯在挖坟时显示特殊的话。
	if self.doer ~= nil and self.doer.ActionStringOverride ~= nil then
		 str, overriden = self.doer:ActionStringOverride(self)
	end
--★★ 57-58 行：执行者给了字符串就直接返回（连 overridden 也不设）。
--   ★★ 注意 `return str, overriden` —— overriden 是 nil（54 行未赋值）。
--     ★★ 语义：「我给了词，但我没说我接管了整个串」
--       ⇒ 调用方仍会拼接目标名。
--     ★ 与 62 行的 `return str, true` 形成对比。
--   ★★★ **这个细节是整个 UI 体系的关键**：
--     · overriden = nil  → 「这是修饰词，请拼上目标名」
--       例：「Tell Story」+「Portable Campfire」
--     · overriden = true → 「这是完整字符串，别碰」
--       例：TELLSTORY 的 stroverridefn（actions.lua:1576）
--       ★★★ 「修饰 vs 完整」的区分只由第二个返回值表达。
    if str ~= nil then
        return str, overriden
--★★ 59-64 行：动作原型的完全覆盖（第二优先级）。
--   ★★ 只有 stroverridefn 存在时才走这条（strfn 不是）。
--     ★★ **strfn 与 stroverridefn 的根本区别在此确立**：
--       · strfn          → 返回「修饰词」，会与基础串拼接
--       · stroverridefn  → 返回「完整串」，override 标记为 true
--   ★★ 60 行返回单值，所以 62 行硬编码 `return str, true`。
--     ★ 作者用显式的 true 而非透传 overriden，说明这是「必然覆盖」。
    elseif self.action.stroverridefn ~= nil then
        str = self.action.stroverridefn(self)
        if str ~= nil then
            return str, true
        end
    end
--★★★ 65 行 —— 本文件与 actions.lua 交界的那一行。
--   `GetActionString(self.action.id,
--     self.action.strfn ~= nil and self.action.strfn(self) or nil)`
--   ★★★ 三个细节：
--     ① self.action.id —— 由 actions.lua:748 在建表时回写。
--        ★★ 若某个模组用 `Action()` 直接构造而忘了设 id，
--          这里会传 nil 给 GetActionString ⇒ 查不到串。
--     ② `strfn ~= nil and strfn(self) or nil` —— 三元惯例。
--        ★★ 注意如果 strfn 返回 **false**（而非 nil），
--          `false or nil` 会得到 nil。
--          ★ 实际上 strfn 都返回 nil 或字符串，所以无碍。
--     ③ strfn 在**客户端**被调用 ⇒ 它只能读 replica 与标签。
--        ★★ 这解释了 actions.lua:1402 行（OCEAN_FISHING_REEL.strfn
--          用 replica 而 fn 用 components）那类「写两遍」的必要性。
--   ★★★ 这行的 `or nil` 是本文件里最容易被误读的一处：
--     「strfn 不存在」与「strfn 返回 nil」在这里被合并了。
--     ★ 这在语义上正确（两者都不加修饰词），但丢失了区分能力。
    return GetActionString(self.action.id, self.action.strfn ~= nil and self.action.strfn(self) or nil)
--★ 66 行 —— GetActionString 结束。
end

--★★ __tostring —— 调试输出（5 行）。
--   ★★ 三段可选后缀：动作串 + 目标 / With Inv + 手持物 / Recipe + 配方。
--   ★★★ 「调试信息按重要性分层」的范例：
--     核心（做什么）→ 次要（对什么）→ 附加（拿什么）。
--   ★★ 用 `..` 串接并在每段前判空，避免出现「nil」字样。
--   ★★ 这行在调试器、print、DBString 里都会出现 ——
--     排查「玩家说他按了但没反应」时，这是第一手信息。
function BufferedAction:__tostring()
--★ 69 行 —— 与 70/71 行的串接。
--   ★★★ 用 `..` 而非 string.format：调试路径不需要格式化性能。
    return (self:GetActionString().." "..tostring(self.target))
        ..(self.invobject ~= nil and (" With Inv: "..tostring(self.invobject)) or "")
        ..(self.recipe ~= nil and (" Recipe: "..self.recipe) or "")
end

--★★ AddFailAction —— 登记失败回调（3 行）。
--   ★★ 只有两件���：push 到数组。
--     ★ **没有去重**：同一个函数可以被登记多次 ⇒ 会跑多次。
--   ★★ 实际使用者（检索 actions.lua 与 locomotor）：
--     · locomotor.lua 记录「动作开始/结束」以便打断其它系统逻辑
--     · playercontroller 记录 UI 状态
--     · brains/*.lua 记录 AI 行为的状态转移
--   ★★ 注意：**登记了但动作没走到 Fail 就不会执行**（见 23 行早退）。
--     ★ 这是「回调可能永不执行」的常见陷阱 ——
--       若回调持有资源（如打开了 UI），需要小心泄漏。
function BufferedAction:AddFailAction(fn)
    table.insert(self.onfail, fn)
end

--★ AddSuccessAction —— 登记成功回调。与 74 行严格对称。
--   ★★ 11 行初始化为空表，所以 78 行前不需要 nil 检查。
function BufferedAction:AddSuccessAction(fn)
    table.insert(self.onsuccess, fn)
end

--★★【Succeed —— 跑成功回调（7 行）】
--   ★★ 83-85 行用 `pairs` 遍历（不是 ipairs）：
--     ★ 数组用 pairs 遍历略不规范，但顺序不保证 ——
--       对回调而言通常无所谓（它们之间不应有依赖）。
--     ★★ 若两个回调**有先后依赖**，pairs 会导致顺序不确定。
--       ★ 属于「不应依赖但可能依赖」的隐患。
--   ★★ 86-87 行清空**两个**数组：
--     ★★★ 成功时也清空 onfail —— 因为「不可能再失败了」。
--       ★ 防止重复执行。
--     ★ 这是「一次性回调」的实现方式。
--       ★★ 若 Succeed 被调用两次，回调不会跑第二次。
function BufferedAction:Succeed()
    for k, v in pairs(self.onsuccess) do
        v()
--★ 85 行 `v()` —— 无参数调用。
--   ★★ 回调拿不到 act 作为参数 —— 必须自己闭包捕获。
--     ★ 这限制了回调的表达力：
--       `act:AddSuccessAction(function() print(act.invobject) end)`
--       里的 act 是闭包变量，可以访问。
--       ★★★ 这也是为什么 actions.lua 里大量使用局部变量 act。
    end
--★★ 清空回调的两个数组 —— 「一次性」语义。
    self.onsuccess = {}
    self.onfail = {}
end

--★★【GetActionPoint —— 「动作的目标坐标」（4 行）】
--   ★★ 保留的英文注释「returns a Vector3 or nil」——
--     ★★ 注释明确了返回类型，而这正是 actions.lua 里最常被误用的接口。
--   ★★★ 它是 actions.lua 中出现**最频繁**的调用（60+ 次）：
--     `act:GetActionPoint()` 遍布 COOK/PICKUP/TOSS/CAST_NET 等所有
--     「对着一个点做」的动作。
--   ★★ 95 行的 GetDynamicActionPoint 返回 DynamicPosition ——
--     ★★★ 两者区别：
--       · GetActionPoint         → Vector3（世界坐标，会漂）
--       · GetDynamicActionPoint  → DynamicPosition（会跟随平台）
--       ★ 「会漂」对船上的动作是致命的，所以有后者。
--     ★ 但 actions.lua 里 60+ 处用的都是 GetActionPoint，
--       只有 is_relative_to_platform 的动作才真正需要后者。
function BufferedAction:GetActionPoint()
--★ 91 行的保留注释「returns a Vector3 or nil」—— 类型契约。
	-- returns a Vector3 or nil
	return self.pos ~= nil and self.pos:GetPosition() or nil
end

--★ GetDynamicActionPoint —— 直接返回 self.pos（四个字符）。
--   ★★ 与 90 行构成一对：一个转坐标、一个给原对象。
--     ★ 有了它，接收方可以决定要不要用 DynamicPosition 的跟随能力。
function BufferedAction:GetDynamicActionPoint()
	-- returns a DynamicPosition or nil
	return self.pos
end

--★ SetActionPoint —— **修改** pos 的唯一入口。
--   ★★ 它用 `DynamicPosition(pt)` 而不是直接赋值 ——
--     ★ 保证修改后 pos 仍然是 DynamicPosition（9 行的不变量）。
--     ★★★ 封装的价值：调用方不需要知道内部类型。
--   ★★★ 谁会调用它？ locomotor 在 forced 降级时（937 行之后）
--     或 overridedest 生效时可能重新设定目标点。
--     ★ 「动作执行前可以改变它的目标点」—— 这是动态性的体现。
function BufferedAction:SetActionPoint(pt)
	self.pos = DynamicPosition(pt)
--★ 102 行 —— SetActionPoint 结束。
end

--★★【Fail —— 跑失败回调（7 行）】
--   ★★ 与 Succeed（82）**逐行对称**，只有两点不同：
--     ① 遍历的是 self.onfail 而非 onsuccess
--     ② 无返回值（而 Succeed 也没有 —— 两者都没返回）
--   ★★★ 注意本文件**没有任何地方**在 Fail 里推事件或说话。
--     ★ 失败提示完全由 actions.lua 的 `return false, reason` 负责。
--       ★★ 职责划分清晰：本文件管「回调」，actions.lua 管「提示」。
--   ★★ Fail 有三个调用点：
--     · 34 行   Do() 里 fn 失败
--     · locomotor.lua:1079  SetBufferedAction 覆盖旧动作时
--     · entityscript.lua:1563 / 1647 / 1675  实体侧的各种中止
--     ★★ 其中后两者说明：**打断一个动作也走 Fail**。
--       ★ 这就是「打断」在回调层面的体现。
function BufferedAction:Fail()
--★ 105 行 `for k,v in pairs(self.onfail) do` —— 同样用 pairs。
--   ★★ 与 83 行一致的不规范（数组该用 ipairs）。
--     ★ 若回调数组里有洞（不会发生，因为只用 table.insert），无影响。
    for k,v in pairs(self.onfail) do
        v()
    end
--★★ 108-109 行：清空两个数组。
--   ★★★ 「失败时也清空 onsuccess」与 Succeed 的「失败时也清空 onfail」
--     是完全对称的设计。
--   ★★ 效果：**任何一次终结（Succeed 或 Fail）都会让两个数组归零**。
--     ★★★ 这保证了「无论怎样结束，都不会重复执行回调」。
--       ★ 若没有清空，一个「先失败又被重试成功」的场景会双跑。
--   ★★ 到此全文件结束（110 行是 109 行的 end）。
--   ★★ 全文统计：1 个类 + 12 个方法 + 1 个别名 = 约 110 行。
--     ★ 与 actions.lua 的 7092 行形成鲜明对比 ——
--       ★★ 「数据多、行为少」正是动作系统良好分层的标志。
    self.onsuccess = {}
    self.onfail = {}
end
