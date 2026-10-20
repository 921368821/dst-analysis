// spec-playercontroller-p1.mjs —— 第 1 段：1-620 行
// 覆盖：常量表、局部工具函数、Class 构造器、事件回调、Activate/Deactivate、
//       地图、IsEnabled、remote_controls、修饰键位掩码、CanLocomote/IsBusy、OnControl 上半

export const HEADER_EXTRA = [];

export const BEFORE = {
  1: [
    "--============================================================",
    "-- 【第一段】1-620 行：常量 / 工具函数 / 生命周期 / 输入总入口 OnControl",
    "--============================================================",
  ],

  2: [
    "--【BUTTON_REPEAT_COOLDOWN = .5】按住攻击键的最小重发间隔（秒）。",
    "--   这个值是 remote_controls 的**倒计时初值**（1362/1368/1965/2355 行都会用它）。",
    "--   为什么要半秒：手柄扳机按下会自动连发，若不加冷却，一个长按会在几百毫秒内",
    "--   灌进几十个 ATTACK RPC，直接把服务端的 attack_buffer 打爆。",
    "--   参见 2607 行的 ACTION_REPEAT_COOLDOWN=0.2（长按重复走动作的间隔，更短）。",
  ],

  3: [
    "--【ACTION_REPEAT_COOLDOWN = 0.2】长按重复执行「上一次动作」的重入冷却。",
    "--   比 BUTTON_REPEAT_COOLDOWN 短，因为长按重复的是**同一个**动作（挖掘/砍树），",
    "--   语义上等价于玩家的连续操作，不需要防刷。",
    "--   ★ 注意 2609 行在重发前会写 lastheldaction.options.no_predict_fastforward = true，",
    "--   这是为了避免重复动作触发客户端动画快进（吃本地资源却不同步）。",
  ],

  4: [
    "--【INVENTORY_ACTIONHOLD_REPEAT_COOLDOWN = 0.8】手柄在库存格上长按的重复间隔。",
    "--   比 0.2 长 4 倍：库存格动作（吃/装备/丢弃）的动画节奏由角色 prefab 决定，",
    "--   转太快会出现「嘴还在嚼就已经吞下 4 个」的视觉穿帮。",
  ],

  5: [
    "--【BUFFERED_CASTAOE_TIME = .5】法杖/法术书 AOE 施法后，方向键仍不打断该动作的宽限期。",
    "--   写在 5903 行 recent_bufferedaction.t 里。施法有前摇，摇杆会持续偏向玩家按下的方向，",
    "--   若不放宽限，DoDirectWalking 会在 4518 行把施法打断。",
  ],

  6: [
    "--【BUFFERED_ACTION_NO_CANCEL_TIME = FRAMES + .0001】普通动作的**最小不可取消窗口**。",
    "--   FRAMES 即 1/30 秒（见 constants.lua）。加 .0001 是浮点保护：",
    "--   若某帧 dt 恰好等于 FRAMES，`self.recent_bufferedaction.t > dt` 会因精度失败。",
    "--   ⇒ 这个字段（recent_bufferedaction.t）是 DoDirectWalking:4322 判定的依据：",
    "--     「方向键是**先于**动作按下才松开的」→ 不取消动作。",
    "--   ★ 这是玩家手感的关键：一个 33ms 的窗口刚好跨过「按住方向 + 点鼠标」的常见时序。",
  ],

  7: [
    "--【CONTROLLER_TARGETING_LOCK_TIME = 1.0】手柄目标锁定的持续时长（秒）。",
    "--   ⚠ 疑似缺陷（死常量）：grep 全文只有这一处赋值，128-131 行的目标锁定实现",
    "--   全部改成了「玩家手动 Toggle + 列表循环」模式（CONTROL_TARGET_LOCK，711 行），",
    "--   不再依赖任何定时器。因此此常量已失效但未删除。",
    "--   推理依据：grep -n CONTROLLER_TARGETING_LOCK_TIME 只命中第 7 行。",
  ],

  8: [
    "--【★ RUBBER_BAND_PING_TOLERANCE_IN_SECONDS = 0.7】橡皮筋的距离预算时间。",
    "--   只在 3870 行用一次：站在**移动的船上**跳向对岸时，允许的额外跳距 =",
    "--     0.7 秒 × 船速 × (跳跃方向·船移动方向的余弦)。",
    "--   为什么需要：船在动，玩家点对岸，客户端算出的落点基于「船静止」的世界坐标，",
    "--   但服务端执行时船已经往前走了；若不补偿，合法跳会被判为「跳太远」而丢弃。",
    "--   ⇒ 理解方式：这是把**一整个 RTT 的船位移**折算成距离预算。",
  ],

  9: [
    "--【★ RUBBER_BAND_DISTANCE = 4】预测误差容忍上限（单位）。",
    "--   在两处使用，语义不同：",
    "--     · 4082 行：服务器每帧比较「服务器当前位置」与「客户端预测目标点」，",
    "--       平方距离 > 16 就放弃预测，让服务器权威位置胜出。",
    "--     · 3876 行：作为跳跃距离的基线预算（+平台速度补偿 + 跳跃距离）。",
    "--   为什么是 4：DST 单帧跑 30 帧，一帧位移约 0.15；4 单位 ≈ 26 帧 ≈ 0.9 秒的滞后。",
    "--   ⇒ 换算：普通宽带 RTT 100ms 完全在预算内；跨洲 300ms 才会频繁触发。",
  ],

  10: [
    "--【预计算平方】避免每帧重复乘法。4082 行用 RUBBER_BAND_DISTANCE_SQ 而不是",
    "--   距离本身，因为比较平方距离不需要开根号。",
  ],

  11: [
    "--【PREDICT_STOP_ERROR_DISTANCE_SQ = 0.25】预测停止时的位置微调容差（平方）。",
    "--   两处使用：",
    "--     · 4098 行：客户端停下后，服务器若已在 0.5 单位内就把玩家吸到停止点。",
    "--     · 5783 行：非 remote_authority 玩家在执行动作前，允许的对齐距离上限。",
    "--   ⇒ 0.25 平方 = 0.5 单位 = 约 1/3 个身位，属于「看不出来的误差」。",
    "--   ★ 对比 4012 行的 stopdistancesq（0.05/0.0001）—— 那里是**每帧**的收敛阈值，",
    "--     比这里严格 5 倍，因为它是持续收敛判据而不是一次性微调。",
  ],

  "OnPlayerActivated#1": [
    "--【OnPlayerActivated】事件回调 → 转发给 Activate。",
    "--   事件名带 player 前缀，说明这是 prefab 侧主动 PushEvent 进来的。",
  ],

  "OnPlayerDeactivated#1": [
    "--【OnPlayerDeactivated】对称的停用回调。见 313-346 行的 Activate 实现。",
  ],

  "GetWorldControllerVector#1": [
    "--★★ 【GetWorldControllerVector】手柄左摇杆 → 世界空间方向向量。**核心输入函数**。",
    "--   它做两件事：",
    "--   ①【屏幕空间 → 世界空间】摇杆给出的是「屏幕右 / 屏幕下」，",
    "--      乘以相机的右向量与下向量后得到世界方向。取负号是因为「按下」= -Y 方向。",
    "--   ★ 为什么不能直接用摇杆的 x/y：相机可以任意旋转/缩放（俯视角可 45°），",
    "--     摇杆的「上」在屏幕上始终向上，但世界里的「前」会随镜头变。",
    "--   ②【死区】24 行 deadzone 用的是 TUNING.CONTROLLER_DEADZONE_RADIUS。",
    "--     ⚠ 注意判据是 `abs(x)>=deadzone or abs(y>=deadzone)` —— **或**，不是「与」。",
    "--       这意味着斜向轻推（x=0.1,y=0.1，死区 0.2）已经不满足 or 的两个条件，",
    "--       但斜向轻推（x=0.25,y=0.25）满足，会被当成有效输入并**归一化**成满速。",
    "--     ⇒ 后果：玩家轻轻斜推就得到最大速度，而直推需要推过死区才启动。",
    "--       这是「手柄斜向灵敏」的根因，不是 bug 而是手感取舍。",
    "--   ③【归一化】27 行 GetNormalized() 让斜推也得到单位向量，",
    "--     ⇒ 速度大小由 locomotor 的 runspeed 决定，不由摇杆幅度决定。",
    "--     ★ 所以 DST 手柄没有「模拟量移动」，只有「方向 + 固定速度」。",
    "--   返回 nil 表示「没推」，调用方（DoDirectWalking:4317、DoBoatSteering:4167、",
    "--   DoDoubleTapDir:4235、DoClientBusyOverrideLocomote:3977）据此判断停止。",
  ],

  "GetWorldControllerVector#1+3": [
    "--   ⚠ 这里的缩进是 Tab（与周围 4 空格不一致），说明是后期插入的补丁行。",
  ],

  "HasItemSlots#1": [
    "--【HasItemSlots】是否拥有背包格子。**猴补（monkey patch）模式的第一段**。",
    "--   ★ 设计意图：GetPickupAction:2036 要判断「玩家能不能捡东西」，",
    "--     而这个值来自 replica.inventory。副本在客户端可能还没同步好。",
    "--     做法是先把 self.HasItemSlots 指向 CacheHasItemSlots（35 行），",
    "--     第一次调用时算出真值，然后**把 self.HasItemSlots 换成普通函数 HasItemSlots**，",
    "--     之后每次调用都是一次字段读取。",
    "--   ⇒ 这是一个「首次访问付代价、之后零成本」的一次性初始化惯用法。",
  ],

  "CacheHasItemSlots#1": [
    "--【CacheHasItemSlots】惰性求值 + 自我替换。",
    "--   36 行 `self.HasItemSlots = HasItemSlots` 就是「替换掉我自己」——",
    "--   之后 self.HasItemSlots 直接指向 31 行的纯读取版本。",
    "--   ★ 注意 37 行用了 replica.inventory（副本组件）而非 components.inventory：",
    "--     这个判断必须在**双端**都能算出相同答案，否则客户端能捡服务端不能捡。",
  ],

  "OnEquipChanged#1": [
    "--【OnEquipChanged】装备变化 → 维护「草帽建造网格」的放置器。",
    "--   41-55 行的 `(self.gridplacer ~= nil) == not ...:EquipHasTag(\"turfhat\")`",
    "--   是一个刻意写得**难以读**的等价布尔：",
    "--     「有放置器」 应等价于 「没戴草帽」。写成两者的 == 让意图对称，",
    "--     但代价是必须倒读。",
  ],

  "OnEquipChanged#1+1": [
    "--   ★★ 只有 `inst == ThePlayer` 才处理：gridplacer 是**纯本地表现**，",
    "--     其他玩家的草帽网格不该被创建（会浪费一份放置器实体）。",
  ],

  "OnEquipChanged#1+3": [
    "--   -- EquipHasTag(\"turfhat\")：戴草帽时网格**关闭**（草帽自带一个格子覆盖它）。",
    "--   -- 参见 prefabs 里的 turfhat，它是一个 EQUIPSLOTS.HEAD 的覆盖装备。",
  ],

  "OnEquipChanged#1+9": [
    "--   50 行注意第三个参数传了 self.inst.userid —— SpawnPrefab 的第 3/4 参数是",
    "--     networked（是否联网）+ owner。放置器与玩家绑定，避免别人删掉你的草帽网格。",
  ],

  "OnInit#1": [
    "--【OnInit】延迟一帧执行的初始化（180 行 DoTaskInTime(0, ...) 的回调）。",
    "--   ★ 为什么延迟一帧：构造函数运行时 replica 组件可能还没挂上（尤其客户端接收",
    "--     玩家实体的瞬间），强行访问会 nil 索引崩溃。",
  ],

  "OnInit#1+3": [
    "--   --V2C：以下三个分支是**纯客户端**逻辑。英文原注释保留了 K 自己的解释：",
    "--   -- \"Client only event, because when inventory is closed, we will stop",
    "--   --  getting \"equip\" and \"unequip\" events, but we can also assume that",
    "--   --  our inventory is emptied.\"",
    "--   → 翻译：库存界面关闭后客户端会**停止收到** equip/unequip 事件，",
    "--     但此时背包必然已清空，所以要**手动补一次** OnEquipChanged 来拆掉草帽网格。",
    "--   ⇒ 这是一个「客户端的事件系统不对称，用轮询补偿」的典型。",
  ],

  "OnInit#1+8": [
    "--   ⚠ 65-68 行：副本还没到就直接 return，**OnEquipChanged(inst) 不会被调用**。",
    "--     这意味着新生成的客户端玩家，前几帧可能既没有 gridplacer 也没有正确清理。",
    "--     推理依据：--V2C: clients c_spawning characters ...grrrr 这句注释本身就",
    "--     承认这是一个已知的、让他们「有点抓狂」的状态。",
  ],

  "OnInit#1+16": [
    "--★★ 【PlayerController 构造器】Class(function(self, inst) ...)",
    "--   双端各有一个实例。本段（74-155）几乎全是**字段初始化**，但每个字段都是",
    "--   一条协议的一半，务必对照文件头「四个字段族」来读。",
  ],

  "OnInit#1+19": [
    "--   --cache variables：以下三项被**高频**读取（每帧甚至每按钮），",
    "--     缓存为局部字段避免多次 metatable 查找。",
  ],

  "OnInit#1+21": [
    "--   ★ ismastersim 是**整个文件最关键的分流标志**，出现 60+ 次。",
    "--     它决定了：谁读 TheInput、谁能发 RPC、谁驱动 locomotor、谁能改组件。",
  ],

  "OnInit#1+22": [
    "--   ★ locomotor 在构造时就缓存（而不是每次 self.inst.components.locomotor）。",
    "--     注意它**可能为 nil**：无 locomotor 的实体（如某些召唤物）也能挂本组件，",
    "--     整个文件因此有 40+ 处 `self.locomotor == nil` 判定。",
    "--     ⇒ 这个 nil 不是异常，是「非行走单位也复用本组件」的设计结果。",
  ],

  "OnInit#1+26": [
    "--   attack_buffer：攻击请求的**延迟缓冲**。不是普通队列，是「存一个，待会儿执行」。",
    "--     ★ 存进去的可能不是 BufferedAction 而是 CONTROL_ATTACK 这样的**枚举常量**",
    "--       （636/673 行），OnUpdate:2777 会分派。这就是「按键也要走缓冲」的证据。",
  ],

  "OnInit#1+30": [
    "--★★ remote_vector：远端玩家的「移动意图信封」。★ 参见 3694 行顶部注释。",
    "--   Vector3 的三个分量在本文件里被重载：",
    "--     x / z —— 含义取决于 y（方向向量 or 目标坐标，见文件头表格）",
    "--     y     —— 移动模式标签（0/1/2/3/4/5/6），★ 同时在 y>=3 时充当真实高度",
    "--   ★★★ platform —— 关键！这是**后加的第四个字段**（Vector3 上挂的额外属性）。",
    "--     它表示 x/z 是「该平台的局部坐标」而非世界坐标。3791/3925 行设置。",
    "--     ⚠ 这就是 bug-patterns B8 说的「platform 参数是后期补上的，代码里到处是补丁」。",
  ],

  "OnInit#1+31": [
    "--   remote_predict_dir：服务器当前正在追的预测方向（弧度）。",
    "--     4039 行用它做「过冲检测」：新方向与旧方向差 ≥90° ⇒ 玩家改主意了 ⇒ 直接瞬移。",
  ],

  "OnInit#1+32": [
    "--   --used when server detected no more movement (NOTE: could be client running up against obstacle)",
    "--   → K 自己的注释就点明了歧义：服务器看到「不走了」有两种可能：",
    "--     (a) 玩家真的停了； (b) 客户端预测撞墙停住了，但服务器这边墙还没生效。",
    "--   ⇒ 4095-4105 行的处理是**折中**：下一帧若服务器已在停止点附近就吸附过去，否则放弃。",
  ],

  "OnInit#1+33": [
    "--   remote_predict_stop_notified：客户端**明确告知**「我停了」的标志。",
    "--     ★ 与 _stop_tick 的区别：_stop_tick 是「服务器自己发现的」，",
    "--       _notified 是「客户端说出来的」。3794/3812 行赋值。",
    "--     二者的配合解决的是「客户端停 → 服务端还在跑」这个经典预测失配。",
  ],

  "OnInit#1+34": [
    "--   client_last_predict_walk = { tick, direct }：客户端最后一次发预测的位置与时刻。",
    "--     ★ 与已废弃的 self.predictionsent（106 行）并存 —— 见 106 行注释。",
  ],

  "OnInit#1+36": [
    "--   remote_predicting：**服务端**是否开启客户端预测。",
    "--     ★ 只有它为 true，networkclientrpc.lua:455 才会放行 PredictWalking RPC。",
    "--       它由 PlayerController:OnRemoteToggleMovementPrediction（5920 行）设置，",
    "--       而那个函数是**服务端本地**调用（连 OnRemote 前缀都没有）。",
    "--     ⇒ 也就是说：预测开关是服务端单方面决定的，客户端只是被告知。",
  ],

  "OnInit#1+37": [
    "--★★ remote_authority —— 见文件头的详细说明。这里只强调：它是「信任位」。",
    "--   IsConsole()：主机（房主）在自己的客户端上也跑 mastersim，行为特殊。",
  ],

  "OnInit#1+39": [
    "--   GetClientTableForUser(self.inst.userid)：查该玩家的连接元数据。",
    "--   admin/moderator/friend 三者任一为真即获得信任。",
    "--   ⚠ 疑似缺陷：friend 是**社交关系**，不是权限。好友客户端可无条件硬瞬移。",
    "--     推理依据：97 行 `client.admin or client.moderator or client.friend`——",
    "--     若这是权限判定，不该包含 friend；Klei 把它当「熟人可信」而非权限。",
    "--     后果：任一房主的好友（不需要管理权限）即可获得无校验瞬移能力。",
  ],

  "OnInit#1+44": [
    "--   recent_bufferedaction：松手护栏。见 4319-4343 行的完整逻辑。",
    "--     结构：{ act（上一个缓冲动作）, t（剩余保护时间）, x, z（按下时的摇杆方向）}。",
  ],

  "OnInit#1+46": [
    "--   ★ 三个互斥的手势标志 directwalking / dragwalking / predictwalking。",
    "--     它们不是「移动方式」，而是「**输入来源**」，且贯穿双端：",
    "--       客户端：按住了方向键 / 按住了鼠标左键拖 / 点了地面走过去",
    "--       服务端：由 remote_vector.y 反推（4054-4075 行）",
    "--   ⇒ 关键用途：1826 行「自动行走时攻击范围 +6」就靠 directwalking 判断；",
    "--     2135/2203/2262 行的 FindEntity 半径也靠它（在 3 和 6 之间二选一）。",
  ],

  "OnInit#1+49": [
    "--   --deprecated, see self.client_last_predict_walk",
    "--   ⇒ 废弃但**未删除**：3005 行仍在读它（`self.remote_vector.y >= 3` 的 nopredict 分支",
    "--     之后没有清它），323 行/369 行还在重置它。属于无害的历史残留。",
  ],

  "OnInit#1+57": [
    "--   isclientcontrollerattached：手柄热插拔标志。TUNING/Profile 之外的自持状态。",
    "--     395-407 行 ToggleController 负责同步它。",
  ],

  "OnInit#1+59": [
    "--   mousetimeout = 10：10 秒无鼠标操作后……（grep 本文件后续使用，",
    "--     实际超时判定在 HUD 侧的输入处理里，这里只是初值占位）。",
  ],

  "OnInit#1+62": [
    "--   ★ controller_target：手柄「Y 键」选中的交互目标（对应鼠标的 LMB/RMB 高亮）。",
    "--   ★ controller_attack_target：手柄「X 键」选中的攻击目标。",
    "--     两者的区别是本文件 3178-3601 那 260 行存在的全部理由。",
  ],

  "OnInit#1+63": [
    "--   controller_target_age = math.huge：目标的「年龄」。",
    "--     ★ 3381 行用它做 **0.2 秒防抖**：目标刚变（age=0）时先冻结 0.2 秒再重新评估。",
    "--     为什么要防抖：手柄瞄准在两个候选边缘来回时会疯狂跳目标，",
    "--     0.2 秒的滞回让瞄准「粘住」而不是抽搐。",
  ],

  "OnInit#1+65": [
    "--   controller_attack_target_ally_cd：**友方目标冷却**。",
    "--     ★ 机制：手柄瞄准友军时默认不想打，但偶尔需要（AOE/误伤），",
    "--       于是设一个 ~1 秒的冷却，冷却内友军分数 ×0.25（3268 行）。",
    "--     初始值 nil，3198 行 `math.max(0, (cd or 1) - dt)` 让它首次进入时为 1 秒。",
  ],

  "OnInit#1+68": [
    "--   -- CharlesB: For now this is always off",
    "--   ⇒ 目标锁定的「按住修饰键」模式被弃用，改为「按一下 Toggle」（711 行 CONTROL_TARGET_LOCK）。",
  ],

  "OnInit#1+71": [
    "--   controller_targeting_lock_available = Profile:GetTargetLockingEnabled()",
    "--   ★ 这是**玩家档案级设置**，不是联机同步量。⇒ 两端各自读本地 Profile，",
    "--     理论上可能不一致（但 Profile 在联机开始时会同步，故实践中安全）。",
  ],

  "OnInit#1+75": [
    "--   command_wheel_allows_gameplay：指令轮盘打开时是否仍允许移动/操作。",
    "--     499 行 IsEnabled 用它决定返回的第二个布尔值。",
  ],

  "OnInit#1+79": [
    "--   deploy_mode = not TheInput:ControllerAttached()：鼠标模式默认可进入放置态。",
    "--     ★ 注意它是「未插手柄时为真」——因为鼠标右键就是「放置预览」的位置。",
  ],

  "OnInit#1+86": [
    "--   ★ LMBaction / RMBaction：**鼠标左/右键当前对应的动作缓存**。",
    "--     由 2827 行 playeractionpicker:DoGetMouseActions 每帧刷新。",
    "--     它是「鼠标指向」的唯一真相来源：GetLeftMouseAction/GetRightMouseAction",
    "--     只是它的 getter（5321/5325 行）。",
  ],

  "OnInit#1+89": [
    "--   handler ~= nil ⇔ 「我控制这台客户端」。★ 全文件最重要的一句话。",
    "--     handler 只在 319 行（ThePlayer）赋值，345/365 行清除。",
    "--     几乎每个 Remote*On* 的守卫都是 `self.ismastersim and self:IsEnabled() and self.handler == nil`，",
    "--     即「我是服务器、玩家已激活、且我不是这台机器的本地玩家」。",
  ],

  "OnInit#1+96": [
    "--   heldactioncooldown：长按重复的冷却计时器（由 OnUpdate:3010 每帧递减）。",
  ],

  "OnInit#1+98": [
    "--   ★ remoteinteractionaction/target/pos：把「玩家正在对谁做什么」广播给 AI。",
    "--     消费方全是 brain：mermbrain / wx78_possessedbodybrain / eater / trader /",
    "--     container_transform / wagdrone_rollingbrain / wobycommon。",
    "--     ⇒ 动机：美人鱼鱼人需要「玩家正在喂我」才能配合，",
    "--       温蒂附身的身体需要跟随主人的动作。纯 AI 协作，零玩家可见。",
  ],

  "OnInit#1+102": [
    "--★★ 【双端初始化分叉】159-175 行是理解整个文件的枢纽。",
    "--   服务端（159-164）：挂 classified 句柄、启动**每帧更新**与**每墙钟更新**。",
    "--   客户端（165-175）：",
    "--     · 只注册 _clearinteractiontarget 回调（166-171）",
    "--     · 若 classified 还没到，先挂上（172-174）",
    "--   ★ 注意：客户端**没有** StartUpdatingComponent（那在 335 行的 Activate 里，",
    "--     因为那时才确认自己是 ThePlayer）。",
  ],

  "OnInit#1+105": [
    "--   classified = inst.player_classified：服务端的「客户端可见数据」对象。",
    "--     它是 net_bool / net_tinybyte 的集合（iscontrollerenabled、",
    "--     ismapcontrolsvisible、busyremoteoverridelocomote 等）。",
    "--     ★ 参见 prefabs/player_classified.lua —— 本文件所有 classified.X:value()",
    "--       读的都是服务端写、客户端只读的单向同步量。",
  ],

  "OnInit#1+106": [
    "--   StartUpdatingComponent(self) → 每帧调用 OnUpdate(2650 行)。",
    "--   ★ 客户端的 StartUpdatingComponent 在 335 行（Activate 内）——因为客户端只有",
    "--     本机玩家需要每帧算移动意图，其他玩家的移动由 RPC 驱动。",
  ],

  "OnInit#1+107": [
    "--   StartWallUpdatingComponent(self) → OnWallUpdate(2629 行)。",
    "--     ★ WallUpdate 用的是**墙钟时间**（GetStaticTime）而非游戏时间，",
    "--       所以暂停时仍会跑 —— 4438 行的相机旋转因此在暂停菜单里也能用。",
  ],

  "self._clearinteractiontarget#1": [
    "--   _clearinteractiontarget：动作成功/失败时清掉 AI 可见的交互意图。",
    "--   --V2C 注释说明了为什么要闭包 + 双重校验：",
    "--     「This is used by action Success/Fail callback, which doesn't know",
    "--       if player got removed」——回调触发时玩家可能已被移除，",
    "--     所以必须检查 self 还是当前组件、实体还有效。",
    "--   ★ 这是防「回调晚到导致操作已销毁实体」的教科书式写法。",
  ],

  "self._clearinteractiontarget#1+6": [
    "--   客户端的 classified 可能比组件构造晚到（网络顺序问题），",
    "--     所以这里做一次补偿式 AttachClassified。",
  ],

  "self._clearinteractiontarget#1+11": [
    "--   ★ 177-178：这两个事件是**玩家 prefab 主动 Push 的**，不是引擎的。",
    "--     与 328-343 行的 ListenForEvent 形成对比：177 行在构造函数里（双端都监听），",
    "--     328 行在 Activate 里（只对本机玩家）。",
  ],

  "self._clearinteractiontarget#1+14": [
    "--   ★ DoTaskInTime(0, OnInit, self) —— 下一帧才初始化，理由见 57 行上方。",
    "--     181 行 end 是 Class 构造器的结束。",
  ],

  "PlayerController:OnRemoveFromEntity#1": [
    "--【OnRemoveFromEntity】组件从实体上卸载时的清理。",
    "--   ★ 199 行的 `PlayerController.OnRemoveEntity = PlayerController.OnRemoveFromEntity`",
    "--     是**双命名兼容**：Class 销毁器调 OnRemoveFromEntity，",
    "--     而实体销毁路径调 OnRemoveEntity。指向同一函数体。",
  ],

  "PlayerController:AttachClassified#1": [
    "--【AttachClassified】绑定 classified 并监听它的 onremove。",
    "--   ★ 用独立函数而不是闭包，是为了 193 行能 RemoveEventCallback 精确解绑。",
  ],

  "OnBuild#1": [
    "--【OnBuild】建造完成事件 → 取消放置预览。",
    "--   ★ 这是一个**服务端权威**的信号：客户端只是收到事件后清理本地预览。",
  ],

  "OnEquip#1": [
    "--【OnEquip】装备到手上 → 切换准星（reticule）。",
    "--   ★ reticule 是「指向哪」的视觉反馈载体，可能是：",
    "--     · 玩家默认的（inst.components.reticule）",
    "--     · 物品自带的（data.item.components.reticule，如火把/魔杖）",
    "--   它是「瞄准」这件事的**表现层**，与 target 计算完全解耦。",
  ],

  "OnEquip#1+2": [
    "--   只处理 HANDS（手上）槽位。EQUIPSLOTS 定义见 constants.lua。",
  ],

  "OnEquip#1+4": [
    "--   ★★ 法术书特例：手持法术书时**忽略 equip 事件**。",
    "--     理由：法术书的准星由 spellbook 组件自己管，若在这里把 reticule 换掉，",
    "--     会与法术轮盘的选中态冲突。这是「同一件东西不能有两个准星所有者」的仲裁。",
  ],

  "OnEquip#1+7": [
    "--   AOE 武器（魔杖类）：equip 时强制 StopTargeting，",
    "--     因为 AOE 施法需要「举着手杖不动」，切手会打断。",
  ],

  "OnEquip#1+14": [
    "--   ★ newreticule = 物品自己的 或 玩家默认的。优先级：物品 > 玩家。",
    "--     这让模组可以给物品挂专属准星而不必改 playercontroller。",
  ],

  "OnEquip#1+20": [
    "--   238 行的 `(newreticule.mouseenabled or TheInput:ControllerAttached())`：",
    "--     ★ 鼠标玩家 + 准星不跟随鼠标（如工具自带固定准星）→ 不创建。",
    "--     手柄玩家 → 一律创建（手柄没有鼠标位置，准星必须是方向指示器）。",
  ],

  "OnEquip#1+22": [
    "--   创建后若「当前不可操作」（!IsEnabled）或「该准星要求隐藏」（ShouldHide）→ 隐藏。",
  ],

  "OnUnequip#1": [
    "--【OnUnequip】与 OnEquip 对称，但**多一层判断**（257-259）。",
    "--   259 行 `equip == nil or self.reticule ~= equip.components.retiquel`：",
    "--     卸下的装备已经不在手上（equip 为 nil）或换成了别的东西 → 重建默认准星。",
    "--   ★ 为什么要这么麻烦：equip 与 unequip 事件的时序不保证，",
    "--     快速切手时可能先收到 uneq(HANDS) 再收到 equip(HANDS)，",
    "--     这里靠「重新读一次真实装备状态」来纠正事件乱序。",
  ],

  "OnInventoryClosed#1": [
    "--【OnInventoryClosed】关库存 → 拆掉一切瞄准态。",
    "--   ★ 必须 CancelAOETargeting：如果玩家在举魔杖瞄准时按了关库存，",
    "--     AOE 目标点会永久停在旧位置（因为拿不到新的鼠标输入）。",
  ],

  "OnZoom#1": [
    "--【OnZoom】滚轮缩放。默认步长 6。",
    "--   ★ 为什么放在 playercontroller 而不是 camera：滚轮键位可被手柄抢占",
    "--     （CONTROL_ZOOM_IN/OUT），两边的映射冲突判定在 303-304 行。",
  ],

  "OnContinueFromPause#1": [
    "--【OnContinueFromPause】从暂停恢复 / 继续游戏。",
    "--   303-304 行：缓存「手柄 ZOOM 键是否映射到了滚轮键」。",
    "--   ★ 为什么要缓存：4492/4497 行做缩放时，如果 ZOOM_IN 和 SCROLLBACK 是同一个键，",
    "--     在合成菜单里滚轮会同时触发两条缩放路径 → 缩放速度翻倍。",
    "--     缓存后可在 craftingmenu 有焦点时跳过重复的那条。",
  ],

  "OnDeactivateWorld#1": [
    "--【OnDeactivateWorld】★ 客户端专属，世界被重置/重生流程时清理。",
    "--   --V2C 注释：\"Essential cleanup when client is notified of pending server",
    "--   c_reset or c_regenerateworld\" —— 服务端要 c_reset 时客户端必须先把手上的",
    "--   状态（输入 handler、预测数据、准星）全部拆干净，否则新世界里会残留。",
  ],

  "PlayerController:Activate#1": [
    "--★★ 【Activate】313-346 行：把本组件「接上线」。",
    "--   ★ 结构是一个三重互斥 if：",
    "--     ① handler ~= nil → 已激活，若不是 ThePlayer 就先 Deactivate（独占控制权）",
    "--     ② handler == nil 且 inst == ThePlayer → 真正激活",
    "--     ③ handler == nil 且 inst ~= ThePlayer → 什么都不做（远端玩家的激活是空操作）",
    "--   ⇒ 推论：handler 是**全局单例**。两个实体不可能同时是「本地玩家」。",
  ],

  "PlayerController:Activate#1+2": [
    "--   ①的控制权抢占：切角色 / 复活后 player 换了，旧 player 必须让位。",
  ],

  "PlayerController:Activate#1+6": [
    "--   ★★ TheInput:AddGeneralControlHandler —— 输入总线的唯一挂载点。",
    "--     所有按键从这里进入 601 行的 OnControl。",
    "--     「General」= 全局处理器（不是某个屏幕的局部处理器），",
    "--     所以玩家在 crafting / map / spellwheel 打开时它**也在跑**，",
    "--     由 OnControl 内部的 IsEnabled 决定放行哪些。",
  ],

  "PlayerController:Activate#1+9": [
    "--   --reset the remote controllers just in case there was some old data",
    "--   322-324：激活时必须清空远端镜像，否则会带着上一次会话的方向键状态复活。",
    "--   ★ 3697 行 ResetRemoteController 同时清了 remote_vector.y 和 remote_controls。",
  ],

  "PlayerController:Activate#1+15": [
    "--   328-343：注册七类事件。注意 331 行的 zoomcamera 是**双端**监听",
    "--     （因为缩进在 if not ismastersim 之外），而 334-341 是纯客户端。",
  ],

  "PlayerController:Activate#1+20": [
    "--   ★ 分叉点：只有客户端才需要 StartUpdatingComponent / StartWallUpdatingComponent。",
    "--     335/336 行的这两句与 163/164 行的服务端版本配对，构成双端对称。",
  ],

  "PlayerController:Activate#1+31": [
    "--   ★ 立即调用一次 OnContinueFromPause（而不只是监听），",
    "--     因为 Activate 发生时可能没经过「continuefrompause」事件。",
  ],

  "PlayerController:Deactivate#1": [
    "--【Deactivate】Activate 的严格镜像，按相反顺序拆除。",
    "--   ★ 注意它也以 `if self.handler ~= nil` 为守卫 —— 保证幂等：",
    "--     远端玩家的 Deactivate 是空操作（因为 handler 一直是 nil）。",
    "--     这个幂等性让 188 行 OnRemoveFromEntity 可以无条件调用它。",
  ],

  "PlayerController:Deactivate#1+2": [
    "--   清理顺序有讲究：先取消所有放置/瞄准态，再拆 handler，最后清远端镜像。",
    "--   ★ 350-352 行的三个 Cancel 是对称的（BuildPlacement / DeployPlacement / AOE）。",
  ],

  "PlayerController:Deactivate#1+16": [
    "--   handler:Remove() —— 从输入总线摘除。此后 OnControl 不再被调用。",
  ],

  "PlayerController:Enable#1": [
    "--【Enable(val)】服务端 → 客户端：「这个玩家的输入是否启用」。",
    "--   ★ 391 行注意是 `set(val)` 而非 `set(val == true)`：",
    "--     与 411/418 行的写法不一致（那两处用了 `== true` 归一化）。",
    "--     ⚠ 疑似缺陷（轻微）：若外部传 nil，391 行会把 net_bool 写成 nil 而不是 false，",
    "--       客户端 `:value()` 读到 nil 后在 492 行 `not nil` 为真 → 误判为「已禁用」。",
    "--     推理依据：net_bool 的 set 是否容忍 nil 取决于 netvar 实现，",
    "--       而同文件 411/418 行明确做了 `== true` 归一化，说明作者认为需要归一化。",
  ],

  "PlayerController:ToggleController#1": [
    "--【ToggleController】手柄插拔。客户端 → RPC 告知服务端。",
    "--   396 行 `if self.isclientcontrollerattached ~= val` 保证只处理**变化**。",
  ],

  "PlayerController:ToggleController#1+7": [
    "--   SendRPCToServer(RPC.ToggleController, val) ——",
    "--     参见 networkclientrpc.lua:1055。★ 注意它没有用 OnRemote 前缀的处理器，",
    "--     而是在 RPC handler 里直接调 SetCanUseMap 之类的 classified 写入。",
  ],

  "PlayerController:EnableMapControls#1": [
    "--【EnableMapControls / SetCanUseMap】小地图可见性（416-421 是同一对）。",
    "--   ★ 用**两个独立布尔**交叉相乘而不是一个，是为了让「按设置」和「按当前状态」",
    "--     能分别被远程控制而不互相覆盖（778 次外部调用可见其重要）。",
    "--   ⚠ 但 412 行 `EnableMapControls(val and self.can_use_map)` 传的是 may-be-nil",
    "--     （val 为 nil 时），同样有上面 391 行的归一化问题。",
  ],

  "PlayerController:GetMapTarget#1": [
    "--【GetMapTarget】判断某个动作是否应「改为在地图上执行」。",
    "--   ★ 424 行的 `self.inst.HUD == nil` 检查被注释说明为：",
    "--     \"HUD check makes this client sided only but can run on server when no caves\"",
    "--     → 翻译：用 HUD 是否存在来「顺便」把服务端排除掉，但无洞穴的服务端 HUD 为 nil，",
    "--       所以这个检查**不是可靠的端判定**，只是一个副作用。",
    "--     ⚠ 疑似缺陷：真正的端判定应该用 self.ismastersim。",
    "--       推理依据：注释自己承认「can run on server when no caves」，",
    "--       而 444 行 PullUpMap 里的 NOTES(JBK) 注释又说「assuming inst is the local client」，",
    "--       两处都承认了这里存在端判定的漏洞，只是没人修。",
  ],

  "PlayerController:GetMapTarget#1+5": [
    "--   ★ maptarget 的来源优先级：动作的 target（除非 map_only）→ 手持物。",
    "--     428 行 `(not act.action.map_only and act.target) or act.invobject or nil`",
    "--     用 and/or 链实现「map_only 动作不指向 target 而指向物品」。",
  ],

  "PlayerController:GetMapTarget#1+10": [
    "--   两种豁免：动作显式声明了 maptarget（地图自己传的），",
    "--     或目标带 action_pulls_up_map 标签（地图本身就是该动作的目标，如雕像）。",
  ],

  "PlayerController:GetMapTarget#1+14": [
    "--   valid_map_actions 是「白名单」：地图目标可以限制哪些动作在地图上做。",
    "--   ★ 这是模组扩展点：给实体加 valid_map_actions 就能定制地图交互。",
  ],

  "PlayerController:PullUpMap#1": [
    "--【PullUpTarget → PullUpMap】打开地图并把 maptarget 传进去。",
    "--   ★ 本函数是**纯客户端 UI 操作**（大量 self.inst.HUD: 调用），",
    "--     但它被 879/1140/4790/5031 四处从动作路径调用，而动作路径双端都跑。",
    "--     ⇒ 靠 424/445 行的 HUD/HUD 检查与服务端无 HUD 来短路。",
  ],

  "PlayerController:PullUpMap#1+2": [
    "--   先收回手持物：地图上不能手持东西操作（否则会拿着斧头开地图）。",
    "--   449 行的 `if not IsHolding(activeitem) then return end` 是竞态防护：",
    "--     ReturnActiveItem 可能因物品已被丢弃而失败，此时必须整体放弃。",
  ],

  "PlayerController:PullUpMap#1+22": [
    "--   ★ self.skip_inherentmapaction = true —— 一个刻意的 hack：",
    "--     ToggleMap 内部会触发 OnUpdate(0)，而 OnUpdate 会调 GetMapActions，",
    "--     那时 mapscreen 还没拿到 maptarget，会算出一套错误的动作。",
    "--     这个标志让那一帧的 GetMapActions 跳过内建地图动作分支（5174 行）。",
    "--   ⇒ 设计代价：全局可变的临时标志，必须在同一函数内立即清掉（468 行）。",
  ],

  "PlayerController:PullUpMap#1+27": [
    "--   ⚠★ 疑似缺陷（跨对象字段污染）：这里设置的是 **mapscreen** 上的同名字段，",
    "--     而 612-618 行的 OnControl 读的是 **self（playercontroller）** 的同名字段。",
    "--     推理依据：grep 全仓，playercontroller 上的 _hack_ignore_held_controls",
    "--       只被 screens/mapscreen.lua:1361-1362 设置（那里明确写 playercontroller.XXX）；",
    "--       471 行写的是 mapscreen.XXX，被 mapscreen.lua:1313 自己消费。",
    "--     结论：这两处是**两个不同对象的同名字段**，各自消费，看起来是有意为之",
    "--       （开地图时 mapscreen 要忽略自己收到的按键；关地图时 playercontroller",
    "--        要忽略松手事件）。但命名完全相同、语义几乎一致，极易误读。",
    "--       建议：若要重构，先把 mapscreen 上的那份改名。",
  ],

  "PlayerController:PullUpMap#1+31": [
    "--   map_remap_min_dist：需要先在地图上定位到一个位置才能执行的地图动作",
    "--     （例如「在地图上标记雕像位置」）。477 行的 +0.1 是浮点保护。",
  ],

  "PlayerController:PullUpMap#1+36": [
    "--   ★-- Z offset is negative to desired from Transform coordinates。",
    "--     Transform 的 Z 轴与数学 Z 轴**相反**（引擎是左手系 + Z 朝屏幕内）。",
    "--     凡是 `x + cos(rot)*d, z - sin(rot)*d` 这种写法都源于此。",
    "--     ★ 这是本文件里最容易搞错符号的地方：",
    "--       4034 行 atan2(z0-pt.z, pt.x-x0)、4360 行 -atan2(dir.z,dir.x)、",
    "--       1654 行 atan2(-dir.z, dir.x) —— 全是这个符号约定的受害者。",
  ],

  "PlayerController:PullUpMap#1+41": [
    "--   ProcessStaticDecorations：地图上的静态装饰（季节标记等）需要立即刷新。",
  ],

  "PlayerController:IsEnabled#1": [
    "--★★ 【IsEnabled】**双返回值**，这是本文件最容易被误用的函数。",
    "--   返回 (false)            —— 完全禁用（classified 说禁用，或 HUD 抢了焦点）",
    "--   返回 (false, true)      —— ★ HUD 阻塞，但**部分输入仍应放行**",
    "--   返回 (true)             —— 正常可操作",
    "--   -- returns: enable/disable, \"a hud element is up, but still allow for limited",
    "--   gameplay to happen\"",
    "--   ⇒ 630 行 OnControl 用 `if isenabled or ishudblocking` 放行三个按钮",
    "--     （ACTION / ATTACK / COMMAND_WHEEL），647 行才真正 return。",
    "--   ⇒ 2691-2754 行 OnUpdate 用它决定「要不要强行停下移动」。",
  ],

  "PlayerController:IsEnabled#1+3": [
    "--   HUD:HasInputFocus()：焦点在 HUD 上的任一 widget（如合成菜单输入框）。",
  ],

  "PlayerController:IsEnabled#1+5": [
    "--   ★ `(IsCraftingOpen() and TheFrontEnd.textProcessorWidget == nil)`：",
    "--     合成菜单开着，但**没有**文本编辑器获得焦点 → 只阻塞 HUD 层面的通用输入，",
    "--     但仍允许「操作」类按钮（在合成菜单里点击合成是合法的）。",
    "--     textProcessorWidget 非 nil 时（玩家正在给物品改名）才完全阻塞。",
  ],

  "PlayerController:IsEnabled#1+8": [
    "--   command_wheel_allows_gameplay：玩家设置里允许「轮盘开着也能操作」。",
  ],

  "PlayerController:IsMapControlsEnabled#1": [
    "--【IsMapControlsEnabled】小地图控制是否可用（三个条件与）。",
    "--   与 IsEnabled 的区别：不管焦点，只看 classified 三个同步位。",
  ],

  "PlayerController:IsControlPressed#1": [
    "--★★ 【IsControlPressed】**双端统一的按键查询**。这是本文件的抽象精髓。",
    "--   本地玩家 → 问 TheInput；远端玩家 → 问 remote_controls。",
    "--   ⇒ 于是 601 行的 OnControl、1122 行的重复动作、3135 行的连击攻击，",
    "--     这些逻辑**写一次、两端跑**，完全不需要 if ismastersim 分流。",
    "--   ★ 设计代价：remote_controls 的值必须被远端玩家的 RPC 及时维护（见 546-572 行）。",
  ],

  "PlayerController:IsAnyOfControlsPressed#1": [
    "--【IsAnyOfControlsPressed(...)】上面那个的变参版本（22 处外部调用）。",
    "--   ★ 2579 行的 IsAnyActionHoldButtonHeld 是它的「本地特化版」——",
    "--     因为长按判定必须用真实输入（remote_controls 的值可能是陈旧的冷却）。",
  ],

  "PlayerController:CooldownRemoteController#1": [
    "--【CooldownRemoteController】给 remote_controls 全体减冷却。",
    "--   ★ 537 行的 `dt ~= nil and math.max(v-dt,0) or 0`：",
    "--     ★★ 传 dt 则正常倒数；**传 nil 直接清零**。",
    "--     这就是 4143/4349/4355/4400/4429 行那些 `CooldownRemoteController()`",
    "--     无参调用能立即解除「按键还按着」状态的原理。",
    "--     ⚠ 这个「dt 为 nil 意为清零」的二义性是隐式契约，靠 arity 区分，",
    "--       极易在重构时踩坑（写成 dt=nil 的显式传参会静默清零）。",
  ],

  "PlayerController:CooldownHeldAction#1": [
    "--【CooldownHeldAction】长按冷却的递减。547-558 行是远端玩家的按键抬起处理。",
  ],

  "PlayerController:OnRemoteStopControl#1": [
    "--   ★ 守卫 `self.handler == nil`：只有远端玩家才需要「处理别人按键的抬起」。",
    "--     本地玩家的抬起由 TheInput 自己管（622 行直接 return，不发 RPC）。",
  ],

  "PlayerController:RemoteStopControl#1": [
    "--【RemoteStopControl / RemoteStopAllControls】本地玩家的按键抬起 → RPC。",
    "--   ★ 561/568 行的重复检查（已经 nil 就不发）是带宽优化：",
    "--     抬起事件可能重复到达，只在真正变化时通知服务器。",
  ],

  "PlayerController:RemotePausePrediction#1": [
    "--【RemotePausePrediction(frames)】★ 68 次外部调用，是给外部（AI/陷阱/剧情）",
    "--   用的「暂时冻结这个玩家的客户端预测」开关。",
    "--   ★ 典型用法：韦布斯特/温蒂的操作需要玩家的位置在某一帧绝对准确。",
    "--     写入 classified.pushpausepredictionframes，客户端 765 行 IsBusy 读它。",
  ],

  "PlayerController:ShouldPlayerHUDControlBeIgnored#1": [
    "--★ 【ShouldPlayerHUDControlBeIgnored】★ **给 HUD 用的优先级仲裁钩子**。",
    "--   -- NOTES(JBK) 的英文原文解释了整件事的由来：",
    "--     \"The PlayerHud gets control events before PlayerController which works",
    "--      for most cases. Some cases are exceptions for priority which are handled",
    "--      here to have PlayerController take over. This would be good to have a",
    "--      CONTROL_ priority list and SetDigitalControlFromInput creates a table",
    "--      that is sent to game. Right now priority is lower CONTROL_ id is higher",
    "--      priority. So this function exists to force a priority based off of",
    "--      function run ordering.\"",
    "--   → 翻译：HUD 比 PlayerController 先收到按键，所以 HUD 想「抢」某个键时，",
    "--     它会问本函数「这个键我要不要跳过」。跳过 = 忽略 = 让给 PlayerController。",
    "--   ⇒ 两个场景：①轴对齐放置时，方向键应归放置器（588 行）",
    "--            ②目标锁定时，方向键应归目标列表切换（592 行）",
    "--   ⚠ K 自己承认这是权宜之计（\"This would be good to have a CONTROL_ priority",
    "--     list\"）。真实设计应有一个显式的控件优先级表。",
  ],

  "PlayerController:ShouldPlayerHUDControlBeIgnored#1+7": [
    "--   588 行的 `control ~= X and ControlsHaveSameMapping(..., CONTROL_X)`：",
    "--     ★ 不是按 ID 比，而是按「实际键位映射」比 —— 因为手柄可重绑定，",
    "--       CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID 在不同手柄上绑到不同物理键。",
    "--     这也解释了为什么这个钩子必须是**函数**而不是 HUD 里的静态表。",
  ],

  "PlayerController:OnControl#1": [
    "--★★★ 【OnControl】601-718 行：★ **整个玩家输入的唯一入口**。",
    "--   设计要点：",
    "--   ① 它是 AddGeneralControlHandler 的回调（319 行），**只在本机玩家**触发。",
    "--   ② 它对**所有**按键一视同仁地做守卫，然后按 CONTROL_ 分派。",
    "--   ③ 服务端永远收不到它（因为 handler 为 nil 时 Activate 不会注册）。",
    "--   ⚠ 618 行 return true 与其他分支的裸 return 混用：",
    "--     返回值在 AddGeneralControlHandler 的语义里是「已消费」，",
    "--     但 601-718 行大部分分支都是**裸 return（nil）**，",
    "--     意味着 PlayerController 几乎从不「消费」事件 —— 它只是旁路处理。",
    "--     真正的事件消费方是 HUD（1427 行问 ShouldPlayerHUDControlBeIgnored）。",
  ],

  "PlayerController:OnControl#1+2": [
    "--   暂停时直接 return：★ 暂停期间 playercontroller 完全不响应输入。",
    "--     这也是为什么 4438 行的相机旋转要放在 OnWallUpdate（墙钟）里。",
  ],

  "PlayerController:OnControl#1+6": [
    "--   ★ isenabled, ishudblocking = self:IsEnabled() —— 注意接收两个返回值。",
    "--     608 行 `if not isenabled and not ishudblocking then return end`：",
    "--     两者皆假才彻底放弃（HUD 完全不阻塞时不该由 PC 处理任何键）。",
  ],

  "PlayerController:OnControl#1+11": [
    "--   _hack_ignore_held_controls：开地图后忽略「已经按下的键的抬起」，",
    "--     防止玩家点「开地图」那一下的松开动作被误当成新操作。",
    "--     ★ 614 行 return true 是「消费掉这个事件」，与本函数其余分支不同 ——",
    "--       这两个 hack 分支是唯一真正返回 true 的地方。",
  ],

  "PlayerController:OnControl#1+15": [
    "--   对称分支：把 613 行记下的 control 从忽略名单里摘掉，然后消费。",
    "--   ★ 设计意图：按下时忽略（记下来）→ 松开时也忽略一次（摘名单）→ 之后恢复正常。",
    "--     若只做 612 行不做 616 行，这个键将**永远**无法再次触发。",
  ],

  "PlayerController:OnControl#1+20": [
    "--   --V2C: control up happens here now —— ★ 历史注释，说明这段是重排过的。",
    "--   ★★ 622-627 行是一个极其重要的**方向性设计**：",
    "--     几乎所有「抬起」事件在这里被统一处理成 RemoteStopControl，然后 return，",
    "--     **不再走下面的分派逻辑**。",
    "--     ⇒ 推论：OnControl 的分派部分只对「按下」事件有效（PRIMARY/SECONDARY 除外，",
    "--       它们在 622 行被显式排除，会继续往下走到 651/653 行）。",
    "--     ⇒ 推论 2：抬起时清 remote_controls（624 行），这保证了 511 行",
    "--       IsControlPressed 在远端玩家身上不会「卡住」。",
  ],

  "PlayerController:OnControl#1+28": [
    "--   -- actions that can be done while the crafting menu is open go in here",
    "--   ★ 这三个按钮（ACTION/ATTACK/COMMAND_WHEEL）是**唯一允许在 HUD 打开时",
    "--     仍然生效**的。设计原因见 496 行：在合成菜单里点物品 = 合成。",
  ],

  "PlayerController:OnControl#1+34": [
    "--   ★ CONTROL_ATTACK 的双端分叉是关键设计：",
    "--     服务端**不立即执行**，而是把 CONTROL_ATTACK 这个**常量**塞进 attack_buffer，",
    "--     交给 OnUpdate:2777 去执行；客户端立即执行（因为要预测）。",
    "--     ⇒ 为什么服务端要绕一圈？因为 OnControl 发生在输入时刻，",
    "--       而执行需要 Locomotor 的状态（能否边走边打），那要等下一帧。",
  ],

  "PlayerController:OnControl#1+46": [
    "--   三个「HUD 也允许」的按钮处理完，才在这里真正阻断。",
    "--   ⇒ 从这里往下是「游戏世界输入」：PRIMARY / SECONDARY / CANCEL / INSPECT /",
    "--     控制器动作 / 库存格子 / 目标锁定。",
  ],

  "PlayerController:OnControl#1+50": [
    "--   PRIMARY = 鼠标左键 = 「做动作」。SECONDARY = 鼠标右键 = 「另一动作/AOE/放置」。",
    "--   ★ 与手柄的对应：PRIMARY ↔ CONTROLLER_ACTION(X)，",
    "--     SECONDARY ↔ CONTROLLER_ALTACTION(Y)，CONTROL_ATTACK(Z 或 扳机)。",
    "--     ⇒ 三键对应三套 GetXxxAction 查询，见 2096/5373/5450 行的分工。",
  ],

  "PlayerController:OnControl#1+59": [
    "--   CONTROL_CANCEL = 右键取消放置。662 行注释掉的 ControllerTargetLock(false)",
    "--     说明「取消键同时解除目标锁定」是设计过但未启用的。",
  ],

  "PlayerController:OnControl#1+62": [
    "--   轴对齐放置时按循环键 → 切换对齐方式（0°/45°/90°/世界坐标）。",
  ],

  "PlayerController:OnControl#1+76": [
    "--   677 行 `self.inst.replica.inventory:IsVisible()`：库存可见才处理库存格子操作。",
    "--     ★ 这是「库存 UI 打开时手柄的十字键变成光标」的守卫。",
  ],

  "PlayerController:OnControl#1+79": [
    "--   ★★ 680-706 行是**手柄方案适配层**：同一批库存格子操作，",
    "--     在「经典映射」和「方向键映射」下用不同的 CONTROL_ id。",
    "--   -- 682 行的英文注释说明了为什么这么写：",
    "--     \"Classic mapping control IDs aren't in the same order as",
    "--      (up/down/left/right), so lets handle it manually here rather than",
    "--      calling ResolveVirtualControls 4 times.\"",
    "--     → 经典映射的 ID 顺序不是上/下/左/右，调用 ResolveVirtualControls 4 次",
    "--       开销大且顺序对不上，于是手工枚举。",
    "--   ⇒ 设计代价：新增映射方案必须同时改这两支。",
  ],

  "PlayerController:OnControl#1+92": [
    "--   693-706：现代映射只需解析一次虚拟控件基址，再按 +0/+1/+2/+3 偏移。",
    "--   696/698/700/702 行注释直接标出了每个偏移对应哪个操作。",
  ],

  "PlayerController:OnControl#1+109": [
    "--   710-716：目标锁定的两个按键。★ 全部包在 `if down` 里 —— 只响应按下。",
  ],
};

export const AFTER = {};