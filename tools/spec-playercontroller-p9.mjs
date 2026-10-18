// spec-playercontroller-p9.mjs —— 第 9 段：4700-5330 行
// 覆盖：OnRightClick 及其服务端对端、RemapMapAction、GetMapActions、OnMapAction

export const BEFORE = {
  4970: [
    "--============================================================",
    "-- 【第九段】4970-5330 行：鼠标右键 / ★ 地图动作（屏幕坐标 → 世界坐标）",
    "--============================================================",
  ],

  4969: [
    "--【GetPlatformRelativePosition(absolute_x, absolute_z)】世界坐标 → 平台局部坐标。",
    "--   ★ 与 3718 行的 ConvertPlatformRelativeToAbsoluteXZ 是**逆运算**。",
    "--   ★ 返回三元组 (platform, x, z)：platform 为 nil 时 x/z 原样返回。",
    "--   ⚠ 4973 行 `platform.entity:WorldToLocalSpace(absolute_x, 0, absolute_z)`：",
    "--     ★★ y 硬编码 0。因为只处理 XZ 平面，y 无意义。",
    "--     但若平台在 y=10 的空中（船），局部 y 也会是 -10，却被丢弃 ——",
    "--     这正是 B8「一字段三语义」的另一个体现：**平台局部坐标丢掉了高度维度**。",
    "--   ⇒ 后果：在不同高度的平台上点击同一世界坐标，得到的局部 xz 不同，",
    "--     还原回去能得到正确世界坐标（因为 y 被丢弃后又置 0）。但若目标平台",
    "--     不在同一水平面，还原会出错。",
    "--   推理依据：4974 行 `absolute_x, y, absolute_z = ...WorldToLocalSpace(...)`",
    "--     中 y 被接收但随后 4975 行的返回不含 y。",
  ],

  4978: [
    "--★★ 【OnRightClick(down)】鼠标右键 = 「第二动作 / AOE 瞄准 / 进入放置」。",
    "--   ★ 5087 行结束，110 行。结构：",
    "--     ① 4979-4986 守卫（鼠标模式 / 抬起 → RemoteStopControl）",
    "--     ② 4988-5001 取消分支（放置/AOE/禁用/HUD）",
    "--     ③ 5003-5005 取长按起点 + 取动作",
    "--     ④ 5007-5029 无动作时的四条出路",
    "--     ⑤ 5030-5033 地图动作",
    "--     ⑥ 5034-5084 部署特判 + 三分支发送",
    "--     ⑦ 5085 DoAction",
  ],

  4982: [
    "--   ★ 4982-4985 行：右键**抬起** → 通知服务器按键松开（对称 4527 行）。",
    "--     守卫 `self:IsEnabled()`：被禁用时不需要清（ClearActionHold 会清）。",
  ],

  4990: [
    "--   ★ 4990-4991 行：右键**只清** startdragtime，**不清** startdoubleclicktime",
    "--     （而 4688-4695 行的左键两者都清）。",
    "--   ⚠ 疑似缺陷（不对称）：右键不重置双击记录，意味着「左键双击后立刻右键」",
    "--     可能被误判为双击的第二击（4773-4774 行记录的时间未被清除）。",
    "--     推理依据：4688-4695（左键）清 actionholdtime + startdragtime +",
    "--       startdoubleclicktime/pos 四项；4990-4991（右键）只清 startdragtime。",
    "--     缓解：DOUBLE_CLICK_TIMEOUT = .5 秒，窗口很短；",
    "--       且右键的 5003 行会重设 actionholdtime。",
  ],

  4993: [
    "--   ★ 4993-4998 行：右键的前三个早退都是「取消当前模式」：",
    "--     建造放置中 → 取消建造",
    "--     AOE 瞄准中 → 取消瞄准",
    "--     被禁用 / 点在 HUD 上 → 放弃",
    "--   ⇒ 对比左键（4699-4719）：左键在建造放置中是**执行建造**（点一下放下）。",
    "--     ★ 这是 LMB/RMB 的核心语义差异：「左键确认，右键取消」。",
  ],

  5003: [
    "--   长按起点。与左键的 4722 行对称。",
  ],

  5005: [
    "--   ★★ act = self:GetRightMouseAction() —— **取缓存**（2827/2936 行的副产物）。",
    "--     ★ 与手柄路径的 GetGroundUseAction（现算）不同。",
    "--   ⚠ 若本帧还没跑过 OnUpdate 的 2827 行（如刚 Activate），RMBaction 可能过期。",
    "--     由 4559-4563 行的有效性检查兜底。",
  ],

  5006: [
    "--   maptarget 在 act 可能为 nil 时就算（GetMapTarget:424 首行处理 nil）。",
  ],

  5007: [
    "--★★★ 【5007-5029 无右键动作时的四条出路】",
    "--   ① 5009-5018 关闭 HUD（合成菜单 / 法术轮盘）",
    "--   ② 5020 收回手持物（ReturnActiveItem）",
    "--   ③ 5021 TryAOETargeting 或 TryAOECharging",
    "--   ④ 5025-5028 通知服务器「右键按下」",
    "--   ★ 这是「右键 = 上下文菜单键」的设计：没有具体动作时，",
    "--     右键负责「退出当前模式」或「切换 UI」。",
  ],

  5010: [
    "--   ★ 5010-5017 行：一次右键可能**同时**关闭合成菜单与法术轮盘（两个 if 而非 elif）。",
    "--     closed 标志（5008 行）只用于「是否还需要通知服务器」。",
  ],

  5020: [
    "--   ★ 5020 行 ReturnActiveItem：把激活物品放回背包。",
    "--     这是「右键空手 → 收起当前工具」的操作（如放下火把后空手）。",
  ],

  5021: [
    "--★ 5021 行 `TryAOETargeting() or TryAOECharging(nil, false)`：",
    "--   ★ iscontroller = false → 后续 RPC 用 CONTROL_SECONDARY（1687 行）。",
    "--   ⇒ 与手柄版的 1109 行（iscontroller = true）构成鼠标/手柄对照。",
  ],

  5025: [
    "--   「右键按下」通知（同 870 行范式）。⚠ 有 closed 标志守卫：",
    "--     若已经关闭了某个 UI，就不再通知（因为那不是「玩家想操作世界」）。",
  ],

  5035: [
    "--   ★ 5036 行 PingReticuleAt：准星涟漪。纯表现。",
  ],

  5038: [
    "--★★ 【5038-5050 部署特判】goingtodeploy：右键动作是 DEPLOY/DEPLOY_FLOATING。",
    "--   5040-5042 行：轴对齐放置时用放置器位置而非鼠标位置。",
    "--   5043-5048 行：override_build_point_fn 可覆盖位置（如桅杆类）。",
    "--   5049 行 `act.rotation = deployplacer.Transform:GetRotation()`：",
    "--     ★★ 部署方向来自**放置器当前朝向**而非鼠标 ——",
    "--       所以放置模式下可用滚轮/按键旋转放置器。",
  ],

  5051: [
    "--★ 5051-5084 行：非服务端的发送分支（与左键同构但参数不同）。",
  ],

  5054: [
    "--   5054-5062 行：部署时位置来自放置器（可选 mouseover），否则来自鼠标。",
    "--   ★ 5056 行非轴对齐时才取 mouseover（轴对齐时没有「悬停物」概念）。",
  ],

  5063: [
    "--★ 右键也带 EncodeControlMods（5063 行）—— 强制攻击等修饰键同样适用。",
  ],

  5076: [
    "--   ★ 5076 行 `act.action ~= ACTIONS.WALKTO and CanLocomote()` ——",
    "--     与左键 4865 行同构的 WALKTO 豁免。",
    "--     ⚠ 但右键几乎不会出现 WALKTO（走是左键的事），这个检查近乎冗余。",
    "--     推理依据：5005 行的 RMBaction 来自 GetRightMouseActions，",
    "--       该函数（playeractionpicker.lua:388）不返回 WALKTO。",
  ],

  5085: [
    "--★ DoAction：右键路径的终点。与左键的 4875 行对称。",
  ],

  5089: [
    "--【OnRemoteRightClick】右键的服务端对端。",
    "--   ★★ 与 OnLeftClick 相比简化很多：",
    "--     · 没有四级回退链（5092 行后直接判断 rmb code）",
    "--     · 没有 AOE / 双击分支",
    "--     · 没有角色特例（玩家资料、商店页）",
    "--   ⇒ 因为右键动作类型少、歧义小。",
    "--   ★ 5100 行仍用 DoGetMouseActions（同时算 lmb 与 rmb）而非专用函数。",
  ],

  5107: [
    "--★ 5107 行的匹配**只有 rmb**（没有 lmb 回退）。",
    "--   ⇒ 对比左键的 4937-4944 行有 lmb→rmb 的双向回退。",
    "--   ⚠ 推测原因：右键不做自动装备（4657 行的黑名单含 STORE 等），",
    "--     不存在「装备变了导致左右键互换」的场景。",
    "--     推理依据：DoActionAutoEquip:4657 排除了大量容器类动作，",
    "--       而这些大多通过右键触发。",
    "--   ⇒ 这是一个**正确的不对称**，不是遗漏。",
  ],

  5112: [
    "--★ 5112 行 `rmb.rotation = rotation or rmb.rotation`：",
    "--   ★ 客户端上报的旋转优先（同 forced 的处理范式）。",
    "--   ⚠ rotation 在 5068/5080 行是 `act.rotation ~= 0 and act.rotation or nil`，",
    "--     所以「旋转 0」会被转成 nil → 服务端保留自己的 rotation。",
    "--     ⇒ 部署时若朝向正好是 0 度，服务端会用自己算的 rotation。",
    "--     推理依据：5068 行 `act.rotation ~= 0 and act.rotation or nil`。",
  ],

  5122: [
    "--★★ 【RemapMapAction(act, position)】★ 地图动作的重映射。",
    "--   回答的问题：「这个动作在**地图的另一个位置**上还成立吗？」",
    "--   两条路径（5126/5141）：",
    "--     ① act.action.map_only：地图专属动作，检查位置合法性后原样返回",
    "--     ② ACTIONS_MAP_REMAP[act.action.code]：普通动作 → 地图专用变体",
    "--   ★ 例：地面点击是 DIG，地图上变成「挖掘标记」。",
  ],

  5126: [
    "--   ★ map_only 动作：maponly_checkvalidpos_fn 决定「合法位置」。",
    "--   5127-5135 行：该函数可同时**改写位置**（返回 act_posx/act_posz）。",
    "--     例：「在这块区域种树」→ 实际种在区域的某个子位置。",
  ],

  5136: [
    "--★★ 【5136-5137 行：地块合法性三连判】",
    "--   ① IsOceanTileAtPoint —— 海上不行",
    "--   ② IsVisualGroundAtPoint —— 有地面才行",
    "--   ③ map_works_on_impassable 时 IsImpassableTileAtPoint 也算",
    "--   再叠加：map_works_on_unexplored 或 CanSeePointOnMiniMap（★ 战争迷雾）。",
    "--   ⚠⚠ 疑似缺陷（运算符优先级）：",
    "--     `A or B or C and D` 解析为 `A or B or (C and D)`（and 优先级高于 or），",
    "--     ★ 这恰好是**作者想要的**语义（map_works_on_impassable 是 C 的修饰）。",
    "--     但**依赖隐式优先级**是可读性隐患 —— 加括号更安全。",
    "--   推理依据：Lua 优先级 and > or > not；",
    "--     5136 行与 5142 行的写法完全相同，说明是刻意的惯用法。",
    "--   ⇒ 这不是 bug，但属于「读的人必须先查优先级表」的危险写法。",
  ],

  5141: [
    "--   ACTIONS_MAP_REMAP（actions.lua 定义）：code → 重映射函数。",
    "--   5143-5145 行比 map_only 多一个豁免：invobject 带 mapaction_works_on_unexplored 标签。",
    "--   ★★ 标签豁免：某些道具（如望远镜/地图扩展）能在未探索区域用地图动作。",
  ],

  5154: [
    "--★ _calc_mapaction_dsq：算「动作实际位置」与「请求位置」的距离平方。",
    "--   ⚠⚠ 疑似缺陷（死代码）：grep 全仓只有这一处定义，**没有任何调用点**。",
    "--     同样的逻辑在 5192-5202 行被内联了一遍（GetMapActions 里）。",
    "--   推理依据：grep -rn _calc_mapaction_dsq 全仓只命中 5154 行的定义。",
    "--   ⇒ 推测：抽取函数时忘记替换内联版本，或后来改回内联而未删函数。",
    "--   ⚠ 它未被删除是好事：若有人要重构，函数逻辑就在这里。",
  ],

  5164: [
    "--★★ 【GetMapActions(position, maptarget, actiondef)】★ 地图动作的选择。",
    "--   5165-5167 行 K 的注释说明了设计约束：",
    "--     \"In order to not interface with the playercontroller too harshly and keep",
    "--      that isolated from this system here / it is better to get what the",
    "--      player could do at their location as a quick check to make sure the",
    "--      actions done here will not interfere with actions done without the map up.\"",
    "--   → 翻译：为了不让地图系统「侵入」playercontroller，",
    "--     先在玩家当前位置做一次快速检查，确认「地图上的动作」与",
    "--     「不开地图时的动作」不冲突。",
    "--   ★ 这就是 5169-5170 行 checkingmapactions 标志的用途。",
  ],

  5169: [
    "--   -- NOTES(JBK): Workaround flag to not add function argument changes for this",
    "--   task and lets things opt-in to special handling.",
    "--   ★★ self.inst.checkingmapactions = true —— 临时全局标志（而非参数传递）。",
    "--   ★ 消费方在 componentactions.lua / playeractionpicker.lua 里：",
    "--     「正在算地图动作」时某些动作（如需要走过去的）会被排除。",
    "--   ⇒ 又一个「为省事而用全局态」的实例（与 skip_inherentmapaction 同类）。",
    "--   ⚠ 必须成对清除（5256-5257 行），否则异常路径会残留。",
  ],

  5174: [
    "--   ★ 5174 行的三态入口：都为空时才走「内建地图动作」分支。",
  ],

  5176: [
    "--   ★ 5176 行 GetPointSpecialActions(position, nil, true)：",
    "--     ★ `true` = 只取「地图专属」的特殊动作（usereticulepos 语义见 225 行）。",
  ],

  5178: [
    "--★ 5178-5179 行的注释解释了「为什么要再挑一次最近的」：",
    "--   --NOTE: -playeractionpicker sorted by priorty / -we're picking again to find",
    "--   the closest one out of the top priority map actions.",
    "--   ⇒ playeractionpicker 已按优先级排序，但同一优先级内取**最近**的。",
  ],

  5180: [
    "--   ★ mapactions（用于 SetInherentMapActions，给地图画可点击标记）",
    "--     与 ba（实际选中的动作）是两个不同的收集。",
  ],

  5191: [
    "--★ 5191 行 `if not ba_end then`：一旦遇到非 map_only 动作就停止挑选。",
    "--   ⇒ 依赖 playeractionpicker 的**优先级排序**保证 map_only 在前。",
    "--   ⚠ 若某个模组注册了优先级更高的非 map_only 动作，会导致地图动作被跳过。",
  ],

  5193: [
    "--   ★ 5195 行 `dsq = valid and DistSq(...) or math.huge`：",
    "--     同样的「and/or 归一」惯用法：合法位置才算距离，否则无穷大。",
    "--     ⚠ 若 DistSq 返回 0（恰好在目标位置），`valid and 0` = 0（Lua 中 0 为真），",
    "--       故不会被 or 分支吞掉。安全。",
  ],

  5209: [
    "--   ★ 5210 行的 `ba.action.rmb` 决定强制到哪个键。",
    "--     与 5229 行（actiondef 分支）、5285/5296 行（OnMapAction）同款三处。",
    "--   ⇒ 「动作属于哪个键」是 Action 上的一个布尔字段（actions.lua 定义）。",
  ],

  5216: [
    "--   ★ 5218 行 SetInherentMapActions：告诉地图界面「哪些动作是地图专属的」，",
    "--     地图据此决定要不要画图标。纯 UI。",
  ],

  5220: [
    "--   ★ 5220-5233 行：客户端指定了具体动作（forced_actiondef）→ 无条件强制。",
    "--   5223-5226 行：maptarget 其实是**手持物**时，把它转成 invobject。",
    "--     注释：\"Unless the action itself is a map_only action then let us say it is",
    "--     fine and force it as highest priority.\"",
    "--   ⚠ 5225 行 `maptarget = nil` 修改了形参 —— 与 1856 行同款的「入参复用」。",
  ],

  5236: [
    "--★ pos = 玩家当前位置（用于 GetLeftClickActions 的「场景动作」查询）。",
    "--   ⚠ 注意 5240 行传的是**玩家位置**而非地图上的 position：",
    "--     GetLeftClickActions 的 position 参数语义是「场景中实体查询的中心」，",
    "--     而 maptarget 已经显式传了目标实体，所以这里只需玩家位置做距离判定。",
  ],

  5238: [
    "--   ★ 5238 行 action_maptarget 的三重过滤：有效性 + 非 INLIMBO + 无 INLIMBO 标签。",
    "--     注释 \"Workaround passing the maptarget entity if it is out of scope for",
    "--     world actions\"。",
  ],

  5252: [
    "--   ★ 5252-5254 行：左右键动作相同 → 丢弃 LMB（避免地图上出现两个相同图标）。",
    "--     注释 \"If the actions are the same for the same target remove the",
    "--     LMBaction\"。",
    "--   ⇒ 与 5358 行（GetSceneItemControllerAction 的同款去重）、",
    "--     5444 行（GetGroundUseAction 的同款去重）构成三处同款逻辑。",
    "--   ⚠ 三处都是 `rmb ~= nil and (lmb == nil or lmb.action ~= rmb.action) and rmb or nil`，",
    "--     逐字相同但没有抽成函数。",
  ],

  5256: [
    "--   ★ 5256-5257 行：必须清除临时标志。",
  ],

  5262: [
    "--【UpdateActionsToMapActions】地图界面每帧调用它来刷新玩家的 LMB/RMB 动作。",
    "--   ★ 5265 行：它**替换** self.LMBaction/self.RMBaction（5267 行），",
    "--     即「地图打开时，鼠标动作由地图位置决定」。",
    "--   ⇒ ★ 这就是「地图动作」的实现本质：换一套动作查询的输入。",
    "--   ⚠ 但 5262-5270 行的函数**不检查 IsEnabled** —— ",
    "--     地图打开时游戏自动暂停，OnUpdate 的移动分支会早退（3024 行），",
    "--     所以不会被客户端 OnUpdate 覆盖回去。",
  ],

  5272: [
    "--★ 【OnMapAction(actioncode, position, maptarget, mod_name)】地图动作的客户端发起 +",
    "--   ★★ 注意：**这个函数客户端和服务端都会跑**（它不是 OnRemote*）。",
    "--   5284 行 `if self.ismastersim then` 分成两半。",
  ],

  5274: [
    "--★★ 5274 行的注释是一条重要的模组兼容约定：",
    "--   \"Do not shorten to a short circuit logic we do not want base game actions",
    "--    as a fallback this would break everything.\"",
    "--   → 翻译：**不要**简写成 `mod_name and MOD_ACTIONS[mod_name][code] or ACTIONS[code]`。",
    "--     因为若模组的 code 表里没有这个 code，不应回退到原版动作表。",
    "--     那样模组客户端点击就会执行**原版的另一个动作**。",
    "--   ⇒ 这是「模组命名空间必须严格隔离」的具体实现。",
  ],

  5279: [
    "--   ★ 双重守卫：动作存在 且（是地图动作 或 地图专属）。",
    "--   ⇒ 非地图动作的 RPC 会被丢弃 —— 这是地图动作的**鉴权**。",
    "--   ⚠ 与 5274 行的严格隔离配合：客户端无法通过地图 RPC 执行任意动作。",
  ],

  5283: [
    "--   ★ 服务端与客户端**共用** GetMapActions（5283 行在 ismastersim 之外）。",
    "--   ⇒ 与 OnLeftClick 的「服务端用 CLIENT_REQUESTED_ACTION 重算」不同，",
    "--     这里靠 5291/5312 行的 PushAction/PreviewAction 走标准路径，",
    "--     且**没有做 code 匹配校验**。",
    "--   ⚠⚠ 疑似缺陷（缺少 code 校验）：对比 OnLeftClick:2332 行的",
    "--     `buffaction.action.code == actioncode` 双重校验，本函数直接执行。",
    "--     安全性依赖 5279 行的 map_action/map_only 标签检查 ——",
    "--     即「只执行本身标记为地图动作的动作」。",
    "--     推理依据：5283-5293 行无任何 code 比较；",
    "--       而 position/maptarget 全部来自客户端（RPC 层只有 IsPointInRange）。",
    "--   ⇒ 攻击面：客户端可让服务器在**地图任意已探索点**执行任意 map_action。",
    "--     由于这些动作本身都是「玩家在地图上能做的」，风险有限；",
    "--     但距离校验只有 64 格（IsPointInRange 的 4096），比近战距离宽松得多。",
  ],

  5294: [
    "--   无 locomotor 客户端：手工 pre_action_cb + 发 RPC（5305 行）。",
    "--   ★ 5305 行 `SendRPCToServer(RPC.DoActionOnMap, ...)` ——",
    "--     服务端会再次进入本函数（5284 行的 mastersim 分支）并真正执行。",
    "--   ⇒ 即「客户端调用 → 服务端再走一遍同一个函数」。",
  ],

  5306: [
    "--   ★★ 5307-5317 行的严重问题：**没有 nil 检查**。",
    "--     `if act.rmb then RMBaction.preview_cb = ...` ——",
    "--     若 GetMapActions 返回的 RMBaction 为 nil，这里会 nil 索引崩溃。",
    "--   ⚠ 5306 行的 CanLocomote 为假时整个分支不进（反而安全），",
    "--     但 CanLocomote 为真且 RMBaction 为 nil 时崩溃。",
    "--     推理依据：5294-5305 行（无 locomotor）分支有 nil 保护",
    "--       （5297 行的 `if RMBaction and RMBaction.action.pre_action_cb`），",
    "--       而 5306-5317 行完全没有对应的 `if RMBaction ~= nil then`。",
    "--   ⚠ 这是**结构不对称**导致的潜在崩溃，与 5294 分支的细致保护形成对比。",
    "--     实际触发条件：玩家在地图上按了一个「只有 LMB 动作」的位置，",
    "--       且客户端有 locomotor 且能预测。",
    "--     ⇒ 这是本文件中最值得上报的一处缺陷。",
  ],

  5321: [
    "--★★ 【GetLeftMouseAction / GetRightMouseAction】纯 getter。",
    "--   ★ 5322/5326 行只是返回缓存字段 —— 但这两个 getter 是**外部 API**：",
    "--     grep 确认被 componentactions.lua / UI / 地图等多处调用。",
    "--   ⇒ 「缓存」的设计让所有动作判定都读同一个值，天然一致。",
  ],
};

export const AFTER = {};