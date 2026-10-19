--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：widgets/widget.lua（840 行）
-- 模块：UI 系统 / 控件基类（Widget）
-- 职责：DST 全部 UI 元素的父类。它只做五件事：
--   ① 把每个控件包装成一个**真实实体**（CreateEntity + UITransform），
--      因此 UI 与玩法共用同一套实体世界与渲染管线；
--   ② 维护控件树（children / parent）与显示-启用-焦点三种可见状态；
--   ③ 定义所有事件回调的**默认传播规则**（OnControl / OnMouseButton /
--      OnRawKey / OnTextInput / OnFocusMove）；
--   ④ 实现焦点链（SetFocus / SetFocusFromChild / ClearFocus /
--      GetDeepestFocus / focus_flow 导航图）；
--   ⑤ 把补间（ScaleTo/MoveTo/RotateTo/TintTo）转发给 components/uianim。
--
-- ★★ 全文件最重要的认知一：**一个 Widget == 一个实体**。
--   7 行 self.inst = CreateEntity() 不是性能取舍，是**架构必然**：
--   · UI 才能复用引擎的 Transform/材质/Shader/Scissor/鼠标命中；
--   · UI 才能挂组件（本文件就挂了 uianim，第 20 行）；
--   · 渲染排序天然由实体的父子关系 + MoveToFront 决定（64-70 行）。
--   ⇒ 推论：CreateEntity 很贵（要分配 GUID、走实体管理表）。
--     widgets/ 顶层有 183 个控件文件，一个界面动辄几百个 Widget，
--     这就是为什么 StartUpdating（485）是**注册制**而不是每帧遍历整棵树。
--
-- ★★ 全文件最重要的认知二：**三个「可见性」互相独立，且只有两个是布尔的**。
--   · shown（311 Hide / 318 Show）—— 自己画不画。有父级继承（101-103）。
--   · enabled（266 Enable / 271 Disable）—— 响应不响应。有父级继承（233-241）。
--   · focus（659 SetFocus）—— 是否在焦点路径上。**不继承**，由
--     SetFocusFromChild（632）显式向上冒泡。
--   ★ 注意 shown 用的单词是 shown 而不是 visible，因为 IsVisible（101）
--     是**计算**出来的（自己 && 父级），而 shown 是**存储**的。
--   ⚠ 见 129-131：只有 focus==true 的子控件才收事件。所以「shown 但
--     没有焦点的控件」永远收不到输入——这正是 G2 的机制根源。
--
-- ★★ 全文件最重要的认知三：**事件分发是「深度优先 + 焦点门禁 + 短路」**。
--   统一模板（56-62、105-110、112-118、124-138、72-99 五处完全同构）：
--     ① 自己没焦点 → 直接 return false（107、127、74、57）
--     ② 遍历 children，**只对 v.focus 为真的**子控件递归（60、108、116、130、77）
--     ③ 任一子控件返回 true → 立刻 return true（短路，不再问下一个兄弟）
--     ④ 自己再处理（124-138 的 parent_scroll_list；72-99 的 focus_flow）
--   ⇒ 三个后果，全部是设计后果而不是缺陷：
--     · 事件永远先到叶子（最深的焦点控件），符合「最具体优先」；
--     · ★ focus=true 的子控件**互斥**（由 SetFocusFromChild 保证），
--       所以短路与不短路等价——这解释了为什么这里可以放心 pairs()遍历：
--       同一时刻最多一个子控件有焦点。
--     · ⚠ 616ClearFocus 里`if self.focus then` 包着整段递归：如果一个
--       控件 focus 已经是 false，它内部的 focus=true 子控件**不会被清**。
--       见 615-630 的缺陷标注。
--
-- ★★ 关于锚点（配合 frontend.lua 文件头的「没有布局引擎」）：
--   本文件只暴露 SetHAnchor / SetVAnchor（416-422）四个方向的设置入口，
--   以及 SetScaleMode（385）。RegPoint 只在 widgets/image.lua:154-158
--   （贴图自己的对齐点），因为只有带贴图的控件需要它。
--   三者的组合才决定最终位置：父级区域 + Anchor + RegPoint + ScaleMode。
--
-- ★★ 关于坐标（三套，互不相同——这是模组最常踩的坑）：
--   · 局部坐标  GetPosition / GetLocalPosition（340/358）—— 相对**父实体**。
--     ★ 336 GetWorldPosition 与 340 GetPosition 对**同一个 Widget 会返回
--     不同值**，只要它有父级且父级有位移/缩放。
--   · 世界坐标  GetWorldPosition（336）—— 屏幕绝对坐标。
--   · 模拟坐标  Input:GetWorldPosition（input.lua:251）—— 3D 场景投影，
--     UI 拿不到；这就是为什么 UI 点击要经过 entitiesundermouse 中转。
--   · 缩放      GetScale（548）返回**累积**缩放（自己 × 父 × 祖父…），
--     而 GetLooseScale（557）只返回**自身**缩放。两个都要，看用途。
--   ⇒ 708-800 SetHoverText 里手工做了 `world_pos - parent_pos` 再除以
--     parent_scale 的逆运算（778-782），就是在补这套坐标系。
--
-- ★★ 关于暂停（22行 UpdateWhilePaused）：
--   34-44 UpdateWhilePaused 把 DoPeriodicTask / DoTaskInTime 从
--   「模拟时间轴」换成「真实时间轴」（DoStaticPeriodicTask），
--   并同步给 uianim 组件。⇒ **默认所有控件在服务器暂停时继续动**。
--   注释明确要求：依赖玩法的效果要显式传 false。
--   ★ 这是双调度器架构（scheduler.lua 的 scheduler / staticScheduler）
--     在 UI 层的落地，也是「暂停时菜单淡入动画不冻结」的实现方式。
--
-- 关键符号：Widget（类）, children, parent, callbacks, inst,
--   AddChild, RemoveChild, KillAllChildren, Kill,
--   Show, Hide, Enable, Disable, IsVisible, IsEnabled,
--   SetFocus, SetFocusFromChild, ClearFocus, GetDeepestFocus,
--   GetFocusChild, IsDeepestFocus, SetFocusChangeDir, ClearFocusDirs,
--   OnControl, OnMouseButton, OnRawKey, OnTextInput, OnFocusMove,
--   SetFocus, LockFocus, SetParentScrollList, SetHoverText, ClearHoverText,
--   GetTooltip, SetTooltip, SetTooltipPos, SetTooltipColour,
--   ScaleTo, MoveTo, RotateTo, TintTo, CancelScaleTo, CancelMoveTo,
--   CancelRotateTo, CancelTintTo, ForceStartWallUpdating, ForceStopWallUpdating,
--   FollowMouse, StopFollowMouse, MoveToFront, MoveToBack,
--   SetPosition, SetScale, SetHAnchor, SetVAnchor, SetScaleMode,
--   SetScissor, SetClickable, SetFadeAlpha, SetCanFadeAlpha,
--   GetWorldPosition, GetPosition, GetLocalPosition, GetScale, GetLooseScale,
--   UpdateWhilePaused, StartUpdating, StopUpdating, GetStr, GetParentScreen
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 frontend.lua:297-316 —— 消费本文件的 GetDeepestFocus / GetFocusChild
--   ★★ 参见 frontend.lua:403-416 OnFocusMove —— 驱动本文件 72-99 的导航
--   ★★ 参见 frontend.lua:759-761 —— 只有栈顶屏幕才收 OnUpdate
--   ★★ 参见 widgets/screen.lua —— Screen 是 Widget 的唯一直接子类
--   ★★ 参见 components/uianim.lua —— ScaleTo/MoveTo/TintTo 的真正实现
--   ★★ 参见 widgets/scrollablelist.lua:44 —— G2 的原始现场（本文件 77 行是传播路径）
--   ★★ 参见 widgets/button.lua:56 OnControl —— 子类覆盖本文件 124 的典型例子
--   参见 widgets/image.lua:154-158 SetHRegPoint / SetVRegPoint —— RegPoint 只在贴图类
--   参见 widgets/text.lua —— GetRegionSize / SetMultilineTruncatedString 的提供方
--   参见 widgets/scrollablelist.lua —— parent_scroll_list（94/133 行）的赋值方
--   参见 util.lua:1716 FunctionOrValue —— 81 行 focus_flow 的求值器
--   参见 constants.lua:77-81 —— ANCHOR 三值枚举（H 与 V 共用）
--   参见 frontend.lua:1029-1031—— 「alpha 淡出会留下坏状态」的官方警告
--   参见 widgets/imagebutton.lua —— hovertext 用到的 blank.tex（759 行）
--============================================================
-- ════════════════════════════════════════════════════════════════
-- ★★★ 【Widget 构造函数】1-32 —— 一切 UI 元素的起点
--
-- ★★ 全文件最重要的认知一：**一个 Widget == 一个实体**。
--   7 行 self.inst = CreateEntity() 不是性能取舍，是**架构必然**：
--   ① UI 才能复用引擎的 Transform / 材质 / Shader / Scissor /
--      鼠标命中测试（⇒ 才有 input.lua:516 GetEntitiesAtScreenPoint
--      这种「UI 与世界共用一套拾取」的可能）；
--   ② UI 才能挂组件（本文件 20 行就挂了 uianim）；
--   ③ 渲染排序天然由实体的父子关系决定（64-70 行 MoveToFront/Back）；
--   ④ 每个实体有 GUID，能被 TheSim 的全局表查到（供鼠标反查）。
--   ⇒ 代价：CreateEntity 很贵。一个界面动辄几百个 Widget，
--     所以有 485-491 的「按需更新注册表」（配合 frontend.lua:234
--     的弱键表）—— 这套设计直接源于「每个控件都是实体」这个前提。
--═══════════════════════════════════════════════════════════════
local Widget = Class(function(self, name)
-- name 缺省为 "widget"。⚠ 注意所有控件都叫 widget 时 GetStr（690）
--   的调试输出无法区分它们——排查工具的已知局限。
	name = name or "widget"
-- ★★ self.children = {} —— **以控件对象为键的表**（不是数组）。
-- ★ 为什么用对象键而不是数字下标？
--   → 因为事件分发靠 `for k,v in pairs(self.children)`（59/76/107/115/129 等），
--     用对象键表可以**任意顺序**遍历而不依赖下标连续性。
--   → 且 AddChild（300-309）/RemoveChild（282-289）能O(1) 摘除。
-- ⚠ 代价：pairs 的遍历顺序在 Lua 里是**未定义**的（由哈希表实现决定）。
--   本文件多处依赖「任一子控件消费即返回」的短路（60/77/108/116/130），
--   所以顺序无关紧要 ✓。但若某处需要「按添加顺序」，就必须另维护数组。
--   参见 697-699 GetStr 的递归遍历——它也需要顺序（缩进显示），
--   同样是未定义的，只影响调试可读性。
    self.children = {}
    self.callbacks = {}
-- self.name —— 显示名，主要用于 GetStr/toString（704-706）。
    self.name = name

-- ★★ self.inst = CreateEntity() —— 见文件头「认知一」。
-- ⚠ CreateEntity 无参数 = 创建一个「无 prefab」的裸实体。
--   它不会有 prefab 名、不进存档、不复制到服务端。
--   ⇒ UI 实体是**纯本地**的（18 行CallPrefabConstructionComplete 之后
--     就完全脱离服务端逻辑）。
    self.inst = CreateEntity()
-- ★★★ 原注释是一段极重要的设计指引：
--   "--if your widget does something that is based on gameplay, use these
--    over the default, so that pausing freezes the effect."
-- 【解读】
--   9-10 行把 DoPeriodicTask / DoTaskInTime **重命名**到DoSimPeriodicTask /
--   DoSimTaskInTime 两个新名字。这不是重命名，是**别名重定向**：
--   把「模拟时间轴的任务」存到 DoSim* 名下，而 DoPeriodicTask 这个名字
--   留给「真实时间轴的任务」（22 行 UpdateWhilePaused(true) 干的）。
-- 【为什么要这么绕】
--   实体基类的 DoPeriodicTask 默认挂在**模拟时间**上（服务器暂停就停）。
--   但 UI 大多数动画**不应该**因暂停而冻结（打开菜单时它还要动）。
--   ⇒ 框架默认把 UI 的任务切到真实时间轴（静态调度器）。
--   ⇒ 若某个控件的效果**要**随玩法冻结（例：显示血量的数字在暂停时
--     不变化），就用 DoSimPeriodicTask 显式取回模拟时间轴。
-- 【落地】
--   scheduler.lua 的双调度器：scheduler（模拟时间）/ staticScheduler
--   （真实时间）。这是 DST 全局一致的设计，见 bug-patterns.md D 家族
--   「把模拟时间与真实时间分成两个独立调度器」。
-- ★ 这也是缺陷 D2（暂停语义混乱）的解药：UI 明确选边站。
    --if your widget does something that is based on gameplay, use these over the default, so that pausing freezes the effect.
-- ★★ 9-10 行的别名重定向。**这是本文件最容易被误改的两行**。
--   ⚠ 若有人「清理」掉这两行（看起来像无用赋值），整个 UI 的
--     暂停语义会立刻反转：所有 UI 动画在暂停时冻结。
--   ⇒ 建议在任何重构里显式排除这两行。
    self.inst.DoSimPeriodicTask = self.inst.DoPeriodicTask
    self.inst.DoSimTaskInTime = self.inst.DoTaskInTime
-- ★★★ self.inst.widget = self —— **反向指针**。
-- ★ 它是「实体 → 控件」的查找表，唯一的消费者是
--   frontend.lua:933-934DoHoverFocusUpdate 的 `hover_inst.widget:SetFocus()`。
--   ⇒ 鼠标命中一个 UI 实体后，靠这个字段找回对应的 Lua 控件。
-- ★ 与 306 行 child.parent = self 互为镜像，构成**双向连接**：
--     控件 → 实体（inst）、实体 → 控件（inst.widget）。
-- ⚠ 331 行 Kill 时会置 `self.inst.widget = nil` —— 解除反向指针，
--   防止已销毁控件被鼠标误查。★ 这一点很关键：
--   931-934 若拿到已 Kill 的实体，widget 为 nil → `hover_inst and
--   hover_inst.widget` 为假 → 走 935 的屏幕级兜底。✓ 安全。
    self.inst.widget = self
-- inst.name = name —— 实体的名字（与 5 行的控件名同步）。
	self.inst.name = name

-- ★★★ 两个标签："widget" 与 "UI"。
-- ★ "UI" 标签是**语义分类**的消费者在别处：
--   grep 核实——本文件之外，widgets/ 与 prefabs/ 里对 "UI" 标签的
--     检查极少见；它更多是给调试工具与模组用的。
-- ★ "widget" 标签则对应 inst.widget 字段的另一种命名方式。
-- ⚠ 两个标签功能重叠，属历史遗留。
    self.inst:AddTag("widget")
    self.inst:AddTag("UI")
-- entity:SetName(name) —— C++ 侧的实体名（调试器里可见）。
    self.inst.entity:SetName(name)
-- ★★ entity:AddUITransform() —— ★ 本文件所有定位能力的来源。
-- ★ UITransform 提供（后续全部通过 self.inst.UITransform.X 访问）：
--   · 局部位置 / 世界位置（GetLocalPosition / GetWorldPosition）
--   · 缩放 / 旋转（GetScale / SetRotation）
--   · ★ 锚点 SetHAnchor / SetVAnchor（416/420）
--   · ★ 缩放模式 SetScaleMode（385）
--   · ★ MaxPropUpscale（381）—— UI 最大放大倍数
--   · ★ 裁剪矩形 SetScissor（836）—— 实现滚动列表的关键
-- ⇒ 「没有布局引擎」的物理基础：最终位置计算全在 C++ 的 UITransform 里，
--   Lua 只负责喂三个参数（Anchor / RegPoint / ScaleMode）。
    self.inst.entity:AddUITransform()
-- ★ CallPrefabConstructionComplete() —— 通知实体「构造完成」。
--   ★★ 为什么 UI 实体也需要它？因为引擎的统一流程里，
--   prefab 构造完成后才会被纳入渲染/更新循环。
--   ⇒ UI 实体走的是与游戏实体**完全相同**的初始化流程。
--   这是「UI 与玩法共用实体世界」的最后一块拼图。
    self.inst.entity:CallPrefabConstructionComplete()

-- ★★ AddComponent("uianim") —— 每个控件都自带补间组件。
-- ★ 为什么是构造函数里就加，而不是等需要时（ScaleTo 的 167 行）？
--   → 因为 22 行 UpdateWhilePaused 立刻要访问它（43 行）；
--     且避免首次动画时的一次组件创建开销。
-- ⚠ 但 167/180/193/206/216/226 六处仍有 `if not self.inst.components.uianim`
--   的懒初始化兜底——说明**有些路径会丢掉构造时加的组件**。
--   推理：可能与 RemoveComponent 或实体重用有关。属防御性冗余。
-- ★ 组件实现见 components/uianim.lua（只有 9 个方法，全部基于
--   StartWallUpdatingComponent 走**真实时间**墙钟更新）。
    self.inst:AddComponent("uianim")

-- ★★★ UpdateWhilePaused(true) —— 默认「暂停时继续更新」。
-- ★★ 这是「双调度器」在 UI 层的落点，详见 9-10 行的原注释。
-- ★ 22 行是**默认选择**：绝大多数 UI 动画不该被暂停冻结。
--   ⇒ 需要冻结的控件要显式调 UpdateWhilePaused(false)（34 行）。
    self:UpdateWhilePaused(true)

-- ════════════════════════════════════════════════════════════════
-- ★★ 【控件的五个布尔状态字段】24-28
--  24  self.enabled          —— 响应输入吗？（266/271 切换，有父级继承）
--  25  self.shown             —— 绘制自己吗？（311/318 切换，有父级继承）
--  26  self.focus             —— 在焦点路径上吗？（659 设置，**不继承**）
--  27  self.focus_target      —— ★「想被聚焦」（预置目标，见下）
--  28  self.can_fade_alpha    —— 允许被 SetFadeAlpha 改透明度吗？
--
-- ★★ 这五个字段互相**正交**，且分属三套完全不同的机制：
--  · enabled / shown  有父级继承（233-241 / 101-103）→ 「链式可见」
--  · focus           无继承，由 SetFocusFromChild（632）向上冒泡
--  · can_fade_alpha  无继承，但 SetFadeAlpha 会递归传给子节点（506-514）
--
-- ★ 27 行 focus_target 是本文件里**最不被理解**的字段：
--   grep 核实——它在 1-840 行里**只被初始化，从不被读取**！
--   ⇒ 死字段（历史遗留，或由子类/mods 使用）。
--   ⚠ 标注：grep 核实「本文件内无读取点」，不代表全库无引用。
--═══════════════════════════════════════════════════════════════
    self.enabled = true
    self.shown = true
-- ★ self.focus = false —— 焦点是**存储**的布尔，不是计算值。
--   ⇒ 「当前焦点」= 从根到叶唯一一条 focus==true 的路径。
--   详见 592-602 GetDeepestFocus 与 632-657 SetFocusFromChild。
    self.focus = false
-- ⚠ self.focus_target = false —— grep 核实：本文件内**无任何读取点**。
--   推测是早期设计里「标记某个控件为焦点候选」的遗留。
--   ⇒ 若模组依赖它，需要自己实现。
    self.focus_target = false
-- ★ can_fade_alpha = true —— 是否允许被「alpha 淡出」改透明度。
-- ★ 它的**唯一**读者是 507 行 `if not self.can_fade_alpha then return end`。
-- ★ 517-523 SetCanFadeAlpha 会把它递归传给所有子节点，
--   所以设一次就整棵子树生效。
-- ★★ 与缺陷 G4 的关联：frontend.lua:591-598 的 alpha 淡出收尾时
--   调 `v:SetFadeAlpha(1)` 试图恢复，
--   ⚠ 但 **can_fade_alpha=false 的控件会被 507 行直接 return**，
--     永远恢复不了！这就是 frontend.lua:1029-1031 官方警告
--     「it leaves your screen's widgets at alpha 0 when it's finished」
--     的**机制层根因**。
--   ⇒ 准确机制：can_fade_alpha=false = 「拒绝一切淡入淡出」，
--     包括收尾时的恢复。★ 这个字段让「恢复」变得不可靠。
    self.can_fade_alpha = true

-- ★★ self.focus_flow = {} —— 手柄/键盘**导航图**。
-- 【结构】focus_flow[dir] = 目标控件（或返回控件的函数）
--   dir ∈ {MOVE_UP, MOVE_DOWN, MOVE_LEFT, MOVE_RIGHT}（constants.lua:94-97）
-- ★ 它是**稀疏表**（只有注册过的方向才有值），
--   80 行 `if down and self.focus_flow[dir] then` 靠存在性判断。
-- ★★★ 与「焦点是一条链」的关系：
--   · 焦点链（focus=true 的路径）= 「当前在哪」；
--   · focus_flow              = 「能从这去哪」。
--   ⇒ 两者配合：链管状态，flow 管转移。
--   参见 583-590 SetFocusChangeDir（注册）与 577-581 ClearFocusDirs（清空）。
    self.focus_flow = {}
-- ★★ focus_flow_args = {} —— 导航时传给目标 SetFocus 的**参数**。
-- 【为什么要参数】
--   85-89 行：`dest:SetFocus(unpack(self.focus_flow_args[dir]))`。
--   ⇒ 导航不只「移到某个控件」，还可以「移到某控件的第N 个子项」。
--   实例：widgets/menu.lua 用它实现「上/下」与「第几项」的分离。
-- ★ 589 行 toarrayornil(...) 把变长参数转成数组或 nil，
--   保证 focus_flow_args[dir] 要么是数组要么是 nil（不参与真值判断）。
    self.focus_flow_args = {}
end)

-- ════════════════════════════════════════════════════════════════
-- ★★ 【UpdateWhilePaused】—— 双调度器切换（34-44）
-- 【两分支的对称切换】
--   true（默认）→ DoPeriodicTask  = DoStaticPeriodicTask  ★ 真实时间
--                  DoTaskInTime     = DoStaticTaskInTime
--   false        → DoPeriodicTask  = DoSimPeriodicTask     ★ 模拟时间
--                  DoTaskInTime     = DoSimTaskInTime
-- ★ 43 行把这个选择同步给 uianim 组件 —— ★★ 关键：
--   补间动画（ScaleTo/MoveTo/TintTo）也必须跟着切换时间轴，
--   否则「任务跑真实时间、动画跑模拟时间」会不同步。
--   参见 components/uianim.lua:153 `if not self.update_while_paused and
--   TheNet:IsServerPaused() then return end`。
-- ⚠ 注意这里是**赋值**（=）而不是包装成函数：
--   意味着 DoPeriodicTask 从「方法」变成了「另一个方法的别名」。
--   ⚠ 若某个子类在构造后又调了 inst:DoPeriodicTask 的其它重载，
--     行为会随之改变。属「猴补丁」式设计，脆弱但有效。
--────────────────────────────────────────────────────────────────
function Widget:UpdateWhilePaused(update_while_paused)
    if update_while_paused then
        --widgets run all their tasks on StaticUpdate instead of Update so pausing the server doesn't pause widget tasks.
-- ★★ 37-38 行把「周期性任务」与「延时任务」都切到真实时间轴。
--   DoStaticPeriodicTask —— 静态调度器（真实时间，暂停也跑）。
--   ★ scheduler.lua 里staticScheduler 与 scheduler 是两个独立调度器，
--     这正是 bug-patterns.md D 家族建议的「双调度器」架构。
        self.inst.DoPeriodicTask = self.inst.DoStaticPeriodicTask
        self.inst.DoTaskInTime = self.inst.DoStaticTaskInTime
    else
        self.inst.DoPeriodicTask = self.inst.DoSimPeriodicTask
        self.inst.DoTaskInTime = self.inst.DoSimTaskInTime
    end
    self.inst.components.uianim:UpdateWhilePaused(update_while_paused)
end

-- ★★★ IsDeepestFocus —— 「我是焦点链的末端吗」。
-- 【逻辑（46-53）】
--   若我 focus 且**没有任何子节点 focus** → 我是最深的
--   否则 → 我不是最深的
-- 【注意 48-50 行】遍历 children 找 v.focus，**找到一个就return false**。
--   ⇒ 提前退出，O(子节点数)。
-- ★★ 正确性依赖「同一时刻最多一个子节点有焦点」这个不变量。
--   该不变量由 632-657 SetFocusFromChild 的「清兄弟」保证。
-- ⚠ 若这个不变量被破坏（模组手工设 self.focus = true），
--   本函数只检查「有没有」，不检查「有几个」，仍返回 false ✓
--   （任一子节点有焦点我就不是最深的）—— 实际是安全的。
-- ★ 与 GetDeepestFocus（592）对比：本函数只回答**布尔**，
--   那个回答**对象**。两者都基于同一不变量。
function Widget:IsDeepestFocus()
    if self.focus then
        for k,v in pairs(self.children) do
            if v.focus then return false end
        end
    end

    return true
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【事件分发模板①：OnMouseButton】56-62
--
-- 【四步，与本文件另外四处完全同构】
--  ① 焦点门禁：57 `if not self.focus then return false end`
--  ② 深度优先下钻：59-61 只对 `v.focus` 的子节点递归
--  ③ 短路：60 `if ... then return true end` —— 任一子节点消费即返回
--  ④ 自己不处理任何鼠标逻辑 ——★ 纯转发！
--
-- ★★ ④ 是本函数最重要的设计：**基类的默认实现什么也不做**。
--   子类要自己重写（如 widgets/imagebutton.lua）。
--   ⇒ 递归终点是叶子控件（ImageButton），它消费并返回 true。
--
-- ★★ ① 的焦点门禁是 G2（透明 Image 吃焦点）的传播基础：
--   一个 blank.tex 的 Image 想吃到鼠标，必须先**获得焦点**；
--   而焦点由鼠标移动时frontend.lua:933-934 赋予。
--   ⇒ 只要它画在列表区域上、且被命中，就会抢焦点。
--   完整现场见 widgets/scrollablelist.lua:44。
--────────────────────────────────────────────────────────────────
function Widget:OnMouseButton(button, down, x, y)
-- ★★ 焦点门禁。★ 注意它**不检查 shown/enabled**！
-- ⚠ 可见缺陷：
--   一个 `Hide()` 过（shown=false）但仍持有焦点的控件，
--   **依然会收到鼠标事件**。
--   推理依据：Hide（311-316）只改 self.shown，**不动 self.focus**；
--   而本行只看 focus。
--   ⇒ 这就是 frontend.lua:1070 `existing_screen:Hide()` 的隐患：
--     隐藏后的旧屏若仍有焦点链，它的控件仍会吃掉点击。
--   ⚠ 与 84 行 OnFocusMove 的 `dest:IsVisible() and dest.enabled` 判定
--     形成鲜明对比——**导航路径检查了可见性，事件路径没检查**。
--     这是同文件内的不一致，标注为疑似缺陷。
--   ⇒ 影响可控的前提：隐藏屏通常紧接被 PopScreen → OnDestroy。
--     但 1070 的 FadeToScreen 里 Hide 之后**可能不 Pop**。
    if not self.focus then return false end

-- ★ pairs 遍历 children（顺序未定义，见 3 行注释）。
--   60 行的 `v.focus` 过滤保证只有焦点路径上的子树参与。
-- ★★ 短路（return true）的正确性依赖「最多一个子节点有焦点」，
--   所以 pairs 的无序性无害 ✓。这一点值得强调：
--   在一个「无序遍历 + 任一命中即短路」的组合里，顺序不影响结果。
    for k,v in pairs (self.children) do
        if v.focus and v:OnMouseButton(button, down, x, y) then return true end
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【Z 序控制】64-70 —— 两行转发。
-- 【关键性质：MoveToFront/Back 是**实体级**的】
--   C++ 侧的 entity:MoveToFront() 会把该实体移到**父实子的末尾**。
-- ★★ 这就是 DST UI 的全部「层级机制」：
--   AddChild 的顺序 = 初始 z 序；MoveToFront = 提到最前。
--   ⇒ **界面层级 = 屏幕栈的压栈顺序**（frontend.lua:981 AddChild）。
--   ⇒ 没有 z-index、没有 layer 字段、没有布局优先级。
-- ⚠ 代价：无法「压栈新屏但让某个旧屏浮在上面」——
--   唯一手段是 frontend.lua:959 InsertScreenUnderTop（把新屏插到栈下）。
--   这是一个**用栈代替 z-index**的等价设计。
--   参见 frontend.lua:169-179 的层级装配说明与 952-956 的 MoveToFront 修复。
--────────────────────────────────────────────────────────────────
function Widget:MoveToBack()
    self.inst.entity:MoveToBack()
end

function Widget:MoveToFront()
    self.inst.entity:MoveToFront()
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【事件分发模板②：OnFocusMove】72-99 —— 导航的完整实现
--
-- 【五步】
--  ① 74    焦点门禁（同57）
--  ② 76-78 深度优先下钻子节点（与 59-61 同构）
--  ③ 80-92 ★ 自身处理：按 focus_flow[dir] 转移焦点
--  ④ 94-96 ★ 向上回退：交给 parent_scroll_list
--  ⑤ 98    都失败 → return false（让调用者尝试默认值）
--
-- ★★ ③ 里有两个关键判定（84 行）：
--   `if dest and dest:IsVisible() and dest.enabled`
--   ⇒ ★★ 这是本文件**唯一**检查可见性的事件路径！
--     对比 57/127 的纯 focus 门禁 —— 不一致（见 57 行缺陷标注）。
--   为什么导航要检查而点击不检查？
--   ⇒ 因为「导航目标是不可见的控件」在语义上是错的：
--     焦点跑到了一个看不见的地方，玩家完全无法感知。
--     而「点击一个看不见但有焦点的控件」在实践中不会发生。
--   ⇒ 这是「按危害决定检查强度」的合理取舍，但仍是**不一致**。
--────────────────────────────────────────────────────────────────
function Widget:OnFocusMove(dir, down)
    --print ("OnFocusMove", self.name or "?", self.focus, dir, down)
    if not self.focus then return false end

    for k,v in pairs (self.children) do
        if v.focus and v:OnFocusMove(dir, down) then return true end
    end

-- ★★ `if down and self.focus_flow[dir] then` —— 方向键导航只在**按下**时发生。
-- ⚠ down=false（摇杆回中/按键抬起）不导航。
--   ⇒ 手柄「轻推一下方向键」的导航会丢失。
--   但实际中前端只在 keydown 时调 OnFocusMove（frontend.lua:841/859），
--   down 恒为 true。⇒ 这个判定实际不生效。
--   ⚠ 属「参数未被真正使用」的冗余分支。
    if down and self.focus_flow[dir] then
-- ★★ FunctionOrValue(self.focus_flow[dir], self) —— 导航目标可以是**函数**。
-- 【为什么允许函数】
--   → 「下一项」在很多 UI 里是动态的（列表可能变化）；
--   → 函数形式可以**延迟求值**，避免注册时就固定目标。
--   → 第二个参数 self 是传入的「self」参数（FunctionOrValue 的 ... 部分，
--     util.lua:1716-1722：type 是 function 就 func_or_val(...)）。
--   ⇒ 注意它传的是 **self 而不是 dir**，所以回调签名是 fn(widget)，
--     无法知道是哪个方向。要方向得自己闭包捕获。
-- ★ 对比 661 行 `FunctionOrValue(self.focus_forward)` —— 少传了 self，
--   所以 focus_forward 的回调**不接受参数**。两处签名不同。
        local dest = FunctionOrValue(self.focus_flow[dir], self)

        -- Can we pass the focus down the chain if we are disabled/hidden?
-- ★★ 三重判定：目标存在 && 目标可见 && 目标启用。
-- 【dest:IsVisible() 的展开（101-103）】
--   self.shown and (self.parent == nil or self.parent:IsVisible())
--   ⇒ 递归向上检查整条祖先链。
-- ⚠ 但它**不检查祖先的 enabled**（只查 dest.enabled）。
--   ⇒ 一个自身 enabled 但父级被 Disable 的控件会被判为可导航。
--   ⚠ 这是 84 行的一个真实疏漏。
--     推理：IsEnabled（233-241）做了递归，但 84 只调了 IsVisible。
--   ⇒ 正确写法应是 dest:IsEnabled() 而非 dest.enabled。
--     但若父级被 Disable，焦点链通常也进不去它（Disable 不清焦点），
--     所以实际暴露面很小。标注为疑似缺陷（轻度）。
        if dest and dest:IsVisible() and dest.enabled then
            if self.focus_flow_args[dir] then
-- ★★ 有参数就 unpack 传参，没有就空调用。
-- ★ focus_flow_args 的存在让「导航到某控件的某个子项」成为可能。
-- ★ 与 589 行 toarrayornil(...) 配对：注册时转数组，导航时解包。
                dest:SetFocus(unpack(self.focus_flow_args[dir]))
            else
                dest:SetFocus()
            end
            return true
        end
    end

-- ★★ parent_scroll_list 回退 —— 「我处理不了，交给滚动列表」。
-- 【机制】141-143 SetParentScrollList 由 ScrollableList 给它的
--   条目控件赋值。
-- 【为什么需要】
--   → 焦点在列表**内部**的某个控件上时，「往下」应该移动到列表的下一项，
--     而不是由那个控件自己决定（它不知道列表有几项）。
--   → 于是把决策权**上提**给列表。
-- ★★ 这是一个「责任上移」的设计：控件不处理跨边界的导航。
-- ⚠ 但它让 parent_scroll_list 变成了一个**反向引用**（子指向父的父），
--   形成了控件树之外的额外依赖。Kill 时（325-334）**没有清理它**！
-- ⚠ 疑似缺陷：已 Kill 的控件若被外部再访问 parent_scroll_list，
--   会调用到一个已销毁的列表对象。
--   推理依据：Kill（325-334）逐项处理 children / inst.widget /
--   followhandler，**唯独没有 parent_scroll_list**。
--   ⇒ 实际影响：GC 会回收已销毁对象（除非有循环引用阻止），
--     而循环引用正是这里的情形（列表持有条目，条目反向持有列表）。
--     Lua 的 GC 能处理循环（标记-清除），所以不会泄漏，
--     但会**延迟回收**。标注为轻度疏漏。
    if self.parent_scroll_list then
        return self.parent_scroll_list:OnFocusMove(dir, down)
    end

    return false
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【IsVisible】—— 「计算」出来的可见性。
-- 【与 self.shown 的区别】
--   self.shown = **存储**：我自己画不画（Hide/Show 切换）
--   IsVisible() = **计算**：我 && 父级都画
-- ★★ 名字用 Visible 而字段用 shown，就是为了区分这两者。
-- ★ 唯一的读者：84 行（导航目标检查）。
-- ⚠ 缺陷：IsVisible 不检查 enabled，而 IsEnabled（233）不检查 shown。
--   两个「有效」概念互不覆盖，调用方要自己组合。
--────────────────────────────────────────────────────────────────
function Widget:IsVisible()
    return self.shown and (self.parent == nil or self.parent:IsVisible())
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【事件分发模板③：OnRawKey】105-110
-- 与 56-62（鼠标）、124-138（控制码）完全同构的四步结构：
--  ① 106 焦点门禁
--  ② 107-109 只对 v.focus 的子节点递归，任一消费即返回 true
--  ③ 110 隐式返回 nil（基类不处理按键）
-- ★ 与 OnMouseButton 的唯一区别：★ **基类不处理任何逻辑，纯转发**。
--   而 OnControl（124）多了一个 133-135 的滚动列表回退。
-- ★ 与 OnFocusMove 的区别：★ **没有 focus_flow 导航**。
--   ⇒ 键盘导航不走 OnRawKey，而由前端映射成 CONTROL_FOCUS_* 后
--     走 OnControl →（Screen 层）→ OnFocusMove。
--   参见 frontend.lua:858-865。
--────────────────────────────────────────────────────────────────
function Widget:OnRawKey(key, down)
    if not self.focus then return false end
    for k,v in pairs (self.children) do
        if v.focus and v:OnRawKey(key, down) then return true end
    end
end

-- ★★ OnTextInput（112-118）—— 与 OnRawKey 同构的第四个模板。
-- ★ 113 行的 `--print ("text", self, text)` 是被注释的调试打印，
--   保留作为「这里曾需要调试」的记录。
-- ★★ 五处同构模板汇总（务必记住这个模式）：
--   56-62   OnMouseButton  —— 无自身处理
--   72-99   OnFocusMove    —— + 导航（focus_flow）+ 滚动列表回退
--   105-110 OnRawKey       —— 无自身处理
--   112-118 OnTextInput    —— 无自身处理
--   124-138 OnControl      —— + 滚动列表回退
--   ⇒ 「递归下钻 + 焦点门禁 + 短路」是本文件的统一范式。
--     任何一个新事件类型都应照抄这个结构。
function Widget:OnTextInput(text)
    --print ("text", self, text)
    if not self.focus then return false end
    for k,v in pairs (self.children) do
        if v.focus and v:OnTextInput(text) then return true end
    end
end

-- ★★ OnStopForceProcessTextInput —— 空钩子。
-- 【谁调它】frontend.lua:1180/1186 SetForceProcessTextInput
--   在文本框失去「强制输入权」时通知。
-- 【为什么基类是空的】
--   因为「强制处理文本输入」是**文本框专属**的能力。
--   ⇒ 基类不需要实现，只有 widgets/textedit.lua 有真正的逻辑。
-- ★★ 这是「钩子方法（template method）」的标准用法：
--   基类定义接口，具体类填实现，框架在恰当时机调用。
function Widget:OnStopForceProcessTextInput()
end

-- 【ValidateLineNumber(123)】源码完整性哨兵，框住 OnTextInput。
-- ★ 与 frontend.lua:418/497 同一机制——Klei 用它检测打补丁漂移。
ValidateLineNumber(123)
-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【事件分发模板⑤：OnControl】124-138 —— 最核心的事件入口
--
-- 【五步】
--  125    --print("oncontrol", ...) 已注释的调试打印
--  127    ① 焦点门禁：if not self.focus then return false end
--  129-131 ② 深度优先下钻子节点（任一消费即返回 true）
--  133-135 ③ 自身处理：滚轮事件转交 parent_scroll_list
--  137    ④ return false
--
-- ★★★ 为什么这是「最核心」？
--   因为它是**所有抽象输入的唯一收敛点**：
--   · 键盘 → CONTROL_ACCEPT/FOCUS_*（经前端映射 431-435）
--   · 鼠标左键 → CONTROL_PRIMARY → **映射成 CONTROL_ACCEPT**（435 行）
--   · 手柄 A/X → CONTROL_ACCEPT / CONTROL_CONTROLLER_ATTACK
--   · 滚轮 → CONTROL_SCROLLBACK / SCROLLFWD
--   ⇒ 按钮只认CONTROL_ACCEPT（widgets/button.lua:64），
--     所以**鼠标点击按钮与手柄 A 键走的是同一条路径**。
--   这是「键鼠 / 手柄完全等价」的实现基础。
--────────────────────────────────────────────────────────────────
function Widget:OnControl(control, down)
--    print("oncontrol", self, control, down, self.focus)

-- ★★ 焦点门禁（第三次出现：57/106/127）。
-- ⚠ 与 57 行同样的疏漏：★ **不检查 shown**。
--   隐藏但有焦点的控件仍会收到控制码事件。
    if not self.focus then return false end

-- ★ 与 59-61（鼠标）完全同构。
-- ★★ 129 行和 133 行之间没有「自身通用处理」——
--   基类只处理滚动这一件具体的事。
    for k,v in pairs (self.children) do
        if v.focus and v:OnControl(control, down) then return true end
    end

-- ★★★ 滚动事件的**特殊回退**：与 94-96 的 OnFocusMove 回退对应，
--   但多传了一个第三参数 true：
--     `self.parent_scroll_list:OnControl(control, down, true)`
-- 【第三参数 true 的含义】
--   在 ScrollableList:OnControl 的签名里，它表示「来自子控件的转发」
--   ⇒ 列表据此决定是否要**阻止默认滚动**（避免双重滚动）。
-- ★★ 对比 95 行 `parent_scroll_list:OnFocusMove(dir, down)` ——
--   **没有**第三参数。
-- ⚠ 不对称的原因：滚动转发可能引发二次处理，需要标记；
--   导航转发不会。
--   ⚠ 但这构成一个隐式契约：列表的 OnControl 必须接受第三参数。
--   若子类 Screen 覆写了 OnControl 却忘了这个参数，
--   滚轮在列表内会失效。
    if self.parent_scroll_list and (control == CONTROL_SCROLLBACK or control == CONTROL_SCROLLFWD) then
        return self.parent_scroll_list:OnControl(control, down, true)
    end

    return false
end
-- 第二个 ValidateLineNumber，框住 OnControl 的结束（139 = `end` 行）。
ValidateLineNumber(139)

-- ★★ SetParentScrollList —— 反向引用（见 94 行注释的完整分析）。
-- ★ 只有 ScrollableList 给条目控件调用（全库 grep 核实）。
-- ★ 单参数，没有对应的 ClearParentScrollList。
-- ⚠ 结合 325-334 Kill 未清理此引用，构成「悬垂引用」隐患。
function Widget:SetParentScrollList(list)
    self.parent_scroll_list = list
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【IsEditing】—— 递归查找「有没有文本框在编辑」。
-- 【逻辑（145-158）】
--  147-149 自己 editing 就返回 true
--  151-155 任一子节点 IsEditing 为真就返回 true
--  157    否则 false
-- ★★ 读者：frontend.lua:481 的 OnControl 特判（避免退格键被调试渲染抢走）。
-- ★ 与 GetDeepestFocus（592）结构完全相同——
--   都是「深度优先递归 + 提前返回」。
-- ⚠ 同样是**不检查 shown**：隐藏的文本框编辑态仍会被报告。
-- ⚠ 且**无短路优化问题**（找到就return ✓），但无缓存，
--   每次调用都是 O(子树大小)。frontend 只在退格抬起时调，
--   频率极低 ✓。
-- ★ self.editing 字段由子类设置，本文件只在 147 行读取。
--────────────────────────────────────────────────────────────────
function Widget:IsEditing()
    --recursive check to see if anything has text edit focus
    if self.editing then
        return true
    end

    for k, v in pairs(self.children) do
        if v:IsEditing() then
            return true
        end
    end

    return false
end

-- ════════════════════════════════════════════════════════════════
-- 段2/6：★★ 补间动画转发层（160-230）
-- 【八对 Cancel*/xxxTo，结构完全同构】
--   160 CancelScaleTo  / 166 ScaleTo
--   173 CancelMoveTo   / 179 MoveTo
--   186 CancelRotateTo / 192 RotateTo
--   199 CancelTintTo   / 205 TintTo
--   212 ForceStartWallUpdating / 222 ForceStopWallUpdating
-- ★★★ 全部是**转发 + 防御**的组合：
--   转发：self.inst.components.uianim:xxx(...)
--   防御：`if self.inst.components.uianim ~= nil then` /
--         `if not self.inst.components.uianim then self.inst:AddComponent`
-- ★★ 为什么需要防御？构造函数 20 行已经 AddComponent 了。
--   ⚠ 推理：① 构造后组件可能被移除；
--     ② 更可能是**防御性冗余**——模板代码。
--     但它掩盖了一个真实问题：如果组件真的丢了，
--     Cancel* 会**静默无操作**（不重建组件），
--     而 xxxTo 会**重建组件**（丢失旧状态）。
--     ⇒ 两种行为不一致。标注为轻度不一致。
-- ★★ 真正的动画实现在 components/uianim.lua（约 200 行），
--   全部基于 StartWallUpdatingComponent（真实时间墙钟）。
--────────────────────────────────────────────────────────────────
function Widget:CancelScaleTo(run_complete_fn)
-- ⚠ Cancel* 系列只判 `~= nil`，**不补建组件**；
--   而 xxxTo 系列会补建（167/180/193/206/216/226）。
-- ⇒ 组件缺失时两者行为不同。属轻度不一致。
    if self.inst.components.uianim ~= nil then
        self.inst.components.uianim:CancelScaleTo(run_complete_fn)
    end
end

function Widget:ScaleTo(from, to, time, fn)
-- ★ 懒初始化补间组件 —— 因为构造函数已加，这里几乎不会触发。
-- ★★ 注意：重建组件会**丢失所有进行中的动画**。
--   若真的走到这条路，已有动画会被静默中断。
    if not self.inst.components.uianim then
        self.inst:AddComponent("uianim")
    end
    self.inst.components.uianim:ScaleTo(from, to, time, fn)
end

function Widget:CancelMoveTo(run_complete_fn)
    if self.inst.components.uianim ~= nil then
        self.inst.components.uianim:CancelMoveTo(run_complete_fn)
    end
end

function Widget:MoveTo(from, to, time, fn)
    if not self.inst.components.uianim then
        self.inst:AddComponent("uianim")
    end
    self.inst.components.uianim:MoveTo(from, to, time, fn)
end

function Widget:CancelRotateTo(run_complete_fn)
    if self.inst.components.uianim ~= nil then
        self.inst.components.uianim:CancelRotateTo(run_complete_fn)
    end
end

function Widget:RotateTo(from, to, time, fn, infinite)
    if not self.inst.components.uianim then
        self.inst:AddComponent("uianim")
    end
    self.inst.components.uianim:RotateTo(from, to, time, fn, infinite)
end

function Widget:CancelTintTo(run_complete_fn)
    if self.inst.components.uianim ~= nil then
        self.inst.components.uianim:CancelTintTo(run_complete_fn)
    end
end

function Widget:TintTo(from, to, time, fn)
    if not self.inst.components.uianim then
        self.inst:AddComponent("uianim")
    end
    self.inst.components.uianim:TintTo(from, to, time, fn)
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【ForceStartWallUpdating】—— ⚠⚠ 一处「死代码 + 潜在崩溃」。
--
-- 【grep 核实结论】
--   ① components/uianim.lua（235 行）里**没有** ForceStartWallUpdating
--      方法。该组件只有 12 个方法：UpdateWhilePaused / FinishCurrentTint /
--      CancelTintTo / TintTo / FinishCurrentScale / CancelScaleTo / ScaleTo /
--      CancelMoveTo / MoveTo / CancelRotateTo / RotateTo / OnWallUpdate。
--   ② 全库 grep `ForceStartWallUpdating` 仅 3 处命中：widget.lua 的
--      定义（212/219）与 frontend.lua:261 的唯一调用点。
--   ③ 唯一调用点frontend.lua:261 在 `if self.saving_indicator ~= nil`
--      分支内，而 saving_indicator **只在 frontend.lua:197 的
--      `if IsConsole() then` 里创建**。
--   ④ 而本函数 213 行 `if IsConsole() then return end` 会早退。
--
-- 【★ 结论：这条路径恒不可达】
--   saving_indicator 存在 ⟹ IsConsole() ⟹ 213 行早退。
--   ⇒ 219 行在**任何平台都不会执行**。
--
-- 【⚠⚠ 潜在缺陷：若将来这段被搬到 PC 平台，会立刻崩】
--   推理依据：metaclass.lua:6-20 的 __index 找不到该方法时返回 nil，
--   调用 nil 会抛 "attempt to call a nil value"。
--   ⇒ 219 行既调了**不存在的方法**，又把 self 当参数传（见下）。
--   ⇒ 正确的写法应该是 `self.inst:StartWallUpdatingComponent(component)`
--      （这才是 uianim 内部真正使用的接口，见 uianim.lua:50/92/115/143）。
--   ★ 这解释了参数风格的怪异：作者大概以为 uianim 有个接受 self 的
--     ForceStartWallUpdating，实际上抄了一个不存在的签名。
--   ⇒ 标注为 ⚠ 疑似缺陷（死代码掩盖了崩溃），**不改代码**。
--────────────────────────────────────────────────────────────────
function Widget:ForceStartWallUpdating()
    if IsConsole() then
        return --disabled for console
    end
    if not self.inst.components.uianim then
        self.inst:AddComponent("uianim")
    end
-- ⚠⚠ 见212 行的完整分析：
--   ① 被调的 ForceStartWallUpdating 在 components/uianim.lua 中**不存在**
--      （grep 核实，235 行里只有 12 个方法，无此项）。
--   ② 唯一的调用点因IsConsole() 早退而不可达，故缺陷被掩盖。
--   ③ ★ 参数风格与同文件其它转发（170/183/196/209 不传 self）不一致，
--      进一步佐证这里是凭想象写的签名。
--   ⇒ 对比正确写法：components/uianim.lua:50
--     `self.inst:StartWallUpdatingComponent(self)`（无前缀=self 是组件）。
    self.inst.components.uianim:ForceStartWallUpdating(self)
end

-- ★★ ForceStopWallUpdating —— 与 212 完全同构，同一批问题。
--   同样在 IsConsole() 下早退，同样调了不存在的方法。
--   frontend.lua:731 的调用点同样不可达。
function Widget:ForceStopWallUpdating()
    if IsConsole() then
        return --disabled for console
    end
    if not self.inst.components.uianim then
        self.inst:AddComponent("uianim")
    end
    self.inst.components.uianim:ForceStopWallUpdating(self)
end


-- ★★ IsEnabled —— 「计算」出来的有效状态（与 self.enabled 相对）。
-- 【逻辑】自己 enabled && 父级 enabled（递归）。
-- ★★ 与 IsVisible（101-103）完全平行，唯一区别是链上查的是哪个字段：
--   IsVisible  → self.shown（绘制）
--   IsEnabled  → self.enabled（响应）
-- ⇒ 两个正交维度组合出 4 种状态：
--   shown+enabled（正常） / shown+!enabled（灰掉但可见）
--   !shown+enabled（不画但收输入？★见缺陷）/ !shown+!enabled
-- ⚠ 缺陷：!shown 但 enabled 的控件**会收输入** ——
--   因为事件门禁（57/106/127）只查 focus，不查 shown。
--   ⇒ 「隐藏但可点」是可能的。标注为系统性不一致。
-- ★ 唯一读者：widgets/button.lua:62 `if not self:IsEnabled() or not self.focus`
--   —— ★★ 注意按钮**两个都查了**（IsEnabled + focus），但没查 shown！
--   ⇒ 这进一步印证「shown 不参与事件门禁」是全局性的设计选择/遗漏。
function Widget:IsEnabled()
    if not self.enabled then return false end

    if self.parent then
        return self.parent:IsEnabled()
    end

    return true
end

function Widget:GetParent()
    return self.parent
end

-- ★★ GetParentScreen —— 向上找 is_screen 的祖先（**带缓存**）。
-- 【逻辑（247-260）】
--  249-251 有缓存直接返回
--  253-257 while( not parent.is_screen) do parent = parent:GetParent() end
--  258     结果写回 self.parent_screen
--
-- ★★ ⚠⚠ 疑似缺陷：`while` 循环**没有任何终止保护**。
--   若某控件的祖先链里没有 is_screen 标记的节点（例如被AddChild
--   到一个游离控件上，或 parent 为 nil），这个循环会：
--     · parent 为 nil → `parent.is_screen` 索引 nil → 抛错
--     · 环→ 死循环
--   ⇒ 对比 633-636 SetFocusFromChild 里那段防御：
--     if self.parent == nil and not self.is_screen then print(...); print(debugstack()) end
--     ★ 同一文件里，SetFocusFromChild 会检查并报警，GetParentScreen 不检查。
--   ⇒ 这是明确的不一致。标注为 ⚠ 疑似缺陷。
--
-- ★★ 另一个隐患：★ **缓存永不失效**。
--   缓存写入后（258）就再也不检查了。
--   若控件被 RemoveChild（282-289，注意它**只置 child.parent = nil**，
--   **不清理 child.parent_screen**！）再 AddChild 到另一个 Screen 下，
--   ★ parent_screen 仍是**旧屏幕**。
--   ⚠ 推理依据：RemoveChild（282-289）只做三件事——
--     children[child] = nil; child.parent = nil; inst.entity:SetParent(nil)
--     **没有** `child.parent_screen = nil`。
--   ⇒ 这是**确定存在的缓存失效 bug**，机制清晰、推理充分。
--     影响：任何「把控件在两个 Screen 之间搬来搬去」的代码，
--     之后 GetParentScreen 会返回错误（陈旧）的屏幕。
--     参见 frontend.lua:1100-1113 分支 A —— PopScreen 内部会
--     RemoveChild(screen)（screen 自身），若该 screen 被复用，
--     它的后代控件的 parent_screen 缓存全部陈旧。
--────────────────────────────────────────────────────────────────
function Widget:GetParentScreen()
    --check for a cached version
    if self.parent_screen then
        return self.parent_screen
    end

    local parent = self.parent
    while( not parent.is_screen )
    do
        parent = parent:GetParent()
    end
    self.parent_screen = parent
    return self.parent_screen
end

-- GetChildren —— 返回 children 表的**直接引用**（不是拷贝）。
-- ⚠ 返回引用意味着外部可以随意修改控件树，绕过 AddChild/RemoveChild。
--   （Klei 内部常这么用，但这是「信任内部代码」的取舍。）
function Widget:GetChildren()
    return self.children
end

-- ════════════════════════════════════════════════════════════════
-- ★【Enable / Disable】266-274 + 空钩子 276-280
-- 【★ 关键性质：只改自己，不递归】
--★ 这与 SetFadeAlpha（506-514，会递归）、SetCanFadeAlpha（516-524，会递归）
--   形成鲜明对比。
-- ⇒ 为什么Disable 不递归？
--   因为 Enable 有明确的「反向」语义需求：批量启用一批控件时，
--   通常期望「连带子树一起启用」，所以由调用方决定是否逐个调。
-- ⇒ 而 IsEnabled（233）已经做了递归**计算**，所以即使不递归设置，
--   「整棵子树无效」的效果也自动成立。
-- ★★ 这一点很容易搞错：Disable 一个父控件**不需要**递归，
--   因为 IsEnabled 会向上查父级链。✓ 设计是自洽的。
-- 【Enable/Disable 的副作用】调OnEnable / OnDisable 钩子（空实现 276-280）。
--  ⚠ 但**不调** OnShow/OnHide 类的钩子（那是 Hide/Show 的）。
--  ⚠ 也不触发任何焦点变化——★ 被 Disable 的控件可能仍持有焦点，
--    而事件门禁（127）只查 focus 不查 enabled！
--    ⇒ ⚠ 真正被拦住的只有 widgets/button.lua:62（它自己查了 IsEnabled）。
--    ⇒ **通用控件（Widget:OnControl）完全不看 enabled**！
--    这是本文件最大的不一致点，标注为 ⚠ 疑似缺陷（系统性）。
--────────────────────────────────────────────────────────────────
function Widget:Enable()
    self.enabled = true
    self:OnEnable()
end

-- ★★ Disable 的三个动作：enabled=false + OnDisable 钩子。
-- ⚠ 不清焦点（见上）—— 这与「Disable 应当让焦点离开」的直觉相反。
--   ⇒ 焦点可能停在一个已禁用的控件上；
--     此时 84 行的导航判定 `dest.enabled` 会阻止**导航过去**，
--     但**已经在那里的焦点**依然收事件（127 只查 focus）。
--   ⇒ 玩家可能「卡」在一个禁用控件上，方向键也走不动。
--     ⚠ 这是可复现的 UI 卡死场景。标注为 ⚠ 疑似缺陷。
function Widget:Disable()
    self.enabled = false
    self:OnDisable()
end

function Widget:OnEnable()
end

function Widget:OnDisable()
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【RemoveChild】—— 摘除但不销毁。
-- 【三个动作（283-287）】
--  284  self.children[child] = nil        —— 从表里摘掉
--  285  child.parent = nil              —— ★ 清反向指针
--  286  child.inst.entity:SetParent(nil) —— ★ 从实体树上摘掉
-- 【★ 与 Kill（325-334）的区别】
--   RemoveChild：只脱离关系，对象**还能活**，可再被AddChild 挂回去。
--   Kill：脱离 + 销毁实体（333 self.inst:Remove()），**不可复活**。
-- 【★ 三个遗漏（都会造成陈旧状态）】
--  ⚠ ① **不清** child.parent_screen 缓存 —— 见 247 行完整分析。
--  ⚠ ② **不清** child.parent_scroll_list —— 见 94 行分析。
--  ⚠ ③ **不清** child.tooltip / hovertext 等UI 状态字段。
--     （不算 bug，因为它们本就该跨挂载保留。）
-- ⇒ ①② 是可确认的缓存失效路径。
-- ★ frontend.lua:1110 的 PopScreen 内部就调它——所以这是热路径。
--────────────────────────────────────────────────────────────────
function Widget:RemoveChild(child)
    if child then
        self.children[child] = nil
        child.parent = nil
        child.inst.entity:SetParent(nil)
    end

end

-- ★★ KillAllChildren —— 递归销毁全部子控件。
-- 【★ 遍历中删除的安全性（292-295）】
--   `for k,v in pairs(self.children) do self:RemoveChild(k); k:Kill() end`
--   ★ RemoveChild 会 `self.children[k] = nil`（284），
--     **但随后还有一次对已修改表的迭代**。
--   ⇒⚠ 这是「遍历中删除」的标准隐患：Lua 的 pairs 在表被修改后
--     行为未定义（可能跳过元素、可能报错）。
--   ⚠ 但实际上：282RemoveChild(k) 后立刻 k:Kill()，
--     而 Kill（328-330）里又有 `if self.parent then self.parent.children[self] = nil`
--     —— **同一个键被删两次**（第二次是 no-op）。
--   ⇒ 风险：若 pairs 因删除而跳过某个 k，该控件**不会被销毁**，
--     成为泄漏的孤儿实体（仍在实体树上，仍会渲染）。
--   ⇒ 对比 1592-1611（frontend.lua）的正确写法：
--     删除后 i 不自增。这里恰好等价（每次都删当前 k），
--     所以实际是安全的——因为 k 一定会在被删之前被访问。
--     ✅ 重新评估：**这个写法是正确的**（Lua 的 next 语义保证
--     删掉当前 key 不会影响后续迭代）。
--     ⚠ 但仍是危险模式：一旦改成「条件性删除」就会出错。
-- 【★ 297 行 ClearHoverText 的必要性】
--   hovertext_root 是**独立创建**的控件（721 行 new，global_widget），
--   **不在 children 里**！若不单独清理，它会泄漏。
--⇒ 这是对 718-724 那段「attach_to_parent 或独立 root」逻辑的补偿。
--────────────────────────────────────────────────────────────────
function Widget:KillAllChildren()
    for k,v in pairs(self.children) do
        self:RemoveChild(k)
        k:Kill()
    end

-- ★★ ClearHoverText —— 必须显式清理，因为 hovertext_root 不在 children 里。
--   推理依据：708-724 行，hovertext_root 要么是 attach_to_parent 的子控件，
--   要么是一个 global_widget 独立控件。
--   ⇒ 独立的那个**不在 self.children 里**，KillAllChildren 遍历不到。
-- ⇒ 这是一个「结构决定的必然清理点」，写法正确。
    self:ClearHoverText()
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【AddChild】—— 控件树的核心操作（300-309）
-- 【四行做完的事】
--  301-303 若已有父，先从旧父的 children 里摘掉（**自动脱旧**）
--  305     self.children[child] = child   —— ★ 对象键表
--  306     child.parent = self          —— 反向指针
--  307     child.inst.entity:SetParent(self.inst.entity) —— ★ 实体树
--  308     return child                 —— 链式调用支持
--
-- ★★★ 两个层级必须同步 —— 这是本文件最重要的设计约束：
--   ① Lua 控件树：self.children / child.parent
--   ② C++ 实体树：entity:SetParent / MoveToFront
--   ⇒ 301-307 就是在维护**两棵必须一致的树**。
--   ⚠ 任何只改一棵的操作都会造成不一致。
--     RemoveChild（282）两棵都改了 ✓；Kill（328/333）也改了 ✓；
--     ★ 但 33-341 的 GetWorldPosition 依赖 C++ 树正确，
--       而事件分发（59 等）依赖 Lua 树正确。
--       两棵树的失效模式不同 → 症状不同。
--
-- ★★ 301-303「自动脱旧」的正确性：
--   它只从 `child.parent.children` 里摘，**不调 entity:SetParent(nil)**。
--   ⇒ 但紧接着 307 行就SetParent 到新父。
--   ⇒ 等价于「先摘后挂」，比「先 RemoveChild 再 AddChild」更高效。
--────────────────────────────────────────────────────────────────
function Widget:AddChild(child)
    if child.parent then
        child.parent.children[child] = nil
    end

    self.children[child] = child
    child.parent = self
-- ★★ 实体树的父子关系 —— 与 306 行的 Lua 层**成对**维护。
-- ★★★ 为什么实体树这么重要？
--   ① **渲染层级**：MoveToFront 就是「移到父实子的末尾」（64-70）。
--   ② **鼠标命中**：input.lua:516 的 GetEntitiesAtScreenPoint
--      只在 UIRoot（screenroot）子树里拾取，实体树决定「哪些实体可被命中」。
--   ③ **世界坐标**：UITransform:GetWorldPosition 依赖实体树的变换累乘。
-- ⇒ 三个关键能力全部建立在实体树之上。
    child.inst.entity:SetParent(self.inst.entity)
    return child
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【Hide / Show】311-323 —— 存储态，不是计算态。
-- 【★ Hide 的三个动作】
--  312  self.inst.entity:Hide(false)   —— C++ 实体隐藏
--  313  local was_visible = self.shown == true
--  314  self.shown = false              —— Lua 标记
--  315  self:OnHide(was_visible)       —— ★ 钩子带「之前的状态」
-- 【★★ OnHide(was_visible) 的设计值得学习】
--   传入「改变前的状态」而不是「改变后的」，
--   让子类能区分「从可见变不可见」与「本来就不可见再调 Hide」。
--   ⇒ 这类「转换前状态」参数是 UI 框架的通用模式：
--     widgets/screen.lua 没有用，但 widgets/ 里有大量使用。
-- ⚠ 幂等性：连调两次 Hide，第二次 was_visible = false。
--   子类若依赖 was_visible 做一次性初始化，会正确地跳过。✓
-- ★ entity:Hide(false) 的参数 false 的含义：
--   「不递归隐藏子实体」——因为子树由各自的 Hide 状态管理。
--────────────────────────────────────────────────────────────────
function Widget:Hide()
    self.inst.entity:Hide(false)
    local was_visible = self.shown == true
    self.shown = false
    self:OnHide(was_visible)
end

-- ★ Show —— 与 Hide 完全对称。319 的 false 同样不递归。
-- ★★ 313/320 行的 `== true` / `== false` 显式比较：
--   311-316 用 `was_visible = self.shown == true`，
--   318-323 用 `was_hidden = self.shown == false`，
--   ⇒ 两者互补：一次转换的「前态」总会是 true 或 false 之一。
-- ★ 强制 bool 化的写法避免了 nil 传播（若构造被绕过，shown 可能是 nil）。
function Widget:Show()
    self.inst.entity:Show(false)
    local was_hidden = self.shown == false
    self.shown = true
    self:OnShow(was_hidden)
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【Kill】—— 销毁控件（325-334）。六个动作：
--  326  self:StopUpdating()          —— 从前端更新表摘除
--  327  self:KillAllChildren()       —— ★ 递归销毁子树
--  328-330 从父的 children 里摘掉自己
--  331  self.inst.widget = nil       —— ★★ 断开反向指针
--  332  self:StopFollowMouse()      —— 解除鼠标跟随
--  333  self.inst:Remove()          —— ★ 实体销毁（真正死）
--
-- ★★ 331 行断开 inst.widget 是**安全关键**：
--   frontend.lua:933 `if hover_inst and hover_inst.widget then`
--   ⇒ 实体被销毁后 widget 字段为 nil，hover 分支不会取到野控件。
--   若忘了这一行，鼠标悬停在一个已销毁控件的位置会崩。
--   ⇒ 这一行是「G1 焦点指向已销毁控件」在**鼠标侧**的对应防线。
--
-- ★★ 326 StopUpdating 为什么必要？
--   frontend.lua:234 的 updating_widgets 是**弱键表**，理论上
--   控件被 GC 后条目自动消失。但 Kill 时控件可能还被引用，
--   ⇒ 显式摘除避免「已死控件被 OnUpdate 调用」。
--   ★ 这是「弱表兜底 + 显式清理」的双保险。
--
-- ⚠⚠ 三个遗漏（与 RemoveChild 同源）
--  ⚠ ① **不清** self.parent_screen（247 行分析的缓存失效）
--  ⚠ ② **不清** self.parent_scroll_list（94 行分析的悬垂引用）
--  ⚠ ③ ★★ **不清焦点**！若一个持有焦点的控件被 Kill，
--     祖先链上其它控件的 self.focus 仍是 true。
--     ⇒ 焦点链出现「断口」：祖先 focus=true 但叶子已死。
--     ⇒ GetDeepestFocus（592）会下钻到死节点返回它。
--   ⇒ ★★ 这就是缺陷 G1 在**框架层**的机制来源！
--     对比 widgets/screen.lua:35 的 IsValid 检查——那是 Screen 层的
--     事后补救，而框架层没有提供「Kill 时自动清理焦点」的能力。
--   ⇒ 修复建议（不改代码）：Kill 里补self:ClearFocus() 向上传播，
--     或在 GetDeepestFocus 里加 inst.entity:IsValid() 校验。
--────────────────────────────────────────────────────────────────
function Widget:Kill()
-- ★ StopUpdating → frontend.lua:945 StopUpdatingWidget →表里置 nil。
    self:StopUpdating()
    self:KillAllChildren()
    if self.parent then
        self.parent.children[self] = nil
    end
-- ★★ 断开反向指针 —— 见上方完整分析（鼠标侧的安全防线）。
-- ⚠ 注意它在 328-330（摘出父children）**之后**、333（实体销毁）之前。
--   顺序正确：先断 Lua 引用，再死实体。
    self.inst.widget = nil
    self:StopFollowMouse()
    self.inst:Remove()
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【坐标三套·第一套：世界坐标】336-350
-- 【★ 三套坐标的完整对照（本文件的核心知识点）】
--  ┌────────────┬──────────────────┬───────────────────────────┐
--  │ 函数       │ 语义             │ 依赖                       │
--  ├────────────┼──────────────────┼───────────────────────────┤
--  │ GetPosition│ **局部**（相对父） │ UITransform:GetLocalPosition│
--  │  (340)     │ ★ 布局用这个      │ ★ 只受自身影响            │
--  │ GetWorldPos│ **世界**（屏幕）  │ UITransform:GetWorldPosition│
--  │  (336)     │ ★ 定位用这个      │ ★ 累乘整条祖先链的变换    │
--  │ GetLocalPos│ 局部（368 重复） │ ★ 与 GetPosition 等价      │
--  │  (358)     │ ⚠ 冗余别名        │                            │
--  └────────────┴──────────────────┴───────────────────────────┘
-- ★★ 336 与 340 对**同一个控件**会返回不同值——只要它有父级。
--   根控件（parent == nil）两者相同。
-- ★ 三处读者印证了这个区别的重要性：
--   · 764/787 SetHoverText 用 **World**（要屏幕绝对位置）；
--   · 778-782 手工做 `world - parent_world` 再除以 parent_scale
--     —— ★ 就是因为要的是**父局部坐标**，而框架只提供了世界坐标。
--   · widgets/button.lua:68 用 GetLocalPosition（要相对偏移）。
--────────────────────────────────────────────────────────────────
function Widget:GetWorldPosition()
    return Vector3(self.inst.UITransform:GetWorldPosition())
end

-- ★★ GetPosition —— 局部位置。★ 布局操作用它（与父无关）。
-- ⚠ 命名误导：叫 GetPosition 但返回**局部**坐标；
--   想拿全局的得知道还有 GetWorldPosition。
-- ⚠ 与 358 GetLocalPosition **完全等价**（同一个 C++ 接口）。
--   ⇒ 两个名字两个函数返回同样的东西，纯冗余。
--★ 两者都 return Vector3(...) 而非多返回值 ——
--   多一个包装对象分配。Nudge（352）每次调GetLocalPosition 都分配。
function Widget:GetPosition()
    return Vector3(self.inst.UITransform:GetLocalPosition())
end

-- ★★ GetPositionXYZ —— 唯一返回**裸三元组**（x, y, z）而非 Vector3 的。
-- 【为什么需要它】
--   ⇒ **性能**。Vector3 是 userdata，每次分配都有成本；
--     回调密集处（如每帧的位置更新）用裸三元组更快。
-- ★ 与 362SetPosition 的双签名（number 或 Vector3）配对使用。
-- ★ 这是「热路径避免 userdata 分配」的典型优化。
function Widget:GetPositionXYZ()
    return self.inst.UITransform:GetLocalPosition()
end

-- GetWorldScale —— 世界缩放（累乘）。与 548 GetScale 语义不同，
--   那个会额外与**Lua 层**的父缩放相乘（551 行）。
-- ⚠ 两个缩放函数：UITransform 层的 vs Lua 手动递归的。
--   为什么不能都靠 UITransform？⇒ 见 548 行分析。
function Widget:GetWorldScale()
    return Vector3(self.inst.UITransform:GetWorldScale())
end

-- ★★ Nudge(offset) —— 「按当前局部位置平移」。
-- 【它解决的真实问题】
--   ★ UI 里大量操作是**相对**的：「按钮按下时往下偏 3 像素」、
--   「拖动时跟着鼠标走」、「面板往下挪一点」。
--   若每次都写 `self:SetPosition(self:GetPosition() + delta)`
--   会有两个问题：① 重复读位置（可能已被子物体改动）；
--   ② Vector3 的运算符重载在 DST 里是自定义的（vector3.lua）。
-- ⇒ Nudge 把这个模式固化成一行。
-- ★ 使用者：widgets/button.lua:69 `self:SetPosition(self.o_pos + self.clickoffset)`
--   —— 它没直接用 Nudge，而是自己实现了等价逻辑（因为要先存 o_pos）。
-- ⚠ 353 行 `local o_pos = self:GetLocalPosition()` 每次分配 Vector3。
--   高频调用（如 613 OffsetCursor 每帧）会有 GC 压力。
function Widget:Nudge(offset)
    local o_pos = self:GetLocalPosition()
    local n_pos = o_pos + offset
    self:SetPosition(n_pos)
end

-- ★ GetLocalPosition —— 与 340 GetPosition 等价。
-- ★★ 命名更准确（Local vs 无修饰），所以 352 Nudge 用了它。
--   ⇒ 340 那个才是历史遗留。
function Widget:GetLocalPosition()
    return Vector3(self.inst.UITransform:GetLocalPosition())
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【SetPosition】—— 双签名入口（362-371）
-- 【两种调用形态】
--  363-364 SetPosition(x, y, z)        —— 裸三元组，z 默认 0
--  365-370 SetPosition(vec3)           —— Vector3
-- 【★★ 366-368 是一段「防御性调试」】
--   if not self.inst:IsValid() then print(debugstack()) end
--   ★ 作者知道这里会崩（对已销毁实体调 UITransform:SetPosition），
--     于是加了 IsValid 检查 + 打印调用栈——但**打完栈还是继续执行**！
--   ⇒ 只是「打印得更详细」，并不能阻止崩溃。
-- ⚠⚠ 这是典型的「诊断代码代替修复」：
--   正确做法是 `if not valid then return end` 或警告后跳过。
--   ⇒ 标注为 ⚠ 疑似缺陷（诊断缺失 return）。
-- ★★ 434-440 SetTooltipPos 里有**完全相同**的片段，
--   同样的问题。同一文件里两处犯同样的错，说明是复制粘贴。
--────────────────────────────────────────────────────────────────
function Widget:SetPosition(pos, y, z)
    if type(pos) == "number" then
        self.inst.UITransform:SetPosition(pos, y, z or 0)
    else
        if not self.inst:IsValid() then
            print(debugstack())
        end
-- ⚠ 369 行 `self.inst.UITransform:SetPosition(pos:Get())` ——
--   ★ 加了 IsValid 检查（367）**却仍然执行**，若实体无效会崩。
--   ⇒ 见 362 行分析：诊断代替修复。⚠ 疑似缺陷。
-- ★★ 与 344 GetPositionXYZ 的裸三元组对称：
--   363-364 收三元组、369 拆三元组，两处互为逆运算。
--   ★ 所以 344 存在的意义就是让 369 这条路径更快（免去 Vector3）。
        self.inst.UITransform:SetPosition(pos:Get())
    end
end

-- SetRotation / GetRotation —— 旋转。UI 用得少（几乎只有提示框）。
-- ★ 旋转配合 348 GetWorldScale 一起构成完整的变换三元组。
function Widget:SetRotation(angle)
    self.inst.UITransform:SetRotation(angle)
end

function Widget:GetRotation()
    return self.inst.UITransform:GetRotation()
end

-- ★★ SetMaxPropUpscale(val) —— UI 的最大放大倍数上限。
-- 【为什么需要】
--   4K 屏上 HUD 会按 1241-1243 的 res_scale 放大好几倍，
--   贴图（尤其是像素风的字体与小图标）会被放大到模糊。
--   ⇒ MaxPropUpscale 给「按比例缩放」设一个天花板，
--     超过就不再放大（多余的画布留白）。
-- ★ 使用者：frontend.lua:205 的 saving_indicator:SetMaxPropUpscale(MAX_HUD_SCALE)。
-- ★★ 只有存档指示器用了它 —— 说明「HUD 大多数元素不怕模糊」
--   （因为它们是矢量化渲染的文字或高分辨率贴图）。
--   ⇒ 这是按需优化，不是全局策略。
function Widget:SetMaxPropUpscale(val)
    self.inst.UITransform:SetMaxPropUpscale(val)
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【SetScaleMode】—— 「没有布局引擎」的另一半。
-- 【五种模式（constants.lua:83-87，含原注释）】
--  SCALEMODE_NONE = 0
--  SCALEMODE_FILLSCREEN = 1 --stretch art to fit/fill window
--  SCALEMODE_PROPORTIONAL = 2 --preserve aspect ratio (picks the smaller
--                                of horizontal/vertical scale)
--  SCALEMODE_FIXEDPROPORTIONAL = 3 --same as SCALEMODE_FIXEDSCREEN_NONDYNAMIC,
--                                    except for safe area on consoles
--  SCALEMODE_FIXEDSCREEN_NONDYNAMIC = 4 --scale same amount as window
--                                        scaling from 1280x720
-- 【★ 三种思路】
--  · 跟随窗口：FILLSCREEN / PROPORTIONAL（相对当前分辨率）
--  · 固定基准：FIXEDSCREEN_NONDYNAMIC（相对 1280x720）
--  · 折中：FIXEDPROPORTIONAL（固定基准 + 主机安全区）
-- ★★ 「没有布局引擎」的准确含义就在这个函数上：
--   框架提供的定位能力只有「锚点 + 缩放模式」两个旋钮，
--   **没有任何尺寸协商、没有内容测量回流、没有对齐容器**。
--   ⇒ 想要「按钮排成一排且间距自适应」？
--     只能自己在 OnUpdate 里算好每个按钮的 SetPosition。
--   ★ 参见 widgets/scrollablelist.lua —— 滚动列表的位置计算全靠手算。
--────────────────────────────────────────────────────────────────
function Widget:SetScaleMode(mode)
    self.inst.UITransform:SetScaleMode(mode)
end

-- ★ SetScale —— 同样是双签名（单值 / Vector3）。
-- ★★ 390-391 的单值分支：`SetScale(pos, y or pos, z or pos)`
--   ⇒ ★ 关键设计：只给一个数时**三个轴用同一个值**（均匀缩放）。
--   ⇒ 所以 SetScale(2) 等价于 SetScale(2,2,2)，最常用。
-- ★ 393 的 Vector3 分支逐分量取。
-- ⚠ 与 SetPosition 不同：这里没有 IsValid 防御。
--   ⇒ 不一致（362 有防御，389 没有）。轻微瑕疵。
function Widget:SetScale(pos, y, z)
    if type(pos) == "number" then
        self.inst.UITransform:SetScale(pos, y or pos, z or pos)
    else
        self.inst.UITransform:SetScale(pos.x,pos.y,pos.z)
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★【事件回调挂载】397-414 —— 三函数组合
--  397 HasCallback(event)      —— 有没有挂
--  401 HookCallback(event, fn)  —— 挂（**单槽**，不是多播）
--  409 UnhookCallback(event)    —— 摘
-- 【★★ 401-407 的「单槽」语义（关键设计）】
--   if self.callbacks[event] then
--       self.inst:RemoveEventCallback(event, self.callbacks[event])
--   end
--   self.callbacks[event] = fn
--   self.inst:ListenForEvent(event, fn)
-- ★★ 每次 Hook 都先摘掉旧的 → **同一个事件只能挂一个回调**。
-- ⇒ 这是「覆盖」而非「追加」。
-- ⚠ 若外部误以为可以多次 Hook 累积多个回调，会静默丢失。
-- ★ 正确做法：外部自己包一个分发函数。
--   这与 Widget 自己的事件分发（59/129 等）**完全不同**——
--   那些是「向子控件递归」，这个是「挂到实体事件总线上」。
--   ⇒ 两种「回调」的语义要分清。
--────────────────────────────────────────────────────────────────
function Widget:HasCallback(event)
	return self.callbacks[event] ~= nil
end

-- ★★ 「单槽」语义 —— 见上方分析。注意 403 的精确配对：
--   RemoveEventCallback 用的是**同一个函数对象**，
--   而事件系统按函数引用匹配 ✓。
-- ★ 所以「重新 Hook」是幂等安全的（不会累积）。
-- ⚠ 副作用：外部无法知道自己的回调被覆盖了。
function Widget:HookCallback(event, fn)
    if self.callbacks[event] then
        self.inst:RemoveEventCallback(event, self.callbacks[event])
    end
    self.callbacks[event] = fn
    self.inst:ListenForEvent(event, fn)
end

-- ★ UnhookCallback —— 410-413 三重判空，407 的逆操作。
-- ★★ 未挂时静默返回（不报错）—— 符合「幂等清理」惯例。
-- ⚠ 但**没有**对应「Kill 时自动摘除所有回调」的逻辑（325-334）。
--   ⇒ 依赖实体 Remove（333）时事件系统自动清理。
--   ⇒ 合理：实体死了，事件总线也不会再发给它。
function Widget:UnhookCallback(event)
    if self.callbacks[event] then
        self.inst:RemoveEventCallback(event, self.callbacks[event])
        self.callbacks[event] = nil
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【SetHAnchor / SetVAnchor】416-422 —— 锚点定位的两个旋钮
-- 【★ Anchor 的语义（★ 这是最容易搞错的部分）】
--   Anchor 回答的是：「**这个控件的区域，贴父级的哪一点**」。
--   取值（constants.lua:77-81）：
--     ANCHOR_MIDDLE = 0 / ANCHOR_LEFT = 1 / ANCHOR_RIGHT = 2
--     ANCHOR_TOP   = 1 / ANCHOR_BOTTOM = 2
--   ★★ 注意 79 与 80 行：**左右与上下共用同一套数值**（1 和 2）。
--     所以 SetHAnchor(ANCHOR_TOP) 在语义上是错的（虽然能工作）。
--     ⇒ 这是 DST 锚点 API 的固有混淆点。
-- 【★ 三个正交概念（务必分清）】
--   ① Anchor（本函数）—— 区域贴父级哪一点
--   ② Align（Text/Image 自己的 SetHAlign/SetVAlign）—— 内容在区域内怎么排
--   ③ RegPoint（widgets/image.lua:154-158）—— 贴图自身哪一点对齐到 Anchor
-- ★★ 三者独立，共同决定最终位置。示例见 frontend.lua:52-62 的完整注释。
-- ★ Align 本文件**没有**暴露（只有 Image/Text 自己有）。
--────────────────────────────────────────────────────────────────
function Widget:SetVAnchor(anchor)
    self.inst.UITransform:SetVAnchor(anchor)
end

function Widget:SetHAnchor(anchor)
    self.inst.UITransform:SetHAnchor(anchor)
end

-- OnShow / OnHide —— 空钩子（基类）。
-- ★ 与 276-280 的 OnEnable/OnDisable、120 的 OnStopForceProcess
--   一起构成 Widget 的**五个空钩子**。
-- ★★ 设计模式：模板方法（Template Method）。
--   框架在恰当时机调用，子类填实现。
-- ★ 被 Hook 的位置：311-316（Hide）与 318-323（Show）传入 was_* 状态。
function Widget:OnShow(was_hidden)
end

function Widget:OnHide(was_visible)
end

-- ════════════════════════════════════════════════════════════════
-- ★【Tooltip 三件套】430-483 —— 与焦点系统深度耦合
--  430 SetTooltip(str)             —— 设文本
--  434 SetTooltipPos(pos,y,z)      —— 设位置
--  445 SetTooltipColour(r,g,b,a)   —— 设颜色
--  449 GetTooltipColour()          —— ★ 查询（带子控件下钻）
--  461 GetTooltip()                —— ★ 查询（带子控件下钻）
--  473 GetTooltipPos()             —— ★ 查询（带子控件下钻）
-- 【★★ 三个 Get 的统一模式（449-483）】
--   if self.focus then                       —— ★ 没焦点就返回 nil
--     for k,v in pairs(self.children) do     —— 问子控件
--       local x = k:GetXxx()
--       if x ~= nil then return x end        —— ★ 任一有就返回
--     end
--     return self.xxx                        —— 否则用自己的
--   end
-- ★★ 与事件分发的模式对比：
--   事件分发：**自己没焦点就 return false**（门禁）
--   Tooltip查询：**自己没焦点就 return nil**（门禁）
--   ⇒ 完全一致。焦点是所有交互查询的统一门禁。
-- ★★ tooltip 是**沿焦点链求值**的：焦点在哪个叶子，就用哪个的 tooltip。
--   参见 frontend.lua:332-363 GetHelpText 的同类逻辑（手柄提示条）。
-- ⚠ 与 449 相比，461 GetTooltip 用了 `if str ~= nil` 而 450 用 `if col ~= nil`
--   —— 一致 ✓。
--────────────────────────────────────────────────────────────────
function Widget:SetTooltip(str)
    self.tooltip = str
end

function Widget:SetTooltipPos(pos, pos_y, pos_z)
    if type(pos) == "number" then
        self.tooltip_pos = Vector3(pos, pos_y, pos_z)
    else
-- ⚠ 438-440 与 366-368 **完全相同**的缺陷：
--   `if not self.inst:IsValid() then print(debugstack()) end`
--   然后**继续执行** 441 行 `self.tooltip_pos = pos`。
-- ⚠⚠ 这里更严重：赋值给 self 不访问实体，所以**不会崩** ——
--   说明这个 IsValid 检查是**从 SetPosition（366）复制来的**，
--   在这里根本不需要（不访问 inst）。
-- ⇒ 属于「无意义的防御 + 误导性的调试输出」。
-- ⇒ 对比 445 SetTooltipColour —— 纯 Lua 赋值，**没有**这个检查。
--   ⇒ 同一功能块内三个 setter 的防御风格不一致。⚠ 轻度瑕疵。
        if not self.inst:IsValid() then
            print(debugstack())
        end
        self.tooltip_pos = pos
    end
end

function Widget:SetTooltipColour(r, g, b, a)
    self.tooltipcolour = { r, g, b, a }
end

-- ★★ GetTooltipColour —— 「沿焦点链求值」模板的范例。
-- ★ 450 行 `if self.focus then` —— 没焦点返回 nil（隐式）。
-- ★ 451-456 遍历子控件，任一有颜色就返回（深度优先）。
-- ★★ 依赖「最多一个子控件有焦点」的不变量 → 只会有一个非nil 结果。
-- ⇒ 短路是有意义的（若不保证互斥，这个函数就没有确定结果）。
function Widget:GetTooltipColour()
    if self.focus then
        for k, v in pairs(self.children) do
            local col = k:GetTooltipColour()
            if col ~= nil then
                return col
            end
        end
        return self.tooltipcolour
    end
end

-- ★ GetTooltip —— 同 449 结构，只是取 str。
-- ★★ 消费者在 widgets/ 之外（由具体 UI 调用），本文件只提供机制。
function Widget:GetTooltip()
    if self.focus then
        for k, v in pairs(self.children) do
            local str = k:GetTooltip()
            if str ~= nil then
                return str
            end
        end
        return self.tooltip
    end
end

-- ★★ GetTooltipPos —— 同结构。注意**没有**判空保护在 473：
--   `if self.focus then` 之后的 481 `return self.tooltip_pos`
--   ⇒ 可能返回 nil（若从未 SetTooltipPos）。
-- ⚠ 三个 Get 里只有它返回的是「可能为 nil 的 Vector3」，
--   消费方需要判空。
function Widget:GetTooltipPos()
   if self.focus then
        for k, v in pairs(self.children) do
            local t_pos = k:GetTooltipPos()
            if t_pos ~= nil then
                return t_pos
            end
        end
        return self.tooltip_pos
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【StartUpdating / StopUpdating】485-491 —— 性能关键
-- 【★ 为什么需要这套机制】
--   每个 Widget 都是一个实体（贵）；一个界面几百个控件。
--   若每帧递归整棵控件树调 OnUpdate，CPU 会爆。
--   ⇒ 框架采用「**按需注册**」：
--     Widget:StartUpdating() → frontend.lua:941 加入弱键表
--     frontend.lua:883-892 每帧遍历该表调 OnUpdate
-- 【★ 实例：widgets/button.lua:71-73】
--   `if self.whiledown then self:StartUpdating() end`
--   —— 只有「按住不放」时才注册（用于持续触发）。
--   ★ widgets/button.lua:95 的原注释：
--     "-- Will only run if the button is manually told to start updating:
--      we don't want a bunch of unnecessarily updating widgets"
-- 【★★ 弱键表的隐藏语义（frontend.lua:234）】
--   setmetatable({}, {__mode="k"}) —— 控件被 GC 后自动移除。
--   ⚠ 但 GC 时机不确定 ⇒ 「控件被移除引用但仍在更新表里」可能持续若干帧。
--   ⇒ 331 行 Kill 里的 326 StopUpdating 是显式清理 ✓。
--────────────────────────────────────────────────────────────────
function Widget:StartUpdating()
    TheFrontEnd:StartUpdatingWidget(self)
end

function Widget:StopUpdating()
    TheFrontEnd:StopUpdatingWidget(self)
end

-- ════════════════════════════════════════════════════════════════
-- ★【一段被整体注释掉的 Update】493-504 —— 重要的历史信息
-- 【★ 注释里的实现是「递归遍历整棵树」】
--   for k, v in pairs(self.children) do
--     if v.OnUpdate ~= nil or #v.children > 0 then v:Update(dt) end
--   end
-- 【★ 现在的实现（485-491 + frontend.lua:883-892）是「注册制」】
--   ⇒ ★ 这段被注释的代码记录了**从递归改为注册制的重构**。
-- ★★ 为什么改？
--   ① 性能：递归遍历 N 个控件 = 每帧 N 次函数调用（大部分 no-op）；
--      注册制只有需要更新的才被调。
--   ② ★ 更重要：`if v.OnUpdate ~= nil or #v.children > 0` 这个条件
--      仍要遍历每个节点才能判断 ⇒ 省不掉遍历本身。
--   ⇒ 注册制是**质的改进**（从 O(N) 到 O(M)，M << N）。
-- ★★ 保留注释是好习惯：后人能知道「为什么这里没有 Update」。
--   否则很可能有人「好心」把这段取消注释，导致性能回退。
--────────────────────────────────────────────────────────────────
--[[function Widget:Update(dt)
    if not self.enabled then return end
    if self.OnUpdate ~= nil then
        self:OnUpdate(dt)
    end

    for k, v in pairs(self.children) do
        if v.OnUpdate ~= nil or #v.children > 0 then
            v:Update(dt)
        end
    end
end--]]

-- ════════════════════════════════════════════════════════════════
-- ★★ 【SetFadeAlpha】—— 递归改透明度的唯一入口（506-514）
-- 【★★ 两个守卫】
--  507  if not self.can_fade_alpha then return end   —— ★ 我不参与
--  509-513 if not skipChildren then 递归子节点       —— ★ 子节点也改
-- 【★★ can_fade_alpha 是「不可恢复」的开关】
--   28 行初始化为 true；517 SetCanFadeAlpha 可改。
--   ⚠⚠ 一旦某个控件 can_fade_alpha = false，
--     **frontend.lua:591-598 的 alpha 淡出收尾恢复不了它**
--     （那里调的正是 SetFadeAlpha(1)，会被 507 拦掉）。
--   ⇒ 这就是 frontend.lua:1029-1031 官方警告的**机制层根因**：
--     "it leaves your screen's widgets at alpha 0 when it's finished"。
-- 【★ skipChildren 参数的两用】
--   · frontend.lua:594-596 调 v:SetFadeAlpha(1) 时**没传** skipChildren
--     ⇒ 会递归（意图是恢复整棵子树）✓
--   · 594 的 `for k,v in pairs(screen.children)` 只遍历**直接子节点**，
--     但 SetFadeAlpha 自己会递归 ⇒ 实际上是全子树 ✓ 正确。
--   ⇒ 511 行把 skipChildren **原样传递**给子节点，
--     而不是清掉它 —— ★ 这是正确的（保持调用者的意图）。
--────────────────────────────────────────────────────────────────
function Widget:SetFadeAlpha(alpha, skipChildren)
    if not self.can_fade_alpha then return end

    if not skipChildren and self.children then
        for k,v in pairs(self.children) do
            v:SetFadeAlpha(alpha, skipChildren)
        end
    end
end

-- ★★ SetCanFadeAlpha —— 递归设置「是否允许淡入淡出」。
-- 【★ 519-523 的递归与 509-513 同构，skipChildren 同样透传】
-- ★★ 用法模式：`SetCanFadeAlpha(false)` 关掉整棵子树的淡入淡出。
--   典型场景：某个面板需要「完全不参与全局淡出淡入」。
-- ⚠⚠ **强烈建议**：不要在 alpha 淡出**进行中**调用本函数，
--   因为关掉的控件无法被 591-598 恢复。
--   ⇒ 标注为「使用陷阱」，非代码缺陷。
function Widget:SetCanFadeAlpha(fade, skipChildren)
    self.can_fade_alpha = fade

    if not skipChildren and self.children then
        for k,v in pairs(self.children) do
            v:SetCanFadeAlpha(fade, skipChildren)
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【SetClickable】—— 「实体级点击开关」（526-528）
-- ★★ 它做的是 `self.inst.entity:SetClickable(val)` ——
--   ★ 改的是**实体在 C++ 命中测试中的参与性**，不是 Lua 侧的 focus。
-- 【★ 与 focus 的区别（极重要）】
--  · SetClickable(false) → 鼠标点不到（不进 entitiesundermouse）
--  · focus = false         → 收不到事件（Lua 侧门禁）
--   ⇒ ★★ 一个控件可以被点到（有焦点）但点击不生效（不可点击）。
-- 【★ 使用者：frontend.lua 的全部浮层】
--   84/94/106/118/128/132/142/146 —— 8 个遮罩全部 SetClickable(false)。
--   ⇒ 否则淡出遮罩会挡住整个屏幕的点击！
-- 【⚠ 与 160 行的对照（一个反例）】
--   frontend.lua:160 `helptextbg:SetClickable(false)` 被**注释掉了**，
--   注释里没有说明原因（推测：需要 hover）。
--   ⇒ 结果是提示条背景会吃掉该区域的点击。⚠ 已在 frontend 标注。
-- 【★ 谁调SetClickable(true)？grep 核实 widgets/ 内有大量调用。
--   典型：ImageButton 的启用/禁用态切换。
--────────────────────────────────────────────────────────────────
function Widget:SetClickable(val)
    self.inst.entity:SetClickable(val)
end

-- ★★ UpdatePosition(x, y) —— 内部专用的位置设置（固定 z=0）。
-- 【唯一读者】534-539 FollowMouse 的回调。
-- ★ 为什么单独包一层而不是直接 SetPosition(x,y,0)？
--   → 回调签名 (x, y) 需要匹配 AddMoveHandler 的签名，
--     所以需要一个「二元 → 三元」的适配器。
-- ⇒ 典型的「回调签名适配」薄封装。
function Widget:UpdatePosition(x, y)
    self:SetPosition(x, y, 0)
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【FollowMouse / StopFollowMouse】534-546 —— 鼠标捕获与拖放
-- 【★ 这就是 UI 层的「拖放」机制】
--  535  followhandler 为 nil 时才注册（幂等）
--  536  TheInput:AddMoveHandler(function(x,y) self:UpdatePosition(x,y) end)
--  537  SetPosition(TheInput:GetScreenPosition()) —— 立即定位一次
-- 【★★ 与拖放的关系（DST 的拖放不是「拖图片」）】
--   DST 的拖放实现是：**创建一个跟随鼠标的 Widget**，
--   拖动时把它挪到鼠标下，松开时检测落点。
--   ⇒ 典型实现见 widgets/inventorybar.lua 的「光标物品」机制
--     （GetCursorItem / CursorLeft / OffsetCursor 等）。
--   ★ 所以「鼠标捕获」在本游戏里= 「让某控件锁死跟随鼠标」，
--     而不是浏览器那种「抓住鼠标按钮直到松开」的捕获。
--   ⚠ ⇒ 推论：游戏里**没有** SetCapture/ReleaseCapture 概念。
--     光标不会被锁在窗口内，拖出窗口就丢了。
--     对比 517? MOUSE_SCROLL_REPEAT_TIME 处的滚轮判断也是这个思路。
-- 【★ 537 行 GetScreenPosition 的来源】input.lua:246-249，
--   它把 TheSim:GetPosition()（屏幕坐标）包成 Vector3。
--   ★ 注意是**屏幕**坐标，与 UITransform 的坐标系一致 ✓。
--────────────────────────────────────────────────────────────────
function Widget:FollowMouse()
    if self.followhandler == nil then
-- ★★ 闭包捕获 self —— 注册后返回的 handler 被存进 535 的 followhandler。
-- ★ StopFollowMouse（541-546）用 `:Remove()` 注销。
-- ⚠ ★★ 545 行 Remove 后置 nil ✓ 正确（可重复调用）。
-- ⚠ 但**循环引用**：闭包捕获 self，handler 存在 self 上 ——
--   self.followhandler → 闭包 → self。
--   ⇒ GC 的标记-清除能处理循环 ✓ 不会泄漏。
--   ⇒ ★ 这也正是 Kill（332）必须调 StopFollowMouse 的原因：
--     否则 handler 还注册在 TheInput 的事件表里，
--     会**永远**对已销毁的控件调 UpdatePosition！
--   ⇒ 332 行是安全关键，不是可选清理。★
        self.followhandler = TheInput:AddMoveHandler(function(x, y) self:UpdatePosition(x, y) end)
-- ★ 立即定位一次 —— 否则控件会在 (0,0) 停留一帧才跳到鼠标处。
-- ★★ 这体现了「注册 + 立即生效」的完整生命周期。
        self:SetPosition(TheInput:GetScreenPosition())
    end
end

-- ★★ StopFollowMouse —— 注销鼠标跟随。
-- 【★ 两个读者】
--  541 定义
--  332 Kill 里调用 —— ★ 安全关键（见 536 行分析）
-- ⚠ 若某个控件调了 FollowMouse 但没走 Kill（比如只是 RemoveChild），
--   handler 会继续存在 → 对已脱树的控件调 SetPosition。
--   ⚠ RemoveChild（282-289）**没有**调 StopFollowMouse。
--   ⇒ 与 282 行分析的其他三个遗漏同源，构成第 4 个。
function Widget:StopFollowMouse()
    if self.followhandler ~= nil then
        self.followhandler:Remove()
        self.followhandler = nil
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【GetScale vs GetLooseScale】548-559 —— 缩放的两套算法
-- 【548GetScale：Lua 层手动递归累乘】
--   if self.parent ~= nil then
--     local sx,sy,sz = self.inst.UITransform:GetScale()   —— 自身
--     local scale = self.parent:GetScale()                 —— ★ 递归问父
--     return Vector3(sx*scale.x, sy*scale.y, sz*scale.z)
--   end
--   return Vector3(self.inst.UITransform:GetScale())
-- 【★ 为什么不用 UITransform:GetWorldScale（348 行）？】
--   ⇒ ★★ 因为**布局用的缩放**与**渲染用的缩放**不是一回事：
--     控件的 LayoutScale 受 SCALEMODE 影响（385行），
--     而 UITransform:GetScale() 是纯缩放系数；
--     两者相乘才是「这个控件实际显示多大」。
--   ⇒ 348 行的 WorldScale 不含 scaleMode 的影响，
--     548 行的 Lua 递归**包含**它（因为 GetScale 拿的是 UITransform 的）。
-- ⚠ 但 548 的实现有性能问题：
--   ★ 每次调用都是**O(树深)** 的递归，且**没有缓存**。
--   ⇒ 在深度嵌套的 UI 里频繁调用会累积。
--   ⇒ 778-782 SetHoverText 里就调了 GetScale（779行）。
-- 【557 GetLooseScale：只返回自身】
--   return self.inst.UITransform:GetScale()  —— ★ 无递归
--   ⇒ 「Loose」= 松散的、不含祖先的。
-- ★ 命名反直觉：GetScale（含祖先）vs GetLooseScale（不含）。
--   通常「Loose」意味着更宽松/更完整，这里恰好相反。
--────────────────────────────────────────────────────────────────
function Widget:GetScale()
    if self.parent ~= nil then
        local sx, sy, sz = self.inst.UITransform:GetScale()
        local scale = self.parent:GetScale()
        return Vector3(sx * scale.x, sy * scale.y, sz * scale.z)
    end
    return Vector3(self.inst.UITransform:GetScale())
end

function Widget:GetLooseScale()
    return self.inst.UITransform:GetScale()
end

-- ════════════════════════════════════════════════════════════════
-- 段 4/6：★★★ 焦点管理（561-706）—— 本文件的核心章节
--
-- 【★ 六个函数的分工】
--  563 OnGainFocus / 566 OnLoseFocus  —— 空钩子
--  569 SetOnGainFocus / 573 SetOnLoseFocus —— ★ 挂函数式回调
--  577 ClearFocusDirs / 583 SetFocusChangeDir —— ★ 导航图维护
--  592 GetDeepestFocus  —— ★ 查「焦点链末端」
--  604 GetFocusChild    —— ★ 查「焦点链下一段」
--  615 ClearFocus       —— ★ 失焦（向下传播）
--  632 SetFocusFromChild —— ★★ 获焦（向上冒泡 + 清兄弟）
--  659 SetFocus        —— ★★ 获焦（入口）
--
-- ★★ 焦点模型的完整表述（务必记住）：
--   焦点是一条**从根到叶的唯一路径**，路径上每个节点 focus=true。
--   · 获焦 = SetFocus（从目标开始向上冒泡，同时清兄弟）
--   · 失焦 = ClearFocus（从当前节点向下递归清）
--   · 查询 = GetDeepestFocus（从根往下钻到底）
--   ⇒ 不是「一个全局指针」，是「一棵被标记的子树」。
--────────────────────────────────────────────────────────────────
---------------------------focus management

-- ★★ OnGainFocus / OnLoseFocus —— 两个空钩子。
-- 【★★ 与「设置回调」的双轨制】
--   路径A：覆写方法 —— 子类写 `function MyWidget:OnGainFocus()`
--           （widgets/button.lua:105 就是这么做的）
--   路径B：挂函数   —— SetOnGainFocus(fn)（569 行）
-- ⇒ ★★ 两者都会在 646/674 行被调用，**且都会执行**：
--      646/674 `if self.OnGainFocus then self:OnGainFocus() end`
--      649/675 `if self.ongainfocusfn then self.ongainfocusfn() end`
--   ★ 二者无冲突（方法与字段名不同：OnGainFocus vs ongainfocusfn）。
--   ⇒ 但 776-799 SetHoverText **直接覆写了 self.OnGainFocus**！
--     它会**替换**掉子类的方法实现。
--     ⚠ 详见 773-775 的分析：那里用 _OnGainFocus 备份原方法。
function Widget:OnGainFocus()
end

function Widget:OnLoseFocus()
end

-- ★★ SetOnGainFocus(fn) —— 挂「获得焦点」的回调。
-- 【与覆写 OnGainFocus 方法的区别】
--  · 覆写方法：子类实现，**可能覆盖**基类逻辑
--  · 挂函数  ：外部注入，与方法**并存**（646 + 649 都会跑）
-- ★ 669/674 行两处都会执行。
-- ⚠ 669行存的字段名是 `ongainfocusfn`（小写 o 开头），
--   与方法名 OnGainFocus 区分开。命名有点隐晦。
function Widget:SetOnGainFocus( fn )
    self.ongainfocusfn = fn
end

-- SetOnLoseFocus —— 与 569 对称。621/622 行被调用。
function Widget:SetOnLoseFocus( fn )
    self.onlosefocusfn = fn
end

-- ════════════════════════════════════════════════════════════════
-- ★【ClearFocusDirs】—— 清空导航图。
-- 【★ 清三样东西】
--  578  self.focus_flow = {}        —— 方向 → 目标
--  579  self.focus_flow_args = {}   —— 方向 → 参数
--  580  self.next_in_tab_order = nil—— ★ Tab 顺序指针（本文件无其它读写）
-- ★★ next_in_tab_order 是 grep 核实的**半死字段**：
--   · 583-586 SetFocusChangeDir 里**被写**（首次设置时）
--   · 577 ClearFocusDirs 里被清
--   · ★ **本文件内无任何读取点**。
--   ⇒ 推测：给子类/模组用的「Tab 键顺序」钩子。
--     widgets/ 里可能有消费者。标注为「框架预留钩子」。
--────────────────────────────────────────────────────────────────
function Widget:ClearFocusDirs()
    self.focus_flow = {}
	self.focus_flow_args = {}
	self.next_in_tab_order = nil
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【SetFocusChangeDir】—— 注册导航目标。
-- 【签名】SetFocusChangeDir(dir, widget, ...)
-- 【三步（583-590）】
--  584-586 若 focus_flow 为空，则把第一个注册的 widget 记为
--         self.next_in_tab_order（★ 「Tab 顺序」的隐式推导）
--  588    self.focus_flow[dir] = widget
--  589    self.focus_flow_args[dir] = toarrayornil(...)
-- 【★ 584 的「第一次」判定】
--   `if not next(self.focus_flow) then` —— ★ 注意用 next() 而不是
--   pairs/#。这正是为了判定「表是否为空」。
--   ⇒ 语义：**第一个注册的方向决定 Tab 顺序的起点**。
--   ⚠ 副作用：若先注册了 MOVE_DOWN 再注册 MOVE_LEFT，
--     next_in_tab_order 就是 MOVE_DOWN 的目标。
--     ⇒ ★ **注册顺序会影响 Tab 顺序**，这是一个隐式契约。
--     推理依据：584 行只认「第一个」。
-- 【★ dir 的取值】MOVE_UP/DOWN/LEFT/RIGHT（constants.lua:94-97）。
--   ★ 为什么 move 是「1..4」而 focus 是另一套？
--     MOVE_* 是「导航方向」，与物理输入无关（手柄/键鼠都用它）。
--────────────────────────────────────────────────────────────────
function Widget:SetFocusChangeDir(dir, widget, ...)
    if not next(self.focus_flow) then
        self.next_in_tab_order = widget
    end

-- ★★ 稀疏表赋值：只有注册过的方向才有值。
--   80 行 `if down and self.focus_flow[dir] then` 靠存在性判断。
-- ★★ 覆盖语义：重复 SetFocusChangeDir 同方向会**静默覆盖**。
--   ⇒ 条件注册（if not X then SetFocusChangeDir...）必须小心。
    self.focus_flow[dir] = widget
-- ★★ toarrayornil(...) —— 变长参数转数组或 nil。
--   目的：保证 focus_flow_args[dir] 要么是数组要么是 nil，
--   不影响 85 行 `if self.focus_flow_args[dir] then` 的真值判断。
--   ⇒ ★ 若直接用 {...}，无参时得到空表 {}，在 Lua 里 **truthy**！
--     那 85-89 就会走 unpack({}) 分支——虽然结果一样（不传参），
--     但语义上「空表 = 真值」是Lua 的经典陷阱。
--   ⇒ toarrayornil 正是为此而生。★ 细节到位。
    self.focus_flow_args[dir] = toarrayornil(...)
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【GetDeepestFocus】—— 「当前焦点控件」的实现
-- 【逻辑（592-602）】
--  593  if self.focus then
--  594-598    任一子节点 focus → 递归下钻
--  600        否则 return self（我就是末端）
--  601  end
--  602  end  -- 隐式 return nil（我没焦点）
--
-- 【★★ 三个关键性质】
-- ① **返回 nil 当且仅当「自己没焦点」**。
--   ⇒ 「当前焦点」的定义是「从 screenroot 出发能钻到的末端」。
--   ⇒ 若祖先都没焦点，整个链条返回 nil。
-- ② **依赖「最多一个子节点有焦点」**（提前 return 594-598）。
--   该不变量由 632 SetFocusFromChild 的「清兄弟」保证。
-- ③ ★★ **不校验节点是否已销毁**。
--   ⚠ 这是缺陷 G1 的**机制层根因**：
--     若祖先链上有已 Kill 的节点仍标着 focus=true，
--     本函数会一路下钻返回一个已销毁的控件对象。
--   ⇒ 对比 widgets/screen.lua:35 的 IsValid 检查：
--     那是 Screen 层的事后补救，**框架层没有防线**。
--   ⇒ 修复建议（不改代码）：在 594/600 前加
--     `self.inst.entity:IsValid()` 校验并向上纠正。
--
-- 【★ 唯一的框架级读者】frontend.lua:299 GetFocusWidget。
--   ⇒ 也就是说：**整个游戏里「当前焦点是什么」只有这一个定义**。
--   也只有它会返回野指针。
--────────────────────────────────────────────────────────────────
function Widget:GetDeepestFocus()
    if self.focus then
        for k,v in pairs(self.children) do
            if v.focus then
                return v:GetDeepestFocus()
            end
        end

        return self
    end
end

-- ★★★ GetFocusChild —— 「焦点链的下一段」。
-- 【与 GetDeepestFocus 的区别】
--  GetDeepestFocus —— 一路钻到底，返回**末端**
--  GetFocusChild    —— 只下钻**一层**，返回**下一段**
-- ★★ 它们的配合构造了「焦点链的遍历」：
--   frontend.lua:303-316 GetIntermediateFocusWidgets 用GetFocusChild
--   循环下钻直到遇到 GetFocusWidget 的结果 —— ★★ 这就是
--   「焦点链中间段」的提取算法。
-- ★★ 注意 605 与 593 都是 `if self.focus then` 门禁，
--   完全一致。两个函数是同一逻辑的「一层」与「到底」两种深度。
-- ⚠ 与 GetDeepestFocus 同样**不校验 IsValid**（G1 同源）。
function Widget:GetFocusChild()
    if self.focus then
        for k,v in pairs(self.children) do
            if v.focus then
                return v
            end
        end
    end
    return nil
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【ClearFocus】—— 失焦（向下递归）。
-- 【逻辑（615-630）】
--  616  if self.focus then                    ← ★ 门禁
--  617      self.focus = false
--  618-620      if self.OnLoseFocus then self:OnLoseFocus() end
--  621-623      if self.onlosefocusfn then self.onlosefocusfn() end
--  624-628      递归：任一子节点 focus → v:ClearFocus()
--  629  end
-- 630  end
-- 【★ 与 SetFocusFromChild 的对比（对称性分析）】
--            ClearFocus              SetFocusFromChild
--  方向      向下递归               向上冒泡
--  清兄弟    无（自己都清了）       ✓ 637-641 清兄弟
--  门禁      616 if self.focus      643 if not self.focus（取反）
--
-- ⚠⚠ 缺陷：616 行的 `if self.focus then` **包着整段**。
--   ⇒ 若调用时自己 focus 已经是 false，内部的 624-628 递归**不会执行**。
--   ⇒★ 一个「自身无焦点、但内部有焦点子节点」的控件，
--     调 ClearFocus **不会清除子节点的焦点**。
--   ⚠ 这个中间态能出现吗？
--     按 SetFocusFromChild（653-655）的向上冒泡逻辑，
--     子节点有焦点 ⇒ 祖先必然 focus=true（不变量成立）。
--     ⇒ 所以在**框架自身维护的不变量**下，616 的门禁是安全的。
--   ⚠ 但模组若手工设 focus 破坏不变量，就会触发。
--   ⇒ 标注为「依赖不变量，防御不足」—— 轻度疑似缺陷。
--────────────────────────────────────────────────────────────────
function Widget:ClearFocus()
    if self.focus then
        self.focus = false
-- ★ OnLoseFocus 方法钩子 —— 671 的 OnGainFocus 的镜像。
-- ★ widgets/button.lua 的 OnLoseFocus 会把文字颜色改回。
        if self.OnLoseFocus then
            self:OnLoseFocus()
        end
        if self.onlosefocusfn then
            self.onlosefocusfn()
        end
        for k,v in pairs(self.children) do
            if v.focus then
                v:ClearFocus()
            end
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【SetFocusFromChild】—— 焦点链的**核心不变式维护者**
-- 【签名】SetFocusFromChild(from_child)
-- 【五步（632-657）】
--  633-636 ★ 防御：不在屏幕层级里则打印警告 + 调用栈
--  637-641 ① 清掉**除 from_child 以外**的焦点兄弟
--  643-656 ② 若自己还没焦点：置焦点 + 调钩子 + **向上冒泡**
--  657     end
--
-- ★★★★ 【为什么必须「向上冒泡」（653-655）】
--   `if self.parent then self.parent:SetFocusFromChild(self) end`
--   ⇒ ★ 这就是「焦点是一条从根到叶的路径」的**实现**。
--   叶子获焦 → 父亲获焦 → 祖父获焦 → …… → screenroot 获焦。
--   ⇒ 递归深度 = 树深。一次 SetFocus 是 O(树深)。
--
-- ★★ 【637-641 清兄弟为什么必要】
--   没有它，一个父节点下可以同时有两个焦点子节点，
--   → GetDeepestFocus（594-598）只取第一个 ⇒ 另一个永远收不到事件；
--   → GetFocusChild（604-613）同样只取第一个；
--   → 「唯一焦点路径」的不变量被破坏。
--   ⇒ ★★ 清兄弟是整个焦点模型的正确性基石。
--
-- ⚠⚠ 缺陷：637-641 的遍历中**删除了**元素吗？没有。
--   `v:ClearFocus()` 只是改 v.focus，不动 self.children ✓ 安全。
--
-- ⚠ 缺陷：641 行递归调ClearFocus，而 616 的门禁会跳过
--   「自身无焦点的兄弟」内部的焦点子孙（见 615 行分析）。
--   ⇒ 依赖不变量成立。
--────────────────────────────────────────────────────────────────
function Widget:SetFocusFromChild(from_child)
-- ★★ 633-636 的防御性警告 —— 本文件里唯一一处「自检」。
-- 【判据】self.parent == nil and not self.is_screen
--   ⇒ 「我是根，但不是屏幕」= 我游离在屏幕层级之外。
-- 【后果】向上冒泡（653）会因 self.parent 为 nil 而**停住**，
--   ⇒ 焦点路径到我就断了 ⇒ 焦点移动会失败。
-- ★ 原文警告得很准确："This will cause focus moves to fail."
-- ★ 但它**只打印不断言**——错误会继续发生，只是留了日志。
-- ⚠ 与 247 GetParentScreen 的**同类缺陷**（无保护的死循环）形成对照：
--   同一个文件里，一个位置检测了这种误用并警告，
--   另一个位置（247）却直接 while 死循环。⚠ 明显的不一致。
-- ★★ 建议（不改代码）：GetParentScreen 应加同样的检查。
    if self.parent == nil and not self.is_screen then
        print("Warning: Widget:SetFocusFromChild is happening on a widget outside of the screen/widget hierachy. This will cause focus moves to fail. Is ", self.name, "not a screen?")
        print(debugstack())
    end
-- ★★ 清兄弟循环。★ 注意 `v ~= from_child` 的排除 ——
--   发起冒泡的那个子节点不能被清（否则焦点刚设上就被清）。
-- ★ `v:ClearFocus()` 会递归向下（615-630），
--   ⇒ 清一个兄弟会清掉它的**整个焦点子树**。
-- ⇒ 焦点转移时旧分支被完整剪除 ✓。
    for k,v in pairs(self.children) do
        if v ~= from_child and v.focus then
            v:ClearFocus()
        end
    end

-- ★★ `if not self.focus then` —— ★ 与 ClearFocus 的门禁**恰好相反**。
-- 【★ 关键】已在焦点链上的节点**不重复触发** OnGainFocus。
--   ⇒ 向上冒泡时，已获焦的祖先不会重复跑钩子。
-- ⇒ 保证「一次 SetFocus 只产生一次 OnGainFocus」。
-- ★ 这是幂等性的关键设计。
    if not self.focus then
        self.focus = true
        if self.OnGainFocus then
-- ★★ OnGainFocus 方法钩子（与 649 的函数式钩子并存）。
-- ★ widgets/button.lua:105-110 的实现在这里被触发：
--   改文字颜色 + 播 hover 音效（并检查 FadeLevel<=0 避免淡出时出声）。
             self:OnGainFocus()
        end

-- ★★ ongainfocusfn 函数式钩子（569 SetOnGainFocus 挂的）。
-- ★★ 与 646 的方法钩子**都会执行**（无 else if）。
--   ⇒ ⚠ 776-799 SetHoverText 覆写了 self.OnGainFocus（方法），
--     会替换 646 的调用目标 —— 它用 _OnGainFocus 备份并在 794 转调。
--     ★ 这套「备份-包装-还原」在 773-774/822-827 有完整实现。
        if self.ongainfocusfn then
            self.ongainfocusfn()
        end

-- ★★★★ 【向上冒泡】—— 焦点链得以形成的唯一机制。
--   `if self.parent then self.parent:SetFocusFromChild(self) end`
-- 【递归链】叶子 → 父 → 祖父 → ... → screenroot → nil（停止）
-- 【★ 终止条件】self.parent == nil。
--   ⇒ 对 screenroot 而言 parent 是 nil（它从未被 AddChild 到别处）
--     ⇒ 冒泡在 screenroot 停止 ✓。
-- ⚠ 但若某个控件游离在屏幕层级外（633 警告的情形），
--   冒泡会在它这里停止（parent == nil），焦点路径断在中间。
-- ★ 这正是 633-636 要警告的原因 —— 机制与后果完全对应。
-- ★★ 递归深度 = 树深。UI 树通常 5-10 层深，开销可忽略。
        if self.parent then
            self.parent:SetFocusFromChild(self)
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【SetFocus】—— 获焦的公开入口（659-688）
-- 【五步】
--  661-665 ★ 转发：若有 focus_forward 则代理给目标
--  667-681 自己获焦（含向上冒泡）
--  683-685 ★★ 清空所有子控件的焦点
--  687    --print(debugstack()) 已注释
--
-- 【★★ 683-685「清子焦点」是本函数最容易被误解的地方】
--   for k,v in pairs(self.children) do v:ClearFocus() end
--   ★★ 它**无条件**清空所有子节点（不是「除某个别清」）。
--   ⇒ 语义：「让焦点停在我身上，不在任何人下面」。
--   ⇒ 这就是 frontend.lua:1128 那个「先 SetFocus 再 OnBecomeActive」
--     模式的原因：先清干净，再让OnBecomeActive 精确恢复 last_focus。
--   ⚠ 但它**不检查 shown/enabled**（ClearFocus 616 也只查 focus）
--     ⇒ 若某子控件 focus 已是 false 而其子孙有焦点，
--       616 的门禁会跳过（见 615 行分析）。
--
-- 【★★ 661-665 focus_forward：代理焦点】
--   local focus_forward = FunctionOrValue(self.focus_forward)
--   if focus_forward then focus_forward:SetFocus(); return end
--   ★★ 语义：让 A 的 SetFocus **实际转给** B。
--   ⇒ 「A 是一个不可见的占位/代理，焦点真正落在 B 上」。
--   ⚠ grep 核实：**本文件无 focus_forward 的设置函数**
--     （只有 661 行的读取），由子类/模组直接赋值字段。
--   ⚠ 819的 hovertext 也有类似机制但不是这个名字。
--────────────────────────────────────────────────────────────────
function Widget:SetFocus()
-- ⚠ 660 行 `--  print ("SET FOCUS ", self)` 已注释。
--   ★ 但 687 行还有第二个 `--print(debugstack())` 未被注释掉标记。
--   ⇒ 作者调试完这个函数时留了两处痕迹。这是**有益的考古线索**。
  --  print ("SET FOCUS ", self)
-- ★★ focus_forward —— 代理焦点。完整分析见 659 行上方注释块。
-- ⚠ 与 81 行的 FunctionOrValue 用法不同：
--   81行传了 self 作为参数，661 行**没传**。
--   ⇒ 两处回调签名不统一（util.lua:1716 的 ... 部分）。
--   ⚠ 若 focus_forward 是一个需要参数的函数，661 行会调用失败。
--   标注为轻度不一致。
    local focus_forward = FunctionOrValue(self.focus_forward)
    if focus_forward then
        focus_forward:SetFocus()
        return
    end

    if not self.focus then
        self.focus = true

        if self.OnGainFocus then
            self:OnGainFocus()
        end

        if self.ongainfocusfn then
            self.ongainfocusfn()
        end

        if self.parent then
            self.parent:SetFocusFromChild(self)
        end
    end

-- ★★★ 【无条件清空所有子控件的焦点】—— 「让焦点停在我身上」。
-- ★ 与 637-641 的「清兄弟（除 from_child）」形成对比：
--   · 637 清兄弟：保留发起者，清掉其它
--   · 683 清子：全部清掉（包括之后可能被恢复的那个）
-- ⇒ 用法差异：
--   · SetFocusFromChild 用于「从下往上」的冒泡（要保留发起者）
--   · SetFocus 用于「我要成为焦点」（要独占）
-- ★★ 这个「全清」正是 659 函数与 632 函数的本质区别。
-- ⚠ 性能：无条件遍历所有子节点（而非只清有焦点的那个）。
--   ⇒ O(子节点数)。对几百个兄弟的大面板，SetFocus 会明显慢。
--   ⚠ 可优化为「只调有焦点的那个」，但收益有限，代码保持简单。
    for k,v in pairs(self.children) do
        v:ClearFocus()
    end

    --print(debugstack())
end

-- ════════════════════════════════════════════════════════════════
-- ★【GetStr】—— 调试输出（690-702）。把控件树打成缩进文本。
-- ★★ 697-699 的递归用 pairs（无序）⇒ 输出顺序不确定。
--   ⇒ 对调试是**缺点**（两次打印顺序可能不同）。
-- ⚠ 695 行的格式串有四个 %s：
--   tostring(self) / focus 标记 / enabled 标记 / \n
--   ★ 但只传了三个参数 + \n 在格式串里是转义序列而非参数。
--   ⇒ ★★ **格式串与参数数量不匹配**：第 4 个 %s 会拿到 nil。
--   ⚠ 这是真实的格式串 bug，但因为是调试输出，无实际后果。
--   推理依据：string.format 在参数不足时补 nil，输出 "nil"。
--   ⇒ 标注为 ⚠ 疑似缺陷（调试辅助函数，无生产影响）。
--────────────────────────────────────────────────────────────────
function Widget:GetStr(indent)
    indent = indent or 0
    local indent_str = string.rep("\t",indent)

    local str = {}
    table.insert(str, string.format("%s%s%s%s\n", indent_str, tostring(self), self.focus and " (FOCUS) " or "", self.enabled and " (ENABLE) " or "" ))

    for k,v in pairs(self.children) do
        table.insert(str, v:GetStr(indent + 1))
    end

    return table.concat(str)
end

-- ★★ __tostring —— 返回控件名。
-- ★ 它是 695 行 tostring(self) 的实现，
--   也是所有 print/日志里能看见可读名字的原因。
-- ★ 745 行 stringtable 等处也依赖 tostring。
function Widget:__tostring()
    return tostring(self.name)
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【SetHoverText】—— 本文件最长的函数（708-812，105 行）
-- 【★★ 它在一个函数里做了四件事】
--  ① 创建或复用 hover 文本控件（710-753）
--  ② 选择「谁来检测 hover」（756-771 vs 772-800）
--  ③ 处理坐标换算（763-766 或 777-791）
--  ④ 更新已有 hover 文本（802-809）
--
-- 【★ 设计要点一：惰性创建（710 `if not self.hovertext then`）】
--   只有第一次调用才建控件，之后走 801-810 的更新分支。
--   ⇒ 避免每个控件都预建一个隐藏的文本控件（浪费内存）。
--
-- 【★ 设计要点二：坐标换算的两种算法（★ 本文件的核心知识点）】
--   路径 A（756-771，self 是 Text 控件时）：
--     用 GetWorldPosition（世界坐标）+ 参数偏移 → 挂在 global_widget 上
--   路径 B（772-800，一般情况）：
--     备份 OnGainFocus/OnLoseFocus，换成自己的包装函数；
--     ★★ 若有 attach_to_parent，要做**逆变换**：
--       778  world_pos = GetWorldPosition() - attach_to_parent:GetWorldPosition()
--       779  parent_scale = attach_to_parent:GetScale()   ★ 累乘缩放
--       781  x_pos = world_pos.x / parent_scale.x + offset_x
--       782  y_pos = world_pos.y / parent_scale.y + offset_y
--     ⇒ ★ 这段手工做的正是「世界坐标 → 父局部坐标」的换算，
--       也就是本文件 336-360 三套坐标问题的**实证**：
--       框架只提供 GetWorldPosition（世界），
--       要放到某个父节点下就必须自己减父位置、除父缩放。
--       ★★ 这段代码是「没有布局引擎」的直接代价。
--────────────────────────────────────────────────────────────────
function Widget:SetHoverText(text, params)
    if text and text ~= "" then
        if not self.hovertext then
-- ★★ 函数内 require —— 延迟加载，避免循环依赖。
--   widgets/imagebutton（759 行用）与 widgets/text。
-- ★ 为什么 text 要在这里 require 而不在文件头？
--   → widgets/text 可能间接依赖 widget ⇒ 循环。
-- ⇒ 函数内 require 是打破循环依赖的常用手段。
            local ImageButton = require "widgets/imagebutton"
            local Text = require "widgets/text"

            if params == nil then
                params = {}
            end

-- ★★ attach_to_parent 参数 —— 「把 hover 文本挂到别的节点下」。
-- 【为什么要这个选项】
--   默认路径（721-723）创建一个 **global_widget** 独立控件。
--   global_widget 的特点是**不受屏幕栈影响**（frontend.lua:46/50/66）。
--   ⇒ hover 文本能浮在所有屏幕之上 ✓ 这正是想要的。
--   ⚠ 但 attach_to_parent 分支（719）把它挂到指定父下——
--     ★ 那它就**不再是 global_widget**（721 行才设 global_widget = true，
--       719 行的分支没有设）。
--     ⇒ 会受该父的遮挡与坐标变换影响。
--   ⇒ 这是「两种摆放策略」的选择参数。
			if params.attach_to_parent ~= nil then
				self.hovertext_root = params.attach_to_parent:AddChild(Widget("hovertext_root"))
			else
			    self.hovertext_root = Widget("hovertext_root")
				self.hovertext_root.global_widget = true
				self.hovertext_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
			end
-- hovertext_root:Hide() —— 默认隐藏，靠焦点显示。
			self.hovertext_root:Hide()

-- ★★ params.bg 为 nil/true 时创建背景（false 时不建）。
-- ★ 728 行 params.bg_atlas or "images/frontend.xml" —— 可换图集。
-- ★ 729-730 背景半透明 0.8 且 SetClickable(false) ✓
--   ⇒ hover 文本的背景不吃点击（正确，否则会挡住原控件）。
-- ★★ 对比 frontend.lua:160 helptextbg 的 SetClickable 被注释掉——
--   同样的问题，一个处理了，一个没处理。⚠ 印证 160 行的缺陷标注。
            if params.bg ~= false then
                self.hovertext_bg = self.hovertext_root:AddChild(Image(params.bg_atlas or "images/frontend.xml", params.bg_texture or "scribble_black.tex"))
                self.hovertext_bg:SetTint(1,1,1,.8)
                self.hovertext_bg:SetClickable(false)
            end

-- ★★ Text 控件的创建。三种可配：字体 / 字号 / 内容。
-- ★ 735 SetScale(1.1, 1.1) —— 悬停文本**放大 10%**。
--   ⇒ 微妙的视觉提示：文字在放大 = 「这是浮层不是场景元素」。
-- ★ 734 SetClickable(false) ✓ 同上，文本不吃点击。
			self.hovertext = self.hovertext_root:AddChild(Text(params.font or NEWFONT_OUTLINE, params.font_size or 22, text))
            self.hovertext:SetClickable(false)
            self.hovertext:SetScale(1.1,1.1)

            if params.region_h ~= nil or params.region_w ~= nil then
                self.hovertext:SetRegionSize(params.region_w or 1000, params.region_h or 40)
            end

            if params.wordwrap ~= nil then
                --print("Enabling word wrap", params.wordwrap)
                self.hovertext:EnableWordWrap(params.wordwrap)
            end

            if params.colour then
                self.hovertext:SetColour(params.colour)
            end

-- ★★★ 【★ 条件表达式陷阱】`if params.bg == nil or params.bg == true then`
-- ★★ 727 行是 `if params.bg ~= false then`（即 bg 为 nil/true 时创建）。
--   750 行的条件与之**逻辑相同**，但形式不同。
--   ⇒ 两处必须保持同步；不一致会导致「背景不存在却去设它的大小」。
-- ★★ 752 行 `self.hovertext_bg:SetSize(w*1.5, h*2.0)` ——
--   若 750 条件为假（bg == false），hovertext_bg 为 nil → 753 会崩？
--   ⇒ ★ 但 750 的条件与 727 相同，所以 bg==false 时 750 也不成立 ✓。
--   ⇒ 逻辑自洽，但**依赖两处条件保持一致**这个隐式契约。
-- ⚠ 标注为「脆弱的一致性依赖」，非当前缺陷。
-- ★ 1.5×2.0 的倍数是美术调出来的：宽度 1.5 倍留边，高度 2 倍留上下空间。
            if params.bg == nil or params.bg == true then
                local w, h = self.hovertext:GetRegionSize()
                self.hovertext_bg:SetSize(w*1.5, h*2.0)
            end


-- ════════════════════════════════════════════════════════════════
-- ★★★ 【路径A 分支】756-771 —— 自身是 Text 控件时的做法。
-- 【判据】hover_parent = self.text or self
--   且 `hover_parent.GetString ~= nil and hover_parent:GetString() ~= ""`
--   ⇒ 「我有 text 子控件，且它有文字」。
-- 【★ 与路径B 的本质差异】
--   路径 A：**额外创建一个 ImageButton**（759行）当 hover 探测器；
--   路径 B：**替换自己的 OnGainFocus**。
-- ★★ 758 行的原注释解释了原因：
--   "--Note(Peter): This block is here because Text widgets don't receive
--    OnGainFocus calls."
--   ⇒ ★★★ **Text 控件不收 OnGainFocus**（因为它不可点击/无焦点）。
--     所以路径 B 的「替换 OnGainFocus」对 Text 无效，
--     必须另造一个 ImageButton 来接收焦点。
-- ⇒ 这是「不同控件类型需要不同 hover 机制」的具体体现。
--   代价：多一个实体 + 一次 draw call（G2 的同类代价）。
--────────────────────────────────────────────────────────────────
            local hover_parent = self.text or self
            if hover_parent.GetString ~= nil and hover_parent:GetString() ~= "" then
                --Note(Peter): This block is here because Text widgets don't receive OnGainFocus calls.
-- ★★ ImageButton("images/ui.xml", "blank.tex", ...) ——
--   ★★ 三张贴图全是 "blank.tex"（不可见的空白图）。
--   这就是**缺陷 G2「透明 Image 吃焦点」的另一个实例**！
--   推理：blank.tex 不可见，但它必须被创建、被渲染（一次 draw call），
--   只为了能收到 OnGainFocus。
-- ★ 与 widgets/scrollablelist.lua:44 的动机完全相同，
--   那里有明确的原注释：
--     "-- so that we have focus whenever the mouse is over this thing"
-- ⇒ ★★ 同一个框架里，同样的 hack 至少出现两次。
--   这正是 bug-patterns.md G2 建议「在框架层提供独立的命中区域概念」
--   的证据——因为每个人都在自己造轮子。
-- ★ 759-771 完整复述：构造 → ScaleToSize → 挂 OnGainFocus/OnLoseFocus。
                self.hover = hover_parent:AddChild(ImageButton("images/ui.xml", "blank.tex", "blank.tex", "blank.tex", nil, nil, {1,1}, {0,0}))
                self.hover.image:ScaleToSize(hover_parent:GetRegionSize())

-- ★★ OnGainFocus（**直接赋函数**，不是 SetOnGainFocus）。
--   → 走的是「方法钩子」路径（670行调用），不是「函数钩子」路径。
-- ★ 763-765 的位置计算：用**世界**坐标 + 偏移。
--   ★ 765 行 y 偏移默认 26 —— 悬停文本出现在控件**下方 26 像素**。
--   ⇒ 纯美术常量，无参数化。
-- ⚠ 与路径B 的 787-791 逻辑重复（两处算位置）。
--   ⇒ 结构上的重复，但因机制不同（见 756 分析）无法合并。
                self.hover.OnGainFocus = function()
                    local world_pos = self:GetWorldPosition()
                    local x_pos = world_pos.x + (params.offset_x or 0)
                    local y_pos = world_pos.y + (params.offset_y or 26)
                    self.hovertext_root:SetPosition(x_pos, y_pos)
                    self.hovertext_root:Show()
                end
-- ★ OnLoseFocus —— 隐藏 hover 文本。与 762 对称。
                self.hover.OnLoseFocus = function()
                    self.hovertext_root:Hide()
                end
-- ════════════════════════════════════════════════════════════════
-- ★★★ 【路径B 分支】772-800 —— 一般控件的做法
-- 【★★「备份-包装-还原」模式】
--  773-774 备份原方法到 _OnGainFocus / _OnLoseFocus
--  776-795 替换 OnGainFocus：先算位置 + 显示，再转调 _OnGainFocus
--  796-799 替换 OnLoseFocus：隐藏 + 转调 _OnLoseFocus
-- 【★ 为什么必须备份？】
--   因为 646/618 行会调用 self:OnGainFocus()。
--   若直接覆写不备份，**子类原本的获焦逻辑就被吞掉了**。
--   ⇒ 转调（794 `self._OnGainFocus( self )`）是必需的。
-- ★★ 转调时传了 self（794/798）——
--   因为此时 self._OnGainFocus 已是**函数**（不是方法），
--   必须手动传 self 作为第一个参数。
--   ⚠ 但 794 行无条件调 `self._OnGainFocus( self )` ——
--     若子类从未定义 OnGainFocus，备份的是**基类的空函数**
--     （563-564），调用它无害 ✓。
--   ⇒ 这个设计是安全的：基类保证有默认实现。
--────────────────────────────────────────────────────────────────
            else
-- ★★ 备份原方法。★ 这两行是「装饰器模式」的手写实现。
--   762-771（路径A）没有这一步，因为它不覆写自己的方法。
                self._OnGainFocus = self.OnGainFocus --save these fns so we can undo the hovertext on focus when clearing the text
                self._OnLoseFocus = self.OnLoseFocus

-- ★★ 包装后的 OnGainFocus。★ 注意它**替换**了 self.OnGainFocus，
--   所以 670 行 `self:OnGainFocus()` 会调到它。
--   ⚠ 而如果之后再调一次 SetHoverText（走 802 的更新分支），
--     **不会**重复包装 ✓（因为 710 的条件拦住了）。
--   ⇒ 包装只发生一次，正确。
                self.OnGainFocus = function()
-- ★★★ 【attach_to_parent 坐标换算】777-791 —— 逆变换的实证
-- 【四行看懂「世界 → 父局部」的换算】
--  778  world_pos = self:GetWorldPosition() - attach:GetWorldPosition()
--       ⇒ ① 减掉父的世界位置 → 得到「相对父的位移」（仍是世界尺度）
--  779  parent_scale = attach:GetScale()
--       ⇒ ② 取父的累乘缩放（548，注意是累乘不是自身）
--  781-782 x_pos = world_pos.x / parent_scale.x + offset_x
--        ⇒ ③ 除以缩放 → 得到父局部坐标
--       ⇒ ★★ 三步正是 UITransform 没有提供的变换。
-- 【★ 为什么必须用 GetScale（累乘）而不是 GetLooseScale（自身）】
--   因为世界位移是相对**整条祖先链**的，而父局部坐标只除最直接父的缩放？
--   ⚠ 推理：严格来说应该除以**世界缩放**（UITransform:GetWorldScale，348 行），
--     而 548GetScale 是 Lua 手动递归累乘的 UITransform 缩放，
--     两者在有无 SCALEMODE 影响时可能不同（见 548 行分析）。
--   ⇒ ★ 这可能是一个**坐标系混用**：用「Lua 累乘缩放」去除「世界位移」。
--     在有 SCALEMODE_PROPORTIONAL 的祖先下，两者可能不一致，
--     导致 hover 文本位置偏移。
--   ⇒ 标注为 ⚠ 疑似缺陷（坐标系可能混用），推理依据见上。
--   ⚠ 实际影响：hover 文本偏移几个像素，肉眼难辨。
					if params.attach_to_parent ~= nil then
						local world_pos = self:GetWorldPosition() - params.attach_to_parent:GetWorldPosition()
						local parent_scale = params.attach_to_parent:GetScale()

						local x_pos = world_pos.x / parent_scale.x + (params.offset_x or 0)
						local y_pos = world_pos.y / parent_scale.y + (params.offset_y or 26)
						self.hovertext_root:SetPosition(x_pos, y_pos)

-- ★★ MoveToFront() —— ★★ hover 文本要保证在最上层！
--   ⇒ 只有挂在 attach_to_parent 下时才需要（因为可能被遮挡）。
--   ⇒ 而 721-723 的 global_widget 路径**没有**这个调用——
--     因为 global_widget 本来就在最上层（frontend.lua:46/50）。
-- ⇒ ★ 两个分支的「保证在最上层」用了不同机制。设计正确。
						self.hovertext_root:MoveToFront()
					else
-- ★ else 分支：无 attach_to_parent → 直接用世界坐标（787-790）。
--   ⇒ 与 762-766（路径A）**完全相同的四行**。
--   ⚠ 782 与 790 两处重复计算「世界坐标 + 偏移 + 显示」。
--     属结构性重复，但因上下文不同（一个在 ImageButton 回调里，
--     一个在 OnGainFocus 包装里）不宜合并。
						local world_pos = self:GetWorldPosition()
						local x_pos = world_pos.x + (params.offset_x or 0)
						local y_pos = world_pos.y + (params.offset_y or 26)
						self.hovertext_root:SetPosition(x_pos, y_pos)
					end
					self.hovertext_root:Show()

                    self._OnGainFocus( self )
                end
-- ★★ OnLoseFocus 包装：隐藏 + 转调原方法。
--   ★ 顺序与 OnGainFocus 相反（先隐藏后转调），
--     与 762-771 的路径A 一致（770 先 Hide）。
                self.OnLoseFocus = function()
                    self.hovertext_root:Hide()
                    self._OnLoseFocus( self )
                end
            end
-- ════════════════════════════════════════════════════════════════
-- 【更新分支】801-810 —— hover 文本已存在时的处理。
-- 【三个动作】
--  802  SetString(text)            —— 更新文字
--  803-805 若给了 colour 则更新颜色
--  806-809 若有背景则重新按文本尺寸调整背景大小
-- ★★ 806-809 与创建时的 750-753 逻辑重复（1.5×/2.0×）。
--   ⚠ 两处必须同步修改倍数，否则文字变长后背景不跟着变。
--   ⇒ 标注为「重复的排版常量」，隐式一致性依赖。
-- ★★ 809 的 SetSize 依赖 757 GetRegionSize 的测量结果，
--   而测量要求**布局已稳定**。若在构造期立即 SetHoverText，
--     尺寸可能还没算好 ⇒ 背景偏小。
--   ⚠ 潜在的「首帧尺寸错误」，无实测证据，标注为「可能」。
--────────────────────────────────────────────────────────────────
        else
-- ★ 更新已有 hover 文本 —— 惰性创建的第二次入口。
            self.hovertext:SetString(text)
            if params and params.colour then
                self.hovertext:SetColour(params.colour)
            end
            if self.hovertext_bg then
                local w, h = self.hovertext:GetRegionSize()
                self.hovertext_bg:SetSize(w*1.5, h*2.0)
            end
        end
    end
end


-- ════════════════════════════════════════════════════════════════
-- ★★ 【ClearHoverText】—— hover 文本的完整清理（815-834）
-- 【★ 为什么要「还原」包装过的方法】
--   822-827 `if self._OnGainFocus then` 才还原。
--   ⇒ 条件是「有没有备份」⇒ 没走过路径B（772-800）就不用还原 ✓。
--   ⇒ 走路径A（762-771）时没有备份，也不会还原 ✓ 正确。
-- 【★ 四种资源的清理】
--  816-820  hovertext_root（Kill）→ hovertext / hovertext_bg（置 nil）
--  822-828  还原 _OnGainFocus / _OnLoseFocus → 两个备份置 nil
--  830-833  self.hover（路径A 的 ImageButton）→ Kill → 置 nil
-- 【★ 两处 Kill（817/831）的必要性】
--   hovertext_root 是**独立实体**（721 行 CreateEntity），
--   不在 self.children 里 ⇒ 必须显式 Kill，否则泄漏。
--   self.hover 是 AddChild 到 self 或 self.text 的 ⇒
--   ★ 其实在 children 里，Kill 双重清理（无害，282 的删是幂等的）。
-- ⇒ 三个读者：291 KillAllChildren（必需）、外部显式清理、816 内部。
--────────────────────────────────────────────────────────────────
function Widget:ClearHoverText()
-- ★★ 判断条件是 hovertext_root ~= nil —— 「是否建过」。
--   ⇒ 没建过就什么都不做（零开销）✓。
    if self.hovertext_root ~= nil then
        self.hovertext_root:Kill()
        self.hovertext_root = nil
        self.hovertext = nil
        self.hovertext_bg = nil

-- ★★★ 还原被包装的 OnGainFocus / OnLoseFocus。
-- ★★ 这是「装饰器模式」的 teardown。
--   `if self._OnGainFocus then` 保证只还原一次。
-- ⚠ 潜在缺陷：★ 若某控件**只清了 hovertext_root**（816-820）
--   而备份字段被外部误设，会还原错的方法。极不可能。
-- ★ 正确性依赖：备份与还原严格配对（773/822）。
--   ⇒ 路径A（无备份）不会误还原 ✓ 由 822 的条件保证。
        if self._OnGainFocus then
            self.OnGainFocus = self._OnGainFocus
            self.OnLoseFocus = self._OnLoseFocus

			self._OnGainFocus = nil
			self._OnLoseFocus = nil
        end
    end
-- ★★ 清理路径A 的 ImageButton 探测器。
--   self.hover 是 759 行创建的 ImageButton。
-- ⚠ 它是 AddChild 到 hover_parent（756 行），所以在 children 里；
--   817 行的 hovertext_root:Kill() **不会**清它（不同对象）
--   ⇒ 830-833 是必需的 ✓。
    if self.hover ~= nil then
        self.hover:Kill()
        self.hover = nil
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【SetScissor】—— 裁剪（836-838）。滚动列表的实现基础。
-- 【语义】把子内容的绘制限制在 (x, y, w, h) 矩形内。
-- ★★ 这是 DST 实现「滚动区域」的方式：
--   1. 外层控件设 Scissor（裁剪窗口）
--   2. 内层控件可以超出边界（内容更长）
--   3. 用 SetPosition 或遮罩移动内层 → 内容「滚动」
-- ★ 读者：widgets/scrollablelist.lua —— 它同时用了 Scissor、
--   blank.tex 背景（G2）、parent_scroll_list（94 行）、
--   focus_flow 导航。⇒ ★★ 它是本文件所有机制的综合演示。
-- ★⇒ **强烈建议配合 widgets/scrollablelist.lua 阅读本文件**：
--   那里能看到 SetScissor / AddChild / ClearFocusDirs /
--   SetFocusChangeDir / parent_scroll_list 全部实际用法。
--────────────────────────────────────────────────────────────────
function Widget:SetScissor(x, y, w, h)
    self.inst.UITransform:SetScissor(x, y, w, h)
end

return Widget
