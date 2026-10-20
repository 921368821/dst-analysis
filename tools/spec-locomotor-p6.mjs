// spec-locomotor-p6.mjs —— locomotor.lua 深度注释规格 第 6 部分
// 覆盖：寻路能力（pathcaps）→ FindPath → 文件尾
// 锚点范围：1760 ~ 1865

export const BEFORE = {
  // ══════════════════════════════════════════════════════════════
  // 十六、寻路能力（pathcaps）—— locomotor 与寻路器的接口契约
  // ══════════════════════════════════════════════════════════════
  "LocoMotor:IsAquatic#1": [
    "--★★★【四个寻路能力查询函数】",
    "--   这四个函数是 locomotor 声明「自己能走什么地形」的入口。",
    "--   ★★ 它们全部读同一个字段：self.pathcaps（寻路能力表）。",
    "--   pathcaps 的键名（由调用方通过 AdjustPathCaps 传入的 capname 决定）",
    "--   至少包括：allowocean（能走水面）、ignoreLand（忽略陆地）、",
    "--   allowplatformhopping（能跨平台）。",
    "--   ★ 键名是**字符串约定**而非枚举 —— 强类型移植时应收敛为枚举。",
  ],
  "LocoMotor:IsAquatic#1+1": [
    "--★★ IsAquatic：完全水生。必须同时满足「能走水面」且「忽略陆地」。",
    "--   ★★ 两个条件都要 —— 只有 allowocean 的话，",
    "--     「陆地上也能走」的水生生物（如鸭子）不满足 IsAquatic。",
  ],
  "LocoMotor:CanPathfindOnWater#1": [
    "--★ CanPathfindOnWater：只要 allowocean 即可（鸭子也满足）。",
  ],
  "LocoMotor:IsTerrestrial#1": [
    "--★★【IsTerrestrial：陆生。英文原注释解释了双重否定的原因】",
    "--   \"We use 'not' because the pathcaps may be unassigned or assigned false",
    "--    (i.e. if they're changed at runtime)\"",
    "--   ★★★ 翻译：pathcaps 可能整体是 nil（从未设置），",
    "--     也可能被运行时改成 false。所以必须用「取反」而不是「比较等于 false」",
    "--     —— 后者在 nil 时会崩。",
    "--   ★ 这是一条关于「可选配置」的重要防御模式。",
  ],
  "LocoMotor:CanPathfindOnLand#1": [
    "--★★ CanPathfindOnLand：默认 true（pathcaps 为 nil 时也返回 true）。",
    "--   ★★ 注意这里与其他三个函数的默认值策略**相反**：",
    "--     · IsAquatic / IsTerrestrial / CanPathfindOnWater —— pathcaps 为 nil 时返回 false",
    "--     · CanPathfindOnLand —— pathcaps 为 nil 时返回 true",
    "--   ★★ 原因是默认值：实体没配 pathcaps 时，应当「按陆地生物处理」",
    "--     （最常见的情况），而不是「什么都不行」。",
    "--   ★ 但这也造成了一个 API 不一致：四个查询里三个「默认无」，一个「默认有」。",
    "--     使用方必须清楚这个区别，否则会出现「以为能在陆地走却不能」。",
  ],
  "LocoMotor:AdjustPathCaps#1": [
    "--★★★【AdjustPathCaps：寻路能力开关】",
    "--   启用 → pathcaps[capname] = true（懒建表）",
    "--   禁用 → pathcaps[capname] = nil；若表空则整体置 nil",
    "--   ★ 与 655 行 TempGroundSpeedMultiplier 的「懒建 + 空则置 nil」是同一套路。",
    "--   ★★ 禁用时置 nil 而非 false —— 因为判读时用的是 `pathcaps.ignoreLand`",
    "--     的真值性，nil 与 false 等价。用 nil 便于 `next()` 的空表检测。",
  ],
  "LocoMotor:AdjustPathCaps#1+9": [
    "--★ 空表则整体置 nil —— 保持「nil = 未设置」的语义（见 1768 行注释）。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 十七、FindPath —— 向寻路器提交搜索
  // ══════════════════════════════════════════════════════════════
  "LocoMotor:FindPath#1": [
    "--★★★★★【FindPath：向 C++ 寻路器提交一次搜索（或走直线）】",
    "--   ★★★ 这是本文件与「寻路器」的唯一接口。分工非常清晰：",
    "--     · locomotor：提交起点/终点/能力，等结果，**决定往哪转**",
    "--     · TheWorld.Pathfinder（C++）：求解 A*，返回 steps 列表",
    "--   locomotor **不做任何寻路决策**（不判断该不该寻路、不选备选路径），",
    "--   它只做两件事：",
    "--     ① 若两点之间视线通畅（IsClear）→ 放弃寻路，走直线",
    "--     ② 否则提交搜索",
    "--   ---- 完整流程 ----",
    "--   1796 同步 allow_platform_hopping 到 pathcaps",
    "--   1803 目标有效性检查",
    "--   1807-1808 取起点终点",
    "--   1821-1832 目标地块去重（★ 性能关键）",
    "--   1836 视线通畅检查 → ResetPath（走直线）",
    "--   1845 防抖 → SubmitSearch",
  ],
  "LocoMotor:FindPath#1+1": [
    "--★★★【JBK 的注释坦承这是一个 hack —— 非常值得学习】",
    "--   \"This is a hack because of the handling of locomotor.pathcaps has no setter",
    "--    and we do not want a metatable hook for all of every instance of locomotor",
    "--    component. So we will watch the state of allow_platform_hopping which is",
    "--    true or false if it was ever set or cleared later.\"",
    "--   ★★★ 完整翻译：",
    "--     问题：pathcaps 没有属性 setter（不走 class.lua 的 props 机制），",
    "--          若要「pathcaps 变化时自动同步」，得给**每一个** locomotor 实例",
    "--          挂一个元表钩子 —— 那会有明显的性能与内存开销（成百上千个实例）。",
    "--     折中：不去监听 pathcaps 的变化，而是**在每次 FindPath 时**，",
    "--          检查「allow_platform_hopping 是否曾经被显式设置过（可能为 nil/true/false）」，",
    "--          然后手动同步到 pathcaps。",
    "--   ★★ 这是一个「主动轮询替代被动监听」的经典权衡：",
    "--     用「每次调用时多一次比较」换取「不给每个实例挂钩子」。",
    "--   ★ 值得学习的是作者**把权衡的理由完整写了下来**——",
    "--     后来者能理解为什么这里看起来很笨。",
  ],
  "LocoMotor:FindPath#1+3": [
    "--★★ `if self.allow_platform_hopping ~= nil` —— 只在「被显式设置过」时才同步。",
    "--   ★ 若从未设置（nil），AdjustPathCaps(nil, ...) 会走「禁用」分支，",
    "--     把 allowplatformhopping 键置 nil —— 对从未配置过的东西是安全的。",
    "--   ⚠ 但注意：若 allow_platform_hopping = false（显式禁用），",
    "--     AdjustPathCaps(false, ...) 也会置 nil —— 结果正确（都是「不允许」）。",
  ],
  "LocoMotor:FindPath#1+10": [
    "--★ 目标失效则不寻路（否则会向一个已销毁的实体提交搜索）。",
  ],
  "LocoMotor:FindPath#1+14": [
    "--★ Vector3 包装当前位置。Point 只存 3 个 float，Vector3 可能是 Lua 对象。",
  ],
  "LocoMotor:FindPath#1+19": [
    "--⚠【被注释掉的距离上限检查】（见文件头 5-6 行的说明）",
    "--   ★ 现在无距离限制 —— 玩家可以要求走到地图任何地方。",
  ],
  "LocoMotor:FindPath#1+28": [
    "--★★★【目标地块去重 —— 本函数最重要的性能优化】",
    "--   `GetPathTileIndexFromPoint` 把目标坐标映射到**寻路网格**的索引。",
    "--   ★★ 语义：若「上次搜索的目标地块」与「本次相同」，直接 return —— ",
    "--     因为寻路结果只取决于起点与终点所在格，",
    "--     目标在同一格内移动不必重新求解。",
    "--   ★★★ 这就是文件头 PATHFIND_PERIOD 被废弃后的替代方案：",
    "--     用「空间去重」代替「时间节流」，既省 CPU 也不影响正确性。",
    "--   ⚠ 精确性：目标在同格内移动时不再更新路径，",
    "--     所以移动目标（逃跑的敌人）会有「路径滞后一格」的现象。",
    "--     ★ 滞后距离 = 一格（寻路网格的分辨率，通常是 1~2 格），",
    "--       加上 1619 行的「无条件继续前进」，实际表现是「追着上一格的路径走」，",
    "--       而 1469 行的到达判定用的是**实时**目标坐标 —— 所以不会真的追丢。",
  ],
  "LocoMotor:FindPath#1+31": [
    "--★ 双重守卫：本次有索引 且 上次也有记录（lastdesttile）。",
  ],
  "LocoMotor:FindPath#1+33": [
    "--★★ 地块索引相同 → 直接返回（不重新寻路）。",
    "--   ★★ 注意这里返回的是「不做事」，而不是「重置路径」——",
    "--     已有路径继续被 OnUpdate 跟随。",
  ],
  "LocoMotor:FindPath#1+39": [
    "--★ 记录本次目标地块，供下次去重比较。",
  ],
  "LocoMotor:FindPath#1+43": [
    "--★★★【视线通畅检查：寻路的第一道也是最重要的一道优化】",
    "--   `Pathfinder:IsClear(p0, p1, self.pathcaps)` ——",
    "--   ★★ 若起点到终点之间无阻挡，**根本不需要寻路**。",
    "--     直接走直线（ResetPath 清掉旧路径，之后走电机 + 物理碰撞）。",
    "--   ★★★ 这是本文件最重要的性能设计：",
    "--     · 开阔地形（草原、海面）上 100% 命中 → 完全不触发 A*",
    "--     · 只有需要绕障时才付出寻路代价",
    "--   ★ 而且它同时是「正确性」保障：直线路径永远可走（物理会挡住），",
    "--     不会因为寻路器找不到路（被围死）而卡住。",
    "--   ★ 对比 1839 行的注释 \"NO LOS - PATHFIND\" ——",
    "--     两分支互斥：一个「走直线」，一个「寻路」。",
  ],
  "LocoMotor:FindPath#1+45": [
    "--★★ 视线通畅 → ResetPath（清掉旧路径，后续走直线）。",
  ],
  "LocoMotor:FindPath#1+49": [
    "--★★★【英文原注释解释了一个真实的性能问题】",
    "--   \"while chasing a moving target, the path may get reset frequently before any",
    "--    search completes -- only start a new search if we're not already waiting for",
    "--    the previous one to complete OR we already have a completed path we can",
    "--    keep following until new search returns\"",
    "--   ★★★ 完整翻译：",
    "--     问题：追移动目标时，FindPath 每帧被调用（若 lastdesttile 变了），",
    "--           若无条件提交新搜索，会「杀死旧搜索、提交新搜索」无限循环，",
    "--           一个搜索都完不成（CPU 100% 空转）。",
    "--     解法：只在满足下列之一时才提交新搜索：",
    "--       ① 已经有一条**完成的**路径（可以边走旧边等新）",
    "--       ② 当前**没有**在等任何搜索（不会打断别人）",
    "--   ★★ 这是「异步任务提交」的经典防抖：",
    "--     「要么我有结果可用，要么我没在忙 —— 才发起新任务」。",
  ],
  "LocoMotor:FindPath#1+52": [
    "--★★ 防抖条件：`(self.path and self.path.steps) or not self:WaitingForPathSearch()`",
    "--   ★ 注意 self.path.steps 存在即代表「有可跟随的已完成路径」。",
    "--   ★★ 语义：即使「有搜索在跑」，只要「有完成的路径可走」，也提交新的 ——",
    "--     因为旧路径还能用，新搜索只是为将来做准备。",
  ],
  "LocoMotor:FindPath#1+54": [
    "--★ KillPathSearch：先杀掉旧搜索再提交新的，避免句柄堆积。",
  ],
  "LocoMotor:FindPath#1+56": [
    "--★★ SubmitSearch：真正的 A* 求解请求，返回句柄。",
    "--   ★ pathcaps 作为最后参数传入 —— 寻路器据此决定「水能不能走」「陆地能不能走」。",
    "--   ★★ 这是 pathcaps 的**唯一实际用途**：",
    "--     locomotor 从不自己用 pathcaps 做移动决策（除了那四个查询函数），",
    "--     它只是把这份「能力声明」转交给寻路器。",
  ],
  "LocoMotor:FindPath#1+57": [
    "--★ 句柄非 nil 表示提交成功。nil 通常意味着「寻路器满了/拒绝了请求」。",
  ],
  "LocoMotor:FindPath#1+60": [
    "--★★★【★ 「新旧路径共存」的设计 —— 极易被误解为 bug】",
    "--   `self.path = self.path or {}` —— ★ 保留已有的 path 表（含 steps 与 currentstep）",
    "--   `self.path.handle = handle` —— ★ 只替换句柄，不动 steps",
    "--   ★★★ 这意味着：",
    "--     · 新搜索在跑的同时，OnUpdate 继续跟随**旧的 steps**（1531 行那套逻辑）",
    "--     · 新搜索完成后（1536 行）才替换 steps",
    "--     ★★ 效果：角色永远在「走一条有效路径」，而路径在后台持续优化。",
    "--     这就是「有旧路径可走就允许发起新搜索」（1845 行）的意义所在。",
    "--   ⚠⚠ 潜在隐患：1537 行 `self.path.currentstep = 2` 在采纳新路径时重置，",
    "--     但从 step 2 重新开始走一条新的（可能绕远的）路径，",
    "--     可能让角色「突然改变方向往回走」。",
    "--     ★ 实际不明显的理由：新旧路径的起点相同，",
    "--       前几步通常方向一致，视觉上是平滑的。",
  ],
  "LocoMotor:FindPath#1+65": [
    "--★ 提交失败只打调试日志，不做重试 —— 依赖下一帧的 FindPath 再次尝试。",
  ],
  "LocoMotor:FindPath#1+70": [
    "--★ 函数结束。注意末尾没有 return —— 无返回值，调用方不依赖返回值。",
    "--   ★ FindPath 的结果通过 self.path 字段传递（副作用式 API），",
    "--     而不是返回值。这是本文件的一贯风格。",
  ],
  "LocoMotor:FindPath#1+72": [
    "--★★ 模块出口。LocoMotor 类通过 Class 系统全局可用（不需要模块导出机制）。",
    "--   ★ 与 health.lua:665 的 `return Health` 形式一致。",
  ],
};

export const AFTER = {};
