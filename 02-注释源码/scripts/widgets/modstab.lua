--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：widgets/modstab.lua
-- 模块：界面 / 模组列表标签页（servercreationscreen 的一个页签）
-- 职责：列出所有已安装模组（分客户端/服务端两栏），支持勾选启用、
--       配置、更新（创意工坊）、批量清理、批量更新；右侧详情面板
--       展示名称/作者/描述/兼容性/状态。
--       本控件是 **Widget 而非 Screen**，没有屏幕栈参与，
--       而通过 self.servercreationscreen 反向通知宿主界面刷新。
-- 关键符号：UpdateForWorkshop（数据→UI 的唯一刷新入口，375 行）,
--           StartWorkshopUpdate（周期轮询）, ShowModDetails（详情填充）,
--           EnableCurrent / OnConfirmEnable（模组启停，含可撤销快照）, 
--           LoadModInfoPrefabs / UnloadModInfoPrefabs / ReloadModInfoPrefabs
--           （运行时为模组图标临时注册预制体，含引用计数顺序陷阱）, 
--           DoFocusHookups（23 行焦点导航图，含动态目标函数）,
--           SetModsList（页签切换）, CreateDetailPanel, GetBestModStatus,
--           SetSaveSlot（切换存档槽 = 换整套模组配置）, CleanAllButton
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：widgets/scrollablelist.lua（列表容器，本文件用其模式 A）, 
--           widgets/templates.lua（ModListItem / ModDLListItem 行模板）、
--           widgets/widget.lua（SetFocusChangeDir 支持 FunctionOrValue,
--           这是 tomiddlecol 动态焦点目标的基础）、
--           widgets/imagebutton.lua（SetTextures 多态贴图切换）、
--           screens/servercreationscreen.lua（宿主界面，接收反向通知）、
--           screens/modconfigurationscreen.lua（PushScreen 打开的子屏）、
--           knownmodindex.lua（模组元数据与启用状态）、
--           modmanager.lua（模组加载/卸载）、
--           schaduler / staticScheduler（周期轮询，不随暂停冻结）
--============================================================
local Widget = require "widgets/widget"
local Text = require "widgets/text"
local Image = require "widgets/image"
local Menu = require "widgets/menu"
local ScrollableList = require "widgets/scrollablelist"

local TEMPLATES = require "widgets/templates"
local PopupDialogScreen = require "screens/popupdialog"

local ModConfigurationScreen = require "screens/modconfigurationscreen"
-- ══════════════════════════════════════════════════════════════
-- ModsTab —— 模组列表标签页（1171 行）
--
-- 【定位：它是 servercreationscreen（创建世界界面）的一个「页签」Widget，
--   不是 Screen】所以没有 PushScreen/PopScreen 参与，
--   而是通过 self.servercreationscreen 反向通知宿主界面刷新。
--   → 这是「嵌入式面板」形态（与 playerhud 的 upgrademodulewidget 同类）。
--
-- 【★★ 最重要的三件事】
-- 1) **一个数据源刷两个列表**（384-638 行，client/server 两段几乎逐字重复）：
--    KnownModIndex → modnames_client/server → 为每个模组建 ModListItem 控件
--    → optionwidgets_client / optionwidgets_server → 交给 ScrollableList。
--    ★ 注意它用的是 ScrollableList 的**模式 A**（自带子控件），
--      不是虚拟化模式 —— 见 645 行的构造参数分析。
-- 2) **UpdateForWorkshop 是唯一的刷新入口**（308 行，375 行代码）：
--    周期性跑（TUNING.MODS_QUERY_TIME），比对数据 → 无变化就早退，
--    有变化才重建全部控件。数据 → UI 的完整链路都在这里。
-- 3) **DoFocusHookups（1127 行）建立整个页签的焦点图**：
--    23 行焦点连线，把导航栏/列表/右侧按钮连成一张可手柄操作的图。
--
-- 【⚠️ 容易踩的坑】
-- · 12-13 行的 DISABLE / ENABLE 是死常量（已 grep 核实从未被读）。
-- · 384-504 与 513-632 两段是**整段复制粘贴**（约 120 行 × 2）。
-- · CreateDetailPanel 在「无模组」分支不建 detailimage/detailwarning 等字段，
--   而 ShowModDetails 会无条件访问它们 —— 见该处分析。
-- ══════════════════════════════════════════════════════════════

local DISABLE = 0
-- ⚠️【死常量，已 grep 全文件核实】DISABLE = 0 与 ENABLE = 1 从未被读取。
--   grep 显示 DISABLE 的 9 次命中里，8 次是字符串 "DISABLED_ERROR"/
--   "DISABLED_MANUAL" 的一部分，ENABLE 只命中定义行本身。
--   → 推测是早期设计里「模组开关状态用数字表示」的遗留，
--     后来改用 KnownModIndex:IsModEnabled() 布尔查询，枚举就废了。
--   保留无害（Lua 的 local 不占运行时开销），但会让读者以为存在状态机。
local ENABLE = 1

local mid_col = RESOLUTION_X*.07
-- ★★★ 布局常量：全部用 RESOLUTION_X/Y 按**比例**算，而非绝对像素。
-- 15-17 行的三个列位置（中间列 / 左列 / 右列）。
-- → ★★ 这是 DST UI 的核心布局约定：**用分辨率比例而非固定像素**。
--   好处：同一份 UI 代码在 720p / 1080p / 4K 上都能正确布局。
--   代价：一旦某处用了绝对像素（如下面 198 行的 SetPosition(115,0,0)），
--     在不同分辨率下就会错位。**同一个文件里两种写法混用**，
--     这是 DST UI 最大的可移植性问题。
-- ⚠️ 已核实：15-17 行的 mid_col 在 58 行被使用，
--   但 left_col 与 right_col **各自只出现 1 次（即定义行）** → 也是死变量。
-- → 移植时这些常量应当抽进一个「响应式布局」工具层，
--   由引擎的锚点系统接管，而不是每个文件各算一遍。
local left_col = -RESOLUTION_X*.3
local right_col = RESOLUTION_X*.37

local ModsTab = Class(Widget, function(self, servercreationscreen)
-- ★★ ModsTab 是 Widget 而非 Screen，因此没有 OnBecomeActive 的自动调用；
--   1013 行自己实现了同名函数。
--   但**谁来调它**？宿主 servercreationscreen 需要显式转发。
--   → ⚠️ 这是「非 Screen 控件」的固有责任：
--     Screen 的生命周期由 FrontEnd 统一驱动，
--     Widget 则完全靠调用方。移植时要明确谁来触发这些钩子。
-- 26 行存下宿主引用：整个文件靠它反向通知（731-734 行）。
--   → 「子面板持有父界面引用」是双向通信的简化做法，
--     代价是形成环状引用（本文件与 servercreationscreen 互相持有），
--     销毁顺序需要小心。
    Widget._ctor(self, "ModsTab")

    self.mods_page = self:AddChild(Widget("mods_page"))

    self.slotnum = -1

    self.servercreationscreen = servercreationscreen

	self.currentmodtype = ""

    -- save current mod index before user configuration
-- ★★★【数据 → UI 刷新链路的第一步：状态快照】
-- CacheSaveData：把当前启用状态存一份快照。
--   → 用途见 989 行 Cancel() 的 RestoreCachedSaveData：
--     玩家在这个界面里试开关模组，点「取消」要恢复原状。
--   → ★★★ 「可撤销的修改」的标准实现：
--     进入编辑态时快照，提交时保存，取消时回滚。
--     自研 UI 只要涉及「改了但可能不保存」的设置，就该这么做。
-- ⚠️ 注意这个快照是**全局的**（存在 KnownModIndex 上，不带实例标识），
--   所以两个同时打开的 ModsTab 会互相覆盖快照。
--   实践中同时只有一个（servercreationscreen 是模态），故不显错。
-- 33 行 UpdateModInfo：拉取模组元数据（描述/图标/版本/兼容性）。
--   → 这是**异步**的（要读磁盘与 Workshop），所以界面先建、数据后到。
    KnownModIndex:CacheSaveData()
    -- get the latest mod info
    KnownModIndex:UpdateModInfo()

    self.infoprefabs = {}

    self.nav_bar = self.mods_page:AddChild(TEMPLATES.NavBarWithScreenTitle(nil, "short"))
-- 导航栏两个按钮：服务端模组 / 客户端模组。
-- ★ 38-39 行的回调只调 SetModsList，不做数据刷新 ——
--   数据刷新由 1014 行的 OnBecomeActive → StartWorkshopUpdate 负责。
--   → 「切换视图」与「刷新数据」是两件事，职责分离。
-- 46 行 SetPosition 用 RESOLUTION_X*.364 —— 又是比例定位（见 15 行分析）。
-- ⚠️ 但 50/55 行的 left_line / middle_line 用的是绝对值 -380 / -83。
--   → 同一文件里两种布局风格混用，分隔线的位置在不同分辨率下会错。
    self.servermodsbutton = self.nav_bar:AddChild(TEMPLATES.NavBarButton(25, STRINGS.UI.MODSSCREEN.SERVERMODS, function() self:SetModsList("server") end))
    self.clientmodsbutton = self.nav_bar:AddChild(TEMPLATES.NavBarButton(-25, STRINGS.UI.MODSSCREEN.CLIENTMODS, function() self:SetModsList("client") end))

    self.servermodsbutton.active_page_image:SetScale(.55,.65)
    self.clientmodsbutton.active_page_image:SetScale(.55,.65)

    self.nav_bar.bg:SetPosition(-5, 0)
    self.nav_bar:SetScale(.85, .8)
    self.nav_bar:SetPosition(-RESOLUTION_X*.364, RESOLUTION_Y*.192)

    self.left_line = self.mods_page:AddChild(Image("images/ui.xml", "line_vertical_5.tex"))
    self.left_line:SetScale(1, .59)
    self.left_line:SetPosition(-380, 5, 0)
    self.left_line:MoveToBack()

    self.middle_line = self.mods_page:AddChild(Image("images/ui.xml", "line_vertical_5.tex"))
    self.middle_line:SetScale(1, .59)
    self.middle_line:SetPosition(-83, 5, 0)

    self.mainmenu = self.mods_page:AddChild(Menu(nil, 0, true))
-- mainmenu 是「右侧操作按钮区」，Menu(nil, 0, true) 的三个参数：
--   nil = 无背景图，0 = 初始选中索引，true = 竖排/紧凑布局（推断）。
-- ★ 60-72 行连续 AddCustomItem，每个都是 TEMPLATES.IconButton + 位置。
--   这是「低价值布局样板」，不做逐行注释。
-- ★★ 但 60-72 行的位置参数暴露了一个信息：
--   configure(40) / update(110) / link(180) 在**正方向**，
--   cleanall(-587) / updateall(-517) 在**负方向**。
--   → 布局意图：右半屏是「当前模组的操作」，左半屏是「全局批量操作」。
-- 68 行 mainmenu:MoveToFront() 在 70-72 行**之前**调用：
--   ⚠️ 顺序可疑。MoveToFront 把 menu 提到最前，
--   但随后 AddCustomItem 还会加子控件 ——
--   加进来的子控件是否还在 menu 的最前？
--   实际 Menu:AddCustomItem 自己会 MoveToFront 新项，
--   所以 68 行实际上是多余的（或为 60-66 行那批兜底）。
--   标注为「疑似冗余」。
    self.mainmenu:SetPosition(mid_col, -155, 0)

    self.modconfigbutton = self.mainmenu:AddCustomItem(TEMPLATES.IconButton("images/button_icons.xml", "configure_mod.tex", STRINGS.UI.MODSSCREEN.CONFIGUREMOD, false, false, function() self:ConfigureSelectedMod() end), Vector3(40, 0, 0))
    self.modconfigable = false

    self.modupdatebutton = self.mainmenu:AddCustomItem(TEMPLATES.IconButton("images/button_icons.xml", "update.tex", STRINGS.UI.MODSSCREEN.UPDATEMOD, false, false, function() self:UpdateSelectedMod() end), Vector3(110, -0, 0))
    self.modupdateable = false

    self.modlinkbutton = self.mainmenu:AddCustomItem(TEMPLATES.IconButton("images/button_icons.xml", "more_info.tex", STRINGS.UI.MODSSCREEN.MODLINK_MOREINFO, false, false, function() self:ModLinkCurrent() end), Vector3(180, 0, 0))

    self.mainmenu:MoveToFront()

    self.cleanallbutton = self.mainmenu:AddCustomItem(TEMPLATES.IconButton("images/button_icons.xml", "clean_all.tex", STRINGS.UI.MODSSCREEN.CLEANALL, false, false, function() self:CleanAllButton() end), Vector3(-587, 0, 0))

    self.updateallbutton = self.mainmenu:AddCustomItem(TEMPLATES.IconButton("images/button_icons.xml", "updateall.tex", STRINGS.UI.MODSSCREEN.UPDATEALL, false, false, function() self:UpdateAllButton() end), Vector3(-517, 0, 0))
    self.updateallbutton.out_of_date_image = self.updateallbutton:AddChild(Image("images/frontend.xml", "circle_red.tex"))
-- ★ 徽章（红点 + 数字）嵌在按钮内部：updateallbutton.out_of_date_image。
-- 76 行 SetClickable(false)：★ 红点不能吃掉点击。
--   → ★★★ 「装饰性覆盖物必须 SetClickable(false)」是 UI 的硬规则。
--     否则点红点的位置就点不到按钮了。
--     这条规则在本项目里反复出现（playerhud 的 vig 也这么做）。
-- 77-79 行在红点里再嵌一个 Text 显示数量。
-- 80 行初始 Hide：有红点的控件必须默认隐藏，
--   否则会闪现一个空红点（与 playerhud:139 的 drops_vig 同一教训）。
    self.updateallbutton.out_of_date_image:SetScale(.6)
    self.updateallbutton.out_of_date_image:SetPosition(-28,-20)
    self.updateallbutton.out_of_date_image:SetClickable(false)
    self.updateallbutton.out_of_date_image.count = self.updateallbutton.out_of_date_image:AddChild(Text(BUTTONFONT, 30, ""))
    self.updateallbutton.out_of_date_image.count:SetColour(0,0,0,1)
    self.updateallbutton.out_of_date_image.count:SetPosition(2,0)
    self.updateallbutton.out_of_date_image:Hide()

	self.currentmodtype = "server"
-- ⚠️ 28 行已把 currentmodtype 设为 ""，82 行又设为 "server"，
--   84 行 SetModsList("server") 里再设一次。
--   → 三次赋值同一语义字段，其中 28 行那次立即被覆盖。
--   属「初始化字段时的重复」，无害但暗示构造顺序被多次改动过。
-- ★ 84 行 SetModsList 在 options_scroll_list_client 还不存在时
--   会被 151-153 行提前 return —— 见该处分析。

    self:SetModsList("server")

    self:DoFocusHookups()

    self.default_focus = self.servermodsbutton
-- ★★ default_focus 与 focus_forward 都指向同一个按钮。
-- 两者区别（widget.lua:659-662）：
--   default_focus : PushScreen 时若焦点为空则聚焦它
--   focus_forward : SetFocus 时**转发**给目标（本控件自己不接收焦点）
-- → ★ 本文件是 Widget 而非 Screen，default_focus 由宿主读取；
--   focus_forward 让「聚焦 ModsTab」等价于「聚焦第一个按钮」，
--   宿主只需调一次 SetFocus 就能落进正确的位置。
--   这是「容器把焦点转发给默认子项」的标准技巧。
    self.focus_forward = self.servermodsbutton
end)

function ModsTab:DisableConfigButton(modWidget)
-- ══★【Enable/Disable 成对函数 = 「按钮可用性」的双写模式】
-- 四个函数：DisableConfigButton / EnableConfigButton /
--           DisableUpdateButton / EnableUpdateButton。
-- ★★ 每个都做**四件事**，缺一不可：
--   1) 改状态字段（self.modconfigable / self.modupdateable）
--   2) 改按钮外观（Select / Unselect）
--   3) 改提示文字（SetHoverText）
--   4) 改列表行上的对应图标（modWidget.configurable_image）
--   5) 重建焦点链（DoFocusHookups）
-- → ★★★ 第 5 步是本文件最重要的细节：**按钮不可用时焦点链也要变**。
--   若不重建，手柄导航会跳到一个点不动的按钮上，
--   玩家会觉得「手柄失灵」。
--   → 移植到自研 UI 时，「控件可用性变化」必须触发「导航图重建」。
-- ⚠️ 但 122 行的 DisableUpdateButton 直接调 self.modupdatebutton:Select()
--   **没有** if 判断，而 92/107 行的配置按钮版本都有 `if self.modconfigbutton then`。
--   构造期 63 行已创建该按钮，所以实际不会 nil。
--   三个函数里只有一个没写守卫，属不一致。
    self.modconfigable = false

    if self.modconfigbutton then
        self.modconfigbutton:Select()
        self.modconfigbutton:SetHoverText(STRINGS.UI.MODSSCREEN.NOCONFIG)
    end

    if modWidget then
        modWidget.configurable_image:Hide()
    end

    self:DoFocusHookups()
end

function ModsTab:EnableConfigButton(modWidget)
    self.modconfigable = true

    if self.modconfigbutton then
        self.modconfigbutton:Unselect()
        self.modconfigbutton:SetHoverText(STRINGS.UI.MODSSCREEN.CONFIGUREMOD)
    end

    if modWidget then
        modWidget.configurable_image:Show()
    end

    self:DoFocusHookups()
end

function ModsTab:DisableUpdateButton(mode)
    self.modupdateable = false

    self.modupdatebutton:Select()

	if mode == "uptodate" then
		self.modupdatebutton:SetHoverText(STRINGS.UI.MODSSCREEN.UPTODATE)
	else
		self.modupdatebutton:SetHoverText(STRINGS.UI.MODSSCREEN.UPDATINGMOD)
	end

    self:DoFocusHookups()
end

function ModsTab:EnableUpdateButton()
-- ★ 139-141 行：只有**鼠标**模式才 Unselect。
--   手柄下保持 Select 状态（表示「这个按钮被手柄关注着」）。
-- → ★★★ 「同一个 Select/Unselect 状态在不同输入设备下含义不同」：
--     鼠标下 Select = 灰掉不可用；
--     手柄下 Select = 焦点候选的视觉标记。
--   这解释了为什么 107/122 行的无条件 Select 在手柄下也合理。
--   → 移植时若手柄与鼠标并存，可用性视觉必须分设备处理。
    self.modupdateable = true

    if not TheInput:ControllerAttached() then
        if self.modupdatebutton then self.modupdatebutton:Unselect() end
    end

	self.modupdatebutton:SetHoverText(STRINGS.UI.MODSSCREEN.UPDATEMOD)

    self:DoFocusHookups()
end

function ModsTab:SetModsList(listtype)
-- ★★ SetModsList 是「页签切换」的唯一入口，六件事按序做：
-- 149 记录当前页签类型
-- 151-153 数据未就绪则提前返回
-- 155 重建右侧详情面板
-- 157-158 切换两个列表的显隐
-- 159 重建焦点链
-- 161-162 切换导航按钮的选中态
-- 164-171 找回上次选中的模组并显示其详情
-- → ★★★ 「页签切换」的正确要素：视图 + 焦点 + 选中状态，三者都要更新。
--   最容易漏的是「选中状态」——切回来时若不恢复，
--   玩家会丢失上下文。
-- ⚠️ 151 行的守卫依赖 options_scroll_list_client 存在，
--   而它只在 645 行（UpdateForWorkshop 内）才被创建。
--   → 构造期 84 行调用本函数必然提前返回（见该处分析）。
--   这实际上是**有意的**：构造时还没有数据，先建骨架，等数据到了再填。
-- ★ 156/172 行的 if/elseif 覆盖了全部两种情况，
--   没有 else 分支 → 若传入其他 listtype，状态会停在「已记录但没执行」。
	self.currentmodtype = listtype

	if self.options_scroll_list_client == nil then
		return
	end

	self:CreateDetailPanel()
    if listtype == "client" then
        if self.options_scroll_list_client then self.options_scroll_list_client:Show() end
        if self.options_scroll_list_server then self.options_scroll_list_server:Hide() end
        self:DoFocusHookups()

        if self.clientmodsbutton.shown then self.clientmodsbutton:Select() end
        if self.servermodsbutton.shown then self.servermodsbutton:Unselect() end

        local idx = 1
-- ★★★【选中态保持：与 mapscreen 的 AutoAimToStaticDecorations 同类问题】
-- 遍历 modnames 找出 last_client_modname 的下标，找到就 break。
--   找不到则 idx 保持 1（默认第一项）。
-- → ★ 「按名字而不是按索引恢复选中」是正确做法：
--   索引会随模组启停而变化，名字稳定。
--   （与 scrollablelist 的 SetList 的 keeprelativefocusindex 不同 ——
--     那里只能记相对位置，因为数据项没有稳定标识。）
-- ★ 803-806 行（ShowModDetails 内）负责写 last_client/server_modname，
--   所以「记住」与「恢复」分在两个函数里。
-- ⚠️ 但如果模组被卸载了（名字消失），就回落到第一项 —— 合理降级。
		for i,v in ipairs(self.modnames_client) do
			if self.last_client_modname == v.modname then
				idx = i
				break
			end
		end
		self:ShowModDetails(idx, true)
    elseif listtype == "server" then
        if self.options_scroll_list_client then self.options_scroll_list_client:Hide() end
        if self.options_scroll_list_server then self.options_scroll_list_server:Show() end
        self:DoFocusHookups()

        if self.clientmodsbutton.shown then self.clientmodsbutton:Unselect() end
        if self.servermodsbutton.shown then self.servermodsbutton:Select() end

        local idx = 1
		for i,v in ipairs(self.modnames_server) do
			if self.last_server_modname == v.modname then
				idx = i
				break
			end
		end
		self:ShowModDetails(idx, false)
    end
end

function ModsTab:CreateDetailPanel()
-- ══⚠️★★【CreateDetailPanel：全量重建详情面板 + 严重的字段缺失】
-- 192-195 行：KillAllChildren 后又 Kill，然后重新 AddChild。
--   → 「KillAllChildren + Kill」是彻底销毁，比只 KillAllChildren 更干净。
--     作者选择全量重建而非复用，理由大概是详情面板结构固定、
--     重建成本低。
-- ⚠️⚠️【真实缺陷，已逐行核实】else 分支（243-256，空模组时）
--   **不创建** detailimage / detailtitle / detailtitle2 / detailauthor /
--   detailcompatibility / detailwarning，只创建了 detaildesc（244 行）。
-- 而 ShowModDetails（780 行）从 814 行起无条件访问：
--   814 self.detailimage:SetTexture(...)
--   821 self.detailtitle:SetMultilineTruncatedString(...)
--   892 self.detailwarning:SetString(...)
-- → 这些字段在「该页签没有任何模组」时是**上一轮 detailpanel 的旧引用**
--   （已被 Kill）或 nil（若从未建过）。
--   对已 Kill 的控件调 SetTexture 会操作失效实体。
-- ★ 为什么实践中不崩：
--   ① 若玩家有模组，num_mods > 0，走 if 分支，字段齐全；
--   ② 若一个模组都没有，ShowModDetails 会在 784 行因
--      `#widgetTable > 0` 不成立而**提前 return（794 行）**，
--      走不到 814 行。
--   → 即「靠上游的守卫兜住了下游的空字段」，属「隐式契约」。
--   正确做法：else 分支也建这些字段（内容留空），
--   或 ShowModDetails 开头就判 self.detailimage ~= nil。
-- ⚠️ 我未能确认「切到空列表页签」的完整路径是否 100% 被 784 行挡住，
--   故标注为「真实缺陷但当前被上游守卫掩盖」。
    if self.detailpanel then
		self.detailpanel:KillAllChildren()
		self.detailpanel:Kill()
	end

    self.detailpanel = self.mods_page:AddChild(Widget("detailpanel"))
    self.detailpanel:SetPosition(115,0,0)

	local num_mods = 0
-- ★ 201 行用 if/else 表达式取数量，是本文件少见的紧凑写法。
--   但两个分支都判 `self.currentmodtype == "client"`，
--   若 currentmodtype 是 ""（28 行的初值），会走 else 取 server 列表。
--   → 初值为空串时的隐式默认是「server」，与 82 行的显式设置重复。
	if self.currentmodtype == "client" then num_mods = #self.modnames_client else num_mods = #self.modnames_server end

    if num_mods > 0 then
        self.detailimage = self.detailpanel:AddChild(Image("images/ui.xml", "portrait_bg.tex"))
        self.detailimage:SetSize(102, 102)
        self.detailimage:SetScale(0.8,0.8,0.8)
        self.detailimage:SetPosition(-148, 145, 0)

        self.detailtitle = self.detailpanel:AddChild(Text(NEWFONT, 30, ""))
        self.detailtitle:SetPosition(-100, 176)
        self.detailtitle:SetColour(0,0,0,1)

        self.detailtitle2 = self.detailpanel:AddChild(Text(NEWFONT, 30, ""))
        self.detailtitle2:SetHAlign(ANCHOR_LEFT)
        self.detailtitle2:SetPosition(35, 151)
        self.detailtitle2:SetRegionSize(270, 45)
        self.detailtitle2:SetColour(0,0,0,1)

        self.detailauthor = self.detailpanel:AddChild(Text(NEWFONT, 20, ""))
        self.detailauthor:SetColour(0,0,0,1)
        --self.detailauthor:SetColour(0.9,0.8,0.6,1) -- link colour
        self.detailauthor:SetPosition(-100, 128, 0)

        self.detailcompatibility = self.detailpanel:AddChild(Text(NEWFONT, 18, ""))
        self.detailcompatibility:SetColour(0,0,0,1)
        self.detailcompatibility:SetPosition(35, 111, 0)
        self.detailcompatibility:SetRegionSize(270, 30)
        self.detailcompatibility:SetHAlign(ANCHOR_LEFT)

        self.detaildesc = self.detailpanel:AddChild(Text(NEWFONT, 20, ""))
        self.detaildesc:SetColour(0,0,0,1)
        self.detaildesc:SetPosition(-187, 97, 0)
        self.detaildesc:SetHAlign(ANCHOR_LEFT)

        self.detailwarning = self.detailpanel:AddChild(Text(BODYTEXTFONT, 25, ""))
        self.detailwarning:SetColour(0.8,0.6,0.5, 1)
        self.detailwarning:SetPosition(-107, -153, 0)
        self.detailwarning:SetRegionSize( 360, 107 )
        self.detailwarning:EnableWordWrap(true)

        self.modlinkbutton:SetHoverText(STRINGS.UI.MODSSCREEN.MODLINK_MOREINFO)
-- ★ 空模组分支（243-256）里连按钮状态都一并禁用。
-- 252/253 调 Disable 系列 → 它们内部会调 DoFocusHookups。
--   而 155 行（SetModsList）已经调过一次 DoFocusHookups，
--   258 行之后 mainmenu:MoveToFront。
--   → 同一次页签切换中 DoFocusHookups 被调用 2-3 次（159 行 + 92/122 行内部）。
--     幂等（它只是重设焦点连线），所以无副作用，但有冗余开销。
-- ★★★ 这正是本文件要求 DoFocusHookups 幂等的原因 ——
--   它被当作「状态变更后统一重算」的事件来用，而非「初始化时算一次」。
		self.modlinkbutton:Unselect()
    else
        self.detaildesc = self.detailpanel:AddChild(Text(NEWFONT, 25))
        local no_mods = string.format(STRINGS.UI.MODSSCREEN.NO_MODS_TYPE, self.currentmodtype )
        self.detaildesc:SetString(no_mods)
        self.detaildesc:SetColour(0,0,0,1)
        self.detaildesc:SetPosition(-7, 55, 0)
        self.detaildesc:SetRegionSize( 360, 225 )
        self.detaildesc:EnableWordWrap(true)

		self:DisableConfigButton()
		self:DisableUpdateButton("uptodate")
        self.modlinkbutton:ClearHoverText()
		self.modlinkbutton:Unselect()
    end

    self.mainmenu:MoveToFront()
end

function ModsTab:StartWorkshopUpdate()
-- ★★ StartWorkshopUpdate：周期刷新循环的启动。
-- 262-265 先取消旧任务 → 保证幂等（重复调用不会有两个循环）。
-- 267 先同步跑一次 → 让界面立刻有数据，不用等第一个周期。
-- 268 staticScheduler:ExecutePeriodic：
--   ★ 用 staticScheduler 而非 DoPeriodicTask ——
--     前者是**墙钟时间**驱动（暂停也走），后者跟随模拟。
--     模组界面不需要暂停语义，且暂停时仍该检查更新。
--   后三个参数 nil, 0, "updateforworkshop", self：
--     第 5 个参数是任务名（用于取消），第 6 个是绑定 self。
-- → ★★★ 「先同步一次 + 再周期执行」是所有数据轮询的标准模式：
--     避免界面打开后的一段空白期。
    if self.updatetask ~= nil then
        self.updatetask:Cancel()
        self.updatetask = nil
    end

	self:UpdateForWorkshop()
	self.updatetask = staticScheduler:ExecutePeriodic( TUNING.MODS_QUERY_TIME, self.UpdateForWorkshop, nil, 0, "updateforworkshop", self )

end

local function ModNameVersionTableContains( modnames_versions, modname )
-- ══【三个纯函数辅助：变更检测的原子单位】
-- ModNameVersionTableContains：查某个模组是否已在已安装列表里。
--   用途见 506/634 行：下载中的模组若已在列表里就不重复加行。
-- ⚠️ 用 pairs 而非 ipairs：数组遍历应该用 ipairs。
--   这里只做存在性检查所以结果相同（除非表里有洞），
--   但与文件里其他地方（165/384 行用 ipairs）不统一。
	for _,v in pairs(modnames_versions) do
		if modname == v.modname then
			return true
		end
	end
	return false
end

local function CompareModnamesTable( t1, t2 )
-- ★★★ CompareModnamesTable 是「深度相等」的朴素实现。
-- 逐项比较 modname 与 version。
-- → ★★ 关键性质：**依赖调用方先排序**。
--   320-321 行先 table.sort 才调本函数，
--   所以比较的是「顺序敏感的相等」而非「集合相等」。
--   这比集合相等更严格（顺序变了也会触发刷新），
--   对 UI 而言反而是优点：顺序变了列表显示就该变。
-- ⚠️ 但它比较 version 字段，而 version 是在 324-329 行
--   单独填进 curr 表的。若某个模组不是 Workshop 模组，version = ""，
--   比较时两个空串相等 → 不会误触发刷新。正确。
-- ★ 292 行的 CompareModDLTable 是同一函数但**不比较 version**
--   —— 因为下载列表没有版本概念。这是刻意的差异，
--   但两个函数 90% 相同，应合并为带参数的一个。
	if #t1 ~= #t2 then
		return false
	end
	for i = 1, #t1 do
		if t1[i].modname ~= t2[i].modname or t1[i].version ~= t2[i].version then
			return false
		end
	end
	return true
end
local function CompareModDLTable( t1, t2 )
	if #t1 ~= #t2 then
		return false
	end
	for i = 1, #t1 do
		if t1[i].modname ~= t2[i].modname then
			return false
		end
	end
	return true
end

local function IsModOutOfDate( modname, workshop_version )
-- ══★【IsModOutOfDate：本文件的核心业务判定，全文 6 处调用】
-- 三个条件与：
--   ① IsWorkshopMod：只有创意工坊模组才可能「过期」
--   ② workshop_version ~= ""：还没查到线上版本 → 不算过期
--   ③ workshop_version ~= 本地版本：版本确实不同
-- ★★★ 三个条件缺一不可，尤其 ②：
--   联网前 GetWorkshopVersion 返回空串，若不判空，
--   所有模组都会显示「可更新」红点。
-- → ★ 「查询失败」与「查询结果为空」必须区分，
--     否则 UI 会把「不知道」显示成「有更新」。
-- ⚠️ 305 行最后一段没有括号：
--   `A and B and C and D.knownversion`
--   由于 A/B/C 都是布尔，最后一段的 D.knownversion 不会被隐式转换 ——
--   若 modname 不在 KnownModIndex 里，D 为 nil，整个表达式求值为 nil，
--   而调用方 `if IsModOutOfDate(...)` 把 nil 当假处理。行为正确。
--   但依赖「nil 在条件里为假」是隐式契约，建议显式加 tostring 或补括号。
	return IsWorkshopMod(modname) and workshop_version ~= "" and workshop_version ~= KnownModIndex:GetModInfo(modname).version
end

function ModsTab:UpdateForWorkshop( force_refresh )
-- ══★★★【UpdateForWorkshop：数据 → UI 的完整链路（375 行，本文件的心脏）】
-- ★★ 309 行 TryLockModDir 是**跨进程文件锁**：
--   模组目录可能被多个进程（游戏 + 启动器）同时读写。
--   抢不到锁就整个函数跳过（683 行的 if 结尾）。
--   → ★★★ 「拿不到资源就跳过本轮，下轮再试」是标准做法，
--     比阻塞等待或强行访问安全得多。
--   ★★ 每一处 return/结束都必须 UnlockModDir（346/681 行）：
--     两条路径都解锁了，说明作者注意到了这一点。
-- ⚠️ 但若 311-681 之间任何一行抛错，锁不会被释放。
--   正确写法是 pcall + finally 语义（或用 xpcall）。
--   → ★ 移植时凡涉及外部锁/文件句柄，必须有异常安全的释放路径。
	if TheSim:TryLockModDir() then
		KnownModIndex:UpdateModInfo()
		local curr_modnames_client = KnownModIndex:GetClientModNamesTable()
		local curr_modnames_server = KnownModIndex:GetServerModNamesTable()
		local curr_modnames_client_dl = TheSim:GetClientModsDownloading()
		local curr_modnames_server_dl = TheSim:GetServerModsDownloading()
		local function alphasort(moda, modb)
-- ★ alphasort 排序比较函数，两个防御分支处理 nil：
-- 316 `if not moda then return false end` —— 防止对 nil 取字段。
-- 317 `if not modb then return true end` —— nil 排在前面。
-- ★★★ 这是 table.sort 比较函数的标准防御：
--   比较函数可能被传入 nil（数组有洞时）。
-- → ★★★ 排序必须用 GetModFancyName（显示名）而非 modname（内部名）：
--   玩家看到的是显示名，排序要符合直觉。
--   用 string.lower 是为了大小写不敏感（「Apple」与「apple」相邻）。
-- ⚠️ 但 318 行的比较用的是 `<`，不是 `..` 拼接技巧 ——
--   对含特殊字符的名字可能排序异常。属细节。
			if not moda then return false end
			if not modb then return true end
			return string.lower(KnownModIndex:GetModFancyName(moda.modname)) < string.lower(KnownModIndex:GetModFancyName(modb.modname))
		end
		table.sort(curr_modnames_client, alphasort)
		table.sort(curr_modnames_server, alphasort)

		--update workshop version data into the curr list
		for k,v in pairs( curr_modnames_client ) do
-- ★★★ 版本信息的获取是「逐个查询 + 写回数据表」。
-- 325 行 v.version = IsWorkshopMod(...) and TheSim:GetWorkshopVersion(...) or ""。
--   → ★ 这是在**污染**从 KnownModIndex 拿到的原始表，
--     把「线上版本」这个 UI 关心的字段塞进了数据表。
--   好处：324-329 填完后，CompareModnamesTable 就能顺便比版本。
--   代价：数据表不再纯粹是「有哪些模组」，而是「UI 用的视图模型」。
-- → ★★★ 这其实是对的：UI 应该维护自己的视图模型，
--     而不是直接读原始数据源。
--     本文件把视图模型叫 self.modnames_client/server。
--   ⚠️ 但若 GetClientModNamesTable 返回的是**共享表**（非副本），
--     这里会污染全局状态。已核实 311-312 行每次都重新调用该函数，
--     所以拿到的是新表，安全。
			v.version = IsWorkshopMod(v.modname) and TheSim:GetWorkshopVersion(v.modname) or ""
		end
		for k,v in pairs( curr_modnames_server ) do
			v.version = IsWorkshopMod(v.modname) and TheSim:GetWorkshopVersion(v.modname) or ""
		end

		--check it see if anything changed
-- ★★★ 变更检测：四张表逐一比较，任一不同就重建全部 UI。
-- 332 行 need_to_udpate = force_refresh —— ★ 注意变量名拼写错误
--   （udpate 应为 update）。Lua 允许，但 grep 时容易漏。
-- 333 行额外判 `self.modnames_client == nil`（首次运行必然重建）。
-- ★★ 「全量比较 + 全量重建」是本文件的数据流策略：
--   不做增量更新（模组数量通常几十个，重建成本可接受）。
-- → ★★ 移植判据：**列表项数在两位数以内时，全量重建比增量更新简单得多**。
--   ScrollableList 的 SetList（642 行）本身就支持整体替换。
-- ★ 342-348 行的早退分支非常关键：
--   没变化时不碰 UI，但**仍然发起 Workshop 查询**（343-345）。
--   → ★★★ 「UI 不变 ≠ 后端不必工作」：
--     这里的数据源有两个（本地模组目录 + 线上 Workshop），
--     本地没变不代表线上没变，所以仍要查询。
--     这是「多个数据源各自独立刷新的正确写法」。
		local need_to_udpate = force_refresh
		if self.modnames_client == nil or
			not CompareModnamesTable( self.modnames_client, curr_modnames_client ) or
			not CompareModnamesTable( self.modnames_server, curr_modnames_server ) or
			not CompareModDLTable( self.modnames_client_dl, curr_modnames_client_dl ) or
			not CompareModDLTable( self.modnames_server_dl, curr_modnames_server_dl ) then
			need_to_udpate = true
		end

		--If nothing has changed bail out and leave the ui alone
		if not need_to_udpate then
			if TheSim:IsLoggedOn() then
				TheSim:StartWorkshopQuery()
			end
			TheSim:UnlockModDir()
			return
		end

		--print("### Do UpdateForWorkshop refresh")

		self.modnames_client = curr_modnames_client
		self.modnames_server = curr_modnames_server
		self.modnames_client_dl = curr_modnames_client_dl
		self.modnames_server_dl = curr_modnames_server_dl

		self:ReloadModInfoPrefabs()

		--figure out the current selection after the refresh
-- ══★【刷新后恢复选中态：按名字找新索引】
-- 360 行默认索引 1。
-- 361 行 client_mod_type = self.client_only —— ⚠️ 从未赋值过。
--   grep 核实：client_only 在本文件只出现 1 次（即这行）。
--   → 它永远是 nil，于是 363 行立刻被 `currentmodtype ~= nil` 覆盖。
--     361 行是死代码，但 363 行的逻辑是对的。
-- 365-379 按 currentmodname 在新表里找下标。
-- ⚠️ 用 pairs 遍历却把 k 当索引用（369/375 行 mod_index = k）。
--   数组用 pairs 遍历时 k 确实是整数索引，所以能用。
--   但与文件里其他地方的 ipairs 不一致，且 pairs 顺序无保证 ——
--   因为这里只要下标正确，顺序无所谓，可以接受。
-- ★★ 与 scrollablelist 的 keeprelativefocusindex 对比：
--   那里只能记相对位置（数据项无稳定标识），这里能记名字（有标识）。
--   → 「有无稳定标识」决定了选中保持的实现难度。
		local mod_index = 1
		local client_mod_type = self.client_only
		if self.currentmodtype ~= nil then
			client_mod_type = self.currentmodtype == "client"
		end
		if self.currentmodname ~= nil then
			if client_mod_type then
				for k,v in pairs(self.modnames_client) do
					if v.modname == self.currentmodname then
						mod_index = k
					end
				end
			else
				for k,v in pairs(self.modnames_server) do
					if v.modname == self.currentmodname then
						mod_index = k
					end
				end
			end
		end

		local out_of_date_mods = 0
		-- Now that we're up to date, build widgets for all the mods
		self.optionwidgets_client = {}
		for i,v in ipairs(self.modnames_client) do
-- ══⚠️⚠️【★★★ 本文件最大的结构问题：384-504 与 513-632 整段复制粘贴】
-- 两段各约 120 行，逻辑完全相同，只有三处不同：
--   1) 遍历 modnames_client vs modnames_server
--   2) 收集到 optionwidgets_client vs optionwidgets_server
--   3) 451 行 ShowModDetails(idx, true) vs 580 行 (idx, false)
-- 连 OnGainFocus/OnLoseFocus/StartClick/FinishClick/OnControl/
-- checkbox.OnControl/GetHelpText 六个闭包都是逐字复制。
-- → ★★★ 这是「双列表」需求的必然结果，但实现方式糟糕：
--   正确做法是抽一个 BuildOptionWidgets(modnames, is_client) 返回数组，
--   两处各调一次。整个文件能瘦掉 120 行。
-- → ★★ 更严重的后果：**修改必须同步改两处**，
--   漏一处就会导致「客户端模组能勾选、服务端模组不能」这类难查 bug。
--   → 移植时的硬规则：**同一段逻辑出现两次以上就该抽函数**，
--     出现两次且带一个布尔差异时，抽函数 + 参数是标准解法。
-- ⚠️ 值得肯定的是：两段的顺序完全一致（对比 486-487 与 614-615），
--   说明 GetHelpText 的顺序是有意设计而非随意。
-- ★★ 另一个有意思的细节：两段都用了 `local idx = i`（386/515 行）。
--   这是**闭包捕获循环变量的经典防御**：
--   直接在闭包里用 i 会捕获到循环结束后的值（Lua 5.1 里是共享的），
--   复制到局部变量后每个闭包捕获各自的值。
--   → ★★★ 这是本文件最值得学的一处技术细节：
--     在 for 循环里给控件挂闭包时，**必须先 local 化循环变量**。
--     （Lua 5.2+ 每轮迭代新建变量，但 5.1 不行；DST 用 5.1 语义。）
-- ⚠️ 但 386 行写成 `local idx = i` 而 388/392 行直接用 v 的字段提取了 modname，
--   说明作者对 modname 做了同样处理（388 行 local modname = v.modname）。
--   这是**一致且正确**的。

			local idx = i

			local modname = v.modname
			local modinfo = KnownModIndex:GetModInfo(modname)
			local modstatus = self:GetBestModStatus(modname)

			local opt = TEMPLATES.ModListItem(modname, modinfo, modstatus, KnownModIndex:IsModEnabled(modname))
			opt.idx = idx

			opt.OnGainFocus =
-- ★★★ 焦点视觉反馈：OnGainFocus 播音效 + 显示 state_bg。
-- 397 行用 ClickMouseoverSoundReduction() 降音量 ——
--   与 scrollablelist 的 238/727/750 行同一模式。
--   → ★ 「焦点音效」在全项目里统一降音量，说明这是被反复讨论过的决定。
-- ★ 赋值方式：opt.OnGainFocus = function() ... end（**覆盖实例字段**）。
--   注意不是 SetOnGainFocus（widget.lua:569 提供的并存式 API）。
--   → 与 scrollablelist:149 的 OnLoseFocus 覆盖同类。
--     差别在于：这里 ModListItem 是 TEMPLATES 造的行控件，
--     其基类 OnGainFocus 大概是空的，覆盖无损失。
--   → ★★ 覆盖实例字段 vs SetOnGainFocus：
--     覆盖会丢掉基类行为，SetOnGainFocus 是并存的。
--     **写新代码时应优先用 SetOnGainFocus**，除非确认基类是空的。
				function()
					TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_mouseover", nil, ClickMouseoverSoundReduction())
					opt.state_bg:Show()
				end

			opt.OnLoseFocus =
-- ★★ OnLoseFocus 除了藏背景，还负责「把按下位移复位」。
-- 404-407：若 o_pos 非 nil（说明正被按下），恢复原位置并清标记。
--   → ★★★ 「按下位移」的复位必须同时挂在 OnLoseFocus 和 OnControl(up) 上，
--     因为焦点可能在按下状态下被抢走（如推入弹窗）。
--     本文件在 444-447 与 465-468 各做了一次，OnLoseFocus 是兜底。
--   → ★ 「视觉状态的所有出口都要复位」是 UI 状态机的基本要求：
--     正常结束、失焦、被销毁，三条路径都要处理。
-- o_pos 的设置见 435-438 行（按下时记录原位置并加 clickoffset）。
				function()
					opt.state_bg:Hide()
                    if opt.o_pos ~= nil then
                        opt:SetPosition(opt.o_pos)
                        opt.o_pos = nil
                    end
				end

			opt.StartClick = function()
-- ══★【StartClick / FinishClick：双击检测的手写实现】
-- 410-414 StartClick（按下时）：
--   若点的不是当前选中项，清掉双击计时 → 保证「换行点击」不误判双击。
--   → ★★★ 这是双击检测的关键一行，漏了它就会「快速点两个不同行 = 切换启用」。
-- 416-428 FinishClick（松开时）：
--   418 判断「同一项 + 距上次点击 <= DOUBLE_CLICK_TIMEOUT」→ 双击 → EnableCurrent
--   423-427 双击则清计时，单击则记时间戳
-- → ★★ 状态机只有两个状态（空闲 / 刚单击过），靠一个时间戳区分。
--   ★ 用 GetTimeReal() 而非 GetTime()：
--     模组界面在暂停下也要能点，若用模拟时间暂停后计时器不前进，
--     双击窗口会异常地长。
--   → ★★★ 「双击 = 单击 + 延时窗口」是所有 UI 库的通用实现，
--     没有例外。移植时不必重新设计。
-- ⚠️ 注意 EnableCurrent 会触发模组加载（705 行），
--   在**松开**时执行是刻意的（避免按下时就改状态）。
				if modname ~= self.currentmodname then
					self.last_mod_click_time = nil
				end
			end

			opt.FinishClick = function()
				local double = false
				if modname == self.currentmodname and self.last_mod_click_time and GetTimeReal() - self.last_mod_click_time <= DOUBLE_CLICK_TIMEOUT then
					self:EnableCurrent(idx)
					double = true
				end

				if double then
					self.last_mod_click_time = nil
				else
					self.last_mod_click_time = GetTimeReal()
				end
			end

			opt.OnControl =
-- ══★【行的输入处理：opt.OnControl 被整体覆盖】
-- 432 行先调基类 Widget.OnControl(opt, ...) —— 这是正确的兜底。
--   （基类会递归派发给子控件，包括 checkbox。）
-- ★★ 434 行的条件是本文件的输入设计核心：
--   `control == CONTROL_ACCEPT or (control == CONTROL_MENU_MISC_2 and 手柄)`
--   → 鼠标：ACCEPT（=左键）可点
--   → 手柄：ACCEPT 或 MISC_2 都能按下（两个按键都映射到选中）。
--   → ★★★ 「同一动作绑定多个键」以适配不同设备，且用设备检测区分。
-- 435-438 按下位移：o_pos 只在第一次按下时记录（`if opt.o_pos == nil`）。
--   → ★ 防止重复按下时叠加多次位移。
-- ★ 439-441：只有 ACCEPT 才调 StartClick（MISC_2 不参与双击检测）。
--   → 双击只在主键上生效，是合理的设计取舍。
				function(_, control, down)
					if Widget.OnControl(opt, control, down) then return true end
					if down then
						if control == CONTROL_ACCEPT or (control == CONTROL_MENU_MISC_2 and TheInput:ControllerAttached()) then
                            if opt.o_pos == nil then
                                opt.o_pos = opt:GetLocalPosition()
                                opt:SetPosition(opt.o_pos + opt.clickoffset)
                            end
							if control == CONTROL_ACCEPT then
								opt.StartClick()
							end
						end
					else
-- ══★【松开分支：三个出口，各不相同】
-- 444-447 复位按下位移（无条件，任何键松开都做）。
-- 448-452 ACCEPT → FinishClick（可能双击）+ 播音效 + ShowModDetails。
--   → ★★ 「单击 = 选中并显示详情」，而双击已在 FinishClick 里启用了。
--     所以单击不会误启用。
-- 453-457 MISC_1（另一个键）→ 直接 EnableCurrent（开关该模组）。
--   → ★★★ 「不同键做不同事」：主键选中，辅键切换开关。
--     这让手柄上「A 选中 / X 开关」可以独立操作，效率高。
-- ⚠️ 但 448 与 453 都是 return true，没有 return false 的出口。
--   → 即「按了不认识的键」也返回 nil（函数末尾无 return），
--     事件会继续冒泡给父控件。这是正确的。
						if opt.o_pos ~= nil then
							opt:SetPosition(opt.o_pos)
							opt.o_pos = nil
						end
						if control == CONTROL_ACCEPT then
							opt.FinishClick()
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							self:ShowModDetails(idx, true)
							return true
						elseif control == CONTROL_MENU_MISC_1 then
							self:EnableCurrent(idx)
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							return true
						end
					end
				end

			opt.checkbox.OnControl =
-- ★★ checkbox 的 OnControl 被单独覆盖，与 opt 的分开。
-- ★ 463 行调的是 `Widget.OnControl(opt.checkbox, ...)` 而不是基类的基类，
--   正确（要在 checkbox 自己的上下文里跑）。
-- 469 行的条件与行本体不同：
--   `ACCEPT and (not 手柄 or tracking_mouse)`
--   → ★★★ 「手柄下点 checkbox 不触发」（因为手柄用 MISC_1），
--     但**手柄连着鼠标时例外**（tracking_mouse）。
--   这是「手柄 + 鼠标同时可用」的精细处理。
-- ⚠️ 465-468 复位位移的代码与行本体的 444-447 逐字相同，
--   在 checkbox 的处理器里复位**行**的位移 —— 逻辑正确（同一个 opt），
--   但位置很奇怪（在 checkbox 的回调里改 opt 的位置）。
--   → 反映了这个文件的实现是「哪里方便塞哪里」。
				function(_, control, down)
					if Widget.OnControl(opt.checkbox, control, down) then return true end
					if not down then
						if opt.o_pos then
							opt:SetPosition(opt.o_pos)
							opt.o_pos = nil
						end
						if control == CONTROL_ACCEPT and (not TheInput:ControllerAttached() or TheFrontEnd.tracking_mouse) then
							self:EnableCurrent(idx)
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							return true
						elseif control == CONTROL_MENU_MISC_1 then
							self:EnableCurrent(idx)
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							return true
						end
					end
				end


			opt.GetHelpText = function()
				local controller_id = TheInput:GetControllerID()
				local t = {}

				table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_MENU_MISC_1) .. " " .. STRINGS.UI.HELP.TOGGLE)
				table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT) .. " " .. STRINGS.UI.HELP.SELECT)

				return table.concat(t, "  ")
			end

			table.insert(self.optionwidgets_client, opt)

			if IsModOutOfDate( modname, v.version ) then
-- ★★ out_of_date_mods 的累加与行内红点显示绑定在一起。
-- 495 计数、496 显示行内红点；498 反之隐藏。
-- → ★★★ 「统计与显示在同一个循环里完成」：
--     省掉一次遍历，且保证两者永远一致。
--   这个计数最终用于 664 行决定 updateallbutton 的徽章数字。
-- ⚠️ 664 行用的是 out_of_date_mods（**全部**模组的过期数），
--   而 661 行的下载数是分客户端/服务端的。
--   徽章数字在两种情形下含义不同（下载中 = 正在下载的个数），
--   但共用同一个徽章控件 —— 靠互斥的 if/elseif 保证只显示一种。
				out_of_date_mods = out_of_date_mods + 1
				opt.out_of_date_image:Show()
			else
				opt.out_of_date_image:Hide()
			end

			if KnownModIndex:HasModConfigurationOptions(modname) then
-- ★ 「可配置」标记（configurable_image）在**构建期**就确定。
--   而不是等到选中时（860-864 行）才判断。
-- → ★★ 两处判断用的是同一个 HasModConfigurationOptions，
--   但一处用于「行的图标」，一处用于「右侧按钮的可用性」。
--   → ★★★ 「同一事实在两个层级分别消费」是常见做法，
--     但要求事实的来源唯一（这里是 KnownModIndex）。
--   若两处用不同的判断逻辑，就会出现「行显示可配但按钮灰掉」。
--   移植时应把这类判断抽成单一函数。
				opt.configurable_image:Show()
			end
		end
		for _,v in ipairs(self.modnames_client_dl) do
-- ★★ 下载中的模组作为「额外的行」追加到列表末尾。
-- 506 行只加「尚未安装」的（避免与已安装的重复）。
-- 507 行 ModDLListItem 是一个更简单的行模板（只有名字）。
-- → ★★★ 「下载中」也占一个列表位置，是让状态可见的好做法。
--     玩家能看到「正在下 3 个模组」而不是界面毫无反应。
-- ⚠️ 但这些行没有 OnControl 等回调（TEMPLATES.ModDLListItem 自带），
--   所以点它们不会有反应。若玩家误以为可以操作，
--   就会遇到「点了没动静」。属体验缺陷。
-- ★ 505 行的遍历对象是 self.modnames_client_dl（354 行刚赋的新值）。
			if not ModNameVersionTableContains( self.modnames_client, v.modname ) then
				local opt = TEMPLATES.ModDLListItem(v.fancy_name)
				table.insert(self.optionwidgets_client, opt)
			end
		end

		self.optionwidgets_server = {}
		for i,v in ipairs(self.modnames_server) do

			local idx = i

			local modname = v.modname
			local modinfo = KnownModIndex:GetModInfo(modname)
			local modstatus = self:GetBestModStatus(modname)

			local opt = TEMPLATES.ModListItem(modname, modinfo, modstatus, KnownModIndex:IsModEnabled(modname))
			opt.idx = idx

			opt.OnGainFocus =
				function()
					TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_mouseover", nil, ClickMouseoverSoundReduction())
					opt.state_bg:Show()
				end

			opt.OnLoseFocus =
				function()
					opt.state_bg:Hide()
                    if opt.o_pos ~= nil then
                        opt:SetPosition(opt.o_pos)
                        opt.o_pos = nil
                    end
				end

			opt.StartClick = function()
				if modname ~= self.currentmodname then
					self.last_mod_click_time = nil
				end
			end

			opt.FinishClick = function()
				local double = false
				if modname == self.currentmodname and self.last_mod_click_time and GetTimeReal() - self.last_mod_click_time <= DOUBLE_CLICK_TIMEOUT then
					self:EnableCurrent(idx)
					double = true
				end

				if double then
					self.last_mod_click_time = nil
				else
					self.last_mod_click_time = GetTimeReal()
				end
			end

			opt.OnControl =
				function(_, control, down)
					if Widget.OnControl(opt, control, down) then return true end
					if down then
						if control == CONTROL_ACCEPT or (control == CONTROL_MENU_MISC_2 and TheInput:ControllerAttached()) then
                            if opt.o_pos == nil then
                                opt.o_pos = opt:GetLocalPosition()
                                opt:SetPosition(opt.o_pos + opt.clickoffset)
                            end
							if control == CONTROL_ACCEPT then
								opt.StartClick()
							end
						end
					else
						if opt.o_pos ~= nil then
							opt:SetPosition(opt.o_pos)
							opt.o_pos = nil
						end
						if control == CONTROL_ACCEPT then
							opt.FinishClick()
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							self:ShowModDetails(idx, false)
							return true
						elseif control == CONTROL_MENU_MISC_1 then
							self:EnableCurrent(idx)
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							return true
						end
					end
				end

			opt.checkbox.OnControl =
				function(_, control, down)
					if Widget.OnControl(opt.checkbox, control, down) then return true end
					if not down then
						if opt.o_pos then
							opt:SetPosition(opt.o_pos)
							opt.o_pos = nil
						end
						if control == CONTROL_ACCEPT and (not TheInput:ControllerAttached() or TheFrontEnd.tracking_mouse) then
							self:EnableCurrent(idx)
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							return true
						elseif control == CONTROL_MENU_MISC_1 then
							self:EnableCurrent(idx)
							TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
							return true
						end
					end
				end

			opt.GetHelpText = function()
				local controller_id = TheInput:GetControllerID()
				local t = {}

				table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT) .. " " .. STRINGS.UI.HELP.SELECT)
				table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_MENU_MISC_1) .. " " .. STRINGS.UI.HELP.TOGGLE)

				return table.concat(t, "  ")
			end

			table.insert(self.optionwidgets_server, opt)

			if IsModOutOfDate( modname, v.version ) then
				out_of_date_mods = out_of_date_mods + 1
				opt.out_of_date_image:Show()
			else
				opt.out_of_date_image:Hide()
			end

			if KnownModIndex:HasModConfigurationOptions(modname) then
				opt.configurable_image:Show()
			end
		end
		for _,v in ipairs(self.modnames_server_dl) do
			if not ModNameVersionTableContains( self.modnames_server, v.modname ) then
				local opt = TEMPLATES.ModDLListItem(v.fancy_name)
				table.insert(self.optionwidgets_server, opt)
			end
		end

		-- And make a scrollable list!
-- ══★★【★ 列表的创建与更新：模式 A（自带子控件），非虚拟化】
-- 641-651 行：首次创建用 AddChild(ScrollableList(...))，
--   之后用 SetList 替换数据。
-- ★★ 645 行的构造参数解读（对照 scrollablelist 的 36 行签名）：
--   items    = optionwidgets_client（**已构造好的控件数组**）
--   listwidth = 183, listheight = 450
--   itemheight = 90, itempadding = 3
--   updatefn / widgetstoupdate = nil, nil ← ★★ 决定了走**模式 A**
--   → 所以每个模组都有一个专属控件，**没有虚拟化**。
--   模组数量通常几十个，控件数与项数成正比，可接受。
--   → ★★★ 选型印证了 scrollablelist 的判据：
--     「项数是否会无界增长」。模组列表有上限（几百个），
--     所以简单模式够用；而服务器列表可能上千，才需要池化。
-- ⚠️ 642 行 SetList(self.optionwidgets_client) 只传了第一个参数，
--   keepitems / scrollto / keeprelativefocusindex 全为 nil。
--   → scrollablelist 的 SetList（530 行）在 keepitems 为 nil 且
--     **有 updatefn 或 static_widgets** 时会跳过销毁分支。
--     本例两者都是 nil，所以走 532 行的分支：
--     **把所有旧控件 Kill 掉，再 AddChild 新的**。
--   → 即：每次刷新都完全重建列表（控件全销毁重建）。
--     配合 384-632 行的重新构建，实际是「数据控件双重重建」。
--     对几十项来说可以接受，但 100+ 模组时会卡顿。
-- ★ 651 行之后没有 SetPosition/SetScale 之外的处理，
--   说明滚动位置在 SetList 时会重置（scrollablelist 545 行 Scroll(0,true)）。
		if self.options_scroll_list_client ~= nil then
			self.options_scroll_list_client:SetList(self.optionwidgets_client)
			self.options_scroll_list_server:SetList(self.optionwidgets_server)
		else
			self.options_scroll_list_client = self.mods_page:AddChild(ScrollableList(self.optionwidgets_client, 183, 450, 90, 3, nil, nil, nil, nil, nil, -15))
			self.options_scroll_list_client:SetPosition(-172, 0)
			self.options_scroll_list_client:SetScale(.8)
			self.options_scroll_list_server = self.mods_page:AddChild(ScrollableList(self.optionwidgets_server, 183, 450, 90, 3, nil, nil, nil, nil, nil, -15))
			self.options_scroll_list_server:SetPosition(-172, 0)
			self.options_scroll_list_server:SetScale(.8)
		end

		self:SetModsList(self.currentmodtype)
-- ★★ 653-654 行的顺序：先 SetModsList 再 ShowModDetails。
-- 653 行 SetModsList 内部**也会**调 ShowModDetails（171/187 行）。
-- 654 行又调了一次（用精确的 mod_index）。
-- → 即同一次刷新中 ShowModDetails 被调两次：
--   第一次用「上次选中项」恢复，第二次用「刷新前算出的索引」。
-- ★★ 这个重复是有意义的：
--   653 行保证页签状态与导航按钮正确；
--   654 行保证详情面板显示的是「刷新后索引对应的那个 mod」。
--   → 但两次调用之间有状态写入（803-806 行写 last_*_modname），
--     所以第一次调用已经把 last_*_modname 改了，
--     第二次若 idx 指向别的 mod 会再改一次。行为正确但绕。
--   → ★ 移植提示：「恢复选中」与「应用选中」是两个动作，
--     最好显式分成 RestoreSelection() 与 SelectMod(idx)。
		self:ShowModDetails(mod_index, client_mod_type)

		--update the text on Update All button to indicate how many mods are out of date
-- ══★【updateallbutton 的三态：下载中 / 有更新 / 全部最新】
-- 657-663 下载中：显示下载数，Select（灰掉，因为正在下载不能重复触发）
-- 664-669 有过期：显示过期数，Unselect，**enabled = true**
-- 670-675 全最新：隐藏徽章，Select，enabled = false
-- → ★★★ 三态的判据是「下载数」与「过期数」，且下载优先。
--   徽章数字的含义随状态改变（下载数 vs 过期数），但控件复用同一个。
-- ★★ enabled 字段与 Select/Unselect 是**两个独立状态**：
--   663 行 Select + enabled=false（下载中，不可点）
--   668 行 Unselect + enabled=true（可更新）
--   674 行 Select + enabled=false（无更新）
--   → 可见性（Unselect）与可用性（enabled）恰好同向，
--     实际上 enabled 可以直接由状态推导，这里存成字段是为了
--     1078 行 UpdateAllButton 能查询。
-- ⚠️ 但 modupdateable / modconfigable 字段（92/122 行）也有同样机制，
--   说明这是全文件统一的「字段驱动点击拦截」模式（见 1017 行）。
		if #self.modnames_client_dl > 0 or #self.modnames_server_dl > 0 then
			--updating
			self.updateallbutton:SetHoverText(STRINGS.UI.MODSSCREEN.UPDATINGMOD)
			self.updateallbutton.out_of_date_image:Show()
			self.updateallbutton.out_of_date_image.count:SetString(tostring(#self.modnames_client_dl + #self.modnames_server_dl))
			self.updateallbutton:Select()
			self.updateallenabled = false
		elseif out_of_date_mods > 0 then
			self.updateallbutton:SetHoverText(STRINGS.UI.MODSSCREEN.UPDATEALL)
			self.updateallbutton.out_of_date_image:Show()
			self.updateallbutton.out_of_date_image.count:SetString(tostring(out_of_date_mods))
			self.updateallbutton:Unselect()
			self.updateallenabled = true
		else
			self.updateallbutton:SetHoverText(STRINGS.UI.MODSSCREEN.UPTODATEALL)
			self.updateallbutton.out_of_date_image:Hide()
			self.updateallbutton.out_of_date_image.count:SetString("")
			self.updateallbutton:Select()
			self.updateallenabled = false
		end

		--Note(Peter) do we need to do this focus hookup?
-- ★ 作者自己留了问句注释「Note(Peter) do we need to do this focus hookup?」。
-- → ★★★ 「不确定但保险起见就调」——
--   DoFocusHookups 是幂等的，多调一次无害，但留着这句注释
--   说明作者对**必要性**没有把握。
--   实际分析：679 行之前 widget 全部重建了，
--   而 1134-1163 行的 SetFocusChangeDir 目标是 modconfigbutton 等
--   **未重建的控件**，且 optionwidgets 的焦点链由 ScrollableList 内部管理。
--   → 所以这次调用很可能确实必要（列表重建后要重新连），
--     但注释里的疑问仍未解答。
		self:DoFocusHookups()

		TheSim:UnlockModDir()
	end
end

function ModsTab:GetOutOfDateEnabledMods()
    local outofdate = {}
    local enabled = ModManager:GetEnabledServerModNames()

    for i,v in pairs(enabled) do
        local version = IsWorkshopMod(v) and TheSim:GetWorkshopVersion(v) or ""
        if IsModOutOfDate( v, version ) then
            table.insert(outofdate, v)
        end
    end

    return outofdate
end

function ModsTab:OnConfirmEnable(restart, modname)
-- ══★★【OnConfirmEnable：模组启停的真正执行点 —— 有副作用、有副作用的重入】
-- 700-706 行的启用/禁用：
--   注意顺序：FrontendUnloadMod 在 Disable **之前**，
--   FrontendLoadMod 在 Enable **之后**。
--   → ★ 这就是「状态先改、资源后动」与「资源先卸、状态后改」的顺序差异，
--     反映两个操作的语义：卸载时先拿掉代码再改标记；
--     加载时先改标记再载入代码（让载入过程能看到新状态）。
-- ⚠️ 但这个顺序差异没有注释说明，很容易被后人「统一风格」而改坏。
-- ★★★ FrontendLoadMod 会在**前端**动态执行模组的 main.lua ——
--   这是 DST 允许「不重启就启用模组」的机制。
--   代价是已加载的实体不会受影响（见 752 行 restart_required 判定）。
    if KnownModIndex:IsModEnabled(modname) then
        ModManager:FrontendUnloadMod(modname)
		KnownModIndex:Disable(modname)
	else
		KnownModIndex:Enable(modname)
        ModManager:FrontendLoadMod(modname)
	end

    --show the auto-download warning for non-workshop mods
-- ★★ 启用后的两种警告，各压一个确认弹窗。
-- 710-721 all_clients_require_mod 且非创意工坊 → 警告无法自动分发。
--   713-715 IsRail() 时换文案（Rail = 主机平台，有自己的分发机制）。
-- → ★★★ 「同一警告、不同平台不同文案」的最小实现。
--   → 移植时应把「文案选择」与「警告内容」分开，
--     便于日后国际化或按平台细分。
-- ⚠️⚠️【真实缺陷】716 行 PushScreen 后，725 行**又** PushScreen 一个弹窗。
--   两个 if 是**顺序执行**而非 elseif：
--     若一个模组同时满足 all_clients_require_mod 与 不兼容，
--     会**连续压两个弹窗**（玩家要点两次「确定」）。
--   → 这不是崩溃，但体验上明显是 bug。
--   正确写法：合并成一个弹窗的多行文本，或收集警告后一次显示。
--   我已逐行核实 710/711/724 是两个独立 if，非 elseif。
-- ★ 注意这两个警告只 PushScreen，**不阻塞后面的逻辑**
--   （731-734 行照样执行），因为 Lua 没有 await。
--   → ★★ 这是「同步代码里插异步 UI」的固有局限：
--     必须靠状态机而非顺序流来处理「等用户点确定」。
--     正确做法是把后续动作放进弹窗的回调里（见 716-719 就是这么做的）。
    local modinfo = KnownModIndex:GetModInfo(modname)
    if KnownModIndex:IsModEnabled(modname) and modinfo.all_clients_require_mod then
        if not IsWorkshopMod(modname) then
			local warn_txt = STRINGS.UI.MODSSCREEN.MOD_WARNING
			if IsRail() then
				warn_txt = STRINGS.UI.MODSSCREEN.MOD_WARNING_RAIL
			end
			TheFrontEnd:PushScreen(PopupDialogScreen(STRINGS.UI.MODSSCREEN.MOD_WARNING_TITLE, warn_txt,
            {
                {text=STRINGS.UI.MODSSCREEN.OK, cb = function() TheFrontEnd:PopScreen() end }
            }))
        end
    end

    --Warn about incompatible mods being enabled
    if KnownModIndex:IsModEnabled(modname) and (not modinfo.dst_compatible or modinfo.dst_compatibility_specified == false) then
        TheFrontEnd:PushScreen(PopupDialogScreen(STRINGS.UI.MODSSCREEN.MOD_WARNING_TITLE, STRINGS.UI.MODSSCREEN.DST_COMPAT_WARNING,
        {
            {text=STRINGS.UI.MODSSCREEN.OK, cb = function() TheFrontEnd:PopScreen() end }
        }))
    end

    self.servercreationscreen:UpdateModeSpinner(self.slotnum)
-- ★★★【反向通知宿主：这是「Widget 而非 Screen」的必然代价】
-- 四行通知：更新模式转盘、更新按钮、标脏、刷新世界页签。
-- → ★★ 「界面变化要通知所有关心的人」：
--     ModsTab 改了模组启用状态，但按「启动世界」按钮、
--     显示的模组数、世界列表都可能受影响，所以逐个通知。
-- → ★★★ 这是**没有观察者机制**时的标准做法：手动逐个通知。
--     自研 UI 若要做到位，应引入「事件总线/信号」替代这种硬编码通知：
--       self.servercreationscreen:OnModsChanged()（一个入口，
--       由它内部决定要刷新哪些子部件）。
-- ⚠️ MakeDirty 的语义值得注意：把存档槽标为「已修改」
--   （未保存的变更）。模组启停确实改变了存档内容。
-- ★ 736-739：restart 时保存并退出游戏 —— 不可逆操作。
--   → 「不可逆操作必须放在用户确认的回调里」，这里正是（756 行的回调）。
    self.servercreationscreen:UpdateButtons(self.slotnum)
    self.servercreationscreen:MakeDirty()
    self.servercreationscreen.world_tab:Refresh()

    if restart then
        KnownModIndex:Save()
        TheSim:Quit()
    end
end

function ModsTab:EnableCurrent(idx)
-- ══★【EnableCurrent：双击后的分派，含两处隐患】
-- 744-748 按页签类型取 modname。
-- ⚠️【真实缺陷，已逐行核实 + 已读下游实现确认】
-- 745/747 行直接 `self.modnames_client[idx].modname`，**没有判 idx 越界**。
--   若 idx 超出范围会崩溃。
--   idx 来源：闭包里的 local idx（386/515 行），来自 for 循环，合法。
-- ★★ 我已读 templates.lua:1109-1126 的 ModDLListItem 实现并确认：
--   它只建 white_bg / name 两个子控件，**没有 OnControl、没有 checkbox、
--   不捕获 idx**。所以 505-510 行追加的下载行不会被点击，
--   也不会带着越界 idx 调 EnableCurrent。
--   → 结论：**当前不可触发**，属「靠上下游约束侥幸安全」。
--     但这正是最危险的形态：任何人对 ModDLListItem 加一个可点击回调，
--     就会立刻引入越界崩溃。正确做法是加一行 `if ... [idx] then` 守卫。
--   → ★★★ 移植要点：**「行数 ≠ 数据项数」的列表，索引前必须判数据**。
--     本文件在 797-801 行（ShowModDetails）做对了这件事，
--     在 742 行（EnableCurrent）漏了 —— 同一文件里的现成对照。
-- 746 行 `elseif not self.client_only` —— client_only 从未赋值（见 361 行）。
--   所以这个条件恒真（not nil == true），第二个分支总是可达。
-- ★ 762 行无条件重调 ShowModDetails —— 刷新按钮与勾选态。
    local modname = nil
	if self.currentmodtype == "client" then
		modname = self.modnames_client[idx].modname
	elseif not self.client_only then
		modname = self.modnames_server[idx].modname
	end

    local modinfo = KnownModIndex:GetModInfo(modname)

    if modinfo and modinfo.restart_required then
-- ★★ restart_required 的模组必须重启才能生效。
-- 753 行 print 到控制台（开发者可见），玩家看不到。
-- 754-758 弹出「重启 or 取消」双按钮确认框。
--   → ★★ 「确认框的回调即后续动作」：
--     756 行确认 → OnConfirmEnable(true, modname) → 736-739 保存并退出。
--     757 行取消 → PopScreen（注意：**不会撤销任何改动**，
--     因为此时还没改状态，改动在确认回调里才做）。
--   → ★★★ 这是「先问再做」的干净实现：
--     可逆性检查放在动作之前，而不是「先做再撤销」。
-- ★ 759 行 elseif modname then：非 restart 的模组直接执行。
--   ⚠️ 但 750 行 `KnownModIndex:GetModInfo(modname)` 在 modname 为 nil 时
--   可能报错（743 行 modname 初值就是 nil）。
--   750 行没有 `modname and` 守卫。
--   → 疑似缺陷：当 currentmodtype 既非 client 又 client_only 为真时，
--     modname 保持 nil，750 行会拿 nil 去查。
--     实践中 746 行条件恒真所以不会到这。属「靠巧合」。
        print("RESTART REQUIRED")
        TheFrontEnd:PushScreen(PopupDialogScreen(STRINGS.UI.MODSSCREEN.RESTART_TITLE, STRINGS.UI.MODSSCREEN.RESTART_REQUIRED,
        {
            {text=STRINGS.UI.MODSSCREEN.RESTART, cb = function() self:OnConfirmEnable(true, modname) end },
            {text=STRINGS.UI.MODSSCREEN.CANCEL, cb = function() TheFrontEnd:PopScreen() end}
        }))
    elseif modname then
        self:OnConfirmEnable(false, modname)
    end
	self:ShowModDetails(idx, self.currentmodtype == "client")
end

function ModsTab:GetBestModStatus(modname)
-- ★★★ GetBestModStatus：把三种状态压成一个字符串枚举。
-- 优先级：已启用 > 加载失败/已知坏 > 手动禁用。
-- → ★ 「返回一个字符串枚举而非布尔」的价值：
--   890-912 行按这个字符串分派三种配色与文案，
--   若返回布尔就需要 UI 自己再查一遍状态。
--   → ★★★ 「UI 需要的语义由查询函数直接给出」是干净的接口设计。
-- ⚠️ 766 行取了 modinfo 但**没用**（770 行又调了一次 GetModInfo）。
--   冗余，且若 GetModInfo 较慢就是双倍开销。
--   → 与 scrollablelist:46 的 `self.items = {}` 立即被覆盖同类。
    local modinfo = KnownModIndex:GetModInfo(modname)
    if KnownModIndex:IsModEnabled(modname) then
       return "WORKING_NORMALLY"
    else
        if KnownModIndex:GetModInfo(modname).failed or KnownModIndex:IsModKnownBad(modname) then
            return "DISABLED_ERROR"
        else
            return "DISABLED_MANUAL"
        end
    end
end

local splitChars = {" ", "-", "_", "|", "/", "\\", "+", "=", "(", ")", ".", ",", "~", "*", "[", "]", "<", ">"}
-- ⚠️【死变量，已 grep 全文件核实】splitChars 只出现在这一行。
--   它是一个「用于把模组名按分隔符切成单词」的字符表，
--   显然是某个搜索/高亮功能的遗留。
--   → 死变量与 12-13 行的 DISABLE/ENABLE、15-17 行的 left_col/right_col
--     一起，构成本文件的「第四类遗留物」。
-- ★ 统计一下：本文件共有 5 处已确认的死代码（DISABLE/ENABLE/left_col/
--   right_col/splitChars），占比不算小。
--   → 移植时应删，但删了要确认没有模组通过 debug 手段引用它们。

function ModsTab:ShowModDetails(idx, client_mod)
-- ══★★【ShowModDetails：详情面板的唯一填充函数（146 行）】
-- ★★ 781-782 行的三元表达式用 client_mod 选表：
--   `client_mod and A or B` —— 经典写法（playerhud:1191 也这么判断）。
-- ⚠️ 但这种写法**在 client_mod 为 false 时会出问题**：
--   `false and A or B` → false and A = false → false or B = B。正确。
--   只有当 A 本身为 false/nil 时才会出错。这里 A 是表，安全。
-- ★ 784 行的三重守卫（widgetTable 非空 + modnames 非空）是必要的，
--   因为「空列表页签」是合法状态（见 191 行的 else 分支）。
-- 785-788：先把**所有**行的选中态清掉，再设目标行。
--   → ★★★ 「重置全部 → 设置一个」是列表选中态的标准做法，
--     比「找到旧的清掉、找到新的设上」健壮（后者漏了就双选）。
--   → 与 mapscreen 的 UpdateMapActionsDecorations 同一思想。
-- ⚠️ 785 行用 pairs 遍历 widgetTable 做重置 ——
--   数组应该用 ipairs。但这里只是遍历所有元素，顺序无关，可以。
-- ⚠️ 789-791 行 `modWidget = widgetTable[idx]` 无 nil 检查：
--   若 idx 越界则 modWidget 为 nil，790 行立即崩溃。
--   784 行只判了 `#widgetTable > 0`，**没有判 idx <= #widgetTable**。
--   → ★ 真实缺陷：任何传入越界 idx 的调用方都会崩。
--     调用方有 171/187/451/580/654/762 行，传的都是从 modnames 推出的下标，
--     安全。但 505-510 行的下载行会让 #widgetTable **大于** #modnames，
--     所以下标从 modnames 来时反而安全。属「当前不可触发」。
    local widgetTable = client_mod and self.optionwidgets_client or self.optionwidgets_server
	local modnames_versions = client_mod and self.modnames_client or self.modnames_server
    local modWidget
	if widgetTable and #widgetTable > 0 and modnames_versions and #modnames_versions > 0 then
		for k,_ in pairs(widgetTable) do
			widgetTable[k].white_bg:SetTint(1,1,1,1)
			widgetTable[k].name:SetColour(0,0,0,1)
		end
        modWidget = widgetTable[idx]
        modWidget.white_bg:SetTint(0,0,0,1)
        modWidget.name:SetColour(1,1,1,1)
    else
		self.currentmodname = nil
		return --no list to populate
    end

    local modname = modnames_versions[idx].modname
-- ★★ 797-801 行：modname 为 nil 说明这一行是「下载中」的占位行。
-- 800 行注释明说「probably in the download list」——
--   作者清楚这个分支的成因。
-- → ★★★ 「数据与视图不完全对应」时的显式处理：
--     视图有 N 行，但数据表只有 M < N 行（多出来的是下载占位）。
--     此时必须先判数据再取，否则 nil 索引。
--   → ★ 这是本文件最该学的防御：
--     凡是「列表行数 ≠ 数据项数」的地方，索引前必须判数据。
--     （对照 742 行 EnableCurrent **没有**这个防御 → 那才是缺陷。）
-- 803-807：写入 last_*_modname 供下次页签切换恢复。
    if modname == nil then
		self.currentmodname = nil
		return --no actual mod found, it's probably in the download list
	end
	self.currentmodname = modname
	if client_mod then
        self.last_client_modname = self.currentmodname
    else
        self.last_server_modname = self.currentmodname
    end

	local modinfo = KnownModIndex:GetModInfo(modname)
-- ⚠️ 810-812 行 `if modinfo == nil then return end` 会**提前返回**，
--   此时 currentmodname（802 行）已被设置，last_* 也已写。
--   → 即「选中态已改变，但详情面板没刷新」。
--   属「部分更新」状态。实践中 modinfo 不会为 nil（797 行已确保名字有效）。
-- ★ 813-819：图标有就用模组的，没有就用默认占位图。
--   → ★ 「缺省资源兜底」的标准做法，且 817 行硬编码了默认贴图。
--   → 移植时应把所有默认贴图集中管理（DST 的 templates.lua 就是干这个的）。
	if modinfo == nil then
		return
	end
    if modinfo.icon and modinfo.icon_atlas then
        self.detailimage:SetTexture(modinfo.icon_atlas, modinfo.icon)
        self.detailimage:SetSize(102, 102)
    else
        self.detailimage:SetTexture("images/ui.xml", "portrait_bg.tex")
        self.detailimage:SetSize(102, 102)
    end

    self.detailtitle:SetMultilineTruncatedString(modinfo.name or modname, 2, 270, 60, true)
-- ★★★ 双行标题的自适应布局 —— 本文件最精细的排版处理。
-- 821 行 SetMultilineTruncatedString(..., 最多2行, ...) 先渲染两行。
-- 822 行按换行符切开。
-- 823-827 若确实有第二行：
--   第一行留在 detailtitle（y 调到 176），
--   第二行放进 detailtitle2（预先建好的备用控件）。
-- 828-832 只有一行时：detailtitle 下移（160），detailtitle2 清空。
-- → ★★★ 「一个控件放不下就借第二个控件」：
--     detailtitle2 在 213 行无条件预建（213-217 行），
--     即使只有一行标题时它是空的。
--   → ★ 预建 + 按需填充，避免了「需要时才发现没有控件」的动态创建。
--   → 移植要点：**布局的极端情况要在初始化时就准备好控件**。
-- ⚠️ 但 826/830 行的 `w * .5 - 100` 用 GetRegionSize 算居中，
--   而 detailtitle 的 SetRegionSize 从未被设置（209-211 行只有 SetPosition/SetColour）。
--   → w 依赖控件默认的 region size，居中效果可能不准。
--   属「排版魔数」，不影响功能但视觉上可能有偏差。
    local nameLines = self.detailtitle:GetString():split("\n")
    if #nameLines > 1 then
        self.detailtitle:SetString(nameLines[1])
        local w = self.detailtitle:GetRegionSize()
        self.detailtitle:SetPosition(w * .5 - 100, 176)
        self.detailtitle2:SetString(nameLines[2])
    else
        local w = self.detailtitle:GetRegionSize()
        self.detailtitle:SetPosition(w * .5 - 100, 160)
        self.detailtitle2:SetString("")
    end

    self.detailauthor:SetTruncatedString(string.format(STRINGS.UI.MODSSCREEN.AUTHORBY, modinfo.author or "unknown"), 270, 88, true)
    local w, h = self.detailauthor:GetRegionSize()
    self.detailauthor:SetPosition(w * .5 - 100, 128)

    self.detaildesc:SetMultilineTruncatedString(modinfo.description or "", 11, 360, 77, true)
-- ★ 描述文本最多 11 行，截断。
-- 839-840 行用实际渲染高度反推位置：`97 - .5 * h` ——
--   → ★★★ 「控件变高时把它的**上边缘**固定住」：
--     h 越大（描述越长），位置越靠上，底部仍在同一水平线。
--   这是变高文本控件的标准布局技巧：
--     锚点在顶部则从顶部往下排；锚点在底部则要减去高度。
--     这里 97 是设计时的基准 y，减去半高做居中微调。
--   → ★★★ 移植要点：**变尺寸的控件必须重新定位，否则会跳**。
--     834-836 行的作者名用了同样的手法（835-836 行）。
    w, h = self.detaildesc:GetRegionSize()
    self.detaildesc:SetPosition(w * .5 - 187, 97 - .5 * h)

    -- if self.modlinkbutton then
-- ★★ 842-848 行是被注释掉的一整块逻辑（长注释块形式）。
--   内容：根据模组是否有 forumthread 或 workshop- 前缀，
--   决定 modlinkbutton 显示 MODLINK（跳论坛）还是 MODLINKGENERIC。
-- ⚠️ 现在这个按钮**恒定**显示 MODLINK_MOREINFO（241 行设置）。
-- → ★ 推测原因是「更多链接」需要联网查询，本地拿不到稳定的 URL。
--   → ★★★ 注释掉的分支保留价值：**说明这个按钮曾经有过更细的语义**。
--     后人若要恢复功能，知道去哪里找原始逻辑。
--   移植时保留这类「注释掉但有价值的分支」，比直接删掉好。
    --     if (modinfo.forumthread and modinfo.forumthread ~= "") or string.sub(modname, 1, 9) == "workshop-" then
    --         self.modlinkbutton:SetText(STRINGS.UI.MODSSCREEN.MODLINK)
    --     else
    --         self.modlinkbutton:SetText(STRINGS.UI.MODSSCREEN.MODLINKGENERIC)
    --     end
    -- end

    if modinfo.dst_compatible then
-- ★★★ 兼容性三态显示（兼容 / 未知 / 不兼容）。
-- 851 行的 dst_compatibility_specified == false 是关键：
--   「作者没说」与「作者说不兼容」是**不同的事**，UI 必须区分。
-- → ★★★ 「未知」是三态逻辑的经典第三态：
--     只判 dst_compatible 会把「没写」显示成「不兼容」，
--     对模组作者不公平（会被误劝退）。
--   → ★★★ 移植要点：**布尔字段表达不了三态时，用 nil 表示未知**，
--     而不是给个默认值。
-- ⚠️ 724 行的警告逻辑也用了同一个判断（`not dst_compatible or
--   dst_compatibility_specified == false`），两处一致，正确。
        if modinfo.dst_compatibility_specified == false then
            self.detailcompatibility:SetString(STRINGS.UI.MODSSCREEN.COMPATIBILITY_UNKNOWN)
        else
            self.detailcompatibility:SetString(STRINGS.UI.MODSSCREEN.COMPATIBILITY_DST)
        end
    else
        self.detailcompatibility:SetString(STRINGS.UI.MODSSCREEN.COMPATIBILITY_NONE)
    end

    if KnownModIndex:HasModConfigurationOptions(modname) then
        self:EnableConfigButton(modWidget)
    else
        self:DisableConfigButton(modWidget)
    end

	--is workshop mod and is out of date version, and check if it's updating currently
-- ══★【更新按钮的三态判定，与 updateallbutton 同构】
-- 867 过期？→ 868-876 检查是否正在下载（遍历两个下载表）
-- 877-878 正在下载 → DisableUpdateButton("updating", idx)
-- 879-881 未在下载 → EnableUpdateButton(idx)
-- 882-883 没过期 → DisableUpdateButton("uptodate", idx)
-- ⚠️⚠️【真实缺陷，已逐行核实】878/880/883 行都传了**两个参数**，
--   但函数签名是：
--     122 行 DisableUpdateButton(mode) —— 只收一个
--     136 行 EnableUpdateButton() —— 一个都不收
--   Lua 会静默丢弃多余实参，所以**不会崩**，
--   但说明作者曾打算接收 idx 却改了签名却没改调用点。
--   → ★★ 这是「重构留下的痕迹」：调用点比签名更「新」或更「旧」。
--     修正方式：要么给函数加 idx 参数（若还需要），
--     要么删掉调用点的多余实参。当前无害但误导读者。
-- ★★ 869 行 `pairs({client_dl, server_dl})` 造了个临时表来遍历两列表，
--   写法巧妙但每次调用都分配一个新表。
--   869 行位于 ShowModDetails 内，每次切换选中都会执行 → 轻微 GC 压力。
	if IsModOutOfDate( modname, modnames_versions[idx].version ) then
		local is_updating = false
		for _,dl_table in pairs( {self.modnames_client_dl, self.modnames_server_dl} ) do
			for _,v in ipairs(dl_table) do
				if v.modname == modname then
					is_updating = true
					break
				end
			end
		end
		if is_updating then
			self:DisableUpdateButton("updating", idx)
		else
			self:EnableUpdateButton(idx)
		end
	else
		self:DisableUpdateButton("uptodate", idx)
	end

    ---------------------------------------------
-- ★ 作者用分隔线加 TODO 标记「更新按钮的启用/禁用应该也放这里」。
-- ★★ 但实际上 867-884 行**已经**做了这件事（紧邻的上面）。
--   → ⚠️ 已过期的 TODO：它想做的事在它上面已经完成了。
--   推测是重构时把逻辑搬到了上面，TODO 忘了删。
-- → ★★★ 维护 TODO 的规则：**完成后立刻删**。
--   留着会误导后来人重复劳动。
    -- TODO: enable/disable update button here (similar to config button)
    ---------------------------------------------

    local modStatus = self:GetBestModStatus(modname)
-- ══★【三态配色：状态色是 UI 与玩法的唯一接口】
-- WORKING_NORMALLY → 绿（59,222,99）/255
-- DISABLED_ERROR    → 红（242,99,99）/255
-- DISABLED_MANUAL   → 灰（0.6,0.6,0.6）
-- ★★ 三个分支的代码结构完全平行：设 detailwarning + 设 widgetTable[idx].status。
--   但顺序不一致（891 分支先 String 后 Colour，898 分支先 Colour 后 String）。
--   → 无害，但说明是复制粘贴后微调过。
-- → ★★★ 「同一个状态在两个位置用同一个颜色」应抽成映射表：
--     local STATUS_COLOURS = { WORKING_NORMALLY = {59,222,99}, ... }
--   当前写法在 895/896/902/903/909/910 六处重复了同样的数字。
--   → ★ 移植时应把「状态 → 视觉」的映射数据化。
-- ⚠️ 每个分支都有 `if widgetTable then` 守卫，但 891/898/905 三个分支
--   的外层已经保证了 widgetTable 非空（784 行）。守卫冗余但无害。
-- ★ 899 行行尾注释保留了旧值 `--(242/255, 99/255, 99/255, 1)--0.9,0.3,0.3,1)`，
--   是「从旧写法迁移到除以 255 写法」的痕迹。
    if modStatus == "WORKING_NORMALLY" then
        self.detailwarning:SetString(STRINGS.UI.MODSSCREEN.WORKING_NORMALLY)
        self.detailwarning:SetColour(59/255, 222/255, 99/255, 1)
        if widgetTable then
            widgetTable[idx].status:SetString(STRINGS.UI.MODSSCREEN.STATUS.WORKING_NORMALLY)
            widgetTable[idx].status:SetColour(59/255, 222/255, 99/255, 1)
        end
    elseif modStatus == "DISABLED_ERROR" then
        self.detailwarning:SetColour(242/255, 99/255, 99/255, 1) --(242/255, 99/255, 99/255, 1)--0.9,0.3,0.3,1)
        self.detailwarning:SetString(STRINGS.UI.MODSSCREEN.DISABLED_ERROR)
        if widgetTable then
            widgetTable[idx].status:SetColour(242/255, 99/255, 99/255, 1)
            widgetTable[idx].status:SetString(STRINGS.UI.MODSSCREEN.STATUS.DISABLED_ERROR)
        end
    elseif modStatus == "DISABLED_MANUAL" then
        self.detailwarning:SetString(STRINGS.UI.MODSSCREEN.DISABLED_MANUAL)
        self.detailwarning:SetColour(.6,.6,.6,1)
        if widgetTable then
            widgetTable[idx].status:SetColour(.6,.6,.6,1)
            widgetTable[idx].status:SetString(STRINGS.UI.MODSSCREEN.STATUS.DISABLED_MANUAL)
        end
    end

    if widgetTable and KnownModIndex:IsModEnabled(modname) then
-- ★★ 启用/禁用的视觉：整行图标染色 + 勾选框换贴图。
-- 915 启用 → 原色 + checkbox_on
-- 920 禁用 → 粉红染色（1.0,0.5,0.5）+ checkbox_off
-- → ★★★ 「禁用态用红色染色而非降低透明度」是常见做法：
--     透明度会让文字也变淡（可读性差），
--     染色只影响图标，文字仍清晰。
-- ★ 917/922 行的 SetTextures 一次换了 5 张贴图（普通/高亮/禁用…），
--   → 「切状态 = 换整组贴图」是 ImageButton 的标准做法。
--   对比 mapscreen 的 SetTint —— 那里没有多态贴图，所以用染色。
-- ⚠️ 916/921 行 `if ... .checkbox then` 守卫：
--   TEMPLATES.ModListItem 一定有 checkbox（下载行 ModDLListItem 没有），
--   但这里访问的是 widgetTable[idx]，理论上 idx 可能指向下载行。
--   → 守卫是必要的，说明作者遇到过这个问题。
        widgetTable[idx].image:SetTint(1,1,1,1)
		if widgetTable[idx].checkbox then
			widgetTable[idx].checkbox:SetTextures("images/ui.xml", "checkbox_on.tex", "checkbox_on_highlight.tex", "checkbox_on_disabled.tex", nil, nil, {1,1}, {0,0})
		end
    elseif widgetTable then
        widgetTable[idx].image:SetTint(1.0,0.5,0.5,1)
		if widgetTable[idx].checkbox then
			widgetTable[idx].checkbox:SetTextures("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0})
		end
    end
end

function ModsTab:LoadModInfoPrefabs(prefabtable)
-- ══★【LoadModInfoPrefabs：运行时动态创建预制体 —— UI 与资源系统的交界】
-- 928 行遍历所有已知模组。
-- 930 行只处理有图标的（没图标的模组不占资源）。
-- 935 行 Prefab("MODSCREEN_"..modname, nil, assets, nil)：
--   → ★★★ 「为一个模组临时造一个预制体，只为加载它的图标」。
--   预制体名加 MODSCREEN_ 前缀避免与游戏预制体冲突。
-- 936 行 RegisterSinglePrefab 注册单个预制体（不走批量注册）。
-- 941 行 TheSim:LoadPrefabs 真正加载。
-- → ★★★ 这是「UI 需要展示模组资源，但模组资源不在游戏包里」的标准解法：
--   在运行时为每个模组注册一个只含图标的最小预制体。
-- → ★ 移植要点：自研游戏的 mod 资源加载必须做同样的事，
--   否则界面无法显示模组图标（只能显示占位图）。
-- ⚠️ 935 行的 modname 未做转义，若含非法字符可能导致预制体名非法。
--   实践中 Klei 的模组名有字符限制，故未暴露。
	for i,modname in ipairs(KnownModIndex:GetModNames()) do
		local info = KnownModIndex:GetModInfo(modname)
		if info.icon_atlas and info.iconpath then
			local modinfoassets = {
				Asset("ATLAS", info.icon_atlas),
				Asset("IMAGE", info.iconpath),
			}
			local prefab = Prefab("MODSCREEN_"..modname, nil, modinfoassets, nil)
			RegisterSinglePrefab( prefab )
			table.insert(prefabtable, prefab.name)
		end
	end

	TheSim:LoadPrefabs( prefabtable )
end

function ModsTab:UnloadModInfoPrefabs(prefabtable)
    TheSim:UnloadPrefabs( prefabtable )
    for k,v in pairs(prefabtable) do
        prefabtable[k] = nil
    end
end

function ModsTab:ReloadModInfoPrefabs()
-- ══★★【ReloadModInfoPrefabs：顺序敏感的引用计数操作 —— 极有价值的坑注释】
-- 952-955 行的注释是本文件最好的一段：
-- 「load before unload -- this prevents the refcounts of prefabs from
--  going 1, 0, 1 (which triggers a resource unload and crashes).
--  Instead we load first, so the refcount goes 1, 2, 1」
-- → ★★★★ 这是「资源引用计数」最经典的坑，值得完整记住：
--   引用计数降到 0 会触发资源卸载；
--   若紧接着又加载同一个资源，某些引擎会崩溃（资源已被销毁）。
--   「先加载再卸载」让计数走 1→2→1，永不触底。
-- → ★★★ 移植到自研引擎时，这是**必须复刻**的模式：
--     任何「刷新一批资源」的操作都要考虑引用计数是否会瞬时归零。
--     通用解法：先全部 AddRef，再全部 Release。
-- 956 行 oldprefabs 先取旧引用，960 行最后才替换 self.infoprefabs。
--   → 顺序正确：必须在新表建好、旧表卸掉之后才更新字段。
    -- load before unload -- this prevents the refcounts of prefabs from going 1,
    -- 0, 1 (which triggers a resource unload and crashes). Instead we load first,
    -- so the refcount goes 1, 2, 1 for existing prefabs so everything stays the
    -- same.
    local oldprefabs = self.infoprefabs
    local newprefabs = {}
    self:LoadModInfoPrefabs(newprefabs)
    self:UnloadModInfoPrefabs(oldprefabs)
    self.infoprefabs = newprefabs
end

function ModsTab:ModLinkCurrent()
    local link_fn = ModManager:GetLinkForMod(self.currentmodname)
    link_fn()
end

function ModsTab:MoreMods()
    VisitURL("https://forums.kleientertainment.com/files/")
end

function ModsTab:MoreWorkshopMods()
    VisitURL("https://steamcommunity.com/app/322330/workshop/")
end

function ModsTab:SetTopModsPanel(panel)
    self.top_mods_panel = panel

    self:DoFocusHookups()
end

function ModsTab:Cancel()
-- ══★【Cancel：完整的回滚路径，与 Apply 对称】
-- 983-986 取消周期任务（与 Apply/OnDestroy 同一段代码，出现 3 次）。
-- ⚠️ 三处相同的「取消 updatetask」代码应抽成 StopWorkshopUpdate()。
-- 988 行 FrontendUnloadMod(nil) —— **nil 表示「所有模组」**，
--   → 用 nil 做「全部」的哨兵值，是常见但不够显式的做法。
-- 989 行 RestoreCachedSaveData —— 回滚到 31 行 CacheSaveData 的快照。
--   → ★★★ 「快照 - 回滚」闭环在此完成（见 30 行分析）。
-- ★★ 988 行与 989 行的顺序：先卸代码，再回滚状态。
--   与 OnConfirmEnable（700-706）的顺序一致。
-- ⚠️ 990 行 UnloadModInfoPrefabs(self.infoprefabs) 但**没有**把
--   self.infoprefabs 置空或重置。
--   944-948 行的 UnloadModInfoPrefabs 内部会把 prefabtable 的项置 nil，
--   所以 infoprefabs 变成空表 —— 这就是「通过修改实参来清空」的隐式设计。
--   → ★ 可读性差：函数名是 Unload，却顺手清空了调用方的表。
--     应显式写 self.infoprefabs = {}。
	if self.updatetask then
		self.updatetask:Cancel()
		self.updatetask = nil
	end

    ModManager:FrontendUnloadMod(nil) -- all mods
    KnownModIndex:RestoreCachedSaveData()
    self:UnloadModInfoPrefabs(self.infoprefabs)
end

function ModsTab:Apply()
-- ★★ 994 行的注释是重要的使用契约：
-- 「After apply, the mods tab is no longer in a working state,
--  it must be restarted with :StartWorkshopUpdate()」
-- → ★★★ 「Apply 之后对象进入半失效状态，必须重新启动」——
--   这是「一次性事务对象」的用法：
--     用完即弃，不试图恢复。
-- → ★ 移植要点：当一个界面对象无法干净地回到初始态时，
--   **明确写下重建方式**，比留一堆半失效状态让人猜要好。
-- ⚠️ 但本文件没有任何地方在 Apply 后调 StartWorkshopUpdate。
--   调用方（servercreationscreen）必须负责。
--   → 又一处「跨文件的责任约定」，只能靠注释维系。
    -- Note: After "apply", the mods tab is no longer in a working state, it must be restarted with :StartWorkshopUpdate()
	if self.updatetask then
		self.updatetask:Cancel()
		self.updatetask = nil
	end

    KnownModIndex:Save()
    SaveGameIndex:SetServerEnabledMods( self.slotnum )
    SaveGameIndex:Save()
end

function ModsTab:OnDestroy()
-- ★ OnDestroy 只做两件事：停任务 + 卸预制体。
--   与 Cancel（982）的区别：没有 FrontendUnloadMod 与 RestoreCachedSaveData。
--   → ★ 语义正确：销毁不是取消，不需要回滚玩家配置。
-- ⚠️ 但 1010 行没有把 self.infoprefabs 置空（见 990 行分析）。
--   若 OnDestroy 后又有代码读它，会拿到空表（因 946-947 已清空）。
	if self.updatetask then
		self.updatetask:Cancel()
		self.updatetask = nil
	end
    self:UnloadModInfoPrefabs(self.infoprefabs)
end

function ModsTab:OnBecomeActive()
-- ══★★【OnBecomeActive：钩子由宿主手动转发（因为不是 Screen）】
-- 1014 行 StartWorkshopUpdate。
-- ⚠️ 但 StartWorkshopUpdate（261 行）**没有先取消已有任务之外的重入保护**：
--   它有（262-265 行先 Cancel），所以重复调用安全。
-- ★★★ 这个函数是「OnBecomeActive」在 Widget 上的手动实现，
--   它证明了「非 Screen 控件必须自己实现生命周期钩子」。
-- → ★★ 移植要点：**先确定你的界面是不是屏幕**。
--     是屏幕 → FrontEnd 免费给你 OnBecomeActive/OnBecomeInactive/焦点管理；
--     不是 → 全部要自己接线（本文件的 servercreationscreen 就是那个接线人）。
-- ⚠️ 没有对应的 OnBecomeInactive 实现：
--   意味着页签被隐藏时周期任务仍在跑（浪费），
--   且每次切回都会 Cancel+重建（261-268 行）。
--   → 轻微的性能与体验问题：应该加上 OnBecomeInactive 停任务。
    self:StartWorkshopUpdate()
end

function ModsTab:ConfigureSelectedMod()
-- ══★【ConfigureSelectedMod / UpdateSelectedMod：字段驱动的点击拦截范式】
-- 1018 行 `if self.modconfigable then` —— 真正的判断只有这一句。
-- ★★ 这就是「可用性字段」的意义所在：
--   按钮本身的 Select/Unselect（视觉）只是表现，
--   真正的拦截在点击回调里用字段判断。
--   → ★★★ 「视觉禁用」与「逻辑禁用」是两套机制，缺一不可：
--     只有视觉 → 手柄下仍可能触发；
--     只有逻辑 → 玩家看得见却点不动（困惑）。
--     本文件两套都有（Select/Unselect + 字段）。
-- ★ 1019 行 GetModInfo(self.currentmodname) 取了 modinfo 但没使用。
--   死代码（可能是早期版本需要它做校验）。
-- ★ 1020 行 PushScreen —— 这里才用到顶部 require 的 ModConfigurationScreen。
--   → 对比 84 行的 SetModsList 不涉及 Screen，本文件是「混合形态」：
--     自身是 Widget，内部却会 Push 别的 Screen。
    if self.modconfigable then
        local modinfo = KnownModIndex:GetModInfo(self.currentmodname)
        TheFrontEnd:PushScreen(ModConfigurationScreen(self.currentmodname, false))
    end
end

function ModsTab:UpdateSelectedMod()
    if self.modupdateable then
        TheSim:UpdateWorkshopMod(self.currentmodname)
		self:UpdateForWorkshop()
    end
end

function ModsTab:CleanAllButton()
-- ══★【CleanAllButton：最重的破坏性操作，三阶段确认】
-- 1032-1057 构造一个双按钮确认框（OK / CANCEL）。
-- 1034-1054 OK 的回调里做了五件事：
--   1036 TheSim:CleanAllMods() 清磁盘上的模组
--   1038-1039 禁用全部并保存
--   1041-1044 清空两个滚动列表
--   1045 关闭确认框
--   1047-1053 禁用菜单 → 黑场淡出 → 卸预制体 → ForceAssetReset → SimReset
-- → ★★★「淡出 → 重置 → 回到主界面」的完整流程，
--   是所有「需要完全重启前端」的操作的标准序列。
-- ★ 1047 行先 Disable 菜单，防止淡出期间玩家还能点。
--   → ★★★ 「动画期间锁输入」—— 与 scrollablelist 的 LockFocus(true) 同思想。
-- ⚠️ 1048 行的淡出回调里没有 PopScreen（确认框已在 1045 Pop 了），
--   但也没关掉承载 ModsTab 的界面 —— 靠 SimReset 整体重建。
-- ★ 1051-1052 ForceAssetReset + SimReset 是**最重的两个调用**：
--   它们会清空所有资源缓存与模拟状态。
--   → ★ 破坏性操作应有明确的注释说明「为什么必须重启」。
--     本文件的注释只说了「clean all」这个动作名，没解释后果。
    local mod_warning = PopupDialogScreen(STRINGS.UI.MODSSCREEN.CLEANALL_TITLE, STRINGS.UI.MODSSCREEN.CLEANALL_BODY,
        {
            {text=STRINGS.UI.SERVERLISTINGSCREEN.OK, cb =
                function()
                    TheSim:CleanAllMods()

                    KnownModIndex:DisableAllMods()
                    KnownModIndex:Save()

					if self.options_scroll_list_client then
						self.options_scroll_list_client:Clear()
						self.options_scroll_list_server:Clear()
					end
                    TheFrontEnd:PopScreen()

                    self.mainmenu:Disable()
                    TheFrontEnd:Fade(FADE_OUT, SCREEN_FADE_TIME, function()

                        self:UnloadModInfoPrefabs(self.infoprefabs)
                        ForceAssetReset()
                        SimReset()
                    end)
                end},
            {text=STRINGS.UI.SERVERLISTINGSCREEN.CANCEL, cb = function() TheFrontEnd:PopScreen() end}
        }
    )
    TheFrontEnd:PushScreen( mod_warning )
end

function ModsTab:UpdateAllButton(force)
-- ══★★【UpdateAllButton：同一条逻辑的两份拷贝（1062-1077 与 1083-1097）】
-- 1062 行 force=true 分支：直接执行更新，不弹确认框。
-- 1078 行 else 分支：弹确认框，OK 回调里执行同样的循环。
-- ⚠️⚠️【结构缺陷，已核实】两个分支里的「遍历并更新」代码**完全相同**
--   （1064-1069 与 1084-1089、1071-1076 与 1091-1096），
--   共约 24 行复制了两遍，连 UpdateForWorkshop 的调用都重复。
-- → ★★★ 正确写法：抽一个 UpdateAllWorkshopMods()，
--   两个分支都调它。这与 384/513 那 120 行重复是同一类问题。
--   → 本文件共有 3 处大段复制（384/513、1064/1084、1071/1091）。
-- ★★ 1065 行的判断条件与 IsModOutOfDate（304 行）**等价但写法不同**：
--   `IsWorkshopMod(x) and version ~= "" and version ~= 已知版本`
--   与 IsModOutOfDate 的三个条件完全一致。
--   → ★★★ 已有现成的函数却不用，在两处重新实现了一遍。
--     这是最典型的「重复逻辑导致规则漂移」隐患：
--     若 IsModOutOfDate 增加一个条件，这两处不会跟着更新。
-- ⚠️ 1069/1076 行没有 `break`（虽然遍历全部是对的，因为要更新多个）。
--   这里确实需要遍历全部，正确。
    if force then
		if self.modnames_client ~= nil then
			for _,name_version in pairs(self.modnames_client) do
				if IsWorkshopMod(name_version.modname) and name_version.version ~= "" and name_version.version ~= KnownModIndex:GetModInfo(name_version.modname).version then
					TheSim:UpdateWorkshopMod(name_version.modname)
				end
			end
		end
		if self.modnames_server ~= nil then
			for _,name_version in pairs(self.modnames_server) do
				if IsWorkshopMod(name_version.modname) and name_version.version ~= "" and name_version.version ~= KnownModIndex:GetModInfo(name_version.modname).version then
					TheSim:UpdateWorkshopMod(name_version.modname)
				end
			end
		end
        self:UpdateForWorkshop()
	elseif self.updateallenabled then
		local mod_warning = PopupDialogScreen(STRINGS.UI.MODSSCREEN.UPDATEALL_TITLE, STRINGS.UI.MODSSCREEN.UPDATEALL_BODY,
			{
				{text=STRINGS.UI.SERVERLISTINGSCREEN.OK, cb =
					function()
						if self.modnames_client ~= nil then
							for _,name_version in pairs(self.modnames_client) do
								if IsWorkshopMod(name_version.modname) and name_version.version ~= "" and name_version.version ~= KnownModIndex:GetModInfo(name_version.modname).version then
									TheSim:UpdateWorkshopMod(name_version.modname)
								end
							end
						end
						if self.modnames_server ~= nil then
							for _,name_version in pairs(self.modnames_server) do
								if IsWorkshopMod(name_version.modname) and name_version.version ~= "" and name_version.version ~= KnownModIndex:GetModInfo(name_version.modname).version then
									TheSim:UpdateWorkshopMod(name_version.modname)
								end
							end
						end
						self:UpdateForWorkshop()

						TheFrontEnd:PopScreen()
					end},
				{text=STRINGS.UI.SERVERLISTINGSCREEN.CANCEL, cb = function() TheFrontEnd:PopScreen() end}
			}
		)
		TheFrontEnd:PushScreen( mod_warning )
	end
end

function ModsTab:SetSaveSlot(slotnum, fromDelete)
-- ══★★【SetSaveSlot：切换存档槽 = 换一整套模组配置】
-- 1109 行早退：`not fromDelete and slotnum == self.slotnum`。
--   → ★★ 「切到同一个槽则什么都不做」的幂等保护，
--     但 fromDelete=true 时**强制执行** ——
--     因为删除存档后必须重建配置。
--   → ★ 这是「同一函数服务两个不同场景」的常见设计，
--     用布尔参数区分。代价是语义不清（应拆成两个函数）。
-- 1111 行先全量卸载所有模组。
-- 1114 行 LoadServerEnabledModsFromSlot 载入目标槽的配置。
-- 1116 行 UpdateForWorkshop(true) —— **force_refresh = true**：
--   → ★★ 因为模组集合完全变了，必须跳过「无变化早退」的优化。
--     这是「缓存失效」的正确处理：数据源换了，缓存的比较基准也换了。
-- 1118-1120 逐个 FrontendLoadMod 重新加载。
-- → ★★★ 完整的事务：卸载全部 → 换配置 → 刷新界面 → 重新加载。
--   顺序正确：先卸载（避免同时加载两套导致冲突）。
    if not fromDelete and slotnum == self.slotnum then return end

    ModManager:FrontendUnloadMod(nil) -- all mods

    self.slotnum = slotnum
    SaveGameIndex:LoadServerEnabledModsFromSlot( self.slotnum )

    self:UpdateForWorkshop(true)

    for i, name in ipairs(ModManager:GetEnabledServerModNames()) do
        ModManager:FrontendLoadMod(name)
    end
end

function ModsTab:GetNumberOfModsEnabled()
    return #ModManager:GetEnabledServerModNames()
end

function ModsTab:DoFocusHookups()
-- ══★★★【DoFocusHookups：整个页签的焦点导航图（43 行）】
-- 本文件被调用 12+ 次（92/107/122/136/159/175/679/979 等），
--   每次状态变化后重建。
-- ★★ 1128-1132 行 tomiddlecol 是一个**动态目标**函数：
--   返回当前页签对应的列表控件。
--   → ★★★ 「焦点目标可以是函数」是本文件的关键设计：
--     1134/1135/1154/1162 行把它作为 SetFocusChangeDir 的目标。
--     Widget:SetFocusChangeDir 支持 FunctionOrValue（widget.lua:81），
--     所以目标在**按下的那一刻**才求值。
--   → ★★★ 这解决了「两个列表二选一，但焦点连线要在两个按钮上各写一遍」的问题。
--     移植时若焦点系统不支持「函数目标」，
--     就只能为每个页签各建一套连线，并在切页签时重建。
-- ★ 1131 行的 `or nil` 是冗余（and/or 链已返回 nil）。
--
-- ★★ 1134-1163 行的连线构成完整的导航图：
--   导航栏 servermods ←→ clientmods（MOVE_DOWN 上下）
--   导航栏 → 列表（MOVE_RIGHT，动态目标）
--   列表 → modconfigbutton（MOVE_RIGHT）
--   列表 → servermodsbutton（MOVE_LEFT）
--   cleanall ↔ updateall（左右）
--   cleanall/updateall ↔ clientmodsbutton（上下）
--   modconfig → modupdate → modlink（横排）
-- → ★★★ 「焦点图 = 有向图」的思维：
--   每个节点声明「我朝某方向走到谁」，而不是维护一张全局表。
--   好处：局部、可增量更新（只改受影响的边）。
-- ⚠️ 代价：**必须记得在数据/控件变化后重建**，否则边会指向死控件。
--   本文件靠「到处调 DoFocusHookups」来保证，属于「用纪律换简洁」的方案。
-- ⚠️ 1134-1135 行两个按钮都连 MOVE_RIGHT 到 tomiddlecol，
--   但 tomiddlecol 依赖 currentmodtype —— 所以从 servermods 按右键
--   会跳到 server 列表（因为 currentmodtype 是 server），
--   即使当前高亮的是 clientmodsbutton 也不影响。
--   行为合理（跳到当前页签的列表），但玩家可能预期「从哪个按钮来就跳到哪个列表」。
    local function tomiddlecol()
        return (self.currentmodtype == "client" and self.options_scroll_list_client)
            or (self.currentmodtype == "server" and self.options_scroll_list_server)
            or nil
	end

    self.servermodsbutton:SetFocusChangeDir(MOVE_RIGHT, tomiddlecol)
    self.clientmodsbutton:SetFocusChangeDir(MOVE_RIGHT, tomiddlecol)
    self.servermodsbutton:SetFocusChangeDir(MOVE_DOWN, self.clientmodsbutton)
    self.clientmodsbutton:SetFocusChangeDir(MOVE_DOWN, self.cleanallbutton)
    self.clientmodsbutton:SetFocusChangeDir(MOVE_UP, self.servermodsbutton)

    if self.options_scroll_list_client then
        self.options_scroll_list_client:SetFocusChangeDir(MOVE_RIGHT, self.modconfigbutton)
        self.options_scroll_list_client:SetFocusChangeDir(MOVE_LEFT, self.servermodsbutton)
    end

    if self.options_scroll_list_server then
        self.options_scroll_list_server:SetFocusChangeDir(MOVE_RIGHT, self.modconfigbutton)
        self.options_scroll_list_server:SetFocusChangeDir(MOVE_LEFT, self.servermodsbutton)
    end

    self.cleanallbutton:SetFocusChangeDir(MOVE_UP, self.clientmodsbutton)
    self.updateallbutton:SetFocusChangeDir(MOVE_UP, self.clientmodsbutton)

    self.cleanallbutton:SetFocusChangeDir(MOVE_RIGHT, self.updateallbutton)
    self.updateallbutton:SetFocusChangeDir(MOVE_RIGHT, tomiddlecol)
    self.updateallbutton:SetFocusChangeDir(MOVE_LEFT, self.cleanallbutton)

    self.modlinkbutton:SetFocusChangeDir(MOVE_LEFT, self.modupdatebutton)

    self.modupdatebutton:SetFocusChangeDir(MOVE_RIGHT, self.modlinkbutton)
    self.modupdatebutton:SetFocusChangeDir(MOVE_LEFT, self.modconfigbutton)

    self.modconfigbutton:SetFocusChangeDir(MOVE_LEFT, tomiddlecol)
    self.modconfigbutton:SetFocusChangeDir(MOVE_RIGHT, self.modupdatebutton)

    if self.top_mods_panel ~= nil then
        self.top_mods_panel:SetFocusChangeDir(MOVE_LEFT, self.modlinkbutton)
        self.modlinkbutton:SetFocusChangeDir(MOVE_RIGHT, self.top_mods_panel.morebutton)
    end
end

return ModsTab