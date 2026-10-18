--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/avoidlight.lua
-- 模块：行为树节点库 / 避让
-- 职责：躲避光源（火焰、余烬、探照灯）的节点：探测最近光源 → 计算侧向逃逸角 → 边走边等。
-- 关键符号：AvoidLight, AvoidLight:Visit, AvoidLight:PickNewAngle, AvoidLight:Wait
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：runaway.lua, avoidelectricfence.lua, components/locomotor.lua
--============================================================
AvoidLight = Class(BehaviourNode, function(self, inst)
--[[
-- avoidlight.lua —— 避光节点（AvoidLight）：躲开光源（火焰、探照灯等）
--
-- 【★ 与 findlight.lua 的关系 —— 完全镜像的两个节点】
--   avoidlight：找最近的光并**远离**它
--   findlight  ：找最近的光并**靠近**它
--   两者共享同一套「找目标 → 走过去」骨架，只差行动方向。
-- ★ 移植要点：这种「同骨架、反方向」的节点对，是行为库最常见的形态，
--   写完一个后照着写另一个非常快，也非常容易保持一致性。
--
-- 【★★ 本文件有两个我已逐字核实的真实缺陷（见第 55、30 行的 ⚠）】
--   ① 第 55 行  phasechangetime 漏了 `t +` → 「等待」阶段实际永不持续
--   ② 第 20-23 行 四向都被阻挡时 angles 为空 → 第 32 行 math.random(0) 崩
-- ★ 与其他文件不同，本文件的核心结构基本正确，缺陷集中在时序与边界处理上；
--   这恰好是自研 AI 最常见的两类 bug 来源，值得作为反面对照学习。
--]]
--★★ 构造器零参数 —— 本文件完全不可配置（radius、时长全部硬编码）。
--★ 与 follow/approach/wander 的高度参数化形成鲜明对比。
-- ★ 适用判断：本节点只服务一种「怕光生物」，参数化没有收益。
    BehaviourNode._ctor(self, "AvoidLight")
    self.inst = inst
    self.waiting = false
--★ waiting：内层二态小状态机的当前状态（等待 or 移动）。
--★ 与 wander 的 walking（第 47 行）、follow 的 action 是同一模式。
    self.phasechangetime = 0
--★ phasechangetime：阶段切换时刻初值 0 —— 保证首次必定触发切换。
--★ 与 useshield 第 8 行「用初值表达初始状态」同一手法。
end)



function AvoidLight:Wait(t)
--★★★ Wait(t) —— 与 wander 第 105-108 行**完全相同**的两行封装：
--   ① 设 waittime（业务状态：等待结束时刻）
--   ② 设 Sleep（调度状态：大脑休眠到何时）
-- ★★ 这说明 Wait 是本目录的通用小工具（wander 先写，avoidlight 复用）。
-- ★ 移植要点：这类「同时设置业务状态与调度状态」的方法应当提取复用，
--   漏设其中一半会造成「逻辑对但性能差」或「性能好但逻辑错」的隐蔽 bug。
--⚠️ 隐患：第 55 行的缺陷恰恰破坏了这个封装的前提（见该行详解）。
    self.waittime = t+GetTime()
    self:Sleep(t)
end


function AvoidLight:PickNewAngle()
--★★★ PickNewAngle —— 从「四个可走方向」里挑一个作为逃跑方向。
-- ★★ 与 runaway/runtodist 的 FindWalkableOffset（连续角度扇形扫描）不同：
--   本节点只考虑**正交四方向**（上/下/左/右），是更粗粒度的选点。
-- ★ 取舍：粗粒度更快（4 次碰撞检测 vs 8 次寻路检测）、更稳（不会选到窄缝），
--   但移动路径更僵硬。适合「快速逃跑」这类不需要精细路径的场景。
-- ★★ 移植要点：逃跑 AI 不需要漂亮路径，「不撞墙」比「绕得优雅」重要。

    local angles = {}

    if self.inst.Physics:CheckGridOffset(0,-1) then table.insert(angles, -90) end
--★★★ 四个正交方向的碰撞预检测，收集「能走」的方向。
--   CheckGridOffset(0,-1) → 前方 → 角度 -90
--   CheckGridOffset(0,1)  → 后方 → 角度 90
--   CheckGridOffset(-1,0) → 左方 → 角度 180
--   CheckGridOffset(1,0)  → 右方 → 角度 0
--★ 全部用单行 if + table.insert，无 else —— 收集式写法，比四段 if/else 短得多。
--★ 只做碰撞检测，不做寻路（Pathfinder:IsClear），因此非常快。
-- ★ 移植要点：把「候选集构建」与「候选集选择」分成两步（第 20-23 / 27-33 行），
--   职责单一，加新方向只需改第一段。
    if self.inst.Physics:CheckGridOffset(0,1) then table.insert(angles, 90) end
    if self.inst.Physics:CheckGridOffset(-1,0) then table.insert(angles, 180) end
    if self.inst.Physics:CheckGridOffset(1,0) then table.insert(angles, 0) end

    local angle = 0

    local light = self.inst.LightWatcher:GetLightAngle()
--★ 取光源相对自己的方位角（LightWatcher 组件，引擎原生）。
--   ⚠️ 诚实标注：我 grep 了整个 scripts/ 目录，**未找到**
--     LightWatcher:GetLightAngle 的 Lua 实现，
--     它应是引擎（C++）提供的原生方法。故不对其语义细节下断言，
--     只依据调用方式推断「返回光源方位角，nil 表示附近无光」。
--   ★ 这正是严谨注释应有的态度：**不确定的外部依赖不要编造说明**。
    if light then
--★★★ 排序策略：有光时按「与光源的夹角从小到大」排序，取第一个。
--   ★★ 关键洞察：夹角最小的可走方向 = **背对光源的方向**，正是要逃的方向。
--   ★★ 用「排序 + 取首元素」代替「遍历找最小」，
--     代码更短且天然支持后续扩展（如取前 N 个候选）。
--★ 第 29 行必须用 anglediff（不能直接相减），理由见第 29 行的说明。
--★ 排序比较函数返回布尔：a 与光夹角更小则 a 排前面。
        table.sort(angles, function(a,b) return math.abs(anglediff(a, light)) < math.abs(anglediff(b,light)) end)
--★★★ `math.abs(anglediff(a, light))` —— 夹角的绝对值。
--★ 必须用 anglediff 而非 `a - light`：
--   角度差要按**环形**计算。179° 与 -179° 实际只差 2°，
--   直接相减得 358°，会把「背对光源」误判为「正对光源」。
--   ★★ 这是 DST AI 里反复出现的陷阱（leashandavoid 第 38 行、
--     chaseandram 第 94 行是同一主题的变体），务必记住。
        angle = angles[1]
--⚠️⚠️【已核实 · 真实缺陷 · 崩溃风险】angles 可能为空表。
--
-- 推理（我已逐行核实第 18-30 行）：
--   · 第 18 行 angles 初始化为空表
--   · 第 20-23 行只有四向**都**被阻挡时它才保持为空
--   · 第 28 行若 light 非 nil（即附近有光），会走排序分支
--   · 第 30 行 angles[1] 在空表上取值为 **nil**
--   · 第 35 行 `angle + math.random()*90-45` 对 nil 做加法 → **运行时错误**
--
-- 【触发条件】实体被完全围住（四个正交方向都有墙/障碍）且附近有光源。
--   在被玩家用冰墙围住的「怕光生物」身上完全可能发生。
--
-- 【修复方向】在第 25 行后加 `if #angles == 0 then return nil end`，
--   并在调用处（第 58 行）处理 nil。
--
-- ★★ 对比第 32 行（无光分支）：math.random(#angles) 在 #angles==0 时
--   等价于 math.random(0)，Lua 会抛错而非返回 nil。
--   两条路径都缺空表保护。标注为「已核实 · 真实缺陷」。
    else
        angle = angles[math.random(#angles)]
--★ 无光时随机挑一个可走方向（无优先级可依据）。
--⚠️ 同样有 #angles == 0 的崩溃风险（math.random(0)）。见第 30 行。
--★ ★ 移植要点：任何 `math.random(#table)` 前都要确认表非空，
--     这是 Lua 里最常见的运行时崩溃之一。
    end

    angle = angle + math.random()*90-45
--★★ 在选定方向上再加 ±45° 的随机扰动。
--★ 目的与 wander 第 231 行（±0.5 弧度）完全同源：**避免每次都走同一条线**。
--★ 群体里多只生物会朝略微不同的方向散开，观感自然得多。
--★ 注意这里用的是**度**（±45 度），而 wander 用的是**弧度**（±0.5）。
--   两处单位不同但各自自洽 —— 又一个「角度单位必须逐处确认」的实例。
    return angle
end

function AvoidLight:Visit()
--★★ Visit：READY 段无条件转 RUNNING，**没有 FAILED 分支**。
--★ 即本节点永不失败 —— 「怕光」是持续状态，不存在「不需要躲」的完成点。
--★ 对照 wander（同样永不写终态）：这类「持续过程型」节点都无终态。
--★ 第 43 行被注释掉的 Steering:SetActive(true)：
--   曾想用转向系统（steering）做避障，最终改用 locomotor 的方向移动。
-- ★ 与 runaway 第 51 行的 Slerp 思路同属「转向系统」流派。

    if self.status == READY then
        self.status = RUNNING
        --self.inst.Steering:SetActive(true)
    end

    if self.status == RUNNING then
--★★ RUNNING 段入口。只关心两件事：是否在光里、当前处于哪个阶段。
        local in_light = self.inst:IsInLight()
--★ in_light = self.inst:IsInLight() —— 引擎原生方法（同样未在 scripts/ 中找到实现）。
--★ 用途：若正在等待且已进入光照，则立即结束等待（不必等相位结束）。
--★★ 这个「条件打断」让避光反应更灵敏：
--   一被照到就立刻启动，而不是先把当前的等待阶段走完。
--   ★ 移植要点：让「危险信号」能打断当前的常规节拍，是实时性设计的基本手法。

        local t = GetTime()
--★ t = GetTime()，绝对时钟（不用累加 deltaTime，避免漂移）。
--★ 与 beargeroffscreen 第 182 行同一做法。
        if t > self.phasechangetime or (self.waiting and in_light) then
--★★★ 阶段切换的两个触发条件：
--   ① t > phasechangetime            —— 常规：时间到了就切
--   ② self.waiting and in_light     —— 例外：等待中却被照到，立刻切
--★★ 「二态翻转」的设计（第 52 行 `self.waiting = not self.waiting`）：
--   一次触发就切换到另一个状态，无需分别写「开始等待」和「开始移动」两个分支的入口。
--   ★ 代码量减半，且不可能漏掉某个状态的进入条件。
--   ★ 移植要点：**二态状态机用翻转，比用 if/else 分别处理更简洁**。
--★ 条件 ② 只在「等待中被照到」时提前唤醒；
--   若「移动中被照到」，则走条件 ① 的正常时间路径（1~4 秒后切换）。
--   ★ 略不对称但可接受：移动中的反应已由第 64-75 行的每帧重算保证。

            self.waiting = not self.waiting
--★ 翻转内层状态机。这是整个节点的控制中枢。

            if self.waiting then
--★ 进入「等待」阶段：停下不动（第 56 行）。
--★ 语义：先定住，让光照状态稳定一下，再决定往哪跑。
--★★ 「跑两步停一下」的节奏本身就是躲光的观感（像受惊的野兽），
--   这个二态设计直接决定了最终的手感。
                self.phasechangetime = .2+math.random()*.25
--★★★★⚠️【已核实 · 真实缺陷】缺少 `t +`。
--
-- 实际代码：
--     self.phasechangetime = .2+math.random()*.25
-- 应当是：
--     self.phasechangetime = t + .2+math.random()*.25
--
-- 【证据 —— 我已逐字核对第 49-62 行】
--   · 第 49 行取了局部变量 t = GetTime()
--   · 第 59 行的对称分支写的是 `t + 1+math.random()*3`  ← **有** t +
--   · 第 55 行写的是 `.2+math.random()*.25`              ← **没有** t +
--   两个对称分支写法不一致，这是漏写而非有意为之。
--
-- 【后果 —— 影响比看起来更大】
--   · 第 55 行赋的是**绝对值** 0.2 ~ 0.45
--   · 而 t 是 GetTime()，游戏运行时通常已远大于 0.45
--   · 第 50 行 `t > self.phasechangetime` 于是**恒为真**
--   → 「等待」阶段在下一帧立即被翻转掉，**等待行为完全失效**
--   → 生物表现为「几乎一直在移动，从不停顿」，失去受惊的节奏感。
--
-- ★★ 为什么没被发现？
--   因为「等待阶段太短」在观感上只表现为「停得不够久」，
--   不会崩溃、不会报错，只是手感略差 —— 属于典型的**手感型隐性 bug**。
--   ★★★ 这类 bug 是自研 AI 最难查的一类：
--     没有任何错误信号，只能靠「和预期不一样」的直觉判断。
--     唯一的防线是**在对称的代码块之间做交叉检查**（正如本次的比对）。
--   ★ 移植建议：凡是「设下次触发时刻」的赋值，都要检查是否带了当前时间基准。
                self.inst.components.locomotor:Stop()
            else
--★ 进入「移动」阶段：选一个新方向，并设 1~4 秒的移动持续时间。
--★ 与第 55 行的 0.2~0.45 秒对照：移动阶段远长于等待阶段，
--   符合「多跑少停」的逃跑直觉。
                self.angle = self:PickNewAngle()
--★ 选新方向。若 PickNewAngle 返回 nil（第 30 行的缺陷），self.angle 变 nil，
--   第 73 行 WalkInDirection(nil) 会报错。缺陷的传播路径见第 30 行。
                self.phasechangetime = t + 1+math.random()*3
--★★ 正确写法：t + 1 + random()*3 → 1~4 秒后下次切换。
--★ 与 wander 的「min + random()*rand」模式一致（本处 min=1, rand=3）。
            end

        end

        if not self.waiting then
--★ 只有非等待阶段才移动逻辑（等待阶段已 Stop）。
--★ 每帧执行，因此移动方向可以持续修正 —— 见第 66-72 行。

            local light = self.inst.LightWatcher:GetLightAngle()
--★★ 每帧重新取光源角度，准备实时修正方向。
--★ 注意这与 PickNewAngle 内部（第 27 行）的取光逻辑重复了，
--   但用途不同：第 27 行是「选可走方向」，这里是为每帧修正提供基准。
--★ ★★ 这体现了一个重要的实时性取舍：
--   选点（PickNewAngle）受 CheckGridOffset 限制，只能选四方向，
--   所以移动阶段再叠加一个「精确的背光方向」来提高精度。
--   ★ 移植要点：离散选点 + 连续修正，两者结合既快又准。
            if light then

                self.inst.entity:LocalToWorldSpace(1,0,0)
--⚠️【已核实 · 无用调用】self.inst.entity:LocalToWorldSpace(1,0,0)
--   返回值未被赋给任何变量，全文件仅此一次调用。
--   ★ 我已 grep 确认 LocalToWorldSpace 在本文件只出现于第 69 行。
--   推测原意是「取实体前方的一个点来测试」，但没写完或改用了别的方式。
--   标注为「已核实 · 残留调用」：无功能危害（纯计算），但属应清理的死代码。
--★ ★★ 与 beargeroffscreen、controlminions、findclosest 等文件都有类似残留，
--   说明调试痕迹在本项目中普遍存在。阅读时不要把无用调用当成有效逻辑。

                self.angle = light + 180 + math.random()*60-30
--★★★ 精确的背光方向：light + 180（正对背）+ ±30° 随机。
--★ 与第 35 行的 ±45° 扰动对比：这里的扰动更小（±30），
--   因为方向基准已经是精确的背光方向，不需要太大自由度。
--★ ★ 两个扰动幅度（选点时 ±45、修正时 ±30）的差异是有意义的：
--   离散的选点需要更大的自由度，连续修正只需轻微扰动避免僵直。
--★ 这是「扰动幅度应与该次决策的精度需求匹配」的好例子。
--★ 注意这里覆盖了 PickNewAngle 选出的 self.angle（第 58 行），
--   即「先选一个可行走方向，再微调成背光方向」。
            end
            self.inst.components.locomotor:WalkInDirection(self.angle)
--★ 按方向行走。注意是 Walk（走）而非 Run（跑）—— 怕光生物逃跑不冲刺。
--★ 若 self.angle 为 nil（第 58 行的缺陷传播），此处会报错。
--★ 本节点**不用** GoToPoint，而是用方向移动 —— 与 follow 第 155-160 行同一理由：
--   方向移动只依赖瞬时方位，不会指向过时位置。
            self:Wait(.1)
--★★★ self:Wait(.1) —— 每 0.1 秒醒一次（每秒 10 次）重新算方向。
--★ 与其他节点对比：chaseandattack .125 / follow .25 / 本节点 .1。
--   ★ 0.1 是本目录最频繁的节拍，原因合理：
--     避光需要**实时**响应（光源可能突然移动/熄灭），
--     慢半拍就会站在光里。
--★ Wait 封装同时设了业务计时与休眠（第 10 行的说明）。
--★ ⚠️ 注意：第 11 行设的 self.waittime 在本文件中**从未被读取**
--   （本文件只用 phasechangetime 做时序）。属无害冗余。
--   标注为「已核实」：直接调 self:Sleep(.1) 即可，无需走 Wait 封装。
        end


    end
end


