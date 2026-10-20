/**
 * spec-containers-dense.mjs —— containers.lua 密集注释（结构性代码行补齐）
 *
 * 由 gen-dense-params.mjs 依据 FIELD_DOC / TYPE_DOC / CONTAINER_DESC 三张人工表生成：
 *   · widget 每个字段都有**专属释义**（不是统一套话）
 *   · 同一字段第二次出现只写「同第 N 行 + 本行实际值」，避免注释复读
 *   · 槽位循环先解析 for 范围，算出「行 × 列 = 槽数」再写
 *   · 蓝图声明行附容器身份与别名/deepcopy 的语义
 */

export const HEADER_EXTRA = [];

export const BEFORE = {
  "containers.widgetsetup#1+19": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
  ],
  "containers.widgetsetup#1+25": [
    "-- type = \"pack\"",
    "--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "containers.widgetsetup#1+30": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "containers.widgetsetup#1+31": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "containers.widgetsetup#1+32": [
    "-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。",
  ],
  "containers.widgetsetup#1+44": [
    "-- ★ 槽位坐标数组：每个 Vector3 是**一个格子在屏幕上的绝对位置**。",
    "--   ★★ 数组顺序 = 槽位编号顺序（slot 1 = 第一个坐标）。改顺序就改了物品编号，",
    "--     而存档按编号还原（components/container.lua:996 OnLoad），所以这是**存档兼容雷区**。",
  ],
  "containers.widgetsetup#1+45": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_icepack_2x3\"。",
  ],
  "containers.widgetsetup#1+46": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
  ],
  "containers.widgetsetup#1+47": [
    "-- ★ UI 整体位置偏移（屏幕像素）。正值=右/上，负值=左/下。",
    "--   ★ 与 slotpos 的关系：slotpos 是**绝对坐标**，pos 是**整体偏移**，二者叠加生效。",
  ],
  "containers.widgetsetup#1+49": [
    "-- ★ UI 是否挂在屏幕**侧边**（背包类）而非中央（箱子类）。",
    "--   消费点：components/container.lua:637 作为第二参数传给 doer.HUD:OpenContainer。",
  ],
  "containers.widgetsetup#1+50": [
    "-- type = \"pack\"",
    "--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "containers.widgetsetup#1+51": [
    "-- ★ 同时开启人数上限（不是「一生只能开一次」）。",
    "--   判定在 components/container.lua:735 CanOpen；★ 但 Open 自身不检查它，",
    "--   守门在 actions.lua:1095 —— 这是「约定优于实现」的边界。",
  ],
  "containers.widgetsetup#1+55": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "containers.widgetsetup#1+56": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "containers.widgetsetup#1+57": [
    "-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。",
  ],
  "containers.widgetsetup#1+67": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "containers.widgetsetup#1+68": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "containers.widgetsetup#1+69": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "containers.widgetsetup#1+70": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "containers.widgetsetup#1+71": [
    "-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。",
  ],
  "containers.widgetsetup#1+73": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "containers.widgetsetup#1+80": [
    "-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。",
  ],
  "containers.widgetsetup#1+92": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "containers.widgetsetup#1+93": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chester_shadow_3x4\"。",
  ],
  "containers.widgetsetup#1+94": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chester_shadow_3x4\"。",
  ],
  "containers.widgetsetup#1+95": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 220, 0)。",
  ],
  "containers.widgetsetup#1+96": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "containers.widgetsetup#1+98": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "containers.widgetsetup#1+103": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "containers.widgetsetup#1+105": [
    "-- 循环结束：已插入 **12 个** slotpos 坐标，本容器的 numslots 定为 12。",
  ],
  "containers.widgetsetup#1+108": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "containers.widgetsetup#1+109": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "containers.widgetsetup#1+110": [
    "-- ★ 开门动画是否**循环**播放（传送门漩涡这类用）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.shadow_container.itemtestfn#1+8": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.shadow_container.itemtestfn#1+9": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.shadow_container.itemtestfn#1+10": [
    "-- ★ 开门动画是否**循环**播放（传送门漩涡这类用）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.shadow_container.itemtestfn#1+27": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.shadow_container.itemtestfn#1+28": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_woby_3x3\"。",
  ],
  "params.shadow_container.itemtestfn#1+29": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_woby_3x3\"。",
  ],
  "params.shadow_container.itemtestfn#1+31": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.shadow_container.itemtestfn#1+33": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.shadow_container.itemtestfn#1+40": [
    "-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「沃比小形态容器 3x3」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原",
  ],
  "params.shadow_container.itemtestfn#1+42": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.shadow_container.itemtestfn#1+44": [
    "-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。",
  ],
  "params.shadow_container.itemtestfn#1+70": [
    "-- ★ 槽位生成循环（顶层）：x = 0 … 2 → **3 轮**。",
    "--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 3 × 1 = **3 个槽**，即「沃比晾肉架 3x1」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 3），存档按编号还原",
  ],
  "params.shadow_container.itemtestfn#1+71": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.shadow_container.itemtestfn#1+72": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.shadow_container.itemtestfn#1+73": [
    "-- 循环结束：已插入 **3 个** slotpos 坐标，本容器的 numslots 定为 3。",
  ],
  "params.woby_rack_container.itemtestfn#1+32": [
    "-- ★ 槽位生成循环（顶层）：x = 0 … 2 → **3 轮**。",
    "--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 3 × 1 = **3 个槽**，即「普通晾肉架 3x1」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 3），存档按编号还原",
  ],
  "params.woby_rack_container.itemtestfn#1+33": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.woby_rack_container.itemtestfn#1+34": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.woby_rack_container.itemtestfn#1+35": [
    "-- 循环结束：已插入 **3 个** slotpos 坐标，本容器的 numslots 定为 3。",
  ],
  "params.meatrack.itemtestfn#1+45": [
    "-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「寄居蟹 3x3 晾肉架」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原",
  ],
  "params.meatrack.itemtestfn#1+47": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.meatrack.itemtestfn#1+48": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.meatrack.itemtestfn#1+50": [
    "-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。",
  ],
  "params.meatrack.itemtestfn#1+65": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.meatrack.itemtestfn#1+66": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.meatrack.itemtestfn#1+67": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.meatrack.itemtestfn#1+77": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x1\"。",
  ],
  "params.meatrack.itemtestfn#1+78": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x1\"。",
  ],
  "params.meatrack.itemtestfn#1+79": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "params.meatrack.itemtestfn#1+80": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.meatrack.itemtestfn#1+89": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+16": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+17": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+18": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+19": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+21": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_cookpot_1x4\"。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+22": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_cookpot_1x4\"。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+23": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+24": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+31": [
    "-- ★ 是否接受整摞物品。false = 每格只放一件。",
    "--   落点：components/container.lua:534 GiveItem 会把超量堆叠 Get() 拆成单个并**返回 false**。",
  ],
  "params.yotb_sewingmachine.widget.buttoninfo.validfn#1+32": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+5": [
    "-- 【蓝图：portablecookpot】便携烹饪锅",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+17": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+18": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+25": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_cookpot_1x2\"。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+26": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_cookpot_1x2\"。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+27": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+28": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+35": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.cookpot.widget.buttoninfo.validfn#1+37": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+14": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+15": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+16": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+17": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+19": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_bundle_2x2\"。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+20": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_bundle_2x2\"。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+21": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+22": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 120。",
  ],
  "params.portablespicer.widget.buttoninfo.validfn#1+29": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+13": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_construction_4x1\"。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+14": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_construction_4x1\"。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+16": [
    "-- 提示条顶部对齐距离（像素）。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+30": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+34": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+35": [
    "-- 循环结束：已插入 **4 个** slotpos 坐标，本容器的 numslots 定为 4。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+17": [
    "-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+18": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+19": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+26": [
    "-- 【蓝图：construction_container_1x1】建造材料容器 1x1 变体",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+28": [
    "-- ★ 槽位坐标数组：每个 Vector3 是**一个格子在屏幕上的绝对位置**。",
    "--   ★★ 数组顺序 = 槽位编号顺序（slot 1 = 第一个坐标）。改顺序就改了物品编号，",
    "--     而存档按编号还原（components/container.lua:996 OnLoad），所以这是**存档兼容雷区**。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+30": [
    "-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+31": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.construction_container.widget.buttoninfo.validfn#1+32": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "EnableRiftsPopUpConfirm#1+31": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "EnableRiftsPopUpConfirm#1+32": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "EnableRiftsPopUpConfirm#1+33": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "EnableRiftsPopUpConfirm#1+34": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "EnableRiftsPopUpConfirm#1+36": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_lamp_1x4\"。",
  ],
  "EnableRiftsPopUpConfirm#1+37": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_lamp_1x4\"。",
  ],
  "EnableRiftsPopUpConfirm#1+38": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "EnableRiftsPopUpConfirm#1+39": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "EnableRiftsPopUpConfirm#1+41": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "EnableRiftsPopUpConfirm#1+42": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.mushroom_light2.itemtestfn#1+9": [
    "-- 【蓝图：yots_lantern_post】永夜灯柱 1 格（灯燃料/孢子/灯芯）",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.mushroom_light2.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = { Vector3(0, 0, 0), }。",
  ],
  "params.mushroom_light2.itemtestfn#1+13": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_1x1\"。",
  ],
  "params.mushroom_light2.itemtestfn#1+14": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_1x1\"。",
  ],
  "params.mushroom_light2.itemtestfn#1+15": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 160, 0)。",
  ],
  "params.mushroom_light2.itemtestfn#1+16": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.mushroom_light2.itemtestfn#1+18": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.mushroom_light2.itemtestfn#1+19": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.yots_lantern_post.itemtestfn#1+8": [
    "-- 【蓝图：hermitcrab_lightpost】寄居蟹灯柱（换皮，复用同一 itemtestfn）",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.yots_lantern_post.itemtestfn#1+9": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.yots_lantern_post.itemtestfn#1+10": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.yots_lantern_post.itemtestfn#1+11": [
    "-- ★ 物品筛选闭包，签名固定 (container, item, slot)。",
    "--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。",
    "--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.hermitcrab_lightpost.widget.bganim_visualfn#1+15": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.hermitcrab_lightpost.widget.bganim_visualfn#1+16": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.hermitcrab_lightpost.widget.bganim_visualfn#1+17": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.hermitcrab_lightpost.widget.bganim_visualfn#1+18": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.hermitcrab_lightpost.widget.bganim_visualfn#1+31": [
    "-- 底纹批量填充循环：i = 1 … 4 → **4 次**。",
    "--   ★ 只往 slotbg 塞贴图、**不产生槽位**——槽位由 slotpos 决定。",
    "--   ⇒ 它的次数必须与「寄居蟹屋 2 代 2x2=4 格」的 slotpos 数量严格相等，否则底纹会错位。",
  ],
  "params.hermitcrab_lightpost.widget.bganim_visualfn#1+33": [
    "-- 循环结束：已插入 **0 个** slotpos 坐标，本容器的 numslots 定为 0。",
  ],
  "params.hermithouse2.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.hermithouse2.itemtestfn#1+13": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_backpack_2x4\"。",
  ],
  "params.hermithouse2.itemtestfn#1+14": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_backpack_2x4\"。",
  ],
  "params.hermithouse2.itemtestfn#1+15": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(275, 0, 0)。",
  ],
  "params.hermithouse2.itemtestfn#1+16": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.hermithouse2.itemtestfn#1+18": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.hermithouse2.itemtestfn#1+19": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.hermithouse2.itemtestfn#1+22": [
    "-- ★ 槽位生成循环（顶层）：y = 0 … 3 → **4 轮**。",
    "--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 4 × 2 = **8 个槽**，即「冬季树 8 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 8），存档按编号还原",
  ],
  "params.hermithouse2.itemtestfn#1+23": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.hermithouse2.itemtestfn#1+24": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.hermithouse2.itemtestfn#1+25": [
    "-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。",
  ],
  "params.winter_tree.itemtestfn#1+5": [
    "-- 【蓝图：winter_deciduoustree】冬季落叶树",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.winter_tree.itemtestfn#1+6": [
    "-- 【蓝图：winter_palmconetree】冬季棕榈树",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.winter_tree.itemtestfn#1+18": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.winter_tree.itemtestfn#1+19": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.winter_tree.itemtestfn#1+20": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.winter_tree.itemtestfn#1+21": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.winter_tree.itemtestfn#1+30": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_2x2\"。",
  ],
  "params.winter_tree.itemtestfn#1+31": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_2x2\"。",
  ],
  "params.winter_tree.itemtestfn#1+32": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.winter_tree.itemtestfn#1+33": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 120。",
  ],
  "params.winter_tree.itemtestfn#1+35": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.winter_tree.itemtestfn#1+36": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.winter_tree.itemtestfn#1+37": [
    "-- openlimit：同第 60 行（首次定义），此处值 = 1。",
  ],
  "params.sisturn.itemtestfn#1+26": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.sisturn.itemtestfn#1+27": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.sisturn.itemtestfn#1+28": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.sisturn.itemtestfn#1+29": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.sisturn.itemtestfn#1+38": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_2x2\"。",
  ],
  "params.sisturn.itemtestfn#1+39": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_2x2\"。",
  ],
  "params.sisturn.itemtestfn#1+40": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.sisturn.itemtestfn#1+41": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 120。",
  ],
  "params.sisturn.itemtestfn#1+43": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.sisturn.itemtestfn#1+44": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.offering_pot.itemtestfn#1+14": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+15": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+16": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+17": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+18": [
    "-- 内联槽位坐标（本容器第 5 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+19": [
    "-- 内联槽位坐标（本容器第 6 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+30": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x2\"。",
  ],
  "params.offering_pot.itemtestfn#1+31": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x2\"。",
  ],
  "params.offering_pot.itemtestfn#1+32": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.offering_pot.itemtestfn#1+33": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 120。",
  ],
  "params.offering_pot.itemtestfn#1+35": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.offering_pot.itemtestfn#1+36": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.offering_pot.itemtestfn#1+51": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+52": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.offering_pot.itemtestfn#1+59": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_1x2\"。",
  ],
  "params.offering_pot.itemtestfn#1+60": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_1x2\"。",
  ],
  "params.offering_pot.itemtestfn#1+61": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.offering_pot.itemtestfn#1+62": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.offering_pot.itemtestfn#1+64": [
    "-- ★ 关箱 UI 音效，同样只在客户端播放（同上）。",
  ],
  "params.offering_pot.itemtestfn#1+67": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.merm_armory.itemtestfn#1+9": [
    "-- 【蓝图：merm_armory_upgraded】鱼人军械库升级版",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.merm_armory.itemtestfn#1+21": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.merm_armory.itemtestfn#1+22": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.merm_armory.itemtestfn#1+23": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.merm_armory.itemtestfn#1+25": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x1\"。",
  ],
  "params.merm_armory.itemtestfn#1+26": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x1\"。",
  ],
  "params.merm_armory.itemtestfn#1+27": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.merm_armory.itemtestfn#1+28": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.merm_armory.itemtestfn#1+30": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.merm_armory.itemtestfn#1+31": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.livingtree_halloween.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.livingtree_halloween.itemtestfn#1+13": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.livingtree_halloween.itemtestfn#1+14": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.livingtree_halloween.itemtestfn#1+15": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "params.livingtree_halloween.itemtestfn#1+16": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.livingtree_halloween.itemtestfn#1+18": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.livingtree_halloween.itemtestfn#1+23": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.livingtree_halloween.itemtestfn#1+25": [
    "-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。",
  ],
  "params.saltbox.itemtestfn#1+16": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.saltbox.itemtestfn#1+17": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_krampusbag_2x8\"。",
  ],
  "params.saltbox.itemtestfn#1+18": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_krampusbag_2x8\"。",
  ],
  "params.saltbox.itemtestfn#1+20": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -130, 0)。",
  ],
  "params.saltbox.itemtestfn#1+22": [
    "-- issidewidget：同第 58 行（首次定义），此处值 = true。",
  ],
  "params.saltbox.itemtestfn#1+23": [
    "-- type = \"pack\"",
    "--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.saltbox.itemtestfn#1+27": [
    "-- ★ 槽位生成循环（顶层）：y = 0 … 6 → **7 轮**。",
    "--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 7 × 2 = **14 个槽**，即「圣诞怪口袋 14 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 14），存档按编号还原",
  ],
  "params.saltbox.itemtestfn#1+28": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+29": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+30": [
    "-- 循环结束：已插入 **14 个** slotpos 坐标，本容器的 numslots 定为 14。",
  ],
  "params.saltbox.itemtestfn#1+40": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.saltbox.itemtestfn#1+41": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_piggyback_2x6\"。",
  ],
  "params.saltbox.itemtestfn#1+42": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_piggyback_2x6\"。",
  ],
  "params.saltbox.itemtestfn#1+44": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -90, 0)。",
  ],
  "params.saltbox.itemtestfn#1+46": [
    "-- issidewidget：同第 58 行（首次定义），此处值 = true。",
  ],
  "params.saltbox.itemtestfn#1+47": [
    "-- type = \"pack\"",
    "--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.saltbox.itemtestfn#1+48": [
    "-- openlimit：同第 60 行（首次定义），此处值 = 1。",
  ],
  "params.saltbox.itemtestfn#1+51": [
    "-- ★ 槽位生成循环（顶层）：y = 0 … 5 → **6 轮**。",
    "--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 6 × 2 = **12 个槽**，即「背背怪背包 12 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 12），存档按编号还原",
  ],
  "params.saltbox.itemtestfn#1+52": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+53": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+54": [
    "-- 循环结束：已插入 **12 个** slotpos 坐标，本容器的 numslots 定为 12。",
  ],
  "params.saltbox.itemtestfn#1+66": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+67": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+68": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+69": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.saltbox.itemtestfn#1+71": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_cookpot_1x4\"。",
  ],
  "params.saltbox.itemtestfn#1+72": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_cookpot_1x4\"。",
  ],
  "params.saltbox.itemtestfn#1+73": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 0, 0)。",
  ],
  "params.saltbox.itemtestfn#1+74": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.saltbox.itemtestfn#1+81": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+21": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+22": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+23": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+24": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+25": [
    "-- 内联槽位坐标（本容器第 5 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+37": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_cookpot_1x4\"。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+38": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(100, 0, 0)。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+45": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+46": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.teleportato_base.widget.buttoninfo.fn#1+47": [
    "-- openlimit：同第 60 行（首次定义），此处值 = 1。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+14": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+15": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+16": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+18": [
    "-- ★ 升级态构建名。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+19": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+20": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+22": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+25": [
    "-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「宝箱 3x3=9 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+27": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+29": [
    "-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+32": [
    "-- 【蓝图：chest_mimic】拟态怪箱",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+33": [
    "-- 【蓝图：skullchest】骷髅宝箱",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+34": [
    "-- 【蓝图：terrariumchest】生态箱",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+37": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+38": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+41": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+42": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+49": [
    "-- 循环结束：已插入 **16 个** slotpos 坐标，本容器的 numslots 定为 16。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+57": [
    "-- ★ 升级态贴图库名（箱子被季节活动升级后使用）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+58": [
    "-- ★ 升级态构建名。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+68": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+69": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+75": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_antlionhat_1x1\"。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+76": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_antlionhat_1x1\"。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+77": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(106, 40, 0)。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+79": [
    "-- type = \"hand_inv\"",
    "--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.antlionhat.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.antlionhat.itemtestfn#1+13": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_fish_box_5x4\"。",
  ],
  "params.antlionhat.itemtestfn#1+14": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_fish_box_5x4\"。",
  ],
  "params.antlionhat.itemtestfn#1+15": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 220, 0)。",
  ],
  "params.antlionhat.itemtestfn#1+16": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.antlionhat.itemtestfn#1+18": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.antlionhat.itemtestfn#1+23": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.antlionhat.itemtestfn#1+25": [
    "-- 循环结束：已插入 **20 个** slotpos 坐标，本容器的 numslots 定为 20。",
  ],
  "params.fish_box.itemtestfn#1+15": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.fish_box.itemtestfn#1+16": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.fish_box.itemtestfn#1+23": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_cookpot_1x2\"。",
  ],
  "params.fish_box.itemtestfn#1+24": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_cookpot_1x2\"。",
  ],
  "params.fish_box.itemtestfn#1+25": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 60, 0)。",
  ],
  "params.fish_box.itemtestfn#1+27": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.fish_box.itemtestfn#1+28": [
    "-- ★ 槽位是否有语义：true 时物品必须进 itemtestfn(item, slot) 指定的**那一格**。",
    "--   落点：components/container.lua:298 GetSpecificSlotForItem（逐槽试）、451 GiveItem（优先用）。",
  ],
  "params.fish_box.itemtestfn#1+29": [
    "-- type = \"hand_inv\"",
    "--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.fish_box.itemtestfn#1+30": [
    "-- 箱内物品是否**排除在合成搜索之外**。true=不参与合成（沙尘蜂帽/弹弓用）。",
    "--   ⚠ 对照第 1373/1408/1444 行：beard_sack 把同一行注释掉了，即胡子袋要参与合成。",
  ],
  "params.oceanfishingrod.itemtestfn#1+17": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.oceanfishingrod.itemtestfn#1+23": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_beard_1x1\"。",
  ],
  "params.oceanfishingrod.itemtestfn#1+24": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_beard_1x1\"。",
  ],
  "params.oceanfishingrod.itemtestfn#1+25": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-82, 89, 0)。",
  ],
  "params.oceanfishingrod.itemtestfn#1+26": [
    "-- 提示条底部对齐距离（像素）。",
  ],
  "params.oceanfishingrod.itemtestfn#1+28": [
    "-- type = \"side_inv_behind\"",
    "--   角色背后侧边容器（playerhud.lua:397）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.beard_sack_1.itemtestfn#1+16": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_1.itemtestfn#1+17": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_1.itemtestfn#1+24": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_beard_2x1\"。",
  ],
  "params.beard_sack_1.itemtestfn#1+25": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_beard_2x1\"。",
  ],
  "params.beard_sack_1.itemtestfn#1+26": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-82, 89, 0)。",
  ],
  "params.beard_sack_1.itemtestfn#1+27": [
    "-- bottom_align_tip：同第 1368 行（首次定义），此处值 = -100。",
  ],
  "params.beard_sack_1.itemtestfn#1+30": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = true。",
  ],
  "params.beard_sack_1.itemtestfn#1+31": [
    "-- ★ 自动取物优先级最低（从背包找东西时先翻别处，找不到才来这里）。",
  ],
  "params.beard_sack_2.itemtestfn#1+15": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_2.itemtestfn#1+16": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_2.itemtestfn#1+17": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_2.itemtestfn#1+25": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_beard_3x1\"。",
  ],
  "params.beard_sack_2.itemtestfn#1+26": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_beard_3x1\"。",
  ],
  "params.beard_sack_2.itemtestfn#1+27": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-82, 89, 0)。",
  ],
  "params.beard_sack_2.itemtestfn#1+28": [
    "-- bottom_align_tip：同第 1368 行（首次定义），此处值 = -100。",
  ],
  "params.beard_sack_2.itemtestfn#1+30": [
    "-- type = \"side_inv_behind\"",
    "--   角色背后侧边容器（playerhud.lua:397）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.beard_sack_2.itemtestfn#1+31": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = true。",
  ],
  "params.beard_sack_2.itemtestfn#1+32": [
    "-- lowpriorityselection：同第 1407 行（首次定义），此处值 = true。",
  ],
  "params.beard_sack_3.itemtestfn#1+22": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_3.itemtestfn#1+28": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_cookpot_1x2\"。",
  ],
  "params.beard_sack_3.itemtestfn#1+29": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_cookpot_1x2\"。",
  ],
  "params.beard_sack_3.itemtestfn#1+30": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 15, 0)。",
  ],
  "params.beard_sack_3.itemtestfn#1+33": [
    "-- excludefromcrafting：同第 1339 行（首次定义），此处值 = true。",
  ],
  "params.beard_sack_3.itemtestfn#1+37": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.beard_sack_3.itemtestfn#1+38": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.beard_sack_3.itemtestfn#1+40": [
    "-- 【蓝图：slingshot999ex】弹弓 999 变体（deepcopy slingshotex 换皮）",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.beard_sack_3.itemtestfn#1+41": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.beard_sack_3.itemtestfn#1+42": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.beard_sack_3.itemtestfn#1+51": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_3.itemtestfn#1+52": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.beard_sack_3.itemtestfn#1+68": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.beard_sack_3.itemtestfn#1+69": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.slingshot.itemtestfn#1+17": [
    "-- ★ 物品筛选闭包，签名固定 (container, item, slot)。",
    "--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。",
    "--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.slingshot.itemtestfn#1+18": [
    "-- ★ 物品筛选闭包，签名固定 (container, item, slot)。",
    "--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。",
    "--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.slingshot.itemtestfn#1+19": [
    "-- ★ 物品筛选闭包，签名固定 (container, item, slot)。",
    "--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。",
    "--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.slingshot.itemtestfn#1+32": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.slingshot.itemtestfn#1+33": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+34": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+35": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_tacklecontainer_3x2\"。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+36": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_tacklecontainer_3x2\"。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+37": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+38": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+40": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+45": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.slingshotmodscontainer.itemtestfn#1+47": [
    "-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。",
  ],
  "params.tacklecontainer.itemtestfn#1+14": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.tacklecontainer.itemtestfn#1+15": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_tacklecontainer_3x5\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+16": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_tacklecontainer_3x5\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+17": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 280, 0)。",
  ],
  "params.tacklecontainer.itemtestfn#1+18": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.tacklecontainer.itemtestfn#1+20": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.tacklecontainer.itemtestfn#1+25": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.tacklecontainer.itemtestfn#1+27": [
    "-- 循环结束：已插入 **15 个** slotpos 坐标，本容器的 numslots 定为 15。",
  ],
  "params.tacklecontainer.itemtestfn#1+30": [
    "-- ★ 专用容器优先判定（弹药包这类）。常与 itemtestfn 共用同一函数，但语义相反：",
    "--   itemtestfn 管「能不能放」，priorityfn 管「优先往哪放」（components/container.lua:319）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.tacklecontainer.itemtestfn#1+42": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.tacklecontainer.itemtestfn#1+43": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_tacklecontainer_3x5\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+44": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_tacklecontainer_3x5\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+45": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 280, 0)。",
  ],
  "params.tacklecontainer.itemtestfn#1+46": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.tacklecontainer.itemtestfn#1+48": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.tacklecontainer.itemtestfn#1+53": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.tacklecontainer.itemtestfn#1+55": [
    "-- 循环结束：已插入 **15 个** slotpos 坐标，本容器的 numslots 定为 15。",
  ],
  "params.tacklecontainer.itemtestfn#1+65": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.tacklecontainer.itemtestfn#1+66": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x2\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+67": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x2\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+68": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "params.tacklecontainer.itemtestfn#1+69": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.tacklecontainer.itemtestfn#1+71": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.tacklecontainer.itemtestfn#1+74": [
    "-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「圣柜 3x2=6 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原",
  ],
  "params.tacklecontainer.itemtestfn#1+76": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.tacklecontainer.itemtestfn#1+78": [
    "-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。",
  ],
  "params.tacklecontainer.itemtestfn#1+88": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.tacklecontainer.itemtestfn#1+89": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_krampusbag_2x8\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+90": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_krampusbag_2x8\"。",
  ],
  "params.tacklecontainer.itemtestfn#1+91": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -130, 0)。",
  ],
  "params.tacklecontainer.itemtestfn#1+93": [
    "-- issidewidget：同第 58 行（首次定义），此处值 = true。",
  ],
  "params.tacklecontainer.itemtestfn#1+94": [
    "-- type = \"pack\"",
    "--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.tacklecontainer.itemtestfn#1+95": [
    "-- openlimit：同第 60 行（首次定义），此处值 = 1。",
  ],
  "params.tacklecontainer.itemtestfn#1+98": [
    "-- ★ 槽位生成循环（顶层）：y = 0 … 6 → **7 轮**。",
    "--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 7 × 2 = **14 个槽**，即「种子袋 14 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 14），存档按编号还原",
  ],
  "params.tacklecontainer.itemtestfn#1+99": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.tacklecontainer.itemtestfn#1+100": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.tacklecontainer.itemtestfn#1+101": [
    "-- 循环结束：已插入 **14 个** slotpos 坐标，本容器的 numslots 定为 14。",
  ],
  "params.seedpouch.itemtestfn#1+14": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.seedpouch.itemtestfn#1+15": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_krampusbag_2x8\"。",
  ],
  "params.seedpouch.itemtestfn#1+16": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_krampusbag_2x8\"。",
  ],
  "params.seedpouch.itemtestfn#1+17": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-5, -130, 0)。",
  ],
  "params.seedpouch.itemtestfn#1+19": [
    "-- issidewidget：同第 58 行（首次定义），此处值 = true。",
  ],
  "params.seedpouch.itemtestfn#1+20": [
    "-- type = \"pack\"",
    "--   背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.seedpouch.itemtestfn#1+21": [
    "-- openlimit：同第 60 行（首次定义），此处值 = 1。",
  ],
  "params.seedpouch.itemtestfn#1+24": [
    "-- ★ 槽位生成循环（顶层）：y = 0 … 6 → **7 轮**。",
    "--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 7 × 2 = **14 个槽**，即「糖果袋 14 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 14），存档按编号还原",
  ],
  "params.seedpouch.itemtestfn#1+25": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.seedpouch.itemtestfn#1+26": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.seedpouch.itemtestfn#1+27": [
    "-- 循环结束：已插入 **14 个** slotpos 坐标，本容器的 numslots 定为 14。",
  ],
  "params.candybag.itemtestfn#1+4": [
    "-- ★ 专用容器优先判定（弹药包这类）。常与 itemtestfn 共用同一函数，但语义相反：",
    "--   itemtestfn 管「能不能放」，priorityfn 管「优先往哪放」（components/container.lua:319）。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.candybag.itemtestfn#1+14": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {。",
  ],
  "params.candybag.itemtestfn#1+15": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.candybag.itemtestfn#1+21": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_alterguardianhat_1x1\"。",
  ],
  "params.candybag.itemtestfn#1+22": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_alterguardianhat_1x1\"。",
  ],
  "params.candybag.itemtestfn#1+23": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 160, 0)。",
  ],
  "params.candybag.itemtestfn#1+25": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.candybag.itemtestfn#1+26": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+13": [
    "-- 格子底纹贴图数组（与 slotpos 严格一一对应）。★ 纯装饰，容器逻辑从不读。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+14": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_alterguardianhat_1x6\"。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+15": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_alterguardianhat_1x6\"。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+18": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+19": [
    "-- type = \"hand_inv\"",
    "--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+20": [
    "-- excludefromcrafting：同第 1339 行（首次定义），此处值 = true。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+26": [
    "-- ★ 槽位生成循环（顶层）：i = 0 … 4 → **5 轮**。",
    "--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 5 × 1 = **5 个槽**，即「监护者帽 5 竖排」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 5），存档按编号还原",
  ],
  "params.alterguardianhatshard.itemtestfn#1+28": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+29": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.alterguardianhatshard.itemtestfn#1+30": [
    "-- 循环结束：已插入 **5 个** slotpos 坐标，本容器的 numslots 定为 5。",
  ],
  "params.alterguardianhat.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.alterguardianhat.itemtestfn#1+13": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_tacklecontainer_3x2\"。",
  ],
  "params.alterguardianhat.itemtestfn#1+14": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_tacklecontainer_3x2\"。",
  ],
  "params.alterguardianhat.itemtestfn#1+15": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-850, 100, 0)。",
  ],
  "params.alterguardianhat.itemtestfn#1+16": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.alterguardianhat.itemtestfn#1+18": [
    "-- type = \"hand_inv\"",
    "--   手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.alterguardianhat.itemtestfn#1+19": [
    "-- excludefromcrafting：同第 1339 行（首次定义），此处值 = true。",
  ],
  "params.alterguardianhat.itemtestfn#1+22": [
    "-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「怀表 3x2=6 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原",
  ],
  "params.alterguardianhat.itemtestfn#1+24": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.alterguardianhat.itemtestfn#1+26": [
    "-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。",
  ],
  "params.pocketwatch.itemtestfn#1+14": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.pocketwatch.itemtestfn#1+15": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.pocketwatch.itemtestfn#1+16": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.pocketwatch.itemtestfn#1+17": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.pocketwatch.itemtestfn#1+19": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_cookpot_1x4\"。",
  ],
  "params.pocketwatch.itemtestfn#1+20": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_cookpot_1x4\"。",
  ],
  "params.pocketwatch.itemtestfn#1+21": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.pocketwatch.itemtestfn#1+22": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.pocketwatch.itemtestfn#1+24": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.pocketwatch.itemtestfn#1+25": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.ocean_trawler.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.ocean_trawler.itemtestfn#1+13": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_bookstation_4x5\"。",
  ],
  "params.ocean_trawler.itemtestfn#1+14": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_bookstation_4x5\"。",
  ],
  "params.ocean_trawler.itemtestfn#1+15": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 280, 0)。",
  ],
  "params.ocean_trawler.itemtestfn#1+16": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.ocean_trawler.itemtestfn#1+18": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.ocean_trawler.itemtestfn#1+22": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.ocean_trawler.itemtestfn#1+23": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.ocean_trawler.itemtestfn#1+24": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 3 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.ocean_trawler.itemtestfn#1+25": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 4 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.ocean_trawler.itemtestfn#1+26": [
    "-- 循环结束：已插入 **20 个** slotpos 坐标，本容器的 numslots 定为 20。",
  ],
  "params.bookstation.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.bookstation.itemtestfn#1+13": [
    "-- slotbg：同第 1802 行（首次定义），此处值 = {}。",
  ],
  "params.bookstation.itemtestfn#1+14": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_icepack_2x3\"。",
  ],
  "params.bookstation.itemtestfn#1+15": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_icepack_2x3\"。",
  ],
  "params.bookstation.itemtestfn#1+16": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(75, 195, 0)。",
  ],
  "params.bookstation.itemtestfn#1+17": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.bookstation.itemtestfn#1+19": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.bookstation.itemtestfn#1+24": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.bookstation.itemtestfn#1+25": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.bookstation.itemtestfn#1+27": [
    "-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+13": [
    "-- slotbg：同第 1802 行（首次定义），此处值 = {}。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+14": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_backpack_2x4\"。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+15": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_backpack_2x4\"。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+16": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(75, 195, 0)。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+17": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+19": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+24": [
    "-- ★ 槽位生成循环（顶层）：y = 0 … 3 → **4 轮**。",
    "--   每轮直接插入 2 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 4 × 2 = **8 个槽**，即「战歌容器 8 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 8），存档按编号还原",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+25": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+26": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 2 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+28": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+29": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.houndstooth_blowpipe.itemtestfn#1+30": [
    "-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。",
  ],
  "params.battlesong_container.itemtestfn#1+15": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {。",
  ],
  "params.battlesong_container.itemtestfn#1+16": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.battlesong_container.itemtestfn#1+18": [
    "-- slotbg：同第 1802 行（首次定义），此处值 = {。",
  ],
  "params.battlesong_container.itemtestfn#1+21": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_wortox_souljar_1x1\"。",
  ],
  "params.battlesong_container.itemtestfn#1+22": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_wortox_souljar_1x1\"。",
  ],
  "params.battlesong_container.itemtestfn#1+23": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 195, 0)。",
  ],
  "params.battlesong_container.itemtestfn#1+24": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.battlesong_container.itemtestfn#1+26": [
    "-- closesound：同第 929 行（首次定义），此处值 = \"meta5/wortox/souljar_close_pop\"。",
  ],
  "params.battlesong_container.itemtestfn#1+28": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.wortox_souljar.itemtestfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.wortox_souljar.itemtestfn#1+13": [
    "-- slotbg：同第 1802 行（首次定义），此处值 = {}。",
  ],
  "params.wortox_souljar.itemtestfn#1+14": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_elixir_container_3x3\"。",
  ],
  "params.wortox_souljar.itemtestfn#1+15": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_elixir_container_3x3\"。",
  ],
  "params.wortox_souljar.itemtestfn#1+16": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "params.wortox_souljar.itemtestfn#1+17": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.wortox_souljar.itemtestfn#1+19": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.wortox_souljar.itemtestfn#1+24": [
    "-- ★ 槽位生成循环（顶层）：y = 2 … 0，步长 -1 → **3 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 3 × 3 = **9 个槽**，即「温蒂灵药容器 3x3=9 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 9），存档按编号还原",
  ],
  "params.wortox_souljar.itemtestfn#1+26": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.wortox_souljar.itemtestfn#1+27": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.wortox_souljar.itemtestfn#1+29": [
    "-- 循环结束：已插入 **9 个** slotpos 坐标，本容器的 numslots 定为 9。",
  ],
  "params.elixir_container.itemtestfn#1+16": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.elixir_container.itemtestfn#1+17": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.elixir_container.itemtestfn#1+18": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.elixir_container.itemtestfn#1+19": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.elixir_container.itemtestfn#1+28": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_dragonflyfurnace_2x2\"。",
  ],
  "params.elixir_container.itemtestfn#1+29": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_dragonflyfurnace_2x2\"。",
  ],
  "params.elixir_container.itemtestfn#1+30": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.elixir_container.itemtestfn#1+31": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 120。",
  ],
  "params.elixir_container.itemtestfn#1+38": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+12": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+13": [
    "-- slotbg：同第 1802 行（首次定义），此处值 = {}。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+14": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_slingshotammo_container_3x2\"。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+15": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_slingshotammo_container_3x2\"。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+16": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(0, 200, 0)。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+17": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+19": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+24": [
    "-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「弹弓弹药箱 3x2=6 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+27": [
    "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
    "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
  ],
  "params.dragonflyfurnace.widget.buttoninfo.validfn#1+29": [
    "-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。",
  ],
  "params.slingshotammo_container.itemtestfn#1+13": [
    "-- ★ widget 子表：本容器全部 UI 配置的容器（槽位/贴图/音效/按钮/位置）。",
    "--   ★ 纯表现层——components/container.lua 一个字段都不读，只有 widgets 层消费。",
    "--   参见 widgets/containerwidget.lua（仓库外）；本文件只负责「声明值」。",
  ],
  "params.slingshotammo_container.itemtestfn#1+14": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.slingshotammo_container.itemtestfn#1+15": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_wx78_backupbody_5x3\"。",
  ],
  "params.slingshotammo_container.itemtestfn#1+16": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_wx78_backupbody_5x3\"。",
  ],
  "params.slingshotammo_container.itemtestfn#1+18": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 160。",
  ],
  "params.slingshotammo_container.itemtestfn#1+20": [
    "-- closesound：同第 929 行（首次定义），此处值 = \"WX_rework/module_side/close\"。",
  ],
  "params.slingshotammo_container.itemtestfn#1+22": [
    "-- type = \"chest\"",
    "--   ★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.wx78_backupbody.itemtestfn#1+6": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.wx78_backupbody.itemtestfn#1+8": [
    "-- 循环结束：已插入 **15 个** slotpos 坐标，本容器的 numslots 定为 15。",
  ],
  "params.wx78_backupbody.itemtestfn#1+27": [
    "-- ★ 槽位生成循环（顶层）：y = 1 … 0，步长 -1 → **2 轮**。",
    "--   内层循环：x = 0 … 2 → **3 列**。",
    "--   ⇒ 槽位总数 = 2 × 3 = **6 个槽**，即「WX-78 送货无人机 3x2=6 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 6），存档按编号还原",
  ],
  "params.wx78_backupbody.itemtestfn#1+29": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.wx78_backupbody.itemtestfn#1+31": [
    "-- 循环结束：已插入 **6 个** slotpos 坐标，本容器的 numslots 定为 6。",
  ],
  "params.wx78_backupbody.itemtestfn#1+46": [
    "-- ★ 槽位生成循环（顶层）：x = 0 … 2 → **3 轮**。",
    "--   每轮直接插入 1 个 slotpos 坐标（无内层循环）。",
    "--   ⇒ 槽位总数 = 3 × 1 = **3 个槽**，即「WX-78 小型无人机 3x1=3 格」的 numslots。",
    "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
    "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
    "--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot 3），存档按编号还原",
  ],
  "params.wx78_backupbody.itemtestfn#1+47": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 2 个**坐标（同行向右偏移一格的那一列）。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.wx78_backupbody.itemtestfn#1+48": [
    "-- 循环结束：已插入 **3 个** slotpos 坐标，本容器的 numslots 定为 3。",
  ],
  "params.wx78_backupbody.itemtestfn#1+57": [
    "-- 底纹批量填充循环：x = 0 … 4 → **5 次**。",
    "--   ★ 只往 slotbg 塞贴图、**不产生槽位**——槽位由 slotpos 决定。",
    "--   ⇒ 它的次数必须与「WX-78 小型无人机 3x1=3 格」的 slotpos 数量严格相等，否则底纹会错位。",
  ],
  "params.wx78_backupbody.itemtestfn#1+59": [
    "-- 循环结束：已插入 **0 个** slotpos 坐标，本容器的 numslots 定为 0。",
  ],
  "slothighlightscalefn#1+3": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_wx78_inventorycontainer_1x1\"。",
  ],
  "slothighlightscalefn#1+4": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_wx78_inventorycontainer_1x1\"。",
  ],
  "params.wx78_inventorycontainer.priorityfn#1+13": [
    "-- 提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.wx78_inventorycontainer.priorityfn#1+14": [
    "-- UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "params.wx78_inventorycontainer.priorityfn#1+15": [
    "-- UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
    "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。",
  ],
  "GiveKeyStonePopUp#1+28": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "GiveKeyStonePopUp#1+29": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "GiveKeyStonePopUp#1+30": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "GiveKeyStonePopUp#1+31": [
    "-- 内联槽位坐标（本容器第 4 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "GiveKeyStonePopUp#1+33": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"quagmire_ui_pot_1x4\"。",
  ],
  "GiveKeyStonePopUp#1+34": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"quagmire_ui_pot_1x4\"。",
  ],
  "GiveKeyStonePopUp#1+35": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "GiveKeyStonePopUp#1+36": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "GiveKeyStonePopUp#1+39": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.quagmire_pot.itemtestfn#1+18": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.quagmire_pot.itemtestfn#1+19": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.quagmire_pot.itemtestfn#1+21": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"quagmire_ui_pot_1x3\"。",
  ],
  "params.quagmire_pot.itemtestfn#1+22": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"quagmire_ui_pot_1x3\"。",
  ],
  "params.quagmire_pot.itemtestfn#1+23": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.quagmire_pot.itemtestfn#1+24": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.quagmire_pot.itemtestfn#1+26": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.quagmire_pot.itemtestfn#1+27": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.quagmire_pot.itemtestfn#1+42": [
    "-- 【蓝图：quagmire_casseroledish_small】未开化小平底锅",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.quagmire_pot.itemtestfn#1+48": [
    "-- 【蓝图：quagmire_grill】未开化烤架",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.quagmire_pot.itemtestfn#1+54": [
    "-- 【蓝图：quagmire_grill_small】未开化小烤架",
    "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
    "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
    "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
    "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。",
  ],
  "params.quagmire_pot.itemtestfn#1+66": [
    "-- 内联槽位坐标（本容器第 1 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.quagmire_pot.itemtestfn#1+67": [
    "-- 内联槽位坐标（本容器第 2 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.quagmire_pot.itemtestfn#1+68": [
    "-- 内联槽位坐标（本容器第 3 个 slot）。",
    "--   ★ 数组内先后顺序 = 槽位编号顺序。",
  ],
  "params.quagmire_pot.itemtestfn#1+70": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"quagmire_ui_pot_1x3\"。",
  ],
  "params.quagmire_pot.itemtestfn#1+71": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"quagmire_ui_pot_1x3\"。",
  ],
  "params.quagmire_pot.itemtestfn#1+72": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(200, 0, 0)。",
  ],
  "params.quagmire_pot.itemtestfn#1+73": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.quagmire_pot.itemtestfn#1+75": [
    "-- acceptsstacks：同第 369 行（首次定义），此处值 = false。",
  ],
  "params.quagmire_pot.itemtestfn#1+76": [
    "-- type = \"cooker\"",
    "--   ★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+14": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+15": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+16": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+17": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-50, -450, 0)。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+18": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+20": [
    "-- type = \"backpack\"",
    "--   背包类新类型（全文件仅未开化 DLC 的两个容器在用）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+24": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+25": [
    "-- 循环结束：已插入 **4 个** slotpos 坐标，本容器的 numslots 定为 4。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+35": [
    "-- slotpos：同第 53 行（首次定义），此处值 = {}。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+36": [
    "-- animbank：同第 28 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+37": [
    "-- animbuild：同第 55 行（首次定义），此处值 = \"ui_chest_3x3\"。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+38": [
    "-- pos：同第 56 行（首次定义），此处值 = Vector3(-50, -450, 0)。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+39": [
    "-- side_align_tip：同第 80 行（首次定义），此处值 = 100。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+41": [
    "-- type = \"backpack\"",
    "--   背包类新类型（全文件仅未开化 DLC 的两个容器在用）。",
    "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
    "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+45": [
    "-- 向 slotpos 追加一个槽位坐标：每轮的**第 1 个**坐标。本容器累计第 1 次插入。",
    "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
  ],
  "params.quagmire_pot_syrup.itemtestfn#1+46": [
    "-- 循环结束：已插入 **8 个** slotpos 坐标，本容器的 numslots 定为 8。",
  ],
};

export const AFTER = {};
