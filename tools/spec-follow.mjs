// spec-follow.mjs —— behaviours/follow.lua 逐行深度注释的「行号 → 注释」映射
// 配合 build-follow.mjs 使用。可执行代码行全部来自源文件，本文件只提供注释。
//
// ⚠️ 行号必须与源文件严格对应（follow.lua 实际 165 行），构建器会对越界行号报错。

export default {
  // ══════════════ 文件头 ══════════════
  1: [
    '--[[',
    '-- follow.lua —— 跟随节点（Follow）：把实体维持在目标周围的「三段距离带」内',
    '--',
    '-- 【★★★ 本目录的节点协议 —— 先纠正一个常见误解】',
    '-- DST 的行为树节点**不是** ShouldRun/OnEnter/OnUpdate/OnExit 那套四段式。',
    '-- grep 全目录确认：ShouldRun / DoBehaviour / OnEnter / OnExit 出现次数均为 0。',
    '-- 真实协议是 behaviourtree.lua 定义的**两段式**：',
    '--   · 构造器（Class(BehaviourNode, function(self, ...)）—— 只在**建树时**跑一次',
    '--     做参数存档与事件注册，绝不在这里做决策。',
    '--   · Visit() —— 每一帧（或每次被唤醒）被 BT:Update 调用的唯一入口。',
    '--     内部靠 self.status 分三段：READY（本帧进入）/ RUNNING（持续）/ 终态。',
    '-- 终态只有两个：SUCCESS（本行为成功达成）与 FAILED（本行为不适用）。',
    '-- ★ 终态写完就 return，因为随后 BT:Step 会把整棵跑完的子树 Reset 回 READY。',
    '--   换言之：**SUCCESS/FAILED 是给父节点（Selector/Sequence）本帧看的**',
    '--   一次性信号，不是持久状态。看懂这一点，就看懂了本目录下所有节点。',
    '--',
    '-- 【本文件的「三段距离带」是 DST 跟随 AI 的核心范式】',
    '--   max_dist     —— 超过它才开始追（外圈，滞回起点）',
    '--   target_dist  —— 追到它就算成功，节点转 SUCCESS（中圈）',
    '--   min_dist     —— 近于它就要后退（内圈，避免贴脸叠加）',
    '--   三者构成「进入-收敛-退出」的完整迟滞（hysteresis）带。',
    '-- ★★ 为什么必须三段而不是一个「跟到 3 格」？单一阈值会在边界抖动（oscillation）：',
    '--   跨过阈值 → 向前 → 距离因移动惯性变成小于阈值 → 停下 → 又跨过 → ...',
    '--   怪物会在目标旁边来回抽搐。min_dist 这个「退出带」是止抖器。',
    '--   ★ 移植到自研 AI 时，这是最值得直接照抄的一条：任何「维持在某个范围内」',
    '--     的行为都要有内圈退出条件，否则一定会抖。',
    '--',
    '-- 【构造器参数 —— 参数化节点的标准示范】',
    '--   inst / target —— target 可以是实体**或返回实体的函数**（见 GetTarget）',
    '--   min_dist / target_dist / max_dist —— 数字**或函数**（见 EvaluateDistances）',
    '--   canrun        —— 能否跑步，默认 true（写 ~= false 而不是 if nil）',
    '--   alwayseval    —— 每次 Visit 都重算距离，还是仅换目标时算（默认 true）',
    '--   inlimbo_invalid —— 目标处于加载/卸载中是否视为无效',
    '--]]',
  ],

  // ══════════════ 数字参数支持「函数形式」 ══════════════
  6: [
    '--★★ 「值或函数」双形态参数的标准写法（min_dist / max_dist / target_dist 三处同构）。',
    '--   意义：同一个 brain 里，阈值可以随 buff / 昼夜 / 体型动态变化，',
    '--   而不必为每种情况重建一棵行为树。',
    '--⚠️ 注意这里存的是**函数本身**，求值推迟到 EvaluateDistances（第 39 行）。',
    '--   若在构造期就求值一次，动态阈值就退化成静态阈值了 —— 这是移植时最常见的错误。',
    '--   配套的代价：函数在 Visit 路径上被调用，不能 yield（协程化会破坏休眠语义）。',
  ],
  13: [
    '-- max_dist 同上。注意三处 if/else 的排版不一致（1 用 tab、2 用空格），',
    '-- 属风格问题，不影响语义。',
  ],
  20: [
    '-- target_dist 同样支持函数形式。',
    '-- ★ 实践上 target_dist 最常写成函数 —— 体型大的生物跟得更远。',
  ],
  27: [
    '--★★ `x ~= false` 而非 `if x == nil then x = true end` 的写法：',
    '--   语义等价，但只需一行，且默认保留「显式传 false 关闭」的能力。',
    '--   ★ 这是 Lua 布尔参数的社区惯例，全目录普遍使用，移植时建议沿用。',
  ],
  30: [
    '-- currenttarget：本帧实际跟的对象。与 self.target（意图）区分开，',
    '--   因为 self.target 可能是函数，每帧解一次的结果未必相同。',
    '--   ★ 两个字段分离是本文件能做「目标切换检测」的前提（第 80-82 行）。',
  ],
  31: [
    '-- action 是**节点内部的小状态机**：STAND / BACKOFF / APPROACH 三态。',
    '-- ★★★ 这是本目录最值得学的模式之一：',
    '--   外层用框架的 status（READY/RUNNING/终态），内层用 action 表达「RUNNING 期间在干什么」。',
    '--   为什么不新开一个子节点？因为「接近」和「后退」是同一个意图的两种表现，',
    '--   拆成两个节点会让父节点在两者间反复横跳（又是一次抖动）。',
  ],

  // ══════════════ 目标解析 ══════════════
  "Follow:GetTarget#1": [
    '--★★ GetTarget：把 self.target（实体 or 函数）解析成「此刻有效」的实体。',
    '--   FunctionOrValue 是 DST 的全局工具函数：',
    '--     · 参数是函数 → 调用它并返回结果',
    '--     · 参数是值   → 原样返回',
    '--   ★ 传 inst 作为参数 → 函数可以写成 function(inst) return inst.topdog end，',
    '--     从而让节点跟随「黑板」上的共享目标而不必硬编码引用。',
    '--★★ 返回值做了**三重与运算**的防御：非 nil、IsValid、非 nil 否则取 nil。',
    '--   ⚠️ 注意 Lua 的 `a and b and c or d` 陷阱：这里因为每个分支都产出布尔值所以安全，',
    '--     但若把 `target` 直接当返回值（去掉 :IsValid() 判断）就会在 target 为 nil 时',
    '--     静默返回 nil 而非报错 —— 错误会被推迟到下游 locomotor 调用时才炸。',
  ],

  // ══════════════ 阈值求值 ══════════════
  "Follow:EvaluateDistances#1": [
    '--★★ EvaluateDistances：把三个「函数形式阈值」求值成数字。',
    '--   原注释写明 "this is run once per follow target" —— 每个目标只算一次。',
    '--★ 与第 88 行 `if targetswitched or self.alwayseval` 配合：',
    '--   alwayseval=true（默认）→ 每帧重算，阈值能实时跟随状态变化；',
    '--   alwayseval=false        → 只在换目标时算，省 CPU 但阈值变「快照」。',
    '--   ★ 这是「动态阈值」与「求值开销」之间的显式取舍，参数化的价值所在。',
  ],

  // ══════════════ 调试输出 ══════════════
  "Follow:DBString#1": [
    '--★★ DBString：仅在 RUNNING 时被 GetString 调用（behaviourtree.lua:664）。',
    '--   输出格式「<目标> <动作>, (<距离>) 」—— 距离保留两位小数便于肉眼判断差多少。',
    '--★ 距离用 GetDistanceSqToInst + sqrt（现算），而不是复用 Visit 里缓存的 dist_sq：',
    '--   调试信息宁可每次重算最新值，也不接受「为了性能而展示陈旧数据」。',
    '--   ★ 排查「跟随抖动」时，这一行输出是第一个要看的东西。',
  ],

  // ══════════════ 距离计算 ══════════════
  "_distsq#1": [
    '--★★ _distsq：自己实现距离平方计算，返回 (距离², 目标世界坐标)。',
    '--   一次函数调用同时拿到距离和目标点，避免调用方再取一次 Transform ——',
    '--   ★ 这是「把两个查询合并成一次」的典型优化，Visit 里每帧都要用。',
    '--⚠️ 第 65 行原注释明确：Currently, this is 3D including y-component。',
    '--   即**高低差计入距离**。所以站在二楼的目标，即使水平距离为 0，',
    '--   在 min_dist 内也会触发 BACKOFF。移植时若只算水平距离需显式改。',
    '--★ 返回 Vector3 而非 Point：本文件只在第 143/145 行传给 locomotor:GoToPoint，',
    '--   而 GoToPoint 接受 Vector3，避免了一次无意义的 Point 构造。',
  ],

  // ══════════════ 平台判定 ══════════════
  "Follow:AreDifferentPlatforms#1": [
    '--★★ AreDifferentPlatforms：两者是否不在同一块平台上（船 vs 岸）。',
    '--★ 第一行 `if self.inst.components.locomotor.allow_platform_hopping` 是能力开关：',
    '--   只有生物**允许跳船**时，「不同平台」才是有意义的问题；否则一律返回 false。',
    '--   ★ 这是「把能力判定前置，避免无谓计算」的好写法。',
    '--⚠️ 注意函数签名是 (inst, target)，但函数体读的是 self.inst —— 第 70/71 行用的是',
    '--   self.inst 与 target。调用方都传 self.inst 作为第一参，所以行为正确，',
    '--   但参数 inst 在第 71 行被用了一次（inst:GetCurrentPlatform()），',
    '--   而第 70 行用 self.inst。属于**参数与成员混用**，风格瑕疵，非缺陷。',
  ],

  // ══════════════ Visit：READY 段 ══════════════
  "Follow:Visit#1": [
    '--★★ Visit —— 本节点唯一被框架调用的方法，三段式写法的范本。',
    '--   结构固定为：',
    '--     if self.status == READY  then ... end   -- ① 能否进入 + 决定动作',
    '--     if self.status == RUNNING then ... end  -- ② 执行 + 判断终止',
    '--   ★ 注意两段是**顺序 if 而非 elseif**：READY 段把 status 改成 RUNNING 后，',
    '--     紧接着的 RUNNING 段会在**同一次调用**里执行。这是刻意的 ——',
    '--     「决定做」和「开始做」之间不浪费一帧。',
  ],
  "Follow:Visit#1+4": [
    '--★ 先存旧目标，再解出新目标，二者不等即「目标切换」。',
    '--   targetswitched 是本节点最核心的一个状态位 —— 它同时触发：',
    '--     · 重新求值阈值（第 88-90 行）',
    '--     · 重新做进入/退出决策（第 84 行的 or targetswitched）',
    '--   ★ 即「换目标 = 重新考虑要不要跟」，而不是继续沿用旧目标的结论。',
  ],
  "Follow:Visit#1+8": [
    '--★★ `if self.status == READY or targetswitched then` —— 决策段的入口守卫。',
    '--   为什么 RUNNING 期间换目标也要重进决策段？因为 APPROACH 和 BACKOFF 的方向相反，',
    '--   目标一变就必须重新判断该靠近还是该后退。',
    '--   ★ 这就是内层 action 小状态机必须与「目标切换」联动的根本原因。',
  ],
  "Follow:Visit#1+12": [
    '--★ 只有「刚切换目标」或「alwayseval 开启」才重算阈值。',
    '--   若 alwayseval=false 且目标未变，阈值保持上次求值结果（快照语义）。',
  ],

  // ══════════════ 三段距离带判定 ══════════════
  "Follow:Visit#1+16": [
    '--★ 先算「是否跨平台」，后面两个分支都以它为前提，避免重复计算。',
  ],
  "Follow:Visit#1+18": [
    '--★★【BACKOFF 判定】进入内圈（比 min_dist 还近）→ 要后退。',
    '--   注意 `not on_different_platforms` 前置：跨平台时距离语义失效（见 _distsq 的 3D 注释），',
    '--   所以跨平台一律不走 BACKOFF。',
  ],
  "Follow:Visit#1+21": [
    '--★★【APPROACH 判定】跨平台，或超出 max_dist → 要追。',
    '--   两条独立触发条件用 or 连接，语义不同：前者是「够不着」，后者是「太远」。',
  ],
  "Follow:Visit#1+24": [
    '--★★【收敛判定】既不近也不远 —— 已在目标距离带内。',
    '--   ★★ 这里写的是 FAILED 而不是 SUCCESS，这是本文件最容易被误读的一行：',
    '--     站在正确位置「不需要采取任何行动」，对行为树来说就是「本节点不适用」，',
    '--     父节点（Selector）应去试下一个分支。若写成 SUCCESS，',
    '--     Selector 会认为「跟到了，停在这里」，后面的分支（如战斗）永远轮不到。',
    '--   ★★ 判定成功与否看的是「动作是否完成」，不是「状态是否理想」。',
    '--     这是读 DST 行为树源码时最需要建立的心智模型。',
    '--   第 132 行则是**真正的 SUCCESS**：那是 APPROACH 动作跑完的那一刻。',
    '--   同一个概念在两处用不同终态，正是因为一个测「状态」、一个测「动作」。',
    '--★ wasrunning 守卫：只有「原本在跑」才需要停下 locomotor。',
    '--   从 READY 进来时 locomotor 可能正被别处驱动（如战斗走位），',
    '--   无条件 Stop 会打断别人的行为 —— 这是节点间**互不干扰**的重要约定。',
  ],

  // ══════════════ Visit：RUNNING 段 ══════════════
  "Follow:Visit#1+38": [
    '--★★ RUNNING 段入口。四类失效条件逐层检查（任一命中即 FAILED）：',
    '--   ① 目标为 nil          —— 被外层换掉了',
    '--   ② 目标 IsValid 失败   —— 被删了',
    '--   ③ 目标已死            —— 跟一个尸体没有意义',
    '--   ④ 目标在 limbo        —— 仅当 inlimbo_invalid 为真（第 118 行）',
    '--★ 与 READY 段重复检查有效性看似冗余，实则必要：',
    '--   READY 段到 RUNNING 段之间虽然只隔几行，但下一帧 RUNNING 段执行时',
    '--   目标可能已被销毁。多帧存活的行为必须**每帧重新验证外部世界**。',
  ],
  "Follow:Visit#1+43": [
    '--⚠️ 第 118 行 `self.inlimbo_invalid and self.currenttarget:IsInLimbo()`：',
    '--   inlimbo_invalid 默认为 nil（构造器第 29 行不设默认值），',
    '--   所以默认**不把 limbo 当失效**。这是有意的：',
    '--   跟随已加载但正在载入的实体在 DST 里是常见场景（联机时对象延迟出现）。',
    '--   需要严格校验的调用方应显式传 true。',
  ],

  // ══════════════ APPROACH 动作 ══════════════
  "Follow:Visit#1+49": [
    '--★ APPROACH 分支。先补算距离：dist_sq 是第 78 行的局部缓存，',
    '--   若本次调用是从 RUNNING 直接进入（未走过 READY 段）则仍为 nil。',
    '--   ★ 「缓存 + 按需补算」而非每帧无条件重算，兼顾正确性与开销。',
  ],
  "Follow:Visit#1+56": [
    '--★★ APPROACH 的完成条件：进入 target_dist 内 → **SUCCESS**。',
    '--   这是本文件唯一产出 SUCCESS 的地方（对照第 101 行的 FAILED）。',
    '--   ★ 同理第 132 行的 not different_platforms：跨平台时距离无意义，不能判成功。',
  ],
  "Follow:Visit#1+61": [
    '--★★ `local max_dist = self.max_dist * .75` —— 关键细节：跑步时用 75% 距离。',
    '--   ★ 为什么？因为「跑」的刹车距离远大于「走」。若按满 max_dist 起跑，',
    '--     冲过头再 BACKOFF，来回摆动的幅度会更大（抖动更明显）。',
    '--   ★★ 缩小起跑阈值 = 提前减速。这是「运动学补偿」而非几何补偿，',
    '--     只在能跑时生效（第 142 行 canrun 守卫）。',
    '--   ※ 代价：跑步时会在比 max_dist 更远处就转为走路，观感上略「怂」。',
  ],
  "Follow:Visit#1+63": [
    '--★ 跨平台时 max_dist 强制为 0 —— 效果是「永远处于「太远」状态」，',
    '--   于是第 142 行必然成立，强制进入跑步分支去追跳板/船。',
    '--   ★ 用一个哨兵值（0）让后续统一逻辑自然退化，比在多处写 if 更省事。',
  ],
  "Follow:Visit#1+66": [
    '--★★ 三个条件任一成立就跑起来走：太远 / 状态图已在 running。',
    '--★ 第二条 `self.inst.sg:HasStateTag("running")` 是**迟滞（sticky）技巧**：',
    '--   一旦开始跑，除非进了 target_dist，否则不切回走。',
    '--   ★ 这与第 137 行的 .75 是同一个问题的两种解法：',
    '--     .75 从几何上提前减速，sticky 从时间上避免「跑两步走两步」。',
    '--   两者叠加，DST 的跟随动作看起来才流畅。移植时建议一起抄。',
    '--★ 第三参数 true = run（强制跑步），第二参数 nil = 不指定到达点。',
    '--   对比第 145 行的 GoToPoint(target_pos) 无第三参 → 只走路。',
  ],

  // ══════════════ BACKOFF 动作 ══════════════
  "Follow:Visit#1+71": [
    '--★ BACKOFF 分支。结构与 APPROACH 对称：补算距离 → 判完成 → 移动。',
  ],
  "Follow:Visit#1+75": [
    '--★★ BACKOFF 的完成条件：退到 target_dist 之外 → SUCCESS。',
    '--   ★ 注意用的是 target_dist 而不是 min_dist：',
    '--     进入时判定「比 min_dist 还近」用的是更内圈的 min_dist，',
    '--     退出时却放宽到 target_dist —— **进入阈值与退出阈值刻意不同**。',
    '--   ★★ 这是滞回带的完整形态：进入用 min_dist（保守，容易触发），',
    '--     退出用 target_dist（宽容，不容易退出）。若两侧都用 min_dist，',
    '--     实体会在阈值线附近高频进出，BACKOFF/APPROACH 疯狂切换。',
    '--   ★ 这一处是「迟滞」思想在 DST 里写得最清楚的地方，值得反复读。',
  ],
  "Follow:Visit#1+79": [
    '--★ BACKOFF 不指定目标点，而是朝「远离目标」的方向走：',
    '--   GetAngleToPoint 给出指向目标的方位角，+180 即反方向。',
    '--⚠️ 为什么不也用 GoToPoint(某个反向点)？因为反向点需要计算「自己 + 单位向量*某距离」，',
    '--   而目标在移动，那点会过时。RunInDirection 只依赖瞬时方位，永远不会指向过时位置。',
    '--★ 移植要点：需要「持续远离某物」时，用方向移动而非目标点移动，更鲁棒。',
  ],
  "Follow:Visit#1+80": [
    '--★ 第 157 行 RunInDirection / 第 159 行 WalkInDirection 对应 canrun 的两种分支。',
  ],

  // ══════════════ 休眠 ══════════════
  "Follow:Visit#1+87": [
    '--★★ self:Sleep(.25) —— 节点与框架休眠机制的**唯一**协作点。',
    '--   语义（behaviourtree.lua:97-99）：self.nextupdatetime = GetTime() + .25。',
    '--★ 效果链：Sleep(.25) → GetSleepTime 返回剩余秒 → BT:GetSleepTime 逐层取最小 →',
    '--   brain.lua:143-149 消费：非 nil 则把大脑排进 Sleep 队列，期间零 CPU 开销。',
    '--★ 0.25 秒 = 每秒 4 次决策。跟随是「连续过程」而非「瞬时判定」，',
    '--   所以用轮询式休眠；事件驱动的节点（如 EventNode）则不调 Sleep，靠 forceupdate 唤醒。',
    '--★★ 移植要点：节点「主动声明我要睡多久」是 AI 省电的核心机制。',
    '--   不调 Sleep 时 GetSleepTime 返回 0 → 每帧都跑 → 几百只怪就是几百倍开销',
    '--   （对应 bug-patterns F2/F4 的性能命门）。',
    '--⚠️ 代价：.25 是硬编码，上层无法调。若要按距离/速度自适应，需要扩展成字段。',
  ],
};
