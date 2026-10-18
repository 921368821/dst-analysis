--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/minperiod.lua
-- 模块：行为树节点库 / 节流
-- 职责：装饰型节流节点：自身子节点/条件只有累计到指定周期才允许成功一次。
--       是「用节点做限流」而非「在业务代码里写计时器」的示例。
-- 关键符号：MinPeriod, MinPeriod:Visit, MinPeriod:DBString
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：behaviourtree.lua（LatchNode 是同族但机制不同的实现）, brain.lua（period 语义）
--============================================================
MinPeriod = Class(BehaviourNode, function(self, inst, minperiod, immediate, child)
--[[
-- minperiod.lua —— 最小间隔装饰节点（MinPeriod）：限制某个行为多久才能成功一次
--
-- 【★★★ 与 chattynode 并列，本目录仅有的两个「装饰器（Decorator）」型节点】
--   两者机制相同（转发子节点 + 同步状态），但意图完全相反：
--   · chattynode —— 给子节点「加副作用」（说话），不影响其行为
--   · minperiod   —— 给子节点「加限制」（节流），影响其何时能成功
-- ★★ 对比非常有价值：装饰器的关键在于「转发 + 同步」这个骨架，
--   而骨架之上的策略（说话 / 节流）才是各节点的核心设计。
--
-- 【★ 它解决什么问题？】
-- 场景：蜜蜂每 5 秒该「扇翅膀」（一个 SUCCESS 的子行为），
--   但如果每帧都判「现在该扇翅了吗」，它会一直成功 —— 动作触发过度。
-- 本节点在子节点之前加一道闸：「距上次成功不足 minperiod 就直接 FAILED」。
-- ★★ 语义要点：限制的是**成功频率**，不是执行频率。
--   子节点在冷却期内根本不会被 Visit（第 18 行的 return），
--   所以连「评估」都省了 —— 这也是它比「在子节点里加计时判断」更优的地方。
--]]
--★★ 4 个形参，最后一个是 child（被包裹的子节点）。
--★ 与 chattynode 第 1 行结构相同，`{child}` 传给基类建立父子链接。
    BehaviourNode._ctor(self, "MinPeriod", {child})

    self.inst = inst
    self.minperiod = minperiod
--★ minperiod：最小间隔秒数。
    if not immediate then
--★★★ immediate 开关 —— 决定「是否立刻允许第一次成功」。
--   不传 immediate 时（即为 nil/false）：
--     第 7 行把 lastsuccesstime 设为当前时间
--     → 第 16 行的 time - lastsuccesstime ≈ 0 < minperiod
--     → **第一次也要等 minperiod 秒**
--   传 immediate 时：不初始化 lastsuccesstime（保持 nil）
--     → 第 14 行的 `and self.lastsuccesstime` 条件为假，跳过节流
--     → **立刻可以成功一次**
-- ★★★ 语义清晰：「immediate = 冷却从零开始算」而非「从现在算」。
-- ★ ★ 移植要点：这类「初始状态」开关有两种自然写法：
--   ① 初始化时间戳（默认也要等）—— 本文件
--   ② 保持 nil 并在判断处跳过（首次放行）
--   两种都对，但必须让调用方清楚选的是哪一种。
        self.lastsuccesstime = GetTime()
    end
end)


function MinPeriod:Visit()
--★★ Visit —— 装饰器骨架：取子节点 → 闸门 → 转发 → 同步。
-- ★ 与 chattynode 第 23-27 行结构一致，顺序完全相同。
    local child = self.children[1]
--★ 取唯一子节点（装饰器只包一个）。
	if self.status == READY and self.lastsuccesstime then
--★★★ 闸门：READY 且冷却未结束 → 直接 FAILED 并 return。
-- ★★ 两个设计要点：
-- ① `and self.lastsuccesstime` —— nil 时跳过节流（immediate 模式）
-- ② `return` —— 冷却期内**完全不 Visit 子节点**，直接结束本次调用。
-- ★★★★ 第 ② 点是性能关键：
--   子节点可能很贵（如跑一次空间查询），冷却期内省掉它才是本节点的收益。
--   若只是「设 FAILED 但仍 Visit 子节点」，就退化成了单纯的节流开关，
--   白白付出装饰器的复杂度。
-- ★ 移植要点：**装饰器应该在被装饰对象「不需要工作」时也一并跳过它**。
-- ★ 对照 chattynode 第 25 行无条件 child:Visit()：
--   那个装饰器必须 Visit 子节点（它要「在子节点运行时说话」），
--   本装饰器则不必。**装饰器与被装饰者的耦合方式决定实现方式**。
		local time = GetTime()
		if time - self.lastsuccesstime < self.minperiod then
--★ 冷却未结束（距上次成功不足 minperiod 秒）→ FAILED。
--★ 用 `<` 严格小于；恰好等于 minperiod 时放行（通过冷却）。
-- ★ 对照 leash/leashandavoid 用严格 `<` 导致边界都判 false 的情况，
--   这里的边界处理是对的（单一条件无歧义）。
			self.status = FAILED
			return
--★ 冷却期内**不碰子节点**（见第 14 行的详解）。
		end
	end

    child:Visit()
--★ 冷却结束（或首次）→ 转发给子节点执行。
--★ 与 chattynode 第 25 行相同的透传调用。
--★ ⚠️ 同样存在「手动转发绕过框架机制」的代价（详见 chattynode 第 25 行的说明）：
--   子节点的 SaveStatus/Step 不会被框架调用，其 lastresult 不更新。
    if child.status == SUCCESS then
--★★★ 子节点成功后**记录时间戳** —— 本装饰器的状态核心。
-- ★★ 注意记的是「成功」而不是「执行」：
--   子节点 FAILED 不更新时间戳 → 冷却期不因失败而延长。
-- ★★ 语义正确：minperiod 限制的是「成功频率」，不是「尝试频率」。
--   若记失败，就会出现「不断失败 → 冷却不断延长 → 再也不尝试」的死亡螺旋。
-- ★ ★★★ 移植要点：节流器的计时刻意只记成功，
--   是避免「失败导致永久封禁」的关键设计。这条值得记住。
		self.lastsuccesstime = GetTime()
    end

	self.status = child.status
--★★ 状态同步 —— 与 chattynode 第 27 行完全相同。
-- ★★ 但**本装饰器不总是透传**：第 17 行的 FAILED 是装饰器自己写的。
--   即装饰器可以「否决」子节点的潜在成功（冷却期内一律 FAILED）。
-- ★★★ 与 chattynode 对比（重要区别）：
--   chattynode —— 纯透传，status 完全由子节点决定，装饰器绝不干预
--   minperiod   —— 会干预，在特定条件下直接给 FAILED
-- ★★ 两类装饰器：
--   透明型（副作用型）：绝不改状态，最安全
--   约束型（策略型）：可以否决，用于限流
-- ★ 移植建议：优先写透明型；确需约束时，否决条件要尽量简单可预测。

end

function MinPeriod:DBString()
--★★★ DBString —— 本文件写得最好的部分：把冷却状态可视化了。
--   三种输出：
--   · minperiod 为 nil → 无输出（return nil，GetString 会显示空括号）
--   · 未在冷却     → "OK (min period is X.XX)"
--   · 冷却中       → "Waiting for X.XX (min period is X.XX)"
-- ★★★ 这正是限流节点最需要的可观测性：
--   排查「为什么这个行为不触发」时，第一时间就要知道「是在冷却期」。
--   没有这行输出，你只能看到 FAILED 而无法区分「条件不满足」与「被节流」。
-- ★★ 移植建议：**给限流/冷却机制配一条「还剩多久」的状态输出**，
--   这是调试限流类机制的基本要求。
    if self.minperiod then
		local time = GetTime()


		local time_since_success = time - (self.lastsuccesstime or 0)
--★ `self.lastsuccesstime or 0` —— nil 时用 0，
--   使 time_since_success = time（很大），自然满足第 37 行的 > minperiod。
--★ 这是一种巧妙的「用哨兵值让条件自动成立」的写法，避免额外的 if。
-- ★★ 与 leashandavoid 第 61 行 `math.sqrt(... or 0)` 同一手法。
-- ★ 移植要点：给可能为 nil 的变量配一个「让它走对分支」的哨兵默认值，
--   比写 if 分支更简洁。
		if not self.lastsuccesstime or time_since_success > self.minperiod then
--★ 双重条件：`not lastsuccesstime`（从未成功过）或已超期。
--★ 第 38 行输出「OK」——告诉调试者「现在可以触发」。
--★ ★ 对照第 14 行的闸门条件（`READY and lastsuccesstime` 然后比较时间），
--   这里复述了同一判定逻辑。两处若不同步就会出现「输出说 OK 但实际被拦」。
--   ★★★ 移植建议：判定逻辑要收敛到一处，不要在两处重复。
--     （本文件因只是展示用途而容忍了重复，属可接受的取舍。）
			return string.format("OK (min period is %2.2f)", self.minperiod)
		else
			return string.format("Waiting for %2.2f (min period is %2.2f)", self.minperiod-time_since_success, self.minperiod)
--★ 输出「还要等多久」+「最小间隔是多少」。
--★ %2.2f 保留两位小数，肉眼足以判断（详见 behaviourtree.lua:483 的说明）。
		end
    end
end
--★★ 无 self:Sleep —— 装饰器不节流自身。
--★ 原因：装饰器自身很便宜（几个时间比较），
--   真正贵的是子节点，而第 18 行的 return 已经在冷却期挡掉了它。
-- ★★★★ 这一点印证了文件头的性能分析，也说明一个更一般的道理：
--   **优化要花在「贵的那部分」上，而不是无差别地给所有节点加 Sleep**。
--   装饰器已经把开销控制在自己身上，无需再调 Sleep。
-- ★★ 全目录的休眠策略对比（本文件是一个独特样本）：
--   · chaseandattack/standandattack → Sleep(.125)，战斗要快
--   · follow/approach              → Sleep(.25)，移动不敏感
--   · wander                        → Sleep(剩余时间)，最精细
--   · findlight                     → 不 Sleep，靠内部 1 秒节流
--   · doaction                      → 不 Sleep（要低延迟等结果）
--   · minperiod（本文件）           → 不 Sleep（自己已经很便宜）
-- ★ ★★ 结论：**Sleep 不是必选项，而是一种「代价 vs 精度」的选择**。
--   至少三种降低开销的手段：Sleep 节流、内部降频、跳过调用。