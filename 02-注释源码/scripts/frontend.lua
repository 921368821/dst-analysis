--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：frontend.lua（1655 行）
-- 模块：UI 系统 / 前端总控（FrontEnd，全局单例 TheFrontEnd）
-- 职责：DST 全部界面层的中枢。它把四件通常拆开的事塞进同一个类：
--   ① 屏幕栈（screenstack）—— 界面压栈 / 出栈 / 交叉淡化的调度；
--   ② 输入仲裁—— 判定「这次输入归 UI 还是归游戏」；
--   ③ 焦点管理 —— 跨屏幕的记忆与恢复；
--   ④ 全屏演出层—— 淡入淡出、标题、服务器暂停挂起、存档指示器。
--   它是**纯客户端**文件：服务端不加载它（无 network 段、无 mod_protect）。
--
-- ★★ 全文件最重要的认知一：★「DST 的 UI 没有布局引擎」。
--   你在本文件里找不到任何 layout / flex / grid / align-content 代码。
--   每一个控件的位置都由三组**锚点**手工算出：
--     · Anchor  （控件自身对齐到父级的哪一点）—— SetHAnchor / SetVAnchor
--       取值 constants.lua:77-81，只有三个：
--         ANCHOR_MIDDLE=0 / ANCHOR_LEFT=1(==ANCHOR_TOP) / ANCHOR_RIGHT=2(==ANCHOR_BOTTOM)
--         ★ 注意 79 与 80 行：左右与上下共用同一套数值枚举（1/2），
--           所以H 用 ANCHOR_LEFT、V 用 ANCHOR_TOP 都是 1。
--     · RegPoint（贴图自身哪一点对齐到 Anchor）—— SetHRegPoint / SetVRegPoint
--       定义在 widgets/image.lua:154-158，不在本文件。
--         例：77-82 行 blackoverlay 把 Anchor 与 RegPoint 都设成 MIDDLE，
--         于是「屏幕正中」而不是「左上角贴图」。
--     · ScaleMode（怎么缩放）—— SetScaleMode，constants.lua:83-87 五种：
--         SCALEMODE_NONE / FILLSCREEN / PROPORTIONAL /
--         FIXEDPROPORTIONAL / FIXEDSCREEN_NONDYNAMIC。
--   最终位置的计算发生在 C++ 层的 UITransform，Lua 只负责把三个参数喂给它。
--   ★ 为什么不用自动布局？（这是一个影响很大的设计决策）
--     ① DST 的 UI 是**美术驱动**的：所有界面都是手绘 NineSlice 贴图
--        按固定像素尺寸拼出来的，图就是布局。用自动布局反而要写
--        「把这张 240×80 的图在 4 个按钮里居中」这类约束求解代码。
--     ② 游戏**同时**要服务 720p / 1080p / 4K / 主机安全区 / 分屏，
--        但同一张贴图必须看起来一样。自动布局会按内容重新分配空间，
--        美术的比例关系就崩了；锚点 + 缩放模式则保证「整体等比放大」，
--        参见 1225 GetProportionalHUDScale 与 1233 GetHUDScale。
--     ③ 玩家可见信息**密度极高**且随版本变化（DLC 加了新页签）。
--        自动布局需要「最小尺寸 + 溢出 + 滚动」三件套；DST 的做法是
--        每个具体界面（widgets/crafting.lua、widgets/menu.lua）自己算好坐标。
--     ⇒ 代价：任何要写新界面的人，都得**手算每一个子控件的坐标**，
--       且分辨率相关的偏移必须手写（例：368-385 UpdateHelpTextSize 里
--       splitscreen_scale 要按 1.8 / 1.63 分别硬编码，字体缩放靠 SetSize）。
--       这是 DST 模组做 UI 最大的摩擦点。
--
-- ★★ 全文件最重要的认知二：**焦点是一条链，不是一个指针**。
--   `self.focus` 是每个控件自己的布尔标记；「当前焦点」= 从
--   screenroot 往下走，唯一一条 focus==true 的路径（GetDeepestFocus）。
--   所以 Focus 的传播（widgets/widget.lua:632 SetFocusFromChild）必须
--   「清兄弟 +向上冒泡」。焦点不是从根往下的单指针，而是**路径**。
--
-- ★★ 全文件最重要的认知三：**仲裁发生在分发之前，但消费发生在分发之中**。
--   input.lua:163-170 的Input:OnControl 先问 TheFrontEnd:OnControl，
--   返回 true 就不再广播给游戏层。这是**正确的**仲裁位置（见 G3 修复）。
--   但 419-450 的历史补丁说明：当 UI 在**抬起帧**才消费时，
--   按下帧已经漏给游戏层了，于是必须**事后**取消游戏层的中间状态。
--   ⇒ 理解本文件的关键是理解 G3 这条补丁，它暴露了架构的真实缺陷。
--
-- 已收录缺陷对照（本文件相关部分）：
--   G1「焦点指向已销毁控件」→ 触发点在本文件 1151 GetActiveScreen 无校验，
--      校验只在 widgets/screen.lua:35；根因分析见该行与 1093-1143 PopScreen。
--   G2「透明 Image 吃焦点」→ 实例在 widgets/scrollablelist.lua:44；
--      本文件 widget.lua:77 / 129 的 `if v.focus` 递归是它能生效的传播路径。
--   G3「按下/抬起两帧导致误攻击」→ 根因行 frontend.lua:439-448（补丁本体）、
--      input.lua:163-170（仲裁位置）、playercontroller.lua:3132（另一侧补丁）。
--   G4「UI 状态残留（屏幕栈互相污染）」→ 根因行 frontend.lua:1103-1113
--      （PopScreen 按对象弹出时**不**成对调OnBecomeInactive）；
--      对称基类见 widgets/screen.lua:28-43。
--
-- ★★ 关于「三循环暂停语义」：
--   DST 的暂停由mainfunctions.lua:914DoAutopause 统一裁决，输入是三个
--   计数器（autopausecount / craftingautopause / consoleautopausecount）。
--   本文件是它的**触发方**而非决策方：
--     · 575-577 SetFadeLevel 与 1032-1057 Fade 都调DoAutopause()，
--       因为「淡出期间必须暂停」，否则淡出动画里世界还在跑；
--     · ★ 398IsControlsDisabled 是反向闸门：淡出中/错误弹窗时禁用输入，
--       于是 DoAutopause 的 `and not TheFrontEnd:IsControlsDisabled()`
--       成立 → 自动暂停。**这是个隐式耦合**：UI 的淡入淡出状态直接
--       决定世界是否暂停。任何在Fade 期间误调 SetFadeLevel(0) 的代码，
--       都会导致世界在弹窗打开时继续跑（已收录D2 家族问题）。
--     · 暂停时 UI 仍要动，靠 widgets/widget.lua:22 UpdateWhilePaused(true)
--       —— 它把 DoPeriodicTask 换成 DoStaticPeriodicTask（真实时间轴），
--       参见 scheduler.lua 的 sim/static 双调度器设计。
--
-- 关键符号：FrontEnd（类）, screenstack, screenroot, overlayroot,
--   PushScreen, PopScreen, ClearScreens, InsertScreenUnderTop,
--   InsertScreenAtIndex, ShowScreen, GetActiveScreen, GetOpenScreenOfType,
--   IsScreenInStack, GetScreenStackSize, FadeToScreen, FadeBack,
--   OnControl, OnFocusMove, OnRawKey, OnTextInput, OnMouseButton, OnMouseMove,
--   GetFocusWidget, GetIntermediateFocusWidgets, LockFocus, ClearFocus,
--   StopTrackingMouse, DoHoverFocusUpdate, SetForceProcessTextInput,
--   SetFadeLevel, GetFadeLevel, DoFadingUpdate, HideTopFade, ShowTopFade,
--   GetProportionalHUDScale, GetHUDScale, GetCraftingMenuScale,
--   UpdateRepeatDelays, IsControlsDisabled, StartUpdatingWidget,
--   StopUpdatingWidget, CheckCachedError, SetGlobalErrorWidget
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 widgets/widget.lua —— 控件基类（焦点链、事件分发、锚点 API）
--   ★★ 参见 widgets/screen.lua:28-43 OnBecomeInactive/OnBecomeActive —— 焦点记忆
--   ★★ 参见 input.lua:163-170 Input:OnControl —— UI 与游戏的输入仲裁点
--   ★★ 参见 mainfunctions.lua:914 DoAutopause —— 暂停语义的唯一裁决点
--   ★★ 参见 components/playercontroller.lua:3132 —— G3 的另一侧补丁
--   参见 components/playercontroller.lua:2635 GetCombatRetarget —— retarget 读取点
--   参见 widgets/screen.lua:34 TheSim:SetUIRoot —— C++ 把输入路由到哪棵子树
--   参见 widgets/scrollablelist.lua:44 —— G2 透明Image 吃焦点的原始现场
--   参见 components/uianim.lua:148 OnWallUpdate 的 IsValid 守卫 —— 补间存活检查
--   参见 constants.lua:77-81 —— ANCHOR 枚举（左右与上下共用的三值枚举）
--   参见 constants.lua:83-87 —— SCALEMODE 五种缩放模式
--   参见 constants.lua:109 CONTROL_PRIMARY=0 / :147 CONTROL_ACCEPT=29
--     —— 为什么 431-435 行要把 PRIMARY 映射成 ACCEPT
--   参见 screens/playerhud.lua:462 —— InsertScreenUnderTop 的唯一调用点
--   参见 easing.lua —— 本文件全部淡入淡出曲线（inOutCubic / outCubic / linear）
--   参见 widgets/templates.lua —— TEMPLATES.BackgroundVignette 等复用浮层
--============================================================
-- ────────────────────────────────────────────────────────────────
-- 段 1/8：模块引入与常量（1-40）
-- ────────────────────────────────────────────────────────────────
local easing = require("easing")
-- 【easing 曲线库】本文件所有淡入淡出都走它。注意用的是 Lua 函数
-- 形参风格 easing.inOutCubic(t, from, delta, duration)，**不是**
-- 「缓动函数对象」，所以同一条曲线可以在任意 (from, to) 上复用。
-- 参见 easing.lua 全文件。
local Widget = require "widgets/widget"
-- ★ 循环依赖风险点：frontend 依赖 widget，而 widgets/screen.lua 也
-- 依赖 widget。widget.lua **不** require frontend（只通过全局
-- TheFrontEnd 反向调用，见 486/490 行）—— 这是刻意的，用来打破环。
local DebugPanel2 = CAN_USE_DBUI and require("dbui_no_package/debug_panel2") or nil
local DebugEntity = CAN_USE_DBUI and require("dbui_no_package/debug_entity") or nil
local DebugNodes = CAN_USE_DBUI and require("dbui_no_package/debug_nodes") or nil
-- 【文本控件】Text 是 DST 的富文本控件（字体 / 描边 / 多行截断）。
-- 参见 widgets/text.lua 的 SetMultilineTruncatedString（本文件 903 行用到）。
local Text = require "widgets/text"
-- 【UIAnim】补间动画的驱动实体，独立成一个 widget 而不是一个组件，
-- 是因为存档指示器（198-207）需要它当独立渲染节点。
-- 补间能力本体在 components/uianim.lua，widget.lua:166-210 是转发层。
local UIAnim = require "widgets/uianim"
local Image = require "widgets/image"
local ConsoleScreen = require "screens/consolescreen"
local DebugMenuScreen = require "screens/DebugMenuScreen"
local PopupDialogScreen = require "screens/popupdialog"
-- ★ Redux（新版）弹窗与旧版弹窗并存。12 行是 redux 版，11 行是旧版。
--   判据：文件路径 screens/redux/ 前缀 = 新 UI 体系（2020 后重写）。
--   前端总控必须同时持有两个类，因为 1384/1399/1424 仍在用旧版。
local PopupDialogScreenRedux = require "screens/redux/popupdialog"
local TEMPLATES = require "widgets/templates"
local ServerPauseWidget = require "widgets/redux/serverpausewidget"

-- ★ 注意这两个 require 写在所有 local 之后——require 不是声明性的，
--   它在执行到这一行时才跑，所以顺序有语义（依赖前面已定义的变量）。
require "constants"
require "splitscreenutils_pc"

local MotdManager = require "motdmanager"

-- ────────────────────────────────────────────────────────────────
-- 【输入重复率常量】—— 这是「按住方向键连续移动焦点」的速度参数。
-- ★ 四个常量分属四类不同的重复语义，值也差一个数量级：
--   REPEAT_TIME = .15 —— 菜单导航（方向键），手感最慢，
--     因为焦点移动会触发控件重建，走太快会漏。
--   SCROLL_REPEAT_TIME = .05 —— 滚动条，极快，因为滚动只是位移。
--   MOUSE_SCROLL_REPEAT_TIME = 0 —— 鼠标滚轮，**故意为 0**。
--     ⚠ 推理依据：滚轮本身就有硬件级连发（每个滚轮齿就是一个事件），
--     再加软件重复会导致一格滚一屏。0 在 787-808 行被当作「立即触发」
--     的哨兵值使用（793/804 行 `repeat_time > dt and repeat_time - dt or 0`）。
--   SPINNER_REPEAT_TIME = .25 —— 数字微调器（spinner），最慢，
--     因为每一次会改一个具体数值（合成数量 / 数量选择）。
-- ⇒ 设计启示：重复率不是全局配置，而是**按控件类**分别调出来的。
--────────────────────────────────────────────────────────────────
local REPEAT_TIME = .15
local SCROLL_REPEAT_TIME = .05
local MOUSE_SCROLL_REPEAT_TIME = 0
local SPINNER_REPEAT_TIME = .25

-- ────────────────────────────────────────────────────────────────
-- 【帮助文本（手柄提示条）】—— 游戏里屏幕底部那行"A 接受 / B 返回"。
-- ★ 26 行原注释 "-- dunno where this magic number came from"
--   是 Klei 工程师自己也不知道来历的注释——典型的「考古遗留」。
--   HELP_TEXT_SCALE_FACTOR = 1/63：背景宽度 = RESOLUTION_X/63 + 8，
--   也就是背景宽度恒为「屏幕宽度的 1.58% 再加 8 像素」。
--   8 是 27 行的魔数补偿；为何要 +8 已无从考证。
-- ★ 为什么背景要跟着 RESOLUTION_X 算？→ 因为 SCALEMODE_PROPORTIONAL
--   下控件会等比缩放，写死像素会导致不同分辨率下背景与文字不匹配。
--   参见 153 行 self.helptext:SetScaleMode(SCALEMODE_PROPORTIONAL)。
--────────────────────────────────────────────────────────────────
local HELP_TEXT_SCALE_FACTOR = 1/63	-- dunno where this magic number came from
local HELP_TEXT_BG_SCALE_X = RESOLUTION_X * HELP_TEXT_SCALE_FACTOR + 8 
local HELP_TEXT_BG_SCALE_Y = 2 * HELP_TEXT_SCALE_FACTOR
local HELP_TEXT_BG_HEIGHT = 80
-- ★ HELP_TEXT_MAX_LINES = 2 与 129 行 help_height 的关系：
--   行数由实际文本量决定（903 行 SetMultilineTruncatedString 返回），
--   背景高度随之变（379-382 行）。所以提示条不会因为文字多而被裁掉。
local HELP_TEXT_FONT_SIZE = 30
local HELP_TEXT_MAX_LINES = 2
local HELP_TEXT_MAX_WIDTH = RESOLUTION_X * .95
local HELP_TEXT_MAX_CHARS_PER_LINE = 130
-- ⚠ 分屏专用常量：分屏时每个视口只有约一半宽，字号不变的话每行
--   能放的字符数会锐减，所以降到 80。否则提示文本会折成 4 行
--   撑破 2 行的上限（HELP_TEXT_MAX_LINES）而被截断。
--   判据在 150 行 self.is_splitscreen = HaveMultipleViewports()。
local HELP_TEXT_MAX_CHARS_PER_LINE_SPLITSCREEN = 80

-- 存档指示器的淡入淡出时长（秒）。刻意用局部变量而非 self 字段，
-- 因为它同时被 ShowSavingIndicator（262）与 Update（737/747/739）引用，
-- 作为常量比字段更安全（字段可以被意外改写）。
local save_fade_time = .5

-- ⚠ CAN_USE_DBUI（开发者 UI 扩展）在正式包里为 false，
--   因此 38 行 require 的结果是 nil，后面 246/1468/1528 全部短路。
--   这些代码路径在零售版**从不执行**，等于死代码——
--   但模组开发版会开启，所以仍需维护。
local DebugMenu = CAN_USE_DBUI and require("dbui_no_package/debugmenu") or nil

-- ────────────────────────────────────────────────────────────────
-- 【全局错误锁】global_error_widget 是一个**裸全局**（无 local）。
-- ★ 它的作用是「一票否决」：一旦非nil，IsControlsDisabled（397-401）
--   就返回 true，于是所有输入被冻结、PushScreen 的早退分支生效。
--   配套逻辑在 1635-1655：SetGlobalErrorWidget 只是**缓存**错误参数，
--   真正弹窗推迟到 CheckCachedError——因为构造错误弹窗本身可能再次出错，
--   必须先离开错误现场（见 1651-1652 的原注释）。
--   ⚠ 风险：它是全局且无处清空。ResetGlobalErrorWidget（1641）
--     实际**不改** global_error_widget，只把缓存清空——名字有误导性。
--────────────────────────────────────────────────────────────────
global_error_widget = nil

-- ════════════════════════════════════════════════════════════════
-- ★★ 段 2/8：FrontEnd 构造函数（42-254）—— UI 根与浮层的建立
--
-- ★★★ 本构造函数是理解「DST 的 UI 组织结构」的唯一入口。
--   最终的实体层级如下（AddChild 的调用顺序 = 渲染层级序）：
--
--   screenroot                （45行，is_screen=true）
--     ├─ blackoverlay（77）    全屏黑色遮罩，用于「黑场淡出」
--     ├─ whiteoverlay（121）全屏白色遮罩 + vigoverlay 暗角
--     ├─ vigoverlay  （131）  暗角（暗场淡出用）
--     ├─ swipeoverlay（97）   噪声贴图 + swipe_fade.ksh 着色器
--     ├─ consoletext （53）   控制台/日志文本（永远最前的文本）
--     └─ serverpausewidget（72）服务器暂停挂起提示
--     ※ 注意上面这七个是**后加的**（169-179 行），它们压在所有
--       PushScreen 进来的屏幕之上（这也是 983-984/955-956 反复
--       MoveToFront 的原因）。
--
--   overlayroot               （49 行，独立根）
--     ├─ helptext / helptextbg / helptexttext（152-167）手柄提示条
--     ├─ globalwidgetroot（65）  全局小挂件（成就横幅等）
--     ├─ topblackoverlay  （87） ★ 与 screenroot 里的blackoverlay
--     │  是**同一张图的两个实例**，一个在屏幕栈之下、一个之上。
--     │  用途：淡出期间先遮 top 层、再遮底层，避免看到中间的弹窗。
--     ├─ topwhiteoverlay  （135）同上
--     ├─ topvigoverlay   （145）同上
--     ├─ topswipeoverlay （109）同上
--     ├─ title / subtitle（183-195）大标题（"YOU ARE DEAD" 等）
--     └─ consoletext? 否——consoletext 在 screenroot 里（见上）
--
--   ★ 为什么 overlayroot 要独立于 screenroot？
--     因为 ClearScreens（1002-1011）会while 循环清空 screenstack，
--     overlayroot 不在其中 → 标题、提示条在切场景时不会被清掉。
--   ★ 为什么「top」系列要压在屏幕栈之上？
--     FadeToScreen（1059）淡出时，弹出新屏前先把整个场景盖住，
--     盖住之后才切换。top 层负责「盖住切屏的那一瞬间」，
--     底层负责「切完之后继续保持」。参见 1041-1042 的原注释：
--     "--     this place it can actually be out of sync with the backfade"。
--   ★ 三重遮罩（bottom / top × white / black / swipe）共 8 个 Image，
--     全部 SetClickable(false)（84/94/106/118/128/132/142/146），
--     否则它们会吃掉鼠标事件。→ 这就是 widget.lua:526 SetClickable。
-- ════════════════════════════════════════════════════════════════
FrontEnd = Class(function(self, name)
-- ★★★ 【屏幕栈】self.screenstack 是**唯一**的界面调度结构。
--   它是一个**普通 Lua 数组**，栈顶 = #self.screenstack。
--   · 压栈PushScreen（967）
--   · 出栈   PopScreen（1093）
--   · 特殊压栈 InsertScreenUnderTop（959）—— HUD 用它把弹窗开在暂停屏之下
--   · 全清   ClearScreens（1002）
--   ⇒ 界面层级完全由「栈里第几层」决定，没有 z-index 概念。
--   ⚠ 缺陷 G4 的舞台就在这里：栈存的是**对象引用**，
--     出栈时既可能调 OnBecomeInactive 也可能不调（见 1103-1113）。
	self.screenstack = {}

-- 【UI 根 · screenroot】它是一个**没有实体的抽象容器**——
-- 注意 45 行 Widget("screenroot") 虽然会 CreateEntity（widget.lua:7），
-- 但它自身不渲染任何东西，纯粹作为所有 Screen 的公共父节点。
-- ★ 46-47 行两个标记：
--   global_widget = true —— 该控件即使没有焦点也能收到事件
--     （用于「永远在后台监听」的控件，如存档指示器）。
--   is_screen = true —— 它是**屏幕**而非普通控件。
--     ★ 这是 widget.lua:254 GetParentScreen 的while 循环的终止条件：
--       `while(not parent.is_screen) do parent = parent:GetParent() end`。
--       ⚠ 若某个控件的祖先里没有 is_screen 标记的祖先（比如被
--         AddChild 到一个游离控件上），这个 while 会**死循环/崩**。
--       widget.lua:633-636 那段 print+debugstack 就是在警告这种误用。
	self.screenroot = Widget("screenroot")
    self.screenroot.global_widget = true
    self.screenroot.is_screen = true

-- 【UI 根 · overlayroot】与 screenroot 平级，独立存在。
-- 50 行同样标 global_widget —— 它要能穿透屏幕栈接收事件。
	self.overlayroot = Widget("overlayroot")
    self.overlayroot.global_widget = true

-- ────────────────────────────────────────────────────────────────
-- 【控制台文本块】53-62 行。
-- ★ 注意这是**同时演示锚点四要素**的最小样本：
--   54SetVAlign(ANCHOR_BOTTOM) + 55 SetHAlign(ANCHOR_LEFT)
--     → 内容在区域内的对齐（Align）
--   56 SetVAnchor(ANCHOR_MIDDLE) + 57 SetHAnchor(ANCHOR_MIDDLE)
--     → 区域本身在父级里的锚点（Anchor）
--   58 SetScaleMode(SCALEMODE_PROPORTIONAL)
--     → 区域随分辨率等比缩放
-- ★★ Align 与 Anchor 是**两个正交的概念**，新手最容易混：
--   · Anchor：这个矩形贴父级的哪一点
--   · Align：内容在这个矩形里怎么排布（左上/居中/右下）
--   · RegPoint：贴图自身的哪一点对齐到 Anchor（见 image.lua:154）
--   ★ 本文件里**只有 Image 类控件设了 RegPoint**（78-79/88-89 等），
--     因为 Align/Anchor 对纯文本控件已经够用。
--────────────────────────────────────────────────────────────────
	------ CONSOLE -----------
	self.consoletext = Text(BODYTEXTFONT, 20, "CONSOLE TEXT")
	self.consoletext:SetVAlign(ANCHOR_BOTTOM)
	self.consoletext:SetHAlign(ANCHOR_LEFT)
    self.consoletext:SetVAnchor(ANCHOR_MIDDLE)
    self.consoletext:SetHAnchor(ANCHOR_MIDDLE)
	self.consoletext:SetScaleMode(SCALEMODE_PROPORTIONAL)

-- 60-61 行：把文本区域固定成 900×406 并钉在 (0,0,0)。
-- ★ 这个尺寸是**硬编码像素**，在 4K 下靠 58 行的 PROPORTIONAL
--   等比放大才能看起来一样大。这就是「锚点+缩放模式」相对
--   自动布局的代价：尺寸是美术定的，不是算出来的。
	self.consoletext:SetRegionSize(900, 406)
	self.consoletext:SetPosition(0,0,0)
	self.consoletext:Hide()
    -----------------

-- 【globalwidgetroot】装成就弹出横幅、临时提示这类小挂件。
-- ★ 它的子控件是 global_widget 树上的节点，靠 global_widget 标记
--   穿透屏幕栈收事件（46/50/66 三处标记就是这个用途）。
	self.globalwidgetroot = Widget("globalwidgetroot")
	self.globalwidgetroot.global_widget = true
	self.globalwidgetroot:SetVAnchor(ANCHOR_MIDDLE)
	self.globalwidgetroot:SetHAnchor(ANCHOR_MIDDLE)
	self.globalwidgetroot:SetScaleMode(SCALEMODE_PROPORTIONAL)

	------ SERVERPAUSE -----------
-- 【ServerPauseWidget】—— 服务器暂停时挂起的那个提示。
-- ★ 为什么它单独一个控件而不是文本？见 985行 PushScreen 里的
--   `self.serverpausewidget:SetOffset(0, 0)` 与 987-989 的
--   `screen.OffsetServerPausedWidget` 可选钩子：不同屏幕会
--   用不同的视觉样式（比如结束结算屏要换颜色），框架给屏幕
--   一个「自己调偏移」的机会。
--   参见 widgets/redux/serverpausewidget.lua 与 1631 SetServerPauseText。
	self.serverpausewidget = ServerPauseWidget()
	self.serverpausewidget:SetPosition(0,0,0)
	self.serverpausewidget:Hide()
    -----------------

-- ────────────────────────────────────────────────────────────────
-- 【全屏遮罩家族】77-147 行，8 个 Image，结构完全同构：
--   SetVRegPoint / SetHRegPoint  → ANCHOR_MIDDLE（RegPoint：贴图自身中心）
--   SetVAnchor  / SetHAnchor     → ANCHOR_MIDDLE（Anchor：区域贴屏幕中心）
--   SetScaleMode(SCALEMODE_FILLSCREEN) → 拉伸铺满
--   SetClickable(false)          → 不吃鼠标
--   Hide()                       → 默认不显示
-- ★★ 这一段是「锚点定位」讲得最清楚的样本：
--   要让一张square.tex（1×1 白块）铺满全屏，需要三件事同时成立：
--     ① RegPoint = MIDDLE → 缩放以贴图中心为基准
--     ② Anchor  = MIDDLE → 区域中心对齐屏幕中心
--     ③ ScaleMode = FILLSCREEN → 区域尺寸 = 屏幕尺寸
--   若把 78 行改成 ANCHOR_TOP，遮罩就会锚在屏幕顶部且拉伸时错位。
--   ★ 为什么遮罩用 square.tex（纯色方块）而不是全屏图片？
--     因为纯色可以用 SetTint（83行）任意染色，一张图四种用途。
--   ★ 为什么 tint 的 alpha 初始是 0（83行）而不是直接Hide？
--     因为 Fade 动画要能直接改 alpha，不需要先 Show 再改。
--────────────────────────────────────────────────────────────────
    self.blackoverlay = Image("images/global.xml", "square.tex")
    self.blackoverlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.blackoverlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.blackoverlay:SetVAnchor(ANCHOR_MIDDLE)
    self.blackoverlay:SetHAnchor(ANCHOR_MIDDLE)
    self.blackoverlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.blackoverlay:SetTint(0,0,0,0)
	self.blackoverlay:SetClickable(false)
	self.blackoverlay:Hide()

    self.topblackoverlay = Image("images/global.xml", "square.tex")
    self.topblackoverlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.topblackoverlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.topblackoverlay:SetVAnchor(ANCHOR_MIDDLE)
    self.topblackoverlay:SetHAnchor(ANCHOR_MIDDLE)
    self.topblackoverlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.topblackoverlay:SetTint(0,0,0,0)
	self.topblackoverlay:SetClickable(false)
	self.topblackoverlay:Hide()

-- 【swipe 淡出】唯一使用着色器的遮罩：98 行 SetEffect("shaders/swipe_fade.ksh")。
-- ★ 643 行 SetEffectParams(progress, phase_1, 0, 0) 驱动它：
--   progress 0→0.5→1 走「噪声擦除」的完整周期；
--   phase_1 在 636-641 行按 FADE_IN / FADE_OUT 决定擦除方向。
--   ⇒ 这是纯视觉的转场，与 black/white 的 alpha 淡出互不干扰。
-- ★ 100-104 与 112-116 两组的RegPoint/Anchor/ScaleMode 完全相同，
--   唯一差别是 99 vs 111 行的 SetEffectParams 初值——
--   top 层初始 progress=0，bottom 层初始 0.5。
--   ⚠ 推理依据：两者都Show 时，叠加的视觉效果是 progress 相加；
--     但 1044-1051 行 Fade 里 top 层会被重置为 0，说明设计意图是
--     「top 层单独负责转场瞬间，bottom 层负责转场全程」。
	self.swipeoverlay = Image("images/global.xml", "noise.tex")
	self.swipeoverlay:SetEffect( "shaders/swipe_fade.ksh" )
	self.swipeoverlay:SetEffectParams(0.5,0,0,0)
    self.swipeoverlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.swipeoverlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.swipeoverlay:SetVAnchor(ANCHOR_MIDDLE)
    self.swipeoverlay:SetHAnchor(ANCHOR_MIDDLE)
    self.swipeoverlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.swipeoverlay:SetTint(1,1,1,0)
	self.swipeoverlay:SetClickable(false)
	self.swipeoverlay:Hide()

	self.topswipeoverlay = Image("images/global.xml", "noise.tex")
	self.topswipeoverlay:SetEffect( "shaders/swipe_fade.ksh" )
	self.topswipeoverlay:SetEffectParams(0,0,0,0)
    self.topswipeoverlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.topswipeoverlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.topswipeoverlay:SetVAnchor(ANCHOR_MIDDLE)
    self.topswipeoverlay:SetHAnchor(ANCHOR_MIDDLE)
    self.topswipeoverlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.topswipeoverlay:SetTint(1,1,1,0)
	self.topswipeoverlay:SetClickable(false)
	self.topswipeoverlay:Hide()

-- 【白场淡出】FADE_WHITE_COLOUR 是「纯白」的三通道常量。
-- ⚠ 注意 127 行只取了 [1][2][3]，alpha 硬编码为 0。
--   Fade 时由 601 行用实际的 alpha 参数重设。
	self.whiteoverlay = Image("images/global.xml", "square.tex")
    self.whiteoverlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.whiteoverlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.whiteoverlay:SetVAnchor(ANCHOR_MIDDLE)
    self.whiteoverlay:SetHAnchor(ANCHOR_MIDDLE)
    self.whiteoverlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.whiteoverlay:SetTint(FADE_WHITE_COLOUR[1], FADE_WHITE_COLOUR[2], FADE_WHITE_COLOUR[3], 0)
	self.whiteoverlay:SetClickable(false)
	self.whiteoverlay:Hide()

-- 【暗角遮罩】TEMPLATES.BackgroundVignette() —— 复用模板而非裸Image。
-- ★ 这是 DST UI 的通用做法：TEMPLATES（widgets/templates.lua）里
--   有一整套预制好的窗口/按钮/背景，界面直接组装。
--   参见报告 04 第 10 节「一个 Screen 就是在构造函数里从模板
--   组装出来的一棵 Widget 树」。
	self.vigoverlay = TEMPLATES.BackgroundVignette()
	self.vigoverlay:SetClickable(false)
	self.vigoverlay:Hide()

    self.topwhiteoverlay = Image("images/global.xml", "square.tex")
    self.topwhiteoverlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.topwhiteoverlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.topwhiteoverlay:SetVAnchor(ANCHOR_MIDDLE)
    self.topwhiteoverlay:SetHAnchor(ANCHOR_MIDDLE)
    self.topwhiteoverlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.topwhiteoverlay:SetTint(FADE_WHITE_COLOUR[1], FADE_WHITE_COLOUR[2], FADE_WHITE_COLOUR[3], 0)
	self.topwhiteoverlay:SetClickable(false)
	self.topwhiteoverlay:Hide()

-- topvigoverlay —— 顶层的暗角版本，与 131 行同构。
	self.topvigoverlay = TEMPLATES.BackgroundVignette()
	self.topvigoverlay:SetClickable(false)
	self.topvigoverlay:Hide()
	
-- ────────────────────────────────────────────────────────────────
-- ★★ 分屏（Splitscreen）适配点。
--   self.is_splitscreen = HaveMultipleViewports() —— 主控一开分屏，
--   就切换到另一套排版常量（150 行）。
-- ★ 为什么这里要单独处理？同屏 2/4 分屏下每个视口只有 1/2 或1/4 宽，
--   而 26-33 行的帮助文本常量是按全屏设计的。
--   ⇒ 这是「没有布局引擎」的代价的典型体现：**分辨率/视口变化
--     必须在每个具体位置手工处理**，本文件里至少三处：
--       · 149-150 分屏字符数
--       · 369-372 分屏缩放系数（含 XBONE 特判）
--       · 1252-1255 合成菜单缩放区间（IsSplitScreen 分支）
--────────────────────────────────────────────────────────────────
	self.is_splitscreen = HaveMultipleViewports()
	self.helptext_max_characters_per_line = (self.is_splitscreen and HELP_TEXT_MAX_CHARS_PER_LINE_SPLITSCREEN) or HELP_TEXT_MAX_CHARS_PER_LINE

-- ────────────────────────────────────────────────────────────────
-- 【帮助文本组件树】152-167 行，三层：
--   helptext      （152）空容器，只负责定位：H=MIDDLE, V=BOTTOM
--     ├─ helptextbg（157）黑色半透明背景条
--     └─ helptexttext（163）实际文字
-- ★ 152 行 SetScaleMode(SCALEMODE_PROPORTIONAL) 与 67-69 行
--   globalwidgetroot 用的是同一个模式：让子树的缩放跟随统一的
--   HUD 缩放系数（见 1233 GetHUDScale）。
-- ★ 155 行 SetVAnchor(ANCHOR_BOTTOM)：提示条钉在屏幕底部。
--   154 行 SetHAnchor(ANCHOR_MIDDLE)：水平居中。
--   ⇒ 「底部居中」这个需求在**两行内**表达完毕——这就是锚点定位
--     相对 CSS flex 的简洁之处（虽然也因此无法自动适应内容）。
--────────────────────────────────────────────────────────────────
	self.helptext = self.overlayroot:AddChild(Widget("HelpText"))
	self.helptext:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.helptext:SetHAnchor(ANCHOR_MIDDLE)
    self.helptext:SetVAnchor(ANCHOR_BOTTOM)

    self.helptextbg = self.helptext:AddChild(Image("images/global.xml", "square.tex"))
-- ★ 背景条的缩放：X 用 HELP_TEXT_BG_SCALE_X（= 屏宽/63 + 8），
--   Y 用「80 * 2/63」。80 是 HELP_TEXT_BG_HEIGHT（29 行）。
--   ⇒ 高度 = 行数 × 字号 × 系数，26 行的 1/63 同时控制宽高比例。
	self.helptextbg:SetScale(HELP_TEXT_BG_SCALE_X, HELP_TEXT_BG_HEIGHT * HELP_TEXT_BG_SCALE_Y)
	self.helptextbg:SetPosition(0, -HELP_TEXT_BG_HEIGHT/2)
-- ⚠ 160 行原代码是注释掉的 SetClickable(false)，第 161 行紧随其后。
--   ★ 推理：这个注释掉是**有意为之**——帮助文本背景条需要吃鼠标
--     hover，让鼠标移到提示条上时不会掉回下层界面。
--   ⚠ 但它的副作用是：提示条出现在屏幕上时，它所在区域（屏幕底部
--     一条 1.6% × N 行的高度）会**吞掉该区域的所有点击**。
--     对照 84/94/106 等其它浮层都显式 SetClickable(false)，
--     这里显得不一致。这是一处「用实现细节凑需求」的痕迹
--     —— 与缺陷 G2（透明图元吃焦点）是同一个模式。
--	self.helptextbg:SetClickable(false)
	self.helptextbg:SetTint(0,0,0,.75)

	self.helptexttext = self.helptext:AddChild(Text(UIFONT, HELP_TEXT_FONT_SIZE))
	self.helptexttext:SetPosition(0, -5)
	self.helptexttext:SetHAlign(ANCHOR_LEFT)
	self.helptexttext:SetVAlign(ANCHOR_TOP)
-- ★ self.helptextstring 是**缓存键**：894-906 行用它判断文本是否变化，
--   没变就不重排版（重排要跑 SetMultilineTruncatedString，很贵）。
--   ⇒ 缓存与渲染分离是 DST UI 的通用优化模式。
	self.helptextstring = ""

-- ────────────────────────────────────────────────────────────────
-- ★★ 【层级装配】169-179 行 —— 把所有浮层挂到对应的根上。
--   overlayroot（49行）：helptext(152) + globalwidgetroot(65) +
--     topblack/topwhite/topvig/topswipe —— 全部在**屏幕栈之上**。
--   screenroot（45 行）：black/white/vig/swipe + consoletext +
--     serverpausewidget —— 在**屏幕栈之下**（但自己是最后挂的，
--     所以在 screenroot 内排在所有 Screen 之上）。
-- ★★ 这里藏着一个**关键的隐式约定**：
--   `screenroot:AddChild(screen)`（981 行 PushScreen）把新屏挂在
--   screenroot 的**末尾**，即压在 blackoverlay 等遮罩**之上**。
--   ⇒ 所以 PushScreen 后必须 983-984 把 consoletext / serverpausewidget
--     MoveToFront，否则控制台文本会被新屏盖住。
--   ⚠ 缺陷 G4 的结构性根因就在这个约定里：界面层级 = 挂载顺序 =
--     栈顺序，三者被绑死，无法独立调整。
--────────────────────────────────────────────────────────────────
    self.overlayroot:AddChild(self.globalwidgetroot)
	self.overlayroot:AddChild(self.topblackoverlay)
	self.overlayroot:AddChild(self.topwhiteoverlay)
	self.overlayroot:AddChild(self.topvigoverlay)
	self.overlayroot:AddChild(self.topswipeoverlay)
-- ★ 注意这里的顺序（黑→白→暗角→swipe→控制台→暂停挂起）：
--   后挂的盖在先挂的上面。所以「swipe 遮罩」会盖住「黑遮罩」，
--   但控制台文本又会盖住所有遮罩——即淡出时控制台文字依然可见。
	self.screenroot:AddChild(self.blackoverlay)
	self.screenroot:AddChild(self.whiteoverlay)
	self.screenroot:AddChild(self.vigoverlay)
	self.screenroot:AddChild(self.swipeoverlay)
	self.screenroot:AddChild(self.consoletext)
    self.screenroot:AddChild(self.serverpausewidget)

-- ★ self.alpha = 0 —— **淡出强度的权威状态**。
--   IsControlsDisabled（397）读它，GetFadeLevel（648）返回它，
--   SetFadeLevel（575）改它。
--   ⇒ 这一个 float 同时控制「视觉不透明度」与「输入是否冻结」，
--     详见文件头关于「三循环暂停语义」的说明。
    self.alpha = 0

-- 【大标题】183-188。TITLEFONT + 100 号字，居中，(0,-30)。
-- ★ ShowTitle（499）里会 Show 它并触发 StartTileFadeIn。
--   淡入淡出由 DoTitleFade（509）逐帧驱动。
    self.title = Text(TITLEFONT, 100)
    self.title:SetPosition(0, -30, 0)
    self.title:Hide()
    self.title:SetVAnchor(ANCHOR_MIDDLE)
    self.title:SetHAnchor(ANCHOR_MIDDLE)
	self.overlayroot:AddChild(self.title)

    self.subtitle = Text(TITLEFONT, 70)
    self.subtitle:SetPosition(0, 70, 0)
    self.subtitle:Hide()
    self.subtitle:SetVAnchor(ANCHOR_MIDDLE)
    self.subtitle:SetHAnchor(ANCHOR_MIDDLE)
	self.overlayroot:AddChild(self.subtitle)

-- ⚠ IsConsole() 分支：主机平台才创建存档指示器（198-207）。
--   ⇒ 261/731 的 ForceStartWallUpdating/ForceStopWallUpdating 在
--     widget.lua:213/223 也用 IsConsole() 做了同样的短路，两处一致。
    if IsConsole() then
        self.saving_indicator = UIAnim()
        self.saving_indicator:GetAnimState():SetBank("saving_indicator")
        self.saving_indicator:GetAnimState():SetBuild("saving_indicator")
        self.saving_indicator:GetAnimState():PlayAnimation("save_loop", true)
        self.saving_indicator:SetVAnchor(ANCHOR_BOTTOM)
        self.saving_indicator:SetHAnchor(ANCHOR_RIGHT)
        self.saving_indicator:SetScaleMode(SCALEMODE_PROPORTIONAL)
        self.saving_indicator:SetMaxPropUpscale(MAX_HUD_SCALE)
        self.saving_indicator:SetPosition(-10, 40)
        self.saving_indicator:Hide()
    end

-- 构造末尾把标题隐藏。注意 541HideTitle 还会重置 fade_title_* 状态，
-- 直接 Hide() 不会——构造阶段这三个字段还是 nil，507-518 行的
-- `if self.fade_title_in == true or ...` 恰好能容错。
	self:HideTitle()

-- ────────────────────────────────────────────────────────────────
-- 【gameinterface】212-218 —— 把「全局 UI 服务」挂成一个假实体。
-- ★ 这是 DST 的经典手法：SoundEmitter / GraphicsOptions /
--   TwitchOptions / AccountManager 都是需要实体宿主的服务，
--   这里造一个 GameInterface 实体来装它们。
--   消费入口是 559-573 四个小转发函数（GetSound / GetGraphicsOptions /
--   GetTwitchOptions / GetAccountManager）。
-- ★ 为什么转发成 4 个函数而不是让外面直接 self.gameinterface.X？
--   因为 gameinterface 只在构造时创建一次，字段访问路径很浅，
--   转发函数的价值是**给出一个稳定的公共 API**，防止外部依赖内部结构。
--   ★ 注意 213 行 AddSoundEmitter() 是创建而非获取——它初始化了
--     音效发射器。所有 UI 音效最终都经过它（408、561 等处）。
--────────────────────────────────────────────────────────────────
	self.gameinterface = CreateEntity("GameInterface")
	self.gameinterface.entity:AddSoundEmitter()
	self.gameinterface.entity:AddGraphicsOptions()
	if IsNotConsole() then
		self.gameinterface.entity:AddTwitchOptions()
	end
	self.gameinterface.entity:AddAccountManager()

-- ★★★ 【输入注册】220-221 行 —— FrontEnd 在构造时就把自己
--   挂到了 Input 的全局处理器上。
--   220 行 AddKeyHandler  → input.lua:187 onkey:HandleEvent("onkey")
--   221 行 AddTextInputHandler → input.lua:196 ontextinput:HandleEvent("text")
-- ★ 注册时机在构造期意味着：**TheFrontEnd 一旦创建就永久收输入**，
--   与屏幕栈是否为空无关（栈空时OnRawKey 里有 screen ~= nil 守卫，
--   见 1198-1199）。
-- ⚠ 注意没有注册 OnControl / OnMouseButton / OnMouseMove——
--   那三个不是走 EventProcessor，而是 input.lua:166/175/181 里
--   **直接调用** TheFrontEnd:xxx。两种注册方式的区别见 input.lua 头部。
	TheInput:AddKeyHandler(function(key, down) self:OnRawKey(key, down) end )
	TheInput:AddTextInputHandler(function(text) self:OnTextInput(text) end )

-- ★★ self.tracking_mouse —— 「鼠标焦点跟随」开关（鼠标与手柄两套导航的仲裁点）。
--   · true  = 鼠标动→ 焦点跟着鼠标走（DoHoverFocusUpdate 925-939）
--   · false = 焦点被手柄/键盘接管，鼠标移动不再抢焦点
-- ★ 谁把它置false？
--   · 409/412：OnFocusMove 成功（手柄导航了）
--   · 972/1097：PushScreen/PopScreen 里那两行**已被注释掉**的赋值
--   · 387StopTrackingMouse：外部显式停
--   · 1301-1303：OnMouseMove 里**两个坐标都变**时重新置 true
-- ★ 1301 行的 `self.lastx ~= x and self.lasty ~= y` 是「与」不是「或」，
--   ⇒ 鼠标沿单轴滑动（x变 y不变）**不会**恢复跟随。这是有意的：
--   避免手柄导航过程中鼠标被微动打断。⚠ 但也意味着手柄玩家若想
--     切回鼠标，必须点一下按钮（OnMouseButton 1287 无条件置 true）。
	self.tracking_mouse = true

-- ★ 构造期调用 UpdateRepeatDelays（1267）：把 Profile 里的
--   合成/物品栏灵敏度设置换算成三个重复率基值。
--   存档加载后 Profile 可能才可用，所以这个函数在别处还会被调用。
	self:UpdateRepeatDelays() -- crafting menu and inventory navigation

-- ────────────────────────────────────────────────────────────────
-- 【连发计数器】227-230 行。三个计时器都初始化为 -1。
-- ★ 为什么是 -1 而不是 0？因为 0 是「立即触发」的哨兵值——
--   Update 里用 `< 0` 判断「尚未起跳」、用 `> dt` 判断「冷却中」。
--   若初始化为 0，772行的 `SPINNER_REPEAT_TIME > dt and ... or 0`
--   首次求值会走 or 分支拿到 0，语义混乱。
--   ⇒ -1 是一个明确的「无状态」哨兵。参见 769-772 的三段式。
--────────────────────────────────────────────────────────────────
	self.repeat_time = -1
	self.repeat_reps = 0
    self.scroll_repeat_time = -1
    self.spinner_repeat_time = -1

-- ★ topFadeHidden —— top 层遮罩是否被 HideTopFade（277）藏起来了。
--   604/620/627 三处 `if not self.topFadeHidden then` 依赖它。
--   用它可以做到「压淡入遮罩但保留其它类型」。
	self.topFadeHidden = false

-- ★★ self.updating_widgets = setmetatable({}, {__mode="k"})
--   **弱键表**。这是本文件第二个漂亮的设计：
--   · 谁想每帧更新 → StartUpdatingWidget（941）把自己塞进去；
--   · Update（883-892）遍历这张表调 k:OnUpdate(dt)；
--   · ★ 不需要遍历整棵控件树（widgets/ 有 183 个控件类，
--     一个界面轻松几百个Widget，逐帧递归遍历会爆）。
--   · ★ 弱引用意味着：控件被 Kill 后，条目**自动消失**，
--     不需要写反注册。widget.lua:489 StopUpdating 显式摘除只是更快。
--   ⚠ 代价：GC 会回收条目，若某个控件的更新「恰好」无人引用就停了。
--     这在实践中不会发生（控件总被 parent.children 引用），
--     但它意味着「注册了但没人引用」的控件会静默停止更新。
--   ★ 883-892 用 updating_widgets_alt 做**快照**再遍历：
--     因为 OnUpdate 里可能 StartUpdating/StopUpdating，
--     直接遍历正在修改的表是未定义行为。⚠ 但清空用的是 alt 表
--     （891 行），原表不清——所以「本次没被 alt 覆盖的条目」会残留。
--     实际正确：887 循环里 891 把 alt 清空，而原表只在Stop 时清。
--     ⇒ 结果等价，但多了一次表拷贝。这是「安全优先」的取舍。
	self.updating_widgets = setmetatable({}, {__mode="k"})
-- 存档系统与 UI 的对接：num_pending_saves 是引用计数（256/271）。
-- ★ 必须引用计数而不是布尔：多个存档操作可能同时在飞。
	self.num_pending_saves = 0
	self.save_indicator_time_left = 0
	self.save_indicator_fade_time = 0
	self.save_indicator_fade = nil
	self.autosave_enabled = true

-- ⚠ 调试 UI（imgui）初始化：242-247 行只在开发版执行。
--   244 行从 Profile 读持久化的字体大小——说明调试面板的偏好
--   会存进存档设置里（与 1573-1578 SetImguiFontSize 配对）。
    if CAN_USE_DBUI then
        self.imgui = require("dbui_no_package/imgui")
        self.debug_panels = {}
        self.imgui_font_size = Profile:GetValue("imgui_font_size") or 1

        self.debugMenu = DebugMenu()
    end

-- ────────────────────────────────────────────────────────────────
-- ★★ 249-251 原注释解释了一个「看起来很怪」的设计：
--   self.match_results = {} 永不清空（原注释：
--   "Never set this to nil or people will crash"）。
--   它是「本局游戏的结果」，用来在从服务器重置回大厅时，
--   让结算界面还能读到上一局的胜负数据。
--   ★ 为什么不能置 nil？因为界面代码里到处直接索引这个表，
--     置 nil 会产生 "attempt to index nil"。
--   ⇒ 典型取舍：**用空表代替 nil**，换取「调用方不必判空」。
--     与之呼应，原注释明确要求「需要时测长度来控制流程」。
--────────────────────────────────────────────────────────────────
    -- data from the current game that is to be passed back to the game when the server resets (used for showing results in events when back in the lobby)
    -- Never set this to nil or people will crash. If needed, test for empty list if needed to control flow.
    self.match_results = {}

-- 【MotdManager】登录时的「消息-of-the-day」推送。
--   属于 UI 层但业务上是网络层，参见 motdmanager.lua。
	self.MotdManager = MotdManager()
end)

-- ════════════════════════════════════════════════════════════════
-- 段 3/8：存档指示器与浮层显隐（256-296）
-- ════════════════════════════════════════════════════════════════
function FrontEnd:ShowSavingIndicator()
-- ★ 双重守卫：saving_indicator 存在（主机平台，197-208）
--   且存储系统可用（主机不支持本地存档时为 false）。
--   ⇒ PC 上第一个条件为 false，256-269 整个函数是空操作。
    if self.saving_indicator ~= nil and TheSystemService:IsStorageEnabled() then
-- ★ if not self.saving_indicator.shown then —— 幂等保护。
--   多个并发存档请求里只有第一个会真正显示指示器，
--   但 267 行 num_pending_saves 仍然全部累加。
--   ⇒ 「显示一次、计数多次」是这里的核心设计。
		if not self.saving_indicator.shown then
			self.save_indicator_time_left = 3
			self.saving_indicator:Show()
-- ★ ForceStartWallUpdating（widget.lua:212）→ uianim 的
--   StartWallUpdatingComponent：让补间用真实时间轴驱动。
--   存档指示器是一个 save_loop 循环动画（201行），
--   ★ 服务器暂停时它必须继续转——这就是 22 行 UpdateWhilePaused
--     机制的具体应用。
			self.saving_indicator:ForceStartWallUpdating()
			self.save_indicator_fade_time = save_fade_time
			self.saving_indicator:GetAnimState():SetMultColour(1,1,1,0)
			self.save_indicator_fade = "in"
		end

	    self.num_pending_saves = self.num_pending_saves + 1
	end
end

-- ★★ HideSavingIndicator（271-275）是**只减计数不改显示**：
--   真正的淡出由 745-748 行触发（num_pending_saves <= 0 且超时）。
--   ⇒ 「最后一次保存完成」+「至少显示 3 秒」两个条件都满足才淡出。
--   为什么要有最短显示时间？⚠ 推理：快速连续存档时指示器会闪一下，
--     闪烁是明显的视觉噪音。3 秒（259 行）是体验取舍。
function FrontEnd:HideSavingIndicator()
	if self.saving_indicator ~= nil and self.num_pending_saves > 0 then
		self.num_pending_saves = self.num_pending_saves - 1
	end
end

-- ────────────────────────────────────────────────────────────────
-- 【topFade 显隐】277-295。四个 top 遮罩的批量开关。
-- ★★ 注意 ShowTopFade（285）**依赖 self.fade_type** 这个外部设置，
--   而 fade_type 由 Fade（1037）设置。所以正确调用序是：
--     Fade(FADE_OUT, ...) → 1052 ShowTopFade → 1043-1051 重置参数
--   ⚠ 缺陷风险：若外部直接调 ShowTopFade 而没先设 fade_type，
--     四个分支都不命中 → 什么都不显示，且 topFadeHidden 已被置 false，
--     后续 Fade 的 `if not self.topFadeHidden` 会尝试操作已隐藏的图。
--     这是「用字符串当状态机标签」的典型脆弱点。
--────────────────────────────────────────────────────────────────
function FrontEnd:HideTopFade()
	self.topwhiteoverlay:Hide()
	self.topvigoverlay:Hide()
	self.topblackoverlay:Hide()
	self.topswipeoverlay:Hide()
	self.topFadeHidden = true
end

function FrontEnd:ShowTopFade()
	self.topFadeHidden = false
	if self.fade_type == "white" then
		self.topwhiteoverlay:Show()
		self.topvigoverlay:Show()
	elseif self.fade_type == "black" then
		self.topblackoverlay:Show()
	elseif self.fade_type == "swipe" then
		self.topswipeoverlay:Show()
	end
end

-- ════════════════════════════════════════════════════════════════
-- 段 4/8：★ 焦点查询 API（297-366）—— G1 的第一现场
-- ════════════════════════════════════════════════════════════════
function FrontEnd:GetFocusWidget()
-- ★★★ 【GetFocusWidget】—— 「当前焦点控件」的定义式。
--   定义：栈顶屏幕的**最深**焦点控件。
--   为什么不是遍历 self.focus？
--   → 因为 focus 是一条**从根到叶的路径**（不是全局唯一指针），
--     路径上的每个节点都是 focus=true。GetDeepestFocus（widget.lua:592）
--     就是「从自己开始，一路往有焦点的子节点下钻，到底了返回自己」。
--   ★ 两条隐含前提：
--     ① 只看栈顶屏幕（屏幕栈以下的屏幕即便有焦点也不算数）
--     ② 栈顶屏幕必须自身 focus=true——由 screen.lua:36
--       `self.last_focus:SetFocus()` 与 1128 `top_screen:SetFocus()`
--       保证。若栈顶屏幕 focus 为false，本函数返回 **nil**。
--   ⚠ 缺陷 G1 的触发路径正在这里：GetDeepestFocus 逐层下钻时
--     **不校验节点是否已被 Kill**。如果 Screen.last_focus 指向一个
--     已销毁控件（screen.lua:35 虽有 IsValid 检查，但模组自写的
--     Screen 可能没有），这条链会返回一个野对象。
--────────────────────────────────────────────────────────────────
	if #self.screenstack > 0 then
		return self.screenstack[#self.screenstack]:GetDeepestFocus()
	end
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【GetIntermediateFocusWidgets】—— 焦点链的「中间段」。
--
-- ★★ 这是本文件最巧妙也最脆弱的函数之一。
-- 它做的是：从栈顶屏幕的「焦点子节点」开始，沿 GetFocusChild
-- 往下走，直到遇到「最深焦点」为止，把途经的控件全部收集起来。
--
-- 举例：栈顶屏幕 root(focus) → dialog(focus) → scroller(focus) → btn(focus)
--   · GetFocusWidget()       = btn（最深）
--   · GetIntermediateFocusWidgets() = [dialog, scroller]（中间两段）
--
-- ★ 用途：GetHelpText（318）用它拼接「滚动条提示 + 按钮提示」。
--   因为玩家在滚动列表里时，既要知道「怎么滚」也要知道「怎么点」，
--   焦点链天然携带了这条信息。
-- ⇒ 这就是为什么「焦点必须是链而不能是指针」：
--   链上的每一段都可能有自己的提示文本与独占优先级。
-- ⚠ 缺陷 G1 的第二现场：309 行的循环条件是
--   `while nextWidget and nextWidget ~= self:GetFocusWidget()`。
--   ★ 这意味着 **GetFocusWidget 被重算了一次**（每轮迭代都调），
--     而 GetFocusWidget 会再走一遍 GetDeepestFocus 整条链。
--     ⇒ O(n²) 的链遍历。链长通常 <10，性能无碍，但结构浪费。
--   ⚠ 更严重的：若 GetDeepestFocus 返回 nil（栈顶屏幕 focus=false），
--     循环条件 `nextWidget ~= nil` 会变成「只要 nextWidget 非nil就继续」，
--     一直走到 nextWidget 为 nil 才停——不会死循环（会返回全部中间段），
--     但**返回值的语义已经错了**（多收了本不该收的）。
--   ⚠ 若链上有环（模组错误地让 A 的焦点子节点是 B、B 的是 A），
--     这里的 while 会**无限循环**。框架层没有任何深度上限保护。
--────────────────────────────────────────────────────────────────
function FrontEnd:GetIntermediateFocusWidgets()
	if #self.screenstack > 0 then
		local widgs = {}
-- ⚠ 306 行的 `if self.screenstack[#self.screenstack] then` 是**死代码**：
--   304 行已经保证 #self.screenstack > 0，而 1..n 位的元素不可能是 nil
--   （table.insert 不会插入 nil）。
--   ⇒ 说明作者自己也不确定栈内元素是否可能为 nil——
--     这与 303 行函数头的 `if #self.screenstack > 0 then` 重复。
--   ★ 教训：Lua 表可以持有 nil 值（长度语义特殊），
--     防御性判空在这里不是错，只是被外层条件覆盖了。
		if self.screenstack[#self.screenstack] then
			local nextWidget = self.screenstack[#self.screenstack]:GetFocusChild()

			while nextWidget and nextWidget ~= self:GetFocusWidget() do
				table.insert(widgs, nextWidget)
				nextWidget = nextWidget:GetFocusChild()
			end
		end
		return widgs
	end
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【GetHelpText】—— 焦点链 + 独占优先级的完整实现。
--
-- ★ 三层文本来源，从粗到细：
--   ① 屏幕级（324-330）：active_screen:GetHelpText()
--   ② 中间控件级（333-350）：滚动条等「中间段」控件的提示
--   ③ 叶控件级（353-363）：最深焦点控件的提示
-- 最后用 table.concat(t, "  ")（365 行）双空格拼接。
--
-- ★★ 「HasExclusiveHelpText」是这个函数的核心机制（324/339/354）：
--   任何一层声明自己「独占」，就**清空整个t** 只留自己。
--   ⇒ 优先级：叶控件独占 > 中间控件独占 > 屏幕独占 > 累加。
--   这是「多来源文本」的经典仲裁方式——不需要框架预先知道
--   谁比谁重要，让内容自己声明。
-- ★ 325 行的条件值得逐字读：
--   `if active_screen_exclusivehelp or active_screen and active_screen ~= widget`
--   ⇒ 屏幕级提示只在「屏幕自己独占」或「屏幕不是最深焦点控件」
--     时才取。注意这里**没有** `IsVisible()` 检查——
--     隐藏的屏幕如果还在栈里也会贡献文本。⚠ 见G4 分析。
-- ★ 336 行的 `v.GetHelpText` 是**鸭子类型探测**：
--   不是所有控件都有 GetHelpText，有才调。这是 DST 少用继承多用
--   「有就用」的探测式接口风格（对比 widget.lua:336 GetHelpText 的空实现）。
--────────────────────────────────────────────────────────────────
function FrontEnd:GetHelpText()
	local t = {}

	local widget = self:GetFocusWidget()
-- ★ active_screen 可能为 nil（栈空），所有使用处都做了 `and` 短路。
--   ⇒ 325 行 `active_screen_exclusivehelp or active_screen and ...`
--     依赖 Lua 的 and/or 优先级：and 优先于 or，所以等价于
--     `exclusivehelp or (active_screen and (active_screen ~= widget))`。
--     写法紧凑但可读性差——**典型的 Lua 遗留风格**。
    local active_screen = self:GetActiveScreen()

-- ★ 三重 and/or 链：`A and A:HasExclusiveHelpText() or false`。
--   显式 `or false` 是为了让结果严格是布尔值，
--   因为 HasExclusiveHelpText 可能返回 nil。
--   ⇒ 326 行因此不必再判一次。
    local active_screen_exclusivehelp = active_screen and active_screen.HasExclusiveHelpText and active_screen:HasExclusiveHelpText() or false
	if active_screen_exclusivehelp or active_screen and active_screen ~= widget then
-- ⚠ 326 行直接active_screen:GetHelpText()。
--   走到这里时 325 行已保证 active_screen 非nil（因为 active_screen ~= widget
--   时 active_screen 必须非 nil；exclusivehelp 为真时 active_screen 也非 nil，
--   因为 324 的 `active_screen and ... or false` 会把 nil 归一为 false）。
--   ⇒ 逻辑上安全，但**依赖对324 行短路语义的精确理解**，
--     可读性差。改动 324 行会静默打破 326 行。
		local str = active_screen:GetHelpText()
		if str ~= nil and str ~= "" then
			table.insert(t, str)
		end
	end

-- ★★★ 原注释 "-- Show the help text for secondary widgets, like scroll bars"
--   这行英文注释是理解 333-350 那段代码的钥匙：
--   「次级控件」= 焦点链上的中间段，不是叶子。
--   在 DST 里最典型的次级控件就是 ScrollableList 的滚动条——
--   玩家在列表里移动焦点时，滚动条自己有提示（"X 键滚动"）。
--   ⇒ 若焦点只是指针（不保留链），就**无法**表达这个需求。
	-- Show the help text for secondary widgets, like scroll bars
	local intermediate_widgets = self:GetIntermediateFocusWidgets()
	if not active_screen_exclusivehelp and intermediate_widgets then
		for i,v in ipairs(intermediate_widgets) do
			if v and v ~= widget and v.GetHelpText then
				local str = v:GetHelpText()
				if str and str ~= "" then
-- ★ 独占优先级的第二次应用：中间控件也可以独占。
--   341 行 t = {} 清空，然后 break——后续中间段不再处理。
					if v.HasExclusiveHelpText and v:HasExclusiveHelpText() then
						-- Only use this widgets help text, clear all other help text
						t = {}
						table.insert(t, v:GetHelpText())
						break
					else
						table.insert(t, v:GetHelpText())
					end
				end
			end
		end
	end

	-- Show the help text for the focused widget
-- ★ 叶控件的独占处理354-357：清空 t 后才继续。
--   注意它**先清空再添加**（359-361行），保证叶控件独占时
--   结果恰好是「只有叶控件的文本」。
	if not active_screen_exclusivehelp and widget and widget.GetHelpText then
		if widget.HasExclusiveHelpText and widget:HasExclusiveHelpText() then
			-- Only use this widgets help text, clear all other help text
			t = {}
		end

		local str = widget:GetHelpText()
		if str and str ~= "" then
			table.insert(t, widget:GetHelpText())
		end
	end

-- ★ table.concat(t, "  ") —— 双空格分隔。
--   为什么是两个空格？因为单个空格在视觉上分隔度不够，
--   两段提示会糊在一起。这是**纯美术/排版决策**写进了代码。
	return table.concat(t, "  ")
end

-- ════════════════════════════════════════════════════════════════
-- 段 5/8：帮助文本尺寸自适应（368-385）
-- ════════════════════════════════════════════════════════════════
function FrontEnd:UpdateHelpTextSize(num_lines)
-- ★★ 分屏缩放系数1.8 —— 为什么不是 2？
--   分屏时视口宽度减半但字体不用减半（否则太小看不清），
--   所以整体放大 1.8 倍来补偿视觉密度。
--   ⚠ 370-372 的 XBONE 特判 1.63：主机 TV 的观看距离更远、
--     画布更大，同样补偿需要更少的放大倍数。
--   ⇒ 这类「按平台微调」的魔数是**无法参数化的排版经验**，
--     只能一个个平台一个个场景试出来。
--   ★ 369 行还额外要求 `not IsGameInstance(Instances.Overlay)`：
--     Overlay 实例（游戏里弹出的界面，如物品栏）**不缩放**。
	local splitscreen_scale = (self.is_splitscreen and not IsGameInstance(Instances.Overlay)) and 1.8 or 1
	if PLATFORM == "XBONE" and splitscreen_scale == 1.8 then
		splitscreen_scale = 1.63
	end
		
-- ★ 缓存式字号更新：只有 splitscreen_scale 变了才 SetSize。
--   SetSize 会触发字体图集重建，是**昂贵**操作。
--   ⇒ 与 167 行 helptextstring 同属「缓存键避免重复重排」。
	if self.helptext_scale ~= splitscreen_scale then
		self.helptexttext:SetSize(HELP_TEXT_FONT_SIZE*splitscreen_scale)
		self.helptext_scale = splitscreen_scale
	end
	
-- ★ help_height = 80 * scale * num_lines —— 高度随行数线性增长。
--   而 158 行初始化时 num_lines 隐含为 1。
--   ⇒ 背景高度是**动态**的，这解释了为什么 60 行的 SetRegionSize(900,406)
--     对 helptext 不适用（helptexttext 用 384 行的动态值）。
	local help_height = HELP_TEXT_BG_HEIGHT * splitscreen_scale * num_lines

	self.helptextbg:SetScale(HELP_TEXT_BG_SCALE_X, help_height * HELP_TEXT_BG_SCALE_Y)
	self.helptextbg:SetPosition(0, -help_height/2)

	self.helptexttext:SetRegionSize(HELP_TEXT_MAX_WIDTH, help_height)
end

-- ★★ StopTrackingMouse(autofocus) —— 交出鼠标控制权。
--   autofocus=true 时立即给栈顶屏幕一个默认焦点，
--   避免「鼠标交出去了但焦点还停在某个控件上」的中间态。
--   392 行 screen:SetDefaultFocus() → screen.lua:70 → default_focus:SetFocus()。
function FrontEnd:StopTrackingMouse(autofocus)
	self.tracking_mouse = false
    if autofocus then
        local screen = self:GetActiveScreen()
        if screen ~= nil then
            screen:SetDefaultFocus()
        end
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【IsControlsDisabled】—— 整个前端最重要的一行守卫。
--
-- 三个条件，任一成立即冻结所有输入：
--   ① GetFadeLevel() > 0 —— 淡出进行中（任何强度 > 0）
--   ② fadedir == FADE_OUT 且 fade_delay_time == nil
--      → 即「正在淡出、且延迟已过」的状态
--   ③ global_error_widget ~= nil —— 错误弹窗已弹出（40 行）
--
-- ★★ 为什么 ① 用 `> 0` 而不是 `>= 1`？
--   因为 alpha 是连续变化的过渡量（648GetFadeLevel 返回它），
--   淡入过程中 alpha 会从 1 降到 0，但**依然 > 0**，
--   此时输入依然被冻结。→ **淡入完全结束的那一刻才解冻**。
--   ⇒ 后果：玩家在淡入动画播完前按任何键都无效。
--     ⚠ 这是玩家常见抱怨「切屏后按键没反应」的直接原因。
--
-- ★★ 与暂停语义的耦合（文件头「三循环暂停」）：
--   mainfunctions.lua:921 的 DoAutopause 最后一行是
--     `and not TheFrontEnd:IsControlsDisabled()`。
--   ⇒ **UI 的淡入淡出状态直接决定世界是否自动暂停**。
--     这是一个跨文件的隐式耦合：任何在 Fade 期间把 alpha 归零的
--     代码都会让世界「在弹窗打开时继续跑」。
--   ⚠ 反向看：本函数返回 true 时，DoAutopause 会把自动暂停关掉，
--     于是「弹窗打开 → 世界继续跑」与「弹窗打开 → 世界暂停」
--     这两种结果取决于**弹窗是否伴随淡出**，而不是弹窗本身。
--────────────────────────────────────────────────────────────────
function FrontEnd:IsControlsDisabled()
    return self:GetFadeLevel() > 0
        or (self.fadedir == FADE_OUT and self.fade_delay_time == nil)
        or global_error_widget ~= nil
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【OnFocusMove】—— 手柄/键盘的方向导航入口。
--
-- 签名 (dir, down) 与 OnControl 一致：down=false 表示「抬起」
--（比如摇杆回中），down=true 表示「按下/持续」。
--
-- 三条分支：
--   ① 404-405 锁定或门禁 → return true（**消费掉**，不返回 false）
--   ② 407-410 栈顶屏幕处理成功 → 播音效 + 交出鼠标 + return true
--   ③ 411-414 鼠标还在跟随 → 让屏幕自己选个默认焦点
--
-- ★★ 404 行 return **true** 而不是 false，是一个重要的语义决定：
--   「输入被冻结」时应该**消费**输入（return true = 我处理了/我拒绝），
--   否则 input.lua:166 会认为 UI 没处理，把这次方向键广播给游戏层，
--   玩家在淡出时按方向键就会**同时**移动角色。
--   ⚠ 这正是 bug-patterns.md G3 所说的「一个输入事件只被一个消费者处理」
--     的正面例子——本文件做对了，419-450 的补丁是另一处没做对的地方。
--────────────────────────────────────────────────────────────────
function FrontEnd:OnFocusMove(dir, down)
    if self.focus_locked or self:IsControlsDisabled() then
        return true
	elseif #self.screenstack > 0 then
		if self.screenstack[#self.screenstack]:OnFocusMove(dir, down) then
-- ★ 焦点移动成功音效："dontstarve/HUD/click_mouseover_controller"。
--   ★ 用 controller 专属音效而不是通用的 click_mouseover，
--     因为手柄导航的听觉反馈要和鼠标 hover 区分开。
--   对比 widgets/button.lua:110 用的 click_mouseover（鼠标版）。
	   		self:GetSound():PlaySound("dontstarve/HUD/click_mouseover_controller")
-- ★ 焦点被手柄/键盘移动后**立刻**关闭鼠标跟随。
--   ⇒ 一旦发生方向键导航，鼠标就不再抢焦点，直到用户再点一下
--     （OnMouseButton 1287 无条件恢复）。
			self.tracking_mouse = false
			return true
-- ★★ elseif 分支：屏幕自己「吃不下」这次导航，但鼠标还在跟随。
--   这时给屏幕一个默认焦点（992-994 PushScreen 里也有同样调用）。
--   ⇒ 效果：从「鼠标模式」第一次按方向键时，焦点跳到默认控件，
--     而不是「毫无反应」。
--   ⚠ 但 SetDefaultFocus 返回 true 的前提是 default_focus 非 nil
--     （screen.lua:71-74）。没有 default_focus 的屏幕在此**静默失败**，
--     玩家会觉得「方向键没用」。
		elseif self.tracking_mouse and down and self.screenstack[#self.screenstack]:SetDefaultFocus() then
			self.tracking_mouse = false
			return true
		end
	end
end

-- 【ValidateLineNumber(418)】Klei 自研的**源码完整性哨兵**。
-- 展开后是一个运行时断言：确认文件被反混淆/打补丁时行号没有漂移。
-- ★ 本文件有 418/497 两处，正好框住下面这个函数——
--   因为这是历史上被反复修改（V2C 补丁）因而最需要哨兵的位置。
-- 参见 gamelogic.lua 中 ValidateLineNumber 的实现。
ValidateLineNumber(418)
-- ════════════════════════════════════════════════════════════════
-- ★★★ 【FrontEnd:OnControl】—— 输入仲裁的 UI 侧，缺陷 G3 的核心现场。
--
-- 【它回答什么】
--   「这一次 control 的按下/抬起，UI 要不要吃掉？」
--   返回 true = 吃掉（不进游戏层）；false/nil = 不吃，游戏层处理。
--
-- 【完整流程（419-496）】
--   421-423 文本框失焦处理（点别处结束编辑）
--   425      记录 isprimary（这次是主键 = 左键/A键）
--   426-428 门禁：淡出中/错误弹窗 → 消费并返回 false（★ 注意是 false）
--   433-450 栈顶屏幕消费 → ★G3 补丁 → return true
--   452-488 三个调试快捷键（控制台/调试菜单/日志/物理渲染）
--   495      兜底：self.isprimary = false，返回 nil
--
-- ★★ 为什么这是 G3 的现场？因为它是「UI 消费」与「游戏层攻击」
--   之间的**唯一**仲裁点，而 439-448 那段 #HACK 就是在这里打的补丁。
--   详见 439 行处的完整分析。
-- ════════════════════════════════════════════════════════════════
function FrontEnd:OnControl(control, down)
-- ★★ 421-423 行处理一个具体场景：文本框正在被强制处理输入
--   （textProcessorWidget 见 1176 SetForceProcessTextInput），
--   此时玩家在别处点了左键（CONTROL_PRIMARY 且 !down = 抬起帧），
--   于是结束强制输入。
--   ★ 判据是「抬起」而不是「按下」：因为 click 语义（widgets/button.lua:80-86）
--     是在抬起时才真正触发 onclick，若按下就结束输入，
--     按钮收到的将是一个「已经被夺走焦点」的事件。
-- ⚠ 缺陷风险：这里只处理了 CONTROL_PRIMARY（鼠标左键 / 手柄 A）。
--   用键盘 Tab / 方向键移动焦点出文本框**不会**触发它，
--   只能靠 1193 OnRawKey 里的路径（若 textedit 自己实现了）。
    -- if there is a textedit that is currently editing, stop editing if the player clicks somewhere else
    if self.textProcessorWidget ~= nil and not self.textProcessorWidget.focus and not down and control == CONTROL_PRIMARY then
        self:SetForceProcessTextInput(false, self.textProcessorWidget)
    end

-- ★★★ self.isprimary —— 「本次输入是否来自主键」。
--   为什么需要这个全局状态？
--   → widgets/button.lua:64 `if control == self.control and (not self.mouseonly
--     or TheFrontEnd.isprimary)`：Button:SetControl（button.lua:47）
--     在控件由 CONTROL_PRIMARY 构造时把 self.control 改成 CONTROL_ACCEPT、
--     self.mouseonly 置 true。于是 CONTROL_ACCEPT 这个语义键
--     既可能来自鼠标左键，也可能来自手柄 A 键；
--     **只有鼠标按钮需要 TheFrontEnd.isprimary 为真**才响应。
--   ⇒ isprimary 是「让同一个语义键区分物理来源」的状态位。
-- ★ 它在 425 置位、在 437/453/458/463/472/495 全部清零——
--   495 行的无条件清零保证「不消费输入的路径不会留下脏状态」。
-- ⚠ 疑似缺陷：425 置位之后，433-435 调 screen:OnControl 的过程中
--   isprimary 是 true；但如果 OnControl 内部又触发了别的输入处理
--   （例如某个控件 OnControl 里调用了 FocusMove），那个嵌套调用
--   结束时（495 行）会把 isprimary 清成 false，
--   **外层后续逻辑读到的 isprimary 就错了**。
--   推理依据：isprimary 是 self 上的共享可变状态，无栈式保存/恢复。
--   参见 widgets/button.lua:64 的消费点。
    self.isprimary = control == CONTROL_PRIMARY
-- ★★ 426-428 门禁返回的是 **false**（不是 true），与 404-405 的
--   OnFocusMove 门禁（返回 true）**刻意相反**。
--   推理：这里返回 false 意味着「UI 不吃，让游戏层去处理」。
--   ⚠ 但 398-399 的条件（淡出中）意味着游戏层此刻也不该收输入……
--   ⇒ 结果：淡出期间的点击**既不进 UI 也不进 UI 以外的拦截**，
--     而是继续走 input.lua:167-168 广播给游戏层。
--   这与 404 行 OnFocusMove 的处理不一致，⚠ 是一个真实的不对称：
--     · 方向键淡出时被冻结（OnFocusMove return true）
--     · 主键淡出时透传给游戏（OnControl return false）
--   实践后果：淡出时点左键可能触发一次攻击/交互。
    if self:IsControlsDisabled() then
        self.isprimary = false
        return false
-- ⚠ 429 行原注释 "--handle focus moves" 是**错位的旧注释**：
--   它的缩进（4 空格）暗示它属于 428 的 return 之后的分支，
--   但实际上它描述的是「本分支负责焦点移动」——而焦点移动
--   真正由 433-435 的 screen:OnControl 间接完成（由 Screen 遍历焦点链）。
--   ⇒ 注释与代码的对应关系有偏移，读代码时不要被它误导。
    --handle focus moves

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【CONTROL_PRIMARY → CONTROL_ACCEPT 映射】—— 必须讲清楚。
--
-- 431-432 原注释：
--   "-- map CONTROL_PRIMARY to CONTROL_ACCEPT for buttons"
--   "-- while editing a text box and hovering over something else, consume the"
--      "accept button (the raw key handlers will deal with it)."
--
-- 【为什么映射】
--   两个 CONTROL_* 在默认键位下是**同一个物理键**（鼠标左键 / 手柄 A）：
--     CONTROL_PRIMARY = 0 （constants.lua:109）—— 通用主键
--     CONTROL_ACCEPT = 29（constants.lua:147，注释 "-- A"）—— UI 确认键
--   UI 按钮只认 CONTROL_ACCEPT（widgets/button.lua:56-64），
--   而游戏层认 CONTROL_PRIMARY（playercontroller.lua:3135）。
--   ⇒ 所以**同一个物理输入要同时喂给两条路径，但用不同的语义码**：
--       给 UI → CONTROL_ACCEPT
--       给游戏 → CONTROL_PRIMARY
--   433/435 行的 `control == CONTROL_PRIMARY and CONTROL_ACCEPT or control`
--   就是这个「一次事件、两种语义」的转换器。
--
-- 【434 行的 textProcessorWidget 分支】
--   当文本框正在强制处理输入、且焦点已不在它上面时，
--   **先**让文本框自己处理一次（可能触发某些清理），
--   若它消费了就短路掉整个 433 分支。
--   原注释说明了原因：此时 accept 键应该被「文本框的清理逻辑」
--   而不是「UI 栈」消费；后续的键值由 OnRawKey 路径处理。
--
-- ⚠ 疑似缺陷（短路语义不一致）：
--   434 行文本框消费成功 → 整个 elseif 链**被短路**，
--   于是 452-488 的三个调试快捷键分支**不会被检查**。
--   推理依据：Lua 的 elseif 链在首个为真时短路；
--   文本框分支为真时不会 fallthrough到 452。
--   实际影响很小（CONTROL_OPEN_DEBUG_CONSOLE 与文本框分支互斥），
--   但这属于「条件顺序耦合」的脆弱写法。
-- ════════════════════════════════════════════════════════════════
    -- map CONTROL_PRIMARY to CONTROL_ACCEPT for buttons
    -- while editing a text box and hovering over something else, consume the accept button (the raw key handlers will deal with it).
-- ★ 条件换行写法：433 行末尾是 `elseif #self.screenstack > 0`
--   而 434 行才 `and not (...)`。Lua 允许条件跨行，
--   ★ 注意此处**不是**「433 单独构成条件」——
--     `and` 优先级高于 `elseif`，所以 434-435 是完整条件的一部分。
-- ⚠ 这种把 `and` 放到下一行缩进里的写法极易误读：
--   视觉上 434-435 像是独立语句。实际不是。
    elseif #self.screenstack > 0
        and not (self.textProcessorWidget ~= nil and not self.textProcessorWidget.focus and self.textProcessorWidget:OnControl(control == CONTROL_PRIMARY and CONTROL_ACCEPT or control, down))
-- ★★ 435 行：真正的 UI 消费点——把 control 交给栈顶屏幕。
--   screen:OnControl → widget.lua:124 → 逐层下钻有焦点的子节点。
--   ★ 注意这里**每次都做一遍映射**（同样的表达式在 434 也出现一次），
--     属于重复计算；因为映射是廉价的纯函数，无性能问题。
		and self.screenstack[#self.screenstack]:OnControl(control == CONTROL_PRIMARY and CONTROL_ACCEPT or control, down)
	then
-- ★ 437 行 isprimary = false —— UI 消费了，所以不再是「主键输入」。
--   配合 425 行，语义完整：isprimary 只在「本次输入会流向 UI 按钮」时为真。
		self.isprimary = false

-- ════════════════════════════════════════════════════════════════
-- ★★★★★ 【缺陷 G3 完整分析】#FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK
--
-- 【原注释逐字】
--   --@V2C: #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK (see playercontroller.lua)
--   --@V2C: #HACK fix auto repeat attack bug in playercontroller where clicking
--         down on UI elements still triggers attacks
--
-- 【症状】点击任何 UI 元素都会让角色朝那个方向攻击一次；
--         连续点击 UI 会持续攻击（auto-repeat）。
--
-- 【根因：三段链条，缺一不可】
--
--  【环节一：轮询式消费 vs 事件式仲裁】
--    playercontroller.lua:3133-3137 **每帧轮询**攻击键：
--      attack_control = ... (self:IsControlPressed(CONTROL_PRIMARY) and CONTROL_PRIMARY) ...
--    而 PlayerController:IsControlPressed（playercontroller.lua:511-517）
--    在 handler ~= nil（本地玩家）时直接调 TheInput:IsControlPressed，
--    走 input.lua:479-482 → TheSim:GetDigitalControl（**物理状态查询**），
--    ★ 完全不经过 input.lua:163-170 的事件仲裁。
--    ⇒ 按下鼠标左键那一帧：TheSim 说「左键已按下」→ 判定为攻击意图。
--    此时 UI 还没消费（甚至永远不会消费，因为仲裁只在事件层）。
--
--  【环节二：retarget 粘滞】
--    攻击发起后 playercontroller.lua:4603 / 4804 写入
--      self.inst.sg.statemem.retarget = <目标实体>
--    状态图据此在攻击动作结束前**记住目标并继续连击**。
--    ★ retarget 是「粘性状态」，它不会因为鼠标松开而自动清空——
--      这正是 auto-repeat 的燃料。
--
--  【环节三：UI 在抬起帧才真正消费】
--    widgets/button.lua:56-93：down 时只做音效 + 视觉位移 + ondown；
--    真正触发业务逻辑的 onclick 在 **up** 分支（button.lua:80-86）。
--    ⇒ 从「按下」到「UI 意识到这是自己的点击」之间隔着整个按住时长。
--
-- 【为什么必须打补丁而不能改设计】
--   playercontroller 的轮询式消费是**大量玩法语义的基础**：
--   「按住左键持续攻击」「按住右键持续交互」都依赖轮询。
--   改成事件驱动会牵动整个战斗/交互系统。
--   ⇒ 唯一低成本的修法：**在 UI 消费的那一刻，
--     反向撤销游戏层已经建立的中间状态。**
--
-- 【补丁本体 442-448 行做的事】
--   条件：ThePlayer 存在 且 有状态图 且 **retarget 已被设置**
--        且 玩家此刻**没有**按住 CONTROL_ATTACK / CONTROL_CONTROLLER_ATTACK
--   动作：player.sg.statemem.retarget = nil
--   ⇒ 判定逻辑很讲究：「UI 消费了主键，但玩家确实在按住真正的攻击键，
--     那就是玩家想边点UI边攻击」——此时不该清。
--
-- ★ 补丁的另一半在 playercontroller.lua:3132：
--   `--@V2C: #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK (see frontend.lua)`
--   那边加的是 `and (self.handler == nil or not IsPaused())`，
--   防止暂停期间误触发攻击。⇒ 同一个 bug 修了两处。
--
-- ⚠⚠ 这个补丁的**结构性代价**（bug-patterns.md G3 的正解在这里）：
--   正确做法是「一次性决定输入归谁」——在 input.lua:163 仲裁时
--   记下 mark_input_swallowed(control)，游戏层查询这个标记。
--   DST 没有这么做，于是：
--     · UI 侧要**反向写**游戏层的私有字段 sg.statemem.retarget；
--     · 前端（UI 层）因此**耦合到了状态图的内部实现**；
--     · 状态图若改字段名（statemem.retarget → statemem.target），
--       这个补丁会**静默失效**（赋值 nil 给不存在的字段不报错）。
--   ⚠ 实证：SGwilson.lua / SGwx78_possessedbody.lua 等多个状态图
--     都在写同一个 statemem.retarget（SGwilson.lua:10343/10568/10848/18108），
--     它们与这个补丁的清理逻辑之间**没有任何一致性保证**。
--   ⇒ 这是「事后打补丁」vs「前置仲裁」两种架构的教科书对照。
-- ════════════════════════════════════════════════════════════════
		--@V2C: #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK (see playercontroller.lua)
		--@V2C: #HACK fix auto repeat attack bug in playercontroller where clicking down on
		--      UI elements still triggers attacks
		local player = ThePlayer
-- ★ 三重守卫 `player and player.sg and player.sg.statemem`：
--   · player 非 nil —— 菜单界面里 ThePlayer 是 nil（主菜单没有角色）
--   · sg 非 nil —— 没有状态图的角色（部分 prefab / 观战模式）
--   · statemem 非 nil —— 状态图初始化后才有 statemem
--   ⚠ 但没有校验 statemem.retarget 是否**属于这个玩家当前的目标**——
--     若同一帧内玩家通过别的途径（技能、状态图脚本）设置了 retarget，
--     这个补丁会误清。举例：玩家点 UI 的同一帧，
--     SGwilson 的某个 onenter 正在设置 retarget（SGwilson.lua:10343），
--     两者执行顺序取决于事件派发次序，无保证。
		if player and player.sg and player.sg.statemem.retarget and
-- ★★ 444-445 是补丁里最精细的部分，也是最容易被误改的部分：
--   `not (IsControlPressed(CONTROL_ATTACK) or IsControlPressed(CONTROLLER_ATTACK))`
--   语义：「只有当玩家**没有**在按真正的攻击键时，才清retarget」。
--   ⇒ 这样「左手点UI + 右手按住攻击键」的合法操作不会被误伤。
--   CONTROL_CONTROLLER_ATTACK = 56（constants.lua:178，"-- X on xbox controller"）
--   是手柄的独立攻击键（摇杆点击之外的独立映射）。
-- ⚠ 但注意这里**没有**检查 CONTROL_PRIMARY 本身——
--   而 IsControlPressed 会走 ResolveVirtualControls（input.lua:480），
--   对 CONTROL_PRIMARY（非虚拟码）直接原样返回（input.lua:348）。
--   ⇒ 逻辑上没有绕过，但这个依赖是隐式的。
			not (TheInput:IsControlPressed(CONTROL_ATTACK) or
				TheInput:IsControlPressed(CONTROL_CONTROLLER_ATTACK))
		then
			player.sg.statemem.retarget = nil
		end
-- 一个孤立的 `--` 行：纯粹为了在视觉上标记补丁结束区。
-- ★ 这是「补丁区标记」的好习惯——后来者一眼能看出
--   哪几行是为了绕 bug 而存在的、不能在重构时丢掉。
		--
        return true

-- ════════════════════════════════════════════════════════════════
-- 段 7/8：调试快捷键（452-488）
-- ★ 四条分支全部 `not down`（只在抬起时触发）——
--   与 gameplay 快捷键「按下即触发」的风格相反。
--   ⇒ 推理：这些键（控制台/调试菜单/日志/渲染）风险高，
--     误触发代价大，所以要求「明确地按下去再松开」。
--────────────────────────────────────────────────────────────────
    elseif CONSOLE_ENABLED and not down and control == CONTROL_OPEN_DEBUG_CONSOLE then
        self.isprimary = false
        self:PushScreen(ConsoleScreen())
        return true

    elseif DEBUG_MENU_ENABLED and not down and control == CONTROL_OPEN_DEBUG_MENU then
        self.isprimary = false
        self:PushScreen(DebugMenuScreen())
        return true

    elseif SHOWLOG_ENABLED and not down and control == CONTROL_TOGGLE_LOG then
        self.isprimary = false
        if self.consoletext.shown then
            self:HideConsoleLog()
-- ★ 462-469 日志开关：同一分支里做 toggle。
--   464 行 `if self.consoletext.shown` 检查的是 **shown 字段**
--   （widget.lua:24 初始化为 true，但 62 行构造时调了 Hide()置 false），
--   ⇒ 于是初始状态是「日志关」。状态与 widget.lua:311-323 的
--     shown 语义一致。
        else
            self:ShowConsoleLog()
        end
        return true

-- ★★ 471-488 物理渲染切换。473-479 的原注释是又一处「考古笔记」：
--   "--V2C: Special logic when text edit has focus, and assuming
--      CONTROL_TOGGLE_DEBUGRENDER will always be BACKSPACE."
--   "--NOTE: Even though it looks like we're traversing the
--      screen hierarchy again, it's still better than
--      embedding the logic in Widget:OnControl, since
--      it only triggers here on a backspace keyup."
-- ★ 这段注释的信息量很大，说明三件事：
--   ① CONTROL_TOGGLE_DEBUGRENDER 默认被绑成退格键；
--   ② 作者知道「又遍历了一遍屏幕层级」不好，但判断不值得抽象——
--      因为**只在退格抬起这一条路径上触发**，抽象收益为负；
--   ③ 这是「局部重复优于过度抽象」的正确示范，与 D5 的
--      「结构性重复」形成对照（区别在于：触发条件唯一且罕见）。
    elseif DEBUGRENDER_ENABLED and not down and control == CONTROL_TOGGLE_DEBUGRENDER then
        self.isprimary = false
        --V2C: Special logic when text edit has focus, and assuming
        --     CONTROL_TOGGLE_DEBUGRENDER will always be BACKSPACE.

        --NOTE: Even though it looks like we're traversing the
        --      screen hierarchy again, it's still better than
        --      embedding the logic in Widget:OnControl, since
        --      it only triggers here on a backspace keyup.

-- ★ 481 行 `screenstack[#self.screenstack]:IsEditing()` ——
--   递归检查整棵控件树里有没有处于编辑态的文本框。
--   实现见 widget.lua:145-158（IsEditing 递归 children）。
--   ★ 这是「优先用工具函数而不是重复遍历」的例子：
--     同样的遍历逻辑已经被封装在 widget.lua，
--     前面 476-479 的注释所说的「又遍历一遍」指的是
--     「又自己实现一遍遍历」，而非「重复调用」。
        if #self.screenstack > 0 and self.screenstack[#self.screenstack]:IsEditing() then
            --Ignore since backspace is used by text edit
-- ⚠ 483 行 `elseif TheInput:IsKeyDown(KEY_CTRL)` ——
--   这里的按键状态查询**绕过了 input.lua 的语义层**，
--   直接读 TheSim:IsKeyDown（input.lua:297-299）。
--   ⇒ 与 G3 同源的架构问题：存在两条并行的输入读取路径
--     （事件 vs 状态查询），二者的仲裁无法统一。
        elseif TheInput:IsKeyDown(KEY_CTRL) then
            TheSim:SetDebugPhysicsRenderEnabled(not TheSim:GetDebugPhysicsRenderEnabled())
        else
            TheSim:SetDebugRenderEnabled(not TheSim:GetDebugRenderEnabled())
        end
        return true

-- ⚠ 490-493 是一段被注释掉的 elseif：
--     elseif control == CONTROL_CANCEL then
--         return screen:OnCancel(down)
-- ★ 这说明「ESC/CANCEL 关闭当前屏幕」曾是这个通用逻辑，
--   后来被下放给各个 Screen 自己处理（因为何时可关闭是业务决定）。
--   ⇒ 保留了注释作为历史记录——比直接删掉更好。
-- ★ 注意它引用了 `screen` 这个**未定义的局部变量**（本函数里没有 local screen），
--   所以即使取消注释也不会工作（会取到全局 screen = nil）。
--   ⇒ 双重失效，说明这段代码早就是纯历史文本了。
--[[
    elseif control == CONTROL_CANCEL then
        return screen:OnCancel(down)
--]]
    end
-- ★ 495 行：兜底清零 isprimary 并隐式返回 nil。
--   ⇒ 「UI 没吃掉」= 返回 nil（falsy）→ input.lua:166 的
--     `not TheFrontEnd:OnControl(...)` 为真 → 广播给游戏层。
--   这就是完整的仲裁闭环。
    self.isprimary = false
end
-- 第二个 ValidateLineNumber——框住 OnControl 函数的结束（497 行 = `end`）。
ValidateLineNumber(497)

-- ════════════════════════════════════════════════════════════════
-- 段 8/8：标题淡入淡出（499-551）
-- ════════════════════════════════════════════════════════════════
function FrontEnd:ShowTitle(text,subtext)
	self.title:SetString(text)
	self.title:Show()
	self.subtitle:SetString(subtext)
	self.subtitle:Show()
	self:StartTileFadeIn()
end

-- ★ fade_time = 2 —— 标题淡入淡出的**总时长**（秒）。
-- ★ 用 local 而非 self.fade_time 是刻意的：self.fade_time 是
--   **全屏淡入淡出**（Fade）的计时器（1036行），两者不同源。
--   ⇒ 用局部常量避免与 652DoFadingUpdate 的同名状态混淆。
--   ⚠ 仍是同类问题：两个模块都在做淡入淡出，却各有一套状态字段
--     （fade_title_* vs fadedir/fade_time/fade_type）。
local fade_time = 2

-- ★★ DoTitleFade(dt) —— 标题动画的逐帧推进。
-- 511 行 `dt = math.min(dt, 1/30)`：**钳制步长**。
--   ⇒ 防止卡顿（dt 很大）时一帧把动画跳完，导致动画「闪过去」。
--   ⚠ 但这样做的副作用是：卡顿时标题动画会**变慢**而不是跳帧。
--     对 2 秒的淡入淡出来说这是可接受的取舍（平滑 > 准确）。
-- ★ 对比 653 行 `dt = math.min(dt, FRAMES)`：全屏淡出用的是
--   FRAMES（每帧时长），钳制上限更大。⇒ 两种淡出用不同钳制策略。
function FrontEnd:DoTitleFade(dt)
	if self.fade_title_in == true or self.fade_title_out == true then
		dt = math.min(dt, 1/30)
		if self.fade_title_in == true and self.fade_title_time <fade_time then
			self.fade_title_time = self.fade_title_time + dt
		elseif self.fade_title_out == true and self.fade_title_time >0 then
			self.fade_title_time = self.fade_title_time - dt
		end

-- ★★ easing.inOutCubic(t, from, delta, duration) —— 缓动签名。
--   t 当前时间、from 起点值、delta 变化量、duration 总时长。
--   0→2 秒之间 alpha 从 0 走到 1（delta=1）。
-- ★★ 注意 518 行是在**两个分支之外**统一执行的：
--   无论 fade_title_in 还是 fade_title_out，都会重算 alpha。
--   ⇒ 只有 fade_title_time 在两个分支里被修改（513 递增 / 515 递减），
--     视觉由同一个 easing 反函数处理。
--   ⚠ 但 512 行的条件是 `fade_title_in == true and time < fade_time`，
--     514 行是 `fade_title_out == true and time > 0`。
--     若两个标志都为 false（HideTitle 后541-546 的状态），
--     fade_title_time 停在 0 → alpha = 0 → 标题透明。
--     而 541 行 HideTitle 同时调了 title:Hide()，双保险。
		self.fade_title_alpha = easing.inOutCubic(self.fade_title_time, 0, 1, fade_time)

		self.title:SetAlpha(self.fade_title_alpha)
		self.subtitle:SetAlpha(self.fade_title_alpha)

-- 淡入完成 → 启动全屏 tile 淡出（StartTileFadeOut）。
-- ★ 「标题先淡入，标题稳了才把画面淡掉」——这是一个两段式转场。
		if self.fade_title_in == true and self.fade_title_time >=fade_time then
			self:StartTileFadeOut()
		end
	end
end

function FrontEnd:StartTileFadeIn()
	self.fade_title_in = true
	self.fade_title_time = 0
	self.fade_title_out = false
	self:DoTitleFade(0)
end

function FrontEnd:StartTileFadeOut()
	self.fade_title_in = false
	self.fade_title_out = true
end

-- ★★ HideTitle 同时做三件事：Hide 控件 + 清两个动画标志 + 清计时器。
--   缺任何一个都会留下「淡出还在跑但控件已隐藏」的中间态。
--   ⇒ 这是应对 G4「OnBecomeActive/Inactive 不成对」的正确姿势：
--     把状态收敛集中在一个显式的重置函数里。
function FrontEnd:HideTitle()
	self.title:Hide()
	self.subtitle:Hide()
	self.fade_title_in = false
	self.fade_title_time = 0
	self.fade_title_out = false
end

-- ★★ LockFocus(lock) —— 焦点总闸。
--   唯一读者是 404 行 OnFocusMove 与 926 行 DoHoverFocusUpdate。
--   ★ 注意它**不影响** OnControl/OnMouseButton——
--     锁焦点时控件仍可被鼠标点击，只是**不能导航**。
--   ⇒ 语义是「禁止键盘/手柄改焦点」，不是「禁止一切输入」。
--   名字LockFocus 容易被误读为后者。
function FrontEnd:LockFocus(lock)
	self.focus_locked = lock
end

-- SendScreenEvent —— 向栈顶屏幕转发一个自定义事件。
-- ★ 与 widget.lua:401 HookCallback 的区别：
--   HookCallback 挂在**实体事件总线**上（inst:ListenForEvent，
--     绑的是玩法实体推的事件）；
--   SendScreenEvent 是**手动转发**给屏幕的 HandleEvent（screen.lua:61）。
--   ⇒ 前者被动（等事件），后者主动（代码显式调用）。
function FrontEnd:SendScreenEvent(type, message)
	if #self.screenstack > 0 then
		self.screenstack[#self.screenstack]:HandleEvent(type, message)
	end
end

function FrontEnd:GetSound()
	return self.gameinterface.SoundEmitter
end

function FrontEnd:GetGraphicsOptions()
	return self.gameinterface.GraphicsOptions
end

function FrontEnd:GetTwitchOptions()
	return self.gameinterface.TwitchOptions
end

function FrontEnd:GetAccountManager()
	return self.gameinterface.AccountManager
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【SetFadeLevel】—— 淡出强度的唯一写入点。
--
-- 【四种 fade_type 的语义（fade_type 由 1037 行 Fade 设置）】
--   "alpha"  —— **特殊**：不用遮罩，而是逐个设置屏幕子控件的 alpha。
--   "white"  —— 白遮罩 + 暗角（过场、亮光）
--   "black"  —— 黑遮罩（最常用：进游戏、退出）
--   "swipe"  —— 噪声擦除着色器（进服务器）
--
-- ★★ 577 行 DoAutopause() —— 每次改淡出强度都重新评估自动暂停。
--   这是文件头「三循环暂停语义」的具体落点：
--   SetFadeLevel(0.5) → IsControlsDisabled() 为真 → 自动暂停关闭。
--   ⇒ 淡出期间世界**继续运行**，只有淡入/淡出都结束才恢复暂停。
--   ⚠ 这与直觉相反（通常转场时希望世界静止），
--     推理依据是 mainfunctions.lua:921 的 `and not IsControlsDisabled()`：
--     它在控件禁用时**关闭**自动暂停。所以淡出期间 = 不自动暂停。
--────────────────────────────────────────────────────────────────
function FrontEnd:SetFadeLevel(alpha, time, time_total)
    self.alpha = alpha
    DoAutopause()
-- ★★ alpha <= 0 分支：淡出结束，隐藏所有遮罩。
--   578-590 逐一 Hide 四个 bottom + 四个 top 遮罩。
--   ★ 579 行 `if self.blackoverlay ~= nil` 的判空是因为
--     console / 专用服务器上部分遮罩不会被创建（197-208 同理）。
    if alpha <= 0 then
        if self.blackoverlay ~= nil then
            self.blackoverlay:Hide()
            self.whiteoverlay:Hide()
            self.vigoverlay:Hide()
            self.swipeoverlay:Hide()
        end
        if self.topblackoverlay ~= nil then
            self.topblackoverlay:Hide()
            self.topwhiteoverlay:Hide()
            self.topvigoverlay:Hide()
            self.topswipeoverlay:Hide()
        end
-- ★★★ "alpha" 模式的收尾：把屏幕子控件的 alpha **强制恢复为 1**。
-- 591-598：`if self.fade_type == "alpha" then ... v:SetFadeAlpha(1) end`
-- ★★ 官方在 1029-1031 的原注释正是警告这件事：
--   "-- **CAUTION** about using the "alpha" fade: it leaves your screen's
--      widgets at alpha 0 when it's finished AND makes all children
--      of the screen not clickable"
--   "-- It generally leaves the screen in bad state: don't use lightly
--      for screens that will be returned to (ex: we only use it leading
--      into a sim reset)"
--
-- ⇒ 两条已知副作用：
--   ① 控件停在 alpha=0 —— 591-598 的补救是**只恢复直接子控件**，
--      孙控件的 alpha 依赖 widget.lua:506-514 SetFadeAlpha 的递归；
--      若某控件 can_fade_alpha=false（widget.lua:28可配），它不会被恢复。
--   ② 控件变得**不可点击** —— 因为 alpha=0 的控件在引擎层
--      被视作不可见而跳过命中测试。这解释了为什么官方说
--      「不要对会被返回的屏幕用 alpha 淡出」。
--   ★ 使用场景被限定为「进入 sim 重置」——即整个世界重建，
--     屏幕状态不复用，所以副作用无害。
        if self.fade_type == "alpha" then
            local screen = self:GetActiveScreen()
            if screen and screen.children then
                for k,v in pairs(screen.children) do
                    v:SetFadeAlpha(1)
                end
            end
        end
-- ★ white 分支：白遮罩 + 暗角，四个控件同show。
-- ★ 604-607 的 `if not self.topFadeHidden then` 只包住 Show，
--   而 608-609 的 SetTint 在 if 外——
--   ⇒ 即使 topFadeHidden 为 true，top 遮罩的 tint 也被更新（只是不显示）。
--   这是无害的不对称，但说明 HideTopFade（277）只是「视觉隐藏」，
--   状态仍被维护。
    elseif self.fade_type == "white" then
        self.whiteoverlay:Show()
        self.whiteoverlay:SetTint(FADE_WHITE_COLOUR[1], FADE_WHITE_COLOUR[2], FADE_WHITE_COLOUR[3], alpha)
        self.vigoverlay:Show()
        self.vigoverlay:SetTint(1, 1, 1, alpha)
        if not self.topFadeHidden then
            self.topwhiteoverlay:Show()
            self.topvigoverlay:Show()
        end
        self.topwhiteoverlay:SetTint(FADE_WHITE_COLOUR[1], FADE_WHITE_COLOUR[2], FADE_WHITE_COLOUR[3], alpha)
        self.topvigoverlay:SetTint(1, 1, 1, alpha)
-- ★★★ alpha 模式的核心：610-616 逐个设置屏幕子控件的 alpha。
-- 614 行原注释解释了一个容易搞反的方向：
--   `-- "alpha" here is the intensity of the fade, 1 is full intensity, so 0 widget alpha`
--   ⇒ fade 的 alpha 是「遮蔽强度」，控件 alpha 是「不透明度」，二者反向。
-- ★ 与 591-598 对称：淡出时设 (1 - alpha)，结束时设 1。
-- ⚠ 612 行有 `screen ~= nil and screen.children ~= nil` 双判空，
--   而 593 行只有 `screen and screen.children`（children 在 Widget 构造时
--   必定存在，widget.lua:3）——593 的判空其实够用，612 更保守。
    elseif self.fade_type == "alpha" then
        local screen = self:GetActiveScreen()
        if screen ~= nil and screen.children ~= nil then
            for k, v in pairs(screen.children) do
                v:SetFadeAlpha(1 - alpha) -- "alpha" here is the intensity of the fade, 1 is full intensity, so 0 widget alpha
            end
        end
    elseif self.fade_type == "black" then
        self.blackoverlay:Show()
        self.blackoverlay:SetTint(0, 0, 0, alpha)
        if not self.topFadeHidden then
            self.topblackoverlay:Show()
        end
        self.topblackoverlay:SetTint(0, 0, 0, alpha)
-- ★ swipe 分支：632-644 是本函数最复杂的部分。
-- 632 行原注释："--progress should be a float from 0 to 1 over the whole
-- fade in and out"
-- 634 行 fade_progress = time and (time/time_total) or 0 ——
--   当前过渡进度（0→1）。★ `time and ... or 0`：
--     time 为 nil 时取 0；time 为 0 时 `0/0` = nil → 走 or 0 → 0。
--     这个写法**恰好**处理了 total_fade_time=0 的除零情况。
--     ⚠ 但它脆弱：如果 time/time_total 算出 0（合法的开始时刻），
--       `0 and x or 0` 会返回 0（正确）；如果算出非 0 才返回它。
--       实际正确，但可读性差。
-- ★ 635-641 把「淡出」映射到 progress 的前半段、
--   「淡入」映射到后半段 + phase_1 反转方向：
--     FADE_IN  → progress = 0.5 + p/2，phase_1 = 1
--     FADE_OUT → progress = p/2，      phase_1 = 0
--   ⇒ 淡出从噪声中心向外擦除，淡入反向擦回。
--   ★★ phase_1（0/1）是着色器的「方向开关」而非进度的一部分——
--     这就是为什么 top 层与 bottom 层初始 progress 不同（99 vs 111）。
    elseif self.fade_type == "swipe" then
        self.swipeoverlay:Show()
        self.swipeoverlay:SetTint(1, 1, 1, alpha)
        if not self.topFadeHidden then
            self.topswipeoverlay:Show()
        end
        self.topswipeoverlay:SetTint(1, 1, 1, alpha)

        local progress = 0 --progress should be a float from 0 to 1 over the whole fade in and out
        local phase_1 = 0
        local fade_progress = time and (time/time_total) or 0
        if self.fadedir == FADE_IN then
			progress = 0.5 + (fade_progress/2)
			phase_1 = 1
        else--if self.fadedir == FADE_OUT then
			progress = fade_progress/2
			phase_1 = 0
        end

        self.swipeoverlay:SetEffectParams(progress, phase_1, 0, 0)
        self.topswipeoverlay:SetEffectParams(progress, phase_1, 0, 0)
    end
end

-- GetFadeLevel —— alpha 的唯一读取封装。
-- ★ 三个读者：397 IsControlsDisabled、896 提示条显隐、
--   widgets/button.lua:108 OnGainFocus 里的音效抑制。
--   ⇒ 「淡出中不要播 hover 音效」——一个小但体贴的细节。
function FrontEnd:GetFadeLevel()
    return self.alpha
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【DoFadingUpdate】—— 全屏淡入淡出的状态机。
--
-- 【三个状态，由两个字段决定】
--   ① 空闲：fadedir == nil（Fade 没被调用或已完成 684 行）
--   ② 延迟中：fade_delay_time ~= nil（654-663）
--   ③ 过渡中：fadedir ~= nil（664-691）
--
-- ★★ 延迟机制（654-663）是为「连着做两个淡出」准备的：
--   FadeToScreen（1059）传 fade_delay_time=0，
--   表示「上一段淡出结束后立即开始下一段」。
--   delayovercb 是延迟结束时的回调，660 行执行后立刻置 nil（防重入）。
--────────────────────────────────────────────────────────────────
function FrontEnd:DoFadingUpdate(dt)
-- ★ dt = math.min(dt, FRAMES) —— 钳制到一帧时长。
--   比 511 行的 1/30 更宽松（FRAMES 通常是 1/30~1/60）。
--   ⇒ 目的相同（防卡顿跳帧），但全屏淡出对时间准确度要求更高，
--     所以钳制上限更大。
        dt = math.min(dt, FRAMES)
        if self.fade_delay_time ~= nil then
                self.fade_delay_time = self.fade_delay_time - dt
                if self.fade_delay_time <= 0 then
                        self.fade_delay_time = nil
                        if self.delayovercb ~= nil then
                                self.delayovercb()
                                self.delayovercb = nil
                        end
                end
                return
        elseif self.fadedir ~= nil then
-- ★ fade_time 累加 —— 与 1036 行 Fade 的初始化 `self.fade_time = 0` 配对。
--   三个字段（fadedir / total_fade_time / fade_time）构成完整计时状态。
                self.fade_time = self.fade_time + dt

                local alpha = 0
-- ★★ FADE_IN 的 alpha 曲线：easing.inOutCubic(t, 1, -1, total)。
--   from=1, delta=-1 ⇒ alpha 从 1 降到 0。
--   ★ 669-670 的 `total_fade_time == 0` 特判：总时长为0 时
--     alpha 直接取 0（跳过中间态）。
--   ⚠ 推理依据：inOutCubic(t, 1, -1, 0) 会除以 duration=0 → 除零错误。
--     所以必须特判。FADE_OUT 分支（675-676）同理取 1。
--   ⇒ 但 1039 行 Fade 在 FADE_IN 时会先 SetFadeLevel(1)，
--     682 行再 SetFadeLevel(alpha=0)——即**瞬间跳到透明**。
--     total=0 的 Fade 实际就是「瞬切」。
                if self.fadedir == FADE_IN then
                        if self.total_fade_time == 0 then
                                alpha = 0
                        else
                                alpha = easing.inOutCubic(self.fade_time, 1, -1, self.total_fade_time)
                        end
                elseif self.fadedir == FADE_OUT then
                        if self.total_fade_time == 0 then
                                alpha = 1
                        else
                                alpha = easing.outCubic(self.fade_time, 0, 1, self.total_fade_time)
                        end
                end

                self:SetFadeLevel(alpha, self.fade_time, self.total_fade_time)
-- ★★★ 过渡结束处理：683-690。
-- 684 行 fadedir = nil → 回到「空闲」状态。
-- 685-689 fadecb 的执行顺序值得注意：
--   `local cb = self.fadecb` 先取出，686 行立刻置 nil，687 行才调。
--   ★ 防重入：如果 cb 内部又调了 Fade（FadeToScreen 1065 正是如此），
--     新设的 fadecb 不会被这一行清掉。
--   ⇒ 「先清后调」是事件回调的标准防重入姿势，
--     与 660 行 delayovercb 的处理同构。
                if self.fade_time >= self.total_fade_time then
                        self.fadedir = nil
                        if self.fadecb ~= nil then
                                local cb = self.fadecb
                                self.fadecb = nil
                                cb()
                        end
                end
        end
end

-- UpdateConsoleOutput —— 把 C++ 控制台缓冲区搬进文本控件。
-- ★⚠ 性能问题（每帧执行，752-754 行无条件调用）：
--   `table.concat(GetConsoleOutputList(), "\n")` 每帧重建整个字符串，
--   且 SetString 触发文本重排版。
--   ⇒ 输出日志时会有可观察的帧率抖动。
--   根因：752 行 `if self.consoletext.shown then` —— 日志开着就一直跑。
--   ★ 这属于「轮询式 UI 更新」的典型代价；
--     正确做法应是 C++ 侧推事件（与 730 行 serverpausewidget:UpdateText
--     相反，后者是**推**模式）。
function FrontEnd:UpdateConsoleOutput()
    local consolestr = table.concat(GetConsoleOutputList(), "\n")
    consolestr = consolestr.."\n(Press CTRL+L to close this log)"
   	self.consoletext:SetString(consolestr)
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【_RefreshRepeatDelay】—— 三档连发速度的选择。
--
-- ★ 三档（701-707）：
--   repeat_reps <= 1        → crafting_repeat_base（刚按下，最慢）
--   repeat_reps >= 3 且摇杆接近满舵 → crafting_repeat_ninja（最快，×0.2）
--   否则                → crafting_repeat_fast（中等，×0.4）
--
-- ★★ 703 行 `Input:GetAnalogControlValue(control) > 0.95` ——
--   为什么用**摇杆模拟量**作为「加速条件」？
--   → 手柄玩家把摇杆推到底（>0.95）= 明确意图 = 给最快的重复率。
--     轻推摇杆 = 慢速微调。这是为手柄玩家设计的「推到底才加速」手感。
-- ⚠ 键盘玩家永远拿不到 >0.95 的模拟量，
--   所以他们只能拿到 fast 档（除非按住方向键很久让 reps 涨到3，
--     但那时模拟量仍是 0 → 走 else 分支 → fast）。
--   ⇒ ★ 两类玩家体验不同，这是**无意**还是有意无法确定。
--────────────────────────────────────────────────────────────────
function FrontEnd:_RefreshRepeatDelay(control)
	if self.repeat_reps <= 1 then
		self.repeat_time = self.crafting_repeat_base
	elseif self.repeat_reps >= 3 and Input:GetAnalogControlValue(control) > 0.95 then
		self.repeat_time = self.crafting_repeat_ninja
	else
		self.repeat_time = self.crafting_repeat_fast
	end
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【FrontEnd:Update(dt)】—— 前端主循环（710-912）。
--
-- 【执行顺序（严格按代码顺序，设计上很重要）】
--   711-717 调试器/作弊探针（仅开发版）
--   719      读手柄连接状态（后面多处要用）
--   721-750 存档指示器动画与淡出
--   752-754  控制台日志刷新（⚠ 每帧重建字符串）
--   756      全屏淡出状态机
--   757      标题淡出
--   759-761  ★ 只有栈顶屏幕收 OnUpdate
--   763-874  输入连发逻辑（spinner / scroll / 菜单导航）
--   876      imgui 渲染
--   878-892  ★ 弱引用表驱动的控件更新
--   894-909  手柄提示条
--
-- ★★ 759-761 是 UI 栈的核心语义：**只有栈顶更新**。
--   被压在下面的屏幕（如暂停屏下的弹窗）**不会**收到 dt，
--   ⇒ 它的动画会停在原地。这也是缺陷 G4 的一种表现：
--     被遮挡的屏幕处于「半冻结」状态。
--────────────────────────────────────────────────────────────────
function FrontEnd:Update(dt)
    if DEBUGGER_ENABLED then
        Debuggee.poll()
    end

    if CHEATS_ENABLED then
        ProbeReload(TheInput:IsKeyDown(KEY_F6))
    end

-- ★ local controller = TheInput:ControllerAttached() —— 全函数只用一次
--   （817-820/838-850 的 `not controller` 判断）。
--   ★ 这些判断的含义：**手柄玩家与键鼠玩家走不同的导航键集合**。
--     键鼠用 CONTROL_FOCUS_*，手柄用 VIRTUAL_CONTROL_INV_*。
--     ⇒ 这是「同一逻辑、不同物理来源」的第二处映射。
	local controller = TheInput:ControllerAttached()

-- ★ `saving_indicator ~= nil and saving_indicator.shown` ——
--   PC 上第一个条件永远为 false（主机专属）。
--   721-750 整段在 PC 上是空操作。
	if self.saving_indicator ~= nil and self.saving_indicator.shown then
-- ★ 淡出状态机（722-742）。三个子状态：
--   save_indicator_fade == "in"  → 正在淡入（alpha 由剩余时间反算）
--   save_indicator_fade == "out" → 正在淡出
--   save_indicator_fade == nil    → 已完全显示，开始计时（744-748）
-- ★ 737 行 `1 - fade_time_left/save_fade_time` 是标准线性淡入。
-- ★ 739 行 `math.min(1, fade_time_left/save_fade_time)` 是淡出。
--   ⚠ 注意 737/739 都在 else 分支里（735-740），
--     而 726-734 的 if 分支处理「fade_time < 0 即动画结束」。
--     ⇒ 结束判定优先于速率计算，顺序正确。
		if self.save_indicator_fade then
			local alpha = 1
			self.save_indicator_fade_time = self.save_indicator_fade_time - math.min(dt, 1/60)

			if self.save_indicator_fade_time < 0 then
				if self.save_indicator_fade == "in" then
					alpha = 1
				else
					alpha = 0
-- ★ 淡出完成 → ForceStopWallUpdating + Hide。
--   ForceStopWallUpdating（widget.lua:222）在主机上会短路
--   （IsConsole() 检查），因为主机上本来就是逐帧更新。
					self.saving_indicator:ForceStopWallUpdating()
					self.saving_indicator:Hide()
				end
				self.save_indicator_fade = nil
			else
				if self.save_indicator_fade == "in" then
					alpha = math.max(0, 1 - self.save_indicator_fade_time/save_fade_time)
				elseif self.save_indicator_fade == "out" then
					alpha = math.min(1,self.save_indicator_fade_time/save_fade_time)
				end
			end
			self.saving_indicator:GetAnimState():SetMultColour(1,1,1,alpha)
		else
-- ★★ 「开始计时淡出」的双条件：745 行
--   `if self.num_pending_saves <= 0 and self.save_indicator_time_left <= 0`。
--   ⇒ **必须所有存档都完成** 且 **至少显示过3 秒**（259 行赋值）。
--   这就是 271-275 只减计数不隐藏的兑现处。
			self.save_indicator_time_left = self.save_indicator_time_left - dt
			if self.num_pending_saves <= 0 and self.save_indicator_time_left <= 0 then
				self.save_indicator_fade = "out"
				self.save_indicator_fade_time = save_fade_time
			end
		end
	end

	if self.consoletext.shown then
		self:UpdateConsoleOutput()
	end

	self:DoFadingUpdate(dt)
	self:DoTitleFade(dt)

	if #self.screenstack > 0 then
		self.screenstack[#self.screenstack]:OnUpdate(dt)
	end

-- ★★ `if not self:IsControlsDisabled() then` —— 整个连发逻辑的门禁。
--   ⇒ 淡出中不产生连发。与 404OnFocusMove 的门禁呼应。
    if not self:IsControlsDisabled() then

-- ════════════════════════════════════════════════════════════════
-- ★★ 【三套连发机制】765-871 行。它们结构完全同构，但语义不同：
--
--  【Spinner 连发】765-779 —— 数字微调器
--    769-772 的三段式：`> dt` 冷却中 → `< 0` 未起跳 → 中间触发
--    772 行 `SPINNER_REPEAT_TIME > dt and SPINNER_REPEAT_TIME - dt or 0`
--      = 若重复间隔大于本帧时长，则「减去本帧」作为下次冷却起点，
--        否则直接置 0。★ 这是为了保证「每帧最多触发一次」
--        同时不丢失已过的时间。
--    773-778 直接调self:OnControl(CONTROL_PREVVALUE, true)——
--      ★ 手动合成一个「按下」事件，而不是等真实输入。
--
--  【Scroll 连发】781-809 —— 滚动
--    ★★ 787-792 与 798-804 有一个特殊处理：
--      `TheInput:GetControlIsMouseWheel(CONTROL_SCROLLBACK)`（789）
--      决定用 MOUSE_SCROLL_REPEAT_TIME(0) 还是 SCROLL_REPEAT_TIME(.05)。
--      GetControlIsMouseWheel（input.lua:712-719）通过**比较本地化字符串**
--      来判断（localized == stringtable[1003]）——
--      ⚠ 这是极其脆弱的判定：改了按键语言包就会失效。
--      见 input.lua:718 的缺陷标注。
--    793/804 的 or 0 分支：重复间隔为 0 时，「下帧立即再触发」。
--      ⇒ 滚轮连发靠硬件事件频率，软件层不节流。
--
--  【菜单导航连发】811-871 —— 方向键移动焦点
--    ★ 835 行 `elseif not (self.textProcessorWidget ~= nil) then`：
--      文本框在处理输入时**完全不导航**。
--    816-834 是「正在冷却时检查是否松开了导航键」：
--      松开 → repeat_time=0 且 repeat_reps=0（复位）。
--    838-870 是「该触发了」：
--      · crafting_navigation_mode（838）走 VIRTUAL_CONTROL_INV_*
--        （物品栏导航），并调 _RefreshRepeatDelay 选三档速度；
--      · 否则（855-870）走 CONTROL_MOVE_* / CONTROL_FOCUS_*，
--        ★ 不调 _RefreshRepeatDelay ⇒ 恒定 REPEAT_TIME(.15)。
--        856 行 self.repeat_time = REPEAT_TIME 在这一分支里被重置。
--────────────────────────────────────────────────────────────────
        --Spinner repeat
        if not (TheInput:IsControlPressed(CONTROL_PREVVALUE) or
                TheInput:IsControlPressed(CONTROL_NEXTVALUE)) then
            self.spinner_repeat_time = -1
        elseif self.spinner_repeat_time > dt then
            self.spinner_repeat_time = self.spinner_repeat_time - dt
        elseif self.spinner_repeat_time < 0 then
-- ★★ 「首次按下立刻触发」的实现：
--   spinner_repeat_time 初值 -1 → `< 0` 分支把它设成 (0.25 - dt)。
--   ★ 所以首次触发发生在**下一次**Update，而不是本次。
--     （本次Update 在 771 走的是 `< 0` 分支，不是触发分支 773。）
--   ⇒ 按下与首次生效之间有 1 帧延迟。这是所有连发机制的共性代价。
--────────────────────────────────────────────────────────────────
            self.spinner_repeat_time = SPINNER_REPEAT_TIME > dt and SPINNER_REPEAT_TIME - dt or 0
        elseif TheInput:IsControlPressed(CONTROL_PREVVALUE) then
            self.spinner_repeat_time = SPINNER_REPEAT_TIME
            self:OnControl(CONTROL_PREVVALUE, true)
        else--if TheInput:IsControlPressed(CONTROL_NEXTVALUE) then
            self.spinner_repeat_time = SPINNER_REPEAT_TIME
            self:OnControl(CONTROL_NEXTVALUE, true)
        end

        --Scroll repeat
        if not (TheInput:IsControlPressed(CONTROL_SCROLLBACK) or
                TheInput:IsControlPressed(CONTROL_SCROLLFWD)) then
            self.scroll_repeat_time = -1
        elseif self.scroll_repeat_time > dt then
            self.scroll_repeat_time = self.scroll_repeat_time - dt
-- ★★ 788-791 行：滚轮 vs 肩键的不同节流。
--   ⚠ 推理依据：MOUSE_SCROLL_REPEAT_TIME = 0 意味着 793 行
--     `repeat_time > dt` 为假 → 直接走 else 分支（795-796）→ 立即触发。
--     于是每次滚轮事件都会触发一次，无节流。
--   ★ 这依赖滚轮硬件自带连发。若玩家把滚轮映射到某个
--     「可连发」的输入源上，会变成疯狂滚动。
        elseif TheInput:IsControlPressed(CONTROL_SCROLLBACK) then
            local repeat_time =
                TheInput:GetControlIsMouseWheel(CONTROL_SCROLLBACK) and
                MOUSE_SCROLL_REPEAT_TIME or
                SCROLL_REPEAT_TIME
            if self.scroll_repeat_time < 0 then
                self.scroll_repeat_time = repeat_time > dt and repeat_time - dt or 0
            else
                self.scroll_repeat_time = repeat_time
                self:OnControl(CONTROL_SCROLLBACK, true)
            end
        else--if TheInput:IsControlPressed(CONTROL_SCROLLFWD) then
            local repeat_time =
                TheInput:GetControlIsMouseWheel(CONTROL_SCROLLFWD) and
                MOUSE_SCROLL_REPEAT_TIME or
                SCROLL_REPEAT_TIME
            if self.scroll_repeat_time < 0 then
                self.scroll_repeat_time = repeat_time > dt and repeat_time - dt or 0
            else
                self.scroll_repeat_time = repeat_time
                self:OnControl(CONTROL_SCROLLFWD, true)
            end
        end

-- ★ 原注释 "--Menu nav repeat" + "--skip while editing a text box"
--   两行注释精确概括了 811-871 的两件事：
--   ① 这是菜单导航的连发；
--   ② 文本框编辑时跳过（835 行的条件）。
        --Menu nav repeat
        --skip while editing a text box
        if self.repeat_time > dt then
            self.repeat_time = self.repeat_time - dt

-- ★ crafting_navigation_mode —— 「物品栏导航模式」开关。
--   ★ 由外部（inventorybar 之类）设置。开启后：
--     · 方向键变成「在物品栏格子间移动光标」而非「在菜单间移动焦点」
--     · 启用 _RefreshRepeatDelay 的三档加速（838-850）
--     · 897 行还禁止了手柄提示条的显示
--   ⇒ 这是一个**UI 模式开关**，与手柄/键鼠无关。
			if self.crafting_navigation_mode then
-- ★★ 817-820 行的 `not controller and TheInput:IsControlPressed(CONTROL_FOCUS_*)`
--   是全文件最绕的一处：
--   `not controller and X` ≡ `not (controller and X)`
--   语义：「手柄玩家用 VIRTUAL_CONTROL_INV_*，键鼠玩家额外能用 CONTROL_FOCUS_*」。
--   ⚠ 可读性极差——运算符优先级（and 紧于 or）是对的，
--     但连续 8 个 or 串起来极易漏看括号。
--   ★ 这也是「UI 层做输入源仲裁」的典型代价：
--     判定被摊进每个消费点，而不是集中在一处。
				if not (   TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_LEFT) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_LEFT))
						or TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_RIGHT) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_RIGHT))
						or TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_UP) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_UP))
						or TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_DOWN) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_DOWN)) ) then

            		self.repeat_time = 0
					self.repeat_reps = 0
				end
			else
				if not (   TheInput:IsControlPressed(CONTROL_MOVE_LEFT) or TheInput:IsControlPressed(CONTROL_FOCUS_LEFT)
            			or TheInput:IsControlPressed(CONTROL_MOVE_RIGHT) or TheInput:IsControlPressed(CONTROL_FOCUS_RIGHT)
            			or TheInput:IsControlPressed(CONTROL_MOVE_UP) or TheInput:IsControlPressed(CONTROL_FOCUS_UP)
            			or TheInput:IsControlPressed(CONTROL_MOVE_DOWN) or TheInput:IsControlPressed(CONTROL_FOCUS_DOWN) ) then

            		self.repeat_time = 0
					self.repeat_reps = 0
				end
			end
-- ★★ `elseif not (self.textProcessorWidget ~= nil) then` ——
--   等价于 `elseif self.textProcessorWidget == nil then`，
--   但写成了双重否定。⚠ 这行同时也是 813 的 else：
--     · 813 if（冷却中）→ 814-834 递减计时 / 检查松开
--     · 835 elseif（**不在冷却中**且**无文本框**）→ 838-870 触发导航
--   ★ 缺一个分支：**不在冷却中** 但 **有文本框** → 什么都不做。
--     这是正确的（文本框独占输入），但隐式依赖 813 的条件为假。
		elseif not (self.textProcessorWidget ~= nil) then
-- ★★ `self.repeat_reps and (self.repeat_reps + 1) or 1` ——
--   连发次数自增。初值 227 行是 0，所以第一次走 or 分支取 1。
--   ★ repeat_reps 的消费者是 701-703 的三档选择。
--   ⚠ 这个「用 and/or 做可选自增」的写法是为了兼容 nil 初值，
--     但 227 行已明确初始化为 0 ⇒ 这里的 nil 保护是多余的。
--     历史遗留。
            self.repeat_reps = self.repeat_reps and (self.repeat_reps + 1) or 1

			if self.crafting_navigation_mode then
				if TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_LEFT) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_LEFT)) then
					self:_RefreshRepeatDelay(VIRTUAL_CONTROL_INV_LEFT)
					self:OnFocusMove(MOVE_LEFT, true)
				elseif TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_RIGHT) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_RIGHT)) then
					self:_RefreshRepeatDelay(VIRTUAL_CONTROL_INV_RIGHT)
					self:OnFocusMove(MOVE_RIGHT, true)
				elseif TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_UP) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_UP)) then
					self:_RefreshRepeatDelay(VIRTUAL_CONTROL_INV_UP)
					self:OnFocusMove(MOVE_UP, true)
				elseif TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_DOWN) or (not controller and TheInput:IsControlPressed(CONTROL_FOCUS_DOWN)) then
					self:_RefreshRepeatDelay(VIRTUAL_CONTROL_INV_DOWN)
					self:OnFocusMove(MOVE_DOWN, true)
				else
					self.repeat_time = 0
					self.repeat_reps = 0
				end
			else
				self.repeat_time = REPEAT_TIME

				if TheInput:IsControlPressed(CONTROL_MOVE_LEFT) or TheInput:IsControlPressed(CONTROL_FOCUS_LEFT) then
					self:OnFocusMove(MOVE_LEFT, true)
				elseif TheInput:IsControlPressed(CONTROL_MOVE_RIGHT) or TheInput:IsControlPressed(CONTROL_FOCUS_RIGHT) then
					self:OnFocusMove(MOVE_RIGHT, true)
				elseif TheInput:IsControlPressed(CONTROL_MOVE_UP) or TheInput:IsControlPressed(CONTROL_FOCUS_UP) then
					self:OnFocusMove(MOVE_UP, true)
				elseif TheInput:IsControlPressed(CONTROL_MOVE_DOWN) or TheInput:IsControlPressed(CONTROL_FOCUS_DOWN) then
					self:OnFocusMove(MOVE_DOWN, true)
				else
					self.repeat_time = 0
					self.repeat_reps = 0
				end
			end
        end

-- ★ DoHoverFocusUpdate —— 鼠标焦点跟随的每帧更新。
--   必须在所有连发逻辑**之后**调用：
--   因为方向键导航（861-865）刚刚把焦点移走，
--   若先跑hover 更新就会立刻把焦点抢回鼠标位置。
--   ⇒ 这是「事件驱动的焦点变化必须晚于状态驱动的焦点同步」的顺序要求。
        self:DoHoverFocusUpdate()
    end

-- OnRenderImGui —— 调试面板渲染（1580 定义）。
-- ★ 放在连发逻辑之后、控件更新之前，保证调试面板看到的是
--   本帧最新的输入状态。
    self:OnRenderImGui(dt)

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【控件更新循环】878-892 —— DST UI 性能的核心设计。
--
-- 878     ProfilerPush("update widgets") —— 打点，可被 profiler 观测
-- 879-881 建/复用 alt 快照表（避免每帧 new）
-- 883-885 把 updating_widgets 拷进 alt（★ 遍历时可能在OnUpdate 里改原表，
--         所以必须快照）
-- 887-892 遍历 alt，对 enabled 的调OnUpdate(dt)，然后从 alt 摘除
--
-- ★★ 为什么用「注册表 + 弱引用」而不是「遍历控件树」？
--   遍历树的话：每个 Screen 都得递归几千个 Widget，
--   而绝大多数 Widget **不需要每帧更新**（静态标签、背景图）。
--   widget.lua:485-487 StartUpdating 让控件**按需注册**。
--   ★ 对比 widgets/button.lua:96 的注释：
--     "-- Will only run if the button is manually told to start updating:
--      we don't want a bunch of unnecessarily updating widgets"
--   ⇒ 按需更新是这个UI 框架的核心性能策略。
--
-- ★ 888 行 `if k.enabled then k:OnUpdate(dt) end` ——
--   只看**自己**的 enabled，不看继承的（widget.lua:233-241 IsEnabled）。
--   ⇒ 被 Disable 的子树仍会被遍历（只是不执行 OnUpdate）。
--     ⚠ 微小浪费：可以直接看k:IsEnabled()，但那样会多一次递归。
--────────────────────────────────────────────────────────────────
	TheSim:ProfilerPush("update widgets")
	if not self.updating_widgets_alt then
		self.updating_widgets_alt = {}
	end

	for k,v in pairs(self.updating_widgets) do
		self.updating_widgets_alt[k] = v
	end

	for k,v in pairs(self.updating_widgets_alt) do
		if k.enabled then
			k:OnUpdate(dt)
		end
		self.updating_widgets_alt[k] = nil
	end

-- ★★ 894-909 手柄提示条的显示逻辑。四道门禁：
--   894      先无条件 Hide（保证每帧从干净状态开始）
--   895      controller 或 showhelptextforeverything（调试开关，914-923）
--   896      淡出强度 < 1（Fade 到alpha=1 时不显示）
--   897      不在物品栏导航模式
--   898      不在「黑色淡出」过程中（其它淡出类型可以显示）
-- ★ 898 的条件 `not (fadedir == FADE_OUT and fade_type ~= "black")`
--   意味着：黑场淡出时隐藏提示条，白/扫场淡出时保留。
--   ⚠ 推理：黑场淡出通常伴随场景切换（进游戏），提示条无意义；
--     白场淡出（亮光）时游戏还在，提示条仍有价值。
	self.helptext:Hide()
	if (controller or self.showhelptextforeverything)
        and self:GetFadeLevel() < 1
		and not self.crafting_navigation_mode
        and not (self.fadedir == FADE_OUT and self.fade_type ~= "black") then
		local str = self:GetHelpText()
-- ★★ 901 行 `if str ~= self.helptextstring then` —— 缓存键比较。
--   ★ 只在文本**内容变化**时才重排版（903行很贵）。
--   ⇒ 若焦点在两个文本相同的控件间移动，不重排——
--     正确的优化，因为视觉结果相同。
		if str ~= "" then
			if str ~= self.helptextstring then
				self.helptexttext:SetRegionSize(100, 40)
-- ★★ SetMultilineTruncatedString(str, max_lines, max_width, max_chars, ..., "  ")
--   —— 多行 + 超宽截断，返回**实际行数**。
--   最后那个 "  " 是行内分隔符（与 365 行的 table.concat 分隔呼应）。
--   ★ 返回值 num_lines 直接喂给 904 行 UpdateHelpTextSize 决定背景高度。
--   ★ 这是「测量与渲染分离」：Text 负责测量，FrontEnd 负责布局。
				local num_lines = self.helptexttext:SetMultilineTruncatedString(str, HELP_TEXT_MAX_LINES, HELP_TEXT_MAX_WIDTH, self.helptext_max_characters_per_line, nil, nil, nil, "  ")
				self:UpdateHelpTextSize(num_lines)				
				self.helptextstring = str
			end
			self.helptext:Show()
		end
	end

-- ProfilerPop —— 与 878 行配对。
-- ⚠ 891行从 alt 摘除而883-885 每帧重新拷贝，等于每帧全量搬运一次表。
--   若 updating_widgets 有 N 项，每帧做 N 次插入。
--   N 通常 <50（只有需要更新的控件注册），可接受。
--   ★ 这是一次「为了安全而牺牲常数」的取舍，注释里已点明意图。
	TheSim:ProfilerPop()
end

-- ════════════════════════════════════════════════════════════════
-- 段 11/8：★★ 屏幕栈管理（914-1174）—— 缺陷 G4 的现场
-- ════════════════════════════════════════════════════════════════
function FrontEnd:PushShowHelpTextForEverything()
    self.showhelptextforeverything = (self.showhelptextforeverything or 0) + 1
end

function FrontEnd:PopShowHelpTextForEverything()
    self.showhelptextforeverything = self.showhelptextforeverything - 1
    if self.showhelptextforeverything <= 0 then
        self.showhelptextforeverything = nil
    end
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【DoHoverFocusUpdate】—— 鼠标 → 焦点的同步（每帧执行）。
--
-- 【两步】
--   929  （可选）重新做实体拾取：TheInput:UpdateEntitiesUnderMouse
--   931  读结果：TheInput:GetAllEntitiesUnderMouse
--   933  若命中的是 UI 实体 → hover_inst.widget:SetFocus()
--   936  否则 → 栈顶屏幕自己 SetFocus()（回到屏幕级焦点）
--
-- ★★ 933 行 `hover_inst.widget` 是「实体 → 控件」的反查：
--   widget.lua:11 `self.inst.widget = self` 建的反向指针。
--   ★ 这是 UI 与实体世界之间的**双向连接**，
--     与 widget.lua:306 child.parent = self 互为镜像。
--   ⇒ 没有这行，鼠标命中一个 UI 实体也无法定位到控件。
--
-- ★★ 936 行 `self.screenstack[#self.screenstack]:SetFocus()`：
--   鼠标在空白处 → 把焦点退回**屏幕根**，然后 GetDeepestFocus
--   会下钻到原来有焦点的那个控件（若它的祖先仍在焦点路径上）。
--   ★ 这不是「清空焦点」，而是「让屏幕重新收敛焦点」。
--   ⇒ 这是防止焦点链断裂的兜底机制。
--────────────────────────────────────────────────────────────────
function FrontEnd:DoHoverFocusUpdate(manual_update)
-- ★ 双门禁：tracking_mouse（鼠标模式）且 focus 未被 LockFocus 锁住。
--   ⇒ 549LockFocus 期间鼠标不抢焦点，但 OnControl/OnMouseButton 仍工作。
    if self.tracking_mouse and not self.focus_locked then
-- ★ manual_update 参数来自哪里？—— 全文只有 925 定义、873 调用（无参），
--   所以 manual_update 恒为 nil/false，927-930 实际**从不执行**。
--   ⚠ 疑似缺陷/死代码：manual_update 参数在本文件无任何传 true 的调用点。
--     推理依据：grep 本文件只有 873 一处 `self:DoHoverFocusUpdate()`（无参）。
--     ⇒ 929 的 UpdateEntitiesUnderMouse 只能由外部（鼠标移动时）触发，
--       这里只是「重算焦点」而非「重算命中」。
--     影响：鼠标不动但 UI 元素移动（如拖放中的物品）时，
--     焦点不会重新拾取。这与 874 行前面的注释语义相符
--     （"--something has been manually moved" 指控件移动而非鼠标）。
--     ⚠ 但控件移动后本应重新拾取——所以 manual_update 的意图
--       与实际调用方式不匹配。属未完成的机制。
		if manual_update then
			--something has been manually moved, so we want to update the entities under the mouse and re-evaluate the hover/focus state
			TheInput:UpdateEntitiesUnderMouse()
		end
-- ★★ GetAllEntitiesUnderMouse（input.lua:263-265）返回的是
--   **实体拾取结果**，包含 3D 世界实体与 UI 实体混排的列表。
--   该列表由 input.lua:519-571 OnUpdate 每帧计算。
--   ★ 933 行只取 [1]（最上面的那个），不做穿透筛选——
--     穿透筛选已在 input.lua:526-557 的 CanMouseThrough 里做完。
	    local entitiesundermouse = TheInput:GetAllEntitiesUnderMouse()
        local hover_inst = entitiesundermouse[1]
-- ★★ 判据是 `hover_inst.widget` 存在 —— 即「这是一个 UI 实体」。
--   3D 世界实体没有 widget 字段（widget.lua:11 只给 UI 实体设）。
--   ⇒ 这一行就是「鼠标命中的是 UI 还是世界」的判定点。
--   ⚠ 对比 input.lua:284-291 GetHUDEntityUnderMouse 用
--     `self.hoverinst.Transform == nil` 判定「是 HUD 实体」——
--     **两种判定方式并存**（有无 widget 字段 vs 有无 Transform）。
--     理论上一致（UI 实体无 3D Transform），但不统一。
        if hover_inst and hover_inst.widget then
            hover_inst.widget:SetFocus()
        elseif #self.screenstack > 0 then
            self.screenstack[#self.screenstack]:SetFocus()
        end
    end
end

-- ★★★ StartUpdatingWidget / StopUpdatingWidget —— 更新注册表。
--   这是 widget.lua:485-487 StartUpdating/StopUpdating 的对端。
--   ★ 表是弱键（234 行），所以控件被 GC 后条目自动消失。
-- ⚠ 但 StopUpdating（945-947）显式置 nil：如果控件被 Kill 后
--   有人再调 StopUpdating，置 nil 一个不存在的键是安全的（无副作用）。
function FrontEnd:StartUpdatingWidget(w)
	self.updating_widgets[w] = true
end

function FrontEnd:StopUpdatingWidget(w)
	self.updating_widgets[w] = nil
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【屏幕栈管理三函数】949-974：压栈的三种变体。
--
--  【InsertScreenAtIndex(949)】插到指定下标
--  【InsertScreenUnderTop(959)】插到栈顶**之下**
--  【PushScreen(967)】插到栈顶
--
-- ★★ 三者的共同骨架（949-957 vs 959-965 vs 967-1000）：
--   ① screenroot:AddChild(screen)   —— 挂到实体树上
--   ② table.insert(screenstack, ...) —— 记进栈
--   ③ MoveToFront consoletext / serverpausewidget —— 修复层级
--
-- ★★ 三者的**关键差异**（也是缺陷 G4 的结构性来源）：
--   · PushScreen     ：调 OnBecomeInactive（旧顶）+ OnBecomeActive（新顶）
--   · InsertScreenUnderTop：**两个都不调**
--   · InsertScreenAtIndex  ：**两个都不调**
--   ⇒ 用 Insert 路径插进来的屏幕，永远不会成为「活动屏幕」，
--     直到它下面的屏幕被弹出，触发 PopScreen 的 1127-1129 分支。
--   ⚠ 这就是 G4：PlayerHud:OpenScreenUnderPause（playerhud.lua:460-465）
--     在暂停屏打开时走 InsertScreenUnderTop，弹窗处于「已入栈但未激活」
--     的中间态。若暂停屏在此期间被别的路径移除，
--     OnBecomeActive 才补上——若没移除，弹窗**永远没被激活过**。
--   ⚠ 推理依据：InsertScreenUnderTop 全库唯一调用点是
--     screens/playerhud.lua:462（grep 核实），
--     而它专用于「暂停时开物品栏/制作栏」的场景。
--────────────────────────────────────────────────────────────────
function FrontEnd:InsertScreenAtIndex(screen, idx)
-- ★ screenroot:AddChild(screen) —— 挂载即决定了渲染层级（见 169-179 说明）。
    self.screenroot:AddChild(screen)
-- ★ table.insert(screenstack, idx, screen) —— idx 是插入位置（1..n+1）。
    table.insert(self.screenstack, idx, screen)
-- ★★ 952-954：把 idx 及其之后的所有屏幕 MoveToFront。
--   ⇒ 视觉效果：从插入位置往下，层序依次抬到最前。
--   ★ 为什么 consoletext / serverpausewidget 要单独再提一次（955-956）？
--     因为它们是 screenroot 的固定子节点，被新屏 AddChild 后会被压住，
--     必须重新提到最前。
--   ⚠ 缺陷风险：952 的循环**不包含** consoletext/serverpausewidget，
--     它们靠 955-956 补救。但如果屏幕数量很多，
--     953 的循环会把 idx 之后的屏幕盖在 consoletext 之上——
--     随后 955-956 把 consoletext 提到最前，顺序正确。
    for i = idx, #self.screenstack do
        self.screenstack[i]:MoveToFront()
    end
    self.consoletext:MoveToFront()
    self.serverpausewidget:MoveToFront()
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【InsertScreenUnderTop】—— 压到栈顶之下，但不激活。
--
-- 用途（screens/playerhud.lua:460-465）：
--   暂停屏开着的时候打开物品栏/制作栏 → 用这个，
--   让物品栏显示在**暂停屏之下**，但仍在栈里（能被 GetActiveScreen
--   之外的逻辑看到、能被统一清理）。
--
-- ⚠⚠ 缺陷 G4 的准确现场：
--   959-965 **完全没有** OnBecomeInactive / OnBecomeActive 调用。
--   对比 PushScreen（977-979 调旧屏 OnBecomeInactive，995 调新屏
--   OnBecomeActive）与 PopScreen（1106/1119 调 OnBecomeInactive，
--   1129 调新顶屏 OnBecomeActive）。
--   ⇒ 插入的屏幕处于「在栈里、已挂实体树、但从未 OnBecomeActive」
--     的第三态。它既不会被 TheSim:SetUIRoot 设为输入根（screen.lua:34），
--     也不会恢复 last_focus（screen.lua:36）。
--   ⚠ 后果链：
--     ① 输入不会路由到这棵子树（因为 UIRoot 还是暂停屏的）；
--     ② 若弹出暂停屏，PopScreen 的 1127 条件 `top_screen and old_head ~=
--        top_screen` 成立 → 会补调 OnBecomeActive —— 状态被「补齐」，
--        但 OnBecomeInactive 此前**从未成对调过**。
--     ③ 若这期间该屏幕被 IsEditing/IsControlsDisabled 之类的查询碰到，
--        它的内部状态可能处于半初始化。
--   ★★ 官方注释 1029-1031 提到的「leaves your screen in bad state」
--     与这里是同一族问题：框架提供了三条入栈路径，
--     但只有两条（Push/Pop）维护了激活/失活的对称性。
--────────────────────────────────────────────────────────────────
function FrontEnd:InsertScreenUnderTop(screen)
    self.screenroot:AddChild(screen)
    table.insert(self.screenstack, #self.screenstack, screen)
-- ★ 只对**这一个**屏幕 MoveToFront（而不是 952 那样循环）。
--   因为它插在「栈顶之下」，其后没有任何屏幕需要提层。
    self.screenstack[#self.screenstack]:MoveToFront()
    self.consoletext:MoveToFront()
    self.serverpausewidget:MoveToFront()
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【PushScreen】—— 压栈的主路径，全文件最重要的函数之一。
--
-- 【七步流程（967-1000）】
--  ① 968      focus_locked = false      —— 解开全局焦点锁
--  ② 969      SetForceProcessTextInput(false) —— 结束文本框强制输入
--  ③ 970      TheInputProxy:FlushInput() —— ★ 清空 C++ 侧的按键状态
--  ④ 977-979  旧顶屏 OnBecomeInactive   —— ★ 记忆焦点（screen.lua:29）
--  ⑤ 981-984  挂实体树 + 入栈 + 修复 consoletext/serverpausewidget 层级
--  ⑥ 987-989  serverpausewidget 偏移（可选钩子）
--  ⑦ 992-996  按 tracking_mouse 决定是否给默认焦点 + OnBecomeActive
--              + ★ self:Update(0) 立即刷新一帧
--
-- ★★ 970 行 FlushInput —— 「跨屏幕清输入」，防 G3 的第一道闸：
--   如果玩家「按住左键点按钮」进入新屏，不清输入的话
--   新屏会立刻看到一个仍处于按下状态的左键。
--   ⚠ 但这是**唯一的两处**之一（另一处是 1096PopScreen）。
--     InsertScreenUnderTop（959）**不做**这件事。
--
-- ★★ 979 行 OnBecomeInactive 的作用（widgets/screen.lua:28-30）：
--   `self.last_focus = self:GetDeepestFocus()`
--   ⇒ 焦点记忆就是**出栈时记下深层焦点，入栈时恢复**。
--   ★ 这是 G1 的上下文：记忆的是**对象引用**，
--     而 screen.lua:35 有 `last_focus.inst.entity:IsValid()` 守卫。
--     若某个屏幕的 last_focus 指向的控件在别处被 Kill，
--     IsValid 拦不住「控件对象还在但 inst 已移除」之外的情况。
--
-- ★ 973-974 的原注释记录了一次被否决的设计：
--   "--jcheng: don't allow any other screens to push if we're displaying an error"
--   "--if global_error_widget ~= nil then return end -- Note: this just leaves
--      screens outside the screen hierarchy which is worse than having them pushed"
--   ★ 作者的判断值得学习：「拒绝压栈」比「压了但不可见」更糟，
--     因为后者会留下悬空状态。所以错误期间照常压栈，
--     靠 IsControlsDisabled（400行）冻结一切输入。
--────────────────────────────────────────────────────────────────
function FrontEnd:PushScreen(screen)
	self.focus_locked = false
-- ★★ SetForceProcessTextInput(false) —— 结束任何「强制文本输入」。
--   签名只有一个参数 takeText（见 1176），widget 为 nil → 走 1184 分支
--   → 通知旧控件 OnStopForceProcessTextInput 并清空。
--   ★ 为什么压栈必须结束文本输入？因为新屏有自己的文本框，
--     旧的强制输入状态会让新屏的输入被劫持。
	self:SetForceProcessTextInput(false)
-- ★★ TheInputProxy:FlushInput() —— C++ 侧的输入缓冲清空。
-- ★★ 这是缺陷 G3 的一环：FlushInput 清的是「物理按键的按下状态」，
--   但**清不掉**已经写进游戏层的 sg.statemem.retarget。
--   ⇒ 所以还需要 439-448 那个 #HACK。两个补丁解决同一个问题的
--     不同侧面，说明架构层的输入仲裁不完整。
--   ⚠ 参见 bug-patterns.md G3 的「✅ 正确做法」：
--     应在 Input::OnControl（input.lua:163）就一次性标记 swallowed，
--     而不是在下游反向清理。
	TheInputProxy:FlushInput()

	--self.tracking_mouse = false
	--jcheng: don't allow any other screens to push if we're displaying an error
    --if global_error_widget ~= nil then return end -- Note: this just leaves screens outside the screen hierarchy which is worse than having them pushed

    Print(VERBOSITY.DEBUG, 'FrontEnd:PushScreen', screen.name)
-- ★★ 旧顶屏失活。977 行的 `#self.screenstack > 0` 保证不会对空栈调用。
--   ⚠ 但这里**没有**对应地调旧顶屏的 SetFocus 清理，
--     也没有任何「焦点迁移」逻辑——焦点迁移完全靠 1127-1129 在
--     **PopScreen** 时完成。
--   ⇒ ⚠ 缺陷 G4 的第二个不对称点：
--     PushScreen 只让旧屏「失活」，**不把焦点交给新屏之外的东西**；
--     而 992-994 只在 `not self.tracking_mouse` 时给新屏默认焦点。
--     ⇒ 若 tracking_mouse 为 true（鼠标模式），PushScreen **不给焦点**，
--       焦点就悬在旧屏上——直到 996 的 self:Update(0) 触发 873 的
--       DoHoverFocusUpdate 才可能重新收敛。
--     若 Update(0) 时鼠标不在任何 UI 上（935→936），
--     则走screen: SetFocus() 收敛到栈顶屏。
--     ⇒ 最终是收敛的，但路径曲折。
    if #self.screenstack > 0 then
        self.screenstack[#self.screenstack]:OnBecomeInactive()
    end

-- ★★ screenroot:AddChild(screen) —— 挂载。
--   ★ 隐含约定：新屏成为 screenroot 的**最后一个子节点**，
--     因而在所有遮罩之上（详见 169-179 行的层级说明）。
    self.screenroot:AddChild(screen)
    table.insert(self.screenstack, screen)
    self.consoletext:MoveToFront()
    self.serverpausewidget:MoveToFront()
-- ★ serverpausewidget:SetOffset(0, 0) —— 先复位偏移。
--   然后 987-989 若屏幕实现了 OffsetServerPausedWidget 就让它自己调。
--   ★ 为什么要在 Push 时复位？因为 PopScreen（1131）也复位，
--     两个入口保持一致 ⇒ 偏移不会被上一个屏幕的设置污染。
    self.serverpausewidget:SetOffset(0, 0)

-- ★★ 可选钩子：screen.OffsetServerPausedWidget is not nil then screen:...()
--   ⇒ 「鸭子类型」：屏幕想自定义服务器暂停提示的位置就实现它，
--     不想就什么都不做。
--   ★ 对比 PopScreen 的 1133-1135 用完全相同的写法。
    if screen.OffsetServerPausedWidget then
        screen:OffsetServerPausedWidget(self.serverpausewidget)
    end

-- ⚠ 991 行原注释 "-- screen:Show()" 被注释掉了。
--   ★ 推理：Screen 构造时默认可见（widget.lua:25 self.shown = true），
--     所以不需要 Show。而 FadeBack（1075）在 PopScreen 之后
--     显式调 TheFrontEnd:GetActiveScreen():Show() —— 说明确实存在
--     「屏幕被 Hide 过」的状态（比如 FadeToScreen 的 1070 existing_screen:Hide()）。
    -- screen:Show()
-- ★★ `if not self.tracking_mouse then screen:SetDefaultFocus() end`
--   ★ 语义：**只有当鼠标不跟随时**才立即给默认焦点。
--   鼠标跟随时不给焦点，让鼠标位置决定（996 Update(0) → 873 hover 更新）。
--   ⇒ 这就是「鼠标模式 / 手柄模式」两套焦点策略的分叉点。
    if not self.tracking_mouse then
        screen:SetDefaultFocus()
    end
-- ★★ screen:OnBecomeActive() —— 见 widgets/screen.lua:32-43。
--   做三件事：
--   ① LastUIRoot = self.inst.entity    （全局变量，给 C++ 用）
--   ② TheSim:SetUIRoot(self.inst.entity) ★ 把输入路由到这棵子树
--   ③ 恢复 last_focus 或 default_focus
--   ⚠ ② 是「输入根」机制的核心：TheInput 的所有命中测试
--     都只在这棵子树里做（input.lua:519 的 GetEntitiesAtScreenPoint）。
--     ★ 所以「栈顶之外屏幕收不到输入」不是靠 screenstack 判定的，
--       而是靠 UIRoot —— 这就是为什么 InsertScreenUnderTop
--       插入的屏幕收不到输入（它没被 SetUIRoot 过）。
    screen:OnBecomeActive()
-- ★★ self:Update(0) —— 用 dt=0 立即跑一帧前端更新。
--   为什么必须立刻跑？
--   · 759-761 只有栈顶屏收 OnUpdate → 新屏要立刻初始化布局；
--   · 883-892 控件更新表 → 新屏的 StartUpdating 注册要立刻生效；
--   · 894-909 提示条 → 新屏的 GetHelpText 要立刻计算。
--   ★ dt=0 意味着「只做状态计算，不推进动画」——
--     正合「刚布局完、还没开始动」的需求。
--   ⚠ 代价：PushScreen 会触发一次完整的 Update（可能很贵，
--     因为 694-698 每帧重建控制台字符串）。
    self:Update(0)

	--print("FOCUS IS", screen:GetDeepestFocus(), self.tracking_mouse)
	--self:Fade(FADE_IN, 2)
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【ClearScreens】—— 清空整个屏幕栈。
--
-- 1003-1005 只对**栈顶**调 OnLoseFocus（不是 OnBecomeInactive！）
-- 1007-1010 while 循环：从顶到底逐个 OnDestroy + table.remove
--
-- ★★ Screen:OnDestroy（screen.lua:20-22）就是 self:Kill()，
--   而 Widget:Kill（widget.lua:325-334）会 KillAllChildren（291-298），
--   后者逐一 RemoveChild + Kill，并调 ClearHoverText。
--   ⇒ 递归销毁整棵子树。
--
-- ⚠⚠ 缺陷 G4 的第三个不对称点，也是最严重的一处：
--   **ClearScreens 只调 OnLoseFocus，从不调 OnBecomeInactive。**
--   对比 PushScreen（979）与 PopScreen（1106/1119）——
--   两者都会调 OnBecomeInactive（内部做 last_focus = GetDeepestFocus()）。
--   ⚠ 后果：ClearScreens 后，屏幕的 last_focus **不会被更新**。
--     若同一个屏幕实例被复用（screenstack 里的实例被 ClearScreens
--     销毁了，但调用方可能还持有引用并在之后重新 Push），
--     其last_focus 仍指向**上一次退出时的老焦点**。
--   ⚠ 更进一步：OnDestroy → Kill → self.inst:Remove()，
--     但 self.last_focus 字段仍持有那个已被 Kill 的 Widget 对象。
--     若该屏幕实例再次 Push 且 OnBecomeActive 执行，
--     screen.lua:35 的 `last_focus.inst.entity:IsValid()` 检查会拦住它，
--     落到 38 行 `last_focus = nil` + default_focus。
--   ⇒ ★★ 这就是 G1 与 G4 的**交汇点**：
--     G4（状态残留）制造了脏的 last_focus，G1（焦点指向已销毁控件）
--     消费它。两者必须一起看才能理解。
--   ⚠ 推理依据：1003-1005 只有 OnLoseFocus 一个调用，
--     全文 grep 本文件 OnBecomeInactive 仅出现在 978 / 1106 / 1119 三行，
--     ClearScreens 不在其中。
--────────────────────────────────────────────────────────────────
function FrontEnd:ClearScreens()
	if #self.screenstack > 0 then
		self.screenstack[#self.screenstack]:OnLoseFocus()
	end

	while #self.screenstack > 0 do
		self.screenstack[#self.screenstack]:OnDestroy()
		table.remove(self.screenstack, #self.screenstack)
	end
end

-- ShowConsoleLog / HideConsoleLog —— 一行转发。
-- ★ 与 462-468 的 toggle 分支配合使用。
function FrontEnd:ShowConsoleLog()
	self.consoletext:Show()
end

function FrontEnd:HideConsoleLog()
	self.consoletext:Hide()
end

-- SetConsoleLogPosition —— 外部可移动控制台文本。
-- ★ 说明控制台文本的位置不是完全固定的（调试工具会挪它）。
function FrontEnd:SetConsoleLogPosition(x, y, z)
    self.consoletext:SetPosition(x, y, z)
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【Fade / FadeToScreen / FadeBack】—— 转场三件套。
--
-- 【Fade(1032)】底层原语：设定状态机初值
-- 【FadeToScreen(1059)】压栈 + 淡出 + 淡入 的组合
-- 【FadeBack(1075)】出栈 + 淡出 + 淡入 的组合
--────────────────────────────────────────────────────────────────
function FrontEnd:DoFadeIn(time_to_take)
	self:Fade(FADE_IN, time_to_take)
end

-- ╔═════════════════════════════════════════════════════════════╗
-- ║ ★★★ 官方原文警告（1029-1031）—— 这是理解「alpha 淡出」的关键  ║
-- ╚═════════════════════════════════════════════════════════════╝
-- 原文：
--   "-- **CAUTION** about using the "alpha" fade: it leaves your screen's
--        widgets at alpha 0 when it's finished AND makes all children
--        of the screen not clickable"
--   "-- It generally leaves the screen in bad state: don't use lightly
--        for screens that will be returned to (ex: we only use it leading
--        into a sim reset)"
--
-- 【两条已知副作用】
--  ① 控件停在 alpha=0（575-646 SetFadeLevel 的 alpha 分支只设不恢复）
--  ② 控件**变得不可点击** —— alpha=0 的 UI 实体在引擎命中测试里
--     被视作不可见而跳过 ⇒ 鼠标点不到。
--
-- 【为什么不可逆】
--   恢复需要「递归把每个控件 alpha 设回 1 且重新可点击」，
--   而 widget.lua:506-514 SetFadeAlpha 会**跳过 can_fade_alpha=false
--   的控件**（28 行字段）—— 所以无法保证全部恢复。
--
-- 【官方限定用法】
--   "we only use it leading into a sim reset" ——
--   只用于「即将重建整个模拟」的场景（进游戏/回大厅）。
--   此时屏幕状态不复用，副作用无害。
--
-- ★★ 这段警告与缺陷 G4 是同一族问题：
--   「屏幕状态残留」——框架提供了会留下坏状态的能力，
--   只能靠**使用约定**来规避，没有机制保障。
--   对照 bug-patterns.md G4 的建议：
--   应在 Screen 基类用断言强制 OnBecomeActive/Inactive 对称。
-- **CAUTION** about using the "alpha" fade: it leaves your screen's widgets at alpha 0 when it's finished AND makes all children of the screen not clickable
-- It generally leaves the screen in bad state: don't use lightly for screens that will be returned to (ex: we only use it leading into a sim reset)
-- Fixup after using an "alpha" fade would include making the appropriate children of the screen clickable and setting alphas appropriately
-- ★★ Fade(in_or_out, time_to_take, cb, fade_delay_time, delayovercb, fadeType)
-- 七个状态字段一次性设定：
--   fadedir / total_fade_time / fadecb / fade_time / fade_type
--   + fade_delay_time / delayovercb
-- ★ 参数全是可选的，除了前两个。fadeType 默认 "black"（1037）。
-- ⚠ 注意这里**不重置** fade_delay_time 为 nil，而是直接赋值 1055 行，
--   所以 Fade(FADE_IN) 之后若省略该参数，fade_delay_time = nil，
--   652DoFadingUpdate 会走 664 的过渡分支。✓ 正确。
function FrontEnd:Fade(in_or_out, time_to_take, cb, fade_delay_time, delayovercb, fadeType)
	self.fadedir = in_or_out
	self.total_fade_time = time_to_take
	self.fadecb = cb
	self.fade_time = 0
	self.fade_type = fadeType or "black"
-- ★★ FADE_IN 分支：立刻 SetFadeLevel(1)（全黑），然后过渡到 0。
--   ⇒ 「淡入」的实现是：**先瞬间全黑，再渐渐变透明**。
--   这解释了为什么 597 SetFadeAlpha(1) 在「alpha」模式下是必要的：
--     FADE_IN 起始 alpha=1 → 屏幕控件全部 alpha=0（全隐藏），
--     结束时必须恢复成 1。
--   ⚠ 而 610-616 的 alpha 模式在 FADE_IN 期间会把控件 alpha 设成
--     1-alpha（0），结束时 alpha→0 ⇒ 控件 alpha 恢复为 1。
--     ⇒ 593-597 的补救其实只在**手动调SetFadeLevel(0)** 时才需要。
	if in_or_out == FADE_IN then
		self:SetFadeLevel(1)
	else
-- ★★ 1041-1042 的原注释解释了 top 遮罩的复位：
--   "-- starting a fade out, make the top fade visible again"
--   "-- this place it can actually be out of sync with the backfade, so make it full trans"
-- ★ 「可能与 backfade 不同步」⇒ 所以强制设为完全透明（0），
--   然后让 652 的 DoFadingUpdate 正常推进，避免残留中间态。
--   ⇒ 这是「宁可多设一次也不能留脏状态」的实用主义。
		-- starting a fade out, make the top fade visible again
		-- this place it can actually be out of sync with the backfade, so make it full trans
		if self.fade_type == "white" then
			self.topwhiteoverlay:SetTint(FADE_WHITE_COLOUR[1], FADE_WHITE_COLOUR[2], FADE_WHITE_COLOUR[3], 0)
			self.topvigoverlay:SetTint(1,1,1,0)
		elseif self.fade_type == "black" then
			self.topblackoverlay:SetTint(0,0,0,0)
		elseif self.fade_type == "swipe" then
			self.topswipeoverlay:SetTint(1,1,1,0)
			self.topswipeoverlay:SetEffectParams(0,0,0,0)
		end
		self:ShowTopFade()
        DoAutopause()
	end
	self.fade_delay_time = fade_delay_time
	self.delayovercb = delayovercb
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【FadeToScreen】—— 「淡出 → 换屏 → 淡入」的原子操作。
--
-- 【结构：一次Fade(FADE_OUT)，完成回调里做三件事】
--  1067  new_screen = new_screen_fn()          —— ★ 用**函数**而非实例
--  1068  TheFrontEnd:PushScreen(new_screen)    ——   因为屏幕可能在回调时才可用
--  1069  TheFrontEnd:Fade(FADE_IN, ...)        ——   反向淡入
--  1070  existing_screen:Hide()                ——   ★ 只 Hide，不 Pop！
--
-- ★★ 三个设计要点：
-- ① 【new_screen_fn 是函数】—— 延迟构造。
--   为什么要延迟？因为 FadeToScreen 常在「关卡切换」时调用，
--   那时构造新屏需要的数据（服务器信息等）可能还在加载。
--   ⇒ 用闭包把「什么时候造」推迟到淡出结束那一刻。
-- ② 【existing_screen:Hide() 而非 PopScreen】—— 1070 行。
--   ★★ 这是缺陷 G4 的**最直接物证**：
--     屏幕被「隐藏但仍在栈里」！
--     ⇒ 后果一：#screenstack 仍然包含它，GetActiveScreen 可能返回它；
--       实际上 PushScreen(new) 已把它压下去，所以栈顶是新的 ✓；
--     ⇒ 后果二：它仍占着实体树的一个节点，仍会被 Update 的
--       759-761 之外的路径触及（比如 ClearScreens）；
--     ⇒ 后果三：★ 它的 OnBecomeInactive 在 PushScreen 的 978 行
--       **确实被调到了**（因为它是旧顶屏），所以焦点记忆是好的；
--     ⇒ 后果四：⚠ 它被 Hide 了，但 **shown=false 不会阻止收事件**——
--       widget.lua 没有「shown 才收事件」的检查，只有 IsVisible（101）
--       被 OnFocusMove 用来判定 focus_flow 的目标（84 行）。
--       于是「隐藏的屏幕若仍有焦点」仍可能吃掉输入。
--       ★ 这是「shown 与 focus 正交」的又一个代价。
-- ③ 【1055-1056 传 fade_delay_time=0】—— 让两段淡出无缝衔接。
--   652DoFadingUpdate 的 654-663 延迟分支会在 fade_delay_time<=0 时
--   立即执行 delayovercb（这里为 nil）并转入过渡分支。
--────────────────────────────────────────────────────────────────
function FrontEnd:FadeToScreen( existing_screen, new_screen_fn, fade_complete_cp, fade_type )
-- ★ 淡入淡出时长按类型分：SCREEN_FADE_TIME / SWIPE_FADE_TIME。
-- ★ 这是常量级的差异（普通转场 vs 扫场转场），不在参数里暴露。
	local fade_time = SCREEN_FADE_TIME
	if fade_type == "swipe" then
		fade_time = SWIPE_FADE_TIME
	end

	self:Fade(FADE_OUT, fade_time,
		function()
-- ★★ new_screen_fn() —— 延迟构造的兑现点。
--   ⚠ 若这个函数抛错，fadecb 已被清空（686-687）→ 屏幕会卡在全黑。
--     没有错误兜底。⚠ 属「异常安全」缺失。
			local new_screen = new_screen_fn()
			TheFrontEnd:PushScreen( new_screen )
            TheFrontEnd:Fade(FADE_IN, fade_time, fade_complete_cp and function() fade_complete_cp(new_screen) end, 0, nil, fade_type )
            existing_screen:Hide()
		end,
	0, nil, fade_type)
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【FadeBack】—— FadeToScreen 的「反向」版本（出栈）。
--
-- 与 FadeToScreen 的三处差异：
--  ① 1083-1085 多一个 fade_out_complete_cb（在 PopScreen **之前**执行）
--  1086 TheFrontEnd:PopScreen()             —— 真的出栈（带 OnDestroy）
--  1088 TheFrontEnd:GetActiveScreen():Show() —— ★ 把上一个屏幕 Show 回来
--
-- ★★ 1088 的 Show 是必需的：因为 FadeToScreen 的 1070 把旧屏 Hide 了。
--   ⇒ ★★ FadeBack 与 FadeToScreen 是一对**必须配对使用**的操作。
--     单独调 FadeBack 而没先 Hide 过当前屏 → 上一屏本来就是 Show 的，
--     再 Show 一次无害（widget.lua:318-323 Show 幂等）。
--     单独调 FadeToScreen 而之后不 FadeBack → 旧屏永远 Hide 着。
--   ⚠ 这是**隐式契约**：两个函数必须成对。
--   ⇒ 与缺陷 G4 同源：屏幕的 shown/focus 状态被跨屏操作遗留，
--     而框架没有断言检查这种遗留。
--────────────────────────────────────────────────────────────────
function FrontEnd:FadeBack( fade_complete_cb, fade_type, fade_out_complete_cb )
	local fade_time = SCREEN_FADE_TIME
	if fade_type == "swipe" then
		fade_time = SWIPE_FADE_TIME
	end

	self:Fade(FADE_OUT, fade_time,
		function()
			if fade_out_complete_cb ~= nil then
				fade_out_complete_cb()
			end
-- ★★ PopScreen() —— 注意**没有传参**，所以走 1114-1123 的「弹栈顶」分支。
--   这保证了 OnBecomeInactive/OnDestroy/RemoveChild 三步都执行（对称）。
--   ⇒ 对比 1103-1113 的「按对象弹出」分支（有不对称）。
			TheFrontEnd:PopScreen()
            TheFrontEnd:Fade(FADE_IN, fade_time, fade_complete_cb, 0, nil, fade_type)
            TheFrontEnd:GetActiveScreen():Show()
		end,
	0, nil, fade_type)
end

-- ════════════════════════════════════════════════════════════════
-- ★★★★ 【PopScreen(screen)】—— 出栈，缺陷 G4 的核心现场。
--
-- 【两个分支】
--  【分支 A：传入 screen 对象（1100-1113）】—— 弹栈中间的屏
--  【分支 B：不传（1114-1123）】—— 弹栈顶
--
-- 【共同前置（1094-1097）】
--  1094  focus_locked = false
--  1095  SetForceProcessTextInput(false)
--  1096  TheInputProxy:FlushInput()   ← 与 PushScreen 的 970 配对
--
-- 【分支 B 的正确性（1116-1122）】
--  table.remove → OnBecomeInactive → OnDestroy → RemoveChild
--  ⇒ OnBecomeInactive 与 OnDestroy **成对**，焦点记忆正确写入。
--  ⚠ 唯一瑕疵：没有 OnLoseFocus（ClearScreens 有，这里没有）。
--    ⇒ 屏幕在失活时，其内部「最深焦点控件」不会收到 OnLoseFocus。
--    相比之下 ClearScreens 只给栈顶调了 OnLoseFocus。
--    ⇒ ⚠ 两处都不完整：PopScreen 完全不调，ClearScreens 只调一个。
--────────────────────────────────────────────────────────────────
function FrontEnd:PopScreen(screen)
	self.focus_locked = false
	self:SetForceProcessTextInput(false)
	TheInputProxy:FlushInput()
	--self.tracking_mouse = false

-- ★★ old_head = 弹栈前的栈顶 —— 用于 1127 判断「栈顶是否改变」。
--   若弹的就是栈顶，弹完后新栈顶**必然**与 old_head 不同（栈里原来就有它）。
--   ⇒ 1127 的条件恒真，除非栈只剩1 个（弹完栈空，top_screen 为 nil）。
--   ★ 变量名的意义在于对比，而不是判断「谁被弹了」。
	local old_head = #self.screenstack > 0 and self.screenstack[#self.screenstack]
-- ════════════════════════════════════════════════════════════════
-- ⚠⚠⚠ 【分支 A：按对象弹出】—— 缺陷 G4 的最准确行号：1103-1113
--
-- 【代码逻辑】
--   for k,v in ipairs(self.screenstack) do
--     if v == screen then
--       if old_head == v then screen:OnBecomeInactive() end  ← ★ 条件！
--       table.remove(self.screenstack, k)
--       screen:OnDestroy()
--       self.screenroot:RemoveChild(screen)
--       break
--     end
--   end
--
-- 【★ 为什么这是缺陷】
--   1105 行 `if old_head == v then` —— 只有弹出的是**栈顶**才调
--   OnBecomeInactive。弹出栈**中间**的屏幕时，
--   ★★ **OnBecomeInactive 永远不会被调用**。
--
-- 【三个层次的后果】
--  ① 【G4 状态残留】
--     中间屏的 last_focus 不会被更新（screen.lua:29 的赋值不执行）
--     ⇒ 若该屏幕实例被复用并重新 Push，OnBecomeActive（screen.lua:32-43）
--       会恢复一个**过期**的 last_focus。
--  ② 【G1 焦点指向已销毁控件】
--     该屏的 inst 已被 OnDestroy → Kill → Remove 销毁，
--     但 last_focus 字段仍持有那个 Widget 对象。
--     ⚠ 而 last_focus 是**字段**，不是弱引用 —— 对象不会自动变 nil。
--     若外部代码（模组）持有该屏幕实例并复用，
--     screen.lua:35 的 IsValid 检查是唯一的防线。
--  ③ 【OnDestroy 与 OnBecomeInactive 语义不匹配】
--     1109 行无条件调 OnDestroy —— 屏幕被彻底销毁了。
--     一个被销毁的屏幕，「失活」回调本无意义；
--     ★ 但**对称性检查**（G4 排查方法）会发现不匹配。
--       因为 PushScreen(978) 调了旧屏 OnBecomeInactive，
--       这一次却不调 → 全局计数失衡。
--
-- 【为什么条件存在】
--   推测：作者认为「非栈顶的屏幕本来就不是活动的，失活回调无意义」。
--   ★ 但这与 InsertScreenUnderTop（959-965）叠加后出问题：
--     Insert 路径插进来的屏**从未被激活**，
--     若之后走分支 A 被弹出，OnBecomeInactive 也不会被调。
--     ⇒ 「激活/失活」这对回调在这条路径上**从来没有成对过**。
--
-- 【修复方向（不改代码，仅记录）】
--   把 1105-1107 改成无条件调用，或把「是否失活」显式记为字段：
--     screen._was_active 由 OnBecomeActive 置位，
--     OnDestroy 时若为真则补调 OnBecomeInactive。
--   ⇒ 这正是 bug-patterns.md G4 建议的「对称性断言」的价值所在。
--────────────────────────────────────────────────────────────────
	if screen then
		-- screen:Hide()
		Print(VERBOSITY.DEBUG,'FrontEnd:PopScreen', screen.name)
-- ★ ipairs 正序遍历 + break —— 只弹第一个匹配的（正确）。
--   ⚠ 但 table.remove(self.screenstack, k) 在遍历中修改了被遍历的表。
--     因为紧接着 break，Lua 的 for 循环不会再访问 k+1，安全。
--     ⇒ 这是「修改后立即退出」的合法模式，不是缺陷。
		for k,v in ipairs(self.screenstack) do
			if v == screen then
-- ⚠⚠ 缺陷 G4 的**准确行号：1105-1107**。
--   条件 `old_head == v` 使OnBecomeInactive 只在弹栈顶时执行。
--   弹出栈中屏时该回调被跳过 ⇒ 状态残留 + 与 PushScreen 不对称。
--   完整推理见 1100 行的注释块。
				if old_head == v then
					screen:OnBecomeInactive()
				end
				table.remove(self.screenstack, k)
-- ★★ screen:OnDestroy() → screen.lua:20 → self:Kill()
--   → widget.lua:325-334：StopUpdating + KillAllChildren + 摘出父节点
--   + self.inst.widget = nil + StopFollowMouse + self.inst:Remove()。
--   ⚠ 注意 1109 在 1110 RemoveChild **之前**调用：
--     Kill 里328-330 已经把自己从 parent.children 摘掉了，
--     所以 1110 的 screenroot:RemoveChild(screen) 里
--     widget.lua:282-289 的 `self.children[child] = nil` 是幂等空操作。
--     ⇒ 顺序无害，但略有冗余。
--   ★ 真正重要的在 1111 行 RemoveChild 的 286 行：
--     `child.inst.entity:SetParent(nil)` —— 从实体树上摘除。
--     931GetAllEntitiesUnderMouse 的拾取只搜 UIRoot 子树，
--     摘除后这个屏幕的任何实体都不会再被鼠标命中。
				screen:OnDestroy()
				self.screenroot:RemoveChild(screen)
				break
			end
		end
	else
		Print(VERBOSITY.DEBUG,'FrontEnd:PopScreen')
		if #self.screenstack > 0 then
			local screen = self.screenstack[#self.screenstack]
			table.remove(self.screenstack, #self.screenstack)
			screen:OnBecomeInactive()
			screen:OnDestroy()
			self.screenroot:RemoveChild(screen)
		end

	end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【新栈顶的重新激活】1126-1142 —— G4 的另一半补丁。
--
-- 条件 `if top_screen and old_head ~= top_screen then`：
--   · top_screen 为 nil → 栈空了，不激活（正确）
--   · old_head == top_screen → 弹的不是栈顶，新栈顶没变（不重复激活）
--   · 否则 → 栈顶确实变了，需要重新激活
--
-- 【激活的四步】
--  1128  top_screen:SetFocus()        —— 先让屏幕自身获得焦点
--  1129  top_screen:OnBecomeActive()  —— 再恢复深层焦点 + 设 UIRoot
--  1131  serverpausewidget:SetOffset(0,0) —— 复位（与 985 配对）
--  1133-1135 OffsetServerPausedWidget 可选钩子
--  1137  TheInput:UpdateEntitiesUnderMouse() —— ★ 重做鼠标拾取
--  1138  self:Update(0)                        —— 立即刷新一帧
--
-- ★★ 1137 的意义：出栈后鼠标下的实体可能变了（下面的屏露出来了），
--   必须重做拾取才能让 925DoHoverFocusUpdate 拿到正确结果。
--   与 996 PushScreen 的 Update(0) 是同一个理由的两种做法
--   （PushScreen 没显式 UpdateEntitiesUnderMouse，靠 Update(0)→931 读取
--    **上一次**的拾取结果；⚠ 这意味着刚压栈的那一帧，
--    hover 焦点用的是**压栈前**的鼠标位置数据，可能有一帧的偏差）。
--────────────────────────────────────────────────────────────────
    local top_screen = self.screenstack[#self.screenstack]
	if top_screen and old_head ~= top_screen then
-- ★★ top_screen:SetFocus() —— widget.lua:659-688。
--   它会：
--   ① 若有 focus_forward（661-665）转发给目标控件
--   ② 置 self.focus = true + 调 OnGainFocus + ongainfocusfn
--   ③ 向父冒泡 self.parent:SetFocusFromChild(self)（678-680）
--   ④ **清除所有子控件的焦点**（683-685）
--   ⇒ ④ 是 1129 紧接着要恢复 last_focus 的原因：
--     先全清，再由 OnBecomeActive 精确恢复。
--     若不先清，GetDeepestFocus 会因为有多条焦点路径而歧义。
--   ★ 661-665 的 focus_forward 是一个「代理焦点」机制：
--     让 A 控件的焦点实际指向 B 控件。
--     ⚠ 但 widget.lua 中 grep 不到 focus_forward 的**设置**函数
--       （只有 661 行的读取）—— 由子类（widgets/ 里）直接赋值。
		top_screen:SetFocus()
-- ★★ top_screen:OnBecomeActive() —— 恢复 last_focus（screen.lua:35-42）。
--   ⚠⚠ 缺陷 G1 的完整链路在此闭合：
--     ① 1105-1107（或 1119）调 OnBecomeInactive → 记住 last_focus；
--     ② 1109 调 OnDestroy → Kill → 控件 inst 被 Remove；
--     ③ 某处复用了该屏幕实例并 Push；
--     ④ screen.lua:35 `if self.last_focus and self.last_focus.inst.entity:IsValid()`
--        —— ★ 官方基类**有**这层防护，所以官方屏幕不会中招；
--     ⑤ ⚠ 但模组自写的 Screen 若忘了这个检查（G1 的原话），
--        就会 `self.last_focus:SetFocus()` 一个已销毁控件。
--   ⇒ G1 的根因不在前端框架，而在「焦点记忆存对象引用 +
--     有效性校验下放到每个屏幕」。修复建议（bug-patterns.md G1）：
--     「把焦点记忆做成框架能力，在 Screen 基类的 OnBecomeActive
--     里统一处理并校验有效性，不要让每个屏幕自己写。」
--   ★ 结论：DST 的 Screen 基类（widgets/screen.lua:35）已经做到了；
--     但 bug-patterns.md 记录的是这个坑被踩过的历史。
		top_screen:OnBecomeActive()

        self.serverpausewidget:SetOffset(0, 0)

        if top_screen.OffsetServerPausedWidget then
            top_screen:OffsetServerPausedWidget(self.serverpausewidget)
        end

        TheInput:UpdateEntitiesUnderMouse()
		self:Update(0)

-- ⚠ 1140-1141 被注释掉的调试打印：
--   "--print ("POP!", self.screenstack[#self.screenstack]:GetDeepestFocus(), self.tracking_mouse)"
--   ⚠ 若取消注释，在栈空时会索引 nil（#0 = nil → [nil] 报 Index 错误）。
--     说明当时调试时没考虑空栈。这是被注释代码的通病。
		--print ("POP!", self.screenstack[#self.screenstack]:GetDeepestFocus(), self.tracking_mouse)
		--self:Fade(FADE_IN, 1)
	end
end

-- ★ ClearFocus —— 名字有误导性：它不是「清除焦点」，
--   而是「让栈顶屏重新收敛焦点」（screen:SetFocus 会清子节点焦点）。
--   ⇒ 效果上是把焦点退回屏幕根，等价于「焦点复位」。
function FrontEnd:ClearFocus()
	if #self.screenstack > 0 then
		self.screenstack[#self.screenstack]:SetFocus()
	end
end

-- ★★ GetActiveScreen —— 「当前界面」的唯一定义：栈顶。
-- ⚠ 缺陷 G1 的第一现场：
--   它**不校验**栈顶屏幕是否仍然有效（inst 是否被 Kill）。
--   虽然 PopScreen 会 OnDestroy（screen.lua:20 Kill），
--   但若某处直接 RemoveChild 而未 OnDestroy（或模组自己改了栈），
--   本函数会返回一个已销毁的屏幕实例。
--   ⚠ 全库 grep 核实：直接写 self.screenstack 的地方只有本文件
--     （43 初始化 / 951 / 961 / 982 / 1009 / 1108 / 1118），
--     所以官方路径是安全的；风险来自模组。
--   一切 GetActiveScreen 的消费者（401/481/555/592/611/1088/1198/1213）
--   都直接信任返回值。
function FrontEnd:GetActiveScreen()
    return #self.screenstack > 0 and self.screenstack[#self.screenstack] or nil
end

-- ★ GetOpenScreenOfType(name) —— 按类型名查找，**从栈顶往下**
--   （ipairs_reverse）。
--   ★ 为什么反序？因为「最新的那个」才是调用者想要的
--     （例如检查「有没有关着的制作屏」）。
-- ★ 1156 行 ipairs_reverse 是 Klei 自定义的倒序 ipairs，
--   Lua 标准库没有。参见 util.lua。
function FrontEnd:GetOpenScreenOfType(screenname)
	for _,v in ipairs_reverse(self.screenstack) do
		if v.name == screenname then
			return v
		end
	end

	return nil
end

-- GetScreenStackSize —— 简单的栈深度查询。
-- ★ 使用场景：判断「是不是在最外层界面」（例如 ESC 的行为）。
function FrontEnd:GetScreenStackSize()
    return #self.screenstack
end

-- ★★ ShowScreen —— 「清空再压栈」的组合操作。
--   1170 ClearScreens()（⚠ 走的是有缺陷的那条路径，见 1002 行分析）
--   1172 PushScreen(screen)
--   ⇒ 这是「场景切换」的主力 API（进游戏、回大厅、载入存档）。
--   ⚠ 因为它必经 ClearScreens（1003-1005 的 OnLoseFocus-only 路径），
--     所有用 ShowScreen 切换的场景都继承了 G4 的不完整性。
--   ★ 但因为每次都是全新屏幕实例（`if screen then`），
--     实际污染有限——除非调用方复用了同一实例。
function FrontEnd:ShowScreen(screen)
	self:ClearScreens()
	if screen then
		self:PushScreen(screen)
	end
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【SetForceProcessTextInput】—— 文本输入的所有权仲裁。
--
-- 【两个分支】
--  1177-1183 takeText and widget → 夺取输入权
--     ① 通知旧持有者退出（OnStopForceProcessTextInput）
--     ② 记录新持有者 self.textProcessorWidget
--     ③ 置 forceProcessText = true
--  1184-1190 否则（widget 为 nil 或就是当前持有者）→ 释放输入权
--
-- ★ 1184 的条件很讲究：`widget == nil or widget == self.textProcessorWidget`
--   ⇒ 传一个**第三方** widget 且它不是当前持有者时，**什么都不做**。
--   这防止了「A 想夺权时 B 也在夺权」的互相覆盖。
--   ⚠ 但也意味着：如果当前持有者的实体已销毁，调用方无法强制回收
--     输入权（因为 self.textProcessorWidget 不是 nil）。
--     ⇒ 只能靠 1176 的 `SetForceProcessTextInput(false)`（widget 省略）。
--★ 三个读者：
--   · 969 PushScreen / 1095 PopScreen —— 压出栈时无条件释放
--   · 422 OnControl 里 SetForceProcessTextInput(false, self.textProcessorWidget)
--     —— ★ 传了 widget（= 当前持有者）所以会走 1184 分支 ✓
--   · 1200/1215 OnRawKey / OnTextInput —— 检查 forceProcessText
--────────────────────────────────────────────────────────────────
function FrontEnd:SetForceProcessTextInput(takeText, widget)
	if takeText and widget then
		-- Tell whatever the previous widget was to quit it
-- ★ 1180 行 self.textProcessorWidget:OnStopForceProcessTextInput()
--   —— 通知控件「别再强制处理输入了」。
--   基类实现是空函数（widget.lua:120-121），
--   真正实现在 widgets/textedit.lua 等子类。
--   ★ 双重守卫（1177 takeText and widget + 1179 if textProcessorWidget）
--     保证不会对 nil 调用。
		if self.textProcessorWidget then
			self.textProcessorWidget:OnStopForceProcessTextInput()
		end
		self.textProcessorWidget = widget
		self.forceProcessText = true
	elseif widget == nil or widget == self.textProcessorWidget then
		if self.textProcessorWidget then
			self.textProcessorWidget:OnStopForceProcessTextInput()
		end
-- ★ self.forceProcessText = false —— 与 1183 的 true 配对。
--   ⚠ 潜在不一致：1183 置 textProcessorWidget + forceProcessText，
--     1188-1189 同时置 nil + false。两条路径都成对 ✓。
		self.textProcessorWidget = nil
		self.forceProcessText = false
	end
end

-- ★★ OnRawKey(key, down) —— **物理按键**的第二条通路。
--
-- 【与 OnControl 的分工】
--   OnControl（419）处理的是「语义控制码」（CONTROL_*）——
--     受键位绑定影响，适合按钮/菜单。
--   OnRawKey（本函数）处理的是「物理键码」（KEY_*）——
--     不经绑定，适合文本框（打字必须是物理字母键）。
--   ⇒ ★ 这是同一次物理按键在 UI 层的**两条并行路径**，
--     互不干扰（不同的事件处理器）。
--
-- 【注册来源】input.lua:187 self.onkey:HandleEvent("onkey", ...)
--   ← input.lua:764-766 OnInputKey（C++ 调用）
--   ← frontend.lua:220 AddKeyHandler
--────────────────────────────────────────────────────────────────
function FrontEnd:OnRawKey(key, down)
    if self:IsControlsDisabled() then
        return false
    end

    local screen = self:GetActiveScreen()
    if screen ~= nil then
-- ★★ 三路分发（优先级从高到低）：
--   ① 强制文本输入 → 直接给 textProcessorWidget（1201）
--   ② 否则 screen:OnRawKey（1202）—— 传的是**栈顶屏幕**
--   ③ 若屏幕没消费且开了作弊 → DoDebugKey（1203）
--   ⚠ ③ 的条件是 `not screen:OnRawKey(...)`：**屏幕不消费才给调试键**。
--     ⇒ 调试键的优先级低于 UI。合理（UI 在编辑时不希望被调试键打断）。
-- ⚠ 1202 行没有检查 screen.focus —— 但 widget.lua:105-110
--   OnRawKey 内部有 `if not self.focus then return false end`。
--   ⇒ 若栈顶屏没有焦点，什么都不会消费，调试键生效。
--   ⚠ 这是**正确**的：玩家没在任何 UI 焦点上时按 F1 应该能用调试键。
        if self.forceProcessText and self.textProcessorWidget ~= nil then
            self.textProcessorWidget:OnRawKey(key, down)
        elseif not screen:OnRawKey(key, down) and CHEATS_ENABLED then
            DoDebugKey(key, down)
        end
    end
end

-- ★ OnTextInput —— 文本输入的第二条通路（input.lua:195-197）。
-- ★ 与 OnRawKey 的结构几乎一致，但**没有** DoDebugText 兜底分支。
--   ⇒ 文本输入只能到强制输入的控件或屏幕，没有全局兜底。
-- ⚠ 这意味着：若一个 Screen 忘了实现 OnTextInput，
--   文本框就完全收不到字符——静默失败。
function FrontEnd:OnTextInput(text)
    if self:IsControlsDisabled() then
        return false
    end

-- ★ screen ~= nil 守卫 —— 栈空时忽略文本输入。
-- ⚠ 但 1215 的强制输入分支在栈空时**也不生效**，
--   即使 textProcessorWidget 存在——因为它被包在 screen ~= nil 里。
--   ⇒ ★ 潜在缺陷：栈空但有强制文本输入时，字符会被丢弃。
--     推理依据：1214 `if screen ~= nil then` 包住了 1215-1219 整段。
--     实践中栈空 + 文本输入的组合罕见（输入框总在某个屏里），
--     所以未被发现。但这是 1193 OnRawKey 同样有的问题
--     （1198-1205 同样被 screen ~= nil 包住）。
    local screen = self:GetActiveScreen()
    if screen ~= nil then
        if self.forceProcessText and self.textProcessorWidget ~= nil then
            self.textProcessorWidget:OnTextInput(text)
        else
            screen:OnTextInput(text)
        end
    end
end

-- ★★★ 「V2C」标记的含义：这是 mod「V2」移植到原版「C」（core）时
--   留下的注释标记。Klei 的 mod 工具（V2 = Klei Entertainment 内部
--   的 mod 分支标记）会在代码里留 #V2C 标注移植点。
--   ★ 本文件里的 V2C 标记共三处：
--     · 439-441 #FIX_LEFT_CLICK_UI_TRIGGERS_AUTO_ATTACK（G3 补丁）
--     · 473-479 调试渲染的文本框特判
--     · 1223-1224 本行的缩放排除说明
--   ⇒ 这是追溯「这段代码为什么长这样」的历史线索。
--V2C: -exclude resolution scaling
--     -useful when parents already have SCALEMODE_PROPORTIONAL
-- ════════════════════════════════════════════════════════════════
-- ★★★ 【GetProportionalHUDScale】—— 等比缩放（HUD 尺寸偏好）。
--
-- 【公式】easing.linear(size, .75, 1.1-.75, 10)
--   size ∈ [0,10] 来自 Profile:GetHUDSize()（玩家偏好）
--   size=0  → 0.75（最小）
--   size=10 → 1.1 （最大）
--   ⇒ 线性插值，斜率 = (1.1-0.75)/10 = 0.035。
--
-- ★ 原注释 "--V2C: -exclude resolution scaling" /
--   "--     -useful when parents already have SCALEMODE_PROPORTIONAL"
--   ⇒ ★★ 解释了**为什么有两个缩放函数**：
--     GetProportionalHUDScale（1225）—— 只看玩家偏好
--     GetHUDScale（1233）—— 额外叠加**分辨率缩放**
--   「parents already have SCALEMODE_PROPORTIONAL」是关键：
--     父控件已经设了 PROPORTIONAL 模式，会自动跟随分辨率缩放，
--     所以这个函数**故意不重复计算**，避免二次缩放。
--   ⇒ 使用约定：需要分辨率自适应用 GetHUDScale；
--     挂在已有 PROPORTIONAL 父级下的用 GetProportionalHUDScale。
--────────────────────────────────────────────────────────────────
function FrontEnd:GetProportionalHUDScale()
-- ★ Profile:GetHUDSize() —— 玩家在设置界面拖的 HUD 大小滑块（0..10）。
-- ★ 这是**少数把玩家偏好直接变成渲染参数**的地方，
--   与 1225/1233 的 min/max 共同定义映射曲线。
	local size = Profile:GetHUDSize()
	local min_scale = .75
	local max_scale = 1.1

-- ★ easing.linear(size, min_scale, max_scale - min_scale, 10) ——
--   第三个参数是**增量**（delta）不是终点值。
--   ⇒ linear(t, from, delta, duration) = from + delta * t/duration
--   验证：size=10 → 0.75 + 0.35*10/10 = 1.10 ✓
	return easing.linear(size, min_scale, max_scale - min_scale, 10)
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【GetHUDScale】—— 等比缩放 + 分辨率补偿。
--
-- 【分辨率缩放公式（1239-1245）】
--   res_scale_x = max(1, w / 1920)   —— 水平相对 1080p 的倍数
--   res_scale_y = max(1, h / 1200)   —— 垂直相对 720p 的倍数
--   res_scale   = min(x, y)          —— ★ 取较小者（保持比例）
--
-- ★★ 为什么是 1920×1200 这个基准？
--   1920×1200 是 DST 美术的**设计基准分辨率**（3:2 比例）。
--   ★ 3:2 而非 16:9 —— 因为游戏画面的视野比宽屏大
--     （竖屏时视野更高，这在 4:3 时代是设计目标）。
-- ⚠ 取 min 保证「宁可留黑边也不裁切」——这是安全的选择。
-- ⚠ max(1, ...) 保证「低于基准时不缩小」——
--   UI 元素不会因为窗口变小而变得不可点。
--   ⇒ 综合效果：UI 在小窗口下保持基准大小（大而可读），
--     在大窗口下等比放大。**永不为小**。
--────────────────────────────────────────────────────────────────
function FrontEnd:GetHUDScale()
    local size = Profile:GetHUDSize()
    local min_scale = .75
    local max_scale = 1.1

    --testing high res displays
    local w, h = TheSim:GetScreenSize()

-- ★★ 基准宽度 1920 —— 与 1200 成 3:2 比例。
--   ⚠ 硬编码的「设计基准」，无外部配置。
--   ⇒ 如果 Klei 未来改变美术基准，所有 UI 需要同步改这两个数。
--────────────────────────────────────────────────────────────────
    local res_scale_x = math.max(1, w / 1920)
    local res_scale_y = math.max(1, h / 1200)
    local res_scale = math.min(res_scale_x, res_scale_y)

    return easing.linear(size, min_scale, max_scale - min_scale, 10) * res_scale
end

-- ★★★ GetCraftingMenuScale —— 合成菜单的独立缩放。
--   min/max 区间不同（.6 ~ 1.15，比 HUD 的 .75~1.1 更宽），
--   因为合成菜单信息密度更高、用户常手动调小。
-- ★★ 1252-1255 分屏特判：min=1.0, max=1.92。
--   ⚠ 分屏时缩放**反而变大**？因为每个视口小，
--     需要放大才能在半屏里塞下同样的信息。
--   1.92 ≈ 2×(1/1.04)，接近「翻倍」的补偿。
--   ⇒ 与 369-372 分屏缩放 1.8 是同一思路，但数值不同
--     （因为不同面板的信息密度不同）。
--   ★ 这类「每个面板一套缩放曲线」是没有布局引擎的必然结果：
--     没有全局的 auto-fit，只能逐个手调。
function FrontEnd:GetCraftingMenuScale()
    local size = Profile:GetCraftingMenuSize()
    local min_scale = .6
    local max_scale = 1.15
	if IsSplitScreen() then
		min_scale = 1.0
		max_scale = 1.92
	end

    --testing high res displays
    local w, h = TheSim:GetScreenSize()

    local res_scale_x = math.max(1, w / 1920)
    local res_scale_y = math.max(1, h / 1200)
    local res_scale = math.min(res_scale_x, res_scale_y)

    return easing.linear(size, min_scale, max_scale - min_scale, 10) * res_scale
end

-- ★★ UpdateRepeatDelays —— 把玩家灵敏度偏好换算成三个连发基值。
-- 1269 行 `easing.linear(20-craft_sensitivity, .11, .4-.11, 20)`：
--   craft_sensitivity ∈ [0,20]，反转成 (20 - s) →
--   s=0（最低灵敏度）→ .11（最慢）
--   s=20（最高灵敏度）→ .4 （最快）
--   ⇒ ★★ 「灵敏度越高 = 连发越快」= 玩家把同一方向按得更少次。
--     这是把「输入采样频率」映射到「玩家偏好」的正确做法。
--   1270-1271：fast = base × 0.4，ninja = base × 0.2。
--   ⇒ 对应 701-707 的三档选择（见 _RefreshRepeatDelay）。
-- ★ 1273-1276 是物品栏的同一套公式（用inventory_repeat_* 前缀）。
--   ⚠ 注意变量名不对称：合成用 self.crafting_repeat_*（无下划线分隔），
--     物品栏用 self.inventory_repeat_*。纯粹是命名不统一。
function FrontEnd:UpdateRepeatDelays()
	local craft_sensitivity = Profile:GetCraftingMenuSensitivity()
	self.crafting_repeat_base = easing.linear(20-craft_sensitivity, .11, .4 - .11, 20)
	self.crafting_repeat_fast = self.crafting_repeat_base * 0.4
	self.crafting_repeat_ninja = self.crafting_repeat_base * 0.2

	local inv_sensitivity = Profile:GetInventorySensitivity()
	self.inventory_repeat_base = easing.linear(20-inv_sensitivity, .11, .4 - .11, 20)
	self.inventory_repeat_fast = self.inventory_repeat_base * 0.4
	self.inventory_repeat_ninja = self.inventory_repeat_base * 0.2

-- ⚠ 1278-1279 两行注释掉的调试打印。
--   它们揭示了变量命名的意图（crafting vs inventory 的对照）。
--   ★ 保留注释是好习惯——调试这类数值对齐时需要它们。
	--print("UpdateRepeatDelays crafting  ", craft_sensitivity, self.crafting_repeat_base, self.crafting_repeat_fast, self.crafting_repeat_ninja)
	--print("                   inventory ", inv_sensitivity, self.inventory_repeat_base, self.inventory_repeat_fast, self.inventory_repeat_ninja)
end

-- ★★★ OnMouseButton —— 鼠标点击的 UI 侧入口。
-- 【来自 input.lua:181，由 Input:OnMouseButton 调用（C++ → OnMouseButton）】
--
-- 1283-1285 门禁：淡出中 → false（⚠ 与 426 一致，与 404 不一致）
-- 1287      ★ tracking_mouse = true  —— 鼠标点击无条件夺回焦点控制权
-- 1289-1291 栈顶屏消费 → true
-- 1293      否则 → DoDebugMouse（仅作弊版）
--
-- ★★ 1287 是鼠标/手柄模式切换的**唯一无条件点**：
--   1301-1303 的 OnMouseMove 要求「x 和 y 都变」才恢复跟随，
--   而这里只要**点一下**就恢复。
--   ⇒ 手柄玩家切回鼠标的最短路径就是点一下。
--   ★ 为什么点击必然夺回？直觉上正确：玩家主动点了界面，
--     就说明他要回到鼠标交互。
function FrontEnd:OnMouseButton(button, down, x, y)
    if self:IsControlsDisabled() then
        return false
    end

    self.tracking_mouse = true

-- ★ screenstack[top]:OnMouseButton(button, down, x, y)
--   → widgets/screen.lua 未覆盖 → widget.lua:56-62。
--   ★ widget.lua:57 `if not self.focus then return false end` ——
--     焦点门禁。与 OnControl（127）完全同构。
--   ⚠ 注意 x, y 原样传递：**屏幕坐标**（不是控件局部坐标）。
--     控件若要判断「点在我身上」得自己用 UITransform 换算。
    if #self.screenstack > 0 and self.screenstack[#self.screenstack]:OnMouseButton(button, down, x, y) then
        return true
    end

-- ★★ `return CHEATS_ENABLED and DoDebugMouse(...)` ——
--   正式版 CHEATS_ENABLED 为 false ⇒ 返回 false ⇒ 输入透传到游戏层。
--   ⚠ 注意这里**没有**把结果再传给别的监听者——
--     但 input.lua:182 在TheFrontEnd 返回后还会广播 onmousebutton：
--       `self.onmousebutton:HandleEvent("onmousebutton", ...)`
--   ⇒ ★★ 鼠标点击**总是**会广播给游戏层，UI 的「消费」只影响
--     TheFrontEnd:OnMouseButton 的返回值，而 input.lua:181
--     **忽略了这个返回值**！
--   ⚠⚠ 潜在缺陷（对比 OnControl）：
--     input.lua:181 `TheFrontEnd:OnMouseButton(button, down, x,y)`
--     返回值被丢弃，182 行无条件广播。
--     ⇒ UI 吃掉了点击，游戏层的 onmousebutton 监听者**仍然会收到**。
--     ⚠ 推理依据：对比 input.lua:166 `not TheFrontEnd:OnControl(...)`
--       —— OnControl 的返回值被用于短路，OnMouseButton 的没有。
--     ⚠ 影响：实际游戏逻辑不走 onmousebutton 事件（走 CONTROL_*），
--       所以未暴露为玩家可见 bug。但这确实是**不对称**。
--     参见 input.lua:181 的缺陷标注。
    return CHEATS_ENABLED and DoDebugMouse(button, down, x, y)
end

-- ★★ OnMouseMove —— 只做两件事，不分发事件。
-- 1301  坐标**都**变 → tracking_mouse = true
-- 1305-1306 记录 lastx / lasty
-- ★★ 为什么不在这里派发 hover？
--   ⇒ 因为 hover 的计算在 input.lua:519-571 OnUpdate（每帧一次），
--     而 OnMouseMove 是**事件驱动**（可能一帧多次）。
--   ⇒ 分离「输入采样」（高频）与「命中计算」（每帧一次）
--     是性能上的正确做法。
function FrontEnd:OnMouseMove(x, y)
    if self:IsControlsDisabled() then
        return false
    end

-- ⚠⚠ `self.lastx ~= x and self.lasty ~= y` —— 「与」不是「或」。
--   ★ 后果：沿单轴滑动（水平或垂直）**不会**恢复鼠标跟随。
--   ★ 这与 1305-1306 记录的 lastx/lasty 的用途矛盾——
--     记录了**两个**坐标，判定却要求**两个都变**。
--   ⇒ 强烈怀疑这是笔误（应该是 or）。
--     推理依据：
--     ① 若意图是「鼠标移动就恢复跟随」，应为 or；
--     ② 若意图是「鼠标**斜向**移动才恢复」，那 lastx/lasty 只需一个；
--     ③ 实际玩家行为：单轴滑动在鼠标操作中极常见（沿列表下滑）。
--   ⚠ 但也可能是有意的：避免手柄导航时鼠标被**手抖**打断。
--     区分不了 ⇒ 标注为「疑似缺陷/意图不明」，不改代码。
--   ⇒ 实际后果被 1287 的「点击无条件夺回」掩盖了，
--     所以这个条件几乎不影响体验。
    if self.lastx ~= nil and self.lasty ~= nil and self.lastx ~= x and self.lasty ~= y then
        self.tracking_mouse = true
    end

    self.lastx = x
	self.lasty = y
end

-- ★★★ 【OnSaveLoadError】—— 全文件最长、最绕的一个函数。
--
-- 【它做什么】
--   存储系统报告一次存档/读档/删除失败后，根据 status 弹出不同的
--   对话框栈，让玩家选择重试/覆盖/取消。
--
-- ★★ 【为什么它是 G4 的教科书案例】
--   这个函数在 OnSaveLoadError 里管理一个**最多三层的弹窗栈**
--   （见 1370-1392 与 1399-1406），且**用硬编码的注释标注层次**：
--     1376 -- confirmation message box
--     1377 -- saveload error message box
--     1361/1367/1412 -- saveload error message box
--   ⇒ 每次 PopScreen 都用 `-- xxx` 注释标明弹的是哪一层。
--   ★ 这是**用注释替代显式栈管理**的做法：既不优雅也不安全。
--     若某个回调少调一次 PopScreen，后续所有弹窗都会错层。
--   ⚠ 推理依据：1372-1378 的 disable_autosave 连续 PopScreen 两次，
--     每次只能靠注释确认层次——说明作者自己对层次关系没有信心。
--   ⇒ 正确做法：把这些局部弹窗也走一个显式的栈对象，
--     或至少在 PopScreen 时校验「弹的是不是当前活动屏」。
--────────────────────────────────────────────────────────────────
function FrontEnd:OnSaveLoadError(operation, filename, status)
-- ★ 无论走哪条路径，第一步都是 HideSavingIndicator ——
--   「出错时先把存档指示器收掉」，否则指示器会一直转。
--   1310 原注释："-- in case it's still being shown for some reason"。
    self:HideSavingIndicator() -- in case it's still being shown for some reason

-- ★★ retry —— 三个分支（1314/1341/1345）共用的「重试」回调。
-- 1313 第一步也是 PopScreen（"saveload error message box"），
--   注释再次确认层次。
-- ⚠ 1313 的 PopScreen 无参 → 走 1114 分支（弹栈顶）→ 对称 ✓。
--   ⇒ 这是本文件中 PopScreen 使用**正确**的写法，与 G4 的 1105-1107 分支形成对比。
    local function retry()
        self:PopScreen() -- saveload error message box
        if operation == SAVELOAD.OPERATION.LOAD then

-- ⚠ 1316-1318 一个空回调 OnSaveGameIndexLoaded ——
--   整个 OnSaveGameIndexLoaded 函数体只有一行注释掉的 print。
--   ⚠ 空回调是典型的「预留钩子」，但空函数本身无成本，
--     真正的问题是它让ShardGameIndex:Load 的回调链多了一层无意义间接。
            local function OnSaveGameIndexLoaded(success)
                --print("OnSaveGameIndexLoaded", success)
            end

-- ★★ 三级回调链 OnProfileLoaded → SaveGameIndex:Load →
--   ShardSaveGameIndex:Load → ShardGameIndex:Load。
-- ★ 每一个都在判success 后才继续下一层（1322/1334）。
--   ⇒ 异步加载的链式失败处理，每层只做「成功就继续」。
--   ⚠ 但**失败时什么都不做**——没有错误弹窗、没有用户提示。
--     推理依据：1322 `if success then` 没有 else 分支。
--     ⇒ 读档失败重试时，如果 Morgue 或 Profile 加载失败，
--       玩家会看到一个「什么都没发生」的界面。
--   ⇒ 这是一个**已收录风格问题**（静默失败）。
            local function OnProfileLoaded(success)
                --print("OnProfileLoaded", success)
                if success then

                    SaveGameIndex:Load(function()
                        ShardSaveGameIndex:Load(function()
                            ShardGameIndex:Load(OnSaveGameIndexLoaded)
                        end)
                    end)
                end
            end

-- Morgue 加载 —— 「死亡记录」存储。加载失败同样静默（1334 无 else）。
            local function OnMorgueLoaded(success)
                --print("OnMorgueloaded", success)
                if success then
                    Profile:Load(OnProfileLoaded)
                end
            end

            Morgue:Load(OnMorgueLoaded)

-- ★ 保存分支：1343 ShowSavingIndicator + 1344 RetryOperation。
--   1342 原注释 "-- the system service knows which files are not saved
--   and will try to resave any files from the cache"。
--   ⇒ 重试期间必须显示指示器，因为可能耗时较久。
        elseif operation == SAVELOAD.OPERATION.SAVE then
            -- the system service knows which files are not saved and will try to save them
            self:ShowSavingIndicator()
            TheSystemService:RetryOperation(operation, filename)
        elseif operation == SAVELOAD.OPERATION.DELETE then
            TheSystemService:RetryOperation(operation, filename)
        end
    end

-- ════════════════════════════════════════════════════════════════
-- 【分支一：status == SAVELOAD.STATUS.DAMAGED】1350-1406
--   存档**损坏**——提供三选项：重试 / 覆盖 / 取消。
--────────────────────────────────────────────────────────────────
    if status == SAVELOAD.STATUS.DAMAGED then
        print("OnSaveLoadError", "Damaged save data popup")
-- ★ overwrite —— 「覆盖损坏存档」。
-- 1358 原注释 "-- OverwriteStorage will also try to resave any files
-- found in the cache"。
-- ★★ 1360 先 OverwriteStorage，1361 才 PopScreen：
--   顺序是「启动操作 → 关对话框」。「先操作后关窗」
--   保证操作失败时对话框还在。这是**正确的错误处理顺序**。
-- ⚠ 但 1353-1356 的 on_overwritten(success) 里无条件调
--   `TheSystemService:EnableAutosave(success)` ——
--   ★★ 这是**把 success 布尔值直接当成 enable 标志**。
--   推理：EnableAutosave 的参数通常是 boolean 或「延迟开关的值」。
--   ⚠ 若 success 为 false，EnableAutosave(false) 恰好合理；
--     若为 true，EnableAutosave(true) 也合理。
--   ⇒ 实际语义是「操作成功就恢复自动存档配置，失败就禁用」。
--     但这是把「成功标志」复用为「配置值」的**语义混用**，
--     可读性差且极易被误改。标注为「语义混用」而非缺陷。
        local function overwrite()
            local function on_overwritten(success)
                self:HideSavingIndicator()
                TheSystemService:EnableAutosave(success)
            end

            -- OverwriteStorage will also try to resave any files found in the cache
            self:ShowSavingIndicator()
            TheSystemService:OverwriteStorage(on_overwritten)
            self:PopScreen() -- saveload error message box
        end

-- cancel —— 「原样保留不处理」。
-- ★ 1365 EnableStorage(IsAutosaveEnabled()) —— 恢复存储开关到当前自动存档设置。
-- ★ 1366 ClearLastOperation —— 清掉 TheSystemService 里挂起的失败操作，
--   否则下次启动还会重试同一个失败操作。
        local function cancel()
            TheSystemService:EnableStorage(TheSystemService:IsAutosaveEnabled())
            TheSystemService:ClearLastOperation()
            self:PopScreen() -- saveload error message box
        end

-- ════════════════════════════════════════════════════════════════
-- ★★ confirm_autosave_disable —— **第二层弹窗**。
-- 【触发条件】1394-1397：取消操作时若自动存档开着，
--   就先问「要不要顺便关掉自动存档」。
-- 【为什么要问】
--   若存档已损坏而自动存档继续开着，下次启动会再次失败并弹窗。
--   ⇒ 关掉自动存档是一个**需要用户同意的副作用**。
-- ★ 这是本函数里唯一的「取消操作会产生副作用」的分支，
--   所以需要二次确认。★ 其余分支（重试/覆盖）都不问。
--   ⇒ UI 设计的正确顺序：副作用越重，确认层级越深。
--────────────────────────────────────────────────────────────────
        local function confirm_autosave_disable()

-- ★★ 1375-1377 **连续两次 PopScreen**，注释标明层次：
--     1376 -- confirmation message box     （刚弹出的确认框）
--     1377 -- saveload error message box   （下面那层损坏提示）
-- ⚠⚠ 这是缺陷 G4 最直观的现场：
--   弹出第二层对话框（1391 行 PushScreen(confirmation)）时，
--   PushScreen 的 977-979 会调**第一层**的 OnBecomeInactive →
--   记住第一层的 last_focus ✓（对称）。
--   但如果第二层的取消按钮走 dont_disable（1380-1382），
--   只会 Pop **一层** ✓ 正确。
--   ⇒ 真正的风险在别处：**若某个分支的 PopScreen 数量写错**，
--     栈的平衡就断了，且**没有任何断言能发现**。
--   ⚠ 推理依据：全文 grep，PopScreen 在本函数里被调用 5 次（1361/1367/
--     1376/1377/1381/1412 共 6 处），每次层数都靠注释判断。
--     没有一处有「校验当前活动屏是否是我要弹的那层」的断言。
--────────────────────────────────────────────────────────────────
            local function disable_autosave()
                TheSystemService:EnableStorage(false)
                TheSystemService:EnableAutosave(false)
                TheSystemService:ClearLastOperation()
                self:PopScreen() -- confirmation message box
                self:PopScreen() -- saveload error message box
            end

-- dont_disable —— 「不关自动存档」分支。只弹一层（1381）。
-- ★ 与 1376-1377 的双层弹形成对照，说明作者知道层次。
            local function dont_disable()
                self:PopScreen() -- confirmation message box
            end

-- ★★ 第二层对话框的构造：PopupDialogScreen（旧版，非 redux）。
-- ★ 1390 行 `confirmation.title:SetPosition(0, 40, 0)` ——
--   ★★ 这是「锚点定位」的一个手工调整样本：
--     对话框的标题控件默认在顶部某处，这里手工把它挪到 y=40。
--     为什么不是让 PopupDialogScreen 支持参数？因为直接改更省事。
--   ⇒ 这正是「没有布局引擎」的代价：每个调用点都可能手工微调。
            local confirmation = PopupDialogScreen(STRINGS.UI.SAVELOAD.DISABLE_AUTOSAVE, "",
                {
                    {text=STRINGS.UI.SAVELOAD.YES, cb = disable_autosave},
                    {text=STRINGS.UI.SAVELOAD.NO, cb = dont_disable},
                }
            )
            confirmation.title:SetPosition(0, 40, 0)
            self:PushScreen(confirmation)
        end

-- ★★ cancel_cb 的动态选择（1394-1397）：
--   若自动存档开着 → cancel_cb = confirm_autosave_disable（会再弹一层）
--   否则            → cancel_cb = cancel（直接弹）
--   ⇒ 「取消」这个按钮在两种情况下的行为**不同**。
--   ⚠ 从用户视角这是**不可见的**（按钮文字一样），
--     但行为差异很大（多一次确认）。
--     ⚠ 推理依据：1386-1388 的按钮表是静态的，
--       只有第三个按钮的 cb 被动态替换。
--     ⇒ 这是可接受的渐进式确认，但属于 UI 设计上的隐患。
        local cancel_cb = cancel
        if TheSystemService:IsAutosaveEnabled() then
            cancel_cb = confirm_autosave_disable
        end

        local popup = PopupDialogScreen(STRINGS.UI.SAVELOAD.DATA_DAMAGED, "",
            {
                {text=STRINGS.UI.SAVELOAD.RETRY, cb = retry},
                {text=STRINGS.UI.SAVELOAD.OVERWRITE, cb = overwrite},
                {text=STRINGS.UI.SAVELOAD.CANCEL, cb = cancel_cb},
            }
        )
-- ★ 第一层对话框 Push（1399-1405 构造，1406 压栈）。
-- ⚠ 注意 1406 在 1391（第二层 Push）**之后**？不——
--   执行顺序是 1391 PushScreen(confirmation) 在 confirm_autosave_disable
--   **被调用时**才执行，而 confirm_autosave_disable 是 1396 赋给 cancel_cb、
--   在玩家点「取消」时才触发。
--   ⇒ 实际时序：1406 先压第一层 → 玩家点取消 → 1391 压第二层。
--     代码的**书写顺序**（1391 在前，1406 在后）与**执行顺序**相反。
--   ⚠ 这是本函数最容易读错的地方，务必注意。
        self:PushScreen(popup)

-- ════════════════════════════════════════════════════════════════
-- 【分支二：status == SAVELOAD.STATUS.FAILED】1408-1431
--   存档操作**失败**（非损坏）——只给两个选项：重试 / 取消。
-- ★ 为什么不需要覆盖？因为文件没坏，只是这次操作没成功，
--   重试或放弃即可，不涉及数据销毁。
--   ⇒ 对比分支一的三选项，设计差异源于**破坏性**。
--────────────────────────────────────────────────────────────────
    elseif status == SAVELOAD.STATUS.FAILED then

        local function cancel()
            TheSystemService:ClearLastOperation()
            self:PopScreen() -- saveload error message box
        end

-- ★ text 的三分支赋值（1415-1422）—— 没有 else 分支。
-- ⚠ 若 operation 是未知值，text 为 nil → 1424 的PopupDialogScreen
--   第一个参数为 nil。是否崩溃取决于 PopupDialogScreen 的实现。
--   ⇒ 理论上的空指针风险，实践中 operation 只取三个枚举值。
        local text
        if operation == SAVELOAD.OPERATION.LOAD then
            text = STRINGS.UI.SAVELOAD.LOAD_FAILED
        elseif operation == SAVELOAD.OPERATION.SAVE then
            text = STRINGS.UI.SAVELOAD.SAVE_FAILED
        elseif operation == SAVELOAD.OPERATION.DELETE then
            text = STRINGS.UI.SAVELOAD.DELETE_FAILED
        end

-- 第二层也是最后一个对话框。1408 分支只需**两层**（错误框 → 确认框），
--   不像分支一需要三层。
-- ⚠ 注意 1430 PushScreen 与 1406 相同——说明两层结构在两个分支里
--   复用了同一套代码路径（只有第三个按钮的 cb 不同）。
        local popup = PopupDialogScreen(text, "",
            {
                {text=STRINGS.UI.SAVELOAD.RETRY, cb = retry},
                {text=STRINGS.UI.SAVELOAD.CANCEL, cb = cancel},
            }
        )
        self:PushScreen(popup)
    end
end

-- ★★ 全局函数 OnSaveLoadError —— C++ 侧调用的入口。
--   与本文件末尾其它全局（1460 等）同构：
--     C++ → 全局函数 → TheFrontEnd:方法。
-- ★ 这是 frontend.lua 的**双重身份**：
--   既是 FrontEnd 类的方法集合，也是全局 C 回调的宿主。
--   对比 input.lua:742-778 那一整段全局函数（OnPosition/OnControl 等）。
--   ⇒ ★ 两个文件都采用「类 + 全局转发函数」的组合，
--     因为 Lua 的全局函数表就是 C 侧的绑定面。
function OnSaveLoadError(operation, filename, status)
    TheFrontEnd:OnSaveLoadError(operation, filename, status)
end

-- ★★ IsScreenInStack —— 「这个屏还在栈里吗」。
-- ⚠ 1429 行同样有这个判空风格：1439-1444 用 pairs 而非 ipairs，
--   因为**不关心顺序**，只关心存在性。
--   ★ 与 1155 GetOpenScreenOfType 的 ipairs_reverse 形成对照：
--     「查存在性」用 pairs（无序更快），「查最新」用 ipairs_reverse。
--   ⇒ 「选对遍历方式」是这类查询的基本功。
function FrontEnd:IsScreenInStack(screen)
    for _,screen_in_stack in pairs(self.screenstack) do
        if screen_in_stack == screen then
            return true
        end
    end
    return false
end

-- SetOfflineMode / GetIsOfflineMode —— 离线模式标志的存取。
-- ★ 注意字段名 self.offline 与方法名不一致（少了 Is）。
--   小瑕疵。
function FrontEnd:SetOfflineMode(isOffline)
    self.offline = isOffline
end

function FrontEnd:GetIsOfflineMode()
    return self.offline
end

-- ════════════════════════════════════════════════════════════════
-- 段 18/8：imgui 调试面板（1455-1629）
-- ★ 这整段在零售版**全是死代码**（CAN_USE_DBUI 为 false）。
--   保留它是因为 mod 开发版会开启。
--   ★ 但也意味着：这 175 行代码缺少零售版的实机验证。
--────────────────────────────────────────────────────────────────
function FrontEnd:ToggleImgui(node)
-- ★★ 每个调试函数开头都是 `if not CAN_USE_DBUI then return end`。
--   ⇒ 这是「编译期条件」的运行时模拟。
--   ★ 为什么不在文件顶部就整体包一层？
--     因为 Lua 没有条件编译，只能逐函数守卫。
--     ⇒ 代价：1456/1498/1511/1524/1581/1624 六处重复守卫。
	if not CAN_USE_DBUI then
		return
	end

-- ★ ToggleImgui 的主逻辑（1460-1493）。三个分支：
--   ① imgui 已启用 → 切换 self.imgui_enabled（开关语义）
--   ② 首次开启且无面板无节点 → 建一个 DebugEntity 面板（1467-1469）
--   ③ 线程渲染开着 → **弹窗告知必须关掉**（1471-1492）
    if TheRawImgui:IsImguiEnabled() then
        if self.imgui_enabled then
            self.imgui_enabled = false
        else
            self.imgui_enabled = true
            self.imgui.ActivateImgui()

-- ★ "#self.debug_panels == 0 and not node" —— 「一个面板都没开时
--   默认建一个实体检查面板」。这是调试工具的合理默认值。
            if #self.debug_panels == 0 and not node then
                self:CreateDebugPanel( DebugEntity() )
            end
        end
-- ⚠⚠ 1472 行的 print 揭示了一个**部署陷阱**：
--   "IsImguiEnabled is disabled due to threaded renderer being enabled"
-- ★★ 【线程渲染与调试 UI 的冲突】—— 一个重要的架构约束：
--   线程渲染把渲染工作放到工作线程，此时主线程的立即模式
--   绘制（imgui）无法正确同步（imgui 的命令缓冲是单线程的）。
--   ⇒ 所以开发版必须关线程渲染才能用调试面板。
--   ⚠ 推理依据：1474-1490 弹出的对话框内容明确写着
--     "You are trying to use a debug panel but have threaded renderer ON,
--      please turn it OFF."
--   ★ 这类「渲染管线特性与工具链互斥」的限制，是难以从代码
--     本身看出来的，只能通过这种「运行时才发现」的弹窗暴露。
    else
        print("IsImguiEnabled is disabled due to threaded renderer being enabled")
        if self.ignoredebugpanelwarning == nil then
-- ★★ 1474-1490：阻断性对话框。两个选项都是「终止型」：
--   · Ignore for now → 记下警告已显示（1478），PopScreen
--   · Turn OFF and Quit → 写 Profile + RequestShutdown
--   ★ 为什么要「Quit」而不是热重载？
--     因为线程渲染是**启动时**决定的设置，中途不能改。
--   ⇒ 这是一个「设置变更需要重启游戏」的典型场景。
            local dialogue = PopupDialogScreenRedux("[DEV] Bad threaded renderer setting!", "You are trying to use a debug panel but have threaded renderer ON, please turn it OFF.", {
                {
                    text = "Ignore for now",
                    cb = function()
-- ★★ self.ignoredebugpanelwarning = true —— 「不再提示」。
--   ⇒ 典型的「一次性提示」模式（teach the user once）。
--   ★ 对照本文件其他布尔标志（tracking_mouse 等）是运行时状态，
--     这个是**用户偏好性质**的。但它**不存 Profile**（重启后重置）。
--     ⚠ 轻微缺陷：玩家每次重启游戏都会被这个弹窗打扰一次。
                        self.ignoredebugpanelwarning = true
                        TheFrontEnd:PopScreen()
                    end
                },{
                    text = "Turn OFF and Quit",
                    cb = function()
                        Profile:SetThreadedRenderEnabled(false)
                        Profile:Save(function()
                            RequestShutdown()
                        end)
                    end
                },
            }, nil, "big")
            self:PushScreen(dialogue)
        end
    end
end


-- ★ IsDebugPanelOpen(nodename) —— 按节点**名**查是否已开。
-- ★ 1529 行 `node.type = node` 是「记住原始类」，让 1543 FindOpenDebugPanel
--   能按类查（panel.type:is_a(node)）。
--   ⇒ ★ 这是「运行时保存类型信息」以便后续 is_a 判定的常见技巧，
--     因为实例被创建后类型信息会丢失（除非保留构造引用）。
function FrontEnd:IsDebugPanelOpen( nodename )
	if not CAN_USE_DBUI then
		return false
	end

    for i, panel in ipairs(self.debug_panels) do
        if panel:GetNode().NodeName == nodename then
            return true
        end
    end
    return false
end

-- ★★ CloseDebugPanel —— ⚠ 遍历中 table.remove 的经典隐患。
-- 1515  for i, panel in ipairs(self.debug_panels) do
--  1517      panel:OnClose()
--  1518      table.remove( self.debug_panels, i )
--  ⚠ 没有 break 或递减 i —— 移除第 i 个后，后续元素左移，
--     循环的 i++ 会跳过下一个。
--   ⇒ 结果：**相邻的多个同类面板会被漏关一个**。
--   ⚠ 推理依据：table.remove(table, i) 后原来第 i+1 个变成第 i 个，
--     但 for 循环下一次访问 i+1（即原来的 i+2）。
--   ⚠ 实际影响：需要连续关闭两个同类面板时漏关一个。
--     属于「遍历中删除」的标准 bug，但危害小（面板不致命）。
--   ⇒ 对比 1592-1611 的 OnRenderImGui 用了正确的 while + i 不自增模式。
--     ★ 同一个文件里两种写法，说明这是疏漏而非约定。
function FrontEnd:CloseDebugPanel( nodename )
	if not CAN_USE_DBUI then
		return
	end

    for i, panel in ipairs(self.debug_panels) do
        if panel:GetNode().NodeName == nodename then
            panel:OnClose()
            table.remove( self.debug_panels, i )
        end
    end
end

-- CreateDebugPanel —— 三个职责：建面板 / 按需开 imgui / 登记。
-- ★ 1530-1532：`if not self.imgui_enabled then self:ToggleImgui(node) end` ——
--   「要开面板就先把 imgui 打开」的隐式依赖。
-- ⚠ 但 ToggleImgui 1460 在 imgui 未启用时会走 1471 分支弹窗阻断，
--   也就是说 CreateDebugPanel 的调用结果可能是「什么都没发生，
--   反而弹了个对话框」。副作用方向反了。
function FrontEnd:CreateDebugPanel( node )
	if not CAN_USE_DBUI then
		return
	end

	local node = DebugPanel2( node )
    node.type = node
	if not self.imgui_enabled then
		self:ToggleImgui(node)
	end

	table.insert( self.debug_panels, node )
    -- If you want to stuff values into the PrefabEditor, it's the input node
	-- that you want to modify, not this panel. If you want to modify windowing
	-- info, then this panel is where it's at.
	return node
end

-- Takes the same argument as CreateDebugPanel -- the class of a debug panel
-- node.
-- ★ FindOpenDebugPanel(node) —— 按**类**查面板。
-- ★ 依赖 1529 的 node.type = node 保存的类型引用。
-- ★ 1554 GetNumberOpenDebugPanel 是同一个 is_a 判定的计数版。
-- ⇒ 这一对（查找 + 计数）是「已打开面板」的唯一查询入口。
function FrontEnd:FindOpenDebugPanel( node )
	for _, panel in ipairs(self.debug_panels) do
		if panel.type:is_a(node) then
			return panel
		end
	end
end

function FrontEnd:GetNumberOpenDebugPanels( node )
	local numOpenPanels = 0
	for _, panel in ipairs(self.debug_panels) do
		if panel.type:is_a(node) then
			numOpenPanels = numOpenPanels + 1
		end
	end

	return numOpenPanels
end

-- ★★ GetSelectedDebugPanel —— 按 isSelected **字段**找。
-- ⚠ 与 1564 的 ipairs 遍历中可能一个都不满足，返回 nil。
--   调用方需判空。
function FrontEnd:GetSelectedDebugPanel()

	for _, panel in ipairs(self.debug_panels) do
		if panel.isSelected then
			return panel
		end
	end

	return nil
end

-- ★★ SetImguiFontSize —— **唯一会写 Profile 的调试函数**。
-- 1576 `Profile.dirty = true` —— 手动标脏。
--   ⚠ 1575-1577 直接 `Profile:Save()` 异步保存。
--   ★ 为什么字体大小要持久化？因为调试面板在小屏上太小看不清。
--   ⚠ 写入键名硬编码 "imgui_font_size"（244 行读取同一字符串）
--     —— 字符串字面量在两处重复，没有共享常量。
function FrontEnd:SetImguiFontSize( font_size )
	self.imgui_font_size = font_size
    Profile:SetValue("imgui_font_size", self.imgui_font_size)
    Profile.dirty = true
    Profile:Save()
end

-- ════════════════════════════════════════════════════════════════
-- ★★ 【OnRenderImGui】—— 调试面板的渲染循环。
--【防重入锁】1585 `if not self.imgui_is_running and self.imgui_enabled`
--  1590 `self.imgui_is_running = true`
--  1617 `self.imgui_is_running = false`
-- ★★ 1589 的原注释解释了原因：
--   "--jcheng: this is to stop imgui from re-running while inside imgui,
--      for example if you do a sim step"
--   ⇒ imgui 的渲染是「即构即弃」的（immediate mode），
--     如果在渲染期间触发一次模拟步进，就会重入。
--   ⇒ 典型的**递归进入保护**。
--────────────────────────────────────────────────────────────────
function FrontEnd:OnRenderImGui(dt)
	if not CAN_USE_DBUI then
		return
	end

	if not self.imgui_is_running and self.imgui_enabled then

-- ★★ i = 1 的 while 循环 —— 与 1515 的 for 循环对比：
--   这里是**正确**的遍历-删除模式：
--     1603  table.remove( self.debug_panels, i )   ← 删除第 i 个
--     1604  if not ok then break end              ← 出错才退出
--     1608  else i = i + 1 end                     ← 否则 i 才前进
--   ⇒ 删除后不前进 i，下一轮访问的就是被移上来的那个元素。
--   ★ 同一个文件里的 1515-1520 用了错误写法。对照阅读价值很高。
		local i = 1

		--jcheng: this is to stop imgui from re-running while inside imgui, for example if you do a sim step
		self.imgui_is_running = true

		while i <= #self.debug_panels do
			local panel = self.debug_panels[i]

-- ★★ xpcall(函数, generic_error) —— 每个面板独立捕获异常。
-- ★ 为什么不用 pcall？generic_error 是 Klei 的统一错误格式化器，
--   会输出完整堆栈（stacktrace.lua）。
-- 1604-1607 出错时：print 结果 → break（**不再遍历后续面板**）。
--   ⚠ 推理依据：出错后继续渲染其它面板可能在错误状态下二次出错。
--     break 是保守选择，但也意味着一个坏面板会阻塞其它面板的更新。
			local ok, result = xpcall( function() return panel:RenderPanel(self.imgui, i, dt) end, generic_error )
			if ok and panel:WantsToClose() then
				result = false
			end

			if not ok or not result then
				print("closing panel "..tostring(panel))
				panel:OnClose()
				table.remove( self.debug_panels, i )
				if not ok then
					print( tostring(result) )
					break
				end
			else
				i = i + 1
			end
		end

-- 面板清空时自动关闭 imgui（1613-1615）。
-- ★ 避免「imgui 开着但没有面板」的空转开销。
		if #self.debug_panels == 0 then
			self.imgui_enabled = false
		end

		self.imgui_is_running = false
	end

-- ⚠ 1620 `self.debugMenu:Render(dt)` 在 if 块**之外** ——
--   即使 imgui 没启用也会调用。
--   ⚠ 若 CAN_USE_DBUI 为 true 但 self.debugMenu 为 nil（246 行创建），
--     会崩。实际两者总是同时为真（241 行同一个 if 里创建）。
--   ⇒ 依赖了「两个字段总是一起创建」这个隐式不变量。
	self.debugMenu:Render(dt)
end

-- ════════════════════════════════════════════════════════════════
-- 段 20/8：★★ 全局错误锁与文件尾（1631-1655）
-- ════════════════════════════════════════════════════════════════
function FrontEnd:IsImGuiWindowFocused(flags)
	if not CAN_USE_DBUI then
		return false
	end

    return self.imgui ~= nil and imgui ~= nil and self.imgui:IsWindowFocused(flags or imgui.FocusedFlags.AnyWindow)
end

-- ★★ SetServerPauseText —— 「服务器暂停」提示的文本更新。
--   这是**推模式**（外部主动调），与 694 的轮询模式相反。
--   ⇒ ★ 对照结论：同一个文件里两种 UI 更新风格并存。
--     轮询（控制台日志、存档指示器）vs 推送（暂停提示）。
--   ⇒ 推模式更好，但需要外部知道「何时该更新」。
function FrontEnd:SetServerPauseText(source)
    self.serverpausewidget:UpdateText(source)
end

-- ════════════════════════════════════════════════════════════════
-- ★★★ 【全局错误锁的三段式】1635-1655 —— 一个精巧的设计。
--
-- 【三个函数】
--  1635 SetGlobalErrorWidget(...)  —— **只缓存**，不弹窗
--  1641 ResetGlobalErrorWidget()   —— 清缓存
--  1645 CheckCachedError()        —— 真正弹窗并上锁
--
-- 【为什么不能立刻弹窗】
-- 1651-1652 原注释给出了答案：
--   "-- Pushing screens is not allowed after creating the error widget, so
--      assign it last."
--   ⇒ 「创建错误弹窗之后不允许再 PushScreen，所以全局标记必须最后赋值。」
-- ⇒ 这是一个**三阶段错误处理**：
--   ① 错误发生 →缓存参数（此时还在正常的 Push 上下文里）
--   ② 错误现场清理完毕 → CheckCachedError 弹窗 + 上锁
--   ③ 全局标记一旦为真，IsControlsDisabled(400) 永久冻结输入
--
-- ★★ 设计精髓：**先离开错误现场，再展示错误。**
--   若在错误现场直接 PushScreen，那个 PushScreen 本身可能失败，
--   导致递归错误。分阶段保证「弹窗这一步不再出错」。
--   ⇒ 这与 1312-1314 的存档错误处理是同一思想：
--     「先完成操作，再关对话框」。
--────────────────────────────────────────────────────────────────
function FrontEnd:SetGlobalErrorWidget(...)
-- ★★ `if not self.cachedError then self.cachedError = {...} end` ——
--   ★ 只缓存**第一次**错误！
--   ⇒ 后续错误不会覆盖。
--   理由：第一个错误往往是**根因**，后续都是级联。
--   ⇒ ★ 这是错误处理的重要经验：显示第一个，不是最后一个。
-- ⚠ 但参数被 `{...}` 打包成表，丢失了参数个数信息。
--   1647 用 `unpack(self.cachedError)` 还原 ✓ 正确。
	if not self.cachedError then
		self.cachedError = {...}
	end
end

-- ★★ ResetGlobalErrorWidget —— ⚠ 命名误导（文件头已提）。
--   它清的是**缓存**（self.cachedError = nil），
--   **不是**全局锁（global_error_widget）。
-- ⚠ 而 global_error_widget 一旦被 1653 赋值，
--   全文 grep 显示**没有任何地方把它置回 nil**。
--   ⇒ 一旦发生过一次致命错误，整个前端的输入就永久冻结，
--     只能重启游戏。
--   ⚠ 这是**有意的**（原文 974行："--if global_error_widget ~= nil
--     then return end" 被注释掉时的替代方案），
--     但 ResetGlobalErrorWidget 这个名字会让人误以为能解锁。
--   ⇒ 标注为「命名误导 + 潜在困惑」，不是缺陷。
function FrontEnd:ResetGlobalErrorWidget()
	self.cachedError = nil
end

-- ★ CheckCachedError —— 「消费」缓存并上锁。
-- ★ 1646 的条件 `if self.cachedError and not global_error_widget`：
--   双重门禁——有缓存**且**尚未上锁。
--   ⇒ 保证 CheckCachedError 可以被反复调用（幂等）。
--   ★ 这是「缓存 + 幂等消费」的标准模式。
function FrontEnd:CheckCachedError()
	if self.cachedError and not global_error_widget then
		local widget = ScriptErrorWidget(unpack(self.cachedError))
-- ★★ widget:MarkTransformDirty() —— 强制刷新变换矩阵。
-- ⚠ 为什么需要？因为错误弹窗可能在一个「变换未同步」的
--   时刻被创建（错误往往发生在实体操作中途）。
--   ⇒ 手动标脏确保它能正确渲染。
--   ★ 这是「异常路径需要额外的正确性保障」的体现。
		widget:MarkTransformDirty()
-- ★★ self:PushScreen(widget) —— 错误弹窗压栈。
-- ⚠ 此时 global_error_widget 还是 nil，所以 PushScreen 的 973-974
--   那个「有错误就不许压栈」的检查（已注释）不会阻止它。
--   ⇒ 必须压栈成功才能显示错误。
		self:PushScreen(widget)

		-- Pushing screens is not allowed after creating the error widget, so
		-- assign it last.
-- ════════════════════════════════════════════════════════════════
-- ★★ 全文件最后一行有语义的代码：global_error_widget = widget。
-- ★ 原注释 "-- Pushing screens is not allowed after creating the error
--   widget, so assign it last."
--
-- 【精确机制】
-- 971行 PushScreen 的 973-974 注释掉的检查若启用就是：
--   `if global_error_widget ~= nil then return end`
--   作者改成了「不阻止压栈，但用 IsControlsDisabled 冻结输入」。
--   ⇒ 于是必须**先完成压栈**再置标记，否则这个错误弹窗自己
--     会在 IsControlsDisabled 为 true 时被压栈 → 逻辑死锁。
--
-- 【★ 全局锁的完整生命周期】
--   置位点：1653（本行，唯一）
--   读取点：400 IsControlsDisabled、1635 的 SetGlobalErrorWidget
--          （若已置位则**跳过缓存** —— 因为 1636 只缓存第一次，
--            而 global_error_widget 非 nil 时 CheckCachedError 不再执行，
--            所以重复错误不会重复缓存 ✓）
--   清零点：★ 全库 grep 无清零点。
--   ⇒ 一旦置位，永久生效。
--────────────────────────────────────────────────────────────────
		global_error_widget = widget
	end
end
