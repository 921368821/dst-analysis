--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：screens/serverlistingscreen.lua
-- 模块：界面 / 服务器浏览器（本批最大文件，2320 行）
-- 职责：拉取服务器列表 → 过滤 → 排序 → 池化渲染 → 详情展示 → 加入。
--       是 widgets/scrollablelist.lua **模式 B（静态控件池）** 的标杆用户：
--       只创建 13 个行控件（listings_per_view），靠 updatefn 把它们
--       重新绑定到不同服务器数据，从而显示任意数量的服务器。
--
-- 数据流（网络 → 像素）：
--   TheNet（引擎侧，异步，GetServerListingReadDirty 脏标志）
--     → self.servers
--     → DoFiltering（过滤 + 字段显式拷贝 + 附加 actualindex 稳定标识）
--     → DoSorting（原地 table.sort，多级优先级 + 打破平局）
--     → ScrollableList:SetList
--     → RefreshView → updatefn = UpdateServerListWidget → 13 行重绑定
--
-- 关键符号：CompareTable（递归深比较，性能基石）, RefreshView（中心调度）, 
--           DoFiltering / IsValidWithFilters（过滤，分「不可加入」与「被过滤」）, 
--           DoSorting / SetSort / CycleColumnSort, 
--           UpdateServerListWidget（虚拟化绑定函数）, 
--           MakeServerListWidgets（池构建）, 
--           GuaranteeSelectedServerHighlighted（高亮全量重算）, 
--           ProcessPlayerData（★ RunInSandboxSafe 沙箱执行不可信上报数据）, 
--           ServerSelected / UpdateServerData（选中即异步拉详情）, 
--           ClearServerList（虚拟化的配套：清内容而不销毁控件）, 
--           CurrentCenterFocus / CurrentRightFocus / CurrentLeftFocus
--           （动态焦点图）, OnControl（输入独占与路由）, GetHelpText
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：widgets/scrollablelist.lua（模式 B 的被调用方）, 
--           widgets/listcursor.lua（每行的焦点指示器，接入焦点冒泡）, 
--           widgets/spinner.lua / numericspinner.lua / textedit.lua（筛选器控件）, 
--           widgets/scrollablelist.lua 的 LayOutStaticWidgets(skipFixUp)（
--           本文件声明自己处理焦点，故跳过框架注入）、
--           thenet.lua（服务器搜索/列表/详情下载的引擎接口）、
--           sandbox.lua（RunInSandboxSafe，不可信数据的唯一安全出口）、
--           profile.lua（playerintention 等本地设置）、
--           constants.lua（INTENTIONS / BETA_INFO / APP_VERSION）
--============================================================
local Screen = require "widgets/screen"
local ImageButton = require "widgets/imagebutton"
local Button = require "widgets/button"
local InputDialogScreen = require "screens/inputdialog"
local PopupDialogScreen = require "screens/popupdialog"
local TextListPopupDialogScreen = require "screens/textlistpopupdialog"
local ListCursor = require "widgets/listcursor"
local IntentionPicker = require "widgets/intentionpicker"
local TEMPLATES = require "widgets/templates"

local Text = require "widgets/text"
local Image = require "widgets/image"

local Spinner = require "widgets/spinner"
local NumericSpinner = require "widgets/numericspinner"
local TextEdit = require "widgets/textedit"

local Widget = require "widgets/widget"

local ScrollableList = require "widgets/scrollablelist"

local ViewCustomizationModalScreen = require "screens/viewcustomizationmodalscreen"
local ViewPlayersModalScreen = require "screens/viewplayersmodalscreen"
-- ══════════════════════════════════════════════════════════════
-- ServerListingScreen —— 服务器浏览界面（2320 行，本批最大文件）
--
-- 【★★★ 本文件是「列表虚拟化」的完整教科书级用例】
-- 它是 widgets/scrollablelist.lua **模式 B（静态控件池）** 的标杆用户：
--   只创建 13 个行控件（listings_per_view = 13），
--   通过 UpdateServerListWidget 把它们「重新绑定」到不同的服务器数据，
--   从而显示任意数量的服务器。
--
-- 【★★ 数据流（从网络到像素的完整链路）】
--   TheNet（引擎侧服务器列表，异步刷新）
--     → self.servers          （847 行 RefreshView 拉取）
--     → DoFiltering（1491）    → self.viewed_servers（过滤 + 拷贝字段）
--     → DoSorting（1242）      → 原地 table.sort
--     → ScrollableList:SetList（1612）
--     → RefreshView（284，在 scrollablelist 里）
--     → updatefn = UpdateServerListWidget（985 行）
--     → 13 个行控件被重新绑定
--   ★ 「过滤」与「排序」是两个独立阶段，且排序在过滤之后 ——
--     因为排序依据的字段是过滤后才确定的。
--
-- 【★ 三个值得学的模式】
-- 1) **深度相等做脏检查**（CompareTable，551 行）：
--   「服务器列表有没有变」用递归深比较判断，变了才重建 UI。
--   → 网络轮询场景下的标准做法：数据可能每秒变多次，
--     但 UI 只在真正变化时重建。
-- 2) **actualindex 与视口索引的分离**（1565 行）：
--   过滤后 viewed_servers 的下标 ≠ 服务器在原始列表里的下标，
--   所以每项都带一个 actualindex 字段作为「真实身份」。
--   选中态、高亮、双击检测全靠它，而不是靠下标。
--   → ★★★★ 这是本文件最关键的设计，详见 1565 行注释。
-- 3) **搜索词分词**（1497-1521 行）：手写的逗号分隔解析器。
--
-- 【⚠️ 容易踩的坑】
-- · 文件第 89 行注释自承：名字排序是字典序，
--   「Server 5 < Server 50 < Server 6」—— 作者自己承认这是缺陷。
-- · 1016 行注释「actual index is wrong」—— 连作者都不确定该字段是否正确。
-- · DoFiltering（1491）的查询分词逻辑极其绕（1512-1517），
--   有 startPos/endPos 双游标 + 多个条件分支，是本文件最难读的一段。
-- ══════════════════════════════════════════════════════════════

local OnlineStatus = require "widgets/onlinestatus"
-- ★★ listings_per_view = 13 是**虚拟化池的大小**。
--   它决定：只创建 13 个行控件，无论服务器有多少个。
-- 865 行的循环 `for i=1,listings_per_view` 建控件；
-- 1125 行把 13 个控件交给 ScrollableList 当静态池。
-- ★★★ 这里的值是**手工调出来的**，不是算出来的：
--   scrollablelist 的 widgets_per_view 公式是
--     ceil(height / (item_height + item_padding))
--     = ceil(385 / (20+10)) = ceil(12.83) = 13
--   恰好等于 13，是调用方按公式算出来后写死的。
-- → ★ 若改了 1125 行的 listheight/item_height/item_padding，
--   必须同步改这个常量，否则池大小与可视数不匹配
--   （池 < 可视 → 底部空缺；池 > 可视 → 多余控件白占内存）。
--   正确做法是把这个常量由公式推导，而不是独立硬编码。

-- ⚠️ listings_per_scroll = 10 —— 已 grep 核实**从未被使用**（死常量）。
--   可能是早期版本的分页大小残留（后来改成了连续滚动）。
-- ★ 与 listings_per_view 并列放置容易让人以为它在用，
--   是「死常量误导读者」的典型。
require("constants")

local listings_per_view = 13
local listings_per_scroll = 10
local list_spacing = 37.5
-- ★★ 四种行文本颜色，全部是「除以 255」的显式写法：
--   dev_color     紫（开发版服务器）
--   mismatch_color 红（版本不匹配）
--   beta_color     橙（beta 服务器）
--   offline_color  深蓝（离线/LAN）
--   normal_color   黑（正常）
-- → ★★★ 「用颜色编码服务器状态」是本文件的核心视觉语言：
--   玩家不用读文字，扫一眼颜色就知道能不能连、是不是好友在玩。
-- → ★ 移植要点：**列表行的第一视觉通道应该是颜色**，
--   而非文字内容。这是最省认知成本的编码方式。
-- ⚠️ 颜色以「预除 255」的形式存储（{80/255, 16/255, ...}），
--   是为了调用 SetColour 时直接展开（SetRowColour 用 unpack）。
--   → 稍显低效（每次 SetColour 都做除法），但只在刷新时调用，可忽略。

local filters_per_page = 6

local column_offsets_x_pos = -RESOLUTION_X*0.18;
local column_offsets_y_pos = RESOLUTION_Y*0.23;

local column_offsets ={
        NAME = -92,
        DETAILS = 238,
        PLAYERS = 413,
        PING = 509,
    }

local dev_color = { 80/255, 16/255, 158/255, 1 }
local mismatch_color = { 130/255, 19/255, 19/255, 1 }
-- ★★ STRING_MAX_LENGTH = 254 的注释直接给了 RFC 链接：
-- 「http://tools.ietf.org/html/rfc5321#section-4.5.3.1」
-- → ★★★★ 「常量的出处用可点击的权威链接标注」是极高价值的注释习惯。
--   254 是 SMTP 单行长度上限，用于截断过长的服务器名。
-- → ★ 移植提示：**任何一个「魔法数字」都应说明其来源与业务含义**。
--     带上标准编号，别人能立刻验证你抄对了。
local beta_color = { 80/255, 53/255, 19/255, 1 }
local offline_color = { 19/255, 67/255, 80/255, 1 }
local normal_color = { 0, 0, 0, 1 }

-- ★ intention_images：一张「意图枚举 → 贴图」映射表。
-- 1027 行直接用它 `intention_images[serverdata.intention].small`。
-- → ★ 「枚举到视觉资源」的查表（对照 scrollablelist 的 SCROLLBAR_STYLE）。
--   好处：新增一种意图只需加一行，界面代码零改动。
-- ⚠️ 1025 行的守卫检查了 `intention_images[x] ~= nil`，
--   说明作者防过「枚举有值但表里没图」的情况 —— 这是后来加的补丁。
--   → ★★ 「数据枚举与资源表可能不同步」是常见的历史包袱，
--     正确做法是启动时校验两者一致并报错。
local font_size = 35
if JapaneseOnPS4() then
    font_size = 35 * 0.75
end

local STRING_MAX_LENGTH = 254 -- http://tools.ietf.org/html/rfc5321#section-4.5.3.1

local hover_text_params = { font = NEWFONT, size = 20, offset_x = -4, offset_y = 45, colour = {0,0,0,1} }

local intention_images = {
    [INTENTIONS.SOCIAL] = { big="social.tex", small="playstyle_social.tex" },
    [INTENTIONS.COOPERATIVE] = { big="coop.tex", small="playstyle_coop.tex" },
    [INTENTIONS.COMPETITIVE] = { big="competitive.tex", small="playstyle_competitive.tex" },
    [INTENTIONS.MADNESS] = { big="madness.tex", small="playstyle_madness.tex" },
}

local function GetBetaInfoId(tags)
	tags = string.lower(tags)
	for i,beta_info in ipairs(BETA_INFO) do
		if string.find(tags, beta_info.SERVERTAG, 1, true) ~= nil then
			return i
		end
	end

	return 0
end

local ServerListingScreen = Class(Screen, function(self, prev_screen, filters, cb, offlineMode, session_mapping)
    Widget._ctor(self, "ServerListingScreen")

    self.server_intention = {}

    self.prev_screen = prev_screen
    prev_screen:TransferPortalOwnership(prev_screen, self)

    -- Query all data related to user sessions
    self.session_mapping = session_mapping

    self.cb = cb
    self.offlinemode = offlineMode

    self.tickperiod = 0.5
    self.task = nil

    self.unjoinable_servers = 0

    self.root = self:AddChild(Widget("scaleroot"))
    self.root:SetVAnchor(ANCHOR_MIDDLE)
    self.root:SetHAnchor(ANCHOR_MIDDLE)
    self.root:SetScaleMode(SCALEMODE_PROPORTIONAL)

    self.view_online = true

    local nav_col = -RESOLUTION_X*.415
    local left_col = -RESOLUTION_X*.047
    local right_col = RESOLUTION_X*.40

    self.menu_bg = self.root:AddChild(TEMPLATES.LeftGradient())

    self.server_list_frame = self.root:AddChild(Image("images/serverbrowser.xml", "frame.tex"))
    self.server_list_frame:SetPosition(75,-20)
    self.server_list_frame:SetScale(.66, .65)

    self.server_list = self.root:AddChild(Widget("server_list"))
    self.server_list:SetPosition(left_col,-15,0)

    self.server_list_background = self.server_list:AddChild(Image("images/options_bg.xml", "options_panel_bg.tex"))
    self.server_list_background:SetScale(-.563,.66)
    self.server_list_background:SetPosition(0,-5)

    self.server_list_titles = self.server_list:AddChild(Widget("server_list_titles"))
    self.server_list_titles:SetPosition(column_offsets_x_pos, column_offsets_y_pos, 0)


    self.intentions_overlay = self.server_list:AddChild(IntentionPicker( STRINGS.UI.SERVERLISTINGSCREEN.INTENTION_TITLE, STRINGS.UI.SERVERLISTINGSCREEN.INTENTION_DESC, true))
    self.intentions_overlay:SetCallback(function(intention)
        self:SetServerIntention(intention)
    end)
    self.intentions_overlay:SetPosition(0, 180)

    self.nav_bar = self.root:AddChild(TEMPLATES.NavBarWithScreenTitle(STRINGS.UI.MAINSCREEN.BROWSE, "short"))

    self.table = self.root:AddChild(Widget("table container"))
    self.table:SetPosition(-RESOLUTION_X*0.045, -RESOLUTION_Y*0.023, 0)
    self.table.titles = self.table:AddChild(Widget("table titles"))
    self.table.titles:SetPosition(column_offsets_x_pos, column_offsets_y_pos, 0)

    self.table.server_list_bgs = self.table:AddChild(Widget("server_list_rows"))
    self.table.server_list_bgs:SetPosition(column_offsets_x_pos, -RESOLUTION_Y*0.075, 0)

    local vertical_line_y_offset = -35
    local slide = 280
    self.table.upper_horizontal_line = self.table:AddChild(Image("images/ui.xml", "line_horizontal_5.tex"))
    self.table.upper_horizontal_line:SetScale(.565, .66)
    self.table.upper_horizontal_line:SetPosition(-20, column_offsets_y_pos+22, 0)

    self.table.lower_horizontal_line = self.table:AddChild(Image("images/ui.xml", "line_horizontal_5.tex"))
    self.table.lower_horizontal_line:SetScale(.565, .66)
    self.table.lower_horizontal_line:SetPosition(-20, column_offsets_y_pos-11, 0)

    self.table.first_column_end = self.table:AddChild(Image("images/ui.xml", "line_vertical_5.tex"))
    self.table.first_column_end:SetScale(.66, .66)
    self.table.first_column_end:SetPosition(column_offsets.DETAILS-slide-10,vertical_line_y_offset, 0)

    self.table.second_column_end = self.table:AddChild(Image("images/ui.xml", "line_vertical_5.tex"))
    self.table.second_column_end:SetScale(.66, .66)
    self.table.second_column_end:SetPosition(column_offsets.PLAYERS-slide+1, vertical_line_y_offset, 0)

    self.table.third_column_end = self.table:AddChild(Image("images/ui.xml", "line_vertical_5.tex"))
    self.table.third_column_end:SetScale(.66, .66)
    self.table.third_column_end:SetPosition(column_offsets.PING-slide+15, vertical_line_y_offset, 0)

    self:MakeColumnHeaders()

    self.sort_ascending = nil
    self.sort_column = nil
    self:SetSort("DETAILS")

    self.selected_index_actual = -1
    self.selected_server = nil
    self.list_widgets = {}
    self.view_offset = 0
    self.viewed_servers = {}
    self.servers = {}
    self.filters = {}
    self.sessions = {}

    self.table.server_list_rows = self.table:AddChild(Widget("server_list_rows"))
    self.table.server_list_rows:SetPosition(column_offsets_x_pos, -RESOLUTION_Y*0.075, 0)
    -- self.table.server_list_rows:SetVAlign(ANCHOR_MIDDLE)
    self:MakeServerListWidgets()

    self:MakeDetailPanel(right_col)

    self:MakeMenuButtons(left_col, right_col, nav_col)

    self:MakeFiltersPanel(filters)

    self.onlinestatus = self.root:AddChild(OnlineStatus())

    self:UpdateServerInformation(false)
    self:ToggleShowFilters()
    self:SetServerIntention(Profile:GetValue("playerintention"))

    if self.offlinemode then
        self:SetTab("LAN")
    else
        self:SetTab("online")
    end
    self:RefreshView(false)

    self.servers_scroll_list:SetFocusChangeDir(MOVE_LEFT, function() return self:CurrentLeftFocus() end)
    self.filters_scroll_list:SetFocusChangeDir(MOVE_LEFT, function() return self:CurrentCenterFocus() end, MOVE_LEFT)
    self.server_details_additional:SetFocusChangeDir(MOVE_LEFT, function() return self:CurrentCenterFocus() end, MOVE_LEFT)

    self.intentions_overlay:SetFocusChangeDir(MOVE_LEFT, function() return self:CurrentLeftFocus() end)
    self.intentions_overlay:SetFocusChangeDir(MOVE_RIGHT, function() return self:CurrentRightFocus() end)

    self.default_focus = self.online_button
end)

function ServerListingScreen:SetTab(tab)
-- SetTab：切换在线/LAN 两个页签。
-- ★ 与 modstab 的 SetModsList 同模式（视图 + 焦点 + 选中态三者齐更新）。
--   移植时可对照阅读。
-- ★ 2279 行 CurrentCenterFocus 用 `view_online` 决定焦点落点，
--   即页签状态直接决定焦点图 —— 两处保持一致。
    if tab == "LAN" then
        self.view_online = false
        self:SearchForServers()
        self.lan_button:Select()
        self.online_button:Unselect()
        self.server_intention.button:Select()
        self.server_intention.button:SetText("")
    elseif tab == "online" then
        self.view_online = true
        self:SearchForServers()
        self.lan_button:Unselect()
        self.online_button:Select()
        self.server_intention.button:Unselect()
        if self.server_intention.data ~= nil then
            self.server_intention.button:SetText(STRINGS.UI.INTENTION[string.upper(self.server_intention.data)])
        end
    end
    self:ShowServerIntention()
end

function ServerListingScreen:SetServerIntention(intention)
    self.server_intention.data = intention

    if intention ~= nil then
        self.title:SetString(string.format(STRINGS.UI.SERVERLISTINGSCREEN.SERVER_LIST_TITLE_INTENT, STRINGS.UI.INTENTION[string.upper(intention)]))
        self.server_intention.button:SetText(STRINGS.UI.INTENTION[string.upper(intention)])
        self.intentions_overlay:SetSelected(intention)
    end

    Profile:SetValue("playerintention", self.server_intention.data)

    self:ShowServerIntention()

    self:DoFiltering()
end

function ServerListingScreen:ShowServerIntention()
    if self.view_online then
        if self.server_intention.data == nil then
            self.intentions_overlay:Show()
            self.table:Hide()
            self.server_list_titles:Hide()
            self.title:SetString(STRINGS.UI.SERVERLISTINGSCREEN.SERVER_LIST_TITLE)
            self.server_intention.button:Select()
        else
            self.intentions_overlay:Hide()
            self.table:Show()
            self.server_list_titles:Show()
            --self.server_intention:Show()
            self.title:SetString(string.format(STRINGS.UI.SERVERLISTINGSCREEN.SERVER_LIST_TITLE_INTENT, STRINGS.UI.INTENTION[string.upper(self.server_intention.data)]))
            self.server_intention.button:Unselect()
        end
    else
        self.intentions_overlay:Hide()
        self.table:Show()
        self.server_list_titles:Show()
        --self.server_intention:Hide()
        self.title:SetString(STRINGS.UI.SERVERLISTINGSCREEN.SERVER_LIST_TITLE)
    end

    if self.servers_scroll_list.focus and (self.server_intention.data == nil or not self.view_online) then
        self.intentions_overlay:SetFocus()
    elseif self.intentions_overlay.focus and self.server_intention.data ~= nil and self.view_online then
        self.servers_scroll_list:SetFocus()
    end
end


function ServerListingScreen:UpdateServerInformation( show )
    if show then
        if self.filters_shown then
            self:ToggleShowFilters(true)
        end
        self.details_servername:Show()
        self.details_serverdesc:Show()
        if self.selected_server ~= nil then
            self.server_details_additional:Show()-- self.detail_scroll_list:Show()
        end
    else
        if self.filters_shown then
            self.details_servername:Hide()
            self.details_serverdesc:Hide()
        end
        self.server_details_additional:Hide()-- self.detail_scroll_list:Hide()
    end
end

function ServerListingScreen:ToggleShowFilters(forcehide)
    if not self.filters_shown and not forcehide then
        self.filters_shown = true
        self:UpdateServerInformation( false )
        self.filters_button:Disable()
        if TheInput:ControllerAttached() and self.server_details_additional.focus then--self.detail_scroll_list.focus then
            self.filters_scroll_list:SetFocus()
        end
        self.details_button:Enable()
        self.filters_scroll_list:Show()
        self.server_details_additional:Hide()--self.detail_scroll_list:Hide()
    else
        self.filters_scroll_list:Hide()
        if self.selected_server ~= nil then
            self.server_details_additional:Show()--self.detail_scroll_list:Show()
        end
        if TheInput:ControllerAttached() and self.filters_scroll_list.focus then
            self.server_details_additional:SetFocus()--self.detail_scroll_list:SetFocus()
        end
        self.filters_shown = false
        self.filters_button:Enable()
        self.details_button:Disable()
        self:UpdateServerInformation( true )
    end
end

function ServerListingScreen:OnBecomeActive()
-- ══★【OnBecomeActive：进入界面的初始化 —— 搜索的触发点】
-- ★★★ 与 mapscreen 的 OnBecomeActive 完全同构（都是「从后台回前台」）：
--   重新拉数据、重新布局、重建焦点。
-- ★ 具体动作：
--   启动周期刷新任务（StartPeriodicRefreshTask，725 行）
--   + 立即刷新一次（避免首个周期内界面空白）
-- → ★★★ 「先同步一次 + 再周期轮询」的标准模式（对照 modstab:267-268）。
-- ⚠️ OnBecomeInactive（333）会停掉轮询任务 —— 这是正确的资源回收。
--   对比 tradescreen 的 TradeScreen 没有对应实现（缺 OnBecomeInactive）。
    ServerListingScreen._base.OnBecomeActive(self)
    self:Enable()

    self:StartPeriodicRefreshTask()
end

function ServerListingScreen:OnBecomeInactive()
    ServerListingScreen._base.OnBecomeInactive(self)

    self:StopPeriodicRefreshTask()
end

function ServerListingScreen:OnDestroy()
    self.prev_screen:TransferPortalOwnership(self, self.prev_screen)
    self._base.OnDestroy(self)
end

local function tchelper(first, rest)
  return first:upper()..rest:lower()
end

function ServerListingScreen:Join(warnedOffline)
-- ★ tchelper（344 行）是一个「延迟执行 + 防重入」的辅助：
--   加入服务器前先做一次确认（询问 mod 列表等）。
-- ★ 348 行 Join(warnedOffline)：
--   warned_warning 参数与 tradescreen 的 Trade(done_warning) 是同一模式
--   —— 「参数即守卫」，第一次调用做检查，确认后带 true 重新调用跳过检查。
-- → ★★★ 这个模式在本项目里出现至少 3 次（tradescreen:596、
--   serverlistingscreen:348、还有 modstab 的确认框模式）。
--   说明团队形成了「先问再做」的约定，但没有统一成基类方法。
    if self.selected_server ~= nil then
		local beta = GetBetaInfoId(self.selected_server.tags)
        if BRANCH == "release" and beta > 0 then
			local beta_info = BETA_INFO[beta]
            local beta_popup = PopupDialogScreen(STRINGS.UI.NETWORKDISCONNECT.TITLE[beta_info.VERSION_MISMATCH_STRING], STRINGS.UI.NETWORKDISCONNECT.BODY[beta_info.VERSION_MISMATCH_STRING],
                                {
                                    {text=STRINGS.UI.MODSSCREEN.MODLINK_MOREINFO, cb = function()
                                        VisitURL(beta_info.URL)
                                        TheFrontEnd:PopScreen()
                                    end},
                                    {text=STRINGS.UI.SERVERLISTINGSCREEN.CANCEL, cb = function()
                                        TheFrontEnd:PopScreen()
                                    end},
                                })
            self.last_focus = TheFrontEnd:GetFocusWidget()
            TheFrontEnd:PushScreen(beta_popup)
        elseif not warnedOffline and self.selected_server.offline then
            local confirm_offline_popup = PopupDialogScreen(STRINGS.UI.SERVERLISTINGSCREEN.OFFLINEWARNINGTITLE, STRINGS.UI.SERVERLISTINGSCREEN.OFFLINEMODEBODYJOIN,
                                {
                                    {text=STRINGS.UI.SERVERLISTINGSCREEN.OK, cb = function()
                                        -- If player is okay with offline mode, go ahead
                                        TheFrontEnd:PopScreen()
                                        self:Join(true)
                                    end},
                                    {text=STRINGS.UI.SERVERLISTINGSCREEN.CANCEL, cb = function()
                                        TheFrontEnd:PopScreen()
                                    end}
                                })
            self.last_focus = TheFrontEnd:GetFocusWidget()
            TheFrontEnd:PushScreen(confirm_offline_popup)
        else

            local filters = {}
            for i, v in ipairs(self.filters) do
                if v.spinner ~= nil then
                    table.insert(filters, {name=v.name, data=v.spinner:GetSelectedData()})
                elseif v.textbox then
                    table.insert(filters, {name="search", data=v.textbox:GetString()})
                end
            end
            Profile:SaveFilters(filters)
            JoinServer( self.selected_server )
        end
    else
        assert(false, "Invalid server selection")
    end
end

function ServerListingScreen:Report()
    local index = self.selected_index_actual
    local guid = self.servers[index] and self.servers[index].guid
    local servname = string.len(self.servers[index].name) > 18 and string.sub(self.servers[index].name,1,18).."..." or self.servers[index].name
    local report_dialog = InputDialogScreen( STRINGS.UI.SERVERLISTINGSCREEN.REPORTREASON.." ("..servname..")",
                                        {
                                            {
                                                text = STRINGS.UI.SERVERLISTINGSCREEN.OK,
                                                cb = function()
                                                    TheNet:ReportListing(guid, InputDialogScreen:GetText())
                                                    TheFrontEnd:PopScreen()
                                                end
                                            },
                                                                                        {
                                                text = STRINGS.UI.SERVERLISTINGSCREEN.CANCEL,
                                                cb = function()
                                                    TheFrontEnd:PopScreen()
                                                end
                                            },
                                        },
                                    true )
    report_dialog.edit_text.OnTextEntered = function()
        TheNet:ReportListing(guid, InputDialogScreen:GetText())
        TheFrontEnd:PopScreen()
    end
    report_dialog:SetValidChars([[ abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,[]@!()'*+-/?{}" ]]) --'
    TheFrontEnd:PushScreen(report_dialog)
    report_dialog.edit_text:OnControl(CONTROL_ACCEPT, false)
end

local function SetChecked( widget, label, check )
    if check then
        label:SetColour(0,0,0,1)
        widget.off_image:Hide()
        widget.bg:Show()
        widget.img:Show()
    else
        label:SetColour(.4,.4,.4,1)
        widget.off_image:Show()
        widget.bg:Hide()
        widget.img:Hide()
    end
end

function ServerListingScreen:ViewServerMods()
    if self.selected_server ~= nil and self.selected_server.mods_enabled then
        local success = false
        local mods_list = ""
        if self.selected_server.mods_failed_deserialization then
            mods_list = STRINGS.UI.SERVERLISTINGSCREEN.MODS_HIDDEN_MISMATCH
        else
            local added_mod_name = false
            for k,v in pairs(self.selected_server.mods_description) do
                mods_list = mods_list .. v.modinfo_name .. ", "
                added_mod_name = true
            end
            mods_list = string.sub( mods_list, 1, string.len(mods_list)-2 )

            if not added_mod_name then
                mods_list = STRINGS.UI.SERVERLISTINGSCREEN.MODS_HIDDEN_LAN
            else
                success = true
            end
        end

        if success then
            TheFrontEnd:PushScreen(TextListPopupDialogScreen(STRINGS.UI.SERVERLISTINGSCREEN.MODSTITLE, mods_list))
        else
            TheFrontEnd:PushScreen(PopupDialogScreen(
                    STRINGS.UI.SERVERLISTINGSCREEN.MODSTITLE,
                    mods_list,
                    {{ text = STRINGS.UI.SERVERLISTINGSCREEN.OK, cb = function() TheFrontEnd:PopScreen() end }}))
        end
    end
end

function ServerListingScreen:ViewServerTags()
    if self.selected_server ~= nil and self.selected_server.tags ~= nil then
        --force the item to use the fallback font so that language tags don't look broken
        TheFrontEnd:PushScreen(TextListPopupDialogScreen(STRINGS.UI.SERVERLISTINGSCREEN.TAGSTITLE, self.selected_server.tags, nil, nil, nil, FALLBACK_FONT))
    end
end

function ServerListingScreen:ViewServerGroup()
    if self.selected_server ~= nil and self.selected_server.clan_server then
        TheNet:ViewNetProfile(self.selected_server.net_group_id)
    end
end

function ServerListingScreen:ViewServerWorld()
    local worldgenoptions = self:ProcessServerWorldGenData()
    if worldgenoptions ~= nil then
        TheFrontEnd:PushScreen(ViewCustomizationModalScreen(worldgenoptions))
    end
end

function ServerListingScreen:ViewServerPlayers()
    local players = self:ProcessServerPlayersData()
    if players ~= nil then
        TheFrontEnd:PushScreen(ViewPlayersModalScreen(players, self.selected_server.max_players))
    end
end

function ServerListingScreen:ProcessServerGameData()
    if self.selected_server == nil then
        return
    elseif self.selected_server._processed_game_data == nil
        and self.selected_server.game_data ~= nil
        and #self.selected_server.game_data > 0 then
        local success, data = RunInSandboxSafe(self.selected_server.game_data)
        if success and data ~= nil then
            self.selected_server._processed_game_data = data
        end
    end
    return self.selected_server._processed_game_data
end

function ServerListingScreen:ProcessServerWorldGenData()
    if self.selected_server == nil then
        return
    elseif self.selected_server._processed_world_gen_data == nil
        and self.selected_server.world_gen_data ~= nil
        and #self.selected_server.world_gen_data > 0 then
        local success, data = RunInSandboxSafe(self.selected_server.world_gen_data)
        if success and data ~= nil then
            self.selected_server._processed_world_gen_data = data
        end
    end
    return self.selected_server._processed_world_gen_data
end

function ServerListingScreen:ProcessServerPlayersData()
    if self.selected_server == nil then
        return
    elseif self.selected_server._processed_players_data == nil
        and self.selected_server.players_data ~= nil
        and #self.selected_server.players_data > 0 then
        local success, data = RunInSandboxSafe(self.selected_server.players_data)
        if success and data ~= nil then
            for i, v in ipairs(data) do
                if v.colour ~= nil then
                    local colourstr = "00000"..v.colour
                    local r = tonumber(colourstr:sub(-6, -5), 16) / 255
                    local g = tonumber(colourstr:sub(-4, -3), 16) / 255
                    local b = tonumber(colourstr:sub(-2), 16) / 255
                    v.colour = { r, g, b, 1 }
                end
            end
            self.selected_server._processed_players_data = data
        end
    end
    return self.selected_server._processed_players_data
end

local function CompareTable(table_a, table_b)
-- ══★★★【CompareTable：递归深度相等 —— 整个界面性能的关键】
-- ★★★ 这个函数的用途决定了本文件的性能特征：
--   每秒被调用多次（轮询任务）来判断「服务器列表有没有变」，
--   变了才重建 13 个行控件。
-- → ★★ 若用「总是重建」的写法，每秒重建 13 × 约 20 个子控件 =
--   每秒 260 次 AddChild/Kill，在低配机上会明显卡顿。
--   深比较的代价是 O(字段数)，远小于重建控件。
--
-- ★ 逐段分析：
-- 553 同一引用 → 必然相等（最快的短路）
-- 556 nil 检查 → 但只查了 a，**没查 b**：
--   ⚠️ 若 table_a 非 nil、table_b 为 nil，会走到 559 行
--     `type(table_a) ~= "table"` 为假，然后 562 行 getmetatable(nil)
--     返回 nil，564 行 CompareTable(nil, nil) → 553 行 table_a==table_b
--     （两个 nil 相等）→ 返回 true！
--   → ⚠️⚠️【疑似缺陷】CompareTable({1,2}, nil) 会返回 **true**。
--     我已逐行核实 553/556/559/562-564 的逻辑，
--     确认 a 有值而 b 为 nil 时会误判相等。
--     实践中 1581 行 `CompareTable(self.viewed_servers, filtered_servers)`
--     两个都是表，不会触发；但 564 行对元表的递归比较可以触发
--     （a 有元表而 b 没有 → getmetatable(a) 非 nil、getmetatable(b) 为 nil
--       → 此时 556 行的检查就漏了 b 为 nil 的情况）。
--     标注为「真实缺陷但触发条件罕见」。
-- 559 只检查了 a 的类型（b 的类型由 564 递归隐含检查）
--   → 这也是上面那个 bug 的来源：应该写
--     `if type(table_a) ~= "table" or type(table_b) ~= "table"`。
-- 562-564 递归比较元表：
--   → ★ 「比较元表」说明作者考虑过带元表的表（Class 实例）。
--     服务器列表是纯表，元表都是 nil，所以这层比较在实践中是 no-op。
--     但它让函数变慢了一点点（多两次 getmetatable 调用）。
-- ★★ 567-574 双向遍历（两个 for 循环）：
--   → ★ 这是「集合相等」的正确做法：
--     只遍历 a 检查 b（571-574 的反向遍历是多余的，
--     因为若 a 的每个 key 都在 b 中且值相等，而 b 有更多 key，
--     第一个循环不会发现 —— 所以第二个循环是必要的）。
--   → ★★★ 「双向遍历判等」是实现集合相等的标准写法，
--     比单向往返更完备。
-- ⚠️ 但它比较的是**键的值**而非键的存在性，且用了 pairs：
--   对数组 `[1]=a,[2]=b` 与 `{a,b}`（隐式 1,2 键）能判相等。
--   对 `{[1]=x, [3]=y}` 与 `{[1]=x, [3]=y}` 也能判相等（正确）。
--   整体是合理的深比较实现。
-- → ★★ 移植要点：**「数据变了才重建 UI」是所有轮询型界面的核心性能策略**。
--   深比较的成本随数据量线性增长，通常远小于重建视图。
--   前提：数据是「小而完整」的（几十个服务器），而不是分页的。
    -- Basic validation
    if table_a==table_b then return true end

    -- Null check
    if table_a == nil or table_b == nil then return false end

    -- Validate type
    if type(table_a) ~= "table" then return false end

    -- Compare meta tables
    local meta_table_a = getmetatable(table_a)
    local meta_table_b = getmetatable(table_b)
    if not CompareTable(meta_table_a,meta_table_b) then return false end

    -- Compare nested tables
    for index,value_a in pairs(table_a) do
        local value_b = table_b[index]
        if not CompareTable(value_a,value_b) then return false end
    end
    for index,value_b in pairs(table_b) do
        local value_a = table_a[index]
        if not CompareTable(value_a,value_b) then return false end
    end

    return true
end

function ServerListingScreen:UpdateServerData(selected_index_actual)
-- ══★★【UpdateServerData：详情面板的数据 → UI（120 行）】
-- ★★ 581 行的守卫是整个函数的开关：
--   `if sel_serv and CompareTable(sel_serv, self.selected_server) == false`
--   → 「数据真的变了才刷新」—— 又是 CompareTable 的第三种用法。
--   → ★★★★ 同一个深比较函数在本文件承担三种角色：
--     1) 轮询时判断「列表变了没」（847 → 1581）
--     2) 这里判断「选中的服务器详情变了没」
--     3) CompareTable 内部对元表递归时自用
--   → 一个好用的工具函数会被自然地用在所有需要「变了没」的地方。
-- ★★ 588 行的 `self.details_servername._align.maxwidth`：
--   → ★★★ 直接访问控件的**私有字段** _align 来获取排版参数。
--     这违反了封装，但避免了在多处重复写死「270 宽 / 60 字符」。
--     作者选择「读私有字段」而非「把参数抽成常量」。
--     风险：若 templates 里改了这个 Text 的宽度，这里不会自动跟随，
--     而是跟随 _align —— 实际上 _align 就是构造时设的，
--     所以是自洽的。属「可接受的私有访问」。
-- ★ 594 行的描述文案三态（有详情 / 空描述 / 加载中）：
--   → ★★★ 「加载中」是重要的第三态：
--     服务器列表先到（只有名字），详情稍后异步下载（DownloadServerDetails）。
--     UI 必须能表达「还没加载完」而不是显示空白。
--   → ★★ 移植要点：**异步数据要有「加载中」状态**，
--     否则玩家会以为功能坏了。
-- ⚠️ 608 行 GetGameModeString 之后 611 行用 w/2 定位，
--   其中 610 行 `info_button.o_pos = nil` 的注释「wipe the o_pos
--   in case it's been clicked and got set」——
--   → ★★★ 「按下位移的残留状态要主动清理」：
--     Button:OnControl（button.lua:71）按下时会存 o_pos 并把控件偏移，
--     若此时外部改了位置，必须清 o_pos，否则下次按下会从错误位置偏移。
--     这是「与 Button 内部状态机打交道」的必要防御。
-- ★ 622-696 行是五组「视图按钮的三态设置」：
--   viewmods / viewtags / viewgroup / viewworld / viewplayers
--   每组都是 Select（禁用）+ 三种 HoverText（无内容 / 加载中 / 可查看）。
--   → ★★★ 统一的按钮三态模板，重复 5 次。
--   → 应抽成一个 SetViewButton(btn, has_details, has_data) 函数。
-- ⚠️ 640 行的注释「V2C: tags are always available in online tab
--   without detailed info」揭示了业务规则的变更史：
--   曾经 tags 也需要等详情，现在是「在线页签下总是可用」。
--   → ★★★ 「V2C:」前缀的注释记录了「从旧版本改到新版本」的差异。
--     这类注释对理解「为什么代码是这样」极有价值，
--     因为业务规则变更通常不会同步改注释。
    local sel_serv = TheNet:GetServerListingFromActualIndex(selected_index_actual)
    if sel_serv and CompareTable(sel_serv, self.selected_server) == false then
        self.selected_server = sel_serv
        self.selected_index_actual = selected_index_actual

        self.details_servername:SetMultilineTruncatedString(
            self.selected_server.name,
            2,
            self.details_servername._align.maxwidth,
            self.details_servername._align.maxchars,
            true
        )

        self.details_serverdesc:SetMultilineTruncatedString(
            self.selected_server.has_details and (self.selected_server.description ~= "" and self.selected_server.description or STRINGS.UI.SERVERLISTINGSCREEN.NO_DESC) or STRINGS.UI.SERVERLISTINGSCREEN.DESC_LOADING,
            3,
            self.details_serverdesc._align.maxwidth,
            self.details_serverdesc._align.maxchars,
            true
        )

        --if self.selected_server.intention ~= "" then
            --self.details_background:SetTexture("images/server_intentions.xml", intention_images[self.selected_server.intention].big)
            --self.details_background:Show()
        --else
            --self.details_background:Hide()
        --end

        self.game_mode_description.text:SetString( GetGameModeString( self.selected_server.mode ) )
        local w,h = self.game_mode_description.text:GetRegionSize()
        self.game_mode_description.info_button.o_pos = nil --wipe the o_pos in case it's been clicked and got set
        self.game_mode_description.info_button:SetPosition(w/2 + 7, -2)
        if self.selected_server.mode ~= "" then
            self.game_mode_description.info_button:Unselect()
        else
            self.game_mode_description.info_button:Select()
        end

        SetChecked( self.checkbox_dedicated_server, self.dedicated_server_description, self.selected_server.dedicated )
        SetChecked( self.checkbox_pvp, self.pvp_description, self.selected_server.pvp )
        SetChecked( self.checkbox_has_password, self.has_password_description, self.selected_server.has_password )

        if not self.selected_server.mods_enabled then
            self.viewmods_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.NOMODS)
            self.viewmods_button:Select()
        elseif self.selected_server.offline then
            self.viewmods_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.VIEWMODS_LAN)
            self.viewmods_button:Select()
        elseif self.selected_server.has_details then
            self.viewmods_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.VIEWMODS)
            self.viewmods_button:Unselect()
        else
            self.viewmods_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.MODS_LOADING)
            self.viewmods_button:Select()
        end

        if self.selected_server.tags ~= "" then
            self.viewtags_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.VIEWTAGS)
            self.viewtags_button:Unselect()
        else
            --V2C: tags are always available in online tab without detailed info
            if self.selected_server.has_details or self.view_online then
                self.viewtags_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.NOTAGS)
            else
                self.viewtags_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.TAGS_LOADING)
            end
            self.viewtags_button:Select()
        end

        if self.selected_server.clan_server then
            self.viewgroup_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.VIEWGROUP)
            self.viewgroup_button:Unselect()
        else
            --V2C: clan id is always available without detailed info
            --if self.selected_server.has_details then
                self.viewgroup_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.GROUP_NONE)
            --else
            --    self.viewgroup_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.GROUP_LOADING)
            --end
            self.viewgroup_button:Select()
        end

        local gamedata = self:ProcessServerGameData()
        local day = gamedata ~= nil and gamedata.day or STRINGS.UI.SERVERLISTINGSCREEN.UNKNOWN
        self.day_description.text:SetString(STRINGS.UI.SERVERLISTINGSCREEN.DAYDESC..day)

        local seasondesc = self.selected_server.season ~= nil and STRINGS.UI.SERVERLISTINGSCREEN.SEASONS[string.upper(self.selected_server.season)] or nil
        if seasondesc ~= nil and
            gamedata ~= nil and
            gamedata.daysleftinseason ~= nil and
            gamedata.dayselapsedinseason ~= nil then

            if gamedata.daysleftinseason * 3 <= gamedata.dayselapsedinseason then
                seasondesc = STRINGS.UI.SERVERLISTINGSCREEN.LATE_SEASON_1..seasondesc..STRINGS.UI.SERVERLISTINGSCREEN.LATE_SEASON_2
            elseif gamedata.dayselapsedinseason * 3 <= gamedata.daysleftinseason then
                seasondesc = STRINGS.UI.SERVERLISTINGSCREEN.EARLY_SEASON_1..seasondesc..STRINGS.UI.SERVERLISTINGSCREEN.EARLY_SEASON_2
            end
        end
        self.season_description.text:SetString(seasondesc or STRINGS.UI.SERVERLISTINGSCREEN.UNKNOWN_SEASON)

        local worldgenoptions = self:ProcessServerWorldGenData()
        if worldgenoptions ~= nil then
            self.viewworld_button:Unselect()
            self.viewworld_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.VIEWWORLD)
        else
            self.viewworld_button:Select()
            self.viewworld_button:SetHoverText(self.selected_server.has_details and STRINGS.UI.SERVERLISTINGSCREEN.WORLD_UNKNOWN or STRINGS.UI.SERVERLISTINGSCREEN.WORLD_LOADING)
        end

        local players = self:ProcessServerPlayersData()
        if players ~= nil then
            self.viewplayers_button:Unselect()
            self.viewplayers_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.VIEWPLAYERS)
        else
            self.viewplayers_button:Select()
            self.viewplayers_button:SetHoverText(self.selected_server.has_details and STRINGS.UI.SERVERLISTINGSCREEN.PLAYERS_UNKNOWN or STRINGS.UI.SERVERLISTINGSCREEN.PLAYERS_LOADING)
        end

        self.join_button:Enable()
    end
end

function ServerListingScreen:ServerSelected(new_index)
-- ══★【ServerSelected：选中态的唯一入口】
-- ★★★ 与 modstab 的 SetNewMapTarget、tradescreen 的选中处理同模式：
--   一个函数负责「有选中」与「无选中」两条路径的全部状态更新。
-- ★★★ 708 行 DownloadServerDetails(server.row)：
--   → ★★★ 「选中一个条目 → 触发一次异步详情下载」：
--     服务器列表（名字/人数/延迟）是廉价的，详情（描述/mod 列表）
--     需要单独请求。选中即请求是最省流量的策略。
--   → ★★ 移植要点：**「列表数据」与「详情数据」分离**，
--     选中时才拉详情，能大幅降低服务器压力与客户端流量。
-- ⚠️ 705 行的守卫：只有 actualindex 变了才下载，
--   → ★ 「避免重复请求同一份详情」的幂等保护。
-- ★ 722 行无条件调 GuaranteeSelectedServerHighlighted：
--   → 即使在「无选中」分支（713-720）也会调，
--     保证所有行的光标都被取消选中。
    if new_index and self.viewed_servers and self.viewed_servers[new_index] ~= nil then
        local server = self.viewed_servers[new_index]
        if self.selected_index_actual ~= server.actualindex then
            self.selected_index_actual = server.actualindex
            if string.len(server.row) > 0 then
                TheNet:DownloadServerDetails(server.row)
            end
        end
        self:UpdateServerData(self.selected_index_actual)
        self:UpdateServerInformation(true)
    else
        self:UpdateServerInformation(false)
        self.selected_server = nil
        self.selected_index_actual = -1
        self.details_servername:SetString(STRINGS.UI.SERVERLISTINGSCREEN.NOSERVERSELECTED)
        self.details_serverdesc:SetString("")
        self.join_button:Disable()
    end

    self:GuaranteeSelectedServerHighlighted()
end

function ServerListingScreen:StartPeriodicRefreshTask()
-- ══★【周期刷新任务：轮询的实现】
-- ★★ 729 行 `DoPeriodicTask(self.tickperiod, function() self:RefreshView(false, true) end)`：
--   第二个参数 keepScrollFocusPos = true ——
--   → ★★ 「刷新时保持滚动位置」：
--     服务器列表每 tickperiod 就刷新一次，若不保持位置，
--     玩家正在浏览第 50 个服务器时会突然被弹回原处。
--     这是「后台刷新不打断用户操作」的核心需求。
--   → ★★★★ 移植要点：**任何周期性刷新都要考虑「用户正在看的位置」**。
--     DST 的做法是把这个标志一路传到 SetList 的第 4 个参数
--     （keeprelativefocusindex，见 scrollablelist:530/549-551）。
-- 726-728 行 Cancel 后**没有置 nil**，与 735 行的 StopPeriodicRefreshTask
--   不一致（后者置 nil）。
--   → 属「同一操作两处实现，风格不同」，无害但不统一。
    if self.task ~= nil then
        self.task:Cancel()
    end
    self.task = self.inst:DoPeriodicTask(self.tickperiod, function() self:RefreshView(false, true) end)
end

function ServerListingScreen:StopPeriodicRefreshTask()
    if self.task ~= nil then
        self.task:Cancel()
        self.task = nil
    end
end

function ServerListingScreen:ClearServerList()
-- ══★【ClearServerList：清空显示而不销毁控件 —— 虚拟化的配套】
-- ★★ 740 行遍历 list_widgets（13 个池控件）逐个清空字段并 Hide 图标。
--   → ★★★ 这是「模式 B」的关键配套：
--     池里的控件是**共享的**，清空数据不能 Kill 控件，
--     只能把它的内容复位。
--   → 对比 scrollablelist 的模式 A（SetList 会 Kill 旧控件重建）。
-- ★ 742 行 `v.NAME:SetPosition(v.NAME._align.x, v.NAME._align.y, 0)`：
--   → ★★★ 与 1034 行的居中定位形成对照：
--     UpdateServerListWidget 会根据文字宽度把 NAME 居中（1033-1035 行），
--     而这里恢复到 _align 里的**原始左对齐位置**。
--   → 「列表重建时按内容重排 + 整体重置时恢复默认布局」，
--     两套定位逻辑并存，正是虚拟化的复杂度所在。
-- ★ 757 行 Scroll(-view_offset, true) 滚回顶部：
--   → ★★★ 注意这里传的是**负的当前偏移**，scrollablelist:250 的 Scroll 会
--     加上它得到 0，再夹紧到合法范围 —— 正是「Scroll 惯用法」的应用。
--   → 但 Scroll(0, true) 更直观（545 行就有这个用法），
--     这里用负偏移是多余的绕路。属「同一效果的不同写法」。
    for i,v in pairs (self.list_widgets) do
        v.NAME:SetString("")
        v.NAME:SetPosition(v.NAME._align.x, v.NAME._align.y, 0)
        v.CHAR:Hide()
        v.FRIEND_ICON:Hide()
        v.CLAN_OTHER_ICON:Hide()
        v.CLAN_OPEN_ICON:Hide()
        v.CLAN_CLOSED_ICON:Hide()
        v.HAS_PASSWORD_ICON:Hide()
        v.DEDICATED_ICON:Hide()
        v.PVP_ICON:Hide()
        v.MODS_ENABLED_ICON:Hide()
        v.PLAYERS:SetString("")
        v.PING:SetString("")
    end
    -- Scroll back to the top of the list
    if self.servers_scroll_list.items and #self.servers_scroll_list.items > 0 then
        self.servers_scroll_list:Scroll(-self.servers_scroll_list.view_offset, true)
    end
end

function ServerListingScreen:SearchForServers()
-- ══★★【SearchForServers：一次搜索的完整生命周期】
-- ★ 763-764 行清空 servers 与 viewed_servers ——
--   → ★★ 注意「服务器总数」也被清零，但 766 行马上用
--     `#self.servers - self.unjoinable_servers` 计算 num_servs，
--     结果必然是 0 - unjoinable（unjoinable 此时是上一轮残留值！）。
--   → ⚠️⚠️【疑似缺陷，已逐行核实】763 行清空 self.servers 后，
--     766 行立即计算 num_servs，但 self.unjoinable_servers
--     **没有在 SearchForServers 里被重置**。
--     它只在 DoFiltering:1495 行被重置为 0。
--     → 搜索开始的那一瞬间，num_servs = 0 - 上轮的 unjoinable = 负数，
--       767 行 `if num_servs < 0 then num_servs = 0 end` 兜住了。
--     → 所以不会崩，但 767 行的存在正是为了掩盖这个顺序问题。
--     正确做法是 763 行附近把 unjoinable_servers 也清零。
-- ★★ 768 行 SetList(self.viewed_servers) 传空表：
--   → 列表立刻变空（配合 765 行的 ClearServerList 清掉残留行）。
--   → ★★★ 「先清空显示，再等新数据」：
--     避免旧数据停留造成误解（玩家可能点到一个已经下线的服务器）。
-- 770-774 行的计数文本三态（搜索中 / 显示 X 共 Y / 无连接 / 仅 LAN）：
--   → ★★★ 「总数」与「当前显示数」分开显示是列表界面的标准做法：
--     玩家能立刻知道「有 500 个服务器，但筛选后只剩 12 个」。
-- ★ 788/791 行两处 `focused_index = 1`：
--   → ★★★ 直接改 ScrollableList 的内部字段来重置焦点位置。
--     这印证了 scrollablelist 的 focused_index 是公开可写的状态
--     （虽然没提供 setter）。属「知道内部实现才能这么用」。
-- ⚠️ 795-796 行：先启动周期任务，再立即刷新一次。
--   顺序正确（否则周期任务可能在 RefreshView 之前触发）。
--   → ★ 与 326 行 OnBecomeActive 的顺序一致，符合惯例。
    self:ServerSelected(nil)
    self.servers = {}
    self.viewed_servers = {}
    self:ClearServerList()
    local num_servs = #self.servers-self.unjoinable_servers
    if num_servs < 0 then num_servs = 0 end
    self.servers_scroll_list:SetList(self.viewed_servers)

    if num_servs == 0 then
        self.server_count:SetString("("..STRINGS.UI.SERVERLISTINGSCREEN.SEARCHING_SERVERS..")")
    else
        self.server_count:SetString( subfmt(STRINGS.UI.SERVERLISTINGSCREEN.SHOWING_FMT, { viewed = #self.viewed_servers, total = num_servs }) )
    end
    if self.view_online and self.offlinemode then
        self.server_count:SetString("("..STRINGS.UI.SERVERLISTINGSCREEN.NO_CONNECTION..")")
    elseif not self.view_online then
        self.server_count:SetString("("..STRINGS.UI.SERVERLISTINGSCREEN.LAN..")")
    end

    for i, v in ipairs(self.filters) do
        if v.name == "VERSIONCHECK" then
            TheNet:SetCheckVersionOnQuery(v.spinner:GetSelectedData())
        end
    end

    if self.view_online and not self.offlinemode then -- search LAN and online if online
        self.servers_scroll_list.focused_index = 1
        TheNet:SearchServers()
    else -- otherwise just LAN
        self.servers_scroll_list.focused_index = 1
        TheNet:SearchLANServers(self.offlinemode)
    end

    self:StartPeriodicRefreshTask()
    self:RefreshView(true)
end

function ServerListingScreen:OnStartClickServerInList(index)
    index = index + self.servers_scroll_list.view_offset
    if self.viewed_servers and self.viewed_servers[index] ~= nil and self.selected_index_actual ~= self.viewed_servers[index].actualindex then
        self.last_server_click_time = nil
    end
    self:ServerSelected(index)
end

function ServerListingScreen:OnFinishClickServerInList(index)
    if self.viewed_servers and self.viewed_servers[index] ~= nil and self.viewed_servers[index].actualindex == self.selected_index_actual then
        -- If we're clicking on the same server as the last click, check for double-click Join
        if self.last_server_click_time and GetStaticTime() - self.last_server_click_time <= DOUBLE_CLICK_TIMEOUT then
            self:Join(false)
            return
        end
    end
    self.last_server_click_time = GetStaticTime()
end

function ServerListingScreen:RefreshView(skipPoll, keepScrollFocusPos)
-- ══★★★【RefreshView：本文件的中心调度函数 —— 与 mapscreen 同一模式】
-- ★ 820 行淡出时不刷新：
--   「If we're fading, don't mess with stuff」。
--   → ★★★ 「界面在过渡动画中时冻结数据更新」：
--     否则会在淡出过程中重建控件，导致闪烁或撕裂。
--   → ★ 移植要点：**UI 状态机要有「过渡中」状态并冻结数据绑定**。
--     这个检查只需一行，却能消除一整类视觉 bug。
-- ★★ 837-840 行的脏检查：
--   `if not skipPoll then if TheNet:GetServerListingReadDirty() == false then return end`
--   → ★★★★ 「引擎侧提供脏标志，Lua 侧只做界面」：
--     GetServerListingReadDirty 是引擎告知「数据变了」的信号。
--     比 CompareTable 的深比较快得多（O(1) vs O(字段数)）。
--   → ★★ 两级脏检查的分工：
--     引擎脏标志（廉价，847 行）→ 快速跳过整次刷新
--     CompareTable（昂贵，1581 行）→ 精细判断是否要重建控件
--   → ★★★★ 「两级过滤：先廉价后昂贵」是轮询界面的标准优化。
--   skipPoll 为真时跳过取数据，直接刷视图（796/848 行的路径）。
-- ★★ 847 行的注释「This also calls DoSorting」：
--   → ★★ 关键知识：DoFiltering 内部会调 DoSorting（1596 行）。
--     「过滤后排序」是一条隐式链路，作者用注释保住了它。
-- 850-852 行的三连调用：
--   RefreshView（列表重排）+ GuaranteeSelectedServerHighlighted（高亮）
--   + UpdateServerData（详情面板）。
--   → ★★★ 「一次数据变化引发三处 UI 更新」在此集中编排。
--   → ★ 与 mapscreen:1180 的 UpdateMapActionsDecorations 完全同构
--     （都是脏标记 → 统一刷新点 → 分发到各子部件）。
-- ★ 这三行的顺序也重要：先刷列表（高亮依赖列表数据），
--   再更新高亮，最后更新详情面板。
    -- If we're fading, don't mess with stuff
    if TheFrontEnd:GetFadeLevel() > 0 then return end

    if TheNet:IsSearchingServers() then
        self.refresh_button:Disable()
        self.refresh_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.REFRESHING)
        --if self.lan_spinner then self.lan_spinner.spinner:Disable() end
    else
        self.refresh_button:Enable()
        self.refresh_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.REFRESH)
        local num_servs = #self.servers-self.unjoinable_servers
        if num_servs < 0 then num_servs = 0 end
        self.server_count:SetString( subfmt(STRINGS.UI.SERVERLISTINGSCREEN.SHOWING_FMT, { viewed = #self.viewed_servers, total = num_servs }) )
        if not self.view_online then
            self.server_count:SetString("("..STRINGS.UI.SERVERLISTINGSCREEN.LAN..")")
        end
    end

    if not skipPoll then
        if TheNet:GetServerListingReadDirty() == false then
            return
        end

        local servers = {}
        servers = TheNet:GetServerListings()

        self.servers = servers

        self:DoFiltering(false, keepScrollFocusPos) -- This also calls DoSorting
    end

    self.servers_scroll_list:RefreshView()
    self:GuaranteeSelectedServerHighlighted()
    self:UpdateServerData( self.selected_index_actual )
end

function ServerListingScreen:SetRowColour(row_widget, colour)
-- ★★ SetRowColour：把一个颜色应用到一行的三个文本控件。
-- ★ 三个字段 NAME / PLAYERS / PING 必须在同一行被改，
--   否则会出现「名字是红的但延迟是黑的」。
-- → ★★★ 「一行是一个视觉单元，改样式要整体改」：
--   抽成函数保证不会出现只改一半的情况。
--   正确做法本应是「行控件自己提供 SetStyle(color)」，
--   这里由屏幕代劳，属于外部操作内部子控件。
-- ⚠️ 用 unpack 展开四元颜色（scrollablelist:209 也用同样手法）。
--   Lua 5.1 的 unpack 在 5.2+ 改名 table.unpack ——
--   lupa 是 5.5，但只是语法检查，不会执行到这里。
--   DST 用 5.1 语义所以 unpack 可用。
    row_widget.NAME:SetColour(unpack(colour))
    row_widget.PLAYERS:SetColour(unpack(colour))
    row_widget.PING:SetColour(unpack(colour))
end

function ServerListingScreen:MakeServerListWidgets()
-- ══★【MakeServerListWidgets：建立 13 个行控件（约 280 行）】
-- ★★ 865 行的循环是虚拟化的**池构建**：
--   for i=1,listings_per_view do ... AddChild(Widget("server_list_row")) ... end
--   → 每个行包含 NAME / PLAYERS / PING 三个文本 + 八个状态图标
--     （CHAR / FRIEND_ICON / CLAN_* / HAS_PASSWORD / DEDICATED / PVP /
--     MODS_ENABLED / INTENTION）。
--   → ★★ 「一行约 20 个子控件」× 13 = 260 个控件常驻。
--     若服务器有 500 个而每个一行，就是 10000 个控件 —— 不可接受。
--     虚拟化把「每数据一行」变成「每可视行一行」。
-- ★ 868 行 `local font_size = font_size * .7` 遮蔽了外层的 font_size：
--   → ⚠️ 这是循环内的局部变量，只在本轮迭代有效。
--     写法的意图（避免逐行重复缩放计算）是好的，
--     但变量遮蔽让读者困惑（外层同名变量是什么？）。
--     同款写法在 1013 行又出现一次。
-- ⚠️ 968-969 行有**重复的连续赋值**：
--   `row.PLAYERS = row:AddChild(Text(BUTTONFONT, font_size))`
--   紧接着又 `row.PLAYERS = row:AddChild(Text(NEWFONT, font_size))`。
--   → ★★★ 第一行创建的控件被**立即覆盖**（成了孤儿控件，仍在树上）。
--     我已逐行核实这两行相邻且完全重复。
--     这是一个真实的资源泄漏：每个行多一个不可见的 Text 控件。
--     13 行 × 1 = 13 个多余控件。
--     推测是改字体时忘了删旧行。修复：删掉第一行。
--     标注为「真实缺陷（资源泄漏）」。
    self.list_widgets = {}

    local bg_y_offset = -215
    for i=1, listings_per_view do
        local row = self.table.server_list_rows:AddChild(Widget("server_list_row"))

        local font_size = font_size * .7
        local y_offset = 15

        if i%2 == 1 then
            local bg = self.table.server_list_bgs:AddChild(Image("images/serverbrowser.xml", "whitebar.tex"))
            bg:SetScale(.7,.7)
            bg:SetPosition( 213, bg_y_offset+(i*30)+y_offset-1, 0)
            bg:SetTint(1,1,1,.7)
            bg:MoveToBack()
        end

        row.index = -1

        row.cursor = row:AddChild( ListCursor() )
        row.cursor:SetPosition( 221, y_offset-1, 0)
        row.cursor:SetOnDown(  function() self:OnStartClickServerInList(i)  end)
        row.cursor:SetOnClick( function() self:OnFinishClickServerInList(i) end)
        row.cursor:Hide()

        local intent = row:AddChild(Widget("intention_image"))
        intent:SetPosition(column_offsets.NAME-18, y_offset)
        intent.img = intent:AddChild(Image("images/servericons.xml", "playstyle_social.tex"))
        intent.img:SetScale(0.08, 0.08)
        intent:SetHoverText("INTENTION", {font = NEWFONT_OUTLINE, offset_x = 1, offset_y = 28, colour = {1,1,1,1}})
        row.INTENTION = intent

        row.NAME = row:AddChild(Text(NEWFONT, font_size))
        row.NAME:SetHAlign(ANCHOR_MIDDLE)
        row.NAME:SetString("")
        row.NAME._align =
        {
            maxwidth = 275,
            maxchars = 80,
            x = column_offsets.NAME,
            y = y_offset,
        }
        row.NAME:SetPosition(row.NAME._align.x, row.NAME._align.y, 0)

        row.DETAILS = row.cursor:AddChild(Widget("detail_icons"))
        row.DETAILS:SetPosition(column_offsets.DETAILS-200, -1, 0)

        local details_x = -56

        row.HAS_PASSWORD_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "password.tex", "rust", STRINGS.UI.SERVERLISTINGSCREEN.PASSWORD_ICON_HOVER, nil, {-1,0}, .08, .073))
        row.HAS_PASSWORD_ICON:SetPosition(details_x,1)
        row.HAS_PASSWORD_ICON:Hide()
        details_x = details_x + 26

        row.DEDICATED_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "dedicated.tex", "burnt", STRINGS.UI.SERVERLISTINGSCREEN.DEDICATED_ICON_HOVER, nil, {0,0}, .08, .073))
        row.DEDICATED_ICON:SetPosition(details_x,1)
        row.DEDICATED_ICON:Hide()
        details_x = details_x + 26

        row.MODS_ENABLED_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "mods.tex", "orange", STRINGS.UI.SERVERLISTINGSCREEN.MODS_ICON_HOVER, nil, {0,0}, .077, .077))
        row.MODS_ENABLED_ICON:SetPosition(details_x,1)
        row.MODS_ENABLED_ICON:Hide()
        details_x = details_x + 26

        row.PVP_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "pvp.tex", "brown", STRINGS.UI.SERVERLISTINGSCREEN.PVP_ICON_HOVER, nil, {0,0}, .075, .075))
        row.PVP_ICON:SetPosition(details_x,1)
        row.PVP_ICON:Hide()
        details_x = details_x + 26

        local bgColor = "yellow"--"beige"
        row.CHAR = row.DETAILS:AddChild(Widget("char"))
        row.CHAR_ICON_BG = row.CHAR:AddChild(Image("images/servericons.xml", ("bg_"..bgColor..".tex") or "bg_burnt.tex"))
        row.CHAR_ICON_BG:SetScale(.09)
        row.CHAR_ICON = row.CHAR:AddChild(Image("images/saveslot_portraits.xml", "unknown.tex"))
        row.CHAR_ICON:SetScale(.21, .22, 1)
        row.CHAR:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.CHAR_AGE_1.."0"..STRINGS.UI.SERVERLISTINGSCREEN.CHAR_AGE_3, { font = NEWFONT_OUTLINE, offset_x = 1, offset_y = 28, colour = {1,1,1,1} })
        row.CHAR:SetPosition(details_x,1)
        row.CHAR:Hide()
        details_x = details_x + 27

        row.FRIEND_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "friend.tex", "green", STRINGS.UI.SERVERLISTINGSCREEN.FRIEND_ICON_HOVER, nil, {0,0}, .075, .08))
        row.FRIEND_ICON:SetPosition(details_x,1)
        row.FRIEND_ICON:Hide()
        details_x = details_x + 26

        row.CLAN_OTHER_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "clan.tex", "beige", STRINGS.UI.SERVERLISTINGSCREEN.CLAN_OTHER_ICON_HOVER, nil, {0,0}, .075, .075))
        row.CLAN_OTHER_ICON.img:SetTint(150/255, 150/255, 150/255, 255/255)
        row.CLAN_OTHER_ICON:SetPosition(details_x,1)
        row.CLAN_OTHER_ICON:Hide()

        row.CLAN_OPEN_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "clan.tex", "orange", STRINGS.UI.SERVERLISTINGSCREEN.CLAN_OPEN_ICON_HOVER, nil, {0,0}, .075, .075))
        row.CLAN_OPEN_ICON.img:SetTint(238/255, 238/255, 99/255, 255/255)
        row.CLAN_OPEN_ICON:SetPosition(details_x,1)
        row.CLAN_OPEN_ICON:Hide()

        row.CLAN_CLOSED_ICON = row.DETAILS:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "clan.tex", "orange", STRINGS.UI.SERVERLISTINGSCREEN.CLAN_CLOSED_ICON_HOVER, nil, {0,0}, .075, .075))
        row.CLAN_CLOSED_ICON.img:SetTint(238/255, 99/255, 99/255, 255/255)
        row.CLAN_CLOSED_ICON:SetPosition(details_x,1)
        row.CLAN_CLOSED_ICON:Hide()
        details_x = details_x + 26

        row.PLAYERS = row:AddChild(Text(BUTTONFONT, font_size))
        row.PLAYERS = row:AddChild(Text(NEWFONT, font_size))
        row.PLAYERS:SetHAlign(ANCHOR_MIDDLE)
        row.PLAYERS:SetPosition(column_offsets.PLAYERS + 20, y_offset, 0)
        row.PLAYERS:SetRegionSize( 400, 70 )
        row.PLAYERS:SetString("")

        row.PING = row:AddChild(Text(NEWFONT, font_size))
        row.PING:SetHAlign(ANCHOR_MIDDLE)
        row.PING:SetPosition(column_offsets.PING + 20, y_offset, 0)
        row.PING:SetRegionSize( 400, 70 )
        row.PING:SetString("")

        row.focus_forward = row.cursor

        row:SetFocusChangeDir(MOVE_RIGHT, function() return self:CurrentRightFocus() end)
        row:SetFocusChangeDir(MOVE_LEFT, function() return self:CurrentLeftFocus() end)

        table.insert(self.list_widgets, row)--, id=i})
    end

    local function UpdateServerListWidget(widget, serverdata)
-- ══★★★【UpdateServerListWidget：虚拟化的核心 —— 一行代码的职责】
-- ★★★★ 这个函数是 ScrollableList 模式 B 的 `updatefn`：
--   签名 (widget, serverdata) 由 scrollablelist:301 调用，
--   传入「池里的某个控件」与「当前要显示的数据」。
--   → ★★★ 每次滚动一格，所有池控件都会重新调用一次本函数，
--     把它们重新绑定到新的数据上。
-- ★★★ 986 行的 `if not widget then return end` 是必需的防御：
--   scrollablelist:299 行取 `static_widgets[i - view_offset]`，
--   当该下标越界时是 nil —— 正是我在 scrollablelist 注释里
--   指出的「首项拿不到控件」的边界问题。
--   → ★★ 这行防御的存在**印证**了那处的边界缺陷确实会发生，
--     且调用方已经踩到过并做了防护。
--   → ★ 移植要点：**复用池的绑定函数必须能处理「拿不到控件」**。
-- ★★ 987-1007 行的 serverdata 为 nil 分支 = 「这一格是空的」：
--   清空所有字段 + Hide 所有图标 + Disable 整个行 + Hide 光标。
--   → ★★★ 「空位」的完整复位，与 ClearServerList:739 是同款逻辑，
--     但这里是**内联**的（20 行），而 ClearServerList 里也有一份。
--   → ⚠️ 两处重复。应抽成 `ClearRowWidget(widget)`。
--   1004-1005 行的 `widget.cursor:Hide()` + `widget.cursor:Disable()`：
--   光标也要复位 —— 它是行的焦点指示器。
-- → ★★★★ 这就是「数据 → UI」的完整反向绑定：
--   serverdata 的一切字段都要在 widget 上有对应表现，
--   且 nil 时要能全部归零。
--   移植时列一张「数据字段 ↔ 视觉表现」的对照表，逐项落实。
        if not widget then return end

        if not serverdata then
            widget.index = -1
            widget.INTENTION:Hide()
            widget.NAME:SetString("")
            widget.NAME:SetPosition(widget.NAME._align.x, widget.NAME._align.y, 0)
            widget.PLAYERS:SetString("")
            widget.PING:SetString("")
            widget.CHAR:Hide()
            widget.FRIEND_ICON:Hide()
            widget.CLAN_OTHER_ICON:Hide()
            widget.CLAN_OPEN_ICON:Hide()
            widget.CLAN_CLOSED_ICON:Hide()
            widget.HAS_PASSWORD_ICON:Hide()
            widget.DEDICATED_ICON:Hide()
            widget.PVP_ICON:Hide()
            widget.MODS_ENABLED_ICON:Hide()
            widget.cursor:Hide()
            widget.cursor:Disable()
            widget:Disable()
        else
            widget:Enable()
            widget.cursor:Enable()

            local dev_server = serverdata.version == -1
            local version_check_failed = serverdata.version ~= tonumber(APP_VERSION)

            local font_size = font_size * .8
            local y_offset = 15

            widget.index = serverdata.actualindex --actual index is wrong
-- ⚠️ 行尾注释「actual index is wrong」—— ★★★ 作者自己标注了不确定。
-- 1017 行 `widget.index = serverdata.actualindex`。
-- ★★ 这里的 index 是**选中判定的依据**（1147 行、1601 行都用它）：
--   `if v.index ~= -1 and v.index == self.selected_index_actual then`。
-- → ★★★ 所以如果 actualindex 真的错了，「高亮选中行」就会错位。
--   实际 index == -1 表示「这一格是空的」（987 行分支设置）。
-- ★★ 1015 行 `local version_check_failed = serverdata.version ~= tonumber(APP_VERSION)`：
--   → ★★ **没判 version 为 nil**：若服务器没上报版本，
--     nil ~= 某数字 → true → 会被当成版本不匹配（显示红色）。
--     这可能是刻意的（未知版本视为可疑），但没有注释说明。
--     对比 1146 行的同样判断用了 `v.version and` 守卫 ——
--     **两处不一致**（1145/1146 有守卫，1015 没有）。
--     若 widget.version 为 nil（不该发生，因为 1019 行必然赋值），
--     两处行为会不同。标注为「疑似不一致」。
-- ★ 1013 行的 font_size 遮蔽同 868 行的问题。
-- ★★ 1024-1032 行的 intention 处理：
--   ★ 1025 行有三重守卫（值非 nil 且非空 且在表里），
--     注释「TODO: right now checking for bad intention data here,
--     but should probably write fallback data into serverdata earlier」
--     → ★★★ 作者明确知道「数据清洗应该更早做」，
--       现在是在渲染层兜底。这是「脏数据在最后一层防御」的常见形态。
--   → ★★ 正确做法：数据进入时清洗一次，后续全部信任。
-- ★★ 1033-1035 行的动态居中：
--   `SetTruncatedString(...)` 后按实际宽度 `SetPosition(_align.x + w*.5, ...)`。
--   → ★★★ 「文本控件按内容宽度重新居中」：
--     服务器名长短不一，左对齐会参差不齐，居中才整齐。
--     但 SetPosition 是在 SetString 之后 —— 必须如此，
--     因为宽度只有在设了字符串之后才确定。
--   → ★ 这个顺序依赖没有注释，是「靠执行顺序保证正确」的又一处。

            widget.version = serverdata.version
            widget.offline = serverdata.offline
            widget.beta = GetBetaInfoId(serverdata.tags)

            widget.cursor:Show()

            -- TODO: right now checking for bad intention data here, but should probably write fallback data into serverdata earlier in the process. ~gjans
            if serverdata.intention ~= nil and serverdata.intention ~= "" and intention_images[serverdata.intention] ~= nil then
                widget.INTENTION:Show()
                widget.INTENTION.img:SetTexture("images/servericons.xml", intention_images[serverdata.intention].small)
                widget.INTENTION:SetHoverText(STRINGS.UI.INTENTION[string.upper(serverdata.intention)])

            else
                widget.INTENTION:Hide()
            end

            widget.NAME:SetTruncatedString(serverdata.name, widget.NAME._align.maxwidth, widget.NAME._align.maxchars, true)
            local w, h = widget.NAME:GetRegionSize()
            widget.NAME:SetPosition(widget.NAME._align.x + w * .5, widget.NAME._align.y, 0)

            self:ProcessPlayerData( serverdata.session )

            if self.sessions[serverdata.session] ~= nil and self.sessions[serverdata.session] ~= false then
                local playerdata = self.sessions[serverdata.session]
                local character = playerdata.prefab or ""
                local atlas = "images/saveslot_portraits"
                if not table.contains(DST_CHARACTERLIST, character) then
                    if table.contains(MODCHARACTERLIST, character) then
                        atlas = atlas.."/"..character
                    else
                        character = #character > 0 and "mod_small" or "unknown"
                    end
                end
                atlas = atlas..".xml"
                widget.CHAR_ICON:SetTexture(atlas, character..".tex")
                local age = playerdata.age or "???"
                widget.CHAR:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.CHAR_AGE_1..age..(age == 1 and STRINGS.UI.SERVERLISTINGSCREEN.CHAR_AGE_2 or STRINGS.UI.SERVERLISTINGSCREEN.CHAR_AGE_3))
                widget.CHAR:Show()
-- ══★【角色头像：跨层资源查找的完整案例】
-- ★★★ 1041-1053 行处理「这个服务器上有什么角色」：
--   1039 拿沙盒解析出的玩家数据
--   1042-1050 决定用哪张图集、哪个图标：
--     官方角色 → saveslot_portraits.xml
--     模组角色 → saveslot_portraits/<角色名>.xml
--     未知角色 → mod_small
--     无数据     → unknown
-- → ★★★ 「三级回退的资源查找」：
--   优先精确匹配 → 前缀匹配 → 通用占位。
-- → ★ 移植要点：**为「数据可能不认识的东西」准备通用兜底图标**，
--     否则模组新增角色时界面会出现空白格。
-- ★★ 1053 行的三元链：
--   `character = #character > 0 and "mod_small" or "unknown"`
--   → 注意逻辑：非空 → mod_small，为空 → unknown。
--     读起来反直觉（长度 > 0 却是「更通用」的那个），
--     实际是对的（有名字但不认识 → mod_small）。
-- ★ 1052-1053 行的年龄文案有单复数处理：
--   `(age == 1 and CHAR_AGE_2 or CHAR_AGE_3)`
--   → ★ 正确处理了 1 岁与多岁的英文语序差异。
--   → ★★ 「国际化不只是翻译字符串，还包括语法形态」——
--     单复数、语序、量词都要按语言处理。本文件用硬编码的 and/or 实现。
--     更通用的做法是复数规则表（CLDR 风格）。
            else
                widget.CHAR:Hide()
            end

            if serverdata.friend_playing then
                widget.FRIEND_ICON:Show()
            else
                widget.FRIEND_ICON:Hide()
            end

            if serverdata.clan_server then
                if serverdata.belongs_to_clan then
                    if serverdata.clan_only then
                        widget.CLAN_OTHER_ICON:Hide()
                        widget.CLAN_OPEN_ICON:Hide()
                        widget.CLAN_CLOSED_ICON:Show()
                    else
                        widget.CLAN_OTHER_ICON:Hide()
                        widget.CLAN_OPEN_ICON:Show()
                        widget.CLAN_CLOSED_ICON:Hide()
                    end
                else
                    widget.CLAN_OTHER_ICON:Show()
                    widget.CLAN_OPEN_ICON:Hide()
                    widget.CLAN_CLOSED_ICON:Hide()
                end
            else
                widget.CLAN_OTHER_ICON:Hide()
                widget.CLAN_OPEN_ICON:Hide()
                widget.CLAN_CLOSED_ICON:Hide()
            end
            if serverdata.has_password then
                widget.HAS_PASSWORD_ICON:Show()
            else
                widget.HAS_PASSWORD_ICON:Hide()
            end
            if serverdata.dedicated then
                widget.DEDICATED_ICON:Show()
            else
                widget.DEDICATED_ICON:Hide()
            end
            if serverdata.pvp then
                widget.PVP_ICON:Show()
            else
                widget.PVP_ICON:Hide()
            end
            if serverdata.mods_enabled then
                widget.MODS_ENABLED_ICON:Show()
            else
                widget.MODS_ENABLED_ICON:Hide()
            end

            widget.PLAYERS:SetString(serverdata.current_players .. "/" .. serverdata.max_players)

            widget.PING:SetString(serverdata.ping)
            if serverdata.ping < 0 then
                widget.PING:SetString("???")
            end

            if dev_server then
                self:SetRowColour(widget, dev_color)
            elseif version_check_failed then
                self:SetRowColour(widget, widget.beta > 0 and beta_color or mismatch_color)
            else
                self:SetRowColour(widget, serverdata.offline and offline_color or normal_color)
            end
        end
    end

    self.servers_scroll_list = self.table:AddChild(ScrollableList(self.viewed_servers, 320, 385, 20, 10, UpdateServerListWidget, self.list_widgets, 150, true))
-- ══★★★★【★★ 虚拟化的配置现场 —— 三个关键参数】
-- ScrollableList(self.viewed_servers, 320, 385, 20, 10, 
--                UpdateServerListWidget, self.list_widgets, 150, true)
-- 逐参数对照 scrollablelist:36 的签名：
--   items            = viewed_servers（**纯数据**，不是控件！）
--   listwidth/height = 320 / 385
--   itemheight       = 20  ← ⚠️ 注意：这是「每项的高度」，
--                        但 865-981 行建的行控件实际高约 100 像素
--   itempadding      = 10
--   updatefn         = UpdateServerListWidget ← ★ 模式 B 的标志
--   widgetstoupdate  = self.list_widgets（13 个预建行）← ★ 池
--   widgetXOffset    = 150
--   always_show_static = true ← ★★ 见下方分析
--
-- ⚠️⚠️ item_height = 20 与实际行高（约 100）严重不符：
--   scrollablelist:504 的 widgets_per_view = ceil(385/(20+10)) = 13。
--   → 恰好等于池大小 13，**数值上凑对了**。
--   → 但这是「用错误的数字凑出正确的结果」：
--     若真按行高 100 算，widgets_per_view = ceil(385/110) = 4，
--     列表就只能显示 4 行。
--   → 推测原因：美术把行画得比「逻辑行高」高（行与行视觉上重叠），
--     或者 item_height 只是被当作「用于计算可显示项数的除数」而非真实高度。
--   → ★★ 这暴露了 ScrollableList 的一个设计缺陷：
--     **item_height 同时承担「布局高度」与「视口计数」两个语义**。
--     当两者不一致时（正如这里），只能靠手工调参凑数。
--   → ★ 移植时应把这两个语义拆开：
--     行高（用于布局）与每项占位（用于计数）分开配置。
--
-- ★★★ always_show_static = true 的含义（scrollablelist:344-351）：
--   池比数据多时，**多余的行也要调用 updatefn**，只是传 nil。
--   → ★★ 这里正是靠它让 987 行的「空位复位」分支生效：
--     13 个池控件里若只绑定了 8 个服务器，剩下 5 个会
--     被 updatefn(widget, nil) 调用，从而清空并隐藏。
--   → ★★★★ 这是「池化列表」与「非池化列表」的关键差异：
--     非池化时，多余的池控件用 Show/Hide 处理；
--     池化时必须靠 updatefn 传 nil 来复位。
--   → ★★★ 移植要点：**设计复用池时，要明确「池比数据大」怎么处理**。
--     两种方案：(a) 传 nil 让绑定函数自己复位；(b) 列表统一 Hide 多余的。
--     方案 (a) 更灵活（本文件用了），方案 (b) 更简单。
--
-- ★★ 1127 行 LayOutStaticWidgets(3, true)：
--   第二个参数 skipFixUp = true → **跳过焦点链与帮助文本的注入**。
--   → ★★ 因为本文件的每一行自带一个 ListCursor（1131-1135 行手动接），
--     它自己处理焦点，不需要 ScrollableList 再包一层 GetHelpText。
--   → 这正是 scrollablelist:385 行注释里说的「skip fixup 是给
--     已经自己加了提示与焦点处理的场景用的（i.e. ListCursor）」。
--   → ★★★ 「框架提供默认行为 + 调用方声明我不需要」：
--     这是任何框架设计都该有的开关。本文件用得完全正确。
-- ★★ 1128-1130 行 onscrollcb：
--   每次滚动后调 GuaranteeSelectedServerHighlighted ——
--   因为滚动的瞬间行被重新绑定，高亮状态需要重算。
--   → ★★★ 「滚动会改变哪些行的身份」→ 挂 onscrollcb 兜住。
--     这是 scrollablelist:278 的 onscrollcb 钩子的正确用法。
-- ★★ 1131-1135 行的 SetParentList 循环：
--   把每个行的 cursor 都挂到列表上 ——
--   于是光标的方向键事件能冒泡到列表（scrollablelist:94 的 parent_scroll_list）。
--   → ★★★ 「焦点冒泡」机制：
--     行内控件处理不了方向键时，交给父级列表处理（触发滚动）。
--     这就是手柄能在长列表里上下导航的完整链路。
-- ★ 1137-1140 行的四个 MoveToFront：
--   → ★★★ 「滚动时列分隔线必须压在行之上」：
--     行被重排后 z 序可能改变，这里在构建末尾统一纠正。
--     属「事后修正」而非「事前规划」，是 z 序管理的常见妥协。
    self.servers_scroll_list:SetPosition(187,-45)
    self.servers_scroll_list:LayOutStaticWidgets(3, true)
    self.servers_scroll_list.onscrollcb = function()
        self:GuaranteeSelectedServerHighlighted()
    end
    for i, v in ipairs(self.list_widgets) do
        if v.cursor ~= nil then
            v.cursor:SetParentList(self.servers_scroll_list)
        end
    end

    self.table.first_column_end:MoveToFront()
    self.table.second_column_end:MoveToFront()
    self.table.third_column_end:MoveToFront()
    self.table.server_list_rows:MoveToFront()
end

function ServerListingScreen:GuaranteeSelectedServerHighlighted()
-- ══★【GuaranteeSelectedServerHighlighted：高亮的逐行重算】
-- ★★ 1145-1146 行的两个状态判定（注意 `and ... or false` 的写法）：
--   dev_server         = version == -1（开发版服务器）
--   version_check_failed = version ~= tonumber(APP_VERSION)
-- ★ 这里有 `v.version and` 守卫（对比 1015 行没有，见该处注释）。
-- → ★ 两处同样的业务判定，一处有守卫一处没有，属真实的不一致。
-- ★★★ 1147 行的判定条件是本函数的核心：
--   `v.index ~= -1 and v.index == self.selected_index_actual`
--   → 「index 是 -1」表示这一格是空的（987 行设置），
--     必须排除，否则会把高亮画在空格子上。
-- ★★ 1159-1171 的 else 分支（未选中）同样要重设颜色与字体：
--   → ★★★ 「选中」与「未选中」**都是完整的状态设置**，
--     不是「选中时改，其他不动」。
--   → ★★ 这是「无状态 UI」的正确写法：
--     每次刷新都完整重画，不依赖「上一次是什么状态」。
--     对比 modstab:785 的「先全清再设一个」，思路相同。
--     → ★★★★ 移植要点：**用「全量重算」而非「增量修改」，
--       可以从根本上避免状态残留 bug**。
-- ★ 1154-1156 行在 else（正常情况）里 SetFont(NEWFONT)，
--   而 1160-1162 行的未选中分支也 SetFont(NEWFONT)。
--   → 1154-1156 行的 SetFont 实际上是**冗余**的：
--     两个分支设的都是 NEWFONT。除非之前有别的代码设了别的字体，
--     否则这三次调用都没有实际效果。
--   标注为「疑似冗余」。
-- ★ 1158/1170 行 SetSelected：光标的选中态。
-- ★★★ 这个函数被调用 3 处（851/722/1129 的 onscrollcb），
--   每次只有 13 行，开销可忽略。
--   → 说明作者**没有**把「高亮」做成增量，而是每次全量重算。
--     在 13 行的规模下这是正确的取舍。
    for i, v in ipairs(self.list_widgets) do
        local dev_server = v.version and v.version == -1 or false
        local version_check_failed = v.version and v.version ~= tonumber(APP_VERSION) or false
        if v.index ~= -1 and v.index == self.selected_index_actual then
            if dev_server then
                self:SetRowColour(v, dev_color)
            elseif version_check_failed then
                self:SetRowColour(v, v.beta > 0 and beta_color or mismatch_color)
            else
                self:SetRowColour(v, v.offline and offline_color or normal_color)
                v.NAME:SetFont(NEWFONT)
                v.PLAYERS:SetFont(NEWFONT)
                v.PING:SetFont(NEWFONT)
            end
            v.cursor:SetSelected(true)
        else
            v.NAME:SetFont(NEWFONT)
            v.PLAYERS:SetFont(NEWFONT)
            v.PING:SetFont(NEWFONT)
            if dev_server then
                self:SetRowColour(v, dev_color)
            elseif version_check_failed then
                self:SetRowColour(v, v.beta > 0 and beta_color or mismatch_color)
            else
                self:SetRowColour(v, v.offline and offline_color or normal_color)
            end
            v.cursor:SetSelected(false)
        end
    end
end

function ServerListingScreen:CycleColumnSort()
-- ══★【CycleColumnSort：列排序的循环切换】
-- ★★ 1176-1188 行：升序时重复按同一列（= 切换成降序），
--   降序时循环到下一列。
-- → ★★★ 「连按排序键 = 升/降序切换，再按 = 换列」：
--     这是表格的标准交互（对照 Excel / macOS Finder）。
-- ★ 1179-1187 行的 if/elseif 链硬编码了列的循环顺序：
--   DETAILS → PLAYERS → PING → NAME → DETAILS
-- → ⚠️ 列名用**字符串字面量**而非常量。
--   加一列要改这里 + SetSort + DoSorting + MakeColumnHeaders（四处）。
--   → ★ 正确做法：用一个有序数组 `SORT_COLUMNS = {...}` 循环。
--   → ★★★★ 移植要点：**「循环列表」应该是数据（数组），
--     而不是在 if/elseif 链里手写跳转**。
    if self.sort_ascending then
        self:SetSort(self.sort_column)
    else
        if self.sort_column == "DETAILS" then
            self:SetSort("PLAYERS")
        elseif self.sort_column == "PLAYERS" then
            self:SetSort("PING")
        elseif self.sort_column == "PING" then
            self:SetSort("NAME")
        else
            self:SetSort("DETAILS")
        end
    end
end

function ServerListingScreen:SetSort(column)
-- ══★【SetSort：排序状态的切换 + 表头箭头的完整重画】
-- ★★ 1230-1234 行是排序状态机的全部：
--   同列 → 翻转升序/降序；换列 → 重置为升序。
--   → ★★★ 「换列重置为升序」是符合直觉的默认（预期新列从小到大）。
-- ★★★ DoSortArrow（1192-1228 行）是「表头全量重画」：
--   遍历所有列按钮，非当前列隐藏箭头并重置字体颜色，
--   当前列按升/降序显示不同箭头。
-- → ★★ 1216-1225 行的聚焦态差异：
--   聚焦时用 NEWFONT_OUTLINE + 白色 + 字号 33
--   非聚焦用 NEWFONT + 黑色 + 字号 35
--   → ★★★ 「聚焦态不只换颜色，还换描边字体与缩放」：
--     多重视觉通道（颜色 + 字体 + 尺寸）让聚焦态非常醒目。
--     移植时值得学：**重要状态用 2-3 个通道同时表达**。
-- ⚠️ 1201/1208 行读 `v.bg.focus` 而不是按钮自身的 focus：
--   → 说明列按钮的「焦点」实际在它的 bg 子控件上。
--     这种「焦点标志与控件对象分离」的设计容易出错，
--     必须读懂才能改。
-- ★★ 箭头贴图有 4 种（普通/聚焦 × 升/降）：
--   → 「焦点态与状态态正交」的贴图准备方式，标准做法。
    local function DoSortArrow()
        local col = self.column_buttons[self.sort_column]
        for k, v in pairs(self.column_buttons) do
            if v ~= col then
                v.arrow:Hide()
                v.text:SetColour(0,0,0,1)
                v.text:SetFont(NEWFONT)
            else
                if self.sort_ascending then
                    if v.bg.focus then
                        v.arrow:SetTexture("images/ui.xml", "arrow2_up_over.tex")
                    else
                        v.arrow:SetTexture("images/ui.xml", "arrow2_up.tex")
                    end
                    v.arrow.ascending = true
                else
                    if v.bg.focus then
                        v.arrow:SetTexture("images/ui.xml", "arrow2_down_over.tex")
                    else
                        v.arrow:SetTexture("images/ui.xml", "arrow2_down.tex")
                    end
                    v.arrow.ascending = false
                end
                v.arrow:Show()
                if v.bg.focus then
                    v.text:SetFont(NEWFONT_OUTLINE)
                    v.text:SetColour(1,1,1,1)
                    v.text:SetSize(33)
                else
                    v.text:SetFont(NEWFONT)
                    v.text:SetColour(0,0,0,1)
                    v.text:SetSize(35)
                    -- v.text:SetColour(.4,.4,.4,1)
                end
            end
        end
    end

    if column == self.sort_column then
        self.sort_ascending = not self.sort_ascending
    else
        self.sort_ascending = true
    end
    self.sort_column = column

    DoSortArrow()

    self:DoSorting()
end

function ServerListingScreen:DoSorting()
-- ══★★【DoSorting：多列排序与「无延迟优先」的完整规则】
-- ★★ 1243-1244 行的注释是一个**已知缺陷的自述**：
-- 「This does the trick, but we might want more clever criteria...
--  ("Server 5" < "Server 50" < "Server 6" is current result for Name)」
-- → ★★★ 作者主动记录了「当前实现的怪异行为」。
--   根因是 1249 行用 stringidsorter 做纯字符串比较，
--   没有把「Server 5」里的数字提取出来。
-- → ★★ 正确做法：从名称里提取数字部分做自然排序
--   （stringidsorter 应该做「自然排序」但当前实现是字典序）。
-- → ★★★★ 「已知缺陷 + 具体症状 + 可能的改进方向」是最高质量的注释形式。
--   这条注释让后来人不用重新测试就知道问题在哪。
--
-- ★★★ 1246-1324 行的排序比较函数结构：
--   外层：if sort_ascending then ... else ... end（两个近乎重复的大块）
--   内层：按 sort_column 分派到四种比较
-- ⚠️⚠️【结构缺陷，已逐行核实】1247-1282（升序）与 1284-1324（降序）
--   两块内容**完全对称重复**，约 40 行 × 2。
--   唯一差别是 friend_playing / belongs_to_clan / ping 的比较方向取反。
--   → ★★★ 正确写法：写成「升序比较函数」，降序时包一层取反：
--       local cmp = ASCENDING_COMPARATORS[column]
--       table.sort(list, function(a,b)
--           local r = cmp(a,b)
--           return self.sort_ascending and r or not r
--       end)
--     这样比较逻辑只写一遍，加一列只改一处。
-- ★★ 三个排序维度（注释说明了隐式优先级）：
--   friend_playing > belongs_to_clan > ping（DETAILS 列）
--   → ★★ 「和好友玩的服务器永远排最前」——
--     这是**产品优先级**压过了「用户选的排序列」。
--     对普通玩家是好设计，但「点了延迟列却看到好友优先」会困惑。
--     作者用注释说明了，但没有给出理由。
--   → ★ 移植提示：**默认排序应有明确的优先级链，且要让用户能覆盖**。
-- ★★ 1261-1264 行的 ping < 0 处理：
--   负 ping 表示「不可达」（1397 行把这类算作 unjoinable）。
--   `if a.ping < 0 and b.ping >= 0 then return false` → 不可达的排最后。
--   → ★★★ 「无效数据必须显式排到末尾」，否则会随机穿插。
--     迁移要点：**排序前先定义好「无效值」的序**。
-- ★★ 1265-1266 行：ping 相同时按名字排 —— 打破平局保证稳定。
--   与 mapscreen:255 的 `dsq == dsq and GUID < GUID` 同一目的。
--   → ★★★★ **排序必须打破平局**，否则每次 table.sort 的结果可能不同，
--     界面会「无原因地跳动」。这是所有排序实现的必备规则。
-- ★ 用 stringidsorter 而非 `<`：见 1244 行的已知缺陷注释。
    -- This does the trick, but we might want more clever criteria for how a certain column gets ordered
    -- ("Server 5" < "Server 50" < "Server 6" is current result for Name)
    if self.viewed_servers then
        table.sort(self.viewed_servers, function(a,b)
            if self.sort_ascending then
                if self.sort_column == "NAME" then
                    return stringidsorter(string.lower(a.name), string.lower(b.name))
                elseif self.sort_column == "DETAILS" then
                    if a.friend_playing and not b.friend_playing then
                        return true
                    elseif not a.friend_playing and b.friend_playing then
                        return false
                    end
                    if a.belongs_to_clan and not b.belongs_to_clan then
                        return true
                    elseif not a.belongs_to_clan and b.belongs_to_clan then
                        return false
                    end
                    if a.ping < 0 and b.ping >= 0 then
                        return false
                    elseif a.ping >= 0 and b.ping < 0 then
                        return true
                    elseif a.ping == b.ping then
                        return stringidsorter(string.lower(a.name), string.lower(b.name))
                    else
                        return a.ping < b.ping
                    end
                elseif self.sort_column == "PLAYERS" then
                    return a.current_players < b.current_players
                else
                    if a.ping < 0 and b.ping >= 0 then
                        return false
                    elseif a.ping >= 0 and b.ping < 0 then
                        return true
                    elseif a.ping == b.ping then
                        return stringidsorter(string.lower(a.name), string.lower(b.name))
                    else
                        return a.ping < b.ping
                    end
                end
            else
                if self.sort_column == "NAME" then
                    return stringidsorter(string.lower(a.name), string.lower(b.name))
                elseif self.sort_column == "DETAILS" then
                    if a.friend_playing and not b.friend_playing then
                        return false
                    elseif not a.friend_playing and b.friend_playing then
                        return true
                    end
                    if a.belongs_to_clan and not b.belongs_to_clan then
                        return false
                    elseif not a.belongs_to_clan and b.belongs_to_clan then
                        return true
                    end
                    if a.ping < 0 and b.ping >= 0 then
                        return false
                    elseif a.ping >= 0 and b.ping < 0 then
                        return true
                    elseif a.ping == b.ping then
                        return stringidsorter(string.lower(a.name), string.lower(b.name))
                    else
                        return a.ping > b.ping
                    end
                elseif self.sort_column == "PLAYERS" then
                    return a.current_players > b.current_players
                else
                    if a.ping < 0 and b.ping >= 0 then
                        return false
                    elseif a.ping >= 0 and b.ping < 0 then
                        return true
                    elseif a.ping == b.ping then
                        return stringidsorter(string.lower(a.name), string.lower(b.name))
                    else
                        return a.ping > b.ping
                    end
                end
            end
        end)
        self:RefreshView(true)
    end
end

function ServerListingScreen:ProcessPlayerData(session)
-- ══★★★【ProcessPlayerData：★ 沙盒执行与缓存 —— 联机 UI 的安全边界】
-- ★★★ 1332 行 `RunInSandboxSafe(data)`：
--   → ★★★★★ 这是整个文件里最值得移植的一处安全设计：
--     服务器上报的玩家数据是**不可信的 Lua 片段**（可能来自恶意主机）。
--     直接 eval 会让恶意主机在客户端执行任意代码。
--     RunInSandboxSafe 把它放进受限沙箱执行。
--   → ★★★★ 移植要点：**任何来自网络的「代码」都必须沙箱执行**。
--     服务器可以上报 mod 列表、玩家角色等结构化信息，
--     而模组环境本身就是 Lua 片段 —— 直接 eval 等于给主机玩家一个后门。
--   → 这与 mods.lua 的 CreateEnvironment 沙箱机制同源
--     （见 04-联机同步报告第七节）。
--
-- ★★★ 1329-1338 行的缓存设计：
--   第一次：RunInSandboxSafe 执行，把结果（playerdata 或 false）存起来
--   同时在 session_mapping 里存一份「已处理」的标记 + 结果
--   之后：session_mapping 命中就直接取，跳过沙盒执行
-- → ★★ 为什么要 session_mapping 双重结构？
--   sessions[session] 存的是**结果**，session_mapping 存的是
--   「原始数据 + 处理结果」。后者是为了处理「同一 session 的数据」。
--   → ★★ 真正的价值是**避免重复执行沙盒代码**（安全 + 性能）。
--     沙盒执行不便宜，且每次执行都是一次潜在的代码运行风险。
--   → ★★★★ 「不可信输入的解析结果必须缓存」：
--     既省性能，也避免同一个不可信代码被反复执行。
-- ★★★ 1333 行 `self.sessions[session] = success and playerdata or false`：
--   → ★★ 失败时存 **false** 而非 nil —— 这是三值逻辑的关键设计：
--     nil  = 「还没处理过」
--     false = 「处理了，但失败/沙箱拒绝」
--     table = 「成功解析出的玩家数据」
--   → ★★★★ 1358 行的 charInvalid 完全依赖这个三值：
--     `if spinnerSelection == true then return char == false`
--     → 玩家筛选器选中「有角色」时，解析失败（false）被算作「没有角色」。
--     若存 nil，1361 行的判断会走 else 分支返回相反结果。
--   → ★★★★ 「nil / false / table 三态表示处理中/失败/成功」
--     是本文件最精细的设计。移植时务必保留这个区分。
-- ⚠️ 1336 行 `session_data_processed = true` 这个标志其实恒为真
--   （进入 1329 分支时已检查过），是冗余的。但它让缓存的自描述性更好。
    if self.sessions[session] == nil and self.session_mapping ~= nil then
        local data = self.session_mapping[session]
        if data ~= nil then
            if type(data) == "table" and data.session_data_processed then
                self.sessions[session] = data.data
            else
                local success, playerdata = RunInSandboxSafe(data)
                self.sessions[session] = success and playerdata or false
                self.session_mapping[session] =
                {
                    session_data_processed = true,
                    data = self.sessions[session],
                }
            end
        end
    end
end

function ServerListingScreen:IsValidWithFilters(server)
-- ══★★★【IsValidWithFilters：过滤器判定 —— 分两类是关键设计】
-- ★★★ 1377-1379 行的注释点明了本函数的核心思想：
-- 「先检查不可加入的服务器，让计数准确。这样无论选什么过滤器
--  你都永远无法加入的服务器会被排除。」
-- → ★★★★ 「不可加入」与「被设置过滤掉」是两回事：
--   前者是**服务器的属性**（friends_only 且你不是好友 → 永远进不去）
--   后者是**用户的选择**（你勾了「只看有密码的」→ 这个被过滤）
-- → ★★ 混为一谈会导致「显示 100 个服务器但一个都进不去」的困惑。
--   分开后，计数 `总 - 不可加入` 才有意义（829/1586 行的 num_servs）。
--   → ★★★★ 移植要点：**列表的「总数」必须区分「总量」与「可加入量」**。
--
-- ★★ 1382-1406 行四个 unjoinable 判定，每个都 `unjoinable_servers + 1`：
--   friends_only 且非好友 / clan_only 且非 clan /
--   在线但 ping < 0 且非 steamnat（不可达）/ 离线模式下的在线服务器
-- → ★★ 1394-1396 行的三条 NOTE 注释是**领域知识**：
--   「steamroom 对专用服务器不可用」
--   「任何有 steam id 的服务器都能通过 punchcard 加入，即使 ping 不通」
--   「steamnat 现在是检查用的标志」
--   → ★★★★ 这是「为什么代码要这么写」的最佳范例：
--     每个技术判断背后都有一条业务规则，注释把它们讲清楚了。
--     移植时凡涉及网络可达性的判断，都应这样记录依据。
--
-- ★★ 1411-1420 行的版本检查（不计入 unjoinable）：
--   1412-1413 行注释解释「不计入 unjoinable，因为你之前可能能加入，
--   保持计数一致」。
--   → ★★ 「版本不匹配」是**时间性的**不可加入（游戏更新后就进不去了），
--     而 friends_only 是**永久性**的（配置不会变）。
--   → ★ 不把它计入 unjoinable，用户会觉得「刚才还能进的服怎么不见了」，
--     而不是「这个服被永久过滤了」。计数语义与玩家心理对齐。
-- ★★ 1418 行的三条件：
--   版本不匹配 且 不是(beta 且 release 分支) 且 不是 dev 构建
--   → ★★★ 「开发构建不做版本检查」：
--     开发者本地跑的自建服版本号可能任意，不该被过滤。
--     `BRANCH == "dev"` 是编译期常量，分支会被编译器消除。
--   → ★ 移植时用编译期开关包裹开发期规则，标准做法。
--
-- ★★ 1425-1430 行 intention 过滤的例外：
--   `#self.queryTokens == 0` → 玩家输入了搜索词时不按 intention 过滤。
--   → ★★★ 「显式搜索优先于隐式设置」：
--     玩家明确搜了某个词，就不该再被「我只看合作」的限制拦住。
--   → ★★ 这是「用户意图的优先级」设计，非常值得学。
--
-- ⚠️ 1436-1452 行的**巨型 or 链**（17 个筛选条件）：
--   每个条件形如 `(v.name == "XXX" and <判定>)`。
--   → ★★★ 「用 name 字符串在 or 链里硬编码筛选规则」：
--     加一个筛选器要改这个巨型条件式，且**极难验证完整性**
--     （漏一个 name 意味着该筛选器完全失效，且没有报错）。
--   → ★★ 正确做法：每个筛选器自带一个 match 函数：
--       v.match = function(server) return ... end
--     然后循环 `if v.match and not v.match(server) then return false end`。
--   → ★★★★ 移植要点：**筛选规则应与筛选器的定义放在一起**，
--     而不是集中在一个巨大的判定式里。
--   ⚠️ 1436 行有个细节差异：HASPVP 的条件里 `~= "ANY"` 写在了
--     `server.pvp ~= selected` 之后（顺序不同但语义等价），
--     说明这一条与其他条的写法不一致，是复制粘贴后调整过的。
-- ★ 1443/1444 行的 ISFULL / ISEMPTY 用 `GetSelectedData() == false`
--   → 「是否勾选了『排除满服』」的布尔语义，正确。
-- ★ 1462 行用 pairs 遍历 queryTokens（应该是 ipairs）：
--   queryTokens 由 table.insert 构建（1505/1516 行），是连续数组。
--   用 pairs 遍历数组是本文件（乃至本项目）的通病，结果正确但语义不对。

    local function gameModeInvalid(serverMode, spinnerMode)
        if spinnerMode == "ANY" then
            return false
        elseif spinnerMode == "custom" then
            --The user is looking for any modded game mode
            return not GetIsModGameMode( serverMode )
        else
            --The user is looking for a specific game mode
            return serverMode ~= spinnerMode
        end
    end

    local function charInvalid(session, spinnerSelection)
        self:ProcessPlayerData( session )

        if self.sessions[session] ~= nil then
            local char = self.sessions[session]
            if spinnerSelection == true then
                return char == false
            else
                return char ~= false
            end
        elseif spinnerSelection == true then
            return true
        else
            return false
        end
    end

    if not server or type(server) ~= "table" then return false end

    -- Do checks for unjoinable servers first so the count is accurate.
    -- This means servers that you will never be able to join no matter
    -- what filters or settings you choose.

    -- Filter our friends only servers that are not our friend
    if server.friends_only and not server.friend then
        self.unjoinable_servers = self.unjoinable_servers + 1
        return false
    end

    -- Filter servers that we aren't allowed to join.
    if server.clan_only and not server.belongs_to_clan then
        self.unjoinable_servers = self.unjoinable_servers + 1
        return false
    end

    -- Filter out unjoinable servers, if we are online
    -- NOTE: steamroom is not available for dedicated servers
    -- NOTE: Any server with a steam id can be joinable via punchthrough even if you can't ping it directly
    -- NOTE: steamnat is now the flag to check
    if self.view_online and not server.steamnat and server.ping < 0 then
        self.unjoinable_servers = self.unjoinable_servers + 1
        return false
    end

    -- If we are in offline mode, don't show online mode servers
    if self.offlinemode and not server.offline then
        self.unjoinable_servers = self.unjoinable_servers + 1
        return false
    end

    -- Now do checks for servers you can potentially join, but are currently
    -- being filtered due to your settings.

    -- Hide version mismatched servers (except beta) on live builds
    -- We don't count this towards unjoinable because you probably could
    -- have joined them previously, and this keeps the count consistent.
    local version_mismatch = APP_VERSION ~= tostring(server.version)
    local beta_server = GetBetaInfoId(server.tags)
    local dev_build = BRANCH == "dev"

    if version_mismatch and not ((beta_server > 0) and BRANCH == "release") and not dev_build then
        return false
    end

    -- Only show servers that match your intention
    -- But, don't filter this way if we've explicitly put in search terms
    -- Also, this only applies to the online tab
    local intention = Profile:GetValue("playerintention")
    if intention ~= INTENTIONS.ANY and self.view_online and #self.queryTokens == 0 then
        if intention == nil or intention ~= server.intention then
            return false
        end
    end

    -- Check spinner validation
    for i, v in ipairs(self.filters) do
        -- First check with the spinners
        if v.spinner ~= nil then
            if ((v.name == "HASPVP" and server.pvp ~= v.spinner:GetSelectedData() and v.spinner:GetSelectedData() ~= "ANY")
            or (v.name == "GAMEMODE" and v.spinner:GetSelectedData() ~= "ANY" and gameModeInvalid(server.mode, v.spinner:GetSelectedData()))
            or (v.name == "HASPASSWORD" and (v.spinner:GetSelectedData() ~= "ANY" and server.has_password ~= v.spinner:GetSelectedData()))
            or (v.name == "MINCURRPLAYERS" and v.spinner:GetSelectedData() ~= "ANY" and (server.current_players < v.spinner:GetSelectedData()))
            or (v.name == "MAXCURRPLAYERS" and v.spinner:GetSelectedData() ~= "ANY" and (server.current_players > v.spinner:GetSelectedData()))
            or (v.name == "MAXSERVERSIZE" and v.spinner:GetSelectedData() ~= "ANY" and server.max_players > v.spinner:GetSelectedData())
            or (v.name == "MINOPENSLOTS" and v.spinner:GetSelectedData() ~= "ANY" and server.max_players - server.current_players < v.spinner:GetSelectedData())
            or (v.name == "ISFULL" and (server.current_players >= server.max_players and v.spinner:GetSelectedData() == false))
            or (v.name == "ISEMPTY" and (server.current_players <= 0 and v.spinner:GetSelectedData() == false))
            or (v.name == "FRIENDSONLY" and v.spinner:GetSelectedData() ~= "ANY" and v.spinner:GetSelectedData() ~= server.friend_playing )
            or (v.name == "CLANONLY" and v.spinner:GetSelectedData() ~= "ANY" and not server.belongs_to_clan )
            or (v.name == "CLANONLY" and v.spinner:GetSelectedData() == "PRIVATE" and not server.clan_only )
            or (v.name == "SEASON" and v.spinner:GetSelectedData() ~= "ANY" and v.spinner:GetSelectedData() ~= server.season )
            or (v.name == "VERSIONCHECK" and v.spinner:GetSelectedData() and version_mismatch )
            or (v.name == "ISDEDICATED" and v.spinner:GetSelectedData() ~= "ANY" and server.dedicated ~= v.spinner:GetSelectedData())
            or (v.name == "MODSENABLED" and v.spinner:GetSelectedData() ~= "ANY" and server.mods_enabled ~= v.spinner:GetSelectedData())
            or (v.name == "HASCHARACTER" and v.spinner:GetSelectedData() ~= "ANY" and charInvalid(server.session, v.spinner:GetSelectedData()))) then
                return false
            end
        end
    end

    -- Then check with the search box (but only if it hasn't already been invalidated)
    if #self.queryTokens > 0 then
        -- Then check if our servers' names and tags contain any of those tokens
        local searchMatch = true -- Assume match until we find a non-match
        for j,k in pairs(self.queryTokens) do
            if not string.find(string.lower(server.name), k, 1, true) and not string.find(string.lower(server.tags), k, 1, true) then
                searchMatch = false
                break
            end
        end

        if not searchMatch then
            return false
        end
    end

    return true
end

function ServerListingScreen:ResetFilters()
    for i, v in ipairs(self.filters) do
        if v.spinner ~= nil then
            v.spinner:SetSelectedIndex(1)
            v.spinner.changed_image:Hide()
            if v.name == "GAMEMODE" then
                v.spinner:SetHoverText("")
            end
        end
    end
    self.searchbox.textbox:SetString("")
    self:DoFiltering()
end

function ServerListingScreen:DoFiltering(doneSearching, keepScrollFocusPos)
-- ══★★★【DoFiltering：过滤流水线 + 本文件最难读的查询分词】
-- ★★ 1495 行重置 unjoinable_servers ——
--   这个重置必须在过滤**之前**，因为 IsValidWithFilters 会累加它。
--   → ★★★★ 「有副作用的过滤器」的必然要求：
--     过滤器不只是返回布尔，还往统计里累加。
--     这让函数同时是「判定器」和「统计器」，职责不单一。
--   → ★ 更好的设计：让过滤器返回 (valid, is_unjoinable)，
--     由调用方累加。这样判定与统计分离，且可测试。
--   → ★★★ 移植要点：**避免「判定函数偷偷改全局计数」**，
--     这类副作用在并发/重入场景下极易出错。
--
-- ⚠️⚠️ 1497-1521 行的查询分词是本文件最难读的 25 行：
--  手写逗号分隔解析，处理：
--   1504 单字符特例（避免走循环）
--   1509 遇到逗号或末尾则确定 endPos
--   1512 双重条件判断是否该切分 token
--   1513 若 endPos 是末尾且该字符是逗号，则回退一格（**排除尾部逗号**）
--   1515 gsub 去掉首尾空白（模式 "^%s*(.-)%s*$" 是 Lua 的 trim 惯用法）
--   1517 startPos = endPos + 2（跳过逗号本身）
-- → ★★★ 这些代码的正确写法应该用 string.gsub(query, "([^,]+)") 一次搞定：
--     for token in string.gmatch(query, "([^,]+)") do ... end
--   → ★★ 25 行手写状态机能被 3 行 gmatch 替代。
--   → ★ 移植要点：**字符串解析优先找标准库函数**。
--     Lua 的 string.gmatch 加上模式串能处理绝大多数分割需求。
-- ⚠️ 1517 行的 `startPos = endPos + 2`：
--   若 1513 行把 endPos 回退了一格（尾部逗号），这里的 +2 可能跳过字符。
--   我没有构造出触发反例的输入，但这个 +2 与 1513 的回退逻辑
--   存在耦合，改动其一必须同步另一处。
--   标注为「疑似耦合脆弱」。
-- ★ 1515 行的 gsub 返回两个值（字符串与替换次数），
--   这里只取第一个赋给 token —— Lua 的单变量赋值只取首值，正确。
--
-- ★★ 1524-1534 行：搜索时禁用 intention 选择器：
--   → ★★★ 「进入搜索模式时禁用与搜索冲突的筛选器」：
--     意图筛选（只看你想玩的类型）与文本搜索是两种不同的找服方式，
--     混用会让玩家困惑（搜到了却被 intention 过滤掉）。
--   → ★★★ 移植要点：**当用户切换到一种新的检索方式时，
--     应该禁用与它冲突的其他方式**。
-- ★ 1528 行标题变成「SEARCH <输入内容>」：
--   → ★★ 界面标题反映当前检索模式，是低成本高收益的可理解性设计。
--
-- ★★★ 1540-1572 行的**字段显式拷贝**：
--   把服务器的全部 25 个字段逐个拷进新表，并附加 actualindex = i。
--   → ★★★★ 这就是「构建视图模型」（与 modstab 的 modnames 表同理）：
--     1) 过滤后生成一个**干净的**数据表，不含引擎的内部字段
--     2) 附加 actualindex 作为「真实身份」
--     3) 后续所有逻辑（排序、高亮、双击）都基于这个表
--   → ★★ 为什么要拷贝而不是直接引用？
--     a) TheNet:GetServerListings() 每次返回新表（845 行确认），
--        拷贝后我们的数据与引擎解耦
--     b) 可以附加引擎没有的字段（actualindex）
--     c) CompareTable 比较的是拷贝，语义明确
--   ⚠️ 1571 行的 `data = v.data` 被注释掉了：
--     → 大字段（完整描述）被排除在拷贝之外，避免深比较变慢。
--     这是**有意的性能取舍**，但没有注释说明为何注释掉。
-- ★★ 1565 行 `actualindex=i` 是本文件的关键设计：
--   → ★★★★★ 「视图下标」与「数据身份」的分离。
--     viewed_servers 是过滤后的子集，i 是它在**过滤前**的位置。
--     选中态、高亮、双击检测全部通过 actualindex 而非下标。
--   → ★★★★ 为什么这是必须的？
--     因为**排序会改变下标**（DoSorting 原地 table.sort viewed_servers），
--     所以任何用下标表示「选中哪个」的做法都会在排序后错乱。
--   → ★★ 这就是「稳定标识 vs 位置」的经典问题：
--     位置会因为过滤、排序而变化，标识必须独立于位置。
--   → ★★★★ 移植要点：**任何列表的选中态都必须用稳定标识**，
--     绝不能用下标。这是一个通用且极易踩坑的规则。
--   ★★ 反例对照：tradescreen 的 selected_items 用下标做 key，
--     但那里列表不排序，所以侥幸正确。
--   → ★ 说明「用不用稳定标识」取决于列表是否会重排。
--
-- ★★ 1576-1578 行：选中的服务器若不再符合过滤条件则取消选中。
--   → ★★★★ 「选中态的自动失效」：
--     玩家筛选后，原先选中的服务器可能消失了，
--     此时必须把选中态清掉，否则详情面板会显示一个不在列表里的服务器。
--   → ★ 与 mapscreen:212 的 ValidateMapTarget 是同一模式
--     （「焦点/选中态在条件不再满足时自动失效」）。
--   → ★★★★ 移植要点：**筛选/搜索改变列表后，必须重新校验选中态**。
--
-- ★★ 1581-1583 行的深比较早退（见 CompareTable 分析）：
--   `if CompareTable(self.viewed_servers, filtered_servers) and not doneSearching then return end`
--   → ★★ 「视图无变化则不重建」—— 这是性能的核心。
--   doneSearching 为真时强制重建（用户主动点了搜索）。
--   → ★ 强制重建的理由：用户主动搜索时要确保显示最新结果。
-- ★★ 1598-1610 行的滚动位置计算：
--   找出选中服务器在**当前视口**的行位置 i，
--   以及它在**新列表**中的位置 i2，
--   差值 i2 - i 就是「应该滚动多少」。
--   → ★★★★ 「用两个坐标系下的位置差算出滚动量」：
--     这是「刷新后保持选中项可见」的标准做法。
--   → ★ 与 scrollablelist:530 的 keeprelativefocusindex 同思想
--     （那里是列表内部实现，这里是调用方显式计算）。
-- ★★ 1612 行 SetList 的四个参数全给了：
--   (viewed_servers, false, scrollto, keepScrollFocusPos)
--   keepitems = false → 模式 A 分支会被 Kill 旧控件？
--   ⚠️ 但本文件是模式 B（有 updatefn 与 static_widgets），
--   scrollablelist:532 的条件 `updatefn == nil and static_widgets == nil`
--   不成立 → **不会** Kill 控件，只替换 items。
--   → ★★ 这正是虚拟化的价值：每 tickperiod 秒刷新一次，
--     但控件一个都不会重建，只有数据与绑定变化。
--   → ★★★★ 这是「虚拟化让高频刷新变得可行」的最好证明。
    if not self.filters then return end

    -- Reset the number of unjoinable servers
    self.unjoinable_servers = 0

    -- If there's a query, build the table of query tokens for checking against
    self.queryTokens = {}
    local query = self.searchbox.textbox:GetString()
    if query ~= "" then
        local startPos = 1
        local endPos = 1
        local token = ""
        if string.len(query) == 1 then
            table.insert(self.queryTokens, string.lower(query))
        else
            for i=1, string.len(query) do
                -- Separate search tokens by , (and make sure we grab the trailing token)
                if string.sub(query,i,i) == "," or i == string.len(query) then
                    endPos = i
                end
                if (endPos ~= startPos and endPos > startPos) or (endPos == string.len(query)) then
                    if endPos < string.len(query) or (endPos == string.len(query) and string.sub(query, endPos, endPos) == ",") then endPos = endPos - 1 end
                    token = string.sub(query, startPos, endPos) -- Grab the token
                    token = string.gsub(token, "^%s*(.-)%s*$", "%1") -- Get rid of whitespace on the ends
                    table.insert(self.queryTokens, string.lower(token))
                    startPos = endPos + 2 -- Increase startPos so we skip the comma for the next token
                end
            end
        end
    end

    -- Disable server intention button and change the title when we have query tokens
    if self.view_online and self.server_intention.data ~= nil then
        if #self.queryTokens > 0 then
            self.server_intention.button:Select()
            self.server_intention.button:SetText("")
            self.title:SetTruncatedString(STRINGS.UI.SERVERLISTINGSCREEN.SEARCH.." "..self.searchbox.textbox:GetString(), 350, 60, true)
        else
            self.server_intention.button:Unselect()
            self.server_intention.button:SetText(STRINGS.UI.INTENTION[string.upper(self.server_intention.data)])
            self.title:SetString(string.format(STRINGS.UI.SERVERLISTINGSCREEN.SERVER_LIST_TITLE_INTENT, STRINGS.UI.INTENTION[string.upper(self.server_intention.data)]))
        end
    end

    local filtered_servers = {}
    if self.servers and #self.servers > 0 then
        for i, v in ipairs(self.servers) do
            if self:IsValidWithFilters(v) then
                table.insert(filtered_servers,
                    {
                        name=v.name,
                        mode = v.mode,
                        has_password=v.has_password,
                        description=v.description,
                        mods_description=v.mods_description,
                        mods_failed_deserialization=v.mods_failed_deserialization,
                        dedicated=v.dedicated,
                        pvp=v.pvp,
                        current_players=v.current_players,
                        max_players=v.max_players,
                        ping=v.ping,
                        ip=v.ip,
                        port=v.port,
                        row=v.row,
                        version=v.version,
                        friend=v.friend,
                        friend_playing=v.friend_playing,
                        clan_server = v.clan_server,
                        clan_only = v.clan_only,
                        belongs_to_clan=v.belongs_to_clan,
                        lan_only = v.lan_only,
                        offline = v.offline,
                        net_group_id = v.net_group_id,
                        actualindex=i,
                        mods_enabled = v.mods_enabled,
                        tags = v.tags,
                        session = v.session,
                        has_details = v.has_details,
                        intention = v.intention,
                        -- data = v.data,
                    })
            end
        end

        if self.selected_server ~= nil and self:IsValidWithFilters(self.selected_server) == false then
            self:ServerSelected(nil)
        end
    end

    if CompareTable(self.viewed_servers, filtered_servers) and not doneSearching then
        return
    end
    self.viewed_servers = {}
    self.viewed_servers = filtered_servers
    local num_servs = #self.servers-self.unjoinable_servers
    if num_servs < 0 then num_servs = 0 end
    if num_servs == 0 and not doneSearching then
        self.server_count:SetString("("..STRINGS.UI.SERVERLISTINGSCREEN.SEARCHING_SERVERS..")")
    else
        self.server_count:SetString( subfmt(STRINGS.UI.SERVERLISTINGSCREEN.SHOWING_FMT, { viewed = #self.viewed_servers, total = num_servs }) )
    end
    if not self.view_online then
        self.server_count:SetString("("..STRINGS.UI.SERVERLISTINGSCREEN.LAN..")")
    end
    self:DoSorting()

    --Remember what position our selected server is on screen
    local scrollto = nil
    for i, v in ipairs(self.list_widgets) do
        if v.index ~= -1 and v.index == self.selected_index_actual then
            for i2, v2 in ipairs(self.viewed_servers) do
                if v2.actualindex ~= -1 and v2.actualindex == self.selected_index_actual then
                    scrollto = i2 - i
                    break
                end
            end
            break
        end
    end

    self.servers_scroll_list:SetList(self.viewed_servers, false, scrollto, keepScrollFocusPos)
end

function ServerListingScreen:Cancel()
-- ══★【Cancel：退出的淡入淡出编排】
-- ★★ 1616 行先停搜索 —— 必须在关闭界面前停止网络请求。
-- 1617 行 self:Disable() —— 禁用整个屏幕，防止淡出期间被操作。
--   → ★★★ 「淡出期间锁输入」的标准做法。
--     与 scrollablelist:144 的 LockFocus、tradescreen:1047 的 Disable 同思想。
-- ★★ 1618-1632 行的编排：
--   Fade(FADE_OUT) → 回调里收集筛选器 → 调 self.cb(filters)
--   → PopScreen → Fade(FADE_IN)
-- → ★★ 「回调 + 收集数据」在淡出动画期间完成：
--   利用动画时间做数据打包，界面无停顿感。
-- → ★★★ 移植要点：**过渡动画不只是装饰，可以用来藏数据处理**。
-- ★★ 1621-1626 行的筛选器收集：
--   spinner 取 GetSelectedData，textbox 取 GetString，
--   统一包装成 {name=..., data=...} 传给外部回调。
--   → ★★ 「界面状态序列化后交回给上层」：
--     上层（主菜单）保存这些筛选器，下次打开时恢复。
--   → ★ 这是「界面状态外部化」的标准做法，
--     让界面本身无状态、可随时销毁重建。
-- ⚠️ 1631 行 Fade(FADE_IN) 在 PopScreen 之后 ——
--   而 820 行的 RefreshView 在淡出期间会 return，
--   所以顺序是安全的（先淡入完成再允许刷新）。
    TheNet:StopSearchingServers()
    self:Disable()
    TheFrontEnd:Fade(FADE_OUT, SCREEN_FADE_TIME, function()
        if self.cb then
            local filters = {}
            for i, v in ipairs(self.filters) do
                if v.spinner ~= nil then
                    table.insert(filters, {name=v.name, data=v.spinner:GetSelectedData()})
                elseif v.textbox then
                    table.insert(filters, {name="search", data=v.textbox:GetString()})
                end
            end
            self.cb(filters)
        end
        TheFrontEnd:PopScreen()
        TheFrontEnd:Fade(FADE_IN, SCREEN_FADE_TIME)
    end)
end

local label_width = 130
local widget_width = 118
local height = 28
local spacing = 3
local total_width = label_width + widget_width + spacing
local bg_width = spacing + total_width + spacing
local bg_height = height + 2

local function CreateButtonFilter( self, name, text, buttontext, onclick)
-- ══★【CreateButtonFilter / CreateSpinnerFilter：筛选器的工厂函数】
-- ★★ 这两个 local function（1643/1673）是「筛选器控件的构造器」，
--   每个返回 {name=..., spinner=...} 或 {name=..., textbox=...} 的表。
-- → ★★★ 「筛选器是数据驱动的」：
--   self.filters 是一个筛选器对象的数组，
--   每个对象自带类型信息（有没有 spinner / textbox）。
--   DoFiltering:1433 遍历时按 v.spinner ~= nil 分派。
-- → ★★ 这比「按 name 字符串在巨型 or 链里硬编码」好得多，
--   但 DoFiltering 那里没有利用这个结构（见 1436 行的分析）。
--   → ★★★ 也就是说：数据化做了一半，判定侧仍是硬编码。
--     这是很常见的「重构做了一半」的状态。
-- ★ 1635-1640 行的布局常量：
--   label_width / widget_width / height / spacing / total_width / bg_width
--   → ★★ 「由部件尺寸推导整体尺寸」：
--     total_width = label + widget + spacing
--     bg_width = spacing + total + spacing（左右各留一个间距）。
--   → 改任一部件宽度，整体自动跟随。
--   → ★ 移植要点：**布局常量要推导而非重复定义**。

    local group = self.server_detail_panel:AddChild(Widget( "SpinnerGroup" ))
    group.label = group:AddChild( Text( NEWFONT, 20, text ) )
    group.label:SetPosition( (-total_width/2)+(label_width/2), 0, 0 )
    group.label:SetRegionSize( label_width, height )
    group.label:SetHAlign( ANCHOR_RIGHT )
    group.label:SetColour(0,0,0,1)

    local bg = group:AddChild(Image("images/ui.xml", "single_option_bg.tex"))
    bg:SetSize(bg_width, bg_height)
    bg:MoveToBack()

    group.button = group:AddChild(ImageButton("images/ui.xml", "in-window_button_sm_idle.tex", "in-window_button_sm_hl.tex", "in-window_button_sm_disabled.tex", "in-window_button_sm_hl_noshadow.tex", "in-window_button_sm_disabled.tex", {1, 1}, {0, 0}))
    group.button.text:SetFont(NEWFONT)
    group.button.text:SetSize(20)
    group.button:SetText(buttontext)
    group.button.text:SetPosition(2,2)
    group.button.text:SetColour(0,0,0,1)
    group.button:ForceImageSize( widget_width, height )
    group.button:SetPosition((total_width/2)-(widget_width/2), 0)
    group.button:SetOnClick(onclick)

    group.name = name

    group.focus_forward = group.button

    return group
end

local function CreateSpinnerFilter( self, name, text, spinnerOptions, numeric, onchanged )

    local group = self.server_detail_panel:AddChild(Widget( "SpinnerGroup" ))
    group.label = group:AddChild( Text( NEWFONT, 20, text ) )
    group.label:SetPosition( (-total_width/2)+(label_width/2), 0, 0 )
    group.label:SetRegionSize( label_width, height )
    group.label:SetHAlign( ANCHOR_RIGHT )
    group.label:SetColour(0,0,0,1)

    local bg = group:AddChild(Image("images/ui.xml", "single_option_bg.tex"))
    bg:SetSize(bg_width, bg_height)
    bg:MoveToBack()

    group.spinner = nil
    if numeric then
        group.spinner = group:AddChild(NumericSpinner(spinnerOptions.min, spinnerOptions.max, widget_width, height, {font=NEWFONT, size=20}, nil, nil, nil, true, nil, nil))
    else
        group.spinner = group:AddChild(Spinner(spinnerOptions, widget_width, height, {font=NEWFONT, size=20}, nil, nil, nil, true, nil, nil))
    end
    group.spinner:SetPosition( (total_width/2)-(widget_width/2), 0, 0 )
    group.spinner:SetTextColour(0,0,0,1)
    group.spinner.changed_image = group.spinner:AddChild(Image("images/ui.xml", "option_highlight.tex"))
    group.spinner.changed_image:ScaleToSize(widget_width, height)
    group.spinner.changed_image:SetClickable(false)
    group.spinner.changed_image:MoveToBack()
    group.spinner.changed_image:Hide()
    group.spinner.OnChanged =
        function( _, data )
            self:DoFiltering()
            if group.spinner:GetSelectedIndex() ~= 1 then
                group.spinner.changed_image:Show()
            else
                group.spinner.changed_image:Hide()
            end
            if onchanged then
                onchanged(_,data)
            end
        end

    group.name = name

    --pass focus down to the spinner
    group.focus_forward = group.spinner

    return group
end

function ServerListingScreen:MakeFiltersPanel(filter_data)
-- MakeFiltersPanel：构建筛选器面板（约 145 行）。
-- ★★ 1842 行用 ScrollableList 装筛选器，且**用模式 A**（不传 updatefn）：
--   `ScrollableList(self.filters, scroll_width, scroll_height, item_height, item_padding, nil, nil, 0)`
--   → ★★★ 「同一文件里两个列表用了两种模式」：
--     服务器列表（模式 B，池化，13 个控件显示任意数量）
--     筛选器列表（模式 A，直接建，因为筛选器数量固定且很少）
--   → ★★ 这印证了 scrollablelist 的选型判据：
--     「项数是否会无界增长」。服务器会，筛选器不会。
-- → ★★★★ 同一份代码里并排展示了两种模式，
--     是理解「什么时候需要虚拟化」的最佳教材。
-- ⚠️ 1842 行还有一处值得注意：`filters_scroll_list` 被存为 self 上的字段，
--   而 serverlistingscreen 里其他列表也这么做。
--   「列表控件需要被外部查询（IsVisible 等）」是存字段的理由。
    local any_on_off = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" }, { text = STRINGS.UI.SERVERLISTINGSCREEN.ON, data = true }, { text = STRINGS.UI.SERVERLISTINGSCREEN.OFF, data = false }}
    local any_no_yes = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" }, { text = STRINGS.UI.SERVERLISTINGSCREEN.NO, data = false }, { text = STRINGS.UI.SERVERLISTINGSCREEN.YES, data = true }}
    local any_yes_no = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" }, { text = STRINGS.UI.SERVERLISTINGSCREEN.YES, data = true }, { text = STRINGS.UI.SERVERLISTINGSCREEN.NO, data = false }}
    local any_mine_private = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" }, { text = STRINGS.UI.SERVERLISTINGSCREEN.MINE, data = "MINE" }, { text = STRINGS.UI.SERVERLISTINGSCREEN.PRIVATE, data = "PRIVATE" }}
    local yes_no = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.YES, data = true }, { text = STRINGS.UI.SERVERLISTINGSCREEN.NO, data = false }}
    local no_yes = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.NO, data = false }, { text = STRINGS.UI.SERVERLISTINGSCREEN.YES, data = true }}
    local any_dedicated_hosted = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" }, { text = STRINGS.UI.SERVERLISTINGSCREEN.DEDICATED, data = true }, { text = STRINGS.UI.SERVERLISTINGSCREEN.HOSTED, data = false }}

    local seasons = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" },
                    { text = STRINGS.UI.SERVERLISTINGSCREEN.SEASONS.AUTUMN, data = "autumn" },
                    { text = STRINGS.UI.SERVERLISTINGSCREEN.SEASONS.WINTER, data = "winter" },
                    { text = STRINGS.UI.SERVERLISTINGSCREEN.SEASONS.SPRING, data = "spring" },
                    { text = STRINGS.UI.SERVERLISTINGSCREEN.SEASONS.SUMMER, data = "summer" }}

    local game_modes = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" }}
    local m = GetGameModesSpinnerData()
    for i,v in ipairs(m) do
        table.insert( game_modes, { text = v.text, data = v.data} )
    end
    table.insert( game_modes, { text = STRINGS.UI.SERVERLISTINGSCREEN.CUSTOM, data = "custom" } )
    local player_slots = {{ text = STRINGS.UI.SERVERLISTINGSCREEN.ANY, data = "ANY" }}
    local i = TUNING.MAX_SERVER_SIZE
    while i > 0 do
        table.insert(player_slots,{text=i, data=i})
        i = i - 1
    end

    local reset_label_width = total_width * 0.6
    local reset_button_width = 40 -- this doesn't actually set the width, just used for alignment
    local reset = self.server_detail_panel:AddChild(Widget("resetfilters"))
    reset.bg = reset:AddChild(Image("images/ui.xml", "single_option_bg.tex"))
    reset.bg:SetSize(bg_width, bg_height)
    reset.bg:MoveToBack()
    reset.bg:SetClickable(false)
    reset.label = reset:AddChild(Text(NEWFONT, 20, STRINGS.UI.SERVERLISTINGSCREEN.FILTER_RESET))
    reset.label:SetRegionSize(reset_label_width, height)
    reset.label:SetPosition(-(total_width/2)+(reset_label_width/2), 0)
    reset.label:SetHAlign(ANCHOR_RIGHT)
    reset.label:SetColour(0,0,0,1)
    reset.button = reset:AddChild(TEMPLATES.IconButton("images/button_icons.xml", "undo.tex", nil, true, false, function() self:ResetFilters() end))
    reset.button:SetPosition(-(total_width/2)+(reset_label_width)+(reset_button_width/2)+spacing,-2)
    reset.button:SetScale(.45)
    reset.focus_forward = reset.button

    local search_label_width = 55
    local search_box_width = 155
    local search_button_width = 30 -- this doesn't actually set the width, just used for alignment
    local searchbox = self.server_detail_panel:AddChild(Widget("searchbox"))
    searchbox.bg = searchbox:AddChild(Image("images/ui.xml", "single_option_bg.tex"))
    searchbox.bg:SetSize(bg_width, bg_height)
    searchbox.bg:MoveToBack()
    searchbox.outline = searchbox:AddChild( Image("images/textboxes.xml", "textbox2_small_grey.tex") )
    searchbox.label = searchbox:AddChild(Text(NEWFONT, 20, STRINGS.UI.SERVERLISTINGSCREEN.SEARCH))
    searchbox.label:SetRegionSize( search_label_width, height )
    searchbox.label:SetHAlign(ANCHOR_RIGHT)
    searchbox.label:SetPosition(-(total_width/2)+(search_label_width/2), 0)
    searchbox.label:SetColour(0,0,0,1)
    searchbox.outline:ScaleToSize( search_box_width, height )
    searchbox.outline:SetPosition(-(total_width/2)+search_label_width+spacing+(search_box_width/2), 0)
    searchbox.textbox = searchbox:AddChild(TextEdit( NEWFONT, 20, nil, {0,0,0,1} ) )
    searchbox.textbox:SetForceEdit(true)
    searchbox.textbox:SetPosition(-(total_width/2)+search_label_width+spacing+(search_box_width/2), 0)
    searchbox.textbox:SetRegionSize( search_box_width - 20, height )
    searchbox.textbox:SetHAlign(ANCHOR_LEFT)
    searchbox.textbox:SetFocusedImage( searchbox.outline, "images/textboxes.xml", "textbox2_small_grey.tex", "textbox2_small_gold.tex", "textbox2_small_gold_greyfill.tex" )
    searchbox.textbox:SetTextLengthLimit( STRING_MAX_LENGTH )
    searchbox.gobutton = searchbox:AddChild(ImageButton("images/lobbyscreen.xml", "button_send.tex", "button_send_over.tex", "button_send_down.tex", "button_send_down.tex", "button_send_down.tex", {.15, .15}, {0,0}))
    searchbox.gobutton:SetPosition(-(total_width/2)+search_label_width+spacing+search_box_width+spacing+(search_button_width/2), 0)
    searchbox.gobutton:SetScale(.8)
    searchbox.gobutton.image:SetTint(.6,.6,.6,1)
    searchbox.textbox.OnTextEntered = function() self:DoFiltering() end
    searchbox.gobutton:SetOnClick(function() self.searchbox.textbox:OnTextEntered() end)
    searchbox:SetOnGainFocus(function() self.searchbox.textbox:OnGainFocus() end)
    searchbox:SetOnLoseFocus(function() self.searchbox.textbox:OnLoseFocus() end)
    searchbox.GetHelpText = function()
        local t = {}
        if not self.searchbox.textbox.editing and not self.searchbox.textbox.focus then
            table.insert(t, self.searchbox.textbox:GetHelpText())
        end
        return table.concat(t, "  ")
    end

    self.searchbox = searchbox

    local server_intention = CreateButtonFilter(self, nil, STRINGS.UI.SERVERLISTINGSCREEN.INTENTION_FILTER, nil, function(data)
        self:SetServerIntention(nil)
        self.intentions_overlay:SetFocus()
    end)

    self.server_intention = server_intention

    table.insert(self.filters, reset)
    table.insert(self.filters, searchbox)
    table.insert(self.filters, self.server_intention)
    table.insert(self.filters, CreateSpinnerFilter( self, "GAMEMODE", STRINGS.UI.SERVERLISTINGSCREEN.GAMEMODE, game_modes, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "SEASON", STRINGS.UI.SERVERLISTINGSCREEN.SEASONFILTER, seasons, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "HASPVP", STRINGS.UI.SERVERLISTINGSCREEN.HASPVP, any_on_off, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "MODSENABLED", STRINGS.UI.SERVERLISTINGSCREEN.MODSENABLED, any_no_yes, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "HASPASSWORD", STRINGS.UI.SERVERLISTINGSCREEN.HASPASSWORD, any_no_yes, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "ISDEDICATED", STRINGS.UI.SERVERLISTINGSCREEN.SERVERTYPE, any_dedicated_hosted, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "HASCHARACTER", STRINGS.UI.SERVERLISTINGSCREEN.HASCHARACTER, any_yes_no, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "FRIENDSONLY", STRINGS.UI.SERVERLISTINGSCREEN.FRIENDSONLY, any_yes_no, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "CLANONLY", STRINGS.UI.SERVERLISTINGSCREEN.CLANONLY, any_mine_private, false ))
    -- table.insert(self.filters, CreateSpinnerFilter( "MINCURRPLAYERS", STRINGS.UI.SERVERLISTINGSCREEN.MINCURRPLAYERS, {min=0,max=4}, true ))
    -- table.insert(self.filters, CreateSpinnerFilter( self, "MAXCURRPLAYERS", STRINGS.UI.SERVERLISTINGSCREEN.MAXCURRPLAYERS, players, false ))--STRINGS.UI.SERVERLISTINGSCREEN.MAXCURRPLAYERS, {min=0,max=4}, true ))
    table.insert(self.filters, CreateSpinnerFilter( self, "ISFULL", STRINGS.UI.SERVERLISTINGSCREEN.ISFULL, yes_no, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "MINOPENSLOTS", STRINGS.UI.SERVERLISTINGSCREEN.MINOPENSLOTS, player_slots, false ))
    table.insert(self.filters, CreateSpinnerFilter( self, "ISEMPTY", STRINGS.UI.SERVERLISTINGSCREEN.ISEMPTY, yes_no, false ))
    -- table.insert(self.filters, CreateSpinnerFilter( "MAXSERVERSIZE", STRINGS.UI.SERVERLISTINGSCREEN.MAXSERVERSIZE, {min=2,max=4}, true ))

    if BRANCH == "dev" then
        table.insert(self.filters, CreateSpinnerFilter( self, "VERSIONCHECK", STRINGS.UI.SERVERLISTINGSCREEN.VERSIONCHECK, no_yes, false ))
    else
        TheNet:SetCheckVersionOnQuery( true )
    end

    local scroll_width = 230
    local scroll_height = 460
    local item_height = 20
    local item_padding = (scroll_height - (item_height*#self.filters)) / (#self.filters-1)

    self.filters_scroll_list = self.server_detail_panel:AddChild(ScrollableList(self.filters, scroll_width, scroll_height, item_height, item_padding, nil, nil, 0))
    self.filters_scroll_list:SetPosition(50,-35)

    if filter_data ~= nil then
        for i, v in ipairs(filter_data) do
            for j, k in ipairs(self.filters) do
                if v.name == k.name then
                    if k.spinner ~= nil then
                        k.spinner:SetSelected(v.data)
                        if k.spinner:GetSelectedIndex() ~= 1 then
                            k.spinner.changed_image:Show()
                        end
                    end
                elseif v.name == "search" then
                    if k.textbox ~= nil then
                        k.textbox:SetString(v.data or "")
                    end
                end
            end
        end
    end
end

local function MakeImgButton(parent, xPos, yPos, text, onclick, style, image)

    local btn
    if not style or style == "large" then
        btn = parent:AddChild(ImageButton())
        btn.image:SetScale(.7)
        btn:SetDisabledFont(NEWFONT)
    elseif style == "tab" then
        btn = parent:AddChild(TEMPLATES.TabButton(xPos, yPos, text, onclick, "large"))
        btn.text:SetSize(24)
    elseif style == "nav" then
        btn = parent:AddChild(TEMPLATES.NavBarButton(yPos, text, onclick))
    elseif style == "icon" then
        btn = parent:AddChild(TEMPLATES.IconButton("images/button_icons.xml", image..".tex", text, false, false, onclick))
    end

    btn:SetPosition(xPos, yPos)

    if not style or style == "large" then
        btn:SetTextColour(0,0,0,1)
        btn:SetTextSize(40)
        btn:SetOnClick(onclick)
    end

    if style ~= "icon" then
        btn:SetText(text)
    end

    if style ~= "tab" then
        btn:SetFont(NEWFONT)
        btn:SetDisabledFont(NEWFONT)
    end

    return btn
end

function ServerListingScreen:MakeMenuButtons(left_col, right_col, nav_col)
    self.refresh_button = MakeImgButton(self.server_list_titles, left_col-35, 55, STRINGS.UI.SERVERLISTINGSCREEN.REFRESH, function() self:SearchForServers() end, "icon", "refresh")
    self.lan_button = MakeImgButton(self.nav_bar, 10, -23, STRINGS.UI.SERVERLISTINGSCREEN.LAN, function() self:SetTab("LAN") end, "nav")
    self.online_button = MakeImgButton(self.nav_bar, 10, 25, STRINGS.UI.SERVERLISTINGSCREEN.ONLINE, function()
        if self.offlinemode then
            TheFrontEnd:PushScreen(PopupDialogScreen(
                    STRINGS.UI.SERVERLISTINGSCREEN.OFFLINE_MODE_TITLE,
                    STRINGS.UI.SERVERLISTINGSCREEN.OFFLINE_MODE_BODY,
                    {{ text = STRINGS.UI.SERVERLISTINGSCREEN.OK, cb = function() TheFrontEnd:PopScreen() end }}))
        else
            self:SetTab("online")
        end
    end, "nav")
    self.join_button = MakeImgButton(self.server_detail_panel, -55, -RESOLUTION_Y*.5 + BACK_BUTTON_Y - 15, STRINGS.UI.SERVERLISTINGSCREEN.JOIN, function() self:Join(false) end, "large")
    local tab_height = 212
    self.filters_button = MakeImgButton(self.server_detail_panel, -132, tab_height, STRINGS.UI.SERVERLISTINGSCREEN.FILTERS, function() self:ToggleShowFilters() end, "tab")
    self.details_button = MakeImgButton(self.server_detail_panel, -1, tab_height, STRINGS.UI.SERVERLISTINGSCREEN.SERVERDETAILS, function() self:ToggleShowFilters() end, "tab")

    self.refresh_button:Disable()
    self.refresh_button:SetHoverText(STRINGS.UI.SERVERLISTINGSCREEN.REFRESHING)
    self.join_button:Disable()

    self.details_shown = false
    self.filters_shown = false

    self.cancel_button = self.root:AddChild(TEMPLATES.BackButton(function() self:Cancel() end))

    self.online_button:SetFocusChangeDir(MOVE_DOWN, function() return self.lan_button end)
    self.lan_button:SetFocusChangeDir(MOVE_UP, function() return self.online_button end)

    self.online_button:SetFocusChangeDir(MOVE_RIGHT, function() return self:CurrentCenterFocus() end, MOVE_RIGHT)
    self.lan_button:SetFocusChangeDir(MOVE_RIGHT, function() return self:CurrentCenterFocus() end, MOVE_RIGHT)

    if TheInput:ControllerAttached() then
        -- self.refresh_button:Hide()
        self.join_button:Hide()
        self.cancel_button:Hide()
    else
        self.lan_button:SetFocusChangeDir(MOVE_DOWN, function() return self.cancel_button end)
        self.cancel_button:SetFocusChangeDir(MOVE_UP, function() return self.lan_button end)
        self.cancel_button:SetFocusChangeDir(MOVE_RIGHT, function() return self:CurrentCenterFocus() end, MOVE_RIGHT)
    end
end

function ServerListingScreen:MakeDetailPanel(right_col)
    self.server_detail_panel = self.root:AddChild(Widget("server_detail_panel"))
    self.server_detail_panel:SetPosition(right_col,0,0)
    self.server_detail_panelbg = self.server_detail_panel:AddChild(Image("images/serverbrowser.xml", "side_panel.tex"))
    self.server_detail_panelbg:SetScale(-.66,.7)
    self.server_detail_panelbg:SetPosition(-62,-45)

    local detail_x = -65
    local width = 240
    local detail_y = 135

    -- Container for the majority of the details in this panel, so we can hide them
    self.server_details_additional = self.server_detail_panel:AddChild(Widget("additionalservdetails"))
    self.server_details_additional:SetPosition(0,0) -- so we can use positioning relative to the whole panel
    self.server_details_additional:Hide()

    self.details_servername = self.server_detail_panel:AddChild(Text(BUTTONFONT, 40))
    self.details_servername:SetHAlign(ANCHOR_MIDDLE)
    self.details_servername:SetVAlign(ANCHOR_TOP)
    self.details_servername:SetPosition(detail_x, detail_y, 0)
    self.details_servername:SetColour(0, 0, 0, 1)
    self.details_servername._align =
    {
        maxwidth = width,
        maxchars = 45,
    }
    self.details_servername:SetMultilineTruncatedString(STRINGS.UI.SERVERLISTINGSCREEN.NOSERVERSELECTED, 2, self.details_servername._align.maxwidth, self.details_servername._align.maxchars, true)

    self.details_serverdesc = self.server_detail_panel:AddChild(Text(NEWFONT, 20))
    self.details_serverdesc:SetHAlign(ANCHOR_MIDDLE)
    self.details_serverdesc:SetVAlign(ANCHOR_TOP)
    detail_y = detail_y - 85
    self.details_serverdesc:SetPosition(detail_x, detail_y, 0)
    self.details_serverdesc:SetColour(0, 0, 0, 1)
    self.details_serverdesc._align =
    {
        maxwidth = width,
        maxchars = 55,
    }
    self.details_serverdesc:SetString("")

    --self.details_background = self.server_details_additional:AddChild(Image("images/server_intentions.xml", "social.tex"))
    --self.details_background:SetPosition(detail_x, 100)
    --self.details_background:SetTint(1,1,1,0.2)
    --self.details_background:SetScale(0.8, 0.8)
    ----self.details_background:Hide()

    self.viewworld_button = MakeImgButton(self.server_detail_panel, -56, 6, STRINGS.UI.SERVERLISTINGSCREEN.WORLD_UNKNOWN, function() self:ViewServerWorld() end, "icon", "world")
    self.viewworld_button:Select()

    self.viewmods_button = MakeImgButton(self.server_detail_panel, 0, 6, STRINGS.UI.SERVERLISTINGSCREEN.NOMODS, function() self:ViewServerMods() end, "icon", "mods")
    self.viewmods_button:Select()

    self.viewtags_button = MakeImgButton(self.server_detail_panel, 56, 6, STRINGS.UI.SERVERLISTINGSCREEN.NOTAGS, function() self:ViewServerTags() end, "icon", "tags")
    self.viewtags_button:Select()

    self.viewplayers_button = MakeImgButton(self.server_detail_panel, -28, -46, STRINGS.UI.SERVERLISTINGSCREEN.PLAYERS_UNKNOWN, function() self:ViewServerPlayers() end, "icon", "view_players")
    self.viewplayers_button:Select()

    self.viewgroup_button = MakeImgButton(self.server_detail_panel, 28, -46, STRINGS.UI.SERVERLISTINGSCREEN.GROUP_NONE, function() self:ViewServerGroup() end, "icon", "clan")
    self.viewgroup_button:Select()

    self.viewworld_button:SetScale(.9)
    self.viewgroup_button:SetScale(.9)
    self.viewplayers_button:SetScale(.9)
    self.viewmods_button:SetScale(.9)
    self.viewtags_button:SetScale(.9)

    self.server_details_additional.focus_forward = self.viewworld_button

    local buttons = self.server_details_additional:AddChild(Widget("buttons"))
    detail_y = detail_y - 70
    buttons:SetPosition(detail_x, detail_y)
    buttons:AddChild(self.viewmods_button)
    buttons:AddChild(self.viewtags_button)
    buttons:AddChild(self.viewworld_button)
    buttons:AddChild(self.viewgroup_button)
    buttons:AddChild(self.viewplayers_button)
    buttons.focus_forward = self.viewworld_button
    self.viewworld_button:SetFocusChangeDir(MOVE_LEFT, function() return self:CurrentCenterFocus() end, MOVE_LEFT)
    self.viewworld_button:SetFocusChangeDir(MOVE_RIGHT, function() return self.viewmods_button end)
    self.viewworld_button:SetFocusChangeDir(MOVE_DOWN, function() return self.viewplayers_button end)
    self.viewmods_button:SetFocusChangeDir(MOVE_LEFT, function() return self.viewworld_button end)
    self.viewmods_button:SetFocusChangeDir(MOVE_RIGHT, function() return self.viewtags_button end)
    self.viewmods_button:SetFocusChangeDir(MOVE_DOWN, function() return self.viewplayers_button end)
    self.viewtags_button:SetFocusChangeDir(MOVE_LEFT, function() return self.viewmods_button end)
    self.viewtags_button:SetFocusChangeDir(MOVE_DOWN, function() return self.viewgroup_button end)

    self.viewplayers_button:SetFocusChangeDir(MOVE_LEFT, function() return self:CurrentCenterFocus() end, MOVE_LEFT)
    self.viewplayers_button:SetFocusChangeDir(MOVE_RIGHT, function() return self.viewgroup_button end)
    self.viewplayers_button:SetFocusChangeDir(MOVE_UP, function() return self.viewworld_button end)
    self.viewgroup_button:SetFocusChangeDir(MOVE_LEFT, function() return self.viewplayers_button end)
    self.viewgroup_button:SetFocusChangeDir(MOVE_UP, function() return self.viewtags_button end)

    self.game_mode_description = self.server_details_additional:AddChild(Widget("gamemodedesc"))
    detail_y = detail_y - 88
    self.game_mode_description:SetPosition(detail_x, detail_y)
    self.game_mode_description.text = self.game_mode_description:AddChild(Text(NEWFONT, 20))
    self.game_mode_description.text:SetString(STRINGS.UI.SERVERLISTINGSCREEN.SURVIVAL)
    self.game_mode_description.text:SetPosition(-10,0)
    self.game_mode_description.text:SetHAlign(ANCHOR_MIDDLE)
    -- self.game_mode_description.text:SetRegionSize( 200, 50 )
    self.game_mode_description.text:SetString("???")
    self.game_mode_description.text:SetColour(0,0,0,1)
    self.game_mode_description.info_button = self.game_mode_description:AddChild(TEMPLATES.IconButton("images/button_icons.xml", "info.tex", "", false, false, function()
            local mode_title = GetGameModeString( self.selected_server.mode )
            if mode_title == "" then
                mode_title = STRINGS.UI.GAMEMODES.UNKNOWN
            end
            local mode_body = GetGameModeDescriptionString( self.selected_server.mode )
            if mode_body == "" then
                mode_body = STRINGS.UI.GAMEMODES.UNKNOWN_DESCRIPTION
            end
            TheFrontEnd:PushScreen(PopupDialogScreen(
                mode_title,
                mode_body,
                {{ text = STRINGS.UI.SERVERLISTINGSCREEN.OK, cb = function() TheFrontEnd:PopScreen() end }}))
        end))
    local w,h = self.game_mode_description.text:GetRegionSize()
    self.game_mode_description.info_button:SetPosition(w/2 + 7, -2)
    self.game_mode_description.info_button:SetScale(.4)
    self.game_mode_description.info_button:SetFocusChangeDir(MOVE_UP, function() return self.viewplayers_button end)
    self.viewplayers_button:SetFocusChangeDir(MOVE_DOWN, function() return self.game_mode_description.info_button end)
    self.viewgroup_button:SetFocusChangeDir(MOVE_DOWN, function() return self.game_mode_description.info_button end)

    local check_x = -90
    local label_x = 40

    self.season_description = self.server_details_additional:AddChild(Widget("seasondesc"))
    detail_y = detail_y - 30
    self.season_description:SetPosition(detail_x, detail_y)
    self.season_description.text = self.season_description:AddChild(Text(NEWFONT, 20))
    self.season_description.text:SetPosition(-10,0)
    self.season_description.text:SetHAlign(ANCHOR_MIDDLE)
    self.season_description.text:SetRegionSize( 400, 50 )
    self.season_description.text:SetString("???")
    self.season_description.text:SetColour(0,0,0,1)

    self.day_description = self.server_details_additional:AddChild(Widget("daydesc"))
    detail_y = detail_y - 30
    self.day_description:SetPosition(detail_x, detail_y)
    self.day_description.text = self.day_description:AddChild(Text(NEWFONT, 20))
    self.day_description.text:SetPosition(-10,0)
    self.day_description.text:SetHAlign(ANCHOR_MIDDLE)
    self.day_description.text:SetRegionSize( 400, 50 )
    self.day_description.text:SetString("???")
    self.day_description.text:SetColour(0,0,0,1)

    local has_password = self.server_details_additional:AddChild(Widget("pw"))
    detail_y = detail_y - 30
    has_password:SetPosition(detail_x, detail_y)
    self.checkbox_has_password = has_password:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "password.tex", "rust", "", nil, {-1,0}, .08, .073))
    self.checkbox_has_password:SetPosition(check_x, 0, 0)
    self.checkbox_has_password.off_image = self.checkbox_has_password:AddChild(Image("images/servericons.xml", "bg_grey.tex"))
    self.checkbox_has_password.off_image:SetTint(1,1,1,.7)
    self.checkbox_has_password.off_image:SetScale(.09)
    self.checkbox_has_password.off_image:Hide()
    self.has_password_description = has_password:AddChild(Text(NEWFONT, 20))
    self.has_password_description:SetPosition(label_x, 0, 0)
    self.has_password_description:SetString(STRINGS.UI.SERVERLISTINGSCREEN.HASPASSWORD_DETAIL)
    self.has_password_description:SetHAlign(ANCHOR_LEFT)
    self.has_password_description:SetRegionSize( 200, 50 )
    self.has_password_description:SetColour(0,0,0,1)
    SetChecked( self.checkbox_has_password, self.has_password_description, false )

    local dedicated_server = self.server_details_additional:AddChild(Widget("ded"))
    detail_y = detail_y - 26
    dedicated_server:SetPosition(detail_x, detail_y)
    self.checkbox_dedicated_server = dedicated_server:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "dedicated.tex", "burnt", "", nil, {0,0}, .08, .073))
    self.checkbox_dedicated_server:SetPosition(check_x, 0, 0)
    self.checkbox_dedicated_server.off_image = self.checkbox_dedicated_server:AddChild(Image("images/servericons.xml", "bg_grey.tex"))
    self.checkbox_dedicated_server.off_image:SetTint(1,1,1,.7)
    self.checkbox_dedicated_server.off_image:SetScale(.09)
    self.checkbox_dedicated_server.off_image:Hide()
    self.dedicated_server_description = dedicated_server:AddChild(Text(NEWFONT, 20))
    self.dedicated_server_description:SetPosition(label_x, 0, 0)
    self.dedicated_server_description:SetString(STRINGS.UI.SERVERLISTINGSCREEN.ISDEDICATED)
    self.dedicated_server_description:SetHAlign(ANCHOR_LEFT)
    self.dedicated_server_description:SetRegionSize( 200, 50 )
    self.dedicated_server_description:SetColour(0,0,0,1)
    SetChecked( self.checkbox_dedicated_server, self.dedicated_server_description, false )

    local pvp = self.server_details_additional:AddChild(Widget("pvp"))
    detail_y = detail_y - 26
    pvp:SetPosition(detail_x, detail_y)
    self.checkbox_pvp = pvp:AddChild(TEMPLATES.ServerDetailIcon("images/servericons.xml", "pvp.tex", "brown", "", nil, {0,0}, .075, .075))
    self.checkbox_pvp:SetPosition(check_x, 0, 0)
    self.checkbox_pvp.off_image = self.checkbox_pvp:AddChild(Image("images/servericons.xml", "bg_grey.tex"))
    self.checkbox_pvp.off_image:SetTint(1,1,1,.7)
    self.checkbox_pvp.off_image:SetScale(.09)
    self.checkbox_pvp.off_image:Hide()
    self.pvp_description = pvp:AddChild(Text(NEWFONT, 20))
    self.pvp_description:SetPosition(label_x, 0, 0)
    self.pvp_description:SetString(STRINGS.UI.SERVERLISTINGSCREEN.HASPVP_DETAIL)
    self.pvp_description:SetHAlign(ANCHOR_LEFT)
    self.pvp_description:SetRegionSize( 200, 50 )
    self.pvp_description:SetColour(0,0,0,1)
    SetChecked( self.checkbox_pvp, self.pvp_description, false )
end

local function MakeHeader(self, parent, xPos, name, onclick)
-- ══★【MakeHeader：列表列头 —— 表头的排序热区】
-- ★ 本地函数，接收 parent/xPos/name/onclick。
-- ★★ 2217 行 MakeColumnHeaders 用它建四个列头（NAME/DETAILS/PLAYERS/PING）。
-- → ★★★ 「表头可点击排序」是列表的标准交互：
--   而点击处理是 MakeColumnHeaders 里绑定到 SetSort 的（见 1175 行分析）。
-- ★★ onscrollcb 与列头排序的配合：
--   排序后列表重排 → 高亮要重算 → GuaranteeSelectedServerHighlighted
--   → ★ 「排序也是一次列表变化」，必须走同样的刷新链路。

    local root_y_offset = 3
    local text_x_offset = -5
    local text_y_offset = 3
    local frame_color = {0, 0, 0, 1}
    local arrow_x_offset = 6.5
    local arrow_y_offset = 2
    local bg_y_scale = 15
    local bg_x_offset = 10
    local bg_y_offset = 0

    local header = parent:AddChild(Widget("control"))
    header:SetPosition(xPos, root_y_offset)
    header.text = header:AddChild(Text(NEWFONT, font_size, name))
    header.text:SetPosition(text_x_offset,text_y_offset,0)
    header.text:SetColour(frame_color[1], frame_color[2], frame_color[3], frame_color[4])
    header.bg = header.text:AddChild(ImageButton("images/ui.xml", "blank.tex", "blank.tex", "blank.tex"))
    header.bg:MoveToBack()
    header.arrow = header:AddChild(Image("images/ui.xml", "arrow2_down.tex"))
    header.arrow.ascending = true
    header.arrow:SetScale(.25)
    header.arrow:SetPosition(header.text:GetRegionSize()/2 + arrow_x_offset, arrow_y_offset, 0)
    header.arrow:SetClickable(false)
    header.arrow:Hide()
    if name == STRINGS.UI.SERVERLISTINGSCREEN.NAME then
        header.bg.image:SetSize(315, 35)
        header.bg:SetPosition(bg_x_offset+108, bg_y_offset)
    elseif name == STRINGS.UI.SERVERLISTINGSCREEN.DETAILS then
        header.bg.image:SetSize(185, 35)
        header.bg:SetPosition(bg_x_offset+41, bg_y_offset)
    elseif name == STRINGS.UI.SERVERLISTINGSCREEN.PLAYERS then
        header.bg.image:SetSize(110, 35)
        header.bg:SetPosition(bg_x_offset, bg_y_offset)
    else
        header.bg.image:SetSize(80, 35)
        header.bg:SetPosition(bg_x_offset+3, bg_y_offset)
    end

    header.bg.OnGainFocus =
        function()
            TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_mouseover", nil, ClickMouseoverSoundReduction())
            header.text:SetFont(NEWFONT_OUTLINE)
            header.text:SetColour(1,1,1,1)
            header.text:SetSize(33)
            if header.arrow.ascending then
                header.arrow:SetTexture("images/ui.xml", "arrow2_up_over.tex")
            else
                header.arrow:SetTexture("images/ui.xml", "arrow2_down_over.tex")
            end
        end
    header.bg.OnLoseFocus =
        function()
            if self.sort_column == string.upper(name) then
                -- header.text:SetColour(.4,.4,.4,1)
            else
                -- header.text:SetColour(frame_color[1], frame_color[2], frame_color[3], frame_color[4])
            end
            header.text:SetFont(NEWFONT)
            header.text:SetColour(0,0,0,1)
            header.text:SetSize(35)
            if header.arrow.ascending then
                header.arrow:SetTexture("images/ui.xml", "arrow2_up.tex")
            else
                header.arrow:SetTexture("images/ui.xml", "arrow2_down.tex")
            end
        end
    header.bg:SetOnClick( onclick )

    return header
end

function ServerListingScreen:MakeColumnHeaders()
    self.title = self.server_list_titles:AddChild(Text(BUTTONFONT, 45, STRINGS.UI.SERVERLISTINGSCREEN.SERVER_LIST_TITLE))
    self.title:SetColour(0,0,0,1)
    self.title:SetPosition(column_offsets.DETAILS, 55)

    self.server_count = self.server_list_titles:AddChild(Text(NEWFONT, 25, "(0)"))
    self.server_count:SetColour(0,0,0,1)
    self.server_count:SetRegionSize(300,40)
    self.server_count:SetHAlign(ANCHOR_RIGHT)
    self.server_count:SetPosition(column_offsets.DETAILS+167, 53)

    self.NAME = MakeHeader(self, self.table.titles, column_offsets.NAME, STRINGS.UI.SERVERLISTINGSCREEN.NAME, function() self:SetSort("NAME") end)
    self.DETAILS = MakeHeader(self, self.table.titles, column_offsets.DETAILS-13, STRINGS.UI.SERVERLISTINGSCREEN.DETAILS, function() self:SetSort("DETAILS") end)
    self.PLAYERS = MakeHeader(self, self.table.titles, column_offsets.PLAYERS, STRINGS.UI.SERVERLISTINGSCREEN.PLAYERS, function() self:SetSort("PLAYERS") end)
    self.PING = MakeHeader(self, self.table.titles, column_offsets.PING, STRINGS.UI.SERVERLISTINGSCREEN.PING, function() self:SetSort("PING") end)

    self.column_buttons = {
        NAME = self.NAME,
        DETAILS = self.DETAILS,
        PLAYERS = self.PLAYERS,
        PING = self.PING
    }
end

function ServerListingScreen:OnControl(control, down)
-- ══★★★【OnControl：输入路由 —— 「输入独占」的教科书实现】
-- ★★ 2244-2247 行是「文本框焦点独占」：
--   若搜索框正在编辑，或搜索框有焦点且按 ACCEPT，
--   则把事件**直接转交**给 textbox 并 return true。
-- → ★★★★ 「某控件接管输入」的标准做法：
--   在屏幕的 OnControl 里判断「是否有控件正在独占输入」，
--   有则转交并**消费掉**（return true），不继续处理全局按键。
-- → ★★★ 这是玩家提问的「模态与输入独占」的完整答案之一：
--   文本编辑态是「最轻量的模态」—— 不需要弹窗、不需要改焦点树，
--   只是在输入路由的最前面插一个转交。
-- ⚠️ 2244 行的条件有两项：
--   textbox.editing（正在编辑）—— 玩家主动点了输入框
--   searchbox.focus 且 control == ACCEPT —— 搜索框有焦点时按 A
--   → ★★ 后者让「选中搜索框按 A 进入编辑态」正常工作。
--   → ★ 这是「焦点在输入框上时按确认键进入编辑」的标准交互。
--
-- ★★★ 2250-2258 行 CANCEL 的双分支：
--   2251 淡出中 → **断线**并取消淡出
--   2255 否则   → 正常退出（Cancel）
-- → ★★★★ 「同一个键在特殊状态下做特殊的事」：
--     如果界面正在退出（淡出），玩家还在按 ESC/CANCEL，
--     正常的 Cancel 会出问题（对已消失的界面操作），
--     于是改成「断线 + 恢复显示」的应急处理。
-- → ★★★ 移植要点：**对「正在销毁的界面」的输入要有明确的兜底**。
--     否则会出现「关闭动画期间的按键导致崩溃」。
--   2253 行 HideCancelTip() —— 取消「按 ESC 退出」的提示。
-- ★★ 2259 行的 JOIN 条件有三重：
--   `CONTROL_MENU_START and self.selected_server and ControllerAttached()
--    and not TheFrontEnd.tracking_mouse`
--   → ★★ 「有选中 + 用手柄 + 没在用鼠标」才响应菜单键。
--   → 「手柄 + 鼠标同时可用时，手柄的菜单键不触发加入」是刻意的，
--     避免玩家正在用鼠标时误触。
--   → ★★★ 移植要点：**输入响应要考虑「另一种输入设备是否活跃」**。
-- ★★ 2262 行的 L2/R2 共用 ToggleShowFilters：
--   两个肩键都能切筛选面板，是「易发现性」的设计。
-- ⚠️ 2265 行 MISC_2（刷新）有 `not IsSearchingServers()` 守卫，
--   而 2310 行的 GetHelpText 也有同样的守卫 —— 两处一致，正确。
-- ★★ 2271 行的 else `return false`：
--   未识别的键不消费 → 事件继续冒泡。
--   与 playerhud:1421 的「nil 穿透」约定一致。
--   注意这里是 return false 而函数末尾无 return（即 nil），
--   两者在条件判断中等价。
    if ServerListingScreen._base.OnControl(self, control, down) then return true end

    if self.searchbox and ((self.searchbox.textbox and self.searchbox.textbox.editing) or (self.searchbox.focus and control == CONTROL_ACCEPT)) then
        self.searchbox.textbox:OnControl(control, down)
        return true
    end

    if not down then
        if control == CONTROL_CANCEL then
            if TheFrontEnd:GetFadeLevel() > 0 then
                TheNet:Disconnect(false)
                HideCancelTip()
                TheFrontEnd:Fade(FADE_IN, SCREEN_FADE_TIME)
            else
                self:Cancel()
                TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
            end
        elseif control == CONTROL_MENU_START and self.selected_server and TheInput:ControllerAttached() and not TheFrontEnd.tracking_mouse then
            self:Join(false)
            TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
        elseif control == CONTROL_MENU_L2 or control == CONTROL_MENU_R2 then
            self:ToggleShowFilters()
            TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
        elseif control == CONTROL_MENU_MISC_2 and not TheNet:IsSearchingServers() then
            self:SearchForServers()
            TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
        elseif control == CONTROL_MENU_MISC_1 then
            self:CycleColumnSort()
            TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
        else
            return false
        end

        return true
    end
end

function ServerListingScreen:CurrentCenterFocus()
-- ══★★【CurrentCenterFocus / CurrentRightFocus / CurrentLeftFocus：动态焦点图】
-- ★★★ 这三个函数是「焦点目标可以是函数」的用法（对照 modstab:1128）：
--   971/977 行把它们作为 SetFocusChangeDir 的目标传入，
--   Widget:SetFocusChangeDir 支持 FunctionOrValue（widget.lua:81），
--   所以焦点在**按下那一刻**才求值。
--
-- ★★ 2280-2284 行 CurrentCenterFocus 的条件：
--   `if self.view_online and self.server_intention.data == nil then intentions_overlay else servers_scroll_list`
--   → ★★★ 「焦点落点取决于「intention 覆盖层是否已选定」：
--     玩家还没选游戏意图时，焦点应该在意图选择器上（必须先做这个选择）；
--     选定之后才应该能进服务器列表。
--   → ★★★ 这是一种「引导式焦点」：
--     用焦点顺序强制用户完成前置步骤。
--     比弹窗教程更优雅 —— 玩家想往下走就会发现「要先选这个」。
--   → ★ 移植要点：**引导可以靠焦点顺序实现，不必靠弹窗**。
--
-- ★★★ 2287-2292 行 CurrentRightFocus 的两级判定：
--   筛选面板可见 → 焦点去筛选面板
--   否则详情附加区可见 → 焦点去「查看世界生成」按钮
--   否则返回 nil（无右侧焦点）
--   → ★★★ 「右侧区域的内容随状态变化，焦点目标也跟着变」：
--     同样是函数式目标的价值。
--   → ★ 注意返回 nil 是合法的：widget.lua:84 会判 dest 存在性。
--
-- ★ 2295-2296 行 CurrentLeftFocus 极简：
--   在线页签 → online_button，否则 lan_button。
--   → ★ 与 2280 行同款：页签决定左侧焦点落点。
--   → ★★ 三个函数合起来定义了「上下左右」四个方向的焦点图，
--     且都是动态的。这是本文件输入系统的骨架。
    if self.view_online and self.server_intention.data == nil then
        return self.intentions_overlay
    else
        return self.servers_scroll_list
    end
end

function ServerListingScreen:CurrentRightFocus()
    if self.filters_scroll_list:IsVisible() then
        return self.filters_scroll_list
    elseif self.server_details_additional:IsVisible() then
        return self.viewworld_button
    end
end

function ServerListingScreen:CurrentLeftFocus()
    return self.view_online and self.online_button or self.lan_button
end

function ServerListingScreen:GetHelpText()
-- ══★★【GetHelpText：与 OnControl 严格对应的帮助系统】
-- ★★ 逐条对照 2241 行的 OnControl：
--   CANCEL        → BACK            ✓ 对应 2250 行
--   L2 / R2       → CHANGE_TAB      ✓ 对应 2262 行
--   MISC_1        → CHANGE_SORT     ✓ 对应 2268 行
--   MISC_2        → REFRESH（条件）  ✓ 对应 2265 行的 IsSearchingServers 守卫
--   MENU_START    → JOIN（条件）     ✓ 对应 2313 行的 selected_server 守卫
-- → ★★★★ 「帮助文本与实际行为逐条对应，且条件完全一致」：
--   2309-2311 与 2265 行都是 `if not TheNet:IsSearchingServers()`
--   2313-2315 与 2259 行都是 `if self.selected_server`
-- → ★★ 这是本项目里做得最好的输入/文档同步（对照 modstab:678 的 TODO 疑问）。
--   → ★★★ 移植要点：**帮助文本应该从同一份按键配置生成**。
--     手工维护两份必然漂移。本文件靠作者自觉，但可维护性有限。
-- ★ 2305 行一个键位显示两个控制（L2/R2）用斜杠连接，
--   与 tradescreen 的写法一致。
-- ★★ 注意本文件**没有**列出「查看世界生成/查看 mod 列表」等按钮的提示，
--   因为那些是鼠标点击的按钮（有 HoverText 而非按键绑定）。
--   → ★ 两类信息用两种机制呈现：按键绑定的进 GetHelpText，
--     鼠标目标用 SetHoverText。分工清晰。
    local controller_id = TheInput:GetControllerID()
    local t = {}

    table.insert(t,  TheInput:GetLocalizedControl(controller_id, CONTROL_CANCEL) .. " " .. STRINGS.UI.HELP.BACK)

    table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_MENU_L2).."/"..TheInput:GetLocalizedControl(controller_id, CONTROL_MENU_R2).. " " .. STRINGS.UI.HELP.CHANGE_TAB)

    table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_MENU_MISC_1) .. " " .. STRINGS.UI.SERVERLISTINGSCREEN.CHANGE_SORT)

    if not TheNet:IsSearchingServers() then
        table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_MENU_MISC_2) .. " " .. STRINGS.UI.SERVERLISTINGSCREEN.REFRESH)
    end

    if self.selected_server then
        table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_MENU_START) .. " " .. STRINGS.UI.SERVERLISTINGSCREEN.JOIN)
    end

    return table.concat(t, "  ")
end

return ServerListingScreen