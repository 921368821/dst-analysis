// spec-playercontroller-p8.mjs —— 第 8 段：4200-4700 行
// 覆盖：DoDoubleTapDir 收尾与 RPC 对端、DoDirectWalking（★ 松手护栏）、
//       DoDirectStopWalking、DoCameraControl、OnLeftUp、★ DoAction（所有按钮的汇合点）、
//       DoActionAutoEquip

export const BEFORE = {
  "PlayerController:OnRemoteDoubleTapAction#1+22": [
    "--============================================================",
    "-- 【第八段】4300-4700 行：双击 RPC 对端 / ★ DoDirectWalking / 相机 /",
    "--   OnLeftUp / ★★ DoAction（所有按钮的汇合点）",
    "--============================================================",
  ],

  "PlayerController:OnRemoteDoubleTapAction#1": [
    "--【OnRemoteDoubleTapAction(actioncode, position, noforce, mod_name)】",
    "--   ★ 与其他按钮不同：本函数**不查 mod 表**（4278 行的 actioncode 直接进",
    "--     GetDoubleClickActions），靠 4286-4289 行的 code 匹配校验。",
    "--   ⇒ 服务端在**同一位置**重算，若算出的动作 code 不符 → 丢弃。",
    "--   ⚠ 4283 行 `GetDoubleClickActions(position)` 只传了 position，",
    "--     漏掉了 dir 与 target —— 与客户端 4239 行的 `(nil, dir, nil)` 不对称。",
    "--     推理依据：4239 行传 (nil, dir, nil)；4283 行传 (position)。",
    "--     影响：若某动作依赖 dir 或 target（如「朝某方向跳」），服务端算不出来。",
  ],

  "PlayerController:OnRemoteDoubleTapAction#1+16": [
    "--   4294-4296 行：force 时对齐到客户端预测位置（同 975/2334 行的范式）。",
  ],

  "PlayerController:DoDirectWalking#1": [
    "--★★★ 【DoDirectWalking】★★ 直接行走（手柄摇杆 / 远端玩家的方向键）。",
    "--   110 行，是三种移动手势里最复杂的一个 —— 因为它要处理「松开摇杆时不打断动作」。",
    "--   结构：",
    "--     ① 4307 跳跃中 → 立即返回",
    "--     ② 4309-4343 ★ 松手护栏（recent_bufferedaction）的维护",
    "--     ③ 4344-4414 三分支：护栏生效 / 摇杆有值 / 预测行走中 / 正在走",
    "--   ★ 由 3062 行调用（仅在完全空闲时）。",
  ],

  "PlayerController:DoDirectWalking#1+1": [
    "--   ★ 跳跃中不接受直接行走（与 DoPredictWalking:4005、DoDragWalking:4127 同构）。",
  ],

  "PlayerController:DoDirectWalking#1+3": [
    "--★ 4309-4313 行的三重「不能移动」条件：",
    "--     ① 无 locomotor 或不能预测（CanLocomote）",
    "--     ② controller_attack_override 非 nil（手柄持续攻击中）",
    "--     ③ 状态图在 attack 中且扳机按着",
    "--   ⇒ 这三条保证「战斗中的方向键」不触发行走。",
  ],

  "PlayerController:DoDirectWalking#1+13": [
    "--★★★ 【4319-4343：★ 松手护栏（recent_bufferedaction）】本文件最精细的手感逻辑。",
    "--   --Prevent cancelling actions when letting go of direct walking controls late",
    "--   ★ 问题场景：",
    "--     ① 玩家按住摇杆走向某处",
    "--     ② 在快到时松开摇杆，**同一帧**点了「砍树」",
    "--     ③ 摇杆松开导致 DoDirectWalking 进入「摇杆无值」分支（4389 行），",
    "--        它会 locomotor:Stop() —— 而 Stop 会**连带清掉刚缓冲的砍树动作**。",
    "--   ⇒ 护栏的作用：在「摇杆方向与按下动作时的方向一致」且「时间窗未过」时，",
    "--     跳过 Stop，直接进入 4407 行的「重启缓冲动作」。",
    "--   ★★ 这是玩家感知不到但确实存在的一段「保护期」。",
  ],

  "PlayerController:DoDirectWalking#1+15": [
    "--★★ 4321-4324 行的三重判定：",
    "--     ① recent_bufferedaction.act 非 nil（有刚缓冲的动作）",
    "--     ② recent_bufferedaction.t > dt（★ 保护时间还没耗尽）",
    "--     ③ act 与实体当前的 bufferedaction 是**同一个对象**",
    "--   ⇒ ② 的时间来自 5903 行：BUFFERED_ACTION_NO_CANCEL_TIME（1 帧）",
    "--     或 BUFFERED_CASTAOE_TIME（0.5 秒，法术）。",
    "--   ⚠ 4323 行的 `self.recent_bufferedaction.t > dt` 是**相对时间比较**：",
    "--     t 在 OnLocomotorBufferedAction 设置为常量，此后每帧减 dt（4337 行）。",
    "--     所以判定是「剩余时间 > 一帧」—— 若刚好剩一帧就失效。",
    "--     这意味着保护窗口实际是 (常量 - 1帧)，对 1 帧的常量就是 0。",
    "--     ⚠ 疑似缺陷（常量自相消）：BUFFERED_ACTION_NO_CANCEL_TIME = FRAMES + .0001，",
    "--       4323 行在设置后的**第一帧**比较时 t 仍是 FRAMES+.0001 > dt(≈FRAMES) 成立，",
    "--       成立一帧后 t ≈ .0001 < dt 就不成立。",
    "--     推理依据：4323 行比较 t > dt；4337 行 t = t - dt；",
    "--       5903 行 t = FRAMES + .0001。⇒ 恰好一帧的有效窗口。",
    "--     这个「一帧窗口」正是 6 行注释里 \"prevent instant cancelling\" 的本意。",
  ],

  "PlayerController:DoDirectWalking#1+20": [
    "--   ★★ 4326-4334 行的两个方向比较：",
    "--     精确相等（远端玩家：x/z 就是原始数值）",
    "--     或角度差 ≤ 89°（4328 行 `self.isclientcontrollerattached` —— 注释说",
    "--       \"works for local player as well\"）",
    "--   ⇒ 89° 而非 90°：留 1° 的余量，避免浮点/量化误差导致误判。",
    "--     这与 4039 行的 >= 90 形成对比（那边没有余量）。",
  ],

  "PlayerController:DoDirectWalking#1+30": [
    "--   护栏生效 → 递减保护时间但**不**清标志。",
  ],

  "PlayerController:DoDirectWalking#1+32": [
    "--   护栏失效 → 立刻作废（4389 行的常规停止逻辑接管）。",
  ],

  "PlayerController:DoDirectWalking#1+38": [
    "--   ★★ 4344-4350 行：护栏**仍然生效**时的处理 ——",
    "--     清三个手势标志（因为摇杆确实松了）但**保留** act；",
    "--     4349 行 CooldownRemoteController()（无参 = 清零所有按键状态）。",
    "--   ⇒ 关键：这里没有 locomotor:Stop()，所以缓冲动作存活。",
  ],

  "PlayerController:DoDirectWalking#1+45": [
    "--★ 4351-4381 行：摇杆有值的正常行走。",
    "--   4352 行 ClearBufferedAction：★ 有新输入 → 旧动作作废（覆盖护栏）。",
    "--   ★ 4358-4360 行：",
    "--     · 4359 行 SetBufferedAction(nil) —— 先清 locomotor 里的动作",
    "--     · 4360 行 RunInDirection(-atan2(dir.z, dir.x)/DEGREES) —— ★ 负号 + DEGREES",
    "--       注意方向：dir 是**屏幕**方向（GetWorldControllerVector 归一化后的），",
    "--       而 RunInDirection 要的是角度，-atan2(z,x) 得到「屏幕右下 = 负角」。",
    "--   ⚠ 4360 行与 4034 行的 atan2 **符号相反**：",
    "--     4034 行 `atan2(z0 - pt.z, pt.x - x0)` 是「指向目标」；",
    "--     4360 行 `-atan2(dir.z, dir.x)` 是「摇杆方向」。",
    "--     两者在不同上下文使用，不冲突，但对照阅读容易困惑。",
  ],

  "PlayerController:DoDirectWalking#1+57": [
    "--   ★ time_direct_walking 计时：首次进入为 dt，之后累加。",
    "--   ★★ 4364-4366 行的意义：「刚松开后立刻按住」不重置计时 ——",
    "--     保证 0.2 秒的「脱战延迟」不会被快速点按绕过。",
  ],

  "PlayerController:DoDirectWalking#1+66": [
    "--★★ 4372-4381 行：**本机客户端 vs 服务端**的镜像分派。",
    "--   4374 行：无 locomotor 的客户端 → RemoteDirectWalking（发方向 RPC）。",
    "--   4376-4381 行：服务端 → CancelPredictMoveTimer（4377 行注释：",
    "--     \"remote direct walking, means client is not predicting\"）",
    "--     + 4378 行的脱战逻辑。",
    "--   ⚠★ 与 4152-4153 行对比：拖拽的注释说「客户端没有预测」，",
    "--     而直接行走**有**预测（客户端自己的 locomotor 在跑）。",
    "--     两者的服务端处理因此不同：拖拽只取消计时器，",
    "--       直接行走还要执行脱战。",
  ],

  "PlayerController:DoDirectWalking#1+76": [
    "--★ 4382-4388 行：客户端在预测行走、但本函数被调到了（预测刚停）。",
    "--   4383 行 `if locomotor.bufferedaction == nil then locomotor:Stop() end`：",
    "--   ★★ **只清移动，不清动作**：有缓冲动作时保留。",
    "--     注释语义：「停止移动但保持动作」。",
    "--   ⚠ 但此处没有 locomotor nil 检查（4383 行）。缓解：4382 行已被 4309 行",
    "--     的 CanLocomote 过滤（无 locomotor 时 4309 为假 → 不进本分支）。",
  ],

  "PlayerController:DoDirectWalking#1+83": [
    "--★★ 【4389-4414：摇杆松开时的收尾】",
    "--   4391-4392 行 CanLocomote + 无 override → locomotor:Stop()（**用 Stop 不用 Clear**）。",
    "--   4393 行注释 \"instead of self.locomotor:Clear()\" ——",
    "--     ★★ 关键设计：Stop 保留 bufferedaction，Clear 会丢掉它。",
    "--     4394 行取出它，4407-4413 行在「清完手势标志后」重新 Push/Preview。",
    "--   ⇒ 这就是松手护栏的**另一半**：即使护栏没生效，",
    "--     也会用「Stop 而非 Clear + 手动重启」的方式保住刚缓冲的动作。",
    "--   ⚠ 4391 行多了 `controller_attack_override == nil` 条件，",
    "--     与 4420 行的 DoDirectStopWalking 不同（那里没有这个条件）。",
  ],

  "PlayerController:DoDirectWalking#1+93": [
    "--   4399-4404 行：客户端清按键状态 + 无 locomotor 时发停止 RPC。",
    "--   ⚠ 4401-4403 行只在 locomotor == nil 时发 RPC ——",
    "--     有 locomotor 的客户端不发，因为引擎会自己同步 locomotion 状态。",
  ],

  "PlayerController:DoDirectWalking#1+111": [
    "--★★ 【DoDirectStopWalking】★ 无 locomotor 客户端在 busy 时的停止补偿。",
    "--   注释：\"for non-predicting clients, stopping during busy states\"",
    "--   五重条件（4419-4424）：",
    "--     ① 非服务端",
    "--     ② 正在 direct/drag 走",
    "--     ③ locomotor == nil（★ 这就是「无 locomotor」的定义性判据）",
    "--     ④ handler 存在（本机玩家）",
    "--     ⑤ GetWorldControllerVector() == nil（摇杆确实松了）",
    "--   ⇒ 这解释了「无 locomotor 客户端」的能力缺口：",
    "--     它没有 locomotor 组件，所以 busy 期间（3041 行）必须靠 RPC 停住。",
  ],

  "PlayerController:DoDirectStopWalking#1+17": [
    "--★ ROT_REPEAT = .25 / ZOOM_REPEAT = .1：相机旋转/缩放的最小间隔。",
    "--   ★ 用 GetStaticTime（墙钟）而非 GetTime → 暂停时仍生效。",
  ],

  "PlayerController:DoCameraControl#1": [
    "--★★ 【DoCameraControl】相机控制。由 OnWallUpdate(2631 行) 每墙钟帧调用。",
    "--   ★ 双路径：SupportsControllerFreeCamera（自由视角手柄，4453-4477 行）",
    "--     与传统按键（4479-4502 行）。",
  ],

  "PlayerController:DoCameraControl#1+3": [
    "--   ★ 4441 行与 RotLeft/RotRight（1476/1495 行）同款守卫：",
    "--     「不能控制相机 但 在用无人机」→ 仍允许旋转。",
  ],

  "PlayerController:DoCameraControl#1+8": [
    "--   4446 行：既没 enabled 也没 hudblocking → 放弃。",
    "--     ★ 但 4445 行已经拿到了 isenabled/ishudblocking，而这里**只判 isenabled**，",
    "--       与 601 行 OnControl 的 `if not isenabled and not ishudblocking` 不同。",
    "--   ⚠ 差异：在 HUD 阻塞（如地图打开）时，OnControl 仍会放行部分按键，",
    "--     但 DoCameraControl 完全不工作。这是有意的（地图里用自己的缩放）。",
  ],

  "PlayerController:DoCameraControl#1+15": [
    "--   ★★ 4453 行的自由视角分支（4419-4477）：支持「按住旋转 + 垂直缩放」同时进行。",
    "--     移动端/主机平台的常见需求（右摇杆转视角 + 扳机缩放）。",
  ],

  "PlayerController:DoCameraControl#1+21": [
    "--★ 4459 行 `absxdir >= deadzone and absxdir > absydir * 1.3`：",
    "--   --favour zoom a bit more at diagonals",
    "--   ★★ 1.3 的系数：对角线输入时**优先缩放**。",
    "--   ⇒ 因为对角推时 x/y 都较大，若不加权则两者同时超阈值导致抖动。",
    "--     1.3 意味着缩放方向需要比旋转方向推得更远才触发。",
  ],

  "PlayerController:DoCameraControl#1+26": [
    "--   ★ 4464 行 Remap(min(1, absxdir), deadzone, 1, 2, 3)：",
    "--     ★★ 把摇杆幅度映射到「每秒转 2~3 格」。死区处最慢，推满最快。",
    "--     这是「模拟量旋转」的实现（对比传统分支的定步长 45°）。",
  ],

  "PlayerController:DoCameraControl#1+34": [
    "--   4472 行 Remap(min(1, absydir), deadzone, 1, 0, 0.65) → 缩放速度。",
    "--   ★ 4473 行 ContinuousZoomDelta(ydir > 0 and -delta or delta)：",
    "--     ★ 负号来源：摇杆「上」（ydir > 0）对应「放大」，而缩放是反向的。",
  ],

  "PlayerController:DoCameraControl#1+41": [
    "--   -- CharlesB: Not used right now",
    "--   ⇒ 4480 行之后的传统按键分支在支持自由视角的手柄上是死代码。",
    "--     但键盘玩家仍走这里（TheInput:SupportsControllerFreeCamera 为假）。",
  ],

  "PlayerController:DoCameraControl#1+52": [
    "--★ 4490-4502 行：滚轮/按键缩放。4492/4497 行的 craftingmenu.focus 检查",
    "--   呼应 303-304 行 OnContinueFromPause 缓存的 zoomin_same_as_scrollup。",
    "--   ⚠ 4492 行 `self.inst.HUD.controls.craftingmenu.focus` 没有 craftingmenu 的",
    "--     nil 检查（只检查了 HUD 与 HUD.controls）。",
    "--   ⚠ 疑似缺陷（潜在 nil）：若某个平台/模式下 controls.craftingmenu 未创建",
    "--     （widgets/controls.lua:302-306 是在特定条件下 AddChild 的），",
    "--     这里会崩。",
    "--     推理依据：widgets/controls.lua:302-306 显示 craftingmenu 在 if/else 分支里",
    "--       创建，存在未创建的可能。",
    "--     影响：仅在 zoomin_same_as_scrollup 为真时才求值该表达式（短路），",
    "--       故只在「缩放键映射到滚轮键」的手柄配置下触发。",
  ],

  "IsWalkButtonDown#1": [
    "--★ IsWalkButtonDown：四个移动键任一按下。",
    "--   ★ 用于 4516 行：「松开鼠标左键时若方向键还按着，就不停住」。",
    "--     ⇒ 玩家「按住方向键 + 点地面 + 松鼠标」应该继续走而不是停。",
  ],

  "PlayerController:OnLeftUp#1": [
    "--★ 【OnLeftUp】鼠标左键抬起（由 4684 行 OnLeftClick(down=false) 调用）。",
    "--   ⚠ 注意：**不是** RPC 的对端，是一个纯客户端的本地事件处理。",
    "--   ⇒ 客户端的「松开鼠标」不需要通知服务器（服务器只关心最终位置）。",
    "--   ★ 但 4528 行 RemoteStopControl(CONTROL_PRIMARY) 会发一个停止 RPC ——",
    "--     因为 remote_controls 需要同步（服务端要用 IsControlPressed 判断攻击）。",
  ],

  "PlayerController:OnLeftUp#1+7": [
    "--★ 4516 行 `CanLocomote() and not IsWalkButtonDown()`：",
    "--   ★★ 「松开鼠标但方向键还按着 → 不 Stop」。",
    "--     与 4319 行的松手护栏同源，但判据是**按键状态**而非时间窗。",
    "--   ⇒ 两个护栏互补：护栏 1 用时间窗，护栏 2 用按键状态。",
  ],

  "PlayerController:OnLeftUp#1+18": [
    "--   4527-4529 行：非服务端 → 通知服务器「鼠标左键松开」。",
    "--   ★★ 这解释了为什么 remote_controls 里需要存按键的「按住时长」：",
    "--     抬起事件让服务器能清掉它，否则 IsControlPressed 永远为真。",
  ],

  "PlayerController:DoAction#1": [
    "--★★★ 【DoAction(buffaction, spellbook)】★★★ **所有按钮的最终汇合点**。",
    "--   13379 行的 actions.lua 定义「有什么动作」，本文件定义「何时用哪个动作」，",
    "--   而 DoAction 是「把选好的动作真正启动」的唯一入口。",
    "--   结构（七步）：",
    "--     ① 4546-4552 无 locomotor 客户端的 non_preview_cb 早期触发",
    "--     ② 4554-4584 有效性检查（空 / 目标失效 / busy）",
    "--     ③ 4586-4600 重复动作检查",
    "--     ④ 4602-4604 攻击时记录 retarget",
    "--     ⑤ 4606-4616 目标高亮闪烁（仅本机客户端）",
    "--     ⑥ 4618-4627 自动装备 + 长按记录",
    "--     ⑦ 4629-4644 ★ 三分支执行（PushAction / 无 locomotor / PreviewAction）",
    "--   ⚠ 它被 20+ 处调用，是全文件耦合度最高的函数。",
  ],

  "PlayerController:DoAction#1+1": [
    "--   --V2C: -New support for \"non_preview_cb\" on non-predicting clients.",
    "--   --     -If there's no pre_action_cb, trigger the cb to send the RPC",
    "--   --      right away, matching old behaviour.",
    "--   ★★★ 这条 V2C 注释是**协议演进的直接证据**：",
    "--     non_preview_cb 是后来为「无 locomotor 客户端」新增的回调字段，",
    "--     而为保持向后兼容，需要在「没有 pre_action_cb」时立刻触发（等旧行为）。",
    "--   ⇒ 理解要点：pre_action_cb 与 non_preview_cb 是**两种不同的 RPC 触发时机**：",
    "--     · non_preview_cb → 不经 locomotor，到 DoAction 就发（立即）",
    "--     · preview_cb     → 经 locomotor 缓冲，到达/动画完成才发（延迟）",
  ],

  "PlayerController:DoAction#1+4": [
    "--★ 4546-4552 行：条件极其特殊 —— non_preview_cb 存在 且 无 pre_action_cb",
    "--   且 无 locomotor。此时**立刻**触发回调（即发 RPC）。",
    "--   ⚠ 4549 行的 `self.locomotor == nil` 是必要条件（否则预览路径会触发）。",
  ],

  "PlayerController:DoAction#1+12": [
    "--   --Check if the action is actually valid. /",
    "--   --Cached LMB/RMB actions can become invalid. /",
    "--   --Also check if we're busy.",
    "--   ★★ 「缓存的 LMB/RMB 动作可能失效」—— 因为 LMBaction 是上一帧算的（2827 行），",
    "--     这一帧目标可能已被删除/销毁。",
  ],

  "PlayerController:DoAction#1+17": [
    "--★ 4559-4563 行：四个有效性判据（动作存在、invobject/target/doer 有效）。",
    "--   ⇒ 即使动作原型有效，参与的实体也必须都还活着。",
  ],

  "PlayerController:DoAction#1+23": [
    "--★ 4565-4579 行：busy 时的例外 —— CASTAOE 允许重复施法。",
    "--   4568 行 `local item = spellbook or buffaction.invobject`：",
    "--     ★ spellbook 参数从 836/1036/4736 行一路传下来。",
    "--     ⇒ DoAction 的第二个参数存在的唯一理由就是重复施法判定。",
    "--   ★★ 4572 行 `self.inst:HasTag(\"canrepeatcast\")` 是**玩家**标签而非物品标签 ——",
    "--     意味着「这个角色能不能连射」是角色属性，与武器无关。",
  ],

  "PlayerController:DoAction#1+39": [
    "--   ★ 4582 行 `self.actionholdtime = nil`：",
    "--     动作无效 → 取消长按起点 → 不会进入长按重复状态。",
  ],

  "PlayerController:DoAction#1+44": [
    "--★★ 【4587-4600 重复动作检查】★ 本文件防「连点」的最终防线。",
    "--   四个比较：action 相同 / target 相同 / pos 相同。",
    "--   4591-4592 行 `currentbuffaction.pos == buffaction.pos` 带注释：",
    "--     \"Note: see overloaded DynamicPosition:__eq function\"",
    "--     ★★ DynamicPosition 重载了 __eq —— 所以 == 比较的是坐标而非对象身份。",
    "--     这是 actions.lua / bufferedaction 体系的一个精巧设计。",
    "--   4594-4596 行的例外：",
    "--     `not (currentbuffaction.ispreviewing and HasTag(\"idle\") and sg:HasStateTag(\"idle\"))`",
    "--     ★ 若当前动作正在**客户端预览**且玩家处于 idle → 允许重复。",
    "--   4597-4598 行注释：\"The 'not' bit is in case we are stuck waiting for",
    "--   server to act but it never does\" ——",
    "--     ★ 即「如果服务器卡住了，我们要能重发」，否则玩家会觉得卡死。",
  ],

  "PlayerController:DoAction#1+60": [
    "--★ ATTACK 动作时把 target 写进 sg.statemem.retarget（供 2635 行读）。",
    "--   ⇒ 3140 行的链式攻击由此获得目标。",
  ],

  "PlayerController:DoAction#1+64": [
    "--★ 4606-4616 行：目标闪烁（表现层）。仅 handler ~= nil（本机客户端）。",
    "--   4611 行的默认参数 .2/.125/.1：闪白强度/渐入/渐出时间（秒）。",
    "--   4612 行 highlightflashaddoverride：模组可覆盖闪烁强度。",
  ],

  "PlayerController:DoAction#1+76": [
    "--★ 4619 行 `self.attack_buffer = nil`：",
    "--   ★★ 「开始新动作 → 清掉待处理的攻击请求」。",
    "--     优先级规则：任何非攻击动作都会丢弃之前的攻击请求。",
  ],

  "PlayerController:DoAction#1+79": [
    "--★ DoActionAutoEquip：先自动装备，再执行（见 4652 行）。",
  ],

  "PlayerController:DoAction#1+81": [
    "--★★ 【4623-4627 长按记录】`not instant and not invalid_hold_action and IsValid()`",
    "--   三个否定条件：",
    "--     · instant（瞬发动作，如走路/看）→ 不可长按重复",
    "--     · invalid_hold_action（actions.lua:349）→ 显式禁止长按重发",
    "--     · :IsValid() → 动作本身仍有效",
    "--   ⇒ 只有「持续性动作」（挖矿/砍树/进食）会被记录为 lastheldaction。",
  ],

  "PlayerController:DoAction#1+87": [
    "--★★★ 【4629-4644 三个执行分支】",
    "--   4629-4630 服务端：PushAction(buffaction, true) —— force_run=true",
    "--   4631-4641 无 locomotor 客户端：手工触发 pre_action_cb + non_preview_cb",
    "--   4642-4643 有 locomotor 客户端：PreviewAction(buffaction, true)",
    "--   ⚠ 三分支都**没有 else**。若既不是服务端、locomotor ~= nil、",
    "--     又不能 CanLocomote（4565 行的 busy 等），则**什么都不做** —— ",
    "--     动作被静默丢弃。这是有意的（busy 时不排队）。",
    "--   ★ 4638-4641 行的双重触发与 4546-4552 行的早期触发互补：",
    "--     有 pre_action_cb → 在这里触发；无 pre_action_cb → 在 4546 行已触发。",
  ],

  "PlayerController:DoAction#1+104": [
    "--   LOOKAT（查看）完成后登记到「已查看」图鉴（TheScrapbookPartitions）。",
    "--   ★ 2391 行的同款调用在 GetInspectButtonAction 路径上也有 ——",
    "--     两处都记，说明「登记」既不在动作里也不在 RPC 里，而在调用点。",
  ],

  "PlayerController:DoActionAutoEquip#1": [
    "--★★★ 【DoActionAutoEquip】★ 自动装备的**黑名单式**实现（25 行全是排除）。",
    "--   4654-4673 行：22 个条件全满足才自动装备。",
    "--   ★ 结构性观察：**没有白名单，全是黑名单**。",
    "--     ⇒ 后果：新增一个「不该自动装备」的动作，开发者必须记得改这里；",
    "--       而新增一个「应该自动装备」的动作无需改动（默认会装备）。",
    "--   ⇒ 好处：新动作默认获得自动装备行为（绝大多数动作确实如此）。",
    "--   ⚠ 这是模组作者的**必读点**：自定义动作若不想要自动装备，",
    "--     必须自己 patch 这个函数或用 invobject 的标签绕过。",
  ],

  "PlayerController:DoActionAutoEquip#1+20": [
    "--   ★ 4672 行是唯一的复合条件：TOSS（投掷）除非物品带 keep_equip_toss。",
    "--     ⇒ 多数投掷动作不自动装备（避免「扔石头顺手装备石头」），",
    "--       但某些角色（如韦布斯特的球）可以。",
  ],

  "PlayerController:DoActionAutoEquip#1+24": [
    "--   ★ 4676 行 autoequipped = true —— ★★ 这个标志的**关键用途在服务端**：",
    "--     963-972 行（OnRemoteControllerActionButton）与 1213-1220 行",
    "--     都在检查「lmb/rmb 中任一 code 匹配」，正是为了容忍自动装备导致的漂移。",
    "--     若客户端没装备、服务端装备了（或反之），code 就会不匹配。",
    "--   ⚠ 但 4652 行只在客户端执行（用 replica.inventory），",
    "--     而 963 行的检查在服务端 —— 服务端怎么知道客户端是否自动装备了？",
    "--   ⇒ 推理：服务端会**独立地**执行同一个自动装备逻辑（因为 DoAction:4621",
    "--     在服务端也跑），所以两端同步装备 → code 一致。",
    "--     这是「客户端预测 + 服务端独立重算」的又一处体现。",
  ],

  "PlayerController:OnLeftClick#1": [
    "--★★★ 【OnLeftClick(down)】鼠标左键。由 652 行 OnControl 分派。",
    "--   ★★ 4681 行 `if not self:UsingMouse() then return end`：手柄模式完全忽略。",
    "--   结构（140 行）：",
    "--     ① 4681-4698 守卫（鼠标模式 / 抬起 → OnLeftUp / IsEnabled）",
    "--     ② 4699-4719 建造放置 / HUD 元素",
    "--     ③ 4724-4786 ★ 动作选择（AOE / 双击 / LMB / WALKTO 兜底）",
    "--     ④ 4788-4793 地图动作",
    "--     ⑤ 4795-4831 各动作的额外副作用（dragtime / retarget / 准星）",
    "--     ⑥ 4833-4873 ★ 发送（三分支）",
    "--     ⑦ 4875-4887 收尾（DoAction + 防闪烁 + busy 微调）",
  ],

  "PlayerController:OnLeftClick#1+3": [
    "--   ★ 4683-4686 行：抬起事件转给 OnLeftUp（4509 行）后立即返回。",
    "--     ⇒ 与 622 行的统一抬起处理不同：**鼠标左右键被显式排除**于统一处理。",
  ],

  "PlayerController:OnLeftClick#1+8": [
    "--   ★ 4688 行 ClearActionHold：每次左键都重置长按状态。",
    "--     ⇒ 保证「每次新点击都是干净的长按起点」。",
  ],

  "PlayerController:OnLeftClick#1+12": [
    "--   ★ 4692-4695 行：保存并清空上一次的**双击**记录（区别于长按记录）。",
    "--   ⚠ 变量名 startdoubleclicktime/pos 与 long press 的 actionholdtime 不同，",
    "--     两者互不干扰。",
  ],

  "PlayerController:OnLeftClick#1+19": [
    "--   ★ 4699-4701 行：鼠标在 HUD 元素上 → 取消建造放置。",
    "--     \"点 UI 会取消建造\" 是一个容易被误解但很重要的行为。",
  ],

  "PlayerController:OnLeftClick#1+22": [
    "--   建造放置模式：与 2308 行的手柄版本同构，但多了 can_build / onfailed 分支。",
  ],

  "PlayerController:OnLeftClick#1+41": [
    "--★ 4722 行 `self.actionholdtime = GetTime()`：长按起点。",
    "--   ⚠ 4721 行先取 `local t = GetTime()` 再存，4722 行同时赋值 ——",
    "--     t 在 4760/4774/4798/4801 行被复用（双击判定）。",
  ],

  "PlayerController:OnLeftClick#1+45": [
    "--★ AOE 瞄准分支（4725-4743）：与 824-843 行的手柄版本几乎逐行同构。",
    "--   ⚠ 但 4732 行用的是 `self:GetRightMouseAction()`（**鼠标右键**的缓存），",
    "--     而手柄版 831 行用 `self:GetGroundUseAction()`（现算点地动作）。",
    "--     ⇒ 同一个语义，两条不同实现。这是鼠标/手柄不对称的一例。",
  ],

  "PlayerController:OnLeftClick#1+65": [
    "--★ 4745-4746 行 `TheSim:GetPosition()` + `ProjectScreenPos()`：",
    "--   ★★ 这个组合**不是**取鼠标位置，而是取「屏幕中心投影到世界」。",
    "--   为什么？TheSim:ProjectScreenPos 需要世界坐标→屏幕的逆运算；",
    "--     DST 里 TheInput:GetWorldPosition()（4748 行注释提到）才是正解。",
    "--   ⚠ 但 4748 行的注释写 \"basically TheInput:GetWorldPosition()\"，",
    "--     说明作者认为两者近似。",
    "--   ⚠ 疑似缺陷（可能的不精确）：ProjectScreenPos(scrnx, scrny) 的语义",
    "--     是「把屏幕坐标 (scrnx,scrny) 投影回世界」，若参数是 GetPosition() 返回的",
    "--     视口中心，则结果确实是鼠标位置附近。",
    "--     推理依据：GetPosition 返回相机的视口中心；ProjectScreenPos 是逆投影。",
    "--     ⇒ 正确理解：这是「从屏幕中心反投影」，等价于取鼠标下的地面点。",
  ],

  "PlayerController:OnLeftClick#1+72": [
    "--★ 4752 行 `TheInput:GetWorldEntityUnderMouse()`：鼠标下的实体。",
    "--   4753-4755 行：不可见则置 nil（4754 行的重复判断是优化）。",
  ],

  "PlayerController:OnLeftClick#1+76": [
    "--★ 4756 行的条件 `if target or CanEntitySeeTarget(self.inst, self.inst)`：",
    "--   与 4233 行同款 —— 「有目标 或 玩家能看见自己」才尝试双击。",
  ],

  "PlayerController:OnLeftClick#1+78": [
    "--★ 4758 行 GetDoubleClickActions(position, dir, target)[1] —— 三参数版。",
    "--   ⚠ 与 4283 行（服务端）只传 position 的版本不对称（见该处注释）。",
  ],

  "PlayerController:OnLeftClick#1+80": [
    "--★ 4760-4761 行的双击判定比 4243 行更严：还要**位置接近**",
    "--   （DOUBLE_CLICK_POS_THRESHOLD = 3，constants.lua:2307）。",
    "--   ⇒ 鼠标双击要求两次点击在同一片区域（3 像素内），摇杆双击只要求时间。",
  ],

  "PlayerController:OnLeftClick#1+84": [
    "--★★ 4764-4770 行 trypreventdirflicker —— 一个被主动限定范围的修复。",
    "--   注释全文：",
    "--     \"If we're holding a direction key, direct walking will (after one frame)",
    "--      cancel whatever action we are about to buffer to the locomotor",
    "--      (unless it's instant). This flag prevents facing change flicker.",
    "--      Should really do this always, but to avoid bugs with legacy behaviour,",
    "--      we will just do it for players with double click actions for now.\"",
    "--   → 翻译：按住方向键时，刚缓冲的动作会在一帧后被「直接行走」取消，",
    "--     表现为「角色朝向闪一下又转回」。这个标志阻止该闪烁。",
    "--   ★★ 注释最后两句是金矿：作者明确说「应该总是这么做，",
    "--     但为了不破坏 legacy 行为，只给有双击动作的玩家开」。",
    "--   ⇒ 这是「明知有更好方案但不敢全量上线」的典型工程妥协。",
    "--   ⚠ 后果：**只有双击动作受保护**，其他动作仍有朝向闪烁。",
  ],

  "PlayerController:OnLeftClick#1+92": [
    "--   ★ 4772-4775 行：首次（不构成双击）时**记录**位置与时间，作为第二次的基准。",
    "--     且 4772 行的条件包含 `or self:IsBusy()` ——",
    "--     ⇒ busy 时即使不是首次双击也持续记录，因为 busy 期间点击不会执行。",
  ],

  "PlayerController:OnLeftClick#1+100": [
    "--★★ 4780-4785 行：动作选择的最终兜底链。",
    "--   4781 行 `GetLeftMouseAction() or BufferedAction(self.inst, nil,",
    "--   ACTIONS.WALKTO, nil, position)`：",
    "--     没有 LMB 动作 → **兜底为 WALKTO**（点地面走过去）。",
    "--   ★ 这是玩家最常用的操作，也是唯一「必然有动作」的情况。",
    "--   4782-4784 行：动作是 WALKTO 或 LOOKAT 时**不**记录双击起点，",
    "--     且 4783 行主动清空 startdoubleclicktime。",
    "--   ⚠ 看似多余（4782 行已经保证 act ~= nil 时才执行），",
    "--     实则是清掉 4773-4774 行可能已记录的起点。属防御式冗余。",
  ],

  "PlayerController:OnLeftClick#1+115": [
    "--★★ 4795-4799 行：WALKTO 时若目标是**平台**（船/冰），不进入拖拽模式。",
    "--   4797 行的 HasAnyTag(\"walkableplatform\", \"walkableperipheral\") 排除。",
    "--   ⇒ 「点击船上走过去」不会变成「按住拖拽」。",
  ],

  "PlayerController:OnLeftClick#1+120": [
    "--   DASH（冲刺，如韦德的技能）也设置 startdragtime ——",
    "--   ⇒ 冲刺后可继续拖拽连续冲刺。",
  ],

  "PlayerController:OnLeftClick#1+122": [
    "--★ ATTACK 分支：与 DoAttackButton 的「重复攻击」检查同构（2802/1302 行）。",
    "--   ★ 4805 行 `sg:HasStateTag(\"attack\") and act.target == combat:GetTarget()`",
    "--     4804 行先写 retarget —— ★ 即使要 return 也已经写了。",
    "--   ⚠ 副作用：对着同一目标狂点时，每次都会刷新 retarget（无害）。",
  ],

  "PlayerController:OnLeftClick#1+131": [
    "--★ LOOKAT 分支：目标带 playeravatardata → 弹玩家资料；",
    "--   4819-4821 行：目标带 quagmire_shoptab → 推事件打开商店页。",
    "--   ⚠ 硬编码模组内容（quagmire）写在通用文件里（同 2489 行温蒂特例）。",
  ],

  "PlayerController:OnLeftClick#1+143": [
    "--   船炮 / 高尔夫的准星涟漪（纯表现）。",
  ],

  "PlayerController:OnLeftClick#1+153": [
    "--★★★ 【4833-4873 发送分支】与手柄版同构，但有两处鼠标特有的细节。",
    "--   4834 行服务端：combat:SetTarget(nil)（同其他按钮）。",
  ],

  "PlayerController:OnLeftClick#1+157": [
    "--★ 4837-4846 行：★ 「用准星位置」还是「用鼠标位置」的抉择。",
    "--   四种动作用 reticule 的位置：",
    "--     · CASTAOE（法术）",
    "--     · BOAT_CANNON_SHOOT（船炮）",
    "--     · GOLF_START_CHARGING（高尔夫）",
    "--     · dblclickact（双击动作，位置可能已被覆盖）",
    "--   注释 \"dblclickact also may have overridden the position\" ——",
    "--     4780-4781 行的 WALKTO 兜底会把 act 换成用 position 的新动作，",
    "--     所以此时必须用 act.pos 而不是原鼠标位置。",
    "--   ⇒★★ 这解释了为什么 4841 行的条件里要包含 `act == dblclickact`：",
    "--     「动作实例换了，位置来源也必须跟着换」。",
  ],

  "PlayerController:OnLeftClick#1+167": [
    "--★ 4847-4851 行的 else 分支：用真实鼠标位置，并转成平台相对坐标。",
    "--   4850 行 `act.action ~= ACTIONS.DROP and GetWorldEntityUnderMouse() or nil`：",
    "--     ★★ DROP（丢弃）时不发 mouseover —— 丢弃不需要悬停物信息。",
    "--     ⚠ 又一个 `a and b or nil` 惯用法：若 GetWorldEntityUnderMouse 返回",
    "--       false（不会，实体是 table 或 nil），结果为 nil。安全。",
  ],

  "PlayerController:OnLeftClick#1+173": [
    "--★ EncodeControlMods：把修饰键掩码一起发给服务器（转发的强制攻击等）。",
  ],

  "PlayerController:OnLeftClick#1+174": [
    "--★ 4854-4872 行：三分支发送，与 886-939 行同构。",
    "--   ★ 4861-4864 行的「按钮按下」通知：鼠标左键的无参 RPC（RPC.LeftClick）。",
  ],

  "act.non_preview_cb#8+10": [
    "--★ 4865 行 `act.action ~= ACTIONS.WALKTO and self:CanLocomote()`：",
    "--   ★★ 与 2300 行一致的 WALKTO 豁免 —— 走过去不产生动作 RPC。",
    "--     但 4861-4864 行的「按下通知」**仍会发**。",
    "--   ⚠ 这意味着点地面走：发 1 个 RPC.LeftClick（无参）+ 若干 PredictWalking。",
    "--     而不是发一个完整的 LeftClick(code, x, z, ...)。带宽优化成立。",
  ],

  "act.preview_cb#8+9": [
    "--★ 4875 行 DoAction：无论走哪条分支，最终都汇合到这里。",
  ],

  "act.preview_cb#8+11": [
    "--★ 4877-4879 行：trypreventdirflicker 的实际执行。",
    "--   ★ 完整条件链（跨 4758-4879 行）：",
    "--     ① 4758 行算出 dblclickact 但**首次点击**（未构成双击）",
    "--     ② 且玩家正按方向键（dir ~= nil）→ 4770 行置 trypreventdirflicker = true",
    "--     ③ 4780-4781 行 act 仍为 nil → 兜底为 LMB 动作或 WALKTO",
    "--     ④ 4877 行：标志为真 且 act 不是 dblclickact（即③）→ locomotor:Clear()",
    "--   ⚠⚠ 关键：locomotor.lua:755 的 Clear() 内部会 `SetBufferedAction(nil)`，",
    "--     即**清掉刚刚缓冲的动作**。",
    "--   ⇒ 实际效果：玩家「按住方向键 + 首次点击有双击动作的物体」，",
    "--     该次点击的动作被丢弃（不执行），换来朝向不闪烁。",
    "--   推理依据：locomotor.lua:755-763 Clear 的函数体含 SetBufferedAction(nil)；",
    "--     4770 行的注释只提「防止朝向闪烁」，未说明会丢动作。",
    "--   ⇒ 这是一个**已知代价的显式取舍**，不是意外：",
    "--     玩家若想执行该动作，松开方向键再点一次即可（此时 dir 为 nil）。",
  ],

  "act.preview_cb#8+15": [
    "--★ 4881-4887 行：位置存在时发 busy 微调（温泉等场景）。",
    "--   4883 行服务端走 sg:HandleEvent(\"ms_overridelocomote_click\", ...)，",
    "--     4885 行客户端走 DoClientBusyOverrideLocomoteClick（3991 行）。",
  ],

  "PlayerController:OnRemoteLeftClick#1": [
    "--【OnRemoteLeftClick】★ 左键的服务端对端（最长的一个 Remote 函数）。",
    "--   ★★ 4901 行 DecodeControlMods 在**动作选择之前**调用 ——",
    "--     修饰键（强制攻击等）必须先生效，picker 才能算出对应动作。",
    "--     与 5098 行（右键）的顺序一致。",
  ],

  "PlayerController:OnRemoteLeftClick#1+6": [
    "--   actioncode == nil → 「只是按下通知」（4863 行发的）。",
    "--   4897 行 assert(isreleased == nil)：同 951/1199 行的自检断言范式。",
  ],

  "PlayerController:OnRemoteLeftClick#1+11": [
    "--★ 4901-4924 行：解码修饰键 → 选动作 → 清修饰键。",
    "--   ★ 4924 行 ClearControlMods() 在**动作算完之后**才清 ——",
    "--     保证算动作时修饰键生效。",
  ],

  "PlayerController:OnRemoteLeftClick#1+14": [
    "--★ 法术书分支（4904-4911）：与 998 行同构，含 GetGrandOwner 校验。",
  ],

  "PlayerController:OnRemoteLeftClick#1+22": [
    "--   4912 行的 `elseif spell_id == nil`：",
    "--   ⚠ 疑似缺陷（条件含义）：这个条件是「spell_id 为 nil」，",
    "--     而 spellbook == nil 的情况由上一分支覆盖。",
    "--     若两者都为 nil（无书无 spell_id）→ 走 4913 行算普通动作。正确。",
    "--     若 spellbook ~= nil 且 spell_id == nil（书在手上但没选法术）→",
    "--       ★ 走 4913 行的普通路径，可能算出非施法动作。",
    "--     推理依据：4904 分支要求 spellbook ~= nil 全部条件才进；",
    "--       否则落到 4912 行，此时 spell_id 恰好为 nil 就会被当普通点击。",
    "--     缓解：客户端侧 4737-4739 行 spell_id 从 spellbook 取，",
    "--       不会同时出现「有书无 spell_id」。故当前不可触发。",
  ],

  "PlayerController:OnRemoteLeftClick#1+25": [
    "--★ 4915-4918 行：服务端也算一次双击动作（用于 4945 行的回退链）。",
    "--   4916 行同样用 CanEntitySeeTarget(self.inst, self.inst) 做守卫。",
  ],

  "PlayerController:OnRemoteLeftClick#1+36": [
    "--★★ 【4929-4949：四级回退链】★ 本文件最精巧的一段。",
    "--   注释：\"Default fallback lmb action is WALKTO /",
    "--    Possible for lmb action to switch to rmb after autoequip /",
    "--   --V2C: LOOKAT was added to support closeinspect\"",
    "--   四级顺序及理由：",
    "--     ① 4929-4932 LOOKAT：客户端上报 LOOKAT 但算出的是 WALKTO",
    "--        → 「靠近检视」（closeinspect）：玩家走到目标旁边就自动看。",
    "--        ★ 这是模组 closeinspect 的实现。",
    "--     ② 4933-4936 WALKTO：算出 nil 但客户端要的是 WALKTO → 补一个。",
    "--        这是「鼠标点地面」的服务端兜底（因为客户端根本没算 LMB 动作）。",
    "--     ③ 4937-4940 LMB code 匹配 → 标准路径。",
    "--     ④ 4941-4944 RMB code 匹配 → 自动装备导致的漂移（同 963 行）。",
    "--     ⑤ 4945-4948 双击动作 code 匹配 → 双击动作的服务端执行。",
    "--   ⚠⚠ 疑似缺陷（校验放松）：⑤ 让**双击动作**可以绕过 ③ 的 LMB 校验，",
    "--     而双击动作的位置参数（position）来自客户端。",
    "--     缓解：4945 行的 dblclickact 是服务端在 4917 行自己算的（用同一 position），",
    "--       只是取 [1]；且 4917 行传的是 position 而非 4758 行的三参数版。",
    "--     ⇒ 所以「绕过」的是 LMB 通道，但仍需 code 与服务端自算的 dblclickact 匹配。",
    "--       安全性可接受。",
    "--   ⇒★ 真正的价值：这条链让「客户端与服务端算出不同动作」的四种情况都有出路，",
    "--     而不是简单地丢弃请求。**容错优先于严格**。",
  ],

  "PlayerController:OnRemoteLeftClick#1+61": [
    "--★ 4951-4956 行：force 时对齐预测位置（同 975 行）。",
    "--   ★★ 4956 行的 DoAction(lmb, spellbook) 传了 spellbook ——",
    "--     因为 ① 的 LOOKAT 兜底可能来自法术书路径。",
  ],

  "PlayerController:OnRemoteLeftClick#1+67": [
    "--   --see trypreventdirflicker",
    "--★★ 4958 行：服务端的 trypreventdirflicker 对应实现。",
    "--   条件与客户端 4877 行不同：这里多了 `self:GetRemoteDirectVector()`",
    "--   （即「正在直接行走」），因为服务端没有 isclientcontrollerattached 可用。",
    "--   ⚠ 4958 行 `self.locomotor.bufferedaction` 无 nil 检查 ——",
    "--     服务端玩家必有 locomotor（玩家 prefab 都挂），风险低。",
  ],
};

export const AFTER = {};