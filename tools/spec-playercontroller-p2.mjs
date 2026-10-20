// spec-playercontroller-p2.mjs —— 第 2 段：620-1300 行
// 覆盖：OnControl 收尾、修饰键位掩码、CanLocomote/IsBusy、控制器动作按钮（X/Y/扳机）
//       及其 Remote 对端

export const BEFORE = {
  "PlayerController:OnControl#1+119": [
    "--============================================================",
    "-- 【第二段】620-1300 行：修饰键位掩码 / 预测准入 / 手柄三键与其服务端对端",
    "--============================================================",
  ],

  "PlayerController:OnControl#1+121": [
    "--★★ 【MOD_CONTROLS】四个「修饰键」的集合，它们被压缩成一个整数发送。",
    "--   FORCE_INSPECT / FORCE_ATTACK / FORCE_TRADE / FORCE_STACK。",
    "--   ★ 为什么需要独立于 CONTROL_ 的「强制」键：",
    "--     手柄上「攻击」只有一个键，但玩家需要在「不攻击」的前提下强制攻击",
    "--     （如强杀友方宠物、强制采集不采集物、强行交易给中立 NPC）。",
    "--     键盘上这靠组合键区分；手柄只能靠「同时按另一个键」。",
  ],

  "PlayerController:EncodeControlMods#1": [
    "--【EncodeControlMods】★ 客户端把 4 个修饰键压成 1-15 的整数。",
    "--   编码方式：第 i 个键按第 i 位（bit 从 1 开始翻倍）。",
    "--   737 行 `return code ~= 0 and code or nil`：0 表示「无修饰」，",
    "--     ★ 这里**故意返回 nil 而不是 0** —— RPC 的可选参数 nil 表示「参数缺省」，",
    "--       0 会被当成「显式传了 0」。这是 Lua 里区分「false/nil」的常见技巧。",
  ],

  "PlayerController:DecodeControlMods#1": [
    "--【DecodeControlMods】服务端反向解码，写进 remote_controls。",
    "--   ★ 设计要点：Decode **总是**给每个修饰键赋值（0 或 nil），不是只写命中的。",
    "--     因为按住修饰键时会**每帧**重发（LMB/RMB 的 preview_cb），",
    "--     若只写命中位，松手时（code=0）旧值不会被清掉 → 修饰键永久卡住。",
    "--   ⇒ 这与 754 行 ClearControlMods（显式清空）互为补充：",
    "--     Clear 用于动作执行完（4924/5105 行），Decode 用于每次新输入。",
  ],

  "PlayerController:DecodeControlMods#1+2": [
    "--   bit 初值是最高位（2^(n-1)），倒序遍历 → 高位对应列表末尾的键。",
    "--   ⚠ 编码用正序递增、解码用倒序递减，两者必须严格对称。",
    "--     推理依据：730-738 用 `bit=1; bit=bit*2` 正序；",
    "--       740-752 用 `bit=2^(n-1); bit=bit/2` 倒序。任一方改顺序都会静默错位。",
  ],

  "PlayerController:CanLocomote#1": [
    "--★★ 【CanLocomote】★ **「本帧能否做本地预测移动」的唯一判据**。",
    "--   服务端恒为 true（权威，不需要「预测」）。",
    "--   客户端要同时满足五个条件：",
    "--     ① 有 locomotor（非行走单位）",
    "--     ② 状态图没有 busy 标签",
    "--     ③ 没有 pausepredict 标签（被外部 RemotePausePrediction 冻结）",
    "--     ④ classified.pausepredictionframes > 0（冻结帧数还没耗尽）",
    "--     ⑤ entity:CanPredictMovement()（引擎层的判断，见 entityreplica）",
    "--   ⇒ 大量 preview_cb 的安装都以它为前提（895/913/932/1161/1371/...）。",
    "--   ★ 为什么单独抽成函数而不是内联：这五个条件在文件里出现 40+ 次，",
    "--     且 ③④ 是「服务端下发、客户端读取」的一对，必须永远同时判。",
  ],

  "PlayerController:IsBusy#1": [
    "--【IsBusy】与 CanLocomote 并列的第二个高频判据，但**只判 busy**。",
    "--   ★ 双端差异很有意思：",
    "--     服务端用 sg:HasStateTag(\"busy\")；",
    "--     客户端额外看 inst:HasTag(\"busy\")（无状态图的客户端走标签路径，773 行）",
    "--       以及 classified.pausepredictionframes（服务端主动冻结）。",
    "--   ⇒ 推论：客户端的「忙」判定比服务端**宽**（多了两个条件），",
    "--     所以客户端会**更保守**地放弃预测。这是有意的：宁可少预测也不错预测。",
  ],

  "PlayerController:GetCursorInventoryObject#1": [
    "--【GetCursorInventoryObject】手柄模式下库存光标下的物品。",
    "--   ★ 双重守卫：HUD 存在（服务端为 nil）且手柄已连接（鼠标模式光标无意义）。",
    "--   784 行的 `item ~= nil and item:IsValid() and item or nil`：",
    "--     把 false/nil 归一为 nil，避免下游拿到一个假值。",
  ],

  "PlayerController:DoControllerActionButton#1": [
    "--★★ 【DoControllerActionButton】手柄 X 键（CONTROLLER_ACTION）。全文件最长的分支树之一。",
    "--   它要区分**五种**完全不同的上下文：",
    "--     ① 建造放置模式（placer/placer_recipe）→ 直接 MakeRecipeAtPoint",
    "--     ② 部署放置（deployplacer）→ 取 GetDeployAction",
    "--     ③ AOE 瞄准中 → 取 GetGroundUseAction 并要求是 CASTAOE",
    "--     ④ 有控制器目标 → GetSceneItemControllerAction",
    "--     ⑤ 都没有 → GetGroundUseSpecialAction（点地特殊动作）",
    "--   ★ 每种上下文对应的 RPC 都不同（ControllerActionButton / ...Point / ...Deploy），",
    "--     这是本文件里唯一一处「一个按键三条 RPC」的分支。",
  ],

  "PlayerController:DoControllerActionButton#1+1": [
    "--   ★ 建造放置的优先处理：手柄模式下 placer 是「已选好蓝图，按 X 放下」。",
    "--   798 行检查 can_build（放置器自己的可建判定，不查 inventory 的材料）。",
  ],

  "PlayerController:DoControllerActionButton#1+5": [
    "--   ★ 双重条件：replica.builder 存在 且 未在建造中（IsBusy）。",
    "--     IsBusy 防止「连按 X 一次建三个」。",
  ],

  "PlayerController:DoControllerActionButton#1+8": [
    "--   override_build_point_fn：允许放置器自己决定最终建造点。",
    "--     ★ 例：长矛/火把这类「要放在玩家脚下而非鼠标处」的物品。",
  ],

  "PlayerController:DoControllerActionButton#1+15": [
    "--   失败放置的回调（onfailedplacement）：材料不够 / 被占用时的提示。",
  ],

  "PlayerController:DoControllerActionButton#1+22": [
    "--   ② 部署放置：手柄拿着的可部署物品的预览。",
    "--   821 行 `act.distance = 1`：★ 强制把作用距离改成 1。",
    "--     为什么：服务器会对同一个动作做二次的距离校验（actions.lua 的 rangecheckfn），",
    "--     而服务器算出的距离可能因为平台/落点误差而超过原值，直接改成 1 保证能过。",
  ],

  "PlayerController:DoControllerActionButton#1+30": [
    "--   ③ AOE 瞄准：正在用魔杖/法术书瞄点。",
    "--   826 行的 `(canrepeatcast and HasTag(\"canrepeatcast\"))`：",
    "--     ★ 允许「busy 时继续连射」的道具（如多重施法卷轴），需同时满足两个条件。",
    "--   827-828：不能重复施法时播负面音 + 准星闪烁（纯表现，立即 return）。",
  ],

  "PlayerController:DoControllerActionButton#1+38": [
    "--   ★ 833 行的守卫 `act.action ~= ACTIONS.CASTAOE`：",
    "--     「瞄准中但脚下没有合法施法点」→ 什么都不做（不是「换个动作」，那是 X 键之外的职责）。",
  ],

  "PlayerController:DoControllerActionButton#1+42": [
    "--   --meh.. reusing obj =P  —— 英文原注释「obj 复用为 P（玩家）」。",
    "--   ★ 这是真实的代码债：obj 在这个分支里被当作「施法者」重载，",
    "--     而在 844-868 的分支里它是「目标实体」。两个语义共用一个变量，",
    "--     导致 901 行的 `elseif obj == nil` 判断依赖这个重载。",
  ],

  "PlayerController:DoControllerActionButton#1+46": [
    "--   PingReticuleAt：往准星位置发一个涟漪特效（纯表现）。",
    "--   841 行的 ShouldRepeatCast：不消耗弹药则继续瞄准（如永动火把）。",
  ],

  "PlayerController:DoControllerActionButton#1+50": [
    "--   ④ 有控制器目标（手柄 Y 键选中的东西）。",
    "--   ★ 与鼠标路径的根本差异：鼠标用「鼠标指向的世界坐标」，",
    "--     手柄用「玩家自己选中的实体」。因此 GetSceneItemControllerAction 接收实体。",
  ],

  "PlayerController:DoControllerActionButton#1+55": [
    "--   船炮 / 高尔夫的特殊处理：把 obj 复用成 nil，让 RPC 走 Point 变体。",
    "--     ★ 因为这两个动作是「aim at point」而非「target an entity」。",
  ],

  "PlayerController:DoControllerActionButton#1+68": [
    "--   ⑤ 兜底：点地特殊动作（GetGroundUseSpecialAction，5450 行）。",
    "--   ★ isspecial = true 会一路带到 RPC（第 12 个参数），",
    "--     服务端据此选择 GetGroundUseSpecialAction 而不是 GetGroundUseAction。",
  ],

  "PlayerController:DoControllerActionButton#1+76": [
    "--★★ 【act == nil 的处理】870-877 行是本文件里「无动作也要通知服务器」的范式。",
    "--   --Still need to let the server know our controller action button is down",
    "--   ★ 为什么需要：服务端靠 remote_controls[CONTROL_CONTROLLER_ACTION] 知道",
    "--     「玩家正按着 X」，这影响连击攻击（3137 行）、DoClientBusyOverrideLocomote 等。",
    "--     若客户端按了但什么都没做，服务端会以为玩家一直没按 → 行为不一致。",
    "--   ⇒ 这个「无参 RPC」在本文件出现 10+ 次（874/911/930/1159/1178/1369/...），",
    "--     是双端状态同步的必要组成，不是冗余代码。",
  ],

  "PlayerController:DoControllerActionButton#1+85": [
    "--   maptarget 检查：某些动作改为在地图上执行（如给雕像上香）。",
    "--   881 行 map_only 动作传 forced_actiondef，让地图界面强制按此动作。",
  ],

  "PlayerController:DoControllerActionButton#1+92": [
    "--★★ 【三分支发送架构】886-939 行是本文件的**核心范式**，每个按钮都是这个形状：",
    "--   if self.ismastersim then",
    "--       —— 服务端：直接执行（不需要发 RPC，自己就是权威）",
    "--   elseif self.locomotor == nil then",
    "--       —— 无 locomotor 的客户端（纯 UI 客户端，如服务器机）：",
    "--          装 non_preview_cb，动作**不会**被缓冲，DoAction:4546 会立刻触发回调",
    "--   else",
    "--       —— 有 locomotor 的预测客户端：",
    "--          ①先发一个「按钮按下」的无参 RPC（870-877 那个范式）",
    "--          ②装 preview_cb —— 等客户端**真的走到位、动画播完**才发真 RPC",
    "--   ⇒ ★★★ 核心洞察：preview_cb 的触发时机决定了「网络省流 + 手感」：",
    "--     玩家点了「走过去砍树」，如果立刻发 RPC，服务器在玩家还没到时就砍完了，",
    "--     客户端随后要硬回滚。把 RPC 推迟到到达瞬间，服务器的时间线与客户端一致，",
    "--     无需回滚。代价是**服务器响应变慢**（要等走路完成）。",
    "--   ⇒ 这就是为什么 preview_cb 里要再读一次 TheInput:IsControlPressed（896 行）：",
    "--     因为按下→走 2 秒→松开，服务器收到的应该是「松开」而非「按下」。",
  ],

  "PlayerController:DoControllerActionButton#1+93": [
    "--   服务端：清掉 combat 的目标。为什么？",
    "--     因为「攻击」与「移动到某处」是互斥的，新动作开始意味着放弃旧目标。",
    "--     ★ 这个 SetTarget(nil) 在文件里出现 15+ 次（946/990/1047/1194/1239/1359/...），",
    "--       是「动作开始即清战斗目标」这一统一约定的体现。",
  ],

  "act.non_preview_cb#1": [
    "--   non_preview_cb 路径：locomotor 为 nil，没有 locomotor 模块可以调用回调。",
    "--   892 行第 6 个参数 `act.rotation ~= 0 and act.rotation or nil`：",
    "--     ★ 又是「0 → nil」的三元惯例（730 行同款）：0 是「没旋转」的默认值，",
    "--       转成 nil 是为了让服务端用默认旋转。",
  ],

  "act.preview_cb#1": [
    "--   preview_cb：只有 CanLocomote（4003 行的判据）通过才装。",
    "--     否则玩家在 busy 状态按 X 无效 —— 与服务端行为一致。",
  ],

  "act.preview_cb#1+6": [
    "--   obj == nil 分支 = 上面 835/850/857 行那些「obj 被复用成 nil」的分支。",
    "--   ★ 也就是说：即使前面把 obj 置 nil 了，这里也能正确走到 Point 变体。",
    "--     这是「用变量重载来隐式传参」带来的耦合点——改 835 行会直接影响这里。",
  ],

  "act.non_preview_cb#2+2": [
    "--   ControllerActionButtonPoint 的完整参数（12 个）：",
    "--     actioncode, pos_x, pos_z, isreleased, canforce, mod_name,",
    "--     platform, platform_relative, isspecial, spellbook, spell_id",
    "--   ★ mod_name 是**模组命名空间**（见 actions.lua 的 MOD_ACTIONS_BY_ACTION_CODE），",
    "--     原版动作为 nil。服务端据此在原版表或模组表里查动作。",
  ],

  "act.preview_cb#2+7": [
    "--   有目标（obj ~= nil）的 else 分支：发 ControllerActionButton（带 target）。",
    "--   ★ 注意 936 行传的是 `nil` 而不是 `act.action.canforce`：",
    "--     preview 阶段一律不强制（896 行同理），因为此时还不知道最终会走到哪。",
  ],

  "PlayerController:OnRemoteControllerActionButton#1": [
    "--★★ 【OnRemoteControllerActionButton】服务端的同款逻辑 —— 注意它**重新算一遍**。",
    "--   957 行 `local lmb, rmb = self:GetSceneItemControllerAction(target)`：",
    "--     ★★ 这是「意图编号校验」的核心：客户端上报 actioncode=42（CHOP），",
    "--       服务端不信，自己在**同一位置、同一上下文**再算一次，看是不是也是 42。",
    "--       只有相等才执行（974-979 行）。",
    "--   ⇒ 安全模型：客户端无法伪造「在 30 单位外砍树」——服务端算出来的会是别的东西",
    "--     或 nil，动作直接被丢弃。这解释了为什么整个文件没有「信任客户端距离」。",
  ],

  "PlayerController:OnRemoteControllerActionButton#1+1": [
    "--   ★ 三重守卫，逐层收窄：",
    "--     ① ismastersim   —— 必须是服务端（防 RPC 重放到自己）",
    "--     ② IsEnabled()   —— 玩家必须处于可操作状态（防「关着菜单时发 RPC」）",
    "--     ③ handler == nil —— 玩家不能是本机玩家（防自己给自己发）",
  ],

  "PlayerController:OnRemoteControllerActionButton#1+6": [
    "--   actioncode == nil = 「我只告诉你按钮按下了，没有具体动作」。",
    "--   951 行 assert(isreleased == nil)：★ 无参 RPC 时不允许带 isreleased。",
    "--     这是一条自检断言，防止将来有人给无参 RPC 加参数时静默破坏协议。",
  ],

  "PlayerController:OnRemoteControllerActionButton#1+12": [
    "--   SetClientRequestedAction(actioncode, mod_name)：",
    "--     ★★★ 把客户端上报的 actioncode 临时注入 playeractionpicker 的判定条件，",
    "--       让 GetSceneItemControllerAction 「假装」客户端请求的就是这个动作。",
    "--     为什么需要：actions 里同一个按钮在不同物品下可能是不同动作，",
    "--       服务端需要知道客户端**当时看到的是哪个**，才能算出同一个结果。",
    "--     958 行 ClearClientRequestedAction() 必须成对调用，否则会污染后续查询。",
  ],

  "PlayerController:OnRemoteControllerActionButton#1+19": [
    "--   --Possible for lmb action to switch to rmb after autoequip",
    "--   ★★ 964-972 行的 and/or 链在处理**自动装备导致的动作漂移**：",
    "--     客户端按 X 时手里拿的是斧头 → 算出 CHOP（code=1）；",
    "--     服务端算之前 DoActionAutoEquip 可能把斧头换到了手上 → 算出别的 code。",
    "--     所以服务端接受「lmb 或 rmb 中任一匹配」。",
    "--   ⚠ 代价：这条放宽让客户端可以上报 rmb 的 code 来强制执行右键动作。",
    "--     风险有限（服务端仍会检查距离/CanTarget），但确实是校验的松动点。",
  ],

  "PlayerController:OnRemoteControllerActionButton#1+31": [
    "--   canforce 且未被禁止 → 把动作点设为「客户端预测位置」并标记 forced。",
    "--   ★ 976 行 `self:GetRemotePredictPosition() or self.inst:GetPosition()`：",
    "--     用**预测位置**而不是当前位置，是为了对齐客户端「我站在哪」。",
    "--     force 在 actions.lua 的 rangecheckfn 里意味着「跳过距离检查」。",
    "--   ⇒ 安全影响：forced 动作绕过距离校验。但目标实体本身仍要过 CanTarget。",
  ],

  "PlayerController:OnRemoteControllerActionButtonPoint#1": [
    "--【OnRemoteControllerActionButtonPoint】点地版本的服务端对端。",
    "--   996 行的 isspecial 分支：客户端点的是「特殊点地动作」，",
    "--     服务端走 GetGroundUseSpecialAction（5450 行）而不是 GetGroundUseAction。",
  ],

  "PlayerController:OnRemoteControllerActionButtonPoint#1+10": [
    "--   spellbook 分支：法术书施法。1002 行 SelectSpell(spell_id) 强制选中同一个法术。",
    "--     ★ 这是「客户端说我要放第 3 个法术」的合法化：服务端不接受 spell_id 之外的任何东西，",
    "--       但会验证「这本书在不在你手上」（999-1000 行的 GetGrandOwner）。",
  ],

  "PlayerController:OnRemoteControllerActionButtonPoint#1+19": [
    "--   两个特殊动作不走通用 GetGroundUseAction：",
    "--     船炮 → playeractionpicker:GetCannonAimActions（165 行）",
    "--     高尔夫 → GetGolfAimActions（184 行）",
    "--   ★ 它们都需要「玩家正站在船上/球场上」这一额外上下文。",
  ],

  "PlayerController:OnRemoteControllerActionButtonDeploy#1": [
    "--【OnRemoteControllerActionButtonDeploy】部署（放下物品）的服务端对端。",
    "--   1051 行三重校验：物品有 inventoryitem + GrandOwner 是自己。",
    "--     ★ 这是「不能部署别人的东西」的唯一保证。",
    "--   1052 行注释：\"Must match placer:GetDeployAction(), with an additional",
    "--   distance = 1 parameter\" —— 必须与客户端的 GetDeployAction 完全一致，",
    "--     且带 distance=1（对应客户端 821 行）。",
  ],

  "PlayerController:OnRemoteControllerActionButtonDeploy#1+10": [
    "--   ★ 特例：拿着小船（boatbuilder 标签）且举着漂浮物时，部署动作是 DEPLOY_FLOATING。",
    "--     这个二选一必须与客户端 817 行的 placer:GetDeployAction() 结果一致。",
  ],

  "PlayerController:DoControllerAltActionButton#1": [
    "--★★ 【DoControllerAltActionButton】手柄 Y 键（CONTROLLER_ALTACTION）。",
    "--   与 X 键的结构差异：1075-1081 行 Y 键**优先取消**各种瞄准态，",
    "--     而 X 键会尝试执行它们。这符合直觉：X = 确认，Y = 取消/退出。",
  ],

  "PlayerController:DoControllerAltActionButton#1+3": [
    "--   ★ 取消优先级：建造放置 > 部署放置 > AOE 瞄准。",
    "--     1080 行注释掉的 ControllerTargetLock(false) 说明目标锁定取消被移除了。",
  ],

  "PlayerController:DoControllerAltActionButton#1+19": [
    "--   actionholdtime = GetTime()：记录长按起点。",
    "--     ★ 这是 2976-2980 行「按住 8 秒进入长按重复」的计时基准。",
  ],

  "PlayerController:DoControllerAltActionButton#1+21": [
    "--   ★ obj = act.target：Y 键先尝试「点地动作」，失败再退回「选中目标」。",
    "--     这与 X 键的顺序相反（X 先试目标再试点地），是手感上的刻意区分。",
  ],

  "PlayerController:DoControllerAltActionButton#1+26": [
    "--   APPLYCONSTRUCTION（应用到容器，如裂缝祭坛）的 UI 拦截。",
    "--   1099 行注释：\"e.g. rift offering has a local confirmation popup\"",
    "--     → 需要玩家在本地弹窗确认，所以**直接 return 不发 RPC**，",
    "--       等玩家在 UI 里确认后由 UI 自己发。这是本地 UI 插队的合法场景。",
  ],

  "PlayerController:DoControllerAltActionButton#1+39": [
    "--   ★ GetGroundUseSpecialAction(position, true) —— right=true 说明是右键语义。",
    "--     与 X 键的 false 区分：不同上下文的 GetPointSpecialActions。",
  ],

  "PlayerController:OnRemoteControllerActionButtonPoint#1+43": [
    "--★ 1031-1041 行：与服务端 974-984 行完全同构的执行段。",
    "--   ★★ 1037-1040 行被注释掉的三个 print 是**调试残留**：",
    "--     它们本该在「客户端上报的动作没算出来」时打印失败信息。",
    "--   ⚠ 值得注意的是：K 把失败打印**注释掉**了。",
    "--     ⇒ 后果：任何「意图编号不匹配」的失败都是**静默**的。",
    "--     这对一个协议适配层来说是危险的 —— 它让不匹配无法被观测。",
    "--     推理依据：全文件 10+ 处这样的注释掉的失败日志",
    "--       （980/1038/1229/1273/2338/4298/4961/5114）。",
    "--     推测原因：生产环境里客户端与服务端版本不一致时会刷屏。",
    "--   ⇒ 但这也意味着：**版本不一致的模组组合会静默丢动作**而非报错。",
    "--     这是模组作者排查「动作不生效」时最应该先看的线索 ——",
    "--       因为日志里什么都不会写。",
  ],

  "PlayerController:OnRemoteControllerActionButtonDeploy#1": [
    "--★ 【OnRemoteControllerActionButtonDeploy(invobject, position, rotation, isreleased)】",
    "--   ★ 与另外两个 ControllerActionButton* 变体最大的差异：",
    "--     ★ **没有 SetClientRequestedAction / ClearClientRequestedAction 包裹**。",
    "--     因为部署动作不需要 picker 查询 —— 1059 行直接构造 BufferedAction。",
    "--   ⇒⇒ 部署是三个变体里**唯一不做动作重算**的，",
    "--     安全性依赖 1051 行的归属校验（而非 code 匹配）。",
  ],

  "PlayerController:OnRemoteControllerActionButtonDeploy#1+4": [
    "--   ★ 1049 行与另外两个变体的写法差别：`not isreleased and 0 or nil`",
    "--     （一行完成「按下设 0 / 松开清 nil」），比另外两个变体的",
    "--     「先设 0 → 末尾再判断 isreleased 清 nil」更简洁，但三者行为一致。",
  ],

  "PlayerController:DoControllerAltActionButton#1": [
    "--★ 【DoControllerAltActionButton】手柄 Y 键（CONTROLLER_ALTACTION）。",
    "--   ★★ 注意 1069-1081 行：Y 键**优先取消**各种瞄准态，而 X 键会尝试执行它们。",
    "--     1075 行的 `elseif self:IsAOETargeting() then CancelAOETargeting(); return end`",
    "--     ⇒ 「X 确认 / Y 取消」的手感约定在代码层面被严格实现。",
  ],

  "PlayerController:DoControllerAltActionButton#1+3": [
    "--   ★ 1069-1081 行的取消优先级：建造放置 > 部署放置 > AOE 瞄准。",
    "--   ⚠ 1080 行注释掉的 ControllerTargetLock(false) 说明目标锁定取消被移除。",
    "--     ⇒ 目标锁定只能通过 CONTROL_TARGET_LOCK（711 行）切换。",
  ],

  "PlayerController:OnRemoteControllerAltActionButton#1": [
    "--★★ 【OnRemoteControllerAltActionButton】Y 键的服务端对端。",
    "--   ★ 与 X 键版（944 行）的唯一结构差异：1213-1221 行的回退链**反向**",
    "--     （先试 rmb，再试 lmb），且 1211-1212 行的注释自认是「保险性冗余」。",
    "--   ⚠ 1213-1221 行的放宽意味着：**客户端可以用 Y 键 RPC 触发 LMB 动作**。",
    "--     推理依据：1217-1220 行 `or (lmb ~= nil and lmb.action.code == actioncode ...)`。",
    "--     缓解：仍需服务端重算匹配 + 距离校验 + CanTarget。",
    "--     ⇒ 净效果是「Y 键可以执行 X 键的动作」，扩大了攻击面但幅度有限。",
  ],

  "PlayerController:OnRemoteControllerAltActionButton#1+12": [
    "--★★ 【OnRemoteControllerAltActionButton】的内部四段：",
    "--   ① 1194 行清战斗目标 / 1196 行设按键态",
    "--   ② 1198-1201 行「无参 RPC」自检（assert isreleased == nil）",
    "--   ③ 1203-1206 行重算：ClearControlMods → SetClientRequestedAction →",
    "--     GetSceneItemControllerAction → ClearClientRequestedAction",
    "--   ④ 1207-1221 行抬起处理 + 反向回退链",
    "--   ⚠ ③ 的顺序（ClearControlMods 在 Set 之前）说明：",
    "--     服务端每次都先清掉上次残留的修饰键，再按客户端上报的掩码重建。",
    "--     这是「状态重建」范式，比「增量修改」更抗乱序包。",
    "--   ⇒★ 与 4924 行的 ClearControlMods 在 ClearClientRequestedAction **之后**",
    "--     形成对比 —— 说明这里的顺序是刻意的（不能提前清修饰键）。",
    "--     推理依据：1203 行 ClearControlMods 在 1204 行 SetClientRequestedAction 之前；",
    "--       而 4920-4924 行的顺序是 ClearClientRequestedAction → ClearControlMods。",
  ],

  "PlayerController:OnRemoteControllerAltActionButton#1+19": [
    "--   ★★ 1211-1212 行 K 的注释最坦诚：",
    "--     \"Possible for rmb action to switch to lmb after autoequip /",
    "--      Probably not, but fairly inexpensive to be safe =)\"",
    "--     → 与 X 键版 963 行同款的对称放宽，且 K 自己承认「大概不会发生」。",
    "--   ⚠ 这是典型的「为假想场景放宽校验」——1217-1220 行让**左键动作也能用",
    "--     右键 RPC 触发**。",
    "--     ⚠⚠ 推理依据与影响：",
    "--       1217 行 `or (lmb ~= nil and lmb.action.code == actioncode and ...)`",
    "--       ⇒ 攻击面：客户端可用 Y 键 RPC 执行任意物品的 LMB 动作。",
    "--       缓解因素：仍需服务端重算匹配（1205 行）+ 距离校验 + CanTarget。",
    "--     ★ 这是一个**有意识的权衡**：用一点安全性换「不因自动装备而丢动作」。",
    "--       相比之下 963 行（X 键）的放宽是**必需**的（Y 键没有 LMB 通道）。",
    "--   ⇒ 所以 1217 行比 963 行更「宽松」，是本文件校验链条上最松的一处。",
  ],

  "PlayerController:OnRemoteControllerAltActionButton#1+31": [
    "--★ 1223-1233 行：force 时对齐预测位置 + 执行。",
    "--   ★ 与 X 键版（974-979 行）逐字同构，差异只有三个：",
    "--     ① 回退链方向相反（rmb 优先）",
    "--     ② 没有 mod_name 参数（Y 键不发模组名）",
    "--     ③ DoAction 无 spellbook 第二参数",
    "--   ⚠ 1229-1232 行又是被注释掉的失败日志（见 1037 行的分析）。",
  ],

  "PlayerController:OnRemoteControllerAltActionButtonPoint#1": [
    "--★ 【OnRemoteControllerAltActionButtonPoint】Y 键点地版的服务端对端。",
    "--   ★ 1245-1249 行：isspecial 时走 GetGroundUseSpecialAction(position, true)，",
    "--     否则走 GetGroundUseAction(position)。",
    "--     ⚠ 与 996-1014 行的 X 键版对比：X 键版多了船炮/高尔夫分支",
    "--       （1007/1009 行），Y 键版没有。",
    "--     ⇒ 这是**有意的**：船炮与高尔夫只有左键语义。",
  ],

  "PlayerController:OnRemoteControllerAltActionButtonPoint#1+18": [
    "--★ 1255-1265 行：与服务端 1020-1029 行同构的回退链（rmb 优先）。",
    "--   ⚠ 1267-1272 行的 force 处理与 1032-1035 行完全相同 ——",
    "--     说明这三个 Controller*OnRemote* 变体是**复制粘贴**出来的。",
    "--     复制粘贴的直接证据：三处的注释文字完全一致。",
    "--   ⚠ 疑似缺陷（复制粘贴的代价）：",
    "--     任何对这三点共有的 force/回退逻辑的修改都要改三处。",
    "--     推理依据：944/988/1192/1237 四个函数的开头守卫与结尾执行段逐字相同。",
  ],

  "PlayerController:OnRemoteControllerAltActionButtonPoint#1+36": [
    "--★ 1273-1278 行：Y 键点地版的收尾。与 1031-1041 行同构。",
  ],

  "PlayerController:DoControllerAttackButton#1": [
    "--★★ 【DoControllerAttackButton】手柄攻击键。★ 详见下一段的详细注释。",
    "--   ★★ 它与 DoControllerActionButton（794 行）的最大差异：",
    "--     ① 不构造 preview_cb 的三种变体，只有一条路径",
    "--     ② 多了「空气攻击」的五种例外判据（1334 行）",
    "--     ③ 多了 attack_buffer 的延迟机制（1356 行构造，2805 行消费）",
    "--   ⇒ 第三点是理解攻击的关键：**攻击被特殊对待**，",
    "--     因为它必须在状态图的 attack 状态下执行。",
  ],

  "PlayerController:DoControllerAltActionButton#1+43": [
    "--   ★★ 1109 行是本函数的核心分支：尝试进入 AOE 瞄准/蓄力。",
    "--     `if self:TryAOETargeting() or self:TryAOECharging(nil, true) then return end`",
    "--   ★★ 短路求值：先试瞄准，再试蓄力。任一成功就 return（不执行后续）。",
    "--     ⇒ 「按住 Y 进入蓄力」的实现；同时可触发时瞄准优先。",
    "--   ⚠ 疑似缺陷（互斥性依赖顺序）：若某物品同时支持 aoetargeting 与",
    "--     aoecharging（如未来的复合道具），永远只会进瞄准，无法蓄力。",
    "--     推理依据：TryAOETargeting（1609 行）返回 true 时，",
    "--       or 的短路使 TryAOECharging 根本不被调用。",
    "--     影响：现实中双组件物品罕见（法杖类只瞄准、弹弓类只蓄力）。",
  ],

  "PlayerController:DoControllerAltActionButton#1+46": [
    "--   骑乘中的交互：RUMMAGE（翻找坐骑的箱子）。",
    "--   1118 行：角色自己是法术书（韦布斯特/温蒂）→ USESPELLBOOK。",
    "--   1121 行：兜底 DISMOUNT（下坐骑）。",
  ],

  "PlayerController:DoControllerAltActionButton#1+70": [
    "--   准星可见时才 Ping（在实体上画涟漪）。这是纯表现，无网络影响。",
  ],

  "PlayerController:DoControllerAltActionButton#1+81": [
    "--   1147-1187：与 DoControllerActionButton 886-939 完全同构的三分支发送。",
    "--   ★ 二者的 RPC 差异只有一个：ControllerAltActionButton vs ControllerActionButton。",
  ],

  "act.non_preview_cb#5+2": [
    "--   ControllerAltActionButtonPoint 的参数里 isspecial 在 noforce 之后（位置不同！）。",
    "--   ⚠ 疑似缺陷（协议脆弱，非现行 bug）：isspecial 在这里排第 7 位，",
    "--     而 905 行的 ControllerActionButtonPoint 里它排第 10 位。",
    "--     已核实两个 RPC 的形参顺序本身就不同，故当前**是正确的**：",
    "--       networkclientrpc.lua:249 ControllerActionButtonPoint (action,x,z,isreleased,",
    "--           noforce,mod_name,platform,platform_relative,isspecial,spellbook,spell_id)",
    "--       networkclientrpc.lua:329 ControllerAltActionButtonPoint (action,x,z,isreleased,",
    "--           noforce,isspecial,mod_name,platform,platform_relative)",
    "--     ⇒ 但同一个「点地动作」的两条 RPC 用了不同的参数序，且两处调用点",
    "--       （1172 与 1184）都在手写全量参数，任何一侧改签名都会静默错位。",
    "--     建议：改用尾部的 table 或具名 table 传参。",
  ],

  "PlayerController:OnRemoteControllerAltActionButton#1": [
    "--【OnRemoteControllerAltActionButton】Y 键的服务端对端。",
    "--   1211-1212 行的注释很坦诚：",
    "--     \"Possible for rmb action to switch to lmb after autoequip /",
    "--      Probably not, but fairly inexpensive to be safe =)\"",
    "--     → 与 963 行同款的对称放宽，且 K 自己承认「大概不会发生，但加上很便宜」。",
    "--   ⚠ 这是典型的「为假想场景放宽校验」——1217-1220 行让**左键动作也能用右键 RPC 触发**。",
    "--     结合 1213 行的 rmb 优先，攻击面：客户端可用 Y 键 RPC 执行任意物品的 LMB 动作。",
    "--     缓解因素：仍需服务端重算匹配 + 距离校验。",
  ],
};

export const AFTER = {};