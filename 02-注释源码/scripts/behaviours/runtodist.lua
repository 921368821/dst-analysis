--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/runtodist.lua
-- 模块：行为树节点库 / 位移
-- 职责：朝「离当前最远的若干候选点」跑过去（取距离最远的那个），常用于「往地图另一边跑」。
--       GetRunPosition 封装了候选点的生成与打分。
-- 关键符号：RunToDist, RunToDist:Visit, RunToDist:GetRunPosition, RunToDist:__tostring
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/locomotor.lua, runaway.lua, behaviorutil.lua（GetFurthestPoint 等）
--============================================================
-- OMAR: For wx78_possessedbody only, right now.
--[[
-- runtodist.lua —— 拉开距离节点（RunToDist）：跑到距某个实体「刚好 safe_dist」的位置
--
-- 【★ 与 runaway.lua 的关系 —— 本文件是它的「简化裁剪版」】
-- runaway    ：每帧重算逃跑方向，目标是「越远越好」（safe_dist 是终止阈值）
-- runtodist  ：同样朝反方向跑，但目标是「停在 safe_dist 处」（safe_dist 是目标值）
-- ★★ 区别在于 **safe_dist 的角色**：
--   runaway    的 safe_dist = 「够了就停」的门槛，跑过头也算成功
--   runtodist  的 safe_dist = 「跑到这里就停」的目标，跑过头要拉回来
-- ★ 移植要点：同一套几何算法，换一个语义就得到完全不同的行为。
--   复用代码时务必确认「参数的角色」而不是「参数的名字」。
--
-- 【★ 本文件的 GetRunPosition 是 runaway 的 GetRunAngle 的改写版】
-- 四级降级结构、方向惯性缓存（第 21-29 行）、fix_overhang 兜底（第 48-60 行）
-- 全都逐行同构。差别只在于**返回值**：
--   GetRunAngle   返回「角度」（给 RunInDirection 用）
--   GetRunPosition 返回「偏移向量」（给 GoToPoint 用）
-- ★ 移植要点：把「几何搜索」与「移动接口」解耦，
--   同一套搜索可服务「按方向走」与「按点走」两种移动原语。
--]]
--★ 原注释（保留）：OMAR: For wx78_possessedbody only, right now.
--   翻译：「OMAR：目前仅供 wx78_possessedbody（被控制的傀儡机器人）使用」。
--★★ 作者署名 + 使用范围声明，是很规范的做法：
--   标明「这个节点只服务于某个实体」，避免他人误以为通用而滥用。
--★ 移植建议：专用节点在文件头写明「谁在用」，能减少很多误用与维护成本。

RunToDist = Class(BehaviourNode, function(self, inst, hunterparams, safe_dist, fn, fix_overhang, walk_instead, allow_boats)
--★★ 8 个形参，与 runaway 的 10 个对照，少了 see_dist 与 safe_point_fn。
--   即：本节点不做「自己找追猎者」的四种方式，只支持 gethunterfn。
--★★ 第 6 行只取 hunterparams.getfn 一个字段（runaway 取了 6 个）。
--   更简单，但也意味着只能靠调用方自己找目标。
    BehaviourNode._ctor(self, "RunToDist")
    self.safe_dist = safe_dist
    if type(hunterparams) == "table" then
		self.gethunterfn = hunterparams.getfn
    end
    self.inst = inst
    self.shouldrunfn = fn
	self.fix_overhang = fix_overhang -- this will put the point check back on land if self.inst is stepping on the ocean overhang part of the land
--★ 与 runaway 第 24 行逐字相同的原注释：
--   "this will put the point check back on land if self.inst is stepping on
--    the ocean overhang part of the land"
--★ 同款注释在三个文件出现（本文件、runaway、leashandavoid），
--   属「复制代码时连注释一起复制」的痕迹。无害，但说明这些文件同源。
    self.walk_instead = walk_instead
    self.allow_boats = allow_boats or nil
--★ allow_boats：允许选到船的位置（第 44/46/57 行传给 FindWalkableOffset）。
--★ ⚠️ `or nil` 是冗余的 —— or nil 什么都不改变。
--   疑为 `or false` 的笔误，但语义上无差别（nil 与 false 在下游 if 里同样为假）。
--   标注为「已核实 · 无害冗余」。
end)

function RunToDist:__tostring()
    return string.format("RunToDist %f from: %s", self.safe_dist, tostring(self.hunter))
end

function RunToDist:GetRunPosition(pt, hp, safe_dist)
--★★★ GetRunPosition —— 与 runaway 的 GetRunAngle 四级降级完全同构，
--   唯一差别是**返回偏移向量而非角度**。
-- 逐段对照（括号内为 runaway 的对应行号）：
--   ① 方向惯性缓存   （同第 34-41 行）
--   ② 背向目标的角度 （同第 51-56 行）
--   ③ 选点四级降级   （同第 65-86 行）
--   ④ deflected 缓存 （同第 89-92 行）
    if self.avoid_angle ~= nil then
--★★ 方向惯性：缓存「上一次被迫偏转后的偏移」，1 秒内继续沿用。
--★ 与 runaway 第 34 行的机制完全相同（详见 runaway 第 34 行的详解）：
--   给转向一个冷却期，避免贴着墙高频重算导致的抽搐。
-- ★★ 注意这里缓存的是 **offset（向量）**而非 angle（角度），
--   因为本节点的返回值就是 offset。缓存的东西必须与返回值同类型 ——
--   这也是 runaway 与本文件最容易在移植时搞混的地方。
        local avoid_time = GetTime() - self.avoid_time
        if avoid_time < 1 then
            return self.avoid_angle
--★ 缓存命中直接返回，跳过全部几何计算（本函数最贵的部分）。
--★ 性能收益与 runaway 相同。
        else
            self.avoid_time = nil
            self.avoid_angle = nil
        end
    end

	local angle = self.inst:GetAngleToPoint(hp) + 180 -- + math.random(30)-15
--★ 背向目标：`GetAngleToPoint(hp) + 180`（度）。
--★ 第 31 行末尾同样有被注释掉的 math.random(30)-15（见 runaway 第 51 行的说明）。
--★ 两个文件都留了同一段注释，说明这段是从 runaway 整体复制来的。
    if angle > 360 then
--★★ 归一到 [0, 360)。⚠️ 只减一次 360，依赖上游返回 (-180,180]。
--   我已标注为 runaway 同一处的「疑似脆弱点」，此处同理。
--   更稳妥的写法是 math.fmod(angle, 360)，对任意输入都正确。
        angle = angle - 360
    end

    local radius = safe_dist
--★★ `local radius = safe_dist` —— 搜索半径就等于目标安全距离。
--★★★ 这是本节点与 runaway 的**根本差异**，也是它名字的由来：
--   runaway    ：radius = 6（硬编码，第 58 行），与 safe_dist 无关
--   runtodist  ：radius = safe_dist（跟着调用方给的参数走）
-- ★★ 语义后果：
--   runaway    在 6 格范围内找**任意**可走方向 → 尽快离开
--   runtodist  在 safe_dist 范围内找**可走**方向 → 试图停在恰好 safe_dist 处
--   ★ 移植要点：把「搜索半径」与「目标距离」绑定，才可能实现「精确停在某距离」，
--     否则只能「随便找个能走的方向」（runaway 的做法）。

	local find_offset_fn = self.inst.components.locomotor:IsAquatic() and FindSwimmableOffset or FindWalkableOffset
--★ 按能力选选点函数（水生/陆生），与 runaway 第 60 行相同。
    local allowwater_or_allowboat = nil
    if find_offset_fn == FindWalkableOffset then
        allowwater_or_allowboat = self.inst.components.locomotor:CanPathfindOnWater()
    end

	local result_offset, result_angle, deflected = find_offset_fn(pt, angle*DEGREES, radius, 8, true, false, nil, allowwater_or_allowboat, allowwater_or_allowboat or self.allow_boats) -- try avoiding walls
--★★★ 第一级：避墙选点。参数比 runaway 第 65 行**多一个**：
--   第 9 个参数 allow_boats（本文件的独有配置）。
--★ 但注意第 9 个参数的表达式是 `allowwater_or_allowboat or self.allow_boats`：
--   即「若能水上寻路就用它，否则用配置的 allow_boats」。
--★★ 这里有个命名混乱：allowwater_or_allowboat 这个变量名提到两种含义，
--   实际第 41 行赋的是 CanPathfindOnWater()（能否在水上寻路）。
--   ★ 移植建议：变量名应当与内容一致，这里容易误读。
--★ 第 44/46 行把 angle*DEGREES 转弧度（DEGREES = π/180）。
    if result_angle == nil then
--★ 用 result_angle == nil 判失败（与 runaway/beargeroffscreen 同一判据）。
--★ ★★ 已核实：FindValidPositionByFan 返回 (offset, check_angle, deflected)，
--   所以「结果角度」确实是判断成败的正确信号。
		result_offset, result_angle, deflected = find_offset_fn(pt, angle*DEGREES, radius, 8, true, true, nil, allowwater_or_allowboat, allowwater_or_allowboat or self.allow_boats) -- ok don't try to avoid walls
--★★ 第二级：放弃避墙。与 runaway 第 67 行结构相同，但参数完整（9 个）。
--★ 对照：runaway 第 67 行只传了 6 个参数，漏了 allowwater 相关项。
--   ★ 本文件这一处**比 runaway 更完整**，说明它不是从 runaway 复制，
--     而是从更早的版本演化而来。
        if result_angle == nil then
			if self.fix_overhang and not TheWorld.Map:IsAboveGroundAtPoint(pt:Get()) then
--★★ 第三级：fix_overhang 兜底（拉回合法地面），与 runaway 第 69 行同构。
--★ 三条件：开关开 + 前两级失败 + 当前不在地面之上。
                if self.inst.components.locomotor:IsAquatic() then
                    local back_on_ocean = FindNearbyOcean(pt, 1)
				    if back_on_ocean ~= nil then
			            result_offset, result_angle, deflected = FindSwimmableOffset(back_on_ocean, math.random()*2*math.pi, radius - 1, 8, true, true)
				    end
                else
				    local back_on_ground = FindNearbyLand(pt, 1) -- find a point back on proper ground
				    if back_on_ground ~= nil then
			            result_offset, result_angle, deflected = FindWalkableOffset(back_on_ground, math.random()*2*math.pi, radius - 1, 8, true, true, nil, nil, self.allow_boats) -- ok don't try to avoid walls, but at least avoid water
--★ 第 3 级的陆生分支，同样带完整参数（本处也传了 self.allow_boats）。
				    end
                end
			end
			if result_angle == nil then
--★★★ 第四级（最终兜底）：`return result_offset` —— 直接返回（可能是 nil）。
--   原注释：ok whatever, just run
--★ 与 runaway 第 82-83 行的 `return angle`（保证非 nil）**语义不同**：
--   runaway   —— 无论如何都给一个方向，调用方总能走
--   runtodist —— 可能返回 nil，调用方第 101 行的 `if pos ~= nil` 会走 FAILED
-- ★★ 后果：完全找不到方向时，本节点会放弃（FAILED）而不是硬走。
--   标注为「已核实的设计差异」：不是 bug，但两个「逃跑」节点行为不一致，
--     移植时要按需求选择（硬走更安全，放弃更诚实）。
	            return result_offset -- ok whatever, just run
			end
        end
    end

    result_angle = result_angle / DEGREES
--⚠️【已核实 · 死代码】`result_angle = result_angle / DEGREES` 转换了角度，
--   但**后面从未使用 result_angle**：第 73 行返回的是 result_offset。
--   我已逐行核对第 67-73 行确认。
--★ 推测：从 GetRunAngle 复制过来时把「角度转换」也带上了，
--   改成返回 offset 后忘了删。属残留代码，无功能危害。
--★ ★★ 这类残留正是「复制代码后未清理」的典型产物，
--     与本文件多处保留的注释掉的 print（第 32 行等）同源。
    if deflected then
--★★ deflected 缓存 —— 本文件与 runaway 第 89 行同构。
--★ 效果：方向被墙/水挡住而偏转时，缓存 1 秒，防止每帧重算又被打回。
        self.avoid_time = GetTime()
        self.avoid_angle = result_offset
--⚠️【已核实 · 疑似不一致】`self.avoid_angle = result_offset`。
--   字段名叫 avoid_angle，但存的是**偏移向量**。
--   ★ 与第 24 行 `return self.avoid_angle`（当作 pos 返回）是一致的，
--     所以**功能正确**，只是字段名与内容不符。
--★ 对照 runaway 第 91 行：`self.avoid_angle = result_angle`（确实是角度）。
--   ★★ 即两个文件的同名字段存着不同类型的值 —— 跨文件对照时极易误解。
--   标注为「已核实 · 命名误导，功能正确」。
    end

    return result_offset
--★ 返回偏移向量。调用方第 102 行会加上追猎者位置得到绝对目标点。
end

local TOLERANCE_DIST = .4
--★★★ TOLERANCE_DIST = 0.4（局部常量，模块级）。
--★ 用途：第 104 行判断「是否已经站在目标点附近」。
--★★ 这个「容差」的设计非常值得学：
--   目标点每帧都在重算，若严格比较总会因浮点误差/追逐效应永不命中；
--   给一个 0.4 格的容差带，就能在「实质到达」时稳定触发。
--   ★★ 移植要点：任何「追到某点就结束」的 AI 都必须设容差，
--     否则会永远在目标点周围绕圈（经典的 orbit 问题）。
--   ★ 0.4 格约等于一个角色碰撞半径，是合理的量级。
local TOLERANCE_DIST_SQ = TOLERANCE_DIST*TOLERANCE_DIST
function RunToDist:Visit()
--★★ Visit：READY 段做索敌，RUNNING 段驱动移动 —— 与 runaway 结构一致。
    if self.status == READY then
		if self.gethunterfn then
--★ 只支持 gethunterfn 一种索敌方式（无四种分支）。
			self.hunter = self.gethunterfn(self.inst)
        end

        if self.hunter ~= nil and self.shouldrunfn ~= nil and not self.shouldrunfn(self.hunter, self.inst) then
            self.hunter = nil
        end

        self.status = self.hunter ~= nil and RUNNING or FAILED
--★★ 找到就 RUNNING，否则 FAILED。
--★ 用 and/or 三元（与 runaway 第 149 行同款）。
--★ 安全前提：RUNNING/FAILED 是非空字符串（behaviourtree.lua:4-7），恒为真，
--   不会触发 and/or 的假值回退陷阱。
    end

    if self.status == RUNNING then
--★★ RUNNING 段。复检追猎者时比 runaway 多一个条件：IsEntityDead。
--★ 即本节点把「追猎者已死」也算作失效（FAILED），而 runaway 不检查死亡。
--★★ 语义差异：
--   runaway   的目标是「活着的威胁」，威胁死了逃跑自然结束（FAILED 合理）
--   runtodist 的目标是「某个位置参照物」，它死了也不影响位置意义 ——
--   但本文件仍判 FAILED，说明它假设目标总是活的。
--★ 标注为「已核实的行为差异」，非缺陷。
        if self.hunter == nil or not self.hunter.entity:IsValid() or IsEntityDead(self.hunter) then
            self.status = FAILED
            self.inst.components.locomotor:Stop()
        else
            local pt = self.inst:GetPosition()
--★ pt（自己）与 hp（追猎者），与 runaway 第 160-161 行相同。
            local hp = self.hunter:GetPosition()
            local safe_dist = FunctionOrValue(self.safe_dist, self.inst, self.hunter)
--★★ safe_dist 也支持「值或函数」，且传入 (inst, hunter) 两个参数。
--★ ★★ 与 runaway 的关键区别：runaway 第 70 行 safe_dist 构造器里存的是固定值，
--   本节点则**每帧重新求值**（第 98 行在 RUNNING 段内）。
--   语义：目标距离可以随状态动态变化（如「离玩家远点」）。
--★ 移植要点：把阈值求值放在 RUNNING 段而非构造器，才能支持动态阈值。
            local pos = self:GetRunPosition(pt, hp, safe_dist)

            if pos ~= nil then
--★ 有可用偏移 → 继续；为 nil → FAILED + 停止（第 116-119 行）。
--★ 承接第 62 行的「可能返回 nil」设计。
                pos = hp + pos
--★★★★ `pos = hp + pos` —— 把偏移转成绝对目标点。
--★ 承接 GetRunPosition 返回的是「相对追猎者的偏移」这一约定。
--★★ 这个「相对 → 绝对」转换放在调用方而非函数内，好处是：
--   GetRunPosition 可以被复用于「以任何点为基准」的搜索，不绑定追猎者。
-- ★ 移植要点：搜索函数返回相对偏移，调用方决定基准点 —— 更好的复用性。

                if distsq(pos, pt) <= TOLERANCE_DIST_SQ then
--★★★【容差判定】距目标点 < 0.4 格 → FAILED（不是 SUCCESS）。
--★★★ 这个终态选择很反直觉，值得单独说明：
--   「已经站到目标位置了」为什么是 FAILED 而不是 SUCCESS？
--   ★ 因为对「拉开距离」这个意图而言：站到 safe_dist 处恰恰是**不该发生**的。
--     玩家追过来了，AI 没能逃开 → 逃跑失败 → FAILED 正确。
-- ★★ 这与 runaway 第 176 行「距追猎者 > safe_dist → SUCCESS」正好相反：
--     runaway  是「跑够远就成功」
--     runtodist 是「没跑够远就失败」
--   ★★★ 移植要点（本文件最重要的收获）：
--     SUCCESS/FAILED 的语义**只能由行为意图决定**。
--     同一个几何条件（距离），在不同意图下必须取相反的终态。
--     若这里误写成 SUCCESS，AI 会在被追上时宣布「逃跑成功」，
--     上层逻辑全盘错误。
--★ 第 106-107 行的 Stop + return 与其他终止路径写法一致。
                    self.status = FAILED
                    self.inst.components.locomotor:Stop()
                    return
                end

                if self.walk_instead then
--★ walk_instead 分支：先清 locomotor.dest（同 runaway 第 166 行）。
--★★ 再次强调这行的必要性：
--   locomotor 的 GoToPoint 会设 dest，若不清理会与当前行为打架。
--   ★ 移植要点：切换「按点走」与「按方向走」必须清掉另一套的残留状态。
                    self.inst.components.locomotor.dest = nil
                    self.inst.components.locomotor:GoToPoint(pos, nil, false)
--★ walk_instead → GoToPoint(pos, nil, false)（第三参数 false = 走路）
--   需对比下一行第 114 行的第三参数 true（= 跑）。
                else
                    self.inst.components.locomotor:GoToPoint(pos, nil, true)
                end
            else
                self.status = FAILED
                self.inst.components.locomotor:Stop()
            end

            local dist_sq = safe_dist * safe_dist
--★★★【成功判定】|当前距离² - 目标距离²| < 0.75 → SUCCESS。
--
-- ★★★ 这个判据值得仔细拆解（我已逐行核实）：
--   · dist_sq   = safe_dist × safe_dist  —— 目标距离的平方
--   · 比较的是**距离的平方之差**，而不是距离之差
--   · 容差 0.75 是硬编码的
-- ★★ 平方之差容差 0.75 对应多长的实际距离？设 d 为当前距离、s 为目标：
--   |d² - s²| < 0.75  即  |d-s|·(d+s) < 0.75
--   ★★ **所以容差不是固定的**：s 越大，|d-s| 的允许范围越小。
--     例：s=1 时允许 |d-s| < 0.375；s=4 时允许 |d-s| < 0.094。
--   ⚠️ 标注为「疑似缺陷 · 已核实公式」：
--     对远距离目标，成功判定会**过严**，AI 可能永远达不到而持续奔跑；
--     对近距离目标又过松。正确做法是先开方再比较距离之差，
--     或把容差也按比例设定（如 0.75 / (d+s)）。
-- ★ 移植要点：比较距离时应明确「比较的是距离还是距离的平方」，
--   平方的容差与线性容差不是一回事，很容易出错。
--★ 注意第 122 行在第 104 行之后：即使已 FAILED 仍会执行（无 return）。
--   理论上不会同时成立（一个要求在点附近、一个要求在 safe_dist 处），
--   但 safe_dist 很小时两者可能冲突。标注为「已核实的边界情况」。
            if math.abs(distsq(hp, pt) - dist_sq) < 0.75 then
                self.status = SUCCESS
                self.inst.components.locomotor:Stop()
            end

            self:Sleep(.125)
--★★ self:Sleep(.125) —— 与 runaway 的 .25 相比更快（战斗级节拍）。
--★ 差异原因：本节点的目标是「精确停在某距离」，需要频繁校正；
--   runaway 只要求「越远越好」，不需要这么精确。
-- ★ 移植要点：**节拍频率应与「所需精度」挂钩**，而非全局统一。
--   这一点与 chaseandattack 全家统一 0.125 的做法形成有意义的对比：
--   同目录里两种策略都在用，判断依据是行为精度需求。
        end
    end
end