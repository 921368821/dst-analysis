--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：screens/playerhud.lua
-- 模块：界面 / 游戏内 HUD 屏幕（screen 名 "HUD"）
-- 职责：游戏主 HUD 的「编排器」。本身是 Screen，但几乎不画东西，只做三件事：
--       1) 持有五棵根控件（overlayroot/under_root/root/over_root/
--          popupstats_root），其 AddChild 顺序即渲染 z 序；
--       2) 编排全部弹窗与轮盘的开与关（Open*/Close* 共 20 多对）；
--       3) 独占输入：HasInputFocus 与 OnControl 决定按键归 UI 还是归世界。
--       真正的 HUD 内容在 widgets/controls.lua（root 的唯一子控件）。
-- 关键符号：CreateOverlays, SetMainCharacter, OpenScreenUnderPause,
--           HasInputFocus, SetModFocus, OnControl, OpenSpellWheel,
--           OpenCommandWheel, TryStopInspectingModules, RefreshControllers,
--           UpdateClouds, UpdateDrops, GetFirstOpenContainerWidget
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：frontend.lua（screenstack 压栈/出栈/插栈、焦点）, 
--           widgets/screen.lua（Screen 基类，OnDestroy 即 Kill）, 
--           widgets/widget.lua（焦点链 SetFocus/SetFocusFromChild）, 
--           widgets/controls.lua（HUD 本体，本文件的 self.controls）, 
--           widgets/inventorybar.lua（rebuild_pending 脏标记）, 
--           widgets/characterstatst displays（血/理智/体温）,
--           cameras/followcamera.lua（ScreenHOffset 配对栈）, 
--           prefabs/player_common.lua（ActivateHUD 激活顺序）,
--           popupmanager.lua（POPUPS.PLAYERINFO 等模组化弹窗）, 
--           components/playercontroller.lua（ShouldPlayerHUDControlBeIgnored 输入仲裁）
--============================================================
local Screen = require "widgets/screen"
local ContainerWidget = require("widgets/containerwidget")
local WriteableWidget = require("widgets/writeablewidget")
local Controls = require("widgets/controls")
local UIAnim = require "widgets/uianim"
local Text = require "widgets/text"
local Widget = require "widgets/widget"
local IceOver = require "widgets/iceover"
local FireOver = require "widgets/fireover"
local BloodOver = require "widgets/bloodover"
local BeefBloodOver = require "widgets/beefbloodover"
local HeatOver = require "widgets/heatover"
local FumeOver = require "widgets/fumeover"
local MiasmaOver = require("widgets/miasmaover")
local MiasmaCloudsOver = require("widgets/miasmacloudsover")
local SandOver = require "widgets/sandover"
local SandDustOver = require "widgets/sanddustover"
local MoonstormOver = require "widgets/moonstormover"
local MoonstormOver_Lightning = require "widgets/moonstormover_lightning"
local RainDomeOver = require("widgets/raindomeover")
local Leafcanopy = require "widgets/leafcanopy"
local MindControlOver = require "widgets/mindcontrolover"
local ParasiteThrallOver = require "widgets/parasitethrallover"
local InkOver = require "widgets/inkover"
local WagpunkUI = require "widgets/wagpunkui"
local GogglesOver = require "widgets/gogglesover"
local NutrientsOver = require "widgets/nutrientsover"
local ScrapMonocleOver = require "widgets/scrapmonocleover"
local NightVisionFruitOver = require "widgets/nightvisionfruitover"
local InspectaclesOver = require("widgets/inspectaclesover")
local RoseGlassesOver = require("widgets/roseglassesover")
local DroneZapOver = require("widgets/dronezapover")
local BatOver = require "widgets/batover"
local FlareOver = require "widgets/flareover"
local LunarBurnOver = require("widgets/lunarburnover")
local WxPowerOver = require("widgets/wxpowerover")
local EndOfMatchPopup = require "widgets/redux/endofmatchpopup"
local PopupNumber = require "widgets/popupnumber"
local RingMeter = require "widgets/ringmeter"
local easing = require("easing")
local PauseScreen = require "screens/redux/pausescreen"
local ChatInputScreen = require "screens/chatinputscreen"
local PlayerStatusScreen = require "screens/playerstatusscreen"
local InputDialogScreen = require "screens/inputdialog"
local CookbookPopupScreen = require "screens/cookbookpopupscreen"
local PlantRegistryPopupScreen = require "screens/plantregistrypopupscreen"
local PlayerInfoPopupScreen = require "screens/playerinfopopupscreen"
local ScrapbookScreen = require "screens/redux/scrapbookscreen"
local InspectaclesScreen = require("screens/redux/inspectaclesscreen")
local BalatroScreen = require("screens/redux/balatroscreen")
local PumpkinCarvingScreen = require("screens/redux/pumpkincarvingscreen")
local PumpkinHatCarvingScreen = require("screens/redux/pumpkinhatcarvingscreen")
local SnowmanDecoratingScreen = require("screens/redux/snowmandecoratingscreen")
local UpgradeModulesDisplay_Inspecting = require("widgets/upgrademodulesdisplay_inspecting")

local TargetIndicator = require "widgets/targetindicator"

local EventAnnouncer = require "widgets/eventannouncer"
local GiftItemPopUp = require "screens/giftitempopup"
local GridWardrobePopupScreen = require "screens/redux/wardrobepopupgridloadout"
local GridGroomerPopupScreen = require "screens/redux/groomerpopupgridloadout"
local GridHermitCrabWardrobePopupScreen = require "screens/redux/hermitcrabwardrobepopupgridloadout"
local GridScarecrowClothingPopupScreen = require "screens/redux/scarecrowpopupgridloadout"
local PlayerAvatarPopup = require "widgets/playeravatarpopup"
local DressupAvatarPopup = require "widgets/dressupavatarpopup"

-- ══════════════════════════════════════════════════════════════
-- PlayerHud —— 游戏主 HUD 屏幕（screen 名 "HUD"，1812 行）
--
-- 【本文件的角色：屏幕栈的「编排器」，不是控件】
-- HUD 本身是一个 Screen，但它几乎不画东西。它做三件事：
--   1) 持有五棵根控件，决定渲染 z 序（见 70-75 行）
--   2) 编排所有弹窗/轮盘的开与关（Open*/Close* 共 20 多对，380-830 行）
--   3) 独占输入：HasInputFocus / OnControl 决定按键是给 UI 还是给世界
--
-- 【★ 最重要的三件事】
-- 1) 五个根的 AddChild 顺序 == z 序（70-75）。DST 没有布局引擎，
--    渲染层次纯粹靠 AddChild 顺序（后来的盖在先来的上面）。
-- 2) HasInputFocus（1081）是模态的总闸：HUD 永远在栈里，
--    「栈顶不是我」就等于「我锁住了输入」。
-- 3) OpenScreenUnderPause（460）解决暂停时的层级：暂停屏已开时
--    新弹窗必须插到暂停屏「下面」，否则玩家看不见自己开的东西。
--
-- 【⚠️ 容易踩的坑】
-- · 弹窗字段的大小写极不统一：playerinfoscreen（715）vs
--   PlayerInfoPopupScreen（1197）—— 后者全库从未被赋值，见该处注释。
-- · self.playeravatarpopup（81/93-97/1191）全库只有「置 nil」，
--   从无「置为实例」，见该处注释。
-- · 大量 Close*Screen 用 activescreen.name 做字符串比较，
--   重命名 Screen 的第一个参数就会静默失效。
-- ══════════════════════════════════════════════════════════════
local PlayerHud = Class(Screen, function(self)
    Screen._ctor(self, "HUD")

    self.overlayroot = self:AddChild(Widget("overlays"))
-- ★ 五棵根控件的顺序就是 z 序，从下到上：
--   overlayroot  < under_root < root < over_root < popupstats_root
-- 语义分层（这个顺序不是随便排的）：
--   overlayroot  屏幕特效（暗角 vig、血/冰/火/热/沙尘/月亮风暴…）
--   under_root   背景层（云层、服务器暂停遮罩、事件播报条）
--   root         ★ 主 HUD 本体（Controls：血条/背包/合成/地图…）
--   over_root    覆盖在 HUD 之上但仍在特效之下（心灵控制、寄生仆从、动力）
--   popupstats_root 飘字/环 meter —— 必须在最顶，否则会被 HUD 元素盖住
-- ⚠️ 换写法会怎样错：若把 popupstats_root 提前到 root 之前，
--   伤害飘字会被血条/背包遮住。这五个名字在别的文件里也被引用，
--   改名要全局搜（例如 controls.lua 里的 self.controls 与此处的 self.root 不同物）。

    self.under_root = self:AddChild(Widget("under_root"))
    self.root = self:AddChild(Widget("root"))
    self.over_root = self:AddChild(Widget("over_root"))
    self.popupstats_root = self:AddChild(Widget("popupstats_root"))

    self.playerstatusscreen = nil
-- ★ 弹窗句柄统一在构造器里预置为 nil。这是 Lua 里的好习惯：
--   与其让每处 Open/Close 都写 if x == nil then，
--   不如构造时把「将来会被赋值的字段」全部声明出来。
--   读未初始化字段在 Lua 里返回 nil 不会报错，但可读性会塌。
-- ⚠️ 注意这里只声明了 5 个（77-83），而文件里实际有十几个弹窗字段
--   （cookbookscreen / plantregistryscreen / scrapbookscreen /
--   balatroscreen / upgrademodulewidget …）并未在此声明 ——
--   说明这份声明是「历史累积」而非「完备清单」，靠 nil 默认值兜底。
    self.giftitempopup = nil
    self.wardrobepopup = nil
    self.groomerpopup = nil
    self.playeravatarpopup = nil
    self.recentgifts = nil
    self.recentgiftstask = nil

    self.inst:ListenForEvent("continuefrompause", function() self:RefreshControllers() end, TheWorld)
-- ★【事件 → UI 刷新链路的第一站】HUD 用 ListenForEvent 把玩法事件
--   直接接到界面回调上。这是 DST「数据驱动 UI」的主通道：
--   服务端改组件 → PushEvent → 客户端副本转发 → 这里改控件。
-- 注意 ListenForEvent 的第三个参数是「事件源实体」，不是监听者：
--   这里监听 TheWorld 上发生的事件，监听者是 self.inst（见 entityscript.lua:1187）。
-- continuefrompause = 从暂停恢复。此刻必须重算手柄相关布局，
--   因为暂停期间玩家可能插拔手柄（RefreshControllers，846 行）。
    self.inst:ListenForEvent("endofmatch", function(world, data) self:ShowEndOfMatchPopup(data) end, TheWorld)
    self.inst:ListenForEvent("debug_rebuild_skilltreedata", function() self:OpenPlayerInfoScreen() end, TheGlobalInstance)
    
    if not TheWorld.ismastersim then
-- ⚠️ 这一大段 if/else 是**端判定**，决定后续代码跑在哪个端：
--   ismastersim == true 表示「房主/专用服务器的模拟端」。
--   客户端（isastersim）走 if 分支，服务端走 else 分支。
-- 为什么客户端要做这一堆清理：
--   服务器可能发 c_reset / c_regenerateworld（存档重置/世界重生成），
--   客户端收到 deactivateworld 后整个世界要重建，
--   此时任何还挂在旧世界上的界面对象都会变成悬空指针，必须手动关掉。
--   这是「副本生命周期短于界面生命周期」的典型处理。
        self.inst:ListenForEvent("deactivateworld", function()
            --Essential cleanup when client is notified of
            --pending server c_reset or c_regenerateworld.
            if self.playeravatarpopup ~= nil then
-- ⚠️【疑似失效分支，已本人逐行核实】
--   self.playeravatarpopup 在**全库**（grep 全仓 .lua）只有两处赋值，
--   且都是置 nil（81 行构造器、97 行此处）。从来没有被赋成实例。
--   真正被创建的是 711 行的 self.dressupAvatarPopUpcreen（另一个字段）。
--   → 这段清理代码实际永远不执行。
-- 推测原因：重构时把 playeravatarpopup 改名成 dressupAvatarPopUpcreen，
--   忘了同步这处。结果是：客户端 deactivateworld 时
--   换装预览弹窗不会被这条路径关掉。
-- 为什么这不一定造成线上崩溃：elseif 分支里 99 行仍会关 playerstatusscreen，
--   且 113 行的 under_root:KillAllChildren 等重建路径另有兜底。
                if self.playeravatarpopup.started and self.playeravatarpopup.inst:IsValid() then
                    self.playeravatarpopup:Close()
                end
                self.playeravatarpopup = nil
            end
            if self.playerstatusscreen ~= nil then
                if self.playerstatusscreen.shown then
                    self.playerstatusscreen:Close()
                end
                self.playerstatusscreen:CloseUserCommandPickerScreen()
            end
        end, TheWorld)
    else
-- ⚠️【疑似失效，已核实】self.onclosepopups 在 PlayerHud 里从未定义：
--   grep 全仓，只有 components/writeable.lua:66 定义过同名字段
--   （那是 writeable 组件的字段，与 HUD 无关）。
--   于是这里等价于 ListenForEvent("ms_closepopups", nil)。
-- 为什么不会崩：AddListener（entityscript.lua:1185）执行
--   table.insert(listener_fns, nil)。本人用 lupa 实测 Lua 5.5：
--   table.insert(t, nil) 不报错、返回 nil、t 长度不变（空操作）。
--   所以它只是**静默注册了一个永远不会被调用的监听器**。
-- 意图推测：服务端 HUD 想在 ms_closepopups 时关掉某些弹窗，
--   但回调函数忘了写（或被删）。
        self.inst:ListenForEvent("ms_closepopups", self.onclosepopups)
    end
end)

function PlayerHud:CreateOverlays(owner)
-- ★【CreateOverlays = 全量重建特效层】
-- 关键设计：函数开头先 KillAllChildren 三个根，然后从头 AddChild。
-- 「重建」而非「增删」—— 因为 CreateOverlays 会被重复调用
-- （每次 SetMainCharacter 都调，见 922 行），重建天然幂等，
-- 不用写「这个字段之前建过没有」的分支。
-- ⚠️ 反面代价：重建会丢失所有局部状态（比如 self.drops_alpha 在 140 行
--   被重置为 0）。这是选择「简单可预测」而非「保留状态」的取舍。
    self.overlayroot:KillAllChildren()
-- ⚠️ 注意这里 Kill 了 under_root，但**没有** Kill overlayroot 之外的两棵
--   根（root / over_root / popupstats_root）—— 因为那些归 Controls 管。
--   也就是说 overlayroot/under_root 完全由本函数拥有，
--   root 及以上由外部（SetMainCharacter 923 行）拥有。
    self.under_root:KillAllChildren()
    self.over_root:KillAllChildren()

    self.vig = self.overlayroot:AddChild(UIAnim())
-- 【暗角 vig】AnimateWhilePaused(false)（120 行）是关键：
--   暂停时暗角动画**冻结**，这样暂停菜单打开时背景不会继续闪。
--   对比：Widget 构造默认 UpdateWhilePaused(true)（widget.lua:43）。
--   → 特效层普遍覆盖成 false，界面层普遍保持 true。
--   这是一条通用规则：背景特效不该在暂停时动，UI 反馈应该动。
    self.vig:GetAnimState():SetBuild("vig")
    self.vig:GetAnimState():SetBank("vig")
    self.vig:GetAnimState():PlayAnimation("basic", true)
    self.vig:GetAnimState():AnimateWhilePaused(false)

    self.vig:SetHAnchor(ANCHOR_MIDDLE)
    self.vig:SetVAnchor(ANCHOR_MIDDLE)
    self.vig:SetScaleMode(SCALEMODE_FIXEDSCREEN_NONDYNAMIC)

    self.vig:SetClickable(false)

    self.drops_vig = self.overlayroot:AddChild(UIAnim())
-- drops_vig = 「淋雨时屏幕边缘的水痕」。它是 UI 与玩法的又一个直连：
--   142 行监听 owner 的 moisturedelta（湿度变化）事件来触发。
-- 状态机只有两个：dropsplash（是否正在下雨）与 drops_alpha（0..1 透明度）。
-- ⚠️ 注意 139-140 行初始化为 Hide + alpha=0：
--   必须是「先隐藏再淡入」，否则构造完成的第一帧会闪一下水痕。
    self.drops_vig:GetAnimState():SetBuild("paddle_over")
    self.drops_vig:GetAnimState():SetBank("paddle_over")
    self.drops_vig:GetAnimState():PlayAnimation("over", true)
    self.drops_vig:GetAnimState():AnimateWhilePaused(false)

    self.drops_vig:SetHAnchor(ANCHOR_MIDDLE)
    self.drops_vig:SetVAnchor(ANCHOR_MIDDLE)
    self.drops_vig:SetScaleMode(SCALEMODE_FIXEDSCREEN_NONDYNAMIC)

    self.drops_vig:SetClickable(false)
    self.drops_vig:Hide()
    self.drops_alpha= 0

    self.inst:ListenForEvent("moisturedelta", function(inst, data)
-- ★【数据 → UI 刷新链路的教科书案例】
-- moisturedelta 事件由 weather/sanity 相关组件推送，数据是 {old, new}。
-- 三个分支的优先级设计值得学：
--   1) 在雨伞下 → 取消水滴效果（但保留已累积的 alpha，让它自然消退）
--   2) 湿度上升 → 开始下雨
--   3) 湿度下降 → 什么都不做（等 UpdateDrops 自然消退）
-- ⚠️ 154 行的 DoSimTaskInTime(3, ...) 是「去抖」：
--   湿度是连续 netvar，可能每帧都在变。若每次上升都重建任务，
--   计时器永远推不到 3 秒，水痕会一直闪。
--   正确写法是「先 Cancel 旧的，再建新的」—— 见 152-153 行。
-- ⚠️ 但这里 Cancel 后**没有把 self.droptask 置 nil**（对比 146-147 行有置 nil）。
--   结果：droptask 会一直指向一个已完成的死任务。
--   下次 146 行 Cancel 一个死任务是安全的（DST 的 Cancel 幂等），
--   所以不是崩溃级缺陷，但属于「字段语义已污染」——
--   读代码时不能相信 self.droptask ~= nil 表示「有任务在跑」。
			if owner.components.raindomewatcher ~= nil and owner.components.raindomewatcher:IsUnderRainDome() then
				self.dropsplash = nil
				if self.droptask ~= nil then
					self.droptask:Cancel()
					self.droptask = nil
				end
			elseif data.new > data.old then
                self.dropsplash = true
                if self.droptask then
                    self.droptask:Cancel()
                end
                self.droptask = self.inst:DoSimTaskInTime(3,function() self.dropsplash = nil end)
-- ★ 去抖的标准写法。3 秒是「雨停后水痕再维持 3 秒」的手感参数。
-- ⚠️ 用 DoSimTaskInTime 而非 DoTaskInTime：widget.lua:40-41 显示
--   实例创建时会把这俩替换成 Sim 版本，即 UI 计时器**跟随模拟暂停**。
--   这里是对的：水痕应该在暂停时也停。但若某个 UI 计时器需要
--   在暂停时继续走，必须显式走别的路径。
            end
        end, owner)

    self.leafcanopy = self.overlayroot:AddChild(Leafcanopy(owner))
    self.raindomeover = self.overlayroot:AddChild(RainDomeOver(owner))

    self.storm_root = self.over_root:AddChild(Widget("storm_root"))
-- storm_root / storm_overlays 是天气特效的两级容器。
-- 为什么要嵌套两层而不是直接挂：
--   storm_overlays 需要作为一个整体被 gogglesover 引用（189 行），
--   同时 storm_root 还要能和 mindcontrolover（179 行）分开控制显隐。
-- → UI 树的层级设计原则：**按「谁引用谁」分层，而不是按「功能」分层**。
    self.storm_overlays = self.storm_root:AddChild(Widget("storm_overlays"))
    self.sanddustover = self.storm_overlays:AddChild(SandDustOver(owner))

    self.moonstormdust = self.storm_overlays:AddChild(Image("images/overlays_moonstorm.xml", "moonstorm.tex"))
    self.moonstormdust:SetEffect( "shaders/moonstorm.ksh" )
    self.moonstormdust:EnableEffectParams2(true)
    self.moonstormdust:SetHAnchor(ANCHOR_MIDDLE)
    self.moonstormdust:SetVAnchor(ANCHOR_MIDDLE)
    self.moonstormdust:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.moonstormdust:SetBlendMode(1)
    self.moonstormdust:SetUVMode(WRAP_MODE.WRAP)
    self.moonstormdust:Hide()
    self.moonstormdust:SetClickable(false)
    self.moonstormover_lightning = self.storm_overlays:AddChild(MoonstormOver_Lightning(owner))

	self.miasmaclouds = self.storm_overlays:AddChild(MiasmaCloudsOver(owner))

    self.mindcontrolover = self.over_root:AddChild(MindControlOver(owner))
    self.parasitethrallover = self.over_root:AddChild(ParasiteThrallOver(owner))

    if IsSpecialEventActive(SPECIAL_EVENTS.HALLOWED_NIGHTS) then
-- ⚠️ 条件创建特效的写法：只有 Halloween 活动期才挂 batover。
-- 这带来一个隐患（代码本身已规避）：其它地方若无条件访问 self.batover，
--   非活动期就是 nil。移植时若新增 self.xxxover 的无条件访问，
--   就会在特定活动期崩溃——这类「按活动期条件存在的字段」
--   应当集中登记，而不是散落在 200 多行里。
        self.batover = self.overlayroot:AddChild(BatOver(owner))
    end
    self.sandover = self.overlayroot:AddChild(SandOver(owner, self.sanddustover))
    self.moonstormover = self.overlayroot:AddChild(MoonstormOver(owner, self.moonstormdust))
	self.miasmaover = self.overlayroot:AddChild(MiasmaOver(owner, self.miasmaclouds))

    self.gogglesover = self.overlayroot:AddChild(GogglesOver(owner, self.storm_overlays))
    self.nutrientsover = self.overlayroot:AddChild(NutrientsOver(owner))
    self.scrapmonocleover = self.overlayroot:AddChild(ScrapMonocleOver(owner))
    self.nightvisionfruitover = self.overlayroot:AddChild(NightVisionFruitOver(owner))
    self.inspectaclesover = self.overlayroot:AddChild(InspectaclesOver(owner))
    self.roseglassesover = self.overlayroot:AddChild(RoseGlassesOver(owner))
    self.bloodover = self.overlayroot:AddChild(BloodOver(owner))
    self.beefbloodover = self.overlayroot:AddChild(BeefBloodOver(owner))
    self.iceover = self.overlayroot:AddChild(IceOver(owner))
    self.fireover = self.overlayroot:AddChild(FireOver(owner))
	self.lunarburnover = self.overlayroot:AddChild(LunarBurnOver(owner))
    self.heatover = self.overlayroot:AddChild(HeatOver(owner))
    self.fumeover = self.overlayroot:AddChild(FumeOver(owner))
    self.flareover = self.overlayroot:AddChild(FlareOver(owner))

    self.InkOver = self.overlayroot:AddChild(InkOver(owner))
	self.Wagpunkui = self.overlayroot:AddChild(WagpunkUI(owner))
	self.dronezapover = self.overlayroot:AddChild(DroneZapOver(owner))
	self.wxpowerover = self.over_root:AddChild(WxPowerOver(owner))

    self.clouds = self.under_root:AddChild(UIAnim())
-- 云层放在 under_root（在 HUD 之下）：拉远镜头时云在天上、地在下面。
-- 210 行的 GetGameModeProperty("cloudcolour") or {1,1,1}：
--   游戏模式可覆盖云色，缺省白色。
-- ⚠️ 219 行 SetMultColour 的第四参（alpha）固定为 0 —— 初始全透明。
--   真正的淡入在 UpdateClouds（1672 行）里每帧按镜头距离算。
--   「初始透明 + 事件驱动淡入」避免了在没拉远镜头时白白付费画一层全屏。
    self.clouds.cloudcolour = GetGameModeProperty("cloudcolour") or {1, 1, 1}
    self.clouds:SetClickable(false)
    self.clouds:SetHAnchor(ANCHOR_MIDDLE)
    self.clouds:SetVAnchor(ANCHOR_MIDDLE)
    self.clouds:SetScaleMode(SCALEMODE_FIXEDSCREEN_NONDYNAMIC)
    self.clouds:GetAnimState():SetBank("clouds_ol")
    self.clouds:GetAnimState():SetBuild("clouds_ol")
    self.clouds:GetAnimState():SetForceSinglePass(true)
    self.clouds:GetAnimState():PlayAnimation("idle", true)
    self.clouds:GetAnimState():SetMultColour(self.clouds.cloudcolour[1], self.clouds.cloudcolour[2], self.clouds.cloudcolour[3], 0)
    self.clouds:Hide()

    self.serverpause_underlay = self.under_root:AddChild(Image("images/global.xml", "square.tex"))
-- 服务器暂停遮罩：一层半透明黑 + FILLSCREEN。
-- ★ 注意它挂在 under_root 而不是 overlayroot：
--   这样遮罩会盖住云层但**盖不住 HUD 本体**，
--   玩家暂停时仍能看见自己的血条和背包。
--   挂错根就会变成「暂停时整个 UI 都看不见」，非常容易搞错。
-- ⚠️ 231 行在构造期就调 SetServerPaused(TheNet:IsServerPaused(true))：
--   因为 229 行刚 Hide 过，若客户端进游戏时服务器已是暂停态，
--   忘了同步就会漏掉遮罩。
    self.serverpause_underlay:SetVRegPoint(ANCHOR_MIDDLE)
    self.serverpause_underlay:SetHRegPoint(ANCHOR_MIDDLE)
    self.serverpause_underlay:SetVAnchor(ANCHOR_MIDDLE)
    self.serverpause_underlay:SetHAnchor(ANCHOR_MIDDLE)
    self.serverpause_underlay:SetScaleMode(SCALEMODE_FILLSCREEN)
    self.serverpause_underlay:SetTint(0,0,0,0.5)
	self.serverpause_underlay:Hide()
	self.serverpaused = false
    self:SetServerPaused(TheNet:IsServerPaused(true))

    self.eventannouncer = self.under_root:AddChild(Widget("eventannouncer_root"))
-- ⚠️【真实的字段复用，可读性陷阱】
--   233 行 self.eventannouncer 指向「根容器」，237 行又把它改指向「内层容器」。
--   于是 self.eventannouncer 最终只代表**内层**那个，根容器句柄丢失。
-- 为什么仍然能工作：1767 行 OffsetServerPausedWidget 用它取位置，
--   两个容器位置相同（内层只是加了 offset），取谁都一样。
-- 但这是「同一个字段先后指两个东西」的典型坏味道：
--   一旦有人想给根容器加属性，就必须先读代码确认拿到的是内层。
    self.eventannouncer:SetScaleMode(SCALEMODE_PROPORTIONAL)
    self.eventannouncer:SetHAnchor(ANCHOR_MIDDLE)
    self.eventannouncer:SetVAnchor(ANCHOR_TOP)
    self.eventannouncer = self.eventannouncer:AddChild(Widget("eventannouncer"))
    self.eventannouncer:SetPosition(0, GetGameModeProperty("eventannouncer_offset") or 0)

    if TheFrontEnd:GetActiveScreen() == ThePlayer.HUD then
-- ⚠️ 这里用了全局 ThePlayer.HUD 而不是 self.owner.HUD / self。
--   在分屏（is_split_screen）场景下 ThePlayer 只是其中一个本地玩家，
--   第二个玩家的 HUD 走不到这个分支。
--   → 移植多本地玩家支持时，这里是第一处要改的。
-- 触发时机：PushScreen 会在 923 行 AddChild Controls 之前执行，
--   所以这里 self.controls 尚不存在（533 行也检查了 controls ~= nil，
--   说明作者知道这个顺序问题，但 240 行没加同样的检查）。
        ThePlayer.HUD:OffsetServerPausedWidget(TheFrontEnd.serverpausewidget)
    end
end

function PlayerHud:OnDestroy()
-- 【★ 屏幕销毁钩子】OnDestroy 会被 FrontEnd:PopScreen（frontend.lua:1109）调用。
-- 247 行 TheCamera:PopScreenHOffset(self) 是一个**配对 hack**：
--   giftitempopup.lua:95 在 ApplySkin 里 PushScreenHOffset(self.owner.HUD, ...)，
--   也就是给 **HUD** 推了一个横向镜头偏移；HUD 销毁时必须弹出，
--   否则镜头会永久偏移。
--   → 这暴露了 FollowCamera 的一个设计弱点：偏移栈以 ref 为键，
--     谁推的谁负责弹，全靠调用点自觉，成对关系在两个文件之间、
--     编译器管不到。本文件在 470/493/508/550/569/608/625/660 行
--     重复了 8 次同样的弹调用，全是同一个 hack。
    --Hack for holding offset when transitioning from giftitempopup to wardrobepopup
    TheCamera:PopScreenHOffset(self)

    if self.playerstatusscreen ~= nil then
-- ★ 销毁时的清理顺序：先让子屏幕自己关嵌套界面，再 Kill，最后置 nil。
-- 250 行 CloseUserCommandPickerScreen 必须**先于** Kill：
--   那是 playerstatusscreen 内部再压的一层屏，
--   直接 Kill 父屏会让这层成为孤儿（还在 FrontEnd 的 screenstack 里，
--   但 inst 已被 Remove）。→ 屏幕有嵌套时，销毁必须自顶向下拆。
-- ⚠️ 254 行 Screen.OnDestroy(self) 内部就是 self:Kill()（screen.lua:19-21），
--   所以「先清子项再 Kill」这个顺序不能反。
        self.playerstatusscreen:CloseUserCommandPickerScreen()
        self.playerstatusscreen:Kill()
        self.playerstatusscreen = nil
    end
    Screen.OnDestroy(self)
end

function PlayerHud:OnLoseFocus()
-- ══【焦点链：OnLoseFocus 的完整清单】
-- 失焦 = 有别的屏幕压上来了。此时必须把所有「半开着」的东西收干净：
--   261 CloseCrafting / 262 CloseSpellWheel / 264 CloseCommandWheel
--   267-269 CloseControllerInventory
-- 271-273 手柄模式下把激活物品退回原槽 —— 不然手柄拔掉后
--   物品还处于「被手柄选中」的悬空状态。
-- 274-284 把 hover 提示和所有 toast 的手柄焦点态清掉。
-- ★ 设计模式：**失焦清理用「无条件全清」而非「谁开的谁关」**。
--   因为要判断「谁开的」需要维护一张所有权表，成本高且易漏；
--   全清是幂等的，代价只是关几个本就没开的界面。
-- ⚠️ 但这个取舍有代价：OnGainFocus（287 行）**没有**对称地全部恢复，
--   它只恢复 toast/复活按钮的焦点态。因为恢复需要知道之前开过什么。
    Screen.OnLoseFocus(self)
    TheInput:EnableMouse(true)
-- 失焦时**强制打开**鼠标（与 OnGainFocus 的按需开启相反）。
-- 理由：焦点已经交给别的屏幕了，此时不接管鼠标，
--   就可能出现「界面在但鼠标不可用」的僵死态。

    self:CloseCrafting()
	self:CloseSpellWheel()
	if self:IsCommandWheelOpen() then
	    self:CloseCommandWheel()
	end

    if self:IsControllerInventoryOpen() then
        self:CloseControllerInventory()
    end

    if self.owner ~= nil and TheInput:ControllerAttached() then
        self.owner.replica.inventory:ReturnActiveItem()
    end
    if self.controls ~= nil then
-- ⚠️ 这里访问 self.controls.hover 与 self.controls.toastitems 时加了
--   `if self.controls ~= nil` 守卫，但 261-269 行的 CloseCrafting 等
--   内部又访问 self.controls.craftingmenu 而没有守卫。
--   → 守卫是不完整的：说明 SetMainCharacter 之前若真的失焦，仍会崩。
--   实践中没崩，因为 HUD 是随 ActivateHUD 一起 PushScreen + SetMainCharacter 的
--   （player_common.lua:744-751），窗口极窄。这是「靠调用时序侥幸正确」。
        self.controls.hover:Hide()
		for i, v in ipairs(self.controls.toastitems) do
			v:ToggleHUDFocus(false)
		end

        local resurrectbutton = self.controls.status:GetResurrectButton()
        if resurrectbutton ~= nil then
            resurrectbutton:ToggleHUDFocus(false)
        end
    end
end

function PlayerHud:OnGainFocus()
-- ══【OnGainFocus：输入设备的接管点】
-- 核心是一个**互斥决策**：手柄接上就关鼠标，鼠标就用鼠标。
-- 289-290：TheInput:EnableMouse(not controller)。
--   注意这里是全局的——会影响整个前端，不只是 HUD。
-- 292-306：按设备形态切换 HUD 自身的表现。
-- ⚠️ 308 行 `if not TheInput:ControllerAttached()` 才关轮盘/背包，
--   逻辑与 257 行的无条件全清**不对称**：
--   鼠标切手柄时，正在开着的合成菜单会被保留（因为要切到手柄版合成）；
--   手柄切鼠标时则关掉。这是刻意的，但读代码极易看漏。
    Screen.OnGainFocus(self)
    local controller = TheInput:ControllerAttached()
    TheInput:EnableMouse(not controller)

    if self.controls ~= nil then
        self.controls:SetHUDSize()
        if controller then
            self.controls.hover:Hide()
        else
            self.controls.hover:Show()
        end
		for i, v in ipairs(self.controls.toastitems) do
			v:ToggleHUDFocus(true)
		end
        local resurrectbutton = self.controls.status:GetResurrectButton()
        if resurrectbutton ~= nil then
            resurrectbutton:ToggleHUDFocus(true)
        end
    end

    if not TheInput:ControllerAttached() then
		if self:IsCommandWheelOpen() then
			self:CloseCommandWheel()
		end

        if self:IsControllerInventoryOpen() then
            self:CloseControllerInventory()
        end
    end
end

function PlayerHud:Toggle(targetindicators)
-- ★ Toggle 用 shown 标志位而非查询可见性。
--   注意它把 targetindicators 一起切（322-326 / 329-333）——
--   HUD 隐藏时目标指示器也要隐藏，否则会看到「没有 HUD 的世界标记」。
-- ⚠️ 319 行只在 self.shown 为真时隐藏，为假时显示，
--   但 self.shown 初值是 nil（Screen/Widget 构造器都没设），
--   所以首次 Toggle 走 else 分支 = 显示。方向正确，但是靠 nil 的假值性，
--   属于「隐式契约」。
    if self.shown then
        self:Hide()
        if targetindicators and self.targetindicators then
            for i, target in pairs(self.targetindicators) do
                target:Hide()
            end
        end
    else
        self:Show()
        if self.targetindicators then
            for i, target in pairs(self.targetindicators) do
                target:Show()
            end
        end
    end
end

function PlayerHud:Hide()
-- ⚠️【Hide 与 Show 不对称】
--   Hide（337）额外做了两件事：关投票界面、关指令选择器；
--   Show（348）只做 self.shown = true + root:Show()。
--   看起来是刻意的（341 行注释解释：投票界面是本地前端弹窗，
--   挂在别的地方不受 root:Show 影响，必须手动关）。
--   但这也意味着「HUD 隐藏 → 弹出投票 → 显示 HUD」不会恢复投票态。
--   实践中投票界面不可在 HUD 隐藏时弹出，所以没暴露。
-- ⚠️ 342 行 self.controls.votedialog 没有 nil 守卫，
--   而 343 行却检查了 self.playerstatusscreen ~= nil。
--   如果 SetMainCharacter 之前 Hide 就会崩（见 274 行的同类问题）。
    self.shown = false
    self.root:Hide()

    --Normally, HUD hides are tied to gameplay logic, but we need to manually force close some locally controlled FE popup screens.
    self.controls.votedialog:CloseControllerVoteScreen()
    if self.playerstatusscreen ~= nil then
        self.playerstatusscreen:CloseUserCommandPickerScreen()
    end
end

function PlayerHud:Show()
    self.shown = true
    self.root:Show()
end

function PlayerHud:GetFirstOpenContainerWidget()
-- ⚠️ GetFirstOpenContainerWidget 用 next() 取「任意一个」，不是「第一个」。
--   next 的返回顺序是哈希序，**无保证**。
--   函数名里的 First 有误导性。调用方若依赖它拿到确定的某个容器，
--   会得到随机的那个。
-- 实际用途是「拿任意一个来算某个全局量」，此时无序无害；
--   但这是个应当改名的函数（GetAnyOpenContainerWidget）。
-- 另一个隐含事实：self.controls.containers 为空时 next 返回 nil，
--   本函数返回 nil 而不报错——调用方必须处理 nil。
    local k, v = next(self.controls.containers)
    return v
end

local function CloseAllChestContainerWidgets(self)
-- CloseAllChestContainerWidgets 用「父节点是谁」来近似判断「是不是箱子」：
-- 360 行注释直言这是 cheap check。
-- 依据：只有普通箱子才挂在 containerroot 下；背包等挂在别处。
-- → 用**树的位置**承载语义，省掉了给每个容器打标签的维护成本。
--   代价是脆弱：一旦某个箱子类型改挂 containerroot（比如为了层级需要），
--   打开法术轮盘时就会把它误关掉。这类隐式契约应写进注释（作者做了，赞）。
	for _, v in pairs(self.controls.containers) do
		--cheap check for "chest" type containers
		if v:GetParent() == self.controls.containerroot then
			v:Close()
		end
	end
end

local function CloseContainerWidget(self, container, side)
-- ⚠️【形参未被使用】function CloseContainerWidget(self, container, side)
--   side 在函数体内一次都没出现。
--   调用点 381 行还把 side 传了进来（CloseContainer → CloseContainerWidget）。
--   → 死参数。可能是早期版本用它区分左右侧，后来改用「父节点判定」
--     （361 行）后忘了删。删掉它不影响行为。
    for k, v in pairs(self.controls.containers) do
        if v.container == container then
            v:Close()
        end
    end
end

function PlayerHud:CloseContainer(container, side)
-- ★【输入独占的落地：CloseContainer 的手柄分支】
-- 手柄 / 整合背包模式下**不立刻关容器**，只置一个脏标记：
--   379 self.controls.inv.rebuild_pending = true
-- 真正的关闭发生在背包控件重建时（inventorybar 的 RebuildLayout）。
-- 为什么：手柄背包是一整块重建式布局，容器挂在它内部；
--   直接 Close 会破坏正在进行的重建。置标记 = 「让重建器代劳」。
-- → ★★ 这是 UI 里非常典型的「延迟重建（脏标记 + 下帧消费）」模式，
--   和 inventorybar.lua:150-155 的 rebuild_pending 是同一套思路。
--   移植自研 UI 时，「交互状态变更」不要直接改视图，
--   写成标记让唯一的重建入口消费，可以从根本上避免状态撕裂。
    if container == nil then
        return
    elseif side and (TheInput:ControllerAttached() or Profile:GetIntegratedBackpack()) then
        self.controls.inv.rebuild_pending = true
    else
        CloseContainerWidget(self, container, side)
    end
end

local function OpenContainerWidget(self, container, side)
-- ══【★ 挂载点决策：数据驱动的 UI 布局（本文件最值得学的一段）】
-- 同一个 ContainerWidget，根据**容器副本的 type 字段**挂到不同的根上。
-- 392 行的 typefn 支持「按玩家动态决定类型」的容器（如某些随角色变的背包）。
-- 393-401 是一张**纯数据映射表**：type 字符串 → 父容器。
-- ★ 为什么用「查表 + 兜底」而不是 if/elseif 链：
--   1) 新增容器类型只需加一行，不用改控制流
--   2) 最后的 self.controls.containerroot 是兜底，
--      未知类型自动落到「普通箱子位」，**永不返回 nil**
--   3) Lua 的 `or` 短路天然形成「第一个匹配即返回」
-- ⚠️ 换写法会怎样错：如果写成 if type == "inv" then ... else return end，
--   模组新增一种容器 type 就会拿到 nil parent → AddChild 崩溃。
--   「兜底分支必须存在」是自研 UI 的硬规则。
-- 这一段是「服务端数据字段 → 客户端界面结构」的最短路径示范：
--   容器 type 是网络变量，客户端拿到就能决定布局，无需询问服务端。
    local containerwidget = ContainerWidget(self.owner)
	local parent
	if side then
		parent = self.controls.containerroot_side
	else
		local _container = container.replica.container
-- ⚠️ 391 行先取 _container = container.replica.container，
--   392 行又用 _container.typefn。链式取值 + or 兜底写在一行里，
--   非常紧凑但易错：若 container.replica 本身为 nil 会崩。
--   这里靠「ContainerWidget 只在有副本的容器上打开」这个前提保证。
--   写作规范上建议拆成三行并对 container.replica 加守卫。
		local _type = _container and (_container.typefn and _container.typefn(container, self.owner) or _container.type)
		parent =
			(_type == "inv" and self.controls.inv.toprow_inv) or
			(_type == "hand_inv" and self.controls.inv.hand_inv) or
			(_type == "side_inv" and self.controls.secondary_status.side_inv) or
			(_type == "side_inv_behind" and self.controls.containerroot_side_behind) or
			(_type == "top_rack" and self.controls.containerroot_under) or
			(_type == "chest_addon" and self.controls.containerroot_over) or
			self.controls.containerroot
	end

	parent:AddChild(containerwidget)
-- ★ AddChild 到选定的父级。★ 但紧接着 409 行又 MoveToBack ——
--   「挂上去但置于最底」，保证新开的箱子不会盖住同级的其它 HUD 元素
--   （比如同层的背包格）。
-- → UI 里「层级归属」与「绘制顺序」是**两件事**：
--   AddChild 决定树的归属（谁负责销毁、谁接收输入），
--   MoveToFront/Back 决定 z 序。混淆二者是常见 bug 来源。

    --self.controls[side and "containerroot_side" or "containerroot"]:AddChild(containerwidget)
    --self.controls.bottom_root:AddChild(containerwidget)
    --self.controls.inv.hand_inv:AddChild(containerwidget)

	containerwidget:MoveToBack()
    containerwidget:Open(container, self.owner)
    self.controls.containers[container] = containerwidget
-- ★ self.controls.containers[container] = containerwidget：
--   **用容器实体当键**建立反查表。后续 CloseContainerWidget（368 行）
--   就是遍历它按 container 反查 widget。
-- → 「实体 → 控件」映射表是 UI 层的必备结构：
--   因为事件从玩法侧来时手里只有实体，没有控件句柄。
-- ⚠️ 这张表**没有在容器控件被销毁时清理**——
--   容器消失（被烧掉/被卸载）后表里会留下失效条目。
--   缓解：所有读取处都先查 v.container == container 且 353 行有 IsValid 检查。
--   彻底解法是监听容器的 onremove 事件主动 RemoveField。
	self.controls.inv:OnNewContainerWidget(containerwidget)

	if parent == self.controls.containerroot then
-- 只有挂在「普通箱子位」的容器才关法术轮盘。
-- 因为法术轮盘是径向菜单，箱子窗口会挡住它的可读区域；
-- 而背包/侧栏容器不挡（轮盘画在它们旁边）。
-- → 「打开 A 要关 B」的条件应当绑定到**具体的层级冲突**，
--   而不是无脑互斥。这是 UI 层级设计里最需要想清楚的部分。
		self:CloseSpellWheel()
	end
end

function PlayerHud:OpenContainer(container, side)
    if container == nil then
        return
    elseif side and (TheInput:ControllerAttached() or Profile:GetIntegratedBackpack()) then
        self.controls.inv.rebuild_pending = true
    else
        OpenContainerWidget(self, container, side)
    end
end

function PlayerHud:RemoveDressupWidget()
-- ⚠️【字段名拼写：dressupAvatarPopUpcreen，缺了一个 s】
--   正确应为 dressupAvatarPopUpScreen 或 dressupAvatarPopupScreen。
--   已核实：本文件内 8 处（430/431/432/437/438/439/711/712/713）
--   **全部一致**使用这个错拼，所以当前功能正常。
--   但它极易与 playerinfoscreen / playerinfoscreen 混淆，
--   且 711 行是唯一的**赋值点**，其余全是读取。
-- ⚠️ 更值得警惕的是：本文件没有在构造器（77-83 行）声明该字段，
--   也没有 :RemoveDressupWidget 的调用点在 playerhud 内，
--   唯一调用来自 dressupavatarpopup.lua:106 的动画回调。
--   → 字段的创建点（711）与销毁点（431/438 与外部回调）分散在两个文件，
--     典型地容易漏。移植时建议收进一个专用管理器。
    if self.dressupAvatarPopUpcreen then
        self.dressupAvatarPopUpcreen:Kill()
        self.dressupAvatarPopUpcreen = nil
    end 
end

function PlayerHud:TogglePlayerInfoPopup(player_name, data, show_net_profile, force)
-- TogglePlayerInfoPopup：换装预览与普通信息面板**互斥**。
-- ★ 用 if/elseif 而非两个独立 if —— 保证同一时刻只有一个存在。
-- ⚠️ 440 行 `elseif self.OpenPlayerInfoScreen ~= nil` 是个**真缺陷**：
--   OpenPlayerInfoScreen 是本文件的**方法**（708 行定义），
--   它作为类成员永远非 nil → 这个条件恒为真。
--   作者本意应是 `elseif self.playerinfoscreen ~= nil`（小写）。
--   后果：只要 dressupAvatarPopUpcreen 为 nil 就走这个分支，
--   恰好等价于作者想要的「否则处理普通面板」，所以**当前行为正确**；
--   但 441 行的 POPUPS.PLAYERINFO:Close(self.owner) 因此会
--   在每次打开普通面板前都无条件执行一次。
--   → 属于「条件写错但结果侥幸正确」，比直接写错更危险：
--     后人把 OpenPlayerInfoScreen 这个方法删掉/改名，行为会突变。
-- 已核实 popupmanager.lua:53 定义了 POPUPS.PLAYERINFO，
--   playerinfopopupscreen.lua:189 也在用它，调用方存在，不是死代码。
    if self.dressupAvatarPopUpcreen ~= nil then
        self.dressupAvatarPopUpcreen:Close()
        self.dressupAvatarPopUpcreen = nil
    elseif self.OpenPlayerInfoScreen ~= nil then
        POPUPS.PLAYERINFO:Close(self.owner)
    self:OpenPlayerInfoScreen(player_name, data, show_net_profile, force)
    end
end

--ThePlayer.HUD:ShowEndOfMatchPopup({victory=true})
function PlayerHud:ShowEndOfMatchPopup(data)
-- ShowEndOfMatchPopup 里的延迟是**演出节奏**不是性能考虑：
-- 448 行 `data.victory and 2.5 or 0` —— 赢了等 2.5 秒（让胜利演出演完），
--   输了立刻弹。
-- → ★ UI 里的 DoTaskInTime 常常是「叙事调度」而非「延后处理」，
--   读代码时容易误判为性能优化而去掉它。
-- ⚠️ 449 行只在 endofmatchpopup == nil 时创建，
--   但没有任何地方把它置回 nil（grep 本文件无 Close/置 nil）。
--   若 endofmatch 事件重复触发，第二次调用什么都不会发生。
    self.inst:DoTaskInTime(data.victory and 2.5 or 0, function()
        if self.endofmatchpopup == nil then
            local popupdata =
            {
                title = data.victory and STRINGS.UI.HUD.LAVAARENA_WIN_TITLE or STRINGS.UI.HUD.LAVAARENA_LOSE_TITLE,
                body = data.victory and STRINGS.UI.HUD.LAVAARENA_WIN_BODY or STRINGS.UI.HUD.LAVAARENA_LOSE_BODY,
            }
            self.endofmatchpopup = self.root:AddChild(EndOfMatchPopup(self.owner, popupdata))
        end
    end)
end

function PlayerHud:OpenScreenUnderPause(screen)
-- ══★【屏幕栈：本文件最重要的架构决策点】
-- 同一个「打开弹窗」动作，在暂停与未暂停下走**两条不同的栈操作**：
--   461-462 暂停屏已开 → InsertScreenUnderTop（插到栈顶「下面」）
--   464      未暂停     → PushScreen（正常压栈）
-- 为什么要分：PauseScreen 是模态，它必须留在最顶，否则玩家在暂停时
--   打开衣柜，衣柜会盖住暂停菜单 —— 视觉上像是「暂停结束了」。
--   而物品仍然要可见（打开衣柜是为了在暂停时换装）。
-- → ★★ 这是「模态层」与「内容层」分离的最小实现。
--   更完整的做法是给屏幕打 modality 标签，栈操作由标签自动决定；
--   DST 选择用「判断当前栈顶是不是 PauseScreen」这个特判，
--   简单但每加一个模态屏（服务器暂停、错误弹窗）都得改这里。
-- ⚠️ 判定用的是字符串比较（1150 行 IsPauseScreenOpen 同款），
--   屏名一改这里就静默失效。
    if self:IsPauseScreenOpen() then
        TheFrontEnd:InsertScreenUnderTop(screen)
    else
        TheFrontEnd:PushScreen(screen)
    end
end

function PlayerHud:OpenItemManagerScreen()
-- ══★【跨屏数据传递的「最近礼物」机制】
-- 打开礼物弹窗 → 拆包 → ApplySkin（giftitempopup.lua:92-98）→
--   立刻 PushScreen 衣柜弹窗，并把 item_types/item_ids 存进 HUD 的
--   self.recentgifts，通过 SetRecentGifts（829 行）。
-- 衣柜弹窗构造时读 self.recentgifts（526-527 行）预选这些物品。
-- ★ 为什么数据要「借道 HUD」而不是全局变量或返回值：
--   因为**中间没有调用者**——ApplySkin 是被事件驱动的，
--   没有一个函数调用栈能把返回值传下去。HUD 是两个屏幕共同持有的对象，
--   是天然的共享信箱。
--   → 自研 UI 遇到「A 屏关闭时要把数据交给 B 屏」时，
--     标准解法就是找一个长生命周期的宿主对象当信箱。
-- ⚠️ 470 行的 PopScreenHOffset 是 247 行那个 hack 的第三次出现。
    --Hack for holding offset when transitioning from giftitempopup to wardrobepopup
    TheCamera:PopScreenHOffset(self)
    self:ClearRecentGifts()

    if self.giftitempopup ~= nil and self.giftitempopup.inst:IsValid() then
        TheFrontEnd:PopScreen(self.giftitempopup)
    end
    local item = TheInventory:GetUnopenedItems()[1]
    if item ~= nil then
        self.giftitempopup = GiftItemPopUp(self.owner, { item.item_type }, { item.item_id })
        self:OpenScreenUnderPause(self.giftitempopup)
        return true
    else
        return false
    end
end

local function OnClearRecentGifts(inst, self)
-- ⚠️ DoTaskInTime(0, ...) 不是「立刻执行」，而是**下一帧**执行。
--   为什么要延后一帧：PopScreen（500 行）会同步触发 giftitempopup 的
--   OnDestroy → SetAutopaused(false)。若在同帧清 recentgifts，
--   衣柜弹窗的构造可能还没跑完。延后一帧让整个切换事务结束。
-- → ★ UI 事务的通用手法：**「关闭」动作要延后一帧清理状态**，
--   否则清理会插进开/关流程中间，产生半初始化状态。
-- 486-489 用一个具名 local function 而非内联匿名函数，
--   是为了让 495 行能保存任务句柄并在 839 行 Cancel 它。
    self.recentgiftstask = nil
    self:ClearRecentGifts()
end

function PlayerHud:CloseItemManagerScreen()
    --Hack for holding offset when transitioning from giftitempopup to wardrobepopup
    TheCamera:PopScreenHOffset(self)
    if self.recentgiftstask == nil then
        self.recentgiftstask = self.inst:DoTaskInTime(0, OnClearRecentGifts, self)
    end

    if self.giftitempopup ~= nil then
        if self.giftitempopup.inst:IsValid() then
            TheFrontEnd:PopScreen(self.giftitempopup)
        end
        self.giftitempopup = nil
    end
end

function PlayerHud:OpenWardrobeScreen(target)
-- ══★【OpenWardrobeScreen：屏幕栈编排的完整样板】
-- 固定五步，文件里 20 多对 Open*/Close* 全是这个模板：
--   1) 508 弹镜头偏移（配对 hack）
--   2) 510-512 若已开过同款弹窗，先 Pop 掉
--   3) 514-529 构造新屏（target 有无 → 两款不同的衣柜屏）
--   4) 531-536 若地图开着，把地图小地图收起来
--   5) 538-539 清信箱 + 按 460 行的规则入栈
-- ★ 步骤 2「先关后开」是防重入的关键：没有它，
--   连按两次打开会压两个屏，PopScreen 时只弹一个，另一个泄漏在栈里。
-- ⚠️ 531 行的 `if not TheWorld.ismastersim` 是端判定：
--   地图 UI 只在客户端有，服务端进这个分支会访问 nil 的 controls。
    --Hack for holding offset when transitioning from giftitempopup to wardrobepopup
    TheCamera:PopScreenHOffset(self)

    if self.wardrobepopup ~= nil and self.wardrobepopup.inst:IsValid() then
        TheFrontEnd:PopScreen(self.wardrobepopup)
    end

    if target ~= nil then
        self.wardrobepopup =
            GridScarecrowClothingPopupScreen(
                target,
                self.owner,
                Profile
            )
    else
        self.wardrobepopup =
            GridWardrobePopupScreen(
                self.owner,
                Profile,
                self.recentgifts ~= nil and self.recentgifts.item_types or nil,
                self.recentgifts ~= nil and self.recentgifts.item_ids or nil
            )
    end

    if not TheWorld.ismastersim then
        local map = TheFrontEnd:GetOpenScreenOfType("MapScreen")
        if map ~= nil and self.controls ~= nil then
            self.controls:HideMap()
        end
    end

    self:ClearRecentGifts()
    self:OpenScreenUnderPause(self.wardrobepopup)
    return true
end

function PlayerHud:CloseWardrobeScreen()
-- ══★【延迟重试：一个真实存在的「屏打架」处理】
-- 548 行判断当前栈顶不是 "ItemServerContactPopup"，否则：
--   560-562 延迟 0.2 秒**再试一次**（递归调用自己）。
-- 为什么：拆礼物/寄件流程会临时压一个 ItemServerContactPopup，
--   此时用户又点了衣柜。若强行 PopScreen 衣柜，
--   屏幕栈顺序会乱（PopScreen 可以弹非栈顶的屏，见 frontend.lua:1103-1111，
--   它会 table.remove 后 break，栈顶仍是别人）。
-- → ★★★ 「重试直到前置界面消失」是屏幕栈里防冲突的标准手法，
--   比加锁/加状态机便宜得多。代价是要有超时兜底，
--   而这里**没有超时**（若 ItemServerContactPopup 因 bug 卡住，
--   CloseWardrobeScreen 会每 0.2 秒自我重试，永不停止）。
-- ⚠️ 这是真实的资源泄漏型缺陷形态：无限重试定时器。
-- 同一模板在 599/653 行重复两次。
    local activescreen = TheFrontEnd:GetActiveScreen()

    if activescreen == nil then return end

    if activescreen.name ~= "ItemServerContactPopup" then
        --Hack for holding offset when transitioning from giftitempopup to wardrobepopup
        TheCamera:PopScreenHOffset(self)
        self:ClearRecentGifts()

        if self.wardrobepopup ~= nil then
            if self.wardrobepopup.inst:IsValid() then
                TheFrontEnd:PopScreen(self.wardrobepopup)
            end
            self.wardrobepopup = nil
        end
    else
        self.inst:DoTaskInTime(.2, function()
            self:CloseWardrobeScreen()
        end)
    end
end


function PlayerHud:OpenGroomerScreen(target,filter)
    --Hack for holding offset when transitioning from giftitempopup to groomerpopup
    TheCamera:PopScreenHOffset(self)

    if self.groomerpopup ~= nil and self.groomerpopup.inst:IsValid() then
        TheFrontEnd:PopScreen(self.groomerpopup)
    end

    assert(target, "No Target for skinning")
   -- assert(target.components.skinner_beefalo, "TARGET IS NOT SKINABLE BEEFALO")
    self.groomerpopup =
        GridGroomerPopupScreen(
            target,
            self.owner,
            Profile,
            nil,
            nil,
            filter
        )

    if not TheWorld.ismastersim then
        local map = TheFrontEnd:GetOpenScreenOfType("MapScreen")
        if map ~= nil and self.controls ~= nil then
            self.controls:HideMap()
        end
    end

    self:ClearRecentGifts()
    self:OpenScreenUnderPause(self.groomerpopup)
    return true
end

function PlayerHud:CloseGroomerScreen()
    local activescreen = TheFrontEnd:GetActiveScreen()

    if activescreen == nil then return end

    if activescreen.name ~= "ItemServerContactPopup" then
        --Hack for holding offset when transitioning from giftitempopup to groomerpopup
        TheCamera:PopScreenHOffset(self)
        self:ClearRecentGifts()

        if self.groomerpopup ~= nil then
            if self.groomerpopup.inst:IsValid() then
                TheFrontEnd:PopScreen(self.groomerpopup)
            end
            self.groomerpopup = nil
        end
    else
        self.inst:DoTaskInTime(.2, function()
            self:CloseGroomerScreen()
        end)
    end
end


function PlayerHud:OpenHermitCrabWardrobeScreen(target, filter)
    --Hack for holding offset when transitioning from giftitempopup to groomerpopup
    TheCamera:PopScreenHOffset(self)

    if self.hermitcrabwardrobepopup ~= nil and self.hermitcrabwardrobepopup.inst:IsValid() then
        TheFrontEnd:PopScreen(self.hermitcrabwardrobepopup)
    end

    self.hermitcrabwardrobepopup =
        GridHermitCrabWardrobePopupScreen(
            target,
            self.owner,
            Profile,
            nil,
            nil,
            filter
        )

    if not TheWorld.ismastersim then
        local map = TheFrontEnd:GetOpenScreenOfType("MapScreen")
        if map ~= nil and self.controls ~= nil then
            self.controls:HideMap()
        end
    end

    self:ClearRecentGifts()
    self:OpenScreenUnderPause(self.hermitcrabwardrobepopup)
    return true
end

function PlayerHud:CloseHermitCrabWardrobeScreen()
    local activescreen = TheFrontEnd:GetActiveScreen()

    if activescreen == nil then return end

    if activescreen.name ~= "ItemServerContactPopup" then
        --Hack for holding offset when transitioning from giftitempopup to hermitcrabwardrobepopup
        TheCamera:PopScreenHOffset(self)
        self:ClearRecentGifts()

        if self.hermitcrabwardrobepopup ~= nil then
            if self.hermitcrabwardrobepopup.inst:IsValid() then
                TheFrontEnd:PopScreen(self.hermitcrabwardrobepopup)
            end
            self.hermitcrabwardrobepopup = nil
        end
    else
        self.inst:DoTaskInTime(.2, function()
            self:CloseHermitCrabWardrobeScreen()
        end)
    end
end

function PlayerHud:OpenCookbookScreen()
    self:CloseCookbookScreen()
    self.cookbookscreen = CookbookPopupScreen(self.owner)
    self:OpenScreenUnderPause(self.cookbookscreen)
    return true
end

function PlayerHud:CloseCookbookScreen()
    if self.cookbookscreen ~= nil then
        if self.cookbookscreen.inst:IsValid() then
            TheFrontEnd:PopScreen(self.cookbookscreen)
		end
        self.cookbookscreen = nil
    end
end

function PlayerHud:OpenPlantRegistryScreen()
    self:ClosePlantRegistryScreen()
    self.plantregistryscreen = PlantRegistryPopupScreen(self.owner)
    self:OpenScreenUnderPause(self.plantregistryscreen)
    return true
end

function PlayerHud:ClosePlantRegistryScreen()
    if self.plantregistryscreen ~= nil then
        if self.plantregistryscreen.inst:IsValid() then
            TheFrontEnd:PopScreen(self.plantregistryscreen)
		end
        self.plantregistryscreen = nil
    end
end

function PlayerHud:OpenPlayerInfoScreen(player_name, data, show_net_profile, force)
    self:ClosePlayerInfoScreen()
    if data and data.inst ~= nil and data.inst:HasTag("dressable") then
        self.dressupAvatarPopUpcreen = self.controls.right_root:AddChild( DressupAvatarPopup(self.owner, player_name, data) )
        self.dressupAvatarPopUpcreen.started = false
        self.dressupAvatarPopUpcreen:Start()
    else
        self.playerinfoscreen = PlayerInfoPopupScreen(self.owner, player_name, data, show_net_profile, force)
    self:OpenScreenUnderPause(self.playerinfoscreen)
    return true
    end
end

function PlayerHud:ClosePlayerInfoScreen()
    if self.playerinfoscreen ~= nil then
        if self.playerinfoscreen.inst:IsValid() then
            TheFrontEnd:PopScreen(self.playerinfoscreen)
        end
        self.playerinfoscreen = nil
    end
end

function PlayerHud:OpenScrapbookScreen()
    self:CloseScrapbookScreen()
    self.scrapbookscreen = ScrapbookScreen(self.owner)
    self:OpenScreenUnderPause(self.scrapbookscreen)
    return true
end

function PlayerHud:CloseScrapbookScreen()
    if self.scrapbookscreen ~= nil then
        if self.scrapbookscreen.inst:IsValid() then
            TheFrontEnd:PopScreen(self.scrapbookscreen)
        end
        self.scrapbookscreen = nil
    end
end

function PlayerHud:OpenInspectaclesScreen()
    self:CloseInspectaclesScreen()
    self.inspectaclesscreen = InspectaclesScreen(self.owner)
    self:OpenScreenUnderPause(self.inspectaclesscreen)
    return true
end

function PlayerHud:CloseInspectaclesScreen()
    if self.inspectaclesscreen ~= nil then
        if self.inspectaclesscreen.inst:IsValid() then
            TheFrontEnd:PopScreen(self.inspectaclesscreen)
        end
        self.inspectaclesscreen = nil
    end
end

-- BALATRO WIDGET
function PlayerHud:OpenBalatroScreen(target, jokers, cards)
    self:CloseBalatroScreen()
    self.balatroscreen = BalatroScreen(self.owner, target, jokers, cards)
    self:OpenScreenUnderPause(self.balatroscreen)
    return true
end

function PlayerHud:CloseBalatroScreen()
    if self.balatroscreen ~= nil then
        if self.balatroscreen.inst:IsValid() then
            TheFrontEnd:PopScreen(self.balatroscreen)
        end
        self.balatroscreen = nil
    end
end
----------------

function PlayerHud:OpenPumpkinCarvingScreen(target)
	self:ClosePumpkinCarvingScreen()
	self.pumpkincarvingscreen = PumpkinCarvingScreen(self.owner, target)
	self:OpenScreenUnderPause(self.pumpkincarvingscreen)
	return true
end

function PlayerHud:ClosePumpkinCarvingScreen()
	if self.pumpkincarvingscreen then
		if self.pumpkincarvingscreen.inst:IsValid() then
			TheFrontEnd:PopScreen(self.pumpkincarvingscreen)
		end
		self.pumpkincarvingscreen = nil
	end
end

function PlayerHud:OpenPumpkinHatCarvingScreen(target)
	self:ClosePumpkinHatCarvingScreen()
	self.pumpkinhatcarvingscreen = PumpkinHatCarvingScreen(self.owner, target)
	self:OpenScreenUnderPause(self.pumpkinhatcarvingscreen)
	return true
end

function PlayerHud:ClosePumpkinHatCarvingScreen()
	if self.pumpkinhatcarvingscreen then
		if self.pumpkinhatcarvingscreen.inst:IsValid() then
			TheFrontEnd:PopScreen(self.pumpkinhatcarvingscreen)
		end
		self.pumpkinhatcarvingscreen = nil
	end
end

function PlayerHud:OpenSnowmanDecoratingScreen(target, obj)
	self:CloseSnowmanDecoratingScreen()
	self.snowmandecoratingscreen = SnowmanDecoratingScreen(self.owner, target, obj)
	self:OpenScreenUnderPause(self.snowmandecoratingscreen)
	return true
end

function PlayerHud:CloseSnowmanDecoratingScreen()
	if self.snowmandecoratingscreen then
		if self.snowmandecoratingscreen.inst:IsValid() then
			TheFrontEnd:PopScreen(self.snowmandecoratingscreen)
		end
		self.snowmandecoratingscreen = nil
	end
end

--Helper for transferring data between screens when transitioning from giftitempopup to wardrobepopup
function PlayerHud:SetRecentGifts(item_types, item_ids)
    if self.recentgiftstask ~= nil then
        self.recentgiftstask:Cancel()
        self.recentgiftstask = nil
    end
    self.recentgifts = { item_types = item_types, item_ids = item_ids }
end

--Helper for transferring data between screens when transitioning from giftitempopup to wardrobepopup
function PlayerHud:ClearRecentGifts()
    if self.recentgiftstask ~= nil then
        self.recentgiftstask:Cancel()
        self.recentgiftstask = nil
    end
    self.recentgifts = nil
-- ⚠️【ClearRecentGifts 与 SetRecentGifts（829 行）几乎逐字相同】
--   唯一差别是 834 赋 recentgifts vs 843 赋 nil。
--   抽成一个 `ClearRecentGifts(keep)` 能省一半，
--   但两份分开写的好处是「意图显式」，不算缺陷，只是冗余。
end

function PlayerHud:RefreshControllers() -- this is really the event handler for "continuefrompause"
-- ══★【RefreshControllers：输入设备热切换的完整事务】
-- 触发源是 continuefrompause（85 行）—— 玩家从暂停恢复时重算。
-- 848-850 手柄模式下停掉鼠标追踪（否则鼠标会乱飘）。
-- 855 ★ 脏标记判定用「双条件与」：控制器接上没 + 整合背包设没，
--   两者任一变化都要重建背包布局。
-- 857-870 是**四种迁移场景的穷举**，注释写得很清楚：
--   无背包→切手柄 / 有背包→切手柄 / 有背包→切鼠标 / 都没变
--   每个分支的动作不同（snap / 关容器 / 开容器）。
-- → ★★★ 这是「状态迁移」的标准写法：先判定迁移类型，
--   再执行对应迁移，最后重算派生状态（rebuild_pending）。
--   比「先无条件重建再修正」快一个数量级（重建要 Kill/重建几十个控件）。
-- ⚠️ 855 行直接访问 self.controls.inv，没有 nil 守卫。
--   848 行也没有。而 OnLoseFocus（274 行）同类访问是有守卫的。
--   靠 ActivateHUD 的时序（SetMainCharacter 必在 PushScreen 之后）保证不崩。
    local controller_mode = TheInput:ControllerAttached()
	if controller_mode then
	    TheFrontEnd:StopTrackingMouse()
	end

	TheFrontEnd:UpdateRepeatDelays()

	local integrated_backpack = controller_mode or Profile:GetIntegratedBackpack()
    if self.controls.inv.controller_build ~= controller_mode or self.controls.inv.integrated_backpack ~= integrated_backpack then
        self.controls.inv.rebuild_pending = true
        local overflow = self.owner.replica.inventory:GetOverflowContainer()
        if overflow == nil then
            --switching to controller inv with no backpack
            --don't animate out from the backpack position
            self.controls.inv.rebuild_snapping = true
        elseif controller_mode or integrated_backpack then
            --switching to controller with backpack
            --close mouse backpack container widget
            CloseContainerWidget(self, overflow.inst, overflow:IsSideWidget())
        elseif overflow:IsOpenedBy(self.owner) then
            --switching to mouse with backpack
            --reopen backpack if it was opened
            OpenContainerWidget(self, overflow.inst, overflow:IsSideWidget())
        end
    end

	self.controls.craftingmenu:RefreshControllers(controller_mode)
-- ★ 重建背包之后还要通知合成菜单 —— 因为手柄合成菜单的
--   焦点链依赖背包控件是否存在。
--   → 「重建一个控件」必须显式通知所有持有它引用的模块。
--     DST 没有依赖注入，全靠手工调。漏掉就是「手柄切过去合成菜单失灵」。

	if self._CraftingHintAllRecipesEnabled ~= Profile:GetCraftingHintAllRecipesEnabled() then
-- ★ 缓存 Profile 值的变化检测（_CraftingHintAllRecipesEnabled）。
-- 920 行在 SetMainCharacter 里初始化这个缓存。
-- → 【数据 → UI 刷新链路】Profile 是客户端本地设置（不走网络），
--   没有事件可监听，只能靠「每帧/每次刷新时比对缓存」来发现变化。
--   这是本地设置驱动 UI 的**唯一**可用模式，值得记住。
-- ⚠️ 与 855 行同款：Profile 的 getter 每次都读文件/Profile 对象，
--   放进每帧路径要注意开销。这里是事件驱动所以没问题。
		self.owner:PushEvent("refreshcrafting")
		self._CraftingHintAllRecipesEnabled = Profile:GetCraftingHintAllRecipesEnabled()
	end

end

function PlayerHud:ShowWriteableWidget(writeable, config)
-- ══★【顺序陷阱：SetEditing 必须在 PushScreen 之后】
-- 887 行先入栈，890 行才 SetEditing(true)。887 行的注释明说原因。
-- 推测的真实原因：PushScreen 内部（frontend.lua:992-994）会调
--   screen:SetDefaultFocus()，若此时 textedit 已处于编辑态，
--   焦点会被 SetDefaultFocus 抢走，导致「光标不出现」。
--   ——即 **PushScreen 有副作用，会重置焦点**，任何「聚焦某控件」
--     的动作都必须排在它后面。
-- → ★★★ 自研 UI 必踩：压栈/显示/激活 这类操作会重置焦点与输入态，
--   「设焦点/设编辑态」必须后置。这与 frontend.lua:970
--   TheInputProxy:FlushInput()（清空输入队列）是同一类问题。
    if writeable == nil then
        return
    else
        self.writeablescreen = WriteableWidget(self.owner, writeable, config)
        self:OpenScreenUnderPause(self.writeablescreen)
        if TheFrontEnd:GetActiveScreen() == self.writeablescreen then
            -- Have to set editing AFTER pushscreen finishes.
            self.writeablescreen.edit_text:SetEditing(true)
        end
        return self.writeablescreen
    end
end

function PlayerHud:CloseWriteableWidget()
    if self.writeablescreen then
        self.writeablescreen:Close()
        self.writeablescreen = nil
    end
end

function PlayerHud:GoSane()
-- GoSane/GoInsane/GoEnlightened 三个方法体完全同构，
-- 只是 PlayAnimation 的参数不同。
-- ★ 它们是 925-927 行三个事件的回调 —— 「玩法事件 → 界面动画」的最短链路。
-- ⚠️ 903/907/911 直接访问 self.vig，若在 SetMainCharacter（922 行创建）
--   之前被事件触发就是 nil 崩溃。
--   934-940 行的初始化分支会在 SetMainCharacter 内补调一次，
--   说明作者意识到「首帧状态要对齐」的问题。
    self.vig:GetAnimState():PlayAnimation("basic", true)
end

function PlayerHud:GoInsane()
    self.vig:GetAnimState():PlayAnimation("insane", true)
end

function PlayerHud:GoEnlightened()
    self.vig:GetAnimState():PlayAnimation("basic", true)
end

function PlayerHud:SetMainCharacter(maincharacter)
-- ══★【SetMainCharacter = HUD 的真正初始化入口】
-- 构造函数（67 行）只建五棵空根；一切内容都在这里挂上去。
-- 拆分的好处：**构造函数可以在没有玩家实体的情况下跑**
--   （ActivateHUD 先 PlayerHud() 再 SetMainCharacter，player_common.lua:742-751），
--   两步之间 PushScreen 已经在栈里了。
-- ⚠️ 后果：全文件有大量 `self.controls ~= nil` 守卫，
--   因为「已构造但未初始化」是一个真实存在的中间状态。
--   这是一个应当记住的代价：**分阶段初始化会让每个访问点都得自证安全**。
-- ★ 917 行反写 maincharacter.HUD = self —— 建立双向引用，
--   之后任何地方都能 owner.HUD 拿回 HUD（本文档大量使用这个反向引用）。
    if maincharacter then
        maincharacter.HUD = self
        self.owner = maincharacter

		self._CraftingHintAllRecipesEnabled = Profile:GetCraftingHintAllRecipesEnabled() -- cache the value so we can refresh the crafting menu with it changes
-- 缓存 Profile 值，供 RefreshControllers（875 行）比对。
-- 放在这里而不是构造函数：因为要等 owner 就位才有意义。

        self:CreateOverlays(self.owner)
        self.controls = self.root:AddChild(Controls(self.owner))

        self.inst:ListenForEvent("gosane", function() self:GoSane() end, self.owner)
-- ★ 三个 sanity 事件监听。注意第三个参数是 self.owner（玩家实体），
--   不是 TheWorld —— 事件由玩家自己 Push。
-- 928-932 newactiveitem 的回调体看起来绕：
--   只在 data ~= nil and data.item ~= nil 时 CloseSpellWheel。
--   即「拿起新物品 → 关掉旧法术轮盘」。合理。
        self.inst:ListenForEvent("goinsane", function() self:GoInsane() end, self.owner)
        self.inst:ListenForEvent("goenlightened", function() self:GoEnlightened() end, self.owner)
		self.inst:ListenForEvent("newactiveitem", function(owner, data)
				if data ~= nil and data.item ~= nil then
					self:CloseSpellWheel()
				end
			end, self.owner)

        if self.owner.replica.sanity ~= nil then
-- ★ 首帧状态对齐：HUD 是延迟创建的，若玩家在创建前就已经疯/ enlightenment，
--   光等事件会漏掉这一次。
--   → 「事件驱动 UI」必须配一个「创建时读当前值」的对齐点，
--     否则会出现「加载后第一次状态变化不反映」的经典 bug。
-- ⚠️ 这里读的是 replica.sanity（客户端副本），
--   证明理智值是**网络同步到客户端**的 —— UI 可以直接判定，无需问服务器。
            if self.owner.replica.sanity:IsCrazy() then
                self:GoInsane()
            elseif self.owner.replica.sanity:IsEnlightened() then
                self:GoEnlightened()
            end
        end

        local overflow = maincharacter.replica.inventory ~= nil and maincharacter.replica.inventory:GetOverflowContainer() or nil
-- 换主角时重开背包容器窗。
-- ⚠️ 三重 and/or 兜底：maincharacter.replica.inventory 本身可能 nil
--   （角色未完全加载），replica.inventory 可能 nil，
--   GetOverflowContainer 可能返回 nil。
-- → ★ UI 初始化期读副本的标准兜底范式，抄。
        if overflow ~= nil then
            overflow:Close()
            overflow:Open(maincharacter)
        end

    end
end

local GODMODEINDICATOR_HATS =
{
    "feather",
    "goggles",
    "green_mushroom",
    "ice",
    "merm",
    "monkey_small",
    "rain",
    "scrap",
    "skeleton",
    "top",
    "wathgrithr_improved",
}

function PlayerHud:OnUpdate(dt)
-- ══★【OnUpdate：每帧路径的三个纪律】
-- 本函数每帧执行，因此：
-- 1) 967 行每个分支都要 nil 检查（Profile / vig / controls 可能未就绪）
-- 2) 976/992 行用 CAN_USE_DBUI / CHEATS_ENABLED 编译期开关，
--    发行版里整段被剔除 —— 「调试 UI 不进发行包」的标准做法
-- 3) 创建控件用「惰性 + 缓存」（978/995 行的 if nil then 创建）
-- ⚠️ 代价：惰性创建意味着每帧都要做一次状态比对。
--   这里比对的是廉价的布尔/tag，没问题；
--   若换成「每帧遍历 100 个子控件找变化」就会成为性能热点。
    if Profile ~= nil and self.vig ~= nil then
        if RENDER_QUALITY.LOW == Profile:GetRenderQuality() or TheConfig:IsEnabled("hide_vignette") then
            self.vig:Hide()
        else
            self.vig:Show()
        end
    end

    -- Indicate if history recording is active
    if CAN_USE_DBUI and self.controls ~= nil then
-- CAN_USE_DBUI：调试 UI 总开关。
-- 历史录制指示器 978-989 行：启→建、关→Kill 并置 nil。
-- ⚠️ 987 行 `self.controls.historyrecordingindicator.inst.widget:Kill()`
--   连下两层取 widget —— 因为 Text 控件对象与 inst.widget 是同一个，
--   但这里存的是 Text 实例，用 .inst.widget 绕了一圈。
--   直接 .controls.historyrecordingindicator:Kill() 等价。属冗余写法。
-- ★ 977 行每帧查 TheFrontEnd.debugMenu.history:IsEnabled()，
--   说明这个开关没有事件可订阅，只能轮询。
        if TheFrontEnd.debugMenu.history:IsEnabled() then
			if self.controls.historyrecordingindicator == nil then
				self.controls.historyrecordingindicator = self.controls:AddChild(Text(DEFAULTFONT, 64))
				self.controls.historyrecordingindicator:SetPosition(400, 180, 0)
				self.controls.historyrecordingindicator:SetString("*** History recording ON ***")
				self.controls.historyrecordingindicator:SetColour(UICOLOURS.RED)
				self.controls.historyrecordingindicator:SetHAnchor(ANCHOR_LEFT)
				self.controls.historyrecordingindicator:SetVAnchor(ANCHOR_BOTTOM)
			end
        elseif self.controls.historyrecordingindicator ~= nil then
            self.controls.historyrecordingindicator.inst.widget:Kill()
            self.controls.historyrecordingindicator = nil
        end
    end

    if CHEATS_ENABLED and self.owner ~= nil and self.controls ~= nil then
-- ★ 无敌模式指示器：随机戴一顶帽子（999 行 GetRandomItem）。
-- 这是纯本地开发便利功能，CHEATS_ENABLED 为假时整段不编译。
-- 1010-1014 关闭时先播 death 动画，1.5 秒后才 Kill ——
--   延迟 Kill 是为了让死亡动画播完。
-- ⚠️ 1012 行 `inst.widget:Kill()` 同 987 行，是冗余的绕路写法。
        -- Just an indicator so we can tell if we're in godmode or not
        if self.owner:HasTag("invincible") then
            if self.controls.godmodeindicator == nil then
                self.controls.godmodeindicator = self.controls.inv:AddChild(UIAnim())
                self.controls.godmodeindicator:GetAnimState():SetBank("pigman")
                self.controls.godmodeindicator:GetAnimState():SetBuild("pig_guard_build")
                self.controls.godmodeindicator:GetAnimState():OverrideSymbol("swap_hat", "hat_"..GetRandomItem(GODMODEINDICATOR_HATS), "swap_hat")
                self.controls.godmodeindicator:GetAnimState():Hide("ARM_carry_up")
                self.controls.godmodeindicator:SetHAnchor(ANCHOR_LEFT)
                self.controls.godmodeindicator:SetVAnchor(ANCHOR_BOTTOM)
                self.controls.godmodeindicator:SetPosition(100, 50, 0)
                self.controls.godmodeindicator:SetScale(0.2, 0.2, 0.2)
                self.controls.godmodeindicator:SetFacing(FACING_DOWN)
                self.controls.godmodeindicator:GetAnimState():MakeFacingDirty()
                self.controls.godmodeindicator:GetAnimState():PlayAnimation("idle_happy")
                self.controls.godmodeindicator:GetAnimState():PushAnimation("idle_loop")
            end
        elseif self.controls.godmodeindicator ~= nil then
            self.controls.godmodeindicator:GetAnimState():PlayAnimation("death")
            self.controls.godmodeindicator.inst:DoTaskInTime(1.5, function(inst) inst.widget:Kill() end)
            self.controls.godmodeindicator = nil
        end
    end

    if self.leafcanopy then
        self.leafcanopy:OnUpdate(dt)
    end

	if self.owner ~= nil then
-- ══★【OnUpdate 里的「焦点失效」检测 —— 焦点链的关键一环】
-- 法术轮盘打开期间，每帧检查书是否还「可用」：
--   1024 实体已失效（被烧掉/卸载）
--   1025 燃料耗尽（fueldepleted 标签）
--   1026 组件判定不能被该玩家使用（CanBeUsedBy）
-- 任一成立就 CloseSpellWheel。
-- → ★★★ 这是用户提到的「焦点链：控件销毁时焦点如何失效」的核心答案：
--   DST **没有**「控件销毁自动撤销焦点」的反向通知机制。
--   Widget:Kill（widget.lua）只摘父子关系，不通知祖先清焦点。
--   所以「持有焦点的对象失效」必须由**持有者自己轮询检测**。
--   换成事件驱动（实体 onremove 时主动关闭）会更省，
--   但那样要处理「实体已死但事件已错过」的时序，两种方案各有代价。
-- ⚠️ 1035 行的 CanEntitySeeTarget 只在「没有 inventoryitem 副本」时检查，
--   而 1030-1034 的 IsGrandOwner 只在有副本时检查。
--   这两个是互斥分支而非「都要检查」，逻辑正确但极易看漏。
		local spellbook = self:GetCurrentOpenSpellBook()
		if spellbook ~= nil then
			if not spellbook:IsValid() or
				spellbook:HasTag("fueldepleted") or
				not (spellbook.components.spellbook and spellbook.components.spellbook:CanBeUsedBy(self.owner))
			then
				self:CloseSpellWheel()
			else
				local inventoryitem = spellbook.replica.inventoryitem
				if inventoryitem then
					if not inventoryitem:IsGrandOwner(self.owner) then
						self:CloseSpellWheel()
					end
				elseif not CanEntitySeeTarget(self.owner, spellbook) then
					self:CloseSpellWheel()
				end
			end
		end
	end
end

function PlayerHud:HideControllerCrafting()
-- HideControllerCrafting/ShowControllerCrafting 用 MoveTo 滑出/滑入 200 像素。
-- ⚠️ -200 是**魔法数字**，且 1048 行是 0 —— 两者必须成对且数值匹配，
--   但没有任何断言保证它们一致。移植时改成同一个常量更安全。
-- ★ 用 MoveTo 而不是 Hide：保留展开动画，且动画期间控件仍在树上，
--   不会因为 Hide 触发 OnLoseFocus 链。
    local pt = self.controls.craftingmenu:GetPosition()
    self.controls.craftingmenu:MoveTo(pt, Vector3(-200, pt.y, pt.z), .25)
end

function PlayerHud:ShowControllerCrafting()
    local pt = self.controls.craftingmenu:GetPosition()
    self.controls.craftingmenu:MoveTo(pt, Vector3(0, pt.y, pt.z), .25)
end

function PlayerHud:OpenControllerInventory()
-- ══★【OpenControllerInventory：输入独占的手柄版】
-- 1055 StopTrackingMouse —— 与 849 行同样的「手柄接管鼠标」动作，
--   但这里是在打开动作里做的。
-- 1062-1064 toast 全部切到手柄态；1065 显示状态数字。
-- ⚠️ 1067 行 `self.owner.components.playercontroller:OnUpdate(0)`
--   手动驱动一次玩法组件的更新，dt 传 0。
--   意图：立刻让玩家控制器知道「UI 变了」（比如暂停 AOE 目标选择），
--   而不等下一帧。
--   → ★ 这是 UI 主动 poke 玩法层的少见但正确的用法：
--     UI 状态变化必须立刻通知玩法，否则玩家会有一帧的输入真空。
--   ⚠️ 用 OnUpdate(0) 而非一个专用方法，是把「帧驱动」当「事件」用的妥协；
--     若 playercontroller 的 OnUpdate 里含 dt 相关积分，dt=0 是安全的，
--     但这个安全性是隐式的、依赖实现的。
    TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/craft_open")
    TheFrontEnd:StopTrackingMouse()

    self:CloseCrafting()
	self:CloseSpellWheel()

    self:CloseCommandWheel()
    self.controls.inv:OpenControllerInventory()
	for i, v in ipairs(self.controls.toastitems) do
		v:ToggleController(true)
	end
    self.controls:ShowStatusNumbers()

    self.owner.components.playercontroller:OnUpdate(0)
end

function PlayerHud:CloseControllerInventory()
    if self:IsControllerInventoryOpen() then
        TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/craft_close")
    end
    self.controls:HideStatusNumbers()
    self.controls.inv:CloseControllerInventory()
	for i, v in ipairs(self.controls.toastitems) do
		v:ToggleController(false)
	end
end

function PlayerHud:HasInputFocus()
-- ══★★【模态与输入独占的总闸 —— 本文件最该学的一段】
-- 注释已经说了原理：HUD 永远在栈里，所以「栈顶不是我」就等于「我锁输入」。
-- 逐项拆解五个 or 分支：
--   1085-1086 有别的屏幕在 HUD 之上 → 我锁输入（最常见情形）
--   1087 textProcessorWidget 存在（文本转文字面板）→ 锁
--   1088-1089 控制器背包开着 → 锁
--   1090-1096 合成/法术轮/指令轮/升级模块开着 **且** 接了手柄 → 锁
--        （鼠标下这些轮盘不夺输入，鼠标仍要点世界）
--   1098 任何模组申请过输入焦点（modfocus）→ 锁
-- → ★★★★ 这是「模态」的**声明式**实现：
--   不在打开界面时去 disable 世界，而是在「查询焦点」时把各种状态或起来。
--   好处：输入查询点只有一个（frontend → HasInputFocus），
--   不会出现「A 界面忘了 disable、B 界面 disable 过头」这类失衡。
-- → ★★ 第 1090 行的「**且接了手柄**」是同一 UI 在两种输入设备下
--   模态性不同的例子。手柄导航必须独占（否则方向键会同时动角色），
--   鼠标下则可以点穿。移植时若手柄与鼠标共存，这一条必须逐个界面设计。
-- ⚠️ 1098 行 modfocus 由 SetModFocus（1101 行）写入，
--   全库无其他写入点 → 这是**专门留给模组的输入独占钩子**，
--   官方自己不用，模组作者靠它实现自定义弹窗的模态。
    --We're checking that the active screen is NOT us, because HUD
    --is always active, and we're saying that it locks input focus
    --when anything else is active on top of it.
    local active_screen = TheFrontEnd:GetActiveScreen()
    return (active_screen ~= nil and active_screen ~= self)
		or TheFrontEnd.textProcessorWidget ~= nil
		or (self.controls ~= nil and (
				self.controls.inv.open or
				(	(	self:IsCraftingOpen() or
						self:IsSpellWheelOpen() or
						self:IsCommandWheelOpen() or
						self:IsUpgradeModuleWidgetInputFocus()
					) and
					TheInput:ControllerAttached()
				)
			))
        or self.modfocus ~= nil
end

function PlayerHud:SetModFocus(modname, focusid, hasfocus)
-- ══★【modfocus：给模组的两级焦点租约表】
-- 结构：modfocus[modname][focusid] = true。
-- ★ 1110-1117 的「逐级回收」是精髓：
--   释放一个 focusid → 若该模组已无任何 focusid，删掉 modname 项
--   → 若已无任何模组，把 self.modfocus 置 nil。
--   这样 1088 行那个 `self.modfocus ~= nil` 判断才是**准确的**：
--   它读到的不是「曾经申请过焦点」，而是「此刻真的持有焦点」。
-- → ★★★★ 「引用计数式」的表结构设计范式，
--   对应 C++ 里的 intrusive refcount，Lua 里靠「逐级清空到 nil」实现。
--   若只置 self.modfocus[modname][focusid] = false 而不逐级回收，
--   HasInputFocus 会永远返回 true —— 世界永久失去输入。
-- ⚠️ 注意 elseif（1110）带三重守卫，而 if 分支（1102）不需要守卫：
--   「申请」幂等，「释放」才需要确认持有。
--   但这意味着**重复申请同一 focusid 不会计数**，
--   申请两次释放一次就彻底失去焦点。模组作者需自行保证配对。
    if hasfocus then
        if self.modfocus == nil then
            self.modfocus = { [modname] = { [focusid] = true } }
        elseif self.modfocus[modname] == nil then
            self.modfocus[modname] = { [focusid] = true }
        else
            self.modfocus[modname][focusid] = true
        end
    elseif self.modfocus ~= nil and self.modfocus[modname] ~= nil and self.modfocus[modname][focusid] then
        self.modfocus[modname][focusid] = nil
        if next(self.modfocus[modname]) == nil then
            self.modfocus[modname] = nil
            if next(self.modfocus) == nil then
                self.modfocus = nil
            end
        end
    end
end

function PlayerHud:IsControllerInventoryOpen()
-- ★ 下面 1121-1188 是一整组「Is*Open」谓词。
-- 两种写法并存，注意区分：
--   A 型（1121-1148）：查 self.controls 下的子控件状态，需要 nil 守卫
--   B 型（1150-1188）：查 TheFrontEnd 的栈顶屏名，**不需要** controls
-- ⚠️ 1138-1148 这批 A 型谓词全部带 `self.controls ~= nil`，
--   但 1232/1236 的 IsSpellWheelOpen / GetCurrentOpenSpellBook
--   **没有**守卫。
--   不对称的原因（推测）：spellwheel 是 controls 创建时就存在的固定控件，
--   而 craftingmenu 等可能被重建。
--   但 OnUpdate:1022 调用 GetCurrentOpenSpellBook 时只判了 self.owner，
--   若 SetMainCharacter 尚未跑完就会 nil 索引崩溃。窗口极窄。
-- ⚠️【★ 真实缺陷，已逐行核实】1196-1199 行 IsPlayerInfoPopUpOpen
--   读的是 self.PlayerInfoPopupScreen（大写 P，且少了 PopupS 的 S），
--   而唯一的赋值点是 715 行的 self.playerinfoscreen（全小写）。
--   grep 全库确认：self.PlayerInfoPopupScreen 仅出现在 1197/1198 两处读取，
--   从无任何赋值 → 该函数**恒返回 nil/false**。
--   受影响的两处调用：
--     1434 CONTROL_INSPECT 时「已开信息面板则关闭」——永不成立
--     1476 暂停键关闭信息面板 —— 永不成立
--   即：玩家信息面板一旦打开，无法用检查键或暂停键关闭。
--   为什么线上没被大面积报障：1427 行 playercontroller 的
--   ShouldPlayerHUDControlBeIgnored 可能在更上层拦掉了部分按键，
--   且该面板主要在鼠标下用（点黑底关闭，见 playerinfopopupscreen.lua:30）。
    return self.controls ~= nil and self.controls.inv.open
end

function PlayerHud:IsControllerCraftingOpen() -- deprecated - please switch to using IsCraftingOpen() or playercontroller:IsEnabled()
    return self.controls ~= nil and self.controls.craftingmenu:IsCraftingOpen()
end

function PlayerHud:IsCraftingOpen()
    return self.controls ~= nil and self.controls.craftingmenu:IsCraftingOpen()
end

function PlayerHud:IsCraftingBlockingGameplay()
	-- deprecated
    return false
end

function PlayerHud:IsCommandWheelOpen()
    return self.controls ~= nil and self.controls.commandwheel:IsOpen()
end

function PlayerHud:IsControllerVoteOpen()
    return self.controls ~= nil and self.controls.votedialog:IsControllerVoteOpen()
end

function PlayerHud:IsVoteOpen()
    return self.controls ~= nil and self.controls.votedialog:IsOpen()
end

function PlayerHud:IsPauseScreenOpen()
-- ⚠️ B 型谓词全部用**字符串比较**判屏：`active_screen.name == "PauseScreen"`。
-- Screen 的 name 来自构造第一个参数（68 行 Screen._ctor(self, "HUD")）。
-- 全库共 9 个这样的比较（1150-1188）。
-- → 代价：重命名任一 Screen 的 name 会**静默**让对应的 Is*Open 恒假，
--   编译器与测试都抓不到。
-- → 更好的做法：`TheFrontEnd:GetOpenScreenOfType("PauseScreen")`
--   （frontend.lua:1155）语义相同但意图更清晰；
--   最好的是 `active_screen:IsA(PlayerStatusScreen)` 这类类型判断。
-- ★ GetActiveScreen 返回的是**栈顶**，不是「已打开的任意一个」。
--   若同一个屏被压了两个（虽然各处都做了先关后开），这里只会看到最上面那个。
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and active_screen.name == "PauseScreen"
end

function PlayerHud:IsChatInputScreenOpen()
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and active_screen.name == "ChatInputScreen"
end

function PlayerHud:IsConsoleScreenOpen()
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and active_screen.name == "ConsoleScreen"
end

function PlayerHud:IsMapScreenOpen()
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and active_screen.name == "MapScreen"
end

function PlayerHud:IsStatusScreenOpen()
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and active_screen.name == "PlayerStatusScreen"
end

function PlayerHud:IsItemManagerScreenOpen()
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and active_screen.name == "GiftItemPopUp"
end

function PlayerHud:IsWardrobeScreenOpen()
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and (active_screen.name == "WardrobePopupScreen" or active_screen.name == "GridScarecrowClothingPopupScreen")
end

function PlayerHud:IsGroomerScreenOpen()
    local active_screen = TheFrontEnd:GetActiveScreen()
    return active_screen ~= nil and (active_screen.name == "GroomerPopupScreen")
end

function PlayerHud:IsPlayerAvatarPopUpOpen()
    return self.playeravatarpopup ~= nil
        and self.playeravatarpopup.started
        and self.playeravatarpopup.inst:IsValid()
end

function PlayerHud:IsPlayerInfoPopUpOpen()
    return self.PlayerInfoPopupScreen ~= nil
        and self.PlayerInfoPopupScreen.inst:IsValid()
end

function PlayerHud:OpenCrafting(search)
-- OpenCrafting 的三重前置条件：
--   1202 没开着 + 1202 craftingshown（HUD 里确实有合成栏）+ 游戏模式没禁
-- ★ 注意 game mode property 的作用：no_crafting 让竞技类模式直接砍掉合成。
-- 1213-1215 toast 切手柄态 —— 与 OpenControllerInventory（1062）同款，
--   说明「打开一个模态面板时把所有 toast 切到手柄态」是本文件的固定套路。
-- ⚠️ 1202 行 self.controls.craftingshown 无 nil 守卫。
	if not self:IsCraftingOpen() and self.controls.craftingshown and not GetGameModeProperty("no_crafting") then
		self:CloseSpellWheel()
		if self:IsControllerInventoryOpen() then
			self:CloseControllerInventory()
		end

        self:CloseCommandWheel()

		TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/craft_open")
		self.controls.craftingmenu:Open(search)

		for i, v in ipairs(self.controls.toastitems) do
			v:ToggleController(true)
		end
	end
end

function PlayerHud:CloseCrafting(silent)
    if self:IsCraftingOpen() then
		if not silent then
			TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/craft_close")
		end
	    self.controls.craftingmenu:Close()

		for i, v in ipairs(self.controls.toastitems) do
			v:ToggleController(false)
		end
    end
end

function PlayerHud:IsSpellWheelOpen()
	return self.controls.spellwheel:IsOpen()
end

function PlayerHud:GetCurrentOpenSpellBook()
	return self.controls.spellwheel.invobject
end

function PlayerHud:OpenSpellWheel(invobject, items, radius, focus_radius, bgdata)
-- ══★【OpenSpellWheel：径向菜单的数据 → 视图转换】
-- 这是「客户端就地改造数据再交给通用控件」的典范：
-- 1247 itemscpy = shallowcopy(v) —— 先浅拷贝，不改原数据
-- 1250-1272 给拷贝品挂上 execute / onfocus / ondown 三个闭包
-- ★★ 1252-1255 的 execute 闭包捕获了循环变量 i 与 v：
--   点第 i 项 → SelectSpell(i) → 再调原 execute(invobject)。
--   → 「把行为注入数据」而不是「让控件认识领域对象」：
--     spellwheel 控件完全不知道法术书的存在，只认 items 数组
--     里的 execute/onfocus/ondown 回调。
--   → ★★★ 这是 UI 层最重要的解耦模式：控件只认「视图模型」，
--     领域逻辑由调用方以闭包形式挂上。移植自研 UI 应优先采用。
-- ⚠️ 1250 shallowcopy 是**浅**拷贝：itemscpy[i] 与 v 共享内部表。
--   1258 行 `v.selected = ...` 故意改原对象（同步回 items），
--   1259-1263 的 onfocus 也直接改 items 里的 v.selected。
--   → 拷贝只是「顶层字段可替换」（execute/onfocus 被覆盖），
--     嵌套字段仍共享。理解这点才不会误以为已完全隔离。
-- 1274-1283 处理 default_focus：找出带默认焦点标记的项，
--   同时同步 items 与 itemscpy 的 selected —— 两份都要改。
	self:CloseCrafting()
	self:TryStopInspectingModules()
	if self:IsControllerInventoryOpen() then
		self:CloseControllerInventory()
	end
	CloseAllChestContainerWidgets(self)
	local itemscpy = {}
	local default_focus = nil
	for i, v in ipairs(items) do
		itemscpy[i] = shallowcopy(v)
		if v.execute ~= nil then
			itemscpy[i].execute = function()
				invobject.components.spellbook:SelectSpell(i)
				v.execute(invobject)
			end
			itemscpy[i].onfocus = function()
				for j, v in ipairs(items) do
					v.selected = i == j or nil
				end
				if invobject.components.spellbook.focussound then
					TheFocalPoint.SoundEmitter:PlaySound(invobject.components.spellbook.focussound)
				end
			end
			itemscpy[i].ondown = function()
				if self.controls.spellwheel.iscontroller then
					invobject.components.spellbook:SelectSpell(i)
					if not invobject.components.spellbook.closeonexecute then
						--return true to halt operation; Wheel's ondown for controllers usually hide's all other buttons
						return true
					end
				end
			end
		end
		if v.default_focus then
			default_focus = i
		end
	end
	if default_focus then
		for i, v in ipairs(items) do
			v.selected = i == default_focus or nil
			itemscpy[i].selected = v.selected
		end
	end
	self.controls.spellwheel:SetScale(TheFrontEnd:GetProportionalHUDScale()) --instead of GetHUDScale(), because parent already has SCALEMODE_PROPORTIONAL
-- ⚠️ 注释明说用 GetProportionalHUDScale() 而非 GetHUDScale()，
--   因为父级已经是 SCALEMODE_PROPORTIONAL。
-- → ★ 缩放不能连乘：父级已按比例缩放，控件再乘一次 HUD 缩放就变成平方，
--   在 4K 屏上会大得离谱。
--   「找一个已经缩放过的祖先」是 UI 缩放最常见的 bug 来源。
--   （GetHierarchicalScale 在 scrollablelist.lua:434 就是干这个的）
	self.controls.spellwheel:SetItems(itemscpy, radius, focus_radius)
	self.controls.spellwheel:Open()

	if bgdata then
-- 1288-1298 给轮盘加一个可配置的背景（不同法术书用不同底图）。
-- 1296 MoveToBack —— 背景必须在轮盘按钮**之下**，
-- 又一次印证「层级归属(AddChild)与 z 序(MoveToBack)是两件事」。
-- 1297 self.controls.spellwheel.bg = bg：挂回控件上，
--   使 CloseSpellWheel（1315 行）能找到并 Kill 它。
-- ⚠️ 若 OpenSpellWheel 被连续调用两次而没有 Close，
--   第二次的 1300 行 old 是第一次的 invobject，但 bg 会被覆盖，
--   第一次的 bg 泄漏在轮盘下（因为 MoveToBack 把它藏了，看不见但还在）。
--   实践中所有调用点都先 CloseCrafting/CloseSpellWheel（1241 行在函数开头有 CloseSpellWheel），
--   所以不会发生。
		local bg = self.controls.spellwheel:AddChild(UIAnim())
		bg:GetAnimState():SetBuild(bgdata.build)
		bg:GetAnimState():SetBank(bgdata.bank)
		bg:GetAnimState():PlayAnimation(bgdata.anim, bgdata.loop)
		if bgdata.widget_scale then
			bg:SetScale(bgdata.widget_scale)
		end
		bg:MoveToBack()
		self.controls.spellwheel.bg = bg
	end

	local old = self.controls.spellwheel.invobject
-- ★ 1300-1305 是「打开新对象前先通知旧对象离开」的配对模式：
--   old 收到 closespellwheel，新对象收到 openspellwheel。
--   → 领域对象（法术书）通过这两个事件自己管理附属 UI
--     （比如书的 UI 播放关闭动画），无需 HUD 逐个清理。
-- ⚠️ 1300 行读的是**上一轮**的 invobject（在 1301 行赋值之前读），
--   顺序正确但极易看错——把 1300/1301 调换就全错。
--   正确写法其实应是 local old = ... 提到 1284 之前，可读性更好。
	self.controls.spellwheel.invobject = invobject
	if old ~= nil and old:IsValid() then
		old:PushEvent("closespellwheel")
	end
	invobject:PushEvent("openspellwheel")
	local sfx = invobject.components.spellbook ~= nil and invobject.components.spellbook.opensound or nil
	if sfx ~= nil then
		TheFocalPoint.SoundEmitter:PlaySound(sfx)
	end
end

function PlayerHud:CloseSpellWheel(is_execute)
	self.controls.spellwheel:Close()

	if self.controls.spellwheel.bg then
		self.controls.spellwheel.bg:Kill()
		self.controls.spellwheel.bg = nil
	end

	local old = self.controls.spellwheel.invobject
	if old ~= nil then
		self.controls.spellwheel.invobject = nil
		if old:IsValid() then
			old:PushEvent("closespellwheel")
		end
		if old.components.spellbook ~= nil then
			local sfx
			if is_execute then
				sfx = old.components.spellbook.executesound
			else
				sfx = old.components.spellbook.closesound
			end
			if sfx ~= nil then
				TheFocalPoint.SoundEmitter:PlaySound(sfx)
			end
		end
		if is_execute and old == self.owner then
			self.controls:DelayControllerSpellWheelHint()
		end
	end
end

function PlayerHud:OpenCommandWheel()
-- ══★【OpenCommandWheel：唯一会「自动暂停游戏」的 UI】
-- 1372-1374：若 Profile 允许（即用户不想自动暂停），SetAutopaused(true)。
-- → ★★★ 这是「UI 反向操纵模拟」的少见但重要的例子：
--   指令轮盘（聊天/组队/管理）在多人游戏里会冻结世界，
--   所以它必须走 SetAutopaused 而不是简单 Hide。
--   CloseCommandWheel（1381-1383）对称地 SetAutopaused(false)。
-- ⚠️ 配对风险：SetAutopaused(true) 在 1373，Close 在 1382，
--   但两者分别被 `IsCommandWheelOpen()`（1378）守卫。
--   如果轮盘 Open 后立刻被别的路径 Close 且该路径不走本函数，
--   世界会永久暂停。OnLoseFocus（264 行）走的是本函数，安全。
-- ⚠️ 1344 行的 `self.is_split_screen` 后面挂着一段被注释掉的条件
--   （长注释块定界符形式，内容是另一个未启用的家长控制判断）。
--   本文件**保留了长注释块定界符**，提到它时要小心（见 SOP 坑 #6）。
--   注意这里**保留了长注释块定界符**；注释里提到它时要小心（见 SOP 坑 #6）。
--   语义：幽灵玩家 + 分屏 → 改开状态屏而不是指令轮盘。
	if self.owner:HasTag("playerghost") and (self.is_split_screen --[[or ParentalControls_BlockChat()]]) then
		self:ShowPlayerStatusScreen()
		return
	end

	local can_invite_now = IsConsole() and TheNet:CanSendInvitation() or false
-- ★ 1351 行的「脏判定重建」是本文件第二次出现这个模式：
--   只在「能否邀请」或「是否骑乘」变化时才重建整个指令轮盘。
--   重建成本高（几十个按钮），所以必须精确到「只有影响布局的因素」。
-- → 与 855 行的 rebuild_pending 是同一个思路的两个变体：
--   一个重建背包，一个重建指令轮盘。
	local is_mounted_now = self.owner.replica.rider and self.owner.replica.rider:IsRiding()	
	if (self.controls.can_invite ~= can_invite_now) or (self.controls.is_mounted ~= is_mounted_now) then
		-- rebuild the command wheel, something we care about has changed
		self.controls:BuildCommandWheel(self.is_split_screen)
	end

    TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/craft_open")
    TheFrontEnd:StopTrackingMouse()
	if self:IsControllerInventoryOpen() then
		self:CloseControllerInventory()
	end
	self:CloseCrafting()
	self:CloseSpellWheel()
	self:TryStopInspectingModules()

    self.controls.inv:Disable()
-- ★★ 打开指令轮盘时显式 Disable 背包与合成菜单 ——
--   这是**第二种模态机制**，与 HasInputFocus 的「声明式」并存的
--   「命令式」做法。
-- → 两种机制并存是 DST UI 的现状，也是可移植性最差的地方：
--   新人容易只实现其中一种，导致「界面关了但世界仍不能点」
--   或「界面关了但背包还是灰的」。
-- → 正确做法是统一走一种：推荐 HasInputFocus 那种声明式，
--   因为它的状态查询点在单一位置（input.lua → frontend → HasInputFocus）。
-- ⚠️ 这里 Disable 的是 inv 和 craftingmenu，
--   CloseCommandWheel（1386-1387）对称 Enable —— 这一对是配对的。
    self.controls.craftingmenu:Disable()
	for i, v in ipairs(self.controls.toastitems) do
		v:ToggleController(true)
	end
    self.controls.commandwheel:Open()

	if not Profile:GetCommandWheelAllowsGameplay() then
		SetAutopaused(true)
	end
end

function PlayerHud:CloseCommandWheel()
	if self:IsCommandWheelOpen() then
		TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/craft_close")
		
		if not Profile:GetCommandWheelAllowsGameplay() then
			SetAutopaused(false)
		end
	end
    self.controls.commandwheel:Close()
    self.controls.inv:Enable()
    self.controls.craftingmenu:Enable()
	for i, v in ipairs(self.controls.toastitems) do
		v:ToggleController(false)
	end
end

function PlayerHud:ShowPlayerStatusScreen(click_to_close, onclosefn)
-- ══★【Screen 实例缓存：ShowPlayerStatusScreen 的复用模式】
-- 1394-1396：只在第一次创建 Screen 实例，之后复用同一对象。
-- → ★★★ 与 PushScreen/PopScreen 语义强相关：
--   PopScreen 会调 screen:OnDestroy()（frontend.lua:1109），
--   而 Screen:OnDestroy 就是 self:Kill()（screen.lua:19-21）——
--   **被 Pop 的 Screen 是不可复用的死对象**。
--   所以「打开-关闭-再打开」必须每次 new 一个 Screen，
--   只有「不经过 PopScreen 的重复显示」才能复用。
--   这条约束解释了本文件里为什么几乎所有 Open*Screen 都 new 新实例，
--   而只有这个状态屏做了缓存。
-- ⚠️ 1400-1401 的 MoveToFront + Show 是为了把复用的旧实例重新提到最前。
--   若此前它被 Pop 过（已 Kill），1399 的 PushScreen 会操作一个死实体 ——
--   实践中因 109 行的 nil 化与 OnDestroy 清理而不会发生。
-- ★ 1397-1398 每次都重设回调与 click_to_close，说明复用对象的
--   可变状态必须在每次显示前重置 —— 复用即要求「状态在 Open 里全量初始化」。
    if self.playerstatusscreen == nil then
        self.playerstatusscreen = PlayerStatusScreen(self.owner)
    end
	self.playerstatusscreen.onclosefn = onclosefn
	self.playerstatusscreen.click_to_close = click_to_close
    TheFrontEnd:PushScreen(self.playerstatusscreen)
    self.playerstatusscreen:MoveToFront()
    self.playerstatusscreen:Show()
end

function PlayerHud:InspectSelf()
-- ══★【InspectSelf：三重守卫 + 「不追踪自己」的注释】
-- 1405-1408 三条与：可见 + 玩家控制器启用 + 无人机面板没开。
-- 1409 用 TheNet:GetClientTableForUser 取**客户端连接表**里的名字，
--   而不是用实体的 displayname —— 因为要显示的是 Steam 好友名。
-- 1411 行注释明说「不要追踪自己」（原文 don't track yourself），
--   即故意不给 client_obj 赋 inst。
-- ⚠️ 这个「故意不传」的写法很隐蔽：传 nil 是有语义的选择，不是遗漏。
--   后人「顺手补上 self.owner」会破坏它的设计意图。
    if self:IsVisible() and
		self.owner.components.playercontroller:IsEnabled() and
		not self.dronezapover.shown
	then
        local client_obj = TheNet:GetClientTableForUser(self.owner.userid)
        if client_obj ~= nil then
            --client_obj.inst = self.owner --don't track yourself
            self:TogglePlayerInfoPopup(client_obj.name, client_obj)
            return true
        end
    end
end

function PlayerHud:OnControl(control, down)
-- ══★★【OnControl：本文件的输入路由总表 —— 最该精读的一段】
-- 结构分五段，每段都有明确的「放弃所有权」语义：
--
-- 段1（1419-1429）**准入判断**，三道闸：
--   1419 先给基类 Screen 处理（基类返回 true 表示已消费）
--   1421-1426 HUD 自己隐藏时，只放行「解除服务器暂停」这一个键，
--          其余 input 全部 `return`（返回 nil = 不消费 = 穿透到世界）
--   1427-1429 玩家控制器说「这个键该被忽略」→ return true（消费掉）
-- ⚠️ 1421-1426 的 `return`（无值）vs 1428 的 `return true` 区别极大：
--   nil = 「我不处理，你继续」→ 世界会响应这个键；
--   true = 「我处理了，别往下传」→ 世界收不到。
--   这是 UI 输入路由里最容易写反的一处：
--   「HUD 隐藏时」这个分支必须穿透（否则玩家隐藏 HUD 后无法操作），
--   所以返回 nil 是**正确**的，不是遗漏。
--
-- 段2（1431-1452）仅按下时：检查/关闭信息面板、处理无人机面板
-- 段3（1453-1504）仅松开时：暂停、合成翻页、服务器暂停
-- ★★ 段2 用 `if down`、段3 用 `elseif control == CONTROL_PAUSE` ——
--   也就是说段3 只在**不是按下**时才走（1453 的 elseif 接在 1431 的 if 后面）。
--   「暂停键在松开时才触发」是这个游戏的手感设计，
--   移植时若改成按下触发会改变操作节奏。
-- 段4（1506-1513）**焦点外控件的事件探测** —— 见该处注释
-- 段5（1514-1630）其余按键的全局绑定
--
-- ⚠️ 1514 的 `elseif not down` 嵌在段4 的 elseif 链里，
--   意味着「松开时才处理」的判断被夹在段3 和段5 之间，
--   缩进（制表符与空格混用，本文件通病）让层次极难辨认。
--   重构建议：拆成 5 个独立函数，各自 return。
    if PlayerHud._base.OnControl(self, control, down) then
        return true
    elseif not self.shown then
		if self.serverpaused and down and control == CONTROL_SERVER_PAUSE then
			SetServerPaused(false)
			return true
		end
        return
    elseif self.owner.components.playercontroller:ShouldPlayerHUDControlBeIgnored(control, down) then
-- ★ 玩家控制器的「忽略此键」裁决。
--   → UI 与玩法的边界不只在 frontend，**玩法侧也有否决权**。
--   例如拉杆推箱子时，方向键归玩法；开界面时归 UI。
-- → 移植要点：这个函数是**唯一**的仲裁点，必须在 UI 之前调用，
--     否则会出现「UI 抢走了玩法需要的键」。
-- ⚠️ 1421 分支返回 nil（穿透）后**不会**走到这里，
--   意味着 HUD 隐藏时玩法侧的否决权也被跳过了。
--   实践中 HUD 隐藏只发生在切场景，此时世界交互本就不该发生。
        return true
    end

    if down then
        if control == CONTROL_INSPECT then
-- CONTROL_INSPECT 的三级与判定，顺序即优先级：
--   1433-1437 已开信息面板 → 切换（关闭）；
--     ⚠️ 因 1196 行的字段名缺陷，IsPlayerInfoPopUpOpen 恒假，
--       此分支**永不执行**（已核实）。
--   1438-1440 交给投票对话框处理
--   1440-1442 没有手柄目标且能 InspectSelf → 看自己
-- ★ 注意 1440 用 GetControllerTarget() == nil 作为条件：
--   手柄选中了一个目标时，检查键应作用于该目标而非自己。
-- → 手柄/鼠标两套交互的仲裁点，与 1090 行的手柄模态判断呼应。
            if self:IsVisible() and
                self:IsPlayerInfoPopUpOpen() and
                self.owner.components.playercontroller:IsEnabled() then
                self:TogglePlayerInfoPopup()
                return true
            elseif self.controls.votedialog:CheckControl(control, down) then
                return true
            elseif self.owner.components.playercontroller:GetControllerTarget() == nil
                and self:InspectSelf() then
                return true
            end
		elseif control == CONTROL_INSPECT_SELF then
			if self:InspectSelf() then
				return true
			end
		elseif control == CONTROL_SECONDARY then
			if self.dronezapover.shown and self.dronezapover:TryClose() then
				return true
			end
        end
    elseif control == CONTROL_PAUSE then
-- ══★【CONTROL_PAUSE 的双路径：手柄 vs 鼠标】
-- 1454-1461 手柄：取消 AOE 选中 → 关三个面板 → 压 PauseScreen。
--   **总是**压暂停屏（不检查是否已开）。
-- 1462-1489 鼠标：逐个尝试关闭，**只有都没关掉才**压暂停屏。
-- ★★★ 1463 的 closed 标志是本文件最值得学的「ESC 语义」实现：
--   玩家按 ESC 的**意图**是「退回上一层」，
--   而不是「打开暂停菜单」。所以要先给所有上层界面一次关闭机会，
--   都没接住才落到最底层菜单。
-- → 这就是 UI 的「返回栈」语义。自研 UI 若只做「ESC = 打开菜单」，
--   玩家会觉得界面很笨。
-- ⚠️ 但两套路径**不对称**：手柄路径不做 closed 判定，
--   所以手柄下在合成菜单里按暂停会直接压 PauseScreen 盖住合成菜单，
--   而鼠标下会先关合成菜单。这是手柄/鼠标的行为差异（疑似不一致）。
		if TheInput:ControllerAttached() then
            self.owner.components.playercontroller:CancelAOETargeting()
            self:CloseCrafting()
			self:CloseSpellWheel()
            if self:IsControllerInventoryOpen() then
                self:CloseControllerInventory()
            end
            TheFrontEnd:PushScreen(PauseScreen())
		else
			local closed = false
			if self.owner.components.playercontroller:IsAOETargeting() then
	            self.owner.components.playercontroller:CancelAOETargeting()
				closed = true
			end
            if self:IsCraftingOpen() then
                self:CloseCrafting()
                closed = true
            end
			if self:IsSpellWheelOpen() then
				self:CloseSpellWheel()
				closed = true
			end
			if self:IsPlayerInfoPopUpOpen() and
                self:TogglePlayerInfoPopup() then
                closed = true
			end
			if self.dronezapover.shown and self.dronezapover:TryClose() then
				closed = true
			end
            if self:TryStopInspectingModules() then
                closed = true
            end
			if not closed then
-- 「都没关掉」才压暂停屏。1487 行 PushScreen(PauseScreen()) 无参 ——
--   PauseScreen 自己会去 owner.HUD 找数据。
-- ★ 1490 行无条件 return true：无论是否压了暂停屏，这个键都被 HUD 消费，
--   不会穿透到世界去触发别的暂停逻辑。
	            TheFrontEnd:PushScreen(PauseScreen())
			end
		end
        return true
	elseif control == CONTROL_CRAFTING_PINLEFT then
		if self.controls ~= nil and self.controls.craftingmenu ~= nil and self.controls.craftingmenu.pinbar ~= nil then
			self.controls.craftingmenu.pinbar:GoToPrevPage()
			return true
		end
	elseif control == CONTROL_CRAFTING_PINRIGHT then
		if self.controls ~= nil and self.controls.craftingmenu ~= nil and self.controls.craftingmenu.pinbar ~= nil then
			self.controls.craftingmenu.pinbar:GoToNextPage()
			return true
		end
    elseif control == CONTROL_SERVER_PAUSE then
        SetServerPaused()
        return true
    end

    --V2C: This kinda hax? Cuz we don't rly want to set focus to it I guess?
-- ══★★【段4：焦点外控件的事件探测（V2C 自承认的 hack）】
-- 1506 行注释直白：作者也不确定为什么要这么写。
-- 机制：CheckControl 是「按这个键并返回是否处理」的探测接口，
--   但**不会给控件焦点**（注释说「我们不太想给它焦点」）。
-- → ★★★ 这是一个非常实用的 UI 模式，值得单独记住：
--   「让某个当前无焦点的控件也能响应某个键，但不夺取焦点」。
--   典型用途：常驻的提示条/通知条要能被快捷键消掉，
--   但绝不能抢走当前界面的焦点。
-- 1508 的复活按钮、1510 的物品通知、1512 的技能树通知三者并列，
--   说明这是「全局快捷通知」的标准挂载点。
-- ⚠️ 1510/1512 直接访问 self.controls.item_notification 等，无 nil 守卫；
--   且这三行在 `not down` 判断**之前**，所以按下松开都会调用 CheckControl。
--   → 控件必须自己处理 down/up 配对，否则会双触发。
    local resurrectbutton = self.controls.status:GetResurrectButton()
    if resurrectbutton ~= nil and resurrectbutton:CheckControl(control, down) then
        return true
    elseif self.controls.item_notification:CheckControl(control, down) then
        return true
    elseif self.controls.skilltree_notification:CheckControl(control, down) then
        return true        
    elseif not down then
-- ★ 1514 的 `elseif not down` 把「仅松开」的大批全局键绑定与段4 分开。
-- 这些键（地图、指令轮、聊天、合成、物品栏）都是「松开时响应」，
-- 目的是让长按/连按不重复触发。
-- ⚠️ 但 1532 行在此之上又叠了 `and TheInput:ControllerAttached()`：
--   即手柄的取消键处理**只在松开时**做。
--   1537-1541 的注释解释了为什么不在这里关法术轮盘：
--   轮盘自己在按下 CANCEL 时就关了，若这里再关，
--   「按 B 打开轮盘 → 松开 B 就立刻关掉」—— 因为 B 键同时是 CANCEL。
-- ★★ 这是**输入事件时序**的经典坑：同一个物理键映射到多个 control 时，
--   「按下」与「松开」会分别触发不同语义的处理。
-- → 移植手柄支持时，必须为每个键画出「down/up 分别触发什么」的表，
--     否则会出现「一按就开、一松就关」的抖动。
        if control == CONTROL_MAP then
            if not self:IsMapScreenOpen() then
				self:CloseCrafting()
				self:CloseSpellWheel()
                if self:IsControllerInventoryOpen() then
                    self:CloseControllerInventory()
                end
            end
            self.controls:ToggleMap()
            return true
        elseif control == CONTROL_OPEN_COMMAND_WHEEL then
			if self:IsCommandWheelOpen() then
				self:CloseCommandWheel()
			else
				self:OpenCommandWheel()
			end
			return true
        elseif control == CONTROL_CANCEL and TheInput:ControllerAttached() then
-- ══★【手柄取消键的「逐层关闭」链】
-- 与 1463 的鼠标 closed 标志同构，但只在手柄下生效。
-- 关闭顺序：合成 → 法术轮（不关，注释解释）→ 控制器背包 → 无人机面板
--        → 升级模块检查态。
-- ⚠️ 1536 的 elseif 链里，法术轮分支 `return true` 但什么都不做 ——
--   目的是「吃掉这个键，不让玩家控制器响应」，
--   因为法术轮已经自己关了，再让世界响应会导致误操作。
--   → 「空分支但 return」是刻意的「消费但不动作」，
--     读代码时极易误以为是遗漏而「顺手补上 CloseSpellWheel」，
--     那就重新引入 1537 注释里描述的 bug。
            if self:IsCraftingOpen() then
                self:CloseCrafting()
                return true
			elseif self:IsSpellWheelOpen() then
				--V2C: Wheel widget closes itself on CONTROL_CANCEL down already.
				--     Don't do this here because we can now open spell wheel via
				--     (B) button, and this would've instantly closed it when the
				--     button is released.
				--self:CloseSpellWheel()
				return true
            elseif self:IsControllerInventoryOpen() then
                self:CloseControllerInventory()
                return true
			elseif self.dronezapover.shown and self.dronezapover:TryClose() then
				return true
            elseif self:TryStopInspectingModules() then
                return true
            end
        --elseif control == CONTROL_TOGGLE_PLAYER_STATUS then DEPRECATED
        --    self:ShowPlayerStatusScreen(true)
        --    return true
		elseif control == CONTROL_TOGGLE_SAY then
			TheFrontEnd:PushScreen(ChatInputScreen(false))
			return true
		elseif control == CONTROL_TOGGLE_WHISPER then
			TheFrontEnd:PushScreen(ChatInputScreen(true))
			return true
		elseif control == CONTROL_TOGGLE_SLASH_COMMAND then
			local chat_input_screen = ChatInputScreen(false)
			chat_input_screen.chat_edit:SetString("/")
			TheFrontEnd:PushScreen(chat_input_screen)
			return true
		elseif control == CONTROL_START_EMOJI then
			local chat_input_screen = ChatInputScreen(false)
			chat_input_screen.chat_edit:SetString(":")
			TheFrontEnd:PushScreen(chat_input_screen)
			return true
        end
    elseif control == CONTROL_SHOW_PLAYER_STATUS then
        if not self:IsPlayerAvatarPopUpOpen() or self.playeravatarpopup.settled then
            self:ShowPlayerStatusScreen()
        end
        return true
    elseif control == CONTROL_OPEN_CRAFTING then
        if self:IsCraftingOpen() then
			if TheInput:IsControlPressed(CONTROL_CRAFTING_MODIFIER) then
				self.controls.craftingmenu.craftingmenu:StartSearching(true)
			else
	            self:CloseCrafting()
			end
            return true
        elseif not GetGameModeProperty("no_crafting") then
            local inventory = self.owner.replica.inventory
            if inventory ~= nil and inventory:IsVisible() then
                self:OpenCrafting(TheInput:IsControlPressed(CONTROL_CRAFTING_MODIFIER))
                return true
            end
        end
    elseif control == CONTROL_OPEN_INVENTORY then
        if self:IsControllerInventoryOpen() then
            self:CloseControllerInventory()
            return true
        end
        local inventory = self.owner.replica.inventory
        if inventory ~= nil and inventory:IsVisible() and inventory:GetNumSlots() > 0 then
            self:OpenControllerInventory()
            return true
        end
    elseif control >= CONTROL_INV_1 and control <= CONTROL_INV_10 then
-- ★ 物品栏热键用**区间比较**而不是查表：
--   1601 control >= CONTROL_INV_1 and control <= CONTROL_INV_10
--   1605 hot_key_num = control - CONTROL_INV_1 + 1
-- → 依赖 constants.lua 里这些常量**连续编号**。
--   若有人插入新常量到中间，全部热键会静默错位。
--   「枚举连续」是隐式契约，抄这段时要连注释一起抄。
-- ★★ 1607-1614 同一个键被复用为两种语义：
--   按住 CRAFTING_MODIFIER → 跳到合成菜单的第 n 个图钉
--   直接按 → 使用第 n 格物品
--   → 「修饰键切换语义」是提高信息密度的标准手法。
-- 1617-1629 是第二段热键（11-15 格），注释明说「没有合成图钉」。
--   → 说明 DST 的合成图钉上限是 10，与背包 15 格不一致，是硬编码约束。
        --inventory hotkeys
        local inventory = self.owner.replica.inventory
        if inventory ~= nil and inventory:IsVisible() then
			local hot_key_num = control - CONTROL_INV_1 + 1

			if TheInput:IsControlPressed(CONTROL_CRAFTING_MODIFIER) then
				self.controls.craftingmenu:SelectPin(hot_key_num)
			else
				local item = inventory:GetItemInSlot(hot_key_num)
				if item ~= nil then
					self.owner.replica.inventory:UseItemFromInvTile(item)
				end
			end
            return true
        end
    elseif control >= CONTROL_INV_11 and control <= CONTROL_INV_15 then
        -- Inventory hotkeys part two.
        local inventory = self.owner.replica.inventory
        if inventory ~= nil and inventory:IsVisible() then
			local hot_key_num = control - CONTROL_INV_11 + 11

            -- No crafting menu pins!
			local item = inventory:GetItemInSlot(hot_key_num)
            if item ~= nil then
                self.owner.replica.inventory:UseItemFromInvTile(item)
            end
            return true
        end
    end
end

function PlayerHud:OnRawKey(key, down)
-- OnRawKey 是**空实现**，只有注释。
-- 1637-1639 的注释极有价值：它列出了「要让玩家能改键，
--   就必须同步修改的全部文件清单」（strings / constants / playerhud /
--   optionsscreen / C++ 输入处理与定义头文件）。
-- ★★ 「加一个可重绑的键需要改哪几个文件」这种清单式注释，
--   是多人协作项目里最省沟通成本的文档形式。强烈建议模仿。
-- ⚠️ 1634 的基类调用保留着 —— 说明这是留给模组的钩子点
--   （注释明说「maybe a mod already hooked it」）。
    if PlayerHud._base.OnRawKey(self, key, down) then
        return true
    end
    -- NOTES(JBK): Add controls to the files below to allow players to edit bound keys do not use OnRawKey for forced binds unless in dev only.
    -- strings.lua, constants.lua, playerhud.lua, optionsscreen.lua, DontStarveInputHandler.h, DontStarveInputHandler.cpp, InputDefinitions.h
    -- I am leaving this function stub here for dev testing only and maybe a mod already hooked it.
end

local DROPS_ALPHA_INCREASE_RATE = 0.01
-- ══★【UpdateDrops：帧率无关性的反面教材（值得注意的设计取舍）】
-- 1642-1643 两个速率常量：上升 0.01/帧，下降 0.05/帧。
-- ⚠️⚠️ 这是**按帧**而非按时间递增的：
--   1655 self.drops_alpha = self.drops_alpha + DROPS_ALPHA_INCREASE_RATE
--   同样 100 次增加，在 30fps 下要 3.3 秒，在 144fps 下只要 0.7 秒。
-- → 【bug-patterns】帧率相关的 UI 动画：高帧率机器上淡入过快、
--   低帧率机器上淡出过慢。这是**真实存在**的缺陷形态。
--   正确写法应传 dt：`alpha = alpha + RATE * dt * 60`。
-- ★ 为什么作者这么写：DST 的 UI 动画大量用 AnimState/Tween（按时间），
--   这几处手写插值是少数例外。属于遗留代码。
-- ⚠️ 1646 与 1659 构成一个手写状态机，
--   1659 的 elseif 内又嵌了一个冗余的 `if self.drops_alpha > 0`（1660 行），
--   条件与外层 elseif 完全相同 —— 纯冗余，无害但迷惑。
-- → 自研 UI 的教训：**所有手写插值必须乘 dt**，
--   除非你明确接受「效果随帧率变化」。
local DROPS_ALPHA_DECREASE_RATE = 0.05
function PlayerHud:UpdateDrops(camera)

    if self.dropsplash  then
        if self.drops_alpha >= 1 then
            return
        end

        if self.drops_alpha <= 0 then
            self.drops_vig:Show()
            self.drops_alpha = DROPS_ALPHA_INCREASE_RATE
        elseif self.drops_alpha < 1 then
            self.drops_alpha = self.drops_alpha + DROPS_ALPHA_INCREASE_RATE
        end

        self.drops_vig.inst.AnimState:SetMultColour(1, 1, 1, self.drops_alpha)
    elseif self.drops_alpha > 0 then
        if self.drops_alpha > 0 then
            self.drops_alpha = self.drops_alpha - DROPS_ALPHA_DECREASE_RATE
            self.drops_vig.inst.AnimState:SetMultColour(1, 1, 1, self.drops_alpha)
        end

        if self.drops_alpha <= 0 then
            self.drops_alpha = 0
            self.drops_vig:Hide()
        end
    end
end

function PlayerHud:UpdateClouds(camera)
-- ══★【UpdateClouds：镜头距离驱动的全屏效果】
-- 1673 行注释自嘲「这是个奇怪的位置，但这个动画确实是 HUD 资源」。
-- 1675 把镜头距离归一化到 0..1（mindist..maxdist），
--   1676 读游戏模式可调的阈值 TUNING.HUD_CLOUD_CUTOFF。
-- ★ 1678-1687 是「**边沿触发 + 连续插值**」的标准结构：
--   状态位 self.clouds_on 只在**跨越阈值的那一刻**翻转（做昂贵操作：
--   Show/Hide、播风声、推混音档），
--   而颜色与音量每帧插值（做廉价操作）。
-- → ★★★★ 这是 UI 性能优化的第一法则：
--   **把「一次性昂贵操作」与「每帧廉价插值」分离，用状态位当闸**。
--   混音的 PushMix/PopMix 也在这里配对（1683/1693），
--   TheMixer 的档位是栈式的，所以成对调用是正确用法。
-- ⚠️ 1679 camera.should_push_down = true —— UI 反向写相机的字段。
--   UI 层能改相机行为，说明这个「云」实际参与了镜头表现，不只是装饰。
-- ⚠️ 1685 easing.outCubic(a, 0, .5, 1 - cutoff) 的结果 p 同时喂给：
--   云的颜色 alpha 与风声音量 → 两者严格同步，这是刻意的。
-- 1674 的 `if camera.distance and not camera.dollyzoom` 守卫：
--   洞穴（TheWorld:HasTag("cave")）里根本不会调本函数（见 player_common.lua:747），
--   而 dollyzoom（特殊镜头）时也不画云。
    --this is kind of a weird place to do all of this, but the anim *is* a hud asset...
    if camera.distance and not camera.dollyzoom then
        local dist_percent = (camera.distance - camera.mindist) / (camera.maxdist - camera.mindist)
        local cutoff = TUNING.HUD_CLOUD_CUTOFF
        if dist_percent > cutoff then
            if not self.clouds_on then
                camera.should_push_down = true
                self.clouds_on = true
                self.clouds:Show()
                TheFocalPoint.SoundEmitter:PlaySound("dontstarve/common/clouds", "windsound")
                TheMixer:PushMix("high")
            end
            local p = easing.outCubic(dist_percent - cutoff, 0, .5, 1 - cutoff)
            self.clouds:GetAnimState():SetMultColour(self.clouds.cloudcolour[1], self.clouds.cloudcolour[2], self.clouds.cloudcolour[3], p)
            TheFocalPoint.SoundEmitter:SetVolume("windsound", p)
        elseif self.clouds_on then
            camera.should_push_down = false
            self.clouds_on = false
            self.clouds:Hide()
            TheFocalPoint.SoundEmitter:KillSound("windsound")
            TheMixer:PopMix("high")
        end
    end
end

function PlayerHud:AddTargetIndicator(target, data)
-- 目标指示器：世界中被标记的实体上方显示的箭头/名字。
-- 挂 under_root（1703 行）→ 画在 HUD 之下但在地形之上。
-- ★ 1704 用 table.insert 存进数组，但 1707/1718 行用 pairs 遍历 ——
--   数组应该用 ipairs。不过这里无害：RemoveTargetIndicator 用
--   table.remove 删的是**同一个** table，索引仍然连续。
-- ⚠️ 但若外部直接改了 self.targetindicators（比如塞入 nil 制造稀疏），
--   pairs 仍能遍历而 ipairs 会中断。当前代码 1722 行有 `if v and` 的守卫，
--   说明作者确实预期过 nil 元素存在 → 与 pairs 的用法自洽。
    if not self.targetindicators then
        self.targetindicators = {}
    end

    local ti = self.under_root:AddChild(TargetIndicator(self.owner, target, data))
    table.insert(self.targetindicators, ti)
end

function PlayerHud:HasTargetIndicator(target)
-- HasTargetIndicator 与 RemoveTargetIndicator 都先判 `if not self.targetindicators then return end`。
-- ★ 这是本文件里少见的**早返回保护**：1699 行是惰性创建（首次 Add 才建表），
--   而这里是防御性读取。两种风格并存。
-- ⚠️ 1708/1719 的 `return` 无值 → 返回 nil 而非 false。
--   Lua 里 nil 与 false 在条件判断中等价，但 `== false` 的比较会失败。
--   1707 的调用方（1715 等）都用条件判断，安全。
    if not self.targetindicators then return end

    for i,v in pairs(self.targetindicators) do
        if v and v:GetTarget() == target then
            return true
        end
    end
    return false
end

function PlayerHud:RemoveTargetIndicator(target)
    if not self.targetindicators then return end

    local index = nil
    for i,v in pairs(self.targetindicators) do
        if v and v:GetTarget() == target then
            index = i
            break
        end
    end
    if index then
        local ti = table.remove(self.targetindicators, index)
        if ti then ti:Kill() end
    end
end

function PlayerHud:ShowPopupNumber(val, size, pos, height, colour, burst)
-- ══★【一次性特效的「建了就扔」范式】
-- 1734-1736 ShowPopupNumber：直接 AddChild，不保存句柄。
--   PopupNumber 自己负责动画播完后 Kill 自己。
-- → ★★★ 与 ShowRingMeter（1738）的「缓存复用」形成对照：
--   飘字每次形态不同（数值/颜色/大小都变）→ 建了就扔；
--   环 meter 形态固定 → 建一次反复 SetWorldPosition + StartTimer。
--   「选建了就扔还是缓存复用」的判据是：**每次的数据是否不同**。
--   → 自研 UI 池化（object pooling）的判断依据就是这个。
-- ⚠️ 代价：建了就扔意味着每帧可能有几十次 AddChild/Kill，
--   Widget:Kill 会 KillAllChildren + Remove 实体，是重量级操作。
--   DST 靠「飘字频率不高」容忍了它。做自研游戏应上对象池。
    self.popupstats_root:AddChild(PopupNumber(self.owner, val, size, pos, height, colour, burst))
end

function PlayerHud:ShowRingMeter(pos, duration, starttime)
-- 1739-1741 惰性创建 + 缓存；1746 的 HideRingMeter 在 1753 把句柄置 nil，
-- 下一帧又会新建。
-- ⚠️ 这意味着 ringmeter 的「淡出动画」期间（1749/1751 传了 duration），
--   self.ringmeter 已经被置 nil。若此时再次 ShowRingMeter，
--   会**同时存在两个 RingMeter**（旧的还在淡出，新的开始计时）。
--   视觉上会重叠。属于疑似缺陷（是否有调用方这么用需另行确认）。
--   正确写法是淡出完成后再置 nil，或淡出期间复用同一实例。
    if self.ringmeter == nil then
        self.ringmeter = self.popupstats_root:AddChild(RingMeter(self.owner))
    end
    self.ringmeter:SetWorldPosition(pos)
    self.ringmeter:StartTimer(duration, starttime)
end

function PlayerHud:HideRingMeter(success, duration)
-- success 决定 FlashOut（成功金光）还是 FadeOut（普通淡出）——
-- 同一次挖掘/成功的两种反馈。
-- 「把结果语义传进动画选择」是 UI 反馈设计的基本功：
-- 同一个动作，成功与失败必须视觉可区分。
    if self.ringmeter ~= nil then
        if success then
            self.ringmeter:FlashOut(duration)
        else
            self.ringmeter:FadeOut(duration)
        end
        self.ringmeter = nil
    end
end

function PlayerHud:SetServerPaused(paused)
-- SetServerPaused 双向：paused 且用户没开「隐藏暂停遮罩」才显示。
-- ★ 1763 行无论显示与否都更新 self.serverpaused ——
--   这个**状态**与**视觉表现**必须分开：
--   1422 行的「解除服务器暂停」按键处理读的是 self.serverpaused，
--   与玩家是否想看遮罩无关。
-- → 「状态」与「该状态的视觉呈现」分离，UI 代码里反复出现这个原则。
    if paused and not Profile:GetHidePauseUnderlay() then
        self.serverpause_underlay:Show()
    else
        self.serverpause_underlay:Hide()
    end
	self.serverpaused = paused
end

function PlayerHud:OffsetServerPausedWidget(serverpausewidget)
    if self.eventannouncer then
        serverpausewidget:SetOffset(self.eventannouncer:GetPosition():Get())
    end
end

-- Wx
function PlayerHud:IsUpgradeModuleWidgetInputFocus()
	return self.upgrademodulewidget ~= nil and self.upgrademodulewidget:HasInputFocus()
end

function PlayerHud:ShowUpgradeModuleWidget()
-- ══★【UpgradeModulesDisplay_Inspecting：HUD 内的「子界面」】
-- 注意 1780 行：它**不是** Screen，而是 AddChild 到 controls.right_root。
-- → ★★★ 这是屏幕栈之外的第三种界面形态：**嵌入式面板**。
--   权衡：
--     走 Screen 栈 → 有独立焦点/输入/暂停语义，但会遮住 HUD
--     嵌入 HUD   → 与 HUD 共存，但焦点与输入要自己协调
--   升级模块检查器选后者，于是必须**手动**参与输入独占：
--   1773 的 IsUpgradeModuleWidgetInputFeedback 就是为此存在，
--   并被 1093 行纳入 HasInputFocus 的 or 链。
-- → ★★★★ 移植要点：只要你的界面不是全屏 Screen，
--     就**必须**自己在总闸函数里登记，否则玩家能点穿到世界。
-- 1778 先 Close 再建 —— 与 506 行同款「先关后开」防重入。
-- 1781-1787 成对：显示模块时藏 secondary_status 的属主显示，
--   关闭时再 Show 回来。嵌入式面板的典型代价：
--   「借用了别人的地盘就必须记得还回去」，且这个约定只存在于两行代码里。
    self:CloseUpgradeModuleWidget()
	self.upgrademodulewidget = UpgradeModulesDisplay_Inspecting(self.owner, self.controls)
    self.controls.right_root:AddChild(self.upgrademodulewidget)
    self.controls.secondary_status:HideModuleOwnerDisplay()
    return self.upgrademodulewidget
end

function PlayerHud:CloseUpgradeModuleWidget()
    if self.upgrademodulewidget then
        self.controls.secondary_status:ShowModuleOwnerDisplay()
        self.upgrademodulewidget:Close()
        self.upgrademodulewidget = nil
    end
end

function PlayerHud:TryStopInspectingModules(nomoduleremover)
-- ══★【TryStopInspectingModules：三态返回 —— 本文件最精巧的接口】
-- 返回值有三种含义：
--   true  = 确实关掉了升级模块面板（调用方应消费这个键）
--   false = 有面板，但正在用「模块拆除器」（不能关）
--   nil   = 本来就没有面板（调用方应把键透传给玩法）
-- → ★★★★ 「nil / false / true 三态」是 Lua 里表达「没做事」与
--   「做事了但结果不同」的标准手法：
--     return      → 什么都没做，键归玩法
--     return false→ 做了决策但不动作，键归玩法
--     return true → 动作了，键归 UI
--   调用方 1483/1548 都写成 `if self:TryStopInspectingModules() then`，
--   nil 与 false 均为假 → 都正确地穿透。
--   → 自研 UI 若用 bool 返回，会丢失「主动放弃 vs 无事发生」的区分，
--     进而在某些边界上重复执行动作。
-- ⚠️ 1795 的 nomoduleremover 参数是**反向否决开关**：
--   「不要用拆除器去强行关掉它」。调用方 1548 传的是 nil（允许关），
--   而其他调用方（1242/1363）也都不传 → 该参数实际上从未被传 true。
--   grep 本文件无第三处调用点 → 疑似死参数（可能供模组使用）。
    if self.upgrademodulewidget ~= nil then
        if nomoduleremover and self.upgrademodulewidget.is_using_module_remover then
            return false
        end

        self:CloseUpgradeModuleWidget()
        if self.owner.StopInspectingModules then
			self.owner:StopInspectingModules()
		end
        return true
    end
end

--V2C: for clients, this is the best way to poll for drone in client stategraph
-- 1807 行的注释再次示范了「写清为什么」的价值：
-- 客户端没有服务端的状态机，只能靠轮询 UI 对象来获取同类信息。
-- → ★★★ 副本机制的根本限制：**客户端可以读状态但不能算状态**。
--   所有「客户端需要知道 X 的变化」的需求，都得设计成一个可轮询的 UI 对象。
--   自研联机游戏若要做客户端预测或本地 AI，必须先想清楚这件事。
function PlayerHud:GetCurrentDrone()
	return self.dronezapover:GetDrone()
end

return PlayerHud