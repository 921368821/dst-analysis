--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/findclosest.lua
-- 模块：行为树节点库 / 查找
-- 职责：按标签在视野半径内挑选最近的一个实体并走到它身边，同时每 5 秒复查一次目标有效性。
--       演示三种标签过滤语义的组合：必须全有(tags) / 必须全无(exclude_tags) / 至少一个(one_of_tags)。
-- 关键符号：FindClosest, FindClosest:Visit, FindClosest:PickTarget, FindClosest:DBString,
--           CHECK_INTERVAL
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：TheSim:FindEntities（实际的空间查询）, components/locomotor.lua,
--           entity:HasTag / IsValid, behaviourtree.lua
--============================================================
local CHECK_INTERVAL = 5
--[[
-- findclosest.lua —— 就近查找节点（FindClosest）：找最近的符合标签的实体并走到它身边
--
-- 【本节点与 approach/follow 的关键差异：目标由自己找】
--   approach / follow：目标由调用方给出（实体或返回实体的函数）
--   findclosest   ：目标由本节点 TheSim:FindEntities 空间查询得出
-- ★★ 因此本节点多出一个别人都没有的职责：**周期性复核目标有效性**
--  （第 26 行的 CHECK_INTERVAL = 5 秒）。
--   理由：空间查询是「瞬时快照」，世界在变，近处的目标随时会消失或跑远。
--   自己找的目标若不复核，节点会死追一个已经无效的对象。
--
-- 【★ 本文件是理解 DST 三种标签语义最清晰的地方】
--   第 32-60 行把三种过滤叠在一起，务必分清：
--     tags        (第 32 行) —— 必须**全部具备**（AND）。一个不缺才行。
--     exclude_tag (第 42 行) —— 必须**全部不具备**（NOT ANY）。命中任一即淘汰。
--     one_of_tags (第 52 行) —— 至少**具备一个**（OR）。
--   ★ 这三者组合起来能表达几乎所有筛选需求，且都是数据驱动。
--   ⚠️ 对比 combat.lua:190 的 ShareTarget 用的是 AND 语义的 musttags ——
--     同为「标签过滤」，语义却相反，最容易在移植时混淆。
--
-- 【★ 与其他节点共享的怪癖：本文件没有 self:Sleep()】
--   这是本节点最值得注意的技术细节，详见第 75 行的说明：
--   FindClosest **不主动声明休眠**，所以 GetSleepTime 返回 0，
--   大脑会在「靠近某人」的全过程中**每帧**都跑一次 Visit。
--]]
--★★ CHECK_INTERVAL = 5 —— 模块级常量（不是 self 字段）。
--   ★ 提取为常量的好处：想调整复核频率时全局搜一眼即可；
--     若散落在 Visit 里写成魔数 5，就没人知道它是「5 秒」还是「5 次」。
--   ⚠️ 代价：它是模块全局，无法按实例配置。
--     若不同生物需要不同复核频率，得把它做成构造参数（这里没做）。

FindClosest = Class(BehaviourNode, function(self, inst, see_dist, safe_dist, tags, exclude_tags, one_of_tags)
--★★ 构造器：see_dist / safe_dist / tags / exclude_tags / one_of_tags。
--   see_dist —— 视野半径（FindEntities 的搜索范围）
--   safe_dist —— **保持的安全距离**（不是抵达距离，见第 75 行）
--   ★★ 注意 safe_dist 的语义是「站在离目标这么远的地方」，不是「走到目标身边」。
--     这与 findflower/findlight 那类「走到东西上面」不同 ——
--     后者传的其实是 0 或极小值。读参数名时容易误解，务必看第 71-75 行。
    BehaviourNode._ctor(self, "FindClosest")
    self.inst = inst
    self.targ = nil
    self.see_dist = see_dist
    self.safe_dist = safe_dist
    self.lastchecktime = 0
--★ lastchecktime 初值 0：保证首次 Visit 时 `GetTime() - 0 > 5` 成立，
--   于是会立刻 PickTarget 一次。不过第 21 行 READY 段已经无条件 PickTarget 了，
--   所以这个初值的实际作用是：保证第二次进入 RUNNING 段（若 <5 秒）不重复查询。
    self.tags = type(tags) == "string" and { tags } or tags
--★★★★ 标签参数的三行归一化 —— 本文件最值得抄的技巧。
--   `type(x) == "string" and { x } or x` 的意思是：
--     传字符串 → 包成单元素表（让调用方不必手写 {"tag"}）
--     传表     → 原样使用
--   ★★ 价值：调用方写 FindClosest(inst, 10, 5, "plant") 就能工作，
--     也能写 FindClosest(inst, 10, 5, {"plant","sapling"})。
--     两种自然度都支持，API 友好度大幅提升。
--⚠️ 陷阱：`and/or` 三元在 Lua 里的经典坑是「and 侧结果为假值就返回 or 侧」。
--   此处安全，因为 { x } 是**表**，表永远为真；且 x 为表时第一个条件为 false 直接返回 x。
--   ★ 移植提醒：只有当 and 侧可能产生 false/nil 时才要小心，此处不属于那种情况。
--★ 三个标签参数（10/11/12 行）用完全相同的手法归一化，风格统一。
--⚠️ 字段名不统一：构造参数叫 exclude_tags（复数），字段叫 self.exclude_tag（单数）。
--   我已对照第 83 行 FindEntities 调用确认传的是 self.exclude_tag，功能正确；
--   属命名瑕疵，非缺陷。读代码时不要被参数名误导。
    self.exclude_tag = type(exclude_tags) == "string" and { exclude_tags } or exclude_tags
    self.one_of_tags = type(one_of_tags) == "string" and { one_of_tags } or one_of_tags
end)

function FindClosest:DBString()
    return string.format("Stay near target %s", tostring(self.targ))
end

function FindClosest:Visit()
--★★ Visit：与同族节点同形的三段式，但这里 READY 段**无条件转 RUNNING**。
--★ 注意与 approach 的区别：approach 在 READY 段就可能直接 SUCCESS（已在范围内）；
--   findclosest 不做这种判断 —— 它刚找到目标，必然需要走过去。
--★★ 移植要点：READY 段允许「直接给终态」，这是让组合节点短路的关键。
    if self.status == READY then
--★ 立刻选目标并进入 RUNNING。无失败分支 —— 因为第 67 行才做有效性判定。
--★ 设计意图：把「找不到目标」也当作一种 RUNNING 状态来处理，
--   下一帧就会在第 67 行转 FAILED。语义上等价，但代码路径更统一。
        self:PickTarget()
        self.status = RUNNING
    end

    if self.status == RUNNING then
--★★ RUNNING 段分成两条路：超过 5 秒就重新选，否则复核当前目标。
        if GetTime() - self.lastchecktime > CHECK_INTERVAL then
--★★★ 周期性重选（每 5 秒一次）。这是本节点的性能与正确性平衡点。
--   「重新选」= 再跑一次 FindEntities，可能换成更近的、或换一个目标。
--★ 为什么不每帧重选？FindEntities 是**全半径空间查询**，
--   在半径 20、附近 200 个实体的场景里是本节点最贵的一步。
--   每帧做 → 一次靠近行为就产生成百上千次空间查询，CPU 直接爆炸
--   （对应 bug-patterns F2/F4 的性能命门）。
--★ 为什么不能完全不重选？因为自己选的目标会失效（死了/跑了/被卸载），
--   节点会死追一个无效对象直到玩家看见它卡住。
--★★ 5 秒 = 「反应迟钝」与「开销可接受」的折中。
--   ★ 移植要点：自己找目标的节点**必须**周期性复核；
--     复核频率是这类节点最重要的性能参数。
--★ 对照本节点**没有** self:Sleep()：每帧都跑 Visit，但只在每 5 秒才做一次昂贵查询。
--   这是一种「低频重活 + 高频轻活」的合理分工，代价是 Visit 的轻活部分
--   （下面 29-77 行的标签检查）每帧都在做。
            self:PickTarget()
        else
--★ 未到 5 秒 → 走 else 分支：复核已选目标是否仍然合格。
			local valid_target = self.targ ~= nil and self.targ:IsValid()
--★ valid_target 是一条「逐层否决」的链：初值有效，任一检查不过就置 false，
--   且后续检查都以 `if valid_target and ...` 为前提（短路）。
--★ 这个结构的好处：一旦判定无效，后面的 HasTag 调用全部跳过，省开销。

			-- Has all of the tags
			if valid_target and self.tags ~= nil then
--★★★【语义一：tags —— AND，全部必须具备】
--   循环里任何一个 tag 缺失就置 false 并 break。
--★ 举例：tags = {"plant","sapling"} 表示「既要是 plant 又要是 sapling」，
--   即「正在流浆的树」。而 tags = {"plant"} 就是「任何植物」。
--⚠️ 移植陷阱：想要 OR 语义必须用 one_of_tags（第 52 行），
--   写进 tags 里会被理解成「两个都要有」，永远筛不出东西。
				for i,k in ipairs(self.tags) do
					if not self.targ:HasTag(k) then
						valid_target = false
						break
					end
				end
			end

			-- Has none of the tags
			if valid_target and self.exclude_tag ~= nil then
--★★★【语义二：exclude_tags —— NOT ANY，命中任一即淘汰】
--   注意这里是「有 k 就 false」，与 tags 的「没 k 就 false」正好相反。
--★ 举例：exclude_tag = {"shadowcreature"} 排除暗影生物 ——
--   只要目标带这个标签，无论它多近都不要。
--★ 这一层是黑名单式过滤，与 combat.lua 的「白名单式排除」思路互补。
				for i,k in ipairs(self.exclude_tag) do
					if self.targ:HasTag(k) then
						valid_target = false
						break
					end
				end
			end

			-- Has or or more of the tags
			if valid_target and self.one_of_tags ~= nil then
--★★★【语义三：one_of_tags —— OR，至少具备一个】
--★ 第 53 行先把 valid_target **强制置 false**，再用循环「找到就翻回 true」。
--   ★★ 这是 OR 语义的正确写法：默认不满足，满足任一才成立。
--⚠️ 对比第 32/42 行的写法：这两个是「默认满足，不满足才否决」（AND/NOT ANY）。
--   三种语义恰好对应三种不同的初始化策略 —— 这段代码是「语义决定结构」的样板。
--★ 举例：one_of_tags = {"cattoy","food"} = 「这些东西里随便哪一个都行」。
--★ 三层是「与」关系叠加：先 AND 检查 tags，再做黑名单，最后要求 OR 成立。
--   注意第 42/52 行都以 `if valid_target` 为前提，所以顺序有意义。
				valid_target = false
				for i,k in ipairs(self.one_of_tags) do
					if self.targ:HasTag(k) then
						valid_target = true
						break
					end
				end
			end

			if not valid_target then
--★ 三层复核都通过才保留目标，否则清空（第 67 行会据此转 FAILED）。
				self.targ = nil
			end
        end

        if self.targ == nil or not self.targ:IsValid() then
--★★ 目标无效 → FAILED，交回父节点（Selector 会去试下一个分支）。
--★ 这一步同时覆盖了「找不到任何实体」和「目标中途失效」两种情况 ——
--   因为 PickTarget 把 self.targ 置为 nil（第 84 行允许 ents[2] 为 nil）。
            self.status = FAILED
        else
            local actual_safe_dist = FunctionOrValue(self.safe_dist, self.inst, self.targ) or 5
--★★ safe_dist 也支持「值或函数」，且**同时传入 inst 和目标实体**。
--   兜底值 `or 5`：safe_dist 为 nil 或函数返回 nil 时用 5。
--★ 移植要点：与外部调用方解耦的节点参数，兜底值比直接报错更实用 ——
--   上层忘配参数时行为退化而不是整棵树崩掉。
            if self.inst:IsNear(self.targ, actual_safe_dist) then
--★★ 到达判定：站在 safe_dist 之内 → SUCCESS + 停止移动。
--★ 用 inst:IsNear 一次判定「双方距离」，比自己算平方更简洁。
--★ 转 SUCCESS 前先 Stop locomotor —— 成功后就该停下，
--   否则会继续朝目标点走、撞上目标。这与 chaseandattack 的「Stop + return」同理。
                self.status = SUCCESS
                self.inst.components.locomotor:Stop()
            else
                self.inst.components.locomotor:GoToPoint(self.inst:GetPositionAdjacentTo(self.targ, actual_safe_dist * 0.98), nil, true)
--★★★ 没到位 → 朝「目标旁边 safe_dist 处」走。三点值得学：
--   ① `safe_dist * 0.98` —— ★★ 乘一个略小于 1 的系数，
--     让目标点比判定边界**略微靠内**。这样到达后一定满足第 71 行的 IsNear，
--     不会因为浮点误差/边界抖动在「差 0.02 格」处反复徘徊。
--     ★★ 这就是滞回思想的极简版：**判定阈值与执行阈值留一条缝**。
--     这是本文件最值得抄的一行，比长篇的逻辑更有移植价值。
--   ② GetPositionAdjacentTo 由实体自己算相邻点，能绕开地形（放在可站立的格子上）。
--   ③ 第三参数 true = 允许跑步。
--★⚠️【与本文件其他节点的重大差异】这里**没有** self:Sleep()。
--   → GetSleepTime 返回 0 → 大脑在整段「走向某人」过程中每帧都执行 Visit。
--   ★ 后果：CPU 开销比 approach/follow（.25s 节流）高约 8 倍。
--   ★ 我判断这是**有意的**：第 71 行的到达判定用了 0.98 的窄缝，
--     若节流到 0.25 秒，到达后的停止会更迟钝、看起来更「黏」。
--     也就是用 CPU 换「靠近动作的顺滑度」。
--   ⚠️ 标注为「疑似设计取舍」而非缺陷：它在半径小、附近实体少时开销可忽略，
--     但若把它用在大量单位上（如牛群/蜜蜂群），会是明确的性能热点。
--   ★ 移植建议：照抄这段时**务必自己补一个 self:Sleep()**，
--     或至少确认使用场景的实体数量级。
            end
        end
    end
end

function FindClosest:PickTarget()
--★★ PickTarget：真正的空间查询。整个节点最贵的一步，故由 CHECK_INTERVAL 节流。
--★ 标签参数原样透传给 FindEntities：see_dist / tags / exclude_tag / one_of_tags。
--   ★ 关键发现：**筛选工作在引擎侧一次完成**，第 32-60 行那三层复核是
--     「拿到结果后的二次确认」，不是筛选本身。
--   ★★ 这是一个重要的性能认知：真正的过滤已下推给 FindEntities 的索引查询，
--     本文件第 32-60 行只是防止「5 秒内目标标签发生变化」的少量遍历。
--     移植时若自己写朴素遍历扫描，复杂度会完全不同 —— 必须做空间索引。
    local x, y, z = self.inst.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, self.see_dist, self.tags, self.exclude_tag, self.one_of_tags)
    self.targ = ents[1] ~= self.inst and ents[1] or ents[2] -- note: its okay that ents[2] might be nil
--★★★ `ents[1] ~= self.inst and ents[1] or ents[2]` —— 排除自己。
--   FindEntities 会把 inst 自己也算进去（距离为 0），所以要跳过。
--★ 注意这里只跳过 ents[1]，若 ents[1] 恰是自己则取 ents[2]（第二近的）。
--   ★ 若自己恰好排在第二（不可能，距离 0 必然第一），所以逻辑成立。
--⚠️ 但存在一个边界：若 ents 只有一项且那一项是自己，则 targ = ents[2] = nil，
--   第 67 行会转 FAILED。原注释也承认 "its okay that ents[2] might be nil"。
--   这是**已知的、有意接受的边界情况**，不是缺陷。
--★ 移植要点：`a ~= b and a or c` 这个惯用法在本文件里能成立，
--   是因为 a（实体）与 b（实体）比较后结果是布尔值，不会触发 and/or 三元陷阱。
--   ★ 但如果改成 `a == b and c or a` 就必须小心 —— 写法差异决定正确性。

    self.lastchecktime = GetTime()
--★ 无论找到与否都更新时间戳 —— 找不到也会「续期」5 秒。
--★ 这是合理的：找不到时第 67 行同帧就转 FAILED，不会进入下一次复核。
--   真正会进入复核的只有「找到了」的分支。
end