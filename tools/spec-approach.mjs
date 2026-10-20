// spec-approach.mjs —— behaviours/approach.lua 深度注释（行号 → 注释）
// ⚠️ 行号对应 approach.lua 实际 108 行。
//
// 本文件与 follow.lua 高度同源（约 60% 重复），注释重点放在「与 follow 的差异」上。

export default {
  1: [
    '-- [= [ 长注释块开始（原为 --[[，改用 --[=[ 安全形式，避免误闭合）',
    '-- approach.lua —— 接近节点（Approach）：走到目标附近指定距离即成功',
    '--',
    '-- 【与 follow.lua 的关系 —— 建议对照阅读】',
    '-- approach 是 follow 的**功能子集**：',
    '--   保留：目标解析(FunctionOrValue)、阈值可为函数、跨平台判定、.25 秒休眠节流',
    '--   砍掉：min_dist（不后退）、max_dist（不设触发带）、BACKOFF/APPROACH 双态机',
    '--   结果：单一阈值 dist，一个动作，走到即 SUCCESS。',
    '-- ★★ 三者的定位对比：',
    '--   approach —— 「去那边一趟」（一次性抵达）',
    '--   follow   —— 「在那附近待着」（维持距离带，会后退）',
    '--   findclosest —— 「去最近的某个东西那里」（目标由本节点自己找）',
    '--   ★ 移植建议：先写 approach 这种「一个动作 + 一个阈值」的节点，',
    '--     熟练后再叠加 follow 的滞回带。直接从 follow 起步容易把双阈值搞混。',
    '--',
    '-- 【★ 本文件也印证了 DST 节点协议的真相】',
    '-- 没有 ShouldRun / OnEnter / OnUpdate / OnExit / DoBehaviour ——',
    '-- 全部逻辑塞在单个 Visit() 里，用 self.status 三态（READY/RUNNING/终态）驱动。',
    '-- ]=] 长注释块结束（原为 --]]）',
  ],

  // ══════════════ 阈值参数化 ══════════════
  6: [
    '--★ 「值或函数」双形态阈值，与 follow 的三处同构。',
    '--★ 注意这里函数只收一个参数 self.inst（不像 chaseandattack 那样传目标），',
    '--   因为 Approach 的阈值通常只与自身状态（速度、体型）相关。',
  ],
  13: [
    '--★★ 构造器只有 4 个参数，对比 follow 的 9 个 —— 参数多寡直接反映行为的复杂度。',
    '--★ 自研 AI 的经验法则：节点参数一旦超过 6~7 个，就该考虑拆节点或引入配置表。',
  ],
  14: [
    '--★ currenttarget：与 self.target 分离，理由同 follow（目标可能是函数，每帧结果可变）。',
  ],

  // ══════════════ 阈值求值 ══════════════
  "Approach:EvaluateDistances#1": [
    '--★★ EvaluateDistances：求值时机比 follow 更严格。',
    '--★ 对照 follow 第 88 行 `if targetswitched or self.alwayseval`：',
    '--   follow 有 alwayseval 开关，可选每帧重算；',
    '--   approach **只在目标切换时重算**（见第 63 行）。',
    '--   ★ 这是有意的不对称：Approach 是一次性抵达行为，',
    '--     阈值在途中变化通常没有意义，重算反而可能在到达途中改变判定距离。',
    '--★ 「快照语义」在这里是优点而非缺陷 —— 一次行为内保持一致的判定标准。',
  ],

  // ══════════════ 调试输出 ══════════════
  "Approach:DBString#1": [
    '--★ DBString：格式比 follow 简（无 action 字段，因为无多态动作）。',
    '--   同样是每帧现算距离，保证调试信息是最新的。',
  ],

  // ══════════════ 距离与平台 ══════════════
  "_distsq#1": [
    '--★★ _distsq：从 follow.lua 第 59-67 行**原样复制**。',
    '--⚠️ 这是一处真实的代码重复（两个文件各自定义同名局部函数，逻辑一致）。',
    '--   我已逐行比对：两处实现完全相同，包括第 42 行的 3D 距离原注释。',
    '--   影响：无功能危害（局部函数不会冲突），但修改时需同步两处，容易漏。',
    '--★ 移植建议：这类通用几何工具应该提到公共 util，而不是每个节点各抄一份。',
    '--   DST 自己的 behaviourutil.lua 就是干这个的，但这两个节点没复用它。',
    '--★ 提醒：复制粘贴的代码是「双份维护成本」的来源，注释出来至少能让后人警觉。',
  ],
  "Approach:AreDifferentPlatforms#1": [
    '--★★ AreDifferentPlatforms：同样从 follow 第 69-74 行复制。',
    '--★ 条件是 allow_platform_hopping —— 生物不允许跳船时，跨平台问题不存在。',
  ],

  // ══════════════ Visit:READY 段 ══════════════
  "Approach:Visit#1": [
    '--★★ Visit 的三段式结构，与 follow/approach 完全同形。',
    '--   ★★ 与 follow 的一个重要结构差异：approach **两个 status 段都在外层 if 里**，',
    '--     所以 READY 段判定成功后（同帧直接 SUCCESS），第二段仍会被检查 ——',
    '--     但因为 status 已是 SUCCESS 而非 RUNNING，第 79 行不成立，安全跳过。',
    '--   这正是「顺序双 if」写法的健壮之处：状态改动后第二段自动失效。',
  ],
  "Approach:Visit#1+2": [
    '--★ 三个局部变量缓存：距离、目标点、跨平台标记。',
    '--★ 只在 READY 段算一次，RUNNING 段若为 nil 再补算（第 89 行）——',
    '--   「缓存 + 按需补算」的标准模式，避免每帧重复计算。',
  ],
  "Approach:Visit#1+4": [
    '--★★ READY 段入口。与 follow 相比少了 `or targetswitched` ——',
    '--   因为 Approach 只有「接近」一个动作，目标切换后进入的是新的一次 Visit',
    '--   （READY 状态），不需要在 RUNNING 中途重做决策。',
    '--★★ 这是 follow 必须处理「RUNNING 期间换目标」而 approach 不需要的原因，',
    '--   根因是 follow 有 APPROACH/BACKOFF 两个互斥动作。',
  ],
  "Approach:Visit#1+5": [
    '--★ 先存旧目标 —— 仅用于第 63 行判断「是否换目标」，决定要不要重算阈值。',
  ],
  "Approach:Visit#1+8": [
    '--★ 同 follow：一次调用同时拿到距离平方与目标世界坐标，避免重复取 Transform。',
  ],
  "Approach:Visit#1+10": [
    '--★★ 仅在目标切换时重算阈值（对比 follow 可选 alwayseval 每帧重算）。',
    '--★ 语义差异的取舍已在第 22 行详述：一次性行为用快照更合理。',
  ],
  "Approach:Visit#1+16": [
    '--★★ 进入判定：跨平台 或 距离超出 dist。',
    '--   ★ 两个条件的语义与 follow 第 97 行的 APPROACH 完全一致，抄的是同一套判据。',
    '--★ 缺了 follow 的 min_dist 分支 —— 没有内圈，所以不会后退。',
  ],
  "Approach:Visit#1+19": [
    '--★★ 已经在 dist 范围内 → 直接 SUCCESS（不产生任何移动）。',
    '--★★ 这是与 follow 第 101 行最本质的差异：',
    '--   follow：已在范围内 → FAILED（「不需要做什么」）',
    '--   approach：已在范围内 → SUCCESS（「已经抵达」）',
    '--★ 为什么不同？因为 Approach 的行为**本身就是「到达」**这个状态，',
    '--   处在目标附近就等于成功；而 Follow 的行为是「维持一个跟随动作」，',
    '--   静止不动的跟随者并没有完成任何动作，所以是 FAILED。',
    '--★★ 移植要点：这是判断 SUCCESS/FAILED 的黄金准则 ——',
    '--   问自己「行为的**意图**在此刻是否已经达成」，而不是「过程是否有进展」。',
    '--     · 意图是「到达某处」 → 已在某处 = 达成 = SUCCESS',
    '--     · 意图是「持续跟随」 → 原地不动 = 未采取动作 = FAILED',
    '--   ★★★ 搞清这一点，DST 行为树里所有看似矛盾的终态就都不矛盾了。',
  ],

  // ══════════════ Visit:RUNNING 段 ══════════════
  "Approach:Visit#1+26": [
    '--★★ RUNNING 段入口：先做目标有效性复检（nil / 无效 / 已死）。',
    '--★ 跨帧存活的行为必须每帧重新验证外部世界 —— 与 follow 第 114-123 行同理。',
    '--★ 注意此处**没有** inlimbo 检查（follow 有且需显式开启）：',
    '--   Approach 节点构造器根本没有 inlimbo_invalid 参数。',
    '--   这说明「是否把 limbo 当失效」是按节点语义逐个决定的，不是统一策略。',
  ],
  "Approach:Visit#1+36": [
    '--★★ 距离缓存的补算点。dist_sq 为 nil 说明本次调用是从 RUNNING 直接进入的。',
    '--★ 第 91 行连跨平台标记一起补算 —— 两者在 READY 段是成对产出的，',
    '--   补算时必须成对补，漏一个就会用到 nil 参与比较（第 100 行）而报错。',
  ],
  "Approach:Visit#1+41": [
    '--★★ RUNNING 中的完成判定：进入 dist 内 → SUCCESS。',
    '--★ 与第 72 行的 READY 判定条件完全相同（not on_different_platforms and dist_sq < dist²），',
    '--   两处重复是有意为之：一个是「首次进入时判断」，一个是「运行途中判断」。',
    '--   ⚠️ 若只保留一处，会出现「READY 时够不着、RUNNING 中走进去了却永不结束」的死循环。',
    '--   ★ 移植要点：凡是有「进入 RUNNING → 达成目标」结构的行为，',
    '--     READY 与 RUNNING 两处都必须写完成判定。',
  ],
  "Approach:Visit#1+47": [
    '--★★ 跑步判定：跨平台 或 太远 或 已在 running 状态。',
    '--★ 第三个条件 `sg:HasStateTag("running")` 是**迟滞（sticky）**：',
    '--   已经开始跑就保持跑，直到进入 dist。',
    '--   ★ 与 follow 第 142 行同一手法 —— 避免「跑两步走两步」的节奏抖动。',
    '--⚠️ 与 follow 的差异：approach 把 on_different_platforms 也算作「该跑」。',
    '--   follow 的做法是「跨平台时 max_dist = 0」（哨兵值法，见 follow 第 139 行）。',
    '--   ★ 两种写法等价，但 approach 更直接。移植时可择其一，别同时用。',
  ],
  "Approach:Visit#1+53": [
    '--★★ self:Sleep(.25) —— 与 follow 完全相同：每 0.25 秒醒一次。',
    '--★ 「走到位即结束」的节点用 .25 足够；持续性行为（战斗、逃跑）才需要更快的节拍',
    '--  （对比 chaseandattack 的 .125、runaway 的更短值）。',
    '--★★ 与 chaseandattack 对照可以看出一条规律：',
    '--   **决策频率正比于「行为出错的后果严重度」**。',
    '--   走路走错几步无所谓（.25s），攻击慢半拍会挨打（.125s），',
    '--   逃跑慢半拍会死（更短）。移植时优先调这个参数。',
  ],
};
