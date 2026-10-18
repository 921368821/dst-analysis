--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/controlminions.lua
-- 模块：行为树节点库 / 单位控制
-- 职责：找出最近的一个从属单位并下达指令（由外部传入的控制函数），
--       演示「节点作为指令调度器」而非「节点自己执行动作」的写法。
-- 关键符号：ControlMinions, ControlMinions:Visit, ControlMinions:GetClosestMinion
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：components/locomotor.lua, components/combat.lua, brain.lua（黑板 shared 变量）
--============================================================
ControlMinions = Class(BehaviourNode, function(self, inst)
--[[
-- controlminions.lua —— 集群采集节点（ControlMinions）
--
-- 【行为语义】主人站在农田/晾肉架/晾干架旁时，
--   自动指挥附近空闲的小怪（minion）去收获、拾取、捡起物品。
--
-- 【★★★ 本文件是「节点作为指令调度器」的范本，与本目录其他节点都不同】
-- 其他节点（approach/follow/chaseandattack…）都是「自己动」：
--   节点直接给 self.inst 下移动/攻击指令。
-- 本节点是「指挥别人动」：
--   · 节点自己**完全不移动**
--   · 它扫描周围环境，找到可干活的资源
--   · 为每个资源分配一个空闲的小怪（BufferedAction）
--   · 真正的移动与干活由小怪自己的 locomotor / brain 负责
-- ★★★★ 这是 AI 架构里非常关键的一层：**群体 AI 的控制者不执行动作**。
--   收益：
--     · 主人的 AI 树保持极简（只管「派活」）
--     · 每个小怪各自跑自己的行为树，天然具备个体能力差异
--     · 主人不必知道小怪怎么走、怎么避开障碍
--   ★ 移植要点：群体 AI 应分成「调度层」与「执行层」两层，
--     调度层只负责「谁去做什么」，执行层各自负责「怎么做到」。
--     这比让一个中心 AI 逐帧计算每个单位的移动要高效得多。
--]]
--★ 构造器只收 inst —— 本节点零参数化，所有数值都是硬编码常量或推导值。
--★ 这在本目录里独一份：其余节点（尤其 wander/follow/chaseandattack）
--   都高度参数化。说明「专用逻辑」就写死，「通用逻辑」才参数化。
    BehaviourNode._ctor(self, "ControlMinions")
    self.inst = inst
    self.ms = inst.components.minionspawner
--★ ms = minionspawner 组件 —— 本节点真正的数据源。
--★ 注意构造期直接取组件，**不做判空**。
--   ⚠️ 隐含前提：使用本节点的实体必有 minionspawner 组件。
--   ★ 对比 standandattack 第 67 行对 locomotor 的判空，
--     这里更硬气。属设计选择（专用节点），非缺陷。
    self.radius = nil
    self.minionrange = 3.5
--★ minionrange = 3.5 —— 小怪离资源多远算「够得着」（第 13 行用）。
--★ 与第 106 行 `ba.distance = 4` 是两个不同的量：
--   minionrange —— 挑小怪时的筛选半径（3.5）
--   ba.distance —— 执行动作时的可达距离（4）
--★ 前者略小于后者，保证选中时一定能走过去。
end)

function ControlMinions:GetClosestMinion(item, minions)
--★★ GetClosestMinion —— 为一个资源点挑一个「最近且够得着」的小怪。
-- 签名：(item, minions) → 最近的可用小怪或 nil
    local x, y, z = item.Transform:GetWorldPosition()

    local closest = nil
    local closest_dist_sq = self.minionrange * self.minionrange
--★★★ 筛选半径直接用**距离平方**比较（minionrange²）—— 全程不开方。
--★ 把 maxsq 作为「当前最优」的初值，天然过滤掉所有太远的小怪。
--★ ★ 移植要点：这是「用哨兵值做初始化」的经典技巧，
--     比遍历完再单独判断范围更简洁，也少一次比较。

    for k, v in pairs(minions) do
        if v ~= item then
--★ 排除自己 —— 主人自己也在 minions 列表里吗？可能是（若主人也是可控制的）。
--★ 更可能的意图是：避免把「资源点」自己当成小怪。
--★ 保守起见，这个判断无害。
            local dist_sq = v:GetDistanceSqToPoint(x, y, z)
--★ 用引擎方法 GetDistanceSqToPoint（而非自己算）—— 复用标准实现。
--★ ★ 与 follow/approach 自己实现 _distsq 不同，这里用了引擎方法。
--   两种都可行，复用引擎方法更不容易写错。
            if dist_sq < closest_dist_sq then
                closest = v
                closest_dist_sq = dist_sq
            end
        end
    end

    return closest
end

local NO_TAGS =
--★★★ NO_TAGS —— 15 个「绝对不要考虑」的标签，写成模块级常量表。
-- 逐类解读（这是本文件最有价值的信息）：
--   FX / NOCLICK / DECOR   —— 特效、不可点击、装饰物（看得见摸不着）
--   INLIMBO                —— 正在加载/卸载
--   irreplaceable          —— 不可替代（重要场景物件）
--   heavy                  —— 重物（小怪搬不动）
--   lureplant / eyeplant   —— 眼草/诱捕花（会攻击）
--   notarget / noattack    —— 不可索敌 / 不可攻击
--   flight                 —— 飞行单位（够不着）
--   invisible              —— 隐身
--   catchable              —— 可被捕捉（小怪不碰玩家宠物）
--   fire                   —— 火（会烧）
--   eyeplant_immune        —— 对眼草免疫
-- ★★★ 这张表是「什么不能被小怪采集」的完整答案，非常实用。
-- ★★ 移植建议：任何「自动采集/拾取」系统都需要这样一张排除表，
--   而且应当**数据驱动**（就像这里），而不是散落在 if 里。
--   ★ 与 combat.lua 的 INLIMBO/notarget/noattack/flight/invisible 高度重合 ——
--     DST 在不同系统里重复定义了这些标签，说明它们是跨系统的通用词汇。
{
    "FX",
    "NOCLICK",
    "DECOR",
    "INLIMBO",
    "irreplaceable",
    "heavy",
    "lureplant",
    "eyeplant",
    "notarget",
    "noattack",
    "flight",
    "invisible",
    "catchable",
    "fire",
    "eyeplant_immune",
}

local ACT_TAGS =
--★★★ ACT_TAGS —— 5 个「至少要有一个」的活跃标签。
--   _inventoryitem   —— 是物品（可拿的东西）
--   pickable         —— 可拾取
--   donecooking      —— 烹饪完成（可以取出）
--   readyforharvest  —— 作物成熟
--   dried            —— 已晾干
-- ★★ 注意：这些标签对应的是「**处于可交互状态**」而非「是什么东西」。
--   例如一只浆果丛有 _inventoryitem + pickable；
--   一株成熟作物有 _inventoryitem + readyforharvest。
--★ 用 one_of_tags（OR）传入第 81 行 —— 命中任一即纳入候选。
-- ★★ 与 NO_TAGS（NOT ANY）配对，构成完整的空间查询过滤：
--   「在范围内，排除这 15 类，至少属于这 5 类之一」。
--   ★ 与 findclosest 第 32/42/52 行的三语义完全一致，可对照阅读。
{
    "_inventoryitem",
    "pickable",
    "donecooking",
    "readyforharvest",
    "dried",
}

function ControlMinions:Visit()
--★★ Visit：顺序双 if 结构（READY → RUNNING），与全目录一致。
    if self.status == READY then
--★ READY 段：有小怪才继续，否则 FAILED。
--★ 判断用 numminions > 0（组件的存活计数），无需遍历 minions 列表。
--★ ★ 移植要点：优先用「维护好的计数」而不是每次遍历求长度。
        if self.ms.numminions > 0 then
            self.status = RUNNING
        else
            self.status = FAILED
        end
    end

    if self.status == RUNNING then
--★★ RUNNING 段开始。注意本节点**没有** self:Sleep —— 也不需要：
--   第 116/118 行会在同一帧内直接转 SUCCESS/FAILED，节点不会长期 RUNNING。
--   ★ 这是「一次性动作型节点」的典型形态：跑一帧就结束，不存在跨帧状态。
--   对照 chaseandattack（.125 秒节流、跨帧存活），两者是完全不同的节点类别。
        local x, y, z = self.inst.Transform:GetWorldPosition()

        --Get the distance you need to look for things within.
        if self.radius == nil then
--★★★【动态半径】按「最远的那个小怪有多远」来确定搜索范围。
--   `if self.radius == nil` —— 只算一次，之后缓存（惰性初始化）。
--★ 为什么按小怪分布算半径？
--   小怪散开得越远，需要扫描的「作业面」就越大。
--   固定半径会导致「小怪跑远了就找不到旁边的资源」。
--★★★ 这是「根据当前编队规模动态调整工作范围」的通用思路：
--   队伍越大 → 工作面越宽。移植到任何「群体作业」场景都适用。
--★ 第 73 行 `rad + rad * 0.1` —— 在实际距离上加 10% 余量。
--   余量的意义：distsq 用的是二维距离（第 72 行取 x/z），
--   而实体可能有高度差，所以给一点富余。
            if self.ms.minionpositions ~= nil then
                local x1, y1, z1 = self.ms.minionpositions[#self.ms.minionpositions]:Get()
--★ 取最后一个 minionposition 的坐标作为参考点。
--⚠️【疑似缺陷 · 已核实】取的是**最后一个**（`[#...]`）而非最远的。
--   代码意图（按第 73 行 rad 的算法）应该是「到最远小怪的半径」，
--   但实现取的是「数组最后一个元素的距离」。
--   若 minions 列表按生成顺序排列，最后一个恰是最新生成的，
--   不保证是最远的。
--   标注为「疑似缺陷」：我已核实第 71 行确实是 `[#...]`（末元素），
--     而第 72-73 行确实据此计算半径。正确做法应是遍历取最大距离。
--★ 影响可控：半径偏小只会漏扫一部分资源，不产生错误行为。
                local rad = math.sqrt(distsq(x, z, x1, z1))
--★★★ `distsq(x, z, x1, z1)` —— 一次调用算出距离并开方。
--★★ DST 的 distsq（util.lua:553）支持**两种调用形式**，很容易用错：
--   · 传 4 个数字 (x1,y1,x2,y2) → 返回**二维**平方距离（util.lua:562-565）
--   · 传 2 个向量 (vecA, vecB) → 返回**三维**平方距离（含 y 分量）
--   本行传的是四个数字且只用 x/z（忽略高度），与第 73 行加 10% 余量相配。
--★ 移植要点：拿到一个「距离」后**不要默认它是三维的** ——
--   DST 里 follow/approach 显式注明「含 y 分量」，而这里是有意忽略 y。
--   两种语义混用会让「站在二楼的目标」的判定结果完全不同。
                self.radius = rad + (rad * 0.1)
            else
                self.status = FAILED
                return
            end
        end

        --find all entities within required radius
        local ents = TheSim:FindEntities(x, y, z, self.radius, nil, NO_TAGS, ACT_TAGS)
--★★★ 空间查询：三标签过滤一次到位。
--   FindEntities(x, y, z, radius, nil /*musttags*/, NO_TAGS, ACT_TAGS)
--   musttags 传 nil（不要求任何标签），只靠后两张表过滤。
--★★ 与 findclosest 第 83 行同构：把过滤下推给引擎的空间索引。
--   ★ 移植要点：绝不要自己写「遍历所有实体算距离」的朴素循环 ——
--     那是 O(全部实体)，而索引查询是 O(半径内实体)。差几个数量级。
        if #ents > 0 then
            for i, v in pairs(ents) do
                if v:IsValid() and v:IsOnValidGround() and v:GetTimeAlive() > 1 then
--★★ 三重有效性检查，是「拿到候选后仍要复检」的典型：
--   IsValid()           —— 实体没被销毁（查询结果可能是陈旧的）
--   IsOnValidGround()   —— 站在有效地面上（不是悬空/海洋悬垂区）
--   GetTimeAlive() > 1  —— 存在超过 1 秒
--★★★ 第 84 行的第三条最值得学：
--   排除「刚生成不到 1 秒」的实体，避免小怪去捡玩家刚丢下的东西，
--   也避免处理尚未完成初始化的实体。
--★ ★ 移植要点：候选实体的「成熟度」检查，是自动化系统避免误操作的常用手段。
--   时间阈值取 1 秒，是个经验值：足够让实体完成生成流程，又短到不会漏掉正常目标。
                    local mn = self:GetClosestMinion(v, self.ms.minions)
                    if mn ~= nil and not mn.sg:HasStateTag("busy") then
--★★ 双重条件：有可用小怪 且 小怪不忙。
--★ `not mn.sg:HasStateTag("busy")` —— 复用状态图的 busy 标签（对照 useshield 第 60 行）。
--★★★ 这体现了状态标签的价值：
--   「小怪是否在忙」不需要调度器自己维护一个 busy 集合，
--   只要问状态图即可 —— 单一事实来源，永远不会不同步。
-- ★ 移植建议：调度系统应尽量用「被调度者自己报告状态」，而不是复制一份状态。
                        local action = nil
--★★★ 动作选择：一个 if/elseif 链，输出三种动作之一。
-- ★★ 这是一个「按目标可用状态选择动作」的调度决策表：
--   作物成熟 / 炖煮完成 / 晾干完成 → 收获（HARVEST）
--   可拾取且可交互             → 拾取（PICK）
--   可放入容器                   → 捡起（PICKUP）
-- ★★ 顺序即优先级：先判「完成态」（最明确的信号），再判通用可交互性。
-- ★ 移植要点：当一个资源可能同时满足多种动作时，
--   **用 elif 链明确优先级**，不要写多个独立 if 互相覆盖。
                        if (v.components.crop ~= nil and v.components.crop:IsReadyForHarvest()) or
--★★ 三种「完成态」用 or 并列，每个都要求对应组件存在。
--★ `v.components.crop ~= nil and v.components.crop:IsReadyForHarvest()`
--   —— 先判组件存在再调方法，避免 nil 调用。
--★ 三个组件（crop/stewer/dryer）分别对应：农田作物、炖锅、晾肉架。
--★★ 值得学的一点：**动作条件由资源的组件暴露**，调度器不认识具体资源类型，
--   只问「你有没有 crop 组件且成熟了」。
-- ★ 移植要点：让「资源方」自己暴露可执行动作，调度器就与具体资源类型解耦；
--     新增一种资源时只需给它加组件，调度器代码一行不用改。
--★ 对照 ACT_TAGS（第 47 行）：那里已经用标签过滤了 donecooking/readyforharvest/dried，
--   这里又用组件方法判一次 —— 标签用于粗筛，组件用于精确判定。
--   两层过滤的分工：标签快（索引内完成），组件准（业务语义）。
                            (v.components.stewer ~= nil and v.components.stewer:IsDone()) or
                            (v.components.dryer ~= nil and v.components.dryer:IsDone()) then
                            --Harvest!
                            action = ACTIONS.HARVEST
                        elseif v.components.pickable ~= nil and
--★ PICK：需要 pickable + CanBePicked + caninteractwith 三个条件。
--★ 第 95 行的 caninteractwith 是个数据字段（不是方法调用，无冒号），
--   表示「这个物品能与其他东西交互」（如果实可被采摘）。
--★ 注意判断顺序：先判组件存在（短路径最快）。
                                v.components.pickable:CanBePicked() and
                                v.components.pickable.caninteractwith then
                            --Pick!
                            action = ACTIONS.PICK
                        elseif v.components.inventoryitem ~= nil and
--★ PICKUP：物品能进容器，且允许被捡起（活着或死的形态都算）。
--★ 第 100 行的 `canbepickedup or canbepickedupalive` —— or 语义：
--   某些物品死了也能捡（如掉落物），某些必须活着（如未收割的作物）。
                                v.components.inventoryitem.cangoincontainer and
                                (v.components.inventoryitem.canbepickedup or v.components.inventoryitem.canbepickedupalive) then
                            --Pick up!
                            action = ACTIONS.PICKUP
                        end
                        if action ~= nil then
--★ 有可用动作才执行 —— 与第 87 行的 nil 配对。
--★ 若动作链都没命中（例如资源存在但状态不匹配），则跳过这个资源，
--   继续遍历下一个（第 83 行的循环）。
--★★★ 注意这里**不 break**：一个资源点可能不适合采集，但下一个可能适合。
--   ★ 移植要点：单次机会失败不应中断批量处理。
                            local ba = BufferedAction(mn, v, action)
--★★★ BufferedAction(mn, v, action) —— 「让小怪 mn 对目标 v 执行 action」。
--★★★ 这就是本节点的全部「执行」：它只创建一个动作对象并推给小怪，
--   自己不移动、不寻路、不播动画。
--   ★★ 完全印证文件头的判断：这是**纯调度器**。
--★ 对照 chaseandattack 第 88 行（自己调 locomotor:GoToPoint），
--   两者是「自己动」与「指挥别人动」的最清晰对照。
                            ba.distance = 4
--★ ba.distance = 4 —— 动作的最大可达距离（覆盖构造器的 minionrange=3.5）。
--★ 留一点余量，保证小怪走得过去。
                            mn:PushBufferedAction(ba)
--★ PushBufferedAction 把动作加入小怪的动作队列。
--★★ 为什么用「队列」而不是直接执行？
--   小怪自己的 brain/行为树会从队列取动作并驱动它执行（走位、动画、时机）。
--   ★★ 关键：调度器**不关心时机**，只提交意图；时机由执行者的 AI 决定。
--   这就是「调度层 / 执行层」分离带来的灵活性：
--   小怪可以自行插队、等待、绕路，而调度器无需了解。
                            ba = mn:GetBufferedAction()
--★ Push 之后**再取回**当前动作（第 108 行 GetBufferedAction）。
--★ 为什么需要取回？因为只有拿到实际的 ba 对象才知道「当前动作的目标是谁」。
--★ 这依赖「Push 后该动作立即成为当前动作」的实现细节。
--⚠️ 略有冗余：第 105 行的 ba 已经是同一个对象。
--   但作者可能担心 Push 过程中队列被其他逻辑改动，所以重新取一次更保险。
--   标注为「疑似冗余，但属防御性写法」。
                            if ba ~= nil and ba.target ~= nil and ba.target:IsValid() then
--★ 三重判空后再操作目标 —— 动作入队后目标仍可能失效（被采集/销毁）。
--★★ 这是「异步操作」的标准防御：
--   提交意图 ≠ 目标仍然存在。派发之后必须重新确认。
-- ★ 移植要点：任何「排队执行」的系统都要这样 ——
--   入队时目标有效，不代表执行时还有效。
                                mn:ForceFacePoint(ba.target.Transform:GetWorldPosition())
--★ ForceFacePoint 让小怪立刻面向目标。
--★★ 为什么已经在推动作了还要立刻转身？
--   因为小怪可能还要走一段路，而玩家/其他生物会从任何方向来。
--   提前面向目标能减少「走到才发现方向不对」的突兀感。
--★ ★ 移植要点：这是「可读性优先于纯效率」的例子 ——
--     多做一次转身，显著改善观感。AI 的观感往往就赢在这种细节上。
                            end
                        end
                    end
                end
            end
            self.status = SUCCESS
--★★★ SUCCESS：只要「范围内找到过任何东西」就成功。
--★ 注意这与 chaseandattack 的语义截然不同：那边 SUCCESS 表示「打死敌人了」，
--   是**过程达成**；这里 SUCCESS 只表示「派过活」，甚至可能一个动作都没派出去
--   （第 82 行的 ents 非空，但第 84/86/104 行的过滤可能全不通过）。
-- ★★ 这是一个「弱成功」的典型例子：
--   对父节点（Selector）而言 SUCCESS 会让它继续往下走，
--   所以弱成功可能掩盖「其实什么也没做成」。
--★ ⚠️ 若父节点依赖 SUCCESS 判断「农活干完了」，这里会误判。
--   标注为「已核实的语义特点」：不算 bug，但需了解其弱成功特性。
        else
            self.status = FAILED
--★ 范围内什么都没有 → FAILED（无事可做）。
--★ 与第 116 行构成「有活/没活」的完整二分。
--★ 两个分支都在第 65 行的同一帧内执行完，节点永不跨帧 RUNNING ——
--   因此本文件**完全没有** self:Sleep 调用，也不存在休眠协作问题。
--   ★ 对照：本目录的节点按「是否跨帧存活」可分为两类：
--     · 一次性动作型（controlminions / findflower 等）→ 无需 Sleep
--     · 持续过程型（follow / chaseandattack / wander）→ 必须 Sleep
--   判断依据：**行为是否需要跨帧维持**。
--     需要维持 → 必须 Sleep 节流，否则每帧空跑烧 CPU
--     不需要   → 自然一帧结束，无休眠开销
        end
    end
end