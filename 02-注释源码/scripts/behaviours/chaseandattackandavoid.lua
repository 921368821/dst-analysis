--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/chaseandattackandavoid.lua
-- 模块：行为树节点库 / 追打避障
-- 职责：chaseandattack 的变体：在追击途中若发现「想躲的障碍物比目标更近」，
--       就把目标点偏移到障碍物另一侧 —— leashandavoid 的绕行 hack 的原始出处。
-- 关键符号：ChaseAndAttackAndAvoid, ChaseAndAttackAndAvoid:Visit,
--           ChaseAndAttackAndAvoid:OnAttackOther, ChaseAndAttackAndAvoid:OnStop,
--           ChaseAndAttackAndAvoid:__tostring
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：chaseandattack.lua（基础版）, leashandavoid.lua（hack 的移植）,
--           components/combat.lua, components/locomotor.lua
--============================================================
ChaseAndAttackAndAvoid = Class(BehaviourNode, function(self, inst, findavoidanceobjectfn, avoid_dist, max_chase_time, give_up_dist, max_attacks, findnewtargetfn, walk)
--[[
-- chaseandattackandavoid.lua —— 追击攻击并绕开障碍（ChaseAndAttackAndAvoid）
--
-- 【★★★ 本文件是 leashandavoid.lua 第 31 行那个 hack 的「原版」】
-- leashandavoid.lua:31-33 明确写着：
--   "V2C: copied my own hack from chaseandattackandavoid =)"
--   即「从本文件抄了我自己的 hack」。所以**本文件才是原始出处**。
-- ★ 两个文件必须对照阅读：
--   本文件    —— hack 内嵌在 Visit 深处（80-96 行），靠 combat.target 驱动
--   leashandavoid —— hack 抽成了 Visit 的主逻辑（34-50 行），靠 home 驱动
-- ★★ 同一个几何技巧在两个文件里被复制了两份（我已逐字比对，逻辑一致），
--   差别是本文件**直接改写 hp.x/hp.z**（原地修改坐标），
--   而 leashandavoid **重新构造一个 Point**。
--   → 移植建议：抄 leashandavoid 的写法（不改原变量），可读性更好。
--
-- 【与 chaseandattack 的差异 —— 只有两处，都很关键】
--   ① 多了 findavoidanceobjectfn + avoid_dist：追击途中绕开障碍
--   ② 少了 distance_from_ocean_target：不做海上目标的边缘处理
-- 其余（三个放弃阈值、事件计数、.125 秒节流）与 chaseandattack 逐行同构。
-- ★ 所以本文件是「chaseandattack + 绕行补丁」，而非重新设计。
--]]
--★★ 8 个形参，与 chaseandattack 的 8 个一一对应（顺序略不同）：
--   新增 findavoidanceobjectfn（第 1 位）、avoid_dist（第 2 位）
--   缺少 distance_from_ocean_target
--★ 参数顺序不统一（新增项插在前面）说明它是后期扩展的，
--   没打乱原参数顺序以保持调用兼容性 —— 这是个好习惯。
    BehaviourNode._ctor(self, "ChaseAndAttackAndAvoid")
    self.inst = inst
    self.findnewtargetfn = findnewtargetfn
    self.max_chase_time = max_chase_time
    self.give_up_dist = give_up_dist
    self.max_attacks = max_attacks
    self.numattacks = 0
    self.walk = walk
    self.findavoidanceobjectfn = findavoidanceobjectfn
    self.avoid_dist = avoid_dist

    -- we need to store this function as a key to use to remove itself later
--★ 存句柄以便反注册，与 chaseandattack 第 12 行完全相同的套路。
    self.onattackfn = function(inst, data)
        self:OnAttackOther(data.target)
    end

    self.inst:ListenForEvent("onattackother", self.onattackfn)
    self.inst:ListenForEvent("onmissother", self.onattackfn)
end)

function ChaseAndAttackAndAvoid:__tostring()
--★ __tostring 同时显示「攻击目标」与「正在躲避的障碍」——
--   两个目标都要能看到，排障时很实用。
    return string.format("target %s, avoiding %s", tostring(self.inst.components.combat.target), tostring(self.avoidtarget))
end

function ChaseAndAttackAndAvoid:OnStop()
--★ OnStop 摘两个监听，与构造器注册的对称。
    self.inst:RemoveEventCallback("onattackother", self.onattackfn)
    self.inst:RemoveEventCallback("onmissother", self.onattackfn)
end

function ChaseAndAttackAndAvoid:OnAttackOther(target)
--★ OnAttackOther：计数 + 清空追击计时器（静默超时语义）。
--★ 与 chaseandattack 第 30-34 行逐行相同。
    --print ("on attack other", target)
    self.numattacks = self.numattacks + 1
    self.startruntime = nil -- reset max chase time timer
end

function ChaseAndAttackAndAvoid:Visit()
--★★ Visit：顺序双 if 结构，与 chaseandattack 完全一致。
    local combat = self.inst.components.combat
    if self.status == READY then
--★ 先 ValidateTarget（与 chaseandattack 第 39 行相同）。
        combat:ValidateTarget()

        if combat.target == nil and self.findnewtargetfn ~= nil then
			combat:SetTarget(self.findnewtargetfn(self.inst))
        end

        if self.findavoidanceobjectfn ~= nil then
--★★★ 避障目标在**进场时**选一次，之后不重选。
--★ 与 leashandavoid 第 21-23 行同一取舍：
--   重选障碍会改变绕行方向 → 抖动；不重选则障碍跑了会白绕。
-- ★★ 本文件没有 findclosest 那样的周期性复核 —— 属于「选一次」派。
-- ★ 移植要点：这个取舍的判据是「目标变化是否会引发行为抖动」，
--   而非「重选是否更准确」。这里选了「不抖」。
            self.avoidtarget = self.findavoidanceobjectfn(self.inst)
        end

		if combat:HasTarget() then
--★ 判断用 combat:HasTarget() 而非 chaseandattack 的 `combat.target ~= nil`。
--★ 语义更强：HasTarget 可能还检查目标是否可攻击（我未读 combat.lua 该方法，
--   但从命名看是更严格的判断）。属合理改进。
			combat:BattleCry()
            self.startruntime = GetTime()
            self.numattacks = 0
            self.status = RUNNING
        else
            self.status = FAILED
        end
    end

    if self.status == RUNNING then
--★★ RUNNING 段。与 chaseandattack 同构的三分支。
        local is_attacking = self.inst.sg:HasStateTag("attack")
--★ `local is_attacking = sg:HasStateTag("attack")` ——
--⚠️【已核实 · 疑似无用变量】is_attacking 在本文件后续（第 61-131 行）
--   **从未被读取**。我已通读全文确认。
--   对照 standandattack.lua 第 51 行有完全相同的一行（也是被注释掉的同款代码）。
--★ 说明这是作者调试时留下的残留。Lua 允许未使用变量，无功能危害。
--   标注为「已核实」：属代码整洁性问题。

        if combat.target == nil or not combat.target.entity:IsValid() then
            self.status = FAILED
            combat:SetTarget(nil)
            self.inst.components.locomotor:Stop()
        elseif combat.target.components.health ~= nil and combat.target.components.health:IsDead() then
            self.status = SUCCESS
            combat:SetTarget(nil)
            self.inst.components.locomotor:Stop()
        else
            local hp = Point(combat.target.Transform:GetWorldPosition())
            local pt = Point(self.inst.Transform:GetWorldPosition())
            local dsq = distsq(hp, pt)
            --local angle = self.inst:GetAngleToPoint(hp)
            local r = self.inst:GetPhysicsRadius(0) + combat.target:GetPhysicsRadius(-.1) + .1
--★★ 贴身距离 r = 双方物理半径之和 + 0.1 余量。
--★ 与 chaseandattack 第 85 行逐字相同 —— 同一套「跑动时用半径、走路时用射程」的判据。
--★ 提前算出 r 是为了第 98 行的两分支比较，避免重复开方。
            local running = self.inst.components.locomotor:WantsToRun()

            -- this is probably the biggest hack i've done in my life...
--★★★ 原注释（保留，作者原话）：
--   "this is probably the biggest hack i've done in my life..."
--   翻译：「这可能是我这一生做过的最大的 hack……」
--★★★ 注意 leashandavoid.lua 第 33 行在引用这句时补了一句 "^ not true"，
--   （「^ 并不属实」）。也就是说作者后来觉得原注释太夸张了。
-- ★★ 这条注释链（原始出处 + 引用处 + 自我更正）是极好的代码考古样本：
--   读者能一路追溯到 hack 的诞生地，还能看到作者态度的变化。
-- ★ 移植要点：给复杂逻辑留「作者自评」注释很有帮助，
--   它能提示后来者「这段要小心，作者自己都说它很 hack」。
            if self.avoidtarget ~= nil and self.avoidtarget:IsValid() then
--★ 两道守卫：障碍存在且仍有效。
--★ 注意**没有**检查「障碍是否仍挡在途中」—— 与 leashandavoid 同样的简化。
                local ap = Point(self.avoidtarget.Transform:GetWorldPosition())
--★ 障碍点。三个点齐备：pt（自己）/ hp（目标）/ ap（障碍）。
                if distsq(ap, pt) < dsq then
--★★★ 第一层廉价判据：障碍比目标更近。
--★ 我已核实 leashandavoid 第 37 行用的是 `distsq(ap, pt) < distsq(hp, pt)`
--   （障碍 vs 目标的距离平方比较），
--   而本文件第 82 行用的是 `distsq(ap, pt) < dsq`，其中 dsq 是第 74 行算的
--   自身到目标的距离 —— **语义完全相同**，只是省了一次开方。
--★ ★ 移植要点：把「与目标的距离平方」缓存下来复用，是等价且更省的写法。
--   本文件比 leashandavoid 略优一点点。
                    local delta_dir = anglediff(--[[angle]]self.inst:GetAngleToPoint(hp), self.inst:GetAngleToPoint(ap))
--★★★ anglediff(A, B) —— 求两个角度之差（自动处理 ±360° 环绕）。
--★ 第 83 行还留着一个被注释掉的 `--[[angle]]`，说明这里曾是变量名 angle。
--★ ★ 移植要点：做角度比较**必须**用 anglediff，不能直接相减。
--   直接相减在 179° 与 -179° 之间会得到 358°（实际只差 2°），
--   是 AI「朝向抖动」的经典来源。DST 提供了 anglediff 就是为了避开这个坑。
--★ ★★ 对照本文件第 94 行的 offset_angle = math.abs(angle - math.abs(self.ram_angle))
--   ——那里用的是**直接相减**。在 chaseandram.lua 的同名公式里我也标了疑似缺陷。
--   这里两处角度都来自 GetAngleToPoint（同源、同范围），相减相对安全；
--   但仍不如 anglediff 稳健。属可改进点。
                    if math.abs(delta_dir) < 45 then
--★★ 第二层廉价判据：夹角小于 45 度（障碍在正前方锥形内）。
--★ 与 leashandavoid 第 39 行完全相同的阈值。
--★★ 两层廉价判据的意义（详见 leashandavoid 第 37-39 行的详解）：
--   ① 障碍更近  →  挡在路上
--   ② 方向接近  →  确认在正前方
--   只有都成立才做真正的绕行几何 —— 用便宜判断过滤掉绝大多数情况。
                        local offset = (hp - pt):GetNormalized()
--★ 归一化的「指向目标」方向向量，用作侧移的基准轴。
--★ ⚠️ 与 leashandavoid 第 40 行同样的问题：
--   该向量在 xz 平面上（y 分量为 0），所以第 93 行的 y 偏移恒为 0。
--   「抬高/压低」这一项目前不起作用。我已在 leashandavoid 第 41 行详述。
                        if delta_dir < 0 then
--★★ 绕行方向的选择：delta_dir 的符号决定绕向障碍物的哪一侧。
--★ 两个分支只差 offset.z / offset.x 的正负号（正交旋转的两种方向）。
--★★ 几何构造（与 leashandavoid 第 41-47 行同构）：
--   结果点 = 障碍点 ± (垂直于目标方向的单位向量) × avoid_dist
--   效果是「从障碍物的侧面绕过去」，且绕过后仍大致朝目标前进。
--★ 移植建议：leashandavoid 用了 Lua 的 and/or 三元一次表达两个分支，
--   本文件用显式 if/else —— **本文件的写法更清晰，建议照抄这一版**。
                            hp.x = ap.x - offset.z * self.avoid_dist
--★ 绕向一侧：ap.x - offset.z × d，ap.z + offset.x × d。
--★ 这一对分量就是「把 offset 向量顺时针旋转 90°」的结果。
                            hp.z = ap.z + offset.x * self.avoid_dist
                        else
--★ 绕向另一侧：符号相反，即旋转 -90°。
                            hp.x = ap.x + offset.z * self.avoid_dist
                            hp.z = ap.z - offset.x * self.avoid_dist
                        end
                        hp.y = ap.y + offset.y * self.avoid_dist
--★⚠️ y 方向的偏移。**已核实恒等于 ap.y**（因为 offset.y 为 0）。
--★ 与 leashandavoid 第 43/46 行相同 —— 都是「看似在抬高、实际没抬」。
--★ 对比：本文件第 72-73 行的 hp 是 Point（y 可能是真实高度），
--   而 leashandavoid 重新构造 Point 时也保留了 ap.y。行为一致。
                    end
                end
            end

            if (running and dsq > r * r) or (not running and dsq > combat:CalcAttackRangeSq()) then
--★★ 移动判定：与 chaseandattack 第 86 行逐字相同。
--   跑动用物理半径 r，走动用 CalcAttackRangeSq()。
--★ 注意用的是第 74 行的 dsq（**未被绕行 hack 修改**），
--   而 GoToPoint 的目标是可能被改写的 hp。
-- ★★ 这里有一个细微的正确性问题：绕行后实际要走到的是偏离目标的位置，
--   但距离判定用的仍是原始 dsq。绕行偏移量不大时无感知，
--   偏移很大（avoid_dist 大）时会「明明没到位却停下了」。
--   标注为「疑似不精确」：无功能危害，属几何近似的固有代价。
                --self.inst.components.locomotor:RunInDirection(angle)
                self.inst.components.locomotor:GoToPoint(hp, nil, not self.walk)
--★ GoToPoint(hp, nil, not self.walk) —— 第三参数控制跑/走。
--★ hp 可能是被绕行 hack 改写的点（第 87-93 行），
--   这就是「决策结果编码进目标变量」的传递方式（对照 leashandavoid 第 53 行）。
            elseif not (self.inst.sg ~= nil and self.inst.sg:HasStateTag("jumping")) then
--★ 跳跃豁免：滞空时不打断（与 chaseandattack 第 89 行相同）。
                self.inst.components.locomotor:Stop()
                if self.inst.sg:HasStateTag("canrotate") then
--★ 只有 canrotate 状态才转身，避免扭歪攻击动画朝向。
                    self.inst:FacePoint(hp)
                end
            end

            if combat:TryAttack() then
--★ TryAttack 返回值被丢弃（空 then），语义与 chaseandattack 第 96 行相同：
--   真正的计时器重置在事件回调（第 34 行）里，不在这里。
--★ ⚠️ 但本文件的绕行 hack 改写了 hp（移动目标），而攻击方向
--   由 combat 组件按真实目标计算 —— 两者独立，互不干扰。这一点是对的。
                -- reset chase timer when attack hits, not on attempts
            elseif self.startruntime == nil then
                self.startruntime = GetTime()
                self.inst.components.combat:BattleCry()
            end

            if self.max_attacks ~= nil and self.numattacks >= self.max_attacks then
--★★ 终止一：攻击次数用尽 → SUCCESS + 清目标 + 停止 + return。
--★ 与 chaseandattack 第 104-108 行完全相同。
                self.status = SUCCESS
                self.inst.components.combat:SetTarget(nil)
                self.inst.components.locomotor:Stop()
                return
            elseif (self.give_up_dist ~= nil and dsq >= self.give_up_dist * self.give_up_dist)
--★★ 终止二：距离过远 或 静默超时 → FAILED + GiveUp + 停止 + return。
--★ GiveUp 而非 SetTarget(nil)：会一并清掉仇恨来源（同 chaseandattack 第 112 行）。
--⚠️ 第 121 行的 startruntime ~= nil 防御是必需的（startruntime 会被第 34 行置 nil）。
                or (self.max_chase_time ~= nil and self.startruntime ~= nil and GetTime() - self.startruntime > self.max_chase_time) then
                self.status = FAILED
                self.inst.components.combat:GiveUp()
                self.inst.components.locomotor:Stop()
                return
            end

            self:Sleep(.125)
--★★ self:Sleep(.125) —— 与 chaseandattack/standandattack/chaseandram 全部相同。
--★ 至此本目录的「战斗类节点」节拍完全统一（0.125 秒），
--   而「移动类节点」用 0.25 秒。这个区分是清晰的：
--   · 战斗类需要快速反应出手机会 → 高频
--   · 移动类走错几步无所谓     → 低频省电
-- ★ 移植要点：把决策频率按「行为类型」分组统一，而不是逐节点随意设。
        end
    end
end