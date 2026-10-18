--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：components/playercontroller.lua（5940 行，DST 玩家操控的唯一中枢）
-- 模块：组件 / playercontroller（玩家控制器）
-- 职责：把「玩家的物理输入」翻译成「引擎可执行的状态变更」，并在这条链路上
--       插入一层**客户端预测 + 服务端权威**的双端协议。文件内部可以粗暴地分成
--       六大块，每一块都围绕一个「意图 → 执行体」的映射：
--   ① 输入分发（21-718）    键鼠/手柄事件 → DoXxxButton
--   ② 动作选择（1737-2472）鼠标指向 → 「这一刻能做什么」→ BufferedAction
--   ③ 手柄目标锁定（3178-3690）方向键 → 打分排序 → controller_target/_attack_target
--   ④ 移动链路（3693-4432）★核心★ 意图编码 → RPC → locomotor 驱动 → 橡皮筋纠正
--   ⑤ 地图动作（5122-5319） 屏幕坐标 → 世界坐标 → 仅在地图上可做的动作
--   ⑥ 库存格子与法术书（5562-5748）手柄 UI 直连动作
--
-- ★★★ 全文件第一认知：这不是「玩家逻辑」，而是「网络协议适配层」。
--   PlayerController 在双端都存在同一个类，但**角色完全不同**：
--     · 客户端（handler ~= nil，即本机玩家）：它是**输入源 + 预测器**。
--       按键立刻本地生效（locomotor:PreviewAction / PreviewWalking），
--       同时把「我打算做什么」压缩成整数 actioncode 用 RPC 发给服务器。
--     · 服务端（handler == nil，即远端玩家）：它是**验证器 + 执行器**。
--       OnRemoteXxx 收到 RPC 后**重新跑一遍同样的 GetXxxAction**，
--       只有当重算出的 action.code 与客户端上报的 code 完全一致时才执行。
--   ⇒ 推论 1：客户端上报的不是「结果」而是「意图编号」，服务端永远可以否决。
--   ⇒ 推论 2：任何在 GetXxxAction 里读 TheInput 的代码，在服务端都读不到
--             ——所以服务端路径必须靠 SetClientRequestedAction（995/2329 行）
--             把客户端的 actioncode 临时注入 playeractionpicker 的分支条件里。
--   ⇒ 推论 3：所以「双击两次」「按住不放」这类纯客户端交互，在服务端会退化成
--             一次单次请求。客户端必须用 --V2C: 注释标记的补充协议来补齐。
--
-- ★★★ 全文件第二认知：三个远端玩家**没有输入设备**，必须靠 remote_* 镜像。
--   这个镜像由四个字段族构成，是本文件最难读的部分：
--   ① remote_vector（Vector3）—— 移动意图，见 3694 行顶部注释
--      ★★ y 分量一字段三语义（本项目重点，参见 bug-patterns.md B8）：
--        0 = 停止 / 无意图
--        1 = 直接行走（x/z 是**方向向量**，不是坐标）
--        2 = 拖拽行走（x/z 是**世界坐标**）
--        3 = 预测行走·直接（x/z 是目标坐标）
--        4 = 预测行走·拖拽（x/z 是目标坐标）
--        5 = 预测行走但正在执行动作（目标坐标被冻结，见 5801 行）
--        6 = 跳跃（hopping，见 3884 行）
--      ⇒ y>=3 时 GetRemotePredictPosition 会把 y 当作**真实高度**返回（3743 行），
--        此时 y 只是恰好等于 3/4/5/6 而已，绝不是海拔。这是 B8 缺陷的根源。
--      ⇒ 客户端只发 x/z 两��（3905 行 DirectWalking 注释明确说明），
--        y 完全由服务端按 isdirectwalking/isstop 推导，压缩了带宽。
--   ② remote_controls（table）—— 按键按下态。键 → 剩余冷却秒数。
--      ★ 双重身份：①本地查询（IsControlPressed 515 行）②RPC 幂等去重
--      （BUTTON_REPEAT_COOLDOWN/.5 阻止连点刷动作）。
--   ③ remote_predict_dir / _stop_tick / _stop_notified —— 预测停止的三段握手。
--   ④ recent_bufferedaction —— 「刚放下方向键时不要取消刚缓冲的动作」的护栏。
--
-- ★★★ 全文件第三认知：**V2C = V2C**，即 「Vehicle-to-Client」不，是引擎内部的
--   客户端预测补丁标记（Client Prediction）。全文件 42 处 V2C 注释、8 处
--   FIXME/FIXED(JBK) 标记，说明这套预测链路是**长期打补丁**演化出来的。
--   阅读时凡遇 V2C/FIXME，一律把它当成「这里曾经出过 bug」的墓碑：
--     · 4 处 FIXME(JBK): Boat handling.（4041/4086/4099/5794）—— 船只场景至今未修。
--     · 4084 行 --V2C: don't override rubberband —— 详见下面橡皮筋一节。
--     · 4768 行注释明说「为了不破坏 legacy 行为，只给有双击动作的玩家开这个修复」。
--
-- ── 本文件**不包含**的内容（grep 核实，勿在本文件里找） ──
--   × sprint / 奔跑：grep -niE sprint components/playercontroller.lua → 0 命中。
--     奔跑消耗与速度加成在 locomotor（GetRunSpeed:593）+ 角色 prefab 里。
--   × 饥饿度 / 理智值驱动减速：grep -niE 'hunger|sanity' → 0 命中。
--     减速走 locomotor:SetExternalSpeedMultiplier（567 行），调用方是
--     carefulwalker/grogginess/rooted/miasmawatcher 等组件，饥饿在 hunger.lua。
--   × 跳跃高度 / 空中控制 / 落地伤害：grep -niE 'jump|fall|dropdamage' → 0 命中。
--     本文件只有**平台跳跃（hopping）** 的协议部分（3835-3901），
--     物理部分在 locomotor:StartHopping:1396。
--   × Respawn 流程 / 重生点选择：grep -niE respawnpoint → 0 命中。
--     本文件只有 ACTIONS.REMOTERESURRECT（2426 行，遥控台复活）与
--     ACTIONS.REVIVE_CORPSE（2061 行，复活尸体）。
--   × 控制台命令 / cheat：grep -c AddConsoleCommand → 0 命中。
--     但 94 行 IsConsole() 会让主机玩家拿到 remote_authority 权限（见下）。
--
-- ★★ remote_authority（本文件最容易被误读的权限位，94-98 行）：
--   self.remote_authority = IsConsole() or client.admin or client.moderator or client.friend
--   它**不是**「客户端预测是否开启」的开关，而是「服务器是否相信客户端意图」
--   的信任位。开启后，4039 行的「过冲瞬移」和 5782 行的「动作前对齐」
--   都会**无条件**执行（直接 Transform:SetPosition 硬瞬移、不做距离校验）。
--   ⚠ 这意味着主机/房主/管理者的客户端可以直接把自己的位置拉过去。
--     这是有意为之（房主不该被自己的网络延迟拖累），但它同时是一条真实的
--     作弊面：房主客户端被改内存即可任意瞬移，且**不会**被橡皮筋拉回。
--     参见 4039-4043、5778-5785、3789 三处依赖点。
--
-- 关键符号：
--   PlayerController（类本体）, GetWorldControllerVector（模拟摇杆→世界方向）,
--   OnControl（★ 输入总入口，601 行）, IsEnabled（双返回值：enabled + hudblocking）,
--   CanLocomote / IsBusy（预测准入判据）, DoAction（★ 所有按钮的共同汇合点，4542 行）,
--   DoActionAutoEquip（自动装备白名单）, ClearActionHold / RepeatHeldAction（长按重复）,
--   GetAttackTarget / ValidateAttackTarget / TargetIsHostile（战斗瞄准与过滤）,
--   GetActionButtonAction / GetPickupAction（空间键的 17 级动作优先级链）,
--   GetSceneItemControllerAction / GetGroundUseAction / GetGroundUseSpecialAction /
--   GetItemUseAction / GetItemSelfAction（手柄与鼠标共用的动作查询族）,
--   UpdateControllerAttackTarget / UpdateControllerInteractionTarget /
--   UpdateControllerConflictingTargets（★ 手柄目标打分三件套）,
--   remote_vector / GetRemoteDirectVector / GetRemoteDragPosition /
--   GetRemotePredictPosition / GetRemotePredictStopXZ（★ 移动意图解码）,
--   RemoteDirectWalking / RemoteDragWalking / RemotePredictWalking /
--   RemoteStopWalking / OnRemoteXxxWalking（移动 RPC 的收发两端）,
--   DoPredictWalking（★ 预测的驱动与纠正核心，4003 行）,
--   DoDirectWalking / DoDragWalking / DoDoubleTapDir（三种移动手势）,
--   DoBoatSteering（船上驾驶，与玩家行走互斥）, DoClientBusyOverrideLocomote,
--   OnRemoteStartHop（跳跃的服务器校验，含橡皮筋距离计算）,
--   GetMapActions / RemapMapAction / OnMapAction（地图动作）,
--   EncodeControlMods / DecodeControlMods / MOD_CONTROLS（修饰键位掩码）,
--   RegisterFindTags（TheSim 查询索引，两处注册）, GetMapTarget / PullUpMap,
--   HasAOETargeting / TryAOETargeting / TryAOECharging（AOE 施法与蓄力）,
--   OnLocomotorBufferedAction（动作意图广播给 AI）, RemoteInteractionTarget
--   OnRemoteToggleMovementPrediction（★ 客户端预测的总开关，由外部 UI 控制）
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 networkclientrpc.lua —— 本文件所有 Remote* 的对端
--     networkclientrpc.lua:387 DirectWalking（★ 校验 x*x+z*z<1.01，即方向归一化）
--     networkclientrpc.lua:403 DragWalking（★ 先 IsPointInRange 再转换平台坐标）
--     networkclientrpc.lua:425 PredictWalking（★ 双重 or 校验：全nil 或 全合法）
--     networkclientrpc.lua:43  IsPointInRange —— 半径 64（distsq<=4096）的反外挂闸
--     networkclientrpc.lua:48  ConvertPlatformRelativePositionToAbsolutePosition
--     networkclientrpc.lua:30  printinvalidplatform（第 33 行把 Platform 拼成 Playform ⚠）
--     networkclientrpc.lua:491 StartHop / :508 SteerBoat / :520 StopWalking
--     networkclientrpc.lua:61 LeftClick / :113 RightClick / :163 ActionButton
--     networkclientrpc.lua:179 AttackButton / :205 ResurrectButton / :223 ControllerActionButton
--     networkclientrpc.lua:356 ControllerAttackButton / :369 StopControl / :380 StopAllControls
--     networkclientrpc.lua:1100 RepeatHeldAction / :1107 ClearActionHold / :1129 DoActionOnMap
--   ★★ 参见 components/locomotor.lua —— 本文件只发意图，locomotor 才产生位移
--     locomotor.lua:782 PreviewAction（★ 客户端预测的动画+位移入口）
--     locomotor.lua:882 PushAction（服务端权威执行入口）
--     locomotor.lua:1091 Stop / :755 Clear（★ Clear 会额外清 bufferedaction）
--     locomotor.lua:1141 RunInDirection / :705 SetMoveDir / :741 WalkForward
--     locomotor.lua:1078 SetBufferedAction / :403 GetTimeMoving / :452 PopOverrideTimeMoving
--     locomotor.lua:461 RestartPredictMoveTimer / :465 CancelPredictMoveTimer /
--     locomotor.lua:469 OverridePredictTimer（★ 预测移动的「超时自杀」三件套）
--     locomotor.lua:1396 StartHopping / :1222 GetHopDistance / :1200 SetAllowPlatformHopping
--     locomotor.lua:593 GetRunSpeed / :982 与 :1040 GoToEntity/GoToPoint
--     locomotor.lua:1087 反向调用本文件 OnLocomotorBufferedAction
--     locomotor.lua:930 反向调用本文件 GetRemotePredictPositionExternal
--   ★★ 参见 components/playeractionpicker.lua —— 「这一刻能做什么」的真正实现
--     playeractionpicker.lua:301 GetLeftClickActions / :388 GetRightClickActions
--     playeractionpicker.lua:207 GetPointActions / :225 GetPointSpecialActions
--     playeractionpicker.lua:240 GetDoubleClickActions / :257 GetInventoryActions
--     playeractionpicker.lua:142 GetUseItemActions / :109 GetSceneActions
--     playeractionpicker.lua:498 DoGetMouseActions（★ LMB+RMB 一次算完）
--   ★★ 参见 actions.lua / bufferedaction.lua —— 动作原型与执行实例
--     actions.lua:357 ACTIONS 表（ACTIONS[k] 与 TOOLACTIONS 的键名对应）
--     bufferedaction.lua:1 BufferedAction（★ 冻结 doer/target/invobject/pos）
--     bufferedaction.lua:14 self.options（★ DoAction/RepeatHeldAction 往里塞临时标志）
--     componentactions.lua:3181 CollectActions（condition 的等价物在这里）
--     componentactions.lua:463 HasAOETargeting 的一个消费点
--   ★★ 参见 entityscript.lua —— bufferedaction 的宿主
--     entityscript.lua:1609 PushBufferedAction / :1654 PerformBufferedAction
--     entityscript.lua:1689 GetBufferedAction / :1563 ClearBufferedAction
--     entityscript.lua:1794 CanDoAction（最终鉴权）
--   ★★ 参见 stategraphs/SGwilson.lua / SGwilson_client.lua —— 动画与 busy 判定
--     SGwilson.lua:1319 sg.mem.localchainattack（★ 3110 行读的就是这个）
--     SGwilson.lua:4326 HUNGRY_THRESH（饥饿的动画阈值，与减速无关）
--   ★★ 参见 prefabs/player_classified.lua —— 服务端→客户端的同步载体
--     player_classified.lua:1602 busyremoteoverridelocomote（--WASD）
--     player_classified.lua:1603 busyremoteoverridelocomoteclick（--L.click）
--     player_classified.lua:1467 ismapcontrolsvisible
--   ★★ 参见 components/combat.lua / combat_replica.lua —— 攻击合法性
--     combat.lua:348 IsRecentTarget / :471 SetTarget / :747 CanTarget / :1321 IsAlly
--     combat_replica.lua:82 GetAttackRangeWithWeapon / :311 CanTarget
--   ★★ 参见 screens/mapscreen.lua —— 地图动作的另一侧
--     mapscreen.lua:1361-1362 反向设置 playercontroller._hack_ignore_held_controls
--     mapscreen.lua:1313 mapscreen 自己也有一份 _hack_ignore_ups_for
--   参见 simutil.lua:31 FindEntity（空间查询的通用封装，本文件用了 12 次）
--   参见 util.lua:553 distsq / mathutil.lua:81 DiffAngle / :90 DiffAngleRad
--   参见 constants.lua:2183 TOOLACTIONS（8 个工具动作的标签约定）
--   参见 constants.lua:2306 DOUBLE_CLICK_TIMEOUT=.5 / :2307 DOUBLE_CLICK_POS_THRESHOLD=3
--   参见 bug-patterns.md B8（★ remote_vector.y 一字段三语义，本文件的重灾区）
--   参见 04-联机同步-模组系统-UI.md「移动预测链路」章节
--============================================================
--============================================================
-- 【第一段】1-620 行：常量 / 工具函数 / 生命周期 / 输入总入口 OnControl
--============================================================
local START_DRAG_TIME = 8 * FRAMES
--【BUTTON_REPEAT_COOLDOWN = .5】按住攻击键的最小重发间隔（秒）。
--   这个值是 remote_controls 的**倒计时初值**（1362/1368/1965/2355 行都会用它）。
--   为什么要半秒：手柄扳机按下会自动连发，若不加冷却，一个长按会在几百毫秒内
--   灌进几十个 ATTACK RPC，直接把服务端的 attack_buffer 打爆。
--   参见 2607 行的 ACTION_REPEAT_COOLDOWN=0.2（长按重复走动作的间隔，更短）。
local BUTTON_REPEAT_COOLDOWN = .5
--【ACTION_REPEAT_COOLDOWN = 0.2】长按重复执行「上一次动作」的重入冷却。
--   比 BUTTON_REPEAT_COOLDOWN 短，因为长按重复的是**同一个**动作（挖掘/砍树），
--   语义上等价于玩家的连续操作，不需要防刷。
--   ★ 注意 2609 行在重发前会写 lastheldaction.options.no_predict_fastforward = true，
--   这是为了避免重复动作触发客户端动画快进（吃本地资源却不同步）。
local ACTION_REPEAT_COOLDOWN = 0.2
--【INVENTORY_ACTIONHOLD_REPEAT_COOLDOWN = 0.8】手柄在库存格上长按的重复间隔。
--   比 0.2 长 4 倍：库存格动作（吃/装备/丢弃）的动画节奏由角色 prefab 决定，
--   转太快会出现「嘴还在嚼就已经吞下 4 个」的视觉穿帮。
local INVENTORY_ACTIONHOLD_REPEAT_COOLDOWN = 0.8
--【BUFFERED_CASTAOE_TIME = .5】法杖/法术书 AOE 施法后，方向键仍不打断该动作的宽限期。
--   写在 5903 行 recent_bufferedaction.t 里。施法有前摇，摇杆会持续偏向玩家按下的方向，
--   若不放宽限，DoDirectWalking 会在 4518 行把施法打断。
local BUFFERED_CASTAOE_TIME = .5
--【BUFFERED_ACTION_NO_CANCEL_TIME = FRAMES + .0001】普通动作的**最小不可取消窗口**。
--   FRAMES 即 1/30 秒（见 constants.lua）。加 .0001 是浮点保护：
--   若某帧 dt 恰好等于 FRAMES，`self.recent_bufferedaction.t > dt` 会因精度失败。
--   ⇒ 这个字段（recent_bufferedaction.t）是 DoDirectWalking:4322 判定的依据：
--     「方向键是**先于**动作按下才松开的」→ 不取消动作。
--   ★ 这是玩家手感的关键：一个 33ms 的窗口刚好跨过「按住方向 + 点鼠标」的常见时序。
local BUFFERED_ACTION_NO_CANCEL_TIME = FRAMES + .0001
--【CONTROLLER_TARGETING_LOCK_TIME = 1.0】手柄目标锁定的持续时长（秒）。
--   ⚠ 疑似缺陷（死常量）：grep 全文只有这一处赋值，128-131 行的目标锁定实现
--   全部改成了「玩家手动 Toggle + 列表循环」模式（CONTROL_TARGET_LOCK，711 行），
--   不再依赖任何定时器。因此此常量已失效但未删除。
--   推理依据：grep -n CONTROLLER_TARGETING_LOCK_TIME 只命中第 7 行。
local CONTROLLER_TARGETING_LOCK_TIME = 1.0
--【★ RUBBER_BAND_PING_TOLERANCE_IN_SECONDS = 0.7】橡皮筋的距离预算时间。
--   只在 3870 行用一次：站在**移动的船上**跳向对岸时，允许的额外跳距 =
--     0.7 秒 × 船速 × (跳跃方向·船移动方向的余弦)。
--   为什么需要：船在动，玩家点对岸，客户端算出的落点基于「船静止」的世界坐标，
--   但服务端执行时船已经往前走了；若不补偿，合法跳会被判为「跳太远」而丢弃。
--   ⇒ 理解方式：这是把**一整个 RTT 的船位移**折算成距离预算。
local RUBBER_BAND_PING_TOLERANCE_IN_SECONDS = 0.7
--【★ RUBBER_BAND_DISTANCE = 4】预测误差容忍上限（单位）。
--   在两处使用，语义不同：
--     · 4082 行：服务器每帧比较「服务器当前位置」与「客户端预测目标点」，
--       平方距离 > 16 就放弃预测，让服务器权威位置胜出。
--     · 3876 行：作为跳跃距离的基线预算（+平台速度补偿 + 跳跃距离）。
--   为什么是 4：DST 单帧跑 30 帧，一帧位移约 0.15；4 单位 ≈ 26 帧 ≈ 0.9 秒的滞后。
--   ⇒ 换算：普通宽带 RTT 100ms 完全在预算内；跨洲 300ms 才会频繁触发。
local RUBBER_BAND_DISTANCE = 4
--【预计算平方】避免每帧重复乘法。4082 行用 RUBBER_BAND_DISTANCE_SQ 而不是
--   距离本身，因为比较平方距离不需要开根号。
local RUBBER_BAND_DISTANCE_SQ = RUBBER_BAND_DISTANCE * RUBBER_BAND_DISTANCE
--【PREDICT_STOP_ERROR_DISTANCE_SQ = 0.25】预测停止时的位置微调容差（平方）。
--   两处使用：
--     · 4098 行：客户端停下后，服务器若已在 0.5 单位内就把玩家吸到停止点。
--     · 5783 行：非 remote_authority 玩家在执行动作前，允许的对齐距离上限。
--   ⇒ 0.25 平方 = 0.5 单位 = 约 1/3 个身位，属于「看不出来的误差」。
--   ★ 对比 4012 行的 stopdistancesq（0.05/0.0001）—— 那里是**每帧**的收敛阈值，
--     比这里严格 5 倍，因为它是持续收敛判据而不是一次性微调。
local PREDICT_STOP_ERROR_DISTANCE_SQ = 0.25

--【OnPlayerActivated】事件回调 → 转发给 Activate。
--   事件名带 player 前缀，说明这是 prefab 侧主动 PushEvent 进来的。
local function OnPlayerActivated(inst)
    inst.components.playercontroller:Activate()
end

--【OnPlayerDeactivated】对称的停用回调。见 313-346 行的 Activate 实现。
local function OnPlayerDeactivated(inst)
    inst.components.playercontroller:Deactivate()
end

--★★ 【GetWorldControllerVector】手柄左摇杆 → 世界空间方向向量。**核心输入函数**。
--   它做两件事：
--   ①【屏幕空间 → 世界空间】摇杆给出的是「屏幕右 / 屏幕下」，
--      乘以相机的右向量与下向量后得到世界方向。取负号是因为「按下」= -Y 方向。
--   ★ 为什么不能直接用摇杆的 x/y：相机可以任意旋转/缩放（俯视角可 45°），
--     摇杆的「上」在屏幕上始终向上，但世界里的「前」会随镜头变。
--   ②【死区】24 行 deadzone 用的是 TUNING.CONTROLLER_DEADZONE_RADIUS。
--     ⚠ 注意判据是 `abs(x)>=deadzone or abs(y>=deadzone)` —— **或**，不是「与」。
--       这意味着斜向轻推（x=0.1,y=0.1，死区 0.2）已经不满足 or 的两个条件，
--       但斜向轻推（x=0.25,y=0.25）满足，会被当成有效输入并**归一化**成满速。
--     ⇒ 后果：玩家轻轻斜推就得到最大速度，而直推需要推过死区才启动。
--       这是「手柄斜向灵敏」的根因，不是 bug 而是手感取舍。
--   ③【归一化】27 行 GetNormalized() 让斜推也得到单位向量，
--     ⇒ 速度大小由 locomotor 的 runspeed 决定，不由摇杆幅度决定。
--     ★ 所以 DST 手柄没有「模拟量移动」，只有「方向 + 固定速度」。
--   返回 nil 表示「没推」，调用方（DoDirectWalking:4317、DoBoatSteering:4167、
--   DoDoubleTapDir:4235、DoClientBusyOverrideLocomote:3977）据此判断停止。
local function GetWorldControllerVector()
    local xdir = TheInput:GetAnalogControlValue(CONTROL_MOVE_RIGHT) - TheInput:GetAnalogControlValue(CONTROL_MOVE_LEFT)
    local ydir = TheInput:GetAnalogControlValue(CONTROL_MOVE_UP) - TheInput:GetAnalogControlValue(CONTROL_MOVE_DOWN)
--   ⚠ 这里的缩进是 Tab（与周围 4 空格不一致），说明是后期插入的补丁行。
	local deadzone = TUNING.CONTROLLER_DEADZONE_RADIUS
    if math.abs(xdir) >= deadzone or math.abs(ydir) >= deadzone then
        local dir = TheCamera:GetRightVec() * xdir - TheCamera:GetDownVec() * ydir
        return dir:GetNormalized()
    end
end

--【HasItemSlots】是否拥有背包格子。**猴补（monkey patch）模式的第一段**。
--   ★ 设计意图：GetPickupAction:2036 要判断「玩家能不能捡东西」，
--     而这个值来自 replica.inventory。副本在客户端可能还没同步好。
--     做法是先把 self.HasItemSlots 指向 CacheHasItemSlots（35 行），
--     第一次调用时算出真值，然后**把 self.HasItemSlots 换成普通函数 HasItemSlots**，
--     之后每次调用都是一次字段读取。
--   ⇒ 这是一个「首次访问付代价、之后零成本」的一次性初始化惯用法。
local function HasItemSlots(self)
    return self._hasitemslots
end

--【CacheHasItemSlots】惰性求值 + 自我替换。
--   36 行 `self.HasItemSlots = HasItemSlots` 就是「替换掉我自己」——
--   之后 self.HasItemSlots 直接指向 31 行的纯读取版本。
--   ★ 注意 37 行用了 replica.inventory（副本组件）而非 components.inventory：
--     这个判断必须在**双端**都能算出相同答案，否则客户端能捡服务端不能捡。
local function CacheHasItemSlots(self)
    self.HasItemSlots = HasItemSlots
    self._hasitemslots = self.inst.replica.inventory:GetNumSlots() > 0
    return self._hasitemslots
end

--【OnEquipChanged】装备变化 → 维护「草帽建造网格」的放置器。
--   41-55 行的 `(self.gridplacer ~= nil) == not ...:EquipHasTag("turfhat")`
--   是一个刻意写得**难以读**的等价布尔：
--     「有放置器」 应等价于 「没戴草帽」。写成两者的 == 让意图对称，
--     但代价是必须倒读。
local function OnEquipChanged(inst)
--   ★★ 只有 `inst == ThePlayer` 才处理：gridplacer 是**纯本地表现**，
--     其他玩家的草帽网格不该被创建（会浪费一份放置器实体）。
    if inst == ThePlayer then
        local self = inst.components.playercontroller
--   -- EquipHasTag("turfhat")：戴草帽时网格**关闭**（草帽自带一个格子覆盖它）。
--   -- 参见 prefabs 里的 turfhat，它是一个 EQUIPSLOTS.HEAD 的覆盖装备。
        if self and (self.gridplacer ~= nil) == not inst.replica.inventory:EquipHasTag("turfhat") then
            if self.gridplacer then
                self.gridplacer:SetPlayer(nil)
                self.gridplacer:Remove()
                self.gridplacer = nil
            else
--   50 行注意第三个参数传了 self.inst.userid —— SpawnPrefab 的第 3/4 参数是
--     networked（是否联网）+ owner。放置器与玩家绑定，避免别人删掉你的草帽网格。
                self.gridplacer = SpawnPrefab("gridplacer_turfhat")
                self.gridplacer:SetPlayer(self.inst)
            end
        end
    end
end

--【OnInit】延迟一帧执行的初始化（180 行 DoTaskInTime(0, ...) 的回调）。
--   ★ 为什么延迟一帧：构造函数运行时 replica 组件可能还没挂上（尤其客户端接收
--     玩家实体的瞬间），强行访问会 nil 索引崩溃。
local function OnInit(inst, self)
    inst:ListenForEvent("equip", OnEquipChanged)
    inst:ListenForEvent("unequip", OnEquipChanged)
--   --V2C：以下三个分支是**纯客户端**逻辑。英文原注释保留了 K 自己的解释：
--   -- "Client only event, because when inventory is closed, we will stop
--   --  getting "equip" and "unequip" events, but we can also assume that
--   --  our inventory is emptied."
--   → 翻译：库存界面关闭后客户端会**停止收到** equip/unequip 事件，
--     但此时背包必然已清空，所以要**手动补一次** OnEquipChanged 来拆掉草帽网格。
--   ⇒ 这是一个「客户端的事件系统不对称，用轮询补偿」的典型。
    if not TheWorld.ismastersim then
        --Client only event, because when inventory is closed, we will stop
        --getting "equip" and "unequip" events, but we can also assume that
        --our inventory is emptied.
        inst:ListenForEvent("inventoryclosed", OnEquipChanged)
--   ⚠ 65-68 行：副本还没到就直接 return，**OnEquipChanged(inst) 不会被调用**。
--     这意味着新生成的客户端玩家，前几帧可能既没有 gridplacer 也没有正确清理。
--     推理依据：--V2C: clients c_spawning characters ...grrrr 这句注释本身就
--     承认这是一个已知的、让他们「有点抓狂」的状态。
        if inst.replica.inventory == nil then
            --V2C: clients c_spawning characters ...grrrr
            return
        end
    end
    OnEquipChanged(inst)
end

--★★ 【PlayerController 构造器】Class(function(self, inst) ...)
--   双端各有一个实例。本段（74-155）几乎全是**字段初始化**，但每个字段都是
--   一条协议的一半，务必对照文件头「四个字段族」来读。
local PlayerController = Class(function(self, inst)
    self.inst = inst

--   --cache variables：以下三项被**高频**读取（每帧甚至每按钮），
--     缓存为局部字段避免多次 metatable 查找。
    --cache variables
    self.map = TheWorld.Map
--   ★ ismastersim 是**整个文件最关键的分流标志**，出现 60+ 次。
--     它决定了：谁读 TheInput、谁能发 RPC、谁驱动 locomotor、谁能改组件。
    self.ismastersim = TheWorld.ismastersim
--   ★ locomotor 在构造时就缓存（而不是每次 self.inst.components.locomotor）。
--     注意它**可能为 nil**：无 locomotor 的实体（如某些召唤物）也能挂本组件，
--     整个文件因此有 40+ 处 `self.locomotor == nil` 判定。
--     ⇒ 这个 nil 不是异常，是「非行走单位也复用本组件」的设计结果。
    self.locomotor = self.inst.components.locomotor
    self.HasItemSlots = CacheHasItemSlots

    --attack control variables
--   attack_buffer：攻击请求的**延迟缓冲**。不是普通队列，是「存一个，待会儿执行」。
--     ★ 存进去的可能不是 BufferedAction 而是 CONTROL_ATTACK 这样的**枚举常量**
--       （636/673 行），OnUpdate:2777 会分派。这就是「按键也要走缓冲」的证据。
    self.attack_buffer = nil
    self.controller_attack_override = nil

    --remote control variables
--★★ remote_vector：远端玩家的「移动意图信封」。★ 参见 3694 行顶部注释。
--   Vector3 的三个分量在本文件里被重载：
--     x / z —— 含义取决于 y（方向向量 or 目标坐标，见文件头表格）
--     y     —— 移动模式标签（0/1/2/3/4/5/6），★ 同时在 y>=3 时充当真实高度
--   ★★★ platform —— 关键！这是**后加的第四个字段**（Vector3 上挂的额外属性）。
--     它表示 x/z 是「该平台的局部坐标」而非世界坐标。3791/3925 行设置。
--     ⚠ 这就是 bug-patterns B8 说的「platform 参数是后期补上的，代码里到处是补丁」。
    self.remote_vector = Vector3()
--   remote_predict_dir：服务器当前正在追的预测方向（弧度）。
--     4039 行用它做「过冲检测」：新方向与旧方向差 ≥90° ⇒ 玩家改主意了 ⇒ 直接瞬移。
	self.remote_predict_dir = nil
--   --used when server detected no more movement (NOTE: could be client running up against obstacle)
--   → K 自己的注释就点明了歧义：服务器看到「不走了」有两种可能：
--     (a) 玩家真的停了； (b) 客户端预测撞墙停住了，但服务器这边墙还没生效。
--   ⇒ 4095-4105 行的处理是**折中**：下一帧若服务器已在停止点附近就吸附过去，否则放弃。
	self.remote_predict_stop_tick = nil --used when server detected no more movement (NOTE: could be client running up against obstacle)
--   remote_predict_stop_notified：客户端**明确告知**「我停了」的标志。
--     ★ 与 _stop_tick 的区别：_stop_tick 是「服务器自己发现的」，
--       _notified 是「客户端说出来的」。3794/3812 行赋值。
--     二者的配合解决的是「客户端停 → 服务端还在跑」这个经典预测失配。
	self.remote_predict_stop_notified = nil --server received explicit notification that client has stopped moving
--   client_last_predict_walk = { tick, direct }：客户端最后一次发预测的位置与时刻。
--     ★ 与已废弃的 self.predictionsent（106 行）并存 —— 见 106 行注释。
	self.client_last_predict_walk = { tick = nil, direct = false }
    self.remote_controls = {}
--   remote_predicting：**服务端**是否开启客户端预测。
--     ★ 只有它为 true，networkclientrpc.lua:455 才会放行 PredictWalking RPC。
--       它由 PlayerController:OnRemoteToggleMovementPrediction（5920 行）设置，
--       而那个函数是**服务端本地**调用（连 OnRemote 前缀都没有）。
--     ⇒ 也就是说：预测开关是服务端单方面决定的，客户端只是被告知。
	self.remote_predicting = false
--★★ remote_authority —— 见文件头的详细说明。这里只强调：它是「信任位」。
--   IsConsole()：主机（房主）在自己的客户端上也跑 mastersim，行为特殊。
	self.remote_authority = IsConsole()
	if not self.remote_authority then
--   GetClientTableForUser(self.inst.userid)：查该玩家的连接元数据。
--   admin/moderator/friend 三者任一为真即获得信任。
--   ⚠ 疑似缺陷：friend 是**社交关系**，不是权限。好友客户端可无条件硬瞬移。
--     推理依据：97 行 `client.admin or client.moderator or client.friend`——
--     若这是权限判定，不该包含 friend；Klei 把它当「熟人可信」而非权限。
--     后果：任一房主的好友（不需要管理权限）即可获得无校验瞬移能力。
		local client = TheNet:GetClientTableForUser(self.inst.userid)
		self.remote_authority = client and (client.admin or client.moderator or client.friend)
	end

	--locomotor buffered action instant cancelling prevention
--   recent_bufferedaction：松手护栏。见 4319-4343 行的完整逻辑。
--     结构：{ act（上一个缓冲动作）, t（剩余保护时间）, x, z（按下时的摇杆方向）}。
	self.recent_bufferedaction = {}

--   ★ 三个互斥的手势标志 directwalking / dragwalking / predictwalking。
--     它们不是「移动方式」，而是「**输入来源**」，且贯穿双端：
--       客户端：按住了方向键 / 按住了鼠标左键拖 / 点了地面走过去
--       服务端：由 remote_vector.y 反推（4054-4075 行）
--   ⇒ 关键用途：1826 行「自动行走时攻击范围 +6」就靠 directwalking 判断；
--     2135/2203/2262 行的 FindEntity 半径也靠它（在 3 和 6 之间二选一）。
    self.dragwalking = false
    self.directwalking = false
    self.predictwalking = false
--   --deprecated, see self.client_last_predict_walk
--   ⇒ 废弃但**未删除**：3005 行仍在读它（`self.remote_vector.y >= 3` 的 nopredict 分支
--     之后没有清它），323 行/369 行还在重置它。属于无害的历史残留。
	self.predictionsent = false --deprecated, see self.client_last_predict_walk
    self.draggingonground = false
    self.is_hopping = false
    self.startdragtestpos = nil
    self.startdragtime = nil
	self.startdoubleclicktime = nil
	self.startdoubleclickpos = nil
	self.doubletapmem = { down = false }
--   isclientcontrollerattached：手柄热插拔标志。TUNING/Profile 之外的自持状态。
--     395-407 行 ToggleController 负责同步它。
    self.isclientcontrollerattached = false

--   mousetimeout = 10：10 秒无鼠标操作后……（grep 本文件后续使用，
--     实际超时判定在 HUD 侧的输入处理里，这里只是初值占位）。
    self.mousetimeout = 10
    self.time_direct_walking = 0

--   ★ controller_target：手柄「Y 键」选中的交互目标（对应鼠标的 LMB/RMB 高亮）。
--   ★ controller_attack_target：手柄「X 键」选中的攻击目标。
--     两者的区别是本文件 3178-3601 那 260 行存在的全部理由。
    self.controller_target = nil
--   controller_target_age = math.huge：目标的「年龄」。
--     ★ 3381 行用它做 **0.2 秒防抖**：目标刚变（age=0）时先冻结 0.2 秒再重新评估。
--     为什么要防抖：手柄瞄准在两个候选边缘来回时会疯狂跳目标，
--     0.2 秒的滞回让瞄准「粘住」而不是抽搐。
    self.controller_target_age = math.huge
    self.controller_attack_target = nil
--   controller_attack_target_ally_cd：**友方目标冷却**。
--     ★ 机制：手柄瞄准友军时默认不想打，但偶尔需要（AOE/误伤），
--       于是设一个 ~1 秒的冷却，冷却内友军分数 ×0.25（3268 行）。
--     初始值 nil，3198 行 `math.max(0, (cd or 1) - dt)` 让它首次进入时为 1 秒。
    self.controller_attack_target_ally_cd = nil
    --self.controller_attack_target_age = math.huge

--   -- CharlesB: For now this is always off
--   ⇒ 目标锁定的「按住修饰键」模式被弃用，改为「按一下 Toggle」（711 行 CONTROL_TARGET_LOCK）。
	-- CharlesB: For now this is always off
	--self.controller_targeting_modifier_down = false
	--self.controller_targeting_lock_timer = nil
--   controller_targeting_lock_available = Profile:GetTargetLockingEnabled()
--   ★ 这是**玩家档案级设置**，不是联机同步量。⇒ 两端各自读本地 Profile，
--     理论上可能不一致（但 Profile 在联机开始时会同步，故实践中安全）。
	self.controller_targeting_lock_available = Profile:GetTargetLockingEnabled() -- can target locking be used at all or is it disabled in the profile
	self.controller_targeting_lock_target = false
	self.controller_targeting_targets = {}
	self.controller_targeting_target_index = nil
--   command_wheel_allows_gameplay：指令轮盘打开时是否仍允许移动/操作。
--     499 行 IsEnabled 用它决定返回的第二个布尔值。
	self.command_wheel_allows_gameplay = Profile:GetCommandWheelAllowsGameplay() -- does the command wheel block all other gameplay or can you do other things, like move around, while it is open

    self.reticule = nil
    self.terraformer = nil
--   deploy_mode = not TheInput:ControllerAttached()：鼠标模式默认可进入放置态。
--     ★ 注意它是「未插手柄时为真」——因为鼠标右键就是「放置预览」的位置。
    self.deploy_mode = not TheInput:ControllerAttached()
    self.deployplacer = nil
    self.placer = nil
    self.placer_recipe = nil
    self.placer_recipe_skin = nil
    self.placer_cached = nil

--   ★ LMBaction / RMBaction：**鼠标左/右键当前对应的动作缓存**。
--     由 2827 行 playeractionpicker:DoGetMouseActions 每帧刷新。
--     它是「鼠标指向」的唯一真相来源：GetLeftMouseAction/GetRightMouseAction
--     只是它的 getter（5321/5325 行）。
    self.LMBaction = nil
    self.RMBaction = nil

--   handler ~= nil ⇔ 「我控制这台客户端」。★ 全文件最重要的一句话。
--     handler 只在 319 行（ThePlayer）赋值，345/365 行清除。
--     几乎每个 Remote*On* 的守卫都是 `self.ismastersim and self:IsEnabled() and self.handler == nil`，
--     即「我是服务器、玩家已激活、且我不是这台机器的本地玩家」。
    self.handler = nil
    self.actionbuttonoverride = nil

    --self.actionholding = false
    --self.actionholdtime = nil
    --self.lastheldaction = nil
    --self.actionrepeatfunction = nil
--   heldactioncooldown：长按重复的冷却计时器（由 OnUpdate:3010 每帧递减）。
    self.heldactioncooldown = 0

--   ★ remoteinteractionaction/target/pos：把「玩家正在对谁做什么」广播给 AI。
--     消费方全是 brain：mermbrain / wx78_possessedbodybrain / eater / trader /
--     container_transform / wagdrone_rollingbrain / wobycommon。
--     ⇒ 动机：美人鱼鱼人需要「玩家正在喂我」才能配合，
--       温蒂附身的身体需要跟随主人的动作。纯 AI 协作，零玩家可见。
	self.remoteinteractionaction = nil
	self.remoteinteractiontarget = nil
    self.remoteinteractionpos = nil

--★★ 【双端初始化分叉】159-175 行是理解整个文件的枢纽。
--   服务端（159-164）：挂 classified 句柄、启动**每帧更新**与**每墙钟更新**。
--   客户端（165-175）：
--     · 只注册 _clearinteractiontarget 回调（166-171）
--     · 若 classified 还没到，先挂上（172-174）
--   ★ 注意：客户端**没有** StartUpdatingComponent（那在 335 行的 Activate 里，
--     因为那时才确认自己是 ThePlayer）。
    if self.ismastersim then
        self.is_map_enabled = true
        self.can_use_map = true
--   classified = inst.player_classified：服务端的「客户端可见数据」对象。
--     它是 net_bool / net_tinybyte 的集合（iscontrollerenabled、
--     ismapcontrolsvisible、busyremoteoverridelocomote 等）。
--     ★ 参见 prefabs/player_classified.lua —— 本文件所有 classified.X:value()
--       读的都是服务端写、客户端只读的单向同步量。
        self.classified = inst.player_classified
--   StartUpdatingComponent(self) → 每帧调用 OnUpdate(2650 行)。
--   ★ 客户端的 StartUpdatingComponent 在 335 行（Activate 内）——因为客户端只有
--     本机玩家需要每帧算移动意图，其他玩家的移动由 RPC 驱动。
        inst:StartUpdatingComponent(self)
--   StartWallUpdatingComponent(self) → OnWallUpdate(2629 行)。
--     ★ WallUpdate 用的是**墙钟时间**（GetStaticTime）而非游戏时间，
--       所以暂停时仍会跑 —— 4438 行的相机旋转因此在暂停菜单里也能用。
        inst:StartWallUpdatingComponent(self)
	else
--   _clearinteractiontarget：动作成功/失败时清掉 AI 可见的交互意图。
--   --V2C 注释说明了为什么要闭包 + 双重校验：
--     「This is used by action Success/Fail callback, which doesn't know
--       if player got removed」——回调触发时玩家可能已被移除，
--     所以必须检查 self 还是当前组件、实体还有效。
--   ★ 这是防「回调晚到导致操作已销毁实体」的教科书式写法。
		self._clearinteractiontarget = function()
			--V2C: This is used by action Success/Fail callback, which doesn't know if player got removed.
			if self == inst.components.playercontroller and inst:IsValid() then
				self:RemoteInteractionTarget(nil, nil, nil)
			end
		end
--   客户端的 classified 可能比组件构造晚到（网络顺序问题），
--     所以这里做一次补偿式 AttachClassified。
		if self.classified == nil and inst.player_classified then
			self:AttachClassified(inst.player_classified)
		end
    end

--   ★ 177-178：这两个事件是**玩家 prefab 主动 Push 的**，不是引擎的。
--     与 328-343 行的 ListenForEvent 形成对比：177 行在构造函数里（双端都监听），
--     328 行在 Activate 里（只对本机玩家）。
    inst:ListenForEvent("playeractivated", OnPlayerActivated)
    inst:ListenForEvent("playerdeactivated", OnPlayerDeactivated)

--   ★ DoTaskInTime(0, OnInit, self) —— 下一帧才初始化，理由见 57 行上方。
--     181 行 end 是 Class 构造器的结束。
    inst:DoTaskInTime(0, OnInit, self)
end)

--------------------------------------------------------------------------

--【OnRemoveFromEntity】组件从实体上卸载时的清理。
--   ★ 199 行的 `PlayerController.OnRemoveEntity = PlayerController.OnRemoveFromEntity`
--     是**双命名兼容**：Class 销毁器调 OnRemoveFromEntity，
--     而实体销毁路径调 OnRemoveEntity。指向同一函数体。
function PlayerController:OnRemoveFromEntity()
    self.inst:RemoveEventCallback("playeractivated", OnPlayerActivated)
    self.inst:RemoveEventCallback("playerdeactivated", OnPlayerDeactivated)
    self:Deactivate()
    if self.classified ~= nil then
        if self.ismastersim then
            self.classified = nil
        else
            self.inst:RemoveEventCallback("onremove", self.ondetachclassified, self.classified)
            self:DetachClassified()
        end
    end
end

PlayerController.OnRemoveEntity = PlayerController.OnRemoveFromEntity

--【AttachClassified】绑定 classified 并监听它的 onremove。
--   ★ 用独立函数而不是闭包，是为了 193 行能 RemoveEventCallback 精确解绑。
function PlayerController:AttachClassified(classified)
    self.classified = classified
    self.ondetachclassified = function() self:DetachClassified() end
    self.inst:ListenForEvent("onremove", self.ondetachclassified, classified)
end

function PlayerController:DetachClassified()
    self.classified = nil
    self.ondetachclassified = nil
end

--------------------------------------------------------------------------

--【OnBuild】建造完成事件 → 取消放置预览。
--   ★ 这是一个**服务端权威**的信号：客户端只是收到事件后清理本地预览。
local function OnBuild(inst)
    inst.components.playercontroller:CancelPlacement()
end

--【OnEquip】装备到手上 → 切换准星（reticule）。
--   ★ reticule 是「指向哪」的视觉反馈载体，可能是：
--     · 玩家默认的（inst.components.reticule）
--     · 物品自带的（data.item.components.reticule，如火把/魔杖）
--   它是「瞄准」这件事的**表现层**，与 target 计算完全解耦。
local function OnEquip(inst, data)
    --Reticule targeting items
--   只处理 HANDS（手上）槽位。EQUIPSLOTS 定义见 constants.lua。
    if data.eslot == EQUIPSLOTS.HANDS then
        local self = inst.components.playercontroller
--   ★★ 法术书特例：手持法术书时**忽略 equip 事件**。
--     理由：法术书的准星由 spellbook 组件自己管，若在这里把 reticule 换掉，
--     会与法术轮盘的选中态冲突。这是「同一件东西不能有两个准星所有者」的仲裁。
		if self.reticule ~= nil and self.reticule.inst.components.spellbook ~= nil then
			--Ignore when targeting with spellbook
			return
--   AOE 武器（魔杖类）：equip 时强制 StopTargeting，
--     因为 AOE 施法需要「举着手杖不动」，切手会打断。
		elseif data.item.components.aoetargeting ~= nil and data.item.components.aoetargeting:IsEnabled() then
            if self.reticule ~= nil then
                self.reticule:DestroyReticule()
                self.reticule = nil
            end
            data.item.components.aoetargeting:StopTargeting()
        else
--   ★ newreticule = 物品自己的 或 玩家默认的。优先级：物品 > 玩家。
--     这让模组可以给物品挂专属准星而不必改 playercontroller。
            local newreticule = data.item.components.reticule or inst.components.reticule
            if newreticule ~= self.reticule then
                if self.reticule ~= nil then
                    self.reticule:DestroyReticule()
                end
                self.reticule = newreticule
--   238 行的 `(newreticule.mouseenabled or TheInput:ControllerAttached())`：
--     ★ 鼠标玩家 + 准星不跟随鼠标（如工具自带固定准星）→ 不创建。
--     手柄玩家 → 一律创建（手柄没有鼠标位置，准星必须是方向指示器）。
                if newreticule ~= nil and newreticule.reticule == nil and (newreticule.mouseenabled or TheInput:ControllerAttached()) then
                    newreticule:CreateReticule()
--   创建后若「当前不可操作」（!IsEnabled）或「该准星要求隐藏」（ShouldHide）→ 隐藏。
					if newreticule.reticule ~= nil and (not self:IsEnabled() or newreticule:ShouldHide()) then
						newreticule.reticule:Hide()
					end
                end
            end
        end
    end
end

--【OnUnequip】与 OnEquip 对称，但**多一层判断**（257-259）。
--   259 行 `equip == nil or self.reticule ~= equip.components.retiquel`：
--     卸下的装备已经不在手上（equip 为 nil）或换成了别的东西 → 重建默认准星。
--   ★ 为什么要这么麻烦：equip 与 unequip 事件的时序不保证，
--     快速切手时可能先收到 uneq(HANDS) 再收到 equip(HANDS)，
--     这里靠「重新读一次真实装备状态」来纠正事件乱序。
local function OnUnequip(inst, data)
    --Reticule targeting items
    if data.eslot == EQUIPSLOTS.HANDS then
        local self = inst.components.playercontroller
		if self.reticule ~= nil then
			if self.reticule.inst.components.spellbook ~= nil then
				--Ignore when targeting with spellbook
				return
			elseif self.reticule ~= inst.components.reticule then
				local equip = inst.replica.inventory:GetEquippedItem(data.eslot)
				if equip == nil or self.reticule ~= equip.components.reticule then
					self.reticule:DestroyReticule()
					self.reticule = inst.components.reticule
					if self.reticule ~= nil and self.reticule.reticule == nil and (self.reticule.mouseenabled or TheInput:ControllerAttached()) then
						self.reticule:CreateReticule()
						if self.reticule.reticule ~= nil and (not self:IsEnabled() or self.reticule:ShouldHide()) then
							self.reticule.reticule:Hide()
						end
					end
				end
			end
		end
    end
end

--【OnInventoryClosed】关库存 → 拆掉一切瞄准态。
--   ★ 必须 CancelAOETargeting：如果玩家在举魔杖瞄准时按了关库存，
--     AOE 目标点会永久停在旧位置（因为拿不到新的鼠标输入）。
local function OnInventoryClosed(inst)
    --Reticule targeting items
    local self = inst.components.playercontroller
	self:CancelAOETargeting()
    if self.reticule ~= nil then
        self.reticule:DestroyReticule()
        self.reticule = nil
    end
end

--【OnZoom】滚轮缩放。默认步长 6。
--   ★ 为什么放在 playercontroller 而不是 camera：滚轮键位可被手柄抢占
--     （CONTROL_ZOOM_IN/OUT），两边的映射冲突判定在 303-304 行。
local function OnZoom(inst, data)
    if data.zoomout then
        TheCamera:ZoomOut(data.zoom or 6)
    else
        TheCamera:ZoomIn(data.zoom or 6)
    end
end

local function OnNewActiveItem(inst, data)
	if data ~= nil and data.item ~= nil then
		inst.components.playercontroller:CancelAOETargeting()
	end
end

--【OnContinueFromPause】从暂停恢复 / 继续游戏。
--   303-304 行：缓存「手柄 ZOOM 键是否映射到了滚轮键」。
--   ★ 为什么要缓存：4492/4497 行做缩放时，如果 ZOOM_IN 和 SCROLLBACK 是同一个键，
--     在合成菜单里滚轮会同时触发两条缩放路径 → 缩放速度翻倍。
--     缓存后可在 craftingmenu 有焦点时跳过重复的那条。
local function OnContinueFromPause()
	local self = ThePlayer.components.playercontroller
    self:ToggleController(TheInput:ControllerAttached())

	-- this caches if the camera zooming is using the same physical controls as the scroll bar scrolling
	self.zoomin_same_as_scrollup = TheInput:GetLocalizedControl(TheInput:GetControllerID(), CONTROL_ZOOM_IN) == TheInput:GetLocalizedControl(TheInput:GetControllerID(), CONTROL_SCROLLBACK)
	self.zoomout_same_as_scrolldown = TheInput:GetLocalizedControl(TheInput:GetControllerID(), CONTROL_ZOOM_OUT) == TheInput:GetLocalizedControl(TheInput:GetControllerID(), CONTROL_SCROLLFWD)
end

--【OnDeactivateWorld】★ 客户端专属，世界被重置/重生流程时清理。
--   --V2C 注释："Essential cleanup when client is notified of pending server
--   c_reset or c_regenerateworld" —— 服务端要 c_reset 时客户端必须先把手上的
--   状态（输入 handler、预测数据、准星）全部拆干净，否则新世界里会残留。
local function OnDeactivateWorld()
    --Essential cleanup when client is notified of
    --pending server c_reset or c_regenerateworld.
    ThePlayer.components.playercontroller:Deactivate()
end

--★★ 【Activate】313-346 行：把本组件「接上线」。
--   ★ 结构是一个三重互斥 if：
--     ① handler ~= nil → 已激活，若不是 ThePlayer 就先 Deactivate（独占控制权）
--     ② handler == nil 且 inst == ThePlayer → 真正激活
--     ③ handler == nil 且 inst ~= ThePlayer → 什么都不做（远端玩家的激活是空操作）
--   ⇒ 推论：handler 是**全局单例**。两个实体不可能同时是「本地玩家」。
function PlayerController:Activate()
    if self.handler ~= nil then
--   ①的控制权抢占：切角色 / 复活后 player 换了，旧 player 必须让位。
        if self.inst ~= ThePlayer then
            self:Deactivate()
        end
    elseif self.inst == ThePlayer then
--   ★★ TheInput:AddGeneralControlHandler —— 输入总线的唯一挂载点。
--     所有按键从这里进入 601 行的 OnControl。
--     「General」= 全局处理器（不是某个屏幕的局部处理器），
--     所以玩家在 crafting / map / spellwheel 打开时它**也在跑**，
--     由 OnControl 内部的 IsEnabled 决定放行哪些。
        self.handler = TheInput:AddGeneralControlHandler(function(control, value) self:OnControl(control, value) end)

        --reset the remote controllers just in case there was some old data
--   --reset the remote controllers just in case there was some old data
--   322-324：激活时必须清空远端镜像，否则会带着上一次会话的方向键状态复活。
--   ★ 3697 行 ResetRemoteController 同时清了 remote_vector.y 和 remote_controls。
        self:ResetRemoteController()
        self.predictionsent = false
        self.isclientcontrollerattached = false

        self:RefreshReticule()

--   328-343：注册七类事件。注意 331 行的 zoomcamera 是**双端**监听
--     （因为缩进在 if not ismastersim 之外），而 334-341 是纯客户端。
        self.inst:ListenForEvent("buildstructure", OnBuild)
        self.inst:ListenForEvent("equip", OnEquip)
        self.inst:ListenForEvent("unequip", OnUnequip)
        self.inst:ListenForEvent("zoomcamera", OnZoom)
        self.inst:ListenForEvent("newactiveitem", OnNewActiveItem)
--   ★ 分叉点：只有客户端才需要 StartUpdatingComponent / StartWallUpdatingComponent。
--     335/336 行的这两句与 163/164 行的服务端版本配对，构成双端对称。
        if not self.ismastersim then
            self.inst:ListenForEvent("deactivateworld", OnDeactivateWorld, TheWorld)
            self.inst:StartUpdatingComponent(self)
            self.inst:StartWallUpdatingComponent(self)

            --Client only event, because when inventory is closed, we will stop
            --getting "equip" and "unequip" events, but we can also assume that
            --our inventory is emptied.
            self.inst:ListenForEvent("inventoryclosed", OnInventoryClosed)
        end
        self.inst:ListenForEvent("continuefrompause", OnContinueFromPause, TheWorld)
--   ★ 立即调用一次 OnContinueFromPause（而不只是监听），
--     因为 Activate 发生时可能没经过「continuefrompause」事件。
        OnContinueFromPause()
    end
end

--【Deactivate】Activate 的严格镜像，按相反顺序拆除。
--   ★ 注意它也以 `if self.handler ~= nil` 为守卫 —— 保证幂等：
--     远端玩家的 Deactivate 是空操作（因为 handler 一直是 nil）。
--     这个幂等性让 188 行 OnRemoveFromEntity 可以无条件调用它。
function PlayerController:Deactivate()
    if self.handler ~= nil then
--   清理顺序有讲究：先取消所有放置/瞄准态，再拆 handler，最后清远端镜像。
--   ★ 350-352 行的三个 Cancel 是对称的（BuildPlacement / DeployPlacement / AOE）。
        self:CancelPlacement()
        self:CancelDeployPlacement()
		self:CancelAOETargeting()

        if self.terraformer ~= nil then
            self.terraformer:Remove()
            self.terraformer = nil
        end

        if self.reticule ~= nil then
            self.reticule:DestroyReticule()
            self.reticule = nil
        end

--   handler:Remove() —— 从输入总线摘除。此后 OnControl 不再被调用。
        self.handler:Remove()
        self.handler = nil

        --reset the remote controllers just in case there was some old data
        self:ResetRemoteController()
        self.predictionsent = false
        self.isclientcontrollerattached = false

        self.inst:RemoveEventCallback("buildstructure", OnBuild)
        self.inst:RemoveEventCallback("equip", OnEquip)
        self.inst:RemoveEventCallback("unequip", OnUnequip)
		self.inst:RemoveEventCallback("zoomcamera", OnZoom)
		self.inst:RemoveEventCallback("newactiveitem", OnNewActiveItem)
        self.inst:RemoveEventCallback("continuefrompause", OnContinueFromPause, TheWorld)
        if not self.ismastersim then
            self.inst:RemoveEventCallback("inventoryclosed", OnInventoryClosed)
            self.inst:RemoveEventCallback("deactivateworld", OnDeactivateWorld, TheWorld)
            self.inst:StopUpdatingComponent(self)
            self.inst:StopWallUpdatingComponent(self)
        end
    end
end

--------------------------------------------------------------------------

--【Enable(val)】服务端 → 客户端：「这个玩家的输入是否启用」。
--   ★ 391 行注意是 `set(val)` 而非 `set(val == true)`：
--     与 411/418 行的写法不一致（那两处用了 `== true` 归一化）。
--     ⚠ 疑似缺陷（轻微）：若外部传 nil，391 行会把 net_bool 写成 nil 而不是 false，
--       客户端 `:value()` 读到 nil 后在 492 行 `not nil` 为真 → 误判为「已禁用」。
--     推理依据：net_bool 的 set 是否容忍 nil 取决于 netvar 实现，
--       而同文件 411/418 行明确做了 `== true` 归一化，说明作者认为需要归一化。
function PlayerController:Enable(val)
    if self.ismastersim then
        self.classified.iscontrollerenabled:set(val)
    end
end

--【ToggleController】手柄插拔。客户端 → RPC 告知服务端。
--   396 行 `if self.isclientcontrollerattached ~= val` 保证只处理**变化**。
function PlayerController:ToggleController(val)
    if self.isclientcontrollerattached ~= val then
        self.isclientcontrollerattached = val
        if self.handler ~= nil then
            self:RefreshReticule()
        end
        if not self.ismastersim then
--   SendRPCToServer(RPC.ToggleController, val) ——
--     参见 networkclientrpc.lua:1055。★ 注意它没有用 OnRemote 前缀的处理器，
--     而是在 RPC handler 里直接调 SetCanUseMap 之类的 classified 写入。
            SendRPCToServer(RPC.ToggleController, val)
        elseif val and self.inst.components.inventory ~= nil then
            self.inst.components.inventory:ReturnActiveItem()
        end
    end
end

--【EnableMapControls / SetCanUseMap】小地图可见性（416-421 是同一对）。
--   ★ 用**两个独立布尔**交叉相乘而不是一个，是为了让「按设置」和「按当前状态」
--     能分别被远程控制而不互相覆盖（778 次外部调用可见其重要）。
--   ⚠ 但 412 行 `EnableMapControls(val and self.can_use_map)` 传的是 may-be-nil
--     （val 为 nil 时），同样有上面 391 行的归一化问题。
function PlayerController:EnableMapControls(val)
    if self.ismastersim then
        self.is_map_enabled = val == true
        self.classified:EnableMapControls(val and self.can_use_map)
    end
end

function PlayerController:SetCanUseMap(val)
    if self.ismastersim then
        self.can_use_map = val == true
        self.classified:EnableMapControls(val and self.is_map_enabled)
    end
end

--【GetMapTarget】判断某个动作是否应「改为在地图上执行」。
--   ★ 424 行的 `self.inst.HUD == nil` 检查被注释说明为：
--     "HUD check makes this client sided only but can run on server when no caves"
--     → 翻译：用 HUD 是否存在来「顺便」把服务端排除掉，但无洞穴的服务端 HUD 为 nil，
--       所以这个检查**不是可靠的端判定**，只是一个副作用。
--     ⚠ 疑似缺陷：真正的端判定应该用 self.ismastersim。
--       推理依据：注释自己承认「can run on server when no caves」，
--       而 444 行 PullUpMap 里的 NOTES(JBK) 注释又说「assuming inst is the local client」，
--       两处都承认了这里存在端判定的漏洞，只是没人修。
function PlayerController:GetMapTarget(act)
    if act == nil or act.action.map_action or self.inst.HUD == nil then -- HUD check makes this client sided only but can run on server when no caves.
        return nil
    end

--   ★ maptarget 的来源优先级：动作的 target（除非 map_only）→ 手持物。
--     428 行 `(not act.action.map_only and act.target) or act.invobject or nil`
--     用 and/or 链实现「map_only 动作不指向 target 而指向物品」。
    local maptarget = (not act.action.map_only and act.target) or act.invobject or nil
    if maptarget == nil then
        return nil
    end

--   两种豁免：动作显式声明了 maptarget（地图自己传的），
--     或目标带 action_pulls_up_map 标签（地图本身就是该动作的目标，如雕像）。
    if not act.maptarget and not maptarget:HasTag("action_pulls_up_map") then
        return nil
    end

--   valid_map_actions 是「白名单」：地图目标可以限制哪些动作在地图上做。
--   ★ 这是模组扩展点：给实体加 valid_map_actions 就能定制地图交互。
    if maptarget.valid_map_actions ~= nil and not maptarget.valid_map_actions[act.action] then
        return nil
    end

    return maptarget
end

--【PullUpTarget → PullUpMap】打开地图并把 maptarget 传进去。
--   ★ 本函数是**纯客户端 UI 操作**（大量 self.inst.HUD: 调用），
--     但它被 879/1140/4790/5031 四处从动作路径调用，而动作路径双端都跑。
--     ⇒ 靠 424/445 行的 HUD/HUD 检查与服务端无 HUD 来短路。
function PlayerController:PullUpMap(maptarget, forced_actiondef)
    if self.inst.replica.inventory then
--   先收回手持物：地图上不能手持东西操作（否则会拿着斧头开地图）。
--   449 行的 `if not IsHolding(activeitem) then return end` 是竞态防护：
--     ReturnActiveItem 可能因物品已被丢弃而失败，此时必须整体放弃。
        local activeitem = self.inst.replica.inventory:GetActiveItem()
        if activeitem then
            self.inst.replica.inventory:ReturnActiveItem()
            if not self.inst.replica.inventory:IsHolding(activeitem) then
                return
            end
        end
    end
    -- NOTES(JBK): This is assuming inst is the local client on call with a check to self.inst.HUD not being nil.
    if self.inst.HUD:IsCraftingOpen() then
        self.inst.HUD:CloseCrafting()
    end
    if self.inst.HUD:IsSpellWheelOpen() then
        self.inst.HUD:CloseSpellWheel()
    end
    if self.inst.HUD:IsControllerInventoryOpen() then
        self.inst.HUD:CloseControllerInventory()
    end
    -- Pull up map now.
    if not self.inst.HUD:IsMapScreenOpen() then
--   ★ self.skip_inherentmapaction = true —— 一个刻意的 hack：
--     ToggleMap 内部会触发 OnUpdate(0)，而 OnUpdate 会调 GetMapActions，
--     那时 mapscreen 还没拿到 maptarget，会算出一套错误的动作。
--     这个标志让那一帧的 GetMapActions 跳过内建地图动作分支（5174 行）。
--   ⇒ 设计代价：全局可变的临时标志，必须在同一函数内立即清掉（468 行）。
        self.skip_inherentmapaction = true -- Hack flag to get around the OnUpdate(0) PushScreen does before we can set the maptarget.
        self.inst.HUD.controls:ToggleMap()
        self.skip_inherentmapaction = nil
        if self.inst.HUD:IsMapScreenOpen() then -- Just in case.
            local mapscreen = TheFrontEnd:GetActiveScreen()
--   ⚠★ 疑似缺陷（跨对象字段污染）：这里设置的是 **mapscreen** 上的同名字段，
--     而 612-618 行的 OnControl 读的是 **self（playercontroller）** 的同名字段。
--     推理依据：grep 全仓，playercontroller 上的 _hack_ignore_held_controls
--       只被 screens/mapscreen.lua:1361-1362 设置（那里明确写 playercontroller.XXX）；
--       471 行写的是 mapscreen.XXX，被 mapscreen.lua:1313 自己消费。
--     结论：这两处是**两个不同对象的同名字段**，各自消费，看起来是有意为之
--       （开地图时 mapscreen 要忽略自己收到的按键；关地图时 playercontroller
--        要忽略松手事件）。但命名完全相同、语义几乎一致，极易误读。
--       建议：若要重构，先把 mapscreen 上的那份改名。
            mapscreen._hack_ignore_held_controls = 0.1
            mapscreen._hack_ignore_ups_for = {}
			mapscreen:SetNewMapTarget(maptarget, forced_actiondef and forced_actiondef.map_only and forced_actiondef)
            if maptarget then
--   map_remap_min_dist：需要先在地图上定位到一个位置才能执行的地图动作
--     （例如「在地图上标记雕像位置」）。477 行的 +0.1 是浮点保护。
                local min_dist = maptarget.map_remap_min_dist
                if min_dist then
                    min_dist = min_dist + 0.1 -- Padding for floating point precision.
                    local x, y, z = self.inst.Transform:GetWorldPosition()
                    local rotation = self.inst.Transform:GetRotation() * DEGREES
--   ★-- Z offset is negative to desired from Transform coordinates。
--     Transform 的 Z 轴与数学 Z 轴**相反**（引擎是左手系 + Z 朝屏幕内）。
--     凡是 `x + cos(rot)*d, z - sin(rot)*d` 这种写法都源于此。
--     ★ 这是本文件里最容易搞错符号的地方：
--       4034 行 atan2(z0-pt.z, pt.x-x0)、4360 行 -atan2(dir.z,dir.x)、
--       1654 行 atan2(-dir.z, dir.x) —— 全是这个符号约定的受害者。
                    local wx, wz = x + math.cos(rotation) * min_dist, z - math.sin(rotation) * min_dist -- Z offset is negative to desired from Transform coordinates.
                    self.inst.HUD.controls:FocusMapOnWorldPosition(mapscreen, wx, wz)
                end
            end
            -- Do not have to take into account max_dist because the map automatically centers on the player when opened.
--   ProcessStaticDecorations：地图上的静态装饰（季节标记等）需要立即刷新。
            mapscreen:ProcessStaticDecorations()
        end
    end
end

-- returns: enable/disable, "a hud element is up, but still allow for limited gameplay to happen"
--★★ 【IsEnabled】**双返回值**，这是本文件最容易被误用的函数。
--   返回 (false)            —— 完全禁用（classified 说禁用，或 HUD 抢了焦点）
--   返回 (false, true)      —— ★ HUD 阻塞，但**部分输入仍应放行**
--   返回 (true)             —— 正常可操作
--   -- returns: enable/disable, "a hud element is up, but still allow for limited
--   gameplay to happen"
--   ⇒ 630 行 OnControl 用 `if isenabled or ishudblocking` 放行三个按钮
--     （ACTION / ATTACK / COMMAND_WHEEL），647 行才真正 return。
--   ⇒ 2691-2754 行 OnUpdate 用它决定「要不要强行停下移动」。
function PlayerController:IsEnabled()
    if self.classified == nil or not self.classified.iscontrollerenabled:value() then
        return false
--   HUD:HasInputFocus()：焦点在 HUD 上的任一 widget（如合成菜单输入框）。
    elseif self.inst.HUD ~= nil and self.inst.HUD:HasInputFocus() then
		return false,
--   ★ `(IsCraftingOpen() and TheFrontEnd.textProcessorWidget == nil)`：
--     合成菜单开着，但**没有**文本编辑器获得焦点 → 只阻塞 HUD 层面的通用输入，
--     但仍允许「操作」类按钮（在合成菜单里点击合成是合法的）。
--     textProcessorWidget 非 nil 时（玩家正在给物品改名）才完全阻塞。
			(self.inst.HUD:IsCraftingOpen() and TheFrontEnd.textProcessorWidget == nil) or
			self.inst.HUD:IsSpellWheelOpen() or
			self.inst.HUD:IsUpgradeModuleWidgetInputFocus() or
--   command_wheel_allows_gameplay：玩家设置里允许「轮盘开着也能操作」。
			(self.command_wheel_allows_gameplay and self.inst.HUD:IsCommandWheelOpen())
    end
    return true
end

--【IsMapControlsEnabled】小地图控制是否可用（三个条件与）。
--   与 IsEnabled 的区别：不管焦点，只看 classified 三个同步位。
function PlayerController:IsMapControlsEnabled()
    return self.classified ~= nil and
        self.classified.iscontrollerenabled:value() and
        self.classified.ismapcontrolsvisible:value() and
        self.inst.HUD ~= nil
end

--★★ 【IsControlPressed】**双端统一的按键查询**。这是本文件的抽象精髓。
--   本地玩家 → 问 TheInput；远端玩家 → 问 remote_controls。
--   ⇒ 于是 601 行的 OnControl、1122 行的重复动作、3135 行的连击攻击，
--     这些逻辑**写一次、两端跑**，完全不需要 if ismastersim 分流。
--   ★ 设计代价：remote_controls 的值必须被远端玩家的 RPC 及时维护（见 546-572 行）。
function PlayerController:IsControlPressed(control)
    if self.handler ~= nil then
        return TheInput:IsControlPressed(control)
    else
        return self.remote_controls[control] ~= nil
    end
end

--【IsAnyOfControlsPressed(...)】上面那个的变参版本（22 处外部调用）。
--   ★ 2579 行的 IsAnyActionHoldButtonHeld 是它的「本地特化版」——
--     因为长按判定必须用真实输入（remote_controls 的值可能是陈旧的冷却）。
function PlayerController:IsAnyOfControlsPressed(...)
    if self.handler ~= nil then
        for i, v in ipairs({...}) do
            if TheInput:IsControlPressed(v) then
                return true
            end
        end
    else
        for i, v in ipairs({...}) do
            if self.remote_controls[v] ~= nil then
                return true
            end
        end
    end
end

--【CooldownRemoteController】给 remote_controls 全体减冷却。
--   ★ 537 行的 `dt ~= nil and math.max(v-dt,0) or 0`：
--     ★★ 传 dt 则正常倒数；**传 nil 直接清零**。
--     这就是 4143/4349/4355/4400/4429 行那些 `CooldownRemoteController()`
--     无参调用能立即解除「按键还按着」状态的原理。
--     ⚠ 这个「dt 为 nil 意为清零」的二义性是隐式契约，靠 arity 区分，
--       极易在重构时踩坑（写成 dt=nil 的显式传参会静默清零）。
function PlayerController:CooldownRemoteController(dt)
    for k, v in pairs(self.remote_controls) do
        self.remote_controls[k] = dt ~= nil and math.max(v - dt, 0) or 0
    end
    self:CooldownHeldAction(dt)
end

--【CooldownHeldAction】长按冷却的递减。547-558 行是远端玩家的按键抬起处理。
function PlayerController:CooldownHeldAction(dt)
    self.heldactioncooldown = dt ~= nil and math.max(self.heldactioncooldown - dt, 0) or 0
end

--   ★ 守卫 `self.handler == nil`：只有远端玩家才需要「处理别人按键的抬起」。
--     本地玩家的抬起由 TheInput 自己管（622 行直接 return，不发 RPC）。
function PlayerController:OnRemoteStopControl(control)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.remote_controls[control] = nil
    end
end

function PlayerController:OnRemoteStopAllControls()
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        if next(self.remote_controls) ~= nil then
            self.remote_controls = {}
        end
    end
end

--【RemoteStopControl / RemoteStopAllControls】本地玩家的按键抬起 → RPC。
--   ★ 561/568 行的重复检查（已经 nil 就不发）是带宽优化：
--     抬起事件可能重复到达，只在真正变化时通知服务器。
function PlayerController:RemoteStopControl(control)
    if self.remote_controls[control] ~= nil then
        self.remote_controls[control] = nil
        SendRPCToServer(RPC.StopControl, control)
    end
end

function PlayerController:RemoteStopAllControls()
    if next(self.remote_controls) ~= nil then
        self.remote_controls = {}
        SendRPCToServer(RPC.StopAllControls)
    end
end

--【RemotePausePrediction(frames)】★ 68 次外部调用，是给外部（AI/陷阱/剧情）
--   用的「暂时冻结这个玩家的客户端预测」开关。
--   ★ 典型用法：韦布斯特/温蒂的操作需要玩家的位置在某一帧绝对准确。
--     写入 classified.pushpausepredictionframes，客户端 765 行 IsBusy 读它。
function PlayerController:RemotePausePrediction(frames)
    if self.ismastersim then
        self.classified:PushPausePredictionFrames(frames or 0)
    end
end

--★ 【ShouldPlayerHUDControlBeIgnored】★ **给 HUD 用的优先级仲裁钩子**。
--   -- NOTES(JBK) 的英文原文解释了整件事的由来：
--     "The PlayerHud gets control events before PlayerController which works
--      for most cases. Some cases are exceptions for priority which are handled
--      here to have PlayerController take over. This would be good to have a
--      CONTROL_ priority list and SetDigitalControlFromInput creates a table
--      that is sent to game. Right now priority is lower CONTROL_ id is higher
--      priority. So this function exists to force a priority based off of
--      function run ordering."
--   → 翻译：HUD 比 PlayerController 先收到按键，所以 HUD 想「抢」某个键时，
--     它会问本函数「这个键我要不要跳过」。跳过 = 忽略 = 让给 PlayerController。
--   ⇒ 两个场景：①轴对齐放置时，方向键应归放置器（588 行）
--            ②目标锁定时，方向键应归目标列表切换（592 行）
--   ⚠ K 自己承认这是权宜之计（"This would be good to have a CONTROL_ priority
--     list"）。真实设计应有一个显式的控件优先级表。
function PlayerController:ShouldPlayerHUDControlBeIgnored(control, down)
    -- NOTES(JBK): The PlayerHud gets control events before PlayerController which works for most cases.
    -- Some cases are exceptions for priority which are handled here to have PlayerController take over.
    -- This would be good to have a CONTROL_ priority list and SetDigitalControlFromInput creates a table that is sent to game.
    -- Right now priority is lower CONTROL_ id is higher priority.
    -- So this function exists to force a priority based off of function run ordering.

--   588 行的 `control ~= X and ControlsHaveSameMapping(..., CONTROL_X)`：
--     ★ 不是按 ID 比，而是按「实际键位映射」比 —— 因为手柄可重绑定，
--       CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID 在不同手柄上绑到不同物理键。
--     这也解释了为什么这个钩子必须是**函数**而不是 HUD 里的静态表。
    if self:IsAxisAlignedPlacement() and
        control ~= CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID and
        TheInput:ControlsHaveSameMapping(TheInput:GetControllerID(), control, CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID) then
        return true
    end
    if self:IsControllerTargetLocked() and
        control ~= CONTROL_TARGET_CYCLE and
        TheInput:ControlsHaveSameMapping(TheInput:GetControllerID(), control, CONTROL_TARGET_CYCLE) then
        return true
    end

    return false
end

--★★★ 【OnControl】601-718 行：★ **整个玩家输入的唯一入口**。
--   设计要点：
--   ① 它是 AddGeneralControlHandler 的回调（319 行），**只在本机玩家**触发。
--   ② 它对**所有**按键一视同仁地做守卫，然后按 CONTROL_ 分派。
--   ③ 服务端永远收不到它（因为 handler 为 nil 时 Activate 不会注册）。
--   ⚠ 618 行 return true 与其他分支的裸 return 混用：
--     返回值在 AddGeneralControlHandler 的语义里是「已消费」，
--     但 601-718 行大部分分支都是**裸 return（nil）**，
--     意味着 PlayerController 几乎从不「消费」事件 —— 它只是旁路处理。
--     真正的事件消费方是 HUD（1427 行问 ShouldPlayerHUDControlBeIgnored）。
function PlayerController:OnControl(control, down)

--   暂停时直接 return：★ 暂停期间 playercontroller 完全不响应输入。
--     这也是为什么 4438 行的相机旋转要放在 OnWallUpdate（墙钟）里。
    if IsPaused() then
        return
	end

--   ★ isenabled, ishudblocking = self:IsEnabled() —— 注意接收两个返回值。
--     608 行 `if not isenabled and not ishudblocking then return end`：
--     两者皆假才彻底放弃（HUD 完全不阻塞时不该由 PC 处理任何键）。
    local isenabled, ishudblocking = self:IsEnabled()
	if not isenabled and not ishudblocking then
		return
	end

--   _hack_ignore_held_controls：开地图后忽略「已经按下的键的抬起」，
--     防止玩家点「开地图」那一下的松开动作被误当成新操作。
--     ★ 614 行 return true 是「消费掉这个事件」，与本函数其余分支不同 ——
--       这两个 hack 分支是唯一真正返回 true 的地方。
    if down and self._hack_ignore_held_controls then
        self._hack_ignore_ups_for[control] = true
        return true
    end
--   对称分支：把 613 行记下的 control 从忽略名单里摘掉，然后消费。
--   ★ 设计意图：按下时忽略（记下来）→ 松开时也忽略一次（摘名单）→ 之后恢复正常。
--     若只做 612 行不做 616 行，这个键将**永远**无法再次触发。
    if not down and self._hack_ignore_ups_for and self._hack_ignore_ups_for[control] then
        self._hack_ignore_ups_for[control] = nil
        return true
    end

--   --V2C: control up happens here now —— ★ 历史注释，说明这段是重排过的。
--   ★★ 622-627 行是一个极其重要的**方向性设计**：
--     几乎所有「抬起」事件在这里被统一处理成 RemoteStopControl，然后 return，
--     **不再走下面的分派逻辑**。
--     ⇒ 推论：OnControl 的分派部分只对「按下」事件有效（PRIMARY/SECONDARY 除外，
--       它们在 622 行被显式排除，会继续往下走到 651/653 行）。
--     ⇒ 推论 2：抬起时清 remote_controls（624 行），这保证了 511 行
--       IsControlPressed 在远端玩家身上不会「卡住」。
	--V2C: control up happens here now
	if not down and control ~= CONTROL_PRIMARY and control ~= CONTROL_SECONDARY then
		if not self.ismastersim then
			self:RemoteStopControl(control)
		end
		return
	end

--   -- actions that can be done while the crafting menu is open go in here
--   ★ 这三个按钮（ACTION/ATTACK/COMMAND_WHEEL）是**唯一允许在 HUD 打开时
--     仍然生效**的。设计原因见 496 行：在合成菜单里点物品 = 合成。
	-- actions that can be done while the crafting menu is open go in here
	if isenabled or ishudblocking then
		if control == CONTROL_ACTION then
			self:DoActionButton()
			return
		elseif control == CONTROL_ATTACK then
--   ★ CONTROL_ATTACK 的双端分叉是关键设计：
--     服务端**不立即执行**，而是把 CONTROL_ATTACK 这个**常量**塞进 attack_buffer，
--     交给 OnUpdate:2777 去执行；客户端立即执行（因为要预测）。
--     ⇒ 为什么服务端要绕一圈？因为 OnControl 发生在输入时刻，
--       而执行需要 Locomotor 的状态（能否边走边打），那要等下一帧。
			if self.ismastersim then
				self.attack_buffer = CONTROL_ATTACK
			else
				self:DoAttackButton()
			end
			return
		elseif control == CONTROL_CHARACTER_COMMAND_WHEEL then
			self:DoCharacterCommandWheelButton()
			return
		end
	end

--   三个「HUD 也允许」的按钮处理完，才在这里真正阻断。
--   ⇒ 从这里往下是「游戏世界输入」：PRIMARY / SECONDARY / CANCEL / INSPECT /
--     控制器动作 / 库存格子 / 目标锁定。
	if not isenabled then
		return
	end

--   PRIMARY = 鼠标左键 = 「做动作」。SECONDARY = 鼠标右键 = 「另一动作/AOE/放置」。
--   ★ 与手柄的对应：PRIMARY ↔ CONTROLLER_ACTION(X)，
--     SECONDARY ↔ CONTROLLER_ALTACTION(Y)，CONTROL_ATTACK(Z 或 扳机)。
--     ⇒ 三键对应三套 GetXxxAction 查询，见 2096/5373/5450 行的分工。
    if control == CONTROL_PRIMARY then
        self:OnLeftClick(down)
    elseif control == CONTROL_SECONDARY then
        self:OnRightClick(down)
	--V2C: see above for control up handling
	--elseif not down then
	--    if not self.ismastersim then
	--        self:RemoteStopControl(control)
	--    end
--   CONTROL_CANCEL = 右键取消放置。662 行注释掉的 ControllerTargetLock(false)
--     说明「取消键同时解除目标锁定」是设计过但未启用的。
    elseif control == CONTROL_CANCEL then
        self:CancelPlacement()
		--self:ControllerTargetLock(false)
--   轴对齐放置时按循环键 → 切换对齐方式（0°/45°/90°/世界坐标）。
    elseif control == CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID and self:IsAxisAlignedPlacement() then
        CycleAxisAlignmentValues()
    elseif control == CONTROL_INSPECT then
        self:DoInspectButton()
    elseif control == CONTROL_CONTROLLER_ALTACTION then
        self:DoControllerAltActionButton()
    elseif control == CONTROL_CONTROLLER_ACTION then
        self:DoControllerActionButton()
    elseif control == CONTROL_CONTROLLER_ATTACK then
        if self.ismastersim then
            self.attack_buffer = CONTROL_CONTROLLER_ATTACK
        else
            self:DoControllerAttackButton()
        end
--   677 行 `self.inst.replica.inventory:IsVisible()`：库存可见才处理库存格子操作。
--     ★ 这是「库存 UI 打开时手柄的十字键变成光标」的守卫。
    elseif self.inst.replica.inventory:IsVisible() then
        local inv_obj = self:GetCursorInventoryObject()
        if inv_obj ~= nil then
--   ★★ 680-706 行是**手柄方案适配层**：同一批库存格子操作，
--     在「经典映射」和「方向键映射」下用不同的 CONTROL_ id。
--   -- 682 行的英文注释说明了为什么这么写：
--     "Classic mapping control IDs aren't in the same order as
--      (up/down/left/right), so lets handle it manually here rather than
--      calling ResolveVirtualControls 4 times."
--     → 经典映射的 ID 顺序不是上/下/左/右，调用 ResolveVirtualControls 4 次
--       开销大且顺序对不上，于是手工枚举。
--   ⇒ 设计代价：新增映射方案必须同时改这两支。
			local scheme = TheInput:GetActiveControlScheme(CONTROL_SCHEME_CAM_AND_INV)
			if scheme <= 3 or scheme > 7 then
				--Classic mapping control IDs aren't in the same order as (up/down/left/right), so
				--lets handle it manually here rather than calling ResolveVirtualControls 4 times.
				if control == CONTROL_INVENTORY_DROP then
					self:DoControllerDropItemFromInvTile(inv_obj)
				elseif control == CONTROL_INVENTORY_EXAMINE then
					self:DoControllerInspectItemFromInvTile(inv_obj)
				elseif control == CONTROL_INVENTORY_USEONSELF then
					self:DoControllerUseItemOnSelfFromInvTile(inv_obj)
				elseif control == CONTROL_INVENTORY_USEONSCENE then
					self:DoControllerUseItemOnSceneFromInvTile(inv_obj)
				end
--   693-706：现代映射只需解析一次虚拟控件基址，再按 +0/+1/+2/+3 偏移。
--   696/698/700/702 行注释直接标出了每个偏移对应哪个操作。
			else
				local vcontrol = TheInput:ResolveVirtualControls(VIRTUAL_CONTROL_INV_ACTION_UP)
				if vcontrol then
					if control == vcontrol + 1 then --VIRTUAL_CONTROL_INV_ACTION_DOWN
						self:DoControllerDropItemFromInvTile(inv_obj)
					elseif control == vcontrol then --VIRTUAL_CONTROL_INV_ACTION_UP
						self:DoControllerInspectItemFromInvTile(inv_obj)
					elseif control == vcontrol + 3 then --VIRTUAL_CONTROL_INV_ACTION_RIGHT
						self:DoControllerUseItemOnSelfFromInvTile(inv_obj)
					elseif control == vcontrol + 2 then --VIRTUAL_CONTROL_INV_ACTION_LEFT
						self:DoControllerUseItemOnSceneFromInvTile(inv_obj)
					end
				end
			end
        end
    end
    
--   710-716：目标锁定的两个按键。★ 全部包在 `if down` 里 —— 只响应按下。
    if down then
	    if control == CONTROL_TARGET_LOCK then		
		    self:ControllerTargetLockToggle()
	    elseif self:IsControllerTargetLockEnabled() and control == CONTROL_TARGET_CYCLE then
		    self:CycleControllerAttackTargetForward()
        end
    end

end

--============================================================
-- 【第二段】620-1300 行：修饰键位掩码 / 预测准入 / 手柄三键与其服务端对端
--============================================================
--------------------------------------------------------------------------

--★★ 【MOD_CONTROLS】四个「修饰键」的集合，它们被压缩成一个整数发送。
--   FORCE_INSPECT / FORCE_ATTACK / FORCE_TRADE / FORCE_STACK。
--   ★ 为什么需要独立于 CONTROL_ 的「强制」键：
--     手柄上「攻击」只有一个键，但玩家需要在「不攻击」的前提下强制攻击
--     （如强杀友方宠物、强制采集不采集物、强行交易给中立 NPC）。
--     键盘上这靠组合键区分；手柄只能靠「同时按另一个键」。
local MOD_CONTROLS =
{
    CONTROL_FORCE_INSPECT,
    CONTROL_FORCE_ATTACK,
    CONTROL_FORCE_TRADE,
    CONTROL_FORCE_STACK,
}

--【EncodeControlMods】★ 客户端把 4 个修饰键压成 1-15 的整数。
--   编码方式：第 i 个键按第 i 位（bit 从 1 开始翻倍）。
--   737 行 `return code ~= 0 and code or nil`：0 表示「无修饰」，
--     ★ 这里**故意返回 nil 而不是 0** —— RPC 的可选参数 nil 表示「参数缺省」，
--       0 会被当成「显式传了 0」。这是 Lua 里区分「false/nil」的常见技巧。
function PlayerController:EncodeControlMods()
    local code = 0
    local bit = 1
    for i, v in ipairs(MOD_CONTROLS) do
        code = code + (TheInput:IsControlPressed(v) and bit or 0)
        bit = bit * 2
    end
    return code ~= 0 and code or nil
end

--【DecodeControlMods】服务端反向解码，写进 remote_controls。
--   ★ 设计要点：Decode **总是**给每个修饰键赋值（0 或 nil），不是只写命中的。
--     因为按住修饰键时会**每帧**重发（LMB/RMB 的 preview_cb），
--     若只写命中位，松手时（code=0）旧值不会被清掉 → 修饰键永久卡住。
--   ⇒ 这与 754 行 ClearControlMods（显式清空）互为补充：
--     Clear 用于动作执行完（4924/5105 行），Decode 用于每次新输入。
function PlayerController:DecodeControlMods(code)
    code = code or 0
--   bit 初值是最高位（2^(n-1)），倒序遍历 → 高位对应列表末尾的键。
--   ⚠ 编码用正序递增、解码用倒序递减，两者必须严格对称。
--     推理依据：730-738 用 `bit=1; bit=bit*2` 正序；
--       740-752 用 `bit=2^(n-1); bit=bit/2` 倒序。任一方改顺序都会静默错位。
    local bit = 2 ^ (#MOD_CONTROLS - 1)
    for i = #MOD_CONTROLS, 1, -1 do
        if code >= bit then
            self.remote_controls[MOD_CONTROLS[i]] = 0
            code = code - bit
        else
            self.remote_controls[MOD_CONTROLS[i]] = nil
        end
        bit = bit / 2
    end
end

function PlayerController:ClearControlMods()
    for i, v in ipairs(MOD_CONTROLS) do
        self.remote_controls[v] = nil
    end
end

--★★ 【CanLocomote】★ **「本帧能否做本地预测移动」的唯一判据**。
--   服务端恒为 true（权威，不需要「预测」）。
--   客户端要同时满足五个条件：
--     ① 有 locomotor（非行走单位）
--     ② 状态图没有 busy 标签
--     ③ 没有 pausepredict 标签（被外部 RemotePausePrediction 冻结）
--     ④ classified.pausepredictionframes > 0（冻结帧数还没耗尽）
--     ⑤ entity:CanPredictMovement()（引擎层的判断，见 entityreplica）
--   ⇒ 大量 preview_cb 的安装都以它为前提（895/913/932/1161/1371/...）。
--   ★ 为什么单独抽成函数而不是内联：这五个条件在文件里出现 40+ 次，
--     且 ③④ 是「服务端下发、客户端读取」的一对，必须永远同时判。
function PlayerController:CanLocomote()
    return self.ismastersim
        or (self.locomotor ~= nil and
            not (self.inst.sg:HasStateTag("busy") or
                self.inst:HasTag("pausepredict") or
                (self.classified ~= nil and self.classified.pausepredictionframes:value() > 0)) and
            self.inst.entity:CanPredictMovement())
end

--【IsBusy】与 CanLocomote 并列的第二个高频判据，但**只判 busy**。
--   ★ 双端差异很有意思：
--     服务端用 sg:HasStateTag("busy")；
--     客户端额外看 inst:HasTag("busy")（无状态图的客户端走标签路径，773 行）
--       以及 classified.pausepredictionframes（服务端主动冻结）。
--   ⇒ 推论：客户端的「忙」判定比服务端**宽**（多了两个条件），
--     所以客户端会**更保守**地放弃预测。这是有意的：宁可少预测也不错预测。
function PlayerController:IsBusy()
    if self.ismastersim then
        return self.inst.sg:HasStateTag("busy")
    else
        return self.inst:HasTag("busy")
            or (self.inst.sg ~= nil and self.inst.sg:HasStateTag("busy"))
            or (self.classified ~= nil and self.classified.pausepredictionframes:value() > 0)
    end
end

--------------------------------------------------------------------------

--【GetCursorInventoryObject】手柄模式下库存光标下的物品。
--   ★ 双重守卫：HUD 存在（服务端为 nil）且手柄已连接（鼠标模式光标无意义）。
--   784 行的 `item ~= nil and item:IsValid() and item or nil`：
--     把 false/nil 归一为 nil，避免下游拿到一个假值。
function PlayerController:GetCursorInventoryObject()
    if self.inst.HUD ~= nil and TheInput:ControllerAttached() then
        local item = self.inst.HUD.controls.inv:GetCursorItem()
        return item ~= nil and item:IsValid() and item or nil
    end
end

function PlayerController:GetCursorInventorySlotAndContainer()
    if self.inst.HUD ~= nil and TheInput:ControllerAttached() then
        return self.inst.HUD.controls.inv:GetCursorSlot()
    end
end

--★★ 【DoControllerActionButton】手柄 X 键（CONTROLLER_ACTION）。全文件最长的分支树之一。
--   它要区分**五种**完全不同的上下文：
--     ① 建造放置模式（placer/placer_recipe）→ 直接 MakeRecipeAtPoint
--     ② 部署放置（deployplacer）→ 取 GetDeployAction
--     ③ AOE 瞄准中 → 取 GetGroundUseAction 并要求是 CASTAOE
--     ④ 有控制器目标 → GetSceneItemControllerAction
--     ⑤ 都没有 → GetGroundUseSpecialAction（点地特殊动作）
--   ★ 每种上下文对应的 RPC 都不同（ControllerActionButton / ...Point / ...Deploy），
--     这是本文件里唯一一处「一个按键三条 RPC」的分支。
function PlayerController:DoControllerActionButton()
--   ★ 建造放置的优先处理：手柄模式下 placer 是「已选好蓝图，按 X 放下」。
--   798 行检查 can_build（放置器自己的可建判定，不查 inventory 的材料）。
    if self.placer ~= nil and self.placer_recipe ~= nil then
        --do the placement
        local placer_placer = self.placer.components.placer
        if placer_placer.can_build then
--   ★ 双重条件：replica.builder 存在 且 未在建造中（IsBusy）。
--     IsBusy 防止「连按 X 一次建三个」。
            if self.inst.replica.builder ~= nil and not self.inst.replica.builder:IsBusy() then
                self.inst.replica.builder:MakeRecipeAtPoint(
                    self.placer_recipe,
--   override_build_point_fn：允许放置器自己决定最终建造点。
--     ★ 例：长矛/火把这类「要放在玩家脚下而非鼠标处」的物品。
                    (placer_placer.override_build_point_fn ~= nil and placer_placer.override_build_point_fn(self.placer))
                        or self.placer:GetPosition(),
                    self.placer:GetRotation(),
                    self.placer_recipe_skin
                )
                self:CancelPlacement()
            end
--   失败放置的回调（onfailedplacement）：材料不够 / 被占用时的提示。
        elseif placer_placer.onfailedplacement ~= nil then
            placer_placer.onfailedplacement(self.inst, self.placer)
        end
        return
    end

	local obj, act, isspecial, spellbook, spell_id
--   ② 部署放置：手柄拿着的可部署物品的预览。
--   821 行 `act.distance = 1`：★ 强制把作用距离改成 1。
--     为什么：服务器会对同一个动作做二次的距离校验（actions.lua 的 rangecheckfn），
--     而服务器算出的距离可能因为平台/落点误差而超过原值，直接改成 1 保证能过。
    if self.deployplacer ~= nil then
        if self.deployplacer.components.placer.can_build then
            act = self.deployplacer.components.placer:GetDeployAction()
            if act ~= nil then
                obj = act.invobject
                act.distance = 1
            end
        end
--   ③ AOE 瞄准：正在用魔杖/法术书瞄点。
--   826 行的 `(canrepeatcast and HasTag("canrepeatcast"))`：
--     ★ 允许「busy 时继续连射」的道具（如多重施法卷轴），需同时满足两个条件。
--   827-828：不能重复施法时播负面音 + 准星闪烁（纯表现，立即 return）。
    elseif self:IsAOETargeting() then
		local canrepeatcast = self.reticule.inst.components.aoetargeting:CanRepeatCast()
		if self:IsBusy() and not (canrepeatcast and self.inst:HasTag("canrepeatcast")) then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative", nil, .4)
            self.reticule:Blip()
            return
        end
        obj, act = self:GetGroundUseAction()
--   ★ 833 行的守卫 `act.action ~= ACTIONS.CASTAOE`：
--     「瞄准中但脚下没有合法施法点」→ 什么都不做（不是「换个动作」，那是 X 键之外的职责）。
        if act == nil or act.action ~= ACTIONS.CASTAOE then
            return
        end
        obj = nil --meh.. reusing obj =P
--   --meh.. reusing obj =P  —— 英文原注释「obj 复用为 P（玩家）」。
--   ★ 这是真实的代码债：obj 在这个分支里被当作「施法者」重载，
--     而在 844-868 的分支里它是「目标实体」。两个语义共用一个变量，
--     导致 901 行的 `elseif obj == nil` 判断依赖这个重载。
		spellbook = self:GetActiveSpellBook()
		if spellbook ~= nil then
			spell_id = spellbook.components.spellbook:GetSelectedSpell()
		end
--   PingReticuleAt：往准星位置发一个涟漪特效（纯表现）。
--   841 行的 ShouldRepeatCast：不消耗弹药则继续瞄准（如永动火把）。
		self.reticule:PingReticuleAt(act:GetDynamicActionPoint())
		if not (canrepeatcast and self.reticule.inst.components.aoetargeting:ShouldRepeatCast(self.inst)) then
			self:CancelAOETargeting()
		end
--   ④ 有控制器目标（手柄 Y 键选中的东西）。
--   ★ 与鼠标路径的根本差异：鼠标用「鼠标指向的世界坐标」，
--     手柄用「玩家自己选中的实体」。因此 GetSceneItemControllerAction 接收实体。
    else
        obj = self:GetControllerTarget()
        if obj ~= nil then
            act = self:GetSceneItemControllerAction(obj)
			if act then
--   船炮 / 高尔夫的特殊处理：把 obj 复用成 nil，让 RPC 走 Point 变体。
--     ★ 因为这两个动作是「aim at point」而非「target an entity」。
				if act.action == ACTIONS.BOAT_CANNON_SHOOT then
					obj = nil --meh.. reusing obj =P
					local boatcannonuser = self.inst.components.boatcannonuser
					local reticule = boatcannonuser and boatcannonuser:GetReticule()
					if reticule then
						reticule:PingReticuleAt(act:GetDynamicActionPoint())
					end
				elseif act.action == ACTIONS.GOLF_START_CHARGING then
					obj = nil --meh.. reusing obj =P
					--@V2C #TODO
				end
            end
        end
--   ⑤ 兜底：点地特殊动作（GetGroundUseSpecialAction，5450 行）。
--   ★ isspecial = true 会一路带到 RPC（第 12 个参数），
--     服务端据此选择 GetGroundUseSpecialAction 而不是 GetGroundUseAction。
        if act == nil then
            act = self:GetGroundUseSpecialAction(nil, false)
            if act ~= nil then
                isspecial = true
            end
        end
    end

--★★ 【act == nil 的处理】870-877 行是本文件里「无动作也要通知服务器」的范式。
--   --Still need to let the server know our controller action button is down
--   ★ 为什么需要：服务端靠 remote_controls[CONTROL_CONTROLLER_ACTION] 知道
--     「玩家正按着 X」，这影响连击攻击（3137 行）、DoClientBusyOverrideLocomote 等。
--     若客户端按了但什么都没做，服务端会以为玩家一直没按 → 行为不一致。
--   ⇒ 这个「无参 RPC」在本文件出现 10+ 次（874/911/930/1159/1178/1369/...），
--     是双端状态同步的必要组成，不是冗余代码。
    if act == nil then
		--Still need to let the server know our controller action button is down
		if self.remote_controls[CONTROL_CONTROLLER_ACTION] == nil then
			self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
			SendRPCToServer(RPC.ControllerActionButton)
		end
        return
    end

--   maptarget 检查：某些动作改为在地图上执行（如给雕像上香）。
--   881 行 map_only 动作传 forced_actiondef，让地图界面强制按此动作。
    local maptarget = self:GetMapTarget(act)
    if maptarget ~= nil then
        local forced_actiondef = act.action.map_only and act.action or nil
		self:PullUpMap(maptarget, forced_actiondef)
        return
    end

--★★ 【三分支发送架构】886-939 行是本文件的**核心范式**，每个按钮都是这个形状：
--   if self.ismastersim then
--       —— 服务端：直接执行（不需要发 RPC，自己就是权威）
--   elseif self.locomotor == nil then
--       —— 无 locomotor 的客户端（纯 UI 客户端，如服务器机）：
--          装 non_preview_cb，动作**不会**被缓冲，DoAction:4546 会立刻触发回调
--   else
--       —— 有 locomotor 的预测客户端：
--          ①先发一个「按钮按下」的无参 RPC（870-877 那个范式）
--          ②装 preview_cb —— 等客户端**真的走到位、动画播完**才发真 RPC
--   ⇒ ★★★ 核心洞察：preview_cb 的触发时机决定了「网络省流 + 手感」：
--     玩家点了「走过去砍树」，如果立刻发 RPC，服务器在玩家还没到时就砍完了，
--     客户端随后要硬回滚。把 RPC 推迟到到达瞬间，服务器的时间线与客户端一致，
--     无需回滚。代价是**服务器响应变慢**（要等走路完成）。
--   ⇒ 这就是为什么 preview_cb 里要再读一次 TheInput:IsControlPressed（896 行）：
--     因为按下→走 2 秒→松开，服务器收到的应该是「松开」而非「按下」。
    if self.ismastersim then
--   服务端：清掉 combat 的目标。为什么？
--     因为「攻击」与「移动到某处」是互斥的，新动作开始意味着放弃旧目标。
--     ★ 这个 SetTarget(nil) 在文件里出现 15+ 次（946/990/1047/1194/1239/1359/...），
--       是「动作开始即清战斗目标」这一统一约定的体现。
        self.inst.components.combat:SetTarget(nil)
    elseif self.deployplacer ~= nil then
        if self.locomotor == nil then
--   non_preview_cb 路径：locomotor 为 nil，没有 locomotor 模块可以调用回调。
--   892 行第 6 个参数 `act.rotation ~= 0 and act.rotation or nil`：
--     ★ 又是「0 → nil」的三元惯例（730 行同款）：0 是「没旋转」的默认值，
--       转成 nil 是为了让服务端用默认旋转。
			act.non_preview_cb = function()
				self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
				SendRPCToServer(RPC.ControllerActionButtonDeploy, obj, act.pos.local_pt.x, act.pos.local_pt.z, act.rotation ~= 0 and act.rotation or nil, nil, act.pos.walkable_platform, act.pos.walkable_platform ~= nil)
			end
        elseif self:CanLocomote() then
--   preview_cb：只有 CanLocomote（4003 行的判据）通过才装。
--     否则玩家在 busy 状态按 X 无效 —— 与服务端行为一致。
            act.preview_cb = function()
                local isreleased = not TheInput:IsControlPressed(CONTROL_CONTROLLER_ACTION)
				self.remote_controls[CONTROL_CONTROLLER_ACTION] = not isreleased and 0 or nil
                SendRPCToServer(RPC.ControllerActionButtonDeploy, obj, act.pos.local_pt.x, act.pos.local_pt.z, act.rotation ~= 0 and act.rotation or nil, isreleased, act.pos.walkable_platform, act.pos.walkable_platform ~= nil)
            end
        end
--   obj == nil 分支 = 上面 835/850/857 行那些「obj 被复用成 nil」的分支。
--   ★ 也就是说：即使前面把 obj 置 nil 了，这里也能正确走到 Point 变体。
--     这是「用变量重载来隐式传参」带来的耦合点——改 835 行会直接影响这里。
    elseif obj == nil then
        if self.locomotor == nil then
			act.non_preview_cb = function()
				self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
--   ControllerActionButtonPoint 的完整参数（12 个）：
--     actioncode, pos_x, pos_z, isreleased, canforce, mod_name,
--     platform, platform_relative, isspecial, spellbook, spell_id
--   ★ mod_name 是**模组命名空间**（见 actions.lua 的 MOD_ACTIONS_BY_ACTION_CODE），
--     原版动作为 nil。服务端据此在原版表或模组表里查动作。
				SendRPCToServer(RPC.ControllerActionButtonPoint, act.action.code, act.pos.local_pt.x, act.pos.local_pt.z, nil, act.action.canforce, act.action.mod_name, act.pos.walkable_platform, act.pos.walkable_platform ~= nil, isspecial, spellbook, spell_id)
			end
		else
			--Still need to let the server know our controller action button is down
			if self.remote_controls[CONTROL_CONTROLLER_ACTION] == nil then
				self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
				SendRPCToServer(RPC.ControllerActionButton)
			end
			if self:CanLocomote() then
				act.preview_cb = function()
					local isreleased = not TheInput:IsControlPressed(CONTROL_CONTROLLER_ACTION)
					self.remote_controls[CONTROL_CONTROLLER_ACTION] = not isreleased and 0 or nil
					SendRPCToServer(RPC.ControllerActionButtonPoint, act.action.code, act.pos.local_pt.x, act.pos.local_pt.z, isreleased, nil, act.action.mod_name, act.pos.walkable_platform, act.pos.walkable_platform ~= nil, isspecial, spellbook, spell_id)
				end
			end
        end
--   有目标（obj ~= nil）的 else 分支：发 ControllerActionButton（带 target）。
--   ★ 注意 936 行传的是 `nil` 而不是 `act.action.canforce`：
--     preview 阶段一律不强制（896 行同理），因为此时还不知道最终会走到哪。
    elseif self.locomotor == nil then
		act.non_preview_cb = function()
			self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
			SendRPCToServer(RPC.ControllerActionButton, act.action.code, obj, nil, act.action.canforce, act.action.mod_name)
		end
	else
		--Still need to let the server know our controller action button is down
		if self.remote_controls[CONTROL_CONTROLLER_ACTION] == nil then
			self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
			SendRPCToServer(RPC.ControllerActionButton)
		end
		if self:CanLocomote() then
			act.preview_cb = function()
				local isreleased = not TheInput:IsControlPressed(CONTROL_CONTROLLER_ACTION)
				self.remote_controls[CONTROL_CONTROLLER_ACTION] = not isreleased and 0 or nil
				SendRPCToServer(RPC.ControllerActionButton, act.action.code, obj, isreleased, nil, act.action.mod_name)
			end
		end
    end

	self:DoAction(act, spellbook)
end

--★★ 【OnRemoteControllerActionButton】服务端的同款逻辑 —— 注意它**重新算一遍**。
--   957 行 `local lmb, rmb = self:GetSceneItemControllerAction(target)`：
--     ★★ 这是「意图编号校验」的核心：客户端上报 actioncode=42（CHOP），
--       服务端不信，自己在**同一位置、同一上下文**再算一次，看是不是也是 42。
--       只有相等才执行（974-979 行）。
--   ⇒ 安全模型：客户端无法伪造「在 30 单位外砍树」——服务端算出来的会是别的东西
--     或 nil，动作直接被丢弃。这解释了为什么整个文件没有「信任客户端距离」。
function PlayerController:OnRemoteControllerActionButton(actioncode, target, isreleased, noforce, mod_name)
--   ★ 三重守卫，逐层收窄：
--     ① ismastersim   —— 必须是服务端（防 RPC 重放到自己）
--     ② IsEnabled()   —— 玩家必须处于可操作状态（防「关着菜单时发 RPC」）
--     ③ handler == nil —— 玩家不能是本机玩家（防自己给自己发）
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.inst.components.combat:SetTarget(nil)

        self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0

--   actioncode == nil = 「我只告诉你按钮按下了，没有具体动作」。
--   951 行 assert(isreleased == nil)：★ 无参 RPC 时不允许带 isreleased。
--     这是一条自检断言，防止将来有人给无参 RPC 加参数时静默破坏协议。
		if actioncode == nil then
			assert(isreleased == nil) --actioncode nil means all params must be nil
			return
		end

        self:ClearControlMods()
--   SetClientRequestedAction(actioncode, mod_name)：
--     ★★★ 把客户端上报的 actioncode 临时注入 playeractionpicker 的判定条件，
--       让 GetSceneItemControllerAction 「假装」客户端请求的就是这个动作。
--     为什么需要：actions 里同一个按钮在不同物品下可能是不同动作，
--       服务端需要知道客户端**当时看到的是哪个**，才能算出同一个结果。
--     958 行 ClearClientRequestedAction() 必须成对调用，否则会污染后续查询。
        SetClientRequestedAction(actioncode, mod_name)
        local lmb, rmb = self:GetSceneItemControllerAction(target)
        ClearClientRequestedAction()
        if isreleased then
            self.remote_controls[CONTROL_CONTROLLER_ACTION] = nil
        end

--   --Possible for lmb action to switch to rmb after autoequip
--   ★★ 964-972 行的 and/or 链在处理**自动装备导致的动作漂移**：
--     客户端按 X 时手里拿的是斧头 → 算出 CHOP（code=1）；
--     服务端算之前 DoActionAutoEquip 可能把斧头换到了手上 → 算出别的 code。
--     所以服务端接受「lmb 或 rmb 中任一匹配」。
--   ⚠ 代价：这条放宽让客户端可以上报 rmb 的 code 来强制执行右键动作。
--     风险有限（服务端仍会检查距离/CanTarget），但确实是校验的松动点。
        --Possible for lmb action to switch to rmb after autoequip
        lmb =  (lmb ~= nil and
                lmb.action.code == actioncode and
                lmb.action.mod_name == mod_name and
                lmb)
            or (rmb ~= nil and
                rmb.action.code == actioncode and
                rmb.action.mod_name == mod_name and
                rmb)
            or nil

        if lmb ~= nil then
--   canforce 且未被禁止 → 把动作点设为「客户端预测位置」并标记 forced。
--   ★ 976 行 `self:GetRemotePredictPosition() or self.inst:GetPosition()`：
--     用**预测位置**而不是当前位置，是为了对齐客户端「我站在哪」。
--     force 在 actions.lua 的 rangecheckfn 里意味着「跳过距离检查」。
--   ⇒ 安全影响：forced 动作绕过距离校验。但目标实体本身仍要过 CanTarget。
            if lmb.action.canforce and not noforce then
                lmb:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
                lmb.forced = true
            end
            self:DoAction(lmb)
        --elseif mod_name ~= nil then
            --print("Remote controller action button action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
        --else
            --print("Remote controller action button action failed: "..tostring(ACTION_IDS[actioncode]))
        end
    end
end

--【OnRemoteControllerActionButtonPoint】点地版本的服务端对端。
--   996 行的 isspecial 分支：客户端点的是「特殊点地动作」，
--     服务端走 GetGroundUseSpecialAction（5450 行）而不是 GetGroundUseAction。
function PlayerController:OnRemoteControllerActionButtonPoint(actioncode, position, isreleased, noforce, mod_name, isspecial, spellbook, spell_id)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.inst.components.combat:SetTarget(nil)

        self.remote_controls[CONTROL_CONTROLLER_ACTION] = 0
        self:ClearControlMods()
        SetClientRequestedAction(actioncode, mod_name)
        local lmb, rmb
        if isspecial then
			lmb = self:GetGroundUseSpecialAction(position, false)
--   spellbook 分支：法术书施法。1002 行 SelectSpell(spell_id) 强制选中同一个法术。
--     ★ 这是「客户端说我要放第 3 个法术」的合法化：服务端不接受 spell_id 之外的任何东西，
--       但会验证「这本书在不在你手上」（999-1000 行的 GetGrandOwner）。
		elseif spellbook ~= nil then
			if spellbook.components.inventoryitem ~= nil and
				spellbook.components.inventoryitem:GetGrandOwner() == self.inst and
				spellbook.components.spellbook ~= nil and
				spellbook.components.spellbook:SelectSpell(spell_id)
				then
				lmb, rmb = self:GetGroundUseAction(position, spellbook)
			end
		elseif spell_id == nil then
--   两个特殊动作不走通用 GetGroundUseAction：
--     船炮 → playeractionpicker:GetCannonAimActions（165 行）
--     高尔夫 → GetGolfAimActions（184 行）
--   ★ 它们都需要「玩家正站在船上/球场上」这一额外上下文。
			if actioncode == ACTIONS.BOAT_CANNON_SHOOT.code then
				lmb = self.inst.components.playeractionpicker:GetCannonAimActions(self.inst, position, false)[1]
			elseif actioncode == ACTIONS.GOLF_START_CHARGING.code then
				lmb = self.inst.components.playeractionpicker:GetGolfAimActions(position, false)[1]
            else
                lmb, rmb = self:GetGroundUseAction(position)
            end
		end
        ClearClientRequestedAction()
        if isreleased then
            self.remote_controls[CONTROL_CONTROLLER_ACTION] = nil
        end

        --Possible for lmb action to switch to rmb after autoequip
        lmb =  (lmb ~= nil and
                lmb.action.code == actioncode and
                lmb.action.mod_name == mod_name and
                lmb)
            or (rmb ~= nil and
                rmb.action.code == actioncode and
                rmb.action.mod_name == mod_name and
                rmb)
            or nil

--★ 1031-1041 行：与服务端 974-984 行完全同构的执行段。
--   ★★ 1037-1040 行被注释掉的三个 print 是**调试残留**：
--     它们本该在「客户端上报的动作没算出来」时打印失败信息。
--   ⚠ 值得注意的是：K 把失败打印**注释掉**了。
--     ⇒ 后果：任何「意图编号不匹配」的失败都是**静默**的。
--     这对一个协议适配层来说是危险的 —— 它让不匹配无法被观测。
--     推理依据：全文件 10+ 处这样的注释掉的失败日志
--       （980/1038/1229/1273/2338/4298/4961/5114）。
--     推测原因：生产环境里客户端与服务端版本不一致时会刷屏。
--   ⇒ 但这也意味着：**版本不一致的模组组合会静默丢动作**而非报错。
--     这是模组作者排查「动作不生效」时最应该先看的线索 ——
--       因为日志里什么都不会写。
        if lmb ~= nil then
            if lmb.action.canforce and not noforce then
                lmb:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
                lmb.forced = true
            end
			self:DoAction(lmb, spellbook)
        --elseif mod_name ~= nil then
            --print("Remote controller action button action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
        --else
            --print("Remote controller action button action failed: "..tostring(ACTION_IDS[actioncode]))
        end
    end
end

--★ 【OnRemoteControllerActionButtonDeploy(invobject, position, rotation, isreleased)】
--   ★ 与另外两个 ControllerActionButton* 变体最大的差异：
--     ★ **没有 SetClientRequestedAction / ClearClientRequestedAction 包裹**。
--     因为部署动作不需要 picker 查询 —— 1059 行直接构造 BufferedAction。
--   ⇒⇒ 部署是三个变体里**唯一不做动作重算**的，
--     安全性依赖 1051 行的归属校验（而非 code 匹配）。
function PlayerController:OnRemoteControllerActionButtonDeploy(invobject, position, rotation, isreleased)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.inst.components.combat:SetTarget(nil)

--   ★ 1049 行与另外两个变体的写法差别：`not isreleased and 0 or nil`
--     （一行完成「按下设 0 / 松开清 nil」），比另外两个变体的
--     「先设 0 → 末尾再判断 isreleased 清 nil」更简洁，但三者行为一致。
        self.remote_controls[CONTROL_CONTROLLER_ACTION] = not isreleased and 0 or nil

        if invobject.components.inventoryitem ~= nil and invobject.components.inventoryitem:GetGrandOwner() == self.inst then
            --Must match placer:GetDeployAction(), with an additional distance = 1 parameter
			local action =
				self.inst.components.inventory and
--   ★ 特例：拿着小船（boatbuilder 标签）且举着漂浮物时，部署动作是 DEPLOY_FLOATING。
--     这个二选一必须与客户端 817 行的 placer:GetDeployAction() 结果一致。
				self.inst.components.inventory:IsFloaterHeld() and
				invobject:HasTag("boatbuilder") and
				ACTIONS.DEPLOY_FLOATING or
				ACTIONS.DEPLOY
			self:DoAction(BufferedAction(self.inst, nil, action, invobject, position, nil, 1, nil, rotation or 0))
        --else
            --print("Remote controller action button deploy failed")
        end
    end
end

--★ 【DoControllerAltActionButton】手柄 Y 键（CONTROLLER_ALTACTION）。
--   ★★ 注意 1069-1081 行：Y 键**优先取消**各种瞄准态，而 X 键会尝试执行它们。
--     1075 行的 `elseif self:IsAOETargeting() then CancelAOETargeting(); return end`
--     ⇒ 「X 确认 / Y 取消」的手感约定在代码层面被严格实现。
function PlayerController:DoControllerAltActionButton()
    self:ClearActionHold()

--   ★ 1069-1081 行的取消优先级：建造放置 > 部署放置 > AOE 瞄准。
--   ⚠ 1080 行注释掉的 ControllerTargetLock(false) 说明目标锁定取消被移除。
--     ⇒ 目标锁定只能通过 CONTROL_TARGET_LOCK（711 行）切换。
    if self.placer_recipe ~= nil then
        self:CancelPlacement()
        return
    elseif self.deployplacer ~= nil then
        self:CancelDeployPlacement()
        return
    elseif self:IsAOETargeting() then
        self:CancelAOETargeting()
        return
	--elseif self:IsControllerTargetLockEnabled() then
	--	self:ControllerTargetLock(false)
	--	return
    end

    self.actionholdtime = GetTime()

--   actionholdtime = GetTime()：记录长按起点。
--     ★ 这是 2976-2980 行「按住 8 秒进入长按重复」的计时基准。
    local lmb, act = self:GetGroundUseAction()
    local isspecial = nil
--   ★ obj = act.target：Y 键先尝试「点地动作」，失败再退回「选中目标」。
--     这与 X 键的顺序相反（X 先试目标再试点地），是手感上的刻意区分。
	local obj = act ~= nil and act.target or nil
    if act == nil then
        obj = self:GetControllerTarget()
        if obj ~= nil then
            lmb, act = self:GetSceneItemControllerAction(obj)
--   APPLYCONSTRUCTION（应用到容器，如裂缝祭坛）的 UI 拦截。
--   1099 行注释："e.g. rift offering has a local confirmation popup"
--     → 需要玩家在本地弹窗确认，所以**直接 return 不发 RPC**，
--       等玩家在 UI 里确认后由 UI 自己发。这是本地 UI 插队的合法场景。
			if act ~= nil and act.action == ACTIONS.APPLYCONSTRUCTION then
				local container = act.target ~= nil and act.target.replica.container
				if container ~= nil and
					container.widget ~= nil and
					container.widget.overrideactionfn ~= nil and
					container.widget.overrideactionfn(act.target, self.inst)
					then
					--e.g. rift offering has a local confirmation popup
					return
				end
			end
        end
        if act == nil then
--   ★ GetGroundUseSpecialAction(position, true) —— right=true 说明是右键语义。
--     与 X 键的 false 区分：不同上下文的 GetPointSpecialActions。
			act = self:GetGroundUseSpecialAction(nil, true)
			if act ~= nil then
				obj = nil
				isspecial = true
--   ★★ 1109 行是本函数的核心分支：尝试进入 AOE 瞄准/蓄力。
--     `if self:TryAOETargeting() or self:TryAOECharging(nil, true) then return end`
--   ★★ 短路求值：先试瞄准，再试蓄力。任一成功就 return（不执行后续）。
--     ⇒ 「按住 Y 进入蓄力」的实现；同时可触发时瞄准优先。
--   ⚠ 疑似缺陷（互斥性依赖顺序）：若某物品同时支持 aoetargeting 与
--     aoecharging（如未来的复合道具），永远只会进瞄准，无法蓄力。
--     推理依据：TryAOETargeting（1609 行）返回 true 时，
--       or 的短路使 TryAOECharging 根本不被调用。
--     影响：现实中双组件物品罕见（法杖类只瞄准、弹弓类只蓄力）。
			elseif self:TryAOETargeting() or self:TryAOECharging(nil, true) then
				return
			else
--   骑乘中的交互：RUMMAGE（翻找坐骑的箱子）。
--   1118 行：角色自己是法术书（韦布斯特/温蒂）→ USESPELLBOOK。
--   1121 行：兜底 DISMOUNT（下坐骑）。
				local rider = self.inst.replica.rider
				local mount = rider and rider:GetMount() or nil
				local container = mount and mount.replica.container or nil
				if container and container:IsOpenedBy(self.inst) then
					obj = self.inst
					act = BufferedAction(obj, obj, ACTIONS.RUMMAGE)
				elseif self.inst.components.spellbook and self.inst.components.spellbook:CanBeUsedBy(self.inst) then
					obj = self.inst
					act = BufferedAction(obj, obj, ACTIONS.USESPELLBOOK)
				elseif mount then
					obj = self.inst
					act = BufferedAction(obj, obj, ACTIONS.DISMOUNT)
				else
					--Still need to let the server know our controller alt action button is down
					if self.remote_controls[CONTROL_CONTROLLER_ALTACTION] == nil then
						self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = 0
						SendRPCToServer(RPC.ControllerAltActionButton)
					end
					return
				end
			end
        end
    end

--   准星可见时才 Ping（在实体上画涟漪）。这是纯表现，无网络影响。
	if self.reticule ~= nil and self.reticule.reticule ~= nil and self.reticule.reticule.entity:IsVisible() then
		self.reticule:PingReticuleAt(act:GetDynamicActionPoint())
    end

    local maptarget = self:GetMapTarget(act)
    if maptarget ~= nil then
        local forced_actiondef = act.action.map_only and act.action or nil
		self:PullUpMap(maptarget, forced_actiondef)
        return
    end

--   1147-1187：与 DoControllerActionButton 886-939 完全同构的三分支发送。
--   ★ 二者的 RPC 差异只有一个：ControllerAltActionButton vs ControllerActionButton。
    if self.ismastersim then
        self.inst.components.combat:SetTarget(nil)
    elseif obj ~= nil then
        if self.locomotor == nil then
			act.non_preview_cb = function()
				self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = 0
				SendRPCToServer(RPC.ControllerAltActionButton, act.action.code, obj, nil, act.action.canforce, act.action.mod_name)
			end
		else
			--Still need to let the server know our controller alt action button is down
			if self.remote_controls[CONTROL_CONTROLLER_ALTACTION] == nil then
				self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = 0
				SendRPCToServer(RPC.ControllerAltActionButton)
			end
			if self:CanLocomote() then
				act.preview_cb = function()
					local isreleased = not TheInput:IsControlPressed(CONTROL_CONTROLLER_ALTACTION)
					self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = not isreleased and 0 or nil
					SendRPCToServer(RPC.ControllerAltActionButton, act.action.code, obj, isreleased, nil, act.action.mod_name)
				end
			end
        end
    elseif self.locomotor == nil then
		act.non_preview_cb = function()
			self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = 0
--   ControllerAltActionButtonPoint 的参数里 isspecial 在 noforce 之后（位置不同！）。
--   ⚠ 疑似缺陷（协议脆弱，非现行 bug）：isspecial 在这里排第 7 位，
--     而 905 行的 ControllerActionButtonPoint 里它排第 10 位。
--     已核实两个 RPC 的形参顺序本身就不同，故当前**是正确的**：
--       networkclientrpc.lua:249 ControllerActionButtonPoint (action,x,z,isreleased,
--           noforce,mod_name,platform,platform_relative,isspecial,spellbook,spell_id)
--       networkclientrpc.lua:329 ControllerAltActionButtonPoint (action,x,z,isreleased,
--           noforce,isspecial,mod_name,platform,platform_relative)
--     ⇒ 但同一个「点地动作」的两条 RPC 用了不同的参数序，且两处调用点
--       （1172 与 1184）都在手写全量参数，任何一侧改签名都会静默错位。
--     建议：改用尾部的 table 或具名 table 传参。
			SendRPCToServer(RPC.ControllerAltActionButtonPoint, act.action.code, act.pos.local_pt.x, act.pos.local_pt.z, nil, act.action.canforce, isspecial, act.action.mod_name, act.pos.walkable_platform, act.pos.walkable_platform ~= nil)
		end
	else
		--Still need to let the server know our controller alt action button is down
		if self.remote_controls[CONTROL_CONTROLLER_ALTACTION] == nil then
			self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = 0
			SendRPCToServer(RPC.ControllerAltActionButton)
		end
		if self:CanLocomote() then
			act.preview_cb = function()
				local isreleased = not TheInput:IsControlPressed(CONTROL_CONTROLLER_ALTACTION)
				self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = not isreleased and 0 or nil
				SendRPCToServer(RPC.ControllerAltActionButtonPoint, act.action.code, act.pos.local_pt.x, act.pos.local_pt.z, isreleased, nil, isspecial, act.action.mod_name, act.pos.walkable_platform, act.pos.walkable_platform ~= nil)
			end
		end
    end

    self:DoAction(act)
end

--【OnRemoteControllerAltActionButton】Y 键的服务端对端。
--   1211-1212 行的注释很坦诚：
--     "Possible for rmb action to switch to lmb after autoequip /
--      Probably not, but fairly inexpensive to be safe =)"
--     → 与 963 行同款的对称放宽，且 K 自己承认「大概不会发生，但加上很便宜」。
--   ⚠ 这是典型的「为假想场景放宽校验」——1217-1220 行让**左键动作也能用右键 RPC 触发**。
--     结合 1213 行的 rmb 优先，攻击面：客户端可用 Y 键 RPC 执行任意物品的 LMB 动作。
--     缓解因素：仍需服务端重算匹配 + 距离校验。
function PlayerController:OnRemoteControllerAltActionButton(actioncode, target, isreleased, noforce, mod_name)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.inst.components.combat:SetTarget(nil)

        self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = 0

		if actioncode == nil then
			assert(isreleased == nil) --actioncode nil means all params must be nil
			return
		end

        self:ClearControlMods()
--★★ 【OnRemoteControllerAltActionButton】的内部四段：
--   ① 1194 行清战斗目标 / 1196 行设按键态
--   ② 1198-1201 行「无参 RPC」自检（assert isreleased == nil）
--   ③ 1203-1206 行重算：ClearControlMods → SetClientRequestedAction →
--     GetSceneItemControllerAction → ClearClientRequestedAction
--   ④ 1207-1221 行抬起处理 + 反向回退链
--   ⚠ ③ 的顺序（ClearControlMods 在 Set 之前）说明：
--     服务端每次都先清掉上次残留的修饰键，再按客户端上报的掩码重建。
--     这是「状态重建」范式，比「增量修改」更抗乱序包。
--   ⇒★ 与 4924 行的 ClearControlMods 在 ClearClientRequestedAction **之后**
--     形成对比 —— 说明这里的顺序是刻意的（不能提前清修饰键）。
--     推理依据：1203 行 ClearControlMods 在 1204 行 SetClientRequestedAction 之前；
--       而 4920-4924 行的顺序是 ClearClientRequestedAction → ClearControlMods。
        SetClientRequestedAction(actioncode, mod_name)
        local lmb, rmb = self:GetSceneItemControllerAction(target)
        ClearClientRequestedAction()
        if isreleased then
            self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = nil
        end

--   ★★ 1211-1212 行 K 的注释最坦诚：
--     "Possible for rmb action to switch to lmb after autoequip /
--      Probably not, but fairly inexpensive to be safe =)"
--     → 与 X 键版 963 行同款的对称放宽，且 K 自己承认「大概不会发生」。
--   ⚠ 这是典型的「为假想场景放宽校验」——1217-1220 行让**左键动作也能用
--     右键 RPC 触发**。
--     ⚠⚠ 推理依据与影响：
--       1217 行 `or (lmb ~= nil and lmb.action.code == actioncode and ...)`
--       ⇒ 攻击面：客户端可用 Y 键 RPC 执行任意物品的 LMB 动作。
--       缓解因素：仍需服务端重算匹配（1205 行）+ 距离校验 + CanTarget。
--     ★ 这是一个**有意识的权衡**：用一点安全性换「不因自动装备而丢动作」。
--       相比之下 963 行（X 键）的放宽是**必需**的（Y 键没有 LMB 通道）。
--   ⇒ 所以 1217 行比 963 行更「宽松」，是本文件校验链条上最松的一处。
        --Possible for rmb action to switch to lmb after autoequip
        --Probably not, but fairly inexpensive to be safe =)
        rmb =  (rmb ~= nil and
                rmb.action.code == actioncode and
                rmb.action.mod_name == mod_name and
                rmb)
            or (lmb ~= nil and
                lmb.action.code == actioncode and
                lmb.action.mod_name == mod_name and
                lmb)
            or nil

--★ 1223-1233 行：force 时对齐预测位置 + 执行。
--   ★ 与 X 键版（974-979 行）逐字同构，差异只有三个：
--     ① 回退链方向相反（rmb 优先）
--     ② 没有 mod_name 参数（Y 键不发模组名）
--     ③ DoAction 无 spellbook 第二参数
--   ⚠ 1229-1232 行又是被注释掉的失败日志（见 1037 行的分析）。
        if rmb ~= nil then
            if rmb.action.canforce and not noforce then
                rmb:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
                rmb.forced = true
            end
            self:DoAction(rmb)
        --elseif mod_name ~= nil then
            --print("Remote controller alt action button action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
        --else
            --print("Remote controller alt action button action failed: "..tostring(ACTION_IDS[actioncode]))
        end
    end
end

--★ 【OnRemoteControllerAltActionButtonPoint】Y 键点地版的服务端对端。
--   ★ 1245-1249 行：isspecial 时走 GetGroundUseSpecialAction(position, true)，
--     否则走 GetGroundUseAction(position)。
--     ⚠ 与 996-1014 行的 X 键版对比：X 键版多了船炮/高尔夫分支
--       （1007/1009 行），Y 键版没有。
--     ⇒ 这是**有意的**：船炮与高尔夫只有左键语义。
function PlayerController:OnRemoteControllerAltActionButtonPoint(actioncode, position, isreleased, noforce, isspecial, mod_name)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.inst.components.combat:SetTarget(nil)

        self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = 0
        self:ClearControlMods()
        local lmb, rmb
        SetClientRequestedAction(actioncode, mod_name)
        if isspecial then
            rmb = self:GetGroundUseSpecialAction(position, true)
        else
            lmb, rmb = self:GetGroundUseAction(position)
        end
        ClearClientRequestedAction()
        if isreleased then
            self.remote_controls[CONTROL_CONTROLLER_ALTACTION] = nil
        end

--★ 1255-1265 行：与服务端 1020-1029 行同构的回退链（rmb 优先）。
--   ⚠ 1267-1272 行的 force 处理与 1032-1035 行完全相同 ——
--     说明这三个 Controller*OnRemote* 变体是**复制粘贴**出来的。
--     复制粘贴的直接证据：三处的注释文字完全一致。
--   ⚠ 疑似缺陷（复制粘贴的代价）：
--     任何对这三点共有的 force/回退逻辑的修改都要改三处。
--     推理依据：944/988/1192/1237 四个函数的开头守卫与结尾执行段逐字相同。
        --Possible for rmb action to switch to lmb after autoequip
        --Probably not, but fairly inexpensive to be safe =)
        rmb =  (rmb ~= nil and
                rmb.action.code == actioncode and
                rmb.action.mod_name == mod_name and
                rmb)
            or (lmb ~= nil and
                lmb.action.code == actioncode and
                lmb.action.mod_name == mod_name and
                lmb)
            or nil

        if rmb ~= nil then
            if rmb.action.canforce and not noforce then
                rmb:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
                rmb.forced = true
            end
            self:DoAction(rmb)
--★ 1273-1278 行：Y 键点地版的收尾。与 1031-1041 行同构。
        --elseif mod_name ~= nil then
            --print("Remote controller alt action button point action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
        --else
            --print("Remote controller alt action button point action failed: "..tostring(ACTION_IDS[actioncode]))
        end
    end
end

--★★ 【DoControllerAttackButton】手柄攻击键。★ 详见下一段的详细注释。
--   ★★ 它与 DoControllerActionButton（794 行）的最大差异：
--     ① 不构造 preview_cb 的三种变体，只有一条路径
--     ② 多了「空气攻击」的五种例外判据（1334 行）
--     ③ 多了 attack_buffer 的延迟机制（1356 行构造，2805 行消费）
--   ⇒ 第三点是理解攻击的关键：**攻击被特殊对待**，
--     因为它必须在状态图的 attack 状态下执行。
--★★★ 【DoControllerAttackButton(target)】手柄扳机/X 攻击。target 通常为 nil。
--   结构：
--   ① 1282-1294 target==nil 且处于特殊状态时的三条早退路径
--   ② 1296-1314 target 非 nil（连击重定向）时的校验
--   ③ 1315-1354 无 target 时从 controller_attack_target 取，并判断「空气攻击」
--   ④ 1356-1380 构造 ATTACK 动作并走标准三分支发送
function PlayerController:DoControllerAttackButton(target)
--   ★ 参数 target 由 3151 行传入（连击攻击时非 nil），其余调用点传 nil。
	if target == nil then
--   ★ 1283 行的两个早退：AOE 瞄准中 / 坐在椅子上时攻击无效。
--     理由：AOE 瞄准时按扳机会误放法术；椅子上（笼子/椅子的拟态攻击）攻击无效。
		if self:IsAOETargeting() or self.inst:HasTag("sitting_on_chair") then
			return
--   ★★ IsOverrideAttack 的第三返回值体系（1981 行）：
--     「攻击键被重定义为别的功能」——如温蒂的「 Abigail 出来」、
--     猎犬的「扑咬」等。这里改为 PushEvent("attackbutton") 让对应 prefab 接管。
--   1286 行的 PushEventImmediate：★立即派发，不排队 ——
--     攻击手感要求零延迟，这与普通 PushEvent 的排队语义不同。
		elseif self:IsOverrideAttack() then
			self.inst:PushEventImmediate("attackbutton")
--   --Need to let server know NOW, wheter we have prediciton or not.
--   → K 的原注释有拼写错误（wheter / prediciton），照录。
--   ★「不管有没有预测能力都要立刻通知」——因为 overrideattack 可能改变玩家位置
--     （如韦布斯特的口哨召唤），服务器必须马上知道。
			--Need to let server know NOW, wheter we have prediciton or not.
			if not self.ismastersim and self.remote_controls[CONTROL_CONTROLLER_ATTACK] == nil then
				self.remote_controls[CONTROL_CONTROLLER_ATTACK] = 0
				SendRPCToServer(RPC.ControllerAttackButton, true)
			end
			return
		end
	end

--   ★ 1297 行的注释点明了防刷机制：连击重定向时若 remote_controls 还在冷却，
--     直接 return —— 避免「持续按住扳机」在每次重定向时都发一次 RPC。
	if target then
        --Don't want to spam the controller attack button when retargetting
        if not self.ismastersim and (self.remote_controls[CONTROL_CONTROLLER_ATTACK] or 0) > 0 then
            return
--============================================================
-- 【第三段】1300-2100 行：攻击 / 库存格子 / 相机 / 放置 / AOE / 攻击目标筛选
--============================================================
        end

--   ★ 双端判定的 attack 状态：客户端有 sg 看状态标签，否则看 inst:HasTag。
--     与 IsBusy:769-777 同样的双端不对称设计。
        if self.inst.sg ~= nil then
            if self.inst.sg:HasStateTag("attack") then
                return
            end
        elseif self.inst:HasTag("attack") then
            return
        end

--   ★★ 攻击前的三重合法性校验（客户端提前拦，服务端还会再查一遍）：
--     ① LocomotorCanAttack(nil, target)：locomotor 能否边移动边攻击这个目标
--        参见 locomotor.lua 的 LocomotorCanAttack（如正在挖矿时不能攻击）
--     ② IsEntityDead(target, true)：目标已死
--     ③ CanEntitySeeTarget：视线判定（模组可改，如-visible-distance）
--   ⇒ 即便如此，服务端 OnRemoteControllerAttackButton:1400 仍会重查 CanTarget。
		if not self.inst.replica.combat:LocomotorCanAttack(nil, target) or
            IsEntityDead(target, true) or
            not CanEntitySeeTarget(self.inst, target) then
            return
        end
    else
--   无显式 target → 取手柄当前选中的攻击目标 controller_attack_target。
        target = self.controller_attack_target
        if target ~= nil then
--   ★ 1318-1326：目标已经是当前战斗目标 → 只发「按钮按下」通知，不重复攻击。
--     这是「按住扳机不重复攻击同一目标」的实现，靠 1322 行的 nil 检查去重 RPC。
            if target == self.inst.replica.combat:GetTarget() then
                --Still need to let the server know our controller attack button is down
                if not self.ismastersim and
					--self.locomotor == nil and
                    self.remote_controls[CONTROL_CONTROLLER_ATTACK] == nil then
                    self.remote_controls[CONTROL_CONTROLLER_ATTACK] = 0
                    SendRPCToServer(RPC.ControllerAttackButton, true)
                end
                return
--   CanTarget 为假 → 目标作废（掉到 nil）。
--     参见 combat_replica.lua:311 —— 判据是目标是否已死/是否已归属别人。
            elseif not self.inst.replica.combat:CanTarget(target) then
                target = nil
            end
        end
--   --V2C: controller attacks still happen even with no valid target
--   ★ 1332 行的 target==nil 块：即使没有目标也允许「挥空」。
--     为什么要挥空：攻击是「播放动画 + 判定命中」，玩家按了就得有反应，
--     否则远程客户端的本地动画不会播，且服务端状态与客户端不一致。
        --V2C: controller attacks still happen even with no valid target
		if target == nil then
			--exceptions:
--★ no_air_attack 的五种例外（这个表就是「什么时候不能空挥」的完整清单）：
--     ① directwalking：正在用摇杆直接行走（手会忙）
--     ② HasAnyTag("playerghost","weregoose")：幽灵/沃古斯形态
--     ③ classified.inmightygym > 0：练力场（Infinite Gym）里
--     ④ GetGameModeProperty("no_air_attack")：游戏模式级开关
--     ⑤ inventory:IsHeavyLifting() or IsFloaterHeld()：举着重物/漂浮物
--   ⇒ 注意前三项是「状态」，后两项是「装备」——它们都会用不同的 tag/字段表达。
			local no_air_attack =
				self.directwalking or
				self.inst:HasAnyTag("playerghost", "weregoose") or
				(self.classified and self.classified.inmightygym:value() > 0) or
				GetGameModeProperty("no_air_attack")

			if not no_air_attack then
				local inventory = self.inst.replica.inventory
				no_air_attack = inventory:IsHeavyLifting() or inventory:IsFloaterHeld()
			end

			if no_air_attack then
				--Still need to let the server know our controller attack button is down
				if not self.ismastersim and self.remote_controls[CONTROL_CONTROLLER_ATTACK] == nil then
					self.remote_controls[CONTROL_CONTROLLER_ATTACK] = 0
					SendRPCToServer(RPC.ControllerAttackButton, true)
				end
				return
			end
		end
    end

--   ★ 构造 ATTACK 的 BufferedAction。1357 行没有传 distance，
--     说明攻击距离由 actions.lua 的 ATTACK.rangecheckfn 决定（默认 3）。
    local act = BufferedAction(self.inst, target, ACTIONS.ATTACK)

    if self.ismastersim then
        self.inst.components.combat:SetTarget(nil)
    elseif self.locomotor == nil then
--   ★ 1362 行 `self.remote_controls[CONTROL_CONTROLLER_ATTACK] = BUTTON_REPEAT_COOLDOWN`
--     与 1368 行的差异：non_preview_cb 路径设 0（立即可再发），
--     preview 路径设 0.5。
--   ⚠ 疑似缺陷（不一致）：non_preview_cb 意味着「无 locomotor，无法缓冲」，
--     动作会立刻执行，无需防刷（也确实不会刷）。但 0 与 0.5 的语义不一致
--     会让 IsControlPressed 在两种客户端上返回不同的「按下中」时长。
--     推理依据：对比 1362 行与 1368 行，以及 1975 行 DoAttackButton 路径
--       统一用 0（本文件没有对应的 BUTTON_REPEAT_COOLDOWN 用法）。
		act.non_preview_cb = function()
			self.remote_controls[CONTROL_CONTROLLER_ATTACK] = BUTTON_REPEAT_COOLDOWN
			SendRPCToServer(RPC.ControllerAttackButton, target, nil, act.action.canforce)
		end
	else
		--Still need to let the server know our controller attack button is down
		if self.remote_controls[CONTROL_CONTROLLER_ATTACK] == nil then
			self.remote_controls[CONTROL_CONTROLLER_ATTACK] = BUTTON_REPEAT_COOLDOWN
			SendRPCToServer(RPC.ControllerAttackButton, true)
		end
--   ★★ preview_cb 的 1374 行与 1362 行对比：
--     1374 行 `not isreleased and BUTTON_REPEAT_COOLDOWN or nil` —— 抬起时置 nil。
--   ⇒ 所以 BUTTON_REPEAT_COOLDOWN 实际上是「攻击按钮被视作按下的时长」，
--     不是「重发间隔」。它在 1965 行（键盘路径）也是同样用法。
		if self:CanLocomote() then
			act.preview_cb = function()
				local isreleased = not TheInput:IsControlPressed(CONTROL_CONTROLLER_ATTACK)
				self.remote_controls[CONTROL_CONTROLLER_ATTACK] = not isreleased and BUTTON_REPEAT_COOLDOWN or nil
				SendRPCToServer(RPC.ControllerAttackButton, target, isreleased)
			end
		end
    end

    self:DoAction(act)
end

--【OnRemoteControllerAttackButton(target, isreleased, noforce)】服务端对端。
--   ★ 与 944 行的 ControllerActionButton 不同，本函数**不重算动作**，
--     而是把攻击塞进 self.attack_buffer 交给 OnUpdate 执行。
--   为什么：攻击需要 sg 的 attack 状态配合，OnControl 时刻状态可能还没切。
function PlayerController:OnRemoteControllerAttackButton(target, isreleased, noforce)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        --Check if target is valid, otherwise make
        --it nil so that we still attack and miss.
		self.remote_controls[CONTROL_CONTROLLER_ATTACK] = 0
--   target == true：客户端只发了「按钮按下」。
--   1390 行注释掉的重复赋值：1387 行已经设过了。
        if target == true then
            --Special case, just flagging the button as down
			--self.remote_controls[CONTROL_CONTROLLER_ATTACK] = 0
			if self:IsOverrideAttack() then
				self.inst:PushEventImmediate("attackbutton")
			end
--   ★ not noforce 分支：客户端没按强制攻击键 → 允许重新选目标。
--   noforce 分支（1405-1415）：客户端已按强制 → 目标不可重选（1400 行跳过）。
--   ★ noforce=true 时若 CanTarget 为假，构造一个 target=nil 的 ATTACK 并
--     设置 overridedest = self.inst（1413 行）——
--     这是「强制攻击时打空气」的动作，动作执行体据此决定特效落点。
        elseif not noforce then
--   ★★ "abouttoattack" vs "attack" 的双标签判定：
--     1817/1940/3114 行有完全相同的三元表达式。
--     → remote_authority 且正在预测时查 "abouttoattack"（发起攻击的过渡态），
--       否则查 "attack"（真正在打）。
--   ⇒ 为什么可空？因为 stategraph 可以自定义标签集。
--     但这意味着**任何自定义状态图若不用 attack 标签，攻击连击就会失效**。
--     ⚠ 疑似缺陷（隐式契约）：没有 sg 时（第 1820/1806 行的 elseif 分支）
--       只查 HasTag("attack")，与有 sg 时的判定不对称。
--     推理依据：1816-1822 行的 if/elseif 结构。
			if self.inst.sg:HasStateTag(self.remote_authority and self.remote_predicting and "abouttoattack" or "attack") then
--   ★★ chainattack_cb = function() ... end —— **连击攻击的延迟回调**。
--   场景：玩家在攻击动画（attack 状态）中再次按下扳机，
--     此时不能立即开始新攻击（会打断当前动画），
--     于是把「再打一次」的请求**存进状态图的 statemem**，
--     由 3110-3120 行的 OnUpdate 在攻击结束前触发。
--   ⚠ 疑似缺陷（参数丢失）：1397 行 `self:OnRemoteControllerAttackButton(target)`
--     **丢掉了 isreleased 与 noforce**。若客户端在发起连击的同时松开了扳机，
--     服务器执行时 isreleased=nil → 1416 行不清理 remote_controls，
--     服务器会认为扳机还按着，直到下一个 RPC。
--     推理依据：1942 行的 chainattack_cb 同样丢参（丢 isleftmouse/isreleased），
--       说明这是复制粘贴的产物而非有意为之。
--     缓解：ControlC 抬起会发 StopControl（546 行）独立于 isreleased，
--       所以最终状态仍会被清理，但中间会有一帧的「按住」状态。
                self.inst.sg.statemem.chainattack_cb = function()
                    self:OnRemoteControllerAttackButton(target)
                end
            else
--   ★ CanTarget 失败则 target=nil → 「打空气」，不是丢弃请求。
                target = self.inst.components.combat:CanTarget(target) and target or nil
                self.attack_buffer = BufferedAction(self.inst, target, ACTIONS.ATTACK, nil, nil, nil, nil, true)
                self.attack_buffer._controller = true
                self.attack_buffer._predictpos = true
            end
        else
            if self.inst.components.combat:CanTarget(target) then
                self.attack_buffer = BufferedAction(self.inst, target, ACTIONS.ATTACK)
                self.attack_buffer._controller = true
            else
                self.attack_buffer = BufferedAction(self.inst, nil, ACTIONS.ATTACK, nil, nil, nil, nil, true)
                self.attack_buffer._controller = true
                self.attack_buffer._predictpos = true
                self.attack_buffer.overridedest = self.inst
            end
        end
		if isreleased then
			self.remote_controls[CONTROL_CONTROLLER_ATTACK] = nil
		end
    end
end

--【DoControllerDropItemFromInvTile】手柄在库存格上「丢弃」。
--   1424-1426 行的双条件：
--     未锁定在格子里（IsLockedInSlot）→ 可丢
--     或者 single（长按一次一个）且物品可堆叠 → 可丢
--   ★ 单（single）= 移出 1 个；全 = 移出整堆。
function PlayerController:DoControllerDropItemFromInvTile(item, single)
	if item and item.replica.inventoryitem and
		(	not item.replica.inventoryitem:IsLockedInSlot() or
			(single and item.replica.stackable and item.replica.stackable:IsStack())
		)
	then
		self.inst.replica.inventory:DropItemFromInvTile(item, single)
	end
end

function PlayerController:DoControllerInspectItemFromInvTile(item)
    self.inst.replica.inventory:InspectItemFromInvTile(item)
end

--【DoControllerUseItemOnSelfFromInvTile】在库存格上「对自己用」。
--   1438-1440 行：设置了**长按重复的三件套**：
--     actionholdtime / lastheldaction / actionrepeatfunction
--   ★★★ 这三个字段是长按重复机制的全部。2588 行 RepeatHeldAction 每帧调用
--     actionrepeatfunction；2609/2619 行设置 no_predict_fastforward。
--   ⇒ 1443 行 `if item == nil then self.actionrepeatfunction = nil return end`：
--     长按重发时 item 参数为 nil（104 行没有参数），必须自己取光标物品。
function PlayerController:DoControllerUseItemOnSelfFromInvTile(item)
    if item ~= nil then
        self.actionholdtime = GetTime()
        self.lastheldaction = nil
        self.actionrepeatfunction = self.DoControllerUseItemOnSelfFromInvTile
    else
        item = self:GetCursorInventoryObject()
        if item == nil then self.actionrepeatfunction = nil return end
    end
--   ★ 可部署物品在鼠标模式下进入放置模式（而不是直接使用）。
--     这是「手持火把右键出现放置预览」的实现。
--   1447 行的 IsGrandOwner 校验：只能部署自己的东西。
    if not self.deploy_mode and
        item.replica.inventoryitem:IsDeployable(self.inst) and
        item.replica.inventoryitem:IsGrandOwner(self.inst) then
		self.deploy_mode = true
		return
    end
    self.inst.replica.inventory:ControllerUseItemOnSelfFromInvTile(item)
end

--【DoControllerUseItemOnSceneFromInvTile】在库存格上「对世界用」。
--   ★ 1464-1468 行是个特例：不是自己背里的、且未锁定 → 从容器里**取出**。
--     这是手柄操作的「一键拿取」：从马厩/冰箱里直接把物品拿到手上，
--     免去「先按方向键选中容器、再打开、再选物品」。
--   1465 行 GetCursorInventorySlotAndContainer 拿的是「光标所在的槽位与容器」，
--     这是 controller-only 的 API（788 行，鼠标模式下返回 nil）。
function PlayerController:DoControllerUseItemOnSceneFromInvTile(item)
    if item ~= nil then
        self.actionholdtime = GetTime()
        self.lastheldaction = nil
        self.actionrepeatfunction = self.DoControllerUseItemOnSceneFromInvTile
    else
        item = self:GetCursorInventoryObject()
        if item == nil then self.actionrepeatfunction = nil return end
    end
	local inventoryitem = item.replica.inventoryitem
	if inventoryitem and not inventoryitem:IsGrandOwner(self.inst) then
        local slot, container = self:GetCursorInventorySlotAndContainer()
		if slot and container and not inventoryitem:IsLockedInSlot() then
            container:MoveItemFromAllOfSlot(slot, self.inst)
        end
    else
        self.inst.replica.inventory:ControllerUseItemOnSceneFromInvTile(item)
    end
end

--【RotLeft / RotRight】相机 45° 步进旋转。
--   1479 行 `local rotamount = 45 ---90-- ...`：
--     英文原注释留下了曾经的方案：洞穴里 22.5°，后来改回统一 45°。
--   ★ 步进而非连续旋转：手柄的「视角吸附」是 DST 手柄体验的核心之一，
--     与鼠标的自由旋转共存靠的就是这个 45° 网格。
function PlayerController:RotLeft(speed)
--   --V2C: exception for drone cam: zoom disabled, but rotate allowed
--   → 使用无人机（韦德沃克斯的 Drone）时相机不可控，但允许旋转。
--     这个例外同时出现在 4441 行 DoCameraControl。
	--V2C: exception for drone cam: zoom disabled, but rotate allowed
	if not (TheCamera:CanControl() or self.inst:HasTag("using_drone_remote")) then
        return
    end
    local rotamount = 45 ---90-- TheWorld:HasTag("cave") and 22.5 or 45
    if not IsPaused() then
--   ★ 带速度的旋转（手柄摇杆）：SetContinuousHeadingTarget(target, -speed)。
--   1482 行的取整公式 `(math.ceil((heading - speed)/rotamount) - 1) * rotamount`：
--     向下取到 45° 网格，减去一个格——这是「转一整格」而非「转到最近格」的手感。
		if speed then
			TheCamera:SetContinuousHeadingTarget((math.ceil((TheCamera:GetHeading() - speed) / rotamount) - 1) * rotamount, -speed)
		else
			TheCamera:SetHeadingTarget(TheCamera:GetHeadingTarget() - rotamount)
		end
        --UpdateCameraHeadings()
--   ★ 暂停 + 地图打开时用 Snap()：地图内旋转要立刻生效（不能有插值）。
    elseif self.inst.HUD ~= nil and self.inst.HUD:IsMapScreenOpen() then
        TheCamera:SetHeadingTarget(TheCamera:GetHeadingTarget() - rotamount)
        TheCamera:Snap()
    end
end

function PlayerController:RotRight(speed)
	--V2C: exception for drone cam: zoom disabled, but rotate allowed
	if not (TheCamera:CanControl() or self.inst:HasTag("using_drone_remote")) then
        return
    end
    local rotamount = 45 --90--TheWorld:HasTag("cave") and 22.5 or 45
    if not IsPaused() then
		if speed then
			TheCamera:SetContinuousHeadingTarget((math.floor((TheCamera:GetHeading() + speed) / rotamount) + 1) * rotamount, speed)
		else
			TheCamera:SetHeadingTarget(TheCamera:GetHeadingTarget() + rotamount)
		end
        --UpdateCameraHeadings()
    elseif self.inst.HUD ~= nil and self.inst.HUD:IsMapScreenOpen() then
        TheCamera:SetHeadingTarget(TheCamera:GetHeadingTarget() + rotamount)
        TheCamera:Snap()
    end
end

--【GetHoverTextOverride】建造模式下鼠标悬停的提示文字。
--   1515 行的优先级：recipe 自定义函数 > 按 product/name 查字符串 > 「这里」。
--   ★ 1535 行的 `canmouse.data_item` 不存在时返回 nil（不覆盖原提示）。
function PlayerController:GetHoverTextOverride()
    if self.placer_recipe then
        local name = self.placer_recipe.recipedisplaynamefn and self.placer_recipe:recipedisplaynamefn(self.inst)
            or STRINGS.NAMES[string.upper(self.placer_recipe.product or self.placer_recipe.name)]
            or STRINGS.UI.HUD.HERE
        return string.format("%s %s", STRINGS.UI.HUD.BUILD, name)
    end
    return nil
end

--【CancelPlacement(cache)】★ cache 参数是「保留蓝图以便重建」。
--   ★ 为什么需要 cache：HUD 打开/关闭会触发 2709 行的 CancelPlacement(true)，
--     若清掉 recipe，玩家关一下合成菜单就得重新选蓝图。
--   1527-1528 行 K 的注释说明了 V2C 的补丁：
--     "Leave cache alone if recipe is already nil / This can get called
--      repeatedly when controls are disabled"
--   ⚠ 副作用：2806-2811 行 OnUpdate 会在 IsEnabled 后自动重建缓存的 placer，
--     这就是「菜单打开时蓝图仍显示」的机制。
function PlayerController:CancelPlacement(cache)
    if not cache then
        self.placer_cached = nil
    elseif self.placer_recipe ~= nil then
        self.placer_cached = { self.placer_recipe, self.placer_recipe_skin }
        --V2C: Leave cache alone if recipe is already nil
        --     This can get called repeatedly when controls are disabled
    end

    if self.placer ~= nil then
        self.placer:Remove()
        self.placer = nil
    end
    self.placer_recipe = nil
    self.placer_recipe_skin = nil
end

--【CancelDeployPlacement】取消部署放置。
--   1540 行 `self.deploy_mode = not TheInput:ControllerAttached()`：
--     ★ 取消时重置为「鼠标模式默认有 deploy_mode」，所以鼠标玩家每次取消后
--       仍可用右键进入放置。手柄玩家则通过 TOGGLE_DEPLOY_MODE 切换（5552 行）。
function PlayerController:CancelDeployPlacement()
    self.deploy_mode = not TheInput:ControllerAttached()
    if self.deployplacer ~= nil then
        self.deployplacer:Remove()
        self.deployplacer = nil
    end
end

--【StartBuildPlacementMode(recipe, skin)】进入建造模式。
--   ★ 1561 行 testfn：把「能不能在这建」的判定从 placer 组件改为
--     replica.builder:CanBuildAtPoint —— 因为建造合法性（含材料）只有 builder 知道。
--   ★ 这是一个**客户端自定义判定函数**注入服务端组件的范式，
--     它让 placer 无需认识 builder。
function PlayerController:StartBuildPlacementMode(recipe, skin)
    self.placer_cached = nil
    self.placer_recipe = recipe
    self.placer_recipe_skin = skin

    if self.placer ~= nil then
        self.placer:Remove()
    end
    self.placer =
        skin ~= nil and
        SpawnPrefab(recipe.placer, skin, nil, self.inst.userid) or
        SpawnPrefab(recipe.placer)

    self.placer.components.placer:SetBuilder(self.inst, recipe)
    self.placer.components.placer.testfn = function(pt, rot)
        local builder = self.inst.replica.builder
        return builder ~= nil and builder:CanBuildAtPoint(pt, recipe, rot)
    end
end

--【IsTwinStickAiming】双摇杆瞄准（用手柄右摇杆瞄准射击）。
function PlayerController:IsTwinStickAiming()
	return self.reticule ~= nil and self.reticule:IsTwinStickAiming()
end

--【GetAOETargetingPos】当前 AOE 瞄准点的世界坐标（来自准星）。
function PlayerController:GetAOETargetingPos()
    return self.reticule ~= nil and self.reticule.targetpos or nil
end

--【IsAOETargeting】★ 注意它**只看准星**，不看手持物。
--   对比 1579 行的 HasAOETargeting：后者查「当前手持物是否支持 AOE 瞄准」。
--   ⇒ 两个函数名的区别是「**正在瞄**」与「**能瞄**」。
function PlayerController:IsAOETargeting()
    return self.reticule ~= nil and self.reticule.inst.components.aoetargeting ~= nil
end

--【HasAOETargeting】手持物是否具备 AOE 瞄准能力。
--   ★ 1584/1594 行的 allowriding：允许骑乘时使用的道具（如韦德的自行车加速器）。
function PlayerController:HasAOETargeting()
    local item = self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	if item then
		local isriding
		if item.components.aoetargeting and item.components.aoetargeting:IsEnabled() then
			if item.components.aoetargeting.allowriding then
				return true
			end
			isriding = self.inst.replica.rider
			isriding = isriding ~= nil and isriding:IsRiding()
			if not isriding then
				return true
			end
		end
		if item.components.aoecharging and item.components.aoecharging:IsEnabled() then
			if item.components.aoecharging.allowriding then
				return true
			end
--   ⚠ 疑似缺陷（缓存变量语义不一致）：
--     1597 行 `if isriding == nil then` 试图「若之前没算过 riding 就补算」，
--     但 1588/1599 行都把 isriding 赋成了 **布尔值**（isriding ~= nil and ...），
--     所以 isriding 永远不可能是 nil（除非从没进过任何一个分支）。
--   推理依据：1582 行 local isriding 初值为 nil；
--     1587-1588 与 1598-1599 行都是 `isriding = X ~= nil and X:IsRiding()`，
--     结果必然是 true/false，永不为 nil。
--   ⇒ 后果：若手持物**只有** aoecharging 而无 aoetargeting，
--     isriding 保持 nil，1597 行会补算 —— 恰好是正确的；
--     若两个都有，1588 行算出的值被 1599 行跳过 —— 也正确。
--     所以当前行为无误，但 1597 行的判据是**巧合成立**而非显式设计。
--     重构建议：改用 `local isriding_cached = false` 之类的显式标志。
			if isriding == nil then
				isriding = self.inst.replica.rider
				isriding = isriding ~= nil and isriding:IsRiding()
			end
			if not isriding then
				return true
			end
		end
	end
	return false
end

--【TryAOETargeting】开始 AOE 瞄准（魔杖类）。返回是否成功。
--   1612-1617 行：不允许骑乘时，若在骑乘则拒绝。
--   ★ 返回 boolean 的意义：1109 行用它做短路（Try 或 Try 的语义互斥）。
function PlayerController:TryAOETargeting()
    local item = self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
    if item ~= nil and item.components.aoetargeting ~= nil and item.components.aoetargeting:IsEnabled() then
		if not item.components.aoetargeting.allowriding then
			local rider = self.inst.replica.rider
			if rider and rider:IsRiding() then
				return false
			end
		end
        item.components.aoetargeting:StartTargeting()
		return true
    end
	return false
end

--【StartAOETargetingUsing(item)】★ 由 prefab 直接调用（不走 OnControl）。
--   4 个外部调用点：ghostcommand_defs / waxwelljournal / willow_ember / winona_remote。
--   ★ 1626-1630 行的四连清理：这是「按一个外部事件进入瞄准态」的标准收尾，
--     与 1075-1081 行（Y 键的取消链）对称。
function PlayerController:StartAOETargetingUsing(item)
	if item ~= nil and item.components.aoetargeting ~= nil and item.components.aoetargeting:IsEnabled() then
		self:ClearActionHold()
		self:CancelPlacement()
		self:CancelDeployPlacement()
		self:CancelAOETargeting()
		self.inst.replica.inventory:ReturnActiveItem()
		item.components.aoetargeting:StartTargeting()
	end
end

--【GetActiveSpellBook】当前准星是否属于一本法术书。
--   ⚠ 1636 行没有 nil 检查 self.reticule：若 reticule 为 nil 会崩。
--   推理依据：`self.reticule.inst.components.spellbook ~= nil` 首字段即索引。
--     但所有调用点（836/4736/5389）都在 IsAOETargeting 为真之后，
--     而 IsAOETargeting 保证了 reticule ~= nil，故实际安全。
--     隐式契约：调用前必须 reticule ~= nil。
function PlayerController:GetActiveSpellBook()
	return self.reticule.inst.components.spellbook ~= nil and self.reticule.inst or nil
end

function PlayerController:CancelAOETargeting()
    if self.reticule ~= nil and self.reticule.inst.components.aoetargeting ~= nil then
        self.reticule.inst.components.aoetargeting:StopTargeting()
    end
end

--★ _CalcAOEChargingStartingRotation：算蓄力起始朝向。
--   1646-1647 行的英文注释说明了返回 nil 的两种情况：
--     "handler should always exist when we get here"（正常路径）
--     "nil return only when mouse position unavailable, should not be
--      possible normally"（鼠标位置拿不到，理论上不可能）
local function _CalcAOEChargingStartingRotation(self)
	--handler should always exist when we get here
	--nil return only when mouse position unavailable, should not be possible normally
	if self.handler then
		if not TheInput:ControllerAttached() then
			local pos = TheInput:GetWorldPosition()
			return pos and self.inst:GetAngleToPoint(pos) or nil
		else
--   ★ 手柄分支：把方向向量转成角度。
--     math.atan2(-dir.z, dir.x) * RADIANS —— 注意 **-dir.z**。
--     参见文件头 480 行的说明：Transform 的 Z 轴与数学 Z 轴相反。
--     这行与 4360 行的 -math.atan2(dir.z, dir.x) / DEGREES 是同一约定的两个写法。
			local dir = GetWorldControllerVector()
			return dir and math.atan2(-dir.z, dir.x) * RADIANS or self.inst.Transform:GetRotation()
		end
	end
end

--★★ 【TryAOECharging(force_rotation, iscontroller)】蓄力类道具（弹弓/ pneumatic）。
--   ★★ 三个调用点传入的 force_rotation 语义完全不同：
--     · 1109 行 TryAOECharging(nil, true) —— force_rotation=nil（客户端首次）
--     · 5021 行 TryAOECharging(nil, false) —— 鼠标右键版
--     · 1671 行 TryAOECharging(rotation, iscontroller) —— 服务端从 RPC 收到 rotation
--   ⇒ 1669 行 `if force_rotation then` 区分的就是「服务端已告知角度」还是「自己算」。
function PlayerController:TryAOECharging(force_rotation, iscontroller)
	local item = self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
	if item and item.components.aoecharging and item.components.aoecharging:IsEnabled() and not self:IsBusy() then
		if not item.components.aoecharging.allowriding then
			local rider = self.inst.replica.rider
			if rider and rider:IsRiding() then
				return false
			end
		end
		if self.inst.sg then
			if force_rotation then
				--server received remote rpc
--   --server received remote rpc
--   ★ 客户端已经在 1686-1688 行把 rotation 发了过来，服务端直接复用。
--     服务端**不重算**角度 —— 因为蓄力方向是玩家当时看的方向，重算会漂。
				self:OnRemoteBufferedAction()
			else
				--server or prediction client
--   --server or prediction client
--   ★ 预测客户端在**本地**就 SetRotation + GoToState 先行表演（1677-1678 行），
--     动画立即播，服务器随后跟上。这是「动画预测」而非「位置预测」。
				force_rotation = _CalcAOEChargingStartingRotation(self)
			end
			if force_rotation then
				self.inst.Transform:SetRotation(force_rotation)
				self.inst.sg:GoToState("slingshot_charge")
			end
--   --non-prediction client
--   --We still need to know our desired starting angle for the RPC, /
--   --but we can't set transform rotation on non-prediction clients
--   ★★ 无 locomotor 的客户端**不能**改 Transform（会与服务端冲突），
--     但仍要算出角度发 RPC。所以 1686 行的条件不含 sg 判断。
		else
			--non-prediction client
			--We still need to know our desired starting angle for the RPC,
			--but we can't set transform rotation on non-prediction clients
			force_rotation = _CalcAOEChargingStartingRotation(self)
		end
--   ★ startflag：1 = 鼠标右键，2 = 手柄 Y 键。
--     客户端用它反推「服务器该把哪个 remote_controls 置 0」。
		if not self.ismastersim and force_rotation then
			self.remote_controls[iscontroller and CONTROL_CONTROLLER_ALTACTION or CONTROL_SECONDARY] = 0
			SendRPCToServer(RPC.AOECharging, force_rotation, iscontroller and 2 or 1)
		end
		return true
	end
	return false
end

--【OnRemoteAOECharging(rotation, startflag)】蓄力的服务端对端。
--   1697 行的 if startflag：非零 = 开始蓄力；nil/0 = **持续更新角度**。
--   ★ 这是一个「start + 后续 update」共用一条 RPC 的省流设计：
--     1707 行 RemoteAOEChargingDir 每帧/每次转方向都发一次（只带 rotation）。
function PlayerController:OnRemoteAOECharging(rotation, startflag)
	if self.ismastersim and self:IsEnabled() and self.handler == nil then
		if startflag then
			local iscontroller = startflag == 2
			self.remote_controls[iscontroller and CONTROL_CONTROLLER_ALTACTION or CONTROL_SECONDARY] = 0
			self:TryAOECharging(rotation, iscontroller)
		elseif self.inst.sg:HasStateTag("aoecharging") then
			self.inst.Transform:SetRotation(rotation)
		end
	end
end

function PlayerController:RemoteAOEChargingDir(rotation)
	SendRPCToServer(RPC.AOECharging, rotation)
end

--【EchoReticuleAt(x,y,z)】在指定位置生成一个一次性准星涟漪实体。
--   1718 行的 `reticule:DoTaskInTime(1, reticule.Remove)`：
--     没有 Flash 方法的预制体，1 秒后自行移除。这是「特效实体的生命周期管理」。
function PlayerController:EchoReticuleAt(x, y, z)
    local reticule = SpawnPrefab(self.reticule.reticuleprefab)
    if reticule ~= nil then
        reticule.Transform:SetPosition(x, 0, z)
        if reticule.Flash ~= nil then
            reticule:Flash()
        else
            reticule:DoTaskInTime(1, reticule.Remove)
        end
    end
end

--【RefreshReticule(item)】重建准星。 Activate(326) / OnEquip(232) /
--   ToggleController(399) / 8 处外部调用。
--   ★ 与 OnEquip 的 reticule 逻辑重复（232-244 与 1725-1734 几乎一样），
--     但 RefreshReticule 是通用入口，接受可选 item 参数。
function PlayerController:RefreshReticule(item)
    item = item or self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
    if self.reticule ~= nil then
        self.reticule:DestroyReticule()
    end
    self.reticule = item ~= nil and item.components.reticule or self.inst.components.reticule
    if self.reticule ~= nil and self.reticule.reticule == nil and (self.reticule.mouseenabled or TheInput:ControllerAttached()) then
        self.reticule:CreateReticule()
		if self.reticule.reticule ~= nil and (not self:IsEnabled() or self.reticule:ShouldHide()) then
            self.reticule.reticule:Hide()
        end
    end
end

--★★ 【TargetIsHostile】敌对判定三级回退：
--     ① 实体自己有 HostileTest（生物侧优先）
--     ② 目标有 HostileToPlayerTest（如猪人村民对村民）
--     ③ 兜底查 target 的 hostile 标签
--   ★ 顺序不可交换：①解决「我怎么看它」，②解决「它怎么看我」，
--     ③是纯标签的最终兜底。第三方模组只需实现 ① 或 ② 之一即可。
local function TargetIsHostile(inst, target)
    if inst.HostileTest ~= nil then
        return inst:HostileTest(target)
	elseif target.HostileToPlayerTest ~= nil then
		return target:HostileToPlayerTest(inst)
    else
        return target:HasTag("hostile")
    end
end

--★★★ 【ValidateAttackTarget】★ 攻击目标合法性四道闸（本文件最重要的过滤器）。
--   签名 (combat, target, force_attack, x, z, has_weapon, reach)
--   ⚠ 注意 has_weapon 参数在函数体里**完全没被使用**（grep 确认）。
--     ⇒ 疑似缺陷（死参数）：1830/1835/1846/1858 四处认真计算并传入 has_weapon，
--       但 ValidateAttackTarget 从头到尾没读它。推测是早期版本用武器类型
--       区分「武器攻击 / 赤手攻击」的射程，现已改由 combat:GetAttackRangeWithWeapon
--       统一处理，但参数没删。
--     推理依据：1747-1786 行内 has_weapon 出现 0 次（仅在形参里）。
local function ValidateAttackTarget(combat, target, force_attack, x, z, has_weapon, reach)
--   闸①：combat:CanTarget（未死、未被别人锁定）+ 非 stealth 潜行。
	if not combat:CanTarget(target) or target:HasTag("stealth") then
        return false
    end

    --no combat if light/extinguish target
--   ★★ targetcombat 为 nil 的实体（光/扑灭器）**跳过敌对判定**，直接进距离检查。
--     注释："no combat if light/extinguish target"
--     设计取舍：火把/扑灭器能点任何东西，包括玩家自己（这是某些角色的技能）。
    local targetcombat = target.replica.combat
    if targetcombat ~= nil then
--   闸②：友军永不误伤（除非 force_attack 也过不了这一关？实际是直接 return false）。
--   ⚠ 注意：IsAlly 为真时**无条件** return false，force_attack 也不能强制攻击友军。
--     这与「强制攻击可以打队友的随从」（1769-1777）的处理不一致——
--     后者只针对 follower。所以「强制攻击友方随从」是允许的，
--     「强制攻击玩家队友」不允许。
        if combat:IsAlly(target) then
            return false
--   ★★ 闸③（非 force 且非最近目标时）：必须「对方也把我当敌人」或「对方是敌对生物」。
--   1759 行 shadowsubmissive（暗影驯服者）：
--     "shadowsubmissive needs to ignore GetTarget() test, since they have you
--      targeted even when not hostile"
--     → 已驯服的暗影生物虽然 GetTarget() 指向玩家，但不算敌对，不能再打。
--     这是为了避免「驯服后被误杀」。
		elseif not (force_attack or combat:IsRecentTarget(target)) then
			local inst = combat.inst
			if target.HostileToPlayerTest ~= nil and target:HasTag("shadowsubmissive") and not target:HostileToPlayerTest(inst) then
				--shadowsubmissive needs to ignore GetTarget() test,
				--since they have you targeted even when not hostile
				return false
--   ★ targetcombat:GetTarget() ~= inst：目标正在被别人打 → 允许玩家插队。
--     注释："must use force attack non-hostile creatures"
--     逻辑：非敌对生物（如猪）只要在跟你打架，就可以打；站着不动的猪不行。
			elseif targetcombat:GetTarget() ~= inst then
				--must use force attack non-hostile creatures
				if not TargetIsHostile(inst, target) then
					return false
				end
--   ★ 1769-1777 行：目标若是「某个玩家的随从」，且它主人正在跟你打，
--     那你也打它；否则不能打（防止误伤主人的宠物）。
--     ⚠ 1763 行的 `targetcombat:GetTarget() ~= inst` 与这里形成**双重条件**：
--       一个随从只有在「目标已指向我」或「主人已指向我」时才可被打。
--     推理依据：1774 行 leader.replica.combat:GetTarget() ~= inst 直接 return false。
				--must use force attack on players' followers
				local follower = target.replica.follower
				if follower ~= nil then
					local leader = follower:GetLeader()
					if leader ~= nil and
						leader:HasTag("player") and
						leader.replica.combat:GetTarget() ~= inst then
						return false
					end
				end
			end
		end
    end

    --Now we ensure the target is in range
    --light/extinguish targets may not have physics
--   ★★ 距离判定：`reach + target:GetPhysicsRadius(0)` ——
--     ★ 这是「点边缘即可命中」的实现：攻击范围是**边缘到边缘**，不是中心距。
--     所以大体型目标（牛 2.5 格）在同样 attackrange 下更容易被打中。
--     注释："light/extinguish targets may not have physics" ——
--       没有物理实体的目标半径为 0，退化为中心距判定。
    reach = reach + target:GetPhysicsRadius(0)
    return target:GetDistanceSqToPoint(x, 0, z) <= reach * reach
end

--★★ TheSim:RegisterFindTags —— ★ 向引擎注册一个**空间查询索引**。
--   { "_combat" }：只匹配带 _combat 标签的实体（entityreplica.lua 里自动加）。
--   { "INLIMBO" }：排除在「limbo 暂停」中的实体（存档中暂存的实体）。
--   ⇒ 这个注册是**模块加载时**执行的全局副作用，只做一次。
--   ★ 为什么用 _combat 标签而不是遍历所有实体：空间查询是每帧多次的热路径。
--   ⚠ 但注释说 "Only include combat targets for auto-targetting, not
--     light/extinguish"（1850 行）—— 而 ValidateAttackTarget 里却要处理
--     targetcombat == nil 的灯光目标。两者矛盾。
--     推理依据：1850 行注释 vs 1753 行的灯光分支；
--       REGISTERED_FIND_ATTACK_TARGET_TAGS 只查 _combat。
--     可能的调和：灯光分支只在 force_target 路径（1846 行）生效。
local REGISTERED_FIND_ATTACK_TARGET_TAGS = TheSim:RegisterFindTags({ "_combat" }, { "INLIMBO" })

--★★ 【GetAttackTarget(force_attack, force_target, isretarget, use_remote_predict)】
--   ★ 本函数被**双端**调用：
--     客户端：1895 行 DoAttackButton 算目标 → 决定发哪个 code
--     服务端：1945/1950 行 OnRemoteAttackButton 重算 → 校验客户端的 code
--   ⇒ 这就是「意图编号校验」在攻击路径上的落点。
function PlayerController:GetAttackTarget(force_attack, force_target, isretarget, use_remote_predict)
--   ★ 1791-1795 行：幽灵/沃古斯形态/无限练力场里**不能自动索敌**。
--     幽灵要主动 HAUNT，沃古斯攻击是技能，练力场里攻击无意义。
	if self.inst:HasAnyTag("playerghost", "weregoose") or
		(self.classified and self.classified.inmightygym:value() > 0)
	then
        return
    end

	local inventory = self.inst.replica.inventory
--   ★ 举重物 / 举漂浮物 → 不能攻击（双手被占用）。
--     与 1341-1343 行的 no_air_attack 判据一致。
	if inventory:IsHeavyLifting() or inventory:IsFloaterHeld() then
		return
	end

    local combat = self.inst.replica.combat
    if combat == nil then
        return
    end

--   --Don't want to spam the attack button before the server actually starts
--   the buffered action
--   ★ 这是「按键去重」的第二道闸（第一道是 BUTTON_REPEAT_COOLDOWN 的 remote_controls）。
--     1808 行 `(self.remote_controls[CONTROL_ATTACK] or 0) > 0` 在客户端才生效。
    --Don't want to spam the attack button before the server actually starts the buffered action
    if not self.ismastersim and (self.remote_controls[CONTROL_ATTACK] or 0) > 0 then
        return
    end

--   ★ isretarget && force_target 且可见 → 直接返回，不做任何重新搜索。
--     连击攻击的目标保持（避免「打着打着换了目标」）。
    if isretarget and force_target and not IsEntityDead(force_target) and CanEntitySeeTarget(self.inst, force_target) then
        return force_target
    end

    if self.inst.sg ~= nil then
		if self.inst.sg:HasStateTag(use_remote_predict and self.remote_authority and self.remote_predicting and "abouttoattack" or "attack") then
            return
        end
    elseif self.inst:HasTag("attack") then
        return
    end

--★★ 【1826 行的 attackrange 扩张】`local rad = self.directwalking and attackrange
--   or attackrange + 6` —— ★ 手柄/鼠标「直接行走」时缩到恰好 attackrange，
--   「点地面走过去」（自动行走）时**放大 6 格**。
--   为什么：自动行走时玩家不在瞄准，是「走过去打」，需要更宽的搜索半径；
--     而直接行走是「边跑边打」，必须严格限制在攻击距离内。
--   ⇒ 这是「交互范围判定」在攻击路径上的体现。
--   ⚠ 注释 "--\"not self.directwalking\" is autowalking" 位置写反了：
--     代码里 directwalking 为真时用小半径，注释却说「不是 directwalking 就是 autowalking」，
--     描述的是 else 分支（+6）。注释本身没错但紧贴在小半径那一行，容易误读。
    local x, y, z = self.inst.Transform:GetWorldPosition()
    local attackrange = combat:GetAttackRangeWithWeapon()
    local rad = self.directwalking and attackrange or attackrange + 6
    --"not self.directwalking" is autowalking

--   --Beaver teeth counts as having a weapon
--   ★ 海狸（Beaver）默认带武器。1830 行用 inst:HasTag 而非查装备。
    --Beaver teeth counts as having a weapon
    local has_weapon = self.inst:HasTag("beaver")
    if not has_weapon then
		local tool = inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
        if tool ~= nil then
            local inventoryitem = tool.replica.inventoryitem
            has_weapon = inventoryitem ~= nil and inventoryitem:IsWeapon()
--   propweapon（长矛等投掷武器）：自动视为 force_attack。
--   "don't require pressing force_attack when using prop weapons"
--     ⇒ 长矛可以插地/点燃而不会误伤友军，因为自动 force。
            if has_weapon and not force_attack and tool:HasTag("propweapon") then
                --don't require pressing force_attack when using prop weapons
                force_attack = true
            end
        end
    end

--   ★ reach = 自己半径 + 搜索半径 + 0.1。0.1 是浮点保护。
    local reach = self.inst:GetPhysicsRadius(0) + rad + .1

    if force_target ~= nil then
        return ValidateAttackTarget(combat, force_target, force_attack, x, z, has_weapon, reach) and force_target or nil
    end

--   --To deal with entity collision boxes we need to pad the radius.
--   ★ 因为目标有体积，「中心距 ≤ R」会把「体型 2.5 的牛在 3.2 处」判为不可达。
    --To deal with entity collision boxes we need to pad the radius.
    --Only include combat targets for auto-targetting, not light/extinguish
    --See entityreplica.lua (re: "_combat" tag)
    local nearby_ents = TheSim:FindEntities_Registered(x, y, z, rad + 5, REGISTERED_FIND_ATTACK_TARGET_TAGS)

    local nearest_dist = math.huge
--   ★★ 1855-1856 行**变量复用**做「状态机式」处理：
--     isretarget 原是入参（是否强制重定向），此处被复用为「是否找到最近目标」标志；
--     force_target 原是入参（强制目标），此处被复用为「最近目标」。
--   ⚠ 疑似缺陷（可读性/易错）：函数入参被覆写，退出时 1876 行返回的 force_target
--     已经是「最近目标」而非入参。后续维护极易出错。
--     推理依据：1856 行 force_target = nil 显式清空入参值；1876 行 return force_target。
    isretarget = false --reusing variable for flagging when we've found recent target
    force_target = nil --reusing variable for our nearest target
--   ★★★ 1857-1875 行是「最近目标优先，但最近目标有额外特权」的完整逻辑：
--     ① ValidateAttackTarget 通过 + 可见 → 算「边缘距」（减物理半径）
--     ② 若是 combat:IsRecentTarget（战斗系统认为的当前目标）
--        且边缘距 < attackrange+0.1 → **立即返回**（绝不放弃）
--        否则标记 isretarget = true（已见过最近目标但太远）
--     ③ 常规比较 dist < nearest_dist → 更新最近目标
--   ⇒ 效果：玩家点着一个敌人走来走去时，只要还在攻击范围内就永远打它，
--     哪怕旁边有个更近的路人。
    for i, v in ipairs(nearby_ents) do
        if ValidateAttackTarget(combat, v, force_attack, x, z, has_weapon, reach) and
            CanEntitySeeTarget(self.inst, v) then
            local dsq = self.inst:GetDistanceSqToInst(v)
            local dist = dsq <= 0 and 0 or math.max(0, math.sqrt(dsq) - v:GetPhysicsRadius(0))
            if not isretarget and combat:IsRecentTarget(v) then
                if dist < attackrange + .1 then
                    return v
                end
                isretarget = true
            end
            if dist < nearest_dist then
                nearest_dist = dist
                force_target = v
            end
--   elseif 分支：目标不合法但它是「最近目标」→ 只标记 isretarget，不更新最近目标。
--   ★ 与 1862 行的区别：这里目标已经不可打了，只是为了防止 1862 的立即返回逻辑
--     在目标离开后仍然生效。
        elseif not isretarget and combat:IsRecentTarget(v) then
            isretarget = true
        end
    end
    return force_target
end

--★★ 【DoAttackButton(retarget, isleftmouse)】★ 攻击按钮的统一入口。
--   三个调用点：638 行（OnControl 直接调）、2778 行（attack_buffer）、3149 行（连击）。
--   ★ isleftmouse：区分「用鼠标左键打」和「用攻击键打」。
--     原因：1953 行 `elseif not isleftmouse and self:IsOverrideAttack()` ——
--     鼠标左键**不**触发 overrideattack，只有专用攻击键才触发。
function PlayerController:DoAttackButton(retarget, isleftmouse)
    --if retarget == nil and self:IsAOETargeting() then
    --    return
    --end

	if not isleftmouse and self:IsOverrideAttack() then
		self.inst:PushEventImmediate("attackbutton")
		--Need to let server know NOW, wheter we have prediciton or not.
		if not self.ismastersim and self.remote_controls[CONTROL_ATTACK] == nil then
			self:RemoteAttackButton()
		end
		return
	end

--   ★ control 的选择：isleftmouse ? CONTROL_PRIMARY : CONTROL_ATTACK。
--     决定了 1899/1918 行往 remote_controls 里写哪个键。
	local control = isleftmouse and CONTROL_PRIMARY or CONTROL_ATTACK
--   force_attack = TheInput:IsControlPressed(CONTROL_FORCE_ATTACK) ——
--   ★ 注意读的是 TheInput 而非 IsControlPressed(511 行)：
--     这是纯客户端路径，服务端从不读这一行（服务端走 OnRemoteAttackButton）。
	local force_attack = TheInput:IsControlPressed(CONTROL_FORCE_ATTACK)
--   ★★ `retarget ~= self:GetCombatTarget()` 三个参数复用同一表达式：
--     force_target = retarget（可能重定向的目标）
--     isretarget  = 「目标是否和当前战斗目标不同」
--     ⚠ GetCombatTarget（2643 行）读的是 sg.statemem.attacktarget，
--       而 4603 行 DoAction 才写它 —— 存在一帧延迟。
	local target = self:GetAttackTarget(force_attack, retarget, retarget ~= self:GetCombatTarget())

--   没有目标 → 只发「按钮按下」RPC（1898 行的注释解释了这个范式）。
    if target == nil then
        --Still need to let the server know our attack button is down
        if not self.ismastersim and
			--self.locomotor == nil and
			self.remote_controls[control] == nil
		then
			self:RemoteAttackButton(nil, nil, isleftmouse)
        end
        return --no target
    end

    if self.ismastersim then
        self.locomotor:PushAction(BufferedAction(self.inst, target, ACTIONS.ATTACK), true)
--   -- NOTES(JBK): Does not call locomotor component functions needed for
--   pre_action_cb, manual call here.
--   ★★ 这个 --V2C 注释在全文件出现 12 次，是无 locomotor 客户端的适配手法：
--     locomotor:PreviewAction 内部会调 pre_action_cb（切换客户端状态标签），
--     无 locomotor 的客户端没有 locomotor 组件，只能手工调。
--   ⇒ 副作用：这两个分支的客户端**没有**客户端状态图，所以不能预测动作。
    elseif self.locomotor == nil then
		-- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
		if ACTIONS.ATTACK.pre_action_cb ~= nil then
			ACTIONS.ATTACK.pre_action_cb(BufferedAction(self.inst, target, ACTIONS.ATTACK))
		end
		self:RemoteAttackButton(target, force_attack, isleftmouse)
	else
--   ★ 1918 行的写法与 1899 行对称：先确保「按钮按下」已通知，再装 preview_cb。
		--Still need to let the server know our attack button is down
		if self.remote_controls[control] == nil then
			self:RemoteAttackButton(nil, nil, isleftmouse)
		end
--   ★ 只有 CanLocomote 才能 PreviewAction —— 移动预测能力是动作预测的前提。
--     为什么：PreviewAction 会让 locomotor 立刻开始移动到目标点，
--       若此时状态图说「你在攻击中」，移动就是错的。
		if self:CanLocomote() then
			local buffaction = BufferedAction(self.inst, target, ACTIONS.ATTACK)
			buffaction.preview_cb = function()
				local isreleased = not TheInput:IsControlPressed(control)
				self:RemoteAttackButton(target, force_attack, isleftmouse, isreleased)
			end
			self.locomotor:PreviewAction(buffaction, true)
		end
	end
end

--   --V2C: isreleased at the end because added a lot later
--   ★★ 一条极有价值的注释：isreleased 排在最后是因为它是**后加的参数**。
--   ⇒ 这暴露了 RPC 的兼容性约定：**只能在末尾追加可选参数**，
--     否则老客户端的实参会错位。这是本文件多处参数顺序怪异的根因。
--V2C: isreleased at the end because added a lot later
--【OnRemoteAttackButton(target, force_attack, noforce, isleftmouse, isreleased)】
--   ★★ 与 944 行的 ControllerActionButton 相比，本函数**不重算动作**，
--     因为 ATTACK 是固定动作（不需要 picker），只需要重算「打谁」。
--   ⇒ 重算逻辑在 1945/1950 行的 GetAttackTarget 调用里。
function PlayerController:OnRemoteAttackButton(target, force_attack, noforce, isleftmouse, isreleased)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        --Check if target is valid, otherwise make
        --it nil so that we still attack and miss.
		local control = isleftmouse and CONTROL_PRIMARY or CONTROL_ATTACK
		self.remote_controls[control] = 0
--   ★ 1945 行 use_remote_predict = true：服务端重算时启用 abouttoattack 标签检查。
--     （与 1817 行同一表达式，此处传 true。）
        if target ~= nil and not noforce then
			if self.inst.sg:HasStateTag(self.remote_authority and self.remote_predicting and "abouttoattack" or "attack") then
--   ★ 与 1396 行同款的 chainattack_cb，★ 同样丢参：
--     `self:OnRemoteAttackButton(target, force_attack)` 丢了 isleftmouse 与 isreleased。
--   ⚠ 后果比 1397 行更严重：isleftmouse 丢失后，1937 行会把 control 算成
--     CONTROL_ATTACK 而不是 CONTROL_PRIMARY → 1958 行清错键 →
--     服务器的 remote_controls[CONTROL_PRIMARY] 永远不会被清。
--   推理依据：1942 行参数表只到 force_attack；1937/1957 依赖 isleftmouse 与 isreleased。
--     缓解：ControlC 抬起走独立的 StopControl RPC（546 行）。
                self.inst.sg.statemem.chainattack_cb = function()
                    self:OnRemoteAttackButton(target, force_attack)
                end
            else
				target = self:GetAttackTarget(force_attack, target, target ~= self:GetCombatTarget(), true)
                self.attack_buffer = BufferedAction(self.inst, target, ACTIONS.ATTACK, nil, nil, nil, nil, true)
                self.attack_buffer._predictpos = true
            end
        else
            target = target ~= nil and self:GetAttackTarget(force_attack, target) or nil
            if target ~= nil then
                self.attack_buffer = BufferedAction(self.inst, target, ACTIONS.ATTACK)
			elseif not isleftmouse and self:IsOverrideAttack() then
				self.inst:PushEventImmediate("attackbutton")
            end
        end
		if isreleased then
			self.remote_controls[control] = nil
		end
    end
end

--V2C: isreleased at the end because added a lot later
--【RemoteAttackButton】发 RPC 的薄封装。
--   ★ 1965 行是本文件按键计时的**标准范式**：
--     `self.remote_controls[键] = not isreleased and (target and COOLDOWN or 0) or nil`
--     → 按下且有目标：设冷却时长；按下但无目标：设 0（可以连续发「打空气」）；
--       松开：设 nil。
--   ⇒ 1374/2302/2355 等处的变体都是这个式子的裁剪。
function PlayerController:RemoteAttackButton(target, force_attack, isleftmouse, isreleased)
	self.remote_controls[isleftmouse and CONTROL_PRIMARY or CONTROL_ATTACK] = not isreleased and (target and BUTTON_REPEAT_COOLDOWN or 0) or nil
    if self.locomotor ~= nil then
		SendRPCToServer(RPC.AttackButton, target, force_attack, nil, isleftmouse, isreleased)
--   ★ 1966-1972 三分支：noforce 只在「无 locomotor」且「有目标」时才置真。
--     因为有 locomotor 的客户端走 preview，服务器重定向时不需要 noforce。
    elseif target ~= nil then
		SendRPCToServer(RPC.AttackButton, target, force_attack, true, isleftmouse, isreleased)
    else
		SendRPCToServer(RPC.AttackButton, nil, nil, nil, isleftmouse, isreleased)
    end
end

--【SetIsOverrideAttack / IsOverrideAttack】★ 攻击键重映射的读写。
--   ★★ 1981-1986 行的双端不对称值得注意：
--     有 sg → 查状态标签 "overrideattack"（权威）
--     无 sg → 查 classified.isoverrideattack（同步量）
--   ⚠ 疑似缺陷（双端判定不一致）：客户端有 sg 时查标签，
--     而写 classified 的是 1975 行的服务端函数。
--     若某端有 sg 另一端没有，两端对同一个玩家会得出不同的答案。
--     推理依据：1975 行的写入只发生在 ismastersim；
--       1982 行 `if self.inst.sg then` 只检查本地是否有状态图。
function PlayerController:SetIsOverrideAttack(val)
	if self.ismastersim then
		self.classified.isoverrideattack:set(val)
	end
end

function PlayerController:IsOverrideAttack()
	if self.inst.sg then
		return self.inst.sg:HasStateTag("overrideattack")
	end
	return self.classified ~= nil and self.classified.isoverrideattack:value()
end

--★★ 四个 Validate* 谓词（1988-2003）：给 FindEntity 用的候选过滤器。
--   ⚠ ValidateHaunt:1989 的 HasActionComponent("hauntable") 是**组件检查**，
--     而后面 ValidateBugNet/ValidateUnsaddler 只查死亡。
--     三者风格不统一，说明是随需求逐步添加的。
local function ValidateHaunt(target)
    return target:HasActionComponent("hauntable")
end

local function ValidateBugNet(target)
    return not IsEntityDead(target)
end

local function ValidateUnsaddler(target)
    return not IsEntityDead(target)
end

--   --V2C: revivablecorpse is on clients as well
--   ★ 注释解释了为什么这个 Validate 可以双端跑：revivablecorpse 组件客户端也有。
--     大多数组件只在服务端有（客户端会 nil 索引），这个是少数例外。
local function ValidateCorpseReviver(target, inst)
    --V2C: revivablecorpse is on clients as well
    return target.components.revivablecorpse:CanBeRevivedBy(inst)
end

--★★★ 【GetPickupAction(self, target, tool)】★★ **动作优先级链，全文件最长的 if-else 链**。
--   2080 行之前的 65 行里排了 18 个分支。★ 顺序即优先级，不可随意调整。
--   每一条都是「标签 → 动作」的映射，模组加标签即可扩展。
--   两个调用点：2267 行（空间搜索后逐个试）与 2274 行（force_target 直试）。
local function GetPickupAction(self, target, tool)
--   ① smolder（余烬）→ 扑灭。★ 放在最前是因为「正在烧」必须最先处理，
--     否则后面任何分支都可能先匹配上「这是可采集物」。
    if target:HasTag("smolder") then
        return ACTIONS.SMOTHER
    elseif tool ~= nil then
--   ★ LunarBuildup（月光堆积）需要 MINE 工具才能清除。
--     这是 2024 新增的内容，插在 TOOLACTIONS 循环之前。
        if target:HasTag("LunarBuildup") and tool:HasTag("MINE_tool") then
            return ACTIONS.REMOVELUNARBUILDUP
        end
--★ 【TOOLACTIONS 循环】14-17 行是与「工具 vs 可作业物」匹配的通用机制。
--   标签约定：目标有 `CHOP_workable` + 工具刀有 `CHOP_tool` → ACTIONS.CHOP。
--   参见 constants.lua:2183 TOOLACTIONS = { CHOP, DIG, HAMMER, MINE, NET, PLAY,
--   UNSADDLE, SCYTHE } —— 8 个工具动作。
--   ⚠ 循环体里的 break（2017 行）：★ 只匹配第一个标签就 break，
--     意味着「同时有 CHOP_workable 和 DIG_workable 的目标」只会匹配 TOOLACTIONS
--     遍历顺序里的第一个。pairs 遍历顺序不保证 → 行为不确定。
--     推理依据：constants.lua 的 TOOLACTIONS 是**数组**，但 pairs 对数组的遍历
--       顺序在 Lua 中不保证与索引顺序一致（虽然实践中通常是 1..n）。
--     现实中双标签目标极少，故未暴露。
        for k, v in pairs(TOOLACTIONS) do
            if target:HasTag(k.."_workable") then
                if tool:HasTag(k.."_tool") then
                    return ACTIONS[k]
                end
                break
            end
        end
    end

--   ★★ 注意每个分支都带 `not target:HasTag("fire")` 之类的否定条件：
--     「着火的东西不能这么处理」。这是 DST 火灾机制的统一约定，
--     也是为什么 2006 行的扑灭必须放最前面。
    if target:HasTag("quagmireharvestabletree") and not target:HasTag("fire") then
        return ACTIONS.HARVEST_TREE
    elseif target:HasTag("trapsprung") then
        return ACTIONS.CHECKTRAP
    elseif target:HasTag("minesprung") and not target:HasTag("mine_not_reusable") then
        return ACTIONS.RESETMINE
--   ★ 2029 行：inactive（未激活的机器）需靠近 2.5 格才能激活 ——
--     但只对 wall 生效（`(not target:HasTag("wall") or IsNear(target, 2.5))`）。
--   ⚠ 这个 2.5 是**独立的距离常量**，与 actions.lua 的 rangecheckfn 无关。
    elseif target:HasTag("inactive") and not target:HasTag("activatable_forcenopickup") and target.replica.inventoryitem == nil then
		return (not target:HasTag("wall") or self.inst:IsNear(target, 2.5))
			and ACTIONS.ACTIVATE
			or nil
--   ★★ 2032-2039 行的 PICKUP 分支有五重守卫：
--     ① 是 inventoryitem
--     ② CanBePickedUp(self.inst)（能否被**这个人**捡：所有者/堆叠上限）
--     ③ 不是 heavy（太重）/ 不是可燃物（除非 lighter）/ 不是 catchable（要抓的）
--     ④ 不是 spider（蜘蛛蛋要孵化）
--     ⑤ ★ 有背包格子 或 目标可装备 → 否则捡不了（玩家是幽灵时）
--   ⚠ 2034 行的 `(target:HasTag("fire") and not target:HasTag("lighter"))` ——
--     着火的东西**可以**被 lighter 标签的物品处理（如火把本身带 fire+lighter）。
    elseif target.replica.inventoryitem ~= nil and
        target.replica.inventoryitem:CanBePickedUp(self.inst) and
		not (target:HasTag("heavy") or (target:HasTag("fire") and not target:HasTag("lighter")) or target:HasTag("catchable")) and
        not target:HasTag("spider") then
--   ★★ HasItemSlots() 的两个用途之一：幽灵/无背包实体捡不了东西。
--     这是 31-39 行猴补模式的实际消费点。
        if self:HasItemSlots() or target.replica.equippable ~= nil then
            return ACTIONS.PICKUP
        end
        return nil
--   ★ pickable（可采摘，如草）→ PICK。
    elseif target:HasTag("pickable") and not target:HasTag("fire") then
        return ACTIONS.PICK
    elseif target:HasTag("harvestable") then
        return ACTIONS.HARVEST
--   ★ 2045 行的 withered（枯萎）特例：已枯萎的也算「准备好采摘」。
    elseif target:HasTag("readyforharvest") or
        (target:HasTag("notreadyforharvest") and target:HasTag("withered")) then
        return ACTIONS.HARVEST
    elseif target:HasTag("tapped_harvestable") and not target:HasTag("fire") then
        return ACTIONS.HARVEST
--   ★ 2049 行 `not self.inst:HasTag("mime")`：哑谜演员不能照料作物
--     （mime 的机制是「模仿 NPC」，照料作物会破坏伪装）。
    elseif target:HasTag("tendable_farmplant") and not self.inst:HasTag("mime") and not target:HasTag("fire") then
        return ACTIONS.INTERACT_WITH
    elseif target:HasTag("dried") and not target:HasTag("burnt") then
        return ACTIONS.HARVEST
    elseif target:HasTag("donecooking") and not target:HasTag("burnt") then
        return ACTIONS.HARVEST
--   ★ inventoryitemholder_take → TAKEITEM（从盒子里拿东西）。
--   ⚠ 这个标签是「容器专门给 TAKEITEM 动作用」的，不是通用容器标记。
    elseif target:HasTag("inventoryitemholder_take") and not target:HasTag("fire") then
        return ACTIONS.TAKEITEM
    elseif tool ~= nil and tool:HasTag("unsaddler") and target:HasTag("saddled") and not IsEntityDead(target) then
        return ACTIONS.UNSADDLE
    elseif tool ~= nil and tool:HasTag("brush") and target:HasTag("brushable") and not IsEntityDead(target) then
        return ACTIONS.BRUSH
--   ★ 2061 行的守卫是 `self.inst.components.revivablecorpse ~= nil`：
--     「只有本身可被复活的玩家才能复活别人」——对应 2213 行的注释
--     "only need to do this if i am also revivable"。
    elseif self.inst.components.revivablecorpse ~= nil and target:HasTag("corpse") and ValidateCorpseReviver(target, self.inst) then
        return ACTIONS.REVIVE_CORPSE
    end
    --no action found
end

--【IsDoingOrWorking】★ 双端判据的第三种形态（除 IsBusy 外的第二个 busy）。
--   sg 标签：doing / working；实体标签：doing / working。
--   2071 行的 autopredict 分支：非预测客户端且带 autopredict 标签时只用 sg 标签。
--   ⚠ 疑似缺陷（条件覆盖不全）：2071 行的 elseif 只在 `not ismastersim and
--     HasTag("autopredict")` 时生效，**主sim 分支没有对应逻辑**——
--     主sim 走到 2075 行的兜底（sg 标签 + inst 标签都查）。
--     这意味着主sim 会用更宽的判据（多查 inst:HasTag），与 autopredict 客户端
--     的窄判据不一致。
--     推理依据：2071 行含 not self.ismastersim，2075 行无此限制。
function PlayerController:IsDoingOrWorking()
    if self.inst.sg == nil then
        return self.inst:HasTag("doing")
            or self.inst:HasTag("working")
    elseif not self.ismastersim and self.inst:HasTag("autopredict") then
        return self.inst.sg:HasStateTag("doing")
            or self.inst.sg:HasStateTag("working")
    end
    return self.inst.sg:HasStateTag("doing")
        or self.inst.sg:HasStateTag("working")
        or self.inst:HasTag("doing")
        or self.inst:HasTag("working")
end

--★ TARGET_EXCLUDE_TAGS：目标查询的通用排除表。
--   FX（特效）/ NOCLICK（不可点）/ DECOR（装饰）/ INLIMBO（存档暂存）/ stealth。
--   ⚠ 2081 行有 5 个标签但 3375 行的注释只说 "FX" 和 "DECOR"：
--     "\"FX\" and \"DECOR\" tag should never change, should be safe to skip
--      that check" —— 说明作者认为 FX/DECOR 是永久不变的，故在有效性检查里省掉。
--     但 stealth 没被这样对待（1748 行单独检查），说明 stealth 会变。
local TARGET_EXCLUDE_TAGS = { "FX", "NOCLICK", "DECOR", "INLIMBO", "stealth" }
--   ★ 攻击索敌用**独立注册**（1788 行），因为排除表不同（这里排除了 stealth）。
local REGISTERED_CONTROLLER_ATTACK_TARGET_TAGS = TheSim:RegisterFindTags({ "_combat" }, TARGET_EXCLUDE_TAGS)

--   PICKUP / HAUNT 的排除表由 TARGET_EXCLUDE_TAGS 扩展而来（2086-2089 行）。
--   ★ 注意 2087 行的 table.insert 是在**循环里直接改被遍历的表**的副本 ——
--     PICKUP_TARGET_EXCLUDE_TAGS 是本地表，安全；但若有人复用 TARGET_EXCLUDE_TAGS
--     本身就会死循环。当前是安全的（2084 行是新表）。
local PICKUP_TARGET_EXCLUDE_TAGS = { "catchable", "mineactive", "intense", "paired" }
local HAUNT_TARGET_EXCLUDE_TAGS = { "haunted", "catchable" }
for i, v in ipairs(TARGET_EXCLUDE_TAGS) do
    table.insert(PICKUP_TARGET_EXCLUDE_TAGS, v)
    table.insert(HAUNT_TARGET_EXCLUDE_TAGS, v)
end

--   六个 CATCHABLE_TAGS 常量表：catchable / pinned / corpse /
--   gestaltcapturable / moonstormstaticcapturable。
--   ★ 都是「FindEntity 的 musttags 参数」——FindEntity（simutil.lua:31）
--     接受 musttags/canttags/mustoneoftags 三个标签过滤参数。
local CATCHABLE_TAGS = { "catchable" }
local PINNED_TAGS = { "pinned" }
local CORPSE_TAGS = { "corpse" }
local GESTALTCAPTURABLE_TAGS = { "gestaltcapturable" }
local MOONSTORMSTATICCAPTURABLE_TAGS = { "moonstormstaticcapturable" }
--★★★ 【GetActionButtonAction(force_target)】★★ **空间键（CONTROL_ACTION）的动作选择**。
--   这是全文件最长的单函数（185 行），是一条**严格有序**的优先级链。
--   链上的每一级都是「一个动作族」，顺序即优先级：
--     ① 前置守卫（2102-2115）
--     ② 手被占（2117-2127）
--     ③ 手势忙（2129）
--     ④ 幽灵态：Haunt（2132-2145）
--     ⑤ 工具特定：BugNet / GestaltCage / MoonstormStatic（2147-2186）
--     ⑥ CATCH（2188-2199）
--     ⑦ UNPIN（2201-2210）
--     ⑧ REVIVE_CORPSE（2212-2224）
--     ⑨ 兜底：拾取/工具/扑灭（2226-2278）
--   ⇒ ★ 为什么幽灵 Haunt 排在工具之前：幽灵拿不了东西，Haunt 是它唯一能做的事。
--   ⇒ ★ 为什么 UNPIN 排在 REVIVE 之前：解除陷阱比复活尸体更紧急（自己可能被夹）。
function PlayerController:GetActionButtonAction(force_target)
--   ★ 2097 行就取 IsEnabled 的两个返回值 —— 本函数在 HUD 打开时也可能被调用。
    local isenabled, ishudblocking = self:IsEnabled()

--   ★★ 2102-2107 行的四重守卫，任一成立就**什么都不做**（返回 nil）：
--     ① 客户端且 CONTROl_ACTION 还在冷却 → 防连点刷动作
--     ② 既没 enabled 也没 hudblocking → 玩家被禁用（睡觉/死亡/倒地）
--     ③ IsBusy() → 正在做别的动作
--     ④ force_target 已失效（不可见 / INLIMBO / NOCLICK）
--   ⚠ 2106 行注释："DECOR should never change, should be safe to skip that check"
--     → 与 2081 行的 TARGET_EXCLUDE_TAGS 呼应：DECOR 标签永久不变。
    --Don't want to spam the action button before the server actually starts the buffered action
--============================================================
-- 【第四段】2100-2650 行：空间键动作链 / 查看 / 复活 / 轮盘 / 长按重复
--============================================================
    --Also check if playercontroller is enabled
    --Also check if force_target is still valid
    if (not self.ismastersim and (self.remote_controls[CONTROL_ACTION] or 0) > 0) or
        (not isenabled and not ishudblocking) or
        self:IsBusy() or
        (force_target ~= nil and (not force_target.entity:IsVisible() or force_target:HasTag("INLIMBO") or force_target:HasTag("NOCLICK"))) then
        --"DECOR" should never change, should be safe to skip that check
        return

--   ★★ actionbuttonoverride —— **模组插入点**。
--   2110 行返回 (buffaction, usedefault)：
--     · usedefault=false → 用返回的 buffaction
--     · usedefault=true 且 buffaction==nil → **落穿**到下面的默认链（2114 行注释）
--     · usedefault=true 且 buffaction~=nil → 用它
--   ⚠ 疑似缺陷（隐式约定）：返回两个值但调用方要解构判断，
--     任何模组返回单值（Lua 里 usedefault=nil 视为 false）都会走「用它」分支。
--     推理依据：2111 行 `if not usedefault or buffaction ~= nil` ——
--       usedefault 为 nil 时 not nil 为真，直接返回 buffaction。
--   ⇒ 好消息：单值返回恰好是「替换默认动作」的语义，不会出错。
    elseif self.actionbuttonoverride ~= nil then
        local buffaction, usedefault = self.actionbuttonoverride(self.inst, force_target)
        if not usedefault or buffaction ~= nil then
            return buffaction
        end
		--(usedefault and buffaction == nil) ==> fallthrough
	end

--   ★★ 双手被占的两个判定，语义不同：
--     IsFloaterHeld：举着漂浮物（气球等）→ 完全不能操作
--     IsHeavyLifting：举重物 → **骑乘时仍可操作**（可以一边骑一边开箱）
--   ⚠ 2123 行的 `if not (rider and rider:IsRiding()) then return end`：
--     骑乘时跳过整个返回 ⇒ 允许在骑乘状态开箱。
	local inventory = self.inst.replica.inventory
	if inventory:IsFloaterHeld() then
		--hands are full!
		return
	elseif inventory:IsHeavyLifting() then
		local rider = self.inst.replica.rider
		if not (rider and rider:IsRiding()) then
			--hands are full!
			return
		end
	end

--   ★★ 「正在做/正在工作」时**整个动作链都不跑**。
--   ⇒ 这是 2067 行 IsDoingOrWorking 的第一个消费点，也是「按空格没反应」的主因之一。
	if not self:IsDoingOrWorking() then
--   ★ force_target_distsq：先算好「鼠标指定目标」的距离平方，后面每一级复用。
--     避免在 18 个分支里重复调 GetDistanceSqToInst。
        local force_target_distsq = force_target ~= nil and self.inst:GetDistanceSqToInst(force_target) or nil

--   ④ 幽灵态 → Haunt（附身）。
--   2135 行半径：directwalking ? 3 : 6。与 1826 行的攻击半径同款双档设计。
        if self.inst:HasTag("playerghost") then
            --haunt
            if force_target == nil then
                local target = FindEntity(self.inst, self.directwalking and 3 or 6, ValidateHaunt, nil, HAUNT_TARGET_EXCLUDE_TAGS)
--   ★★ 2136 行的 CanEntitySeeTarget(self.inst, target)：
--     传给 FindEntity 的是 nil validator，若没找到则 target 为 nil，
--     而 CanEntitySeeTarget 对 nil 返回 false（simutil.lua:548）——
--     ★ 所以这一行同时充当了「找到没有」的判据。
--   ⇒ 这是本文件反复使用的惯用法：
--     `if CanEntitySeeTarget(self.inst, FindEntity(...)) then return action end`
--     2135/2152/2167/2179/2191/2203/2215 行七处全是这个形状。
                if CanEntitySeeTarget(self.inst, target) then
                    return BufferedAction(self.inst, target, ACTIONS.HAUNT)
                end
--   force_target 路径的距离判据：directwalking ? 9 : 36（= 3² / 6²）。
--   ⚠ 数字硬编码：与 2135 行的 3/6 是「平方 vs 开方」的一对，
--     但**没有共享常量**。改半径时极易只改一处。
            elseif force_target_distsq <= (self.directwalking and 9 or 36) and
                not (force_target:HasTag("haunted") or force_target:HasTag("catchable")) and
                ValidateHaunt(force_target) then
                return BufferedAction(self.inst, force_target, ACTIONS.HAUNT)
            end
            return
        end

--   ★ 拿到手持工具。后续所有工具相关分支都用它。
		local tool = inventory:GetEquippedItem(EQUIPSLOTS.HANDS)

--   ★★ 2149 行的注释 "bug catching (has to go before combat)"：
--     捕虫必须在战斗之前。因为「打着打着把虫子抓了」会丢失战斗目标。
--   ⇒ 这是空间键链与攻击路径（1790 GetAttackTarget）**完全独立**的证据：
--     两者不共享优先级，任何「先攻击再捕虫」的排序都需要新增跨链逻辑。
        --bug catching (has to go before combat)
        if tool ~= nil and tool:HasTag(ACTIONS.NET.id.."_tool") then
            if force_target == nil then
--   ★ musttags = { "_health", "NET_workable" }：
--     同时要求有生命值组件（有血条，即生物）与可被网捕（可捕捉的活物）。
--     排除死人（尸体没有 _health？实际尸体也有，但 NET_workable 不会加在尸体上）。
                local target = FindEntity(self.inst, 5, ValidateBugNet, { "_health", ACTIONS.NET.id.."_workable" }, TARGET_EXCLUDE_TAGS)
                if CanEntitySeeTarget(self.inst, target) then
                    return BufferedAction(self.inst, target, ACTIONS.NET, tool)
                end
--   force_target 路径：距离 ≤ 25（= 5²，与 2152 行的半径 5 对应）。
            elseif force_target_distsq <= 25 and
                force_target.replica.health ~= nil and
                ValidateBugNet(force_target) and
                force_target:HasTag(ACTIONS.NET.id.."_workable") then
                return BufferedAction(self.inst, force_target, ACTIONS.NET, tool)
            end
        end

		--catch gestalts
--   ★ 2164-2186：Gestalt（地牢 Boss 的吸入）与 MoonstormStatic（月亮风暴静电）。
--     两段结构完全同构（半径 8 / 距离 ≤ 64 / 标签判据）。
--   ⚠ 疑似缺陷（数值不一致）：8²=64 ✓，这一对是自洽的。
--     但注意 2188 行的 CATCH 用半径 10 / 距离 ≤ 100，也自洽。
--     ⇒ 真正的不一致在于：这些半径全部硬编码，与 TUNING 表无关联。
		if tool and tool:HasTag("gestalt_cage") then
			if force_target == nil then
				local target = FindEntity(self.inst, 8, nil, GESTALTCAPTURABLE_TAGS, TARGET_EXCLUDE_TAGS)
				if CanEntitySeeTarget(self.inst, target) then
					return BufferedAction(self.inst, target, ACTIONS.POUNCECAPTURE, tool)
				end
			elseif force_target_distsq <= 64 and force_target:HasTag("gestaltcapturable") then
				return BufferedAction(self.inst, force_target, ACTIONS.POUNCECAPTURE, tool)
			end
		end

        --catch moonstorm statics
        if tool and tool:HasTag("moonstormstatic_catcher") then
            if force_target == nil then
                local target = FindEntity(self.inst, 8, nil, MOONSTORMSTATICCAPTURABLE_TAGS, TARGET_EXCLUDE_TAGS)
                if CanEntitySeeTarget(self.inst, target) then
                    return BufferedAction(self.inst, target, ACTIONS.DIVEGRAB, tool)
                end
            elseif force_target_distsq <= 64 and force_target:HasTag("moonstormstaticcapturable") then
                return BufferedAction(self.inst, force_target, ACTIONS.DIVEGRAB, tool)
            end
        end

--   ⑥ CATCH：抓（蜘蛛/兔子）。★ 2189 行 `inst:HasTag("cancatch")`：
--     是**玩家**身上的标签（韦德沃克斯/抓娃娃机角色），不是工具。
--   ⇒ 这解释了为什么它排在工具分支之后 —— 它不使用任何道具。
        --catching
        if self.inst:HasTag("cancatch") then
            if force_target == nil then
                local target = FindEntity(self.inst, 10, nil, CATCHABLE_TAGS, TARGET_EXCLUDE_TAGS)
                if CanEntitySeeTarget(self.inst, target) then
                    return BufferedAction(self.inst, target, ACTIONS.CATCH)
                end
            elseif force_target_distsq <= 100 and
                force_target:HasTag("catchable") then
                return BufferedAction(self.inst, force_target, ACTIONS.CATCH)
            end
        end

--   ⑦ UNPIN：从陷阱里把队友/自己拔出来（救蜘蛛人！）。
--   ★ 2202 行 `if force_target == nil` —— 这一级**只支持无指定目标**，
--     有鼠标目标时不会触发 UNPIN。这是刻意的：解陷阱要「对着陷阱按」。
        --unstick
        if force_target == nil then
            local target = FindEntity(self.inst, self.directwalking and 3 or 6, nil, PINNED_TAGS, TARGET_EXCLUDE_TAGS)
            if CanEntitySeeTarget(self.inst, target) then
                return BufferedAction(self.inst, target, ACTIONS.UNPIN)
            end
        elseif force_target_distsq <= (self.directwalking and 9 or 36) and
            force_target:HasTag("pinned") then
            return BufferedAction(self.inst, force_target, ACTIONS.UNPIN)
        end

--   ⑧ REVIVE_CORPSE：★ 守卫 `self.inst.components.revivablecorpse ~= nil`，
--     注释 "only need to do this if i am also revivable"。
--     ⇒ 与 2061 行 GetPickupAction 里的同款守卫呼应：只有能复活的玩家才显示该动作。
        --revive (only need to do this if i am also revivable)
        if self.inst.components.revivablecorpse ~= nil then
            if force_target == nil then
                local target = FindEntity(self.inst, 3, ValidateCorpseReviver, CORPSE_TAGS, TARGET_EXCLUDE_TAGS)
                if CanEntitySeeTarget(self.inst, target) then
                    return BufferedAction(self.inst, target, ACTIONS.REVIVE_CORPSE)
                end
--   ⚠ 2219-2220 行的 Lua 多行条件书写方式：
--       `elseif force_target_distsq <= 9`
--           `and force_target:HasTag("corpse")`
--           `and ValidateCorpseReviver(...)` then
--     这是合法的（表达式可跨行），但**极易被后人误读为三个独立 elseif**。
--     文件中 2219-2221 与 2044-2045、2047-2048 都有同样的风格。
            elseif force_target_distsq <= 9
                and force_target:HasTag("corpse")
                and ValidateCorpseReviver(force_target, self.inst) then
                return BufferedAction(self.inst, force_target, ACTIONS.REVIVE_CORPSE)
            end
        end

--   ★★ ⑨ 兜底分支：自己找目标（2227 行 force_target == nil）。
--   这是唯一一个「在空间里搜一遍所有候选」的分支（2262 行 TheSim:FindEntities），
--     其他分支都用 FindEntity（单目标）。
--   ⇒ 性能差异：2262 行返回**列表**，要遍历并对每个调 GetPickupAction（2267 行），
--     而 FindEntity 返回第一个匹配的。后者是 simutil 的提前退出优化。
        --misc: pickup, tool work, smother
        if force_target == nil then
--   ★★ pickup_tags 表：★ 这是「交互范围判定」的另一条路径 —— 
--     它不是靠距离，而是靠**标签白名单**先把空间查询缩小到相关实体。
--   ★ 2246 行的 client_forward_tag：允许「转发」实体参与（见 2264 行）。
--     这是模组机制（如韦布斯特的「延伸的手」把动作转发给远处实体）。
            local pickup_tags =
            {
                "_inventoryitem",
                "pickable",
                "donecooking",
                "readyforharvest",
                "notreadyforharvest",
                "harvestable",
                "trapsprung",
                "minesprung",
                "dried",
                "inactive",
                "smolder",
                "saddled",
                "brushable",
                "tapped_harvestable",
                "tendable_farmplant",
                "inventoryitemholder_take",
				"client_forward_action_target",
            }
--   ★★ 动态扩充 pickup_tags：
--     2249 行：手持矿镐 → 追加 LunarBuildup（月光堆积）
--     2252-2256 行：按 TOOLACTIONS 把「我这把工具能作业的标签」全加进去
--   ⇒ ★★ 推论：**工具的作业标签是运行时注入查询表的**，
--     所以 2262 行的空间查询范围已经含「我工具能干的事」。
--     这就是为什么「走过去自动提示砍树」不需要额外的距离逻辑。
            if tool ~= nil then
                if tool:HasTag("MINE_tool") then
                    table.insert(pickup_tags, "LunarBuildup")
                end
                for k, v in pairs(TOOLACTIONS) do
                    if tool:HasTag(k.."_tool") then
                        table.insert(pickup_tags, k.."_workable")
                    end
                end
            end
            if self.inst.components.revivablecorpse ~= nil then
                table.insert(pickup_tags, "corpse")
            end
--   ★ 2262 行的搜索半径：directwalking ? 3 : 6，与前面七处一致。
--   ⚠ 但 2262 行传的是 PICKUP_TARGET_EXCLUDE_TAGS（排除 catchable/mineactive/intense/
--     paired + FX/NOCLICK/DECOR/INLIMBO/stealth），与 2135 行的 HAUNT_ 排除表不同。
            local x, y, z = self.inst.Transform:GetWorldPosition()
            local ents = TheSim:FindEntities(x, y, z, self.directwalking and 3 or 6, nil, PICKUP_TARGET_EXCLUDE_TAGS, pickup_tags)
            for i, v in ipairs(ents) do
--   ★★ v = v.client_forward_target or v —— 模组转发机制。
--     若实体带 client_forward_target，则用**被转发的那个实体**做后续判断。
--     3464 行（手柄目标选择）有**完全相同**的一行。
--     ⇒ 这两处必须同步改动，否则鼠标和手柄的转发行为会分叉。
				v = v.client_forward_target or v

--   ★ 三重可见性守卫：不是自己 + 实体可见 + 视线可达。
--   ⚠ 2266 行的 `v.entity:IsVisible()` 检查是**引擎层**的可见性
--     （如在未探索洞穴里、隐藏的实体），CanEntitySeeTarget 是**光照**可见性。
--     两者语义不同，缺一不可。
                if v ~= self.inst and v.entity:IsVisible() and CanEntitySeeTarget(self.inst, v) then
                    local action = GetPickupAction(self, v, tool)
                    if action ~= nil then
--   ★★ `action ~= ACTIONS.SMOTHER and tool or nil`：扑灭时**不传工具**。
--   ⚠ 疑似缺陷（Lua and/or 惯用法陷阱）：若 tool 为 false/nil 时会传 nil —— 安全；
--     但若 action==nil（GetPickupAction 返回 nil）此处不会执行（2268 行已判）。
--   ⚠ 真正的问题：`a and b or nil` 当 b 为 **false** 时会退化成 nil。
--     tool 恒为实体或 nil，不会是 false，故当前安全。
--     但这个写法在 2276 行重复了一次，两处都依赖 tool 不为 false。
                        return BufferedAction(self.inst, v, action, action ~= ACTIONS.SMOTHER and tool or nil)
                    end
                end
            end
--   force_target 路径：距离 ≤ 9 或 36（3 或 6 的平方），与 2227 行对称。
        elseif force_target_distsq <= (self.directwalking and 9 or 36) then
            local action = GetPickupAction(self, force_target, tool)
            if action ~= nil then
                return BufferedAction(self.inst, force_target, action, action ~= ACTIONS.SMOTHER and tool or nil)
            end
        end
    end
end

--★★ 【DoActionButton】空间键 / 手柄 X 的客户端入口（632 行调它）。
--   ★ 2283-2285 行注释掉的 AOE 守卫说明「AOE 期间禁空间键」曾被考虑后放弃。
function PlayerController:DoActionButton()
    --if self:IsAOETargeting() then
    --    return
    --end
--   ★ 分支1：没有建造放置器 → 走常规动作链。
--     分支2（2308）：有 placer → 执行建造（鼠标模式与手柄模式共用）。
    if self.placer == nil then
        local buffaction = self:GetActionButtonAction()
        if buffaction ~= nil then
--   服务端：直接 PushAction（2290 行），不走 2319 行的「按钮按下」通知。
--     ⇒ 因为服务端按的就是它自己的输入，不需要 RPC 往返。
            if self.ismastersim then
                self.locomotor:PushAction(buffaction, true)
                return
            elseif self.locomotor == nil then
                -- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
                if buffaction.action.pre_action_cb ~= nil then
                    buffaction.action.pre_action_cb(buffaction)
                end
                self:RemoteActionButton(buffaction)
                return
            elseif self:CanLocomote() then
--   ★★ 2300 行 `buffaction.action ~= ACTIONS.WALKTO`：
--     WALKTO 不装 preview_cb ⇒ 「走过去」这个动作**不会**发 RPC。
--   ⇒ 为什么？因为走过去已经由预测移动协议（PredictWalking）表达了，
--     再发一次 ActionButton 是重复的。
--   ⚠ 这是一个重要的性能优化点：玩家最常用的「点地面走」不会产生额外 RPC。
                if buffaction.action ~= ACTIONS.WALKTO then
                    buffaction.preview_cb = function()
                        self:RemoteActionButton(buffaction, not TheInput:IsControlPressed(CONTROL_ACTION) or nil)
                    end
                end
                self.locomotor:PreviewAction(buffaction, true)
            end
        end
    elseif self.placer.components.placer.can_build and
        self.inst.replica.builder ~= nil and
        not self.inst.replica.builder:IsBusy() then
        --do the placement
        self.inst.replica.builder:MakeRecipeAtPoint(self.placer_recipe,
            self.placer.components.placer.override_build_point_fn ~= nil and self.placer.components.placer.override_build_point_fn(self.placer) or self.placer:GetPosition(),
            self.placer:GetRotation(), self.placer_recipe_skin)
    elseif self.placer.components.placer.onfailedplacement ~= nil then
        self.placer.components.placer.onfailedplacement(self.inst, self.placer)
    end

--   ★ 2319-2322 行是 870 行那个「无参 RPC」范式的第 8 次出现。
--   ⚠ 2319 行的位置在 if/elseif 链**之外** —— 所以即使动作成功执行了，
--     只要 remote_controls[CONTROL_ACTION] 已被 preview_cb 设为非 nil 就不会再发。
--     若动作走了服务端分支（2289）返回，或走了 2305 的 PreviewAction，
--     remote_controls 已被 preview_cb 填上 → 不重复发。
--   ⇒ 这个「靠 remote_controls 的状态决定要不要发」是全文件的一致技巧。
    --Still need to let the server know our action button is down
    if not self.ismastersim and self.remote_controls[CONTROL_ACTION] == nil then
        self:RemoteActionButton()
    end
end

--【OnRemoteActionButton(actioncode, target, isreleased, noforce, mod_name)】
--   服务端对端。2330 行 `self:GetActionButtonAction(target)` ——
--   ★★ 注意传的是 target 而非 nil：客户端指定了目标，服务端**必须在同目标上**重算。
--     若客户端没给 target（nil），服务端会走 2227 行的空间搜索分支，
--     可能选中另一个实体 → code 不匹配 → 丢弃。这正是防「隔空抓物」的机制。
function PlayerController:OnRemoteActionButton(actioncode, target, isreleased, noforce, mod_name)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.remote_controls[CONTROL_ACTION] = 0
        if actioncode ~= nil then
            SetClientRequestedAction(actioncode, mod_name)
            local buffaction = self:GetActionButtonAction(target)
            ClearClientRequestedAction()
--   ★★ 2332 行是**双条件匹配**：`buffaction.action.code == actioncode and
--   buffaction.action.mod_name == mod_name`。
--     两个都相等才执行。mod_name 用于模组动作的命名空间隔离。
--   ⇒ 这就是「客户端上报意图编号，服务端重算校验」的完整实现。
            if buffaction ~= nil and buffaction.action.code == actioncode and buffaction.action.mod_name == mod_name then
--   2333-2336：服务端算出可 force → 把动作点设为客户端预测位置并标记 forced。
--     ★ forced 会让 actions.lua 的 rangecheckfn 跳过距离检查。
--     ★⚠ 安全注意：这是唯一一处服务端主动 force 的地方，
--       安全性依赖 2332 行的 code 匹配（服务端确实认为玩家在范围内，只是
--       服务器算的位置比客户端靠后）。
                if buffaction.action.canforce and not noforce then
                    buffaction:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
                    buffaction.forced = true
                end
                self.locomotor:PushAction(buffaction, true)
            --elseif mod_name ~= nil then
                --print("Remote action button action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
            --else
                --print("Remote action button action failed: "..tostring(ACTION_IDS[actioncode]))
            end
        end
        if isreleased then
            self.remote_controls[CONTROL_ACTION] = nil
        end
    end
end

--【RemoteActionButton(action, isreleased)】发 RPC 的薄封装。
--   ★ 2354 行 `local noforce = self.locomotor == nil and action ~= nil and ...`：
--     只有「无 locomotor 的客户端」才上报 noforce —— 因为它没法等待 preview，
--     服务端若等重定向会永远等不到。
function PlayerController:RemoteActionButton(action, isreleased)
    local actioncode = action ~= nil and action.action.code or nil
    local action_mod_name = action ~= nil and action.action.mod_name or nil
    local target = action ~= nil and action.target or nil
    local noforce = self.locomotor == nil and action ~= nil and action.action.canforce or nil
    self.remote_controls[CONTROL_ACTION] = action ~= nil and BUTTON_REPEAT_COOLDOWN or 0
    SendRPCToServer(RPC.ActionButton, actioncode, target, isreleased, noforce, action_mod_name)
end

--【GetInspectButtonAction(target)】★ 「查看/检视」动作的五重判据。
--   2361  inspectable 标签：目标可检视
--   2362  CanExamine：角色自定义（眼线等），可为 nil
--   2363  ★ 状态图必须处于 moving/idle/channeling —— 「不能边被控制边看」
--   2364  实体标签也必须是这三者之一（无 sg 时的回退）
--   ⚠ 2363 与 2364 是**同一判据的两套实现**（sg 优先，标签兜底），
--     与 2071-2078 行 IsDoingOrWorking 的双端结构完全同型。
function PlayerController:GetInspectButtonAction(target)
    return target ~= nil and
        target:HasTag("inspectable") and
        (self.inst.CanExamine == nil or self.inst:CanExamine()) and
        (self.inst.sg == nil or self.inst.sg:HasStateTag("moving") or self.inst.sg:HasStateTag("idle") or self.inst.sg:HasStateTag("channeling")) and
        (self.inst:HasTag("moving") or self.inst:HasTag("idle") or self.inst:HasTag("channeling")) and
        BufferedAction(self.inst, target, ACTIONS.LOOKAT) or
        nil
end

--【DoInspectButton】★ 2373 行的英文注释很关键：
--   "Closing the avatar popup takes priority" —— 关闭头像弹窗优先于检视。
--   ⇒ 当玩家的头像面板开着时，按检视键是「关面板」而不是「看目标」。
function PlayerController:DoInspectButton()
    if not self:IsEnabled()
        or (self.inst.HUD ~= nil and
            self.inst.HUD:IsPlayerAvatarPopUpOpen()) then
        --V2C: Closing the avatar popup takes priority
        return
    end
    local buffaction = TheInput:ControllerAttached() and self:GetInspectButtonAction(self:GetControllerTarget()) or nil
    if buffaction == nil then
        return
    end

--   ★ 2382-2388 行：目标带 playeravatardata → 弹出玩家资料框。
--     2385 行 `client_obj.inst = buffaction.target`：
--     ★ 客户端缓存的 data 对象被**就地塞入 inst 引用**——
--       因为 classified 里同步过来的纯数据没有实体引用，需要补上。
    if buffaction.action == ACTIONS.LOOKAT and buffaction.target ~= nil then
        if buffaction.target.components.playeravatardata ~= nil and self.inst.HUD ~= nil then
            local client_obj = buffaction.target.components.playeravatardata:GetData()
            if client_obj ~= nil then
                client_obj.inst = buffaction.target
                self.inst.HUD:TogglePlayerInfoPopup(client_obj.name, client_obj, true, buffaction.target)
            end
        end
--   2390 行注释掉的 assert(self.inst == ThePlayer)：
--     说明这条路径**可能**在非本机玩家上运行（模组调用），K 不确定。
        if self.handler ~= nil then
			--assert(self.inst == ThePlayer)
            TheScrapbookPartitions:SetInspectedByCharacter(buffaction.target, self.inst.prefab)
        end
    end

    if self.ismastersim then
        self.locomotor:PushAction(buffaction, true)
    elseif self.locomotor == nil then
        -- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
        if buffaction.action.pre_action_cb ~= nil then
            buffaction.action.pre_action_cb(buffaction)
        end
        self:RemoteInspectButton(buffaction)
    elseif self:CanLocomote() then
        buffaction.preview_cb = function()
            self:RemoteInspectButton(buffaction)
        end
        self.locomotor:PreviewAction(buffaction, true)
    end
end

--【OnRemoteInspectButton(target)】服务端对端。比ActionButton 简单：
--   不需要 code 校验，因为 LOOKAT 是固定动作，只需要校验目标有效性。
function PlayerController:OnRemoteInspectButton(target)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        local buffaction = self:GetInspectButtonAction(target)
        if buffaction ~= nil then
            self.locomotor:PushAction(buffaction, true)
        --else
            --print("Remote inspect button action failed")
        end
    end
end

function PlayerController:RemoteInspectButton(action)
    SendRPCToServer(RPC.InspectButton, action.target)
end

--★★ 【GetResurrectButtonAction】★ **本文件唯一的「复活玩家」入口**。
--   四重判据：
--     ① 有 playerghost 标签（自己是幽灵）
--     ② 状态图处于 moving/idle（不能被控制中）
--     ③ 实体标签匹配（无 sg 时的回退）
--     ④ ★★ components.attuner:HasAttunement("remoteresurrector" 或
--           "gravestoneresurrector") —— 必须站在复活雕像的有效范围内
--   ⇒ 重生点选择、复活等待时间、复活后满血逻辑**全都不在本文件**。
--     grep 核实：本文件无 respawnpoint / autorespawn / GetRespawnPoint 等符号。
--   ★ 2430 行的 attuner 组件是「乐进的调谐器」——它维护一堆「调谐效果」标记，
--     复活雕像与鼎石会写入这两个。参见 components/attuner.lua。
function PlayerController:GetResurrectButtonAction()
    return self.inst:HasTag("playerghost") and
        (self.inst.sg == nil or self.inst.sg:HasStateTag("moving") or self.inst.sg:HasStateTag("idle")) and
        (self.inst:HasTag("moving") or self.inst:HasTag("idle")) and
        (self.inst.components.attuner:HasAttunement("remoteresurrector")
            or self.inst.components.attuner:HasAttunement("gravestoneresurrector")) and
        BufferedAction(self.inst, nil, ACTIONS.REMOTERESURRECT) or
        nil
end

--【DoResurrectButton】★ 「复活自己」按钮的执行。
--   ★★ 结构与 DoInspectButton（2369 行）**逐字同构**的四分支：
--     ① 2437 行 IsEnabled 守卫
--     ② 2440-2442 行取动作（GetResurrectButtonAction，无参数）
--     ③ 2443-2456 行 master / 无 locomotor / 有 locomotor 三分支
--   ⚠ 2445 行 `self.locomotor == nil` 分支里的断言被注释掉了（2447 行），
--     而 2390 行（DoInspectButton）也有同样的注释掉的 assert。
--   ⇒ 说明这两处曾怀疑「本函数可能在非 ThePlayer 上被调用」，但没查清。
function PlayerController:DoResurrectButton()
    if not self:IsEnabled() then
        return
    end
    local buffaction = self:GetResurrectButtonAction()
    if buffaction == nil then
        return
    elseif self.ismastersim then
        self.locomotor:PushAction(buffaction, true)
    elseif self.locomotor == nil then
        -- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
        if buffaction.action.pre_action_cb ~= nil then
            buffaction.action.pre_action_cb(buffaction)
        end
        self:RemoteResurrectButton(buffaction)
    elseif self:CanLocomote() then
        buffaction.preview_cb = function()
            self:RemoteResurrectButton(buffaction)
        end
        self.locomotor:PreviewAction(buffaction, true)
    end
end

--★ 【OnRemoteResurrectButton】复活的服务端对端 —— ★ 本文件最短的 Remote 函数。
--   ★★ 它**不需要任何参数校验**：因为 REMOTERESURRECT 是固定动作，
--     唯一要校验的是「玩家在不在复活点范围内」，
--     而那由 2430-2431 行的 attuner:HasAttunement 判定（attuner 由雕像维护）。
--   ⇒★★ 这就是本文件「意图编号校验」的**最简形态**：
--     动作唯一 → 无需 code 匹配 → 只需校验执行前提。
--     对比 944 行的 35 行（动作由 picker 决定 → 必须匹配 code）。
--   ⇒ 设计启示：动作越固定，协议校验越简单。
function PlayerController:OnRemoteResurrectButton()
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        local buffaction = self:GetResurrectButtonAction()
        if buffaction ~= nil then
            self.locomotor:PushAction(buffaction, true)
        --else
            --print("Remote resurrect button action failed")
        end
    end
end

--★ 【RemoteResurrectButton】复活 RPC 的发送端 —— 一行。
--   ⚠ 与其他 Remote* 函数不同，它**不设置 remote_controls 的按键状态**。
--     推理依据：全函数只有 SendRPCToServer 一行。
--   ⇒ 后果：复活是**瞬时**操作，不需要「按住不放」的语义。
--     这与「复活台」的使用方式一致（站上去按一下）。
--   ★ 这是本文件里最短的 RPC 发送端，也是最干净的一个。
function PlayerController:RemoteResurrectButton()
    SendRPCToServer(RPC.ResurrectButton)
end

--★ 【DoCharacterCommandWheelButton】指令轮盘（法术书）。三段递进的书本查找。
function PlayerController:DoCharacterCommandWheelButton()
	local isenabled, ishudblocking = self:IsEnabled()
	if not (isenabled or ishudblocking) then
		return
	end

	local inventory = self.inst.replica.inventory
	if inventory and inventory:IsFloaterHeld() then
		return
	end

	--First, try find a spellbook in our inventory
	local invobject = inventory and inventory:FindItem(function(item)
		if item.components.spellbook and item.components.spellbook:CanBeUsedBy(self.inst) then
			--special case for wendy, just hardcoded here for now
--   --special case for wendy, just hardcoded here for now
--   ★★★ 温蒂特例：拿着的阿比盖尔之花 + 尚未召唤 → 不能用法术轮盘。
--   ⚠ 疑似缺陷（硬编码）：角色特例被写在通用控制器里，而不是通过
--     "ghostfriend_notsummoned" 标签的通用规则表达。
--     推理依据：注释自认 "just hardcoded here for now"；
--       若有第二个角色需要类似逻辑，会继续在此堆积。
--   ⇒ 好的一面：2490 行的 prefab == 判断保证了只影响温蒂。
			if item.prefab == "abigail_flower" and self.inst:HasTag("ghostfriend_notsummoned") then
				return false
			end
			return true
		end
		return false
	end)

	local target
	if invobject == nil then
		--Second, try see if we are a spellbook ourself
		if self.inst.components.spellbook and self.inst.components.spellbook:CanBeUsedBy(self.inst) then
			target = self.inst
--   getlinkedspellbookfn：角色 prefab 提供「我关联的书」。
--   2505 行的三重校验确保拿到的确实是合法法术书。
		elseif self.inst.getlinkedspellbookfn then
			--Third, try see if we have a linked spellbook, like our pet
			target = self.inst:getlinkedspellbookfn()
			if target and not (target:IsValid() and target.components.spellbook and target.components.spellbook:CanBeUsedBy(self.inst)) then
				target = nil
			end
		end

		if target == nil then
			--No invobject or target spellbook found
			return
		end
	end

--   ★★ 2516-2520 行：同一次按键，按「轮盘是否已开着这个书」决定开或关。
--     ACTIONS.CLOSESPELLBOOK vs ACTIONS.USESPELLBOOK —— 复用一个按键做 toggle。
--   ⇒ 2557-2558 行的注释解释了为什么不发 CLOSESPELLBOOK 的 RPC：
--     "Don't need to send CLOSESPELLBOOK"（关书纯客户端行为）。
	local act =
		self.inst.HUD and
		self.inst.HUD:GetCurrentOpenSpellBook() == (invobject or target) and
		ACTIONS.CLOSESPELLBOOK or
		ACTIONS.USESPELLBOOK

	act = BufferedAction(self.inst, target, act, invobject)

	if not self.ismastersim then
		if self.locomotor == nil then
			act.non_preview_cb = function()
				self:RemoteCharacterCommandWheelButton(act)
			end
		elseif self:CanLocomote() then
			act.preview_cb = function()
				self:RemoteCharacterCommandWheelButton(act)
			end
		end
	end
	self:DoAction(act)
end

--【OnRemoteCharacterCommandWheelButton(target)】服务端对端。
--   ★ 2542 行区分「书在背包里」（传 invobject）vs「角色自己是书」（传 target）。
--     这对应客户端 5522 行 `BufferedAction(self.inst, target, act, invobject)`。
function PlayerController:OnRemoteCharacterCommandWheelButton(target)
	if self.ismastersim and self:IsEnabled() and self.handler == nil then
		local buffaction
		if target.components.spellbook and target.components.spellbook:CanBeUsedBy(self.inst) then
			if target.components.inventoryitem and target.components.inventoryitem:GetGrandOwner() then
				buffaction = BufferedAction(self.inst, nil, ACTIONS.USESPELLBOOK, target)
			elseif target == self.inst or (self.inst.getlinkedspellbookfn and target == self.inst:getlinkedspellbookfn()) then
				buffaction = BufferedAction(self.inst, target, ACTIONS.USESPELLBOOK)
			end
		end
		if buffaction then
			self:DoAction(buffaction)
		else
			--print("Remote character command wheel button action failed")
		end
	end
end

function PlayerController:RemoteCharacterCommandWheelButton(action)
	--Don't need to send CLOSESPELLBOOK
	if action.action == ACTIONS.USESPELLBOOK then
		SendRPCToServer(RPC.CharacterCommandWheelButton, action.target or action.invobject)
	end
end

--【UsingMouse】`not TheInput:ControllerAttached()` ——
--   ★ 用它来在 OnLeftClick/OnRightClick（4979/4681 行）开头就 return，
--     实现「手柄模式下鼠标键完全无效」。
function PlayerController:UsingMouse()
    return not TheInput:ControllerAttached()
end

--★★ 【ClearActionHold】★ 清空长按重复的全部状态（4 个字段）。
--   2573-2575 行：客户端还要发 RPC 让服务端同步清空。
--   ⚠ 注意服务端收到 ClearActionHold 后会调 RepeatHeldAction 之外的这个函数
--     （networkclientrpc.lua:1107 → playercontroller:ClearActionHold），
--     服务端**不会**递归发 RPC（因为它自己的 ismastersim 为真）。
function PlayerController:ClearActionHold()
    self.actionholding = false
    self.actionholdtime = nil
    self.lastheldaction = nil
    self.lastheldactiontime = nil
    self.actionrepeatfunction = nil
    if not self.ismastersim then
        SendRPCToServer(RPC.ClearActionHold)
    end
end

--★ ACTIONHOLD_CONTROLS：能触发长按重复的五个控制。
--   PRIMARY / SECONDARY / CONTROLLER_ALTACTION / 两个虚拟库存方向键。
--   ⚠ 这里用 VIRTUAL_CONTROL_*（虚拟控件）而非 CONTROL_*（物理控件），
--     因为长按的判定必须用「实际映射后的键」，与 680-706 行的方案分支一致。
local ACTIONHOLD_CONTROLS = { CONTROL_PRIMARY, CONTROL_SECONDARY, CONTROL_CONTROLLER_ALTACTION, VIRTUAL_CONTROL_INV_ACTION_LEFT, VIRTUAL_CONTROL_INV_ACTION_RIGHT }
local function IsAnyActionHoldButtonHeld()
    for i, v in ipairs(ACTIONHOLD_CONTROLS) do
        if TheInput:IsControlPressed(v) then
            return true
        end
    end
    return false
end

--★★★ 【RepeatHeldAction】★ 长按重复机制。每帧由 3012 行调用（若 actionholding）。
--   ★ 结构：双端各有一份实现，客户端发 RPC 让服务端也执行。
--   客户端分支（2589-2598）：
--     · 有 actionrepeatfunction（库存格长按）→ 本地重发 + 0.8 秒冷却
--     · 否则 → 发 RPC 让服务端走 lastheldaction 路径
--   服务端分支（2599-2626）：
--     · 有 lastheldaction（世界内动作长按，如长按挖掘）→ DoAction + 0.2 秒冷却
--     · 退而求其次用 actionrepeatfunction + 0.8 秒冷却
--     · 都没有 → ClearActionHold（长按结束）
function PlayerController:RepeatHeldAction()
    if not self.ismastersim then
--   ★★ 2590 行的双重条件：`self.actionrepeatfunction and (lastheldactiontime == nil
--   or GetTime() - lastheldactiontime < 1)`。
--     「1 秒」是长按的**滑动窗口**：每次重发都刷新 lastheldactiontime，
--     若两次重发间隔超过 1 秒则视为「不再是长按」，放弃。
--   ⇒ 这是防「点一下松开一点再按住被误判成长按」的机制。
        if self.actionrepeatfunction and (self.lastheldactiontime == nil or GetTime() - self.lastheldactiontime < 1) then
            self.lastheldactiontime = GetTime()
            if self.heldactioncooldown == 0 then
                self.heldactioncooldown = INVENTORY_ACTIONHOLD_REPEAT_COOLDOWN
                self:actionrepeatfunction()
            end
        else
            SendRPCToServer(RPC.RepeatHeldAction)
        end
    else
--   服务端分支的第一道守卫：lastheldaction 必须**仍然有效**。
--   2601 行 `:IsValid()` —— 复用 bufferedaction.lua 的 TestForStart 全套判据
--     （doer/target/invobject 都还有效、目标仍在范围内）。
--   ★ 这是「长按期间目标被打断就自动停」的实现。
		if self.lastheldaction and
			self.lastheldaction:IsValid() and
			(self.lastheldactiontime == nil or GetTime() - self.lastheldactiontime < 1) and
--   NOCLICK 目标（如装饰物）不重复 —— 避免对着装饰物狂点。
			not (self.lastheldaction.target and self.lastheldaction.target:HasTag("NOCLICK"))
		then
            self.lastheldactiontime = GetTime()
--   ★★ 2609 行 `self.lastheldaction.options.no_predict_fastforward = true`：
--     关闭客户端的动画快进。★ 但**永不清除**——
--     options 表是 BufferedAction 实例自己的（bufferedaction.lua:14），
--     所以污染只影响这一个实例，不影响 actions.lua 里的动作原型。
--   ⚠ 疑似缺陷（无复位）：与 2621 行对比，后者在用完后把
--     locomotor.no_predict_fastforward 置回 nil。这里没有对称操作。
--     推理依据：2619-2621 行有 set/clear 成对；2609 行只有 set。
--     后果轻微：该 lastheldaction 实例后续所有重发都不快进。
--     而 lastheldaction 每次新动作都会被 4624 行覆盖，所以实际影响很小。
            if self.heldactioncooldown == 0 then
                self.heldactioncooldown = ACTION_REPEAT_COOLDOWN
				--No fast-forward when repeating
				self.lastheldaction.options.no_predict_fastforward = true
                self:DoAction(self.lastheldaction)
            end
--   elseif：只有 actionrepeatfunction（库存格）时走这条路。
--   2616-2618 行 K 的注释说明了 2619 行为何用 locomotor 的标志：
--     "use temp override flag since we don't know where the bufferedaction
--      may come from, but we know it will be pushed to locomotor"
--     ★★ 这是一个**已知的妥协**：他想在 BufferedAction 上设标志，
--       但不知道它来自哪里，于是把标志设在 locomotor 上（因为确定会走 locomotor）。
        elseif self.actionrepeatfunction and (self.lastheldactiontime == nil or GetTime() - self.lastheldactiontime < 1) then
            self.lastheldactiontime = GetTime()
            if self.heldactioncooldown == 0 then
                self.heldactioncooldown = INVENTORY_ACTIONHOLD_REPEAT_COOLDOWN
				--#V2C: #HACK use temp override flag since we don't know where
				--            the bufferedaction may come from, but we know it
				--            will be pushed to locomotor.
				self.locomotor.no_predict_fastforward = true
                self:actionrepeatfunction()
				self.locomotor.no_predict_fastforward = nil
            end
        else
            self:ClearActionHold()
        end
    end
end

--【OnWallUpdate(dt)】★ 墙钟更新。只有客户端本机玩家（handler ~= nil）才跑相机控制。
--   ★ 为什么相机旋转要在 WallUpdate 而不是 OnUpdate：
--     暂停时 OnUpdate 停止（游戏时间冻结），但相机仍需能转（玩家在暂停菜单里看地图）。
--   ⇒ 这是「墙钟 vs 游戏钟」分离的一个实际用例。
function PlayerController:OnWallUpdate(dt)
    if self.handler then
        self:DoCameraControl()
    end
end

--【GetCombatRetarget / GetCombatTarget】★ 两个「当前目标」查询。
--   GetCombatRetarget → sg.statemem.retarget（**重定向目标**，4603/4804 写入）
--   GetCombatTarget   → sg.statemem.attacktarget（**实际攻击目标**，状态图写）
--   ⇒ ★ 两者不同：retarget 是「玩家想打谁」，attacktarget 是「正在打谁」。
--     连击攻击用 retarget 起手，普通攻击用 attacktarget 维持。
function PlayerController:GetCombatRetarget()
    if self.inst.sg then
        return self.inst.sg.statemem.retarget
    elseif self.inst.replica.combat then
        return self.inst.replica.combat:GetTarget()
    end
end

--   2644 行 `if self.inst.sg then` —— 无 sg 的实体返回 nil。
--   ⚠ 与 2635 行的 elseif 分支不一致：那里无 sg 时回退到 replica.combat:GetTarget()，
--     这里直接返回 nil。⇒ 两者在无 sg 时语义不同。
--     推理依据：2638 行 `elseif self.inst.replica.combat then return ...:GetTarget()`。
function PlayerController:GetCombatTarget()
    if self.inst.sg then
        return self.inst.sg.statemem.attacktarget
    end
    return nil
end

--★★★ 【OnUpdate(dt)】★ 全文件最长函数（526 行），每帧执行一次。
--   它是**唯一**的帧驱动入口，负责把「上一帧积累的各种请求」派发出去。
--   可以分成七段：
--     ① 2651-2656  hack 计时器
--     ② 2658-2663  enabled 判定 + 长按中断
--     ③ 2665-2688  拖拽中断 + 动作重启
--     ④ 2691-2754  ★ 被禁用时的全面清理（本文件最重要的防御块）
--     ⑤ 2756-2802  AOE 有效性 + ★ attack_buffer 派发
--     ⑥ 2804-3020  正常态：目标高亮、放置器、terraformer、长按
--     ⑦ 3022-3175  ★ 移动意图分流（hop / predict / drag / direct / boat）+ 连击攻击
--   ⚠ 注意它是**双端**都跑的：客户端靠它驱动预测，服务端靠它消化远端玩家的 RPC。
function PlayerController:OnUpdate(dt)
--   _hack_ignore_held_controls 的倒计时（开地图的按键忽略窗口）。
--   ★ 为什么在 OnUpdate 递减而不是设个任务：因为这个值可能被 mapscreen
--     重新设置（1361 行），任务式的定时器会在重设后失准。
    if self._hack_ignore_held_controls then
        self._hack_ignore_held_controls = self._hack_ignore_held_controls - dt
        if self._hack_ignore_held_controls < 0 then
            self._hack_ignore_held_controls = nil
        end
    end

--   ★★ 2659 行 `self.predictionsent = false` 每帧清零 ——
--     它是 3930 行 RemotePredictWalking 设置的一次性标志。
--     ⚠ 这个字段已被标记 deprecated（106 行注释），此处仍在维护。
    local isenabled, ishudblocking = self:IsEnabled()
    self.predictionsent = false

--   ★ 长按中断：actionholding 为真但**没有任何长按键被按住** → 清空。
--     这是玩家「按住挖掘 → 松开方向键」的正常结束路径。
--   ⚠ 2661 行用了 `isenabled and IsAnyActionHoldButtonHeld()` 的**双重否定**：
--     只有「enabled 且有键按住」才算仍在长按。
--     若 HUD 突然抢焦点（isenabled 转 false）→ 立即中断长按。合理。
    if self.actionholding and not (isenabled and IsAnyActionHoldButtonHeld()) then
        self:ClearActionHold()
    end

--   ★★ 拖拽中断：draggingonground（鼠标左键按住拖地）且 CONTROL_PRIMARY 松开。
--   2667 行的分支：有 locomotor → Stop 并**取出** bufferedaction；
--     否则 → Clear（丢弃动作）。
--   ★ 2670 vs 2672 的差别很关键：
--     enabled → 保留 bufferedaction（2681-2687 会重启它）
--     非 enabled（HUD 抢焦点）→ 直接 Clear，动作作废
--   ⇒ 「点地面走过去，鼠标松开时恰好菜单弹出」会丢掉这个 walkto 动作。
    if self.draggingonground and not (isenabled and TheInput:IsControlPressed(CONTROL_PRIMARY)) then
		local buffaction
        if self.locomotor ~= nil then
            self.locomotor:Stop()
			if isenabled then
				buffaction = self.locomotor.bufferedaction
			else
				self.locomotor:Clear()
			end
        end
        self.draggingonground = false
        self.startdragtime = nil
        TheFrontEnd:LockFocus(false)

--   --restart any buffered actions that may have been pushed at the same time
--   as the user releasing draggingonground
--   ★★ 这是本文件反复出现的三行模式（2681-2687、4405-4413、4531-4539）。
--     「松开方向键/鼠标」与「按下动作键」发生在同一帧时，先 Stop 再重启，
--     保证新动作不被「停止移动」的副作用清掉。
--   ⇒ 4389-4414 与 4509-4540 是这套逻辑的两个副本，加上这里的第三处。
--   ⚠ 疑似缺陷（代码重复）：三处逻辑相同但没有抽成函数，
--     修改一处容易漏另两处。已核实三处的分支条件完全一致。
		--restart any buffered actions that may have been pushed at the
		--same time as the user releasing draggingonground
		if buffaction then
			if self.ismastersim then
				self.locomotor:PushAction(buffaction)
			else
				self.locomotor:PreviewAction(buffaction)
			end
		end
    end

--★★★ 【2691-2754 被禁用时的清理块】★ 本文件最dense 的防御代码。
--   触发条件：IsEnabled 的第一个返回值为 false（不管第二个）。
--   ★ allow_loco = ishudblocking：**HUD 阻塞时不清移动状态**，
--     因为在合成菜单里按方向键应该能继续走路（497 行的设计）。
    --ishudblocking set to true lets us know that the only reason for isenabled returning false is due to HUD wanting to handle some input.
    if not isenabled then
		local allow_loco = ishudblocking
--   ★ 完全禁用（不是 HUD 阻塞）时：
--     ① 停 locomotor + Clear
--     ② 清三个移动标志
--     ③ 客户端额外发 RemoteStopWalking（2702-2704）
--   ⇒ 「玩家被禁用时服务器还在跑」这个不一致被彻底消除。
		if not allow_loco then
			if self.directwalking or self.dragwalking then
				if self.locomotor ~= nil then
					self.locomotor:Stop()
					self.locomotor:Clear()
				end
				self.directwalking = false
				self.dragwalking = false
				self.predictwalking = false
				if not self.ismastersim then
					self:RemoteStopWalking()
				end
			end
		end

--   ★ 只有 handler ~= nil（本机客户端）才做 UI 层清理。
--     服务端没有 HUD，不需要取消放置/准星。
        if self.handler ~= nil then
            self:CancelPlacement(true)
            self:CancelDeployPlacement()
            self:CancelAOETargeting()
--   2712-2714 行：`if not ishudblocking and HUD ~= nil then HUD:CloseSpellWheel()`
--   ⚠ 疑似缺陷（UI 行为不一致）：只在「非 hudblocking」时才关法术轮盘。
--     但 2710/2711 行（CancelPlacement/CancelDeployPlacement）**无条件**执行。
--   推理依据：对比 2710-2711 与 2712-2714 的条件差异。
--     推测意图：法术轮盘开着时 ishudblocking 为真，此时不能强行关（否则玩家
--       打开轮盘的同时就被关了）。但后果是「轮盘开着 + 玩家被禁用」时
--       轮盘不会被清理。
			if not ishudblocking and self.inst.HUD ~= nil then
				self.inst.HUD:CloseSpellWheel()
			end

            if self.reticule ~= nil and self.reticule.reticule ~= nil then
                self.reticule.reticule:Hide()
            end

            if self.terraformer ~= nil then
                self.terraformer:Remove()
                self.terraformer = nil
            end
            
            self.LMBaction, self.RMBaction = nil, nil
            self.controller_target = nil
            self.controller_attack_target = nil
            self.controller_attack_target_ally_cd = nil
--   ★ 清理高亮：self.highlight_guy 是「当前被高亮的实体」。
--     ⚠ 注意这个字段**在构造函数里没有初始化**（grep 确认只在 2729/2848/2852 用）。
--     依赖 Lua 的 nil 语义工作（2729 行的 ~= nil 守卫）。属可接受但脆弱的写法。
            if self.highlight_guy ~= nil and self.highlight_guy:IsValid() and self.highlight_guy.components.highlight ~= nil then
                self.highlight_guy.components.highlight:UnHighlight()
            end
            self.highlight_guy = nil
        end

--   ★★ 服务端 vs 客户端的禁用清理：
--     服务端 → ResetRemoteController（清 remote_vector + remote_controls）
--     客户端 → RemoteStopAllControls（发 RPC）+ DoPredictWalking(dt)
--   2740-2744 行的注释很关键：
--     "Other than HUD blocking, we would've been enabled otherwise"
--     → 客户端在「HUD 阻塞」状态下**仍然继续预测移动**（2742 行），
--       否则玩家在菜单里走两步就会与服务器分叉。
        if self.ismastersim then
            self:ResetRemoteController()
        else
            self:RemoteStopAllControls()

            --Other than HUD blocking, we would've been enabled otherwise
            if not self:IsBusy() then
                self:DoPredictWalking(dt)
			else
				self:ClearRemotePredictData(true)
            end
        end

--   ★ controller_attack_override 清理：手柄「按住扳机持续攻击」的临时覆盖。
--   ★ 2749 行 `self.recent_bufferedaction.act = nil`：
--     「刚放下方向键不取消动作」的护栏失效 —— 因为玩家状态变了。
        self.controller_attack_override = nil
		self.recent_bufferedaction.act = nil

		if not allow_loco then
	        self.attack_buffer = nil
		end
    end

--★ AOE 瞄准态的每帧有效性检查（2756-2765）。
--   三种失效：
--     ① 施法者实体失效或燃料耗尽（fueldepleted）→ 取消
--     ② 施法者不再是自己拥有（被丢了/被抢了）→ 取消
--   ★ 2757 行的 `self.reticule.inst:IsValid()`：reticule.inst 才是施法者，
--     reticule 本身是准星组件的包装。
	if self:IsAOETargeting() then
		if not self.reticule.inst:IsValid() or self.reticule.inst:HasTag("fueldepleted") then
			self:CancelAOETargeting()
		else
			local inventoryitem = self.reticule.inst.replica.inventoryitem
			if inventoryitem ~= nil and not inventoryitem:IsGrandOwner(self.inst) then
				self:CancelAOETargeting()
			end
		end
	end

--   ★ usingmagiciantool 标签（魔术帽）：施法中禁用一切放置/瞄准态。
--   ★ 2769-2771 行的分支：鼠标模式不取消 deploy（因为鼠标右键就是部署），
--     手柄模式才取消。
	if self.handler ~= nil and self.inst:HasTag("usingmagiciantool") then
		self:CancelPlacement()
        if not self:UsingMouse() then
            self:CancelDeployPlacement()
        end
		self:CancelAOETargeting()
	end

--★★★ 【attack_buffer 派发】2776-2802 行。★ 本文件的「按键缓冲」实现。
--   为什么需要缓冲：见 635 行的说明 —— OnControl 时刻状态图还没切到 attack，
--     直接执行会误判「不能攻击」。所以推迟到 OnUpdate（此时上一帧的状态已生效）。
--   ★ 四种取值：
--     ① CONTROL_ATTACK（636 行存的常量）→ DoAttackButton
--     ② CONTROL_CONTROLLER_ATTACK（673 行存的常量）→ DoControllerAttackButton
--     ③ 普通 BufferedAction（1401/1407/1946/1952 行存的）
--     ④ 带 _controller / _predictpos 标记的（1402/1403/1408/1412 行）
	--Attack controls are buffered and handled here in the update
	if self.attack_buffer ~= nil then
		if self.attack_buffer == CONTROL_ATTACK then
			self:DoAttackButton()
		elseif self.attack_buffer == CONTROL_CONTROLLER_ATTACK then
			self:DoControllerAttackButton()
		else
--   ★ _predictpos（1403/1412/1413 行设置）：动作点用客户端预测位置。
--     2783 行 `self:GetRemotePredictPosition() or self.inst:GetPosition()`。
--     ⇒ 与 975 行的 forced 逻辑同源：让服务器的动作点对齐客户端站位。
			if self.attack_buffer._predictpos then
				self.attack_buffer:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
			end
--   ★ _controller 标记：来自手柄的攻击（1402/1408 行设置）。
--   2786-2787 行：目标为 nil 时若扳机仍按着，**保留** override 让后续帧持续攻击。
--     ★ 这是「按住扳机 = 持续攻击」的实现：controller_attack_override 非 nil 时
--       3045 行的 DoPredictWalking 会被跳过、4310 行的 DoDirectWalking 也会跳过。
			if self.attack_buffer._controller then
				if self.attack_buffer.target == nil then
					self.controller_attack_override = self:IsControlPressed(CONTROL_CONTROLLER_ATTACK) and self.attack_buffer or nil
				end
				self:DoAction(self.attack_buffer)
--   普通（非手柄）攻击：2810 行的重复动作检查。
--   2792-2798 行：若当前已有**相同动作 + 相同目标**的缓冲动作 → 丢弃。
--     ★ 与 4587-4600 行 DoAction 里的重复检查重复，但少了 pos 的比较。
--     ⇒ 轻微不一致：这里的检查不含位置，可能误丢弃「在两个相似位置挖同一棵树」。
--     推理依据：对比 4589-4596 行（含 pos == 比较）与 2793-2795 行（不含）。
			else
				--Check for duplicate actions
				local currentbuffaction = self.inst:GetBufferedAction()
				if not (currentbuffaction ~= nil and
						currentbuffaction.action == self.attack_buffer.action and
						currentbuffaction.target == self.attack_buffer.target)
				then
					self.locomotor:PushAction(self.attack_buffer, true)
				end
			end
		end
		self.attack_buffer = nil
	end

--   ★★ 2804 行 `if isenabled then` 之后是**纯表现层**（高亮、放置器、terraformer）。
--     这些全是本地 UI，不发 RPC、不影响服务器。
--   ⇒ 这解释了为什么这一整段（约 220 行）在服务端「本地玩家」路径下也会跑
--     ——因为 handler ~= nil 的服务端玩家（房主的客户端）也需要高亮。
    if isenabled then
		--Restore cached placer
--   ★★ placer_cached 恢复（2806-2811）：菜单关闭后自动重建建造放置器。
--   这是 1522-1529 行 CancelPlacement(cache) 的消费端。
--   ⇒ ★ 完整闭环：开菜单 → OnUpdate 判定不 enabled → CancelPlacement(true)
--     缓存蓝图 → 关菜单 → OnUpdate 判定 enabled → StartBuildPlacementMode(unpack(...))。
		if self.placer_cached ~= nil then
			if self.inst.replica.inventory:IsVisible() then
				self:StartBuildPlacementMode(unpack(self.placer_cached))
			end
			self.placer_cached = nil
		end


--   ★★ 2815 行的 controller_mode 分流：本节的所有逻辑在鼠标/手柄下**完全不同**。
--     鼠标（2823-2844）：调 playeractionpicker:DoGetMouseActions 取 LMB/RMB
--     手柄（2819-2822）：调 UpdateControllerTargets（3185 行）做方向键目标选择
--   ⇒ ★ 这是「同一套游戏逻辑、两套输入方案」在代码层面的分水岭。
		if self.handler ~= nil then
			local controller_mode = TheInput:ControllerAttached()
			local new_highlight = nil
--   2817 行 `not self.inst:IsActionsVisible()`：玩家主动关掉了动作提示 → 不高亮。
--   ★ 这是一个纯外观开关（可通过 UI 关闭），但**影响是否调 DoGetMouseActions**。
			if not self.inst:IsActionsVisible() then
				--Don't highlight when actions are hidden
			elseif controller_mode then
				self.LMBaction, self.RMBaction = nil, nil
				self:UpdateControllerTargets(dt)
				new_highlight = self.controller_target
			else
				self.controller_target = nil
				self.controller_attack_target = nil
				self.controller_attack_target_ally_cd = nil
--   ★★ 2827 行 `self.inst.components.playeractionpicker:DoGetMouseActions()`：
--     每帧重新计算「鼠标左/右键各对应什么动作」。
--   ⚠ 性能注意：DoGetMouseActions（playeractionpicker.lua:498）内部会遍历
--     大量候选动作并排序，**每帧每客户端一次**。
--     若 profile 关闭了动作提示，2817 行会跳过它 —— 这也是性能优化。
				self.LMBaction, self.RMBaction = self.inst.components.playeractionpicker:DoGetMouseActions()

--   --If an action has a target, highlight the target. / If an action has no
--   target and no pos, then it should be an inventory action where doer is
--   ourself and we are targeting ourself, so highlight ourself
--   ★ 这段注释解释了 2833-2844 行那个三段 and/or 表达式：
--     「无 target 无 pos ⇒ 是对自己用背包物品 ⇒ 高亮自己」。
				--If an action has a target, highlight the target.
				--If an action has no target and no pos, then it should
				--be an inventory action where doer is ourself and we are
				--targeting ourself, so highlight ourself
				new_highlight =
					(self.LMBaction ~= nil
					and (self.LMBaction.target
						or (self.LMBaction.pos == nil and
							self.LMBaction.doer == self.inst and
							self.inst))) or
					(self.RMBaction ~= nil
					and (self.RMBaction.target
						or (self.RMBaction.pos == nil and
							self.RMBaction.doer == self.inst and
							self.inst))) or
					nil
			end

--   ★ highlightforward：模组的「高亮转发」——实际高亮的可能是另一个实体
--     （如长矛高亮的是它指向的敌人）。2264/3464 行的 client_forward_target 同源。
			local new_highlight_guy = new_highlight ~= nil and new_highlight.highlightforward or new_highlight
			if new_highlight_guy ~= self.highlight_guy then
				if self.highlight_guy ~= nil and self.highlight_guy:IsValid() and self.highlight_guy.components.highlight ~= nil then
					self.highlight_guy.components.highlight:UnHighlight()
				end
				self.highlight_guy = new_highlight_guy
			end

--   ★ 2856-2858 行：目标实体没有 highlight 组件 → 动态 AddComponent。
--   ⚠ 这是**运行时给别人的实体加组件**。在 DST 里给远端玩家的实体加组件
--     是允许的（组件不自动同步），所以只有本机看得到高亮 —— 正是想要的。
			if new_highlight_guy ~= nil and new_highlight_guy:IsValid() then
				if new_highlight_guy.components.highlight == nil then
					new_highlight_guy:AddComponent("highlight")
				end

--   2861 行注释 "--V2C: check tags on the original, not the forwarded"：
--     ★ 高亮的标签判定用**原始实体**（new_highlight）而非转发目标（new_highlight_guy）。
--     因为「是否已烧焦」是原始实体的属性。
				if not self.inst.shownothightlight then
					--V2C: check tags on the original, not the forwarded
--   burnt（烧焦）目标用灰色高亮 (.5,.5,.5)，暗示「这个不能用了」。
					if new_highlight:HasTag("burnt") then
						new_highlight_guy.components.highlight:Highlight(.5, .5, .5)
					else
						new_highlight_guy.components.highlight:Highlight()
					end
				end
			else
				self.highlight_guy = nil
			end

--   ★ 2872 行：鼠标模式且准星不跟随鼠标 → 拆掉准星。
--     典型：某些工具自带固定准星（如指南针），鼠标模式下不需要。
			if self.reticule ~= nil and not (controller_mode or self.reticule.mouseenabled) then
				self.reticule:DestroyReticule()
				self.reticule = nil
			end

--   ★ 2878 行 `not builder:IsBuildBuffered(recipe.name)`：
--     「建造已被服务器接受/正在排队」→ 取消本地预览。
--     ⇒ 这是客户端感知服务器状态的第二条通道（第一条是 classified）。
			if self.placer ~= nil and self.placer_recipe ~= nil and
				not (self.inst.replica.builder ~= nil and self.inst.replica.builder:IsBuildBuffered(self.placer_recipe.name)) then
				self:CancelPlacement()
			end

--   ★ placer_item：手柄取光标物品，鼠标取「激活物品」（右手拿着的）。
			local placer_item = controller_mode and self:GetCursorInventoryObject() or self.inst.replica.inventory:GetActiveItem()
			--show deploy placer
--   ★ 部署放置器的显示条件（四重）：deploy_mode 且无建造 placer 且有可部署物品。
			if self.deploy_mode and
				self.placer == nil and
				placer_item ~= nil and
				placer_item.replica.inventoryitem ~= nil and
				placer_item.replica.inventoryitem:IsDeployable(self.inst) then

				local placer_name = placer_item.replica.inventoryitem:GetDeployPlacerName()
--   ★ 2891 行的自认 hack："hack that relies on the build name to match the
--   linked skinname" —— 用 AnimState:GetSkinBuild() 反查皮肤，
--   依赖「建造名与皮肤名一致」的隐式约定。
--   ⚠ 疑似缺陷（命名约定耦合）：若某皮肤名与 build 名不符，放置器皮肤会错。
--     推理依据：注释自认是 hack；正确做法是 GetDeployPlacerSkin 之类的显式接口。
				local placer_skin = placer_item.AnimState:GetSkinBuild() --hack that relies on the build name to match the linked skinname
                if placer_skin == "" then
                    placer_skin = nil
                end
                if self.deployplacer ~= nil and (self.deployplacer.prefab ~= placer_name or self.deployplacer.skinname ~= placer_skin) then
					self:CancelDeployPlacement()
				end
				if self.deployplacer == nil then
					self.deployplacer = SpawnPrefab(placer_name, placer_skin, nil, self.inst.userid )
					if self.deployplacer ~= nil then
                        local placer = self.deployplacer.components.placer
						placer:SetBuilder(self.inst, nil, placer_item)
--   ★ placer.testfn：部署合法性判定。2908 行用逗号连接两个返回值
--     （CanDeploy 的结果, 「是否可以放置到鼠标指向的实体上」）。
--   ⚠ 疑似缺陷（逗号表达式易错）：Lua 的逗号构造多返回值，
--     这里依赖 testfn 契约允许返回两个值。语义是「地形可放」或「鼠标指向物也可放」。
--     可读性差，建议改成 local 变量。
						placer.testfn = function(pt)
							local mouseover = (not placer:IsAxisAlignedPlacement()) and TheInput:GetWorldEntityUnderMouse() or nil
							return placer_item:IsValid() and
								placer_item.replica.inventoryitem ~= nil and
								placer_item.replica.inventoryitem:CanDeploy(pt, mouseover, self.inst, self.deployplacer.Transform:GetRotation()),
								(mouseover ~= nil and not mouseover:HasTag("walkableplatform") and not mouseover:HasTag("walkableperipheral") and not mouseover:HasTag("ignoremouseover")) or TheInput:GetHUDEntityUnderMouse() ~= nil
						end
--   placer:OnUpdate(0) 手动推一帧：「so that our position is accurate on the first frame」。
--   ★ 原因：SpawnPrefab 出来的实体位置未初始化，直接给玩家用会闪一下。
						placer:OnUpdate(0) --so that our position is accurate on the first frame
					end
				end
			else
				self:CancelDeployPlacement()
			end

--★ 【terraformer 段】2917-2974 行：右键「改变地形」类动作的放置器。
--   例：铲子挖地、草种种植、挖洞。terraform_action 来自 rmb.action.tile_placer。
			local terraform = false
			local hideactionreticuleoverride = false
			local terraform_action = nil
			if controller_mode then
--   ★ 2921 行手柄用 GetGroundUseAction（点坐标），2936 行鼠标用 GetRightMouseAction（缓存）。
--     ★★ 这是鼠标与手柄的第二处不对称：鼠标的动作是**上一帧缓存的**，
--       手柄的动作是**本帧现算的**。鼠标路径省算力，手柄路径保证新鲜度。
				local lmb, rmb = self:GetGroundUseAction()
				if rmb ~= nil then
--   2923 行 `rmb.action.tile_placer ~= nil` —— 判据是「动作带 tile_placer」。
--   ★★ 所以「哪些动作会显示地形放置器」完全由 actions.lua 的 tile_placer 字段决定。
--     参见 actions.lua 中 TERRAFORM / DIG / PLANT 等动作的 tile_placer = "..."。
					terraform = rmb.action.tile_placer ~= nil
					terraform_action = terraform and rmb.action or nil
					--hide reticule if not a point action (ie. STOPUSINGMAGICTOOL)
--   --hide reticule if not a point action (ie. STOPUSINGMAGICTOOL)
--   2926 行 hideactionreticuleoverride：rmb 没有 pos（不是点地动作）→ 藏准星。
					hideactionreticuleoverride = rmb.pos == nil
				end
				--If reticule is from special action, hide it when other actions are available
--   --If reticule is from special action, hide it when other actions are available
--   ★ 这是「准星所有权仲裁」的第二个例子（第一个在 222-224 行法术书特例）。
--     准星属于「特殊点地动作」时，若出现了普通目标动作则隐藏准星。
				if not hideactionreticuleoverride and self.reticule ~= nil and self.reticule.inst == self.inst then
					if rmb == nil and self.controller_target ~= nil then
						lmb, rmb = self:GetSceneItemControllerAction(self.controller_target)
					end
--   2933 行 `hideactionreticuleoverride = rmb ~= nil or not HasGroundUseSpecialAction(true)`：
--     ★ 有普通动作 **或** 没有特殊动作 → 都要藏。这两个条件是「或」而非「且」，
--     读起来容易反直觉：只有「无普通动作 且 有特殊动作」才显示准星。
					hideactionreticuleoverride = rmb ~= nil or not self:HasGroundUseSpecialAction(true)
				end
			else
				local rmb = self:GetRightMouseAction()
				if rmb ~= nil then
--   ★ 鼠标路径多一个 show_tile_placer_fn 钩子（手柄路径没有）。
--     2938 行还重复调了一次 GetRightMouseAction()（作为参数传入）。
--   ⚠ 疑似缺陷（低效）：`rmb.action.show_tile_placer_fn(self:GetRightMouseAction())`
--     明明 rmb 已经是当前动作，却又调了一次 getter。虽然 getter 只是返回缓存，
--     但这种写法暗示作者不确定 rmb 的有效性。
					terraform = rmb.action.tile_placer ~= nil and (rmb.action.show_tile_placer_fn == nil or rmb.action.show_tile_placer_fn(self:GetRightMouseAction()))
					terraform_action = terraform and rmb.action or nil
				end
			end

			--show right action reticule
--   ★ 2944 行：只有在没有建造/部署放置器时才显示 terraformer 与准星。
--     三者（placer / deployplacer / terraformer）互斥，避免视觉打架。
			if self.placer == nil and self.deployplacer == nil then
				if terraform then
					if self.terraformer == nil then
--   ★ SpawnPrefab(terraform_action.tile_placer) —— tile_placer 字段直接是预制体名。
						self.terraformer = SpawnPrefab(terraform_action.tile_placer)
						if self.terraformer ~= nil and self.terraformer.components.placer ~= nil then
							self.terraformer.components.placer:SetBuilder(self.inst)
							self.terraformer.components.placer:OnUpdate(0)
						end
					end
				elseif self.terraformer ~= nil then
					self.terraformer:Remove()
					self.terraformer = nil
				end

--   ★ 2959 行 `hideactionreticuleoverride or self.reticule:ShouldHide()`：
--     两个来源的隐藏需求合并。ShouldHide 由准星组件自己实现（如月亮风暴时隐藏）。
				if self.reticule ~= nil and self.reticule.reticule ~= nil then
					if hideactionreticuleoverride or self.reticule:ShouldHide() then
						self.reticule.reticule:Hide()
					else
						self.reticule.reticule:Show()
					end
				end
			else
				if self.terraformer ~= nil then
					self.terraformer:Remove()
					self.terraformer = nil
				end

				if self.reticule ~= nil and self.reticule.reticule ~= nil then
					self.reticule.reticule:Hide()
				end
			end

--★★ 【长按判定】2976-2980 行：按住动作键 8 秒（START_DRAG_TIME = 8*FRAMES，
--   ⚠ 注意单位混用：START_DRAG_TIME = 8 * FRAMES 是**帧数**不是秒数！
--     而 2977 行用 `GetTime() - self.actionholdtime > START_DRAG_TIME`
--     比较的是**秒**。FRAMES = 1/30，所以 8*FRAMES = 0.267 秒。
--   ⚠⚠ 疑似缺陷（单位错配）：常量名与赋值暗示「8 帧」，但被当作秒使用。
--     推理依据：1 行 `local START_DRAG_TIME = 8 * FRAMES`；
--       constants.lua 的 FRAMES 定义为 1/30；
--       2977 与 2984 行都用 GetTime()（返回秒）与之比较。
--     实际效果：长按触发阈值是 0.267 秒而非「8 帧」想表达的 0.267 秒——
--       巧合的是两者数值相同，但**语义完全不符**：若 FRAMES 改成 1/60，
--       长按阈值会减半。变量名与 FRAMES 乘法强烈暗示本意是「8 帧 ≈ 0.27 秒」，
--       而 2977/2984 行想表达的是「按住一段时间」。这至少是一个命名/意图缺陷。
			if not self.actionholding and self.actionholdtime and IsAnyActionHoldButtonHeld() then
				if GetTime() - self.actionholdtime > START_DRAG_TIME then
					self.actionholding = true
				end
			end

--   ★★ 鼠标拖拽判定：2984 行同样是 `now - self.startdragtime > START_DRAG_TIME`。
--     4798 行在 WALKTO 且目标不是平台时设置 startdragtime = t。
--   ⇒ 「按住左键不动超过 0.27 秒 → 进入拖拽行走模式」。
			if not self.draggingonground and self.startdragtime ~= nil and TheInput:IsControlPressed(CONTROL_PRIMARY) then
				local now = GetTime()
				if now - self.startdragtime > START_DRAG_TIME then
					TheFrontEnd:LockFocus(true)
					self.draggingonground = true
				end
			end

--   ★ 焦点丢失（GetFocusWidget 不等于 HUD）→ 强制退出拖拽与长按。
--     ★ 2997 行的守卫 `CanLocomote()`：无预测能力时不能 Clear（会丢动作）。
			if TheFrontEnd:GetFocusWidget() ~= self.inst.HUD then
				if self.draggingonground then
					self.draggingonground = false
					self.startdragtime = nil

					TheFrontEnd:LockFocus(false)

					if self:CanLocomote() then
						self.locomotor:Stop()
						self.locomotor:Clear()
					end
				elseif self.actionholding then
					self:ClearActionHold()
				end
			end
--★★ 3005-3008 行：`elseif self.ismastersim and HasTag("nopredict") and
--   remote_vector.y >= 3` —— 服务端对「明确不能预测」的玩家的特殊处理。
--   nopredict 标签由 SGwilson.lua 在某些状态（如莫比乌斯卷轴的混乱）添加。
--   ★ 3007 行 ClearRemotePredictData() 而**不发 RPC**：
--     因为这是服务端的决定，客户端没资格预测到。
--   ⚠ 但 remote_vector.y 被置 0 后，客户端的下一个 PredictWalking RPC
--     （3924 行的条件 `self.remote_vector.y ~= y and self.remote_vector.y ~= 0`）
--     会因为「已经是 0」而**跳过发送**！
--   ⇒ 后果：nopredict 玩家一旦触发这个分支，客户端的预测目标坐标就卡在
--     旧值，且因 3924 行条件不成立而**再也不会更新**。
--     这是一个真实的协议状态机缺陷。
--     推理依据：3006 行 self.remote_vector.y = 0 与 3924 行的
--       `(self.remote_vector.x ~= x or self.remote_vector.z ~= z or
--        (self.remote_vector.y ~= y and self.remote_vector.y ~= 0))` ——
--       最后那个 `self.remote_vector.y ~= 0` 显式豁免了 y==0 的情况。
--       意图是「服务器说停了就别再发」，但 nopredict 是临时状态。
		elseif self.ismastersim and self.inst:HasTag("nopredict") and self.remote_vector.y >= 3 then
			self.remote_vector.y = 0
			self:ClearRemotePredictData()
		end

--   CooldownHeldAction(dt)：长按冷却递减（每帧）。
		self:CooldownHeldAction(dt)
--   ★ actionholding 为真 → 每帧 RepeatHeldAction（长按重复）。
		if self.actionholding then
			self:RepeatHeldAction()
		end

--   ★ controller_attack_override 的存活判定：
--     「手柄攻击缓冲动作仍是 locomotor 的当前动作」且「扳机仍按着」。
--   ⚠ 3016 行 `self.locomotor.bufferedaction` 没有 nil 检查 self.locomotor！
--     推理依据：3016 行直接 `self.locomotor.bufferedaction == ...`。
--     缓解：controller_attack_override 只在有 locomotor 的路径（2789 行 DoAction）设置，
--       而 DoAction 在无 locomotor 时 4631 行提前 return，故 override 不被设置。
--       但这是**间接**保证，非常脆弱。
		if self.controller_attack_override ~= nil and
			not (self.locomotor.bufferedaction == self.controller_attack_override and
				self:IsControlPressed(CONTROL_CONTROLLER_ATTACK)) then
			self.controller_attack_override = nil
		end
	end

--★ DoPredictHopping：客户端检测到本地 locomotor 开始跳跃 → 发 StartHop RPC。
--   ★★ 3948 行的 `ThePlayer == self.inst and not self.ismastersim` ——
--     只有本机预测客户端做这件事（远端玩家的跳跃由服务器自己在 3835 处理）。
    self:DoPredictHopping(dt)

--   ★ 3024 行：既没 enabled 也没 hudblocking → 到此为止。
--   3025-3026 行的注释 "don't think this should call; delete after confirming
--   no side effects" + 注释掉的 DoClientBusyOverrideLocomote：
--     ⇒ 这是一个**被有意短路**的调用。3041 行的 isbusy 分支仍会调它，
--       所以 3026 这处的注释表达的是「不 disabled 时不该调」。
	if not isenabled and not ishudblocking then
		--V2C: don't think this should call; delete after confirming no side effects.
		--self:DoClientBusyOverrideLocomote()
		return
	end

--   --NOTE: isbusy is used further below as well
--   3031 行算一次 isbusy，供 3040 和 3121 两处使用。
    --NOTE: isbusy is used further below as well
    local isbusy = self:IsBusy()

--★★ 3033-3037 行的 `#HACK for hopping prediction`：
--   "ignore server 'busy' if server still 'boathopping' but we're not anymore"
--   → 客户端已从「跳船中」状态出来，但服务器的 busy 标签还没清，
--     于是强行把 isbusy 视为 false，让玩家能立即继续操作。
--   ⚠ 这是一个**单向豁免**：只豁免 boathopping，不豁免其他 busy 原因。
--     若同一个 busy 标签同时覆盖「跳船中」和「别的忙」，豁免会误放。
	--#HACK for hopping prediction
	--ignore server "busy" if server still "boathopping" but we're not anymore
	if isbusy and self.inst.sg ~= nil and self.inst:HasTag("boathopping") and not self.inst.sg:HasStateTag("boathopping") then
		isbusy = false
	end

--   ★ allowdoubletapdiraction：是否允许「双击方向键」触发动作（如双击跳跃）。
--     默认 false，只有在「正在走路」或「完全空闲」时才 true。
--     ⇒ 设计意图：走路时不能双击跳（会冲突），停下才能。
	local allowdoubletapdiraction = false
--★★★ 【3040-3079 移动意图分流】★★ 本文件第二核心。
--   五种互斥的移动状态，按优先级：
--     ① isbusy → DoClientBusyOverrideLocomote + DoDirectStopWalking（3041-3044）
--     ② 预测/拖拽行走中 → 保持（3045-3049）
--     ③ 空闲 → DoDirectWalking（3062）或 DoBoatSteering（3076）
--   ⚠ 注意②的写法：`if self:DoPredictWalking(dt) or self:DoDragWalking(dt) then`
--     —— 短路求值：预测行走优先，拖拽行走只在预测未激活时才试。
	if isbusy then
--   ★★ busy 时仍然允许「方向微调」（DoClientBusyOverrideLocomote）。
--     用途：密恐魔（Moo Moo）被牛车卡住时能用方向键挣脱。
--     注释 3968-3971 行说明了这个设计：
--     "e.g. Moose tackle can be cancelled using directional input, but
--      the state itself is still busy"。
		self:DoClientBusyOverrideLocomote()
		self.recent_bufferedaction.act = nil
--   ★ ClearRemotePredictData(true) —— busy 时**强制**取消预测计时器。
--     force_reset_timer=true 表示即使没收到 stop 通知也要取消。
		self:ClearRemotePredictData(true)
		self:DoDirectStopWalking()
--   ★★ 3048 行 `self.recent_bufferedaction.act = nil`：
--     移动开始 → 松手护栏失效。这是对的：护栏本来只为「刚松手」设计。
	elseif self:DoPredictWalking(dt)
		or self:DoDragWalking(dt)
		then
		self.recent_bufferedaction.act = nil
		allowdoubletapdiraction = true
    else
--   ★★ 3051 行的 aimingcannon 判定：`boatcannonuser ~= nil and GetCannon() ~= nil`。
--     正在瞄准船炮时**不移动**。3052 行连船舵（steeringboat）也算。
--   ⚠ 3063 行的 `elseif aimingcannon then` 分支**是空的** —— 什么都不做。
--     这不是 bug 而是一个显式的「冻结」分支，但可读性上应写成注释。
        local aimingcannon = self.inst.components.boatcannonuser ~= nil and self.inst.components.boatcannonuser:GetCannon() ~= nil
        if not (aimingcannon or self.inst:HasTag("steeringboat") or self.inst:HasTag("rotatingboat")) then
            if self.wassteering then
--   ★ 结束船舵瞄准时向船推送 endsteeringreticule 事件（带 player 参数）。
--     ⇒ 船的预制体负责画/收瞄准辅助线。
                -- end reticule
                local boat = self.inst:GetCurrentPlatform()
                if boat then
                    boat:PushEvent("endsteeringreticule",{player=self.inst})
                end
                self.wassteering = nil
            end
			allowdoubletapdiraction = true
--   ★ 空闲时执行 DoDirectWalking（手柄摇杆直走）。
            self:DoDirectWalking(dt)
        elseif aimingcannon then

        else
            if not self.wassteering then
                -- start reticule
                local boat = self.inst:GetCurrentPlatform()
                if boat then
                    boat:PushEvent("starsteeringreticule",{player=self.inst})
                end
            end
            self.wassteering = true

--   ★ 3076 行 DoBoatSteering：手柄/键盘当舵用。
--     ★★ 3062 与 3076 的选择条件是 3052 行的标签，
--       所以「站在船上」会**自动**禁用行走改为操舵 —— 无需玩家按键切换。
            if self.inst:HasTag("steeringboat") then
                self:DoBoatSteering(dt)
            end
        end
    end

--   --do automagic control repeats
--★ 「按住键自动重复」机制（3081-3107）。
--   ★ 3094 行的注释是本文件关于预测最精辟的一段说明：
--     "clear cooldowns if we actually did something on the server /
--      otherwise just decrease / if the server is still 'idle', then it
--      hasn't begun processing the action yet / when using movement prediction,
--      the RPC is sent AFTER reaching the destination, / so we must also
--      check that the server is not still 'moving'"
--   → 翻译：只有当服务器**也**空闲（idle）时，客户端的按键状态才可信；
--     用预测移动时 RPC 是到达后才发的，所以服务器此刻可能还在「移动中」。
--   ⇒ 3094 行传 dt 或传 nil 的选择 = 「清零」还是「倒数」，见 537 行的二义性。
    --do automagic control repeats
	if self.handler ~= nil then
		--do double tap first =)
		self:DoDoubleTapDir(allowdoubletapdiraction)

        local isidle = self.inst:HasTag("idle")

        if not self.ismastersim then
            --clear cooldowns if we actually did something on the server
            --otherwise just decrease
            --if the server is still "idle", then it hasn't begun processing the action yet
            --when using movement prediction, the RPC is sent AFTER reaching the destination,
            --so we must also check that the server is not still "moving"
            self:CooldownRemoteController((isidle or (self.inst.sg ~= nil and self.inst:HasTag("moving"))) and dt or nil)
        end

        if self.inst.sg ~= nil then
            isidle = self.inst.sg:HasStateTag("idle") or (isidle and self.inst:HasTag("nopredict"))
        end
--   ★★ 3098 行 isidle 的双端兜底：`sg:HasStateTag("idle") or (isidle and
--   HasTag("nopredict"))` —— 无状态图预测的实体用标签兜底。
        if isidle then
--   ★★ 3101-3106：空闲时若玩家仍按住动作键，**手动重放一次 OnControl**。
--     这是「按住挖掘键持续挖掘」的第二种实现（第一种是 RepeatHeldAction）。
--   ⇒ 为什么需要两种：3101 行是「玩家在动作间隙还按着键」，
--     2588 行是「长按超过 0.27 秒后自动连发」。两者的时间尺度不同。
--   ⚠ 3104 行的 `not self:IsDoingOrWorking()`：控制器 X 键只在完全空闲时重放，
--     而 CONTROL_ACTION（3101 行）无条件重放。两者条件不对称。
            if TheInput:IsControlPressed(CONTROL_ACTION) then
                self:OnControl(CONTROL_ACTION, true)
            elseif TheInput:IsControlPressed(CONTROL_CONTROLLER_ACTION)
                and not self:IsDoingOrWorking() then
                self:OnControl(CONTROL_CONTROLLER_ACTION, true)
            end
        end
    end

--★★★ 【连击攻击的延迟触发】3110-3168 行。
--   这是「连击」的第二半（前半在 1396/1941 的 chainattack_cb 设置）。
--   3110 行守卫：服务端 + 非本机玩家 + **不是本地连击**（localchainattack）。
--   ★ `self.inst.sg.mem.localchainattack` 来自 SGwilson.lua:1319，
--     语义：本次攻击是 forced（玩家主动指定目标）则为 nil，
--     非 forced（自动索敌）则为 true → 「本地连击」意味着是玩家自己安排的连击。
    if self.ismastersim and self.handler == nil and not self.inst.sg.mem.localchainattack then
        if self.inst.sg.statemem.chainattack_cb ~= nil then
--   3112 行：正在施法（CASTAOE）时清掉连击回调 —— 施法期间不该被打断。
            if self.locomotor ~= nil and self.locomotor.bufferedaction ~= nil and self.locomotor.bufferedaction.action == ACTIONS.CASTAOE then
                self.inst.sg.statemem.chainattack_cb = nil
--   ★★ 3114 行又是那个 abouttoattack/attack 三元表达式（第三处）。
--   3116-3118 行：取出回调、置空、执行。
--   ★ 为什么要有 3114 行的守卫：回调可能在攻击状态**内部**被设入，
--     若立刻执行会打断当前攻击动画。必须等状态离开攻击态才触发。
			elseif not self.inst.sg:HasStateTag(self.remote_authority and self.remote_predicting and "abouttoattack" or "attack") then
                --Handles chain attack commands received at irregular intervals
                local fn = self.inst.sg.statemem.chainattack_cb
                self.inst.sg.statemem.chainattack_cb = nil
                fn()
            end
        end
--★★ 3121-3168 行：客户端（以及服务端非 handler 路径）的「按住攻击持续攻击」。
--   守卫三重：非 directwalking、非 isbusy、不在施法中。
    elseif (self.ismastersim or self.handler ~= nil)
        and not (self.directwalking or isbusy)
        and not (self.locomotor ~= nil and self.locomotor.bufferedaction ~= nil and self.locomotor.bufferedaction.action == ACTIONS.CASTAOE) then
--   ★★ 3127-3131 行：判定「能否开始新攻击」——
--     没有攻击状态，或「正在打的人」与「想打的人」不同（= 可以重定向）。
--   ⇒ 这就是「连击换目标」的实现：打 A 时按住扳机走到 B 旁边会自动转火。
        local attack_control = false
        local currenttarget = self:GetCombatTarget()
        local retarget = self:GetCombatRetarget()
        if self.inst.sg ~= nil then
            attack_control = not self.inst.sg:HasStateTag("attack") or currenttarget ~= retarget
        else
            attack_control = not self.inst:HasTag("attack")
        end
        if attack_control then
--   --@V2C: #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK (see frontend.lua)
--   ★★★ 一条重要的修复记录：UI 消费了左键点击，但**按下瞬间**的攻击被触发。
--   3134 行的修复：`attack_control = (self.handler == nil or not IsPaused()) and ...`
--     ⇒ 客户端在**暂停中**不触发左键自动攻击。
--   原因：暂停菜单弹出时，玩家之前按住的左键仍被记为 pressed，
--     导致一进暂停菜单就打人。参见报告 04 号文档 2744 行的分析。
			--@V2C: #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK (see frontend.lua)
            attack_control = (self.handler == nil or not IsPaused())
--   ★★ 3135-3137 行：三键的自动攻击映射。
--     `(IsControlPressed(A) and A) or (IsControlPressed(B) and B) or ... or nil`
--   ⇒ 优先级：CONTROL_ATTACK > CONTROL_PRIMARY > CONTROL_CONTROLLER_ATTACK。
--     这与 1893 行 DoAttackButton 的 control 选择**恰好相反**（那里 leftmouse 优先）。
--   ⚠ 疑似缺陷（优先级不一致）：
--     1893 行 `local control = isleftmouse and CONTROL_PRIMARY or CONTROL_ATTACK`
--     3135 行 `IsControlPressed(CONTROL_ATTACK) and CONTROL_ATTACK or
--                  IsControlPressed(CONTROL_PRIMARY) and CONTROL_PRIMARY`
--     两者在「两个键同时按住」时会选到不同的 control，
--     导致 remote_controls 里被置 0 的键不同 → 服务端状态不一致。
--     推理依据：1893 行优先 PRIMARY，3135 行优先 ATTACK。
                and ((self:IsControlPressed(CONTROL_ATTACK) and CONTROL_ATTACK) or
                    (self:IsControlPressed(CONTROL_PRIMARY) and CONTROL_PRIMARY) or
                    (self:IsControlPressed(CONTROL_CONTROLLER_ATTACK) and not self:IsAOETargeting() and CONTROL_CONTROLLER_ATTACK))
                or nil
--   3139 行 `if attack_control ~= nil`：没有任何攻击键按住 → 跳过整段。
            if attack_control ~= nil then
--★ 「链式攻击」（chain attack）的核心分支。
--   3140 行：存在有效 retarget（玩家指定过目标）且它还活着可见。
--   ⚠ 3144 行 `self:GetAttackTarget(false, retarget, retarget ~= currenttarget)`
--     第二个参数 retarget 被当作 force_target 传入，返回值可能是 nil。
--     3145-3147 行的 nil 检查是必要的。
                if retarget and not IsEntityDead(retarget) and CanEntitySeeTarget(self.inst, retarget) then
                    --Handle chain attacking
                    if self.inst.sg ~= nil then
--   ★★ 3143 行 `if self.handler == nil`：服务端直接 PushAction（不重定向）。
--     服务端已经知道 target（RPC 带过来的），直接执行。
                        if self.handler == nil then
                            retarget = self:GetAttackTarget(false, retarget, retarget ~= currenttarget)
                            if retarget ~= nil then
                                self.locomotor:PushAction(BufferedAction(self.inst, retarget, ACTIONS.ATTACK), true)
                            end
--   3148 行 `attack_control ~= CONTROL_CONTROLLER_ATTACK`：
--     手柄攻击 → 3151 行的 DoControllerAttackButton(retarget)。
--   ⚠ 3148 行的 elseif 在 3143 行的 `if self.handler == nil` 之内，
--     所以 3151 行只在 handler ~= nil（本机客户端）时可达。
                        elseif attack_control ~= CONTROL_CONTROLLER_ATTACK then
							self:DoAttackButton(retarget, attack_control == CONTROL_PRIMARY)
                        else
                            self:DoControllerAttackButton(retarget)
                        end
                    end
--★★ 3154 行 `elseif attack_control ~= CONTROL_PRIMARY and self.handler ~= nil`：
--   「开始一次新攻击」的条件。排除 PRIMARY（左键点击交给 4680 行 OnLeftClick），
--   也排除服务端。
--   ⚠ 疑似缺陷（语义不对称）：
--   ⇒ 与 3140-3152 行的「链式攻击」分支对照：那里 3149 行
--     `self:DoAttackButton(retarget, attack_control == CONTROL_PRIMARY)`
--     **允许** isleftmouse=true（3148 行只排除 CONTROLLER_ATTACK）。
--     所以：按住左键 + 已有 retarget → 走 3149 行；
--           按住左键 + 无 retarget → 被 3154 行拦住，什么都不做。
--   ⚠ 也就是说「左键按住自动攻击」只在「已有一个攻击目标」时生效。
--     结合 3133 行的 #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK 修复，
--     这个不对称很可能是那次修复的无意副作用，而非有意设计。
--     推理依据：3135-3137 行把 CONTROL_PRIMARY 列为候选，
--       但 3154 行的条件让它在无 retarget 时永远走不到 DoAttackButton。
--     缓解：3149 行可达时 isleftmouse 会正确为 true，故不会误伤。
                elseif attack_control ~= CONTROL_PRIMARY and self.handler ~= nil then
--   「开始新攻击」还需满足 isidle（3158-3160 的双端兜底）。
                    --Check for starting a new attack
                    local isidle
                    if self.inst.sg ~= nil then
                        isidle = self.inst.sg:HasStateTag("idle") or (self.inst:HasTag("idle") and self.inst:HasTag("nopredict"))
                    else
                        isidle = self.inst:HasTag("idle")
                    end
                    if isidle then
--   ★ 3163 行 `self:OnControl(attack_control, true)`：
--     **复用 OnControl** 手动重放一次按键，而不是直接调 DoAttackButton。
--     ⇒ 保证客户端与服务端走完全相同的代码路径（3101-3106 行的同款技巧）。
                        self:OnControl(attack_control, true)
                    end
                end
            end
        end
    end

--   ★ 手柄热插拔检测：TryRecacheController 为真 → 重发 continuefrompause。
--   3171-3172 行注释解释：不能 PushScreen（会卡住），所以发事件。
    if self.handler ~= nil and TheInput:TryRecacheController() then
        --Could also push pause screen, but it won't come up right
        --away if controls were disabled at the time of the switch
        TheWorld:PushEvent("continuefrompause")
        TheInput:EnableMouse(not TheInput:ControllerAttached())
    end
end

--★★ 【CheckControllerPriorityTagOrOverride】手柄目标优先级的「可覆盖」查询。
--   override 是函数或值 → FunctionOrValue 求值；nil → 查标签。
--   ★ 这是模组的第三个扩展点（前两个是 actionbuttonoverride 与 client_forward）。
--     实体通过 `controller_priority_override_is_epic` 等字段声明自己的优先级，
--     不需要改本文件。
--   ⚠ 3269/3271/3275 行的三个字段（is_epic / is_monster / is_targeting_player）
--     都是**实体上的裸字段**（不是组件方法），grep 确认由 prefab 直接赋值。
local function CheckControllerPriorityTagOrOverride(target, tag, override)
	if override ~= nil then
--============================================================
-- 【第六段】3180-3700 行：★ 手柄目标选择（打分排序）与目标锁定
--============================================================
		return FunctionOrValue(override)
	end
	return target:HasTag(tag)
end

--★★★ 【UpdateControllerAttackTarget】★ **手柄「X 键」目标选择：几何 + 打分**。
--   每帧由 UpdateControllerTargets:3620 调用（仅手柄模式）。
--   与鼠标的 GetAttackTarget（1790 行）的根本差异：
--     · 鼠标：枚举范围内所有候选，选「最近的合法目标」
--     · 手柄：枚举范围内所有候选，算**分数**后选最高的
--   ⇒ 手柄可以用「方向 + 优先级」瞄准，鼠标只能点最近的。这是手柄体验的核心。
local function UpdateControllerAttackTarget(self, dt, x, y, z, dirx, dirz)
	local inventory = self.inst.replica.inventory
--   ★ 三种「不能瞄准」的情况：举重物 / 举漂浮物 / 幽灵。
--   3192 行连带关闭目标锁定 —— 因为无目标时锁定无意义。
	if inventory:IsHeavyLifting() or inventory:IsFloaterHeld() or self.inst:HasTag("playerghost") then
        self.controller_attack_target = nil
        self.controller_attack_target_ally_cd = nil

		-- we can't target right now; disable target locking
		self.controller_targeting_lock_target = false
        return
    end

    local combat = self.inst.replica.combat

--   ★★ 友方目标冷却倒计时。初值 nil → 3198 行用 `(nil or 1) - dt` 变成 1 秒。
--   ⇒ 设计：切换到非友方目标时 3355-3358 行把它清回 nil，下一帧又从 1 秒开始。
--     效果是「每次切换目标后，有 1 秒的友方降权期」。
    self.controller_attack_target_ally_cd = math.max(0, (self.controller_attack_target_ally_cd or 1) - dt)

--   ★ 3200-3208 行：当前目标失效 → 清空 + 关闭锁定。
--   3207 行注释 "it went invalid, but we're not resetting the age yet" ——
--     ★ 刻意不重置年龄：age 保持很大值，让 3381 行的 0.2 秒防抖立即通过。
--     ⇒ 目的：目标失效后要**立刻**重新选，而不是等 0.2 秒。
    if self.controller_attack_target ~= nil and
        not (combat:CanTarget(self.controller_attack_target) and
            CanEntitySeeTarget(self.inst, self.controller_attack_target)) then
        self.controller_attack_target = nil

		-- target is no longer valid; disable target locking
		self.controller_targeting_lock_target = false
        --it went invalid, but we're not resetting the age yet
    end

--   3210-3214 行注释掉的 controller_attack_target_age 防抖代码。
--   ⚠ 与 controller_target_age（120 行仍在用）的对比说明：
--     攻击目标**放弃**了防抖，交互目标保留了。
--   推理依据：120 行 `self.controller_target_age = math.huge` 仍在构造函数里；
--     3207 行的注释「not resetting the age yet」证明攻击目标没有 age 字段了。
    --self.controller_attack_target_age = self.controller_attack_target_age + dt
    --if self.controller_attack_target_age < .3 then
        --prevent target flickering
    --    return
    --end

--★ 【3217-3221 攻击半径的三档】交互范围判定的核心。
--   forced_rad：物品自带的 controller_use_attack_distance（如长矛的额外长度）。
--   min_rad = 3：★ 不需要瞄准就能打的最小半径（身后也能打）
--   max_rad = max(forced_rad, 武器射程) + 3.5
--   ⇒ +3.5 的余量是为了容纳目标的物理半径（3264 行才减去）。
--   ⚠ 3219 行的 min_rad=3 与 3436 行交互目标的 min_rad=1.5 不同：
--     攻击需要更大的「无瞄准区」，因为误伤代价高。
	local equipped_item = inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
    local forced_rad = equipped_item ~= nil and equipped_item.controller_use_attack_distance or 0

	local min_rad = 3
	local max_rad = math.max(forced_rad, combat:GetAttackRangeWithWeapon()) + 3.5
    local max_rad_sq = max_rad * max_rad

    --see entity_replica.lua for "_combat" tag

--   ★ 3225 行用 RegisterFindTags 的版本（排除 stealth 等，2082 行注册）。
--   3226-3230 行：把当前目标**强行插到列表首位**（3229 行），
--     保证它被优先处理（3244 行用 `(v ~= self.controller_attack_target or i == 1)`
--     保证它只被处理一次）。
	local nearby_ents = TheSim:FindEntities_Registered(x, y, z, max_rad + 3, REGISTERED_CONTROLLER_ATTACK_TARGET_TAGS)
    if self.controller_attack_target ~= nil then
        --Note: it may already contain controller_attack_target,
        --      so make sure to handle it only once later
        table.insert(nearby_ents, 1, self.controller_attack_target)
    end

    local target = nil
    local target_score = 0
    local target_isally = true
--   ★★ preferred_target 的三级优先：
--     ① 扳机按着时的当前目标（最优先：玩家明确表达过意图）
--     ② combat:GetTarget()（战斗系统认为的目标）
--     ③ 无
--   3279 行给它 ×10 分（最大的单项加权）。
    local preferred_target =
        TheInput:IsControlPressed(CONTROL_CONTROLLER_ATTACK) and
        self.controller_attack_target or
        combat:GetTarget() or
        nil

	local current_controller_targeting_targets = {}
	local selected_target_index = 0
    for i, v in ipairs(nearby_ents) do
--   ★★ 3244 行的 `(v ~= self.controller_attack_target or i == 1)`：
--     跳过重复出现的当前目标（因为 3229 行插入了一份，FindEntities 也返回了一份）。
--     i==1 保证插入的那份能被处理。
--   ⇒ 经典的空间查询去重技巧：手动插入已选目标后必须去重。
        if v ~= self.inst and (v ~= self.controller_attack_target or i == 1) then
            local isally = combat:IsAlly(v)
--   ★★ 友方降权守卫：`(isally and ally_cd > 0 and v ~= preferred_target)`。
--     三个条件同时满足才排除 —— 冷却期内友方几乎不可被选中。
--     但 preferred_target（玩家明确指的）豁免。
            if not (isally and
                    self.controller_attack_target_ally_cd > 0 and
                    v ~= preferred_target) and
--   combat:CanTarget(v) —— 目标是否合法（未死/未被独占）。
                combat:CanTarget(v) then
                --Check distance including y value
--★ 【3251-3253 行：攻击索敌计入 y 轴】
--   ★ 与 3479 行的交互索敌（**只算 xz**）形成鲜明对比。
--   为什么攻击要算 y：可以打到**下方一层**的目标（站在悬崖边打下面的敌人）。
--   为什么交互不算 y：站在二楼不该能「交互」一楼的东西。
--   ⚠ 但 3502-3505 行的交互索敌在通过半径测试**之后**又补加了 dy² ——
--     用它做平局时的 tiebreaker（见该处注释）。这个折衷很微妙。
                local x1, y1, z1 = v.Transform:GetWorldPosition()
                local dx, dy, dz = x1 - x, y1 - y, z1 - z
                local dsq = dx * dx + dy * dy + dz * dz

				--include physics radius for max range check since we don't have (dist - phys_rad) yet
--   --include physics radius for max range check since we don't have
--   (dist - phys_rad) yet
--   ★ 两段式距离判定：先用「中心距 + 物理半径」判可达，
--     再用「中心距 - 物理半径」算分（3264 行）。
--   ⇒ 这样既保证「体型大的目标在边缘也算命中」，又能给近处大目标高分。
				local phys_rad = v:GetPhysicsRadius(0)
				local max_range = max_rad + phys_rad

				if dsq < max_range * max_range and CanEntitySeePoint(self.inst, x1, y1, z1) then
                    local dist = dsq > 0 and math.sqrt(dsq) or 0
                    local dot = dist > 0 and dx / dist * dirx + dz / dist * dirz or 0
--★ 【3262 行：扇形/近距混合判据】`if dot > 0 or dist < min_rad + phys_rad`。
--   dot > 0 = 在玩家朝向的**半球**内（朝向优先）；
--   dist < min_rad + phys_rad = 就在脚边，无论朝向都可选。
--   ⇒ 手柄体验的关键：准星可以指哪打哪，但脚边的东西不会漏掉。
--   ⚠ dot 是**二维**的（3258/3261 行只用 dx/dz），未计入 y。
--     所以站在高处时，朝向判定会把低处目标也算作「前方」。
					if dot > 0 or dist < min_rad + phys_rad then
						--now calculate score with physics radius subtracted
						dist = math.max(0, dist - phys_rad)
--★★★ 【打分公式】`local score = dot + 1 - 0.5 * dist * dist / max_rad_sq`
--   拆解：
--     dot          ∈ [-1, 1]  朝向吻合度（正前方 = 1，背对 = -1）
--     + 1          → 把 dot 平移到 [0, 2]，保证 score 起点为正
--     - 0.5*d²/R²  → 距离惩罚。系数 0.5 意味着「最远处扣 0.5 分」，
--                    而朝向差 180° 扣 2 分 ⇒ ★**朝向权重是距离的 4 倍**。
--   ⇒ 设计意图：手柄瞄准时，玩家「指哪」比「近在哪」重要得多。
--     副作用：正前方远处 (dot=1, d=R) 得 1.5 分；
--            紧贴身后 (dot=-1, d=0) 得 0 分 → 会被前者压过。
						local score = dot + 1 - 0.5 * dist * dist / max_rad_sq

--   ★★★ 四级倍率（3245-3273）：优先级标签乘在基础分上。
--     · 友方（除非 override）      × 0.25
--     · epic（BOSS）               × 5
--     · monster（普通怪）           × 4
--     · 正在攻击玩家                × 6
--     · preferred_target            × 10（3279 行）
--   ⇒ 「正在攻击我」比「BOSS」还高 —— 生存优先于威胁等级。
--   ⚠ 倍率是**连乘**的：epic + 正在攻击我 = 30 倍。
--     这在数学上没问题（仍是单调），但调参时难以直观预期。
                        if isally and not v.controller_priority_override_is_ally then
                            score = score * .25
						elseif CheckControllerPriorityTagOrOverride(v, "epic", v.controller_priority_override_is_epic) then
                            score = score * 5
						elseif CheckControllerPriorityTagOrOverride(v, "monster", v.controller_priority_override_is_monster) then
                            score = score * 4
						end

--   ★ 3275 行：目标正在打玩家 → ×6。这是「自保」优先级的来源。
						if v.replica.combat:GetTarget() == self.inst or FunctionOrValue(v.controller_priority_override_is_targeting_player) then
                            score = score * 6
                        end

                        if v == preferred_target then
                            score = score * 10
                        end

--   ★ 3283 行把**所有通过筛选的实体**都塞进 current_controller_targeting_targets，
--     不只是最高分的那个。
--   ⇒ 这就是目标锁定功能的数据源：锁定后列表被冻结，可用方向键循环。
						table.insert(current_controller_targeting_targets, v)
                        if score > target_score then
							selected_target_index = #current_controller_targeting_targets
                            target = v
                            target_score = score
                            target_isally = isally
                        end
                    end
                end
            end
        end
    end

--★★★ 【3296-3327 目标锁定分支】★ 锁定时不更新目标，只维护列表。
--   ★ 三步走：
--     ① 3300-3317 行：把「不在附近实体列表里」的旧目标**移除**
--     ② 3319-3323 行：把新出现的实体**加入**列表
--     ③ 3326 行：直接 return，**不修改** controller_attack_target
--   ⇒ 锁定的语义：「冻结当前目标，但保持候选列表新鲜」，
--     玩家可以用方向键在列表里循环而不丢失候选。
--   ⚠ 疑似缺陷（循环内修改被遍历表）：
--     3300 行 `for idx_outer = #self.controller_targeting_targets, 1, -1 do`
--     内层 3307 行 table.remove 的是 **current_controller_targeting_targets**（安全），
--     3315 行 table.remove 的是 **self.controller_targeting_targets** ——
--     ★★ 这是在**倒序**循环中删除自身元素，倒序保证安全（删 idx_outer 后
--       前面的元素索引不变）。故实际正确，但极易被后来者改成正序而引入 bug。
--     推理依据：倒序遍历 + table.remove 是安全模式；正序则会跳过元素。
	if self.controller_attack_target ~= nil and self.controller_targeting_lock_target then
--★★ 【3296-3327 目标锁定分支的完整语义】
--   ★ 这是本文件里唯一「冻结选择但维持候选池」的数据结构维护逻辑。
--   ⭐ 三个关键设计决策：
--     ① 3229 行把当前目标插到候选列表首位 —— 保证它在任何位置都能被找到
--     ② 3283 行把**所有**合法候选都记进临时表 —— 供锁定时的 diff
--     ③ 3326 行直接 return —— 不改 controller_attack_target
--   ⇒ 净效果：锁定期间，玩家按方向键在候选池里滚动，
--     而候选池会随敌人进出而增删（3300-3323 行）。
--   ⚠ 复杂度警示：这段用了三张表（附近实体、当前候选、锁定候选），
--     O(n²) 的双层循环（3300-3311 行），且 table.remove 在循环内。
--     n 通常 < 10（附近能打的怪），可接受；但若模组让半径内实体暴增，
--     这段会成为每帧热点。
		-- we have a target and target locking is enabled so only update the list of valid targets, ie. check for targets that have appeared or disappeared

		-- first check if any targets should be removed
--★ 3300-3317 行：从锁定候选里**移除**已消失的目标（倒序遍历）。
--   ★ 3304-3309 行：先在「当前合法候选」里找它，找到就把它从当前表里删掉。
--     英文原注释："we found the existing target in the list of current nearby
--     entities so remove it from the current entity list to make later addition
--     of new entities more straightforward" ——
--     ★ 这是**减少后续工作量**的优化：不在锁定池里的，就不用再比对。
--   ⚠ 性能反例：若某个目标反复出现/消失，每帧都要全表扫描。
		for idx_outer = #self.controller_targeting_targets, 1, -1 do
			local found = false
			local existing_target = self.controller_targeting_targets[idx_outer]
			for idx_inner = #current_controller_targeting_targets, 1, -1 do
				if existing_target == current_controller_targeting_targets[idx_inner] then
					-- we found the existing target in the list of current nearby entities so remove it from the current entity list to
					-- make later addition of new entities more straightforward
					table.remove(current_controller_targeting_targets, idx_inner)
					found = true
					break
				end
			end

			-- if the existing target isn't found in the nearby entities then remove it from the targets
			if not found then
				table.remove(self.controller_targeting_targets, idx_outer)
			end
		end

--★ 3319-3323 行：把「本帧新出现」的候选加入锁定池。
--   ★ 此时 current_controller_targeting_targets 里只剩**真正新增**的（因为
--     3307 行已把已存在的移除了）。⇒ 可以无脑全量 insert。
		-- now add new targets; check everything left in the nearby_ents table as we've been
		-- removing existing targets from it as we checked for targets that were no longer valid
		for i, v in ipairs(current_controller_targeting_targets) do
			table.insert(self.controller_targeting_targets, v)
		end

		-- fin
--   -- fin
--★ 3326 行的 return 是本分支的终点：锁定期间**不改**当前目标。
--   ⇒ 3351 行的 controller_targeting_target_index 在锁定期间**不更新**。
--   ⚠ 但 3673 行的 CycleControllerAttackTargetForward 依赖它做循环起点。
--   ⚠⚠ 疑似缺陷（索引漂移）：
--     玩家锁定 → 敌人进出 → 玩家按循环键，索引可能指向一个语义不同的位置。
--     推理依据：3351 行的赋值在 3326 行的 return 之后，锁定时不执行；
--       而 3322 行 table.insert 会改变 controller_targeting_targets 的顺序。
--     缓解：3674 行 `if index > num_targets then index = 1 end` 只会夹到范围内，
--       所以不会崩溃，但「循环顺序」可能与预期不符。
		return
	end

--★★ 3329-3347 行：礼物的特例修正。
--   if giftmachine 有 (Y) 优先级 → 它也压过墙（target = nil）。
--   注释："if giftmachine has (Y) control priority, then it should also have
--   (X) control priority over walls"
--   ⚠ 硬编码墙与礼物机的标签对（IsControllerTargetLocked 之外的一个特例），
--     与 3585 行的 mermthrone/crabking 属同一类「在通用代码里写角色特例」。
    if self.controller_target ~= nil and self.controller_target:IsValid() then
        if target ~= nil then
            if target:HasTag("wall") and
                self.classified ~= nil and
                self.classified.hasgift:value() and
                self.classified.hasgiftmachine:value() and
                self.controller_target:HasTag("giftmachine") then
                --if giftmachine has (Y) control priority, then it
                --should also have (X) control priority over walls
                target = nil
                target_isally = true
            end
--   3341 行：没有 (X) 目标但 (Y) 目标是墙 → 把墙给 (X) 键。
--   注释："if we have no (X) control target, then give it to our (Y) control
--   target if it's a wall" —— 墙没有攻击价值，把两个键合并到它上面。
        elseif self.controller_target:HasTag("wall") and not IsEntityDead(self.controller_target, true) then
            --if we have no (X) control target, then give
            --it to our (Y) control target if it's a wall
            target = self.controller_target
            target_isally = false
        end
    end

--   ★ 3349-3353 行：目标变化时才更新 controller_targeting_target_index。
--   ⚠ 3351 行 `self.controller_targeting_target_index = selected_target_index`：
--     selected_target_index 是 **current_controller_targeting_targets 的下标**，
--     但 3673 行的 CycleControllerAttackTargetForward 用它索引
--     **self.controller_targeting_targets**。两个不同的表！
--   ⚠⚠ 疑似缺陷（索引表错配）：
--     非锁定状态下 3326 行的 return 不会执行，3329-3353 正常运行，
--       此时 current_controller_targeting_targets 是**每帧新建的临时表**（3241 行），
--       而 self.controller_targeting_targets 只在锁定分支（3322 行）被填充。
--     ⇒ 在「刚开启锁定但还没跑过一次锁定分支」的窗口内，
--       selected_target_index 可能指向一个与 controller_targeting_targets 无关的下标。
--     缓解：ControllerTargetLock(true) 要求已有 controller_attack_target（3653 行），
--       且 3672 行循环前会检查 num_targets > 0，越界会被 3674 行夹回 1。
--     ⇒ 实际后果是「第一次按循环键可能跳到列表第一个」而非崩溃。
--     推理依据：3241 行 local current_controller_targeting_targets = {} 是局部表；
--       3283 行 table.insert 到的是局部表；只有 3322 行才 insert 到成员表。
    if target ~= self.controller_attack_target then
        self.controller_attack_target = target
		self.controller_targeting_target_index = selected_target_index
        --self.controller_attack_target_age = 0
    end

--   ★ 非友方目标 → 友方冷却清零（3357 行置 nil，下一帧变成 1 秒）。
    if not target_isally then
        --reset ally targeting cooldown
        self.controller_attack_target_ally_cd = nil
    end
end

--★★★ 【UpdateControllerInteractionTarget】★ **手柄「Y 键」目标选择（交互）**。
--   268 行，比攻击索敌长 90 行，因为交互的候选类型更多（见 3386-3446 的优先级段）。
--   与攻击索敌的另一大差异：★ 有**显式的优先级段**（早返回），
--     而攻击索敌是纯打分。
local function UpdateControllerInteractionTarget(self, dt, x, y, z, dirx, dirz, heading_angle)
	local attack_target = self:GetControllerAttackTarget()
--   ★ 锁定状态且有攻击目标 → 交互目标直接跟随攻击目标。
--     ⇒ 锁定的语义是「两个键绑定同一个目标」。
	if self.controller_targeting_lock_target and attack_target then
		self.controller_target = attack_target
		return
--   ★ 放置/施法态 → 强制无目标（3367-3368 行还会重置 age）。
--     建造预览时不该高亮任何可交互物。
	elseif self.placer ~= nil or (self.deployplacer ~= nil and self.deploy_mode) or self.inst:HasTag("usingmagiciantool") then
        self.controller_target = nil
        self.controller_target_age = 0
        return
--   ★ 3370-3377 行：当前目标失效的四重检查。
--   3375 行的注释解释为什么跳过 FX/DECOR（同 2106 行）。
    elseif self.controller_target ~= nil
        and (not self.controller_target:IsValid() or
            self.controller_target:HasTag("INLIMBO") or
            self.controller_target:HasTag("NOCLICK") or
            not CanEntitySeeTarget(self.inst, self.controller_target)) then
        --"FX" and "DECOR" tag should never change, should be safe to skip that check
        self.controller_target = nil
        --it went invalid, but we're not resetting the age yet
    end

--★★ 3381 行的 `if self.controller_target_age < .2 then return end`：
--   ★★ 手柄目标防抖。目标变化时 age 归零（3392/3403/3424/3573 行），
--     0.2 秒内冻结不再重选。
--   ⇒ 效果：瞄准在两个候选边缘时，「粘住」上一个 0.2 秒，不会抽搐。
--   ⚠ 副作用：玩家**故意**快速切换目标时会觉得「粘手」，需要等 0.2 秒。
--     这是「稳定性 vs 响应性」的经典取舍，DST 选了稳定。
    self.controller_target_age = self.controller_target_age + dt
    if self.controller_target_age < .2 then
        --prevent target flickering
        return
    end

--★★ 【3386-3446 显式优先级段】按顺序：
--   ① 3387 CATCH（能抓就抓）
--   ② 3400 物品要求用攻击目标（controller_should_use_attack_target）
--   ③ 3409 铲除草皮（terraformerremoveable）—— ★「Turf entity removal always
--      highest priority」
--   ④ 3431 钓鱼（放大小搜索半径）
--   ⑤ 3434 永不选自己的鱼钩
--   ★★ 注意 3414 行的特殊查询：`TheSim:GetEntitiesAtScreenPoint(
--     TheSim:GetScreenPos(x, y, z))` —— 用**玩家自己所在屏幕位置**做查询，
--     因为草皮视觉体的原点离实际网格很远（3420-3421 行注释）。
--   ⚠ 这个特例在 5422-5430 行的 GetGroundUseAction 里被**完整复制了一遍**。
--     推理依据：两处的注释文字几乎一字不差。代码重复，改一处会漏另一处。
    --catching
    if self.inst:HasTag("cancatch") then
        local target = FindEntity(self.inst, 10, nil, CATCHABLE_TAGS, TARGET_EXCLUDE_TAGS)
        if CanEntitySeeTarget(self.inst, target) then
            if target ~= self.controller_target then
                self.controller_target = target
                self.controller_target_age = 0
            end
            return
        end
    end

--   equipped_item：★ 注意变量名拼写错误（equiped 少一个 p），全文件一致。
    local equiped_item = self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)

--   ★ controller_should_use_attack_target：物品要求「用攻击键而不是交互键」。
--     例：某些工具只能通过攻击键对敌使用。此时 (Y) 跟随 (X)。
    if equiped_item and equiped_item.controller_should_use_attack_target and self.controller_attack_target ~= nil then
        if self.controller_target ~= self.controller_attack_target then
            self.controller_target = self.controller_attack_target
            self.controller_target_age = 0
        end
        return
    end

    -- Turf entity removal always highest priority.
    if equiped_item and equiped_item:HasActionComponent("terraformer") then
        -- Special case for ACTIONS.TERRAFORM_REMOVE via placed turf visuals needing to take highest priority over all other checks due to increased range from entity origin.
        -- We will use the player's origin to find things with the tag to use the action.
--   -- Special case for ACTIONS.TERRAFORM_REMOVE via placed turf visuals needing
--   to take highest priority over all other checks due to increased range from
--   entity origin.
--   -- We will use the player's origin to find things with the tag to use the action.
--   ★★ 英文注释说清了原因：草皮的**视觉体**原点离它的实际位置很远
--     （视觉体挂在网格上，原点在中心），所以用常规距离判定会漏掉脚下的草皮。
        local x, y, z = self.inst.Transform:GetWorldPosition()
        local terraform_remove_target = nil
        local ents = TheSim:GetEntitiesAtScreenPoint(TheSim:GetScreenPos(x, y, z))
        for _, ent in ipairs(ents) do
            if ent:HasTag("terraformerremoveable") then
                terraform_remove_target = ent
                break
            end
        end
        if terraform_remove_target then
            if terraform_remove_target ~= self.controller_target then
                self.controller_target = terraform_remove_target
                self.controller_target_age = 0
            end
            return
        end
    end

    --Fishing targets may have large radius, making it hard to target with normal priority
--   --Fishing targets may have large radius, making it hard to target with normal priority
--   ★ 钓鱼时**无视当前目标**强制用最大半径搜索（鱼群范围大）。
    local fishing = equiped_item ~= nil and equiped_item:HasTag("fishingrod")

--   -- we want to never target our fishing hook, but others can
--   ★ 自己的鱼钩永不成为 (Y) 目标（会自我循环），但队友的可以（帮他收线）。
    -- we want to never target our fishing hook, but others can
    local ocean_fishing_target = (equiped_item ~= nil and equiped_item.replica.oceanfishingrod ~= nil) and equiped_item.replica.oceanfishingrod:GetTarget() or nil

--   ★★ 交互半径：min_rad = 1.5 / max_rad = 6。
--   与攻击的 3 / max_rad+3.5 完全不同：交互需要**更大的近距离容忍**
--   （1.5 vs 3）但**更小的最大距离**（6 vs 攻击的 ~6.5）。
--   ⇒ 交互刻意做成「贴身且短距」，避免误选远处物体。
    local min_rad = 1.5
    local max_rad = 6
    local min_rad_sq = min_rad * min_rad
    local max_rad_sq = max_rad * max_rad

--★★ 3441-3445 行：**迟滞半径（sticky radius）**。
--   rad = 有当前目标 ? clamp(当前距离, min_rad, max_rad) : max_rad。
--   ⇒★ 核心效果：当前目标在 1.5~6 之间时用**它自己的距离**作搜索半径，
--     且加了 .1 的浮点余量（3445 行）。
--   ⇒ 这实现了「目标锁定在范围内时不因轻微移动而丢失」。
--   3520 行的 mult = 1.5 是这个机制的第二半（分数加成）。
--   ⇒★★ 两处配合：半径不缩小（保目标）+ 分数放大（优先选它）。
    local rad =
            self.controller_target ~= nil and
            math.max(min_rad, math.min(max_rad, math.sqrt(self.inst:GetDistanceSqToInst(self.controller_target)))) or
            max_rad
    local rad_sq = rad * rad + .1 --allow small error

--   TheSim:FindEntities 用 TARGET_EXCLUDE_TAGS（2081 行），非注册版。
--   ⚠ 与攻击索敌用 RegisterFindTags 版本不同 —— 这里每帧走一次完整查询。
--     性能影响：手柄每帧最多 1 次（攻击 + 交互各 1 次）。可接受。
    local nearby_ents = TheSim:FindEntities(x, y, z, fishing and max_rad or rad, nil, TARGET_EXCLUDE_TAGS)
    if self.controller_target ~= nil then
        --Note: it may already contain controller_target,
        --      so make sure to handle it only once later
        table.insert(nearby_ents, 1, self.controller_target)
    end

    local target = nil
    local target_score = 0
--★ canexamine 的四重判据（与 2361-2364 行的 GetInspectButtonAction 完全同型）。
--   3457 行的 `self.inst.HUD:IsPlayerAvatarPopUpOpen()` 没有 HUD nil 检查。
--   ⚠ 疑似缺陷（nil 索引风险）：3457 行 `self.inst.HUD:...` 直接索引。
--     缓解：UpdateControllerTargets 只在 handler ~= nil 时被调用（2821 行），
--       而 handler ~= nil 意味着是本机玩家，HUD 必然存在。
--     推理依据：2821 行的 `if self.handler ~= nil then` 包裹。
--   ⚠ 与 3458 行的 `self.inst.sg == nil or ...` 对比，3457 行是唯一没做双端兜底的。
    local canexamine = (self.inst.CanExamine == nil or self.inst:CanExamine())
				and (not self.inst.HUD:IsPlayerAvatarPopUpOpen())
				and (self.inst.sg == nil or self.inst.sg:HasStateTag("moving") or self.inst.sg:HasStateTag("idle") or self.inst.sg:HasStateTag("channeling"))
				and (self.inst:HasTag("moving") or self.inst:HasTag("idle") or self.inst:HasTag("channeling"))

--   ★★ currentboat / anglemax：**站在船上时交互角度放宽**。
--   TUNING.CONTROLLER_BOATINTERACT_ANGLE vs TUNING.CONTROLLER_INTERACT_ANGLE。
--   ⇒ 为什么：船在晃，站在船上瞄准时手柄视角相对船是偏的，
--     若用陆地的严格角度会频繁选错。
    local currentboat = self.inst:GetCurrentPlatform()
    local anglemax = currentboat and TUNING.CONTROLLER_BOATINTERACT_ANGLE or TUNING.CONTROLLER_INTERACT_ANGLE
    for i, v in ipairs(nearby_ents) do
--   ★ v = v.client_forward_target or v —— 与 2264 行完全相同（第二次出现）。
--   ⚠ 两处必须同步修改，否则鼠标与手柄的转发行为分叉。
		v = v.client_forward_target or v

--   排除自己的鱼钩（3434 行算出）。
        if v ~= ocean_fishing_target then

            --Only handle controller_target if it's the one we added at the front
--   ★★ 3469 行三重守卫：不是自己 / 不是重复的当前目标 / 实体可见。
            if v ~= self.inst and (v ~= self.controller_target or i == 1) and v.entity:IsVisible() then
--   ★ bundle（正在捆扎/建造中的物件）→ 无条件选中并 break。
--     注释 "bundling or constructing" —— 正在施工的东西必须能被选中，
--     否则玩家会「看不清自己在建什么」。
--   ⚠ 直接 break 跳出整个循环 = 最高优先级，不参与打分。
                if v.entity:GetParent() == self.inst and v:HasTag("bundle") then
                    --bundling or constructing
                    target = v
                    break
                end

--   --Calculate the dsq to filter out objects, ignoring the y component for now.
--   ★★ 与攻击索敌（3253 行算 y）相反：交互的初筛**忽略 y**。
                -- Calculate the dsq to filter out objects, ignoring the y component for now.
                local x1, y1, z1 = v.Transform:GetWorldPosition()
                local dx, dy, dz = x1 - x, y1 - y, z1 - z
                local dsq = dx * dx + dz * dz

--   ★ 3481-3486 行：钓鱼时「鱼在网里就算贴着」，把 dsq 强制为 0。
--     这是「上了钩的鱼自动成为目标」的机制（半径内直接命中）。
                if fishing and v:HasTag("fishable") then
                    local r = v:GetPhysicsRadius(0)
                    if dsq <= r * r then
                        dsq = 0
                    end
                end

--★ 【3488-3492 半径判据】三选一即可：
--     ① dsq < min_rad_sq（1.5²）：无论朝向
--     ② dsq <= rad_sq 且（是当前目标 / 是攻击目标 / 在朝向半球内）
--   ⇒ 「当前目标」与「攻击目标」享有越过角度限制的特权（3490-3491 行）。
                if (dsq < min_rad_sq
                    or (dsq <= rad_sq
                        and (v == self.controller_target or
                            v == self.controller_attack_target or
                            dx * dirx + dz * dirz > 0))) and
                    CanEntitySeePoint(self.inst, x1, y1, z1) then
--★★ 3494 行 `local shouldcheck = dsq < 1 -- Do not skip really close entities.`
--   ★★ 角度检查的豁免：**距离中心 1 格以内**（平方 1，即半径 1）的实体跳过角度判定。
--   ⇒ 效果：脚边的东西永远能选中，不会因为「没正对着它」而选不到。
--   与攻击索敌的 3262 行 `dist < min_rad + phys_rad` 同源思路。
                    local shouldcheck = dsq < 1 -- Do not skip really close entities.
                    if not shouldcheck then
--   3496-3500 行：角度检查用 **angletoepos**（实体位置的绝对角），
--     而打分用 **dot**（相对玩家朝向的向量点积）。
--   ⇒ 两个角度概念并存：
--     · angleto/anglemax = 「实体在不在视野锥内」（硬过滤）
--     · dot = 「有多正对」（软打分）
                        local epos = v:GetPosition()
                        local angletoepos = self.inst:GetAngleToPoint(epos)
--   ★ angleto = math.abs(anglediff(-heading_angle, angletoepos)) ——
--     **减号**再次是 Z 轴符号约定（参见文件头 480 行）。
--     heading_angle 本身在 3616 行也是 `-GetRotation()`。两个负号抵消。
                        local angleto = math.abs(anglediff(-heading_angle, angletoepos))
                        shouldcheck = angleto < anglemax
                    end
                    if shouldcheck then
--★★ 3502-3505 行：**y 分量延后加入**。★ 注释解释得很清楚：
--   --Incorporate the y component after we've performed the inclusion radius test.
--   --We wait until now because we might disqualify our controller_target if its
--   transform has a y component, but we still want to use the y component as a
--   tiebreaker for objects at the same x,z position.
--   → 翻译：先在 xz 平面判「在不在范围内」，再把 y 差加进距离做**平局时的区分**。
--     为什么不一开始就加 y？因为站在二楼时，用 3D 距离会把一楼脚下的东西判远。
--   ⇒★★ 这是本文件最精细的一处设计：分层过滤 + 平局决胜。
                        -- Incorporate the y component after we've performed the inclusion radius test.
                        -- We wait until now because we might disqualify our controller_target if its transform has a y component,
                        -- but we still want to use the y component as a tiebreaker for objects at the same x,z position.
                        dsq = dsq + (dy * dy)

                        local dist = dsq > 0 and math.sqrt(dsq) or 0
                        local dot = dist > 0 and dx / dist * dirx + dz / dist * dirz or 0

                        --keep the angle component between [0..1]
--★ 【3511-3522 交互打分公式】`angle_comp * dist_comp * mult + add`
--     angle_component = (dot + 1) / 2          → [0, 1] 归一化朝向分
--     dist_component   = dsq < min_rad_sq and 1 or min_rad_sq / dsq
--                                          → 近处 1，min_rad 处 ≈1，更远按平方衰减
--     mult             = 当前目标且非墙 ? 1.5 : 1   → 迟滞加成
--     add              = dsq < .0625 and 1 or 0  → ★ 极近处（0.25 格）额外 +1
--   ⚠ 与攻击索敌（3265 行 dot + 1 - 0.5*d²/R²）**完全不同**：
--     这里**没有常数 1 的偏移**，所以 add 是唯一能让「极近目标」取胜的项。
--     注释 3516 行："for stuff that's *really* close - ie, just dropped"
--     —— 刚丢在地上的东西必须立刻能被选中（+1 直接碾压其他候选）。
--   ⚠ 但 3536 行 `if score < target_score then skip` 意味着**严格小于才跳过**，
--     所以同分时后来者会赢（见 3537-3541 的 CanMouseThrough 平局规则）。
                        local angle_component = (dot + 1) / 2

                        --distance doesn't matter when you're really close, and then attenuates down from 1 as you get farther away
                        local dist_component = dsq < min_rad_sq and 1 or min_rad_sq / dsq

                        --for stuff that's *really* close - ie, just dropped
                        local add = dsq < .0625 --[[.25 * .25]] and 1 or 0

                        --just a little hysteresis
                        local mult = v == self.controller_target and not v:HasTag("wall") and 1.5 or 1

                        local score = angle_component * dist_component * mult + add

                        --make it easier to target stuff dropped inside the portal when alive
                        --make it easier to haunt the portal for resurrection in endless mode
--   ★ 3527 行 portal 的双向调整：
--     幽灵态 + 有复活点 → ×1.1（更容易选中传送门复活）
--     活人态        → ×0.9（略微降低，避免误选传送门）
--   注释："make it easier to haunt the portal for resurrection in endless mode"
--   ⚠ GetPortalRez() 没有 nil 检查：若该函数可返回 nil，1.1 会变成 nil，
--     整个 score 变 nil → 3536 行比较报错。
--     推理依据：3527 行 `GetPortalRez() and 1.1 or .9` 的 and/or 惯用法
--       在 GetPortalRez 返回 nil 时会走 or 分支取 0.9，故实际安全。
                        if v:HasTag("portal") then
                            score = score * (self.inst:HasTag("playerghost") and GetPortalRez() and 1.1 or .9)
                        end

--   hasfurnituredecoritem（家具装饰品）→ ×0.5，避免与真家具抢目标。
                        if v:HasTag("hasfurnituredecoritem") then
                            score = score * 0.5
                        end

                        --print(v, angle_component, dist_component, mult, add, score)

--★★ 3536-3541 行：平局时的 CanMouseThrough 规则。
--   `score < target_score` → 跳过；`score == target_score` 时，
--     若新候选**能穿透鼠标**而旧的不行 → 仍然替换。
--   ⇒ CanMouseThrough：某些实体会被鼠标「穿透」（如隐形墙），
--     同分时应优先选能被点到的那个。
                        if score < target_score or
                            (   score == target_score and
                                (   (target ~= nil and not (target.CanMouseThrough ~= nil and target:CanMouseThrough())) or
                                    (v.CanMouseThrough ~= nil and v:CanMouseThrough())
                                )
                            ) then
                            --skip
--   3543 行：可检视物直接选中（不打分），注释 "elseif canexamine and
--   v:HasTag('inspectable')" —— 检视优先级高于「有没有可用动作」。
                        elseif canexamine and v:HasTag("inspectable") then
                            target = v
                            target_score = score
                        else
--   --this is kind of expensive, so ideally we don't get here for many objects
--   ★★★ K 自己标注了性能顾虑：GetSceneItemControllerAction（5339 行）
--     内部会调 playeractionpicker 两次，**很贵**。
--   ⇒ 这就是 3488-3500 行那些廉价的距离/角度过滤必须放在前面的原因：
--     它们是「廉价拒绝」，GetSceneItemControllerAction 是「昂贵确认」。
--   ⇒★★ 这是本文件里少见的、把性能预算写进注释的地方，非常有参考价值。
                            --this is kind of expensive, so ideally we don't get here for many objects
                            local lmb, rmb
--   ★ 3549 行：同一条船上的场景物降权到 0.75 倍。
--     因为船上全是可交互物，需要给「非船上的」让路。
                            if currentboat ~= v or score * 0.75 < target_score then -- Lower priority for scene items on the same boat.
                                lmb, rmb = self:GetSceneItemControllerAction(v)
                            end
                            if lmb ~= nil or rmb ~= nil then
                                target = v
                                target_score = score
                            else
--   ★ 3556-3563 行：手持物品对目标的右键使用（GetItemUseAction）。
--     放在最后是因为它需要先有光标物品（controller-only）。
--   ⚠ 3559 行要求 `rmb.target == v` —— 严格匹配，若 GetItemUseAction
--     返回的是「对自己用」的动作（target 为 nil）则不匹配。
                                local inv_obj = self:GetCursorInventoryObject()
                                if inv_obj ~= nil then
                                    rmb = self:GetItemUseAction(inv_obj, v)
                                    if rmb ~= nil and rmb.target == v then
                                        target = v
                                        target_score = score
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
--   ★ 目标变化才重置 age（3573 行）。这是 3381 行防抖的起点。
    if target ~= self.controller_target then
        self.controller_target = target
        self.controller_target_age = 0
    end
end

--★★ 【UpdateControllerConflictingTargets】冲突消解（30 行，纯硬编码特例）。
--   3582-3583 行的 K 注释坦白了这段的性质：
--     "This is for handling when there are two targets on a controller but one
--      should take super priority over the other. Most of this will be
--      workarounds in appearance as there are no sure fire ways to guarantee
--      what two entities should be prioritized by actions alone as they need
--      additional context."
--   → 翻译：「两个键各选了一个目标，但应该让其中一个压过另一个」。
--     因为动作系统缺少表达「这两个实体之间有上下文关系」的能力，
--     所以只能在这里打补丁。K 自认这是 appearance-level 的 workaround。
local function UpdateControllerConflictingTargets(self)
    local target, attacktarget = self.controller_target, self.controller_attack_target
    if target == nil or attacktarget == nil then
        return
    end
    -- NOTES(JBK): This is for handling when there are two targets on a controller but one should take super priority over the other.
    -- Most of this will be workarounds in appearance as there are no sure fire ways to guarantee what two entities should be prioritized by actions alone as they need additional context.
    if target ~= attacktarget then
--   ★ 特例 1：正在查看美人鱼王座（mermthrone）时，旁边的鱼人（merm）优先。
--     因为鱼人王座机制要求与鱼人交互。
--   ⚠ 硬编码在通用组件里，与 3329 行的礼物机属同类问题。
        if target:HasTag("mermthrone") and attacktarget:HasTag("merm") then
            -- Inspecting a throne but could interact with a Merm, Merm takes priority.
            target = attacktarget
            self.controller_target_age = 0
--   ★ 特例 2：两只蟹王钳（crabking_claw）时选近的那个。
--     注释："it will most likely be the one next to a boat" ——
--     「因为近的那个多半是在船边上的那个」。
--   ⚠ 3595 行只在 else 分支重置 controller_target_age，不对称。
        elseif target:HasTag("crabking_claw") and attacktarget:HasTag("crabking_claw") then
            -- Two claws let us try targeting the closest one because it will most likely be the one next to a boat.
            if self.inst:GetDistanceSqToInst(target) < self.inst:GetDistanceSqToInst(attacktarget) then
                attacktarget = target
            else
                target = attacktarget
                self.controller_target_age = 0
            end
        end
    end

--   ★ 写回结果。若两者都没变（3600 行之前的 target/attacktarget 相同），
--     赋值是幂等的。
    self.controller_target, self.controller_attack_target = target, attacktarget
end

--★★ 【UpdateControllerTargets(dt)】三件套的调度器。
--   ★ 顺序很重要：3619 交互先算（它可能修改 controller_attack_target，
--     见 3400-3405 行的 controller_should_use_attack_target），
--     然后 3620 攻击再算（会覆盖 controller_attack_target），
--     最后 3621 冲突消解。
--   ⚠ 但 3362 行 UpdateControllerInteractionTarget 的第一行会读
--     `self:GetControllerAttackTarget()` —— 用的是**上一帧**的攻击目标。
--     ⇒ 存在一帧的延迟。锁定状态下这个延迟不影响（3364 行直接赋值）。
function PlayerController:UpdateControllerTargets(dt)
	if self:IsAOETargeting() or
		self.inst:HasTag("sitting_on_chair") or
		(self.inst:HasTag("weregoose") and not self.inst:HasTag("playerghost")) or
		(self.classified and self.classified.inmightygym:value() > 0) then
        self.controller_target = nil
        self.controller_target_age = 0
        self.controller_attack_target = nil
        self.controller_attack_target_ally_cd = nil
        self.controller_targeting_lock_target = nil
        return
    end
--   ★★ heading_angle = -GetRotation()，再取 cos/sin 得 dirx/dirz。
--   ⚠ 注意 3617-3618 行：`dirz = math.sin(heading_angle * DEGREES)`
--     ★★ **没有负号**！而 3616 行已经取过负的 rotation。
--   ⇒ 这就是为什么 480 行的注释说「Z 偏移为负」：
--     rotation 取负 → sin(-θ) = -sin(θ) → 自动完成 Z 翻转。
--     理解要点：dirx/dirz 是**引擎坐标系**下的朝向向量，与「屏幕右下」直觉相反。
--   ⇒ 与 4034 行 `math.atan2(z0 - pt.z, pt.x - x0) * RADIANS` 对照：
--     那个 atan2 的结果可以直接与 dir 的 atan2 对比，说明坐标系一致。
    local x, y, z = self.inst.Transform:GetWorldPosition()
    local heading_angle = -self.inst.Transform:GetRotation()
    local dirx = math.cos(heading_angle * DEGREES)
    local dirz = math.sin(heading_angle * DEGREES)
    UpdateControllerInteractionTarget(self, dt, x, y, z, dirx, dirz, heading_angle)
    UpdateControllerAttackTarget(self, dt, x, y, z, dirx, dirz)
    UpdateControllerConflictingTargets(self)
end

--【GetControllerTarget / GetControllerAttackTarget】带 IsValid 校验的 getter。
--   ★ 为什么需要包装：因为 controller_target 可能已被 Remove（-IsValid 后索引会崩）。
--   ⚠ 但它们不检查 IsValid 之外的 INLIMBO/NOCLICK（3370-3377 行的检查在别处）。
function PlayerController:GetControllerTarget()
    return self.controller_target ~= nil and self.controller_target:IsValid() and self.controller_target or nil
end

function PlayerController:GetControllerAttackTarget()
    return self.controller_attack_target ~= nil and self.controller_attack_target:IsValid() and self.controller_attack_target or nil
end

--   ★ 3632-3636 行：`--[[ CharlesB: Disabled for now ]]` 块注释掉的
--     IsControllerTargetingModifierDown。③ 与 125-127 行的注释字段配套。
--   ⇒ 目标锁定经历了「按住修饰键」→「按一下切换」的设计变更。
--[[ CharlesB: Disabled for now
function PlayerController:IsControllerTargetingModifierDown()
    return self.controller_targeting_modifier_down
end
]]

--【CanLockTargets / IsControllerTargetLockEnabled / IsControllerTargetLocked】
--   三个查询。3638 行读 Profile（玩家设置），3642/3646 读运行时状态。
--   ⚠ 3647 行 `IsControllerTargetLocked()` 返回的是 `lock_target and attack_target`，
--     是一个**实体或 nil/false** 而非布尔 —— 严格说是「锁定目标本身」。
--     外部（widgets/controls.lua:748/755/771）当作布尔用，靠 Lua 的真值语义工作。
function PlayerController:CanLockTargets()
    return self.controller_targeting_lock_available
end

function PlayerController:IsControllerTargetLockEnabled()
	return self.controller_targeting_lock_target
end

function PlayerController:IsControllerTargetLocked()
	return self.controller_targeting_lock_target and self.controller_attack_target
end

--【ControllerTargetLock(enable)】
--   ★ 3653 行：**必须有目标才能锁定**。避免锁定到空。
function PlayerController:ControllerTargetLock(enable)
	if enable then
		-- only enable locking if there's a target
		if self.controller_targeting_lock_available and self.controller_attack_target then
			self.controller_targeting_lock_target = true
		end
	else
		-- disable locking at any time
		self.controller_targeting_lock_target = false
	end
end

function PlayerController:ControllerTargetLockToggle()
	if self:IsControllerTargetLockEnabled() then
		self:ControllerTargetLock(false)
	else
		self:ControllerTargetLock(true)
	end
end

--【CycleControllerAttackTargetForward / Back】方向键循环候选目标。
--   ★ 只在锁定状态下生效（3672 行）。3670 正向 / 3681 反向。
--   ⚠ 3681 行 CycleControllerAttackTargetBack **无任何调用点**（grep 全文确认）。
--     ⇒ 反向循环是预留功能（可能由模组或未来的手柄设置调用）。
--   ★ 3673 行 `index + 1` 若 index 为 nil 会崩。
--     缓解：index 由 3351 行设置，而 3351 只在「目标变化」时赋值；
--       首次锁定时若目标未变化（index 仍为 nil）就会崩。
--     但 3653 行要求锁定时已有 controller_attack_target，
--     而该目标必然是某帧 3349-3353 行设的（此时 index 被赋）。
--     ⚠ 除非该目标是 3229 行插入的「已在列表中」路径 —— 仍会走 3349 分支。
--     推理依据：3349 行 `if target ~= self.controller_attack_target` 在
--       首次设置时必然为真，故 index 会被赋值。实际安全。
function PlayerController:CycleControllerAttackTargetForward()
	local num_targets = #self.controller_targeting_targets
	if self.controller_targeting_lock_target and num_targets > 0 then
		self.controller_targeting_target_index = self.controller_targeting_target_index + 1
		if self.controller_targeting_target_index > num_targets then
			self.controller_targeting_target_index = 1
		end
		self.controller_attack_target = self.controller_targeting_targets[self.controller_targeting_target_index]
	end
end

function PlayerController:CycleControllerAttackTargetBack()
	local num_targets = #self.controller_targeting_targets
	if self.controller_targeting_lock_target and num_targets > 0 then
		self.controller_targeting_target_index = self.controller_targeting_target_index - 1
		if self.controller_targeting_target_index < 1 then
			self.controller_targeting_target_index = num_targets
		end
		self.controller_attack_target = self.controller_targeting_targets[self.controller_targeting_target_index]
	end
end


--------------------------------------------------------------------------
--★★ 【3694-3695 顶部注释 —— 本文件最重要的一行注释】
--   --remote_vector.y is used as a flag for stop/direct/drag walking
--   --since its value is never actually used in the walking function
--   ==> ★★★ 这是 B8 缺陷的官方声明。Klei 自己的注释说：
--     「y 被用作 停止/直接行走/拖拽行走 的标志，**因为它的值在行走函数
--       里从来没被真正用到**」。
--   ⇒ 而事实是：这句话在写时为真，后来**不再为真**了。
--     因为 3736-3747 行的 GetRemotePredictPosition 在 y>=3 时把 y 当成
--     **真实高度**返回给调用方（`Vector3(x, self.remote_vector.y, z)`），
--     而 4014/4030/4054/4067 行又反过来用 `pt.y == 5 / < 5 / == 3 / == 4`
--     做模式判断。
--   ⚠⚠⇒ 编码与解码**互相递归**：
--     写入端：3790 行 `remote_vector.y = isdirectwalking and 3 or 4`（标签）
--     解码端 A：3737 行 `if self.remote_vector.y >= 3 then`（当标签用）
--     解码端 B：3743 行 `Vector3(x, self.remote_vector.y, z)`（当坐标用）
--     消费端：4054 行 `if pt.y == 3`（又当标签用）
--   ⇒ 同一个数值在同一次调用链里既是「模式」又是「海拔」。
--     只要标签值不是 0，海拔就是 3/4/5/6 这种荒谬高度。
--     目前之所以没出事，是因为没有任何代码真的用 pt.y 做物理计算。
--   参见 bug-patterns.md B8：「一字段三语义」。
--remote_vector.y is used as a flag for stop/direct/drag walking
--since its value is never actually used in the walking function

--============================================================
-- 【第七段预告】3693 行开始是 ★ 移动链路的核心，
--   remote_vector 的编码表、四种行走手势、橡皮筋纠正、teleport 区分
--============================================================
--【ResetRemoteController】★ 全量重置远端镜像。三件事：
--   ① remote_vector.y = 0（模式归零 = 停止）
--   ② remote_controls = {}（按键全松）
--   ③ ClearRemotePredictData()（预测数据全清）
--   ★ 调用点：322（Activate）、368（Deactivate）、2736（OnUpdate 禁用时）、
--     5927（ToggleMovementPrediction）。四处都是「状态彻底变了」的时刻。
function PlayerController:ResetRemoteController()
    self.remote_vector.y = 0
    if next(self.remote_controls) ~= nil then
--============================================================
-- 【第七段】3700-4200 行：★★★ 移动链路（客户端预测 + 橡皮筋 + teleport）
--============================================================
        self.remote_controls = {}
    end
	self:ClearRemotePredictData()
end

--【ClearRemotePredictData(force_reset_timer)】★ 预测数据的三段握手清理。
--   3706-3707 行：dir 与 stop_tick 直接清。
--   3708-3712 行：★ 若已收到 stop 通知 → 清标志并取消 locomotor 的计时器。
--   3713-3715 行：否则若 force_reset_timer → 也取消（强制）。
--   ⇒ 语义：
--     · 非强制 + 没通知 → **保留** locomotor 的计时器（可能还有效）
--     · 非强制 + 有通知 → 取消（客户端说停了，计时器无意义）
--     · 强制 → 无条件取消（3043 行的 busy 分支用）
function PlayerController:ClearRemotePredictData(force_reset_timer)
	self.remote_predict_dir = nil
	self.remote_predict_stop_tick = nil
	if self.remote_predict_stop_notified then
		self.remote_predict_stop_notified = nil
		if self.locomotor then
--   ★ CancelPredictMoveTimer（locomotor.lua:465）：
--     取消「预测移动超时自杀」定时器。
--     若不取消，玩家停下后 locomotor 会在某个时刻自行归位（回滚），
--     造成「明明停住了却又抖一下退回」。
			self.locomotor:CancelPredictMoveTimer()
		end
	elseif force_reset_timer and self.locomotor then
		self.locomotor:CancelPredictMoveTimer()
	end
end

--【ConvertPlatformRelativeToAbsoluteXZ】平台局部坐标 → 世界坐标。
--   ★ 3719 行 platform 为 nil → 原样返回（世界坐标）。
--   ⚠ 3721 行 `elseif platform:IsValid()` —— 若平台无效则**隐式返回 nil**，
--     而调用方（3761 行 GetRemotePredictStopXZ）返回 nil 是合法的（3759 行的契约）。
--     3780 行的 GetRemotePredictPositionExternal 也做了 x 的 nil 检查。
--   ⇒ 平台的失效是被显式处理的，这是平台机制补丁史里少见的干净之处。
local function ConvertPlatformRelativeToAbsoluteXZ(vec, platform)
	if platform == nil then
		return vec.x, vec.z
	elseif platform:IsValid() then
		local x, y, z = platform.entity:LocalToWorldSpace(vec.x, 0, vec.z)
		return x, z
	end
end

--★★★ 【四个解码器】—— remote_vector 的读出端。
--   GetRemoteDirectVector  (3727) y==1 → 方向向量（directwalking）
--   GetRemoteDragPosition  (3731) y==2 → 拖拽目标点（dragwalking）
--   GetRemotePredictPosition(3736) y>=3 → 预测目标点（★ y 变成海拔）
--   GetRemotePredictStopXZ  (3759) 特殊：读取「刚停止的那一帧」的坐标
function PlayerController:GetRemoteDirectVector()
    return self.remote_vector.y == 1 and self.remote_vector or nil
end

function PlayerController:GetRemoteDragPosition()
    return self.remote_vector.y == 2 and self.remote_vector or nil
end

--V2C: These aren't really meant for use outside of this component XD
--   --V2C: These aren't really meant for use outside of this component XD
--   ⇒ 标注「内部 API」，但 12 处外部调用（inventory / locomotor 等）。
--     「XD」暗示这是临时状态。
--   ★★ 3743 行是 B8 的**病根**：`Vector3(x, self.remote_vector.y, z)`
--     把标签值原样当作 Y 坐标塞进返回值。
--     若 y==3，返回的向量高度就是 3（相当于三层楼高）。
--     全部调用点：4080 附近的自比较（只用 xz）、5769-5797（只用 xz）、
--     1934/976/1033/1225/1269/2334/4294/4953/5109（只取 x,z 取或整点）。
--   ⚠ 已核实：没有任何调用点真正使用返回值的 .y 做物理计算。
--     5797 行的 `Transform:SetPosition(pt.x, 0, pt.z)` 硬编码了 y=0。
--     ⇒ 这证明「y 是标签」在实践中是自洽的，
--       但 3743 行的写法依然是一个**定时炸弹**：任何人拿这个返回值算高度都会中招。
function PlayerController:GetRemotePredictPosition()
	if self.remote_vector.y >= 3 then
		if self.remote_vector.platform == nil then
			return self.remote_vector
		elseif self.remote_vector.platform:IsValid() then
			local x, y, z = self.remote_vector.platform.entity:LocalToWorldSpace(self.remote_vector.x, 0, self.remote_vector.z)
			if x then
				return Vector3(x, self.remote_vector.y, z)
			end
		end
	end
end

--V2C; This one can be used externally XD
--   --V2C; This one can be used externally XD
--   ★ 与 GetRemotePredictPosition 的区别：3754 行**显式构造 y=0** 的向量。
--     ⇒ 这个版本是「干净的」，没有 B8 陷阱。
--     外部调用点：inventory.lua:2428（丢物品的落点）、locomotor.lua:930。
function PlayerController:GetRemotePredictPositionExternal()
	if self.remote_vector.y >= 3 then
		local x, z = ConvertPlatformRelativeToAbsoluteXZ(self.remote_vector, self.remote_vector.platform)
		if x then
			return Vector3(x, 0, z)
		end
	end
end

--★ 【GetRemotePredictStopXZ】「上一帧刚停止」的坐标读取。
--   ★★ 3760 行的双重条件：`remote_predict_stop_tick + 1 == GetTick()`
--     且 `remote_vector.y == 0`。
--   ⇒ 语义：**只在停止后的紧接一帧有效**。
--     这是「一次性读取」的设计 —— 读取后 4105 行会清 stop_tick。
--   ⚠ 若服务器那一帧没跑（卡顿），读取失败，客户端位置就永久偏了那 0.5 格。
--     但 4082 行的橡皮筋会在后续帧兜住（超过 4 格才触发，0.5 格不会）。
--   ⇒ 净效果：极端情况下可能残留半格误差，无纠正。属可接受的权衡。
function PlayerController:GetRemotePredictStopXZ()
	if self.remote_predict_stop_tick + 1 == GetTick() and self.remote_vector.y == 0 then
		return ConvertPlatformRelativeToAbsoluteXZ(self.remote_vector, self.remote_vector.platform)
	end
end

--★★ 【OnRemoteDirectWalking】移动 RPC 的服务端接收端（direct）。
--   ★ 三重守卫与所有 Remote* 一致。
--   ★★ 3771 行的 ClearRemotePredictData()：
--     「切到直接行走 ⇒ 之前的预测目标作废」。
--     这是三种移动模式**互斥**的保证。
--   ⚠ 但注意它**不设置** remote_predict_dir / _stop_tick —— 3771 行的
--     ClearRemotePredictData 把它们清了。所以切到 direct 后预测状态是干净的。
function PlayerController:OnRemoteDirectWalking(x, z)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.remote_vector.x = x
        self.remote_vector.y = 1
        self.remote_vector.z = z
		self.remote_vector.platform = nil
		self:ClearRemotePredictData()
    end
end

function PlayerController:OnRemoteDragWalking(x, z)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.remote_vector.x = x
        self.remote_vector.y = 2
        self.remote_vector.z = z
		self.remote_vector.platform = nil
		self:ClearRemotePredictData()
    end
end

--★★★ 【OnRemotePredictWalking】★★ 预测行走 RPC 的服务端接收端 —— 最复杂的一个。
--   签名：(x, z, isdirectwalking, isstart, platform, overridemovetime, isstop)
--   ⚠ 服务端已经做过参数校验（networkclientrpc.lua:425-467）：
--     · 两种形态之一：全 nil（x==z==isdirectwalking==platform==platform_relative==nil
--       且 isstart 或 isstop 为真）或全合法
--     · isstart 必须是 bool
--     · IsPointInRange（半径 64！）
--     · 必须 playercontroller.remote_predicting 为真
--   ⇒ 所以本函数收到的是「已清洗」的数据。
function PlayerController:OnRemotePredictWalking(x, z, isdirectwalking, isstart, platform, overridemovetime, isstop)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
		if x then
			self.remote_vector.x = x
--   ★★ 3789 行写入标签：`isdirectwalking and 3 or 4`。
--     这是 remote_vector.y 的**唯一写入点**之一（另一处是 3923 行的客户端）。
--   ⚠ 3791 行的 platform 参数：**x/z 是该平台的局部坐标**。
--     3790 行设 y=3/4 后，3737-3745 行的 GetRemotePredictPosition 会做还原。
--   ⚠⚠ 疑似缺陷（B8 的具体表现）：
--     platform 为 nil（世界坐标）时，3743 行返回 `self.remote_vector` 本身
--     （3739 行）—— 此时 y=3/4/5/6 是标签；
--     platform 非 nil 时，3741-3743 行做坐标变换并 `Vector3(x, y, z)`，
--     此时的 y 仍是标签值，被伪装成海拔。
--     两条路径返回的向量语义不一致（一个是「原始信封」，一个是「还原后的点」），
--     但调用方无法区分。
--     推理依据：3739 行 `return self.remote_vector` 直接返回**同一个对象**，
--       调用方若修改返回值就会破坏内部状态（aliasing 缺陷）。
--   ⚠ 已核实当前所有调用点都只读不写，故 aliasing 未被触发。
			self.remote_vector.y = isdirectwalking and 3 or 4
			self.remote_vector.z = z
			self.remote_vector.platform = platform
			self.remote_predict_dir = nil
			self.remote_predict_stop_tick = nil
--★ 3794 行 `remote_predict_stop_notified = isstop`：
--   isstop 可能是 nil（只发坐标不发 stop），此时 notified 被清空。
--   ⇒ 语义：「客户端最后一条消息明确说了 stop 吗」。
			self.remote_predict_stop_notified = isstop
			if isstart then
--★ isstart → RestartPredictMoveTimer（locomotor.lua:461）：
--   「重新开始计时」。locomotor 内部有个超时：预测移动若在 N 秒内没更新就自杀。
--   ⇒ 这是**预测的保险丝**：客户端崩溃/断网时服务器不会永远追一个死目标。
				self.locomotor:RestartPredictMoveTimer()
			elseif overridemovetime then
--   overridemovetime → OverridePredictTimer(GetTime() - overridemovetime)：
--   ★★ 客户端告诉服务器「我已经移动了 N 秒」。
--     服务器用 `GetTime() - N` 反推出「客户端的移动起点时刻」，
--     从而让服务器的移动计时器与客户端对齐。
--   ⇒ 这是**时间戳同步**的一个轻量实现（只传时长不传绝对时间，
--     避免时钟偏移）。参见 locomotor.lua:469 OverridePredictTimer。
				self.locomotor:OverridePredictTimer(GetTime() - overridemovetime)
			end
--   x == nil 分支：只发控制信号（isstart / isstop / overridemovetime）不发坐标。
--   3801-3803 行 K 的注释："guaranteed either isstart or isstop (or both) /
--   overridemovetime optional / everything else nil"
--   ⇒ 这解释了 3932 行的 `SendRPCToServer(RPC.PredictWalking, nil, nil, nil,
--     isstart, nil, nil, overridemovetime, isstop)` ——
--     **前四个全 nil**（x, z, isdirectwalking, platform）。
		else
			--guaranteed either isstart or isstop (or both)
			--overridemovetime optional
			--everything else nil
			if isstart then
				self.locomotor:RestartPredictMoveTimer()
			elseif overridemovetime then
				self.locomotor:OverridePredictTimer(GetTime() - overridemovetime)
			end
--★ 3809-3816 行的判定：客户端说「我停了」时，服务器怎么处理计时器。
--   ① 不是 stop → 清 notified（还在走）
--   ② 是 stop 且（服务器知道停止 tick 或有预测位置）→ notified = true，
--      「我记住了，等会儿用」（由 3708 行消费）
--   ③ 是 stop 但服务器完全不知情 → 直接 CancelPredictMoveTimer
--     （客户端骗我们？没有有效目标，停就停）
			if not isstop then
				self.remote_predict_stop_notified = nil
			elseif self.remote_predict_stop_tick or self:GetRemotePredictPosition() then
				self.remote_predict_stop_notified = true
			else
				self.remote_predict_stop_notified = nil
				self.locomotor:CancelPredictMoveTimer()
			end
		end
    end
end

--★ 【OnRemotePredictOverrideLocomote】busy 状态下的方向微调（服务端）。
--   3822 行的三重守卫 + 状态标签 overridelocomote：
--     ★ 必须处于「可被外部驱动移动」的状态（滑索、传送带等）。
--   3823-3826 行的条件被 3830 行和 3967 行的注释互为印证：
--     「e.g. Moose tackle can be cancelled using directional input, but the
--      state itself is still busy」—— 密恐魔被套住时能用摇杆挣脱。
function PlayerController:OnRemotePredictOverrideLocomote(dir)
	if self.ismastersim and self.handler == nil and self.inst.sg:HasStateTag("overridelocomote") then
		if self:IsEnabled() and not self:IsBusy() or
--   ★ classified.busyremoteoverridelocomote（--WASD）：服务端标记「这个状态
--     允许摇杆驱动」。由 SGwilson 在进入特定状态时设置。
--   ★ 3824-3825 行两个 classified 或运算：摇杆 与 左键 两种驱动源。
			self.classified.busyremoteoverridelocomote:value() or
			self.classified.busyremoteoverridelocomoteclick:value()
		then
			if dir and self.inst.sg:HasStateTag("canrotate") then
				self.locomotor:SetMoveDir(dir)
			end
			self.inst:PushEvent("locomote", { dir = dir, remoteoverridelocomote = true })
		end
	end
end

--★★★ 【OnRemoteStartHop(x, z, platform)】★★ 跳跃的**服务器权威校验**。
--   ★ 这是本文件里「反作弊校验」写得最完整的一段，值得逐行读。
--   RPC 层已做（networkclientrpc.lua:491-506）：参数类型 + platform 一致性。
--   本函数再做**距离校验**（3835-3882）。
function PlayerController:OnRemoteStartHop(x, z, platform)
    if not self.ismastersim then return end
    if not self:IsEnabled() then return end
--   3838 行 `if not self.handler == nil then return end` ——
--   ⚠ 疑似缺陷（Lua 运算符优先级）：`not self.handler` 先求值为布尔，
--     再与 nil 比较 → **恒为 false**（布尔永远不等于 nil）。
--     本意应是 `if self.handler ~= nil then return end`（本机玩家不发 RPC）。
--   推理依据：3790/3837 行的前两句是 ismastersim 与 IsEnabled，
--     3838 行应是第三个同类守卫 `self.handler == nil`（少了波浪号）。
--   ⇒ 实际后果：本机玩家（房主在自己的客户端上）发来的 StartHop RPC
--     **不会被这个守卫拦截**，会继续执行到 locomotor:StartHopping。
--     对房主来说这基本无害（自己就是权威），但守卫失效了。
--   ⚠ 这是一个**真实存在但低危**的缺陷：守卫失效，且恰好对房主最不重要。
    if not self.handler == nil then return end

--   ★★ 3850 行的守卫：`platform == nil and (当前无平台 or 落点在海里)` → 拒绝。
--   逻辑：请求跳到「没有平台的地方」→ 除非那是个漂浮物（跳到海里的浮冰）。
--   ⇒ 防止客户端凭空请求「跳到地图外的虚空」。
    local my_x, my_y, my_z = self.inst.Transform:GetWorldPosition()
    local target_x, target_y, target_z = x, 0, z
    local platform_for_velocity_calculation = platform

    if platform ~= nil then
        target_x, target_z = platform.components.walkableplatform:GetEmbarkPosition(my_x, my_z)
    else
        platform_for_velocity_calculation = self.inst:GetCurrentPlatform()
    end

	if platform == nil and (platform_for_velocity_calculation == nil or TheWorld.Map:IsOceanAtPoint(target_x, 0, target_z)) then
        return
	end

    local hop_dir_x, hop_dir_z = target_x - my_x, target_z - my_z
    local hop_distance_sq = hop_dir_x * hop_dir_x + hop_dir_z * hop_dir_z

--★★ 【3857-3874：移动平台的橡皮筋补偿】★ 本文件最精细的一段计算。
--   问题：站在**移动的船**上跳向对岸。客户端算落点时基于自己的世界坐标，
--     服务端执行时船已移动。若不补偿，合法跳会被判「太远」。
--   解法（3859-3874）：
--     ① 取平台速度向量
--     ② 若速度非零：把「跳跃方向」与「平台移动方向」都归一化
--     ③ 取点积 hop_dir_dot_platform_velocity（3870 行）
--     ④ 若点积 > 0（同向）→ 额外预算 = 0.7 秒 × 速度 × 点积
--   ⇒ 这是把「一个 RTT 时间内的平台位移」折算成距离预算。
--   ★ 3870 行严格要求点积 > 0：船**朝跳跃方向**移动才补偿。
--     若船横向漂移（点积 ≈ 0）不补偿 —— 因为那不是「追不上」而是「偏了」，
--     偏了应该由别的方式修正。
    local target_velocity_rubber_band_distance = 0
    local platform_velocity_x, platform_velocity_z = 0, 0
    if platform_for_velocity_calculation ~= nil then
        local platform_physics = platform_for_velocity_calculation.Physics
        if platform_physics ~= nil then
            platform_velocity_x, platform_velocity_z = platform_physics:GetVelocity()
            if platform_velocity_x ~= 0 or platform_velocity_z ~= 0 then
                local hop_distance = math.sqrt(hop_distance_sq)
                local normalized_hop_dir_x, normalized_hop_dir_z = hop_dir_x / hop_distance, hop_dir_z / hop_distance
                local velocity = math.sqrt(platform_velocity_x * platform_velocity_x + platform_velocity_z * platform_velocity_z)
                local normalized_platform_velocity_x, normalized_platform_velocity_z = platform_velocity_x / velocity, platform_velocity_z / velocity
                local hop_dir_dot_platform_velocity = normalized_platform_velocity_x * normalized_hop_dir_x + normalized_platform_velocity_z * normalized_hop_dir_z
                if hop_dir_dot_platform_velocity > 0 then
                    target_velocity_rubber_band_distance = RUBBER_BAND_PING_TOLERANCE_IN_SECONDS * velocity * hop_dir_dot_platform_velocity
                end
            end
        end
    end

--★ 跳跃的橡皮筋距离 = 基础 4 + 平台速度补偿 + locomotor 自己的跳跃距离。
--   GetHopDistance（locomotor.lua:1222）返回「按当前速度能跳多远」。
--   ⇒ 三项相加意味着：合法跳（落点在跳跃能力内 + 网络滞后补偿内 + 平台移动内）
--     才被接受。
	local hop_rubber_band_distance = RUBBER_BAND_DISTANCE + target_velocity_rubber_band_distance + self.locomotor:GetHopDistance()
    local hop_rubber_band_distance_sq = hop_rubber_band_distance * hop_rubber_band_distance

--★ 超距则 `print` 一整段诊断信息后 return。
--   ⚠ 注意用的是 `print` 而非 Print/VERBOSITY 包装 ——
--     开发版会把这段打到日志，生产版被 C++ 层过滤。
--   ★ 这是本文件里**唯一**的调试输出（grep 确认），K 特意留下它
--     因为「Hop discarded」是玩家会遇到的真实问题（船跳失败）。
    if hop_distance_sq > hop_rubber_band_distance_sq then
        print("Hop discarded:", "\ntarget_velocity_rubber_band_distance", target_velocity_rubber_band_distance, "\nplatform_velocity_x", platform_velocity_x, "\nplatform_velocity_z", platform_velocity_z, "\nhop_distance", math.sqrt(hop_distance_sq), "\nhop_rubber_band_distance", math.sqrt(hop_rubber_band_distance_sq))
        return
    end

--   ★★ remote_vector.y = 6 —— 跳跃模式。这是唯一的 y=6 写入点。
--   3964 行 IsLocalOrRemoteHopping 会读它：`remote_vector.y == 6 or
--   locomotor.hopping`。
--   ⇒ y=6 的含义是「正在跳跃」，此时 x/z 是**客户端请求的落点**。
--   ⚠ 3885 行 ClearRemotePredictData()：跳跃会取消预测移动（互斥）。
    self.remote_vector.y = 6
	self:ClearRemotePredictData()
	self.locomotor:StartHopping(x,z,platform)
end

--★ OnRemoteStopWalking / OnRemoteStopHopping：停止的两种 RPC，
--   ★★ 但两个函数体**完全相同**（都是 y=0 + ClearRemotePredictData）。
--   ⚠ 疑似缺陷（冗余 RPC）：既然行为一致，可以合并成一个 StopWalking。
--     推理依据：对比 3889-3894 与 3896-3901 行，函数体逐字相同。
--     影响：多占用一个 RPC 通道（每个 RPC 都要注册 handler，占内存）。
--     历史原因：推测 StopHopping 是后加的，忘了合并。
function PlayerController:OnRemoteStopWalking()
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.remote_vector.y = 0
		self:ClearRemotePredictData()
    end
end

function PlayerController:OnRemoteStopHopping()
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.remote_vector.y = 0
		self:ClearRemotePredictData()
    end
end

--★★ 【3903-3945 客户端发 RPC 端】—— 四种移动手势的发送。
--   RemoteDirectWalking (3903) / RemoteDragWalking (3912) /
--   RemotePredictWalking (3922) / RemoteStopWalking (3940)
--   ★★ 全部有「值未变则不发」的去重（3904/3913/3924/3941 行）。
--     这是**带宽优化的第一道闸**。
function PlayerController:RemoteDirectWalking(x, z)
    if self.remote_vector.x ~= x or self.remote_vector.z ~= z or self.remote_vector.y ~= 1 then
--   ★★ 3905 行的英文注释是一条协议设计说明：
--   "x and z are directions, not positions, so we don't need it to be
--    platform relative"
--   → directwalking 的 x/z 是**方向向量**（已归一化），不是位置，
--     所以不需要平台相对坐标转换（也不需要 platform 参数）。
--   ⇒ ★ 这解释了网络侧的直接校验：networkclientrpc.lua:392
--     `if x * x + z * z < 1.01 then` —— ★★ 用**长度平方 ≤ 1.01** 验证方向向量！
--     这是一个漂亮的协议级反作弊：客户端不可能通过这里发一个位置。
--   ⇒ 对比 dragwalking（4402 行）：发的是位置，需要 IsPointInRange 与平台转换。
        SendRPCToServer(RPC.DirectWalking, x, z) -- x and z are directions, not positions, so we don't need it to be platform relative
        self.remote_vector.x = x
        self.remote_vector.y = 1
        self.remote_vector.z = z
    end
end

function PlayerController:RemoteDragWalking(x, z)
    if self.remote_vector.x ~= x or self.remote_vector.z ~= z or self.remote_vector.y ~= 2 then
--★ 拖拽行走需要平台相对坐标（3914 行 GetPlatformRelativePosition）。
--   3915 行 SendRPCToServer(RPC.DragWalking, pos_x, pos_z, platform,
--   platform ~= nil) —— ★ 最后那个 `platform ~= nil` 是 RPC 的
--   **类型标记位**（RPC 需要区分「nil 参数」与「缺省参数」）。
		local platform, pos_x, pos_z = self:GetPlatformRelativePosition(x, z)
        SendRPCToServer(RPC.DragWalking, pos_x, pos_z, platform, platform ~= nil)
        self.remote_vector.x = x
        self.remote_vector.y = 2
        self.remote_vector.z = z
    end
end

--★★ 【RemotePredictWalking】预测行走的客户端发送端。
--   3923 行 `local y = (overridedirect or self.directwalking) and 3 or 4`：
--     ★★ 客户端**自己**算出与服务器 3789 行相同的标签值，
--       并保存在本地 remote_vector 里（3928 行）。
--     这就是「客户端预测」的字面含义：两端各自维护同构的 remote_vector。
--   ⚠ 注意 3923 行的条件用了 `or self.directwalking`，
--     而 3789 行只有 `isdirectwalking`。客户端多了一个 overridedirect 来源
--     （4119/5756 行的调用会传 overridedirect = 上一次的 direct 值）。
function PlayerController:RemotePredictWalking(x, z, isstart, overridemovetime, overridedirect, isstop)
	local y = (overridedirect or self.directwalking) and 3 or 4
--★★ 3924 行的去重条件是**三段或**，且末段带 `self.remote_vector.y ~= 0`：
--   `x 变了 or z 变了 or (y 变了 and 当前不是停止态)`。
--   ⇒ 语义：「服务器说停了（y==0）之后，即使客户端的意图没变也不再发」。
--   ★ 设计意图：停 → 走 的转换要发一次（3757 行是 stop，3931 行补发 isstart）。
--   ⚠⚠ 疑似缺陷（状态机卡死）：见 3005 行的分析 ——
--     服务端把 remote_vector.y 置 0（nopredict 分支）后，
--     客户端的 3924 行末段条件 `self.remote_vector.y ~= 0` 恒为 false，
--     若 x/z 也恰好没变，则**永远不再发送预测更新**。
--   ⇒ 服务端一次 nopredict 置零会让客户端的预测目标永久冻结。
--   推理依据：3924 行完整条件；3006 行 `self.remote_vector.y = 0`；
--     3930 行 predictionsent = true 也只在「发送了」时设置，
--     且 2659 行每帧清零，说明它也依赖「至少发过一次」。
    if self.remote_vector.x ~= x or self.remote_vector.z ~= z or (self.remote_vector.y ~= y and self.remote_vector.y ~= 0) then
		local platform, pos_x, pos_z = self:GetPlatformRelativePosition(x, z)
		SendRPCToServer(RPC.PredictWalking, pos_x, pos_z, self.directwalking, isstart, platform, platform ~= nil, overridemovetime, isstop)
        self.remote_vector.x = x
        self.remote_vector.y = y
        self.remote_vector.z = z
        self.predictionsent = true
--   ★ 3931-3932 行：坐标没变但 isstart/isstop 变了 → 补发「无坐标」的控制消息。
--     对应服务端 3800 行的 x==nil 分支。
--   ⇒ 这是三态消息（坐标 / 控制 / 无）的第二种形态。
	elseif isstart or isstop then
		SendRPCToServer(RPC.PredictWalking, nil, nil, nil, isstart, nil, nil, overridemovetime, isstop)
    end
end

--【RemotePredictOverrideLocomote】busy 态方向微调的客户端发送端。
--   3937 行 `dir or (autodir ~= false and GetRotation()) or nil`：
--     ★★ 三态：无 dir + autodir ~= false → 用当前朝向（持续微调）
--       无 dir + autodir == false → 显式 nil（**停止**微调）
--       有 dir → 用指定方向
--   ⇒ autodir 参数是一个「布尔化的 nil」，与文件头的 or/nil 惯用法同源。
function PlayerController:RemotePredictOverrideLocomote(dir, autodir)
	SendRPCToServer(RPC.PredictOverrideLocomote, dir or (autodir ~= false and self.inst.Transform:GetRotation()) or nil)
end

--★ RemoteStopWalking：只有 y ~= 0 时才发（3941 行去重）。
function PlayerController:RemoteStopWalking()
    if self.remote_vector.y ~= 0 then
        SendRPCToServer(RPC.StopWalking)
        self.remote_vector.y = 0
    end
end

--★ 【DoPredictHopping】★★ 客户端「检测到跳跃就上报」。
--   ★★ 3950 行的边沿检测：`if locomotor.hopping and not self.is_hopping`。
--     ⇒ 只在跳跃**开始的那一帧**发一次 StartHop（3954 行）。
--   ★ 为什么需要这个：跳跃是 locomotor 自己发起的（玩家点远处），
--     服务器并不知道客户端「打算跳」。这个函数是唯一的上报通道。
--   ★ 3952 行 `embarker:GetEmbarkPosition()` —— 取得「登船点」坐标。
--     这不是跳跃目标，而是**当前所站的平台上的落点**（服务端的出发基准）。
function PlayerController:DoPredictHopping(dt)
    if ThePlayer == self.inst and not self.ismastersim then
		if self.locomotor then
--   ⚠ 3951 行 `self.inst.components.embarker` 无 nil 检查。
--     缓解：能 hopping 说明有 embarker 组件（Boarding 是 locomotor 的前置）。
--   ⚠ 3956 行 `self.is_hopping = self.locomotor.hopping` 每帧更新（边沿维护）。
			if self.locomotor.hopping and not self.is_hopping then
				local embarker = self.inst.components.embarker
                local disembark_x, disembark_z = embarker:GetEmbarkPosition()
                local target_platform = embarker.embarkable
                SendRPCToServer(RPC.StartHop, disembark_x, disembark_z, target_platform, target_platform ~= nil)
            end
			self.is_hopping = self.locomotor.hopping
        else
            self.is_hopping = false
        end
    end
end

--★ IsLocalOrRemoteHopping：`remote_vector.y == 6 or (locomotor and locomotor.hopping)`。
--   ★ 两个来源：远端玩家的跳跃标志（服务端）/ 本地的实际跳跃（客户端）。
--   ⇒ 这个函数被 4005（DoPredictWalking）、4127（DoDragWalking）、
--     4307（DoDirectWalking）三处调用 —— 「跳跃时不接受任何其他移动意图」。
function PlayerController:IsLocalOrRemoteHopping()
	return self.remote_vector.y == 6 or (self.locomotor ~= nil and self.locomotor.hopping)
end

--★★ 【DoClientBusyOverrideLocomote】busy 态的方向微调（客户端发送）。
--   3968-3971 行的注释解释了动机（莫比乌斯/密恐魔）。
--   ★★ 3983 行的边沿检测：摇杆松开时的**下一帧**才发「停止」消息。
--     `if self._last_busy_override_locomote_tick == tick - 1 then`
--   ⇒ 为什么要等一帧？因为松手瞬间客户端还不知道玩家是真松手还是抖了一下。
--     而 busy 态下没有 locomotion 的移动事件可依赖，只能靠 tick 比较。
--   ⚠ 疑似缺陷（帧率敏感）：若某帧 dt > 1（卡顿），tick 直接跳过 2，
--     `tick - 1` 不匹配 → 停止消息永不发 → 服务器持续按旧方向微调。
--     推理依据：3983 行的精确 tick 相等判断；GetTick() 在低帧率下可能跳号。
--     缓解：服务器侧 DoClientBusyOverrideLocomote 的对端（3823 行）在
--       not IsBusy 时会退出，故影响有限。
function PlayerController:DoClientBusyOverrideLocomote()
	--This is specifically for passing overridelocomote events to the
	--server when we're in a busy state and/or controls are disabled.
	--e.g. Moose tackle can be cancelled using directional input, but
	--     the state itself is still busy.
	if not self.ismastersim and
		self.handler ~= nil and
		self.classified and
		self.classified.busyremoteoverridelocomote:value()
	then
		local dir = GetWorldControllerVector()
		local tick = GetTick()
		if dir then
			self._last_busy_override_locomote_tick = tick
			self:RemotePredictOverrideLocomote(math.atan2(-dir.z, dir.x) * RADIANS)
		else
			if self._last_busy_override_locomote_tick == tick - 1 then
				self:RemotePredictOverrideLocomote(nil, false)
			end
			self._last_busy_override_locomote_tick = nil
		end
	end
end

--★ DoClientBusyOverrideLocomoteClick：左键版（3992 行注释："e.g. Getting
--   out of hotspring" —— 从温泉里出来）。
--   与摇杆版的区别：单击**给一个方向**（3999 行 GetAngleToPoint），
--     不持续更新，也不发停止消息（因为是一次性动作）。
function PlayerController:DoClientBusyOverrideLocomoteClick(pos)
	--Left click version of the above.
	--e.g. Getting out of hotspring.
	if not self.ismastersim and
		self.handler and
		self.classified and
		self.classified.busyremoteoverridelocomoteclick:value()
	then
		self:RemotePredictOverrideLocomote(self.inst:GetAngleToPoint(pos))
	end
end

--★★★ 【DoPredictWalking】★★★ **本文件第二核心函数**（122 行）。
--   双端共用同一个函数，靠 `if self.ismastersim` 分成两个完全不同的实现：
--   · 服务端分支（4004-4106）：**消费**客户端的预测目标，驱动 locomotor，
--     并在误差过大时执行橡皮筋回滚。
--   · 客户端分支（4107-4123）：**生产**预测目标并发送。
--   ★ 由 3045 行每帧调用。
function PlayerController:DoPredictWalking(dt)
--   服务端分支入口。
    if self.ismastersim then
--   ★ 跳跃中不接受预测行走（三种移动手势互斥的第一处）。
		if self:IsLocalOrRemoteHopping() then
			return
		end
--   ★★ GetRemotePredictPosition 有值才继续 —— 意味着「客户端在预测移动」。
--     为 nil 时走 4095 行的「刚停止」处理分支。
		local pt = self:GetRemotePredictPosition()
		if pt then
--   x0,y0,z0 = 服务器当前的权威位置。
            local x0, y0, z0 = self.inst.Transform:GetWorldPosition()
--   ★ distancetotargetsq：服务器与客户端预测目标的**平面**距离平方。
--     ⚠ 注意用的是 util.lua:553 的 distsq(pt.x, pt.z, x0, z0) —— 忽略 y。
--     这是对的：B8 陷阱在这里被规避了（没有用 pt.y）。
            local distancetotargetsq = distsq(pt.x, pt.z, x0, z0)
--★ 停止阈值：floating（漂浮）时 0.0001（几乎精确），否则 0.05（≈0.22 格）。
--   ⚠ 疑似缺陷（精度过低）：0.05 的平方 = 0.22 格的停止容差。
--     对比 PREDICT_STOP_ERROR_DISTANCE_SQ = 0.25（0.5 格）。
--     0.22 意味着玩家停下时服务器位置与目标的差可达 0.22 格 ——
--     这在视觉上几乎不可见（角色碰撞半径 0.5），可接受。
--     但注意这是**每帧**判据，所以会持续收敛到 0.22 格内。
--   推理依据：4012 行硬编码 0.05 而非引用任何 TUNING 或本文件常量；
--     与 4098 行引用 PREDICT_STOP_ERROR_DISTANCE_SQ 的风格不一致。
			local stopdistancesq = self.inst.sg:HasStateTag("floating") and 0.0001 or 0.05

--★★★ 【pt.y == 5 分支】★ 这是 B8 最直接的消费者。
--   y==5 的含义（5801 行设置）：「客户端要开始执行动作，预测目标被冻结」。
--   条件：正在执行动作（locomotor 或实体有 bufferedaction）或状态图不在 idle/moving。
--   ⇒ 动作优先于移动：先把三个移动标志清掉。
--   ⚠ 但 4023-4026 行：只有在**距离已经够近**时才清 remote_vector.y，
--     否则保留让服务器继续走过去。
--   ⇒ 逻辑：「走到位再停下开始动作」—— 这是「走过去砍树」的时序保证。
			if pt.y == 5 and (
				self.locomotor.bufferedaction ~= nil or
                self.inst.bufferedaction ~= nil or
				not self.inst.sg:HasAnyStateTag("idle", "moving")
			) then
                --We're performing an action now, so ignore predict walking
                self.directwalking = false
                self.dragwalking = false
                self.predictwalking = false
                if distancetotargetsq <= stopdistancesq then
                    self.remote_vector.y = 0
					self:ClearRemotePredictData()
                end
                return true
            end

--★ 4030-4032 行 `if pt.y < 5 then self.inst:ClearBufferedAction() end`：
--   ★★★ **移动优先于动作**：只要还在预测行走（y=3/4），就清掉缓冲动作。
--     实体脚本的 ClearBufferedAction（entityscript.lua:1563）会 Fail 掉它。
--   ⇒ 这实现了「按方向键取消刚缓冲的动作」，是玩家能中途改主意的基础。
--   ⚠ 与 4014-4028 的顺序：y==5（要执行动作）先判并 return，
--     所以只有 y=3/4（纯移动）才会走到 4030 行清动作。二者互补。
            if pt.y < 5 then
                self.inst:ClearBufferedAction()
            end

--★ 4034 行 `local dir = math.atan2(z0 - pt.z, pt.x - x0) * RADIANS`：
--   从当前位置指向目标的角度。★ 这是 atan2(y, x) 的标准形式，
--     但引擎坐标系 Z 相反 ⇒ 结果的角度与「屏幕方向」差一个镜像。
--   ⇒ 与 1654 行、3601-3601 行的同一约定保持一致。
			local dir = math.atan2(z0 - pt.z, pt.x - x0) * RADIANS
--★★ 【4035-4050：未到达 vs 已到达】
--   未到达（distancetotargetsq > stopdistancesq）：
--     · RunInDirection(dir)（全速跑向目标）
--     · 记录 remote_predict_dir（供 4039 行用过冲检测）
--   已到达：
--     · 若「方向偏转 ≥90°」且 remote_authority → 直接瞬移到目标
--     · 否则 SetMoveDir(dir)（只转向不移动，用于「最后一点点」对齐）
--     · Stop({force_idle_state = true}) —— ★ 注释："so that this tiny motion
--       was meant to cancel an action" —— 强制进 idle 态是为了中断动作。
            if distancetotargetsq > stopdistancesq then
				self.locomotor:RunInDirection(dir)
				self.remote_predict_dir = dir
            else
--★★★ 【4039-4043：过冲瞬移（overshoot 纠正）】★ remote_authority 的特权。
--   条件：① remote_authority（房主/好友，见 94-98 行）
--     ② 有 remote_predict_dir（之前在走）
--     ③ DiffAngle(dir, remote_predict_dir) >= 90（方向反了）
--   ⇒ 推断：「玩家原本往东走，现在突然要往西走」，
--     且我们已经过了目标点 → 说明目标点是过期数据 → 直接瞬移。
--   ★★ 4084-4088 行的注释解释了这个特权为何**不能**推广：
--     "--V2C: don't override rubberband, otherwise server teleports will also
--      get stomped by client prediction"
--     → 翻译：**不要覆盖橡皮筋**（4082 行的逻辑），否则服务器自己的瞬移
--       也会被客户端预测「踩掉」。
--     被注释掉的代码（4085-4088 行）就是「不分 remote_authority 一律瞬移」
--       的旧实现 —— 它曾导致服务器传送被预测覆盖，已被移除。
--   ⚠ 这条注释是本项目重点（「V2C: don't override rubberband」这个坑）
--     的原始证据，务必与 4082-4091 行一起读。
--   ⚠ 但 4039 行的**瞬移本身**仍在，且不受「不覆盖橡皮筋」约束 ——
--     因为它只在这条特定路径上。若服务器同时在做传送（4162 行的 teleport），
--     且玩家刚好在 remote_authority + 反向移动，就会被拉回客户端的旧目标。
--     ⇒ 这是「传送 vs 预测」冲突的**残留漏洞**。
				if self.remote_authority and self.remote_predict_dir and DiffAngle(dir, self.remote_predict_dir) >= 90 then
					--overshot?
					--FIXME(JBK): Boat handling.
					--FIXED(V2C): Remote predict position now resolves platform relative positions from client.
					self.inst.Transform:SetPosition(pt.x, 0, pt.z)
				else
					self.locomotor:SetMoveDir(dir)
				end
                --Destination reached, queued (instead of immediate) stop
                --so that prediction may be resumed before the next frame
                self.locomotor:Stop({ force_idle_state = true }) --force idle state in case this tiny motion was meant to cancel an action
            end

--   ★★ 4052-4053 行注释解释了「为什么服务端要伪造客户端的手势标志」：
--   "Even though we're predict walking, we want the server to behave
--    according to whether the client thinks he's direct/drag walking"
--   ⇒ 服务端的 directwalking/dragwalking/predictwalking 三个标志，
--     **来源是客户端的 remote_vector.y**，而不是服务器自己的输入。
--   ★★ 这就是「意图镜像」：服务端用客户端的手势标志来驱动自己的逻辑，
--     因为那些逻辑（攻击范围 1826 行、FindEntity 半径 2135 行等）
--     必须与客户端看到的一致，否则动作校验会失败。
            --Even though we're predict walking, we want the server to behave
            --according to whether the client thinks he's direct/drag walking
--★ 4054-4075 行：把 remote_vector.y（3/4/其他）翻译成三个布尔手势标志。
--   ★★ 这段是 3694 行「y 是 flag」这一原始设计的**忠实实现**，
--     也是 B8 缺陷仍然存活的原因：
--     ① 它被嵌在「服务端伪造客户端手势」的逻辑里，语义上必须读 y
--     ② 它同时被 3737 行当作「是否在预测」的门槛
--     ③ 它还被 5801 行写入 5 来表达「正在执行动作」
--     三者叠加使 y 无法被安全地改成别的语义。
            if pt.y == 3 then
                if self.directwalking then
                    self.time_direct_walking = self.time_direct_walking + dt
                else
                    self.time_direct_walking = dt
                    self.directwalking = true
                    self.dragwalking = false
                    self.predictwalking = false
                end

--★ 4064-4066 行：直接行走超过 0.2 秒 → 清战斗目标。
--   ⇒ 「持续按方向键走路时自动脱战」。
--   ⚠ 但 4064 行的攻击状态检查与 3035 行的 boathopping 豁免不同构，
--     说明这段逻辑加了不止一次补丁。
                if self.time_direct_walking > .2 and not self.inst.sg:HasStateTag("attack") then
                    self.inst.components.combat:SetTarget(nil)
                end
            elseif pt.y == 4 then
                self.directwalking = false
                self.dragwalking = true
                self.predictwalking = false
            else
                self.directwalking = false
                self.dragwalking = false
                self.predictwalking = true
            end

--★★★ 【4077-4092：停止检测 / 橡皮筋回滚】★ 本项目重点。
--   --Detect stop, teleport, or prediction errors /
--   --Cancel the cached prediction vector and force resync if necessary
--   → 三个不同的终止原因走同一段代码：
--     ① 停止：距离 ≤ stopdistancesq
--     ② 橡皮筋：距离 > 4 格
--     ③ 传送：服务器自己把玩家挪走了（距离自然变得很远）
            --Detect stop, teleport, or prediction errors
            --Cancel the cached prediction vector and force resync if necessary
--★ ① 停止：y=0 + 记录 stop_tick（供 4095 行下一帧的微调）。
--   ⚠ 注意这里**没有** ClearRemotePredictData —— 有意为之，
--     因为下一帧（4095 行）还要用 stop_tick 做最后一次位置微调。
            if distancetotargetsq <= stopdistancesq then
                self.remote_vector.y = 0
				self.remote_predict_stop_tick = GetTick()
--★★★★ 【4082-4091：橡皮筋回滚】★★★ 本项目重点（bug-patterns B7/B8 的核心）。
--   条件：`distancetotargetsq > RUBBER_BAND_DISTANCE_SQ`（> 16，即 > 4 格）。
--   动作：
--     ① remote_vector.y = 0（放弃预测意图）
--     ② Physics:Teleport(当前世界位置)（★ 见下）
--   ★★ 4084 行的 --V2C 注释是本项目的关键警告：
--     "--V2C: don't override rubberband, otherwise server teleports will also
--      get stomped by client prediction"
--   → 翻译：**不要覆盖橡皮筋**。否则服务器自己的传送（传送门/复活/传送带）
--     会被客户端的预测意图「踩掉」——因为传送后玩家离预测目标很远，
--     橡皮筋逻辑会把它拉回客户端发来的旧坐标。
--   ⇒ 这是「teleport 与 rubberband 的优先级」问题：
--     ★★★ 传送必须**赢**，橡皮筋必须**让步**。
--   ⇒ 4085-4088 行是被注释掉的旧代码（无条件 SetPosition 到 pt），
--     4089-4091 行是修复后的实现（Physics:Teleport 到**当前**位置）。
--   ⚠★ 4090 行的 `self.inst.Physics:Teleport(self.inst.Transform:GetWorldPosition())`：
--     ★ 这是「零位移自愈」—— 把物理位置强行对齐到 Transform 位置。
--     物理与 Transform 是引擎的两套坐标系（Transform 是逻辑位置，
--     Physics 是 AABB 碰撞体位置）。传送后 Transform 更新了但 Physics 可能
--     还需要一帧。此调用立即同步二者。
--   ⇒★★ 完整语义：「放弃预测（y=0）+ 让物理追上逻辑（Teleport 到当前）」
--     ——注意**没有**把玩家拉回预测目标，而是拉回**服务器的权威位置**。
--     这正是「服务器胜出」的实现方式：不回滚到客户端，而是停在原地。
--   ⚠ 副作用：客户端此时会在自己的下一帧发现「服务器位置与我的预测差 > 4 格」，
--     触发客户端侧的同步（引擎层的 replicated transform 插值/硬切）。
--     玩家看到的是「突然被拉回」。
--   ⚠⚠ 潜在问题：若服务器传送与客户端正常行走**同时**发生，
--     客户端仍会每帧发送旧的预测目标（3930 行），服务器每次都判定超距、
--     每次都走 4082 分支 → Physics:Teleport 每帧调用 →
--     可能与传送的插值动画打架。
--     缓解：4095 行的 stop 流程与 remote_predict_stop_notified 会终止预测。
--     但若客户端持续发新坐标（玩家仍按着方向键），notified 会被 3794 行重置。
--     推理依据：3794 行 `self.remote_predict_stop_notified = isstop` 每次都赋值；
--       3922-3933 行只要 x/z 变化就会重发。
--   ⇒ 真正的解法是客户端侧的 3924 行末段条件（y==0 时不再发）——
--     而这正是 3005 行分析出的「卡死」隐患的另一面：它同时也是这个循环的
--     **终止条件**。设计上是一石二鸟，但过于脆弱。
            elseif distancetotargetsq > RUBBER_BAND_DISTANCE_SQ then
                self.remote_vector.y = 0
				--V2C: don't override rubberband, otherwise server teleports will also get stomped by client prediction
				--if self.remote_authority then
					--FIXME(JBK): Boat handling.
					--FIXED(V2C): Remote predict position now resolves platform relative positions from client.
				--	self.inst.Transform:SetPosition(pt.x, 0, pt.z)
				--else
					self.inst.Physics:Teleport(self.inst.Transform:GetWorldPosition())
				--end
            end

            return true
--★★ 【4095-4106：停止后的位置微调】
--   触发：pt 为 nil（模式已回 0）但 stop_tick 有值。
--   4096 行 GetRemotePredictStopXZ **只在停止后的紧接一帧有效**（3760 行）。
--   4098 行的三重要求：
--     ① 状态图处于 idle 或 floating（不能还在跑）
--     ② 距离 ≤ PREDICT_STOP_ERROR_DISTANCE_SQ（0.25，即 0.5 格）
--   ⇒ 通过则 SetPosition(x1, 0, z1) —— 把玩家吸到客户端最后说的位置。
--   ★ 这是「服务器主动把玩家向客户端拉近 0.5 格」的补偿，
--     用于消除「停下时的落点误差」。
--   ⚠ 4099-4100 行又出现 FIXME(JBK): Boat handling + FIXED(V2C) 注释 ——
--     第三处。与 4041/4086/5794 相同，说明船只场景反复出问题。
--   ⚠ 4105 行 `self.remote_predict_stop_tick = nil` 在 if 块**外面** ——
--     即使 x1 为 nil 也会清（4103 的 ClearRemotePredictData 也在里面）。
--     ⇒ 若 4096 行返回 nil（tick 不匹配），ClearRemotePredictData 不会被调，
--       但 stop_tick 已被清。结果：remote_predict_dir 等字段残留。
--     推理依据：4103 行在 `if x1 then` 内，4105 行在 if 外。
--     实际后果轻微：下一次 OnRemotePredictWalking 会重置这些字段（3792-3793）。
		elseif self.remote_predict_stop_tick then
			local x1, z1 = self:GetRemotePredictStopXZ()
			if x1 then
				if self.inst.sg:HasAnyStateTag("idle", "floating") and self.inst:GetDistanceSqToPoint(x1, 0, z1) <= PREDICT_STOP_ERROR_DISTANCE_SQ then
					--FIXME(JBK): Boat handling.
					--FIXED(V2C): Remote predict position now resolves platform relative positions from client.
					self.inst.Transform:SetPosition(x1, 0, z1)
				end
				self:ClearRemotePredictData()
			end
			self.remote_predict_stop_tick = nil
        end
--★★ 【4107-4123：客户端分支】★★ 生产预测目标并发送。
--   守卫：CanLocomote（760 行）—— 无预测能力则不发。
	elseif self:CanLocomote() then
--★ 4108 行 `sg:HasAnyStateTag("moving", "floating_predict_move")`：
--   ★★ floating_predict_move 是一个**专门为预测设计的虚拟状态标签**。
--   为什么需要：漂浮时（坐船/泳圈）真实状态图可能没有 moving 状态，
--     用它能让 OnUpdate 继续产生预测目标。
--   ⇒ 这说明「移动预测」与「状态图」的耦合是通过**标签**解开的。
		if self.inst.sg:HasAnyStateTag("moving", "floating_predict_move") then
--★★ 4109 行 `self.inst.Transform:GetPredictionPosition()`：
--   ★★ 不是 GetWorldPosition()！GetPredictionPosition 是**引擎为客户端
--     预测专门维护的位置**（客户端实体的 transform 在预测时会给出预测值）。
--   ⇒ 这是「客户端预测」的引擎级入口：Klei 在 C++ 层做了一套预测位置，
--     Lua 侧只需读取并上报。
--   ⚠ 与 5753 行的对照：那里**刻意**用 GetWorldPosition 并注释
--     "--V2C: not GetPredictionPosition()"（因为引擎已修正过本地位置）。
--     ⇒ 两处的选择不同，说明「GetPredictionPosition 在何时可信」有微妙差异。
--   ⚠ 这个差异本身就是 B8 类问题的表现：同一个 API 在两处被相反地使用。
			local x, y, z = self.inst.Transform:GetPredictionPosition()
--★ 4110 行的 isstart = `locomotor:GetTimeMoving() == 0`：
--   ★ 「刚开始移动」（累计移动时间为 0）= isstart。
--     这让服务器知道「这是新一段行走的开始，可以重启超时计时器」。
--   PopOverrideTimeMoving（locomotor.lua:452）取出并清空覆盖的移动时长。
			self:RemotePredictWalking(x, z, self.locomotor:GetTimeMoving() == 0, self.locomotor:PopOverrideTimeMoving())
--★ 4111-4112 行记录本次的时间戳与手势，供 4119 行补发 isstop 用。
			self.client_last_predict_walk.tick = GetTick()
			self.client_last_predict_walk.direct = self.directwalking
--★ 4113-4122 行：上一帧在移动、本帧不在 → 补发一次 isstop。
--   4114-4117 行的守卫：
--     ① 状态图 idle 或 floating
--     ② 不是 busy 也不是 boathopping
--     ③ tick + 1 == GetTick()（★ 必须紧接着上一帧）
--   ⚠ 4116 行的 tick 精确判断与 3983 行同款，有同样的帧率敏感隐患。
--   ★ 4119 行传 overridedirect = client_last_predict_walk.direct：
--     保证 isstop 那条消息的标签（3 或 4）与之前的一致，
--     否则 3924 行的去重会认为「标签变了」而多发一条。
		elseif self.client_last_predict_walk.tick then
			if self.inst.sg:HasAnyStateTag("idle", "floating") and
				not (self:IsBusy() or self.inst:HasTag("boathopping")) and
				self.client_last_predict_walk.tick + 1 == GetTick()
			then
				local x, y, z = self.inst.Transform:GetPredictionPosition()
				self:RemotePredictWalking(x, z, self.locomotor:GetTimeMoving() == 0, self.locomotor:PopOverrideTimeMoving(), self.client_last_predict_walk.direct, true)
			end
			self.client_last_predict_walk.tick = nil
        end
    end
end

--★★ 【DoDragWalking】鼠标左键按住拖地走。
--   ★ 由 3046 行调用（仅当 DoPredictWalking 返回 false 时）。
--   ★★ 拖拽是**鼠标独占**的手势（4134 行 draggingonground，鼠标模式）。
--     而 dragwalking 标志本身是双端的（服务端由 y==2 反推，4067 行）。
function PlayerController:DoDragWalking(dt)
--   ★★ 4127 行两个守卫：跳跃中 或 状态标签 nodragwalk（不允许拖拽走）。
--     nodragwalk 用于「必须站着不动才能操作」的场景（如某些施法）。
	if self:IsLocalOrRemoteHopping() or (self.inst.sg and self.inst.sg:HasStateTag("nodragwalk")) then
		return
	end
    local pt = nil
--★ 4131-4137 行：三个来源取目标点。
--     ① handler == nil（远端玩家）→ GetRemoteDragPosition（y==2 的信封）
--     ② draggingonground（鼠标本地拖拽）→ TheInput:GetWorldPosition（实时鼠标）
--     ③ 都不满足 → pt 为 nil → 不走（返回 nil）
--   ⚠ 但 4131 行还有 `self.locomotor == nil or self:CanLocomote()`：
--     ★★ **无 locomotor 的客户端不能拖拽走**。
--     推理依据：无 locomotor 就没有移动能力。这是无 locomotor 客户端的
--       能力削减之一（另一个是 4107 行的 CanLocomote）。
    if self.locomotor == nil or self:CanLocomote() then
        if self.handler == nil then
            pt = self:GetRemoteDragPosition()
        elseif self.draggingonground then
            pt = TheInput:GetWorldPosition()
        end
    end
    if pt ~= nil then
        local x0, y0, z0 = self.inst.Transform:GetWorldPosition()
--★ 4140 行 `distsq(pt.x, pt.z, x0, z0) > 1`：
--   ★★ 已经站在 1 格以内就不动。1 是**平方**（0 格 = 重合，1 格 = 1 单位）。
--     ⇒ 拖拽走的死区是 1 单位（1 格），比预测走的 0.22 格大得多。
--   ⇒ 设计：拖拽是「粗粒度」手势，玩家在目标附近时不该来回抖。
--   ⚠ 4141 行 ClearBufferedAction：拖拽移动会取消缓冲动作（同 4030 行思路）。
        if distsq(pt.x, pt.z, x0, z0) > 1 then
            self.inst:ClearBufferedAction()
            if not self.ismastersim then
                self:CooldownRemoteController()
            end
            if self:CanLocomote() then
--   ★ 4146 行 `RunInDirection(self.inst:GetAngleToPoint(pt))`：
--     ★ 用 GetAngleToPoint 而不是手算 atan2 —— 这是引擎提供的便捷函数。
--     对比 4034 行手算 atan2。两处等价但写法不同（历史遗留）。
                self.locomotor:RunInDirection(self.inst:GetAngleToPoint(pt))
            end
        end
        self.directwalking = false
        self.dragwalking = true
        self.predictwalking = false
--★★ 4152-4156 行：★ **远端与本地的镜像处理**。
--   服务端 → CancelPredictMoveTimer（4153 行，注释 "remote drag walking,
--   means client is not predicting"）。
--     ★★ 这行注释揭示了一个重要事实：
--       **拖拽行走永远没有客户端预测**。
--       因为客户端的鼠标位置每帧都在变，无法预测「下一帧鼠标在哪」。
--       所以拖拽是「客户端发坐标、服务器照做」的纯远程驱动模式。
--   无 locomotor 的客户端 → RemoteDragWalking（4155 行，发 RPC）。
--   ⇒ ★★ 对比：direct 行走有预测（locomotor 自带），drag 行走没有。
--     这是三种移动手势里唯一的「非预测」模式。
        if self.ismastersim then
            self.locomotor:CancelPredictMoveTimer() --remote drag walking, means client is not predicting
        elseif self.locomotor == nil then
            self:RemoteDragWalking(pt.x, pt.z)
        end
        return true
    end
end

--★ 【DoBoatSteering】船上操舵。与行走的双端分派结构相同（4164-4168）。
--   ★ 4167 行手柄模式用 GetWorldControllerVector（真实摇杆），
--     远端玩家用 GetRemoteDirectVector（y==1 的信封）——
--     ★★ 操舵**复用了 direct walking 的编码**（y=1）！
--     4217 行发的 RPC 是 RPC.SteerBoat（不是 DirectWalking）。
--   ⚠ 疑似缺陷（编码复用）：y==1 同时表示「直接行走」和「操舵」。
--     区分靠上下文（服务器在 3052 行根据 steeringboat 标签决定如何解读）。
--     推理依据：3903 行 RemoteDirectWalking 设 y=1；
--       4177 行 SendRPCToServer(RPC.SteerBoat, ...) **不设** remote_vector.y；
--       所以远端玩家的 y 仍是什么就什么，只有 y==1 时 4165 行才有值。
--     ⇒ 实际：远端玩家在船上时，其 y 必须是 1（由 4306 行 DoDirectWalking 的
--       4377 行设置？不对，4377 是服务端分支）。
--     ⚠ 这里存在一个真实的不一致：远端玩家的操舵方向**没有经过 remote_vector**，
--       直接由 RPC.SteerBoat（networkclientrpc.lua:508）传给 steeringwheeluser。
--       所以 4165 行在服务端永远是 nil（除非同时在 direct walking）。
--     ⇒ 结论：DoBoatSteering 的 handler==nil 分支（4165 行）实际是死代码。
--     推理依据：4171-4178 行的服务端分支直接用 dir 而不查 remote_vector；
--       而 DoBoatSteering 只在 OnUpdate:3076 被调用（双端都跑），
--       服务端进入该分支需要 self.handler == nil（恒真）且 dir 非 nil（来自4165）。
--       4165 行要非 nil 必须 remote_vector.y==1，即同时在直接行走，
--       而 3052 行的条件是 HasTag("steeringboat")，此时 3062 行 DoDirectWalking
--       不会被调用（被 3063/3075 分支替代）⇒ remote_vector.y 不可能为 1。
--     ⇒ 死代码的**严格**证明依赖「3062 行不会被调用」这一点。
function PlayerController:DoBoatSteering(dt)
    local dir = nil

    if self.handler == nil then
        dir = self:GetRemoteDirectVector()
    else
        dir = GetWorldControllerVector()
    end

    if dir ~= nil then
        if self.ismastersim then
--   steeringwheeluser 组件：只有「在船上且操作舵轮」时存在。
--   ⇒ 4173 行的 nil 检查是必要的（站在船上但没碰舵）。
            local steeringwheeluser = self.inst.components.steeringwheeluser
            if steeringwheeluser ~= nil then
                steeringwheeluser:SteerInDir(dir.x, dir.z)
            end
        else
            SendRPCToServer(RPC.SteerBoat, dir.x, dir.z)
        end
    end
end

--★★★ 【DoDoubleTapDir】双击方向键（默认「跳跃」）。由 3084 行调用。
--   双阈值设计是本函数的核心：
--   · deadzone（4189-4190）：与 GetWorldControllerVector 同源，用于「有没有在推」
--   · 0.8（4194）：「明确推到底」→ 算作一次 tap
--   · 0.6（4195）：「推了一些」→ 算作按住
--   ★★ 两个阈值之间（0.6~0.8）形成「灰色地带」，4197-4198 行的注释说明：
--     "NOTE: Intentional overlap in the down vs released handling below when
--      isoverdeadzone but not isoverminthreshold"
--     → 有意让按下与释放的处理在灰区重叠。
function PlayerController:DoDoubleTapDir(allowaction)
	local mem = self.doubletapmem

	local xdir = TheInput:GetAnalogControlValue(CONTROL_MOVE_RIGHT) - TheInput:GetAnalogControlValue(CONTROL_MOVE_LEFT)
	local ydir = TheInput:GetAnalogControlValue(CONTROL_MOVE_UP) - TheInput:GetAnalogControlValue(CONTROL_MOVE_DOWN)

	--This is for the GetWorldControllerVector() deadzone
	local deadzone = TUNING.CONTROLLER_DEADZONE_RADIUS
	local isoverdeadzone = math.abs(xdir) >= deadzone or math.abs(ydir) >= deadzone

	--This is for double tap which uses different thresholds
	local magsq = xdir * xdir + ydir * ydir
	local isovermaxthreshold = magsq >= 0.8 * 0.8
	local isoverminthreshold = magsq >= 0.6 * 0.6

	--NOTE: Intentional overlap in the down vs released handling
	--      below when isoverdeadzone but not isoverminthreshold

--   ★★ 4201 行的条件 `isoverdeadzone or isoverminthreshold`：
--     用 deadzone（0.2?）**或** 0.6。死区值远小于 0.6，
--     所以这个 or 实质上被 isoverminthreshold 主导。
--   ⚠ 疑似缺陷（死条件）：isoverdeadzone 永远为真（只要在推），
--     故整个分支等价于 `if isoverminthreshold then`。
--     推理依据：magsq >= 0.36 ⟹ |xdir| 或 |ydir| ≥ 0.6 > deadzone；
--       而 TUNING.CONTROLLER_DEADZONE_RADIUS 的典型值 < 0.6。
--     除非玩家把死区调得 > 0.6（引擎允许），否则 isoverdeadzone 冗余。
--     影响：极小（若死区极大则行为不同），属冗余而非错误。
	--Handle dir pressed down
	if isoverdeadzone or isoverminthreshold then
		local isnewtap = not mem.down and isovermaxthreshold

		local dir
		if mem.dir then
			dir = TheCamera:GetRightVec() * xdir - TheCamera:GetDownVec() * ydir
			--dir:Normalize() --don't need since we're only testing angle

--★ 4209-4211 行：方向角度差超过阈值 → 认为是「转了个方向」而非「双击」。
--   阈值随推杆幅度变化：推到底（0.8）时 60°，轻推（0.6）时 90°。
--   ⇒ 推得越满，允许的角度变化越大（更容易判定为双击）。
			local angle = math.atan2(dir.z, -dir.x)
			local lastangle = math.atan2(mem.dir.z, -mem.dir.x)
			local threshold = (isovermaxthreshold and PI / 3) or (isoverminthreshold and PI / 2) or PI
			if DiffAngleRad(angle, lastangle) >= threshold then
				--angle changed too much
				if isnewtap then
					--don't allowaction below, but still track the new tap
--★ 4214-4216 行：新 tap 但角度变化太大 → 只记录不执行动作（allowaction=false）。
--   注释 "don't allowaction below, but still track the new tap" ——
--     仍然要更新 tap 记录，否则玩家「推过去再推回来」永远双击不了。
					allowaction = false
				else
					--stop tracking until dir is released to start over
					mem.down = true
					mem.t = nil
					mem.dir = nil
				end
			end
		end

--★★ 4226-4269 行：tap 成功的处理。
--   4233 行 `CanEntitySeeTarget(self.inst, self.inst)` ——
--     ★★ 检查「玩家能否看见自己」＝ 没有全屏遮挡（UI/其他界面）。
--     与 GetWorldControllerVector 的摇杆检查配对（同在双击路径）。
--   ⚠ 这是一个 hack 式判据：把自己的可见性当作「UI 没挡着」的代理。
		if isnewtap then
			--successfully tapped
			local last_t = mem.t
			mem.down = true
			mem.t = nil
			mem.dir = nil

			if CanEntitySeeTarget(self.inst, self.inst) then
				if dir == nil then
					dir = TheCamera:GetRightVec() * xdir - TheCamera:GetDownVec() * ydir
				end
				dir:Normalize()

--★ 4239 行 GetDoubleClickActions(nil, dir, nil)[1] —— 传 dir（当前方向）。
--   ★ 与 4758 行的调用对比：那里传 (position, dir, target)，多了位置与目标。
--     ⇒ 双击方向键用**方向**，双击鼠标用**位置**。这是两条独立的双击路径。
				local dblclickact = self.inst.components.playeractionpicker:GetDoubleClickActions(nil, dir, nil)[1]
				if dblclickact then
					local t = GetTime()
--★ 4242-4243 行的双击判定：`allowaction and (last_t and t < last_t + DOUBLE_CLICK_TIMEOUT)`。
--   DOUBLE_CLICK_TIMEOUT = .5（constants.lua:2306）。
--   ⚠ 4245 行 `if self.ismastersim then`：服务端直接执行，
--     客户端发 RPC.DoubleTapAction（networkclientrpc.lua:1233）。
--   ★ 4252-4260 行：双击走 non_preview_cb / preview_cb 双路径，与其他按钮同构。
--     但 4258 行的 preview_cb **不发 canforce**（传 nil），因为跳跃不能强制。
					if allowaction and
						(last_t and t < last_t + DOUBLE_CLICK_TIMEOUT)
					then
						if self.ismastersim then
							self.inst.components.combat:SetTarget(nil)
						else
							local platform = dblclickact.pos.walkable_platform
							local pos_x = dblclickact.pos.local_pt.x
							local pos_z = dblclickact.pos.local_pt.z

							if self.locomotor == nil then
								dblclickact.non_preview_cb = function()
									SendRPCToServer(RPC.DoubleTapAction, dblclickact.action.code, pos_x, pos_z, dblclickact.action.canforce, dblclickact.action.mod_name, platform, platform ~= nil)
								end
							elseif self:CanLocomote() then
								dblclickact.preview_cb = function()
									SendRPCToServer(RPC.DoubleTapAction, dblclickact.action.code, pos_x, pos_z, nil, dblclickact.action.mod_name, platform, platform ~= nil)
								end
							end
						end
						self:DoAction(dblclickact)
					else
						mem.t = t
						mem.dir = dir
					end
				end
			end
		end
	end

--★ 4273 行的释放判定：`if mem.down and not (isoverminthreshold and
--   isoverdeadzone) then mem.down = false end`。
--   ⚠ 与 4201 行的分析同理，isoverdeadzone 冗余（被 isoverminthreshold 主导）。
--   ⇒ 真正决定「松手」的是 mag < 0.6。
	--Handle dir released
	if mem.down and not (isoverminthreshold and isoverdeadzone) then
		mem.down = false
	end
end

--【OnRemoteDoubleTapAction(actioncode, position, noforce, mod_name)】
--   ★ 与其他按钮不同：本函数**不查 mod 表**（4278 行的 actioncode 直接进
--     GetDoubleClickActions），靠 4286-4289 行的 code 匹配校验。
--   ⇒ 服务端在**同一位置**重算，若算出的动作 code 不符 → 丢弃。
--   ⚠ 4283 行 `GetDoubleClickActions(position)` 只传了 position，
--     漏掉了 dir 与 target —— 与客户端 4239 行的 `(nil, dir, nil)` 不对称。
--     推理依据：4239 行传 (nil, dir, nil)；4283 行传 (position)。
--     影响：若某动作依赖 dir 或 target（如「朝某方向跳」），服务端算不出来。
function PlayerController:OnRemoteDoubleTapAction(actioncode, position, noforce, mod_name)
	if self.ismastersim and self:IsEnabled() and self.handler == nil then
		self.inst.components.combat:SetTarget(nil)

		SetClientRequestedAction(actioncode, mod_name)
		local dblclickact = self.inst.components.playeractionpicker:GetDoubleClickActions(position, nil, nil)[1]
		ClearClientRequestedAction()

		dblclickact = (	dblclickact and
						dblclickact.action.code == actioncode and
						dblclickact.action.mod_name == mod_name and
						dblclickact)
					or nil

		if dblclickact then
			if dblclickact.action.canforce and not noforce then
--   4294-4296 行：force 时对齐到客户端预测位置（同 975/2334 行的范式）。
				dblclickact:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
				dblclickact.forced = true
			end
			self:DoAction(dblclickact)
		--elseif mod_name then
			--print("Remote double tap action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
--============================================================
-- 【第八段】4300-4700 行：双击 RPC 对端 / ★ DoDirectWalking / 相机 /
--   OnLeftUp / ★★ DoAction（所有按钮的汇合点）
--============================================================
		--else
			--print("Remote double tap action failed: "..tostring(ACTION_IDS[actioncode]))
		end
	end
end

--★★★ 【DoDirectWalking】★★ 直接行走（手柄摇杆 / 远端玩家的方向键）。
--   110 行，是三种移动手势里最复杂的一个 —— 因为它要处理「松开摇杆时不打断动作」。
--   结构：
--     ① 4307 跳跃中 → 立即返回
--     ② 4309-4343 ★ 松手护栏（recent_bufferedaction）的维护
--     ③ 4344-4414 三分支：护栏生效 / 摇杆有值 / 预测行走中 / 正在走
--   ★ 由 3062 行调用（仅在完全空闲时）。
function PlayerController:DoDirectWalking(dt)
--   ★ 跳跃中不接受直接行走（与 DoPredictWalking:4005、DoDragWalking:4127 同构）。
    if self:IsLocalOrRemoteHopping() then return end
    local dir = nil
--★ 4309-4313 行的三重「不能移动」条件：
--     ① 无 locomotor 或不能预测（CanLocomote）
--     ② controller_attack_override 非 nil（手柄持续攻击中）
--     ③ 状态图在 attack 中且扳机按着
--   ⇒ 这三条保证「战斗中的方向键」不触发行走。
    if (self.locomotor == nil or self:CanLocomote()) and
        not (self.controller_attack_override ~= nil or
            (self.inst.sg ~= nil and
            self.inst.sg:HasStateTag("attack") and
            self:IsControlPressed(CONTROL_CONTROLLER_ATTACK))) then
        if self.handler == nil then
            dir = self:GetRemoteDirectVector()
        else
            dir = GetWorldControllerVector()
        end
--★★★ 【4319-4343：★ 松手护栏（recent_bufferedaction）】本文件最精细的手感逻辑。
--   --Prevent cancelling actions when letting go of direct walking controls late
--   ★ 问题场景：
--     ① 玩家按住摇杆走向某处
--     ② 在快到时松开摇杆，**同一帧**点了「砍树」
--     ③ 摇杆松开导致 DoDirectWalking 进入「摇杆无值」分支（4389 行），
--        它会 locomotor:Stop() —— 而 Stop 会**连带清掉刚缓冲的砍树动作**。
--   ⇒ 护栏的作用：在「摇杆方向与按下动作时的方向一致」且「时间窗未过」时，
--     跳过 Stop，直接进入 4407 行的「重启缓冲动作」。
--   ★★ 这是玩家感知不到但确实存在的一段「保护期」。
        --Prevent cancelling actions when letting go of direct walking controls late
		local keep_recent_bufferedaction = false
--★★ 4321-4324 行的三重判定：
--     ① recent_bufferedaction.act 非 nil（有刚缓冲的动作）
--     ② recent_bufferedaction.t > dt（★ 保护时间还没耗尽）
--     ③ act 与实体当前的 bufferedaction 是**同一个对象**
--   ⇒ ② 的时间来自 5903 行：BUFFERED_ACTION_NO_CANCEL_TIME（1 帧）
--     或 BUFFERED_CASTAOE_TIME（0.5 秒，法术）。
--   ⚠ 4323 行的 `self.recent_bufferedaction.t > dt` 是**相对时间比较**：
--     t 在 OnLocomotorBufferedAction 设置为常量，此后每帧减 dt（4337 行）。
--     所以判定是「剩余时间 > 一帧」—— 若刚好剩一帧就失效。
--     这意味着保护窗口实际是 (常量 - 1帧)，对 1 帧的常量就是 0。
--     ⚠ 疑似缺陷（常量自相消）：BUFFERED_ACTION_NO_CANCEL_TIME = FRAMES + .0001，
--       4323 行在设置后的**第一帧**比较时 t 仍是 FRAMES+.0001 > dt(≈FRAMES) 成立，
--       成立一帧后 t ≈ .0001 < dt 就不成立。
--     推理依据：4323 行比较 t > dt；4337 行 t = t - dt；
--       5903 行 t = FRAMES + .0001。⇒ 恰好一帧的有效窗口。
--     这个「一帧窗口」正是 6 行注释里 "prevent instant cancelling" 的本意。
        if dir ~= nil and
			self.recent_bufferedaction.act ~= nil and
			self.recent_bufferedaction.t > dt and
			self.recent_bufferedaction.act == self.inst:GetBufferedAction() then
			--compare our analog dir
--   ★★ 4326-4334 行的两个方向比较：
--     精确相等（远端玩家：x/z 就是原始数值）
--     或角度差 ≤ 89°（4328 行 `self.isclientcontrollerattached` —— 注释说
--       "works for local player as well"）
--   ⇒ 89° 而非 90°：留 1° 的余量，避免浮点/量化误差导致误判。
--     这与 4039 行的 >= 90 形成对比（那边没有余量）。
			if self.recent_bufferedaction.x == dir.x and self.recent_bufferedaction.z == dir.z then
				keep_recent_bufferedaction = true
			elseif self.isclientcontrollerattached then --works for local player as well
				local angle = math.atan2(-dir.z, dir.x) * RADIANS
				local recent_angle = math.atan2(-self.recent_bufferedaction.z, self.recent_bufferedaction.x) * RADIANS
				if DiffAngle(angle, recent_angle) <= 89 then
					keep_recent_bufferedaction = true
				end
			end
		end
--   护栏生效 → 递减保护时间但**不**清标志。
		if keep_recent_bufferedaction then
			self.recent_bufferedaction.t = self.recent_bufferedaction.t - dt
--   护栏失效 → 立刻作废（4389 行的常规停止逻辑接管）。
        else
			self.recent_bufferedaction.act = nil
        end
    else
		self.recent_bufferedaction.act = nil
    end
--   ★★ 4344-4350 行：护栏**仍然生效**时的处理 ——
--     清三个手势标志（因为摇杆确实松了）但**保留** act；
--     4349 行 CooldownRemoteController()（无参 = 清零所有按键状态）。
--   ⇒ 关键：这里没有 locomotor:Stop()，所以缓冲动作存活。
	if self.recent_bufferedaction.act ~= nil then
        self.directwalking = false
        self.dragwalking = false
        self.predictwalking = false
        if not self.ismastersim then
            self:CooldownRemoteController()
        end
--★ 4351-4381 行：摇杆有值的正常行走。
--   4352 行 ClearBufferedAction：★ 有新输入 → 旧动作作废（覆盖护栏）。
--   ★ 4358-4360 行：
--     · 4359 行 SetBufferedAction(nil) —— 先清 locomotor 里的动作
--     · 4360 行 RunInDirection(-atan2(dir.z, dir.x)/DEGREES) —— ★ 负号 + DEGREES
--       注意方向：dir 是**屏幕**方向（GetWorldControllerVector 归一化后的），
--       而 RunInDirection 要的是角度，-atan2(z,x) 得到「屏幕右下 = 负角」。
--   ⚠ 4360 行与 4034 行的 atan2 **符号相反**：
--     4034 行 `atan2(z0 - pt.z, pt.x - x0)` 是「指向目标」；
--     4360 行 `-atan2(dir.z, dir.x)` 是「摇杆方向」。
--     两者在不同上下文使用，不冲突，但对照阅读容易困惑。
    elseif dir ~= nil then
        self.inst:ClearBufferedAction()

        if not self.ismastersim then
            self:CooldownRemoteController()
        end

        if self:CanLocomote() then
            self.locomotor:SetBufferedAction(nil)
            self.locomotor:RunInDirection(-math.atan2(dir.z, dir.x) / DEGREES)
        end

--   ★ time_direct_walking 计时：首次进入为 dt，之后累加。
--   ★★ 4364-4366 行的意义：「刚松开后立刻按住」不重置计时 ——
--     保证 0.2 秒的「脱战延迟」不会被快速点按绕过。
        if self.directwalking then
            self.time_direct_walking = self.time_direct_walking + dt
        else
            self.time_direct_walking = dt
            self.directwalking = true
            self.dragwalking = false
            self.predictwalking = false
        end

--★★ 4372-4381 行：**本机客户端 vs 服务端**的镜像分派。
--   4374 行：无 locomotor 的客户端 → RemoteDirectWalking（发方向 RPC）。
--   4376-4381 行：服务端 → CancelPredictMoveTimer（4377 行注释：
--     "remote direct walking, means client is not predicting"）
--     + 4378 行的脱战逻辑。
--   ⚠★ 与 4152-4153 行对比：拖拽的注释说「客户端没有预测」，
--     而直接行走**有**预测（客户端自己的 locomotor 在跑）。
--     两者的服务端处理因此不同：拖拽只取消计时器，
--       直接行走还要执行脱战。
        if not self.ismastersim then
            if self.locomotor == nil then
                self:RemoteDirectWalking(dir.x, dir.z)
            end
        else
            self.locomotor:CancelPredictMoveTimer() --remote direct walking, means client is not predicting
            if self.time_direct_walking > .2 and not self.inst.sg:HasStateTag("attack") then
                self.inst.components.combat:SetTarget(nil)
            end
        end
--★ 4382-4388 行：客户端在预测行走、但本函数被调到了（预测刚停）。
--   4383 行 `if locomotor.bufferedaction == nil then locomotor:Stop() end`：
--   ★★ **只清移动，不清动作**：有缓冲动作时保留。
--     注释语义：「停止移动但保持动作」。
--   ⚠ 但此处没有 locomotor nil 检查（4383 行）。缓解：4382 行已被 4309 行
--     的 CanLocomote 过滤（无 locomotor 时 4309 为假 → 不进本分支）。
    elseif self.predictwalking then
        if self.locomotor.bufferedaction == nil then
            self.locomotor:Stop()
        end
        self.directwalking = false
        self.dragwalking = false
        self.predictwalking = false
--★★ 【4389-4414：摇杆松开时的收尾】
--   4391-4392 行 CanLocomote + 无 override → locomotor:Stop()（**用 Stop 不用 Clear**）。
--   4393 行注释 "instead of self.locomotor:Clear()" ——
--     ★★ 关键设计：Stop 保留 bufferedaction，Clear 会丢掉它。
--     4394 行取出它，4407-4413 行在「清完手势标志后」重新 Push/Preview。
--   ⇒ 这就是松手护栏的**另一半**：即使护栏没生效，
--     也会用「Stop 而非 Clear + 手动重启」的方式保住刚缓冲的动作。
--   ⚠ 4391 行多了 `controller_attack_override == nil` 条件，
--     与 4420 行的 DoDirectStopWalking 不同（那里没有这个条件）。
    elseif self.directwalking or self.dragwalking then
		local buffaction
        if self:CanLocomote() and self.controller_attack_override == nil then
            self.locomotor:Stop()
			--instead of self.locomotor:Clear()
			buffaction = self.locomotor.bufferedaction
        end
        self.directwalking = false
        self.dragwalking = false
        self.predictwalking = false
--   4399-4404 行：客户端清按键状态 + 无 locomotor 时发停止 RPC。
--   ⚠ 4401-4403 行只在 locomotor == nil 时发 RPC ——
--     有 locomotor 的客户端不发，因为引擎会自己同步 locomotion 状态。
        if not self.ismastersim then
            self:CooldownRemoteController()
            if self.locomotor == nil then
                self:RemoteStopWalking()
            end
        end
		--restart any buffered actions that may have been pushed at the
		--same time as the user letting go of directwalking controls
		if buffaction then
			if self.ismastersim then
				self.locomotor:PushAction(buffaction)
			else
				self.locomotor:PreviewAction(buffaction)
			end
		end
    end
end

--★★ 【DoDirectStopWalking】★ 无 locomotor 客户端在 busy 时的停止补偿。
--   注释："for non-predicting clients, stopping during busy states"
--   五重条件（4419-4424）：
--     ① 非服务端
--     ② 正在 direct/drag 走
--     ③ locomotor == nil（★ 这就是「无 locomotor」的定义性判据）
--     ④ handler 存在（本机玩家）
--     ⑤ GetWorldControllerVector() == nil（摇杆确实松了）
--   ⇒ 这解释了「无 locomotor 客户端」的能力缺口：
--     它没有 locomotor 组件，所以 busy 期间（3041 行）必须靠 RPC 停住。
--for non-predicting clients, stopping during busy states
function PlayerController:DoDirectStopWalking()
	if not self.ismastersim and
		(self.directwalking or self.dragwalking) and
		self.locomotor == nil and
		self.handler and
		GetWorldControllerVector() == nil
	then
		self.recent_bufferedaction.act = nil
		self.directwalking = false
		self.dragwalking = false
		self.predictwalking = false
		self:CooldownRemoteController()
		self:RemoteStopWalking()
	end
end

--------------------------------------------------------------------------
--★ ROT_REPEAT = .25 / ZOOM_REPEAT = .1：相机旋转/缩放的最小间隔。
--   ★ 用 GetStaticTime（墙钟）而非 GetTime → 暂停时仍生效。
local ROT_REPEAT = .25
local ZOOM_REPEAT = .1

--★★ 【DoCameraControl】相机控制。由 OnWallUpdate(2631 行) 每墙钟帧调用。
--   ★ 双路径：SupportsControllerFreeCamera（自由视角手柄，4453-4477 行）
--     与传统按键（4479-4502 行）。
function PlayerController:DoCameraControl()
	local canzoom = TheCamera:CanControl()
	--V2C: exception for drone cam: zoom disabled, but rotate allowed
--   ★ 4441 行与 RotLeft/RotRight（1476/1495 行）同款守卫：
--     「不能控制相机 但 在用无人机」→ 仍允许旋转。
	if not (canzoom or self.inst:HasTag("using_drone_remote")) then
        return
    end

    local isenabled, ishudblocking = self:IsEnabled()
--   4446 行：既没 enabled 也没 hudblocking → 放弃。
--     ★ 但 4445 行已经拿到了 isenabled/ishudblocking，而这里**只判 isenabled**，
--       与 601 行 OnControl 的 `if not isenabled and not ishudblocking` 不同。
--   ⚠ 差异：在 HUD 阻塞（如地图打开）时，OnControl 仍会放行部分按键，
--     但 DoCameraControl 完全不工作。这是有意的（地图里用自己的缩放）。
    if not isenabled and not ishudblocking then
		return
    end

    local time = GetStaticTime()
	local invert_rotation = Profile:GetInvertCameraRotation()

--   ★★ 4453 行的自由视角分支（4419-4477）：支持「按住旋转 + 垂直缩放」同时进行。
--     移动端/主机平台的常见需求（右摇杆转视角 + 扳机缩放）。
	if TheInput:SupportsControllerFreeCamera() then
		local xdir = TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ROTATE_RIGHT) - TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ROTATE_LEFT)
		local ydir = TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ZOOM_IN) - TheInput:GetAnalogControlValue(VIRTUAL_CONTROL_CAMERA_ZOOM_OUT)
		local absxdir = math.abs(xdir)
		local absydir = math.abs(ydir)
		local deadzone = TUNING.CONTROLLER_DEADZONE_RADIUS
--★ 4459 行 `absxdir >= deadzone and absxdir > absydir * 1.3`：
--   --favour zoom a bit more at diagonals
--   ★★ 1.3 的系数：对角线输入时**优先缩放**。
--   ⇒ 因为对角推时 x/y 都较大，若不加权则两者同时超阈值导致抖动。
--     1.3 意味着缩放方向需要比旋转方向推得更远才触发。
		if absxdir >= deadzone and absxdir > absydir * 1.3 then --favour zoom a bit more at diagonals
			local right = xdir > 0
			if invert_rotation then
				right = not right
			end
--   ★ 4464 行 Remap(min(1, absxdir), deadzone, 1, 2, 3)：
--     ★★ 把摇杆幅度映射到「每秒转 2~3 格」。死区处最慢，推满最快。
--     这是「模拟量旋转」的实现（对比传统分支的定步长 45°）。
			local speed = Remap(math.min(1, absxdir), deadzone, 1, 2, 3)
			if right then
				self:RotRight(speed)
			else
				self:RotLeft(speed)
			end
			self.lastrottime = time
		elseif canzoom and absydir > deadzone then
--   4472 行 Remap(min(1, absydir), deadzone, 1, 0, 0.65) → 缩放速度。
--   ★ 4473 行 ContinuousZoomDelta(ydir > 0 and -delta or delta)：
--     ★ 负号来源：摇杆「上」（ydir > 0）对应「放大」，而缩放是反向的。
			local delta = Remap(math.min(1, absydir), deadzone, 1, 0, 0.65)
			TheCamera:ContinuousZoomDelta(ydir > 0 and -delta or delta)
			self.lastzoomtime = time
		end
		return
	end

--   -- CharlesB: Not used right now
--   ⇒ 4480 行之后的传统按键分支在支持自由视角的手柄上是死代码。
--     但键盘玩家仍走这里（TheInput:SupportsControllerFreeCamera 为假）。
	-- CharlesB: Not used right now
    if --[[not self:IsControllerTargetingModifierDown() and ]] (self.lastrottime == nil or time - self.lastrottime > ROT_REPEAT) then
        if TheInput:IsControlPressed(invert_rotation and CONTROL_ROTATE_RIGHT or CONTROL_ROTATE_LEFT) then
            self:RotLeft()
            self.lastrottime = time
        elseif TheInput:IsControlPressed(invert_rotation and CONTROL_ROTATE_LEFT or CONTROL_ROTATE_RIGHT) then
            self:RotRight()
            self.lastrottime = time
        end
    end

--★ 4490-4502 行：滚轮/按键缩放。4492/4497 行的 craftingmenu.focus 检查
--   呼应 303-304 行 OnContinueFromPause 缓存的 zoomin_same_as_scrollup。
--   ⚠ 4492 行 `self.inst.HUD.controls.craftingmenu.focus` 没有 craftingmenu 的
--     nil 检查（只检查了 HUD 与 HUD.controls）。
--   ⚠ 疑似缺陷（潜在 nil）：若某个平台/模式下 controls.craftingmenu 未创建
--     （widgets/controls.lua:302-306 是在特定条件下 AddChild 的），
--     这里会崩。
--     推理依据：widgets/controls.lua:302-306 显示 craftingmenu 在 if/else 分支里
--       创建，存在未创建的可能。
--     影响：仅在 zoomin_same_as_scrollup 为真时才求值该表达式（短路），
--       故只在「缩放键映射到滚轮键」的手柄配置下触发。
	if canzoom and (self.lastzoomtime == nil or time - self.lastzoomtime > ZOOM_REPEAT) then
		if TheInput:IsControlPressed(CONTROL_ZOOM_IN) then
			if not self.zoomin_same_as_scrollup or (self.inst.HUD ~= nil and self.inst.HUD.controls ~= nil and not self.inst.HUD.controls.craftingmenu.focus) then
				TheCamera:ZoomIn()
				self.lastzoomtime = time
			end
		elseif TheInput:IsControlPressed(CONTROL_ZOOM_OUT) then
			if not self.zoomout_same_as_scrolldown or (self.inst.HUD ~= nil and self.inst.HUD.controls ~= nil and not self.inst.HUD.controls.craftingmenu.focus) then
				TheCamera:ZoomOut()
				self.lastzoomtime = time
			end
		end
	end
end

--★ IsWalkButtonDown：四个移动键任一按下。
--   ★ 用于 4516 行：「松开鼠标左键时若方向键还按着，就不停住」。
--     ⇒ 玩家「按住方向键 + 点地面 + 松鼠标」应该继续走而不是停。
local function IsWalkButtonDown()
    return TheInput:IsControlPressed(CONTROL_MOVE_UP) or TheInput:IsControlPressed(CONTROL_MOVE_DOWN) or TheInput:IsControlPressed(CONTROL_MOVE_LEFT) or TheInput:IsControlPressed(CONTROL_MOVE_RIGHT)
end

--★ 【OnLeftUp】鼠标左键抬起（由 4684 行 OnLeftClick(down=false) 调用）。
--   ⚠ 注意：**不是** RPC 的对端，是一个纯客户端的本地事件处理。
--   ⇒ 客户端的「松开鼠标」不需要通知服务器（服务器只关心最终位置）。
--   ★ 但 4528 行 RemoteStopControl(CONTROL_PRIMARY) 会发一个停止 RPC ——
--     因为 remote_controls 需要同步（服务端要用 IsControlPressed 判断攻击）。
function PlayerController:OnLeftUp()
    if not self:IsEnabled() then
        return
    end

	local buffaction
    if self.draggingonground then
--★ 4516 行 `CanLocomote() and not IsWalkButtonDown()`：
--   ★★ 「松开鼠标但方向键还按着 → 不 Stop」。
--     与 4319 行的松手护栏同源，但判据是**按键状态**而非时间窗。
--   ⇒ 两个护栏互补：护栏 1 用时间窗，护栏 2 用按键状态。
        if self:CanLocomote() and not IsWalkButtonDown() then
            self.locomotor:Stop()
			--instead of self.locomotor:Clear()
			buffaction = self.locomotor.bufferedaction
        end
        self.draggingonground = false
        self.startdragtime = nil
        TheFrontEnd:LockFocus(false)
    end
    self.startdragtime = nil

--   4527-4529 行：非服务端 → 通知服务器「鼠标左键松开」。
--   ★★ 这解释了为什么 remote_controls 里需要存按键的「按住时长」：
--     抬起事件让服务器能清掉它，否则 IsControlPressed 永远为真。
    if not self.ismastersim then
        self:RemoteStopControl(CONTROL_PRIMARY)
    end

	--restart any buffered actions that may have been pushed at the
	--same time as the user releasing draggingonground
	if buffaction then
		if self.ismastersim then
			self.locomotor:PushAction(buffaction)
		else
			self.locomotor:PreviewAction(buffaction)
		end
	end
end

--★★★ 【DoAction(buffaction, spellbook)】★★★ **所有按钮的最终汇合点**。
--   13379 行的 actions.lua 定义「有什么动作」，本文件定义「何时用哪个动作」，
--   而 DoAction 是「把选好的动作真正启动」的唯一入口。
--   结构（七步）：
--     ① 4546-4552 无 locomotor 客户端的 non_preview_cb 早期触发
--     ② 4554-4584 有效性检查（空 / 目标失效 / busy）
--     ③ 4586-4600 重复动作检查
--     ④ 4602-4604 攻击时记录 retarget
--     ⑤ 4606-4616 目标高亮闪烁（仅本机客户端）
--     ⑥ 4618-4627 自动装备 + 长按记录
--     ⑦ 4629-4644 ★ 三分支执行（PushAction / 无 locomotor / PreviewAction）
--   ⚠ 它被 20+ 处调用，是全文件耦合度最高的函数。
function PlayerController:DoAction(buffaction, spellbook)
--   --V2C: -New support for "non_preview_cb" on non-predicting clients.
--   --     -If there's no pre_action_cb, trigger the cb to send the RPC
--   --      right away, matching old behaviour.
--   ★★★ 这条 V2C 注释是**协议演进的直接证据**：
--     non_preview_cb 是后来为「无 locomotor 客户端」新增的回调字段，
--     而为保持向后兼容，需要在「没有 pre_action_cb」时立刻触发（等旧行为）。
--   ⇒ 理解要点：pre_action_cb 与 non_preview_cb 是**两种不同的 RPC 触发时机**：
--     · non_preview_cb → 不经 locomotor，到 DoAction 就发（立即）
--     · preview_cb     → 经 locomotor 缓冲，到达/动画完成才发（延迟）
	--V2C: -New support for "non_preview_cb" on non-predicting clients.
	--     -If there's no pre_action_cb, trigger the cb to send the RPC
	--      right away, matching old behaviour.
--★ 4546-4552 行：条件极其特殊 —— non_preview_cb 存在 且 无 pre_action_cb
--   且 无 locomotor。此时**立刻**触发回调（即发 RPC）。
--   ⚠ 4549 行的 `self.locomotor == nil` 是必要条件（否则预览路径会触发）。
	if buffaction and
		buffaction.non_preview_cb and
		buffaction.action.pre_action_cb == nil and
		self.locomotor == nil
	then
		buffaction.non_preview_cb()
	end

--   --Check if the action is actually valid. /
--   --Cached LMB/RMB actions can become invalid. /
--   --Also check if we're busy.
--   ★★ 「缓存的 LMB/RMB 动作可能失效」—— 因为 LMBaction 是上一帧算的（2827 行），
--     这一帧目标可能已被删除/销毁。
    --Check if the action is actually valid.
    --Cached LMB/RMB actions can become invalid.
    --Also check if we're busy.

	local valid = true
--★ 4559-4563 行：四个有效性判据（动作存在、invobject/target/doer 有效）。
--   ⇒ 即使动作原型有效，参与的实体也必须都还活着。
    if buffaction == nil or
        (buffaction.invobject ~= nil and not buffaction.invobject:IsValid()) or
        (buffaction.target ~= nil and not buffaction.target:IsValid()) or
		(buffaction.doer ~= nil and not buffaction.doer:IsValid())
		then
		valid = false
--★ 4565-4579 行：busy 时的例外 —— CASTAOE 允许重复施法。
--   4568 行 `local item = spellbook or buffaction.invobject`：
--     ★ spellbook 参数从 836/1036/4736 行一路传下来。
--     ⇒ DoAction 的第二个参数存在的唯一理由就是重复施法判定。
--   ★★ 4572 行 `self.inst:HasTag("canrepeatcast")` 是**玩家**标签而非物品标签 ——
--     意味着「这个角色能不能连射」是角色属性，与武器无关。
	elseif self:IsBusy() then
		if buffaction.action == ACTIONS.CASTAOE then
			--V2C: special case for repeat casting during busy state
			local item = spellbook or buffaction.invobject
			if not (item ~= nil and
					item.components.aoetargeting ~= nil and
					item.components.aoetargeting:CanRepeatCast() and
					self.inst:HasTag("canrepeatcast"))
				then
				valid = false
			end
		else
			valid = false
		end
	end

--   ★ 4582 行 `self.actionholdtime = nil`：
--     动作无效 → 取消长按起点 → 不会进入长按重复状态。
	if not valid then
		self.actionholdtime = nil
		return
	end

--★★ 【4587-4600 重复动作检查】★ 本文件防「连点」的最终防线。
--   四个比较：action 相同 / target 相同 / pos 相同。
--   4591-4592 行 `currentbuffaction.pos == buffaction.pos` 带注释：
--     "Note: see overloaded DynamicPosition:__eq function"
--     ★★ DynamicPosition 重载了 __eq —— 所以 == 比较的是坐标而非对象身份。
--     这是 actions.lua / bufferedaction 体系的一个精巧设计。
--   4594-4596 行的例外：
--     `not (currentbuffaction.ispreviewing and HasTag("idle") and sg:HasStateTag("idle"))`
--     ★ 若当前动作正在**客户端预览**且玩家处于 idle → 允许重复。
--   4597-4598 行注释："The 'not' bit is in case we are stuck waiting for
--   server to act but it never does" ——
--     ★ 即「如果服务器卡住了，我们要能重发」，否则玩家会觉得卡死。
    --Check for duplicate actions
    local currentbuffaction = self.inst:GetBufferedAction()
    if currentbuffaction ~= nil and
        currentbuffaction.action == buffaction.action and
        currentbuffaction.target == buffaction.target and
        (   (currentbuffaction.pos == nil and buffaction.pos == nil) or
            (currentbuffaction.pos == buffaction.pos) -- Note: see overloaded DynamicPosition:__eq function
        ) and
        not (currentbuffaction.ispreviewing and
            self.inst:HasTag("idle") and
            self.inst.sg:HasStateTag("idle")) then
        --The "not" bit is in case we are stuck waiting for server
        --to act but it never does
        return
    end

--★ ATTACK 动作时把 target 写进 sg.statemem.retarget（供 2635 行读）。
--   ⇒ 3140 行的链式攻击由此获得目标。
    if buffaction.action == ACTIONS.ATTACK and self.inst.sg then
        self.inst.sg.statemem.retarget = buffaction.target
    end

--★ 4606-4616 行：目标闪烁（表现层）。仅 handler ~= nil（本机客户端）。
--   4611 行的默认参数 .2/.125/.1：闪白强度/渐入/渐出时间（秒）。
--   4612 行 highlightflashaddoverride：模组可覆盖闪烁强度。
    if self.handler ~= nil and buffaction.target ~= nil then
        local highlight_guy = buffaction.target.highlightforward or buffaction.target
        if highlight_guy.components.highlight == nil then
            highlight_guy:AddComponent("highlight")
        end
        local flashadd, flashtimein, flashtimeout = .2, .125, .1
        if highlight_guy.highlightflashaddoverride then
            flashadd = highlight_guy.highlightflashaddoverride
        end
        highlight_guy.components.highlight:Flash(flashadd, flashtimein, flashtimeout)
    end

--★ 4619 行 `self.attack_buffer = nil`：
--   ★★ 「开始新动作 → 清掉待处理的攻击请求」。
--     优先级规则：任何非攻击动作都会丢弃之前的攻击请求。
    --Clear any buffered attacks since we're starting a new action
    self.attack_buffer = nil

--★ DoActionAutoEquip：先自动装备，再执行（见 4652 行）。
    self:DoActionAutoEquip(buffaction)

--★★ 【4623-4627 长按记录】`not instant and not invalid_hold_action and IsValid()`
--   三个否定条件：
--     · instant（瞬发动作，如走路/看）→ 不可长按重复
--     · invalid_hold_action（actions.lua:349）→ 显式禁止长按重发
--     · :IsValid() → 动作本身仍有效
--   ⇒ 只有「持续性动作」（挖矿/砍树/进食）会被记录为 lastheldaction。
    if not buffaction.action.instant and not buffaction.action.invalid_hold_action and buffaction:IsValid() then
        self.lastheldaction = buffaction
    else
        self.actionholdtime = nil
    end

--★★★ 【4629-4644 三个执行分支】
--   4629-4630 服务端：PushAction(buffaction, true) —— force_run=true
--   4631-4641 无 locomotor 客户端：手工触发 pre_action_cb + non_preview_cb
--   4642-4643 有 locomotor 客户端：PreviewAction(buffaction, true)
--   ⚠ 三分支都**没有 else**。若既不是服务端、locomotor ~= nil、
--     又不能 CanLocomote（4565 行的 busy 等），则**什么都不做** —— 
--     动作被静默丢弃。这是有意的（busy 时不排队）。
--   ★ 4638-4641 行的双重触发与 4546-4552 行的早期触发互补：
--     有 pre_action_cb → 在这里触发；无 pre_action_cb → 在 4546 行已触发。
    if self.ismastersim then
        self.locomotor:PushAction(buffaction, true)
	elseif self.locomotor == nil then
		--V2C: -New support for "non_preview_cb" on non-predicting clients.
		--     -If we have a pre_action_cb, only trigger the cb to send the
		--      RPC if we make it to here.
		--Backward compatibility:
		--     -If there is no "non_preview_cb", assume that pre_action_cb
		--      is manually triggered elsewhere.
		if buffaction.non_preview_cb and buffaction.action.pre_action_cb then
			buffaction.action.pre_action_cb(buffaction)
			buffaction.non_preview_cb()
		end
    elseif self:CanLocomote() then
        self.locomotor:PreviewAction(buffaction, true)
    end

--   LOOKAT（查看）完成后登记到「已查看」图鉴（TheScrapbookPartitions）。
--   ★ 2391 行的同款调用在 GetInspectButtonAction 路径上也有 ——
--     两处都记，说明「登记」既不在动作里也不在 RPC 里，而在调用点。
    if self.handler ~= nil and buffaction.action == ACTIONS.LOOKAT and buffaction.target then
		--assert(self.inst == ThePlayer)
        TheScrapbookPartitions:SetInspectedByCharacter(buffaction.target, self.inst.prefab)
    end
end

--★★★ 【DoActionAutoEquip】★ 自动装备的**黑名单式**实现（25 行全是排除）。
--   4654-4673 行：22 个条件全满足才自动装备。
--   ★ 结构性观察：**没有白名单，全是黑名单**。
--     ⇒ 后果：新增一个「不该自动装备」的动作，开发者必须记得改这里；
--       而新增一个「应该自动装备」的动作无需改动（默认会装备）。
--   ⇒ 好处：新动作默认获得自动装备行为（绝大多数动作确实如此）。
--   ⚠ 这是模组作者的**必读点**：自定义动作若不想要自动装备，
--     必须自己 patch 这个函数或用 invobject 的标签绕过。
function PlayerController:DoActionAutoEquip(buffaction)
    local equippable = buffaction.invobject ~= nil and buffaction.invobject.replica.equippable or nil
    if equippable ~= nil and
        equippable:EquipSlot() == EQUIPSLOTS.HANDS and
        not equippable:IsRestricted(self.inst) and
        buffaction.action ~= ACTIONS.DROP and
        buffaction.action ~= ACTIONS.COMBINESTACK and
        buffaction.action ~= ACTIONS.STORE and
        buffaction.action ~= ACTIONS.BUNDLESTORE and
        buffaction.action ~= ACTIONS.EQUIP and
        buffaction.action ~= ACTIONS.GIVETOPLAYER and
        buffaction.action ~= ACTIONS.GIVEALLTOPLAYER and
        buffaction.action ~= ACTIONS.GIVE and
        buffaction.action ~= ACTIONS.ADDFUEL and
        buffaction.action ~= ACTIONS.ADDWETFUEL and
        buffaction.action ~= ACTIONS.DEPLOY and
		buffaction.action ~= ACTIONS.DEPLOY_FLOATING and
        buffaction.action ~= ACTIONS.CONSTRUCT and
		buffaction.action ~= ACTIONS.ADDCOMPOSTABLE and
        buffaction.action ~= ACTIONS.EQUIPONBODY and
--   ★ 4672 行是唯一的复合条件：TOSS（投掷）除非物品带 keep_equip_toss。
--     ⇒ 多数投掷动作不自动装备（避免「扔石头顺手装备石头」），
--       但某些角色（如韦布斯特的球）可以。
		(buffaction.action ~= ACTIONS.TOSS or not equippable.inst:HasTag("keep_equip_toss")) and
		buffaction.action ~= ACTIONS.DECORATESNOWMAN
	then
        self.inst.replica.inventory:EquipActionItem(buffaction.invobject)
--   ★ 4676 行 autoequipped = true —— ★★ 这个标志的**关键用途在服务端**：
--     963-972 行（OnRemoteControllerActionButton）与 1213-1220 行
--     都在检查「lmb/rmb 中任一 code 匹配」，正是为了容忍自动装备导致的漂移。
--     若客户端没装备、服务端装备了（或反之），code 就会不匹配。
--   ⚠ 但 4652 行只在客户端执行（用 replica.inventory），
--     而 963 行的检查在服务端 —— 服务端怎么知道客户端是否自动装备了？
--   ⇒ 推理：服务端会**独立地**执行同一个自动装备逻辑（因为 DoAction:4621
--     在服务端也跑），所以两端同步装备 → code 一致。
--     这是「客户端预测 + 服务端独立重算」的又一处体现。
        buffaction.autoequipped = true
    end
end

--★★★ 【OnLeftClick(down)】鼠标左键。由 652 行 OnControl 分派。
--   ★★ 4681 行 `if not self:UsingMouse() then return end`：手柄模式完全忽略。
--   结构（140 行）：
--     ① 4681-4698 守卫（鼠标模式 / 抬起 → OnLeftUp / IsEnabled）
--     ② 4699-4719 建造放置 / HUD 元素
--     ③ 4724-4786 ★ 动作选择（AOE / 双击 / LMB / WALKTO 兜底）
--     ④ 4788-4793 地图动作
--     ⑤ 4795-4831 各动作的额外副作用（dragtime / retarget / 准星）
--     ⑥ 4833-4873 ★ 发送（三分支）
--     ⑦ 4875-4887 收尾（DoAction + 防闪烁 + busy 微调）
function PlayerController:OnLeftClick(down)
    if not self:UsingMouse() then
        return
--   ★ 4683-4686 行：抬起事件转给 OnLeftUp（4509 行）后立即返回。
--     ⇒ 与 622 行的统一抬起处理不同：**鼠标左右键被显式排除**于统一处理。
    elseif not down then
        self:OnLeftUp()
        return
    end

--   ★ 4688 行 ClearActionHold：每次左键都重置长按状态。
--     ⇒ 保证「每次新点击都是干净的长按起点」。
    self:ClearActionHold()

    self.startdragtime = nil

--   ★ 4692-4695 行：保存并清空上一次的**双击**记录（区别于长按记录）。
--   ⚠ 变量名 startdoubleclicktime/pos 与 long press 的 actionholdtime 不同，
--     两者互不干扰。
	local laststartdoubleclicktime = self.startdoubleclicktime
	local laststartdoubleclickpos = self.startdoubleclickpos
	self.startdoubleclicktime = nil
	self.startdoubleclickpos = nil

    if not self:IsEnabled() then
        return
--   ★ 4699-4701 行：鼠标在 HUD 元素上 → 取消建造放置。
--     "点 UI 会取消建造" 是一个容易被误解但很重要的行为。
    elseif TheInput:GetHUDEntityUnderMouse() ~= nil then
        self:CancelPlacement()
        return
--   建造放置模式：与 2308 行的手柄版本同构，但多了 can_build / onfailed 分支。
    elseif self.placer_recipe ~= nil and self.placer ~= nil then

        --do the placement
        if self.placer.components.placer.can_build then

            if self.inst.replica.builder ~= nil and not self.inst.replica.builder:IsBusy() then
                self.inst.replica.builder:MakeRecipeAtPoint(self.placer_recipe,
                    self.placer.components.placer.override_build_point_fn ~= nil and self.placer.components.placer.override_build_point_fn(self.placer) or self.placer:GetPosition(),
                    self.placer:GetRotation(), self.placer_recipe_skin)
                self:CancelPlacement()
            end

        elseif self.placer.components.placer.onfailedplacement ~= nil then
            self.placer.components.placer.onfailedplacement(self.inst, self.placer)
        end

        return
    end

--★ 4722 行 `self.actionholdtime = GetTime()`：长按起点。
--   ⚠ 4721 行先取 `local t = GetTime()` 再存，4722 行同时赋值 ——
--     t 在 4760/4774/4798/4801 行被复用（双击判定）。
	local t = GetTime()
	self.actionholdtime = t

	local act, spellbook, spell_id, dblclickact, trypreventdirflicker, position
--★ AOE 瞄准分支（4725-4743）：与 824-843 行的手柄版本几乎逐行同构。
--   ⚠ 但 4732 行用的是 `self:GetRightMouseAction()`（**鼠标右键**的缓存），
--     而手柄版 831 行用 `self:GetGroundUseAction()`（现算点地动作）。
--     ⇒ 同一个语义，两条不同实现。这是鼠标/手柄不对称的一例。
    if self:IsAOETargeting() then
		local canrepeatcast = self.reticule.inst.components.aoetargeting:CanRepeatCast()
		if self:IsBusy() and not (canrepeatcast and self.inst:HasTag("canrepeatcast")) then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative", nil, .4)
            self.reticule:Blip()
            return
        end
        act = self:GetRightMouseAction()
        if act == nil or act.action ~= ACTIONS.CASTAOE then
            return
        end
        spellbook = self:GetActiveSpellBook()
		if spellbook ~= nil then
			spell_id = spellbook.components.spellbook:GetSelectedSpell()
		end
		self.reticule:PingReticuleAt(act:GetDynamicActionPoint())
		if not (canrepeatcast and self.reticule.inst.components.aoetargeting:ShouldRepeatCast(self.inst)) then
			self:CancelAOETargeting()
		end
	else
--★ 4745-4746 行 `TheSim:GetPosition()` + `ProjectScreenPos()`：
--   ★★ 这个组合**不是**取鼠标位置，而是取「屏幕中心投影到世界」。
--   为什么？TheSim:ProjectScreenPos 需要世界坐标→屏幕的逆运算；
--     DST 里 TheInput:GetWorldPosition()（4748 行注释提到）才是正解。
--   ⚠ 但 4748 行的注释写 "basically TheInput:GetWorldPosition()"，
--     说明作者认为两者近似。
--   ⚠ 疑似缺陷（可能的不精确）：ProjectScreenPos(scrnx, scrny) 的语义
--     是「把屏幕坐标 (scrnx,scrny) 投影回世界」，若参数是 GetPosition() 返回的
--     视口中心，则结果确实是鼠标位置附近。
--     推理依据：GetPosition 返回相机的视口中心；ProjectScreenPos 是逆投影。
--     ⇒ 正确理解：这是「从屏幕中心反投影」，等价于取鼠标下的地面点。
		local scrnx, scrny = TheSim:GetPosition()
		local x, y, z = TheSim:ProjectScreenPos(scrnx, scrny)

		--first see if we have double click actions
		if x and y and z then
			position = Vector3(x, y, z) --basically TheInput:GetWorldPosition()

--★ 4752 行 `TheInput:GetWorldEntityUnderMouse()`：鼠标下的实体。
--   4753-4755 行：不可见则置 nil（4754 行的重复判断是优化）。
			local target = TheInput:GetWorldEntityUnderMouse()
			if target and not CanEntitySeeTarget(self.inst, target) then
				target = nil
			end
--★ 4756 行的条件 `if target or CanEntitySeeTarget(self.inst, self.inst)`：
--   与 4233 行同款 —— 「有目标 或 玩家能看见自己」才尝试双击。
			if target or CanEntitySeeTarget(self.inst, self.inst) then
				local dir = GetWorldControllerVector()
--★ 4758 行 GetDoubleClickActions(position, dir, target)[1] —— 三参数版。
--   ⚠ 与 4283 行（服务端）只传 position 的版本不对称（见该处注释）。
				dblclickact = self.inst.components.playeractionpicker:GetDoubleClickActions(position, dir, target)[1]
				if dblclickact then
--★ 4760-4761 行的双击判定比 4243 行更严：还要**位置接近**
--   （DOUBLE_CLICK_POS_THRESHOLD = 3，constants.lua:2307）。
--   ⇒ 鼠标双击要求两次点击在同一片区域（3 像素内），摇杆双击只要求时间。
					if (laststartdoubleclicktime and t < laststartdoubleclicktime + DOUBLE_CLICK_TIMEOUT) and
						(laststartdoubleclickpos and math.abs(laststartdoubleclickpos.x - scrnx) <= DOUBLE_CLICK_POS_THRESHOLD and math.abs(laststartdoubleclickpos.y - scrny) <= DOUBLE_CLICK_POS_THRESHOLD)
					then
						act = dblclickact
--★★ 4764-4770 行 trypreventdirflicker —— 一个被主动限定范围的修复。
--   注释全文：
--     "If we're holding a direction key, direct walking will (after one frame)
--      cancel whatever action we are about to buffer to the locomotor
--      (unless it's instant). This flag prevents facing change flicker.
--      Should really do this always, but to avoid bugs with legacy behaviour,
--      we will just do it for players with double click actions for now."
--   → 翻译：按住方向键时，刚缓冲的动作会在一帧后被「直接行走」取消，
--     表现为「角色朝向闪一下又转回」。这个标志阻止该闪烁。
--   ★★ 注释最后两句是金矿：作者明确说「应该总是这么做，
--     但为了不破坏 legacy 行为，只给有双击动作的玩家开」。
--   ⇒ 这是「明知有更好方案但不敢全量上线」的典型工程妥协。
--   ⚠ 后果：**只有双击动作受保护**，其他动作仍有朝向闪烁。
					elseif dir then
						--If we're holding a direction key, direct walking will (after one frame) cancel
						--whatever action we are about to buffer to the locomotor (unless it's instant).
						--This flag prevents facing change flicker.
						--Should really do this always, but to avoid bugs with legacy behaviour, we will
						--just do it for players with double click actions for now.
						trypreventdirflicker = true
					end
--   ★ 4772-4775 行：首次（不构成双击）时**记录**位置与时间，作为第二次的基准。
--     且 4772 行的条件包含 `or self:IsBusy()` ——
--     ⇒ busy 时即使不是首次双击也持续记录，因为 busy 期间点击不会执行。
					if act == nil or self:IsBusy() then
						self.startdoubleclickpos = Vector3(scrnx, scrny, 0)
						self.startdoubleclicktime = t
					end
				end
			end
		end

--★★ 4780-4785 行：动作选择的最终兜底链。
--   4781 行 `GetLeftMouseAction() or BufferedAction(self.inst, nil,
--   ACTIONS.WALKTO, nil, position)`：
--     没有 LMB 动作 → **兜底为 WALKTO**（点地面走过去）。
--   ★ 这是玩家最常用的操作，也是唯一「必然有动作」的情况。
--   4782-4784 行：动作是 WALKTO 或 LOOKAT 时**不**记录双击起点，
--     且 4783 行主动清空 startdoubleclicktime。
--   ⚠ 看似多余（4782 行已经保证 act ~= nil 时才执行），
--     实则是清掉 4773-4774 行可能已记录的起点。属防御式冗余。
		if act == nil then
			act = self:GetLeftMouseAction() or BufferedAction(self.inst, nil, ACTIONS.WALKTO, nil, position)
			if act and act.action ~= ACTIONS.WALKTO and act.action ~= ACTIONS.LOOKAT then
				self.startdoubleclicktime = nil
			end
		end
    end

    local maptarget = self:GetMapTarget(act)
    if maptarget ~= nil then
        local forced_actiondef = act.action.map_only and act.action or nil
		self:PullUpMap(maptarget, forced_actiondef)
        return
    end

--★★ 4795-4799 行：WALKTO 时若目标是**平台**（船/冰），不进入拖拽模式。
--   4797 行的 HasAnyTag("walkableplatform", "walkableperipheral") 排除。
--   ⇒ 「点击船上走过去」不会变成「按住拖拽」。
    if act.action == ACTIONS.WALKTO then
        local entity_under_mouse = TheInput:GetWorldEntityUnderMouse()
        if act.target == nil and (entity_under_mouse == nil or entity_under_mouse:HasAnyTag("walkableplatform", "walkableperipheral")) then
			self.startdragtime = t
        end
--   DASH（冲刺，如韦德的技能）也设置 startdragtime ——
--   ⇒ 冲刺后可继续拖拽连续冲刺。
	elseif act.action == ACTIONS.DASH then
		self.startdragtime = t
--★ ATTACK 分支：与 DoAttackButton 的「重复攻击」检查同构（2802/1302 行）。
--   ★ 4805 行 `sg:HasStateTag("attack") and act.target == combat:GetTarget()`
--     4804 行先写 retarget —— ★ 即使要 return 也已经写了。
--   ⚠ 副作用：对着同一目标狂点时，每次都会刷新 retarget（无害）。
    elseif act.action == ACTIONS.ATTACK then
        if self.inst.sg ~= nil then
            self.inst.sg.statemem.retarget = act.target
            if self.inst.sg:HasStateTag("attack") and act.target == self.inst.replica.combat:GetTarget() then
                return
            end
        elseif self.inst:HasTag("attack") and act.target == self.inst.replica.combat:GetTarget() then
            return
        end
--★ LOOKAT 分支：目标带 playeravatardata → 弹玩家资料；
--   4819-4821 行：目标带 quagmire_shoptab → 推事件打开商店页。
--   ⚠ 硬编码模组内容（quagmire）写在通用文件里（同 2489 行温蒂特例）。
    elseif act.action == ACTIONS.LOOKAT then
        if act.target ~= nil and self.inst.HUD ~= nil then
            if act.target.components.playeravatardata ~= nil then
                local client_obj = act.target.components.playeravatardata:GetData()
                if client_obj ~= nil then
                    client_obj.inst = act.target
                    self.inst.HUD:TogglePlayerInfoPopup(client_obj.name, client_obj, true)
                end
            elseif act.target.quagmire_shoptab ~= nil then
                self.inst:PushEvent("quagmire_shoptab", act.target.quagmire_shoptab)
            end
        end
--   船炮 / 高尔夫的准星涟漪（纯表现）。
    elseif act.action == ACTIONS.BOAT_CANNON_SHOOT then
        local boatcannonuser = self.inst.components.boatcannonuser
        local reticule = boatcannonuser ~= nil and boatcannonuser:GetReticule() or nil
        if reticule ~= nil then
			reticule:PingReticuleAt(act:GetDynamicActionPoint())
        end
	elseif act.action == ACTIONS.GOLF_START_CHARGING then
		--@V2C #TODO
    end

--★★★ 【4833-4873 发送分支】与手柄版同构，但有两处鼠标特有的细节。
--   4834 行服务端：combat:SetTarget(nil)（同其他按钮）。
    if self.ismastersim then
        self.inst.components.combat:SetTarget(nil)
    else
        local mouseover, platform, pos_x, pos_z
--★ 4837-4846 行：★ 「用准星位置」还是「用鼠标位置」的抉择。
--   四种动作用 reticule 的位置：
--     · CASTAOE（法术）
--     · BOAT_CANNON_SHOOT（船炮）
--     · GOLF_START_CHARGING（高尔夫）
--     · dblclickact（双击动作，位置可能已被覆盖）
--   注释 "dblclickact also may have overridden the position" ——
--     4780-4781 行的 WALKTO 兜底会把 act 换成用 position 的新动作，
--     所以此时必须用 act.pos 而不是原鼠标位置。
--   ⇒★★ 这解释了为什么 4841 行的条件里要包含 `act == dblclickact`：
--     「动作实例换了，位置来源也必须跟着换」。
        if act.action == ACTIONS.CASTAOE or
			act.action == ACTIONS.BOAT_CANNON_SHOOT or
			act.action == ACTIONS.GOLF_START_CHARGING or
			act == dblclickact
		then
            --These actions use reticule position
			--dblclickact also may have overridden the position
			platform = act.pos.walkable_platform
			pos_x = act.pos.local_pt.x
			pos_z = act.pos.local_pt.z
--★ 4847-4851 行的 else 分支：用真实鼠标位置，并转成平台相对坐标。
--   4850 行 `act.action ~= ACTIONS.DROP and GetWorldEntityUnderMouse() or nil`：
--     ★★ DROP（丢弃）时不发 mouseover —— 丢弃不需要悬停物信息。
--     ⚠ 又一个 `a and b or nil` 惯用法：若 GetWorldEntityUnderMouse 返回
--       false（不会，实体是 table 或 nil），结果为 nil。安全。
        else
			position = position or TheInput:GetWorldPosition()
			platform, pos_x, pos_z = self:GetPlatformRelativePosition(position.x, position.z)
            mouseover = act.action ~= ACTIONS.DROP and TheInput:GetWorldEntityUnderMouse() or nil
        end

--★ EncodeControlMods：把修饰键掩码一起发给服务器（转发的强制攻击等）。
        local controlmods = self:EncodeControlMods()
--★ 4854-4872 行：三分支发送，与 886-939 行同构。
--   ★ 4861-4864 行的「按钮按下」通知：鼠标左键的无参 RPC（RPC.LeftClick）。
        if self.locomotor == nil then
			act.non_preview_cb = function()
				self.remote_controls[CONTROL_PRIMARY] = 0
				SendRPCToServer(RPC.LeftClick, act.action.code, pos_x, pos_z, mouseover, nil, controlmods, act.action.canforce, act.action.mod_name, platform, platform ~= nil, spellbook, spell_id)
			end
		else
			--Still need to let the server know LMB is down
			if self.remote_controls[CONTROL_PRIMARY] == nil then
				self.remote_controls[CONTROL_PRIMARY] = 0
				SendRPCToServer(RPC.LeftClick)
			end
--★ 4865 行 `act.action ~= ACTIONS.WALKTO and self:CanLocomote()`：
--   ★★ 与 2300 行一致的 WALKTO 豁免 —— 走过去不产生动作 RPC。
--     但 4861-4864 行的「按下通知」**仍会发**。
--   ⚠ 这意味着点地面走：发 1 个 RPC.LeftClick（无参）+ 若干 PredictWalking。
--     而不是发一个完整的 LeftClick(code, x, z, ...)。带宽优化成立。
			if act.action ~= ACTIONS.WALKTO and self:CanLocomote() then
				act.preview_cb = function()
					local isreleased = not TheInput:IsControlPressed(CONTROL_PRIMARY)
					self.remote_controls[CONTROL_PRIMARY] = not isreleased and 0 or nil
					SendRPCToServer(RPC.LeftClick, act.action.code, pos_x, pos_z, mouseover, isreleased, controlmods, nil, act.action.mod_name, platform, platform ~= nil, spellbook, spell_id)
				end
			end
        end
    end

--★ 4875 行 DoAction：无论走哪条分支，最终都汇合到这里。
	self:DoAction(act, spellbook)

--★ 4877-4879 行：trypreventdirflicker 的实际执行。
--   ★ 完整条件链（跨 4758-4879 行）：
--     ① 4758 行算出 dblclickact 但**首次点击**（未构成双击）
--     ② 且玩家正按方向键（dir ~= nil）→ 4770 行置 trypreventdirflicker = true
--     ③ 4780-4781 行 act 仍为 nil → 兜底为 LMB 动作或 WALKTO
--     ④ 4877 行：标志为真 且 act 不是 dblclickact（即③）→ locomotor:Clear()
--   ⚠⚠ 关键：locomotor.lua:755 的 Clear() 内部会 `SetBufferedAction(nil)`，
--     即**清掉刚刚缓冲的动作**。
--   ⇒ 实际效果：玩家「按住方向键 + 首次点击有双击动作的物体」，
--     该次点击的动作被丢弃（不执行），换来朝向不闪烁。
--   推理依据：locomotor.lua:755-763 Clear 的函数体含 SetBufferedAction(nil)；
--     4770 行的注释只提「防止朝向闪烁」，未说明会丢动作。
--   ⇒ 这是一个**已知代价的显式取舍**，不是意外：
--     玩家若想执行该动作，松开方向键再点一次即可（此时 dir 为 nil）。
	if trypreventdirflicker and act ~= dblclickact and self.locomotor and self.locomotor.bufferedaction == act then
		self.locomotor:Clear()
	end

--★ 4881-4887 行：位置存在时发 busy 微调（温泉等场景）。
--   4883 行服务端走 sg:HandleEvent("ms_overridelocomote_click", ...)，
--     4885 行客户端走 DoClientBusyOverrideLocomoteClick（3991 行）。
	if position then
		if self.ismastersim then
			self.inst.sg:HandleEvent("ms_overridelocomote_click", { dir = self.inst:GetAngleToPoint(position) })
		else
			self:DoClientBusyOverrideLocomoteClick(position)
		end
	end
end

--【OnRemoteLeftClick】★ 左键的服务端对端（最长的一个 Remote 函数）。
--   ★★ 4901 行 DecodeControlMods 在**动作选择之前**调用 ——
--     修饰键（强制攻击等）必须先生效，picker 才能算出对应动作。
--     与 5098 行（右键）的顺序一致。
function PlayerController:OnRemoteLeftClick(actioncode, position, target, isreleased, controlmodscode, noforce, mod_name, spellbook, spell_id)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.inst.components.combat:SetTarget(nil)

        self.remote_controls[CONTROL_PRIMARY] = 0

--   actioncode == nil → 「只是按下通知」（4863 行发的）。
--   4897 行 assert(isreleased == nil)：同 951/1199 行的自检断言范式。
		if actioncode == nil then
			assert(isreleased == nil) --actioncode nil means all params must be nil
			return
		end

--★ 4901-4924 行：解码修饰键 → 选动作 → 清修饰键。
--   ★ 4924 行 ClearControlMods() 在**动作算完之后**才清 ——
--     保证算动作时修饰键生效。
        self:DecodeControlMods(controlmodscode)
        SetClientRequestedAction(actioncode, mod_name)
		local lmb, rmb
--★ 法术书分支（4904-4911）：与 998 行同构，含 GetGrandOwner 校验。
		if spellbook ~= nil then
			if spellbook.components.inventoryitem ~= nil and
				spellbook.components.inventoryitem:GetGrandOwner() == self.inst and
				spellbook.components.spellbook ~= nil and
				spellbook.components.spellbook:SelectSpell(spell_id)
				then
				lmb, rmb = self.inst.components.playeractionpicker:DoGetMouseActions(position, target, spellbook)
			end
--   4912 行的 `elseif spell_id == nil`：
--   ⚠ 疑似缺陷（条件含义）：这个条件是「spell_id 为 nil」，
--     而 spellbook == nil 的情况由上一分支覆盖。
--     若两者都为 nil（无书无 spell_id）→ 走 4913 行算普通动作。正确。
--     若 spellbook ~= nil 且 spell_id == nil（书在手上但没选法术）→
--       ★ 走 4913 行的普通路径，可能算出非施法动作。
--     推理依据：4904 分支要求 spellbook ~= nil 全部条件才进；
--       否则落到 4912 行，此时 spell_id 恰好为 nil 就会被当普通点击。
--     缓解：客户端侧 4737-4739 行 spell_id 从 spellbook 取，
--       不会同时出现「有书无 spell_id」。故当前不可触发。
		elseif spell_id == nil then
			lmb, rmb = self.inst.components.playeractionpicker:DoGetMouseActions(position, target)
		end
--★ 4915-4918 行：服务端也算一次双击动作（用于 4945 行的回退链）。
--   4916 行同样用 CanEntitySeeTarget(self.inst, self.inst) 做守卫。
		local dblclickact
		if CanEntitySeeTarget(self.inst, self.inst) then
			dblclickact = self.inst.components.playeractionpicker:GetDoubleClickActions(position)[1]
		end

        ClearClientRequestedAction()
        if isreleased then
            self.remote_controls[CONTROL_PRIMARY] = nil
        end
        self:ClearControlMods()

--★★ 【4929-4949：四级回退链】★ 本文件最精巧的一段。
--   注释："Default fallback lmb action is WALKTO /
--    Possible for lmb action to switch to rmb after autoequip /
--   --V2C: LOOKAT was added to support closeinspect"
--   四级顺序及理由：
--     ① 4929-4932 LOOKAT：客户端上报 LOOKAT 但算出的是 WALKTO
--        → 「靠近检视」（closeinspect）：玩家走到目标旁边就自动看。
--        ★ 这是模组 closeinspect 的实现。
--     ② 4933-4936 WALKTO：算出 nil 但客户端要的是 WALKTO → 补一个。
--        这是「鼠标点地面」的服务端兜底（因为客户端根本没算 LMB 动作）。
--     ③ 4937-4940 LMB code 匹配 → 标准路径。
--     ④ 4941-4944 RMB code 匹配 → 自动装备导致的漂移（同 963 行）。
--     ⑤ 4945-4948 双击动作 code 匹配 → 双击动作的服务端执行。
--   ⚠⚠ 疑似缺陷（校验放松）：⑤ 让**双击动作**可以绕过 ③ 的 LMB 校验，
--     而双击动作的位置参数（position）来自客户端。
--     缓解：4945 行的 dblclickact 是服务端在 4917 行自己算的（用同一 position），
--       只是取 [1]；且 4917 行传的是 position 而非 4758 行的三参数版。
--     ⇒ 所以「绕过」的是 LMB 通道，但仍需 code 与服务端自算的 dblclickact 匹配。
--       安全性可接受。
--   ⇒★ 真正的价值：这条链让「客户端与服务端算出不同动作」的四种情况都有出路，
--     而不是简单地丢弃请求。**容错优先于严格**。
        --Default fallback lmb action is WALKTO
        --Possible for lmb action to switch to rmb after autoequip
		--V2C: LOOKAT was added to support closeinspect
		lmb =  (actioncode == ACTIONS.LOOKAT.code and
				(lmb == nil or lmb.action == ACTIONS.WALKTO) and
				mod_name == nil and
				BufferedAction(self.inst, target, ACTIONS.LOOKAT, nil, position))
			or (lmb == nil and
                actioncode == ACTIONS.WALKTO.code and
                mod_name == nil and
                BufferedAction(self.inst, nil, ACTIONS.WALKTO, nil, position))
            or (lmb ~= nil and
                lmb.action.code == actioncode and
                lmb.action.mod_name == mod_name and
                lmb)
            or (rmb ~= nil and
                rmb.action.code == actioncode and
                rmb.action.mod_name == mod_name and
                rmb)
			or (dblclickact and
				dblclickact.action.code == actioncode and
				dblclickact.action.mod_name == mod_name and
				dblclickact)
            or nil

--★ 4951-4956 行：force 时对齐预测位置（同 975 行）。
--   ★★ 4956 行的 DoAction(lmb, spellbook) 传了 spellbook ——
--     因为 ① 的 LOOKAT 兜底可能来自法术书路径。
        if lmb ~= nil then
            if lmb.action.canforce and not noforce then
                lmb:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
                lmb.forced = true
            end
			self:DoAction(lmb, spellbook)
--   --see trypreventdirflicker
--★★ 4958 行：服务端的 trypreventdirflicker 对应实现。
--   条件与客户端 4877 行不同：这里多了 `self:GetRemoteDirectVector()`
--   （即「正在直接行走」），因为服务端没有 isclientcontrollerattached 可用。
--   ⚠ 4958 行 `self.locomotor.bufferedaction` 无 nil 检查 ——
--     服务端玩家必有 locomotor（玩家 prefab 都挂），风险低。
			--see trypreventdirflicker
			if dblclickact and lmb ~= dblclickact and self.locomotor.bufferedaction == lmb and self:GetRemoteDirectVector() then
				self.locomotor:Clear()
			end
        --elseif mod_name ~= nil then
            --print("Remote left click action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
        --else
            --print("Remote left click action failed: "..tostring(ACTION_IDS[actioncode]))
        end
    end
end

--【GetPlatformRelativePosition(absolute_x, absolute_z)】世界坐标 → 平台局部坐标。
--   ★ 与 3718 行的 ConvertPlatformRelativeToAbsoluteXZ 是**逆运算**。
--   ★ 返回三元组 (platform, x, z)：platform 为 nil 时 x/z 原样返回。
--   ⚠ 4973 行 `platform.entity:WorldToLocalSpace(absolute_x, 0, absolute_z)`：
--     ★★ y 硬编码 0。因为只处理 XZ 平面，y 无意义。
--     但若平台在 y=10 的空中（船），局部 y 也会是 -10，却被丢弃 ——
--     这正是 B8「一字段三语义」的另一个体现：**平台局部坐标丢掉了高度维度**。
--   ⇒ 后果：在不同高度的平台上点击同一世界坐标，得到的局部 xz 不同，
--     还原回去能得到正确世界坐标（因为 y 被丢弃后又置 0）。但若目标平台
--     不在同一水平面，还原会出错。
--   推理依据：4974 行 `absolute_x, y, absolute_z = ...WorldToLocalSpace(...)`
--     中 y 被接收但随后 4975 行的返回不含 y。
function PlayerController:GetPlatformRelativePosition(absolute_x,absolute_z)
--============================================================
-- 【第九段】4970-5330 行：鼠标右键 / ★ 地图动作（屏幕坐标 → 世界坐标）
--============================================================
    local platform = TheWorld.Map:GetPlatformAtPoint(absolute_x,absolute_z)
    if platform ~= nil then
		local y
		absolute_x, y, absolute_z = platform.entity:WorldToLocalSpace(absolute_x, 0, absolute_z)
    end
    return platform, absolute_x, absolute_z
end

--★★ 【OnRightClick(down)】鼠标右键 = 「第二动作 / AOE 瞄准 / 进入放置」。
--   ★ 5087 行结束，110 行。结构：
--     ① 4979-4986 守卫（鼠标模式 / 抬起 → RemoteStopControl）
--     ② 4988-5001 取消分支（放置/AOE/禁用/HUD）
--     ③ 5003-5005 取长按起点 + 取动作
--     ④ 5007-5029 无动作时的四条出路
--     ⑤ 5030-5033 地图动作
--     ⑥ 5034-5084 部署特判 + 三分支发送
--     ⑦ 5085 DoAction
function PlayerController:OnRightClick(down)
    if not self:UsingMouse() then
        return
    elseif not down then
--   ★ 4982-4985 行：右键**抬起** → 通知服务器按键松开（对称 4527 行）。
--     守卫 `self:IsEnabled()`：被禁用时不需要清（ClearActionHold 会清）。
        if self:IsEnabled() then
            self:RemoteStopControl(CONTROL_SECONDARY)
        end
        return
    end

    self:ClearActionHold()

--   ★ 4990-4991 行：右键**只清** startdragtime，**不清** startdoubleclicktime
--     （而 4688-4695 行的左键两者都清）。
--   ⚠ 疑似缺陷（不对称）：右键不重置双击记录，意味着「左键双击后立刻右键」
--     可能被误判为双击的第二击（4773-4774 行记录的时间未被清除）。
--     推理依据：4688-4695（左键）清 actionholdtime + startdragtime +
--       startdoubleclicktime/pos 四项；4990-4991（右键）只清 startdragtime。
--     缓解：DOUBLE_CLICK_TIMEOUT = .5 秒，窗口很短；
--       且右键的 5003 行会重设 actionholdtime。
    self.startdragtime = nil
	self.startdoubleclicktime = nil

--   ★ 4993-4998 行：右键的前三个早退都是「取消当前模式」：
--     建造放置中 → 取消建造
--     AOE 瞄准中 → 取消瞄准
--     被禁用 / 点在 HUD 上 → 放弃
--   ⇒ 对比左键（4699-4719）：左键在建造放置中是**执行建造**（点一下放下）。
--     ★ 这是 LMB/RMB 的核心语义差异：「左键确认，右键取消」。
    if self.placer_recipe ~= nil then
        self:CancelPlacement()
        return
    elseif self:IsAOETargeting() then
        self:CancelAOETargeting()
        return
    elseif not self:IsEnabled() or TheInput:GetHUDEntityUnderMouse() ~= nil then
        return
    end

--   长按起点。与左键的 4722 行对称。
    self.actionholdtime = GetTime()

--   ★★ act = self:GetRightMouseAction() —— **取缓存**（2827/2936 行的副产物）。
--     ★ 与手柄路径的 GetGroundUseAction（现算）不同。
--   ⚠ 若本帧还没跑过 OnUpdate 的 2827 行（如刚 Activate），RMBaction 可能过期。
--     由 4559-4563 行的有效性检查兜底。
    local act = self:GetRightMouseAction()
--   maptarget 在 act 可能为 nil 时就算（GetMapTarget:424 首行处理 nil）。
    local maptarget = self:GetMapTarget(act)
--★★★ 【5007-5029 无右键动作时的四条出路】
--   ① 5009-5018 关闭 HUD（合成菜单 / 法术轮盘）
--   ② 5020 收回手持物（ReturnActiveItem）
--   ③ 5021 TryAOETargeting 或 TryAOECharging
--   ④ 5025-5028 通知服务器「右键按下」
--   ★ 这是「右键 = 上下文菜单键」的设计：没有具体动作时，
--     右键负责「退出当前模式」或「切换 UI」。
    if act == nil then
		local closed = false
		if self.inst.HUD ~= nil then
--   ★ 5010-5017 行：一次右键可能**同时**关闭合成菜单与法术轮盘（两个 if 而非 elif）。
--     closed 标志（5008 行）只用于「是否还需要通知服务器」。
			if self.inst.HUD:IsCraftingOpen() then
				self.inst.HUD:CloseCrafting()
				closed = true
			end
			if self.inst.HUD:IsSpellWheelOpen() then
				self.inst.HUD:CloseSpellWheel()
				closed = true
			end
		end
		if not closed then
--   ★ 5020 行 ReturnActiveItem：把激活物品放回背包。
--     这是「右键空手 → 收起当前工具」的操作（如放下火把后空手）。
			self.inst.replica.inventory:ReturnActiveItem()
--★ 5021 行 `TryAOETargeting() or TryAOECharging(nil, false)`：
--   ★ iscontroller = false → 后续 RPC 用 CONTROL_SECONDARY（1687 行）。
--   ⇒ 与手柄版的 1109 行（iscontroller = true）构成鼠标/手柄对照。
			if self:TryAOETargeting() or self:TryAOECharging(nil, false) then
				return
			end
			--Still need to let the server know RMB is down
--   「右键按下」通知（同 870 行范式）。⚠ 有 closed 标志守卫：
--     若已经关闭了某个 UI，就不再通知（因为那不是「玩家想操作世界」）。
			if self.remote_controls[CONTROL_SECONDARY] == nil then
				self.remote_controls[CONTROL_SECONDARY] = 0
				SendRPCToServer(RPC.RightClick)
			end
		end
    elseif maptarget ~= nil then
        local forced_actiondef = act.action.map_only and act.action or nil
		self:PullUpMap(maptarget, forced_actiondef)
        return
    else
--   ★ 5036 行 PingReticuleAt：准星涟漪。纯表现。
        if self.reticule ~= nil and self.reticule.reticule ~= nil then
			self.reticule:PingReticuleAt(act:GetDynamicActionPoint())
        end
--★★ 【5038-5050 部署特判】goingtodeploy：右键动作是 DEPLOY/DEPLOY_FLOATING。
--   5040-5042 行：轴对齐放置时用放置器位置而非鼠标位置。
--   5043-5048 行：override_build_point_fn 可覆盖位置（如桅杆类）。
--   5049 行 `act.rotation = deployplacer.Transform:GetRotation()`：
--     ★★ 部署方向来自**放置器当前朝向**而非鼠标 ——
--       所以放置模式下可用滚轮/按键旋转放置器。
		local goingtodeploy = self.deployplacer ~= nil and (act.action == ACTIONS.DEPLOY or act.action == ACTIONS.DEPLOY_FLOATING)
        if goingtodeploy then
            if self.deployplacer.components.placer:IsAxisAlignedPlacement() then
                act:SetActionPoint(self.deployplacer:GetPosition())
            end
            if self.deployplacer.components.placer.override_build_point_fn then
                local override_pt = self.deployplacer.components.placer.override_build_point_fn(self.deployplacer)
                if override_pt then
                    act:SetActionPoint(override_pt)
                end
            end
            act.rotation = self.deployplacer.Transform:GetRotation()
        end
--★ 5051-5084 行：非服务端的发送分支（与左键同构但参数不同）。
        if not self.ismastersim then
            local position
            local mouseover
--   5054-5062 行：部署时位置来自放置器（可选 mouseover），否则来自鼠标。
--   ★ 5056 行非轴对齐时才取 mouseover（轴对齐时没有「悬停物」概念）。
            if goingtodeploy then
                position = act:GetActionPoint()
                if not self.deployplacer.components.placer:IsAxisAlignedPlacement() then
                    mouseover = TheInput:GetWorldEntityUnderMouse()
                end
            else
                position = TheInput:GetWorldPosition()
                mouseover = TheInput:GetWorldEntityUnderMouse()
            end
--★ 右键也带 EncodeControlMods（5063 行）—— 强制攻击等修饰键同样适用。
            local controlmods = self:EncodeControlMods()
            local platform, pos_x, pos_z = self:GetPlatformRelativePosition(position.x, position.z)
            if self.locomotor == nil then
				act.non_preview_cb = function()
					self.remote_controls[CONTROL_SECONDARY] = 0
					SendRPCToServer(RPC.RightClick, act.action.code, pos_x, pos_z, mouseover, act.rotation ~= 0 and act.rotation or nil, nil, controlmods, act.action.canforce, act.action.mod_name, platform, platform ~= nil)
				end
			else
				--Still need to let the server know RMB is down
				if self.remote_controls[CONTROL_SECONDARY] == nil then
					self.remote_controls[CONTROL_SECONDARY] = 0
					SendRPCToServer(RPC.RightClick)
				end
--   ★ 5076 行 `act.action ~= ACTIONS.WALKTO and CanLocomote()` ——
--     与左键 4865 行同构的 WALKTO 豁免。
--     ⚠ 但右键几乎不会出现 WALKTO（走是左键的事），这个检查近乎冗余。
--     推理依据：5005 行的 RMBaction 来自 GetRightMouseActions，
--       该函数（playeractionpicker.lua:388）不返回 WALKTO。
				if act.action ~= ACTIONS.WALKTO and self:CanLocomote() then
					act.preview_cb = function()
						local isreleased = not TheInput:IsControlPressed(CONTROL_SECONDARY)
						self.remote_controls[CONTROL_SECONDARY] = not isreleased and 0 or nil
						SendRPCToServer(RPC.RightClick, act.action.code, pos_x, pos_z, mouseover, act.rotation ~= 0 and act.rotation or nil, isreleased, controlmods, nil, act.action.mod_name, platform, platform ~= nil)
					end
                end
            end
        end
--★ DoAction：右键路径的终点。与左键的 4875 行对称。
        self:DoAction(act)
    end
end

--【OnRemoteRightClick】右键的服务端对端。
--   ★★ 与 OnLeftClick 相比简化很多：
--     · 没有四级回退链（5092 行后直接判断 rmb code）
--     · 没有 AOE / 双击分支
--     · 没有角色特例（玩家资料、商店页）
--   ⇒ 因为右键动作类型少、歧义小。
--   ★ 5100 行仍用 DoGetMouseActions（同时算 lmb 与 rmb）而非专用函数。
function PlayerController:OnRemoteRightClick(actioncode, position, target, rotation, isreleased, controlmodscode, noforce, mod_name)
    if self.ismastersim and self:IsEnabled() and self.handler == nil then
        self.remote_controls[CONTROL_SECONDARY] = 0

		if actioncode == nil then
			assert(isreleased == nil) --actioncode nil means all params must be nil
			return
		end

        self:DecodeControlMods(controlmodscode)
        SetClientRequestedAction(actioncode, mod_name)
        local lmb, rmb = self.inst.components.playeractionpicker:DoGetMouseActions(position, target)
        ClearClientRequestedAction()
        if isreleased then
            self.remote_controls[CONTROL_SECONDARY] = nil
        end
        self:ClearControlMods()

--★ 5107 行的匹配**只有 rmb**（没有 lmb 回退）。
--   ⇒ 对比左键的 4937-4944 行有 lmb→rmb 的双向回退。
--   ⚠ 推测原因：右键不做自动装备（4657 行的黑名单含 STORE 等），
--     不存在「装备变了导致左右键互换」的场景。
--     推理依据：DoActionAutoEquip:4657 排除了大量容器类动作，
--       而这些大多通过右键触发。
--   ⇒ 这是一个**正确的不对称**，不是遗漏。
        if rmb ~= nil and rmb.action.code == actioncode and rmb.action.mod_name == mod_name then
            if rmb.action.canforce and not noforce then
                rmb:SetActionPoint(self:GetRemotePredictPosition() or self.inst:GetPosition())
                rmb.forced = true
            end
--★ 5112 行 `rmb.rotation = rotation or rmb.rotation`：
--   ★ 客户端上报的旋转优先（同 forced 的处理范式）。
--   ⚠ rotation 在 5068/5080 行是 `act.rotation ~= 0 and act.rotation or nil`，
--     所以「旋转 0」会被转成 nil → 服务端保留自己的 rotation。
--     ⇒ 部署时若朝向正好是 0 度，服务端会用自己算的 rotation。
--     推理依据：5068 行 `act.rotation ~= 0 and act.rotation or nil`。
            rmb.rotation = rotation or rmb.rotation
            self:DoAction(rmb)
        --elseif mod_name ~= nil then
            --print("Remote right click action failed: "..tostring(ACTION_MOD_IDS[mod_name][actioncode]))
        --else
            --print("Remote right click action failed: "..tostring(ACTION_IDS[actioncode]))
        end
    end
end

--★★ 【RemapMapAction(act, position)】★ 地图动作的重映射。
--   回答的问题：「这个动作在**地图的另一个位置**上还成立吗？」
--   两条路径（5126/5141）：
--     ① act.action.map_only：地图专属动作，检查位置合法性后原样返回
--     ② ACTIONS_MAP_REMAP[act.action.code]：普通动作 → 地图专用变体
--   ★ 例：地面点击是 DIG，地图上变成「挖掘标记」。
function PlayerController:RemapMapAction(act, position)
    local act_remap = nil
    if act then
        local px, py, pz = position:Get()
--   ★ map_only 动作：maponly_checkvalidpos_fn 决定「合法位置」。
--   5127-5135 行：该函数可同时**改写位置**（返回 act_posx/act_posz）。
--     例：「在这块区域种树」→ 实际种在区域的某个子位置。
        if act.action.map_only then
            if act.action.maponly_checkvalidpos_fn then
                local valid, reason, act_posx, act_posz, mapent = act.action.maponly_checkvalidpos_fn(act)
                if not valid then
                    return nil
                end
                if act_posx then
                    px, py, pz = act_posx, 0, act_posz
                end
            end
--★★ 【5136-5137 行：地块合法性三连判】
--   ① IsOceanTileAtPoint —— 海上不行
--   ② IsVisualGroundAtPoint —— 有地面才行
--   ③ map_works_on_impassable 时 IsImpassableTileAtPoint 也算
--   再叠加：map_works_on_unexplored 或 CanSeePointOnMiniMap（★ 战争迷雾）。
--   ⚠⚠ 疑似缺陷（运算符优先级）：
--     `A or B or C and D` 解析为 `A or B or (C and D)`（and 优先级高于 or），
--     ★ 这恰好是**作者想要的**语义（map_works_on_impassable 是 C 的修饰）。
--     但**依赖隐式优先级**是可读性隐患 —— 加括号更安全。
--   推理依据：Lua 优先级 and > or > not；
--     5136 行与 5142 行的写法完全相同，说明是刻意的惯用法。
--   ⇒ 这不是 bug，但属于「读的人必须先查优先级表」的危险写法。
            if TheWorld.Map:IsOceanTileAtPoint(px, py, pz) or TheWorld.Map:IsVisualGroundAtPoint(px, py, pz) or act.action.map_works_on_impassable and TheWorld.Map:IsImpassableTileAtPoint(px, py, pz) then
                if act.action.map_works_on_unexplored or self.inst:CanSeePointOnMiniMap(px, py, pz) then
                    act_remap = act
                end
            end
--   ACTIONS_MAP_REMAP（actions.lua 定义）：code → 重映射函数。
--   5143-5145 行比 map_only 多一个豁免：invobject 带 mapaction_works_on_unexplored 标签。
--   ★★ 标签豁免：某些道具（如望远镜/地图扩展）能在未探索区域用地图动作。
        elseif ACTIONS_MAP_REMAP[act.action.code] then
            if TheWorld.Map:IsOceanTileAtPoint(px, py, pz) or TheWorld.Map:IsVisualGroundAtPoint(px, py, pz) or act.action.map_works_on_impassable and TheWorld.Map:IsImpassableTileAtPoint(px, py, pz) then
                if act.action.map_works_on_unexplored or
                    self.inst:CanSeePointOnMiniMap(px, py, pz) or
                    act.invobject and act.invobject:HasTag("mapaction_works_on_unexplored") then
                    act_remap = ACTIONS_MAP_REMAP[act.action.code](act, Vector3(px, py, pz))
                end
            end
        end
    end
    return act_remap
end

--★ _calc_mapaction_dsq：算「动作实际位置」与「请求位置」的距离平方。
--   ⚠⚠ 疑似缺陷（死代码）：grep 全仓只有这一处定义，**没有任何调用点**。
--     同样的逻辑在 5192-5202 行被内联了一遍（GetMapActions 里）。
--   推理依据：grep -rn _calc_mapaction_dsq 全仓只命中 5154 行的定义。
--   ⇒ 推测：抽取函数时忘记替换内联版本，或后来改回内联而未删函数。
--   ⚠ 它未被删除是好事：若有人要重构，函数逻辑就在这里。
local function _calc_mapaction_dsq(inst, action, position)
	if action.maponly_checkvalidpos_fn then
		local valid, reason, act_posx, act_posz, mapent = action.maponly_checkvalidpos_fn(BufferedAction(inst, nil, action, nil, position))
		if valid then
			return math2d.DistSq(act_posx, act_posz, position.x, position.z)
		end
	end
	return math.huge
end

--★★ 【GetMapActions(position, maptarget, actiondef)】★ 地图动作的选择。
--   5165-5167 行 K 的注释说明了设计约束：
--     "In order to not interface with the playercontroller too harshly and keep
--      that isolated from this system here / it is better to get what the
--      player could do at their location as a quick check to make sure the
--      actions done here will not interfere with actions done without the map up."
--   → 翻译：为了不让地图系统「侵入」playercontroller，
--     先在玩家当前位置做一次快速检查，确认「地图上的动作」与
--     「不开地图时的动作」不冲突。
--   ★ 这就是 5169-5170 行 checkingmapactions 标志的用途。
function PlayerController:GetMapActions(position, maptarget, actiondef)
    -- NOTES(JBK): In order to not interface with the playercontroller too harshly and keep that isolated from this system here
    --             it is better to get what the player could do at their location as a quick check to make sure the actions done
    --             here will not interfere with actions done without the map up.

--   -- NOTES(JBK): Workaround flag to not add function argument changes for this
--   task and lets things opt-in to special handling.
--   ★★ self.inst.checkingmapactions = true —— 临时全局标志（而非参数传递）。
--   ★ 消费方在 componentactions.lua / playeractionpicker.lua 里：
--     「正在算地图动作」时某些动作（如需要走过去的）会被排除。
--   ⇒ 又一个「为省事而用全局态」的实例（与 skip_inherentmapaction 同类）。
--   ⚠ 必须成对清除（5256-5257 行），否则异常路径会残留。
    self.inst.checkingmapactions = true -- NOTES(JBK): Workaround flag to not add function argument changes for this task and lets things opt-in to special handling.
    self.inst.checkingmapactions_pos = position

    local LMBaction, RMBaction = nil, nil
    local forced_lmbact, forced_rmbact
--   ★ 5174 行的三态入口：都为空时才走「内建地图动作」分支。
    if not actiondef and not maptarget and not self.skip_inherentmapaction then
        -- Special case for map only actions that only exist in the map itself we use the pointspecialactionsfn to have highest priority with the right click action only.
--   ★ 5176 行 GetPointSpecialActions(position, nil, true)：
--     ★ `true` = 只取「地图专属」的特殊动作（usereticulepos 语义见 225 行）。
		local actions = self.inst.components.playeractionpicker:GetPointSpecialActions(position, nil, true)

--★ 5178-5179 行的注释解释了「为什么要再挑一次最近的」：
--   --NOTE: -playeractionpicker sorted by priorty / -we're picking again to find
--   the closest one out of the top priority map actions.
--   ⇒ playeractionpicker 已按优先级排序，但同一优先级内取**最近**的。
		--NOTE: -playeractionpicker sorted by priorty
		--      -we're picking again to find the closest one out of the top priority map actions.
--   ★ mapactions（用于 SetInherentMapActions，给地图画可点击标记）
--     与 ba（实际选中的动作）是两个不同的收集。
		local mapactions --collect all unique map actions
		local ba --find the closest top priority map action
		local ba_mindsq
		local ba_end = false
		for _, v in ipairs(actions) do
			if v.action.map_only then
				if mapactions then
					mapactions[v.action] = true
				else
					mapactions = { [v.action] = true }
				end
--★ 5191 行 `if not ba_end then`：一旦遇到非 map_only 动作就停止挑选。
--   ⇒ 依赖 playeractionpicker 的**优先级排序**保证 map_only 在前。
--   ⚠ 若某个模组注册了优先级更高的非 map_only 动作，会导致地图动作被跳过。
				if not ba_end then
					local dsq
--   ★ 5195 行 `dsq = valid and DistSq(...) or math.huge`：
--     同样的「and/or 归一」惯用法：合法位置才算距离，否则无穷大。
--     ⚠ 若 DistSq 返回 0（恰好在目标位置），`valid and 0` = 0（Lua 中 0 为真），
--       故不会被 or 分支吞掉。安全。
					if v.action.maponly_checkvalidpos_fn then
						local valid, reason, act_posx, act_posz, mapent = v.action.maponly_checkvalidpos_fn(v)
						dsq = valid and math2d.DistSq(act_posx, act_posz, position.x, position.z) or math.huge
					else
						dsq = math.huge
					end
					if ba == nil or dsq < ba_mindsq then
						ba = v
						ba_mindsq = dsq
					end
				end
			else
				ba_end = true
			end
		end

--   ★ 5210 行的 `ba.action.rmb` 决定强制到哪个键。
--     与 5229 行（actiondef 分支）、5285/5296 行（OnMapAction）同款三处。
--   ⇒ 「动作属于哪个键」是 Action 上的一个布尔字段（actions.lua 定义）。
		if ba then
            if ba.action.rmb then
                forced_rmbact = ba
            else
                forced_lmbact = ba
            end
        end
--   ★ 5218 行 SetInherentMapActions：告诉地图界面「哪些动作是地图专属的」，
--     地图据此决定要不要画图标。纯 UI。
        if self.inst.HUD and self.inst.HUD:IsMapScreenOpen() then
            local mapscreen = TheFrontEnd:GetActiveScreen()
			mapscreen:SetInherentMapActions(mapactions)
        end
--   ★ 5220-5233 行：客户端指定了具体动作（forced_actiondef）→ 无条件强制。
--   5223-5226 行：maptarget 其实是**手持物**时，把它转成 invobject。
--     注释："Unless the action itself is a map_only action then let us say it is
--     fine and force it as highest priority."
--   ⚠ 5225 行 `maptarget = nil` 修改了形参 —— 与 1856 行同款的「入参复用」。
    elseif actiondef and actiondef.map_only then
        -- NOTES(JBK): Unless the action itself is a map_only action then let us say it is fine and force it as highest priority.
        local invobject
        if maptarget and maptarget.components.inventoryitem and maptarget.components.inventoryitem:GetGrandOwner() == self.inst then
            invobject = maptarget
            maptarget = nil
        end

        local ba = BufferedAction(self.inst, maptarget, actiondef, invobject, position)
        if actiondef.rmb then
            forced_rmbact = ba
        else
            forced_lmbact = ba
        end
    end

--★ pos = 玩家当前位置（用于 GetLeftClickActions 的「场景动作」查询）。
--   ⚠ 注意 5240 行传的是**玩家位置**而非地图上的 position：
--     GetLeftClickActions 的 position 参数语义是「场景中实体查询的中心」，
--     而 maptarget 已经显式传了目标实体，所以这里只需玩家位置做距离判定。
    local pos = self.inst:GetPosition()

--   ★ 5238 行 action_maptarget 的三重过滤：有效性 + 非 INLIMBO + 无 INLIMBO 标签。
--     注释 "Workaround passing the maptarget entity if it is out of scope for
--     world actions"。
    local action_maptarget = maptarget and maptarget:IsValid() and not maptarget:HasTag("INLIMBO") and maptarget or nil -- NOTES(JBK): Workaround passing the maptarget entity if it is out of scope for world actions.

    local lmbact = forced_lmbact or self.inst.components.playeractionpicker:GetLeftClickActions(pos, action_maptarget)[1]
    if lmbact then
        lmbact.maptarget = maptarget
        LMBaction = self:RemapMapAction(lmbact, position)
    end

    local rmbact = forced_rmbact or self.inst.components.playeractionpicker:GetRightClickActions(pos, action_maptarget)[1]
    if rmbact then
        rmbact.maptarget = maptarget
        RMBaction = self:RemapMapAction(rmbact, position)
    end

--   ★ 5252-5254 行：左右键动作相同 → 丢弃 LMB（避免地图上出现两个相同图标）。
--     注释 "If the actions are the same for the same target remove the
--     LMBaction"。
--   ⇒ 与 5358 行（GetSceneItemControllerAction 的同款去重）、
--     5444 行（GetGroundUseAction 的同款去重）构成三处同款逻辑。
--   ⚠ 三处都是 `rmb ~= nil and (lmb == nil or lmb.action ~= rmb.action) and rmb or nil`，
--     逐字相同但没有抽成函数。
    if RMBaction and LMBaction and RMBaction.action == LMBaction.action then -- NOTES(JBK): If the actions are the same for the same target remove the LMBaction.
        LMBaction = nil
    end

--   ★ 5256-5257 行：必须清除临时标志。
    self.inst.checkingmapactions = nil
    self.inst.checkingmapactions_pos = nil

    return LMBaction, RMBaction
end

--【UpdateActionsToMapActions】地图界面每帧调用它来刷新玩家的 LMB/RMB 动作。
--   ★ 5265 行：它**替换** self.LMBaction/self.RMBaction（5267 行），
--     即「地图打开时，鼠标动作由地图位置决定」。
--   ⇒ ★ 这就是「地图动作」的实现本质：换一套动作查询的输入。
--   ⚠ 但 5262-5270 行的函数**不检查 IsEnabled** —— 
--     地图打开时游戏自动暂停，OnUpdate 的移动分支会早退（3024 行），
--     所以不会被客户端 OnUpdate 覆盖回去。
function PlayerController:UpdateActionsToMapActions(position, maptarget, forced_actiondef)
    -- NOTES(JBK): This should be called from a map interface to update the player's current actions to the ones the map has.
    -- Currently used by mapscreen.
    local LMBaction, RMBaction = self:GetMapActions(position, maptarget, forced_actiondef)

    self.LMBaction, self.RMBaction = LMBaction, RMBaction

    return LMBaction, RMBaction
end

--★ 【OnMapAction(actioncode, position, maptarget, mod_name)】地图动作的客户端发起 +
--   ★★ 注意：**这个函数客户端和服务端都会跑**（它不是 OnRemote*）。
--   5284 行 `if self.ismastersim then` 分成两半。
function PlayerController:OnMapAction(actioncode, position, maptarget, mod_name)
    local act
--★★ 5274 行的注释是一条重要的模组兼容约定：
--   "Do not shorten to a short circuit logic we do not want base game actions
--    as a fallback this would break everything."
--   → 翻译：**不要**简写成 `mod_name and MOD_ACTIONS[mod_name][code] or ACTIONS[code]`。
--     因为若模组的 code 表里没有这个 code，不应回退到原版动作表。
--     那样模组客户端点击就会执行**原版的另一个动作**。
--   ⇒ 这是「模组命名空间必须严格隔离」的具体实现。
    if mod_name then -- Do not shorten to a short circuit logic we do not want base game actions as a fallback this would break everything.
        act = MOD_ACTIONS_BY_ACTION_CODE[mod_name] and MOD_ACTIONS_BY_ACTION_CODE[mod_name][actioncode] or nil
    else
        act = ACTIONS_BY_ACTION_CODE[actioncode]
    end
--   ★ 双重守卫：动作存在 且（是地图动作 或 地图专属）。
--   ⇒ 非地图动作的 RPC 会被丢弃 —— 这是地图动作的**鉴权**。
--   ⚠ 与 5274 行的严格隔离配合：客户端无法通过地图 RPC 执行任意动作。
    if act == nil or not (act.map_action or act.map_only) then
        return
    end

--   ★ 服务端与客户端**共用** GetMapActions（5283 行在 ismastersim 之外）。
--   ⇒ 与 OnLeftClick 的「服务端用 CLIENT_REQUESTED_ACTION 重算」不同，
--     这里靠 5291/5312 行的 PushAction/PreviewAction 走标准路径，
--     且**没有做 code 匹配校验**。
--   ⚠⚠ 疑似缺陷（缺少 code 校验）：对比 OnLeftClick:2332 行的
--     `buffaction.action.code == actioncode` 双重校验，本函数直接执行。
--     安全性依赖 5279 行的 map_action/map_only 标签检查 ——
--     即「只执行本身标记为地图动作的动作」。
--     推理依据：5283-5293 行无任何 code 比较；
--       而 position/maptarget 全部来自客户端（RPC 层只有 IsPointInRange）。
--   ⇒ 攻击面：客户端可让服务器在**地图任意已探索点**执行任意 map_action。
--     由于这些动作本身都是「玩家在地图上能做的」，风险有限；
--     但距离校验只有 64 格（IsPointInRange 的 4096），比近战距离宽松得多。
	local LMBaction, RMBaction = self:GetMapActions(position, maptarget, act)
    if self.ismastersim then
        if act.rmb then
            if RMBaction then
                self.locomotor:PushAction(RMBaction, true)
            end
        else
            if LMBaction then
                self.locomotor:PushAction(LMBaction, true)
            end
        end
--   无 locomotor 客户端：手工 pre_action_cb + 发 RPC（5305 行）。
--   ★ 5305 行 `SendRPCToServer(RPC.DoActionOnMap, ...)` ——
--     服务端会再次进入本函数（5284 行的 mastersim 分支）并真正执行。
--   ⇒ 即「客户端调用 → 服务端再走一遍同一个函数」。
    elseif self.locomotor == nil then
		-- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
		if act.rmb then
			if RMBaction and RMBaction.action.pre_action_cb then
				RMBaction.action.pre_action_cb(RMBaction)
			end
		else
			if LMBaction and LMBaction.action.pre_action_cb then
				LMBaction.action.pre_action_cb(LMBaction)
			end
		end
        SendRPCToServer(RPC.DoActionOnMap, actioncode, position.x, position.z, maptarget, mod_name)
--   ★★ 5307-5317 行的严重问题：**没有 nil 检查**。
--     `if act.rmb then RMBaction.preview_cb = ...` ——
--     若 GetMapActions 返回的 RMBaction 为 nil，这里会 nil 索引崩溃。
--   ⚠ 5306 行的 CanLocomote 为假时整个分支不进（反而安全），
--     但 CanLocomote 为真且 RMBaction 为 nil 时崩溃。
--     推理依据：5294-5305 行（无 locomotor）分支有 nil 保护
--       （5297 行的 `if RMBaction and RMBaction.action.pre_action_cb`），
--       而 5306-5317 行完全没有对应的 `if RMBaction ~= nil then`。
--   ⚠ 这是**结构不对称**导致的潜在崩溃，与 5294 分支的细致保护形成对比。
--     实际触发条件：玩家在地图上按了一个「只有 LMB 动作」的位置，
--       且客户端有 locomotor 且能预测。
--     ⇒ 这是本文件中最值得上报的一处缺陷。
    elseif self:CanLocomote() then
        if act.rmb then
            RMBaction.preview_cb = function()
                SendRPCToServer(RPC.DoActionOnMap, actioncode, position.x, position.z, maptarget, mod_name)
            end
            self.locomotor:PreviewAction(RMBaction, true)
        else
            LMBaction.preview_cb = function()
                SendRPCToServer(RPC.DoActionOnMap, actioncode, position.x, position.z, maptarget, mod_name)
            end
            self.locomotor:PreviewAction(LMBaction, true)
        end
    end
end

--★★ 【GetLeftMouseAction / GetRightMouseAction】纯 getter。
--   ★ 5322/5326 行只是返回缓存字段 —— 但这两个 getter 是**外部 API**：
--     grep 确认被 componentactions.lua / UI / 地图等多处调用。
--   ⇒ 「缓存」的设计让所有动作判定都读同一个值，天然一致。
function PlayerController:GetLeftMouseAction()
    return self.LMBaction
end

function PlayerController:GetRightMouseAction()
    return self.RMBaction
end

--★ 【GetItemSelfAction(item)】★ 一个**已被掏空**的函数。
--   5333-5335 行两行赋值语句**全部被注释掉**：
--     --[[rmb]] ...GetInventoryActions(item, true)[1] or
--     --[[lmb]] ...GetInventoryActions(item, false)[1]
--   ⇒ act 恒为 nil → 5336 行的 and/or 链恒返回 nil。
--   ⚠⚠ 疑似缺陷（残留的空壳函数）：
--     函数永远返回 nil，但仍有 8 处外部调用（grep 确认）。
--   推理依据：5333-5335 行的两个表达式都在 `--[[ ]]` 块注释里；
--     5336 行 `act ~= nil and ...` 在 act 为 nil 时短路返回 nil。
--   ⇒ 历史推测：K 曾在调试「背包物品的两个动作」，发现由
--     GetItemUseAction（5484 行）统一处理更合适，于是注释掉但保留函数。
--   ⚠ 保留而非删除说明**仍有 UI 在调用它**（widgets/controls.lua 等），
--     删除会破坏 UI。属技术债。
function PlayerController:GetItemSelfAction(item)
--============================================================
-- 【第十段】5330-5941 行：动作查询族尾部 / 库存格子 / ★ OnRemoteBufferedAction
--   / AI 交互广播 / ★ 客户端预测总开关
--============================================================
    if item == nil or (self.handler ~= nil and self.deploy_mode) then
        return
    end
    local act =
        --[[rmb]] self.inst.components.playeractionpicker:GetInventoryActions(item, true)[1] or
        --[[lmb]] self.inst.components.playeractionpicker:GetInventoryActions(item, false)[1]
    return act ~= nil and act.action ~= ACTIONS.LOOKAT and act or nil
end

--★★ 【GetSceneItemControllerAction(item)】手柄对「实体」的动作查询。
--   ★ 与 GetItemUseAction（5484）不同：这里查的是**鼠标模式下鼠标指向时
--     系统会给什么动作**（GetLeftClickActions/GetRightClickActions）。
--   ★ 5339 行的守卫：`item == nil or self:IsAOETargeting()`。
--     AOE 瞄准时不做实体查询（此时关心的是点地，不是实体）。
function PlayerController:GetSceneItemControllerAction(item)
    if item == nil or self:IsAOETargeting() then
        return
    end
--   ★★ 5346-5357 行的过滤：**剔除三类动作**。
--     LOOKAT（查看）—— 有专门的 CONTROLLER 键
--     ATTACK（仅当目标有 combat 组件时）—— 有专门的攻击键
--     WALKTO（走过去）—— 不该占用交互键
--   ⚠ 注意 ATTACK 的条件是 `item.replica.combat ~= nil`：
--     对没有战斗组件的实体（如箱子），ATTACK **不会**被剔除。
--     ⇒ 这意味着对着箱子按 X 键可能得到 ATTACK 动作。
--   ⚠ 疑似缺陷（条件不完整）：本意应该是「凡是 ATTACK 都剔除」，
--     但条件写成了「ATTACK 且目标可战斗」。
--     推理依据：5348 行 `(lmb.action == ACTIONS.ATTACK and item.replica.combat ~= nil)`。
--     实际影响：ATTACK 的 fn 会检查目标合法性（actions.lua），
--       所以对箱子执行 ATTACK 只会「打空气」，不会破坏箱子。
    local itempos = item:GetPosition()
    local lmb = self.inst.components.playeractionpicker:GetLeftClickActions(itempos, item)[1]
    local rmb = self.inst.components.playeractionpicker:GetRightClickActions(itempos, item)[1]
    if lmb ~= nil
        and (lmb.action == ACTIONS.LOOKAT or
            (lmb.action == ACTIONS.ATTACK and item.replica.combat ~= nil) or
            lmb.action == ACTIONS.WALKTO) then
        lmb = nil
    end
    if rmb ~= nil
        and (rmb.action == ACTIONS.LOOKAT or
            (rmb.action == ACTIONS.ATTACK and item.replica.combat ~= nil) or
            rmb.action == ACTIONS.WALKTO) then
        rmb = nil
    end
--   ★ 5358 行的去重：`rmb ~= nil and (lmb == nil or lmb.action ~= rmb.action)`。
--     与 5252/5444 行同款。⚠ 三处重复，未抽函数。
    return lmb, rmb ~= nil and (lmb == nil or lmb.action ~= rmb.action) and rmb or nil
end

--【IsAxisAlignedPlacement】轴对齐放置（0/45/90 度）是否激活。
--   ★ 消费点：588 行（优先级仲裁）、4071 行（菜单里切换对齐）、5040 行（部署）。
function PlayerController:IsAxisAlignedPlacement()
    return (self.placer and self.placer.components.placer and self.placer.components.placer:IsAxisAlignedPlacement()) or
    (self.deployplacer and self.deployplacer.components.placer and self.deployplacer.components.placer:IsAxisAlignedPlacement()) or
    false
end

--【GetPlacerPosition】三个放置器（建造/部署/terraformer）的位置查询。
--   优先级：placer > deployplacer（terraformer 在 5383 行单独处理）。
function PlayerController:GetPlacerPosition()
    return (self.placer ~= nil and self.placer:GetPosition()) or
    (self.deployplacer ~= nil and self.deployplacer:GetPosition()) or
    nil
end

--★★★ 【GetGroundUseAction(position, spellbook)】★ **点地动作查询（最核心的查询）**。
--   被 4 处调用：831（手柄X）、1004/1012/1248（服务端）、2921（手柄高亮）。
--   ★ 它承担了「鼠标模式下右键点地面」和「手柄模式下 X/Y 键」的共同查询。
--   结构：
--     ① 5374-5378 容器 widget 优先 / 魔术帽特判
--     ② 5380-5386 ★ 位置的四级回退（准星→terraformer→放置器→自己）
--     ③ 5387-5403 可见性 + 可施法性判定
--     ④ 5404-5405 ★ 取 LMB/RMB 点地动作
--     ⑤ 5406-5443 TERRAFORM 特判与草皮移除
function PlayerController:GetGroundUseAction(position, spellbook)
--   ★ HasContainerWidgetAction()：当前有容器（箱子/冰箱）打开。
--     ⇒ 打开容器时地面动作全部失效（避免「开着箱子还能挖地」）。
--     参见 playeractionpicker.lua:38。
    if self.inst.components.playeractionpicker:HasContainerWidgetAction() then
        return
--   ★ usingmagiciantool：魔术帽使用中 → 只提供「停止使用」这一个动作。
--   5377 行 `return nil, BufferedAction(...)` —— ★★ 注意返回**两个值**：
--     LMB 为 nil（地面无动作），RMB 是 STOPUSINGMAGICTOOL。
--     ⇒ 符合「右键取消」的语义。
	elseif self.inst:HasTag("usingmagiciantool") then
		return nil, BufferedAction(self.inst, self.inst, ACTIONS.STOPUSINGMAGICTOOL)
	end

--★★ 5380 行 islocal = (position == nil) —— **「本地查询」标志**。
--   ★★ 它决定三个行为：
--     ① 5393 行：islocal 时才从手持物读 aoetargeting 参数
--     ② 5388 行：islocal 时才尝试自动填充 spellbook
--     ③ 5405 行：islocal 时才可能取 RMB（远端查询只取 LMB）
--   ⚠ 5388 行 `local isaoetargeting = islocal and self:IsAOETargeting()` ——
--     AOE 瞄准只在本地查询时生效。服务端重算时 islocal 为 false，
--     ⇒ ★ 这解释了服务端为何能用 GetGroundUseAction 重算出 CASTAOE：
--       客户端会通过 spellbook 参数显式传入（988-1013 行），绕开 islocal 依赖。
    local islocal = position == nil
--★★ 5381-5385 行：目标位置的**四级回退**。
--     ① 准星位置（但排除「准星属于玩家自己」的情况 —— 5382 行的
--        `self.reticule.inst ~= self.inst` 判断）
--     ② terraformer（右键地形放置器）的位置
--     ③ 建造/部署放置器的位置
--     ④ 玩家自己的位置（脚下）
--   ⇒ ★ 5382 行的排除很重要：玩家自己的 reticule（默认准星）跟随鼠标，
--     不能用它当「点地位置」，否则移动鼠标会改变脚下动作。
    position = position or
        (self.reticule ~= nil and self.reticule.inst ~= self.inst and self.reticule.targetpos) or
        (self.terraformer ~= nil and self.terraformer:GetPosition()) or
        self:GetPlacerPosition() or
        self.inst:GetPosition()

--★ 可见性检查（CanEntitySeePoint，simutil.lua:536）：含光照判定。
--   ⇒ 黑暗中的点不能交互（除非玩家有夜视）。
    if CanEntitySeePoint(self.inst, position:Get()) then
		local isaoetargeting = islocal and self:IsAOETargeting()
		if isaoetargeting and spellbook == nil then
			spellbook = self:GetActiveSpellBook()
		end
        --Check validitiy because FE controls may call this in WallUpdate
		local item = spellbook or self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
		if item ~= nil and item:IsValid() then
--★★ 5395-5403 行：AoE 施法参数从**手持物组件**读出。
--   alwaysvalid：无视地形（法术可空中施放）
--   allowwater：可对水施放
--   deployradius：投放半径（如藤壶的粘液）
--   5402 行额外合并 `item:HasTag("allow_action_on_impassable")`（标签兜底）。
--   ★ 5403 行 `self.map:CanCastAtPoint(...)` 是最终的地图合法性判定。
			local alwayspassable, allowwater, deployradius
			local aoetargeting = item.components.aoetargeting
			if aoetargeting ~= nil and aoetargeting:IsEnabled() then
				alwayspassable = aoetargeting.alwaysvalid
				allowwater = aoetargeting.allowwater
				deployradius = aoetargeting.deployradius
			end
			alwayspassable = alwayspassable or item:HasTag("allow_action_on_impassable")
			if self.map:CanCastAtPoint(position, alwayspassable, allowwater, deployradius) then
--★ 5404 行 `not isaoetargeting and ...GetPointActions(position, item, false, nil)[1] or nil`：
--   ★★ AOE 瞄准时**不取 LMB**（瞄准中只按右键施法）。
--     → 与 4732 行（鼠标 AOE 用 GetRightMouseAction）一致。
				local lmb = not isaoetargeting and self.inst.components.playeractionpicker:GetPointActions(position, item, false, nil)[1] or nil
--★★ 5405 行的条件是本函数最复杂的一行：
--   `(not islocal or isaoetargeting or item.components.aoetargeting == nil
--    or not item.components.aoetargeting:IsEnabled()) and ...GetPointActions(..., true, ...)`
--   展开：「不是本地查询」 OR 「在 AOE 瞄准」 OR 「手持物没有 aoetargeting」
--     OR 「aoetargeting 未启用」→ 取 RMB 点地动作。
--   ⇒★ 语义：**本地查询且手持物支持 AOE 瞄准时，不取普通 RMB**
--     （因为 RMB 已被施法占用）。
--   ⚠ 四个条件的 or 冗长但语义清晰，优于 5136 行的隐式优先级。
				local rmb = (not islocal or isaoetargeting or item.components.aoetargeting == nil or not item.components.aoetargeting:IsEnabled()) and self.inst.components.playeractionpicker:GetPointActions(position, item, true, nil)[1] or nil
--★ 5407-5411 行的动作改写：
--   DROP → 丢弃动作不能作为「点地 LMB」（否则右键丢弃会变成左键动作）
--   TERRAFORM → 距离改成 2（挖地需要够到格子中心）
--   ★★ 这些改写直接修改了 playeractionpicker 返回的动作实例。
--   ⚠ BufferedAction 是每次新建的（picker 里新建），所以修改安全。
				if lmb ~= nil then
					if lmb.action == ACTIONS.DROP then
						lmb = nil
					elseif lmb.action == ACTIONS.TERRAFORM then
						lmb.distance = 2
					end
				end
				if rmb ~= nil and rmb.action == ACTIONS.TERRAFORM then
					rmb.distance = 2
				end
--★★ 【5416-5443 草皮移除特判】★ 与 3409-3428 行是**完整复制**。
--   注释文字与 3410-3411 行几乎逐字相同。
--   ⚠ 疑似缺陷（代码重复）：两处必须同步修改。
--     推理依据：对比 3420-3421 与 5420-5421 行的注释：
--       "Special case for ACTIONS.TERRAFORM_REMOVE via placed turf visuals"
--       "We will use the player's origin to find things with the tag"
--     仅缩进不同。
--   ★ 5435/5440 行的 `distance = 0`：★ 因为目标是自己脚下的草皮视觉体，
--     原点就在玩家身上，距离判据必须放宽为 0。
                local lmb_terraforming = lmb and lmb.action == ACTIONS.TERRAFORM
                local rmb_terraforming = rmb and rmb.action == ACTIONS.TERRAFORM
                if lmb_terraforming or rmb_terraforming then
                    local tool = self.inst.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
                    -- Special case for ACTIONS.TERRAFORM_REMOVE via placed turf visuals needing to take highest priority over all other checks due to increased range from entity origin.
                    -- We will use the player's origin to find things with the tag to use the action.
                    local x, y, z = self.inst.Transform:GetWorldPosition()
                    local terraform_remove_target = nil
                    local ents = TheSim:GetEntitiesAtScreenPoint(TheSim:GetScreenPos(x, y, z))
                    for _, ent in ipairs(ents) do
                        if ent:HasTag("terraformerremoveable") then
                            terraform_remove_target = ent
                            break
                        end
                    end
                    if terraform_remove_target then
                        if lmb_terraforming then
                            lmb.action = ACTIONS.TERRAFORM_REMOVE
                            lmb.target = terraform_remove_target
                            lmb.distance = 0
                        end
                        if rmb_terraforming then
                            rmb.action = ACTIONS.TERRAFORM_REMOVE
                            rmb.target = terraform_remove_target
                            rmb.distance = 0
                        end
                    end
                end
--   ★ 与 5358/5252 行同款的去重（第三次出现）。
				return lmb, rmb ~= nil and (lmb == nil or lmb.action ~= rmb.action) and rmb or nil
			end
        end
    end
end

--★★ 【GetGroundUseSpecialAction(position, right)】「特殊」点地动作。
--   与 GetGroundUseAction 的区别：
--     · 不查手持物（5459 行只查地形与 picker 的 special 动作）
--     · 用 GetPointSpecialActions（225 行）而非 GetPointActions
--   ★ 5451 行注释掉的 `local islocal = position == nil` ——
--     表明**曾经**也有本地/远端之分，但被移除了。
--   ⚠ 5458-5460 行的三连判（可见 && 可通行 && 有动作）：
--     ★ IsPassableAtPoint 比 CanCastAtPoint 严格 —— 特殊动作不能对水/墙。
function PlayerController:GetGroundUseSpecialAction(position, right)
    --local islocal = position == nil
    position = position or
        (self.reticule ~= nil and self.reticule.targetpos) or
        (self.terraformer ~= nil and self.terraformer:GetPosition()) or
        self:GetPlacerPosition() or
        self.inst:GetPosition()

    return CanEntitySeePoint(self.inst, position:Get())
        and self.map:IsPassableAtPoint(position:Get())
        and self.inst.components.playeractionpicker:GetPointSpecialActions(position, nil, right)[1]
        or nil
end

--【HasGroundUseSpecialAction(right)】★ 存在性查询（不算具体动作）。
--   ★ 5465 行传了**第四个参数 true**（usereticulepos），与 5460 行不同。
--     用途不同：这里只问「有没有」，所以用准星位置参数以匹配实际查询。
--   消费点：2933 行（决定要不要藏准星）。
function PlayerController:HasGroundUseSpecialAction(right)
	return #self.inst.components.playeractionpicker:GetPointSpecialActions(self.inst:GetPosition(), nil, right, true) > 0
end

--★ 【ValidateItemUseAction】物品使用动作的过滤器（局部函数，不导出）。
--   5470 行：`active_item:HasTag(act.action.id.."_tool")` 为真则拒绝。
--   ★★ 这是「装备的物品不能被自己用」的判据（防「手持斧头用斧头砍树」）。
--     标签约定：动作 CHOP 的 tool 标签是 chop_tool。
--   ⚠ 5470 行 `active_item.replica.equippable == nil or ...` 的短路顺序：
--     若没有 equippable 组件则放行。
local function ValidateItemUseAction(self, act, active_item, target)
    return act ~= nil and
        (active_item.replica.equippable == nil or not active_item:HasTag(act.action.id.."_tool")) and
--   ★ 5471 行：STORE/BUNDLESTORE 只在「目标自己不是物主」时允许。
--     ⇒ 不能把东西存进自己已经拿着的容器（会形成循环嵌套）。
        ((act.action ~= ACTIONS.STORE and act.action ~= ACTIONS.BUNDLESTORE) or target.replica.inventoryitem == nil or not target.replica.inventoryitem:IsGrandOwner(self.inst)) and
--   COMBINESTACK（合并堆叠）与 ATTACK 一律拒绝 —— 它们是右键专属动作，
--   不应出现在 GetUseItemActions 的结果里。
        act.action ~= ACTIONS.COMBINESTACK and
        act.action ~= ACTIONS.ATTACK and
        act or nil
end

--#V2C #Hack to allow controllers to Store in Magician's Top Hat while mounted.
--           This is for DPAD actions, so they don't have to open inventory UI
--           to access the unfiltered UI actions.
--★ AllowMountedStoreActionFilter：骑乘时的动作过滤器（模组 hack）。
--   5477-5479 行的注释："--#V2C #Hack to allow controllers to Store in
--   Magician's Top Hat while mounted. This is for DPAD actions, so they don't
--   have to open inventory UI to access the unfiltered UI actions."
--   → 翻译：允许骑乘时用手柄方向键把东西存进魔术帽。
--   ★ 5491 行的注释 "See rider_replica MountedActionFilter; match priority" ——
--     ★★ 明确要求优先级与 rider 副本里的过滤器**匹配**。
--     这是跨组件的隐式契约，改一处必须改另一处。
--     推理依据：注释自认；ACTION_FILTER_PRIORITIES.mounted（5510 行使用）。
local function AllowMountedStoreActionFilter(inst, action)
	return action.mount_valid or action == ACTIONS.STORE
end

--★★ 【GetItemUseAction(active_item, target)】★ 手柄「对某物使用手持物」的查询。
--   5490-5504 行的 target 解析四级：
--     ① 5491 行：显式 target 或 GetControllerTarget()（手柄选中目标）
--     ② 5493-5504 行：魔术帽使用中 → 从打开的容器里找可写的
--     ③ 5506-5514 行：骑乘特例（允许存进魔术帽）
function PlayerController:GetItemUseAction(active_item, target)
    if active_item == nil then
        return
    end

	local allow_mounted_store = target ~= nil and target:HasTag("pocketdimension_container")
--   ★ 5489 行 `target ~= nil and target:HasTag("pocketdimension_container")`：
--     ★★★ 这行在 5491 行的 `target = target or GetControllerTarget()` **之前**——
--     即「显式传入的 target 是口袋维度容器」才算 allow_mounted_store，
--     而手柄自动选中的目标不算。
--     ⚠ 疑似缺陷（判断时机）：
--       若玩家手柄选中的目标恰好是口袋维度容器（5491 行填入的 target），
--       5489 行已经算过 allow_mounted_store = false，之后不再补算。
--     推理依据：5489 行用入参 target，5491 行才用 GetControllerTarget() 覆盖。
--     影响：手柄模式下骑乘时无法把东西存进自动选中的口袋容器。
--     推测：这是「先算标志再解析目标」的顺序疏漏，而非有意。

    target = target or self:GetControllerTarget()

--   ★ 5493-5504 行：魔术帽使用中且无目标 → 从打开的容器里找一个可写的。
--   ★ 5499 行 `k.replica.container == nil or not IsReadOnlyContainer()`：
--     ★★ 同时允许「还没有 container 组件」的容器（客户端未同步时）。
--     这是客户端预测必需的宽松 —— 但也意味着在组件同步完成前
--     客户端会显示「可存储」而服务端拒绝。
--   ⚠ 5495 行 `break` —— 取第一个匹配即止（unordered pairs 遍历，
--     所以若开多个魔术帽，选中哪个不确定）。
	if target == nil and self.inst:HasTag("usingmagiciantool") then
		local containers = self.inst.replica.inventory:GetOpenContainers()
		if containers ~= nil then
			for k in pairs(containers) do
				if k:HasTag("pocketdimension_container") and (k.replica.container == nil or not k.replica.container:IsReadOnlyContainer()) then
					target = k
					allow_mounted_store = true
					break
				end
			end
		end
	end

--★★ 5506-5514 行：骑乘特例的动作过滤器安装。
--   ★ 5508 行必须 rider:IsRiding()，否则 5512 行撤销 allow_mounted_store。
--     ⇒ 非骑乘时这个标签白名单不生效，保持「骑乘时不显示容器动作」的常规规则。
--   ⚠ 5510 行注释 "See rider_replica MountedActionFilter; match priority" ——
--     ★★ 显式要求与 rider 副本的过滤器优先级**匹配**。
--     推理依据：这是跨组件隐式契约；若 rider_replica 改了优先级而这里没改，
--       过滤顺序会错乱（一个动作可能被过滤两次或一次都不过滤）。
--     ⇒ 参见 components/rider_replica.lua 的 MountedActionFilter 与
--       ACTION_FILTER_PRIORITIES.mounted。
	if allow_mounted_store then
		local rider = self.inst.replica.rider
		if rider ~= nil and rider:IsRiding() then
			--See rider_replica MountedActionFilter; match priority
			self.inst.components.playeractionpicker:PushActionFilter(AllowMountedStoreActionFilter, ACTION_FILTER_PRIORITIES.mounted)
		else
			allow_mounted_store = false
		end
	end

--★★ 5516-5519 行：**右键优先，再取左键**。
--   注释用 `--[[rmb]]` / `--[[lmb]]` 标注了两次调用的语义（该注释风格全文件通用）。
--   ⇒ 与 5414 行的顺序一致（先 rmb 后 lmb）。
    local act = target ~= nil and (
        ValidateItemUseAction(--[[rmb]] self, self.inst.components.playeractionpicker:GetUseItemActions(target, active_item, true)[1], active_item, target) or
        ValidateItemUseAction(--[[lmb]] self, self.inst.components.playeractionpicker:GetUseItemActions(target, active_item, false)[1], active_item, target)
    ) or nil

--   5521-5523 行：及时弹出过滤器（try/finally 模式）。
--   ⚠ 若 5517-5518 行的 picker 抛错，过滤器会泄漏在栈上。
--     实际不会抛（纯数据查询），属理论风险。
	if allow_mounted_store then
		self.inst.components.playeractionpicker:PopActionFilter(AllowMountedStoreActionFilter)
	end

--★★ 5525-5535 行：没有目标时退回「对自己用」（背包格动作）。
--   5531 行 `lmb.action ~= rmb.action and lmb.action ~= ACTIONS.LOOKAT`：
--     ★ 排除 LOOKAT（查看物品）—— 因为它已在 GetItemSelfAction（被掏空）里处理过。
--   ⚠ 但 GetItemSelfAction 现在返回 nil ⇒ LOOKAT 的物品查看路径可能已失效。
--     推理依据：5531 行的注释说 "GetItemSelfAction would've used the rmb one"，
--       说明这段是为配合 GetItemSelfAction 而写的；后者被掏空后，
--       LOOKAT 在这条路径上不再被产出（但 5361/4811 行的 LOOKAT 路径仍可用）。
	if act == nil and target == nil then
		--V2C: We have no ItemUseAction, try taking another ItemSelfAction (see GetItemSelfAction).
		local rmb = self.inst.components.playeractionpicker:GetInventoryActions(active_item, true)[1]
		if rmb then
			--GetItemSelfAction would've used the rmb one, so lets try the lmb one
			local lmb = self.inst.components.playeractionpicker:GetInventoryActions(active_item, false)[1]
			if lmb and lmb.action ~= rmb.action and lmb.action ~= ACTIONS.LOOKAT then
				act = lmb
			end
		end
	end

--★ 5538-5540 行：存进「口袋维度」（无限 dumping bag 变体）→ 标记为 instant。
--   ★ `act.options.instant = true` 让 locomotor 不缓冲，立即执行。
--     因为「存进口袋」不该要求玩家走过去。
--   ⚠ options 是 BufferedAction 实例的字段（bufferedaction.lua:14），安全。
	if act ~= nil then
		if act.action == ACTIONS.STORE and act.target ~= nil and act.target:HasTag("pocketdimension_container") then
			act.options.instant = true
		end
--   magiciantool + magician 标签（魔术师角色）→ 唯一动作 USEMAGICTOOL。
--   ★ 兜底分支：当没有任何物品使用动作时的最后手段。
	elseif active_item:HasTag("magiciantool") and self.inst:HasTag("magician") then
		act = BufferedAction(self.inst, nil, ACTIONS.USEMAGICTOOL, active_item)
	end

	if act ~= nil then
		return act
--★ 5547-5559 行：**可部署物品**在无其他动作时的兜底。
--   5549-5550 行的注释解释了 rmb/lmb 的强制：
--     "When not mounted, use self actions blocked by controller R.Dpad
--      'TOGGLE_DEPLOY_MODE' / So force it onto L.Dpad instead here"
--     → 未骑乘时 R.Dpad 是「切换部署模式」键，所以这里用 L.Dpad。
--   ★ 5552-5553 行的 `act[1] ~= nil and act[1].action ~= TOGGLE_DEPLOY_MODE and act[1] or act[2]`：
--     ★★ 经典的 and/or 惯用法：取「第一个非 TOGGLE_DEPLOY_MODE 的动作」，
--       若第一项就是 TOGGLE 则取第二项。
--     ⚠ 疑似缺陷（Lua 真值陷阱）：若 act[1] 为 nil，`nil ~= nil` 为 false → 取 act[2]。正确。
--       若 act[1] 存在但其 action 是 TOGGLE → false → 取 act[2]。正确。
--       若 act[1] 存在且不是 TOGGLE → act[1]。正确。
--     ⇒ 逻辑正确，但极难读。建议改成显式 if。
	elseif active_item.replica.inventoryitem:IsDeployable(self.inst) and active_item.replica.inventoryitem:IsGrandOwner(self.inst) then
		--Deployable item, no item use action generated yet
		--V2C: When not mounted, use self actions blocked by controller R.Dpad "TOGGLE_DEPLOY_MODE"
		--     So force it onto L.Dpad instead here
		--     e.g. Murder/Plant, Eat/Plant
		act = --[[rmb]] self.inst.components.playeractionpicker:GetInventoryActions(active_item, true)
		act = act[1] ~= nil and act[1].action ~= ACTIONS.TOGGLE_DEPLOY_MODE and act[1] or act[2]
		if act == nil then
			act = --[[lmb]] self.inst.components.playeractionpicker:GetInventoryActions(active_item, false)
			act = act[1] ~= nil and act[1].action ~= ACTIONS.TOGGLE_DEPLOY_MODE and act[1] or act[2]
		end
		return act ~= nil and act.action ~= ACTIONS.LOOKAT and act or nil
	end
end

--【RemoteUseItemFromInvTile】库存格子「使用」的客户端发起端。
function PlayerController:RemoteUseItemFromInvTile(buffaction, item)
    if not self.ismastersim then
        local controlmods = self:EncodeControlMods()
        if self.locomotor == nil then
            -- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if buffaction.action.pre_action_cb ~= nil then
				if self:IsBusy() then
					return --V2C: Block inv tile actions that have pre_action_cb; otherwise send RPC anyway for better responsiveness.
				end
				buffaction.action.pre_action_cb(buffaction)
			end
            SendRPCToServer(RPC.UseItemFromInvTile, buffaction.action.code, item, controlmods, buffaction.action.mod_name)
--   5574-5580 行：有 locomotor 且能预测且不 busy → 走 preview。
--   ★ 与 5563 行的 `self.locomotor == nil` 分支构成标准二选一。
        elseif buffaction.action ~= ACTIONS.WALKTO
            and self:CanLocomote()
            and not self:IsBusy() then
            buffaction.preview_cb = function()
                SendRPCToServer(RPC.UseItemFromInvTile, buffaction.action.code, item, controlmods, buffaction.action.mod_name)
            end
            self.locomotor:PreviewAction(buffaction, true)
        end
    end
end

--★★ 【RemoteControllerUseItemOnItemFromInvTile】★ 「在物品 A 上用物品 B」。
--   5586 行的 `if not self.ismastersim then` —— 注意其他函数用 `== nil`，
--     这里用 `not ... then`，语义等价但风格不一致。
--   ⚠ 四个 Remote*InvTile 函数（5562/5585/5607/5629）的结构**逐字重复**，
--     只有 RPC 名与参数不同。未抽成通用函数。
--     推理依据：5562-5583 / 5585-5605 / 5607-5627 / 5629-5649 四段结构一致。
function PlayerController:RemoteControllerUseItemOnItemFromInvTile(buffaction, item, active_item)
    if not self.ismastersim then
        if self.locomotor == nil then
            -- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if buffaction.action.pre_action_cb ~= nil then
				if self:IsBusy() then
					return --V2C: Block inv tile actions that have pre_action_cb; otherwise send RPC anyway for better responsiveness.
				end
				buffaction.action.pre_action_cb(buffaction)
			end
            SendRPCToServer(RPC.ControllerUseItemOnItemFromInvTile, buffaction.action.code, item, active_item, buffaction.action.mod_name)
        elseif buffaction.action ~= ACTIONS.WALKTO
            and self:CanLocomote()
            and not self:IsBusy() then
            buffaction.preview_cb = function()
                SendRPCToServer(RPC.ControllerUseItemOnItemFromInvTile, buffaction.action.code, item, active_item, buffaction.action.mod_name)
            end
            self.locomotor:PreviewAction(buffaction, true)
        end
    end
end

--【RemoteControllerUseItemOnSelfFromInvTile】★ 「对自己用」。
--   ★ 与 5585 行版相比只是少一个 active_item 参数。
--   ★ 5617 行的注释 "--V2C: Block inv tile actions that have pre_action_cb;
--   otherwise send RPC anyway for better responsiveness" ——
--     这是四个函数**共用同一条 V2C 权衡**（见 5569 行的详细分析）：
--       有状态变化的动作在 busy 时被吞掉，普通动作为响应速度可绕过。
--   ⚠ 5613 行的 `if self:IsBusy() then return end` 会让玩家的按键**完全无响应**。
--     玩家视角：手柄在手上之物时突然失灵。属可接受但需文档化的取舍。
function PlayerController:RemoteControllerUseItemOnSelfFromInvTile(buffaction, item)
    if not self.ismastersim then
        if self.locomotor == nil then
            -- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if buffaction.action.pre_action_cb ~= nil then
				if self:IsBusy() then
					return --V2C: Block inv tile actions that have pre_action_cb; otherwise send RPC anyway for better responsiveness.
				end
				buffaction.action.pre_action_cb(buffaction)
			end
            SendRPCToServer(RPC.ControllerUseItemOnSelfFromInvTile, buffaction.action.code, item, buffaction.action.mod_name)
        elseif buffaction.action ~= ACTIONS.WALKTO
            and self:CanLocomote()
            and not self:IsBusy() then
            buffaction.preview_cb = function()
                SendRPCToServer(RPC.ControllerUseItemOnSelfFromInvTile, buffaction.action.code, item, buffaction.action.mod_name)
            end
            self.locomotor:PreviewAction(buffaction, true)
        end
    end
end

--【RemoteControllerUseItemOnSceneFromInvTile】★ 「对世界用」。
--   ★ 5639 行的 RPC 带 buffaction.target —— 这是四个里唯一带目标的。
--     ⇒ 「对世界用」需要告诉服务端用在哪（服务端会重算，见 5730 行模式）。
--   ⚠ 5629-5649 行与 5607-5627 行逐字相同（除 RPC 名与 target 参数），
--     是「四份复制」的第四份。
function PlayerController:RemoteControllerUseItemOnSceneFromInvTile(buffaction, item)
    if not self.ismastersim then
        if self.locomotor == nil then
            -- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if buffaction.action.pre_action_cb ~= nil then
				if self:IsBusy() then
					return --V2C: Block inv tile actions that have pre_action_cb; otherwise send RPC anyway for better responsiveness.
				end
				buffaction.action.pre_action_cb(buffaction)
			end
            SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, buffaction.action.code, item, buffaction.target, buffaction.action.mod_name)
        elseif buffaction.action ~= ACTIONS.WALKTO
            and self:CanLocomote()
            and not self:IsBusy() then
            buffaction.preview_cb = function()
                SendRPCToServer(RPC.ControllerUseItemOnSceneFromInvTile, buffaction.action.code, item, buffaction.target, buffaction.action.mod_name)
            end
            self.locomotor:PreviewAction(buffaction, true)
        end
    end
end

--【RemoteInspectItemFromInvTile】查看库存物品。
--   ★ 5655-5657 行：即使是无 locomotor 客户端也要调 LOOKAT 的 pre_action_cb。
--     与其他 invTile 函数的「busy 时 return」不同，这里**没有** busy 检查。
--   ⚠ 疑似缺陷（守卫缺失）：查看是无害的，busy 时也允许。属有意为之。
function PlayerController:RemoteInspectItemFromInvTile(item)
    if not self.ismastersim then
        if self.locomotor == nil then
			-- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if ACTIONS.LOOKAT.pre_action_cb ~= nil then
				ACTIONS.LOOKAT.pre_action_cb(BufferedAction(self.inst, nil, ACTIONS.LOOKAT, item))
			end
            SendRPCToServer(RPC.InspectItemFromInvTile, item)
        elseif self:CanLocomote() then
            local buffaction = BufferedAction(self.inst, nil, ACTIONS.LOOKAT, item)
            buffaction.preview_cb = function()
                SendRPCToServer(RPC.InspectItemFromInvTile, item)
            end
            self.locomotor:PreviewAction(buffaction, true)
        end
    end
end

--★ 5682 行 `buffaction.options.instant = self.inst.sg:HasStateTag("overridelocomote")`：
--   ★★ 丢弃物品的 instant 性**取决于状态图**！
--     在 overridelocomote 态（如温泉里）丢东西是瞬发的（不用走过去）。
--   ⚠ 直接读 sg:HasStateTag，无 sg 检查 —— 但玩家必有 sg。
function PlayerController:RemoteDropItemFromInvTile(item, single)
    if not self.ismastersim then
        if self.locomotor == nil then
			-- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if ACTIONS.DROP.pre_action_cb ~= nil then
				ACTIONS.DROP.pre_action_cb(BufferedAction(self.inst, nil, ACTIONS.DROP, item, self.inst:GetPosition()))
			end
            SendRPCToServer(RPC.DropItemFromInvTile, item, single or nil)
        elseif self:CanLocomote() then
            local buffaction = BufferedAction(self.inst, nil, ACTIONS.DROP, item, self.inst:GetPosition())
            buffaction.preview_cb = function()
                SendRPCToServer(RPC.DropItemFromInvTile, item, single or nil)
            end
			buffaction.options.instant = self.inst.sg:HasStateTag("overridelocomote")
            self.locomotor:PreviewAction(buffaction, true)
        end
    end
end

--【RemoteCastSpellBookFromInv】从库存释放法术。
--   5690-5691 行的 target/invobject 二选一（与 5585 行同款）。
--   5692 行 spell_action 可覆盖（不同法术书的默认动作不同）。
function PlayerController:RemoteCastSpellBookFromInv(item, spell_id, spell_action)
	if not self.ismastersim then
		local target = item == self.inst and item or nil
		local invobject = item ~= self.inst and item or nil
		spell_action = spell_action or ACTIONS.CAST_SPELLBOOK
		if self.locomotor == nil then
			-- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if spell_action.pre_action_cb then
				spell_action.pre_action_cb(BufferedAction(self.inst, target, spell_action, invobject))
			end
			SendRPCToServer(RPC.CastSpellBookFromInv, item, spell_id)
		elseif self:CanLocomote() then
			local buffaction = BufferedAction(self.inst, target, spell_action, invobject)
			buffaction.preview_cb = function()
				SendRPCToServer(RPC.CastSpellBookFromInv, item, spell_id)
			end
			self.locomotor:PreviewAction(buffaction, true)
		end
	end
end

--【RemoteMakeRecipeFromMenu / RemoteMakeRecipeAtPoint】建造菜单的两条路径。
--   ★ 5711 行用 `PREFAB_SKINS_IDS[recipe.product][skin]`（菜单路径查 product），
--     5731 行用 `PREFAB_SKINS_IDS[recipe.name][skin]`（放置路径查 name）。
--   ⚠⚠ 疑似缺陷（索引键不一致）：
--     5711 行查 recipe.product，5731 行查 recipe.name。
--     若某配方的 product 与 name 不同（常见：product 是物品名，name 是配方名），
--     两处会查出不同的皮肤索引 → 皮肤错乱或 nil 索引崩溃。
--   推理依据：对比 5711 行与 5731 行的 `[recipe.product]` vs `[recipe.name]`。
--     5735/5741 行的 BufferedAction 都用 recipe.name 作为第 6 参数，
--     说明 name 才是配方的权威键 ⇒ 5711 行更可疑。
function PlayerController:RemoteMakeRecipeFromMenu(recipe, skin)
    if not self.ismastersim then
        local skin_index = skin ~= nil and PREFAB_SKINS_IDS[recipe.product][skin] or nil
        if self.locomotor == nil then
			-- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if ACTIONS.BUILD.pre_action_cb ~= nil then
				ACTIONS.BUILD.pre_action_cb(BufferedAction(self.inst, nil, ACTIONS.BUILD, nil, nil, recipe.name, 1))
			end
            SendRPCToServer(RPC.MakeRecipeFromMenu, recipe.rpc_id, skin_index)
        elseif self:CanLocomote() then
            self.locomotor:Stop()
            local buffaction = BufferedAction(self.inst, nil, ACTIONS.BUILD, nil, nil, recipe.name, 1)
            buffaction.preview_cb = function()
                SendRPCToServer(RPC.MakeRecipeFromMenu, recipe.rpc_id, skin_index)
            end
            self.locomotor:PreviewAction(buffaction, true)
        end
    end
end

function PlayerController:RemoteMakeRecipeAtPoint(recipe, pt, rot, skin)
    if not self.ismastersim then
        local skin_index = skin ~= nil and PREFAB_SKINS_IDS[recipe.name][skin] or nil
        if self.locomotor == nil then
			-- NOTES(JBK): Does not call locomotor component functions needed for pre_action_cb, manual call here.
			if ACTIONS.BUILD.pre_action_cb ~= nil then
				ACTIONS.BUILD.pre_action_cb(BufferedAction(self.inst, nil, ACTIONS.BUILD, nil, pt, recipe.name, 1, nil, rot))
			end
--★ 5737 行 MakeRecipeAtPoint 需要平台相对坐标（建造也要处理平台）。
	        local platform, pos_x, pos_z = self:GetPlatformRelativePosition(pt.x, pt.z)
            SendRPCToServer(RPC.MakeRecipeAtPoint, recipe.rpc_id, pos_x, pos_z, rot, skin_index, platform, platform ~= nil)
        elseif self:CanLocomote() then
--★ 5740 行 `self.locomotor:Stop()` —— 建造前先停移动（其余函数没有）。
--   ⇒ 建造是「站定不动」的动作，与挖矿不同（挖矿可以边走边挖）。
            self.locomotor:Stop()
            local act = BufferedAction(self.inst, nil, ACTIONS.BUILD, nil, pt, recipe.name, 1, nil, rot)
--   ★ 5743 行的 preview_cb **重新读** act.pos.local_pt —— 而不是用 5737 行的 pt。
--     因为 preview_cb 触发时 act.pos 可能已被平台移动改写。
--   ⚠ 这与 5738 行（非 preview 路径用闭包捕获的 pt）不一致。
--   ⇒ 两条路径的平台处理精度不同。属实现细节的差异。
            act.preview_cb = function()
                SendRPCToServer(RPC.MakeRecipeAtPoint, recipe.rpc_id, act.pos.local_pt.x, act.pos.local_pt.z, rot, skin_index, act.pos.walkable_platform, act.pos.walkable_platform ~= nil)
            end
            self.locomotor:PreviewAction(act, true)
        end
    end
end

--★★★ 【RemoteBufferedAction(buffaction)】★★ 由 locomotor 在**预览回调时**调用。
--   5751 行守卫：classified.iscontrollerenabled（服务端的输入启用位）。
--   ★★ 5752-5758 行：在发动作 RPC 之前，**先把最后的预测行走发出去**。
--     "If we're starting a remote buffered action, prevent the last movement
--      prediction vector from cancelling us out right away"（5801 行同款注释）
--   ⇒★ 原因：客户端站在某处准备动作，但服务器还以为它在走向别处。
--     若不先同步位置，服务器会先执行「到达预测点」再执行动作，
--     造成明显的延迟。
--   ⇒ 这就是「动作与移动的交接协议」：动作开始前，先把位置对齐。
function PlayerController:RemoteBufferedAction(buffaction)
	if self.classified and self.classified.iscontrollerenabled:value() then
		if self.client_last_predict_walk.tick then
--★ 5753 行 `--V2C: not GetPredictionPosition()` —— 刻意用真实位置。
--   5754-5755 行的注释解释：
--     "Physics:Stop() fixed to stop at last sim position; no need to correct
--      local position anymore / self.inst.Transform:SetPosition(x, 0, z)
--      --V2C: correcting local position, no need to account for platform"
--   → 翻译：引擎的 Physics:Stop() 已改为停在「最后模拟位置」，
--     所以客户端不再需要自己修正 Transform 位置。
--     而被注释掉的那行修正**没有考虑平台**（若在船上会错）。
--   ⇒★★ 这又是一条 V2C 补丁记录（42 处 V2C 中的一处），
--     说明「客户端位置修正」这件事被引擎层接管过一次。
			local x, y, z = self.inst.Transform:GetWorldPosition() --V2C: not GetPredictionPosition()
			--V2C: Physics:Stop() fixed to stop at last sim position; no need to correct local position anymore
			--self.inst.Transform:SetPosition(x, 0, z) --V2C: correcting local position, no need to account for platform
			self:RemotePredictWalking(x, z, self.locomotor:GetTimeMoving() == 0, self.locomotor:PopOverrideTimeMoving(), self.client_last_predict_walk.direct)
			self.client_last_predict_walk.tick = nil
		end
		buffaction.preview_cb()
	else
		self.client_last_predict_walk.tick = nil
	end
end

--★★★ 【OnRemoteBufferedAction】★★ 服务端侧的「动作前位置对齐」。
--   ⚠ 与所有其他 OnRemote* 不同，本函数**没有** ismastersim/IsEnabled/handler 三重守卫，
--     只有 5766 行的 `if self.ismastersim then`。
--   ⚠ 且它**不是 RPC**（grep 确认 networkclientrpc.lua 中无对应项）。
--     它由 1671 行 TryAOECharging 调用（且只在 force_rotation 时）。
--   ⇒★ 双重身份：
--     ① 蓄力开始时的对齐（1671 行）
--     ② 也被 locomotor 在「远端缓冲动作开始」时调用（见 5750 行的对端注释）
function PlayerController:OnRemoteBufferedAction()
    if self.ismastersim then
--   --If we're starting a remote buffered action, prevent the last movement
--   prediction vector from cancelling us out right away
--   ★★ 5770 行注释解释了本函数的核心意图：**别让移动把动作顶掉**。
        --If we're starting a remote buffered action, prevent the last
        --movement prediction vector from cancelling us out right away
		local pt = self:GetRemotePredictPosition()
		if pt then
--★ 5771 行 `pt.y < 5 and not self:IsBusy()`：
--   ★★ 排除 y>=5（正在执行动作）与 y==6（跳跃）。
--     5772 行注释 "excludes self:IsLocalOrRemoteHopping() as well, ie. y ~= 6" ——
--     明确指出 y=6 也被这条判断排除（因为 6 > 5）。
--   ⚠ 这再次印证 B8：连「判断是否跳跃」都要靠 y 的**大小关系**，
--     而不是独立的布尔字段。
			if pt.y < 5 and not self:IsBusy() then
				--excludes self:IsLocalOrRemoteHopping() as well, ie. y ~= 6
--   5773 行：取服务器当前世界位置（忽略 y）。
				local x, _, z = self.inst.Transform:GetWorldPosition()
				local dx = pt.x - x
				local dz = pt.z - z
--   5776 行 `if dx ~= 0 or dz ~= 0`：完全重合则什么都不做（省开销）。
				if dx ~= 0 or dz ~= 0 then
--★★★ 【5777-5785：should_snap 的两级条件】★ remote_authority 的特权。
--   ★ 5778-5779 行：remote_authority → **无条件**瞬移。
--     ★ 不做任何距离/合法性检查。这是「信任」的极致体现（也见文件头警告）。
--   ★ 5781-5784 行：非信任玩家 → 两重限制：
--     ① 距离 ≤ min(单帧跑距, PREDICT_STOP_ERROR_DISTANCE_SQ)
--        ★ `GetRunSpeed() * FRAMES` = 一帧能跑多远。
--          即「只允许在**一帧之内**的距离差内对齐」。
--          ⇒ 语义：这不是「拉玩家过去」，而是「消除亚帧级误差」。
--     ② 目标点可通行（IsPassableAtPoint）—— 不许把玩家推进墙里。
--   ⇒★★ 对比 4039-4043 行（过冲瞬移）：那里**没有**这两重限制。
--     同为 remote_authority 特权，一处宽松一处严格，不一致。
--   ⚠ 推理依据：4039 行只有 remote_authority + 方向差 >= 90；
--     5777 行有 should_snap 变量与额外两项检查。
					local should_snap
					if self.remote_authority then
						should_snap = true
					else
						local max_dist = self.locomotor:GetRunSpeed() * FRAMES
						should_snap =
							dx * dx + dz * dz <= math.min(max_dist * max_dist, PREDICT_STOP_ERROR_DISTANCE_SQ) and
							self.map:IsPassableAtPoint(pt:Get())
					end

--★ 5787-5798：snap 的三步（转向 → 强制进 idle → 停止 → SetPosition）。
--   5789 行的 canrotate 检查：不能转朝向时跳过第一步。
--   5793 行的 `sg:HandleEvent("locomote", {dir=dir, force_idle_state=true})`：
--     ★ force_idle_state 与 4049 行的注释同款 ——
--       「这次微小移动可能是为了取消某个动作，所以必须进 idle」。
--   5796 行 locomotor:Stop() 在 SetPosition **之前** ——
--     顺序重要：先停（停止路径计算），再挪位置（否则路径会重新计算）。
					if should_snap then
						local dir = math.atan2(-dz, dx) * RADIANS
						if self.inst.sg:HasStateTag("canrotate") then
							self.locomotor:SetMoveDir(dir)
						end
						--Force us to interrupt and go to movement state immediately
						self.inst.sg:HandleEvent("locomote", { dir = dir, force_idle_state = true }) --force idle state in case this tiny motion was meant to cancel an action
						--FIXME(JBK): Boat handling.
						--FIXED(V2C): Remote predict position now resolves platform relative positions from client.
						self.locomotor:Stop()
						self.inst.Transform:SetPosition(pt.x, 0, pt.z)
					end
				end
			end
--★★★ 5801 行 `self.remote_vector.y = 5` —— **B8 编码表的最后一个成员**。
--   ★ 语义：「客户端要开始执行动作，预测目标冻结在此处」。
--   ★★ 它的三个消费者：
--     4014 行 `if pt.y == 5 and (...)` → 清移动标志，开始执行动作
--     4030 行 `if pt.y < 5 then ClearBufferedAction()` → 5 号**不清**动作
--     5771 行 `pt.y < 5` → 5 号**不做**位置对齐（避免动作前又挪一下）
--   ⇒★★ 完整语义链：「y=5 是一个**事务开始标记**」——
--     移动到动作的交接点，所有「清理移动」与「清理动作」的逻辑都绕开它。
--   ⚠ 但 3809-3816 行的 isstop 分支处理不了 y=5（因为 3789 行只会写 3/4）。
--     5801 行是**唯一**写 5 的地方，也从不把它重置为 0 ——
--     重置靠 3800-3817 行（客户端发 isstop）或 3698 行（ResetRemoteController）。
--     ⚠ 若客户端在 y=5 状态下断线，服务器的 remote_vector.y 永远停在 5。
--     ⇒ 后果：DoPredictWalking:4008 的 pt 恒非 nil → 服务器永远执行预测逻辑。
--     缓解：4014 行进入该分支后会清三个移动标志并 return，行为退化到「静止」。
            self.remote_vector.y = 5
--   5802-5806 行：没有预测位置（pt 为 nil）且 y 已是 0 → 清手势标志。
--   ★ 这是「干净退出」的收尾。
        elseif self.remote_vector.y == 0 then
            self.directwalking = false
            self.dragwalking = false
            self.predictwalking = false
        end
    end
end

--★★ CREATURE_INTERACTIONS：★ 「玩家正在对生物做什么」的广播清单。
--   注释："This is just for friendly interactions where some brains may have
--   logic to stop and wait for you."
--   → 翻译：仅用于「友好交互」—— 某些 AI 会在玩家靠近时停下等待。
--   ★★ 全部 9 个动作都要求 target 带 locomotor 标签（5885 行）——
--     「能被喂食的生物」必须能走动（不能是墙上的画像）。
--   ⇒ 消费方：eater:363 / trader:58 / mermbrain:49 / container_transform:22 ...
--   ⚠ WEATHER 类的 GIVE/GIVEALLTOPLAYER 不在清单里 —— 那些是「给予」不是「交互」。
--This is just for friendly interactions where some brains may have logic to stop and wait for you.
local CREATURE_INTERACTIONS =
{
	[ACTIONS.GIVE] = true,
	[ACTIONS.FEED] = true,
	[ACTIONS.HEAL] = true,
	[ACTIONS.STORE] = true,
	[ACTIONS.RUMMAGE] = true,
	[ACTIONS.MOUNT] = true,
	[ACTIONS.PICKUP] = true,
	[ACTIONS.USEITEMON] = true,

	--Webber
	[ACTIONS.MUTATE_SPIDER] = true,
}

--★ WX78_INTERACTIONS：温蒂附身身体需要跟随主人的动作。
--   ★ 包含 ATTACK / CHOP / MINE / DIG / TILL / FEEDPLAYER ...
--   注释 "Special logic for WX so possessed bodies can follow in sync" ——
--   ⇒ 机制：温蒂附身后，她的「身体」AI 读取自己实体的 remoteinteraction，
--     从而跟着主人做同样的事（同步攻击/同步建造）。
--   ⚠ 守卫条件是 `self.inst.wx78_classified ~= nil`（5886 行）——
--     即「我是一个被别人附着的身体」，而非「我是温蒂」。方向相反，容易搞混。
-- Special logic for WX so possessed bodies can follow in sync.
local WX78_INTERACTIONS =
{
    [ACTIONS.ATTACK] = true,
    [ACTIONS.CHOP] = true,
    [ACTIONS.MINE] = true,
    [ACTIONS.DIG] = true,
    [ACTIONS.TILL] = true,
    [ACTIONS.FEEDPLAYER] = true,
    [ACTIONS.RUMMAGE] = true,
    [ACTIONS.RAISE_ANCHOR] = true,
    [ACTIONS.LOWER_SAIL_FAIL] = true,
    [ACTIONS.LOWER_SAIL_BOOST] = true,
    [ACTIONS.ROW] = true,
    [ACTIONS.ROW_FAIL] = true,
    [ACTIONS.ROW_CONTROLLER] = true,
}
--★ WX78_INTERACTION_POSITIONS：需要**位置**的三个划船动作。
--   ★ 为什么只有这三个：ROW / ROW_FAIL / ROW_CONTROLLER ——
--     划船需要「在哪条船上划」的位置信息，其余动作只需 target 即可。
local WX78_INTERACTION_POSITIONS = -- These ones we need the positions too
{
    [ACTIONS.ROW] = true,
    [ACTIONS.ROW_FAIL] = true,
    [ACTIONS.ROW_CONTROLLER] = true,
}

--   --InteractionTarget naming scheme from when this was initially just used
--   for action + target only
--   ★★ 一条历史注记：这套协议最初只有「动作+目标」两个字段，
--     后来加了 position（第三个参数），且**追加在末尾**（5862 行）。
--   ⇒ 与 1932 行的 isreleased 注释同款约定：**只能在末尾追加参数**。
-- InteractionTarget naming scheme from when this was initially just used for action + target only
--★ 【OnRemoteInteractionTarget】服务端接收 AI 交互意图。
--   ⚠⚠ 疑似缺陷（缺少有效性校验）：本函数**没有任何守卫**
--     （无 ismastersim / IsEnabled / handler == nil），--     且直接 ACTIONS_BY_ACTION_CODE[actioncode] 查表。
--   ⇒ RPC 层（networkclientrpc.lua:1273-1294）只校验参数类型与
--     IsPointInRange（64 格），**不校验 action 是否合法**。
--   后果：客户端可上报任意 actioncode（服务端查表失败得 nil，
--     则 remoteinteractionaction = nil，等于「清空交互意图」）。
--   ⚠ 这**不会**让玩家做动作（GetRemoteInteraction 只是给 AI 读的只读接口），
--     所以攻击面有限：最多让 NPC 误以为玩家在喂它/骑它。
--   推理依据：5851-5855 行的函数体只有三行赋值，无任何条件判断；
--     对比 5857 行客户端版有 `if 三者都变了才发` 的去重。
function PlayerController:OnRemoteInteractionTarget(actioncode, target, position)
	self.remoteinteractionaction = ACTIONS_BY_ACTION_CODE[actioncode]
	self.remoteinteractiontarget = target
    self.remoteinteractionpos = position
end

--★ RemoteInteractionTarget：客户端发送端（三元组变化才发）。
--   ★ 5862 行 `position ~= nil and position.x or nil`：
--     Vector3 无法直接网络传输（不是引擎支持的类型），故拆成 x/z 两个字数。
--     ★ 这也解释了 5859 行本地存的是完整 Vector3（本地不需要序列化）。
function PlayerController:RemoteInteractionTarget(actioncode, target, position)
    if self.remoteinteractionaction ~= actioncode or self.remoteinteractiontarget ~= target or self.remoteinteractionpos ~= position then
		self.remoteinteractionaction = actioncode
		self.remoteinteractiontarget = target
        self.remoteinteractionpos = position
		SendRPCToServer(RPC.InteractionTarget, actioncode, target, position ~= nil and position.x or nil, position ~= nil and position.z or nil)
	end
end

--★ GetRemoteInteraction：★ 13 处外部调用（全部是 brain）。
--   ⇒ 「AI 读取玩家意图」的唯一接口。
--   ⚠ 三元返回，调用方都写成 `act, target = GetRemoteInteraction()`
--     （只取前两个），WX78 的 5887 行才用第三个（position）。
function PlayerController:GetRemoteInteraction()
	return self.remoteinteractionaction, self.remoteinteractiontarget, self.remoteinteractionpos
end

--★★★ 【OnLocomotorBufferedAction(act)】★ 被 locomotor.lua:1087 调用。
--   ★ 这是「动作被缓冲进 locomotor」时的回调，双端都跑。
--   两个职责：
--     ① 更新 recent_bufferedaction（★ 松手护栏的数据源）
--     ② 广播 remoteinteractionaction（★ AI 意图）
function PlayerController:OnLocomotorBufferedAction(act)
	local dir
	if self.handler == nil then
		dir = self:GetRemoteDirectVector()

--   ★★ 5875-5877 行：`self.handler == nil`（远端玩家）时**清空**交互意图。
--     注释 "Clear any remote interactions if server takes over" ——
--     ⇒ 语义：一旦服务器接管（玩家不再由客户端预测驱动），
--       客户端上报的交互意图就失效了。
--   ⚠ 但 5876-5877 行只清 action 与 target，**不清 pos**（5857 行的第三个字段）。
--   ⚠ 疑似缺陷（清理不完整）：remoteinteractionpos 残留。
--     推理依据：5876/5877 行分别清 remoteinteractionaction 与
--       remoteinteractiontarget，没有 remoteinteractionpos。
--       而 5868 行的 GetRemoteInteraction 会返回残留的 pos。
--     影响：WX78 的划船逻辑（5891 行）可能读到过期位置。
		--Clear any remote interactions if server takes over
		self.remoteinteractionaction = nil
		self.remoteinteractiontarget = nil
	else
		dir = GetWorldControllerVector()

        local actioncode, target, position
        if not self.ismastersim then
            if (act.target and act.target:IsValid() and
            (
                (CREATURE_INTERACTIONS[act.action] and act.target:HasTag("locomotor")) or
                (WX78_INTERACTIONS[act.action] and self.inst.wx78_classified ~= nil)
            )) or (self.inst.wx78_classified ~= nil and WX78_INTERACTION_POSITIONS[act.action] and act:GetActionPoint())
            then
                actioncode = act.action.code
			    target = act.target
                if self.inst.wx78_classified ~= nil and WX78_INTERACTION_POSITIONS[act.action] then
                    position = act:GetActionPoint()
                end
--   ★★ 5894-5895 行：动作的成功/失败回调都清意图。
--     回调是 _clearinteractiontarget（166-171 行定义的闭包）。
--     ⇒ 语义：「做了这个交互」或「交互失败」都让 AI 重新评估。
--   ⚠ 注意只有「友好交互」才挂回调（5885 行的标签判据）。
			    act:AddSuccessAction(self._clearinteractiontarget)
			    act:AddFailAction(self._clearinteractiontarget)
            end
        end

		self:RemoteInteractionTarget(actioncode, target, position)
	end
--★ 5901-5906 行：更新松手护栏的四元组。
--   5903 行 `act.action == ACTIONS.CASTAOE and BUFFERED_CASTAOE_TIME or
--   BUFFERED_ACTION_NO_CANCEL_TIME` ——
--     ★★ 唯一的分岔：施法给 0.5 秒宽限，普通动作只给 1 帧。
--     理由见 5 行注释（施法有前摇，摇杆会持续偏向）。
--   ⚠ 5901 行的守卫 `if dir ~= nil`：★ 摇杆无输入时不记录护栏。
--     ⇒ 只有「玩家正推着摇杆点动作」才会触发护栏。
--     这解释了为什么护栏不会影响鼠标玩家的动作。
	if dir ~= nil then
		self.recent_bufferedaction.act = act
		self.recent_bufferedaction.t = act.action == ACTIONS.CASTAOE and BUFFERED_CASTAOE_TIME or BUFFERED_ACTION_NO_CANCEL_TIME
		self.recent_bufferedaction.x = dir.x
		self.recent_bufferedaction.z = dir.z
	end
end

--★ 【OnNewState】状态切换 → 强制 currentstate 变脏。
--   --V2C: -Don't use data.statename /
--   --     -"newstate" events are fired off in reverse order when chaining
--   --      GoToState calls in the state's onenter
--   ==> ★★ 「newstate 事件在状态图链式 GoToState 时会**逆序**触发」——
--     若用 data.statename（事件携带的名字）会拿到错误的状态。
--     正确做法是**直接读 sg.currentstate.name**。
local function OnNewState(inst)--, data)
	--V2C: -Don't use data.statename
	--     -"newstate" events are fired off in reverse order when chaining GoToState calls in the state's onenter
	--
--   --#V2C #client_prediction / --force dirty
--   --see SGWilson_client -> ClearCachedServerState
--   ★★ 5916 行 `currentstate:set_local(0)` —— ★★ **这就是「force dirty」**。
--     net 变量有一个「脏标记」机制：值没变就不发网络包。
--     先本地置 0（与目标值必然不同）→ 标记为脏 → 再 set 真实值 → 必定发包。
--   ⇒ 这是引擎网络层的一个经典 trick，用于「值没变但必须通知」的场合。
--   ⚠ 性能代价：每次状态切换都强制发一个包（即使状态名相同）。
--     对状态切换频繁的实体有额外带宽开销。
	--#V2C #client_prediction
	--force dirty
	--see SGWilson_client -> ClearCachedServerState
	inst.player_classified.currentstate:set_local(0)
	inst.player_classified.currentstate:set(inst.sg ~= nil and inst.sg.currentstate.name or 0)
end

--★★★ 【OnRemoteToggleMovementPrediction(val)】★ 客户端预测的**总开关**。
--   ★ 它的 RPC 对端是 networkclientrpc.lua:954 SetMovementPredictionEnabled，
--     ★★ 由**客户端发起**（一个 RPC 参数只有 bool，却能关闭服务器的预测能力）。
--   ⚠ 疑似缺陷（鉴权缺失）：RPC handler（954-962 行）只 checkbool(enabled)，
--     ★★ **不检查调用者是不是这个玩家本人**，也不检查 enabled 的取值是否合法。
--     推理依据：954 行 `SetMovementPredictionEnabled = function(player, enabled)`；
--       959 行 `if not (checkbool(enabled)) then printinvalid(...); return end`；
--       961 行直接调用。→ player 参数只用于取组件，不做归属校验。
--     ⇒ 后果：任何客户端都能让**服务器**关闭（或开启）自己的移动预测。
--       关闭后自己就不再被预测跟随（= 自己说了算），这是可利用的。
--       开启则相反（自己被预测拉走）。
--     对比：PredictWalking（425 行）有 IsPointInRange + remote_predicting 检查；
--       LeftClick（61 行）有 checknumber/checkbool 系列校验。
--     ⇒ 这条 RPC 的校验强度**明显低于同文件其他 RPC**，是最可疑的一处。
--   ★★ 但它同时也是理解整个预测系统的**架构骨架**，值得逐行读：
function PlayerController:OnRemoteToggleMovementPrediction(val)
	if self.ismastersim then
		local dirty = self.remote_predicting ~= val
		self.remote_predicting = val
--★ 5924-5926 行的三步「关闭现有预测」：
--   ① locomotor:Stop() —— 立即停止移动
--   ② locomotor:Clear() —— 清掉所有意图（dest + bufferedaction）
--   ③ SetAllowPlatformHopping(not val) —— ★★ 关闭预测时**禁止平台跳跃**。
--   ★ ③ 的理由：跳跃需要客户端与服务器同步（3835 行的 OnRemoteStartHop），
--     没有预测就没有「客户端先行跳跃」的能力，故必须禁。
		self.locomotor:Stop()
		self.locomotor:Clear()
		self.locomotor:SetAllowPlatformHopping(not val)
--   ResetRemoteController：彻底清空远端镜像（同 3697 行）。
		self:ResetRemoteController()
--★ 5928 行 `if dirty then`：只有开关**真正变化**时才做后续的监听管理。
--   ⚠ 但 5924-5926 行的 Stop/Clear/SetAllowPlatformHopping 在 if 之外 ——
--     即「每次调用都会强制停止移动」，哪怕值没变。
--   ⚠ 疑似缺陷（过度清理）：重复调用 ToggleMovementPrediction(true)
--     会不断打断玩家当前移动。
--     推理依据：5922 行算出 dirty 但 5924-5926 无条件执行；
--       5930-5934 行的监听管理才在 if dirty 内。
--     若调用方每次状态切换都调一次（如某些角色技能），会造成频繁打断。
		if dirty then
--★ 5929-5931 行：开启预测 → 开始监听 newstate，同步状态名给客户端。
--   ★ 5931 行 `currentstate:set(真实值)` —— 因为 5916 行的 set_local(0) 已置脏，
--     所以这里必定发包。
--   ⇒★★ 预测开启的**必要条件**是「客户端知道我在哪个状态」，
--     因为预测的合法性判断（CanLocomote:763）依赖 sg 状态标签。
			if val then
				self.inst:ListenForEvent("newstate", OnNewState)
				self.classified.currentstate:set(self.inst.sg.currentstate and self.inst.sg.currentstate.name or 0)
--★ 关闭预测 → 停止监听，currentstate:set(0)。
--   ★ set(0) 而非 set_local(0) —— 这是**发给客户端**的终止信号，
--     客户端据此知道「服务端不再预测，位置以服务器为准」。
			else
				self.inst:RemoveEventCallback("newstate", OnNewState)
				self.classified.currentstate:set(0)
			end
		end
	end
end

--★★ 返回类对象本身 —— DST 组件的标准导出形式。
return PlayerController
