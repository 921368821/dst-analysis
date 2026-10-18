// spec-locomotor-p3.mjs —— locomotor.lua 深度注释规格 第 3 部分
// 覆盖：临时地面倍率 → 斜向 → 动作路由（PreviewAction / PushAction）
//       → GoToEntity / GoToPoint
// 锚点范围：638 ~ 1080

export const BEFORE = {
  // ══════════════════════════════════════════════════════════════
  // 八、临时地面速度修正（2 帧窗口的瞬时效果）
  // ══════════════════════════════════════════════════════════════
  638: [
    "--★★★【PushTempGroundSpeedMultiplier：临时地面加速】",
    "--   用于「踩到某物短暂加速」类效果。三个特征：",
    "--     ① 只取**最小**的 mult（647 行 `mult <= self.tempgroundspeedmultiplier`），",
    "--        即多个来源同时推时，**减速优先**（取更保守的值）",
    "--     ② 有 modifierfn 钩子（640 行），供模组改写",
    "--     ③ 有效期只有 0.034 秒（见 657 行）",
    "--   ★★ 语义：这个函数是「每帧被调用」的（由具体 prefab 在 OnUpdate 里调），",
    "--     所以效果靠「持续推」维持；一旦停止推，0.034 秒后自动失效。",
    "--   ★ 这就是「无状态计时」的技巧：不存到期时刻，只存「最后一次推的时间」，",
    "--     读取时比较 now - lasttime < 窗口。不需要定时器就能实现 TTL。",
  ],
  645: [
    "--★★★【取最小值的规则 —— 整段最反直觉的一行】",
    "--   `if tempgroundspeedmultiplier == nil or t > tempgroundspeedmulttime",
    "--    or mult <= self.tempgroundspeedmultiplier then`",
    "--   三个条件任一成立就接受新值：",
    "--     · 还没有临时值（首次）",
    "--     · 上次的值已过期（t > 旧时间戳）",
    "--     · 新值比旧值**更小**（mult <= 旧值）——即减速覆盖加速",
    "--   ★★ 设计意图：多个来源同时生效时，取最不利（最低）的那个。",
    "--     举例：踩到加速带（1.3）同时中了减速 debuff（0.5）→ 结果 0.5 而非 0.65。",
    "--   ★ 为什么是 min 而不是 max？因为「临时修正」多用于**惩罚性**效果",
    "--     （沼泽、火山灰），取 min 保证惩罚不被加速抵消。",
    "--   ⚠ 但这意味着「多个加速来源不叠加」——设计取舍，不是 bug。",
  ],
  651: [
    "--★ 刷新时间戳 —— 每次推都刷新，TTL 因此是「最后一次推后 0.034 秒」。",
  ],
  655: [
    "--★★★【TempGroundSpeedMultiplier：读取即判定过期（并顺手清理）】",
    "--   `if self.tempgroundspeedmulttime + 0.034 > GetTime() then return 值`",
    "--   ★★ 0.034 秒 ≈ 一帧（1/30 = 0.0333）。多出的 0.0007 是浮点余量。",
    "--   ★ 设计：过期时**顺手把三个字段都置 nil**（惰性清理）。",
    "--     不需要额外的清理任务，也不会有「残留的临时值突然复活」。",
    "--   ★★★ 这是一个很干净的 TTL 实现范式，值得复用。",
    "--   ⚠ 副作用：第一次读取若已过期，会把状态清掉，",
    "--     所以「读一次就没了」—— 若某个 prefab 只推一次就读多次，",
    "--     必须在同帧内读，否则效果丢失。",
  ],
  660: [
    "--★ 惰性清理：三个字段一起清，与 649 行的写入严格对称。",
  ],
  666: [
    "--★★【TempGroundTile：与 TempGroundSpeedMultiplier 同构】",
    "--   ⚠⚠ 疑似缺陷【重复清理代码】：",
    "--     666-675 行的函数体与 655-664 几乎完全相同，唯一区别是返回值。",
    "--     更要紧的是：TempGroundTile 里清理的字段**也是** tempgroundspeedmultiplier ——",
    "--     这本身是对的（两者同生命周期），但两份重复的清理逻辑意味着",
    "--     若将来要加第四个字段（如来源标记），很容易只改一处。",
    "--     这不是功能性 bug，是可维护性隐患。",
    "--   ★ 顺带说明 tempgroundtile 的用途：由 prefab 记录「临时加速来自哪块地」，",
    "--     用于播放对应的特效/音效。",
  ],
  677: [
    "--★★ 英文原注释强调：「Call for both client and server, make sure results are synced」",
    "--   ★ 这条约束很重要：modifierfn 若只在服务端调用，客户端算出的速度就不同，",
    "--     产生「本地看着正常，一到联机就卡顿」。",
    "--   ★★★ 这是本文件「双端同构」原则的又一体现：",
    "--     凡影响最终速度的逻辑，两端必须同时以相同输入执行。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 九、斜向移动（strafing）
  // ══════════════════════════════════════════════════════════════
  681: [
    "--★★【StartStrafing：进入斜向模式】",
    "--   ★★ 斜向移动的语义：「身体朝向 strafedir，但移动方向自由」。",
    "--     典型场景是端着盾走路时仍能自由转向。",
    "--   ⚠⚠ 疑似缺陷【直接解引用 player_classified】：",
    "--     `self.inst.player_classified.isstrafing:value()` 没有 nil 守卫。",
    "--     虽然 ismastersim 判了，但**服务端上的怪物也有 locomotor 组件**，",
    "--     而怪物没有 player_classified。",
    "--     推理依据：对比 67 行 onrunspeed 里严谨的",
    "--     `if self.inst.player_classified ~= nil` 守卫，",
    "--     以及 238 行 ServerIsFasterOnGroundTile 的 `== nil or` 写法，",
    "--     本函数与 StopStrafing（689 行）都缺了这个守卫。",
    "--     实际未崩的原因是：只有玩家会调用 StartStrafing/StopStrafing",
    "--     （由 playercontroller 调用），而玩家必有 player_classified。",
    "--     ★ 所以这是「靠调用方约束存活」而非「靠自身守卫存活」的隐式契约 ——",
    "--       强类型移植或模组误调用时会立刻暴露为崩溃。",
  ],
  682: [
    "--★ 双重守卫：服务端 且 当前未在斜向（避免重复派发事件）。",
  ],
  685: [
    "--★ startstrafing 事件供状态图切到「持盾行走」等对应状态。",
  ],
  697: [
    "--★★★【SetStrafing：斜向模式的开关与初始化】",
    "--   ★ 关键：进入斜向时记录「当前朝向」为 strafedir，",
    "--     之后身体朝向就不再被移动方向改写。",
    "--   退出时置 nil —— 回到「朝向 = 移动方向」的普通模式。",
  ],
  701: [
    "--★ strafedir 初始化为当前旋转角（Transform:GetRotation 返回弧度制角度）。",
  ],
  705: [
    "--★★【SetMoveDir：移动方向设置 —— 斜向模式的核心分叉】",
    "--   斜向中 → 改的是 strafedir（朝向），**不动实际移动方向**",
    "--   非斜向 → 改 Transform 旋转（身体朝向 = 移动方向）",
    "--   ★★★ 关键理解：斜向模式下，移动方向由 Physics 的 motor velocity 决定，",
    "--     身体朝向由 strafedir 决定，两者解耦。",
    "--   ★ 这就是斜向的完整实现：SetMotorSpeed（726 行）负责解耦移动，",
    "--     SetMoveDir 负责解耦朝向。",
  ],
  713: [
    "--★★【FaceMovePoint：转向到某点 —— 斜向下的特殊处理】",
    "--   斜向中 → 不动 Transform，只改 strafedir",
    "--   非斜向 → 调 inst:FacePoint（引擎侧转向）",
    "--   ★★ 「busy」状态标签检查：正在做动作（如攻击）时不转向，",
    "--     避免「攻击时身体乱转」。",
    "--   ⚠ 注意 716 行的条件是 `not (sg and sg:HasStateTag(\"busy\"))`，",
    "--     而 1610 行的同类检查用的是 `not (sg and HasStateTag(\"busy\"))` + canrotate。",
    "--     两处的 busy 语义一致，但 canrotate 检查位置不同（这里没有 canrotate）。",
  ],
  721: [
    "--★★★【SetMotorVelRelToStrafeDir：把「沿移动方向」转成「沿世界坐标」】",
    "--   `angle = (strafedir - dir) * DEGREES`",
    "--   `Physics:SetMotorVel(speed * cos(angle), 0, -speed * sin(angle))`",
    "--   ★★ 数学：把速度向量在「朝向坐标系」下分解为 (cos, sin) 分量，",
    "--     再转成世界 XZ 坐标。DST 的约定是 +X 为 0°、顺时针为正（因此有负号）。",
    "--   ★★★ 关键洞察【两层速度模型的真相】：",
    "--     · locomotor.lua 里**只有水平速度**（Y 分量恒为 0，见 723/730 行）",
    "--     · 垂直方向（跳跃、下落、斜坡）完全由 **C++ 侧物理**处理",
    "--       （Physics 组件的重力与碰撞），见 physics.lua",
    "--     · 「两层速度模型」的分层是「Lua 水平层 + C++ 垂直层」，",
    "--       不是 Lua 内部的两层",
    "--   ★ 所以本文件没有 verticalVelocity 字段——这是刻意的架构划分，",
    "--     不是遗漏。跳跃由 stategraph 的 jumping 状态触发（见 commonstates.lua:797），",
    "--     物理由引擎接管。",
  ],
  726: [
    "--★★【SetMotorSpeed：速度设置的双路径】",
    "--   斜向 → SetMotorVelRelToStrafeDir（解耦）",
    "--   非斜向 → 直接 SetMotorVel(speed, 0, 0)（motor 朝自身前方）",
    "--   ★ 非斜向时只给 X 分量，物理引擎会按当前 Transform 旋转方向推进。",
  ],
  734: [
    "--★★【OnStrafeFacingChanged：斜向中朝向被外部改变时的补偿】",
    "--   ★★ 场景：斜向模式里，状态图或其他代码改了实体旋转（如受击转向）。",
    "--     若不补偿，motor velocity 就与新朝向脱节（会横着走）。",
    "--   解法：用新的 dir 重算 motor velocity。",
    "--   ★ 这是一个「外部状态变更 → 重算派生状态」的标准钩子。",
  ],
  741: [
    "--★★【WalkForward / RunForward：最基础的移动原语】",
    "--   结构完全相同，只差 isrunning 标志与速度来源。",
    "--   ★★ 三个动作：设姿态 → 设 motor 速度 → 启动每帧更新。",
    "--     第三个动作最容易被忘 —— 漏了它就不会转向、不会到达、不会跳跃。",
    "--   ★ direct 参数：\"直接前进\"模式。",
    "--     设为 true 时记 wantstomoveforward，供 OnUpdate 决策是否继续 locomote。",
  ],
  748: [
    "--★ RunForward：唯一区别是 isrunning=true 与 GetRunSpeed()。",
  ],
  755: [
    "--★★★【Clear：只清「意图」，不动物理】",
    "--   清理项：目标、到达回调、前进意图、跑意图、缓冲动作。",
    "--   ★★ 注意它**不清** wantstomoveforward 之外的东西，也不调 Physics:Stop()",
    "--     —— 因为 Clear 可能在「立即要设新目标」的场景被调用（792/905 行），",
    "--     此刻停止物理会造成一帧的顿挫。真正的停止是 Stop()（1091 行）。",
    "--   ★ 与 ResetPath 的区别：Clear 不碰路径，ResetPath 专门清路径。",
    "--     782 行的 Clear 里注释掉的 `self:ResetPath()` 说明曾考虑过合并。",
  ],
  761: [
    "--★ SetBufferedAction(nil) 会**Fail 掉旧动作**（见 1079 行）——",
    "--   换目标时旧动作必须被显式作废，否则会留下「悬挂的缓冲动作」。",
  ],
  765: [
    "--★★【ResetPath：清路径 + 杀搜索】",
    "--   顺序：先 KillPathSearch（杀掉挂起的 C++ 搜索），再清 path。",
    "--   ★★ 顺序重要：先杀再清，才能保证不会残留一个「句柄已失效但 Lua 仍持有」的 path。",
  ],
  771: [
    "--★ KillPathSearch 用 WaitingForPathSearch() 做守卫（防重复杀）。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 十、动作路由：PreviewAction（客户端预览）vs PushAction（服务端执行）
  // ══════════════════════════════════════════════════════════════
  778: [
    "--★ SetReachDestinationCallback：设置「到达目的地时执行」的回调（atdestfn）。",
    "--   ★ 与 bufferedaction 的区别：atdestfn 是**纯通知**，不携带动作。",
  ],
  782: [    "--★★★【PreviewAction —— 客户端「预测」版的动作路由】",
    "--   ★★★ 与 PushAction（882 行）是**同一套逻辑的两个平行实现**：",
    "--     · PreviewAction 在客户端跑（本地预测，喂给 PreviewBufferedAction）",
    "--     · PushAction 在服务端跑（权威，喂给 PushBufferedAction）",
    "--   ★ 两者结构逐条对应，但**不是简单镜像**——有几处刻意的不对称（见下）。",
    "--   ★★ 这种「双份路由表」是 DST 的固有代价：",
    "--     客户端要立即给玩家视觉反馈，服务端要保证权威正确。",
    "--     ⚠ 维护风险极高：加一种新动作类型时**必须同时改两个函数**，",
    "--       漏改会导致「本地看起来会去，联机上却不走过去」。",
    "--   ---- 决策顺序（两者一致）----",
    "--   ① WALKTO（显式走过去的动作）",
    "--   ② LOOKAT（注视/查看）",
    "--   ③ forced（强制动作，如开门）",
    "--   ④ instant / do_not_locomote（瞬时或不需要走过去）",
    "--   ⑤ 有 target → GoToEntity",
    "--   ⑥ 无 action_pos → 直接执行",
    "--   ⑦ CASTAOE → 范围技能（AOE 施法）",
    "--   ⑧ 无穷远距离 → 视为瞬时",
    "--   ⑨ 兜底 → GoToPoint",
  ],
  787: [
    "--★ pre_action_cb：动作的前置钩子（修改动作参数，如距离、方向）。",
    "--   ★ 在 Clear 之前调用 —— 前置钩子失败时原移动意图还未被破坏。",
  ],
  791: [
    "--★★ throttle 重置为 1：每次发起新动作都恢复全速。",
    "--   ★ 与 RunInDirection:1144 的部分节流相对。",
  ],
  795: [
    "--★ WALKTO 动作：显式「走到某处」。分 target / action_pos 两种。",
  ],
  801: [
    "--★★★【LOOKAT 分支 —— 客户端版比服务端版多了三个条件】",
    "--   条件：有 playercontroller 且**不是** directwalking（直走模式）。",
    "--   ★ directwalking 是「玩家用 WASD 直走而非点击移动」的模式，",
    "--     此时 LOOKAT 不该触发自动走过去。",
    "--   ★★ 客户端独有的 overridelocomote 检查（805 行）：",
    "--     若状态图有 overridelocomote 标签，说明「移动由状态图接管」，",
    "--     此时只做预览，不发移动指令。",
    "--   ⚠ 服务端版（915 行）**没有** overridelocomote 检查 —— 刻意的差异，",
    "--     因为服务端不需要「预览」，且状态图已在服务端做出决策。",
  ],
  805: [
    "--★ overridelocomote 标签：状态图说「我自己管移动」。见 OnUpdate:1631 的对应处理。",
  ],
  810: [
    "--★ CanCloseInspect：能否「走近看」（如物品详情）。能则走过去看，不能就原地预览。",
    "--   ★ 定义在 componentutil.lua:657 的 CLOSEINSPECTORUTIL。",
  ],
  823: [
    "--★★★【V2C 注释解释了一个 workaround】",
    "--   \"since LOOKAT now has an action handler for closeinspect support, we can use",
    "--   options.instant to bypass it during preview. see EntityScript:PreviewBufferedAction\"",
    "--   ★ 背景：LOOKAT 加了「走近查看」支持后，预览时会真的走过去；",
    "--     所以预览路径必须用 options.instant 强制绕过。",
    "--   ★★ 这是「特性新增后回补旧路径」的典型痕迹，也提示：",
    "--     options.instant 是一个**递归传染的标志** —— 设了它，下游又会去改它。",
  ],
  831: [
    "--★ 若不在 idle 状态则强制播 idle 动画 —— 避免「走着走着卡在走路动画」。",
  ],
  832: [
    "--★ 幽灵（playerghost）用 idle 而非 idle_loop —— 幽灵没有循环待机动画。",
  ],
  838: [
    "--★ 强制进 idle 状态并加 noanim 参数（避免重复播动画）。",
  ],
  841: [
    "--★ forced 分支：强制动作（如开门）—— 若有 action_pos 就走过去。",
  ],
  845: [
    "--★★★【instant / do_not_locomote / options.instant 三条件并联】",
    "--   三者任一成立 → 直接执行，不移动。",
    "--   ★ options.instant 由 826 行设置（预览路径强制置位）。",
    "--   ★★ 注意这条分支在客户端版和**服务端版的位置相同**（946 行），",
    "--     所以「预览时瞬时执行」与「真正执行时瞬时执行」保持一致。",
  ],
  847: [
    "--★ 有目标 → 走过去执行。",
  ],
  848: [
    "--★★★【客户端用 replica.inventoryitem 判断「物品是否被持有」】",
    "--   `bufferedaction.target.replica.inventoryitem:IsHeld()`",
    "--   ★ 服务端版（949 行）用 components.inventoryitem.owner —— 路径不同，语义相同。",
  ],
  850: [
    "--★★【pocketdimension_container 特殊处理：不能走到 (0,0,0)】",
    "--   ★★★ 这是「手套」类道具的特殊情况：",
    "--     它挂着一个 pocketdimension（次级维度容器），其坐标在次级空间里。",
    "--     如果按常规走过去，目标坐标是次级空间的原点，实体真的会跑过去。",
    "--     所以改为「只转向 + 直接执行」。",
    "--   ★ 这类「坐标系不统一」的特例，是本文件里最「脏」也最必要的分支。",
  ],
  854: [
    "--★ 距离为无穷大 → 视为瞬时（只转向不移动）。",
  ],
  861: [
    "--★ 无 action_pos → 无处可去 → 直接执行。",
  ],
  863: [
    "--★★【CASTAOE：范围施法动作的距离判定】",
    "--   `GetDistanceSqToPoint(action_pos) <= distance^2` ——",
    "--   ★ 用**距离平方**比较，避免开方（性能 + 精度）。",
    "--   在范围内 → 转向 + 立即执行；不在 → 走过去。",
    "--   ★ 这是 AOE 技能的标准处理：站进范围就能放，不必精确走到点。",
  ],
  869: [
    "--★ bufferedcastaoe 事件：告诉上层「正在走向 AOE 施法点」。",
    "--   ★★ 守卫 `if self.bufferedaction == bufferedaction` 是必要的：",
    "--     GoToPoint 可能立即失败并换掉 bufferedaction，此时不该派发。",
  ],
  882: [
    "--★★★★★【PushAction —— 服务端权威版的动作路由】",
    "--   ★ 结构与 PreviewAction 平行，但有四处**实质差异**：",
    "--     ① 先调 TestForStart()，失败则派发 actionfailed 并返回（899 行）",
    "--        —— 客户端预览不做这个检查（因为还没真正开始）",
    "--     ② LOOKAT 分支条件不同（没有 directwalking 判断，改为用",
    "--        GetRemotePredictPositionExternal 取远端预测位置）",
    "--     ③ forced 分支多了 rangecheckfn 检查（938 行）",
    "--     ④ 调 PushBufferedAction 而非 PreviewBufferedAction",
    "--   ★★ 差异 ② 的意义：服务端处理的是**客户端上报的意图**，",
    "--     所以要相信客户端给的「远程预测位置」作为目的地。",
    "--   ⚠ 维护提示：加新动作类型时必须 PreviewAction + PushAction 同改。",
  ],
  885: [
    "--★ playercontroller:OnRemoteBufferedAction —— 告诉控制器「收到远端动作请求」。",
  ],
  889: [
    "--★★★【no_predict_fastforward 的传染标记】",
    "--   `if self.no_predict_fastforward then bufferedaction.options.no_predict_fastforward = true`",
    "--   ★★★ 把组件级标志复制到**动作的 options 表**上，",
    "--     让下游（EntityScript:PerformBufferedAction）也能看到这个意图。",
    "--   ★ 来源：PlayerController:RepeatHeldAction() —— 玩家按住右键重复动作时，",
    "--     不允许客户端预测快进（否则会连发）。",
  ],
  899: [
    "--★★★【TestForStart：执行前的合法性检查】",
    "--   ★★ 为什么要在这里检查而不在动作真正执行时？",
    "--     因为「走过去」可能耗时很久，目标可能在此期间失效。",
    "--     先检查一次可以提前失败，不必白走一趟。",
    "--   ★ actionfailed 事件携带 reason，供 UI 提示玩家为什么没反应。",
  ],
  901: [
    "--★ actionfailed 事件：UI 层（widgets/controls.lua）监听它显示失败提示。",
  ],
  915: [
    "--★ LOOKAT 分支（服务端版）：条件更宽松（只要有 playercontroller）。",
    "--   ★★ 关键差异：931 行用 `pos and not directwalking` ——",
    "--     远端预测位置存在且非直走模式 → 走过去；否则直接执行。",
  ],
  930: [
    "--★★★【GetRemotePredictPositionExternal：客户端上报的预测位置】",
    "--   ★ 这是「客户端预测」的服务端消费点：",
    "--     玩家点击地面 → 客户端本地立刻走过去（预测）→",
    "--     同时把「我预计要去哪」发给服务器 →",
    "--     服务端用这个位置作为 GoToPoint 的目标，",
    "--     从而让服务端的移动与客户端视觉一致。",
    "--   ★ 若这个值为 nil（客户端没上报或直走模式），则退化为「不移动」。",
    "--   ⚠ 安全考量：这是客户端可控的数据。若直接信任，",
    "--     恶意客户端可以声称「我要走到世界尽头」来让角色跑飞。",
    "--     ★ 实际约束：GoToPoint 走的是正常寻路（1817 行 FindPath），",
    "--     目标不可达时寻路器会失败，实体不会真的跑到非法位置。",
  ],
  938: [
    "--★★【rangecheckfn：强制动作的距离复核】",
    "--   ★ forced 分支（开门、挖掘等）里，先复核目标是否还在合法范围。",
    "--   不在范围内 → 丢弃 target 与 initialtargetowner（相当于放弃这次尝试）。",
    "--   ★★ 为什么客户端版没有这个检查？因为客户端是预览，",
    "--     真正执行前服务端还会重新检查一次。",
  ],
  944: [
    "--★ overridedest：额外的目的地覆盖（供网络控制器支持，见 1039 行注释）。",
  ],
  949: [
    "--★ 服务端版用 components.inventoryitem 判断持有 —— 与 848 行客户端版对称。",
  ],
  954: [
    "--★ 与 854 行完全对称的「无穷远即瞬时」分支。",
  ],
  955: [
    "--★ 客户端「无穷远即瞬时」用 Preview，服务端（954 行）用 Push ——",
    "--   除执行端不同外，两分支的判定顺序与客户端版（841-879）完全一致。",
  ],
  959: [
    "--★★ 最后一个「走过去执行」的分支 —— 服务端版的兜底 GoToEntity。",
    "--   ★ 三个 GoToEntity 调用点：919（LOOKAT 走近看）、921、959（常规）。",
  ],
  961: [
    "--★ 无 action_pos 且无 target → 目标「不可达」，直接执行（等价于原地执行）。",
    "--   ★ 与客户端版 861 行完全对称。",
  ],
  963: [
    "--★ CASTAOE 分支：与客户端版 863 行对称，但执行端为 Push。",
  ],
  964: [
    "--★★ 距离平方比较（AOE 范围判定）与客户端版逐字符相同 ——",
    "--   再次印证「判定逻辑必须两端一致」这条铁律。",
  ],
  968: [
    "--★ 服务端版同样在「走向 AOE 施法点」时派发 bufferedcastaoe 事件。",
  ],
  973: [
    "--★ 与 845/846 行的 instant 判定对称的「无穷远即瞬时」。",
  ],
  977: [
    "--★★ PushAction 的最终兜底：GoToPoint。",
    "--   ★ 走到这里意味着：动作既不是瞬时、又没有实体目标、",
    "--     但有 action_pos —— 只能走向那个坐标点。",
  ],

  // ══════════════════════════════════════════════════════════════
  // 十一、GoToEntity / GoToPoint —— 移动指令的核心入口
  // ══════════════════════════════════════════════════════════════
  982: [
    "--★★★★★【GoToEntity：走向一个实体】",
    "--   这是 locomotor 最重要的公开入口。调用方遍布：",
    "--   brain（AI 决策）、stategraph（状态迁移）、",
    "--   playercontroller（玩家点击）、componentactions（各种动作）。",
    "--   ---- 完整流程 ----",
    "--   ① 建 Dest、设 throttle、取消客户端预测计时",
    "--   ② 设置缓冲动作与前进意图",
    "--   ③ **计算 arrive_dist（三分支，见下）**",
    "--   ④ directdrive ? 直推 : FindPath 寻路",
    "--   ⑤ 启动每帧更新",
    "--   ⑥ 若不在 moving 状态，立刻做一次到达检查（见 1034 行）",
  ],
  986: [
    "--★ 取消客户端预测计时：走到这里说明是服务端路径（或客户端没在预测）。",
  ],
  991: [
    "--★★★【arrive_dist 的三分支 —— 「走多近算到达」的决定性逻辑】",
    "--   分支 1：bufferedaction.arrivedist 显式指定 → 直接用（最优先）",
    "--   分支 2：有 bufferedaction.distance →",
    "--     ARRIVE_STEP + 双方物理半径，再与 distance 取 max",
    "--   分支 3：都没有 →",
    "--     ARRIVE_STEP + 双方物理半径(0)，再叠加 action.extra_arrive_dist 与 mindistance",
    "--   ★★★ 为什么半径之和是必需的？",
    "--     因为「到达」的判定是**中心点距离**（1469 行的 distsq），",
    "--     两实体各有半径 r1、r2 时，边缘刚好接触对应中心距 r1+r2。",
    "--     不加半径就会「贴脸才算到达」，玩家会觉得「明明碰到了却还在走」。",
    "--   ★ 分支 2 的 `math.max` 是防御：若 distance 比半径和小（近距离动作），",
    "--     取半径和作为下限，保证「至少不撞上」。",
  ],
  997: [
    "--★★★【英文原注释解释了一个历史包袱】",
    "--   \"use actual physics (ignoring physicsradiusoverride) as fallback",
    "--    if bufferedaction.distance is too small\"",
    "--   ★ 物理半径有两种：实际的（Physics:GetRadius）与覆写的",
    "--     （physicsradiusoverride，某些 prefab 为视觉放大而缩小碰撞体）。",
    "--     这里**故意用实际的**，作为 distance 太小时的兜底。",
    "--   ★ 这行注释的价值：说明「用哪个半径」是深思熟虑的结果，不是随手写的。",
  ],
  1000: [
    "--★ GetGrandOwner：物品在被背包里时要算「最外层主人」（如船上的箱子里的物品）。",
  ],
  1005: [
    "--★ GetPhysicsRadius(0) 带参数 0 —— 见 entityscript.lua 的实现，",
    "--   参数用于指定「取哪个实体的半径」（0 = 自己）。",
  ],
  1007: [
    "--★★【extra_arrive_dist 钩子：让动作自定义「额外接近距离」】",
    "--   典型用途：长柄武器需要更靠近（挥击范围），钩爪需要更远。",
    "--   ★ 是函数调用形式，允许按参数动态计算。",
  ],
  1012: [
    "--★ mindistance：动作的「最小接近距离」下限，防止某些动作贴太近反而失败。",
  ],
  1019: [
    "--★★【directdrive：绕过寻路的直推模式】",
    "--   ★ 用于「直走」场景（如玩家 WASD 移动、脚本驱动的直线移动）。",
    "--     直推不寻路，直接给 motor 速度，靠物理碰撞自然阻挡。",
    "--   ★ 与 FindPath 的对比：直推简单但会被墙卡住，寻路能绕。",
  ],
  1029: [
    "--★ wantstorun 在寻路**之后**才设 —— 顺序微妙：FindPath 不关心跑/走。",
  ],
  1031: [
    "--★ StartUpdatingInternal：没有它就不会有转向、到达判定、跳跃。",
  ],
  1033: [
    "--★★★【★ 立即到达检查：解决「原地已到位却还在走」的经典问题】",
    "--   `if not (self.inst.sg and self.inst.sg:HasStateTag(\"moving\")) then self:OnUpdate(0, true)`",
    "--   ★★ 问题场景：玩家在原地点击一个就在脚下的物品 ——",
    "--     GoToEntity 启动更新后，要等**下一帧** OnUpdate 才会做到达判定，",
    "--     期间实体已经开始移动 → 玩家看到「点了一下却先跑开再回来」。",
    "--   ★ 解法：立刻调一次 OnUpdate(0, true)，用 dt=0 且 arrive_check_only=true",
    "--     只做到达判定、不做移动决策。",
    "--   ★★★ `arrive_check_only` 这个第二参数是本文件的一个小设计亮点：",
    "--     让「检查到达」与「执行移动」可以在同一段代码里复用而不混淆副作用。",
  ],
  1035: [
    "--★ OnUpdate(0, true)：dt=0 保证不做移动积分，arrive_check_only 保证不改状态。",
  ],
  1040: [
    "--★★★【GoToPoint：走向一个坐标点】",
    "--   结构与 GoToEntity 平行，差异只有 arrive_dist 的计算（更简单）：",
    "--     有 bufferedaction → arrivedist or distance or max(mindistance, ARRIVE_STEP)",
    "--     无 bufferedaction → ARRIVE_STEP",
    "--   ★★ 少了两步：不用算双方物理半径（点没有半径）、",
    "--     不用 GetGrandOwner。",
  ],
  1041: [
    "--★ overridedest：允许「真正目的地是另一个实体，但立即触发点是坐标」。",
    "--   ★ 用途：点击物品的某个部位时，pt 是点击点，overridedest 是那个实体。",
  ],
  1046: [
    "--★ arrive_dist 的 or 链：`arrivedist or distance or max(mindistance, ARRIVE_STEP)`",
    "--   ★ 优先级：显式 arrivedist > 动作距离 > 动作最小距离 > 基准步长。",
  ],
  1051: [
    "--★ extra_arrive_dist 同样适用（1053 行调用时只传 3 个参数，与 1009 行不同）。",
    "--   ⚠ 注意签名差异：1009 行传 4 个参数（含 arrive_dist），1053 行传 3 个。",
    "--     模组实现 extra_arrive_dist 时需容忍参数个数变化。",
  ],
  1059: [
    "--★ directdrive 分支与 GoToEntity 相同。",
  ],
  1068: [
    "--★ 注意这里 wantstomoveforward 设**在** FindPath 之后（与 GoToEntity 的 1029 行对称）。",
  ],
  1073: [
    "--★ 同样的「立即到达检查」—— 1033 行的机制在此复用。",
  ],
};

export const AFTER = {};
