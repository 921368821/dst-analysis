--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/faceentity.lua
-- 模块：行为树节点库 / 朝向
-- 职责：把实体转向某个目标实体（一次性动作，无参数化阈值），用于「说话时看着对方」。
-- 关键符号：FaceEntity, FaceEntity:Visit, FaceEntity:HasLocomotor
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：standandattack.lua（同样用 canrotate 状态标签）
--============================================================
FaceEntity = Class(BehaviourNode, function(self, inst, getfn, keepfn, timeout, customalert)
--[[
-- faceentity.lua —— 注视节点（FaceEntity）：站在原地盯着某个实体看一段时间
--
-- 【★ 它是本目录的「表演类」节点，与 talker/chattynode 同族】
-- 不影响战斗、不影响移动，只改变「朝向」与「状态图状态」。
-- 典型场景：NPC 与玩家对话时看着对方、警戒时盯着入侵者。
-- ★★ 这类「表演」AI 的价值在于**可读性**：
--   玩家能从「它是否在看我」判断它的意图（对话中 / 警戒中 / 无视我）。
-- ★ 移植建议：游戏的 AI 不只要「会动」，还要「会表演意图」。
--   朝向是最便宜、最高效的意图表达手段。
--
-- 【★ 与 standstill 的对照 —— 两个「站着不动」的节点】
--   faceentity  —— 站着 + **朝某目标转身** + 可切状态 + 有超时
--   standstill   —— 站着 + 不转身 + 两个回调判断进出
-- ★ 两者共同点：**每帧（或每 0.5 秒）重申 locomotor:Stop()**。
-- ★★ 这是防漂移的关键：别的节点可能发出移动指令，本节点每帧把它停掉。
--]]
--★★ 6 个形参，其中两个是回调（getfn / keepfn），一个是超时，一个是状态名。
--★★ getfn / keepfn 的分工（与 panicandavoid 的 findavoidanceobjectfn 同款设计）：
--   getfn  —— 「看谁」：进场时问一次
--   keepfn —— 「还该不该看」：每帧问，直到它说停
-- ★★ 这种「进入条件回调 + 维持条件回调」的组合是本目录的通用模式：
--   · controlminions      用组件计数代替 keepfn
--   · useshield          用 ShouldShield / TimeToEmerge 代替
--   · findflower         用 CanPollinate 代替
--   ★ 移植建议：给「持续型行为」提供 keepfn 回调，
--     让调用方无需写自定义节点就能定义退出条件。
    BehaviourNode._ctor(self, "FaceEntity")
    self.inst = inst
    self.getfn = getfn
    self.keepfn = keepfn
    self.timeout = timeout
    self.starttime = 0
--★ starttime 初值 0（只在 READY 段被赋实际值，第 27 行）。
    self.target = nil
    self.customalert = customalert
end)

function FaceEntity:HasLocomotor()
--★★ 抽成独立方法的能力探测 —— 与 controlminions 第 67 行的判空同款。
--★ 「只需要知道有没有 locomotor，不需要操作它」的场景，
--   抽个方法是好习惯（语义清晰、可复用）。
-- ★★ 对照 standandattack 第 67 行：那里是 `if locomotor then` 内联判断，
--   因为需要用到 Stop；本文件只需探测，故抽方法更合适。
    return self.inst.components.locomotor ~= nil
end

function FaceEntity:Visit()
--★★ Visit：顺序双 if。
    if self.status == READY then
--★ READY 段：问「看谁」，有就 RUNNING，无就 FAILED。
        self.target = self.getfn(self.inst)
--★ getfn(inst) —— 目标可能是实体，也可能是别的回调结果。
--★ 缓存到 self.target 供 RUNNING 段使用（不重复调用回调）。
-- ★★ 「进入时解析一次、之后用缓存」是正确做法：
--   若每帧调用 getfn，目标可能中途变化，导致 AI 视线游移不定。

        if self.target ~= nil then
--★ 有目标才继续。
            self.status = RUNNING

            if self:HasLocomotor() then
--★ 有 locomotor 就停下 —— 「站定」。
--★★ 站定是本节点的基本姿态；但第 54 行的每帧重申同样重要（见该行）。
                self.inst.components.locomotor:Stop()
            end

            self.starttime = GetTime()
--★ 记录起始时刻，供第 43 行的超时判定。
        else
            self.status = FAILED
        end
    end

    if self.status == RUNNING then
--★★ RUNNING 段：三件事（切状态 / 超时 / 转身），顺序固定。
        --uhhhh....
--★ 原注释保留：uhhhh....（作者对这段逻辑的无奈吐槽）。
--★★★ 这条吐槽式注释很有价值 —— 它暗示第 35-41 行这段代码连作者自己都不满意，
--   却因历史原因保留着。
-- ★ 移植建议：这类「我也不确定这写得对」的注释，
--   比若无其事地留着代码有用得多 —— 它提醒后人不要盲目信任。
        if self.inst.sg:HasStateTag("idle") and not self.inst.sg:HasStateTag("alert") and self.inst.sg.sg.states.alert then
--★★★★★【状态图切换 —— 本文件最容易看不懂的一段】
-- 三个条件同时成立才切换：
--   ① HasStateTag("idle")    —— 当前处于待机
--   ② 不 HasStateTag("alert")—— 当前不是警戒
--   ③ sg.sg.states.alert 存在—— 这个状态图**定义过** alert 状态
--
-- ★★★ 条件 ③ 是关键，也是最容易被误读的地方：
--   `self.inst.sg.sg.states.alert` 是在查「状态图**定义表**里有没有 alert」，
--   不是查「当前是不是 alert」。
--   · sg       是 StateGraph 实例（有 currentstate、HasStateTag 等）
--   · sg.sg    是 StateGraph **定义**（有 states 表，列出所有可切换状态）
-- ★ 为什么要查这个？因为不同实体的状态图里 alert 状态可能不存在
--   （比如某些生物没有警戒状态）。切到不存在的状态会崩溃。
-- ★★ 这是一层很重要的防御：**不要假设状态图里有某个状态**。
-- ★ 移植建议：切换状态前先确认目标状态存在，是通用的安全实践。
--★ 语义：处于待机且不忙警戒 → 说明「现在允许切换」→ 切到 alert。
-- ★ 即「站着看人」这个行为，在状态图里表现为「警戒」状态，
--   从而触发警戒的动画/音效 —— 表演与状态机在此联动。
            if self.customalert and self.inst.sg.currentstate.name ~= self.customalert then
--★★ customalert 分支：调用方指定了自定义警戒状态名就用它。
--★ 条件多一层 `and self.inst.sg.currentstate.name ~= self.customalert`
--   —— 防止重复切到同一个状态（防抖）。
--★★ 对比第 38 行的默认分支：那里**也有**同样的防抖检查。
--   两处写法对称，是刻意的。
-- ★ 移植要点：**每次 GoToState 前都检查「已经不在这个状态了」**，
--   是避免状态机抖动的标准做法（与 follow 的 sticky 思路同源）。
                self.inst.sg:GoToState(self.customalert)
--★ GoToState(customalert) —— 切到调用方指定的状态。
--⚠️ 注意：这里**没有**再检查 self.inst.sg.sg.states[self.customalert] 是否存在，
--   而第 35 行只验证了 states.alert。
--   ★ 若调用方传了一个未定义的状态名，这里会出错。
--   ⚠️【疑似风险】已核实第 35 行的条件只检查 states.alert，
--     未检查 states[self.customalert]。属「信任调用方」的取舍。
            elseif self.inst.sg.currentstate.name ~= "alert" then
--★ 默认分支：切到标准的 "alert" 状态（第 39 行执行）。
--★ 第 35 行已保证 states.alert 存在，这里是安全的。
                self.inst.sg:GoToState("alert")
            end
        end

        if self.timeout ~= nil and GetTime() - self.starttime > self.timeout then
--★★ 超时 → SUCCESS + return。
--★★★ 【★ 成功语义的重要澄清】
--   「超时」为什么是 **SUCCESS** 而不是 FAILED？
--   ★ 因为本节点的意图是「看够 N 秒」，而不是「一直看到某条件」。
--   看到时间够了 = 意图达成 = SUCCESS。
-- ★★★ 这与 runtodist 第 104-105 行形成绝妙对照：
--   runtodist 「没能跑到安全距离」→ FAILED（意图未达成）
--   faceentity 「看够了时间」   → SUCCESS（意图已达成）
--   ★★★ 两个节点都是「超时」触发，终态却相反。
--   ★★ 原因：faceentity 的**意图本身包含时长**（「看 3 秒」），
--     所以时间是成功条件；runtodist 的意图是「到达某位置」，
--     3 秒只是防卡死的兜底，不是成功条件。
-- ★★★★ 移植要点：判定终态时问「这个条件是意图的一部分，还是兜底？」
--     是意图 → 达成即 SUCCESS；是兜底 → 未达成即 FAILED。
--   ★ 这是本目录里关于 SUCCESS/FAILED 语义最精妙的一组对照，值得反复读。
--★ 第 45 行的 return：超时后不再执行第 48-54 行。
            self.status = SUCCESS
            return
        end

        if not (self.target ~= nil and self.target:IsValid() and self.keepfn(self.inst, self.target)) then
--★★★ 维持条件检查：目标还在、还有效、keepfn 仍说该看。
--★ 三重与，任一不满足即 FAILED。
--★ 与 doaction 第 53 行的「动作对象失效」是同类兜底：
--   跨帧存活的行为必须每帧复检外部世界。
-- ★ keepfn(inst, target) —— 注意传了 target，可让调用方做「看着这个人」的具体判断。
            self.status = FAILED
        elseif self.inst.sg:HasStateTag("canrotate") then
--★ 维持中 → 朝目标转身。
--★★★ `HasStateTag("canrotate")` 是必需的守卫：
--   与 chaseandattack 第 91 行、standandattack 第 70 行、
--   chaseandram 第 101/117 行完全一致。
-- ★★★★ 这是本目录出现次数最多的守卫（约 6 处），值得单独记住：
--   **行为树永远不与状态图争夺「什么时候允许转向」的控制权**。
--   攻击动画、冲锋动画都有自己的朝向，强行转动会把动画扭歪。
-- ★ 移植建议：建立「状态标签 = 能力许可」的约定，
--   行为树只在被允许时才动。这比自己维护布尔标志可靠得多。
            self.inst:FacePoint(self.target.Transform:GetWorldPosition())
--★ FacePoint 取目标的当前位置并转向。
--★ 每 0.5 秒转一次（第 54 行节流），足以跟上目标的移动。
        end

        self:Sleep(.5)
--★★★ self:Sleep(.5) —— 每 0.5 秒转身一次，是本目录**第二慢**的节拍。
--★ 谱系回顾：
--   .1   avoidlight（避光要实时）
--   .125 战斗类四件套
--   .25  移动类（follow/approach/runaway/panic）
--   .5   faceentity / standstill ← 本文件
--   1    attackwall
-- ★ 为什么 .5 秒够用？因为「转身」是慢动作，不需要高频。
--   ★★★ 移植要点：节拍频率应匹配**行为的变化速度** ——
--     转身是渐进的（角色转向本身有插值），0.5 秒一次的指令完全够；
--     而「该往哪跑」的变化快（目标在动），就需高频。
--★ ★★ 对照 standstill 第 28 行同样是 .5 秒 ——
--   两个「站着不动」类节点共享同一个节拍，符合「同族同参数」的规律。
    end
end