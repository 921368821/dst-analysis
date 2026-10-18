--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：widgets/inventorybar.lua
-- 模块：UI 系统 / 手柄背包栏主控件（类名 Inv）
-- 职责：手柄与主机模式下的背包条。维护槽位网格布局（5 格一组的组间大间距）、
--       装备槽、光标导航（几何最近邻 + 环绕步进）、动态操作提示条 actionstring、
--       物品飞入动画、溢出背包（第二行）集成与自动暂停联动。
--       ★ 注意：鼠标玩家的背包交互不在本文件，由 invslot.lua/itemtile.lua 自行处理；
--         本文件是并列的第二套手柄交互实现。
-- 关键符号：Inv, Rebuild, Refresh, RebuildLayout, RebuildLayout_Quagmire,
--           CursorNav, CursorLeft, CursorRight, CursorUp, CursorDown,
--           GetClosestWidget, OffsetCursor, GetInventoryLists, SelectSlot,
--           SelectDefaultSlot, UpdateCursor, UpdateCursorText, OnControl,
--           OpenControllerInventory, CloseControllerInventory,
--           SetAutopausedInternal, SetHoverTileHideModifier, OnItemGet,
--           OnNewActiveItem, RefreshIntegratedContainer, AddEquipSlot
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：class.lua（Class 继承）, widgets/widget.lua（基类与焦点锁）,
--           widgets/invslot.lua（槽位控件）、widgets/itemtile.lua（物品图）,
--           widgets/equipslot.lua（装备槽）、widgets/hudcompass.lua（罗盘）,
--           containers.lua（容器 widget.slotpos / *_align_tip 数据驱动定义）,
--           widgets/containerwidget.lua（容器 UI）、util/sourcemodifierlist.lua
--           （多来源布尔遮罩聚合器）
--============================================================
require "class"
--[[
-- inventorybar.lua —— 手柄版背包栏主控件（Inv）
--
-- 【⚠️ 命名澄清】类名是 **Inv**（第 33 行 local Inv = Class(Widget, ...)），
-- 不是 InventoryBar。文件叫 inventorybar.lua 但导出的符号叫 Inv。
--
-- 【职责边界（重要）】
-- 本文件只负责「手柄/主机模式」的背包条，即控制器 UI。
--   · 鼠标玩家的背包由 invslot.lua / itemtile.lua 自己处理悬停与拖拽；
--   · 本文件全程用 cursor（光标）、active_slot（当前选中槽）而非鼠标 hover。
-- 因此它是**第二套**交互实现，很多逻辑与鼠标版平行但不共用。
--
-- 【★ 对自研游戏最有价值的四点】
-- 1) 【布局全手算，无布局引擎】第 247-284 行的网格公式。
--    DST 没有 flex/grid 布局，槽位坐标是纯算术推导出来的。
-- 2) 【延迟重建】rebuild_pending（第 154、460、522 行）：
--    改布局的请求只置标志，实际重建推迟到 OnUpdate 的安全时机。
-- 3) 【多来源事件收敛】第 108-125 行的 13 个事件监听，
--    全部最终收敛到 Rebuild / Refresh 两个入口，避免状态不一致。
-- 4) 【数据驱动 UI】第 286-291 行按角色 prefab 查图集；
--    配合 containers.lua 的 widget.slotpos 数据表实现「配置即布局」。
--
-- 【网格公式速解（第 247-284 行）】
--   W=68   单槽宽
--   SEP=12 槽间常规间距
--   INTERSEP=28 每 5 个槽之后的「组间」大间距（物品栏按 5 个一行分组）
--   total_w = 总槽数×W + (总槽数-1)×SEP + 组数×INTERSEP
-- 即：先把所有槽按常规间距排满，再给每个分组交界处补一份额外间距。
--]]
local InvSlot = require "widgets/invslot"
-- InvSlot = 一个可容纳物品的槽位控件；ItemTile = 槽里那个物品图。
-- ★ 本文件的「槽位/物品」二元结构：
--   self.inv[k]      → InvSlot 实例（空格子，含选中框、tooltip 锚点）
--   self.inv[k].tile → ItemTile 实例（物品图像，含堆叠数、耐久条）
-- 拖拽/刷新都发生在这一层分离上：换物品 = 换 tile，不必重建 slot。
local TileBG = require "widgets/tilebg"
local Image = require "widgets/image"
local Widget = require "widgets/widget"
local EquipSlot = require "widgets/equipslot"
local ItemTile = require "widgets/itemtile"
-- ⚠️ 第 7 行与第 10 行 **重复 require 了同一个 itemtile**。
-- require 有缓存，第二次返回同一份 module table，不会出错；
-- 但这属于历史遗留的冗余写法（很可能是合并两个分支时留下的）。
-- 我实测确认无害，仅作记录。
local Text = require "widgets/text"
local HudCompass = require "widgets/hudcompass"
local ItemTile = require("widgets/itemtile")

local TEMPLATES = require "widgets/templates"

local HUD_ATLAS = "images/hud.xml"
-- 两套 HUD 图集并存：HUD_ATLAS 是通用件，
-- HUD2_ATLAS 只服务于特定角色的专属部件（见第 17-20 行映射表）。
-- ★ 「按角色换图集」是 DST 做角色专属 UI 的标准手法：
-- 不新建文件，只在新图集里加同名符号。
local HUD2_ATLAS = "images/hud2.xml"

local HUD_CHARACTERS =
-- 【数据驱动的角色 → 图集映射表】
-- 当前只有 wanda 一个角色有专属 HUD2 图集。
-- ★ 新增角色专属 UI 时只需往这张表加一行，
-- 第 290 行的 HUD_CHARACTERS[owner_prefab] or HUD_ATLAS 回退链会自动生效。
-- 注意用的是 `or` 回退：查不到就用通用图集，天然向后兼容。
{
    ["wanda"] = HUD2_ATLAS,
}

local SourceModifierList = require("util/sourcemodifierlist")

local W = 68
-- 【★ 布局常量集中定义的范式】
-- 四个魔法数字抽成文件级 local，好处是：
--   · 只在一处定义，第 24-27 行的用途一目了然；
--   · 改分辨率/尺寸只需改这里；
--   · 因为是 local，不会污染全局，也不会被别的文件误改。
-- W=68 是单个槽位宽度，SEP=12 是槽间距，
-- INTERSEP=28 是「每 5 槽」之后的分组间距（对应 5 格一排的布局）。
local SEP = 12
local YSEP = 8
local INTERSEP = 28

local CURSOR_STRING_DELAY = 10
-- CURSOR_STRING_DELAY=10：光标提示条（actionstring）在最后一次交互后
-- 停留 10 秒才淡出。注意它是**帧计数式**的用法：
-- 第 542 行每帧 actionstringtime -= dt，配合 dt 以秒计，
-- 所以实际是「10 秒后淡出」而非「10 帧」。
-- TIP_YFUDGE=16：提示条与槽位之间的微调间距，避免视觉贴合。
-- HINT_UPDATE_INTERVAL=2.0：底部按键提示的刷新间隔，
-- ★ 源码原注释写 "once per second" 但值是 2.0 —— 注释与实际不符，
-- 属**注释陈旧**（不影响行为）。这类地方读代码时不能全信注释。
local TIP_YFUDGE = 16
local HINT_UPDATE_INTERVAL = 2.0 -- once per second

local Inv = Class(Widget, function(self, owner)
-- 【★ Class 继承：与 templates.lua 的工厂函数是两条不同的路】
-- 这里是 class.lua:83 的 Class(Widget, ctor)，得到真正的子类；
-- 而 templates.lua 是纯工厂函数表。
-- ★ 区别：Class 方式适合「有状态、有方法、要被继承」的长生命周期控件；
--   工厂方式适合「一次性造出即用」的静态零件。
-- 本文件是前者的代表：Inv 有大量方法（40+ 个 Inv:xxx）。
-- 第 34 行 Widget._ctor(self, "Inventory") 必须**显式调用基类构造器**，
-- 否则基类里的 self.inst / self.children / self.focus_flow 等全都不存在。
    Widget._ctor(self, "Inventory")
    self.owner = owner

    self.out_pos = Vector3(0,W,0)
-- 【★ out_pos / in_pos：背包栏的「收起/展开」两态坐标】
-- out_pos = 屏幕底外（收起），in_pos = 屏幕底内（展开）。
-- 两者之间的过渡用 MoveTo 做补间动画（第 380、389 行）。
-- ★ 这是「用坐标动画代替显隐」的手柄 UI 惯例：
-- 背包不是突然出现，而是从屏幕下方滑上来。
-- ★ 收起状态下（第 392 行）整条 bar 移到 out_pos，
-- 但依然存在且可接收输入 —— 这样手柄玩家随时能再次呼出。
    self.in_pos = Vector3(0,W*1.5,0)

    self.base_scale = .6
-- base_scale=.6（收起）/ selected_scale=.8（展开）。
-- ★ 手柄 UI 的两套缩放：小提示玩家「这里有条 bar」，
-- 大提示「你现在可以操作了」。缩放差异即状态提示。
    self.selected_scale = .8

    self:SetScale(self.base_scale)
    self:SetPosition(0,-16,0)

    self.inv = {}
    self.backpackinv = {}
    self.equip = {}
    self.equipslotinfo = {}

    self.root = self:AddChild(Widget("root"))
-- 【★ 单一 root 容器：整个背包挂在一个子 root 下】
-- root 之下再挂 hudcompass / hand_inv / bg / bgcover / toprow / bottomrow。
-- ★ 好处：移动/缩放只需操作 root 一处（第 368、380 行的 MoveTo），
-- 所有子件自动跟随。且 root 的坐标与外部 HUD 其它部件解耦。
-- ⚠️ 但 UpdateCursorText（第 1198 行）取的是 active_slot 的**世界**坐标，
-- 提示条要跨 root 定位，所以后面那几行要乘 xscale/yscale 换算。

    self.hudcompass = self.root:AddChild(HudCompass(owner, true))
    self.hudcompass:SetScale(1.5, 1.5)
    self.hudcompass:SetMaster()
-- ★ SetMaster()：把当前焦点设为「主控件」。
-- 手柄模式下焦点链需要一个根，Master 标记的就是这个根，
-- 之后 TheFrontEnd:LockFocus(true)（第 928 行）才能把焦点锁在这里，
-- 避免焦点跑到别的屏幕上（第 518 行 OnUpdate 里有对应检查）。

    self.hand_inv = self.root:AddChild(Widget("hand_inv"))
    self.hand_inv:SetScale(1.5, 1.5)

	if TheNet:GetServerGameMode() == "lavaarena" then
-- 【★ 三种游戏模式的 HUD 皮肤分支】
-- lavaarena（熔岩竞技场）/ quagmire（圣旗模式）/ 默认生存。
-- 三者连缩放、坐标、图集都不同。
-- ★ 注意第 66、70 行：lavaarena 与 quagmire 都用 Widget("dummy") 当 bgcover，
-- 即「占位但不可见」。这是关键技巧 —— 见第 294-304 行的说明。
-- ⚠️ 这段 if/elseif 写在构造器里，且同一批条件（60/68/100/135/364/441 行）
-- 在全文件重复出现 6 次。是历史欠债，但改造成本高、风险大，不宜重构。
	    self.base_scale = .55
		self:SetScale(self.base_scale)
	    self:SetPosition(0,0,0)

		self.bg = self.root:AddChild(Image("images/lavaarena_hud.xml", "lavaarena_inventorybar.tex"))
		self.bgcover = self.root:AddChild(Widget("dummy"))
-- ★★★ 关键技巧：**用空 Widget 顶替 Image 当占位符**。
-- bgcover 在默认分支是张覆盖图（inventory_bg_cover.tex），
-- 但 lavaarena/quagmire 没有对应美术资源，于是塞一个空 Widget("dummy")。
--
-- 为什么值得学：后续 RebuildLayout（第 294-304、371、384 行）会无条件
-- 对 self.bgcover 调用 SetScale/SetPosition。
-- 若此时 self.bgcover 为 nil → 崩溃。
-- ★ 换成空 Widget 后，上层代码**完全不用写 if**，接口形状保持一致。
-- 这与 templates.lua 第 73 行的「空函数覆盖」是同一类 Null Object 模式。
-- ★★ 移植自研项目时这是最容易踩的坑：
--   「某个分支没创建这个字段」会让其它分支的通用代码炸掉。
--   正确做法就是像这里一样补一个空对象占位。
		self.in_pos = Vector3(41,W*1.5,0)
	elseif TheNet:GetServerGameMode() == "quagmire" then
		self.bg = self.root:AddChild(Image("images/quagmire_hud.xml", "inventory_bg.tex"))
		self.bgcover = self.root:AddChild(Widget("dummy"))
		self.in_pos = Vector3(0,72,0)
	    self.base_scale = .75
		self.selected_scale = .8
	    self:SetScale(self.base_scale)
	else
		self.bg = self.root:AddChild(Image(HUD_ATLAS, "inventory_bg.tex"))
		self.bgcover = self.root:AddChild(Image(HUD_ATLAS, "inventory_bg_cover.tex"))
	end

    self.hovertile = nil
-- 【★ 两套「跟随物品的浮层」状态并存】
--   hovertile  —— 鼠标模式：跟随鼠标的物品图（第 1504 行挂在 mousefollow 下）
--   cursortile —— 手柄模式：跟随光标位置的物品图（第 1342 行）
-- 第 474 行 OnUpdate 与第 1273 行 UpdateCursor 按 ControllerAttached() 分流。
-- ★ 这是「同一功能两套实现」的典型：
-- 因为鼠标靠 hover 触发、手柄靠 cursor 触发，事件源根本不同。
-- 代价是两处代码要同步维护，好处是各自简单。
    self.cursortile = nil

    self.repeat_time = .2
-- repeat_time=.2：光标连发的初始延迟。
-- ★ 手柄长按方向键要能连续移动光标，机制是：
--   首次按下后等 .2 秒，之后进入连发循环（第 565-608 行）。
-- reps 记录已连发次数，用于切换连发速度（第 464-472 行）。
	self.reps = 0

    --this is for the keyboard / controller inventory controls
-- 【actionstring：手柄操作提示条（★ 本文件第二大块逻辑，第 994-1248 行）】
-- 手柄没有键盘按键提示，所有能做的操作都要以文字列出。
-- 结构：actionstring（根，隐藏态）
--        ├ actionstringtitle（物品名，第 90 行）
--        └ actionstringbody（操作列表，第 93 行）
-- ★ 第 94 行 EnableWordWrap(true)：手柄提示文字长，必须能换行。
-- 第 95 行默认 Hide，靠光标移动触发显示（第 671 行）。
    self.actionstring = self.root:AddChild(Widget("actionstring"))
    self.actionstring:SetScaleMode(SCALEMODE_PROPORTIONAL)

    self.actionstringtitle = self.actionstring:AddChild(Text(TALKINGFONT, 35))
    self.actionstringtitle:SetColour(204/255, 180/255, 154/255, 1)

    self.actionstringbody = self.actionstring:AddChild(Text(TALKINGFONT, 25))
    self.actionstringbody:EnableWordWrap(true)
    self.actionstring:Hide()

    self.hovertile_hide_sources = SourceModifierList(self.inst, false, SourceModifierList.boolean)
-- ★ SourceModifierList：多来源的布尔「或」聚合器。
-- 用来实现「只要有任一来源要求隐藏，就隐藏悬停物品」。
-- 第 97 行第三个参数 SourceModifierList.boolean —— 按布尔语义聚合。
-- 典型场景：正在放建造蓝图时（deployplacer）不该显示手持物品图。
-- ★ 这个模式 DST 里到处用，移植自研项目做「多来源互斥遮罩」时可直接复用。
    self.hover_tile_visibility = true
    --default equip slots
	if TheNet:GetServerGameMode() == "quagmire" then
-- ★ 装备槽数量按模式不同：quagmire 只有 HANDS（单手），
-- 默认模式有 HANDS/BODY/HEAD 三个。
-- 第 101 行与第 103 行前半段代码**完全相同**（都是 HANDS + equip_slot.tex），
-- 只有 else 分支才额外加 BODY/HEAD。
-- 可简化为「总是加 HANDS，quagmire 之外再加 BODY/HEAD」，
-- 但现状无害，保留原样更安全（改动会牵动 sortkey 排序与第 703 行逻辑）。
		self:AddEquipSlot(EQUIPSLOTS.HANDS, HUD_ATLAS, "equip_slot.tex")
	else
		self:AddEquipSlot(EQUIPSLOTS.HANDS, HUD_ATLAS, "equip_slot.tex")
		self:AddEquipSlot(EQUIPSLOTS.BODY, HUD_ATLAS, "equip_slot_body.tex")
		self:AddEquipSlot(EQUIPSLOTS.HEAD, HUD_ATLAS, "equip_slot_head.tex")
	end

    self.inst:ListenForEvent("builditem", function(inst, data) self:OnBuild() end, self.owner)
-- 【★★ 事件驱动：13 个监听器 = 本文件的「数据流入口」】
-- ★ 核心洞察：**背包 UI 不是轮询服务端状态，而是被事件推着走**。
-- 服务端发事件 → 客户端 Inst:ListenForEvent 接住 → 转成 Rebuild/Refresh。
-- 这避免了每帧全量同步背包的开销。
--
-- 事件清单（按语义分三类）：
--   ① 物品流动：itemget(109) / itemlose(113) / equip(110) / unequip(111)
--      → 走 OnItemGet / OnItemLose / OnItemEquip / OnItemUnequip，局部更新
--   ② 结构变化：refreshinventory(114) → Refresh(true)，全量刷新
--   ③ 玩家替换：seamlessplayerswap(122) / finishseamlessplayerswap(125)
--      → 停止更新 / 延迟重建（见下方说明）
-- ★ 移植自研游戏时，若目标平台有可靠的事件系统，务必走事件而非轮询。
    self.inst:ListenForEvent("itemget", function(inst, data) self:OnItemGet(data.item, self.inv[data.slot], data.src_pos, data.ignore_stacksize_anim) end, self.owner)
    self.inst:ListenForEvent("equip", function(inst, data) self:OnItemEquip(data.item, data.eslot) end, self.owner)
    self.inst:ListenForEvent("unequip", function(inst, data) self:OnItemUnequip(data.item, data.eslot) end, self.owner)
    self.inst:ListenForEvent("newactiveitem", function(inst, data) self:OnNewActiveItem(data.item) end, self.owner)
    self.inst:ListenForEvent("itemlose", function(inst, data) self:OnItemLose(self.inv[data.slot]) end, self.owner)
	self.inst:ListenForEvent("refreshinventory", function() self:Refresh(true) end, self.owner)
    self.inst:ListenForEvent("onplacershown", function() self:OnPlacerChanged(true) end, self.owner)
    self.inst:ListenForEvent("onplacerhidden", function() self:OnPlacerChanged(false) end, self.owner)

    self.inst:ListenForEvent("sethovertilehidemodifier", function(src, data) self:SetHoverTileHideModifier(data.source, data.hidden, data.key) end, self.owner)

    --NOTE: this is triggered on the swap SOURCE. we need to stop updates because
-- 【★ 换人（seamless swap）的两阶段处理 —— 注释本身就说明了坑】
-- 源码原注释：触发在 swap 的「源」上，必须 StopUpdating，
-- 因为 playercontroller 组件先被移除，实体移除是延迟的。
--
-- ★ 翻译成机制语言：换角色时 Inv 会被从旧 owner 身上「移交」给新 owner。
-- 移交过程中旧引用会失效，若继续 Update 就会访问已销毁的对象。
-- 所以第 122 行先「断血」，等第 125 行（新归属确立）再「复活重建」。
--
-- ★ 这是分布式 UI 的经典问题：控件的生命周期与数据所有者的生命周期
-- 未必一致。DST 的解法是「源侧停更 + 目标侧重启」，两段式。
-- ⚠️ 移植时若你的框架没有这种「实体延迟销毁」，
-- 需要自己保证 Update 里所有引用都做有效性检查。
    --      playercontroller component is removed first, entity remove is delayed.
    self.inst:ListenForEvent("seamlessplayerswap", function() self:StopUpdating() end, self.owner)

    --NOTE: this is triggered on the swap TARGET.
    self.inst:ListenForEvent("finishseamlessplayerswap", function () if self.rebuild_pending then self.rebuild_snapping = true self:Rebuild() self:Refresh() end end, self.owner)
-- 【★ 重建时的「吸附」处理，细节很讲究】
-- rebuild_snapping = true → Rebuild + Refresh。
-- 在 RebuildLayout 里（第 375-378 行）看到该标志就
-- **跳过 MoveTo 补间，直接 SetPosition 瞬移到目标**。
--
-- ★ 为什么？换人时新角色的背包要从旧位置滑过去会显得诡异，
-- 瞬移更干净。rebuild_snapping 就是「本次重建不要动画」的内部信号。
-- ⚠️ 这个标志在 Rebuild 末尾（第 461 行）清空，
-- 意味着它只影响「紧接着的这一帧」的重建。

    self.root:SetPosition(self.in_pos)
    self:StartUpdating()

    self.actionstringtime = CURSOR_STRING_DELAY

    self.openhint = self:AddChild(Text(UIFONT, 52))
    self.openhint:SetRegionSize(300, 60)
    self.openhint:SetHAlign(ANCHOR_LEFT)
	if TheNet:GetServerGameMode() == "quagmire" then
	    self.openhint:SetPosition(400, 70, 0)
	else
	    self.openhint:SetPosition(940, 70, 0)
	end

    self.hint_update_check = HINT_UPDATE_INTERVAL

    self.controller_build = nil
    self.integrated_backpack = nil
    self.force_single_drop = false
	self.autopaused = false
	self.autopause_delay = 0
end)

function Inv:AddEquipSlot(slot, atlas, image, sortkey)
-- AddEquipSlot：**只登记，不立刻建控件**。
-- 把装备槽信息塞进 equipslotinfo 并排序，然后置 rebuild_pending。
-- ★★★ 这是「延迟重建」模式的最纯粹示范：
--   调用方连续调三次 AddEquipSlot，不会建出三个控件、也不会建两次；
--   只是排好队，等 OnUpdate（第 522 行）统一 Rebuild 一次。
--
-- ★ 为什么必须这样？因为 Rebuild 很贵（要重算全部槽位坐标）。
--   若每加一个槽就重建一次，加 3 个槽 = 重建 3 次，坐标还会算错
--   （中间态的装备槽数不对，total_w 算出来的底板宽度是错的）。
--
-- ★★ 移植要点：「批量修改请求」的正确姿势是置脏标记 + 下一帧统一处理，
--   而不是立刻执行。这是所有 UI/游戏循环都该用的模式。
-- 第 151 行 sortkey 默认取表长度，保证新槽排到末尾。
-- 第 153 行每次插入后重排 —— 装备槽显示顺序由 sortkey 决定（mod 可改）。
    sortkey = sortkey or #self.equipslotinfo
    table.insert(self.equipslotinfo, {slot = slot, atlas = atlas, image = image, sortkey = sortkey})
    table.sort(self.equipslotinfo, function(a,b) return a.sortkey < b.sortkey end)
    self.rebuild_pending = true
end

local function BackpackGet(inst, data)
-- 【★ overflow（溢出背包）的事件转发 —— 为什么要多这一层？】
-- 背包栏本身（inv）和溢出容器（overflow，即第二行）是**两个 container**。
-- 第 349-352 行给 overflow.inst 也挂了同名事件监听。
-- 但事件回调里不能直接用 self：此时可能已经换人（ThePlayer 变了）。
-- 所以第 158-159 行**重新取当前玩家**并逐层判空：
--   owner → owner.HUD → owner.replica.inventory → IsHolding(inst)。
--
-- ★★ 这是本文件最值得学的一段防御式编码：
--   「UI 控件可能活得比它引用的数据更久」，
--   任何跨实体的事件回调都必须重新解析引用并判空，
--   否则会拿到上一个玩家的 HUD，造成「操作错人背包」的诡异 bug。
-- IsHolding(inst) 确认这个事件确实是「当前打开的这个容器」发出的，
-- 防止别的容器（如同时打开的冰箱）的同名事件串台。
    local owner = ThePlayer
    if owner ~= nil and owner.HUD ~= nil and owner.replica.inventory:IsHolding(inst) then
        local inv = owner.HUD.controls.inv
        if inv ~= nil then
            inv:OnItemGet(data.item, inv.backpackinv[data.slot], data.src_pos, data.ignore_stacksize_anim)
        end
    end
end

local function BackpackLose(inst, data)
    local owner = ThePlayer
    if owner ~= nil and owner.HUD ~= nil and owner.replica.inventory:IsHolding(inst) then
        local inv = owner.HUD.controls.inv
        if inv ~= nil then
            inv:OnItemLose(inv.backpackinv[data.slot])
        end
    end
end

local function BackpackRefresh(inst)
	local owner = ThePlayer
	local inventory = owner and owner.HUD and owner.replica.inventory or nil
	local overflow = inventory and inventory:GetOverflowContainer() or nil
	if overflow and overflow.inst == inst then
		local inv = owner.HUD.controls.inv
		if inv then
			inv:RefreshIntegratedContainer()
		end
	end
end

local function RebuildLayout_Quagmire(self, inventory, overflow, do_integrated_backpack, do_self_inspect)
-- RebuildLayout_Quagmire：圣旗模式**独立写了一份**布局函数。
-- 与通用版 RebuildLayout（第 240 行）并存，由第 441-445 行二选一调用。
-- ★ 为什么不抽象成「配置驱动的布局」？
-- 因为圣旗模式槽位尺寸/间距全不同（inv_w=68 但 inv_sep=10），
-- 且起点 x 固定为 -165（不分居中）。
--
-- ⚠️ 代价：两套布局逻辑要各自维护。
--   若新增第三种模式，势必要再复制一份。
-- ★ 这正是 templates.lua 里 CenterPanel/CenterPanelOld 同构的历史包袱
--   在不同文件里的翻版 —— DST 的 UI 技术债主要来自「模式特判」。
--
-- ★ 但反面看：这也是「不强行抽象」 pragmatically 的选择。
--   两套 ~55 行代码各自清晰，好过一层充满 if 的万能函数。
	local inv_scale = 1
	local inv_w = 68 * inv_scale
	local inv_sep = 10 * inv_scale
	local inv_y = -77
	local inv_tip_y = inv_w + inv_sep + (30 * inv_scale)
-- inv_tip_y = inv_w + inv_sep + 30：槽位提示条的 Y 偏移。
-- ★ 换算成「槽高 + 间距 + 文字高度」，即提示条落在槽位正下方。
-- 通用版对应的是第 276 行的 slot.top_align_tip = W*.5 + YSEP。
-- ★ 注意两处单位不同：这里 inv_w 是全宽（68），
-- 通用版 W*.5 = 34 是半宽（因为 top_align_tip 以槽中心为原点）。
-- 混用这两个数会导致提示条位置差一倍。

    local num_slots = inventory:GetNumSlots()
    local x = -165
    for k = 1, num_slots do
        self.inv[k] = InvSlot(k, HUD_ATLAS, "inv_slot.tex", self.owner, self.owner.replica.inventory)
		local slot = self.toprow:AddChild(Widget("slot_scaler"..k))
		slot:AddChild(self.inv[k])
        slot:SetPosition(x, inv_y)
		slot:SetScale(inv_scale)
        slot.top_align_tip = inv_w + inv_sep + 30 -- tooltip text offset when using cursors

        local item = inventory:GetItemInSlot(k)
        if item ~= nil then
            self.inv[k]:SetTile(ItemTile(item))
        end

        x = x + 83
    end

	local equip_scale = 0.8
	local equip_y = -74

    local hand_slot = self.equipslotinfo[1]
    local slot = EquipSlot(hand_slot.slot, hand_slot.atlas, hand_slot.image, self.owner)
    slot:SetPosition(x, equip_y)
	slot.highlight_scale = 1
	slot.base_scale = equip_scale
	slot:SetScale(equip_scale)


    self.equip[hand_slot.slot] = self.toprow:AddChild(slot)

    local item = inventory:GetEquippedItem(hand_slot.slot)
    if item ~= nil then
        slot:SetTile(ItemTile(item))
    end


    self.toprow:SetPosition(0, 75)
    self.bg:SetPosition(0, 15)

    self.root:SetPosition(self.in_pos)
    self:UpdatePosition()
end

local function RebuildLayout(self, inventory, overflow, do_integrated_backpack, do_self_inspect)
    local y = overflow ~= nil and ((W + YSEP) / 2) or 0
-- ★ 有 overflow（第二行）时整条 bar 上移 (W+YSEP)/2 = 38，
-- 为 bottomrow 让出垂直空间。这是「无布局引擎」的经典手工避让：
-- 子容器数量变了，父容器位置要跟着补偿。
-- 有布局引擎的话这里会是一行 flex 配置。
    local eslot_order = {}

    local num_slots = inventory:GetNumSlots()
    local num_equip = #self.equipslotinfo
    local num_buttons = do_self_inspect and 1 or 0
    local num_slotintersep = math.ceil(num_slots / 5)
-- 【★★ 槽位网格公式 —— 全文件最该抄的一段布局代码】
-- num_slotintersep = ceil(num_slots / 5)：物品栏每 5 格一组，
--   组与组之间要额外加 INTERSEP 的间距，所以组数 = ceil(格数/5)。
-- ★ 例：12 格 → ceil(12/5)=3 组 → 3 处大间距。
--   这是「N 列网格」的分组间距计数，公式为 ceil(n/cols)。
--
-- total_w（第 249 行）= 槽数×W + (槽数-1)×SEP + 组数×INTERSEP
--   三项含义：槽本身宽度 / 槽间常规间距 / 分组大间距。
--   ★ (槽数-1) 而不是槽数 —— 间距比槽子少一个，这是网格排布的通用规律。
--
-- ★★ 整个公式的意义：算出整条背包的**总宽度**，
--   用来把内容水平居中（第 271 行 x = (W-total_w)*.5）
--   并把底板拉伸到刚好匹配（第 361 行 bg:Flow(total_w+60, 256)）。
--   即「先算内容宽 → 再据此摆内容、拉伸背景」的两步法。
    local num_equipintersep = num_buttons > 0 and 1 or 0
    local total_w = (num_slots + num_equip + num_buttons) * W + (num_slots + num_equip + num_buttons - num_slotintersep - num_equipintersep - 1) * SEP + (num_slotintersep + num_equipintersep) * INTERSEP

	local x = (W - total_w) * .5 + num_slots * W + (num_slots - num_slotintersep) * SEP + num_slotintersep * INTERSEP
-- ★ 这一行是**从右边往左**推算装备槽的起始 x：
--   左侧留白 (W-total_w)/2
-- + 物品区总宽（num_slots 个 W + (num_slots-1) 个 SEP + 分组 INTERSEP）
--
-- ★ 为什么要先算装备区起点？第 252-269 行的装备槽循环是第一个循环，
--   此刻 x 必须已指向「物品区右边界之后」的位置。
--   紧接着第 271 行又把 x 重置为左侧起点开始排物品槽。
--
-- ★★ 这是「一趟向左、一趟向右」的双向排布：
--   装备槽在物品栏右侧（第 251 行算出其起点），
--   物品槽从左边缘开始（第 271 行起点）。
-- ⚠️ 整个文件没有一处循环同时排两者，全靠这个「先跳到右端」的动作。
--   改动布局时务必同时看这两处，否则装备槽会跑到物品栏左边。
    for k, v in ipairs(self.equipslotinfo) do
        local slot = EquipSlot(v.slot, v.atlas, v.image, self.owner)
-- EquipSlot vs InvSlot：装备槽是特化控件（自带装备图标、不能自由放东西）。
-- ★ 第 260 行 SetTile(ItemTile(item)) —— 装备槽与物品槽共用同一个 ItemTile，
-- 说明「显示一个物品」与「槽位类型」是解耦的两层。
-- 这是 widget 组合式设计的好处：换槽型不影响物品渲染。
        self.equip[v.slot] = self.toprow:AddChild(slot)
        slot:SetPosition(x, 0, 0)
        table.insert(eslot_order, slot)

        local item = inventory:GetEquippedItem(v.slot)
        if item ~= nil then
            slot:SetTile(ItemTile(item))
        end

        if v.slot == EQUIPSLOTS.HANDS then
            self.hudcompass:SetPosition(x, do_integrated_backpack and 80 or 40, 0)
-- ★ 罗盘（hudcompass）与手部图标（hand_inv）跟随 HANDS 装备槽定位：
-- HANDS 槽就是玩家「当前手持物」的位置，把这两个 UI 钉在它上面，
-- 视觉上就成了「手里拿着的东西」。
-- do_integrated_backpack 时下移 80 而非 40，避开第二行背包。
-- ★ 这是「用另一个控件的坐标驱动自己」—— 无布局引擎下的常见手法。
            self.hand_inv:SetPosition(x, do_integrated_backpack and 80 or 40, 0)
        end

        x = x + W + SEP
    end

    x = (W - total_w) * .5
    for k = 1, num_slots do
        local slot = InvSlot(k, HUD_ATLAS, "inv_slot.tex", self.owner, self.owner.replica.inventory)
        self.inv[k] = self.toprow:AddChild(slot)
        slot:SetPosition(x, 0, 0)
        slot.top_align_tip = W * .5 + YSEP
-- ★ slot.top_align_tip = W*.5 + YSEP：记录「提示条应在此槽上方（W/2 处）」。
-- 注意是给**槽位对象**打标记，而非直接算提示条坐标。
-- 第 1208 行 UpdateCursorText 再读这个标记决定提示条朝向。
--
-- ★★ 「由数据生产者声明布局意图，由消费者读取」——
--   这是本文件处理所有对齐问题的统一手法，避免了中心化的布局管理器。
--   对比 containers.lua 里 side_align_tip/top_align_tip/bottom_align_tip，
--   同一套字段也用于游戏内容器（冰箱/箱子）的提示条定位。
--   → 即：**背包与箱子共用一套提示条定位协议**，靠这三个字段区分。

        local item = inventory:GetItemInSlot(k)
        if item ~= nil then
            slot:SetTile(ItemTile(item))
        end

        x = x + W + (k % 5 == 0 and INTERSEP or SEP)
    end

    local owner_prefab = self.owner.prefab
-- 【★★ 数据驱动 UI：按角色动态选图集】
-- image_name = "self_inspect_" .. prefab .. ".tex"
-- atlas_name = "images/avatars/self_inspect_" .. prefab .. ".xml"
-- ★ 命名约定即接口：角色 prefab 名（wanda/wilba/wortox…）
--   拼进图集路径，美术只要按约定命名资源，代码零改动支持新角色。
--
-- 第 289 行 softresolvefilepath(atlas_name) == nil 探测资源是否存在：
-- ★ 「文件不存在」被用作特性开关 —— 老角色没这套图，就回退到通用图。
--   softresolvefilepath 是 Klei 的软路径解析，不会崩。
-- ⚠️ 这让「资源缺失」从错误变成了静默回退：
--   新角色忘了加图，玩家看到的是通用图标而不是报错，很难排查。
--   移植时建议至少加一条日志。
    local image_name = "self_inspect_".. owner_prefab ..".tex"
    local atlas_name = "images/avatars/self_inspect_".. owner_prefab.. ".xml"
    if softresolvefilepath(atlas_name) == nil then
        atlas_name = HUD_CHARACTERS[owner_prefab] or HUD_ATLAS
    end

    if do_self_inspect then
-- do_self_inspect（能否查看自己）：决定是否加「查看自己」按钮。
-- ★ 第 294-295 行同步拉伸底板 bg/bgcover 到 1.22（比第 303 行的 1.15 更宽），
--   因为多了一个按钮，总宽度变大。
--   → 「内容变多 → 背景跟着变宽」，这就是第 249 行 total_w 的用途。
-- ★ 第 302-310 行的 else 分支处理「从有变无」：
--   第 306-309 行显式 Kill 掉 inspectcontrol 并置 nil。
--   ⚠️ 不置 nil 的话，下次 Rebuild（第 409 行）会把它当残留节点处理。
--   「创建与销毁严格配对」是这段的要点。
        self.bg:SetScale(1.22, 1, 1)
        self.bgcover:SetScale(1.22, 1, 1)

        self.inspectcontrol = self.toprow:AddChild(TEMPLATES.IconButton(atlas_name, image_name, STRINGS.UI.HUD.INSPECT_SELF, false, false, function() self.owner.HUD:InspectSelf() end, nil, "self_inspect_mod.tex"))
        self.inspectcontrol.icon:SetScale(.7)
        self.inspectcontrol.icon:SetPosition(-4, 6)
        self.inspectcontrol:SetScale(1.25)
        self.inspectcontrol:SetPosition((total_w - W) * .5 + 3, -7, 0)
    else
        self.bg:SetScale(1.15, 1, 1)
        self.bgcover:SetScale(1.15, 1, 1)

        if self.inspectcontrol ~= nil then
            self.inspectcontrol:Kill()
            self.inspectcontrol = nil
        end
    end

    local hadbackpack = self.backpack ~= nil
-- ★★ 溢出背包的事件监听「先解绑再重建」，三步走：
--   314-316 行 RemoveEventCallback 三个监听
--   317 行 self.backpack = nil
-- 第 320 行分支若需要 overflow，则第 349-352 行重新绑定。
--
-- ★ 为什么必须先解绑？RebuildLayout 会在物品栏数量变化时被反复调用
-- （换人、开合容器、模式切换）。若不解绑，每次都多挂一个监听器，
-- → 同一个事件触发 N 次 → OnItemGet 被调 N 次 → 物品图重复创建 + 内存泄漏。
--
-- ★★ 移植要点：任何「挂到外部对象上的监听」都要成对管理，
--   且重建前必须清理。这是 UI 与外部对象交互的头号泄漏源。
    if hadbackpack then
        self.inst:RemoveEventCallback("itemget", BackpackGet, self.backpack)
        self.inst:RemoveEventCallback("itemlose", BackpackLose, self.backpack)
		self.inst:RemoveEventCallback("refresh", BackpackRefresh, self.backpack)
        self.backpack = nil
    end

    if do_integrated_backpack then
        local num = overflow:GetNumSlots()

        local x = - (num * (W+SEP) / 2)
-- 集成背包（第二行）的排布有两种策略，由 offset 正负决定：
--   offset > 0（第 336-337 行）：借用主背包第 offset..offset+n-1 格的 x 坐标
--   offset ≤ 0（第 338-341 行）：自己从 x=-num*(W+SEP)/2 起居中排
--
-- ★ 逻辑：当 overflow 槽数 ≤ 主背包槽数时，多余的主背包槽位空着，
--   overflow 对齐到主背包**右侧一段**，视觉上像同一行；
--   否则 overflow 自己居中另起一行。
-- 第 325 行 offset = 1 + #self.inv - num。
-- ⚠️ 这是「两套坐标二选一」的手写布局分支，逻辑正确但不易维护。
        --local offset = #self.inv >= num and 1 or 0 --math.ceil((#self.inv - num)/2)
        local offset = 1 + #self.inv - num

		self.integrated_arrow = self.bottomrow:AddChild(Image(HUD_ATLAS, "inventory_bg_arrow.tex"))
-- integrated_arrow：指向第二行的箭头图标。
-- 第 328 行定位方式是**读取主背包最后一格的实际坐标**再右移，
-- 而不是用公式重算 —— 这样即使主背包布局将来变了，箭头仍跟着对。
-- ★ 「用已有控件的真实坐标定位新控件」是无布局引擎下的稳妥做法，
-- 比复制公式更抗改动。
		self.integrated_arrow:SetPosition(self.inv[#self.inv]:GetPosition().x + W * 0.5 + INTERSEP + 61, 8)

        for k = 1, num do
            local slot = InvSlot(k, HUD_ATLAS, "inv_slot.tex", self.owner, overflow)
            self.backpackinv[k] = self.bottomrow:AddChild(slot)

            slot.top_align_tip = W*1.5 + YSEP*2

            if offset > 0 then
                slot:SetPosition(self.inv[offset+k-1]:GetPosition().x,0,0)
            else
                slot:SetPosition(x,0,0)
                x = x + W + SEP
            end

            local item = overflow:GetItemInSlot(k)
            if item ~= nil then
                slot:SetTile(ItemTile(item))
            end
        end

        self.backpack = overflow.inst
        self.inst:ListenForEvent("itemget", BackpackGet, self.backpack)
        self.inst:ListenForEvent("itemlose", BackpackLose, self.backpack)
		self.inst:ListenForEvent("refresh", BackpackRefresh, self.backpack)
    end

    if hadbackpack and self.backpack == nil then
-- hadbackpack 且重建后没有 backpack → 说明玩家收起了溢出背包，
-- 此时重置光标到默认槽，避免 active_slot 指向已被 Kill 的槽位。
-- ★ 「外部状态变化后清理内部选择」的典型处理。
-- 不做的话，第 552 行虽然有 IsValid 检查，但会有一帧的错误状态。
        self:SelectDefaultSlot()
    end

    if self.bg.Flow ~= nil then
-- ★ 底板自适应宽度：Flow 是三段切片（3-slice）拉伸，
-- 比 NineSlice 便宜（只需首/中/尾三块而非九块）。
-- total_w + 60：槽区总宽 + 两侧各留 30 像素边距。
-- ⚠️ 这意味着**底板宽度是算出来的**，与第 249 行 total_w 强耦合。
--   若只改 INTERSEP 而漏改此处，底板与槽位会不匹配。
--   ★ 这类「同一数值在两处使用」的耦合是本文件最易出错的地方。
        -- note: Flow is a 3-slice function
        self.bg:Flow(total_w + 60, 256, true)
    end

    if TheNet:GetServerGameMode() == "lavaarena" then
        self.bg:SetPosition(15, 0)
        self.bg:SetScale(1)
        self.toprow:SetPosition(0, 3)
        self.root:SetPosition(self.in_pos)
    elseif do_integrated_backpack then
        self.bg:SetPosition(0, -24)
        self.bgcover:SetPosition(0, -135)
        self.toprow:SetPosition(0, .5 * (W + YSEP))
        self.bottomrow:SetPosition(0, -.5 * (W + YSEP))

        if self.rebuild_snapping then
-- rebuild_snapping（见第 125 行）→ 瞬移而非补间。
-- CancelMoveTo 必须先调：否则之前发起的 MoveTo 动画会在瞬移后
-- 继续把 root 拉回旧位置，造成「刚瞬移又滑回去」的抖动。
-- ★ MoveTo/CancelMoveTo 成对使用，是补间动画的基本纪律。
			self.root:CancelMoveTo()
            self.root:SetPosition(self.in_pos)
            self:UpdatePosition()
        else
            self.root:MoveTo(self.out_pos, self.in_pos, .5)
        end
    else
        self.bg:SetPosition(0, -64)
        self.bgcover:SetPosition(0, -100)
        self.toprow:SetPosition(0, 0)
        self.bottomrow:SetPosition(0, 0)

        if do_integrated_backpack and not self.rebuild_snapping then
-- ⚠️★★ 【真实缺陷 · 已逐行核实】此处分支永远为假。
--
-- 上下文：第 369 行是 `elseif do_integrated_backpack then`，
--          第 382 行的 `else` 意味着 **do_integrated_backpack 必为 false**。
--          而第 388 行条件正是 `do_integrated_backpack and not self.rebuild_snapping`，
--          短路求值下第一项即 false → 整个条件恒假。
--
-- 后果：第 389 行 self.root:MoveTo(self.in_pos, self.out_pos, .2)
--（收背包的滑出动画）**永远不执行**，恒走 else 分支瞬移到 out_pos。
--
-- ★ 判定：这是从第 369 行重构时遗留的旧逻辑分支。
--   因为「有第二行背包」和「需要滑出动画」在当前结构里互斥，
--   该分支已失去意义。属死代码，不是运行时 bug（不影响现有行为）。
--
-- ⚠️ 但风险在于：若日后有人修改第 369 行的条件使其能同时成立，
--   会期望看到滑出动画却得到瞬移，且没有任何报错提示。
-- 建议在第 388 行加注释说明其为死分支，或直接删除。
-- （我已对照第 369/382/388 三行确认行号与逻辑无误。）
            self.root:MoveTo(self.in_pos, self.out_pos, .2)
        else
			self.root:CancelMoveTo()
            self.root:SetPosition(self.out_pos)
            self:UpdatePosition()
        end
    end
end

function Inv:Rebuild()
-- 【★★ Rebuild：整条背包栏的结构性重建】
-- 被调用时机：AddEquipSlot 置脏后（522 行）、finishseamlessplayerswap（125 行）、
-- 以及首次 Refresh（1150 行的 Refresh 里 self.rebuild_pending 判断）。
-- ★ 与 Refresh 的分工（★ 面试常问）：
--   Rebuild —— 改**结构**：槽位数量、坐标、底板宽度、按钮有无。贵。
--   Refresh —— 改**内容**：每个槽里放哪个物品。便宜。
-- 频繁 Refresh 无妨，Rebuild 必须尽量少（靠 rebuild_pending 合并）。
    if self.cursor ~= nil then
        self.cursor:Kill()
        self.cursor = nil
    end

    if self.toprow ~= nil then
-- ★ 第 405-407 行：toprow_inv 需要被「摘下来再挂回去」，不能随 toprow 一起 Kill。
--   因为 toprow_inv 是**跨重建持久存在**的容器（存放外部塞进来的控件）。
-- ★ 若直接 Kill 会把外部控件一起销毁，调用方持有的引用就悬空了。
-- 移植要点：重建子树时，先把「不属于本子树但需要保留」的节点摘出。
		if self.toprow_inv then
			self.toprow:RemoveChild(self.toprow_inv)
		end
        self.toprow:Kill()
		self.inspectcontrol = nil
    end

    if self.bottomrow ~= nil then
        self.bottomrow:Kill()
    end

    self.toprow = self.root:AddChild(Widget("toprow"))
-- 新建 toprow / bottomrow 两行容器。
-- ★ toprow 装主背包与装备槽，bottomrow 装溢出背包（第 330-347 行）。
--   两行分开是为了能独立上移/下移（第 372-373、385-386 行）。
-- 紧接着第 425-427 行把三个记录表清空 ——
-- ★ 重建前必须清空索引表，否则会残留上一轮的槽位引用。
--   这是「重建 = 清空 + 重建」标准模式的体现。
	if self.toprow_inv then
		self.toprow:AddChild(self.toprow_inv)
	else
		self.toprow_inv = self.toprow:AddChild(Widget("toprow_inv"))
	end

	self.bottomrow = self.root:AddChild(Widget("bottomrow"))

    self.inv = {}
    self.equip = {}
    self.backpackinv = {}

	local controller_attached = TheInput:ControllerAttached()
-- 【★ 交互模式探测：手柄 or 键鼠，直接决定布局形态】
-- controller_attached = TheInput:ControllerAttached()
--
-- ★ 关键：手柄玩家**总是**有集成背包（第 431 行的 or 短路），
--   因为手柄没法像鼠标那样精确点开容器，必须把 overflow 摆出来。
--   键鼠玩家则由 Profile 设置决定（第 431 行后半段）。
--
-- ★★ 这是「输入设备决定 UI 形态」的例子：
--   自研游戏做手柄适配时，输入方式会反过来约束界面布局，
--   而不只是「给现有界面加按键映射」。
    self.controller_build = controller_attached
	self.integrated_backpack = controller_attached or Profile:GetIntegratedBackpack()

    local inventory = self.owner.replica.inventory

	local overflow = inventory:GetOverflowContainer()
	overflow = (overflow ~= nil and overflow:IsOpenedBy(self.owner)) and overflow or nil
-- ★★ overflow 归属校验：必须确认这个容器是「当前玩家打开的」。
-- IsOpenedBy(self.owner) 防止拿到别人（如队友代开）的容器。
-- 第 438 行再与 integrated_backpack 相与 —— 两个条件缺一不可。
-- ★ 这是安全校验：UI 绝不能展示/操作不属于当前玩家的数据。

	local do_integrated_backpack = overflow ~= nil and self.integrated_backpack
    local do_self_inspect = not (self.controller_build or GetGameModeProperty("no_avatar_popup"))
-- do_self_inspect = not (controller_build or no_avatar_popup)
-- ★ 手柄模式不给「查看自己」按钮：手柄玩家按不出鼠标点击，
--   且该功能对查看装备状态意义不大。
-- GetGameModeProperty("no_avatar_popup") 让 mod 能全局禁用。
-- ★ 「游戏模式属性」是 DST 的扩展点：一个 flag 关掉一组 UI 行为。

	if TheNet:GetServerGameMode() == "quagmire" then
		RebuildLayout_Quagmire(self, inventory, overflow, do_integrated_backpack, do_self_inspect)
	else
		RebuildLayout(self, inventory, overflow, do_integrated_backpack, do_self_inspect)
	end

	for k, v in pairs(self.toprow_inv.children) do
-- 重建后让外部塞进 toprow_inv 的控件重算坐标。
-- ★ 为什么必须显式调？它们不是 toprow_inv 的自动子节点，
--   坐标基于旧布局算的。布局一变就得通知它们 RefreshPosition。
-- ⚠️ 漏掉这行 → 外部控件停留在旧坐标，视觉上「错位但不报错」。
		v:RefreshPosition()
	end

    self.actionstring:MoveToFront()

    self:SelectDefaultSlot()
    self:UpdateCursor()

    if self.cursor ~= nil then
        self.cursor:MoveToFront()
    end

    self.rebuild_pending = nil
-- rebuild_pending / rebuild_snapping 清空。
-- ★ 置 pending 的唯一目的是「让下次 OnUpdate 执行 Rebuild」，
--   执行完必须清掉，否则会无限重建（每帧一次，直接卡死）。
    self.rebuild_snapping = nil
end

function Inv:RefreshRepeatDelay(control)
-- 【★ 连发速度的三档策略】
-- reps<=1：首次 —— 最慢（inventory_repeat_base），给玩家反应时间；
-- reps>=3 且摇杆推到底(>0.95)：最快（inventory_repeat_ninja），
--   快速长距离移动；
-- 其余：中间档（inventory_repeat_fast）。
--
-- ★ 设计意图清晰：**起手慢 → 连发中 → 推到底最快**。
-- 这避免了「一推就飞速乱窜」的失控感，也是竞速游戏的标准手感设计。
-- ⚠️ 这三个值来自 TheFrontEnd（用户设置），允许玩家调 —— 手感应当可定制。
	if self.reps <= 1 then
		self.repeat_time = TheFrontEnd.inventory_repeat_base
	elseif self.reps >= 3 and Input:GetAnalogControlValue(control) > 0.95 then
		self.repeat_time = TheFrontEnd.inventory_repeat_ninja
	else
		self.repeat_time = TheFrontEnd.inventory_repeat_fast
	end
end

function Inv:OnUpdate(dt)
-- 【★★ OnUpdate：本文件每帧都会走一次，热点代码】
-- 可读本函数被拆成五段，依次是：
--   475-503  自动暂停判定（autopause）
--   505-516  位置刷新 + 按键提示节流
--   518-525  可见性早退 + 延迟重建
--   541-550  提示条淡出计时 + 连发计时
--   552-609  槽位有效性维护 + 光标移动
-- ★ 整体性能意识很强：多处做了「无变化则跳过」的早退。
	if self.open and not self.autopaused then
-- 【★ 自动暂停（autopause）机制 —— 手柄玩家边操作边看背包时的体验设计】
-- 问题：手柄玩家打开背包时若不暂停，NPC 会继续攻击。
-- 解决：打开背包期间自动暂停游戏。
--
-- ★ 但**多人游戏里暂停无效**（只改音频设置），所以第 481 行特判：
--   shouldautopause = stategraph 有 shouldautopausecontrollerinventory 标签
--                  或 TheWorld.ismastersim（主机）时不需要自动暂停。
-- → 联机玩家不自动暂停（避免影响别人），单机玩家自动暂停。
-- ★ 这是「按运行环境降级功能」的教科书案例。
		local playercontroller = self.owner.components.playercontroller
		if playercontroller ~= nil then
			local busy = playercontroller:IsBusy()
			if not busy and playercontroller:IsDoingOrWorking() then
				local shouldautopause = self.owner.sg ~= nil and self.owner.sg:HasStateTag("shouldautopausecontrollerinventory")
				if not (shouldautopause or TheWorld.ismastersim) then
					shouldautopause = self.owner:HasTag("shouldautopausecontrollerinventory")
				end
				busy = not shouldautopause
			end
			if self.autopause_delay > 0 then
-- 【★★ autopause_delay：0.5 秒「宽限期」—— 细节见第 880 行设置处】
-- 逻辑：玩家按下丢弃键后，给 0.5 秒让角色「真的开始动作」，
--   若动作迟迟没开始（被 busy 挡住）就强制自动暂停。
-- 三分支：
--   489 行 busy → 动作开始了，取消延迟；
--   490-492 行 仍在等待 → 继续倒计时；
--   493-497 行 超时 → 认为动作没起来，SetAutopausedInternal(true)。
--
-- ★ 为什么需要宽限期？因为「按键 → 状态机响应」有 1-2 帧延迟，
--   若立即暂停，角色会被定格在「按键已响应」的动画中途。
-- ★ 这与 SetAutopausedInternal 的 `not pause == self.autopaused`（第 899 行）
--   配合：那是防重复触发的守卫。
				if busy then
					--started doing the action
					self.autopause_delay = 0
				elseif self.autopause_delay > dt then
					--still waiting for action to start
					self.autopause_delay = self.autopause_delay - dt
				else
					--timed out before the action ever started
					self.autopause_delay = 0
					self:SetAutopausedInternal(true)
				end
			elseif not busy then
				--action finished
				self:SetAutopausedInternal(true)
			end
		end
	end

    self:UpdatePosition()

    self.hint_update_check = self.hint_update_check - dt
-- ★ hint_update_check 节流：每 2 秒才检查一次是否要更新手柄提示。
-- 第 515 行归零重计，形成 2 秒周期。
-- ★ 为什么节流？因为第 513 行的 GetLocalizedControl 会做本地化查表，
--   且提示内容不常变（除非插拔手柄）。每帧调纯属浪费。
    if 0 > self.hint_update_check then
        if #self.inv <= 0 or not TheInput:ControllerAttached() then
            self.openhint:Hide()
        else
            self.openhint:Show()
            self.openhint:SetString(TheInput:GetLocalizedControl(TheInput:GetControllerID(), CONTROL_OPEN_INVENTORY))
        end
        self.hint_update_check = HINT_UPDATE_INTERVAL
    end

    if not self.owner.HUD.shown or self.owner.HUD ~= TheFrontEnd:GetActiveScreen() then
-- 【★ 早退守卫：本帧剩余逻辑只在「HUD 可见且是当前屏幕」时执行】
-- ★ 这是性能与正确性双重守卫：
--   性能 —— 背包不在前台时，光标/连发/重建全部跳过；
--   正确性 —— 避免在看不见的时候悄悄改变 UI 状态，
--           等玩家切回来会看到「莫名其妙变了」的界面。
-- ⚠️ 注意它在第 522 行的 Rebuild **之前**：
--   所以「看不见时不重建」是有意设计，不是遗漏。
        return
    end

    if self.rebuild_pending then
-- ★ 延迟重建的唯一执行点：
-- AddEquipSlot（第 154 行）置 dirty，这里消费。
-- ★ 关键是「消费后立刻 Rebuild + Refresh」且第 460 行会清标志，
--   保证一帧只重建一次。
-- ⚠️ 若 Rebuild 内部又置了 pending，会变成每帧重建 → 性能悬崖。
        self:Rebuild()
        self:Refresh()
    end

	if self.owner.HUD:IsCraftingOpen() or
		self.owner.HUD:IsSpellWheelOpen() or
		self.owner.HUD:IsUpgradeModuleWidgetInputFocus()
	then
        self.actionstring:Hide()
		return
	end

    --V2C: Don't set pause in multiplayer, all it does is change the
-- ★ V2C（开发期校验）注释：原本想在手柄开背包时暂停，
-- 但联机里暂停只改音频设置，会误伤玩家音频，故注释掉。
-- ★ 这类「被注释掉的功能」在本文件出现多次（第 537-539、908-910、952-954 行）。
--   与 SOP 第 4 条一致：注释掉的代码 ≠ 未实现，要看它是否真被注释。
--   这里确实是死代码。
    --     audio settings, which we don't want to do now
    --if self.open and TheInput:ControllerAttached() then
    --    SetPause(true, "inv")
    --end

    if not self.open and self.actionstring and self.actionstringtime and self.actionstringtime > 0 then
        self.actionstringtime = self.actionstringtime - dt
        if self.actionstringtime <= 0 then
            self.actionstring:Hide()
        end
    end

    if self.repeat_time > 0 then
-- repeat_time 倒计时。归零后（第 565 行）才处理方向键 → 连发循环。
-- ★ 这就是「首延迟」的实现：第一次按下走 IsControlPressed（边沿触发），
--   之后靠 repeat_time 到期重复。
        self.repeat_time = self.repeat_time - dt
    end

    if self.active_slot ~= nil and not self.active_slot.inst:IsValid() then
-- ★ 槽位有效性自愈：active_slot 指向的控件可能已被 Kill
--   （如物品被丢弃后 ItemTile 被销毁）。
-- 检测到失效就重置到默认槽，并清掉 cursor。
-- ★★ 「UI 持有的引用可能先于数据失效」—— 这是所有长生命周期 UI 的必修课。
--   注意第 676 行 CursorNav 里还有一次同样的检查，属双保险。
        self:SelectDefaultSlot()

        if self.cursor ~= nil then
            self.cursor:Kill()
            self.cursor = nil
        end
    end

    self:UpdateCursor()

    if self.shown then
        --this is intentionally unaware of focus
        if self.repeat_time <= 0 then
-- 【★ 光标移动的总入口 —— 三种输入源的优先级链】
-- 第 568-586 行：手柄摇杆（仅 open 时，即面板已展开）
-- 第 588-604 行：虚拟控制键 VIRTUAL_CONTROL_INV_*（始终可用）
--
-- ★ 顺序设计：先查实体按键，再查虚拟键。
--   虚拟键是「自定义按键映射」的产物，优先级更低但覆盖面更广。
-- ⚠️ 每个分支末尾都有 `return`（572、575、580、584、591…）：
--   移动了光标就**立即结束本帧**，不再往下走。
--   漏掉 return 会导致一帧内连移多格。
            self.reps = self.reps and (self.reps + 1) or 1

			if self.open then
				if TheInput:IsControlPressed(CONTROL_MOVE_LEFT) then
					self:RefreshRepeatDelay(CONTROL_MOVE_LEFT)
	                self:CursorLeft()
					return
				elseif TheInput:IsControlPressed(CONTROL_MOVE_RIGHT) then
					self:RefreshRepeatDelay(CONTROL_MOVE_RIGHT)
					self:CursorRight()
					return
				elseif TheInput:IsControlPressed(CONTROL_MOVE_UP) then
					self:RefreshRepeatDelay(CONTROL_MOVE_UP)
					self:CursorUp()
					return
				elseif TheInput:IsControlPressed(CONTROL_MOVE_DOWN) then
					self:RefreshRepeatDelay(CONTROL_MOVE_DOWN)
					self:CursorDown()
					return
				end
			end

			if TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_LEFT) then
				self:RefreshRepeatDelay(VIRTUAL_CONTROL_INV_LEFT)
				self:CursorLeft()
				return
			elseif TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_RIGHT) then
				self:RefreshRepeatDelay(VIRTUAL_CONTROL_INV_RIGHT)
				self:CursorRight()
				return
			elseif TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_UP) then
				self:RefreshRepeatDelay(VIRTUAL_CONTROL_INV_UP)
				self:CursorUp()
				return
			elseif TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_DOWN) then
				self:RefreshRepeatDelay(VIRTUAL_CONTROL_INV_DOWN)
				self:CursorDown()
				return
			end

			self.repeat_time = 0
			self.reps = 0
        end
    end
end

function Inv:OffsetCursor(offset, val, minval, maxval, slot_is_valid_fn)
-- 【★ OffsetCursor：带环绕与「跳过无效槽」的光标步进】
-- 用于单行内的左右/上下移动（本文件其它方向走 CursorNav）。
--
-- 环绕（第 622-623 行）：idx 越界时从另一端绕回，
--   → 光标从第 1 格按左会跳到最后一格（循环列表的直觉行为）。
-- 跳过无效（第 625-628 行）：slot_is_valid_fn 为假则继续循环，
--   → 空槽/未装备的槽不响应导航。
--
-- ★★★ 第 619-630 行的 `repeat ... until start_idx == idx` 是安全阀：
--   若所有槽都无效，环绕会让 idx 无限循环。
--   `until start_idx == idx` 表示「绕回起点就停」，最多试一圈。
-- ⚠️ 这是必需的防御：没有它，一个「全无效」的列表会让手柄卡死转圈。
-- ★ 移植要点：任何「循环查找」都要有起点回归判断，否则死循环。
    if val == nil then
        val = minval
    else
        local idx = val
        local start_idx = idx

        repeat
            idx = idx + offset

            if idx < minval then idx = maxval end
            if idx > maxval then idx = minval end

            if slot_is_valid_fn(idx) then
                val = idx
                break
            end

        until start_idx == idx
    end

    return val
end

function Inv:PinBarNav(select_pin)
	if select_pin ~= nil then
		self.actionstringtime = 0
		self.actionstring:Hide()
		self:SelectSlot(select_pin)
		return true
	end
end

function Inv:GetInventoryLists(same_container_only)
-- GetInventoryLists：决定光标能在哪些槽位列表间移动。
--
-- ★ same_container_only=true（第 646-655 行）：只在「主背包↔装备槽」之间跳，
--   不跨到溢出背包或外部容器。用于水平移动（第 698、717 行传 true）。
--   —— 因为横向移动不该突然跳进冰箱。
--
-- false（第 657-663 行）：包含 inv + equip + backpackinv + 所有打开的容器。
--   用于纵向移动（第 731 行不传参 → false），
--   因为上下移动就是要「从背包往上进入容器」。
--
-- ★★ 这是「导航范围按方向区分」的设计：横向=局部，纵向=全局。
--   自研游戏做列表/网格焦点导航时的通用思路。
-- 第 658 行从 HUD.controls.containers 取所有打开的容器 ——
--   动态扩展，无需在背包栏里硬编码容器列表。
    if same_container_only then
        local lists = {self.current_list}

        if self.current_list == self.inv then
            table.insert(lists, self.equip)
        elseif self.current_list == self.equip then
            table.insert(lists, self.inv)
        end

        return lists
    else
        local lists = {self.inv, self.equip, self.backpackinv}
		for _, v in pairs(self.owner.HUD.controls.containers) do
            table.insert(lists, v.inv)
		end

        return lists
    end
end

function Inv:CursorNav(dir, same_container_only)
-- 【★★ CursorNav：几何式焦点导航的核心】
-- 第 667 行 CancelDeployPlacement：
--   ★ 导航前先取消建造放置态 —— 否则玩家在放蓝图时按方向键，
--     焦点会跑到背包而蓝图还留在放置预览，状态错乱。
--   跨系统状态清理必须在动作入口做，这类「前置清理」很容易漏。
--
-- 第 669-672 行：手上有东西时显示提示条并重置倒计时。
--   CURSOR_STRING_DELAY=10 秒后自动淡出（第 541 行）。
--
-- 第 676 行的四重判空 —— ★ 防御式编程的教科书写法：
--   active_slot 存在 且 控件有效 且 current_list 存在 且首个槽位有效。
--   任何一项不满足就重置到默认槽并返回，绝不继续用无效引用。
    ThePlayer.components.playercontroller:CancelDeployPlacement()

    if self:GetCursorItem() ~= nil then
        self.actionstringtime = CURSOR_STRING_DELAY
        self.actionstring:Show()
    end

	local _, current_list_first_slot = next(self.current_list)

    if self.active_slot == nil or not self.active_slot.inst:IsValid() or self.current_list == nil or current_list_first_slot == nil or not current_list_first_slot.inst:IsValid() then
        self.current_list = self.inv
        self:SelectDefaultSlot()
		return true
    end

    local lists = self:GetInventoryLists(same_container_only)
    local slot, list = self:GetClosestWidget(lists, self.active_slot:GetWorldPosition(), dir)
-- ★★ 几何导航：GetClosestWidget 按方向向量找最近的可导航槽位。
-- ★ 注意返回的 slot 与 list **成对**（第 787 行）——
--   光标必须同时知道「选中哪个槽」和「当前在哪个列表」，
--   后者决定后续左右移动的边界（第 649-653 行）。
-- 第 685 行 self.current_list = list 是这个配对关系的落点。
-- ★ 若只返回 slot 而不更新 current_list，横向移动会算错边界。
    if slot and list then
        self.current_list = list
        return self:SelectSlot(slot)
    end
end

function Inv:CursorLeft()
	if self.pin_nav and not self.owner.HUD.controls.craftingmenu.is_left_aligned then
		local k, slot = next(self.current_list or {})
		if slot == nil or not slot.inst:IsValid() then
			self.current_list = self.equip
		end
	end

    if self:CursorNav(Vector3(-1,0,0), true) then
        TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
	elseif not self.open and not self.pin_nav and self.owner.HUD.controls.craftingmenu.is_left_aligned and self.owner.HUD.controls.craftingshown and self:PinBarNav(self.owner.HUD.controls.craftingmenu:InvNavToPin(self.active_slot, -1, 0)) then
        TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
	elseif self.reps == 1 and (self.current_list == self.inv or self.current_list == self.equip or self.pin_nav) then
		self.current_list = self.equip[self.equipslotinfo[#self.equipslotinfo].slot] and self.equip or self.inv
	    self:SelectSlot(self.equip[self.equipslotinfo[#self.equipslotinfo].slot] or self.inv[#self.inv])
		TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
    end
end

function Inv:CursorRight()
	if self.pin_nav and self.owner.HUD.controls.craftingmenu.is_left_aligned then
		local k, slot = next(self.current_list or {})
		if slot == nil or not slot.inst:IsValid() then
			self.current_list = self.inv
		end
	end

    if self:CursorNav(Vector3(1,0,0), true) then
        TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
	elseif not self.open and not self.pin_nav and not self.owner.HUD.controls.craftingmenu.is_left_aligned and self:PinBarNav(self.owner.HUD.controls.craftingmenu:InvNavToPin(self.active_slot, 1, 0)) then
        TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
	elseif self.reps == 1 and (self.current_list == self.inv or self.current_list == self.equip or self.pin_nav) then
		self:SelectDefaultSlot()
		TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
    end
end

function Inv:CursorUp()
	if self.pin_nav then
		self:PinBarNav(self.active_slot:FindPinUp())
    else
		if self:CursorNav(Vector3(0,1,0)) then
			TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
		elseif not self.open and (self.current_list == self.inv or self.current_list == self.equip) and self.owner.HUD.controls.craftingshown then
			-- go into the pin bar if there are no other open containers above the inventory bar
			self:PinBarNav(self.owner.HUD.controls.craftingmenu:InvNavToPin(self.active_slot, 0, 1))
		end
    end
end

function Inv:CursorDown()
	local pin_nav = self.pin_nav
	if pin_nav then
		local next_pin = self.active_slot:FindPinDown()
		if next_pin then
			self:PinBarNav(next_pin)
		else
			pin_nav = false
			local k, slot = next(self.current_list or {})
			if slot == nil or not slot.inst:IsValid() then
				self.current_list = self.owner.HUD.controls.craftingmenu.is_left_aligned and self.inv or self.equip
			end
		end
    end
	
	if not pin_nav and self:CursorNav(Vector3(0,-1,0)) then
        TheFrontEnd:GetSound():PlaySound("dontstarve/HUD/click_move")
    end
end

function Inv:GetClosestWidget(lists, pos, dir)
-- 【★★ GetClosestWidget：纯几何的焦点导航算法】
-- 遍历候选列表里所有槽，算出「相对当前槽的向量」，
--   ① 点积 > 0（第 775 行）：确认在**指定方向**上 ——
--      ★ 这一步过滤掉所有不在该方向上的槽，是方向约束的实现；
--   ② 距离平方（第 776 行）最小者胜 ——
--      ★ 用平方而非开方，省 sqrt 且排序结果不变。
--
-- ★ 两点设计取舍值得学：
--   · 用**世界坐标**（UITransform:GetWorldPosition）而非局部坐标：
--     因为各列表（主背包/装备/冰箱）挂在不同父节点下、缩放不同，
--     只有世界坐标能把它们放在同一空间比较。
--     ★ 容器整体缩放时导航依然正确，这是关键。
--   · 点积只判「方向」，不判角度锥：实现极简，
--     代价是斜向也匹配 —— 但网格 UI 里通常无妨。
--
-- ⚠️ 若要做严格的方向性导航（如只能上下左右），
--   需把点积改为角度区间判定，并按 4 个方向各跑一次。
    local closest = nil
    local closest_score = nil
    local closest_list = nil

	local x, y = pos.x, pos.y
	local dir_x, dir_y = dir.x, dir.y

    for kk, vv in pairs(lists) do
        for k,v in pairs(vv) do
            if v ~= self.active_slot then
				local vx, vy = v.inst.UITransform:GetWorldPosition()
				local local_dir_x, local_dir_y = vx-x, vy-y

				local dot = VecUtil_Dot(local_dir_x, local_dir_y, dir_x, dir_y)
                if dot > 0 then
					local score = local_dir_x * local_dir_x + local_dir_y * local_dir_y
	                if not closest or score < closest_score then
	                    closest = v
	                    closest_score = score
	                    closest_list = vv
	                end
				end
	        end
        end
    end

    return closest, closest_list
end

function Inv:GetCursorItem()
-- GetCursorItem：当前光标所指槽位里的物品。
-- ★ 三重 and 保护：active_slot 存在 → 有 tile → 有 item。
--   任一为空则返回 nil。
-- ★ 这个函数被第 669、817、996、1008… 等大量调用，
--   是全文件使用频率最高的取值入口。
    return self.active_slot ~= nil and self.active_slot.tile ~= nil and self.active_slot.tile.item or nil
end

function Inv:GetCursorSlot()
    if self.active_slot ~= nil then
        return self.active_slot.num, self.active_slot.container
    end
end

function Inv:OnControl(control, down)
-- 【★★ OnControl：输入分发的总入口 —— 「判定顺序」是本文件精华】
--
-- 顺序（★ 这个顺序本身就是设计，不可调换）：
--  ① 第 801-802 行：先给基类 Inv._base.OnControl 机会，
--     它若返回 true 表示「已处理」，立即返回 —— 基类优先。
--  ② 第 803-805 行：背包未展开则**直接返回**，
--     收起的背包不响应操作键（只有展开态才可操作）。
--  ③ 第 812-814 行：`if down then return end`
--     ★★ 只处理**抬起（up）事件**，按下事件一律忽略。
--     理由：避免一次按键触发两次（按下+抬起各一次）。
--     「按键判定放在 up 还是 down」是手柄 UI 的基础决策：
--     多数 UI 选 up（避免误触），而长按/滑动类选 down。
--  ④ 第 816-822 行：取当前手持物、光标处物品、只读容器标记，
--     作为后续各分支的判定依据。
--
-- ★ 第 818-820 行对 inv_item 的有效性复核：
--   `inv_item.replica.inventoryitem == nil` 说明该物品已被服务端移除
--   （replica 尚未同步销毁），当作 nil 处理。
--   避免对「已消失的物品」执行操作导致报错。
    if Inv._base.OnControl(self, control, down) then
        return true
    elseif not self.open then
        return
    end

    local was_force_single_drop = self.force_single_drop
-- 【★ force_single_drop：一次按键只丢 1 个的「弱化」模式】
-- 第 808-810 行：若上一帧设了这个标志、但本次没再按 PUTSTACK，就复位。
--
-- ★ 机制：按住 DROP 时，第一次是「丢弃全部/一个堆叠」，
--   后续要「只丢一个」得再点一下 —— 这就是 can_stack=false 的由来（第 881 行）。
--   通过 0.5 秒宽限 + 标志位实现，避开重复触发的竞态。
-- ★ 这是「按键语义随重复次数变化」的技巧，移植做长按/连发交互时常见。
    if was_force_single_drop and not TheInput:IsControlPressed(CONTROL_PUTSTACK) then
        self.force_single_drop = false
    end

    if down then
        return
    end

    local active_item = self.owner.replica.inventory:GetActiveItem()
    local inv_item = self:GetCursorItem()
    if inv_item ~= nil and inv_item.replica.inventoryitem == nil then
        inv_item = nil
    end

    local isreadonlycontainer = self.active_slot and self.active_slot.container and self.active_slot.container.IsReadOnlyContainer and self.active_slot.container:IsReadOnlyContainer()

    if control == CONTROL_ACCEPT then
-- 【★★ CONTROL_ACCEPT（主键/A键）的分支 —— 最复杂的判定链】
--
-- 优先级（★ 顺序即优先级）：
--  ① 只读容器 → 播否定音效、直接返回（第 825-827 行）。
--     ★ 「只读容器」在四个分支里都重复这个检查（825、851、862、885 行），
--       说明这是个横切关注点，本可提取成前置守卫。属轻微重复。
--  ② 背包里有物品、手上没东西 → 判是否允许丢下（第 828-845 行）：
--     · ShouldPreventUnequipping + 动作是 DROP → 特殊丢弃（玩家浮空物）；
--       ★ 注释标了 V2C，是专门为 playerfloaters 打的补丁。
--     · non_item_equips 或 不能进容器 → 也走丢弃。
--  ③ 都不是 → 正常点击当前槽（第 846-849 行 active_slot:Click()）。
--
-- ★ 注意第 846 行：有 active_slot 才点。
--   即「A 键 = 拿起/放下当前槽物品」，是最基础的操作。
        if isreadonlycontainer then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
            return true
		elseif inv_item and active_item == nil then
			local inv_equippable = inv_item.replica.equippable
			if inv_equippable and inv_equippable:ShouldPreventUnequipping() then
				local self_action = self.owner.components.playercontroller:GetItemSelfAction(inv_item)
				if self_action and self_action.action == ACTIONS.DROP then
					--V2C: special case handling for how to drop playerfloaters
					self.owner.replica.inventory:DropItemFromInvTile(inv_item)
					self:CloseControllerInventory()
					return true
				end
			elseif (inv_equippable and GetGameModeProperty("non_item_equips")) or
				not inv_item.replica.inventoryitem:CanGoInContainer()
			then
				self.owner.replica.inventory:DropItemFromInvTile(inv_item)
				self:CloseControllerInventory()
				return true
			end
		end
		if self.active_slot then
            self.active_slot:Click()
            return true
        end
    elseif control == CONTROL_PUTSTACK then
-- CONTROL_PUTSTACK：堆叠/半取。
-- ★ 第 856 行 `if not was_force_single_drop` —— 弱化模式生效时忽略本次，
--   避免「弱化」与「堆叠」两个机制打架。
-- ★ 三种堆叠操作（见第 1146/1150/1162 行提示文案）：
--   手上有一堆 + 槽里同类 → PUT（放入整组）；
--   槽里有一堆 + 手上没东西 → GETHALF（拿一半）；
--   槽里有单个 + 手上同类 → PUTONE（放一个）。
        if isreadonlycontainer then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
            return true
        end
        if self.active_slot ~= nil then
            if not was_force_single_drop then
                self.active_slot:Click(true)
            end
            return true
        end
	elseif control == TheInput:ResolveVirtualControls(VIRTUAL_CONTROL_INV_ACTION_DOWN) then
-- ★ VIRTUAL_CONTROL_INV_ACTION_DOWN：用虚拟键做「丢弃」。
-- 第 867 行的双重条件 `not was_force_single_drop and IsControlPressed(PUTSTACK)`：
--   同时按住修饰键表示「只要一个」。
-- 第 868-873 行额外拦「锁定在槽里的物品」：
--   ★ 锁定物不可丢，但**可以整组操作** —— 所以这里额外要求
--     `not (stackable and IsStack())`，即「不是整组」才拒绝。
--   这个双重否定读起来绕，但语义精确。
        if isreadonlycontainer then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
            return true
        end
        if inv_item ~= nil and active_item == nil then
            if not was_force_single_drop and TheInput:IsControlPressed(CONTROL_PUTSTACK) then
				if inv_item.replica.inventoryitem and inv_item.replica.inventoryitem:IsLockedInSlot() and
					not (inv_item.replica.stackable and inv_item.replica.stackable:IsStack())
				then
					TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
					return true
				end
                self.force_single_drop = true
			elseif inv_item.replica.inventoryitem and inv_item.replica.inventoryitem:IsLockedInSlot() then
				TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
				return true
            end
			self:SetAutopausedInternal(false)
-- ★★ 丢弃前先关自动暂停 + 设 0.5 秒宽限（第 880 行）。
--
-- 为什么？丢弃动作会让角色进入 busy 状态，
--   若此时已自动暂停，角色会被冻在丢弃动画中途。
-- 先解冻 + 给宽限期，等状态机确认动作开始了（第 475-503 行）
--   才重新暂停。
--
-- ★★ 这是「UI 操作与游戏状态机的时序协调」，
--   在 DST 这种「UI 逻辑与 gameplay 逻辑交织」的架构里非常典型。
--   自研游戏若有类似的「操作中」状态，同样需要这种宽限机制。
			self.autopause_delay = .5
            self.owner.replica.inventory:DropItemFromInvTile(inv_item, self.force_single_drop)
            return true
        end
    elseif control == CONTROL_USE_ITEM_ON_ITEM then
        if isreadonlycontainer then
            TheFocalPoint.SoundEmitter:PlaySound("dontstarve/HUD/click_negative")
            return true
        end
        if inv_item ~= nil and active_item ~= nil then
			self:SetAutopausedInternal(false)
-- CONTROL_USE_ITEM_ON_ITEM：两个物品互相使用（如把火把插进灯）。
-- 第 892 行 ControllerUseItemOnItemFromInvTile 交给 inventory 组件处理。
-- ★ 注意同样有第 890-891 行的解冻 + 宽限 ——
--   凡是会触发角色动作的操作都要走这套。
			self.autopause_delay = .5
            self.owner.replica.inventory:ControllerUseItemOnItemFromInvTile(inv_item, active_item)
            return true
        end
    end
end

function Inv:SetAutopausedInternal(pause)
-- SetAutopausedInternal：自动暂停的唯一入口。
-- ★ 第 899 行 `if not pause == self.autopaused then` 是防抖守卫：
--   只有「目标状态 ≠ 当前状态」才真正切换。
--   ⚠️ 逻辑等价于 `if pause ~= self.autopaused then`，
--     作者写成 `not pause == x` 略显晦涩，但语义相同。
--   作用：防止重复调用 SetAutopaused（该函数会改全局暂停状态，代价高）。
-- ★ 「用状态比较代替幂等标记」的常见写法。
	if not pause == self.autopaused then
		self.autopaused = not self.autopaused
		SetAutopaused(self.autopaused)
	end
end

function Inv:OpenControllerInventory()
-- 【★ OpenControllerInventory：展开手柄背包的全过程】
-- 顺序很有讲究（★ 打断动画前的准备）：
--  907 行 SetDark(true)          —— 先压暗背景（视觉反馈，即时）
--  912 行 SetAutopausedInternal  —— 再暂停游戏
--  914 行 self.open = true        —— 置状态
--  922-926 行 ScaleTo 放大背包与所有容器
--  928-929 行 LockFocus + SetFocus —— 最后抢焦点
--
-- ★ 第 928 行 LockFocus(true) 的作用见第 518 行的对应检查：
--   锁焦点后，光标操作不会被其他屏幕抢走。
-- ★ 第 906 行 `if not self.open` 保证幂等：重复调用不会叠加动画。
-- ★ 第 924-926 行：打开背包时**所有已打开的容器一起放大**，
--   否则背包大了而容器还是小号，视觉不协调。
    if not self.open then
        self.owner.HUD.controls:SetDark(true)
        --V2C: Don't set pause in multiplayer, all it does is change the
        --     audio settings, which we don't want to do now
        --SetPause(true, "inv")

		self:SetAutopausedInternal(true)

        self.open = true
        self.force_single_drop = false --reset the flag

		if self.pin_nav then
-- ★ 已在 pin bar（制作面板的置顶栏）导航状态时展开背包，
--   强制右移一格把手柄焦点拉回背包内。
-- 属于「状态切换时的焦点复位」，避免焦点遗留在已隐藏的 UI 上。
			self:CursorRight()
		end

        self:UpdateCursor()
        self:ScaleTo(self.base_scale,self.selected_scale,.2)

		for _, v in pairs(self.owner.HUD.controls.containers) do
            v:ScaleTo(self.base_scale,self.selected_scale,.2)
		end

        TheFrontEnd:LockFocus(true)
        self:SetFocus()
    end
end

function Inv:OnNewContainerWidget(containerwidg)
	if self.open then
		--V2C: need to spawn at the larger scale if controller inventory is already open
		--     (this can now happen with the slingshotmodkit for example)
		containerwidg:SetScale(self.selected_scale)
	end
end

function Inv:OnEnable()
    self:UpdateCursor()
end

function Inv:OnDisable()
    self.actionstring:Hide()
end

function Inv:CloseControllerInventory()
-- CloseControllerInventory：Open 的逆操作。
-- ★ 第 960 行 ReturnActiveItem()：关闭时强制归还手持物。
--   若不还，物品会「卡在光标上」丢失。
--   ★ 这是「关闭 UI 必须回收其持有的临时状态」的范例。
-- 第 964-966 行 DeHighlight：清掉选中高亮，避免下次展开时残留。
-- 第 974 行 LockFocus(false) 与第 928 行严格配对。
-- ★ 第 950 行的 `if self.open` 保证幂等。
    if self.open then
        self.open = false
        --V2C: Don't set pause in multiplayer, all it does is change the
        --     audio settings, which we don't want to do now
        --SetPause(false)

		self:SetAutopausedInternal(false)

        self.owner.HUD.controls:SetDark(false)

        self.owner.replica.inventory:ReturnActiveItem()

        self:UpdateCursor()

        if self.active_slot ~= nil then
            self.active_slot:DeHighlight()
        end

        self:ScaleTo(self.selected_scale, self.base_scale, .1)

		for _, w in pairs(self.owner.HUD.controls.containers) do
            w:ScaleTo(self.selected_scale,self.base_scale, .1)
		end

        TheFrontEnd:LockFocus(false)
    end
end

function Inv:GetDescriptionString(item)
-- GetDescriptionString：物品的完整描述名。
-- ★ 第 983 行「形容词 + 显示名」的拼接，
--   如「温热的 浆果酱」—— 形容词来自 GetAdjective（受火把/保温影响）。
-- ⚠️ 用 `adjective ~= nil and (...) or ...` —— 若形容词是 false 会被吞，
--   但 GetAdjective 返回 nil 或字符串，安全。
    if item == nil then
        return ""
    end
    local adjective = item:GetAdjective()
    return adjective ~= nil and (adjective.." "..item:GetDisplayName()) or item:GetDisplayName()
end

function Inv:SetTooltipColour(r, g, b, a)
   self.actionstringtitle:SetColour(r, g, b, a)
end

local function GetDropActionString(doer, item)
    return BufferedAction(doer, nil, ACTIONS.DROP, item, doer:GetPosition()):GetActionString()
end

function Inv:UpdateCursorText()
-- 【★★ UpdateCursorText：手柄提示条的全部生成逻辑（约 250 行）】
-- 这是本文件最长的函数，结构是「两层嵌套」：
--   外层（1004-1243）：决定标题颜色 + 生成操作列表 + 摆放位置；
--   内层（1029-1182）：按 open 状态、装备槽与否、两物品组合分支。
--
-- ★ 为什么这么长？因为它是「操作可用性矩阵」的**可视化**：
--   只在真正可执行的操作上显示按键提示，不可执行的绝不显示。
--   这意味着玩家看到的提示 = 当前状态的精确反映。
--
-- ★★ 这是一个关键 UI 原则：**提示要动态且诚实**。
--   很多游戏直接写死「按 X 使用」，结果一半时候按了没反应。
--   DST 靠这个函数保证不出现「提示了但做不到」。
--   移植自研项目时，这段是最值得完整参考的。
    if ThePlayer then ThePlayer.test = self.active_slot end
-- ⚠️ 【疑似调试残留】ThePlayer.test = self.active_slot
--
-- 我 grep 过全库 scripts/：ThePlayer.test 这个字段**没有任何读取方**
--（其它 .test 命中都是 cooking/spicedfoods/trader 的同名无关字段）。
-- 判定为调试遗留（可能是当年排查焦点问题加的）。
-- ★ 危害：给全局玩家对象挂了无用字段；
--   多人游戏中若所有客户端都执行，会各自污染自己的本地 ThePlayer。
--   不影响功能，但属于应当清理的调试代码。
-- ★ 顺带说明 UpdateCursorText 里可以访问 ThePlayer ——
--   因为它只在 ThePlayer 存在时（游戏内）被调用（第 518 行已守卫）。
    local inv_item = self:GetCursorItem()
    local active_item = self.cursortile ~= nil and self.cursortile.item or nil
    if inv_item ~= nil and inv_item.replica.inventoryitem == nil then
-- ★ 双端有效性校验：inv_item 与 active_item 都要查 replica.inventoryitem。
-- 原因：replica 数据由服务端异步下发，客户端可能持有「已删除但未同步」的引用。
-- ★ 这是分布式客户端 UI 的标准防御模式，全文件出现多次
--   （第 818、998、1001 行）。照抄这个检查即可避免大量 nil 崩溃。
        inv_item = nil
    end
    if active_item ~= nil and active_item.replica.inventoryitem == nil then
        active_item = nil
    end
    if active_item ~= nil or inv_item ~= nil then
        local controller_id = TheInput:GetControllerID()

        if inv_item ~= nil then
            local itemname = self:GetDescriptionString(inv_item)
            self.actionstringtitle:SetString(itemname)
            if inv_item:GetIsWet() then
-- ★ 标题染色反映物品状态：湿的物品用 WET_TEXT_COLOUR（蓝），否则普通色。
-- 第 1011/1013 行与 1019/1021 行逻辑完全相同（只是 inv/active 二选一）。
-- ★ 「颜色即状态」的视觉编码：玩家不看字也能知道物品湿没湿。
                self:SetTooltipColour(unpack(WET_TEXT_COLOUR))
            else
                self:SetTooltipColour(unpack(NORMAL_TEXT_COLOUR))
            end
        elseif active_item ~= nil then
            local itemname = self:GetDescriptionString(active_item)
            self.actionstringtitle:SetString(itemname)
            if active_item:GetIsWet() then
                self:SetTooltipColour(unpack(WET_TEXT_COLOUR))
            else
                self:SetTooltipColour(unpack(NORMAL_TEXT_COLOUR))
            end
        end

        local is_equip_slot = self.active_slot and self.active_slot.equipslot
        local str = {}

        local isreadonlycontainer = self.active_slot and self.active_slot.container and self.active_slot.container.IsReadOnlyContainer and self.active_slot.container:IsReadOnlyContainer()
-- 只读容器 → 不生成任何操作提示（第 1186 行 new_string = " "）。
-- ★ 与第 801 行的输入拦截配套：
--   输入层在第 825/851/862/885 行拦截只读容器的操作，
--   提示层在第 1029 行不显示 ——
--   ★ 输入与提示「两处都要改」，漏一处就会出现
--     「不能按但提示说能按」或「提示没有但其实能按」。
-- 这正是第 994 行开头说的「提示要诚实」的维护成本。
        if not isreadonlycontainer then
            if not self.open then
                if inv_item ~= nil then
					--local scheme = TheInput:GetActiveControlScheme(CONTROL_SCHEME_CAM_AND_INV)
-- 【★ 控制方案（scheme）适配 —— 手柄 UI 复杂度最高的根源】
-- 第 1034 行从 Profile 直读控制方案（注释第 1032-1033 行说明了原因：
--   原本用 GetActiveControlScheme，但这段代码专供手柄 UI，故直接查 Profile）。
--
-- ★ 关键概念：DPad（十字键）在不同方案下有两种用法 ——
--   use_preset_dpad（第 1037 行，scheme 在 4-7）：
--     DPad 被预设为固定功能（上=查看/下=丢弃/左=对场景/右=对自己）；
--   否则：Dpad 保留原义，上下左右直接做移动光标。
--
-- ★★ 移植要点：手柄 UI 必须区分「预设方向键」与「自由方向键」两种模式，
--   因为 Xbox/PS/Switch 的按键语义不同。
--   用 scheme 数值区间判断（>=4 and <=7）是 DST 的做法，
--   换成枚举会更清晰但需要引擎配合。
					--Check Profile directly since this code here is specifically for controller ui.
					local scheme = Profile:GetControlScheme(CONTROL_SCHEME_CAM_AND_INV) or 1
					local show_actions = true
					local show_mod_hint = false
					local use_preset_dpad = scheme >= 4 and scheme <= 7

					if use_preset_dpad then
-- 【★ DPad 模式下还要判断「是否按住修饰键」】
-- scheme>=6（第 1041 行）：DPad 独占给「物品动作」，
--   必须按住修饰键才能用 —— 否则 show_actions=false + show_mod_hint=true。
-- scheme 4-5：不需要修饰键，按住反而收起提示。
--
-- ★ 第 1044 行用 TheSim:GetDigitalControl 而非 TheInput:IsControlPressed，
--   注释第 1043 行说明是「跳过冗余检查」—— 少一层函数调用，
--   这段每帧可能跑多次，省下的开销可累积。
-- ★ 性能敏感位置的小优化，移植时可参考其取舍思路。
						--DPad is shared between inventory nav vs actions
						local actions_require_modifier = scheme >= 6
						--local ismodified = TheInput:IsControlPressed(CONTROL_CAM_AND_INV_MODIFIER)
						--Use TheSim:GetDigitalControl to skip some of the redundant checks.
						local ismodified = TheSim:GetDigitalControl(CONTROL_CAM_AND_INV_MODIFIER)
						if actions_require_modifier then
							if not ismodified then
								show_actions = false
								show_mod_hint = true
							end
						elseif ismodified then
							show_actions = false
						end
					end

					if show_actions then
-- 绑定「查看/丢弃/对场景/对自己」四个动作到具体按键常量。
-- ★ 第 1057-1067 行是纯查表：两套 DPad 方案各对应一组按键。
--   若再加一种 scheme，这里要加第三组。
-- ★ 第 1071 行 `if not is_equip_slot` —— 装备槽的可执行动作完全不同
--   （不能「拿起来」，只能「卸下」），故整个 1071-1105 与 1088-1105 分开写。
						local examine_ctrl, scene_act_ctrl, self_use_ctrl, drop_ctrl
						if use_preset_dpad then
							examine_ctrl = CONTROL_PRESET_DPAD_UP
							drop_ctrl = CONTROL_PRESET_DPAD_DOWN
							scene_act_ctrl = CONTROL_PRESET_DPAD_LEFT
							self_use_ctrl = CONTROL_PRESET_DPAD_RIGHT
						else
							examine_ctrl = CONTROL_INVENTORY_EXAMINE
							drop_ctrl = CONTROL_INVENTORY_DROP
							scene_act_ctrl = CONTROL_INVENTORY_USEONSCENE
							self_use_ctrl = CONTROL_INVENTORY_USEONSELF
						end

						table.insert(str, TheInput:GetLocalizedControl(controller_id, examine_ctrl).." "..STRINGS.UI.HUD.INSPECT)

						if not is_equip_slot then
							local inventoryitem = inv_item.replica.inventoryitem
							if not (inventoryitem:IsGrandOwner(self.owner) or inventoryitem:IsLockedInSlot()) then
								table.insert(str, TheInput:GetLocalizedControl(controller_id, scene_act_ctrl).." "..STRINGS.UI.HUD.TAKE)
							else
								local scene_action = self.owner.components.playercontroller:GetItemUseAction(inv_item)
								if scene_action then
									table.insert(str, TheInput:GetLocalizedControl(controller_id, scene_act_ctrl).." "..scene_action:GetActionString())
								end
							end
							local self_action = self.owner.components.playercontroller:GetItemSelfAction(inv_item)
							if self_action then
								table.insert(str, TheInput:GetLocalizedControl(controller_id, self_use_ctrl).." "..self_action:GetActionString())
							end
							if not inventoryitem:IsLockedInSlot() then
								table.insert(str, TheInput:GetLocalizedControl(controller_id, drop_ctrl).." "..GetDropActionString(self.owner, inv_item))
							end
						else
							local self_action = self.owner.components.playercontroller:GetItemSelfAction(inv_item)
							if self_action and self_action.action ~= ACTIONS.UNEQUIP and self_action.action ~= ACTIONS.DROP then
								table.insert(str, TheInput:GetLocalizedControl(controller_id, scene_act_ctrl).." "..self_action:GetActionString())
							end
							local equippable = inv_item.replica.equippable
							if not (equippable and equippable:ShouldPreventUnequipping()) then
								if #self.inv > 0 and not (inv_item:HasTag("heavy") or GetGameModeProperty("non_item_equips")) then
-- ★ 卸下装备的条件：背包非空、物品非 heavy、模式允许物品式装备。
-- 第 1096 行提示 UNEQUIP。
-- ⚠️ `#self.inv > 0` 说明「手上没有可放的东西时不给卸下选项」——
--   但实际卸下并不需要背包有空间，卸下后物品进 active_item。
--   判定：这是刻意的 UX 约束（避免手上已满时困惑），非缺陷。
									table.insert(str, TheInput:GetLocalizedControl(controller_id, self_use_ctrl).." "..STRINGS.UI.HUD.UNEQUIP)
								end
								if not inv_item.replica.inventoryitem:IsLockedInSlot() then
									table.insert(str, TheInput:GetLocalizedControl(controller_id, drop_ctrl).." "..GetDropActionString(self.owner, inv_item))
								end
							elseif self_action and self_action.action == ACTIONS.DROP then
								--V2C: special case handling for how to drop playerfloaters
								table.insert(str, TheInput:GetLocalizedControl(controller_id, drop_ctrl).." "..self_action:GetActionString())
							end
						end
					elseif show_mod_hint then
						table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_CAM_AND_INV_MODIFIER))--.." "..STRINGS.UI.HUD.ITEM_ACTIONS)
					end
                end
            else
                if is_equip_slot then
                    --handle the quip slot stuff as a special case because not every item can go there
					if active_item then
						local active_equippable = active_item.replica.equippable
						if active_equippable and active_equippable:EquipSlot() == self.active_slot.equipslot and not active_equippable:IsRestricted(self.owner) then
							if inv_item then
								local inv_equippable = inv_item.replica.equippable
								if not (inv_equippable and inv_equippable:ShouldPreventUnequipping()) then
									table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT).." "..STRINGS.UI.HUD.SWAP)
								end
							else
								table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT).." "..STRINGS.UI.HUD.EQUIP)
							end
						end
					elseif inv_item then
						local inv_equippable = inv_item.replica.equippable
						if inv_equippable and inv_equippable:ShouldPreventUnequipping() then
							local self_action = self.owner.components.playercontroller:GetItemSelfAction(inv_item)
							if self_action and self_action.action == ACTIONS.DROP then
								--V2C: special case handling for how to drop playerfloaters
								table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT).." "..self_action:GetActionString())
							end
						elseif not (inv_equippable and GetGameModeProperty("non_item_equips")) and
							inv_item.replica.inventoryitem:CanGoInContainer()
						then
                            table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT) .. " " .. STRINGS.UI.HUD.UNEQUIP)
						else--if not inv_item.replica.inventoryitem:IsLockedInSlot() then
                            table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT) .. " " .. GetDropActionString(self.owner, inv_item))
                        end
                    end
                else
                    local can_take_active_item = active_item ~= nil and (self.active_slot.container.CanTakeItemInSlot == nil or self.active_slot.container:CanTakeItemInSlot(active_item, self.active_slot.num))
-- ★★ can_take_active_item：目标槽能否接收手上的物品。
-- `container.CanTakeItemInSlot == nil` 时视为可以（兼容无此方法的容器）。
--
-- ★ 「方法存在性检查」而非 try/catch：
--   Lua 里用「字段为 nil 则走默认分支」实现鸭子类型。
-- 第 1145 行还额外要求 stackable 能与槽内物品堆叠。
-- ★ 这个判断同时决定提示文案（第 1164 行 SWAP）与实际点击行为，
--   保证提示与结果一致。

                    if active_item ~= nil and active_item.replica.stackable ~= nil and
                        ((inv_item ~= nil and active_item.replica.stackable:CanStackWith(inv_item)) or (inv_item == nil and can_take_active_item)) then
                        table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_PUTSTACK) .. " " .. STRINGS.UI.HUD.PUTONE)
                    end

                    if active_item == nil and inv_item ~= nil and inv_item.replica.stackable ~= nil and inv_item.replica.stackable:IsStack() then
                        table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_PUTSTACK) .. " " .. STRINGS.UI.HUD.GETHALF)
                    end

                    if inv_item ~= nil and active_item == nil then
						if not inv_item.replica.inventoryitem:IsLockedInSlot() then
							table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT).." "..STRINGS.UI.HUD.SELECT)
							table.insert(str, TheInput:GetLocalizedControl(controller_id, VIRTUAL_CONTROL_INV_ACTION_DOWN).." "..GetDropActionString(self.owner, inv_item))
						else
							table.insert(str, " ")
						end
                    elseif inv_item ~= nil and active_item ~= nil then
                        if active_item.replica.stackable ~= nil and active_item.replica.stackable:CanStackWith(inv_item) then
                            table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT) .. " " .. STRINGS.UI.HUD.PUT)
                        elseif can_take_active_item then
                            table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT) .. " " .. STRINGS.UI.HUD.SWAP)
                        else
                            table.insert(str, " ")
                        end
                    elseif inv_item == nil and active_item ~= nil and can_take_active_item then
                        table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT) .. " " .. STRINGS.UI.HUD.PUT)
                    else
                        table.insert(str, " ")
                    end
                end

                if active_item ~= nil and inv_item ~= nil then
                    local use_action = self.owner.components.playercontroller:GetItemUseAction(active_item, inv_item)
                    if use_action ~= nil then
                        table.insert(str, TheInput:GetLocalizedControl(controller_id, CONTROL_USE_ITEM_ON_ITEM) .. " " .. use_action:GetActionString())
                    end
                end
            end
        end

        local was_shown = self.actionstring.shown
-- 【★ 提示条更新的两重节流】
-- 第 1187 行：字符串**没变**就不更新、不重置计时、不 Show。
--   → 避免每帧 SetString 造成文字重排与闪烁。
-- 第 1235 行：位置没动（距离平方 <= 1）就不 MoveTo。
--   → 避免每帧重启动画。
--
-- ★★ 这是 UI 性能的两条通用原则：
--   ① 内容不变不重绘；② 位置不变不动画。
--   缺任何一个都会让 UI 每帧做无用功。
-- ★ 第 1235 行用 DistSq > 1 而非距离 > 1：省开方，阈值更精确。
        local old_string = self.actionstringbody:GetString()
        local new_string = isreadonlycontainer and " " or table.concat(str, '\n')
        if old_string ~= new_string then
            self.actionstringbody:SetString(new_string)
            self.actionstringtime = CURSOR_STRING_DELAY
            self.actionstring:Show()
        end

        local w0, h0 = self.actionstringtitle:GetRegionSize()
-- ★ 先量出标题与正文各自的尺寸，取较大值 wmax 作为整体宽度。
-- 因为 title 在上、body 在下（纵向堆叠），宽度取 max 而非相加。
-- ★ 「先测量再定位」—— 无布局引擎下必须手工完成这个步骤，
--   否则提示条会在文字长短不一时左右跳动。
        local w1, h1 = self.actionstringbody:GetRegionSize()

        local wmax = math.max(w0, w1)

        local dest_pos = self.active_slot:GetWorldPosition()

        local xscale, yscale, zscale = self.root:GetScale():Get()
-- ★★ dest_pos 换算：槽位给的是**世界坐标**，
--   但 actionstring 挂在 self.root 下，需要**局部坐标**。
--   第 1207/1213/1219/1225 行统一乘 xscale/yscale 换算。
--
-- ★ 这个坑来自第 51 行的「单一 root」设计：
--   好处是整体动画方便，代价是跨 root 定位要手动换算。
-- ★★ 移植要点：嵌套坐标系里取「另一个子树的局部位置」，
--   正确做法是 GetWorldPosition 后减去父节点偏移并除以父缩放。
--   DST 这里直接乘 root 的缩放，等价于假设 root 原点为基准。

        if self.active_slot.side_align_tip then
-- 【★ 提示条四向对齐：三种标记 + 一个兜底】
-- side_align_tip   —— 容器类（冰箱/箱子），提示在右侧（第 1203 行注释）；
-- top_align_tip    —— 主背包，提示在上方；
-- bottom_align_tip —— 溢出背包（第二行），提示在下方（第 334 行设置）；
-- else             —— 兜底，按主背包的方式（第 1221 行注释「老默认行为」）。
--
-- ★★ 关键设计：**对齐方式由槽位自己声明**（第 276、334 行设置标记），
--   消费方（第 1202 行）只负责读取。
--   → 新增一种容器布局，只需在 containers.lua 的 widget 定义里
--     加一个 *_align_tip 字段，提示条自动适配，无需改本文件。
-- ★ 这是「配置驱动 UI」的完整闭环，值得作为自研项目架构参考。
-- ⚠️ 注意顺序：必须先判 side（第 1202 行），
--   因为 top/bottom 用 elseif 串联。三个标记互斥由调用方保证。
            -- in-game containers, chests, fridge
            self.actionstringtitle:SetPosition(wmax/2, h0/2)
            self.actionstringbody:SetPosition(wmax/2, -h1/2)

            dest_pos.x = dest_pos.x + self.active_slot.side_align_tip * xscale
        elseif self.active_slot.top_align_tip then
            -- main inventory
            self.actionstringtitle:SetPosition(0, h0/2 + h1)
-- title 在 body 上方：标题贴 h0/2+h1（自身底边紧贴正文顶边），
-- body 贴 h1/2。两者之间零间隙，紧凑排列。
-- ★ 与第 1216-1217 行（下方排列，body 在 title 之下）对照：
--   两处的符号完全不同，说明定位全靠手算。
            self.actionstringbody:SetPosition(0, h1/2)

            dest_pos.y = dest_pos.y + (self.active_slot.top_align_tip + TIP_YFUDGE) * yscale
        elseif self.active_slot.bottom_align_tip then
            
            self.actionstringtitle:SetPosition(0, -h0/2)
            self.actionstringbody:SetPosition(0, -(h1/2 + h0))

            dest_pos.y = dest_pos.y + (self.active_slot.bottom_align_tip + TIP_YFUDGE) * yscale
        else
            -- old default as fallback ?
            self.actionstringtitle:SetPosition(0, h0/2 + h1)
            self.actionstringbody:SetPosition(0, h1/2)

            dest_pos.y = dest_pos.y + (W/2 + TIP_YFUDGE) * yscale
        end

        -- print("self.active_slot:GetWorldPosition()", self.active_slot:GetWorldPosition())
        -- print("h0", h0)
        -- print("w0", w0)
        -- print("h1", h1)
        -- print("w1", h1)
        -- print("dest_pos", dest_pos)

        if dest_pos:DistSq(self.actionstring:GetPosition()) > 1 then
            self.actionstringtime = CURSOR_STRING_DELAY
            if was_shown then
                self.actionstring:MoveTo(self.actionstring:GetPosition(), dest_pos, .1)
            else
                self.actionstring:SetPosition(dest_pos)
                self.actionstring:Show()
            end
        end
    else
        self.actionstringbody:SetString("")
        self.actionstring:Hide()
    end
end

function Inv:SelectSlot(slot)
-- 【★ SelectSlot：光标切换的守卫与副作用】
-- 第 1251 行 `slot ~= self.active_slot` 保证「选中同一格不算切换」，
--   → 避免重复触发 DeHighlight/Highlight 与提示条闪烁。
-- 第 1252-1254 行：旧槽取消高亮。
-- 第 1256-1261 行：★ 维护 pin_nav 状态 ——
--   选中的槽带 in_pinbar 标记 → 进入 pin 导航模式；
--   离开 pin bar → 退出并 ClearFocus。
--   这是「选中行为隐式驱动模式切换」的耦合，移植时需注意。
-- 第 1264 行 return true —— 调用方（OnControl）靠它知道是否真的切换了。
    if slot and slot ~= self.active_slot then
        if self.active_slot and self.active_slot ~= slot then
            self.active_slot:DeHighlight()
        end

		if self.pin_nav and not slot.in_pinbar then
			self.pin_nav = false
			self.owner.HUD.controls.craftingmenu:ClearFocus()
		elseif slot.in_pinbar then
			self.pin_nav = true
		end

        self.active_slot = slot
        return true
    end
end

function Inv:SelectDefaultSlot()
-- SelectDefaultSlot：选第一个可用槽。
-- ★ 第 1269 行 `self.inv[1] and self.inv or self.equip`：
--   有物品槽就用物品槽，没有才退到装备槽（纯手柄模式可能无物品栏）。
--   ★ 注意这里是 `and/or` 三元而非 if，依赖 self.inv[1] 非 nil。
--     若 self.inv 为空表，self.inv[1] 为 nil → 回退 equip，正确。
-- 第 1270 行同理。
-- ★ 这两行组合保证了「任何状态下都有一个合法选中项」，
--   是第 552、676、1292 行三处兜底调用的实现。
    self.current_list = self.inv[1] and self.inv or self.equip
	self:SelectSlot(self.inv[1] or self.equip[self.equipslotinfo[1].slot])
end

function Inv:UpdateCursor()
-- 【★★ UpdateCursor：光标图标的绘制与跟随】
-- ★ 开头第 1274-1285 行先判「没接手柄」就整体隐藏并 return：
--   鼠标模式下整个手柄光标 UI 不存在。
--   → 这是「同一控件支持两种输入模式」的成本：函数内部到处要判模式。
--
-- 光标本身（第 1304 行）是独立 Image（slot_select.tex），
--   ★ 但它的**父节点是变化的** —— 见下。
--
-- cursortile（第 1342 行）是「手上物品」的图，跟随光标。
--   第 1346 行 StartDrag() —— ★ 它处于「拖拽中」状态，
--   这样鼠标模式下不会重复触发拾取。
    if not TheInput:ControllerAttached() then
        self.actionstring:Hide()
        if self.cursor ~= nil then
            self.cursor:Hide()
        end

        if self.cursortile ~= nil then
            self.cursortile:Kill()
            self.cursortile = nil
        end
        return
    end

    if self.hovertile ~= nil then
        self.hovertile:Kill()
        self.hovertile = nil
    end

    if self.active_slot == nil then
        self:SelectDefaultSlot()
    end

    if self.active_slot ~= nil and self.cursortile ~= nil then
        self.cursortile:SetPosition(self.active_slot:GetWorldPosition())
    end

    if self.active_slot ~= nil then
        if self.cursor ~= nil then
            self.cursor:Kill()
        end
        self.cursor = self.root:AddChild(Image(HUD_ATLAS, "slot_select.tex"))

        if self.active_slot.tile ~= nil and self.active_slot.tile:HasSpoilage() then
-- 【★★ 三分支决定光标框的挂载位置 —— 看似重复，实则必要】
-- 分支1（第 1306-1317 行）：物品会腐坏（HasSpoilage）
--   → 光标挂到 **tile 里面**，随物品一起缩放/销毁；
--   → 并且要把腐败计时条和背景一起 MoveToBack（第 1312-1317 行）。
--     ★ 否则光标框会盖住「这个食物还剩多久变质」的提示 ——
--       而那恰恰是玩家此时最需要看的信息。
-- 分支2（第 1318-1320 行）：hide_cursor（如某些隐藏槽）
--   → 光标存在但 Hide，仅保留高亮。
-- 分支3（第 1321-1330 行）：常规
--   → 光标挂到 **slot 上**，并把槽背景 MoveToBack。
--
-- ★★ 这三段的共同结构是「Kill 旧光标 → AddChild 新光标 → MoveToBack 背景」
--   （第 1301-1304 行每帧都重建光标）。
--   每帧重建听着浪费，但 DST 用对象池化 + 贴图缓存使代价可接受，
--   换来的是「光标永远在最上层且不残留旧位置」的简洁。
-- ⚠️ 注意第 1332 行的 else 分支：active_slot 为 nil 时 self.cursor 可能也是 nil
--   （第 1292 行已 SelectDefaultSlot 兜底），实际不会到此。
            self.cursor:Show()
            self.active_slot.tile:AddChild(self.cursor)
            self.active_slot:Highlight()

            self.cursor:MoveToBack()
			if self.active_slot.tile.spoilage then
				self.active_slot.tile.spoilage:MoveToBack()
			end
			if self.active_slot.tile.bg then
				self.active_slot.tile.bg:MoveToBack()
			end
        elseif self.active_slot.hide_cursor then
			self.cursor:Hide()
            self.active_slot:Highlight()
		else
            self.cursor:Show()
            self.active_slot:AddChild(self.cursor)
            self.active_slot:Highlight()

            self.cursor:MoveToBack()
			if self.active_slot.bgimage then
	            self.active_slot.bgimage:MoveToBack()
			end
        end
    else
        self.cursor:Hide()
    end

    --if self.open then
    local active_item = self.owner.replica.inventory:GetActiveItem()
-- 【★ cursortile 的「差分更新」】
-- 第 1338 行条件：cursortile 为空 **或** 物品已变 → 才重建。
--   否则什么都不做，保留现有 tile。
-- ★ 与第 1347 行：新建后立刻对齐到光标位置，
--   已存在时靠第 1296-1298 行每帧 SetPosition 跟随。
-- ★ 「差分更新」避免每帧重建 ItemTile ——
--   而 ItemTile 是重控件（含堆叠数、耐久条、腐败条）。
-- ★ 移植要点：跟随类 UI 要区分「重建对象」与「只改位置」，
--   两者开销差一个数量级。
    if active_item ~= nil then
        if self.cursortile == nil or active_item ~= self.cursortile.item then
            if self.cursortile ~= nil then
                self.cursortile:Kill()
            end
            self.cursortile = self.root:AddChild(ItemTile(active_item))
            self.cursortile.isactivetile = true
            self.cursortile.image:SetScale(1.3)
            self.cursortile:SetScaleMode(SCALEMODE_PROPORTIONAL)
            self.cursortile:StartDrag()
            self.cursortile:SetPosition(self.active_slot:GetWorldPosition())
        end
    elseif self.cursortile ~= nil then
        self.cursortile:Kill()
        self.cursortile = nil
    end

    self:UpdateCursorText()
end

function Inv:Refresh(skipbackpack)
-- 【★ Refresh：内容刷新（与 Rebuild 的结构刷新相对）】
-- 遍历三组槽位（背包 1363、装备 1376、溢出 1389），每组三个分支：
--   该槽无物品 → SetTile(nil) 清理；
--   物品变了 → SetTile(ItemTile(item)) **重建**；
--   物品没变 → v.tile:Refresh() **只更新内容**（耐久/堆叠数）。
--
-- ★★★ 第 1369 行的判定 `v.tile.item ~= item`（对象身份比较）是本函数的关键：
--   它用「Lua 对象引用相等」判断物品是否真的换了，
--   从而区分「需要重建」与「只需刷新」。
-- ⚠️ 前提：服务端下发的 item 必须是**稳定的对象引用**，
--   同一物品重复下发若产生新 Lua 对象，会导致每次 Refresh 都重建全部 tile。
-- ★ 移植时若用纯数据描述物品（无对象身份），
--   应改用 inventoryitem 的唯一 id 比较。
-- ★ skipbackpack 参数（第 1357、1389 行）：refreshinventory 事件传 true，
--   跳过溢出背包刷新 —— 因为该事件不代表溢出容器变化。
    local inventory = self.owner.replica.inventory
    local items = inventory:GetItems()
    local equips = inventory:GetEquips()
    local activeitem = inventory:GetActiveItem()

    for i, v in ipairs(self.inv) do
        local item = items[i]
        if item == nil then
            if v.tile ~= nil then
                v:SetTile(nil)
            end
        elseif v.tile == nil or v.tile.item ~= item then
            v:SetTile(ItemTile(item))
        else
            v.tile:Refresh()
        end
    end

    for k, v in pairs(self.equip) do
        local item = equips[k]
        if item == nil then
            if v.tile ~= nil then
                v:SetTile(nil)
            end
        elseif v.tile == nil or v.tile.item ~= item then
            v:SetTile(ItemTile(item))
        else
            v.tile:Refresh()
        end
    end

	if not skipbackpack then
		self:RefreshIntegratedContainer()
	end

    self:OnNewActiveItem(activeitem)
end

function Inv:RefreshIntegratedContainer()
    if #self.backpackinv > 0 then
		local inventory = self.owner.replica.inventory
        local overflow = inventory:GetOverflowContainer()
        if overflow ~= nil then
            for i, v in ipairs(self.backpackinv) do
                local item = overflow:GetItemInSlot(i)
                if item == nil then
                    if v.tile ~= nil then
                        v:SetTile(nil)
                    end
                elseif v.tile == nil or v.tile.item ~= item then
                    v:SetTile(ItemTile(item))
                else
                    v.tile:Refresh()
                end
            end
        end
    end
end

function Inv:SetHoverTileHideModifier(source, hidden, key)
-- 【★ SetHoverTileHideModifier：多来源遮罩的统一入口】
-- 第 1418 行把「来源 + 隐藏位 + 键」交给 SourceModifierList 聚合，
-- 第 1419 行再根据聚合结果（Get 返回任一为真）切换可见性。
-- ★ 这就是第 97 行那个容器的用法闭环。
-- ★ 设计价值：**多个互不相关的系统都能要求隐藏**，
--   （放蓝图时、砍树时、别的 mod …）而不必互相知道。
--   「加法而非覆盖」的语义 —— 只需一个来源撤销即可恢复。
-- key 或 source（第 1418 行）：同一来源可按不同键分别控制。
    self.hovertile_hide_sources:SetModifier(source, hidden or false, key or source)
    self:EnableHoverTileVisibility(not self.hovertile_hide_sources:Get())
end

local PLACER_SOURCE = "deployplacer_hide"
function Inv:OnPlacerChanged(placer_shown)
-- OnPlacerChanged：建造蓝图放置态变化时的回调。
-- ★ 用固定字符串 PLACER_SOURCE（第 1422 行）作为来源标识，
--   与第 118 行的通用事件入口共用同一个聚合器。
-- ★ 这样「放蓝图时隐藏手持物」就自动实现了，无需特殊逻辑。
    self:SetHoverTileHideModifier(PLACER_SOURCE, placer_shown)
end

function Inv:EnableHoverTileVisibility(enable)
-- EnableHoverTileVisibility：切隐藏时**只动 image 和 imagebg 两个子件**，
-- 而不 Kill 整个 hovertile。
-- ★ 意义：悬停位置、物品、数量等状态全部保留，
--   恢复显示时不会「跳回原点」或丢失状态。
-- ⚠️ 若改成 Hide()/Show() 整个 tile，被它挡住的鼠标事件也会变化，
--   交互会不稳定。这是「局部隐藏优于整体隐藏」的实例。
    self.hover_tile_visibility = enable
    if self.hovertile ~= nil then
		if enable then
			if self.hovertile.image ~= nil then
				self.hovertile.image:Show()
			end
			if self.hovertile.imagebg ~= nil then
				self.hovertile.imagebg:Show()
			end
		else
            if self.hovertile.image ~= nil then
				self.hovertile.image:Hide()
			end
			if self.hovertile.imagebg ~= nil then
				self.hovertile.imagebg:Hide()
			end
		end
	end
end

function Inv:Cancel()
-- Cancel：手柄模式下取消操作。
-- ★ 第 1450-1453 行：若手持着东西，先 ReturnActiveItem 归还。
--   否则「按取消键」只会清光标，手上的物品却还跟着，
--   玩家会觉得「东西卡住了」。
-- ★ 与第 960 行（Close 时归还）同构：任何中止路径都要回收临时状态。
    local inventory = self.owner.replica.inventory
    local active_item = inventory:GetActiveItem()
    if active_item ~= nil then
        inventory:ReturnActiveItem()
    end
end

function Inv:OnItemLose(slot)
    if slot then
        slot:SetTile(nil)
    end

    --self:UpdateCursor()
end

function Inv:OnBuild()
-- OnBuild：放置建造物时的反馈动画。
-- ★ 第 1466 行 ScaleTo(3,1,.5)：从 3 倍缩回 1 倍（放大后收缩），
--   配合第 1515-1532 行「物品飞入」的 0.3 秒动画，
--   形成「东西砸进背包」的反馈。
-- ⚠️ 这里未判 hovertile 是否有 image，直接调 ScaleTo。
--   若 hovertile 存在但被 Kill（竞态），会报错。
--   判定为**疑似健壮性缺口**：实际触发路径（第 108 行 builditem 事件）
--   与 hovertile 的生命周期关系不保证。不易复现，故标疑似。
    if self.hovertile then
        self.hovertile:ScaleTo(3, 1, .5)
    end
end

function Inv:OnNewActiveItem(item)
-- 【★★ OnNewActiveItem：手持物变化 —— 双模式分流的第二处】
-- 第 1471 行按 ControllerAttached 分成两大分支：
--   手柄（1472-1492）：维护 cursortile；
--   鼠标（1493-1508）：维护 hovertile（第 1504 行挂在 mousefollow 下）。
--
-- ★★ 鼠标分支的第 1507 行值得注意：
--   新建 hovertile 后立刻调 EnableHoverTileVisibility(self.hover_tile_visibility)
--   —— 把当前遮罩状态应用到新对象上。
--   ⚠️ 不调的话，放蓝图时（遮罩为隐藏）新拾起的物品会**错误地显示**。
--   ★「全局状态变化后新建的子对象必须继承该状态」——
--     这是状态型 UI 极易遗漏的一环。
--
-- 第 1493 行 `item == nil or controls == nil`：
--   第二个条件是防御 —— HUD 拆除过程中 controls 可能已为 nil。
    if TheInput:ControllerAttached() then
        if item == nil or self.owner.HUD.controls == nil then
            if self.cursortile ~= nil then
                self.cursortile:Kill()
                self.cursortile = nil
                self:UpdateCursorText()
            end
        elseif self.cursortile ~= nil and self.cursortile.item == item then
            self.cursortile:Refresh()
            self:UpdateCursorText()
        elseif self.active_slot ~= nil then
            if self.cursortile ~= nil then
                self.cursortile:Kill()
            end
            self.cursortile = self.root:AddChild(ItemTile(item))
            self.cursortile.isactivetile = true
            self.cursortile.image:SetScale(1.3)
            self.cursortile:SetScaleMode(SCALEMODE_PROPORTIONAL)
            self.cursortile:StartDrag()
            self.cursortile:SetPosition(self.active_slot:GetWorldPosition())
            self:UpdateCursorText()
        end
    elseif item == nil or self.owner.HUD.controls == nil then
        if self.hovertile ~= nil then
            self.hovertile:Kill()
            self.hovertile = nil
        end
    elseif self.hovertile ~= nil and self.hovertile.item == item then
        self.hovertile:Refresh()
    else
        if self.hovertile ~= nil then
            self.hovertile:Kill()
        end
        self.hovertile = self.owner.HUD.controls.mousefollow:AddChild(ItemTile(item))
        self.hovertile.isactivetile = true
        self.hovertile:StartDrag()
        self:EnableHoverTileVisibility(self.hover_tile_visibility)
    end
end

function Inv:OnItemGet(item, slot, source_pos, ignore_stacksize_anim)
-- 【★★ OnItemGet：物品飞入动画 —— 「假物品图 + 真 tile」技巧】
-- 第 1513-1515 行：真正的 tile 已建好，但**先 Hide()**。
--
-- 然后（第 1518-1532 行，若给了 source_pos）：
--   ① 第 1520 行另造一个**临时的纯图片** im（不含堆叠数/耐久条）；
--   ② 第 1532 行让 im 从世界坐标飞向槽位（0.3 秒）；
--   ③ 动画结束后 im:Kill()，同时 tile:Show() + ScaleTo(2,1,.25) 弹一下。
--
-- ★★ 为什么不用真 tile 飞？
--   真 ItemTile 上挂着堆叠数、耐久条、腐败条等子件，
--   它们带各自的缩放/对齐逻辑，飞行途中会错位；
--   且飞行期间会响应悬停/拖拽事件，引发误操作。
--   → 用「简化替身飞行 + 真件到位后弹入」，是动画与逻辑解耦的经典手法。
-- ★ 第 1526 行 bg:AddChild(im) 支持物品自带底图（inv_image_bg）。
-- ★ 第 1521/1528 行按游戏模式加色彩校正 shader（icons_use_cc）。
-- 第 1533-1535 行：没有 source_pos（如服务端直接下发）就直接显示，不做动画。
--   ★ 优雅降级：动画是加分项，缺了也不影响正确性。
    if slot ~= nil then
        local tile = ItemTile(item)
        slot:SetTile(tile)
        tile:Hide()
        tile.ignore_stacksize_anim = ignore_stacksize_anim

        if source_pos ~= nil then
            local dest_pos = slot:GetWorldPosition()
			local im = ItemTile.sSetImageFromItem(Image(), item)
            if GetGameModeProperty("icons_use_cc") then
                im:SetEffect("shaders/ui_cc.ksh")
            end
            if item.inv_image_bg ~= nil then
                local bg = Image(item.inv_image_bg.atlas, item.inv_image_bg.image)
                bg:AddChild(im)
                im = bg
                if GetGameModeProperty("icons_use_cc") then
                    im:SetEffect("shaders/ui_cc.ksh")
                end
            end
            im:MoveTo(Vector3(TheSim:GetScreenPos(source_pos:Get())), dest_pos, .3, function() tile:Show() tile:ScaleTo(2, 1, .25) im:Kill() end)
        else
            tile:Show()
            --tile:ScaleTo(2, 1, .25)
        end
    end
end

function Inv:OnItemEquip(item, slot)
    if slot ~= nil and self.equip[slot] ~= nil then
        self.equip[slot]:SetTile(ItemTile(item))
    end
end

function Inv:OnItemUnequip(item, slot)
    if slot ~= nil and self.equip[slot] ~= nil then
        self.equip[slot]:SetTile(nil)
    end
end

--Extended to autoposition world reset timer

function Inv:UpdatePosition()
-- UpdatePosition：把背包条锚到 autoanchor（屏幕安全区）。
-- 第 1555 行 `self:IsVisible() and (...) or 0`：
--   可见时贴到 root 下方 10 像素；不可见时归零（滑出视野）。
-- ★ 注意 autoanchor 与 root 是两套坐标体系：
--   autoanchor 由引擎管理（适配刘海屏/电视安全区），root 是我们的布局。
-- ★ 移植要点：UI 需要区分「引擎给的固定锚点」与「自己算的布局坐标」。
-- ★ 第 1552 行注释说明这是为世界重置计时器扩展的接口。
    self.autoanchor:SetPosition(0, self:IsVisible() and (self.root:GetPosition().y - 10) or 0)
end

function Inv:OnShow()
-- OnShow/OnHide（第 1558-1570 行）：显隐时同步刷新锚点与悬停物。
-- ★ 第 1560-1562 行：显示时把 hovertile 一并 Show ——
--   因为 EnableHoverTileVisibility 可能在隐藏期间把它 Hide 掉了。
--   显隐钩子里同步子对象状态，是「状态型 UI」的必要收尾。
    self:UpdatePosition()
    if self.hovertile ~= nil then
        self.hovertile:Show()
    end
end

function Inv:OnHide()
    self:UpdatePosition()
    if self.hovertile ~= nil then
        self.hovertile:Hide()
    end
end

function Inv:OnCraftingHidden()
-- OnCraftingHidden：制作面板关闭后的收尾。
-- ★ 条件 `pin_nav and not self.open`：
--   若焦点还在已关闭的 pin bar 里，则重置到默认槽。
-- ★ 这就是第 1256-1261 行 pin_nav 状态的**清理责任方**。
-- ⚠️ 若 pin_nav 为真但制作面板是被别的方式关闭的，
--   这里可能不触发 → pin_nav 残留。属疑似状态残留风险。
	if self.pin_nav and not self.open then
		self:SelectDefaultSlot()
	end
end

return Inv
-- 返回 Inv 类本身（不是实例）。
-- ★ 消费方写法：`local Inv = require "widgets/inventorybar"` 然后 `Inv(owner)`。
--   对比 templates.lua 的 `return TEMPLATES`（返回工厂表，调用时带括号）。
--   两者都是「require 拿到构造入口」，只是形态不同。