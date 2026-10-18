--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：containers.lua（2504 行）
-- 模块：容器系统 / 全局容器「配置表」（Container Params Registry）
--
-- ★★★ 本文件的身份：一本**静态数据字典**，不是逻辑实现。
--   它导出 `containers` 一张表，里面两样东西：
--     ① containers.params —— 以 prefab 名为键的**容器蓝图**（约 90 条）；
--     ② containers.widgetsetup(container, prefab, data) —— 把蓝图
--        灌进组件的**唯一入口**。
--   全文件 2504 行里**没有一行是「运行时的容器逻辑」**，全部是
--   `params.<名字> = { widget = {...}, type = "...", ... }` 与
--   `function params.<名字>.itemtestfn(...)` 的声明。
--   ⇒ 真正的逻辑全在 components/container.lua（服务端组件）与
--     components/container_replica.lua（客户端镜像）。
--
-- ★★ 全文件最重要的认知一：**容器没有「类」，只有「类型字符串」**。
--   任务描述里提到的 `CONST.GRID` / `STACKABLE` / `FRIDGE` / `CHEST`
--   这些「容器类型常量」——★ grep 核实：本文件**从未出现 `CONST.`**
--   （零命中），也不存在名为 Container 的类。同名的三个常量都别处：
--     · constants.lua:1440  GRID = 3  →  属于 LAYOUT 表，
--       是**世界生成布局**（3 = 网格），与容器毫无关系；
--     · constants.lua:669  ITEMTAG.STACKABLE = "stackable"  →  物品标签；
--     · constants.lua:1972 UPGRADETYPES.CHEST = "chest"  →  箱子升级动画类型。
--   容器真正的「类型」就是本文件里的裸字符串，对应 containers.lua 第 18 行
--   `self.type`。全文件 type 取值统计（grep 核实）：
--     "chest"×24  "cooker"×21  "pack"×6  "hand_inv"×6
--     "side_inv_behind"×3  "backpack"×2  "inv"×1  "top_rack"×1
--     另有动态类型：第 2282 行 typefn 返回的 "chest_addon"。
--   ★ 这些字符串的唯一用途有且只有三处（见下），不是标签系统。
--
-- ★★ 全文件最重要的认知二：type 字符串只被当作「**UI 挂载点选择器**」用。
--   grep 核实全部消费点只有 4 个文件：
--     · components/container.lua:625 —— Open 时关掉「同 prefab 或同 type」
--       的其他已开容器（同一时间只允许开一个同类）；
--     · screens/playerhud.lua:395-400 —— 决定 ContainerWidget 挂到 HUD 的
--       哪个 root（容器出现在屏幕的哪个方位）；
--     · components/inventory.lua:2120 —— CloseAllChestContainers 只关
--       type == "chest" 的；
--     · prefabs/storage_robot_common.lua:78 / prefabs/wobycommon.lua:552
--       —— 白名单只有 { "chest", "pack" }。
--   ⇒ **type 不参与物品筛选，也不参与容量计算**。
--     「冰箱」之所以只能装食物，靠的是 itemtestfn（第 1019 行），
--     **不是**因为它的 type 叫 "chest"。
--
-- ★★ 全文件最重要的认知三：物品筛选规则**只有两个**入口，
--   而第二个在本文件中**完全不存在**（★ grep 核实全库零命中）：
--     ① itemtestfn(container, item, slot) —— 本文件 40+ 处声明，
--       被 components/container.lua:295 的 CanTakeItemInSlot 调用；
--     ② globaltestfn —— **不存在**。全库 grep `globaltestfn` 零命中。
--   同样地，任务描述提到的 ★ rangecheck / maxweight 在容器系统里
--   **都不存在**：
--     · rangecheck —— grep 全库只在 actions.lua 里以 rangecheckfn 形式存在
--       （如 actions.lua:370 DefaultRangeCheck），是**动作距离**判定，
--       容器不引用它；
--     · maxweight —— grep 全库只在 loadingtipsdata.lua:63 出现（加载提示权重），
--       容器**没有重量上限**这一概念。
--     容器真正的「限制」是 slots 数量（numslots）与 acceptsstacks，
--     见 components/container.lua:107 IsFull / 322 AcceptsStacks。
--   ⇒ 那些能塞进**无限多物品**的容器（冰箱/箱子）不是靠 maxweight，
--     而是因为 numslots 固定、而每摞的 stacksize 由 stackable.maxsize 决定。
--
-- ★★ 全文件最重要的认知四：itemtestfn 的统一表达范式。
--   本文件 40 多个 itemtestfn 虽然内容各异，但**骨架完全一致**：
--     function params.X.itemtestfn(container, item, slot)  -- 三参约定
--         return <标签判定> and <额外约束>  -- 单行布尔表达式
--     end
--   签名固定为 (container, item, slot)——注意**第一个参数是 container 自己**：
--   因为 components/container.lua:295 写成 `self:itemtestfn(item, slot)`，
--   冒号调用把 self 补到第一个形参。所以本文件里写 `container.inst:HasTag(...)`
--   时，`container` 就是那个组件。
--   ★ 冰箱（第 1019 行）是**四层漏斗**：
--     白名单标签 icebox_valid/inventoryitemtemperature → 直接放行；
--     再要求有保鲜状态 fresh/stale/spoiled → 否则拒；
--     再排除 smallcreature → 最后遍历 FOODTYPE 找 edible_<TYPE>。
--   这就是「冰箱只放食物」在通用语言里的表达：**没有冰箱这个类型，
--   只有一条标签组合判定**。新增一个「肥料箱」只需再写一条同形状的闭包。
--   ★ 而 priorityfn（第 1632 行等）是 itemtestfn 的**同函数别名**，
--     但语义相反：itemtestfn 决定「能不能放」，priorityfn 决定
--     「在专用容器（弹药包这类）里优先往哪放」，见 components/container.lua:319。
--
-- ★★ 全文件最重要的认知五：开合（Open/Close）**不在本文件**。
--   本文件只提供一个与开合相关的配置项：openlimit（见下）。
--   · openlimit —— 「最多允许多人同时打开」，grep 核实 9 处声明；
--     判定在 components/container.lua:735 Container:CanOpen()，
--     而 CanOpen 只被 actions.lua:1095/2484/2506 与 components/slingshotmods.lua:148
--     调用——**Open 自身并不检查 CanOpen**，靠动作层守门。
--   · canbeopened —— 声明在 components/container.lua:31，由 setter 转成
--     **反向 netvar** container._cannotbeopened（container_replica.lua:6/277），
--     即「服务端存的是不能开，客户端读出来取反」。
--   · ⚠ 任务描述提到的 `Toggle` 方法：★ grep 核实 containers.lua 与
--     components/container.lua 中**均不存在** Toggle，全库容器相关文件零命中。
--     开合是 Open/Close 两个独立动作，切换逻辑在 actions.lua 的
--     OPEN/OPENCONTAINER 动作里。
--   · ⚠ 任务描述提到的 `IsVisible`：★ grep 核实容器三文件中**不存在**
--     IsVisible。对应的查询是 components/container.lua:723 IsOpen、
--     727 IsOpenedBy、731 IsOpenedByOthers。
--
-- 关键符号：containers.params（蓝图字典）, containers.widgetsetup（灌入入口）,
--   containers.MAXITEMSLOTS（全局最大槽位数）, params.X.widget.slotpos,
--   params.X.widget.slotbg, animbank/animbuild/animloop, side_align_tip,
--   params.X.itemtestfn, params.X.priorityfn, widget.buttoninfo.fn/validfn,
--   widget.slotposfn/slotscalefn/animfn/posfn, type, typefn, openlimit,
--   acceptsstacks, usespecificslotsforitems, issidewidget, excludefromcrafting,
--   lowpriorityselection, opensound/closesound, animbank_upgraded
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：
--   ★★ 参见 components/container.lua:86 Container:WidgetSetup —— 唯一调用点
--   ★★ 参见 components/container.lua:9-17 —— 本文件 widgetsetup 的服务端侧
--   ★★ 参见 components/container.lua:269 CanTakeItemInSlot —— itemtestfn 调用点
--   ★★ 参见 components/container.lua:735 CanOpen —— openlimit 的唯一判定
--   参见 components/container_replica.lua:232 WidgetSetup —— 客户端侧同构入口
--   参见 components/container_replica.lua:6-8 —— 三条反向 netvar 的定义
--   参见 prefabs/container_classified.lua:1057 —— MAXITEMSLOTS 的消费点
--   参见 constants.lua:650 MAXITEMSLOTS = 15 —— 物品栏的槽位上限（对照）
--   参见 constants.lua:2928 CONTAINER_AUTOCLOSE_DISTANCE = 3 —— 自动关闭距离
--   参见 constants.lua:2022 FOODTYPE —— 冰箱 edible_ 判定的枚举来源
--   参见 constants.lua:2049 FOODGROUP.OMNI —— 胡子袋 edible_ 判定的枚举来源
--   参见 screens/playerhud.lua:395-400 —— type 字符串的 UI 挂载点
--   参见 components/inventory.lua:2120 CloseAllChestContainers —— type=="chest"
--   参见 prefabs/storage_robot_common.lua:78 ALLOWED_CONTAINER_TYPES
--   参见 components/inventory.lua —— 容器的「近亲」，GetOverflowContainer 一侧
--============================================================
-- 【模块头】两个 require 揭示了本文件的真实身份——它是个「依赖两个 UI 模块的**数据表**」。
--   cooking.lua 提供 cooking.IsCookingIngredient（第 374 行被锅的 itemtestfn 调用）；
--   RiftConfirmScreen 用于「月影裂隙献祭」的二次确认弹窗（第 631 行）。
--   ★ 注意：RiftConfirmScreen 是 screens/redux/ 下的 UI 模块，**说明本文件里混进了 UI 逻辑**——
--     这正是「蓝图可以带按钮回调」的直接后果（widget.buttoninfo.fn）。
local cooking = require("cooking")
local RiftConfirmScreen = require("screens/redux/riftconfirmscreen")

-- 【全局状态】params 是本文件唯一的产出（对外表现为 containers.params）。
--   它以「prefab 名」为键；widgetsetup 第 10 行用 `params[prefab or container.inst.prefab]` 查表。
--   ★ 这意味着**改 prefab 名就会查不到蓝图**——这是模组最常见的容器失效原因。
local params = {}
-- MAXITEMSLOTS 初值 0；文件末尾第 2498-2500 行会遍历所有 params 求真实最大值。
--   ★ 它的唯一消费者是 prefabs/container_classified.lua:1057，用来预分配 net_entity 变量池：
--     `for i = 1, containers.MAXITEMSLOTS do table.insert(inst._itemspool, net_entity(...))`。
--   ⇒ 设计含义：**槽位上限是全局共享的、启动时一次性定死的网络带宽预算**。
--     一个容器想开更多槽位，就必须抬高全局 MAXITEMSLOTS，代价是所有容器都多背一份 netvar。
--     这就是为什么 bookstation（4x5=20 槽）与 wx78_backupbody（5x3=15 槽）
--     会把整个游戏的容器网络开销顶上去。
local containers = { MAXITEMSLOTS = 0 }

containers.params = params

-- 【★★ 核心入口】containers.widgetsetup 是本文件**唯一的函数**（其余全是 params 声明）。
--   它做三件事：查表 → 逐字段拷贝 → 设置槽位数。
--   ★ 设计要点：拷贝是**浅拷贝**（`container[k] = v`），所以 container.type 是字符串、
--     container.itemtestfn 是函数指针、container.widget 是**共享的同一张表**。
--     推论：多个同类容器（如两只冰柜）的 self.widget 指向同一个表，
--     谁也别想单独改 widget 里的字段——要改必须改 params 源头。
--   ★ 第二个设计要点：**prefab 名是主键**。prefab 参数优先于 inst.prefab，
--     这样同一个 prefab 可以有不同蓝图（见 prefabs/beard_sack.lua:39-50 的 fn_mastersim）。
function containers.widgetsetup(container, prefab, data)
-- data 优先：传入了自定义表就用它，否则按 prefab 名查全局 params。
--   ★ data 的存在让模组可以**完全绕过本文件**自定义容器布局，
--     这是本文件唯一的「扩展点」，也是最常用的模组 hook。
    local t = data or params[prefab or container.inst.prefab]
    if t ~= nil then
-- 浅拷贝循环：把蓝图里**每一个**键都写成容器的属性。
--   ⚠ 这里没有任何过滤——蓝图里写什么就灌什么，包括注释掉的字段也无所谓（因为它们不存在）。
--   ⚠ 推论：蓝图里加一个 components/container.lua 不认识的键，**不会报错**，
--     只会静默地成为一个无人消费的死字段（例：第 1373 行被注释掉的 excludefromcrafting）。
        for k, v in pairs(t) do
            container[k] = v
        end
-- ★ 槽位数来源：优先 widget.numslots，否则数 slotpos 数组长度，都没有则 0。
--   · numslots 通常是**动态**容器用的（如 wx78_inventorycontainer 需要 1，但显示 1 个格子）；
--   · slotpos 是**静态**蓝图的主力（绝大多数容器靠数坐标数组）。
--   ⚠ 潜在坑：第 248 行的 params.meatrack_hermit 写了 `slotpos = { Vector3(-2, 18, 0) }`
--     却**没有 numslots**，只能靠数出 1 个槽——若美术改坐标数量，槽位会静默跟着变。
--   ⇒ 推论：**槽位数是 UI 布局的副产品**，不是独立配置。这是本设计最脆弱的一环。
		container:SetNumSlots(container.widget.numslots or (container.widget.slotpos and #container.widget.slotpos or 0))
    end
end

-- ── 区块分隔注释的固定格式：----------  / --[[ 名字 ]] / ----------
--   全文 50 多个这样的区块，等于一份「容器蓝图目录」。
--------------------------------------------------------------------------
--[[ backpack ]]
--------------------------------------------------------------------------

-- 【backpack 背包】2x4 = 8 格。type = "pack" + issidewidget = true 是背包类容器的标记。
--   ★ 与「箱子类」（type="chest"）的关键区别：issidewidget 让 UI 挂在屏幕侧面
--     而不是中央（见 screens/playerhud.lua:387 OpenContainerWidget 的 side 分支）。
params.backpack =
-- ★ widget 表是「UI 蓝图」的容器：以下字段全集 ——
--   · slotpos   —— 每个槽的绝对屏幕坐标（Vector3 数组）
--   · slotbg    —— 每个槽的底纹贴图（table 数组，与 slotpos 一一对应）
--   · animbank/animbuild —— UI 贴图库名与构建名（客户端 C++ 侧读取）
--   · animloop  —— 开门动画是否循环播放
--   · animbank_upgraded/animbuild_upgraded —— 升级态贴图
--   · pos       —— UI 整体位置偏移
--   · posfn     —— 动态 pos（wx78 用）
--   · side_align_tip / top_align_tip / bottom_align_tip —— 提示条对齐距离
--   · side_align_tip_fn / top_align_tip_fn / bottom_align_tip_fn —— 动态版
--   · slotscale / slotscalefn —— 格子缩放
--   · slothighlightscale / slothighlightscalefn —— 高亮缩放
--   · slotposfn —— 动态槽位坐标（wx78 用）
--   · animfn    —— 动态贴图名（wx78 用）
--   · opensound / closesound —— UI 开合音效
--   · buttoninfo —— 按钮（text / position / fn / validfn）
--   ★ 这些字段**全部只被 UI 层（widgets/containerwidget.lua）消费**，
--     容器逻辑（components/container.lua）一个都不读。
--     ⇒ 这是理解本文件的关键：widget 是纯表现层配置。
{
    widget =
    {
-- slotpos：**绝对屏幕坐标**（单位是 HUD 像素），不是相对容器的局部坐标。
--   这一点对理解本文件至关重要：蓝图作者是在**摆 UI**，不是在摆物品。
        slotpos = {},
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
        animbank = "ui_backpack_2x4",
-- ★ animbank 与 animbuild 同名：bank 是「贴图库」，build 是「库内构建名」。
--   两者通常相同，UI 层用 build 从 bank 里取出可渲染的实例。
        animbuild = "ui_backpack_2x4",
-- 被注释掉的旧坐标——保留了美术调位置的痕迹，是这类文件的常态。
        --pos = Vector3(-5, -70, 0),
-- ★ pos.y 从 -70 改成 -80：背包 UI 相对角色立绘下移了 10 像素。
--   为什么这类微调要留注释？因为**布局回归（layout regression）很难用逻辑解释**，
--   美术改一版就得记一笔，否则下一个改 UI 的人会把箱子里的格子挤到立绘上。
        pos = Vector3(-5, -80, 0),        
    },
-- issidewidget = true → UI 出现在角色旁边而非屏幕中央（背包/背包类专属）。
--   ★ 消费点：components/container.lua:637 Open 时作为第二参数传给 HUD:OpenContainer。
-- ★ 容器组件里对应的字段名 issidewidget（无下划线）——蓝图到组件会做重命名。
    issidewidget = true,
-- type = "pack"
--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "pack",
-- 【★ openlimit】openlimit = 1 → **同一个人同时只能开一个背包**。
--   注意语义：它限的是 opencount（同时开启人数），不是「一生只能开一次」。
--   · 判定在 components/container.lua:735 CanOpen；
--   · ★ 但 Open 自身（第 617 行）**不检查 CanOpen**，守门在 actions.lua:1095。
--     这是一条「约定优于实现」的边界：绕过动作直接调 container:Open 能开出第二个。
    openlimit = 1,
}

-- 用 for 循环批量生成 4 行 × 2 列 = 8 个槽位坐标，而不是手写 8 行 Vector3。
--   ★ 这是本文件的核心风格：**能算出来的坐标就算出来**。
--     公式 `-75 * y + 114` 里 -75 是行高（像素），114 是首行偏移。
--   ⇒ 推论：想让背包变成 3 行，只要把 `0, 3` 改成 `0, 2` 并换 animbank 即可。
--     代价：美术资源 ui_backpack_2x4 必须匹配，否则格子会画到图外面。
for y = 0, 3 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.backpack.widget.slotpos, Vector3(-162, -75 * y + 114, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.backpack.widget.slotpos, Vector3(-162 + 75, -75 * y + 114, 0))
-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。
end

-- ⚠ 疑似缺陷：params.icepack = params.backpack —— 这是**引用赋值**而非 deepcopy。
--   推理依据：① 第 116/128/678/944/950/2297 行用的是 deepcopy，
--     说明作者清楚两者的区别，这里是刻意的还是手滑无从判断；
--   ② 后果明确：params.icepack 与 params.backpack 指向**同一张表**，
--     任何对 icepack 的字段修改都会**同时改掉 backpack**；
--   ③ 当前代码里没有任何地方修改 icepack 的字段（grep 核实），所以暂时无害；
--   ④ 讽刺的是 icepack（冰袋）本该有自己的美术——spicepack（第 49 行）就单独定义了
--     用 ui_icepack_2x3，说明「冰袋 2x3」这套美术是存在的，只是 icepack 没去用。
--   ⇒ 判断：更像是「icepack 复用 backpack 布局」的有意为之，而非 bug；
--     但它是一个**共享可变状态**的隐患，模组若写 containers.params.icepack.widget.animbank = "..."
--     会连带把玩家的背包外观改掉。此处仅标注，不改代码。
params.icepack = params.backpack

-- ── spicepack（香料包）区块 ──
--------------------------------------------------------------------------
--[[ spicepack ]]
--------------------------------------------------------------------------

-- 香料包：2x3 = 6 格，比背包少 2 格，美术是 ui_icepack_2x3。
--   ★ 注意它和 beargerfur_sack（第 1914 行）**共用同一张美术图** ui_icepack_2x3，
--     说明美术资源是跨 prefab 复用的，animbank 不是「一个容器一张图」。
params.spicepack =
{
    widget =
    {
-- ★ 槽位坐标数组：每个 Vector3 是**一个格子在屏幕上的绝对位置**。
--   ★★ 数组顺序 = 槽位编号顺序（slot 1 = 第一个坐标）。改顺序就改了物品编号，
--     而存档按编号还原（components/container.lua:996 OnLoad），所以这是**存档兼容雷区**。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_icepack_2x3"。
        animbank = "ui_icepack_2x3",
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
        animbuild = "ui_icepack_2x3",
-- ★ UI 整体位置偏移（屏幕像素）。正值=右/上，负值=左/下。
--   ★ 与 slotpos 的关系：slotpos 是**绝对坐标**，pos 是**整体偏移**，二者叠加生效。
        pos = Vector3(-5, -70, 0),
    },
-- ★ UI 是否挂在屏幕**侧边**（背包类）而非中央（箱子类）。
--   消费点：components/container.lua:637 作为第二参数传给 doer.HUD:OpenContainer。
    issidewidget = true,
-- type = "pack"
--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "pack",
-- ★ 同时开启人数上限（不是「一生只能开一次」）。
--   判定在 components/container.lua:735 CanOpen；★ 但 Open 自身不检查它，
--   守门在 actions.lua:1095 —— 这是「约定优于实现」的边界。
    openlimit = 1,
}

-- 3 行 × 2 列 = 6 槽；首行偏移 75（与背包的 114 不同，因为美术高度不同）。
for y = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.spicepack.widget.slotpos, Vector3(-162, -75 * y + 75, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.spicepack.widget.slotpos, Vector3(-162 + 75, -75 * y + 75, 0))
-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。
end

-- ── chester（ Chester 箱子）区块 ──
--------------------------------------------------------------------------
--[[ chester ]]
--------------------------------------------------------------------------

-- 【chester】3x3 = 9 格，type = "chest"。
--   ★ side_align_tip = 160：这是**侧边提示条的对齐距离**，不是槽位坐标。
--     当屏幕空间不够时，提示文字（物品名/操作提示）会被推到距容器 160 像素的侧边。
--   参见 components/container_replica.lua 与 widgets/containerwidget.lua 中对 *_align_tip 的消费。
params.chester =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x3"。
        animbank = "ui_chest_3x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x3"。
        animbuild = "ui_chest_3x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 倒序双层循环：外层 y 从 2 到 0 递减（**从上往下**画），内层 x 从 0 到 2。
--   ★ 为什么倒序？因为 slotpos 的**插入顺序即槽位编号顺序**。
--     从上往下插入 = 玩家从上往下读格子编号，符合视觉直觉。
--   ⇒ 推论：槽位编号是「美术布局顺序」的函数，改美术顺序就改了物品编号，
--     这在存档兼容上是雷区（见 components/container.lua:996 OnLoad 直接按 k 还原）。
for y = 2, 0, -1 do
    for x = 0, 2 do
-- 坐标公式 `80 * x - 80 * 2 + 80`：把 x∈[0,2] 映射到 [-80, 0, 80]，间距 80。
--   ★ 写死 80*2 而不是 80*1.5，是因为 3 格居中需要偏移半格。
        table.insert(params.chester.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 80, 0))
    end
-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。
end

-- ── shadowchester（暗影 Chester）区块 ──
--------------------------------------------------------------------------
--[[ shadowchester ]]
--------------------------------------------------------------------------

-- ★ 原注释保留：「Deprecated; keep definition for dragonflychest, minotaurchest, mods,
--   and also for legacy save data」。
--   这行英文是**存档兼容的墓碑**：删掉它，老存档里的暗影 Chester 会查不到蓝图而崩。
--   ⇒ 这是本文件里「为什么死配置不能删」的最好教材，与第 34 行被注释的 skipautoclose
--     形成对照——**有的死代码要留（有兼容价值），有的死代码可删（无外部依赖）**。
--Deprecated; keep definition for dragonflychest, minotaurchest, mods,
--and also for legacy save data
-- 3 行 × 3 列，美术 ui_chester_shadow_3x4（名字里的 3x4 与 9 格不符，见下）。
params.shadowchester =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_chester_shadow_3x4"。
        animbank = "ui_chester_shadow_3x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chester_shadow_3x4"。
        animbuild = "ui_chester_shadow_3x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 220, 0)。
        pos = Vector3(0, 220, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ 这里 y 从 **2.5 递减到 -0.5**（步长 -1），即半格偏移——
--   对应美术是 4 行高的图（ui_chester_shadow_3x4），但槽位只有 3 行。
--   推论：格子坐标是「半像素级」精度的，说明这版美术的格子中心不在整像素上。
--   ⚠ 副作用：half-offset 让 (slot-1)%N 之类的列计算会得到小数，
--     参见第 2223 行 wx78_inventorycontainer_getcolumn 用 ((slot-1) % 5) + 1 还原列号。
for y = 2.5, -0.5, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.shadowchester.widget.slotpos, Vector3(75 * x - 75 * 2 + 75, 75 * y - 75 * 2 + 75, 0))
    end
-- 循环结束：已插入 **12 个** slotpos 坐标，本容器的 numslots 定为 12。
end

-- ★ deepcopy：月影传送门（shadow portal）的容器蓝图，与暗影 Chester 同布局但换美术。
--   animloop = true 让 UI 的开门动画**循环播放**（门是传送门，视觉上是漩涡）。
--   ⇒ 这是「用同一套布局做不同叙事」的典型：布局复用 + 美术/动画差异化。
params.shadow_container = deepcopy(params.shadowchester)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.shadow_container.widget.animbank = "ui_portal_shadow_3x4"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.shadow_container.widget.animbuild = "ui_portal_shadow_3x4"
-- ★ 开门动画是否**循环**播放（传送门漩涡这类用）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.shadow_container.widget.animloop = true

-- 【itemtestfn 范例 A：黑名单式】只排除 irreplaceable（不可替代的道具）。
--   ★ 签名 (container, item, slot) 是全文件铁律，
--     因为调用方 components/container.lua:295 写的是 `self:itemtestfn(item, slot)`。
--   ★ 语义：传送门什么都能装，除了「不可替代物」（防止把剧情道具扔进去丢失）。
function params.shadow_container.itemtestfn(container, item, slot)
    return not item:HasTag("irreplaceable")
end

-- ── rabbitkinghorn（兔子王之角）区块 ──
--------------------------------------------------------------------------
--[[ rabbitkinghorn ]]
--------------------------------------------------------------------------
-- 再次 deepcopy：兔子王之角的容器 = 传送门容器换美术。
--   ★ 第 131 行把 animloop 改回 nil：传送门要循环漩涡，牛角不需要。
--   ⇒ 微小的视觉差异就靠覆盖一个字段实现，这正是 deepcopy 模式的价值——
--     如果第 116 行用的是引用赋值，这里改 animloop 会连带改掉 shadow_container。
params.rabbitkinghorn_container = deepcopy(params.shadow_container)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.rabbitkinghorn_container.widget.animbank = "ui_portal_rabbitkinghorn_3x4"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.rabbitkinghorn_container.widget.animbuild = "ui_portal_rabbitkinghorn_3x4"
-- ★ 开门动画是否**循环**播放（传送门漩涡这类用）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.rabbitkinghorn_container.widget.animloop = nil

-- ── hutch 区块 ──
--------------------------------------------------------------------------
--[[ hutch ]]
--------------------------------------------------------------------------

-- ⚠ 疑似缺陷：params.hutch = params.chester —— 同样是**引用赋值**。
--   推理依据：同第 43 行 icepack 的问题，但这里**后果更确定**：
--   prefabs/chester.lua:389 与 :442 分别用 WidgetSetup("chester") 和
--   WidgetSetup("shadowchester")，而 hutch 是螃蟹的箱子——
--   grep 核实 hutch 在 prefabs 中的使用会让它拿到 chester 的同一张 widget 表。
--   由于第 15 行只是**读** widget.numslots / widget.slotpos，两条路径行为一致，
--   所以当前无害。仅标注共享可变状态的风险，不改代码。
params.hutch = params.chester


-- ── Woby（沃比，海牛坐骑）区块 ──
--------------------------------------------------------------------------
--[[ Woby ]]
--------------------------------------------------------------------------

-- 沃比的「小」形态容器：3x3 = 9 格。
params.wobysmall =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_woby_3x3"。
        animbank = "ui_woby_3x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_woby_3x3"。
        animbuild = "ui_woby_3x3",
-- pos.y 从 200 提到 330：与沃比晾肉架对齐（见第 182 行）。
		pos = Vector3(0, 330, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ 原注释保留（V2C = Vanilla-to-Content，社区反编译整理者的标记）：
--   「y pos used to be 200, moved to 330 to match woby_rack_container so that it scales
--    together in controller inventory screen. Shift all y-coords to account for this.
--    Art was also shifted accordingly. 0.6 is the base scale (in inventorybar).」
--   ★ 这段注释的价值在于它记录了**为什么连槽位坐标都要一起挪**：
--     挂载到骑乘界面（controller inventory screen）时整体缩放 0.6，
--     若 UI 底板挪了而格子没挪，格子就会画到图外面。
--   ⇒ 这是「槽位坐标依赖 UI 底板位置」的明证，也解释了为什么槽位坐标要写死成常量。
--V2C: y pos used to be 200, moved to 330 to match woby_rack_container so that it scales
--     together in controller inventory screen. Shift all y-coords to account for this.
--     Art was also shifted accordingly.  0.6 is the base scale (in inventorybar).
-- ★ yshift = (330-200)/0.6 = 216.67：除以 0.6 是**逆缩放**，
--   因为槽位坐标定义在「未缩放的 UI 空间」，而底板被缩放了。
--   ⇒ 这是一个「用数学消除缩放影响」的典型 hack，注释必须留着，否则没人敢动。
local yshift = (330 - 200) / 0.6
-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「沃比小形态容器 3x3」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原
for y = 2, 0, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
		table.insert(params.wobysmall.widget.slotpos, Vector3(75 * x - 75 * 2 + 75, 75 * y - 75 * 2 + 75 - yshift, 0))
    end
-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。
end
-- 立刻置 nil：防 Lua 的「局部变量意外捕获」——后面的循环若误用 yshift 会得到 nil。
--   ★ 这是 Lua 里的良好习惯（对应 inventory 组件里大量 `x = nil` 的写法）。
yshift = nil

-- ⚠ 疑似缺陷：params.wobybig = params.wobysmall —— 第三处**引用赋值**。
--   推理依据：与第 43/137 行同类；此处风险稍低，因为 wobysmall 后续未被修改。
--   累计统计：本文件有 8 处以上 `params.X = params.Y` 形式的共享别名，
--   遍布 backpack/spicepack/chester/wobysmall/treasurechest/quagmire 等。
--   ⇒ 这是本文件最大的架构性技术债：**蓝图表是一张可变共享图，不是不可变常量**。
params.wobybig = params.wobysmall

-- ── woby_rack_container（沃比晾肉架）区块 ──
--------------------------------------------------------------------------
--[[ woby_rack_container ]]
--------------------------------------------------------------------------

-- 晾肉架：3x1 = 3 格，单排。
--   ★ acceptsstacks = false —— **一格一串肉**，不能堆。
--     这与「冰箱可堆」的直觉相反：晾肉架是位图式的（每格一件，定时减质），
--     而堆叠是列表式的（数量 = 一维）。两种建模方式对应两套交互逻辑。
params.woby_rack_container =
{
	widget =
	{
		slotpos = {},
-- slotbg = {}：格子**底纹**贴图数组，与 slotpos 一一对应。
--   ★ slotbg 是纯装饰，容器逻辑从不读它（grep 核实：本文件内只有写入，没有读取）。
--     它的唯一去向是 widgets 层——用它画「这里该放肉」的提示底图。
		slotbg = {},
		animbank = "ui_meatrack_3x1",
		animbuild = "ui_meatrack_3x1",
		pos = Vector3(0, 330, 0),
		side_align_tip = 160,
	},
-- acceptsstacks = false 的语义落点在 components/container.lua:534：
--   放超量堆叠时会 Get() 成单个并**返回 false**（表示「只放进去一部分」）。
--   ★ 所以 acceptsstacks=false 不是「拒绝堆叠」，而是「把堆叠拆散成一格一件」。
	acceptsstacks = false,
-- type = "top_rack"：UI 挂到屏幕**下方**的 containerroot_under（见 playerhud.lua:398）。
--   ★ 这是「晾肉架为什么显示在背包下面而不是中间」的原因——纯 UI 方位标记。
	type = "top_rack",
	openlimit = 1,
}

-- ★ dryer_slotbg 被声明为 local 但**故意在多处重复声明**（第 190/228/278 行）。
--   原因：它是「当前正在用的格子底纹」的可变游标。第 278 行把它改成海藻贴图后，
--   第 282 行插入给 meatrack_hermit_multi 的就是新贴图。
--   ⇒ 这种「重新赋值一个 local 变量来切换配置」的写法可读性极差，
--     读代码时必须注意第 251 行的 slotbg = { dryer_slotbg } 抓到的是**第 228 行那一张**。
local dryer_slotbg = { image = "inv_slot_morsel.tex" }
-- ★ 槽位生成循环（顶层）：x = 0 … 2 → **3 轮**。
--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 3 × 1 = **3 个槽**，即「沃比晾肉架 3x1」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 3），存档按编号还原
for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
	table.insert(params.woby_rack_container.widget.slotpos, Vector3(75 * x - 75 * 2 + 75, 0, 0))
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
	table.insert(params.woby_rack_container.widget.slotbg, dryer_slotbg)
-- 循环结束：已插入 **3 个** slotpos 坐标，本容器的 numslots 定为 3。
end
dryer_slotbg = nil

-- 【★ itemtestfn 范例 B：白名单 + 三条「工程性例外」】
--   这个函数是全文件**最值得逐行读**的 itemtestfn，因为它同时展示了：
--     ① 规则本体：item:HasTag("dryable") —— 语义规则；
--     ② TheWorld.ismastersim 包裹 —— **服务端才做**的判定（客户端不需要）；
--     ③ 三条「为了修 bug 而开的口子」——每条都有原注释说明来龙去脉。
--   ★ 为什么例外要在服务端判？因为 GetTimeAlive 只在服务端有意义（客户端没有存活时间）。
--     而 dryingrack_lastinfo 是服务端在搬运失败时写回的定位信息。
function params.woby_rack_container.itemtestfn(container, item, slot)
-- 规则本体：只有带 dryable 标签（腊肉、香肠、牛皮…）才进晾肉架。
--   ★ 注意这不是「不是食物」，而是「**是**可风干物」——黑名单式会漏掉新物品。
	return item:HasTag("dryable")
-- ★【关键设计】TheWorld.ismastersim：下面三条例外**只在服务端执行**。
--   为什么？因为它们处理的都是「服务端状态迁移」的中间态，
--   客户端 UI 上这些物品根本不该被看见（或者看见了也判不了）。
--   ⇒ 这是 DST 里区分「逻辑判定」与「UI 判定」的标准手法，全库大量使用。
		or (TheWorld.ismastersim and (
-- ★ 原注释保留：「items perishing replaced by spoiled_food/fish」。
--   推理：物品腐坏动画期间，引擎会把它替换成 spoiled_food/fish 实例，
--   替换瞬间新实例的 GetTimeAlive()==0，若不放行就会「卡住无法取出」。
--   这是一条**为修具体 bug 而存在的规则**，属于典型的「技术债但必须留」。
				item:GetTimeAlive() == 0 or --items perishing replaced by spoiled_food/fish
-- ★ 原注释保留：「transferring items during woby transform」。
--   沃比在形态间切换时会批量搬运格内物品，容器实体的 GetTimeAlive() 也会短暂为 0。
--   同理：形态切换窗口内必须放行，否则物品会被锁死。
--   ⚠ 注意第 238 行的 meatrack 版本**特意注释掉了这一条**（woby specific），
--     说明这条例外被精确限定在沃比专用容器，不污染普通晾肉架。
				container.inst:GetTimeAlive() == 0 or --transferring items during woby transform
-- ★ 原注释保留：「failing to move items; return to slot」。
--   推理：晾肉架有「取出→放置→可能失败放回」的流程，失败时物品要能回到原槽。
--   dryingrack_lastinfo 是服务端在搬运前写下的 {container, slot}，
--   itemtestfn 靠它识别「这就是刚才那个要退回的物品」。
--   ⇒ 这是一个**用外部状态字段反推意图**的做法，脆弱但有效。
				(	item.dryingrack_lastinfo and --failing to move items; return to slot
-- 比对容器身份：必须是同一个容器实例（不是同一 prefab 的另一个实体）。
					item.dryingrack_lastinfo.container == container and
-- 比对槽位号：连槽位都要一致，杜绝「退到别的空槽」的可能。
					item.dryingrack_lastinfo.slot == slot
				)
			))
end

-- ── meatrack（晾肉架）区块 ──
--------------------------------------------------------------------------
--[[ meatrack ]]
--------------------------------------------------------------------------

-- 普通晾肉架：同样是 3x1，但美术是 ui_meatrack_multi_3x1（multi = 可多层堆叠渲染）。
--   ★ 与沃比版（woby_rack_container）的区别只有美术与 itemtestfn 的一条例外。
params.meatrack =
{
	widget =
	{
		slotpos = {},
		slotbg = {},
		animbank = "ui_meatrack_multi_3x1",
		animbuild = "ui_meatrack_multi_3x1",
		pos = Vector3(0, 200, 0),
		side_align_tip = 160,
	},
	acceptsstacks = false,
	type = "chest",
}

-- ★ 第二次声明 dryer_slotbg（同为 inv_slot_morsel.tex）。
--   注意：第 251 行的 meatrack_hermit 会抓到**这一张**，第 282 行会抓到第 278 行那张。
local dryer_slotbg = { image = "inv_slot_morsel.tex" }
-- ★ 槽位生成循环（顶层）：x = 0 … 2 → **3 轮**。
--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 3 × 1 = **3 个槽**，即「普通晾肉架 3x1」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 3），存档按编号还原
for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
	table.insert(params.meatrack.widget.slotpos, Vector3(75 * x - 75 * 2 + 75, 0, 0))
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
	table.insert(params.meatrack.widget.slotbg, dryer_slotbg)
-- 循环结束：已插入 **3 个** slotpos 坐标，本容器的 numslots 定为 3。
end

-- 【itemtestfn 范例 B 的简化版】与沃比版逐字对照，只少了一条 woby 例外。
--   ★ 这个「复制粘贴后删一行」的模式本身就是最好的文档：
--     两段代码并列一看，就知道沃比专用逻辑是什么。
function params.meatrack.itemtestfn(container, item, slot)
	return item:HasTag("dryable")
		or (TheWorld.ismastersim and (
				item:GetTimeAlive() == 0 or --items perishing replaced by spoiled_food/fish
-- ★ 这行被注释掉的例外旁**留着说明**「woby specific; see above」——
--   指向第 201 行。这是本文件注释规范的好例子：删代码留理由。
				--container.inst:GetTimeAlive() == 0 or --woby specific; see above
				(	item.dryingrack_lastinfo and --failing to move items; return to slot
					item.dryingrack_lastinfo.container == container and
					item.dryingrack_lastinfo.slot == slot
				)
			))
end

-- 寄居蟹的 1x1 晾肉架：只有 1 格。
params.meatrack_hermit =
{
	widget =
	{
-- slotpos 只有 1 个坐标 → 第 15 行数出 numslots = 1。
--   ★ 第 2240 行 wx78_inventorycontainer 的注释「numslots = 1, --required if we
--     don't have slotpos table」说明：**动态槽位容器必须显式写 numslots**，
--     因为 slotpos 可能只是个占位。
		slotpos = { Vector3(-2, 18, 0) },
		slotbg = { dryer_slotbg },
		animbank = "ui_hermitcrab_meatrack_1x1",
		animbuild = "ui_hermitcrab_meatrack_1x1",
		pos = Vector3(0, 160, 0),
		side_align_tip = 100,
	},
	acceptsstacks = false,
	type = "chest",
-- ★ itemtestfn = params.meatrack.itemtestfn —— **函数指针共享**。
--   三个寄居蟹晾肉架共用同一个判定闭包，改一处即改三处。
--   ⇒ 与第 137 行的表共享不同：函数共享是**安全的**（函数本身不可变），
--     表共享才危险。这是本文件里两种「复用」手法的本质区别。
	itemtestfn = params.meatrack.itemtestfn,
}

params.meatrack_hermit_multi =
{
	widget =
	{
		slotpos = {},
		slotbg = {},
		animbank = "ui_hermitcrab_3x3",
		animbuild = "ui_hermitcrab_3x3",
		pos = Vector3(0, 200, 0),
		side_align_tip = 160,
	},
	acceptsstacks = false,
	type = "chest",
	itemtestfn = params.meatrack.itemtestfn,
}

-- ★ 把 dryer_slotbg 换成海藻贴图——从这里开始的 slotbg 都是这张。
--   ⚠ 这就是「用可变游标切换配置」的代价：读代码时必须倒着数一遍，
--     才能知道第 251 行和第 282 行各拿到哪张贴图。
dryer_slotbg = { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" }
-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「寄居蟹 3x3 晾肉架」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原
for y = 2, 0, -1 do
	for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
		table.insert(params.meatrack_hermit_multi.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 80, 0))
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
		table.insert(params.meatrack_hermit_multi.widget.slotbg, dryer_slotbg)
	end
-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。
end

dryer_slotbg = nil

-- ── sewingmachine（缝纫机）区块 ──
--------------------------------------------------------------------------
--[[ sewingmachine ]]
--------------------------------------------------------------------------

-- 缝纫机：3 个横向槽位，只放「图纸碎片」（yotb_pattern_fragment）。
--   ★ 这是「装备站式容器」的典型：槽位少、有专用按钮、无配方逻辑（按钮直接触发动作）。
params.yotb_sewingmachine =
{

    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-(64 + 12), 0, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 0, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(64 + 12, 0, 0),
        },

        slotbg =
        {
            { image = "yotb_sewing_slot.tex", atlas = "images/hud2.xml" },
            { image = "yotb_sewing_slot.tex", atlas = "images/hud2.xml" },
            { image = "yotb_sewing_slot.tex", atlas = "images/hud2.xml" },
        },

-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x1"。
        animbank = "ui_chest_3x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x1"。
        animbuild = "ui_chest_3x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,

-- 【★ buttoninfo：容器按钮的完整三件套入口】
--   buttoninfo = { text, position, fn, validfn } 是本文件里第二套「可挂回调」的机制
--   （第一套是 itemtestfn）。full fn 和 validfn 分别定义在第 330/338 行。
--   ★ 三件套的职责：text = 按钮文案、position = 按钮在 UI 上的位置、
--     fn = 点击做什么、validfn = 什么时候按钮可点（灰显判定）。
        buttoninfo =
        {
            text = STRINGS.ACTIONS.YOTB_SEW,
            position = Vector3(0, -65, 0),
        }
    },
-- type = "cooker" —— ★ 全文件出现 21 次最多的 type。
--   但 grep 核实：「cooker」**不在任何白名单里**（playerhud.lua 只认 inv/hand_inv/
--     side_inv/side_inv_behind/top_rack/chest_addon），也不在 storage_robot 的
--     {chest, pack} 里。⇒ cooker 在当前代码中只用于「不是侧边 UI、不是背包」这个否定语义。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【itemtestfn 范例 C：单标签白名单】最简形态，只有 3 行。
--   ★ 对照第 121 行（黑名单式）与第 1019 行（冰箱三层漏斗），
--     可见筛选规则的复杂度完全由「语义有多窄」决定，框架是同一个。
function params.yotb_sewingmachine.itemtestfn(container, item, slot)
    return item:HasTag("yotb_pattern_fragment")
end

-- 【★ buttoninfo.fn 的双端模板】这是本文件里出现 6 次的固定写法，务必逐字理解：
--   if inst.components.container ~= nil → **我在服务端**，直接执行 BufferedAction；
--   elseif inst.replica.container ~= nil → **我在客户端**，发 RPC 让服务端执行。
--   ★ 为什么同一个函数要兼容两端？因为 params 表是**双端共享**的——
--     服务端 WidgetSetup 灌一次，客户端 container_replica.lua:233 也灌一次，
--     拿到的是同一个函数。
--   ⇒ 这是「双端分裂架构」在数据层的直接体现，也是 DST 全库最常见的写法。
--   参见 components/container_replica.lua:47 `containers.widgetsetup(self)` 客户端分支。
function params.yotb_sewingmachine.widget.buttoninfo.fn(inst, doer)
-- 服务端分支：inst.components.container 存在 ⟺ TheWorld.ismastersim。
--   ★ 用「组件是否存在」而非 TheWorld.ismastersim 判断端，是 DST 的惯用间接手法
--     （因为 TheWorld 在某些纯逻辑上下文里可能还没准备好）。
    if inst.components.container ~= nil then
-- 服务端：直接执行动作。BufferedAction 会走完整的缓冲动作流程（见 bufferedaction.lua）。
--   ★ 为什么客户端不能直接执行？因为动作有服务端权威校验（见 actions.lua 的 *_fn）。
        BufferedAction(doer, inst, ACTIONS.YOTB_SEW):Do()
-- 客户端分支：两个前置条件——有 replica 容器、且**不忙**（IsBusy）。
--   ★ IsBusy（container_replica.lua:539）的语义是「客户端已发起 RPC 但还没收到确认」，
--     用于**防止重复点击**。这是联机 UI 的标准防抖。
    elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
-- SendRPCToServer(RPC.DoWidgetButtonAction, action.code, inst, action.mod_name) ——
--   ★ 四个参数：RPC 通道名、动作**编号**（不是函数）、目标实体、动作所属 mod 名。
--     传 code 而非函数是为了**跨端兼容**（客户端可能没有该动作的定义）。
        SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.YOTB_SEW.code, inst, ACTIONS.YOTB_SEW.mod_name)
    end
end

-- 【★ validfn：按钮可用性判定】注意它**只读 replica**，说明它只在客户端跑。
--   IsFull（第 458 行）= 槽位数 >= numslots。这里要求「满了才可点」，
--   因为缝纫机需要 3 张图纸碎片才触发——**空着的时候点了也没用，故灰显**。
--   ★ validfn 只在客户端存在的理由：按钮外观是纯 UI，不需要服务端知道。
function params.yotb_sewingmachine.widget.buttoninfo.validfn(inst)
    return inst.replica.container ~= nil and inst.replica.container:IsFull()
end



-- ── cookpot（烹饪锅）区块 ──
--------------------------------------------------------------------------
--[[ cookpot ]]
--------------------------------------------------------------------------

-- 烹饪锅：4 个**竖排**槽位（DST 的经典 pot 造型）+ COOK 按钮。
--   ★ 这是「竖排锅」的布局约定，槽位从上到下依次为 Vector3(0, +108/+36/-36/-108, 0)。
params.cookpot =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 64 + 32 + 8 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(64 + 32 + 8 + 4), 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_cookpot_1x4"。
        animbank = "ui_cookpot_1x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_cookpot_1x4"。
        animbuild = "ui_cookpot_1x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
        buttoninfo =
        {
            text = STRINGS.ACTIONS.COOK,
            position = Vector3(0, -165, 0),
        }
    },
-- ★ 是否接受整摞物品。false = 每格只放一件。
--   落点：components/container.lua:534 GiveItem 会把超量堆叠 Get() 拆成单个并**返回 false**。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

function params.cookpot.itemtestfn(container, item, slot)
-- 【★ itemtestfn 范例 D：跨模块判定】调用 cooking.lua 的 IsCookingIngredient。
--   ★ 关键设计：判定逻辑**不在容器系统里**，而在烹饪系统里。
--     ⇒ 推论：新增一种可烹饪物只要改 cooking.lua，锅、便携锅、
--       沙漏-pot（quagmire_pot 用的是 quagmire_stewable 另一套）会自动跟随。
--   —— 这就是「规则外置」的收益，与第 1019 行把规则写在 itemtestfn 里形成对比。
--   ⚠ 但注意末尾的 `not container.inst:HasTag("burnt")`：
--     锅**烧焦（burnt）后连原本合法的食材都拒绝**。这是「容器状态参与筛选」的少数例子。
    return cooking.IsCookingIngredient(item.prefab) and not container.inst:HasTag("burnt")
end

-- 第 330 行 fn 的逐字复制（只换了 ACTIONS.COOK）。
--   ★ 全文件 6 处 buttoninfo.fn 都是这个模板，只有 ACTIONS 名字不同。
function params.cookpot.widget.buttoninfo.fn(inst, doer)
    if inst.components.container ~= nil then
        BufferedAction(doer, inst, ACTIONS.COOK):Do()
-- ★★ 「客户端读 widgets 字段」的直接证据就在这一行：
--   `item.dryingrack_lastinfo` 是**客户端组件上的运行时字段**。
--   它由服务端在搬运失败时写回，客户端在渲染时读它来决定「哪一格高亮」。
--   ⇒ 说明 dryingrack_lastinfo 通过某条同步链路到达客户端（很可能是 classified netvar）。
--   ⚠ 风险：这个字段**在客户端与服务端的写入时机不一定同步**，
--     若客户端判定早于同步，会出现「高亮错了格子」的短暂视觉 bug。
    elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
        SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.COOK.code, inst, ACTIONS.COOK.mod_name)
    end
end

-- cookpot 的 validfn 与缝纫机一致：满了才可点（凑齐材料才能煮）。
function params.cookpot.widget.buttoninfo.validfn(inst)
    return inst.replica.container ~= nil and inst.replica.container:IsFull()
end

-- ⚠ 疑似缺陷：params.archive_cookpot = params.cookpot（第 390 行同）——引用赋值。
--   推理依据：第 543/553/565 行在类似场景都用了 deepcopy，唯独这两行用了赋值。
--   当前无害（无后续修改），但与第 1047 行 params.saltbox = deepcopy(params.icebox)
--   的写法不一致，属风格不统一。仅标注，不改代码。
params.archive_cookpot = params.cookpot
-- 【蓝图：portablecookpot】便携烹饪锅
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.portablecookpot = params.cookpot

-- ── portablespicer（便携香料锅）区块 ──
--------------------------------------------------------------------------
--[[ portablespicer]]
--------------------------------------------------------------------------

-- 便携香料锅：2 格，**每格内容物不同**（slot 1 = 食材，slot 2 = 香料）。
--   ★ 这就是 usespecificslotsforitems = true 的意义：**槽位有语义**，
--     物品必须进指定的那一格，由 itemtestfn 里的 slot 参数强制（第 425 行）。
params.portablespicer =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 32 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
        },
-- slotbg 逐槽不同：cook_slot_food.tex / cook_slot_spice.tex ——
--   ★ 底纹在**告诉玩家「这一格放什么」**，这是槽位语义最直观的 UI 表达。
        slotbg =
        {
            { image = "cook_slot_food.tex" },
            { image = "cook_slot_spice.tex" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_cookpot_1x2"。
        animbank = "ui_cookpot_1x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_cookpot_1x2"。
        animbuild = "ui_cookpot_1x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
        buttoninfo =
        {
            text = STRINGS.ACTIONS.SPICE,
            position = Vector3(0, -93, 0),
        },
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- usespecificslotsforitems = true → 落点在 components/container.lua:298
--   GetSpecificSlotForItem：逐槽试 itemtestfn(item, i)，第一个通过的就是目标槽。
--   ★ 关键：GiveItem 第 451 行 `slot = slot or self:GetSpecificSlotForItem(item)`，
--     所以**未指定槽位时也会走专用槽分配**，不会随便找个空位。
    usespecificslotsforitems = true,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【★ itemtestfn 范例 E：按槽位分派的三分支】全文件最清晰的一个「槽位语义」样板。
--   三个分支分别对应：slot==1（食材槽）、slot==2（香料槽）、slot==nil（不指定槽位时）。
--   ★ slot == nil 分支是必需的：因为拖拽悬停判定时槽位可能未确定，
--     若不写 nil 分支，拖拽时会被判为「不能放」而卡住。
--   ⚠ 注意每个分支都写了 `and not spicedfood` / `HasTag("spice")`：
--     规则是互斥的，香料不能当食材、已调味的菜不能再当食材——
--     这类「状态互斥」是容器筛选里最难表达的一类规则。
function params.portablespicer.itemtestfn(container, item, slot)
-- ★ 首行 `item.prefab ~= "wetgoop"`：一种具体的「烂糊糊」不可入锅。
--   ⚠ 这是**硬编码 prefab 名**的白名单，与第 1732 行 seedpouch 用
--     `string.match(item.prefab, "_seeds")` 做前缀/后缀匹配相比，
--     健壮性差得多（新物品必须改这里）。这类硬编码在本文件里约有 20 处。
    return item.prefab ~= "wetgoop"
        and (   (slot == 1 and item:HasTag("preparedfood") and not item:HasTag("spicedfood")) or
                (slot == 2 and item:HasTag("spice")) or
-- slot == nil 的兜底分支：两种都接受，等价于「不限槽」。
                (slot == nil and (item:HasTag("spice") or (item:HasTag("preparedfood") and not item:HasTag("spicedfood"))))
            )
        and not container.inst:HasTag("burnt")
end

function params.portablespicer.widget.buttoninfo.fn(inst, doer)
    if inst.components.container ~= nil then
        BufferedAction(doer, inst, ACTIONS.COOK):Do()
    elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
        SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.COOK.code, inst, ACTIONS.COOK.mod_name)
    end
end

function params.portablespicer.widget.buttoninfo.validfn(inst)
    return inst.replica.container ~= nil and inst.replica.container:IsFull()
end

-- ── bundle_container（包扎容器）区块 ──
--------------------------------------------------------------------------
--[[ bundle_container ]]
--------------------------------------------------------------------------

-- 绷带包：2x2 = 4 格，WRAPBUNDLE 按钮。
--   ★ type = "cooker" 但它根本不烹饪——再次说明 type 只是 UI 方位标记，无语义。
params.bundle_container =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(37.5, -(32 + 4), 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_bundle_2x2"。
        animbank = "ui_bundle_2x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_bundle_2x2"。
        animbuild = "ui_bundle_2x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 120。
        side_align_tip = 120,
        buttoninfo =
        {
            text = STRINGS.ACTIONS.WRAPBUNDLE,
            position = Vector3(0, -100, 0),
        }
    },
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【itemtestfn 范例 F：多标签黑名单】HasAnyTag 一次性排除四类标签。
--   irreplaceable（剧情物）、_container（容器本身，防止容器套容器）、
--   bundle（成品绷带）、nobundling（不可包扎物）。
--   ★ 「排除容器本身」是一条通用规则——几乎所有语义容器都会写它，
--     防止玩家把背包塞进背包导致溢出链递归。
function params.bundle_container.itemtestfn(container, item, slot)
    return not item:HasAnyTag("irreplaceable", "_container", "bundle", "nobundling")
end

function params.bundle_container.widget.buttoninfo.fn(inst, doer)
    if inst.components.container ~= nil then
        BufferedAction(doer, inst, ACTIONS.WRAPBUNDLE):Do()
    elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
        SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.WRAPBUNDLE.code, inst, ACTIONS.WRAPBUNDLE.mod_name)
    end
end

-- bundle 的 validfn 与前几个不同：要求「非空 **且** 不是只读容器」。
--   IsReadOnlyContainer（container_replica.lua:336）读的是 netvar readonlycontainer，
--   ⇒ 只读容器（如展示柜）里明明有东西，按钮也不能点。
function params.bundle_container.widget.buttoninfo.validfn(inst)
    return inst.replica.container ~= nil and not inst.replica.container:IsEmpty() and not inst.replica.container:IsReadOnlyContainer()
-- ★ IsReadOnlyContainer 在 validfn 里出现（第 487 行）：只读容器连按钮都不能点。
--   ⇒ 只读容器（readonlycontainer）是一个**端到端的三层开关**：
--     服务端：CanTakeItemInSlot 第 275 行拒绝一切放入；
--     客户端：IsReadOnlyContainer 让 UI 灰掉；
--     事件层：EnableReadOnlyContainer 第 1618 行挂断言监听器，
--              若有物品硬塞进去直接 assert(false)。
end

-- ── construction_container（建造容器）区块 ──
--------------------------------------------------------------------------
--[[ construction_container ]]
--------------------------------------------------------------------------

-- 【★ 建造容器：全文件最特殊的一个】它的槽位内容**由玩家角色决定**，不由容器决定。
--   判定逻辑在 itemtestfn（第 523 行）：问「你是谁？你手上的建造蓝图要什么材料？」
--   ★ 所以这个容器不需要知道建造配方——它只是把角色组件当数据源。
params.construction_container =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_construction_4x1"。
        animbank = "ui_construction_4x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_construction_4x1"。
        animbuild = "ui_construction_4x1",
-- pos.x = 300：建造 UI 在屏幕**最右侧**（远离中央的角色与准星）。
        pos = Vector3(300, 0, 0),
-- 提示条顶部对齐距离（像素）。
        top_align_tip = 50,
        buttoninfo =
        {
            text = STRINGS.ACTIONS.APPLYCONSTRUCTION.GENERIC,
            position = Vector3(0, -94, 0),
		},
-- ★ 原注释保留（V2C）：这是全文件**唯一一段解释音效归属**的注释，务必读：
--   「override the default widget sound, which is heard only by the client
--    -most containers disable the client sfx via skipopensnd/skipclosesnd,
--     and play it in world space through the prefab instead.」
--   ⇒ 翻译成本项目的话：
--     · 大部分容器走**世界空间音效**（prefab 自己播放，所有人听见）；
--     · 于是要关掉客户端 HUD 音效（skipopensnd/skipclosesnd），
--       否则会「一个人听两遍」（世界一遍 + HUD 一遍，只有本人听见 HUD 那遍）；
--     · 但建造容器想用**专属 HUD 音效**，所以反过来：覆盖 opensound/closesound。
--   消费点见 components/container.lua:645 `self.widget.opensound`。
		--V2C: -override the default widget sound, which is heard only by the client
		--     -most containers disable the client sfx via skipopensnd/skipclosesnd,
		--      and play it in world space through the prefab instead.
		opensound = "dontstarve/wilson/chest_open",
		closesound = "dontstarve/wilson/chest_close",
		--
    },
-- usespecificslotsforitems = true：建造材料**必须按序进指定槽**（第 4 格放木材…）。
--   ★ 目标槽由 itemtestfn 第 528 行 `GetIngredientForSlot(slot)` 算出——
--     它把「当前槽号」翻译成「这个槽该放什么 prefab」，是双向映射。
    usespecificslotsforitems = true,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- for x = -1.5 to 1.5 step 1 → 4 个槽，间距 110（比常规 75/80 宽，为了放长材料图标）。
for x = -1.5, 1.5, 1 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.construction_container.widget.slotpos, Vector3(x * 110, 8, 0))
-- 循环结束：已插入 **4 个** slotpos 坐标，本容器的 numslots 定为 4。
end

-- 【★ itemtestfn 范例 G：向「角色」要答案】本文件最巧妙的一个 itemtestfn。
--   它不查物品自身，而是查 container.inst 的**父实体**（也就是玩家）：
--     doer = container.inst.entity:GetParent() —— 容器的父实体就是拿它的人。
--   ★ 为什么这样？因为建造蓝图（constructionbuilderuidata）挂在玩家身上，
--     而容器是个「被玩家拖着走的临时 UI 实体」（portablecontainer 语义）。
--   ⇒ 设计启示：itemtestfn 不只是「物品过滤器」，它可以是一段**任意查询**。
--     这解释了为什么框架从不试图给 itemtestfn 限定职责边界。
function params.construction_container.itemtestfn(container, item, slot)

-- ★ entity:GetParent() 返回承载该实体的父（玩家背包或手上的物理实体）。
--   ⚠ 潜在脆弱点：若容器不在任何人身上（刚放地上），parent 为 nil → 判定 false，
--     即「地面上的建造容器不接受任何东西」。第 526 行的 doer ~= nil 正是守这个。
    local doer = container.inst.entity:GetParent()
-- 三重与：① 有人拿着 ② 拿的人有建造 UI 数据 ③ 该槽要求的材料正好是这个 prefab。
--   ★ 第 528 行的 == item.prefab 是**精确 prefab 匹配**，比标签判定严格得多。
--     建造配方要求 2 根木头就是 2 根木头，不能用「等价物」。
    return doer ~= nil
        and doer.components.constructionbuilderuidata ~= nil
        and doer.components.constructionbuilderuidata:GetIngredientForSlot(slot) == item.prefab
end

function params.construction_container.widget.buttoninfo.fn(inst, doer)
    if inst.components.container ~= nil then
        BufferedAction(doer, inst, ACTIONS.APPLYCONSTRUCTION):Do()
    elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
        SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.APPLYCONSTRUCTION.code, inst, ACTIONS.APPLYCONSTRUCTION.mod_name)
    end
end

-- 建造的 validfn 只需「非空」：材料齐不齐由 builder 组件自己判，容器不管。
function params.construction_container.widget.buttoninfo.validfn(inst)
    return inst.replica.container ~= nil and not inst.replica.container:IsEmpty()
end

-- ★ deepcopy + 改一个字段 = 派生新蓝图。
--   这是本文件最重要的复用手法，后面 20+ 处派生（saltbox/merm_armory/winter_tree 等）都用它。
--   ⚠ 代价：deepcopy 是**值拷贝**，widget.slotpos 里的 Vector3 会被重新构造，
--     所以改一个槽位坐标不影响原版（这正是我们想要的）。
params.construction_repair_container = deepcopy(params.construction_container)
params.construction_repair_container.widget.buttoninfo.text = STRINGS.ACTIONS.APPLYCONSTRUCTION.REPAIR

-- 第三个建造派生：REBUILD（重建）动作，与 REPAIR 共用同一套 UI。
params.construction_rebuild_container = deepcopy(params.construction_container)
params.construction_rebuild_container.widget.buttoninfo.text = STRINGS.ACTIONS.APPLYCONSTRUCTION.REBUILD

-- ── enable_shadow_rift_construction_container（月影裂隙献祭容器）区块 ──
--------------------------------------------------------------------------
--[[ enable_shadow_rift_construction_container ]]
--------------------------------------------------------------------------

-- 第四次派生：裂隙献祭。它比普通建造容器多一步——**要弹确认框**。
params.enable_shadow_rift_construction_container = deepcopy(params.construction_container)

-- 槽位缩到 1 个：献祭只需要一件东西。★ 用整体替换而非逐项修改，更清晰。
params.enable_shadow_rift_construction_container.widget.slotpos = {Vector3(0, 8, 0)}
-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.enable_shadow_rift_construction_container.widget.side_align_tip = 120
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.enable_shadow_rift_construction_container.widget.animbank = "ui_bundle_2x2"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.enable_shadow_rift_construction_container.widget.animbuild = "ui_bundle_2x2"
params.enable_shadow_rift_construction_container.widget.buttoninfo.text = STRINGS.ACTIONS.APPLYCONSTRUCTION.OFFER

---------------------------------------
-- construction_container_1x1


-- 【蓝图：construction_container_1x1】建造材料容器 1x1 变体
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.construction_container_1x1 = deepcopy(params.construction_container)

-- ★ 槽位坐标数组：每个 Vector3 是**一个格子在屏幕上的绝对位置**。
--   ★★ 数组顺序 = 槽位编号顺序（slot 1 = 第一个坐标）。改顺序就改了物品编号，
--     而存档按编号还原（components/container.lua:996 OnLoad），所以这是**存档兼容雷区**。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.construction_container_1x1.widget.slotpos = {Vector3(0, 8, 0)}
params.construction_container_1x1.widget.pos.x = 150
-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.construction_container_1x1.widget.side_align_tip = 40
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.construction_container_1x1.widget.animbank = "ui_construction_1x1"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.construction_container_1x1.widget.animbuild = "ui_construction_1x1"

---------------------------------------

-- 【★ IsConstructionSiteComplete：本地函数，服务端也会跑】
--   判定「容器里的材料 + 建造站已有的材料」是否已够建成。
--   ⚠ 注意第 576 行取的是 inst.replica.container —— 这个函数**只在客户端跑**
--     （第 623 行的 overrideactionfn 有 `doer.HUD ~= nil` 守卫），
--     因为它的目的是「决定要不要弹确认框」，纯 UI 决策。
local function IsConstructionSiteComplete(inst, doer)
    local container = inst.replica.container

-- 容器为空直接返回 false：没材料不可能建成。
    if container ~= nil and not container:IsEmpty() then
-- ★ 用 and/or 链实现「三元」：doer 没组件 → nil。
--   Lua 没有 ?: 运算符，and/or 是标准替代（注意 or 后面必须是 nil/false）。
--   ⚠ 这写法有陷阱：若 GetConstructionSite() 返回 false 也会落到 nil，但本例安全。
        local constructionsite = doer.components.constructionbuilderuidata ~= nil and doer.components.constructionbuilderuidata:GetConstructionSite() or nil
        
        if constructionsite ~= nil then
            local ingredients = constructionsite:GetIngredients()

-- ★ 这里的 ingredients 来自建造站（constructionsite）而非容器本身。
--   ⇒ 印证第 523 行的结论：建造容器的规则完全由「携带者」决定。
            if ingredients ~= nil then
                for i, v in ipairs(ingredients) do
-- ★★ 这行揭示了一个**双计数**设计：new_count（容器里的） + old_count（站点已有的）。
--   → 说明建造材料可以「一半放容器、一半已在建造站」，两者相加才算数。
--   ⚠ 疑似缺陷：`local complete, new_count = container:Has(...)` 的 complete 未被使用。
--     推理依据：Lua 的 `a, b = f()` 只取前两个返回值，而此处 complete 之后再没出现；
--     作者真正需要的只有 new_count（因为要和 old_count 相加）。
--     这不是逻辑错误（Lua 允许未使用的局部量），但属于死变量。仅标注，不改代码。
                    local complete, new_count = container:Has(v.type, v.amount)
                    local old_count = constructionsite:GetSlotCount(i)
-- ★ 加法比较：这就是「容器 + 站点」的合并计数。
--   ⚠ 变量名 new_count 实为「容器内该 prefab 的总数」，与 count 无冲突但易误解。
                    if not (new_count +  old_count >= v.amount) then
                        return false
                    end
                end
-- ingredients 为 nil（建造站没返回材料表）→ 保守返回 false。
            else
                return false
            end

            return true
        end
    end

    return false
end

-- 【EnableRiftsPopUpGoBack】取消回调：只弹回上一层。
--   ★ TheFrontEnd:PopScreen() 是全局前端栈操作——这是**客户端 UI 栈**的通用操作，
--     与容器系统无关，只是搭了个便车。
local function EnableRiftsPopUpGoBack()
    TheFrontEnd:PopScreen()
end

-- 【EnableRiftsDoAct】与第 331 行同构的服务端/客户端双端模板。
local function EnableRiftsDoAct(inst, doer)
	if inst.components.container ~= nil then
		BufferedAction(doer, inst, ACTIONS.APPLYCONSTRUCTION):Do()
	elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
		SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.APPLYCONSTRUCTION.code, inst, ACTIONS.APPLYCONSTRUCTION.mod_name)
	end
end

-- 【★ fn 与 overrideactionfn 的分工】一个「默认动作」被拆成两个函数：
--   · overrideactionfn —— 先问「要不要弹框」；
--   · fn —— 没有弹框时，直接执行。
--   ★ 这样拆分的好处：普通建造容器复用 fn 模板，裂隙容器只在前面插一个拦截层。
function params.enable_shadow_rift_construction_container.widget.buttoninfo.fn(inst, doer)
-- ★ 若 overrideactionfn 返回 true（已弹框并处理），fn 就不再执行。
	if not params.enable_shadow_rift_construction_container.widget.overrideactionfn(inst, doer) then
		-- No UI no dialogue.
		EnableRiftsDoAct(inst, doer)
	end
end

-- 【★ overrideactionfn：UI 拦截层】这是本文件里唯一「非纯数据」的逻辑块之一。
--   它做三件事：判断是否材料齐全 → 弹 RiftConfirmScreen → 返回 true 表示「已处理」。
--   ★ 返回布尔值作为「是否已消费事件」的信号，是回调式设计的常见约定。
function params.enable_shadow_rift_construction_container.widget.overrideactionfn(inst, doer)
-- 两个前置：doer 存在（有玩家）、且有 HUD（**说明必须是有 UI 的人类玩家**）。
--   ⇒ NPC（无 HUD）走不到这里，会落到第 618 行的直接执行路径。
	if doer ~= nil and doer.HUD ~= nil and IsConstructionSiteComplete(inst, doer) then
		-- We have UI do dialogue.
-- 局部函数即闭包：捕获 doer，弹框的 OK 回调里执行动作后关掉弹窗。
--   ★ 顺序很关键：**先执行再 Pop**，因为执行可能触发新的界面。
		local function EnableRiftsPopUpConfirm()
			EnableRiftsDoAct(inst, doer)
			TheFrontEnd:PopScreen()
		end

		local str = inst.POPUP_STRINGS
-- RiftConfirmScreen(title, body, buttons) —— 文件头 require 的那个 UI 模块。
--   ★ 这再次证明本文件不是纯数据表：它直接 new 了一个 Screen。
		local confirmation = RiftConfirmScreen(str.TITLE, str.BODY,
		{
			{ text = str.OK,     cb = EnableRiftsPopUpConfirm },
			{ text = str.CANCEL, cb = EnableRiftsPopUpGoBack  },
		})

		TheFrontEnd:PushScreen(confirmation)
		return true
	end
	return false
end

--lunar is same as shadow, just different strings specified in prefab
-- ⚠ 疑似缺陷：params.enable_lunar_rift_construction_container = params.enable_shadow_...
--   引用赋值（原注释说「lunar is same as shadow, just different strings specified in prefab」）。
--   推理依据：原注释解释了「只有字符串不同」，即差异由 prefab 的 POPUP_STRINGS 提供——
--     这是**有意的共享**，属合理设计。仅记录，便于区分于第 43/137 行的无解释共享。
params.enable_lunar_rift_construction_container = params.enable_shadow_rift_construction_container

-- ── mushroom_light（蘑菇灯）区块 ──
--------------------------------------------------------------------------
--[[ mushroom_light ]]
--------------------------------------------------------------------------

-- 蘑菇灯：4 竖格，只放「灯燃料」与「灯芯」。
params.mushroom_light =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 64 + 32 + 8 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(64 + 32 + 8 + 4), 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_lamp_1x4"。
        animbank = "ui_lamp_1x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_lamp_1x4"。
        animbuild = "ui_lamp_1x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【itemtestfn 范例 H：双标签白名单 + burnt 守卫】与第 374 行 cookpot 同型。
--   lightbattery（灯油等燃料）/ lightcontainer（灯芯等）；burnt 后全拒。
function params.mushroom_light.itemtestfn(container, item, slot)
    return item:HasAnyTag("lightbattery", "lightcontainer") and not container.inst:HasTag("burnt")
end

-- ── mushroom_light2 区块 ──
--------------------------------------------------------------------------
--[[ mushroom_light2 ]]
--------------------------------------------------------------------------

-- deepcopy 后**整体覆盖 itemtestfn**：蘑菇灯 2 额外接受「孢子」。
--   ★ 覆盖整个函数而不是改函数体，是派生式配置最干净的做法。
params.mushroom_light2 = deepcopy(params.mushroom_light)

-- 三个标签：lightbattery / spore / lightcontainer。
--   ★ 注意 spore 这个标签是 wormwood（蕨类学家）机制的通用接口。
function params.mushroom_light2.itemtestfn(container, item, slot)
    return item:HasAnyTag("lightbattery", "spore", "lightcontainer") and not container.inst:HasTag("burnt")
end

-- ── yots_lantern_post（永夜灯柱）区块 ──
--------------------------------------------------------------------------
--[[ yots_lantern_post ]]
--------------------------------------------------------------------------

-- ★ 把三个标签提成局部常量 LIGHT_TAGS，供第 703 行与第 713 行复用。
--   这是全文件里少见的「提成常量」写法——其余地方都是重复字符串字面量。
local LIGHT_TAGS = { "lightbattery", "spore", "lightcontainer" }
-- 【蓝图：yots_lantern_post】永夜灯柱 1 格（灯燃料/孢子/灯芯）
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.yots_lantern_post = {
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = { Vector3(0, 0, 0), }。
        slotpos = { Vector3(0, 0, 0), },
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_1x1"。
        animbank = "ui_chest_1x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_1x1"。
        animbuild = "ui_chest_1x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 160, 0)。
        pos = Vector3(0, 160, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 第 671 行的复用版：把 FOODTYPE 风格的枚举换成 LIGHT_TAGS 常量。
--   ★ 对比第 681 行 mushroom_light2 用的是内联三标签表——**风格不统一**，
--     两个几乎相同的 itemtestfn，一个提常量一个内联。仅记录风格问题。
function params.yots_lantern_post.itemtestfn(container, item, slot)
    return item:HasAnyTag(LIGHT_TAGS) and not container.inst:HasTag("burnt")
end

--------------------------------------------------------------------------
--[[ hermitcrab_lightpost ]]
--------------------------------------------------------------------------

-- 【蓝图：hermitcrab_lightpost】寄居蟹灯柱（换皮，复用同一 itemtestfn）
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.hermitcrab_lightpost = deepcopy(params.yots_lantern_post)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.hermitcrab_lightpost.widget.animbank = "ui_hermitcrab_1x1"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.hermitcrab_lightpost.widget.animbuild = "ui_hermitcrab_1x1"
-- ★ 物品筛选闭包，签名固定 (container, item, slot)。
--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。
--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.hermitcrab_lightpost.itemtestfn = params.yots_lantern_post.itemtestfn

function params.hermitcrab_lightpost.widget.bganim_visualfn(bganim, container, doer)
    local r, g, b, a = container.AnimState:GetSymbolMultColour("coral")
    bganim:GetAnimState():SetSymbolMultColour("coral", r, g, b, a)
end

-- ── hermithouse2（寄居蟹屋 2）区块 ──
--------------------------------------------------------------------------
--[[ hermithouse2 ]]
--------------------------------------------------------------------------

-- 寄居蟹屋：2x2 = 4 格，只放「装饰品」（hermithouse_ornament）。
--   ★ 这类「装饰槽」容器让玩家把收集品摆在房里——纯装饰玩法，无功能影响。
params.hermithouse2 =
{
	widget =
	{
		slotpos =
		{
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(-37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(-37.5, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(37.5, -(32 + 4), 0),
		},
		slotbg = {},
		animbank = "ui_hermitcrab_2x2",
		animbuild = "ui_hermitcrab_2x2",
		pos = Vector3(200, 0, 0),
		side_align_tip = 120,
	},
	acceptsstacks = false,
	type = "cooker",
}

-- 又一张 slotbg 常量，4 格共用同一张贴图。
local hermithouse2_slotbg = { image = "inv_slot_hermithouse.tex", atlas = "images/hud2.xml" }
-- 底纹批量填充循环：i = 1 … 4 → **4 次**。
--   ★ 只往 slotbg 塞贴图、**不产生槽位**——槽位由 slotpos 决定。
--   ⇒ 它的次数必须与「寄居蟹屋 2 代 2x2=4 格」的 slotpos 数量严格相等，否则底纹会错位。
for i = 1, 4 do
	params.hermithouse2.widget.slotbg[i] = hermithouse2_slotbg
-- 循环结束：已插入 **0 个** slotpos 坐标，本容器的 numslots 定为 0。
end
hermithouse2_slotbg = nil

-- 单标签白名单（与缝纫机第 327 行同型），是最简形态。
function params.hermithouse2.itemtestfn(container, item, slot)
    return item:HasTag("hermithouse_ornament")
end

-- ── winter_tree（冬季树）区块 ──
--------------------------------------------------------------------------
--[[ winter_tree ]]
--------------------------------------------------------------------------

-- 冬季树：8 格（2x4），放节日装饰。
--   ★ 与背包（8 格）同一个 slotpos 公式与同一张美术 ui_backpack_2x4，
--     说明「8 格 2x4 布局」在本文件里被复用了很多次。
params.winter_tree =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_backpack_2x4"。
        animbank = "ui_backpack_2x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_backpack_2x4"。
        animbuild = "ui_backpack_2x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(275, 0, 0)。
        pos = Vector3(275, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- ★ 槽位生成循环（顶层）：y = 0 … 3 → **4 轮**。
--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 4 × 2 = **8 个槽**，即「冬季树 8 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 8），存档按编号还原
for y = 0, 3 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.winter_tree.widget.slotpos, Vector3(-162, -75 * y + 114, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.winter_tree.widget.slotpos, Vector3(-162 + 75, -75 * y + 114, 0))
-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。
end

-- 【★ 双标签白名单】winter_ornament 或 hermithouse_ornament，外加 burnt 守卫。
--   ★ 注意：hermithouse_ornament 同时被第 751 行的寄居蟹屋接受——
--     **同一个物品可以被两个不同容器接受**，这在本系统里完全合法。
--     ⇒ 推论：itemtestfn 是「每个容器各自为政」的闭包，没有任何全局物品-容器映射表。
function params.winter_tree.itemtestfn(container, item, slot)
	return item:HasAnyTag("winter_ornament", "hermithouse_ornament") and not container.inst:HasTag("burnt")
end

-- ⚠ 疑似缺陷：连续三行引用赋值 winter_twiggytree / winter_deciduoustree /
--   winter_palmconetree = params.winter_tree，未用 deepcopy。
--   推理依据：本文件派生蓝图时 **deepcopy 是主流写法**（第 116/128/678/944/950/1047/2297 行等），
--     这里三处连用赋值显得是「图省事」。当前无后续修改故无害；
--     但模组若改 params.winter_tree.widget.* 会同时影响三种树。
--     与第 43/137/168 行同属一类技术债。**不改代码，仅标注**。
params.winter_twiggytree = params.winter_tree
-- 【蓝图：winter_deciduoustree】冬季落叶树
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.winter_deciduoustree = params.winter_tree
-- 【蓝图：winter_palmconetree】冬季棕榈树
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.winter_palmconetree = params.winter_tree

-- ── sisturn（露西的花槽）区块 ──
--------------------------------------------------------------------------
--[[ sisturn ]]
--------------------------------------------------------------------------

-- 花槽：2x2 = 4 格。openlimit = 1（第 815 行）：**同一人同时只能开一个花槽**。
--   ★ 这是「专用小容器设 openlimit」的典型：避免误开一堆花槽把屏幕塞满。
params.sisturn =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(37.5, -(32 + 4), 0),
        },
        slotbg =
        {
            { image = "sisturn_slot_petals.tex" },
            { image = "sisturn_slot_petals.tex" },
            { image = "sisturn_slot_petals.tex" },
            { image = "sisturn_slot_petals.tex" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_2x2"。
        animbank = "ui_chest_2x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_2x2"。
        animbuild = "ui_chest_2x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 120。
        side_align_tip = 120,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
-- openlimit：同第 60 行（首次定义），此处值 = 1。
    openlimit = 1,
}

-- 【★ itemtestfn 范例 I：依赖「打开者」的动态规则】全文件最复杂的一个 itemtestfn。
--   它先确定「谁开着这个容器」（owner），再根据 owner 的**技能树解锁情况**
--   决定接受哪些物品。⇒ 判定输入不只是 (item, slot)，还有「世界状态 + 玩家进度」。
--   ★ 双端分支与第 199 行同理：服务端用 GetOpeners()[1]，客户端用 IsOpenedBy(ThePlayer)。
function params.sisturn.itemtestfn(container, item, slot)
-- 服务端取「第一个打开者」：多人同开时以先开的人为准。
    local owner
    if TheWorld.ismastersim then
-- ⚠ 潜在缺陷：GetOpeners()[1] 在 openlist 无序（pairs）的情况下**不保证是最近打开者**。
--   推理依据：openlist 是以实体为键的哈希表，pairs 遍历顺序未定义。
--   实际影响很小（两人同开一花槽的技能解锁状态通常相同），但严格说是未定义行为。
--   ★ 对照第 1523 行 slingshot 的 itemtestfn 用了**完全相同**的写法，
--     说明这是「通用模式」而非笔误。仅标注，不改代码。
        owner = container.inst.components.container:GetOpeners()[1]
    elseif ThePlayer and container:IsOpenedBy(ThePlayer) then
        owner = ThePlayer
    end

-- ★ 原注释保留：「NOTE: can have no owner when loading」。
--   推理：存档加载期间不会有任何玩家 openlist，owner 为 nil。
--   此时**必须放行**，否则读档后玩家从花槽里取不出花瓣（物品被锁死）。
--   ⇒ 「加载期例外」是容器筛选的第三类工程性开口（前两类见第 200/202 行）。
    --NOTE: can have no owner when loading
-- 三选一放行：无 owner（加载中）**或** 拥有 wendy_sisturn_3 技能 → 接受三种花瓣；
--   否则只接受普通 petals。
--   ★ skilltreeupdater:IsActivated 是「技能树节点是否已解锁」的统一查询接口。
    if not owner or (owner.components.skilltreeupdater and owner.components.skilltreeupdater:IsActivated("wendy_sisturn_3")) then
        return item.prefab == "petals" or item.prefab == "moon_tree_blossom" or item.prefab == "petals_evil"
    end

-- 未解锁时：只接受最基础的 petals。
    return item.prefab == "petals" 
end

-- ── offering pot（供奉锅）区块 ──
--------------------------------------------------------------------------
--[[ offering pot ]]
--------------------------------------------------------------------------

-- 供奉锅：2x2 = 4 格，**只放海藻（kelp）**。
--   ★ 这是「单一物品容器」的极端：整个 4 格容器只接受一个 prefab。
params.offering_pot =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(37.5, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(37.5, -(32 + 4), 0),
        },
        slotbg =
        {
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_2x2"。
        animbank = "ui_chest_2x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_2x2"。
        animbuild = "ui_chest_2x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 120。
        side_align_tip = 120,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【itemtestfn 范例 J：prefab 精确匹配】`item.prefab == "kelp"`。
--   ⚠ 与 HasTag 相比，预fab 精确匹配不容错：把「海藻」换成任何带 forofferingpot 标签的物品都不行。
--     但反过来它也最严格——不会出现「顺带收进奇怪东西」的投诉。
--   ★ 两种风格在本文件里并存，按「语义有多确定」选：
--     确定（只有一个 prefab 合法）→ 精确匹配；不确定（一类物品）→ 标签。
function params.offering_pot.itemtestfn(container, item, slot)
    return not container.inst:HasTag("burnt") and item.prefab == "kelp"
end

-- ── offering pot II（供奉锅 II）区块 ──
--------------------------------------------------------------------------
--[[ offering pot II ]]
--------------------------------------------------------------------------

-- 二代供奉锅：3x2 = 6 格（从 4 格扩到 6 格），美术 ui_chest_3x2。
--   ★ 注意它**没有 itemtestfn 字段**，而是在第 904 行单独赋值——
--     两种写法等价，但「先建表后补函数」在这里更清晰。
params.offering_pot_upgraded =
{
    widget =
    {
        slotpos =
        {            
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-75, 32 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(75, 32 + 4, 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-75, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 5 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 6 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(75, -(32 + 4), 0),
        },
        slotbg =
        {
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_kelp.tex", atlas = "images/hud2.xml" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x2"。
        animbank = "ui_chest_3x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x2"。
        animbuild = "ui_chest_3x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 120。
        side_align_tip = 120,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- ★ 函数指针共享：二代锅复用一代的判定（同第 259 行的模式）。
--   正确写法，与第 543 行的 deepcopy 形成对照：
--     · 表结构要改 → deepcopy 再改字段；
--     · 只共享判定逻辑 → 直接赋函数指针。
params.offering_pot_upgraded.itemtestfn = params.offering_pot.itemtestfn

-- ── merm_toolshed（鱼人工具棚）区块 ──
--------------------------------------------------------------------------
--[[ merm_toolshed ]]
--------------------------------------------------------------------------

-- 工具棚：2 格，每格固定物品（slot1 = 树枝，slot2 = 石头），slotbg 直接画对应图标。
--   ★ 这是「双格语义容器」的代表：不用标签，靠 slot 参数硬绑定。
params.merm_toolshed =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0,   32 + 4,  0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
        },
        slotbg =
        {
            { image = "inv_slot_twigs.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_rocks.tex", atlas = "images/hud2.xml" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_1x2"。
        animbank = "ui_chest_1x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_1x2"。
        animbuild = "ui_chest_1x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
-- ★ 自定义开合音效（meta4 前缀 = 鱼人 Wurtster? DLC 的资源前缀）。
--   参见第 508-513 行那段关于「世界音效 vs HUD 音效」的注释。
        opensound = "meta4/mermery/open",
-- ★ 关箱 UI 音效，同样只在客户端播放（同上）。
        closesound = "meta4/mermery/close",
    },
-- usespecificslotsforitems = true：slot 1/2 不可互换。
    usespecificslotsforitems = true,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【★ itemtestfn 范例 K：slot 参数的三分支，与第 425 行 portablespicer 同型】
--   唯一区别是这里用 prefab 精确匹配（twigs/rocks），那里用标签（preparedfood/spice）。
--   ★ 又一次印证：**规则的具体程度由语义确定程度决定**，框架完全通用。
function params.merm_toolshed.itemtestfn(container, item, slot)
    return
        not container.inst:HasTag("burnt") and (
            (slot == 1 and item.prefab == "twigs") or
            (slot == 2 and item.prefab == "rocks") or
-- slot == nil 的兜底：两种都接受 → 拖拽时不高亮任何特定格也能放下。
            (slot == nil and (item.prefab == "twigs" or item.prefab == "rocks"))
        )
end

-- deepcopy 派生二代：只有槽位布局不变，判定靠第 950 行覆盖。
params.merm_toolshed_upgraded = deepcopy(params.merm_toolshed)

-- ── merm_armory（鱼人军械库）区块 ──
--------------------------------------------------------------------------
--[[ merm_armory ]]
--------------------------------------------------------------------------

-- ★ 完整 deepcopy（第 944 行用的是 deepcopy，这里也是——风格一致）。
--   注意第 43/137/168/389/782 行的引用赋值是**少数派**，本文件主流是 deepcopy。
params.merm_armory = deepcopy(params.merm_toolshed)

-- 整体替换 slotbg：木头 + 草。★ 用「整体替换」而非「逐项覆盖」表达「这一组全换」。
params.merm_armory.widget.slotbg =
{
    { image = "inv_slot_log.tex",       atlas = "images/hud2.xml" },
    { image = "inv_slot_cutgrass.tex" , atlas = "images/hud2.xml"},
}

-- 军械库的 itemtestfn 覆盖：log / cutgrass。同样是 prefab 精确匹配。
function params.merm_armory.itemtestfn(container, item, slot)
    return
        not container.inst:HasTag("burnt") and (
            (slot == 1 and item.prefab == "log") or
            (slot == 2 and item.prefab == "cutgrass") or
            (slot == nil and (item.prefab == "log" or item.prefab == "cutgrass"))
        )
end

-- 【蓝图：merm_armory_upgraded】鱼人军械库升级版
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.merm_armory_upgraded = deepcopy(params.merm_armory)

-- ── livingtree_halloween（万圣节树）区块 ──
--------------------------------------------------------------------------
--[[ livingtree_halloween ]]
--------------------------------------------------------------------------

-- 万圣节树：3 横格，放万圣节装饰（南瓜灯等）。
params.livingtree_halloween =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-(64 + 12), 0, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 0, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(64 + 12, 0, 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x1"。
        animbank = "ui_chest_3x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x1"。
        animbuild = "ui_chest_3x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 单标签 + burnt 守卫。与第 993 行同型的最短写法。
--   ★ 三个槽用同一张 Vector3 公式 `-(64+12)/0/+(64+12)`：间距 76，比标准 75 多 1。
--     偏移 12 是为了给「物品图标比格子略大」的美术留边距。
function params.livingtree_halloween.itemtestfn(container, item, slot)
    return item:HasTag("halloween_ornament") and not container.inst:HasTag("burnt")
end

-- ── icebox（冰箱）区块 ★★★ 本文件最重要的区块 ──
--------------------------------------------------------------------------
--[[ icebox ]]
--------------------------------------------------------------------------

-- 【★★★ 冰箱：type = "chest"，但它才是「物品筛选」的教科书】
--   ★★ 关键认知：**冰箱并没有「冰箱类型」**。它的 type 和普通木箱一模一样，
--     它的特殊性 100% 来自下面第 1019 行的 itemtestfn。
--     把这个 itemtestfn 删掉，冰箱就会变成能装一切的 9 格箱子。
--     ⇒ 这就是「DST 不用类型枚举做物品筛选」的实证。
params.icebox =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x3"。
        animbank = "ui_chest_3x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x3"。
        animbuild = "ui_chest_3x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ 冰箱的槽位坐标与 chester（第 85 行）**逐字相同**（80 间距 3x3）。
--   ⇒ 冰箱 UI 与木箱 UI 用同一套坐标，美术换图即可 —— 布局参数已高度抽象。
for y = 2, 0, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.icebox.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 80, 0))
    end
-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。
end

-- 【★★ 四层漏斗：全库最值得读的 itemtestfn】逐层拆解：
--   第 1 层（1020 行）：**显式白名单标签** —— icebox_valid / inventoryitemtemperature；
--   第 2 层（1025 行）：**状态门** —— 必须有 fresh/stale/spoiled 之一，否则拒；
--   第 3 层（1029 行）：**生物排除** —— smallcreature 一律拒（活的东西不能进冰箱）；
--   第 4 层（1034 行）：**类型枚举遍历** —— 遍历 FOODTYPE 找 edible_<TYPE>。
--   ★ 为什么第 4 层要遍历？因为 edible 标签有 20 多种（constants.lua:2022 FOODTYPE），
--     写死 20 个 or 条件不可维护，遍历枚举只需 5 行。
--   ⚠ 但遍历也带来代价：**新加一种 FOODTYPE 不会自动让旧物品变成可放入**，
--     它只是让「已经打好 edible_XXX 标签的物品」通过。若新食物没打标签就进不去冰箱。
function params.icebox.itemtestfn(container, item, slot)
-- 第 1 层：两条快速通道。icebox_valid 是「模组/官方指定的合法物」逃生口；
--   inventoryitemtemperature 指「有温度属性」的物品（如温度计、水银温度计类道具）。
--   ★ 这两条是为了**兼容性与特殊道具**而开的口子——规则永远需要后门。
    if item:HasAnyTag("icebox_valid", "inventoryitemtemperature") then
        return true
    end

-- ★ 原注释保留：「--Perishable」。这一个词就概括了第 2 层的意图。
--   perishable（易腐品）组件会自动打上 fresh/stale/spoiled 三个标签之一，
--   所以「有这三个标签」≡「这东西会腐烂」≡「放冰箱有意义」。
    --Perishable
-- 第 2 层：不是易腐品 → 直接拒。这排除了木头、石头、工具等一切非食物。
    if not item:HasAnyTag("fresh", "stale", "spoiled") then
        return false
    end

-- 第 3 层：★ 易腐品里的例外——小生物不许进。
--   为什么？活物（如小蜘蛛、蜜蜂）进了冰箱会「冻住」或数据异常。
--   ⚠ 这里只排除了 smallcreature 标签；若某种生物没有这个标签仍会漏进来。
--     说明这是一个**标签驱动的补丁**，不是根本解法。
	if item:HasTag("smallcreature") then
		return false
	end

-- 第 4 层：遍历 FOODTYPE 全枚举，检查对应 edible_ 标签。
--   ★ 与第 1378 行胡子袋用 FOODGROUP.OMNI.types 的差别：
--     FOODTYPE 是**全集**（20+ 种），FOODGROUP.OMNI 是**子集**（6 种）。
--     冰箱要什么都能放（全集），胡子袋只要玩家能吃的（OMNI 集）。
    --Edible
    for k, v in pairs(FOODTYPE) do
        if item:HasTag("edible_"..v) then
            return true
        end
    end

    return false
end

-- ── saltbox（盐罐）区块 ──
--------------------------------------------------------------------------
--[[ saltbox ]]
--------------------------------------------------------------------------

-- ★ deepcopy(icebox) 后**整体覆盖 itemtestfn** —— 派生式配置的标准三步。
--   布局/美术/槽位全部继承，只换规则。
params.saltbox = deepcopy(params.icebox)

-- 【★ itemtestfn 范例 L：比冰箱更严的漏斗】条件差异逐条对照：
--   · 不再需要 icebox_valid 快速通道（但保留了 saltbox_valid）；
--   · 额外要求 HasTag("cookable") —— **只放能烹饪的易腐品**；
--   · 额外排除 deployable（可部署物，如帐篷）—— 盐罐不是仓库；
--   · 排除 smallcreature（同冰箱）；
--   · ★★ 额外要求 `item.replica.health == nil` —— 排除有血条的东西（如活体）。
--   ⇒ 综合效果：盐罐 = 「能下锅烹饪的、不是活物、不是帐篷的食物」。
function params.saltbox.itemtestfn(container, item, slot)
    return (item:HasAnyTag("fresh", "stale", "spoiled")
		and item:HasTag("cookable")
		and not item:HasAnyTag("deployable", "smallcreature")
-- ⚠ 疑似缺陷：`item.replica.health` 在**服务端**访问 replica。
--   推理依据：
--     ① entityscript.lua:244 `self.replica = { _ = {}, inst = self }` 说明服务端
--       也存在 replica 表（且 health 是 REPLICATABLE_COMPONENTS 之一，见
--       entityreplica.lua:15），所以**不会崩**；
--     ② 但语义可疑：服务端上 replica.health 通常只在客户端副本创建后才填充，
--       在服务端拿它当「有没有血条」的判据，行为依赖引擎实现细节；
--     ③ 对照 components/container.lua 全文，它判定血条一律用
--       `item.components.inventoryitem` 这类**服务端组件**，从不用 .replica；
--     ④ 同型写法也出现在 componentactions.lua:1575（preservative 动作判定），
--       那里同样是客户端侧代码（componentactions 几乎全在客户端跑），所以那边没问题。
--   ⇒ 结论：**本处服务端访问 replica 属可疑写法**，但因为 replica 表在两端都存在，
--     实际不会崩；风险是若 itemtestfn 在服务端被调用时 replica 尚未就绪，
--     判断可能与预期不符。仅标注，不改代码。
		and item.replica.health == nil)
		or item:HasTag("saltbox_valid")
end

-- ── krampus_sack（圣诞怪的口袋）区块 ──
--------------------------------------------------------------------------
--[[ krampus_sack ]]
--------------------------------------------------------------------------

-- 口袋类容器（type = "pack" + issidewidget = true），和背包同型。
--   ★ 2x8 = 16 格（for y = 0, 6 → 7 行 × 2 列 = 14 格，美术名说 2x8）。
--     ⚠ 实际算出 **14 格**，而美术是 ui_krampusbag_2x8（2x8=16）。
--     推理依据：第 1076 行 `for y = 0, 6 do` 共 7 轮，每轮插 2 个 → 14。
--     这是「美术比逻辑多 2 格」的常见情况（美术留了装饰性空槽）。
--     不构成 bug，因为第 15 行数的是 slotpos 长度 = 14，UI 只画 14 个格子。
params.krampus_sack =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_krampusbag_2x8"。
        animbank = "ui_krampusbag_2x8",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_krampusbag_2x8"。
        animbuild = "ui_krampusbag_2x8",
        --pos = Vector3(-5, -120, 0),
-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -130, 0)。
        pos = Vector3(-5, -130, 0),
    },
-- issidewidget：同第 58 行（首次定义），此处值 = true。
    issidewidget = true,
-- type = "pack"
--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "pack",
-- openlimit = 1：同类互斥，同一时刻只能开一个（与背包一致的体验）。
    openlimit = 1,
}

-- ★ 槽位生成循环（顶层）：y = 0 … 6 → **7 轮**。
--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 7 × 2 = **14 个槽**，即「圣诞怪口袋 14 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 14），存档按编号还原
for y = 0, 6 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.krampus_sack.widget.slotpos, Vector3(-162, -75 * y + 240, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.krampus_sack.widget.slotpos, Vector3(-162 + 75, -75 * y + 240, 0))
-- 循环结束：已插入 **14 个** slotpos 坐标，本容器的 numslots 定为 14。
end

-- ── piggyback（背背怪背包）区块 ──
--------------------------------------------------------------------------
--[[ piggyback ]]
--------------------------------------------------------------------------

-- 又一个 pack 类容器：2x6 = 12 格（for y = 0, 5 → 6 行 × 2 = 12，与美术 2x6 一致）。
params.piggyback =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_piggyback_2x6"。
        animbank = "ui_piggyback_2x6",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_piggyback_2x6"。
        animbuild = "ui_piggyback_2x6",
-- 又是被注释掉的旧坐标 + 新坐标。对照第 30/31 行的 backpack。
--        pos = Vector3(-5, -50, 0),
-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -90, 0)。
        pos = Vector3(-5, -90, 0),
    },
-- issidewidget：同第 58 行（首次定义），此处值 = true。
    issidewidget = true,
-- type = "pack"
--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "pack",
-- openlimit：同第 60 行（首次定义），此处值 = 1。
    openlimit = 1,
}

-- ★ 槽位生成循环（顶层）：y = 0 … 5 → **6 轮**。
--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 6 × 2 = **12 个槽**，即「背背怪背包 12 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 12），存档按编号还原
for y = 0, 5 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.piggyback.widget.slotpos, Vector3(-162, -75 * y + 170, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.piggyback.widget.slotpos, Vector3(-162 + 75, -75 * y + 170, 0))
-- 循环结束：已插入 **12 个** slotpos 坐标，本容器的 numslots 定为 12。
end

-- ── teleportato_base（土豆地传送锅）区块 ──
--------------------------------------------------------------------------
--[[ teleportato ]]
--------------------------------------------------------------------------

-- 传送锅：4 竖格。★ type = "cooker" 且**没有 acceptsstacks = false**（默认 true）。
--   ⇒ 传送锅可以堆叠，而烹饪锅不行——同样是锅，交互却不同（有意为之）。
params.teleportato_base =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 64 + 32 + 8 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(64 + 32 + 8 + 4), 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_cookpot_1x4"。
        animbank = "ui_cookpot_1x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_cookpot_1x4"。
        animbuild = "ui_cookpot_1x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 0, 0)。
        pos = Vector3(0, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
        buttoninfo =
        {
-- ★ 传送锅的按钮（ACTIVATE.GENERIC）是**空函数**（第 1137-1140 行），
--   所以玩家点了没反应。与第 1187 行机房的「无 validfn（永远可点）」形成对比：
--     传送锅 = 按钮可点但无效果；机房 = 按钮可点且有效果。
            text = STRINGS.ACTIONS.ACTIVATE.GENERIC,
            position = Vector3(0, -165, 0),
        },
    },
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【itemtestfn 范例 M：黑名单式，极简】只排除 nonpotatable。
--   ★ 这是「黑名单优于白名单」的典型场景：传送锅的语义是「什么都能传」，
--     若用白名单就要维护一张无限长的表；用黑名单只需排除明确的坏物。
function params.teleportato_base.itemtestfn(container, item, slot)
    return not item:HasTag("nonpotatable")
end

-- 【★ 空函数体：被刻意阉割的按钮】函数只含注释，不做任何事。
--   ★ 原注释保留：「see teleportato.lua, not supported in multiplayer yet」
--     /「CheckNextLevelSure(inst, doer)」（后者被注释掉）。
--   ⇒ 结论：传送锅按钮在联机模式下**完全无效**（连 UI 都不响应）。
--     这是一条「已知限制」的显式声明，比留个会崩的函数好得多。
function params.teleportato_base.widget.buttoninfo.fn(inst, doer)
    --see teleportato.lua, not supported in multiplayer yet
    --CheckNextLevelSure(inst, doer)
end

-- ── balatro machine（同步机房）区块 ──
--------------------------------------------------------------------------
--[[ balatro machine ]]
--------------------------------------------------------------------------

-- 机房：5 个**横排**槽，间距 68（比标准 75/80 紧凑）。
params.balatro_machine =
{
    widget =
    {
        slotpos =
        {
-- ★ 前 4 行被注释掉的 slotpos：竖排版布局的残留。
--   说明这个容器从「竖排 4 格 + 预留 1 格」改成「横排 5 格」。
--   ⚠ 但 animbank/animbuild 仍是 ui_cookpot_1x4（1x4 = 4 格），与 5 个槽位不符。
--     这是一处**美术资源与逻辑不同步**的痕迹（槽位会画到图外）。仅记录。
           -- Vector3(0, 64 + 32 + 8 + 4 + 80, 0),
           -- Vector3(0, 64 + 32 + 8 + 4, 0),
           -- Vector3(0, 32 + 4, 0),
           -- Vector3(0, -(32 + 4), 0),
           -- Vector3(0, -(64 + 32 + 8 + 4), 0),

-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 0, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(68, 0, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(68+68, 0, 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(68+68+68, 0, 0),
-- 内联槽位坐标（本容器第 5 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(68+68+68+68, 0, 0),

        },
        slotbg =
        {
            { image = "sisturn_slot_petals.tex" },
            { image = "sisturn_slot_petals.tex" },
            { image = "sisturn_slot_petals.tex" },
            { image = "sisturn_slot_petals.tex" },
            { image = "sisturn_slot_petals.tex" },            
        },        
-- ⚠ 与上面呼应：animbank 写的是 1x4，slotpos 有 5 个 —— **美术/逻辑不同步**。
--   推理依据：第 1164 行 table.insert 到 5 个坐标（0/68/136/204/272），
--     而 slotbg 也给了 5 张贴图（第 1171 行），唯独 animbank 名是 1x4。
--   ⇒ 推测：美术新增了第 5 格但没换 animbank（或反之）。仅标注，不改代码。
        animbank = "ui_cookpot_1x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_cookpot_1x4"。
        animbuild = "ui_cookpot_1x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(100, 0, 0)。
        pos = Vector3(100, 0, 0),
        buttoninfo =
        {
            text = STRINGS.ACTIONS.ACTIVATE.GENERIC,
            position = Vector3(68+68, -68, 0),
        },        
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
-- openlimit：同第 60 行（首次定义），此处值 = 1。
    openlimit = 1,
}

-- 【itemtestfn 范例 N：近乎无条件放行】只排除 burnt。
--   ★ 原注释保留：`--and item.prefab == "kelp"` —— 被注释掉的收窄条件，
--     说明这里原本打算改成只放海藻，最终放宽成「什么都行（除烧焦）」。
--   ⚠ 这是一个**危险的宽松规则**：若有物品能进机房而不该进，游戏平衡会出问题。
--     保留原注释至少让人知道这里曾经更严格。
function params.balatro_machine.itemtestfn(container, item, slot)
    return not container.inst:HasTag("burnt") --and item.prefab == "kelp"
end

function params.balatro_machine.widget.buttoninfo.fn(inst, doer)
    if inst.components.container ~= nil then
        BufferedAction(doer, inst, ACTIONS.ACTIVATE_CONTAINER):Do()
    elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
        SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.ACTIVATE_CONTAINER.code, inst, ACTIONS.ACTIVATE_CONTAINER.mod_name)
    end
end
-- ★ 被整块注释掉的 validfn（用 --[[ ]] 长注释而非 --）。
--   ⇒ 机房按钮**没有 validfn**，即按钮永远可点。
--   对照 cookpot/sewingmachine 都有 validfn，这里被刻意去掉（因为内容物杂）。
--[[
function params.balatro_machine.widget.buttoninfo.validfn(inst)
    return inst.replica.container ~= nil and inst.replica.container:IsFull()
end
]]


-- ── treasurechest（宝箱）区块 ──
--------------------------------------------------------------------------
--[[ treasurechest ]]
--------------------------------------------------------------------------

-- 宝箱：3x3 = 9 格。★ 注意本蓝图**没有 itemtestfn** → 什么都能装。
--   这与冰箱形成鲜明对照：同样是 9 格，type 都是 "chest"，
--     唯一的差别就是有没有 itemtestfn。
params.treasurechest =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x3"。
        animbank = "ui_chest_3x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x3"。
        animbuild = "ui_chest_3x3",
-- ★★ animbank_upgraded / animbuild_upgraded：**升级态美术**的第一份定义。
--   宝箱可被升级（万圣节/季节活动），升级后 UI 换一套图。
--   ⇒ 这两个字段的消费点不在本文件（grep 核实：只在这里被写入），
--     实际读取方是 widgets 层的 ContainerWidget（按 inst 的升级状态选图）。
--   ⚠ 这类「只写不读」的字段之所以没被清理，正是因为读取方在仓库外的渲染层。
        animbank_upgraded = "ui_chest_upgraded_3x3",
-- ★ 升级态构建名。
        animbuild_upgraded = "ui_chest_upgraded_3x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「宝箱 3x3=9 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原
for y = 2, 0, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.treasurechest.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 80, 0))
    end
-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。
end

-- ⚠ 疑似缺陷：连续四行引用赋值（pandoraschest/chest_mimic/skullchest/terrariumchest）。
--   推理依据：与第 782 行同类。这四个都直接复用 treasurechest 的同一张 widget 表。
--   ⇒ 风险：模组若单独调整 skullchest 的美术，会连带改掉潘多拉箱/拟态怪箱/ terrarium箱。
--     ★ 对照第 1235 行 quagmire_safe 用的是 deepcopy —— 同一区块内两种写法并存，
--     进一步说明这是习惯问题而非设计意图。**不改代码，仅标注**。
params.pandoraschest = params.treasurechest
-- 【蓝图：chest_mimic】拟态怪箱
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.chest_mimic = params.pandoraschest
-- 【蓝图：skullchest】骷髅宝箱
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.skullchest = params.treasurechest
-- 【蓝图：terrariumchest】生态箱
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.terrariumchest = params.treasurechest

-- ★ 用 deepcopy 派生（与上面四行形成鲜明对照）。
--   quagmire_safe 只换美术名，槽位布局保持 3x3。
-- ★ quagmire_safe 用 deepcopy 而第 1230 行四连用赋值 —— 同区块两种风格。
params.quagmire_safe = deepcopy(params.treasurechest)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.quagmire_safe.widget.animbank = "quagmire_ui_chest_3x3"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.quagmire_safe.widget.animbuild = "quagmire_ui_chest_3x3"

-- 古代船（Ocean Trawler 遗迹）容器：deepcopy 后换成 4x4 = 16 格。
params.boat_ancient_container = deepcopy(params.treasurechest)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.boat_ancient_container.widget.animbank = "ui_boat_ancient_4x4"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.boat_ancient_container.widget.animbuild = "ui_boat_ancient_4x4"
-- ★ 显式清空 slotpos 再重新生成 —— 因为 deepcopy 带来的 9 个坐标需要作废。
--   这是「整体替换」技法：与其逐个删除，不如清空重建。
params.boat_ancient_container.widget.slotpos = {}

-- 4x4 = 16 格。★ 这是本文件里**槽位数最多**的静态蓝图之一，
--   直接把 containers.MAXITEMSLOTS（第 2499 行）顶到 16。
for y = 3, 0, -1 do
    for x = 0, 3 do
-- 坐标偏移 -80*2.5 = -200（半格偏移的 4 格版），同样为了美术居中。
        table.insert(params.boat_ancient_container.widget.slotpos, Vector3(80 * x - 80 * 2.5 + 80, 80 * y - 80 * 2.5 + 80, 0))
    end
-- 循环结束：已插入 **16 个** slotpos 坐标，本容器的 numslots 定为 16。
end

-- ── dragonflychest（蜻蜓箱）区块 ──
--------------------------------------------------------------------------
--[[ dragonflychest ]]
--------------------------------------------------------------------------

-- ⚠ 疑似缺陷：params.minotaurchest = params.shadowchester —— 又一处引用赋值。
--   推理依据：紧邻的第 1255 行 dragonflychest 用的是 deepcopy。
--   minotaurchest（牛头人宝箱）直接共享 shadowchester 的 widget 表。
--   ⇒ 与第 95-96 行原注释呼应：「keep definition for dragonflychest, 
--     minotaurchest, mods」—— 这两个确实需要保留定义，但**共享 vs 深拷贝**
--     在这里是两种不同的保留方式。仅标注，不改代码。
params.minotaurchest = params.shadowchester
-- deepcopy + 只设置**升级态**美术（普通态美术仍继承 shadowchester 的）。
--   ⇒ 蜻蜓箱平时是暗影 Chester 的样子，升级后才变。
params.dragonflychest = deepcopy(params.shadowchester)
-- ★ 升级态贴图库名（箱子被季节活动升级后使用）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.dragonflychest.widget.animbank_upgraded = "ui_chester_upgraded_3x4"
-- ★ 升级态构建名。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.dragonflychest.widget.animbuild_upgraded = "ui_chester_upgraded_3x4"

-- ── antlionhat（沙尘蜂帽）区块 ──
--------------------------------------------------------------------------
--[[ antlionhat ]]
--------------------------------------------------------------------------

-- 沙尘蜂帽：1 格，放「地砖」。★ type = "hand_inv" —— UI 挂在**手持物区**。
--   参见 screens/playerhud.lua:395 `(_type == "hand_inv" and self.controls.inv.hand_inv)`。
params.antlionhat =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {。
        slotpos = {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 2, 0),
        },
        slotbg =
        {
            { image = "turf_slot.tex", atlas = "images/hud2.xml" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_antlionhat_1x1"。
        animbank = "ui_antlionhat_1x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_antlionhat_1x1"。
        animbuild = "ui_antlionhat_1x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(106, 40, 0)。
        pos = Vector3(106, 40, 0),
    },
-- type = "hand_inv"
--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "hand_inv",
-- excludefromcrafting = true：★ 帽子里的地砖**不参与合成搜索**。
--   消费点：components/inventory.lua 的 GetCraftingIngredient / GetSpecializedContainers。
--   ⇒ 理由：合成面板不该把玩家挂在帽子上的东西当材料翻出来。
--   ⚠ 但第 1373/1408/1444 行 beard_sack 把同一行注释掉了 —— 
--     说明这个字段的语义在不同容器里被有意区分（胡子袋要参与合成）。
    excludefromcrafting = true,
}

-- 【itemtestfn 范例 O：标签 + 额外条件】groundtile 标签 **且** item.tile 存在。
--   ★ `item.tile` 是引擎属性（这物品带着一张地图贴图数据）。
--     双重条件确保放进去的一定是「能铺的地砖」，而不是任意带 tag 的道具。
function params.antlionhat.itemtestfn(container, item, slot)
    return item:HasTag("groundtile") and item.tile
end

-- ── fish_box（鱼箱）区块 ──
--------------------------------------------------------------------------
--[[ fish_box ]]
--------------------------------------------------------------------------

-- 鱼箱：5x4 = 20 格（for y=2.5..-0.5 三行 × for x=-1..3 五列）。
params.fish_box =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_fish_box_5x4"。
        animbank = "ui_fish_box_5x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_fish_box_5x4"。
        animbuild = "ui_fish_box_5x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 220, 0)。
        pos = Vector3(0, 220, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ⚠ y 从 **2.5** 递减到 -0.5，x 从 **-1** 到 3 —— 双向半格偏移，
--   坐标系原点不在左上角。视觉上没错，但 slotpos[k] 的「行/列」推导必须小心。
for y = 2.5, -0.5, -1 do
    for x = -1, 3 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.fish_box.widget.slotpos, Vector3(75 * x - 75 * 2 + 75, 75 * y - 75 * 2 + 75, 0))
    end
-- 循环结束：已插入 **20 个** slotpos 坐标，本容器的 numslots 定为 20。
end

-- 单标签白名单：smalloceancreature（小型海洋生物：鱼、海星、海胆…）。
function params.fish_box.itemtestfn(container, item, slot)
    return item:HasTag("smalloceancreature")
end


-- ── ocean fishing rod（海洋钓竿）区块 ──
--------------------------------------------------------------------------
--[[ ocean fishing rod ]]
--------------------------------------------------------------------------

-- 钓竿：2 格专用槽（slot1 = 浮标，slot2 = 诱饵），type = "hand_inv"。
--   ★ 与第 396 行 portablespicer 完全同型：手持物 + 双格语义 + 专用槽。
params.oceanfishingrod =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0,   32 + 4,  0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
        },
        slotbg =
        {
            { image = "fishing_slot_bobber.tex" },
            { image = "fishing_slot_lure.tex" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_cookpot_1x2"。
        animbank = "ui_cookpot_1x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_cookpot_1x2"。
        animbuild = "ui_cookpot_1x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 60, 0)。
        pos = Vector3(0, 60, 0),
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- ★ 槽位是否有语义：true 时物品必须进 itemtestfn(item, slot) 指定的**那一格**。
--   落点：components/container.lua:298 GetSpecificSlotForItem（逐槽试）、451 GiveItem（优先用）。
    usespecificslotsforitems = true,
-- type = "hand_inv"
--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "hand_inv",
-- 箱内物品是否**排除在合成搜索之外**。true=不参与合成（沙尘蜂帽/弹弓用）。
--   ⚠ 对照第 1373/1408/1444 行：beard_sack 把同一行注释掉了，即胡子袋要参与合成。
    excludefromcrafting = true,
}

-- 【★ itemtestfn 范例 P：三槽三分支】这里 slot 只有 1 和 2（第 1344-1345 行），
--   但 nil 分支写在**最前面**（第 1343 行）—— 顺序与 portablespicer 相反。
--   ⚠ 顺序不同不影响语义（全是 or），但说明这类分支代码是**复制粘贴后手工调整**的，
--     维护时容易改错。
function params.oceanfishingrod.itemtestfn(container, item, slot)
-- slot == nil 时两种都收（拖拽悬停态）。注意这一行排在最前。
	return (slot == nil and item:HasAnyTag("oceanfishing_bobber", "oceanfishing_lure"))
		or (slot == 1 and item:HasTag("oceanfishing_bobber"))
		or (slot == 2 and item:HasTag("oceanfishing_lure"))
end


-- ── beard（胡子袋）区块 ──
--------------------------------------------------------------------------
--[[ beard ]]
--------------------------------------------------------------------------

-- 【★ 胡子袋：side_inv_behind 类型】UI 挂在「角色背后的侧边区」。
--   参见 screens/playerhud.lua:397 `("side_inv_behind" and self.controls.containerroot_side_behind)`。
--   ★ 这是唯一一种「UI 在角色身后」的容器类型，用于沃尔托克斯的发型袋。
params.beard_sack_1 =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 0, 0),
        },
        slotbg =
        {
            { image = "inv_slot_morsel.tex" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_beard_1x1"。
        animbank = "ui_beard_1x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_beard_1x1"。
        animbuild = "ui_beard_1x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-82, 89, 0)。
        pos = Vector3(-82, 89, 0),
-- 提示条底部对齐距离（像素）。
        bottom_align_tip = -100,
    },
-- type = "side_inv_behind"
--   角色背后侧边容器（playerhud.lua:397）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "side_inv_behind",
-- acceptsstacks = true 是**显式写出**的默认值（容器组件第 35 行已默认 true）。
--   ★ 写出它是为了**自文档化**：说明这个容器确实允许堆叠（对比第 322 行的 false）。
--     冗余但有益——读蓝图的人不必去翻组件源码就知道栈行为。
    acceptsstacks = true,
-- lowpriorityselection = true：★ **从背包自动取物时优先级最低**。
--   推理：拿食物时，先看背包再看胡子袋 —— 胡子袋是「补充装」不是「主仓库」。
--   ⚠ 但 grep 核实：本文件只是写入 lowpriorityselection，
--     而 components/container.lua:73-84 的 widgetprops 白名单**不含**它，
--     components/container.lua 的 WidgetSetup 第 91 行仍会把所有键浅拷贝过去
--     （因为 widgets.container 仍会通过 `container[k] = v` 灌入 self），
--     真正读取方在其他文件。**这里只做写入登记，判定逻辑不在容器系统**。
    lowpriorityselection = true,
   -- excludefromcrafting = false,
}

-- 【★ itemtestfn 范例 Q：FOODGROUP 子集遍历】与冰箱第 1034 行的全集遍历对照：
--   · 冰箱：pairs(FOODTYPE) —— 20+ 种全放行；
--   · 胡子袋：pairs(FOODGROUP.OMNI.types) —— 只有 6 种（MEAT/VEGGIE/INSECT/
--     SEEDS/GENERIC/GOODIES，见 constants.lua:2049）。
--   ⇒ 差别是「玩家能吃的所有东西」，即 OMNI 组。这是有意的收窄。
function params.beard_sack_1.itemtestfn(container, item, slot)
-- ★ 原注释保留：「--Edible」。与第 1033 行同款。
    --Edible
    for k, v in pairs(FOODGROUP.OMNI.types) do
        if item:HasTag("edible_"..v) then
            return true
        end
    end
-- ⚠ 疑似缺陷：函数体末尾**没有 return false**，只有 if 块和一行空行。
--   推理依据：Lua 函数无 return 时返回 nil（falsy），语义上等价于 return false；
--     但第 1418/1454 行 beard_sack_2/3 都**显式**没有 return，两者一致；
--     而第 1519 行 slingshot 的 itemtestfn 末尾是 `return item:HasTag(...)` 明确返回。
--   ⇒ 这不是 bug（nil 与 false 在 `if` 判断中等价），
--     但**风格不统一**会让读者怀疑是否漏写。仅标注，不改代码。
      
end

-- 二代胡子袋：2 格。
params.beard_sack_2 =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-(64 + 12)/2, 0, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3( (64 + 12)/2, 0, 0),
        },
        slotbg =
        {
            { image = "inv_slot_morsel.tex" },
            { image = "inv_slot_morsel.tex" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_beard_2x1"。
        animbank = "ui_beard_2x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_beard_2x1"。
        animbuild = "ui_beard_2x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-82, 89, 0)。
        pos = Vector3(-82, 89, 0),
-- bottom_align_tip：同第 1368 行（首次定义），此处值 = -100。
        bottom_align_tip = -100,
    },
-- type = "side_inv_behind" + acceptsstacks + lowpriorityselection —— 与 1 代同构。
    type = "side_inv_behind",
-- acceptsstacks：同第 369 行（首次定义），此处值 = true。
    acceptsstacks = true,
-- ★ 自动取物优先级最低（从背包找东西时先翻别处，找不到才来这里）。
    lowpriorityselection = true,
   -- excludefromcrafting = false,
}

function params.beard_sack_2.itemtestfn(container, item, slot)
    --Edible
    for k, v in pairs(FOODGROUP.OMNI.types) do
        if item:HasTag("edible_"..v) then
            return true
        end
    end
end

-- 三代胡子袋：3 格。
params.beard_sack_3 =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-(64 + 12), 0, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 0, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(64 + 12, 0, 0),
        },
        slotbg =
        {
            { image = "inv_slot_morsel.tex" },
            { image = "inv_slot_morsel.tex" },
            { image = "inv_slot_morsel.tex" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_beard_3x1"。
        animbank = "ui_beard_3x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_beard_3x1"。
        animbuild = "ui_beard_3x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-82, 89, 0)。
        pos = Vector3(-82, 89, 0),
-- bottom_align_tip：同第 1368 行（首次定义），此处值 = -100。
        bottom_align_tip = -100,
    },
-- type = "side_inv_behind"
--   角色背后侧边容器（playerhud.lua:397）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "side_inv_behind",
-- acceptsstacks：同第 369 行（首次定义），此处值 = true。
    acceptsstacks = true,
-- lowpriorityselection：同第 1407 行（首次定义），此处值 = true。
    lowpriorityselection = true,
   -- excludefromcrafting = false,
}

function params.beard_sack_3.itemtestfn(container, item, slot)
    --Edible
    for k, v in pairs(FOODGROUP.OMNI.types) do
        if item:HasTag("edible_"..v) then
            return true
        end
    end
end

-- ── slingshot（弹弓）区块 ──
--------------------------------------------------------------------------
--[[ slingshot ]]
--[[ slingshotex ]]
--[[ slingshot2 ]]
--[[ slingshot2ex ]]
--------------------------------------------------------------------------

-- 弹弓：1 格，放「弹弓弹药」。★ type = "hand_inv"（UI 在手持区）。
--   ★ 与第 1318 行海洋钓竿同型——手持武器类容器的标准形态。
params.slingshot =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0,   32 + 4,  0),
        },
        slotbg =
        {
            { image = "slingshot_ammo_slot.tex" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_cookpot_1x2"。
        animbank = "ui_cookpot_1x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_cookpot_1x2"。
        animbuild = "ui_cookpot_1x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 15, 0)。
        pos = Vector3(0, 15, 0),
    },
-- hand_inv + excludefromcrafting：弹药不参与合成（同第 1279 行沙尘蜂帽的取舍）。
    type = "hand_inv",
-- excludefromcrafting：同第 1339 行（首次定义），此处值 = true。
    excludefromcrafting = true,
}

-- deepcopy + 换美术：三个弹弓变体（普通/骨/宝石）共用同一套逻辑，只换外观。
--   ★ 这就是第 105 行 widgetsetup 浅拷贝的**正面价值**：
--     蓝图里嵌套的 Vector3 是 UI 布局，与逻辑无关，换图不影响判定。
params.slingshotex = deepcopy(params.slingshot)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshotex.widget.animbank = "ui_slingshot_wagpunk_0"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshotex.widget.animbuild = "ui_slingshot_wagpunk_0"

-- 【蓝图：slingshot999ex】弹弓 999 变体（deepcopy slingshotex 换皮）
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.slingshot999ex = deepcopy(params.slingshotex)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshot999ex.widget.animbank = "ui_slingshot_wagpunk"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshot999ex.widget.animbuild = "ui_slingshot_wagpunk"

-- 【★ slingshot2：双格弹弓，且槽序被刻意反转】
--   第 1497 行原注释保留：「--reversed so bottom is slot 1」
--   ★ 这是**槽位语义与视觉顺序解耦**的唯一一处：视觉上 slot 2 在上、slot 1 在下，
--     而 slotpos 数组里 slot 1 写在前面。
--   ⇒ 推论：槽位编号由 slotpos 数组顺序决定，而 UI 绘制位置也由 slotpos 决定，
--     两者本应一致；这里通过「先写上面的坐标却表示下面的槽」人为反转，
--     说明确有下游逻辑依赖「slot 1 = 底部」。仅记录这个反直觉约定。
params.slingshot2 =
{
	widget =
	{
		slotpos =
		{
			--reversed so bottom is slot 1
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(0, 32 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(0, 64 + 32 + 8 + 4, 0),
		},
		slotbg =
		{
			{ image = "slingshot_ammo_slot.tex" },
			{ image = "slingshot_ammo_slot.tex" },
		},
		animbank = "ui_slingshot_bone",
		animbuild = "ui_slingshot_bone",
		pos = Vector3(0, 15, 0),
	},
	type = "hand_inv",
	excludefromcrafting = true,
}

-- 宝石弹弓：deepcopy + 换美术 + ★ 单独调整第 2 槽 y 坐标（第 1517 行）。
--   这展示了「派生后微调单个槽位」的粒度 —— 因为 slotpos 是 Vector3 数组，可以索引。
params.slingshot2ex = deepcopy(params.slingshot2)
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshot2ex.widget.animbank = "ui_slingshot_gems"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshot2ex.widget.animbuild = "ui_slingshot_gems"
params.slingshot2ex.widget.slotpos[2].y = 64 + 32 + 8 + 4 + 32

-- 【★ itemtestfn 范例 R：带前置条件的标签判定】三层：
--   ① 若物品有 REQUIRED_SKILL 字段，先查打开者的技能树是否解锁（第 1528 行）；
--   ② 未解锁 → return false；
--   ③ 解锁（或不需要技能）→ 最终只认 slingshotammo 标签。
--   ★ 这是「弹弓弹药按角色技能树分化」的实现 —— 沃托克斯/ Wortox 相关机制。
function params.slingshot.itemtestfn(container, item, slot)
-- ★ 用「物品自带字段」REQUIRED_SKILL 作为门禁，容器系统本身不知道技能树的存在。
--   ⇒ 设计要点：**物品可以携带自己的准入条件**，容器只需读取。
--     这样新增一个「需要某技能的弹药」不需要改任何容器蓝图。
	if item.REQUIRED_SKILL then
		local owner
-- 与第 819 行 sisturn 同型的双端分支（服务端 GetOpeners / 客户端 ThePlayer）。
		if TheWorld.ismastersim then
			owner = container.inst.components.container:GetOpeners()[1]
		elseif ThePlayer and container:IsOpenedBy(ThePlayer) then
			owner = ThePlayer
		end
-- ★ 原注释保留：「NOTE: can have no owner when loading, or when replacing
--   slingshots when swapping frames」。
--   ⇒ 比第 826 行的 sisturn 多了一个例外：**换弹弓框（换弹药池）时也没有 owner**。
--     推理：换框过程会重建容器实例，此刻无人「打开」它。
--   第 1528 行的 `if owner and ...` 用 owner 非空做了守卫，所以加载期会**跳过**技能检查、
--     直接落到第 1532 行接受弹药 —— 这是有意的「宽松兜底」。
		--NOTE: can have no owner when loading, or when replacing slingshots when swapping frames
		if owner and not (owner.components.skilltreeupdater and owner.components.skilltreeupdater:IsActivated(item.REQUIRED_SKILL)) then
			return false
		end
	end
	return item:HasTag("slingshotammo")
end

-- ★ 四个变体共享同一个 itemtestfn 函数指针。
--   ⚠ 但注意顺序：slingshotex（第 1483 行 deepcopy）与 slingshot2（第 1491 行独立定义）
--     都在这里被赋值。slingshotex 是 deepcopy 来的，本来就没有 itemtestfn，
--     这里补上；slingshot2 已有，这里覆盖成同一个 —— 结果一致。
-- ★ 四个变体共享 itemtestfn：注意 slingshot999ex 是 slingshotex 的 deepcopy（1487 行），
--   所以给它赋值等于「把 slingshotex 的判定也给它一份指针」。函数共享安全。
params.slingshotex.itemtestfn = params.slingshot.itemtestfn
-- ★ 物品筛选闭包，签名固定 (container, item, slot)。
--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。
--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshot999ex.itemtestfn = params.slingshot.itemtestfn
-- ★ 物品筛选闭包，签名固定 (container, item, slot)。
--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。
--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshot2.itemtestfn = params.slingshot.itemtestfn
-- ★ 物品筛选闭包，签名固定 (container, item, slot)。
--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。
--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.slingshot2ex.itemtestfn = params.slingshot.itemtestfn

-- ── slingshotmodscontainer（弹弓改装台）区块 ──
--------------------------------------------------------------------------
--[[ slingshotmodscontainer ]]
--------------------------------------------------------------------------

-- 【★ 改装台：三槽位语义（弹带/弹弓框/握把）+ 1.6 倍放大显示】
--   ★ slotscale = 1.6 / slothighlightscale = 1.75：零件比普通格子大，
--     因为弹弓零件在物品栏里会被缩小显示（弹弓是手持物，格子小）。
--   ⇒ 这是一个纯 UI 参数，与逻辑完全无关，但缺了它零件就看不清。
params.slingshotmodscontainer =
{
	widget =
	{
		slotpos =
		{
-- ★ 原注释保留的行内注释：「--band」「--frame」「--handle」——
--   直接标出 slot1/2/3 分别是弹带/弓框/握把。
--   ★ 这三行行内注释比外部块注释更有价值：它们让 slotpos 数组**自解释**。
			Vector3(220, 125, 0),	--band
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(20, -60, 0),	--frame
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
			Vector3(220, -150, 0),	--handle
		},
		slotbg =
		{
			{ image = "inv_slot_sketchy.tex", atlas = "images/hud2.xml" },
			{ image = "inv_slot_sketchy.tex", atlas = "images/hud2.xml" },
			{ image = "inv_slot_sketchy.tex", atlas = "images/hud2.xml" },
		},
		slotscale = 1.6,
		slothighlightscale = 1.75,
		animbank = "ui_slingshotmods",
		animbuild = "ui_slingshotmods",
		pos = Vector3(200, 0, 0),
		side_align_tip = 100,
		--V2C: -override the default widget sound, which is heard only by the client
		--     -most containers disable the client sfx via skipopensnd/skipclosesnd,
		--      and play it in world space through the prefab instead.
		opensound = "meta5/walter/slingshot_UI_open_close",
		closesound = "meta5/walter/slingshot_UI_open_close",
		--
	},
-- usespecificslotsforitems + acceptsstacks=false + type=cooker + openlimit=1 —— 四项全开。
	usespecificslotsforitems = true,
	acceptsstacks = false,
	type = "cooker",
	openlimit = 1,
}

-- 【★ itemtestfn 范例 S：三分支 + 显式 return false 兜底】
--   与第 425/935 行同型，但**末尾有 return false**（第 1602 行），
--   这才是完整写法 —— slot 超出 1..3 时（不可能，但防御性）返回 false。
--   ★ 对照第 1383 行 beard_sack_1 没有 return：同一个团队里两种风格。
function params.slingshotmodscontainer.itemtestfn(container, item, slot)
	if item.REQUIRED_SKILL then
		local owner
		if TheWorld.ismastersim then
			owner = container.inst.components.container:GetOpeners()[1]
		elseif ThePlayer and container:IsOpenedBy(ThePlayer) then
			owner = ThePlayer
		end
		--NOTE: can have no owner when loading
		if owner and not (owner.components.skilltreeupdater and owner.components.skilltreeupdater:IsActivated(item.REQUIRED_SKILL)) then
			return false
		end
	end

-- ★ 三个 slot 分支用 if/elseif 链，最后 else nil 分支。
--   ⚠ 与第 425 行 portablespicer 的「or 表达式」写法不同，这里是命令式分支。
--     两种写法都能用，但命令式更容易加日志/调试分支。
	if slot == 1 then
		return item:HasTag("slingshot_band")
	elseif slot == 2 then
		return item:HasTag("slingshot_frame")
	elseif slot == 3 then
		return item:HasTag("slingshot_handle")
	elseif slot == nil then
		return item:HasAnyTag("slingshot_band", "slingshot_frame", "slingshot_handle")
	end
	return false
end

-- ── tacklecontainer（钓具箱）区块 ──
--------------------------------------------------------------------------
--[[ tacklecontainer ]]
--------------------------------------------------------------------------

-- 钓具箱：3x2 = 6 格，放浮标与诱饵。
params.tacklecontainer =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_tacklecontainer_3x2"。
        animbank = "ui_tacklecontainer_3x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_tacklecontainer_3x2"。
        animbuild = "ui_tacklecontainer_3x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ y 从 1 到 0（只有 2 行），y 坐标偏移 +120 —— 整体上移，
--   因为 UI 底板下方还要留位置放提示条。
for y = 1, 0, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.tacklecontainer.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 120, 0))
    end
-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。
end

-- 【双标签白名单】oceanfishing_bobber / oceanfishing_lure，任意一个都行。
function params.tacklecontainer.itemtestfn(container, item, slot)
	return item:HasAnyTag("oceanfishing_bobber", "oceanfishing_lure")
end

-- 【★★ priorityfn 的定义方式】`priorityfn = itemtestfn`。
--   ★ 关键：两者签名不同！itemtestfn 是 (container, item, slot)，
--     priorityfn 是 (container, item) —— 调用点见 components/container.lua:319
--     `self:priorityfn(item)`，Lua 会自动传 self 作第一参、item 作第二参，slot 为 nil。
--   ⇒ 因为本例的 itemtestfn 不依赖 slot（第 1629 行没用 slot 参数），
--     直接复用是安全的。★ 但若 itemtestfn 依赖 slot，这么赋值就会**永远传 nil**。
--   ⚠ 这是本文件一个**易被误用的复用技巧**：第 1735 行 seedpouch、第 1764 行 candybag、
--     第 1985 行 battlesong、第 2046 行 elixir、第 2130 行 slingshotammo_container、
--     第 1658 行 supertacklecontainer 都用了同一手法 —— 全部安全（都不依赖 slot）。
params.tacklecontainer.priorityfn = params.tacklecontainer.itemtestfn

-- ── supertacklecontainer（超级钓具箱）区块 ──
--------------------------------------------------------------------------
--[[ supertacklecontainer ]]
--------------------------------------------------------------------------

-- 超级钓具箱：3x5 = 15 格（for y = 1 到 -3）。
params.supertacklecontainer =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_tacklecontainer_3x5"。
        animbank = "ui_tacklecontainer_3x5",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_tacklecontainer_3x5"。
        animbuild = "ui_tacklecontainer_3x5",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 280, 0)。
        pos = Vector3(0, 280, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ y 坐标公式 `80 * y - 45`（不是 -80*2+80）—— 因为是 5 行，
--   需要从中心 45 像素处起算。这是一个**按行数反推偏移**的写法。
for y = 1, -3, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.supertacklecontainer.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 45, 0))
    end
-- 循环结束：已插入 **15 个** slotpos 坐标，本容器的 numslots 定为 15。
end

-- itemtestfn 与 priorityfn 一起共享给超级版（两行成对出现，说明作者知道必须成对设）。
params.supertacklecontainer.itemtestfn = params.tacklecontainer.itemtestfn
-- ★ 专用容器优先判定（弹药包这类）。常与 itemtestfn 共用同一函数，但语义相反：
--   itemtestfn 管「能不能放」，priorityfn 管「优先往哪放」（components/container.lua:319）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.supertacklecontainer.priorityfn = params.tacklecontainer.priorityfn

-- ── sunkenchest（沉箱）区块 ──
--------------------------------------------------------------------------
--[[ sunkenchest ]]
--------------------------------------------------------------------------
-- ★★★ 原注释保留（本文件最有价值的一段工程说明）：
--   「Sunken Chest is an actual container though it can not be opened it often reaches
--    capacity from it's old container data (3x3) we have moved to 3x5 now
--    We can deepcopy supertacklecontainer and set itemtestfn but I am making a entirely
--    new definition to ensure it is not potentially messed with」
--   ★ 逐句翻译与解读：
--     ① 沉箱**是一个真正的容器**（有 slots 数组），但玩家**打不开它**；
--     ② 它经常从小容量（3x3）旧存档数据**满载**进来 —— 即旧档有 9 个物品，
--        新版 numslots 变 15，但加载时物品仍占着原来的槽位；
--     ③ 作者明确考虑了「直接 deepcopy supertacklecontainer 再设 itemtestfn」的捷径，
--        但**故意不用**，理由是「确保它不会被（共享表）意外搞坏」。
--   ⇒ 这段注释是**共享可变表技术债的官方自证**：作者在别的容器上用了
--     第 950 行那种 deepcopy 派生，但在这里拒绝派生，转而手写一份完整定义。
--     这正好印证了本文件第 43/137/168 行那些引用赋值的风险是真实存在的。
-- Sunken Chest is an actual container though it can not be opened it often reaches capacity from it's old container data (3x3) we have moved to 3x5 now
-- We can deepcopy supertacklecontainer and set itemtestfn but I am making a entirely new definition to ensure it is not potentially messed with

-- 手写完整定义（3x5），与 supertacklecontainer 布局相同但**不共享**。
--   ★ 注意它**故意不设 itemtestfn** —— 于是沉箱什么都能装。
--     为什么？因为它打不开，也就没人能往里放东西，规则无意义。
params.sunkenchest =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_tacklecontainer_3x5"。
        animbank = "ui_tacklecontainer_3x5",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_tacklecontainer_3x5"。
        animbuild = "ui_tacklecontainer_3x5",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 280, 0)。
        pos = Vector3(0, 280, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 3x5 槽位生成，与第 1651 行逐字相同 —— 复制粘贴而非共享。
for y = 1, -3, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.sunkenchest.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 45, 0))
    end
-- 循环结束：已插入 **15 个** slotpos 坐标，本容器的 numslots 定为 15。
end

-- ── sacred_chest（圣柜）区块 ──
--------------------------------------------------------------------------
--[[ sacred_chest ]]
--------------------------------------------------------------------------

-- 圣柜：3x2 = 6 格。★ 同样**没有 itemtestfn** —— 万能箱。
params.sacred_chest =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x2"。
        animbank = "ui_chest_3x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x2"。
        animbuild = "ui_chest_3x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「圣柜 3x2=6 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原
for y = 1, 0, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.sacred_chest.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 120, 0))
    end
-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。
end

-- ── seedpouch（种子袋）区块 ──
--------------------------------------------------------------------------
--[[ seedpouch ]]
--------------------------------------------------------------------------

-- 种子袋：2x8 布局（14 格），与 krampus_sack 同规格。
params.seedpouch =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_krampusbag_2x8"。
        animbank = "ui_krampusbag_2x8",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_krampusbag_2x8"。
        animbuild = "ui_krampusbag_2x8",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -130, 0)。
        pos = Vector3(-5, -130, 0),
    },
-- issidewidget：同第 58 行（首次定义），此处值 = true。
    issidewidget = true,
-- type = "pack"
--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "pack",
-- openlimit：同第 60 行（首次定义），此处值 = 1。
    openlimit = 1,
}

-- ★ 槽位生成循环（顶层）：y = 0 … 6 → **7 轮**。
--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 7 × 2 = **14 个槽**，即「种子袋 14 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 14），存档按编号还原
for y = 0, 6 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.seedpouch.widget.slotpos, Vector3(-162, -75 * y + 240, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.seedpouch.widget.slotpos, Vector3(-162 + 75, -75 * y + 240, 0))
-- 循环结束：已插入 **14 个** slotpos 坐标，本容器的 numslots 定为 14。
end

-- 【★ itemtestfn 范例 T：prefab 精确 + 字符串匹配 + 标签三合一】
--   第 1732 行的三重 or 是本文件**最复杂的一条单行规则**：
--     ① prefab 精确等于 "seeds"；
--     ② ★ string.match(prefab, "_seeds") —— 用 Lua 模式匹配找**任意位置**的 "_seeds"；
--        这条覆盖了所有 `xxx_seeds` 变体（前置/后缀变体），
--        string.match 的第一个返回值是匹配到的子串，真值即通过；
--     ③ HasTag("treeseed") —— 兜底的标签通路。
--   ⇒ 推论：一个种子物品只要满足三者之一就能进袋子，不必逐个注册。
--   ⚠ 但 string.match 无锚点，若某物品名含 "_seeds"（如 "seeds_dust"）会被误纳。
function params.seedpouch.itemtestfn(container, item, slot)
    return item.prefab == "seeds" or string.match(item.prefab, "_seeds") or item:HasTag("treeseed")
end

-- priorityfn = itemtestfn（同第 1632 行）。此处安全：第 1732 行不依赖 slot。
params.seedpouch.priorityfn = params.seedpouch.itemtestfn

-- ── candybag（糖果袋）区块 ──
--------------------------------------------------------------------------
--[[ candybag ]]
--------------------------------------------------------------------------

-- 糖果袋：同样是 2x8 = 14 格，与种子袋布局完全一致（复用 krampus 美术）。
params.candybag =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_krampusbag_2x8"。
        animbank = "ui_krampusbag_2x8",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_krampusbag_2x8"。
        animbuild = "ui_krampusbag_2x8",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -130, 0)。
        pos = Vector3(-5, -130, 0),
    },
-- issidewidget：同第 58 行（首次定义），此处值 = true。
    issidewidget = true,
-- type = "pack"
--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "pack",
-- openlimit：同第 60 行（首次定义），此处值 = 1。
    openlimit = 1,
}

-- ★ 槽位生成循环（顶层）：y = 0 … 6 → **7 轮**。
--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 7 × 2 = **14 个槽**，即「糖果袋 14 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 14），存档按编号还原
for y = 0, 6 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.candybag.widget.slotpos, Vector3(-162, -75 * y + 240, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.candybag.widget.slotpos, Vector3(-162 + 75, -75 * y + 240, 0))
-- 循环结束：已插入 **14 个** slotpos 坐标，本容器的 numslots 定为 14。
end

-- 【itemtestfn 范例 U：标签 + 前缀匹配】
--   第 1761 行：`HasAnyTag("halloweencandy", "halloween_ornament")` 或
--     `string.sub(item.prefab, 1, 8) == "trinket_"`。
--   ★ string.sub 取前 8 字符与 "trinket_" 比较 —— 这是**前缀匹配的正确写法**
--     （对比第 1732 行 string.match 无锚点的写法，这里更严谨）。
--   ⇒ 万圣节小丑饰品（trinket_xxx）能进糖果袋。
function params.candybag.itemtestfn(container, item, slot)
    return item:HasAnyTag("halloweencandy", "halloween_ornament") or string.sub(item.prefab, 1, 8) == "trinket_"
end

-- ★ 专用容器优先判定（弹药包这类）。常与 itemtestfn 共用同一函数，但语义相反：
--   itemtestfn 管「能不能放」，priorityfn 管「优先往哪放」（components/container.lua:319）。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.candybag.priorityfn = params.candybag.itemtestfn

-- ── alterguardianhatshard（ alters 监护者帽子碎片）区块 ──
--------------------------------------------------------------------------
--[[ alterguardianhatshard ]]
--------------------------------------------------------------------------

-- 帽子碎片：1 格，放孢子（spore）。type = "chest"（世界里的实体容器）。
params.alterguardianhatshard =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {。
        slotpos = {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-2, 18, 0),
        },
        slotbg =
        {
            { image = "spore_slot.tex", atlas = "images/hud2.xml" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_alterguardianhat_1x1"。
        animbank = "ui_alterguardianhat_1x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_alterguardianhat_1x1"。
        animbuild = "ui_alterguardianhat_1x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 160, 0)。
        pos = Vector3(0, 160, 0),
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 单标签白名单：spore。与第 1790 行的 alterguardianhat 用 HasAnyTag(spore, lunarseed) 不同。
--   ⇒ 同一个物品（spore）在两个容器里都能放，且判定规则不同。
function params.alterguardianhatshard.itemtestfn(container, item, slot)
    return item:HasTag("spore")
end

-- ── alterguardianhat 区块 ──
--------------------------------------------------------------------------
--[[ alterguardianhat ]]
--------------------------------------------------------------------------

-- 监护者帽子：5 格竖排，放孢子与月之种。type = "hand_inv"。
params.alterguardianhat =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- 格子底纹贴图数组（与 slotpos 严格一一对应）。★ 纯装饰，容器逻辑从不读。
        slotbg = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_alterguardianhat_1x6"。
        animbank = "ui_alterguardianhat_1x6",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_alterguardianhat_1x6"。
        animbuild = "ui_alterguardianhat_1x6",
		pos = Vector3(106, 10, 0),
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "hand_inv"
--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "hand_inv",
-- excludefromcrafting：同第 1339 行（首次定义），此处值 = true。
    excludefromcrafting = true,
}

-- ★★ 坐标常量提成局部变量：AGHAT_SLOTSTART = 72*5-22 = 338。
--   ★ 公式的来历：5 格 × 72 间距 = 360，再减 22 让整组略微上移居中。
--   这比第 1013 行那种「循环 + 行内算式」更易读：
--     常量把「为什么是这个数」显式化，而不是埋在算式里。
--   ⚠ 但注意这**不是** immutable：第 1816 行的 sp 用它计算，不修改它。
local AGHAT_SLOTSTART = 72 * 5 - 22
local AGHAT_SLOTDIFF = 72
-- 第三张 slotbg 常量（spore_slot.tex），5 格共用。
local SLOT_BG = { image = "spore_slot.tex", atlas = "images/hud2.xml" }
-- ★ 槽位生成循环（顶层）：i = 0 … 4 → **5 轮**。
--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 5 × 1 = **5 个槽**，即「监护者帽 5 竖排」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 5），存档按编号还原
for i = 0, 4 do
    local sp = Vector3(0, AGHAT_SLOTSTART - (i*AGHAT_SLOTDIFF), 0)
-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.alterguardianhat.widget.slotpos, sp)
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
    table.insert(params.alterguardianhat.widget.slotbg, SLOT_BG)
-- 循环结束：已插入 **5 个** slotpos 坐标，本容器的 numslots 定为 5。
end

-- ★ 把物品清单提为常量表 ALTERGUARDIANHAT_ITEMS，供 HasAnyTag 展开。
--   ⇒ 若要支持 lunarseed 的同时保留 spore 的语义，只需改这一张表。
local ALTERGUARDIANHAT_ITEMS = {"spore", "lunarseed"}
-- itemtestfn = HasAnyTag(常量表)。★ 最短最清晰的 itemtestfn 之一。
function params.alterguardianhat.itemtestfn(container, item, slot)
    return item:HasAnyTag(ALTERGUARDIANHAT_ITEMS)
end

-- ── pocketwatch（怀表）区块 ──
--------------------------------------------------------------------------
--[[ pocketwatch ]]
--------------------------------------------------------------------------

-- 怀表：3x2 = 6 格，放怀表零件。
--   ★ pos = Vector3(-850, 100, 0) —— x 偏移 **-850 像素**，
--     极负值 = UI 出现在屏幕**最左侧**（远离中央）。
--   推论：怀表打开时物品栏会被推到右边，是为特殊道具设计的极端布局。
params.pocketwatch =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_tacklecontainer_3x2"。
        animbank = "ui_tacklecontainer_3x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_tacklecontainer_3x2"。
        animbuild = "ui_tacklecontainer_3x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-850, 100, 0)。
        pos = Vector3(-850, 100, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- type = "hand_inv"
--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "hand_inv",
-- excludefromcrafting：同第 1339 行（首次定义），此处值 = true。
    excludefromcrafting = true,
}

-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「怀表 3x2=6 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原
for y = 1, 0, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.pocketwatch.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 120, 0))
    end
-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。
end

function params.pocketwatch.itemtestfn(container, item, slot)
	return item:HasTag("pocketwatchpart")
end

-- ── ocean_trawler（海洋拖网渔船）区块 ──
--------------------------------------------------------------------------
--[[ ocean_trawler ]]
--------------------------------------------------------------------------

-- 拖网渔船：4 竖格，acceptsstacks = false（每格一条鱼）。
params.ocean_trawler =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 100, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 20, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -60, 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -140, 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_cookpot_1x4"。
        animbank = "ui_cookpot_1x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_cookpot_1x4"。
        animbuild = "ui_cookpot_1x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【双标签白名单】cookable 或 oceanfish。
--   ★ 注意这里允许「可烹饪」但不带 burnt 守卫（对比第 374 行 cookpot 有）。
--     ⇒ 烧焦的船（burnt 标签）仍能放鱼 —— 小差异，通常无害。
function params.ocean_trawler.itemtestfn(container, item, slot)
    return item:HasAnyTag("cookable", "oceanfish")
end

-- ── bookstation（书站）区块 ──
--------------------------------------------------------------------------
--[[ bookstation ]]
--------------------------------------------------------------------------

-- 书站：4x5 = 20 格。★ 与第 1239 行的古代船并列，
--   是**全文件槽位最多的静态蓝图**（20 格）。
--   ⇒ 直接决定 containers.MAXITEMSLOTS = 20（第 2499 行），
--     进而决定 container_classified 要为每个容器分配多少条 net_entity 变量。
params.bookstation =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_bookstation_4x5"。
        animbank = "ui_bookstation_4x5",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_bookstation_4x5"。
        animbuild = "ui_bookstation_4x5",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 280, 0)。
        pos = Vector3(0, 280, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ 坐标公式 `-77 * y + 37 - (y * 2)`：行距 77 且**逐行再下移 2 像素**。
--   推理：行距不是常数偏移，而是带累积项 —— 因为行高 77 小于格高，两行之间会挤。
--   `- (y * 2)` 随 y 递增，等于每行比均匀分布再低 2 像素，补偿格子重叠。
--   ⇒ 这解释了为什么只有这 4 个槽用 -114/-163/-238/-313 四个不同 x 值：
--     4 列不等距（间距 75），因为右侧要避开翻页按钮。
for y = 0, 4 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.bookstation.widget.slotpos, Vector3(-114      , (-77 * y) + 37 - (y * 2), 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.bookstation.widget.slotpos, Vector3(-114 + 75 , (-77 * y) + 37 - (y * 2), 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 3 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.bookstation.widget.slotpos, Vector3(-114 + 150, (-77 * y) + 37 - (y * 2), 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 4 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.bookstation.widget.slotpos, Vector3(-114 + 225, (-77 * y) + 37 - (y * 2), 0))
-- 循环结束：已插入 **20 个** slotpos 坐标，本容器的 numslots 定为 20。
end

-- 单标签白名单：bookcabinet_item。
function params.bookstation.itemtestfn(container, item, slot)
    return item:HasTag("bookcabinet_item")
end

-- ── beargerfur_sack（熊皮袋）区块 ──
--------------------------------------------------------------------------
--[[ beargerfur_sack ]]
--------------------------------------------------------------------------

-- 熊皮袋：2x3 = 6 格，放熟食。美术复用 ui_icepack_2x3（与香料包同图）。
params.beargerfur_sack =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- slotbg：同第 1802 行（首次定义），此处值 = {}。
        slotbg  = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_icepack_2x3"。
        animbank  = "ui_icepack_2x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_icepack_2x3"。
        animbuild = "ui_icepack_2x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(75, 195, 0)。
        pos = Vector3(75, 195, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ for y = 0,2 / for x = 0,1 → 6 格，但注意 x 方向是**向右**递增（-163 + 75*x），
--   与其他容器的「从 -160 到 -85」写法相反。坐标原点在右下而非左上。
for y = 0, 2 do
    for x = 0, 1 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.beargerfur_sack.widget.slotpos, Vector3(-163 + (75 * x),   -75 * y + 73,   0))
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
        table.insert(params.beargerfur_sack.widget.slotbg, { image = "preparedfood_slot.tex", atlas = "images/hud2.xml" })
    end
-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。
end

-- 【itemtestfn 范例 V：标签 + 逃生口】
--   HasAnyTag("beargerfur_sack_valid", "preparedfood")。
--   ★ 与冰箱第 1020 行的 icebox_valid 同型：给模组留一个「指定合法物」的标签口。
--     官方自己用它装「冬oki 节的皮」，模组可用它塞任意自定义物品。
--   ⚠ 风险：任何模组给物品打上 beargerfur_sack_valid 就能塞进去 —— 这是**刻意的开放**。
function params.beargerfur_sack.itemtestfn(container, item, slot)
    -- Prepared food.
    return item:HasAnyTag("beargerfur_sack_valid", "preparedfood")
end

-- ── houndstooth_blowpipe（獠牙吹管）区块 ──
--------------------------------------------------------------------------
--[[ houndstooth_blowpipe ]]
--------------------------------------------------------------------------

-- deepcopy(params.slingshot) —— 吹管完全复用弹弓的 1 格手持布局，只换贴图与判定。
--   ★ 跨「道具语义」复用 UI 布局（弹弓→吹管），说明布局参数确实已高度抽象。
params.houndstooth_blowpipe = deepcopy(params.slingshot)

-- 整体替换 slotbg 为吹管专用贴图（1 格）。
params.houndstooth_blowpipe.widget.slotbg = {{ image = "houndstooth_ammo_slot.tex", atlas = "images/hud2.xml" }}

-- 单标签白名单：blowpipeammo。★ 与弹弓的 slingshotammo 同型，只是标签不同。
function params.houndstooth_blowpipe.itemtestfn(container, item, slot)
	return item:HasTag("blowpipeammo")
end

-- ── battlesong_container（战歌容器）区块 ──
--------------------------------------------------------------------------
--[[ battlesong_container ]]
--------------------------------------------------------------------------

-- 战歌容器：2x4 = 8 格，放战歌。与背包同布局同美术。
params.battlesong_container =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- slotbg：同第 1802 行（首次定义），此处值 = {}。
        slotbg  = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_backpack_2x4"。
        animbank  = "ui_backpack_2x4",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_backpack_2x4"。
        animbuild = "ui_backpack_2x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(75, 195, 0)。
        pos = Vector3(75, 195, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- ★ 第四处 slotbg 常量。累计本文件已有 4~5 处 slotbg 游标（第 190/228/278/745/1814 行），
--   全是「声明 local → 用 → 置 nil」的相同模式。
local battlesong_container_bg = { image = "battlesong_slot.tex", atlas = "images/hud2.xml" }

-- ★ 槽位生成循环（顶层）：y = 0 … 3 → **4 轮**。
--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 4 × 2 = **8 个槽**，即「战歌容器 8 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 8），存档按编号还原
for y = 0, 3 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.battlesong_container.widget.slotpos, Vector3(-162     , -75 * y + 114, 0))
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.battlesong_container.widget.slotpos, Vector3(-162 + 75, -75 * y + 114, 0))

-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
    table.insert(params.battlesong_container.widget.slotbg, battlesong_container_bg)
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
    table.insert(params.battlesong_container.widget.slotbg, battlesong_container_bg)
-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。
end

-- 单标签白名单：battlesong。
function params.battlesong_container.itemtestfn(container, item, slot)
    -- Battlesongs.
    return item:HasTag("battlesong")
end

-- priorityfn = itemtestfn（第 1632 行模式的第五次复用）。此处不依赖 slot，安全。
params.battlesong_container.priorityfn = params.battlesong_container.itemtestfn

-- ── wortox_souljar（沃尔托克斯魂罐）区块 ──
--------------------------------------------------------------------------
--[[ wortox_souljar ]]
--------------------------------------------------------------------------

-- 魂罐：1 格，放灵魂。
params.wortox_souljar =
{
-- ★ 魂罐的 slotpos 是 `{ Vector3(0, 0, 0) }` —— 单元格式，与第 1267 行沙尘蜂帽同型。
--   ★ 单槽容器的标准写法：slotpos 数组长度 1 → 第 15 行得出 numslots = 1。
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {。
        slotpos = {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-2, 18, 0),
        },
-- slotbg：同第 1802 行（首次定义），此处值 = {。
        slotbg  = {
            {image = "soul_slot.tex", atlas = "images/hud2.xml"},
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_wortox_souljar_1x1"。
        animbank  = "ui_wortox_souljar_1x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_wortox_souljar_1x1"。
        animbuild = "ui_wortox_souljar_1x1",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 195, 0)。
        pos = Vector3(0, 195, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
-- ★ 自定义开合音效：开盖是「pop」，关盖是「close_pop」——
--   两个不同音效而非同一音效的正放/倒放，体现了音效系统的灵活性。
        opensound = "meta5/wortox/souljar_lid_pop",
-- closesound：同第 929 行（首次定义），此处值 = "meta5/wortox/souljar_close_pop"。
        closesound = "meta5/wortox/souljar_close_pop",
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 【itemtestfn 范例 W：标签 + 标签排除】HasTag("soul") and not HasTag("nosouljar")。
--   ★ 「排除标签」模式：给特殊灵魂打上 nosouljar 就能把它挡在罐外，
--     而无需为每种「不该放的灵魂」写一条规则。
function params.wortox_souljar.itemtestfn(container, item, slot)
    return item:HasTag("soul") and not item:HasTag("nosouljar")
end

-- ── wendy_elixir_container（温蒂灵药容器）区块 ──
--------------------------------------------------------------------------
--[[ wendy_elixir_container ]]
--------------------------------------------------------------------------

-- 灵药容器：3x3 = 9 格。
params.elixir_container =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- slotbg：同第 1802 行（首次定义），此处值 = {}。
        slotbg  = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_elixir_container_3x3"。
        animbank  = "ui_elixir_container_3x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_elixir_container_3x3"。
        animbuild = "ui_elixir_container_3x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 第五处 slotbg 游标（elixir_slot.tex）。
local elixir_container_bg = { image = "elixir_slot.tex", atlas = "images/hud2.xml" }

-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「温蒂灵药容器 3x3=9 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原
for y = 2, 0, -1 do
    for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.elixir_container.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 80, 0))
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
        table.insert(params.elixir_container.widget.slotbg, elixir_container_bg)
    end
-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。
end

-- 双标签白名单：ghostlyelixir / ghostflower。
function params.elixir_container.itemtestfn(container, item, slot)
	return item:HasAnyTag("ghostlyelixir", "ghostflower")
end

-- priorityfn = itemtestfn（第 1632 行模式）。不依赖 slot，安全。
params.elixir_container.priorityfn = params.elixir_container.itemtestfn

-- ── dragonflyfurnace（蜻蜓焚化炉）区块 ──
--------------------------------------------------------------------------
--[[ dragonflyfurnace ]]
--------------------------------------------------------------------------

-- 焚化炉：2x2 = 4 格，INCINERATE 按钮。
params.dragonflyfurnace =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5,   32 + 4,  0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3( 37.5,   32 + 4,  0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(-37.5, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3( 37.5, -(32 + 4), 0),
        },
        slotbg =
        {
            { image = "inv_slot_dragonflyfurnace.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_dragonflyfurnace.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_dragonflyfurnace.tex", atlas = "images/hud2.xml" },
            { image = "inv_slot_dragonflyfurnace.tex", atlas = "images/hud2.xml" },
        },
-- animbank：同第 28 行（首次定义），此处值 = "ui_dragonflyfurnace_2x2"。
        animbank = "ui_dragonflyfurnace_2x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_dragonflyfurnace_2x2"。
        animbuild = "ui_dragonflyfurnace_2x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 120。
        side_align_tip = 120,
        buttoninfo =
        {
            text = STRINGS.ACTIONS.INCINERATE,
            position = Vector3(0, -100, 0),
        }
    },
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【itemtestfn 范例 X：与第 121 行传送门完全相同的黑名单】
--   `not item:HasTag("irreplaceable")`。
--   ⇒ 「焚化炉能烧任何不可替代物之外的东西」—— 与传送门「能装任何不可替代物之外的东西」
--     是**同一个规则**。两者语义不同却共用判定，说明这个规则被复用得很广。
function params.dragonflyfurnace.itemtestfn(container, item, slot)
    return not item:HasTag("irreplaceable")
end

-- 第 330 行双端模板的第 N 次复制（ACTIONS.INCINERATE）。
function params.dragonflyfurnace.widget.buttoninfo.fn(inst, doer)
    if inst.components.container ~= nil then
        BufferedAction(doer, inst, ACTIONS.INCINERATE):Do()
    elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
        SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.INCINERATE.code, inst, ACTIONS.INCINERATE.mod_name)
    end
end

-- 焚化炉 validfn：只需非空（不要求满）。
--   ⇒ 有一个物品就能点，与 cookpot/sewingmachine 的 IsFull 形成对比。
function params.dragonflyfurnace.widget.buttoninfo.validfn(inst)
    return inst.replica.container ~= nil and not inst.replica.container:IsEmpty()
end

-- ── slingshotammo_container（弹弓弹药箱）区块 ──
--------------------------------------------------------------------------
--[[ slingshotammo_container ]]
--------------------------------------------------------------------------

-- 弹药箱：3x2 = 6 格。★ slotpos 循环变量 y 从 1 到 0（2 行）。
params.slingshotammo_container =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- slotbg：同第 1802 行（首次定义），此处值 = {}。
        slotbg  = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_slingshotammo_container_3x2"。
        animbank  = "ui_slingshotammo_container_3x2",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_slingshotammo_container_3x2"。
        animbuild = "ui_slingshotammo_container_3x2",
-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。
        pos = Vector3(0, 200, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 第六处 slotbg 游标（slingshot_ammo_slot.tex）。
--   ★ 与第 1473 行弹弓槽的贴图**同名**，说明弹药相关道具共用一张格子底图。
local slingshotammo_container_bg = { image = "slingshot_ammo_slot.tex" }

-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「弹弓弹药箱 3x2=6 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原
for y = 1, 0, -1 do
    for x = 0, 2 do
-- ★ 坐标 `90 * x - 90`（x=0,1,2 → -90/0/90）与 `80 * y - 42.5`（y=1,0 → 37.5/-42.5）。
--   这里 x 从 0 开始且偏移 -90，而多数容器是 -80*2+80。
--   ⇒ 说明坐标原点并不统一，**每个容器都要独立看它的 slotpos 循环**。
        table.insert(params.slingshotammo_container.widget.slotpos, Vector3(90 * x - 90, 80 * y - 42.5, 0))
-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。
--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。
        table.insert(params.slingshotammo_container.widget.slotbg, slingshotammo_container_bg)
    end
-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。
end

-- 单标签白名单：slingshotammo。与第 1532 行弹弓的判定一致。
function params.slingshotammo_container.itemtestfn(container, item, slot)
    return item:HasTag("slingshotammo")
end

-- priorityfn = itemtestfn（第 1632 行模式）。不依赖 slot，安全。
params.slingshotammo_container.priorityfn = params.slingshotammo_container.itemtestfn

-- ── wx78_backupbody（WX-78 备用躯体）区块 ──
--------------------------------------------------------------------------
--[[ wx78_backupbody ]]
--------------------------------------------------------------------------

-- ★ 把坐标提成命名常量 WX78_BACKUPBODY_POS，第 2143 行 pos = 该常量。
--   ★ 原因：第 2258 行 wx78_inventorycontainer 在「进入备用躯体」时
--     **要把自己摆到与备用躯体相同的位置**，必须引用同一个常量。
--     这是「跨容器共享布局常量」的必要条件，也是第 2205 行另一个常量的由来。
local WX78_BACKUPBODY_POS = Vector3(0, 280, 0)

-- 备用躯体：5x3 = 15 格，15 = constants.lua:650 MAXITEMSLOTS（物品栏槽数）。
params.wx78_backupbody = {
-- ★ widget 子表：本容器全部 UI 配置的容器（槽位/贴图/音效/按钮/位置）。
--   ★ 纯表现层——components/container.lua 一个字段都不读，只有 widgets 层消费。
--   参见 widgets/containerwidget.lua（仓库外）；本文件只负责「声明值」。
    widget = {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_wx78_backupbody_5x3"。
        animbank = "ui_wx78_backupbody_5x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_wx78_backupbody_5x3"。
        animbuild = "ui_wx78_backupbody_5x3",
		pos = WX78_BACKUPBODY_POS,
-- side_align_tip：同第 80 行（首次定义），此处值 = 160。
        side_align_tip = 160,
-- 自定义开合音效（WX_rework 前缀 = 韦斯特 DLC 资源包）。
        opensound = "WX_rework/module_side/open",
-- closesound：同第 929 行（首次定义），此处值 = "WX_rework/module_side/close"。
        closesound = "WX_rework/module_side/close",
    },
-- type = "chest"
--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "chest",
}

-- 【itemtestfn 范例 Y：又一处 irreplaceable 黑名单】
--   与第 121 行传送门、第 2083 行焚化炉**逐字相同**。
--   ⇒ 三个语义完全不同的容器共用同一条规则，进一步说明该规则是「通用道具安全网」。
function params.wx78_backupbody.itemtestfn(container, item, slot)
    return not item:HasTag("irreplaceable")
end

-- 5 列 × 3 行。★ 注意 `for x = 0, 4, 1` 显式写了步长 1（Lua 默认步长就是 1，冗余）。
--   坐标 `80 * x - 80 * 2` → x∈[0,4] 映射到 [-160..160]，y 偏移 -42.5。
for y = 2, 0, -1 do
    for x = 0, 4, 1 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
        table.insert(params.wx78_backupbody.widget.slotpos, Vector3(80 * x - 80 * 2, 80 * y - 80 * 2 - 42.5, 0))
    end
-- 循环结束：已插入 **15 个** slotpos 坐标，本容器的 numslots 定为 15。
end

-- ── wx78_drone_delivery（WX-78 送货无人机）区块 ──
--------------------------------------------------------------------------
--[[ wx78_drone_delivery ]]
--------------------------------------------------------------------------

-- 送货无人机：3x2 = 6 格。★ 没有 itemtestfn —— 万能容器。
params.wx78_drone_delivery =
{
	widget =
	{
		slotpos = {},
		animbank = "ui_wx_deliverydrone_3x2",
		animbuild = "ui_wx_deliverydrone_3x2",
		pos = Vector3(0, 200, 0),
		side_align_tip = 160,
	},
	type = "chest",
}

-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。
--   内层循环：x = 0 … 2 → **3 列**。
--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「WX-78 送货无人机 3x2=6 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原
for y = 1, 0, -1 do
	for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
		table.insert(params.wx78_drone_delivery.widget.slotpos, Vector3(80 * x - 80 * 2 + 80, 80 * y - 80 * 2 + 120, 0))
	end
-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。
end

-- 小型无人机：3x1 = 3 格（单排）。★ 同样没有 itemtestfn。
params.wx78_drone_delivery_small =
{
	widget =
	{
		slotpos = {},
		animbank = "ui_wx_deliverydrone_3x1",
		animbuild = "ui_wx_deliverydrone_3x1",
		pos = Vector3(0, 200, 0),
		side_align_tip = 160,
	},
	type = "chest",
}

-- ★ 槽位生成循环（顶层）：x = 0 … 2 → **3 轮**。
--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。
--   ⇒ 槽位总数 = 3 × 1 = **3 个槽**，即「WX-78 小型无人机 3x1=3 格」的 numslots。
--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，
--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。
--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 3），存档按编号还原
for x = 0, 2 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
	table.insert(params.wx78_drone_delivery_small.widget.slotpos, Vector3(75 * x - 75 * 2 + 75, 0, 0))
-- 循环结束：已插入 **3 个** slotpos 坐标，本容器的 numslots 定为 3。
end

-- ── wx78_inventorycontainer（WX-78 物品柜容器）区块 ──
--------------------------------------------------------------------------
--[[ wx78_inventorycontainer ]]
--------------------------------------------------------------------------

-- ★ 第二个共享布局常量：WX78_INVENTORY_CONTAINER_OFFSET = Vector3(0, 100, 0)。
--   第 2264 行 posfn 用它把柜子挂到它所在**物品栏格子的位置 + 这个偏移**。
--   ⇒ ★ 这是「UI 跟随物品栏实时定位」的常量 —— 玩家移动柜子，UI 立刻跟随。
local WX78_INVENTORY_CONTAINER_OFFSET = Vector3(0, 100, 0)

-- ★★ 五列位置表：WX78_INVENTORY_CONTAINER_SLOTPOS，5 个坐标。
--   它们按「这个柜子当前在备用躯体的第几列」被索引（第 2235-2239 行 slotposfn）。
--   ⇒ 这是全文件**唯一的动态布局**容器：槽位坐标由运行时状态决定，而非写死。
local WX78_INVENTORY_CONTAINER_SLOTPOS = {}
-- 底纹批量填充循环：x = 0 … 4 → **5 次**。
--   ★ 只往 slotbg 塞贴图、**不产生槽位**——槽位由 slotpos 决定。
--   ⇒ 它的次数必须与「WX-78 小型无人机 3x1=3 格」的 slotpos 数量严格相等，否则底纹会错位。
for x = 0, 4, 1 do
	table.insert(WX78_INVENTORY_CONTAINER_SLOTPOS, { Vector3(80 * x - 80 * 2, -340, 0) })
-- 循环结束：已插入 **0 个** slotpos 坐标，本容器的 numslots 定为 0。
end

-- 【★ wx78_inventorycontainer_isinbackupbody：双端兼容的归属判定】
--   `container.replica.inventoryitem:IsHeldBy(doer)` —— 注意用的是 **replica**，
--     这就是它能同时在两端工作的原因（replica 表两端都存在，见 entityscript.lua:244）。
--   取反得到「柜子不在任何玩家手上」=「柜子在备用躯体里」。
--   ★ 这解释了为什么第 1053 行 saltbox 用 replica 不会崩：replica 在两端都有。
local function wx78_inventorycontainer_isinbackupbody(container, doer)
	local inventoryitem = container.replica.inventoryitem
	return not (inventoryitem and inventoryitem:IsHeldBy(doer))
end

-- 【★ wx78_inventorycontainer_getcolumn：从父容器反查自己的列号】
--   parent = container.entity:GetParent() —— 柜子的物理父实体是备用躯体；
--   遍历备用躯体的 container items，找出「哪个槽里装的是我」，
--   再用 ((slot-1) % 5) + 1 折算出列号 1..5。
--   ★ mod 5 是因为备用躯体有 15 槽 = 3 行 × 5 列，列号需要从行号里剥出来。
--   ⇒ 设计巧思：**UI 布局与数据布局解耦**，靠一个取模公式桥接。
local function wx78_inventorycontainer_getcolumn(container)
	local parent = container.entity:GetParent()
	local _container = parent and parent.replica.container
	if _container then
		for slot, v in pairs(_container:GetItems()) do
			if v == container then
				return ((slot - 1) % 5) + 1
			end
		end
-- ⚠ 默认返回 5（最后一列）：找不到自己时兜底到最右列。
--   推理依据：加载中/父容器还没同步完时 GetItems() 可能为空，
--     必须给一个合法值否则 slotposfn 返回 nil → UI 无格子。
--   选 5 而不是 1 是因为「放最右」在视觉上更不突兀。**不改代码**。
	end
	return 5
end

-- 【★★ 动态布局容器本体】读它的 widget 需要理解 5 个 *fn 字段的组合。
--   slotpos / slotposfn / slotscalefn / slothighlightscalefn / animfn / posfn
--   ⇒ 规律：**静态字段是默认值，*fn 字段按需覆盖；fn 返回 nil 表示「用默认值」**。
--   这是全文件唯一大量使用 *fn 的容器，也是唯一没有「确定槽位数」的容器。
params.wx78_inventorycontainer =
{
    widget =
    {
-- 默认槽位：固定在 (0,0)。★ 只有 1 个坐标 → 第 15 行数出 numslots = 1。
		slotpos = { Vector3(0, 0, 0) },
-- 【★ slotposfn：动态槽位坐标】
--   在备用躯体里 → 返回对应列的坐标；否则 → 返回 nil（用默认的 (0,0)）。
--   ★ 注意它返回的是 **WX78_..._SLOTPOS 数组的一个元素**（一个 Vector3），
--     不是函数结果集 —— widget 层把它当作 slotpos[i] 使用。
		slotposfn = function(container, doer)
			return wx78_inventorycontainer_isinbackupbody(container, doer)
				and WX78_INVENTORY_CONTAINER_SLOTPOS[wx78_inventorycontainer_getcolumn(container)]
				or nil
		end,
-- ★ 原注释保留：「--numslots = 1, --required if we don't have slotpos table」。
--   这条注释说明了「slotpos 与 numslots 的关系」：
--     · 有 slotpos → 第 15 行自动数出槽位数；
--     · 没 slotpos → 必须显式给 numslots，否则 slots 是空表。
--   本容器两者都有（slotpos 1 个 + 不写 numslots），恰好都满足。
		--numslots = 1, --required if we don't have slotpos table
-- 【slotscalefn】在备用躯体里缩到 0.85 倍（柜子变小以塞进躯体框内），否则 nil（默认 1.0）。
		slotscalefn = function(container, doer)
			return wx78_inventorycontainer_isinbackupbody(container, doer) and 0.85 or nil
		end,
-- 【slothighlightscalefn】高亮放大 1.08 倍（与 0.85 缩放配套，放大比例也相应减小）。
		slothighlightscalefn = function(container, doer)
			return wx78_inventorycontainer_isinbackupbody(container, doer) and 1.08 or nil
		end,
-- animbank：同第 28 行（首次定义），此处值 = "ui_wx78_inventorycontainer_1x1"。
        animbank = "ui_wx78_inventorycontainer_1x1",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_wx78_inventorycontainer_1x1"。
        animbuild = "ui_wx78_inventorycontainer_1x1",
-- 【★ animfn：动态美术名】`anim .. tostring(列号)` ——
--   ★ 把美术名按列号动态拼接：ui_wx78_inventorycontainer_1x1 → ..._3x1。
--   ⇒ 意思是「第几列就用第几列的那张 UI 图」，美术资源命名必须严格遵循此约定。
--   ⚠ 这是最脆弱的一处：美术改了命名规则，这里会静默找不到图（显示空白）。
		animfn = function(container, doer, anim)
			return wx78_inventorycontainer_isinbackupbody(container, doer)
				and (anim..tostring(wx78_inventorycontainer_getcolumn(container)))
				or nil
		end,
		--
		pos = WX78_INVENTORY_CONTAINER_OFFSET,
-- 【★ posfn：最复杂的一段】三条分支决定柜子 UI 摆在哪：
--   ① 在备用躯体里 → 固定用 WX78_BACKUPBODY_POS（因为躯体 UI 是固定位置的）；
--   ② 否则 → 遍历玩家的 HUD 物品栏，找到「哪个格子装的是我」，
--      返回该格子的位置 + 偏移；
--   ③ 两者都不是 → 隐式返回 nil。
--   ⇒ 这解释了第 2205 行常量偏移的用途：把柜子 UI 相对物品栏格微微下移，避免重叠。
		posfn = function(container, doer)
			if wx78_inventorycontainer_isinbackupbody(container, doer) then
				return WX78_BACKUPBODY_POS
			end

-- ★ 原注释保留：「-- TODO is this the best way of doing this?」
--   ★ 作者自己标注了这套「翻 HUD 控件树找自己」的做法是临时方案。
--     推理：doer.HUD.controls.inv.inv 是 UI 控件树，直接遍历它找 tile.item，
--     属于**从渲染层反查数据**（本该反过来）。作者知道这不优雅但暂时没有更好的 API。
--     ⇒ 这是本文件里少见的「作者自认技术债」标注，很有参考价值。
			-- TODO is this the best way of doing this?
			for k, v in pairs(doer.HUD.controls.inv.inv) do
				if v.tile and v.tile.item == container then
					return v:GetPosition() + WX78_INVENTORY_CONTAINER_OFFSET
				end
			end
		end,
-- ★ 注释再次提到音效归属：「Override the widget sound, which is heard only by the client」
--   与第 508 行的 V2C 注释呼应 —— 这类音效只在客户端播放，**服务端无声**。
--   推测：可能是从别的服务器主题（balatro/ = 梭哈主题音乐包）临时借用的音效。
		--Override the widget sound, which is heard only by the client
		opensound = "balatro/balatro_cabinet/cards_flip_HUD",
		closesound = "balatro/balatro_cabinet/cards_flip_HUD",
		--
-- 【bottom_align_tip_fn / top_align_tip_fn：提示条对齐的动态版本】
--   在躯体里 → 底部对齐 -90；否则 → 顶部对齐 70。
		bottom_align_tip_fn = function(container, doer)
			return wx78_inventorycontainer_isinbackupbody(container, doer) and -90 or nil
		end,
		top_align_tip_fn = function(container, doer)
			return not wx78_inventorycontainer_isinbackupbody(container, doer) and 70 or nil
		end,
-- ★ 原注释保留：「top_align_tip = 70, --backward compatibility, fn versions would have higher priority now」。
--   ★★ 这是**向后兼容的教科书案例**：
--     · 老版本只有静态 top_align_tip；
--     · 新版本加了 top_align_tip_fn；
--     · 为了让老 prefab（可能只写静态字段）仍能工作，静态字段保留；
--     · 而 widget 层约定「fn 版本优先级更高」。
--   ⇒ 配置系统的版本兼容三板斧：**加新字段 → 保留旧字段 → 声明优先级**。
--     全库新增配置项都应参照这个模式。
		top_align_tip = 70, --backward compatibility, fn versions would have higher priority now
    },
-- ★ 默认 type = "inv" —— UI 挂在物品栏顶行（playerhud.lua:394 `("inv" and self.controls.inv.toprow_inv)`）。
	type = "inv",
-- 【★★ typefn：动态类型】默认 "inv"，在备用躯体里 → "chest_addon"。
--   ★ 这是全文件唯一使用 typefn 的容器。
--   消费点：screens/playerhud.lua:392 ——
--     `local _type = _container and (_container.typefn and _container.typefn(container, self.owner) or _container.type)`
--   ⇒ UI 层先问「你有没有 typefn？有就调它，没有用静态 type」。
--     效果：同一个柜子在物品栏里占顶行，放进躯体里就变成躯体顶部的装饰区。
	typefn = function(container, doer)
		return wx78_inventorycontainer_isinbackupbody(container, doer) and "chest_addon" or nil
	end,
    -- excludefromcrafting = true,
}
-- ⚠ 注意第 2284 行被注释掉的 `excludefromcrafting = true`：
--   柜子里的东西**参与合成搜索**（与第 1279 行沙尘蜂帽相反的取舍）。
--   被注释而非写成 false，说明「暂时不排除」的意图留在了代码里。

-- 【★ priorityfn：唯一用 stackable 能力的 priorityfn】
--   逻辑：若当前槽里已有物品且它能与新物品**叠加**，就优先放这个柜子。
--   ⇒ 效果：玩家拿 20 个燧石，会优先塞进「已经装了燧石的柜子」而不是「空柜子」
--     —— 即**按物品类型聚合**，减少碎片化占格。这是很典型的 UX 优化。
function params.wx78_inventorycontainer.priorityfn(container, item)
-- 先看第 1 格（numslots = 1，唯一的槽）里有什么。
	local existingitem = container:GetItemInSlot(1)
	local stackable = existingitem and existingitem.replica.stackable
-- stackable ~= nil and CanStackWith(item) —— ★ 「已有物品与新物品同类型且非空」。
--   注意用的是 `existingitem.replica.stackable`（replica）而非 components —— 
--     因为 priorityfn 会在**客户端 UI 侧**被提前调用（为了决定高亮哪个容器）。
--   ⇒ ★ 这解释了全文件为什么允许 replica 访问：某些判定确实需要双端通用。
	return stackable ~= nil and stackable:CanStackWith(item)
end

-- ── socket_keystone_construction_container（基岩插槽容器）区块 ──
--------------------------------------------------------------------------
--[[ socket_keystone_construction_container ]]
--------------------------------------------------------------------------

-- 第七次（也是最后一次）deepcopy(construction_container) —— 派生建造容器的标准套路。
params.socket_keystone_construction_container = deepcopy(params.construction_container)

-- 槽位缩到 1 个。★ 与第 555 行的裂隙容器完全同构，连 side_align_tip 都一样（120）。
params.socket_keystone_construction_container.widget.slotpos = {Vector3(0, 8, 0)}
-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.socket_keystone_construction_container.widget.side_align_tip = 120
-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.socket_keystone_construction_container.widget.animbank = "ui_construction_1x1"
-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。
--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。
params.socket_keystone_construction_container.widget.animbuild = "ui_construction_1x1"
-- 按钮文案换成 OFFER（献出基岩）。
params.socket_keystone_construction_container.widget.buttoninfo.text = STRINGS.ACTIONS.APPLYCONSTRUCTION.OFFER

-- 【DoKeyStoneAct】与第 607 行 EnableRiftsDoAct **逐字同构**，只有名字不同。
--   ⚠ 重复代码：本文件有 4 份几乎相同的双端执行模板（第 330/377/434/478/531/607/1191/2087/2305 行）。
--     它们没有抽成公共函数，原因大概是每个都绑定不同的 ACTIONS，
--     抽了反而要传更多参数。这是「小重复优于抽象过度」的合理取舍。
local function DoKeyStoneAct(inst, doer)
	if inst.components.container ~= nil then
		BufferedAction(doer, inst, ACTIONS.APPLYCONSTRUCTION):Do()
	elseif inst.replica.container ~= nil and not inst.replica.container:IsBusy() then
		SendRPCToServer(RPC.DoWidgetButtonAction, ACTIONS.APPLYCONSTRUCTION.code, inst, ACTIONS.APPLYCONSTRUCTION.mod_name)
	end
end

-- 取消回调：与第 603 行 EnableRiftsPopUpGoBack 同构（只 PopScreen）。
local function GiveKeyStoneGoBack()
	TheFrontEnd:PopScreen()
end

function params.socket_keystone_construction_container.widget.buttoninfo.fn(inst, doer)
	if not params.socket_keystone_construction_container.widget.overrideactionfn(inst, doer) then
		-- No UI no dialogue.
		DoKeyStoneAct(inst, doer)
	end
end

-- overrideactionfn：与第 622 行裂隙版**逐字同构**（同样弹 RiftConfirmScreen）。
--   ⇒ 两套「献祭类」容器共享同一套交互模式，只是文案与动作不同。
function params.socket_keystone_construction_container.widget.overrideactionfn(inst, doer)
	if doer ~= nil and doer.HUD ~= nil and IsConstructionSiteComplete(inst, doer) then
		-- We have UI do dialogue.
		local function GiveKeyStonePopUp()
			DoKeyStoneAct(inst, doer)
			TheFrontEnd:PopScreen()
		end

		local str = inst.POPUP_STRINGS
		local confirmation = RiftConfirmScreen(str.TITLE, str.BODY,
		{
			{ text = str.OK,     cb = GiveKeyStonePopUp },
-- ⚠ 缩进不齐：这一行比上下两行多缩进（`            { text = ...`）。
--   推理依据：纯格式问题，Lua 对空白不敏感，执行无差异。
--     仅标注为「疑似缺陷（格式）」，不改代码。
            { text = str.CANCEL, cb = GiveKeyStoneGoBack  },
		})

		TheFrontEnd:PushScreen(confirmation)
		return true
	end
	return false
end

-- ── quagmire_pot（脓goo锅）区块 ──
--------------------------------------------------------------------------
--[[ quagmire_pot ]]
--------------------------------------------------------------------------

-- 脓液锅：4 竖格。与普通 cookpot 同型但美术换成 quagmire 前缀（未开化 DLC）。
params.quagmire_pot =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 64 + 32 + 8 + 4, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 32 + 4, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(32 + 4), 0),
-- 内联槽位坐标（本容器第 4 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(64 + 32 + 8 + 4), 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "quagmire_ui_pot_1x4"。
        animbank = "quagmire_ui_pot_1x4",
-- animbuild：同第 55 行（首次定义），此处值 = "quagmire_ui_pot_1x4"。
        animbuild = "quagmire_ui_pot_1x4",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks = false：每格一份材料。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【★ itemtestfn 范例 AA：全文件最复杂的 itemtestfn —— 四重与，每重都有讲究】
--   逐项拆解：
--   ① HasTag("quagmire_stewable") —— 白名单：可炖的东西；
--   ② prefab ~= "quagmire_sap" —— ★ 排除树液本身（原料不能直接下锅）；
--   ③ item.components.inventoryitem ~= nil and not IsHeld() —— 
--      「不是正被别人拿在手上」；
--   ④ not (spoiled_food or preparedfood or overcooked or takeonly) —— 
--      排除一切「已加工态」与「只出不进」的容器状态。
--   ⇒ 综合语义：只接受**未加工的生鲜**，且容器不是 takeonly（一次性容器）。
--   ★ 值得注意的是第 ③ 条用的是 **components**（服务端）而非 replica，
--     与第 2260 行 priorityfn 用 replica 形成对照 —— 
--     同一个文件里两种风格并存，判断依据是「这段代码在哪一端跑」。
function params.quagmire_pot.itemtestfn(container, item, slot)
    return item:HasTag("quagmire_stewable")
        and item.prefab ~= "quagmire_sap"
-- ★ 第 ③ 重条件的写法：`A ~= nil and not A:IsHeld()`。
--   这是「先确保组件存在再调方法」的标准防 nil 模式。
--   ⚠ 注意这里用 components 而第 2260 行用 replica，两处风格不一致（见上文说明）。
        and ((item.components.inventoryitem ~= nil and not item.components.inventoryitem:IsHeld()) or
            not (item.prefab == "spoiled_food" or item:HasTag("preparedfood") or item:HasTag("overcooked") or container.inst:HasTag("takeonly")))
end

-- ── quagmire_pot_small 区块 ──
--------------------------------------------------------------------------
--[[ quagmire_pot_small ]]
--------------------------------------------------------------------------

-- 小锅：3 格（比 4 格版少一格）。
params.quagmire_pot_small =
{
    widget =
    {
        slotpos =
        {
-- ★ 坐标 64 + 8 = 72 间距（而 4 格版是 64+32+8+4=108 与 36）。
--   小锅用更紧凑的 72 间距，因为格子少、UI 更小。
            Vector3(0, 64 + 8, 0),
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 0, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(64 + 8), 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "quagmire_ui_pot_1x3"。
        animbank = "quagmire_ui_pot_1x3",
-- animbuild：同第 55 行（首次定义），此处值 = "quagmire_ui_pot_1x3"。
        animbuild = "quagmire_ui_pot_1x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- itemtestfn 直接共享（第 904 行模式）。不依赖 slot，安全。
params.quagmire_pot_small.itemtestfn = params.quagmire_pot.itemtestfn

-- ── quagmire_casseroledish（平底锅）区块 ──
--------------------------------------------------------------------------
--[[ quagmire_casseroledish ]]
--------------------------------------------------------------------------

-- ⚠ 疑似缺陷：`params.quagmire_casseroledish = params.quagmire_pot`（引用赋值）。
--   第 2411/2417/2423 行同样是（quagmire_casseroledish_small / quagmire_grill /
--     quagmire_grill_small = params.quagmire_pot_small）。
--   推理依据：同一区块内连续 4 处共享，且这个区块**确实需要覆盖 itemtestfn 的能力**
--     （平底锅与深锅的规则可能不同）—— 若有人改 params.quagmire_pot.itemtestfn = fn，
--     三个平底锅/烤架会**同时被改**。这是本文件共享别名风险的典型后果。
--     ★ 对照第 950 行 merm_armory 用 deepcopy，说明作者在同一文件里也不统一。
--     **不改代码，仅标注**。
params.quagmire_casseroledish = params.quagmire_pot

-- ── quagmire_casseroledish_small 区块 ──
--------------------------------------------------------------------------
--[[ quagmire_casseroledish_small ]]
--------------------------------------------------------------------------

-- 【蓝图：quagmire_casseroledish_small】未开化小平底锅
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.quagmire_casseroledish_small = params.quagmire_pot_small

-- ── quagmire_grill 区块 ──
--------------------------------------------------------------------------
--[[ quagmire_grill ]]
--------------------------------------------------------------------------

-- 【蓝图：quagmire_grill】未开化烤架
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.quagmire_grill = params.quagmire_pot

-- ── quagmire_grill_small 区块 ──
--------------------------------------------------------------------------
--[[ quagmire_grill_small ]]
--------------------------------------------------------------------------

-- 【蓝图：quagmire_grill_small】未开化小烤架
--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。
--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。
--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。
--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。
params.quagmire_grill_small = params.quagmire_pot_small

-- ── quagmire_pot_syrup（糖浆锅）区块 ──
--------------------------------------------------------------------------
--[[ quagmire_pot_syrup ]]
--------------------------------------------------------------------------

-- 糖浆锅：3 格。与小锅同布局但**有独立 itemtestfn**。
params.quagmire_pot_syrup =
{
    widget =
    {
        slotpos =
        {
-- 内联槽位坐标（本容器第 1 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 64 + 8, 0),
-- 内联槽位坐标（本容器第 2 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, 0, 0),
-- 内联槽位坐标（本容器第 3 个 slot）。
--   ★ 数组内先后顺序 = 槽位编号顺序。
            Vector3(0, -(64 + 8), 0),
        },
-- animbank：同第 28 行（首次定义），此处值 = "quagmire_ui_pot_1x3"。
        animbank = "quagmire_ui_pot_1x3",
-- animbuild：同第 55 行（首次定义），此处值 = "quagmire_ui_pot_1x3"。
        animbuild = "quagmire_ui_pot_1x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。
        pos = Vector3(200, 0, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- acceptsstacks：同第 369 行（首次定义），此处值 = false。
    acceptsstacks = false,
-- type = "cooker"
--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "cooker",
}

-- 【★ itemtestfn 范例 AB：与 quagmire_pot 的关键差异】
--   对照第 2369 行，本函数：
--     · 不再排除 quagmire_sap —— ★ **树液正是糖浆锅的原料**；
--     · 反而加了 `item.prefab == "quagmire_sap" and not takeonly`，
--       即「树液可以进，但 takeonly 状态的锅不行」。
--   ⇒ 这是「同一 UI 形态、不同语义」的典型：两个锅长得一样，规则互为反面。
function params.quagmire_pot_syrup.itemtestfn(container, item, slot)
    return item:HasTag("quagmire_stewable")
        and ((item.components.inventoryitem ~= nil and not item.components.inventoryitem:IsHeld()) or
            (item.prefab == "quagmire_sap" and not container.inst:HasTag("takeonly")))
end

-- ── quagmire_backpack_small 区块 ──
--------------------------------------------------------------------------
--[[ quagmire_backpack_small ]]
--------------------------------------------------------------------------

-- 小背包：type = "backpack"。★ 全文件仅 2 处用这个 type（第 2468/2489 行），
--   且**两处都在未开化 DLC 里** —— 说明 backpack 是新引入的、尚未被主流程使用的类型。
params.quagmire_backpack_small =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x3"。
        animbank = "ui_chest_3x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x3"。
        animbuild = "ui_chest_3x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-50, -450, 0)。
        pos = Vector3(-50, -450, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- type = "backpack"
--   背包类新类型（全文件仅未开化 DLC 的两个容器在用）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "backpack",
}

-- ★ 4 个槽全在同一行 y = 120：单排布局。坐标 -x*75-37.5 → -37.5/-112.5/-187.5/-262.5。
--   ⚠ 注意 x 从 0 递增但坐标**递减**（-x*75），所以 slot 1 在**最右**。
--     这是本文件少数「槽序与视觉顺序相反」的写法（同第 1497 行弹弓2 的注释）。
for x = 0, 3 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.quagmire_backpack_small.widget.slotpos, Vector3(-x * 75 - 75*.5, 120, 0))
-- 循环结束：已插入 **4 个** slotpos 坐标，本容器的 numslots 定为 4。
end

--------------------------------------------------------------------------
-- ── quagmire_backpack 区块 ──
--[[ quagmire_backpack ]]
--------------------------------------------------------------------------

-- 大背包：8 格（for x = 0, 7），单排。
params.quagmire_backpack =
{
    widget =
    {
-- slotpos：同第 53 行（首次定义），此处值 = {}。
        slotpos = {},
-- animbank：同第 28 行（首次定义），此处值 = "ui_chest_3x3"。
        animbank = "ui_chest_3x3",
-- animbuild：同第 55 行（首次定义），此处值 = "ui_chest_3x3"。
        animbuild = "ui_chest_3x3",
-- pos：同第 56 行（首次定义），此处值 = Vector3(-50, -450, 0)。
        pos = Vector3(-50, -450, 0),
-- side_align_tip：同第 80 行（首次定义），此处值 = 100。
        side_align_tip = 100,
    },
-- type = "backpack"
--   背包类新类型（全文件仅未开化 DLC 的两个容器在用）。
--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /
--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。
    type = "backpack",
}

-- 8 个槽全在同一行。★ 这是本文件唯一「单排 8 格」的布局，与背包的 2x4 视觉不同。
for x = 0, 7 do
-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。
--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。
    table.insert(params.quagmire_backpack.widget.slotpos, Vector3(-x * 75 - 75*.5, 120, 0))
-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。
end

-- ── 文件末尾：全局槽位数统计 ──
--------------------------------------------------------------------------

-- 【★ MAXITEMSLOTS 计算】遍历所有蓝图，取最大的槽位数。
--   · v.widget.numslots 优先（动态槽位容器显式声明的）；
--   · 否则数 #v.widget.slotpos（静态布局的坐标数组长度）；
--   · 都没有则 0。
--   ⚠ 潜在缺陷：若某个 params 蓝图**既无 numslots 也无 slotpos**，它会静默变成 0，
--     而 MAXITEMSLOTS 取 max 所以不影响全局 —— 但该容器运行时 slots 会是空的。
--     当前所有蓝图都有 slotpos 或 numslots（grep 核实无遗漏），故无害。
for k, v in pairs(params) do
-- ★★ 这行决定了**整个游戏的容器网络开销**：
--   container_classified.lua:1057 会 `for i = 1, containers.MAXITEMSLOTS` 
--     为**每一个**容器实体预分配 net_entity 变量。
--   ⇒ 推论：本文件第 1886 行给 bookstation 开 20 槽，就等于给**每个**箱子容器
--     多分配 5 条网络变量。这是一个**全局性的带宽决策，却藏在一个数据文件里**。
--   ⚠ 这也是本文件最容易出「性能退化」的地方：
--     任何模组新增一个大容器，都会抬高这个全局数字，影响所有玩家的所有容器。
--   ★ 对照 constants.lua:650 MAXITEMSLOTS = 15（物品栏槽数上限）——
--     两个同名常量，一个是物品栏的、一个是容器的，**极易混淆**。
	containers.MAXITEMSLOTS = math.max(containers.MAXITEMSLOTS, v.widget.numslots or (v.widget.slotpos and #v.widget.slotpos or 0))
end

-- 收尾分隔线。
--------------------------------------------------------------------------

return containers
