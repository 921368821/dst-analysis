--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：widgets/templates.lua
-- 模块：UI 系统 / 前端零件工厂（TEMPLATES）
-- 职责：一张扁平的工厂函数表，每个 entry 是 `function(...) -> 新控件实例`。
--       提供背景/前景场景、九宫格面板、导航栏与各类按钮、标签+输入控件、
--       物品飞入动画、雪花粒子等前端零件，供 screens/ 与 frontend.lua 消费。
--       ★ 不是「UI 模板基类」：全库无 Widget:Template() 机制；
--         真正的继承体系在 class.lua:83 的 Class() 与 widget.lua:1。
-- 关键符号：TEMPLATES, NoPortalBackground, AnimatedPortalBackground,
--           AnimatedPortalForeground, ForegroundLetterbox, CenterPanel,
--           CurlyWindow, NavBarButton, BackButton, IconButton, InvisibleButton,
--           TextMenuItem, ModListItem, LabelTextbox, LabelSpinner, LabelButton,
--           MovingItem, ItemImageText, Snowfall
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：class.lua（Class 继承体系）, widgets/widget.lua（Widget 基类与焦点链）,
--           widgets/button.lua（Button:OnGainFocus 读 ongainfocus 字段，113 行）,
--           widgets/imagebutton.lua（ImageButton 继承 Button，focus_scale 默认 1.2）,
--           widgets/textedit.lua, widgets/spinner.lua, widgets/nineslice.lua,
--           widgets/uianim.lua（AnimState build/bank/animation 三件套）,
--           frontend.lua 与 screens/*.lua（消费方）
--============================================================
local Widget = require "widgets/widget"
--[[
-- templates.lua —— 前端 UI 的「零件工厂」：一整张工厂函数表
--
-- 【⚠️ 先纠正一个常见误解】
-- 本文件不是「UI 模板基类」，也不存在 Widget:Template() 这个机制。
-- 我用 grep -rn ":Template(" 扫过全库 scripts/，零命中。
-- 真正的模板机制在 class.lua:83 的 Class(base, _ctor, props)，
-- widget.lua:1 用 `local Widget = Class(function(self, name) ... end)` 建立基类，
-- ImageButton 再用 Class(Button, function...) 做浅拷贝继承。
-- 本文件走的是**完全另一条路**：纯函数工厂 + 闭包状态，不参与继承体系。
--
-- 【机制 A：工厂函数表（本文档主体）】
-- TEMPLATES 是一个纯 table，每个 value 是 `function(...) -> 新实例`。
-- 调用方写法：  local w = TEMPLATES.CenterPanel(1, 1, false)
-- 为什么这样设计：UI 零件需要「每次调用拿到全新实例」，
-- 而 Class 体系给的是「同一份原型 + 实例化」。工厂函数省掉了
-- 元表查找与 _ctor 派发，且允许在返回前自由闭包捕获局部状态
-- （见 ForegroundLetterbox / Snowfall —— 它们把 per-instance 状态
--  藏在闭包里，而不是写进 self 字段）。
--
-- 【机制 B：惰性自引用】
-- 第 16-17 行先 `local TEMPLATES = nil` 再赋值，是**必需**的技巧：
-- 表构造器内部的函数体（第 28-30 行）要回头调用 TEMPLATES.BackgroundPlate()，
-- 但此刻构造器还没跑完，TEMPLATES 还是 nil。
-- 提前 local 声明只是给闭包留一个 upvalue 槽位；
-- 若删掉第 16 行直接 TEMPLATES = {...}，Lua 会把 TEMPLATES
-- 解析成**全局变量**，闭包捕获的仍是 nil，运行时才炸。
-- 这是本文件唯一一处「顺序敏感」的地方。
--
-- 【为什么对自研游戏有价值】
-- 零件复用有两条路：继承（Class）与组合（工厂 + AddChild）。
-- DST 的 UI 几乎全走组合——一个复杂界面 = 一串 AddChild 叠出锚点树，
-- 没有布局引擎、没有容器自动排版，全部手算坐标。
--]]
local Text = require "widgets/text"
local TextEdit = require "widgets/textedit"
local Button = require "widgets/button"
local Image = require "widgets/image"
local ImageButton = require "widgets/imagebutton"
local NineSlice = require "widgets/nineslice"
local UIAnim = require "widgets/uianim"
local Spinner = require "widgets/spinner"
local AnimButton = require "widgets/animbutton"
local ItemImage = require "widgets/itemimage"


local smoke_offset = -20
-- 前端烟雾层统一的 Y 偏移（-20）。抽成常量是因为 West/East/South
-- 三片雾都用同一偏移，抽出来改一处即可；若各写各的 -20，
-- 改视觉就会漏掉其中一片。

local TEMPLATES = nil
TEMPLATES = {

    ----------------
    ----------------
    -- Static background comp --
    ----------------
    ----------------

    NoPortalBackground = function()
-- 【★ 典型「组合式装配」范式】
-- 注意这里没有任何 Class / 继承，全是 26-32 行的手工搭树：
--   bg 本身是个空壳 Widget，用来当**容器**；
--   三个零件（背景板/前景板/树）由三个独立工厂各造一个，
--   再 AddChild 挂上去，并存进具名字段。
-- 具名字段（bgplate/fgplate/trees）不是装饰：调用方要能事后单独
-- 拿到某个子件改属性或 Kill 它，散落的匿名子节点做不到这点。
--
-- ⚠️ 常见错误写法：把 TEMPLATES.Xxx() 的返回值直接当成最终控件用。
-- 工厂返回的往往只是「根」，真正的可视件在它的子节点上。
        local bg = Widget("background")

        bg.bgplate = bg:AddChild(TEMPLATES.BackgroundPlate())
        bg.fgplate = bg:AddChild(TEMPLATES.ForegroundPlate())
        bg.trees = bg:AddChild(TEMPLATES.ForegroundTrees())

        bg:SetCanFadeAlpha(false)

        return bg
    end,

    ----------------
    ----------------
    -- BACKGROUND --
    ----------------
    ----------------

    -- A static, full screen background image
    -- To be added as a child of the screen itself.
    --[[Background = function()
-- 【⚠️ 整段被注释掉的模板 —— 这是「注释掉的代码 ≠ 不存在」的代表】
-- 第 45-57 行是一个完整的 Background 工厂，但被 Lua 长注释（双中括号）封死。
-- 它没被删除，说明历史上曾启用过（静态背景图方案），
-- 后来改成了 AnimatedPortalBackground（第 61 行）才弃用。
-- 搜 TEMPLATES.Background 不会有结果——它是死的。
-- 保留这段的价值：能看到方案演进（静态图 → 动态传送门场景）。
        local bg = Image("images/bg_color.xml", "bg.tex")
        TintBackground(bg)
        bg:SetVRegPoint(ANCHOR_MIDDLE)
        bg:SetHRegPoint(ANCHOR_MIDDLE)
        bg:SetVAnchor(ANCHOR_MIDDLE)
        bg:SetHAnchor(ANCHOR_MIDDLE)
        bg:SetScaleMode(SCALEMODE_FILLSCREEN)

        bg:SetCanFadeAlpha(false)

        return bg
    end,]]

    -- A dynamic background scene with an animated portal and smoke/mist
    -- To be added as a child of the screen itself.
    AnimatedPortalBackground = function()
-- 【★ 动态背景的组装顺序 = 绘制层级】
-- DST 没有 zIndex，全靠 children 列表顺序决定谁盖住谁。
-- 本函数内 AddChild 的先后即：底板(64) → 烟雾(75) → 传送门(91)。
-- 调换顺序会让烟雾盖住传送门，且没有任何报错。
--
-- ★ 条件化的两个维度（第 71-89 行）：
--   1) InGamePlay() —— 只在主菜单存在，进游戏内就不建这些节点；
--      ★ 这是性能开关：一进游戏就省掉整套菜单背景的开销。
--   2) 特殊活动 / 画质档（见第 72、85 行）。
        local bg = Widget("background")

        bg.plate = bg:AddChild(TEMPLATES.BackgroundPlate())

        bg.anim_root = bg:AddChild(Widget("anim_root"))
        bg.anim_root:SetVAnchor(ANCHOR_MIDDLE)
        bg.anim_root:SetHAnchor(ANCHOR_MIDDLE)
        bg.anim_root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        if not InGamePlay() then
            if IsSpecialEventActive(SPECIAL_EVENTS.WINTERS_FEAST) then
                bg.EnableSmoke = function() end
-- ★ 空函数覆盖 = 「禁用该能力」的惯用法。
-- 冬季盛宴活动下不生成烟雾，于是把 EnableSmoke 换成一个**什么都不做**的替身。
-- 为什么要这么绕？为了调用方不必写 `if bg.smoke then ... end`——
-- 接口形状保持一致，调用方无脑调 bg:EnableSmoke(false) 即可。
-- 这就是「空对象模式（Null Object）」，移植自研 UI 时非常值得抄。
            else
                bg.anim_root.smoke = bg.anim_root:AddChild(TEMPLATES.BackgroundSmoke())

                bg.EnableSmoke = function(bg, enable)
                    if enable then
                        bg.anim_root.smoke:Show()
                    else
                        bg.anim_root.smoke:Hide()
                    end
                end

                if TheSim:IsNetbookMode() or TheFrontEnd:GetGraphicsOptions():IsSmallTexturesMode() then
-- ★ 降级路径：网电一体机 / 低画质档下主动关烟雾。
-- 与第 73 行对比：那是在**构造期**就不生成节点（省内存与创建开销），
-- 这是在**构造完成后**立刻隐藏（节点已建，只是停掉更新与绘制）。
-- 前者更彻底，但无法在运行期切回；后者可逆。
-- netbook 是低配上网本，DST 对它单独降级，代码里这种判断有几十处。
                    bg:EnableSmoke(false)
                end
            end
        end

        bg.anim_root.portal = bg.anim_root:AddChild(TEMPLATES.BackgroundPortal())

        bg:SetCanFadeAlpha(false)

        return bg
    end,

    -- A component of the AnimatedPortalBackground
    BackgroundPlate = function()
-- 【★ 「按设计分辨率缩放」的标准三步式】
-- 这是本文件出现次数最多的模式（第 105-110、292-298、366-374 行同构）：
--   ① 造图；② 取图元自然宽度 w = plate:GetSize()；
--   ③ SetScale(RESOLUTION_X / w)。
-- 原理：美术资源按固定像素画，DST 的虚拟坐标恒为 RESOLUTION_X × RESOLUTION_Y
--（游戏内 1280×720，前端通常 1920×1080 常量），
-- 把像素图缩放到「正好铺满虚拟宽度」，就实现了**分辨率无关**。
-- ★ 换个写法会怎样错：直接 SetScale(1) → 高分辨率下背景露边；
-- 写死 SetScale(1.5) → 只有单一分辨率正确，换 16:10 就错位。
        local root = Widget("bg_plate_root")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local plate = root:AddChild(Image("images/bg_animated_portal.xml", "bg_plate.tex"))
        plate:SetVRegPoint(ANCHOR_MIDDLE)
        plate:SetHRegPoint(ANCHOR_MIDDLE)

        local w = plate:GetSize()
        plate:SetScale(RESOLUTION_X / w)

        return root
    end,

    -- A component of the AnimatedPortalBackground
    BackgroundSmoke = function()
-- 【★ AnimState 三件套：SetBuild / SetBank / PlayAnimation】
--  Klei 的美术管线是「build（整张精灵图集）+ bank（子目录）+ animation（帧序列）」。
-- 第 118-120 行的三次调用缺一不可，且顺序固定：
--   先指 build，再指 bank，最后播帧。
-- ⚠️ 换个写法会怎样错：只调 SetBank 不调 SetBuild → 引擎找不到图集，
-- 静默不渲染（UI 上表现为「元素凭空消失」，不报 Lua 错，极难查）。
-- 第 120 行末的 true = loop（循环播放），false = 播完停住。
        local smoke = UIAnim()
        smoke:GetAnimState():SetBuild("portal_scene_steamfxbg")
        smoke:GetAnimState():SetBank("cloudsfx_BG")
        smoke:GetAnimState():PlayAnimation("idle_bg", true)
        smoke:SetScale(.7)
-- 第 121-123 行：先缩放到 .7，再把 Y 挪到 -500（远在屏幕下方之外）。
-- 烟雾本体是循环动画，靠位移进入视野制造「飘上来」的错觉。
-- SetMultColour 是乘算着色：整体套一层半透明烟灰，
-- 不必为每种烟雾单独出一套美术资源。
        smoke:SetPosition(0,-500)
        smoke:GetAnimState():SetMultColour(FRONTEND_SMOKE_COLOUR[1], FRONTEND_SMOKE_COLOUR[2], FRONTEND_SMOKE_COLOUR[3], 1)

        return smoke
    end,

    -- A component of the AnimatedPortalBackground
    BackgroundPortal = function()
-- ★ 对比第 116 行：这里 PlayAnimation("portal_idle", **false**)。
-- false = 不循环。传送门动画「播一次停在最后一帧」，
-- 而烟雾必须循环。循环与否直接决定 CPU 是否持续重绘——
-- 把本该静止的传送门误设成循环，等于让整屏背景永不停歇地重绘。
        local portal = UIAnim()
        portal:GetAnimState():SetBuild("portal_scene2")
        portal:GetAnimState():SetBank("portal_scene")
        portal:GetAnimState():PlayAnimation("portal_idle", false)
        portal:GetAnimState():SetMultColour(unpack(FRONTEND_PORTAL_COLOUR))
        portal:SetScale(.4)

        return portal
    end,

    BackgroundSpiral = function()
        local bg = Image("images/bg_spiral.xml", "bg_spiral.tex")
        bg:SetVRegPoint(ANCHOR_MIDDLE)
        bg:SetHRegPoint(ANCHOR_MIDDLE)
        bg:SetVAnchor(ANCHOR_MIDDLE)
        bg:SetHAnchor(ANCHOR_MIDDLE)
        bg:SetScaleMode(SCALEMODE_FILLSCREEN)
        bg:SetTint(unpack(FRONTEND_PORTAL_COLOUR))
-- SetTint 与第 123 行的 SetMultColour 语义不同，别混用：
--   SetTint(r,g,b,a)      —— 设为指定颜色（含 alpha）；
--   SetMultColour(r,g,b,a)—— 与原色**相乘**（保留贴图本身的明暗层次）。
-- 背景叠加层用 SetTint 即可，但想保留纹理渐变就得用乘法。

        return bg
    end,

    BackgroundVignette = function()
        local vig = Image("images/bg_vignette.xml", "vignette.tex")
        vig:SetVRegPoint(ANCHOR_MIDDLE)
        vig:SetHRegPoint(ANCHOR_MIDDLE)
        vig:SetVAnchor(ANCHOR_MIDDLE)
        vig:SetHAnchor(ANCHOR_MIDDLE)
        vig:SetScaleMode(SCALEMODE_FILLSCREEN)

        return vig
    end,

    BackgroundTint = function(a, rgb)
-- 【★ 全屏纯色遮罩 —— 压暗背景的通用手段】
-- 用 images/global.xml 里的 square.tex（一块纯白方块）铺满全屏，
-- 再用 SetTint 染成半透明黑。压暗背景不需要美术资源，
-- 一个 1×1 白块 + tint 就够了 —— 前端里到处是这个套路。
        local bg = Image("images/global.xml", "square.tex")
        bg:SetVRegPoint(ANCHOR_MIDDLE)
        bg:SetHRegPoint(ANCHOR_MIDDLE)
        bg:SetVAnchor(ANCHOR_MIDDLE)
        bg:SetHAnchor(ANCHOR_MIDDLE)
        bg:SetScaleMode(SCALEMODE_FILLSCREEN)

		a = a ~= nil and a or 0.75
-- ⚠️ 【Lua 真值陷阱 · 经典写法但有雷】
-- 第 171-172 行用的是 `a ~= nil and a or 默认值` 这种「三元表达式」。
-- 在 Lua 里它依赖 `and` 的短路返回**原值**：若 a 恰为 false，
-- `false or 0.75` 会得到 0.75，a 的 false 被吃掉。
-- 这里 a 是 alpha 数值（0.75/1.0），不会是 false，所以安全。
-- ⚠️ 换成颜色分量、布尔开关就必错。安全写法是 if a == nil then a = 0.75 end。
-- 第 172 行 rgb 默认 `{0, 0, 0 }` 同理。
		rgb = rgb ~= nil and rgb or {0, 0, 0 }

		bg:SetTint(rgb[1], rgb[2], rgb[3], a)

        return bg
    end,

    -------------------------------
    -------------------------------
    -- LEFT/RIGHT SIDE GRADIENTS --
    -------------------------------
    -------------------------------

    -- To be added as a child of the root
    LeftGradient = function()
-- 【★ 侧边渐变：镜像复用同一张贴图，省一半美术资源】
-- LeftGradient 与 RightGradient（第 201 行）用的是**同一张** sidemenu_bg.tex，
-- 只是锚点与位移不同。右侧靠第 211 行 grad:SetScale(-1) 做水平镜像。
--
-- ★ SetScale 的负值 = 翻转，这是游戏 UI 的常用技巧：
-- 左右对称装饰只需一张图。移植时要注意负缩放会让法线/文字一并镜像，
-- 所以只能用于纯装饰图，不能放带文字的控件。
        local root = Widget("left_gradient_root")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local grad = root:AddChild(Image("images/frontend.xml", "sidemenu_bg.tex"))
        grad:SetVRegPoint(ANCHOR_MIDDLE)
        grad:SetHRegPoint(ANCHOR_LEFT)
        grad:SetPosition(-.5 * RESOLUTION_X, 0)
-- 渐变图贴左边：HRegPoint=ANCHOR_LEFT 让「图片左缘」作为定位基准，
-- 再 SetPosition(-.5*RESOLUTION_X, 0) 把左缘推到虚拟屏幕正中，
-- 于是半张图自然铺满屏幕左半。
-- ★ 这就是「RegPoint（注册点/图内基准）+ Anchor（相对父级的锚）」的配合：
-- RegPoint 选图内的哪个点，Anchor 选这个点贴到父级的哪个位置。
-- DST 没有布局引擎，全靠这两个属性手算 —— 理解它就理解了 DST 的全部布局。

        return root
    end,

    -- To be added as a child of the root
    RightGradient = function()
        local root = Widget("left_gradient_root")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local grad = root:AddChild(Image("images/frontend.xml", "sidemenu_bg.tex"))
        grad:SetVRegPoint(ANCHOR_MIDDLE)
        grad:SetHRegPoint(ANCHOR_LEFT)
        grad:SetPosition(.5 * RESOLUTION_X, 0)
		grad:SetScale(-1)
-- ★ 负缩放 = 水平镜像，让同一张图铺满右半屏。
-- ⚠️ 但第 209 行仍是 SetHRegPoint(ANCHOR_LEFT)：
-- 镜像后图内左右对调，所以定位基准要取图**左**缘，
-- 再位移到 +.5*RESOLUTION_X（屏幕正中偏右）。
-- 「翻转 + 基准点」必须成对修改，只改其一就会左右错位。

        return root
    end,

    ----------------
    ----------------
    -- FOREGROUND --
    ----------------
    ----------------

    -- A dynamic background scene with an animated portal and smoke/mist (and a hook for character placement)
    -- To be added as a child of the screen itself AFTER adding AnimatedPortalBackground.
    AnimatedPortalForeground = function()
-- 【★ 前景层：与背景层（61 行）成对出现的另一半】
-- 命名约定：Background* = 角色之后，Foreground* = 角色之前。
-- 角色（perd）被夹在中间，才有「站在场景里」的纵深感。
--
-- ★ AddChild 顺序即层级，本函数 12 次 AddChild 的次序不能乱：
--   228 背后的 perd → 232 前景板 → 235-237 内部/西/东雾 →
--   241 角色根节点 → 248 南雾 → 272 前排 perd → 277 树 → 278 遮幅。
        local fg = Widget("foreground")

        if IsSpecialEventActive(SPECIAL_EVENTS.YOTG) and not InGamePlay() then
-- 第 227 行：`IsSpecialEventActive(YOTG)` 且**不在**游戏内才加角色。
-- 双重条件：既要在活动期，又要处于菜单态。
-- ★ 注意这个 `not InGamePlay()` 与第 234、247 行重复出现三次，
-- 每次都重新判断 —— 因为它们守卫的是**不同**的子节点组。
-- 合并成一个 if 虽然更简洁，但会让三个子节点组的结构耦合在一起，
-- 后续单独调整某一组时更易出错。作者选了「重复判断」。
            fg.perds_back = fg:AddChild(TEMPLATES.ForegroundPerdBack())
            fg.perds_back:SetCanFadeAlpha(false)
        end

        fg.plate = fg:AddChild(TEMPLATES.ForegroundPlate())

        if not InGamePlay() then
            fg.smoke_inside = fg:AddChild(TEMPLATES.ForegroundSmokeInside())
            fg.smoke_west = fg:AddChild(TEMPLATES.ForegroundSmokeWest())
            fg.smoke_east = fg:AddChild(TEMPLATES.ForegroundSmokeEast())
        end

        -- A root widget for placing characters (or anything else you want to place "in" the scene) at the appropriate depth if desired
        fg.character_root = fg:AddChild(Widget("character_root"))
-- ★ character_root = 预留的「角色插槽」。
-- 模板只给出一个锚定到屏幕中央、按比例缩放的空根节点（并默认隐藏），
-- 由调用方自行 AddChild 角色动画并控制深度。
-- 这是本文件「数据驱动 UI」思路的雏形：
-- **模板负责骨架与坐标，调用方负责内容**。
-- 角色位置因此能自动匹配任意分辨率，无需各屏幕重复算坐标。
        fg.character_root:SetVAnchor(ANCHOR_MIDDLE)
        fg.character_root:SetHAnchor(ANCHOR_MIDDLE)
        fg.character_root:SetScaleMode(SCALEMODE_PROPORTIONAL)
        fg.character_root:Hide()
-- 默认隐藏。角色由调用方在合适时机 Show()，
-- 避免模板一造出来就渲染一个空节点。

        if not InGamePlay() then
            fg.smoke_south = fg:AddChild(TEMPLATES.ForegroundSmokeSouth())

            fg.EnableSmoke = function(fg, enable)
                if enable then
                    fg.smoke_inside:Show()
                    fg.smoke_west:Show()
                    fg.smoke_east:Show()
                    fg.smoke_south:Show()
                else
                    fg.smoke_inside:Hide()
                    fg.smoke_west:Hide()
                    fg.smoke_east:Hide()
                    fg.smoke_south:Hide()
                end
                if fg.snowfall ~= nil then
                    fg.snowfall:EnableSnowfall(enable)
                end
            end

            if TheSim:IsNetbookMode() or TheFrontEnd:GetGraphicsOptions():IsSmallTexturesMode() then
                fg:EnableSmoke(false)
            end

            if IsSpecialEventActive(SPECIAL_EVENTS.YOTG) then
                fg.perds = fg:AddChild(TEMPLATES.ForegroundPerdFront(fg.perds_back))
                fg.perds:SetCanFadeAlpha(false)
            end
        end

        fg.trees = fg:AddChild(TEMPLATES.ForegroundTrees())
        fg.letterbox = fg:AddChild(TEMPLATES.ForegroundLetterbox())

        fg:SetCanFadeAlpha(false)

        return fg
    end,

    -- A component of the AnimatedPortalForeground
    ForegroundPlate = function()
        local root = Widget("fg_plate_root")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local plate = root:AddChild(Image("images/fg_animated_portal.xml", "fg_plate.tex"))
        plate:SetVRegPoint(ANCHOR_BOTTOM)
-- 与第 106 行的背景板对照，注意 RegPoint 不同：
--   背景板 VRegPoint=ANCHOR_MIDDLE（垂直居中）；
--   前景板 VRegPoint=ANCHOR_BOTTOM（底部）。
-- 前景板是「站在地上」的地面，必须以底边为基准（295 行再下移半屏高），
-- 否则地面会浮在半空。
-- ★ RegPoint 选错 → 整块图绕错误的点缩放，视觉上「整体偏移且变形」。
        plate:SetHRegPoint(ANCHOR_MIDDLE)
        plate:SetPosition(0, -.5 * RESOLUTION_Y)

        local w = plate:GetSize()
        plate:SetScale(RESOLUTION_X / w)

        return root
    end,

    -- A component of the AnimatedPortalForeground
    ForegroundSmokeWest = function()
        local smoke = UIAnim()
        smoke:GetAnimState():SetBuild("cloud_build")
        smoke:GetAnimState():SetBank("cloudsfx_OL_west")
        smoke:GetAnimState():PlayAnimation("steamfxwest_loop", true)
        smoke:SetScale(.7)
        smoke:SetVAnchor(ANCHOR_MIDDLE)
        smoke:SetHAnchor(ANCHOR_MIDDLE)
        smoke:SetPosition(0,smoke_offset)
        smoke:GetAnimState():SetMultColour(unpack(FRONTEND_SMOKE_COLOUR))

        return smoke
    end,

    -- A component of the AnimatedPortalForeground
    ForegroundSmokeEast = function()
        local smoke = UIAnim()
        smoke:GetAnimState():SetBuild("cloud_build")
        smoke:GetAnimState():SetBank("cloudsfx_OL_east")
        smoke:GetAnimState():PlayAnimation("steamfxeast_loop", true)
        smoke:SetScale(.7)
        smoke:SetVAnchor(ANCHOR_MIDDLE)
        smoke:SetHAnchor(ANCHOR_MIDDLE)
        smoke:SetPosition(0,smoke_offset)
        smoke:GetAnimState():SetMultColour(unpack(FRONTEND_SMOKE_COLOUR))

        return smoke
    end,

    -- A component of the AnimatedPortalForeground
    ForegroundSmokeSouth = function()
        local smoke = UIAnim()
        smoke:GetAnimState():SetBuild("cloud_build")
        smoke:GetAnimState():SetBank("cloudsfx_OL_south")
        smoke:GetAnimState():PlayAnimation("steamfxsouth_loop", true)
        smoke:SetScale(.7)
        smoke:SetVAnchor(ANCHOR_MIDDLE)
        smoke:SetHAnchor(ANCHOR_MIDDLE)
        smoke:SetPosition(0,smoke_offset)
        smoke:GetAnimState():SetMultColour(unpack(FRONTEND_SMOKE_COLOUR))

        return smoke
    end,

    -- A component of the AnimatedPortalForeground
    ForegroundSmokeInside = function()
        local smoke = UIAnim()
        smoke:GetAnimState():SetBuild("portal_scene2_inside")
        smoke:GetAnimState():SetBank("cloudsfx_insideportal")
        smoke:GetAnimState():PlayAnimation("insideportal_idle", true)
        smoke:SetScale(.7)

        return smoke
    end,

    -- A component of the AnimatedPortalForeground
    ForegroundTrees = function()
        local root = Widget("fg_trees_root")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local trees = root:AddChild(Image("images/fg_trees.xml", "trees.tex"))
        trees:SetVRegPoint(ANCHOR_MIDDLE)
        trees:SetHRegPoint(ANCHOR_MIDDLE)
        --V2C: Tint and dirt baked into trees layer now
-- 第 369-370 行：V2C（Verify To Confirm，开发期校验备注）说明
-- 染色和泥土效果已烘焙进贴图，于是删掉了运行时 SetTint。
-- ★ 烘焙 vs 运行时染色 的取舍：烘焙省一次绘制/换贴图，
-- 但再想动态变色就得重出美术资源。这类取舍在源码里以注释形式留痕。
        --trees:SetTint(unpack(FRONTEND_TREE_COLOUR))
        trees:SetClickable(false)
-- ★ SetClickable(false) —— DST UI 的头号性能与正确性开关。
-- 装饰性图片若保持可点击，会**挡住**它下面所有控件的鼠标事件。
-- 树是纯装饰，必须关掉。
-- 本文件第 717、724、883、887、1054、1063 行等处都是同一处理。
-- ⚠️ 换句话说：装饰层忘了这行，按钮就「点不动」，且无任何报错。

        local w = trees:GetSize()
        trees:SetScale(RESOLUTION_X / w)

        return root
    end,

    ForegroundLetterbox = function()
-- 【★ 超宽屏「遮幅（letterbox）」自适配 —— 全文件最硬的数学段】
-- 背景图按 16:9 等比放大铺满。当屏幕更宽或更高时，
-- 多出来的区域不能拉伸变形，于是用四条黑边盖住（电影黑边）。
-- 386-388 行是三组常量：
--   aspect = 1920/1080 = 16:9，maxw/maxh = 设计分辨率 × MAX_FE_SCALE
--（允许的最大放大倍数，决定「黑边从超过多少倍开始出现」）。
        local root = Widget("fg_letterbox_root")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local _scrnw, _scrnh
        local aspect = RESOLUTION_X / RESOLUTION_Y
        local maxw = RESOLUTION_X * MAX_FE_SCALE
        local maxh = RESOLUTION_Y * MAX_FE_SCALE

        root.OnUpdate = function()
-- ★ OnUpdate 每帧被调用，但第 392-394 行做了**脏检查**：
-- 屏幕尺寸没变就直接 return，什么都不做。
-- 这是 UI 性能的常规套路 —— 窗口缩放是低频事件，
-- 若不缓存，每帧都重算遮幅 + 重建子节点，纯浪费。
-- ★ 对比：数据驱动的 UI（如下面的 health 数值）必须每帧更新，
-- 就不做这种缓存；判断标准是「值是否可能每帧都变」。
            local scrnw, scrnh = TheSim:GetScreenSize()
            if _scrnw == scrnw and _scrnh == scrnh then
                return
            end

            _scrnw = scrnw
            _scrnh = scrnh

            local scrnaspect = scrnw / scrnh
            local hbars = scrnw > maxw or scrnaspect > aspect
-- 【★ 判定「要不要黑边」的两个条件，用 or / and 组合成四象限】
--   hbars（左右黑边）：屏幕比最大宽度更宽，**或**比 16:9 更宽；
--   vbars（上下黑边）：屏幕比最大高度更高，**或**比 16:9 更窄。
-- 两个 or 各自兜住「超出 MAX_FE_SCALE」与「宽高比偏离 16:9」两种情形。
-- 后面第 454 行的 `hbars and vbars` 分支正是这四种组合的穷举。
-- ★ 换个写法会怎样错：只判 `scrnw > maxw` → 16:10 屏幕上背景被拉伸，不出黑边。
            local vbars = scrnh > maxh or scrnaspect < aspect

            if hbars then
-- 【★ 惰性创建 + 主动销毁（Kill）】
-- 黑边 Image 只在需要时 AddChild（第 405、412 行），
-- 不需要时 Kill 并置 nil（第 419-426、444-451 行）。
-- 必须置 nil，否则下次进来 `root.left ~= nil` 为真，
-- 会以为已存在而跳过创建 → 黑边永远出不来。
-- ⚠️ 这是「懒创建 + 显式清空」配对的经典坑，移植时务必照做。
-- SetHRegPoint 用 RIGHT(408) + 负位移：黑边贴着虚拟屏左边缘向**左**延伸。
                if root.left == nil then
                    root.left = root:AddChild(Image("images/global.xml", "square.tex"))
                    root.left:SetTint(0, 0, 0, 1)
                    root.left:SetVRegPoint(ANCHOR_MIDDLE)
                    root.left:SetHRegPoint(ANCHOR_RIGHT)
                    root.left:SetPosition(-.5 * RESOLUTION_X, 0)
                end
                if root.right == nil then
                    root.right = root:AddChild(Image("images/global.xml", "square.tex"))
                    root.right:SetTint(0, 0, 0, 1)
                    root.right:SetVRegPoint(ANCHOR_MIDDLE)
                    root.right:SetHRegPoint(ANCHOR_LEFT)
                    root.right:SetPosition(.5 * RESOLUTION_X, 0)
                end
            else
                if root.left ~= nil then
                    root.left:Kill()
                    root.left = nil
                end
                if root.right ~= nil then
                    root.right:Kill()
                    root.right = nil
                end
            end
            if vbars then
                if root.top == nil then
                    root.top = root:AddChild(Image("images/global.xml", "square.tex"))
                    root.top:SetTint(0, 0, 0, 1)
                    root.top:SetVRegPoint(ANCHOR_BOTTOM)
                    root.top:SetHRegPoint(ANCHOR_MIDDLE)
                    root.top:SetPosition(0, .5 * RESOLUTION_Y)
                end
                if root.bottom == nil then
                    root.bottom = root:AddChild(Image("images/global.xml", "square.tex"))
                    root.bottom:SetTint(0, 0, 0, 1)
                    root.bottom:SetVRegPoint(ANCHOR_TOP)
                    root.bottom:SetHRegPoint(ANCHOR_MIDDLE)
                    root.bottom:SetPosition(0, -.5 * RESOLUTION_Y)
                end
            else
                if root.top ~= nil then
                    root.top:Kill()
                    root.top = nil
                end
                if root.bottom ~= nil then
                    root.bottom:Kill()
                    root.bottom = nil
                end
            end

            if hbars and vbars then
-- 【★ 三个分支的差别只在「宽高哪个溢出更多」】
--   454 hbars and vbars —— 四条边都要：按各自方向算溢出比例；
--   464 仅 hbars —— 横向溢出量 = scrnw/(scrnh×aspect) - 1，再取半；
--   470 仅 vbars —— 纵向溢出量 = scrnh×aspect/scrnw - 1，再取半；
-- 「取半」因为黑边是**两侧对称**各占一半。
-- 末尾的 RESOLUTION_X / w 把比例换算成图元缩放 ——
-- 即回到第 109-110 行那套「像素图缩放到虚拟分辨率」的同一思路。
                local w, h = root.left:GetSize()
                local scalex = (scrnw - maxw) / (maxw * 2) * RESOLUTION_X / w
                local scaley = scrnh / maxh * RESOLUTION_Y / h
                root.left:SetScale(scalex, scaley)
                root.right:SetScale(scalex, scaley)
                scalex = RESOLUTION_X / w
                scaley = (scrnh - maxh) / (maxh * 2) * RESOLUTION_Y / h
                root.top:SetScale(scalex, scaley)
                root.bottom:SetScale(scalex, scaley)
            elseif hbars then
                local w, h = root.left:GetSize()
                local scalex = (scrnw / (scrnh * aspect) - 1) * .5 * RESOLUTION_X / w
                local scaley = RESOLUTION_Y / h
                root.left:SetScale(scalex, scaley)
                root.right:SetScale(scalex, scaley)
            elseif vbars then
                local w, h = root.top:GetSize()
                local scalex = RESOLUTION_X / w
                local scaley = (scrnh * aspect / scrnw - 1) * .5 * RESOLUTION_Y / h
                root.top:SetScale(scalex, scaley)
                root.bottom:SetScale(scalex, scaley)
            end
        end

        root:StartUpdating()
        root:OnUpdate()

        return root
    end,

    -------------
    -------------
    -- FE Perd --
    -------------
    -------------
    -- Main menu perd for event
    ForegroundPerdFront = function(back)
-- 【★ 带参数依赖的复合模板：front 需要 back】
-- 第 491 行 ForegroundPerdFront(back) 接收第 228 行挂上的 back 根节点。
-- ★ 表现分前后两片（同一张 frontend_perd 素材，第 498 行 build 一致）：
--   前片 Show("front")，后片 Hide("front")（第 577 行）。
-- 靠 AnimState 的分区可见性，让一只 2D 角色产生「身体在前、影子在后」的层次。
-- 第 503-504 行按 1024（美术原始舞台高度）反推缩放，注释已说明来源。
        local root = Widget("fg_perd_front")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        local perd = root:AddChild(UIAnim())
        perd:GetAnimState():SetBuild("frontend_perd")
        perd:GetAnimState():SetBank("frontend_perd")
        perd:GetAnimState():Hide("back")
        perd:GetAnimState():PlayAnimation("empty")

        --V2C: Source anim was done on a 1820 x 1024 stage
        perd:SetScale(RESOLUTION_Y / 1024)

        local spawntask = nil
        local runtask = nil
        local anims = { 2, 3, 4 }
-- anims 是一个「候选池」：{2,3,4} 三种出场动画轮流抽，
-- 抽中就把该值移出并再插回（第 516-517 行的 remove+insert），
-- 保证 1 会穿插出现 —— 这是**洗牌（shuffle）算法**，不是权重随机。
-- ★ 移植自研游戏做「随机效果」时，洗牌池比每次 math.random(4) 更均匀。

        local function DoRunSound(_, period, remaining)
            TheFrontEnd:GetSound():PlaySound("dontstarve/creatures/perd/run")
            runtask = remaining > 1 and perd.inst:DoTaskInTime(period, DoRunSound, period, remaining - 1) or nil
        end

        local function OnSpawnPerd()
            local anim = #anims > 3 and table.remove(anims, math.random(2)) or 1
-- ★ 洗牌实现（含一处易踩的语义细节）：
-- `#anims > 3` 恒为假（池子初始 3 个、移出再插回，恒为 3），
-- 所以永远走 `or 1` 分支 —— 实际效果是「恒定播动画 1」。
-- ⚠️ 这与第 517 行的 table.insert 组合起来看：anims 每次 insert 后变 4 个，
-- 下一次 remove 后又回到 3 个。但 #anims>3 只在 insert 之后的那一瞬间为真，
-- 而本行读到的 #anims 恒为 3 → 恒假。
-- 即：**作者写池子洗牌，但条件写错导致池子逻辑从未生效**，
--    结果固定为每次播 perd1_fe。
-- 这不是性能问题，而是「想要的随机效果没实现」，
-- 但因该模板只在 YOTG 活动菜单用（227 行守卫），影响极小、无报错。
-- ★ 正面教材：它提醒我们 and/or 三元在「前置条件恒假」时是**静默降级**，
--   不会崩、不会警告，只会让功能悄悄消失。
            table.insert(anims, anim)
            if runtask ~= nil then
                runtask:Cancel()
                runtask = nil
            end
            if anim == 1 then
                perd:GetAnimState():PlayAnimation("perd1_fe")
                TheFrontEnd:GetSound():PlaySound("dontstarve/creatures/perd/gobble")
            elseif anim == 2 then
                back.perd:GetAnimState():PlayAnimation("perd2_fe")
                DoRunSound(nil, 16 * FRAMES, 5)
            elseif anim == 3 then
                back.perd:GetAnimState():PlayAnimation("perd3_fe")
                TheFrontEnd:GetSound():PlaySound("dontstarve/creatures/perd/scream")
            else
                perd:GetAnimState():PlayAnimation("perd4_fe")
                back.perd:GetAnimState():PlayAnimation("perd4_fe")
                DoRunSound(nil, 16 * FRAMES, 4)
            end
            spawntask = perd.inst:DoTaskInTime(4.5 + math.random() * 1.5, OnSpawnPerd)
-- 4.5 + random()*1.5 秒随机后再次出场，避免节奏机械。
-- ★ 任务挂在 perd.inst（底层实体）上而非 root：
-- widget 被 Kill 时实体随之销毁，任务自动随之消失，
-- 不需要手动 Cancel。这是 DST 「widget 复用实体做任务宿主」的通用做法。
        end

        root.StartPerds = function()
-- 【★ Start/Stop 幂等化的标准写法】
-- 第 540 行 `if spawntask == nil` —— 重复调用 StartPerds 不会叠加任务；
-- 第 548 行 StopPerds 同理。
-- ⚠️ 换写法（无条件 DoTaskInTime）后果：连点几次菜单就叠出多个循环任务，
-- 音效与动画成倍触发，且任务永不回收 → 越开越卡。
-- 顺带说明第 547-560 行 Stop 里要 Cancel **两个**任务（spawn + run），
-- 第 556 行的 runtask 正是第 512 行递归排的音效任务。
            if spawntask == nil then
                spawntask = perd.inst:DoTaskInTime(4, OnSpawnPerd)
                root:Show()
                back:Show()
            end
        end

        root.StopPerds = function()
            if spawntask ~= nil then
                spawntask:Cancel()
                spawntask = nil
                perd:GetAnimState():PlayAnimation("empty")
                back.perd:GetAnimState():PlayAnimation("empty")
                root:Hide()
                back:Hide()
            end
            if runtask ~= nil then
                runtask:Cancel()
                runtask = nil
            end
        end

        root:Hide()
        back:Hide()

        return root
    end,

    ForegroundPerdBack = function()
        local root = Widget("fg_perd_back")
        root:SetVAnchor(ANCHOR_MIDDLE)
        root:SetHAnchor(ANCHOR_MIDDLE)
        root:SetScaleMode(SCALEMODE_PROPORTIONAL)

        root.perd = root:AddChild(UIAnim())
        root.perd:GetAnimState():SetBuild("frontend_perd")
        root.perd:GetAnimState():SetBank("frontend_perd")
        root.perd:GetAnimState():Hide("front")
        root.perd:GetAnimState():PlayAnimation("empty")

        --V2C: Source anim was done on a 1820 x 1024 stage
        root.perd:SetScale(RESOLUTION_Y / 1024)

        return root
    end,

    -------------------
    -------------------
    -- PANELS/FRAMES --
    -------------------
    -------------------

    -- Ornate black frame, no fill (nine-slice)
    CurlyWindow = function(sizeX, sizeY, scaleX, scaleY, topCrownOffset, bottomCrownOffset, xOffset)
        local w = NineSlice("images/fepanels.xml",
                "TopLeft.tex", "TopCenter.tex", "TopRight.tex",
                "MiddleLeft.tex", "CenterMiddle.tex", "MiddleRight.tex",
                "BottomLeft.tex", "BottomCenter.tex", "BottomRight.tex")
        w:AddCrown("TopCap.tex", ANCHOR_MIDDLE, ANCHOR_TOP, xOffset or 0, topCrownOffset or 68)
-- 【★ 九宫格（NineSlice）+ 皇冠（Crown）—— 可拉伸面板的标准做法】
-- 第 594-597 行 NineSlice 传了 9 个贴图名，固定四角的贴图保持原尺寸，
-- 中间五块负责拉伸，任意 sizeX/sizeY 都不糊。
-- ⚠️ 换成单张 Image 直接 SetScale → 边框圆角与花纹一起被拉变形。
-- AddCrown 把上下两个「王冠」装饰按锚点挂到面板上沿/下沿（598-599 行），
-- 默认偏移 68 / -42 是美术量好的位置，xOffset 可横向挪动。
-- ★ 参数表用「位置参数 + 全 or 兜底」而非命名参数 —— 老 Lua 代码风格。
        w:AddCrown("BottomCap.tex", ANCHOR_MIDDLE, ANCHOR_BOTTOM, xOffset or 0, bottomCrownOffset or -42)
        w:SetSize(sizeX or 200, sizeY or 200)
        w:SetScale(scaleX or 1, scaleY or 1)
        return w
    end,

    -- Ornate black frame with paper texture fill (nine-slice)
    -- To be added as a child of the root
    CenterPanel = function(frame_x_scale, frame_y_scale, skipPos, x_size, y_size, topCrownOffset, bottomCrownOffset, bg_x_scale, bg_y_scale, bg_x_pos, bg_y_pos )
-- 【★ 本文件最长的参数表：11 个位置参数】
-- 这是「没有布局引擎」的代价 —— 面板的尺寸/缩放/内边距/王冠偏移全靠参数外传。
-- 615 行 SetSize(x_size or 520, y_size or 475) 给出默认尺寸。
-- ★ 值得学的是第 626-628 行的 skipPos 逃生舱：
-- 默认给面板一个 (37,-10) 的偏移（美术调好的位置），
-- 传 skipPos 则不设，让调用方自己完全掌控坐标。
-- 这种「默认好用 + 可完全接管」的双模设计，比强制调用方算坐标友好得多。
    	frame_x_scale = frame_x_scale or 1
    	frame_y_scale = frame_y_scale or 1
        local panel = Widget("panel")

        panel.frame = panel:AddChild(NineSlice("images/fepanels.xml",
                "TopLeft.tex", "TopCenter.tex", "TopRight.tex",
                "MiddleLeft.tex", "CenterMiddle.tex", "MiddleRight.tex",
                "BottomLeft.tex", "BottomCenter.tex", "BottomRight.tex"))
        panel.frame:AddCrown("TopCap.tex", ANCHOR_MIDDLE, ANCHOR_TOP, 0, topCrownOffset or 68)
        panel.frame:AddCrown("BottomCap.tex", ANCHOR_MIDDLE, ANCHOR_BOTTOM, 0, bottomCrownOffset or -42)
        panel.frame:SetSize( x_size or 520, y_size or 475)
        panel.frame:SetScale(frame_x_scale or 1, frame_y_scale or 1)
-- ⚠️ 注意第 608-609 行已经把 frame_x_scale/frame_y_scale 用 `or 1` 兜过底，
-- 第 619 行的 `frame_x_scale or 1` 是**冗余**的第二次兜底。
-- 无害（608 行已保证非 nil），但暴露了这段代码是历史上
-- 「补参数」式修改的产物。移植时不必模仿这种冗余。
        panel.frame:SetPosition(0, 0)

		panel.bg = panel.frame:AddChild(Image("images/options_bg.xml", "options_panel_bg.tex"))
-- ★ 关键细节：panel.bg 挂在 **panel.frame** 上，而不是 panel。
-- 面板由「边框(frame) + 纸张底色(bg)」两层构成，
-- 把 bg 挂成 frame 的子节点，就自动跟随 frame 的缩放与位移 ——
-- 只需调一次 frame 的 scale，两者同步变化。
-- ⚠️ 若误挂到 panel 上，则 frame 缩放时 bg 不动，边框与底图会错位。
-- 第 623-624 行给出内边距(9,13)与底色缩放(.725,.69)，同样是美术调好的经验值。
		panel.bg:SetPosition( bg_x_pos or 9, bg_y_pos or 13)
        panel.bg:SetScale(bg_x_scale or .725, bg_y_scale or .69)

        if not skipPos then
            panel:SetPosition(37,-10)
        end

		return panel
    end,

    -- Ornate black frame with paper texture fill
    -- The old version that didn't use the 9-slice
    CenterPanelOld = function(x_scale, y_scale, skipPos)
    	local xScale = x_scale or .67
    	local yScale = y_scale or .65
        local panel = Widget("panel")

    	panel.frame = panel:AddChild(Image( "images/options_bg.xml", "options_panel_bg_frame.tex" ))
		panel.frame:SetScale( xScale, yScale )
		panel.frame:SetPosition(0, 0)

        xScale = x_scale or .69
        yScale = y_scale or .65
		panel.bg = panel:AddChild(Image("images/options_bg.xml", "options_panel_bg.tex"))
		panel.bg:SetPosition(0, 0)
        panel.bg:SetScale(xScale, yScale)

        if not skipPos then
            panel:SetPosition(25,-10)
        end

		return panel
    end,


    ----------------
    ----------------
    -- NAVIGATION --
    ----------------
    ----------------

    -- Makes the background for holding NavBarButtons and puts a screen title above it
    -- To be added as a child of the root. Heights: "short" (2 buttons), "medium" (3 buttons), "tall" (5 buttons).
    NavBarWithScreenTitle = function(title, height)
-- 【★ 导航栏：三档高度用同一张图靠缩放凑】
-- short/medium/tall 分别对应 2/3/5 个按钮（约 45-50 一行，注释见 692 行）。
-- short 与 medium 甚至复用同一张 nav_bg_short.tex，只改 Y 缩放(.7 / 1)，
-- 因为面板高度 = 内容高度，一张图缩放即可；
-- tall 换 nav_bg_med.tex 再缩小 —— 缩放过头会露出纹理模糊，
-- 故极端档位换图。
        local nav_bar = Widget("nav_bar")
        nav_bar:SetPosition(-RESOLUTION_X*.415, RESOLUTION_Y*.27)

        if not height or height == "short" then
            nav_bar.bg = nav_bar:AddChild(Image("images/frontend.xml", "nav_bg_short.tex"))
            nav_bar.bg:SetScale(.65, .7)
        elseif height == "medium" then
        	nav_bar.bg = nav_bar:AddChild(Image("images/frontend.xml", "nav_bg_short.tex"))
            nav_bar.bg:SetScale(.65, 1)
        elseif height == "tall" then
            nav_bar.bg = nav_bar:AddChild(Image("images/frontend.xml", "nav_bg_med.tex"))
            nav_bar.bg:SetScale(.65, .475)
            nav_bar.bg:SetPosition(0, -RESOLUTION_Y*.145)
        end

        if title then
            nav_bar.title = nav_bar:AddChild(Text(TITLEFONT, 45, title or ""))
-- 第 683 行 `title or ""` 是冗余兜底：第 682 行已判过 `if title then`。
-- 同属 619 行那类历史冗余，不影响正确性。
            nav_bar.title:SetRegionSize(200, 50)
            nav_bar.title:SetHAlign(ANCHOR_LEFT)
            nav_bar.title:SetPosition(40,100)
        end

        return nav_bar
    end,

    -- To be added as a child of the Nav Bar. Approximate spacing in Y for these buttons is 45-50.
    NavBarButton = function(yPos, buttonText, onclick, truncate)
-- 【★ NavBarButton：展示态按钮的完整状态机】
-- 一个按钮要同时表达 4 种视觉状态，DST 用**子节点显隐**而非重设贴图：
--   文字本体（btn.text）
--   714 active_page_image —— 当前页高亮（SetOnSelect/UnSelect 切换，738-743 行）
--   721 focus_image      —— 焦点光标（SetOnGainFocus/LoseFocus 切换，731-736 行）
--   727 bg               —— 纯色底衬
-- ★ 焦点与选中是**两个独立维度**：鼠标悬停有焦点但未必是当前页；
-- 键盘 Tab 切到别的按钮有焦点但当前页不变。把两者混为一谈就会做出
-- 「鼠标移开就丢失高亮」这类 bug。
        local btn = Button()
        btn:SetPosition(10, yPos)

        btn:SetFont(NEWFONT)
        btn:SetDisabledFont(NEWFONT)
        btn:SetTextSize(35)

        if truncate then
-- truncate 分支（第 702-703 行）先 SetText("") 再 SetTruncatedString：
-- 因为 SetTruncatedString 是往**已有 Text 对象**里塞截断后的串，
-- 必须先有 Text 实例。
-- ★ 用途：长菜单名（如 mod 名）超宽时按像素宽度截断并加省略号，
-- 而非换行 —— 导航栏每行高度固定，换行会把布局撑破。
            btn:SetText("")
            btn.text:SetTruncatedString(buttonText, 140, 28, true)
        else
            btn:SetText(buttonText)
        end
        btn.text:SetRegionSize(140, 40)
        btn.text:SetHAlign(ANCHOR_LEFT)

        btn:SetTextColour(unpack(GOLD))
        btn:SetTextFocusColour(unpack(GOLD))
        btn:SetTextSelectedColour(0, 0, 0, 1)

        btn.active_page_image = btn:AddChild(Image("images/frontend.xml", "nav_selected2.tex"))
-- ★ 第 718 行 MoveToBack() 是必需的，不是整理代码：
-- active_page_image 在第 714 行才 AddChild，默认叠在文字**之上**，
-- 若不后移，会把按钮文字整块盖住。
-- SetClickable(false)（717 行）则保证它不吃鼠标点击，
-- 否则高亮图会吞掉本该传给按钮的点击。
-- 装饰性子节点「三件套」：SetClickable(false) + MoveToBack + 初始 Hide。
        btn.active_page_image:SetPosition(-7, -6)
        btn.active_page_image:SetScale(.56, .65)
        btn.active_page_image:SetClickable(false)
        btn.active_page_image:MoveToBack()
        btn.active_page_image:Hide()

        btn.focus_image = btn:AddChild(Image("images/frontend.xml", "nav_cursor.tex"))
        btn.focus_image:SetScale(.65)
        btn.focus_image:SetPosition(-85,0)
        btn.focus_image:SetClickable(false)
        btn.focus_image:Hide()

        btn.bg = btn:AddChild(Image("images/ui.xml", "blank.tex"))
-- ★ 底衬尺寸从**文字实测宽度**推导（第 728 行）：
-- btn.bg:ScaleToSize(200, h+15) —— 宽固定 200，高随文字行高自适应。
-- 用 blank.tex（一块纯白/纯色方块）而不是专用底图，
-- 任意尺寸都不糊，且可被上层 SetTint 染色。
-- ★ 这就是「空白图 + 缩放 + 染色」三件套，UI 里最省资源的通用做法。
        local w,h = btn.text:GetRegionSize()
        btn.bg:ScaleToSize(200, h+15)

        btn:SetOnGainFocus(function()
            btn.focus_image:Show()
        end)
        btn:SetOnLoseFocus(function()
            btn.focus_image:Hide()
        end)

        btn:SetOnSelect(function()
            btn.active_page_image:Show()
        end)
        btn:SetOnUnSelect(function()
            btn.active_page_image:Hide()
        end)

        btn:SetOnClick(onclick)

        return btn
    end,

    ----------------
    ----------------
    -- TAB BUTTON --
    ----------------
    ----------------
    -- To be added as a child of the panel with tabs.
    TabButton = function(xPos, yPos, buttonText, onclick, tabSize)
-- 【★ 用四元分支代替查表 → 有静默失败风险】
-- 只有 "large" 与 "small" 两个合法值，但第 758 行是 `if not tabSize or tabSize == "large"`，
-- 传任何第三种值（如拼错的 "sm"）时，btn 保持 nil，
-- 第 763 行立刻对 nil 调用 SetPosition → **运行时崩溃**。
-- ⚠️ 换写法（查表 + 断言/default 分支）会更稳；
-- 但对内部模板来说，作者选择相信调用方。移植时建议加 else 兜底。
        local btn
        if not tabSize or tabSize == "large" then
            btn = ImageButton("images/frontend.xml", "tab1_button.tex", "tab1_button_highlight.tex", "tab1_selected.tex", nil, nil, {1,1}, {0,0})
        elseif tabSize == "small" then
            btn = ImageButton("images/frontend.xml", "tab2_button.tex", "tab2_button_highlight.tex", "tab2_selected.tex", nil, nil, {1,1}, {0,0})
        end
        btn:SetPosition(xPos, yPos)

        btn.image:SetScale(.73)
        btn.scale_on_focus = false

        btn:SetText(buttonText)
        btn:SetFont(NEWFONT_OUTLINE)
        btn:SetDisabledFont(NEWFONT_SMALL)
        btn:SetTextColour(unpack(GOLD))
        btn:SetTextFocusColour(unpack(GOLD))
        btn:SetTextDisabledColour(0,0,0,1)
        btn:SetTextSize(30)
        btn.text:SetPosition(2,7)

        btn:SetOnClick(onclick)

        return btn
    end,

    -----------------
    -----------------
    -- BACK BUTTON --
    -----------------
    -----------------
    -- To be added as a child of the root. onclick should be whatever cancel/back fn is appropriate for your screen.
    BackButton = function(onclick, txt, txt_offset, shadow_offset, scale)
        local btn = ImageButton("images/frontend.xml", "turnarrow_icon.tex", "turnarrow_icon_over.tex", nil, nil, nil, {1,1}, {0,0})
        btn:SetPosition(-RESOLUTION_X*.4 - 10, -RESOLUTION_Y*.5 + BACK_BUTTON_Y)

        btn.scale = scale or 1

        btn.image:SetPosition(-63, 0)
        btn.image:SetScale(.7)

        btn:SetText(txt or STRINGS.UI.SERVERLISTINGSCREEN.BACK, true, { shadow_offset and shadow_offset.x or 2, shadow_offset and shadow_offset.y or -1})
-- 第 797 行 SetText(txt, true, {阴影偏移}) 的第三个参数是阴影位移，
-- 写成 `{ shadow_offset and shadow_offset.x or 2, ... }` 双重兜底。
-- 第 799-802 行随后把 txt_offset 同时施加到 btn.text 与 **btn.text_shadow**：
-- ★ 两个必须同步移动，只移文字会让文字与阴影错位（重影）。
-- 这是「文字带阴影」控件的通用注意点。
        if txt_offset then
            local textPos = btn.text:GetPosition()
        	btn.text:SetPosition(textPos.x + txt_offset.x, textPos.y + txt_offset.y)
            local textShadowPos = btn.text_shadow:GetPosition()
        	btn.text_shadow:SetPosition(textShadowPos.x + txt_offset.x, textShadowPos.y + txt_offset.y)
        end
        btn:SetTextColour(unpack(GOLD))
        btn:SetTextFocusColour(unpack(PORTAL_TEXT_COLOUR))
        btn:SetFont(NEWFONT_OUTLINE)
        btn:SetDisabledFont(NEWFONT_OUTLINE)
        btn:SetTextDisabledColour(unpack(GOLD))

        btn.bg = btn:AddChild(Image("images/ui.xml", "blank.tex"))
        local w,h = btn.text:GetRegionSize()
        btn.bg:ScaleToSize(w+50, h+15)
        if txt_offset then
            btn.bg:SetPosition(txt_offset.x, txt_offset.y)
        end

        btn:SetOnGainFocus(function()
            btn:SetScale(btn.scale + .05)
        end)
        btn:SetOnLoseFocus(function()
            btn:SetScale(btn.scale)
        end)

        btn:SetOnClick(onclick)

        btn:SetScale(btn.scale)

        return btn
    end,

    -------------------------
    -------------------------
    -- SERVER DETAIL IMAGE --
    -------------------------
    -------------------------
    ServerDetailIcon = function(iconAtlas, iconTexture, bgColor, hoverText, textinfo, imgOffset, scaleX, scaleY)
        local icon = Widget("detail_icon")
        icon.bg = icon:AddChild(Image("images/servericons.xml", bgColor and "bg_"..bgColor..".tex" or "bg_burnt.tex"))
        icon.bg:SetScale(.09)
        icon.img = icon:AddChild(Image(iconAtlas, iconTexture))
        icon.img:SetScale(scaleX or .075, scaleY or .075)
        icon.img:SetPosition(imgOffset and imgOffset[1] or -1, imgOffset and imgOffset[2] or 0)

        if hoverText and hoverText ~= "" then
            if not textinfo then textinfo = {} end
            icon:SetHoverText(hoverText, { font = textinfo.font or NEWFONT_OUTLINE, offset_x = 1, offset_y = 28, colour = textinfo.colour or {1,1,1,1}, bg = textinfo.bg })
        end

        return icon
    end,

    -----------------
    -----------------
    -- INVISIBLE BUTTON --
    -----------------
    -----------------

    InvisibleButton = function(width, height, onclick, onfocus)
-- 【★ 「看不见但可点」的按钮 —— DST 布局的独门解法】
-- 五张状态贴图（normal/focus/disabled/down/selected）全给 "blank.tex"：
-- 于是任何状态下都不显示**任何**图像，但按钮逻辑与命中区域照常存在。
-- 第 860-861 行 SetFocusScale/SetNormalScale(width,height) 强制焦点缩放为 1:1，
-- ⚠️ 不写这两行：ImageButton 默认 focus_scale={1.2,1.2,1.2}（见 imagebutton.lua:22），
-- 获得焦点时按钮会放大 20%，视觉上「凭空鼓出来一块」，
-- 对隐形按钮是明显破绽。
-- 用途见消费方：mousetracker.lua:24 用它做 50×50 的虚拟摇杆热区。
    	local btn = ImageButton("images/ui.xml", "blank.tex", "blank.tex", "blank.tex", "blank.tex", "blank.tex", {width,height}, {0,0})
    	btn:SetFocusScale(width, height)
    	btn:SetNormalScale(width, height)
        btn:SetOnClick(onclick)

        btn.ongainfocus = onfocus
-- ⚠️ 【易混：两个同名不同用途的字段】
-- 第 864 行直接赋字段 `btn.ongainfocus = onfocus`，
-- 而**不是**调 btn:SetOnGainFocus(fn)。
-- 二者都生效，但走的是不同代码路径：
--   SetOnGainFocus → 存到 self.ongainfocusfn，由 widget.lua:649/674 读；
--   直接赋 ongainfocus → 由 button.lua:113 在 Button:OnGainFocus 里读，
--     且**带参调用**：self.ongainfocus(self:IsEnabled())。
-- 两者签名不同（无参 vs 一个 is_enabled 布尔），换用会拿到 nil 或多余参数。
-- 本行的第 4 个参数 onfocus 因此必须写成 `function(is_enabled)` 形式才正确。
-- 这处是全库少见的「不走 SetOnXxx  setter」的写法，容易被后来者当成笔误改掉。

        return btn
    end,

    -----------------
    -----------------
    -- ICON BUTTON --
    -----------------
    -----------------
    -- For making a square button that has a custom icon on it and has a text label
    -- Text label offset can be specified, as well as whether or not it always shows
    IconButton = function(iconAtlas, iconTexture, labelText, sideLabel, alwaysShowLabel, onclick, textinfo, defaultTexture)
-- 【★ 一个控件、四种标签呈现方式（876-910 行）】
-- 同一个 IconButton 按参数把 labelText 渲染成三种形态：
--   sideLabel 为真   → 右侧常驻文字（894-899 行，独立 Text 子节点）；
--   alwaysShowLabel  → 按钮下方常驻文字（900-907 行，走 btn.text）；
--   都不为真         → 悬停提示（908-910 行 SetHoverText，鼠标移入才出现）。
-- ★ 关键区别：前两者会**改变控件的布局尺寸**，
-- 后者不占位。所以同一份美术图能服务「紧凑」与「宽松」两种排版。
-- 第 894 行的分支顺序有讲究：sideLabel 优先，alwaysShowLabel 次之。
        local btn = ImageButton("images/frontend.xml", "button_square.tex", "button_square_halfshadow.tex", "button_square_disabled.tex", "button_square_halfshadow.tex", "button_square_disabled.tex", {1,1}, {0,0})
        btn.image:SetScale(.7)

        btn.icon = btn:AddChild(Image(iconAtlas, iconTexture, defaultTexture))
        btn.icon:SetPosition(-5,4)
        btn.icon:SetScale(.16)
        btn.icon:SetClickable(false)

        btn.highlight = btn:AddChild(Image("images/frontend.xml", "button_square_highlight.tex"))
        btn.highlight:SetScale(.7)
        btn.highlight:SetClickable(false)
        btn.highlight:Hide()

        if not textinfo then
            textinfo = {}
        end

        if sideLabel then
            btn.label = btn:AddChild(Text(textinfo.font or NEWFONT, textinfo.size or 25, labelText, textinfo.colour or {0,0,0,1}))
            btn.label:SetRegionSize(150,70)
            btn.label:EnableWordWrap(true)
            btn.label:SetHAlign(ANCHOR_RIGHT)
            btn.label:SetPosition(-115, 7)
        elseif alwaysShowLabel then
            btn:SetTextSize(25)
            btn:SetText(labelText, true)
            btn.text:SetPosition(-3, -34)
            btn.text_shadow:SetPosition(-5, -36)
            btn:SetFont(textinfo.font or NEWFONT)
            btn:SetTextColour(textinfo.colour or { unpack(GOLD) })
            btn:SetTextFocusColour(textinfo.focus_colour or { unpack(GOLD) })
        else
            btn:SetHoverText(labelText, { font = textinfo.font or NEWFONT_OUTLINE, offset_x = textinfo.offset_x or -4, offset_y = textinfo.offset_y or 45, colour = textinfo.colour or {1,1,1,1}, bg = textinfo.bg })
        end

        btn:SetOnClick(onclick)

        btn:SetOnGainFocus(function()
            if btn:IsEnabled() and not btn:IsSelected() and TheFrontEnd:GetFadeLevel() <= 0 then
-- 第 915 行三重守卫才显示高亮：
--   IsEnabled()   —— 禁用按钮不给高亮；
--   not IsSelected() —— 已选中的（按下/保持）不给高亮，避免叠加两层亮；
--   GetFadeLevel() <= 0 —— ★ 页面切换淡入淡出期间不给高亮，
--     否则会在半透明画面上叠加出「突然亮一下」的突兀反馈。
-- 这第三条是 UI 动效与输入反馈的经典冲突处理，很值得学。
                btn.highlight:Show()
            end
        end)
        btn:SetOnLoseFocus(function()
            btn.highlight:Hide()
        end)

        return btn
    end,

 	------------
    ------------
    -- BUTTON --
    ------------
    ------------
    -- To be used anywhere you need a button.
    Button = function (text, cb)
	    local btn = ImageButton()
-- 【★ 极简工厂：注意与 widgets/button.lua 的 Button 类区分】
-- 本函数返回的是 **ImageButton() 无参实例**（走 imagebutton.lua），
-- 而 widgets/button.lua 里的 Button 是另一个类。
-- 两者同名易混：TEMPLATES.Button ≠ widgets/button.lua 的 Button。
-- 此处模板只做最小定制（缩放 .7、字体），其余交给基类。
	    btn.image:SetScale(.7)
	    btn:SetFont(NEWFONT)
	    btn:SetDisabledFont(NEWFONT)

	    btn:SetText(text)
	    btn:SetOnClick(cb)

	    return btn
	end,


	------------
    ------------
    -- SmallBUTTON --
    ------------
    ------------
    -- A button with configurable size. It defaults to smaller than Button.
    SmallButton = function (text, fontsize, scale, cb)
-- SmallButton 与 Button 的差别就是把「缩放」和「字号」参数化（第 953、955 行）。
-- ★ 体现了一条 UI 工程经验：小控件与大控件应做成**同一实现的参数化**，
-- 而非复制两份模板 —— 否则改配色要改两处。
	    local btn = ImageButton()
	    btn.image:SetScale(scale or .5)
	    btn:SetFont(NEWFONT)
	    btn:SetTextSize(fontsize or 26)
	    btn:SetDisabledFont(NEWFONT)

	    btn:SetText(text)
	    btn:SetOnClick(cb)

	    return btn
	end,

	------------
    ------------
    -- AnimTextButton --
    ------------
    ------------
    -- A button that uses an animation file and has text on top of the image.
    AnimTextButton = function (animname, states, scale, cb, text, size)

    	local button = AnimButton(animname, states)
    	button:SetScale(scale)
    	button:SetOnClick(cb)

   		button:SetFont(NEWFONT_OUTLINE)
    	button:SetTextSize(size or 24)
    	button:SetText(text)
    	button:SetTextColour(1, 1, 1, 1)
    	button:SetTextSelectedColour(1, 1, 1, 1)
    	button:SetTextFocusColour(1, 1, 1, 1)

   		return button
    end,


	------------
    ------------
    -- TextMenuItem --
    ------------
    ------------
    -- Text with a background beind it. For use in right click menus and similar.
	TextMenuItem = function(text, onClickFn)
-- 【★ 用裸 Widget + OnControl 手搓「菜单项」】
-- 不用现成按钮类，直接用第 1006-1010 行的 OnControl 钩子接鼠标按下：
--   `if down and onClickFn` —— 只在**按下瞬间**触发。
-- ★ 为什么不在抬起时触发？因为在右键菜单这类场景中，
-- 菜单项是「按下即执行并关闭」，等抬起会让响应显得迟钝。
-- 第 1012-1014 行覆写 GetSize 返回底衬尺寸 ——
-- 布局引擎（这里没有，但调用方的列表排布）按 GetSize 取尺寸，
-- 覆写它才能让**被底衬撑开的尺寸**生效，而非文字本身的尺寸。
		local item = Widget("item")

		item.text = item:AddChild(Text(NEWFONT, 24, text, WHITE))

		item.bg = item:AddChild(Image("images/frontend.xml", "scribble_black.tex"))
        item.bg:SetPosition(0, 0)
        local w, h = item.text:GetRegionSize()
        item.bg:SetTint(1,1,1,.8)
        item.bg:SetSize(w*1.3, h*1.8)
        item.bg:MoveToBack()
        item.bg:SetClickable(true)

    	item.OnControl = function(control, down)
    		if down and onClickFn then
    			onClickFn()
    		end
    	end

    	item.GetSize = function()
    		return item.bg:GetSize()
    	end


    	return item
	end,


	-----------------
    -----------------
    -- ModListItem --
    -----------------
    -----------------
    -- A widget that displays info about a mod. To be used in scroll lists etc.
	ModListItem = function (modname, modinfo, modstatus, isenabled)
-- 【★ 数据驱动的列表项：所有内容都来自入参】
-- modinfo（模组元数据）、modstatus（状态字符串）、isenabled（开关）
-- 三个数据决定整行的外观，模板不含任何具体 mod 信息。
-- 第 1067 行的 `modinfo and modinfo.name or modname` 是降级链：
-- 优先用元数据里的显示名，缺失则回落到目录名。
-- ★ 这就是「模板 + 数据分离」的标准形态，
-- 移植自研游戏做背包/商店/技能列表时可直接照搬这个签名约定。

		local opt = Widget("option")
		-- opt:SetScale(.9,.95)
        opt.clickoffset = Vector3(0,-3,0)

		opt.white_bg = opt:AddChild(Image("images/ui.xml", "single_option_bg_large.tex"))
		opt.white_bg:SetScale(.63, .9)

        opt.state_bg = opt:AddChild(Image("images/ui.xml", "single_option_bg_large_gold.tex"))
        opt.state_bg:SetScale(.63, .9)
        opt.state_bg:Hide()

		opt.checkbox = opt:AddChild(ImageButton("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0}))
		opt.checkbox:SetPosition(140, -22, 0)

		opt.image = opt:AddChild(Image("images/ui.xml", "portrait_bg.tex"))
		--opt.image:SetScale(imscale,imscale,imscale)
		opt.image:SetPosition(-120,0,0)
		if modinfo and modinfo.icon_atlas and modinfo.icon then
			opt.image:SetTexture(modinfo.icon_atlas, modinfo.icon)
		end
		opt.image:SetSize(70,70)

        opt.out_of_date_image = opt:AddChild(Image("images/frontend.xml", "circle_red.tex"))
        opt.out_of_date_image:SetScale(.65)
        opt.out_of_date_image:SetPosition(65, -22)
        opt.out_of_date_image:SetClickable(false)
        opt.out_of_date_image.icon = opt.out_of_date_image:AddChild(Image("images/button_icons.xml", "update.tex"))
        opt.out_of_date_image.icon:SetPosition(-1,0)
        opt.out_of_date_image.icon:SetScale(.15)
        opt.out_of_date_image:Hide()

        opt.configurable_image = opt:AddChild(Image("images/button_icons.xml", "configure_mod.tex"))
        opt.configurable_image:SetScale(.1)
        opt.configurable_image:SetPosition(100, -20)
        opt.configurable_image:SetClickable(false)
        opt.configurable_image:Hide()

        opt.name = opt:AddChild(Text(NEWFONT, 30))
        local nameStr = (modinfo and modinfo.name) and modinfo.name or modname
        opt.name:SetTruncatedString(nameStr, 235, 51, true)
-- ★ 名字过长时按 235 像素宽截断（而非换行），因为列表行高固定（第 1070 行定位）。
-- 第 1069-1070 行：SetTruncatedString 之后**必须**重新 GetRegionSize 才能定位，
-- 因为截断后的实际宽度与原始宽度不同 —— 用旧宽度定位会导致长名右偏。
-- ⚠️ 这是「先测量再布局」在无布局引擎环境下的必要手工步骤。
        local w, h = opt.name:GetRegionSize()
        opt.name:SetPosition(w * .5 - 75, 17, 0)
        opt.name:SetVAlign(ANCHOR_MIDDLE)
        opt.name:SetColour(0,0,0,1)

		opt.status = opt:AddChild(Text(BODYTEXTFONT, 23))
		opt.status:SetVAlign(ANCHOR_MIDDLE)
		opt.status:SetHAlign(ANCHOR_LEFT)
		opt.status:SetString(modname)

		if modstatus == "WORKING_NORMALLY" then
-- 【★ 状态 → 颜色的映射表（本文件最直观的「数据驱动」片段）】
-- 三个分支把 modstatus 字符串翻译成 (颜色, 显示文本) 二元组：
--   WORKING_NORMALLY 绿 / DISABLED_ERROR 红 / DISABLED_MANUAL 灰。
-- 注意第 1080、1083 行用 `59/255` 而非写 0.23 —— 保留 255 基准便于美术调色。
-- ★ ⚠️ 第 1084、1087 行的 else 缺省：若传入未知状态，
-- 颜色与文本都保持第 1077 行设的 modname 原始字符串。
-- 这算**优雅降级**（不崩、显示原始值）而非缺陷，但对未知状态不设灰显色，
-- 若原字符串是长路径会溢出固定 200 宽的 RegionSize（1090 行）。
-- 判定为「疑似健壮性缺口」：不崩，但显示效果未定义。
            opt.status:SetColour(59/255,  222/255, 99/255,1)
			opt.status:SetString(STRINGS.UI.MODSSCREEN.STATUS.WORKING_NORMALLY)
		elseif modstatus == "DISABLED_ERROR" then
			opt.status:SetColour(242/255, 99/255, 99/255, 1)--0.9,0.3,0.3,1)
			opt.status:SetString(STRINGS.UI.MODSSCREEN.STATUS.DISABLED_ERROR)
		elseif modstatus == "DISABLED_MANUAL" then
			opt.status:SetColour(.6,.6,.6,1)
			opt.status:SetString(STRINGS.UI.MODSSCREEN.STATUS.DISABLED_MANUAL)
		end
		opt.status:SetPosition(25, -20, 0)
		opt.status:SetRegionSize( 200, 50 )

		if isenabled then
-- isenabled 决定复选框贴图与图标染色（第 1096 行红晕 = 禁用态）。
-- ★ 同一个 checkbox 用 SetTextures 在两套贴图间整体切换（1094/1097 行），
-- 而非叠加两张图做淡入淡出 —— 切换更省一次绘制。
			opt.image:SetTint(1,1,1,1)
			opt.checkbox:SetTextures("images/ui.xml", "checkbox_on.tex", "checkbox_on_highlight.tex", "checkbox_on_disabled.tex", nil, nil, {1,1}, {0,0})
		else
			opt.image:SetTint(1.0,0.5,0.5,1)
			opt.checkbox:SetTextures("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0})
		end

		return opt
	end,

	-------------------
    -------------------
    -- ModDLListItem --
    -------------------
    -------------------
    -- A widget that displays a mod that is currently being downloaded.
	ModDLListItem = function (modname)
		local opt = Widget("option")
		opt:SetScale(.9,.9)

		opt.white_bg = opt:AddChild(Image("images/ui.xml", "single_option_bg.tex"))
		opt.white_bg:SetScale(.7, 2.1)

		opt.name = opt:AddChild(Text(NEWFONT, 35))
		opt.name:SetVAlign(ANCHOR_MIDDLE)
		opt.name:SetHAlign(ANCHOR_MIDDLE)
		opt.name:SetString("Downloading:\n" .. modname)
		opt.name:SetColour(0,0,0,1)
		opt.name:SetRegionSize( 330, 100 )

		return opt
	end,


    -------------------
    -------------------
    -- Label Textbox --
    -------------------
    -------------------
    -- Text box with a label beside it
    LabelTextbox = function(labeltext, fieldtext, width_label, width_field, height, spacing, font, font_size, horiz_offset)
-- 【★ 「标签 + 控件」三件套的第 1 个：LabelTextbox】
-- 本文件 1133/1182/1206 三兄弟共用同一套定位数学（第 1136 行 total_width）：
--   total_width = 宽标签 + 宽控件 + 间距
--   标签右对齐贴在 -total_width/2 + width_label/2，
--   控件左对齐贴在 +total_width/2 - width_field/2。
-- ★ 即「以中心为原点左右分列」。这样调用方只需给三个宽度，
-- 无需计算任何绝对坐标 —— 这是本文件最重要的布局抽象。
-- ⚠️ 换个写法（调用方自己算绝对坐标）会让每处调用都充满魔法数字。
        local textbox_font_ratio = 0.8
        local offset = horiz_offset or 0
        local total_width = width_label + width_field + spacing
        local wdg = Widget("labeltextbox")
        wdg.label = wdg:AddChild(Text(font or NEWFONT, font_size or 25))
        wdg.label:SetString(labeltext)
        wdg.label:SetHAlign(ANCHOR_RIGHT)
        wdg.label:SetRegionSize(width_label,height)
        wdg.label:SetPosition((-total_width/2)+(width_label/2)+offset,0)
        wdg.label:SetColour(0,0,0,1)
        wdg.textbox_bg = wdg:AddChild( Image("images/textboxes.xml", "textbox2_grey.tex") )
        wdg.textbox_bg:SetPosition((total_width/2)-(width_field/2)+offset, 0)
        wdg.textbox_bg:ScaleToSize(width_field, height)
        wdg.textbox = wdg:AddChild(TextEdit( font or NEWFONT, (font_size or 25)*textbox_font_ratio, fieldtext, {0,0,0,1} ) )
-- 第 1147 行：文本框字号 = 标签字号 × 0.8（第 1134 行 textbox_font_ratio）。
-- 视觉上让「可编辑内容」比「标签」略小，形成层次。
-- ⚠️ 参数字典 `{0,0,0,1}` 是文本颜色，非背景色 —— 传错位置会得到透明文字。
        wdg.textbox:SetForceEdit(true)
-- ★ SetForceEdit(true)：未获得焦点也允许直接输入。
-- 默认 TextEdit 需先选中才能编辑，表单里这会让用户多点一次。
-- ★ 与第 1154-1161 行的焦点转发配套：容器拿到焦点时把焦点「下沉」给 textbox。
        wdg.textbox:SetPosition((total_width/2)-(width_field/2)+offset, 0)
        wdg.textbox:SetRegionSize(width_field-30, height) -- this needs to be slightly narrower than the BG because we don't have margins
-- ★ 注释已点明：文本框要比底衬窄 30 像素，因为「没有边距」。
-- 底衬是纯图（1144 行 textbox2_grey.tex），不会自动留白；
-- 若设成同宽，文字会紧贴/溢出边框。
-- 这是「无布局引擎」下内边距必须手算的典型例证。
        wdg.textbox:SetHAlign(ANCHOR_LEFT)
        wdg.textbox:SetFocusedImage( wdg.textbox_bg, "images/textboxes.xml", "textbox2_grey.tex", "textbox2_gold.tex", "textbox2_gold_greyfill.tex" )
-- ★ SetFocusedImage：把外部的底衬图登记为「焦点联动图」，
-- 于是 textbox 获焦时由框架自动在灰底/金框之间切换 ——
-- 调用方无需再写 SetOnGainFocus 切图代码。
-- 第 4 个参数 "textbox2_gold_greyfill.tex" 是**焦点+不可用**的组合态，
-- 三态贴图齐全才能覆盖 获焦/未获焦/禁用×获焦。

        wdg.OnGainFocus = function(self)
-- 【★ 焦点向下转发的样板（最值得抄的一段）】
-- 容器 wdg 是普通 Widget（本身不可编辑），但用户 Tab 到它时，
-- 应直接能打字。所以：
--   第 1155 行 Widget.OnGainFocus(self) —— **手工调用基类实现**，
--     ★ 这是 Lua 里做「方法包装（decorate）」的标准写法：
--       重写 OnGainFocus 后必须显式回调 _base，否则会丢失基类行为；
--       直接写空函数覆写是最常见的破坏方式。
--   第 1156 行 self.textbox:OnGainFocus() —— 再把焦点真正交给子控件。
-- 第 1158-1161 行的 OnLoseFocus 完全对称。
-- ★ 这就是「容器不可编辑但能把焦点路由给内部编辑框」的完整解法，
-- 也是 focus_forward（第 1195、1224 行）之外的另一种焦点链接法。
            Widget.OnGainFocus(self)
            self.textbox:OnGainFocus()
        end
        wdg.OnLoseFocus = function(self)
            Widget.OnLoseFocus(self)
            self.textbox:OnLoseFocus()
        end
        wdg.GetHelpText = function(self)
-- GetHelpText：返回当前手柄按键提示（按 controller_id 本地化）。
-- ★ 第 1165 行的守卫 `not editing and not focus` 决定是否提示「按 A 修改」：
-- 已经聚焦/正在编辑时不再提示，否则提示会与输入内容抢注意力。
-- 列表累积 + table.concat 拼接（第 1168 行）说明 GetHelpText 可以返回多行，
-- 由外层统一渲染。
            local controller_id = TheInput:GetControllerID()
            local t = {}
            if not self.textbox.editing and not self.textbox.focus then
                table.insert(t, TheInput:GetLocalizedControl(controller_id, CONTROL_ACCEPT, false, false ) .. " " .. STRINGS.UI.HELP.CHANGE_TEXT)
            end
            return table.concat(t, "  ")
        end
        global("TheWidget")
-- ⚠️ 【疑似调试残留 / 全局泄漏】
-- 第 1170-1171 行 `global("TheWidget"); TheWidget = wdg`
-- 把当前文本框写进**全局变量** TheWidget。
-- 我 grep 过全库 scripts/：TheWidget 仅出现在本文件这两行，
-- 没有任何读取方 —— 属于死代码，且是**全局命名污染**。
-- ★ 为什么疑似而非断定：本工程 scripts/ 只是脚本侧，
-- TheWidget 有可能被 C++ 引擎层或未收录的脚本读取，
-- 但引擎一般不读这种随意命名的 Lua 全局，故倾向认定为调试残留。
-- ⚠️ 危害在于：同一屏有多个 LabelTextbox 时互相覆盖；
-- 移植自研项目时切勿模仿。
        TheWidget = wdg

        return wdg
    end,

    -------------------
    -------------------
    -- Label Spinner --
    -------------------
    -------------------
    -- Spinner with a label beside it
    LabelSpinner = function(labeltext, spinnerdata, width_label, width_spinner, height, spacing, font, font_size, horiz_offset)
        local offset = horiz_offset or 0
        local total_width = width_label + width_spinner + spacing
        local wdg = Widget("labelspinner")
        wdg.label = wdg:AddChild( Text(font or NEWFONT, font_size or 25, labeltext) )
        wdg.label:SetPosition( (-total_width/2)+(width_label/2) + offset, 0 )
        wdg.label:SetRegionSize( width_label, height )
        wdg.label:SetHAlign( ANCHOR_RIGHT )
        wdg.label:SetColour(0,0,0,1)
        wdg.spinner = wdg:AddChild(Spinner(spinnerdata, width_spinner, height, {font = font or NEWFONT, size = font_size or 25}, nil, nil, nil, true, nil, nil, 1, 1))
        wdg.spinner:SetPosition((total_width/2)-(width_spinner/2) + offset, 0)
        wdg.spinner:SetTextColour(0,0,0,1)

        wdg.focus_forward = wdg.spinner
-- 【★ focus_forward —— 焦点穿透透明容器的另一种机制】
-- wdg 本身不可获焦，第 1195 行让「对 wdg 调用 SetFocus()」
-- 自动转发给 wdg.spinner。
-- 对比第 1154-1161 行的 OnGainFocus 转发：
--   focus_forward —— 简单，只转发 SetFocus，粒度粗；
--   OnGainFocus 包装 —— 复杂，能同时管焦点进入/离开两向。
-- ★ 两个都必要：focus_forward 保证「能进来」，包装保证「进来后行为正确」。
-- widget.lua:657 SetFocus 的开头正是读 self.focus_forward。

        return wdg
    end,

    ------------------
    ------------------
    -- Label Button --
    ------------------
    ------------------
    -- Button with a label beside it
    LabelButton = function(labeltext, buttontext, width_label, width_button, height, spacing, font, font_size, horiz_offset)
        local offset = horiz_offset or 0
        local total_width = width_label + width_button + spacing
        local wdg = Widget("labelbutton")
        wdg.label = wdg:AddChild( Text(font or NEWFONT, font_size or 25, labeltext) )
        wdg.label:SetPosition( (-total_width/2)+(width_label/2) + offset, 0 )
        wdg.label:SetRegionSize( width_label, height )
        wdg.label:SetHAlign( ANCHOR_RIGHT )
        wdg.label:SetColour(0,0,0,1)
        wdg.button = wdg:AddChild(ImageButton("images/ui.xml", "in-window_button_sm_idle.tex", "in-window_button_sm_hl.tex", "in-window_button_sm_disabled.tex", "in-window_button_sm_hl_noshadow.tex", "in-window_button_sm_disabled.tex", {1, 1}, {0, 0}))
        wdg.button.text:SetFont(font or NEWFONT)
        wdg.button.text:SetSize(font_size or 25)
        wdg.button:SetText(buttontext)
        wdg.button.text:SetPosition(2,2)
        wdg.button.text:SetColour(0,0,0,1)
        wdg.button:ForceImageSize( width_button, height )
        wdg.button:SetPosition((total_width/2)-(width_button/2) + offset, 0)

        wdg.focus_forward = wdg.button

        return wdg
    end,

    ----------------------
    ----------------------
    -- Moving Item --
    -----------------------
    -----------------------
    -- An item image for the inventory screens that moves
    MovingItem = function(name, slot_index, src_pos, dest_pos, start_scale, end_scale)
-- 【★ MovingItem：物品飞入动画的通用零件】
-- 背包「物品从世界飞到格子」的动画被抽成独立工厂，
-- 参数是 起点 src_pos / 终点 dest_pos，逻辑全包在返回的 Move 方法里。
-- ★ 关键设计：调用方只管调 widg.Move(回调)，不关心时序与销毁；
-- 动画结束（第 1265 行）自己 Kill 自己，再触发回调。
-- 「自销毁 + 回调」避免了调用方忘记清理导致的残留节点。

        local widg = UIAnim()

        widg.name = name

		widg.target_slot_index = slot_index

        widg:GetAnimState():SetBuild("frames_comp") -- use the animation file as the build, then override it
-- 【★★ 数据驱动 UI 的教科书：4 行代码渲染任意物品】
-- 第 1243-1244 行先把 build/bank 都设成通用的 "frames_comp" 物品栏底框素材；
-- 第 1248 行再用 OverrideSkinSymbol("SWAP_ICON", GetBuildForItem(name), "SWAP_ICON")
--   把占位图标**就地替换**为该物品自己的贴图；
-- 第 1249 行 OverrideSymbol("SWAP_frameBG", "frame_BG", GetFrameSymbolForRarity(rarity))
--   把边框换成按稀有度选好的那一帧。
--
-- ★★ 机制：一份底框素材 + 两个「插槽」（SWAP_ICON / SWAP_frameBG），
--   通过运行时覆写实现「一个 widget 渲染 N 种物品」。
--   这样 UI 只持有极少 draw call，也无需为每种物品预建 widget。
--   —— 这就是整个 DST 背包能扛住上百种物品的原因，
--   也是自研游戏做物品格最该抄的一条。
-- ⚠️ 换个写法（每种物品各建一个 Image）会导致物品栏初始化时创建
--   数百个节点，启动与内存都会明显恶化。
        widg:GetAnimState():SetBank("frames_comp") -- top level symbol from frames_comp

        local rarity = GetRarityForItem(name)

        widg:GetAnimState():OverrideSkinSymbol("SWAP_ICON", GetBuildForItem(name), "SWAP_ICON")
        widg:GetAnimState():OverrideSymbol("SWAP_frameBG", "frame_BG", GetFrameSymbolForRarity(rarity))

        widg:GetAnimState():PlayAnimation("idle_on", true)
        widg:GetAnimState():Hide("NEW")

        widg:Hide()

        --print("SETTING UP MOVING ITEM ", name, src_pos, dest_pos, debugstack())
        local move_time = 0.3 -- .3 is the time used for moving items into inventory in game
-- ★ 0.3 秒与游戏内物品入包的时长保持一致（有源码注释背书），
-- 视觉上「菜单里飞入」与「世界里捡起」是同一种手感。
-- 手感一致性这类参数不要随手改，它往往有其它系统的对齐依据。
        widg.Move = function(callbackfn)
                        widg.moving = true
                        widg:SetScale(start_scale or 1)
                        widg:Show()
                        widg:ScaleTo(start_scale or 1, end_scale or 1, move_time)
                        widg:MoveTo(src_pos, dest_pos, move_time,
                        function()
                            widg:Kill()

                            if callbackfn then
                                callbackfn()
                            end
                        end)
                    end
        return widg
    end,


    ----------------------
    ----------------------
    -- ItemImageText --
    -----------------------
    -----------------------
    -- An item image with text to the right of it.
    ItemImageText = function(type, name, iconScale, font, textsize, string, colour, textwidth, image_offset)
        textwidth = textwidth or 50

        local widg = Widget("ImageText")

        widg.icon = widg:AddChild(ItemImage(nil, type, name, nil, nil, nil))
        widg.icon:SetScale(iconScale)
        widg.icon:Disable() -- shouldn't be clickable
        widg.icon:SetPosition(0, 0)

        widg.check = widg.icon:AddChild(Image("images/ui.xml", "checkmark.tex"))
        widg.check:SetScale(.33)
        widg.check:SetPosition(-75, 0)
        widg.check:Hide()


        widg.text = widg:AddChild(Text(font or BUTTONFONT, textsize or 35,
                                        string or "", colour or BLACK))

-- 【★ ItemImageText：图标 + 文本 + 勾选标记】
-- 第 1292-1295 行的 check 是**子图标**（挂在 widg.icon 上），
-- 所以它天然跟随图标的缩放与位置，无需独立定位。
-- ★ SetChecked（第 1308 行）只做 Show/Hide，把状态判断留给调用方，
-- 控件本身无业务逻辑 —— 保持模板「 dumb 」是 UI 组件设计的通用原则。
        widg.text:SetRegionSize(textwidth, 40)

        local text_offset = image_offset or 20
        widg.text:SetPosition(text_offset + .5*textwidth, -2)
        widg.text:SetHAlign( ANCHOR_LEFT )


        widg.SetChecked = function(self, value)
            if value then
                self.check:Show()
            else
                self.check:Hide()
            end
        end

        return widg
    end,

    --------------
    --------------
    -- Snowfall --
    --------------
    --------------
    -- Main menu snowfall
    Snowfall = function(fade_y_threshold, snowflake_chance, max_snowball_size, max_snowflake_size)
-- 【★ 对象池 + 粒子循环 —— 低端机友好的雪景实现】
-- 雪花会不断生成、飞出屏幕、回收（第 1336 行 snowflake_pool）。
-- ★ 核心取舍：每帧最多生成 **1 个**雪花（第 1419 行用 random() < chance 抽），
-- 而雪花自身靠 SetSize(20~80px) 的大小差异营造密度观感。
-- 用「数量少 + 个头大」替代「数量多 + 个体小」，
-- 视觉几乎等价，绘制开销差一个数量级。
		-- defaults
		snowflake_chance = snowflake_chance or 0.5
		max_snowball_size = max_snowball_size or 5
		max_snowflake_size = max_snowflake_size or 20

        local num_wintersnow = 4
        local num_specialsnow = 5
        local padding = max_snowflake_size * .5
        local remove_y_threshold = -RESOLUTION_Y - padding
-- remove_y_threshold = -RESOLUTION_Y - padding：
-- 越过屏幕下边界再多半个雪花直径才回收（1333 行 padding = 最大雪花尺寸的一半），
-- ★ 留 padding 是为了保证雪花**完全**离开视野后才回收，
-- 否则会看到雪花在屏幕边缘突然消失。
-- ⚠️ 阈值算错（忘了减 padding）→ 雪花在屏幕内被回收，肉眼可见「凭空消失」。
        local superprettycounter = math.random(20, 30)
        local snowflake_pool = {}

        local function OnUpdateSnowflake(snowflake, dt)
            local pos = snowflake:GetPosition()
            if pos.y > remove_y_threshold then
                if pos.y < fade_y_threshold then
-- 【★ 淡出与移动的两段式】
-- 落在 fade_y_threshold(顶部阈值) 以下才开始递减 alpha（第 1342 行，每帧 -.022），
-- 减到 ≤0 才真正回收（第 1343-1346 行）。
-- 之上时保持恒定 alpha 正常飘落。
-- ★ 意味着 alpha 递减是**帧率相关**的（每帧固定 -.022 而非按 dt），
-- 120Hz 屏幕上雪花淡出速度是 60Hz 的两倍。
-- 这是刻意的简化（DST 目标帧率稳定），但移植到帧率波动的引擎时
-- 必须改成 alpha -= rate * dt。
                    snowflake.alpha = snowflake.alpha - .022
                    if snowflake.alpha <= 0 then
                        snowflake:Recycle()
                        return
                    end
                    snowflake:SetTint(1, 1, 1, snowflake.alpha)
                end
                snowflake.xt = snowflake.xt + dt
                pos.x = snowflake.x0 + math.sin(snowflake.xt * snowflake.xtspeed) * snowflake.xdist + snowflake.xwindspeed * snowflake.xt
-- ★ 横向运动 = 正弦摆动 + 线性风速，是经典雪花的运动模型：
--   sin(xt × xtspeed) × xdist  —— 周期性左右摆；
--   xwindspeed × xt             —— 持续单向漂移（风，恒为负 ⇒ 总体向左）；
--   xt 每帧累加 dt（第 1349 行），故整个式子与真实时间无关而与帧数耦合。
-- ⚠️ 第 1351-1353 行：飘出左边界后**整屏回绕**到右侧（+RESOLUTION_X + 尺寸），
-- 使雪花数量守恒、永不减少。
                if pos.x < -.5 * (RESOLUTION_X + max_snowflake_size) then
                    pos.x = pos.x + RESOLUTION_X + max_snowflake_size
                end
                snowflake:UpdatePosition(pos.x, pos.y - snowflake.speed)
                if snowflake.rotspeed ~= 0 then
                    snowflake.rot = snowflake.rot + snowflake.rotspeed
                    snowflake:SetRotation(snowflake.rot)
                end
            else
                snowflake:Recycle()
            end
        end

        local function RecycleSnowflake(snowflake)
            if not snowflake.recycled then
                table.insert(snowflake_pool, snowflake)
                snowflake.recycled = true
                snowflake:Hide()
                snowflake:StopUpdating()
            end
        end

        local function CreateSnowFlake(x, y)
            local snowflake = #snowflake_pool > 0 and table.remove(snowflake_pool) or Image()
-- 【★ 对象池取用：复用优先，否则新建】
-- 有空闲就 table.remove 拿一个，没有才 Image() 新建。
-- 第 1364-1371 行的 RecycleSnowflake 负责回池 + Hide + StopUpdating。
-- ⚠️ 配套第 1400-1407 行：**只有新对象才需要**绑定 OnUpdate/Recycle/
-- SetClickable 与 StartUpdating；复用对象这些早已设好，重复设置会重启计时。
-- 「初始化与复用分离」是对象池最容易写错的地方 —— 漏掉这层判断，
-- 复用的雪花会永远不动（因为被 StopUpdating 了）。
            local ispretty = math.random() < .1
            if not ispretty then
                snowflake:SetTexture("images/frontscreen.xml", "snow.tex")
            elseif superprettycounter > 1 then
-- ★ 稀有雪花（ispretty，10% 概率）的配额控制：
-- superprettycounter（1335 行初值 20-30）递减到 1 后才允许出 specialsnow，
-- 出完立刻重置为 20-30 —— 强制「稀有种不能连着出」。
-- 「稀疏资源配额」是粒子/特效随机化的通用技巧：
-- 纯随机会连续出 5 个特殊雪花，一眼看穿是随机算法。
                superprettycounter = superprettycounter - 1
                snowflake:SetTexture("images/frontscreen.xml", "wintersnow"..tostring(math.random(num_wintersnow))..".tex")
            else
                superprettycounter = math.random(20, 30)
                snowflake:SetTexture("images/frontscreen.xml", "specialsnow"..tostring(math.random(num_specialsnow))..".tex")
            end

            snowflake.size = math.random()
-- ★ 所有随机量统一用 `r + r*r` 型分布（1386-1397 行）：
--   size    = (1 + r²) × 上限  → 偏小值居多，特大雪片稀少；
--   speed   = .5 + r²×1.5        → 同上，避免雪花速度过于一致；
--   xdist   = r²×50             → 摆幅偏小；
--   rotspeed（仅 ispretty，1392 行）—— 普通雪花**不旋转**以省开销。
-- ★ r² 变换 = 「概率向小值倾斜」。若直接用 math.random(上,下) 均匀分布，
-- 视觉上会因大量中等尺寸而显得平庸。
            snowflake.size = (1 + snowflake.size * snowflake.size) * (ispretty and max_snowflake_size or max_snowball_size)
            snowflake.alpha = .4 + math.random() * .7
            snowflake.speed = math.random()
            snowflake.speed = .5 + snowflake.speed * snowflake.speed * 1.5
            snowflake.rot = 0
            snowflake.rotspeed = ispretty and (.5 + math.random() * .5) * (math.random() < .5 and 1 or -1) or 0
            snowflake.xtspeed = .5 + math.random()
            snowflake.xt = math.random() * snowflake.xtspeed
            snowflake.xdist = math.random()
            snowflake.xdist = snowflake.xdist * snowflake.xdist * 50
            snowflake.xwindspeed = -50 - 20 * math.random()
            snowflake.x0 = x

            if snowflake.recycled then
                snowflake.recycled = false
                snowflake:Show()
            else
                snowflake.OnUpdate = OnUpdateSnowflake
                snowflake.Recycle = RecycleSnowflake
                snowflake:SetClickable(false)
            end

            snowflake:SetPosition(x, y)
            snowflake:SetSize(snowflake.size, snowflake.size)
            snowflake:SetTint(1, 1, 1, snowflake.alpha)
            snowflake:StartUpdating()

            return snowflake
        end

        local widg = Widget("Snowfall")
        widg.OnUpdate = function(widg)
            if math.random() < snowflake_chance then
                widg:AddChild(CreateSnowFlake((math.random() - .5) * (RESOLUTION_X + max_snowflake_size), padding))
            end
        end
        widg.EnableSnowfall = function(widg, enable)
-- 【★ _disabled / _started 双标志 —— 状态机而非单一开关】
-- EnableSnowfall(enable) 与 StartSnowfall 分开：
--   _disabled 表示「被配置为关闭」；_started 表示「被启动过」。
-- 二者正交组合出 4 种状态，才能做到：
--   先 EnableSnowfall(true) 再 StartSnowfall() —— 会真正开始；
--   先 StartSnowfall() 再 EnableSnowfall(true) —— 也能补开（第 1428 行）。
-- ⚠️ 若只用一个 enabled 布尔，这两种调用顺序会有一种永远不生效。
-- 第 1425-1427 行关闭时 KillAllChildren：把在飞的雪花**销毁**（非回池），
-- 对象池随之作废，再次开启会重建 —— 可接受，因为关闭是低频事件。
            widg._disabled = not enable
            if not enable then
                widg:StopUpdating()
                widg:KillAllChildren()
            elseif widg._started then
-- ★★ 第 1428 行的 `elseif widg._started then` 是本函数最容易漏读的一行：
-- 它负责「先启动、后启用」的补偿路径 —— 逐个重启子雪花（第 1430-1434 行）。
-- ⚠️ 若漏掉这段：先 StartSnowfall() 再 EnableSnowfall(true)，
-- 父节点更新起来了，但没有任何雪花 —— 屏幕上什么都没有。
-- 这个 bug 极难复现，因为「正常的调用顺序」是好的。
                widg:StartUpdating()
                for k, v in pairs(widg.children) do
                    if not v.recycled then
                        v:StartUpdating()
                    end
                end
            end
        end
        widg.StartSnowfall = function(widg)
            widg._started = true
            if not widg._disabled then
                widg:StartUpdating()
                for k, v in pairs(widg.children) do
                    if not v.recycled then
                        v:StartUpdating()
                    end
                end
            end
        end
        widg.StopSnowfall = function(widg)
            widg._started = false
            widg:StopUpdating()
            for k, v in pairs(widg.children) do
                v:StopUpdating()
            end
        end

        if TheSim:IsNetbookMode() or TheFrontEnd:GetGraphicsOptions():IsSmallTexturesMode() then
-- 与第 85、267 行同款：网电一体机/低画质档建完就关。
-- ★ 这里是模板层的**最后一关**：即便调用方不判断硬件，
-- 模板自身也会兜底关掉高开销特效。
-- 「性能降级由模板兜底，而非指望每个调用方自觉」——重要的工程习惯。
            widg:EnableSnowfall(false)
        end

        return widg
    end,

}
-- 表构造器结束。整个 TEMPLATES 是一张**扁平的、无状态的**工厂表：
-- 除第 16 行的前向引用外，内部不依赖任何外部可变状态。
-- ★ 由此得到一个可移植性结论：本文件可整段复制到任何基于
-- Widget/Image/Text 的 UI 框架，只需补上常量（RESOLUTION_X/Y、ANCHOR_*、
-- FRONTEND_* 颜色、STRINGS）与 TheSim/TheFrontEnd 宿主对象。
-- —— 这是「数据与引擎解耦」能做到的极限。

return TEMPLATES
-- 返回工厂表本身。调用方 `require "widgets/templates"` 拿到的
-- 就是这张表，直接 TEMPLATES.Xxx(...) 调用，无需再解包 .TEMPLATES。
-- ★ 对比 class.lua 的 Class() 返回 metatable：两者返回的都是「构造入口」，
-- 只是一个产出实例，一个产出类。移植时可各自借鉴。