#!/usr/bin/env node
/**
 * build-ui.mjs —— UI 框架三文件深度中文注释生成器（锚点注入法）
 *
 * 与 build-inventory.mjs / build-entityscript.mjs 同构：
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-ui-*.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *   · 规格里任何非 `--` 开头的行都会在构建期抛错（assertComment）。
 *   · 规格里出现越界行号（超出源文件行数）同样在构建期抛错。
 *
 * 用法：node build-ui.mjs [frontend|widget|input|all]
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC_ROOT = pristineRoot();
const OUT_ROOT = ANN_SCRIPTS;

/* ────────────────────────── 文件头：frontend.lua ────────────────────────── */

const HEADER_FRONTEND = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：frontend.lua（1655 行）",
  "-- 模块：UI 系统 / 前端总控（FrontEnd，全局单例 TheFrontEnd）",
  "-- 职责：DST 全部界面层的中枢。它把四件通常拆开的事塞进同一个类：",
  "--   ① 屏幕栈（screenstack）—— 界面压栈 / 出栈 / 交叉淡化的调度；",
  "--   ② 输入仲裁—— 判定「这次输入归 UI 还是归游戏」；",
  "--   ③ 焦点管理 —— 跨屏幕的记忆与恢复；",
  "--   ④ 全屏演出层—— 淡入淡出、标题、服务器暂停挂起、存档指示器。",
  "--   它是**纯客户端**文件：服务端不加载它（无 network 段、无 mod_protect）。",
  "--",
  "-- ★★ 全文件最重要的认知一：★「DST 的 UI 没有布局引擎」。",
  "--   你在本文件里找不到任何 layout / flex / grid / align-content 代码。",
  "--   每一个控件的位置都由三组**锚点**手工算出：",
  "--     · Anchor  （控件自身对齐到父级的哪一点）—— SetHAnchor / SetVAnchor",
  "--       取值 constants.lua:77-81，只有三个：",
  "--         ANCHOR_MIDDLE=0 / ANCHOR_LEFT=1(==ANCHOR_TOP) / ANCHOR_RIGHT=2(==ANCHOR_BOTTOM)",
  "--         ★ 注意 79 与 80 行：左右与上下共用同一套数值枚举（1/2），",
  "--           所以H 用 ANCHOR_LEFT、V 用 ANCHOR_TOP 都是 1。",
  "--     · RegPoint（贴图自身哪一点对齐到 Anchor）—— SetHRegPoint / SetVRegPoint",
  "--       定义在 widgets/image.lua:154-158，不在本文件。",
  "--         例：77-82 行 blackoverlay 把 Anchor 与 RegPoint 都设成 MIDDLE，",
  "--         于是「屏幕正中」而不是「左上角贴图」。",
  "--     · ScaleMode（怎么缩放）—— SetScaleMode，constants.lua:83-87 五种：",
  "--         SCALEMODE_NONE / FILLSCREEN / PROPORTIONAL /",
  "--         FIXEDPROPORTIONAL / FIXEDSCREEN_NONDYNAMIC。",
  "--   最终位置的计算发生在 C++ 层的 UITransform，Lua 只负责把三个参数喂给它。",
  "--   ★ 为什么不用自动布局？（这是一个影响很大的设计决策）",
  "--     ① DST 的 UI 是**美术驱动**的：所有界面都是手绘 NineSlice 贴图",
  "--        按固定像素尺寸拼出来的，图就是布局。用自动布局反而要写",
  "--        「把这张 240×80 的图在 4 个按钮里居中」这类约束求解代码。",
  "--     ② 游戏**同时**要服务 720p / 1080p / 4K / 主机安全区 / 分屏，",
  "--        但同一张贴图必须看起来一样。自动布局会按内容重新分配空间，",
  "--        美术的比例关系就崩了；锚点 + 缩放模式则保证「整体等比放大」，",
  "--        参见 1225 GetProportionalHUDScale 与 1233 GetHUDScale。",
  "--     ③ 玩家可见信息**密度极高**且随版本变化（DLC 加了新页签）。",
  "--        自动布局需要「最小尺寸 + 溢出 + 滚动」三件套；DST 的做法是",
  "--        每个具体界面（widgets/crafting.lua、widgets/menu.lua）自己算好坐标。",
  "--     ⇒ 代价：任何要写新界面的人，都得**手算每一个子控件的坐标**，",
  "--       且分辨率相关的偏移必须手写（例：368-385 UpdateHelpTextSize 里",
  "--       splitscreen_scale 要按 1.8 / 1.63 分别硬编码，字体缩放靠 SetSize）。",
  "--       这是 DST 模组做 UI 最大的摩擦点。",
  "--",
  "-- ★★ 全文件最重要的认知二：**焦点是一条链，不是一个指针**。",
  "--   `self.focus` 是每个控件自己的布尔标记；「当前焦点」= 从",
  "--   screenroot 往下走，唯一一条 focus==true 的路径（GetDeepestFocus）。",
  "--   所以 Focus 的传播（widgets/widget.lua:632 SetFocusFromChild）必须",
  "--   「清兄弟 +向上冒泡」。焦点不是从根往下的单指针，而是**路径**。",
  "--",
  "-- ★★ 全文件最重要的认知三：**仲裁发生在分发之前，但消费发生在分发之中**。",
  "--   input.lua:163-170 的Input:OnControl 先问 TheFrontEnd:OnControl，",
  "--   返回 true 就不再广播给游戏层。这是**正确的**仲裁位置（见 G3 修复）。",
  "--   但 419-450 的历史补丁说明：当 UI 在**抬起帧**才消费时，",
  "--   按下帧已经漏给游戏层了，于是必须**事后**取消游戏层的中间状态。",
  "--   ⇒ 理解本文件的关键是理解 G3 这条补丁，它暴露了架构的真实缺陷。",
  "--",
  "-- 已收录缺陷对照（本文件相关部分）：",
  "--   G1「焦点指向已销毁控件」→ 触发点在本文件 1151 GetActiveScreen 无校验，",
  "--      校验只在 widgets/screen.lua:35；根因分析见该行与 1093-1143 PopScreen。",
  "--   G2「透明 Image 吃焦点」→ 实例在 widgets/scrollablelist.lua:44；",
  "--      本文件 widget.lua:77 / 129 的 `if v.focus` 递归是它能生效的传播路径。",
  "--   G3「按下/抬起两帧导致误攻击」→ 根因行 frontend.lua:439-448（补丁本体）、",
  "--      input.lua:163-170（仲裁位置）、playercontroller.lua:3132（另一侧补丁）。",
  "--   G4「UI 状态残留（屏幕栈互相污染）」→ 根因行 frontend.lua:1103-1113",
  "--      （PopScreen 按对象弹出时**不**成对调OnBecomeInactive）；",
  "--      对称基类见 widgets/screen.lua:28-43。",
  "--",
  "-- ★★ 关于「三循环暂停语义」：",
  "--   DST 的暂停由mainfunctions.lua:914DoAutopause 统一裁决，输入是三个",
  "--   计数器（autopausecount / craftingautopause / consoleautopausecount）。",
  "--   本文件是它的**触发方**而非决策方：",
  "--     · 575-577 SetFadeLevel 与 1032-1057 Fade 都调DoAutopause()，",
  "--       因为「淡出期间必须暂停」，否则淡出动画里世界还在跑；",
  "--     · ★ 398IsControlsDisabled 是反向闸门：淡出中/错误弹窗时禁用输入，",
  "--       于是 DoAutopause 的 `and not TheFrontEnd:IsControlsDisabled()`",
  "--       成立 → 自动暂停。**这是个隐式耦合**：UI 的淡入淡出状态直接",
  "--       决定世界是否暂停。任何在Fade 期间误调 SetFadeLevel(0) 的代码，",
  "--       都会导致世界在弹窗打开时继续跑（已收录D2 家族问题）。",
  "--     · 暂停时 UI 仍要动，靠 widgets/widget.lua:22 UpdateWhilePaused(true)",
  "--       —— 它把 DoPeriodicTask 换成 DoStaticPeriodicTask（真实时间轴），",
  "--       参见 scheduler.lua 的 sim/static 双调度器设计。",
  "--",
  "-- 关键符号：FrontEnd（类）, screenstack, screenroot, overlayroot,",
  "--   PushScreen, PopScreen, ClearScreens, InsertScreenUnderTop,",
  "--   InsertScreenAtIndex, ShowScreen, GetActiveScreen, GetOpenScreenOfType,",
  "--   IsScreenInStack, GetScreenStackSize, FadeToScreen, FadeBack,",
  "--   OnControl, OnFocusMove, OnRawKey, OnTextInput, OnMouseButton, OnMouseMove,",
  "--   GetFocusWidget, GetIntermediateFocusWidgets, LockFocus, ClearFocus,",
  "--   StopTrackingMouse, DoHoverFocusUpdate, SetForceProcessTextInput,",
  "--   SetFadeLevel, GetFadeLevel, DoFadingUpdate, HideTopFade, ShowTopFade,",
  "--   GetProportionalHUDScale, GetHUDScale, GetCraftingMenuScale,",
  "--   UpdateRepeatDelays, IsControlsDisabled, StartUpdatingWidget,",
  "--   StopUpdatingWidget, CheckCachedError, SetGlobalErrorWidget",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 widgets/widget.lua —— 控件基类（焦点链、事件分发、锚点 API）",
  "--   ★★ 参见 widgets/screen.lua:28-43 OnBecomeInactive/OnBecomeActive —— 焦点记忆",
  "--   ★★ 参见 input.lua:163-170 Input:OnControl —— UI 与游戏的输入仲裁点",
  "--   ★★ 参见 mainfunctions.lua:914 DoAutopause —— 暂停语义的唯一裁决点",
  "--   ★★ 参见 components/playercontroller.lua:3132 —— G3 的另一侧补丁",
  "--   参见 components/playercontroller.lua:2635 GetCombatRetarget —— retarget 读取点",
  "--   参见 widgets/screen.lua:34 TheSim:SetUIRoot —— C++ 把输入路由到哪棵子树",
  "--   参见 widgets/scrollablelist.lua:44 —— G2 透明Image 吃焦点的原始现场",
  "--   参见 components/uianim.lua:148 OnWallUpdate 的 IsValid 守卫 —— 补间存活检查",
  "--   参见 constants.lua:77-81 —— ANCHOR 枚举（左右与上下共用的三值枚举）",
  "--   参见 constants.lua:83-87 —— SCALEMODE 五种缩放模式",
  "--   参见 constants.lua:109 CONTROL_PRIMARY=0 / :147 CONTROL_ACCEPT=29",
  "--     —— 为什么 431-435 行要把 PRIMARY 映射成 ACCEPT",
  "--   参见 screens/playerhud.lua:462 —— InsertScreenUnderTop 的唯一调用点",
  "--   参见 easing.lua —— 本文件全部淡入淡出曲线（inOutCubic / outCubic / linear）",
  "--   参见 widgets/templates.lua —— TEMPLATES.BackgroundVignette 等复用浮层",
  "--============================================================",
].join("\n");

/* ────────────────────────── 文件头：widget.lua ────────────────────────── */

const HEADER_WIDGET = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：widgets/widget.lua（840 行）",
  "-- 模块：UI 系统 / 控件基类（Widget）",
  "-- 职责：DST 全部 UI 元素的父类。它只做五件事：",
  "--   ① 把每个控件包装成一个**真实实体**（CreateEntity + UITransform），",
  "--      因此 UI 与玩法共用同一套实体世界与渲染管线；",
  "--   ② 维护控件树（children / parent）与显示-启用-焦点三种可见状态；",
  "--   ③ 定义所有事件回调的**默认传播规则**（OnControl / OnMouseButton /",
  "--      OnRawKey / OnTextInput / OnFocusMove）；",
  "--   ④ 实现焦点链（SetFocus / SetFocusFromChild / ClearFocus /",
  "--      GetDeepestFocus / focus_flow 导航图）；",
  "--   ⑤ 把补间（ScaleTo/MoveTo/RotateTo/TintTo）转发给 components/uianim。",
  "--",
  "-- ★★ 全文件最重要的认知一：**一个 Widget == 一个实体**。",
  "--   7 行 self.inst = CreateEntity() 不是性能取舍，是**架构必然**：",
  "--   · UI 才能复用引擎的 Transform/材质/Shader/Scissor/鼠标命中；",
  "--   · UI 才能挂组件（本文件就挂了 uianim，第 20 行）；",
  "--   · 渲染排序天然由实体的父子关系 + MoveToFront 决定（64-70 行）。",
  "--   ⇒ 推论：CreateEntity 很贵（要分配 GUID、走实体管理表）。",
  "--     widgets/ 顶层有 183 个控件文件，一个界面动辄几百个 Widget，",
  "--     这就是为什么 StartUpdating（485）是**注册制**而不是每帧遍历整棵树。",
  "--",
  "-- ★★ 全文件最重要的认知二：**三个「可见性」互相独立，且只有两个是布尔的**。",
  "--   · shown（311 Hide / 318 Show）—— 自己画不画。有父级继承（101-103）。",
  "--   · enabled（266 Enable / 271 Disable）—— 响应不响应。有父级继承（233-241）。",
  "--   · focus（659 SetFocus）—— 是否在焦点路径上。**不继承**，由",
  "--     SetFocusFromChild（632）显式向上冒泡。",
  "--   ★ 注意 shown 用的单词是 shown 而不是 visible，因为 IsVisible（101）",
  "--     是**计算**出来的（自己 && 父级），而 shown 是**存储**的。",
  "--   ⚠ 见 129-131：只有 focus==true 的子控件才收事件。所以「shown 但",
  "--     没有焦点的控件」永远收不到输入——这正是 G2 的机制根源。",
  "--",
  "-- ★★ 全文件最重要的认知三：**事件分发是「深度优先 + 焦点门禁 + 短路」**。",
  "--   统一模板（56-62、105-110、112-118、124-138、72-99 五处完全同构）：",
  "--     ① 自己没焦点 → 直接 return false（107、127、74、57）",
  "--     ② 遍历 children，**只对 v.focus 为真的**子控件递归（60、108、116、130、77）",
  "--     ③ 任一子控件返回 true → 立刻 return true（短路，不再问下一个兄弟）",
  "--     ④ 自己再处理（124-138 的 parent_scroll_list；72-99 的 focus_flow）",
  "--   ⇒ 三个后果，全部是设计后果而不是缺陷：",
  "--     · 事件永远先到叶子（最深的焦点控件），符合「最具体优先」；",
  "--     · ★ focus=true 的子控件**互斥**（由 SetFocusFromChild 保证），",
  "--       所以短路与不短路等价——这解释了为什么这里可以放心 pairs()遍历：",
  "--       同一时刻最多一个子控件有焦点。",
  "--     · ⚠ 616ClearFocus 里`if self.focus then` 包着整段递归：如果一个",
  "--       控件 focus 已经是 false，它内部的 focus=true 子控件**不会被清**。",
  "--       见 615-630 的缺陷标注。",
  "--",
  "-- ★★ 关于锚点（配合 frontend.lua 文件头的「没有布局引擎」）：",
  "--   本文件只暴露 SetHAnchor / SetVAnchor（416-422）四个方向的设置入口，",
  "--   以及 SetScaleMode（385）。RegPoint 只在 widgets/image.lua:154-158",
  "--   （贴图自己的对齐点），因为只有带贴图的控件需要它。",
  "--   三者的组合才决定最终位置：父级区域 + Anchor + RegPoint + ScaleMode。",
  "--",
  "-- ★★ 关于坐标（三套，互不相同——这是模组最常踩的坑）：",
  "--   · 局部坐标  GetPosition / GetLocalPosition（340/358）—— 相对**父实体**。",
  "--     ★ 336 GetWorldPosition 与 340 GetPosition 对**同一个 Widget 会返回",
  "--     不同值**，只要它有父级且父级有位移/缩放。",
  "--   · 世界坐标  GetWorldPosition（336）—— 屏幕绝对坐标。",
  "--   · 模拟坐标  Input:GetWorldPosition（input.lua:251）—— 3D 场景投影，",
  "--     UI 拿不到；这就是为什么 UI 点击要经过 entitiesundermouse 中转。",
  "--   · 缩放      GetScale（548）返回**累积**缩放（自己 × 父 × 祖父…），",
  "--     而 GetLooseScale（557）只返回**自身**缩放。两个都要，看用途。",
  "--   ⇒ 708-800 SetHoverText 里手工做了 `world_pos - parent_pos` 再除以",
  "--     parent_scale 的逆运算（778-782），就是在补这套坐标系。",
  "--",
  "-- ★★ 关于暂停（22行 UpdateWhilePaused）：",
  "--   34-44 UpdateWhilePaused 把 DoPeriodicTask / DoTaskInTime 从",
  "--   「模拟时间轴」换成「真实时间轴」（DoStaticPeriodicTask），",
  "--   并同步给 uianim 组件。⇒ **默认所有控件在服务器暂停时继续动**。",
  "--   注释明确要求：依赖玩法的效果要显式传 false。",
  "--   ★ 这是双调度器架构（scheduler.lua 的 scheduler / staticScheduler）",
  "--     在 UI 层的落地，也是「暂停时菜单淡入动画不冻结」的实现方式。",
  "--",
  "-- 关键符号：Widget（类）, children, parent, callbacks, inst,",
  "--   AddChild, RemoveChild, KillAllChildren, Kill,",
  "--   Show, Hide, Enable, Disable, IsVisible, IsEnabled,",
  "--   SetFocus, SetFocusFromChild, ClearFocus, GetDeepestFocus,",
  "--   GetFocusChild, IsDeepestFocus, SetFocusChangeDir, ClearFocusDirs,",
  "--   OnControl, OnMouseButton, OnRawKey, OnTextInput, OnFocusMove,",
  "--   SetFocus, LockFocus, SetParentScrollList, SetHoverText, ClearHoverText,",
  "--   GetTooltip, SetTooltip, SetTooltipPos, SetTooltipColour,",
  "--   ScaleTo, MoveTo, RotateTo, TintTo, CancelScaleTo, CancelMoveTo,",
  "--   CancelRotateTo, CancelTintTo, ForceStartWallUpdating, ForceStopWallUpdating,",
  "--   FollowMouse, StopFollowMouse, MoveToFront, MoveToBack,",
  "--   SetPosition, SetScale, SetHAnchor, SetVAnchor, SetScaleMode,",
  "--   SetScissor, SetClickable, SetFadeAlpha, SetCanFadeAlpha,",
  "--   GetWorldPosition, GetPosition, GetLocalPosition, GetScale, GetLooseScale,",
  "--   UpdateWhilePaused, StartUpdating, StopUpdating, GetStr, GetParentScreen",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 frontend.lua:297-316 —— 消费本文件的 GetDeepestFocus / GetFocusChild",
  "--   ★★ 参见 frontend.lua:403-416 OnFocusMove —— 驱动本文件 72-99 的导航",
  "--   ★★ 参见 frontend.lua:759-761 —— 只有栈顶屏幕才收 OnUpdate",
  "--   ★★ 参见 widgets/screen.lua —— Screen 是 Widget 的唯一直接子类",
  "--   ★★ 参见 components/uianim.lua —— ScaleTo/MoveTo/TintTo 的真正实现",
  "--   ★★ 参见 widgets/scrollablelist.lua:44 —— G2 的原始现场（本文件 77 行是传播路径）",
  "--   ★★ 参见 widgets/button.lua:56 OnControl —— 子类覆盖本文件 124 的典型例子",
  "--   参见 widgets/image.lua:154-158 SetHRegPoint / SetVRegPoint —— RegPoint 只在贴图类",
  "--   参见 widgets/text.lua —— GetRegionSize / SetMultilineTruncatedString 的提供方",
  "--   参见 widgets/scrollablelist.lua —— parent_scroll_list（94/133 行）的赋值方",
  "--   参见 util.lua:1716 FunctionOrValue —— 81 行 focus_flow 的求值器",
  "--   参见 constants.lua:77-81 —— ANCHOR 三值枚举（H 与 V 共用）",
  "--   参见 frontend.lua:1029-1031—— 「alpha 淡出会留下坏状态」的官方警告",
  "--   参见 widgets/imagebutton.lua —— hovertext 用到的 blank.tex（759 行）",
  "--============================================================",
].join("\n");

/* ────────────────────────── 文件头：input.lua ────────────────────────── */

const HEADER_INPUT = [
  "--============================================================",
  "-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖",
  "-- 文件：input.lua（780 行）",
  "-- 模块：UI 系统 / 输入系统（Input，全局单例 TheInput）",
  "-- 职责：把**键盘、鼠标、手柄、Steam Deck 虚拟键盘**四类物理输入",
  "--   抽象成三套语义化事件（按键 / 鼠标 / 控制码），并在input.lua:163",
  "--   完成「UI vs 游戏」的仲裁。同时它承担**控制方案（control scheme）**",
  "--   的解释工作——这是手柄能玩这个游戏的全部秘密（301-477）。",
  "--",
  "-- ★★ 全文件最重要的认知一：**两层抽象，各解决一个问题**。",
  "--   第一层「物理 → 语义」：",
  "--     · Raw key      OnRawKey（186）—— 物理键码 KEY_*，不含设备信息。",
  "--       谁需要「按了退格」这种语义，谁用它。",
  "--     · Control       OnControl（163）—— 抽象动作码 CONTROL_ACCEPT /",
  "--       CONTROL_ATTACK / CONTROL_FOCUS_UP…。**按键绑定在这一层完成**：",
  "--       「A 键」被绑到 CONTROL_ACCEPT，游戏逻辑只认 CONTROL_ACCEPT。",
  "--       ★ 这就是「同一个游戏能被手柄/键鼠/Steam Deck 玩」的根本原因。",
  "--       参见 widgets/controls.lua 与 screens/controlsscreen*.lua。",
  "--   第二层「虚拟控制（VIRTUAL_CONTROL_*)」——**手柄专属的一层**：",
  "--     · 339-477 ResolveVirtualControls 把 VIRTUAL_CONTROL_* 翻译成",
  "--       真正的 CONTROL_*，翻译规则取决于当前控制方案（1..7）。",
  "--     · 为什么需要这一层？因为手柄上「R 摇杆」在方案 4 里是",
  "--       物品栏导航、在方案 5 里是瞄准、在方案 6 里又变回导航。",
  "--       同一个物理输入在不同方案下要打到不同的逻辑控制码上。",
  "--     · ★ VIRTUAL_CONTROL_START = 10000（constants.lua:246）——",
  "--       用一个大偏移把「虚拟层」和「物理层」在同一个整数空间里区分开，",
  "--       于是 IsControlPressed 可以同时接受两种编号并自动判别（480行）。",
  "--       这是本文件最漂亮的一处设计：**用数值区间代替类型系统**。",
  "--",
  "-- ★★ 全文件最重要的认知二：**仲裁点在163-170，只有一处**。",
  "--     if (鼠标可用 or 非鼠标键) and not TheFrontEnd:OnControl(...) then",
  "--         广播给 oncontrol 的全部监听者（游戏层）",
  "--     end",
  "--   · 前端（UI）**先**问，返回 true = UI 吃掉了，这次输入不进游戏层。",
  "--   · 这个顺序是对的（bug-patterns.md G3 的「✅ 正确做法」）。",
  "--   · 但 164-165 行有一个**特例逃逸**：当鼠标不可用（主机/专用服务器）时，",
  "--     CONTROL_PRIMARY / CONTROL_SECONDARY **绕过 UI 直接进游戏层**。",
  "--     ⚠ 疑似缺陷：这条豁免意味着主机上点击 UI 可能漏给游戏层。",
  "--       推理依据见 164-165 行注释。",
  "--",
  "-- ★★ 已收录缺陷 G3 的准确根因链（三处，缺一不可）：",
  "--   【环节一】input.lua:163-170 —— UI 在**抬起帧**才返回 true。",
  "--     Button:OnControl（widgets/button.lua:56）在 down 时只做视觉与音效，",
  "--     返回 true；真正 onclick 在**抬起**时（button.lua:80-86）。",
  "--     而 playercontroller.lua:3133-3137 是**每帧轮询**式读",
  "--     `self:IsControlPressed(CONTROL_PRIMARY)`，不是事件驱动。",
  "--     ⇒ 按下那一帧，轮询读到「鼠标已按下」→ 判定为攻击。",
  "--   【环节二】playercontroller.lua:4603 / 4804 —— 攻击发起时把目标",
  "--     写进 `self.inst.sg.statemem.retarget`，状态图据此继续连击。",
  "--   【环节三】frontend.lua:439-448 —— UI 在抬起帧消费后，",
  "--     **显式把 retarget 清空**（这个 #HACK 就是修复本体）。",
  "--   ★ 为什么必须这样打补丁？因为【环节一】的轮询式设计改不动——",
  "--     playercontroller 有大量「按住持续攻击」的语义需要轮询。",
  "--     ⇒ 结论：G3 的根因是**轮询式消费 + 事件式仲裁**两种模型混用，",
  "--     而不是一个可以「顺手修好」的笔误。",
  "--",
  "-- ★★ 已收录缺陷 G3 之外的 G1/G2/G4 与本文件的关系：",
  "--   · G1（焦点指向已销毁控件）：本文件不参与；根因在",
  "--     widgets/screen.lua:35 与 frontend.lua:1093-1143。",
  "--   · G2（透明 Image 吃焦点）：本文件 515-517 UpdateEntitiesUnderMouse",
  "--     + 263-265 GetAllEntitiesUnderMouse 是「透明 Image 也能吃到鼠标事件」",
  "--     的物理基础——它只按屏幕点做实体拾取，**不关心贴图是否可见**。",
  "--   · G4（屏幕栈状态残留）：本文件 970/1096 的 TheInputProxy:FlushInput()",
  "--     是唯一的「跨屏幕清输入」动作，且只调了两次（PushScreen/PopScreen）。",
  "--     ⚠ InsertScreenUnderTop（frontend.lua:959-965）**没有**FlushInput。",
  "--",
  "-- ★★ 关于「鼠标命中」的两套系统（模组常混）：",
  "--   ① 实体拾取：519-571 OnUpdate 每帧算 entitiesundermouse（3D 世界实体",
  "--      + UI 实体混在一起），559-569 派发 mouseover / mouseout 事件。",
  "--      ★ 由CanMouseThrough（526-557）决定能否「穿透」到下一个实体。",
  "--   ② 屏幕栈事件：179-184 OnMouseButton → frontend.lua:1282 →",
  "--      screen:OnMouseButton → widget.lua:56。",
  "--   ⇒ 一次鼠标点击会**同时**触发这两条路径。UI 控件必须",
  "--     SetClickable(false)（widget.lua:526）才能从路径①里摘掉自己。",
  "--     ★ 这解释了 frontend.lua 里所有浮层都显式 SetClickable(false)",
  "--     （84、94、106、118、128、132、142、146 行）——否则它们会吃点击。",
  "--",
  "-- ★★ 关于 TheInput 全局（740 行）：",
  "--   `TheInput = Input()` 在**文件末尾**创建，而不是文件开头。",
  "--   原因：Class 构造与若干函数体只需要在**调用时**存在，",
  "--   而 4-6 行的原注释说明了真正的原因——历史遗留。",
  "--     \"--V2C: WELL! this should've been local... =(\"",
  "--     \"--     TheInput is the correct global to reference\"",
  "--     \"--     At this point, gotta leave it in case MODs are using the wrong one =/\"",
  "--   ★ 即：因为模组历史上错误地引用了全局 `Input`（而不是 TheInput），",
  "--     官方不敢把它改成 local。**这是「破坏性重构」在长生命周期项目里",
  "--     成本的一个真实样本**——一个 7 字符的改动被一个笔误永久锁死。",
  "--",
  "-- 关键符号：Input（类）, onkey, onkeyup, onkeydown, onmousebutton,",
  "--   position, oncontrol, ontextinput, ongesture,",
  "--   AddKeyHandler, AddKeyUpHandler, AddKeyDownHandler,",
  "--   AddMouseButtonHandler, AddMoveHandler, AddControlHandler,",
  "--   AddGeneralControlHandler, AddControlMappingHandler, AddGestureHandler,",
  "--   AddTextInputHandler, OnControl, OnRawKey, OnText, OnGesture,",
  "--   OnMouseButton, OnMouseMove, OnPosition, OnFrameStart, OnUpdate,",
  "--   IsControlPressed, GetAnalogControlValue, ResolveVirtualControls,",
  "--   GetActiveControlScheme, SupportsControllerFreeAiming,",
  "--   SupportsControllerFreeCamera, ControllerAttached, ControllerConnected,",
  "--   GetControllerID, CacheController, ClearCachedController, TryRecacheController,",
  "--   EnableAllControllers, DisableAllControllers, EnableMouse,",
  "--   UpdateEntitiesUnderMouse, GetAllEntitiesUnderMouse,",
  "--   GetWorldEntityUnderMouse, GetHUDEntityUnderMouse,",
  "--   GetScreenPosition, GetWorldPosition, GetWorldXZWithHeight,",
  "--   GetLocalizedControl, GetLocalizedVirtualControl, IsControlMapped,",
  "--   ControlsHaveSameMapping, GetControlIsMouseWheel, GetInputDevices,",
  "--   OpenVirtualKeyboard, AbortVirtualKeyboard, OnFloatingTextInputDismissed",
  "-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本",
  "-- 交叉引用：",
  "--   ★★ 参见 frontend.lua:419-450 OnControl —— 仲裁的UI 侧实现（G3 补丁）",
  "--   ★★ 参见 frontend.lua:220-221 —— FrontEnd 构造时注册的两个全局处理器",
  "--   ★★ 参见 components/playercontroller.lua:3132-3137 —— G3 的轮询侧",
  "--   ★★ 参见 components/playercontroller.lua:511 IsControlPressed —— handler 分叉",
  "--   ★★ 参见 widgets/button.lua:56-93 OnControl —— 为什么消费发生在抬起帧",
  "--   ★★ 参见 widgets/widget.lua:124-138 —— CONTROL_SCROLL 的滚动列表回退",
  "--   参见 widgets/controls.lua —— 实际把物理键绑到 CONTROL_* 的界面",
  "--   参见 screens/controlsscreen_ps4.lua / controlsscreen.lua —— 绑定界面",
  "--   参见 constants.lua:109-250 —— CONTROL_* / VIRTUAL_CONTROL_* 全部枚举",
  "--   参见 constants.lua:246 VIRTUAL_CONTROL_START = 10000 —— 虚拟层分界",
  "--   参见 constants.lua:227 CONTROL_CAM_AND_INV_MODIFIER —— R 摇杆修饰键",
  "--   参见 strings.lua STRINGS.UI.CONTROLSSCREEN.INPUTS —— 本地化查表",
  "--   参见 inputproxy（C++ 侧）TheInputProxy —— 所有 GetDigitalControl 的落点",
  "--   参见 frontend.lua:970 / 1096 —— FlushInput 的两个调用点",
  "--   参见 prefabs —— CanMouseThrough 事件的响应方（实体侧的鼠标穿透）",
  "--   参见 events.lua:13 EventProcessor —— 本文件全部事件的底层容器",
  "--============================================================",
].join("\n");

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
  // ★ 额外守卫：注释里不得含换行符。规格里写成 "...\n..." 时，
  //   JS 字符串里的 \n 会变成真换行，导致注入后出现「半行注释」——
  //   后半行不以 -- 开头，会被当成代码行，破坏 verify-annotated。
  if (/[\r\n]/.test(line)) {
    throw new Error(
      `规格错误 @${where}: 注释内含换行符（请拆成两条独立注释）-> ${JSON.stringify(line)}`
    );
  }
}

async function build(srcFile, outFile, header, specFiles) {
  const BEFORE = {};
  const AFTER = {};
  const headerExtra = [];

  for (const sf of specFiles) {
    const specUrl = pathToFileURL(sf).href;
    const mod = await import(specUrl);
    for (const raw of [mod.HEADER_EXTRA ?? []].flat(Infinity)) {
      for (const h of String(raw).split("\n")) {
        if (h.trim() === "") continue;
        headerExtra.push(h);
        assertComment(h, `HEADER_EXTRA(${sf})`);
      }
    }
    for (const field of [
      ["BEFORE", BEFORE],
      ["AFTER", AFTER],
    ]) {
      const [name, target] = field;
      for (const [k, v] of Object.entries(mod[name] ?? {})) {
        if (target[k] !== undefined) target[k] = [...target[k], ...v];
        else target[k] = v;
      }
    }
  }

  const raw = readFileSync(join(SRC_ROOT, srcFile), "utf8");
  const srcLines = raw.split("\n");
  expandKeysInPlace(BEFORE, srcLines, "BEFORE");   // 锚点键 → 行号键（M8）
  expandKeysInPlace(AFTER, srcLines, "AFTER");

  const out = [header.replace(/\n$/, "")];
  for (const h of headerExtra) out.push(h);

  let injected = 0;

  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `BEFORE[${lineno}]`);
        out.push(c);
        injected++;
      }
    }

    out.push(srcLines[i]); // ← 代码行永远原样取自源文件

    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `AFTER[${lineno}]`);
        out.push(c);
        injected++;
      }
    }
  }

  const missing = [];
  for (const key of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) {
    throw new Error(`规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = out.join("\n");
  mkdirSync(dirname(outFile), { recursive: true });
  writeFileSync(outFile, text, "utf8");

  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  const cross = (text.match(/参见 /g) || []).length;
  const commented = new Set([
    ...Object.keys(BEFORE).map(Number),
    ...Object.keys(AFTER).map(Number),
  ]);
  let cov = 0;
  for (const k of commented) if (k >= 1 && k <= srcLines.length) cov++;

  console.log(`✔ 已生成: ${outFile}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`);
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷⚠      : ${warn}`);
  console.log(`  交叉引用参见    : ${cross}`);
  console.log(
    `  保护标记在前10行: ${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】")) ? "是" : "否"
    }`
  );
}

async function main() {
  const which = process.argv[2] || "all";
  if (which === "all" || which === "frontend") {
    await build(
      "frontend.lua",
      join(OUT_ROOT, "frontend.lua"),
      HEADER_FRONTEND,
      [
        join(__dirname, "spec-ui-frontend-p1.mjs"),
        join(__dirname, "spec-ui-frontend-p2.mjs"),
        join(__dirname, "spec-ui-frontend-p3.mjs"),
        join(__dirname, "spec-ui-frontend-p4.mjs"),
      ]
    );
  }
  if (which === "all" || which === "widget") {
    await build(
      "widgets/widget.lua",
      join(OUT_ROOT, "widgets/widget.lua"),
      HEADER_WIDGET,
      [
        join(__dirname, "spec-ui-widget-p1.mjs"),
        join(__dirname, "spec-ui-widget-p2.mjs"),
        join(__dirname, "spec-ui-widget-p3.mjs"),
      ]
    );
  }
  if (which === "all" || which === "input") {
    await build(
      "input.lua",
      join(OUT_ROOT, "input.lua"),
      HEADER_INPUT,
      [
        join(__dirname, "spec-ui-input-p1.mjs"),
        join(__dirname, "spec-ui-input-p2.mjs"),
        join(__dirname, "spec-ui-input-p3.mjs"),
      ]
    );
  }
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});