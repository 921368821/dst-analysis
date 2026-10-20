--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：behaviours/chattynode.lua
-- 模块：行为树节点库 / 表演
-- 职责：让实体播放一段带时序的说话/表演动作（按 schedule 表推进），
--       是不影响战斗的「纯表演节点」范例。
-- 关键符号：ChattyNode, ChattyNode:Visit
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：stategraph, animstate, behaviourtree.lua（Sleep 节流）
--============================================================
ChattyNode = Class(BehaviourNode, function(self, inst, chatlines, child, delay, rand_delay, enter_delay, enter_delay_rand)
--[[
-- chattynode.lua —— 说话装饰节点（ChattyNode）：在执行某个行为的同时周期性地说话
--
-- 【★★★ 本文件是 behaviours/ 里唯一的「装饰器（Decorator）」型节点 ——】
--   其余 28 个节点都是叶子节点：自己完成一件事。
--   本文件**包住一个子节点**：自己不执行行为，只负责「在子节点跑的同时说废话」。
--
-- 【★ 装饰器的实现方式：直接调用子节点的 Visit】
--   第 24-27 行是全部的机制：
--       child:Visit()              -- 让子节点自己干活
--       self.status = child.status -- 把子节点的状态**照搬**给自己
--   ★★★ 即：这是一个「透传（pass-through）」节点 ——
--     自己不改变任何决策结果，只在过程中「顺便说话」。
--   ★ 移植要点：装饰器在行为树里极其有用（加日志、加计时、加副作用），
--     其实现要点只有一个：**转发子节点调用 + 同步状态**。
--     忘记同步状态（不写 self.status = child.status）是新手最常见的 bug，
--     表现为「装饰器永远 FAILED」或「装饰器阻断了子节点的终态上报」。
--
-- 【★★★ 三种说话内容的形态（第 41/58/67 行）】
--   function  → 运行时生成台词（回调形式，最灵活）
--   table     → 从字符串数组里随机挑一条（旧式，仅主机显示）
--   字符串     → STRINGS 里的表名（联网显示，走 Chatter）
-- ★ 三条分支各有取舍：
--   · function —— 台词可依赖运行时状态（如「你带了几个物品」）
--   · table    —— 简单随机，但第 59 行注明「legacy, only show on host」
--   · 字符串    —— 走 talker:Chatter，能正确网络同步给所有客户端
-- ★★ 移植要点：游戏内台词若要多人可见，必须走第三条（可同步通道），
--     前两条只能本机看到。这是联机游戏最容易踩的可见性坑。
--]]
--★★ 8 个形参，其中 child 是被包裹的子节点（第 2 行传给基类）。
--★ `BehaviourNode._ctor(self, "ChattyNode", {child})` ——
--   第三个参数是 children 数组，基类会自动给 child 设 parent（behaviourtree.lua:433-437）。
--   ★ 装饰器必须遵守这个约定，否则 child 的 parent 为 nil，
--     DoToParents 之类向上广播的机制会失效。
--★ 注意 child 在参数列表的第 4 位，却最先被使用 —— 参数顺序略反直觉。
    BehaviourNode._ctor(self, "ChattyNode", {child})

    self.inst = inst
    if type(chatlines) == "table" and chatlines.chatterparams then
--★★★ 三种台词形态的判别入口：`chatlines` 是带 chatterparams 的特殊表。
-- ★★ 这是一种很巧妙的「扩展同一个参数」手法：
--   若调用方传普通数组 { "a", "b" }        → 走 else 分支（旧式随机）
--   若调用方传 { name = "STRINGS.FOO",     → 走 if 分支（走 Chatter）
--                   chatterparams = {...} }
--   ★★ 即「表」既是数组也可能是字典，靠是否有 name 字段区分。
--   ★ 移植要点：在 Lua 里这很自然（表可混合），但要求**判别键必须明确**；
--     移植到强类型语言时，应改用显式的 variant/联合类型。
        -- NOTES(JBK): Having chatterparams allows for meta information about how to present the text using chatter.
--★★ 原注释（保留）：
--   "NOTES(JBK): Having chatterparams allows for meta information about how to
--    present the text using chatter."
--   翻译：「笔记(JBK)：带 chatterparams 允许附带关于【如何用 chatter 展示这段文本】的元信息。」
--   并给出了数据格式示例：{ name = "STRINGTABLENAME", chatterparams = { ... } }
--★ 用 `NOTES(作者缩写)` 前缀标注，这是团队协作里非常规范的注释习惯。
--   ★ 移植建议：注释署名能让后来者知道该问谁，比匿名注释有用得多。
        -- { name = "STRINGTABLENAME", chatterparams = { ... }, }
        self.chatlines = chatlines.name
        self.chatter_time = chatlines.chatterparams.time
--★ 四个 chatter 元参数：展示时长 / 强制文字 / 回声优先级 / 回声聊天优先级。
--★ 「回声（echo）」指 NPC 的台词在多人聊天框里的显示方式与优先级。
--   ★ 这属于纯表现层参数，被完整地参数化出来，很好。
        self.chatter_forcetext = chatlines.chatterparams.forcetext
        self.chatter_echotochatpriority = chatlines.chatterparams.echotochatpriority
    else
        self.chatlines = chatlines
    end
    self.nextchattime = 0
--★ nextchattime 初值 0 —— 配合第 40 行的 `t > self.nextchattime` 立即触发首次说话。
--★ 与 useshield 第 8 行的「用初值表达初始状态」是同一手法（对照那边的详解）。
	self.delay = delay
--★★ 四个时长参数，全部可为 nil（第 36/37/84 行的 `or 默认值` 兜底）：
--   delay / rand_delay       —— 两次说话之间的间隔（默认 10 + random()*10 秒）
--   enter_delay / enter_delay_rand —— **每次进入节点时的初始延迟**
--★ 后两个是本节点独有的设计，意义见第 32-38 行的详解。
	self.rand_delay = rand_delay

	self.enter_delay = enter_delay
	self.enter_delay_rand = enter_delay_rand
end)

function ChattyNode:Visit()
--★★ Visit —— 装饰器的全部实现只有四行，但每行都有讲究。
    local child = self.children[1]
--★ 取唯一子节点。装饰器只包一个（构造器传的是 {child} 单元素表）。
--★ 若要支持多子节点包装（如「对每个子节点都说话」），这里就要改成循环。
    child:Visit()
--★★★★【★ 装饰器的第一要务：转发】
--   child:Visit() —— 直接调用子节点的行为逻辑。
--   ★★ 注意是「直接调用」而非「放进树里让框架调度」——
--     这意味着 chattynode 自己就是被调用的那个节点，它代子节点执行了。
--   ★ 这也解释了为什么状态要手动同步（第 27 行）：
--     框架本轮只会 Step 到 chattynode 这一层，
--     child 的 SaveStatus/Step 不会被框架自动调用。
--     ⚠️ 因此 child 的 lastresult 字段不会被更新（调试输出里可能不准），
--     且 child 的 Sleep 声明**会生效**（它设的是自己的 nextupdatetime，
--     但 GetSleepTime 是从 chattynode 调用的，所以实际不生效）。
--     ★★★ 这是一个「手动转发」相对「原生树结构」的代价，
--       移植自定义装饰器时要注意：转发调用会绕过框架的部分机制。
	local prev_status = self.status
--★ prev_status 先存旧状态，用于第 32 行判断「本帧是否刚进入」。
--★★ 必须在改 self.status **之前**存 —— 这就是「装饰器需要记忆上一状态」的原因。
    self.status = child.status
--★★★★【★ 装饰器的第二要务：同步状态】
--   self.status = child.status —— 照搬子节点状态。
--★★★ 这是整个装饰器机制的核心一行，它保证了「装饰不影响语义」：
--   · 子节点 FAILED → 装饰器也 FAILED → 父节点继续试下一个分支
--   · 子节点 SUCCESS → 装饰器也 SUCCESS → 父节点继续往下走
--   · 子节点 RUNNING → 装饰器也 RUNNING → 继续维持行为
--   ★★★★ 移植要点：装饰器**绝不能**改变子节点的终态。
--     一旦装饰器「自己的逻辑」影响了 status（比如为防抖改成 FAILED），
--     整个父级分支的选择就变了 —— 这是装饰器最危险的改法。
--★ 本装饰器只在其上**追加**副作用（说话），不修改 status 语义，是正确写法。

    if self.status == RUNNING then
--★ 只有子节点在跑时才说话 —— 行为结束就不啰嗦，符合直觉。
--★ 三个分支分别对应构造器第 5 行的三种台词形态。
        local t = GetTime()

		if prev_status ~= RUNNING then
--★★★【★ enter_delay 的意义 —— 本节点独有的细腻设计】
--   条件：prev_status ~= RUNNING，即「本帧刚从非 RUNNING 进来」。
--   效果：进入节点时**重置**下一次说话的时间点。
-- 原注释（保留）：
--   "Allow for an initial delay when entering the node.
--    Use this for things like Wander, where you stay in the state
--    for a long time, and frequently enter it."
--   翻译：「允许进入节点时有初始延迟。
--     这对 Wander 这类（在该状态停留很久、且经常进入）的行为很有用。」
-- ★★★ 非常好的一段注释 —— 它不只是说明「做了什么」，
--   还说明了「在什么场景下必要」，读者能立刻判断自己是否需要这个特性。
-- ★★ 语义拆解：
--   · 无 enter_delay：进入节点后可能马上说一句
--   · 有 enter_delay（如 5 秒）：进入后先安静 5 秒再说
--   ★ 为什么需要？因为 Wander 会反复「走一段停一段」，
--     若每次进入都立刻说话，NPC 会在每次停顿时都冒一句 —— 极其聒噪。
--   ★★★★ 移植要点：**周期性台词必须有「进入静默期」**，
--     否则话痨 AI 会毁掉整个游戏的氛围。
--     这是本文件最值得抄的一条设计经验。
			-- Allow for an initial delay when entering the node.
            -- Use this for things like Wander, where you stay in the state
            -- for a long time, and frequently enter it.
            local enter_delay_rand = (self.enter_delay_rand ~= nil and math.random() * self.enter_delay_rand) or 0
			self.nextchattime = t + (self.enter_delay or 0) + enter_delay_rand - FRAMES
--★★ `- FRAMES` —— 减掉一帧的时间常量（FRAMES = 1/30，见 constants.lua:16）。
--★ 作用：让时间点**提前一帧**，确保首次判定 `t > nextchattime` 立即成立。
--★★ 这是一个防止「差一点点没触发」的经典技巧：
--   若恰好 t == nextchattime，则第 40 行的严格大于不成立，要等下一帧；
--   减一帧后必然严格大于，首帧就能说话。
--★ ★ 移植要点：定时逻辑里用 `> ` 比较时，减一点余量能避免首次不触发。
--   也可用 `>=` 替代，但减一帧更明确表达了「我就是要它现在触发」的意图。
--★ ★★ 同时它让第 87 行的 Sleep(nextchattime - t) 在首次为负数，
--   而 GetSleepTime 会把负数钳成 0（behaviourtree.lua:583-585），
--   于是首次调用后立即再被更新一次 —— 不浪费一帧。
--   ★ 这是一个很精细的连锁效应，值得仔细体会。
		end

        if self.nextchattime == nil or t > self.nextchattime then
--★ 到点了才说话。`self.nextchattime == nil` 的判空是因为第 37 行可能没赋值过。
--★ 实际上第 37 行在进入时必然赋值，所以 nil 分支近乎不可达。属防御。
            if type(self.chatlines) == "function" then
--★ 形态一：chatlines 是函数 → 运行时生成台词。
--★ 第 42 行调用它并传入 self.inst —— 台词可以依赖实体状态。
--★★ 这是最灵活的形态：能说「你看起来很饿」这类需要上下文的话。
--★ 第 43 行判空：函数返回 nil 表示「这次不说什么」，可做条件台词。
                local str = self.chatlines(self.inst)
				if str ~= nil then
					if self.inst.components.npc_talker then
--★★ 三选一的输出通道：
--   npc_talker 组件存在 → 用它（NPC 专用，支持 Chatter 与回声）
--   否则             → 用通用 talker 组件
--★ 同一个节点兼容两类实体，靠组件探测分流 —— 与 controlminions 的模式一致。
                        local splits = str:split(".")
--★ `str:split(".")` —— 按句号切分成句子数组。
--★ 第 46 行判断首句是否是 STRINGS 里的合法键（本地化表）。
--★★★ 这是**本地化（localization）**的探测：
--   · 首句是合法 STRINGS 键 → 走 Chatter（可本地化、可联网）
--   · 不是                    → 走 Say（当作原文直接说，无法本地化）
-- ★★ 移植要点：让台词「自动判断能否本地化」是个很实用的模式，
--     模组作者写原文也能正常工作，不必强制走 STRINGS。
--★ splits[1] 为 nil 时（字符串以「.」开头）会安全地被判为不匹配。
                        if STRINGS[splits[1]] ~= nil then
                            local echotochatpriority = (self.chatter_echotochatpriority == true and 1)
--★★★ echotochatpriority 的三态归一化（三行表达式合起来读）：
--   true  → 1
--   false → 0
--   其他（nil / 数字）→ 原值透传
--★ 即「布尔转优先级数字，非布尔原样保留」。
--★★ 这是 Lua 里的 and/or 链式三元惯用法（与 wander 第 1 行的兜底同风格）。
--★ 移植要点：当一个参数有「布尔简写」和「精确值」两种用法时，
--   这种归一化写法能在使用处省去 if。比在构造器里转换更好，
--   因为构造器无法区分「用户没传」与「用户传了 false」。
--★ 第 72-74 行是同一段逻辑的复制（同目录内两处重复实现）。
--   可见作者当时在两处分别加的这个能力。属可提取的重复。
                                or (self.chatter_echotochatpriority == false and 0)
                                or self.chatter_echotochatpriority
                            self.inst.components.npc_talker:Chatter(str, nil, echotochatpriority, nil, true)
--★ npc_talker:Chatter(str, nil, echotochatpriority, nil, true)。
--★ 最后一个参数 true（推断为「不打断/打断优先级」或「是否唯一」）。
--★ 我未读 npc_talker 组件源码，故不对该参数含义下断言。
--   ★ 诚实的做法：不确定的参数就别猜，这里如实标注。
                        else
						    self.inst.components.npc_talker:Say(str,nil,true)
                        end
					else
						self.inst.components.talker:Say(str)
					end
				end
            elseif type(self.chatlines) == "table" then
--★★ 形态二：chatlines 是数组 → 随机挑一条。
--★ 原注释（保留）：legacy, will only show on host
--   翻译：「旧式，只会显示在主机上」。
--★★★ 这条注释很重要：它明确告知该分支**不能联机同步**。
--   ★ 移植要点：功能越旧越要标注清楚，否则别人会误用。
--   一条「这句话只在本机显示」的注释，能省下无数排查时间。
                --legacy, will only show on host
                local r = #self.chatlines
--★★ 空表保护 + dumptable 调试输出。
--   原注释：this will crash let us print more information before it does.
--   翻译：「这里本来会崩，先打印更多信息再让它崩」。
--★ 作者明知第 65 行 `math.random(0)` 会崩，
--   但故意先 dump 出来帮助定位 —— 实用的调试技巧。
--   （`math.random(0)` 在 Lua 里确实会抛错，因为区间为 0 无效。）
                if r == 0 then
                    -- NOTES(JBK): This will crash let us print more information before it does.
                    dumptable(self.chatlines)
                end
                local str = self.chatlines[math.random(r)]
--★ 从数组里随机取一条。math.random(r) 返回 1~r 的整数。
--★ 走通用 talker:Say（不走 Chatter），对应第 59 行的「只显示在主机上」。
                self.inst.components.talker:Say(str)
            else
--★ 形态三：chatlines 是字符串 → 视为 STRINGS 里的表名。
--★ 原注释：Will be networked if talker:MakeChatter() was initialized
--   翻译：「若 talker:MakeChatter() 已初始化，则会网络同步」。
--★★★ 这条注释点出一个隐含依赖：**同步能力取决于组件是否调用过 MakeChatter**。
--   ★ 即节点本身不保证同步，组件的初始化状态才是决定因素。
--   ★ 移植要点：跨系统依赖（这里是组件初始化状态）必须在注释里点明，
--     否则会出现「同一个节点在 A 实体上同步、在 B 实体上不同步」的怪问题。
                --Will be networked if talker:MakeChatter() was initialized
                local strtbl = STRINGS[self.chatlines]
--★ 从 STRINGS 取台词表，nil 则不说话（第 70 行保护）。
--★ 多一层 nil 检查：字符串拼错时静默跳过，不崩。
--   ★ 比崩溃好：台词表名写错属于「内容错误」，不该让游戏崩。
                if strtbl ~= nil then
                    local strid = (type(strtbl) == "table" and math.random(#strtbl)) or 0
--★ 从台词表里随机挑一个句子索引。
--★ `(type(strtbl) == "table" and math.random(#strtbl)) or 0`：
--   若是表 → 随机 1~#strtbl；否则（如字符串）→ 0。
--★ ★ 和/or 三元在**这里恰好安全**：math.random 的结果 1~n 恒为真（非零非 nil），
--   不会触发 and/or 的假值回退。
--   ★ 但这是「恰好安全」，不是「明显安全」—— 见 controlminions 与
--     runtodist 里同款惯用法的讨论。移植时需确认随机函数不会返回 0。
                    local echotochatpriority = (self.chatter_echotochatpriority == true and 1)
                        or (self.chatter_echotochatpriority == false and 0)
                        or self.chatter_echotochatpriority
                    self.inst.components.talker:Chatter(
--★ 走 Chatter（可联网）并传入全部 chatter 元参数（time/forcetext/echotochatpriority）。
--★ 这是三条分支里唯一完整传递元参数的（另外两条只传 echotochatpriority）。
--★ 意味着只有走 Chatter 的形态才能用 time/forcetext 控制。
                        self.chatlines,
                        strid,
                        self.chatter_time,
                        self.chatter_forcetext,
                        echotochatpriority
                    )
                end
            end
            self.nextchattime = t + (self.delay or 10) + math.random() * (self.rand_delay or 10)
--★★★ 重置下一次说话时间 = 现在 + delay + random() * rand_delay。
--   默认 10 + random()*10 = 10~20 秒。
--★ ★ 与 wander 的「min + random()*rand」完全同构，是 DST 的标准随机时长模式。
--★ ★★ 注意这一行位于三个分支**之外**（第 85 行的 end 之后），
--   即无论走哪条台词分支都会执行 —— 正确的写法。
--   ★ 移植要点：这类「分支共享的后置逻辑」要放在 if/elseif 链之后，
--     否则容易漏掉某条路径（会导致 AI 卡在某条分支时说话频率失控）。
        end
        if self.nextchattime ~= nil then
--★★★★【★ 装饰器的休眠协作 —— 与其他节点的本质不同】
--   self:Sleep(self.nextchattime - t) —— 睡到下次说话时间。
--★★★ 但这里有个重要事实：本节点能睡多久，实际上受**子节点**约束。
--   机制链条（behaviourtree.lua:612-647 GetTreeSleepTime）：
--     · chattynode 自己调 Sleep → 自己的 nextupdatetime 被设置
--     · 但 GetTreeSleepTime 从树根自顶向下取**最小值**
--     · 子节点若也在 Sleep（或 RUNNING 返回 0），会覆盖/拉低这个值
--   ★★ 于是真实休眠时间 = min(自己说的时间, 子节点要的时间)。
--   ★ 正确的理解：装饰器**不能延长**子节点的休眠，只能缩短。
--   这与「装饰器改变 status 语义」是同一类约束 ——
--   ★★★★ 移植要点：装饰器的作用只能是「透明」或「更保守」，
--     绝不能让被装饰的行为变得更频繁或更慢。
--★ 第 86 行的判空：若 nextchattime 为 nil（不该发生），则不 Sleep。
--★ 另一条路径：若子节点已 RUNNING 且调了 self:Sleep（如 follow 的 .25），
--   整棵树每 0.25 秒醒一次，而 chattynode 的 10~20 秒说话计时仍在累积。
--   ★ 即「被装饰行为活跃时，装饰器的节流自然失效」—— 这是正确的，
--     因为跟随过程中说话本来就应该更频繁（跟着走时絮叨）。
            self:Sleep(self.nextchattime - t)
        end
    end
end