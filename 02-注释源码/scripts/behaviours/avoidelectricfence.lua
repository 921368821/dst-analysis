--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/avoidelectricfence.lua
-- 模块：行为树节点库 / 避让
-- 职责：躲避电栅栏（海象/巨鹿的电网）：检测到处于电栏范围时朝安全方向奔跑，
--       含 GetRunAngle 的方向逃逸计算与 OnStop 清理。
-- 关键符号：AvoidElectricFence, AvoidElectricFence:Visit, AvoidElectricFence:GetRunAngle,
--           AvoidElectricFence:OnStop, AvoidElectricFence:__tostring
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：runaway.lua, panicandavoid.lua, components/locomotor.lua
--============================================================
local function onelectrocute(inst)
--[[
-- avoidelectricfence.lua —— 躲避电栅栏节点（AvoidElectricFence）
--
-- 【★★★ 本文件是全目录最短、最纯粹的「事件驱动型节点」】
-- 它的逻辑核心只有两行：
--   · 事件回调里算出逃跑角度（第 13-16 行）
--   · RUNNING 时朝那个角度跑（第 69 行）
-- 没有参数、没有阈值、没有状态机 —— 因为「往哪跑」在事件发生的瞬间就确定了。
-- ★★ 与 useshield 的对比：useshield 需要持续判断「要不要防御」，
--   而本节点是「电栅栏建好了 → 立刻决定往哪跑 → 跑完就结束」。
--   ★ 移植要点：一次性决策的节点可以极简；
--     复杂度只来自「要判断什么」，不来自「怎么维持」。
--]]
--★★ 局部函数 onelectrocute —— 被电击时的通用回调。
--★★ 只做一件事：inst.brain:ForceUpdate()（把大脑从休眠中强行唤醒）。
--★ 与 useshield 第 28 行是完全相同的机制与理由（详见那边的详解）：
--   电击状态由 stategraph 驱动，不由行为树驱动；
--   若大脑此刻在 Hibernate，它就永远看不到状态结束 → 卡死。
--★ 本文件用了**模块级共享回调**（而非每个实例一个闭包），
--   与 chaseandattack/useshield 的「self.xxxfn 存句柄」不同：
--   优点 —— 无论创建多少个实例，只注册一份函数对象；
--   ★★★ 重要推论：因为函数对象相同，RemoveEventCallback 能用同一个
--     `onelectrocute` 引用摘除（第 23 行），无需存到 self 上。
--   ★ 移植要点：回调若不需要捕获实例状态，就用模块级函数 ——
--     省内存，且省掉「存句柄以便反注册」的样板代码。
    inst.brain:ForceUpdate() --TODO Can we move this to shocked_by_field?
--★ 原注释：TODO Can we move this to shocked_by_field?
--   翻译：「TODO：能否把这个挪到 shocked_by_field 里去？」
--★ 这条 TODO 记录了一个**未完成的优化意图**：
--   两个事件（startelectrocute / shocked_by_new_field）都能触发逃跑，
--   但只有后者会算出方向（第 14 行）。若把 ForceUpdate 也挪过去，
--   则「已被电击但没有新电栏」的情况就不会被唤醒。
--★ 所以作者自己也不确定这个改动是否安全 —— 保留现状是对的。
-- ★★ 移植要点：跨系统事件的去重要谨慎。
--   看起来重复的两次唤醒，可能各自覆盖不同场景（如本例）。
end

AvoidElectricFence = Class(BehaviourNode, function(self, inst)
--★★ 构造器零参数 —— 完全不可配置（对照 follow/wander 的高度参数化）。
--★ 合理：电栅栏的逃跑方向由几何决定，没有可调阈值。
    BehaviourNode._ctor(self, "AvoidElectricFence")
    --
--★ 单独的注释行 `--`（不是空行也不是代码）—— 源码里的分隔符习惯。
--★ 纯风格：本文件多处用裸 `--` 把构造器切成逻辑块，便于阅读。
--★ ★ 移植建议：这类分隔符在长构造器里很有用，
--     比空行更醒目地标出「接下来是另一个方面」。
    self.inst = inst
    self.run_angle = nil
--★ run_angle 初值 nil —— 「还没有逃跑方向」。
--★ 第 60 行用它作为进入 RUNNING 的前提（`if self.status == READY and self.run_angle`）。
--★★ 即「没有方向就什么都不做」= FAILED 语义（虽然没显式写 FAILED）。
--   对比 chaseandattack 的 `if combat.target ~= nil then ... else FAILED end`，
--   本节点更简洁：直接用条件短路，不满足就什么都不写，
--   而 status 保持 READY → 父节点（Selector）会自然去试下一个分支。
-- ★ 移植要点：「什么都不做」与「显式写 FAILED」对 Selector 等价，
--   前者更简洁，但调试输出里会显示 READY 而非 FAILED，排障时要留意。
    --
    inst._has_electric_fence_panic_trigger = true --used by BrainCommon.HasElectricFencePanicTriggerNode
--★★★ 在实体上挂一个「标记字段」，供**外部查询本节点是否启用**：
--   inst._has_electric_fence_panic_trigger = true
--   原注释：used by BrainCommon.HasElectricFencePanicTriggerNode
--   翻译：「被 BrainCommon.HasElectricFencePanicTriggerNode 使用」。
-- ★★★ 这是本文件最值得注意的**反向依赖模式**：
--   · 通常是节点去查询实体状态
--   · 这里反过来：节点把自己的存在**登记**到实体上，
--     让别处（BrainCommon）来查询「这个 brain 需不需要加避电栏的 panic 节点」。
-- ★★ 为什么这么做？因为「是否需要这个节点」取决于 brain 的构成，
--   而 brain 的构建代码在 brains/ 目录，不该反过来依赖 behaviours/。
--   用一个布尔字段做「能力声明」，打破循环依赖。
-- ★ 移植建议：这是解循环依赖的实用手法 ——
--     当 A 要用 B、B 又要判断有没有 A 时，让 A 在 B 上留个标记。
-- ⚠️ 字段名以 `_` 开头，按 Lua 惯例表示「内部字段」。规范。
    --
    self.shocked_by_field = function(_, field)
--★★★ shocked_by_field 回调 —— 本节点的真正入口。
-- 收到「被新电栏电到」事件时做两件事：
--   ① 第 14 行 算出逃跑角度并缓存
--   ② 第 15 行 唤醒大脑，让 Visit 真正被执行
-- ★★ 顺序不能颠倒：必须先算好角度，再唤醒。
--   否则 Visit 会在 run_angle 还没就绪时被调用（第 60 行条件不成立，什么都不做）。
-- ★ 移植要点：**事件回调与轮询之间的数据交接要有明确的时序保证**。
        self.run_angle = self:GetRunAngle(field)
--★ 算出方向并缓存到 self.run_angle（详见第 32 行的详解）。
--★ 注意这里覆盖而非追加 —— 多次被电就以最近一次的为准。
--★ ★ 与 runaway 的 avoid_angle 缓存（1 秒锁定）不同：
--   本节点不设时间锁，因为「朝电栏反方向跑」在短时间内一定是对的，
--   没有理由「锁住旧方向」。两处差异反映了两种不同的避险需求。
        inst.brain:ForceUpdate()
    end
    --
    self.inst:ListenForEvent("startelectrocute", onelectrocute)
--★ 两个事件监听：一个来自「自己被电」，一个来自「被新电栏波及」。
--★ 第 18 行的回调是模块级 onelectrocute（无实例状态）；
--   第 19 行是实例专属闭包（需要 self）。两种类型并存，各取所需。
    self.inst:ListenForEvent("shocked_by_new_field", self.shocked_by_field)
end)

function AvoidElectricFence:OnStop()
--★ OnStop 摘两个监听，与构造器严格对应。
--★ 第 23 行用的是模块级 `onelectrocute` 引用 —— 与注册时完全同一个对象，
--   所以能正确摘除（Lua 的事件匹配基于函数对象身份）。
--★ 再次强调本目录通病：只有 bt:Stop() 会调 OnStop，Reset 不会。
	self.inst:RemoveEventCallback("startelectrocute", onelectrocute)
	self.inst:RemoveEventCallback("shocked_by_new_field", self.shocked_by_field)
end

local function GetOtherFields(fences)
--⚠️【已核实 · 空函数残留】local function GetOtherFields(fences) 完全是空的。
--   · 函数体（第 28 行）只有一个空行
--   · `fences` 形参从未使用
--   · 我已 grep 确认全文件无任何调用点
--★ 推测：原打算用它来「收集多个电栏的合力方向」，
--   后来改用第 35-39 行的直接遍历（field.fences 已在参数里），此函数作废。
--★ 标注为「已核实 · 死代码」：无功能危害，但应清理。
-- ★★ 与本文件第 44-55 行的大段注释代码一样，都是「保留思路但未启用」的痕迹。
    
end

--TODO we can still improve this, in an odd angled corner piece we should get the run away angle a lil differently
--★★★ 原注释（保留）：
--   "--TODO we can still improve this, in an odd angled corner piece we should
--    get the run away angle a lil differently"
--   翻译：「TODO：我们还能改进这个 —— 在奇数角度的角落地块上，
--    逃跑角度应该用稍微不同的算法」。
-- ★★★ 这条注释指出了一个真实的算法局限：
--   电栅栏可能以任意角度放置（含斜角），而本方法假设各段电栏
--   可以简单地向量相加（第 38 行）。
--   对斜角/角落的情况，合力方向未必是最优逃生路线。
-- ★ 移植要点：向量求和的合力法是最简单直观的避障方向算法，
--     对直线排列的障碍完全正确，对复杂形状只是「大致正确」。
--     知道它的边界在哪，比会写它更重要。
function AvoidElectricFence:GetRunAngle(field)
--★★ GetRunAngle(field) —— 算出「背离电栏群」的方向。
-- ★★★ 核心算法只有 4 行，但思想很漂亮：
--   对电栏的每一段，取「指向它的反方向」单位向量，全部累加，
--   再求累加向量的方向 —— 即「合力方向」。
--   ★★ 直观解释：每段电栏往反方向推一点，加起来的总方向就是最省力的逃法。
--   这正是「向量场求和」在避障中的标准用法。
    local xs, zs = 0, 0
    --
	for i = 1, #field.fences do
--★ 遍历电栏的所有分段（field.fences 是电栏的构成段）。
--★ 一个电栏由多段组成，每段都要单独贡献一份推力。
		local x, y, z = field.fences[i].Transform:GetWorldPosition()
		local angle = self.inst:GetAngleToPoint(x, 0, z) * DEGREES
--★ 取自己指向该段电栏的方位角，并立即转成弧度（* DEGREES）。
--★ ★★ 本文件是全目录少见的「一进入就转弧度」的地方 ——
--   下一行直接 math.cos/sin 消费，需要弧度。
--   对照 runaway/wander 的「保持度数、只在调用处转弧度」的做法。
--   ★ 两种都可行，但**必须在一处统一转换**，绝不能混用。
--   ★ 这是「角度单位纪律」的又一实例（详见 wander 第 187 行的系统说明）。
--★ 第 37 行传的是 (x, 0, z) 三个参数（GetAngleToPoint 的三坐标形式）。
		xs, zs = xs - math.cos(angle), zs - math.sin(angle)
--★★★ 合力累加的真正一行：xs, zs = xs - cos(angle), zs - sin(angle)
--★ 取负号 = 指向「背离电栏」的方向，即逃跑方向。
-- ★★★ 这一行同时做了两件事，很高效：
--   ① 求单位向量（cos/sin 天然单位长）
--   ② 直接累加进总和（不需要中间变量）
--★ 多重赋值（xs, zs = ...）避免了创建临时变量，是 Lua 的惯用写法。
-- ★ 移植要点：**用 cos/sin 表示单位方向向量，可省掉一次 sqrt 与一次除法**，
--   比先算向量再归一化更快。对比 leashandavoid 第 40 行的
--   `(hp - pt):GetNormalized()` —— 那里需要真实长度，那里有必要。
--   这里只需要方向，所以 cos/sin 就够了。
    end
    --
	return (math.atan2(zs, xs) * RADIANS) % 360 --TODO i think we can get away with some variance?
--★★★ 返回角度：atan2 求合力方向，* RADIANS 转成度，% 360 归一。
--★ RADIANS = 180/PI（constants.lua:15），DEGREES = PI/180（第 14 行），
--   两者互为倒数。这里用 RADIANS 是「弧度 → 度」。
--★ `% 360` 保证结果落在 [0, 360)，因为 atan2 返回 (-180, 180]。
--★★ 这与 runaway 第 52-55 行「+180 后若 >360 则减 360」的归一方式不同：
--   runaway 用条件判断（依赖输入范围，脆弱 —— 我在那里标了疑似脆弱点）
--   本文件用模运算（对任意输入都正确，更稳健）。
-- ★ 移植建议：角度归一化优先用模运算，除非有充分的性能理由。
--⚠️【已核实 · 潜在除零】若 field.fences 为空数组，xs 与 zs 都是 0，
--   math.atan2(0, 0) = 0（Lua 不报错），返回 0 而非 nil。
--   → 会朝 0°（右方）跑，可能是错的方向，但不会崩。
--   标注为「已核实 · 边界退化」：不致命，但结果无意义。
--★ 原注释：TODO i think we can get away with some variance?
--   翻译：「TODO：我觉得加一点随机扰动应该没问题？」
-- ★★ 即作者认为逃跑方向应加入随机性，避免所有生物朝同一方向跑。
--   参照 avoidlight 第 35 行的 ±45° 扰动、wander 第 231 行的 ±0.5 弧度 ——
--   「给随机行为加扰动」在本目录是一条反复出现的原则。
--   ★ 移植建议：群体 AI 的同质化是廉价感的主要来源，加点扰动很值得。


    --[[
--★ 被注释掉的一大段代码（约 11 行），是另一套基于实体朝向的算法草稿：
--   思路是「取电栏方向 → 算与实体朝向的夹角 → 折半」（recoilangle 逻辑）。
--★ 注意最后一行注释「我推断这里可以省掉一些方差」——
--   与第 41 行的 TODO 是同一个未竟的改进。
-- ★ ★★ 保留这段死代码的价值：它记录了「曾尝试的第二种方案」，
--     便于后来者了解设计演进。SOP 第 4 条也提到「注释掉的代码 ≠ 未实现」。
-- ★ 同时这段代码的保留也提醒我们：读源码时不要把注释块当成有效逻辑。
    local rot = inst.Transform:GetRotation() * DEGREES
    local rot1 = math.atan2(-dz, dx)
	local diff = ReduceAngleRad(rot - rot1)
	rot1 = rot1 - diff + math.pi
	if recoilangle then
		diff = ReduceAngleRad(rot1 - recoilangle)
		recoilangle = ReduceAngleRad(recoilangle + diff / 2)
	else
		recoilangle = ReduceAngleRad(rot1)
	end
    ]]

end

function AvoidElectricFence:Visit()
--★★★ Visit —— 全部逻辑只有两段共 4 行，是本目录最精简的 Visit。
--★ 没有 FAILED、没有 SUCCESS、没有 Sleep：
--   节点一旦 RUNNING 就永远 RUNNING，直到别处 Stop 整棵树。
--★★ 这是「持续奔逃」行为的正确形态：逃跑没有完成点
--   （跑远了电栏不会消失，所以没有「跑够了」的概念）。
--   对照 leash 那样有明确「到家」终点的节点 —— 差别就在这。
-- ★ 移植要点：**先判断行为有没有完成点**，有则必须设计终态，无则让它持续。
    if self.status == READY and self.run_angle then
--★★★ 双重条件进入 RUNNING：`status == READY and self.run_angle`。
--★ run_angle 非 nil ⟺ 已经收到过电栏事件并算出了方向。
--★★ 「事件填数据 + 轮询读数据」的两阶段模式（本文件的核心架构）：
--   事件侧（第 13-16 行）：算方向、填 run_angle、唤醒大脑
--   轮询侧（本段）：读 run_angle，决定是否进入 RUNNING
-- ★★ 相比 findclosest 的「周期性重选」，本节点是「一次触发永久有效」，
--   因为逃跑方向不需要重新评估（电栏不会自己移动）。
        self.status = RUNNING

        if self.inst.components.combat then
--★★ 进入时丢弃战斗目标 —— 「逃命要紧，不打了」。
--★ DropTarget 而非 GiveUp：Drop 只是解除锁定，
--   不像 GiveUp 会清仇恨来源（本节点只关心逃跑，不承担仇恨管理）。
--★ 条件判空：没有 combat 组件也安全。
-- ★ 移植要点：行为切换时清理**其他系统**的状态（这里是战斗锁定），
--   能避免「一边逃跑一边自动攻击」的荒谬行为。
-- ★★ 这与 chaseandattack 退出时 SetTarget(nil) 是同类的「状态清理」
--     但方向相反：那个是清自己的，那个是清别人的。
            self.inst.components.combat:DropTarget()
        end
    end

    if self.status == RUNNING then
--★ 每帧朝 run_angle 跑。用 Run（跑）而非 Walk —— 避险要快。
--★ 用 RunInDirection 而非 GoToPoint：方向移动只依赖瞬时方位。
--★★ 对照 wander 第 187 行（同为 WalkInDirection）与 runaway 第 169 行
--   （RunInDirection）：逃跑场景统一用方向移动。
--★ ⚠️ 无 self:Sleep —— 故 GetSleepTime 返回 0，大脑每帧都跑。
--   在本场景下是**合理的**：电击类事件随时可能再次发生，
--   高频轮询保证能立即响应（虽然事件已通过 ForceUpdate 唤醒，
--   但持续跑动本身也需要每帧维持 locomotor 指令）。
--   ★ 对比「一次性动作型」节点（controlminions）同帧结束，无需 Sleep；
--     「持续过程型」节点必须每帧维持，也就没法真正睡。
        self.inst.components.locomotor:RunInDirection(self.run_angle)
    end
end

function AvoidElectricFence:__tostring()
--★ __tostring：显示当前逃跑角度。
--★ 排查「为什么它不跑」时看这一行：若显示 nil，说明事件没来过。
-- ★ 移植要点：事件驱动型节点尤其需要这种「数据是否就绪」的调试输出，
--   因为它的失败模式是「静默不动作」，没有报错可查。
    return string.format("AVOIDELECTRICFENCE, %s", tostring(self.run_angle))
end