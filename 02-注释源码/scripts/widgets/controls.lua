--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：scripts/widgets/controls.lua
-- 模块：UI 层 / HUD 根节点（Controls 类）
-- 职责：作为整个客户端界面的最上层容器，创建并布局全部 HUD 子控件
--       （状态栏、背包、制作菜单、toast、地图按钮、轮盘、提示气泡），
--       管理地图与制作/背包界面的开关状态机，并驱动每帧的提示文字排版。
-- 关键符号：Controls, MakeScalingNodes, SetHUDSize, OnUpdate,
--           HighlightActionItem, ManageToast,
--           ShowMap, FocusMapOnWorldPosition, HideMap, ToggleMap,
--           ShowCrafting, HideCrafting, DoShowCrafting_Internal,
--           DoHideCrafting_Internal,
--           ShowCraftingAndInventory, HideCraftingAndInventory,
--           BuildEmoteWheel, BuildCommandWheel,
--           GetTooltipPos, OverrideTooltipPos
-- ★ 三条贯穿全文件的设计原则（详见文末方法清单后的总结）：
--   · 幂等守卫 —— Show*/Hide* 开头先查状态位，已达目标态直接 return
--   · 无状态重算 —— OnUpdate 每帧从零重建 UI 呈现，不存中间态
--   · 防御性降级 —— 跨模块访问点一律判空，宁可少显示不可崩
-- ★ 移植价值最高的三处：
--   1) MakeScalingNodes 第 496-552 行 —— 「外层管分辨率 / 内层管玩家缩放」
--      的两层节点方案，DST 没有布局引擎，全靠锚点 + 两层缩放适配分辨率
--   2) 第 1020-1093 行 —— 用两个正交布尔量（craftingshown 与
--      craftingandinventoryshown）+ _Internal 收敛的幂等状态机
--   3) 第 1095-1124 行 —— BuildEmoteWheel 是「UI 配置与构建分离」的样本：
--      纯数据变换，不接触任何 UI 对象，构造期即可安全调用
-- ⚠️ 已核实并定位的真实缺陷：第 1113 行把 focus_radius 误写成 radius，
--    导致嵌套轮盘外圈判定环半径随项数放大大偏（该行注释内有量化推导）。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：screens/playerhud.lua（指令轮盘差量重建、界面栈管理）,
--           screens/mapscreen.lua（地图屏 zoom/平移生命周期）,
--           widgets/mapwidget.lua（OnShow 中 minimap:ResetOffset）, widgets/wheel.lua（轮盘控件）,
--           widgets/redux/craftingmenu_hud.lua（制作菜单）,
--           widgets/inventorybar.lua（背包栏）, widgets/hoverer.lua（tooltip 定位）,
--           emotes.lua（EMOTE_TYPE 分类）, util.lua（FunctionOrValue）,
--           constants.lua（MAX_HUD_SCALE=1.25, ANCHOR_*, SCALEMODE_*）
--============================================================

--[[
-- controls.lua —— UI 控件总控 / HUD 根节点（Controls 类）
--
-- 这是整个客户端界面的最上层容器：所有 HUD 子控件都挂在 self 上，
-- 它自己不画东西，只负责「建节点、定位、开关、每帧更新提示文字」。
--
-- 【本文件对自研引擎最有价值的三点】
-- 1) ★★ DST 没有布局引擎。UI 全部靠「代码 + 锚点」构建：没有 XML 布局、没有 flex，
--    位置只有 SetPosition(像素) + SetHAnchor/SetVAnchor(九宫格锚点) + SetScale。
--    想知道 DST 的 UI 怎么做，这一个文件就是全部答案。
-- 2) ★★ 分辨率适配靠「两层节点」：外层节点负责随分辨率等比缩放并夹住上限，
--    内层节点承接玩家的 HUD 缩放偏好。见 MakeScalingNodes 第 544-552 行。
-- 3) ★★ 互斥界面（地图 / 制作 / 背包）用「布尔状态 + 幂等守卫」管理，
--    全部动作收敛到 *_Internal 里。见第 1020-1093 行。
--
-- 【⚠️ 移植时最容易踩的坑】
-- * 「是否显示」在 UI 层被拆成了两个正交布尔量（craftingshown /
--   craftingandinventoryshown，见第 412-413 行），而不是一个。外部改其中一个，
--   界面不会立刻响应 —— 必须走 Show*/Hide* 系列函数，不能直接置字段。
-- * 地图的缩放和偏移在每次打开时都被重置（不是保持）。见第 975-988 行注释。
-- * 第 1113 行有一处真实的复制粘贴缺陷，已在该行注释中标出行号依据。
--]]
if not IsConsole() then
	require "splitscreenutils_pc"
end

local Screen = require "widgets/screen"
local Button = require "widgets/button"
local AnimButton = require "widgets/animbutton"
local ImageButton = require "widgets/imagebutton"
local Text = require "widgets/text"
local Image = require "widgets/image"
local UIAnim = require "widgets/uianim"
local Inv = require "widgets/inventorybar"
local Widget = require "widgets/widget"
local CraftTabs = require "widgets/crafttabs"
local CraftingMenu = require "widgets/redux/craftingmenu_hud"
local HoverText = require "widgets/hoverer"
local MapControls = require "widgets/mapcontrols"
local ContainerWidget = require("widgets/containerwidget")
local DemoTimer = require "widgets/demotimer"
local SavingIndicator = require "widgets/savingindicator"
local UIClock = require "widgets/uiclock"
local MapScreen = require "screens/mapscreen"
local FollowText = require "widgets/followtext"
local StatusDisplays = require "widgets/statusdisplays"
local SecondaryStatusDisplays = require "widgets/secondarystatusdisplays"
local Lavaarena_StatusDisplays = require "widgets/statusdisplays_lavaarena"
local Quagmire_StatusDisplays = require "widgets/statusdisplays_quagmire"
local Quagmire_StatusCravingDisplay = require "widgets/statusdisplays_quagmire_cravings"
local Quagmire_NotificationWidget = require "widgets/quagmire_notificationwidget"
local QuagmireRecipeBookScreen = require "screens/quagmire_recipebookscreen"
local ChatQueue = require "widgets/redux/chatqueue"
local Desync = require "widgets/desync"
local WorldResetTimer = require "widgets/worldresettimer"
local PlayerDeathNotification = require "widgets/playerdeathnotification"
local GiftItemToast = require "widgets/giftitemtoast"
local YotbToast = require "widgets/yotbtoast"
local SkillTreeToast = require "widgets/skilltreetoast"
local ScrapbookToast = require "widgets/scrapbooktoast"
local VoteDialog = require "widgets/votedialog"
local TEMPLATES = require "widgets/templates"
local UserCommandPickerScreen = require "screens/redux/usercommandpickerscreen"
local UserCommands = require "usercommands"
local Wheel = require "widgets/wheel"
local WheelItem = require "widgets/wheelitem"

local easing = require("easing")
local TeamStatusBars = require("widgets/teamstatusbars")

local WHEEL_RADIUS = 175
-- ★ 轮盘（Wheel）的几何常量。四个值必须成对理解：
--   WHEEL_RADIUS / WHEEL_FOCUS_RADIUS —— 圈半径 175 / 外圈判定半径 178。
--     两者差 3 是刻意的：判定环比图形环略大，给玩家一点「边缘容差」，
--     免得指针正好压在外圈圆边上时既不算选中也不算未选中（抖动）。
--   NESTED_WHEEL_RADIUS_INCREMENT(10) / NESTED_WHEEL_FOCUS_RADIUS_INCREMENT(1)
--     二级轮盘（展开后的子菜单）每多一项，圈放大多少。
-- ⚠️ 这四个常量同时被 BuildEmoteWheel(1118) 和 BuildCommandWheel(1132/1148) 复用，
--   所以调整轮盘大小会同时影响表情轮盘和指令轮盘，无法单独调。
local WHEEL_FOCUS_RADIUS = 178      
local NESTED_WHEEL_RADIUS_INCREMENT = 10
local NESTED_WHEEL_FOCUS_RADIUS_INCREMENT = 1

local Controls = Class(Widget, function(self, owner)
-- Controls 是 Widget 的子类，构造函数的职责：把所有 HUD 子控件建出来并挂好。
-- 【关键约定】构造期只做「建节点 + 摆位置 + 设锚点」，不做任何跨帧状态管理。
-- 所有随时间变化的逻辑一律放进 OnUpdate（第 597 行），
-- 这样玩家存档 / 换角色时只要重建一个 Controls 就能得到干净状态。
    Widget._ctor(self, "Controls")
    self.owner = owner

	local is_splitscreen = IsSplitScreen()
-- ★ 两个正交的「我是谁」判定，后面所有布局分支都靠它们：
--   is_splitscreen —— 本地是否分屏（双人同屏）
--   is_player1     —— 本实例是否属于 1 号玩家（分屏时决定左右侧）
-- 【为什么在构造期就取一次】这两个值在一局内不变；取成局部变量避免后面
-- 反复调用 C 函数，也让第 137-225 行那一大坨 if/else 读起来短一些。
	local is_player1 = IsGameInstance(Instances.Player1)

    self._scrnw, self._scrnh = TheSim:GetScreenSize()
-- 缓存当前分辨率。OnUpdate 每帧拿 TheSim:GetScreenSize() 和它比对，
-- 一旦不同就重新调 SetHUDSize（第 607-610 行）。
-- 这是 DST 处理「玩家拖拽改窗口大小 / 切显示器」的全套机制 —— 没有 resize 事件，全靠轮询。

    self.playeractionhint = self:AddChild(FollowText(TALKINGFONT, 28))
-- ★ 四块「跟随提示」（FollowText）：跟随某个实体浮在它头顶的文字气泡。
--   playeractionhint          —— 对准目标时列出可用操作（主提示）
--   playeractionhint_itemhighlight —— 上一条的「高亮某一行」用（见第 914 行）
--   attackhint               —— 单独提示攻击键
--   groundactionhint         —— 对准地面时列出的操作
-- 【为什么用 FollowText 而不是普通 Widget】因为它们要每帧跟随实体的屏幕位置，
--   Text 组件的字距/对齐在移动时不会自己更新，跟随型控件把这活儿封装了。
--   统一 SetOffset(0,100,0) = 气泡挂在目标上方 100 像素处。
    self.playeractionhint:SetHUD(owner.HUD.inst)
    self.playeractionhint:SetOffset(Vector3(0, 100, 0))
    self.playeractionhint:Hide()

    self.playeractionhint_itemhighlight = self:AddChild(FollowText(TALKINGFONT, 28))
    self.playeractionhint_itemhighlight:SetHUD(owner.HUD.inst)
    self.playeractionhint_itemhighlight:SetOffset(Vector3(0, 100, 0))
    self.playeractionhint_itemhighlight:Hide()

    self.attackhint = self:AddChild(FollowText(TALKINGFONT, 28))
    self.attackhint:SetHUD(owner.HUD.inst)
    self.attackhint:SetOffset(Vector3(0, 100, 0))
    self.attackhint:Hide()

    self.groundactionhint = self:AddChild(FollowText(TALKINGFONT, 28))
    self.groundactionhint:SetHUD(owner.HUD.inst)
    self.groundactionhint:SetOffset(Vector3(0, 100, 0))
    self.groundactionhint:Hide()

    self.blackoverlay = self:AddChild(Image("images/global.xml", "square.tex"))
-- 全屏黑色半透明遮罩。SetScaleMode(SCALEMODE_FILLSCREEN) 让它无视缩放铺满屏幕，
-- 【布局要点】SetClickable(false) 是必须的 —— 否则这层遮罩会把所有鼠标点击吃掉。
-- 凡是做「压暗背景 + 只让上层可交互」的 UI，这一对调用总是一起出现。
    self.blackoverlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.blackoverlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.blackoverlay:SetVAnchor(ANCHOR_MIDDLE)
    self.blackoverlay:SetHAnchor(ANCHOR_MIDDLE)
    self.blackoverlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.blackoverlay:SetClickable(false)
    self.blackoverlay:SetTint(0,0,0,.5)
    self.blackoverlay:Hide()

	self.containerroot_under = self:AddChild(Widget(""))
-- ★★ 容器挂载点三件套：containerroot 的 under / 本体 / over。
-- 这是一个手工实现的「三明治分层」，用来解决容器 UI 的遮挡顺序问题：
--   _under            —— 压在容器内容「下面」的东西（如塞子背后的装饰）
--   containerroot     —— 容器主体（箱子/冰箱打开时弹出的那层）
--   _over             —— 压在容器内容「上面」的东西（如标题栏、数量角标）
-- 【为什么不用现成的层级系统】DST 的 Widget 是扁平兄弟列表，没有 z-index，
--   前后关系只由 AddChild 的调用顺序决定。所以要三明治就得手动建三个根。
    self.containerroot = self:AddChild(Widget(""))
	self.containerroot_over = self:AddChild(Widget(""))
    self.containerroot_side_behind = self:AddChild(Widget(""))
    self:MakeScalingNodes()

    self.saving = self.topright_over_root:AddChild(SavingIndicator(self.owner))
    self.saving:SetPosition(-440, 0, 0)

    self.toastlocations = {
-- ★ 四个 toast（提示条）的「停靠位」。x = 115/215/315/415，间隔正好 100，
--   与第 112/116/120/124 行实际 SetPosition 的坐标一一对应。
-- 【为什么用「位置表 + 占位」而不是直接排队】toast 的出现与消失是异步的
--   （带 MoveTo 动画，结束后才回调 ManageToast），所以必须有一个数据结构
--   独立于 toast 自身来记录「谁占了第几格」，ManageToast（第 443 行）负责搬位。
        {pos=Vector3(115, 150, 0)},
        {pos=Vector3(215, 150, 0)},
        {pos=Vector3(315, 150, 0)},
        {pos=Vector3(415, 150, 0)},        
    }
	self.toastitems = {}

    self.item_notification = self.topleft_root:AddChild(GiftItemToast(self.owner, self))
    self.item_notification:SetPosition(115, 150, 0)
	table.insert(self.toastitems, self.item_notification)

    self.yotb_notification = self.topleft_root:AddChild(YotbToast(self.owner, self))
    self.yotb_notification:SetPosition(215, 150, 0)
	table.insert(self.toastitems, self.yotb_notification)

    self.skilltree_notification = self.topleft_root:AddChild(SkillTreeToast(self.owner, self))
    self.skilltree_notification:SetPosition(315, 150, 0)
	table.insert(self.toastitems, self.skilltree_notification)

    self.scrapbook_notification = self.topleft_root:AddChild(ScrapbookToast(self.owner, self))
    self.scrapbook_notification:SetPosition(415, 0, 0)
	table.insert(self.toastitems, self.scrapbook_notification)

    --self.worldresettimer = self.bottom_root:AddChild(WorldResetTimer(self.owner))
-- ⚠️ 注意这里的「注释掉的旧代码 + 新代码复用旧字段名」手法：
--   WorldResetTimer 已被 PlayerDeathNotification 取代（第 128 行），
--   但字段名 self.worldresettimer 被沿用（第 130、490 行仍在读它）。
-- 【为什么故意不改名】字段是 HUD 各处与存档逻辑的隐式接口，
--   改名会牵连一片调用点；沿用旧名 + 留一行注释掉的旧代码，是最小风险的重构。
--   移植自己的项目时建议反过来：新字段用新名，旧名保留一个 alias 过渡。
    self.worldresettimer = self.bottom_root:AddChild(PlayerDeathNotification(self.owner))
    self.inv = self.bottom_root:AddChild(Inv(self.owner))
    self.inv.autoanchor = self.worldresettimer
    self.inv:Hide()

    self.sidepanel = self.topright_root:AddChild(Widget("sidepanel"))
    self.sidepanel:SetScale(1,1,1)
    self.sidepanel:SetPosition(-80, -60, 0)

    if is_splitscreen then
-- ★★★ 布局分支矩阵：is_splitscreen × is_player1 × 服务端玩法，共 3×3 种组合。
-- 为什么会有玩法分支：Lavaarena/Quagmire 是特殊服务端模式，
--   它们的状态栏控件类、挂载位置和普通模式完全不同。
-- 【本文件里最值得学的一点】每个分支内部保持「结构同形」：
--   都赋值 self.status / self.clock / self.votedialog，只是位置常量不同。
--   下游代码因此可以无条件访问这些字段，不需要到处写 if is_splitscreen。
--   ⚠️ 代价：新增分支时很容易漏挂某个字段，导致某组合下 nil 崩溃。
--      下游有多处 `if self.X ~= nil then` 的防御（如第 435、582 行）就是被逼出来的。
        if is_player1 then
            if TheNet:GetServerGameMode() == "lavaarena" then
                self.status = self.bottom_root:AddChild(Lavaarena_StatusDisplays(self.owner))
                self.status:SetPosition(-180,105,0)
                --self.status:SetScale(1.8)
                self.teamstatus = self.topleft_root:AddChild(TeamStatusBars(self.owner))
            elseif TheNet:GetServerGameMode() == "quagmire" then
                self.status = self.bottom_root:AddChild(Quagmire_StatusDisplays(self.owner))
                --self.status:SetScale(1.4)
                self.quagmire_hangriness = self.top_root:AddChild(Quagmire_StatusCravingDisplay(self.owner))
                self.quagmire_hangriness.inst:DoPeriodicTask(.5, function() self.quagmire_hangriness:UpdateStatus() end, 0)
-- ⚠️ 这里是全文件唯一一处「由 Controls 主动起周期任务」：每 0.5 秒刷新渴望度条。
-- 【为什么 DoPeriodicTask 的第三个参数写 0】第三个参数是随机相位偏移（秒），
--   传 0 表示不随机。多个客户端若随机相位会错开，刷新帧就会分散在各帧上。
--   ⚠️ 但此处只在 is_splitscreen 且 is_player1 的分支里挂了（第 148 行），
--   单屏分支（第 206 行）和分屏 P2 分支（第 178 行）都没挂 ——
--   意味着非 P1 玩家的渴望度条可能不刷新。这是「分支同形没做到位」的实例。
                self.quagmire_notifications = self.right_root:AddChild(Quagmire_NotificationWidget(self.owner))

                self.containerroot:MoveToFront() -- so safes ui opens on top of hangriness meter
            else
                self.status = self.topleft_root:AddChild(StatusDisplays(self.owner))
                self.status:SetPosition(120,-100,0)
                self.status:SetScale(1.4)

                self.secondary_status = self.topright_root:AddChild(SecondaryStatusDisplays(self.owner))
                self.secondary_status:SetPosition(-160,-250,0)
                self.secondary_status:SetScale(2.2)

				self.clock = self.sidepanel:AddChild(UIClock())
				if self.clock:IsCaveClock() then
					self.clock.inst:DoSimPeriodicTask(.5, function() self.clock:UpdateCaveClock(self.owner) end, 0)
				end
            end

            self.votedialog = self.topright_root:AddChild(VoteDialog(self.owner))
            self.votedialog:SetPosition(-350, 0, 0)
        else
            if TheNet:GetServerGameMode() == "lavaarena" then
                self.status = self.bottom_root:AddChild(Lavaarena_StatusDisplays(self.owner))
                self.status:SetPosition(-180,105,0)	
                --self.status:SetScale(1.8)
                self.teamstatus = self.topright_root:AddChild(TeamStatusBars(self.owner))
            elseif TheNet:GetServerGameMode() == "quagmire" then
                self.status = self.bottom_root:AddChild(Quagmire_StatusDisplays(self.owner))
                --self.status:SetScale(1.4)
                self.quagmire_hangriness = self.top_root:AddChild(Quagmire_StatusCravingDisplay(self.owner))
                self.quagmire_notifications = self.right_root:AddChild(Quagmire_NotificationWidget(self.owner))

                self.containerroot:MoveToFront() -- so safes ui opens on top of hangriness meter
            else
                self.status = self.topright_root:AddChild(StatusDisplays(self.owner))
                self.status:SetPosition(-120,-100,0)
                self.status:SetScale(1.4)

                self.secondary_status = self.topleft_root:AddChild(SecondaryStatusDisplays(self.owner))
                self.secondary_status:SetPosition(160,-250,0)
                self.secondary_status:SetScale(2.2)

				self.clock = self.sidepanel:AddChild(UIClock())
				if self.clock:IsCaveClock() then
					self.clock.inst:DoSimPeriodicTask(.5, function() self.clock:UpdateCaveClock(self.owner) end, 0)
				end
            end
            
            self.votedialog = self.topleft_root:AddChild(VoteDialog(self.owner))
            self.votedialog:SetPosition(350, 0, 0)
        end
    else
        if TheNet:GetServerGameMode() == "lavaarena" then
            self.status = self.bottom_root:AddChild(Lavaarena_StatusDisplays(self.owner))
            self.teamstatus = self.topleft_root:AddChild(TeamStatusBars(self.owner))
        elseif TheNet:GetServerGameMode() == "quagmire" then
            self.status = self.bottom_root:AddChild(Quagmire_StatusDisplays(self.owner))
            self.quagmire_hangriness = self.top_root:AddChild(Quagmire_StatusCravingDisplay(self.owner))
            self.quagmire_notifications = self.right_root:AddChild(Quagmire_NotificationWidget(self.owner))
            self.quagmire_notifications:SetPosition(0, 200)
            self.containerroot:MoveToFront() -- so safes ui opens on top of hangriness meter
        else
            self.status = self.sidepanel:AddChild(StatusDisplays(self.owner))
            self.status:SetPosition(0,-110,0)

            self.secondary_status = self.sidepanel:AddChild(SecondaryStatusDisplays(self.owner))
            self.secondary_status:SetPosition(0,-110,0)

            self.clock = self.sidepanel:AddChild(UIClock())
            if self.clock:IsCaveClock() then
                self.clock.inst:DoSimPeriodicTask(.5, function() self.clock:UpdateCaveClock(self.owner) end, 0)
            end
        end

        self.votedialog = self.topright_root:AddChild(VoteDialog(self.owner))
        self.votedialog:SetPosition(-330, 0, 0)
	end
	
    local twitch_options = TheFrontEnd:GetTwitchOptions()
-- Twitch 直播内嵌聊天。SupportedByPlatform / IsInitialized / GetBroadcastingEnabled
-- 三层门禁 —— 任一不满足就直接不建节点。
-- 【为什么用「不满足就不建」而不是「建了再 Hide」】省掉一整棵 UI 子树的
-- 每帧布局与事件处理开销。平台条件类 UI 都该这么写。
    if twitch_options ~= nil and twitch_options:SupportedByPlatform() then
        if twitch_options:IsInitialized() and twitch_options:GetBroadcastingEnabled() and twitch_options:GetVisibleChatEnabled() then
            self.chatqueue = self.sidepanel:AddChild(ChatQueue(self.owner))
        end
    end

    -- Network global chat queue
    self.chat_queue_root = self:AddChild(Widget("chat_queue_root"))
-- 全局网络聊天的挂载点。SetScaleMode(PROPORTIONAL) + 锚定底部 + MoveToBack，
-- 保证聊天永远在最底层且不随别的节点缩放而变形。
-- 【注意第 240 行】变量自我重绑定：把 self.chat_queue_root 换成它的子节点，
--   于是第 241-242 行的定位坐标是相对这个子节点而非父节点。
--   这个「用 AddChild 的返回值覆盖原字段」的技巧在本文件出现十几次（第 265、271、
--   277、283、290、405、545-552 行），是 DST 排版的核心手法。
    self.chat_queue_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.chat_queue_root:SetHAnchor(ANCHOR_MIDDLE)
    self.chat_queue_root:SetVAnchor(ANCHOR_BOTTOM)
    self.chat_queue_root:MoveToBack()
    self.chat_queue_root = self.chat_queue_root:AddChild(Widget(""))
    self.chat_queue_root:SetPosition(-90,765,0)
    self.networkchatqueue = self.chat_queue_root:AddChild(ChatQueue())
    self.networkchatqueue:SetClickable(false)

    self.containers = {}
-- 已打开容器控件的注册表。容器自己会在需要关闭时置 should_close_widget 标志，
-- 由 OnUpdate 统一回收（第 624-629 行）。

    self.mapcontrols = self.bottomright_root:AddChild(MapControls())
    self.mapcontrols:SetPosition(-60,70,0)
    if TheNet:GetServerGameMode() == "quagmire" then
		self.mapcontrols.minimapBtn:SetTextures("images/quagmire_hud.xml", "map_button.tex")
		self.mapcontrols.map_tooltip = STRINGS.UI.RECIPE_BOOK.TITLE.."\n"
		self.mapcontrols:RefreshTooltips()
	end

    --set this to true, to enable the PAX demo timer
    if false and not IsGamePurchased() then
-- ⚠️ `if false and ...` —— 硬关闭的 PAX 演示计时器，条件恒假，是死代码。
-- 【注意这不是「未实现」，而是「主动关闭」】发布正式版时用 false 关掉，
--   内部试玩会改成 true。移植时见到 `if false and` 通常意味着有开关被关了，
--   不要当垃圾代码删掉。第 631-636 行那段被注释的清理逻辑与之配套。
        self.demotimer = self.top_root:AddChild(DemoTimer(self.owner))
        self.demotimer:SetPosition(0, 0, 0)
    end

    self.containerroot:SetHAnchor(ANCHOR_MIDDLE)
-- ★★ 容器根的分辨率适配四件套，四个挂载点完全同构：
--   SetHAnchor/VAnchor —— 锚点，决定「贴哪条边」
--   SetScaleMode(PROPORTIONAL) —— 等比缩放，随分辨率线性放大/缩小
--   SetMaxPropUpscale(MAX_HUD_SCALE) —— ★ 夹住放大上限
--   self.X = self.X:AddChild(Widget("")) —— 换绑到子节点
-- 【MAX_HUD_SCALE = 1.25（constants.lua:43）为什么必须有】
--   等比缩放在 4K 下会把 UI 放得过大，文字糊、点击区域也偏大；
--   在 720p 下又需要缩小。夹住上限 = 高分辨率下不再变大，只保证可读性下限。
-- 【为什么要换绑子节点】留出「第二层」给玩家偏好缩放用，见第 544 行。
    self.containerroot:SetVAnchor(ANCHOR_MIDDLE)
    self.containerroot:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.containerroot:SetMaxPropUpscale(MAX_HUD_SCALE)
    self.containerroot = self.containerroot:AddChild(Widget(""))

	self.containerroot_under:SetHAnchor(ANCHOR_MIDDLE)
	self.containerroot_under:SetVAnchor(ANCHOR_MIDDLE)
	self.containerroot_under:SetScaleMode(SCALEMODE_PROPORTIONAL)
	self.containerroot_under:SetMaxPropUpscale(MAX_HUD_SCALE)
	self.containerroot_under = self.containerroot_under:AddChild(Widget("containerroot_under"))

	self.containerroot_over:SetHAnchor(ANCHOR_MIDDLE)
	self.containerroot_over:SetVAnchor(ANCHOR_MIDDLE)
	self.containerroot_over:SetScaleMode(SCALEMODE_PROPORTIONAL)
	self.containerroot_over:SetMaxPropUpscale(MAX_HUD_SCALE)
	self.containerroot_over = self.containerroot_over:AddChild(Widget("containerroot_over"))

    self.containerroot_side_behind:SetHAnchor(ANCHOR_RIGHT)
-- containerroot_side_behind：贴在容器「侧边后面」的一层，锚点故意用 RIGHT+MIDDLE
--（其余容器根都是 MIDDLE 居中），因为侧边栏内容靠右对齐。
    self.containerroot_side_behind:SetVAnchor(ANCHOR_MIDDLE)
    self.containerroot_side_behind:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.containerroot_side_behind:SetMaxPropUpscale(MAX_HUD_SCALE)
    self.containerroot_side_behind = self.containerroot_side_behind:AddChild(Widget("containerroot_side_behind"))

    self.containerroot_side = self:AddChild(Widget(""))
-- 第五个容器根：侧栏容器。与 side_behind 的区别是它初始 Hide（第 291 行），
-- 只在 ShowCraftingAndInventory 里才 Show（第 1058 行）。
-- 【命名小坑】第 290 行 AddChild(Widget("contaierroot_side")) —— contaier 拼错了
--   （应为 container）。字符串只是动画名，不影响逻辑，故未修。
    self.containerroot_side:SetHAnchor(ANCHOR_RIGHT)
    self.containerroot_side:SetVAnchor(ANCHOR_MIDDLE)
    self.containerroot_side:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.containerroot_side:SetMaxPropUpscale(MAX_HUD_SCALE)
    self.containerroot_side = self.containerroot_side:AddChild(Widget("contaierroot_side"))
    self.containerroot_side:Hide()


    self.mousefollow = self:AddChild(Widget("follower"))
-- 鼠标跟随的空节点。它本身不显示，作用是给「浮层」（tooltip、拖拽预览、
-- 物品高亮）当坐标基准：FollowMouse(true) 后该节点的坐标就是鼠标位置。
-- 【为什么 SetScaleMode(PROPORTIONAL) 但不设 MaxPropUpscale】
--   它是坐标载体不是可见 UI，缩放策略要与别的层一致才能对得上鼠标实际落点。
    self.mousefollow:FollowMouse(true)
    self.mousefollow:SetScaleMode(SCALEMODE_PROPORTIONAL)

    self.hover = self:AddChild(HoverText(self.owner))
    self.hover:SetScaleMode(SCALEMODE_PROPORTIONAL)

	if is_player1 then
-- ★ 制作菜单挂在哪一侧由「我是几号玩家」决定：P1 靠左、P2 靠右。
-- 【为什么 P1 用 left_root、P2 用 right_root】left_root / right_root 在
--   SetHUDSize（第 586-592 行）里被赋予 crafting_scale（制作面板专用缩放），
--   而另一侧只给普通 scale。所以挂哪边不是随意的，必须与缩放约定一致。
-- ⚠️ 移植陷阱：把制作面板挂到 top/bottom 类挂载点会让它跟着错误地缩放。
	    self.craftingmenu = self.left_root:AddChild(CraftingMenu(self.owner, true))
	else
	    self.craftingmenu = self.right_root:AddChild(CraftingMenu(self.owner, false))
	end
	self.crafttabs = self.craftingmenu -- self.crafttabs is deprecated
-- 旧字段名的向后兼容别名。作者已用注释标明 deprecated。
-- 【为什么保留】老模组按 self.controls.crafttabs 拿菜单，删掉会全线报错。
--   模组生态一旦形成，废弃字段的清理成本极高 —— 宁可长期保留。

	self.commandwheelroot = self:AddChild(Widget("CommandWheelRoot"))
-- 轮盘的公共挂载点，居中锚定 + 等比缩放。两个轮盘（法术/指令）共用它，
-- 靠各自 SetScale 区分大小。
    self.commandwheelroot:SetHAnchor(ANCHOR_MIDDLE)
    self.commandwheelroot:SetVAnchor(ANCHOR_MIDDLE)
    self.commandwheelroot:SetScaleMode(SCALEMODE_PROPORTIONAL)

	self.spellwheel = self.commandwheelroot:AddChild(Wheel("SpellWheel", owner, {ignoreleftstick = true,}))
-- 法术轮盘。ignoreleftstick = true 表示左摇杆不参与瞄准 ——
-- 因为左摇杆已经被「移动」占用了。
-- 【OnCancel / OnExecute 的约定】两个回调把「怎么关闭」的决定权交给 HUD：
--   控件本身不碰界面栈，只报告用户选完/取消了，由 HUD 决定关哪个屏。
--   这样轮盘可以被复用（比如嵌在别的菜单里）。
	self.spellwheel.selected_label:SetSize(26)
	self.spellwheel.OnCancel = function() owner.HUD:CloseSpellWheel() end
	self.spellwheel.OnExecute = function(spellwheel)
		if not (spellwheel.invobject and spellwheel.invobject.components.spellbook and not spellwheel.invobject.components.spellbook.closeonexecute) then
			owner.HUD:CloseSpellWheel(true)
		end
	end


	self.commandwheel = self.commandwheelroot:AddChild(Wheel("CommandWheel", owner, {ignoreleftstick = Profile:GetCommandWheelAllowsGameplay(),}))
-- 指令轮盘。第 325 行 OnExecute 直接复用 OnCancel ——
-- 【为什么可以复用】指令轮盘的每一项要么自己 PushScreen、要么就是「取消」语义，
--   没有「执行完要留在原地」的情况，所以两个回调行为一致。
	self.commandwheel.OnCancel = function() owner.HUD:CloseCommandWheel() end
	self.commandwheel.OnExecute = self.commandwheel.OnCancel

	local character_name = self.owner.prefab
-- ★ 角色专属表情图集的容错。检查 images/emotes_<角色>.xml 是否存在，
-- 不存在就退回 "generic" 通用图集。
-- 【为什么需要这个兜底】表情轮盘的图集名是用角色 prefab 拼出来的（第 337/345/353 行），
--   而 mod 加的自定义角色几乎不会自带 emote 图集。没有兜底就是开局崩溃。
-- 【移植要点】任何「用实体名拼资源路径」的地方都必须有 fallback，
--   否则第三方内容的缺失会变成你的崩溃。
    if not kleifileexists("images/emotes_"..character_name..".xml") then -- TODO(JBK): This would be best done as SkinsPuppet and to do this when time permits. [SPCEWI]
        character_name = "generic"
    end
    self.character_name = character_name
    
    local emote_groups_template = {}	
-- ★ 表情分组的「模板」。注意 emotes 表都是空的 —— 这里只定义分组的壳：
--   label（组标题）、image（组图标 tex）、emotes（待填充的成员列表）。
-- EMOTE_TYPE 是三分类：EMOTION 情绪 / ACTION 动作 / UNLOCKABLE 可解锁。
-- 【为什么要模板 + deepcopy 两份】第 359-360 行：
--   站立和骑乘两套轮盘必须各有独立成员表（骑乘时多了坐骑专属表情），
--   但结构完全相同。用 deepcopy 复制模板比手写两份结构更抗改。
	emote_groups_template[EMOTE_TYPE.EMOTION] = 
	{
        label= STRINGS.UI.EMOTES.EMOTIONS,
        image = "gesture_"..self.character_name.."_wave.tex",
        emotes = 
        {
        },
    }         
	emote_groups_template[EMOTE_TYPE.ACTION] = 
    {
        label= STRINGS.UI.EMOTES.ACTIONS,
        image = "gesture_"..self.character_name.."_pose.tex",
        emotes = 
        {
        },
    }  
	emote_groups_template[EMOTE_TYPE.UNLOCKABLE] = 
    {
        label= STRINGS.UI.EMOTES.UNLOCKABLES,
        image = "gesture_"..self.character_name.."_cheer.tex",
        emotes = 
        {
        },
    }

	local emote_groups_standing = deepcopy(emote_groups_template)
-- deepcopy 复制出「站立」和「骑乘」两套。
-- 【deepcopy 为什么必需】如果直接共享同一个 emotes 表，两次 table.insert
--   会把条目插两次，骑乘轮盘会混进不该有的表情。浅拷贝在这里必然出错。
	local emote_groups_mounted = deepcopy(emote_groups_template)
	local common_emotes = GetCommonEmotes()	
	for name, emote in pairs(common_emotes) do
-- 把公共表情按 mounted / mountonly 标志分流进两套分组。
-- 【两个标志的语义差异】
--   emote.data.mounted    = true → 只有骑乘时才出现
--   emote.data.mountonly  = true → 只有骑乘时...
--   第 370 行是 `if not emote.data.mountonly` → 「不是骑乘专属」才进站立表。
--   注意这两条分支是独立的 if 而非 if/else：一个表情可以既 mounted 又非 mountonly，
--   此时它在两套轮盘里都出现。
		--print("Emote:" .. name)
		if emote.type then	-- ignore unclassified emotes
			if emote.data.mounted then
				--print("...added to Mounted emote group:" .. tostring(emote.type))
				table.insert(emote_groups_mounted[emote.type].emotes, name)
			end
		
			if not emote.data.mountonly then
				--print("...added to Standing emote group:" .. tostring(emote.type))
				table.insert(emote_groups_standing[emote.type].emotes, name)
			end
		end
	end
        
    -- check and add unlockable emotes
    for item_type, emote in pairs(EMOTE_ITEMS) do
-- 道具解锁的表情：走 TheInventory:CheckOwnership 判定玩家是否拥有该物品。
-- 【为什么解锁型表情不能写死在配置里】它们取决于玩家背包内容，
--   必须运行时查。这里遍历的是全局 EMOTE_ITEMS 表，插入的是 emote.cmd_name
--   （命令名）而非物品名 —— 轮盘最终按命令名去执行表情。
       if TheInventory:CheckOwnership(item_type) then      
	   		--print("Unlockable Emote:" .. emote.cmd_name)
			if emote.data.mounted then
				--print("...added to Mounted emotes")
				table.insert(emote_groups_mounted[EMOTE_TYPE.UNLOCKABLE].emotes, emote.cmd_name)
			end
		
			if not emote.data.mountedonly then
				--print("...added to Standing emotes")				
				table.insert(emote_groups_standing[EMOTE_TYPE.UNLOCKABLE].emotes, emote.cmd_name)
			end
		end
    end
    
	self.emote_wheel_standing = self:BuildEmoteWheel(self.character_name, emote_groups_standing)
-- 分别构建站立 / 骑乘两套表情轮盘数据。BuildEmoteWheel 只需 character_name + 分组表，
-- 是纯数据变换，不碰任何 UI 对象（详见第 1095 行）。
	self.emote_wheel_mounted = self:BuildEmoteWheel(self.character_name, emote_groups_mounted)

	self:BuildCommandWheel()     

    if TheNet:GetIsClient() then
-- 掉线检测指示器。只在客户端建（第 398 行 TheNet:GetIsClient()）。
-- 【注释里说明了为什么不用 topleft_root】必须压在 containerroot 之上，
--   否则打开容器时掉线提示会被容器 UI 盖住。
-- 第 406 行只在 WIN32_RAIL（专用服务器）显示性能信息 ——
--   这是给开发/运维看的，玩家端不给看。
        --Not using topleft_root because we need to be on top of containerroot
        self.desync = self:AddChild(Widget("desyncroot"))
        self.desync:SetScaleMode(SCALEMODE_PROPORTIONAL)
        self.desync:SetHAnchor(ANCHOR_LEFT)
        self.desync:SetVAnchor(ANCHOR_TOP)
        self.desync:SetMaxPropUpscale(MAX_HUD_SCALE)
        self.desync = self.desync:AddChild(Desync(owner))
        if PLATFORM == "WIN32_RAIL" then
            self.desync:ShowHostPerf()
        end
    end

    self.dismounthintdelay = 0
-- ★★ 三个状态位的初值，理解它们是读懂本文件后半段的前提：
--   dismounthintdelay            —— 卸马提示的冷却计时器（秒）
--   craftingandinventoryshown    —— 「背包+制作」这整块是否展开
--   craftingshown                —— 玩家是否允许看制作界面（独立于上面那个）
-- 【为什么拆成两个而不是一个】两个界面的生命周期不同步：
--   制作界面可以一直开着（第 413 行初值就是 true），而背包是默认关的；
--   玩家可能「关掉制作但保留背包」。实际可见性 = 两者同时为真。
--   ★ 这种「正交布尔量 + 合取」的建模是全文件的核心状态机思路。
    self.craftingandinventoryshown = false
	self.craftingshown = true

    self:SetHUDSize()
-- 构造末尾立刻算一次 HUD 尺寸。所有依赖分辨率的节点到此刻已全部建好，
-- 所以必须放在最后 —— 早调用会漏掉后面才创建的节点。

    --NOTE: this is triggered on the swap SOURCE. we need to stop updates because
    --      playercontroller component is removed first, entity remove is delayed.
    self.inst:ListenForEvent("seamlessplayerswap", function()
-- ★ 无缝换人（seamless playerswap）的生命周期钩子。
-- 【注释解释了触发端】这个事件在「换出方」触发，注释明确要求 StopUpdating，
--   因为 playercontroller 组件会先被移除、实体的 Remove 是延迟的，
--   中间这几帧里 OnUpdate 若还跑，第 642/644 行访问 playercontroller 就会崩。
-- 【移植要点】UI 每帧更新里访问了「随时可能被卸载的组件」时，
--   必须在组件卸载事件上主动停帧，而不是指望引擎保证调用顺序。
        self:StopUpdating()
    end, self.owner)

    --NOTE: this is triggered on the swap TARGET.
    self.inst:ListenForEvent("finishseamlessplayerswap", function()
-- 换入方：等无缝换人完成后，若背包 replica 报告可见，就补开制作界面。
-- 【为什么要补这一刀】因为换出方走的是 StopUpdating + Hide 路径，
--   新角色那边的 Controls 是新对象，状态位全新（全是初值），
--   必须靠这个事件把界面恢复到玩家离开时的样子。
        if self.owner.replica.inventory:IsVisible() then
            self:ShowCraftingAndInventory()
        end
    end, self.owner)

    self:StartUpdating()
-- 一切就绪后才开帧更新。放在构造函数最后一行是硬性要求。
end)

function Controls:ShowStatusNumbers()
    self.status:ShowStatusNumbers()
    if self.teamstatus ~= nil then
        self.teamstatus:ShowStatusNumbers()
    end
    if self.secondary_status ~= nil then
        self.secondary_status:ShowStatusNumbers()
    end
end

function Controls:ManageToast(toast, remove)
-- ★★ toast 的位次管理。一个接口干两件事：
--   ManageToast(toast)       → 找一个空位坐下（首次出现）
--   ManageToast(toast, true) → 请走，并让后面的 toast 往前补位
-- 【为什么 toast 自己不记录自己的位置】因为 toast 消失有动画时长，
--   位置表必须独立存在，否则动画播完前谁都不敢动位置（会跳）。
    local collapse = false
    for i,spot in ipairs(self.toastlocations) do
        if remove then
            if spot.toast == toast then
                spot.toast = nil
            end
            collapse = true
-- ⚠️ 疑似缺陷（静态推演，未实机验证）：collapse 被无条件置 true。
--   第 447-450 行：只有 spot.toast == toast 时才清空本槽，但 collapse = true
--   在 if 之外，对 remove 分支的每一轮都成立。
--   后果是补位从第 1 格就开始整体左移，而不是从被删的那一格开始。
--   举例（4 格占满 A B C D，删除 C）：
--     i=1: 槽2的 B 覆盖槽1，槽2 清空 → [B, -, C, D]
--     i=2: 槽3的 C 覆盖槽2，槽3 清空 → [B, C, -, D]   ← C 没被删掉，只是左移了一格
--     i=3: 槽4的 D 覆盖槽3            → [B, C, D, -]
--   即被删的 toast 会留在上一格里，表现为「提示条不消失而是往前挪」。
--   行号依据：第 450 行的缩进与第 447 行 if 同级（在 if remove 之内、
--   if spot.toast == toast 之外）。若原意是「仅在命中后才开始补位」，
--   collapse = true 应写在第 448 行 spot.toast = nil 的紧邻之后。
--   【移植建议】若你要复用这段逻辑，把 collapse 的赋值移进命中分支即可。
        else
            if not spot.toast then                
               spot.toast = toast 
               spot.toast:SetPosition(spot.pos.x,spot.pos.y,spot.pos.z)
               break
            end
        end

        if collapse then
            if self.toastlocations[i+1] and self.toastlocations[i+1].toast then
                spot.toast = self.toastlocations[i+1].toast
                self.toastlocations[i+1].toast = nil
                spot.toast:SetPosition(spot.pos.x,spot.pos.y,spot.pos.z)
            end
        end
    end
end

function Controls:HideStatusNumbers()
    self.status:HideStatusNumbers()
    if self.teamstatus ~= nil then
        self.teamstatus:HideStatusNumbers()
    end
    if self.secondary_status ~= nil then
        self.secondary_status:HideStatusNumbers()
    end
end

function Controls:SetDark(val)
    if val then
        self.blackoverlay:Show()
    else
        self.blackoverlay:Hide()
    end
end

function Controls:SetGhostMode(isghost)
    self.status:SetGhostMode(isghost)
    self.secondary_status:SetGhostMode(isghost)
	self.worldresettimer:SetGhostMode(isghost)
end

function Controls:MakeScalingNodes()
-- ★★★ MakeScalingNodes：建立 8 个「自动缩放锚点根节点」，
-- 这是理解 DST UI 分辨率适配的关键，值得逐行读。
-- 【8 个挂载点分别对应屏幕的 8 个方向】
--   top_root / bottom_root / top_root_over    —— 上、下、上覆盖层
--   topleft_root / topright_root              —— 左上、右上
--   bottomright_root                          —— 右下
--   left_root / right_root                    —— 左中、右中
-- 【为什么要拆成 8 个而不是 1 个】因为锚点是控件自己的属性，
--   一个节点只能锚一条边 + 一条边。业务代码按方位取挂载点，
--   就能拿到「已经贴好对应边」的坐标系，不必自己算像素。

    --these are auto-scaling root nodes
    self.top_root = self:AddChild(Widget("top"))
-- 每个挂载点 4 行配置，模板完全一致。以 top_root 为例：
--   AddChild(Widget("top"))   —— 名字只是动画查找键，便于调试
--   SetScaleMode(PROPORTIONAL) —— 随分辨率等比缩放
--   SetHAnchor(ANCHOR_MIDDLE) / SetVAnchor(ANCHOR_TOP) —— 贴上边、水平居中
--   SetMaxPropUpscale(MAX_HUD_SCALE) —— 缩放上限 1.25，超出就不再变大
-- 【每个挂载点都必须设 MaxPropUpscale】漏掉的会在 4K 下无限放大，
--   这是移植自己项目时最容易漏的一行。
    self.top_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.top_root:SetHAnchor(ANCHOR_MIDDLE)
    self.top_root:SetVAnchor(ANCHOR_TOP)
    self.top_root:SetMaxPropUpscale(MAX_HUD_SCALE)

    self.topleft_root = self:AddChild(Widget("topleft"))
    self.topleft_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.topleft_root:SetHAnchor(ANCHOR_LEFT)
    self.topleft_root:SetVAnchor(ANCHOR_TOP)
    self.topleft_root:SetMaxPropUpscale(MAX_HUD_SCALE)

    self.bottom_root = self:AddChild(Widget("bottom"))
    self.bottom_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.bottom_root:SetHAnchor(ANCHOR_MIDDLE)
    self.bottom_root:SetVAnchor(ANCHOR_BOTTOM)
    self.bottom_root:SetMaxPropUpscale(MAX_HUD_SCALE)

    self.topright_root = self:AddChild(Widget("side"))
    self.topright_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.topright_root:SetHAnchor(ANCHOR_RIGHT)
    self.topright_root:SetVAnchor(ANCHOR_TOP)
    self.topright_root:SetMaxPropUpscale(MAX_HUD_SCALE)

    self.right_root = self:AddChild(Widget("right_root"))
    self.right_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.right_root:SetHAnchor(ANCHOR_RIGHT)
    self.right_root:SetVAnchor(ANCHOR_MIDDLE)
    self.right_root:SetMaxPropUpscale(MAX_HUD_SCALE)

    self.bottomright_root = self:AddChild(Widget("bottomright"))
    self.bottomright_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.bottomright_root:SetHAnchor(ANCHOR_RIGHT)
    self.bottomright_root:SetVAnchor(ANCHOR_BOTTOM)
    self.bottomright_root:SetMaxPropUpscale(MAX_HUD_SCALE)

    self.left_root = self:AddChild(Widget("left_root"))
    self.left_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.left_root:SetHAnchor(ANCHOR_LEFT)
    self.left_root:SetVAnchor(ANCHOR_MIDDLE)
    self.left_root:SetMaxPropUpscale(MAX_HUD_SCALE)

    self.topright_over_root = self:AddChild(Widget("topright_over"))
    self.topright_over_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.topright_over_root:SetHAnchor(ANCHOR_RIGHT)
    self.topright_over_root:SetVAnchor(ANCHOR_TOP)
    self.topright_over_root:SetMaxPropUpscale(MAX_HUD_SCALE)
	
    --these are for introducing user-configurable hud scale
-- ★★★★ 全文件最精妙的一处设计，务必理解。
-- 【两层节点的分工】
--   外层（第 496-542 行建的）—— 负责「随分辨率缩放」+ 锚点 + 放大上限
--   内层（这里新建的这批）—— 负责「玩家在设置里拖的 HUD 缩放」
--   即 self.topleft_root 等 8 个字段被重新绑定到内层节点。
-- 【为什么必须分成两层】这两个缩放是不同来源、不同诉求的：
--   * 分辨率缩放：必须自动、要夹上限、要保证不同分辨率下相对布局不变
--   * 玩家缩放：纯偏好，可能要 2 倍也可能要 0.5 倍，且随时会改
--   如果塞在同一个节点上，两次 SetScale 会互相覆盖，
--   而且玩家的缩放会突破 MAX_HUD_SCALE 的保护，
--   也会破坏「外层按分辨率算好的锚点」。
-- 【实现技巧】第 545-552 行把 8 个字段各自 AddChild 一个空 Widget 再赋值回去，
--   之后全工程（含 OnUpdate、SetHUDSize）都只用新绑定的内层，
--   外层完全隐形 —— 典型的「封装掉中间层」。
-- 【移植要点】自研引擎照抄这个两层结构即可，比做一整套布局系统省事得多：
--   外层算分辨率，内层算偏好，乘起来就是最终缩放。
    self.topleft_root = self.topleft_root:AddChild(Widget("tl_scale_root"))
    self.topright_root = self.topright_root:AddChild(Widget("tr_scale_root"))
    self.bottom_root = self.bottom_root:AddChild(Widget("bottom_scale_root"))
    self.top_root = self.top_root:AddChild(Widget("top_scale_root"))
    self.left_root = self.left_root:AddChild(Widget("left_scale_root"))
    self.right_root = self.right_root:AddChild(Widget("right_scale_root"))
    self.bottomright_root = self.bottomright_root:AddChild(Widget("br_scale_root"))
    self.topright_over_root = self.topright_over_root:AddChild(Widget("tr_over_scale_root"))
end

function Controls:SetHUDSize()
-- ★★ 按当前偏好重算所有节点的缩放。两种缩放来源：
--   scale            —— 全局 HUD 缩放（TheFrontEnd:GetHUDScale()）
--   crafting_scale   —— 制作面板专用缩放（独立设置，默认为 1）
-- 【调用时机】构造末尾（第 415 行）+ OnUpdate 里检测到分辨率变化时（第 609 行）。
--   即「改设置要手动重算、改窗口大小由轮询自动重算」两条路径都汇到这里。
    local scale = TheFrontEnd:GetHUDScale()
	local crafting_scale = TheFrontEnd:GetCraftingMenuScale()

    self.topleft_root:SetScale(scale)
-- 逐个把 scale 应用到 8 个挂载点 + 5 个容器根。
-- 【为什么容器根也要单独设】containerroot 系列不在 MakeScalingNodes 的 8 点之内，
--   但它们同样有 PROPORTIONAL 缩放模式，所以必须显式对齐，否则容器 UI 会
--   和 HUD 主体比例不一致（表现为打开箱子时物品栏比例突变）。
    self.topright_root:SetScale(scale)
    self.bottom_root:SetScale(scale)
    self.top_root:SetScale(scale)
    self.bottomright_root:SetScale(scale)
    self.containerroot:SetScale(scale)
	self.containerroot_under:SetScale(scale)
	self.containerroot_over:SetScale(scale)
    self.containerroot_side:SetScale(scale)
    self.containerroot_side_behind:SetScale(scale)

    self.hover:SetScale(scale)
    self.topright_over_root:SetScale(scale)

    self.mousefollow:SetScale(scale)
    
    local consoleScale = 1.0
-- 主机（console）缩放修正：PS5 屏幕小，硬币轮盘要缩到 0.65 才放得下。
-- 【注意这是个平台特判而非通用配置】只有 PS5 命中，其它主机（Xbox/Switch）
--   保持 1.0。移植时这类硬编码平台判断建议改成配置表。
    if IsPS5() then
        consoleScale = .65
    end
    if not IsConsole() or not TheSim:GetIsSplitScreen() then
-- 条件等价于「非主机 或 非分屏」，即：只有在「主机 + 分屏」时才不缩放。
-- 【为什么主机+分屏 要跳过】分屏时每个玩家的可视区域只有半屏，
--   轮盘又已经被 BuildCommandWheel 按 1.6 放大过（第 1154 行），
--   再乘一次缩放会大到出屏。此处跳过避免二次放大。
-- ⚠️ 这行同时体现了「缩放逻辑分散在两个函数里」的维护成本：
--   命令轮盘的最终缩放 = 第 1154 行的 ×1.6 × 本行的 scale，两处必须配套改。
		self.commandwheel:SetScale(consoleScale * scale)
	end
    if self.desync ~= nil then
        self.desync:SetScale(scale)
    end

	if IsGameInstance(Instances.Player1) then
-- ★ 制作面板缩放只给「我这个玩家所在的那一侧」，另一侧保持普通缩放。
-- 【为什么需要这么细】左右两侧分属不同玩家，1 号玩家的制作面板在左边，
--   2 号玩家的在右边，各自的 UI 密度需求不同。
-- 【与第 301-305 行呼应】那里决定菜单挂哪边，这里决定哪边吃 crafting_scale，
--   两处必须用同一个 IsGameInstance(Instances.Player1) 判断，否则菜单会缩错。
		self.left_root:SetScale(crafting_scale)
	    self.right_root:SetScale(scale)
	else
		self.left_root:SetScale(scale)
	    self.right_root:SetScale(crafting_scale)
	end

    self.owner.HUD.inst:PushEvent("refreshhudsize", scale)
-- ★ 把最终 scale 广播出去。PushEvent 是 UI 层的事件总线。
-- 【为什么需要广播】有些控件的缩放不在 Controls 管理范围内（如 world 里的
--   血条/数字），它们各自订阅 "refreshhudsize" 来跟着变。
-- 【移植要点】一套 UI 缩放要覆盖全屏所有元素时，「改完设置广播一次事件」
--   比让每个元素去轮询设置项更省 CPU，也更不容易漏改。
end

function Controls:OnUpdate(dt)
-- ★★★ OnUpdate：每帧执行一次（构造末尾 StartUpdating 开启）。
-- 【回答「有没有目标状态 vs 当前状态的平滑过渡」】
--   ★ 没有。整段代码（约 310 行）没有任何插值、缓动或 lerp。
--   它做的是「每帧从零重算一遍提示文字和位置，然后整块覆盖」。
--   换句话说这是无状态渲染，不是状态机驱动 —— 状态机在 Show*/Hide* 系列里。
-- 【这种设计的取舍】
--   优点：绝对幂等，任何一帧被打断/丢帧都不会导致 UI 状态错乱，
--         也不需要处理「第 N 帧该显示什么」的中间态，代码好调试。
--   缺点：每帧都重算字符串拼接（table.concat + SetString），有持续 CPU 开销；
--         且天然不支持渐变动画 —— 要动画只能在 SetString 前套 UIAnim。
--   对自研游戏：提示类 UI 值得照抄这个「无状态重算」思路；
--   但真正的大面板（背包、商店）别这么写，应该缓存 diff 后按需更新。
    if PerformingRestart then
-- 重启世界（回档）期间直接清掉所有提示的跟随目标并提前返回。
-- 【为什么只清 target 而不 Hide】回档过程中 TheWorld 正在重建，
--   此时继续跑下面的逻辑会因为 TheWorld 为 nil 而崩溃。提前 return 是最省的防御。
-- ★ 这个 early-return 模式在 UI 每帧回调里非常常用：
--   「进入异常状态就什么都不做」，比在每个访问点写 if TheWorld ~= nil 更稳。
        self.playeractionhint:SetTarget(nil)
        self.playeractionhint_itemhighlight:SetTarget(nil)
        self.attackhint:SetTarget(nil)
        self.groundactionhint:SetTarget(nil)
        return
    end

    local scrnw, scrnh = TheSim:GetScreenSize()
-- ★ 分辨率变化检测。DST 没有窗口 resize 事件，只能每帧轮询比对。
-- 【代价】每帧一次 TheSim:GetScreenSize() 调用。可忽略，但说明这是兜底轮询而非事件驱动。
-- 【为什么不用事件】窗口大小变化在 DST 里可能来自多途径（系统拖拽、
--   主机 TV 安全区变化、UI 缩放设置），统一走轮询最省事。
    if scrnw ~= self._scrnw or scrnh ~= self._scrnh then
        self._scrnw, self._scrnh = scrnw, scrnh
        self:SetHUDSize()
    end

    local controller_mode = TheInput:ControllerAttached()
-- 手柄模式判定。后续一大段逻辑（第 615-847 行）只在手柄下执行。
-- 【重要背景】这 230 多行代码只为「手柄玩家怎么用」服务，
--   键鼠玩家走的是第 838-847 行的 else 分支，全部隐藏。
--   —— 这是理解本文件的关键：OnUpdate 里绝大部分复杂度来自手柄适配。
    local controller_id = TheInput:GetControllerID()

    if controller_mode then
-- 手柄模式下隐藏小地图按钮（用手柄导航去按小地图不方便），并清除其焦点。
-- 【Show/Hide 与 ClearFocus 必须成对】只隐藏控件不清理焦点，
--   会留下一个「看不见但仍能接收手柄导航」的幽灵焦点。
--   这是 UI 适配输入方式切换时最常见的 bug 类型。
        self.mapcontrols:Hide()
		if self.mapcontrols.focus then
			self.mapcontrols:ClearFocus()
		end
    else
        self.mapcontrols:Show()
    end

    for k,v in pairs(self.containers) do
-- ★★ 容器的延迟回收。容器自己置 should_close_widget 标志，
-- 在这里（下一帧）统一从注册表摘除并 Kill。
-- 【为什么要延迟一帧，而不是容器请求关闭时立刻 Kill】
--   因为请求关闭的代码常常正跑在容器的动画回调或事件处理里，
--   当场 Kill 自己会导致「遍历中的列表被修改」。
-- 【移植要点】「标记 - 下帧回收」是 UI/场景管理里处理自销毁的标准手法，
--   写引擎时把这类回收做成统一的 GC 队列，能省掉无数个这类 bug。
-- ⚠️ 遍历时直接写 self.containers[k] = nil 在 Lua 里是安全的（官方明确允许），
--   但依赖了「pairs 允许给已有键赋 nil」这一条，实现自己引擎的容器时要记得对齐。
        if v.should_close_widget then
            self.containers[k] = nil
            v:Kill()
        end
    end

    --[[if false and self.demotimer then
        if IsGamePurchased() then
            self.demotimer:Kill()
            self.demotimer = nil
        end
    end]]

    local shownItemIndex = nil
-- ★ shownItemIndex / itemInActions 是「当前高亮第几行」的输出变量，
-- 末尾（第 907 行）传给 HighlightActionItem 使用。
-- 【itemInActions 的含义】true = 高亮行在 playeractionhint 里，
--   false = 在 groundactionhint 里。提示可能挂在两块不同气泡上，
--   高亮必须知道去哪块取。
    local itemInActions = false     -- the item is either shown through the actionhint or the groundaction

    if controller_mode and not (self.inv.open or self.commandwheel.isopen or self.craftingmenu:IsCraftingOpen() or self.spellwheel:IsOpen()) and self.owner:IsActionsVisible() then
-- ★★★ 手柄提示的总开关：一个超长复合条件。拆开看五道门：
--   1) controller_mode —— 必须是手柄
--   2) inv / commandwheel / craftingmenu / spellwheel 都未开
--      ★ 即「没有任何大面板打开」时才显示提示。
--      这是防止 UI 互相污染的关键：轮盘打开时不显示按键提示，
--      否则提示文字会盖在轮盘上，且会和轮盘的输入冲突。
--   3) owner:IsActionsVisible() —— 玩家状态是否允许显示操作
-- 【移植要点】第 2 条那组「互斥检查」应当抽成一个通用的
--   「当前有模态面板吗」查询，而不是每处手写 —— 现在是手写的，容易漏。
        local ground_l, ground_r = self.owner.components.playercontroller:GetGroundUseAction()
        local ground_cmds = {}
        local isplacing = self.owner.components.playercontroller.deployplacer ~= nil or self.owner.components.playercontroller.placer ~= nil
-- isplacing = 玩家正在放置 terraformer/placer 类物件。
-- ⚠️ 注意第 646 行：local placer = self.terraformplacer
--   本文件内 self.terraformplacer 从未被赋值（全文仅第 646 行出现一次），
--   因此 placer 恒为 nil；而下面第 648-672 行用的是 playercontroller.placer，
--   不是这个局部变量。所以第 646 行是彻底的残留死代码。
--   同样，变量 plac此后（第 646-719 行）从未被读取。
--   【移植提醒】这类「改了变量名忘了删旧声明」的死代码，
--   在 Lua 里无害但会误导读者以为有个全局配置项。
        if isplacing then
            local placer = self.terraformplacer

            if self.owner.components.playercontroller.deployplacer ~= nil then
                self.groundactionhint:Show()
                self.groundactionhint:SetTarget(self.owner.components.playercontroller.deployplacer)

                local strs = {}
-- ★ 拼「按键提示」文本的通用套路，全文件出现十余次：
--   TheInput:GetLocalizedControl(controller_id, CONTROL_XXX) —— 按当前手柄/键位映射
--     把抽象的 CONTROL_XXX 转成实际按键提示文字（Xbox 是「Y」，PS 是「△」）。
--   .. ".." 拼上动作说明。
-- 【为什么必须走 GetLocalizedControl 而不能硬编码按键】
--   同一份 Lua 要同时跑键鼠 / Xbox / PS / Switch / 主机 TV，
--   按键图标和布局完全不同。只有通过控制 ID 查询才能正确本地化。
--   ★ 这是移植 UI 到多平台时最容易忽略的一层抽象。
                if self.owner.components.playercontroller:IsAxisAlignedPlacement() then
                    table.insert(strs, TheInput:GetLocalizedControl(controller_id, CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID).." "..STRINGS.UI.HUD.CYCLE_AXIS_ALIGNED_PLACEMENT)
                end
                if self.owner.components.playercontroller.deployplacer.components.placer.can_build then
                    table.insert(strs, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ACTION) .. " " .. self.owner.components.playercontroller.deployplacer.components.placer:GetDeployAction():GetActionString())
                end
                table.insert(strs, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION).." "..STRINGS.UI.HUD.CANCEL)
                self.groundactionhint.text:SetString(table.concat(strs, "\n"))

            elseif self.owner.components.playercontroller.placer ~= nil then
                self.groundactionhint:Show()
                self.groundactionhint:SetTarget(self.owner)
                local strs = {}
                if self.owner.components.playercontroller:IsAxisAlignedPlacement() then
                    table.insert(strs, TheInput:GetLocalizedControl(controller_id, CONTROL_AXISALIGNEDPLACEMENT_CYCLEGRID).." "..STRINGS.UI.HUD.CYCLE_AXIS_ALIGNED_PLACEMENT)
                end
                table.insert(strs, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ACTION) .. " " .. STRINGS.UI.HUD.BUILD)
                table.insert(strs, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION) .. " " .. STRINGS.UI.HUD.CANCEL)
                self.groundactionhint.text:SetString(table.concat(strs, "\n"))
            end
        else
            local aoetargeting = self.owner.components.playercontroller:IsAOETargeting()
            if ground_r ~= nil then
                if ground_r.action ~= ACTIONS.CASTAOE then
                    table.insert(ground_cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION).." "..ground_r:GetActionString())
                elseif aoetargeting then
                    table.insert(ground_cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ACTION).." "..ground_r:GetActionString())
                end
            end
            if aoetargeting then
                table.insert(ground_cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION).." "..STRINGS.UI.HUD.CANCEL)
            end
            if #ground_cmds > 0 then
                self.groundactionhint:Show()
                self.groundactionhint:SetTarget(self.owner)
                self.groundactionhint.text:SetString(table.concat(ground_cmds, "\n"))
            else
                self.groundactionhint:Hide()
            end
        end

        local attack_shown = false
        local controller_target = self.owner.components.playercontroller:GetControllerTarget()
        local controller_attack_target = self.owner.components.playercontroller:GetControllerAttackTarget()
        local l, r
        if controller_target ~= nil then
            l, r = self.owner.components.playercontroller:GetSceneItemControllerAction(controller_target)
        end

        if not isplacing and l == nil and ground_l == nil then
            ground_l = self.owner.components.playercontroller:GetGroundUseSpecialAction(nil, false)
            if ground_l ~= nil then
                table.insert(ground_cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ACTION).." "..ground_l:GetActionString())
                self.groundactionhint:Show()
                self.groundactionhint:SetTarget(self.owner)
                self.groundactionhint.text:SetString(table.concat(ground_cmds, "\n"))
            end
        end
        if not isplacing and r == nil and ground_r == nil then
            ground_r = self.owner.components.playercontroller:GetGroundUseSpecialAction(nil, true)
            if ground_r ~= nil then
                table.insert(ground_cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION).." "..ground_r:GetActionString())
                self.groundactionhint:Show()
                self.groundactionhint:SetTarget(self.owner)
                self.groundactionhint.text:SetString(table.concat(ground_cmds, "\n"))
            end
        end

        if controller_target ~= nil then
            local cmds, cmdsoffset
            local textblock = self.playeractionhint.text
            local keepgroundactionhint = ground_l and ground_l.action.keepgroundactionhint or ground_r and ground_r.action.keepgroundactionhint
            if self.groundactionhint.shown and not keepgroundactionhint and distsq(self.owner:GetPosition(), controller_target:GetPosition()) < 1.33 then
-- ★★ 距离阈值 1.33（平方距离，即约 1.15 个世界单位）——
-- 当玩家已经站得离目标很近时，把「地面操作提示」和「目标操作提示」
-- 合并成一块显示，避免两块气泡在屏幕上叠在一起。
-- 【为什么用 distsq 而不是 dist】平方距离省掉一次 sqrt，
--   而且比较的是平方值不影响判断结果 —— 性能敏感的每帧代码里的常规优化。
-- 【keepgroundactionhint 是什么】某些动作自己声明「即使离得近也要保留地面提示」
--   （第 724 行）。这是给动作表的扩展位：动作可自定义 UI 呈现方式。
                --You're close to your target so we should combine the two text blocks.
                cmds = ground_cmds
                cmdsoffset = #cmds
                textblock = self.groundactionhint.text
                self.playeractionhint:Hide()
                itemInActions = false
            else
                cmds = {}
                cmdsoffset = 0
                self.playeractionhint:Show()
                self.playeractionhint:SetTarget(controller_target)
                itemInActions = true
            end

            local adjective = controller_target:GetAdjective()
-- 第 741 行：在目标名前面加形容词（「燃烧的」「巨大的」）。
-- 用 a ~= nil and (a.." "..name) or name 这种模式 ——
-- 【⚠️ 这个 idiom 有陷阱】`x and A or B` 在 A 为 false/nil 时会退化成 B。
--   此处安全是因为 A 是字符串拼接结果，恒为真字符串。
--   移植时若把 B 设成可能被置空的表达式（如 someObj or ""），
--   就会出「该显示的时候变空」的 bug。正确写法是 if/else 三元。
-- 第 742 行：记录「第几行是目标名」，供末尾的高亮使用。
            table.insert(cmds, adjective ~= nil and (adjective.." "..controller_target:GetDisplayName()) or controller_target:GetDisplayName())
            shownItemIndex = #cmds

            if controller_target == controller_attack_target then
-- 只有「高亮目标」与「攻击目标」是同一个实体时，才在此处追加攻击提示。
-- 【为什么要比对两个目标】手柄有「准星指向」和「实际锁定攻击」两个概念，
--   指向石头但没瞄准它，就不该显示攻击键 —— 否则提示会骗人。
--   attack_shown 置位后，第 830 行就不会再单独弹 attackhint，
--   避免同一个提示显示两遍。
                table.insert(cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ATTACK) .. " " .. STRINGS.UI.HUD.ATTACK)
                attack_shown = true
                
			    if self.owner.components.playercontroller:CanLockTargets() and not self.owner.components.playercontroller:IsControllerTargetLocked() then
                    table.insert(cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_TARGET_LOCK) .. " " .. STRINGS.UI.HUD.LOCK_TARGET)
			    end
            end
            if (self.owner.CanExamine == nil or self.owner:CanExamine()) and
-- 「检视」提示的六重资格判断。任一不满足就不显示，
-- 逐条拆解（这组条件是「UI 不显示误导信息」的教科书）：
--   owner:CanExamine()             —— 玩家状态允许检视（如不在死亡动画中）
--   not HUD:IsPlayerAvatarPopUpOpen() —— 角色面板开着时让位（注释标 V2C）
--   not IsControllerTargetLocked() —— 已锁定目标时改用解锁键，不再重复
--   sg / entity 双重状态检查       —— 必须在 idle/moving/channeling
--   controller_target:HasTag("inspectable") —— 目标本身允许被检视
-- 【★ 双重状态检查（第 756-757 行）值得学】
--   状态图（sg，权威预测）和实体标签（客户端可见）要都通过才显示。
--   只看其中一个会在联机时出现「本地以为能动、实际服务端不让动」的鬼提示。
                --V2C: Closing the avatar popup takes priority
                not self.owner.HUD:IsPlayerAvatarPopUpOpen() and
                not self.owner.components.playercontroller:IsControllerTargetLocked() and
				(self.owner.sg == nil or self.owner.sg:HasStateTag("moving") or self.owner.sg:HasStateTag("idle") or self.owner.sg:HasStateTag("channeling")) and
				(self.owner:HasTag("moving") or self.owner:HasTag("idle") or self.owner:HasTag("channeling")) and
                controller_target:HasTag("inspectable") then
				local actionstr =
-- 同一动作的两种措辞：如果检视动作会「关掉当前面板」，提示就变成"关闭检视"。
-- 【这是纯 UI 层的动态文案】同一套按键逻辑，因上下文给出更准确的动词。
--   移植时的通用做法：让提示文案接受一个「动词提供器」，而不是硬编码字符串。
					CLOSEINSPECTORUTIL.CanCloseInspect(self.owner, controller_target) and
					STRINGS.ACTIONS.LOOKAT.CLOSEINSPECT or
					STRINGS.UI.HUD.INSPECT
				table.insert(cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_INSPECT).." "..actionstr)
            end
            if l ~= nil then
                table.insert(cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ACTION) .. " " .. l:GetActionString())
            end
            if r ~= nil and ground_r == nil then
                table.insert(cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION) .. " " .. r:GetActionString())
            end
			if self.owner.components.playercontroller:IsControllerTargetLocked() then
                table.insert(cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_TARGET_LOCK) .. " " .. STRINGS.UI.HUD.UNLOCK_TARGET)
                table.insert(cmds, TheInput:GetLocalizedControl(controller_id, CONTROL_TARGET_CYCLE) .. " " .. STRINGS.UI.HUD.NEXT_TARGET)
			end
            if controller_target.quagmire_shoptab ~= nil then
                for k, v in pairs(self.craftingmenu.tabs.shown) do
                    if k.filter == controller_target.quagmire_shoptab then
                        if v then
                            table.insert(cmds, TheInput:GetLocalizedControl(TheInput:GetControllerID(), CONTROL_OPEN_CRAFTING).." "..STRINGS.UI.CRAFTING.TABACTION[controller_target.quagmire_shoptab.str])
                        end
                        break
                    end
                end
            end

            if #cmds - cmdsoffset <= 1 then
-- ★ 特殊情况：目标存在但一个可用操作都没有 → 不显示气泡，只把目标名
-- 单独显示（用目标自己的 DisplayName，不带按键前缀）。
-- 【为什么值得特殊处理】空的气泡会显示成一个空框，比什么都不显示更糟。
--   cmdsoffset 是「合并显示时地面提示已占用的行数」，
--   减掉它才能算清「目标自己」贡献了几行 —— 这是合并显示的记账方式。
                --New special case that we support:
                -- target is highlighted but with no actions
                -- -> suppress any ground action hints
                -- -> use target's custom display name to show special action hint
                -- But keep it around if the action really wants it anyway.
                if cmds ~= ground_cmds and not keepgroundactionhint then
                    self.groundactionhint:Hide()
                    self.groundactionhint:SetTarget(nil)
                end
                textblock:SetString(cmds[#cmds])
            else
                textblock:SetString(table.concat(cmds, "\n"))
            end
		elseif not self.groundactionhint.shown then
-- ★ 没有对准任何目标时的三选一优先级：
--   1) 骑乘且容器打开 → 提示「翻找」（ rummage ）
--   2) 有法术书且可用 → 提示「使用法术书」
--   3) 在坐骑上     → 提示「下马」
--   都不满足 → 隐藏
-- 【优先级即业务重要性】翻找 > 法术书 > 下马。三者互斥（骑乘开容器时不可能用书）。
--   写成 if/elseif 链而不是三个独立 if，保证只出现一条提示。
				local rider = self.owner.replica.rider
			local mount = rider and rider:GetMount() or nil
			local container = mount and mount.replica.container or nil
			if container and container:IsOpenedBy(self.owner) then
				self.playeractionhint.text:SetString(TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION).." "..BufferedAction(self.owner, self.owner, ACTIONS.RUMMAGE):GetActionString())
				self.playeractionhint:Show()
				self.playeractionhint:SetTarget(self.owner)
			elseif self.dismounthintdelay <= 0 then
				if self.owner.components.spellbook and self.owner.components.spellbook:CanBeUsedBy(self.owner) then
					self.playeractionhint.text:SetString(TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION).." "..BufferedAction(self.owner, self.owner, ACTIONS.USESPELLBOOK):GetActionString())
					self.playeractionhint:Show()
					self.playeractionhint:SetTarget(self.owner)
				elseif mount and not (self.owner.components.playercontroller and self.owner.components.playercontroller:HasAOETargeting()) then
					self.playeractionhint.text:SetString(TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ALTACTION).." "..STRINGS.ACTIONS.DISMOUNT)
					self.playeractionhint:Show()
					self.playeractionhint:SetTarget(self.owner)
				else
					self.playeractionhint:Hide()
					self.playeractionhint:SetTarget(nil)
				end
			else
				self.playeractionhint:Hide()
				self.playeractionhint:SetTarget(nil)
			end
		else
			self.playeractionhint:Hide()
			self.playeractionhint:SetTarget(nil)
        end

        if controller_attack_target ~= nil and not attack_shown then
            self.attackhint:Show()
            self.attackhint:SetTarget(controller_attack_target)
            self.attackhint.text:SetString(TheInput:GetLocalizedControl(controller_id, CONTROL_CONTROLLER_ATTACK) .. " " .. STRINGS.UI.HUD.ATTACK)
        else
            self.attackhint:Hide()
            self.attackhint:SetTarget(nil)
        end
    else
        self.attackhint:Hide()
        self.attackhint:SetTarget(nil)

        self.playeractionhint:Hide()
        self.playeractionhint:SetTarget(nil)

        self.groundactionhint:Hide()
        self.groundactionhint:SetTarget(nil)
    end

	if self.owner.sg and not self.owner.sg:HasStateTag("idle") or not self.owner:HasTag("idle") then
-- ⚠️ 运算符优先级陷阱（已对照 Lua 优先级核实）：
--   条件写的是 A and B or C，其中 A=sg 存在、B=sg 非 idle、C=实体非 idle。
--   ★ Lua 里 and 的优先级高于 or，所以实际解析为 (A and B) or C，
--     而不是直觉上的 (A and B) and C，也不是 (A or B) and C。
--   效果上：只要 sg 存在且非 idle，条件就短路为真，实体侧的状态完全不看；
--   当 sg 为 nil 时退化成只看实体标签。
--   【本意推测】作者想写的应是「本地状态图非 idle 或实体标签非 idle」——
--     按当前写法结果恰好接近，所以功能上没暴露问题。
--   【移植提醒】混合 and/or 且不加括号是 Lua 里最容易出隐性 bug 的写法。
--     任何跨过两行的复合条件都必须补括号，写清分组。
-- 第 850 行：非 idle 时把冷却直接顶到 0.5 秒（而非累加），保证「停手后至少等 0.5 秒」
--   才允许再提示下马 —— 防止玩家在跑动中反复看到卸马提示闪烁。
-- 第 852 行：只有在 idle 时才递减。这是典型的「用同一个计时器表达冷却窗口」。
        self.dismounthintdelay = .5
    elseif self.dismounthintdelay > 0 then
        self.dismounthintdelay = self.dismounthintdelay - dt
    end

    --default offsets
    self.playeractionhint:SetScreenOffset(0,0)
-- ★★ 每帧先把两个气泡的屏幕偏移重置为 (0,0)，再在后面按需追加偏移。
-- 【★ 这是全文件最重要的排版约定】因为 SetScreenOffset 是「绝对设置」而非「增量」，
--   第 868 行的高尔夫偏移、第 897-902 行的避让偏移都建立在「本帧刚被清零」的前提上。
--   ★ 【移植陷阱】漏掉这两行 → 偏移会每帧累加，气泡会飞出屏幕。
--   如果把这里改成增量式（offset += delta），就必须同时删掉后面所有的重置假设。
    self.attackhint:SetScreenOffset(0,0)

    -- Move tool tip to be behind player so it doesnt obstruct the reticule.
-- 【为什么要给提示偏移】打高尔夫时准星和操作提示会重叠，
--   这里把提示挪到目标的「反方向」，让准星保持干净可见。
-- 第 866 行 math.atan2(sy-psy, psx-sx) ——
--   ★ 注意参数的顺序习惯：这里 dy 传的是「目标的 y 减玩家的 y」，
--     dx 传的是「玩家的 x 减目标的 x」，两个方向相反。
--     所以下面的偏移用 cos 配 x、sin 配 100-y，是配套这个反向的。
--     改动任一处符号都会让提示跑到目标的另一侧，别单独调。
-- 第 868 行 100 - math.sin(theta)*h —— 100 是气泡的基础高度偏移，
--   与第 66/71/76/81 行的 SetOffset(0,100,0) 是同一个基准。
    if self.owner.replica.inventory then
        local handitem = self.owner.replica.inventory:GetEquippedItem(EQUIPSLOTS.HANDS)
        local golfclub_reticule = handitem and handitem.components.golfclub_reticule
        if self.playeractionhint.shown and golfclub_reticule and golfclub_reticule:GetTarget() then
            local psx, psy = TheSim:GetScreenPos(self.owner.Transform:GetWorldPosition())
            local sx, sy = TheSim:GetScreenPos(golfclub_reticule:GetTarget().Transform:GetWorldPosition())
            local theta = math.atan2(sy - psy, psx - sx)
            local w, h = self.playeractionhint.text:GetRegionSize()
            self.playeractionhint:SetScreenOffset(math.cos(theta) * w, 100 - math.sin(theta) * h)
        end
    end

    --if we are showing both hints, make sure they don't overlap
-- ★★ 两块气泡同时显示时的水平避让。整体思路：
--   1) 先用 AABB 相交测试判断是否重叠（第 883-886 行）
--   2) 重叠则各向一侧推开半个间距（第 895-903 行）
-- 【为什么不用布局引擎】DST 没有约束求解器，就靠这种「测重叠 → 手动推开」
--   的土办法。对 2 个矩形够用；要排 N 个元素就得自己写简单的碰撞消解了。
--   【★ 移植建议】如果你的 UI 元素会超过 3-4 个，就别抄这个了，
--   直接写个一维/网格布局器，长期维护成本更低。
    if self.attackhint.shown and self.playeractionhint.shown then

        local w1, h1 = self.attackhint.text:GetRegionSize()
        local x1, y1 = self.attackhint:GetPosition():Get()
        --print (w1, h1, x1, y1)

        local w2, h2 = self.playeractionhint.text:GetRegionSize()
        local x2, y2 = self.playeractionhint:GetPosition():Get()
        --print (w2, h2, x2, y2)

        local sep = (x1 + w1/2) < (x2 - w2/2) or
-- ★ 重叠判定：两个矩形「分离」的充要条件是 x 方向或 y 方向至少一方不相交。
--   四个 or 分支分别对应：a 在 p 左边 / a 在 p 右边 / a 在 p 上方 / a 在 p 下方。
-- 【严格不等号】用 < 和 > 而不是 <= ，两个边界刚好相接时算「不重叠」，
--   不会触发无谓的推开抖动。
-- ⚠️ 这里的矩形用 GetRegionSize（文字区域）而非气泡的视觉尺寸，
--   所以留白被忽略、气泡实际可能已经贴上了。属于可接受的近似。
                    (x1 - w1/2) > (x2 + w2/2) or
                    (y1 + h1/2) < (y2 - h2/2) or
                    (y1 - h1/2) > (y2 + h2/2)

        if not sep then
            local a_l = x1 - w1/2
            local a_r = x1 + w1/2

            local p_l = x2 - w2/2
            local p_r = x2 + w2/2

            if math.abs(p_r - a_l) < math.abs(p_l - a_r) then
-- ★ 选择推开方向：比较两个候选间距，取小的那个 —— 即「从重叠较浅的那侧挤出去」。
--   math.abs(p_r - a_l) 是「p 的右边缘压进 a 左边缘」的深度；
--   math.abs(p_l - a_r) 是「p 的左边缘压进 a 右边缘」的深度。
-- 【第 896 行的 20】额外留 20 像素间隙，避免推开后两段文字几乎贴死。
-- 【为什么各推一半】d/2 与 -d/2 让两块保持相对位置稳定，
--   不会一块贴边、一块悬在中间。
-- ⚠️ 注意这里的两处 SetScreenOffset 是「覆盖」而非「叠加」（见第 856 行），
--   所以高尔夫偏移（第 868 行）在触发避让时会被丢掉。
--   当前场景下二者互斥影响不大，但移植时若要同时生效需改成叠加。
                local d = (p_r - a_l) + 20
                self.attackhint:SetScreenOffset(d/2,0)
                self.playeractionhint:SetScreenOffset(-d/2,0)
            else
                local d = (a_r - p_l) + 20
                self.attackhint:SetScreenOffset( -d/2,0)
                self.playeractionhint:SetScreenOffset(d/2,0)
            end
        end
    end

    self:HighlightActionItem(shownItemIndex, itemInActions)
-- 每帧最后一步：把「高亮第几行」的结果应用到高亮层。
-- 放在 OnUpdate 最末尾是因为前面的所有分支可能已经改写了 shownItemIndex。
end

function Controls:DelayControllerSpellWheelHint()
	self.dismounthintdelay = 0.5
end

function Controls:HighlightActionItem(itemIndex, itemInActions)
-- ★★ 高亮某个操作的实现。技巧值得学：
-- 【不用富文本】提示是纯 Text，不支持局部着色。
--   这里的做法是「文字挖洞」：主气泡照常显示全部行，但把要高亮的那行
--   替换成空格（第 936 行）；另有一个完全重叠的高亮气泡，
--   只显示那一行、有颜色（第 942 行）。两者叠在一起 = 那一行被高亮。
-- 【为什么这个方案比富文本好】不需要把 Text 升级成富文本控件，
--   也不用重排布局；代价是两个气泡必须像素级对齐。
-- 【itemIndex 为 nil 时】直接隐藏高亮层（第 948-950 行）—— 收敛到无高亮的常态。
    if itemIndex then
        local followerWidget
        if itemInActions then
            followerWidget = self.playeractionhint
        else
            followerWidget = self.groundactionhint
        end
        self.playeractionhint_itemhighlight:Show()
        local offsetx, offsety = followerWidget:GetScreenOffset()
-- ★ 高亮层必须复制主气泡的屏幕偏移（读第 856-905 行算出来的结果），
-- 否则两块会错位，「挖洞」露出背景。
-- 这行是「两块必须同步」约束的体现：任何改动偏移的代码都要考虑同步。
        self.playeractionhint_itemhighlight:SetScreenOffset(offsetx, offsety)
        self.playeractionhint_itemhighlight:SetTarget(followerWidget.target)

        local str = followerWidget.text.string
        local itemlines = {}
        local commandlines = {}
        local target = self.owner.components.playercontroller.controller_target
-- ⚠️ 注意这里读的是 playercontroller.controller_target 这个「原始字段」，
--   而不是前面第 695 行用的 GetControllerTarget() 访问器。
--   二者不等价：GetControllerTarget（playercontroller.lua:3624）会额外检查
--   IsValid()，把失效实体转成 nil。
--   此处绕过了有效性检查，第 943 行直接 target:GetIsWet() 调用，
--   若实体此刻刚好失效则可能对无效实体调方法。
--   实际风险不高（itemIndex 非空意味着本帧刚取过 GetControllerTarget），
--   但属于「同一份状态用了两种读法」的隐患，移植时建议统一走访问器。
        for idx,line in ipairs(string.split(str, "\n")) do
            if idx==itemIndex then
                itemlines[#itemlines+1] = line
                commandlines[#commandlines+1]= " "
            else
                itemlines[#itemlines+1] = " "
                commandlines[#commandlines+1] = line
            end
        end
        followerWidget.text:SetString(table.concat(commandlines,"\n"))

        self.playeractionhint_itemhighlight.text:SetString(table.concat(itemlines,"\n"))
        if target:GetIsWet() then
            self.playeractionhint_itemhighlight.text:SetColour(unpack(WET_TEXT_COLOUR))
        else
            self.playeractionhint_itemhighlight.text:SetColour(unpack(NORMAL_TEXT_COLOUR))
        end
    else
        self.playeractionhint_itemhighlight:Hide()
    end
end

function Controls:ShowMap(world_position)
-- ★★★ ShowMap(world_position)：打开地图。world_position 非空时顺带把地图移到该点。
-- 【幂等守卫】第 954 行要求「当前地图没开」才继续 —— 重复调用不会叠出两层地图。
-- ★ 幂等守卫是本文件所有 Show*/Hide* 的统一套路：
--   函数先检查自己的状态位，已是目标状态就直接返回。
--   好处是调用方不必判断「该不该调」，随便调即可，
--   且中途被打断也不会把状态改乱。
-- 【注意 quagmire 分支】第 955-959 行推的是 QuagmireRecipeBookScreen（配方书），
--   不是真地图 —— 那个模式下「地图键」被复用成「配方书键」。
    if self.owner ~= nil and self.owner.HUD ~= nil and (not self.owner.HUD:IsMapScreenOpen()) then
		if TheNet:GetServerGameMode() == "quagmire" then
			if self.owner.HUD:IsStatusScreenOpen() then
				TheFrontEnd:PopScreen()
			end
			TheFrontEnd:PushScreen(QuagmireRecipeBookScreen(self.owner))
		elseif not GetGameModeProperty("no_minimap") then
-- ★ 游戏模式属性 no_minimap 关掉小地图。
-- 【GetGameModeProperty 的意义】同一份客户端 Lua 跑不同服务端模式，
--   行为差异全部通过「查服务端模式属性」表达，而不是编译期分支。
--   移植多模式游戏时，这个「服务端下发能力位、客户端查能力位」的模式
--   比在客户端 if 里硬编码判断好得多。
-- 第 961-963 行：若状态屏开着先 PopScreen ——
--   ★ 必须先关掉旧的再开新的，否则界面栈里会同时存在两张全屏屏。
--   这是全屏屏互斥的标准做法，后面 ToggleMap（第 1011 行）也照抄了它。
			if self.owner.HUD:IsStatusScreenOpen() then
				TheFrontEnd:PopScreen()
			end

			local mapscr = MapScreen(self.owner)
-- 构造地图屏并压栈。注意是每次新建对象，不复用。
-- 第 968 行 world_position ~= nil and mapscr ~= nil 中，
--   ⚠️ mapscr ~= nil 这个判断是多余的（第 965 行刚 new 出来的必非 nil），
--   属于防御性冗余。无害，但说明这里是从别处复制来的代码。
-- 【★ 回答「反复开关时坐标/缩放怎么保持」——答案是：不保持，每次重置。】
--   依据链：MapScreen 每次 new（第 965 行）→ MapWidget:OnShow（mapwidget.lua:130）
--   调 minimap:ResetOffset() 清空平移 → 若传了坐标再被第 978 行 SetZoom(1) 重置缩放。
--   所以「回到上次看的地图位置」这个功能不在这里实现，
--   坐标状态随 MapScreen 对象一起被销毁了。
			TheFrontEnd:PushScreen(mapscr)

			if world_position ~= nil and mapscr ~= nil then
				self:FocusMapOnWorldPosition(mapscr, world_position.x, world_position.z)
			end
		end
    end
end

function Controls:FocusMapOnWorldPosition(mapscreen, worldx, worldz)
-- ★★★ FocusMapOnWorldPosition：把地图中心移到指定世界坐标。
-- 【入参校验】第 976 行防御性早退：地图屏或其 minimap 未就绪就什么都不做。
--   移植注意：跨模块调用必须做这种前置校验，不能假定对方已构造完成。
	if mapscreen == nil or mapscreen.minimap == nil then return nil end

    mapscreen:SetZoom(1)
-- ★ 先把缩放重置为 1（无缩放），再算平移。
-- 【为什么必须先重置缩放】世界坐标 → 屏幕像素的换算比例依赖缩放系数，
--   若沿用玩家上次的缩放级别，算出的偏移量会整体偏大或偏小。
--   这是「先归一、再换算」的标准顺序。
-- ⚠️ 副作用：调用 ShowMap(带坐标) 会把玩家之前调好的缩放级别清掉。
--   对「打开地图看一眼某个目标」的场景合理；若要做记忆缩放，
--   应改成保存/恢复 zoom_target 而非硬置 1。

	local player_x, player_y, player_z = self.owner.Transform:GetWorldPosition()
	local dx, dy = worldx - player_x, worldz - player_z

	local angle_correction = (PI / 4) * (10 - (math.fmod(TheCamera:GetHeadingTarget() / 360, 1) * 8))
-- ★★★ 整段最烧脑的一行，值得单独拆解。
--   angle_correction = (PI/4) * (10 - (fmod(heading/360, 1) * 8))
-- 【化简】设相机朝向 heading（度），则 fmod(heading/360,1) 把朝向归一化到 [0,1)，
--   于是 8*(heading/360) = heading/45，而 (PI/4)*(heading/45) = heading 弧度。
--   ★ 所以整个式子等价于 angle_correction = 2.5*PI - heading_rad，
--     模 2PI 后就是 (-heading + PI/2) 弧度。
--   （已按 0°/45°/90° 三个点验算一致：得 2.5PI / 2.25PI / 2PI）
-- 【为什么需要这个修正】第 984-985 行按世界坐标系算出「玩家→目标」的角度 theta，
--   但小地图是随相机朝向旋转的，屏幕坐标与世界坐标之间差了一个 -heading 的旋转。
--   不加这个修正，玩家朝北看目标会往东偏。
-- 【移植要点】★ 任何「世界坐标 → 带旋转的地图坐标」的换算都要乘旋转矩阵，
--   别用裸的 cos/sin。DST 这里没有走矩阵而是手搓角度，效率更高但可读性差。
-- 第 985 行 mag 用 sqrt(dx²+dy²) 而非 hypot ——
--   距离是 2D 的（忽略 y），因为地图是俯视平面。
	local theta = math.atan2(dy, dx)
	local mag = math.sqrt(dx * dx + dy * dy)

	mapscreen.minimap:Offset(math.cos(theta + angle_correction) * mag, math.sin(theta + angle_correction) * mag)
end

function Controls:HideMap()
-- 关闭地图。守卫用 IsMapScreenOpen()，确保只 Pop 自己压的那一层。
-- 【★ 为什么必须守卫】TheFrontEnd:PopScreen() 弹的是栈顶，
--   栈顶不一定是地图（比如上面压了投票框）。不判断就弹会关错界面。
--   这是「栈式界面管理」的核心纪律：谁压的要自己负责弹。
    if self.owner ~= nil and self.owner.HUD ~= nil and self.owner.HUD:IsMapScreenOpen() then
        TheFrontEnd:PopScreen()
    end
end

function Controls:ToggleMap()
-- ★★★ ToggleMap：地图开关。与 ShowMap 的区别是它多做一层「权限校验」。
-- 【与 ShowMap 的三点差异】
--   1) ShowMap 只检查「是否已开」，ToggleMap 还要检查 IsMapControlsEnabled()
--      —— 即玩家是否有权用地图（比如死亡状态、剧情锁定时禁用）。
--   2) ShowMap 可带 world_position 聚焦，ToggleMap 不聚焦（默认开在玩家处）。
--   3) ShowMap 推的是先构造好的 mapscr 变量，ToggleMap 直接内联 new。
-- 【★ 关键发现：重复打开会丢缩放】
--   第 1014 行直接 MapScreen(self.owner)，没有走 FocusMapOnWorldPosition，
--   因此第 978 行的 SetZoom(1) 不会被调用 —— 缩放级别由 MapScreen 自身初值决定。
--   而 MapWidget:OnShow（mapwidget.lua:130）每次都会 minimap:ResetOffset()。
--   ★ 所以「ToggleMap 反复开关」时，地图每次都回到玩家居中的默认状态，
--     玩家上次的缩放/平移不会被保留。这是「不保持」策略的直接后果。
-- 【★ 状态机总结】DST 的地图状态全部编码在界面栈里（压栈=开、弹栈=关），
--   Controls 本身不存任何地图状态字段。
--   这带来一个好处：不可能出现「栈里没地图但字段说开着」的脏状态。
--   代价：无法查询/保存地图的视口状态，除非另存字段。
    if self.owner ~= nil and self.owner.HUD ~= nil then
		if TheNet:GetServerGameMode() == "quagmire" then
			if self.owner.HUD:IsMapScreenOpen() then
				TheFrontEnd:PopScreen()
			elseif self.owner.components.playercontroller ~= nil and self.owner.components.playercontroller:IsMapControlsEnabled() then
				if self.owner.HUD:IsStatusScreenOpen() then
					TheFrontEnd:PopScreen()
				end
				TheFrontEnd:PushScreen(QuagmireRecipeBookScreen(self.owner))
			end
		elseif not GetGameModeProperty("no_minimap") then
			if self.owner.HUD:IsMapScreenOpen() then
				TheFrontEnd:PopScreen()
			elseif self.owner.components.playercontroller ~= nil and self.owner.components.playercontroller:IsMapControlsEnabled() then
				if self.owner.HUD:IsStatusScreenOpen() then
					TheFrontEnd:PopScreen()
				end
				TheFrontEnd:PushScreen(MapScreen(self.owner))
			end
		end
    end
end

function Controls:DoShowCrafting_Internal()
-- ★★★ 制作界面状态机的核心：所有真正的界面操作都收敛到两个 _Internal 函数。
-- 【为什么要拆出 _Internal】因为「是否允许显示制作界面」有两个独立来源：
--   craftingshown（玩家偏好 / 权限，第 1031-1048 行操作）
--   craftingandinventoryshown（背包是否展开，第 1051-1093 行操作）
--   真正的可见性 = 两者皆真 AND 游戏模式允许。
--   外部只改状态位，由 _Internal 根据「当前完整状态」执行 Show/Hide。
--   ★ 这样就不会出现「只开了背包，制作菜单却还挂在屏幕上」的错位。
-- 第 1021 行 no_crafting 是第三道闸：特殊模式直接不给做。
	if not GetGameModeProperty("no_crafting") then
		self.craftingmenu:Show()
	end
end

function Controls:DoHideCrafting_Internal()
-- 隐藏制作的内部动作。两步都要做：
--   CloseCrafting(true) —— 通知 HUD 层关闭（会停掉相关音效/逻辑）
--   craftingmenu:Hide()  —— 隐藏控件本身
-- 【为什么两步分开】控件 Hide 只管视觉，HUD 还要清理输入焦点等状态。
--   只做视觉隐藏会让隐藏的界面仍然拦截输入。
-- ⚠️ 对比第 1021 行：DoShow 有模式检查，DoHide 没有 —— 这是对的，
--   「不允许显示」时隐藏操作仍必须能执行（否则会留下关不掉的界面）。
--   隐藏路径永远不该被权限判断拦住，这是状态机设计的通用原则。
	self.owner.HUD:CloseCrafting(true)
	self.craftingmenu:Hide()
end

function Controls:ShowCrafting()
-- 请求显示制作界面。注意它不直接 Show，而是：若背包也开着，才真正 Show。
-- 【★ 幂等守卫】if not self.craftingshown —— 已开着就直接返回。
-- 【★ 这就是「正交布尔量 + 合取」的完整形态】
--   SetCrafting(true)  → craftingshown=true；若 craftingandinventoryshown 则 Show
--   SetCrafting(false) → craftingshown=false；若 craftingandinventoryshown 则 Hide
--   两个入口互不干扰，任一顺序调用结果都正确（幂等 + 可交换）。
--   ★ 移植要点：多个 UI 开关控制同一块区域时，别用「最后一个调用者赢」的方式，
--   要用引用计数或正交布尔量求合取，否则会出现先开后关把前者的操作反掉。
	if not self.craftingshown then
		self.craftingshown = true
		if self.craftingandinventoryshown then
			self:DoShowCrafting_Internal()
		end
	end
end

function Controls:HideCrafting()
-- 隐藏制作界面。★ 注意第 1046 行：额外通知背包栏「制作界面被隐藏了」。
-- 【为什么 Show 侧没有对称操作】第 1031-1038 行确实没有对应的通知。
--   这是有意的：inv:OnCraftingHidden() 让背包收起/收窄布局，
--   而「显示回来」不需要通知（背包的 Show 已在 ShowCraftingAndInventory 里处理）。
--   ⚠️ 移植时这类不对称接口要写注释说明，否则很容易被后人「补全」成对称而引入 bug。
	if self.craftingshown then
		self.craftingshown = false
		if self.craftingandinventoryshown then
			self:DoHideCrafting_Internal()
		end
		self.inv:OnCraftingHidden()
	end
end

-- NOTES(JBK): .stay_open_on_hide containers must be hidden and shown in ShowCraftingAndInventory and HideCraftingAndInventory!
-- ★ 作者留下的重要约束注释（NOTES(JBK)）：
--   带 .stay_open_on_hide 标记的容器，在背包界面隐藏时必须一起隐藏、
--   打开时必须一起显示，否则会残留一个「不显示的容器还开着」的脏状态。
--   本函数（第 1079-1081 行）与 Show 侧（第 1057-1059 行）成对处理了
--   containerroot_side / containerroot_side_behind 就是在落实这条约束。
--   【移植要点】★ 「某某类别的窗口必须跟随某某窗口一起开关」
--   这类跨模块的耦合约束，最好在代码里留注释 + 在两侧成对实现，
--   否则第三个地方新加窗口时必然漏掉。
function Controls:ShowCraftingAndInventory()
-- ★★★ 展开「背包 + 制作」整块界面。九个动作，按顺序有讲究：
--  1) 置状态位（第 1053 行）—— 先置位，后面的动作可以依赖它
--  2) 若 craftingshown 则 Show 制作菜单（第 1054-1056 行）
--  3) Show 背包、侧栏容器、侧栏容器后层（第 1057-1059 行）
--  4) 第 1060 行双层判空：secondary_status 本身可能不存在（特殊模式不建，
--     见第 157/187/214 行），其 side_inv 子节点也可能不存在。
--     ★ 用 and 短路而不是嵌套 if，是 Lua 里判两层可选性的惯用写法。
--  5) 通知所有 toast 与状态栏「进入制作模式」（第 1063-1068 行）
-- 【第 1066 行的写法值得学】if self.status.ToggleCrafting ~= nil then ——
--   直接对方法做存在性检查再调，避免调不存在的接口。
--   比 try/catch 式防御更轻，但代价是调用方必须自己记得检查。
    if not self.craftingandinventoryshown then
        self.craftingandinventoryshown = true
		if self.craftingshown then
			self:DoShowCrafting_Internal()
		end
        self.inv:Show()
        self.containerroot_side:Show()
        self.containerroot_side_behind:Show()
        if self.secondary_status and self.secondary_status.side_inv then
            self.secondary_status.side_inv:Show()
        end
		for i, v in ipairs(self.toastitems) do
			v:ToggleCrafting(false)
		end
        if self.status.ToggleCrafting ~= nil then
            self.status:ToggleCrafting(false)
        end
    end
end

function Controls:HideCraftingAndInventory()
-- ★ 收起整块界面。第 1074 行 CloseControllerInventory 必须最先执行 ——
-- 【★ 顺序敏感】控制器物品栏是手柄专用的浮层，它开着时收背包会留下悬空浮层。
--   「先关子浮层，再关容器」是 UI 层级收起的通用顺序。
-- 第 1091 行 self.spellwheel:Close() ——
--   ★ 收背包时强制关掉法术轮盘。因为轮盘是模态的，
--   如果它还开着，收起背包后玩家会困在一个看不见底层的轮盘里。
--   第 641 行的互斥检查（轮盘开时不显示提示）与此呼应。
-- 【★ 状态机完整性】Show（第 1051 行）做的每个动作，Hide 都有对应的逆动作：
--   inv:Show/Hide、containerroot_side、containerroot_side_behind、
--   secondary_status.side_inv、toastitems 的 ToggleCrafting、status 的 ToggleCrafting。
--   ★ 移植建议：写状态机时对照检查「Show/Hide 两侧动作是否严格配对」，
--   这是 UI 状态机最常见的 bug 来源（改了 Show 忘了改 Hide）。
    if self.craftingandinventoryshown then
        self.inv:CloseControllerInventory()
        self.craftingandinventoryshown = false
		if self.craftingshown then
			self:DoHideCrafting_Internal()
		end
        self.inv:Hide()
        self.containerroot_side:Hide()
        self.containerroot_side_behind:Hide()
        if self.secondary_status and self.secondary_status.side_inv then
            self.secondary_status.side_inv:Hide()
        end
		for i, v in ipairs(self.toastitems) do
			v:ToggleCrafting(true)
		end
        if self.status.ToggleCrafting ~= nil then
            self.status:ToggleCrafting(true)
        end
		self.spellwheel:Close()
    end
end

function Controls:BuildEmoteWheel(character_name, emote_groups)
-- ★★★ BuildEmoteWheel：纯数据变换 —— 把「分组表」变成 Wheel 能吃的嵌套结构。
-- 【★ 纯代码构建 UI 的典型样本】整个 DST 的 UI 就是这样长出来的：
--   没有布局文件，全是「new 一个控件 + 填属性 + AddChild」。
--   这个函数只返回普通 Lua table（数组 + 嵌套字典），不接触任何 UI 对象，
--   ★ 因此可以在构造期安全调用、可以随便单元测试。
-- 【数据形状】返回的每一项是 { label, atlas, normal, nestedwheel }，
--   其中 nestedwheel = { name, items, r, f }：
--     r = 圈半径, f = 外圈判定半径（第 1118 行构造）
--   这个形状必须与 widgets/wheel.lua 的期望严格对应。
-- 【为什么用 pairs 遍历分组】分组键是 EMOTE_TYPE 的数值常量（emotes.lua:1），
--   顺序对玩家无意义，所以不关心迭代顺序。
--   ⚠️ 但要注意 Lua 中 pairs 对整数键的遍历顺序不保证稳定，
--     若轮盘项的顺序会影响玩家肌肉记忆，这里应改用有序遍历。
	-- build the emote wheel
	local emote_wheel = {}    
    for name, details in pairs(emote_groups) do
        local nested_wheel_radius = WHEEL_RADIUS -- 0 if auto incrementing
-- 每组默认用统一的轮盘半径与判定半径。
-- ⚠️ 注释「-- 0 if auto incrementing」是过期残留：下方第 1104-1105 行
--   那段「逐项累加」的代码已被注释掉，改成了第 1110 行的「按超量批量放大」。
--   但第 1099-1100 行仍写着「若自动累加则为 0」的旧意图。
--   读源码时以第 1110 行的批量方案为准。
        local nested_wheel_focus_radius = WHEEL_FOCUS_RADIUS -- 0 if auto incrementing
        local nested_wheel_items = {}      
		local num_emotes = 0  
        for i, emote in ipairs(details.emotes) do
            --nested_wheel_radius = nested_wheel_radius + NESTED_WHEEL_RADIUS_INCREMENT
-- 被注释掉的旧方案：每多一项就放大一点（线性逐项累加）。
-- 【为什么换成批量方案】逐项累加时，第 n 项会让圈半径变成 base + n*10，
--   表情多了圈就巨大，视觉上突兀。批量方案只在超过阈值时才整体放大。
--   ★ 移植建议：UI 尺寸的响应式调整优先用「分档」而非「连续累加」，
--   前者视觉更稳定、参数更好调。
            --nested_wheel_focus_radius = nested_wheel_focus_radius + NESTED_WHEEL_FOCUS_RADIUS_INCREMENT
		    table.insert(nested_wheel_items, WheelItem.EmoteItem(emote, character_name))
			num_emotes = num_emotes + 1
        end

		if 8 < num_emotes then
-- ★ 阈值 8：单项超过 8 个才触发放大。8 应是「一圈能舒服排下的上限」。
-- 【为什么是魔数】这是美术与可用性折中的经验值，源码没写理由。
--   移植时这个数字需要按自己的图标尺寸重新试。
			local num_over = num_emotes - 8 
			nested_wheel_radius = nested_wheel_radius + (num_over * NESTED_WHEEL_RADIUS_INCREMENT)
			nested_wheel_focus_radius = nested_wheel_radius + (num_over * NESTED_WHEEL_FOCUS_RADIUS_INCREMENT)
-- ⚠️★ 确认的真实缺陷（已逐行对照核实，行号依据如下）：
--   本行应为「用 nested_wheel_focus_radius 自身的初值 + 少量增量」，
--   但实际写的是 nested_wheel_radius + (num_over * FOCUS_INCREMENT) ——
--   右边用的是 radius 而不是 focus_radius。
-- 【为什么会错】第 1112 行刚刚把 nested_wheel_radius 改成了
--   WHEEL_RADIUS + num_over*10，本行拿它当基数，于是 focus 变成：
--   175 + num_over*10 + num_over*1 = 175 + num_over*11
--   而正确值应是 WHEEL_FOCUS_RADIUS + num_over*1 = 178 + num_over*1。
-- 【量化后果】设 num_over = 5（13 个表情）：
--   实际 f = 230，期望 f = 183 —— 判定环外扩了 47 像素；
--   num_over = 20 时偏差达 220 像素。此时「可点击区域」远大于图形圈，
--   玩家会点到圈外的空白处且没有任何视觉反馈。
--   且 focus 随 radius 一起涨，等于完全放弃了「判定环比图形环略大一点」
--   那个刻意设计的容差（第 50-51 行注释）。
-- 【修法】把第 1113 行的 nested_wheel_radius 改为 nested_wheel_focus_radius：
--   nested_wheel_focus_radius = nested_wheel_focus_radius + (num_over * NESTED_WHEEL_FOCUS_RADIUS_INCREMENT)
-- 【影响面】只影响有 >8 个表情的分组，且属于「判定区偏大」而非「功能失效」，
--   所以这个 bug 能长期存活 —— 正好说明为什么需要逐行注释审计。
-- 【★ 移植提醒】★ 这类「两个平行变量 + 一个写错成另一个」的 bug 最隐蔽，
--   因为代码能跑、不报错，只是手感略怪。建议在代码审查时
--   把「成对出现的相似变量」列为必查项。
		end

		-- don't insert a nested wheel if it's empty
-- 空分组不插入（第 1117 行）。
-- 【为什么重要】第 377-391 行解锁型表情的加入依赖玩家背包，
--   没有对应道具时 UNLOCKABLE 分组会是空的。若仍插入，
--   轮盘上会出现一个点开是空的扇区。
-- ★ 空集合不入列：所有「遍历集合构建 UI」的场合都该加这一道过滤。
		if 0 < num_emotes then
			local nested_wheel = {name=name, items=nested_wheel_items, r=nested_wheel_radius, f=nested_wheel_focus_radius}
			table.insert(emote_wheel, {label=details.label, atlas="images/emotes_" .. character_name .. ".xml", normal=details.image, nestedwheel=nested_wheel})
-- 组装一个轮盘项。注意 atlas（纹理图集）和 normal（图标 tex 名）都是拼出来的，
-- 依赖构造期第 328 行确定的 character_name（有 generic 兜底）。
-- 【为什么组图标和成员图标可以不同图集】组图标（如「情绪」波浪）通常角色专属，
--   而成员表情图标在 emotes_<角色>.xml 里。两套命名空间分开管理。
		end
    end

	return emote_wheel
end

function Controls:BuildCommandWheel(is_splitscreen)
-- ★★ BuildCommandWheel(is_splitscreen)：组装指令轮盘。
-- 【★ 为什么每次都要重建】因为成员构成依赖玩家当前状态：
--   骑乘与否（第 1128 行）决定用哪套表情轮盘；
--   平台能力决定有无邀请/聊天项。状态一变，旧轮盘内容就过时了。
-- 【外部的重建触发条件】screens/playerhud.lua:1353 有调用，
--   那里只在 can_invite 或 is_mounted 变化时才重建 —— 差量触发，省开销。
-- ⚠️ 注意第 396 行构造期调用的是 self:BuildCommandWheel()，没传参数，
--   于是 is_splitscreen 为 nil（falsy），走第 1156 行的 else 分支。
--   也就是说构造期在分屏下也会按非分屏的比例建轮盘，直到玩家首次打开
--   指令轮盘且 playerhud 检测到状态变化时才会重建修正。
--   疑似初次打开轮盘偏小（分屏 1.6 倍的放大在构造期没生效）。
	self.can_invite = IsConsole() and TheNet:CanSendInvitation() or false
-- ★ 这两行不只是取状态，还兼任「变化检测的缓存」——
--   playerhud.lua:1353 正是拿 self.can_invite / self.is_mounted 与实时值比对，
--   不相等才调本函数重建。
-- 【★ 缓存字段与生成逻辑放在一起，是差量重建的标准写法】
--   自己的 UI 想做「变化才重建」，就照这个套路：生成时存快照，比对时用快照。
	self.is_mounted = self.owner.replica.rider and self.owner.replica.rider:IsRiding()	

	local emote_wheel = self.is_mounted and self.emote_wheel_mounted or self.emote_wheel_standing
-- ★ 根据是否骑乘在两套表情轮盘中二选一。
-- 【★ 这是 BuildCommandWheel 必须重建的根本原因】
--   骑乘状态会变，但轮盘的嵌套内容在 SetItems 时就固化了，不会自动更新。
-- 【移植要点】轮盘这类「把当前状态快照进结构」的 UI，必须显式重建。
--   想省事可以改成每次打开时重建（OpenCommandWheel 里调），
--   DST 为省开销改成了差量触发。
	local base_wheel = {}
    table.insert(base_wheel, {label=STRINGS.UI.COMMANDWHEEL.EMOTES,	checkenabled=function() return not self.owner:HasTag("playerghost") end, nestedwheel={name="emotes", items=emote_wheel, r=WHEEL_RADIUS, f=WHEEL_FOCUS_RADIUS}, atlas="images/emotes_"..self.character_name..".xml", normal="gesture_"..self.character_name.."_kiss.tex"})
-- 指令轮盘的第一项：表情（内嵌上面构建好的嵌套轮盘）。
-- 【★ checkenabled 的设计值得学】它是一个函数，在轮盘显示时才求值，
--   返回 true 表示该项可用。玩家变成幽灵（playerghost）后表情自动置灰。
--   ★ 把「可用性」做成惰性函数而非布尔字段，就不需要在状态变化时
--     主动去遍历更新所有轮盘项 —— 省掉一整类同步 bug。
--   这是本文件里最好的一个 UI 模式，强烈建议移植时采用。
-- 第 1133/1143 行的 PLATFORM ~= "SWITCH" and IsConsole() ——
--   主机才有语音聊天项，且 Switch 主机不支持。两道门缺一不可。
	if PLATFORM ~= "SWITCH" and IsConsole() then
		table.insert(base_wheel, WheelItem.TextChatItem( true, "command_whisper.tex" ))		
	end

	table.insert(base_wheel, {label=STRINGS.UI.COMMANDWHEEL.PLAYERLIST,	execute=function() self.owner.HUD:ShowPlayerStatusScreen() end, atlas="images/command_wheel.xml", normal="command_playerlisting.tex"})
-- 玩家列表项与自定义指令项。都是 execute 回调，
-- 回调里自行 PushScreen —— 轮盘只负责「选中后调用谁」。
-- 【★ 分工清晰】轮盘不关心打开什么界面，只知道「选第几项做什么」，
--   具体的界面栈操作由 HUD/FrontEnd 负责。移植时保持这个分层。
    table.insert(base_wheel, {label=STRINGS.UI.COMMANDWHEEL.USERCOMMANDS, execute=function() TheFrontEnd:PushScreen(UserCommandPickerScreen(self.owner, nil)) end, atlas="images/command_wheel.xml", normal="command_usercommands.tex"})

    if self.can_invite then	
		table.insert(base_wheel, {label=STRINGS.UI.COMMANDWHEEL.INVITE,	execute=function() if PLATFORM == "XBONE" then TheNet:StartInvite() else TheNet:SendInvitation() end end, atlas="images/command_wheel.xml", normal="command_playerinvite.tex"})
	end
	if PLATFORM ~= "SWITCH" and IsConsole() then
		table.insert(base_wheel, WheelItem.TextChatItem( false, "command_talk.tex" ))
	end

	
	self.commandwheel:SetItems( base_wheel, WHEEL_RADIUS, WHEEL_FOCUS_RADIUS)
-- 一次性把整张轮盘表交给 Wheel 控件。半径用全局常量，
-- 说明所有轮盘（表情/指令）共享同一套几何参数。
    local consoleScale = 1.0
-- 主机缩放修正，与 SetHUDSize 第 575-578 行同源（PS5 取 0.65）。
-- 【⚠️ 重复定义的问题】consoleScale 这个逻辑在第 575 行和第 1149 行
--   各写了一份，完全相同。改平台缩放要记得改两处。
--   移植建议：这种「同一平台常量」应提到模块顶部做单一来源。
    if IsPS5() then
        consoleScale = .65
    end
	if is_splitscreen then
-- ★★ 分屏时轮盘放大 1.6 倍。
-- 【为什么分屏要放大】分屏时整个屏幕被左右切开，单个玩家的可视区域变窄，
--   轮盘半径 175 可能超出半屏，所以放大。
-- 【⚠️ 与 SetHUDSize 第 579 行的耦合】
--   最终缩放 = 这里的 HUDScale*1.6*consoleScale，或
--                SetHUDSize 里的 consoleScale*scale（主机+分屏时跳过）。
--   两处必须配套，否则轮盘会大到出屏或小到点不中。
--   ★ 这是「同一属性在两处分别赋值」的典型维护陷阱：
--     后执行的那次（SetHUDSize 在 OnUpdate 里每帧可能触发）会覆盖本次。
-- 【移植建议】把「最终缩放」集中到一个函数里算，别分散赋值。
		self.commandwheel:SetScale(TheFrontEnd:GetHUDScale() * 1.6 * consoleScale)
	else
        self.commandwheel:SetScale(TheFrontEnd:GetHUDScale() * consoleScale)
	end
end

function Controls:GetTooltipPos(hoverer)
-- ★★ 工具提示定位的「可覆写钩子」。
-- 【机制】FunctionOrValue（util.lua:1716）：入参是函数就调用它，否则原样返回。
--   所以 override_tooltip_pos 既可以存一个函数（动态计算位置），
--   也可以存一个 Vector3（固定位置），还可以是 nil（用默认逻辑）。
--   ★ 一行代码同时支持三种模式，是 Lua 的典型用法。
-- 【为什么需要这个钩子】tooltip 默认定位算法（贴鼠标/贴控件）无法覆盖
--   「必须避开某个遮挡物」这类需求。开放覆写点给业务代码即可，
--   不用改 tooltip 本身。
-- ⚠️ 注意本函数不传 hoverer 给 FunctionOrValue 的其它参数以外的东西，
--   但仍把 self 一起传了 —— 闭包若写成 function(pos) 会拿到 self 而不是 hoverer。
--   当前写法 self, hoverer 两参都能拿到，是刻意的。移植时别改参数顺序。
    return FunctionOrValue(self.override_tooltip_pos, self, hoverer)
end

function Controls:OverrideTooltipPos(pos_or_pos_x, pos_y, pos_z)
-- 设置 tooltip 位置覆写。
-- 【★ 第 1165 行的类型分派：传单个 number 就当成 x 分量】
--   支持两种调用风格：OverrideTooltipPos(1,2,3) 或 OverrideTooltipPos(Vector3(...))
-- type(pos_or_pos_x) == "number" 作为判据，简洁且无歧义（Vector3 与 number 类型不同）。
-- 【★ 移植要点】这类「同一接口接受两种调用形式」的兼容层，
--   在 API 演进期非常有用：老调用方传三个数，新调用方传对象，两者都能用。
--   自己写 C++/C# 绑定时可用重载实现同样的效果。
-- 【注意没有 nil 清理分支】要取消覆写只能再调一次传 nil，
--   而 type(nil) ~= "number" 会走 else 分支把字段置为 nil —— 恰好可行，
--   但这是巧合而非显式设计。
    if type(pos_or_pos_x) == "number" then
        self.override_tooltip_pos = Vector3(pos_or_pos_x, pos_y, pos_z)
    else
        self.override_tooltip_pos = pos_or_pos_x
    end
end

return Controls
-- 【全文件方法清单（便于移植时对照）】
--   状态显示    ShowStatusNumbers / HideStatusNumbers / SetGhostMode
--   主题        SetDark
--   分辨率      MakeScalingNodes / SetHUDSize
--   每帧        OnUpdate / HighlightActionItem / DelayControllerSpellWheelHint
--   地图        ShowMap / HideMap / ToggleMap / FocusMapOnWorldPosition
--   制作界面    ShowCrafting / HideCrafting
--               ShowCraftingAndInventory / HideCraftingAndInventory
--               DoShowCrafting_Internal / DoHideCrafting_Internal
--   轮盘        BuildEmoteWheel / BuildCommandWheel
--   toast       ManageToast
--   提示位置    GetTooltipPos / OverrideTooltipPos
-- 【★ 移植优先级建议】自研引擎先实现这四组，就有了 DST UI 的骨架：
--   1) MakeScalingNodes + SetHUDSize —— 两层缩放节点 + 上限夹取（分辨率适配）
--   2) OnUpdate 的无状态重算模式 + HighlightActionItem 的文字挖洞高亮
--   3) 制作界面那两个正交布尔量 + _Internal 收敛的状态机
--   4) BuildEmoteWheel 的纯数据变换（UI 配置与构建分离）
-- 【★ 全文件贯穿的三条设计原则，抄代码时别丢掉】
--   · 幂等守卫：Show*/Hide* 开头一律先查状态位，已达目标态就直接 return
--   · 无状态重算：OnUpdate 每帧从零重建 UI 呈现，不存中间态
--   · 防御性降级：每个跨模块访问点都判空，宁可少显示不可崩