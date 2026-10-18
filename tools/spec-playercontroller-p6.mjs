// spec-playercontroller-p6.mjs —— 第 6 段：3180-3700 行
// 覆盖：手柄目标选择三件套（攻击目标打分 / 交互目标打分 / 冲突消解）、目标锁定

export const BEFORE = {
  3180: [
    "--============================================================",
    "-- 【第六段】3180-3700 行：★ 手柄目标选择（打分排序）与目标锁定",
    "--============================================================",
  ],

  3178: [
    "--★★ 【CheckControllerPriorityTagOrOverride】手柄目标优先级的「可覆盖」查询。",
    "--   override 是函数或值 → FunctionOrValue 求值；nil → 查标签。",
    "--   ★ 这是模组的第三个扩展点（前两个是 actionbuttonoverride 与 client_forward）。",
    "--     实体通过 `controller_priority_override_is_epic` 等字段声明自己的优先级，",
    "--     不需要改本文件。",
    "--   ⚠ 3269/3271/3275 行的三个字段（is_epic / is_monster / is_targeting_player）",
    "--     都是**实体上的裸字段**（不是组件方法），grep 确认由 prefab 直接赋值。",
  ],

  3297: [
    "--★★ 【3296-3327 目标锁定分支的完整语义】",
    "--   ★ 这是本文件里唯一「冻结选择但维持候选池」的数据结构维护逻辑。",
    "--   ⭐ 三个关键设计决策：",
    "--     ① 3229 行把当前目标插到候选列表首位 —— 保证它在任何位置都能被找到",
    "--     ② 3283 行把**所有**合法候选都记进临时表 —— 供锁定时的 diff",
    "--     ③ 3326 行直接 return —— 不改 controller_attack_target",
    "--   ⇒ 净效果：锁定期间，玩家按方向键在候选池里滚动，",
    "--     而候选池会随敌人进出而增删（3300-3323 行）。",
    "--   ⚠ 复杂度警示：这段用了三张表（附近实体、当前候选、锁定候选），",
    "--     O(n²) 的双层循环（3300-3311 行），且 table.remove 在循环内。",
    "--     n 通常 < 10（附近能打的怪），可接受；但若模组让半径内实体暴增，",
    "--     这段会成为每帧热点。",
  ],

  3300: [
    "--★ 3300-3317 行：从锁定候选里**移除**已消失的目标（倒序遍历）。",
    "--   ★ 3304-3309 行：先在「当前合法候选」里找它，找到就把它从当前表里删掉。",
    "--     英文原注释：\"we found the existing target in the list of current nearby",
    "--     entities so remove it from the current entity list to make later addition",
    "--     of new entities more straightforward\" ——",
    "--     ★ 这是**减少后续工作量**的优化：不在锁定池里的，就不用再比对。",
    "--   ⚠ 性能反例：若某个目标反复出现/消失，每帧都要全表扫描。",
  ],

  3319: [
    "--★ 3319-3323 行：把「本帧新出现」的候选加入锁定池。",
    "--   ★ 此时 current_controller_targeting_targets 里只剩**真正新增**的（因为",
    "--     3307 行已把已存在的移除了）。⇒ 可以无脑全量 insert。",
  ],

  3326: [
    "--   -- fin",
    "--★ 3326 行的 return 是本分支的终点：锁定期间**不改**当前目标。",
    "--   ⇒ 3351 行的 controller_targeting_target_index 在锁定期间**不更新**。",
    "--   ⚠ 但 3673 行的 CycleControllerAttackTargetForward 依赖它做循环起点。",
    "--   ⚠⚠ 疑似缺陷（索引漂移）：",
    "--     玩家锁定 → 敌人进出 → 玩家按循环键，索引可能指向一个语义不同的位置。",
    "--     推理依据：3351 行的赋值在 3326 行的 return 之后，锁定时不执行；",
    "--       而 3322 行 table.insert 会改变 controller_targeting_targets 的顺序。",
    "--     缓解：3674 行 `if index > num_targets then index = 1 end` 只会夹到范围内，",
    "--       所以不会崩溃，但「循环顺序」可能与预期不符。",
  ],

  3185: [
    "--★★★ 【UpdateControllerAttackTarget】★ **手柄「X 键」目标选择：几何 + 打分**。",
    "--   每帧由 UpdateControllerTargets:3620 调用（仅手柄模式）。",
    "--   与鼠标的 GetAttackTarget（1790 行）的根本差异：",
    "--     · 鼠标：枚举范围内所有候选，选「最近的合法目标」",
    "--     · 手柄：枚举范围内所有候选，算**分数**后选最高的",
    "--   ⇒ 手柄可以用「方向 + 优先级」瞄准，鼠标只能点最近的。这是手柄体验的核心。",
  ],

  3187: [
    "--   ★ 三种「不能瞄准」的情况：举重物 / 举漂浮物 / 幽灵。",
    "--   3192 行连带关闭目标锁定 —— 因为无目标时锁定无意义。",
  ],

  3198: [
    "--   ★★ 友方目标冷却倒计时。初值 nil → 3198 行用 `(nil or 1) - dt` 变成 1 秒。",
    "--   ⇒ 设计：切换到非友方目标时 3355-3358 行把它清回 nil，下一帧又从 1 秒开始。",
    "--     效果是「每次切换目标后，有 1 秒的友方降权期」。",
  ],

  3200: [
    "--   ★ 3200-3208 行：当前目标失效 → 清空 + 关闭锁定。",
    "--   3207 行注释 \"it went invalid, but we're not resetting the age yet\" ——",
    "--     ★ 刻意不重置年龄：age 保持很大值，让 3381 行的 0.2 秒防抖立即通过。",
    "--     ⇒ 目的：目标失效后要**立刻**重新选，而不是等 0.2 秒。",
  ],

  3210: [
    "--   3210-3214 行注释掉的 controller_attack_target_age 防抖代码。",
    "--   ⚠ 与 controller_target_age（120 行仍在用）的对比说明：",
    "--     攻击目标**放弃**了防抖，交互目标保留了。",
    "--   推理依据：120 行 `self.controller_target_age = math.huge` 仍在构造函数里；",
    "--     3207 行的注释「not resetting the age yet」证明攻击目标没有 age 字段了。",
  ],

  3216: [
    "--★ 【3217-3221 攻击半径的三档】交互范围判定的核心。",
    "--   forced_rad：物品自带的 controller_use_attack_distance（如长矛的额外长度）。",
    "--   min_rad = 3：★ 不需要瞄准就能打的最小半径（身后也能打）",
    "--   max_rad = max(forced_rad, 武器射程) + 3.5",
    "--   ⇒ +3.5 的余量是为了容纳目标的物理半径（3264 行才减去）。",
    "--   ⚠ 3219 行的 min_rad=3 与 3436 行交互目标的 min_rad=1.5 不同：",
    "--     攻击需要更大的「无瞄准区」，因为误伤代价高。",
  ],

  3225: [
    "--   ★ 3225 行用 RegisterFindTags 的版本（排除 stealth 等，2082 行注册）。",
    "--   3226-3230 行：把当前目标**强行插到列表首位**（3229 行），",
    "--     保证它被优先处理（3244 行用 `(v ~= self.controller_attack_target or i == 1)`",
    "--     保证它只被处理一次）。",
  ],

  3235: [
    "--   ★★ preferred_target 的三级优先：",
    "--     ① 扳机按着时的当前目标（最优先：玩家明确表达过意图）",
    "--     ② combat:GetTarget()（战斗系统认为的目标）",
    "--     ③ 无",
    "--   3279 行给它 ×10 分（最大的单项加权）。",
  ],

  3244: [
    "--   ★★ 3244 行的 `(v ~= self.controller_attack_target or i == 1)`：",
    "--     跳过重复出现的当前目标（因为 3229 行插入了一份，FindEntities 也返回了一份）。",
    "--     i==1 保证插入的那份能被处理。",
    "--   ⇒ 经典的空间查询去重技巧：手动插入已选目标后必须去重。",
  ],

  3246: [
    "--   ★★ 友方降权守卫：`(isally and ally_cd > 0 and v ~= preferred_target)`。",
    "--     三个条件同时满足才排除 —— 冷却期内友方几乎不可被选中。",
    "--     但 preferred_target（玩家明确指的）豁免。",
  ],

  3249: [
    "--   combat:CanTarget(v) —— 目标是否合法（未死/未被独占）。",
  ],

  3251: [
    "--★ 【3251-3253 行：攻击索敌计入 y 轴】",
    "--   ★ 与 3479 行的交互索敌（**只算 xz**）形成鲜明对比。",
    "--   为什么攻击要算 y：可以打到**下方一层**的目标（站在悬崖边打下面的敌人）。",
    "--   为什么交互不算 y：站在二楼不该能「交互」一楼的东西。",
    "--   ⚠ 但 3502-3505 行的交互索敌在通过半径测试**之后**又补加了 dy² ——",
    "--     用它做平局时的 tiebreaker（见该处注释）。这个折衷很微妙。",
  ],

  3256: [
    "--   --include physics radius for max range check since we don't have",
    "--   (dist - phys_rad) yet",
    "--   ★ 两段式距离判定：先用「中心距 + 物理半径」判可达，",
    "--     再用「中心距 - 物理半径」算分（3264 行）。",
    "--   ⇒ 这样既保证「体型大的目标在边缘也算命中」，又能给近处大目标高分。",
  ],

  3262: [
    "--★ 【3262 行：扇形/近距混合判据】`if dot > 0 or dist < min_rad + phys_rad`。",
    "--   dot > 0 = 在玩家朝向的**半球**内（朝向优先）；",
    "--   dist < min_rad + phys_rad = 就在脚边，无论朝向都可选。",
    "--   ⇒ 手柄体验的关键：准星可以指哪打哪，但脚边的东西不会漏掉。",
    "--   ⚠ dot 是**二维**的（3258/3261 行只用 dx/dz），未计入 y。",
    "--     所以站在高处时，朝向判定会把低处目标也算作「前方」。",
  ],

  3265: [
    "--★★★ 【打分公式】`local score = dot + 1 - 0.5 * dist * dist / max_rad_sq`",
    "--   拆解：",
    "--     dot          ∈ [-1, 1]  朝向吻合度（正前方 = 1，背对 = -1）",
    "--     + 1          → 把 dot 平移到 [0, 2]，保证 score 起点为正",
    "--     - 0.5*d²/R²  → 距离惩罚。系数 0.5 意味着「最远处扣 0.5 分」，",
    "--                    而朝向差 180° 扣 2 分 ⇒ ★**朝向权重是距离的 4 倍**。",
    "--   ⇒ 设计意图：手柄瞄准时，玩家「指哪」比「近在哪」重要得多。",
    "--     副作用：正前方远处 (dot=1, d=R) 得 1.5 分；",
    "--            紧贴身后 (dot=-1, d=0) 得 0 分 → 会被前者压过。",
  ],

  3267: [
    "--   ★★★ 四级倍率（3245-3273）：优先级标签乘在基础分上。",
    "--     · 友方（除非 override）      × 0.25",
    "--     · epic（BOSS）               × 5",
    "--     · monster（普通怪）           × 4",
    "--     · 正在攻击玩家                × 6",
    "--     · preferred_target            × 10（3279 行）",
    "--   ⇒ 「正在攻击我」比「BOSS」还高 —— 生存优先于威胁等级。",
    "--   ⚠ 倍率是**连乘**的：epic + 正在攻击我 = 30 倍。",
    "--     这在数学上没问题（仍是单调），但调参时难以直观预期。",
  ],

  3275: [
    "--   ★ 3275 行：目标正在打玩家 → ×6。这是「自保」优先级的来源。",
  ],

  3283: [
    "--   ★ 3283 行把**所有通过筛选的实体**都塞进 current_controller_targeting_targets，",
    "--     不只是最高分的那个。",
    "--   ⇒ 这就是目标锁定功能的数据源：锁定后列表被冻结，可用方向键循环。",
  ],

  3296: [
    "--★★★ 【3296-3327 目标锁定分支】★ 锁定时不更新目标，只维护列表。",
    "--   ★ 三步走：",
    "--     ① 3300-3317 行：把「不在附近实体列表里」的旧目标**移除**",
    "--     ② 3319-3323 行：把新出现的实体**加入**列表",
    "--     ③ 3326 行：直接 return，**不修改** controller_attack_target",
    "--   ⇒ 锁定的语义：「冻结当前目标，但保持候选列表新鲜」，",
    "--     玩家可以用方向键在列表里循环而不丢失候选。",
    "--   ⚠ 疑似缺陷（循环内修改被遍历表）：",
    "--     3300 行 `for idx_outer = #self.controller_targeting_targets, 1, -1 do`",
    "--     内层 3307 行 table.remove 的是 **current_controller_targeting_targets**（安全），",
    "--     3315 行 table.remove 的是 **self.controller_targeting_targets** ——",
    "--     ★★ 这是在**倒序**循环中删除自身元素，倒序保证安全（删 idx_outer 后",
    "--       前面的元素索引不变）。故实际正确，但极易被后来者改成正序而引入 bug。",
    "--     推理依据：倒序遍历 + table.remove 是安全模式；正序则会跳过元素。",
  ],

  3329: [
    "--★★ 3329-3347 行：礼物的特例修正。",
    "--   if giftmachine 有 (Y) 优先级 → 它也压过墙（target = nil）。",
    "--   注释：\"if giftmachine has (Y) control priority, then it should also have",
    "--   (X) control priority over walls\"",
    "--   ⚠ 硬编码墙与礼物机的标签对（IsControllerTargetLocked 之外的一个特例），",
    "--     与 3585 行的 mermthrone/crabking 属同一类「在通用代码里写角色特例」。",
  ],

  3341: [
    "--   3341 行：没有 (X) 目标但 (Y) 目标是墙 → 把墙给 (X) 键。",
    "--   注释：\"if we have no (X) control target, then give it to our (Y) control",
    "--   target if it's a wall\" —— 墙没有攻击价值，把两个键合并到它上面。",
  ],

  3349: [
    "--   ★ 3349-3353 行：目标变化时才更新 controller_targeting_target_index。",
    "--   ⚠ 3351 行 `self.controller_targeting_target_index = selected_target_index`：",
    "--     selected_target_index 是 **current_controller_targeting_targets 的下标**，",
    "--     但 3673 行的 CycleControllerAttackTargetForward 用它索引",
    "--     **self.controller_targeting_targets**。两个不同的表！",
    "--   ⚠⚠ 疑似缺陷（索引表错配）：",
    "--     非锁定状态下 3326 行的 return 不会执行，3329-3353 正常运行，",
    "--       此时 current_controller_targeting_targets 是**每帧新建的临时表**（3241 行），",
    "--       而 self.controller_targeting_targets 只在锁定分支（3322 行）被填充。",
    "--     ⇒ 在「刚开启锁定但还没跑过一次锁定分支」的窗口内，",
    "--       selected_target_index 可能指向一个与 controller_targeting_targets 无关的下标。",
    "--     缓解：ControllerTargetLock(true) 要求已有 controller_attack_target（3653 行），",
    "--       且 3672 行循环前会检查 num_targets > 0，越界会被 3674 行夹回 1。",
    "--     ⇒ 实际后果是「第一次按循环键可能跳到列表第一个」而非崩溃。",
    "--     推理依据：3241 行 local current_controller_targeting_targets = {} 是局部表；",
    "--       3283 行 table.insert 到的是局部表；只有 3322 行才 insert 到成员表。",
  ],

  3355: [
    "--   ★ 非友方目标 → 友方冷却清零（3357 行置 nil，下一帧变成 1 秒）。",
  ],

  3361: [
    "--★★★ 【UpdateControllerInteractionTarget】★ **手柄「Y 键」目标选择（交互）**。",
    "--   268 行，比攻击索敌长 90 行，因为交互的候选类型更多（见 3386-3446 的优先级段）。",
    "--   与攻击索敌的另一大差异：★ 有**显式的优先级段**（早返回），",
    "--     而攻击索敌是纯打分。",
  ],

  3363: [
    "--   ★ 锁定状态且有攻击目标 → 交互目标直接跟随攻击目标。",
    "--     ⇒ 锁定的语义是「两个键绑定同一个目标」。",
  ],

  3366: [
    "--   ★ 放置/施法态 → 强制无目标（3367-3368 行还会重置 age）。",
    "--     建造预览时不该高亮任何可交互物。",
  ],

  3370: [
    "--   ★ 3370-3377 行：当前目标失效的四重检查。",
    "--   3375 行的注释解释为什么跳过 FX/DECOR（同 2106 行）。",
  ],

  3380: [
    "--★★ 3381 行的 `if self.controller_target_age < .2 then return end`：",
    "--   ★★ 手柄目标防抖。目标变化时 age 归零（3392/3403/3424/3573 行），",
    "--     0.2 秒内冻结不再重选。",
    "--   ⇒ 效果：瞄准在两个候选边缘时，「粘住」上一个 0.2 秒，不会抽搐。",
    "--   ⚠ 副作用：玩家**故意**快速切换目标时会觉得「粘手」，需要等 0.2 秒。",
    "--     这是「稳定性 vs 响应性」的经典取舍，DST 选了稳定。",
  ],

  3386: [
    "--★★ 【3386-3446 显式优先级段】按顺序：",
    "--   ① 3387 CATCH（能抓就抓）",
    "--   ② 3400 物品要求用攻击目标（controller_should_use_attack_target）",
    "--   ③ 3409 铲除草皮（terraformerremoveable）—— ★「Turf entity removal always",
    "--      highest priority」",
    "--   ④ 3431 钓鱼（放大小搜索半径）",
    "--   ⑤ 3434 永不选自己的鱼钩",
    "--   ★★ 注意 3414 行的特殊查询：`TheSim:GetEntitiesAtScreenPoint(",
    "--     TheSim:GetScreenPos(x, y, z))` —— 用**玩家自己所在屏幕位置**做查询，",
    "--     因为草皮视觉体的原点离实际网格很远（3420-3421 行注释）。",
    "--   ⚠ 这个特例在 5422-5430 行的 GetGroundUseAction 里被**完整复制了一遍**。",
    "--     推理依据：两处的注释文字几乎一字不差。代码重复，改一处会漏另一处。",
  ],

  3398: [
    "--   equipped_item：★ 注意变量名拼写错误（equiped 少一个 p），全文件一致。",
  ],

  3400: [
    "--   ★ controller_should_use_attack_target：物品要求「用攻击键而不是交互键」。",
    "--     例：某些工具只能通过攻击键对敌使用。此时 (Y) 跟随 (X)。",
  ],

  3412: [
    "--   -- Special case for ACTIONS.TERRAFORM_REMOVE via placed turf visuals needing",
    "--   to take highest priority over all other checks due to increased range from",
    "--   entity origin.",
    "--   -- We will use the player's origin to find things with the tag to use the action.",
    "--   ★★ 英文注释说清了原因：草皮的**视觉体**原点离它的实际位置很远",
    "--     （视觉体挂在网格上，原点在中心），所以用常规距离判定会漏掉脚下的草皮。",
  ],

  3431: [
    "--   --Fishing targets may have large radius, making it hard to target with normal priority",
    "--   ★ 钓鱼时**无视当前目标**强制用最大半径搜索（鱼群范围大）。",
  ],

  3433: [
    "--   -- we want to never target our fishing hook, but others can",
    "--   ★ 自己的鱼钩永不成为 (Y) 目标（会自我循环），但队友的可以（帮他收线）。",
  ],

  3436: [
    "--   ★★ 交互半径：min_rad = 1.5 / max_rad = 6。",
    "--   与攻击的 3 / max_rad+3.5 完全不同：交互需要**更大的近距离容忍**",
    "--   （1.5 vs 3）但**更小的最大距离**（6 vs 攻击的 ~6.5）。",
    "--   ⇒ 交互刻意做成「贴身且短距」，避免误选远处物体。",
  ],

  3441: [
    "--★★ 3441-3445 行：**迟滞半径（sticky radius）**。",
    "--   rad = 有当前目标 ? clamp(当前距离, min_rad, max_rad) : max_rad。",
    "--   ⇒★ 核心效果：当前目标在 1.5~6 之间时用**它自己的距离**作搜索半径，",
    "--     且加了 .1 的浮点余量（3445 行）。",
    "--   ⇒ 这实现了「目标锁定在范围内时不因轻微移动而丢失」。",
    "--   3520 行的 mult = 1.5 是这个机制的第二半（分数加成）。",
    "--   ⇒★★ 两处配合：半径不缩小（保目标）+ 分数放大（优先选它）。",
  ],

  3447: [
    "--   TheSim:FindEntities 用 TARGET_EXCLUDE_TAGS（2081 行），非注册版。",
    "--   ⚠ 与攻击索敌用 RegisterFindTags 版本不同 —— 这里每帧走一次完整查询。",
    "--     性能影响：手柄每帧最多 1 次（攻击 + 交互各 1 次）。可接受。",
  ],

  3456: [
    "--★ canexamine 的四重判据（与 2361-2364 行的 GetInspectButtonAction 完全同型）。",
    "--   3457 行的 `self.inst.HUD:IsPlayerAvatarPopUpOpen()` 没有 HUD nil 检查。",
    "--   ⚠ 疑似缺陷（nil 索引风险）：3457 行 `self.inst.HUD:...` 直接索引。",
    "--     缓解：UpdateControllerTargets 只在 handler ~= nil 时被调用（2821 行），",
    "--       而 handler ~= nil 意味着是本机玩家，HUD 必然存在。",
    "--     推理依据：2821 行的 `if self.handler ~= nil then` 包裹。",
    "--   ⚠ 与 3458 行的 `self.inst.sg == nil or ...` 对比，3457 行是唯一没做双端兜底的。",
  ],

  3461: [
    "--   ★★ currentboat / anglemax：**站在船上时交互角度放宽**。",
    "--   TUNING.CONTROLLER_BOATINTERACT_ANGLE vs TUNING.CONTROLLER_INTERACT_ANGLE。",
    "--   ⇒ 为什么：船在晃，站在船上瞄准时手柄视角相对船是偏的，",
    "--     若用陆地的严格角度会频繁选错。",
  ],

  3464: [
    "--   ★ v = v.client_forward_target or v —— 与 2264 行完全相同（第二次出现）。",
    "--   ⚠ 两处必须同步修改，否则鼠标与手柄的转发行为分叉。",
  ],

  3466: [
    "--   排除自己的鱼钩（3434 行算出）。",
  ],

  3469: [
    "--   ★★ 3469 行三重守卫：不是自己 / 不是重复的当前目标 / 实体可见。",
  ],

  3470: [
    "--   ★ bundle（正在捆扎/建造中的物件）→ 无条件选中并 break。",
    "--     注释 \"bundling or constructing\" —— 正在施工的东西必须能被选中，",
    "--     否则玩家会「看不清自己在建什么」。",
    "--   ⚠ 直接 break 跳出整个循环 = 最高优先级，不参与打分。",
  ],

  3476: [
    "--   --Calculate the dsq to filter out objects, ignoring the y component for now.",
    "--   ★★ 与攻击索敌（3253 行算 y）相反：交互的初筛**忽略 y**。",
  ],

  3481: [
    "--   ★ 3481-3486 行：钓鱼时「鱼在网里就算贴着」，把 dsq 强制为 0。",
    "--     这是「上了钩的鱼自动成为目标」的机制（半径内直接命中）。",
  ],

  3488: [
    "--★ 【3488-3492 半径判据】三选一即可：",
    "--     ① dsq < min_rad_sq（1.5²）：无论朝向",
    "--     ② dsq <= rad_sq 且（是当前目标 / 是攻击目标 / 在朝向半球内）",
    "--   ⇒ 「当前目标」与「攻击目标」享有越过角度限制的特权（3490-3491 行）。",
  ],

  3494: [
    "--★★ 3494 行 `local shouldcheck = dsq < 1 -- Do not skip really close entities.`",
    "--   ★★ 角度检查的豁免：**距离中心 1 格以内**（平方 1，即半径 1）的实体跳过角度判定。",
    "--   ⇒ 效果：脚边的东西永远能选中，不会因为「没正对着它」而选不到。",
    "--   与攻击索敌的 3262 行 `dist < min_rad + phys_rad` 同源思路。",
  ],

  3496: [
    "--   3496-3500 行：角度检查用 **angletoepos**（实体位置的绝对角），",
    "--     而打分用 **dot**（相对玩家朝向的向量点积）。",
    "--   ⇒ 两个角度概念并存：",
    "--     · angleto/anglemax = 「实体在不在视野锥内」（硬过滤）",
    "--     · dot = 「有多正对」（软打分）",
  ],

  3498: [
    "--   ★ angleto = math.abs(anglediff(-heading_angle, angletoepos)) ——",
    "--     **减号**再次是 Z 轴符号约定（参见文件头 480 行）。",
    "--     heading_angle 本身在 3616 行也是 `-GetRotation()`。两个负号抵消。",
  ],

  3502: [
    "--★★ 3502-3505 行：**y 分量延后加入**。★ 注释解释得很清楚：",
    "--   --Incorporate the y component after we've performed the inclusion radius test.",
    "--   --We wait until now because we might disqualify our controller_target if its",
    "--   transform has a y component, but we still want to use the y component as a",
    "--   tiebreaker for objects at the same x,z position.",
    "--   → 翻译：先在 xz 平面判「在不在范围内」，再把 y 差加进距离做**平局时的区分**。",
    "--     为什么不一开始就加 y？因为站在二楼时，用 3D 距离会把一楼脚下的东西判远。",
    "--   ⇒★★ 这是本文件最精细的一处设计：分层过滤 + 平局决胜。",
  ],

  3511: [
    "--★ 【3511-3522 交互打分公式】`angle_comp * dist_comp * mult + add`",
    "--     angle_component = (dot + 1) / 2          → [0, 1] 归一化朝向分",
    "--     dist_component   = dsq < min_rad_sq and 1 or min_rad_sq / dsq",
    "--                                          → 近处 1，min_rad 处 ≈1，更远按平方衰减",
    "--     mult             = 当前目标且非墙 ? 1.5 : 1   → 迟滞加成",
    "--     add              = dsq < .0625 and 1 or 0  → ★ 极近处（0.25 格）额外 +1",
    "--   ⚠ 与攻击索敌（3265 行 dot + 1 - 0.5*d²/R²）**完全不同**：",
    "--     这里**没有常数 1 的偏移**，所以 add 是唯一能让「极近目标」取胜的项。",
    "--     注释 3516 行：\"for stuff that's *really* close - ie, just dropped\"",
    "--     —— 刚丢在地上的东西必须立刻能被选中（+1 直接碾压其他候选）。",
    "--   ⚠ 但 3536 行 `if score < target_score then skip` 意味着**严格小于才跳过**，",
    "--     所以同分时后来者会赢（见 3537-3541 的 CanMouseThrough 平局规则）。",
  ],

  3526: [
    "--   ★ 3527 行 portal 的双向调整：",
    "--     幽灵态 + 有复活点 → ×1.1（更容易选中传送门复活）",
    "--     活人态        → ×0.9（略微降低，避免误选传送门）",
    "--   注释：\"make it easier to haunt the portal for resurrection in endless mode\"",
    "--   ⚠ GetPortalRez() 没有 nil 检查：若该函数可返回 nil，1.1 会变成 nil，",
    "--     整个 score 变 nil → 3536 行比较报错。",
    "--     推理依据：3527 行 `GetPortalRez() and 1.1 or .9` 的 and/or 惯用法",
    "--       在 GetPortalRez 返回 nil 时会走 or 分支取 0.9，故实际安全。",
  ],

  3530: [
    "--   hasfurnituredecoritem（家具装饰品）→ ×0.5，避免与真家具抢目标。",
  ],

  3536: [
    "--★★ 3536-3541 行：平局时的 CanMouseThrough 规则。",
    "--   `score < target_score` → 跳过；`score == target_score` 时，",
    "--     若新候选**能穿透鼠标**而旧的不行 → 仍然替换。",
    "--   ⇒ CanMouseThrough：某些实体会被鼠标「穿透」（如隐形墙），",
    "--     同分时应优先选能被点到的那个。",
  ],

  3543: [
    "--   3543 行：可检视物直接选中（不打分），注释 \"elseif canexamine and",
    "--   v:HasTag('inspectable')\" —— 检视优先级高于「有没有可用动作」。",
  ],

  3547: [
    "--   --this is kind of expensive, so ideally we don't get here for many objects",
    "--   ★★★ K 自己标注了性能顾虑：GetSceneItemControllerAction（5339 行）",
    "--     内部会调 playeractionpicker 两次，**很贵**。",
    "--   ⇒ 这就是 3488-3500 行那些廉价的距离/角度过滤必须放在前面的原因：",
    "--     它们是「廉价拒绝」，GetSceneItemControllerAction 是「昂贵确认」。",
    "--   ⇒★★ 这是本文件里少见的、把性能预算写进注释的地方，非常有参考价值。",
  ],

  3549: [
    "--   ★ 3549 行：同一条船上的场景物降权到 0.75 倍。",
    "--     因为船上全是可交互物，需要给「非船上的」让路。",
  ],

  3556: [
    "--   ★ 3556-3563 行：手持物品对目标的右键使用（GetItemUseAction）。",
    "--     放在最后是因为它需要先有光标物品（controller-only）。",
    "--   ⚠ 3559 行要求 `rmb.target == v` —— 严格匹配，若 GetItemUseAction",
    "--     返回的是「对自己用」的动作（target 为 nil）则不匹配。",
  ],

  3571: [
    "--   ★ 目标变化才重置 age（3573 行）。这是 3381 行防抖的起点。",
  ],

  3577: [
    "--★★ 【UpdateControllerConflictingTargets】冲突消解（30 行，纯硬编码特例）。",
    "--   3582-3583 行的 K 注释坦白了这段的性质：",
    "--     \"This is for handling when there are two targets on a controller but one",
    "--      should take super priority over the other. Most of this will be",
    "--      workarounds in appearance as there are no sure fire ways to guarantee",
    "--      what two entities should be prioritized by actions alone as they need",
    "--      additional context.\"",
    "--   → 翻译：「两个键各选了一个目标，但应该让其中一个压过另一个」。",
    "--     因为动作系统缺少表达「这两个实体之间有上下文关系」的能力，",
    "--     所以只能在这里打补丁。K 自认这是 appearance-level 的 workaround。",
  ],

  3585: [
    "--   ★ 特例 1：正在查看美人鱼王座（mermthrone）时，旁边的鱼人（merm）优先。",
    "--     因为鱼人王座机制要求与鱼人交互。",
    "--   ⚠ 硬编码在通用组件里，与 3329 行的礼物机属同类问题。",
  ],

  3589: [
    "--   ★ 特例 2：两只蟹王钳（crabking_claw）时选近的那个。",
    "--     注释：\"it will most likely be the one next to a boat\" ——",
    "--     「因为近的那个多半是在船边上的那个」。",
    "--   ⚠ 3595 行只在 else 分支重置 controller_target_age，不对称。",
  ],

  3600: [
    "--   ★ 写回结果。若两者都没变（3600 行之前的 target/attacktarget 相同），",
    "--     赋值是幂等的。",
  ],

  3603: [
    "--★★ 【UpdateControllerTargets(dt)】三件套的调度器。",
    "--   ★ 顺序很重要：3619 交互先算（它可能修改 controller_attack_target，",
    "--     见 3400-3405 行的 controller_should_use_attack_target），",
    "--     然后 3620 攻击再算（会覆盖 controller_attack_target），",
    "--     最后 3621 冲突消解。",
    "--   ⚠ 但 3362 行 UpdateControllerInteractionTarget 的第一行会读",
    "--     `self:GetControllerAttackTarget()` —— 用的是**上一帧**的攻击目标。",
    "--     ⇒ 存在一帧的延迟。锁定状态下这个延迟不影响（3364 行直接赋值）。",
  ],

  3615: [
    "--   ★★ heading_angle = -GetRotation()，再取 cos/sin 得 dirx/dirz。",
    "--   ⚠ 注意 3617-3618 行：`dirz = math.sin(heading_angle * DEGREES)`",
    "--     ★★ **没有负号**！而 3616 行已经取过负的 rotation。",
    "--   ⇒ 这就是为什么 480 行的注释说「Z 偏移为负」：",
    "--     rotation 取负 → sin(-θ) = -sin(θ) → 自动完成 Z 翻转。",
    "--     理解要点：dirx/dirz 是**引擎坐标系**下的朝向向量，与「屏幕右下」直觉相反。",
    "--   ⇒ 与 4034 行 `math.atan2(z0 - pt.z, pt.x - x0) * RADIANS` 对照：",
    "--     那个 atan2 的结果可以直接与 dir 的 atan2 对比，说明坐标系一致。",
  ],

  3624: [
    "--【GetControllerTarget / GetControllerAttackTarget】带 IsValid 校验的 getter。",
    "--   ★ 为什么需要包装：因为 controller_target 可能已被 Remove（-IsValid 后索引会崩）。",
    "--   ⚠ 但它们不检查 IsValid 之外的 INLIMBO/NOCLICK（3370-3377 行的检查在别处）。",
  ],

  3632: [
    "--   ★ 3632-3636 行：`--[[ CharlesB: Disabled for now ]]` 块注释掉的",
    "--     IsControllerTargetingModifierDown。③ 与 125-127 行的注释字段配套。",
    "--   ⇒ 目标锁定经历了「按住修饰键」→「按一下切换」的设计变更。",
  ],

  3638: [
    "--【CanLockTargets / IsControllerTargetLockEnabled / IsControllerTargetLocked】",
    "--   三个查询。3638 行读 Profile（玩家设置），3642/3646 读运行时状态。",
    "--   ⚠ 3647 行 `IsControllerTargetLocked()` 返回的是 `lock_target and attack_target`，",
    "--     是一个**实体或 nil/false** 而非布尔 —— 严格说是「锁定目标本身」。",
    "--     外部（widgets/controls.lua:748/755/771）当作布尔用，靠 Lua 的真值语义工作。",
  ],

  3650: [
    "--【ControllerTargetLock(enable)】",
    "--   ★ 3653 行：**必须有目标才能锁定**。避免锁定到空。",
  ],

  3670: [
    "--【CycleControllerAttackTargetForward / Back】方向键循环候选目标。",
    "--   ★ 只在锁定状态下生效（3672 行）。3670 正向 / 3681 反向。",
    "--   ⚠ 3681 行 CycleControllerAttackTargetBack **无任何调用点**（grep 全文确认）。",
    "--     ⇒ 反向循环是预留功能（可能由模组或未来的手柄设置调用）。",
    "--   ★ 3673 行 `index + 1` 若 index 为 nil 会崩。",
    "--     缓解：index 由 3351 行设置，而 3351 只在「目标变化」时赋值；",
    "--       首次锁定时若目标未变化（index 仍为 nil）就会崩。",
    "--     但 3653 行要求锁定时已有 controller_attack_target，",
    "--     而该目标必然是某帧 3349-3353 行设的（此时 index 被赋）。",
    "--     ⚠ 除非该目标是 3229 行插入的「已在列表中」路径 —— 仍会走 3349 分支。",
    "--     推理依据：3349 行 `if target ~= self.controller_attack_target` 在",
    "--       首次设置时必然为真，故 index 会被赋值。实际安全。",
  ],

  3697: [
    "--============================================================",
    "-- 【第七段预告】3693 行开始是 ★ 移动链路的核心，",
    "--   remote_vector 的编码表、四种行走手势、橡皮筋纠正、teleport 区分",
    "--============================================================",
  ],
};

export const AFTER = {};