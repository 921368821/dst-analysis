// spec-playercontroller-p4.mjs —— 第 4 段：2100-2650 行
// 覆盖：GetActionButtonAction（空间键的 17 级动作优先级链）、DoActionButton 及其服务端对端、
//       查看 / 复活 / 指令轮盘、长按重复机制（ClearActionHold / RepeatHeldAction）

export const BEFORE = {
  "PlayerController:GetActionButtonAction#1+4": [
    "--============================================================",
    "-- 【第四段】2100-2650 行：空间键动作链 / 查看 / 复活 / 轮盘 / 长按重复",
    "--============================================================",
  ],

  "PlayerController:GetActionButtonAction#1": [
    "--★★★ 【GetActionButtonAction(force_target)】★★ **空间键（CONTROL_ACTION）的动作选择**。",
    "--   这是全文件最长的单函数（185 行），是一条**严格有序**的优先级链。",
    "--   链上的每一级都是「一个动作族」，顺序即优先级：",
    "--     ① 前置守卫（2102-2115）",
    "--     ② 手被占（2117-2127）",
    "--     ③ 手势忙（2129）",
    "--     ④ 幽灵态：Haunt（2132-2145）",
    "--     ⑤ 工具特定：BugNet / GestaltCage / MoonstormStatic（2147-2186）",
    "--     ⑥ CATCH（2188-2199）",
    "--     ⑦ UNPIN（2201-2210）",
    "--     ⑧ REVIVE_CORPSE（2212-2224）",
    "--     ⑨ 兜底：拾取/工具/扑灭（2226-2278）",
    "--   ⇒ ★ 为什么幽灵 Haunt 排在工具之前：幽灵拿不了东西，Haunt 是它唯一能做的事。",
    "--   ⇒ ★ 为什么 UNPIN 排在 REVIVE 之前：解除陷阱比复活尸体更紧急（自己可能被夹）。",
  ],

  "PlayerController:GetActionButtonAction#1+1": [
    "--   ★ 2097 行就取 IsEnabled 的两个返回值 —— 本函数在 HUD 打开时也可能被调用。",
  ],

  "PlayerController:GetActionButtonAction#1+3": [
    "--   ★★ 2102-2107 行的四重守卫，任一成立就**什么都不做**（返回 nil）：",
    "--     ① 客户端且 CONTROl_ACTION 还在冷却 → 防连点刷动作",
    "--     ② 既没 enabled 也没 hudblocking → 玩家被禁用（睡觉/死亡/倒地）",
    "--     ③ IsBusy() → 正在做别的动作",
    "--     ④ force_target 已失效（不可见 / INLIMBO / NOCLICK）",
    "--   ⚠ 2106 行注释：\"DECOR should never change, should be safe to skip that check\"",
    "--     → 与 2081 行的 TARGET_EXCLUDE_TAGS 呼应：DECOR 标签永久不变。",
  ],

  "PlayerController:GetActionButtonAction#1+13": [
    "--   ★★ actionbuttonoverride —— **模组插入点**。",
    "--   2110 行返回 (buffaction, usedefault)：",
    "--     · usedefault=false → 用返回的 buffaction",
    "--     · usedefault=true 且 buffaction==nil → **落穿**到下面的默认链（2114 行注释）",
    "--     · usedefault=true 且 buffaction~=nil → 用它",
    "--   ⚠ 疑似缺陷（隐式约定）：返回两个值但调用方要解构判断，",
    "--     任何模组返回单值（Lua 里 usedefault=nil 视为 false）都会走「用它」分支。",
    "--     推理依据：2111 行 `if not usedefault or buffaction ~= nil` ——",
    "--       usedefault 为 nil 时 not nil 为真，直接返回 buffaction。",
    "--   ⇒ 好消息：单值返回恰好是「替换默认动作」的语义，不会出错。",
  ],

  "PlayerController:GetActionButtonAction#1+21": [
    "--   ★★ 双手被占的两个判定，语义不同：",
    "--     IsFloaterHeld：举着漂浮物（气球等）→ 完全不能操作",
    "--     IsHeavyLifting：举重物 → **骑乘时仍可操作**（可以一边骑一边开箱）",
    "--   ⚠ 2123 行的 `if not (rider and rider:IsRiding()) then return end`：",
    "--     骑乘时跳过整个返回 ⇒ 允许在骑乘状态开箱。",
  ],

  "PlayerController:GetActionButtonAction#1+33": [
    "--   ★★ 「正在做/正在工作」时**整个动作链都不跑**。",
    "--   ⇒ 这是 2067 行 IsDoingOrWorking 的第一个消费点，也是「按空格没反应」的主因之一。",
  ],

  "PlayerController:GetActionButtonAction#1+34": [
    "--   ★ force_target_distsq：先算好「鼠标指定目标」的距离平方，后面每一级复用。",
    "--     避免在 18 个分支里重复调 GetDistanceSqToInst。",
  ],

  "PlayerController:GetActionButtonAction#1+36": [
    "--   ④ 幽灵态 → Haunt（附身）。",
    "--   2135 行半径：directwalking ? 3 : 6。与 1826 行的攻击半径同款双档设计。",
  ],

  "PlayerController:GetActionButtonAction#1+40": [
    "--   ★★ 2136 行的 CanEntitySeeTarget(self.inst, target)：",
    "--     传给 FindEntity 的是 nil validator，若没找到则 target 为 nil，",
    "--     而 CanEntitySeeTarget 对 nil 返回 false（simutil.lua:548）——",
    "--     ★ 所以这一行同时充当了「找到没有」的判据。",
    "--   ⇒ 这是本文件反复使用的惯用法：",
    "--     `if CanEntitySeeTarget(self.inst, FindEntity(...)) then return action end`",
    "--     2135/2152/2167/2179/2191/2203/2215 行七处全是这个形状。",
  ],

  "PlayerController:GetActionButtonAction#1+43": [
    "--   force_target 路径的距离判据：directwalking ? 9 : 36（= 3² / 6²）。",
    "--   ⚠ 数字硬编码：与 2135 行的 3/6 是「平方 vs 开方」的一对，",
    "--     但**没有共享常量**。改半径时极易只改一处。",
  ],

  "PlayerController:GetActionButtonAction#1+51": [
    "--   ★ 拿到手持工具。后续所有工具相关分支都用它。",
  ],

  "PlayerController:GetActionButtonAction#1+53": [
    "--   ★★ 2149 行的注释 \"bug catching (has to go before combat)\"：",
    "--     捕虫必须在战斗之前。因为「打着打着把虫子抓了」会丢失战斗目标。",
    "--   ⇒ 这是空间键链与攻击路径（1790 GetAttackTarget）**完全独立**的证据：",
    "--     两者不共享优先级，任何「先攻击再捕虫」的排序都需要新增跨链逻辑。",
  ],

  "PlayerController:GetActionButtonAction#1+56": [
    "--   ★ musttags = { \"_health\", \"NET_workable\" }：",
    "--     同时要求有生命值组件（有血条，即生物）与可被网捕（可捕捉的活物）。",
    "--     排除死人（尸体没有 _health？实际尸体也有，但 NET_workable 不会加在尸体上）。",
  ],

  "PlayerController:GetActionButtonAction#1+60": [
    "--   force_target 路径：距离 ≤ 25（= 5²，与 2152 行的半径 5 对应）。",
  ],

  "PlayerController:GetActionButtonAction#1+69": [
    "--   ★ 2164-2186：Gestalt（地牢 Boss 的吸入）与 MoonstormStatic（月亮风暴静电）。",
    "--     两段结构完全同构（半径 8 / 距离 ≤ 64 / 标签判据）。",
    "--   ⚠ 疑似缺陷（数值不一致）：8²=64 ✓，这一对是自洽的。",
    "--     但注意 2188 行的 CATCH 用半径 10 / 距离 ≤ 100，也自洽。",
    "--     ⇒ 真正的不一致在于：这些半径全部硬编码，与 TUNING 表无关联。",
  ],

  "PlayerController:GetActionButtonAction#1+92": [
    "--   ⑥ CATCH：抓（蜘蛛/兔子）。★ 2189 行 `inst:HasTag(\"cancatch\")`：",
    "--     是**玩家**身上的标签（韦德沃克斯/抓娃娃机角色），不是工具。",
    "--   ⇒ 这解释了为什么它排在工具分支之后 —— 它不使用任何道具。",
  ],

  "PlayerController:GetActionButtonAction#1+105": [
    "--   ⑦ UNPIN：从陷阱里把队友/自己拔出来（救蜘蛛人！）。",
    "--   ★ 2202 行 `if force_target == nil` —— 这一级**只支持无指定目标**，",
    "--     有鼠标目标时不会触发 UNPIN。这是刻意的：解陷阱要「对着陷阱按」。",
  ],

  "PlayerController:GetActionButtonAction#1+116": [
    "--   ⑧ REVIVE_CORPSE：★ 守卫 `self.inst.components.revivablecorpse ~= nil`，",
    "--     注释 \"only need to do this if i am also revivable\"。",
    "--     ⇒ 与 2061 行 GetPickupAction 里的同款守卫呼应：只有能复活的玩家才显示该动作。",
  ],

  "PlayerController:GetActionButtonAction#1+123": [
    "--   ⚠ 2219-2220 行的 Lua 多行条件书写方式：",
    "--       `elseif force_target_distsq <= 9`",
    "--           `and force_target:HasTag(\"corpse\")`",
    "--           `and ValidateCorpseReviver(...)` then",
    "--     这是合法的（表达式可跨行），但**极易被后人误读为三个独立 elseif**。",
    "--     文件中 2219-2221 与 2044-2045、2047-2048 都有同样的风格。",
  ],

  "PlayerController:GetActionButtonAction#1+130": [
    "--   ★★ ⑨ 兜底分支：自己找目标（2227 行 force_target == nil）。",
    "--   这是唯一一个「在空间里搜一遍所有候选」的分支（2262 行 TheSim:FindEntities），",
    "--     其他分支都用 FindEntity（单目标）。",
    "--   ⇒ 性能差异：2262 行返回**列表**，要遍历并对每个调 GetPickupAction（2267 行），",
    "--     而 FindEntity 返回第一个匹配的。后者是 simutil 的提前退出优化。",
  ],

  "PlayerController:GetActionButtonAction#1+132": [
    "--   ★★ pickup_tags 表：★ 这是「交互范围判定」的另一条路径 —— ",
    "--     它不是靠距离，而是靠**标签白名单**先把空间查询缩小到相关实体。",
    "--   ★ 2246 行的 client_forward_tag：允许「转发」实体参与（见 2264 行）。",
    "--     这是模组机制（如韦布斯特的「延伸的手」把动作转发给远处实体）。",
  ],

  "PlayerController:GetActionButtonAction#1+152": [
    "--   ★★ 动态扩充 pickup_tags：",
    "--     2249 行：手持矿镐 → 追加 LunarBuildup（月光堆积）",
    "--     2252-2256 行：按 TOOLACTIONS 把「我这把工具能作业的标签」全加进去",
    "--   ⇒ ★★ 推论：**工具的作业标签是运行时注入查询表的**，",
    "--     所以 2262 行的空间查询范围已经含「我工具能干的事」。",
    "--     这就是为什么「走过去自动提示砍树」不需要额外的距离逻辑。",
  ],

  "PlayerController:GetActionButtonAction#1+165": [
    "--   ★ 2262 行的搜索半径：directwalking ? 3 : 6，与前面七处一致。",
    "--   ⚠ 但 2262 行传的是 PICKUP_TARGET_EXCLUDE_TAGS（排除 catchable/mineactive/intense/",
    "--     paired + FX/NOCLICK/DECOR/INLIMBO/stealth），与 2135 行的 HAUNT_ 排除表不同。",
  ],

  "PlayerController:GetActionButtonAction#1+168": [
    "--   ★★ v = v.client_forward_target or v —— 模组转发机制。",
    "--     若实体带 client_forward_target，则用**被转发的那个实体**做后续判断。",
    "--     3464 行（手柄目标选择）有**完全相同**的一行。",
    "--     ⇒ 这两处必须同步改动，否则鼠标和手柄的转发行为会分叉。",
  ],

  "PlayerController:GetActionButtonAction#1+170": [
    "--   ★ 三重可见性守卫：不是自己 + 实体可见 + 视线可达。",
    "--   ⚠ 2266 行的 `v.entity:IsVisible()` 检查是**引擎层**的可见性",
    "--     （如在未探索洞穴里、隐藏的实体），CanEntitySeeTarget 是**光照**可见性。",
    "--     两者语义不同，缺一不可。",
  ],

  "PlayerController:GetActionButtonAction#1+173": [
    "--   ★★ `action ~= ACTIONS.SMOTHER and tool or nil`：扑灭时**不传工具**。",
    "--   ⚠ 疑似缺陷（Lua and/or 惯用法陷阱）：若 tool 为 false/nil 时会传 nil —— 安全；",
    "--     但若 action==nil（GetPickupAction 返回 nil）此处不会执行（2268 行已判）。",
    "--   ⚠ 真正的问题：`a and b or nil` 当 b 为 **false** 时会退化成 nil。",
    "--     tool 恒为实体或 nil，不会是 false，故当前安全。",
    "--     但这个写法在 2276 行重复了一次，两处都依赖 tool 不为 false。",
  ],

  "PlayerController:GetActionButtonAction#1+177": [
    "--   force_target 路径：距离 ≤ 9 或 36（3 或 6 的平方），与 2227 行对称。",
  ],

  "PlayerController:DoActionButton#1": [
    "--★★ 【DoActionButton】空间键 / 手柄 X 的客户端入口（632 行调它）。",
    "--   ★ 2283-2285 行注释掉的 AOE 守卫说明「AOE 期间禁空间键」曾被考虑后放弃。",
  ],

  "PlayerController:DoActionButton#1+4": [
    "--   ★ 分支1：没有建造放置器 → 走常规动作链。",
    "--     分支2（2308）：有 placer → 执行建造（鼠标模式与手柄模式共用）。",
  ],

  "PlayerController:DoActionButton#1+7": [
    "--   服务端：直接 PushAction（2290 行），不走 2319 行的「按钮按下」通知。",
    "--     ⇒ 因为服务端按的就是它自己的输入，不需要 RPC 往返。",
  ],

  "PlayerController:DoActionButton#1+18": [
    "--   ★★ 2300 行 `buffaction.action ~= ACTIONS.WALKTO`：",
    "--     WALKTO 不装 preview_cb ⇒ 「走过去」这个动作**不会**发 RPC。",
    "--   ⇒ 为什么？因为走过去已经由预测移动协议（PredictWalking）表达了，",
    "--     再发一次 ActionButton 是重复的。",
    "--   ⚠ 这是一个重要的性能优化点：玩家最常用的「点地面走」不会产生额外 RPC。",
  ],

  "buffaction.preview_cb#2+18": [
    "--   ★ 2319-2322 行是 870 行那个「无参 RPC」范式的第 8 次出现。",
    "--   ⚠ 2319 行的位置在 if/elseif 链**之外** —— 所以即使动作成功执行了，",
    "--     只要 remote_controls[CONTROL_ACTION] 已被 preview_cb 设为非 nil 就不会再发。",
    "--     若动作走了服务端分支（2289）返回，或走了 2305 的 PreviewAction，",
    "--     remote_controls 已被 preview_cb 填上 → 不重复发。",
    "--   ⇒ 这个「靠 remote_controls 的状态决定要不要发」是全文件的一致技巧。",
  ],

  "PlayerController:OnRemoteActionButton#1": [
    "--【OnRemoteActionButton(actioncode, target, isreleased, noforce, mod_name)】",
    "--   服务端对端。2330 行 `self:GetActionButtonAction(target)` ——",
    "--   ★★ 注意传的是 target 而非 nil：客户端指定了目标，服务端**必须在同目标上**重算。",
    "--     若客户端没给 target（nil），服务端会走 2227 行的空间搜索分支，",
    "--     可能选中另一个实体 → code 不匹配 → 丢弃。这正是防「隔空抓物」的机制。",
  ],

  "PlayerController:OnRemoteActionButton#1+7": [
    "--   ★★ 2332 行是**双条件匹配**：`buffaction.action.code == actioncode and",
    "--   buffaction.action.mod_name == mod_name`。",
    "--     两个都相等才执行。mod_name 用于模组动作的命名空间隔离。",
    "--   ⇒ 这就是「客户端上报意图编号，服务端重算校验」的完整实现。",
  ],

  "PlayerController:OnRemoteActionButton#1+8": [
    "--   2333-2336：服务端算出可 force → 把动作点设为客户端预测位置并标记 forced。",
    "--     ★ forced 会让 actions.lua 的 rangecheckfn 跳过距离检查。",
    "--     ★⚠ 安全注意：这是唯一一处服务端主动 force 的地方，",
    "--       安全性依赖 2332 行的 code 匹配（服务端确实认为玩家在范围内，只是",
    "--       服务器算的位置比客户端靠后）。",
  ],

  "PlayerController:RemoteActionButton#1": [
    "--【RemoteActionButton(action, isreleased)】发 RPC 的薄封装。",
    "--   ★ 2354 行 `local noforce = self.locomotor == nil and action ~= nil and ...`：",
    "--     只有「无 locomotor 的客户端」才上报 noforce —— 因为它没法等待 preview，",
    "--     服务端若等重定向会永远等不到。",
  ],

  "PlayerController:GetInspectButtonAction#1": [
    "--【GetInspectButtonAction(target)】★ 「查看/检视」动作的五重判据。",
    "--   2361  inspectable 标签：目标可检视",
    "--   2362  CanExamine：角色自定义（眼线等），可为 nil",
    "--   2363  ★ 状态图必须处于 moving/idle/channeling —— 「不能边被控制边看」",
    "--   2364  实体标签也必须是这三者之一（无 sg 时的回退）",
    "--   ⚠ 2363 与 2364 是**同一判据的两套实现**（sg 优先，标签兜底），",
    "--     与 2071-2078 行 IsDoingOrWorking 的双端结构完全同型。",
  ],

  "PlayerController:DoInspectButton#1": [
    "--【DoInspectButton】★ 2373 行的英文注释很关键：",
    "--   \"Closing the avatar popup takes priority\" —— 关闭头像弹窗优先于检视。",
    "--   ⇒ 当玩家的头像面板开着时，按检视键是「关面板」而不是「看目标」。",
  ],

  "PlayerController:DoInspectButton#1+12": [
    "--   ★ 2382-2388 行：目标带 playeravatardata → 弹出玩家资料框。",
    "--     2385 行 `client_obj.inst = buffaction.target`：",
    "--     ★ 客户端缓存的 data 对象被**就地塞入 inst 引用**——",
    "--       因为 classified 里同步过来的纯数据没有实体引用，需要补上。",
  ],

  "PlayerController:DoInspectButton#1+20": [
    "--   2390 行注释掉的 assert(self.inst == ThePlayer)：",
    "--     说明这条路径**可能**在非本机玩家上运行（模组调用），K 不确定。",
  ],

  "PlayerController:OnRemoteInspectButton#1": [
    "--【OnRemoteInspectButton(target)】服务端对端。比ActionButton 简单：",
    "--   不需要 code 校验，因为 LOOKAT 是固定动作，只需要校验目标有效性。",
  ],

  "PlayerController:GetResurrectButtonAction#1": [
    "--★★ 【GetResurrectButtonAction】★ **本文件唯一的「复活玩家」入口**。",
    "--   四重判据：",
    "--     ① 有 playerghost 标签（自己是幽灵）",
    "--     ② 状态图处于 moving/idle（不能被控制中）",
    "--     ③ 实体标签匹配（无 sg 时的回退）",
    "--     ④ ★★ components.attuner:HasAttunement(\"remoteresurrector\" 或",
    "--           \"gravestoneresurrector\") —— 必须站在复活雕像的有效范围内",
    "--   ⇒ 重生点选择、复活等待时间、复活后满血逻辑**全都不在本文件**。",
    "--     grep 核实：本文件无 respawnpoint / autorespawn / GetRespawnPoint 等符号。",
    "--   ★ 2430 行的 attuner 组件是「乐进的调谐器」——它维护一堆「调谐效果」标记，",
    "--     复活雕像与鼎石会写入这两个。参见 components/attuner.lua。",
  ],

  "PlayerController:DoResurrectButton#1": [
    "--【DoResurrectButton】标准三形态（master / 无 locomotor / 有 locomotor）。",
    "--   ★ 与 DoInspectButton 完全同构 —— 这是本文件的统一按钮范式。",
  ],

  "PlayerController:DoResurrectButton#1": [
    "--【DoResurrectButton】★ 「复活自己」按钮的执行。",
    "--   ★★ 结构与 DoInspectButton（2369 行）**逐字同构**的四分支：",
    "--     ① 2437 行 IsEnabled 守卫",
    "--     ② 2440-2442 行取动作（GetResurrectButtonAction，无参数）",
    "--     ③ 2443-2456 行 master / 无 locomotor / 有 locomotor 三分支",
    "--   ⚠ 2445 行 `self.locomotor == nil` 分支里的断言被注释掉了（2447 行），",
    "--     而 2390 行（DoInspectButton）也有同样的注释掉的 assert。",
    "--   ⇒ 说明这两处曾怀疑「本函数可能在非 ThePlayer 上被调用」，但没查清。",
  ],

  "PlayerController:OnRemoteResurrectButton#1": [
    "--★ 【OnRemoteResurrectButton】复活的服务端对端 —— ★ 本文件最短的 Remote 函数。",
    "--   ★★ 它**不需要任何参数校验**：因为 REMOTERESURRECT 是固定动作，",
    "--     唯一要校验的是「玩家在不在复活点范围内」，",
    "--     而那由 2430-2431 行的 attuner:HasAttunement 判定（attuner 由雕像维护）。",
    "--   ⇒★★ 这就是本文件「意图编号校验」的**最简形态**：",
    "--     动作唯一 → 无需 code 匹配 → 只需校验执行前提。",
    "--     对比 944 行的 35 行（动作由 picker 决定 → 必须匹配 code）。",
    "--   ⇒ 设计启示：动作越固定，协议校验越简单。",
  ],

  "PlayerController:RemoteResurrectButton#1": [
    "--★ 【RemoteResurrectButton】复活 RPC 的发送端 —— 一行。",
    "--   ⚠ 与其他 Remote* 函数不同，它**不设置 remote_controls 的按键状态**。",
    "--     推理依据：全函数只有 SendRPCToServer 一行。",
    "--   ⇒ 后果：复活是**瞬时**操作，不需要「按住不放」的语义。",
    "--     这与「复活台」的使用方式一致（站上去按一下）。",
    "--   ★ 这是本文件里最短的 RPC 发送端，也是最干净的一个。",
  ],

  "PlayerController:DoCharacterCommandWheelButton#1": [
    "--★ 【DoCharacterCommandWheelButton】指令轮盘（法术书）。三段递进的书本查找。",
  ],

  "PlayerController:DoCharacterCommandWheelButton#1+15": [
    "--   --special case for wendy, just hardcoded here for now",
    "--   ★★★ 温蒂特例：拿着的阿比盖尔之花 + 尚未召唤 → 不能用法术轮盘。",
    "--   ⚠ 疑似缺陷（硬编码）：角色特例被写在通用控制器里，而不是通过",
    "--     \"ghostfriend_notsummoned\" 标签的通用规则表达。",
    "--     推理依据：注释自认 \"just hardcoded here for now\"；",
    "--       若有第二个角色需要类似逻辑，会继续在此堆积。",
    "--   ⇒ 好的一面：2490 行的 prefab == 判断保证了只影响温蒂。",
  ],

  "PlayerController:DoCharacterCommandWheelButton#1+28": [
    "--   getlinkedspellbookfn：角色 prefab 提供「我关联的书」。",
    "--   2505 行的三重校验确保拿到的确实是合法法术书。",
  ],

  "PlayerController:DoCharacterCommandWheelButton#1+42": [
    "--   ★★ 2516-2520 行：同一次按键，按「轮盘是否已开着这个书」决定开或关。",
    "--     ACTIONS.CLOSESPELLBOOK vs ACTIONS.USESPELLBOOK —— 复用一个按键做 toggle。",
    "--   ⇒ 2557-2558 行的注释解释了为什么不发 CLOSESPELLBOOK 的 RPC：",
    "--     \"Don't need to send CLOSESPELLBOOK\"（关书纯客户端行为）。",
  ],

  "PlayerController:OnRemoteCharacterCommandWheelButton#1": [
    "--【OnRemoteCharacterCommandWheelButton(target)】服务端对端。",
    "--   ★ 2542 行区分「书在背包里」（传 invobject）vs「角色自己是书」（传 target）。",
    "--     这对应客户端 5522 行 `BufferedAction(self.inst, target, act, invobject)`。",
  ],

  "PlayerController:UsingMouse#1": [
    "--【UsingMouse】`not TheInput:ControllerAttached()` ——",
    "--   ★ 用它来在 OnLeftClick/OnRightClick（4979/4681 行）开头就 return，",
    "--     实现「手柄模式下鼠标键完全无效」。",
  ],

  "PlayerController:ClearActionHold#1": [
    "--★★ 【ClearActionHold】★ 清空长按重复的全部状态（4 个字段）。",
    "--   2573-2575 行：客户端还要发 RPC 让服务端同步清空。",
    "--   ⚠ 注意服务端收到 ClearActionHold 后会调 RepeatHeldAction 之外的这个函数",
    "--     （networkclientrpc.lua:1107 → playercontroller:ClearActionHold），",
    "--     服务端**不会**递归发 RPC（因为它自己的 ismastersim 为真）。",
  ],

  "PlayerController:ClearActionHold#1+11": [
    "--★ ACTIONHOLD_CONTROLS：能触发长按重复的五个控制。",
    "--   PRIMARY / SECONDARY / CONTROLLER_ALTACTION / 两个虚拟库存方向键。",
    "--   ⚠ 这里用 VIRTUAL_CONTROL_*（虚拟控件）而非 CONTROL_*（物理控件），",
    "--     因为长按的判定必须用「实际映射后的键」，与 680-706 行的方案分支一致。",
  ],

  "PlayerController:RepeatHeldAction#1": [
    "--★★★ 【RepeatHeldAction】★ 长按重复机制。每帧由 3012 行调用（若 actionholding）。",
    "--   ★ 结构：双端各有一份实现，客户端发 RPC 让服务端也执行。",
    "--   客户端分支（2589-2598）：",
    "--     · 有 actionrepeatfunction（库存格长按）→ 本地重发 + 0.8 秒冷却",
    "--     · 否则 → 发 RPC 让服务端走 lastheldaction 路径",
    "--   服务端分支（2599-2626）：",
    "--     · 有 lastheldaction（世界内动作长按，如长按挖掘）→ DoAction + 0.2 秒冷却",
    "--     · 退而求其次用 actionrepeatfunction + 0.8 秒冷却",
    "--     · 都没有 → ClearActionHold（长按结束）",
  ],

  "PlayerController:RepeatHeldAction#1+2": [
    "--   ★★ 2590 行的双重条件：`self.actionrepeatfunction and (lastheldactiontime == nil",
    "--   or GetTime() - lastheldactiontime < 1)`。",
    "--     「1 秒」是长按的**滑动窗口**：每次重发都刷新 lastheldactiontime，",
    "--     若两次重发间隔超过 1 秒则视为「不再是长按」，放弃。",
    "--   ⇒ 这是防「点一下松开一点再按住被误判成长按」的机制。",
  ],

  "PlayerController:RepeatHeldAction#1+12": [
    "--   服务端分支的第一道守卫：lastheldaction 必须**仍然有效**。",
    "--   2601 行 `:IsValid()` —— 复用 bufferedaction.lua 的 TestForStart 全套判据",
    "--     （doer/target/invobject 都还有效、目标仍在范围内）。",
    "--   ★ 这是「长按期间目标被打断就自动停」的实现。",
  ],

  "PlayerController:RepeatHeldAction#1+15": [
    "--   NOCLICK 目标（如装饰物）不重复 —— 避免对着装饰物狂点。",
  ],

  "PlayerController:RepeatHeldAction#1+18": [
    "--   ★★ 2609 行 `self.lastheldaction.options.no_predict_fastforward = true`：",
    "--     关闭客户端的动画快进。★ 但**永不清除**——",
    "--     options 表是 BufferedAction 实例自己的（bufferedaction.lua:14），",
    "--     所以污染只影响这一个实例，不影响 actions.lua 里的动作原型。",
    "--   ⚠ 疑似缺陷（无复位）：与 2621 行对比，后者在用完后把",
    "--     locomotor.no_predict_fastforward 置回 nil。这里没有对称操作。",
    "--     推理依据：2619-2621 行有 set/clear 成对；2609 行只有 set。",
    "--     后果轻微：该 lastheldaction 实例后续所有重发都不快进。",
    "--     而 lastheldaction 每次新动作都会被 4624 行覆盖，所以实际影响很小。",
  ],

  "PlayerController:RepeatHeldAction#1+24": [
    "--   elseif：只有 actionrepeatfunction（库存格）时走这条路。",
    "--   2616-2618 行 K 的注释说明了 2619 行为何用 locomotor 的标志：",
    "--     \"use temp override flag since we don't know where the bufferedaction",
    "--      may come from, but we know it will be pushed to locomotor\"",
    "--     ★★ 这是一个**已知的妥协**：他想在 BufferedAction 上设标志，",
    "--       但不知道它来自哪里，于是把标志设在 locomotor 上（因为确定会走 locomotor）。",
  ],

  "PlayerController:OnWallUpdate#1": [
    "--【OnWallUpdate(dt)】★ 墙钟更新。只有客户端本机玩家（handler ~= nil）才跑相机控制。",
    "--   ★ 为什么相机旋转要在 WallUpdate 而不是 OnUpdate：",
    "--     暂停时 OnUpdate 停止（游戏时间冻结），但相机仍需能转（玩家在暂停菜单里看地图）。",
    "--   ⇒ 这是「墙钟 vs 游戏钟」分离的一个实际用例。",
  ],

  "PlayerController:GetCombatRetarget#1": [
    "--【GetCombatRetarget / GetCombatTarget】★ 两个「当前目标」查询。",
    "--   GetCombatRetarget → sg.statemem.retarget（**重定向目标**，4603/4804 写入）",
    "--   GetCombatTarget   → sg.statemem.attacktarget（**实际攻击目标**，状态图写）",
    "--   ⇒ ★ 两者不同：retarget 是「玩家想打谁」，attacktarget 是「正在打谁」。",
    "--     连击攻击用 retarget 起手，普通攻击用 attacktarget 维持。",
  ],

  "PlayerController:GetCombatTarget#1": [
    "--   2644 行 `if self.inst.sg then` —— 无 sg 的实体返回 nil。",
    "--   ⚠ 与 2635 行的 elseif 分支不一致：那里无 sg 时回退到 replica.combat:GetTarget()，",
    "--     这里直接返回 nil。⇒ 两者在无 sg 时语义不同。",
    "--     推理依据：2638 行 `elseif self.inst.replica.combat then return ...:GetTarget()`。",
  ],
};

export const AFTER = {};