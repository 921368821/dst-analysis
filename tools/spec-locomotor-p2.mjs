// spec-locomotor-p2.mjs —— locomotor.lua 深度注释规格 第 2 部分
// 覆盖：更新生命周期 → 移动计时器 → 外部速度倍率源表 → 地面速度
// 锚点范围：331 ~ 640

export const BEFORE = {
  // ══════════════════════════════════════════════════════════════
  // 四、更新生命周期（休眠协作）
  // ══════════════════════════════════════════════════════════════
  "LocoMotor:EnableHopDelay#1": [
    "--★★【EnableHopDelay：跳跃延迟的懒初始化】",
    "--   hop_delay 是一张记录跳跃延迟状态的小表（记录从哪个平台到哪个平台、",
    "--   起始 tick 等），见 1276-1319 行的使用。",
    "--   ★★ 它是可选功能：只有调用过 EnableHopDelay(true) 的实体才有延迟。",
    "--     延迟机制的目的是「防止玩家狂点方向键连续跳船」（见 1411 行注释）。",
    "--   ★ 传 false 会把它置 nil（关闭延迟）——**双向开关**。",
  ],
  "LocoMotor:EnableHopDelay#1+4": [
    "--★ 四个字段：toplatform/fromplatform（延迟跨平台的具体范围）、",
    "--   starttick/lasttick（延迟计时的起止）。starttick=-1 表示「未开始计时」。",
  ],
  "LocoMotor:StartUpdatingInternal#1": [
    "--★★★【StartUpdatingInternal：把「我要每帧更新」的请求落地】",
    "--   ★★ 关键：`if not self.inst:IsAsleep()` —— 休眠实体不加入更新队列。",
    "--     但 isupdating 仍被置 true！",
    "--   ★★★ 这是「休眠协作」的核心：",
    "--     · isupdating = true 记住「唤醒后应该继续更新」",
    "--     · OnEntityWake:381 读它并真正 StartUpdatingComponent",
    "--   ★ 若不加 IsAsleep 检查，休眠实体会被每帧遍历（性能浪费），",
    "--     且它的 OnUpdate 会在无渲染的情况下跑（可能引发副作用）。",
  ],
  "LocoMotor:StopUpdatingInternal#1": [
    "--★ StopUpdatingInternal 是对称的：清 isupdating 标志 + 移出更新队列。",
  ],
  "LocoMotor:OnEntitySleep#1": [
    "--★★★【OnEntitySleep：休眠即停止移动】",
    "--   ★★ 设计决策：实体进入休眠（离屏太远）时，直接 Stop() ——",
    "--     不仅停止物理移动，还要清掉目标、路径、缓冲动作。",
    "--   ★ 理由：休眠意味着「没有玩家在看它」，任何自动移动都是浪费 CPU；",
    "--     而且唤醒后实体位置必须与服务器一致，让它继续走会穿墙。",
  ],
  "LocoMotor:OnEntityWake#1": [
    "--★ OnEntityWake 恢复更新 —— 与 365 行的 isupdating 标记严格配对。",
  ],
  "LocoMotor:OnRemoveFromEntity#1": [
    "--★★【OnRemoveFromEntity：组件卸载清理】",
    "--   ★ 三件事：① 摘 locomotor tag（服务端）；② 摘 turf 加速 tag；",
    "--     ③ 摘所有外部倍率来源的 onremove 监听；④ 重置预测倍率。",
    "--   ⚠★ 缺失的清理：没有 KillPathSearch()。",
    "--     若实体在寻路搜索挂起时被移除，搜索句柄会悬空。",
    "--     这属于「引擎层负责回收」还是「缺陷」取决于 C++ 侧的实现，",
    "--     但从 Lua 侧看这是个清理漏洞。",
  ],
  "LocoMotor:OnRemoveFromEntity#1+4": [
    "--★ 摘 turf 加速 tag —— 与 600 行的 AddOrRemoveTag 配对。",
    "--   ⚠ 遍历时用 `for ground_tile in pairs(...)` 而非 ipairs（是字典表）。",
  ],
  "LocoMotor:OnRemoveFromEntity#1+8": [
    "--★ 摘除所有外部倍率来源的 onremove 监听 —— 防止闭包持有已死实体。",
    "--   ★★★ 这正是 bug-patterns.md A7（事件监听未注销）的正确处理方式。",
  ],
  "LocoMotor:OnRemoveFromEntity#1+11": [
    "--★ 预测倍率容器重置 —— 客户端专用（服务端不创建该容器，见 549 行）。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 五、移动计时器（配合状态图与战斗）
  // ══════════════════════════════════════════════════════════════
  "LocoMotor:GetTimeMoving#1": [
    "--★★★【GetTimeMoving：已移动时长，供状态图/战斗判断「持续移动了多久」】",
    "--   三级判定：",
    "--     ① predictmovestarttime 存在 → 用**客户端预测**的时刻（客户端优化）",
    "--     ② movestoptime 存在且距停止 ≥ 0.3 秒 → 返回 0（已停稳）",
    "--     ③ 否则 → now - movestarttime",
    "--   ★★ 为什么要 0.3 秒阈值（而不是立即返回 0）？",
    "--     因为移动中的实体会**周期性停下**（撞墙、被推开、路径拐点减速），",
    "--     若一停下就归零，会导致「我明明在走却被判定为静止」。",
    "--     0.3 秒的迟滞窗口过滤掉了这些微小停顿。",
    "--   ★★ 这是「迟滞（hysteresis）」设计的又一处应用（另见 health.lua 的 FIRE_TIMEOUT）。",
  ],
  "LocoMotor:GetTimeMoving#1+2": [
    "--★ 客户端预测路径：predictmovestarttime 由 RestartPredictMoveTimer 设置，",
    "--   客户端用它做「提前判定」，减少输入延迟感知。",
  ],
  "LocoMotor:GetTimeMoving#1+8": [
    "--★ 兜底路径：从未停过 → now - movestarttime。",
  ],
  "LocoMotor:StartMoveTimerInternal#1": [
    "--★★★【StartMoveTimerInternal：\"开始移动\"的迟滞重置】",
    "--   ★ 逻辑：只有当「上次停止距今 ≥ 0.3 秒」才算真正的重新开始，",
    "--     此时才重置 movestarttime（并撤销 movetimeoverride）。",
    "--   ★ 否则（刚刚才停下）只清 movestoptime，不动 movestarttime ——",
    "--     这样「短暂的停-走-停」不会让计时器反复重置。",
  ],
  "LocoMotor:StartMoveTimerInternal#1+4": [
    "--★ movetimeoverride 撤销：这是客户端预测的定时清理（见 438 行）。",
  ],
  "LocoMotor:StartMoveTimerInternal#1+8": [
    "--★★ 关键：movestarttime = t（而非 t - 0.3），因为 0.3 秒只是「判定阈值」，",
    "--   不是「应该补偿回的时间」。",
  ],
  "LocoMotor:StopMoveTimerInternal#1": [
    "--★ StopMoveTimerInternal 极简：只在第一次停止时记时刻（不动 movestarttime）。",
    "--   ★★ 幂等设计：重复调用不会覆盖第一次停止的时刻，",
    "--     所以「什么时候停的」是稳定的，不会被后续的重复 Stop 滑动。",
  ],
  "ClearOverrideMoveTimer#1": [
    "--★ ClearOverrideMoveTimer：延迟 2 帧后自动清除预测覆盖值。",
    "--   ★★ 为什么要延迟 2 帧？因为 OverrideMoveTimer 的目的是「本帧内让预测生效」，",
    "--     下一帧的服务器数据到达后就该失效了。",
    "--     用 DoTaskInTime(2 * FRAMES) 而不是逐帧检查，是「一次性清理」的标准写法。",
  ],
  "LocoMotor:OverrideMoveTimer#1": [
    "--★★★【OverrideMoveTimer：强制设置「已移动时长」】",
    "--   `self.movestarttime = t - movetime` —— 把起点往回挪，等价于「已经移动了 movetime 秒」。",
    "--   ★★ 用途【客户端→服务器的移动时间预测同步】：",
    "--     玩家按住方向键走路，客户端本地能精确知道「我走了 3 秒」，",
    "--     但服务器只知道「玩家在动」。当玩家在移动中发起攻击时，",
    "--     攻击的距离/时机判定（combat.lua 的 GetTimeMoving）需要准确的移动时长。",
    "--     所以客户端通过 PopOverrideTimeMoving 把这个值随攻击包发给服务器。",
    "--   ★ 这是「客户端预测 + 服务端采纳」的一个小而精的例子。",
    "--   ⚠ 只在客户端创建清理任务（`if not self.ismastersim`）——",
    "--     服务端不需要预测清理，因为服务端的 movestarttime 就是权威值。",
  ],
  "LocoMotor:OverrideMoveTimer#1+8": [
    "--★ 2 * FRAMES = 2 帧（FRAMES 常量为一帧的 tick 数，通常 1/30 秒）。",
    "--   ★ 用 2 而非 1：留一帧余量，确保下一网络批次的权威数据已覆盖。",
  ],
  "LocoMotor:OverrideMoveTimer#1+9": [
    "--★ 把 movetime 挂在 Periodic 对象上（_movetime）—— Lua 没有闭包字段的替代方案。",
    "--   ★ 这是「用对象当结构体」的常见技巧，Periodic 对象本身是安全可挂载的。",
  ],
  "LocoMotor:OverrideMoveTimer#1+13": [
    "--★★ 英文原注释 \"only used by clients for sending to server\"。",
    "--   ★ 明确了这个方法的唯一用途：客户端上报预测的移动时长。",
  ],
  "LocoMotor:RestartPredictMoveTimer#1": [
    "--★★ RestartPredictMoveTimer：客户端预测计时的开始（玩家开始移动时调）。",
    "--   ★ 由 playercontroller 在处理玩家输入时调用。",
  ],
  "LocoMotor:CancelPredictMoveTimer#1": [
    "--★ CancelPredictMoveTimer：取消预测。GoToEntity/GoToPoint 都会调（986/1044 行），",
    "--   注释说「能走到这里说明客户端没在预测」—— 即服务端路径会取消客户端的预测。",
  ],
  "LocoMotor:OverridePredictTimer#1": [
    "--★ OverridePredictTimer：直接设定预测起始时刻（网络同步来的时间戳用）。",
  ],
  "LocoMotor:StopMoving#1": [
    "--★★★【StopMoving：物理层立即停】",
    "--   `self.inst.Physics:Stop()` —— 停止 C++ 侧的物理马达。",
    "--   ★ 与 Stop()（1091 行）区分：Stop() 是「完整停止移动意图」，",
    "--     StopMoving() 是「只停物理，不清目标」。",
    "--   ★ 为什么物理速度会被重置？Physics:Stop 把速度与马达速度都清零，",
    "--     这也是「实体不会滑行」的原因。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 六、外部速度倍率（带来源的倍率表）
  // ══════════════════════════════════════════════════════════════
  "LocoMotor:StopMoving#1+5": [
    "--★★★【V2C 注释揭示了 Recalculate 的设计契约】",
    "--   \"we always call this to recalculate even if only one value changes,",
    "--   so we can always do custom math here\"",
    "--   ★★★ 翻译：即使只有一个倍率变了，也总是**全量重算**所有倍率，",
    "--     这样「合成算法」可以随时被模组改写成任意数学规则，",
    "--     而不必关心「哪个值变了」。",
    "--   ★ 这是「无增量、无缓存」的刻意选择：牺牲性能换可扩展性。",
    "--     性能上完全可接受（倍率来源通常个位数，每帧调用几次）。",
    "--   ★ 模组改写方式：猴补本函数即可改变所有外部倍率的合成规则。",
  ],
  "LocoMotor:RecalculateExternalSpeedMultiplier#1": [
    "--★★ RecalculateExternalSpeedMultiplier：所有来源的倍率**连乘**。",
    "--   语义：1.2（加速 20%）和 0.8（减速 20%）相乘 = 0.96（净减速 4%），",
    "--   而不是加法 1.0。这是倍率类效果的常规合成方式。",
  ],
  "LocoMotor:SetExternalSpeedMultiplier#1": [
    "--★★★【SetExternalSpeedMultiplier：带来源与 key 的倍率设置】",
    "--   三层防护：",
    "--     · key 为 nil → 直接返回（防呆：必须指定 key）",
    "--     · m 为 nil 或 1 → 转为「移除」（1 是无效果的恒等值）",
    "--     · 首次注册该来源 → 建表 + 注册 onremove 自摘除",
    "--   ★ 把 m=1 当作「移除」是刻意的：调用方不需要自己判断「要不要撤」。",
    "--   ★ onremove 自摘除（501-506）：来源实体消失时自动清掉其倍率。",
  ],
  "onremove#1+5": [
    "--★ ListenForEvent 注册自摘除 —— 参见 util/sourcemodifierlist.lua 的同款实现。",
  ],
  "onremove#1+7": [
    "--★ 已有该来源且该 key 的值变了 → 更新并全量重算。",
  ],
  "LocoMotor:RemoveExternalSpeedMultiplier#1": [
    "--★★【RemoveExternalSpeedMultiplier：与 Set 完全对称的两段式移除】",
    "--   传 key → 只删这一路；删完发现该来源没路了 → 整体拆掉 + 反注册 onremove。",
    "--   ★ 与 health.lua 的 RemoveRegenSource（407 行）是同一套模式。",
  ],
  "LocoMotor:RemoveExternalSpeedMultiplier#1+5": [
    "--★ 删 key 后判断来源是否还有其它 key（决定是否整体拆）。",
  ],
  "LocoMotor:GetExternalSpeedMultiplier#1": [
    "--★★ GetExternalSpeedMultiplier：查询接口，key 可选。",
    "--   不传 key → 返回该来源所有 key 的乘积；传 key → 返回该 key 的值（或 1）。",
    "--   ★ 统一用 `or 1` 兜底 —— 「无效果」的标准表示法。",
  ],
  "LocoMotor:SetPredictExternalSpeedMultiplier#1": [
    "--★★★【SetPredictExternalSpeedMultiplier：客户端专用预测倍率】",
    "--   ★★★ 与 SetExternalSpeedMultiplier 的关键区别：",
    "--     · 不分双端，**只在客户端被调用**（548 行无 ismastersim 判断，",
    "--       但因为只在客户端场景使用，语义上等价）",
    "--     · 用 SourceModifierList 而不是手写表（复用现成的自摘除机制）",
    "--     · 结果在 159 行与 netvar 相乘，不直接替换",
    "--   ★★ 设计意图：让「马上要吃加速/减速药」这类瞬时效果",
    "--     在**本地立即生效**，而不等服务端下一网络帧。",
    "--     服务端不认可时，netvar 部分会自然覆盖回来。",
  ],
  "LocoMotor:GetPredictExternalSpeedMultipler#1": [
    "--★ 注意函数名拼写是 GetPredictExternalSpeedMultipler（少一个 i，Multipler）。",
    "--   ★★★ 这是一个**接口命名瑕疵**：内部调用（159 行）也跟着拼错。",
    "--     因为它是公开 API，改名会炸模组，所以只能将错就错。",
    "--     强类型移植时这是一个必须保留的历史拼写（或加 deprecated 别名）。",
  ],
  "LocoMotor:GetPredictExternalSpeedMultipler#1+1": [
    "--★ 三元式 `A and A:Get() or 1` —— 容器不存在时返回 1（无效果）。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 七、地面速度（每帧调用的性能敏感区）
  // ══════════════════════════════════════════════════════════════
  "LocoMotor:SetSlowMultiplier#1": [
    "--★ SetSlowMultiplier：creep 上的减速倍率（默认 0.6，可被 prefab 改）。",
  ],
  "LocoMotor:SetTriggersCreep#1": [
    "--★ SetTriggersCreep：是否响应 creep 边沿事件（某些实体如幽灵不触发）。",
  ],
  "LocoMotor:SetFasterOnCreep#1": [
    "--★ SetFasterOnCreep：是否在 creep 上加速（反向于减速）。",
  ],
  "LocoMotor:EnableGroundSpeedMultiplier#1": [
    "--★★【EnableGroundSpeedMultiplier：地面速度的总开关】",
    "--   关闭时**同时清空所有临时状态**（tempgroundspeedmultiplier 等），",
    "--   而不只是置 enable=false。",
    "--   ★ 为什么必须清？因为 TempGroundSpeedMultiplier（655 行）",
    "--     不检查 enable 标志，只看时间戳。若只置 enable=false，",
    "--     临时倍率仍会生效 —— 这就是「开关必须清理关联状态」的典型。",
  ],
  "LocoMotor:GetWalkSpeed#1": [
    "--★★★【GetWalkSpeed / GetRunSpeed：最终速度的两个入口】",
    "--   两者结构完全相同：`基准速度 × GetSpeedMultiplier()`。",
    "--   ★ 区别只在基准：walkspeed（4）与 RunSpeed()（6 或坐骑速度）。",
    "--   ★★ RunSpeed 走函数（可能是坐骑速度），walkspeed 是裸字段 ——",
    "--     所以骑马时走路速度**不会**用马的速度。这个不对称是有意的：",
    "--     坐骑的「走」由坐骑自己控制（DST 坐骑没有走/跑之分）。",
  ],
  "LocoMotor:SetFasterOnGroundTile#1": [
    "--★★【SetFasterOnGroundTile：turf 加速的 setter，必须双写（表 + tag）】",
    "--   `self.faster_on_tiles[tile] = is_faster`（服务端数据）",
    "--   `self.inst:AddOrRemoveTag(\"turfrunner_\"..tile, is_faster)`（客户端可见）",
    "--   ★★★ 这就是「tag 作为跨端状态载体」的写入点，",
    "--     与 252-263 行 ClientIsFasterOnGroundTile 的 tag 读取严格配对。",
    "--   ★ 为什么 turf 用 tag 而 runspeed 用 netvar？因为 turf 是",
    "--     「世界数据」（由世界扫描写入），不是「玩家数据」，",
    "--     netvar 是每实体一个浮点数，太多 turf 实体会浪费带宽；",
    "--     而 tag 是位打包的，扩展性好。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1": [
    "--★★★【UpdateGroundSpeedMultiplier：每帧可能被调用的性能敏感函数】",
    "--   这是本文件最热的函数之一（每帧、每移动实体都跑）。",
    "--   它做两件互斥的事：",
    "--     在 creep 上 → 设 slowmultiplier（减速）",
    "--     不在 creep 上 → 按「快地面条件」设 fastmultiplier 或 1（加速/正常）",
    "--   ★★★ 性能：内部有三次世界查询——",
    "--     ① TheWorld.GroundCreep:OnCreep(x,y,z)（查 creep 网格）",
    "--     ② TheWorld.Map:GetTileAtPoint（查地块）",
    "--     ③ RoadManager:IsOnRoad（查道路）",
    "--     ★★ 优化全靠调用方（1438-1444 行）：只在「地块坐标变化」时才调本函数。",
    "--       所以实际调用频率 ≈ 「每秒跨过的地块数」而非 30 次/秒。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+1": [
    "--★ 取世界坐标 —— 之后所有查询都基于它。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+2": [
    "--★ GroundCreep:OnCreep 查地面腐蚀（西边的蕨地/触手等）。C++ 侧网格查询。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+4": [
    "--★ oncreep 且允许触发 —— 才走减速分支。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+5": [
    "--★★★【英文原注释是一条设计自省】",
    "--   \"if this ever needs to happen when self.enablegroundspeedmultiplier is",
    "--   set, need to move the check for self.enablegroundspeedmultiplier above\"",
    "--   ★★★ 翻译：这段 creep 减速逻辑**绕过了** enablegroundspeedmultiplier 开关",
    "--     （它只检查 triggerscreep）。作者知道这是不一致的，并写下了修复方案：",
    "--     「若将来需要在开关打开时才生效，把开关检查提到前面」。",
    "--   ★ 这是一段难得的「把已知技术债写进注释」的范例 ——",
    "--     强类型重写时应该直接执行这个修复。",
    "--   ⚠ 具体表现：调用 EnableGroundSpeedMultiplier(false) 之后，",
    "--     实体在 creep 上**依然会减速**。这是可观察的行为差异。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+6": [
    "--★★ `if not self.wasoncreep` —— 边沿检测：只有「刚踏上 creep」才派发事件。",
    "--   ★ 这保证「站在 creep 上不动」不会每帧重复派发 walkoncreep。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+7": [
    "--★ GetTriggeredCreepSpawners：查出该位置会触发哪些 creep 生成器（伏笔需求）。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+12": [
    "--★ walkoncreep 事件：供 prefab 播放「踩到腐蚀」特效等。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+16": [
    "--★★ vigorbuff 标签：韦爵的「活力」buff 让他免疫 creep 减速。",
    "--   ★ 注意这个检查在 triggerscreep 之后、enable 之外 ——",
    "--     属于「个体免疫」层，与全局开关层正交。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+20": [
    "--★ 离开 creep 的边沿事件 walkoffcreep —— 与 616 配对。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+25": [
    "--★★【退出 creep 后：查三类「快地面」条件】",
    "--   三者任一成立就用 fastmultiplier，否则 1：",
    "--     ① IsFasterOnGroundTile(当前地块) —— turf（绿蕈地等）",
    "--     ② FasterOnRoad() 且（在道路上 或 地块本身是道路）—— 人工道路",
    "--     ③ oncreep 且 FasterOnCreep() —— 可配置在 creep 上加速的实体",
    "--   ★★ 为什么 ② 要查两个条件（RoadManager:IsOnRoad 或 GROUND_ROADWAYS[tile]）？",
    "--     RoadManager 是道路系统的运行时查询（瓦片级数据），",
    "--     GROUND_ROADWAYS 是静态表（tilemanager.lua:175 填充的道路地块）。",
    "--     两者覆盖不同来源的道路，且 RoadManager 本身可能是 nil（非道路世界）。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+26": [
    "--★★ 三条件用 or 串联在同一个 and 表达式里 —— 整个表达式为真才加速。",
    "--   ★ 严格用 `== true` 的是 245 行；这里 IsFasterOnGroundTile 已返回布尔。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+27": [
    "--★★【`RoadManager ~= nil and RoadManager:IsOnRoad(...) or GROUND_ROADWAYS[tile]`】",
    "--   ⚠⚠ 这里的 and/or 链式三元有个**经典陷阱**：",
    "--     若 RoadManager 存在但 IsOnRoad 返回 **false**，",
    "--     表达式会继续评估 `GROUND_ROADWAYS[tile]` —— 这恰好是想要的（fallback）。",
    "--     但若 RoadManager 存在、IsOnRoad 返回 false、且 GROUND_ROADWAYS[tile] 为 nil，",
    "--     整个子表达式为 nil（falsy）—— 结果正确。",
    "--   ★ 所以这里恰好是安全的，因为 fallback 是「或」关系。",
    "--     但它**不是**「RoadManager 缺失时用静态表」这么简单：",
    "--     两者是逻辑或，不是有优先级的 fallback。",
  ],
  "LocoMotor:UpdateGroundSpeedMultiplier#1+29": [
    "--★ 加速倍率（1.3），否则 1。整行是一个 and-or 表达式。",
  ],
};

export const AFTER = {};
