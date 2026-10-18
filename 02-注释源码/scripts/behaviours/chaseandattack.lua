--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/chaseandattack.lua
-- 模块：行为树节点库 / 追击战斗
-- 职责：接管 combat.target 的所有权：READY 时校验/补索敌并战吼，RUNNING 时边压近边攻击，
--       并用 max_chase_time / give_up_dist / max_attacks 三个阈值中任一触发即终止，
--       另特判「目标站在无效地面（如海上）时只靠近到边缘」。
-- 关键符号：ChaseAndAttack, ChaseAndAttack:Visit, ChaseAndAttack:OnAttackOther,
--           ChaseAndAttack:OnStop, ChaseAndAttack:__tostring
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/combat.lua（ValidateTarget / SetTarget / TryAttack / BattleCry / GiveUp / CalcAttackRangeSq）,
--           components/locomotor.lua, stategraph（longattack / canrotate / running 状态标签）,
--           standandattack.lua（同结构的站桩版）, chaseandram.lua, chaseandattackandavoid.lua
--============================================================
ChaseAndAttack = Class(BehaviourNode, function(self, inst, max_chase_time, give_up_dist, max_attacks, findnewtargetfn, walk, distance_from_ocean_target)
--[[
-- chaseandattack.lua —— 追击并攻击节点（ChaseAndAttack）
--
-- 【本节点的定位：combat 组件的「看护者」】
-- 它不是自己算伤害，而是全程托管 self.inst.components.combat.target：
--   进门时校验/补索敌 → 出门时（SUCCESS/FAILED）必然清掉目标。
-- ★★ 这是全目录最重要的所有权约定：**谁进门谁负责关门**。
--   第 61/106 行 SUCCESS 时 SetTarget(nil)，第 58/112 行失败时 SetTarget(nil)/GiveUp()。
--   如果节点中途 return 或抛错而不清目标，combat.target 会残留，
--   导致下一次别的节点接管时面对一个陈旧目标（对应 bug-patterns 的悬挂状态类）。
--
-- 【六个可调阈值/开关 —— 全参数化节点的典范】
--   max_chase_time          —— 最长追击秒数（nil = 不限时）
--   give_up_dist            —— 目标跑多远就放弃（nil = 不因距离放弃）
--   max_attacks             —— 打中几次就收手（nil = 不限次数）
--   findnewtargetfn         —— 无目标时的补索敌回调
--   walk                    —— true 则只走路不跑
--   distance_from_ocean_target —— 目标在海上时的「靠边距离」
-- ★ 三个终止阈值全部可独立置 nil，这个设计让同一节点能复用为
--   「攻击到底」「打一下就走」「追到就跑掉」等多种行为，无需派生新类。
--   移植要点：把「行为差异」表达成参数默认值，而不是复制类。
--]]
    BehaviourNode._ctor(self, "ChaseAndAttack")
    self.inst = inst
    self.findnewtargetfn = findnewtargetfn
    self.max_chase_time = max_chase_time
    self.give_up_dist = give_up_dist
    self.max_attacks = max_attacks
    self.numattacks = 0
    self.walk = walk
    self.distance_from_ocean_target = distance_from_ocean_target

    -- we need to store this function as a key to use to remove itself later
--★★ 原注释：我们需要把这个函数存成 key，以后才能反注册。
--   这是 DST 的硬约束：ListenForEvent 的第二个参数是**函数对象**，
--   RemoveEventCallback 用同一函数对象做匹配。
--⚠️ 如果这里写成匿名函数直接传给 ListenForEvent，OnStop 就永远摘不掉。
--   所以必须存成 self.onattackfn。这是「注册即必须存句柄」铁律的实例。
    self.onattackfn = function(inst)
--★ 回调忽略 inst 参数（框架会把事件源传进来，这里用不上）。
--   转发给节点方法而不是把逻辑写在闭包里 —— 便于子类覆写与调试。
        self:OnAttackOther()
    end

    self.inst:ListenForEvent("onattackother", self.onattackfn)
--★★ 同时监听 onattackother（打中）与 onmissother（打空）。
--★ 为什么「打空」也算一次攻击？因为战斗节奏上挥空一次同样是「尝试过」，
--   若只计命中，长攻（miss 概率高）的单位会无限追下去。
--   ⚠️ 副作用：numattacks 会把挥空也计入 max_attacks，
--     所以 max_attacks 的真实语义是「攻击尝试次数」而非「命中次数」。
--     源码变量名 numattacks 与第 104 行的比较都印证了这一点，读参数时别误读。
    self.inst:ListenForEvent("onmissother", self.onattackfn)
end)

function ChaseAndAttack:__tostring()
--★ __tostring：Lua 自动调用。tostring(node) 会走到这里，
--   被 behaviourtree.lua 的 GetTreeString 用来显示节点。
--★ 显示 combat.target 而非 self.inst：追打节点调试时最想知道的是「在追谁」。
    return string.format("target %s", tostring(self.inst.components.combat.target))
end

function ChaseAndAttack:OnStop()
--★★ OnStop —— 本节点唯一的资源释放点。
--   调用链：brain 停止 → bt:Stop() → BehaviourNode:Stop 递归全树 → 每个节点的 OnStop。
--⚠️★ 关键区别（behaviourtree.lua:287-298 的注释也强调了这点）：
--   Reset **不会** 调 OnStop —— 也就是说行为「跑完一次又重来」时，
--   下面两行不会执行，监听一直挂着。
--   ★★ 实际风险：若上层反复重建这棵 bt 而不 Stop 旧的，
--     每建一次就多挂一对监听，numattacks 会被重复累加。
--     移植时务必确认：重建行为树前先 Stop 旧的。
    self.inst:RemoveEventCallback("onattackother", self.onattackfn)
    self.inst:RemoveEventCallback("onmissother", self.onattackfn)
end

function ChaseAndAttack:OnAttackOther()
--★★ OnAttackOther：每次攻击尝试都做两件事。
--   ① numattacks += 1
--   ② startruntime = nil —— ★ 把追击计时器**清空**（而不是重置为当前时间）。
--★★ 为什么是置 nil 而不是 startruntime = GetTime()？
--   因为置 nil 后，下一帧 Visit 的第 98-100 行会走「startruntime == nil」分支，
--   重新打点并战吼。这样做的实际效果是：
--     **计时器统计的是「距上一次攻击的静默时长」，而非「总追击时长」**。
--   ★★ 这是本节点最容易被误读的语义：max_chase_time 不是「最多追 10 秒」，
--     而是「连续 10 秒打不到人就放弃」。只要一直在打，可以追一辈子。
--   移植要点：把超时定义成「静默超时」而非「总时长」，能天然避免
--     「打得顺的追击者被硬性截断」这种不合理的上限。
    --print ("on attack other", target)
    self.numattacks = self.numattacks + 1
    self.startruntime = nil -- reset max chase time timer
end

function ChaseAndAttack:Visit()
--★★ Visit —— 本节点的核心。结构：READY 段决定能否开打，RUNNING 段驱动并终止。
--   ★ 与 follow 相同的「顺序双 if」写法：READY 段把 status 置 RUNNING 后，
--     同一次调用立刻进入 RUNNING 段执行第一帧动作，不浪费一帧。
    local combat = self.inst.components.combat
    if self.status == READY then
--★★ 先 ValidateTarget：把 combat.target 重新校验一遍。
--   ★ 必要性：brain 可能休眠了很久才被唤醒，期间 target 可能早已无效；
--     不校验就直接 SetTarget(nil) 是安全的，先校验则可能保住一个仍然有效的目标。
--   ※ 这一步是 combat 组件与行为树之间的「同步点」，属于协作式共享状态的代价。
        combat:ValidateTarget()

        if combat.target == nil and self.findnewtargetfn ~= nil then
--★ 只有「确实没目标」时才用 findnewtargetfn 补。
--⚠️ 注意 findnewtargetfn(self.inst) 的返回值直接交给 SetTarget，
--   未做非 nil 检查。若该函数返回 nil，SetTarget(nil) 是安全的，
--   下一行 target ~= nil 判断会走 FAILED 分支 —— 容错正确。
            combat:SetTarget(self.findnewtargetfn(self.inst))
        end

        if combat.target ~= nil then
--★★ 有目标才真正「开打」：战吼 + 打起始时间 + 进入 RUNNING。
--★ BattleCry：播放战吼音效/动作，是给玩家的行为预告（可读性设计）。
--   ⚠️ 注意 numattacks 在这里被重置为 0 —— 因为它统计的是「本次追击的攻击次数」，
--     与构造时的初值是两回事。
            self.inst.components.combat:BattleCry()
            self.startruntime = GetTime()
            self.numattacks = 0
            self.status = RUNNING
        else
            self.status = FAILED
--★ 没有目标且补索敌也失败 → FAILED，让父节点去试下一个分支。
        end
    end

    if self.status == RUNNING then
--★★ RUNNING 段入口。注意用的是 `not combat.target.entity:IsValid()`，
--   走的是 entity 而非 combat.target:IsValid() —— 与 follow 的写法不同，
--   但两者对 combat.target（一个 entity）而言等价。
        if combat.target == nil or not combat.target.entity:IsValid() then
--★★ 目标消失 → FAILED + 清目标 + 停止移动。三件事必须一起做：
--   只改 status 不清 target，combat.target 会残留（见文件头「所有权」说明）。
--   只清 target 不 Stop locomotor，怪物会一直滑行。
            self.status = FAILED
            combat:SetTarget(nil)
            self.inst.components.locomotor:Stop()
        elseif combat.target.components.health ~= nil and combat.target.components.health:IsDead() then
--★★ 目标已死 → **SUCCESS**（不是 FAILED）。
--★ 语义正确：把敌人打死就是「追击并攻击」这个行为的成功达成。
--★ 移植要点：SUCCESS/FAILED 的划分标准是「行为的意图是否达成」，
--   不是「过程有没有出错」。目标死了是意图达成，故 SUCCESS。
--⚠️ 与第 104 行 max_attacks 达到上限时的 SUCCESS 区分开：
--   两者都是 SUCCESS，但语义不同 —— 一个是「打完收工」，一个是「够数了收工」。
--   对父节点而言可能需要区分，那就该拆成两个节点。
            self.status = SUCCESS
            combat:SetTarget(nil)
            self.inst.components.locomotor:Stop()
        else
            local target_position = Point(combat.target.Transform:GetWorldPosition())
--★ 目标点、朝向点、自己位置三件套。facing_point 单独保留是因为
--   第 74-82 行会改写 target_position（避让海洋），但**朝向仍要面向真实目标**。
--   ★ 这种「移动目标点」与「朝向目标点」分离的写法值得抄：
--     走位可以绕开障碍，但头/身体朝向仍应指向目标，玩家才看得懂它在打谁。
            local facing_point = target_position
            local me = Point(self.inst.Transform:GetWorldPosition())

            local dsq = distsq(target_position, me)
--★ distsq 求平方距离。与 follow 一样全程避免 sqrt。

            local running = self.inst.components.locomotor:WantsToRun()
--★ WantsToRun：读 locomotor 当前**意图**是否在跑（不是实际速度）。
--   ★ 用它而非「是否移动」来决定起跑距离阈值（第 86 行），
--     可以让「正在滑行减速」的过程保持跑步决策不反复横跳。
            --local angle = self.inst:GetAngleToPoint(target_position)

            if self.distance_from_ocean_target ~= nil and dsq > combat:CalcAttackRangeSq() and not combat.target:IsOnValidGround() then
--★★【海洋规避】三个条件同时成立才触发，很值得逐条看：
--   ① 传了 distance_from_ocean_target  （启用该特性）
--   ② dsq > CalcAttackRangeSq()          （现在够不着，必须先靠近）
--   ③ not IsOnValidGround()              （目标脚下不是可站立地面，如浮冰外）
--★ 第 ② 条的必要性：若已经够得着，就没必要为「靠边」而多走几步。
--   这避免了「明明能打到却绕路」的滑稽表现 —— 属于「优化只在必要时生效」。
--★ 第 ③ 条用 IsOnValidGround 而非 IsOnOcean：前者更通用，
--   任何「地面无效」的情形（空洞、虚空、特殊地格）都适用。
                local reverse_direction = me - target_position
--★ 反方向向量：自己减去目标 = 指向自己的一侧。
--   接下来要在这条线上往前推 ocean_distance，即「朝远离海的方向站定」。
                local rd_normal_x, rd_normal_z = VecUtil_Normalize(reverse_direction.x, reverse_direction.z)
--★ VecUtil_Normalize 二维归一化（只用 x/z，忽略 y）。
--   为什么忽略 y：逃跑方向是水平面上的决策，y 会把方向拉歪（目标在山上时尤其明显）。

                local ocean_distance = FunctionOrValue(self.distance_from_ocean_target, self.inst, combat.target)
--★ 同样是「值或函数」参数，且**多传了目标实体**作为第二参：
--   FunctionOrValue(fn, inst, target) → fn(inst, target)。
--★ 移植要点：阈值函数可以拿到目标，从而做「按目标体型决定距离」这类逻辑。
                target_position = Point((rd_normal_x * ocean_distance) + target_position.x, target_position.y, (rd_normal_z * ocean_distance) + target_position.z)
--★ 把目标点沿「远离自己」方向平移 ocean_distance，作为新的移动目的地。
--   ⚠️ 第 80 行随即重算 dsq —— 必须重算，否则后面第 86/109 行的距离判断
--     会用旧值，导致「明明还没到位就开打」或「明明够得着却继续追」。
--   ★ 这一行是很典型的「改了坐标就必须同步改距离」的纪律，漏掉就是一个难查的 bug。
                dsq = distsq(target_position, me)
                --angle = self.inst:GetAngleToPoint(target_position)
            end

            if not self.inst.sg:HasStateTag("longattack") then
--★★ 【长攻豁免】`if not HasStateTag("longattack")` 整块跳过。
--★ 语义：正在放长攻/必杀技时，不许移动也不许普通攻击 —— 把控制权完全让给 stategraph。
--★ 移植要点：把「特殊动作期间禁止普通行为」做成状态标签，
--   比在每个节点里 if 某动作 is nil 判更解耦。
--⚠️ 副作用：豁免期间第 104-115 行的终止判定**仍会执行**（在 if 之外），
--   这是对的 —— 即使在放大招，目标死了也该立刻结束。
                local r = self.inst:GetPhysicsRadius(0) + combat.target:GetPhysicsRadius(-.1) + .1
--★★ 物理半径之和 + 0.1 余量，作为「贴身距离」。
--   r = 自己的碰撞半径 + 目标的碰撞半径(收缩 10%) + 10cm
--★ 比直接用 attackrange 更好：碰撞半径随体型变化，
--   所以大体型单位会自然地贴得更近，不会「隔空攻击」也不需要按体型调参。
--⚠️ 目标的半径用 -0.1 收缩：留一点缝隙，避免两个碰撞体重叠导致的物理抖动。
                if (running and dsq > r * r) or (not running and dsq > combat:CalcAttackRangeSq()) then
--★★ 二选一的起跑阈值：
--   正在跑 → 用物理半径 r（贴身距离，跑过去刚好刹住）
--   没在跑 → 用 combat:CalcAttackRangeSq()（攻击范围，跑不划算）
--★ 这个分叉的思路与 follow 第 137 行的 .75 完全一致：
--   「运动状态」决定用哪套阈值。跑步需要更早进入贴身区间，因为刹车距离更长。
--   ★★ 两个独立节点不约而同用了同一个招，进一步说明这是 DST 的通用手法。
                    --self.inst.components.locomotor:RunInDirection(angle)
                    self.inst.components.locomotor:GoToPoint(target_position, nil, not self.walk)
                elseif not (self.inst.sg ~= nil and self.inst.sg:HasStateTag("jumping")) then
--★ 除非正在跳跃，否则停下移动 —— 到位后不贴身徘徊。
--★ 跳跃豁免：滞空时强行 Stop locomotor 会打断跳跃状态图的位移。
--★ 呼应第 84 行：stategraph 的特殊状态拥有对移动的控制权。
                    self.inst.components.locomotor:Stop()
                    if self.inst.sg:HasStateTag("canrotate") then
--★ 只有「允许转身」的状态才转向 —— 攻击动作本身通常已锁定朝向。
--   再转会把攻击动画朝向扭到别处，是很常见的「攻击打空朝向」bug 根因。
                        self.inst:FacePoint(facing_point)
                    end
                end

                if combat:TryAttack() then
--★★ `if combat:TryAttack() then` —— 空的 then 分支，原注释写明
--   "reset chase timer when attack hits, not on attempts"。
--   实际重置不在这里，而在第 33 行（事件回调 OnAttackOther 里）。
--★★ 为什么这里什么也不做？两个原因：
--   ① 攻击**失败**不代表没出手（可能还在冷却/距离不够），
--      若在这里重置计时器，站着不动刷攻击失败也会无限续命。
--   ② 真正的「出手」由 onattackother/onmissother 事件统一通知，
--      不依赖节点自己判断 —— 单一事实来源，避免两处逻辑打架。
--★ 移植要点：宁可写一个空分支并说明原因，也不要留一段让人猜的代码。
                    -- reset chase timer when attack hits, not on attempts
                elseif self.startruntime == nil then
--★★ 计时器兜底：startruntime 为 nil 时（即第 33 行刚被清空过）重新打点。
--   这就是第 30-33 行置 nil 的**配套消费点**，两处必须成对存在。
--★ 移进这个分支（第 84 行的 if 内部）是有意的：
--   只有「正常战斗中」才需要追击计时器。豁免期间不打点。
--⚠️ 若只改第 33 行不改这里，max_chase_time 会永久失效（startruntime 恒为 nil）。
                    self.startruntime = GetTime()
                    self.inst.components.combat:BattleCry()
                end
            end

            if self.max_attacks ~= nil and self.numattacks >= self.max_attacks then
--★★【终止一】攻击次数用尽 → SUCCESS + 清目标 + 停止 + 立即 return。
--★ 用 return 而非继续往下走：状态已终结，本次 Visit 的剩余逻辑不该再执行。
--★ 「打够次数就收手」的典型用途：控制单次攻击行为的输血量/仇恨总量。
                self.status = SUCCESS
                self.inst.components.combat:SetTarget(nil)
                self.inst.components.locomotor:Stop()
                return
            elseif (self.give_up_dist ~= nil and dsq >= self.give_up_dist * self.give_up_dist)
--★★【终止二】两个放弃条件 or 在一起：
--   ① give_up_dist：目标跑太远（dsq >= give_up_dist²）
--   ② max_chase_time：距上次攻击静默超时（GetTime() - startruntime > max_chase_time）
--★★ 第 110 行必须再判 `self.startruntime ~= nil`：
--   因为第 33 行会把它置 nil。若不判，GetTime() - nil 会**运行时抛错**（算术操作 nil）。
--   这是「nil 既是合法值就必须防御」的典型位置。
--★ 判定用 FAILED 而非 SUCCESS：放弃 = 意图未达成，语义正确。
--★ 用 GiveUp() 而不是 SetTarget(nil)：GiveUp 还会清掉仇恨来源，
--   避免「A 放弃 B，B 又吸引 A」的死循环（见 combat.lua 的 GiveUp 说明）。
--★ 第 113 行 Stop 后 return：终止后不再 Sleep(.25)，本帧结束。
                    or (self.max_chase_time ~= nil and self.startruntime ~= nil and GetTime() - self.startruntime > self.max_chase_time) then
                self.status = FAILED
                self.inst.components.combat:GiveUp()
                self.inst.components.locomotor:Stop()
                return
            end

            self:Sleep(.125)
--★★ self:Sleep(.125) —— 追击期间每 0.125 秒醒一次（每秒 8 次）。
--★ 比 follow 的 .25 更快，因为战斗需要更灵敏的出手机会。
--★★ 这行注释同时说明了「节点休眠」的两个层面：
--   ① 帧内节流：0.125 秒内不重复跑 Visit。
--   ② 大脑休眠：GetSleepTime 把这个值上报，brain 可能进入 Hibernate（零开销）。
--★ 移植要点：数值是「决策频率 × 反应速度」的折中。
--   调小的直接后果是 CPU 线性上升 —— 这正是 AI 性能调优的第一个旋钮。
        end
    end
end