// spec-playercontroller-p7.mjs —— 第 7 段：3700-4200 行
// 覆盖：★★ 移动链路核心 —— remote_vector 编码表、四个解码器、移动 RPC 收发两端、
//       跳跃的服务器校验（橡皮筋距离）、DoPredictWalking（预测驱动与纠正）、
//       DoDragWalking、DoBoatSteering

export const BEFORE = {
  "PlayerController:ResetRemoteController#1+3": [
    "--============================================================",
    "-- 【第七段】3700-4200 行：★★★ 移动链路（客户端预测 + 橡皮筋 + teleport）",
    "--============================================================",
  ],

  "PlayerController:CycleControllerAttackTargetBack#1+13": [
    "--★★ 【3694-3695 顶部注释 —— 本文件最重要的一行注释】",
    "--   --remote_vector.y is used as a flag for stop/direct/drag walking",
    "--   --since its value is never actually used in the walking function",
    "--   ==> ★★★ 这是 B8 缺陷的官方声明。Klei 自己的注释说：",
    "--     「y 被用作 停止/直接行走/拖拽行走 的标志，**因为它的值在行走函数",
    "--       里从来没被真正用到**」。",
    "--   ⇒ 而事实是：这句话在写时为真，后来**不再为真**了。",
    "--     因为 3736-3747 行的 GetRemotePredictPosition 在 y>=3 时把 y 当成",
    "--     **真实高度**返回给调用方（`Vector3(x, self.remote_vector.y, z)`），",
    "--     而 4014/4030/4054/4067 行又反过来用 `pt.y == 5 / < 5 / == 3 / == 4`",
    "--     做模式判断。",
    "--   ⚠⚠⇒ 编码与解码**互相递归**：",
    "--     写入端：3790 行 `remote_vector.y = isdirectwalking and 3 or 4`（标签）",
    "--     解码端 A：3737 行 `if self.remote_vector.y >= 3 then`（当标签用）",
    "--     解码端 B：3743 行 `Vector3(x, self.remote_vector.y, z)`（当坐标用）",
    "--     消费端：4054 行 `if pt.y == 3`（又当标签用）",
    "--   ⇒ 同一个数值在同一次调用链里既是「模式」又是「海拔」。",
    "--     只要标签值不是 0，海拔就是 3/4/5/6 这种荒谬高度。",
    "--     目前之所以没出事，是因为没有任何代码真的用 pt.y 做物理计算。",
    "--   参见 bug-patterns.md B8：「一字段三语义」。",
  ],

  "PlayerController:ResetRemoteController#1": [
    "--【ResetRemoteController】★ 全量重置远端镜像。三件事：",
    "--   ① remote_vector.y = 0（模式归零 = 停止）",
    "--   ② remote_controls = {}（按键全松）",
    "--   ③ ClearRemotePredictData()（预测数据全清）",
    "--   ★ 调用点：322（Activate）、368（Deactivate）、2736（OnUpdate 禁用时）、",
    "--     5927（ToggleMovementPrediction）。四处都是「状态彻底变了」的时刻。",
  ],

  "PlayerController:ClearRemotePredictData#1": [
    "--【ClearRemotePredictData(force_reset_timer)】★ 预测数据的三段握手清理。",
    "--   3706-3707 行：dir 与 stop_tick 直接清。",
    "--   3708-3712 行：★ 若已收到 stop 通知 → 清标志并取消 locomotor 的计时器。",
    "--   3713-3715 行：否则若 force_reset_timer → 也取消（强制）。",
    "--   ⇒ 语义：",
    "--     · 非强制 + 没通知 → **保留** locomotor 的计时器（可能还有效）",
    "--     · 非强制 + 有通知 → 取消（客户端说停了，计时器无意义）",
    "--     · 强制 → 无条件取消（3043 行的 busy 分支用）",
  ],

  "PlayerController:ClearRemotePredictData#1+6": [
    "--   ★ CancelPredictMoveTimer（locomotor.lua:465）：",
    "--     取消「预测移动超时自杀」定时器。",
    "--     若不取消，玩家停下后 locomotor 会在某个时刻自行归位（回滚），",
    "--     造成「明明停住了却又抖一下退回」。",
  ],

  "ConvertPlatformRelativeToAbsoluteXZ#1": [
    "--【ConvertPlatformRelativeToAbsoluteXZ】平台局部坐标 → 世界坐标。",
    "--   ★ 3719 行 platform 为 nil → 原样返回（世界坐标）。",
    "--   ⚠ 3721 行 `elseif platform:IsValid()` —— 若平台无效则**隐式返回 nil**，",
    "--     而调用方（3761 行 GetRemotePredictStopXZ）返回 nil 是合法的（3759 行的契约）。",
    "--     3780 行的 GetRemotePredictPositionExternal 也做了 x 的 nil 检查。",
    "--   ⇒ 平台的失效是被显式处理的，这是平台机制补丁史里少见的干净之处。",
  ],

  "PlayerController:GetRemoteDirectVector#1": [
    "--★★★ 【四个解码器】—— remote_vector 的读出端。",
    "--   GetRemoteDirectVector  (3727) y==1 → 方向向量（directwalking）",
    "--   GetRemoteDragPosition  (3731) y==2 → 拖拽目标点（dragwalking）",
    "--   GetRemotePredictPosition(3736) y>=3 → 预测目标点（★ y 变成海拔）",
    "--   GetRemotePredictStopXZ  (3759) 特殊：读取「刚停止的那一帧」的坐标",
  ],

  "PlayerController:GetRemotePredictPosition#1": [
    "--   --V2C: These aren't really meant for use outside of this component XD",
    "--   ⇒ 标注「内部 API」，但 12 处外部调用（inventory / locomotor 等）。",
    "--     「XD」暗示这是临时状态。",
    "--   ★★ 3743 行是 B8 的**病根**：`Vector3(x, self.remote_vector.y, z)`",
    "--     把标签值原样当作 Y 坐标塞进返回值。",
    "--     若 y==3，返回的向量高度就是 3（相当于三层楼高）。",
    "--     全部调用点：4080 附近的自比较（只用 xz）、5769-5797（只用 xz）、",
    "--     1934/976/1033/1225/1269/2334/4294/4953/5109（只取 x,z 取或整点）。",
    "--   ⚠ 已核实：没有任何调用点真正使用返回值的 .y 做物理计算。",
    "--     5797 行的 `Transform:SetPosition(pt.x, 0, pt.z)` 硬编码了 y=0。",
    "--     ⇒ 这证明「y 是标签」在实践中是自洽的，",
    "--       但 3743 行的写法依然是一个**定时炸弹**：任何人拿这个返回值算高度都会中招。",
  ],

  "PlayerController:GetRemotePredictPositionExternal#1": [
    "--   --V2C; This one can be used externally XD",
    "--   ★ 与 GetRemotePredictPosition 的区别：3754 行**显式构造 y=0** 的向量。",
    "--     ⇒ 这个版本是「干净的」，没有 B8 陷阱。",
    "--     外部调用点：inventory.lua:2428（丢物品的落点）、locomotor.lua:930。",
  ],

  "PlayerController:GetRemotePredictStopXZ#1": [
    "--★ 【GetRemotePredictStopXZ】「上一帧刚停止」的坐标读取。",
    "--   ★★ 3760 行的双重条件：`remote_predict_stop_tick + 1 == GetTick()`",
    "--     且 `remote_vector.y == 0`。",
    "--   ⇒ 语义：**只在停止后的紧接一帧有效**。",
    "--     这是「一次性读取」的设计 —— 读取后 4105 行会清 stop_tick。",
    "--   ⚠ 若服务器那一帧没跑（卡顿），读取失败，客户端位置就永久偏了那 0.5 格。",
    "--     但 4082 行的橡皮筋会在后续帧兜住（超过 4 格才触发，0.5 格不会）。",
    "--   ⇒ 净效果：极端情况下可能残留半格误差，无纠正。属可接受的权衡。",
  ],

  "PlayerController:OnRemoteDirectWalking#1": [
    "--★★ 【OnRemoteDirectWalking】移动 RPC 的服务端接收端（direct）。",
    "--   ★ 三重守卫与所有 Remote* 一致。",
    "--   ★★ 3771 行的 ClearRemotePredictData()：",
    "--     「切到直接行走 ⇒ 之前的预测目标作废」。",
    "--     这是三种移动模式**互斥**的保证。",
    "--   ⚠ 但注意它**不设置** remote_predict_dir / _stop_tick —— 3771 行的",
    "--     ClearRemotePredictData 把它们清了。所以切到 direct 后预测状态是干净的。",
  ],

  "PlayerController:OnRemotePredictWalking#1": [
    "--★★★ 【OnRemotePredictWalking】★★ 预测行走 RPC 的服务端接收端 —— 最复杂的一个。",
    "--   签名：(x, z, isdirectwalking, isstart, platform, overridemovetime, isstop)",
    "--   ⚠ 服务端已经做过参数校验（networkclientrpc.lua:425-467）：",
    "--     · 两种形态之一：全 nil（x==z==isdirectwalking==platform==platform_relative==nil",
    "--       且 isstart 或 isstop 为真）或全合法",
    "--     · isstart 必须是 bool",
    "--     · IsPointInRange（半径 64！）",
    "--     · 必须 playercontroller.remote_predicting 为真",
    "--   ⇒ 所以本函数收到的是「已清洗」的数据。",
  ],

  "PlayerController:OnRemotePredictWalking#1+4": [
    "--   ★★ 3789 行写入标签：`isdirectwalking and 3 or 4`。",
    "--     这是 remote_vector.y 的**唯一写入点**之一（另一处是 3923 行的客户端）。",
    "--   ⚠ 3791 行的 platform 参数：**x/z 是该平台的局部坐标**。",
    "--     3790 行设 y=3/4 后，3737-3745 行的 GetRemotePredictPosition 会做还原。",
    "--   ⚠⚠ 疑似缺陷（B8 的具体表现）：",
    "--     platform 为 nil（世界坐标）时，3743 行返回 `self.remote_vector` 本身",
    "--     （3739 行）—— 此时 y=3/4/5/6 是标签；",
    "--     platform 非 nil 时，3741-3743 行做坐标变换并 `Vector3(x, y, z)`，",
    "--     此时的 y 仍是标签值，被伪装成海拔。",
    "--     两条路径返回的向量语义不一致（一个是「原始信封」，一个是「还原后的点」），",
    "--     但调用方无法区分。",
    "--     推理依据：3739 行 `return self.remote_vector` 直接返回**同一个对象**，",
    "--       调用方若修改返回值就会破坏内部状态（aliasing 缺陷）。",
    "--   ⚠ 已核实当前所有调用点都只读不写，故 aliasing 未被触发。",
  ],

  "PlayerController:OnRemotePredictWalking#1+9": [
    "--★ 3794 行 `remote_predict_stop_notified = isstop`：",
    "--   isstop 可能是 nil（只发坐标不发 stop），此时 notified 被清空。",
    "--   ⇒ 语义：「客户端最后一条消息明确说了 stop 吗」。",
  ],

  "PlayerController:OnRemotePredictWalking#1+11": [
    "--★ isstart → RestartPredictMoveTimer（locomotor.lua:461）：",
    "--   「重新开始计时」。locomotor 内部有个超时：预测移动若在 N 秒内没更新就自杀。",
    "--   ⇒ 这是**预测的保险丝**：客户端崩溃/断网时服务器不会永远追一个死目标。",
  ],

  "PlayerController:OnRemotePredictWalking#1+13": [
    "--   overridemovetime → OverridePredictTimer(GetTime() - overridemovetime)：",
    "--   ★★ 客户端告诉服务器「我已经移动了 N 秒」。",
    "--     服务器用 `GetTime() - N` 反推出「客户端的移动起点时刻」，",
    "--     从而让服务器的移动计时器与客户端对齐。",
    "--   ⇒ 这是**时间戳同步**的一个轻量实现（只传时长不传绝对时间，",
    "--     避免时钟偏移）。参见 locomotor.lua:469 OverridePredictTimer。",
  ],

  "PlayerController:OnRemotePredictWalking#1+15": [
    "--   x == nil 分支：只发控制信号（isstart / isstop / overridemovetime）不发坐标。",
    "--   3801-3803 行 K 的注释：\"guaranteed either isstart or isstop (or both) /",
    "--   overridemovetime optional / everything else nil\"",
    "--   ⇒ 这解释了 3932 行的 `SendRPCToServer(RPC.PredictWalking, nil, nil, nil,",
    "--     isstart, nil, nil, overridemovetime, isstop)` ——",
    "--     **前四个全 nil**（x, z, isdirectwalking, platform）。",
  ],

  "PlayerController:OnRemotePredictWalking#1+24": [
    "--★ 3809-3816 行的判定：客户端说「我停了」时，服务器怎么处理计时器。",
    "--   ① 不是 stop → 清 notified（还在走）",
    "--   ② 是 stop 且（服务器知道停止 tick 或有预测位置）→ notified = true，",
    "--      「我记住了，等会儿用」（由 3708 行消费）",
    "--   ③ 是 stop 但服务器完全不知情 → 直接 CancelPredictMoveTimer",
    "--     （客户端骗我们？没有有效目标，停就停）",
  ],

  "PlayerController:OnRemotePredictOverrideLocomote#1": [
    "--★ 【OnRemotePredictOverrideLocomote】busy 状态下的方向微调（服务端）。",
    "--   3822 行的三重守卫 + 状态标签 overridelocomote：",
    "--     ★ 必须处于「可被外部驱动移动」的状态（滑索、传送带等）。",
    "--   3823-3826 行的条件被 3830 行和 3967 行的注释互为印证：",
    "--     「e.g. Moose tackle can be cancelled using directional input, but the",
    "--      state itself is still busy」—— 密恐魔被套住时能用摇杆挣脱。",
  ],

  "PlayerController:OnRemotePredictOverrideLocomote#1+3": [
    "--   ★ classified.busyremoteoverridelocomote（--WASD）：服务端标记「这个状态",
    "--     允许摇杆驱动」。由 SGwilson 在进入特定状态时设置。",
    "--   ★ 3824-3825 行两个 classified 或运算：摇杆 与 左键 两种驱动源。",
  ],

  "PlayerController:OnRemoteStartHop#1": [
    "--★★★ 【OnRemoteStartHop(x, z, platform)】★★ 跳跃的**服务器权威校验**。",
    "--   ★ 这是本文件里「反作弊校验」写得最完整的一段，值得逐行读。",
    "--   RPC 层已做（networkclientrpc.lua:491-506）：参数类型 + platform 一致性。",
    "--   本函数再做**距离校验**（3835-3882）。",
  ],

  "PlayerController:OnRemoteStartHop#1+3": [
    "--   3838 行 `if not self.handler == nil then return end` ——",
    "--   ⚠ 疑似缺陷（Lua 运算符优先级）：`not self.handler` 先求值为布尔，",
    "--     再与 nil 比较 → **恒为 false**（布尔永远不等于 nil）。",
    "--     本意应是 `if self.handler ~= nil then return end`（本机玩家不发 RPC）。",
    "--   推理依据：3790/3837 行的前两句是 ismastersim 与 IsEnabled，",
    "--     3838 行应是第三个同类守卫 `self.handler == nil`（少了波浪号）。",
    "--   ⇒ 实际后果：本机玩家（房主在自己的客户端上）发来的 StartHop RPC",
    "--     **不会被这个守卫拦截**，会继续执行到 locomotor:StartHopping。",
    "--     对房主来说这基本无害（自己就是权威），但守卫失效了。",
    "--   ⚠ 这是一个**真实存在但低危**的缺陷：守卫失效，且恰好对房主最不重要。",
  ],

  "PlayerController:OnRemoteStartHop#1+5": [
    "--   ★★ 3850 行的守卫：`platform == nil and (当前无平台 or 落点在海里)` → 拒绝。",
    "--   逻辑：请求跳到「没有平台的地方」→ 除非那是个漂浮物（跳到海里的浮冰）。",
    "--   ⇒ 防止客户端凭空请求「跳到地图外的虚空」。",
  ],

  "PlayerController:OnRemoteStartHop#1+22": [
    "--★★ 【3857-3874：移动平台的橡皮筋补偿】★ 本文件最精细的一段计算。",
    "--   问题：站在**移动的船**上跳向对岸。客户端算落点时基于自己的世界坐标，",
    "--     服务端执行时船已移动。若不补偿，合法跳会被判「太远」。",
    "--   解法（3859-3874）：",
    "--     ① 取平台速度向量",
    "--     ② 若速度非零：把「跳跃方向」与「平台移动方向」都归一化",
    "--     ③ 取点积 hop_dir_dot_platform_velocity（3870 行）",
    "--     ④ 若点积 > 0（同向）→ 额外预算 = 0.7 秒 × 速度 × 点积",
    "--   ⇒ 这是把「一个 RTT 时间内的平台位移」折算成距离预算。",
    "--   ★ 3870 行严格要求点积 > 0：船**朝跳跃方向**移动才补偿。",
    "--     若船横向漂移（点积 ≈ 0）不补偿 —— 因为那不是「追不上」而是「偏了」，",
    "--     偏了应该由别的方式修正。",
  ],

  "PlayerController:OnRemoteStartHop#1+41": [
    "--★ 跳跃的橡皮筋距离 = 基础 4 + 平台速度补偿 + locomotor 自己的跳跃距离。",
    "--   GetHopDistance（locomotor.lua:1222）返回「按当前速度能跳多远」。",
    "--   ⇒ 三项相加意味着：合法跳（落点在跳跃能力内 + 网络滞后补偿内 + 平台移动内）",
    "--     才被接受。",
  ],

  "PlayerController:OnRemoteStartHop#1+44": [
    "--★ 超距则 `print` 一整段诊断信息后 return。",
    "--   ⚠ 注意用的是 `print` 而非 Print/VERBOSITY 包装 ——",
    "--     开发版会把这段打到日志，生产版被 C++ 层过滤。",
    "--   ★ 这是本文件里**唯一**的调试输出（grep 确认），K 特意留下它",
    "--     因为「Hop discarded」是玩家会遇到的真实问题（船跳失败）。",
  ],

  "PlayerController:OnRemoteStartHop#1+49": [
    "--   ★★ remote_vector.y = 6 —— 跳跃模式。这是唯一的 y=6 写入点。",
    "--   3964 行 IsLocalOrRemoteHopping 会读它：`remote_vector.y == 6 or",
    "--   locomotor.hopping`。",
    "--   ⇒ y=6 的含义是「正在跳跃」，此时 x/z 是**客户端请求的落点**。",
    "--   ⚠ 3885 行 ClearRemotePredictData()：跳跃会取消预测移动（互斥）。",
  ],

  "PlayerController:OnRemoteStopWalking#1": [
    "--★ OnRemoteStopWalking / OnRemoteStopHopping：停止的两种 RPC，",
    "--   ★★ 但两个函数体**完全相同**（都是 y=0 + ClearRemotePredictData）。",
    "--   ⚠ 疑似缺陷（冗余 RPC）：既然行为一致，可以合并成一个 StopWalking。",
    "--     推理依据：对比 3889-3894 与 3896-3901 行，函数体逐字相同。",
    "--     影响：多占用一个 RPC 通道（每个 RPC 都要注册 handler，占内存）。",
    "--     历史原因：推测 StopHopping 是后加的，忘了合并。",
  ],

  "PlayerController:RemoteDirectWalking#1": [
    "--★★ 【3903-3945 客户端发 RPC 端】—— 四种移动手势的发送。",
    "--   RemoteDirectWalking (3903) / RemoteDragWalking (3912) /",
    "--   RemotePredictWalking (3922) / RemoteStopWalking (3940)",
    "--   ★★ 全部有「值未变则不发」的去重（3904/3913/3924/3941 行）。",
    "--     这是**带宽优化的第一道闸**。",
  ],

  "PlayerController:RemoteDirectWalking#1+2": [
    "--   ★★ 3905 行的英文注释是一条协议设计说明：",
    "--   \"x and z are directions, not positions, so we don't need it to be",
    "--    platform relative\"",
    "--   → directwalking 的 x/z 是**方向向量**（已归一化），不是位置，",
    "--     所以不需要平台相对坐标转换（也不需要 platform 参数）。",
    "--   ⇒ ★ 这解释了网络侧的直接校验：networkclientrpc.lua:392",
    "--     `if x * x + z * z < 1.01 then` —— ★★ 用**长度平方 ≤ 1.01** 验证方向向量！",
    "--     这是一个漂亮的协议级反作弊：客户端不可能通过这里发一个位置。",
    "--   ⇒ 对比 dragwalking（4402 行）：发的是位置，需要 IsPointInRange 与平台转换。",
  ],

  "PlayerController:RemoteDragWalking#1+2": [
    "--★ 拖拽行走需要平台相对坐标（3914 行 GetPlatformRelativePosition）。",
    "--   3915 行 SendRPCToServer(RPC.DragWalking, pos_x, pos_z, platform,",
    "--   platform ~= nil) —— ★ 最后那个 `platform ~= nil` 是 RPC 的",
    "--   **类型标记位**（RPC 需要区分「nil 参数」与「缺省参数」）。",
  ],

  "PlayerController:RemotePredictWalking#1": [
    "--★★ 【RemotePredictWalking】预测行走的客户端发送端。",
    "--   3923 行 `local y = (overridedirect or self.directwalking) and 3 or 4`：",
    "--     ★★ 客户端**自己**算出与服务器 3789 行相同的标签值，",
    "--       并保存在本地 remote_vector 里（3928 行）。",
    "--     这就是「客户端预测」的字面含义：两端各自维护同构的 remote_vector。",
    "--   ⚠ 注意 3923 行的条件用了 `or self.directwalking`，",
    "--     而 3789 行只有 `isdirectwalking`。客户端多了一个 overridedirect 来源",
    "--     （4119/5756 行的调用会传 overridedirect = 上一次的 direct 值）。",
  ],

  "PlayerController:RemotePredictWalking#1+2": [
    "--★★ 3924 行的去重条件是**三段或**，且末段带 `self.remote_vector.y ~= 0`：",
    "--   `x 变了 or z 变了 or (y 变了 and 当前不是停止态)`。",
    "--   ⇒ 语义：「服务器说停了（y==0）之后，即使客户端的意图没变也不再发」。",
    "--   ★ 设计意图：停 → 走 的转换要发一次（3757 行是 stop，3931 行补发 isstart）。",
    "--   ⚠⚠ 疑似缺陷（状态机卡死）：见 3005 行的分析 ——",
    "--     服务端把 remote_vector.y 置 0（nopredict 分支）后，",
    "--     客户端的 3924 行末段条件 `self.remote_vector.y ~= 0` 恒为 false，",
    "--     若 x/z 也恰好没变，则**永远不再发送预测更新**。",
    "--   ⇒ 服务端一次 nopredict 置零会让客户端的预测目标永久冻结。",
    "--   推理依据：3924 行完整条件；3006 行 `self.remote_vector.y = 0`；",
    "--     3930 行 predictionsent = true 也只在「发送了」时设置，",
    "--     且 2659 行每帧清零，说明它也依赖「至少发过一次」。",
  ],

  "PlayerController:RemotePredictWalking#1+9": [
    "--   ★ 3931-3932 行：坐标没变但 isstart/isstop 变了 → 补发「无坐标」的控制消息。",
    "--     对应服务端 3800 行的 x==nil 分支。",
    "--   ⇒ 这是三态消息（坐标 / 控制 / 无）的第二种形态。",
  ],

  "PlayerController:RemotePredictOverrideLocomote#1": [
    "--【RemotePredictOverrideLocomote】busy 态方向微调的客户端发送端。",
    "--   3937 行 `dir or (autodir ~= false and GetRotation()) or nil`：",
    "--     ★★ 三态：无 dir + autodir ~= false → 用当前朝向（持续微调）",
    "--       无 dir + autodir == false → 显式 nil（**停止**微调）",
    "--       有 dir → 用指定方向",
    "--   ⇒ autodir 参数是一个「布尔化的 nil」，与文件头的 or/nil 惯用法同源。",
  ],

  "PlayerController:RemoteStopWalking#1": [
    "--★ RemoteStopWalking：只有 y ~= 0 时才发（3941 行去重）。",
  ],

  "PlayerController:DoPredictHopping#1": [
    "--★ 【DoPredictHopping】★★ 客户端「检测到跳跃就上报」。",
    "--   ★★ 3950 行的边沿检测：`if locomotor.hopping and not self.is_hopping`。",
    "--     ⇒ 只在跳跃**开始的那一帧**发一次 StartHop（3954 行）。",
    "--   ★ 为什么需要这个：跳跃是 locomotor 自己发起的（玩家点远处），",
    "--     服务器并不知道客户端「打算跳」。这个函数是唯一的上报通道。",
    "--   ★ 3952 行 `embarker:GetEmbarkPosition()` —— 取得「登船点」坐标。",
    "--     这不是跳跃目标，而是**当前所站的平台上的落点**（服务端的出发基准）。",
  ],

  "PlayerController:DoPredictHopping#1+3": [
    "--   ⚠ 3951 行 `self.inst.components.embarker` 无 nil 检查。",
    "--     缓解：能 hopping 说明有 embarker 组件（Boarding 是 locomotor 的前置）。",
    "--   ⚠ 3956 行 `self.is_hopping = self.locomotor.hopping` 每帧更新（边沿维护）。",
  ],

  "PlayerController:IsLocalOrRemoteHopping#1": [
    "--★ IsLocalOrRemoteHopping：`remote_vector.y == 6 or (locomotor and locomotor.hopping)`。",
    "--   ★ 两个来源：远端玩家的跳跃标志（服务端）/ 本地的实际跳跃（客户端）。",
    "--   ⇒ 这个函数被 4005（DoPredictWalking）、4127（DoDragWalking）、",
    "--     4307（DoDirectWalking）三处调用 —— 「跳跃时不接受任何其他移动意图」。",
  ],

  "PlayerController:DoClientBusyOverrideLocomote#1": [
    "--★★ 【DoClientBusyOverrideLocomote】busy 态的方向微调（客户端发送）。",
    "--   3968-3971 行的注释解释了动机（莫比乌斯/密恐魔）。",
    "--   ★★ 3983 行的边沿检测：摇杆松开时的**下一帧**才发「停止」消息。",
    "--     `if self._last_busy_override_locomote_tick == tick - 1 then`",
    "--   ⇒ 为什么要等一帧？因为松手瞬间客户端还不知道玩家是真松手还是抖了一下。",
    "--     而 busy 态下没有 locomotion 的移动事件可依赖，只能靠 tick 比较。",
    "--   ⚠ 疑似缺陷（帧率敏感）：若某帧 dt > 1（卡顿），tick 直接跳过 2，",
    "--     `tick - 1` 不匹配 → 停止消息永不发 → 服务器持续按旧方向微调。",
    "--     推理依据：3983 行的精确 tick 相等判断；GetTick() 在低帧率下可能跳号。",
    "--     缓解：服务器侧 DoClientBusyOverrideLocomote 的对端（3823 行）在",
    "--       not IsBusy 时会退出，故影响有限。",
  ],

  "PlayerController:DoClientBusyOverrideLocomoteClick#1": [
    "--★ DoClientBusyOverrideLocomoteClick：左键版（3992 行注释：\"e.g. Getting",
    "--   out of hotspring\" —— 从温泉里出来）。",
    "--   与摇杆版的区别：单击**给一个方向**（3999 行 GetAngleToPoint），",
    "--     不持续更新，也不发停止消息（因为是一次性动作）。",
  ],

  "PlayerController:DoPredictWalking#1": [
    "--★★★ 【DoPredictWalking】★★★ **本文件第二核心函数**（122 行）。",
    "--   双端共用同一个函数，靠 `if self.ismastersim` 分成两个完全不同的实现：",
    "--   · 服务端分支（4004-4106）：**消费**客户端的预测目标，驱动 locomotor，",
    "--     并在误差过大时执行橡皮筋回滚。",
    "--   · 客户端分支（4107-4123）：**生产**预测目标并发送。",
    "--   ★ 由 3045 行每帧调用。",
  ],

  "PlayerController:DoPredictWalking#1+1": [
    "--   服务端分支入口。",
  ],

  "PlayerController:DoPredictWalking#1+2": [
    "--   ★ 跳跃中不接受预测行走（三种移动手势互斥的第一处）。",
  ],

  "PlayerController:DoPredictWalking#1+5": [
    "--   ★★ GetRemotePredictPosition 有值才继续 —— 意味着「客户端在预测移动」。",
    "--     为 nil 时走 4095 行的「刚停止」处理分支。",
  ],

  "PlayerController:DoPredictWalking#1+7": [
    "--   x0,y0,z0 = 服务器当前的权威位置。",
  ],

  "PlayerController:DoPredictWalking#1+8": [
    "--   ★ distancetotargetsq：服务器与客户端预测目标的**平面**距离平方。",
    "--     ⚠ 注意用的是 util.lua:553 的 distsq(pt.x, pt.z, x0, z0) —— 忽略 y。",
    "--     这是对的：B8 陷阱在这里被规避了（没有用 pt.y）。",
  ],

  "PlayerController:DoPredictWalking#1+9": [
    "--★ 停止阈值：floating（漂浮）时 0.0001（几乎精确），否则 0.05（≈0.22 格）。",
    "--   ⚠ 疑似缺陷（精度过低）：0.05 的平方 = 0.22 格的停止容差。",
    "--     对比 PREDICT_STOP_ERROR_DISTANCE_SQ = 0.25（0.5 格）。",
    "--     0.22 意味着玩家停下时服务器位置与目标的差可达 0.22 格 ——",
    "--     这在视觉上几乎不可见（角色碰撞半径 0.5），可接受。",
    "--     但注意这是**每帧**判据，所以会持续收敛到 0.22 格内。",
    "--   推理依据：4012 行硬编码 0.05 而非引用任何 TUNING 或本文件常量；",
    "--     与 4098 行引用 PREDICT_STOP_ERROR_DISTANCE_SQ 的风格不一致。",
  ],

  "PlayerController:DoPredictWalking#1+11": [
    "--★★★ 【pt.y == 5 分支】★ 这是 B8 最直接的消费者。",
    "--   y==5 的含义（5801 行设置）：「客户端要开始执行动作，预测目标被冻结」。",
    "--   条件：正在执行动作（locomotor 或实体有 bufferedaction）或状态图不在 idle/moving。",
    "--   ⇒ 动作优先于移动：先把三个移动标志清掉。",
    "--   ⚠ 但 4023-4026 行：只有在**距离已经够近**时才清 remote_vector.y，",
    "--     否则保留让服务器继续走过去。",
    "--   ⇒ 逻辑：「走到位再停下开始动作」—— 这是「走过去砍树」的时序保证。",
  ],

  "PlayerController:DoPredictWalking#1+27": [
    "--★ 4030-4032 行 `if pt.y < 5 then self.inst:ClearBufferedAction() end`：",
    "--   ★★★ **移动优先于动作**：只要还在预测行走（y=3/4），就清掉缓冲动作。",
    "--     实体脚本的 ClearBufferedAction（entityscript.lua:1563）会 Fail 掉它。",
    "--   ⇒ 这实现了「按方向键取消刚缓冲的动作」，是玩家能中途改主意的基础。",
    "--   ⚠ 与 4014-4028 的顺序：y==5（要执行动作）先判并 return，",
    "--     所以只有 y=3/4（纯移动）才会走到 4030 行清动作。二者互补。",
  ],

  "PlayerController:DoPredictWalking#1+31": [
    "--★ 4034 行 `local dir = math.atan2(z0 - pt.z, pt.x - x0) * RADIANS`：",
    "--   从当前位置指向目标的角度。★ 这是 atan2(y, x) 的标准形式，",
    "--     但引擎坐标系 Z 相反 ⇒ 结果的角度与「屏幕方向」差一个镜像。",
    "--   ⇒ 与 1654 行、3601-3601 行的同一约定保持一致。",
  ],

  "PlayerController:DoPredictWalking#1+32": [
    "--★★ 【4035-4050：未到达 vs 已到达】",
    "--   未到达（distancetotargetsq > stopdistancesq）：",
    "--     · RunInDirection(dir)（全速跑向目标）",
    "--     · 记录 remote_predict_dir（供 4039 行用过冲检测）",
    "--   已到达：",
    "--     · 若「方向偏转 ≥90°」且 remote_authority → 直接瞬移到目标",
    "--     · 否则 SetMoveDir(dir)（只转向不移动，用于「最后一点点」对齐）",
    "--     · Stop({force_idle_state = true}) —— ★ 注释：\"so that this tiny motion",
    "--       was meant to cancel an action\" —— 强制进 idle 态是为了中断动作。",
  ],

  "PlayerController:DoPredictWalking#1+36": [
    "--★★★ 【4039-4043：过冲瞬移（overshoot 纠正）】★ remote_authority 的特权。",
    "--   条件：① remote_authority（房主/好友，见 94-98 行）",
    "--     ② 有 remote_predict_dir（之前在走）",
    "--     ③ DiffAngle(dir, remote_predict_dir) >= 90（方向反了）",
    "--   ⇒ 推断：「玩家原本往东走，现在突然要往西走」，",
    "--     且我们已经过了目标点 → 说明目标点是过期数据 → 直接瞬移。",
    "--   ★★ 4084-4088 行的注释解释了这个特权为何**不能**推广：",
    "--     \"--V2C: don't override rubberband, otherwise server teleports will also",
    "--      get stomped by client prediction\"",
    "--     → 翻译：**不要覆盖橡皮筋**（4082 行的逻辑），否则服务器自己的瞬移",
    "--       也会被客户端预测「踩掉」。",
    "--     被注释掉的代码（4085-4088 行）就是「不分 remote_authority 一律瞬移」",
    "--       的旧实现 —— 它曾导致服务器传送被预测覆盖，已被移除。",
    "--   ⚠ 这条注释是本项目重点（「V2C: don't override rubberband」这个坑）",
    "--     的原始证据，务必与 4082-4091 行一起读。",
    "--   ⚠ 但 4039 行的**瞬移本身**仍在，且不受「不覆盖橡皮筋」约束 ——",
    "--     因为它只在这条特定路径上。若服务器同时在做传送（4162 行的 teleport），",
    "--     且玩家刚好在 remote_authority + 反向移动，就会被拉回客户端的旧目标。",
    "--     ⇒ 这是「传送 vs 预测」冲突的**残留漏洞**。",
  ],

  "PlayerController:DoPredictWalking#1+49": [
    "--   ★★ 4052-4053 行注释解释了「为什么服务端要伪造客户端的手势标志」：",
    "--   \"Even though we're predict walking, we want the server to behave",
    "--    according to whether the client thinks he's direct/drag walking\"",
    "--   ⇒ 服务端的 directwalking/dragwalking/predictwalking 三个标志，",
    "--     **来源是客户端的 remote_vector.y**，而不是服务器自己的输入。",
    "--   ★★ 这就是「意图镜像」：服务端用客户端的手势标志来驱动自己的逻辑，",
    "--     因为那些逻辑（攻击范围 1826 行、FindEntity 半径 2135 行等）",
    "--     必须与客户端看到的一致，否则动作校验会失败。",
  ],

  "PlayerController:DoPredictWalking#1+51": [
    "--★ 4054-4075 行：把 remote_vector.y（3/4/其他）翻译成三个布尔手势标志。",
    "--   ★★ 这段是 3694 行「y 是 flag」这一原始设计的**忠实实现**，",
    "--     也是 B8 缺陷仍然存活的原因：",
    "--     ① 它被嵌在「服务端伪造客户端手势」的逻辑里，语义上必须读 y",
    "--     ② 它同时被 3737 行当作「是否在预测」的门槛",
    "--     ③ 它还被 5801 行写入 5 来表达「正在执行动作」",
    "--     三者叠加使 y 无法被安全地改成别的语义。",
  ],

  "PlayerController:DoPredictWalking#1+61": [
    "--★ 4064-4066 行：直接行走超过 0.2 秒 → 清战斗目标。",
    "--   ⇒ 「持续按方向键走路时自动脱战」。",
    "--   ⚠ 但 4064 行的攻击状态检查与 3035 行的 boathopping 豁免不同构，",
    "--     说明这段逻辑加了不止一次补丁。",
  ],

  "PlayerController:DoPredictWalking#1+74": [
    "--★★★ 【4077-4092：停止检测 / 橡皮筋回滚】★ 本项目重点。",
    "--   --Detect stop, teleport, or prediction errors /",
    "--   --Cancel the cached prediction vector and force resync if necessary",
    "--   → 三个不同的终止原因走同一段代码：",
    "--     ① 停止：距离 ≤ stopdistancesq",
    "--     ② 橡皮筋：距离 > 4 格",
    "--     ③ 传送：服务器自己把玩家挪走了（距离自然变得很远）",
  ],

  "PlayerController:DoPredictWalking#1+76": [
    "--★ ① 停止：y=0 + 记录 stop_tick（供 4095 行下一帧的微调）。",
    "--   ⚠ 注意这里**没有** ClearRemotePredictData —— 有意为之，",
    "--     因为下一帧（4095 行）还要用 stop_tick 做最后一次位置微调。",
  ],

  "PlayerController:DoPredictWalking#1+79": [
    "--★★★★ 【4082-4091：橡皮筋回滚】★★★ 本项目重点（bug-patterns B7/B8 的核心）。",
    "--   条件：`distancetotargetsq > RUBBER_BAND_DISTANCE_SQ`（> 16，即 > 4 格）。",
    "--   动作：",
    "--     ① remote_vector.y = 0（放弃预测意图）",
    "--     ② Physics:Teleport(当前世界位置)（★ 见下）",
    "--   ★★ 4084 行的 --V2C 注释是本项目的关键警告：",
    "--     \"--V2C: don't override rubberband, otherwise server teleports will also",
    "--      get stomped by client prediction\"",
    "--   → 翻译：**不要覆盖橡皮筋**。否则服务器自己的传送（传送门/复活/传送带）",
    "--     会被客户端的预测意图「踩掉」——因为传送后玩家离预测目标很远，",
    "--     橡皮筋逻辑会把它拉回客户端发来的旧坐标。",
    "--   ⇒ 这是「teleport 与 rubberband 的优先级」问题：",
    "--     ★★★ 传送必须**赢**，橡皮筋必须**让步**。",
    "--   ⇒ 4085-4088 行是被注释掉的旧代码（无条件 SetPosition 到 pt），",
    "--     4089-4091 行是修复后的实现（Physics:Teleport 到**当前**位置）。",
    "--   ⚠★ 4090 行的 `self.inst.Physics:Teleport(self.inst.Transform:GetWorldPosition())`：",
    "--     ★ 这是「零位移自愈」—— 把物理位置强行对齐到 Transform 位置。",
    "--     物理与 Transform 是引擎的两套坐标系（Transform 是逻辑位置，",
    "--     Physics 是 AABB 碰撞体位置）。传送后 Transform 更新了但 Physics 可能",
    "--     还需要一帧。此调用立即同步二者。",
    "--   ⇒★★ 完整语义：「放弃预测（y=0）+ 让物理追上逻辑（Teleport 到当前）」",
    "--     ——注意**没有**把玩家拉回预测目标，而是拉回**服务器的权威位置**。",
    "--     这正是「服务器胜出」的实现方式：不回滚到客户端，而是停在原地。",
    "--   ⚠ 副作用：客户端此时会在自己的下一帧发现「服务器位置与我的预测差 > 4 格」，",
    "--     触发客户端侧的同步（引擎层的 replicated transform 插值/硬切）。",
    "--     玩家看到的是「突然被拉回」。",
    "--   ⚠⚠ 潜在问题：若服务器传送与客户端正常行走**同时**发生，",
    "--     客户端仍会每帧发送旧的预测目标（3930 行），服务器每次都判定超距、",
    "--     每次都走 4082 分支 → Physics:Teleport 每帧调用 →",
    "--     可能与传送的插值动画打架。",
    "--     缓解：4095 行的 stop 流程与 remote_predict_stop_notified 会终止预测。",
    "--     但若客户端持续发新坐标（玩家仍按着方向键），notified 会被 3794 行重置。",
    "--     推理依据：3794 行 `self.remote_predict_stop_notified = isstop` 每次都赋值；",
    "--       3922-3933 行只要 x/z 变化就会重发。",
    "--   ⇒ 真正的解法是客户端侧的 3924 行末段条件（y==0 时不再发）——",
    "--     而这正是 3005 行分析出的「卡死」隐患的另一面：它同时也是这个循环的",
    "--     **终止条件**。设计上是一石二鸟，但过于脆弱。",
  ],

  "PlayerController:DoPredictWalking#1+92": [
    "--★★ 【4095-4106：停止后的位置微调】",
    "--   触发：pt 为 nil（模式已回 0）但 stop_tick 有值。",
    "--   4096 行 GetRemotePredictStopXZ **只在停止后的紧接一帧有效**（3760 行）。",
    "--   4098 行的三重要求：",
    "--     ① 状态图处于 idle 或 floating（不能还在跑）",
    "--     ② 距离 ≤ PREDICT_STOP_ERROR_DISTANCE_SQ（0.25，即 0.5 格）",
    "--   ⇒ 通过则 SetPosition(x1, 0, z1) —— 把玩家吸到客户端最后说的位置。",
    "--   ★ 这是「服务器主动把玩家向客户端拉近 0.5 格」的补偿，",
    "--     用于消除「停下时的落点误差」。",
    "--   ⚠ 4099-4100 行又出现 FIXME(JBK): Boat handling + FIXED(V2C) 注释 ——",
    "--     第三处。与 4041/4086/5794 相同，说明船只场景反复出问题。",
    "--   ⚠ 4105 行 `self.remote_predict_stop_tick = nil` 在 if 块**外面** ——",
    "--     即使 x1 为 nil 也会清（4103 的 ClearRemotePredictData 也在里面）。",
    "--     ⇒ 若 4096 行返回 nil（tick 不匹配），ClearRemotePredictData 不会被调，",
    "--       但 stop_tick 已被清。结果：remote_predict_dir 等字段残留。",
    "--     推理依据：4103 行在 `if x1 then` 内，4105 行在 if 外。",
    "--     实际后果轻微：下一次 OnRemotePredictWalking 会重置这些字段（3792-3793）。",
  ],

  "PlayerController:DoPredictWalking#1+104": [
    "--★★ 【4107-4123：客户端分支】★★ 生产预测目标并发送。",
    "--   守卫：CanLocomote（760 行）—— 无预测能力则不发。",
  ],

  "PlayerController:DoPredictWalking#1+105": [
    "--★ 4108 行 `sg:HasAnyStateTag(\"moving\", \"floating_predict_move\")`：",
    "--   ★★ floating_predict_move 是一个**专门为预测设计的虚拟状态标签**。",
    "--   为什么需要：漂浮时（坐船/泳圈）真实状态图可能没有 moving 状态，",
    "--     用它能让 OnUpdate 继续产生预测目标。",
    "--   ⇒ 这说明「移动预测」与「状态图」的耦合是通过**标签**解开的。",
  ],

  "PlayerController:DoPredictWalking#1+106": [
    "--★★ 4109 行 `self.inst.Transform:GetPredictionPosition()`：",
    "--   ★★ 不是 GetWorldPosition()！GetPredictionPosition 是**引擎为客户端",
    "--     预测专门维护的位置**（客户端实体的 transform 在预测时会给出预测值）。",
    "--   ⇒ 这是「客户端预测」的引擎级入口：Klei 在 C++ 层做了一套预测位置，",
    "--     Lua 侧只需读取并上报。",
    "--   ⚠ 与 5753 行的对照：那里**刻意**用 GetWorldPosition 并注释",
    "--     \"--V2C: not GetPredictionPosition()\"（因为引擎已修正过本地位置）。",
    "--     ⇒ 两处的选择不同，说明「GetPredictionPosition 在何时可信」有微妙差异。",
    "--   ⚠ 这个差异本身就是 B8 类问题的表现：同一个 API 在两处被相反地使用。",
  ],

  "PlayerController:DoPredictWalking#1+107": [
    "--★ 4110 行的 isstart = `locomotor:GetTimeMoving() == 0`：",
    "--   ★ 「刚开始移动」（累计移动时间为 0）= isstart。",
    "--     这让服务器知道「这是新一段行走的开始，可以重启超时计时器」。",
    "--   PopOverrideTimeMoving（locomotor.lua:452）取出并清空覆盖的移动时长。",
  ],

  "PlayerController:DoPredictWalking#1+108": [
    "--★ 4111-4112 行记录本次的时间戳与手势，供 4119 行补发 isstop 用。",
  ],

  "PlayerController:DoPredictWalking#1+110": [
    "--★ 4113-4122 行：上一帧在移动、本帧不在 → 补发一次 isstop。",
    "--   4114-4117 行的守卫：",
    "--     ① 状态图 idle 或 floating",
    "--     ② 不是 busy 也不是 boathopping",
    "--     ③ tick + 1 == GetTick()（★ 必须紧接着上一帧）",
    "--   ⚠ 4116 行的 tick 精确判断与 3983 行同款，有同样的帧率敏感隐患。",
    "--   ★ 4119 行传 overridedirect = client_last_predict_walk.direct：",
    "--     保证 isstop 那条消息的标签（3 或 4）与之前的一致，",
    "--     否则 3924 行的去重会认为「标签变了」而多发一条。",
  ],

  "PlayerController:DoDragWalking#1": [
    "--★★ 【DoDragWalking】鼠标左键按住拖地走。",
    "--   ★ 由 3046 行调用（仅当 DoPredictWalking 返回 false 时）。",
    "--   ★★ 拖拽是**鼠标独占**的手势（4134 行 draggingonground，鼠标模式）。",
    "--     而 dragwalking 标志本身是双端的（服务端由 y==2 反推，4067 行）。",
  ],

  "PlayerController:DoDragWalking#1+1": [
    "--   ★★ 4127 行两个守卫：跳跃中 或 状态标签 nodragwalk（不允许拖拽走）。",
    "--     nodragwalk 用于「必须站着不动才能操作」的场景（如某些施法）。",
  ],

  "PlayerController:DoDragWalking#1+5": [
    "--★ 4131-4137 行：三个来源取目标点。",
    "--     ① handler == nil（远端玩家）→ GetRemoteDragPosition（y==2 的信封）",
    "--     ② draggingonground（鼠标本地拖拽）→ TheInput:GetWorldPosition（实时鼠标）",
    "--     ③ 都不满足 → pt 为 nil → 不走（返回 nil）",
    "--   ⚠ 但 4131 行还有 `self.locomotor == nil or self:CanLocomote()`：",
    "--     ★★ **无 locomotor 的客户端不能拖拽走**。",
    "--     推理依据：无 locomotor 就没有移动能力。这是无 locomotor 客户端的",
    "--       能力削减之一（另一个是 4107 行的 CanLocomote）。",
  ],

  "PlayerController:DoDragWalking#1+14": [
    "--★ 4140 行 `distsq(pt.x, pt.z, x0, z0) > 1`：",
    "--   ★★ 已经站在 1 格以内就不动。1 是**平方**（0 格 = 重合，1 格 = 1 单位）。",
    "--     ⇒ 拖拽走的死区是 1 单位（1 格），比预测走的 0.22 格大得多。",
    "--   ⇒ 设计：拖拽是「粗粒度」手势，玩家在目标附近时不该来回抖。",
    "--   ⚠ 4141 行 ClearBufferedAction：拖拽移动会取消缓冲动作（同 4030 行思路）。",
  ],

  "PlayerController:DoDragWalking#1+20": [
    "--   ★ 4146 行 `RunInDirection(self.inst:GetAngleToPoint(pt))`：",
    "--     ★ 用 GetAngleToPoint 而不是手算 atan2 —— 这是引擎提供的便捷函数。",
    "--     对比 4034 行手算 atan2。两处等价但写法不同（历史遗留）。",
  ],

  "PlayerController:DoDragWalking#1+26": [
    "--★★ 4152-4156 行：★ **远端与本地的镜像处理**。",
    "--   服务端 → CancelPredictMoveTimer（4153 行，注释 \"remote drag walking,",
    "--   means client is not predicting\"）。",
    "--     ★★ 这行注释揭示了一个重要事实：",
    "--       **拖拽行走永远没有客户端预测**。",
    "--       因为客户端的鼠标位置每帧都在变，无法预测「下一帧鼠标在哪」。",
    "--       所以拖拽是「客户端发坐标、服务器照做」的纯远程驱动模式。",
    "--   无 locomotor 的客户端 → RemoteDragWalking（4155 行，发 RPC）。",
    "--   ⇒ ★★ 对比：direct 行走有预测（locomotor 自带），drag 行走没有。",
    "--     这是三种移动手势里唯一的「非预测」模式。",
  ],

  "PlayerController:DoBoatSteering#1": [
    "--★ 【DoBoatSteering】船上操舵。与行走的双端分派结构相同（4164-4168）。",
    "--   ★ 4167 行手柄模式用 GetWorldControllerVector（真实摇杆），",
    "--     远端玩家用 GetRemoteDirectVector（y==1 的信封）——",
    "--     ★★ 操舵**复用了 direct walking 的编码**（y=1）！",
    "--     4217 行发的 RPC 是 RPC.SteerBoat（不是 DirectWalking）。",
    "--   ⚠ 疑似缺陷（编码复用）：y==1 同时表示「直接行走」和「操舵」。",
    "--     区分靠上下文（服务器在 3052 行根据 steeringboat 标签决定如何解读）。",
    "--     推理依据：3903 行 RemoteDirectWalking 设 y=1；",
    "--       4177 行 SendRPCToServer(RPC.SteerBoat, ...) **不设** remote_vector.y；",
    "--       所以远端玩家的 y 仍是什么就什么，只有 y==1 时 4165 行才有值。",
    "--     ⇒ 实际：远端玩家在船上时，其 y 必须是 1（由 4306 行 DoDirectWalking 的",
    "--       4377 行设置？不对，4377 是服务端分支）。",
    "--     ⚠ 这里存在一个真实的不一致：远端玩家的操舵方向**没有经过 remote_vector**，",
    "--       直接由 RPC.SteerBoat（networkclientrpc.lua:508）传给 steeringwheeluser。",
    "--       所以 4165 行在服务端永远是 nil（除非同时在 direct walking）。",
    "--     ⇒ 结论：DoBoatSteering 的 handler==nil 分支（4165 行）实际是死代码。",
    "--     推理依据：4171-4178 行的服务端分支直接用 dir 而不查 remote_vector；",
    "--       而 DoBoatSteering 只在 OnUpdate:3076 被调用（双端都跑），",
    "--       服务端进入该分支需要 self.handler == nil（恒真）且 dir 非 nil（来自4165）。",
    "--       4165 行要非 nil 必须 remote_vector.y==1，即同时在直接行走，",
    "--       而 3052 行的条件是 HasTag(\"steeringboat\")，此时 3062 行 DoDirectWalking",
    "--       不会被调用（被 3063/3075 分支替代）⇒ remote_vector.y 不可能为 1。",
    "--     ⇒ 死代码的**严格**证明依赖「3062 行不会被调用」这一点。",
  ],

  "PlayerController:DoBoatSteering#1+11": [
    "--   steeringwheeluser 组件：只有「在船上且操作舵轮」时存在。",
    "--   ⇒ 4173 行的 nil 检查是必要的（站在船上但没碰舵）。",
  ],

  "PlayerController:DoDoubleTapDir#1": [
    "--★★★ 【DoDoubleTapDir】双击方向键（默认「跳跃」）。由 3084 行调用。",
    "--   双阈值设计是本函数的核心：",
    "--   · deadzone（4189-4190）：与 GetWorldControllerVector 同源，用于「有没有在推」",
    "--   · 0.8（4194）：「明确推到底」→ 算作一次 tap",
    "--   · 0.6（4195）：「推了一些」→ 算作按住",
    "--   ★★ 两个阈值之间（0.6~0.8）形成「灰色地带」，4197-4198 行的注释说明：",
    "--     \"NOTE: Intentional overlap in the down vs released handling below when",
    "--      isoverdeadzone but not isoverminthreshold\"",
    "--     → 有意让按下与释放的处理在灰区重叠。",
  ],

  "PlayerController:DoDoubleTapDir#1+18": [
    "--   ★★ 4201 行的条件 `isoverdeadzone or isoverminthreshold`：",
    "--     用 deadzone（0.2?）**或** 0.6。死区值远小于 0.6，",
    "--     所以这个 or 实质上被 isoverminthreshold 主导。",
    "--   ⚠ 疑似缺陷（死条件）：isoverdeadzone 永远为真（只要在推），",
    "--     故整个分支等价于 `if isoverminthreshold then`。",
    "--     推理依据：magsq >= 0.36 ⟹ |xdir| 或 |ydir| ≥ 0.6 > deadzone；",
    "--       而 TUNING.CONTROLLER_DEADZONE_RADIUS 的典型值 < 0.6。",
    "--     除非玩家把死区调得 > 0.6（引擎允许），否则 isoverdeadzone 冗余。",
    "--     影响：极小（若死区极大则行为不同），属冗余而非错误。",
  ],

  "PlayerController:DoDoubleTapDir#1+27": [
    "--★ 4209-4211 行：方向角度差超过阈值 → 认为是「转了个方向」而非「双击」。",
    "--   阈值随推杆幅度变化：推到底（0.8）时 60°，轻推（0.6）时 90°。",
    "--   ⇒ 推得越满，允许的角度变化越大（更容易判定为双击）。",
  ],

  "PlayerController:DoDoubleTapDir#1+34": [
    "--★ 4214-4216 行：新 tap 但角度变化太大 → 只记录不执行动作（allowaction=false）。",
    "--   注释 \"don't allowaction below, but still track the new tap\" ——",
    "--     仍然要更新 tap 记录，否则玩家「推过去再推回来」永远双击不了。",
  ],

  "PlayerController:DoDoubleTapDir#1+44": [
    "--★★ 4226-4269 行：tap 成功的处理。",
    "--   4233 行 `CanEntitySeeTarget(self.inst, self.inst)` ——",
    "--     ★★ 检查「玩家能否看见自己」＝ 没有全屏遮挡（UI/其他界面）。",
    "--     与 GetWorldControllerVector 的摇杆检查配对（同在双击路径）。",
    "--   ⚠ 这是一个 hack 式判据：把自己的可见性当作「UI 没挡着」的代理。",
  ],

  "PlayerController:DoDoubleTapDir#1+57": [
    "--★ 4239 行 GetDoubleClickActions(nil, dir, nil)[1] —— 传 dir（当前方向）。",
    "--   ★ 与 4758 行的调用对比：那里传 (position, dir, target)，多了位置与目标。",
    "--     ⇒ 双击方向键用**方向**，双击鼠标用**位置**。这是两条独立的双击路径。",
  ],

  "PlayerController:DoDoubleTapDir#1+60": [
    "--★ 4242-4243 行的双击判定：`allowaction and (last_t and t < last_t + DOUBLE_CLICK_TIMEOUT)`。",
    "--   DOUBLE_CLICK_TIMEOUT = .5（constants.lua:2306）。",
    "--   ⚠ 4245 行 `if self.ismastersim then`：服务端直接执行，",
    "--     客户端发 RPC.DoubleTapAction（networkclientrpc.lua:1233）。",
    "--   ★ 4252-4260 行：双击走 non_preview_cb / preview_cb 双路径，与其他按钮同构。",
    "--     但 4258 行的 preview_cb **不发 canforce**（传 nil），因为跳跃不能强制。",
  ],

  "dblclickact.preview_cb#1+15": [
    "--★ 4273 行的释放判定：`if mem.down and not (isoverminthreshold and",
    "--   isoverdeadzone) then mem.down = false end`。",
    "--   ⚠ 与 4201 行的分析同理，isoverdeadzone 冗余（被 isoverminthreshold 主导）。",
    "--   ⇒ 真正决定「松手」的是 mag < 0.6。",
  ],
};

export const AFTER = {};