--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviourtree.lua
-- 模块：决策层 / 行为树运行时（Behaviour Tree Runtime）
-- 职责：定义「行为树」这一整套节点类型与调度协议。承担节点基类
--       BehaviourNode 的生命周期（Visit / SaveStatus / Step / Reset / Stop）、
--       四种状态量（READY/SUCCESS/FAILED/RUNNING）的流转规则、
--       组合节点（Sequence / Selector / Priority / Parallel / Loop / Random）、
--       叶节点（Condition / ConditionWait / MultiCondition / Action / Wait /
--       Latch / Event）、装饰器（Not / FailIfRunning / FailIfSuccess）、
--       三个语法糖构造器（WhileNode / IfNode / IfThenDoWhileNode），
--       以及整棵树的休眠时间推导（GetSleepTime / GetTreeSleepTime）与
--       文本导出（GetTreeString / GetString / DBString）等调试能力。
--       它只回答「此刻该做什么」，不回答「我现在播哪个动画」——
--       后者由 stategraph.lua（表现层状态机）负责。
-- 关键符号：BT, BehaviourNode, DecoratorNode, ConditionNode,
--           MultiConditionNode, ConditionWaitNode, ActionNode, WaitNode,
--           SequenceNode, SelectorNode, NotDecorator,
--           FailIfRunningDecorator, FailIfSuccessDecorator, LoopNode,
--           RandomNode, PriorityNode, ParallelNode, ParallelNodeAny,
--           EventNode, WhileNode, IfNode, IfThenDoWhileNode, LatchNode
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：brain.lua:159 Brain（思考周期与 BT 的对接、ForceUpdate 唤醒）,
--           brain.lua:106 BrainManager:Update（批量驱动 + 休眠调度）,
--           entityscript.lua:1103 SetBrain（树的创建者）,
--           entityscript.lua:1714-1720 Remove（实体销毁时的事件总线清理）,
--           class.lua:83 Class / :15 _is_a（is_a 判定链）,
--           behaviours/（29 个可复用行为片段）,
--           brains/*.lua（各生物的具体树，例如 brains/rabbitbrain.lua:52）,
--           stategraph.lua（表现层，与本文件并存而非从属）
--============================================================
--
--【阅读导航】
--  §零   依赖与四状态常量（1-8）     —— 状态是字符串枚举，且是全局 API
--  §一   BT 外壳（12-47）            —— ★★ 「一次思考 = 三段式事务」
--  §二 ★ BehaviourNode 基类（52-191）—— 生命周期五钩子 + 休眠协议
--  §三   装饰器基类与条件类（195-253）—— 判定 / 等判定 / 两段式判定
--  §四   动作与等待（259-299）        —— ★ WaitNode 的符号笔误
--  §五   Sequence（304-336）          —— 「RUNNING 是唯一记忆」
--  §六   Selector（340-375）          —— 与 Sequence 严格镜像
--  §七   三个装饰器（378-423）        —— Not / FailIfRunning / FailIfSuccess
--  §八   Loop（427-480）/ Random（484-530）—— 循环与随机选址
--  §九 ★★ Priority（533-638）        —— ★★ 决策层的心脏 + ★ H1 缺陷现场
--  §十   Parallel（644-695）          —— ★ 中断的唯一载体
--  §十一 ★★ EventNode（702-765）     —— ★★ 事件驱动 + ★ 第二处破坏性 Reset
--  §十二 语法糖（771-798）            —— While / If / IfThenDoWhile 的语义谱系
--  §十三 LatchNode（801-826）         —— 唯一的限流节点（对照 ConditionWait）
--
--【★★ 全文件最重要的九条】
--  1. 三段式：Visit（决策）→ SaveStatus（快照）→ Step（复位）。三者顺序不可换。
--     理解这一点是读懂全文件的前提。参见 20-24 行。
--  2. ★「RUNNING 是唯一的记忆」。跨思考周期存活的只有 RUNNING 状态，
--     其余状态一律被 Step 复位。于是「优先级」与「粘性」都由它派生。参见 161-169 行。
--  3. ★ 休眠协议：Sleep() 声明 + GetSleepTime() 查询，返回值三态
--     （0 = 马上 / 正数 = 睡多久 / nil = Hibernate，只有事件能唤醒）。参见 37-43 行。
--  4. ★★ PriorityNode 的 lasttime 是节流的唯一旋钮：period 控制频率，
--     lasttime = nil 表示「立即重排」。两个触发源（632 行行为完成、734 行事件）
--     共用这一个信号。参见 582-636 行。
--  5. ★★ 抢占与中断都靠「破坏性 Reset」实现 —— 全文件**不存在** Interrupt /
--     Suspend / Resume / timeout 中的任何一个。
--     ★ 所以「停止」在本框架里等同于「遗忘」，节点不知情、也无法保留进度。
--     ★★ 这是本文件最根本的结构性缺陷。参见 609 行、724 行、767 行三处现场。
--  6. ★★ 【H1 缺陷定位】bug-patterns.md H1 的根因在 609-611 行：
--     抢占时 `self.children[self.idx]:Reset()` 把正在跑的旧赢家直接清空；
--     而 618 行的 `child:Reset()` 又与 603 行自相矛盾（603 刻意排除 RUNNING，
--     618 却不排除），导致「正在正常执行的行为被无端重置」。
--     ★★ 后果：行为树状态与实体状态（locomotor / bufferedaction）分裂，
--       表现为 AI 原地停下、抽搐、打转，或走到一半重新规划。
--     ★★ 第二处现场在 724-726 行：EventNode 事件重复触发时无条件 Reset 自己的
--       子节点，且未把自身 status 归位，与 751 行的 READY 判断产生矛盾。
--     ★★ 核实过的触发前提：同一 PriorityNode 内有多个 EventNode、
--       且旧赢家也是 EventNode。单一 EventNode 的树（如 rabbitbrain）安全。
--  7. ★ priority 是全文件唯一的优先级数字，且只在 600 行生效。
--     ★★ 默认值 0 + 判据用 `<=` ⇒ 同优先级的事件节点互相可抢占，
--       而遍历按位置顺序 ⇒ **靠后的会压制靠前的**（与「位置即优先级」相反）。
--       一旦树里有多个 EventNode，必须显式指定 priority。参见 600/706 行。
--  8. ★ WaitNode:295 的 `Sleep(current_time - self.wake_time)` 符号写反（应为负值变正值），
--     导致所有 WaitNode 的休眠优化完全失效（睡多久都退化成 0）。
--     ★ 功能正确（靠 wake_time 比较），只是节流白做。参见 295 行的完整分析。
--  9. ★ PriorityNode 根的脑**永远不会 Hibernate**：READY 时 GetSleepTime 返回 0，
--     而 Step 每轮把它复位成 READY ⇒ 每帧被调度、靠树内 O(1) 空转节流。
--     参见 541-562 行。这是「Priority 比 Selector 耗 CPU」的根因。
--
--【⚠ 疑似缺陷清单（共 8 处，均只记录不修改）】
--  L1 ★★ behaviourtree.lua:609-611  抢占时破坏性 Reset 旧赢家（H1 根因）
--  L2 ★★ behaviourtree.lua:618       else 分支无条件 Reset，含 RUNNING，与 603 矛盾
--  L3 ★★ behaviourtree.lua:724-726  EventNode 重复触发时 Reset 自己的子节点
--  L4 ★  behaviourtree.lua:295      WaitNode 的 Sleep 传了负数 → 休眠优化失效
--  L5 ※  behaviourtree.lua:428      LoopNode 的 name 误写为 "Sequence"，调试无法区分
--  L6 ※  behaviourtree.lua:59       nextupdatetick 是从未被读取的死字段
--  L7 ※  behaviourtree.lua:586      oldidx 是从未被读取的局部变量（H1 的化石记录）
--  L8 ※  behaviourtree.lua:361/452/497  三处未使用的 local done
--     另有 544/585 行的 `not self.period` 死条件（period 被 535 行兜底为 1）
--
--【★ 事件驱动的完整链路（跨三个文件）】
--  ① 事件源：inst:PushEvent("gohome")  —— entityscript.lua 的事件总线
--  ② 触发：EventNode:OnEvent(721) 被调用
--     · 724-726  若正在 RUNNING 则 Reset 自己的子节点（★ L3 缺陷现场）
--     · 727      triggered = true（★ 只活一帧，741 行清除 —— 存在丢失窗口）
--     · 728      data = 事件负载（全仓库无人读取，是预留扩展点）
--     · 730-732  brain:ForceUpdate() → brain.lua:170-176
--                → BrainManager:Wake(inst) 把实体移回 updaters
--     · 734      DoToParents 清掉所有 PriorityNode 祖先的 lasttime
--                → 下一次 bt:Update 的 585 行 do_eval 必为真 → 全量重排
--  ③ 执行：EventNode:Visit(749) 被遍历到 → 读到 triggered → 转 RUNNING → 跑子节点
--  ★★ 三步缺一不可：只有 triggered 会被休眠挡住；只有 ForceUpdate 会被 period 挡住。
--
--【★ 三种「等待」的语义谱系（选错会造成永久卡树）】
--  ┌────────────────────┬───────────┬──────────┬───────────┬────────────┐
--  │ 节点               │ 容器      │ 等待对象 │ 有终点    │ 期间的表现 │
--  ├────────────────────┼───────────┼──────────┼───────────┼────────────┤
--  │ WaitNode(273)      │ ——       │ 固定时长 │ ✓ 有     │ RUNNING     │
--  │ ConditionWait(242) │ ——       │ 条件成立 │ ✗ 无     │ RUNNING ※   │
--  │ LatchNode(801)     │ ——       │ 冷却结束 │ ✓ 有     │ FAILED ✓    │
--  │ WhileNode(771)     │ Parallel  │ 条件成立 │ ✗ 无     │ 可被中断    │
--  │ IfNode(783)        │ Sequence  │ 判一次   │ ——       │ 不可中断    │
--  │ IfThenDoWhile(792) │ Parallel  │ 一+持续  │ ✗ 无     │ 可被中断    │
--  └────────────────────┴───────────┴──────────┴───────────┴────────────┘
--  ★★ 最危险的是 ConditionWaitNode：条件不成立就永远 RUNNING，整棵树永久停住，
--     且没有任何框架级报错或超时保护。实践中须用外部超时兜底。
--
--【★ behaviours/ 目录（29 个行为片段）—— 本框架的复用机制】
--  behaviours/ 下的每个文件都是 BehaviourNode 的子类或组合，
--  由具体 brain 组合成树。核实到的代表：
--    · panic.lua          Panic       —— 每 0.25~0.5 秒换一个逃跑方向（Sleep 用法范例）
--    · leash.lua          Leash       —— 回家距离约束（自建 Visit + 多个 DBString）
--    · minperiod.lua      MinPeriod   —— 限流（LatchNode 的行为侧同类）
--    · wander.lua / follow.lua / runaway.lua —— 移动类行为
--    · doaction.lua       DoAction    —— 最核心的执行节点（BufferAction 的封装）
--  ★★ 复用靠「回调 + 闭包」：节点不认识实体类型，只接受函数与参数。
--     这正是 54 行基类设计成「只有 fn/action/event」的回报。
--  ★★ 全文件检索确认：LoopNode / RandomNode / ParallelNodeAny / LatchNode
--     在 behaviours/ 中没有对应片段，但被多个 brain 直接使用
--     （braincommon.lua:141/435、oceanfishbrain.lua:184/210 等）。
--
--【★ 与 stategraph.lua 的分工（表现层 vs 决策层）】
--  · Brain + BehaviourTree（本文件）→ 决定「我要去哪、要不要攻击」
--  · StateGraph                 → 决定「我现在播哪个动画」
--  ★ 两者并存而非从属：brain 做出决策后通过 stategraph:GoToState 切换表现状态，
--    stategraph 执行期间（如走路动画）脑仍在独立运行。
--  ★★ 常见的「AI 卡住」是两层的交接问题：brain 认为做完了 → StopBrain，
--    但 stategraph 的动作 handler 因 condition 为假而返回 nil（见 stategraph.lua:430），
--    locomotor 已经走到位却没人接手 → 怪物站住不动。
--    ★ 这是 bug-patterns.md H1「排查方法（相邻问题）」所说的现象。
--
--【★ 性能速查】
--  · 每帧成本集中在「节流路径」（625-636 行），只 Visit 赢家一个 —— O(1)
--  · period 到期才走全量路径（598 行），频率 = 1/period 每秒
--  · RandomNode 的选址是 O(N) 且会「试探执行」（505 行）—— 不可放在脑根
--  · GetTreeString（79 行）是 O(树大小) 且大量字符串分配 —— 只在调试时用
--  · EventNode 的监听在构造期注册（709 行），Stop 才摘除 —— 长期驻留
--  · ※ 全局 NODE_COUNT（52 行）只增不减，但只是数字，无内存泄漏
--★ 本文件唯一的 require 是 class.lua —— 因为全部节点都是 Class() 产物。
--   这也意味着本文件是 DST 决策层的**最底层**：它不认识实体、不认识组件、
--   不认识状态图，只认识「函数」与「子节点数组」。
--   ★★ 正因如此它才能被 behaviours/ 与 brains/ 任意复用：
--     节点的操作全部是回调（fn / action / event），与具体生物无关。
--   参见 class.lua:83 的 Class()、class.lua:15 的 _is_a。
require("class")


--★★【行为树的四种状态 —— 整个框架只有这四个值】
--   READY    —— 尚未开始，或刚被 Reset 回初始态
--   SUCCESS  —— 本轮达成目标
--   FAILED   —— 本轮明确不做
--   RUNNING  —— 正在做，还没做完
--   ★★ 为什么状态是**字符串**而不是数字枚举？
--     因为调试输出（140 行的 GetString）直接把 status 拼进文本，
--     字符串让 imgui / print 的可读性直接拉满，代价是每帧的字符串比较。
--     在「每个节点每次思考都写两次 status」的模型下（SaveStatus + Step），
--     这点开销可接受 —— 真正的性能瓶颈在节点数量而不在状态比较。
--   ★★ 注意这四个是**全局变量**（没有 local）：
--     所有节点文件（behaviours/*.lua、brains/*.lua）都在用它们，
--     例如 behaviours/panic.lua 里直接写 `if self.status == READY`。
--     模组也依赖这四个名字，是事实上的公共 API。
SUCCESS = "SUCCESS"
FAILED = "FAILED"
--★★ READY 的语义是「干净」，不是「空闲」。
--   每次思考周期结束的 Step 阶段（161 行）会把所有非 RUNNING 节点 Reset 成 READY，
--   所以「READY」等价于「上一轮没在跑，且内部状态已复位」。
--   ★ 这是理解 Reset 语义的关键：Reset 不是「停止」，而是「擦干净准备重来」。
READY = "READY"
--★★ RUNNING 是**唯一会被保留**的状态 —— 它是跨思考周期的记忆。
--   Sequence 的 idx、Priority 的 idx、Event 的 triggered、Wait 的 wake_time，
--   全靠「保持 RUNNING」这一条来跨帧延续。详见 161 行的 Step。
RUNNING = "RUNNING"


---------------------------------------------------------------------------------------

--★★【BT 不是节点，是「一棵树 + 它的主人实体」】
--   它把三件事收在一起：
--     ① root —— 根节点（决策从这里开始）
--     ② inst —— 拥有这棵树的实体（EventNode 要用它注册事件监听）
--     ③ Update/Reset/Stop/GetSleepTime —— 与 brain.lua 对接的四个口子
--   ★ 为什么不让根节点自己兼任这些？因为根节点五花八门
--     （可能是 PriorityNode，也可能是 ParallelNode，甚至可能是自定义的 Panic）。
--     把「驱动协议」抽到 BT 这一层，根节点就可以随便换。
--   ★★ 典型构造见 brains/rabbitbrain.lua:52-67：
--     `local root = PriorityNode({...}, .25)` 然后 `self.bt = BT(self.inst, root)`。
--   ※ 注意 BT **不缓存任何思考状态**，它是无状态的。
--     所有状态都在节点里。这是刻意的：BT 可以随时被销毁重建，
--     不会出现「壳还在但内部状态丢了」的不一致。
BT = Class(function(self, inst, root)
--★ inst 只在 EventNode:709 那一处被用到（注册 ListenForEvent）。
--   其余地方（GetSleepTime 等）都只与树有关。
    self.inst = inst
--★ root 允许是 nil —— 构造期还没建好树时 BT 也存在。
--   但那样一来 Update 会崩（root:Visit），所以实际代码总是先建树再 new BT。
    self.root = root
end)

--★★【ForceUpdate：事件唤醒的闸门】
--   只置一个标志 `self.forceupdate = true`，不直接跑树。
--   ★★ 为什么不在这里直接 Update？两个原因：
--     ① **重入安全**：事件可能在树的 Visit 过程中被 PushEvent 触发。
--        若当场执行 Update，等于在 Visit 中嵌套 Visit，节点状态会被写两次。
--        置标志把「立刻重算」推迟到本轮思考结束之后，由 brain.lua:233 的
--        `self.bt:Update()` 在下一个 BrainManager:Update 周期里兑现。
--     ② **不越过 brain 的休眠调度**：事件的紧急性由 brain.lua:170-176 的
--        `Brain:ForceUpdate()` 负责（那里还会 BrainManager:Wake 唤醒实体），
--        BT 这一层只负责「下一轮不许跳过」。
--   ★ 唯一读取点是 38 行的 GetSleepTime：置了标志就返回 0，
--     0 表示「这一 tick 结束后立刻再来一次」，从而绕开 period 节流。
--   ★★ 全流程（三处协作，缺一不可）：
--     EventNode:731  self.inst.brain:ForceUpdate()
--       → brain.lua:170-176  置 bt.forceupdate + BrainManager:Wake(inst)
--       → brain.lua:141-149  下一周期 OnUpdate → bt:Update() → 标志被清（26 行）
--   ※ 代价：事件到生效之间最多有一帧的延迟。
--     对「被打了要逃」这类反应，最多延迟 1/30 秒，玩家感知不到。
function BT:ForceUpdate()
--★ 注意这里是整体覆盖（true），不是计数。连续两个事件也只算一次。
--   ★ 这是**正确的**：事件的意义是「该重新考虑了」，不是「要考虑两次」。
    self.forceupdate = true
end
--★★【BT:Update —— 整个决策层的一次完整思考，只有这四步】
--     ① root:Visit()      —— 自顶向下重算全树状态（决策发生在这里）
--     ② root:SaveStatus() —— 把本轮 status 抄进 lastresult（为了可观测性）
--     ③ root:Step()       —— 把所有非 RUNNING 节点复位成 READY（收尾）
--     ④ forceupdate = false —— 兑现 ForceUpdate 的承诺
--   ★★ 【为什么是这个顺序？这是本文件最重要的设计决策】
--     Visit 与 Step 被 SaveStatus 隔开，形成一次「快照 → 清理」的两段式：
--       · Visit  阶段：所有节点都可能改状态，且互相可见（同一次调用栈内）
--       · SaveStatus：立刻定格，之后无论怎么改都留有「上一轮的结果」
--       · Step 阶段：统一把跑完的节点擦干净，让下次 Visit 从 READY 起步
--   ★★ 若把 SaveStatus 去掉，lastresult 永远是当前值，调试输出会完全失真；
--     若把 Step 提前，节点在同一次思考里就被擦掉，来不及被父节点读到。
--   ★★ 「一次思考 = 一个事务」的隐喻：Visit 是写，SaveStatus 是提交快照，
--     Step 是垃圾回收。三者不可交换顺序。
--   ※ 但它**不是**真正的事务：Step 阶段的 Reset 是破坏性的，
--     中途抛错会导致树停在半复位状态。行为树节点里应避免 error。
function BT:Update()

--★★ Visit 是**自顶向下**的递归，不是自底向上。
--   父节点决定「要不要问子节点」，子节点只在被问到时才执行。
--   ★ 这与传统顺序遍历型行为树最大的区别就在这里 ——
--     传统 BT 是「从上往下走一遍，RUNNING 就停在那」，
--     本框架每帧都从根重新走一遍，靠 status 记住进度。
--   ★★ 好处：任何时刻从任何节点进入都能得到正确状态（无隐藏游标）。
--     代价：每帧都要重新走「到当前节点」的那段路径，深度越深越贵。
    self.root:Visit()
--★★ SaveStatus 单独成为一步（而不是塞进 Step），
--   是为了让「RUNNING 的节点」也能被快照 —— Step 会跳过它们。
--   见 152 行：lastresult 对全树无条件赋值。
    self.root:SaveStatus()
--★★ Step 是「本轮结束」的信号，也是唯一会向下递归的一步。
--   注意基类 Step（161 行）对非 RUNNING 节点调用的是 Reset 而不是 Step，
--   所以「跑完的子树」走的是 Reset 路径（连带清 children），
--   「还在跑的子树」才继续往下 Step。
--   ★★ 这就是为什么「正在跑的行为」能跨帧存活，而「跑完的行为」立刻被忘记。
    self.root:Step()

--★ 放在最后清标志：保证本次 Update 一定消费掉它。
--   ※ 若在 18-24 之间清，中途被 ForceUpdate 会丢失唤醒请求。
    self.forceupdate = false
end

--★ Reset 透传：给「手动打断整棵树」用（如换形态、切阶段）。
--   典型调用：brains/ 里换阶段时先 `self.bt:Reset()`。
--   ※ 注意 Reset **不会** 清 EventNode 的事件监听（见 744 行），
--     只有 Stop 才会（713 行 OnStop）。这是刻意区分：
--     Reset = 「重新考虑」，Stop = 「拆掉」。
function BT:Reset()
    self.root:Reset()
end

--★★【Stop 与 Reset 的区别 —— 涉及资源回收，是本文件的关键分界】
--   Reset：把状态擦成 READY，**不释放任何外部资源**
--   Stop ：调用每个节点的 OnStop 钩子，**释放外部资源**
--   ★★ 唯一用到 OnStop 的是 EventNode（713 行）：它反注册 inst:ListenForEvent。
--     这意味着：
--       · 树在运行期间，事件监听一直挂着（哪怕节点当前是 READY）
--       · 树被 Stop 后，监听被摘掉；若之后又 Update，EventNode 永远收不到事件
--   ★★ 调用链：brain.lua:253 Brain:_Stop_Internal → self.bt:Stop()
--     ← entityscript.lua:1091 StopBrain / :1108 SetBrain / :1128 _DisableBrain_Internal
--   ※ 陷阱：Stop 之后没有「重新 Listen」的代码路径。
--     所以**同一棵 bt 只能 Stop 一次**；要重启必须重建整棵树
--     （这正是 entityscript.lua:1110 的做法：self.brain = brainfn() 重建）。
function BT:Stop()
    self.root:Stop()
end

--★★【GetSleepTime：行为树与「全局调度器」的唯一接口】
--   这是整个 DST AI 性能体系的关键，理解它就理解了「为什么怪物不费 CPU」。
--   返回值语义（被 brain.lua:143-149 消费）：
--     · 0        —— 下一 tick 立刻再来（不睡）
--     · 正数(秒) —— 睡这么久，期间完全不消耗 CPU
--     · nil      —— **休眠（Hibernate）**，直到有人 Wake
--   ★★ forceupdate 直接短路成 0（38-40 行），这是事件响应的保证。
--   ★★ 委托给 GetTreeSleepTime（42 行）而不是自己算，
--     因为「睡多久」取决于**整棵树里最急着醒的那个节点**，
--     而树根自己通常没有时间概念（见 101 行的排除条件）。
--   ★★ 消费方 brain.lua:140-149 的三分支：
--       if sleep_amount then          -- 非 nil
--           if > GetTickTime() then Sleep(k, sleep_amount)  -- 排队等醒
--           else 什么都不做             -- 下一 tick 自然再跑
--       else Hibernate(k)            -- 移出 updaters，零开销
--       end
--   ★★ Hibernate 的唤醒只有两条路：
--       ① BrainManager:Wake —— 由 Brain:ForceUpdate 触发（brain.lua:175）
--          也就是「事件」这条路。
--       ② BrainManager:Sleep 到期 —— 但 Hibernate 状态下不会排 Sleep。
--     ★★ 所以结论很硬：**一个正在 Hibernate 的脑，只有事件能唤醒它**。
--       这就是「事件驱动」四个字的确切含义，也是本文件与
--       「每帧轮询型」AI 在性能上的天壤之别。
function BT:GetSleepTime()
--★ 三元写法 `if ... then return 0 end` 而不是 `return 0 or ...`，
--   意图是让「强制更新」的优先级高于一切时间计算。
    if self.forceupdate then
        return 0
    end

--★ 注意可能返回 nil —— 那不是 bug，是「休眠」的信号（见上方 37 行详解）。
--   ★★ nil 与 0 的区别是本文件最容易误读的地方：
--     0 = 「马上」（还在 updaters 里，下 tick 继续）
--     nil = 「别叫我了」（已移出 updaters，只有事件能叫醒）
    return self.root:GetTreeSleepTime()
end

--★★ __tostring 让 `print(brain)` / 调试面板直接吐出整棵树的快照。
--   brain.lua:178-184 的 Brain:__tostring 会把它包在 "--brain--" 头里，
--   并附上 GetSleepTime —— 这就是玩家在控制台敲 brain 命令看到的东西。
--   ★ 这是本文件唯一的「可视化」手段，也是排查「AI 卡住」的第一入口。
function BT:__tostring()
    return self.root:GetTreeString()
end


---------------------------------------------------------------------------------------

--★★【NODE_COUNT：全局自增节点计数器】
--   ★★ 它的**唯一用途**是给 imgui 调试面板一个稳定可点的 id（见 61-63 行原注释）。
--   为什么需要 id？因为行为树是**递归结构**，同一个 Panic 节点在树的
--   不同深度会出现多次，光靠 name 无法区分是哪一份。
--   ★ 全局自增保证了「跨树唯一」：调试面板可以放心把 id 当主键。
--   ※ 代价与事实：
--     ① 它**永不重置**。长期运行的游戏里会一直涨到几百万级。
--        Lua number 是 double，精度上限约 9e15，现实里不会溢出。
--     ② 它是**全局变量**（没有 local），且 mod 也可能干扰。
--     ③ 节点对象被 GC 后 id 不会被回收 —— 但 id 只是数字，无内存泄漏。
--   ★ 结论：这是「为可观测性付费」的典型取舍，可接受。
local NODE_COUNT = 0

--★★【BehaviourNode：全文件的心脏 —— 所有节点类型的共同基类】
--   它承载三件事，任何节点都免费继承：
--     ① 七个基础字段（54-63）：身份与状态
--     ② 六个生命周期钩子的**默认实现**（97-191）
--     ③ 父子双向链接的建立（65-69）
--   ★★ 最重要的认知：**子类只需覆写 Visit()**，其余五个钩子都有合理默认。
--     这就是「模板方法模式」在 Lua 里的极简版本 —— 没有抽象基类语法，
--     靠「基类给了默认实现」达到同样效果。
--   ★★ 参见 class.lua:95-99：子类构造时会 `for i,v in pairs(base) do c[i] = v end`
--     浅拷贝基类的所有方法，所以基类新增方法时子类自动获得。
--     ★ 但注意这也是「猴补陷阱」的来源：给基类打补丁会**立即影响所有节点**。
BehaviourNode = Class(function (self, name, children)
--★ name 是调试与错误定位的唯一线索，务必写清楚。
--   ★★ 它在 145 行的 GetString 里被拼进输出，形如：
--     `Event(gohome) - RUNNING <SUCCESS> (idx=2)`
--   ※ 实践中大量节点的 name 是硬编码英文（如 428 行 LoopNode 的 name 就写成了
--     "Sequence"，见该行的 ※ 标注），所以调试输出并不总是准确。
    self.name = name or ""
--★★ children 是**数组**（用 ipairs 遍历），不是字典。
--   ★ 这一点很重要：节点的孩子**有顺序**，顺序即优先级。
--     Sequence / Selector / Priority / Random 全部依赖这个顺序语义。
--   ※ 但 Reset/SaveStatus（155 行）用的是 pairs —— 行为等价（数组的 pairs 仍按序），
--     属于风格不统一而非缺陷。
--   ★ nil 表示「叶节点」。101 行的 GetSleepTime 靠它区分叶/非叶。
    self.children = children
--★ status 是「当前思考周期的实时状态」，本周期内会被反复改写。
    self.status = READY
--★★【lastresult —— 为了可观测性而存在的字段】
--   它是 status 的**上一周期快照**，由 SaveStatus（152 行）在 Visit 之后立刻定格。
--   ★★ 为什么要留历史？因为 status 在 Step 阶段会被 Reset 成 READY，
--     如果只有 status，调试输出会永远显示 READY，看不出「刚才成功过」。
--   ★★ 它的直接消费者只有 145 行的 GetString（输出成 <lastresult>）。
--     ★ 也就是说：lastresult **纯粹给人看**，没有任何逻辑读它。
--     这是本文件「调试优先」设计哲学的一处明证。
    self.lastresult = READY
--⚠【疑似缺陷】`self.nextupdatetick = 0` —— 一个**从未被读取的字段**。
--   ★★ 全仓库检索（grep nextupdatetick）只命中这一处。
--     真正被用的是 98 行的 `self.nextupdatetime`（注意少了 tick 的 t）。
--   推理依据：
--     · 97-99 行的 Sleep() 只写 nextupdatetime；
--     · 104 行读的是 self.nextupdatetime；
--     · 没有任何代码写或读 nextupdatetick。
--   推测成因：早期版本曾用「tick 数」做休眠计算（nextupdatetick），
--     后来改为「GetTime() 秒数」（nextupdatetime）但忘了删旧字段。
--   ★ 影响：无功能危害（Lua 允许未使用字段），但它是「代码考古」的线索 ——
--     也提醒我们：**不要给行为树节点加没人读的字段**，它们会永远留在内存里。
    self.nextupdatetick = 0

--★ 原注释（保留）：`--jcheng: this is for imgui to have an id to use`
--   翻译：「jcheng：这是给 imgui 用的，好让它有个 id」。
--   ★★ 这行原注释本身就说明了作者的态度：**框架的核心是给调试器用的**。
--     一个纯逻辑框架主动给每个节点分配稳定 id，是很强的可观测性承诺。
    --jcheng: this is for imgui to have an id to use
--★ id 在构造时分配，此后**永不改变**，与节点在树中的位置无关。
--   ★★ 因此调试面板可以用 id 做「上次的同一个节点」的高亮，
--     即使这轮思考里它换了父节点也一样能对上。
    self.id = NODE_COUNT
    NODE_COUNT = NODE_COUNT + 1

--★★【父子链接：只向上设 parent，不向下设 children 的反向引用】
--   ★ 这个单向链接是本文件里一条**最重要的隐藏契约**：
--     · 构造期：父节点给每个孩子设 parent（这里）
--     · 运行期：只有 EventNode:734 的 DoToParents 会用到它（向上走）
--   ★★ 为什么不需要反向引用？因为所有向下遍历都是「self.children」，
--     树结构本身已经完备；parent 只服务于「我要通知我的祖先」这一个需求。
--   ※ 陷阱：68 行 `k.parent = self` 是在**基类构造**里做的，
--     所以任何节点只要把 children 交给 BehaviourNode._ctor 就自动有 parent。
--     但如果子类构造器**忘了**传 children（如 203 行的 ConditionNode），
--     这个节点就永远是叶子，无法被 DoToParents 之外的方式遍历到。
    if children then
        for i,k in pairs(children) do
            k.parent = self
        end
    end
end)

--★★【DoToParents：向上广播 —— 本文件唯一的「向祖先发通知」机制】
--   递归向上执行 fn，每个祖先一次。
--   ★★ 唯一使用者是 EventNode:734：
--     事件触发时沿 parent 链把所有 PriorityNode 的 lasttime 清成 nil，
--     从而**强制它们的 period 节流失效**，下一帧必须重新评估整棵树。
--   ★★ 为什么这个机制是必需的？
--     PriorityNode 的设计是「每 period 秒才重新挑一次赢家」（585 行的 do_eval）。
--     没有 DoToParents，一个刚触发的事件最多要等 period 秒才被看见。
--     rabbitbrain.lua:65 用的 period 是 0.25 秒 —— 尚可接受；
--     但 abigailbrain.lua:250 那类 period 较大的树就会明显迟钝。
--     ★ 所以「事件 = 立刻重排优先级」这条保证，是靠这七行实现的。
--   ※ 它**只通知 PriorityNode**。如果事件的宿主在 Sequence/Parallel 之下，
--     而 Sequence 外面没有 PriorityNode，那这次唤醒就丢了。
--     实践中所有脑的根都是 PriorityNode，所以没暴露出来；
--     但自定义树时这是个真实的坑。
--   ※ 递归无深度上限：树有多深就递归多深。正常树深度 < 10，无性能问题。
function BehaviourNode:DoToParents(fn)
--★ nil 守卫：根节点没有 parent，递归到此为止。
    if self.parent then
        fn(self.parent)
--★ 注意 `return self.parent:DoToParents(fn)` —— 返回值被丢弃。
--   DoToParents 没有有意义的返回值，调用方也不需要（EventNode 传的是副作用函数）。
        return self.parent:DoToParents(fn)
    end
end

--★★【GetTreeString：排查「AI 卡住」的第一工具】
--   递归吐出整棵树的文本快照，每行形如：
--     <缩进>NAME>STATUS>剩余秒数 (DBString 补充信息)
--   ★★ 这是本文件唯一的调试可视化出口（无 imgui 也能用），
--     接上 45-47 行的 BT:__tostring 与 brain.lua:181 的包装，
--     就是玩家在控制台看到的 brain 输出。
--   ★★ 排查「AI 莫名其妙停下」的读法：
--     先看根节点 status —— 是 RUNNING 还是 SUCCESS/FAILED；
--       · 若是 FAILED，说明所有分支都不成立，条件函数写错了
--       · 若是 RUNNING，看它卡在哪个子节点上，DBString 通常会给出具体数字
--     再看 RUNNING 节点后面的 (DBString) —— 如 `execute 3, eval in 0.18`
--   ※ 代价：整棵树字符串拼接是 O(节点数)，每次调用都分配大量字符串。
--     ★ 所以只在调试/按需时调用，绝不放进每帧路径。
function BehaviourNode:GetTreeString(indent)
    indent = indent or ""
--★★ `self:GetTreeSleepTime() or 0` —— nil 兜底成 0。
--   含义：「这一小片子树现在没有在等时间的事」。
--   ★ 格式 `%2.2f` 保留两位小数，肉眼足以判断「还剩 0.01 秒」还是「还剩 3 秒」。
    local str = string.format("%s%s>%2.2f\n", indent, self:GetString(), self:GetTreeSleepTime() or 0)
    if self.children then
--★ 用 ipairs 遍历 —— 顺序即优先级（见 56 行）。
        for k, v in ipairs(self.children) do
--★ 原注释（保留）：
--   `// uncomment this to see only the "active" part of the tree. handy for pigbrain.`
--   翻译：「取消注释这行就只看树的『活动』部分，对猪很有用。」
--   ★★ 这是开发者留下的一条**调试配方**，价值很高：
--     整棵树可能有几十个节点，但同一时刻只有极少数是 RUNNING/SUCCESS 的。
--     打开这个开关后输出会短到能一屏看完，直接锁定卡住的分支。
--   ※ 它引用的 85-87 行是配套的 if/then/end 三行 —— 必须**成组**取消注释。
--     只取消其中一行会造成 Lua 语法错误（if 有 then 却没有 end）。
--   ★ 「pigbrain」之所以好用，是因为 pigelitebrain.lua:251 那类树特别大。
            -- uncomment this to see only the "active" part of the tree. handy for pigbrain.
--※【被注释掉的「只看活动节点」过滤器】三个条件：
--     v.status == RUNNING          —— 本轮正在跑
--     v.status == SUCCESS          —— 本轮刚成功（尚未被 Step 复位）
--     v.lastresult == RUNNING      —— 上一轮在跑（跨 RUNNING→RUNNING 的续跑）
--     v.lastresult == SUCCESS      —— 上一轮成功
--   ★★ 注意后两个条件用的是 **lastresult**：
--     在 GetTreeString 被调用的时刻，Step 已经跑过了，
--     刚成功的节点 status 已被 Reset 成 READY ——
--     只有 lastresult 还留着 SUCCESS 的痕迹。
--     这正是 lastresult 字段存在的第二个理由。
--   ★ 输出会变短但**不再有缩进上下文**（被跳过的层级直接消失），
--     所以只能看「哪些在跑」，看不出「挂在谁下面」。二者互补。
            --if v.status == RUNNING or v.status == SUCCESS or v.lastresult == RUNNING or v.lastresult == SUCCESS then
                str = str .. v:GetTreeString(indent .. "   >")
            --end
        end
    end
    return str
end

--★★ DBString 是「节点自述」的钩子，默认返回空串。
--   ★ 全文只有三处实现（309/434/567 行 + behaviours/minperiod.lua:22），
--     都是「打印一个能定位问题的数字」：
--       · SequenceNode/LoopNode  → 当前走到第几个孩子（tostring(idx)）
--       · PriorityNode            → "execute N, eval in X"（在执行谁、何时重排）
--       · WaitNode                → 剩余秒数
--       · MinPeriod               → 还要等多久
--   ★★ 注意 142 行的调用条件：`if self.status == RUNNING` ——
--     **只有 RUNNING 的节点才输出 DBString**。
--     这是刻意的降噪：没在跑的节点没什么可说。
function BehaviourNode:DBString()
--★ 空串是安全的默认值：string.format 里的 %s 会得到空文本，不会有 nil。
    return ""
end

--★★【Sleep / nextupdatetime：节点级的「我要睡 N 秒」声明】
--   ★★ 与 BT:GetSleepTime 的关系：
--     Sleep()      —— 声明「我还要 t 秒」（由具体节点在 Visit 里调用）
--     GetSleepTime —— 提问「还要多久」（由调度器调用）
--   ★ 写成对而非写成一个字段，是为了让「无等待」可以用 nil 表达。
--   ※ 关键约定：**Sleep 只能被 RUNNING 中的自己调用**，
--     否则 nextupdatetime 会在节点已经结束时被写进去，残留成脏时间。
--     实际代码都遵守了（见 behaviours/panic.lua:16 在 RUNNING 分支里调）。
--   ※ Sleep 传入负数是合法的（会写出过去的时间），
--     但 106-108 行会把负数钳成 0，等价于「不睡」。
--     ★ 这条容错救了 295 行 WaitNode 的一个笔误（见该行的 ※）。
function BehaviourNode:Sleep(t)
--★ 用 GetTime()（秒，浮点）而非 GetTick()（帧数整数）。
--   ★ 理由：period / latchduration 等配置项都以秒为单位书写，
--     用秒统一后，配置里写 0.25 就是 0.25 秒，不需要任何换算。
    self.nextupdatetime = GetTime() + t
end

--★★【GetSleepTime（基类）：本方法是对称设计的关键半边】
--   与 97 行的 Sleep 配对，构成「声明—查询」协议。基类的四个返回分支：
--     · 满足 RUNNING && 无孩子 && 不是 Condition → 返回剩余时间（可能 0）
--     · 否则 → 返回 nil（=「我不决定睡多久」）
--   ★★ 【条件一】为什么要求 `not self.children`？
--     组合节点的睡眠时间由**孩子**决定（见 117 行 GetTreeSleepTime 的递归），
--     组合节点自己不该再报一个时间，否则会与孩子的取最小值逻辑打架。
--   ★★ 【条件二】为什么排除 ConditionNode？
--     条件是「瞬时判定」，每帧都必须重新算（WhileNode 的语义，见 771 行）。
--     若条件能决定睡眠时间，「持续为真就持续睡觉」会直接破坏 While 语义。
--     ★★ 严格说 ConditionNode 永远不会是 RUNNING（207-213 行只产出 SUCCESS/FAILED），
--       所以这个 is_a 检查实际是**冗余的防御**。写它是为了表达意图。
--   ※ 条件三隐含的问题：`self.nextupdatetime` 从未初始化（默认 nil），
--     所以「RUNNING 但没调过 Sleep 的叶节点」走 111 行返回 0，
--     意思是「每帧都要重新问我」—— 这对 ActionNode 这类瞬时动作是对的，
--     但对**卡住的动作**也是 0，会导致 CPU 空转（详见 p1 中 ActionNode 的说明）。
function BehaviourNode:GetSleepTime()

--★★ 这一行浓缩了三层判断：RUNNING && 无孩子 && 不是条件。
--   ★ 读法：只有「正在执行的、自己是叶子的、不是纯判定」的节点才管休眠。
--   ※ ConditionNode 在本文件 202 行才定义，此处引用的是**运行时**的全局变量。
--     因为方法体在调用时才求值，所以不存在「定义顺序」问题 ——
--     但这意味着本文件存在**前向引用**，阅读时要留意。
    if self.status == RUNNING and not self.children and not self:is_a(ConditionNode) then
--★ `if self.nextupdatetime then` —— 没调过 Sleep 的 RUNNING 节点落到 111 行。
        if self.nextupdatetime then
--★ `self.nextupdatetime - GetTime()` 就是「还差多少秒」。
--   ★★ 可以为负（Sleep 之后又过了更久），所以下一步必须钳位。
            local time_to = self.nextupdatetime - GetTime()
--★★ 负数钳成 0 —— 「已经超期了，那就现在立刻跑」。
--   ★ 这条容错让 295 行的 `Sleep(current_time - self.wake_time)`（一个负数）
--     退化成「每帧都醒」，行为仍然正确，只是丢了优化。见 295 行的 ※。
            if time_to < 0 then
                time_to = 0
            end
            return time_to
        end
--★ 没调过 Sleep 的 RUNNING 叶节点 → 0 → 「下一 tick 继续」。
--   ★★ 这是**保守且正确**的默认值：不确定要睡多久，那就别睡。
--     性能靠「主动声明 Sleep」来赚，而不是靠默认休眠。
        return 0
    end

--★ nil 是「我不表态」，由 GetTreeSleepTime 去问孩子（123 行）。
    return nil
end

--★★【GetTreeSleepTime：向上汇报「这棵子树最早要醒的时刻」】
--   算法只有两步：
--     ① 遍历 RUNNING 的孩子，取它们的最早醒时刻（取最小值）
--     ② 和自己 GetSleepTime() 的结果再取最小
--   ★★ 为什么取**最小**而不是最大？
--     因为语义是「最急的那个什么时候醒」：
--       · 有个 WaitNode 还有 0.2 秒到期 → 整棵树最多只能睡 0.2 秒
--       · 哪怕另一个孩子还想睡 5 秒，也必须为这 0.2 秒醒一次
--     ★★ 反过来（取最大）会让快到期的行为被饿死 ——
--       这正是「等待中的 WaitNode 永远等不到时间到」这类经典 bug 的来源。
--   ★★ 全树无 RUNNING 节点时返回 nil（sleeptime 从未被赋值）
--     → 一路传到 BT:GetSleepTime → brain.lua:148 Hibernate。
--     ★★ 所以「树里没在跑任何东西」= 「大脑休眠」。
--       这是整个 AI 系统「空闲零开销」的实现方式。
function BehaviourNode:GetTreeSleepTime()

    local sleeptime = nil
--★ nil 守卫：叶节点没有 children。
    if self.children then
        for k,v in ipairs(self.children) do
--★★ 只看 RUNNING 的孩子 —— 已完成的（SUCCESS/FAILED）不占睡眠预算。
--   ★ 理由：完成的节点马上会被 Step 复位成 READY，不值得为它定闹钟。
            if v.status == RUNNING then
                local t = v:GetTreeSleepTime()
--★★ `if t and (not sleeptime or sleeptime > t)` —— 三重守卫：
--     · t 非 nil（孩子不表态就跳过）
--     · 还没收集到任何时间（第一次）
--     · 当前记录的时间比这个孩子晚（取更早的）
--   ★★ 用 `sleeptime > t` 而不是 `t < sleeptime` 是等价的，
--     写法上后者更易读；此处保持原样不改。
                if t and (not sleeptime or sleeptime > t) then
                    sleeptime = t
                end
            end
        end
    end

    local my_t = self:GetSleepTime()

--★ 同样的取最小逻辑，把自己也纳入竞争。
--   ※ 注意若自己是 RUNNING 且无孩子的叶节点，这里可能返回 0，
--     于是 124 行收集到的孩子时间会被 0 覆盖 —— 语义正确（「我马上要醒」），
--     但会让整棵树每帧都醒。
    if my_t and (not sleeptime or sleeptime > my_t) then
        sleeptime = my_t
    end

--★ 返回 nil 表示「这一片没有在等的东西」→ 逐层上抛 → Hibernate。
    return sleeptime
end

--★★【GetString：单节点的文本自述，GetTreeString 的零件】
--   输出格式：`NAME - STATUS <LASTRESULT> (DBString)`
--   ★★ 三个信息位的分工：
--     NAME        —— 我是谁（构造时给的）
--     STATUS      —— 我现在怎么样（本轮实时）
--     LASTRESULT  —— 我上一轮怎么样（快照，见 58 行）
--     (DBString)  —— 我在等什么 / 我在做第几步（仅 RUNNING 时）
--   ★ 二者对照着看是排障的关键：
--     `Event(gohome) - READY <RUNNING>` 表示「上一轮还在跑，这轮已复位」；
--     `Priority - RUNNING <FAILED> (execute 3, eval in 0.18)` 表示正在跑第 3 个分支。
function BehaviourNode:GetString()
    local str = ""
--★★ 只有 RUNNING 才问 DBString —— 没在跑的节点没什么可补充。
--   ★ 这也让 DBString 的实现者可以放心写「访问正在倒计时的字段」，
--     因为那些字段只在 RUNNING 时才保证有效（见 WaitNode:279 的 wake_time）。
    if self.status == RUNNING then
        str = self:DBString()
    end
--★★ `self.status or "UNKNOWN"` / `self.lastresult or "?"` 的 nil 兜底。
--   ★ 理论上 57-58 行已初始化，不会是 nil；这里是纯防御。
--   ★★ 格式串里 status 被放在「-」后面而不是括号内，
--     与 name 同列对齐，便于人眼纵向扫读整棵树的状态列。
    return string.format([[%s - %s <%s> (%s)]], self.name, self.status or "UNKNOWN", self.lastresult or "?", str)
end

--★★【BehaviourNode:Visit 的默认实现：直接 FAILED】
--   ★★ 这是整个框架一个**非常重要的默认值**：
--     「没有 Visit 覆写的节点 = 永远失败」。
--   ★★ 为什么这样设计？
--     ① **安全默认**：忘记实现 Visit 的节点不会误触发行为，只是永不选中。
--        反过来（默认 SUCCESS）会让所有半成品节点疯狂触发动作。
--     ② **叶节点就是靠它当条件用**：自定义条件节点可以只写一个返回函数的节点，
--        什么都不做 —— 默认 FAILED 已经是正确答案的一半。
--     ③ **组合节点的兜底**：Sequence/Selector 遍历到某个空节点时立刻短路，
--        不会让整棵子树卡在 RUNNING。
--   ★ 与 149 行的区别：基类 Visit 把 status 打成 FAILED，
--     而 EventNode/ParallelNode 等子类覆写后不调用基类 Visit ——
--     所以「不调用 super」是本文件的常态写法。
function BehaviourNode:Visit()
--★ 唯一一行就是 FAILED。参见上方设计理由。
    self.status = FAILED
end

--★★【SaveStatus：把「本轮结果」定格成「上一轮结果」】
--   ★★ 这是 BT:Update 三段式的第二段（见 23 行），也是理解 lastresult 的关键。
--   ★★ 【为什么必须独立成一步，而不是在 Visit 末尾顺手做？】
--     因为 Visit 是自顶向下递归的：父节点在自己确定 status 之后才 return，
--     此时孩子可能刚被访问过。如果在每个节点 Visit 开头/末尾各抄一次，
--     同一节点在一轮里会被抄多次（一次被父访问、一次被自己 SaveStatus）。
--     ★ 独立成一步保证「一轮 = 一次快照」，语义干净无歧义。
--   ★★ 用 pairs 而非 ipairs：children 是数组，行为等价（见 56 行的 ※）。
--   ★ 无条件递归（不看 status）：连 SUCCESS/FAILED 的节点也快照，
--     因为调试时要能看到「它刚才成功过」。
function BehaviourNode:SaveStatus()
--★ 这一行是 lastresult 唯一的写入点。
--   ※ 推论：**任何直接改 self.status 的代码都不会更新 lastresult**，
--     只有下一次 SaveStatus 才会。所以调试输出里 lastresult 天然滞后一轮。
    self.lastresult = self.status
    if self.children then
        for k,v in pairs(self.children) do
            v:SaveStatus()
        end
    end
end

--★★【BehaviourNode:Step：思考周期的「垃圾回收」阶段 —— 三段式的第三段】
--   逻辑只有两条岔路，但它是全框架「状态得以跨帧延续」的核心：
--     ① 自己不是 RUNNING → 调 Reset()（连带把整棵子树擦成 READY）
--     ② 自己 RUNNING 且有孩子 → 递归 Step 孩子（把跑完的深层节点擦掉）
--   ★★ 【为什么非 RUNNING 就整个 Reset，而不是只把自己擦掉？】
--     因为「不是 RUNNING」意味着「这事已经做完了」。做完就该彻底忘掉：
--       · Sequence 的 idx 要回 1（否则下次从老位置继续，做过的事重做）
--       · WaitNode 的 wake_time 要作废（否则下次一进去就 SUCCESS）
--       · Priority 的状态要清（否则见 603 行的 Reset 判断）
--     ★★ 换句话说：**RUNNING 是唯一的记忆，其余状态一律归零**。
--       这是本框架「无隐藏游标」设计的直接体现 ——
--       每次思考都从干净状态出发，只靠 RUNNING 保留进度。
--   ★★ 为什么 RUNNING 的要递归下去？因为 RUNNING 子树里可能已有孩子完成了，
--     它们需要被清理，而自己不能被清（那会丢掉进度）。
--   ※ 「Reset 整个子树」是级联的：一次 Step 会把整条不再运行的路径擦到底。
--     这也意味着 Reset 的代价与子树大小成正比 —— 宽而浅的树 Reset 快，
--     深而窄的树 Reset 慢。
function BehaviourNode:Step()
--★★ 判据只有 status 是否为 RUNNING，其余一概 Reset。
--   ★ 注意没有区分 SUCCESS 与 FAILED —— 对框架而言两者等价：「做完了」。
--   ★★ 组合节点（Sequence/Selector）通常在上层就把子节点的 RUNNING 透传上来，
--     所以到 Step 时组合节点自己也是 RUNNING，走 elseif 分支继续往下。
    if self.status ~= RUNNING then
        self:Reset()
--★★ 用 ipairs：顺序遍历对 Step 无影响，但与其他遍历保持一致。
    elseif self.children then
        for k, v in ipairs(self.children) do
            v:Step()
        end
    end
end

--★★【Reset：把节点连同子树擦回 READY】
--   ★★ 【最精妙的一处优化：if self.status ~= READY 守卫】
--   已经是 READY 的节点**整个 Reset 都不会执行**——既不改自己，也不碰孩子。
--   ★★ 为什么这个守卫是必须的？性能。
--     Step 阶段（161 行）会对每个非 RUNNING 节点调 Reset，
--     而一棵 Priority 树在「没找到任何赢家」时会 FAILED，
--     此时所有孩子都要被 Reset。没有守卫的话，
--     一个 READY 的孩子会让它的整棵子树被反复递归重置 ——
--     最坏情况是 O(树大小 × 树深度)。
--   ★★ 守卫把「重复 Reset」变成 O(1)：第一次把状态改成 READY，
--     后续所有祖先的递归 Reset 都在这一行被短路掉。
--     ★★ 这是典型的**幂等 + 提前退出**优化，是本文件最值得学的一处写法。
--   ※ 副作用（也是风险）：如果某个子类在 Visit 里改了 status 却没走基类构造，
--     或者在 Reset 之外维护了额外状态（见 LatchNode 的 lastlatchtime、
--     WaitNode 的 wake_time），**这些状态不会被 Reset 清除**。
--     ★ 这正是 809-827 行 LatchNode 刻意不覆写 Reset 的原因：
--       它的冷却时间必须跨 Reset 存活，否则冷却会失效。
--   ★★ 对比：SequenceNode:314 与 PriorityNode:577 都**覆写了** Reset，
--     因为它们有额外的 idx 状态必须归零。这是正确的差异化。
function BehaviourNode:Reset()
--★★ 整个文件最重要的一行守卫。性能与幂等性全靠它。
--   ★ 推论：Reset **不是** 「清空所有字段」，只是「状态归位 + 级联」。
--     自定义节点若有不变量状态，必须自己覆写 Reset。
    if self.status ~= READY then
        self.status = READY
        if self.children then
--★ 用 ipairs 遍历 children 做级联 Reset。
--   ★ 命名 child（其余地方叫 v）—— 无语义差别，纯风格。
            for idx, child in ipairs(self.children) do
                child:Reset()
            end
        end
    end
end

--★★【Stop：与 Reset 的本质区别 —— 前者释放资源，后者只改状态】
--   ① 先调自己的 OnStop 钩子（若存在）
--   ② 再无条件递归所有孩子（注意：这里是 ipairs 全量，不是按 status 筛）
--   ★★ 与 Reset 的三点对比：
--     · Reset 有 `status ~= READY` 守卫，Stop **没有** → Stop 一定全树走一遍
--     · Reset 只改 status，Stop 会**触碰外部世界**（摘事件监听）
--     · Reset 可被反复调用，Stop 对 EventNode 而言**只应调一次**（713 行有 eventfn 守卫）
--   ★★ 全文件只有一个 OnStop 实现：EventNode:713。
--     所以「Stop 的成本」实际就是「摘掉多少个事件监听」。
--   ※ 潜在陷阱：若某个第三方节点在 OnStop 里做了不可逆的事（注销协程等），
--     而调用方连调两次 Stop，就会出错。本文件自己避免了（716 行的守卫），
--     但模组节点未必。
function BehaviourNode:Stop()
--★ `if self.OnStop then` —— 钩子检测用真值判断，
--   所以定义 OnStop 时不能写成 `OnStop = false` 之类。
--   ★★ 子类覆写 OnStop 时**必须自己决定要不要调基类版本**——
--     这里的机制是「钩子替换」而非「钩子链」，不像典型模板方法那样自动串联。
    if self.OnStop then
        self:OnStop()
    end
--★ 无条件递归：不看 status，因为 Stop 的语义是「拆干净」，
--   已完成的节点同样持有资源（比如 EventNode 的监听）。
--   ★★ 这与 Reset 的守卫形成鲜明对比 ——
--     读代码时看到 Stop 无条件递归、Reset 有守卫，就知道两者语义不同。
    if self.children then
        for idx, child in ipairs(self.children) do
            child:Stop()
        end
    end
end


---------------------------------------------------------------------------------------
--★★【DecoratorNode —— 「单子节点 + 改写结果」的基类】
--   ★★ 它与传统行为树里的 Decorator 概念一致：只包一个孩子，
--     自己不改行为，只**转换孩子的状态**。
--   ★★ 三个内置装饰器（378/395/411 行）覆盖了绝大多数需求：
--     Not               —— 取反（孩子 SUCCESS → 自己 FAILED）
--     FailIfRunning     —— 孩子只要还在跑就算失败（「别做这件事」）
--     FailIfSuccess     —— 孩子成功就算失败（「除非做成了，否则不做」）
--   ★★ 【它与 ConditionNode 的本质区别】
--     ConditionNode 无子节点，用**外部函数**判定；
--     DecoratorNode 有子节点，用**孩子的结果**判定。
--     前者是「问世界」，后者是「改孩子的答案」。
--   ★★ 为什么强制 `{child}` 包成数组？
--     因为 BehaviourNode 基类的所有遍历方法（Step/Reset/SaveStatus）
--     都假定 self.children 是数组。装饰器若直接存 child 字段，
--     这些方法就会因为 children 为 nil 而静默跳过整棵子树。
--     ★ 这是「结构对齐」的价值：为了多复用几个基类方法，付出一个数组的代价。
DecoratorNode = Class(BehaviourNode, function(self, name, child)
--★ 注意这一行用的是 **Tab 缩进**，而文件其余部分用 4 空格。
--   ※ 不影响 Lua 语义（Lua 不敏感缩进），但说明这行是后期加的。
--   ★ 名称兜底为 "Decorator"，子类一般会覆盖（379/396/412 行都传了具体名）。
--   ★★ 第二个参数是 `{child}` —— Lua 里 `{child}` 等价于数组 [child]。
--     若 child 为 nil，则 children 变成空表 `{}`（长度 0），
--     此时访问 children[1] 会得 nil。※ 构造时不校验，由使用时报错。
	BehaviourNode._ctor(self, name or "Decorator", {child})
end)

---------------------------------------------------------------------------------------


--★★【ConditionNode —— 「纯判定」节点：一次函数调用决定成败】
--   ★★ 这是全文件最高频使用的节点类型。behaviours/ 与 brains/ 里
--     出现的 `ConditionNode(function() ... end, "名字")` 绝大多数都是它。
--   ★★ 【构造签名反直觉的地方】
--     `ConditionNode(fn, name)` —— 第一个参数是函数，第二个才是名字。
--     而其他节点大多是 `xxxNode(name, children)` 或 `xxxNode(children, ...)`。
--     ★ 原因是它没有 children，需要用「第一个参数占了位置」的方式保持
--       `function(self, fn, name)` 与基类 `function(self, name, children)` 形状相近。
--     ※ 实际用起来要小心：`WhileNode(cond, name, node)` 里 771 行的写法
--       就是靠这个顺序才能直接转发。
--   ★★ 无子节点 ⇒ children 为 nil ⇒ 不参与 GetTreeSleepTime 的遍历
--     ⇒ 也不受 Step 的级联 Reset 影响（171 行的守卫）。
--     这两点正是「条件每帧重算」的物理保证。
ConditionNode = Class(BehaviourNode, function(self, fn, name)
--★ name 兜底 "Condition"。实际用起来几乎都会显式传名字（调试全靠它）。
--   ※ 不传 children，所以 self.children 为 nil —— 这是**刻意的**：
--     条件节点没有孩子，103 行 GetSleepTime 的 `not self.children` 会成立，
--     再配合 is_a(ConditionNode) 被排除，于是条件节点对休眠时间零贡献。
    BehaviourNode._ctor(self, name or "Condition")
--★ fn 存成字段 —— Visit 里直接调用。闭包捕获了外部世界的引用，
--   所以条件天然是「动态」的：每次思考都重新读实体的当前状态。
--   ★★ 不缓存结果，是本框架「无隐藏游标」哲学的又一处体现。
    self.fn = fn
end)

--★★【ConditionNode:Visit —— 三行做完判定，无任何状态记忆】
--   ★★ 【为什么条件节点永远不该有中间态？】
--     因为条件的语义是「此刻成立吗」。若允许它 RUNNING，
--     就会出现「条件从真变假，但节点还在等，结果永远停在旧答案」。
--     禁止 RUNNING = 每帧重新回答 = 永远不会过时。
--   ★★ 而这正是 WhileNode（771 行）用 Parallel + Condition 组合出来的原因：
--     「条件每帧重算」由 ConditionNode 提供，
--     「条件为假时中断后续节点」由 ParallelNode 提供（见 685 行的短路返回）。
--   ★ 在 Sequence 里，条件永远在同一轮得出 SUCCESS/FAILED，
--     所以 Sequence 不可能停在「等条件」上（对比 ConditionWaitNode）。
function ConditionNode:Visit()
--★ 直接调用，无参。
--   ★★ 条件函数**不允许 yield**：它在 Visit 栈里同步执行，
--     一旦 yield 会破坏 BT:Update 的三段式（Visit 未完成就进入 SaveStatus）。
--     ※ 这是 A1/A2 那类协程陷阱在决策层的变体 ——
--       条件函数里绝对不要写 Sleep / DoTaskInTime 的等待逻辑。
--     ★ 参见 bug-patterns.md 分区 A：「定时器回调是不可挂起的」同理适用于此。
    if self.fn() then
--★ 成立即 SUCCESS。SUCCESS 在组合节点里的含义见 327 行（Sequence 继续）。
        self.status = SUCCESS
    else
--★ 不成立即 FAILED。在 Sequence 里会立刻短路整条序列（327 行）。
--   ★★ 这是「条件不满足就什么都不做」的自然实现，不需要额外的 Not 装饰器。
        self.status = FAILED
    end
end

---------------------------------------------------------------------------------------


--★★【MultiConditionNode —— 「两段式条件」：进入时判一次，之后判另一个】
--   这是本文件里最容易被忽略、但设计很精巧的一个节点。
--   ★★ 【它解决的问题】
--     有些逻辑需要「一次性门」+「持续条件」两段：
--       · 进入时判断一次「该不该做这件事」（start）
--       · 之后每帧判断「还能不能继续做」（continue）
--     典型：if 已发现目标 then while 目标还活着 do 追击 end
--   ★★ 单独用 ConditionNode 做不到，因为它的 running 标志在基类 Reset 时
--     **不被清**（171 行守卫只看 status，不看自定义字段），
--     所以这个「粘住的 running」恰好可用来做两段判定 —— 巧合地成了特性。
--   ★★ 唯一使用者是 IfThenDoWhileNode（792 行）：
--     `ParallelNode{ MultiConditionNode(ifcond, whilecond), node }`
--     语义就是字面的「if 条件 then while 另一条件 do ...」。
MultiConditionNode = Class(BehaviourNode, function(self, start, continue, name)
--★ name 兜底仍是 "Condition"（与 ConditionNode 相同），
--   ※ 所以调试输出里 MultiConditionNode 和 ConditionNode 无法从名字区分。
--   ★ 这是一个小的可观测性缺陷：排查 IfThenDoWhileNode 时看不出是哪个。
    BehaviourNode._ctor(self, name or "Condition")
--★★ start —— 第一次进入时（running 为假）求值的函数。
--   ★ 典型：`function() return self.inst.components.combat.target ~= nil end`
    self.start = start
--★★ continue —— running 已为真时每帧求值的函数（「还能继续吗」）。
--   ★ 两段式的意义：continue 通常更宽松（如「目标还在视野内」），
--     因为一旦启动就不该轻易放弃。
--   ※ 但注意 running 一旦为真就**永不复位**（无 Reset 覆写，见 171 行推论）——
--     所以 continue 为假后，下一轮 running 变假，start 又会被重新求值。
--     ★★ 这一点与名字暗示的「if-then-while」**不完全一致**：
--       它实际是「每帧在 start/continue 之间按 running 择一」，
--       而 running 是粘住的。这会在 continue 失败后重启 if 判定。
--     ★ 对绝大多数用法（条件都是幂等的）没有可观察差异，
--       但若 start 有副作用（如「分配一个目标」），就会每次都重新分配。
    self.continue = continue
end)

--★★【MultiConditionNode:Visit —— 用 running 粘住「该问哪个函数」】
--   ★★ 全部逻辑就是这一句 if/else：
--     还没跑起来 → 问 start（门卫）
--     已经跑起来 → 问 continue（维持）
--   ★★ 然后无论问谁，结果都映射成 SUCCESS/FAILED，
--     **running 本身不映射成 RUNNING** ——
--     这一点很关键：节点只被查询（is it ok），不被等待（等到何时）。
--   ★ 真正的「等待」由 ParallelNode 的另一个孩子（node）承担。
function MultiConditionNode:Visit()
--★ `not self.running` —— 首帧（running 为 nil）走 start 分支。
--   ※ 注意 running 是**唯一**的自定义状态，且如上所述永不被 Reset 清除。
    if not self.running then
--★★ 求值入口。函数无参（若需要上下文，调用方自己用闭包捕获）。
        self.running = self.start()
    else
--★ 后续帧走 continue。
        self.running = self.continue()
    end

--★★ running 为真 → SUCCESS。注意这里**不设 RUNNING**。
--   ★★ 推论：MultiConditionNode 在 GetTreeSleepTime 里永远不贡献睡眠时间
--     （它不是 RUNNING），所以整个 Parallel 也不会因它而休眠。
--     ★ 这是正确的 —— 条件每帧重算正是它的存在意义。
    if self.running then
        self.status = SUCCESS
    else
        self.status = FAILED
--★ running 为假 → FAILED。ParallelNode 见此立刻整体 FAILED（672-674 行），
--   连带中断另一个孩子。这就是 IfThenDoWhileNode 的「退出 while」语义。
    end
end


---------------------------------------------------------------------------------------


--★★【ConditionWaitNode —— 「等条件成立」的节点（名字有误导性）】
--   ★★ 它与 ConditionNode 只差一行，但语义完全相反：
--     ConditionNode      成立→SUCCESS，不成立→FAILED（不等）
--     ConditionWaitNode  成立→SUCCESS，不成立→RUNNING（等）
--   ★★ 【为什么需要它？】
--     「等某件事发生」无法用 ConditionNode 表达：
--       若返回 FAILED，Sequence 会短路掉后面的动作；
--       若硬写成 RUNNING，就违反了 207 行「条件不该有中间态」的约定。
--     拆成两个类型，让「等」成为一类节点的固有语义，是很干净的做法。
--   ★★ 典型用途：等目标进入攻击距离、等技能冷却完毕、等某变量被设置。
--   ※ 代价：RUNNING 状态会让它参与 GetTreeSleepTime（117 行），
--     但因为它**不是** ConditionNode 的子类，103 行的 is_a 检查排除不到它，
--     所以它会走「无孩子 + 非条件」分支 → 若没调过 Sleep 则返回 0，
--     意味着 **brain 每帧都会醒**。
--     ★★ 结论：用 ConditionWaitNode 时如果不配 Sleep，整棵树会每帧被调度。
--       这在数量少时无所谓，但成百上千个 AI 时是实打实的 CPU 消耗。
--     ★ 更危险的是：没有任何超时机制。一个永远不成立的等待会永远 RUNNING，
--       整棵树永远停在它上面（详见 812 行 LatchNode 的对照）。
ConditionWaitNode = Class(BehaviourNode, function(self, fn, name)
--★ name 兜底 "Wait" —— ※ **与 WaitNode 的兜底名完全相同**。
--   ★★ 调试输出里 `Wait - RUNNING <SUCCESS>` 无法区分是「等固定时长」
--     还是「等条件成立」。这是本文件的一处可观测性缺陷。
    BehaviourNode._ctor(self, name or "Wait")
    self.fn = fn
end)

--★★ 两个分支的映射是本节点的全部意义（对照 207-213 行）。
--   ★ 成立的那一刻给 SUCCESS，让父节点（通常是 Sequence）往下走。
function ConditionWaitNode:Visit()
    if self.fn() then
        self.status = SUCCESS
    else
--★★ 【本文件最重要的语义分水岭之一】不成立 → RUNNING（而不是 FAILED）。
--   ★★ 三个直接后果，每一个都是实践中的坑：
--     ① **它会卡住父节点**：在 Sequence 里 RUNNING 会让序列停在原地（327 行），
--        在 Selector 里 RUNNING 会让整条选择链停住（366 行）。
--        所以 ConditionWaitNode **只能放在序列的末尾**，
--        或者放在 PriorityNode 的最后一位（作为兜底）。
--     ② **它永不自愈**：没有 timeout / 超时参数。
--        条件不成立就永远 RUNNING，树永远走不下去。
--        ※ 这是「AI 卡住」的一大来源，且没有任何框架级报错。
--     ③ **它让 brain 无法休眠**：RUNNING 叶节点若没 Sleep 就返回 0，
--        导致整个 brain 每帧被 BrainManager 调度（详见 242 行说明）。
--   ★ 缓解手段：把「条件」写成有界形式，例如
--     `function() return self.inst.cooldown <= 0 or GetTime() > deadline end`，
--     用外部超时兜底。这是 DST 各 brain 的通行做法。
        self.status = RUNNING
    end
end


---------------------------------------------------------------------------------------


--★★【ActionNode —— 「执行一段代码」的最简节点】
--   ★★ 它几乎总是被包在别的节点里用，本身不构成决策：
--     LoopNode{ ActionNode(function() inst:PushEvent("matchover") end) }
--     —— 这是 pigelitebrain.lua:251 的真实写法（用 LoopNode 无限重复）。
--   ★★ 【为什么需要一个「只做一件事」的节点？】
--     因为 ConditionNode 是「判定」，DoAction 这类需要「执行」。
--     ActionNode 把两者分开的代价是 status 永远 SUCCESS，
--     收益是可以在组合节点里与条件自由搭配。
--   ★ 它**从不返回 RUNNING**（见 264-267 行），
--     所以每次访问都会被 Step 立刻 Reset（161 行），
--     意味着「每次被访问就执行一次」—— 想重复必须靠 LoopNode。
ActionNode = Class(BehaviourNode, function(self, action, name)
--★ name 兜底 "ActionNode"。实践里几乎都会传名字便于调试。
    BehaviourNode._ctor(self, name or "ActionNode")
    self.action = action
end)

--★★【ActionNode:Visit —— 执行后无条件 SUCCESS】
--   ★★ 【为什么不允许失败？】
--     因为 action 是一个无返回值回调，本框架没有约定它能表达失败。
--     ★ 若动作可能做不成（找不到目标、冷却中等），
--       正确写法是包一层：`ActionNode` 放在 Sequence 的末尾，
--       前面用 ConditionNode 先把「能做」的条件判掉。
--     ★ 例如 behaviours/doaction.lua 用的是 DoAction 自定义节点而非 ActionNode。
--   ※ 这个限制意味着 ActionNode 无法表达「尝试做但失败」，
--     只能表达「做或不做」。这是刻意的简化。
function ActionNode:Visit()
--★ 无条件调用。不检查结果、不捕获错误。
--   ※ action 里若 yield 会破坏三段式（同 208 行的理由）。
--   ※ action 里若抛 error，整个 BT:Update 中断，树停在半更新状态
--     （Visit 已改了部分 status，SaveStatus/Step 没跑）。
--     ★ 这是行为树里**最需要防御**的一行：动作里应尽量不炸。
    self.action()
--★ 恒为 SUCCESS。对比 ConditionWaitNode 的 251 行 —— 差一个字，语义天壤之别。
    self.status = SUCCESS
end


---------------------------------------------------------------------------------------


--★★【WaitNode —— 「固定等 N 秒」节点（真正的等待）】
--   ★★ 与 ConditionWaitNode 的区别：
--     ConditionWaitNode 等的是「某个条件变真」（无限期）
--     WaitNode         等的是「固定时长」（有终点，不会卡死）
--   ★★ 因此 WaitNode 是**有界等待**，是框架里唯一保证会自己结束的等待节点。
--   ★★ 【两阶段状态机】这是本节点唯一的技巧，也是它正确的关键：
--       · 非 RUNNING 时：记录 wake_time，转 RUNNING
--       · RUNNING 时：比对当前时间与 wake_time，到点 SUCCESS
--   ★★ 为什么要分两阶段？wake_time 必须在「开始等的那一刻」计算。
--     若每帧都重算 `wake_time = now + N`，等待永远不会结束（永远差 N 秒）。
--     ★ 这就是所有「计时器」类节点的通用模式，本文件用 status 做阶段标记。
--   ★★ wait_time 支持 FunctionOrValue（287 行）—— 传函数可做「动态时长」，
--     典型用途：`WaitNode(function() return math.random()*0.5 end)`。
--     ★★ 注意函数在**每次开始等待时**求值一次，不是每帧。
WaitNode = Class(BehaviourNode, function(self, time)
--★ name 硬编码 "Wait"。※ 与 ConditionWaitNode:243 的兜底名重复（见该行说明）。
    BehaviourNode._ctor(self, "Wait")
--★★ wait_time 存原始值（可能是数字也可能是函数），不预先求值。
--   ★ 推迟到 287 行求值，好处是闭包能捕获「当下的」上下文。
    self.wait_time = time
end)

--★★ DBString 输出**剩余秒数** —— 「还剩 1.34 秒」。
--   ★ 这是排查「AI 卡住」最有用的一个数字：
--     若某节点长期卡在 `Wait - RUNNING <SUCCESS> (1.34)`，
--     说明它每秒都在重置倒计时 —— 那就是 wake_time 每次都被重算。
--   ★★ 142 行的「仅 RUNNING 才输出 DBString」在这里是**必需的**：
--     非 RUNNING 时 self.wake_time 为 nil，`nil - GetTime()` 会崩。
--     ★ 可见那个 `if status == RUNNING` 的守卫不只为降噪，还承担了正确性。
function WaitNode:DBString()
--★★ `self.wake_time - GetTime()` = 剩余秒数。
--   ※ 首帧调用 DBString 时 wake_time 可能为 nil（第 142 行的守卫保证了不会）。
    local w = self.wake_time - GetTime()
    return string.format("%2.2f", w)
end

--★★【WaitNode:Visit —— 两阶段计时机的全部实现】
--   变量 current_time 只取一次，两处比较都用它，保证同一帧内一致。
function WaitNode:Visit()
    local current_time = GetTime()

--★★【阶段一：不是 RUNNING → 记录起点，转 RUNNING】
--   ★★ 为什么不能用 status == READY 来判断「刚开始」？
--     因为 status 还可能是 SUCCESS / FAILED（上一轮刚跑完，尚未被 Step 复位）。
--     用 `~= RUNNING` 覆盖了所有非运行态，语义是「任何时候不running都当作新开始」。
--   ★★ 这一行是本节点的全部秘密：它让「等待」成为自持的状态，
--     只要自己保持 RUNNING，Step 就不会 Reset 它（161-168 行），
--     wake_time 因而得以保留到下一次 Visit。
--   ★ 实践含义：**WaitNode 只能通过被 Reset 打断**（父节点整体复位）。
--     若要提前结束一段等待，只能让父节点不再 Visit 它。
    if self.status ~= RUNNING then
--★★ FunctionOrValue 在此求值一次（见 util.lua:1716 的定义）。
--   ★★ 为什么不在构造时求值？因为构造时可能还没准备好上下文
--     （比如行为树在 OnStart 里构造，某些状态尚未设置）。
--   ★★ 也因为它允许时长随「当前局势」变化：
--     `WaitNode(function() return self.inst.components.caged:GetCageLength()*0.5 end)`。
--   ※ 求值结果赋给 wake_time，因此 duration 变成绝对时刻，
--     期间再改 self.wait_time 不影响本次等待。
        self.wake_time = current_time + FunctionOrValue(self.wait_time)
--★ 转 RUNNING —— 这是「等待」的起点标记，Step 会因此保住本节点。
        self.status = RUNNING
    end

--★ 条件恒真（286 行已保证非 RUNNING 会转 RUNNING），
--   所以实际总是走这个分支。写成 if 是为了表达「此刻是运行态」。
    if self.status == RUNNING then
--★★ 到点判定：`current_time >= self.wake_time`。
--   ★ 用 >= 而非 >：保证最终一定等到（浮点误差下 > 可能永不成立）。
        if current_time >= self.wake_time then
--★ 到点即 SUCCESS，父节点（Sequence/Selector）本轮就能往下走。
--   ★★ 注意：本轮就 SUCCESS，不需要再等一帧。
            self.status = SUCCESS
        else
--★★⚠【疑似缺陷 · 符号写反】`self:Sleep(current_time - self.wake_time)`
--   ★★ 这个表达式在数学上是**负数**：此刻还没到点（292 行的 else 分支），
--     所以 current_time < wake_time，差值为负。
--     作者想表达的显然是「还要等 wake_time - current_time 秒」。
--   ★★ 【为什么它没造成明显故障？】
--     97 行的 Sleep 照单全收：`nextupdatetime = GetTime() + 负数` = 一个过去时刻。
--     101-115 行 GetSleepTime 里，105 行算出负的剩余时间，
--     106-108 行把它**钳成 0** → 语义退化为「每帧都醒，不睡」。
--   ★★ 【实际后果：休眠优化完全失效】
--     WaitNode 的**唯一存在意义**就是让 brain 睡 N 秒（见 37 行的 GetSleepTime 协议）。
--     这一处符号错误让所有 WaitNode 的休眠时间永远是 0，
--     于是 brain.lua:143 的 `if sleep_amount > GetTickTime()` 恒假，
--     brain 永不入睡队列，每帧都被 BrainManager 调度。
--     ★ 也就是说：**用了 WaitNode 的 AI，节流效果等于没有**。
--   ★★ 【为什么至今没被发现】
--     因为「等 N 秒」这个**功能**是对的（靠 wake_time 比较，见 292 行），
--     错的只是「顺便告诉调度器要睡多久」这个**优化**。
--     功能测试全过，只有性能剖析才会暴露。
--   ※ 修复方向（仅记录，不改代码）：
--     `self:Sleep(self.wake_time - current_time)`
--     改动风险极低：只影响休眠时间，不影响状态流转。
--     ★ 唯一需确认的连带影响：修好后 WaitNode 会真的让 brain 睡 N 秒，
--       期间**只有事件能提前唤醒**（见 37 行的三条唤醒路径）。
--       若某棵树依赖「每帧轮询直到等待结束」，修正后会暴露出来。
--       按设计语义（Hibernate 只能被事件唤醒）这是正确的，
--       但属于行为变更而非纯 bug 修复，需实测。
--   ※ 旁证：101-115 行的负数钳位（106-108）正是为这类情况兜底的，
--     说明作者意识到「Sleep 会被传入负数」，但没意识到问题出在调用方。
            self:Sleep(current_time - self.wake_time)
        end
    end

end


---------------------------------------------------------------------------------------

--★★【SequenceNode —— 「依次做，全部成功才算成功」】
--   ★★ 【与「传统顺序遍历型 BT」的根本差异】
--     传统实现：每帧从 idx=1 开始跑，跑到 RUNNING 就 return，
--               下帧仍从 idx=1 开始但靠「已 SUCCESS 的跳过」来找进度。
--     本实现（319-336 行）：靠 `self.status == RUNNING` 判断是否延续，
--               非 RUNNING 时把 idx 归 1。
--   ★★ 【为什么 idx 与 status 要分开存？】
--     status 是**公共字段**（会被 SaveStatus 快照、被 Reset 归零），
--     idx 是**私有进度**（组合节点自己的记忆）。
--     ★★ 分开的好处：status 可以被父节点查询（组合节点必须暴露它），
--       而 idx 必须被 Reset 精确管理 —— 所以 314 行专门覆写了 Reset。
--     ★ 若把进度塞进 status 字符串（如 "SUCCESS_3"），父节点就无从判断了。
--   ★★ 典型用法：`SequenceNode{ ConditionNode(c), DoAction(a) }`
--     语义「条件成立就做这个动作」，这是 DST brain 里最常见的组合。
--     对照 783 行 IfNode 的语法糖 —— 它就是这两行的封装。
SequenceNode = Class(BehaviourNode, function(self, children)
--★ name 硬编码 "Sequence"（不是从参数传入）。
--   ※ 对比 PriorityNode:534 也硬编码 "Priority"，LoopNode:428 硬编码 "Sequence"。
--   ★★ 后果：调试输出里**无法区分 SequenceNode 与 LoopNode**（见 428 行 ※）。
--   ★ 硬编码而非可传参，是因为它们属于「框架内建」节点，名字不会歧义；
--     需要区分时靠 DBString（309 行输出 idx）。
    BehaviourNode._ctor(self, "Sequence", children)
--★★ idx = 1 —— 「还没开始做」。这个字段是 Sequence 的全部记忆。
--   ★★ 与 RandomNode:491（idx = nil）、PriorityNode:579（idx = nil）对比：
--     Sequence 用 1 起步，Random/Priority 用 nil 表示「尚未选中」，
--     因为它们需要区分「从头」与「无」。
    self.idx = 1
end)

--★ DBString 输出当前走到第几个孩子 —— 「走到第 3 步了」。
--   ★★ 排查价值：若某 Sequence 长时间停在同一个 idx，
--     说明那个孩子一直在 RUNNING（卡住了）。idx 就是卡点。
function SequenceNode:DBString()
--★ tostring(self.idx) 转字符串交给 string.format 的 %s。
    return tostring(self.idx)
end


--★★【SequenceNode:Reset —— 必须覆写，因为基类不知道 idx 的存在】
--   ★★ 写法要点：`self._base.Reset(self)` 先调基类做级联，
--     再把自己独有的 idx 归位。
--   ★★ `_base` 是什么？class.lua:99 在 `Class(base, ...)` 里塞的 `c._base = base`，
--     指向被继承的基类表。所以 `self._base.Reset` 就是「调 BehaviourNode.Reset」。
--   ★★ 【这是本文件里唯一的「显式父类调用」写法，出现在三处】
--     SequenceNode:315 / SelectorNode:351 / LoopNode:440 / RandomNode:490 /
--     PriorityNode:578 / EventNode:740 / EventNode:746
--     ★ 其中 EventNode:740 特别关键：`self._base.Step(self)` 调的是基类 Step，
--       而不是自己的 Step —— 否则会无限递归。
--   ★★ 【为什么必须覆写？】
--     因为 171 行基类 Reset 的守卫是 `if self.status ~= READY`，
--     它只管 status，**完全不知道 idx 的存在**。
--     ★★ 推论出一条通用规则：
--       「节点若引入了基类不认识的自定义状态，就必须自己覆写 Reset（或确保它无害）」。
--     ★ 两种处理方式在本文件里都有实例：
--       覆写并归零（Sequence/Selector/Loop/Random/Priority/Event），
--       或刻意不归零（MultiConditionNode 的 running、LatchNode 的 lastlatchtime）。
--     后者是**有意的粘性状态**，前者是**必须擦除的进度**。
--   ※ 忘记覆写的后果：idx 卡在末尾，Sequence 永远 SUCCESS，行为再也不会重跑。
--     （实际不会发生，因为基类会把 status 归 READY，319 行会把 idx 归 1 ——
--     属于双保险。）
function SequenceNode:Reset()
--★ 显式父类调用。写法上等价于 `BehaviourNode.Reset(self)`。
--   ★★ 注意 EventNode:746 用的是 `self._base.Reset(self)`（无冒号），
--     而这里也是无冒号传 self —— 一致。
    self._base.Reset(self)
--★★ idx 归 1 —— 「下次从头开始」。
--   ★★ 这一行是 Sequence 幂等性的来源：无论被 Reset 多少次，
--     重新开始时都从第一个孩子起步。
    self.idx = 1
end

--★★【SequenceNode:Visit —— 本文件最核心的循环，也是最容易看错的一处】
--   ★★ 【两个隐藏机制，缺一个整个框架就不成立】
--   机制一：**idx 的归位条件是「我是否在跑」，不是「我是否成功」**（320-322 行）
--     · 本轮不是 RUNNING → idx = 1（重新开始）
--     · 本轮 RUNNING → 保留 idx（延续进度）
--     ★★ 注意与 Step（161 行）的配合：每轮结束时非 RUNNING 的节点被 Reset 成 READY，
--       所以下一轮 Visit 时 status 必然是 READY 或 RUNNING ——
--       「READY 就从头」这条规则因此永远成立。
--       ★★ 三者构成一个自洽的闭环：
--         Step 擦除进度标记（status→READY）
--           → Visit 见 READY 就重置 idx
--             → 序列从头执行
--   机制二：**while 循环会在同一轮里连续推进多个孩子**（324-333 行）
--     · 只有当孩子返回 RUNNING 或 FAILED 才 return 中断
--     · 孩子 SUCCESS → idx+1，**在同一次 Visit 里继续 Visit 下一个孩子**
--     ★★ 这是「同一帧内做完能立刻做完的事」的关键：
--       一个「条件 → 立即动作」序列可以在一次思考里全部完成，
--       不需要等到下一帧。
--     ★ 对照 349-375 行 SelectorNode:Visit，结构完全对称，只是中断条件不同。
function SequenceNode:Visit()
--★★ `if self.status ~= RUNNING then self.idx = 1 end` —— 机制一的落点。
--   ★★ 这一行与 161 行 Step 的配合是本框架最精妙的咬合：
--     Step（帧尾）把跑完的节点 Reset 成 READY；
--     Visit（帧首）见非 RUNNING 就认为「这是一次全新的尝试」，idx 归 1。
--   ★★ 【推论：Sequence 是「幂等重放」型节点】
--     每一次从 READY 起步的序列都是从头执行的完整流程，
--     不存在「上轮做到第 2 步，这轮接着做」的残留状态。
--     ★ 这与 PriorityNode 完全不同 —— Priority 的 idx **会跨轮保留**
--       （577 行 Reset 把 idx 设成 nil，但 Step 只 Reset 非 RUNNING 的节点，
--       所以 RUNNING 的 Priority 的 idx 被保留）。
--     ★★ 两者对照就能理解 DST 的决策风格：
--       Priority = 「保持正在做的事，只在必要时换」（有连续性）
--       Sequence = 「每次从头走一遍流程」（无连续性）
    if self.status ~= RUNNING then
--★ idx 归 1。与 316 行的 Reset 重复，属于**双保险**（见 314 行的 ※）。
--   ★ 重复不是冗余：320 行处理「本轮首次进入」，316 行处理「被父节点 Reset」。
--     两条路径都会导致「需要从头」，所以两处都要归位。
        self.idx = 1
    end

--★★ while 而非 for —— 因为 idx 会在循环体内被修改（332 行），
--   且需要「跑到边界就自然结束」的语义。
--   ★ `#self.children` 每次求值；children 是数组，# 即长度。
    while self.idx <= #self.children do
--★ 只取当前孩子，不递归遍历 —— 递归由 child:Visit 自己负责。
        local child = self.children[self.idx]
--★★【递归的落点 —— 这里是「父节点询问子节点」的唯一入口类型】
--   ★ 组合节点只 Visit「当前这一个」孩子，不遍历全部。
--   ★★ 原因：status 已经把「该问谁」编码进 idx 了，遍历全部是浪费。
--   ★★ 对比 PriorityNode:598 的 `for idx, child in ipairs(...)` ——
--     Priority 必须遍历全部（它要挑赢家），Sequence 不需要（它顺序执行）。
--     ★ 这是两种组合节点最本质的差别，也是它们性能特征不同的原因。
--   ※ 若某孩子是 RUNNING，Visit 仍会被调用（而不是跳过）——
--     因为 RUNNING 的孩子需要「被推进」（如 WaitNode 比时间、Leash 检查距离）。
--     ★★ 这一点常被误解：RUNNING 不等于「冻结」，而是「继续问它」。
        child:Visit()
--★★【本框架最重要的 4 行之一：Sequence 的中断条件】
--   `if child.status == RUNNING or child.status == FAILED then`
--   ★★ 逐个解读为什么是这两个状态：
--     · RUNNING → 「还没做完，等下一轮再问它」→ 中断（保留 idx）
--     · FAILED  → 「做不到了，整条序列没意义」→ 中断（idx 留在失败处）
--     · SUCCESS → 「做完了，看下一个」→ **继续循环**（idx+1）
--   ★★ 【为什么 FAILED 要立刻中断，而不是跳过看下一个？】
--     因为 Sequence 的语义是「依次做，缺一不可」。
--     第一个做不成的事会让后续全部失去前提，
--     所以整体立刻变 FAILED（328 行把孩子的 FAILED 透传给父）。
--   ★★ 【与 SelectorNode:366 的对照是理解组合节点的关键】
--     Sequence : 遇到 RUNNING 或 FAILED → 停
--     Selector : 遇到 RUNNING 或 SUCCESS → 停
--     ★★ 两者是**完全对称**的：SUCCESS 在 Sequence 里是「通过」，
--       在 Selector 里是「命中，就用它」；FAILED 在 Sequence 里是「链条断了」，
--       在 Selector 里是「这个不行，试下一个」。
--     ★ 一句话记忆：
--       Sequence  追求「全部都要」→ 找到一个不行就整体崩
--       Selector  追求「有一个就行」→ 找到一个行就整体定
--   ★★ 注意 status 被**直接透传**（328 行 self.status = child.status），
--     所以 Sequence 自己永远不会有第三种状态。
        if child.status == RUNNING or child.status == FAILED then
--★★ 直接透传孩子的状态 —— 「我即我现在的孩子」。
--   ★★ 这行让 Sequence 在有孩子时永远与当前孩子同态，
--     状态机被压缩成两层：Sequence ↔ 当前孩子。
--   ★ 这是「组合即传递」的设计：组合节点不做状态翻译，只做路由。
            self.status = child.status
--★ return —— 立即结束本节点的 Visit，父节点拿到的是这个透传上来的状态。
--   ★★ 不 break 而用 return：这是递归函数，直接结束整个 Visit 调用。
--     所以「中断」= 「本节点 Visit 结束」，语义上就是「我停在这」。
            return
        end

--★ 当前孩子成功了，前进到下一个。
--   ★★ 配合 326 行，会在**同一次 Visit** 里立刻 Visit 新idx 的孩子。
--     ★ 这就是「一次思考内连续完成多个步骤」的实现。
--     ※ 副作用：一个很长的 Sequence 在条件都成立时会一次性跑完，
--       这帧的 CPU 消耗会偏高。对 brain 的可观察行为没有影响。
        self.idx = self.idx + 1
    end

--★★ 所有孩子都 SUCCESS → 整个序列 SUCCESS。
--   ★★ 走到这一行意味着 while 条件失效，即 idx > #children ——
--     即所有孩子都返回了 SUCCESS。
--   ★ SUCCESS 之后本轮即结束，父节点（如 Selector）会立刻尝试下一个分支。
--   ★★ 注意 SUCCESS 会导致下一轮 Step 把本节点 Reset（161 行），
--     所以「做完就忘」是自动发生的，无需显式清理。
    self.status = SUCCESS
end

---------------------------------------------------------------------------------------

--★★【SelectorNode —— 「依次试，第一个成功就停」】
--   ★★ 它与 SequenceNode 是**严格的镜像结构**，对比一眼就懂：
--     327 行 Sequence : `if RUNNING or FAILED  then` 停
--     366 行 Selector: `if RUNNING or SUCCESS then` 停
--     335 行 Sequence 收尾 SUCCESS ； 374 行 Selector 收尾 FAILED
--   ★★ 【为什么 DST 的脑根几乎都是 PriorityNode 而不是 Selector？】
--     Selector 语义是「按顺序试」，没有「周期性重排」的概念，
--     也没有「抢占更高优先级」的概念 —— 它会一直停在第一个成功的分支上，
--     直到那个分支自己 FAILED。
--     PriorityNode（533 行）才是真正带优先级与抢占的版本。
--     ★ 所以 Selector 在 DST 里主要用于「小片段组合」（如 doaction.lua 的内部结构），
--       很少直接做根节点。
--   ★★ 典型用法：`SelectorNode{ 找食物, 找火, Wander }`
--     语义「有食物吃食物，否则生火，否则闲逛」。
SelectorNode = Class(BehaviourNode, function(self, children)
--★ name 硬编码 "Selector"。
    BehaviourNode._ctor(self, "Selector", children)
--★ idx = 1，与 Sequence:306 行同构。
    self.idx = 1
end)

--★ DBString 与 Sequence 完全相同（都输出 idx）——
--   ※ 调试输出里两者只能靠 name 区分（"Sequence" vs "Selector"）。
function SelectorNode:DBString()
--★ tostring(idx)。
    return tostring(self.idx)
end


--★★【SelectorNode:Reset —— 与 Sequence:314 完全同构】
--   ★★ 为什么两者都要覆写？同一原因：基类 Reset 只管 status（171 行守卫），
--     不知道 idx 的存在。不覆写会导致「停在原地的 idx 永远选不中后面的分支」。
--   ★★ 【两者的 Reset 在功能上完全可互换】
--     说明 idx 的归位是「组合节点通用协议」，不是某一种的特有需求。
--     ★ 这也提示：自定义组合节点只要引入游标，就必须覆写 Reset。
function SelectorNode:Reset()
--★ 显式父类调用（class.lua:99 的 _base 机制）。
    self._base.Reset(self)
--★ idx 归 1。
    self.idx = 1
end

--★★【SelectorNode:Visit —— 与 Sequence:319 的结构对称】
--   唯一差别：中断条件与收尾状态相反。
--   ★ 这里多了一个 `local done = false`（361 行），
--   ※ 但它**从未被使用**（见 361 行的 ※ 标注），是复制粘贴的残留。
--   ★ 与 LoopNode:452、RandomNode:497 的 `local done` 同病，
--     三处都声明了未使用的局部变量 —— 说明这三段代码是同一份模板改的。
function SelectorNode:Visit()

--★★ `if self.status ~= RUNNING then self.idx = 1 end` —— 与 320 行逐字相同。
--   ★★ 这再次印证 320 行注释里的结论：
--     「status == RUNNING」是本框架**唯一**的进度记忆机制。
--     所有带游标的组合节点都靠这一行决定「从头开始还是继续」。
--   ★★ 与 PriorityNode 对照会更清晰：
--     Priority 的 idx 在 Reset 里被设为 **nil**（579 行），不是 1；
--     因为 Priority 需要表达「尚未选中任何分支」这个第三种状态。
--     ★ Selector/Sequence 不需要，因为它们「第 1 个」永远合法。
    if self.status ~= RUNNING then
--★ idx 归 1。
        self.idx = 1
    end

--⚠【疑似缺陷 · 无用局部变量】`local done = false` —— 声明后从未被读取或赋值。
--   ★★ 推理依据：本函数（355-375）内没有任何 `done` 的使用；
--     全文件 `grep -n done behaviourtree.lua` 只命中 361/452/497 三处声明，
--     均为孤立声明。
--   ★★ 影响：无功能危害（Lua 允许未使用的局部），但每帧每个 Selector
--     都会多一次栈分配。Selector 在 brain 里极其常见（DoAction 内部全是它），
--     所以这是一笔真实的、虽然是极小的、无谓开销。
--   ★ 推测成因：这三段代码（Selector/Loop/Random 的 Visit）显然同源，
--     作者先写了带 done 标志的模板（可能是想做「并行收割」语义），
--     后来改成 return 式的短路，done 就成了残留。
--   ★★ 但 LoopNode 与 RandomNode **真的用 while(true) 做循环收割**，
--     只有 Selector 用 while + return 短路 —— 说明 Selector 是被改造过的那一个。
    local done = false
--★ while 而非 for：idx 在循环体内被修改（371 行）。
    while self.idx <= #self.children do

--★ 只 Visit 当前这一个孩子。理由同 325 行。
        local child = self.children[self.idx]
--★ 与 326 行同构：递归的落点。
        child:Visit()
--★★【Selector 的中断条件 —— Sequence:327 的镜像】
--   `if child.status == RUNNING or child.status == SUCCESS then`
--   ★★ 逐个解读：
--     · RUNNING → 「这个正在做，还没轮完」→ 停（保留 idx，继续推进它）
--     · SUCCESS → 「这个行！就用它」→ 停（idx 停在这里，后续分支不再考虑）
--     · FAILED  → 「这个不行，试下一个」→ **继续循环**（idx+1）
--   ★★ 【核心记忆法】
--     Sequence   —— 遇 SUCCESS  继续（还有下一个要做）
--     Selector   —— 遇 FAILED   继续（还有下一个可试）
--     两者的「继续条件」正好是对方的中断条件。
--   ★★ 实践含义：Selector 的 idx 会**停在成功的那个分支上**，
--     只要它不 FAILED，Selector 就永远问它、不会往后走。
--     ★ 这就是「粘性」—— 优先级低的分支一旦赢了就赖着不走，
--       直到高级条件失效。这也是为什么脑根要用 PriorityNode（它会周期性重排）。
        if child.status == RUNNING or child.status == SUCCESS then
--★ 状态直接透传给父节点。Selector 同样不做状态翻译。
            self.status = child.status
--★ return —— 「命中，停在这里」。
            return
        end

--★ 当前分支不行，idx 前进 —— 在**同一次 Visit** 里立刻试下一个。
--   ★★ 与 332 行的对称：一个前进是「做完了」，一个前进是「失败了」。
        self.idx = self.idx + 1
    end

--★★ 所有孩子都 FAILED → 整个 Selector FAILED。
--   ★★ 与 Sequence:335 行（全部 SUCCESS 才 SUCCESS）完全镜像。
--   ★ 走到这一行意味着「所有选项都不成立」——
--     在 PriorityNode 里这会让它去找下一个优先级更高的分支（608 行的循环），
--     最终若整个 Priority 都 FAILED，树就整体 FAILED，
--     下一帧 Step 会把一切 Reset（161 行），brain 重新从头想。
--   ★★ 所以「全 FAILED」不是错误状态，而是「这轮没找到事做」，
--     属于正常的空闲表现。
    self.status = FAILED
end
---------------------------------------------------------------------------------------

--★★【NotDecorator —— 「取反」】
--   ★★ 映射表：
--     孩子 SUCCESS → 自己 FAILED（386 行）
--     孩子 FAILED  → 自己 SUCCESS（388 行）
--     孩子 RUNNING → 自己 RUNNING（390 行，透传）
--   ★★ 【为什么 RUNNING 要透传而不是取反？】
--     「没找到东西」若被 Not 取反成 SUCCESS，
--     就会让父节点以为「事情做完了」，从而跳过后续 —— 完全错误。
--     ★ 所以 RUNNING 必须透传：Not 只反转「已定论」的结果，
--       对「还没定论」保持中立。
--   ★★ 这条规则同样适用于 395 / 411 行的两个 FailIfXxx 装饰器。
--   ★★ 实践价值：WriteConditionNode（如 abigailbrain 里的自定义条件）
--     常常只能表达「找到了/没找到」，用 Not 就能反过来当禁用条件用。
NotDecorator = Class(DecoratorNode, function(self, child)
--★ 名字固定 "Not"，覆盖了 196 行的 "Decorator" 兜底。
    DecoratorNode._ctor(self, "Not", child)
end)

--★★【NotDecorator:Visit —— 纯状态翻译，不含任何自己的判断逻辑】
--   ★★ 全函数就是「问孩子一次，然后反着答」。
--   ★ 注意它是**递归调用** child:Visit() —— 装饰器总是主动问孩子。
--   ★★ 与组合节点的区别：组合节点按 idx 决定问谁，装饰器永远问那唯一的孩子。
function NotDecorator:Visit()
--★ `self.children[1]` —— 恒为构造时传入的那一个孩子（196 行 {child}）。
--   ※ 若构造时传了 nil，children 是空表，这里得 nil → 下行child:Visit() 会崩。
--     框架不校验，由使用方负责。
	local child = self.children[1]
	child:Visit()
--★ 孩子成功 → 我失败。这是「Not」的核心。
	if child.status == SUCCESS then
		self.status = FAILED
--★ 孩子失败 → 我成功。
--   ★★ 这条在实践中最有用：`NotDecorator{ ConditionNode(不该做的条件) }`
--     用来表达「除非…否则…」的禁用语义。
	elseif child.status == FAILED then
		self.status = SUCCESS
--★★ else 分支（含 RUNNING）→ 原样透传。理由见 378 行的说明。
--   ★★ 用 `elseif ... else` 而非 `elseif RUNNING then` 的好处：
--     若孩子未来新增了第四种状态，这里会自动透传而不是静默变 FAILED。
--     ★ 这是很稳的写法 —— 对未知状态保持「不干预」。
	else
		self.status = child.status
	end
end
---------------------------------------------------------------------------------------

--★★【FailIfRunningDecorator —— 「只要还在跑就算失败」】
--   ★★ 语义：孩子 FAILED → 自己 FAILED；孩子 SUCCESS → 自己 SUCCESS；
--     孩子 RUNNING → **自己 FAILED**（而不是透传）。
--   ★★ 【它解决什么问题？】
--     「这件事正在做吗？不要一边做一边做另一件。」
--     典型用法：`FailIfRunningDecorator{ ChaseAndAttack(...) }`
--     —— 如果已经在追击了，这个分支就 FAILED，让位给别的分支。
--   ★★ 与 Not 的关键区别：
--     Not      对 RUNNING 透传（保持中立）
--     FailIfRunning 对 RUNNING 转 FAILED（明确拒绝）
--   ★★ 这就是为什么需要三个装饰器而不是一个带参数的：
--     「中立 / 反转 / 拒绝」是三种不同的需求，合并会引入难读的条件表。
--   ★ 注意 410 行那行英文原注释解释了 FailIfSuccess 的用途，
--     对照 FailIfRunning 的用途可自行类推。
FailIfRunningDecorator = Class(DecoratorNode, function(self, child)
--★ 名字 "FailIfRunning"。
    DecoratorNode._ctor(self, "FailIfRunning", child)
end)

--★★【FailIfRunningDecorator:Visit —— 与 Not:382 结构完全对称】
function FailIfRunningDecorator:Visit()
--★ 与 383 行同构。
	local child = self.children[1]
	child:Visit()
--★★ 本装饰器的全部价值在这一行：RUNNING → FAILED。
--   ★★ 【为什么这个映射有用】
--     在 Selector / Priority 里，FAILED 会让父节点「去看下一个分支」。
--     所以 `FailIfRunningDecorator{ 长行为 }` 的效果是：
--       「只要这个长行为还在跑，就当它不存在，让别的分支有机会」。
--     ★ 这实现了「互斥行为」—— 追击时不会同时去生火。
	if child.status == RUNNING then
		self.status = FAILED
	else
--★ 非 RUNNING 时原样透传（SUCCESS→SUCCESS, FAILED→FAILED）。
--   ★★ 所以这个装饰器**只改 RUNNING 一种状态**，是极窄的干预。
--     这种「只改一种状态」的装饰器比 Not 安全得多，
--     因为它不会把「失败」误判成「成功」。
		self.status = child.status
	end
end
---------------------------------------------------------------------------------------

--★ 原注释（保留）：
--   `-- Useful to make a prioritynode move to the next element whether a child succeeds or fails`
--   翻译：「用来让 PriorityNode 无论孩子成功还是失败都跳到下一个元素。」
--   ★★ 这句话精准说明了 FailIfSuccess 在 Priority 里的角色：
--     Priority 遇到 SUCCESS 会停（选中了），遇到 FAILED 会继续（试下一个）。
--     所以一个「孩子失败也算失败、成功也算失败」的节点，
--     会让 Priority 无条件前进到下一个分支。
--   ★★ 实际用途：放一个「纯副作用、结果无关」的节点在 Priority 列表里，
--     保证它执行完不会挡住后面的高价值分支。
--     ★ 语义上它就是 Priority 的「不占用选择权的一次性动作」。
-- Useful to make a prioritynode move to the next element whether a child succeeds or fails
--★★【FailIfSuccessDecorator —— 「成功也算失败」】
--   映射：孩子 SUCCESS → 自己 FAILED（419 行）；其余原样透传。
--   ★★ 与 FailIfRunning 恰好互补：
--     FailIfRunning  ：RUNNING  → FAILED（拒绝「正在做的」）
--     FailIfSuccess  ：SUCCESS  → FAILED（不承认「已完成的」）
--   ★★ 两者合起来可以写出一个「完全不关心结果」的节点类型，
--     常用于「执行一个必定成功的小动作，然后让位」。
--   ★★ 注意 FAILED 的孩子仍透传为 FAILED，RUNNING 也透传为 RUNNING。
--     ※ 所以它**不是**「无条件 FAILED」—— RUNNING 时它还是 RUNNING。
--       这与 410 行注释描述的「无论成功失败都前进」略有出入：
--       孩子 RUNNING 时本装饰器会停住 Priority，不会前进。
--       ※ 这是原注释与代码之间的一处**语义落差**，排查时需注意。
FailIfSuccessDecorator = Class(DecoratorNode, function(self, child)
--★ 名字 "FailIfSuccess"。
    DecoratorNode._ctor(self, "FailIfSuccess", child)
end)

--★★ 与 Not:382 / FailIfRunning:399 结构对称。
function FailIfSuccessDecorator:Visit()
--★ 与 400 行同构。
	local child = self.children[1]
	child:Visit()
--★ 本装饰器的全部价值：SUCCESS → FAILED。
	if child.status == SUCCESS then
		self.status = FAILED
	else
--★ 其余状态（FAILED / RUNNING）原样透传。※ 见 412 行的语义落差说明。
		self.status = child.status
	end
end
---------------------------------------------------------------------------------------


--★★【LoopNode —— 「把一段序列重复执行 N 次（或无限次）」】
--   ★★ 它的 Visit（445-480 行）与 SequenceNode:319 几乎一样，
--     只在收尾处多了一步：**把 idx 拨回 1 并重置所有孩子**（468-479 行）。
--   ★★ 【所以 Loop = Sequence + 「跑完从头再来」】
--     这个复用是通过「相同的 Visit 前半段 + 不同的收尾」实现的，
--     而不是继承 —— 见 427 行它直接继承 BehaviourNode 而非 SequenceNode。
--   ★★ 【为什么 maxreps 是可选的？】
--     471 行 `if self.maxreps and self.rep >= self.maxreps` ——
--       · 传了 maxreps → 重复到次数为止，然后 SUCCESS（**有界循环**）
--       · 没传 → **无限循环**，永远 RUNNING，永远 SUCCESS 不返回
--     ★★ 无限循环是 LoopNode 的主要用法：
--       braincommon.lua:435 `LoopNode{..., ChattyNode(...)}` —— 一直说话；
--       pigelitebrain.lua:251 `LoopNode{ ActionNode(...) }` —— 一直推事件。
--       ★ 这解释了为什么 ChattyNode 这类「需要持续做」的行为要用 Loop 包。
--   ★★ maxreps 的语义细节（471 行）：
--     `self.rep >= self.maxreps` 在**跑完第 maxreps 轮之后**判定。
--     所以 maxreps = 3 → 实际执行 3 轮（rep 从 0 递增三次后到 3）。
--     ★ 「轮」= 把所有孩子从头走一遍，不是「单个孩子执行三次」。
LoopNode = Class(BehaviourNode, function(self, children, maxreps)
--⚠【疑似缺陷 · 文案错误】name 硬编码为 **"Sequence"**，应为 "Loop"。
--   ★★ 推理依据：
--     本行所在类明确是 LoopNode（427 行），但传给基类的名字是 "Sequence"。
--     对比 305 行 SequenceNode 也传 "Sequence" —— 两处完全相同。
--     ★ 这是复制粘贴时漏改的字符串。
--   ★★ 后果：调试输出（GetString:145）里 LoopNode 显示为 `Sequence`，
--     与真正的 SequenceNode **无法区分**。
--     ★★ 实操影响不小：LoopNode 是 brain 里高频节点（braincommon、houndbrain、
--       dragonflybrain、oceanfishbrain 等大量使用），
--       排查「某个 Sequence 卡住了」时无法确认它到底是哪个。
--   ★★ 唯一可用的区分手段是 DBString（434 行输出 idx），
--     但它与 SequenceNode:310 的输出完全相同，无法进一步区分。
--   ※ 修复成本极低（改一个字符串），但会影响历史调试记录的对照性；
--     且若有模组按 name 做字符串匹配（`node.name == "Loop"`），
--     修正反而会让它们失效 —— 这类隐式契约是 DST 里的常见陷阱。
    BehaviourNode._ctor(self, "Sequence", children)
--★ idx = 1 —— 与 Sequence 同构。
    self.idx = 1
--★★ maxreps 为 nil 表示无限循环（见 471 行的双重条件）。
    self.maxreps = maxreps
--★★ rep = 0 —— 「已重复了几轮」。与 idx 是两套独立的进度。
--   ★★ idx  = 「这一轮走到第几个孩子」
--     rep  = 「已经完成了几轮」
--   ★ 为什么要分开？因为一轮可能没走完（某孩子 RUNNING），
--     此时 rep 不能加。只有整轮走完（跑到 468 行）才 rep+1。
--   ★ rep 在 447-450 行被归零：不是 RUNNING 时视为「新一轮循环开始」。
    self.rep = 0
end)

--★ DBString 输出 idx —— 与 SequenceNode:309 完全相同。
--   ★★ 这是 428 行 ※ 的连带后果：name 与 DBString 都无法区分 Loop 与 Sequence，
--     调试时只能靠「它在 Priority 里的位置」与行为特征（会回到 idx=1）来推断。
function LoopNode:DBString()
    return tostring(self.idx)
end


--★★【LoopNode:Reset —— 归位 idx 与 rep 两个游标】
--   ★★ 对比 Sequence:314 只归 idx，Loop 多归一个 rep。
--   ★★ 470 行的 rep+1 与本行的 rep=0 是一对：
--     「跑完一轮 → rep+1（除非次数用尽）」
--     「被 Reset → rep=0（循环从头开始）」
--   ★★ 注意 rep=0 的时机（447 行）：非 RUNNING 时也归零，
--     与 idx 归零的时机完全一致。
function LoopNode:Reset()
--★ 显式父类调用。
    self._base.Reset(self)
--★ idx 归 1。
    self.idx = 1
--★ rep 归 0 —— 「新一轮循环」。
    self.rep = 0
end

--★★【LoopNode:Visit —— Sequence 的复制品 + 循环收尾】
--   ★★ 前半段（447-466）与 SequenceNode:319-336 逐行同构，
--     中断条件也一样是 RUNNING 或 FAILED（457 行）。
--   ★★ 唯一的差别在收尾：
--     Sequence 跑到边界 → SUCCESS（335 行）
--     Loop     跑到边界 → idx 拨回 1 + rep+1 + 重置所有孩子（468-479 行）
function LoopNode:Visit()

--★ 与 320 行同构：非 RUNNING 视为新一轮，idx 与 rep 双双归零。
--   ★★ 为什么 rep 也要在这里归零（而不是只在 Reset 里）？
--     因为 Step（161 行）已经在这轮结束时把非 RUNNING 的节点 Reset 了，
--     本行的 447 分支实际上**很少被走到** —— 它是双保险。
--     ★ 与 320/321 行的双保险结构完全一致。
    if self.status ~= RUNNING then
        self.idx = 1
        self.rep = 0
    end

--⚠【疑似缺陷 · 无用局部变量】`local done = false` —— 见 361 行的完整分析。
--   ★★ 但**这里的情况与 Selector 不同**：Loop 真的在做循环收割，
--     作者原本可能想用 done 表达「一轮已走完」，
--     最后改用了「while 条件失效 = 走到边界」这个更简洁的判断（468 行）。
--     ★ 三处 `local done`（361/452/497）说明这三段代码同源，
--       而只有 Loop 与 Random 真的进入了「循环收割」的写法。
    local done = false
--★ while 而非 for：idx 在循环体内被修改（465 行）。
    while self.idx <= #self.children do

--★ 与 364 行同构。
        local child = self.children[self.idx]
--★ 与 365 行同构：递归 Visit 当前孩子。
        child:Visit()
--★★ 中断条件与 Sequence:327 完全一致：`RUNNING or FAILED`。
--   ★★ 【Loop 的关键行为由此确定】
--     · 孩子 FAILED → **整个 Loop FAILED**（461 行透传），不进入下一轮。
--       ★★ 这意味着 Loop 内部**不能容忍任何失败**：
--         序列里有一个分支不成立，整轮循环就结束。
--         所以 LoopNode 内部通常要放 `FailIfSuccessDecorator`（410 行注释所述）
--         或用 WhileNode 包住条件。
--     · 孩子 RUNNING → 停在当前 idx，等它做完。
--   ★★ 与「容错型循环」的直觉相反：这里是「一次失败即退出」。
--     设计上是自洽的：既然是「依次做完全部」，中途失败就该报告失败。
        if child.status == RUNNING or child.status == FAILED then
--★ `if child.status == FAILED then` —— 只为取一个空的注释块。
            if child.status == FAILED then
--※【被注释掉的调试打印】`--print("EXIT LOOP ON FAIL")`
--   ★ 位置在 457-460 的 if 内部，说明它只会在「因失败而退出」时打印。
--   ★★ 这是排查「Loop 为什么停了」的直接线索 —— 取消注释即可看到。
--   ★ 与 712/714/722 行 EventNode 的三处注释打印同属一类：
--     作者用注释掉的 print 留下了关键观察点。
                --print("EXIT LOOP ON FAIL")
            end
--★ 状态透传（RUNNING 或 FAILED 都直接向上传递）。与 328 行同构。
            self.status = child.status
            return
        end

--★ 当前孩子成功，idx 前进。
        self.idx = self.idx + 1
    end

--★★【循环收尾 —— LoopNode 的灵魂，全部 5 行都在这】
--   ★★ 「一轮走完」被翻译成「idx 拨回 1」。这一行是循环的起点动作。
--   ★★ 为什么用「拨回 idx」而不是「从头重新调用 Visit」？
--     因为 Visit 是递归的，不能重入。用 idx 归零来表达「下一轮从第一个开始」，
--     就复用了同一套 while 循环代码，无需第二份逻辑。
--   ★★ 这一行 + 470 行 + 475-477 行合起来构成一个完整的循环体。
    self.idx = 1

--★★ rep+1 —— 「完成一轮」。
--   ★★ 只有走到 468 行（所有孩子都 SUCCESS）才会执行到这里。
--     任何一轮里出现 FAILED 都在 457 行提前 return 了，rep 不会增加。
--     ★★ 所以 rep 精确等于「成功完成了几轮」，语义很干净。
    self.rep = self.rep + 1
--★★【有界 / 无界循环的分岔点】
--   `if self.maxreps and self.rep >= self.maxreps then`
--   ★ 三重判断：
--     ① self.maxreps 非 nil —— 「调用方要求有界」
--     ② rep >= maxreps —— 「已经够了」
--     ★★ 【⚠ 疑似缺陷 · 次数语义偏一】
--     maxreps = 3 的执行过程：
--       第 1 轮走完 → rep=1 → 1>=3? 否 → 重置孩子
--       第 2 轮走完 → rep=2 → 2>=3? 否 → 重置孩子
--       第 3 轮走完 → rep=3 → 3>=3? 是 → SUCCESS
--     ★ 结果是**恰好执行 3 轮**，符合直觉。这一点没有 bug。
--     ※ 真正值得注意的是：maxreps = 1 时执行 **1 轮**（不是 0 轮），
--       即 maxreps 是「最少执行次数」而非「最多」。
--       换句话说它**不是**一个上界，而是「达到就停」的阈值。
--       ★ 命名 `maxreps` 略具误导性，叫 `nreps` 或 `repcount` 更准确。
--       ★ 由于它是「>=」且在 rep 自增之后判断，实际上界是精确的，
--         所以只有命名问题，没有行为缺陷。
    if self.maxreps and self.rep >= self.maxreps then
        --print("DONE LOOP")
--★ 次数用尽 → SUCCESS。
--   ★★ 注意是 SUCCESS 而不是「继续外层序列」——
--     对父节点（Sequence/Selector）而言，Loop 的任务是「跑完 N 轮」，
--     跑完了就该报告成功。至于「跑完后干什么」由父节点决定。
        self.status = SUCCESS
    else
--★★【无限循环的关键：手动重置所有孩子】
--   ★★ 为什么这里要显式 `v:Reset()` 而不能指望 Step？
--     因为本节点**没有立刻返回** —— 它要在同一次 Visit 里进入下一轮。
--     而 Step（161 行）要等到**整个思考周期结束**才会执行。
--     ★★ 若不在这里重置，下一轮会看到孩子的 status 还是 SUCCESS，
--       于是 457 行的判断里 SUCCESS 不中断，idx 会一路冲到底 ——
--       实际效果是「一轮里把所有孩子跑 N 次」，而不是「N 轮」。
--     ★★ 所以这一行是 LoopNode 能正确循环的**必要条件**，删掉它 Loop 就坏了。
--   ★★ 注意 Reset 有基类守卫（171 行）：已 READY 的孩子跳过，
--     所以重置成本与「上一轮真正跑过多少个孩子」成正比。
        for k,v in ipairs(self.children) do
--★ 用 ipairs 全量重置 —— 不是「从 idx 开始」，因为 idx 已被拨回 1。
            v:Reset()
        end
--★ else 分支是空的 —— 「还没跑够，继续留在本节点，下一轮再来」。
--   ★★ 【无限 Loop 的休眠语义 —— 一个重要推论】
--     本函数走完 else 分支后**不设置 status**，
--     于是 self.status 保持进入时循环最后一次赋的值 ——
--     实际上 457-463 行每次 return 都会设 status；
--     而走到 478 行时 status 是「最后一个孩子 SUCCESS 前」的值……
--     ★★ 更准确地说：走到 475 行说明所有孩子都是 SUCCESS，
--       但本函数**从未把 status 设为 SUCCESS**（对比 Sequence:335 行）。
--       status 此时取决于上一轮的痕迹：
--         · 若上轮在 461 行 return 过 RUNNING，status 是 RUNNING
--         · 若本轮是第一次进来，status 是 READY（构造初值）
--     ★★ 这个「status 不被显式设置」的行为有两个后果：
--       ① 无限 Loop 的节点可能是 READY 而不是 RUNNING ——
--          于是 Step（161 行）会 Reset 它（READY != RUNNING），
--          下一轮 idx 又被归零，等于「每帧重新开始一轮循环」。
--          ★ 在实践里这通常**正是想要的效果**（每帧推进一步），
--            但它意味着 rep 永远到不了 maxreps（除非单轮内有 RUNNING 节点）。
--       ② 若某轮里最后一个孩子是 RUNNING，461 行把 status 设成 RUNNING，
--          Step 就不会 Reset 整个 Loop，idx 被保留 —— 循环得以跨帧连续推进。
--     ★★ 结论：LoopNode 的「跨帧连续性」完全依赖于
--       「本轮是否出现过 RUNNING」。这是一个**隐式契约**，很容易误解。
--       对比 Sequence:335 显式设 SUCCESS 的做法，这里少了一次显式赋值。
--   ※ 这不算 bug（有可观察的合理行为），但它是本文件里
--     「不写 status 就继承上一状态」这一隐患最明显的一处。
--     ★★ 对比 161 行 Step 与 172 行 Reset 的守卫都只看 status，
--       可知「status 未被赋值」会被当作「没在跑」处理 —— 语义是一致的，只是意外。

    end
end

---------------------------------------------------------------------------------------

--★★【RandomNode —— 「随机挑一个能成的来跑」】
--   ★★ 与 Selector 的核心差异：**下一轮换一个起点**。
--     Selector：永远从 idx=1 开始试（340 行），顺序固定。
--     Random  ：每次 Reset 后从**随机位置**开始（501 行），
--              且沿环遍历（512-515 行）直到找到一个非 FAILED 的。
--   ★★ 【为什么需要它？消除位置偏置】
--     若用 Selector 且第一个分支经常成立，排在后面的分支永远轮不到。
--     ★ 典型场景：一群蜜蜂都在采蜜，用 Selector 会让「第二个花丛」永远无人问津。
--     Random 让每个分支都有机会成为首选，群体行为更自然。
--   ★★ 【关键性质：选中的那个会被「粘住」】
--     499 行只在 `self.status == READY` 时才重选，
--     所以一旦选中并 RUNNING，后续所有轮次都 Visit 同一个孩子（523-527 行）。
--     ★★ 这与 Selector 的「粘性」类似，但起点是随机的。
--   ★★ 典型用法：见 oceanfishbrain.lua:210 的 ParallelNodeAny 组合，
--     以及 braincommon.lua 里多处 RandomNode 的群聚行为。
RandomNode = Class(BehaviourNode, function(self, children)
--★ name 硬编码 "Random"。
    BehaviourNode._ctor(self, "Random", children)
end)


--★★【RandomNode:Reset —— 把 idx 设成 nil 而不是 1】
--   ★★ 这是 Random 与 Sequence / Selector 最直观的代码差异：
--     Sequence:316  `self.idx = 1`   （下次从头）
--     Priority:579  `self.idx = nil` （下次重选）
--     Random:491    `self.idx = nil` （下次重选）
--   ★★ 【为什么 Random 要用 nil？】
--     因为 499 行的判断是 `if self.status == READY then` ——
--     它不看 idx 是否为 nil，而是看 status。
--     idx = nil 的作用是**防止 else 分支（524 行）拿到一个陈旧的 idx**：
--     若 idx 残留旧值而 status 又变成 RUNNING，就会 Visit 一个不相关的孩子。
--   ★★ 所以 nil 在这里的作用是「无选择」的安全标记，与 Priority 的用法一致。
--   ★ 三种写法对比（Sequence/Selector=1, Random/Priority=nil）说明：
--     「idx = 1」表示「有序列表的游标」，「idx = nil」表示「未选择的指针」。
function RandomNode:Reset()
--★ 显式父类调用。注意与 RandomNode 无 Sequence 的继承关系无关。
    self._base.Reset(self)
--★ idx = nil —— 「下次重新随机挑」。见 489 行详解。
    self.idx = nil
end


--★★【RandomNode:Visit —— 两条路径：重选 / 续跑】
--   ★★ 整体结构：
--     ① status == READY → 进入「随机起点 + 环遍历搜索」
--     ② 否则          → 只 Visit 已选中的那个孩子
--   ★★ 这是本文件里**唯一用 while(true) + 环回绕**做选择的节点，
--     也是唯一会「一次尝试多个孩子直到找到能成的」的地方。
function RandomNode:Visit()

--⚠【疑似缺陷 · 无用局部变量】`local done = false` —— 见 361 行的完整分析。
--   ★★ 与 Loop:452 同为「本段确实在循环，但没用 done 标志」。
--     推测这三个节点（Selector/Loop/Random）的 Visit 出自同一份草稿。
    local done = false

--★★【重选路径的触发条件 —— 粘性机制的落点】
--   `if self.status == READY then`
--   ★★ 为什么看 status 而不是看 idx？
--     因为 status == READY 精确表达了「上一轮没在跑，且已被 Step 复位」，
--     此时该重新决定做哪一件。
--     ★★ 与 Sequence:320 用的是同一个判据（`status ~= RUNNING`），
--       但语义相反：Sequence 是「不是 RUNNING 就从头」，
--       Random 是「是 READY 就重选」—— 后者对「FAILED」状态另有处理
--       （FAILED 节点会被 Step Reset 成 READY，下一轮自然重选）。
--   ★★ 三种状态进入 Random 的行为：
--     READY   → 重选（499 行）
--     RUNNING → 续跑已选中的（523 行）
--     SUCCESS/FAILED → 什么都不做（直接结束）
--       ★ 因为 Step（161 行）会在本轮末把它们 Reset 成 READY，
--         所以「什么都不做」是安全的 —— 下一轮自然是 READY。
    if self.status == READY then
        --pick a new child
--★★【随机起点：`math.random(#self.children)`】
--   ★★ 返回 1..N 的均匀随机整数，作为环遍历的起点。
--   ★★ 【为什么是「随机起点 + 顺序环遍历」而不是「随机洗牌」？】
--     因为一次只会选中**一个**孩子（除非全部 FAILED），
--     所以「顺序」只在「前几个恰好都 FAILED」时才有意义。
--     ★ 最坏情况：需要试 N 个才能找到一个非 FAILED 的，
--       期望 (N+1)/2 次。这是可接受的。
--   ※ 但如果**所有**孩子都 FAILED，会白跑 N 次 child:Visit（503-521 行）。
--     ★ 在每帧一次的调度频率下，若大量生物处于「所有分支都不成立」，
--       这会形成可观测的 CPU 尖峰。这是 Random 的固有代价。
--     ★★ 缓解手段：这也是 RandomNode 不适合做脑根的原因之一
--       —— 脑根用 PriorityNode（见 p4），它有 found 标志做短路（601 行）。
        self.idx = math.random(#self.children)
--★ start = 记住起点，用于检测「是否已绕回原点」（517 行）。
--   ★★ 这是环遍历的标准终止条件：转到起点就说明全试过一遍了。
--   ★★ 若没有 start 就无法判断「是否试完了」，会无限循环。
        local start = self.idx
--★★【while(true) —— 环遍历搜索】
--   ★★ 三种退出路径：
--     ① 507 行：孩子非 FAILED → 采纳并 return（509 行）
--     ② 513-515 行：越过末尾 → idx 绕回 1
--     ③ 517-520 行：绕回起点 → 全部 FAILED，返回 FAILED
--   ★★ 「非 FAILED」= SUCCESS 或 RUNNING，两者都算采纳。
--     ★ RUNNING 也被采纳的理由：它意味着「这件事能做下去」，
--       与 Sequence/Selector 的处理一致。
        while true do
--★ 取当前候选孩子。注意这是**试探**：可能白跑一趟。
            local child = self.children[self.idx]
--★★ 试探性 Visit —— 即使最后不采纳，这次执行已经产生了副作用。
--   ★★ ※ 这是一个值得注意的行为：
--     ActionNode:264 的副作用是**立即执行**的，不可回滚。
--     所以「随机选一个」实际上可能先执行掉一个不打算采纳的动作。
--   ★★ 实践中 RandomNode 内部几乎只放**纯判定类节点**
--     （ConditionNode / Leash / FindClosest 这类），
--     它们的 Visit 无副作用，所以试探无害。
--   ★★ 规则总结：**RandomNode 的孩子应当无副作用**，否则会出现「误执行」。
            child:Visit()

--★★ `if child.status ~= FAILED then` —— 「非 FAILED 即采纳」。
--   ★★ SUCCESS 与 RUNNING 都采纳，与 Sequence:327 的中断条件互为镜像。
--   ※ 注意这里用的是 `~=` 而非 `== SUCCESS or == RUNNING`，
--     所以若孩子返回了第四种状态（若有），也会被采纳。
--     ★ 与 NotDecorator:389 的「else 透传」是同一种防御风格。
            if child.status ~= FAILED then
--★ 采纳孩子的状态（SUCCESS 或 RUNNING）作为自己的状态。
                self.status = child.status
--★★ return —— 「选定了，就用它」。idx 已指向它。
--   ★★ 与 Selector:368 的 return 语义完全一致，只是搜索方式不同。
                return
            end

--★ 前进到下一个候选。
            self.idx = self.idx + 1
--★ 越过末尾判断 —— 为后面的绕回做准备。
            if self.idx > #self.children then
--★★ 环回绕：idx = 1。配合 501 行的随机起点，实现「循环选取」。
--   ★★ 注意这里不是直接 return FAILED，而是**继续 while** ——
--     因为可能绕回 1 时正好遇到一个能成的。
--   ★★ 与 517 行的区别：514 行是「修正越界」，517 行是「确认试完了」。
                self.idx = 1
--★ 空行结束，注意 514 行是它上一句的续行。
            end

--★★【终止条件：绕回起点 → 全部 FAILED】
--   `if self.idx == start then`
--   ★★ 为什么用 `==` 而不是 `>=`？因为 513-515 行保证了 idx 始终在 1..N，
--     用相等比较就能检测「回到了出发位置」，逻辑上更准确。
--   ★★ 这里没有 break 而是 `self.status = FAILED; return`（518-519 行），
--     与其余分支的 return 风格统一。
            if self.idx == start then
--★ 全部候选都 FAILED → 自己 FAILED。
--   ★★ 与 Sequence:374 / Selector:374 的语义一致：「所有选项都不成立」。
                self.status = FAILED
                return
            end
        end

--★★【续跑路径 —— 「不是 READY 就只问已选中的那个」】
--   ★★ 【本文件里最值得学的一段「廉价粘性」】
--     续跑时**不遍历任何兄弟节点**，只 Visit `self.children[self.idx]`。
--   ★★ 性能收益：O(1) 而非 O(N)。
--     选中之后每帧只花一次 Visit，与只有 1 个孩子的节点开销相同。
--   ★★ 正确性：依赖 491 行 Reset 时的 `self.idx = nil` ——
--     保证「非 READY 时 idx 一定有效」。见 489 行的详解。
--   ★★ 【与 PriorityNode 的对照（见 p4）】
--     Priority 在「未到 period 时」的分支（625-636 行）也是这种 O(1) 续跑，
--     但 Priority 额外做了「只 Visit 赢家」的判断（628 行），
--     因为它可能同时存在多个 RUNNING 的孩子。
--   ★★ 由此引出一条实用规则：**RandomNode / PriorityNode 只在「选定」后才是廉价的**，
--     选定之前（Random:499 / Priority:598）仍然是全量遍历。
    else
--★ 直接索引 —— ※ 若 idx 为 nil 且 status 不是 READY，这里会崩。
--   ★★ 但这个状态不可达：idx 只在 501 行被赋值，
--     而赋值前必然走 499 的 READY 分支；赋值后若变 RUNNING 才走这里。
--     Reset 时 idx 归 nil 而 status 归 READY（172 行），两者同步。
--     ★ 所以这是一个由「status 与 idx 同步维护」保证的不变量。
--   ※ 自定义节点若破坏这个不变量（如单独改 status 不改 idx），就会崩。
        local child = self.children[self.idx]
--★ 递归 Visit 选中的孩子。
        child:Visit()
--★★ 状态直接透传 —— 与 Random 的「搜索」角色无关，
--     续跑时它只是个透明的转发器。
--   ★★ 所以 RandomNode 的「智能」全部在 495-521 的选择阶段，
--     执行阶段（523-527）退化为一个单子节点容器。
        self.status = child.status
    end

end

---------------------------------------------------------------------------------------

--★★【PriorityNode —— 带优先级、周期重排与抢占的组合节点】
--   ★★ 【它是 DST 所有脑的根节点类型】
--     核实：brains/rabbitbrain.lua:52、brains/abigailbrain.lua:252、
--     brains/alterguardian_phase1brain.lua:52 等全部以 PriorityNode 为根。
--     ★ 为什么必须是它？四个能力，其他组合节点都不具备：
--       ① **周期性重排**（period）：不是「赢家一直赖着」，而是每 period 秒重挑
--       ② **抢占**（preemption）：高优先级分支可踢掉正在跑的低优先级分支
--       ③ **事件唤醒**（lasttime = nil）：事件能强制立即重排（见 734 行）
--       ④ **成本节流**（GetSleepTime：541 行）：空闲时不消耗 CPU
--   ★★ 与 Selector 的本质差异：
--     Selector  → idx 一旦停在成功分支就**永不重排**（374 行）
--     Priority  → 每 period 秒**从头重挑**（598 行是全量 for 循环）
--     ★★ 这正是「粘性」与「可抢占」的区别，也是为什么脑根不能用 Selector。
--   ★★ 四个参数的含义：
--     children  —— 有序列表，**靠前的优先级高**（598 行 ipairs 顺序遍历）
--     period    —— 重排周期（秒）。nil 时默认 1（535 行）
--     noscatter —— true 时不随机化初始 lasttime（537 行）
--   ★★ period 的典型值：rabbitbrain 用 0.25 秒（rabbitbrain.lua:65）。
--     ★ 值越小反应越快但 CPU 越贵；值越大越省但迟钝。
--   ★★ noscatter 的意义见 537 行详解 —— 它是一个**反惊群**设计。
PriorityNode = Class(BehaviourNode, function(self, children, period, noscatter)
--★ name 硬编码 "Priority"。
    BehaviourNode._ctor(self, "Priority", children)
--★★ `self.period = period or 1` —— 默认重排周期 1 秒。
--   ★★ 注意这行让 `not self.period` 的检查（544 行）在**构造后永远为假**，
--     所以 544-546 行是死代码（详见该行的 ※）。
    self.period = period or 1
--★★【noscatter：反「惊群」的抖动分散 —— 一个很聪明的细节】
--   `if not noscatter then self.lasttime = self.period * 0.5 + (self.period * math.random()) end`
--   ★★ 翻译成人话：「把初始 lasttime 随机设在 [0.5×period, 1.5×period) 之间」。
--   ★★ 【它解决什么问题？】
--     585 行的 do_eval 判据是 `self.lasttime + self.period < time`。
--     ★ 若所有实体的 lasttime 都相同（如都是 0），
--       它们会在**同一帧**同时触发 do_eval，
--       瞬间遍历整棵树 → 大规模 AI 时产生明显的帧率尖峰（惊群 / thundering herd）。
--   ★★ 随机化 lasttime 后，每个实体的重排时刻被打散到 1 个周期的窗口里，
--     于是重排被**均匀摊平到时间轴上**，CPU 曲线变平滑。
--   ★★ 这与 GameNetworking 里的「兴趣管理」、
--     服务端的「定时任务抖动化（jitter）」是完全同构的手法。
--   ★ 但要注意：lasttime 是**绝对时间**（GetTime() 的值），
--     而这里赋的是 `period * 0.5 + period * random()`（一个相对小值）。
--     ★★ 这意味着游戏刚开局（GetTime() 还很小）时，
--       这些实体会**立刻**触发第一次重排（因为 lasttime + period < time 很快为真）；
--       随着游戏进行，窗口会逐渐被填满。
--     ★ 严格说这更像是「开局立即评估一次 + 之后逐步分散」，
--       而不是「完全均匀分散」。但效果上确实起到了抖动作用。
    if not noscatter then
--★ `self.period * 0.5 + (self.period * math.random())`：math.random() 无参返回 [0,1)，
--   所以范围是 [0.5p, 1.5p)。空的一对括号是笔误，语义无影响。
        self.lasttime = self.period * 0.5 + (self.period * math.random())
    end
end)

--★★【PriorityNode:GetSleepTime —— 节点级休眠协议的三种返回】
--   它**完全覆写**了基类的 101 行实现，理由是 Priority 有自己的时间概念（period）。
--   ★★ 四个分支的语义：
--     ① status == RUNNING → 返回「距下次重排还有多久」（0 意味着马上）
--     ② status == READY   → 返回 0（★ 关键：见下方详解）
--     ③ 其他（SUCCESS/FAILED）→ 返回 nil（「我不表态」）
--   ★★ 【分支②是本方法最重要的设计，决定了空闲脑的 CPU 成本】
--     READY 的 Priority **返回 0**，也就是「下一 tick 立刻再来」。
--     ★★ 结合 161 行的 Step：每轮思考结束时，非 RUNNING 的 Priority 被 Reset
--       成 READY，于是下一轮 GetSleepTime 就返回 0 → brain 不睡 → 下 tick 继续。
--     ★★ 那岂不是说 PriorityNode 永远不让 brain 睡？——是的！
--       ★★ 这是本文件一个**极其重要且反直觉**的事实：
--         「用了 PriorityNode 做根的脑，永远处于 updaters 队列中，每帧被调度。」
--       它靠的不是「大脑休眠」，而是**树内部的廉价空转**。
--     ★★ 为什么这样仍然划算？因为一轮「什么都不能做」的 Update 极便宜：
--       585 行 do_eval 为假 → 走 625-636 行的 else 分支 →
--       只有 self.idx 指向的孩子会被 Visit，其余全部跳过。
--       ★ 真正的成本集中在「有东西在跑」的时候（Leash 查距离、Panic 换方向）。
--     ★★ 推论与对比：
--       · PriorityNode 根 → 每帧被调度，但内部 O(1) 空转（节流靠 period）
--       · 非 Priority 根且无 RUNNING 节点 → GetTreeSleepTime 返回 nil → Hibernate
--         （节流靠休眠）
--       ★★ 所以「事件驱动」在本框架里的含义有两层：
--         ① 事件能**强制**打破 period 节流（734 行）
--         ② 事件能**唤醒**一个已 Hibernate 的脑（brain.lua:175）
--       而对于 PriorityNode 根的脑，只有第①层起作用。
--       ※ 因此 priority 树的 period 才是真正的 CPU 旋钮。
--   ★★ 【分支①的语义与 107-108 行的钳位】
--     RUNNING 时返回「距下次重排的时间」。注意有两个让它是 0 的情况：
--       · 552-554 行：lasttime + period 已经过期 → 钳成 0（**马上要重排**）
--       · 550 行的 lasttime 为 nil → 保持 0
--     ★★ 所以 do_eval 为真时（该重排了），GetSleepTime 就是 0，
--       brain 立刻进入下一 tick 的 Update → 重排真正发生。
--     ★★ 也就是说：**「period 到期」不是靠定时器实现的，而是靠返回 0 实现的**。
--       没有任何外部定时器参与，整个节流是靠 brain 的休眠队列 + 返回值表达的。
--       这是一个非常巧妙的纯返回值式调度。
function PriorityNode:GetSleepTime()
--★ 只有 RUNNING 才计算重排倒计时 —— 已完成的节点不占节流预算。
    if self.status == RUNNING then

--⚠【疑似缺陷 · 死代码】`if not self.period then return 0 end`
--   ★★ 推理依据：535 行 `self.period = period or 1` 保证 period **永远非 nil**，
--     所以这个分支在任何构造路径下都进不去。
--   ★★ 同样的死代码在 585 行也有一份：`not self.period or`（见该行 ※）。
--   ★ 推测成因：早期版本允许 `period = false` 或不传（nil），
--     后来改成 `or 1` 兜底，但没删掉防御检查。
--   ★ 影响：无。防御性代码保留也不算错，只是徒增阅读负担。
--   ★★ 但它揭示了一个隐患：`period` 是**构造期一次性求值**的，
--     模组若想在运行期调整重排频率，只能直接写 `self.bt.root.period = x`，
--     而这个死分支会让人误以为「period 可以为 nil 表示特殊模式」。
        if not self.period then
            return 0
        end


--★★ time_to 初值 0 —— 「默认马上要醒」。
--   ★★ 这个默认值是**故意且关键**的：
--     550 行只在 lasttime 存在时才计算真实剩余时间；
--     若 lasttime 为 nil（例如刚被 EventNode:734 清成 nil），
--     返回 0 就意味着「立即重排」—— 正是事件唤醒所求的效果。
--   ★★ 所以 lasttime = nil 构成了一个「立刻执行」的信号。
        local time_to = 0
--★★ 只有 lasttime 存在才计算。它为 nil 时（事件刚触发）保持 0。
--   ★ 三种 lasttime 为 nil 的场景：
--     · noscatter = true 构造（536-538 行不赋值）
--     · EventNode:734 的 DoToParents 清空（事件唤醒）
--     · 632 行「分支跑完不再 RUNNING 时」主动清空
        if self.lasttime then
--★ 剩余时间 = 上次重排时刻 + 周期 - 当前时刻。
            time_to = self.lasttime + self.period - GetTime()
--★ 钳成 0 —— 「已到期，该重排了」。配合 585 行的 do_eval，两者互为因果。
            if time_to < 0 then
                time_to = 0
            end
        end

--★★ 返回剩余秒数。上界是 period（0 除外）。
--   ★ 实践中 brain.lua:144 会把它换算成 tick 数排队休眠。
        return time_to
--★★【分支②：READY → 返回 0 —— 空闲脑的 CPU 命运就在这一行】
--   ★★ 详见 541 行的完整分析。此处只强调结论：
--     「PriorityNode 一旦被 Reset 成 READY，就宣称『我下一 tick 还要被问』」。
--   ★★ 与 371 行 Selector 的 FAILED 收尾对比：
--     Selector 全部 FAILED → 374 行 status=FAILED → GetSleepTime 返回 nil
--       → 逐层上抛 → brain Hibernate（**真正的零开销**）
--     Priority 全部 FAILED → 622 行 status=FAILED → 但下一轮 Step 会 Reset 成 READY
--       → 559 行返回 0 → **永远醒着**
--   ★★ 所以「Priority 更耗 CPU」这个直觉，根因就在这里。
--     它的补偿是 period 节流（重排之间便宜）与 GetTreeSleepTime 的子树逻辑。
    elseif self.status == READY then
--★ 返回 0 —— 「下一 tick 继续」。
        return 0
    end

--★ SUCCESS / FAILED → nil（「我不表态」）。
--   ★★ 注意这里是 nil 而非 0，与 559 行的 0 形成鲜明对比。
--     推论：若一棵 Priority 树的根是 Priority 且当前是 FAILED，
--     则 GetTreeSleepTime 得到 nil → brain Hibernate → 只能被事件唤醒。
--     ★ 但由于 161 行的 Step 会立刻把它 Reset 成 READY，
--       实际调用 GetSleepTime 时它几乎总是 READY（→ 0）。
--     ★ 所以「Priority 根的脑会 Hibernate」在实践中几乎不会发生。
    return nil

end


--★★【PriorityNode:DBString —— 排查「AI 卡住」的第一现场】
--   输出形如：`execute 3, eval in 0.18`
--   ★★ 两个信息位各有独立诊断价值：
--     `execute N`  —— 当前是第几个分支在跑（**它是谁**）
--     `eval in X`  —— 距下次重排还有多久（**它还能撑多久**）
--   ★★ 【如何用它诊断「AI 莫名其妙停下」】
--     现象：怪物站着不动。
--     读法：看 `execute N`。若 N 指向一个「不该停在这里」的分支，
--       顺着它往下读整条路径上的 DBString，就能找到卡住的那个节点。
--     ★★ 尤其注意 `eval in X` 若是一个**很大的值**（接近 period），
--       说明刚重排完就卡住了 —— 意味着「重排选中的分支立即返回了 RUNNING」，
--       而那个 RUNNING 的子节点在做一件永远做不完的事。
--   ★★ 这是本文件最有实用价值的调试输出，务必掌握。
function PriorityNode:DBString()
--★ time_till 初值 0。
    local time_till = 0
--★ `if self.period then` —— 恒真（见 544 行的死代码分析）。
--   ★ 与 552 行的钳位不同，**这里没有钳位**。
--   ※ 因此当 lasttime 为 nil 时，time_till 会是 `0 + period - GetTime()`，
--     在游戏早期（GetTime() 小）可能是个大正数，
--     与 541 行 GetSleepTime 的「保持 0」行为不一致。
--     ★ 差异仅体现在调试输出上，不影响逻辑（DBString 不参与决策）。
    if self.period then
--★★ 计算「距下次评估还有多久」。注意无钳位（对比 552 行）。
       time_till = (self.lasttime or 0) + self.period - GetTime()
    end

--★★ `self.idx or -1` —— 用 -1 表示「尚未选中任何分支」。
--   ★ 与 579 行 Reset 时的 `self.idx = nil` 配对：
--     nil = 未选中 → 显示 -1。
--   ★ 选 -1 而非 0 是因为 children 从 1 开始编号（Lua 数组惯例）。
    return string.format("execute %d, eval in %2.2f", self.idx or -1, time_till)
end


--★★【PriorityNode:Reset —— 与 Sequence 的 Reset 结构相同，语义不同】
--   ★★ 代码形态与 SequenceNode:314 一模一样，但 `self.idx = nil` 而非 1。
--   ★★ 差异的意义见 489 行（RandomNode 的同款分析）：
--     nil 表示「未选中任何分支」，是第三种状态。
--     ★★ 为什么 Priority 需要这第三种状态？
--       因为 Priority 的遍历是「找一个赢家」（598-620 行），
--       而非「顺序走」。在找到之前，idx 没有意义。
--       ★★ 对比 Sequence：它的 idx 从 1 开始就永远合法（第 1 个孩子必然存在）。
--   ★★ 为什么 Reset 不清 lasttime？
--     ★★ 因为 **lasttime 是节流状态，必须跨 Reset 存活**。
--       若 Reset 清掉它，每次重排后都会立刻再触发一次重排，
--       period 节流就完全失效了（变成每帧全量遍历）。
--     ★★ 这与 Sequence 的 idx 恰好相反：
--       idx = 进度（必须清）
--       lasttime = 节流游标（必须留）
--     ★★ 「什么是进度、什么是节流」是阅读行为树代码时最重要的分类标准。
function PriorityNode:Reset()
--★ 显式父类调用。
    self._base.Reset(self)
--★ idx = nil —— 「未选中」。详见 577 行分析。
    self.idx = nil
end

--★★【PriorityNode:Visit —— 本文件最复杂、最有价值的 55 行】
--   ★★ 【整体结构：两条互斥的大路】
--     do_eval 为真  → 589 行：**全量遍历所有孩子，重新挑赢家**（598-620）
--     do_eval 为假  → 625 行：**只 Visit 当前赢家**，其余不动（节流路径）
--   ★★ 【为什么节流路径要单独存在？】
--     因为每帧重挑所有分支太贵：一棵 20 个分支的树 × 几百个实体 = 每帧上万次 Visit。
--     ★★ 节流路径让「维持正在做的事」变成 O(1)，
--       而「换正在做的事」才付全量遍历的钱，频率由 period 控制。
--     ★★ 这是整个 DST 决策系统的性能基石。
--   ★★ 两条路都与 EventNode 抢占机制深度耦合 —— 见 585-636 各行详解。
function PriorityNode:Visit()

--★ 本次取一次时间，585/596 两处复用，避免同帧内时间漂移。
    local time = GetTime()
--★★【do_eval：该不该在本次思考里重新挑赢家】
--   `local do_eval = not self.lasttime or not self.period or self.lasttime + self.period < time`
--   ★★ 三个「或」条件，逐一分析：
--     ① not self.lasttime → 「上次重排时刻不存在」→ 立即重排。
--        两种成因：noscatter 构造（536 行）、事件唤醒（734 行）。
--        ★★ **这是事件驱动响应的正式入口**：事件把 lasttime 清成 nil，
--          do_eval 立刻为真，下一帧就重新挑赢家。
--     ② not self.period → ※ 恒假（死条件，见 544 行分析）
--     ③ lasttime + period < time → 「周期到了」→ 常规重排
--   ★★ 【与 GetSleepTime 的因果闭环】
--     541 行的 GetSleepTime 返回 `lasttime + period - GetTime()`（剩余时间）；
--     brain.lua:143-146 据此把 brain 放进 tickwaiters 队列；
--     时间到了 brain 醒来 → OnUpdate → bt:Update → 585 行 do_eval 为真 → 全量重排。
--     ★★ 「到期 → 醒 → 重排 → 再睡」是一个完整的闭环，没有外部定时器参与。
--   ★★ 注意条件是 `< time` 而非 `<= time`，
--     所以每 period 至少间隔一次思考，不会因为同一时刻反复触发而空转。
    local do_eval = not self.lasttime or not self.period or self.lasttime + self.period < time
--⚠【疑似缺陷 · 无用局部变量】`local oldidx = self.idx`
--   ★★ 推理依据：检索本函数（582-638）全文，oldidx **从未被读取**。
--     代码里用的都是 self.idx（如 592/593/609/614/627 行）。
--   ★★ 推测成因：从代码结构看，作者原本可能打算用 oldidx 做「恢复原赢家」
--     或「避免重复 Reset 自己」的判断，写到一半改用了 self.idx。
--   ★★ 值得注意的是：**这个残留变量恰好指向了 H1 缺陷的历史**。
--     若作者当初用 oldidx 去做「保留旧赢家状态」的逻辑，
--     就不会有 610 行那处破坏性的 Reset（见 609 行的 ※★ 分析）。
--     ★ 这是「一个无用变量」如何成为「一个真实缺陷的化石记录」的范例。
    local oldidx = self.idx


--★★【全量重排路径的入口 —— 只有这一条路会遍历所有孩子】
--   ★★ 与节流路径（625 行）的对比是本函数的核心：
--     全量路径：O(孩子数) × Visit 成本 —— 贵，但频率低（每 period 一次）
--     节流路径：O(1) —— 便宜，每帧都走
    if do_eval then

--★★ old_event —— 「上一轮的赢家是不是一个 EventNode」。
--   ★★ 这个变量是**抢占机制的总开关**，下面两行是全文件最关键的三行之一：
--     ① 只有当旧赢家是 EventNode 时，才可能发生「事件抢占」
--     ② 否则一律按位置顺序选（后来的低优先级分支连试都不试）
--   ★★ 【为什么必须是「旧赢家是 EventNode」才允许抢占？】
--     理由：EventNode 的触发带有**时效性**（临时状态，如 panic、gohome）。
--     ★ 如果允许普通分支被抢占，会出现「正在正常走路的怪物被一个无关分支打断」，
--       行为变得不可预测。
--     ★ 而 EventNode 抢占意味着「发生了紧急事件」，打断是合理的。
--     ★★ 所以这条规则的设计意图是：
--       「只有紧急事件才允许打断当前行为」。非常克制，也非常合理。
--   ★ 但它有一个直接后果（H1 缺陷的土壤）：
--     ★★ 抢占发生时，旧赢家被**直接 Reset**（610 行）而不是挂起，
--       于是旧行为的状态被彻底清空 —— 这就是「AI 莫名其妙停下」的机制。
        local old_event = nil
--★★ `if self.idx and self.children[self.idx]:is_a(EventNode) then`
--   ★★ 三个守卫缺一不可：
--     ① self.idx 非 nil → 上轮确实选过赢家（对比 Reset 后的 nil）
--     ② 下标合法（构造上恒成立，因为 idx 只由 ipairs 赋值）
--     ③ is_a(EventNode) → 只有事件节点才可被抢占
--   ★★ is_a 来自 class.lua:15，沿 _base 链向上查元表。
--     ★※ 注意 EventNode 定义在 702 行，而 PriorityNode 在 533 行 ——
--       这里引用的是**运行时**的全局变量，属于前向引用。
--       ★ 实际不会出问题：is_a 在 Visit 被调用（游戏运行后）时才求值，
--         那时整个文件早已加载完毕。参见 103 行的同类前向引用说明。
--   ★★ 「只有 EventNode 能被抢占」这条规则的代价：
--     ★ 如果一个 WhileNode（如 gohome 的条件分支）正在跑，
--       一个 EventNode 触发后**不能**抢占它（因为旧赢家不是 EventNode），
--       必须等 WhileNode 自己 FAILED 才有机会。
--     ★ 这在实践中是合理的：WhileNode 通常本身就是「重要状态」（夜晚、回巢），
--       不该被普通事件打断。
        if self.idx and self.children[self.idx]:is_a(EventNode) then
--★ 记下旧事件节点本身（后续要读它的 priority 字段）。
            old_event = self.children[self.idx]
        end

--★★ lasttime = time —— 「本轮重排发生在此刻」。
--   ★★ 注意这行在**遍历之前**执行，所以本次遍历中即使发生抢占，
--     lasttime 也已是新值 —— 抢占不会导致「下一次重排也被迫立即执行」。
--   ★★ 但有一个微妙后果：EventNode:OnEvent 在遍历**过程中**被调用时
--     （某个 child:Visit 触发了事件），它的 DoToParents 会把 lasttime 清成 nil；
--     遍历结束后 596 行已经写过……不对，596 在前，所以会被清成 nil。
--     ★★ 这实际上是**好事**：子树里触发的事件会让下一帧也重排一次，
--       确保事件不被「同一次重排吞掉」。但也意味着可能连续两帧重排。
--       ★ 属于可接受的轻微冗余。
        self.lasttime = time
--★ found —— 「已经找到赢家了」。它控制 601 行的短路。
--   ★★ found 的作用是：**一旦找到赢家，后面的孩子就不必再试**（除非可抢占）。
--     这是本函数唯一的性能优化，也是「优先级 = 位置顺序」的实现。
        local found = false
--★★【全量遍历循环 —— 「优先级」二字的实际含义就在这个顺序里】
--   ★★ `ipairs` 从孩子 1 走到孩子 N。**靠前的先被问，先被问的就是优先级高**。
--   ★★ 「优先级」在这个框架里**没有任何数字**（除了 EventNode 的 priority），
--     它完全由**在列表中的位置**决定。
--     ★ 这是一个关键的设计取舍：
--       · 优点：声明式、零成本、无需配置排序
--       · 代价：调整优先级必须改动列表顺序，无法运行时插队
--   ★★ 详见 600 行的抢占分支 —— 它是对「位置即优先级」这一规则的**唯一例外**。
        for idx, child in ipairs(self.children) do

--★★【should_test_anyway —— 抢占机制的核心判据，全文件最精妙的一行】
--   `local should_test_anyway = old_event and child:is_a(EventNode) and old_event.priority <= child.priority`
--   ★★ 三个条件逐个拆解：
--     ① old_event —— 「上一轮的赢家是事件节点」（591 行的结果）
--        ★ 没有它，任何事件都不能抢占（见 591 行的设计意图分析）
--     ② child:is_a(EventNode) —— 「当前候选也是事件节点」
--        ★★ **只有事件能抢占事件**。非事件分支永远按位置顺序，
--          即使它的位置在旧赢家之后。
--     ③ old_event.priority <= child.priority —— 「候选的优先级不低于旧赢家」
--        ★★ 这才是「优先级」这个**数字字段**唯一的用武之地。
--          同一个 PriorityNode 里的多个 EventNode 靠这个数字比高低。
--        ★ 默认值是 0（706 行 priority or 0），所以：
--          两个都没指定 priority 的事件节点之间，`<=` 恒成立 → 互相可抢占。
--          ★★ 这意味着**只要有两个 EventNode，谁后触发谁赢**（在同一轮内都试，
--            后面的会 Reset 前面的 —— 见 609 行）。
--     ★★ 三个条件的合起来的效果（举例）：
--       树：[..., E1(prio=1)「敌人靠近」, ..., E2(prio=5)「快死了」]
--       · 旧赢家是 E1，E2 触发 → ①✓ ②✓ ③(1<=5)✓ → should_test_anyway=true
--         → 即使 E1 位置在前（优先级本应更高），E2 依然会被测试并可能获胜
--       · 旧赢家是 E2（prio=5），E1 触发 → ③(5<=1)✗ → 不测试
--         → E2 保持，E1 被 618 行 Reset
--       ★★ 所以数字 priority 覆盖了位置优先级 —— 这是唯一的例外通道。
--   ★★ 【 为什么默认 priority = 0 且判据用 `<=` —— 一个值得警惕的设计】
--     当所有事件节点都用默认 0 时，`<=` 让**所有事件节点互相可抢占**，
--     而遍历是按位置顺序的，所以**靠后的事件节点会赢**。
--     ★★ 举例：stageusherbrain.lua:39 的树里若有两个默认 priority 的 EventNode，
--       位置靠后的那个会永远压制靠前的那个 —— 只要两者都处于 triggered。
--     ★★ 这不是 bug 而是「默认同优先级 + 后写优先」的规则，
--       但它与「位置即优先级」的整体规则方向**相反**，非常反直觉。
--     ※ 实践建议：一旦同一 PriorityNode 里有多个 EventNode，
--       **必须显式指定 priority**，否则顺序行为会非常难以预测。
            local should_test_anyway = old_event and child:is_a(EventNode) and old_event.priority <= child.priority
--★★【短路条件 —— 决定「谁被问、谁被跳过」】
--   `if not found or should_test_anyway then`
--   ★★ 两种进入方式：
--     ① not found —— 还没找到赢家 → **每个孩子都要问**（正常优先级流程）
--     ② should_test_anyway —— 已找到赢家，但这个孩子可抢占 → 也问
--   ★★ 所以 618 行的 else 分支 = 「已找到赢家，且这个孩子不能抢占 → 跳过并 Reset」。
--     ★★ 这正是「优先级」的第一次体现：
--       第一个成功的分支确立赢家，后续分支被 Reset（618 行）而非被询问。
--   ★★ 注意：被 618 行 Reset 的孩子**连 Visit 都没被调用**。
--     这比「Visit 了再 Reset」省得多，是重要的性能细节。
            if not found or should_test_anyway then

--★★【重置已完成的分支 —— 「每轮重新评估」的前提】
--   `if child.status == FAILED or child.status == SUCCESS then child:Reset() end`
--   ★★ 为什么只 Reset 这两种状态，不 Reset RUNNING？
--     · SUCCESS/FAILED 是「上一轮的结论」，本轮要重新试 → 先擦干净
--     · RUNNING 是「正在做的事」，本轮可能还要继续做 → 不能擦
--   ★★ 【RUNNING 不被 Reset 是抢占机制能工作的基础】
--     假设这里也 Reset 了 RUNNING 分支，
--     那么「正在追人的怪物」会在每轮重排时被清空进度、重新开始追 ——
--     表现为「追到一半停下来又追」，非常明显的抽搐。
--     ★ 所以这个 `or` 条件里的「不含 RUNNING」是一个**关键的正确性保证**。
--   ★★ 注意这一行在 `if not found or should_test_anyway` 之内，
--     所以被 618 行跳过的分支不走这里（它们走 618 自己的 Reset）。
--   ★★ 两处 Reset 的区别：
--     603 行：会被本轮询问的分支 → 先擦再问
--     618 行：不会被询问的分支 → 直接擦（不问了）
                if child.status == FAILED or child.status == SUCCESS then
--★★ 擦干净，让这次 Visit 从 READY 状态开始。
--   ★ 若不擦，一个上轮 SUCCESS 的分支可能因为内部状态残留而立即 SUCCESS，
--     形成「自我实现的成功」（假阳性）。
                    child:Reset()
--★ 调用的是子节点自己的 Reset —— 若子节点是 Sequence/Event 等，
--   会走它们覆写的版本（连带归零 idx / 清 triggered）。
--   ★★ 这就是「Reset 的多态」：框架不需要知道子节点类型。
                end
--★★ 真正询问这个分支 —— 递归 Visit。
--   ★★ 这是本文件里**唯一**会对「优先级低于赢家」的分支也调用 Visit 的地方
--     （另一半是 629 行的节流路径，只 Visit 赢家）。
                child:Visit()
--★ 读取这次询问的结果。
                local cs = child.status
--★★【赢家的判定：SUCCESS 或 RUNNING 都算「这个分支愿意干」】
--   ★★ 与其他组合节点的「采纳」条件一致（对照 507、327、366 行）。
--   ★★ 为什么 RUNNING 也算赢家？
--     因为「正在做」正是我们要保持的状态。
--     ★★ 所以 Priority 的语义是「找一个愿意做事的分支」，
--       而不是「找一个能立即做完事」的分支。
                if cs == SUCCESS or cs == RUNNING then
--★★【★★ H1 缺陷的核心：抢占时的破坏性 Reset ★★】
--   `if should_test_anyway and self.idx ~= idx then`
--        `self.children[self.idx]:Reset()`      ← 这一行是 bug-patterns.md H1 的根因
--   ★★ 【完整的抢占时序 —— 逐帧还原「AI 莫名其妙停下」】
--     前提：PriorityNode 的孩子里，E_old（旧赢家，位置 k1，priority=p1）
--           与 E_new（新触发的事件，位置 k2>k1，priority>=p1）都是 EventNode。
--     其他分支 X（位置 k3>k2，非 EventNode）此刻正在执行「跑向目标」。
--
--     T0：E_old 触发并运行 → 树稳定在 idx=k1。X 是 RUNNING 的低优先级分支。
--     T1：E_new 的事件发生（inst:PushEvent）。
--        → EventNode:OnEvent(721) 执行：
--             · 730-732  brain:ForceUpdate()（请求立即重排）
--             · 734      DoToParents 把本 PriorityNode 的 lasttime 清成 nil
--        ★ 注意此时 E_new 的 status 仍是 READY，只是 triggered=true。
--     T2：下一次 bt:Update → 585 行 do_eval 为真（lasttime 为 nil）→ 全量遍历。
--        · 591 行 old_event = E_old（is_a(EventNode) 成立）
--        · 遍历到 k1：E_old 保持 RUNNING → found=true, idx=k1
--        · 遍历到 k2：600 行 should_test_anyway = (p1 <= p2) = true
--             603 行：E_new.status 是 READY → 不 Reset
--             606 行：E_new:Visit() → 因 triggered 而转 RUNNING → 子节点开始跑
--             608 行：status == RUNNING → 采纳
--             609 行：should_test_anyway 为真 且 self.idx(k1) ~= idx(k2)
--        ★★ 610 行：`self.children[k1]:Reset()` —— **E_old 被强行清空**
--             包括它 status=RUNNING→READY 与整棵子树（级联）。
--             ★★ E_old 的内部状态（它自己的 idx / 已走过的进度 / 计时）全部丢失。
--             ★★ 更关键：紧接着 612-614 行把 idx 改成 k2。
--        · 遍历到 k3：X 是 RUNNING 的非事件分支。
--             ★★ 601 行 `not found` 为假（found 已是 true），
--               600 行 should_test_anyway 也为假（X 不是 EventNode）
--               → 走 618 行 `child:Reset()`
--        ★★ X 被 Reset 掉了！它本来正在好好地「跑向目标」，
--             现在被清成 READY。
--             ★★ 而 E_new 抢到 idx 后，它的子节点可能**立刻返回 FAILED**
--               （例如「回家」节点发现已经在家里了、或攻击目标已死）。
--             ★★ 于是本轮结束时：E_old 已 reset、X 已 reset、E_new FAILED。
--        · 621 行：found 为真（E_new 曾被采纳），所以本节点 status = RUNNING/E_new状态。
--     T3：下一轮 Step(161) 把一切非 RUNNING 的复位。
--        ★★ 结果：本来在正常跑动的行为（X）被无端打断，
--          E_old 也被清空，而抢占者 E_new 自己又失败了。
--        ★★ 净效果 = **AI 站在原地什么都不做** —— 正是 bug-patterns.md H1 描述的症状。
--
--   ★★ 【为什么这是设计缺陷而非「抢占的正常代价」】
--     ① **抢占者在获胜之前就把竞争者砸了**：
--        610 行无条件 Reset 旧赢家，但并没有验证「抢占者能持续运行」。
--        正确做法应是「抢占者 SUCCESS/RUNNING 后再挂起旧赢家」，
--        而这里虽然 608 行已经确认了 cs == SUCCESS/RUNNING……
--        ★ 但这个 cs 是**瞬时**结论：下一帧 E_new 可能立刻 FAILED。
--     ② **没有挂起/恢复机制**：本框架里根本没有 Suspend / Resume / Interrupt。
--        ★ 全文件检索确认：不存在 Interrupt、Suspend、Resume、timeout 任何一个。
--        ★★ 这意味着「被抢占」与「被重置」是**同一件事**，不可区分。
--        ★★ 这才是根本缺陷：**框架缺少「挂起」这一概念**。
--          抢占只能通过「砸掉重来」实现，代价就是状态全丢。
--     ③ **误伤无辜**：618 行把 k3 的 X 也 Reset 掉。
--        ★★ X 并没有「输掉竞争」——它只是在赢家确定之后还没轮到被问。
--          按 603 行的逻辑，RUNNING 的分支本不该被 Reset（那会导致抽搐），
--          但 618 行恰恰把 RUNNING 的 X Reset 了。
--        ★★ 这是本缺陷最直接的证据：**618 行与 603 行互相矛盾**。
--          603 行刻意排除 RUNNING 以避免「追到一半重来」，
--          而 618 行却不加区分地 Reset 一切 —— 恰好制造了那种抽搐。
--     ④ 与 EventNode:724-726 的叠加效应：
--        当 E_old 自己的事件**重复触发**时（721-726 行），
--        它会先 `self.children[1]:Reset()` 清空自己的子节点。
--        ★★ 这是**第二处**破坏性重置，且发生在事件发生的瞬间（更早）。
--        ★★ 两处叠加：事件重复触发 → 子节点被清 → 行为从头开始 → 视觉上「停下来再走」。
--
--   ★★ 【修复方向（仅记录，本文件不改代码）】
--     方案 A（最小改动）：把 610 行的 Reset 改成「挂起标记」
--       · 给 BehaviourNode 加 status = SUSPENDED，GetTreeSleepTime 忽略它；
--       · Step(161) 对 SUSPENDED 节点也跳过；
--       · 旧赢家重新被选中时把 SUSPENDED 转回 RUNNING（保留状态）。
--     方案 B（保守）：引入 `old_status` 备份，Reset 前存档，
--       抢占失败（下轮 E_new FAILED）时回滚并恢复 idx=k1。
--     方案 C（治标）：只在 `cs == RUNNING` 时才 Reset 旧赢家，
--       `cs == SUCCESS` 时保留（成功意味着这事做完了，旧的确实该让位）。
--       ★ 但这仍不能解决「E_new 下一帧就 FAILED」的情形。
--     ★★ 无论如何，618 行对 RUNNING 分支的无差别 Reset 都应加 RUNNING 排除，
--       与 603 行保持一致。
--   ※ 实际影响面：优先级的抢占只在「同一 PriorityNode 内有多个 EventNode」
--     且「旧赢家也是 EventNode」时才发生。
--     核实：brains/ 中确实有多处这样的树
--     （如 brains/rabbitbrain.lua:58 的 gohome 是该树唯一的 EventNode，
--       故安全；而 stageusherbrain.lua:39、bird_mutant_rift_brain.lua:75/83
--       等树里有多个 EventNode，风险更高）。
--   ★ 这解释了为什么该缺陷「偶发」而非「必现」——它依赖具体的树结构。
--   ※ 参见 bug-patterns.md 分区 H 的 H1 条目（症状 / 根因 / 修复建议）。
                    if should_test_anyway and self.idx ~= idx then
--★★⚠【★ 缺陷现场 · bug-patterns.md H1 的根因行】`self.children[self.idx]:Reset()`
--   ★★ 这一行做了两件破坏性的事：
--     ① 把旧赢家的 status 从 RUNNING 打回 READY
--     ② 级联 Reset 它的**整棵子树**（171-180 行的递归）
--   ★★ 【级联 Reset 的放大效应】
--     旧赢家若是 SequenceNode/EventNode，Reset 会递归到最深的叶子。
--     例如旧赢家是 `EventNode{ SequenceNode{ Condition, DoAction } }`，
--     那么 DoAction 节点**已经发出去的 bufferedaction 无法被撤销**
--     —— Reset 只是把行为树状态擦掉，实体身上的组件状态（正在执行的动作）
--     仍在继续，形成「行为树认为没在做事，实体仍在做」的**状态分裂**。
--   ★★ 这才是最严重的后果：
--     Reset 只清理**行为树内部**的状态，完全不通知 locomotor / bufferedaction。
--     所以被抢占的旧行为不是「优雅地停下」，而是「被遗忘但仍在物理上继续」。
--     ★★ 若旧行为当时正在 locomotor:GoToPoint，locomotor 会继续走完；
--       而行为树已经认为它 READY、可以开始新的行为了。
--       两个行为同时驱动 locomotor → 互相抢方向 → **怪物原地抽搐/打转**。
--     ★★ 这正是「AI 莫名其妙停下」或「原地抖动」的物理成因。
--   ★★ 正确做法应该是先 `inst.components.locomotor:Stop()` 再 Reset，
--     但本框架完全不知道 locomotor 的存在（节点只操作回调）。
--   ※ 这一行绝不能改。本文件是「只加注释」的注释工程，不修改任何代码。
                        self.children[self.idx]:Reset()
--★ `end` —— 结束 if。
--   ★★ 注意缩进用的是 16 空格（比同层多一级），说明作者写这段时
--     对嵌套层级的判断有过犹豫。不影响语义。
                    end
--★★ 自己继承孩子的状态（RUNNING 或 SUCCESS）。
--   ★★ 与 614 行相邻：先定状态，再定 idx。顺序无关紧要。
                    self.status = cs
--★ found = true —— 「赢家已定，后续分支默认不再询问」。
                    found = true
--★★ `self.idx = idx` —— 「赢家易主」。
--   ★★ 这一行与 610 行的 Reset 是同一个抢占动作的两半：
--     610：把旧赢家清空
--     614：把指针指向新赢家
--   ★★ 【为什么不需要「挂起」旧赢家？—— 因为框架里不存在这个概念】
--     参见 609 行的完整分析②：本文件没有 Suspend / Resume。
--     ★★ 所以旧赢家的唯一命运就是被彻底遗忘。
--   ★★ idx 的持久性：它活到下一次 Step。
--     若新赢家是 RUNNING，则本 Priority 也是 RUNNING，
--     Step(162) 不会 Reset 它 → **idx 跨帧保留** → 节流路径（625 行）继续用它。
--     ★★ 这就是「粘性」的物理实现：RUNNING 的 Priority 保住 idx。
--     ★ 若新赢家是 SUCCESS，本 Priority 也是 SUCCESS，
--       Step 会 Reset 它 → 577 行把 idx 置 nil → 下轮重新挑。
                    self.idx = idx
                end
            else

--★★⚠【★ 缺陷现场 · 与 603 行自相矛盾的 Reset】`child:Reset()`
--   ★★ 这个 else 分支 = 「已找到赢家，而这个孩子不能抢占 → 跳过它」。
--   ★★ 本意是「清理落选者，节省后续帧的开销」——出发点没问题。
--   ★★ 【但它无条件 Reset，包括 RUNNING 的分支，这就是缺陷】
--     对照 603 行：`if child.status == FAILED or child.status == SUCCESS then`
--     ★★ 603 行**刻意排除了 RUNNING**，理由很清楚：
--       Reset 一个 RUNNING 的分支会让它「做到一半从头再来」，造成抽搐。
--     ★★ 而 618 行没有这个排除 —— 于是：
--       一个正在安静执行「跑向目标」的 RUNNING 分支（位置在赢家之后），
--       会在每次 do_eval 的遍历中被无条件 Reset。
--       ★★ 结果：它的行为被清空、locomotor 仍在走、行为树认为它 READY。
--         下轮它重新被 Visit、重新发起 locomotor 命令 → **抽搐 / 打转 / 停下**。
--   ★★ 【为什么作者会在这里漏掉 RUNNING 判断？】
--     合理的推测：作者的心智模型是「能走到 else 说明这个分支没被选中，
--     没被选中就是没在跑，Reset 它理所当然」。
--     ★ 但这个假设在「有多个 RUNNING 分支」的树里不成立 ——
--       而恰恰是 Priority 节点**允许并鼓励**多个 RUNNING 分支共存
--       （对比 Sequence / Selector 只会沿一条路径下钻）。
--     ★★ 所以这是「用 Sequence 的心智模型写 Priority 的代码」的经典错误。
--   ★★ 修复方向：618 行应加 RUNNING 排除，与 603 行一致：
--       `if child.status ~= RUNNING then child:Reset() end`
--     ★★ 这是一个**纯 bug 修复**（不改变设计语义，只消除状态丢失），
--       风险比 610 行的改动低得多。
--   ※ 本文件只加注释，不改代码。此处仅记录推理依据与影响面。
--   ※ 参见 bug-patterns.md H1 条目。
--   ★★ 附带影响：618 行也是「落选分支的状态清理」的唯一位置。
--     若改成「跳过 RUNNING 分支不 Reset」，
--     则该 RUNNING 分支会保持 RUNNING 直到自己结束，
--     这正是我们期望的「低优先级行为持续进行」语义。
                child:Reset()
            end
        end
--★ 一轮遍历结束仍无赢家 → 整体 FAILED。
--   ★★ 与 374 行（Selector 全失败）语义相同。
--   ★★ 但注意这里**没有把 idx 设回 nil** —— idx 保持上轮的值。
--     ★★ 而 577 行 Reset 只在本节点被 Reset 时才把 idx 设 nil。
--     本节点 status 是 FAILED → 下一轮 Step(162) 会 Reset 它 → 577 行执行 → idx=nil。
--     ★ 所以不设 nil 是安全的（由 Step 兜底）。
--   ★★ 但存在一个中间态窗口：本轮 status=FAILED 而 idx 仍是旧值，
--     若此时调用 GetString 会显示 `Priority - FAILED <SUCCESS> (execute 2, ...)`。
--     调试时看到这种组合不必惊慌，它只存在于一帧之间。
        if not found then
            self.status = FAILED
        end

--★★【节流路径 —— 「不重排，只推进赢家」】
--   `else` 分支对应 589 行的 if 不成立，即 do_eval 为假（周期未到 / lasttime 为 nil）。
--   ★★ 注意：「lasttime 为 nil」也会走这里！
--     但585 行已保证 lasttime 为 nil 时 do_eval 为真，所以这里 lasttime 一定非 nil。
--   ★★ 【节流路径的三行主体，O(1) 的性能来源】
--     ① 有 idx（说明上轮选过赢家）→ 只 Visit 它
--     ② 它若还是 RUNNING → 状态透传给它（继续推进）
--     ③ 它若不再是 RUNNING（做完了/失败了）→ 清空 lasttime，**立刻重新评估**
--   ★★ ③ 是很巧妙的设计：「赢家结束」= 「重排时机到了」，
--     无需等 period，下一帧就会走全量路径。
--   ★★ 这让 period 只限制「无事发生时的检查频率」，
--     而「有事发生时」立即响应。
    else
--★ `if self.idx then` —— 有过赢家才需要推进。
--   ★ 没有 idx（Reset 后）说明上轮没选出赢家，那 do_eval 应该为真才对。
--     走到这里的 idx=nil 情形极少，保守跳过即可。
        if self.idx then
--★ 直接索引当前赢家 —— O(1) 的关键。
--   ★★ 对比全量路径的 598 行 `for idx, child in ipairs(...)`：
--     这里是「按索引直达」，完全不遍历。
            local child = self.children[self.idx]
--★★ `if child.status == RUNNING then` —— 只推进正在跑的那个。
--   ★★ 为什么必须判 RUNNING？
--     若赢家已完成（SUCCESS/FAILED），状态透传出去会让本 Priority 也变成 SUCCESS/FAILED，
--     下一个 Step 就把它 Reset 掉 —— 但那样就**丢了重新评估的机会**。
--     ★ 所以正确做法是：赢家完成了 → 不透传，改由 632 行清 lasttime 触发重排。
--     ★★ 换句话说：节流路径只会维持 RUNNING，绝不传递「完成」的信号。
--   ★★ 这与全量路径的 612 行（无条件透传 cs）形成鲜明对比。
--     全量路径：本轮选出的结果就是本轮的状态（可以 SUCCESS）
--     节流路径：只维持现状，完成信号转成「该重排了」
--     ★ 这个不对称是有意的 —— 见 625 行的分析。
            if child.status == RUNNING then
--★ 只 Visit 赢家 —— 推进它（让 Wait 比时间、让 Leash 查距离等）。
--   ★★ 【这一行是整个 DST 决策系统每帧成本的主要来源】
--     假设一个服务器有 500 个生物，每个脑的 Priority 有 10 个分支，
--     且只有一个赢家在 RUNNING：
--       · 全量路径：每 period 秒一次 × 10 个分支的 Visit
--       · 节流路径：每帧一次 × 1 个分支的 Visit
--     ★★ period = 0.25 时，全量频率 4Hz；帧率 30fps 即节流频率 30Hz。
--       节流路径反而更高频，但它便宜 10 倍，所以总成本更低。
--   ★★ 真正的成本大头是「赢家在做什么」：
--     · Leash:IsInsideLeash 每帧算一次距离平方（便宜）
--     · Wander 每帧可能改方向（便宜）
--     · DoAction 每帧检查 bufferedaction 状态（中等）
--     · ★ 若赢家里有个 ConditionWaitNode 卡住（251 行），
--       它每帧返回 0 → 整棵树每帧被调度且每帧重跑该节点 → CPU 空转。
                child:Visit()
--★★ 状态透传：赢家仍是 RUNNING，本 Priority 也是 RUNNING。
--   ★★ 这样 541 行的 GetSleepTime 会进入 542 行分支，计算剩余重排时间，
--     实现节流。
                self.status = child.status
--★★ 赢家不再是 RUNNING（做完了）→ 本 Priority 也不透传。
--   ★★ 保持原 status（可能是 RUNNING 或别的）不变，
--     由 632 行清 lasttime 触发下帧重排。
                if self.status ~= RUNNING then
--★★【节流路径的关键一步：主动清空 lasttime 以触发立即重排】
--   `self.lasttime = nil`
--   ★★ 为什么这是必需的？
--     场景：赢家在跑「回家」，跑完了。
--       · 若不清 lasttime：要干等 period 才重排 → 怪物回家后**原地站 period 秒**
--       · 清了 lasttime：下一帧 585 行 do_eval 为真 → 立刻挑下一个行为
--     ★★ 这就是「行为完成后立即无缝切换」，效果非常好。
--   ★★ 与 734 行（EventNode 的 DoToParents）对比：
--     两者都是「把 lasttime 清成 nil」这一个动作，目的相同（强制立即重排），
--     触发源不同（行为完成 vs 外部事件）。
--     ★★ 结论：`lasttime = nil` 是本框架里**唯一的「立即重排」信号**，
--       两个触发源，一个机制。这个「单一信号」的收敛性设计得很好。
--   ★★ 条件（631 行的 else）：只有「赢家结束」时才清，
--     保证不会在赢家还跑着的时候反复清（那会导致每帧全量遍历）。
                    self.lasttime = nil
--★ 结束 if（631 行）。
                end
            end
        end
--★ 结束 if（625 行）。
--   ★★ 整个 Visit 至此结束。回头看整体结构：
--       582  function PriorityNode:Visit()
--       589    if do_eval then          → 全量重排（贵，O(N)）
--       621      if not found then FAILED
--       625    else                     → 节流推进（便宜，O(1)）
--       632        lasttime = nil       → 强制下次全量
--       636    end
--       638  end
--   ★★ 「全量重排 / 节流推进」二分 + 「lasttime = nil 作为唯一开关」
--     是本框架节流机制的全部。理解这三行就理解了 DST AI 的性能模型。
    end

end


---------------------------------------------------------------------------------------


--★★【ParallelNode —— 「同时推进所有孩子」的组合节点】
--   ★★ 与前三种组合节点的根本差异：
--     Sequence / Selector / Priority —— **一次只问一个孩子**（靠 idx）
--     Parallel                     —— **每次问所有孩子**
--   ★★ 【为什么需要它？核心用途是「运行时中断」】
--     考虑需求：「在做某事 A 的同时，一旦条件 B 不成立就立刻停掉 A」。
--     ★ Sequence 无法表达（它会等 A 做完才看下一个）；
--     ★ Selector 也无法表达（它只问一个）；
--     ★ 只有 Parallel 能做到：把 ConditionNode(B) 和「做 A」并排放，
--       每帧同时访问两者，B 一 FAILED 就让整体 FAILED（672-674 行），
--       A 于是被 Step 复位 —— **A 被中断了**。
--   ★★ 这就是 767-770 行原注释所说的：
--     "The While condition will be checked on every update, so subsequent nodes
--      will be interrupted if they change the result of that condition."
--     翻译：「While 条件每次更新都会被检查，所以后续节点会在条件改变时被中断。」
--   ★★ 于是 771 行的 WhileNode 只是「ParallelNode + 一个 ConditionNode」的语法糖。
--   ★★ 【它也是本框架唯一的「中断」机制 —— 因为没有 Interrupt API】
--     全文件检索确认：无 Interrupt / Suspend / Resume / timeout。
--     ★★ 所以「中断」在本框架里 = 「让父节点变 FAILED，下轮 Step 复位它」。
--       这是一种**间接的、无通知的中断**：
--       被中断的节点不知道自己被中断了，只是突然变成 READY。
--     ★★ 这与 610/618 行的破坏性 Reset 是同一个问题的两面：
--       框架缺少显式的取消语义，导致所有「停止」都表现为「遗忘」。
ParallelNode = Class(BehaviourNode, function(self, children, name)
--★ name 可传（ParallelNodeAny 借此改成 "Parallel(Any)"，见 693 行）。
--   ★★ 这是本文件里**唯一支持自定义名字的组合节点构造器**。
--   ※ 对比 Sequence:305 / Selector:341 / Priority:534 / Loop:428 / Random:485
--     都硬编码名字。可传名字在调试多并行场景时很有用。
    BehaviourNode._ctor(self, name or "Parallel", children)
end)


--★★【ParallelNode:Step —— 覆写基类 Step 的唯一理由：条件必须每帧重算】
--   ★★ 两个分支与基类（161 行）完全一致，唯一区别在 654 行的条件重置。
--   ★★ 【为什么需要这一步？】
--     661-690 行的 Visit 里，条件节点每帧都会被 Visit（666-668 行会先 Reset），
--     所以「每帧重算」在 Visit 里已经保证了。
--     ★★ 那 Step 里的 654 行是干什么的？
--       它在**下一轮 Visit 之前**把已 SUCCESS 的条件复位成 READY，
--       ★★ 目的是让 670 行的 `if child.status ~= SUCCESS then child:Visit() end`
--         在下一轮能够重新访问这个条件。
--     ★★ 关键在于 670 行的短路：**条件一旦 SUCCESS 就不再被 Visit**。
--       若不在 Step 里复位，条件将永远停在 SUCCESS ——
--       「每帧检查条件」就退化成了「只检查一次」。
--     ★★ 所以 654-656 行是「每帧重算」这个语义的**最后一环保险**。
--   ★★ 两处重置的分工：
--     666-668 行（Visit 内）：访问前重置 —— 保证本轮能重新判定
--     654-656 行（Step 内）：轮末重置 —— 为下一轮做准备
--     ★ 重复但必要：Visit 内的重置保证「本轮问的是新答案」，
--       Step 内的重置保证「下轮不会被 SUCCESS 短路掉」。
function ParallelNode:Step()
--★ 非 RUNNING → 整体 Reset（与基类 163 行相同）。
    if self.status ~= RUNNING then
--★ `self:Reset()` 而不是 `self._base.Reset(self)` ——
--   ★★ 两者等价（ParallelNode 没有覆写 Reset，走的是基类），
--     但写法不一致，属于风格不统一。无功能影响。
        self:Reset()
    elseif self.children then
        for k, v in ipairs(self.children) do
--★★「已成功的条件节点」需要复位 —— 这是 ParallelNode 的核心机制。
--   ★★ `v:is_a(ConditionNode)` 精确限定「只复位条件」，
--     不动动作节点 —— 动作节点的 SUCCESS 状态需要保留吗？
--   ★★ 【关于 670 行短路的连锁效应 —— 一个需要注意的设计细节】
--     670 行 `if child.status ~= SUCCESS then child:Visit() end`：
--       · 动作节点一旦 SUCCESS，就**永远不再被 Visit**，
--         直到整个 Parallel 被 Reset（650 行）。
--       ★★ 这意味着 Parallel 里一个 SUCCESS 的动作节点会被「永久冻结」。
--         这是正确的（「做完了就别再做」），但它要求 Parallel 的整体生命周期
--         由条件节点来结束 —— 而条件节点一旦 SUCCESS 也会被复位（654 行），
--         于是条件会继续每帧判定，直到 FAILED 才让整体 FAILED。
--     ★★ 完整时序（以 WhileNode(cond, node) 为例）：
--         · cond 假 → FAILED → 整体 FAILED → node 被中断（下一轮 Step 复位）
--         · cond 真 → SUCCESS → node 开始跑
--         · node RUNNING → 整体 RUNNING
--         · node SUCCESS → 整体 SUCCESS（670 行不再 Visit node）
--         · 下轮 Step：654 行复位 cond → cond 重新判定
--           ★★ 若 cond 仍为真，Parallel 继续 SUCCESS 状态（不 reset，因为 650 行
--             判的是本 Parallel 的 status = SUCCESS ≠ RUNNING → 会 Reset！）
--             ※※ 重新看：650 行 `if self.status ~= RUNNING then self:Reset() then`，
--               SUCCESS 也会触发 Reset。所以 Parallel 成功后整体被复位，
--               node 也被复位，然后下一轮从头再来。
--         ★★ 结论：ParallelNode 的「完成」不会持久 ——
--           只要条件还成立，下一轮就会重新进入并重跑 node。
--           这正是 WhileNode 想要的语义：「只要 cond 成立就一直做 node」。
--           ★★ 而这也是为什么 minperiod.lua 那类节点需要存在：
--             防止 WhileNode 把某个动作无限重复（每帧重跑）。
--             MinPeriod 用「距离上次成功不足 minperiod 就 FAILED」来限流。
--             参见 behaviours/minperiod.lua:14-19。
            if v.status == SUCCESS and v:is_a(ConditionNode) then
--★ 复位这个条件节点，让它下轮能被重新询问。
                v:Reset()
            end
        end
    end
end

--★★【ParallelNode:Visit —— 「全部访问 + 任一失败即整体失败」】
--   ★★ 核心规则（与所有其他组合节点都不同）：
--     ① **每个孩子都访问**（664 行遍历）—— 与 Sequence/Selector 的 O(1) 对比
--     ② **任一 FAILED → 整体立刻 FAILED 并 return**（672-675 行）
--     ③ 全部完成 → SUCCESS；否则 RUNNING（685-689 行）
--   ★★ 【②是「中断」的来源】
--     条件节点 FAILED → 整体 FAILED → 下一轮 Step(162) 整体 Reset →
--     那个正在 RUNNING 的动作节点被复位 → **动作被强行终止**。
--     ★★ 而动作节点自己完全不知情（没有 OnInterrupt 回调）。
--       若它已经调用了 locomotor:GoToPoint，物理上仍在走 ——
--       ★★ 于是又出现「行为树状态」与「实体状态」的分裂（同 610 行的分析）。
--     ★★ 这是 WhileNode 的「优雅之处」也是它的「隐患之处」。
function ParallelNode:Visit()
--★ done = true 起步 —— 「默认全部完成」，只要有一个 RUNNING 就置假。
--   ★★ 注意 done 的语义是 **AND**（全部完成才算完成），
--     与 any_done 的 OR 形成一对（685 行）。
    local done = true
--★★ any_done = false —— 「是否至少有一个孩子已完成」。
--   ★★ 只被 stoponanycomplete 为真时使用（685 行），
--     也就是 ParallelNodeAny 专用。普通 Parallel 不看它。
    local any_done = false
--★★ 遍历所有孩子 —— 与 Sequence 的 `while idx <= #children` 形成对比。
--   ★★ 性能：O(孩子数) 每帧。Parallel 的孩子通常只有 2 个（条件 + 动作），
--     所以这个 O(N) 是可接受的。
    for idx, child in ipairs(self.children) do

--★★【条件节点每帧复位 —— 「While 语义」的物理实现】
--   `if child:is_a(ConditionNode) then child:Reset() end`
--   ★★ 为什么必须每帧复位？
--     因为条件必须**每帧重新判定**（WhileNode 的定义）。
--     ★★ 而 670 行的短路会让 SUCCESS 的孩子不再被 Visit，
--       所以必须主动复位，否则条件永远停在上次的答案。
--     ★★ 这两行（666-668）与 654-656 行的 Step 重置构成双重保障，
--       共同实现「条件每帧重算」。
--   ★★ 注意：只有 ConditionNode 及子类会被特殊对待。
--     MultiConditionNode（218 行）**不是** ConditionNode 的子类 ——
--       ★★ 所以 IfThenDoWhileNode 里的 MultiConditionNode 不会享受「每帧重置」，
--         而是靠 470 行式的 SUCCESS 短路 + Parallel 整体 Reset 来重跑。
--         ※ 这是 IfThenDoWhileNode 与 WhileNode 的一个实现差异，
--           行为上大体一致（都能每帧判定 MultiCondition 本身，
--           因为 231/235 行每次 Visit 都会重算），但值得注意。
        if child:is_a(ConditionNode) then
--★ 复位 —— 注意用的是 self（Parallel）风格的调用写法。
            child:Reset()
        end

--★★「已经 SUCCESS 的孩子不再访问」—— 三个后果要分清：
--   ① 条件节点：因 666-668 每帧被复位，所以几乎不会命中这个短路。
--   ② 动作节点：一旦 SUCCESS 就冻结，直到整体被 Reset。
--   ③ 嵌套节点：同理。
--   ★★ ②③ 的「冻结」是必要的（避免重复执行已完成的动作），
--     但它意味着 Parallel 内部**没有进度记录**，
--     「跑到第几步」完全靠各子节点自己的状态维持。
        if child.status ~= SUCCESS then
--★ 递归访问这个孩子。
            child:Visit()
--★★【任一失败 → 整体失败 + 立刻返回 —— 「中断」的触发点】
--   ★★ 注意这里是 `return`，**立即**结束遍历，
--     所以排在后面的孩子这一轮不会被访问。
--   ★★ 这带来一个可观察的顺序依赖：
--     「先条件后动作」的排列（WhileNode / IfNode 的标准排法）
--     能保证条件先判定、动作后执行，避免无谓的动作启动。
--     ★ 771 行的 WhileNode 正是这个顺序（ConditionNode 在前）。
--   ★★ 反过来若动作在前，条件为假时动作已经被启动一次（虽然会被 Reset）。
            if child.status == FAILED then
--★ 状态置 FAILED —— 下轮 Step(162) 会 Reset 整个 Parallel。
--   ★★ 那时正在 RUNNING 的动作节点被级联 Reset —— 「中断」完成。
                self.status = FAILED
--★ 立即返回，不访问后面的孩子。见 672 行的分析。
                return
            end
        end

--★ 该孩子还在跑 → 整体还不能算完成。
        if child.status == RUNNING then
            done = false
        else
--★★ 该孩子已完成（SUCCESS）→ 记一笔 any_done。
--   ★★ 这里 else 分支包含 FAILED，但 FAILED 已在 672 行 return 了，
--     所以能到这里的「非 RUNNING」必然是 SUCCESS。
            any_done = true
        end
    end

--★★【收尾判定 —— 两条不同的成功标准】
--   `if done or (self.stoponanycomplete and any_done) then`
--   ★★ 两种语义：
--     ① done（全部完成）→ 普通 ParallelNode 的成功标准
--     ② stoponanycomplete and any_done（任一完成）→ ParallelNodeAny 的成功标准
--   ★★ stoponanycomplete 只在 ParallelNodeAny 里被设为 true（694 行），
--     普通 ParallelNode 恒为 nil。
--   ★★ 于是两个子类的差异**只有这一处** ——
--     构造时的 name 与 stoponanycomplete 标志，判定逻辑共用。
--   ★★ 【ParallelNodeAny 的语义：「谁先完成就算谁」】
--     典型用途（oceanfishbrain.lua:210、beequeenbrain.lua:214）：
--       并行做几件事，哪件先完成就用哪件的结果。
    if done or (self.stoponanycomplete and any_done) then
--★ 整体 SUCCESS —— 「都做完了」或「够了（Any 模式）」。
        self.status = SUCCESS
    else
--★ 有孩子还在跑 → 整体 RUNNING，parent 会继续保留本节点。
--   ★★ RUNNING 会让 Step(162) 跳过 Reset，从而保住整棵子树的状态。
--     这是「正在做的事能持续下去」的物理保证。
        self.status = RUNNING
    end
end

--★★【ParallelNodeAny —— 「任一子节点完成即成功」的并行节点】
--   ★★ 它只是 ParallelNode 的一个特化：加了 stoponanycomplete 标志。
--     所以可以理解为「带一个布尔开关的 ParallelNode」。
--   ★★ 为什么不做成「参数」而是「子类」？
--     因为 685 行的判定里需要区分两种模式，而子类化能复用全部 Visit 逻辑，
--     避免在热路径里多一次参数判断。
--   ★★ 代价：使用者必须知道有这两个类（ParallelNodeAny / ParallelNode）。
--     ★ 实践中的命名不对称（一个是类一个是子类）容易让人漏掉 Any 版本。
ParallelNodeAny = Class(ParallelNode, function(self, children)
--★★ 注意参数顺序：`ParallelNode._ctor(self, children, "Parallel(Any)")`。
--   ★★ 而 ParallelNode 的构造器签名是 `function(self, children, name)`（644 行），
--     所以 children 在前、name 在后 —— 正确。
--   ※ 对比 LoopNode:427 的签名是 `function(self, children, maxreps)`，
--     同样是 children 在前。行为树节点的构造约定：**children 总是第一个参数**。
--   ★★ 唯一的例外是 ConditionNode:202（fn 在前）与 MultiConditionNode:218。
--     因为它们没有 children。见 202 行的说明。
    ParallelNode._ctor(self, children, "Parallel(Any)")
--★★ stoponanycomplete = true —— 685 行的判据由此生效。
--   ★ 这是 ParallelNode 与 ParallelNodeAny 的**唯一行为差异**。
    self.stoponanycomplete = true
end)



---------------------------------------------------------------------------------------


--★★【EventNode —— 「事件发生时才跑」的节点（★ 事件驱动的落地点）】
--   ★★ 【它在整个框架里的角色：事件的「执行器」】
--     整条链路：
--       ① 事件源 inst:PushEvent("gohome")   （entityscript.lua 的事件总线）
--       ② EventNode 的监听回调 OnEvent(708)  被触发
--       ③ OnEvent 设置 triggered=true，并唤醒 brain（730-732）
--       ④ 下一次 bt:Update 时 Visit(749) 看到 triggered → 转 RUNNING → 跑子节点
--     ★★ 「事件」是本框架唯一的异步输入源。
--       没有它，行为树就只能靠 brain 的周期轮询感知世界。
--   ★★ 四个构造参数的含义：
--     inst      —— 监听哪个实体的事件（通常是实体自己）
--     event     —— 事件名字符串，会出现在 name 里（703 行）便于调试
--     child     —— 事件发生后要跑的节点（单个）
--     priority  —— 抢占优先级（706 行，默认 0）
--     ★★ priority 是**本文件里唯一的优先级数字**，
--       唯一用武之地是 600 行的 `old_event.priority <= child.priority`。
--       详见 600 行的完整分析（尤其是「默认全为 0 会导致后写优先」的陷阱）。
--   ★★ 典型用法（核实自 brains/ 目录）：
--     · rabbitbrain.lua:58   EventNode(inst, "gohome", DoAction(...))
--     · birdbrain.lua:29    EventNode(inst, "threatnear", ...)
--     · stageusherbrain.lua:39  EventNode(inst, "minhealth", ...)
--     ★★ 这些事件由谁 PushEvent？
--       · "gohome"   —— 由各 brain 在特定时刻主动 Push（如黄昏时）
--       · "panic"    —— BrainCommon 的 panic 逻辑
--       · "minhealth"—— 血量组件或 brain 的检查逻辑
--     ★ 所以 EventNode 是「外部世界 → 内部决策」的唯一入口。
EventNode = Class(BehaviourNode, function(self, inst, event, child, priority)
--★★ name 内嵌事件名：`"Event("..event..")"`。
--   ★ 这是调试时最有用的一行 —— 一眼就能看出「这个分支等的是哪个事件」。
--   ※ 若 event 为 nil，字符串拼接会抛异常（Lua 里 .. 与 nil 报错）。
--     所以 event 必须是字符串，没有默认值。
    BehaviourNode._ctor(self, "Event("..event..")", {child})
--★ inst 存起来 —— OnEvent(715) 与 Visit(730) 都要用。
    self.inst = inst
--★ event 名也存一份（除了拼 name 还用于反注册）。
    self.event = event
--★★ priority 默认 0 —— 这个默认值有个反直觉的后果，务必记住：
--   ★★ 因为 600 行的判据是 `old_event.priority <= child.priority`，
--     当**所有**事件节点都用默认值 0 时，该条件恒成立（0 <= 0），
--     ⇒ **同一 PriorityNode 内的多个 EventNode 会互相可抢占**，
--     而遍历按位置顺序 ⇒ **靠后的事件节点永远压制靠前的**。
--   ★★ 这与「位置即优先级」的整体规则方向相反，非常反直觉。
--     结论：树里只有一个 EventNode 时无碍；有多个时必须显式指定 priority。
--   ★★ 参见 600 行的完整分析。
    self.priority = priority or 0

--★★【事件回调的闭包 —— 为什么用闭包而不是直接绑定方法】
--   `self.eventfn = function(inst, data) self:OnEvent(data) end`
--   ★★ 三个设计理由，逐个说清：
--     ① **需要捕获 self**：inst:ListenForEvent 要求回调是稳定的函数引用，
--        而 OnEvent 是方法（需要 self 作为第一个参数），
--        直接传 `self.OnEvent` 会把事件实体的参数当成 self。
--        ★★ 闭包是唯一能同时拿到 self 与 data 的方式。
--     ② **必须能精确反注册**（716 行 RemoveEventCallback）：
--        ★★ 反注册要求传入**同一个函数引用**。
--          如果传方法，Lua 每次访问 `self.OnEvent` 都会新建一个闭包，
--          RemoveEventCallback 永远找不到它 → 监听泄漏。
--        ★★ 这就是「必须把 eventfn 存成字段」的根本原因 ——
--          一个字段 = 一个稳定的引用 = 可精确反注册。
--     ③ **适配参数签名**：
--        ListenForEvent 的回调签名是 `fn(inst, data)`，
--        而 OnEvent 只想收 data（inst 已经在 self.inst 里了），
--        所以这里丢弃第一个参数。
--   ★★ 顺带说明：eventfn 被存为**实例字段**而非局部变量，
--     每个 EventNode 实例各有自己的闭包实例，因此可以独立反注册。
    self.eventfn = function(inst, data) self:OnEvent(data) end
--★★【监听注册 —— 发生在构造期，不是启动期】
--   ★★ 后果一：**从构造那一刻起事件就一直被监听**，
--     哪怕这个节点当前是 READY、整棵树还没跑起来。
--     ★★ 后果二：即使节点被 Reset（744 行），监听依然存在 ——
--     因为 Reset 不动 eventfn。所以「Reset 后重新考虑」时事件不会丢。
--     ★ 这是刻意的：Reset 是「重新考虑」，Stop 才是「拆掉」（713 行）。
--   ★★ 【隐患：事件监听是「构造期注册、Stop 期注销」的固定配对】
--     若某棵树被构造但从未 Stop（例如 Brain 被替换时走了别的清理路径），
--     监听会永久留在 inst 的事件表里 → 内存泄漏 + 幽灵行为。
--     ★ 实际路径核实：entityscript.lua:1108 SetBrain 会先调 _Stop_Internal
--       → brain.lua:253 bt:Stop() → 613 行 OnStop → 摘监听。所以是安全的。
--   ※ 但模组若绕过 SetBrain 直接操作 self.brain，就可能漏掉 Stop。
--     ★ 这是模组开发时最需要注意的「行为树资源生命周期」问题。
    self.inst:ListenForEvent(self.event, self.eventfn)
--※【被注释掉的调试打印】`--print(self.inst, "EventNode()", self.event)`
--   ★ 原样保留 —— 它是排查「事件到底注册到哪个实体上」的第一手线索。
--   ★ 注意这行在构造器里，所以它打的是「节点被创建时」的信息，
--     而不是「事件被触发时」的信息（后者见 722 行）。
    --print(self.inst, "EventNode()", self.event)
end)

--★★【OnStop —— 全文件唯一的资源释放点，也是 Reset/Stop 的分水岭】
--   ★★ 对照 33 行的 BT:Stop 与 182 行的 BehaviourNode:Stop：
--     · Reset（171 行）**不动** eventfn，监听保留
--     · Stop  调 OnStop，**摘掉**监听并把 eventfn 置 nil
--   ★★ 这条区分极其重要，它是「树可以反复 Reset 但只能 Stop 一次」的原因，
--     也是 709 行的监听能安全跨越整个运行期的保证。
--   ★★ 调用链：
--     brain.lua:253 Brain:_Stop_Internal → self.bt:Stop()
--       → 182 行 BehaviourNode:Stop（递归全树）
--         → 每个节点的 OnStop（若定义）
--           → 本函数
--   ★★ 触发 Stop 的上游路径（核实自 entityscript.lua）：
--     · :1098 StopBrain(reason) — 主动停脑
--     · :1108 SetBrain — 换脑时先停旧脑
--     · :1128 _DisableBrain_Internal — 睡眠 / 离开场景
--   ★★ 【※ 重要推论：Stop 之后不能直接复用同一棵树】
--     因为监听已被摘掉（716 行）且 eventfn 置 nil（717 行），
--     而**没有任何代码会重新 ListenForEvent**。
--     ⇒ 若某棵树 Stop 过又再 Start，它的事件分支将永久失效。
--     ★ 这正是 entityscript.lua:1110 与 :1137 选择「重建整个 brain 对象」
--       而非「复用旧 bt」的原因 —— 重建 = 重新构造 = 重新注册监听。
--     ★★ 这个约束对模组作者是硬性的：**bt 一旦 Stop 就必须丢弃重建**。
function EventNode:OnStop()
--※【被注释掉的调试打印】`--print(self.inst, "EventNode:OnStop()", self.event)`
--   ★ 与 710 行的构造打印配套，可确认「监听被摘掉了」。
    --print(self.inst, "EventNode:OnStop()", self.event)
--★★ `if self.eventfn then` —— 幂等守卫。
--   ★★ 为什么必须幂等？BehaviourNode:Stop（182 行）会**递归全树**调用 OnStop，
--     而 Stop 可能被多次调用（见 713 行的上游路径分析）。
--     若不幂等，第二次 RemoveEventCallback 会传 nil 给引擎 → 可能报错。
--   ★★ 这是「用 eventfn 既是引用也是存活标志」的巧思：
--     一个字段同时承担了「回调引用」与「是否已注册」两个职责。
    if self.eventfn then
--★★ 反注册 —— 必须传入与 709 行**完全相同**的函数引用。
--   ★★ 这就是 708 行把 eventfn 存成字段的全部理由。
--   ★ 若写成 `self.inst:RemoveEventCallback(self.event, self.eventfn)` 时
--     eventfn 是 nil（已被清），引擎侧应当忽略。
        self.inst:RemoveEventCallback(self.event, self.eventfn)
--★★ eventfn = nil —— 「已注销」的标记，让 715 行的幂等守卫生效。
--   ★★ 注意这里**没有**把 status 或 triggered 清掉 —— OnStop 只管资源。
        self.eventfn = nil
    end
end

--★★⚠【★★ 缺陷现场之二 · OnEvent 的第一行就是破坏性 Reset ★★】
--   `if self.status == RUNNING then self.children[1]:Reset() end`
--   ★★ 【这是 H1「AI 莫名其妙停下」的第二处根因，且比 610 行更隐蔽】
--     与 610 行的区别非常重要：
--       · 610 行：在**优先级重排时**Reset 别人（赢家易主导致的连带损伤）
--       · 724 行：**事件重复触发时**Reset 自己的子节点
--     ★★ 724 行的问题更严重，因为它在**事件发生的瞬间**就执行，
--       此时 PriorityNode 还没做任何重排决策 —— 行为树完全「自作主张」
--       地把自己的正在运行的行为清空了。
--   ★★ 【完整时序：同一事件重复触发导致行为中断】
--     场景：怪物正在执行 `EventNode(inst, "gohome", DoAction(回家))`，
--           即该 EventNode 是 RUNNING，DoAction 正在让 locomotor 走回家。
--     T0：gohome 事件第一次触发 → EventNode 转 RUNNING → DoAction 启动 → 开始走。
--     T1：gohome 事件**再次触发**（PushEvent("gohome")）。
--        → OnEvent 执行 → status == RUNNING 成立 → 724 行 Reset 子节点
--        ★★ DoAction 被清成 READY：它内部记录的目标、进度、阶段全部丢失。
--        ★★ 但 locomotor 不受影响 —— 它已经在走了！
--        ★★ 造成「行为树认为没在做事，实体仍在走」的状态分裂。
--     T2：下一轮 bt:Update → Visit(755) 发现 status 是 RUNNING（EventNode 自己没被 Reset）
--        → 755-759 行再次 `child:Visit()`
--        ★★ DoAction 是 READY，所以它**从头开始**执行回家逻辑。
--        ★★ 表现：怪物「走到一半突然重新规划路线」或「抖动一下」。
--     T3：如果 DoAction 重新执行时发现「已经在家附近了」，返回 SUCCESS → 行为结束。
--        ★★ 但如果它反复触发（某些 brain 每隔一段时间就 PushEvent("gohome")），
--          怪物就会**永远走不完**，表现为「原地抖动 / 来回踱步」。
--   ★★ 【 为什么 724 行的 Reset 几乎是必然踩坑的？】
--     它的意图应该是「事件重复触发 = 重新开始处理这个事件」。
--     ★★ 但对「一个需要持续多帧的动作」而言，「重新开始」意味着
--       「丢弃已经投入的时间与进度」。
--     ★★ 更根本的问题是：**本框架没有「更新事件数据」的概念**。
--       EventNode 有 self.data（728 行）承载事件负载，
--       但没有任何子节点接口可以「在不中断的情况下接收新数据」。
--       ★★ 所以作者选择了唯一的出路：Reset 后重跑。
--       ★★ 这是「缺少增量更新语义」导致的必然设计缺陷。
--   ★★ 另一个可疑点：725 行只 Reset 了 `self.children[1]`，
--     没有 Reset 自己。所以 EventNode 的 status 仍是 RUNNING。
--     ★★ 结果是 749-765 行的 Visit 会走「已是 RUNNING」的分支（755 行），
--       再次 Visit 那个刚被 Reset 的孩子 → 它从头开始。
--     ★★ 正确做法应该是同时把 status 也归位，让 751 行的
--       `READY and triggered` 分支生效（走完整的新一轮）。
--   ★★ 与 727 行的关系：先 Reset 再置 triggered —— 顺序是对的
--     （先清干净，再标记「有新事件」），符合直觉。
--   ※ 修复方向（仅记录，不改代码）：
--     · 方案 A：去掉 724-726 的 Reset，让 DoAction 自行判断如何处理新事件；
--     · 方案 B：只在子节点**声明**了「可重新触发」时才 Reset（如加属性）；
--       ★ 这正符合 bug-patterns.md H1 的预防建议：
--         「放弃时是否保留状态必须在节点类型上声明清楚」。
--   ※ 参见 bug-patterns.md H1 条目的「预防」段。
function EventNode:OnEvent(data)
    --print(self.inst, "EventNode:OnEvent()", self.event)

    if self.status == RUNNING then
        self.children[1]:Reset()
    end
--★★ triggered = true —— 「有新事件到达」的粘性标志。
--   ★★ 【它的生命周期只有一帧，由 Step(741) 清除】
--     · 置位：725-737 行的 OnEvent（事件发生的瞬间，可能任意两次思考之间）
--     · 消费：749-753 行的 Visit（读到后立刻转 RUNNING）
--     · 清除：741 行的 Step（每次思考周期末）
--   ★★ 【※ 一个真实的丢失窗口】
--     事件可以在**任何时刻**发生，包括「Visit 已经开始之后」。
--     ★★ 若事件在 Visit 过程中被 PushEvent（例如某个 child:Visit 里
--       调用了 inst:PushEvent），那么：
--         · OnEvent 执行，triggered = true
--         · 但本轮 Visit 可能已经走过了这个 EventNode（没消费到 triggered）
--         · 然后 BT:Update 的 Step(24) → EventNode:Step(741) 把 triggered 清成 false
--       ★★ 结果：**这次事件被静默丢弃**。
--     ★★ 这不是理论风险：actions/doaction.lua 这类节点在完成动作后
--       常常会 PushEvent 触发后续行为。若那个后续 EventNode 已被遍历过，
--       事件就丢了。
--     ★★ 对比 730-732 行的 brain:ForceUpdate —— 它请求的是「下一帧重排」，
--       但 triggered 在**本帧**末尾就被清了，两者时序不匹配。
--       ★★ 这是「事件标志 + 每帧清除」这种设计的固有竞态。
--       正确做法应是「消费时才清除」或在 Visit 开头统一快照。
    self.triggered = true
--★★ data —— 事件的负载数据。
--   ★★ 全仓库检索确认：**没有任何代码读取 self.data**。
--     它是一个「预留的扩展点」：模组或未来的 brain 可以通过
--     `child.parent.data` 访问事件负载。
--   ★★ 例如 `"minhealth"` 事件理论上可以携带当前血量，
--     让子节点据此决定「逃跑」还是「硬抗」。
--   ※ data **不会被 Reset 清除**（744 行的 Reset 不动它），
--     所以它会保留上一次事件的负载。若子节点误读，
--     可能拿到过期的数据。这与 728 行配合使用时需注意。
--   ★★ 对照 727 行的 triggered（会被清除），data 是「粘住的」，
--     两者生命周期不同 —— 这一点很容易误解。
    self.data = data
--★ 空行分隔「数据记录」与「唤醒请求」两个阶段。

--★★【唤醒 brain —— 把「事件发生」翻译成「立即重新考虑」】
--   `if self.inst.brain then ... end`
--   ★★ nil 守卫：不是所有有 EventNode 的实体都有 brain。
--     理论上 EventNode 可以挂在别的容器上，那时没有 brain 可唤醒。
--   ★★ 这一行是「事件驱动」的**执行者**，与 727 行的 triggered 配对：
--     · triggered 负责「这一轮要考虑这个分支」
--     · ForceUpdate 负责「这一轮必须发生」（否则 brain 可能在休眠）
--   ★★ 【为什么两者都需要？】
--     只有 triggered 不够：若 brain 已 Hibernate（GetSleepTime 返回 nil），
--     它根本不会进入 bt:Update，triggered 就永远读不到。
--     ★★ 只有 ForceUpdate 也不够：brain 会醒来，但若 period 未到，
--     PriorityNode:585 的 do_eval 为假 → 走节流路径（625 行）→
--     EventNode 的 Visit 可能根本不被调用。
--     ★★ 所以必须两者配合：
--       ForceUpdate → brain 立即醒（绕开休眠）
--         + DoToParents 清 lasttime（734 行）→ do_eval 为真 → 全量遍历
--           → Visit 遍历到 EventNode → triggered 被消费 → 子节点跑起来
--     ★★ 这三步缺一不可，是本框架「事件响应」的最短路径。
--   ★★ 这个唤醒路径同时也解决了 33 行提到的「Hibernate 后只能靠事件唤醒」。
    if self.inst.brain then
--★ 转发给 brain.lua:170-176 的 Brain:ForceUpdate。
--   ★★ 那里做两件事：置 bt.forceupdate + BrainManager:Wake(inst)。
--     前者让 38 行的 GetSleepTime 返回 0（立即更新），
--     后者把实体从 hibernaters 移回 updaters。
--   ★★ 参见 brain.lua:170 与本文件 17 行的详细分析。
        self.inst.brain:ForceUpdate()
    end

--★★【★ 强制重排的另一半：把祖先 PriorityNode 的 lasttime 清成 nil】
--   `self:DoToParents(function(node) if node:is_a(PriorityNode) then node.lasttime = nil end end)`
--   ★★ 【它解决的是 730 行解决不了的问题】
--     ForceUpdate 只保证「brain 会醒」，但**不保证**优先级会被重排 ——
--     因为 585 行的 do_eval 还要看 `lasttime + self.period < time`。
--     ★★ 若 period 是 1 秒，事件发生后最坏要等 1 秒才会被重新评估。
--       对「被攻击要逃」这种反应，1 秒是灾难。
--     ★★ 所以必须有这一行：**清掉 lasttime = 关闭节流 = 立即重排**。
--   ★★ 【与 632 行的对照 —— 同一个「立即重排」信号，两个触发源】
--     · 632 行：赢家跑完了 → lasttime = nil → 下帧全量重排
--     · 734 行：事件发生了 → lasttime = nil → 下帧全量重排
--     ★★ 机制相同（清 lasttime），目的相同（强制重排），
--       触发源不同（内部完成 vs 外部事件）。
--       ★★ 这是本框架「单一信号收敛」设计最好的一处体现。
--   ★★ 【为什么用 DoToParents 而不是直接 self.parent？】
--     因为 EventNode 可能嵌套在多层组合节点之下：
--       PriorityNode{ ..., ParallelNode{ ConditionNode, EventNode{...} } }
--     ★★ EventNode 的直接父亲可能是 ParallelNode（不是 PriorityNode），
--       所以必须向上找到**所有** PriorityNode 祖先。
--     ★★ 而「所有」很重要：若只通知最近的那个，
--       外层的 Priority 仍会处于节流状态 → 重排不会发生。
--   ★★ ※【前提条件 —— 树里必须有 PriorityNode 祖先】
--     若 EventNode 挂在非 Priority 的树里（如纯 Sequence 根），
--     这行什么也不做，事件就只能等 brain 自然醒。
--     ★★ 实践上所有脑的根都是 PriorityNode，所以没暴露。
--     ★★ 自定义树时必须记住：**事件唤醒依赖 PriorityNode 存在**。
--   ※ 性能：每次事件都要向上走一遍祖先链（通常 1-3 层）+ is_a 判定。
--     ★ 开销极低，事件本身频率也不高（不是每帧）。
    self:DoToParents(function(node) if node:is_a(PriorityNode) then node.lasttime = nil end end)

--★ 原注释（保留）：`--wake the parent!`（唤醒父节点！）
--   ★★ 这行英文注释揭示了作者的**原始设计意图**：
--     他认为这一行的作用是「叫醒父节点」。
--     ★★ 但实际实现是「清掉祖先的节流时间」，而不是「立即执行」。
--     这个差异正是 727 行 ※ 那个「事件丢失窗口」的来源：
--     ★★ 作者的心智模型可能是「设置一个唤醒标志，父节点下一轮会看到」，
--       而实际上「父节点会在下一次自然调度时看到」。
--       730-732 行的 brain:ForceUpdate 才真正保证了「下一轮会发生」。
--       但 triggered 在本轮末就被清掉了（741 行），两者时序错位。
    --wake the parent!
end

--★★【EventNode:Step —— 「一次性标志的清除点」】
--   ★★ 两个动作，顺序不可交换：
--     ① 先调基类 Step（做该做的清理/递归）
--     ② 再清 triggered
--   ★★ 为什么要先调基类？
--     基类 Step(161) 在 status ~= RUNNING 时会调 self:Reset()，
--     而 EventNode:Reset（744 行）**也会清 triggered**。
--     ★★ 所以即使不写 741 行，triggered 也会被间接清除。
--     ★★ 那 741 行是冗余的吗？——**不是**：
--       · 若 status == RUNNING，基类走 elseif 分支，只递归孩子，
--         **不会调 EventNode:Reset** → triggered 不会被清。
--       · 此时 741 行是唯一的清除点。
--       ★★ 所以 741 行专门处理「本轮刚转 RUNNING 就结束」的情形。
--         典型：一个 EventNode 触发后子节点立即 SUCCESS，
--         EventNode status 变 SUCCESS → 基类 Step 会 Reset（清 triggered），
--         所以那种情况 741 行确实冗余。
--         ★★ 真正需要 741 行的是：子节点让 EventNode 保持 RUNNING，
--           而 triggered 必须在轮末清除，否则下一轮会重复消费。
--   ★★ 这行是 727 行 ※ 「事件丢失窗口」的直接成因。
--   ★★ 对照 744 行 Reset：那里清 triggered 的时机是「被复位时」。
--     两者合起来保证「triggered 只被消费一次」。
function EventNode:Step()
--★★ `self._base.Step(self)` —— 调基类 Step。
--   ★★ **必须是 self._base 而不是 self**：
--     若写 `self:Step()` 就是无限递归（自己调自己）。
--     ★★ 这是 Lua 里覆写方法时调用父类实现的标准写法，
--       `_base` 由 class.lua:99 在 `Class(base, ...)` 里设置。
--   ★★ 对比 746 行的 `self._base.Reset(self)` —— 完全一致的写法。
--     本文件里所有需要「调父类」的地方都用这个模式，共 7 处。
    self._base.Step(self)
--★★ triggered = false —— 「本次事件已被消费」。
--   ★★ 清除时机是**思考周期末**，而不是「读取时」。
--     ※ 这就是 727 行所述竞态的根源，见该行的完整分析。
--   ★★ 实践影响：绝大多数事件由「外部系统」PushEvent
--     （发生在 brain 更新周期之外），所以通常不会踩到这个窗口。
--     ※ 只有「行为树自己 PushEvent」时才会踩到（见 727 行的分析）。
    self.triggered = false
end

--★★【EventNode:Reset —— 「清标志但保留资源」】
--   ★★ 两行的顺序：先清 triggered（745 行），再调基类 Reset（746 行）。
--     ★★ 顺序其实无所谓，因为基类 Reset（171 行）有 `status ~= READY` 守卫，
--       而 EventNode 已经通过 741/745 行把状态理顺了。
--   ★★ 【 为什么 Reset 不动 eventfn？——这是本文件的关键分界】
--     · Reset（此处）→ 只清 triggered，**监听保留**
--     · Stop（713 行 OnStop）→ 清 eventfn，**监听摘除**
--     ★★ 详见 33 行与 709 行的分析。
--     ★★ 推论：EventNode 可以被无限次 Reset 而不会失效，
--       这正是「树可以反复重新考虑而事件不丢」的实现基础。
--   ★★ 与其他组合节点的 Reset 对比：
--     Sequence（314）归零 idx；Selector（350）归零 idx；
--     Loop（439）归零 idx + rep；Random（489）置 nil idx；
--     Priority（577）置 nil idx；
--     ★★ EventNode（744）清 triggered —— 它也有一个「必须归零的游标」，
--       所以覆写 Reset 是**必需的**，符合 577 行推导的通用规则。
function EventNode:Reset()
--★ 清一次性标志。
--   ★★ 注意这行在 741 行之外，说明「清除触发」有两个入口：
--     · 741 行 Step（每轮末）
--     · 745 行 Reset（被复位时）
--   ★★ 两个入口是为了覆盖不同路径，逻辑上有冗余但无害。
    self.triggered = false
--★★ 调基类 Reset 做级联（清子节点）。
--   ★★ 与 740 行的 Step 配对，构成 EventNode 的两个父类调用。
    self._base.Reset(self)
end

--★★【EventNode:Visit —— 「触发判定 → 执行」的极简两段】
--   ★★ 【与所有其他节点的本质差异】
--     其他节点：每次 Visit 都重新判定（条件是纯函数）。
--     EventNode：**只有 triggered 为真才启动**，否则什么都不做。
--     ★★ 这是「事件驱动」在代码层面的最直接体现：
--       事件的到达（OnEvent 置 triggered）是唯一的启动条件。
--   ★★ 【 一个重要的「不作为」：EventNode 不会主动 Reset 落选者】
--     749-765 行**没有任何 Reset 调用**。
--     对比 PriorityNode:603/618 行会 Reset 其他分支。
--     ★★ 后果：EventNode 被抢占时（610 行由 PriorityNode 代劳），
--       它的 triggered 状态由 EventNode:Step(741) 或 Reset(745) 清除，
--       而不是自己清的。这条清理链是跨节点协作的。
--   ★★ 于是存在一个隐患：若 PriorityNode 因某种原因跳过了这个 EventNode
--     的 Visit（例如节流路径下 idx 指向别的分支），
--     triggered 会等到下一轮 Step(741) 才被清 —— 事件可能延迟一轮才生效。
function EventNode:Visit()

--★★ 启动条件：`status == READY and triggered`。
--   ★★ 两个条件缺一不可：
--     · status == READY —— 「现在没在跑」（若已 RUNNING 则不该重复启动）
--     · triggered     —— 「有未处理的新事件」
--   ★★ 【 这里有个与 724 行的矛盾，值得指出】
--     724-726 行的 OnEvent 在 status == RUNNING 时 Reset 了子节点，
--     却**没有把自己的 status 归位成 READY**。
--     ★★ 于是本行的 `status == READY` 恒为 false（它还是 RUNNING），
--       启动分支被跳过，直接落到 755 行的「继续跑」分支。
--     ★★ 结果：Repeat 触发时走的是「继续执行」而非「重新开始执行」，
--       而子节点已经被 725 行清空了 —— 于是子节点从头跑。
--     ★★ 也就是说：725 行的 Reset 与 751 行的 READY 判断组合出来的效果是
--       「保留 EventNode 的 RUNNING 状态 + 清空子节点」，
--       这是一个**语义上很别扭的中间态**。
--     ★★ 更「自然」的实现应该是在 725 行同时把 status 归 READY，
--       让 751 行的分支自然接管。
--   ⚠ 参见 724 行的完整缺陷分析。
    if self.status == READY and self.triggered then
--★ 转 RUNNING —— 「事件已被接受，这个分支现在在做事」。
--   ★★ 这一行让 EventNode 对外表现为一个普通的 RUNNING 节点，
--     后续所有组合节点的通用逻辑（Step 保活、GetSleepTime 统计）都自动生效。
        self.status = RUNNING
    end

--★★【执行段 —— 「启动了或本来就在跑，就去问子节点」】
--   ★★ 与 751 行是并列的两个 if，不是 if/else：
--     · 751 行可能把 status 改成 RUNNING
--     · 755 行随即处理这个 RUNNING
--     ★★ 这样写避免了 else 分支的重复代码。
--   ★★ 【 这里是全框架最需要警惕的一处：状态退化的路径】
--     759 行 `self.status = child.status` —— 子节点的 SUCCESS/FAILED
--     会**直接覆盖** EventNode 的 RUNNING。
--     ★★ 于是下一轮 Visit 时 751 行的 `status == READY` 又是 false，
--       而 755 行的 RUNNING 也是 false —— **两段都不执行**！
--       EventNode 的 Visit 变成空操作，status 保持不变。
--     ★★ 推论：EventNode 一旦跑完（子节点 SUCCESS），
--       在下一轮 Step(739) 之前它的 Visit 是完全空转的。
--       ★★ 这实际上是**正确**的（Step 会 Reset 它，状态归 READY），
--         但意味着「子节点完成后、Step 之前」这一小段时间内，
--         若再来一个事件（triggered 置位），EventNode 不会立刻响应。
--       ★★ 参见 727 行的竞态分析。
    if self.status == RUNNING then
--★★ `self.children and #self.children == 1` —— 结构校验。
--   ★★ EventNode 的构造器（703 行）保证 children 恒为 {child}，
--     所以这个条件**几乎恒真**。
--   ★★ 它是一道防御：万一子类构造器传了别的孩子数量，
--     这里会走 761 行返回 FAILED 而不是错误地只执行第一个孩子。
--   ※ 注意 child 为 nil 时 `{child}` = `{}`，长度 0 → 走 761 行 FAILED。
--     ★★ 这是**优雅降级**：EventNode(inst, "ev", nil) 不会崩，只是永不触发。
        if self.children and #self.children == 1 then
--★ 取唯一的孩子。
            local child = self.children[1]
--★★ 递归 Visit —— 真正干活的地方。
--   ★★ 注意这里是**无条件** Visit（与 Parallel 的 670 行短路不同），
--     因为 EventNode 只有一个孩子，不存在「选择」问题。
            child:Visit()
--★★※【★ 状态退化的关键行】`self.status = child.status`
--   ★★ 【逐个分析子节点可能返回的状态】
--     · child == RUNNING  → self 保持 RUNNING（正常推进）
--     · child == SUCCESS  → self 变 SUCCESS（**子节点盖掉了 RUNNING**）
--     · child == FAILED   → self 变 FAILED（同上）
--   ★★ 【※ 这里有一个「谁来重启」的隐患】
--     self.status 被降级成 SUCCESS/FAILED 后，
--     下一次 Visit 时 751 行要求 status == READY —— 不满足；
--     755 行要求 status == RUNNING —— 也不满足。
--     ★★ 所以 EventNode 的 Visit 在这期间**完全是空操作**。
--     ★★ 它要等到 Step(739) 把自己 Reset 回 READY 才能再次启动。
--       而 Step 在每次 bt:Update 的最后（24 行）执行 —— 通常只有一帧延迟。
--     ★★ 但若这个 EventNode 恰好位于 PriorityNode 的**节流路径**下
--       （625-636 行只 Visit idx 指向的孩子），
--       而它不是 idx —— 那它的 Step 会不会被调用？
--     ★★ 会的：Step 是从根递归下去的（161 行 elseif 分支），
--       不受 PriorityNode 的 idx 限制。所以能正常复位。
--     ★★ 结论：759 行本身没有 bug，但它是「EventNode 状态机脆弱性」的
--       关键一环：它的状态完全由子节点决定，自身不维护「已完成/待重启」的区分。
--   ★★ 一个更稳健的实现会在 759 行之后保证 status 不为 SUCCESS/FAILED，
--     或在 751 行的判断里用 `self.status ~= RUNNING` 而非 `== READY`。
--   ※ 参见 751 行的矛盾分析。
            self.status = child.status
        else
--★★ 防御分支：孩子数量不为 1 → FAILED。
--   ★★ 结合 756 行的 `and #self.children == 1`，
--     这里处理的是「构造器被绕过 / child 为 nil」的情况。
--   ★★ 优雅降级成 FAILED 而非报错 —— 在行为树里这是对的选择，
--     因为 FAILED 会让 PriorityNode 去找别的分支，不会卡死整棵树。
--   ★★ 印证了一条设计原则：**行为树倾向「失败」而非「崩溃」**。
--     对比 264 行 ActionNode 的无条件 SUCCESS（无失败通道），
--     EventNode 有 FAILED 通道 —— 因为它的「无事可做」是正常状态。
            self.status = FAILED
        end
    end

end

--★★【组合辅助函数 WhileNode —— 「只要条件成立就持续执行 node」】
--   ★★ 原注释（保留，逐行对照）：
--     `WhileNode: The While condition will be checked on every update,`
--     `so subsequent nodes will be interrupted if they change the result`
--     `of that condition.`
--   翻译：「WhileNode：While 条件会在每次更新时被检查，
--         所以如果条件的结果发生变化，后续节点会被中断。」
--   ★★ 【 这段英文注释是全文件解释得最好的一段，值得逐字细读】
--     它精确说明了三件事：
--     ① 条件**每帧**检查（实现：ParallelNode:666 的每帧 Reset）
--     ② 条件变化会**中断**后续节点
--     ③ 「中断」= 后续节点被复位（实现：ParallelNode:672-674 整体 FAILED
--        → 下轮 Step(161) 级联 Reset）
--   ★★ 【「中断」这个动词在本框架里的确切含义 —— 全文件最重要的认知之一】
--     ★★ 检索确认：本文件**不存在** Interrupt / Suspend / Resume / timeout
--       中的任何一个函数。
--     ★★ 所以「中断」在本框架里是一个**复合效应**，由三步合成：
--       ① 条件的 Visit 返回 FAILED
--       ② ParallelNode 见 FAILED → 整体 status = FAILED 并 return（673 行）
--       ③ 下一次 bt:Update 的 Step 见 status ≠ RUNNING → 调 Reset（163 行）
--          → 级联 Reset 整棵子树，包括那个正在跑的动作节点
--     ★★ 三步跨越**两帧**：中断在下一帧才真正完成。
--     ★★ 【 关键缺陷：被中断的节点不知情】
--       没有 OnInterrupt 回调，节点无法知道自己被中止了。
--       ★★ 后果一：若它已经调用了 locomotor:GoToPoint，
--         物理上仍在移动 —— 「行为树状态」与「实体状态」分裂。
--         ★★ 这与 610 行、725 行是同一个根本问题的三个表现：
--           框架缺少显式的取消/挂起语义，所有「停止」都退化为「遗忘」。
--       ★★ 后果二：节点的下次 Visit 会从 READY 开始（被 Reset 过），
--         它以为「我要重新做这件事」，于是重复启动。
--         ★★ 表现：怪物「走到一半又重新规划」，或者「反复启动同一个动作」。
--     ★★ 这是本文件最值得记住的一条结构性缺陷。
--     ※ 参见 bug-patterns.md 分区 H（H1 的「预防」段正是这条）。
---------------------------------------------------------------
-- WhileNode: The While condition will be checked on every update,
-- so subsequent nodes will be interrupted if they change the result
-- of that condition.
--★★【WhileNode 的实现 —— 两个类型、一个 Parallel】
--   `return ParallelNode { ConditionNode(cond, name), node }`
--   ★★ 【Lua 语法糖】ParallelNode 后面直接跟 `{...}` 等价于 `ParallelNode({...})`，
--     因为 Class 生成的表有 `mt.__call`（class.lua:181）。
--     ★ 全文大量使用这个写法（793/785/805 行等），读代码时要能识别。
--   ★★ 【逐个元素的职责】
--     ConditionNode(cond, name) —— 每帧重新判定的「门卫」（见 202 行构造签名）
--     node                    —— 门卫通过时持续执行的行为
--   ★★ 【为什么必须用 Parallel 而不是 Sequence？】
--     ★★ 若用 Sequence：条件 SUCCESS 后 idx 前进，**永远不再检查条件**
--       （参见 320 行的分析 + Sequence 的 idx 机制）。
--       → WhileNode 会退化成 IfNode（只判一次）。
--     ★★ 若用 Selector：条件 SUCCESS 后 idx 停住，同样不再检查。
--     ★★ 只有 Parallel 会每帧遍历所有孩子（661-690 行），
--       才能实现「每帧重判条件」。
--     ★★ 所以 ParallelNode 的存在**唯一的主要理由**就是支撑 WhileNode。
--   ★★ 语义总结：「cond 为真 → 跑 node；cond 一变假 → node 被中断」。
--   ★★ 典型用法（核实自 brains/ 目录）：
--     · braincommon.lua:93  WhileNode(panic 条件, "PanicTrigger", Panic(inst))
--     · braincommon.lua:105 WhileNode(电栅栏条件, "ElectricShock", AvoidElectricFence)
--     · rabbitbrain.lua:60  WhileNode(不是白天, "IsNight", DoAction(回家))
--     ★★ 注意 60 行：**「天黑了就一直尝试回家」**，
--       天亮后条件变假 → 回家动作被中断 → 回到 PriorityNode 选下一个分支。
--       ★★ 这是「昼夜节律」在行为树里的全部实现 —— 极其简洁。
function WhileNode(cond, name, node)
--★ ParallelNode 后直接跟表 —— 隐式调用语法（class.lua:181 的 __call）。
    return ParallelNode
        {
            ConditionNode(cond, name),
            node
        }
end

--★★【IfNode —— 「条件成立一次，就一直做下去」】
--   ★★ 原注释（保留）：
--     `IfNode: Once the If condition passes, the brain will move on to`
--     `the subsequent node, and continue executing it until that node succeeds or fails.`
--     `The If condition will not be checked again until that time.`
--   翻译：「IfNode：一旦 If 条件通过，大脑就会转到后续节点，
--         并持续执行它直到那个节点成功或失败。
--         在那之前 If 条件不会被再次检查。」
--   ★★ 这段注释是 WhileNode 那段的对偶，两者对照能看清全部设计意图：
--     · WhileNode（771 行）= Parallel → 条件**每帧**检查 → 会被中断
--     · IfNode（783 行）    = Sequence → 条件**只查一次** → 不会被打断
--   ★★ 「不会被打断」正是 IfNode 的核心价值：
--     有些事一旦启动就必须做完（如「点燃火把」不能半途放弃）。
--     ★★ 用 Sequence 实现「只查一次」极其自然：
--       条件 SUCCESS → 320 行的 idx 前进到 2 → 此后永远 Visit 孩子，
--       再也不回头看条件。
--     ★★ 对比 583 行 IfThenDoWhileNode 的三段式，IfNode 是最简版。
--   ★★ IfNode 的实际用途相对少（因为 DST brain 更常用 WhileNode），
--     但它在「不可中断的一次性任务」场景下是唯一正确的表达。
---------------------------------------------------------------
-- IfNode: Once the If condition passes, the brain will move on to
-- the subsequent node, and continue executing it until that node succeeds or fails.
-- The If condition will not be checked again until that time.
--★★【IfNode 的实现 —— Sequence + ConditionNode】
--   `return SequenceNode { ConditionNode(cond, name), node }`
--   ★★ 与 WhileNode（771 行）的对照，一眼看出设计上的对称：
--     · WhileNode = ParallelNode{ConditionNode, node} → 每帧判，可中断
--     · IfNode    = SequenceNode{ConditionNode, node} → 判一次，不可中断
--     ★★ 同样的两个元素，只换一个容器，语义天壤之别。
--       这是本文件最优雅的一处「组合即语义」示范。
--   ★★ 条件不成立时 Sequence 立刻 FAILED（327 行）→ 父节点找下一个分支。
--   ★★ 因此 IfNode 的用法是「可选分支」：
--       `SequenceNode{ IfNode(cond1, A), IfNode(cond2, B), Fallback }`
--       —— 能做 A 就做 A，能做 B 就做 B，都不行就 Fallback。
function IfNode(cond, name, node)
--★ SequenceNode 后直接跟表 —— 隐式调用。
    return SequenceNode
        {
            ConditionNode(cond, name),
            node
        }
end
---------------------------------------------------------------

--★★【IfThenDoWhileNode —— 「进入判一次，之后持续判」的三段式】
--   ★★ 结构：ParallelNode{ MultiConditionNode(ifcond, whilecond), node }
--   ★★ 与 WhileNode / IfNode 的三方对照，这是本文件的**完整谱系**：
--     ┌──────────────────┬────────────┬──────────┬─────────────┐
--     │ 辅助函数          │ 容器       │ 条件判定 │ 可否被中断  │
--     ├──────────────────┼────────────┼──────────┼─────────────┤
--     │ IfNode(783)      │ Sequence   │ 一次     │ ✗ 不可中断  │
--     │ WhileNode(771)   │ Parallel   │ 每帧     │ ✓ 可中断    │
--     │ IfThenDoWhile    │ Parallel   │ 一次+持续 │ ✓ 可中断   │
--     │ (792)           │            │          │             │
--     └──────────────────┴────────────┴──────────┴─────────────┘
--   ★★ 「if-then-do-while」这个名字直译自编程语言的 while 循环三段式：
--     进入前判一次（if）→ 持续执行（do）→ 每帧再判（while）→ 不满足就退出
--   ★★ 为什么需要第三种？前两种不够的场景：
--     典型需求「一旦发现敌人就追，但敌人消失就停」：
--       · WhileNode(敌人存在) → 敌人出现前也一直在判 —— 浪费，
--         而且更重要的是：**敌人不存在时 node 根本不会被 Visit**，
--         所以「开始追」这个动作缺少触发时机。
--       · IfNode(敌人出现) → 一旦开始追就永不停下 —— 敌人跑了还在追（穿墙）。
--       · IfThenDoWhile(敌人出现, 敌人还在) → ★ 完美匹配。
--     ★★ 所以它填的是「进入条件严格、退出条件宽松」这个空档。
--   ★★ 使用注意：MultiConditionNode 不是 ConditionNode 的子类，
--     所以 ParallelNode:666 不会每帧复位它（详见 666 行的 ※）。
--     ★ 实际影响不大：MultiConditionNode:Visit 每次访问都会重新求值
--     （224-236 行无条件执行），所以仍能每帧判定。
function IfThenDoWhileNode(ifcond, whilecond, name, node)
--★ ParallelNode 后直接跟表 —— 隐式调用。
    return ParallelNode
        {
--★★ MultiConditionNode(ifcond, whilecond, name) —— 218 行的构造签名。
--   ★★ 注意第三个参数是 name（不是 children），与 ConditionNode:202 同构。
--   ※ name 兜底是 "Condition"（219 行），调试时与普通条件无法区分。
            MultiConditionNode(ifcond, whilecond, name),
            node
        }
end

--★★【LatchNode —— 「冷却 / 最小间隔」节点（★ 对照 ConditionWaitNode 的必备设计）】
--   ★★ 【它解决的问题：动作重复触发】
--     WhileNode 的语义是「条件成立就一直做 node」。
--     ★★ 但若 node 本身很快完成（比如「喊一声」），
--       就会变成「每帧喊一声」—— 高频且无意义。
--     ★★ LatchNode 提供限流：「最多每 latchduration 秒做一次」。
--     ★★ 它是本文件里**唯一**提供时间节流的节点
--       （behaviours/minperiod.lua 是行为目录侧的同类实现）。
--   ★★ 【与 ConditionWaitNode（242 行）的对照 —— 框架里的一对互补设计】
--     ┌───────────────────┬──────────────────┬───────────────────┐
--     │                   │ ConditionWaitNode │ LatchNode          │
--     ├───────────────────┼──────────────────┼───────────────────┤
--     │ 等待的对象         │ 某个条件的成立    │ 固定时长冷却       │
--     │ 初始状态          │ 立刻可 SUCCESS   │ 立刻可 RUNNING     │
--     │ 是否有终点         │ ✗ 无（可永久卡住）│ ✓ 有（超时自动解锁）│
--     │ 时间来源          │ 外部条件函数      │ 内部 latchduration │
--     └───────────────────┴──────────────────┴───────────────────┘
--     ★★ 两者的差异是本文件最值得学的一处工程判断：
--       ConditionWaitNode 允许无限等待 —— 适合「等一个必然会发生的事件」，
--         但若那个事件永不到来，就会永久卡死整棵树。
--       LatchNode 永远有终点 —— 适合「限流」，绝不会卡死。
--       ★★ 所以选择哪个，取决于「这件事会不会永远等不到」。
--         会 → 用 LatchNode；不会 → ConditionWaitNode 更简洁。
--   ★★ 典型用法（本次全仓库检索未发现 Lua 代码里的 LatchNode 调用，
--     它属于「框架提供但少用」的能力）：
--     `LatchNode(inst, 3, ActionNode(function() inst:DoSomething() end))`
--     —— 「每 3 秒最多做一次某事」。
--     ★★ 相比 minperiod.lua 的差异：LatchNode 基于**绝对时间戳**，
--       MinPeriod 基于「上次成功后经过了多久」，
--       且 LatchNode 支持 FunctionOrValue 做动态时长。
---------------------------------------------------------------
--★★ 构造器：inst / latchduration / child 三个参数。
--   ★ inst 传给 FunctionOrValue（814 行）作为上下文，与 WaitNode 不同。
LatchNode = Class(BehaviourNode, function(self, inst, latchduration, child)
--★★ name 内嵌时长：`"Latch ("..tostring(latchduration)..")"`。
--   ※ 若 latchduration 是**函数**，tostring 会打印函数地址（如 `function: 0x...`），
--     调试输出会变得很长且无意义。
--     ★★ 这是 814 行支持 FunctionOrValue 与 802 行的直接冲突：
--       「name 里想打印时长」与「时长可以是函数」不能兼得。
--       实践中 FunctionOrValue 的动态时长更实用，故保留函数支持。
    BehaviourNode._ctor(self, "Latch ("..tostring(latchduration)..")", {child})
--★ inst 存起来（814 行求值时作为参数传入）。
    self.inst = inst
--★★ latchduration —— 可以是数字或函数（814 行 FunctionOrValue）。
    self.latchduration = latchduration
--★★ currentlatchduration = 0 —— 「上一次锁定的时长」（尚未锁定过所以是 0）。
--   ★★ 它在 811 行被用作「上一次冷却了多久」的依据，
--     而真正的当前时长要到 814 行锁定成功时才更新。
--   ★★ 这个「先用旧的再更新」的顺序保证了 811 行的判断用的是上一次的时长。
    self.currentlatchduration = 0
--★★ lastlatchtime = -math.huge —— 「从未锁定」的哨兵值。
--   ★★ 为什么用 -math.huge 而不是 0 或 nil？
--     811 行要算 `GetTime() > currentlatchduration + lastlatchtime`。
--     · 用 0：GetTime() 从世界创建起计时，可能已经很大（存档恢复的世界里更夸张），
--       首次访问时会**误判为「还在冷却中」** → LatchNode 永远不启动。
--     · 用 -math.huge：加任何有限数仍是 -inf，`GetTime() > -inf` 恒真 → 首次必定通过。
--     ★★ 这与 entityscript.lua:307 的 `movestoptime = -1` 是同类技巧，
--       但这里用 -math.huge 更彻底（对任意大的时长都成立）。
--   ★★ 这是本文件里最优雅的一处初始化。
    self.lastlatchtime = -math.huge
end)

--★★【LatchNode:Visit —— 「先判冷却，再执行」的简洁结构】
--   ★★ 【 它刻意不覆写 Reset —— 这是与所有其他节点最大的不同】
--     其他节点（Sequence/Selector/Loop/Random/Priority/Event）都覆写了 Reset，
--     因为它们有「必须归零的进度状态」（idx / rep / triggered）。
--     ★★ LatchNode 的 lastlatchtime（806 行）是**跨 Reset 必须存活**的状态：
--       若被 Reset 清掉，冷却期就失效 → 每帧都能触发 → 限流失效。
--     ★★ 这正是 171 行的推论所说的：
--       「Reset 只改 status，不动自定义字段 —— 这可以是有意的粘性」。
--     ★★ 对照 WaitNode：它也没有覆写 Reset，wake_time 同样跨 Reset 存活。
--       ★★ 两个「计时类节点」都不覆写 Reset，
--         而所有「进度类节点」都覆写 —— 这是一条清晰的分类线。
--   ★★ 结构上只有两段：READY 时判冷却（810-821），RUNNING 时执行（823-826）。
--     ★★ 与 ConditionWaitNode（247 行）对比：后者的 fn 返回真就 SUCCESS，
--       而 LatchNode 是「时间到了就 RUNNING 并执行」—— 语义完全不同。
function LatchNode:Visit()
--★★ `if self.status == READY then` —— 只在未运行时判冷却。
--   ★★ 用 READY 而非 `~= RUNNING`（对比 WaitNode:286）：
--     两者在此处等价（因为非 READY 的状态只有 RUNNING，
--     SUCCESS/FAILED 会被下一轮 Step Reset 回 READY），
--     但写法不同。
--     ★★ 若某帧 status 是 SUCCESS 且 Step 尚未执行，
--       WaitNode 会把它当「新开始」重新计时，
--       LatchNode 则什么都不做（保持 SUCCESS 直到 Step 复位）。
--       ★ 差异极小（最多一帧），但说明两个「等待类节点」是独立编写的。
    if self.status == READY then
--★★【冷却判定 —— LatchNode 的全部智慧所在】
--   `if GetTime() > self.currentlatchduration + self.lastlatchtime then`
--   ★★ 【 为什么用「严格大于」而非「大于等于」】
--     「解锁时刻」= 上次锁定时刻 + 上次锁定的时长。
--     ★★ 严格大于意味着「恰好等于解锁时刻时**还不能进」**，
--       要等一帧之后。★ 这与 WaitNode:292 行的 `>=` 正好相反 ——
--       两者对「边界时刻」的处理不一致。
--     ★ 实际影响微乎其微（只差一帧），但值得注意这是两处独立实现。
--   ★★ 【 关键设计：currentlatchduration 在此处是「上一次的时长」】
--     看执行顺序：
--       811 行：用 currentlatchduration（**旧值**）算出解锁时刻
--       813 行：记录当前锁定时刻
--       814 行：更新 currentlatchduration 为**新值**
--     ★★ 所以「冷却时长」永远是「上一次用的那个时长」，
--       而不是「这一次想用的时长」。
--     ★★ 这是正确的 —— 你不可能用「未来的时长」来判断过去是否解锁。
--     ★★ 也正因如此，动态时长（FunctionOrValue）的效果是「延后一周期生效」，
--       第一次调用时 latchduration 是什么就锁多长，下次调用才算新值。
--   ★★ 806 行的 -math.huge 哨兵在此生效：
--     `-inf + 0 = -inf`，`GetTime() > -inf` 恒真 → 首次必定解锁。
        if GetTime() > self.currentlatchduration + self.lastlatchtime then
--※【被注释掉的调试打印】`--print("GONNA GO!", GetTime(), ...)`
--   ★★ 这行打印的内容极其有用：
--     GetTime()（当前时刻）、self.currentlatchduration（上次时长）、
--     `GetTime()+self.currentlatchduration`（假想的下次解锁时刻）、
--     `self.lastlatchtime`（上次锁定时刻）。
--   ★★ 排查「LatchNode 为什么不触发」时，取消注释这行能立刻定位。
--     注意它还把整个判定条件写进了打印：
--     `"----"` 后面就是 811 行的完整比较式。
            --print("GONNA GO!", GetTime(), self.currentlatchduration, "----", GetTime()+self.currentlatchduration, ">", self.lastlatchtime)
--★★ lastlatchtime = GetTime() —— 「本次锁定从此刻开始」。
--   ★★ 必须在 814 行更新 currentlatchduration **之前**执行，
--     因为 811 行的判定已经用完了旧值。
--   ★★ 这是「先判定、再更新」的两阶段模式的又一次运用
--     （与 WaitNode:287-288 的 wake_time 模式类似）。
            self.lastlatchtime = GetTime()
--★★ FunctionOrValue(latchduration, inst) —— 动态时长求值。
--   ★★ 与 WaitNode:287 的对比：
--     · WaitNode:   FunctionOrValue(self.wait_time)  ← 不传 inst
--     · LatchNode:  FunctionOrValue(self.latchduration, self.inst) ← 传 inst
--   ★★ LatchNode 多传了 inst，意味着时长函数可以写成：
--     `function(inst) return inst.components.combat:InCooldownTime() end`
--   ★★ 只有 LatchNode 传了 inst，WaitNode 的时长函数无法访问实体。
--     ★ 这是两个等待节点的一处 API 不一致（无害，但不对称）。
--   ★★ 重新求值的时机：只在「解锁成功的那一刻」（813-814 行的顺序保证）。
--     冷却期间不重复求值 —— 性能友好。
            self.currentlatchduration = FunctionOrValue(self.latchduration, self.inst)
--※【被注释掉的调试打印】`--print("New vals:", self.currentlatchduration, self.lastlatchtime)`
--   ★ 与 812 行配套：812 打「准备进」，815 打「已更新后的新值」。
            --print("New vals:", self.currentlatchduration , self.lastlatchtime)

--★★ status = RUNNING —— 「冷却结束，开始执行」。
--   ★★ 注意这里是**直接**转 RUNNING，不经过任何中间态。
--     于是 823 行紧随其后就会执行子节点 —— 同一个 Visit 内启动。
--   ★★ 与 ConditionWaitNode:251 的 RUNNING 语义对照：
--     那里 RUNNING 表示「还在等」，这里 RUNNING 表示「开始做了」。
--     ★★ 同样是 RUNNING，含义完全相反 —— 这是本文件最容易误读的一点。
--       看 status 时必须结合节点类型判断。
--   ★★ 转 RUNNING 的一个关键副作用：Step(161) 会保活本节点，
--     于是 806/813 行的 lastlatchtime 得以跨帧存活（Step 不重置字段）。
            self.status = RUNNING
--★ else 分支：还在冷却中 → FAILED。
        else
--★★【冷却中 → FAILED —— 让父节点去找别的分支】
--   ★★ 这是 LatchNode 作为「限流器」的核心行为：
--     放在 PriorityNode 里 → 冷却期间这个分支不可用，
--       PriorityNode 会去看下一个分支（598 行的循环）。
--       ★★ 典型用法：限流「每 3 秒最多攻击一次」，冷却期间去 Wander。
--     放在 Sequence 里 → 序列立刻中断，后续步骤都不做。
--   ★★ 【 与 ConditionWaitNode:251 的 RUNNING 形成关键对比】
--     ConditionWaitNode 冷却/等待中 → RUNNING（**卡住整棵树**）
--     LatchNode         冷却中 → FAILED（**让路，不卡树**）
--     ★★ 这是两者最重要的区别，也是 LatchNode 更安全的根本原因：
--       「我暂时不行」表达成 FAILED（可跳过）而不是 RUNNING（会卡住）。
--     ★★ 用 FAILED 表达「暂时不可用」在语义上并不精确
--       （FAILED 通常意味着「永久不行」），
--       但在这个「有优先级的扁平列表」框架里，
--       FAILED 的实际效果就是「跳过」，正是我们想要的。
--     ★★ 这也解释了为什么 DST 的 PriorityNode 用「FAILED 就找下一个」
--       而不是「RUNNING 就等」—— 因为 FAILED 才是「让路」的通用表达。
            self.status = FAILED
        end
    end

--★★【执行段 —— 与 WaitNode:291 / EventNode:755 结构同型】
--   `if self.status == RUNNING then`
--   ★★ 三个节点（WaitNode:291 / EventNode:755 / LatchNode:823）都是同一个模式：
--       「前置判定（可能把 status 改成 RUNNING）→ 若 RUNNING 则执行子节点」
--     ★★ 这是本文件里反复出现的一个「状态提升 + 立即执行」惯用法。
--     写成两个并列 if 而非 if/else，是为了复用同一段执行代码。
--   ★★ 本节点的子节点执行是**无条件**的（无短路），
--     因为 LatchNode 只有一个孩子，不存在选择问题。
    if self.status == RUNNING then
--★★ 无条件 Visit 唯一的孩子。
        self.children[1]:Visit()
--★★【状态透传 —— LatchNode 自己不维护任何执行状态】
--   `self.status = self.children[1].status`
--   ★★ 与 EventNode:759 完全同构：「我是子节点的壳」。
--   ★★ 【 但这里有一个与 EventNode 不同的重要后果】
--     LatchNode 的子节点返回 SUCCESS 后，LatchNode 也变 SUCCESS。
--       下一轮 Visit 时 810 行的 `status == READY` 不成立 → 什么都不做。
--       ★★ 要等到 Step(161) 把它 Reset 回 READY 才能再次判定冷却。
--     ★★ 而这恰恰是**正确且必要**的行为：
--       LatchNode 的 SUCCESS 表示「这次动作做完了」，
--       Step 会立刻 Reset 它（SUCCESS ≠ RUNNING），
--       下一轮重新走 810 行的冷却判定 → 810 行会算「还没到解锁时刻」→ FAILED。
--       ★★ 于是正确的循环形成了：
--         冷却中→FAILED → 冷却到→RUNNING→子节点跑→SUCCESS → Reset → 冷却中→...
--     ★★ 这个「冷却」实际上是由「上次锁定时刻 + 上次时长」在时间轴上保证的，
--       而不是靠状态机。所以即使中间跳过很多轮，冷却依然准确。
--   ★★ 注意：即使 LatchNode 的子节点返回 FAILED（做了但失败），
--     lastlatchtime 也已经更新（813 行在子节点执行之前），
--     ★★ 所以**失败的尝试也会消耗冷却**。
--       这通常是正确的（避免疯狂重试），但若子节点的 FAILED 是瞬时故障，就会浪费一个冷却周期。
        self.status = self.children[1].status
--★ Visit 函数结束。
--   ★★ 【 全文件在此结束 —— 最后一个符号是 LatchNode】
--   回顾本文件的结构（826 行）：
--     §零   状态常量（1-8）
--     §一   BT 外壳（12-47）
--     §二   BehaviourNode 基类（52-191）—— 生命周期与休眠协议
--     §三   装饰器基类（195-197）与条件类（202-253）
--     §四   动作与等待（259-299）
--     §五   组合节点：Sequence（304）/ Selector（340）
--     §六   装饰器：Not（378）/ FailIfRunning（395）/ FailIfSuccess（411）
--     §七   Loop（427）/ Random（484）
--     §八   ★★ Priority（533-638）—— 决策层的心脏，含 H1 缺陷
--     §九   Parallel（644-695）—— 中断的载体
--     §十   ★★ Event（702-765）—— 事件驱动，含第二处破坏性 Reset
--     §十一 语法糖：While（771）/ If（783）/ IfThenDoWhile（792）
--     §十二 Latch（801-826）—— 唯一的限流节点
--   ★★ 全文件最重要的三条结论：
--     ① 事件驱动 + 三段式（Visit → SaveStatus → Step）是理解一切的钥匙
--     ② 抢占与中断都靠「破坏性 Reset」实现，框架**没有**挂起/取消语义
--     ③ lasttime 是节流的唯一旋钮：period 控制频率，nil 表示「立即」
    end
end