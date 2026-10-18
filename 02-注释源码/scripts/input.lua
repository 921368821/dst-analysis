--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：input.lua（780 行）
-- 模块：UI 系统 / 输入系统（Input，全局单例 TheInput）
-- 职责：把**键盘、鼠标、手柄、Steam Deck 虚拟键盘**四类物理输入
--   抽象成三套语义化事件（按键 / 鼠标 / 控制码），并在input.lua:163
--   完成「UI vs 游戏」的仲裁。同时它承担**控制方案（control scheme）**
--   的解释工作——这是手柄能玩这个游戏的全部秘密（301-477）。
--
-- ★★ 全文件最重要的认知一：**两层抽象，各解决一个问题**。
--   第一层「物理 → 语义」：
--     · Raw key      OnRawKey（186）—— 物理键码 KEY_*，不含设备信息。
--       谁需要「按了退格」这种语义，谁用它。
--     · Control       OnControl（163）—— 抽象动作码 CONTROL_ACCEPT /
--       CONTROL_ATTACK / CONTROL_FOCUS_UP…。**按键绑定在这一层完成**：
--       「A 键」被绑到 CONTROL_ACCEPT，游戏逻辑只认 CONTROL_ACCEPT。
--       ★ 这就是「同一个游戏能被手柄/键鼠/Steam Deck 玩」的根本原因。
--       参见 widgets/controls.lua 与 screens/controlsscreen*.lua。
--   第二层「虚拟控制（VIRTUAL_CONTROL_*)」——**手柄专属的一层**：
--     · 339-477 ResolveVirtualControls 把 VIRTUAL_CONTROL_* 翻译成
--       真正的 CONTROL_*，翻译规则取决于当前控制方案（1..7）。
--     · 为什么需要这一层？因为手柄上「R 摇杆」在方案 4 里是
--       物品栏导航、在方案 5 里是瞄准、在方案 6 里又变回导航。
--       同一个物理输入在不同方案下要打到不同的逻辑控制码上。
--     · ★ VIRTUAL_CONTROL_START = 10000（constants.lua:246）——
--       用一个大偏移把「虚拟层」和「物理层」在同一个整数空间里区分开，
--       于是 IsControlPressed 可以同时接受两种编号并自动判别（480行）。
--       这是本文件最漂亮的一处设计：**用数值区间代替类型系统**。
--
-- ★★ 全文件最重要的认知二：**仲裁点在163-170，只有一处**。
--     if (鼠标可用 or 非鼠标键) and not TheFrontEnd:OnControl(...) then
--         广播给 oncontrol 的全部监听者（游戏层）
--     end
--   · 前端（UI）**先**问，返回 true = UI 吃掉了，这次输入不进游戏层。
--   · 这个顺序是对的（bug-patterns.md G3 的「✅ 正确做法」）。
--   · 但 164-165 行有一个**特例逃逸**：当鼠标不可用（主机/专用服务器）时，
--     CONTROL_PRIMARY / CONTROL_SECONDARY **绕过 UI 直接进游戏层**。
--     ⚠ 疑似缺陷：这条豁免意味着主机上点击 UI 可能漏给游戏层。
--       推理依据见 164-165 行注释。
--
-- ★★ 已收录缺陷 G3 的准确根因链（三处，缺一不可）：
--   【环节一】input.lua:163-170 —— UI 在**抬起帧**才返回 true。
--     Button:OnControl（widgets/button.lua:56）在 down 时只做视觉与音效，
--     返回 true；真正 onclick 在**抬起**时（button.lua:80-86）。
--     而 playercontroller.lua:3133-3137 是**每帧轮询**式读
--     `self:IsControlPressed(CONTROL_PRIMARY)`，不是事件驱动。
--     ⇒ 按下那一帧，轮询读到「鼠标已按下」→ 判定为攻击。
--   【环节二】playercontroller.lua:4603 / 4804 —— 攻击发起时把目标
--     写进 `self.inst.sg.statemem.retarget`，状态图据此继续连击。
--   【环节三】frontend.lua:439-448 —— UI 在抬起帧消费后，
--     **显式把 retarget 清空**（这个 #HACK 就是修复本体）。
--   ★ 为什么必须这样打补丁？因为【环节一】的轮询式设计改不动——
--     playercontroller 有大量「按住持续攻击」的语义需要轮询。
--     ⇒ 结论：G3 的根因是**轮询式消费 + 事件式仲裁**两种模型混用，
--     而不是一个可以「顺手修好」的笔误。
--
-- ★★ 已收录缺陷 G3 之外的 G1/G2/G4 与本文件的关系：
--   · G1（焦点指向已销毁控件）：本文件不参与；根因在
--     widgets/screen.lua:35 与 frontend.lua:1093-1143。
--   · G2（透明 Image 吃焦点）：本文件 515-517 UpdateEntitiesUnderMouse
--     + 263-265 GetAllEntitiesUnderMouse 是「透明 Image 也能吃到鼠标事件」
--     的物理基础——它只按屏幕点做实体拾取，**不关心贴图是否可见**。
--   · G4（屏幕栈状态残留）：本文件 970/1096 的 TheInputProxy:FlushInput()
--     是唯一的「跨屏幕清输入」动作，且只调了两次（PushScreen/PopScreen）。
--     ⚠ InsertScreenUnderTop（frontend.lua:959-965）**没有**FlushInput。
--
-- ★★ 关于「鼠标命中」的两套系统（模组常混）：
--   ① 实体拾取：519-571 OnUpdate 每帧算 entitiesundermouse（3D 世界实体
--      + UI 实体混在一起），559-569 派发 mouseover / mouseout 事件。
--      ★ 由CanMouseThrough（526-557）决定能否「穿透」到下一个实体。
--   ② 屏幕栈事件：179-184 OnMouseButton → frontend.lua:1282 →
--      screen:OnMouseButton → widget.lua:56。
--   ⇒ 一��鼠标点击会**同时**触发这两条路径。UI 控件必须
--     SetClickable(false)（widget.lua:526）才能从路径①里摘掉自己。
--     ★ 这解释了 frontend.lua 里所有浮层都显式 SetClickable(false)
--     （84、94、106、118、128、132、142、146 行）——否则它们会吃点击。
--
-- ★★ 关于 TheInput 全局（740 行）：
--   `TheInput = Input()` 在**文件末尾**创建，而不是文件开头。
--   原因：Class 构造与若干函数体只需要在**调用时**存在，
--   而 4-6 行的原注释说明了真正的原因——历史遗留。
--     "--V2C: WELL! this should've been local... =("
--     "--     TheInput is the correct global to reference"
--     "--     At this point, gotta leave it in case MODs are using the wrong one =/"
--   ★ 即：因为模组历史上错误地引用了全局 `Input`（而不是 TheInput），
--     官方不敢把它改成 local。**这是「破坏性重构」在长生命周期项目里
--     成本的一个真实样本**——一个 7 字符的改动被一个笔误永久锁死。
--
-- 关键符号：Input（类）, onkey, onkeyup, onkeydown, onmousebutton,
--   position, oncontrol, ontextinput, ongesture,
--   AddKeyHandler, AddKeyUpHandler, AddKeyDownHandler,
--   AddMouseButtonHandler, AddMoveHandler, AddControlHandler,
--   AddGeneralControlHandler, AddControlMappingHandler, AddGestureHandler,
--   AddTextInputHandler, OnControl, OnRawKey, OnText, OnGesture,
--   OnMouseButton, OnMouseMove, OnPosition, OnFrameStart, OnUpdate,
--   IsControlPressed, GetAnalogControlValue, ResolveVirtualControls,
--   GetActiveControlScheme, SupportsControllerFreeAiming,
--   SupportsControllerFreeCamera, ControllerAttached, ControllerConnected,
--   GetControllerID, CacheController, ClearCachedController, TryRecacheController,
--   EnableAllControllers, DisableAllControllers, EnableMouse,
--   UpdateEntitiesUnderMouse, GetAllEntitiesUnderMouse,
--   GetWorldEntityUnderMouse, GetHUDEntityUnderMouse,
--   GetScreenPosition, GetWorldPosition, GetWorldXZWithHeight,
--   GetLocalizedControl, GetLocalizedVirtualControl, IsControlMapped,
--   ControlsHaveSameMapping, GetControlIsMouseWheel, GetInputDevices,
--   OpenVirtualKeyboard, AbortVirtualKeyboard, OnFloatingTextInputDismissed
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 frontend.lua:419-450 OnControl —— 仲裁的UI 侧实现（G3 补丁）
--   ★★ 参见 frontend.lua:220-221 —— FrontEnd 构造时注册的两个全局处理器
--   ★★ 参见 components/playercontroller.lua:3132-3137 —— G3 的轮询侧
--   ★★ 参见 components/playercontroller.lua:511 IsControlPressed —— handler 分叉
--   ★★ 参见 widgets/button.lua:56-93 OnControl —— 为什么消费发生在抬起帧
--   ★★ 参见 widgets/widget.lua:124-138 —— CONTROL_SCROLL 的滚动列表回退
--   参见 widgets/controls.lua —— 实际把物理键绑到 CONTROL_* 的界面
--   参见 screens/controlsscreen_ps4.lua / controlsscreen.lua —— 绑定界面
--   参见 constants.lua:109-250 —— CONTROL_* / VIRTUAL_CONTROL_* 全部枚举
--   参见 constants.lua:246 VIRTUAL_CONTROL_START = 10000 —— 虚拟层分界
--   参见 constants.lua:227 CONTROL_CAM_AND_INV_MODIFIER —— R 摇杆修饰键
--   参见 strings.lua STRINGS.UI.CONTROLSSCREEN.INPUTS —— 本地化查表
--   参见 inputproxy（C++ 侧）TheInputProxy —— 所有 GetDigitalControl 的落点
--   参见 frontend.lua:970 / 1096 —— FlushInput 的两个调用点
--   参见 prefabs —— CanMouseThrough 事件的响应方（实体侧的鼠标穿透）
--   参见 events.lua:13 EventProcessor —— 本文件全部事件的底层容器
--============================================================
-- ================================================================
-- ★★★ 【input.lua 段 1/6】1-4：引入与全局说明
--
-- ★★ 4-6 行的原注释是全文件最有价值的「历史证词」：
--   "--V2C: WELL! this should've been local... =("
--   "--     TheInput is the correct global to reference"
--   "--     At this point, gotta leave it in case MODs are using the wrong one =/"
-- 【逐句解读】
--  ① "should've been local" —— 作者认为 Input 类不该是全局。
--     它应该是一个局部变量，通过 TheInput 访问。
--  ② "TheInput is the correct global" —— 正确的全局是 TheInput（740 行）。
--  ③ "gotta leave it in case MODs are using the wrong one" ——
--     ★★ 不敢改，因为模组历史上错误地引用了全局 Input。
-- 【★★ 这段注释的架构价值】
--   一个 7 字符的改动（Input = 变成 local Input =）被一个历史笔误
--   永久锁死。因为把全局改成局部是破坏性重构：
--   所有引用 Input 的模组会在运行时得到 nil。
--   ⇒ 通用教训：长生命周期项目的破坏性重构成本远高于直觉。
--     这也是本项目所有注释版一律坚持「只加注释不改代码」的原因。
-- 【★ 4-6 与 740 行的呼应】
--   740 行 TheInput = Input() —— 唯一的实例化点。
--   ⇒ 全局有两个：Input（类+实例，历史遗留）与 TheInput（正确别名）。
-- ================================================================
require "events"
-- ★ require events（1 行）提供 EventProcessor 类型（events.lua:13）。
-- ★ require widgets/text（2 行）—— grep 核实：本文件只出现于第 2 行，
--   无其它引用。⇒ 未使用的引入（历史遗留）。⚠ 轻微残留依赖，无功能影响。
-- ★★ 它并非完全无用：214-231 OpenVirtualKeyboard 接收 text_widget，
--   而 text_widget 是 Text 实例（由调用方传入），本文件不需要类型本身。
local Text = require "widgets/text"

--V2C: WELL! this should've been local... =(
--     TheInput is the correct global to reference
--     At this point, gotta leave it in case MODs are using the wrong one =/

-- ================================================================
-- ★★★ 【Input 构造函数】8-28 —— 九个事件容器 + 五个状态字段
--
-- 【★★ 九个 EventProcessor 的分类（全部来自 events.lua:13）】
--  物理层（不语义化）
--    9   self.onkey         —— 所有按键，带 key/down 参数
--    10  self.onkeyup       —— 按键抬起，无参数（按 key 名索引）
--    11  self.onkeydown     —— 按键按下，无参数（按 key 名索引）
--    12  self.onmousebutton —— 鼠标按钮
--  动作层（CONTROL_*）
--    15  self.oncontrol     —— 控制码
--  状态层（位置/文本/手势）
--    14  self.position      —— 鼠标位置
--    16  self.ontextinput   —— 文本输入
--    17  self.ongesture     —— 手势（主机平台）
--
-- ★★ onkey / onkeyup / onkeydown 三者的分工：
--   · onkey 带参数 → 回调签名 (key, down)，用于「所有键统一处理」
--   · onkeyup/onkeydown 无参数 → 回调签名 ()，用于「绑一个具体键」
--   ⇒ 前者「一个处理器管所有键」，后者「每个键一个处理器」。
--   ★ 例子：frontend.lua:220 AddKeyHandler → onkey（要 down）。
--     某个界面绑「按 ESC」则用 AddKeyUpHandler(KEY_ESC, fn)。
--   ⇒ ★ EventProcessor 支持两种派发风格：HandleEvent(key, ...) 具名，
--     HandleEvent(event, ...) 通用。见 119-153 的十个注册器。
-- ===============================================================
Input = Class(function(self)
-- ★★★ self.onkey —— 「所有按键」的统一处理器。
-- 【唯一消费者】frontend.lua:220 AddKeyHandler → 1193 OnRawKey。
-- ★★ 这是 UI 的**第二条按键通路**（第一条是 CONTROL_*）：
--   · onkey     → 物理键码 KEY_*，不经过键位绑定
--   · oncontrol → 语义码 CONTROL_*，经过键位绑定
--   ⇒ 文本框必须用前者（打字要知道具体字母），按钮必须用后者。
--   ★ 这两条通路并行存在，是输入架构的关键分层。
    self.onkey = EventProcessor()     -- all keys, down and up, with key param
    self.onkeyup = EventProcessor()   -- specific key up, no parameters
    self.onkeydown = EventProcessor() -- specific key down, no parameters
    self.onmousebutton = EventProcessor()

-- ★ self.position —— 鼠标位置事件。
-- 【唯一消费者】widgets/widget.lua:536 AddMoveHandler（FollowMouse）。
-- ★★ 注意：它在 155-159 UpdatePosition 里派发，而 UpdatePosition 的
--   唯一调用者是 746-748 的全局 OnPosition（C++ 调用）。
--   ⇒ 与 TheFrontEnd:OnMouseMove（173）是两条不同的通路：
--     · self.position → 「跟随鼠标」的控件（FollowMouse）
--     · TheFrontEnd:OnMouseMove → tracking_mouse 的维护
-- ⚠ 说明框架并未统一鼠标移动的派发。标注为「架构分裂」。
    self.position = EventProcessor()
    self.oncontrol = EventProcessor()
    self.ontextinput = EventProcessor()
    self.ongesture = EventProcessor()

-- ================================================================
-- 【★ 五个运行时状态字段】19-25
--  19  self.hoverinst           —— 鼠标下的实体（每帧更新）
--  20  self.enabledebugtoggle   —— 是否允许用调试键切后端
--  22  self.mouse_enabled       —— ★ 鼠标是否可用（主机为 false）
--  24  self.overridepos         —— 鼠标位置覆盖（分屏/锁定用）
--  25  self.controllerid_cached —— ★ 控制器 ID 缓存
-- ★★ mouse_enabled 的判定（22 行）是全文件最重要的分支之一：
--   IsNotConsole() and not TheNet:IsDedicated()
--   ⇒ 主机（Xbox/PS/Switch）上鼠标不可用；专用服务器上也不可用。
-- ★ 后果链：164-165 的「主键豁免」、520 的 OnUpdate 全跳过、
--   264/285 的 GetAllEntitiesUnderMouse 返回空表。
-- ===============================================================
    self.hoverinst = nil
    self.enabledebugtoggle = true

-- ★★ mouse_enabled —— 「鼠标是否启用」。
-- 【六个消费点（★ 全都是「短路整个鼠标系统」级别）】
--  156  UpdatePosition —— 不派发移动事件（FollowMouse 失效）
--  164  OnControl —— ★★ 主键 CONTROL_PRIMARY/SECONDARY 被整个丢弃
--  174  OnMouseMove —— 不通知前端
--  180  OnMouseButton —— 不派发
--  264  GetAllEntitiesUnderMouse —— 返回空表
--  520  OnUpdate —— ★ 不做实体拾取、不派发 mouseover/mouseout
-- ⚠⚠ 164-165 的后果见该行详细分析。
    self.mouse_enabled = IsNotConsole() and not TheNet:IsDedicated()

-- ⚠ overridepos —— ★ 本文件只初始化为 nil，从不被赋值/读取。
--   grep 核实：24 行是唯一出现点。
--   ⇒ 死字段，疑为已移除的「锁定鼠标位置」功能残留。
    self.overridepos = nil
    self.controllerid_cached = nil

-- ★ 构造末尾调 DisableAllControllers —— ★★ 默认关闭所有手柄。
-- 【为什么？】30-36 的循环从 i=1 开始（跳过 0），
--   0 号设备是键鼠，1+ 才是手柄。
--   ⇒ 启动时禁用所有手柄，玩家需在设置里手动启用。
-- ★ 这解释了 90-96 ControllerAttached 的缓存机制：
--   「有手柄插着」≠「手柄被启用」。
    self:DisableAllControllers()
end)

-- ★★★ DisableAllControllers —— 关闭除 0 号外的所有输入设备。
-- 【★ 关键：for i = 1, N-1 —— 从 1 开始，跳过设备 0】
--   0 号设备 = 键鼠（TheInputProxy 的约定）。
-- ★★ 双重条件（32 行）—— 只有「已启用且已连接」才关闭：
--   → 已连接但未启用的（玩家主动禁用过）保持禁用
--   ⚠ 但玩家上次**启用过**的手柄会被再次禁用。
--   ⇒ 与「记住玩家设置」的意图相反，标注为轻度疑似缺陷。
-- ★ 38 行 EnableAllControllers 是对称的反操作。
function Input:DisableAllControllers()
    for i = 1, TheInputProxy:GetInputDeviceCount() - 1 do
        if TheInputProxy:IsInputDeviceEnabled(i) and TheInputProxy:IsInputDeviceConnected(i) then
            TheInputProxy:EnableInputDevice(i, false)
        end
    end
end

-- EnableAllControllers —— 30 行的镜像（无条件启用已连接的）。
-- ★ 与 30 行不同：这里不检查是否已启用，直接启用。
--   ⇒ 「全开」的语义，对称。
function Input:EnableAllControllers()
    for i = 1, TheInputProxy:GetInputDeviceCount() - 1 do
        if TheInputProxy:IsInputDeviceConnected(i) then
            TheInputProxy:EnableInputDevice(i, true)
        end
    end
end

-- ================================================================
-- 【主机平台的一组「空实现」】46-67
--  46 IsControllerLoggedIn  —— 仅 XB1 真实实现
--  53 LogUserAsync          —— 仅 XB1 真实实现
--  61 LogSecondaryUserAsync —— 仅 XB1 真实实现
-- 【★ 统一模式：if IsXB1() then ... else cb(true) end】
--   ⇒ 非 Xbox One 平台上全部走「假装成功」的分支。
-- ★★★ 这是「平台差异在运行时分支」而非条件编译的典型代价：
--   这些函数在 PC 上是纯粹的空壳，但签名仍须与 XB1 版本一致。
-- ⚠ 三个函数 grep 核实全库无调用点 ⇒ 疑似死代码。
--   可能是早期 XB1 独占期的遗留。
-- ===============================================================
function Input:IsControllerLoggedIn(controller)
    if IsXB1() then
        return TheInputProxy:IsControllerLoggedIn(controller)
    end
    return true
end

-- ★ LogUserAsync —— 「异步登录手柄用户」。仅 XB1 有意义。
-- ⚠ grep 核实：全库无调用点。⇒ 疑似死代码。
function Input:LogUserAsync(controller,cb)
    if IsXB1() then
        TheInputProxy:LogUserAsync(controller,cb)
    else
        cb(true)
    end
end

function Input:LogSecondaryUserAsync(controller,cb)
    if IsXB1() then
        TheInputProxy:LogSecondaryUserAsync(controller,cb)
    else
        cb(true)
    end
end

-- ★ EnableMouse(enable) —— 运行期开关鼠标。
-- ★★ 70 行重复了 22 行的判定：
--   enable and IsNotConsole() and not IsDedicated
--   ⇒ ★ 即使传 enable=true，在主机/专用服务器上 mouse_enabled 仍是 false。
--   ⇒ 语义不是「打开鼠标」而是「请求打开鼠标」。
-- ⚠ 若调用方以为「传 true 就一定开了」会误判。语义不直白，非缺陷。
function Input:EnableMouse(enable)
    self.mouse_enabled = enable and IsNotConsole() and not TheNet:IsDedicated()
end

-- ================================================================
-- ★★★ 【控制器 ID 缓存与判定】73-96 —— 一个精致的小设计
--  73 ClearCachedController() —— 清缓存
--  77 CacheController()        —— 读缓存并写入
--  82 TryRecacheController()  —— ★ 检测「设备是否切换了」
--  86 GetControllerID()       —— 读 ID（缓存优先）
--  90 ControllerAttached()    —— 「玩家在用手柄吗」
-- 【★★ 为什么要缓存？】
--   GetControllerID / ControllerAttached 会被每帧调用
--   （frontend.lua:719 以及 817-850 的连发逻辑）。
--   TheInputProxy:GetLastActiveControllerIndex() 是跨语言调用（C++），
--   ★ 跨语言调用有固定开销（userdata 装箱/拆箱）。
--   ⇒ 每帧多次调用不可接受 ⇒ 缓存。
-- 【★★ CacheController 的两个细节】
--   78 行 IsNotConsole() and (X or 0) or nil
--   ⇒ PC 上：有手柄活动 → 缓存其 ID；无手柄 → 缓存 0。
--   ⇒ 主机上：缓存 nil（永不下探 C++）。
-- ★★ 为什么要区分 PC / 主机？
--     因为主机上「控制器」是系统级的、永远存在，
--     而 PC 上手柄可能插拔。缓存 0 表示「PC 上当前无手柄活动」。
--   ★ 90-92 的读法：controllerid_cached > 0 才算「接了手柄」。
--     ⇒ PC 无手柄时缓存 0 → 0 > 0 为假 → 继续问 IsAnyControllerActive。
--   ⇒★★ 这是「用缓存值 0 表达『已知答案：无』」的编码技巧。
-- ===============================================================
function Input:ClearCachedController()
    self.controllerid_cached = nil
end

-- ★★ CacheController 的双与或链：IsNotConsole() and (X or 0) or nil
-- ★★ or 0 与 or nil 的双层兜底：
--   · PC：C++ 返回 nil（无活动设备）→ or 0 → 缓存 0
--   · 主机：IsNotConsole() 为假 → 整个 and 表达式为 false → or nil
-- ⇒ ★ 这是「利用 and/or 的三值性表达平台分支」的技巧。
-- ⚠ 可读性极差；若 IsNotConsole() 返回 nil 而非 false，行为会不同。
function Input:CacheController()
    self.controllerid_cached = IsNotConsole() and (TheInputProxy:GetLastActiveControllerIndex() or 0) or nil
    return self.controllerid_cached
end

-- ★★ TryRecacheController —— 「设备切换了吗」。
--   cached ~= nil and cached ~= self:CacheController()
--   ⇒ ★★ 副作用：它会**更新缓存**（调了 CacheController）。
--     所以它是「检查并刷新」，不是纯查询。命名略有误导。
-- ★ 消费者：grep 核实 → 用于「切设备时重建 UI/重绑按键」的场景。
function Input:TryRecacheController()
    return self.controllerid_cached ~= nil and self.controllerid_cached ~= self:CacheController()
end

-- ★★ GetControllerID —— 缓存优先。
--   self.controllerid_cached or TheInputProxy:GetLastActiveControllerIndex() or 0
-- ⚠ 主机上缓存恒为 nil ⇒ 每次调用都跨语言。
--   与「缓存是为了省开销」的初衷矛盾。
--   ⚠ 但主机 CPU 相对宽裕，且调用频率可能不高。
--   ⇒ 标注为「缓存在主机平台失效」，轻度问题。
function Input:GetControllerID()
    return self.controllerid_cached or TheInputProxy:GetLastActiveControllerIndex() or 0
end

-- ★★ ControllerAttached —— 「玩家在用手柄吗」。【★ 键盘/手柄分叉总开关】
-- 【两条路径】
--  91-93 有缓存 → cached > 0（PC 路径）
--  95    无缓存 → IsConsole() or TheInputProxy:IsAnyControllerActive()
-- ★★ 94 行原注释 "--Active means connected AND enabled" ——
--   「活动」= 已连接且已启用。⇒ 呼应 30 行的默认全禁用。
-- ★ 95 行的 IsConsole() or ...：主机上恒真（用手柄是必然的）。
-- ★★ 消费者：frontend.lua:719 local controller = TheInput:ControllerAttached()
--   用于决定「用哪套导航键」（817-820/838-850 的 not controller 分支）。
--   ⇒ ★ 这是「键鼠玩家 vs 手柄玩家」体验分叉的总开关。
function Input:ControllerAttached()
    if self.controllerid_cached ~= nil then
        return self.controllerid_cached > 0
    end
    --Active means connected AND enabled
    return IsConsole() or TheInputProxy:IsAnyControllerActive()
end

-- ★★ ControllerConnected —— 「插了手柄吗」（不管启用与否）。
-- ★ 99 行原注释 "--V2C: didn't cache this one because it's not used regularly"
--   ⇒ ★ 与 90 的对照：ControllerAttached 缓存，ControllerConnected 不缓存。
--     理由明确写了：「用得不频繁」。
-- ⇒ 这是一个有意识的性能分级：热路径缓存，冷路径直查。
-- ★★ 这种「注释解释为什么不做某个优化」的习惯值得学习。
function Input:ControllerConnected()
    --V2C: didn't cache this one because it's not used regularly
    return IsConsole() or TheInputProxy:IsAnyControllerConnected()
end

-- ★ GetInputDevices —— 列出已连接设备（给设置界面用）。
-- ★★ 109 行 STRINGS.UI.CONTROLSSCREEN.INPUT_NAMES[device_type + 1]
--   ⇒ ★ device_type 是从 0 开始的枚举，而 Lua 数组从 1 开始，
--     所以要 +1。典型的「C++ 0-based / Lua 1-based」转换。
-- ⚠ 若 device_type 越界（表只有 9 项而 device_type 是 9），会得 nil。
--   109 行没有兜底。轻微风险。
-- Get a list of connected input devices and their ids
function Input:GetInputDevices()
    local devices = {}
    for i = 0, TheInputProxy:GetInputDeviceCount() - 1 do
        if TheInputProxy:IsInputDeviceConnected(i) then
            local device_type = TheInputProxy:GetInputDeviceType(i)
            table.insert(devices, { text = STRINGS.UI.CONTROLSSCREEN.INPUT_NAMES[device_type + 1], data = i })
        end
    end
    return devices
end

-- ================================================================
-- ★★★ 【十三个注册器】115-153 —— 全部是 EventProcessor 的薄封装
-- 【★★ 关键：EventProcessor 支持两种派发命名空间】
--  具名派发：HandleEvent(name, ...) 只触发 AddEventHandler(name, fn)
--  通用派发：HandleEvent(ALL, ...) 触发该处理器下的所有 fn
-- 【十个注册器与它们的命名空间】
--  116  ontextinput    "text"（具名）
--  120  onkeyup         key（具名）
--  124  onkeydown       key（具名）
--  128  onkey           "onkey"（所有键，带参数）
--  132  onmousebutton   "onmousebutton"
--  136  position        "move"
--  140  oncontrol       control（具名）
--  144  oncontrol       "oncontrol"（全部）
--  148  oncontrol       "onmap"（映射变更）
--  152  ongesture       gesture（具名）
-- 【★★ oncontrol 有三个不同命名空间 —— 最需要小心的地方】
--   140  AddControlHandler(control, fn)  → 某个具体控制码
--   144  AddGeneralControlHandler(fn)   → 所有控制码（fn 带 control 参数）
--   148  AddControlMappingHandler(fn)  → 键位映射变更事件（设置界面用）
-- ★★ 167-169 的派发顺序保证了「具名先于通用」：
--   167  self.oncontrol:HandleEvent(control, digitalvalue, analogvalue)
--   168  self.oncontrol:HandleEvent("oncontrol", control, digitalvalue, analogvalue)
--   ⇒ ★★ 若同一控制码既被具名注册又被通用注册，具名先跑，
--     且两者都会跑（没有互斥）—— 与「消费后短路」的直觉相反！
--   ⇒ ⇒ ★ 输入分发是「广播」而非「消费链」。
--   ⇒ UI 与游戏层的仲裁在 166 行（FrontEnd:OnControl）做，
--     而不是靠 EventProcessor 的短路。★ 这是重要区别。
-- ===============================================================
function Input:AddTextInputHandler(fn)
    return self.ontextinput:AddEventHandler("text", fn)
end

function Input:AddKeyUpHandler(key, fn)
    return self.onkeyup:AddEventHandler(key, fn)
end

function Input:AddKeyDownHandler(key, fn)
    return self.onkeydown:AddEventHandler(key, fn)
end

function Input:AddKeyHandler(fn)
    return self.onkey:AddEventHandler("onkey", fn)
end

function Input:AddMouseButtonHandler(fn)
    return self.onmousebutton:AddEventHandler("onmousebutton", fn)
end

function Input:AddMoveHandler(fn)
    return self.position:AddEventHandler("move", fn)
end

-- ★★ AddControlHandler —— 注册某个控制码的处理器。
-- ★ 玩家控制器用它：playercontroller.lua 大量 AddControlHandler(CONTROL_*)。
-- ★★ 注意这里没有「消费」概念：返回 handler 对象，供将来 Remove 用。
function Input:AddControlHandler(control, fn)
    return self.oncontrol:AddEventHandler(control, fn)
end

-- ★★ AddGeneralControlHandler —— 监听所有控制码。
-- ★★ 这是「游戏层」的入口：playercontroller 就是用它接一切的。
-- ★★ 与 139 的区别在回调签名：
--   AddControlHandler       → fn(digitalvalue, analogvalue)
--   AddGeneralControlHandler → fn(control, digitalvalue, analogvalue)
-- ⇒ 通用版多一个 control 参数（168 行多传了一个）。
function Input:AddGeneralControlHandler(fn)
    return self.oncontrol:AddEventHandler("oncontrol", fn)
end

-- ★ AddControlMappingHandler —— 监听「键位被改了」。
-- ★ 唯一派发点：237-239 OnControlMapped（776-778 全局函数，C++ 调用）。
-- ★ 消费者：widgets/controls.lua（按键设置界面）。
-- ★★ 与控制码事件完全分离：一个是「按键触发」，一个是「映射变更」。
function Input:AddControlMappingHandler(fn)
    return self.oncontrol:AddEventHandler("onmap", fn)
end

function Input:AddGestureHandler(gesture, fn)
    return self.ongesture:AddEventHandler(gesture, fn)
end

-- ★★ UpdatePosition —— 派发鼠标位置给 FollowMouse 类控件。
-- ★ 156 行 if self.mouse_enabled —— 主机上不派发。
-- ★★ 与 173 OnMouseMove 的分工：
--   UpdatePosition → 「我要知道鼠标在哪」（FollowMouse 的控件）
--   OnMouseMove    → 「我要维护 tracking_mouse 状态」（前端）
-- ★ 唯一消费者：widgets/widget.lua:536 的 AddMoveHandler。
function Input:UpdatePosition(x, y)
    if self.mouse_enabled then
        self.position:HandleEvent("move", x, y)
    end
end

-- ★★ 原注释 "-- Is for all the button devices (mouse, joystick (even the
--   analog parts), keyboard as well, keyboard" ——
--   说明 CONTROL_* 是设备无关的：鼠标、手柄（含摇杆模拟量）、
--   键盘全都映射到同一套控制码。这是「统一抽象」的核心。
-- Is for all the button devices (mouse, joystick (even the analog parts), keyboard as well, keyboard
-- 【ValidateLineNumber(162)】哨兵框住 OnControl 的定义处（163）。
-- ★ 与 171 配对 —— 这两个哨兵框住的正是「全游戏最重要的仲裁点」。
--   哨兵的存在说明这里被改动过多次（G3 补丁、平台适配……）。
ValidateLineNumber(162)
-- ================================================================
-- ★★★★★ 【Input:OnControl】—— 缺陷 G3 的环节一
--          也是整个输入系统最重要的一行
-- ================================================================
--
-- 【签名】OnControl(control, digitalvalue, analogvalue)
--   control       —— 抽象控制码 CONTROL_*（constants.lua:109-250）
--   digitalvalue  —— 布尔：按下/抬起
--   analogvalue   —— 浮点：模拟量（摇杆推力），范围 0..1
--
-- 【★ 完整逻辑（164-169）】
--   if (鼠标可用 or 不是主键/次键)            ← ★ 前置豁免
--      and not TheFrontEnd:OnControl(...)    ← ★ UI 仲裁
--   then
--       广播给该控制码的具名处理器            ← 167
--       广播给所有通用处理器                  ← 168
--   end
--
-- ★★★ 【为什么这个位置是正确的仲裁点】
--   bug-patterns.md G3 给出的「正确做法」原文：
--     Input::OnControl(control, down):
--         if UI.consume(control, down):      -- UI 消费并记录已被吞掉
--             mark_input_swallowed(control)  -- 标记，游戏层查询
--             return
--         gameplay.handle(control, down)
--   ⇒ ★★ 本文件正是这个结构（少了 mark_input_swallowed 那一步）。
--   ⇒ 仲裁发生在广播之前：UI 说「不」，游戏层就完全收不到。
--   ⇒ ★ 这是 DST 输入设计做对了的部分。
--
-- ⚠⚠⚠ 但它缺少 swallowed 标记，这正是 G3 的根因。
--   详见 164-165 与 167 行的完整分析。
function Input:OnControl(control, digitalvalue, analogvalue)
-- ⚠⚠⚠ 【★ 缺陷 G3 环节一的精确位置：164-165】
--
-- 条件一：(self.mouse_enabled or (control ~= CONTROL_PRIMARY and
--                            control ~= CONTROL_SECONDARY))
--
-- 【★ 逐字重读（这是全文件最容易被误读的一行）】
--   if (A) and not TheFrontEnd:OnControl(...) then 广播 end
--   其中 A = mouse_enabled or (不是主键 and 不是次键)
--
-- ★★★ 三种情况：
--   【一】mouse_enabled=true（PC）
--        A 恒为真 ⇒ 总是问 UI，仲裁生效。
--   【二】mouse_enabled=false（主机/专服）+ 主键/次键
--        A 为假 ⇒ 整个 if 短路；
--        ★★ 既不问 UI，也不广播 → 输入被完全丢弃。
--   【三】mouse_enabled=false + 其它控制码
--        A 为真 ⇒ 正常仲裁。
--
-- ⚠⚠ 【★ 纠正一个常见误解】
--   ★ 本行的豁免**不是**「让主键绕过 UI 直达游戏层」，
--     而是「让主键被整个丢弃」—— 因为 not TheFrontEnd:... 是
--     and 的第二个操作数，A 为假时它根本不求值。
--   ⇒ 「绕过 UI 但进游戏层」是不成立的解读。
--   ⇒ ★★ 主机上 CONTROL_PRIMARY / CONTROL_SECONDARY 被静默吞掉。
--
-- 【★ 为什么这在实践中不出问题？】
--   推理依据：22 行 mouse_enabled = IsNotConsole() and ...。
--   ⇒ 主机上没有鼠标，CONTROL_PRIMARY（鼠标左键）与
--     CONTROL_SECONDARY（右键）这两个控制码根本不会被触发。
--   ⇒ 这个豁免是「防御性的死分支」，永不命中。
-- ★★ 但它是一枚地雷：若某平台/模组让主机上产生了
--     CONTROL_PRIMARY（例：把某个手柄键绑到它），
--     该输入会被无声丢弃，无日志、无报错。
--   ⇒⇒ 标注为 ⚠ 疑似缺陷（无日志的静默丢弃分支），不改代码。
--   ⇒ 正面意义：本行证明作者意图就是「主机上不处理鼠标键」，
--     写法是「丢弃」而非「直通」，意图正确，只是无诊断。
-- ================================================================
    if (self.mouse_enabled or
        (control ~= CONTROL_PRIMARY and control ~= CONTROL_SECONDARY)) and
-- ★★★ not TheFrontEnd:OnControl(control, digitalvalue) —— 仲裁调用。
-- 【★ 这是 UI 唯一被询问「你要不要这个输入」的地方】
-- 【返回值语义】
--   true    → UI 吃掉 → 整个 if 为假 → 不广播（输入消失）
--   false/nil → UI 不吃 → if 为真 → 广播给游戏层
-- ★★ 注意只传了 control 与 digitalvalue，**没传 analogvalue**！
--   ⚠ ⇒ UI 侧看不到模拟量。frontend.lua:703 却用
--     Input:GetAnalogControlValue(control) 自己去问 ——
--     绕过了这个调用。所以 analogvalue 在 UI 路径上是无用参数。
--   ⇒ 轻微不一致，无功能影响（因为 UI 自己能查）。
-- ★★ 与 OnMouseButton（181）的对比：
--   181 行 TheFrontEnd:OnMouseButton(...) 的返回值被丢弃，
--      182 行无条件广播。
--   ⇒ ⚠⚠ 输入仲裁在鼠标路径上完全缺失。
--   ⇒ 后果：UI 吃掉鼠标点击后，游戏层的 onmousebutton 仍会收到。
--     实践影响：游戏逻辑不走 onmousebutton（走 CONTROL_*），
--     所以未暴露。但这是明确的架构不对称。
--     详见 179-184 的完整分析。
        not TheFrontEnd:OnControl(control, digitalvalue) then
-- ★★ 第一步广播：具名处理器（AddControlHandler 注册的）。
-- ★★ 168 行第二步广播：通用处理器（AddGeneralControlHandler）。
-- ⇒ ★★ 两者都会执行（不是短路）。
--   ⇒ 「具名 + 通用」可以同时监听同一个控制码。
-- ⇒ 「广播」而非「消费链」—— 与 UI 的短路分发形成对比。
-- ★★ 为什么 UI 用短路、游戏层用广播？
--   UI：同一输入可能被多个控件竞争（焦点链决定唯一赢家）→ 需要短路；
--   游戏层：一个按键可能同时影响多个系统（移动/攻击/交互）→ 需要广播。
--   ⇒ ★★ 两种分发策略对应两种所有权模型，各自正确。
-- ⚠⚠ 但正因为是广播，本函数没有能力阻止游戏层看到 UI 已消费的输入：
--   它只能靠「不让广播发生」来实现 UI 优先。
--   ⇒★★ 而 G3 的本质是：按下帧 UI 没能阻止广播（见 439 的 HACK），
--     游戏层在轮询式读取里已经看到了按下状态。
--   ⇒⇒ 这就是为什么需要 mark_input_swallowed 那一步：
--     事件层能拦，轮询层拦不住。
        self.oncontrol:HandleEvent(control, digitalvalue, analogvalue)
-- ★★ 第二步广播：「oncontrol」通用命名空间。
--   ★ 多传了 control 参数（相对 167）—— 通用处理器不知道是哪个键。
-- ★★ 这是 playercontroller 的主要入口（AddGeneralControlHandler）。
        self.oncontrol:HandleEvent("oncontrol", control, digitalvalue, analogvalue)
    end
end
-- 第二个 ValidateLineNumber，框住 OnControl 结束（171 = end 行）。
ValidateLineNumber(171)

-- ★★ OnMouseMove —— 只通知前端维护 tracking_mouse。
-- ★ 不派发 self.position（那是 UpdatePosition 155 的职责）。
-- ⇒ ★★ 两条鼠标移动通路彻底分离（见 155 行分析）。
-- ★ 175 行直接调 TheFrontEnd —— 不经 EventProcessor，
--   因为前端是唯一消费者，不需要广播机制。
function Input:OnMouseMove(x, y)
    if self.mouse_enabled then
        TheFrontEnd:OnMouseMove(x, y)
    end
end

-- ================================================================
-- ★★★ 【OnMouseButton】179-184 —— ★★ 缺少仲裁的地方
--
-- 【逻辑】
--  180  if self.mouse_enabled then
--  181      TheFrontEnd:OnMouseButton(button, down, x, y)   ← ★ 返回值丢弃
--  182      self.onmousebutton:HandleEvent("onmousebutton", ...)  ← 无条件
--  183  end
--
-- ⚠⚠ 【疑似缺陷：仲裁结果缺失】
--   对比 163-169 的 OnControl：
--     if A and not TheFrontEnd:OnControl(...) then 广播 end
--     ⇒ UI 返回 true 时不广播。
--   而本函数：
--     TheFrontEnd:OnMouseButton(...)  ← ★★ 没有 not，也没有 if 判断
--     紧接着无条件 182 行广播。
--   ⇒ ★★ UI 吃掉点击后，游戏层的 onmousebutton 仍然会收到。
-- 【⚠ 为什么实际没暴露】
--   游戏逻辑不走 onmousebutton 事件 —— 所有玩法输入都走
--   CONTROL_*（见 167-168）。onmousebutton 的消费者只有调试相关。
--   ⇒ 所以这是架构层面的不对称，不是玩家可见的 bug。
-- ⚠ 但它是「同类问题不同处理」的典型：同一个文件里，
--   两条输入路径的仲裁策略不一致。
-- ⇒ 对比 frontend.lua:1289-1293 的返回值处理：
--   if screen:OnMouseButton(...) then return true end
--   —— 前端自己做了短路，但那个返回值只回到 181，
--   而 181 忽略了它 ⇒ 前端的短路白做了。
-- ⇒⇒ ★★ 完整链条的浪费：
--       前端短路 → 返回 true → input.lua:181 丢弃 → 182 仍广播。
--   ⇒⇒ 标注为 ⚠ 疑似缺陷（鼠标路径缺少输入仲裁）。不改代码。
-- ===============================================================
function Input:OnMouseButton(button, down, x, y)
    if self.mouse_enabled then
-- ⚠⚠ 缺陷核心行：★ 返回值被丢弃（详见 179 行完整分析）。
-- ★★ frontend.lua:1289 在这里做的短路，其返回值在此被扔掉。
        TheFrontEnd:OnMouseButton(button, down, x,y)
-- ★★ 无条件广播 —— 这是与 163 OnControl 的关键差异。
-- ⚠ 唯一消费者是调试/UI 侧，游戏逻辑不走这里。
        self.onmousebutton:HandleEvent("onmousebutton", button, down, x, y)
    end
end

-- ================================================================
-- ★★ 【OnRawKey】186-193 —— 物理按键的第二条通路
-- 【三步派发】
--  187  self.onkey:HandleEvent("onkey", key, down)  —— 所有键（带参数）
--  188-192 down ? onkeydown:HandleEvent(key) : onkeyup:HandleEvent(key)
-- 【★ 为什么分成三条？】
--   · "onkey" 给「一个处理器管所有键」用（frontend.lua:220）；
--   · onkeydown/onkeyup 给「绑一个具体键」用（AddKeyDownHandler(key, fn)）。
-- ★★ 具名派发（HandleEvent(key)）是关键设计：
--   每个键码是一个「事件名」，注册时按名字挂。
--   ⇒ 添加按键监听不需要新的注册 API。
-- ★★ ⚠ 注意：★ 没有 UI 仲裁。
--   ⇒ OnRawKey 无条件派发给所有处理器，包括 frontend.lua:1193。
--   ⇒ 由各监听器自行判断是否处理（文本框走 1200-1201 的
--     forceProcessText 分支）。
--   ⇒ ★ 这是「广播 + 处理器自筛」模式，与 CONTROL_* 的「仲裁+广播」不同。
--   ⇒ ★ 两条路径的哲学差异：因为按键不走 UI 点击语义，所以不需仲裁。
-- ===============================================================
function Input:OnRawKey(key, down)
    self.onkey:HandleEvent("onkey", key, down)
    if down then
        self.onkeydown:HandleEvent(key)
    else
        self.onkeyup:HandleEvent(key)
    end
end

-- ★★ OnText —— 文本输入（IME 输入法的最终字符）。
-- ★★ 唯一消费者：frontend.lua:221 AddTextInputHandler → 1208 OnTextInput。
-- ★ 与 OnRawKey 一样没有仲裁。
-- ★★ 派发时机：仅在「字符被提交」时（不是每次按键）。
--   ⇒ 所以 186 OnRawKey（每个按键）与 195 OnText（每个字符）是
--     不同粒度的事件。前者管功能键，后者管可打印字符。
function Input:OnText(text)
    self.ontextinput:HandleEvent("text", text)
end

-- ★★ 原注释 "-- Specifically for floating text input on Steam Deck" ——
--   ★ Steam Deck 的浮动键盘（触屏输入）。
-- ★★ vk_text_widget 记录「当前哪个控件占用了虚拟键盘」。
-- ★ 与 207-212 AbortVirtualKeyboard / 214-231 OpenVirtualKeyboard
--   组成完整的虚拟键盘生命周期。
-- Specifically for floating text input on Steam Deck
-- ★★ OnFloatingTextInputDismissed —— 「C++ 调用」（原注释）。
-- ★★ 与 743 全局函数 OnFloatingTextInputDismissed 成对：
--   C++ → 全局（742-744）→ TheInput:xxx（200）→ 控件回调。
-- ★★ 「方法 + 同名全局」的桥接模式，文件末尾共 9 处（742-778）。
function Input:OnFloatingTextInputDismissed()			-- called from C++
	if self.vk_text_widget then
		self.vk_text_widget:OnVirtualKeyboardClosed()
		self.vk_text_widget = nil
	end
end

function Input:AbortVirtualKeyboard(for_text_widget)
	if for_text_widget ~= nil and self.vk_text_widget == for_text_widget then
		self.vk_text_widget = nil
		TheInputProxy:CloseVirtualKeyboard()
	end
end

-- ================================================================
-- ★★ 【虚拟键盘】200-231 —— Steam Deck / 主机的屏幕键盘
--  200 OnFloatingTextInputDismissed —— 键盘被关闭
--  207 AbortVirtualKeyboard(widget)   —— 主动放弃
--  214 OpenVirtualKeyboard(text_widget) —— 打开
-- 【★ 幂等设计】
--  215  if not self.vk_text_widget then —— 只在没有键盘时开
--  208  if for_text_widget ~= nil and self.vk_text_widget == for_text_widget
--       —— 放弃时必须持有者匹配（防误关别人的键盘）
-- 【★ 坐标传递（216-217）】
--  216  text_widget.inst.UITransform:GetWorldPosition() —— ★ 世界坐标
--  217  text_widget:GetRegionSize()                      —— 尺寸
-- ⇒ 传给 C++ 让浮动键盘贴着输入框弹出。
-- ★★ 220-222 三行注释掉的实验代码（尝试从文本内容解析坐标），
--   保留作为「这条路走过」的记录。
-- ⚠ 224 行尾有一个 tab 字符（then 之后）—— 无功能影响，纯格式。
-- 【★ allow_newline（224 行第二个参数）】
--   本文件从不设置 self.allow_newline（grep 核实无写入点）。
--   ⇒ 恒为 nil → 虚拟键盘不允许换行。
--   ⇒ ⚠ 若某处需要多行输入框，这里会阻止。标注为「配置缺失」。
-- ===============================================================
function Input:OpenVirtualKeyboard(text_widget)
	if not self.vk_text_widget then
-- ★★ 用 UITransform:GetWorldPosition 拿世界坐标（与 widget.lua:336 同源）。
-- ★ 这是三套坐标问题在输入层的又一个体现。
		local x, y = text_widget.inst.UITransform:GetWorldPosition()
		local w, h = text_widget:GetRegionSize()

		--local _split = text_widget:GetString():split(",")
		--x = _split[1] ~= nil and tonumber(_split[1]) or 0
		--y = _split[2] ~= nil and tonumber(_split[2]) or 0
		--print("_split", x, y)

		if TheInputProxy:OpenVirtualKeyboard(x, y, w, h, self.allow_newline) then	
			self.vk_text_widget = text_widget
			return true
		end
	end

	return false
end

-- ★ OnGesture —— 主机平台的手势（滑动等）。
-- ★ 唯一派发点；注册器是 151 AddGestureHandler。
-- ★★ grep 核实：AddGestureHandler 全库无调用点 ⇒ 疑似死代码。
--   推测是主机平台才有意义的功能（主机键盘搜索手势）。
function Input:OnGesture(gesture)
    self.ongesture:HandleEvent(gesture)
end

-- ★★ OnControlMapped —— 「键位映射变更」的唯一派发点。
-- 【★ 与 163 OnControl 的区别】
--   · 163：某个键被按下（每帧可触发多次）
--   · 237：玩家改了绑定（设置界面，一次性）
-- ★★ 参数语义完全不同：
--   deviceId / controlId —— 哪个设备的哪个控制码
--   inputId              —— 新绑到哪个物理输入
--   hasChanged           —— 是否真的变了（可能是「相同」的确认）
-- ★ 唯一注册器：147 AddControlMappingHandler。
-- ★ 消费者：widgets/controls.lua（按键设置界面）。
function Input:OnControlMapped(deviceId, controlId, inputId, hasChanged)
    self.oncontrol:HandleEvent("onmap", deviceId, controlId, inputId, hasChanged)
end

-- ★★ OnFrameStart —— 每帧开始时清空 hover 状态。
-- 【★ 为什么是「清空」而不是「更新」？】
--   242  self.hoverinst = nil
--   243  self.hovervalid = false
--   ⇒★ 每帧重置，然后 519 OnUpdate 重新拾取并设置。
-- ★★ hovervalid 字段：grep 核实本文件无读取点 ⇒ 死字段。
-- ★★ 正确性依赖：拾取（519-571）必须在本帧的 OnFrameStart 之后跑。
--   若顺序反了（先拾取后重置），hover 永远为 nil。
--   ⚠ 这是一个隐式的时序契约，框架层没有强制。
-- ===============================================================
function Input:OnFrameStart()
    self.hoverinst = nil
    self.hovervalid = false
end

-- ================================================================
-- ★★ 【三套坐标转换】246-261 —— 输入与模拟世界的接缝
--  246 GetScreenPosition()     —— 屏幕坐标（Vector3）
--  251 GetWorldPosition()      —— ★ 3D 世界坐标（投影）
--  256 GetWorldXZWithHeight(h) —— ★ 地面上的 XZ（投影到指定高度）
-- 【★★ 这是「UI 坐标」与「模拟坐标」的唯一接缝】
--   UI 的一切（控件位置）用屏幕坐标；
--   玩法的一切（实体位置）用模拟坐标；
--   ProjectScreenPos（252/259）是 C++ 提供的反投影。
-- 【★ 为什么 UI 点击不直接用这些？】
--   因为 UI 走的是实体拾取（515-571），不需要坐标反投影。
--   ⇒ 这三个函数是给玩法用的（玩家控制器移动、瞄准）。
--   ⇒ UI 与玩法的输入是两条独立的路，只在 163 仲裁处汇合。
--   ⇒ ★ 这解释了 G3 为什么那么难修：两条路各自跑到底。
-- ===============================================================
function Input:GetScreenPosition()
    local x, y = TheSim:GetPosition()
    return Vector3(x, y, 0)
end

-- ★★ GetWorldPosition —— 屏幕坐标 → 3D 世界坐标（反投影）。
-- ★★ 253 行 x ~= nil and y ~= nil and z ~= nil and Vector3(x,y,z) or nil
--   ⇒ ★ 四重 and 链做判空：任一为 nil 则返回 nil。
--   ⇒ 防止投影失败（点在天空/超出范围）时返回垃圾值。
-- ★★ 消费者：playercontroller 的移动/瞄准（本地玩家）。
-- ⚠ 注意 252 行传的是 TheSim:GetPosition()（整个二元组）作为参数，
--   而 256-259 行的 GetWorldXZWithHeight 拆成 x, y 再传。
--   ⇒ 两种调用风格，取决于 ProjectScreenPos 的重载。
function Input:GetWorldPosition()
    local x, y, z = TheSim:ProjectScreenPos(TheSim:GetPosition())
    return x ~= nil and y ~= nil and z ~= nil and Vector3(x, y, z) or nil
end

-- ★★ GetWorldXZWithHeight —— 把鼠标投影到指定高度的水平面。
-- 【★★ 这是「地面拾取」的标准做法】
--   259  x, y, z = TheSim:ProjectScreenPos(x, y, height)
--   260  return x, z    ← ★ 只返回 X 与 Z（丢掉 y）
-- 【★ 为什么返回 XZ 而不是 XYZ】
--   地面交互只需要水平位置：把玩家移到 (x, z)，y 由地形决定。
--   ⇒ ProjectScreenPos 的第三参数 height 指定「投影到哪个高度的平面」，
--     游戏里通常传 0（世界原点高度）。
-- ★★ 返回两个值 x, z（Lua 的多返回值），不是裸三元组。
--   ⇒ 与 widget.lua:344 GetPositionXYZ 同类优化。
-- ★★ 这是「鼠标点击地面移动/攻击」的底层实现。
function Input:GetWorldXZWithHeight(height)
	local x, y = TheSim:GetPosition()
	local z
	x, y, z = TheSim:ProjectScreenPos(x, y, height)
	return x, z
end

-- ================================================================
-- ★★ 【鼠标拾取查询三函数】263-291
--  263 GetAllEntitiesUnderMouse —— 全部（不过滤）
--  267 GetWorldEntityUnderMouse —— 只要 3D 世界实体
--  284 GetHUDEntityUnderMouse   —— 只要 UI/HUD 实体
-- 【★★ 267 vs 284 的判定方式（★ 两种不同的「身份」判定）】
--  267-273（世界实体）
--    self.hoverinst.Transform ~= nil   ← ★★ 用「有没有 3D Transform」
--  285-290（HUD 实体）
--    self.hoverinst.Transform == nil   ← ★★ 用「没有 3D Transform」
-- ★★★ 两个条件互为取反 —— 实体被二分为「世界」与「HUD」两类。
-- 【★ 为什么 Transform 能作为判据？】
--   widget.lua:17 的 AddUITransform 给 UI 实体加的是 UITransform；
--   而 3D 实体（玩家/怪物）有的是 Transform（3D 变换）。
--   ⇒ 「有 Transform 而无 UITransform」= 世界实体。
-- ⚠ ⚠ 但这个判据脆弱：
--     如果某个 UI 实体同时也加了 3D Transform（3D 化的 UI，
--     如 3D 空间中的血条），会被误判为世界实体！
--   ⇒ ★ 对比 933 frontend.lua 用的判据：hover_inst.widget 存在。
--   ⇒★ 同一件事（判断「这是不是 UI」）有两种判据并存：
--       frontend.lua:933 用 widget 字段（可靠）
--       本文件 267/284 用 Transform 缺失（脆弱）
--   ⇒⇒ 标注为 ⚠ 疑似缺陷（两套判据并存且不等价）。
-- ===============================================================
function Input:GetAllEntitiesUnderMouse()
-- ★★ self.mouse_enabled and self.entitiesundermouse or 空表
--   ★ 主机上返回空表（不是 nil）⇒ 调用方无需判空。
--   ⇒ 这是「用空值代替 nil」的典型手法（同 frontend.lua:251 match_results）。
-- ★★ 与 519-521 的关系：entitiesundermouse 由 OnUpdate 每帧填。
--   若 OnUpdate 还没跑过（游戏刚启动），该字段为 nil → 返回空表，安全。
    return self.mouse_enabled and self.entitiesundermouse or {}
end

-- ★★ GetWorldEntityUnderMouse —— 「鼠标下的 3D 实体」。
-- 【★ 六重守卫（267-273）】
--  268 mouse_enabled
--  269 hoverinst ~= nil
--  270 hoverinst.entity:IsValid()
--  271 hoverinst.entity:IsVisible()
--  272 hoverinst.Transform ~= nil     ← ★ 世界 vs HUD 的判据
--  273 or self.hoverinst or nil     ← ★ 返回 hoverinst 本身（不是 entity）
-- ★★ 272 与 273 构成一个有趣的组合：
--   「先确认它是世界实体，然后返回实例」。
--   ⇒ 消费者自己 inst.entity 去取实体。
-- ★★ 270-271 的 IsValid + IsVisible 双检：
--   IsValid 防「已销毁」，IsVisible 防「隐藏但存在」。
--   ⇒ ★ 两者的区别是 G1 类问题的实体侧版本：
--     「实体对象还在但已无效」vs「实体有效但不可见」。
--   ⇒ 这个函数是防御写得最扎实的查询函数，可作为范本。
function Input:GetWorldEntityUnderMouse()
    return self.mouse_enabled and
        self.hoverinst ~= nil and
        self.hoverinst.entity:IsValid() and
        self.hoverinst.entity:IsVisible() and
        self.hoverinst.Transform ~= nil and
        self.hoverinst or nil
end

function Input:EnableDebugToggle(enable)
    self.enabledebugtoggle = enable
end

function Input:IsDebugToggleEnabled()
    return self.enabledebugtoggle
end

-- ★★ GetHUDEntityUnderMouse —— 与 267 完全对称，判据取反。
-- ★★ 289 行 self.hoverinst.Transform == nil —— 「没有 3D 变换」= HUD。
-- ★⚠ 与 frontend.lua:933 的 hover_inst.widget 判据不等价：
--   「没有 Transform」不一定「有 widget」（游离实体可能两者都没有）。
--   ⇒ 标注为 ⚠ 疑似缺陷（两套判据并存）。
function Input:GetHUDEntityUnderMouse()
    return self.mouse_enabled and
        self.hoverinst ~= nil and
        self.hoverinst.entity:IsValid() and
        self.hoverinst.entity:IsVisible() and
        self.hoverinst.Transform == nil and
        self.hoverinst or nil
end

-- ★ IsMouseDown(button) —— 直读 TheSim 的鼠标按钮状态。
-- ★★ 与 OnMouseButton（179）的关系：
--   · 179 是**事件**（按下/抬起的瞬间）
--   · 293 是**状态**（此刻是否按着）
--   ⇒ 两者都要有：「点击」用事件，「按住」用状态。
-- ⚠ 与 164 的「静默丢弃」呼应：主机上这里仍能返回真实状态，
--   即使 mouse_enabled 为 false（这里**没有**判 mouse_enabled）。
--   ⇒ ★ 不一致：156/174/180/264 都判了 mouse_enabled，唯独 293 没有。
--   ⇒ 主机上 IsMouseDown 仍返回 C++ 的原始状态。
--   ⇒ 标注为轻度不一致（多数情况下 mouse_enabled 为 false 时无消费者）。
function Input:IsMouseDown(button)
    return TheSim:GetMouseButtonState(button)
end

-- ★ IsKeyDown(key) —— 键盘按键的**状态**查询（对应 186 的事件）。
-- ★★ 这是「轮询式」读取的第二例（另一例是 479 IsControlPressed）。
-- ⚠ G3 的教训：轮询式读取**绕过了事件仲裁**。
--   ⇒ 所以 frontend.lua:483 读 KEY_CTRL 判断「Ctrl+退格」时，
--     不受任何输入仲裁影响。
--   ⇒ 那个场景里不需要仲裁（是调试快捷键），所以没问题。
--   ⇒ 但它证明了「两条路并存」这个架构事实。
function Input:IsKeyDown(key)
    return TheSim:IsKeyDown(key)
end

-- ★★ RemapTo_CONTROL_INVENTORY —— 「方向 → 物品栏方向」的重映射表。
-- 【★ 为什么需要一张表而不是直接算？】
--   301 行 VIRTUAL_CONTROL_INV_UP = 10000+0（推测）
--   302 行 VIRTUAL_CONTROL_INV_DOWN = 10000+1
--   303 行 VIRTUAL_CONTROL_INV_LEFT = 10000+2
--   304 行 VIRTUAL_CONTROL_INV_RIGHT = 10000+3
--   而 370 行做 `RemapTo_CONTROL_INVENTORY[control - VIRTUAL_CONTROL_INV_UP]`
--   ⇒ ★★★ **偏移量恰好是 0,1,2,3**！所以索引直接可用。
--   ⇒ 这是「四连方向组」的通用套路，后面 317-321 的五个 Is* 函数全用它。
-- ★★ 极简但极关键：把「连续的四元组」编码成「基址 + 索引」，
--   于是 320 行就能只做一次区间比较（>= base and <= base+3）判断归属。
-- ⇒ 五个判定函数的写法完全同构，源头就是这张表。
local RemapTo_CONTROL_INVENTORY =
{
	[0] = CONTROL_INVENTORY_UP,
	[1] = CONTROL_INVENTORY_DOWN,
	[2] = CONTROL_INVENTORY_LEFT,
	[3] = CONTROL_INVENTORY_RIGHT,
}

-- ★★ RemapTo_CONTROL_INVENTORY_ACTIONS —— 「动作组」的重映射表。
-- 【★ 与 301 的区别】
--   301 映射到 CONTROL_INVENTORY_UP/DOWN/LEFT/RIGHT（**方向**）
--   309 映射到 EXAMINE/DROP/USEONSCENE/USEONSELF（**动作**）
-- ★★ 同样四元组，同样用 `control - VIRTUAL_CONTROL_INV_ACTION_UP` 索引。
-- ★ 方向与动作分离是手柄 UI 的需求：
--   D-pad 导航 + X/A/C 面键动作，是常见的手柄 UI 布局。
local RemapTo_CONTROL_INVENTORY_ACTIONS =
{
	[0] = CONTROL_INVENTORY_EXAMINE,
	[1] = CONTROL_INVENTORY_DROP,
	[2] = CONTROL_INVENTORY_USEONSCENE,
	[3] = CONTROL_INVENTORY_USEONSELF,
}

-- ★ IsVCtrlCamera —— 「摄像机」组（缩放 / 旋转）。
-- ★★ 基址 VIRTUAL_CONTROL_CAMERA_ZOOM_IN，终点 VIRTUAL_CONTROL_CAMERA_ROTATE_RIGHT。
-- ⇒ ★★ 「终点常量」是**另一组的起点减一**的写法！
--   所以这五个组的基址**必须连续分配**，否则区间会重叠。
-- ⚠ 推理依据：IsVCtrlCamera 用 `>= ZOOM_IN and <= ROTATE_RIGHT`，
--   而 408 行做 `control - VIRTUAL_CONTROL_CAMERA_ZOOM_IN + CONTROL_PRESET_RSTICK_UP`
--   ⇒ ★★ 这要求这四个虚拟码**连续**且顺序为 缩放入/出 + 旋转左/右。
--   ⇒ constants.lua 里的 VIRTUAL_CONTROL_* 必须严格连续。
--   ⇒ ★★ 标注为「隐式契约：虚拟码必须连续分配」，
--     插入新组到中间会**静默破坏**所有区间判定。
-- 这是本文件最脆弱的架构点。
local function IsVCtrlCamera(control)	return control >= VIRTUAL_CONTROL_CAMERA_ZOOM_IN	and control <= VIRTUAL_CONTROL_CAMERA_ROTATE_RIGHT	end
local function IsVCtrlAiming(control)	return control >= VIRTUAL_CONTROL_AIM_UP			and control <= VIRTUAL_CONTROL_AIM_RIGHT			end
-- ★ IsVCtrlInvNav —— 物品栏导航组。
-- ★★ 370 行做 `RemapTo_CONTROL_INVENTORY[control - VIRTUAL_CONTROL_INV_UP]`，
--   ★★★ 硬依赖「INV_UP 的偏移是 0」。
--   若哪天在 INV_UP 前面插了一个新虚拟码，
--   ★★★ 这里的索引会**静默错位**（查到 nil 或错误的动作）。
--   ⇒ 与 317 行同源的隐式契约，且此处更脆弱（无终止常量保护）。
local function IsVCtrlInvNav(control)	return control >= VIRTUAL_CONTROL_INV_UP			and control <= VIRTUAL_CONTROL_INV_RIGHT			end
-- ★ IsVCtrlInvAct —— 物品栏动作组。
-- ★★ 372 行 `RemapTo_CONTROL_INVENTORY_ACTIONS[control - VIRTUAL_CONTROL_INV_ACTION_UP]`
--   与 319 同构。
local function IsVCtrlInvAct(control)	return control >= VIRTUAL_CONTROL_INV_ACTION_UP		and control <= VIRTUAL_CONTROL_INV_ACTION_RIGHT		end
-- ★ IsVCtrlStrafe —— 横向移动组（方案 2-7 才有）。
-- ★★ 388 行 `RemapTo_CONTROL_INVENTORY[control - VIRTUAL_CONTROL_STRAFE_UP]`
--   ★★ 注意：映射到 **CONTROL_INVENTORY** 而不是别的组。
--   ⇒ 横向移动在方案 1（经典）里复用物品栏导航的语义。
--   ⇒ 合理：手柄上「横向移动」最自然的语义就是「在物品栏里左右移动」。
local function IsVCtrlStrafe(control)	return control >= VIRTUAL_CONTROL_STRAFE_UP			and control <= VIRTUAL_CONTROL_STRAFE_RIGHT			end

-- ★★ IsCamAndInvCtrlScheme1(scheme) —— 「是不是经典方案」。
--   return scheme < 2 or scheme > 7
-- 【★★ 为什么不是 `scheme == 1`？】
--   ⇒ 因为**存在非法的 scheme 值**（例如 Profile 里被写坏了）。
--   `scheme < 2 or scheme > 7` 把「非法值」也归为「经典方案」，
--   也就是**回退到最兼容的行为**。
-- ★ 这是「防御性地处理枚举越界」的典型：宁可用老方案也不要崩。
-- ★★ 对比 323 的写法与 490 行 GetActiveControlScheme 的注释：
--   "--V2C: This check is simplified (assumes all control schemes are
--    for controllers only)."
--   ⇒ 作者承认这个检查是简化的。
-- ⇒ 标注为「用区间而非等值判断，隐含回退语义」，正面设计。
local function IsCamAndInvCtrlScheme1(scheme) return scheme < 2 or scheme > 7 end

-- ★★ IsTwinStickAiming(player, scheme) —— 「双摇杆瞄准」判定。
-- 【★ 三层判定】
--  326  player.components.playercontroller:IsTwinStickAiming()
--         ⇒ 玩家是否开启了「双摇杆瞄准」这个玩法选项
--  327-330  scheme 在 4..7 之间？
--         · 是 → return IsAOETargeting()   （范围攻击也用双摇杆）
--         · 否 → return true
--  332  否则 false
-- 【★★ 为什么要区分 scheme 4..7？】
--   ⇒ 双摇杆瞄准只有方案 4-7（新版方案）支持。
--   ⇒ 方案 1-3（经典/旧版）上双摇杆不工作。
-- 【★★ 为什么它被 ResolveVirtualControls 反复调用？】
--   ⇒ 因为「双摇杆瞄准」会**抢占**摇杆的功能：
--     玩家瞄准时，摇杆不再控制摄像机，也不再控制物品栏导航。
--   ⇒ 360-390 里出现 5 次调用，每次都可能因它而 return（放弃映射）。
--   ⇒ ★ 这就是「玩法状态影响输入解释」的证据：
--     **输入的解释不是纯函数，它依赖玩家状态与当前 UI 状态**。
--   ⇒⚠ 这也是它难以测试的原因（同输入不同结果）。
local function IsTwinStickAiming(player, scheme)
	if player.components.playercontroller and player.components.playercontroller:IsTwinStickAiming() then
		if scheme < 4 or scheme > 7 then
			return player.components.playercontroller:IsAOETargeting()
		end
		return true
	end
	return false
end

-- ★★ IsStrafing(player) —— 「横向移动中」。
--   return player.components.strafer and player.components.strafer:IsAiming()
-- ★★ 与 325 的双摇杆并列，是「抢占条件」之一。
-- ★★ 注意：它**不看 scheme**（与 325 不同）。
--   ⇒ 横向移动在所有方案里都会抢占。
--   ⇒ 365-368/385-388/403-407/421-427 里与 IsTwinStickAiming 并列使用。
local function IsStrafing(player)
	return player.components.strafer and player.components.strafer:IsAiming()
end

-- ══════════════════════════════════════════════════════════════
-- ★★★★★ 【ResolveVirtualControls】—— 虚拟控制层的解释器（339-477）
--
-- 【★ 这是全文件最长的函数（139 行），也是最难读的】
-- 【★ 但它的结构是高度规律的五段式，值得逐段拆解】
--
-- 【签名】ResolveVirtualControls(control) → 真正的 CONTROL_* 或 nil
--
-- 【★★ 三个大分支】
--  【分支0】340-349  control == nil 或 control < VIRTUAL_CONTROL_START
--            ⇒ 非虚拟码：直接返回（只有修饰键要特殊处理）
--  【★ 短路】351-357  法术轮盘打开 → 全部返回 nil
--  【分支1】359-391  方案 1（经典）：把虚拟码映射到旧 CONTROL_*
--  【分支2】395-476  方案 2-7：把虚拟码映射到 R 摇杆 / D-pad 预设
--
-- 【★★★ 返回 nil 的六种情形（汇总）】
--  ① control 本身是 nil（340）
--  ② 修饰键不匹配（346/399/417/439/448/466）
--  ③ 法术轮盘打开（356）
--  ④ 双摇杆瞄准 / 横向移动抢占（367/405/424/458/471）
--  ⑤ AOE 瞄准但方案不支持（376/452）
--  ⑥ 合成面板打开时的冲突处理（365/380/386/422/457/471）
--
-- 【★ 关键：`nil` 的语义是「这个意图当前无效」】
--   → IsControlPressed（479）返回 false
--   → GetAnalogControlValue（484）返回 0
--   ⇒ 所以调用方**不需要**区分「未按下」与「已失效」。
--   ⇒ ★ 这是「用 nil 统一表达无效」的优雅之处。
--═════════════════════════════════════════════════════════════
function Input:ResolveVirtualControls(control)
-- ★★ `if control == nil then return end` —— 空输入守卫。
-- ★ 注意是 return（无值）而不是 return nil —— 等价。
-- ⚠ 但调用方 479/484 都做了 `control ~= nil` 检查，
--   说明它们**不信任**本函数会正确处理 nil。
-- ⇒ 双重防御，无害。
	if control == nil then
		return
-- ★★★ 【分支0】control < VIRTUAL_CONTROL_START —— 「非虚拟码直通」
-- 【★ 339-349 的意义：把「物理层」和「虚拟层」分开处理】
--   · control < 10000 → 已经是真正的 CONTROL_*，直接返回
--   · control >= 10000 → 是虚拟码，要翻译
-- ⇒ ★★★ 这是整个双层抽象的**分水岭**：
--     「IsControlPressed 接受两种编号」的秘密就在这一行。
-- ★★ 好处：调用方**可以**直接传虚拟码（见 484GetAnalogControlValue），
--   框架负责翻译。调用方不需要知道自己传的是哪一层。
	elseif control < VIRTUAL_CONTROL_START then
-- ★★ CONTROL_CAM_AND_INV_MODIFIER（= 90，constants.lua:227）——
--   「摄像机+物品栏修饰键」。★ 它是**物理层**的码（90 < 10000）。
-- ★★ 343-347 的特殊处理：这个修饰键在方案 1 里**无效**。
--   return not IsCamAndInvCtrlScheme1(scheme) and control or nil
--   ⇒ 方案 1 → IsCamAndInvCtrlScheme1 为真 → not 假 → 整式为假 → or nil → nil
--   ⇒ 其它方案 → not 真 → and control → control
-- ★★ 经典的双重否定 + and/or 三值技巧，语义正确但极难读。
-- ★ 原注释 "--Modifier button is not used in control scheme 1" 说明了原因。
		if control == CONTROL_CAM_AND_INV_MODIFIER then
			--Modifier button is not used in control scheme 1
			local scheme = self:GetActiveControlScheme(CONTROL_SCHEME_CAM_AND_INV)
			return not IsCamAndInvCtrlScheme1(scheme) and control or nil
		end
		return control
	end

-- ★★ `local player = ThePlayer` —— ★ **函数依赖游戏状态**。
-- ★★ 352 行的法术轮盘检查说明：
--   「输入的解释」依赖于「玩家当前在做什么 UI」。
--   ⇒ 同理 365/379/385/411/422/457/471 都要查 player.HUD。
-- ⚠ ⇒ ★★ 这是**输入解释函数里嵌 UI 状态**的反模式：
--   本应是「UI 层」的职责被塞进了「输入层」。
--   ⇒ 后果：无法脱离游戏单独测试这个函数。
--   ⇒ 正确做法应该是 UI 层先拦截，输入层只做纯翻译。
--   ⇒★ 但这是**有意的**设计（见 353-355 的原注释）。
	local player = ThePlayer
-- ★★★ 法术轮盘（Spell Wheel）—— 一个打开后「吞掉所有方向」的面板。
-- 【★ 353-355 的原注释是理解本函数意图的关键】
--   "--Spell wheel is treated as ishudblocking in playercontroller,
--    "which allows some controls to continue working, but we do want
--    "to block all virtual directional controls instead."
-- 【★★ 逐句解读】
--  ① 法术轮盘在 playercontroller 那边是「ishudblocking」（部分阻挡），
--     所以某些控制**仍能工作**；
--  ② 但这里**要拦掉全部虚拟方向控制**。
-- ⇒ ★★ 两个层级的「阻挡策略」**故意不同**：
--     gameplay 层允许部分通过（为了不影响技能选择），
--     input 层彻底拦截（为了不让摇杆同时控制别的）。
--   ⇒ 这是「同一个 UI 在不同层用不同策略」的罕见实例，
--     值得记住：**阻挡策略是按层决定的，不是全局的**。
-- ★★ 356 行直接 return（无值）⇒ 所有虚拟码变nil ⇒ 摇杆无效。
	if player and player.HUD and player.HUD:IsSpellWheelOpen() then
		--Spell wheel is treated as "ishudblocking" in playercontroller,
		--which allows some controls to continue working, but we do want
		--to block all virtual directional controls instead.
		return
	end

-- ★★ local scheme = self:GetActiveControlScheme(CONTROL_SCHEME_CAM_AND_INV)
--   ★ 只有一个 scheme 被查询（摄像机+物品栏），说明这是**唯一需要
--     按方案解释的输入组**。其它控制码（接受/攻击）不区分方案。
-- ★★ 489-493 GetActiveControlScheme 的实现：
--   `ControllerAttached() and Profile:GetControlScheme(id) or 1`
--   ⇒ ★ 键鼠玩家**强制方案 1**（因为 ControllerAttached 为假）。
--   ⇒★ 这是「一套 scheme 表同时服务两种输入设备」的简化。
	local scheme = self:GetActiveControlScheme(CONTROL_SCHEME_CAM_AND_INV)

	--Scheme 1 is classic style, where we have no modifier button, and everyhting is remappable.
-- ══════════════════════════════════════════════════════════════
-- ★★ 【分支1：方案 1（经典）】362-391
-- 【★ 方案 1 的特征（361 行原注释）】
--   "--Scheme 1 is classic style, where we have no modifier button,
--       and everyhting is remappable."
-- 【★ 方案 1 的映射策略：把虚拟码映射回**旧的 CONTROL_INVENTORY_*】
--   ⇒ 即「虚拟层」在方案 1 下退化为「物品栏导航的语义别名」。
-- 【四组映射（363-389）】
--   363-370  导航组 → CONTROL_INVENTORY_UP/DOWN/LEFT/RIGHT
--   371-372  动作组 → EXAMINE/DROP/USEONSCENE/USEONSELF
--   373-382  瞄准组 → CONTROL_INVENTORY_*（需 AOE 且非双摇杆）
--   383-388  横移组 → CONTROL_INVENTORY_*
--   390      其它 → nil
-- ★★ 注意：四组的返回值**全都是** CONTROL_INVENTORY_*，
--   区分靠的是**下标不同**（301/309 两张表）。
--─────────────────────────────────────────────────────────────
	if IsCamAndInvCtrlScheme1(scheme) then
-- ★★ 导航组在方案 1 下的处理。
-- 【★★ 365-369 是本分支最精细的逻辑】
--   `if player and not (player.HUD and player.HUD:IsCraftingOpen()) then`
--   `    if IsTwinStickAiming(player, scheme) or IsStrafing(player) then return end
--   end
-- 【逐层解读】
--  365  「玩家不在合成面板里」时才做抢占判定
--  366  双摇杆瞄准 或 横向移动 → return（放弃映射）
-- ★★ 为什么要在「不在合成面板」时才判抢占？
--   ⇒ 因为合成面板里摇杆要控制面板，而非角色。
--   ⇒ ★ 这就是「UI 优先级高于玩法优先级」的直接编码。
-- ★★ 原注释 "--Handle CONTROL_INVENTORY priorities" 说明这是「优先级处理」。
		if IsVCtrlInvNav(control) then
			--Handle CONTROL_INVENTORY priorities
			if player and not (player.HUD and player.HUD:IsCraftingOpen()) then
				if IsTwinStickAiming(player, scheme) or IsStrafing(player) then
					return
				end
			end
			return RemapTo_CONTROL_INVENTORY[control - VIRTUAL_CONTROL_INV_UP]
-- ★ 动作组在方案 1 下**无任何前置条件**，直接映射。
-- ★★ 与导航组（363-370）的三行判定形成对比。
-- ⇒ 合理：动作键（查看/丢弃/使用）不该被双摇杆瞄准抢占，
--     因为它们是「显式操作」而非「连续方向」。
		elseif IsVCtrlInvAct(control) then
			return RemapTo_CONTROL_INVENTORY_ACTIONS[control - VIRTUAL_CONTROL_INV_ACTION_UP]
-- ★★★ 瞄准组 —— 方案 1 下的**严格限制**。
-- 【★ 374-375 的原注释】
--   "--Twin stick aiming outside of AOE targeting is only supported
--       by schemes 4 to 7"
--  375  `if not (player and player.components.playercontroller
--            and player.components.playercontroller:IsAOETargeting()) then return end`
-- 【★★ 三重守卫】
--   ① player 存在
--   ② playercontroller 组件存在
--   ③ ★ **必须开启 AOE 瞄准**
--   ⇒ 三个缺一即 return（无效）。
-- ★★★ 为什么方案 1 必须开 AOE 才能瞄准？】
--   ⇒ 因为经典方案里没有「双摇杆」的概念，
--     摇杆的「瞄准」语义只在 AOE 模式下才有意义
--     （AOE = 范围攻击，摇杆指向攻击范围）。
--   ⇒ 这是一个**玩法驱动的输入限制**：
--     「能不能用某个输入」取决于「玩家开没开某个玩法选项」。
--   ⇒★ 这是本函数「不是纯函数」的最强证据。
-- ⚠ 375 行无 player 判断时的短路顺序：player and ... and ...
--   ⇒ 逻辑正确（player 为 nil 时整个 and 链为 nil，not nil 为真 → return）。
		elseif IsVCtrlAiming(control) then
			--Twin stick aiming outside of AOE targeting is only supported by schemes 4 to 7
			if not (player and player.components.playercontroller and player.components.playercontroller:IsAOETargeting()) then
				return
			end
			--Handle CONTROL_INVENTORY priorities
-- ★★ 380 行的 `if player and player.HUD and player.HUD:IsCraftingOpen() then return end`
--   ★★ 与 365 行**完全相同**的判定，但在这里的语义是反的：
--   365 行：「**不**在合成面板才检查抢占」（359-370 是导航组）
--   380 行：「在合成面板就放弃」（瞄准组）
--   ⇒ ★★ 同一条件在两个组里得到相反处理 ——
--     导航组：合成面板**让位**给 UI；
--     瞄准组：合成面板**抢占**摇杆。
--   ⇒ 这说明两组的设计意图不同：
--     导航在合成面板里要「让出」给面板自己处理（走 369 跳过整个判定）；
--     瞄准在合成面板里要「拒绝」因为面板在用摇杆。
--   ⇒ 实际上两者都导致「合成面板打开时摇杆不控制角色」，
--     只是实现路径不同。⚠ 标注为「逻辑重复，语义等价」。
			if player and player.HUD and player.HUD:IsCraftingOpen() then
				return
			end
			return RemapTo_CONTROL_INVENTORY[control - VIRTUAL_CONTROL_AIM_UP]
-- ★ 横移组 —— 与 373 同构，但**少了 AOE 限制**。
-- ★★ 384-385 的注释 "--Handle CONTROL_INVENTORY priorities" 与 365 相同，
--   判定也相同（合成面板打开就 return）。
-- ⇒ ★ 方案 1 的四组处理里有**三组**是「合成面板检查」。
--   ⇒ 说明「合成面板优先级」是方案 1 的核心规则。
		elseif IsVCtrlStrafe(control) then
			--Handle CONTROL_INVENTORY priorities
			if player and player.HUD and player.HUD:IsCraftingOpen() then
				return
			end
			return RemapTo_CONTROL_INVENTORY[control - VIRTUAL_CONTROL_STRAFE_UP]
		end
-- ★ 兜底 return —— 不是任何虚拟组 → nil。
-- ★★ 注意 390 的 return 在 if 链**之外**（362 的 if 块的末尾）。
--   ⇒ 摄像机组（IsVCtrlCamera）**不在**方案 1 的处理里！
--   ⇒★★ 方案 1 下摄像机虚拟码直接返回 nil ⇒ 摄像机摇杆无效。
--   ⇒ 合理：经典方案（主机+手柄）用摄像机**预设**（92-95），
--     而不是虚拟摇杆。方案 2+ 才引入虚拟摄像机控制。
--   ⇒ 395 行的 IsVCtrlCamera 分支只在方案 2-7 生效。
		return
-- ★★ 方案 1 分支的结束。★ 注意 390 的 return 覆盖所有未匹配组。
	end

-- ★★ 原注释 "--Now handle all the new schemes (2 to 7) for each control category"
--   —— ★★ 这是整个「新版方案」体系的入口。
-- ★★ 新旧方案的本质差异：
--   · 方案 1：虚拟码 → 旧的 CONTROL_INVENTORY_*（**语义别名**）
--   · 方案 2-7：虚拟码 → CONTROL_PRESET_RSTICK_* / CONTROL_PRESET_DPAD_*
--     （**物理预设**：直接对应某个具体的摇杆/D-pad 槽位）
-- ⇒ 新方案把「意图」与「物理位置」**完全解耦**：
--   游戏逻辑用 CONTROL_PRESET_RSTICK_UP 表示「R 摇杆往上」，
--   而这个槽位在不同方案下被解释成不同语义。
--   ⇒★ 这是「控制方案」作为一等概念的真正含义。
	--Now handle all the new schemes (2 to 7) for each control category

-- ══════════════════════════════════════════════════════════════
-- ★★ 【分支2：方案 2-7】395-476 —— 五组逐一处理
-- 【★ 共同套路：算 needsmodifier → 判断修饰键状态 → 决定映射目标】
-- 【★★ needsmodifier 的编码技巧】
--   `local needsmodifier = bit.band(scheme, 1) == 0`（398 行）
--   ⇒ ★★★ **用 scheme 的奇偶位编码「是否需要修饰键」**！
--   ⇒ 偶数方案（2/4/6）需要修饰键，奇数方案（3/5/7）不需要。
--   ⇒★★ 一个 bit 承载了「六种方案的修饰键需求」，极度紧凑。
--   ⇒ ★ 隐式契约：控制方案的编号必须遵守这个奇偶约定。
--     参见 widgets/controls.lua 里玩家选方案的 UI。
-- 【★ 「按下修饰键」用哪个码？】
--   397 行 TheInput:GetDigitalControl(CONTROL_CAM_AND_INV_MODIFIER)
--   ⇒ ★★ 注意这里用的是 **TheSim 直接查询**，而非 self:IsControlPressed！
--   ⇒ ★ 因为 IsControlPressed 会再走一遍 ResolveVirtualControls（递归！）。
--   ⇒★★ 必须直接查 TheSim，否则会无限递归。
--   ⇒ 这是一个**必须绕过自身**的边界，标注为「递归防护点」。
	if IsVCtrlCamera(control) then
		--R.Stick for all schemes, modifier button for even number schemes
		local ismodified = TheSim:GetDigitalControl(CONTROL_CAM_AND_INV_MODIFIER)
-- ★★★ bit.band(scheme, 1) == 0 —— ★ 「奇偶编码方案需求」的技巧。
-- 【★ 四种取法在文件里的分布】
--  398  bit.band(scheme, 1) == 0     —— 摄像机组：偶数方案需修饰键
--  416  scheme >= 3 and scheme <= 5 —— 导航组：3/4/5 需修饰键
--  438  scheme == 6 or scheme == 7 —— 动作组：6/7 需修饰键
--  447  scheme == 5 or scheme == 7 —— 瞄准组：5/7 需修饰键
--  465  false                       —— 横移组：都不需要
-- 【★★ 三种编码方式并存！】
--   · 位运算（398）：摄像机组的「偶数/奇数」规律
--   · 区间（416）：导航组的「3-5」
--   · 枚举（438/447）：动作/瞄准组的「6,7」/「5,7」
--   ⇒★ 这说明每个方案组的修饰键需求是**独立设计的**，
--     只有摄像机组恰好能用 bit 表达。
--   ⇒ ⚠ 隐式耦合：改方案编号会同时影响这五处。
--   ⇒ 这是「把配置藏在代码里」的典型代价。
		local needsmodifier = bit.band(scheme, 1) == 0
-- ★★ `if ismodified ~= needsmodifier then return end` ——
--   「修饰键状态与需求不匹配 → 无效」。
-- ★★ 语义：
--   · needsmodifier 为真但没按修饰键 → 摇杆无效
--   · needsmodifier 为假但按着修饰键 → 摇杆无效
--   ⇒ ★★ **双向排斥**：按与不按都不生效，必须精确匹配。
--   ⇒ 体验上合理：「按住修饰键才切换功能，不按就是另一个功能」。
--   ⇒ ★ 但这在**同一个 if 里同时处理两种不匹配**，
--     使得「按错了修饰键」与「没按」表现相同（都是无效）。
--   ⇒ 对比另一种可能的设计：按了修饰键就一定切换（不看方案）。
--     DST 选了「严格匹配」，更可预测。
-- ★★ 注意 `~= xor` 的写法：两者不同时 return。
		if ismodified ~= needsmodifier then
			return
		end
		--Handle unmodified R.Stick priorities
-- ★★★ 402-407 的抢占判定，★ 与 366 的差别很关键。
--   366 行（方案 1）：`IsTwinStickAiming(player, scheme) or IsStrafing(player)`
--   404 行（方案 2-7）：`scheme ~= 5 and scheme ~= 7 and IsTwinStickAiming(...) or IsStrafing(player)`
-- 【★★ 运算符优先级陷阱】
--   `A and B and C or D` ≡ `(A and B and C) or D`
--   （and 优先于 or）
--   展开：`((scheme ~= 5) and (scheme ~= 7) and IsTwinStickAiming(player, scheme)) or IsStrafing(player)`
-- 【★ 语义】
--   · 方案 5/7 → 左边全假 → 落到 or → 只看 IsStrafing
--   · 其它方案 → 看 scheme!=5 且!=7 且 IsTwinStickAiming
-- ★★ 方案 5/7 是「双摇杆原生方案」（不需要额外条件）。
--   ⇒ 325 IsTwinStickAiming 里的 `if scheme < 4 or scheme > 7` 呼应这一点。
--   ⚠ 但 404 的写法可读性极差，且与 366 的写法不一致。
--   ⇒ 标注为「优先级陷阱 + 与366不一致」，轻度隐患。
		if not needsmodifier and player then
			if scheme ~= 5 and scheme ~= 7 and IsTwinStickAiming(player, scheme) or IsStrafing(player) then
				return
			end
		end
-- ★★★ 映射公式：`control - VIRTUAL_CONTROL_CAMERA_ZOOM_IN + CONTROL_PRESET_RSTICK_UP`
-- 【★ 这是「新方案」映射的标准形态】
--   公式：虚拟码 → 减去组基址（得索引 0..3）→ 加上目标组基址
--   ⇒★★ 「虚拟层」与「物理预设层」用**同构的四连组**做平移映射。
--   ⇒ 若 CONTROL_PRESET_RSTICK_UP/DOWN/LEFT/RIGHT 是连续的 92..95，
--     则整个映射就是一次**常量平移**。
-- ★★ 这是整个函数里最优雅的一行：一个减法一个加法解决四个方向。
-- ⚠ 隐式契约：CONTROL_PRESET_RSTICK_* 必须连续且顺序一致
--   （constants.lua:231 CONTROL_PRESET_RSTICK_UP = 92）。
		return control - VIRTUAL_CONTROL_CAMERA_ZOOM_IN + CONTROL_PRESET_RSTICK_UP
-- ══════════════════════════════════════════════════════════════
-- ★★ 【导航组（方案 2-7）】409-431 —— 最复杂的一段
-- 【★ 410 行原注释是完整的设计说明】
--   "--R.Stick for 2 and 3, DPad for 4 to 7, modifier button for 3 to 5"
-- 【★ 拆解】
--   · 方案 2, 3 → 用 R 摇杆
--   · 方案 4-7  → 用 D-pad
--   · 方案 3, 4, 5 → 需要修饰键
-- 【★ 411-414 的特例：控制器物品栏里忽略修饰键】
--   `if scheme <= 3 and player.HUD and player.HUD:IsControllerInventoryOpen() then`
--   ★★★ 注意这里**直接访问 player.HUD 而没有 player 判空**！
--   ⚠⚠ 疑似缺陷：`player` 可能是 nil（菜单界面）。
--     推理依据：351 行已经取过 `local player = ThePlayer`，
--     353 行明确判断了 `if player and player.HUD`，
--     ★ 但 411 行只判了 player.HUD，**漏了 player ~= nil**。
--     ⇒ 在主菜单（ThePlayer 为 nil）按摇杆 → attempt to index nil。
--   ⇒⇒ ★★ 标注为 ⚠⚠ 疑似缺陷（缺少 player 判空）。**不改代码**。
--     缓解：主菜单通常不调用 IsControlPressed 传虚拟码？
--     但 frontend.lua:839 的连发逻辑在栈顶是主菜单时**确实会调用**
--     `TheInput:IsControlPressed(VIRTUAL_CONTROL_INV_LEFT)`。
--     ⇒★ 若 ThePlayer 在主菜单为 nil，此路径会崩。
--     ⇒ 实际未崩说明 ThePlayer 在主菜单不是 nil（可能是上一局的）。
--     ⇒⇒ **推理依据完整但需实机验证**，如实标注为「疑似」。
	elseif IsVCtrlInvNav(control) then
		--R.Stick for 2 and 3, DPad for 4 to 7, modifier button for 3 to 5
		if scheme <= 3 and player.HUD and player.HUD:IsControllerInventoryOpen() then
			--In controller inventory screen, we can ignore R.stick modifier
			return control - VIRTUAL_CONTROL_INV_UP + CONTROL_PRESET_RSTICK_UP
		end
-- ★★ ismodified/needsmodifier 的取值（416 行）。
--   needsmodifier = scheme >= 3 and scheme <= 5
-- ★ 与 398 的 bit 写法不同 —— 这里用区间。
-- ★★ 419 行的 `elseif scheme <= 3` 分流：
--   · 方案 2/3 → 映射到 R 摇杆预设
--   · 方案 4-7 → 映射到 D-pad 预设
--   ⇒ ★★ **同一个函数返回两种物理预设** —— 这就是「方案」的意义。
		local ismodified = TheSim:GetDigitalControl(CONTROL_CAM_AND_INV_MODIFIER)
		local needsmodifier = scheme >= 3 and scheme <= 5
		if ismodified ~= needsmodifier then
			return
		elseif scheme <= 3 then
			--Handle unmodified R.Stick priorities
-- ★★ 421-427：方案 2/3 的抢占判定（未按修饰键时）。
--   422  `if not (player.HUD and player.HUD:IsCraftingOpen()) then`
--   423      双摇杆 or 横移 → return
-- ⚠★ 注意 422 行**同样没有 player 判空**（同 411 行的问题）。
--   ⇒ 但 423 行的 IsTwinStickAiming(player, scheme) 内部会判 player
--     （326 行 player.components.playercontroller），
--     所以 422 行的 player.HUD 是唯一会崩的点。
--   ⇒ 与 411 行同源，标注一致。
			if not needsmodifier and player then
				if not (player.HUD and player.HUD:IsCraftingOpen()) then
					if IsTwinStickAiming(player, scheme) or IsStrafing(player) then
						return
					end
				end
			end
-- ★★ 方案 2/3 → R 摇杆预设。与 408 行同构。
			return control - VIRTUAL_CONTROL_INV_UP + CONTROL_PRESET_RSTICK_UP
		else
-- ★★ 方案 4-7 → D-pad 预设。与 428 对称。
-- ★★★ 这就是「R.Stick for 2 and 3, DPad for 4 to 7」的实现。
			return control - VIRTUAL_CONTROL_INV_UP + CONTROL_PRESET_DPAD_UP
		end
-- ★ 动作组（方案 2-7）：434 行「Classic mapping for 2 and 3, DPad for 4 to 7,
--   modifier button for 6 and 7」—— 与导航组结构一致。
-- ★★ 但 434-435 的方案 2/3 分支**直接映射，无任何判定**。
--   ⇒ 对比导航组 419-431 的复杂判定。
--   ⇒ 合理：动作键是离散的，不需要抢占判定。
	elseif IsVCtrlInvAct(control) then
		--Classic mapping for 2 and 3, DPad for 4 to 7, modifier button for 6 and 7
		if scheme <= 3 then
			return RemapTo_CONTROL_INVENTORY_ACTIONS[control - VIRTUAL_CONTROL_INV_ACTION_UP]
		end
		local ismodified = TheSim:GetDigitalControl(CONTROL_CAM_AND_INV_MODIFIER)
		local needsmodifier = scheme == 6 or scheme == 7
		if ismodified ~= needsmodifier then
			return
		else
			return control - VIRTUAL_CONTROL_INV_ACTION_UP + CONTROL_PRESET_DPAD_UP
		end
-- ★ 瞄准组（方案 2-7）：445 行「R.Stick for all schemes,
--   modifier button for 5 and 7」。
-- ★★ 452 行 `if scheme <= 3 and not (player and ...IsAOETargeting()) then return end`
--   ★★★ **★ 这次的判空顺序是对的！** player 先判。
--   ⇒ 与 411/422 行的错误形成鲜明对比。
--   ⇒★ 说明作者在同一文件里知道要判空，只是 411/422 漏了。
--   ⇒ 进一步佐证 411 行的缺陷是疏漏而非有意。
-- ★★ 456-460：方案 2 且合成面板打开 → 抢占。
	elseif IsVCtrlAiming(control) then
		--R.Stick for all schemes, modifier button for 5 and 7
		local ismodified = TheSim:GetDigitalControl(CONTROL_CAM_AND_INV_MODIFIER)
		local needsmodifier = scheme == 5 or scheme == 7
		if ismodified ~= needsmodifier then
			return
		end
		--Twin stick aiming outside of AOE targeting is only supported by schemes 4 to 7
		if scheme <= 3 and not (player and player.components.playercontroller and player.components.playercontroller:IsAOETargeting()) then
			return
		end
		--Handle unmodified R.Stick priorities
		if not needsmodifier and player then
			if scheme == 2 and player.HUD and player.HUD:IsCraftingOpen() then
				return
			end
		end
		return control - VIRTUAL_CONTROL_AIM_UP + CONTROL_PRESET_RSTICK_UP
-- ★ 横移组（方案 2-7）：463 行「Unmodified R.Stick for all schemes」。
-- ★★ 465 行 needsmodifier = false —— **永远不需要修饰键**。
--   ⇒ 397/415/437/446 四处都要查修饰键状态，
--     唯独这里 `ismodified ~= false` ⇔ 按了修饰键就无效。
--   ⇒ ★★ 换言之：**横移组与修饰键互斥**（按了就失效）。
--   ⇒ 体验：按住修饰键时 R 摇杆变成摄像机/瞄准，而不是横移。
	elseif IsVCtrlStrafe(control) then
		--Unmodified R.Stick for all schemes
		local ismodified = TheSim:GetDigitalControl(CONTROL_CAM_AND_INV_MODIFIER)
		local needsmodifier = false
		if ismodified ~= needsmodifier then
			return
		end
		--Handle unmodified R.Stick priorities
		if not needsmodifier and player then
			if scheme == 2 and player.HUD and player.HUD:IsCraftingOpen() then
				return
			end
		end
-- ★★ 横移组 → R 摇杆预设。与 408 同构。
		return control - VIRTUAL_CONTROL_STRAFE_UP + CONTROL_PRESET_RSTICK_UP
	end
-- ★★ 函数结束。★★ 隐式返回 nil（若所有分支都未命中）。
--   ⇒ 这是「未知虚拟码 → 无效」的默认行为 ✓
end

-- ══════════════════════════════════════════════════════════════
-- ★★★★ 【IsControlPressed】—— 「我想要 X，问它按下了没」。
-- 【★ 这是全游戏使用频率最高的输入函数（每帧被调用无数次）】
--
-- 【★★ 两行代码，但承载了整个双层抽象】
--   480  control = self:ResolveVirtualControls(control)   ← 翻译
--   481  return control ~= nil and TheSim:GetDigitalControl(control)
-- 【★★ 三种调用意图，调用方写法完全相同】
--   ① 问物理控制码：IsControlPressed(CONTROL_ATTACK)
--      → ResolveVirtualControls 在 348 行直接返回（< 10000）
--   ② 问虚拟控制码：IsControlPressed(VIRTUAL_CONTROL_INV_LEFT)
--      → ResolveVirtualControls 翻译成 CONTROL_PRESET_RSTICK_LEFT
--   ③ 问当前无效的：IsControlPressed(VIRTUAL_CONTROL_CAMERA_ZOOM_IN)
--      → ResolveVirtualControls 返回 nil → 481 行 false
-- ⇒ ★★★ 「值」的语义统一为「此刻这个意图是否生效且被按下」。
--
-- ⚠⚠⚠ 【★ 与 G3 的关系 —— 本函数就是 G3 的祸根之一】
--   481 行 TheSim:GetDigitalControl(control) 是**物理状态查询**，
--   ★★ 它**完全绕过**了 163-169 的事件仲裁！
--   ⇒ 即使 UI 在事件层吃掉了这次点击（前端 439 的 HACK 就是为此），
--     任何**轮询式**调用本函数的地方依然会看到「按下了」。
--   ⇒★★ 这就是 G3「按下/抬起两帧导致误攻击」的**技术根源之一**：
--     playercontroller.lua:3133 每帧轮询 IsControlPressed(CONTROL_PRIMARY)，
--     走的是 481 行，**看不到** UI 的消费。
--   ⇒ 只能靠 frontend.lua:439-448 事后清 retarget 来补救。
--   ⇒⇒ ★★ 若把 481 行改成读「事件层记录的最后一次消费结果」，
--     G3 就会**结构性消失**。这就是 mark_input_swallowed 的价值。
--═════════════════════════════════════════════════════════════
function Input:IsControlPressed(control)
	control = self:ResolveVirtualControls(control)
	return control ~= nil and TheSim:GetDigitalControl(control)
end

-- ★★ GetAnalogControlValue —— 模拟量版本（摇杆推力）。
--   control = self:ResolveVirtualControls(control)
--   return control and TheSim:GetAnalogControl(control) or 0
-- ★★ 与 479 的两处差异（细节但重要）：
--   ① `control and ...` 而非 `control ~= nil and ...`
--     ⇒ 利用 Lua 三值性：nil 时走 or 0
--   ② 返回 **0** 而非 false（类型不同：数值 vs 布尔）
-- ★★ 481 返回布尔、486 返回数值 —— 调用方必须知道区别。
--   frontend.lua:703 用它判 `> 0.95`（数值比较）✓
-- ★★★ 486 与 481 有**同样的绕过仲裁问题**（480 行同样到 TheSim）。
--   ⇒ playercontroller 的摇杆瞄准也读物理模拟量。
function Input:GetAnalogControlValue(control)
	control = self:ResolveVirtualControls(control)
	return control and TheSim:GetAnalogControl(control) or 0
end

-- ══════════════════════════════════════════════════════════════
-- ★★ 【GetActiveControlScheme】—— 「当前用哪套方案」。
-- 【★ 490-491 的原注释很重要】
--   "--V2C: This check is simplified (assumes all control schemes are
--       for controllers only)."
--   "--     It's also unlikely that we'd ever need to set up control
--        schemes for kybd/mouse."
-- 【★ 实现（492 行）】
--   return self:ControllerAttached() and Profile:GetControlScheme(id) or 1
-- 【★★ 语义：键鼠玩家强制方案 1】
--   ⇒ 因为 ControllerAttached() 为假 → and 假 → or 1。
--   ⇒★ 「一套 scheme 表同时服务键鼠与手柄」的简化：
--     键鼠不参与方案系统，永远是「经典方案」。
-- ★★ 这个函数被 339ResolveVirtualControls 反复调用
--   （359/345 行）—— 每次都走一次 Profile 查询 + 控制器检测。
-- ⚠ 性能：IsControlPressed → ResolveVirtualControls → GetActiveControlScheme
--   → ControllerAttached（可能读缓存）+ Profile:GetControlScheme。
--   ⇒ 每帧数百次调用 ⇒ ★ 这条链是潜在的热点。
--   ⚠ 但 ControllerAttached 91 行读缓存（PC 上）所以较便宜。
--   ⇒ 标注为「潜在热点，靠缓存缓解」。
function Input:GetActiveControlScheme(schemeId)
	--V2C: This check is simplified (assumes all control schemes are for controllers only).
	--     It's also unlikely that we'd ever need to set up control schemes for kybd/mouse.
	return self:ControllerAttached() and Profile:GetControlScheme(schemeId) or 1
end

-- ★ SupportsControllerFreeAiming —— 「当前方案支持自由瞄准？」
--   return scheme >= 4 and scheme <= 7
-- ★★ 与 325 IsTwinStickAiming 的 `scheme < 4 or scheme > 7` 互为取反。
--   ⇒ 印证「双摇杆只在方案 4-7 支持」。
-- ★ 消费者：控制设置界面（决定是否显示某个选项）。
function Input:SupportsControllerFreeAiming()
	local scheme = self:GetActiveControlScheme(CONTROL_SCHEME_CAM_AND_INV)
	return scheme >= 4 and scheme <= 7
end

-- ★ SupportsControllerFreeCamera —— 「支持自由摄像机？」
--   return scheme >= 2 and scheme <= 7
-- ★★ 比 495 宽（2 起）。★ 这是 398行
--   `needsmodifier = bit.band(scheme, 1) == 0` 的含义：
--   ⇒ 方案 2 起有虚拟摄像机控制（其中偶数方案需修饰键）。
-- ★★ 三个 Supports 函数构成了「方案能力查询」的公共 API。
function Input:SupportsControllerFreeCamera()
	local scheme = self:GetActiveControlScheme(CONTROL_SCHEME_CAM_AND_INV)
	return scheme >= 2 and scheme <= 7
end

-- ★★ IsPasteKey —— 「这个键是粘贴键吗」（跨平台）。
-- 【★ 三个平台的差异（505-513）】
--  macOS  → Cmd+V（LSUPER / RSUPER）
--  其他   → Ctrl+V
--  Linux  → 额外支持 Shift+Insert
-- ★★ 507 行 `PLATFORM == "OSX_STEAM"` —— 只判 macOS Steam 版，
--   不含 macOS 主机版（若存在）。⚠ 平台判定的脆弱性。
-- ★★ 512 行的三元结构：
--   return key == KEY_INSERT and PLATFORM == "LINUX_STEAM"
--          and self:IsKeyDown(KEY_SHIFT)
--   ⇒ ★★★ **三个 and 串联，最后一个是 boolean**。
--   ⇒ 若前面的条件为假，返回的是 **false**（不是 nil）——
--     因为 and 短路返回最后一个操作数，而 PLATFORM=="LINUX_STEAM"
--     是最后一个被求值的**值**类型条件（返回布尔）。
--   ⇒ ★ 实际是安全的：因为第二个条件是布尔比较。
-- ★★ 消费者：widgets/textedit.lua（粘贴功能）。
function Input:IsPasteKey(key)
    if key == KEY_V then
        if PLATFORM == "OSX_STEAM" then
            return self:IsKeyDown(KEY_LSUPER) or self:IsKeyDown(KEY_RSUPER)
        end
        return self:IsKeyDown(KEY_CTRL)
    end
    return key == KEY_INSERT and PLATFORM == "LINUX_STEAM" and self:IsKeyDown(KEY_SHIFT)
end

-- ══════════════════════════════════════════════════════════════
-- ★★★★ 【UpdateEntitiesUnderMouse】—— 鼠标拾取的显式触发。
--
-- ★★ 只有一行：`self.entitiesundermouse = TheSim:GetEntitiesAtScreenPoint(...)`
-- 【★ 为什么需要这个「显式」版本？】
--   因为通常不需要 —— 519 OnUpdate 每帧都会调它。
--   ★ 但有两种情况需要「立即重算」：
--     ① frontend.lua:1137 PopScreen 后（下面的屏幕露出来了）
--     ② frontend.lua:929 DoHoverFocusUpdate(manual_update=true)
--   ⇒ ★「按需重算」比「每帧重算」更省。
-- ⚠ 缺少 mouse_enabled 守卫（对比 520 OnUpdate 有）。
--   ⇒ 主机上调用它会做一次无用的 C++ 拾取。
--   ⇒ 轻微性能问题，无功能影响。标注为「轻度不一致」。
function Input:UpdateEntitiesUnderMouse()
-- ★★ TheSim:GetEntitiesAtScreenPoint —— ★ 实体拾取的 C++ 实现。
-- 【★★★ 这就是「UI 与世界共用一套鼠标命中」的技术底座】
--   返回一个**列表**（按深度/距离排序），包含：
--     · 3D 世界实体（怪物、物品、玩家…）
--     · ★ UI 实体（widget.lua:7 CreateEntity 建的）
--   ⇒ 因为 UI 实体也在 TheSim 的实体表里、也有 UITransform。
-- 【★ 拾取范围限定】
--   ★ 只在 TheSim 的 **UIRoot 子树**内搜索。
--   UIRoot 由 widgets/screen.lua:34 的 TheSim:SetUIRoot 设置。
--   ⇒★★ 这就是「栈顶之外的屏幕收不到鼠标事件」的物理原因：
--     它们的实体不在 UIRoot 子树里。
--     ★★ 而 InsertScreenUnderTop（frontend.lua:959）插入的屏幕
--       从未被 SetUIRoot（因为它不调 OnBecomeActive）→
--       ★★ 它的任何 UI 实体都**无法被鼠标命中**！
--   ⇒⇒ 这是缺陷 G4 的**物理层后果**，比 1105 行的逻辑不对称更致命。
	self.entitiesundermouse = TheSim:GetEntitiesAtScreenPoint(TheSim:GetPosition())
end

-- ══════════════════════════════════════════════════════════════
-- ★★★★ 【OnUpdate】—— ★★ 每帧鼠标穿透判定（519-571，53 行）
--
-- 【★★ 它解决的问题：★★★ 「多个实体叠在鼠标下，点哪个？」】
--   鼠标下可能有：血条 + 名字 + 描边 + 道具 + 地面…
--   GetEntitiesAtScreenPoint 返回全部（DST 的「透明图元也要能被点到」），
--   所以必须有一个**规则**决定「哪个才是玩家想点的」。
-- 【★★ 规则就是 CanMouseThrough（526 行）】
--   每个实体可以回答：「我允许鼠标穿透我吗？」
--   · 返回 (true, false)  → 我可以被穿透，继续往里找
--   · 返回 (false, ...)   → 我不可穿透，就是最终目标
--   · 返回 (false, true)   → 「穿透但别找我」（keepnone 语义）
-- 【★ 两个返回值的语义】
--   mousethrough —— 能否穿透到更深的实体
--   keepnone     —— ★ 「如果全都穿透，什么都不选」
-- ★★ keepnone 的场景：鼠标在一堆纯装饰元素上
--   ⇒ 应该「什么都不发生」，而不是选中最后兜底的那个。
-- 【★ 整个函数的流程（519-571）】
--  520-521  鼠标不可用 → 整个函数跳过（主机上是空操作）
--  523      inst = entitiesundermouse[1]  —— 最上面的
--  524      ★ client_forward_target 转发（网络代理实体）
--  526-557  穿透循环
--  559-569  变化检测 → 派发 mouseover / mouseout
--─────────────────────────────────────────────────────────────
function Input:OnUpdate()
    if self.mouse_enabled then
        self.entitiesundermouse = TheSim:GetEntitiesAtScreenPoint(TheSim:GetPosition())

        local inst = self.entitiesundermouse[1]
-- ★★ client_forward_target —— 「实体代理」机制。
-- 【★ 联机下的实体分层】
--   客户端上，一个「远端玩家」可能有多个实体：
--     · 外壳实体（可点击，用于 HUD 交互）
--     · 代理实体（client_forward_target，指向真正的逻辑实体）
--   ⇒ 鼠标命中外壳后，要转而操作代理。
-- ★★ 531 行对 nextinst 也做了同样转发。
-- ★★ 这是联机同步对 UI 的影响：
--   输入系统的鼠标命中结果需要经过一层「代理解析」。
--   ⇒ 参见 04-联机同步报告的「classified 实体模式」章节。
		inst = inst and inst.client_forward_target or inst

-- ★★★★ 【★★ CanMouseThrough 穿透循环】526-557
-- 【★ 三个 break 条件（决定何时停止往里找）】
--  533-541  nextinst 为 nil、或是玩家、或是「世界/HUD 属性变化」
--           ⇒ ★★ **跨类型不穿透**：从 HUD 元素不能穿到世界实体，
--             反之亦然。理由：点击血条不应该攻击底下的怪物。
--  536-539  keepnone → 「什么都不选」并 break
--           ⇒ ★★ keepnone 的实现就在这里：直接 break 且 inst 保持不变
--  549-551  nextinst 不可穿透 → break（找到目标了）
-- 【★ 循环的推进逻辑（543-548）】
--   inst = nextinst   —— ★ **无论是否穿透都推进**
--   然后更新 mousethrong/keepnone 为 nextinst 的 CanMouseThrough 结果
-- ⇒ 即「当前候选 = 下一层实体，携带它的穿透意愿」。
-- 【★★ 循环不变量】
--   每一轮结束时：(inst, mousethrough, keepnone) 三元组描述
--   「当前已选实体 + 它是否允许继续穿透 + 若穿透到底是否放弃」。
--   ⇒ 这是一个干净的状态机写法。
        if inst ~= nil and inst.CanMouseThrough ~= nil then
-- ★★ `local mousethrough, keepnone = inst:CanMouseThrough()` ——
--   ★★ **鸭子类型探测**：只有实现了 CanMouseThrough 的实体才回答。
--   （526 行先判 `inst.CanMouseThrough ~= nil`）
-- ★★ prefabs/ 里的实体通过组件实现这个方法
--   （例：containerwidget / interactable 类的组件）。
-- ★★ 这就是「UI 无关实体（怪物）默认不可穿透，UI 装饰默认可穿透」
--   这条规则的**来源**：谁定义了 CanMouseThrough 谁就参与穿透。
-- ★★★ 与缺陷 G2 的关系：
--   「透明 Image 吃焦点」的根源之一就是这个机制 ——
--   透明图元**既不吃穿透、又吃命中**，两头通吃。
--   ⇒ 框架没有「纯装饰」这一类别，只有「可穿透 / 不可穿透」二元。
--   ⇒ 这是 G2 的**机制层根因**。
            local mousethrough, keepnone = inst:CanMouseThrough()
            if mousethrough then
                for i = 2, #self.entitiesundermouse do
                    local nextinst = self.entitiesundermouse[i]
					nextinst = nextinst and nextinst.client_forward_target or nextinst

-- ★★★ 三个 break 条件的合取（533-535）—— 「跨类型不穿透」。
--   nextinst == nil or
--   nextinst:HasTag("player") or
--   (nextinst.Transform ~= nil) ~= (inst.Transform ~= nil)
-- 【★★ 逐项解读】
--  ① nextinst == nil —— 列表到底了
--  ② HasTag("player") —— ★ **玩家实体是「终点」**
--     ⇒ 鼠标在玩家身上时，永远选中玩家，不会穿到玩家身上的 UI
--       （名字、血条）—— 这符合直觉。
--     ⇒ 但也意味着玩家身上的 UI **无法被点击**？
--       ⚠ 若如此，「点自己的血条」是做不到的。
--       ⇒ 实际上 widgets/playerhud 里玩家的血条是纯显示，不可点 ✓
--  ③ ★★ 类型变化（Transform 有无不同）—— 世界实体 ↔ HUD 元素
--     ⇒ 这与 267/284 的判定方式**同一个概念**
--       （用 Transform 区分世界与 HUD）。
--   ⇒★ 所以「点 UI 不穿透到世界」这条规则在此实现。
--     ★★ 这也解释了为什么点击 UI 不会同时攻击底下的怪物。
                    if nextinst == nil or
                        nextinst:HasTag("player") or
                        (nextinst.Transform ~= nil) ~= (inst.Transform ~= nil) then
-- ★★ keepnone 分支：「穿透到底就什么都不选」。
--   537  inst = nextinst
--   538  mousethrough, keepnone = false, false
--   540  break
-- ★★ 注意它**仍然把 inst 设为 nextinst**（537），
--   然后才 break。⇒ 所以最终 hoverinst 不是 nil！
--   ⚠ 这与 553-555 的 `if mousethrough and keepnone then inst = nil end`
--     语义**不同**（那里才是真的置 nil）。
--   ⇒★★ 两处 keepnone 的处理不一致：
--     · 536-540：选了 nextinst 然后 break（保留选择）
--     · 553-555：置 inst = nil（放弃选择）
--   ⇒ 推测：536 是「中途遇到 keepnone 的实体，接受它」；
--     553 是「所有层都穿透且最后说 keepnone，全放弃」。
--   ⇒ 标注为「两处 keepnone 语义不同，需仔细区分」。
                        if keepnone then
                            inst = nextinst
                            mousethrough, keepnone = false, false
                        end
                        break
                    end

                    inst = nextinst
-- ★★ 544-548 的推进：无论穿透与否都把 inst 设为 nextinst。
--   544  if nextinst.CanMouseThrough == nil then
--   545      mousethrough, keepnone = false, false   ← 无方法 = 不可穿透
--   546  else
--   547      mousethrough, keepnone = nextinst:CanMouseThrough()
--   548  end
-- ★★ 545 行：没有 CanMouseThrough 方法的实体 = **终点**。
--   ⇒ 怪物、物品等玩法实体默认「实心」，能挡住后面的 UI。
--   ⇒ 这就是「点怪物」能工作的原因。
                    if nextinst.CanMouseThrough == nil then
                        mousethrough, keepnone = false, false
                    else
                        mousethrough, keepnone = nextinst:CanMouseThrough()
                    end
                    if not mousethrough then
                        break
                    end
                end
-- ★★ 循环结束后的 keepnone 收尾：全穿透且要求放弃 → inst = nil。
-- ★★ 553 行 `if mousethrough and keepnone then` ——
--   循环自然结束（没被 break）时，mousethrong 仍为 true
--   ⇒ 说明一路穿透到了列表末尾，且最后一个实体说「别选我」。
--   ⇒ 置 nil ⇒ hoverinst = nil ⇒ frontend.lua:935 走屏幕级兜底。
-- ★★ 与 536-540 的对照见该行分析。
                if mousethrough and keepnone then
                    inst = nil
                end
            end
        end

-- ══════════════════════════════════════════════════════════════
-- ★★ 【mouseover / mouseout 派发】559-569 —— hover 的副作用
-- 【★ 变化检测：`if inst ~= self.hoverinst then`】
--  560-562  新实体且是 3D → inst:PushEvent("mouseover")
--  564-566  旧实体且是 3D → self.hoverinst:PushEvent("mouseout")
--  568      self.hoverinst = inst
-- 【★ 为什么只在 Transform ~= nil 时派发？】
--   ⇒ ★★ **UI 实体不派发 mouseover/mouseout**！
--     UI 的 hover 走的是**焦点**机制（frontend.lua:925-939），
--     而不是事件。
--   ⇒ 所以：世界实体 → 事件；UI 实体 → 焦点变更。
--   ⇒★ 两条 hover 机制并存，这是理解 DST 输入的关键。
-- ★★ 561 行 PushEvent 是**异步**的（进事件队列）
--   ⇒ 与 widget.lua:187 的 HandleEvent（同步）不同。
--   ⇒ ⚠ 「hoverinst 已更新但 mouseout 还没处理」可能发生。
        if inst ~= self.hoverinst then
            if inst ~= nil and inst.Transform ~= nil then
                inst:PushEvent("mouseover")
            end

            if self.hoverinst ~= nil and self.hoverinst.Transform ~= nil then
                self.hoverinst:PushEvent("mouseout")
            end

            self.hoverinst = inst
        end
    end
end

-- ★ IsControlMapped —— 「这个控制码有绑定吗」。
-- ★★ 574 行 GetLocalizedControl(..., false, true) 与 598 相同，
--   区别是这里只看返回的 device/numInputs，不取文本。
-- ★★ 575 行 `device ~= 9` —— ★ 设备号 9 是「无设备」的哨兵。
--   （对照 601 行 `STRINGS.UI.CONTROLSSCREEN.INPUTS[9][1]`）
--   ⇒ ★ 「9」在本地化表里是一个特殊条目。
-- ★ 消费者：控制设置界面（判断是否要显示「未绑定」）。
function Input:IsControlMapped(deviceId, controlId)
	local device, numInputs = TheInputProxy:GetLocalizedControl(deviceId, controlId, false, true)
	return device and device ~= 9 and numInputs >= 1
end

-- ★★ ControlsHaveSameMapping —— 「这两个控制码绑的是同一个东西吗」。
-- 【★ 实现：逐字段比较 8 个返回值】
--   device_1~4, numInputs, input1_1~3, intParam_1 —— 共 8 个
-- ★★ 为什么要比这么多？
--   因为一个控制码可以绑**多个**输入（579 行取回 4 个 input）。
--   ⇒ 判定「相同」必须全字段一致。
-- ★ 消费者：控制设置界面（检测「重复绑定」并警告）。
-- ⚠ 580 行的早退：`device_1 == nil or device_1 == 9 or numInputs_1 < 1`
--   → false。原注释 "--don't match unmapped controls"。
--   ⇒ ★ 未绑定的控制码**不算相同**（哪怕都未绑定）。
--   ⇒ 合理：两个「未绑定」不构成冲突。
function Input:ControlsHaveSameMapping(deviceId, controlId_1, controlId_2)
	local device_1, numInputs_1, input1_1, input2_1, input3_1, input4_1, intParam_1 = TheInputProxy:GetLocalizedControl(deviceId, controlId_1, false, true)
	if device_1 == nil or device_1 == 9 or numInputs_1 < 1 then
		return false --don't match unmapped controls
	end
	local device_2, numInputs_2, input1_2, input2_2, input3_2, input4_2, intParam_2 = TheInputProxy:GetLocalizedControl(deviceId, controlId_2, false, true)
	return device_1 == device_2
		and numInputs_1 == numInputs_2
		and input1_1 == input1_2
		and input2_1 == input2_2
		and input3_1 == input3_2
		and input4_1 == input4_2
		and intParam_1 == intParam_2
end

-- ★★ GetLocalizedControl —— 「这个控制码现在绑的是哪个键（人类可读）」。
-- 【★ 594-596 的分发】
--   if controlId >= VIRTUAL_CONTROL_START then
--       return self:GetLocalizedVirtualControl(...)
--   ⇒ ★★ 又是双层分派 —— 与 342 行的 IsControlPressed 同构。
--   ⇒ 两处合起来：**任何接收 controlId 的公共函数都必须先分派**。
-- 【★ 610 行的「多输入拼接」】
--   for idx = 2, numInputs do
--       text = text.." + "..STRINGS.UI.CONTROLSSCREEN.INPUTS[device][inputs[idx]]
--   ⇒ ★ 一个控制码可绑多个键（如「鼠标左键 + 游戏手柄 A」），
--     显示为 "鼠标左键 + 手柄A"。
--   ⇒ ★ 拼接分隔符是 " + "（带空格）。
-- ★★ 614 行 `intParam ~= nil and string.format(text, intParam) or text`
--   ⇒ ★★ **格式串里可能含 %d 之类**（如「滚轮第 3 格」）。
--   ⚠ 风险：若某个本地化文本本身含 % 而 intParam 为 nil，
--     string.format 会报错或格式化失败。这里用 and/or 规避 ✓
--   ⇒ 与 675 行的同类模式呼应。
function Input:GetLocalizedControl(deviceId, controlId, use_default_mapping, use_control_mapper)
	if controlId >= VIRTUAL_CONTROL_START then
		return self:GetLocalizedVirtualControl(deviceId, controlId, use_default_mapping, use_control_mapper)
	end

    local device, numInputs, input1, input2, input3, input4, intParam = TheInputProxy:GetLocalizedControl(deviceId, controlId, use_default_mapping == true, use_control_mapper ~= false)

-- ★★ 600-604 的三态返回：
--   601  device == nil → STRINGS.UI.CONTROLSSCREEN.INPUTS[9][1]
--        ⇒ ★ 设备号 9 的本地化文本（哨兵，通常是「未知」）
--   603  numInputs < 1 → ""（空串）
--        ⇒ 「未绑定」显示为空
-- ★★ 三态区分得很清楚：**未知设备 / 未绑定 / 已绑定**。
--   ⇒ 说明按键设置界面要处理这三种显示。
    if device == nil then
        return STRINGS.UI.CONTROLSSCREEN.INPUTS[9][1]
    elseif numInputs < 1 then
        return ""
    end

-- ★ local inputs = { input1, input2, input3, input4 } —— 收集四个输入。
-- ★★ 607 行只用 inputs[1]（text 从 input1 开始），
--   609-611 循环从 idx=2 追加。
-- ⚠ 若 numInputs > 4（比如绑了 5 个键）？
--   C++ 最多返回 4 个，所以不会。⚠ 但代码没有断言。
    local inputs = { input1, input2, input3, input4 }
    local text = STRINGS.UI.CONTROLSSCREEN.INPUTS[device][input1]
    -- concatenate the inputs
    for idx = 2, numInputs do
        text = text.." + "..STRINGS.UI.CONTROLSSCREEN.INPUTS[device][inputs[idx]]
    end

    -- process string format params if there are any
    return intParam ~= nil and string.format(text, intParam) or text
end

-- ══════════════════════════════════════════════════════════════
-- ★★ 【GetLocalizedVirtualControl】—— 本地化版的虚拟层（617-678）
-- 【★★ 它是 339-477 ResolveVirtualControls 的「镜像」】
-- 【★ 结构完全对应】
--   339  判断方案1 → 映射到 CONTROL_INVENTORY_*
--   617  判断方案1 → 映射到 CONTROL_INVENTORY_*（同样的表）
--   395  判断方案2-7 → 映射到 RSTICK/DPAD 预设
--   637  判断方案2-7 → 映射到 RSTICK/DPAD 预设
-- 【★★ ★★ 两处映射逻辑必须保持一致】
--   否则会出现「显示绑定的键」与「实际生效的键」不符。
--   ⇒ 例如 617 用 CONTROL_PRESET_RSTICK_UP，
--     408 也用 CONTROL_PRESET_RSTICK_UP ✓ 一致。
--   ⇒ 但 646-651 的 needsmodifier 计算与 415-416 **不同**：
--     415  needsmodifier = scheme >= 3 and scheme <= 5
--     646-651 又额外加了「控制器物品栏里忽略修饰键」的特例。
--   ⇒ ★★ 646-651 是 617 独有的逻辑（617 有、617 无）。
--   ⇒ 标注为「两处映射的修饰键计算不完全一致」。
--   ⇒★ 这是一个真实的维护隐患：改一处忘另一处。
--─────────────────────────────────────────────────────────────
function Input:GetLocalizedVirtualControl(deviceId, controlId, use_default_mapping, use_control_mapper)
-- ★★ `Profile:GetControlScheme(CONTROL_SCHEME_CAM_AND_INV) or 1` ——
-- ★★★ 注意与 489 GetActiveControlScheme 的**关键差异**：
--   489  有 `self:ControllerAttached() and ...`（键鼠强制方案 1）
--   618  **没有**（直接读 Profile）
-- ★★★ 618 行原注释说明了理由：
--   "--ignores controller active or not"
-- ★★ 为什么要忽略控制器状态？
--   ⇒ 因为「按键设置界面」要能显示**任何方案下的绑定**，
--     即使玩家当前没插手柄。
--   ⇒ ★ 这是设置界面与运行时的**不同需求**。
--   ⇒ 618 行的 `or 1` 只在 Profile 里没这个键时兜底。
	local scheme = Profile:GetControlScheme(CONTROL_SCHEME_CAM_AND_INV) or 1 --ignores controller active or not

	--Scheme 1 is classic style, where we have no modifier button, and everyhting is remappable.
	if IsCamAndInvCtrlScheme1(scheme) then
		if IsVCtrlInvNav(controlId) then
			return self:GetLocalizedControl(deviceId, RemapTo_CONTROL_INVENTORY[controlId - VIRTUAL_CONTROL_INV_UP])
		elseif IsVCtrlInvAct(controlId) then
			return self:GetLocalizedControl(deviceId, RemapTo_CONTROL_INVENTORY_ACTIONS[controlId - VIRTUAL_CONTROL_INV_ACTION_UP])
		elseif IsVCtrlAiming(controlId) then
			return self:GetLocalizedControl(deviceId, RemapTo_CONTROL_INVENTORY[controlId - VIRTUAL_CONTROL_AIM_UP])
		elseif IsVCtrlStrafe(controlId) then
			return self:GetLocalizedControl(deviceId, RemapTo_CONTROL_INVENTORY[controlId - VIRTUAL_CONTROL_STRAFE_UP])
		end
		return ""
	end

	--Now handle all the new schemes (2 to 7) for each control category

	local needsmodifier
	if IsVCtrlCamera(controlId) then
		--R.Stick for all schemes, modifier button for even number schemes
		needsmodifier = bit.band(scheme, 1) == 0
		controlId = controlId - VIRTUAL_CONTROL_CAMERA_ZOOM_IN + CONTROL_PRESET_RSTICK_UP
	elseif IsVCtrlAiming(controlId) then
		--R.Stick for all schemes, modifier button for 5 and 7
		needsmodifier = scheme == 5 or scheme == 7
		controlId = controlId - VIRTUAL_CONTROL_AIM_UP + CONTROL_PRESET_RSTICK_UP
	elseif IsVCtrlInvNav(controlId) then
		--R.Stick for 2 and 3, DPad for 4 to 7, modifier button for 3 to 5
		needsmodifier = scheme >= 3 and scheme <= 5
		if scheme <= 3 then
-- ⚠⚠⚠ 【★ 未定义全局 player —— 本文件最实的一个缺陷】
--
-- 原代码：if needsmodifier and player.HUD and player.HUD:IsControllerInventoryOpen() then
--
-- 【★ grep 核实：本函数（617-678）的作用域内没有 player】
--   · 617-678 的局部变量只有 scheme(618) / needsmodifier(636) /
--     controlId(参数) / text(673)。
--   · ★ 对比 339 ResolveVirtualControls：它在 351 行有 local player = ThePlayer，
--     所以同类的 player.HUD 写法（411/422 行）在那里是合法的。
--   · ⇒ 649 行很可能是从 411 行复制粘贴过来时漏了 local player。
--   · 全库 grep 核实：不存在全局 player（正确的是 ThePlayer，
--     main.lua:332 定义）。所有其它文件里的 player 都是函数形参。
--   ⇒ 若该行被求值，player 为 nil → attempt to index nil（崩溃）。
--
-- 【★★ 可达性精确分析（本条价值最高的部分）】
--   进入 649 行需要三个条件同时成立：
--     ① IsVCtrlInvNav(controlId) 为真（645 行）
--     ② needsmodifier 为真 ⇒ 647 行 scheme 在 3..5
--     ③ 648 行 scheme <= 3
--   ⇒ ★★ ②∩③ = scheme == 3（唯一解）。
--
-- 【★ 当前是否会被触发？结论：不会，但只是运气好】
--   grep 核实 GetLocalizedVirtualControl 的全部调用点：
--     · input.lua:595（GetLocalizedControl 的转发）
--     · prefabs/farm_soil.lua:19 —— 传 VIRTUAL_CONTROL_INV_ACTION_LEFT
--     · prefabs/quagmire_soil.lua:19 —— 传 VIRTUAL_CONTROL_INV_ACTION_LEFT
--     · widgets/inventorybar.lua:1156 —— 传 VIRTUAL_CONTROL_INV_ACTION_DOWN
--   ⇒ ★★ 所有现有调用方传的都是 ACTION 组（IsVCtrlInvAct），
--     不是 NAV 组 ⇒ 645 行为假 ⇒ 649 永不求值。
--   ⇒⇒ 这是一个被调用方巧合保护的缺陷：
--     只要有人（模组、或将来 Klei 自己）写一句
--       TheInput:GetLocalizedControl(id, VIRTUAL_CONTROL_INV_UP)
--     且玩家用的是方案 3，键位设置界面就会崩。
--
-- ⇒⇒ 标注为 ⚠⚠⚠ 疑似缺陷（未定义全局 player，方案 3 下会崩）。
--     修复建议（不改代码）：在 617 函数开头补 local player = ThePlayer。
--     ★ 这个模式（从 ResolveVirtualControls 复制到本地化函数时
--       漏掉 local 声明）在两个函数间迁移代码时很常见。
			if needsmodifier and player.HUD and player.HUD:IsControllerInventoryOpen() then
				--In controller inventory screen, we can ignore R.stick modifier
				needsmodifier = false
			end
			controlId = controlId - VIRTUAL_CONTROL_INV_UP + CONTROL_PRESET_RSTICK_UP
		else
-- ★★ 655 行 D-pad 预设（与 653 的 R 摇杆对应）。
-- ★★ 与 430 行的 ResolveVirtualControls 分支完全对称 ✓
			controlId = controlId - VIRTUAL_CONTROL_INV_UP + CONTROL_PRESET_DPAD_UP
		end
	elseif IsVCtrlInvAct(controlId) then
		--Classic mapping for 2 and 3, DPad for 4 to 7, modifier button for 6 and 7
		needsmodifier = scheme == 6 or scheme == 7
		if scheme <= 3 then
			controlId = RemapTo_CONTROL_INVENTORY_ACTIONS[controlId - VIRTUAL_CONTROL_INV_ACTION_UP]
		else
			controlId = controlId - VIRTUAL_CONTROL_INV_ACTION_UP + CONTROL_PRESET_DPAD_UP
		end
	elseif IsVCtrlStrafe(controlId) then
		--Unmodified R.Stick for all schemes
		needsmodifier = false
		controlId = controlId - VIRTUAL_CONTROL_STRAFE_UP + CONTROL_PRESET_RSTICK_UP
	else
		return ""
	end

	local text = self:GetLocalizedControl(deviceId, controlId, use_default_mapping, use_control_mapper)
-- ★★★ 674-676 的修饰键前缀拼接。
--   if needsmodifier then
--       text = self:GetLocalizedControl(..., CONTROL_CAM_AND_INV_MODIFIER, ...)
--              .." + "..text
--   ⇒ ★ 显示成「修饰键 + R 摇杆」。
-- ★★ 与 607-611 的多输入拼接格式一致（" + " 分隔）✓
-- ⚠ 但 617 侧的 needsmodifier 计算（646-651）与 339 侧（415）不同，
--   ⇒ 可能显示「有修饰键」但实际不生效（或反之）。
--   ⇒ 见 617 行完整分析。
	if needsmodifier then
		text = self:GetLocalizedControl(deviceId, CONTROL_CAM_AND_INV_MODIFIER, use_default_mapping, use_control_mapper).." + "..text
	end
	return text
end

-- ══════════════════════════════════════════════════════════════
-- ★★ 【GetLocalizedVirtualDirectionalControl】681-710
-- 【★ 它的存在理由（680 行原注释）】
--   "--V2C: used for rstick/dpad virtual controls with or without modifier button held"
-- ★★ 为什么需要这个「第三个」本地化函数？
--   因为「按住修饰键时 R 摇杆是什么」是**运行时状态**：
--     · 不按 → 显示「R 摇杆」
--     · 按了 → 显示「修饰键 + 摄像机」
--   ⇒ 617 只能显示**静态**的方案绑定；
--     本函数能显示**当前**状态。
-- 【★ 参数 use_modifier 是调用方告诉的】
--   本函数**不自己判断**修饰键状态，只接收。
--   ⇒ 纯函数 ✓ 可测试。
-- ★★ 682 行的 GetLocalizedControl 调用与 598 相同
--   但参数是 modifierId 而非 controlId。
--V2C: used for rstick/dpad virtual controls with or without modifier button held
function Input:GetLocalizedVirtualDirectionalControl(deviceId, controlIdStr, modifierId, use_modifier)
	local device, numInputs, input1, input2, input3, input4, intParam = TheInputProxy:GetLocalizedControl(deviceId, modifierId, false, true)
	if device == nil then
		return ""
	elseif numInputs < 1 and use_modifier then
		return ""
	end

	local text = STRINGS.UI.CONTROLSSCREEN.INPUTS[device][controlIdStr]
	if text == nil then
		return ""
	end

	if use_modifier then
		local inputs = { input1, input2, input3, input4 }
		local modifiertext = STRINGS.UI.CONTROLSSCREEN.INPUTS[device][input1]
		-- concatenate the inputs
		for idx = 2, numInputs do
			modifiertext = modifiertext.." + "..STRINGS.UI.CONTROLSSCREEN.INPUTS[device][inputs[idx]]
		end

		-- process string format params if there are any
		if intParam then
			modifiertext = string.format(modifiertext, intParam)
		end

		text = modifiertext.." + "..text
	end
	return text
end

-- ══════════════════════════════════════════════════════════════
-- ★★★ 【GetControlIsMouseWheel】—— ⚠⚠ 最脆弱的一个判定
-- 【★ 实现（712-719）】
--   if self:ControllerAttached() then return false end
--   local localized = self:GetLocalizedControl(0, controlId)
--   local stringtable = STRINGS.UI.CONTROLSSCREEN.INPUTS[1]
--   return localized == stringtable[1003] or localized == stringtable[1004]
-- 【★ 它在做什么】
--   「这个控制码当前绑的是不是鼠标滚轮？」
-- 【⚠⚠⚠ 方法：通过比较本地化字符串】
--   ⇒ ★★★ 判定逻辑是「本地化后的文本 == 「鼠标滚轮上/下」的文本」。
-- 【⚠⚠⚠ 为什么这极其脆弱】
--   ① ★ **语言包依赖**：中文/英文的「鼠标滚轮」文本不同，
--      但 stringtable 也随语言变，所以理论上匹配 ✓；
--      ★ 但 1003/1004 是**魔数索引**，来自 UI 的字符串表。
--   ② ★★ **玩家改键会破坏判定**：若玩家把「滚轮上」改绑到别的键，
--      localized 就不再等于滚轮文本 ⇒ 返回 false ✓（正确）。
--      ★ 但反过来：若玩家把别的键绑成「滚轮」的样子…… 不可能。
--   ③ ★★ **默认绑定依赖**：默认绑定下才匹配。
--   ④ ⚠⚠ **1003/1004 无命名**：改动字符串表会静默破坏。
-- 【★ 消费方：frontend.lua:789/800 的滚动节流】
--   若判定错误 → 鼠标滚轮会用 0.05 的重复率或 0 的重复率
--   ⇒ 表现为「滚一下滚一屏」或「滚不动」。
-- ⇒⇒ 标注为 ⚠⚠⚠ 疑似缺陷（靠本地化字符串做行为判定）。**不改代码**。
--─────────────────────────────────────────────────────────────
function Input:GetControlIsMouseWheel(controlId)
    if self:ControllerAttached() then
        return false
    end
-- ⚠ 716 行 GetLocalizedControl(0, controlId) —— 设备号写死 0。
-- ★★ 0 是键鼠设备（呼应 31 行跳过 0 号）。
-- ★ 713 行的 `if self:ControllerAttached() then return false end`
--   ⇒ 手柄玩家直接返回 false（手柄没有滚轮）✓
-- ⇒ 714-715 行是快速路径，避免手柄玩家走慢路径。
    local localized = self:GetLocalizedControl(0, controlId)
-- ★★ `STRINGS.UI.CONTROLSSCREEN.INPUTS[1]` —— 设备 1 的字符串表。
-- ⚠⚠ 注意这里取 [1]，而 609-611 取 [device]（device 来自 C++）。
--   ⇒ ★★ 索引不一致！716 行的 device 可能是别的值，但这里写死 1。
--   ⇒ ★ 但因为 607 是 `INPUTS[device][input1]`，
--     而本函数比较的是 `localized`（已用真实 device 取文本）
--     与 `stringtable[1003]`（用写死的 1 取）——
--   ⇒★★ ★ 若是其它设备（device ≠ 1）的字符串表里恰好也有同样的文本，
--     就会**误判**。
--   ⇒ 标注为「索引不一致的潜在误判」，与 712 的脆弱性叠加。
    local stringtable = STRINGS.UI.CONTROLSSCREEN.INPUTS[1]
    return localized == stringtable[1003] or localized == stringtable[1004]
end

-- ★ GetStringIsButtonImage —— 「这个字符串是手柄图标吗」。
-- ★★ 722-726 行查四张表（2/4/5/7/8）—— 各种手柄类型的图标表。
-- ★★ 用 or 串起 5 次 table.contains —— 无缓存，
--   但只在渲染设置界面时调用，频率低 ✓
-- ★ 消费者：按键设置界面（决定显示文字还是图标）。
function Input:GetStringIsButtonImage(str)
    return table.contains(STRINGS.UI.CONTROLSSCREEN.INPUTS[2], str)
        or table.contains(STRINGS.UI.CONTROLSSCREEN.INPUTS[4], str)
        or table.contains(STRINGS.UI.CONTROLSSCREEN.INPUTS[5], str)
        or table.contains(STRINGS.UI.CONTROLSSCREEN.INPUTS[7], str)
        or table.contains(STRINGS.UI.CONTROLSSCREEN.INPUTS[8], str)
end

-- ★ PlatformUsesVirtualKeyboard —— 「这个平台用屏幕键盘吗」。
--   return IsConsole() or IsSteamDeck()
-- ★★ 只有主机与 Steam Deck（触屏）用虚拟键盘。
--   PC 用真实键盘 ⇒ 不用。
-- ★ 消费者：widgets/textedit.lua（决定要不要弹虚拟键盘）。
function Input:PlatformUsesVirtualKeyboard()
	if IsConsole() or IsSteamDeck() then
		return true
	end

	return false
end


-- ══════════════════════════════════════════════════════════════
-- ★★★ 【全局桥接】738-780 —— C++ 与 Lua 的最后一道接缝
--
-- 【★ 740 行：实例化点（★ 为什么在文件末尾而不是开头？）】
--   TheInput = Input()
--   ★★★ 原因：EventProcessor / Class 必须在 require 完成后才可用。
--     更重要的是：**实例化会调用构造函数**（27 行 DisableAllControllers，
--     20-22 行读 TheNet），这些依赖必须在所有 require 之后。
--   ⇒ 「全局单例在文件末尾创建」是 Lua 的常见惯例。
--
-- 【★ 九个全局桥接函数（742-778）】
--  742  OnFloatingTextInputDismissed   → TheInput:OnFloatingTextInputDismissed
--  746  OnPosition(x, y)               → TheInput:UpdatePosition
--  751  OnControl(control, dv, av)     → TheInput:OnControl ★ 仲裁入口
--  756  OnMouseButton(...)             → TheInput:OnMouseButton
--  760  OnMouseMove(x, y)              → TheInput:OnMouseMove
--  764  OnInputKey(key, is_up)         → TheInput:OnRawKey
--  768  OnInputText(text)              → TheInput:OnText
--  772  OnGesture(gesture)             → TheInput:OnGesture
--  776  OnControlMapped(...)           → TheInput:OnControlMapped
-- 【★ 为什么需要这一层桥接？】
--   C++ 侧调用的是**全局函数**（固定的 C 绑定面），
--   而 Input 是**实例方法**。⇒ 必须有一层「全局 → 实例」的转发。
-- ★★ 这层桥接是「Lua 对象系统」与「C 的全局命名空间」的接缝。
--   同模式见 frontend.lua:1434 OnSaveLoadError。
-- 【★★ 750/754 的两个 ValidateLineNumber】
--   ★ 框住 751 行的 OnControl 全局函数。
--   ★ 与 162/171（Input:OnControl 方法）呼应：
--     **仲裁链的最后一跳也有哨兵保护**。
--─────────────────────────────────────────────────────────────
---------------- Globals

-- ★★★★ TheInput = Input() —— 唯一的实例化点。
-- 【★★ 为什么放在文件末尾（780 行 return 之前）？】
--   ① Class / EventProcessor 必须在 require 之后才可用；
--   ② 构造函数会调用 TheNet:IsDedicated()（22 行）与
--      TheInputProxy（27/31 行）—— 这些全局必须已就绪。
--   ③ ★ 若在文件开头创建，而某处 require 又反过来依赖 input，
--      就会拿到未初始化的实例。
-- 【★ 4-6 行的历史包袱】
--   TheInput 是「正确的全局」，但 Input（8 行）也仍是全局。
--   ⇒ 全局表里有两个名字指向同一个东西。
TheInput = Input()

-- ★★ 全局 OnFloatingTextInputDismissed —— C++ 侧调用点。
--   原注释 "-- called from C++" ★ 直接写在函数上方。
-- ★★ 这种「C 绑定点」的注释很有价值：
--   它明确告诉读者「这个函数不能改名/改签名」。
-- ★ 与 200 行的方法同名（不同层级）。
function OnFloatingTextInputDismissed() -- called from C++
    TheInput:OnFloatingTextInputDismissed()
end

-- ★★ 全局 OnPosition —— 鼠标移动（C++ 调用）。
--   → TheInput:UpdatePosition（155 行）→ self.position 事件
-- ★★ 注意**不**走 TheFrontEnd（那是 OnMouseMove 760）。
--   ⇒ 两条鼠标移动通路在 C 侧就已经分开。
function OnPosition(x, y)
    TheInput:UpdatePosition(x, y)
end

-- ★ ValidateLineNumber(750) —— 框住全局 OnControl。
-- ★★ 与 162 行的哨兵成对：
--   162/171 框住 **Input:OnControl 方法**
--   750/754 框住 **全局 OnControl 转发函数**
--   ⇒★★ 仲裁链的**最后两跳**都有哨兵。
--   ⇒ 说明 Klei 对这个入口极其重视（改过很多次）。
ValidateLineNumber(750)
-- ★★ 全局 OnControl —— ★ C++ 输入的最终入口。
--   → TheInput:OnControl（163）★ 仲裁在这里
-- 【★ 与 163 的签名完全一致】
--   control, digitalvalue, analogvalue 三个参数全传 ✓
--   （对比 166 行 UI 调用只传两个 —— 那是另一个调用点）
-- ★★ 751 是「C++ → Lua」的边界，753 是「回到 Lua」的边界。
function OnControl(control, digitalvalue, analogvalue)
    TheInput:OnControl(control, digitalvalue, analogvalue)
end
-- 第二个 ValidateLineNumber，框住全局 OnControl 结束（754 = end 行）。
ValidateLineNumber(754)

-- ★★ 全局 OnMouseButton —— ★★ 注意第三个参数名是 is_up。
--   原注释之外的线索：`is_up`（抬起）而不是 `down`（按下）。
--   ⚠ 参数名与 179 行的 down **相反**！
--   757 行直接 `TheInput:OnMouseButton(button, is_up, x, y)`
--   ⇒ ⚠⚠ **疑似缺陷：参数名颠倒导致语义颠倒**？
--   推理：757 行是**位置传参**（is_up 传给 down 形参），
--     顺序正确、语义不变 ✓。只是变量名误导。
--   ⇒⇒ 重新评估：**不是缺陷**，只是命名不统一。
--     但它极易让人误读（以为 down 被传成了 not down）。
--   ⇒★ 同理 764 行的 is_up、766 行的 is_up 都传给了 down 形参。
--   ⇒ **这是全文件统一的命名风格**（C 侧叫 is_up，Lua 侧叫 down）。
--   ⇒ 标注为「跨语言命名不一致，易误读」而非缺陷。
function OnMouseButton(button, is_up, x, y)
    TheInput:OnMouseButton(button, is_up, x, y)
end

-- ★ 全局 OnMouseMove —— → TheInput:OnMouseMove（173）。
-- ★★ 与 746 OnPosition 是**两个不同的全局**（见 738 段分析）。
function OnMouseMove(x, y)
    TheInput:OnMouseMove(x, y)
end

-- ★ 全局 OnInputKey —— → TheInput:OnRawKey（186）。
-- ★★ 参数名 is_up 同 756 行，Lua 侧叫 down。命名不统一。
function OnInputKey(key, is_up)
    TheInput:OnRawKey(key, is_up)
end

-- ★ 全局 OnInputText —— → TheInput:OnText（195）。
-- ★★ 这是 IME 文本的 C 入口。
function OnInputText(text)
    TheInput:OnText(text)
end

-- ★ 全局 OnGesture —— → TheInput:OnGesture（233）。
-- ⚠ 对应 233 的 AddGestureHandler 全库无调用者 ⇒ 疑似死链路。
function OnGesture(gesture)
    TheInput:OnGesture(gesture)
end

-- ★ 全局 OnControlMapped —— → TheInput:OnControlMapped（237）。
-- ★★ 键位映射变更的 C 入口。
function OnControlMapped(deviceId, controlId, inputId, hasChanged)
    TheInput:OnControlMapped(deviceId, controlId, inputId, hasChanged)
end

-- ★ return Input —— 导出类本身。
-- ★★ 与 TheInput（740）不同：返回的是**类**，不是实例。
--   ⇒ 其它文件可以 `local Input = require("input")` 做继承。
--   ⇒ ★ 但 TheInput 仍是全局实例 —— 两种访问方式并存。
return Input
