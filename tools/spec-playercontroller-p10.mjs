// spec-playercontroller-p10.mjs —— 第 10 段：5330-5941 行
// 覆盖：GetItemSelfAction / GetSceneItemControllerAction / GetGroundUseAction /
//       GetGroundUseSpecialAction / GetItemUseAction、库存格子与法术书的 Remote 端、
//       ★★ OnRemoteBufferedAction（动作前的位置对齐）、AI 交互意图广播、
//       ★ OnRemoteToggleMovementPrediction（客户端预测总开关）

export const BEFORE = {
  "PlayerController:GetItemSelfAction#1+1": [
    "--============================================================",
    "-- 【第十段】5330-5941 行：动作查询族尾部 / 库存格子 / ★ OnRemoteBufferedAction",
    "--   / AI 交互广播 / ★ 客户端预测总开关",
    "--============================================================",
  ],

  "PlayerController:GetItemSelfAction#1": [
    "--★ 【GetItemSelfAction(item)】★ 一个**已被掏空**的函数。",
    "--   5333-5335 行两行赋值语句**全部被注释掉**：",
    "--     --[[rmb]] ...GetInventoryActions(item, true)[1] or",
    "--     --[[lmb]] ...GetInventoryActions(item, false)[1]",
    "--   ⇒ act 恒为 nil → 5336 行的 and/or 链恒返回 nil。",
    "--   ⚠⚠ 疑似缺陷（残留的空壳函数）：",
    "--     函数永远返回 nil，但仍有 8 处外部调用（grep 确认）。",
    "--   推理依据：5333-5335 行的两个表达式都在 `--[[ ]]` 块注释里；",
    "--     5336 行 `act ~= nil and ...` 在 act 为 nil 时短路返回 nil。",
    "--   ⇒ 历史推测：K 曾在调试「背包物品的两个动作」，发现由",
    "--     GetItemUseAction（5484 行）统一处理更合适，于是注释掉但保留函数。",
    "--   ⚠ 保留而非删除说明**仍有 UI 在调用它**（widgets/controls.lua 等），",
    "--     删除会破坏 UI。属技术债。",
  ],

  "PlayerController:GetSceneItemControllerAction#1": [
    "--★★ 【GetSceneItemControllerAction(item)】手柄对「实体」的动作查询。",
    "--   ★ 与 GetItemUseAction（5484）不同：这里查的是**鼠标模式下鼠标指向时",
    "--     系统会给什么动作**（GetLeftClickActions/GetRightClickActions）。",
    "--   ★ 5339 行的守卫：`item == nil or self:IsAOETargeting()`。",
    "--     AOE 瞄准时不做实体查询（此时关心的是点地，不是实体）。",
  ],

  "PlayerController:GetSceneItemControllerAction#1+4": [
    "--   ★★ 5346-5357 行的过滤：**剔除三类动作**。",
    "--     LOOKAT（查看）—— 有专门的 CONTROLLER 键",
    "--     ATTACK（仅当目标有 combat 组件时）—— 有专门的攻击键",
    "--     WALKTO（走过去）—— 不该占用交互键",
    "--   ⚠ 注意 ATTACK 的条件是 `item.replica.combat ~= nil`：",
    "--     对没有战斗组件的实体（如箱子），ATTACK **不会**被剔除。",
    "--     ⇒ 这意味着对着箱子按 X 键可能得到 ATTACK 动作。",
    "--   ⚠ 疑似缺陷（条件不完整）：本意应该是「凡是 ATTACK 都剔除」，",
    "--     但条件写成了「ATTACK 且目标可战斗」。",
    "--     推理依据：5348 行 `(lmb.action == ACTIONS.ATTACK and item.replica.combat ~= nil)`。",
    "--     实际影响：ATTACK 的 fn 会检查目标合法性（actions.lua），",
    "--       所以对箱子执行 ATTACK 只会「打空气」，不会破坏箱子。",
  ],

  "PlayerController:GetSceneItemControllerAction#1+19": [
    "--   ★ 5358 行的去重：`rmb ~= nil and (lmb == nil or lmb.action ~= rmb.action)`。",
    "--     与 5252/5444 行同款。⚠ 三处重复，未抽函数。",
  ],

  "PlayerController:IsAxisAlignedPlacement#1": [
    "--【IsAxisAlignedPlacement】轴对齐放置（0/45/90 度）是否激活。",
    "--   ★ 消费点：588 行（优先级仲裁）、4071 行（菜单里切换对齐）、5040 行（部署）。",
  ],

  "PlayerController:GetPlacerPosition#1": [
    "--【GetPlacerPosition】三个放置器（建造/部署/terraformer）的位置查询。",
    "--   优先级：placer > deployplacer（terraformer 在 5383 行单独处理）。",
  ],

  "PlayerController:GetGroundUseAction#1": [
    "--★★★ 【GetGroundUseAction(position, spellbook)】★ **点地动作查询（最核心的查询）**。",
    "--   被 4 处调用：831（手柄X）、1004/1012/1248（服务端）、2921（手柄高亮）。",
    "--   ★ 它承担了「鼠标模式下右键点地面」和「手柄模式下 X/Y 键」的共同查询。",
    "--   结构：",
    "--     ① 5374-5378 容器 widget 优先 / 魔术帽特判",
    "--     ② 5380-5386 ★ 位置的四级回退（准星→terraformer→放置器→自己）",
    "--     ③ 5387-5403 可见性 + 可施法性判定",
    "--     ④ 5404-5405 ★ 取 LMB/RMB 点地动作",
    "--     ⑤ 5406-5443 TERRAFORM 特判与草皮移除",
  ],

  "PlayerController:GetGroundUseAction#1+1": [
    "--   ★ HasContainerWidgetAction()：当前有容器（箱子/冰箱）打开。",
    "--     ⇒ 打开容器时地面动作全部失效（避免「开着箱子还能挖地」）。",
    "--     参见 playeractionpicker.lua:38。",
  ],

  "PlayerController:GetGroundUseAction#1+3": [
    "--   ★ usingmagiciantool：魔术帽使用中 → 只提供「停止使用」这一个动作。",
    "--   5377 行 `return nil, BufferedAction(...)` —— ★★ 注意返回**两个值**：",
    "--     LMB 为 nil（地面无动作），RMB 是 STOPUSINGMAGICTOOL。",
    "--     ⇒ 符合「右键取消」的语义。",
  ],

  "PlayerController:GetGroundUseAction#1+7": [
    "--★★ 5380 行 islocal = (position == nil) —— **「本地查询」标志**。",
    "--   ★★ 它决定三个行为：",
    "--     ① 5393 行：islocal 时才从手持物读 aoetargeting 参数",
    "--     ② 5388 行：islocal 时才尝试自动填充 spellbook",
    "--     ③ 5405 行：islocal 时才可能取 RMB（远端查询只取 LMB）",
    "--   ⚠ 5388 行 `local isaoetargeting = islocal and self:IsAOETargeting()` ——",
    "--     AOE 瞄准只在本地查询时生效。服务端重算时 islocal 为 false，",
    "--     ⇒ ★ 这解释了服务端为何能用 GetGroundUseAction 重算出 CASTAOE：",
    "--       客户端会通过 spellbook 参数显式传入（988-1013 行），绕开 islocal 依赖。",
  ],

  "PlayerController:GetGroundUseAction#1+8": [
    "--★★ 5381-5385 行：目标位置的**四级回退**。",
    "--     ① 准星位置（但排除「准星属于玩家自己」的情况 —— 5382 行的",
    "--        `self.reticule.inst ~= self.inst` 判断）",
    "--     ② terraformer（右键地形放置器）的位置",
    "--     ③ 建造/部署放置器的位置",
    "--     ④ 玩家自己的位置（脚下）",
    "--   ⇒ ★ 5382 行的排除很重要：玩家自己的 reticule（默认准星）跟随鼠标，",
    "--     不能用它当「点地位置」，否则移动鼠标会改变脚下动作。",
  ],

  "PlayerController:GetGroundUseAction#1+14": [
    "--★ 可见性检查（CanEntitySeePoint，simutil.lua:536）：含光照判定。",
    "--   ⇒ 黑暗中的点不能交互（除非玩家有夜视）。",
  ],

  "PlayerController:GetGroundUseAction#1+22": [
    "--★★ 5395-5403 行：AoE 施法参数从**手持物组件**读出。",
    "--   alwaysvalid：无视地形（法术可空中施放）",
    "--   allowwater：可对水施放",
    "--   deployradius：投放半径（如藤壶的粘液）",
    "--   5402 行额外合并 `item:HasTag(\"allow_action_on_impassable\")`（标签兜底）。",
    "--   ★ 5403 行 `self.map:CanCastAtPoint(...)` 是最终的地图合法性判定。",
  ],

  "PlayerController:GetGroundUseAction#1+31": [
    "--★ 5404 行 `not isaoetargeting and ...GetPointActions(position, item, false, nil)[1] or nil`：",
    "--   ★★ AOE 瞄准时**不取 LMB**（瞄准中只按右键施法）。",
    "--     → 与 4732 行（鼠标 AOE 用 GetRightMouseAction）一致。",
  ],

  "PlayerController:GetGroundUseAction#1+32": [
    "--★★ 5405 行的条件是本函数最复杂的一行：",
    "--   `(not islocal or isaoetargeting or item.components.aoetargeting == nil",
    "--    or not item.components.aoetargeting:IsEnabled()) and ...GetPointActions(..., true, ...)`",
    "--   展开：「不是本地查询」 OR 「在 AOE 瞄准」 OR 「手持物没有 aoetargeting」",
    "--     OR 「aoetargeting 未启用」→ 取 RMB 点地动作。",
    "--   ⇒★ 语义：**本地查询且手持物支持 AOE 瞄准时，不取普通 RMB**",
    "--     （因为 RMB 已被施法占用）。",
    "--   ⚠ 四个条件的 or 冗长但语义清晰，优于 5136 行的隐式优先级。",
  ],

  "PlayerController:GetGroundUseAction#1+33": [
    "--★ 5407-5411 行的动作改写：",
    "--   DROP → 丢弃动作不能作为「点地 LMB」（否则右键丢弃会变成左键动作）",
    "--   TERRAFORM → 距离改成 2（挖地需要够到格子中心）",
    "--   ★★ 这些改写直接修改了 playeractionpicker 返回的动作实例。",
    "--   ⚠ BufferedAction 是每次新建的（picker 里新建），所以修改安全。",
  ],

  "PlayerController:GetGroundUseAction#1+43": [
    "--★★ 【5416-5443 草皮移除特判】★ 与 3409-3428 行是**完整复制**。",
    "--   注释文字与 3410-3411 行几乎逐字相同。",
    "--   ⚠ 疑似缺陷（代码重复）：两处必须同步修改。",
    "--     推理依据：对比 3420-3421 与 5420-5421 行的注释：",
    "--       \"Special case for ACTIONS.TERRAFORM_REMOVE via placed turf visuals\"",
    "--       \"We will use the player's origin to find things with the tag\"",
    "--     仅缩进不同。",
    "--   ★ 5435/5440 行的 `distance = 0`：★ 因为目标是自己脚下的草皮视觉体，",
    "--     原点就在玩家身上，距离判据必须放宽为 0。",
  ],

  "PlayerController:GetGroundUseAction#1+71": [
    "--   ★ 与 5358/5252 行同款的去重（第三次出现）。",
  ],

  "PlayerController:GetGroundUseSpecialAction#1": [
    "--★★ 【GetGroundUseSpecialAction(position, right)】「特殊」点地动作。",
    "--   与 GetGroundUseAction 的区别：",
    "--     · 不查手持物（5459 行只查地形与 picker 的 special 动作）",
    "--     · 用 GetPointSpecialActions（225 行）而非 GetPointActions",
    "--   ★ 5451 行注释掉的 `local islocal = position == nil` ——",
    "--     表明**曾经**也有本地/远端之分，但被移除了。",
    "--   ⚠ 5458-5460 行的三连判（可见 && 可通行 && 有动作）：",
    "--     ★ IsPassableAtPoint 比 CanCastAtPoint 严格 —— 特殊动作不能对水/墙。",
  ],

  "PlayerController:HasGroundUseSpecialAction#1": [
    "--【HasGroundUseSpecialAction(right)】★ 存在性查询（不算具体动作）。",
    "--   ★ 5465 行传了**第四个参数 true**（usereticulepos），与 5460 行不同。",
    "--     用途不同：这里只问「有没有」，所以用准星位置参数以匹配实际查询。",
    "--   消费点：2933 行（决定要不要藏准星）。",
  ],

  "ValidateItemUseAction#1": [
    "--★ 【ValidateItemUseAction】物品使用动作的过滤器（局部函数，不导出）。",
    "--   5470 行：`active_item:HasTag(act.action.id..\"_tool\")` 为真则拒绝。",
    "--   ★★ 这是「装备的物品不能被自己用」的判据（防「手持斧头用斧头砍树」）。",
    "--     标签约定：动作 CHOP 的 tool 标签是 chop_tool。",
    "--   ⚠ 5470 行 `active_item.replica.equippable == nil or ...` 的短路顺序：",
    "--     若没有 equippable 组件则放行。",
  ],

  "ValidateItemUseAction#1+3": [
    "--   ★ 5471 行：STORE/BUNDLESTORE 只在「目标自己不是物主」时允许。",
    "--     ⇒ 不能把东西存进自己已经拿着的容器（会形成循环嵌套）。",
  ],

  "ValidateItemUseAction#1+4": [
    "--   COMBINESTACK（合并堆叠）与 ATTACK 一律拒绝 —— 它们是右键专属动作，",
    "--   不应出现在 GetUseItemActions 的结果里。",
  ],

  "AllowMountedStoreActionFilter#1": [
    "--★ AllowMountedStoreActionFilter：骑乘时的动作过滤器（模组 hack）。",
    "--   5477-5479 行的注释：\"--#V2C #Hack to allow controllers to Store in",
    "--   Magician's Top Hat while mounted. This is for DPAD actions, so they don't",
    "--   have to open inventory UI to access the unfiltered UI actions.\"",
    "--   → 翻译：允许骑乘时用手柄方向键把东西存进魔术帽。",
    "--   ★ 5491 行的注释 \"See rider_replica MountedActionFilter; match priority\" ——",
    "--     ★★ 明确要求优先级与 rider 副本里的过滤器**匹配**。",
    "--     这是跨组件的隐式契约，改一处必须改另一处。",
    "--     推理依据：注释自认；ACTION_FILTER_PRIORITIES.mounted（5510 行使用）。",
  ],

  "PlayerController:GetItemUseAction#1": [
    "--★★ 【GetItemUseAction(active_item, target)】★ 手柄「对某物使用手持物」的查询。",
    "--   5490-5504 行的 target 解析四级：",
    "--     ① 5491 行：显式 target 或 GetControllerTarget()（手柄选中目标）",
    "--     ② 5493-5504 行：魔术帽使用中 → 从打开的容器里找可写的",
    "--     ③ 5506-5514 行：骑乘特例（允许存进魔术帽）",
    "--   ★ 5499 行 `k.replica.container == nil or not IsReadOnlyContainer()`：",
    "--     ★★ 同时允许「还没有 container 组件」的容器（客户端未同步时）。",
    "--     这是客户端预测必需的宽松。",
  ],

  "PlayerController:GetItemUseAction#1+32": [
    "--★★ 5516-5519 行：**右键优先，再取左键**。",
    "--   注释用 `--[[rmb]]` / `--[[lmb]]` 标注了两次调用的语义（该注释风格全文件通用）。",
    "--   ⇒ 与 5414 行的顺序一致（先 rmb 后 lmb）。",
  ],

  "PlayerController:GetItemUseAction#1+37": [
    "--   5521-5523 行：及时弹出过滤器（try/finally 模式）。",
    "--   ⚠ 若 5517-5518 行的 picker 抛错，过滤器会泄漏在栈上。",
    "--     实际不会抛（纯数据查询），属理论风险。",
  ],

  "PlayerController:GetItemUseAction#1+41": [
    "--★★ 5525-5535 行：没有目标时退回「对自己用」（背包格动作）。",
    "--   5531 行 `lmb.action ~= rmb.action and lmb.action ~= ACTIONS.LOOKAT`：",
    "--     ★ 排除 LOOKAT（查看物品）—— 因为它已在 GetItemSelfAction（被掏空）里处理过。",
    "--   ⚠ 但 GetItemSelfAction 现在返回 nil ⇒ LOOKAT 的物品查看路径可能已失效。",
    "--     推理依据：5531 行的注释说 \"GetItemSelfAction would've used the rmb one\"，",
    "--       说明这段是为配合 GetItemSelfAction 而写的；后者被掏空后，",
    "--       LOOKAT 在这条路径上不再被产出（但 5361/4811 行的 LOOKAT 路径仍可用）。",
  ],

  "PlayerController:GetItemUseAction#1+53": [
    "--★ 5538-5540 行：存进「口袋维度」（无限 dumping bag 变体）→ 标记为 instant。",
    "--   ★ `act.options.instant = true` 让 locomotor 不缓冲，立即执行。",
    "--     因为「存进口袋」不该要求玩家走过去。",
    "--   ⚠ options 是 BufferedAction 实例的字段（bufferedaction.lua:14），安全。",
  ],

  "PlayerController:GetItemUseAction#1+57": [
    "--   magiciantool + magician 标签（魔术师角色）→ 唯一动作 USEMAGICTOOL。",
    "--   ★ 兜底分支：当没有任何物品使用动作时的最后手段。",
  ],

  "PlayerController:GetItemUseAction#1+63": [
    "--★ 5547-5559 行：**可部署物品**在无其他动作时的兜底。",
    "--   5549-5550 行的注释解释了 rmb/lmb 的强制：",
    "--     \"When not mounted, use self actions blocked by controller R.Dpad",
    "--      'TOGGLE_DEPLOY_MODE' / So force it onto L.Dpad instead here\"",
    "--     → 未骑乘时 R.Dpad 是「切换部署模式」键，所以这里用 L.Dpad。",
    "--   ★ 5552-5553 行的 `act[1] ~= nil and act[1].action ~= TOGGLE_DEPLOY_MODE and act[1] or act[2]`：",
    "--     ★★ 经典的 and/or 惯用法：取「第一个非 TOGGLE_DEPLOY_MODE 的动作」，",
    "--       若第一项就是 TOGGLE 则取第二项。",
    "--     ⚠ 疑似缺陷（Lua 真值陷阱）：若 act[1] 为 nil，`nil ~= nil` 为 false → 取 act[2]。正确。",
    "--       若 act[1] 存在但其 action 是 TOGGLE → false → 取 act[2]。正确。",
    "--       若 act[1] 存在且不是 TOGGLE → act[1]。正确。",
    "--     ⇒ 逻辑正确，但极难读。建议改成显式 if。",
  ],

  "PlayerController:GetItemUseAction#1": [
    "--★★ 【GetItemUseAction(active_item, target)】★ 手柄「对某物使用手持物」的查询。",
    "--   5490-5504 行的 target 解析四级：",
    "--     ① 5491 行：显式 target 或 GetControllerTarget()（手柄选中目标）",
    "--     ② 5493-5504 行：魔术帽使用中 → 从打开的容器里找可写的",
    "--     ③ 5506-5514 行：骑乘特例（允许存进魔术帽）",
  ],

  "PlayerController:GetItemUseAction#1+6": [
    "--   ★ 5489 行 `target ~= nil and target:HasTag(\"pocketdimension_container\")`：",
    "--     ★★★ 这行在 5491 行的 `target = target or GetControllerTarget()` **之前**——",
    "--     即「显式传入的 target 是口袋维度容器」才算 allow_mounted_store，",
    "--     而手柄自动选中的目标不算。",
    "--     ⚠ 疑似缺陷（判断时机）：",
    "--       若玩家手柄选中的目标恰好是口袋维度容器（5491 行填入的 target），",
    "--       5489 行已经算过 allow_mounted_store = false，之后不再补算。",
    "--     推理依据：5489 行用入参 target，5491 行才用 GetControllerTarget() 覆盖。",
    "--     影响：手柄模式下骑乘时无法把东西存进自动选中的口袋容器。",
    "--     推测：这是「先算标志再解析目标」的顺序疏漏，而非有意。",
  ],

  "PlayerController:GetItemUseAction#1+9": [
    "--   ★ 5493-5504 行：魔术帽使用中且无目标 → 从打开的容器里找一个可写的。",
    "--   ★ 5499 行 `k.replica.container == nil or not IsReadOnlyContainer()`：",
    "--     ★★ 同时允许「还没有 container 组件」的容器（客户端未同步时）。",
    "--     这是客户端预测必需的宽松 —— 但也意味着在组件同步完成前",
    "--     客户端会显示「可存储」而服务端拒绝。",
    "--   ⚠ 5495 行 `break` —— 取第一个匹配即止（unordered pairs 遍历，",
    "--     所以若开多个魔术帽，选中哪个不确定）。",
  ],

  "PlayerController:GetItemUseAction#1+22": [
    "--★★ 5506-5514 行：骑乘特例的动作过滤器安装。",
    "--   ★ 5508 行必须 rider:IsRiding()，否则 5512 行撤销 allow_mounted_store。",
    "--     ⇒ 非骑乘时这个标签白名单不生效，保持「骑乘时不显示容器动作」的常规规则。",
    "--   ⚠ 5510 行注释 \"See rider_replica MountedActionFilter; match priority\" ——",
    "--     ★★ 显式要求与 rider 副本的过滤器优先级**匹配**。",
    "--     推理依据：这是跨组件隐式契约；若 rider_replica 改了优先级而这里没改，",
    "--       过滤顺序会错乱（一个动作可能被过滤两次或一次都不过滤）。",
    "--     ⇒ 参见 components/rider_replica.lua 的 MountedActionFilter 与",
    "--       ACTION_FILTER_PRIORITIES.mounted。",
  ],

  "PlayerController:RemoteUseItemFromInvTile#1": [
    "--【RemoteUseItemFromInvTile】库存格子「使用」的客户端发起端。",
  ],

  "PlayerController:RemoteControllerUseItemOnItemFromInvTile#1": [
    "--★★ 【RemoteControllerUseItemOnItemFromInvTile】★ 「在物品 A 上用物品 B」。",
    "--   ★★ 5586 行用 `if not self.ismastersim then` 而其他函数用 `== nil` 分支——",
    "--     语义等价（都是「非服务端才执行」），但风格不一致。",
    "--   ⚠ 疑似缺陷（代码重复）：四个 Remote*InvTile 函数",
    "--     （5562 / 5585 / 5607 / 5629）的结构**逐字重复**，",
    "--     只有 RPC 名与参数不同，且都未抽成通用函数。",
    "--     推理依据：四段代码的分支结构、注释位置、busy 检查位置完全一致。",
    "--     ⇒ 后果：任何对这类 RPC 的策略修改（如鉴权收紧）都要改 4 处，",
    "--       漏改一处就是一个漏洞。这是本文件最明显的可维护性问题。",
    "--   ★ 5595 行的 RPC 参数多了 active_item（双物品），故不能完全参数化。",
  ],

  "PlayerController:RemoteControllerUseItemOnSelfFromInvTile#1": [
    "--【RemoteControllerUseItemOnSelfFromInvTile】★ 「对自己用」。",
    "--   ★ 与 5585 行版相比只是少一个 active_item 参数。",
    "--   ★ 5617 行的注释 \"--V2C: Block inv tile actions that have pre_action_cb;",
    "--   otherwise send RPC anyway for better responsiveness\" ——",
    "--     这是四个函数**共用同一条 V2C 权衡**（见 5569 行的详细分析）：",
    "--       有状态变化的动作在 busy 时被吞掉，普通动作为响应速度可绕过。",
    "--   ⚠ 5613 行的 `if self:IsBusy() then return end` 会让玩家的按键**完全无响应**。",
    "--     玩家视角：手柄在手上之物时突然失灵。属可接受但需文档化的取舍。",
  ],

  "PlayerController:RemoteControllerUseItemOnSceneFromInvTile#1": [
    "--【RemoteControllerUseItemOnSceneFromInvTile】★ 「对世界用」。",
    "--   ★ 5639 行的 RPC 带 buffaction.target —— 这是四个里唯一带目标的。",
    "--     ⇒ 「对世界用」需要告诉服务端用在哪（服务端会重算，见 5730 行模式）。",
    "--   ⚠ 5629-5649 行与 5607-5627 行逐字相同（除 RPC 名与 target 参数），",
    "--     是「四份复制」的第四份。",
  ],

  "PlayerController:RemoteInspectItemFromInvTile#1": [
    "--★ 【RemoteInspectItemFromInvTile】查看库存物品。",
    "--   ★★ 5567-5572 行：**只在有 pre_action_cb 且不 busy 时**才调它，否则直接发 RPC。",
    "--   注释 \"--V2C: Block inv tile actions that have pre_action_cb; otherwise send",
    "--   RPC anyway for better responsiveness.\" ——",
    "--   ★★ 一条明确的**体验权衡**：有状态变化的动作（如吃食物会切动画）",
    "--     不能在 busy 时跳过；而普通动作为了「响应快」可以绕过 busy 直接发。",
    "--   ⚠ 5569 行 busy 时直接 return 而不发 RPC —— 玩家的按键被完全吞掉。",
    "--     这是有意的（避免状态错乱），但玩家会以为「手柄失灵」。",
  ],

  "PlayerController:RemoteUseItemFromInvTile#1+12": [
    "--   5574-5580 行：有 locomotor 且能预测且不 busy → 走 preview。",
    "--   ★ 与 5563 行的 `self.locomotor == nil` 分支构成标准二选一。",
  ],

  "PlayerController:RemoteControllerUseItemOnItemFromInvTile#1": [
    "--★★ 【RemoteControllerUseItemOnItemFromInvTile】★ 「在物品 A 上用物品 B」。",
    "--   5586 行的 `if not self.ismastersim then` —— 注意其他函数用 `== nil`，",
    "--     这里用 `not ... then`，语义等价但风格不一致。",
    "--   ⚠ 四个 Remote*InvTile 函数（5562/5585/5607/5629）的结构**逐字重复**，",
    "--     只有 RPC 名与参数不同。未抽成通用函数。",
    "--     推理依据：5562-5583 / 5585-5605 / 5607-5627 / 5629-5649 四段结构一致。",
  ],

  "PlayerController:RemoteInspectItemFromInvTile#1": [
    "--【RemoteInspectItemFromInvTile】查看库存物品。",
    "--   ★ 5655-5657 行：即使是无 locomotor 客户端也要调 LOOKAT 的 pre_action_cb。",
    "--     与其他 invTile 函数的「busy 时 return」不同，这里**没有** busy 检查。",
    "--   ⚠ 疑似缺陷（守卫缺失）：查看是无害的，busy 时也允许。属有意为之。",
  ],

  "PlayerController:RemoteDropItemFromInvTile#1": [
    "--★ 5682 行 `buffaction.options.instant = self.inst.sg:HasStateTag(\"overridelocomote\")`：",
    "--   ★★ 丢弃物品的 instant 性**取决于状态图**！",
    "--     在 overridelocomote 态（如温泉里）丢东西是瞬发的（不用走过去）。",
    "--   ⚠ 直接读 sg:HasStateTag，无 sg 检查 —— 但玩家必有 sg。",
  ],

  "PlayerController:RemoteCastSpellBookFromInv#1": [
    "--【RemoteCastSpellBookFromInv】从库存释放法术。",
    "--   5690-5691 行的 target/invobject 二选一（与 5585 行同款）。",
    "--   5692 行 spell_action 可覆盖（不同法术书的默认动作不同）。",
  ],

  "PlayerController:RemoteMakeRecipeFromMenu#1": [
    "--【RemoteMakeRecipeFromMenu / RemoteMakeRecipeAtPoint】建造菜单的两条路径。",
    "--   ★ 5711 行用 `PREFAB_SKINS_IDS[recipe.product][skin]`（菜单路径查 product），",
    "--     5731 行用 `PREFAB_SKINS_IDS[recipe.name][skin]`（放置路径查 name）。",
    "--   ⚠⚠ 疑似缺陷（索引键不一致）：",
    "--     5711 行查 recipe.product，5731 行查 recipe.name。",
    "--     若某配方的 product 与 name 不同（常见：product 是物品名，name 是配方名），",
    "--     两处会查出不同的皮肤索引 → 皮肤错乱或 nil 索引崩溃。",
    "--   推理依据：对比 5711 行与 5731 行的 `[recipe.product]` vs `[recipe.name]`。",
    "--     5735/5741 行的 BufferedAction 都用 recipe.name 作为第 6 参数，",
    "--     说明 name 才是配方的权威键 ⇒ 5711 行更可疑。",
  ],

  "PlayerController:RemoteMakeRecipeAtPoint#1+8": [
    "--★ 5737 行 MakeRecipeAtPoint 需要平台相对坐标（建造也要处理平台）。",
  ],

  "PlayerController:RemoteMakeRecipeAtPoint#1+11": [
    "--★ 5740 行 `self.locomotor:Stop()` —— 建造前先停移动（其余函数没有）。",
    "--   ⇒ 建造是「站定不动」的动作，与挖矿不同（挖矿可以边走边挖）。",
  ],

  "act.preview_cb#10": [
    "--   ★ 5743 行的 preview_cb **重新读** act.pos.local_pt —— 而不是用 5737 行的 pt。",
    "--     因为 preview_cb 触发时 act.pos 可能已被平台移动改写。",
    "--   ⚠ 这与 5738 行（非 preview 路径用闭包捕获的 pt）不一致。",
    "--   ⇒ 两条路径的平台处理精度不同。属实现细节的差异。",
  ],

  "PlayerController:RemoteBufferedAction#1": [
    "--★★★ 【RemoteBufferedAction(buffaction)】★★ 由 locomotor 在**预览回调时**调用。",
    "--   5751 行守卫：classified.iscontrollerenabled（服务端的输入启用位）。",
    "--   ★★ 5752-5758 行：在发动作 RPC 之前，**先把最后的预测行走发出去**。",
    "--     \"If we're starting a remote buffered action, prevent the last movement",
    "--      prediction vector from cancelling us out right away\"（5801 行同款注释）",
    "--   ⇒★ 原因：客户端站在某处准备动作，但服务器还以为它在走向别处。",
    "--     若不先同步位置，服务器会先执行「到达预测点」再执行动作，",
    "--     造成明显的延迟。",
    "--   ⇒ 这就是「动作与移动的交接协议」：动作开始前，先把位置对齐。",
  ],

  "PlayerController:RemoteBufferedAction#1+3": [
    "--★ 5753 行 `--V2C: not GetPredictionPosition()` —— 刻意用真实位置。",
    "--   5754-5755 行的注释解释：",
    "--     \"Physics:Stop() fixed to stop at last sim position; no need to correct",
    "--      local position anymore / self.inst.Transform:SetPosition(x, 0, z)",
    "--      --V2C: correcting local position, no need to account for platform\"",
    "--   → 翻译：引擎的 Physics:Stop() 已改为停在「最后模拟位置」，",
    "--     所以客户端不再需要自己修正 Transform 位置。",
    "--     而被注释掉的那行修正**没有考虑平台**（若在船上会错）。",
    "--   ⇒★★ 这又是一条 V2C 补丁记录（42 处 V2C 中的一处），",
    "--     说明「客户端位置修正」这件事被引擎层接管过一次。",
  ],

  "PlayerController:OnRemoteBufferedAction#1": [
    "--★★★ 【OnRemoteBufferedAction】★★ 服务端侧的「动作前位置对齐」。",
    "--   ⚠ 与所有其他 OnRemote* 不同，本函数**没有** ismastersim/IsEnabled/handler 三重守卫，",
    "--     只有 5766 行的 `if self.ismastersim then`。",
    "--   ⚠ 且它**不是 RPC**（grep 确认 networkclientrpc.lua 中无对应项）。",
    "--     它由 1671 行 TryAOECharging 调用（且只在 force_rotation 时）。",
    "--   ⇒★ 双重身份：",
    "--     ① 蓄力开始时的对齐（1671 行）",
    "--     ② 也被 locomotor 在「远端缓冲动作开始」时调用（见 5750 行的对端注释）",
  ],

  "PlayerController:OnRemoteBufferedAction#1+2": [
    "--   --If we're starting a remote buffered action, prevent the last movement",
    "--   prediction vector from cancelling us out right away",
    "--   ★★ 5770 行注释解释了本函数的核心意图：**别让移动把动作顶掉**。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+6": [
    "--★ 5771 行 `pt.y < 5 and not self:IsBusy()`：",
    "--   ★★ 排除 y>=5（正在执行动作）与 y==6（跳跃）。",
    "--     5772 行注释 \"excludes self:IsLocalOrRemoteHopping() as well, ie. y ~= 6\" ——",
    "--     明确指出 y=6 也被这条判断排除（因为 6 > 5）。",
    "--   ⚠ 这再次印证 B8：连「判断是否跳跃」都要靠 y 的**大小关系**，",
    "--     而不是独立的布尔字段。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+8": [
    "--   5773 行：取服务器当前世界位置（忽略 y）。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+11": [
    "--   5776 行 `if dx ~= 0 or dz ~= 0`：完全重合则什么都不做（省开销）。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+12": [
    "--★★★ 【5777-5785：should_snap 的两级条件】★ remote_authority 的特权。",
    "--   ★ 5778-5779 行：remote_authority → **无条件**瞬移。",
    "--     ★ 不做任何距离/合法性检查。这是「信任」的极致体现（也见文件头警告）。",
    "--   ★ 5781-5784 行：非信任玩家 → 两重限制：",
    "--     ① 距离 ≤ min(单帧跑距, PREDICT_STOP_ERROR_DISTANCE_SQ)",
    "--        ★ `GetRunSpeed() * FRAMES` = 一帧能跑多远。",
    "--          即「只允许在**一帧之内**的距离差内对齐」。",
    "--          ⇒ 语义：这不是「拉玩家过去」，而是「消除亚帧级误差」。",
    "--     ② 目标点可通行（IsPassableAtPoint）—— 不许把玩家推进墙里。",
    "--   ⇒★★ 对比 4039-4043 行（过冲瞬移）：那里**没有**这两重限制。",
    "--     同为 remote_authority 特权，一处宽松一处严格，不一致。",
    "--   ⚠ 推理依据：4039 行只有 remote_authority + 方向差 >= 90；",
    "--     5777 行有 should_snap 变量与额外两项检查。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+22": [
    "--★ 5787-5798：snap 的三步（转向 → 强制进 idle → 停止 → SetPosition）。",
    "--   5789 行的 canrotate 检查：不能转朝向时跳过第一步。",
    "--   5793 行的 `sg:HandleEvent(\"locomote\", {dir=dir, force_idle_state=true})`：",
    "--     ★ force_idle_state 与 4049 行的注释同款 ——",
    "--       「这次微小移动可能是为了取消某个动作，所以必须进 idle」。",
    "--   5796 行 locomotor:Stop() 在 SetPosition **之前** ——",
    "--     顺序重要：先停（停止路径计算），再挪位置（否则路径会重新计算）。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+36": [
    "--★★★ 5801 行 `self.remote_vector.y = 5` —— **B8 编码表的最后一个成员**。",
    "--   ★ 语义：「客户端要开始执行动作，预测目标冻结在此处」。",
    "--   ★★ 它的三个消费者：",
    "--     4014 行 `if pt.y == 5 and (...)` → 清移动标志，开始执行动作",
    "--     4030 行 `if pt.y < 5 then ClearBufferedAction()` → 5 号**不清**动作",
    "--     5771 行 `pt.y < 5` → 5 号**不做**位置对齐（避免动作前又挪一下）",
    "--   ⇒★★ 完整语义链：「y=5 是一个**事务开始标记**」——",
    "--     移动到动作的交接点，所有「清理移动」与「清理动作」的逻辑都绕开它。",
    "--   ⚠ 但 3809-3816 行的 isstop 分支处理不了 y=5（因为 3789 行只会写 3/4）。",
    "--     5801 行是**唯一**写 5 的地方，也从不把它重置为 0 ——",
    "--     重置靠 3800-3817 行（客户端发 isstop）或 3698 行（ResetRemoteController）。",
    "--     ⚠ 若客户端在 y=5 状态下断线，服务器的 remote_vector.y 永远停在 5。",
    "--     ⇒ 后果：DoPredictWalking:4008 的 pt 恒非 nil → 服务器永远执行预测逻辑。",
    "--     缓解：4014 行进入该分支后会清三个移动标志并 return，行为退化到「静止」。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+37": [
    "--   5802-5806 行：没有预测位置（pt 为 nil）且 y 已是 0 → 清手势标志。",
    "--   ★ 这是「干净退出」的收尾。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+45": [
    "--★★ CREATURE_INTERACTIONS：★ 「玩家正在对生物做什么」的广播清单。",
    "--   注释：\"This is just for friendly interactions where some brains may have",
    "--   logic to stop and wait for you.\"",
    "--   → 翻译：仅用于「友好交互」—— 某些 AI 会在玩家靠近时停下等待。",
    "--   ★★ 全部 9 个动作都要求 target 带 locomotor 标签（5885 行）——",
    "--     「能被喂食的生物」必须能走动（不能是墙上的画像）。",
    "--   ⇒ 消费方：eater:363 / trader:58 / mermbrain:49 / container_transform:22 ...",
    "--   ⚠ WEATHER 类的 GIVE/GIVEALLTOPLAYER 不在清单里 —— 那些是「给予」不是「交互」。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+61": [
    "--★ WX78_INTERACTIONS：温蒂附身身体需要跟随主人的动作。",
    "--   ★ 包含 ATTACK / CHOP / MINE / DIG / TILL / FEEDPLAYER ...",
    "--   注释 \"Special logic for WX so possessed bodies can follow in sync\" ——",
    "--   ⇒ 机制：温蒂附身后，她的「身体」AI 读取自己实体的 remoteinteraction，",
    "--     从而跟着主人做同样的事（同步攻击/同步建造）。",
    "--   ⚠ 守卫条件是 `self.inst.wx78_classified ~= nil`（5886 行）——",
    "--     即「我是一个被别人附着的身体」，而非「我是温蒂」。方向相反，容易搞混。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+78": [
    "--★ WX78_INTERACTION_POSITIONS：需要**位置**的三个划船动作。",
    "--   ★ 为什么只有这三个：ROW / ROW_FAIL / ROW_CONTROLLER ——",
    "--     划船需要「在哪条船上划」的位置信息，其余动作只需 target 即可。",
  ],

  "PlayerController:OnRemoteBufferedAction#1+85": [
    "--   --InteractionTarget naming scheme from when this was initially just used",
    "--   for action + target only",
    "--   ★★ 一条历史注记：这套协议最初只有「动作+目标」两个字段，",
    "--     后来加了 position（第三个参数），且**追加在末尾**（5862 行）。",
    "--   ⇒ 与 1932 行的 isreleased 注释同款约定：**只能在末尾追加参数**。",
  ],

  "PlayerController:OnRemoteInteractionTarget#1": [
    "--★ 【OnRemoteInteractionTarget】服务端接收 AI 交互意图。",
    "--   ⚠⚠ 疑似缺陷（缺少有效性校验）：本函数**没有任何守卫**",
    "--     （无 ismastersim / IsEnabled / handler == nil），"
    +    "--     且直接 ACTIONS_BY_ACTION_CODE[actioncode] 查表。",
    "--   ⇒ RPC 层（networkclientrpc.lua:1273-1294）只校验参数类型与",
    "--     IsPointInRange（64 格），**不校验 action 是否合法**。",
    "--   后果：客户端可上报任意 actioncode（服务端查表失败得 nil，",
    "--     则 remoteinteractionaction = nil，等于「清空交互意图」）。",
    "--   ⚠ 这**不会**让玩家做动作（GetRemoteInteraction 只是给 AI 读的只读接口），",
    "--     所以攻击面有限：最多让 NPC 误以为玩家在喂它/骑它。",
    "--   推理依据：5851-5855 行的函数体只有三行赋值，无任何条件判断；",
    "--     对比 5857 行客户端版有 `if 三者都变了才发` 的去重。",
  ],

  "PlayerController:RemoteInteractionTarget#1": [
    "--★ RemoteInteractionTarget：客户端发送端（三元组变化才发）。",
    "--   ★ 5862 行 `position ~= nil and position.x or nil`：",
    "--     Vector3 无法直接网络传输（不是引擎支持的类型），故拆成 x/z 两个字数。",
    "--     ★ 这也解释了 5859 行本地存的是完整 Vector3（本地不需要序列化）。",
  ],

  "PlayerController:GetRemoteInteraction#1": [
    "--★ GetRemoteInteraction：★ 13 处外部调用（全部是 brain）。",
    "--   ⇒ 「AI 读取玩家意图」的唯一接口。",
    "--   ⚠ 三元返回，调用方都写成 `act, target = GetRemoteInteraction()`",
    "--     （只取前两个），WX78 的 5887 行才用第三个（position）。",
  ],

  "PlayerController:OnLocomotorBufferedAction#1": [
    "--★★★ 【OnLocomotorBufferedAction(act)】★ 被 locomotor.lua:1087 调用。",
    "--   ★ 这是「动作被缓冲进 locomotor」时的回调，双端都跑。",
    "--   两个职责：",
    "--     ① 更新 recent_bufferedaction（★ 松手护栏的数据源）",
    "--     ② 广播 remoteinteractionaction（★ AI 意图）",
  ],

  "PlayerController:OnLocomotorBufferedAction#1+5": [
    "--   ★★ 5875-5877 行：`self.handler == nil`（远端玩家）时**清空**交互意图。",
    "--     注释 \"Clear any remote interactions if server takes over\" ——",
    "--     ⇒ 语义：一旦服务器接管（玩家不再由客户端预测驱动），",
    "--       客户端上报的交互意图就失效了。",
    "--   ⚠ 但 5876-5877 行只清 action 与 target，**不清 pos**（5857 行的第三个字段）。",
    "--   ⚠ 疑似缺陷（清理不完整）：remoteinteractionpos 残留。",
    "--     推理依据：5876/5877 行分别清 remoteinteractionaction 与",
    "--       remoteinteractiontarget，没有 remoteinteractionpos。",
    "--       而 5868 行的 GetRemoteInteraction 会返回残留的 pos。",
    "--     影响：WX78 的划船逻辑（5891 行）可能读到过期位置。",
  ],

  "PlayerController:OnLocomotorBufferedAction#1+24": [
    "--   ★★ 5894-5895 行：动作的成功/失败回调都清意图。",
    "--     回调是 _clearinteractiontarget（166-171 行定义的闭包）。",
    "--     ⇒ 语义：「做了这个交互」或「交互失败」都让 AI 重新评估。",
    "--   ⚠ 注意只有「友好交互」才挂回调（5885 行的标签判据）。",
  ],

  "PlayerController:OnLocomotorBufferedAction#1+31": [
    "--★ 5901-5906 行：更新松手护栏的四元组。",
    "--   5903 行 `act.action == ACTIONS.CASTAOE and BUFFERED_CASTAOE_TIME or",
    "--   BUFFERED_ACTION_NO_CANCEL_TIME` ——",
    "--     ★★ 唯一的分岔：施法给 0.5 秒宽限，普通动作只给 1 帧。",
    "--     理由见 5 行注释（施法有前摇，摇杆会持续偏向）。",
    "--   ⚠ 5901 行的守卫 `if dir ~= nil`：★ 摇杆无输入时不记录护栏。",
    "--     ⇒ 只有「玩家正推着摇杆点动作」才会触发护栏。",
    "--     这解释了为什么护栏不会影响鼠标玩家的动作。",
  ],

  "OnNewState#1": [
    "--★ 【OnNewState】状态切换 → 强制 currentstate 变脏。",
    "--   --V2C: -Don't use data.statename /",
    "--   --     -\"newstate\" events are fired off in reverse order when chaining",
    "--   --      GoToState calls in the state's onenter",
    "--   ==> ★★ 「newstate 事件在状态图链式 GoToState 时会**逆序**触发」——",
    "--     若用 data.statename（事件携带的名字）会拿到错误的状态。",
    "--     正确做法是**直接读 sg.currentstate.name**。",
  ],

  "OnNewState#1+4": [
    "--   --#V2C #client_prediction / --force dirty",
    "--   --see SGWilson_client -> ClearCachedServerState",
    "--   ★★ 5916 行 `currentstate:set_local(0)` —— ★★ **这就是「force dirty」**。",
    "--     net 变量有一个「脏标记」机制：值没变就不发网络包。",
    "--     先本地置 0（与目标值必然不同）→ 标记为脏 → 再 set 真实值 → 必定发包。",
    "--   ⇒ 这是引擎网络层的一个经典 trick，用于「值没变但必须通知」的场合。",
    "--   ⚠ 性能代价：每次状态切换都强制发一个包（即使状态名相同）。",
    "--     对状态切换频繁的实体有额外带宽开销。",
  ],

  "PlayerController:OnRemoteToggleMovementPrediction#1": [
    "--★★★ 【OnRemoteToggleMovementPrediction(val)】★ 客户端预测的**总开关**。",
    "--   ★ 它的 RPC 对端是 networkclientrpc.lua:954 SetMovementPredictionEnabled，",
    "--     ★★ 由**客户端发起**（一个 RPC 参数只有 bool，却能关闭服务器的预测能力）。",
    "--   ⚠ 疑似缺陷（鉴权缺失）：RPC handler（954-962 行）只 checkbool(enabled)，",
    "--     ★★ **不检查调用者是不是这个玩家本人**，也不检查 enabled 的取值是否合法。",
    "--     推理依据：954 行 `SetMovementPredictionEnabled = function(player, enabled)`；",
    "--       959 行 `if not (checkbool(enabled)) then printinvalid(...); return end`；",
    "--       961 行直接调用。→ player 参数只用于取组件，不做归属校验。",
    "--     ⇒ 后果：任何客户端都能让**服务器**关闭（或开启）自己的移动预测。",
    "--       关闭后自己就不再被预测跟随（= 自己说了算），这是可利用的。",
    "--       开启则相反（自己被预测拉走）。",
    "--     对比：PredictWalking（425 行）有 IsPointInRange + remote_predicting 检查；",
    "--       LeftClick（61 行）有 checknumber/checkbool 系列校验。",
    "--     ⇒ 这条 RPC 的校验强度**明显低于同文件其他 RPC**，是最可疑的一处。",
    "--   ★★ 但它同时也是理解整个预测系统的**架构骨架**，值得逐行读：",
  ],

  "PlayerController:OnRemoteToggleMovementPrediction#1+4": [
    "--★ 5924-5926 行的三步「关闭现有预测」：",
    "--   ① locomotor:Stop() —— 立即停止移动",
    "--   ② locomotor:Clear() —— 清掉所有意图（dest + bufferedaction）",
    "--   ③ SetAllowPlatformHopping(not val) —— ★★ 关闭预测时**禁止平台跳跃**。",
    "--   ★ ③ 的理由：跳跃需要客户端与服务器同步（3835 行的 OnRemoteStartHop），",
    "--     没有预测就没有「客户端先行跳跃」的能力，故必须禁。",
  ],

  "PlayerController:OnRemoteToggleMovementPrediction#1+7": [
    "--   ResetRemoteController：彻底清空远端镜像（同 3697 行）。",
  ],

  "PlayerController:OnRemoteToggleMovementPrediction#1+8": [
    "--★ 5928 行 `if dirty then`：只有开关**真正变化**时才做后续的监听管理。",
    "--   ⚠ 但 5924-5926 行的 Stop/Clear/SetAllowPlatformHopping 在 if 之外 ——",
    "--     即「每次调用都会强制停止移动」，哪怕值没变。",
    "--   ⚠ 疑似缺陷（过度清理）：重复调用 ToggleMovementPrediction(true)",
    "--     会不断打断玩家当前移动。",
    "--     推理依据：5922 行算出 dirty 但 5924-5926 无条件执行；",
    "--       5930-5934 行的监听管理才在 if dirty 内。",
    "--     若调用方每次状态切换都调一次（如某些角色技能），会造成频繁打断。",
  ],

  "PlayerController:OnRemoteToggleMovementPrediction#1+9": [
    "--★ 5929-5931 行：开启预测 → 开始监听 newstate，同步状态名给客户端。",
    "--   ★ 5931 行 `currentstate:set(真实值)` —— 因为 5916 行的 set_local(0) 已置脏，",
    "--     所以这里必定发包。",
    "--   ⇒★★ 预测开启的**必要条件**是「客户端知道我在哪个状态」，",
    "--     因为预测的合法性判断（CanLocomote:763）依赖 sg 状态标签。",
  ],

  "PlayerController:OnRemoteToggleMovementPrediction#1+12": [
    "--★ 关闭预测 → 停止监听，currentstate:set(0)。",
    "--   ★ set(0) 而非 set_local(0) —— 这是**发给客户端**的终止信号，",
    "--     客户端据此知道「服务端不再预测，位置以服务器为准」。",
  ],

  "PlayerController:OnRemoteToggleMovementPrediction#1+20": [
    "--★★ 返回类对象本身 —— DST 组件的标准导出形式。",
  ],
};

export const AFTER = {};