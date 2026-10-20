// spec-playercontroller-p5.mjs —— 第 5 段：2650-3200 行
// 覆盖：OnUpdate 前半（守卫、attack_buffer 派发、LMB/RMB 高亮、放置器、
//       terraformer、长按、移动意图分流、连击攻击）

export const BEFORE = {
  "PlayerController:OnUpdate#1": [
    "--============================================================",
    "-- 【第五段】2650-3200 行：OnUpdate —— ★ 每帧的心跳调度器",
    "--============================================================",
  ],

  "PlayerController:OnUpdate#1": [
    "--★★★ 【OnUpdate(dt)】★ 全文件最长函数（526 行），每帧执行一次。",
    "--   它是**唯一**的帧驱动入口，负责把「上一帧积累的各种请求」派发出去。",
    "--   可以分成七段：",
    "--     ① 2651-2656  hack 计时器",
    "--     ② 2658-2663  enabled 判定 + 长按中断",
    "--     ③ 2665-2688  拖拽中断 + 动作重启",
    "--     ④ 2691-2754  ★ 被禁用时的全面清理（本文件最重要的防御块）",
    "--     ⑤ 2756-2802  AOE 有效性 + ★ attack_buffer 派发",
    "--     ⑥ 2804-3020  正常态：目标高亮、放置器、terraformer、长按",
    "--     ⑦ 3022-3175  ★ 移动意图分流（hop / predict / drag / direct / boat）+ 连击攻击",
    "--   ⚠ 注意它是**双端**都跑的：客户端靠它驱动预测，服务端靠它消化远端玩家的 RPC。",
  ],

  "PlayerController:OnUpdate#1+1": [
    "--   _hack_ignore_held_controls 的倒计时（开地图的按键忽略窗口）。",
    "--   ★ 为什么在 OnUpdate 递减而不是设个任务：因为这个值可能被 mapscreen",
    "--     重新设置（1361 行），任务式的定时器会在重设后失准。",
  ],

  "PlayerController:OnUpdate#1+8": [
    "--   ★★ 2659 行 `self.predictionsent = false` 每帧清零 ——",
    "--     它是 3930 行 RemotePredictWalking 设置的一次性标志。",
    "--     ⚠ 这个字段已被标记 deprecated（106 行注释），此处仍在维护。",
  ],

  "PlayerController:OnUpdate#1+11": [
    "--   ★ 长按中断：actionholding 为真但**没有任何长按键被按住** → 清空。",
    "--     这是玩家「按住挖掘 → 松开方向键」的正常结束路径。",
    "--   ⚠ 2661 行用了 `isenabled and IsAnyActionHoldButtonHeld()` 的**双重否定**：",
    "--     只有「enabled 且有键按住」才算仍在长按。",
    "--     若 HUD 突然抢焦点（isenabled 转 false）→ 立即中断长按。合理。",
  ],

  "PlayerController:OnUpdate#1+15": [
    "--   ★★ 拖拽中断：draggingonground（鼠标左键按住拖地）且 CONTROL_PRIMARY 松开。",
    "--   2667 行的分支：有 locomotor → Stop 并**取出** bufferedaction；",
    "--     否则 → Clear（丢弃动作）。",
    "--   ★ 2670 vs 2672 的差别很关键：",
    "--     enabled → 保留 bufferedaction（2681-2687 会重启它）",
    "--     非 enabled（HUD 抢焦点）→ 直接 Clear，动作作废",
    "--   ⇒ 「点地面走过去，鼠标松开时恰好菜单弹出」会丢掉这个 walkto 动作。",
  ],

  "PlayerController:OnUpdate#1+29": [
    "--   --restart any buffered actions that may have been pushed at the same time",
    "--   as the user releasing draggingonground",
    "--   ★★ 这是本文件反复出现的三行模式（2681-2687、4405-4413、4531-4539）。",
    "--     「松开方向键/鼠标」与「按下动作键」发生在同一帧时，先 Stop 再重启，",
    "--     保证新动作不被「停止移动」的副作用清掉。",
    "--   ⇒ 4389-4414 与 4509-4540 是这套逻辑的两个副本，加上这里的第三处。",
    "--   ⚠ 疑似缺陷（代码重复）：三处逻辑相同但没有抽成函数，",
    "--     修改一处容易漏另两处。已核实三处的分支条件完全一致。",
  ],

  "PlayerController:OnUpdate#1+40": [
    "--★★★ 【2691-2754 被禁用时的清理块】★ 本文件最dense 的防御代码。",
    "--   触发条件：IsEnabled 的第一个返回值为 false（不管第二个）。",
    "--   ★ allow_loco = ishudblocking：**HUD 阻塞时不清移动状态**，",
    "--     因为在合成菜单里按方向键应该能继续走路（497 行的设计）。",
  ],

  "PlayerController:OnUpdate#1+43": [
    "--   ★ 完全禁用（不是 HUD 阻塞）时：",
    "--     ① 停 locomotor + Clear",
    "--     ② 清三个移动标志",
    "--     ③ 客户端额外发 RemoteStopWalking（2702-2704）",
    "--   ⇒ 「玩家被禁用时服务器还在跑」这个不一致被彻底消除。",
  ],

  "PlayerController:OnUpdate#1+58": [
    "--   ★ 只有 handler ~= nil（本机客户端）才做 UI 层清理。",
    "--     服务端没有 HUD，不需要取消放置/准星。",
  ],

  "PlayerController:OnUpdate#1+62": [
    "--   2712-2714 行：`if not ishudblocking and HUD ~= nil then HUD:CloseSpellWheel()`",
    "--   ⚠ 疑似缺陷（UI 行为不一致）：只在「非 hudblocking」时才关法术轮盘。",
    "--     但 2710/2711 行（CancelPlacement/CancelDeployPlacement）**无条件**执行。",
    "--   推理依据：对比 2710-2711 与 2712-2714 的条件差异。",
    "--     推测意图：法术轮盘开着时 ishudblocking 为真，此时不能强行关（否则玩家",
    "--       打开轮盘的同时就被关了）。但后果是「轮盘开着 + 玩家被禁用」时",
    "--       轮盘不会被清理。",
  ],

  "PlayerController:OnUpdate#1+79": [
    "--   ★ 清理高亮：self.highlight_guy 是「当前被高亮的实体」。",
    "--     ⚠ 注意这个字段**在构造函数里没有初始化**（grep 确认只在 2729/2848/2852 用）。",
    "--     依赖 Lua 的 nil 语义工作（2729 行的 ~= nil 守卫）。属可接受但脆弱的写法。",
  ],

  "PlayerController:OnUpdate#1+85": [
    "--   ★★ 服务端 vs 客户端的禁用清理：",
    "--     服务端 → ResetRemoteController（清 remote_vector + remote_controls）",
    "--     客户端 → RemoteStopAllControls（发 RPC）+ DoPredictWalking(dt)",
    "--   2740-2744 行的注释很关键：",
    "--     \"Other than HUD blocking, we would've been enabled otherwise\"",
    "--     → 客户端在「HUD 阻塞」状态下**仍然继续预测移动**（2742 行），",
    "--       否则玩家在菜单里走两步就会与服务器分叉。",
  ],

  "PlayerController:OnUpdate#1+98": [
    "--   ★ controller_attack_override 清理：手柄「按住扳机持续攻击」的临时覆盖。",
    "--   ★ 2749 行 `self.recent_bufferedaction.act = nil`：",
    "--     「刚放下方向键不取消动作」的护栏失效 —— 因为玩家状态变了。",
  ],

  "PlayerController:OnUpdate#1+106": [
    "--★ AOE 瞄准态的每帧有效性检查（2756-2765）。",
    "--   三种失效：",
    "--     ① 施法者实体失效或燃料耗尽（fueldepleted）→ 取消",
    "--     ② 施法者不再是自己拥有（被丢了/被抢了）→ 取消",
    "--   ★ 2757 行的 `self.reticule.inst:IsValid()`：reticule.inst 才是施法者，",
    "--     reticule 本身是准星组件的包装。",
  ],

  "PlayerController:OnUpdate#1+117": [
    "--   ★ usingmagiciantool 标签（魔术帽）：施法中禁用一切放置/瞄准态。",
    "--   ★ 2769-2771 行的分支：鼠标模式不取消 deploy（因为鼠标右键就是部署），",
    "--     手柄模式才取消。",
  ],

  "PlayerController:OnUpdate#1+125": [
    "--★★★ 【attack_buffer 派发】2776-2802 行。★ 本文件的「按键缓冲」实现。",
    "--   为什么需要缓冲：见 635 行的说明 —— OnControl 时刻状态图还没切到 attack，",
    "--     直接执行会误判「不能攻击」。所以推迟到 OnUpdate（此时上一帧的状态已生效）。",
    "--   ★ 四种取值：",
    "--     ① CONTROL_ATTACK（636 行存的常量）→ DoAttackButton",
    "--     ② CONTROL_CONTROLLER_ATTACK（673 行存的常量）→ DoControllerAttackButton",
    "--     ③ 普通 BufferedAction（1401/1407/1946/1952 行存的）",
    "--     ④ 带 _controller / _predictpos 标记的（1402/1403/1408/1412 行）",
  ],

  "PlayerController:OnUpdate#1+132": [
    "--   ★ _predictpos（1403/1412/1413 行设置）：动作点用客户端预测位置。",
    "--     2783 行 `self:GetRemotePredictPosition() or self.inst:GetPosition()`。",
    "--     ⇒ 与 975 行的 forced 逻辑同源：让服务器的动作点对齐客户端站位。",
  ],

  "PlayerController:OnUpdate#1+135": [
    "--   ★ _controller 标记：来自手柄的攻击（1402/1408 行设置）。",
    "--   2786-2787 行：目标为 nil 时若扳机仍按着，**保留** override 让后续帧持续攻击。",
    "--     ★ 这是「按住扳机 = 持续攻击」的实现：controller_attack_override 非 nil 时",
    "--       3045 行的 DoPredictWalking 会被跳过、4310 行的 DoDirectWalking 也会跳过。",
  ],

  "PlayerController:OnUpdate#1+140": [
    "--   普通（非手柄）攻击：2810 行的重复动作检查。",
    "--   2792-2798 行：若当前已有**相同动作 + 相同目标**的缓冲动作 → 丢弃。",
    "--     ★ 与 4587-4600 行 DoAction 里的重复检查重复，但少了 pos 的比较。",
    "--     ⇒ 轻微不一致：这里的检查不含位置，可能误丢弃「在两个相似位置挖同一棵树」。",
    "--     推理依据：对比 4589-4596 行（含 pos == 比较）与 2793-2795 行（不含）。",
  ],

  "PlayerController:OnUpdate#1+154": [
    "--   ★★ 2804 行 `if isenabled then` 之后是**纯表现层**（高亮、放置器、terraformer）。",
    "--     这些全是本地 UI，不发 RPC、不影响服务器。",
    "--   ⇒ 这解释了为什么这一整段（约 220 行）在服务端「本地玩家」路径下也会跑",
    "--     ——因为 handler ~= nil 的服务端玩家（房主的客户端）也需要高亮。",
  ],

  "PlayerController:OnUpdate#1+156": [
    "--   ★★ placer_cached 恢复（2806-2811）：菜单关闭后自动重建建造放置器。",
    "--   这是 1522-1529 行 CancelPlacement(cache) 的消费端。",
    "--   ⇒ ★ 完整闭环：开菜单 → OnUpdate 判定不 enabled → CancelPlacement(true)",
    "--     缓存蓝图 → 关菜单 → OnUpdate 判定 enabled → StartBuildPlacementMode(unpack(...))。",
  ],

  "PlayerController:OnUpdate#1+164": [
    "--   ★★ 2815 行的 controller_mode 分流：本节的所有逻辑在鼠标/手柄下**完全不同**。",
    "--     鼠标（2823-2844）：调 playeractionpicker:DoGetMouseActions 取 LMB/RMB",
    "--     手柄（2819-2822）：调 UpdateControllerTargets（3185 行）做方向键目标选择",
    "--   ⇒ ★ 这是「同一套游戏逻辑、两套输入方案」在代码层面的分水岭。",
  ],

  "PlayerController:OnUpdate#1+167": [
    "--   2817 行 `not self.inst:IsActionsVisible()`：玩家主动关掉了动作提示 → 不高亮。",
    "--   ★ 这是一个纯外观开关（可通过 UI 关闭），但**影响是否调 DoGetMouseActions**。",
  ],

  "PlayerController:OnUpdate#1+177": [
    "--   ★★ 2827 行 `self.inst.components.playeractionpicker:DoGetMouseActions()`：",
    "--     每帧重新计算「鼠标左/右键各对应什么动作」。",
    "--   ⚠ 性能注意：DoGetMouseActions（playeractionpicker.lua:498）内部会遍历",
    "--     大量候选动作并排序，**每帧每客户端一次**。",
    "--     若 profile 关闭了动作提示，2817 行会跳过它 —— 这也是性能优化。",
  ],

  "PlayerController:OnUpdate#1+179": [
    "--   --If an action has a target, highlight the target. / If an action has no",
    "--   target and no pos, then it should be an inventory action where doer is",
    "--   ourself and we are targeting ourself, so highlight ourself",
    "--   ★ 这段注释解释了 2833-2844 行那个三段 and/or 表达式：",
    "--     「无 target 无 pos ⇒ 是对自己用背包物品 ⇒ 高亮自己」。",
  ],

  "PlayerController:OnUpdate#1+197": [
    "--   ★ highlightforward：模组的「高亮转发」——实际高亮的可能是另一个实体",
    "--     （如长矛高亮的是它指向的敌人）。2264/3464 行的 client_forward_target 同源。",
  ],

  "PlayerController:OnUpdate#1+205": [
    "--   ★ 2856-2858 行：目标实体没有 highlight 组件 → 动态 AddComponent。",
    "--   ⚠ 这是**运行时给别人的实体加组件**。在 DST 里给远端玩家的实体加组件",
    "--     是允许的（组件不自动同步），所以只有本机看得到高亮 —— 正是想要的。",
  ],

  "PlayerController:OnUpdate#1+210": [
    "--   2861 行注释 \"--V2C: check tags on the original, not the forwarded\"：",
    "--     ★ 高亮的标签判定用**原始实体**（new_highlight）而非转发目标（new_highlight_guy）。",
    "--     因为「是否已烧焦」是原始实体的属性。",
  ],

  "PlayerController:OnUpdate#1+212": [
    "--   burnt（烧焦）目标用灰色高亮 (.5,.5,.5)，暗示「这个不能用了」。",
  ],

  "PlayerController:OnUpdate#1+222": [
    "--   ★ 2872 行：鼠标模式且准星不跟随鼠标 → 拆掉准星。",
    "--     典型：某些工具自带固定准星（如指南针），鼠标模式下不需要。",
  ],

  "PlayerController:OnUpdate#1+227": [
    "--   ★ 2878 行 `not builder:IsBuildBuffered(recipe.name)`：",
    "--     「建造已被服务器接受/正在排队」→ 取消本地预览。",
    "--     ⇒ 这是客户端感知服务器状态的第二条通道（第一条是 classified）。",
  ],

  "PlayerController:OnUpdate#1+232": [
    "--   ★ placer_item：手柄取光标物品，鼠标取「激活物品」（右手拿着的）。",
  ],

  "PlayerController:OnUpdate#1+234": [
    "--   ★ 部署放置器的显示条件（四重）：deploy_mode 且无建造 placer 且有可部署物品。",
  ],

  "PlayerController:OnUpdate#1+241": [
    "--   ★ 2891 行的自认 hack：\"hack that relies on the build name to match the",
    "--   linked skinname\" —— 用 AnimState:GetSkinBuild() 反查皮肤，",
    "--   依赖「建造名与皮肤名一致」的隐式约定。",
    "--   ⚠ 疑似缺陷（命名约定耦合）：若某皮肤名与 build 名不符，放置器皮肤会错。",
    "--     推理依据：注释自认是 hack；正确做法是 GetDeployPlacerSkin 之类的显式接口。",
  ],

  "placer.testfn#1": [
    "--   ★ placer.testfn：部署合法性判定。2908 行用逗号连接两个返回值",
    "--     （CanDeploy 的结果, 「是否可以放置到鼠标指向的实体上」）。",
    "--   ⚠ 疑似缺陷（逗号表达式易错）：Lua 的逗号构造多返回值，",
    "--     这里依赖 testfn 契约允许返回两个值。语义是「地形可放」或「鼠标指向物也可放」。",
    "--     可读性差，建议改成 local 变量。",
  ],

  "placer.testfn#1+7": [
    "--   placer:OnUpdate(0) 手动推一帧：「so that our position is accurate on the first frame」。",
    "--   ★ 原因：SpawnPrefab 出来的实体位置未初始化，直接给玩家用会闪一下。",
  ],

  "placer.testfn#1+14": [
    "--★ 【terraformer 段】2917-2974 行：右键「改变地形」类动作的放置器。",
    "--   例：铲子挖地、草种种植、挖洞。terraform_action 来自 rmb.action.tile_placer。",
  ],

  "placer.testfn#1+18": [
    "--   ★ 2921 行手柄用 GetGroundUseAction（点坐标），2936 行鼠标用 GetRightMouseAction（缓存）。",
    "--     ★★ 这是鼠标与手柄的第二处不对称：鼠标的动作是**上一帧缓存的**，",
    "--       手柄的动作是**本帧现算的**。鼠标路径省算力，手柄路径保证新鲜度。",
  ],

  "placer.testfn#1+20": [
    "--   2923 行 `rmb.action.tile_placer ~= nil` —— 判据是「动作带 tile_placer」。",
    "--   ★★ 所以「哪些动作会显示地形放置器」完全由 actions.lua 的 tile_placer 字段决定。",
    "--     参见 actions.lua 中 TERRAFORM / DIG / PLANT 等动作的 tile_placer = \"...\"。",
  ],

  "placer.testfn#1+23": [
    "--   --hide reticule if not a point action (ie. STOPUSINGMAGICTOOL)",
    "--   2926 行 hideactionreticuleoverride：rmb 没有 pos（不是点地动作）→ 藏准星。",
  ],

  "placer.testfn#1+26": [
    "--   --If reticule is from special action, hide it when other actions are available",
    "--   ★ 这是「准星所有权仲裁」的第二个例子（第一个在 222-224 行法术书特例）。",
    "--     准星属于「特殊点地动作」时，若出现了普通目标动作则隐藏准星。",
  ],

  "placer.testfn#1+30": [
    "--   2933 行 `hideactionreticuleoverride = rmb ~= nil or not HasGroundUseSpecialAction(true)`：",
    "--     ★ 有普通动作 **或** 没有特殊动作 → 都要藏。这两个条件是「或」而非「且」，",
    "--     读起来容易反直觉：只有「无普通动作 且 有特殊动作」才显示准星。",
  ],

  "placer.testfn#1+35": [
    "--   ★ 鼠标路径多一个 show_tile_placer_fn 钩子（手柄路径没有）。",
    "--     2938 行还重复调了一次 GetRightMouseAction()（作为参数传入）。",
    "--   ⚠ 疑似缺陷（低效）：`rmb.action.show_tile_placer_fn(self:GetRightMouseAction())`",
    "--     明明 rmb 已经是当前动作，却又调了一次 getter。虽然 getter 只是返回缓存，",
    "--     但这种写法暗示作者不确定 rmb 的有效性。",
  ],

  "placer.testfn#1+41": [
    "--   ★ 2944 行：只有在没有建造/部署放置器时才显示 terraformer 与准星。",
    "--     三者（placer / deployplacer / terraformer）互斥，避免视觉打架。",
  ],

  "placer.testfn#1+44": [
    "--   ★ SpawnPrefab(terraform_action.tile_placer) —— tile_placer 字段直接是预制体名。",
  ],

  "placer.testfn#1+55": [
    "--   ★ 2959 行 `hideactionreticuleoverride or self.reticule:ShouldHide()`：",
    "--     两个来源的隐藏需求合并。ShouldHide 由准星组件自己实现（如月亮风暴时隐藏）。",
  ],

  "placer.testfn#1+73": [
    "--★★ 【长按判定】2976-2980 行：按住动作键 8 秒（START_DRAG_TIME = 8*FRAMES，",
    "--   ⚠ 注意单位混用：START_DRAG_TIME = 8 * FRAMES 是**帧数**不是秒数！",
    "--     而 2977 行用 `GetTime() - self.actionholdtime > START_DRAG_TIME`",
    "--     比较的是**秒**。FRAMES = 1/30，所以 8*FRAMES = 0.267 秒。",
    "--   ⚠⚠ 疑似缺陷（单位错配）：常量名与赋值暗示「8 帧」，但被当作秒使用。",
    "--     推理依据：1 行 `local START_DRAG_TIME = 8 * FRAMES`；",
    "--       constants.lua 的 FRAMES 定义为 1/30；",
    "--       2977 与 2984 行都用 GetTime()（返回秒）与之比较。",
    "--     实际效果：长按触发阈值是 0.267 秒而非「8 帧」想表达的 0.267 秒——",
    "--       巧合的是两者数值相同，但**语义完全不符**：若 FRAMES 改成 1/60，",
    "--       长按阈值会减半。变量名与 FRAMES 乘法强烈暗示本意是「8 帧 ≈ 0.27 秒」，",
    "--       而 2977/2984 行想表达的是「按住一段时间」。这至少是一个命名/意图缺陷。",
  ],

  "placer.testfn#1+79": [
    "--   ★★ 鼠标拖拽判定：2984 行同样是 `now - self.startdragtime > START_DRAG_TIME`。",
    "--     4798 行在 WALKTO 且目标不是平台时设置 startdragtime = t。",
    "--   ⇒ 「按住左键不动超过 0.27 秒 → 进入拖拽行走模式」。",
  ],

  "placer.testfn#1+87": [
    "--   ★ 焦点丢失（GetFocusWidget 不等于 HUD）→ 强制退出拖拽与长按。",
    "--     ★ 2997 行的守卫 `CanLocomote()`：无预测能力时不能 Clear（会丢动作）。",
  ],

  "placer.testfn#1+102": [
    "--★★ 3005-3008 行：`elseif self.ismastersim and HasTag(\"nopredict\") and",
    "--   remote_vector.y >= 3` —— 服务端对「明确不能预测」的玩家的特殊处理。",
    "--   nopredict 标签由 SGwilson.lua 在某些状态（如莫比乌斯卷轴的混乱）添加。",
    "--   ★ 3007 行 ClearRemotePredictData() 而**不发 RPC**：",
    "--     因为这是服务端的决定，客户端没资格预测到。",
    "--   ⚠ 但 remote_vector.y 被置 0 后，客户端的下一个 PredictWalking RPC",
    "--     （3924 行的条件 `self.remote_vector.y ~= y and self.remote_vector.y ~= 0`）",
    "--     会因为「已经是 0」而**跳过发送**！",
    "--   ⇒ 后果：nopredict 玩家一旦触发这个分支，客户端的预测目标坐标就卡在",
    "--     旧值，且因 3924 行条件不成立而**再也不会更新**。",
    "--     这是一个真实的协议状态机缺陷。",
    "--     推理依据：3006 行 self.remote_vector.y = 0 与 3924 行的",
    "--       `(self.remote_vector.x ~= x or self.remote_vector.z ~= z or",
    "--        (self.remote_vector.y ~= y and self.remote_vector.y ~= 0))` ——",
    "--       最后那个 `self.remote_vector.y ~= 0` 显式豁免了 y==0 的情况。",
    "--       意图是「服务器说停了就别再发」，但 nopredict 是临时状态。",
  ],

  "placer.testfn#1+107": [
    "--   CooldownHeldAction(dt)：长按冷却递减（每帧）。",
  ],

  "placer.testfn#1+108": [
    "--   ★ actionholding 为真 → 每帧 RepeatHeldAction（长按重复）。",
  ],

  "placer.testfn#1+112": [
    "--   ★ controller_attack_override 的存活判定：",
    "--     「手柄攻击缓冲动作仍是 locomotor 的当前动作」且「扳机仍按着」。",
    "--   ⚠ 3016 行 `self.locomotor.bufferedaction` 没有 nil 检查 self.locomotor！",
    "--     推理依据：3016 行直接 `self.locomotor.bufferedaction == ...`。",
    "--     缓解：controller_attack_override 只在有 locomotor 的路径（2789 行 DoAction）设置，",
    "--       而 DoAction 在无 locomotor 时 4631 行提前 return，故 override 不被设置。",
    "--       但这是**间接**保证，非常脆弱。",
  ],

  "placer.testfn#1+119": [
    "--★ DoPredictHopping：客户端检测到本地 locomotor 开始跳跃 → 发 StartHop RPC。",
    "--   ★★ 3948 行的 `ThePlayer == self.inst and not self.ismastersim` ——",
    "--     只有本机预测客户端做这件事（远端玩家的跳跃由服务器自己在 3835 处理）。",
  ],

  "placer.testfn#1+121": [
    "--   ★ 3024 行：既没 enabled 也没 hudblocking → 到此为止。",
    "--   3025-3026 行的注释 \"don't think this should call; delete after confirming",
    "--   no side effects\" + 注释掉的 DoClientBusyOverrideLocomote：",
    "--     ⇒ 这是一个**被有意短路**的调用。3041 行的 isbusy 分支仍会调它，",
    "--       所以 3026 这处的注释表达的是「不 disabled 时不该调」。",
  ],

  "placer.testfn#1+127": [
    "--   --NOTE: isbusy is used further below as well",
    "--   3031 行算一次 isbusy，供 3040 和 3121 两处使用。",
  ],

  "placer.testfn#1+130": [
    "--★★ 3033-3037 行的 `#HACK for hopping prediction`：",
    "--   \"ignore server 'busy' if server still 'boathopping' but we're not anymore\"",
    "--   → 客户端已从「跳船中」状态出来，但服务器的 busy 标签还没清，",
    "--     于是强行把 isbusy 视为 false，让玩家能立即继续操作。",
    "--   ⚠ 这是一个**单向豁免**：只豁免 boathopping，不豁免其他 busy 原因。",
    "--     若同一个 busy 标签同时覆盖「跳船中」和「别的忙」，豁免会误放。",
  ],

  "placer.testfn#1+136": [
    "--   ★ allowdoubletapdiraction：是否允许「双击方向键」触发动作（如双击跳跃）。",
    "--     默认 false，只有在「正在走路」或「完全空闲」时才 true。",
    "--     ⇒ 设计意图：走路时不能双击跳（会冲突），停下才能。",
  ],

  "placer.testfn#1+137": [
    "--★★★ 【3040-3079 移动意图分流】★★ 本文件第二核心。",
    "--   五种互斥的移动状态，按优先级：",
    "--     ① isbusy → DoClientBusyOverrideLocomote + DoDirectStopWalking（3041-3044）",
    "--     ② 预测/拖拽行走中 → 保持（3045-3049）",
    "--     ③ 空闲 → DoDirectWalking（3062）或 DoBoatSteering（3076）",
    "--   ⚠ 注意②的写法：`if self:DoPredictWalking(dt) or self:DoDragWalking(dt) then`",
    "--     —— 短路求值：预测行走优先，拖拽行走只在预测未激活时才试。",
  ],

  "placer.testfn#1+138": [
    "--   ★★ busy 时仍然允许「方向微调」（DoClientBusyOverrideLocomote）。",
    "--     用途：密恐魔（Moo Moo）被牛车卡住时能用方向键挣脱。",
    "--     注释 3968-3971 行说明了这个设计：",
    "--     \"e.g. Moose tackle can be cancelled using directional input, but",
    "--      the state itself is still busy\"。",
  ],

  "placer.testfn#1+140": [
    "--   ★ ClearRemotePredictData(true) —— busy 时**强制**取消预测计时器。",
    "--     force_reset_timer=true 表示即使没收到 stop 通知也要取消。",
  ],

  "placer.testfn#1+142": [
    "--   ★★ 3048 行 `self.recent_bufferedaction.act = nil`：",
    "--     移动开始 → 松手护栏失效。这是对的：护栏本来只为「刚松手」设计。",
  ],

  "placer.testfn#1+148": [
    "--   ★★ 3051 行的 aimingcannon 判定：`boatcannonuser ~= nil and GetCannon() ~= nil`。",
    "--     正在瞄准船炮时**不移动**。3052 行连船舵（steeringboat）也算。",
    "--   ⚠ 3063 行的 `elseif aimingcannon then` 分支**是空的** —— 什么都不做。",
    "--     这不是 bug 而是一个显式的「冻结」分支，但可读性上应写成注释。",
  ],

  "placer.testfn#1+151": [
    "--   ★ 结束船舵瞄准时向船推送 endsteeringreticule 事件（带 player 参数）。",
    "--     ⇒ 船的预制体负责画/收瞄准辅助线。",
  ],

  "placer.testfn#1+159": [
    "--   ★ 空闲时执行 DoDirectWalking（手柄摇杆直走）。",
  ],

  "placer.testfn#1+172": [
    "--   ★ 3076 行 DoBoatSteering：手柄/键盘当舵用。",
    "--     ★★ 3062 与 3076 的选择条件是 3052 行的标签，",
    "--       所以「站在船上」会**自动**禁用行走改为操舵 —— 无需玩家按键切换。",
  ],

  "placer.testfn#1+178": [
    "--   --do automagic control repeats",
    "--★ 「按住键自动重复」机制（3081-3107）。",
    "--   ★ 3094 行的注释是本文件关于预测最精辟的一段说明：",
    "--     \"clear cooldowns if we actually did something on the server /",
    "--      otherwise just decrease / if the server is still 'idle', then it",
    "--      hasn't begun processing the action yet / when using movement prediction,",
    "--      the RPC is sent AFTER reaching the destination, / so we must also",
    "--      check that the server is not still 'moving'\"",
    "--   → 翻译：只有当服务器**也**空闲（idle）时，客户端的按键状态才可信；",
    "--     用预测移动时 RPC 是到达后才发的，所以服务器此刻可能还在「移动中」。",
    "--   ⇒ 3094 行传 dt 或传 nil 的选择 = 「清零」还是「倒数」，见 537 行的二义性。",
  ],

  "placer.testfn#1+197": [
    "--   ★★ 3098 行 isidle 的双端兜底：`sg:HasStateTag(\"idle\") or (isidle and",
    "--   HasTag(\"nopredict\"))` —— 无状态图预测的实体用标签兜底。",
  ],

  "placer.testfn#1+198": [
    "--   ★★ 3101-3106：空闲时若玩家仍按住动作键，**手动重放一次 OnControl**。",
    "--     这是「按住挖掘键持续挖掘」的第二种实现（第一种是 RepeatHeldAction）。",
    "--   ⇒ 为什么需要两种：3101 行是「玩家在动作间隙还按着键」，",
    "--     2588 行是「长按超过 0.27 秒后自动连发」。两者的时间尺度不同。",
    "--   ⚠ 3104 行的 `not self:IsDoingOrWorking()`：控制器 X 键只在完全空闲时重放，",
    "--     而 CONTROL_ACTION（3101 行）无条件重放。两者条件不对称。",
  ],

  "placer.testfn#1+207": [
    "--★★★ 【连击攻击的延迟触发】3110-3168 行。",
    "--   这是「连击」的第二半（前半在 1396/1941 的 chainattack_cb 设置）。",
    "--   3110 行守卫：服务端 + 非本机玩家 + **不是本地连击**（localchainattack）。",
    "--   ★ `self.inst.sg.mem.localchainattack` 来自 SGwilson.lua:1319，",
    "--     语义：本次攻击是 forced（玩家主动指定目标）则为 nil，",
    "--     非 forced（自动索敌）则为 true → 「本地连击」意味着是玩家自己安排的连击。",
  ],

  "placer.testfn#1+209": [
    "--   3112 行：正在施法（CASTAOE）时清掉连击回调 —— 施法期间不该被打断。",
  ],

  "placer.testfn#1+211": [
    "--   ★★ 3114 行又是那个 abouttoattack/attack 三元表达式（第三处）。",
    "--   3116-3118 行：取出回调、置空、执行。",
    "--   ★ 为什么要有 3114 行的守卫：回调可能在攻击状态**内部**被设入，",
    "--     若立刻执行会打断当前攻击动画。必须等状态离开攻击态才触发。",
  ],

  "placer.testfn#1+218": [
    "--★★ 3121-3168 行：客户端（以及服务端非 handler 路径）的「按住攻击持续攻击」。",
    "--   守卫三重：非 directwalking、非 isbusy、不在施法中。",
  ],

  "placer.testfn#1+221": [
    "--   ★★ 3127-3131 行：判定「能否开始新攻击」——",
    "--     没有攻击状态，或「正在打的人」与「想打的人」不同（= 可以重定向）。",
    "--   ⇒ 这就是「连击换目标」的实现：打 A 时按住扳机走到 B 旁边会自动转火。",
  ],

  "placer.testfn#1+230": [
    "--   --@V2C: #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK (see frontend.lua)",
    "--   ★★★ 一条重要的修复记录：UI 消费了左键点击，但**按下瞬间**的攻击被触发。",
    "--   3134 行的修复：`attack_control = (self.handler == nil or not IsPaused()) and ...`",
    "--     ⇒ 客户端在**暂停中**不触发左键自动攻击。",
    "--   原因：暂停菜单弹出时，玩家之前按住的左键仍被记为 pressed，",
    "--     导致一进暂停菜单就打人。参见报告 04 号文档 2744 行的分析。",
  ],

  "placer.testfn#1+232": [
    "--   ★★ 3135-3137 行：三键的自动攻击映射。",
    "--     `(IsControlPressed(A) and A) or (IsControlPressed(B) and B) or ... or nil`",
    "--   ⇒ 优先级：CONTROL_ATTACK > CONTROL_PRIMARY > CONTROL_CONTROLLER_ATTACK。",
    "--     这与 1893 行 DoAttackButton 的 control 选择**恰好相反**（那里 leftmouse 优先）。",
    "--   ⚠ 疑似缺陷（优先级不一致）：",
    "--     1893 行 `local control = isleftmouse and CONTROL_PRIMARY or CONTROL_ATTACK`",
    "--     3135 行 `IsControlPressed(CONTROL_ATTACK) and CONTROL_ATTACK or",
    "--                  IsControlPressed(CONTROL_PRIMARY) and CONTROL_PRIMARY`",
    "--     两者在「两个键同时按住」时会选到不同的 control，",
    "--     导致 remote_controls 里被置 0 的键不同 → 服务端状态不一致。",
    "--     推理依据：1893 行优先 PRIMARY，3135 行优先 ATTACK。",
  ],

  "placer.testfn#1+236": [
    "--   3139 行 `if attack_control ~= nil`：没有任何攻击键按住 → 跳过整段。",
  ],

  "placer.testfn#1+237": [
    "--★ 「链式攻击」（chain attack）的核心分支。",
    "--   3140 行：存在有效 retarget（玩家指定过目标）且它还活着可见。",
    "--   ⚠ 3144 行 `self:GetAttackTarget(false, retarget, retarget ~= currenttarget)`",
    "--     第二个参数 retarget 被当作 force_target 传入，返回值可能是 nil。",
    "--     3145-3147 行的 nil 检查是必要的。",
  ],

  "placer.testfn#1+240": [
    "--   ★★ 3143 行 `if self.handler == nil`：服务端直接 PushAction（不重定向）。",
    "--     服务端已经知道 target（RPC 带过来的），直接执行。",
  ],

  "placer.testfn#1+245": [
    "--   3148 行 `attack_control ~= CONTROL_CONTROLLER_ATTACK`：",
    "--     手柄攻击 → 3151 行的 DoControllerAttackButton(retarget)。",
    "--   ⚠ 3148 行的 elseif 在 3143 行的 `if self.handler == nil` 之内，",
    "--     所以 3151 行只在 handler ~= nil（本机客户端）时可达。",
  ],

  "placer.testfn#1+251": [
    "--★★ 3154 行 `elseif attack_control ~= CONTROL_PRIMARY and self.handler ~= nil`：",
    "--   「开始一次新攻击」的条件。排除 PRIMARY（左键点击交给 4680 行 OnLeftClick），",
    "--   也排除服务端。",
    "--   ⚠ 疑似缺陷（语义不对称）：",
    "--   ⇒ 与 3140-3152 行的「链式攻击」分支对照：那里 3149 行",
    "--     `self:DoAttackButton(retarget, attack_control == CONTROL_PRIMARY)`",
    "--     **允许** isleftmouse=true（3148 行只排除 CONTROLLER_ATTACK）。",
    "--     所以：按住左键 + 已有 retarget → 走 3149 行；",
    "--           按住左键 + 无 retarget → 被 3154 行拦住，什么都不做。",
    "--   ⚠ 也就是说「左键按住自动攻击」只在「已有一个攻击目标」时生效。",
    "--     结合 3133 行的 #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK 修复，",
    "--     这个不对称很可能是那次修复的无意副作用，而非有意设计。",
    "--     推理依据：3135-3137 行把 CONTROL_PRIMARY 列为候选，",
    "--       但 3154 行的条件让它在无 retarget 时永远走不到 DoAttackButton。",
    "--     缓解：3149 行可达时 isleftmouse 会正确为 true，故不会误伤。",
  ],

  "placer.testfn#1+252": [
    "--   「开始新攻击」还需满足 isidle（3158-3160 的双端兜底）。",
  ],

  "placer.testfn#1+260": [
    "--   ★ 3163 行 `self:OnControl(attack_control, true)`：",
    "--     **复用 OnControl** 手动重放一次按键，而不是直接调 DoAttackButton。",
    "--     ⇒ 保证客户端与服务端走完全相同的代码路径（3101-3106 行的同款技巧）。",
  ],

  "placer.testfn#1+267": [
    "--   ★ 手柄热插拔检测：TryRecacheController 为真 → 重发 continuefrompause。",
    "--   3171-3172 行注释解释：不能 PushScreen（会卡住），所以发事件。",
  ],
};

export const AFTER = {};